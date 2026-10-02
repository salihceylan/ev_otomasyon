#pragma once
// ============================================================================
// ShutterFsm.h - Panjur (YUKARI/ASAGI role cifti) durum makinesi. SAF MANTIK.
//
// Bu sinif Arduino/FreeRTOS/NVS'e BAGIMLI DEGILDIR (yalnizca <stdint.h>). Saat disaridan
// (`now_ms`) verilir, sürücü disaridadir: sinif yalnizca "hangi rolelerin enerjili OLMASI
// GEREKTIGINI" (outMask) ve olaylari (events) üretir. Boylece PC'de (native Unity testleri,
// test/test_shutter_fsm) ayni kod calistirilabilir ve SmartAutomation ince bir sarmalayici olur.
//
// DEGISMEZ KURAL (docs/CONTRACTS.md §4, EVOTOMASYON_TASKS.md "Panjur Interlock"):
//   * outMask() hicbir kosulda 0x03 (YUKARI ve ASAGI ayni anda) olamaz. Cikis tek bir `dir_`
//     alanindan (0/1/2) türetilir; yapisal olarak iki yon ayni anda secilemez.
//   * Yon degisiminde (ve herhangi bir duruştan sonra yeniden kalkista) en az 500 ms ölü zaman.
//     Ölü zaman, rolelerin KAPALI oldugu sürücüce TEYIT EDILDIKTEN (tick(hw_off=true)) sonra
//     saylir; teyit gelmeden enerjileme yapilmaz.
//   * Tüm süre karsilastirmalari `uint32_t` farki ile yapilir (millis() 49,7 günde tasar).
//   * "Ölü zaman gecerli mi" bilgisi ayri bir bool'dur (eski kod `dead_time_start > 0` kullaniyordu;
//     millis()==0 aninda ölü zaman yok sayiliyordu).
//
// Konum modeli: 0 = tam kapali, 100 = tam acik. Konum süre üzerinden kestirilir (limit switch yok):
//   YUKARI: pos = start + elapsed*100/up_ms     ASAGI: pos = start - elapsed*100/down_ms
// ============================================================================
#include <stdint.h>

class ShutterFsm {
public:
  enum : uint32_t {
    MIN_DEAD_TIME_MS = 500,      // alt sinir: disaridan daha kisa deger verilse bile uygulanmaz
    DEFAULT_TRAVEL_MS = 20000,   // süre tanimsizsa (0) varsayilan tam yol süresi
    MAX_TRAVEL_MS = 300000,      // 300 sn (CONTRACTS: runtime 1..300)
    MIN_RUN_MS = 100             // bundan kisa hareket anlamsiz (role asinmasi)
  };
  enum : uint8_t { NO_TARGET = 255 };

  enum Dir : uint8_t { DIR_STOP = 0, DIR_UP = 1, DIR_DOWN = 2 };
  // outMask bitleri: DIR_UP == OUT_UP, DIR_DOWN == OUT_DOWN (outMask() dogrudan dir_'dir)
  enum : uint8_t { OUT_UP = 0x01, OUT_DOWN = 0x02 };

  enum Event : uint8_t {
    EV_STARTED      = 1 << 0,  // yeni hareket basladi (rolede enerjileme gerekir)
    EV_STOPPED      = 1 << 1,  // hareket durdu/iptal edildi (konum guncellendi)
    EV_DEAD_BEGIN   = 1 << 2,  // olu zaman basladi (yon degisimi/duruş sonrasi)
    EV_DEAD_END     = 1 << 3,  // olu zaman bitti
    EV_COMPLETED    = 1 << 4,  // süre dolumuyla hedefe/uca ulasildi
    EV_RETARGET     = 1 << 5,  // ayni yönde hedef degisti (role degismedi)
    EV_START_FAILED = 1 << 6   // enerjileme sürücüde basarisiz oldu, hareket iptal
  };

  ShutterFsm() { reset(); }

  void reset() {
    dir_ = DIR_STOP;
    pending_ = DIR_STOP;
    pend_target_ = NO_TARGET;
    dead_valid_ = false;
    restamp_ = false;
    dead_start_ = 0;
    hw_off_ = true;
    full_ = false;
    run_start_ = 0;
    start_ms_ = 0;
    dur_ms_ = 0;
    start_pos_ = 0;
    target_ = NO_TARGET;
    pos_ = 0;
    last_dir_ = DIR_STOP;
    up_ms_ = DEFAULT_TRAVEL_MS;
    down_ms_ = DEFAULT_TRAVEL_MS;
    dead_ms_ = MIN_DEAD_TIME_MS;
    over_ms_ = 2000;
    ev_ = 0;
  }

