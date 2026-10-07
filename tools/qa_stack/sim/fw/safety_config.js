// safety/SafetyConfig.h (firmware) BIREBIR JavaScript portu: guvenlik yapilandirmasi (NVS "ahbu_safety"), kilit kaydi
// (NVS "ahbu_latch"), capraz dogrulama, blob + CRC32, cokme dongusu sayaci, acilis kipi karari. SAF MANTIK.
//
// Yapilar firmware'deki C yapilarinin bayt duzeniyle KODLANIR (encode*): CRC'ler (state cfg.safety.crc, kilit kaydi) firmware
// ile ayni cikar. Sensor 28 B, eylemci 36 B, politika 16 B, bolge 16 B, isik 4 B, kilit kaydi 164 B.
//
// Dogrulama: test/fw_safety_config.test.js, firmware'in Unity testlerinin (test/test_safety_config) BIREBIR portudur.
import { RelayType } from './sysconfig.js';
import {
  MAX_SENSORS, MAX_ACTUATORS, MAX_ZONES, MAX_BRIDGE, MAX_RELAYS, NAME_LEN, SensorSrc, SensorKind, isKnownKind, isControlRole, hazardOf,
  HZ_GAS, HZ_SMOKE,
} from './sensor_hub.js';
import {
  ActKind, CloseMode, Medium, PULSE_MAX_S, SIREN_RUN_MIN_S, SIREN_RUN_MAX_S, relayBit, actuatorRelayMask,
} from './actuator_map.js';

export const SAFETY_SCHEMA_VER = 1;
export const ZONE_NAME_LEN = 16;
export const DRY_HOLD_DEFAULT_MS = 10000;
export const DRY_HOLD_MIN_MS = 1000;
export const DRY_HOLD_MAX_MS = 600000;
// Hirsiz gecikmelerinin etkin degeri (0 = varsayilan; F2.B.1): IntrusionCore ve gevsetme siniflandirmasi ortak kullanir.
export const EXIT_DEFAULT_S = 45;
export const ENTRY_DEFAULT_S = 30;
export const exitDelayS = (p) => ((p.exit_s || 0) & 0xFF) || EXIT_DEFAULT_S;
export const entryDelayS = (p) => ((p.entry_s || 0) & 0xFF) || ENTRY_DEFAULT_S;
export const CONFIRM_MIN_MS = 100;
export const CONFIRM_MAX_MS = 10000;
export const FB_TIMEOUT_MIN_S = 2;
export const FB_TIMEOUT_MAX_S = 300;
export const CRASH_STABLE_MS = 600000;
export const CRASH_EXIT_MS = 1800000;
export const CRASH_LOOP_COUNT = 3;

/** SafetyConfig::setDefaults(): politika ACIK, kuruluk 10 sn, tek bolge "Ev"; sensor ve eylemci tablosu BOS. */
export function defaultSafetyConfig() {
  return {
    rev: 0,
    pol: { policy_on: 1, flags: 0, dry_hold_ms: DRY_HOLD_DEFAULT_MS, exit_s: 0, entry_s: 0 },   // exit_s/entry_s: Faz 2 (rsv2[0..1])
    zones: [{ name: 'Ev' }, { name: '' }, { name: '' }, { name: '' }],
    nSens: 0,
    sens: [],
    nAct: 0,
    act: [],
    light: Array.from({ length: MAX_RELAYS }, () => ({ dimmable: 0, dimmer_src: 0, dimmer_addr: 0, dimmer_ch: 0 })),
  };
}
export const isEmptyConfig = (c) => c.nSens === 0 && c.nAct === 0;

