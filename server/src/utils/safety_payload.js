'use strict';

// ==============================================================================
// AHBU Akilli Ev - Guvenlik modulu yuk ayristirici (state v:3 ekleri + ev/{t}/event)   [CONTRACTS §2.6]
// ==============================================================================
//
// Tasarim: docs/superpowers/specs/2026-10-06-guvenlik-iklim-senaryo-mimarisi-design.md §3.1-§3.4.
// SAF modul (G/C yok): kopru (mqtt_bridge.js) ve alarm servisi (services/alarm_service.js) kullanir.
//
// state v:3 (parseStateSafety)
//   - v:3, v:2'nin KATI ust kumesidir; v:2 alanlarini bu modul OKUMAZ (kopru eskisi gibi isler).
//   - `caps` yoksa pano "guvenlik desteklemiyor" sayilir (eski firmware): ozet null.
//   - Bozuk oge SESSIZCE DUZELTILMEZ: atlanir ve `skipped` artar; modul hicbir zaman firlatmaz.
//   - Sinirlar [D6]: sensors <= 56, actuators <= 16, safety.zones <= 4, caps <= 8 (her biri <= 12 karakter).
//   - Bilinmeyen eylemci/sensor turu `generic` olur (oge gorunur kalir; eylemci = guvenli taraf).
//   - Adlar state'te YOKTUR [B12]; ozet yalniz kimlik ve durum tasir (devices.safety_state'e yazilir).
//
// ev/{t}/event (validateEventPayload)
//   - KATI: kok nesne, v >= 1, `uid` ve `eid` (`<bn>-<n>`: bn 8 hex, n <= 5 hane) zorunlu.
//   - Bilinmeyen (ama bicimli) `type` -> { unknown: true }: kopru gunluk + ack yapar, islem yapmaz.
//   - Alarm kimligi: `alarm_raised` icin olayin kendi eid'si; diger alarm olaylarinda istege bagli `aid` alani
//     (yoksa null: alarm servisi bolgenin acik alarmini kullanir).
//   - `cfg_dump` olay DEGILDIR [Y6]: eid tasimaz, onaylanmaz; ayri bicimde doner (cfgDump: true). Firmware v1.2.0 oge
//     dizilerini KOKTE yazar (`policy`, `zones`, `lights` yalniz 1. parcada; `sensors`, `actuators` her parcada; CONTRACTS
//     §2.6 "Gerceklesen ayrintilar"); eski taslak bicimi `body` nesnesi de kabul edilir. Parcalar mergeCfgDumpParts ile
//     TEK belgeye birlestirilir (GET /api/safety/config ile ayni bicim, rev/crc haric).

const UID_RE = /^[A-Za-z0-9][A-Za-z0-9_.-]{2,63}$/; // mqtt_bridge UID_RE ile ayni
const EID_RE = /^[0-9A-Fa-f]{8}-[0-9]{1,5}$/;
const BN_RE = /^[0-9A-Fa-f]{8}$/;
const CRC_RE = /^[0-9A-Fa-f]{8}$/;
const TOKEN_RE = /^[a-z][a-z0-9_]{0,23}$/;
const CAP_RE = /^[a-z][a-z0-9_]{0,11}$/;
const SENSOR_ID_RE = /^(d([1-9]|[1-3][0-9]|40)|b([1-9]|1[0-6]))$/;
const ACTUATOR_ID_RE = /^a([1-9]|1[0-6])$/;
const REJ_ID_RE = /^[A-Za-z0-9_.:-]{1,24}$/;

const MAX_CAPS = 8;
const MAX_SENSORS = 56;
const MAX_ACTUATORS = 16;
const MAX_ZONES = 4;
const MAX_SRCS = 8;
const MAX_ACTIONS = 16;
const MAX_RELAY = 40;
const U32_MAX = 0xffffffff;
const SCAN_LIMIT = 64; // mqtt_bridge MAX_ARRAY_ITEMS

