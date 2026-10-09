// sensors/SensorTypes.h + SensorHub.h + DiSensor.h + BridgeSensor.h (firmware) BIREBIR JavaScript portu. SAF MANTIK.
//
//  * Seviye tabanli: kacirilmis kenar ya da acilista zaten islak sensor ilk gecerli okumada yakalanir.
//  * Pencereli birikim [O-1]: pencere (su 3 sn, gaz/duman 1 sn) BUCKETS kovaya bolunur; son pencerede toplam aktif sure
//    >= confirm_ms ise sensor onayli aktiftir (damla deseni birikir, tek kisa sicrama dolduramaz). confirm_ms tur penceresinden
//    uzunsa pencere buyur (SensorHub.windowMs; v1.3.2 fw-tarama-3).
//  * ok=false sensor BILINMEYENDIR [Y-3]: ne islak ne kuru; kuruluk sayacini durdurur. Ariza kenari yalniz once ok=true
//    gorulmus sensorde uretilir. SF_FAULT_CLOSE: ariza, turunun tehlike sinifi icin "islak" sayilir (acilista 30 sn tolerans).
//  * Kontrol rolleri (ALARM_ACK / VALVE_CLOSE / GAS_RESET / ARM_KEY): pasif->aktif kenari bir kez bildirilir; ilk okuma kenar degildir.
//  * Faz 2 (F2.B.1): SF_ENTRY (giris yolu) ve SF_AWAY_ONLY (yalniz disarida) hirsiz bitleri; varsayilan bayraklar kapi=REACT|ENTRY,
//    hareket=REACT|AWAY_ONLY; ARM_KEY (19) anahtarli kontak kumanda rolu.
//
// Dogrulama: test/fw_sensor_hub.test.js, firmware'in Unity testlerinin (test/test_sensor_hub) BIREBIR portudur.

export const MAX_SENSORS = 56;
export const MAX_ACTUATORS = 16;
export const MAX_ZONES = 4;
export const MAX_DI = 40;
export const MAX_BRIDGE = 16;
export const MAX_RELAYS = 40;
export const NAME_LEN = 20;

export const SensorKind = Object.freeze({
  NONE: 0, WATER: 1, GAS: 2, SMOKE: 3, DOOR: 4, WINDOW: 5, MOTION: 6, GENERIC: 7, ALARM_ACK: 16, VALVE_CLOSE: 17, GAS_RESET: 18, ARM_KEY: 19,
});
export const SensorSrc = Object.freeze({ DI: 0, BRIDGE: 1 });
export const SF_REACT = 0x01;
export const SF_TAMPER = 0x02;
export const SF_FAULT_CLOSE = 0x04;
export const SF_ENTRY = 0x08;
export const SF_AWAY_ONLY = 0x10;
export const SF_ALL = 0x1F;
export const HZ_WATER = 0x01;
export const HZ_GAS = 0x02;
export const HZ_SMOKE = 0x04;
export const HZ_ALL = 0x07;

const u32 = (x) => x >>> 0;

export function hazardOf(kind) {
  if (kind === SensorKind.WATER) return HZ_WATER;
  if (kind === SensorKind.GAS) return HZ_GAS;
  if (kind === SensorKind.SMOKE) return HZ_SMOKE;
  return 0;
}
export const isControlRole = (kind) => kind === SensorKind.ALARM_ACK || kind === SensorKind.VALVE_CLOSE || kind === SensorKind.GAS_RESET
  || kind === SensorKind.ARM_KEY;
export const isIntrusionKind = (kind) => kind === SensorKind.DOOR || kind === SensorKind.WINDOW || kind === SensorKind.MOTION;
export const isKnownKind = (kind) => (kind >= SensorKind.WATER && kind <= SensorKind.GENERIC) || isControlRole(kind);
export function defaultConfirmMs(kind) {
  const hz = hazardOf(kind);
  if (hz === HZ_WATER) return 1000;
  if (hz === HZ_GAS || hz === HZ_SMOKE) return 300;
  return 0;
}
export function confirmWindowMs(kind) {
  const hz = hazardOf(kind);
  if (hz === HZ_WATER) return 3000;
  if (hz === HZ_GAS || hz === HZ_SMOKE) return 1000;
  return 0;
}
export const defaultFlags = (kind) => SF_REACT | (kind === SensorKind.GAS ? SF_FAULT_CLOSE : 0) | (kind === SensorKind.DOOR ? SF_ENTRY : 0)
  | (kind === SensorKind.MOTION ? SF_AWAY_ONLY : 0);
