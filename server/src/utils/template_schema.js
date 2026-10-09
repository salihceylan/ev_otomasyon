'use strict';

// ==============================================================================
// AHBU Akilli Ev - Kurulum sablonu dogrulayicisi `ahbu-template/1` (Faz 1 / IP-1.2, plan K-S2)
// ==============================================================================
//
// Tek kaynak: docs/contracts/template/README.md (alanlar, sinirlar, hata kodlari, DOGRULAMA SIRASI).
// Ortak ornekler: docs/contracts/template/fixtures (sunucu, firmware ve servis yazilimi ayni sonucu vermeli).
// SAF modul: G/C yok, asla firlatmaz. Ilk hata doner: {ok:false, error:"<kod>", path:"relays[3].runtime_s"}.
// Yalniz sablon GOVDESI dogrulanir (kart zarfi `{template, label}` DEGIL).
//
// Firmware ile BIREBIR hizali (ev_otomasyon_servis_yazilimi/waveshare_s3_demo/src/template/TemplateParse.cpp parseTemplate,
// safety/SafetyCfgApi.cpp parseSensorItem/parseActuatorItem/parseLightItem, safety/SafetyConfig.h validate): ayni sira,
// ayni kodlar, ayni yollar. Ozet:
//   yapi/tip hatasi, bilinmeyen ya da eksik alan  -> bad_field
//   meta  -> invalid_template_id | invalid_version | invalid_name | invalid_flat_type | invalid_site_id
//   relays[].room / load, dis[].wiring           -> invalid_room / invalid_load / invalid_wiring
//   zones -> bad_zone (liste, kimlik, bolge 1 yok) | bad_name (bolge adi)
//   sensor/eylemci/isik oge ayristirici          -> bad_id | bad_kind | bad_zone | bad_value | bad_relay | bad_name | bad_field
//   cok fazla oge -> count; eylemci tanimsiz bolge -> act_zone; dimmer lamba olmayan / tekrarli role -> invalid_light
//   capraz kurallar (firmware validate): sensor_di_range, sensor_src, sensor_bridge_unsupported, sensor_dup,
//   sensor_di_is_button, gas_smoke_not_nc,
//   arm_key_not_nc, confirm_range, act_relay_range|shutter|impulse|dup, act_zone, valve_medium, pulse_relay2, pulse_time,
//   fb_di_range, fb_di_conflict, fb_timeout_range, siren_run_limit.

const crypto = require('crypto');

const SCHEMA = 'ahbu-template/1';
const EXT_CHANNELS = Object.freeze([0, 2, 4, 8, 12, 16, 24, 32]);
const RELAY_TYPES = Object.freeze(['light', 'shutter_up', 'shutter_down', 'impulse']);
const DI_MODES = Object.freeze(['toggle', 'momentary', 'shutter_step', 'shutter_up', 'shutter_down']);
const SENSOR_KINDS = Object.freeze(['water', 'gas', 'smoke', 'door', 'window', 'motion', 'generic', 'alarm_ack', 'valve_close', 'gas_reset', 'arm_key']);
const CONTROL_KINDS = Object.freeze(['alarm_ack', 'valve_close', 'gas_reset', 'arm_key']);
const ACTUATOR_KINDS = Object.freeze(['valve', 'siren', 'fan', 'generic']);
const CLOSE_MODES = Object.freeze(['energize', 'deenergize', 'pulse']);
const MEDIA = Object.freeze(['water', 'gas', 'none']);
const MAX_SENSORS = 56;
const MAX_ACTUATORS = 16;
const MAX_ZONES = 4;
const MAX_RELAYS = 40;
const MAX_DI = 40;
const MAX_BRIDGE = 16;
const NAME_LEN = 20; // sensor/eylemci adi: < 20 bayt
const ZONE_NAME_MAX = 15;
const SF_ALL = 0x1f;
const DRY_HOLD_MIN_MS = 1000;
const DRY_HOLD_MAX_MS = 600000;
const CONFIRM_MIN_MS = 100;
const CONFIRM_MAX_MS = 10000;
const FB_TIMEOUT_MIN_S = 2;
const FB_TIMEOUT_MAX_S = 300;
const FB_TIMEOUT_DEFAULT_S = 60;
const SIREN_RUN_DEFAULT_S = 180;
const SIREN_RUN_MIN_S = 10;
const SIREN_RUN_MAX_S = 1800;
const PULSE_DEFAULT_S = 15;
const PULSE_MAX_S = 120;
const INT32_MAX = 2147483647;
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

