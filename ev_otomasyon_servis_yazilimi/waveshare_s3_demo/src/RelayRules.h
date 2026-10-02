#pragma once
// ============================================================================
// RelayRules.h - Röle çıkış yazımı için SÜRÜCÜ SEVİYESİ emniyet kuralları. SAF MANTIK.
//
// ShutterFsm panjur durum makinesidir; bu sınıf ise onun HATALI olsa bile fiziksel çıkışı
// korur ("derinlemesine savunma"): TCA9554 `TCA_WriteOutputs()` ve harici RS485 rölelerine
// komut gönderen çıkış katmanı aynı InterlockGuard kuralını uygular (docs/CONTRACTS.md §4:
// "Bu kural sürücü seviyesinde (writeMask) de doğrulanır").
//
// Maske: bit i = röle i (0 tabanlı) enerjili. Panjur çifti p = (röle 2p = YUKARI, röle 2p+1 = AŞAĞI).
//
// Reddedilen yazımlar:
//   BOTH_ON          : bir panjur çiftinde iki yön aynı anda enerjili
//   DIRECT_REVERSAL  : tek yazımda YUKARI -> AŞAĞI (veya tersi), arada KAPALI yok
//   DEAD_TIME        : bir yönün kapanmasından sonra < 500 ms içinde herhangi bir yön enerjilenmek istedi
// KAPATMA yazımları (bitleri 0'a çeken) HİÇBİR ZAMAN reddedilmez.
// ============================================================================
#include <stdint.h>

class InterlockGuard {
public:
  enum Result : uint8_t { OK = 0, BOTH_ON = 1, DIRECT_REVERSAL = 2, DEAD_TIME = 3 };
  enum : uint32_t { DEAD_TIME_MS = 500 };
  enum : uint8_t { MAX_PAIRS = 20 };

  InterlockGuard() : hw_(0), pairMask_(0), haveOff_(0) {
    for (uint8_t i = 0; i < MAX_PAIRS; i++) offAt_[i] = 0;
  }

  // bit p = (2p, 2p+1) çifti panjur (yön kilidi uygulanır)
  void setShutterPairs(uint32_t pairMask) { pairMask_ = pairMask; }
  uint32_t shutterPairs() const { return pairMask_; }

  // Donanımda şu an (başarıyla yazılmış) maske
  uint64_t hw() const { return hw_; }
  void forceHw(uint64_t m) { hw_ = m; }

  // newMask yazılabilir mi? Durumu DEĞİŞTİRMEZ.
  Result check(uint64_t newMask, uint32_t now_ms) const {
    for (uint8_t p = 0; p < MAX_PAIRS; p++) {
      if (!(pairMask_ & (1UL << p))) continue;
      uint8_t o = (uint8_t)((hw_ >> (2 * p)) & 3ULL);
      uint8_t n = (uint8_t)((newMask >> (2 * p)) & 3ULL);
      if (n == 3) return BOTH_ON;
      if (o != 0 && n != 0 && o != n) return DIRECT_REVERSAL;
      if (o == 0 && n != 0 && ((haveOff_ >> p) & 1UL) && (uint32_t)(now_ms - offAt_[p]) < DEAD_TIME_MS) {
        return DEAD_TIME;
      }
    }
    return OK;
  }

  // Yazma BAŞARILI oldu: durumu güncelle, kapanma anlarını kaydet.
  void commit(uint64_t newMask, uint32_t now_ms) {
    for (uint8_t p = 0; p < MAX_PAIRS; p++) {
      uint8_t o = (uint8_t)((hw_ >> (2 * p)) & 3ULL);
      uint8_t n = (uint8_t)((newMask >> (2 * p)) & 3ULL);
      if (o != 0 && n == 0) {
        haveOff_ |= (1UL << p);
        offAt_[p] = now_ms;
      }
    }
    hw_ = newMask;
  }