export const CfgErr = Object.freeze({
  OK: 0, COUNT: 1, DRY_HOLD: 2, NAME: 3,
  SENSOR_SRC: 4, SENSOR_KIND: 5, SENSOR_ZONE: 6, SENSOR_DI_RANGE: 7, SENSOR_BRIDGE_RANGE: 8, SENSOR_DUP: 9, SENSOR_DI_IS_BUTTON: 10,
  GAS_SMOKE_NOT_NC: 11, CONFIRM_RANGE: 12,
  ACT_KIND: 13, ACT_RELAY_RANGE: 14, ACT_RELAY_DUP: 15, ACT_RELAY_SHUTTER: 16, ACT_RELAY_IMPULSE: 17, ACT_ZONE: 18,
  VALVE_MEDIUM: 19, VALVE_MODE: 20, PULSE_RELAY2: 21, PULSE_TIME: 22, SIREN_RUN_LIMIT: 23,
  FB_DI_RANGE: 24, FB_DI_CONFLICT: 25, FB_TIMEOUT_RANGE: 26,
  NOT_FOUND: 27, FULL: 28, BAD_EDIT: 29,
  ARM_KEY_NOT_NC: 30,   // anahtarli kontak NC olmali (Faz 2 incelemesi RV-E3)
});
const CFG_ERR_TEXT = [
  'ok', 'count', 'dry_hold', 'name', 'sensor_src', 'sensor_kind', 'sensor_zone', 'sensor_di_range', 'sensor_bridge_range',
  'sensor_dup', 'sensor_di_is_button', 'gas_smoke_not_nc', 'confirm_range', 'act_kind', 'act_relay_range', 'act_relay_dup',
  'act_relay_shutter', 'act_relay_impulse', 'act_zone', 'valve_medium', 'valve_mode', 'pulse_relay2', 'pulse_time',
  'siren_run_limit', 'fb_di_range', 'fb_di_conflict', 'fb_timeout_range', 'not_found', 'full', 'bad_edit', 'arm_key_not_nc',
];
export const cfgErrText = (e) => CFG_ERR_TEXT[e] ?? '?';

const nameOk = (s, cap) => Buffer.byteLength(String(s ?? ''), 'utf8') < cap;

function relayUsable(sys, relay1) {
  if (relay1 < 1 || relay1 > sys.totalRelays()) return CfgErr.ACT_RELAY_RANGE;
  const t = sys.relays[relay1 - 1].type;
  if (t === RelayType.SHUTTER_UP || t === RelayType.SHUTTER_DOWN) return CfgErr.ACT_RELAY_SHUTTER;
  if (t === RelayType.IMPULSE) return CfgErr.ACT_RELAY_IMPULSE;
  return CfgErr.OK;
}

