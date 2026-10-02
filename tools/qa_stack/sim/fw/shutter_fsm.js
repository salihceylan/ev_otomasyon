// ShutterFsm.h'nin (firmware, src/ShutterFsm.h) BIREBIR JavaScript portu. SAF MANTIK: saat disaridan (now),
// surucu disaridadir; sinif yalnizca "hangi rolelerin enerjili OLMASI GEREKTIGINI" (outMask) ve olaylari uretir.
//
// Konum modeli: 0 = tam kapali, 100 = tam acik; konum sure uzerinden kestirilir (limit switch yok):
//   YUKARI: pos = start + elapsed*100/up_ms     ASAGI: pos = start - elapsed*100/down_ms   (tamsayi bolme)
// DEGISMEZ KURAL: outMask() hicbir kosulda 3 olamaz; yon degisiminde/durus sonrasinda en az 500 ms olu zaman;
// olu zaman rolelerin KAPALI oldugu teyit edildikten sonra sayilir. Tum sure farklari uint32 (>>> 0) ile.
//
// Dogrulama: test/fw_shutter_fsm.test.js, firmware'in kendi Unity testlerinin (test/test_shutter_fsm) BIREBIR portudur.

export const Dir = Object.freeze({ STOP: 0, UP: 1, DOWN: 2 });
export const Ev = Object.freeze({
  STARTED: 1 << 0,
  STOPPED: 1 << 1,
  DEAD_BEGIN: 1 << 2,
  DEAD_END: 1 << 3,
  COMPLETED: 1 << 4,
  RETARGET: 1 << 5,
  START_FAILED: 1 << 6,
});
export const NO_TARGET = 255;

const u32 = (x) => x >>> 0;
const diff = (a, b) => u32(a - b);

export class ShutterFsm {
  static MIN_DEAD_TIME_MS = 500;
  static DEFAULT_TRAVEL_MS = 20000;
  static MAX_TRAVEL_MS = 300000;
  static MIN_RUN_MS = 100;

  constructor() {
    this.reset();
  }

  reset() {
    this.dir_ = Dir.STOP;
    this.pending_ = Dir.STOP;
    this.pend_target_ = NO_TARGET;
    this.dead_valid_ = false;
    this.restamp_ = false;
    this.dead_start_ = 0;
    this.hw_off_ = true;
    this.full_ = false;
    this.run_start_ = 0;
    this.start_ms_ = 0;
    this.dur_ms_ = 0;
    this.start_pos_ = 0;
    this.target_ = NO_TARGET;
    this.pos_ = 0;
    this.last_dir_ = Dir.STOP;
    this.up_ms_ = ShutterFsm.DEFAULT_TRAVEL_MS;
    this.down_ms_ = ShutterFsm.DEFAULT_TRAVEL_MS;
    this.dead_ms_ = ShutterFsm.MIN_DEAD_TIME_MS;
    this.over_ms_ = 2000;
    this.ev_ = 0;
  }

  // ------------------------------------------------------------------ yapilandirma
  /** Yalnizca HAREKETSIZKEN (ve beklemede komut yokken) kabul edilir; aksi halde false. */
  setTiming(upMs, downMs, deadMs, overrunMs) {
    if (this.dir_ !== Dir.STOP || this.pending_ !== Dir.STOP) return false;
    this.up_ms_ = ShutterFsm.#clampTravel(upMs);
    this.down_ms_ = ShutterFsm.#clampTravel(downMs);
    this.dead_ms_ = deadMs < ShutterFsm.MIN_DEAD_TIME_MS ? ShutterFsm.MIN_DEAD_TIME_MS : deadMs;
    this.over_ms_ = overrunMs > 10000 ? 10000 : overrunMs;
    return true;
  }

  setPosition(pos) {
    if (this.dir_ !== Dir.STOP || this.pending_ !== Dir.STOP) return false;
    this.pos_ = pos > 100 ? 100 : pos;
    return true;
  }

  // ------------------------------------------------------------------ zaman / surucu girdisi
  tick(nowMs, hwOff) {
    this.hw_off_ = hwOff;
    if (this.dir_ !== Dir.STOP) {
      // Sure dolumu: now - start >= dur (uint32 farki). Ayrica ayni yonde KESINTISIZ toplam calisma "tam yol + oturma payi"ni
      // (runCapMs) asamaz: ayni yonde art arda hedef degisimi start_ms_'i yeniden damgalar; sinir olmasa motor suresiz calisirdi.
      if (diff(nowMs, this.start_ms_) >= this.dur_ms_ || diff(nowMs, this.run_start_) >= this.runCapMs()) this.#commitStop(nowMs, true);
      return;
    }
    if (this.dead_valid_) {
      if (!hwOff) return;                      // KAPALI teyidi yok: olu zaman henuz baslayamaz
      if (this.restamp_) {                     // teyit simdi geldi: olu zaman BURADAN sayilir
        this.restamp_ = false;
        this.dead_start_ = u32(nowMs);
      }
      if (diff(nowMs, this.dead_start_) >= this.dead_ms_) {
        this.dead_valid_ = false;
        this.ev_ |= Ev.DEAD_END;
        if (this.pending_ !== Dir.STOP) this.#startPending(nowMs);
      }
    } else if (this.pending_ !== Dir.STOP && hwOff) {
      this.#startPending(nowMs);               // (olu zaman yok ama teyit beklenmisti)
    }
  }

