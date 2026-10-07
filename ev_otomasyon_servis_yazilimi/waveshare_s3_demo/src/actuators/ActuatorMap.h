#pragma once
// ============================================================================
// actuators/ActuatorMap.h - Mantıksal eylemci durumu -> röle seviyesi; açılış/kilit maskeleri; ham komut yön kuralı;
// ActuatorCore (vana/siren/fan/generic çalışma durumu, geri bildirim, siren süre bütçesi, iki röleli vana interlock'u).
// SAF MANTIK (yalnız <stdint.h>/<string.h>; saat parametre, (uint32_t)(now - t) karşılaştırması).
//
// Röle numaraları dış dünyada 1 tabanlıdır; maskelerde bit (röle-1) kullanılır (bit 0..39).
// Tek yazıcı ilkesi: ActuatorCore yalnız İSTENEN seviyeyi hesaplar; fiziksel yazımı SmartAutomation::stepOutputs yapar.
// ============================================================================
#include "actuators/ActuatorTypes.h"

namespace safety {

// "Vana KAPALI olsun" -> röle seviyesi. ENERGIZE_TO_CLOSE: true; DEENERGIZE_TO_CLOSE: false. (PULSE: seviyesi yok.)
inline bool relayLevelFor(const ActuatorConfig& a, bool closed) {
  if (a.close_mode == (uint8_t)CloseMode::ENERGIZE_TO_CLOSE) return closed;
  if (a.close_mode == (uint8_t)CloseMode::DEENERGIZE_TO_CLOSE) return !closed;
  return false;
}

inline uint64_t relayBit(uint8_t relay1) {
  return (relay1 >= 1 && relay1 <= MAX_RELAYS) ? (1ULL << (relay1 - 1)) : 0ULL;
}

inline uint64_t relayBits(const ActuatorConfig& a) {
  uint64_t m = relayBit(a.relay);
  if (isPulseValve(a)) m |= relayBit(a.relay2);
  return m;
}

inline uint64_t actuatorRelayMask(const ActuatorConfig* a, uint8_t n) {
  uint64_t m = 0;
  for (uint8_t i = 0; a && i < n; i++) m |= relayBits(a[i]);
  return m;
}

inline uint32_t pulseMs(const ActuatorConfig& a) {
  return (uint32_t)(a.run_limit_s ? a.run_limit_s : PULSE_DEFAULT_S) * 1000UL;
}

// Açılış maskesi (§5.1.6 madde 4; K-1, K-4, 7.2b-6): yapılandırmadan hesaplanan seviyeler (bit = enerjili).
//  - gaz vanası: her açılışta KAPALI (act_pos okunmaz),
//  - kilitli bölgedeki su vanası: KAPALI,
//  - diğer su vanası: son komut konumu (kayıt yoksa "bilinmiyor" = AÇIK kabul),
//  - iki röleli vana, siren, fan, generic: enerjisiz.
// Kilit kaydındaki maske bunun ÜSTÜNE applyLatchMask ile uygulanır (yapılandırmadan bağımsız) [Y-4].
inline uint64_t bootLevelMask(const ActuatorConfig* a, uint8_t n, uint8_t latchedZones, uint16_t posOpenBits, uint16_t posKnownBits) {
  uint64_t m = 0;
  for (uint8_t i = 0; a && i < n; i++) {
    const ActuatorConfig& c = a[i];
    if (!isValve(c) || isPulseValve(c)) continue;
    bool closed;
    if (isGasValve(c) || (c.zone_mask & latchedZones)) closed = true;
    else if (posKnownBits & (1u << i)) closed = !(posOpenBits & (1u << i));
    else closed = false;
    if (relayLevelFor(c, closed)) m |= relayBit(c.relay);
  }
  return m;
}

inline uint64_t applyLatchMask(uint64_t levels, uint64_t latchAssert, uint64_t latchLevel) {
  return (levels & ~latchAssert) | (latchLevel & latchAssert);
}

// Kalıcı açılış güvenli maskesi (NVS "ahbu_latch/safe_msk"; inceleme turu EM-1/EM-5): KAPALI komutlu vanalar (closedBits, bit i = eylemci i)
// ve BÜTÜN gaz vanaları (K-4: her açılışta kapalı). ENERGIZE_TO_CLOSE'da röle 1, DEENERGIZE_TO_CLOSE'da 0, iki röleli vanada AÇ rölesi 0
// (KAPAT darbesi verilmez: süre ister). Relay_Init (yapılandırma yüklenmeden önce) seviyeyi, güvenli kip (yapılandırma kullanılamıyor)
// maskenin tamamını dayatır. Siren/fan/generic girmez.
inline void bootSafeMasks(const ActuatorConfig* a, uint8_t n, uint16_t closedBits, uint64_t& assertMask, uint64_t& levelMask) {
  uint64_t as = 0, lv = 0;
  for (uint8_t i = 0; a && i < n && i < MAX_ACTUATORS; i++) {
    const ActuatorConfig& c = a[i];
    if (!isValve(c) || !(isGasValve(c) || (closedBits & (1u << i)))) continue;
    if (isPulseValve(c)) {
      as |= relayBit(c.relay2);
    } else {
      as |= relayBit(c.relay);
      if (relayLevelFor(c, true)) lv |= relayBit(c.relay);
    }
  }
  assertMask = as;
  levelMask = lv & as;
}

// TCA_SetSafeBits süzgeci: panjur çiftine ait bitler güvenlik yolundan ASLA kurulmaz (interlock bozulamaz).
inline uint8_t filterSafeBits(uint8_t mask, uint8_t shutterPairMask) {
  uint8_t deny = 0;
  for (uint8_t p = 0; p < 4; p++) if (shutterPairMask & (1u << p)) deny |= (uint8_t)(0x03u << (2 * p));
  return (uint8_t)(mask & ~deny);
}

// Ham röle komutu (RELAY_SET/TOGGLE, CLI, LAN /api/relay, ham RS485) için YÖN kuralı [O4][B15].
enum class RawDecision : uint8_t {
  NOT_ACTUATOR = 0,   // eylemci rölesi değil: bugünkü yol
  SAFE = 1,           // güvenli yöne gidiyor (vana kapat / sustur): kabul, çekirdeğe "kullanıcı kapattı" bildirilir
  NOOP = 2,           // iki röleli vananın AÇ rölesini bırakmak: zararsız, etkisiz kabul
  REJECT = 3          // açma yönü: actuator_relay
};
struct RawResult {
  RawDecision d;
  int8_t act;         // eylemci indeksi (0 tabanlı), yoksa -1
};

inline RawResult rawCommand(const ActuatorConfig* a, uint8_t n, uint8_t relay1, bool level) {
  RawResult r;
  r.d = RawDecision::NOT_ACTUATOR;
  r.act = -1;
  for (uint8_t i = 0; a && i < n; i++) {
    const ActuatorConfig& c = a[i];
    if (!(relayBits(c) & relayBit(relay1)) || relayBit(relay1) == 0) continue;
    r.act = (int8_t)i;
    if (isPulseValve(c)) {
      if (relay1 == c.relay) r.d = level ? RawDecision::SAFE : RawDecision::REJECT;
      else r.d = level ? RawDecision::REJECT : RawDecision::NOOP;
    } else if (isValve(c)) {
      r.d = (level == relayLevelFor(c, true)) ? RawDecision::SAFE : RawDecision::REJECT;
    } else {
      r.d = level ? RawDecision::REJECT : RawDecision::SAFE;
    }
    return r;
  }
  return r;
}

// ---------------------------------------------------------------------------------------------
// ActuatorCore: eylemcilerin çalışma durumu. SafetyCore komut verir; SafetyManager her turda levelMask()'i
// SmartAutomation::applySafetyOutput ile _want'a yazar (her turda yeniden dayatma, §2.3 madde 2).
// ---------------------------------------------------------------------------------------------
class ActuatorCore {
public:
  ActuatorCore() : cfg_(nullptr), n_(0), posDirty_(false) { memset(rt_, 0, sizeof(rt_)); }