  // Bir KAPAT yazımı ONAYLANDI (RS485 modülü yankıyı verdi): ilgili çiftin "son kapanma anı" HER ZAMAN yenilenir.
  // commit() yalnızca İNANILAN durumdaki AÇIK->KAPALI geçişlerini damgalar; oysa inanç yanlış olabilir (modül yankıyı
  // verip komutu uygulamamış, önceki KAPAT'ın yankısı kaybolmuş, başka bir master açmış...). Böyle durumlarda GERÇEK
  // kapanma tekrarlanan KAPAT ile olur ve 500 ms ölü zaman O andan sayılmalıdır. Yalnızca panjur çiftleri için anlamlıdır
  // (check() diğer çiftlere bakmaz); gereksiz yenileme en çok 500 ms gecikme demektir (güvenli yön).
  void noteOff(uint8_t relayIndex, uint32_t now_ms) {
    const uint8_t p = (uint8_t)(relayIndex / 2);
    if (p >= MAX_PAIRS) return;
    haveOff_ |= (1UL << p);
    offAt_[p] = now_ms;
  }

  // Tek röleyi açmak/kapatmak için yeni maske
  static uint64_t withRelay(uint64_t mask, uint8_t relayIndex, bool on) {
    uint64_t bit = 1ULL << relayIndex;
    return on ? (mask | bit) : (mask & ~bit);
  }

  static const char* resultText(Result r) {
    switch (r) {
      case OK: return "OK";
      case BOTH_ON: return "IKI YON ACIK";
      case DIRECT_REVERSAL: return "DOGRUDAN YON DEGISIMI";
      case DEAD_TIME: return "OLU ZAMAN (<500ms)";
      default: return "?";
    }
  }

private:
  uint64_t hw_;
  uint32_t pairMask_;
  uint32_t haveOff_;                 // bit p: offAt_[p] geçerli
  uint32_t offAt_[MAX_PAIRS];
};

