// safety/SafetyFsm.h (firmware) BIREBIR JavaScript portu: SafetyCore (bolge durum makinesi NORMAL/LATCHED/FAULT/TEST, kilit,
// kuruluk sayaci, sensor sagligi, tur -> akiskan eslemesi, acma izni, guvenli kip). SAF MANTIK; saat parametre.
//
// Akis (her loop turunda): kaynaklar (DiSensor/BridgeSensor) -> SensorHub -> bolge FSM -> ActuatorCore -> outputMasks()
// -> Automation.applySafetyOutput (want). Kararlar firmware dosyasinin basligindadir (spec 5.1.1-5.1.6, K3, K-4, Y-1, Y-3).
//
// Dogrulama: test/fw_safety_fsm.test.js, firmware'in Unity testlerinin (test/test_safety_fsm) BIREBIR portudur.
// Inceleme turu (entegrasyon): yeni tur = yeni alarm olayi [E2E-2]; FAULT kilit kaydindan FAULT olarak doner, geri bildirim KAPALI
// gorulmeden FAULT/kilit kalkmaz [EM-2]; acilista kapali komutlu iki roleli vanaya KAPAT darbesi [EM-3]; test sonu geri acma kullanici
// kapatmasina ve acma iznine uyar [EM-4]; guvenli kipte acilis guvenli maskesi (imposeBootMask) [EM-5]; reconfigured eslemeyle tasir.
// Faz 2 (F2.B.4): siren rolesi tehlike ve hirsiz isteginin VEYA'si (setIntrusionSiren, ayri butce); ARM_KEY vana surmez.
import {
  MAX_ZONES, MAX_ACTUATORS, MAX_SENSORS, SensorSrc, SensorKind, HZ_ALL, HZ_GAS, HZ_SMOKE, hazardOf, isControlRole, sensorIdCode,
  makeSensorConfig,
} from './sensor_hub.js';
import {
  ActKind, AF_FAN_EXPROOF, FB_TIMEOUT_DEFAULT_S, isValve, isPulseValve, isGasValve, mediumHazard, relayBit, relayBits,
  relayLevelFor, applyLatchMask, rawCommand, RawDecision,
} from './actuator_map.js';
import {
  DRY_HOLD_DEFAULT_MS, CRASH_EXIT_MS, SafeReason, latchValid, latchAny, latchAssert64, latchLevel64, latchClear, latchSetMasks, latchSeal,
} from './safety_config.js';
import { EvType, makeEvent } from './event_outbox.js';

export const ZoneSt = Object.freeze({ NORMAL: 0, LATCHED: 1, FAULT: 2, TEST: 3 });
export const zoneStText = (s) => ['normal', 'latched', 'fault', 'test'][s] ?? 'normal';

export const Rej = Object.freeze({
  OK: 0, ZONE_LATCHED: 1, ZONE_TEST: 2, ACTUATOR_RELAY: 3, UNKNOWN_ACTUATOR: 4, BAD_STATE: 5, UNSUPPORTED: 6, CFG_CONFLICT: 7,
  CFG_INVALID: 8, GAS_LOCAL_ONLY: 9, STALE_ACK: 10, SAFE_MODE: 11, BAD_CMD: 12, BUSY: 13, NOT_READY: 14, CFG_STORAGE: 15, ARMED: 16,
});
const REJ_TEXT = [
  '', 'zone_latched', 'zone_test', 'actuator_relay', 'unknown_actuator', 'bad_state', 'unsupported', 'cfg_conflict', 'cfg_invalid',
  'gas_local_only', 'stale_ack', 'safe_mode', 'bad_cmd', 'busy', 'not_ready', 'cfg_storage', 'armed',
];
/** Hirsiz siren tetigi (IntrusionCore -> setIntrusionSiren): FRESH butceyi her durumda sifirlar; RETRIGGER yalniz durmus sireni. */
export const SirenKick = Object.freeze({ NONE: 0, FRESH: 1, RETRIGGER: 2 });
export const rejText = (r) => REJ_TEXT[r] ?? '';

export const Origin = Object.freeze({ REMOTE: 0, LOCAL_DI: 1, GAS_RESET: 2, SAFETY: 3 });
export const TEST_SIREN_MS = 3000;
export const TEST_NOFB_MS = 5000;
export const SAFE_ACK_HOLD_MS = 5000;