export const sensorIdCode = (c) => (c.src === SensorSrc.BRIDGE ? (0x80 | c.index) : c.index);
export const sensorIdText = (code) => `${code & 0x80 ? 'b' : 'd'}${code & 0x7F}`;

/** Bos SensorConfig (28 B'lik firmware yapisinin alanlari). */
export function makeSensorConfig(o = {}) {
  return { src: 0, index: 0, kind: 0, zone: 0, active_open: 0, flags: 0, confirm_ms: 0, name: '', ...o };
}

export class SensorHub {
  static BUCKETS = 8;

  /**
   * Onay penceresi (firmware SensorHub::windowMs; v1.3.2 fw-tarama-3): tur penceresi ya da confirm_ms icin yeterli en kucuk pencere
   * (ceil(confirm_ms / 7) * 8), hangisi buyukse. Tur penceresinin 7/8'ine kadar degismez. 0: pencere yok.
   */
  static windowMs(kind, confirmMs) {
    const base = confirmWindowMs(kind);
    if (base === 0) return 0;
    const need = Math.floor((confirmMs + (SensorHub.BUCKETS - 2)) / (SensorHub.BUCKETS - 1)) * SensorHub.BUCKETS;
    return need > base ? need : base;
  }
  static BOOT_FAULT_GRACE_MS = 30000;

  constructor() {
    this.cfg_ = [];
    this.n_ = 0;
    this.cfgAt_ = 0;
    this.rt_ = [];
    this.zone_ = [];
    this.faultEdges_ = 0n;
    this.clearedEdges_ = 0n;
    this.pressEdges_ = 0n;
  }

