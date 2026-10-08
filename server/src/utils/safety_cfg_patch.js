'use strict';

// ==============================================================================
// AHBU Akilli Ev - Buluttan guvenlik yapilandirma yamasi: govde dogrulama, sys yuku, kopyaya uygulama, bekleyen kuyruk
// ==============================================================================
//
// Tasarim: docs/superpowers/specs/2026-10-06-guvenlik-iklim-senaryo-mimarisi-design.md "Faz 2 tasarimi" F2.D.1-D.2, D.6.
// SAF modul (G/C yok; asla firlatmaz). Kullananlar: services/safety_service.js (REST), services/safety_cfg_sync.js (kuyruk).
//
// Govde (REST POST /homes/:homeId/devices/:deviceId/safety-config):
//   {base_rev: u32, set: {sensor|actuator|policy|zone|light|intrusion: {...}} | del: {sensor:"dN|bN"} | {actuator:"aN"}, id?}
//   Tek oge; alan listesi ve araliklar firmware parseCfgEdit (src/safety/SafetyCfgApi.cpp) ile AYNI. Capraz kurallar (role
//   cakismasi, NC zorunlulugu ...) panoda: firmware `cfg_invalid` -> 400 CONFIG_INVALID.
//   Hirsiz katmani alanlari (set.intrusion, sensor flags > 0x07, kind "arm_key") yalniz caps 'intrusion' ilan eden panoya
//   (v1.2.0 parseCfgEdit flags > 0x07'yi bad_value ile reddeder): yoksa 409 FIRMWARE_UNSUPPORTED.
// sys yuku: {cmd:"cfg_patch", module:"safety", uid, id, base_rev, set|del} <= 1024 bayt (firmware sys siniri).
// Bekleyen kuyruk (device_configs.pending, surum 1):
//   {"v":1,"items":[{id, base_rev, patch:{set|del}, by, role, at, loosening, sent_at?}], "inflight"?: {id, at, by?}}
//   items <= 16, oge omru 24 sa; inflight = su an panoya gonderilmis ve sonucu beklenen yama (ayni panoya tek ucus;
//   INFLIGHT_TTL_MS sonra gecersiz sayilir: surec cokse bile kilit kalici olmaz).

const MAX_SYS_BYTES = 1024;
const MAX_PENDING_ITEMS = 16;
const PENDING_TTL_MS = 24 * 3600 * 1000;
const INFLIGHT_TTL_MS = 30 * 1000;
const U32_MAX = 0xffffffff;

const MAX_DI = 40;
const MAX_BRIDGE = 16;
const MAX_ACTUATORS = 16;
const MAX_RELAYS = 40;
const MAX_ZONES = 4;
const NAME_LEN = 20; // firmware NAME_LEN (sonlandirici dahil): bayt < 20
const ZONE_NAME_LEN = 16;
const COMMAND_ID_RE = /^[A-Za-z0-9_.:-]{1,24}$/;

const SENSOR_KINDS = Object.freeze(['water', 'gas', 'smoke', 'door', 'window', 'motion', 'generic', 'alarm_ack', 'valve_close', 'gas_reset']);
const INTRUSION_SENSOR_KINDS = Object.freeze(['arm_key']); // F2.B.3: yerel kumanda rolu (firmware 1.2.1)
const ACTUATOR_KINDS = Object.freeze(['valve', 'siren', 'fan', 'generic']);
const CLOSE_MODES = Object.freeze(['energize', 'deenergize', 'pulse']);
const MEDIA = Object.freeze(['water', 'gas', 'none']);
const SET_ITEMS = Object.freeze(['sensor', 'actuator', 'policy', 'zone', 'light', 'intrusion']);
const DEL_ITEMS = Object.freeze(['sensor', 'actuator']);

const SF_REACT = 0x01;
const SF_FAULT_CLOSE = 0x04;
const SF_ENTRY = 0x08; // hirsiz: giris yolu (firmware 1.2.1 defaultFlags: kapi)
const SF_AWAY_ONLY = 0x10; // hirsiz: yalniz disarida (firmware 1.2.1 defaultFlags: hareket)
const FB_TIMEOUT_DEFAULT_S = 60;
const SIREN_RUN_DEFAULT_S = 180;
const PULSE_DEFAULT_S = 15;