const ROOT_KEYS = Object.freeze(['schema', 'meta', 'ext_module', 'relays', 'dis', 'safety']);
const META_KEYS = Object.freeze(['template_id', 'version', 'name', 'flat_type', 'site_id']);
const EXT_KEYS = Object.freeze(['enabled', 'channels', 'address']);
const RELAY_KEYS = Object.freeze(['ch', 'name', 'room', 'type', 'runtime_s', 'pulse_ms', 'load']);
const DI_KEYS = Object.freeze(['ch', 'name', 'target_relay', 'mode', 'wiring']);
const SAFETY_KEYS = Object.freeze(['policy', 'intrusion', 'zones', 'sensors', 'actuators', 'lights']);
const SENSOR_KEYS = Object.freeze(['id', 'kind', 'zone', 'active_open', 'flags', 'confirm_ms', 'name']);
const ACTUATOR_KEYS = Object.freeze([
  'id', 'relay', 'relay2', 'kind', 'close_mode', 'medium', 'zones', 'fb_di', 'fb_closed_active', 'fb_timeout_s', 'run_limit_s', 'exproof', 'name',
]);
const LIGHT_KEYS = Object.freeze(['relay', 'dimmable', 'src', 'addr', 'ch']);

const has = (o, k) => Object.prototype.hasOwnProperty.call(o, k);
const isObj = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);
const isI32 = (v) => typeof v === 'number' && Number.isInteger(v) && v >= -2147483648 && v <= INT32_MAX;
const intIn = (v, lo, hi) => isI32(v) && v >= lo && v <= hi;
const flagVal = (v) => (v === true || v === 1 ? 1 : 0);

class Fail {
  constructor(error, path) {
    this.error = error;
    this.path = path;
  }
}
const fail = (error, path) => {
  throw new Fail(error, path);
};

/** Firmware textOk / isCleanUtf8: dizge, C0/DEL yok, eslenmemis vekil yok, bayt sayisi [min, max]. */
function textOk(s, min, max) {
  if (typeof s !== 'string') return false;
  if (/[\u0000-\u001f\u007f]/.test(s)) return false;
  if (/[\ud800-\udfff]/.test(s.replace(/[\ud800-\udbff][\udc00-\udfff]/g, ''))) return false;
  const n = Buffer.byteLength(s, 'utf8');
  return n >= min && n <= max;
}
const optText = (o, k, max) => !has(o, k) || textOk(o[k], 0, max);

function firstUnknown(o, keys) {
  return Object.keys(o).find((k) => !keys.includes(k)) || null;
}

// --- SafetyCfgApi alan okuyuculari: 'missing' | 'bad' | {v} ---
function getInt(o, k) {
  if (!has(o, k)) return 'missing';
  return isI32(o[k]) ? { v: o[k] } : 'bad';
}
function getStr(o, k) {
  if (!has(o, k)) return 'missing';
  return typeof o[k] === 'string' ? { v: o[k] } : 'bad';
}
function getFlag(o, k) {
  if (!has(o, k)) return 'missing';
  if (typeof o[k] === 'boolean') return { v: o[k] ? 1 : 0 };
  return o[k] === 0 || o[k] === 1 ? { v: o[k] } : 'bad';
}
const isBad = (r) => r === 'bad';
const nameOk = (s) => textOk(s, 0, NAME_LEN - 1);

/** parseSensorId: d1..d40 / b1..b16, bastaki sifir yok. */
function sensorId(s) {
  const m = /^([db])([1-9][0-9]{0,3})$/.exec(typeof s === 'string' ? s : '');
  if (!m) return null;
  const n = Number(m[2]);
  const di = m[1] === 'd';
  return n >= 1 && n <= (di ? MAX_DI : MAX_BRIDGE) ? { di, index: n } : null;
}

