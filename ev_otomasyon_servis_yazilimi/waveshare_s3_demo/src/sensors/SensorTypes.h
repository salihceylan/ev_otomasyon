#pragma once
// ============================================================================
// sensors/SensorTypes.h - Güvenlik katmanı sensör türleri ve SensorSource arayüzü. SAF MANTIK
// (yalnızca <stdint.h>/<stddef.h>/<string.h>; Arduino/FreeRTOS/NVS yok, saat parametre olarak verilir).
//
// Tasarım: docs/superpowers/specs/2026-10-06-guvenlik-iklim-senaryo-mimarisi-design.md §2.5 (K2).
//  * SensorConfig 28 bayttır (NVS "ahbu_safety/sens" blob öğesi; boyut static_assert ile sabit).
//  * Kaynak (DI ya da köprü) güvenlik çekirdeğine görünmez: ikisi de SensorSource::sample() ile aynı
//    {level, ok} örneğini verir; SensorHub NC çevirmeyi, onay süzgecini ve sağlık (ok) semantiğini uygular.
//  * Güvenlik DI rolleri (ALARM_ACK / VALVE_CLOSE / GAS_RESET) sensör değil yerel kumandadır; DIMode'a
//    girmezler (DiGate ve static_assert korunur), sensör tablosunun `kind` alanındadır [B15][K-4].
// ============================================================================
#include <stdint.h>
#include <stddef.h>
#include <string.h>

namespace safety {

enum : uint8_t {
  MAX_SENSORS = 56,
  MAX_ACTUATORS = 16,
  MAX_ZONES = 4,
  MAX_DI = 40,
  MAX_BRIDGE = 16,
  MAX_RELAYS = 40,
  NAME_LEN = 20          // sensör/eylemci adı: 19 bayt + NUL
};

enum class SensorKind : uint8_t {
  NONE = 0,
  WATER = 1, GAS = 2, SMOKE = 3, DOOR = 4, WINDOW = 5, MOTION = 6, GENERIC = 7,
  // Güvenlik DI rolleri (sensör değil, yerel kumanda) [B15][K-4]
  ALARM_ACK = 16, VALVE_CLOSE = 17, GAS_RESET = 18
};

enum class SensorSrc : uint8_t { DI = 0, BRIDGE = 1 };

// SensorConfig.flags
enum : uint8_t {
  SF_REACT = 0x01,       // tepki etkin (bölge ıslaklığına girer)
  SF_TAMPER = 0x02,      // sabotaj/hat izleme (ileride)
  SF_FAULT_CLOSE = 0x04  // arıza (ok=false) vana kapatmayı tetikler (varsayılan: su 0, gaz 1, duman 0)
};

// Tehlike sınıfı bit maskesi: bölge ıslaklık/arıza özeti ve kilit türü bunu kullanır.
enum : uint8_t { HZ_WATER = 0x01, HZ_GAS = 0x02, HZ_SMOKE = 0x04, HZ_ALL = 0x07 };

struct SensorConfig {      // 28 B
  uint8_t src;             // SensorSrc
  uint8_t index;           // DI: 1..40 (DI no) | BRIDGE: 1..16 (köprü yuvası)
  uint8_t kind;            // SensorKind
  uint8_t zone;            // 1..4 (kontrol rollerinde 0 = tüm bölgeler)
  uint8_t active_open;     // 1: NC kontak (kontak AÇILINCA aktif). Gaz/duman için zorunlu [O-2]
  uint8_t flags;           // SF_*
  uint16_t confirm_ms;     // onay penceresinde gereken toplam aktif süre (0 = anında)
  char name[NAME_LEN];
};
static_assert(sizeof(SensorConfig) == 28, "SensorConfig NVS blob ogesi 28 bayt olmali");

struct SensorReport {      // köprü raporu (s_sensorQ öğesi)
  uint8_t slot;            // 1..16
  bool active;
  bool ok;
  uint32_t at_ms;
};

// Kaynaktan tek örnek. level: DI'de "kontak kapalı" (NC çevirmesi hub'dadır), köprüde bildirilen "aktif".
struct SensorSample {
  bool level;
  bool ok;
};

// K2: kablolu (DiSensor) ve köprülü (BridgeSensor) sensör aynı arayüzle okunur.
class SensorSource {
public:
  virtual ~SensorSource() {}
  virtual SensorSample sample(const SensorConfig& c, uint32_t now_ms) = 0;
};

inline uint8_t hazardOf(uint8_t kind) {
  switch (kind) {
    case (uint8_t)SensorKind::WATER: return HZ_WATER;
    case (uint8_t)SensorKind::GAS: return HZ_GAS;
    case (uint8_t)SensorKind::SMOKE: return HZ_SMOKE;
    default: return 0;
  }
}

inline bool isControlRole(uint8_t kind) {
  return kind == (uint8_t)SensorKind::ALARM_ACK || kind == (uint8_t)SensorKind::VALVE_CLOSE ||
         kind == (uint8_t)SensorKind::GAS_RESET;
}

inline bool isKnownKind(uint8_t kind) {
  return (kind >= (uint8_t)SensorKind::WATER && kind <= (uint8_t)SensorKind::GENERIC) || isControlRole(kind);
}

// §2.6: su 1000 ms / 3 sn pencere; gaz-duman 300 ms / 1 sn pencere; diğerleri anında (0).
inline uint16_t defaultConfirmMs(uint8_t kind) {
  const uint8_t hz = hazardOf(kind);
  if (hz == HZ_WATER) return 1000;
  if (hz == HZ_GAS || hz == HZ_SMOKE) return 300;
  return 0;
}

inline uint16_t confirmWindowMs(uint8_t kind) {
  const uint8_t hz = hazardOf(kind);
  if (hz == HZ_WATER) return 3000;
  if (hz == HZ_GAS || hz == HZ_SMOKE) return 1000;
  return 0;
}

inline uint8_t defaultFlags(uint8_t kind) {
  uint8_t f = SF_REACT;
  if (kind == (uint8_t)SensorKind::GAS) f |= SF_FAULT_CLOSE;
  return f;
}

// Durum/olay kimliği kodlaması: DI no (1..40) olduğu gibi, köprü yuvası 0x80 | yuva (1..16).
inline uint8_t sensorIdCode(const SensorConfig& c) {
  return (c.src == (uint8_t)SensorSrc::BRIDGE) ? (uint8_t)(0x80 | c.index) : c.index;
}

// "d3" / "b12" (en çok 3 karakter + NUL). out en az 5 bayt.
inline void sensorIdText(uint8_t code, char* out) {
  uint8_t n = (uint8_t)(code & 0x7F);
  uint8_t p = 0;
  out[p++] = (code & 0x80) ? 'b' : 'd';
  if (n >= 10) out[p++] = (char)('0' + n / 10);
  out[p++] = (char)('0' + n % 10);
  out[p] = '\0';
}

}  // namespace safety