const has = (o, k) => Object.prototype.hasOwnProperty.call(o, k);
const isObj = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);
const isInt32 = (v) => typeof v === 'number' && Number.isInteger(v) && v >= -2147483648 && v <= 2147483647;
const isU32 = (v) => typeof v === 'number' && Number.isInteger(v) && v >= 0 && v <= U32_MAX;
const clone = (o) => JSON.parse(JSON.stringify(o));

function fail(message, code = 'VALIDATION', status = 400) {
  return { ok: false, status, code, message };
}

function unknownKey(o, keys) {
  return Object.keys(o).find((k) => !keys.includes(k)) || null;
}

function intIn(o, k, lo, hi) {
  if (!has(o, k)) return { s: 'missing' };
  return isInt32(o[k]) && o[k] >= lo && o[k] <= hi ? { s: 'ok', v: o[k] } : { s: 'bad' };
}

/** Firmware getFlag: boolean ya da 0/1. */
function flagOf(o, k) {
  if (!has(o, k)) return { s: 'missing' };
  const v = o[k];
  if (typeof v === 'boolean') return { s: 'ok', v: v ? 1 : 0 };
  return v === 0 || v === 1 ? { s: 'ok', v } : { s: 'bad' };
}

/** Firmware isCleanUtf8 + NAME_LEN: gecerli UTF-8 (JS dizgesi), C0/DEL yok, bayt < cap. */
function nameOk(s, cap) {
  if (typeof s !== 'string') return false;
  if (/[\u0000-\u001f\u007f]/.test(s)) return false;
  if (/[\ud800-\udfff]/.test(s.replace(/[\ud800-\udbff][\udc00-\udfff]/g, ''))) return false; // eslenmemis vekil
  return Buffer.byteLength(s, 'utf8') < cap;
}

function sensorIdOk(s) {
  if (typeof s !== 'string') return false;
  const m = /^([db])([1-9][0-9]{0,3})$/.exec(s);
  if (!m) return false;
  const n = Number(m[2]);
  return n >= 1 && n <= (m[1] === 'd' ? MAX_DI : MAX_BRIDGE);
}
function actuatorIdOk(s) {
  if (typeof s !== 'string') return false;
  const m = /^a([1-9][0-9]{0,3})$/.exec(s);
  return Boolean(m) && Number(m[1]) <= MAX_ACTUATORS;
}

function validateSensor(o, intrusion) {
  const u = unknownKey(o, ['id', 'kind', 'zone', 'active_open', 'flags', 'confirm_ms', 'name']);
  if (u) return fail(`Sensörde bilinmeyen alan: ${String(u).slice(0, 24)}`);
  if (!sensorIdOk(o.id)) return fail('Sensör kimliği "d1".."d40" ya da "b1".."b16" olmalı.');
  const known = SENSOR_KINDS.includes(o.kind);
  if (!known && INTRUSION_SENSOR_KINDS.includes(o.kind)) {
    if (!intrusion) return fail("Bu pano yazılımı alarm kipini desteklemiyor; v1.2.1'e güncelleyin.", 'FIRMWARE_UNSUPPORTED', 409);
  } else if (!known) {
    return fail('Sensör türü geçersiz.');
  }
  if (intIn(o, 'zone', 0, MAX_ZONES).s !== 'ok') return fail('Sensör bölgesi 0..4 olmalı.');
  if (flagOf(o, 'active_open').s === 'bad') return fail('active_open true/false (0/1) olmalı.');
  const fl = intIn(o, 'flags', 0, 0x1f);
  if (fl.s === 'bad') return fail('Sensör bayrakları (flags) geçersiz.');
  if (fl.s === 'ok' && fl.v > 0x07 && !intrusion) {
    return fail("Bu pano yazılımı alarm kipi bayraklarını desteklemiyor; v1.2.1'e güncelleyin.", 'FIRMWARE_UNSUPPORTED', 409);
  }
  if (intIn(o, 'confirm_ms', 0, 60000).s === 'bad') return fail('Onay süresi (confirm_ms) 0..60000 olmalı.');
  if (has(o, 'name') && !nameOk(o.name, NAME_LEN)) return fail('Sensör adı en çok 19 bayt olmalı ve denetim karakteri içermemeli.');
  return null;
}

