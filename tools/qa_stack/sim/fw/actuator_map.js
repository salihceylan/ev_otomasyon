// actuators/ActuatorTypes.h + ActuatorMap.h (firmware) BIREBIR JavaScript portu. SAF MANTIK.
//
//  * Mantiksal durum -> role seviyesi (close_mode), acilis maskesi (gaz her zaman kapali, kilitli bolge kapali, digerleri son
//    komut konumu; kayit yoksa "bilinmiyor" = ACIK kabul, karar 7.2b-6), kilit maskesinin yapilandirmadan bagimsiz uygulanmasi,
//    panjur cifti suzgeci, ham komut yon kurali [O4].
//  * ActuatorCore: vana/siren/fan/generic calisma durumu, geri bildirim zaman asimi, siren sure butcesi, IKI ROLELI vana
//    interlock'u (iki role asla birlikte enerjili degil, yon degisiminde 500 ms olu zaman; karar 7.2b-2).
// Role maskeleri BigInt (bit role-1, 40 bit); eylemci bit maskeleri Number (16 bit).
//
// Dogrulama: test/fw_actuator_map.test.js, firmware'in Unity testlerinin (test/test_actuator_map) BIREBIR portudur.
import { HZ_WATER, HZ_GAS, MAX_ACTUATORS, MAX_RELAYS, MAX_DI } from './sensor_hub.js';

export const ActKind = Object.freeze({ NONE: 0, VALVE: 1, SIREN: 2, FAN: 3, GENERIC: 4 });
export const CloseMode = Object.freeze({ ENERGIZE_TO_CLOSE: 0, DEENERGIZE_TO_CLOSE: 1, PULSE_TWO_RELAY: 2 });
export const Medium = Object.freeze({ NONE: 0, WATER: 1, GAS: 2 });
export const AF_FAN_EXPROOF = 0x01;
export const ValvePos = Object.freeze({ UNKNOWN: 0, CLOSED: 1, CLOSING: 2, OPEN: 3, OPENING: 4, CMD_CLOSED: 5, CMD_OPEN: 6 });
export const FB_TIMEOUT_DEFAULT_S = 60;
export const SIREN_RUN_DEFAULT_S = 180;
export const SIREN_RUN_MIN_S = 10;
export const SIREN_RUN_MAX_S = 1800;
export const PULSE_DEFAULT_S = 15;
export const PULSE_MAX_S = 120;
export const PULSE_DEAD_MS = 500;

const u32 = (x) => x >>> 0;

/** Bos ActuatorConfig (36 B'lik firmware yapisinin alanlari). */
export function makeActuatorConfig(o = {}) {
  return {
    relay: 0, kind: 0, close_mode: 0, fb_di: 0, fb_closed_active: 0, zone_mask: 0, fb_timeout_s: 0, run_limit_s: 0,
    medium: 0, aflags: 0, name: '', relay2: 0, ...o,
  };
}

export const isValve = (a) => a.kind === ActKind.VALVE;
export const isPulseValve = (a) => isValve(a) && a.close_mode === CloseMode.PULSE_TWO_RELAY;
export const isGasValve = (a) => isValve(a) && a.medium === Medium.GAS;
export function mediumHazard(medium) {
  if (medium === Medium.WATER) return HZ_WATER;
  if (medium === Medium.GAS) return HZ_GAS;
  return 0;
}
export function actKindText(kind) {
  return { 1: 'valve', 2: 'siren', 3: 'fan', 4: 'generic' }[kind] || '';
}
export function valvePosText(p) {
  return ['unknown', 'closed', 'closing', 'open', 'opening', 'cmd_closed', 'cmd_open'][p] || 'unknown';
}

export function relayLevelFor(a, closed) {
  if (a.close_mode === CloseMode.ENERGIZE_TO_CLOSE) return !!closed;
  if (a.close_mode === CloseMode.DEENERGIZE_TO_CLOSE) return !closed;
  return false;
}
export const relayBit = (relay1) => (relay1 >= 1 && relay1 <= MAX_RELAYS ? 1n << BigInt(relay1 - 1) : 0n);
export function relayBits(a) {
  let m = relayBit(a.relay);
  if (isPulseValve(a)) m |= relayBit(a.relay2);
  return m;
}
export function actuatorRelayMask(a, n) {
  let m = 0n;
  for (let i = 0; a && i < n; i++) m |= relayBits(a[i]);
  return m;
}
export const pulseMs = (a) => (a.run_limit_s || PULSE_DEFAULT_S) * 1000;

