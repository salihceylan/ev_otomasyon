// safety/SafetyCfgApi.{h,cpp} (firmware) JavaScript portu: guvenlik yapilandirmasi yamasinin JSON ayristiricisi (LAN POST /api/safety/config
// ve bulut sys cfg_patch ortak bicimi; spec 4.1-4.2). "set" ya da "del" icinde TEK oge; bilinmeyen alan / tip / aralik disi -> UYGULANMAZ.
import { SensorKind, SensorSrc, MAX_DI, MAX_BRIDGE, MAX_ACTUATORS, MAX_ZONES, MAX_RELAYS, NAME_LEN, defaultFlags, defaultConfirmMs, makeSensorConfig } from './sensor_hub.js';
import { ActKind, CloseMode, Medium, AF_FAN_EXPROOF, FB_TIMEOUT_DEFAULT_S, SIREN_RUN_DEFAULT_S, PULSE_DEFAULT_S, makeActuatorConfig } from './actuator_map.js';
import { ZONE_NAME_LEN } from './safety_config.js';
import { EditOp, editInit, KIND_BY_TEXT } from './safety_cfg_edit.js';
import { isCleanUtf8 } from './netutil.js';

const isObj = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);
const isInt32 = (v) => typeof v === 'number' && Number.isInteger(v) && v >= -2147483648 && v <= 2147483647;
const isU32 = (v) => typeof v === 'number' && Number.isInteger(v) && v >= 0 && v <= 0xFFFFFFFF;
const has = (o, k) => Object.prototype.hasOwnProperty.call(o, k);
const onlyKeys = (o, keys) => Object.keys(o).every((k) => keys.includes(k));

function parseNum(s, lo, hi) {
  if (typeof s !== 'string' || !/^[1-9][0-9]*$/.test(s) || s.length > 4) return null;
  const v = Number(s);
  return v >= lo && v <= hi ? v : null;
}
export function parseSensorId(s) {
  if (typeof s !== 'string' || (s[0] !== 'd' && s[0] !== 'b')) return null;
  const di = s[0] === 'd';
  const n = parseNum(s.slice(1), 1, di ? MAX_DI : MAX_BRIDGE);
  return n === null ? null : { src: di ? SensorSrc.DI : SensorSrc.BRIDGE, index: n };
}
export function parseActuatorId(s) {
  if (typeof s !== 'string' || s[0] !== 'a') return null;
  const n = parseNum(s.slice(1), 1, MAX_ACTUATORS);
  return n === null ? null : n - 1;
}

// Tip dogrulamali alan: {s:'ok'|'missing'|'bad', v}
const getInt = (o, k) => (!has(o, k) ? { s: 'missing' } : isInt32(o[k]) ? { s: 'ok', v: o[k] } : { s: 'bad' });
const getBool = (o, k) => (!has(o, k) ? { s: 'missing' } : typeof o[k] === 'boolean' ? { s: 'ok', v: o[k] } : { s: 'bad' });
const getStr = (o, k) => (!has(o, k) ? { s: 'missing' } : typeof o[k] === 'string' ? { s: 'ok', v: o[k] } : { s: 'bad' });
function getFlag(o, k) {
  const b = getBool(o, k);
  if (b.s !== 'bad') return b.s === 'ok' ? { s: 'ok', v: b.v ? 1 : 0 } : b;
  const n = getInt(o, k);
  return n.s === 'ok' && (n.v === 0 || n.v === 1) ? n : { s: 'bad' };
}
const nameOk = (s, cap) => Buffer.byteLength(s, 'utf8') < cap && isCleanUtf8(s);

function parseSensor(o, e) {
  if (!onlyKeys(o, ['id', 'kind', 'zone', 'active_open', 'flags', 'confirm_ms', 'name'])) return 'bad_field';
  const id = getStr(o, 'id');
  const sid = id.s === 'ok' ? parseSensorId(id.v) : null;
  if (!sid) return 'bad_id';
  const kind = getStr(o, 'kind');
  const k = kind.s === 'ok' ? KIND_BY_TEXT[kind.v] : undefined;
  if (!k) return 'bad_kind';
  const zone = getInt(o, 'zone');
  if (zone.s !== 'ok' || zone.v < 0 || zone.v > MAX_ZONES) return 'bad_zone';
  const ao = getFlag(o, 'active_open');
  if (ao.s === 'bad') return 'bad_value';
  const fl = getInt(o, 'flags');
  if (fl.s === 'bad' || (fl.s === 'ok' && (fl.v < 0 || fl.v > 7))) return 'bad_value';
  const cm = getInt(o, 'confirm_ms');
  if (cm.s === 'bad' || (cm.s === 'ok' && (cm.v < 0 || cm.v > 60000))) return 'bad_value';
  const nm = getStr(o, 'name');
  if (nm.s === 'bad' || (nm.s === 'ok' && !nameOk(nm.v, NAME_LEN))) return 'bad_name';
  e.sens = makeSensorConfig({
    src: sid.src, index: sid.index, kind: k, zone: zone.v, active_open: ao.s === 'ok' ? ao.v : 0,
    flags: fl.s === 'ok' ? fl.v : defaultFlags(k), confirm_ms: cm.s === 'ok' ? cm.v : defaultConfirmMs(k), name: nm.s === 'ok' ? nm.v : '',
  });
  e.op = EditOp.SET_SENSOR;
  return null;
}