function validateActuator(o) {
  const u = unknownKey(o, ['id', 'relay', 'relay2', 'kind', 'close_mode', 'medium', 'zones', 'fb_di', 'fb_closed_active', 'fb_timeout_s', 'run_limit_s', 'exproof', 'name']);
  if (u) return fail(`Eylemcide bilinmeyen alan: ${String(u).slice(0, 24)}`);
  if (has(o, 'id') && !actuatorIdOk(o.id)) return fail('Eylemci kimliği "a1".."a16" olmalı.');
  if (intIn(o, 'relay', 1, MAX_RELAYS).s !== 'ok') return fail('Eylemci rölesi 1..40 olmalı.');
  if (!ACTUATOR_KINDS.includes(o.kind)) return fail('Eylemci türü geçersiz.');
  if (has(o, 'close_mode') && !CLOSE_MODES.includes(o.close_mode)) return fail('Kapanma kipi (close_mode) geçersiz.');
  if (has(o, 'medium') && !MEDIA.includes(o.medium)) return fail('Akışkan (medium) geçersiz.');
  if (has(o, 'zones')) {
    if (!Array.isArray(o.zones) || !o.zones.every((z) => isInt32(z) && z >= 1 && z <= MAX_ZONES)) return fail('Bölgeler 1..4 tamsayı dizisi olmalı.');
  }
  if (intIn(o, 'relay2', 0, MAX_RELAYS).s === 'bad') return fail('İkinci röle (relay2) 0..40 olmalı.');
  if (intIn(o, 'fb_di', 0, MAX_DI).s === 'bad') return fail('Geri bildirim girişi (fb_di) 0..40 olmalı.');
  if (flagOf(o, 'fb_closed_active').s === 'bad') return fail('fb_closed_active true/false (0/1) olmalı.');
  if (intIn(o, 'fb_timeout_s', 0, 65535).s === 'bad') return fail('fb_timeout_s 0..65535 olmalı.');
  if (intIn(o, 'run_limit_s', 0, 65535).s === 'bad') return fail('run_limit_s 0..65535 olmalı.');
  if (has(o, 'exproof') && typeof o.exproof !== 'boolean') return fail('exproof true/false olmalı.');
  if (has(o, 'name') && !nameOk(o.name, NAME_LEN)) return fail('Eylemci adı en çok 19 bayt olmalı ve denetim karakteri içermemeli.');
  return null;
}

function validateSetItem(what, o, intrusion) {
  if (!isObj(o)) return fail('Yama öğesi bir nesne olmalı.');
  switch (what) {
    case 'sensor':
      return validateSensor(o, intrusion);
    case 'actuator':
      return validateActuator(o);
    case 'policy': {
      const u = unknownKey(o, ['on', 'dry_hold_ms']);
      if (u) return fail(`Politikada bilinmeyen alan: ${String(u).slice(0, 24)}`);
      if (has(o, 'on') && typeof o.on !== 'boolean') return fail('Politika "on" true/false olmalı.');
      if (intIn(o, 'dry_hold_ms', 0, 2147483647).s === 'bad') return fail('dry_hold_ms negatif olmayan tamsayı olmalı.');
      if (!has(o, 'on') && !has(o, 'dry_hold_ms')) return fail('Politika yamasında "on" ya da "dry_hold_ms" olmalı.');
      return null;
    }
    case 'zone': {
      const u = unknownKey(o, ['id', 'name']);
      if (u) return fail(`Bölgede bilinmeyen alan: ${String(u).slice(0, 24)}`);
      if (intIn(o, 'id', 1, MAX_ZONES).s !== 'ok') return fail('Bölge kimliği 1..4 olmalı.');
      if (!nameOk(o.name, ZONE_NAME_LEN)) return fail('Bölge adı zorunlu; en çok 15 bayt, denetim karakteri içermemeli.');
      return null;
    }
    case 'light': {
      const u = unknownKey(o, ['relay', 'dimmable', 'src', 'addr', 'ch']);
      if (u) return fail(`Işık seçeneğinde bilinmeyen alan: ${String(u).slice(0, 24)}`);
      if (intIn(o, 'relay', 1, MAX_RELAYS).s !== 'ok') return fail('Işık rölesi 1..40 olmalı.');
      if (flagOf(o, 'dimmable').s === 'bad') return fail('dimmable true/false (0/1) olmalı.');
      if (intIn(o, 'src', 0, 2).s === 'bad') return fail('src 0..2 olmalı.');
      if (intIn(o, 'addr', 0, 247).s === 'bad') return fail('addr 0..247 olmalı.');
      if (intIn(o, 'ch', 0, 255).s === 'bad') return fail('ch 0..255 olmalı.');
      return null;
    }
    case 'intrusion': {
      if (!intrusion) return fail("Bu pano yazılımı alarm kipini desteklemiyor; v1.2.1'e güncelleyin.", 'FIRMWARE_UNSUPPORTED', 409);
      const u = unknownKey(o, ['exit_s', 'entry_s']);
      if (u) return fail(`Alarm kipi ayarında bilinmeyen alan: ${String(u).slice(0, 24)}`);
      if (intIn(o, 'exit_s', 0, 255).s === 'bad' || intIn(o, 'entry_s', 0, 255).s === 'bad') return fail('Gecikmeler 0..255 sn olmalı (0 = varsayılan).');
      if (!has(o, 'exit_s') && !has(o, 'entry_s')) return fail('Alarm kipi ayarında "exit_s" ya da "entry_s" olmalı.');
      return null;
    }
    default:
      return fail('Bilinmeyen yama öğesi.');
  }
}