export function bootLevelMask(a, n, latchedZones, posOpenBits, posKnownBits) {
  let m = 0n;
  for (let i = 0; a && i < n; i++) {
    const c = a[i];
    if (!isValve(c) || isPulseValve(c)) continue;
    let closed;
    if (isGasValve(c) || (c.zone_mask & latchedZones)) closed = true;
    else if (posKnownBits & (1 << i)) closed = !(posOpenBits & (1 << i));
    else closed = false;
    if (relayLevelFor(c, closed)) m |= relayBit(c.relay);
  }
  return m;
}

export const applyLatchMask = (levels, latchAssert, latchLevel) => (levels & ~latchAssert) | (latchLevel & latchAssert);

/**
 * Kalici acilis guvenli maskesi (NVS "safe_msk"; inceleme turu EM-1/EM-5): KAPALI komutlu vanalar + BUTUN gaz vanalari (K-4).
 * E2C role 1, D2C 0, iki roleli: AC rolesi 0. @returns {{assert: bigint, level: bigint}}
 */
export function bootSafeMasks(a, n, closedBits) {
  let as = 0n;
  let lv = 0n;
  for (let i = 0; a && i < n && i < MAX_ACTUATORS; i++) {
    const c = a[i];
    if (!isValve(c) || !(isGasValve(c) || (closedBits & (1 << i)))) continue;
    if (isPulseValve(c)) as |= relayBit(c.relay2);
    else {
      as |= relayBit(c.relay);
      if (relayLevelFor(c, true)) lv |= relayBit(c.relay);
    }
  }
  return { assert: as, level: lv & as };
}

export function filterSafeBits(mask, shutterPairMask) {
  let deny = 0;
  for (let p = 0; p < 4; p++) if (shutterPairMask & (1 << p)) deny |= 0x03 << (2 * p);
  return mask & ~deny & 0xFF;
}

export const RawDecision = Object.freeze({ NOT_ACTUATOR: 0, SAFE: 1, NOOP: 2, REJECT: 3 });

/** @returns {{d:number, act:number}} */
export function rawCommand(a, n, relay1, level) {
  const b = relayBit(relay1);
  for (let i = 0; a && b && i < n; i++) {
    const c = a[i];
    if (!(relayBits(c) & b)) continue;
    let d;
    if (isPulseValve(c)) {
      if (relay1 === c.relay) d = level ? RawDecision.SAFE : RawDecision.REJECT;
      else d = level ? RawDecision.REJECT : RawDecision.NOOP;
    } else if (isValve(c)) {
      d = (!!level === relayLevelFor(c, true)) ? RawDecision.SAFE : RawDecision.REJECT;
    } else {
      d = level ? RawDecision.REJECT : RawDecision.SAFE;
    }
    return { d, act: i };
  }
  return { d: RawDecision.NOT_ACTUATOR, act: -1 };
}

const PS = Object.freeze({ IDLE: 0, RUN_CLOSE: 1, RUN_OPEN: 2, DEAD: 3 });

export class ActuatorCore {
  constructor() { this.cfg_ = []; this.n_ = 0; this.posDirty_ = false; this.rt_ = []; }