  // ------------------------------------------------------------------ yapilandirma
  // Yalnizca HAREKETSIZKEN (ve beklemede komut yokken) kabul edilir; aksi halde false (reddedilir).
  // up_ms/down_ms: tam yol süresi (0 => varsayilan 20 sn); dead_ms en az 500 ms'e yükseltilir.
  bool setTiming(uint32_t up_ms, uint32_t down_ms, uint32_t dead_ms, uint32_t overrun_ms) {
    if (dir_ != DIR_STOP || pending_ != DIR_STOP) return false;
    up_ms_ = clampTravel(up_ms);
    down_ms_ = clampTravel(down_ms);
    dead_ms_ = (dead_ms < MIN_DEAD_TIME_MS) ? (uint32_t)MIN_DEAD_TIME_MS : dead_ms;
    over_ms_ = (overrun_ms > 10000) ? 10000 : overrun_ms;
    return true;
  }

  // NVS'ten yüklenen konum. Yalnizca hareketsizken.
  bool setPosition(uint8_t pos) {
    if (dir_ != DIR_STOP || pending_ != DIR_STOP) return false;
    pos_ = (pos > 100) ? 100 : pos;
    return true;
  }

  // ------------------------------------------------------------------ zaman / sürücü girdisi
  // Her döngüde çagrilir. hw_off: bu panjurun IKI rolesi de sürücüce KAPALI olarak teyit edildi mi?
  void tick(uint32_t now_ms, bool hw_off) {
    hw_off_ = hw_off;

    if (dir_ != DIR_STOP) {
      // Süre dolumu: now - start >= dur (uint32_t farki, tasmaya dayanikli). Ayrica ayni yönde KESINTISIZ toplam
      // çalisma, "tam yol + oturma payi"ni (runCapMs) asamaz: ayni yönde art arda hedef degisimi start_ms_'i yeniden
      // damgalar; sinir olmasa (YUKARI, %99, YUKARI, ...) motor süresiz çalisirdi (uç noktada zorlanma/isinma).
      if ((uint32_t)(now_ms - start_ms_) >= dur_ms_ || (uint32_t)(now_ms - run_start_) >= runCapMs()) {
        commitStop(now_ms, true);
      }
      return;
    }

    if (dead_valid_) {
      if (!hw_off) return;                 // KAPALI teyidi yok: ölü zaman henüz baslayamaz
      if (restamp_) {                      // teyit simdi geldi: ölü zaman BURADAN sayilir
        restamp_ = false;
        dead_start_ = now_ms;
      }
      if ((uint32_t)(now_ms - dead_start_) >= dead_ms_) {
        dead_valid_ = false;
        ev_ |= EV_DEAD_END;
        if (pending_ != DIR_STOP) startPending(now_ms);
      }
    } else if (pending_ != DIR_STOP && hw_off) {
      startPending(now_ms);                // (ölü zaman yok ama teyit beklenmisti)
    }
  }

  // ------------------------------------------------------------------ komutlar
  void cmdUp(uint32_t now_ms)   { request(DIR_UP, NO_TARGET, now_ms); }
  void cmdDown(uint32_t now_ms) { request(DIR_DOWN, NO_TARGET, now_ms); }

  void cmdStop(uint32_t now_ms) {
    bool active = (dir_ != DIR_STOP) || (pending_ != DIR_STOP);
    if (dir_ != DIR_STOP) commitStop(now_ms, false);
    pending_ = DIR_STOP;
    pend_target_ = NO_TARGET;
    if (active) ev_ |= EV_STOPPED;
  }

  // Kademeli düğme: hareket/bekleme varsa DURDUR; durgunsa konuma göre yön seç.
  void cmdStep(uint32_t now_ms) {
    if (dir_ != DIR_STOP || pending_ != DIR_STOP) {
      cmdStop(now_ms);
      return;
    }
    uint8_t d;
    if (pos_ >= 100) d = DIR_DOWN;          // tam açık: yalnız aşağı gidebilir
    else if (pos_ == 0) d = DIR_UP;         // tam kapalı: yalnız yukarı
    else d = (last_dir_ == DIR_UP) ? DIR_DOWN : DIR_UP;   // arada: son yönün tersi
    request(d, NO_TARGET, now_ms);
  }

  void cmdPosition(uint32_t now_ms, uint8_t target) {
    if (target > 100) target = 100;
    uint8_t cur = positionAt(now_ms);
    if (cur == target) {
      // Zaten hedefte: hareket/bekleme varsa dur, yoksa bir sey yapma.
      cmdStop(now_ms);
      return;
    }
    request(target > cur ? DIR_UP : DIR_DOWN, target, now_ms);
  }

  // Sürücü/yapilandirma hatasi vb.: güvenli duruma gec (röleler OFF, konum kaydedilir).
  void forceStop(uint32_t now_ms) { cmdStop(now_ms); }