const ZONE_STATES = Object.freeze(['normal', 'latched', 'fault', 'test']);
const SENSOR_KINDS = Object.freeze(['water', 'gas', 'smoke', 'door', 'window', 'motion', 'generic']);
const ACTUATOR_KINDS = Object.freeze(['valve', 'siren', 'fan', 'generic']);
const VALVE_POS = Object.freeze(['closed', 'closing', 'open', 'opening', 'cmd_closed', 'cmd_open', 'unknown']);
const MEDIA = Object.freeze(['water', 'gas']);
const SENSOR_SRCS = Object.freeze(['di', 'bridge']);
/** Yerel kumanda rolleri (firmware sensors[] listesinde de yayinlar; `active` = ham basili seviye). Tehlike sensoru DEGIL. */
const CONTROL_KINDS = Object.freeze(['alarm_ack', 'valve_close', 'gas_reset']);
/** cfg_dump parcasinin firmware'deki kok anahtarlari. */
const CFG_DUMP_KEYS = Object.freeze(['policy', 'zones', 'lights', 'sensors', 'actuators']);

/** Ilk modulun olay turleri (tasarim §3.4). */
const EVENT_TYPES = Object.freeze([
  'alarm_raised',
  'valve_fault',
  'valve_fault_cleared',
  'alarm_silenced',
  'alarm_cleared',
  'test_result',
  'sensor_fault',
  'sensor_fault_cleared',
  'actuator_fault',
  'safe_mode',
  'nvs_fail',
  'policy_changed',
  'actuator_changed',
  'cfg_conflict',
]);
/** Bolge (zone) ZORUNLU olan turler. */
const ZONE_EVENT_TYPES = Object.freeze(['alarm_raised', 'valve_fault', 'valve_fault_cleared', 'alarm_silenced', 'alarm_cleared', 'test_result']);

function isObj(v) {
  return v !== null && typeof v === 'object' && !Array.isArray(v);
}
function isInt(v, min, max) {
  return typeof v === 'number' && Number.isInteger(v) && v >= min && v <= max;
}
function tokenOr(v, list, fallback) {
  return typeof v === 'string' && list.includes(v) ? v : fallback;
}
function boolOrNull(v) {
  return typeof v === 'boolean' ? v : null;
}
function u32OrNull(v) {
  return isInt(v, 0, U32_MAX) ? v : null;
}

/** `last_rej` {id <= 24, code <= 24}; bozuksa null. */
function parseLastRej(raw) {
  if (!isObj(raw)) return null;
  if (typeof raw.id !== 'string' || !REJ_ID_RE.test(raw.id)) return null;
  if (typeof raw.code !== 'string' || !TOKEN_RE.test(raw.code)) return null;
  return { id: raw.id, code: raw.code };
}

function parseCaps(raw, count) {
  if (raw === undefined) return null;
  if (!Array.isArray(raw)) {
    count();
    return null;
  }
  const out = [];
  for (const c of raw.slice(0, MAX_CAPS)) {
    if (typeof c === 'string' && CAP_RE.test(c)) {
      if (!out.includes(c)) out.push(c);
    } else {
      count();
    }
  }
  if (raw.length > MAX_CAPS) count(raw.length - MAX_CAPS);
  return out;
}

/** Dizi: ilk `max` ogeyi `fn` ile donusturur; null donen ve sinir disi ogeler sayilir. */
function parseList(raw, max, fn, count) {
  if (raw === undefined) return [];
  if (!Array.isArray(raw)) {
    count();
    return [];
  }
  // En cok SCAN_LIMIT oge taranir (bellek/CPU korumasi, koprunun MAX_ARRAY_ITEMS'i); gecerlilerden ilk `max` alinir.
  const scan = Math.max(max, SCAN_LIMIT);
  const out = [];
  const seen = new Set();
  for (const item of raw.slice(0, scan)) {
    const v = out.length < max ? fn(item) : null;
    if (v === null || seen.has(v.id)) {
      count();
      continue;
    }
    seen.add(v.id);
    out.push(v);
  }
  if (raw.length > scan) count(raw.length - scan);
  return out;
}

function parseZone(z) {
  if (!isObj(z) || !isInt(z.id, 1, MAX_ZONES) || typeof z.st !== 'string' || !ZONE_STATES.includes(z.st)) return null;
  const srcs = Array.isArray(z.srcs) ? z.srcs.filter((s) => typeof s === 'string' && SENSOR_ID_RE.test(s)).slice(0, MAX_SRCS) : [];
  return {
    id: z.id,
    st: z.st,
    kind: tokenOr(z.kind, SENSOR_KINDS, null),
    aid: typeof z.aid === 'string' && EID_RE.test(z.aid) ? z.aid.toLowerCase() : null,
    silenced: z.silenced === true,
    since: u32OrNull(z.since),
    since_up: u32OrNull(z.since_up),
    srcs,
  };
}