  // ------------------------------------------------------------------ komutlar
  cmdUp(nowMs) { this.#request(Dir.UP, NO_TARGET, nowMs); }

  cmdDown(nowMs) { this.#request(Dir.DOWN, NO_TARGET, nowMs); }

  cmdStop(nowMs) {
    const active = this.dir_ !== Dir.STOP || this.pending_ !== Dir.STOP;
    if (this.dir_ !== Dir.STOP) this.#commitStop(nowMs, false);
    this.pending_ = Dir.STOP;
    this.pend_target_ = NO_TARGET;
    if (active) this.ev_ |= Ev.STOPPED;
  }

  /** Kademeli dugme: hareket/bekleme varsa DURDUR; durgunsa konuma gore yon sec. */
  cmdStep(nowMs) {
    if (this.dir_ !== Dir.STOP || this.pending_ !== Dir.STOP) {
      this.cmdStop(nowMs);
      return;
    }
    let d;
    if (this.pos_ >= 100) d = Dir.DOWN;                       // tam acik: yalniz asagi
    else if (this.pos_ === 0) d = Dir.UP;                     // tam kapali: yalniz yukari
    else d = this.last_dir_ === Dir.UP ? Dir.DOWN : Dir.UP;   // arada: son yonun tersi
    this.#request(d, NO_TARGET, nowMs);
  }

  cmdPosition(nowMs, target) {
    if (target > 100) target = 100;
    const cur = this.#positionAt(nowMs);
    if (cur === target) {
      this.cmdStop(nowMs);                                    // zaten hedefte: hareket/bekleme varsa dur
      return;
    }
    this.#request(target > cur ? Dir.UP : Dir.DOWN, target, nowMs);
  }

  forceStop(nowMs) { this.cmdStop(nowMs); }

  /** Surucu enerjilemeyi basaramadi: hareketi iptal et, konum DEGISMEZ. */
  onEnergizeFailed(nowMs) {
    if (this.dir_ === Dir.STOP) return;
    this.dir_ = Dir.STOP;
    this.target_ = NO_TARGET;
    this.full_ = false;
    this.pos_ = this.start_pos_;                              // hareket fiilen baslamadi
    this.#enterDead(nowMs);
    this.ev_ |= Ev.START_FAILED | Ev.STOPPED | Ev.DEAD_BEGIN;
  }

  // ------------------------------------------------------------------ cikti / durum
  outMask() { return this.dir_; }                             // 0, 1 (YUKARI) veya 2 (ASAGI); ASLA 3

  takeEvents() { const e = this.ev_; this.ev_ = 0; return e; }

  peekEvents() { return this.ev_; }

  position(nowMs) { return this.#positionAt(nowMs); }

  isMoving() { return this.dir_ !== Dir.STOP; }

  isWaiting() { return this.pending_ !== Dir.STOP; }

  deadTimeActive() { return this.dead_valid_; }

  dir() { return this.dir_; }

  pendingDir() { return this.pending_; }

  lastDir() { return this.last_dir_; }

  target() { return this.dir_ !== Dir.STOP ? this.target_ : NO_TARGET; }

  startMs() { return this.start_ms_; }

  durationMs() { return this.dur_ms_; }

  /** Bu yonde role ENERJILENDIGI an (yeniden hedefleme degistirmez) ve bu yonde izin verilen en uzun kesintisiz calisma (tam yol + oturma payi). */
  runStartMs() { return this.run_start_; }

  runCapMs() { return this.#travelMs(this.dir_ === Dir.STOP ? Dir.UP : this.dir_) + this.over_ms_; }

  upMs() { return this.up_ms_; }

  downMs() { return this.down_ms_; }

  deadMs() { return this.dead_ms_; }

  guardRunMs() { return this.dur_ms_; }

  // ------------------------------------------------------------------ ozel
  static #clampTravel(ms) {
    if (ms === 0) return ShutterFsm.DEFAULT_TRAVEL_MS;
    return ms > ShutterFsm.MAX_TRAVEL_MS ? ShutterFsm.MAX_TRAVEL_MS : ms;
  }

  #travelMs(d) { return d === Dir.UP ? this.up_ms_ : this.down_ms_; }

  #positionAt(nowMs) {
    if (this.dir_ === Dir.STOP) return this.pos_;
    const elapsed = diff(nowMs, this.start_ms_);
    const t = this.#travelMs(this.dir_);
    let delta = Math.floor((elapsed * 100) / t);
    if (delta > 100) delta = 100;
    if (this.dir_ === Dir.UP) {
      const p = this.start_pos_ + delta;
      return p > 100 ? 100 : p;
    }
    return delta >= this.start_pos_ ? 0 : this.start_pos_ - delta;
  }

  #enterDead(nowMs) {
    this.dead_valid_ = true;
    this.dead_start_ = u32(nowMs);
    this.restamp_ = true;          // sayim, rolelerin KAPALI oldugu teyit edildigi ilk tick'ten baslar
    this.ev_ |= Ev.DEAD_BEGIN;
  }

  #commitStop(nowMs, timeout) {
    let p = this.#positionAt(nowMs);
    if (timeout && this.target_ !== NO_TARGET) p = this.target_;   // sure dolumu: hedef konuma esitle (self-healing)
    this.pos_ = p;
    this.dir_ = Dir.STOP;
    this.target_ = NO_TARGET;
    this.full_ = false;
    this.#enterDead(nowMs);
    this.ev_ |= Ev.STOPPED;
    if (timeout) this.ev_ |= Ev.COMPLETED;
  }

