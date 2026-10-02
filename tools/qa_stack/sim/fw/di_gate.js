// DiGate.h'nin (firmware, src/DiGate.h) BIREBIR JavaScript portu: dijital giris (duvar butonu) kapisi. SAF MANTIK.
//
//  1) 60 ms KARARLILIK suzgeci: ham seviye en az DEBOUNCE_MS boyunca degismeden kalirsa kenar kabul edilir.
//  2) COCUK KILIDI yalnizca YENI BASISI engeller; BIRAKMA olayi ASLA yutulmaz. "bu basis islendi mi" biti (acted)
//     ve "momentary AC uretti mi" biti tutulur (birakmada bayat KAPAT uretilmesin / role takili kalmasin).
//  3) URUN KARARI: kilitliyken duvar anahtari HAREKET HALINDEKI (veya ters yon icin bekleyen) panjuru DURDURABILIR;
//     hareketi BASLATMA, role acma/kapama ve toggle kilitliyken engelli kalir (dropped = true -> kisa bip).
//
// Dogrulama: test/fw_di_gate.test.js, firmware'in Unity testlerinin (test/test_di_gate) BIREBIR portudur.

export const Mode = Object.freeze({ TOGGLE: 0, MOMENTARY: 1, SHUTTER_STEP: 2, SHUTTER_UP: 3, SHUTTER_DOWN: 4 });
export const Action = Object.freeze({
  NONE: 0, RELAY_TOGGLE: 1, RELAY_ON: 2, RELAY_OFF: 3, SHUTTER_STEP: 4, SHUTTER_UP: 5, SHUTTER_DOWN: 6, SHUTTER_STOP: 7,
});
export const Edge = Object.freeze({ NONE: 0, PRESS: 1, RELEASE: 2 });

const u32 = (x) => x >>> 0;

export class DiGate {
  static MAX_INPUTS = 40;
  static DEBOUNCE_MS = 60;

  constructor() {
    const n = DiGate.MAX_INPUTS;
    this.raw_ = new Array(n).fill(false);
    this.stable_ = new Array(n).fill(false);
    this.since_ = new Array(n).fill(0);
    this.acted_ = 0n;
    this.momentary_ = 0n;
  }

  /** Baslangic seviyesini kenar uretmeden kabul et (acilista basili dugme olay uretmez). */
  init(idx, level, nowMs) {
    if (idx >= DiGate.MAX_INPUTS) return;
    this.raw_[idx] = level;
    this.stable_[idx] = level;
    this.since_[idx] = u32(nowMs);
    this.#clearActed(idx);
  }

  /** Ham ornek: deger en az DEBOUNCE_MS boyunca degismeden kalirsa kenar doner. */
  sample(idx, closed, nowMs) {
    if (idx >= DiGate.MAX_INPUTS) return Edge.NONE;
    if (closed !== this.raw_[idx]) {                 // degisti: sayaci yeniden baslat
      this.raw_[idx] = closed;
      this.since_[idx] = u32(nowMs);
      return Edge.NONE;
    }
    if (closed === this.stable_[idx]) return Edge.NONE;
    if (u32(nowMs - this.since_[idx]) < DiGate.DEBOUNCE_MS) return Edge.NONE;
    this.stable_[idx] = closed;
    return closed ? Edge.PRESS : Edge.RELEASE;
  }

  /**
   * Kabul edilmis bir kenar icin karar.
   * @returns {{edge:number, action:number, dropped:boolean}}
   */
  decide(idx, edge, mode, childLock, shutterActive) {
    const d = { edge, action: Action.NONE, dropped: false };
    if (idx >= DiGate.MAX_INPUTS || edge === Edge.NONE) return d;

    if (edge === Edge.PRESS) {
      this.#clearActed(idx);
      const shutterMode = mode === Mode.SHUTTER_STEP || mode === Mode.SHUTTER_UP || mode === Mode.SHUTTER_DOWN;

      if (childLock) {
        // Kilitliyken yalnizca DURDURMA serbest; baslatma/role/toggle engelli.
        if (shutterMode && shutterActive) {
          d.action = Action.SHUTTER_STOP;
          this.acted_ |= DiGate.#maskOf(idx);        // birakmada yapilacak bir sey yok (MOMENTARY degil)
        } else {
          d.dropped = mode <= Mode.SHUTTER_DOWN;      // gecerli bir mod: kullaniciya "engellendi" geri bildirimi
        }
        return d;
      }

      switch (mode) {
        case Mode.TOGGLE: d.action = Action.RELAY_TOGGLE; break;
        case Mode.MOMENTARY: d.action = Action.RELAY_ON; this.momentary_ |= DiGate.#maskOf(idx); break;
        case Mode.SHUTTER_STEP: d.action = Action.SHUTTER_STEP; break;
        case Mode.SHUTTER_UP: d.action = shutterActive ? Action.SHUTTER_STOP : Action.SHUTTER_UP; break;
        case Mode.SHUTTER_DOWN: d.action = shutterActive ? Action.SHUTTER_STOP : Action.SHUTTER_DOWN; break;
        default: return d;                            // bilinmeyen mod: hicbir sey yapma
      }
      this.acted_ |= DiGate.#maskOf(idx);
      return d;
    }

    // RELEASE: cocuk kilidinden BAGIMSIZ. Yalnizca islenmis bir MOMENTARY basisin karsiligi KAPAT'tir.
    if (this.momentary_ & DiGate.#maskOf(idx)) d.action = Action.RELAY_OFF;
    this.#clearActed(idx);
    return d;
  }

  stable(idx) { return idx < DiGate.MAX_INPUTS && this.stable_[idx]; }

  stableMask() {
    let m = 0n;
    for (let i = 0; i < DiGate.MAX_INPUTS; i++) if (this.stable_[i]) m |= 1n << BigInt(i);
    return m;
  }

  acted(idx) { return idx < DiGate.MAX_INPUTS && (this.acted_ & DiGate.#maskOf(idx)) !== 0n; }

  actedMask() { return this.acted_; }

  static #maskOf(idx) { return 1n << BigInt(idx); }

  #clearActed(idx) {
    const m = ~DiGate.#maskOf(idx);
    this.acted_ &= m;
    this.momentary_ &= m;
  }
}