/** validate(system, safety): bos guvenlik yapilandirmasinda her zaman OK. */
export function validate(sys, c) {
  if (c.nSens > MAX_SENSORS || c.nAct > MAX_ACTUATORS) return CfgErr.COUNT;
  if (c.pol.dry_hold_ms < DRY_HOLD_MIN_MS || c.pol.dry_hold_ms > DRY_HOLD_MAX_MS) return CfgErr.DRY_HOLD;
  for (let z = 0; z < MAX_ZONES; z++) if (!nameOk(c.zones[z]?.name, ZONE_NAME_LEN)) return CfgErr.NAME;
  const totalD = sys.totalDIs();
  let sensorDi = 0n;
  let bridgeSeen = 0;
  for (let i = 0; i < c.nSens; i++) {
    const s = c.sens[i];
    if (!nameOk(s.name, NAME_LEN)) return CfgErr.NAME;
    if (!isKnownKind(s.kind)) return CfgErr.SENSOR_KIND;
    const control = isControlRole(s.kind);
    if (s.src === SensorSrc.DI) {
      if (s.index < 1 || s.index > totalD) return CfgErr.SENSOR_DI_RANGE;
      const b = 1n << BigInt(s.index - 1);
      if (sensorDi & b) return CfgErr.SENSOR_DUP;
      sensorDi |= b;
      if (sys.dis[s.index - 1].target_relay !== 0) return CfgErr.SENSOR_DI_IS_BUTTON;
    } else if (s.src === SensorSrc.BRIDGE) {
      if (control) return CfgErr.SENSOR_SRC;
      if (s.index < 1 || s.index > MAX_BRIDGE) return CfgErr.SENSOR_BRIDGE_RANGE;
      if (bridgeSeen & (1 << (s.index - 1))) return CfgErr.SENSOR_DUP;
      bridgeSeen |= 1 << (s.index - 1);
    } else {
      return CfgErr.SENSOR_SRC;
    }
    if (control ? s.zone > MAX_ZONES : (s.zone < 1 || s.zone > MAX_ZONES)) return CfgErr.SENSOR_ZONE;
    const hz = hazardOf(s.kind);
    if ((hz === HZ_GAS || hz === HZ_SMOKE) && !s.active_open) return CfgErr.GAS_SMOKE_NOT_NC;
    // Anahtarli kontak yalniz NC: kablo kesilince "aktif" (kurulu) okunur; NO'da kablo kesmek alarmi cozerdi (Faz 2 incelemesi RV-E3)
    if (s.kind === SensorKind.ARM_KEY && !s.active_open) return CfgErr.ARM_KEY_NOT_NC;
    if (hz !== 0 && (s.confirm_ms < CONFIRM_MIN_MS || s.confirm_ms > CONFIRM_MAX_MS)) return CfgErr.CONFIRM_RANGE;
    if (hz === 0 && s.confirm_ms > CONFIRM_MAX_MS) return CfgErr.CONFIRM_RANGE;
  }
  let used = 0n;
  for (let i = 0; i < c.nAct; i++) {
    const a = c.act[i];
    if (!nameOk(a.name, NAME_LEN)) return CfgErr.NAME;
    if (a.kind < ActKind.VALVE || a.kind > ActKind.GENERIC) return CfgErr.ACT_KIND;
    let e = relayUsable(sys, a.relay);
    if (e !== CfgErr.OK) return e;
    if (used & relayBit(a.relay)) return CfgErr.ACT_RELAY_DUP;
    used |= relayBit(a.relay);
    if (a.kind !== ActKind.GENERIC && (a.zone_mask === 0 || a.zone_mask > 0x0F)) return CfgErr.ACT_ZONE;
    if (a.zone_mask > 0x0F) return CfgErr.ACT_ZONE;
    if (a.kind === ActKind.VALVE) {
      if (a.medium !== Medium.WATER && a.medium !== Medium.GAS) return CfgErr.VALVE_MEDIUM;
      if (a.close_mode > CloseMode.PULSE_TWO_RELAY) return CfgErr.VALVE_MODE;
      if (a.close_mode === CloseMode.PULSE_TWO_RELAY) {
        if (a.relay2 === 0 || a.relay2 === a.relay) return CfgErr.PULSE_RELAY2;
        e = relayUsable(sys, a.relay2);
        if (e !== CfgErr.OK) return e;
        if (used & relayBit(a.relay2)) return CfgErr.ACT_RELAY_DUP;
        used |= relayBit(a.relay2);
        if (a.run_limit_s > PULSE_MAX_S) return CfgErr.PULSE_TIME;
      }
      if (a.fb_di !== 0) {
        if (a.fb_di > totalD) return CfgErr.FB_DI_RANGE;
        if ((sensorDi & (1n << BigInt(a.fb_di - 1))) || sys.dis[a.fb_di - 1].target_relay !== 0) return CfgErr.FB_DI_CONFLICT;
        if (a.fb_timeout_s < FB_TIMEOUT_MIN_S || a.fb_timeout_s > FB_TIMEOUT_MAX_S) return CfgErr.FB_TIMEOUT_RANGE;
      }
    } else if (a.kind === ActKind.SIREN) {
      if (a.run_limit_s < SIREN_RUN_MIN_S || a.run_limit_s > SIREN_RUN_MAX_S) return CfgErr.SIREN_RUN_LIMIT;
    }
  }
  return CfgErr.OK;
}

const sameAct = (x, y) => encodeActuator(x).equals(encodeActuator(y));