function targetOf(what, value) {
  if (what === 'sensor' || what === 'actuator') return typeof value === 'string' ? value : value && typeof value.id === 'string' ? value.id : null;
  if (what === 'zone') return value && Number.isInteger(value.id) ? String(value.id) : null;
  if (what === 'light') return value && Number.isInteger(value.relay) ? String(value.relay) : null;
  return null;
}

/**
 * REST govdesi -> dogrulanmis yama.
 * @param {*} body
 * @param {{caps?: string[]}} [opts]
 * @returns {{ok:true, baseRev:number, id:string|undefined, patch:object, op:'set'|'del', item:string, target:string|null}
 *          | {ok:false, status:number, code:string, message:string}}
 */
function validatePatchRequest(body, { caps = [] } = {}) {
  if (!isObj(body)) return fail('Gövde bir JSON nesnesi olmalı.');
  const u = unknownKey(body, ['base_rev', 'set', 'del', 'id']);
  if (u) return fail(`Bilinmeyen alan: ${String(u).slice(0, 24)}`);
  if (!isU32(body.base_rev)) return fail('"base_rev" zorunlu, negatif olmayan tamsayı olmalı.');
  if (has(body, 'id') && (typeof body.id !== 'string' || !COMMAND_ID_RE.test(body.id))) {
    return fail('Komut kimliği (id) en fazla 24 karakterlik harf, rakam, "_", ".", ":" veya "-" olmalı.');
  }
  if (has(body, 'set') === has(body, 'del')) return fail('Gövdede "set" ya da "del" alanlarından tam olarak biri olmalı.');
  const op = has(body, 'set') ? 'set' : 'del';
  const inner = body[op];
  if (!isObj(inner) || Object.keys(inner).length !== 1) return fail(`"${op}" tek bir öğe içermeli.`);
  const what = Object.keys(inner)[0];
  const value = inner[what];
  const intrusion = Array.isArray(caps) && caps.includes('intrusion');
  if (op === 'del') {
    if (!DEL_ITEMS.includes(what)) return fail('Yalnız sensör ya da eylemci silinebilir.');
    if (what === 'sensor' ? !sensorIdOk(value) : !actuatorIdOk(value)) return fail('Silinecek öğe kimliği geçersiz.');
  } else {
    if (!SET_ITEMS.includes(what)) return fail('Bilinmeyen yama öğesi.');
    const err = validateSetItem(what, value, intrusion);
    if (err) return err;
  }
  return {
    ok: true,
    baseRev: body.base_rev,
    id: has(body, 'id') ? body.id : undefined,
    patch: { [op]: { [what]: clone(value) } },
    op,
    item: what,
    target: targetOf(what, value),
  };
}