  // Sürücü enerjilemeyi basaramadi (I2C/RS485 yazma hatasi): hareketi iptal et, konum DEGISMEZ.
  void onEnergizeFailed(uint32_t now_ms) {
    if (dir_ == DIR_STOP) return;
    dir_ = DIR_STOP;
    target_ = NO_TARGET;
    full_ = false;
    // Hareket fiilen baslamadigi için konum olarak baslangic konumunu koru.
    pos_ = start_pos_;
    enterDead(now_ms);
    ev_ |= (EV_START_FAILED | EV_STOPPED | EV_DEAD_BEGIN);
  }

  // ------------------------------------------------------------------ çikti / durum
  uint8_t outMask() const { return (uint8_t)dir_; }   // 0, 1 (YUKARI) veya 2 (ASAGI); ASLA 3
  uint8_t takeEvents() { uint8_t e = ev_; ev_ = 0; return e; }
  uint8_t peekEvents() const { return ev_; }

  uint8_t position(uint32_t now_ms) const { return positionAt(now_ms); }
  bool isMoving() const { return dir_ != DIR_STOP; }
  bool isWaiting() const { return pending_ != DIR_STOP; }
  bool deadTimeActive() const { return dead_valid_; }
  uint8_t dir() const { return dir_; }
  uint8_t pendingDir() const { return pending_; }
  uint8_t lastDir() const { return last_dir_; }
  uint8_t target() const { return (dir_ != DIR_STOP) ? target_ : (uint8_t)NO_TARGET; }
  uint32_t startMs() const { return start_ms_; }
  uint32_t durationMs() const { return dur_ms_; }
  // Bu yönde röle ENERJILENDIGI an (yeniden hedefleme degistirmez) ve bu yönde izin verilen en uzun kesintisiz çalisma
  // (tam yol + oturma payi). Bagimsiz emniyet görevi bunlari kullanir.
  uint32_t runStartMs() const { return run_start_; }
  uint32_t runCapMs() const { return travelMs(dir_ == DIR_STOP ? (uint8_t)DIR_UP : dir_) + over_ms_; }
  uint32_t upMs() const { return up_ms_; }
  uint32_t downMs() const { return down_ms_; }
  uint32_t deadMs() const { return dead_ms_; }
  // Beklenen toplam çalışma süresi + marj: bağımsız motor emniyet görevi bunu kullanır.
  uint32_t guardRunMs() const { return dur_ms_; }

private:
  static uint32_t clampTravel(uint32_t ms) {
    if (ms == 0) return DEFAULT_TRAVEL_MS;
    return (ms > MAX_TRAVEL_MS) ? (uint32_t)MAX_TRAVEL_MS : ms;
  }

  uint32_t travelMs(uint8_t d) const { return (d == DIR_UP) ? up_ms_ : down_ms_; }

  uint8_t positionAt(uint32_t now_ms) const {
    if (dir_ == DIR_STOP) return pos_;
    uint32_t elapsed = (uint32_t)(now_ms - start_ms_);
    uint64_t t = travelMs(dir_);
    uint64_t delta = ((uint64_t)elapsed * 100u) / t;
    if (delta > 100) delta = 100;
    if (dir_ == DIR_UP) {
      uint32_t p = (uint32_t)start_pos_ + (uint32_t)delta;
      return (p > 100) ? 100 : (uint8_t)p;
    }
    return (delta >= start_pos_) ? 0 : (uint8_t)(start_pos_ - (uint8_t)delta);
  }

  void enterDead(uint32_t now_ms) {
    dead_valid_ = true;
    dead_start_ = now_ms;
    restamp_ = true;      // sayim, rolelerin KAPALI oldugu teyit edildigi ilk tick'ten baslar
    ev_ |= EV_DEAD_BEGIN;
  }

  // Enerjili hareketi bitir: konumu kaydet, ölü zamani baslat.
  void commitStop(uint32_t now_ms, bool timeout) {
    uint8_t p = positionAt(now_ms);
    if (timeout && target_ != NO_TARGET) p = target_;   // süre dolumu: hedef konuma esitle (self-healing)
    pos_ = p;
    dir_ = DIR_STOP;
    target_ = NO_TARGET;
    full_ = false;
    enterDead(now_ms);
    ev_ |= EV_STOPPED;
    if (timeout) ev_ |= EV_COMPLETED;
  }