  static #rt() {
    return {
      bucket: new Array(SensorHub.BUCKETS).fill(0), bucketStart: 0, lastMs: 0, holdSince: 0, head: 0, bucketsLive: false,
      seen: false, ok: false, everOk: false, raw: false, prevActive: false, confirmed: false, pressed: false, wet: false,
    };
  }

  configure(cfgs, n, nowMs) {
    this.cfg_ = cfgs;
    this.n_ = Math.min(n, MAX_SENSORS);
    this.cfgAt_ = u32(nowMs);
    this.rt_ = Array.from({ length: MAX_SENSORS }, () => SensorHub.#rt());
    this.zone_ = Array.from({ length: MAX_ZONES + 1 }, () => ({ drySince: u32(nowMs), dryValid: true, wet: 0, fault: 0 }));
    this.faultEdges_ = 0n;
    this.clearedEdges_ = 0n;
    this.pressEdges_ = 0n;
  }

  count() { return this.n_; }
  config(slot) { return slot < this.n_ ? this.cfg_[slot] : null; }

  update(slot, level, ok, nowMs) {
    if (slot >= this.n_) return;
    nowMs = u32(nowMs);
    const c = this.cfg_[slot];
    const r = this.rt_[slot];
    const bit = 1n << BigInt(slot);
    const logical = (c.src === SensorSrc.DI && c.active_open) ? !level : !!level;
    const dt = r.seen ? u32(nowMs - r.lastMs) : 0;

    if (!ok) {
      if (r.seen && r.ok) this.faultEdges_ |= bit;
      r.ok = false; r.confirmed = false; r.prevActive = false; r.raw = false; r.pressed = false; r.bucketsLive = false;
      r.bucket.fill(0);
      r.seen = true;
      r.lastMs = nowMs;
      return;
    }
    if (r.seen && !r.ok && r.everOk) this.clearedEdges_ |= bit;

    if (isControlRole(c.kind)) {
      if (r.seen && r.ok && logical && !r.pressed) {
        this.pressEdges_ |= bit;
        r.holdSince = nowMs;
      } else if (logical && !r.pressed) {
        r.holdSince = nowMs;
      }
      r.pressed = logical;
      r.confirmed = logical;
    } else {
      const window = SensorHub.windowMs(c.kind, c.confirm_ms);   // fw-tarama-3: uzun confirm_ms'de pencere buyur
      if (c.confirm_ms === 0 || window === 0) {
        r.confirmed = logical;
      } else {
        const bucketLen = Math.floor(window / SensorHub.BUCKETS);
        if (!r.bucketsLive) {
          r.bucket.fill(0); r.head = 0; r.bucketStart = nowMs; r.bucketsLive = true;
        } else if (u32(nowMs - r.bucketStart) >= window) {
          r.bucket.fill(0); r.head = 0; r.bucketStart = nowMs;
        } else {
          while (u32(nowMs - r.bucketStart) >= bucketLen) {
            r.head = (r.head + 1) % SensorHub.BUCKETS;
            r.bucket[r.head] = 0;
            r.bucketStart = u32(r.bucketStart + bucketLen);
          }
        }
        if (r.ok && r.prevActive) r.bucket[r.head] = Math.min(0xFFFF, r.bucket[r.head] + Math.min(dt, window));
        const sum = r.bucket.reduce((a, b) => a + b, 0);
        r.confirmed = sum >= c.confirm_ms;
      }
    }
    r.prevActive = logical;
    r.raw = logical;
    r.ok = true;
    r.everOk = true;
    r.seen = true;
    r.lastMs = nowMs;
  }

  finish(nowMs) {
    nowMs = u32(nowMs);
    const allDry = new Array(MAX_ZONES + 1).fill(true);
    for (const z of this.zone_) { z.wet = 0; z.fault = 0; }
    for (let i = 0; i < this.n_; i++) {
      const c = this.cfg_[i];
      const hz = hazardOf(c.kind);
      if (hz === 0 || c.zone > MAX_ZONES) { this.rt_[i].wet = false; continue; }
      const r = this.rt_[i];
      const zs = this.zone_[c.zone];
      if (!r.ok) zs.fault |= hz;
      r.wet = this.#wetContrib(i, nowMs);
      if (r.wet) zs.wet |= hz;
      if (!(r.ok && !r.confirmed && !r.raw)) allDry[c.zone] = false;
    }
    for (let z = 0; z <= MAX_ZONES; z++) {
      if (!allDry[z]) this.zone_[z].dryValid = false;
      else if (!this.zone_[z].dryValid) { this.zone_[z].dryValid = true; this.zone_[z].drySince = nowMs; }
    }
  }

  active(slot) { return slot < this.n_ && this.rt_[slot].ok && this.rt_[slot].confirmed; }
  ok(slot) { return slot < this.n_ && this.rt_[slot].ok; }
  rawActive(slot) { return slot < this.n_ && this.rt_[slot].ok && this.rt_[slot].raw; }
  idle(slot) { return slot < this.n_ && this.rt_[slot].ok && !this.rt_[slot].confirmed && !this.rt_[slot].raw; }

  activeMask() {
    let m = 0n;
    for (let i = 0; i < this.n_; i++) if (this.active(i)) m |= 1n << BigInt(i);
    return m;
  }
  faultMask() {
    let m = 0n;
    for (let i = 0; i < this.n_; i++) if (!this.rt_[i].ok) m |= 1n << BigInt(i);
    return m;
  }

  zoneWet(zone) { return zone <= MAX_ZONES ? this.zone_[zone].wet : 0; }
  zoneFault(zone) { return zone <= MAX_ZONES ? this.zone_[zone].fault : 0; }
  zoneDryMs(zone, nowMs) {
    if (zone > MAX_ZONES || !this.zone_[zone].dryValid) return 0;
    return u32(u32(nowMs) - this.zone_[zone].drySince);
  }

  /** Bolgede islakliga katki veren (hz maskesindeki) sensorlerin kimlik kodlari, yuva sirasiyla (en cok max). */
  zoneSources(zone, hzMask, max = 8) {
    const ids = [];
    for (let i = 0; i < this.n_ && ids.length < max; i++) {
      const c = this.cfg_[i];
      if (c.zone !== zone || (hazardOf(c.kind) & hzMask) === 0) continue;
      if (!this.rt_[i].wet) continue;
      ids.push(sensorIdCode(c));
    }
    return ids;
  }

  takeFaultEdges() { const m = this.faultEdges_; this.faultEdges_ = 0n; return m; }
  takeFaultClearedEdges() { const m = this.clearedEdges_; this.clearedEdges_ = 0n; return m; }
  takeControlPresses() { const m = this.pressEdges_; this.pressEdges_ = 0n; return m; }
  heldMs(slot, nowMs) {
    if (slot >= this.n_ || !this.rt_[slot].pressed) return 0;
    return u32(u32(nowMs) - this.rt_[slot].holdSince);
  }

  #wetContrib(i, nowMs) {
    const c = this.cfg_[i];
    const r = this.rt_[i];
    if (!(c.flags & SF_REACT)) return false;
    if (r.ok) return r.confirmed;
    if (!(c.flags & SF_FAULT_CLOSE)) return false;
    return r.everOk || u32(nowMs - this.cfgAt_) >= SensorHub.BOOT_FAULT_GRACE_MS;
  }
}

