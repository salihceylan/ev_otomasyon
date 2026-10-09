// safety/IntrusionFsm.h (firmware) BIREBIR JavaScript portu: hirsiz alarmi cekirdegi (IntrusionCore). SAF MANTIK; saat parametre.
// Faz 2 tasarimi F2.B (plan 2.5), kararlar F2-2..F2-5:
//  * Kip off/home/away, durum idle/exit/entry/alarm; SF_REACT'li door/window/motion dahil; SF_ENTRY giris yolu, SF_AWAY_ONLY yalniz away.
//  * Kurma hazirligi: kipte etkin, giris yolu OLMAYAN her sensor ok && !aktif (ok=false da hazir degil); giris yolu acikken kurulabilir.
//  * Cikis suresinde giris yolu yok sayilir; sure dolunca giris yolu acik ise giris gecikmesi ("cikis hatasi").
//  * Alarmda yukselen kenar srcs'e eklenir; sensorun kurulum donemindeki tetik sayisi < 3 ise durmus siren yeniden (swinger).
//  * Kip/alarm bellegi ArmRecord (NVS "ahbu_latch/arm"); acilista kip geri yuklenir, cikis gecikmesi yok; bellekteki alarm sirensiz.
//  * Guvenli kip (setUsable(false)): alarm uretilmez, kurma safe_mode, cozme serbest.
// Dogrulama: test/fw_intrusion_fsm.test.js, firmware'in Unity testlerinin (test/test_intrusion_fsm) BIREBIR portudur.
import { SensorKind, SF_REACT, SF_ENTRY, SF_AWAY_ONLY, MAX_SENSORS, isIntrusionKind, sensorIdCode } from './sensor_hub.js';
import { Rej, SirenKick } from './safety_fsm.js';
import { EvType, makeEvent, VIA_DI, VIA_BOOT } from './event_outbox.js';
import { EXIT_DEFAULT_S, ENTRY_DEFAULT_S, exitDelayS, entryDelayS } from './safety_config.js';

export const ArmMode = Object.freeze({ OFF: 0, AWAY: 1, HOME: 2 });
export const ArmSt = Object.freeze({ IDLE: 0, EXIT: 1, ENTRY: 2, ALARM: 3 });
export const BuzPattern = Object.freeze({ OFF: 0, EXIT: 1, ENTRY: 2, ALARM: 3 });
export { EXIT_DEFAULT_S, ENTRY_DEFAULT_S, exitDelayS, entryDelayS };
export const SWINGER_MAX = 3;
export const ARM_REC_VER = 1;
// ArmRecord.alarm: 0 yok, ARM_REC_ALARM alarm bellegi (aid), ARM_REC_ENTRY giris gecikmesi suruyordu (pend: giris yolu kodlari; RV-E2)
export const ARM_REC_ALARM = 1;
export const ARM_REC_ENTRY = 2;

export const armModeText = (m) => (m === ArmMode.AWAY ? 'away' : m === ArmMode.HOME ? 'home' : 'off');
export const armStText = (s) => ['idle', 'exit', 'entry', 'alarm'][s] ?? 'idle';
export const ARM_MODE_BY_TEXT = Object.freeze({ off: ArmMode.OFF, away: ArmMode.AWAY, home: ArmMode.HOME });


export function armedIn(c, m) {
  if (m === ArmMode.OFF || !isIntrusionKind(c.kind) || !(c.flags & SF_REACT)) return false;
  return m === ArmMode.AWAY || !(c.flags & SF_AWAY_ONLY);
}
export function hasIntrusionSensors(sens, n) {
  for (let i = 0; i < n; i++) if (isIntrusionKind(sens[i].kind) && (sens[i].flags & SF_REACT)) return true;
  return false;
}

/** Bos ArmRecord (20 B'lik firmware yapisinin alanlari). */
export const makeArmRecord = (o = {}) => ({ ver: ARM_REC_VER, mode: ArmMode.OFF, alarm: 0, aid: '', pend: [], ...o });

const u32 = (x) => x >>> 0;

