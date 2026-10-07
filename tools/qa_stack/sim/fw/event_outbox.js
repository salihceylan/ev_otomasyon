// events/EventOutbox.h (firmware) BIREBIR JavaScript portu: "ev/{t}/event" olay tamponu. SAF MANTIK.
//
//  * eid = "<bn>-<n>" (bn: acilis nonce'u, 8 hex; n: acilis basina 1'den, 99999'dan sonra 1) [Y4][B4].
//  * Uygulama duzeyinde onay (QoS 0): 5, 10, 20, 40 sn, sonra 60 sn'de bir yeniden deneme; aboneligin ilk 1500 ms'inde
//    bosaltilmaz [D4].
//  * Tasma (16): once en eski actuator_changed, sonra en eski *_cleared, sonra alarm disi en eski; hepsi alarmsa en eski
//    alarmin ustune yazilir.
//  * Faz 2 (F2.B.7): intrusion_alarm alarm sinifi, intrusion_cleared *_cleared sinifi, arm_changed en dusuk (actuator_changed ile).
//
// Dogrulama: test/fw_event_outbox.test.js, firmware'in Unity testlerinin (test/test_event_outbox) BIREBIR portudur.
import { HZ_GAS, HZ_SMOKE, HZ_WATER, MAX_ACTUATORS, sensorIdText } from './sensor_hub.js';

export const EID_LEN = 15;
export const EVENT_JSON_MAX = 768;
export const EID_N_MAX = 99999;

export const EvType = Object.freeze({
  NONE: 0, ALARM_RAISED: 1, VALVE_FAULT: 2, VALVE_FAULT_CLEARED: 3, ALARM_SILENCED: 4, ALARM_CLEARED: 5, TEST_RESULT: 6,
  SENSOR_FAULT: 7, SENSOR_FAULT_CLEARED: 8, ACTUATOR_FAULT: 9, SAFE_MODE: 10, NVS_FAIL: 11, POLICY_CHANGED: 12,
  ACTUATOR_CHANGED: 13, CFG_CONFLICT: 14, INTRUSION_ALARM: 15, INTRUSION_CLEARED: 16, ARM_CHANGED: 17,
});
const EV_TEXT = [
  '', 'alarm_raised', 'valve_fault', 'valve_fault_cleared', 'alarm_silenced', 'alarm_cleared', 'test_result', 'sensor_fault',
  'sensor_fault_cleared', 'actuator_fault', 'safe_mode', 'nvs_fail', 'policy_changed', 'actuator_changed', 'cfg_conflict',
  'intrusion_alarm', 'intrusion_cleared', 'arm_changed',
];
export const evTypeText = (t) => EV_TEXT[t] ?? '';

export const VIA_CLI = 0;
export const VIA_LAN = 1;
export const VIA_CLOUD = 2;
export const VIA_LOCAL_WEB = 3;
export const VIA_DI = 4;     // hirsiz olaylari: ARM_KEY girisi
export const VIA_BOOT = 5;   // hirsiz olaylari: acilista geri yuklenen kip
export const NVSK_LATCH = 1;
export const NVSK_ACT_POS = 2;
export const NVSK_CFG = 3;
export const NVSK_SIREN = 4;
export const NVSK_CRASH = 5;
export const NVSK_ARM = 6;

const u32 = (x) => x >>> 0;
const hex8 = (v) => u32(v).toString(16).padStart(8, '0');

/** Bos olay yuvasi (firmware struct Event alanlari). */
export function makeEvent(o = {}) {
  return {
    type: 0, zone: 0, kinds: 0, nsrcs: 0, srcs: new Array(8).fill(0), actClose: 0, actOpen: 0, actOn: 0, actOff: 0,
    atUp: 0, atEpoch: 0, val: 0, flag: 0, sub: 0, rev: 0, crc: 0, aid: '', ...o,
  };
}

export const formatEid = (bn, n) => `${hex8(bn)}-${n}`;

