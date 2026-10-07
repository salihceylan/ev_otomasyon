#pragma once
// ============================================================================
// actuators/ActuatorTypes.h - Eylemci (K1) türleri. SAF MANTIK.
//
// Tasarım §2.4 + karar 7.2b-2 (iki röleli darbe vana İLK SÜRÜMDE):
//  * RelayType DEĞİŞMEZ; eylemci ataması ayrı tabloda (NVS "ahbu_safety/act"). State'te röle satırına yalnız `act` eklenir.
//  * Güvenlik eylemleri "mantıksal güvenli konum" üzerinden çalışır; röle seviyesi close_mode'dan çıkarılır.
//  * PULSE_TWO_RELAY: relay = KAPAT rölesi, relay2 = AÇ rölesi; run_limit_s = darbe süresi (vars. 15 sn). İki röle ASLA aynı
//    anda enerjili olmaz; yön değişiminde ikisi de kapalıyken PULSE_DEAD_MS beklenir (panjur interlock deseni).
//  * ActuatorConfig 36 bayttır (spec 32 B idi; relay2 + 3 ayrılmış bayt eklendi, bkz. spec "Uygulama notları (EKIP FW)").
// ============================================================================
#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include "sensors/SensorTypes.h"

namespace safety {

enum class ActKind : uint8_t { NONE = 0, VALVE = 1, SIREN = 2, FAN = 3, GENERIC = 4 };

enum class CloseMode : uint8_t {
  ENERGIZE_TO_CLOSE = 0,    // röle AÇIK = vana kapalı (NO selenoid / motorlu vana kapama hattı)
  DEENERGIZE_TO_CLOSE = 1,  // röle KAPALI = vana kapalı (NC selenoid: enerji kesilince kapanır, "fail-safe")
  PULSE_TWO_RELAY = 2       // iki röle: kapat/aç darbesi (motor konumunu korur)
};

enum class Medium : uint8_t { NONE = 0, WATER = 1, GAS = 2 };   // yalnız VALVE: vananın kestiği akışkan [K-3]

enum : uint8_t { AF_FAN_EXPROOF = 0x01 };   // FAN: kurulumcunun ex-proof/ATEX onayı (gaz alarmında açılabilir) [Y-1]

enum class ValvePos : uint8_t { UNKNOWN = 0, CLOSED = 1, CLOSING = 2, OPEN = 3, OPENING = 4, CMD_CLOSED = 5, CMD_OPEN = 6 };

enum : uint16_t {
  FB_TIMEOUT_DEFAULT_S = 60,
  SIREN_RUN_DEFAULT_S = 180,
  SIREN_RUN_MIN_S = 10,
  SIREN_RUN_MAX_S = 1800,
  PULSE_DEFAULT_S = 15,
  PULSE_MAX_S = 120
};
enum : uint32_t { PULSE_DEAD_MS = 500 };

struct ActuatorConfig {     // 36 B, NVS blob dizisinin bir öğesi
  uint8_t relay;            // 1 tabanlı röle (0 = boş satır); PULSE_TWO_RELAY'de KAPAT rölesi
  uint8_t kind;             // ActKind
  uint8_t close_mode;       // CloseMode (yalnız VALVE)
  uint8_t fb_di;            // geri bildirim DI'si, 1 tabanlı (0 = yok)
  uint8_t fb_closed_active; // 1: DI aktifken (kontak kapalı) vana kapalı demektir
  uint8_t zone_mask;        // bit z = bölge z+1 (en çok 4 bölge)
  uint16_t fb_timeout_s;    // geri bildirim beklemesi (vars. 60)
  uint16_t run_limit_s;     // SIREN: en uzun çalışma (TEK KAYNAK [D-2], 10..1800); PULSE vana: darbe süresi
  uint8_t medium;           // Medium (VALVE için zorunlu: WATER ya da GAS)
  uint8_t aflags;           // AF_*
  char name[NAME_LEN];
  uint8_t relay2;           // PULSE_TWO_RELAY: AÇ rölesi (1 tabanlı); diğerlerinde 0
  uint8_t rsv[3];
};
static_assert(sizeof(ActuatorConfig) == 36, "ActuatorConfig NVS blob ogesi 36 bayt olmali");

inline bool isValve(const ActuatorConfig& a) { return a.kind == (uint8_t)ActKind::VALVE; }
inline bool isPulseValve(const ActuatorConfig& a) {
  return isValve(a) && a.close_mode == (uint8_t)CloseMode::PULSE_TWO_RELAY;
}
inline bool isGasValve(const ActuatorConfig& a) { return isValve(a) && a.medium == (uint8_t)Medium::GAS; }

inline uint8_t mediumHazard(uint8_t medium) {
  if (medium == (uint8_t)Medium::WATER) return HZ_WATER;
  if (medium == (uint8_t)Medium::GAS) return HZ_GAS;
  return 0;
}

inline const char* actKindText(uint8_t kind) {
  switch (kind) {
    case (uint8_t)ActKind::VALVE: return "valve";
    case (uint8_t)ActKind::SIREN: return "siren";
    case (uint8_t)ActKind::FAN: return "fan";
    case (uint8_t)ActKind::GENERIC: return "generic";
    default: return "";
  }
}

inline const char* valvePosText(ValvePos p) {
  switch (p) {
    case ValvePos::CLOSED: return "closed";
    case ValvePos::CLOSING: return "closing";
    case ValvePos::OPEN: return "open";
    case ValvePos::OPENING: return "opening";
    case ValvePos::CMD_CLOSED: return "cmd_closed";
    case ValvePos::CMD_OPEN: return "cmd_open";
    default: return "unknown";
  }
}

}  // namespace safety