  // posOpenBits/posKnownBits: NVS "ahbu_latch/act_pos" (bit i = eylemci i). Gaz vanası her açılışta kapalı [K-4].
  void configure(const ActuatorConfig* a, uint8_t n, uint16_t posOpenBits, uint16_t posKnownBits, uint32_t now_ms) {
    cfg_ = a;
    n_ = (n > MAX_ACTUATORS) ? (uint8_t)MAX_ACTUATORS : n;
    memset(rt_, 0, sizeof(rt_));
    posDirty_ = false;
    for (uint8_t i = 0; i < n_; i++) {
      Rt& r = rt_[i];
      r.cmdAt = now_ms;
      if (!isValve(cfg_[i])) continue;
      if (isGasValve(cfg_[i])) {
        r.known = true;
        r.closed = true;
      } else if (posKnownBits & (1u << i)) {
        r.known = true;
        r.closed = !(posOpenBits & (1u << i));
      }
    }
  }

  // Çalışırken yapılandırma yaması (inceleme turu EM-2/EM-3): configure() gibi kurar, ardından eski tablodaki AYNI eylemciye eşlenen satırın
  // (fromOld[j] = eski indeks, -1 = yeni) çalışma durumunu taşır: komut konumu (GAS_RESET ile açılmış gaz vanası dahil), geri bildirim
  // zamanlayıcısı ve arızası, iki röleli vananın darbesi, siren süre bütçesi. Eşleme (actuatorIdentityMap) geri bildirim girişini de
  // kimliğe katar: girişi değişen vana yeni sayılır. Yama vanayı kendiliğinden açıp kapatmaz, sireni yeniden çaldırmaz.
  void reconfigure(const ActuatorConfig* a, uint8_t n, uint16_t posOpenBits, uint16_t posKnownBits, const int8_t* fromOld, uint32_t now_ms) {
    Rt saved[MAX_ACTUATORS];
    const uint8_t oldN = n_;
    memcpy(saved, rt_, sizeof(saved));
    const bool dirty = posDirty_;
    configure(a, n, posOpenBits, posKnownBits, now_ms);
    posDirty_ = dirty;
    for (uint8_t j = 0; fromOld && j < n_; j++) {
      const int8_t i = fromOld[j];
      if (i >= 0 && i < (int8_t)oldN) rt_[j] = saved[i];
    }
  }