/** Panoya giden sys yuku (ev/{t}/sys). */
function buildSysPayload({ uid, id, baseRev, patch }) {
  return { cmd: 'cfg_patch', module: 'safety', uid, id, base_rev: baseRev, ...clone(patch) };
}

function sysPayloadBytes(payload) {
  return Buffer.byteLength(JSON.stringify(payload), 'utf8');
}

// ------------------------------------------------------------------------------
// Kopyaya uygulama (gevsetme siniflandirmasi; firmware applyEdit + parseCfgEdit varsayilanlari)
// ------------------------------------------------------------------------------
// intrusion: kopya firmware 1.2.1+ panonun (cfg_dump'ta "intrusion" var); varsayilan bayraklar SensorTypes.h defaultFlags ile ayni.
function defaultSensorFlags(kind, intrusion) {
  let f = SF_REACT;
  if (kind === 'gas') f |= SF_FAULT_CLOSE;
  if (intrusion && kind === 'door') f |= SF_ENTRY;
  if (intrusion && kind === 'motion') f |= SF_AWAY_ONLY;
  return f;
}

function sensorDefaults(o, intrusion = false) {
  const hazard = o.kind === 'water' ? 1000 : o.kind === 'gas' || o.kind === 'smoke' ? 300 : 0;
  return {
    id: o.id,
    kind: o.kind,
    zone: o.zone,
    active_open: has(o, 'active_open') ? (o.active_open === true || o.active_open === 1 ? 1 : 0) : 0,
    flags: has(o, 'flags') ? o.flags : defaultSensorFlags(o.kind, intrusion),
    confirm_ms: has(o, 'confirm_ms') ? o.confirm_ms : hazard,
    name: has(o, 'name') ? o.name : '',
  };
}

function actuatorDefaults(o, id) {
  const closeMode = has(o, 'close_mode') ? o.close_mode : 'energize';
  let runLimit = 0;
  if (has(o, 'run_limit_s')) runLimit = o.run_limit_s;
  else if (o.kind === 'siren') runLimit = SIREN_RUN_DEFAULT_S;
  else if (o.kind === 'valve' && closeMode === 'pulse') runLimit = PULSE_DEFAULT_S;
  const out = {
    id,
    relay: o.relay,
    kind: o.kind,
    close_mode: closeMode,
    medium: has(o, 'medium') ? o.medium : 'none',
    zones: has(o, 'zones') ? [...new Set(o.zones)].sort((a, b) => a - b) : [],
    fb_di: has(o, 'fb_di') ? o.fb_di : 0,
    fb_closed_active: has(o, 'fb_closed_active') ? (o.fb_closed_active === true || o.fb_closed_active === 1 ? 1 : 0) : 1,
    fb_timeout_s: has(o, 'fb_timeout_s') ? o.fb_timeout_s : FB_TIMEOUT_DEFAULT_S,
    run_limit_s: runLimit,
    exproof: o.exproof === true,
    name: has(o, 'name') ? o.name : '',
  };
  if (o.kind === 'valve' && closeMode === 'pulse') out.relay2 = has(o, 'relay2') ? o.relay2 : 0;
  return out;
}

function renumber(actuators) {
  return actuators.map((a, i) => ({ ...a, id: `a${i + 1}` }));
}

/**
 * Dogrulanmis yamayi yapilandirma kopyasina (JSON) uygular; yeni belge doner (girdi degismez). Bulunamayan oge (silme /
 * olmayan eylemci kimligi) belgeyi degistirmez (firmware NOT_FOUND -> cfg_invalid; karar panoda).
 */
