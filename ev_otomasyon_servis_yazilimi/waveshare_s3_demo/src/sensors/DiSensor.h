#pragma once
// ============================================================================
// sensors/DiSensor.h - Kablolu sensör kaynağı: DiGate'in KARARLI seviyesini okur. SAF MANTIK (DiGate.h saf).
//
// Tasarım §2.5:
//  * DiGate 60 ms süzgeci zaten uygular; burada kenar değil SEVİYE okunur (kaçırılmış kenar sensörü kör bırakmaz).
//  * Sağlık (ok) [Y-2][B6]: DiGate başlangıçta stable_=false ("kontak açık") ile başlar; NC sensör bunu "aktif" okurdu.
//      - yerel DI (1..8): ilk DI okuma turu tamamlanana kadar ok=false (setLocalReady),
//      - ek modül DI (9..40): ok = ek modül etkin && ilk okuma yapıldı && yanıt veriyor && tarama yok (setExtOk;
//        hesap SmartAutomation'da, burada yalnız bayrak).
//  * Sensöre çevrilen DI duvar butonu kararına (runDiDecision) hiç girmez (SmartAutomation::handleDiEdge maskesi);
//    MOMENTARY artığı ise maskeye alınırken temizlenir [B17] (releaseMomentary).
// ============================================================================
#include "sensors/SensorTypes.h"
#include "DiGate.h"

namespace safety {

class DiSensor : public SensorSource {
public:
  explicit DiSensor(const digate::DiGate* gate) : gate_(gate), localReady_(false), extOk_(false) {}

  void setLocalReady(bool v) { localReady_ = v; }
  void setExtOk(bool v) { extOk_ = v; }
  bool localReady() const { return localReady_; }
  bool extOk() const { return extOk_; }

  SensorSample sample(const SensorConfig& c, uint32_t now_ms) override {
    (void)now_ms;
    SensorSample s;
    s.level = false;
    s.ok = false;
    if (!gate_ || c.src != (uint8_t)SensorSrc::DI || c.index < 1 || c.index > MAX_DI) return s;
    const uint8_t idx = (uint8_t)(c.index - 1);
    s.ok = (idx < 8) ? localReady_ : extOk_;
    s.level = gate_->stable(idx);
    return s;
  }

  // Sensör tablosundaki DI kaynaklı satırların (kontrol rolleri dahil) bit maskesi: bit i = DI i+1.
  static uint64_t diMaskOf(const SensorConfig* cfgs, uint8_t n) {
    uint64_t m = 0;
    for (uint8_t i = 0; i < n; i++) {
      if (cfgs[i].src != (uint8_t)SensorSrc::DI || cfgs[i].index < 1 || cfgs[i].index > MAX_DI) continue;
      m |= 1ULL << (cfgs[i].index - 1);
    }
    return m;
  }

  // Maskeye alınan DI'lerin "basış işlendi" ve MOMENTARY bitlerini temizler [B17]. DiGate.h değiştirilmeden:
  // init() kararlı seviyeyi koruyarak acted/momentary bitlerini siler (kenar üretmez).
  static void releaseMomentary(digate::DiGate& gate, uint64_t mask, uint32_t now_ms) {
    for (uint8_t i = 0; i < MAX_DI; i++) {
      if (!(mask & (1ULL << i))) continue;
      if (gate.acted(i)) gate.init(i, gate.stable(i), now_ms);
    }
  }

private:
  const digate::DiGate* gate_;
  bool localReady_;
  bool extOk_;
};

}  // namespace safety