  #startMove(d, target, durMs, full, nowMs) {
    this.dir_ = d;
    this.run_start_ = u32(nowMs);
    this.start_ms_ = u32(nowMs);
    this.start_pos_ = this.pos_;
    this.target_ = target;
    this.dur_ms_ = durMs;
    this.full_ = full;
    this.last_dir_ = d;
    this.pending_ = Dir.STOP;
    this.pend_target_ = NO_TARGET;
    this.ev_ |= Ev.STARTED;
  }

  #durationFor(d, target, from) {
    if (target === NO_TARGET) {
      // Tam hareket: tam yol + uc noktada mekanik oturma payi (konumdan bagimsiz)
      return this.#travelMs(d) + this.over_ms_;
    }
    const df = target > from ? target - from : from - target;
    let dur = Math.floor((df * this.#travelMs(d)) / 100);     // orantili
    if (target === 100 || target === 0) dur += this.over_ms_;  // yalniz uclarda +overrun
    if (dur < ShutterFsm.MIN_RUN_MS) dur = ShutterFsm.MIN_RUN_MS;
    return dur;
  }

  #begin(d, target, nowMs) {
    if (target === NO_TARGET) {
      this.#startMove(d, d === Dir.UP ? 100 : 0, this.#durationFor(d, NO_TARGET, this.pos_), true, nowMs);
      return;
    }
    if (target === this.pos_) return;                         // beklerken hedefe esit olmus: is yok
    const nd = target > this.pos_ ? Dir.UP : Dir.DOWN;
    this.#startMove(nd, target, this.#durationFor(nd, target, this.pos_), false, nowMs);
  }

  #startPending(nowMs) {
    const d = this.pending_;
    const tgt = this.pend_target_;
    this.pending_ = Dir.STOP;
    this.pend_target_ = NO_TARGET;
    this.#begin(d, tgt, nowMs);
  }

  #request(d, target, nowMs) {
    if (this.dir_ === d) {
      // AYNI YON zaten enerjili: role'ye DOKUNMA.
      const cur = this.#positionAt(nowMs);
      if (target === NO_TARGET) {
        if (this.full_) return;                               // "yukari" tekrari: baslangici bozma
        this.pos_ = cur;
        this.start_pos_ = cur;
        this.start_ms_ = u32(nowMs);
        this.target_ = d === Dir.UP ? 100 : 0;
        this.dur_ms_ = this.#durationFor(d, NO_TARGET, cur);
        this.full_ = true;
      } else {
        this.pos_ = cur;
        this.start_pos_ = cur;
        this.start_ms_ = u32(nowMs);
        this.target_ = target;
        this.dur_ms_ = this.#durationFor(d, target, cur);
        this.full_ = false;
      }
      this.ev_ |= Ev.RETARGET;
      return;
    }
    if (this.dir_ !== Dir.STOP) {
      // TERS YON: once hemen kes, konumu kaydet, olu zaman bitince yeni yon kalkacak.
      this.#commitStop(nowMs, false);
      this.pending_ = d;
      this.pend_target_ = target;
      return;
    }
    // Hareketsiz
    if (this.dead_valid_ || !this.hw_off_) {
      this.pending_ = d;                                      // olu zaman dolmadi / OFF teyidi yok: kuyruga al
      this.pend_target_ = target;
      return;
    }
    this.#begin(d, target, nowMs);
  }
}