function parseActuator(a) {
  if (!isObj(a) || typeof a.id !== 'string' || !ACTUATOR_ID_RE.test(a.id) || !isInt(a.relay, 1, MAX_RELAY)) return null;
  const kind = typeof a.kind === 'string' && ACTUATOR_KINDS.includes(a.kind) ? a.kind : 'generic';
  const zones = Array.isArray(a.zones) ? [...new Set(a.zones.filter((z) => isInt(z, 1, MAX_ZONES)))].sort((x, y) => x - y) : [];
  return {
    id: a.id,
    relay: a.relay,
    kind,
    medium: kind === 'valve' ? tokenOr(a.medium, MEDIA, null) : null,
    zones,
    pos: kind === 'valve' ? tokenOr(a.pos, VALVE_POS, 'unknown') : null,
    on: kind === 'valve' ? null : boolOrNull(a.on),
    fb: boolOrNull(a.fb),
    fault: a.fault === true,
  };
}

function parseSensor(s) {
  if (!isObj(s) || typeof s.id !== 'string' || !SENSOR_ID_RE.test(s.id)) return null;
  const src = s.id[0] === 'd' ? 'di' : 'bridge';
  if (s.src !== undefined && s.src !== src) return null; // kimlik ve kaynak celisiyor: supheli
  return {
    id: s.id,
    src: tokenOr(s.src, SENSOR_SRCS, src),
    kind: typeof s.kind === 'string' && (SENSOR_KINDS.includes(s.kind) || CONTROL_KINDS.includes(s.kind)) ? s.kind : 'generic',
    zone: isInt(s.zone, 1, MAX_ZONES) ? s.zone : null,
    active: s.active === true,
    ok: s.ok === true, // ok yoksa / bozuksa GUVENILMEZ sayilir [Y-3]
  };
}

/**
 * state yukunden guvenlik ekleri. ASLA firlatmaz.
 * @returns {{caps:string[]|null, supported:boolean, lastRej:{id,code}|null, summary:object|null, skipped:number}}
 *   summary yalniz caps varsa (v:3) doner; devices.safety_state'e yazilir.
 */
function parseStateSafety(obj) {
  let skipped = 0;
  const count = (n = 1) => {
    skipped += n;
  };
  const out = { caps: null, supported: false, lastRej: null, summary: null, skipped: 0 };
  if (!isObj(obj)) return out;

  out.caps = parseCaps(obj.caps, count);
  out.lastRej = obj.last_rej === undefined ? null : parseLastRej(obj.last_rej);
  if (obj.last_rej !== undefined && out.lastRej === null) count();
  if (out.caps === null) {
    out.skipped = skipped;
    return out;
  }
  out.supported = out.caps.includes('safety');

  const safety = isObj(obj.safety) ? obj.safety : null;
  if (obj.safety !== undefined && safety === null) count();
  const cfgRaw = isObj(obj.cfg) && isObj(obj.cfg.safety) ? obj.cfg.safety : null;
  let cfg = null;
  if (cfgRaw) {
    if (isInt(cfgRaw.rev, 0, U32_MAX) && typeof cfgRaw.crc === 'string' && CRC_RE.test(cfgRaw.crc)) {
      cfg = { rev: cfgRaw.rev, crc: cfgRaw.crc.toLowerCase() };
    } else {
      count();
    }
  }

  // zones[] yalniz normal OLMAYAN bolgeleri listeler (sozlesme); listede olmayan bolgenin "normal" sayilabilmesi icin liste TAM olmali.
  // Dizi degilse ya da bir oge dusurulduyse (bilinmeyen durum/ileri surum, gecersiz oge, sinir asimi) zones_complete=false: alarm
  // uzlastirmasi listede olmayan bolgeye dokunmaz (inceleme turu 2 RV2-1). safety yoksa bolge bilgisi de yoktur.
  let zonesDropped = 0;
  const zones = safety
    ? parseList(safety.zones, MAX_ZONES, parseZone, (n = 1) => {
      zonesDropped += n;
      count(n);
    })
    : [];
  out.summary = {
    v: 1,
    state_v: isInt(obj.v, 0, 255) ? obj.v : null,
    present: safety !== null,
    policy: safety ? tokenOr(safety.policy, ['on', 'off'], null) : null,
    mode: safety ? tokenOr(safety.mode, ['normal', 'safe'], null) : null,
    boot: u32OrNull(obj.boot),
    bn: typeof obj.bn === 'string' && BN_RE.test(obj.bn) ? obj.bn.toLowerCase() : null,
    time_ok: obj.time_ok === true,
    cfg,
    last_rej: out.lastRej,
    zones,
    zones_complete: safety !== null && zonesDropped === 0,
    actuators: parseList(obj.actuators, MAX_ACTUATORS, parseActuator, count),
    sensors: parseList(obj.sensors, MAX_SENSORS, parseSensor, count),
  };
  // Bozuk aid'li bolge yine gorunur (durum bilgisi degerli) ama sayilir
  if (safety && Array.isArray(safety.zones)) {
    for (const z of safety.zones.slice(0, SCAN_LIMIT)) {
      if (isObj(z) && z.aid !== undefined && z.aid !== null && !(typeof z.aid === 'string' && EID_RE.test(z.aid))) count();
    }
  }
  out.skipped = skipped;
  return out;
}