function parseActuator(o, e) {
  if (!onlyKeys(o, ['id', 'relay', 'relay2', 'kind', 'close_mode', 'medium', 'zones', 'fb_di', 'fb_closed_active', 'fb_timeout_s', 'run_limit_s', 'exproof', 'name'])) return 'bad_field';
  const id = getStr(o, 'id');
  if (id.s === 'bad') return 'bad_id';
  if (id.s === 'ok') {
    const i = parseActuatorId(id.v);
    if (i === null) return 'bad_id';
    e.actIndex = i;
  }
  const relay = getInt(o, 'relay');
  if (relay.s !== 'ok' || relay.v < 1 || relay.v > MAX_RELAYS) return 'bad_relay';
  const kind = getStr(o, 'kind');
  const ak = kind.s === 'ok' ? { valve: ActKind.VALVE, siren: ActKind.SIREN, fan: ActKind.FAN, generic: ActKind.GENERIC }[kind.v] : undefined;
  if (!ak) return 'bad_kind';
  const cmo = getStr(o, 'close_mode');
  if (cmo.s === 'bad') return 'bad_value';
  let closeMode = CloseMode.ENERGIZE_TO_CLOSE;
  if (cmo.s === 'ok') {
    closeMode = { energize: CloseMode.ENERGIZE_TO_CLOSE, deenergize: CloseMode.DEENERGIZE_TO_CLOSE, pulse: CloseMode.PULSE_TWO_RELAY }[cmo.v];
    if (closeMode === undefined) return 'bad_value';
  }
  const med = getStr(o, 'medium');
  if (med.s === 'bad') return 'bad_value';
  let medium = Medium.NONE;
  if (med.s === 'ok') {
    medium = { water: Medium.WATER, gas: Medium.GAS, none: Medium.NONE }[med.v];
    if (medium === undefined) return 'bad_value';
  }
  let zoneMask = 0;
  if (has(o, 'zones')) {
    if (!Array.isArray(o.zones)) return 'bad_zone';
    for (const z of o.zones) {
      if (!isInt32(z) || z < 1 || z > MAX_ZONES) return 'bad_zone';
      zoneMask |= 1 << (z - 1);
    }
  }
  const r2 = getInt(o, 'relay2');
  if (r2.s === 'bad' || (r2.s === 'ok' && (r2.v < 0 || r2.v > MAX_RELAYS))) return 'bad_relay';
  const fb = getInt(o, 'fb_di');
  if (fb.s === 'bad' || (fb.s === 'ok' && (fb.v < 0 || fb.v > MAX_DI))) return 'bad_value';
  const fca = getFlag(o, 'fb_closed_active');
  if (fca.s === 'bad') return 'bad_value';
  const fto = getInt(o, 'fb_timeout_s');
  if (fto.s === 'bad' || (fto.s === 'ok' && (fto.v < 0 || fto.v > 65535))) return 'bad_value';
  const rl = getInt(o, 'run_limit_s');
  if (rl.s === 'bad' || (rl.s === 'ok' && (rl.v < 0 || rl.v > 65535))) return 'bad_value';
  let runLimit = 0;
  if (rl.s === 'ok') runLimit = rl.v;
  else if (ak === ActKind.SIREN) runLimit = SIREN_RUN_DEFAULT_S;
  else if (ak === ActKind.VALVE && closeMode === CloseMode.PULSE_TWO_RELAY) runLimit = PULSE_DEFAULT_S;
  const ex = getBool(o, 'exproof');
  if (ex.s === 'bad') return 'bad_value';
  const nm = getStr(o, 'name');
  if (nm.s === 'bad' || (nm.s === 'ok' && !nameOk(nm.v, NAME_LEN))) return 'bad_name';
  e.act = makeActuatorConfig({
    relay: relay.v, kind: ak, close_mode: closeMode, medium, zone_mask: zoneMask, fb_di: fb.s === 'ok' ? fb.v : 0,
    fb_closed_active: fca.s === 'ok' ? fca.v : 1, fb_timeout_s: fto.s === 'ok' ? fto.v : FB_TIMEOUT_DEFAULT_S, run_limit_s: runLimit,
    aflags: ex.s === 'ok' && ex.v ? AF_FAN_EXPROOF : 0, name: nm.s === 'ok' ? nm.v : '', relay2: r2.s === 'ok' ? r2.v : 0,
  });
  e.op = EditOp.SET_ACTUATOR;
  return null;
}

