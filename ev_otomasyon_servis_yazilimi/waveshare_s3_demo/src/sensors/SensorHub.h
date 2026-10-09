#pragma once
// ============================================================================
// sensors/SensorHub.h - Sensör özeti: NC çevirme, pencereli onay, sağlık (ok), bölge ıslaklık/kuruluk. SAF MANTIK.
//
// Tasarım §2.5-2.6:
//  * Seviye tabanlıdır (kenar değil): kaçırılmış kenar ya da açılışta zaten ıslak sensör ilk geçerli okumada yakalanır.
//  * Pencereli birikim [O-1]: pencere (su 3 sn, gaz/duman 1 sn) BUCKETS kovaya bölünür; son pencerede toplam aktif süre
//    >= confirm_ms ise sensör onaylı aktiftir. Kesintisiz süre aranmaz (damla deseni birikir), tek kısa sıçrama dolduramaz.
//    confirm_ms tür penceresinden uzunsa pencere büyür (windowMs; v1.3.2 fw-tarama-3): yoksa toplam hiç confirm_ms'e ulaşmazdı.
//  * ok=false sensör BİLİNMEYENDİR [Y-3]: ne ıslak ne kuru. Islaklığa girmez (SF_FAULT_CLOSE hariç), bölgenin kuruluk
//    sayacını durdurur. Arıza kenarı yalnız daha önce ok=true görülmüş sensörde üretilir (açılıştaki "henüz okunmadı"
//    hali arıza değildir).
//  * SF_FAULT_CLOSE: daha önce sağlıklı görülmüş ya da açılıştan BOOT_FAULT_GRACE_MS sonra hâlâ okunamayan sensörün
//    arızası, türünün tehlike sınıfı için "ıslak" sayılır (gaz: kablo koparsa vana kapanır).
//  * Kuruluk: bölgedeki BÜTÜN tehlike sensörleri ok && !onaylı && !ham aktif ise sayaç ilerler; tek bir aktif ya da
//    ok=false okuma sayacı sıfırlar.
//  * Kontrol rolleri (ALARM_ACK/VALVE_CLOSE/GAS_RESET): pasif->aktif kenarı bir kez bildirilir; ilk okuma kenar değildir.
// Zaman karşılaştırmaları (uint32_t)(now - t) biçimindedir (millis() taşmasına dayanıklı).
// ============================================================================
#include "sensors/SensorTypes.h"

namespace safety {

class SensorHub {
public:
  enum : uint8_t { BUCKETS = 8 };
  enum : uint32_t { BOOT_FAULT_GRACE_MS = 30000 };

  SensorHub() : cfg_(nullptr), n_(0), cfgAt_(0), faultEdges_(0), clearedEdges_(0), pressEdges_(0) {
    memset(rt_, 0, sizeof(rt_));
    memset(zone_, 0, sizeof(zone_));
  }

  // Tablo çağıranda kalır (SafetyConfig); çalışma durumu sıfırlanır. Sensörsüz bölge yapılandırma anından beri kurudur.
  void configure(const SensorConfig* cfgs, uint8_t n, uint32_t now_ms) {
    cfg_ = cfgs;
    n_ = (n > MAX_SENSORS) ? (uint8_t)MAX_SENSORS : n;
    cfgAt_ = now_ms;
    memset(rt_, 0, sizeof(rt_));
    for (uint8_t z = 0; z <= MAX_ZONES; z++) {
      zone_[z].dryValid = true;
      zone_[z].drySince = now_ms;
      zone_[z].wet = 0;
      zone_[z].fault = 0;
    }
    faultEdges_ = clearedEdges_ = pressEdges_ = 0;
  }

  // Onay penceresi (ms): tür penceresi, ya da confirm_ms için yeterli en küçük pencere (hangisi büyükse). Baş ilerleyince yeni kova boş
  // başlar ve toplam yalnız 7 tam kovayı tutar: 7 * (pencere / 8) >= confirm_ms olmalı -> ceil(confirm_ms / 7) * 8 (8'in katı). Tür
  // penceresinin 7/8'ine kadar (su 2625, gaz/duman 875 ms; varsayılanlar dahil) pencere ve zamanlama değişmez. 0: pencere yok (anında).
  static uint32_t windowMs(uint8_t kind, uint16_t confirmMs) {
    const uint32_t base = confirmWindowMs(kind);
    if (base == 0) return 0;
    const uint32_t need = ((uint32_t)confirmMs + (BUCKETS - 2)) / (BUCKETS - 1) * BUCKETS;
    return need > base ? need : base;
  }

