// RelayRules.h'nin (firmware, src/RelayRules.h) BIREBIR JavaScript portu: SURUCU SEVIYESI emniyet kurallari.
// Maske: bit i = role i (0 tabanli) enerjili; panjur cifti p = (role 2p YUKARI, role 2p+1 ASAGI). 64 bit maskeler BigInt.
//
// Reddedilen yazimlar: BOTH_ON (iki yon ayni anda), DIRECT_REVERSAL (tek yazimda YUKARI<->ASAGI, arada KAPALI yok),
// DEAD_TIME (bir cift tamamen kapandiktan sonra < 500 ms icinde HERHANGI bir yon enerjilenmek istedi).
// KAPATMA yazimlari (bitleri 0'a ceken) HICBIR ZAMAN reddedilmez.
//
// Dogrulama: test/fw_relay_rules.test.js, firmware'in Unity testlerinin (test/test_relay_rules) BIREBIR portudur.

export const Result = Object.freeze({ OK: 0, BOTH_ON: 1, DIRECT_REVERSAL: 2, DEAD_TIME: 3 });

const u32 = (x) => x >>> 0;
const big = (m) => (typeof m === 'bigint' ? m : BigInt(m));

export class InterlockGuard {
  static DEAD_TIME_MS = 500;
  static MAX_PAIRS = 20;

  constructor() {
    this.hw_ = 0n;
    this.pairMask_ = 0;
    this.haveOff_ = 0;
    this.offAt_ = new Array(InterlockGuard.MAX_PAIRS).fill(0);
  }

  /** bit p = (2p, 2p+1) cifti panjur (yon kilidi uygulanir) */
  setShutterPairs(pairMask) { this.pairMask_ = pairMask >>> 0; }

  shutterPairs() { return this.pairMask_; }

  /** Donanimda su an (basariyla yazilmis) maske */
  hw() { return this.hw_; }

  forceHw(m) { this.hw_ = big(m); }

  /** newMask yazilabilir mi? Durumu DEGISTIRMEZ. */
  check(newMask, nowMs) {
    const nm = big(newMask);
    for (let p = 0; p < InterlockGuard.MAX_PAIRS; p++) {
      if (!((this.pairMask_ >>> p) & 1)) continue;
      const o = Number((this.hw_ >> BigInt(2 * p)) & 3n);
      const n = Number((nm >> BigInt(2 * p)) & 3n);
      if (n === 3) return Result.BOTH_ON;
      if (o !== 0 && n !== 0 && o !== n) return Result.DIRECT_REVERSAL;
      if (o === 0 && n !== 0 && ((this.haveOff_ >>> p) & 1) && u32(nowMs - this.offAt_[p]) < InterlockGuard.DEAD_TIME_MS) {
        return Result.DEAD_TIME;
      }
    }
    return Result.OK;
  }

  /** Yazma BASARILI oldu: durumu guncelle, kapanma anlarini kaydet. */
  commit(newMask, nowMs) {
    const nm = big(newMask);
    for (let p = 0; p < InterlockGuard.MAX_PAIRS; p++) {
      const o = Number((this.hw_ >> BigInt(2 * p)) & 3n);
      const n = Number((nm >> BigInt(2 * p)) & 3n);
      if (o !== 0 && n === 0) {
        this.haveOff_ = (this.haveOff_ | (1 << p)) >>> 0;
        this.offAt_[p] = u32(nowMs);
      }
    }
    this.hw_ = nm;
  }

  /**
   * Bir KAPAT yazimi ONAYLANDI (RS485 modulu yankiyi verdi): ilgili ciftin "son kapanma ani" HER ZAMAN yenilenir.
   * commit() yalnizca INANILAN durumdaki ACIK->KAPALI gecislerini damgalar; inanc yanlis olabilir -> 500 ms olu zaman O andan sayilir.
   */
  noteOff(relayIndex, nowMs) {
    const p = Math.floor(relayIndex / 2);
    if (p >= InterlockGuard.MAX_PAIRS) return;
    this.haveOff_ = (this.haveOff_ | (1 << p)) >>> 0;
    this.offAt_[p] = u32(nowMs);
  }

  /** Tek roleyi acmak/kapatmak icin yeni maske */
  static withRelay(mask, relayIndex, on) {
    const bit = 1n << BigInt(relayIndex);
    const m = big(mask);
    return on ? m | bit : m & ~bit;
  }

  static resultText(r) {
    switch (r) {
      case Result.OK: return 'OK';
      case Result.BOTH_ON: return 'IKI YON ACIK';
      case Result.DIRECT_REVERSAL: return 'DOGRUDAN YON DEGISIMI';
      case Result.DEAD_TIME: return 'OLU ZAMAN (<500ms)';
      default: return '?';
    }
  }
}