/**
 * @param {object} root  ayristirilmis JSON govdesi
 * @param {boolean} sysEnvelope  sys zarfinin cmd/module/uid/id alanlari kokte bulunabilir
 * @returns {{err:string|null, edit:object, hasBase:boolean, baseRev:number}}
 */
export function parseCfgEdit(root, sysEnvelope = false) {
  const e = editInit();
  const r = (err) => ({ err, edit: e, hasBase, baseRev });
  let hasBase = false;
  let baseRev = 0;
  if (!isObj(root)) return r('bad_field');
  let set = null;
  let del = null;
  for (const [k, v] of Object.entries(root)) {
    if (k === 'base_rev') {
      if (!isU32(v)) return r('bad_base_rev');
      baseRev = v;
      hasBase = true;
    } else if (k === 'set') {
      if (!isObj(v)) return r('bad_field');
      set = v;
    } else if (k === 'del') {
      if (!isObj(v)) return r('bad_field');
      del = v;
    } else if (sysEnvelope && ['cmd', 'module', 'uid', 'id'].includes(k)) {
      /* sys zarfi: cagiran denetler */
    } else {
      return r('bad_field');
    }
  }
  if ((set === null) === (del === null)) return r('bad_field');
  const body = set ?? del;
  const keys = Object.keys(body);
  if (keys.length !== 1) return r('bad_field');
  const what = keys[0];
  const val = body[what];
  if (del) {
    if (typeof val !== 'string') return r('bad_id');
    if (what === 'sensor') {
      const sid = parseSensorId(val);
      if (!sid) return r('bad_id');
      e.sens = makeSensorConfig({ src: sid.src, index: sid.index });
      e.op = EditOp.DEL_SENSOR;
      return r(null);
    }
    if (what === 'actuator') {
      const i = parseActuatorId(val);
      if (i === null) return r('bad_id');
      e.actIndex = i;
      e.op = EditOp.DEL_ACTUATOR;
      return r(null);
    }
    return r('bad_field');
  }
  if (!isObj(val)) return r('bad_field');
  if (what === 'sensor') return r(parseSensor(val, e));
  if (what === 'actuator') return r(parseActuator(val, e));
  if (what === 'policy') {
    if (!onlyKeys(val, ['on', 'dry_hold_ms'])) return r('bad_field');
    const on = getBool(val, 'on');
    if (on.s === 'bad') return r('bad_value');
    const dh = getInt(val, 'dry_hold_ms');
    if (dh.s === 'bad' || (dh.s === 'ok' && dh.v < 0)) return r('bad_value');
    e.hasPolicyOn = on.s === 'ok' ? 1 : 0;
    e.policyOn = on.v ? 1 : 0;
    e.hasDryHold = dh.s === 'ok' ? 1 : 0;
    e.dryHoldMs = dh.s === 'ok' ? dh.v : 0;
    if (!e.hasPolicyOn && !e.hasDryHold) return r('bad_field');
    e.op = EditOp.SET_POLICY;
    return r(null);
  }
  if (what === 'zone') {
    if (!onlyKeys(val, ['id', 'name'])) return r('bad_field');
    const id = getInt(val, 'id');
    if (id.s !== 'ok' || id.v < 1 || id.v > MAX_ZONES) return r('bad_zone');
    const nm = getStr(val, 'name');
    if (nm.s !== 'ok' || !nameOk(nm.v, ZONE_NAME_LEN)) return r('bad_name');
    e.zoneId = id.v;
    e.zoneName = nm.v;
    e.op = EditOp.SET_ZONE;
    return r(null);
  }
  if (what === 'light') {
    if (!onlyKeys(val, ['relay', 'dimmable', 'src', 'addr', 'ch'])) return r('bad_field');
    const relay = getInt(val, 'relay');
    if (relay.s !== 'ok' || relay.v < 1 || relay.v > MAX_RELAYS) return r('bad_relay');
    const dim = getFlag(val, 'dimmable');
    if (dim.s === 'bad') return r('bad_value');
    const src = getInt(val, 'src');
    const addr = getInt(val, 'addr');
    const ch = getInt(val, 'ch');
    if (src.s === 'bad' || (src.s === 'ok' && (src.v < 0 || src.v > 2))) return r('bad_value');
    if (addr.s === 'bad' || (addr.s === 'ok' && (addr.v < 0 || addr.v > 247))) return r('bad_value');
    if (ch.s === 'bad' || (ch.s === 'ok' && (ch.v < 0 || ch.v > 255))) return r('bad_value');
    e.lightRelay = relay.v;
    e.light = { dimmable: dim.s === 'ok' ? dim.v : 0, dimmer_src: src.s === 'ok' ? src.v : 0, dimmer_addr: addr.s === 'ok' ? addr.v : 0, dimmer_ch: ch.s === 'ok' ? ch.v : 0 };
    e.op = EditOp.SET_LIGHT;
    return r(null);
  }
  return r('bad_field');
}

export { SensorKind };