const u32 = (x) => x >>> 0;
const zbit = (z) => 1 << (z - 1);
const emptyZone = () => ({
  st: ZoneSt.NORMAL, kinds: 0, silenced: false, acked: false, aid: '', sinceMs: 0, sinceEpoch: 0, srcs: [], testAt: 0,
  testValves: 0, testPrevOpen: 0,
});
const valveMatches = (a, z, kinds) => isValve(a) && !!(a.zone_mask & zbit(z)) && !!(mediumHazard(a.medium) & kinds);

export class SafetyCore {
  constructor() {
    this.cfg_ = null; this.hub_ = null; this.act_ = null; this.out_ = null;
    this.mode_ = SafeReason.NONE; this.bootAt_ = 0; this.epoch_ = 0; this.policyOn_ = true; this.cfgUsable_ = false;
    this.latchDirty_ = false; this.latchAssert_ = 0n; this.latchLevel_ = 0n; this.latchRecAssert_ = 0n;
    this.zone_ = Array.from({ length: MAX_ZONES + 1 }, emptyZone);
    this.manualOn_ = new Array(MAX_ACTUATORS).fill(false);
    this.userSuppress_ = new Array(MAX_ACTUATORS).fill(false);
    this.intrSuppress_ = new Array(MAX_ACTUATORS).fill(false);
    this.intrReq_ = false;
    this.holdFired_ = new Array(MAX_SENSORS).fill(false);
  }

  begin(cfg, hub, act, out, latch, mode, nowMs) {
    nowMs = u32(nowMs);
    this.cfg_ = cfg; this.hub_ = hub; this.act_ = act; this.out_ = out;
    this.mode_ = mode; this.bootAt_ = nowMs; this.epoch_ = 0;
    this.policyOn_ = cfg ? cfg.pol.policy_on !== 0 : true;
    this.cfgUsable_ = false; this.latchDirty_ = false; this.latchAssert_ = 0n; this.latchLevel_ = 0n; this.latchRecAssert_ = 0n;
    this.zone_ = Array.from({ length: MAX_ZONES + 1 }, emptyZone);
    this.manualOn_.fill(false); this.userSuppress_.fill(false); this.holdFired_.fill(false);
    this.intrSuppress_ = new Array(MAX_ACTUATORS).fill(false);
    this.intrReq_ = false;
    if (latch && latchValid(latch) && latchAny(latch)) {
      for (let z = 1; z <= MAX_ZONES; z++) {
        const lz = latch.z[z - 1];
        if (lz.st === 0) continue;
        const Z = this.zone_[z];
        Z.st = lz.st === ZoneSt.FAULT ? ZoneSt.FAULT : ZoneSt.LATCHED;   // FAULT, geri bildirim KAPALI gorulene dek [EM-2]
        Z.kinds = lz.kinds || HZ_ALL;
        Z.silenced = !!lz.silenced;
        Z.acked = !!lz.acked;
        Z.aid = String(lz.aid || '').slice(0, 14);
        Z.sinceMs = nowMs;
        Z.sinceEpoch = lz.sinceEpoch;
        Z.srcs = lz.srcs.slice(0, Math.min(8, lz.nsrcs));
      }
      this.latchAssert_ = latchAssert64(latch);
      this.latchLevel_ = latchLevel64(latch);
    }
    this.latchRecAssert_ = this.latchAssert_;
    for (let i = 0; act && i < act.count(); i++) {   // kapali komutlu iki roleli vanaya acilista KAPAT darbesi [EM-3]
      if (isPulseValve(act.config(i)) && act.closedCmd(i)) act.commandValve(i, true, nowMs);
    }
    if (this.mode_ !== SafeReason.NONE) this.#emit({ ...this.#blank(EvType.SAFE_MODE, 0, nowMs), sub: this.mode_ });
    this.#enforceLatchedValves(nowMs);
  }

  setConfigUsable(v) { this.cfgUsable_ = !!v; }

  /** Hirsiz alarminin siren istegi (F2.B.4). req kalkinca kullanici bastirmasi da kalkar; cikis ayni turda surulur. */
  setIntrusionSiren(req, kick, nowMs) {
    if (!this.act_) return;
    if (!req) this.intrSuppress_ = new Array(MAX_ACTUATORS).fill(false);
    for (let i = 0; i < this.act_.count(); i++) {
      if (this.act_.config(i).kind !== ActKind.SIREN) continue;
      if (kick === SirenKick.FRESH || (kick === SirenKick.RETRIGGER && this.act_.intrusionLimited(i))) this.act_.restartIntrusion(i);
    }
    this.intrReq_ = !!req;
    this.#driveSwitches(u32(nowMs));
  }
  intrusionSirenRequested() { return this.intrReq_; }

