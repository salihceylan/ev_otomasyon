#pragma once
// ============================================================================
// safety/ValveGuard.h - Bağımsız emniyet (ValveGuard) kararları. SAF MANTIK (saat parametre).
//
// Tasarım §5.1.5 [Y-8][B7], WP-F3:
//  * SafetyManager her loopTask turunda "güvenli tutma" maskelerini (SafeMasks) TEK yapı olarak, ShutterGuard'ın spinlock'u
//    altında yayınlar; guard görevi (Core 0, 50 ms) aynı kilit altında kopyalar (u64 okuma/yazma 32 bit Xtensa'da atomik değildir).
//  * Tutulan bitler yalnız KAPALI komutlu vanalardır (güvenli konum): ENERGIZE_TO_CLOSE'da röle 1, DEENERGIZE_TO_CLOSE'da 0, iki röleli
//    vanada AÇ rölesi 0 (KAPAT darbesine dokunulmaz). Siren/fan/generic tutulmaz: guard hiçbir zaman bir şey "açmaz", yalnız güvenli
//    konumu korur. Güvenli kipte kilit kaydındaki maske yapılandırmadan bağımsız eklenir (seviyesi kazanır).
//  * Yerel 8 röle: karşılaştırma DONANIMDAN okunan çıkış yazmacıyla yapılır (gölge yazılımsaldır; çip sıfırlansa da "1" der).
//    Fark: dayatılan bit 0 olmalıyken 1 -> TCA_ClearBits; 1 olmalıyken 0 -> TCA_SetSafeBits (panjur çifti bitleri ASLA kurulmaz).
//  * Ek modül: coil'lerin gerçek durumu guard görevinde bilinmez; yalnız loop beslemesi kesildiğinde (tur sayacı 1000 ms ilerlemedi)
//    ve en çok 1 sn'de bir körlemesine güvenli seviye yazılır (R-6). loopTask çalıştığı sürece garanti "her turda yeniden dayatma"dır.
// ============================================================================
#include <stdint.h>
#include "actuators/ActuatorTypes.h"
#include "actuators/ActuatorMap.h"

namespace safety {

enum : uint32_t { GUARD_STARVE_MS = 1000, GUARD_EXT_MIN_GAP_MS = 1000 };

// Guard'a yayınlanan maskeler. gen yalnız içerik değiştiğinde artar: guard donanımı okuduktan sonra gen'i yeniden karşılaştırır ve
// arada yayın olduysa (loop yeni bir karar verdi, yazımı henüz yapmamış olabilir) o turu atlar.
struct SafeMasks {
  uint64_t assertMask;      // tutulan röleler (bit = röle-1)
  uint64_t levelMask;       // ... ve güvenli seviyeleri
  uint32_t gen;
};

// closedBits: bit i = eylemci i KAPALI komutlu (ActuatorCore::closedCmd). latchAssert/latchLevel: güvenli kipteki kilit maskesi (yoksa 0).
inline void safeHoldMasks(const ActuatorConfig* a, uint8_t n, uint16_t closedBits, uint64_t latchAssert, uint64_t latchLevel,
                          uint64_t& assertMask, uint64_t& levelMask) {
  uint64_t as = 0, lv = 0;
  for (uint8_t i = 0; a && i < n && i < MAX_ACTUATORS; i++) {
    if (!isValve(a[i]) || !(closedBits & (1u << i))) continue;
    if (isPulseValve(a[i])) {
      as |= relayBit(a[i].relay2);
    } else {
      as |= relayBit(a[i].relay);
      if (relayLevelFor(a[i], true)) lv |= relayBit(a[i].relay);
    }
  }
  assertMask = as | latchAssert;
  levelMask = applyLatchMask(lv, latchAssert, latchLevel) & assertMask;
}

struct LocalGuardPlan {
  uint8_t clearBits;        // TCA_ClearBits
  uint8_t setBits;          // TCA_SetSafeBits (panjur çifti süzgecinden geçmiş)
};

// hwOut: DONANIMDAN okunan çıkış yazmacı. shutterPairMask: bit p = (röle 2p, 2p+1) panjur çifti.
inline LocalGuardPlan planLocalGuard(uint64_t assertMask, uint64_t levelMask, uint8_t hwOut, uint8_t shutterPairMask) {
  const uint8_t a = (uint8_t)(assertMask & 0xFF);
  const uint8_t l = (uint8_t)(levelMask & a);
  LocalGuardPlan p;
  p.clearBits = (uint8_t)(a & ~l & hwOut);
  p.setBits = filterSafeBits((uint8_t)(a & l & ~hwOut), shutterPairMask);
  return p;
}

// Ek modül röleleri (9..40 -> bit 0..31): açılacak ve kapatılacak coil'ler.
inline void extGuardBits(uint64_t assertMask, uint64_t levelMask, uint32_t& onBits, uint32_t& offBits) {
  const uint32_t a = (uint32_t)((assertMask >> 8) & 0xFFFFFFFFu);
  const uint32_t l = (uint32_t)((levelMask >> 8) & 0xFFFFFFFFu);
  onBits = a & l;
  offBits = a & ~l;
}

// Ek modül yazım hızı: loop beslemesi GUARD_STARVE_MS boyunca kesildiyse ve son yazımdan en az GUARD_EXT_MIN_GAP_MS geçtiyse.
class ExtGuardPacer {
public:
  ExtGuardPacer() : beat_(0), beatAt_(0), lastWrite_(0), haveBeat_(false), wrote_(false) {}

  // Guard her turda loop'un tur sayacını verir.
  void beat(uint32_t loopBeat, uint32_t now_ms) {
    if (!haveBeat_ || loopBeat != beat_) {
      beat_ = loopBeat;
      beatAt_ = now_ms;
      haveBeat_ = true;
    }
  }
  bool due(uint32_t now_ms) const {
    if (!haveBeat_ || (uint32_t)(now_ms - beatAt_) < GUARD_STARVE_MS) return false;
    return !wrote_ || (uint32_t)(now_ms - lastWrite_) >= GUARD_EXT_MIN_GAP_MS;
  }
  void wrote(uint32_t now_ms) {
    lastWrite_ = now_ms;
    wrote_ = true;
  }

private:
  uint32_t beat_;
  uint32_t beatAt_;
  uint32_t lastWrite_;
  bool haveBeat_;
  bool wrote_;
};

}  // namespace safety