function applyPatch(doc, patch) {
  const out = clone(isObj(doc) ? doc : {});
  out.sensors = Array.isArray(out.sensors) ? out.sensors.filter(isObj) : [];
  out.actuators = Array.isArray(out.actuators) ? out.actuators.filter(isObj) : [];
  out.policy = isObj(out.policy) ? out.policy : {};
  if (!isObj(patch)) return out;
  if (isObj(patch.del)) {
    if (typeof patch.del.sensor === 'string') out.sensors = out.sensors.filter((s) => s.id !== patch.del.sensor);
    if (typeof patch.del.actuator === 'string') out.actuators = renumber(out.actuators.filter((a) => a.id !== patch.del.actuator));
    return out;
  }
  const set = isObj(patch.set) ? patch.set : {};
  if (isObj(set.sensor)) {
    const s = sensorDefaults(set.sensor, isObj(out.intrusion));
    const i = out.sensors.findIndex((x) => x.id === s.id);
    if (i >= 0) out.sensors[i] = s;
    else out.sensors.push(s);
  } else if (isObj(set.actuator)) {
    const id = typeof set.actuator.id === 'string' ? set.actuator.id : null;
    const i = id ? out.actuators.findIndex((x) => x.id === id) : -1;
    if (i >= 0) out.actuators[i] = actuatorDefaults(set.actuator, id);
    else if (!id || id === `a${out.actuators.length + 1}`) out.actuators.push(actuatorDefaults(set.actuator, `a${out.actuators.length + 1}`));
  } else if (isObj(set.policy)) {
    if (has(set.policy, 'on')) out.policy.on = set.policy.on;
    if (has(set.policy, 'dry_hold_ms')) out.policy.dry_hold_ms = set.policy.dry_hold_ms;
  } else if (isObj(set.zone)) {
    const zones = Array.isArray(out.zones) ? out.zones.filter(isObj) : [];
    const i = zones.findIndex((z) => z.id === set.zone.id);
    if (i >= 0) zones[i] = { id: set.zone.id, name: set.zone.name };
    else zones.push({ id: set.zone.id, name: set.zone.name });
    out.zones = zones;
  } else if (isObj(set.light)) {
    const lights = Array.isArray(out.lights) ? out.lights.filter((l) => isObj(l) && l.relay !== set.light.relay) : [];
    lights.push(clone(set.light));
    out.lights = lights;
  } else if (isObj(set.intrusion)) {
    out.intrusion = { ...(isObj(out.intrusion) ? out.intrusion : {}), ...clone(set.intrusion) };
  }
  return out;
}

// ------------------------------------------------------------------------------
// Bekleyen kuyruk
// ------------------------------------------------------------------------------
function validItem(it) {
  return (
    isObj(it) && typeof it.id === 'string' && COMMAND_ID_RE.test(it.id) && isU32(it.base_rev) && isObj(it.patch) &&
    (isObj(it.patch.set) || isObj(it.patch.del)) && typeof it.at === 'string'
  );
}

/** device_configs.pending -> {v:1, items[], inflight|null}; bozuk/bilinmeyen surum bos kuyruk sayilir (asla firlatmaz). */
function parsePending(raw) {
  const out = { v: 1, items: [], inflight: null };
  if (!isObj(raw) || raw.v !== 1) return out;
  if (Array.isArray(raw.items)) out.items = raw.items.filter(validItem).slice(0, MAX_PENDING_ITEMS).map(clone);
  if (isObj(raw.inflight) && typeof raw.inflight.id === 'string' && typeof raw.inflight.at === 'string') out.inflight = clone(raw.inflight);
  return out;
}

/** Kuyruk bos ve ucusta yama yoksa NULL yazilir. */
function serializePending(q) {
  if (!q || ((!q.items || q.items.length === 0) && !q.inflight)) return null;
  const out = { v: 1, items: q.items || [] };
  if (q.inflight) out.inflight = q.inflight;
  return out;
}

function inflightActive(q, nowMs) {
  if (!q || !q.inflight) return false;
  const at = Date.parse(q.inflight.at);
  return Number.isFinite(at) && nowMs - at < INFLIGHT_TTL_MS;
}

function isExpired(item, nowMs) {
  const at = Date.parse(item && item.at);
  return !Number.isFinite(at) || nowMs - at > PENDING_TTL_MS;
}

/** Sonraki yamanin base_rev'i: kuyruk varsa son oge + 1, yoksa panonun son bildirdigi rev (bilinmiyorsa null). */
function nextBaseRev(q, stateRev) {
  const items = (q && q.items) || [];
  if (items.length > 0) return items[items.length - 1].base_rev + 1;
  return Number.isInteger(stateRev) ? stateRev : null;
}