/** DiSensor.h: kablolu kaynak; DiGate'in KARARLI seviyesi. ok: yerel 1..8 ilk okumadan sonra, ek 9..40 modul saglikliyken VE kanal ilk taze
 * okumayla baslatildiysa (setExtReady, pano-4: modul etkinken kanal sayisi artinca yeni kanallar ilk okumaya kadar "okunamadi"). */
export class DiSensor {
  constructor(gate) { this.gate_ = gate; this.localReady_ = false; this.extOk_ = false; this.extReady_ = MAX_DI - 8; }
  setLocalReady(v) { this.localReady_ = !!v; }
  setExtOk(v) { this.extOk_ = !!v; }
  /** Ek modul kanallarindan ilk `channels` tanesi gercek okumayla baslatildi (varsayilan: hepsi; yalniz setExtOk karar verir). */
  setExtReady(channels) { this.extReady_ = channels & 0xFF; }
  localReady() { return this.localReady_; }
  extOk() { return this.extOk_; }
  extReady() { return this.extReady_; }
  sample(c /* , nowMs */) {
    if (!this.gate_ || c.src !== SensorSrc.DI || c.index < 1 || c.index > MAX_DI) return { level: false, ok: false };
    const idx = c.index - 1;
    return { level: this.gate_.stable(idx), ok: idx < 8 ? this.localReady_ : (this.extOk_ && (idx - 8) < this.extReady_) };
  }
  static diMaskOf(cfgs, n) {
    let m = 0n;
    for (let i = 0; i < n; i++) {
      const c = cfgs[i];
      if (c.src !== SensorSrc.DI || c.index < 1 || c.index > MAX_DI) continue;
      m |= 1n << BigInt(c.index - 1);
    }
    return m;
  }
  /** [B17] Maskeye alinan DI'lerin acted/momentary artiklarini temizler (DiGate degistirilmeden: init kararli seviyeyle). */
  static releaseMomentary(gate, mask, nowMs) {
    for (let i = 0; i < MAX_DI; i++) {
      if (!(mask & (1n << BigInt(i)))) continue;
      if (gate.acted(i)) gate.init(i, gate.stable(i), nowMs);
    }
  }
}

/** BridgeSensor.h: kopru raporlari + kalp atisi (vars. 15 dk). */
export class BridgeSensor {
  static DEFAULT_HEARTBEAT_MS = 900000;
  static MIN_HEARTBEAT_MS = 60000;
  static MAX_HEARTBEAT_MS = 86400000;
  constructor() { this.reset(); }
  reset() {
    this.seen_ = new Array(MAX_BRIDGE).fill(false);
    this.active_ = new Array(MAX_BRIDGE).fill(false);
    this.ok_ = new Array(MAX_BRIDGE).fill(false);
    this.at_ = new Array(MAX_BRIDGE).fill(0);
    this.hb_ = new Array(MAX_BRIDGE).fill(BridgeSensor.DEFAULT_HEARTBEAT_MS);
  }
  setHeartbeat(slot, ms) { if (slot >= 1 && slot <= MAX_BRIDGE) this.hb_[slot - 1] = ms; }
  report(r) {
    if (r.slot < 1 || r.slot > MAX_BRIDGE) return;
    const i = r.slot - 1;
    this.seen_[i] = true;
    this.active_[i] = !!r.active;
    this.ok_[i] = !!r.ok;
    this.at_[i] = u32(r.at_ms);
  }
  sample(c, nowMs) {
    if (c.src !== SensorSrc.BRIDGE || c.index < 1 || c.index > MAX_BRIDGE) return { level: false, ok: false };
    const i = c.index - 1;
    if (!this.seen_[i] || !this.ok_[i]) return { level: false, ok: false };
    if (u32(u32(nowMs) - this.at_[i]) > this.hb_[i]) return { level: false, ok: false };
    return { level: this.active_[i], ok: true };
  }
}