/** Kilitli bolgeye dokunan degisiklik var mi (409 zone_latched) [O-10]. */
export function touchesLockedZones(oldC, newC, lockedZoneMask) {
  if (!lockedZoneMask) return false;
  for (const [a, b] of [[oldC, newC], [newC, oldC]]) {
    for (let i = 0; i < a.nAct; i++) {
      if (!(a.act[i].zone_mask & lockedZoneMask)) continue;
      let same = false;
      for (let j = 0; j < b.nAct && !same; j++) same = sameAct(a.act[i], b.act[j]);
      if (!same) return true;
    }
    for (let i = 0; i < a.nSens; i++) {
      const s = a.sens[i];
      if (s.zone < 1 || s.zone > MAX_ZONES || !(lockedZoneMask & (1 << (s.zone - 1))) || hazardOf(s.kind) === 0) continue;
      let same = false;
      for (let j = 0; j < b.nSens && !same; j++) {
        const t = b.sens[j];
        same = t.src === s.src && t.index === s.index && t.kind === s.kind && t.zone === s.zone && t.active_open === s.active_open &&
          t.flags === s.flags && t.confirm_ms === s.confirm_ms;
      }
      if (!same) return true;
    }
  }
  return false;
}

// ------------------------------------------------------------------------------------------- CRC32 + bayt kodlama
const CRC_TABLE = (() => {
  const t = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = (c & 1) ? (0xEDB88320 ^ (c >>> 1)) : (c >>> 1);
    t[n] = c >>> 0;
  }
  return t;
})();
export function crc32Update(crc, buf) {
  let c = (~crc) >>> 0;
  for (let i = 0; i < buf.length; i++) c = (CRC_TABLE[(c ^ buf[i]) & 0xFF] ^ (c >>> 8)) >>> 0;
  return (~c) >>> 0;
}
export const crc32 = (buf) => crc32Update(0, typeof buf === 'string' ? Buffer.from(buf, 'latin1') : buf);

function nameBytes(s, cap) {
  const out = Buffer.alloc(cap);
  Buffer.from(String(s ?? ''), 'utf8').copy(out, 0, 0, cap);
  return out;
}
export function encodeSensor(s) {
  const b = Buffer.alloc(28);
  b[0] = s.src; b[1] = s.index; b[2] = s.kind; b[3] = s.zone; b[4] = s.active_open; b[5] = s.flags;
  b.writeUInt16LE(s.confirm_ms & 0xFFFF, 6);
  nameBytes(s.name, NAME_LEN).copy(b, 8);
  return b;
}
export function encodeActuator(a) {
  const b = Buffer.alloc(36);
  b[0] = a.relay; b[1] = a.kind; b[2] = a.close_mode; b[3] = a.fb_di; b[4] = a.fb_closed_active; b[5] = a.zone_mask;
  b.writeUInt16LE(a.fb_timeout_s & 0xFFFF, 6);
  b.writeUInt16LE(a.run_limit_s & 0xFFFF, 8);
  b[10] = a.medium; b[11] = a.aflags;
  nameBytes(a.name, NAME_LEN).copy(b, 12);
  b[32] = a.relay2 || 0;
  return b;
}
export function encodePolicy(p) {
  const b = Buffer.alloc(16);
  b[0] = p.policy_on; b[1] = p.flags || 0;
  b.writeUInt32LE(p.dry_hold_ms >>> 0, 4);
  b[8] = (p.exit_s || 0) & 0xFF;     // hirsiz cikis gecikmesi (0 = 45 sn; F2.B.1)
  b[9] = (p.entry_s || 0) & 0xFF;    // hirsiz giris gecikmesi (0 = 30 sn)
  return b;
}

/** Blob = ogeler + CRC32 (kucuk uclu). encode: oge -> Buffer. */
export function packBlob(items, encode) {
  const body = Buffer.concat(items.map(encode));
  const crc = Buffer.alloc(4);
  crc.writeUInt32LE(crc32(body), 0);
  return Buffer.concat([body, crc]);
}
/** @returns {number} oge sayisi ya da -1 (bozuk) */
export function unpackBlobCount(buf, itemSize, maxN) {
  if (buf.length < 4 || (buf.length - 4) % itemSize !== 0) return -1;
  const body = buf.subarray(0, buf.length - 4);
  const n = body.length / itemSize;
  if (n > maxN) return -1;
  return crc32(body) === buf.readUInt32LE(buf.length - 4) ? n : -1;
}