// ---- meta (TemplateParse parseMeta) ----
function parseMeta(m) {
  if (!isObj(m)) fail('bad_field', 'meta');
  const bad = firstUnknown(m, META_KEYS);
  if (bad) fail('bad_field', `meta.${bad}`);
  for (const k of META_KEYS) if (!has(m, k)) fail('bad_field', `meta.${k}`);
  if (typeof m.template_id !== 'string' || !UUID_RE.test(m.template_id)) fail('invalid_template_id', 'meta.template_id');
  if (!intIn(m.version, 1, INT32_MAX)) fail('invalid_version', 'meta.version');
  if (!textOk(m.name, 1, 48)) fail('invalid_name', 'meta.name');
  if (!textOk(m.flat_type, 1, 16)) fail('invalid_flat_type', 'meta.flat_type');
  if (m.site_id !== null && (typeof m.site_id !== 'string' || !UUID_RE.test(m.site_id))) fail('invalid_site_id', 'meta.site_id');
}

// ---- ext_module (parseExt) -> N ----
function parseExt(x) {
  if (!isObj(x)) fail('bad_field', 'ext_module');
  const bad = firstUnknown(x, EXT_KEYS);
  if (bad) fail('bad_field', `ext_module.${bad}`);
  if (typeof x.enabled !== 'boolean') fail('bad_field', 'ext_module.enabled');
  const en = x.enabled;
  if (!intIn(x.channels, 0, 255) || !EXT_CHANNELS.includes(x.channels) || (en ? x.channels === 0 : x.channels !== 0)) {
    fail('invalid_ext_channels', 'ext_module.channels');
  }
  if (!intIn(x.address, 1, 247)) fail('invalid_ext_address', 'ext_module.address');
  return 8 + (en ? x.channels : 0);
}

// ---- relays (parseRelays) ----
function parseRelays(a, n) {
  if (!Array.isArray(a) || a.length !== n) fail('relay_count', 'relays');
  a.forEach((it, i) => {
    if (!isObj(it) || !intIn(it.ch, 1, MAX_RELAYS) || it.ch !== i + 1) fail('relay_count', `relays[${i}].ch`);
  });
  a.forEach((r, i) => {
    const bad = firstUnknown(r, RELAY_KEYS);
    if (bad) fail('bad_field', `relays[${i}].${bad}`);
    if (!textOk(r.name, 1, 31)) fail('invalid_name', `relays[${i}].name`);
    if (!optText(r, 'room', 31)) fail('invalid_room', `relays[${i}].room`);
    if (!optText(r, 'load', 48)) fail('invalid_load', `relays[${i}].load`);
    if (!RELAY_TYPES.includes(r.type)) fail('invalid_type', `relays[${i}].type`);
    const shutter = r.type === 'shutter_up' || r.type === 'shutter_down';
    if (shutter) {
      if (!intIn(r.runtime_s, 1, 300)) fail('invalid_runtime', `relays[${i}].runtime_s`);
    } else if (has(r, 'runtime_s')) {
      fail('invalid_runtime', `relays[${i}].runtime_s`);
    }
    if (r.type === 'impulse') {
      if (!intIn(r.pulse_ms, 100, 60000)) fail('invalid_runtime', `relays[${i}].pulse_ms`);
    } else if (has(r, 'pulse_ms')) {
      fail('invalid_runtime', `relays[${i}].pulse_ms`);
    }
  });
  const isSh = (t) => t === 'shutter_up' || t === 'shutter_down';
  for (let p = 0; p < Math.floor(n / 2); p++) {
    const t1 = a[2 * p].type;
    const t2 = a[2 * p + 1].type;
    const pair = t1 === 'shutter_up' && t2 === 'shutter_down';
    if ((isSh(t1) || isSh(t2)) && !pair) fail('invalid_shutter_pair', `relays[${2 * p}].type`);
  }
  for (let p = 0; p < Math.floor(n / 2); p++) {
    if (a[2 * p].type !== 'shutter_up') continue;
    if (a[2 * p].runtime_s !== a[2 * p + 1].runtime_s) fail('invalid_runtime', `relays[${2 * p + 1}].runtime_s`);
  }
}