const kindText = (k) => ((k & HZ_GAS) ? 'gas' : (k & HZ_SMOKE) ? 'smoke' : (k & HZ_WATER) ? 'water' : null);
const reasonText = (r) => ({ 1: 'cfg_corrupt', 2: 'latch_orphan', 3: 'crash_loop' }[r] || '');
const viaText = (v) => ({ [VIA_LAN]: 'lan', [VIA_CLOUD]: 'cloud', [VIA_LOCAL_WEB]: 'local_web', [VIA_DI]: 'di', [VIA_BOOT]: 'boot' }[v] || 'cli');
const armModeTextOf = (m) => (m === 1 ? 'away' : m === 2 ? 'home' : 'off');
const nvsKeyText = (k) => ({ 1: 'latch', 2: 'act_pos', 3: 'cfg', 4: 'siren_s', 5: 'crash', 6: 'arm' }[k] || '');
const isAlarmClass = (t) => t === EvType.ALARM_RAISED || t === EvType.VALVE_FAULT || t === EvType.INTRUSION_ALARM;
const isCleared = (t) => t === EvType.ALARM_CLEARED || t === EvType.VALVE_FAULT_CLEARED || t === EvType.SENSOR_FAULT_CLEARED
  || t === EvType.INTRUSION_CLEARED;
const isLowest = (t) => t === EvType.ACTUATOR_CHANGED || t === EvType.ARM_CHANGED;

export class EventOutbox {
  static CAP = 16;
  static LOG_CAP = 32;
  static RECONNECT_WINDOW_MS = 1500;

  constructor() { this.begin(0); }

  begin(bootNonce) {
    this.bn_ = u32(bootNonce);
    this.nextN_ = 1;
    this.ord_ = 0;
    this.overwrites_ = 0;
    this.slot_ = Array.from({ length: EventOutbox.CAP }, () => ({ used: false, ev: null, n: 0, ord: 0, lastSent: 0, sends: 0 }));
    this.log_ = [];   // LAN olay halkasi (GET /api/events): son 32 olayin kopyasi, onaylanmislar dahil
  }
  bootNonce() { return this.bn_; }
  setNextN(n) { this.nextN_ = (n === 0 || n > EID_N_MAX) ? 1 : n; }

  /** @returns {string} eid */
  push(e) {
    let s = this.#freeSlot();
    if (s < 0) s = this.#victim();
    const sl = this.slot_[s];
    sl.used = true;
    sl.ev = makeEvent({ ...e, srcs: [...(e.srcs || []), 0, 0, 0, 0, 0, 0, 0, 0].slice(0, 8) });
    sl.n = this.nextN_;
    sl.ord = ++this.ord_;
    sl.sends = 0;
    sl.lastSent = 0;
    this.log_.push({ ev: sl.ev, n: sl.n });
    if (this.log_.length > EventOutbox.LOG_CAP) this.log_.shift();
    this.nextN_ = this.nextN_ >= EID_N_MAX ? 1 : this.nextN_ + 1;
    return formatEid(this.bn_, sl.n);
  }

