#pragma once
// ============================================================================
// template/TemplateRules.h - Şablon uygulamasının cihaz durumuna bağlı KARARLARI. SAF MANTIK (saf başlıklar; NVS/RTOS yok) ->
// PC'de test/test_template_rules ile sınanır. Bağlayıcı: template/TemplateApply.cpp (loopTask).
//
// Plan K-Ş3 / İP-2.4 / İP-2.5, README "Kartta uygulama zarfı":
//  * Kullanıcı kararı (2026-10-08, riskler anlatıldıktan sonra): K-Ş4 LAN gevşetme kuralı KALDIRILDI. LAN (POST /api/template/apply,
//    yerel anahtar) ve USB (seri TPL) AYNI kuralla uygular: geçerli her şablon, güvenli kipte / yarım işlemde de (ikisi de kurtarır).
//  * Her iki yolda yalnız durum denetimleri: kilitli bölge 409 zone_latched, kurulu hırsız alarmı 409 armed, panjur hareket halinde 409 busy, ana yapılandırma
//    açılış güvenli maskesiyle çelişiyorsa (validateSystemChange) 409 cfg_invalid, NVS payı yetmiyorsa 507 storage.
//  * NVS bütçesi (20 KB bölüm, 32 B girdi): güvenlik yapılandırmasının tamamı (configNvsEntries) + ana yapılandırmanın DEĞİŞEN anahtarları
//    + ahbu_tpl (id, ver, label) + kilit kaydı payı + çöp toplama sayfası. Tahmindir; sahada nvs_get_stats ile doğrulanmalı.
// ============================================================================
#include <stdint.h>
#include <string.h>
#include "SystemConfig.h"
#include "safety/SafetyConfig.h"

namespace tpl {

// Kartta yüklü şablon kaydı (NVS "ahbu_tpl").
struct TplRecord {
  bool present;
  char id[37];
  uint32_t ver;
  char label[32];
};

inline void tplRecordClear(TplRecord& r) { memset(&r, 0, sizeof(r)); }

// Kartın güvenlik yapılandırması durumu (SafetyManager + TemplateStore bayrakları): yalnız başarısız uygulamanın geri alma biçimi için.
struct SafetyState {
  bool stored;            // "ahbu_safety" ad alanına yapılandırma HİÇ yazıldı mı (açılışta vardı ya da sonradan yazıldı)
  bool usable;            // açılışta yapılandırma kullanılabilir (CRC + ana yapılandırmayla çapraz doğrulama) ya da sonradan uygulandı
  bool safeMode;          // güvenli kip (cfg_corrupt / latch_orphan / crash_loop)
  bool txnInterrupted;    // yarım kalmış şablon uygulaması ("ahbu_tpl/txn" açılışta işaretliydi; yeniden uygulanana dek)
};

// Başarısız uygulamada güvenlik bölümünün geri alınma biçimi (inceleme R1-2/R1-3):
//  * yapılandırma kullanılamıyordu (cfg_corrupt) ya da önceki şablon işlemi yarımdı -> "ver" geçersiz bırakılır (MARK_CORRUPT): boş/
//    varsayılan bir tabloyu "geçerli" diye yazmak güvenli kipten sessizce çıkarırdı;
//  * ad alanı hiç yazılmamıştı -> silinir (ERASE): kart fabrika durumunda kalır;
//  * aksi halde eski yapılandırma geri yazılır (REWRITE_OLD; pay denetimsiz [FW2-3]).
enum class SafetyRollback : uint8_t { REWRITE_OLD = 0, ERASE = 1, MARK_CORRUPT = 2 };

inline SafetyRollback safetyRollbackKind(const SafetyState& st) {
  if (!st.usable || st.txnInterrupted) return SafetyRollback::MARK_CORRUPT;
  if (!st.stored) return SafetyRollback::ERASE;
  return SafetyRollback::REWRITE_OLD;
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

// ahbu_tpl: "txn" (u8, işlem işareti) + "ver" (u32, önce 0 = geçersiz işaret, en son gerçek değer) + "id" (36) + "label".
inline uint16_t tplNvsEntries(const char* label) {
  return (uint16_t)(1 + 1 + nvsStrEntries(36) + nvsStrEntries(label ? strlen(label) : 0));
}

inline uint32_t templateNvsNeed(const safety::SafetyConfig& next, uint16_t sysEntries, uint16_t tplEntries) {
  return (uint32_t)safety::configNvsEntries(next) + sysEntries + tplEntries + safety::NVS_SAFETY_RESERVE_ENTRIES +
         safety::NVS_GC_PAGE_ENTRIES;
}

inline bool nvsRoomForTemplate(uint32_t freeEntries, const safety::SafetyConfig& next, uint16_t sysEntries, uint16_t tplEntries) {
  return freeEntries >= templateNvsNeed(next, sysEntries, tplEntries);
}

// ---- Uygulama kararı ---------------------------------------------------------------------------------------------
enum class ApplyResult : uint8_t { OK = 0, INVALID, LATCHED, ARMED, BUSY, CFG_INVALID, STORAGE, INTERNAL };

struct ApplyIn {
  bool latched;             // kilitli/arızalı bölge var
  bool armed;               // hırsız alarmı kurulu (kip != off)
  bool shutterMoving;       // herhangi bir panjur hareket ediyor / ölü zamanda
  safety::CfgErr sysErr;    // validateSystemChange(aday ana, aday güvenlik, açılış/kilit maskesi)
  bool nvsRoom;
};

// Öncelik: kilit -> kurulu alarm -> panjur -> çapraz doğrulama -> NVS payı. LAN ve seri yol AYNI karar (kullanıcı kararı 2026-10-08).
inline ApplyResult decideApply(const ApplyIn& in) {
  if (in.latched) return ApplyResult::LATCHED;
  if (in.armed) return ApplyResult::ARMED;
  if (in.shutterMoving) return ApplyResult::BUSY;
  if (in.sysErr != safety::CfgErr::OK) return ApplyResult::CFG_INVALID;
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
    case ApplyResult::LATCHED: return {409, "zone_latched"};
    case ApplyResult::ARMED: return {409, "armed"};
    case ApplyResult::BUSY: return {409, "busy"};
    case ApplyResult::CFG_INVALID: return {409, "cfg_invalid"};
    case ApplyResult::STORAGE: return {507, "storage"};
    default: return {503, "busy"};
  }
}

}  // namespace tpl