// ---- dis (parseDis) ----
function parseDis(a, relays, n) {
  if (!Array.isArray(a) || a.length !== n) fail('di_count', 'dis');
  a.forEach((it, i) => {
    if (!isObj(it) || !intIn(it.ch, 1, MAX_DI) || it.ch !== i + 1) fail('di_count', `dis[${i}].ch`);
  });
  a.forEach((d, i) => {
    const bad = firstUnknown(d, DI_KEYS);
    if (bad) fail('bad_field', `dis[${i}].${bad}`);
    if (!textOk(d.name, 1, 31)) fail('invalid_name', `dis[${i}].name`);
    if (!optText(d, 'wiring', 48)) fail('invalid_wiring', `dis[${i}].wiring`);
    if (!intIn(d.target_relay, 0, n)) fail('invalid_target_relay', `dis[${i}].target_relay`);
    if (!DI_MODES.includes(d.mode)) fail('invalid_mode', `dis[${i}].mode`);
    if (d.mode.startsWith('shutter_') && (d.target_relay < 1 || relays[d.target_relay - 1].type !== 'shutter_up')) {
      fail('invalid_target_relay', `dis[${i}].target_relay`);
    }
  });
}

// ---- oge ayristiricilari (SafetyCfgApi) ----
/** @returns {string|null} hata kodu; basariliysa sens doldurulur */
function parseSensorItem(o, sens) {
  if (firstUnknown(o, SENSOR_KEYS)) return 'bad_field';
  const id = getStr(o, 'id');
  const ref = id === 'missing' || isBad(id) ? null : sensorId(id.v);
  if (!ref) return 'bad_id';
  const kind = getStr(o, 'kind');
  if (kind === 'missing' || isBad(kind) || !SENSOR_KINDS.includes(kind.v)) return 'bad_kind';
  const zone = getInt(o, 'zone');
  if (zone === 'missing' || isBad(zone) || zone.v < 0 || zone.v > MAX_ZONES) return 'bad_zone';
  const ao = getFlag(o, 'active_open');
  if (isBad(ao)) return 'bad_value';
  const fl = getInt(o, 'flags');
  if (isBad(fl) || (fl !== 'missing' && (fl.v < 0 || fl.v > SF_ALL))) return 'bad_value';
  const cm = getInt(o, 'confirm_ms');
  if (isBad(cm) || (cm !== 'missing' && (cm.v < 0 || cm.v > 60000))) return 'bad_value';
  const name = getStr(o, 'name');
  if (isBad(name) || (name !== 'missing' && !nameOk(name.v))) return 'bad_name';
  const hz = ['water', 'gas', 'smoke'].includes(kind.v);
  Object.assign(sens, {
    di: ref.di,
    index: ref.index,
    kind: kind.v,
    zone: zone.v,
    active_open: ao === 'missing' ? 0 : ao.v,
    confirm_ms: cm !== 'missing' ? cm.v : kind.v === 'water' ? 1000 : hz ? 300 : 0,
  });
  return null;
}