  uint8_t count() const { return n_; }
  const ActuatorConfig* config(uint8_t i) const { return (cfg_ && i < n_) ? &cfg_[i] : nullptr; }

  // Vana komutu (closed=true: kapat). İki röleli vanada darbe başlatır (interlock + ölü zaman).
  void commandValve(uint8_t i, bool closed, uint32_t now_ms) {
    if (i >= n_ || !isValve(cfg_[i])) return;
    Rt& r = rt_[i];
    const bool changed = !r.known || r.closed != closed;
    if (changed) posDirty_ = true;
    if (changed || !r.known) {
      r.cmdAt = now_ms;
      r.fbMs = 0;
    }
    r.known = true;
    r.closed = closed;
    if (isPulseValve(cfg_[i])) pulseCommand(r, closed ? PS_RUN_CLOSE : PS_RUN_OPEN, now_ms);
  }

  // Siren/fan/generic aç-kapa isteği. Siren çıkışı ayrıca run_limit_s bütçesiyle sınırlanır.
  void commandSwitch(uint8_t i, bool on, uint32_t now_ms) {
    if (i >= n_ || isValve(cfg_[i])) return;
    Rt& r = rt_[i];
    if (on && !r.on) r.lastTick = now_ms;
    r.on = on;
  }

  // Geri bildirim DI'sinin kararlı seviyesi (aktif = kontak kapalı). Her turda.
  void setFeedback(uint8_t i, bool diActive) {
    if (i >= n_ || cfg_[i].fb_di == 0) return;
    rt_[i].fbSeen = true;
    rt_[i].fbActive = diActive;
  }

