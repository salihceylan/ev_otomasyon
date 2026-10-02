#pragma once
// ============================================================================
// DiGate.h - Dijital giriş (duvar butonu) kapısı. SAF MANTIK (yalnızca <stdint.h>).
//
// SmartAutomation::handleDiEdge() hem yerel 8 GPIO'yu hem RS485 ek modül girişlerini AYNI kapıdan geçirir;
// bu sınıf kararı verir, test/test_di_gate PC'de doğrular (donanım/Arduino yok).
//
// ÜÇ KURAL:
//  1) 60 ms KARARLILIK süzgeci: ham seviye en az DEBOUNCE_MS boyunca değişmeden kalırsa kenar kabul edilir.
//     (Tek sabit; yerel ve ek modül girişleri için ayrı kopya yoktur. Ek modül ~120 ms'de bir örneklenir:
//     kabul için art arda iki aynı örnek gerekir.)
//  2) ÇOCUK KİLİDİ yalnızca YENİ BASIŞI engeller; BIRAKMA olayı ASLA yutulmaz. Her giriş için "bu basış işlendi
//     mi" biti (acted) tutulur:
//       - kilit AÇIKKEN işlenen MOMENTARY basış, kilit sonradan açılmış olsa bile bırakmada mutlaka KAPAT üretir
//         (aksi halde röle sonsuza dek açık kalırdı);
//       - kilit KAPALIYKEN (engellenen) basışın bırakması hiçbir şey yapmaz (kilit sonradan kalkarsa bile);
//         böylece uygulamadan açılmış bir lamba bayat bir KAPAT ile söndürülmez.
//  3) ÜRÜN KARARI (kullanıcı adına verildi): kilitliyken duvar anahtarı HAREKET HALİNDEKİ (veya ters yön için
//     bekleyen) panjuru DURDURABİLİR. Telefonla başlatılmış bir panjuru duvardan durduramamak sıkışma/çarpma
//     riskidir. Hareketi BAŞLATMA, röle açma/kapama ve toggle kilitliyken engelli kalır. Engellenen basışta
//     çağıran kısa bir bip verir (dropped=true). Kaçış yolları: seri CLI (CHILDLOCK OFF), local_key'li LAN HTTP,
//     servis modu/uygulama. "Elektrik gelince ışıklar KAPALI + kilit kalıcı" birleşimi gereği telefon bağlanana
//     kadar kimse duvardan ışık açamaz: bu TASARIM GEREĞİDİR (kilit nadir ayardır, NVS'te kalıcıdır).
// ============================================================================
#include <stdint.h>

namespace digate {

// ConfigManager.h DIMode ile aynı sayısal değerler (SmartAutomation.cpp static_assert ile eşleşmeyi doğrular)
enum : uint8_t {
  MODE_TOGGLE = 0,
  MODE_MOMENTARY = 1,
  MODE_SHUTTER_STEP = 2,
  MODE_SHUTTER_UP = 3,
  MODE_SHUTTER_DOWN = 4
};

enum Action : uint8_t {
  NONE = 0,
  RELAY_TOGGLE,
  RELAY_ON,
  RELAY_OFF,
  SHUTTER_STEP,
  SHUTTER_UP,
  SHUTTER_DOWN,
  SHUTTER_STOP
};

enum Edge : uint8_t { EDGE_NONE = 0, EDGE_PRESS = 1, EDGE_RELEASE = 2 };

struct Decision {
  Edge edge;
  Action action;
  bool dropped;      // çocuk kilidi bu BASIŞI engelledi (kullanıcıya kısa bip için)
};

class DiGate {
public:
  enum : uint8_t { MAX_INPUTS = 40 };
  enum : uint32_t { DEBOUNCE_MS = 60 };

  DiGate() : acted_(0), momentary_(0) {
    for (uint8_t i = 0; i < MAX_INPUTS; i++) { raw_[i] = false; stable_[i] = false; since_[i] = 0; }
  }

  // Başlangıç seviyesini kenar üretmeden kabul et (açılışta basılı düğme olay üretmez)
  void init(uint8_t idx, bool level, uint32_t now_ms) {
    if (idx >= MAX_INPUTS) return;
    raw_[idx] = level;
    stable_[idx] = level;
    since_[idx] = now_ms;
    clearActed(idx);
  }

