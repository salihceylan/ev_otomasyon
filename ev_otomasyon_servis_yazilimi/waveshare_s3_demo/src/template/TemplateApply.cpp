// template/TemplateApply.cpp - Şablonun uygulanması: işçi görev (ayrıştırma + NVS işlemi) + loopTask canlı takası. Bkz. TemplateApply.h.
#include "template/TemplateApply.h"
#include "template/TemplateStore.h"
#include "ConfigManager.h"
#include "SmartAutomation.h"
#include "MqttManager.h"
#include "safety/SafetyManager.h"
#include "safety/SafetyStore.h"
#include <Arduino.h>
#include <ArduinoJson.h>
#include <esp_timer.h>
#include <nvs.h>
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

namespace tpl {

namespace {

void setCode(ApplyOutcome& o, ApplyResult r, const char* code, const char* path = "", const char* detail = "") {
  o.r = r;
  snprintf(o.code, sizeof(o.code), "%s", code ? code : "");
  snprintf(o.path, sizeof(o.path), "%s", path ? path : "");
  sanitizePath(o.path);
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

struct Work {             // ~17 KB: öbekte
  SystemConfig live;      // NVS işlemi öncesi canlı ana yapılandırma (geri alma)
  SystemConfig next;      // aday ana yapılandırma
  SystemConfig swapBackup;// loopTask takasında canlı yapılandırmanın yedeği (takas reddinde geri)
  safety::SafetyConfig cur;
  safety::SafetyConfig nextSafety;
};

// ---- loopTask canlı takası (posta kutusu): 0 boş, 1 bekliyor, 2 yürüyor, 3 bitti ----
struct Swap {
  volatile uint8_t state;
  volatile uint8_t ok;
  uint8_t via;
  Work* w;
};
Swap g_swap;

// ---- işçi işi ----
struct Job {
  volatile bool running;
  volatile bool done;
  char* body;
  size_t len;
  bool viaLan;
  ApplyOutcome out;
  char id[TPL_ID_LEN + 1];
  uint32_t ver;
};
Job g_job;
portMUX_TYPE g_jobMux = portMUX_INITIALIZER_UNLOCKED;

// Güvenlik bölümünün + ana yapılandırmanın + ahbu_tpl'nin geri alınması. Hepsi başarılıysa (ve önceden yarım işlem yoksa) txn silinir.
void rollback(const Work& w, const SafetyState& st, const TplRecord& oldRec, bool safetyTouched, bool sysWritten, bool tplWritten) {
  bool ok = true;
  if (tplWritten) ok &= oldRec.present ? TemplateStore::save(oldRec) : TemplateStore::erase();
  if (sysWritten) ok &= ConfigManager::instance().saveCandidate(w.live);
  if (safetyTouched) {
    switch (safetyRollbackKind(st)) {
      case SafetyRollback::ERASE: ok &= safety::SafetyStore::eraseConfig(); break;
      case SafetyRollback::MARK_CORRUPT: ok &= safety::SafetyStore::markCorrupt(); break;
      default: ok &= safety::SafetyStore::saveConfig(w.cur, nullptr, false); break;   // pay denetimsiz [FW2-3]
    }
  }
  if (ok && !st.txnInterrupted) ok = TemplateStore::txnEnd();
  if (!ok) printf("[SABLON] UYARI: geri alma tamamlanamadi; txn isareti kaldi (sonraki acilis guvenli kip).\r\n");
}

ApplyOutcome applyWorker(const TplCandidate& cand, bool viaLan) {
  ApplyOutcome o;
  memset(&o, 0, sizeof(o));
  auto& sm = safety::SafetyManager::instance();
  auto& cm = ConfigManager::instance();

  if (!sm.lockWriter(2000)) {              // tek öğeli yama yazıcısı sürüyor
    outcomeOf(o, ApplyResult::INTERNAL);
    return o;
  }
  Work* w = (Work*)malloc(sizeof(Work));
  uint64_t guard = 0;
  if (!w || !sm.copyConfig(w->cur, &guard)) {
    free(w);
    sm.unlockWriter();
    outcomeOf(o, ApplyResult::INTERNAL);
    return o;
  }
  SafetyState st;
  st.stored = sm.cfgStored();
  st.usable = sm.cfgUsable();
  st.safeMode = sm.safeModeActive();
  st.txnInterrupted = TemplateStore::txnInterrupted();

  TplRecord oldRec, newRec;
  TemplateStore::get(oldRec);
  tplRecordClear(newRec);
  newRec.present = true;
  memcpy(newRec.id, cand.templateId, sizeof(newRec.id));
  newRec.ver = cand.version;
  memcpy(newRec.label, cand.label, sizeof(newRec.label));

  bool touched = false, sysWritten = false, tplWritten = false;
  {
    ConfigManager::ConfigLock lk(cm);      // canlı kopya + NVS işlemi boyunca diğer save() yazarları bekler
    memcpy(&w->live, &cm.config, sizeof(SystemConfig));
    memcpy(&w->next, &cm.config, sizeof(SystemConfig));
    copyTemplateFields(w->next, cand.sys);
    w->next.validate();
    w->nextSafety = cand.safety;
    w->nextSafety.rev = w->cur.rev + 1;

    ApplyIn in;
    in.latched = sm.latchedMask() != 0;
    in.armed = sm.intrusionArmed();
    in.shutterMoving = shutterMovingNow();
    in.sysErr = safety::validateSystemChange(w->next, w->nextSafety, guard, true);   // güvenlik tablosunu da yazar (v1.3.2 C1)
    const uint16_t sysE = sysConfigNvsEntries(w->live, w->next);
    const uint16_t tplE = tplNvsEntries(newRec.label);
    nvs_stats_t ns;
    memset(&ns, 0, sizeof(ns));
    in.nvsRoom = nvs_get_stats(nullptr, &ns) != ESP_OK || nvsRoomForTemplate((uint32_t)ns.free_entries, w->nextSafety, sysE, tplE);
    const ApplyResult d = decideApply(in);
    if (d != ApplyResult::OK) {
      if (d == ApplyResult::CFG_INVALID) setCode(o, d, "cfg_invalid", "", safety::cfgErrText(in.sysErr));
      else outcomeOf(o, d);
      if (d == ApplyResult::STORAGE) {
        printf("[SABLON] NVS bos girdi yetersiz (%u bos, gereken %lu): uygulanmadi.\r\n", (unsigned)ns.free_entries,
               (unsigned long)templateNvsNeed(w->nextSafety, sysE, tplE));
      }
      free(w);
      sm.unlockWriter();
      return o;
    }
    // ---- NVS işlemi: txn İLK, sonra güvenlik -> ana -> kayıt (canlı RAM'e dokunulmaz) ----
    bool ok = TemplateStore::txnBegin();
    if (ok) ok = safety::SafetyStore::saveConfig(w->nextSafety, &touched, true);
    if (ok) {
      sysWritten = true;
      ok = cm.saveCandidate(w->next);
    }
    if (ok) {
      tplWritten = true;
      ok = TemplateStore::save(newRec);
    }
    if (!ok) {
      rollback(*w, st, oldRec, touched, sysWritten, tplWritten);
      outcomeOf(o, ApplyResult::STORAGE);
      free(w);
      sm.unlockWriter();
      return o;
    }
  }

  // ---- Canlı takas: loopTask'a postala (ConfigLock bırakıldı: loopTask onu alır) ----
  g_swap.w = w;
  g_swap.via = viaLan ? safety::VIA_LAN : safety::VIA_CLI;
  g_swap.ok = 0;
  __sync_synchronize();
  g_swap.state = 1;
  const uint32_t t0 = millis();
  bool picked = true;
  while (g_swap.state != 3) {
    if (g_swap.state == 1 && (uint32_t)(millis() - t0) > 1500UL) {
      if (__sync_bool_compare_and_swap(&g_swap.state, (uint8_t)1, (uint8_t)0)) {   // loopTask almadı
        picked = false;
        break;
      }
    }
    vTaskDelay(pdMS_TO_TICKS(5));
  }
  const bool live = picked && g_swap.ok != 0;
  g_swap.state = 0;
  g_swap.w = nullptr;

  if (!live) {
    {
      ConfigManager::ConfigLock lk(cm);
      rollback(*w, st, oldRec, touched, sysWritten, tplWritten);
    }
    outcomeOf(o, !picked ? ApplyResult::INTERNAL
                         : (sm.latchedMask() ? ApplyResult::LATCHED : (shutterMovingNow() ? ApplyResult::BUSY : ApplyResult::INTERNAL)));
    printf("[SABLON] Canli takas yapilamadi (%s); NVS geri alindi.\r\n", o.code);
    free(w);
    sm.unlockWriter();
    return o;
  }

  // ---- Bitiş: ana yapılandırma NVS'i canlıdan yeniden eşitlenir, txn EN SON silinir ----
  {
    ConfigManager::ConfigLock lk(cm);
    const bool synced = cm.saveCandidate(cm.config);
    if (!synced || !TemplateStore::txnEnd()) {
      printf("[SABLON] UYARI: uygulandi ama NVS bitisi tamamlanamadi; txn isareti kaldi (sonraki acilis guvenli kip).\r\n");
    }
  }
  sm.noteCfgStored();
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

void workerTask(void*) {
  char* body = g_job.body;
  const size_t len = g_job.len;
  const bool viaLan = g_job.viaLan;
  g_job.body = nullptr;
  ApplyOutcome o;
  memset(&o, 0, sizeof(o));
  char id[TPL_ID_LEN + 1] = {0};
  uint32_t ver = 0;
  TplCandidate* cand = (TplCandidate*)malloc(sizeof(TplCandidate));
  if (!cand) {
    outcomeOf(o, ApplyResult::INTERNAL);
  } else if (parseBody(body, len, *cand, o)) {
    free(body);
    body = nullptr;
    memcpy(id, cand->templateId, sizeof(id));
    id[TPL_ID_LEN] = '\0';
    ver = cand->version;
    o = applyWorker(*cand, viaLan);
  }
  free(body);
  if (cand) {
    memset(cand, 0, sizeof(*cand));   // aday, kimlik alanlarının kopyasını taşır
    free(cand);
  }
  if (!viaLan) {                      // seri: yanıt satırı işçiden (araç "OK tpl_applied" / "ERR" bekler)
    if (o.r == ApplyResult::OK) {
      Serial.printf("OK tpl_applied %s %lu\r\n", id, (unsigned long)ver);
    } else {
      const char* extra = o.path[0] ? o.path : o.detail;
      if (extra[0]) Serial.printf("ERR %s %s\r\n", o.code, extra);
      else Serial.printf("ERR %s\r\n", o.code);
    }
  }
  taskENTER_CRITICAL(&g_jobMux);
  g_job.out = o;
  memcpy(g_job.id, id, sizeof(g_job.id));
  g_job.ver = ver;
  g_job.done = true;
  g_job.running = false;
  taskEXIT_CRITICAL(&g_jobMux);
  vTaskDelete(nullptr);
}

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

bool startApply(char* body, size_t len, bool viaLan) {
  taskENTER_CRITICAL(&g_jobMux);
  const bool busy = g_job.running;
  if (!busy) {
    g_job.running = true;
    g_job.done = false;
  }
  taskEXIT_CRITICAL(&g_jobMux);
  if (busy) {
    free(body);
    return false;
  }
  g_job.body = body;
  g_job.len = len;
  g_job.viaLan = viaLan;
  // Core 1, öncelik 0 (WebTask gibi): loopTask (öncelik 1) her uyandığında keser; TWDT'ye kayıtlı değil (NVS yazımı uzun sürebilir).
  if (xTaskCreatePinnedToCore(workerTask, "tpl_apply", 8192, nullptr, tskIDLE_PRIORITY, nullptr, 1) != pdPASS) {
    free(g_job.body);
    g_job.body = nullptr;
    taskENTER_CRITICAL(&g_jobMux);
    g_job.running = false;
    taskEXIT_CRITICAL(&g_jobMux);
    return false;
  }
  return true;
}

bool applyRunning() { return g_job.running; }

bool waitApply(uint32_t timeoutMs, ApplyOutcome& out, char* id, size_t idCap, uint32_t& ver) {
  const uint32_t t0 = millis();
  for (;;) {
    taskENTER_CRITICAL(&g_jobMux);
    const bool done = g_job.done && !g_job.running;
    if (done) {
      out = g_job.out;
      ver = g_job.ver;
      if (idCap) {
        strncpy(id, g_job.id, idCap - 1);
        id[idCap - 1] = '\0';
      }
    }
    taskEXIT_CRITICAL(&g_jobMux);
    if (done) return true;
    if ((uint32_t)(millis() - t0) >= timeoutMs) return false;
    vTaskDelay(pdMS_TO_TICKS(10));
  }
}

void serviceLoop() {
  if (g_swap.state != 1) return;
  if (!__sync_bool_compare_and_swap(&g_swap.state, (uint8_t)1, (uint8_t)2)) return;   // işçi vazgeçti
  Work* w = g_swap.w;
  bool ok = false;
  if (w) {
    auto& cm = ConfigManager::instance();
    auto& sm = safety::SafetyManager::instance();
    ConfigManager::ConfigLock lk(cm);
    // Karar anından bu yana durum değiştiyse (alarm kilitlendi / panjur hareket etti) takas yapılmaz; işçi NVS'i geri alır.
    if (sm.latchedMask() == 0 && !shutterMovingNow()) {
      memcpy(&w->swapBackup, &cm.config, sizeof(SystemConfig));
      copyTemplateFields(cm.config, w->next);
      cm.config.validate();
      ok = sm.applyReplacedOnLoop(w->nextSafety, g_swap.via, SmartAutomation::instance().wantMask(), millis());
      if (!ok) memcpy(&cm.config, &w->swapBackup, sizeof(SystemConfig));   // ana yapılandırma RAM'i geri
    }
  }
  g_swap.ok = ok ? 1 : 0;
  __sync_synchronize();
  g_swap.state = 3;
}

}  // namespace tpl