  /**
   * Calisirken yapilandirma degisti: elle acik / kullanici susturmasi / test vana bitleri fromOld eslemesiyle (actuatorIdentityMap; null =
   * hicbiri) tasinir, eslenmeyenler sifirlanir; politika yeni yapilandirmadan (policy_changed, via). Bolgeler korunur.
   */
  reconfigured(via, nowMs, fromOld = null) {
    const man = this.manualOn_;
    const sup = this.userSuppress_;
    const isup = this.intrSuppress_;
    this.manualOn_ = new Array(MAX_ACTUATORS).fill(false);
    this.userSuppress_ = new Array(MAX_ACTUATORS).fill(false);
    this.intrSuppress_ = new Array(MAX_ACTUATORS).fill(false);
    for (let z = 1; z <= MAX_ZONES; z++) {
      const Z = this.zone_[z];
      const tv = Z.testValves;
      const tp = Z.testPrevOpen;
      Z.testValves = 0;
      Z.testPrevOpen = 0;
      for (let j = 0; fromOld && j < MAX_ACTUATORS; j++) {
        const i = fromOld[j];
        if (i < 0 || i >= MAX_ACTUATORS) continue;
        if (tv & (1 << i)) Z.testValves |= 1 << j;
        if (tp & (1 << i)) Z.testPrevOpen |= 1 << j;
      }
    }
    for (let j = 0; fromOld && j < MAX_ACTUATORS; j++) {
      const i = fromOld[j];
      if (i < 0 || i >= MAX_ACTUATORS) continue;
      this.manualOn_[j] = man[i];
      this.userSuppress_[j] = sup[i];
      this.intrSuppress_[j] = isup[i];
    }
    this.holdFired_ = new Array(MAX_SENSORS).fill(false);
    if (this.cfg_) this.setPolicy(this.cfg_.pol.policy_on !== 0, via, nowMs);
    this.#enforceLatchedValves(nowMs);
  }

  tick(nowMs, epoch, di, bridge) {
    nowMs = u32(nowMs);
    this.epoch_ = u32(epoch || 0);
    if (!this.cfg_ || !this.hub_ || !this.act_) return;
    if (!this.active()) return;
    for (let i = 0; i < this.hub_.count(); i++) {
      const c = this.hub_.config(i);
      const src = c.src === SensorSrc.BRIDGE ? bridge : di;
      const s = src ? src.sample(c, nowMs) : { level: false, ok: false };
      this.hub_.update(i, s.level, s.ok, nowMs);
    }
    this.hub_.finish(nowMs);
    for (let i = 0; i < this.act_.count(); i++) {
      const a = this.act_.config(i);
      if (a.fb_di === 0 || !di) continue;
      const s = di.sample(makeSensorConfig({ src: SensorSrc.DI, index: a.fb_di }), nowMs);
      if (s.ok) this.act_.setFeedback(i, s.level);
    }
    this.act_.tick(nowMs);
    this.#sensorFaultEvents(nowMs);
    this.#controlRoles(nowMs);
    for (let z = 1; z <= MAX_ZONES; z++) this.#stepZone(z, nowMs);
    if (this.mode_ === SafeReason.CRASH_LOOP && u32(nowMs - this.bootAt_) >= CRASH_EXIT_MS) {
      this.mode_ = SafeReason.NONE;
      this.latchAssert_ = 0n;
      this.latchLevel_ = 0n;
      this.latchDirty_ = true;
    }
    this.#enforceLatchedValves(nowMs);
    this.#driveSwitches(nowMs);
    this.act_.tick(nowMs);
  }