  uint8_t count() const { return n_; }
  const SensorConfig* config(uint8_t slot) const { return (cfg_ && slot < n_) ? &cfg_[slot] : nullptr; }

  // Tek sensörün bu turdaki örneği. level: DI'de kontak kapalı, köprüde bildirilen aktif.
  void update(uint8_t slot, bool level, bool ok, uint32_t now_ms) {
    if (!cfg_ || slot >= n_) return;
    const SensorConfig& c = cfg_[slot];
    Rt& r = rt_[slot];
    const uint64_t bit = 1ULL << slot;
    const bool logical = (c.src == (uint8_t)SensorSrc::DI && c.active_open) ? !level : level;
    const uint32_t dt = r.seen ? (uint32_t)(now_ms - r.lastMs) : 0;

    if (!ok) {
      if (r.seen && r.ok) faultEdges_ |= bit;
      r.ok = false;
      r.confirmed = false;
      r.prevActive = false;
      r.raw = false;
      r.pressed = false;
      r.bucketsLive = false;
      memset(r.bucket, 0, sizeof(r.bucket));
      r.seen = true;
      r.lastMs = now_ms;
      return;
    }
    if (r.seen && !r.ok && r.everOk) clearedEdges_ |= bit;

    if (isControlRole(c.kind)) {
      if (r.seen && r.ok && logical && !r.pressed) {
        pressEdges_ |= bit;
        r.holdSince = now_ms;
      } else if (logical && !r.pressed) {
        r.holdSince = now_ms;          // açılışta zaten basılı: kenar değil, basılı tutma süresi buradan sayılır
      }
      r.pressed = logical;
      r.confirmed = logical;
    } else {
      const uint32_t window = windowMs(c.kind, c.confirm_ms);
      if (c.confirm_ms == 0 || window == 0) {
        r.confirmed = logical;
      } else {
        const uint32_t bucketLen = window / BUCKETS;
        if (!r.bucketsLive) {
          memset(r.bucket, 0, sizeof(r.bucket));
          r.head = 0;
          r.bucketStart = now_ms;
          r.bucketsLive = true;
        } else if ((uint32_t)(now_ms - r.bucketStart) >= window) {
          memset(r.bucket, 0, sizeof(r.bucket));
          r.head = 0;
          r.bucketStart = now_ms;
        } else {
          while ((uint32_t)(now_ms - r.bucketStart) >= bucketLen) {
            r.head = (uint8_t)((r.head + 1) % BUCKETS);
            r.bucket[r.head] = 0;
            r.bucketStart += bucketLen;
          }
        }
        if (r.ok && r.prevActive) {
          uint32_t add = (dt > window) ? window : dt;
          uint32_t v = (uint32_t)r.bucket[r.head] + add;
          r.bucket[r.head] = (uint16_t)(v > 0xFFFF ? 0xFFFF : v);
        }
        uint32_t sum = 0;
        for (uint8_t b = 0; b < BUCKETS; b++) sum += r.bucket[b];
        r.confirmed = sum >= c.confirm_ms;
      }
    }
    r.prevActive = logical;
    r.raw = logical;
    r.ok = true;
    r.everOk = true;
    r.seen = true;
    r.lastMs = now_ms;
  }

  // Bütün update() çağrılarından sonra: bölge özetleri.
  void finish(uint32_t now_ms) {
    bool allDry[MAX_ZONES + 1];
    for (uint8_t z = 0; z <= MAX_ZONES; z++) { zone_[z].wet = 0; zone_[z].fault = 0; allDry[z] = true; }
    for (uint8_t i = 0; i < n_; i++) {
      const SensorConfig& c = cfg_[i];
      const uint8_t hz = hazardOf(c.kind);
      if (hz == 0 || c.zone > MAX_ZONES) { rt_[i].wet = false; continue; }
      Rt& r = rt_[i];
      Zone& zs = zone_[c.zone];
      if (!r.ok) zs.fault |= hz;
      r.wet = wetContrib(i, now_ms);
      if (r.wet) zs.wet |= hz;
      if (!(r.ok && !r.confirmed && !r.raw)) allDry[c.zone] = false;
    }
    for (uint8_t z = 0; z <= MAX_ZONES; z++) {
      if (!allDry[z]) {
        zone_[z].dryValid = false;
      } else if (!zone_[z].dryValid) {
        zone_[z].dryValid = true;
        zone_[z].drySince = now_ms;
      }
    }
  }