  static #rt() {
    return {
      cmdAt: 0, fbMs: 0, sirenRunMs: 0, lastTick: 0, psAt: 0, lastOffAt: 0, ps: PS.IDLE, psPending: 0, everRan: false,
      known: false, closed: false, on: false, fbSeen: false, fbActive: false, fbFault: false,
    };
  }

  configure(a, n, posOpenBits, posKnownBits, nowMs) {
    this.cfg_ = a;
    this.n_ = Math.min(n, MAX_ACTUATORS);
    this.rt_ = Array.from({ length: MAX_ACTUATORS }, () => ActuatorCore.#rt());
    this.posDirty_ = false;
    for (let i = 0; i < this.n_; i++) {
      const r = this.rt_[i];
      r.cmdAt = u32(nowMs);
      if (!isValve(a[i])) continue;
      if (isGasValve(a[i])) { r.known = true; r.closed = true; } else if (posKnownBits & (1 << i)) { r.known = true; r.closed = !(posOpenBits & (1 << i)); }
    }
  }

  /**
   * Calisirken yama (EM-2/EM-3): configure gibi kurar, eslenen satirin (fromOld[j] = eski indeks, -1 yeni) calisma durumunu tasir
   * (konum, geri bildirim zamanlayicisi/arizasi, darbe, siren butcesi).
   */
  reconfigure(a, n, posOpenBits, posKnownBits, fromOld, nowMs) {
    const saved = this.rt_;
    const oldN = this.n_;
    const dirty = this.posDirty_;
    this.configure(a, n, posOpenBits, posKnownBits, nowMs);
    this.posDirty_ = dirty;
    for (let j = 0; fromOld && j < this.n_; j++) {
      const i = fromOld[j];
      if (i >= 0 && i < oldN) this.rt_[j] = { ...saved[i] };
    }
  }

  count() { return this.n_; }
  config(i) { return i < this.n_ ? this.cfg_[i] : null; }

  commandValve(i, closed, nowMs) {
    if (i >= this.n_ || !isValve(this.cfg_[i])) return;
    const r = this.rt_[i];
    const changed = !r.known || r.closed !== !!closed;
    if (changed) this.posDirty_ = true;
    if (changed || !r.known) { r.cmdAt = u32(nowMs); r.fbMs = 0; }
    r.known = true;
    r.closed = !!closed;
    if (isPulseValve(this.cfg_[i])) this.#pulseCommand(r, closed ? PS.RUN_CLOSE : PS.RUN_OPEN, u32(nowMs));
  }

  commandSwitch(i, on, nowMs) {
    if (i >= this.n_ || isValve(this.cfg_[i])) return;
    const r = this.rt_[i];
    if (on && !r.on) r.lastTick = u32(nowMs);
    r.on = !!on;
  }

  setFeedback(i, diActive) {
    if (i >= this.n_ || this.cfg_[i].fb_di === 0) return;
    this.rt_[i].fbSeen = true;
    this.rt_[i].fbActive = !!diActive;
  }

  tick(nowMs) {
    nowMs = u32(nowMs);
    for (let i = 0; i < this.n_; i++) {
      const c = this.cfg_[i];
      const r = this.rt_[i];
      if (isPulseValve(c)) this.#pulseTick(c, r, nowMs);
      if (isValve(c)) {
        const fbc = this.fbClosed(i);
        if (this.hasFb(i) && r.closed && fbc && r.fbMs === 0) r.fbMs = u32(nowMs - r.cmdAt);
        if (!this.hasFb(i) || !r.closed || fbc) r.fbFault = false;
        else if (u32(nowMs - r.cmdAt) >= (c.fb_timeout_s || FB_TIMEOUT_DEFAULT_S) * 1000) r.fbFault = true;
      } else if (c.kind === ActKind.SIREN) {
        if (this.#sirenOutput(i)) r.sirenRunMs = Math.min(0xFFFFFFFF, r.sirenRunMs + u32(nowMs - r.lastTick));
        r.lastTick = nowMs;
      }
    }
  }

  levelOf(relay1) {
    const b = relayBit(relay1);
    for (let i = 0; b && i < this.n_; i++) {
      const c = this.cfg_[i];
      if (!(relayBits(c) & b)) continue;
      const r = this.rt_[i];
      if (isPulseValve(c)) return relay1 === c.relay ? r.ps === PS.RUN_CLOSE : r.ps === PS.RUN_OPEN;
      if (isValve(c)) return relayLevelFor(c, r.known ? r.closed : false);
      if (c.kind === ActKind.SIREN) return this.#sirenOutput(i);
      return r.on;
    }
    return false;
  }
  relayMask() { return actuatorRelayMask(this.cfg_, this.n_); }
  levelMask() {
    const rm = this.relayMask();
    let m = 0n;
    for (let r = 1; r <= MAX_RELAYS; r++) if ((rm & relayBit(r)) && this.levelOf(r)) m |= relayBit(r);
    return m;
  }
  fbDiMask() {
    let m = 0n;
    for (let i = 0; i < this.n_; i++) if (this.cfg_[i].fb_di >= 1 && this.cfg_[i].fb_di <= MAX_DI) m |= 1n << BigInt(this.cfg_[i].fb_di - 1);
    return m;
  }

  known(i) { return i < this.n_ && this.rt_[i].known; }
  closedCmd(i) { return i < this.n_ && this.rt_[i].known && this.rt_[i].closed; }
  on(i) { return i < this.n_ && this.rt_[i].on; }
  output(i) { return i < this.n_ && (this.cfg_[i].kind === ActKind.SIREN ? this.#sirenOutput(i) : this.rt_[i].on); }
  hasFb(i) { return i < this.n_ && this.cfg_[i].fb_di !== 0; }
  fbSeen(i) { return i < this.n_ && this.rt_[i].fbSeen; }
  fbClosed(i) { return i < this.n_ && this.rt_[i].fbSeen && (this.rt_[i].fbActive === (this.cfg_[i].fb_closed_active !== 0)); }
  fbFault(i) { return i < this.n_ && this.rt_[i].fbFault; }
  fbMs(i) { return i < this.n_ ? this.rt_[i].fbMs : 0; }
  pulsing(i) { return i < this.n_ && this.rt_[i].ps !== PS.IDLE; }

  pos(i) {
    if (i >= this.n_ || !isValve(this.cfg_[i]) || !this.rt_[i].known) return ValvePos.UNKNOWN;
    const r = this.rt_[i];
    if (this.hasFb(i) && r.fbSeen) {
      const fbc = this.fbClosed(i);
      if (r.closed) return fbc ? ValvePos.CLOSED : ValvePos.CLOSING;
      return fbc ? ValvePos.OPENING : ValvePos.OPEN;
    }
    if (isPulseValve(this.cfg_[i]) && r.ps !== PS.IDLE) return r.closed ? ValvePos.CLOSING : ValvePos.OPENING;
    return r.closed ? ValvePos.CMD_CLOSED : ValvePos.CMD_OPEN;
  }

  posOpenBits() {
    let m = 0;
    for (let i = 0; i < this.n_; i++) if (isValve(this.cfg_[i]) && this.rt_[i].known && !this.rt_[i].closed) m |= 1 << i;
    return m;
  }
  posKnownBits() {
    let m = 0;
    for (let i = 0; i < this.n_; i++) if (isValve(this.cfg_[i]) && this.rt_[i].known) m |= 1 << i;
    return m;
  }
  takePosDirty() { const d = this.posDirty_; this.posDirty_ = false; return d; }

  resetSirenBudget(i) { if (i < this.n_) this.rt_[i].sirenRunMs = 0; }
  sirenRunMs(i) { return i < this.n_ ? this.rt_[i].sirenRunMs : 0; }
  setSirenRunMs(i, ms) { if (i < this.n_) this.rt_[i].sirenRunMs = u32(ms); }
  sirenLimited(i) {
    if (i >= this.n_ || this.cfg_[i].kind !== ActKind.SIREN) return false;
    return this.rt_[i].sirenRunMs >= (this.cfg_[i].run_limit_s || SIREN_RUN_DEFAULT_S) * 1000;
  }

  #sirenOutput(i) { return this.rt_[i].on && !this.sirenLimited(i); }

  #pulseCommand(r, dir, nowMs) {
    if (r.ps === dir) return;
    if (r.ps === PS.RUN_CLOSE || r.ps === PS.RUN_OPEN) { r.ps = PS.DEAD; r.psAt = nowMs; r.psPending = dir; return; }
    if (r.ps === PS.DEAD) { r.psPending = dir; return; }
    if (r.everRan && u32(nowMs - r.lastOffAt) < PULSE_DEAD_MS) { r.ps = PS.DEAD; r.psAt = r.lastOffAt; r.psPending = dir; return; }
    r.ps = dir;
    r.psAt = nowMs;
  }

  #pulseTick(c, r, nowMs) {
    if (r.ps === PS.DEAD) {
      if (u32(nowMs - r.psAt) >= PULSE_DEAD_MS) { r.ps = r.psPending; r.psAt = nowMs; }
    } else if (r.ps === PS.RUN_CLOSE || r.ps === PS.RUN_OPEN) {
      if (u32(nowMs - r.psAt) >= pulseMs(c)) { r.ps = PS.IDLE; r.lastOffAt = nowMs; r.everRan = true; }
    }
  }
}