/**
 * ev/{t}/event yuku. KATI.
 * @returns {{ok:false, reason:string} | {ok:true, value:object}}
 *   value.cfgDump === true ise yapilandirma dokumu parcasi (olay hattina GIRMEZ).
 */
function validateEventPayload(obj) {
  if (!isObj(obj)) return { ok: false, reason: 'kok nesne degil' };
  if (!isInt(obj.v, 1, 255)) return { ok: false, reason: 'v' };
  if (typeof obj.uid !== 'string' || !UID_RE.test(obj.uid.trim())) return { ok: false, reason: 'uid' };
  const uid = obj.uid.trim().toUpperCase();
  if (typeof obj.type !== 'string' || !TOKEN_RE.test(obj.type)) return { ok: false, reason: 'type' };

  if (obj.type === 'cfg_dump') {
    if (typeof obj.module !== 'string' || !TOKEN_RE.test(obj.module) || obj.module.length > 16) return { ok: false, reason: 'module' };
    if (!isInt(obj.rev, 0, U32_MAX)) return { ok: false, reason: 'rev' };
    if (typeof obj.crc !== 'string' || !CRC_RE.test(obj.crc)) return { ok: false, reason: 'crc' };
    if (!isInt(obj.parts, 1, 16) || !isInt(obj.part, 1, obj.parts)) return { ok: false, reason: 'part' };
    let body;
    if (obj.body !== undefined) {
      if (!isObj(obj.body)) return { ok: false, reason: 'body' };
      body = obj.body;
    } else {
      // Firmware bicimi: oge dizileri kokte. sensors/actuators her parcada ZORUNLU (bos dizi olabilir).
      if (!Array.isArray(obj.sensors) || !Array.isArray(obj.actuators)) return { ok: false, reason: 'body' };
      body = {};
      for (const k of CFG_DUMP_KEYS) if (obj[k] !== undefined) body[k] = obj[k];
      if (body.policy !== undefined && !isObj(body.policy)) return { ok: false, reason: 'body' };
      for (const k of ['zones', 'lights']) if (body[k] !== undefined && !Array.isArray(body[k])) return { ok: false, reason: 'body' };
    }
    return {
      ok: true,
      value: { cfgDump: true, uid, module: obj.module, rev: obj.rev, crc: obj.crc.toLowerCase(), part: obj.part, parts: obj.parts, body },
    };
  }

  if (typeof obj.eid !== 'string' || !EID_RE.test(obj.eid)) return { ok: false, reason: 'eid' };
  const eid = obj.eid.toLowerCase();
  const known = EVENT_TYPES.includes(obj.type);
  const needsZone = ZONE_EVENT_TYPES.includes(obj.type);
  if (obj.zone !== undefined && !isInt(obj.zone, 1, MAX_ZONES)) return { ok: false, reason: 'zone' };
  if (needsZone && obj.zone === undefined) return { ok: false, reason: 'zone' };
  if (obj.aid !== undefined && obj.aid !== null && !(typeof obj.aid === 'string' && EID_RE.test(obj.aid))) {
    return { ok: false, reason: 'aid' };
  }

  const srcs = Array.isArray(obj.srcs)
    ? obj.srcs.filter((s) => typeof s === 'string' && SENSOR_ID_RE.test(s)).slice(0, MAX_SRCS)
    : [];
  const actions = Array.isArray(obj.actions)
    ? obj.actions
      .filter((a) => isObj(a) && typeof a.a === 'string' && ACTUATOR_ID_RE.test(a.a) && typeof a.do === 'string' && TOKEN_RE.test(a.do))
      .slice(0, MAX_ACTIONS)
      .map((a) => ({ a: a.a, do: a.do }))
    : [];

  let aid = null;
  if (obj.type === 'alarm_raised') aid = eid;
  else if (typeof obj.aid === 'string') aid = obj.aid.toLowerCase();

  const value = {
    cfgDump: false,
    unknown: !known,
    uid,
    eid,
    type: obj.type,
    aid,
    zone: isInt(obj.zone, 1, MAX_ZONES) ? obj.zone : null,
    kind: tokenOr(obj.kind, SENSOR_KINDS, obj.kind === undefined ? null : 'generic'),
    srcs,
    actions,
    bn: typeof obj.bn === 'string' && BN_RE.test(obj.bn) ? obj.bn.toLowerCase() : null,
    boot: u32OrNull(obj.boot),
    at: u32OrNull(obj.at),
    at_up: u32OrNull(obj.at_up),
    policy: tokenOr(obj.policy, ['on', 'off'], null),
    via: typeof obj.via === 'string' && TOKEN_RE.test(obj.via) ? obj.via : null,
    reason: typeof obj.reason === 'string' && TOKEN_RE.test(obj.reason) ? obj.reason : null,
    ok: boolOrNull(obj.ok),
    fb_ms: u32OrNull(obj.fb_ms),
    rev: u32OrNull(obj.rev),
    crc: typeof obj.crc === 'string' && CRC_RE.test(obj.crc) ? obj.crc.toLowerCase() : null,
  };
  return { ok: true, value };
}