// NVS bos girdi butcesi (inceleme turu RV-3; firmware SafetyConfig.h). Simulatorun NVS modeli girdi saymaz: yalniz hesap portlanir.
export const NVS_SAFETY_RESERVE_ENTRIES = 16;
// Inceleme turu 2 FW2-3: IDF 4.4 free_entries cop toplama icin bos tutulan sayfayi (126 girdi) da sayar; paydan dusulur.
export const NVS_GC_PAGE_ENTRIES = 126;
export const nvsBlobEntries = (len) => 2 + Math.floor((len + 31) / 32);
export function configNvsEntries(c) {
  return 3 + nvsBlobEntries(16 + 4) + nvsBlobEntries(MAX_ZONES * 16 + 4) + nvsBlobEntries(c.nSens * 28 + 4) + nvsBlobEntries(c.nAct * 36 + 4)
    + nvsBlobEntries(MAX_RELAYS * 4 + 4);
}
export const nvsRoomForConfig = (freeEntries, c) => freeEntries >= configNvsEntries(c) + NVS_SAFETY_RESERVE_ENTRIES + NVS_GC_PAGE_ENTRIES;

/**
 * Ana yapilandirma degisiminin capraz dogrulamasi (WebPortal /api/config, seri CLI; inceleme turu 2 FW2-1): validate() + koruma maskesindeki
 * (acilis guvenli maskesi | kilit maskesi) role panjur/darbe yapilamaz. Guvenlik tablosu bos (cfg_corrupt) olsa bile gecerlidir.
 * @param {bigint} relayGuard bit = role-1
 */
export function validateSystemChange(sys, c, relayGuard) {
  const e = validate(sys, c);
  if (e !== CfgErr.OK) return e;
  const g = BigInt(relayGuard);
  const totalR = sys.totalRelays();
  for (let r = 1; r <= totalR && r <= MAX_RELAYS; r++) {
    if (!(g & (1n << BigInt(r - 1)))) continue;
    const u = relayUsable(sys, r);
    if (u !== CfgErr.OK) return u;
  }
  return CfgErr.OK;
}

/** Guvenli kipte dayatilabilecek acilis maskesi bitleri (EM-5): var olan, panjur/darbe OLMAYAN roleler. @returns {bigint} */
export function bootMaskForSystem(sys, mask) {
  const totalR = sys.totalRelays();
  let out = 0n;
  for (let r = 1; r <= totalR && r <= MAX_RELAYS; r++) {
    const b = 1n << BigInt(r - 1);
    if (!(BigInt(mask) & b)) continue;
    const t = sys.relays[r - 1].type;
    if (t === RelayType.SHUTTER_UP || t === RelayType.SHUTTER_DOWN || t === RelayType.IMPULSE) continue;
    out |= b;
  }
  return out;
}

/** state cfg.safety.crc: pol + bolgeler + dolu yuvalar + isik secenekleri (rev CRC'ye girmez). */
export function configCrc(c) {
  let crc = crc32Update(0, encodePolicy(c.pol));
  crc = crc32Update(crc, Buffer.concat(c.zones.map((z) => nameBytes(z.name, ZONE_NAME_LEN))));
  crc = crc32Update(crc, Buffer.from([c.nSens]));
  crc = crc32Update(crc, Buffer.concat(c.sens.slice(0, c.nSens).map(encodeSensor)));
  crc = crc32Update(crc, Buffer.from([c.nAct]));
  crc = crc32Update(crc, Buffer.concat(c.act.slice(0, c.nAct).map(encodeActuator)));
  crc = crc32Update(crc, Buffer.from(c.light.flatMap((l) => [l.dimmable, l.dimmer_src, l.dimmer_addr, l.dimmer_ch])));
  return crc;
}