function parseActuatorItem(o, a) {
  if (firstUnknown(o, ACTUATOR_KEYS)) return 'bad_field';
  if (has(o, 'id')) return 'bad_field'; // sablon eylemcisi: sira = a1.. ("id" YOK)
  const relay = getInt(o, 'relay');
  if (relay === 'missing' || isBad(relay) || relay.v < 1 || relay.v > MAX_RELAYS) return 'bad_relay';
  const kind = getStr(o, 'kind');
  if (kind === 'missing' || isBad(kind) || !ACTUATOR_KINDS.includes(kind.v)) return 'bad_kind';
  const cmode = getStr(o, 'close_mode');
  if (isBad(cmode) || (cmode !== 'missing' && !CLOSE_MODES.includes(cmode.v))) return 'bad_value';
  const medium = getStr(o, 'medium');
  if (isBad(medium) || (medium !== 'missing' && !MEDIA.includes(medium.v))) return 'bad_value';
  let zoneMask = 0;
  if (has(o, 'zones')) {
    if (!Array.isArray(o.zones)) return 'bad_zone';
    for (const z of o.zones) {
      if (!intIn(z, 1, MAX_ZONES)) return 'bad_zone';
      zoneMask |= 1 << (z - 1);
    }
  }
  const relay2 = getInt(o, 'relay2');
  if (isBad(relay2) || (relay2 !== 'missing' && (relay2.v < 0 || relay2.v > MAX_RELAYS))) return 'bad_relay';
  const fbDi = getInt(o, 'fb_di');
  if (isBad(fbDi) || (fbDi !== 'missing' && (fbDi.v < 0 || fbDi.v > MAX_DI))) return 'bad_value';
  if (isBad(getFlag(o, 'fb_closed_active'))) return 'bad_value';
  const fbT = getInt(o, 'fb_timeout_s');
  if (isBad(fbT) || (fbT !== 'missing' && (fbT.v < 0 || fbT.v > 65535))) return 'bad_value';
  const run = getInt(o, 'run_limit_s');
  if (isBad(run) || (run !== 'missing' && (run.v < 0 || run.v > 65535))) return 'bad_value';
  if (has(o, 'exproof') && typeof o.exproof !== 'boolean') return 'bad_value';
  const name = getStr(o, 'name');
  if (isBad(name) || (name !== 'missing' && !nameOk(name.v))) return 'bad_name';
  const closeMode = cmode === 'missing' ? 'energize' : cmode.v;
  let runLimit = 0;
  if (run !== 'missing') runLimit = run.v;
  else if (kind.v === 'siren') runLimit = SIREN_RUN_DEFAULT_S;
  else if (closeMode === 'pulse' && kind.v === 'valve') runLimit = PULSE_DEFAULT_S;
  Object.assign(a, {
    relay: relay.v,
    relay2: relay2 === 'missing' ? 0 : relay2.v,
    kind: kind.v,
    close_mode: closeMode,
    medium: medium === 'missing' ? 'none' : medium.v,
    zone_mask: zoneMask,
    fb_di: fbDi === 'missing' ? 0 : fbDi.v,
    fb_timeout_s: fbT === 'missing' ? FB_TIMEOUT_DEFAULT_S : fbT.v,
    run_limit_s: runLimit,
  });
  return null;
}

function parseLightItem(o) {
  if (firstUnknown(o, LIGHT_KEYS)) return { err: 'bad_field' };
  const relay = getInt(o, 'relay');
  if (relay === 'missing' || isBad(relay) || relay.v < 1 || relay.v > MAX_RELAYS) return { err: 'bad_relay' };
  if (isBad(getFlag(o, 'dimmable'))) return { err: 'bad_value' };
  for (const [k, hi] of [['src', 2], ['addr', 247], ['ch', 255]]) {
    const r = getInt(o, k);
    if (isBad(r) || (r !== 'missing' && (r.v < 0 || r.v > hi))) return { err: 'bad_value' };
  }
  return { relay: relay.v };
}

// ---- capraz dogrulama (SafetyConfig.h validate; bos yapilandirmada OK) ----
function relayUsable(relays, n, r) {
  if (r < 1 || r > n) return 'act_relay_range';
  const t = relays[r - 1].type;
  if (t === 'shutter_up' || t === 'shutter_down') return 'act_relay_shutter';
  if (t === 'impulse') return 'act_relay_impulse';
  return null;
}