// ============================================================================
// Röle çıkış katmanı KARAR kuralları (saf mantık; G/Ç yapan kod bunları çağırır)
// ============================================================================
namespace relayrules {

// ---------------------------------------------------------------------------------------------
// TCA9554: gölge kayıt ile FİZİKSEL çıkış ayrışması (WS_TCA9554PWR.cpp I2C okumalarını buraya verir).
// Çip sıfırlanması (brown-out) ya da rölenin düşmesi ile periyodik TCA_Verify arasında firmware, düşen röleyi hâlâ "AÇIK" sanır;
// 8 bitlik bir yazım onu ölü zamansız yeniden çekerdi. Kural: yazımdan ÖNCE donanım okunur, gölge donanıma EŞİTLENİR ve düşen
// bitler o yazımla YENİDEN ÇEKİLMEZ (InterlockGuard'a kapanma anı bildirilir: ölü zaman o andan başlar).
// Sürücü iki aşamada işler: (1) FİZİKSEL gerçeği (physical) hemen benimser (düzeltme yazımı başarısız olsa bile gölge/koruma
// gerçeği yansıtır), (2) fazla açık röleleri kapatır (newShadow); fazla açık bir PANJUR rölesinin AÇIK->KAPALI geçişi ancak bu iki
// aşamalı işlenişle damgalanır (ölü zaman o kapanmadan başlar).
// ---------------------------------------------------------------------------------------------
struct TcaResyncPlan {
  enum Kind : uint8_t {
    IN_SYNC = 0,      // gölge = donanım
    FIX_EXTRA = 1,    // gölgede KAPALI ama donanımda AÇIK bit(ler) var: kapatılır
    DROPPED = 2,      // gölgede AÇIK ama donanımda KAPALI (düşmüş) bit(ler) var: gölge donanıma çekilir, YENİDEN ÇEKİLMEZ
    CHIP_RESET = 3    // yön yazmacı sıfırlanmış (çıkışlar girişe döndü): önce çıkış 0x00, sonra yön geri yüklenir
  };
  Kind kind;
  uint8_t newShadow;    // gölgenin yeni değeri (donanımla uyumlu)
  uint8_t dropped;      // gölgede AÇIK sanılıp fiziksel olarak KAPALI bulunan bitler
  uint8_t physical;     // okuma anında FİZİKSEL olarak enerjili bitler (CHIP_RESET: pinler girişe döndü = 0x00; aksi halde okunan çıkış yazmacı)
  bool writeOut;        // çıkış yazmacına yazım gerekir (CHIP_RESET: 0x00; FIX_EXTRA/DROPPED+extra: newShadow)
  bool restoreConfig;   // yön yazmacı gölgedeki değere geri yazılmalı (yalnız CHIP_RESET)
};

inline TcaResyncPlan planTcaResync(uint8_t outHw, uint8_t cfgHw, uint8_t shadowOut, uint8_t shadowCfg) {
  TcaResyncPlan p;
  p.kind = TcaResyncPlan::IN_SYNC;
  p.newShadow = shadowOut;
  p.dropped = 0;
  p.physical = outHw;
  p.writeOut = false;
  p.restoreConfig = false;
  if (cfgHw != shadowCfg) {                       // çip sıfırlanmış: bütün "AÇIK" sanılan bitler düştü
    p.kind = TcaResyncPlan::CHIP_RESET;
    p.newShadow = 0x00;
    p.dropped = shadowOut;
    p.physical = 0x00;                            // çıkışlar girişe döndü: hiçbir röle enerjili değil
    p.writeOut = true;
    p.restoreConfig = true;
    return p;
  }
  if (outHw == shadowOut) return p;
  const uint8_t extra = (uint8_t)(outHw & ~shadowOut);      // donanımda AÇIK, gölgede KAPALI (TEHLİKELİ)
  const uint8_t missing = (uint8_t)(shadowOut & ~outHw);    // gölgede AÇIK, donanımda KAPALI (düşmüş)
  p.newShadow = (uint8_t)(shadowOut & outHw);               // ikisinin kesişimi: düşenler YENİDEN çekilmez, fazlalar kapanır
  p.dropped = missing;
  p.writeOut = (extra != 0);
  p.kind = (missing != 0) ? TcaResyncPlan::DROPPED : TcaResyncPlan::FIX_EXTRA;
  return p;
}

// Yerel TCA'da panjur çiftlerinin röle bitleri: çift p (maske biti p) = bit 2p (YUKARI) ve bit 2p+1 (AŞAĞI); yerel röleler 0..7 = en çok 4 çift.
inline uint8_t shutterRelayBits(uint32_t pairMask) {
  uint8_t m = 0;
  for (uint8_t p = 0; p < 4; p++) {
    if (pairMask & (1UL << p)) m = (uint8_t)(m | (3u << (2 * p)));
  }
  return m;
}

// Eşitleme için donanım OKUNAMADIĞINDA (3 denemede de I2C okuma hatası): yazımın "AÇIK bırakacağı" (gölgede zaten AÇIK) panjur röleleri
// DOĞRULANAMAZ; fiziksel olarak düşmüş olabilirler ve 8 bitlik yazım onları ölü zamansız yeniden çekerdi. Güvenli yön (DOĞRULANAMAYAN
// ENERJİ YOK): bu bitler yazımdan ÇIKARILIR (röle kapanır) ve "düşmüş" sayılır (üst katman o panjuru durdurur). Yeni enerjilenecek
// bitler (gölgede KAPALI) ve lamba röleleri bu kuraldan etkilenmez.
inline uint8_t unverifiedRetainedShutterBits(uint8_t mask, uint8_t shadowOut, uint32_t pairMask) {
  return (uint8_t)(mask & shadowOut & shutterRelayBits(pairMask));
}

// ---------------------------------------------------------------------------------------------
// Harici modül (RS485): bir rölenin FİZİKSEL kapatılması için KAPAT yazımı gerekir mi? (SmartAutomation::stepExtOutputs 1. geçiş)
//   want         istenen durum (açılması isteniyor mu)
//   hw/hwKnown   bilinen durum / durum teyitli mi
//   adoptPending ham TOGGLE sonrası: sonuç bilinmiyor, bir sonraki coil okumasında BENİMSENECEK
// ham TOGGLE ile açılan (istenmeyen ama BENİMSENECEK) röleyi bu geçiş kapatırsa röle ~10-20 ms çekip bırakırdı.
// ---------------------------------------------------------------------------------------------
inline bool extNeedsOffWrite(bool want, bool hw, bool hwKnown, bool adoptPending) {
  if (want) return false;            // açılması isteniyor
  if (adoptPending) return false;    // durum coil okumasında benimsenecek: KAPATMA
  return hw || !hwKnown;             // açık olabilir (bilinen AÇIK ya da bilinmiyor): KAPAT gönder
}

}  // namespace relayrules