export class IntrusionCore {
  constructor() { this.cfg_ = null; this.hub_ = null; this.out_ = null; this.#clearRt(); }

  begin(cfg, hub, out, rec, nowMs) {
    this.cfg_ = cfg;
    this.hub_ = hub;
    this.out_ = out;
    this.#clearRt();
    this.bootAt_ = u32(nowMs);
    if (rec && rec.ver === ARM_REC_VER && rec.mode >= 0 && rec.mode <= ArmMode.HOME) {
      this.mode_ = rec.mode;
      if (rec.alarm === ARM_REC_ALARM && this.mode_ !== ArmMode.OFF) {
        this.st_ = ArmSt.ALARM;
        this.aid_ = String(rec.aid || '').slice(0, 14);
        this.restored_ = true;
      } else if (rec.alarm === ARM_REC_ENTRY && this.mode_ !== ArmMode.OFF) {
        // RV-E2: giris gecikmesi bastan; sure dolunca kaydedilen giris yolu sensorleri kaynak olur
        this.st_ = ArmSt.ENTRY;
        for (const code of (Array.isArray(rec.pend) ? rec.pend : []).slice(0, 8)) if (code) IntrusionCore.#addId(this.pend_, code & 0xFF);
        this.#startDelay(entryDelayS(this.cfg_.pol), nowMs);
      }
    }
    if (this.mode_ !== ArmMode.OFF) this.#emit(this.#blank(EvType.ARM_CHANGED, 0, nowMs, { flag: this.mode_, sub: VIA_BOOT }));
  }

  reconfigured(/* nowMs */) {
    this.prev_.fill(false);
    this.seen_.fill(false);
    this.trig_.fill(0);
    this.keyPrev_.fill(false);
    this.keySeen_.fill(false);
    this.pend_ = [];
  }

  setUsable(v) { this.usable_ = !!v; }
  usable() { return this.usable_; }

  command(m, via, nowMs) {
    nowMs = u32(nowMs);
    if (m === ArmMode.OFF) {
      if (this.mode_ === ArmMode.OFF && this.st_ !== ArmSt.ALARM) return Rej.OK;
      this.#disarm(via, nowMs);
      return Rej.OK;
    }
    if (m !== ArmMode.AWAY && m !== ArmMode.HOME) return Rej.BAD_STATE;
    if (!this.usable_) return Rej.SAFE_MODE;
    if (this.st_ === ArmSt.ALARM) return Rej.BAD_STATE;
    if (m === this.mode_) return Rej.OK;
    if (!this.#anyArmed(m)) return Rej.BAD_STATE;
    if (!this.#ready(m)) return Rej.NOT_READY;
    this.mode_ = m;
    this.st_ = ArmSt.EXIT;
    this.#startDelay(exitDelayS(this.cfg_.pol), nowMs);
    this.trig_.fill(0);
    this.pend_ = [];
    this.srcs_ = [];
    this.aid_ = '';
    this.restored_ = false;
    this.dirty_ = true;
    this.#emit(this.#blank(EvType.ARM_CHANGED, 0, nowMs, { flag: m, sub: via }));
    return Rej.OK;
  }

  tick(nowMs, epoch) {
    nowMs = u32(nowMs);
    this.epoch_ = u32(epoch);
    if (!this.cfg_ || !this.hub_) return;
    this.#keyRoles(nowMs);
    if (!this.usable_ || this.mode_ === ArmMode.OFF) { this.#snapshot(); return; }
    let instant = false;
    let entry = false;
    for (let i = 0; i < this.hub_.count(); i++) {
      const c = this.hub_.config(i);
      if (!armedIn(c, this.mode_)) continue;
      if (!(this.hub_.ok(i) && this.hub_.active(i))) continue;
      if (c.flags & SF_ENTRY) entry = true; else instant = true;
    }
    switch (this.st_) {
      case ArmSt.EXIT:
        if (instant) this.#raise(nowMs, false);
        else if (this.#elapsed(nowMs)) {
          if (entry) this.#enterEntry(nowMs); else { this.st_ = ArmSt.IDLE; this.untilUp_ = 0; }
        }
        break;
      case ArmSt.IDLE:
        if (instant) this.#raise(nowMs, false);
        else if (entry) this.#enterEntry(nowMs);
        break;
      case ArmSt.ENTRY:
        this.#collectPending();
        if (instant) this.#raise(nowMs, false);
        else if (this.#elapsed(nowMs)) this.#raise(nowMs, true);
        break;
      case ArmSt.ALARM:
        this.#retrigger();
        break;
      default: break;
    }
    this.#snapshot();
  }

  sirenReq() { return this.st_ === ArmSt.ALARM && this.mode_ !== ArmMode.OFF; }
  takeSirenKick() { const k = this.kick_; this.kick_ = SirenKick.NONE; return k; }
  buzzer() {
    if (this.st_ === ArmSt.ALARM) return this.restored_ ? BuzPattern.OFF : BuzPattern.ALARM;
    if (this.st_ === ArmSt.ENTRY) return BuzPattern.ENTRY;
    if (this.st_ === ArmSt.EXIT) return BuzPattern.EXIT;
    return BuzPattern.OFF;
  }
  takeKeyError() { const k = this.keyError_; this.keyError_ = false; return k; }
  takeDirty() { const d = this.dirty_; this.dirty_ = false; return d; }
  markDirty() { this.dirty_ = true; }   // NVS yazimi basarisiz: kayit yeniden denenecek (fw-tarama-5)
  record() {
    if (this.st_ === ArmSt.ALARM && this.aid_) return makeArmRecord({ mode: this.mode_, alarm: ARM_REC_ALARM, aid: this.aid_ });
    if (this.st_ === ArmSt.ENTRY && this.mode_ !== ArmMode.OFF) return makeArmRecord({ mode: this.mode_, alarm: ARM_REC_ENTRY, pend: this.pend_.slice(0, 8) });
    return makeArmRecord({ mode: this.mode_ });
  }

  present() {
    return (this.cfg_ && hasIntrusionSensors(this.cfg_.sens, this.cfg_.nSens)) || this.mode_ !== ArmMode.OFF || this.st_ === ArmSt.ALARM;
  }
  mode() { return this.mode_; }
  st() { return this.st_; }
  untilUp() { return this.st_ === ArmSt.EXIT || this.st_ === ArmSt.ENTRY ? this.untilUp_ : 0; }
  aid() { return this.aid_; }
  nsrcs() { return this.srcs_.length; }
  srcs() { return this.srcs_.slice(); }

  // ------------------------------------------------------------------------------------------------ ic
  #clearRt() {
    this.mode_ = ArmMode.OFF;
    this.st_ = ArmSt.IDLE;
    this.usable_ = true;
    this.restored_ = false;
    this.dirty_ = false;
    this.keyError_ = false;
    this.kick_ = SirenKick.NONE;
    this.bootAt_ = 0;
    this.epoch_ = 0;
    this.startMs_ = 0;
    this.spanMs_ = 0;
    this.untilUp_ = 0;
    this.aid_ = '';
    this.srcs_ = [];
    this.pend_ = [];
    this.prev_ = new Array(MAX_SENSORS).fill(false);
    this.seen_ = new Array(MAX_SENSORS).fill(false);
    this.trig_ = new Array(MAX_SENSORS).fill(0);
    this.keyPrev_ = new Array(MAX_SENSORS).fill(false);
    this.keySeen_ = new Array(MAX_SENSORS).fill(false);
  }

  #blank(type, zone, nowMs, o = {}) {
    return makeEvent({ type, zone, atUp: Math.floor(u32(u32(nowMs) - this.bootAt_) / 1000), atEpoch: this.epoch_, ...o });
  }
  #emit(e) { return this.out_ ? this.out_.push(e) : ''; }

  #startDelay(s, nowMs) {
    this.startMs_ = nowMs;
    this.spanMs_ = s * 1000;
    this.untilUp_ = Math.floor((u32(nowMs + this.spanMs_) + 999) / 1000);
  }
  #elapsed(nowMs) { return u32(nowMs - this.startMs_) >= this.spanMs_; }
  // Giris gecikmesi baslar; durum kalici yazilir (enerji kesintisinde olay kaybolmasin, RV-E2).
  #enterEntry(nowMs) {
    this.st_ = ArmSt.ENTRY;
    this.#collectPending();
    this.#startDelay(entryDelayS(this.cfg_.pol), nowMs);
    this.dirty_ = true;
  }

  #anyArmed(m) {
    for (let i = 0; i < this.hub_.count(); i++) if (armedIn(this.hub_.config(i), m)) return true;
    return false;
  }
  #ready(m) {
    for (let i = 0; i < this.hub_.count(); i++) {
      const c = this.hub_.config(i);
      if (!armedIn(c, m)) continue;
      if (!this.hub_.ok(i)) return false;
      if (!(c.flags & SF_ENTRY) && (this.hub_.active(i) || this.hub_.rawActive(i))) return false;
    }
    return true;
  }
  static #addId(arr, code) { if (!arr.includes(code) && arr.length < 8) arr.push(code); }
  #collectPending() {
    for (let i = 0; i < this.hub_.count(); i++) {
      const c = this.hub_.config(i);
      if (!armedIn(c, this.mode_) || !(c.flags & SF_ENTRY)) continue;
      if (this.hub_.ok(i) && this.hub_.active(i)) IntrusionCore.#addId(this.pend_, sensorIdCode(c));
    }
  }
  #slotOf(code) {
    for (let i = 0; i < this.hub_.count(); i++) if (sensorIdCode(this.hub_.config(i)) === code) return i;
    return -1;
  }

  #raise(nowMs, fromEntry) {
    this.srcs_ = [];
    let zone = 0;
    if (!fromEntry) {
      for (let i = 0; i < this.hub_.count(); i++) {
        const c = this.hub_.config(i);
        if (!armedIn(c, this.mode_) || (c.flags & SF_ENTRY) || !(this.hub_.ok(i) && this.hub_.active(i))) continue;
        if (!zone) zone = c.zone;
        IntrusionCore.#addId(this.srcs_, sensorIdCode(c));
        if (this.trig_[i] < 255) this.trig_[i]++;
      }
    }
    for (const code of this.pend_) {
      IntrusionCore.#addId(this.srcs_, code);
      const slot = this.#slotOf(code);
      if (slot >= 0) {
        if (!zone) zone = this.hub_.config(slot).zone;
        if (this.trig_[slot] < 255) this.trig_[slot]++;
      }
    }
    this.pend_ = [];
    this.st_ = ArmSt.ALARM;
    this.untilUp_ = 0;
    this.restored_ = false;
    this.kick_ = SirenKick.FRESH;
    this.dirty_ = true;
    const e = this.#blank(EvType.INTRUSION_ALARM, zone, nowMs, { nsrcs: this.srcs_.length, srcs: this.srcs_.slice() });
    this.aid_ = this.#emit(e);
  }

  #retrigger() {
    for (let i = 0; i < this.hub_.count(); i++) {
      const c = this.hub_.config(i);
      if (!armedIn(c, this.mode_)) continue;
      const act = this.hub_.ok(i) && this.hub_.active(i);
      if (!act || !this.seen_[i] || this.prev_[i]) continue;
      IntrusionCore.#addId(this.srcs_, sensorIdCode(c));
      if (this.trig_[i] < SWINGER_MAX) {
        this.trig_[i]++;
        if (this.kick_ === SirenKick.NONE) this.kick_ = SirenKick.RETRIGGER;
        this.restored_ = false;
      }
    }
  }

  #snapshot() {
    for (let i = 0; i < this.hub_.count() && i < MAX_SENSORS; i++) {
      this.prev_[i] = this.hub_.ok(i) && this.hub_.active(i);
      this.seen_[i] = this.hub_.ok(i);
    }
  }

  #keyRoles(nowMs) {
    for (let i = 0; i < this.hub_.count() && i < MAX_SENSORS; i++) {
      const c = this.hub_.config(i);
      if (c.kind !== SensorKind.ARM_KEY || !this.hub_.ok(i)) continue;
      const lv = this.hub_.rawActive(i);
      if (this.keySeen_[i] && lv !== this.keyPrev_[i]) {
        if (lv) { if (this.command(ArmMode.AWAY, VIA_DI, nowMs) !== Rej.OK) this.keyError_ = true; } else this.command(ArmMode.OFF, VIA_DI, nowMs);
      }
      this.keyPrev_[i] = lv;
      this.keySeen_[i] = true;
    }
  }

  #disarm(via, nowMs) {
    if (this.st_ === ArmSt.ALARM) this.#emit(this.#blank(EvType.INTRUSION_CLEARED, 0, nowMs, { aid: this.aid_, sub: via }));
    this.mode_ = ArmMode.OFF;
    this.st_ = ArmSt.IDLE;
    this.untilUp_ = 0;
    this.srcs_ = [];
    this.pend_ = [];
    this.aid_ = '';
    this.restored_ = false;
    this.kick_ = SirenKick.NONE;
    this.dirty_ = true;
    this.trig_.fill(0);
    this.#emit(this.#blank(EvType.ARM_CHANGED, 0, nowMs, { flag: ArmMode.OFF, sub: via }));
  }
}