function crossValidate(relays, dis, n, sensors, actuators) {
  if (sensors.length > MAX_SENSORS || actuators.length > MAX_ACTUATORS) return 'count';
  let sensorDi = 0n;
  for (const s of sensors) {
    const control = CONTROL_KINDS.includes(s.kind);
    if (s.di) {
      if (s.index < 1 || s.index > n) return 'sensor_di_range';
      const b = 1n << BigInt(s.index - 1);
      if (sensorDi & b) return 'sensor_dup';
      sensorDi |= b;
      if (dis[s.index - 1].target_relay !== 0) return 'sensor_di_is_button';
    } else {
      if (control) return 'sensor_src';
      // fw-tarama-1 (sozlesme C1): firmware kopru surucusu olmadan derlenir (BridgeSensor.h, caps'te 'bridge' yok); kopru
      // sensoru kartta hic okunmaz. Sira firmware validate(forWrite) ve servis yazilimiyla ayni: aralik/dup denetiminden once.
      return 'sensor_bridge_unsupported';
    }
    if (control ? s.zone > MAX_ZONES : s.zone < 1 || s.zone > MAX_ZONES) return 'sensor_zone';
    const gasSmoke = s.kind === 'gas' || s.kind === 'smoke';
    if (gasSmoke && !s.active_open) return 'gas_smoke_not_nc';
    if (s.kind === 'arm_key' && !s.active_open) return 'arm_key_not_nc';
    const hz = s.kind === 'water' || gasSmoke;
    if (hz && (s.confirm_ms < CONFIRM_MIN_MS || s.confirm_ms > CONFIRM_MAX_MS)) return 'confirm_range';
    if (!hz && s.confirm_ms > CONFIRM_MAX_MS) return 'confirm_range';
  }
  const used = new Set();
  for (const a of actuators) {
    let e = relayUsable(relays, n, a.relay);
    if (e) return e;
    if (used.has(a.relay)) return 'act_relay_dup';
    used.add(a.relay);
    if (a.kind !== 'generic' && (a.zone_mask === 0 || a.zone_mask > 0x0f)) return 'act_zone';
    if (a.zone_mask > 0x0f) return 'act_zone';
    if (a.kind === 'valve') {
      if (a.medium !== 'water' && a.medium !== 'gas') return 'valve_medium';
      if (a.close_mode === 'pulse') {
        if (a.relay2 === 0 || a.relay2 === a.relay) return 'pulse_relay2';
        e = relayUsable(relays, n, a.relay2);
        if (e) return e;
        if (used.has(a.relay2)) return 'act_relay_dup';
        used.add(a.relay2);
        if (a.run_limit_s > PULSE_MAX_S) return 'pulse_time';
      }
      if (a.fb_di !== 0) {
        if (a.fb_di > n) return 'fb_di_range';
        if ((sensorDi & (1n << BigInt(a.fb_di - 1))) || dis[a.fb_di - 1].target_relay !== 0) return 'fb_di_conflict';
        if (a.fb_timeout_s < FB_TIMEOUT_MIN_S || a.fb_timeout_s > FB_TIMEOUT_MAX_S) return 'fb_timeout_range';
      }
    } else if (a.kind === 'siren') {
      if (a.run_limit_s < SIREN_RUN_MIN_S || a.run_limit_s > SIREN_RUN_MAX_S) return 'siren_run_limit';
    }
  }
  return null;
}