  bool active(uint8_t slot) const { return slot < n_ && rt_[slot].ok && rt_[slot].confirmed; }
  bool ok(uint8_t slot) const { return slot < n_ && rt_[slot].ok; }
  bool rawActive(uint8_t slot) const { return slot < n_ && rt_[slot].ok && rt_[slot].raw; }
  // Açma izni için: sağlıklı, onaylı aktif değil ve ham seviye de pasif.
  bool idle(uint8_t slot) const { return slot < n_ && rt_[slot].ok && !rt_[slot].confirmed && !rt_[slot].raw; }

  uint64_t activeMask() const {
    uint64_t m = 0;
    for (uint8_t i = 0; i < n_; i++) if (active(i)) m |= (1ULL << i);
    return m;
  }
  uint64_t faultMask() const {
    uint64_t m = 0;
    for (uint8_t i = 0; i < n_; i++) if (!rt_[i].ok) m |= (1ULL << i);
    return m;
  }

  uint8_t zoneWet(uint8_t zone) const { return zone <= MAX_ZONES ? zone_[zone].wet : 0; }
  uint8_t zoneFault(uint8_t zone) const { return zone <= MAX_ZONES ? zone_[zone].fault : 0; }
  uint32_t zoneDryMs(uint8_t zone, uint32_t now_ms) const {
    if (zone > MAX_ZONES || !zone_[zone].dryValid) return 0;
    return (uint32_t)(now_ms - zone_[zone].drySince);
  }

  // Bölgede ıslaklığa katkı veren (hz maskesindeki) sensörlerin kimlik kodları (sensorIdCode), yuva sırasıyla.
  uint8_t zoneSources(uint8_t zone, uint8_t hzMask, uint8_t* ids, uint8_t max) const {
    uint8_t k = 0;
    for (uint8_t i = 0; i < n_ && k < max; i++) {
      const SensorConfig& c = cfg_[i];
      if (c.zone != zone || (hazardOf(c.kind) & hzMask) == 0) continue;
      if (!rt_[i].wet) continue;
      ids[k++] = sensorIdCode(c);
    }
    return k;
  }

  uint64_t takeFaultEdges() { uint64_t m = faultEdges_; faultEdges_ = 0; return m; }
  uint64_t takeFaultClearedEdges() { uint64_t m = clearedEdges_; clearedEdges_ = 0; return m; }
  uint64_t takeControlPresses() { uint64_t m = pressEdges_; pressEdges_ = 0; return m; }
  uint32_t heldMs(uint8_t slot, uint32_t now_ms) const {
    if (slot >= n_ || !rt_[slot].pressed) return 0;
    return (uint32_t)(now_ms - rt_[slot].holdSince);
  }

private:
  struct Rt {
    uint16_t bucket[BUCKETS];
    uint32_t bucketStart;
    uint32_t lastMs;
    uint32_t holdSince;
    uint8_t head;
    bool bucketsLive;
    bool seen;
    bool ok;
    bool everOk;
    bool raw;
    bool prevActive;
    bool confirmed;
    bool pressed;
    bool wet;                // son finish() kararı: bölge ıslaklığına katkı veriyor mu
  };
  struct Zone {
    uint32_t drySince;
    bool dryValid;
    uint8_t wet;
    uint8_t fault;
  };

  bool wetContrib(uint8_t i, uint32_t now_ms) const {
    const SensorConfig& c = cfg_[i];
    const Rt& r = rt_[i];
    if (!(c.flags & SF_REACT)) return false;
    if (r.ok) return r.confirmed;
    if (!(c.flags & SF_FAULT_CLOSE)) return false;
    return r.everOk || (uint32_t)(now_ms - cfgAt_) >= BOOT_FAULT_GRACE_MS;
  }
  const SensorConfig* cfg_;
  uint8_t n_;
  uint32_t cfgAt_;
  Rt rt_[MAX_SENSORS];
  Zone zone_[MAX_ZONES + 1];
  uint64_t faultEdges_;
  uint64_t clearedEdges_;
  uint64_t pressEdges_;
};

}  // namespace safety
