// template/TemplateApply.cpp - Şablonun atomik uygulanması (bkz. TemplateApply.h).
#include "template/TemplateApply.h"
#include "template/TemplateStore.h"
#include "ConfigManager.h"
#include "SmartAutomation.h"
#include "MqttManager.h"
#include "safety/SafetyManager.h"
#include "safety/SafetyStore.h"
#include <ArduinoJson.h>
#include <esp_timer.h>
#include <nvs.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

namespace tpl {

namespace {

void setCode(ApplyOutcome& o, ApplyResult r, const char* code, const char* path = "", const char* detail = "") {
  o.r = r;
  snprintf(o.code, sizeof(o.code), "%s", code ? code : "");
  snprintf(o.path, sizeof(o.path), "%s", path ? path : "");
  snprintf(o.detail, sizeof(o.detail), "%s", detail ? detail : "");
}

void outcomeOf(ApplyOutcome& o, ApplyResult r) { setCode(o, r, httpOf(r).code); }

bool shutterMovingNow() {
  AutomationSnapshot snap;
  if (!SmartAutomation::instance().getSnapshot(snap)) return true;   // belirsizse meşgul say
  for (uint8_t p = 0; p < snap.totalPairs && p < (MAX_TOTAL_RELAYS / 2); p++) {
    if (snap.shutters[p].moving || snap.shutters[p].waiting) return true;
  }
  return false;
}

// Şablonun sahip olduğu alan grupları (WebPortal JOB_CONFIG_APPLY ile aynı küme): ad, ek modül, röleler, girişler.
void copyTemplateFields(SystemConfig& dst, const SystemConfig& src) {
  memcpy(dst.device_name, src.device_name, sizeof(dst.device_name));
  dst.ext_module_enabled = src.ext_module_enabled;
  dst.ext_module_channels = src.ext_module_channels;
  dst.ext_module_address = src.ext_module_address;
  memcpy(dst.relays, src.relays, sizeof(dst.relays));
  memcpy(dst.dis, src.dis, sizeof(dst.dis));
}

struct Work {           // ~13 KB: öbekte (loopTask yığını küçük)
  SystemConfig live;    // uygulama öncesi canlı ana yapılandırma (geri alma)
  SystemConfig next;    // aday ana yapılandırma
  safety::SafetyConfig cur;
  safety::SafetyConfig nextSafety;
};

}  // namespace

bool parseBody(const char* json, size_t len, TplCandidate& cand, ApplyOutcome& out) {
  out.rev = 0;
  if (!json || len == 0) {
    setCode(out, ApplyResult::INVALID, "empty_body");
    return false;
  }
  if (len > TPL_MAX_BYTES) {
    setCode(out, ApplyResult::INVALID, "too_large");
    return false;
  }
  size_t cap = len * 2 + 4096;
  if (cap > 57344) cap = 57344;
  DynamicJsonDocument doc(cap);            // > 4 KB: PSRAM'den (CONFIG_SPIRAM_USE_MALLOC)
  if (doc.capacity() == 0) {
    setCode(out, ApplyResult::INTERNAL, "busy");
    return false;
  }
  const DeserializationError de = deserializeJson(doc, json, len);
  if (de == DeserializationError::NoMemory) {
    setCode(out, ApplyResult::INVALID, "too_large");
    return false;
  }
  if (de || !doc.is<JsonObject>()) {
    setCode(out, ApplyResult::INVALID, "bad_json");
    return false;
  }
  SystemConfig* base = (SystemConfig*)malloc(sizeof(SystemConfig));
  if (!base) {
    setCode(out, ApplyResult::INTERNAL, "busy");
    return false;
  }
  {
    ConfigManager::ConfigLock lk(ConfigManager::instance());
    memcpy(base, &ConfigManager::instance().config, sizeof(SystemConfig));
  }
  TplError err;
  const bool ok = parseEnvelope(doc.as<JsonObject>(), *base, cand, err);
  memset(base, 0, sizeof(SystemConfig));   // kimlik alanları öbekte kalmasın
  free(base);
  if (!ok) {
    setCode(out, ApplyResult::INVALID, err.code ? err.code : "invalid", err.path);
    return false;
  }
  return true;
}

ApplyOutcome applyOnLoop(const TplCandidate& cand, bool viaLan) {
  ApplyOutcome o;
  memset(&o, 0, sizeof(o));
  auto& sm = safety::SafetyManager::instance();
  auto& cm = ConfigManager::instance();
  const uint8_t via = viaLan ? safety::VIA_LAN : safety::VIA_CLI;

  if (!sm.lockWriter(100)) {               // tek öğeli yama yazıcısı sürüyor: sonra yeniden denensin
    outcomeOf(o, ApplyResult::INTERNAL);
    return o;
  }
  Work* w = (Work*)malloc(sizeof(Work));
  if (!w) {
    sm.unlockWriter();
    outcomeOf(o, ApplyResult::INTERNAL);
    return o;
  }
  uint64_t guard = 0, diHist = 0;
  if (!sm.copyConfig(w->cur, &guard, &diHist)) {
    free(w);
    sm.unlockWriter();
    outcomeOf(o, ApplyResult::INTERNAL);
    return o;
  }

  ConfigManager::ConfigLock lk(cm);        // özyinelemeli; diğer yazarlar (Wi-Fi kaydı vb.) iş bitene dek bekler
  memcpy(&w->live, &cm.config, sizeof(SystemConfig));
  memcpy(&w->next, &cm.config, sizeof(SystemConfig));
  copyTemplateFields(w->next, cand.sys);
  w->next.validate();
  w->nextSafety = cand.safety;
  w->nextSafety.rev = w->cur.rev + 1;

  TplRecord oldRec, newRec;
  TemplateStore::get(oldRec);
  tplRecordClear(newRec);
  newRec.present = true;
  memcpy(newRec.id, cand.templateId, sizeof(newRec.id));
  newRec.ver = cand.version;
  memcpy(newRec.label, cand.label, sizeof(newRec.label));

  ApplyIn in;
  in.viaLan = viaLan;
  in.latched = sm.latchedMask() != 0;
  in.armed = sm.intrusionArmed();
  in.shutterMoving = shutterMovingNow();
  in.sysErr = safety::validateSystemChange(w->next, w->nextSafety, guard);
  in.lan = lanRule(w->cur, oldRec, cand.templateId, cand.version, w->nextSafety, diHist);
  const uint16_t sysE = sysConfigNvsEntries(w->live, w->next);
  const uint16_t tplE = tplNvsEntries(newRec.label);
  nvs_stats_t st;
  memset(&st, 0, sizeof(st));
  in.nvsRoom = nvs_get_stats(nullptr, &st) != ESP_OK || nvsRoomForTemplate((uint32_t)st.free_entries, w->nextSafety, sysE, tplE);
  const ApplyResult d = decideApply(in);
  if (d != ApplyResult::OK) {
    if (d == ApplyResult::CFG_INVALID) setCode(o, d, "cfg_invalid", "", safety::cfgErrText(in.sysErr));
    else outcomeOf(o, d);
    if (d == ApplyResult::STORAGE) {
      printf("[SABLON] NVS bos girdi yetersiz (%u bos, gereken %lu): uygulanmadi.\r\n", (unsigned)st.free_entries,
             (unsigned long)templateNvsNeed(w->nextSafety, sysE, tplE));
    }
    free(w);
    sm.unlockWriter();
    return o;
  }

  // ---- NVS (canlı RAM'e dokunulmaz) ----
  bool touched = false;
  bool ok = safety::SafetyStore::saveConfig(w->nextSafety, &touched, true);
  bool sysWritten = false, tplWritten = false;
  if (ok) {
    sysWritten = true;
    ok = cm.saveCandidate(w->next);
  }
  if (ok) {
    tplWritten = true;
    ok = TemplateStore::save(newRec);
  }
  bool live = false;
  if (ok) {
    // ---- Canlı: aynı loopTask turunda ana + güvenlik ----
    copyTemplateFields(cm.config, w->next);
    cm.config.validate();
    live = sm.applyReplacedOnLoop(w->nextSafety, via, SmartAutomation::instance().wantMask(), millis());
    if (!live) memcpy(&cm.config, &w->live, sizeof(SystemConfig));   // ana yapılandırma RAM'i geri
  }
  if (!ok || !live) {
    // Geri alma: yazılanlar eski değerlerine (güvenlik: pay denetimsiz [FW2-3]).
    if (tplWritten) TemplateStore::save(oldRec);
    if (sysWritten) cm.saveCandidate(w->live);
    if (touched) safety::SafetyStore::saveConfig(w->cur, nullptr, false);
    outcomeOf(o, !ok ? ApplyResult::STORAGE : (sm.latchedMask() ? ApplyResult::LATCHED : ApplyResult::INTERNAL));
    printf("[SABLON] Uygulanamadi (%s); onceki yapilandirma korundu.\r\n", o.code);
    free(w);
    sm.unlockWriter();
    return o;
  }
  TemplateStore::setRam(newRec, (uint32_t)(esp_timer_get_time() / 1000000ULL));
  o.r = ApplyResult::OK;
  snprintf(o.code, sizeof(o.code), "ok");
  o.rev = w->nextSafety.rev;
  printf("[SABLON] Uygulandi: %s v%lu (%s, %s), guvenlik rev %lu.\r\n", newRec.id, (unsigned long)newRec.ver, newRec.label,
         viaLan ? "lan" : "usb", (unsigned long)o.rev);
  free(w);
  sm.unlockWriter();
  MqttManager::instance().triggerPublish();
  return o;
}

}  // namespace tpl