  ack(zone, aid, origin, force, nowMs) {
    if (zone > MAX_ZONES) return Rej.BAD_STATE;
    if (this.mode_ !== SafeReason.NONE && force) {
      if (origin !== Origin.LOCAL_DI || this.mode_ === SafeReason.CRASH_LOOP || !this.cfgUsable_) return Rej.SAFE_MODE;
      this.#exitSafeMode(nowMs);
      return Rej.OK;
    }
    const Zq = this.zone_[zone];
    if (zone !== 0 && aid && Zq.st !== ZoneSt.NORMAL && Zq.st !== ZoneSt.TEST && aid !== Zq.aid) return Rej.STALE_ACK;
    for (let z = 1; z <= MAX_ZONES; z++) {
      if (zone !== 0 && z !== zone) continue;
      const Z = this.zone_[z];
      if (Z.st !== ZoneSt.LATCHED && Z.st !== ZoneSt.FAULT) continue;
      Z.acked = true;
      this.latchDirty_ = true;
      if (this.#canClear(z, nowMs)) this.#clearZone(z, nowMs);
      else if (!Z.silenced) {
        Z.silenced = true;
        this.#emit({ ...this.#blank(EvType.ALARM_SILENCED, z, nowMs), kinds: Z.kinds, aid: Z.aid });
      }
    }
    return Rej.OK;
  }

  test(zone, nowMs) {
    if (zone < 1 || zone > MAX_ZONES) return Rej.BAD_STATE;
    if (this.mode_ !== SafeReason.NONE) return Rej.SAFE_MODE;
    const Z = this.zone_[zone];
    if (Z.st === ZoneSt.TEST) return Rej.ZONE_TEST;
    if (Z.st !== ZoneSt.NORMAL) return Rej.ZONE_LATCHED;
    Z.st = ZoneSt.TEST;
    Z.testAt = u32(nowMs);
    Z.testValves = 0;
    Z.testPrevOpen = 0;
    for (let i = 0; i < this.act_.count(); i++) {
      const a = this.act_.config(i);
      if (!isValve(a) || !(a.zone_mask & zbit(zone))) continue;
      Z.testValves |= 1 << i;
      if (!this.act_.closedCmd(i)) Z.testPrevOpen |= 1 << i;
      this.act_.commandValve(i, true, nowMs);
    }
    return Rej.OK;
  }

  actuatorSet(i, safe, origin, nowMs) {
    if (!this.act_ || i >= this.act_.count()) return Rej.UNKNOWN_ACTUATOR;
    const a = this.act_.config(i);
    const bit = 1 << i;
    const e = this.#blank(EvType.ACTUATOR_CHANGED, 0, nowMs);
    if (isValve(a)) {
      if (safe) {
        const changed = !this.act_.closedCmd(i);
        for (let z = 1; z <= MAX_ZONES; z++) this.zone_[z].testPrevOpen &= ~bit;   // kullanici kapatti: test sonu acilmaz [EM-4]
        this.act_.commandValve(i, true, nowMs);
        if (changed) this.#emit({ ...e, actClose: bit });
        return Rej.OK;
      }
      if (this.mode_ !== SafeReason.NONE) return Rej.SAFE_MODE;
      if (isGasValve(a) && origin !== Origin.GAS_RESET) return Rej.GAS_LOCAL_ONLY;
      const r = this.#openPermission(a);
      if (r !== Rej.OK) return r;
      const changed = this.act_.closedCmd(i) || !this.act_.known(i);
      this.act_.commandValve(i, false, nowMs);
      if (changed) this.#emit({ ...e, actOpen: bit });
      return Rej.OK;
    }
    if (safe) {
      const was = this.manualOn_[i] || this.act_.on(i) || this.act_.intrusionOn(i);
      this.manualOn_[i] = false;
      if (this.#autoOn(i, nowMs)) this.userSuppress_[i] = true;
      if (this.intrReq_ && a.kind === ActKind.SIREN) this.intrSuppress_[i] = true;   // hirsiz istegi de bu alarm donemi icin bastirilir
      if (was) this.#emit({ ...e, actOff: bit });
      return Rej.OK;
    }
    if (a.kind === ActKind.FAN) {
      for (let z = 1; z <= MAX_ZONES; z++) {
        if (!(a.zone_mask & zbit(z)) || !this.#latched(z)) continue;
        const k = this.zone_[z].kinds;
        if ((k & HZ_SMOKE) || ((k & HZ_GAS) && !(a.aflags & AF_FAN_EXPROOF))) return Rej.ZONE_LATCHED;
      }
    }
    if (!this.manualOn_[i]) this.#emit({ ...e, actOn: bit });
    this.manualOn_[i] = true;
    this.userSuppress_[i] = false;
    return Rej.OK;
  }

  rawRelay(relay1, level, origin, nowMs) {
    if (!this.cfg_) return RawDecision.NOT_ACTUATOR;
    const r = rawCommand(this.cfg_.act, this.act_ ? this.act_.count() : 0, relay1, level);
    if (r.d === RawDecision.SAFE) this.actuatorSet(r.act, true, origin, nowMs);
    return r.d;
  }

  setPolicy(on, via, nowMs) {
    if (!!on === this.policyOn_) return;
    this.policyOn_ = !!on;
    this.#emit({ ...this.#blank(EvType.POLICY_CHANGED, 0, nowMs), flag: on ? 1 : 0, sub: via });
  }

  /** @returns {{assert: bigint, level: bigint}} */
  outputMasks() {
    const la = this.mode_ !== SafeReason.NONE ? this.latchAssert_ : 0n;
    const base = this.act_ ? this.act_.levelMask() : 0n;
    const assert = (this.act_ ? this.act_.relayMask() : 0n) | la;
    return { assert, level: applyLatchMask(base, la, this.latchLevel_) & assert };
  }

  /** Guvenli kip: kalici acilis guvenli maskesi kilit maskesinin dayatmadigi rolelere eklenir (seviyede kilit kaydi kazanir) [EM-5]. */
  imposeBootMask(assertMask, levelMask) {
    if (this.mode_ === SafeReason.NONE) return;
    const add = BigInt(assertMask) & ~this.latchAssert_;
    this.latchAssert_ |= add;
    this.latchLevel_ = (this.latchLevel_ & ~add) | (BigInt(levelMask) & add);
  }
  /** Kilit kaydindan gelen maske (acilis guvenli maskesi haric): guvenli kipten cikis kullanilabilirligi bununla. */
  latchRecordAssert() { return this.latchRecAssert_; }

  /** Guvenli kipte dayatilan kilit maskesi (ValveGuard tutma maskesine eklenir); guvenli kip degilse 0. */
  latchMasks() {
    const a = this.mode_ !== SafeReason.NONE ? this.latchAssert_ : 0n;
    return { assert: a, level: this.latchLevel_ & a };
  }

  buzzer() {
    for (let z = 1; z <= MAX_ZONES; z++) if (this.#latched(z) && !this.zone_[z].silenced) return true;
    return false;
  }

  buildLatch() {
    const r = latchClear();
    let as = 0n;
    let lv = 0n;
    for (let z = 1; z <= MAX_ZONES; z++) {
      const Z = this.zone_[z];
      if (!this.#latched(z)) continue;
      const lz = r.z[z - 1];
      lz.st = Z.st; lz.kinds = Z.kinds; lz.silenced = Z.silenced ? 1 : 0; lz.acked = Z.acked ? 1 : 0;
      lz.aid = Z.aid; lz.nsrcs = Z.srcs.length; lz.sinceEpoch = Z.sinceEpoch;
      lz.srcs = [...Z.srcs, 0, 0, 0, 0, 0, 0, 0, 0].slice(0, 8);
      for (let i = 0; this.act_ && i < this.act_.count(); i++) {
        const a = this.act_.config(i);
        if (!valveMatches(a, z, Z.kinds)) continue;
        if (isPulseValve(a)) as |= relayBit(a.relay2);
        else {
          as |= relayBit(a.relay);
          if (relayLevelFor(a, true)) lv |= relayBit(a.relay);
        }
      }
    }
    if (this.mode_ !== SafeReason.NONE) {
      lv = (lv & ~this.latchAssert_) | (this.latchLevel_ & this.latchAssert_);
      as |= this.latchAssert_;
    }
    latchSetMasks(r, as, lv);
    return latchSeal(r);
  }
  takeLatchDirty() { const d = this.latchDirty_; this.latchDirty_ = false; return d; }
  markLatchDirty() { this.latchDirty_ = true; }   // NVS yazimi basarisiz: kilit kaydi yeniden denenecek (fw-tarama-5)

  /** Sensor/eylemci, kilit, test ya da guvenli kip yoksa cekirdek bostadir (tick O(1)). */
  active() {
    let zones = false;
    for (let z = 1; z <= MAX_ZONES && !zones; z++) zones = this.zone_[z].st !== ZoneSt.NORMAL;
    return (!!this.cfg_ && (this.cfg_.nSens > 0 || this.cfg_.nAct > 0)) || this.mode_ !== SafeReason.NONE || zones;
  }
  safeMode() { return this.mode_ !== SafeReason.NONE; }
  safeReason() { return this.mode_; }
  policyOn() { return this.policyOn_; }
  zoneState(z) { return z >= 1 && z <= MAX_ZONES ? this.zone_[z].st : ZoneSt.NORMAL; }
  zone(z) { return this.zone_[z >= 1 && z <= MAX_ZONES ? z : 0]; }
  latchedZoneMask() {
    let m = 0;
    for (let z = 1; z <= MAX_ZONES; z++) if (this.#latched(z)) m |= zbit(z);
    return m;
  }
  sinceUpS(z, nowMs) { return Math.floor(u32(u32(nowMs) - this.zone_[z].sinceMs) / 1000); }

  // ------------------------------------------------------------------------------------------------ ic
  #latched(z) { return this.zone_[z].st === ZoneSt.LATCHED || this.zone_[z].st === ZoneSt.FAULT; }
  #blank(type, zone, nowMs) { return makeEvent({ type, zone, atUp: Math.floor(u32(u32(nowMs) - this.bootAt_) / 1000), atEpoch: this.epoch_ }); }
  #emit(e) { return this.out_ ? this.out_.push(e) : ''; }

  #openPermission(a) {
    const hz = mediumHazard(a.medium);
    for (let z = 1; z <= MAX_ZONES; z++) {
      if (!(a.zone_mask & zbit(z))) continue;
      if (this.zone_[z].st === ZoneSt.TEST) return Rej.ZONE_TEST;
      if (this.zone_[z].st !== ZoneSt.NORMAL) return Rej.ZONE_LATCHED;
      for (let s = 0; s < this.hub_.count(); s++) {
        const c = this.hub_.config(s);
        if (c.zone !== z || hazardOf(c.kind) !== hz) continue;
        if (!this.hub_.idle(s)) return Rej.ZONE_LATCHED;
      }
    }
    return Rej.OK;
  }

  #canClear(z, nowMs) {
    const Z = this.zone_[z];
    if (this.mode_ !== SafeReason.NONE || Z.st !== ZoneSt.LATCHED || !Z.acked) return false;
    if (this.#fbUnconfirmed(z)) return false;   // geri bildirimli vana KAPALI gorulmedi [EM-2]
    return this.hub_.zoneDryMs(z, nowMs) >= (this.cfg_.pol.dry_hold_ms || DRY_HOLD_DEFAULT_MS);
  }

  #fbUnconfirmed(z) {
    for (let i = 0; i < this.act_.count(); i++) {
      if (valveMatches(this.act_.config(i), z, this.zone_[z].kinds) && this.act_.hasFb(i) && !this.act_.fbClosed(i)) return true;
    }
    return false;
  }

  #raise(z, kinds, nowMs) {
    const Z = this.zone_[z];
    Z.st = ZoneSt.LATCHED; Z.kinds = kinds; Z.silenced = false; Z.acked = false;
    Z.sinceMs = u32(nowMs); Z.sinceEpoch = this.epoch_;
    Z.srcs = this.hub_.zoneSources(z, kinds, 8);
    const e = { ...this.#blank(EvType.ALARM_RAISED, z, nowMs), kinds, nsrcs: Z.srcs.length, srcs: Z.srcs.slice() };
    this.#applyAlarmActions(z, kinds, nowMs, e);
    this.latchDirty_ = true;
    Z.aid = this.#emit(e);
  }

  #applyAlarmActions(z, kinds, nowMs, e) {
    for (let i = 0; i < this.act_.count(); i++) {
      const a = this.act_.config(i);
      if (!(a.zone_mask & zbit(z))) continue;
      const bit = 1 << i;
      if (isValve(a)) {
        if (mediumHazard(a.medium) & kinds) { this.act_.commandValve(i, true, nowMs); e.actClose |= bit; }
      } else if (a.kind === ActKind.SIREN) {
        this.act_.resetSirenBudget(i);
        this.userSuppress_[i] = false;
        e.actOn |= bit;
      } else if (a.kind === ActKind.FAN) {
        if (kinds & HZ_SMOKE) e.actOff |= bit;
        else if ((kinds & HZ_GAS) && (a.aflags & AF_FAN_EXPROOF)) e.actOn |= bit;
      }
    }
  }

  #clearZone(z, nowMs) {
    const e = { ...this.#blank(EvType.ALARM_CLEARED, z, nowMs), kinds: this.zone_[z].kinds, aid: this.zone_[z].aid };
    this.zone_[z] = emptyZone();
    this.latchDirty_ = true;
    this.#emit(e);
  }

  #exitSafeMode(nowMs) {
    for (let z = 1; z <= MAX_ZONES; z++) {
      if (!this.#latched(z)) continue;
      for (let i = 0; i < this.act_.count(); i++) if (valveMatches(this.act_.config(i), z, this.zone_[z].kinds)) this.act_.commandValve(i, true, nowMs);
      this.#clearZone(z, nowMs);
    }
    for (let i = 0; i < this.act_.count(); i++) {
      const a = this.act_.config(i);
      if (isValve(a) && (relayBits(a) & this.latchAssert_)) this.act_.commandValve(i, true, nowMs);
    }
    this.mode_ = SafeReason.NONE;
    this.latchAssert_ = 0n;
    this.latchLevel_ = 0n;
    this.latchDirty_ = true;
  }

  #fbFaultInZone(z) {
    let faulty = 0;
    for (let i = 0; i < this.act_.count(); i++) if (valveMatches(this.act_.config(i), z, this.zone_[z].kinds) && this.act_.fbFault(i)) faulty |= 1 << i;
    return faulty;
  }

  #stepZone(z, nowMs) {
    const Z = this.zone_[z];
    const wet = this.policyOn_ ? this.hub_.zoneWet(z) : 0;
    switch (Z.st) {
      case ZoneSt.NORMAL:
        if (wet) this.#raise(z, wet, nowMs);
        break;
      case ZoneSt.TEST:
        if (wet) { Z.testValves = 0; this.#raise(z, wet, nowMs); } else this.#stepTest(z, nowMs);
        break;
      default: {
        if (wet & ~Z.kinds) {                      // yeni tehlike turu: YENI alarm olayi, bolgenin aid'si yenilenir [E2E-2]
          const add = wet & ~Z.kinds;
          Z.kinds |= add; Z.silenced = false; Z.acked = false;
          this.#joinSources(z);
          const e = { ...this.#blank(EvType.ALARM_RAISED, z, nowMs), kinds: Z.kinds, nsrcs: Z.srcs.length, srcs: Z.srcs.slice() };
          this.#applyAlarmActions(z, add, nowMs, e);
          this.latchDirty_ = true;
          Z.aid = this.#emit(e);
        }
        if (wet) this.#joinSources(z);
        const faulty = this.#fbFaultInZone(z);
        if (Z.st === ZoneSt.LATCHED && faulty) {
          Z.st = ZoneSt.FAULT; Z.silenced = false; this.latchDirty_ = true;
          this.#emit({ ...this.#blank(EvType.VALVE_FAULT, z, nowMs), kinds: Z.kinds, actClose: faulty, aid: Z.aid });
        } else if (Z.st === ZoneSt.FAULT && !faulty && !this.#fbUnconfirmed(z)) {
          Z.st = ZoneSt.LATCHED; this.latchDirty_ = true;
          this.#emit({ ...this.#blank(EvType.VALVE_FAULT_CLEARED, z, nowMs), kinds: Z.kinds, aid: Z.aid });
        }
        if (this.#canClear(z, nowMs)) this.#clearZone(z, nowMs);
      }
    }
  }

  #joinSources(z) {
    const Z = this.zone_[z];
    for (const id of this.hub_.zoneSources(z, Z.kinds, 8)) {
      if (Z.srcs.length >= 8) break;
      if (!Z.srcs.includes(id)) { Z.srcs.push(id); this.latchDirty_ = true; }
    }
  }

  #stepTest(z, nowMs) {
    const Z = this.zone_[z];
    let anyFb = false;
    let allClosed = true;
    let tmo = TEST_NOFB_MS;
    let fbMax = 0;
    for (let i = 0; i < this.act_.count(); i++) {
      if (!(Z.testValves & (1 << i)) || !this.act_.hasFb(i)) continue;
      const t = (this.act_.config(i).fb_timeout_s || FB_TIMEOUT_DEFAULT_S) * 1000;
      if (!anyFb || t > tmo) tmo = t;
      anyFb = true;
      if (!this.act_.fbClosed(i)) allClosed = false;
      else if (this.act_.fbMs(i) > fbMax) fbMax = this.act_.fbMs(i);
    }
    const el = u32(u32(nowMs) - Z.testAt);
    const done = anyFb ? (allClosed || el >= tmo) : el >= TEST_NOFB_MS;
    if (!done) return;
    Z.st = ZoneSt.NORMAL;                          // geri acma izni NORMAL bolgeyle degerlendirilir
    for (let i = 0; i < this.act_.count(); i++) {
      if (!(Z.testValves & (1 << i))) continue;
      const a = this.act_.config(i);
      if (isGasValve(a) || !(Z.testPrevOpen & (1 << i))) continue;
      if (this.mode_ === SafeReason.NONE && this.#openPermission(a) === Rej.OK) this.act_.commandValve(i, false, nowMs);   // [EM-4]
    }
    const e = { ...this.#blank(EvType.TEST_RESULT, z, nowMs), flag: (!anyFb || allClosed) ? 1 : 0, sub: anyFb ? 1 : 0, val: Math.min(0xFFFF, fbMax) };
    Z.testValves = 0;
    Z.testPrevOpen = 0;
    this.#emit(e);
  }

  #sensorFaultEvents(nowMs) {
    const f = this.hub_.takeFaultEdges();
    const c = this.hub_.takeFaultClearedEdges();
    for (let i = 0; i < this.hub_.count(); i++) {
      const b = 1n << BigInt(i);
      if (!((f | c) & b)) continue;
      const s = this.hub_.config(i);
      this.#emit({ ...this.#blank((f & b) ? EvType.SENSOR_FAULT : EvType.SENSOR_FAULT_CLEARED, s.zone, nowMs), kinds: hazardOf(s.kind), nsrcs: 1, srcs: [sensorIdCode(s)] });
    }
  }

  #controlRoles(nowMs) {
    const presses = this.hub_.takeControlPresses();
    for (let i = 0; i < this.hub_.count(); i++) {
      const s = this.hub_.config(i);
      if (!isControlRole(s.kind) || s.kind === SensorKind.ARM_KEY) continue;   // ARM_KEY: IntrusionCore
      const zmask = s.zone === 0 ? 0x0F : zbit(s.zone);
      if (presses & (1n << BigInt(i))) {
        if (s.kind === SensorKind.ALARM_ACK) {
          this.ack(s.zone, null, Origin.LOCAL_DI, false, nowMs);
        } else {
          const open = s.kind === SensorKind.GAS_RESET;
          for (let a = 0; a < this.act_.count(); a++) {
            const c = this.act_.config(a);
            if (!isValve(c) || !(c.zone_mask & zmask)) continue;
            if (open && !isGasValve(c)) continue;
            this.actuatorSet(a, !open, open ? Origin.GAS_RESET : Origin.LOCAL_DI, nowMs);
          }
        }
      }
      if (s.kind === SensorKind.ALARM_ACK) {
        const held = this.hub_.heldMs(i, nowMs);
        if (held === 0) this.holdFired_[i] = false;
        else if (held >= SAFE_ACK_HOLD_MS && !this.holdFired_[i]) {
          this.holdFired_[i] = true;
          if (this.mode_ !== SafeReason.NONE) this.ack(s.zone, null, Origin.LOCAL_DI, true, nowMs);
        }
      }
    }
  }

  #autoOn(i, nowMs) {
    const a = this.act_.config(i);
    for (let z = 1; z <= MAX_ZONES; z++) {
      if (!(a.zone_mask & zbit(z))) continue;
      const Z = this.zone_[z];
      if (a.kind === ActKind.SIREN) {
        if (this.#latched(z) && !Z.silenced) return true;
        if (Z.st === ZoneSt.TEST && u32(u32(nowMs) - Z.testAt) < TEST_SIREN_MS) return true;
      } else if (a.kind === ActKind.FAN) {
        if (this.#latched(z) && !(Z.kinds & HZ_SMOKE) && (Z.kinds & HZ_GAS) && (a.aflags & AF_FAN_EXPROOF)) return true;
      }
    }
    return false;
  }

  #forceOff(i) {
    const a = this.act_.config(i);
    if (a.kind !== ActKind.FAN) return false;
    for (let z = 1; z <= MAX_ZONES; z++) if ((a.zone_mask & zbit(z)) && this.#latched(z) && (this.zone_[z].kinds & HZ_SMOKE)) return true;
    return false;
  }

  #driveSwitches(nowMs) {
    for (let i = 0; i < this.act_.count(); i++) {
      if (isValve(this.act_.config(i))) continue;
      const au = this.#autoOn(i, nowMs);
      if (!au) this.userSuppress_[i] = false;
      const fo = this.#forceOff(i);
      if (fo) this.manualOn_[i] = false;
      this.act_.commandSwitch(i, !fo && ((au && !this.userSuppress_[i]) || this.manualOn_[i]), nowMs);
      if (this.act_.config(i).kind === ActKind.SIREN) this.act_.commandIntrusion(i, this.intrReq_ && !this.intrSuppress_[i], nowMs);
    }
  }

  #enforceLatchedValves(nowMs) {
    if (!this.act_) return;
    for (let i = 0; i < this.act_.count(); i++) {
      const a = this.act_.config(i);
      if (!isValve(a) || this.act_.closedCmd(i)) continue;
      for (let z = 1; z <= MAX_ZONES; z++) {
        const hold = (this.#latched(z) && valveMatches(a, z, this.zone_[z].kinds))
          || (this.zone_[z].st === ZoneSt.TEST && (this.zone_[z].testValves & (1 << i)));
        if (hold) { this.act_.commandValve(i, true, nowMs); break; }
      }
    }
  }
}