/**
 * guvenlik-4: cevrimdisi kuyruga eklenecek yama, kopya + kuyruktaki yamalar SIRAYLA uygulanmis zincire gore anlamli mi?
 * Eylemci silmede firmware kalanlari yeniden numaralar (a3 -> a2): zincirdeki "a2" kopyadaki "a2" olmayabilir. Kimlik
 * izlenir; belirsiz / bulunamayan hedef ve ayni roleye ikinci kimliksiz ekleme reddedilir (yanlis vana silinmesin).
 * @returns {null|'missing_target'|'renumbered'|'duplicate_relay'}
 */
function chainConflict(body, items, patch) {
  const doc = isObj(body) ? body : {};
  // eylemci izleri: {id (zincirdeki), orig (kopyadaki kimlik; zincirde eklendiyse null), relay}
  let acts = (Array.isArray(doc.actuators) ? doc.actuators.filter(isObj) : []).map((a) => ({ id: a.id, orig: a.id, relay: a.relay }));
  const sensors = new Set((Array.isArray(doc.sensors) ? doc.sensors.filter(isObj) : []).map((x) => x.id));
  const renum = () => {
    acts = acts.map((a, i) => ({ ...a, id: `a${i + 1}` }));
  };
  const step = (p) => {
    if (!isObj(p)) return;
    if (isObj(p.del)) {
      if (typeof p.del.sensor === 'string') sensors.delete(p.del.sensor);
      if (typeof p.del.actuator === 'string') {
        acts = acts.filter((a) => a.id !== p.del.actuator);
        renum();
      }
      return;
    }
    const set = isObj(p.set) ? p.set : {};
    if (isObj(set.sensor) && typeof set.sensor.id === 'string') sensors.add(set.sensor.id);
    if (isObj(set.actuator)) {
      const id = typeof set.actuator.id === 'string' ? set.actuator.id : null;
      const i = id ? acts.findIndex((a) => a.id === id) : -1;
      if (i >= 0) acts[i] = { ...acts[i], relay: set.actuator.relay };
      else if (!id || id === `a${acts.length + 1}`) acts.push({ id: `a${acts.length + 1}`, orig: null, relay: set.actuator.relay });
    }
  };
  for (const it of items || []) step(it && it.patch);

  if (!isObj(patch)) return null;
  if (isObj(patch.del)) {
    if (typeof patch.del.sensor === 'string' && !sensors.has(patch.del.sensor)) return 'missing_target';
    if (typeof patch.del.actuator === 'string') {
      const a = acts.find((x) => x.id === patch.del.actuator);
      if (!a) return 'missing_target';
      if (a.orig !== patch.del.actuator) return 'renumbered';
    }
    return null;
  }
  const set = isObj(patch.set) ? patch.set : {};
  if (isObj(set.actuator)) {
    const id = typeof set.actuator.id === 'string' ? set.actuator.id : null;
    if (id) {
      const a = acts.find((x) => x.id === id);
      if (a && a.orig !== id) return 'renumbered';
      return null;
    }
    // kimliksiz ekleme: ayni role zincirde (kuyruktaki eklemelerle) zaten eklendiyse ikinci kez eklenmez
    if (acts.some((a) => a.orig === null && a.relay === set.actuator.relay)) return 'duplicate_relay';
  }
  return null;
}

/** GET yanitindaki ozet: deger ve AD icermez. */
function pendingSummary(q) {
  return ((q && q.items) || []).map((it) => {
    const op = isObj(it.patch.set) ? 'set' : 'del';
    const inner = it.patch[op];
    const item = Object.keys(inner)[0] || null;
    return { id: it.id, op, item, target: targetOf(item, inner[item]), at: it.at, role: it.role || null, loosening: it.loosening === true };
  });
}

module.exports = {
  validatePatchRequest,
  buildSysPayload,
  sysPayloadBytes,
  applyPatch,
  chainConflict,
  parsePending,
  serializePending,
  inflightActive,
  isExpired,
  nextBaseRev,
  pendingSummary,
  targetOf,
  MAX_SYS_BYTES,
  MAX_PENDING_ITEMS,
  PENDING_TTL_MS,
  INFLIGHT_TTL_MS,
};