// ---- safety (parseSafety) ----
function parseSafety(s, relays, dis, n) {
  if (!isObj(s)) fail('bad_field', 'safety');
  const bad = firstUnknown(s, SAFETY_KEYS);
  if (bad) fail('bad_field', `safety.${bad}`);

  const p = s.policy;
  if (!isObj(p)) fail('bad_field', 'safety.policy');
  if (firstUnknown(p, ['on', 'dry_hold_ms']) || typeof p.on !== 'boolean' || !isI32(p.dry_hold_ms)) fail('bad_field', 'safety.policy');
  if (p.dry_hold_ms < DRY_HOLD_MIN_MS || p.dry_hold_ms > DRY_HOLD_MAX_MS) fail('dry_hold', 'safety.policy.dry_hold_ms');

  if (has(s, 'intrusion')) {
    const it = s.intrusion;
    if (!isObj(it)) fail('bad_field', 'safety.intrusion');
    if (firstUnknown(it, ['exit_s', 'entry_s'])) fail('bad_field', 'safety.intrusion');
    for (const k of ['exit_s', 'entry_s']) {
      if (has(it, k) && !intIn(it[k], 0, 255)) fail('bad_value', `safety.intrusion.${k}`);
    }
  }

  let zoneMask = 0;
  const za = s.zones;
  if (!Array.isArray(za) || za.length < 1 || za.length > MAX_ZONES) fail('bad_zone', 'safety.zones');
  za.forEach((z, i) => {
    if (!isObj(z)) fail('bad_field', `safety.zones[${i}]`);
    const zb = firstUnknown(z, ['id', 'name']);
    if (zb) fail('bad_field', `safety.zones[${i}].${zb}`);
    if (!intIn(z.id, 1, MAX_ZONES) || zoneMask & (1 << (z.id - 1))) fail('bad_zone', `safety.zones[${i}].id`);
    if (!textOk(z.name, 1, ZONE_NAME_MAX)) fail('bad_name', `safety.zones[${i}].name`);
    zoneMask |= 1 << (z.id - 1);
  });
  if (!(zoneMask & 1)) fail('bad_zone', 'safety.zones');

  const sensors = [];
  if (has(s, 'sensors')) {
    if (!Array.isArray(s.sensors)) fail('bad_field', 'safety.sensors');
    if (s.sensors.length > MAX_SENSORS) fail('count', 'safety.sensors');
    s.sensors.forEach((o, i) => {
      if (!isObj(o)) fail('bad_field', `safety.sensors[${i}]`);
      const sc = {};
      const r = parseSensorItem(o, sc);
      if (r) fail(r, `safety.sensors[${i}]`);
      const control = CONTROL_KINDS.includes(sc.kind);
      const zoneOk = (control && sc.zone === 0) || (sc.zone >= 1 && sc.zone <= MAX_ZONES && zoneMask & (1 << (sc.zone - 1)));
      if (!zoneOk) fail('sensor_zone', `safety.sensors[${i}].zone`);
      sensors.push(sc);
    });
  }
  let ve = crossValidate(relays, dis, n, sensors, []);
  if (ve) fail(ve, 'safety.sensors');

  const actuators = [];
  if (has(s, 'actuators')) {
    if (!Array.isArray(s.actuators)) fail('bad_field', 'safety.actuators');
    if (s.actuators.length > MAX_ACTUATORS) fail('count', 'safety.actuators');
    s.actuators.forEach((o, i) => {
      if (!isObj(o)) fail('bad_field', `safety.actuators[${i}]`);
      const ac = {};
      const r = parseActuatorItem(o, ac);
      if (r) fail(r, `safety.actuators[${i}]`);
      if (ac.zone_mask & ~zoneMask) fail('act_zone', `safety.actuators[${i}].zones`);
      actuators.push(ac);
    });
  }
  ve = crossValidate(relays, dis, n, sensors, actuators);
  if (ve) fail(ve, 'safety.actuators');

  if (has(s, 'lights')) {
    if (!Array.isArray(s.lights)) fail('bad_field', 'safety.lights');
    if (s.lights.length > n) fail('count', 'safety.lights');
    const seen = new Set();
    s.lights.forEach((o, i) => {
      if (!isObj(o)) fail('bad_field', `safety.lights[${i}]`);
      const r = parseLightItem(o);
      if (r.err) fail(r.err, `safety.lights[${i}]`);
      if (r.relay > n || relays[r.relay - 1].type !== 'light' || seen.has(r.relay)) fail('invalid_light', `safety.lights[${i}].relay`);
      seen.add(r.relay);
    });
  }
}

/**
 * @param {*} t  sablon govdesi (zarf DEGIL)
 * @returns {{ok:true} | {ok:false, error:string, path:string}}
 */
function validateTemplate(t) {
  try {
    if (!isObj(t)) fail('bad_field', 'template');
    if (typeof t.schema !== 'string' || t.schema !== SCHEMA) fail('schema', 'schema');
    const bad = firstUnknown(t, ROOT_KEYS);
    if (bad) fail('bad_field', bad);
    for (const k of ROOT_KEYS) if (!has(t, k)) fail('bad_field', k);
    parseMeta(t.meta);
    const n = parseExt(t.ext_module);
    parseRelays(t.relays, n);
    parseDis(t.dis, t.relays, n);
    parseSafety(t.safety, t.relays, t.dis, n);
    return { ok: true };
  } catch (err) {
    if (err instanceof Fail) return { ok: false, error: err.error, path: err.path };
    return { ok: false, error: 'bad_field', path: '' }; // savunma: beklenmeyen yapi
  }
}

