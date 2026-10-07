#pragma once
// ============================================================================
// sensors/BridgeSensor.h - Köprülü (Zigbee/Thread hub) sensör kaynağı. SAF MANTIK.
//
// Tasarım §2.5, karar 7.2b-1: bu sürümde yalnız arayüz + QA simülatör kaynağı; somut hub sürücüsü ayrı paket.
//  * Hub sürücüsü her rapor için SensorReport üretir (firmware'de s_sensorQ kuyruğu, SafetyManager turun başında boşaltır);
//    rapor buraya report() ile yazılır. Seviye tabanlıdır: düşen bir rapor bir sonrakiyle düzelir.
//  * Kalp atışı (yuva başına, varsayılan 15 dk): son rapordan bu yana süre aşılırsa ok=false (sensör bilinmeyen).
// ============================================================================
#include "sensors/SensorTypes.h"

namespace safety {

class BridgeSensor : public SensorSource {
public:
  enum : uint32_t { DEFAULT_HEARTBEAT_MS = 900000UL, MIN_HEARTBEAT_MS = 60000UL, MAX_HEARTBEAT_MS = 86400000UL };

  BridgeSensor() { reset(); }

  void reset() {
    for (uint8_t i = 0; i < MAX_BRIDGE; i++) {
      seen_[i] = false;
      active_[i] = false;
      ok_[i] = false;
      at_[i] = 0;
      hb_[i] = DEFAULT_HEARTBEAT_MS;
    }
  }

  void setHeartbeat(uint8_t slot, uint32_t ms) {
    if (slot < 1 || slot > MAX_BRIDGE) return;
    hb_[slot - 1] = ms;
  }

  void report(const SensorReport& r) {
    if (r.slot < 1 || r.slot > MAX_BRIDGE) return;
    const uint8_t i = (uint8_t)(r.slot - 1);
    seen_[i] = true;
    active_[i] = r.active;
    ok_[i] = r.ok;
    at_[i] = r.at_ms;
  }

  SensorSample sample(const SensorConfig& c, uint32_t now_ms) override {
    SensorSample s;
    s.level = false;
    s.ok = false;
    if (c.src != (uint8_t)SensorSrc::BRIDGE || c.index < 1 || c.index > MAX_BRIDGE) return s;
    const uint8_t i = (uint8_t)(c.index - 1);
    if (!seen_[i] || !ok_[i]) return s;
    if ((uint32_t)(now_ms - at_[i]) > hb_[i]) return s;
    s.ok = true;
    s.level = active_[i];
    return s;
  }

private:
  bool seen_[MAX_BRIDGE];
  bool active_[MAX_BRIDGE];
  bool ok_[MAX_BRIDGE];
  uint32_t at_[MAX_BRIDGE];
  uint32_t hb_[MAX_BRIDGE];
};

}  // namespace safety