  void tick(uint32_t now_ms) {
    for (uint8_t i = 0; i < n_; i++) {
      const ActuatorConfig& c = cfg_[i];
      Rt& r = rt_[i];
      if (isPulseValve(c)) pulseTick(c, r, now_ms);
      if (isValve(c)) {
        const bool fbc = fbClosed(i);
        if (hasFb(i) && r.closed && fbc && r.fbMs == 0) r.fbMs = (uint32_t)(now_ms - r.cmdAt);
        if (!hasFb(i) || !r.closed || fbc) {
          r.fbFault = false;
        } else {
          const uint32_t tmo = (uint32_t)(c.fb_timeout_s ? c.fb_timeout_s : FB_TIMEOUT_DEFAULT_S) * 1000UL;
          if ((uint32_t)(now_ms - r.cmdAt) >= tmo) r.fbFault = true;
        }
      } else if (c.kind == (uint8_t)ActKind::SIREN) {
        if (sirenOutput(i)) {
          uint32_t v = r.sirenRunMs + (uint32_t)(now_ms - r.lastTick);
          r.sirenRunMs = (v < r.sirenRunMs) ? 0xFFFFFFFFu : v;
        }
        r.lastTick = now_ms;
      }
    }
  }

  // ---- çıktılar ----
  bool levelOf(uint8_t relay1) const {
    const uint64_t b = relayBit(relay1);
    for (uint8_t i = 0; b && i < n_; i++) {
      const ActuatorConfig& c = cfg_[i];
      if (!(relayBits(c) & b)) continue;
      const Rt& r = rt_[i];
      if (isPulseValve(c)) return (relay1 == c.relay) ? (r.ps == PS_RUN_CLOSE) : (r.ps == PS_RUN_OPEN);
      if (isValve(c)) return relayLevelFor(c, r.known ? r.closed : false);
      if (c.kind == (uint8_t)ActKind::SIREN) return sirenOutput(i);
      return r.on;
    }
    return false;
  }
  uint64_t relayMask() const { return actuatorRelayMask(cfg_, n_); }
  uint64_t levelMask() const {
    uint64_t m = 0;
    for (uint8_t r = 1; r <= MAX_RELAYS; r++) if ((relayMask() & relayBit(r)) && levelOf(r)) m |= relayBit(r);
    return m;
  }
  uint64_t fbDiMask() const {
    uint64_t m = 0;
    for (uint8_t i = 0; i < n_; i++) if (cfg_[i].fb_di >= 1 && cfg_[i].fb_di <= MAX_DI) m |= 1ULL << (cfg_[i].fb_di - 1);
    return m;
  }

  bool known(uint8_t i) const { return i < n_ && rt_[i].known; }
  bool closedCmd(uint8_t i) const { return i < n_ && rt_[i].known && rt_[i].closed; }
  bool on(uint8_t i) const { return i < n_ && rt_[i].on; }
  bool output(uint8_t i) const {
    if (i >= n_) return false;
    return cfg_[i].kind == (uint8_t)ActKind::SIREN ? sirenOutput(i) : rt_[i].on;
  }
  bool hasFb(uint8_t i) const { return i < n_ && cfg_[i].fb_di != 0; }
  bool fbSeen(uint8_t i) const { return i < n_ && rt_[i].fbSeen; }       // geri bildirim DI'si en az bir kez okundu
  bool fbClosed(uint8_t i) const {
    return i < n_ && rt_[i].fbSeen && (rt_[i].fbActive == (cfg_[i].fb_closed_active != 0));
  }
  bool fbFault(uint8_t i) const { return i < n_ && rt_[i].fbFault; }
  uint32_t fbMs(uint8_t i) const { return i < n_ ? rt_[i].fbMs : 0; }
  bool pulsing(uint8_t i) const { return i < n_ && rt_[i].ps != PS_IDLE; }

  ValvePos pos(uint8_t i) const {
    if (i >= n_ || !isValve(cfg_[i]) || !rt_[i].known) return ValvePos::UNKNOWN;
    const Rt& r = rt_[i];
    if (hasFb(i) && r.fbSeen) {
      const bool fbc = fbClosed(i);
      if (r.closed) return fbc ? ValvePos::CLOSED : ValvePos::CLOSING;
      return fbc ? ValvePos::OPENING : ValvePos::OPEN;
    }
    if (isPulseValve(cfg_[i]) && r.ps != PS_IDLE) return r.closed ? ValvePos::CLOSING : ValvePos::OPENING;
    return r.closed ? ValvePos::CMD_CLOSED : ValvePos::CMD_OPEN;
  }