  // Yeni hareketi basalt (rolede enerjileme gerekir). Parametreler HER ZAMAN yeniden atanir:
  // eski kodun "hedef 255 degilse start_position/duration eski kalir" hatasi burada yok.
  void startMove(uint8_t d, uint8_t target, uint32_t dur_ms, bool full, uint32_t now_ms) {
    dir_ = d;
    run_start_ = now_ms;
    start_ms_ = now_ms;
    start_pos_ = pos_;
    target_ = target;
    dur_ms_ = dur_ms;
    full_ = full;
    last_dir_ = d;
    pending_ = DIR_STOP;
    pend_target_ = NO_TARGET;
    ev_ |= EV_STARTED;
  }

  // d yönünde hedef (NO_TARGET = tam hareket) için süre; from = baslangiç konumu
  uint32_t durationFor(uint8_t d, uint8_t target, uint8_t from) const {
    if (target == NO_TARGET) {
      // Tam hareket: tam yol + uç noktada mekanik oturma payi (konumdan bagimsiz, eski davranis)
      return travelMs(d) + over_ms_;
    }
    uint32_t diff = (target > from) ? (uint32_t)(target - from) : (uint32_t)(from - target);
    uint32_t dur = (uint32_t)(((uint64_t)diff * travelMs(d)) / 100u);   // orantili
    if (target == 100 || target == 0) dur += over_ms_;                  // yalniz uçlarda +overrun
    if (dur < MIN_RUN_MS) dur = MIN_RUN_MS;
    return dur;
  }

  void begin(uint8_t d, uint8_t target, uint32_t now_ms) {
    if (target == NO_TARGET) {
      startMove(d, (d == DIR_UP) ? 100 : 0, durationFor(d, NO_TARGET, pos_), true, now_ms);
      return;
    }
    if (target == pos_) return;                       // beklerken hedefe esit olmus: yapilacak is yok
    uint8_t nd = (target > pos_) ? DIR_UP : DIR_DOWN; // konum donuk oldugu için d ile ayni olmali; yine de tutarli ol
    (void)d;
    startMove(nd, target, durationFor(nd, target, pos_), false, now_ms);
  }

  void startPending(uint32_t now_ms) {
    uint8_t d = pending_;
    uint8_t tgt = pend_target_;
    pending_ = DIR_STOP;
    pend_target_ = NO_TARGET;
    begin(d, tgt, now_ms);
  }

  // Tek giriş noktasi: yon d, hedef (NO_TARGET = tam).
  void request(uint8_t d, uint8_t target, uint32_t now_ms) {
    if (dir_ == d) {
      // AYNI YON zaten enerjili: röleye DOKUNMA. Tam hareket zaten sürüyorsa yok say; aksi halde
      // mevcut konumdan yeniden hedefle (başlangıç tabanı güncellenir, ilerleme KAYBOLMAZ).
      uint8_t cur = positionAt(now_ms);
      if (target == NO_TARGET) {
        if (full_) return;                            // "yukarı" tekrarı: başlangıcı bozma
        pos_ = cur;
        start_pos_ = cur;
        start_ms_ = now_ms;
        target_ = (d == DIR_UP) ? 100 : 0;
        dur_ms_ = durationFor(d, NO_TARGET, cur);
        full_ = true;
      } else {
        pos_ = cur;
        start_pos_ = cur;
        start_ms_ = now_ms;
        target_ = target;
        dur_ms_ = durationFor(d, target, cur);
        full_ = false;
      }
      ev_ |= EV_RETARGET;
      return;
    }

    if (dir_ != DIR_STOP) {
      // TERS YON: önce hemen kes, konumu kaydet, ölü zaman bitince yeni yön kalkacak.
      commitStop(now_ms, false);
      pending_ = d;
      pend_target_ = target;
      return;
    }

    // Hareketsiz
    if (dead_valid_ || !hw_off_) {
      pending_ = d;                                   // ölü zaman dolmadi / OFF teyidi yok: kuyruğa al
      pend_target_ = target;
      return;
    }
    begin(d, target, now_ms);
  }

  // --- durum ---
  uint8_t dir_;
  uint8_t pending_;
  uint8_t pend_target_;
  bool dead_valid_;        // ölü zaman sayiyor mu (dead_start_ gecerli mi) - AYRI bool
  bool restamp_;           // ölü zaman, OFF teyidinden itibaren yeniden damgalanacak
  bool hw_off_;
  bool full_;              // mevcut hareket "tam yol" komutu mu
  uint32_t dead_start_;
  uint32_t run_start_;     // bu yönde enerjilenme anı (aynı yönde yeniden hedefleme DEĞİŞTİRMEZ)
  uint32_t start_ms_;
  uint32_t dur_ms_;
  uint8_t start_pos_;
  uint8_t target_;
  uint8_t pos_;
  uint8_t last_dir_;
  uint32_t up_ms_;
  uint32_t down_ms_;
  uint32_t dead_ms_;
  uint32_t over_ms_;
  uint8_t ev_;
};