/** Anahtarlari sirali, bosluksuz JSON (SHA-256 icin kararli bicim). */
function canonicalJson(v) {
  if (Array.isArray(v)) return `[${v.map(canonicalJson).join(',')}]`;
  if (isObj(v)) {
    return `{${Object.keys(v)
      .sort()
      .map((k) => `${JSON.stringify(k)}:${canonicalJson(v[k])}`)
      .join(',')}}`;
  }
  return JSON.stringify(v === undefined ? null : v);
}

function bodySha256(body) {
  return crypto.createHash('sha256').update(canonicalJson(body), 'utf8').digest('hex');
}

/** Govdenin kopyasi; meta.template_id / version / site_id sunucu degerleriyle (istemcinin degerleri yok sayilir). */
function withMeta(body, { templateId, version, siteId }) {
  const out = JSON.parse(JSON.stringify(body));
  if (isObj(out) && isObj(out.meta)) {
    out.meta.template_id = templateId;
    out.meta.version = version;
    out.meta.site_id = siteId === undefined ? null : siteId;
  }
  return out;
}

const CLOUD_TYPE = Object.freeze({ light: 'light', impulse: 'impulse', shutter_up: 'shutter', shutter_down: 'shutter' });
const DIMMER_SOURCE = Object.freeze({ 1: 'modbus', 2: 'bridge' });

/**
 * Claim tohumu (K-S8): gecerli sablondan bulut `endpoints` satirlari. Gecersiz sablonda null (cagiran sabit tohuma duser).
 * Esleme endpoint_layout (WP-L) ile ayni: light -> light, impulse -> impulse, shutter_up/down cifti -> iki `shutter` satiri
 * (cift N = kanal 2N-1 ve 2N, sure = runtime_s). Eylemci rolesi tipini korur, `actuator_type` = eylemci turu (033);
 * dimmer: safety.lights[].dimmable / src (1 modbus, 2 bridge). Oda bos ise addan turetilir, yoksa "Genel".
 * @returns {null | Array<{channel_index, name, type, room, shutter_pair_index, shutter_duration_sec, actuator_type, dimmable, dimmer_source}>}
 */
function endpointRowsFromTemplate(body) {
  if (!validateTemplate(body).ok) return null;
  const { deriveRoom, DEFAULT_ROOM } = require('./endpoint_layout');
  const actuators = new Map();
  for (const a of body.safety.actuators || []) {
    actuators.set(a.relay, a.kind);
    if (Number.isInteger(a.relay2) && a.relay2 > 0) actuators.set(a.relay2, a.kind);
  }
  const lights = new Map();
  for (const l of body.safety.lights || []) lights.set(l.relay, l);
  return body.relays.map((r) => {
    const shutter = CLOUD_TYPE[r.type] === 'shutter';
    const room = typeof r.room === 'string' && r.room.trim() ? r.room.trim() : deriveRoom(r.name) || DEFAULT_ROOM;
    const light = lights.get(r.ch);
    const dimmable = Boolean(light && flagVal(light.dimmable) === 1);
    return {
      channel_index: r.ch,
      name: r.name,
      type: CLOUD_TYPE[r.type],
      room,
      shutter_pair_index: shutter ? (r.ch + 1) >> 1 : null,
      shutter_duration_sec: shutter ? r.runtime_s : null,
      actuator_type: actuators.get(r.ch) || null,
      dimmable,
      dimmer_source: dimmable ? DIMMER_SOURCE[light.src] || null : null,
    };
  });
}

module.exports = {
  validateTemplate,
  endpointRowsFromTemplate,
  canonicalJson,
  bodySha256,
  withMeta,
  SCHEMA,
  UUID_RE,
};
