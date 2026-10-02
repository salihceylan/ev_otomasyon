// Bagimsiz "fiziksel" gozlemci: firmware testindeki Sim.apply() ile AYNI degismezleri, sistemin KENDI emniyet katmanindan (InterlockGuard)
// bagimsiz olarak denetler. Fiziksel cikis maskesindeki (yerel 8 role + ek modul coil'leri) her degisimde, GECERLI panjur ciftleri icin:
//   * iki yon ayni anda (maske 3)                            -> 'both_on'
//   * arada KAPALI olmadan yon degisimi (1 <-> 2)             -> 'direct_reversal'
//   * bir cift tamamen kapandiktan sonra < 500 ms icinde yeniden enerjilenme -> 'dead_time'
// Acilista her cift "az once kapandi" sayilir (TCA init ile ayni: ilk enerjileme de olu zamana tabidir).
const u32 = (x) => x >>> 0;

export class PhysicalObserver {
  constructor({ deadTimeMs = 500, pairs = 20 } = {}) {
    this.deadTimeMs = deadTimeMs;
    this.pairs = pairs;
    this.mask = 0n;
    this.haveOff = new Array(pairs).fill(false);
    this.offAt = new Array(pairs).fill(0);
    this.violations = [];
    this.transitions = 0;
  }

  /** Acilis: tum ciftler az once kapandi. */
  boot(now) {
    this.mask = 0n;
    this.haveOff.fill(true);
    this.offAt.fill(now);
  }

  /**
   * @param {number} now
   * @param {bigint} mask  bit i = fiziksel role i enerjili
   * @param {boolean[]} pairValid
   * @returns {object[]} bu cagrida bulunan yeni ihlaller
   */
  observe(now, mask, pairValid) {
    if (mask === this.mask) return [];
    const found = [];
    for (let p = 0; p < this.pairs; p++) {
      const o = Number((this.mask >> BigInt(2 * p)) & 3n);
      const n = Number((mask >> BigInt(2 * p)) & 3n);
      if (o === n) continue;
      this.transitions++;
      if (pairValid[p]) {
        if (n === 3) found.push({ code: 'both_on', pair: p + 1 });
        if (o !== 0 && n !== 0 && o !== n) found.push({ code: 'direct_reversal', pair: p + 1 });
        if (o === 0 && n !== 0 && this.haveOff[p] && u32(now - this.offAt[p]) < this.deadTimeMs) {
          found.push({ code: 'dead_time', pair: p + 1, since_ms: u32(now - this.offAt[p]) });
        }
      }
      if (o !== 0 && n === 0) { this.haveOff[p] = true; this.offAt[p] = u32(now); }
    }
    this.mask = mask;
    this.violations.push(...found);
    return found;
  }

  /** Automation'dan fiziksel maskeyi uretir (yerel TCA GERCEK latch'i + ek modul coil'leri; golge degil: firmware yanilabilir). */
  static physicalMask(automation, ext, extEnabled) {
    let mask = BigInt(automation.tca.latch);
    if (ext && ext.present && extEnabled) {
      for (let k = 0; k < Math.min(32, ext.channels); k++) if (ext.coils[k]) mask |= 1n << BigInt(8 + k);
    }
    return mask;
  }
}