// ------------------------------------------------------------------------------------------- kilit kaydi
const emptyLatchZone = () => ({ st: 0, kinds: 0, silenced: 0, acked: 0, aid: '', nsrcs: 0, sinceEpoch: 0, srcs: new Array(8).fill(0) });
export function encodeLatch(r) {
  const b = Buffer.alloc(164);
  for (let z = 0; z < MAX_ZONES; z++) {
    const o = z * 32;
    const lz = r.z[z];
    b[o] = lz.st; b[o + 1] = lz.kinds; b[o + 2] = lz.silenced; b[o + 3] = lz.acked;
    nameBytes(lz.aid, 15).copy(b, o + 4);
    b[o + 19] = lz.nsrcs;
    b.writeUInt32LE(lz.sinceEpoch >>> 0, o + 20);
    for (let k = 0; k < 8; k++) b[o + 24 + k] = lz.srcs[k] || 0;
  }
  b[128] = r.m.localAssert; b[129] = r.m.localLevel;
  b.writeUInt32LE(r.m.extAssert >>> 0, 132);
  b.writeUInt32LE(r.m.extLevel >>> 0, 136);
  b.writeUInt32LE(r.crc >>> 0, 160);
  return b;
}
export const latchCrc = (r) => crc32(encodeLatch(r).subarray(0, 160));
export function latchSeal(r) { r.crc = latchCrc(r); return r; }
export const latchValid = (r) => !!r && r.crc === latchCrc(r);
export function latchClear() {
  return latchSeal({ z: Array.from({ length: MAX_ZONES }, emptyLatchZone), m: { localAssert: 0, localLevel: 0, extAssert: 0, extLevel: 0 }, crc: 0 });
}
export function latchZoneMask(r) {
  let m = 0;
  for (let z = 0; z < MAX_ZONES; z++) if (r.z[z].st !== 0) m |= 1 << z;
  return m;
}
export const latchAny = (r) => latchZoneMask(r) !== 0;
export const latchAssert64 = (r) => BigInt(r.m.localAssert) | (BigInt(r.m.extAssert >>> 0) << 8n);
export const latchLevel64 = (r) => (BigInt(r.m.localLevel) | (BigInt(r.m.extLevel >>> 0) << 8n)) & latchAssert64(r);
export function latchSetMasks(r, assertMask, levelMask) {
  const lv = levelMask & assertMask;
  r.m.localAssert = Number(assertMask & 0xFFn);
  r.m.localLevel = Number(lv & 0xFFn);
  r.m.extAssert = Number((assertMask >> 8n) & 0xFFFFFFFFn);
  r.m.extLevel = Number((lv >> 8n) & 0xFFFFFFFFn);
}
export const cloneLatch = (r) => JSON.parse(JSON.stringify(r));

// ------------------------------------------------------------------------------------------- cokme dongusu
export const crashClear = () => ({ count: 0, stableWritten: 0 });
export function crashOnBoot(c, unexpected) {
  c.stableWritten = 0;
  if (unexpected && c.count < 255) c.count++;
}
export const crashLoop = (c) => c.count >= CRASH_LOOP_COUNT;
export function crashStableTick(c, uptimeMs) {
  if (c.stableWritten || uptimeMs < CRASH_STABLE_MS) return false;
  c.stableWritten = 1;
  if (c.count === 0) return false;
  c.count = 0;
  return true;
}

// ------------------------------------------------------------------------------------------- acilis kipi
export const SafeReason = Object.freeze({ NONE: 0, CFG_CORRUPT: 1, LATCH_ORPHAN: 2, CRASH_LOOP: 3 });
export const safeReasonText = (r) => ['', 'cfg_corrupt', 'latch_orphan', 'crash_loop'][r] ?? '';

export function decideBootMode(cfgPresent, cfgCrcOk, latch, cfg, crash) {
  if (cfgPresent && !cfgCrcOk) return SafeReason.CFG_CORRUPT;
  if (latch && latchAny(latch)) {
    const need = latchAssert64(latch);
    const have = actuatorRelayMask(cfg.act, cfg.nAct);
    if (cfg.nAct === 0 || (need & ~have) !== 0n) return SafeReason.LATCH_ORPHAN;
  }
  if (crashLoop(crash)) return SafeReason.CRASH_LOOP;
  return SafeReason.NONE;
}