  // NVS "act_pos" (bit i = açık) ve "bilinen" maskesi; yalnız vanalar.
  uint16_t posOpenBits() const {
    uint16_t m = 0;
    for (uint8_t i = 0; i < n_; i++) if (isValve(cfg_[i]) && rt_[i].known && !rt_[i].closed) m |= (uint16_t)(1u << i);
    return m;
  }
  uint16_t posKnownBits() const {
    uint16_t m = 0;
    for (uint8_t i = 0; i < n_; i++) if (isValve(cfg_[i]) && rt_[i].known) m |= (uint16_t)(1u << i);
    return m;
  }
  bool takePosDirty() { bool d = posDirty_; posDirty_ = false; return d; }

  // ---- siren süre bütçesi (kilit başına; NVS "siren_s") [O-8] ----
  void resetSirenBudget(uint8_t i) { if (i < n_) rt_[i].sirenRunMs = 0; }
  uint32_t sirenRunMs(uint8_t i) const { return i < n_ ? rt_[i].sirenRunMs : 0; }
  void setSirenRunMs(uint8_t i, uint32_t ms) { if (i < n_) rt_[i].sirenRunMs = ms; }
  bool sirenLimited(uint8_t i) const {
    if (i >= n_ || cfg_[i].kind != (uint8_t)ActKind::SIREN) return false;
    const uint32_t lim = (uint32_t)(cfg_[i].run_limit_s ? cfg_[i].run_limit_s : SIREN_RUN_DEFAULT_S) * 1000UL;
    return rt_[i].sirenRunMs >= lim;
  }

private:
  enum : uint8_t { PS_IDLE = 0, PS_RUN_CLOSE = 1, PS_RUN_OPEN = 2, PS_DEAD = 3 };
  struct Rt {
    uint32_t cmdAt;       // son yön değişimi (geri bildirim zaman aşımı buradan sayılır)
    uint32_t fbMs;        // kapat komutundan geri bildirimin "kapalı" görülmesine kadar geçen süre (0 = henüz yok)
    uint32_t sirenRunMs;
    uint32_t lastTick;
    uint32_t psAt;        // darbe başlangıcı ya da ölü zaman başlangıcı
    uint32_t lastOffAt;   // son darbenin bittiği an
    uint8_t ps;
    uint8_t psPending;
    bool everRan;
    bool known;
    bool closed;
    bool on;
    bool fbSeen;
    bool fbActive;
    bool fbFault;
  };

  bool sirenOutput(uint8_t i) const { return rt_[i].on && !sirenLimited(i); }

  void pulseCommand(Rt& r, uint8_t dir, uint32_t now_ms) {
    if (r.ps == dir) return;                                   // aynı yön: darbe uzamaz
    if (r.ps == PS_RUN_CLOSE || r.ps == PS_RUN_OPEN) {          // ters yön: önce ikisi de kapalı, ölü zaman
      r.ps = PS_DEAD;
      r.psAt = now_ms;
      r.psPending = dir;
      return;
    }
    if (r.ps == PS_DEAD) { r.psPending = dir; return; }
    if (r.everRan && (uint32_t)(now_ms - r.lastOffAt) < PULSE_DEAD_MS) {
      r.ps = PS_DEAD;
      r.psAt = r.lastOffAt;
      r.psPending = dir;
      return;
    }
    r.ps = dir;
    r.psAt = now_ms;
  }

  void pulseTick(const ActuatorConfig& c, Rt& r, uint32_t now_ms) {
    if (r.ps == PS_DEAD) {
      if ((uint32_t)(now_ms - r.psAt) >= PULSE_DEAD_MS) {
        r.ps = r.psPending;
        r.psAt = now_ms;
      }
    } else if (r.ps == PS_RUN_CLOSE || r.ps == PS_RUN_OPEN) {
      if ((uint32_t)(now_ms - r.psAt) >= pulseMs(c)) {
        r.ps = PS_IDLE;
        r.lastOffAt = now_ms;
        r.everRan = true;
      }
    }
  }

  const ActuatorConfig* cfg_;
  uint8_t n_;
  bool posDirty_;
  Rt rt_[MAX_ACTUATORS];
};

}  // namespace safety