  // Ham örnek: değer en az DEBOUNCE_MS boyunca değişmeden kalırsa kenar döner.
  Edge sample(uint8_t idx, bool closed, uint32_t now_ms) {
    if (idx >= MAX_INPUTS) return EDGE_NONE;
    if (closed != raw_[idx]) {                   // değişti: sayacı yeniden başlat
      raw_[idx] = closed;
      since_[idx] = now_ms;
      return EDGE_NONE;
    }
    if (closed == stable_[idx]) return EDGE_NONE;
    if ((uint32_t)(now_ms - since_[idx]) < DEBOUNCE_MS) return EDGE_NONE;   // taşmaya dayanıklı fark
    stable_[idx] = closed;
    return closed ? EDGE_PRESS : EDGE_RELEASE;
  }

  // Kabul edilmiş bir kenar için karar (kilit + acted biti burada işlenir).
  //   mode          : DIMode (0..4)
  //   childLock     : çocuk kilidi etkin mi
  //   shutterActive : hedef panjur hareket ediyor veya yön değişimi için bekliyor mu
  Decision decide(uint8_t idx, Edge edge, uint8_t mode, bool childLock, bool shutterActive) {
    Decision d;
    d.edge = edge;
    d.action = NONE;
    d.dropped = false;
    if (idx >= MAX_INPUTS || edge == EDGE_NONE) return d;

    if (edge == EDGE_PRESS) {
      clearActed(idx);
      const bool shutterMode = (mode == MODE_SHUTTER_STEP || mode == MODE_SHUTTER_UP || mode == MODE_SHUTTER_DOWN);

      if (childLock) {
        // Kilitliyken yalnızca DURDURMA serbest (bkz. başlık, kural 3); başlatma/röle/toggle engelli.
        if (shutterMode && shutterActive) {
          d.action = SHUTTER_STOP;
          acted_ |= maskOf(idx);                    // bırakmada yapılacak bir şey yok (MOMENTARY değil)
        } else {
          d.dropped = (mode <= MODE_SHUTTER_DOWN);   // geçerli bir mod: kullanıcıya "engellendi" geri bildirimi
        }
        return d;
      }

      switch (mode) {
        case MODE_TOGGLE:        d.action = RELAY_TOGGLE; break;
        case MODE_MOMENTARY:     d.action = RELAY_ON; momentary_ |= maskOf(idx); break;
        case MODE_SHUTTER_STEP:  d.action = SHUTTER_STEP; break;
        case MODE_SHUTTER_UP:    d.action = shutterActive ? SHUTTER_STOP : SHUTTER_UP; break;
        case MODE_SHUTTER_DOWN:  d.action = shutterActive ? SHUTTER_STOP : SHUTTER_DOWN; break;
        default: return d;                       // bilinmeyen mod: hiçbir şey yapma
      }
      acted_ |= maskOf(idx);
      return d;
    }

    // EDGE_RELEASE: çocuk kilidinden BAĞIMSIZ. Yalnızca işlenmiş bir MOMENTARY basışın karşılığı KAPAT'tır.
    // (Basış anındaki durum kullanılır: yapılandırma bırakmadan önce değişse bile röle açık kalmaz.)
    if (momentary_ & maskOf(idx)) d.action = RELAY_OFF;
    clearActed(idx);
    return d;
  }

  bool stable(uint8_t idx) const { return idx < MAX_INPUTS && stable_[idx]; }
  uint64_t stableMask() const {
    uint64_t m = 0;
    for (uint8_t i = 0; i < MAX_INPUTS; i++) if (stable_[i]) m |= (1ULL << i);
    return m;
  }
  bool acted(uint8_t idx) const { return idx < MAX_INPUTS && (acted_ & maskOf(idx)) != 0; }
  uint64_t actedMask() const { return acted_; }

private:
  static uint64_t maskOf(uint8_t idx) { return 1ULL << idx; }
  void clearActed(uint8_t idx) { acted_ &= ~maskOf(idx); momentary_ &= ~maskOf(idx); }

  bool raw_[MAX_INPUTS];
  bool stable_[MAX_INPUTS];
  uint32_t since_[MAX_INPUTS];
  uint64_t acted_;       // bit i: giriş i'nin son BASIŞI işlendi (kilitle engellenmedi)
  uint64_t momentary_;   // bit i: o basış bir MOMENTARY AÇ üretti (bırakmada KAPAT gerekir)
};

}  // namespace digate
