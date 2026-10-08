#pragma once
// ============================================================================
// safety/SafetyConfig.h - Güvenlik yapılandırması (NVS "ahbu_safety"), kilit kaydı (NVS "ahbu_latch"), çapraz doğrulama,
// blob serileştirme + CRC32, çökme döngüsü sayacı ve açılış kipi kararı. SAF MANTIK (SystemConfig.h de saftır).
//
// Tasarım §2.4 (validate), §2.7 (NVS bütçesi, iki ad alanı), §4.1 (alarm sırasında yapılandırma), §4.3 (fabrika varsayılanları),
// §5.1.6 (kilit kaydı güvenli maskeleri taşır; güvenli kip).
//  * Yapılandırmanın asıl kaynağı panodaki NVS'tir (K5); bulut yalnız kopyadır. rev + CRC32 ile ilan edilir.
//  * Kilit kaydı (LatchRecord) fabrika sıfırlamasından, CRC bozulmasından ve yapılandırma silinmesinden SAĞ ÇIKAR: kilitlendiği
//    anda hesaplanan güvenli röle maskelerini (yerel 8 bit + ek 32 bit) taşır ve açılışta yapılandırmadan BAĞIMSIZ uygulanır [Y-4].
// ============================================================================
#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include "SystemConfig.h"
#include "sensors/SensorTypes.h"
#include "actuators/ActuatorTypes.h"
#include "actuators/ActuatorMap.h"

namespace safety {

enum : uint8_t { SAFETY_SCHEMA_VER = 1, ZONE_NAME_LEN = 16 };
enum : uint32_t {
  DRY_HOLD_DEFAULT_MS = 10000UL, DRY_HOLD_MIN_MS = 1000UL, DRY_HOLD_MAX_MS = 600000UL,
  CONFIRM_MIN_MS = 100, CONFIRM_MAX_MS = 10000,
  FB_TIMEOUT_MIN_S = 2, FB_TIMEOUT_MAX_S = 300,
  CRASH_STABLE_MS = 600000UL,        // 10 dk kesintisiz çalışma: çökme sayacı sıfırlanır
  CRASH_EXIT_MS = 1800000UL,         // güvenli kip (crash_loop) çıkışı: 30 dk kesintisiz çalışma
  CRASH_LOOP_COUNT = 3
};

struct Policy {             // 16 B ("ahbu_safety/pol")
  uint8_t policy_on;        // 1: güvenlik tepkileri açık (K5 varsayılan)
  uint8_t flags;
  uint16_t rsv;
  uint32_t dry_hold_ms;     // kuruluk bekleme süresi (vars. 10 sn)
  uint8_t exit_s;           // hırsız çıkış gecikmesi, sn (0 = varsayılan 45; F2.B.1; v1.2.0'da ayrılmış bayt, yeni NVS girdisi yok)
  uint8_t entry_s;          // hırsız giriş gecikmesi, sn (0 = varsayılan 30)
  uint8_t rsv2[6];
};
static_assert(sizeof(Policy) == 16, "Policy 16 bayt olmali");
static_assert(offsetof(Policy, exit_s) == 8 && offsetof(Policy, entry_s) == 9, "Policy gecikme baytlari v1.2.0 rsv2[0..1]");

// Hırsız gecikmelerinin etkin değeri (0 = varsayılan; F2.B.1). IntrusionCore ve gevşetme sınıflandırması (SafetyCfgEdit.h) ortak kullanır.
enum : uint8_t { EXIT_DEFAULT_S = 45, ENTRY_DEFAULT_S = 30 };
inline uint8_t exitDelayS(const Policy& p) { return p.exit_s ? p.exit_s : (uint8_t)EXIT_DEFAULT_S; }
inline uint8_t entryDelayS(const Policy& p) { return p.entry_s ? p.entry_s : (uint8_t)ENTRY_DEFAULT_S; }

struct ZoneConfig {         // 16 B; ad 15 bayt + NUL
  char name[ZONE_NAME_LEN];
};
static_assert(sizeof(ZoneConfig) == 16, "ZoneConfig 16 bayt olmali");

struct LightOpt {           // 4 B (K4)
  uint8_t dimmable;
  uint8_t dimmer_src;       // 0 = yok, 1 = modbus, 2 = köprü
  uint8_t dimmer_addr;
  uint8_t dimmer_ch;
};
static_assert(sizeof(LightOpt) == 4, "LightOpt 4 bayt olmali");

struct SafetyConfig {
  uint32_t rev;             // her yapılandırma değişiminde +1 (§4.2); CRC'ye girmez
  Policy pol;
  ZoneConfig zones[MAX_ZONES];
  uint8_t nSens;
  SensorConfig sens[MAX_SENSORS];
  uint8_t nAct;
  ActuatorConfig act[MAX_ACTUATORS];
  LightOpt light[MAX_RELAYS];