// ---------------------------------------------------------------------------------------------------------------------
// relayrules:: ad alani (src/RelayRules.h) -- G/O yapan kodun cagirdigi SAF KARAR kurallari (BIREBIR port)
// ---------------------------------------------------------------------------------------------------------------------
/** relayrules::TcaResyncPlan::Kind */
export const ResyncKind = Object.freeze({ IN_SYNC: 0, FIX_EXTRA: 1, DROPPED: 2, CHIP_RESET: 3 });

/**
 * relayrules::planTcaResync(): TCA9554 golge kayit ile FIZIKSEL cikis ayrismasi. Cip sifirlanmasi / rolenin dusmesi ile periyodik verify
 * arasinda firmware dusen roleyi hala "ACIK" saniyor; 8 bitlik yazim onu olu zamansiz yeniden cekerdi. Yazimdan ONCE donanim okunur,
 * golge donanima ESITLENIR, dusen bitler o yazimla YENIDEN CEKILMEZ.
 * Surucu iki asamada isler: (1) FIZIKSEL gercegi (physical) hemen benimser (duzeltme yazimi basarisiz olsa bile golge/koruma gercegi
 * yansitir), (2) fazla acik roleleri kapatir (newShadow); fazla acik bir PANJUR rolesinin ACIK->KAPALI gecisi ancak bu iki asamali
 * isleyisle damgalanir (olu zaman o kapanmadan baslar).
 * @returns {{kind:number, newShadow:number, dropped:number, physical:number, writeOut:boolean, restoreConfig:boolean}}
 */
export function planTcaResync(outHw, cfgHw, shadowOut, shadowCfg) {
  const so = shadowOut & 0xFF;
  const oh = outHw & 0xFF;
  const p = { kind: ResyncKind.IN_SYNC, newShadow: so, dropped: 0, physical: oh, writeOut: false, restoreConfig: false };
  if ((cfgHw & 0xFF) !== (shadowCfg & 0xFF)) {              // cip sifirlanmis: "ACIK" sanilan tum bitler dustu (pinler girise dondu: fiziksel 0)
    return { kind: ResyncKind.CHIP_RESET, newShadow: 0, dropped: so, physical: 0, writeOut: true, restoreConfig: true };
  }
  if (oh === so) return p;
  const extra = oh & ~so & 0xFF;                              // donanimda ACIK, golgede KAPALI (TEHLIKELI)
  const missing = so & ~oh & 0xFF;                            // golgede ACIK, donanimda KAPALI (dusmus)
  p.newShadow = so & oh;                                      // kesisim: dusenler YENIDEN cekilmez, fazlalar kapanir
  p.dropped = missing;
  p.writeOut = extra !== 0;
  p.kind = missing !== 0 ? ResyncKind.DROPPED : ResyncKind.FIX_EXTRA;
  return p;
}

/** relayrules::shutterRelayBits(): yerel TCA'da panjur ciftlerinin role bitleri (cift p = bit 2p YUKARI + 2p+1 ASAGI; en cok 4 cift). */
export function shutterRelayBits(pairMask) {
  let m = 0;
  for (let p = 0; p < 4; p++) {
    if ((pairMask >>> p) & 1) m |= 3 << (2 * p);
  }
  return m & 0xFF;
}

/**
 * relayrules::unverifiedRetainedShutterBits(): esitleme icin donanim OKUNAMADIGINDA (3 denemede de I2C okuma hatasi) yazimin "ACIK
 * birakacagi" (golgede zaten ACIK) panjur roleleri DOGRULANAMAZ; fiziksel olarak dusmus olabilirler ve 8 bitlik yazim onlari olu
 * zamansiz yeniden cekerdi. Guvenli yon (DOGRULANAMAYAN ENERJI YOK): bu bitler yazimdan CIKARILIR ve "dusmus" sayilir. Yeni enerjilenecek
 * bitler (golgede KAPALI) ve lamba roleleri bu kuraldan etkilenmez.
 */
export function unverifiedRetainedShutterBits(mask, shadowOut, pairMask) {
  return (mask & shadowOut & shutterRelayBits(pairMask)) & 0xFF;
}

/**
 * relayrules::extNeedsOffWrite(): harici modul rolesinin FIZIKSEL kapatilmasi icin KAPAT yazimi gerekir mi (stepExtOutputs 1. gecis).
 * Ham TOGGLE sonrasi benimse-bekleyen role (sonuc bilinmiyor, bir sonraki coil okumasinda benimsenecek) KAPATILMAZ: aksi halde
 * TOGGLE ile acilan role ~10-20 ms cekip birakirdi.
 */
export function extNeedsOffWrite(want, hw, hwKnown, adoptPending) {
  if (want) return false;
  if (adoptPending) return false;
  return hw || !hwKnown;
}
