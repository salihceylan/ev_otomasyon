#pragma once
// ============================================================================
// template/TemplateRules.h - Şablon uygulamasının cihaz durumuna bağlı KARARLARI. SAF MANTIK (saf başlıklar; NVS/RTOS yok) ->
// PC'de test/test_template_rules ile sınanır. Bağlayıcı: template/TemplateApply.cpp (loopTask).
//
// Plan K-Ş3 / K-Ş4 / İP-2.4 / İP-2.5, README "Kartta uygulama zarfı":
//  * LAN (POST /api/template/apply, yerel anahtar) "gevşetme yasağı" (karar 7.2b-7) delinmez: kartın güvenlik yapılandırması FABRİKA
//    durumundaysa (sensör/eylemci yok + varsayılan politika) ya da AYNI şablonun aynı/yeni sürümü yalnız sıkılaştırıyorsa
//    (SafetyCfgEdit isLoosening, DI geçmişiyle) uygulanır; aksi 403 local_loosen_forbidden ("USB ile yazın").
//  * USB (seri TPL) fiziksel erişimdir: gevşetme kuralı uygulanmaz, provizyon gerekmez.
//  * Her iki yolda: kilitli bölge 409 zone_latched, kurulu hırsız alarmı 409 armed, panjur hareket halinde 409 busy, ana yapılandırma
//    açılış güvenli maskesiyle çelişiyorsa (validateSystemChange) 409 cfg_invalid, NVS payı yetmiyorsa 507 storage.
//  * NVS bütçesi (20 KB bölüm, 32 B girdi): güvenlik yapılandırmasının tamamı (configNvsEntries) + ana yapılandırmanın DEĞİŞEN anahtarları
//    + ahbu_tpl (id, ver, label) + kilit kaydı payı + çöp toplama sayfası. Tahmindir; sahada nvs_get_stats ile doğrulanmalı.
// ============================================================================
#include <stdint.h>
#include <string.h>
#include "SystemConfig.h"
#include "safety/SafetyConfig.h"
#include "safety/SafetyCfgEdit.h"