  // §4.3: politika AÇIK, kuruluk 10 sn, tek bölge "Ev"; sensör ve eylemci tablosu BOŞ.
  void setDefaults() {
    memset(this, 0, sizeof(*this));
    pol.policy_on = 1;
    pol.dry_hold_ms = DRY_HOLD_DEFAULT_MS;
    memcpy(zones[0].name, "Ev", 3);
  }
  bool empty() const { return nSens == 0 && nAct == 0; }
};

enum class CfgErr : uint8_t {
  OK = 0, COUNT, DRY_HOLD, NAME,
  SENSOR_SRC, SENSOR_KIND, SENSOR_ZONE, SENSOR_DI_RANGE, SENSOR_BRIDGE_RANGE, SENSOR_DUP, SENSOR_DI_IS_BUTTON,
  GAS_SMOKE_NOT_NC, CONFIRM_RANGE,
  ACT_KIND, ACT_RELAY_RANGE, ACT_RELAY_DUP, ACT_RELAY_SHUTTER, ACT_RELAY_IMPULSE, ACT_ZONE,
  VALVE_MEDIUM, VALVE_MODE, PULSE_RELAY2, PULSE_TIME, SIREN_RUN_LIMIT,
  FB_DI_RANGE, FB_DI_CONFLICT, FB_TIMEOUT_RANGE,
  NOT_FOUND, FULL, BAD_EDIT,         // tek öğeli yama (SafetyCfgEdit.h): öğe yok / tablo dolu / geçersiz yama
  ARM_KEY_NOT_NC                     // anahtarlı kontak NC olmalı (Faz 2 incelemesi RV-E3)
};

inline const char* cfgErrText(CfgErr e) {
  switch (e) {
    case CfgErr::OK: return "ok";
    case CfgErr::COUNT: return "count";
    case CfgErr::DRY_HOLD: return "dry_hold";
    case CfgErr::NAME: return "name";
    case CfgErr::SENSOR_SRC: return "sensor_src";
    case CfgErr::SENSOR_KIND: return "sensor_kind";
    case CfgErr::SENSOR_ZONE: return "sensor_zone";
    case CfgErr::SENSOR_DI_RANGE: return "sensor_di_range";
    case CfgErr::SENSOR_BRIDGE_RANGE: return "sensor_bridge_range";
    case CfgErr::SENSOR_DUP: return "sensor_dup";
    case CfgErr::SENSOR_DI_IS_BUTTON: return "sensor_di_is_button";
    case CfgErr::GAS_SMOKE_NOT_NC: return "gas_smoke_not_nc";
    case CfgErr::CONFIRM_RANGE: return "confirm_range";
    case CfgErr::ACT_KIND: return "act_kind";
    case CfgErr::ACT_RELAY_RANGE: return "act_relay_range";
    case CfgErr::ACT_RELAY_DUP: return "act_relay_dup";
    case CfgErr::ACT_RELAY_SHUTTER: return "act_relay_shutter";
    case CfgErr::ACT_RELAY_IMPULSE: return "act_relay_impulse";
    case CfgErr::ACT_ZONE: return "act_zone";
    case CfgErr::VALVE_MEDIUM: return "valve_medium";
    case CfgErr::VALVE_MODE: return "valve_mode";
    case CfgErr::PULSE_RELAY2: return "pulse_relay2";
    case CfgErr::PULSE_TIME: return "pulse_time";
    case CfgErr::SIREN_RUN_LIMIT: return "siren_run_limit";
    case CfgErr::FB_DI_RANGE: return "fb_di_range";
    case CfgErr::FB_DI_CONFLICT: return "fb_di_conflict";
    case CfgErr::FB_TIMEOUT_RANGE: return "fb_timeout_range";
    case CfgErr::NOT_FOUND: return "not_found";
    case CfgErr::FULL: return "full";
    case CfgErr::BAD_EDIT: return "bad_edit";
    case CfgErr::ARM_KEY_NOT_NC: return "arm_key_not_nc";
  }
  return "?";
}

namespace cfg_detail {
inline bool nameOk(const char* s, size_t cap) { return memchr(s, 0, cap) != nullptr; }
inline CfgErr relayUsable(const SystemConfig& sys, uint8_t relay1) {
  if (relay1 < 1 || relay1 > sys.totalRelays()) return CfgErr::ACT_RELAY_RANGE;
  const uint8_t t = sys.relays[relay1 - 1].type;
  if (t == RELAY_TYPE_SHUTTER_UP || t == RELAY_TYPE_SHUTTER_DOWN) return CfgErr::ACT_RELAY_SHUTTER;
  if (t == RELAY_TYPE_IMPULSE) return CfgErr::ACT_RELAY_IMPULSE;
  return CfgErr::OK;
}
}  // namespace cfg_detail

// Açılış güvenli maskesinin (bootSafeMasks, NVS "safe_msk") güvenli kipte dayatılabilecek bitleri (inceleme turu EM-5): yalnız ana
// yapılandırmada var olan ve panjur ya da darbe (impulse) rolesi OLMAYAN roleler. Yapılandırma ana yapılandırmayla uyuşmadığı için
// kullanılamıyorsa (ör. role panjura çevrildi) maske interlock'u ya da darbe rolesini bozamaz.
inline uint64_t bootMaskForSystem(const SystemConfig& sys, uint64_t mask) {
  const uint8_t totalR = sys.totalRelays();
  uint64_t out = 0;
  for (uint8_t r = 1; r <= totalR && r <= MAX_RELAYS && r <= MAX_TOTAL_RELAYS; r++) {
    const uint64_t b = 1ULL << (r - 1);
    if (!(mask & b)) continue;
    const uint8_t t = sys.relays[r - 1].type;
    if (t == RELAY_TYPE_SHUTTER_UP || t == RELAY_TYPE_SHUTTER_DOWN || t == RELAY_TYPE_IMPULSE) continue;
    out |= b;
  }
  return out;
}

// Çapraz doğrulama (§2.4, §2.3 madde 5): hem güvenlik yapılandırması hem ana yapılandırma (/api/config) değişiminde çağrılır.
// Boş güvenlik yapılandırmasında her zaman OK (lamba/panjur yolunu hiçbir zaman engellemez).
inline CfgErr validate(const SystemConfig& sys, const SafetyConfig& c) {
  using namespace cfg_detail;
  if (c.nSens > MAX_SENSORS || c.nAct > MAX_ACTUATORS) return CfgErr::COUNT;
  if (c.pol.dry_hold_ms < DRY_HOLD_MIN_MS || c.pol.dry_hold_ms > DRY_HOLD_MAX_MS) return CfgErr::DRY_HOLD;
  for (uint8_t z = 0; z < MAX_ZONES; z++) if (!nameOk(c.zones[z].name, ZONE_NAME_LEN)) return CfgErr::NAME;
  const uint8_t totalD = sys.totalDIs();
  uint64_t sensorDi = 0;
  uint32_t bridgeSeen = 0;
  for (uint8_t i = 0; i < c.nSens; i++) {
    const SensorConfig& s = c.sens[i];
    if (!nameOk(s.name, NAME_LEN)) return CfgErr::NAME;
    if (!isKnownKind(s.kind)) return CfgErr::SENSOR_KIND;
    const bool control = isControlRole(s.kind);
    if (s.src == (uint8_t)SensorSrc::DI) {
      if (s.index < 1 || s.index > totalD) return CfgErr::SENSOR_DI_RANGE;
      const uint64_t b = 1ULL << (s.index - 1);
      if (sensorDi & b) return CfgErr::SENSOR_DUP;
      sensorDi |= b;
      if (sys.dis[s.index - 1].target_relay != 0) return CfgErr::SENSOR_DI_IS_BUTTON;
    } else if (s.src == (uint8_t)SensorSrc::BRIDGE) {
      if (control) return CfgErr::SENSOR_SRC;          // yerel kumanda yalnız panodaki DI'den
      if (s.index < 1 || s.index > MAX_BRIDGE) return CfgErr::SENSOR_BRIDGE_RANGE;
      if (bridgeSeen & (1UL << (s.index - 1))) return CfgErr::SENSOR_DUP;
      bridgeSeen |= 1UL << (s.index - 1);
    } else {
      return CfgErr::SENSOR_SRC;
    }
    if (control ? (s.zone > MAX_ZONES) : (s.zone < 1 || s.zone > MAX_ZONES)) return CfgErr::SENSOR_ZONE;
    const uint8_t hz = hazardOf(s.kind);
    if ((hz == HZ_GAS || hz == HZ_SMOKE) && !s.active_open) return CfgErr::GAS_SMOKE_NOT_NC;   // [O-2]
    // Anahtarlı kontak yalnız NC (kurulu konumda kontak açık): kablo kesilince "aktif" okunur, kurma yönüne düşer; NO bağlantıda kablo
    // kesmek alarmı çözerdi (Faz 2 incelemesi RV-E3).
    if (s.kind == (uint8_t)SensorKind::ARM_KEY && !s.active_open) return CfgErr::ARM_KEY_NOT_NC;
    if (hz != 0 && (s.confirm_ms < CONFIRM_MIN_MS || s.confirm_ms > CONFIRM_MAX_MS)) return CfgErr::CONFIRM_RANGE;
    if (hz == 0 && s.confirm_ms > CONFIRM_MAX_MS) return CfgErr::CONFIRM_RANGE;
  }
  uint64_t used = 0;
  for (uint8_t i = 0; i < c.nAct; i++) {
    const ActuatorConfig& a = c.act[i];
    if (!nameOk(a.name, NAME_LEN)) return CfgErr::NAME;
    if (a.kind < (uint8_t)ActKind::VALVE || a.kind > (uint8_t)ActKind::GENERIC) return CfgErr::ACT_KIND;
    CfgErr e = relayUsable(sys, a.relay);
    if (e != CfgErr::OK) return e;
    if (used & relayBit(a.relay)) return CfgErr::ACT_RELAY_DUP;
    used |= relayBit(a.relay);
    if (a.kind != (uint8_t)ActKind::GENERIC && (a.zone_mask == 0 || a.zone_mask > 0x0F)) return CfgErr::ACT_ZONE;
    if (a.zone_mask > 0x0F) return CfgErr::ACT_ZONE;
    if (a.kind == (uint8_t)ActKind::VALVE) {
      if (a.medium != (uint8_t)Medium::WATER && a.medium != (uint8_t)Medium::GAS) return CfgErr::VALVE_MEDIUM;
      if (a.close_mode > (uint8_t)CloseMode::PULSE_TWO_RELAY) return CfgErr::VALVE_MODE;
      if (a.close_mode == (uint8_t)CloseMode::PULSE_TWO_RELAY) {
        if (a.relay2 == 0 || a.relay2 == a.relay) return CfgErr::PULSE_RELAY2;
        e = relayUsable(sys, a.relay2);
        if (e != CfgErr::OK) return e;
        if (used & relayBit(a.relay2)) return CfgErr::ACT_RELAY_DUP;
        used |= relayBit(a.relay2);
        if (a.run_limit_s > PULSE_MAX_S) return CfgErr::PULSE_TIME;
      }
      if (a.fb_di != 0) {
        if (a.fb_di > totalD) return CfgErr::FB_DI_RANGE;
        if ((sensorDi & (1ULL << (a.fb_di - 1))) || sys.dis[a.fb_di - 1].target_relay != 0) return CfgErr::FB_DI_CONFLICT;
        if (a.fb_timeout_s < FB_TIMEOUT_MIN_S || a.fb_timeout_s > FB_TIMEOUT_MAX_S) return CfgErr::FB_TIMEOUT_RANGE;
      }
    } else if (a.kind == (uint8_t)ActKind::SIREN) {
      if (a.run_limit_s < SIREN_RUN_MIN_S || a.run_limit_s > SIREN_RUN_MAX_S) return CfgErr::SIREN_RUN_LIMIT;   // [D-2]
    }
  }
  return CfgErr::OK;
}

// Ana yapılandırma değişiminin çapraz doğrulaması (WebPortal /api/config, seri CLI) [B3]. relayGuard: açılış güvenli maskesi (NVS "safe_msk")
// ile güvenlik çekirdeğinin kilit maskesinin birleşimi (bit = röle-1). Relay_Init bu bitleri ANA YAPILANDIRMA YÜKLENMEDEN önce uygular; bu
// yüzden maskedeki bir röle panjur ya da darbe rölesine çevrilemez. Güvenlik tablosu boş olsa bile (cfg_corrupt güvenli kipi) geçerlidir
// (inceleme turu 2 FW2-1). Var olmayan (kanal sayısı düşen) röle denetlenmez: bootMaskForSystem onu zaten dayatmaz.
inline CfgErr validateSystemChange(const SystemConfig& sys, const SafetyConfig& c, uint64_t relayGuard) {
  const CfgErr e = validate(sys, c);
  if (e != CfgErr::OK) return e;
  const uint8_t totalR = sys.totalRelays();
  for (uint8_t r = 1; r <= totalR && r <= MAX_RELAYS && r <= MAX_TOTAL_RELAYS; r++) {
    if (!(relayGuard & (1ULL << (r - 1)))) continue;
    const CfgErr u = cfg_detail::relayUsable(sys, r);
    if (u != CfgErr::OK) return u;
  }
  return CfgErr::OK;
}

// §4.1 [O-10]: kilitli (ya da arızalı) bölgeye dokunan değişiklik reddedilir (409 zone_latched). Eylemci röleye, sensör
// (kaynak, no) ikilisine göre eşlenir; kilitli bölgeye değen satır yeni yapılandırmada BİREBİR aynı kalmalıdır.
// Politika kapatma kabul edilir (mevcut kilidi kaldırmaz).
inline bool touchesLockedZones(const SafetyConfig& oldC, const SafetyConfig& newC, uint8_t lockedZoneMask) {
  if (lockedZoneMask == 0) return false;
  for (uint8_t pass = 0; pass < 2; pass++) {
    const SafetyConfig& a = pass ? newC : oldC;
    const SafetyConfig& b = pass ? oldC : newC;
    for (uint8_t i = 0; i < a.nAct; i++) {
      if (!(a.act[i].zone_mask & lockedZoneMask)) continue;
      bool same = false;
      for (uint8_t j = 0; j < b.nAct && !same; j++) same = memcmp(&a.act[i], &b.act[j], sizeof(ActuatorConfig)) == 0;
      if (!same) return true;
    }
    for (uint8_t i = 0; i < a.nSens; i++) {
      const SensorConfig& s = a.sens[i];
      if (s.zone < 1 || s.zone > MAX_ZONES || !(lockedZoneMask & (1u << (s.zone - 1))) || hazardOf(s.kind) == 0) continue;
      bool same = false;
      for (uint8_t j = 0; j < b.nSens && !same; j++) {
        const SensorConfig& t = b.sens[j];
        same = t.src == s.src && t.index == s.index && t.kind == s.kind && t.zone == s.zone && t.active_open == s.active_open &&
               t.flags == s.flags && t.confirm_ms == s.confirm_ms;
      }
      if (!same) return true;
    }
  }
  return false;
}

// ---------------------------------------------------------------------------------------------
// CRC32 (IEEE 802.3, yansıtılmış 0xEDB88320) ve blob = öğeler + CRC32 (küçük uçlu). Yalnız dolu yuvalar yazılır [B9].
// ---------------------------------------------------------------------------------------------
inline uint32_t crc32Update(uint32_t crc, const void* data, size_t len) {
  const uint8_t* p = (const uint8_t*)data;
  crc = ~crc;
  for (size_t i = 0; i < len; i++) {
    crc ^= p[i];
    for (uint8_t k = 0; k < 8; k++) crc = (crc >> 1) ^ (0xEDB88320u & (0u - (crc & 1u)));
  }
  return ~crc;
}
inline uint32_t crc32(const void* data, size_t len) { return crc32Update(0, data, len); }

inline size_t packBlob(const void* items, uint8_t n, size_t itemSize, uint8_t* out, size_t cap) {
  const size_t body = (size_t)n * itemSize;
  if (body + 4 > cap) return 0;
  if (body) memcpy(out, items, body);
  const uint32_t c = crc32(out, body);
  out[body] = (uint8_t)c;
  out[body + 1] = (uint8_t)(c >> 8);
  out[body + 2] = (uint8_t)(c >> 16);
  out[body + 3] = (uint8_t)(c >> 24);
  return body + 4;
}

// Dönüş: öğe sayısı, bozuk/uyumsuz blob'ta -1 (items değişmez).
inline int unpackBlob(const uint8_t* in, size_t len, size_t itemSize, void* items, uint8_t maxN) {
  if (len < 4 || (len - 4) % itemSize != 0) return -1;
  const size_t body = len - 4;
  const size_t n = body / itemSize;
  if (n > maxN) return -1;
  const uint32_t want = (uint32_t)in[body] | ((uint32_t)in[body + 1] << 8) | ((uint32_t)in[body + 2] << 16) | ((uint32_t)in[body + 3] << 24);
  if (crc32(in, body) != want) return -1;
  if (body) memcpy(items, in, body);
  return (int)n;
}

// State'te ilan edilen cfg.safety.crc (§4.2): pol + bölgeler + dolu sensör/eylemci yuvaları + ışık seçenekleri.
inline uint32_t configCrc(const SafetyConfig& c) {
  uint32_t crc = crc32Update(0, &c.pol, sizeof(c.pol));
  crc = crc32Update(crc, c.zones, sizeof(c.zones));
  crc = crc32Update(crc, &c.nSens, 1);
  crc = crc32Update(crc, c.sens, (size_t)c.nSens * sizeof(SensorConfig));
  crc = crc32Update(crc, &c.nAct, 1);
  crc = crc32Update(crc, c.act, (size_t)c.nAct * sizeof(ActuatorConfig));
  crc = crc32Update(crc, c.light, sizeof(c.light));
  return crc;
}

// NVS boş girdi bütçesi (inceleme turu RV-3; 32 B'lık girdiler). Blob güncellemesi önce YENİ kopyayı yazar, sonra eskisini siler: yazım anında
// tam kopya kadar boş girdi gerekir. Yapılandırma yazımı, kilit kaydı + act_pos + güvenli maske + siren güncellemeleri için ayrılan payı
// (NVS_SAFETY_RESERVE_ENTRIES) yiyemez; yetmiyorsa yazım "storage" ile reddedilir. Tahmin: blob = indeks + veri başlığı + veri girdileri
// (çok sayfalı blob'ta sayfa başına bir başlık daha gerekebilir; sahada nvs_get_stats ile doğrulanmalı).
// İnceleme turu 2 FW2-3: IDF 4.4'te nvs_stats_t.free_entries çöp toplama için boş tutulan sayfayı (126 girdi) da sayar ("available_entries"
// alanı yok); o sayfa yazıma kullanılamaz, bu yüzden paydan düşülür (NVS_GC_PAGE_ENTRIES). Başarısız yazımdan sonra eski yapılandırmanın
// geri yazımı bu denetimi ATLAR (SafetyStore::saveConfig checkRoom=false): "ver" geçersiz kalıp açılışın cfg_corrupt olması önlenir.
enum : uint16_t { NVS_SAFETY_RESERVE_ENTRIES = 16, NVS_GC_PAGE_ENTRIES = 126 };
inline uint16_t nvsBlobEntries(size_t len) { return (uint16_t)(2 + (len + 31) / 32); }
inline uint16_t configNvsEntries(const SafetyConfig& c) {
  uint16_t e = 3;                                                   // ver (geçersiz işaret + son) + rev
  e += nvsBlobEntries(sizeof(Policy) + 4);
  e += nvsBlobEntries(sizeof(c.zones) + 4);
  e += nvsBlobEntries((size_t)c.nSens * sizeof(SensorConfig) + 4);
  e += nvsBlobEntries((size_t)c.nAct * sizeof(ActuatorConfig) + 4);
  e += nvsBlobEntries(sizeof(c.light) + 4);
  return e;
}
inline bool nvsRoomForConfig(uint32_t freeEntries, const SafetyConfig& c) {
  return freeEntries >= (uint32_t)configNvsEntries(c) + NVS_SAFETY_RESERVE_ENTRIES + NVS_GC_PAGE_ENTRIES;
}

// ---------------------------------------------------------------------------------------------
// Kilit kaydı (NVS "ahbu_latch/latch", 164 B). YALNIZ GEÇİŞTE yazılır; fabrika sıfırlaması bu ad alanını SİLMEZ [Y-5].
// ---------------------------------------------------------------------------------------------
struct LatchZone {          // 32 B
  uint8_t st;               // ZoneSt (0 = NORMAL)
  uint8_t kinds;            // HZ_* maskesi
  uint8_t silenced;
  uint8_t acked;
  char aid[15];             // "<bn>-<n>" (NUL dahil) [B16]
  uint8_t nsrcs;
  uint32_t sinceEpoch;      // time_ok ise; değilse 0
  uint8_t srcs[8];          // sensorIdCode
};
static_assert(sizeof(LatchZone) == 32, "LatchZone 32 bayt olmali");

struct LatchMasks {         // 32 B: kilitlendiği anki güvenli röle maskeleri [Y-4]
  uint8_t localAssert;      // yerel 8 röle: dayatılan bitler
  uint8_t localLevel;       // ... ve seviyeleri
  uint16_t rsv;
  uint32_t extAssert;       // ek modül röleleri (röle 9..40 -> bit 0..31)
  uint32_t extLevel;
  uint8_t rsv2[20];
};
static_assert(sizeof(LatchMasks) == 32, "LatchMasks 32 bayt olmali");

struct LatchRecord {        // 164 B
  LatchZone z[MAX_ZONES];
  LatchMasks m;
  uint32_t crc;
};
static_assert(sizeof(LatchRecord) == 164, "LatchRecord 164 bayt olmali");

inline uint32_t latchCrc(const LatchRecord& r) { return crc32(&r, offsetof(LatchRecord, crc)); }
inline void latchSeal(LatchRecord& r) { r.crc = latchCrc(r); }
inline bool latchValid(const LatchRecord& r) { return r.crc == latchCrc(r); }
inline void latchClear(LatchRecord& r) { memset(&r, 0, sizeof(r)); latchSeal(r); }
inline uint8_t latchZoneMask(const LatchRecord& r) {
  uint8_t m = 0;
  for (uint8_t z = 0; z < MAX_ZONES; z++) if (r.z[z].st != 0) m |= (uint8_t)(1u << z);
  return m;
}
inline bool latchAny(const LatchRecord& r) { return latchZoneMask(r) != 0; }
inline uint64_t latchAssert64(const LatchRecord& r) { return (uint64_t)r.m.localAssert | ((uint64_t)r.m.extAssert << 8); }
inline uint64_t latchLevel64(const LatchRecord& r) { return ((uint64_t)r.m.localLevel | ((uint64_t)r.m.extLevel << 8)) & latchAssert64(r); }
inline void latchSetMasks(LatchRecord& r, uint64_t assertMask, uint64_t levelMask) {
  r.m.localAssert = (uint8_t)(assertMask & 0xFF);
  r.m.localLevel = (uint8_t)(levelMask & assertMask & 0xFF);
  r.m.extAssert = (uint32_t)((assertMask >> 8) & 0xFFFFFFFFu);
  r.m.extLevel = (uint32_t)(((levelMask & assertMask) >> 8) & 0xFFFFFFFFu);
}

// ---------------------------------------------------------------------------------------------
// Çökme döngüsü (NVS "ahbu_latch/crash", 8 B) [O-8]: beklenmeyen sıfırlama (TWDT, panik, brownout) sayılır; 10 dk kesintisiz
// çalışma sayacı sıfırlar. Arada kararlı çalışma olmadan >= 3 beklenmeyen sıfırlama = crash_loop (güvenli kip).
// ---------------------------------------------------------------------------------------------
struct CrashLog {
  uint8_t count;
  uint8_t stableWritten;    // bu açılışta sıfırlama yazıldı mı (RAM bayrağı; NVS'te 0 tutulur)
  uint16_t rsv;
  uint32_t rsv2;
};
static_assert(sizeof(CrashLog) == 8, "CrashLog 8 bayt olmali");

inline void crashClear(CrashLog& c) { memset(&c, 0, sizeof(c)); }
inline void crashOnBoot(CrashLog& c, bool unexpected) {
  c.stableWritten = 0;
  if (unexpected && c.count < 255) c.count++;
}
inline bool crashLoop(const CrashLog& c) { return c.count >= CRASH_LOOP_COUNT; }
// true: sayaç şimdi sıfırlandı, NVS'e yazılmalı (açılış başına en çok bir kez).
inline bool crashStableTick(CrashLog& c, uint32_t uptime_ms) {
  if (c.stableWritten || uptime_ms < CRASH_STABLE_MS) return false;
  c.stableWritten = 1;
  if (c.count == 0) return false;
  c.count = 0;
  return true;
}

// ---------------------------------------------------------------------------------------------
// Açılış kipi (§5.1.6 madde 3): güvenli kip nedeni.
// ---------------------------------------------------------------------------------------------
enum class SafeReason : uint8_t { NONE = 0, CFG_CORRUPT = 1, LATCH_ORPHAN = 2, CRASH_LOOP = 3 };

inline const char* safeReasonText(SafeReason r) {
  switch (r) {
    case SafeReason::CFG_CORRUPT: return "cfg_corrupt";
    case SafeReason::LATCH_ORPHAN: return "latch_orphan";
    case SafeReason::CRASH_LOOP: return "crash_loop";
    default: return "";
  }
}

// Kilit kaydının dayattığı röleler (need) eylemci tablosunun rölelerince (have) kapsanıyor mu? Röle istemeyen kilit (ör. yalnız
// sensörlü kurulum: eylemci yok, need = 0) her tabloyla kapsanır (pano-1). Açılış kararı (LATCH_ORPHAN) ve güvenli kipte yapılandırma
// uygulandıktan sonra çıkışın kullanılabilirliği (SafetyManager::applyConfigOnLoop -> setConfigUsable) aynı kuralı kullanır.
inline bool latchCovered(uint64_t need, uint64_t have) { return (need & ~have) == 0; }

// cfgPresent: NVS'te güvenlik yapılandırması var mı; cfgCrcOk: okunan blob'ların CRC'si doğru mu.
// latch: geçerli (CRC'si doğru) kilit kaydı ya da nullptr. cfg: yüklenebilen yapılandırma (bozuksa varsayılan).
// LATCH_ORPHAN yalnız kilit, tabloda OLMAYAN röleyi istiyorsa: eylemcisiz tabloyla röle istemeyen kilit normal kipte LATCHED bölge olarak
// geri yüklenir, onay + kurulukla temizlenir (eskiden "nAct == 0" tek başına güvenli kipti ve çıkış yolu yoktu; pano-1).
inline SafeReason decideBootMode(bool cfgPresent, bool cfgCrcOk, const LatchRecord* latch, const SafetyConfig& cfg, const CrashLog& crash) {
  if (cfgPresent && !cfgCrcOk) return SafeReason::CFG_CORRUPT;
  if (latch && latchAny(*latch)) {
    const uint64_t need = latchAssert64(*latch);
    const uint64_t have = actuatorRelayMask(cfg.act, cfg.nAct);
    if (!latchCovered(need, have)) return SafeReason::LATCH_ORPHAN;
  }
  if (crashLoop(crash)) return SafeReason::CRASH_LOOP;
  return SafeReason::NONE;
}

}  // namespace safety