  logCount() { return this.log_.length; }
  /** after eid'inden SONRAKI ilk kaydin sirasi; bulunamazsa 0 (bastan). */
  logAfter(afterEid) {
    if (!afterEid) return 0;
    const i = this.log_.findIndex((l) => formatEid(this.bn_, l.n) === afterEid);
    return i < 0 ? 0 : i + 1;
  }
  logJson(i, uid, bootCount, cap = EVENT_JSON_MAX) { return i < this.log_.length ? this.#eventJson(this.log_[i].ev, this.log_[i].n, uid, bootCount, cap) : ''; }

  nextDue(nowMs, connectedAt) {
    if (u32(nowMs - connectedAt) < EventOutbox.RECONNECT_WINDOW_MS) return -1;
    let best = -1;
    for (let i = 0; i < EventOutbox.CAP; i++) {
      const s = this.slot_[i];
      if (!s.used) continue;
      if (s.sends > 0 && u32(nowMs - s.lastSent) < EventOutbox.#backoffMs(s.sends)) continue;
      if (best < 0 || ((s.ord - this.slot_[best].ord) | 0) < 0) best = i;
    }
    return best;
  }

  markSent(slot, nowMs) {
    if (slot < 0 || slot >= EventOutbox.CAP || !this.slot_[slot].used) return;
    if (this.slot_[slot].sends < 255) this.slot_[slot].sends++;
    this.slot_[slot].lastSent = u32(nowMs);
  }

  ack(eid) {
    if (!eid) return false;
    for (const s of this.slot_) {
      if (s.used && formatEid(this.bn_, s.n) === eid) { s.used = false; return true; }
    }
    return false;
  }
  ackMany(eids) { let k = 0; for (const e of eids) if (this.ack(e)) k++; return k; }

  count() { return this.slot_.filter((s) => s.used).length; }
  countOf(t) { return this.slot_.filter((s) => s.used && s.ev.type === t).length; }
  overwrites() { return this.overwrites_; }
  at(slot) { return slot >= 0 && slot < EventOutbox.CAP && this.slot_[slot].used ? this.slot_[slot].ev : null; }
  eidOf(slot) { return this.at(slot) ? formatEid(this.bn_, this.slot_[slot].n) : ''; }
  /** Kullanilan yuvalar, eklenme sirasiyla (QA gozlemi). */
  list() {
    return this.slot_.map((s, i) => ({ s, i })).filter((x) => x.s.used).sort((a, b) => a.s.ord - b.s.ord)
      .map(({ s, i }) => ({ slot: i, eid: formatEid(this.bn_, s.n), ev: s.ev }));
  }

  /** Yayin JSON'u (firmware toJson ile AYNI bayt dizisi). Sigmazsa '' (firmware: 0). */
  toJson(slot, uid, bootCount, cap = EVENT_JSON_MAX) {
    const e = this.at(slot);
    if (!e) return '';
    return this.#eventJson(e, this.slot_[slot].n, uid, bootCount, cap);
  }

  #eventJson(e, n, uid, bootCount, cap) {
    let s = `{"v":1,"uid":"${uid ?? ''}","eid":"${formatEid(this.bn_, n)}","bn":"${hex8(this.bn_)}","boot":${u32(bootCount)},"n":${n}`;
    s += `,"type":"${evTypeText(e.type)}"`;
    if (e.zone) s += `,"zone":${e.zone}`;
    const k = e.type === EvType.INTRUSION_ALARM ? 'intrusion' : kindText(e.kinds);
    if (k) s += `,"kind":"${k}"`;
    if (e.aid) s += `,"aid":"${String(e.aid).slice(0, 14)}"`;
    if (e.nsrcs) s += `,"srcs":[${e.srcs.slice(0, Math.min(8, e.nsrcs)).map((c) => `"${sensorIdText(c)}"`).join(',')}]`;
    switch (e.type) {
      case EvType.TEST_RESULT: s += `,"ok":${e.flag ? 'true' : 'false'}${e.sub ? `,"fb_ms":${e.val}` : ''}`; break;
      case EvType.SAFE_MODE: s += `,"reason":"${reasonText(e.sub)}"`; break;
      case EvType.CFG_CONFLICT: s += `,"rev":${u32(e.rev)},"crc":"${hex8(e.crc)}"`; break;
      case EvType.POLICY_CHANGED: s += `,"policy":"${e.flag ? 'on' : 'off'}","via":"${viaText(e.sub)}"`; break;
      case EvType.NVS_FAIL: s += `,"key":"${nvsKeyText(e.sub)}"`; break;
      case EvType.INTRUSION_CLEARED: s += `,"via":"${viaText(e.sub)}"`; break;
      case EvType.ARM_CHANGED: s += `,"mode":"${armModeTextOf(e.flag)}","via":"${viaText(e.sub)}"`; break;
      default: break;
    }
    if (e.atEpoch) s += `,"at":${u32(e.atEpoch)}`;
    s += `,"at_up":${u32(e.atUp)}`;
    if (e.actClose | e.actOpen | e.actOn | e.actOff) {
      const parts = [];
      const DO = ['close', 'open', 'on', 'off'];
      const m = [e.actClose, e.actOpen, e.actOn, e.actOff];
      for (let i = 0; i < MAX_ACTUATORS; i++) for (let d = 0; d < 4; d++) if (m[d] & (1 << i)) parts.push(`{"a":"a${i + 1}","do":"${DO[d]}"}`);
      s += `,"actions":[${parts.join(',')}]`;
    }
    s += '}';
    return s.length + 1 > cap ? '' : s;
  }

  static #backoffMs(sends) { return { 1: 5000, 2: 10000, 3: 20000, 4: 40000 }[sends] || 60000; }
  #freeSlot() { return this.slot_.findIndex((s) => !s.used); }
  #oldestWhere(cls) {
    let best = -1;
    for (let i = 0; i < EventOutbox.CAP; i++) {
      const t = this.slot_[i].ev ? this.slot_[i].ev.type : 0;
      const match = cls === 0 ? isLowest(t) : cls === 1 ? isCleared(t) : cls === 2 ? !isAlarmClass(t) : true;
      if (!match) continue;
      if (best < 0 || ((this.slot_[i].ord - this.slot_[best].ord) | 0) < 0) best = i;
    }
    return best;
  }
  #victim() {
    for (let cls = 0; cls < 3; cls++) {
      const v = this.#oldestWhere(cls);
      if (v >= 0) return v;
    }
    this.overwrites_++;
    return this.#oldestWhere(3);
  }
}
