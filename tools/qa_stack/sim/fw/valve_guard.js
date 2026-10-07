// safety/ValveGuard.h (firmware) JavaScript portu: bagimsiz emniyet (ValveGuard) kararlari. SAF MANTIK.
//  * Tutma maskeleri yalniz KAPALI komutlu vanalardir (E2C: role 1, D2C: role 0, iki roleli vanada AC rolesi 0); guvenli kipte kilit maskesi eklenir.
//  * Yerel 8 role: DONANIMDAN okunan cikis yazmaciyla karsilastirilir; panjur cifti bitleri asla KURULMAZ.
//  * Ek modul: yalniz loop beslemesi 1000 ms kesildiginde ve en cok 1 sn'de bir korlemesine guvenli seviye yazilir.
import { MAX_ACTUATORS } from './sensor_hub.js';
import { isValve, isPulseValve, relayBit, relayLevelFor, applyLatchMask, filterSafeBits } from './actuator_map.js';

export const GUARD_STARVE_MS = 1000;
export const GUARD_EXT_MIN_GAP_MS = 1000;
const u32 = (x) => x >>> 0;

/** @returns {{assert: bigint, level: bigint}} */
export function safeHoldMasks(a, n, closedBits, latchAssert, latchLevel) {
  let as = 0n;
  let lv = 0n;
  for (let i = 0; a && i < n && i < MAX_ACTUATORS; i++) {
    if (!isValve(a[i]) || !(closedBits & (1 << i))) continue;
    if (isPulseValve(a[i])) {
      as |= relayBit(a[i].relay2);
    } else {
      as |= relayBit(a[i].relay);
      if (relayLevelFor(a[i], true)) lv |= relayBit(a[i].relay);
    }
  }
  const assert = as | latchAssert;
  return { assert, level: applyLatchMask(lv, latchAssert, latchLevel) & assert };
}

/** @returns {{clearBits:number, setBits:number}} */
export function planLocalGuard(assertMask, levelMask, hwOut, shutterPairMask) {
  const a = Number(assertMask & 0xFFn);
  const l = Number(levelMask & 0xFFn) & a;
  return { clearBits: a & ~l & hwOut & 0xFF, setBits: filterSafeBits(a & l & ~hwOut & 0xFF, shutterPairMask) };
}

/** @returns {{on:number, off:number}} ek modul (role 9..40 -> bit 0..31) */
export function extGuardBits(assertMask, levelMask) {
  const a = Number((assertMask >> 8n) & 0xFFFFFFFFn);
  const l = Number((levelMask >> 8n) & 0xFFFFFFFFn);
  return { on: u32(a & l), off: u32(a & ~l) };
}

export class ExtGuardPacer {
  constructor() { this.beat_ = 0; this.beatAt = 0; this.lastWrite = 0; this.haveBeat = false; this.wrote_ = false; }

  beat(loopBeat, now) {
    if (!this.haveBeat || loopBeat !== this.beat_) {
      this.beat_ = loopBeat;
      this.beatAt = u32(now);
      this.haveBeat = true;
    }
  }

  due(now) {
    if (!this.haveBeat || u32(now - this.beatAt) < GUARD_STARVE_MS) return false;
    return !this.wrote_ || u32(now - this.lastWrite) >= GUARD_EXT_MIN_GAP_MS;
  }

  wrote(now) { this.lastWrite = u32(now); this.wrote_ = true; }
}