/**
 * cfg_dump parcalarini (parca sirasiyla) TEK yapilandirma belgesine birlestirir: politika/bolgeler/isiklar ilk bulunan
 * parcadan, sensor ve eylemci ogeleri sirayla eklenir (sinirlar: sensor 56, eylemci 16, bolge 4, isik 40). Eski kayit
 * bicimi `{parts:[...]}` de ayni yoldan duzlestirilir. ASLA firlatmaz.
 * @returns {{policy:object|null, zones:object[], lights:object[], sensors:object[], actuators:object[]}}
 */
function mergeCfgDumpParts(bodies) {
  const out = { policy: null, zones: [], lights: [], sensors: [], actuators: [] };
  const list = [];
  for (const b of Array.isArray(bodies) ? bodies : []) {
    if (isObj(b) && Array.isArray(b.parts)) list.push(...b.parts);
    else list.push(b);
  }
  for (const b of list) {
    if (!isObj(b)) continue;
    if (out.policy === null && isObj(b.policy)) out.policy = b.policy;
    if (out.zones.length === 0 && Array.isArray(b.zones)) out.zones = b.zones.filter(isObj).slice(0, MAX_ZONES);
    if (out.lights.length === 0 && Array.isArray(b.lights)) out.lights = b.lights.filter(isObj).slice(0, MAX_RELAY);
    if (Array.isArray(b.sensors)) out.sensors.push(...b.sensors.filter(isObj));
    if (Array.isArray(b.actuators)) out.actuators.push(...b.actuators.filter(isObj));
  }
  out.sensors = out.sensors.slice(0, MAX_SENSORS);
  out.actuators = out.actuators.slice(0, MAX_ACTUATORS);
  return out;
}

/** devices.safety_state ozetinden hafif kopya: yalniz bilinen alanlar (JSONB'ye yazilacak). */
function summaryForStorage(summary) {
  return summary ? JSON.parse(JSON.stringify(summary)) : null;
}

module.exports = {
  parseStateSafety,
  validateEventPayload,
  parseLastRej,
  summaryForStorage,
  mergeCfgDumpParts,
  EVENT_TYPES,
  CONTROL_KINDS,
  ZONE_EVENT_TYPES,
  ZONE_STATES,
  SENSOR_KINDS,
  ACTUATOR_KINDS,
  VALVE_POS,
  EID_RE,
  limits: Object.freeze({ MAX_CAPS, MAX_SENSORS, MAX_ACTUATORS, MAX_ZONES, MAX_SRCS, MAX_ACTIONS }),
};