namespace tpl {

// Kartta yüklü şablon kaydı (NVS "ahbu_tpl").
struct TplRecord {
  bool present;
  char id[37];
  uint32_t ver;
  char label[32];
};

inline void tplRecordClear(TplRecord& r) { memset(&r, 0, sizeof(r)); }

// "Fabrika durumu": sensör ve eylemci tablosu boş, politika açık, kuruluk varsayılan, hırsız gecikmeleri varsayılan.
// Bölge adları ve ışık (dimmer) seçenekleri emniyet sürmez; karara girmez.
inline bool isFactorySafety(const safety::SafetyConfig& c) {
  return c.nSens == 0 && c.nAct == 0 && c.pol.policy_on == 1 && c.pol.dry_hold_ms == safety::DRY_HOLD_DEFAULT_MS && c.pol.exit_s == 0 &&
         c.pol.entry_s == 0;
}

enum class LanRule : uint8_t { ALLOW_FACTORY = 0, ALLOW_SAME_TEMPLATE = 1, FORBID = 2 };

inline LanRule lanRule(const safety::SafetyConfig& cur, const TplRecord& curTpl, const char* newId, uint32_t newVer,
                       const safety::SafetyConfig& next, uint64_t diHist) {
  if (isFactorySafety(cur)) return LanRule::ALLOW_FACTORY;
  if (curTpl.present && newId && strcmp(curTpl.id, newId) == 0 && newVer >= curTpl.ver && !safety::isLoosening(cur, next, diHist)) {
    return LanRule::ALLOW_SAME_TEMPLATE;
  }
  return LanRule::FORBID;
}

// ---- NVS bütçesi -----------------------------------------------------------------------------------------------
// Dizge girdisi: 1 başlık + ceil((uzunluk + NUL) / 32) veri girdisi. Tamsayı/bool: 1 girdi. Güncelleme önce yeni kopyayı yazar.
inline uint16_t nvsStrEntries(size_t len) { return (uint16_t)(1 + (len + 1 + 31) / 32); }

// ConfigManager::save() yalnız DEĞİŞEN anahtarları yazar; kanal sayısı artınca yeni kanalların anahtarları NVS'te hiç olmayabilir
// (hepsi sayılır). Kimlik/Wi-Fi/MQTT alanları şablonla değişmez (taban korunur) -> sayılmaz.
inline uint16_t sysConfigNvsEntries(const SystemConfig& o, const SystemConfig& n) {
  uint16_t e = 0;
  if (strcmp(o.device_name, n.device_name) != 0) e += nvsStrEntries(strlen(n.device_name));
  if (o.ext_module_enabled != n.ext_module_enabled) e++;
  if (o.ext_module_channels != n.ext_module_channels) e++;
  if (o.ext_module_address != n.ext_module_address) e++;
  const uint8_t oldR = o.totalRelays(), newR = n.totalRelays();
  for (uint8_t i = 0; i < newR; i++) {
    const bool fresh = i >= oldR;
    if (fresh || strcmp(o.relays[i].name, n.relays[i].name) != 0) e += nvsStrEntries(strlen(n.relays[i].name));
    if (fresh || o.relays[i].type != n.relays[i].type) e++;
    if (fresh || o.relays[i].runtime_sec != n.relays[i].runtime_sec) e++;
  }
  const uint8_t oldD = o.totalDIs(), newD = n.totalDIs();
  for (uint8_t i = 0; i < newD; i++) {
    const bool fresh = i >= oldD;
    if (fresh || strcmp(o.dis[i].name, n.dis[i].name) != 0) e += nvsStrEntries(strlen(n.dis[i].name));
    if (fresh || o.dis[i].target_relay != n.dis[i].target_relay) e++;
    if (fresh || o.dis[i].mode != n.dis[i].mode) e++;
  }
  return e;
}

// ahbu_tpl: "ver" (u32, önce 0 = geçersiz işaret, en son gerçek değer) + "id" (36) + "label".
inline uint16_t tplNvsEntries(const char* label) {
  return (uint16_t)(1 + nvsStrEntries(36) + nvsStrEntries(label ? strlen(label) : 0));
}

inline uint32_t templateNvsNeed(const safety::SafetyConfig& next, uint16_t sysEntries, uint16_t tplEntries) {
  return (uint32_t)safety::configNvsEntries(next) + sysEntries + tplEntries + safety::NVS_SAFETY_RESERVE_ENTRIES +
         safety::NVS_GC_PAGE_ENTRIES;
}

inline bool nvsRoomForTemplate(uint32_t freeEntries, const safety::SafetyConfig& next, uint16_t sysEntries, uint16_t tplEntries) {
  return freeEntries >= templateNvsNeed(next, sysEntries, tplEntries);
}

// ---- Uygulama kararı ---------------------------------------------------------------------------------------------
enum class ApplyResult : uint8_t { OK = 0, INVALID, LOOSEN, LATCHED, ARMED, BUSY, CFG_INVALID, STORAGE, INTERNAL };

struct ApplyIn {
  bool viaLan;              // true: POST /api/template/apply (yerel anahtar); false: seri TPL (fiziksel erişim)
  bool latched;             // kilitli/arızalı bölge var
  bool armed;               // hırsız alarmı kurulu (kip != off)
  bool shutterMoving;       // herhangi bir panjur hareket ediyor / ölü zamanda
  safety::CfgErr sysErr;    // validateSystemChange(aday ana, aday güvenlik, açılış/kilit maskesi)
  LanRule lan;              // yalnız viaLan iken anlamlı
  bool nvsRoom;
};

// Öncelik: kilit -> kurulu alarm -> panjur -> çapraz doğrulama -> LAN gevşetme -> NVS payı.
inline ApplyResult decideApply(const ApplyIn& in) {
  if (in.latched) return ApplyResult::LATCHED;
  if (in.armed) return ApplyResult::ARMED;
  if (in.shutterMoving) return ApplyResult::BUSY;
  if (in.sysErr != safety::CfgErr::OK) return ApplyResult::CFG_INVALID;
  if (in.viaLan && in.lan == LanRule::FORBID) return ApplyResult::LOOSEN;
  if (!in.nvsRoom) return ApplyResult::STORAGE;
  return ApplyResult::OK;
}

struct HttpErr {
  int status;
  const char* code;
};

// INVALID için kod ayrıştırıcıdan gelir (400); burada yalnız durum kodları.
inline HttpErr httpOf(ApplyResult r) {
  switch (r) {
    case ApplyResult::OK: return {200, "ok"};
    case ApplyResult::INVALID: return {400, "invalid"};
    case ApplyResult::LOOSEN: return {403, "local_loosen_forbidden"};
    case ApplyResult::LATCHED: return {409, "zone_latched"};
    case ApplyResult::ARMED: return {409, "armed"};
    case ApplyResult::BUSY: return {409, "busy"};
    case ApplyResult::CFG_INVALID: return {409, "cfg_invalid"};
    case ApplyResult::STORAGE: return {507, "storage"};
    default: return {503, "busy"};
  }
}

}  // namespace tpl
