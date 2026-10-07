'use strict';

// ==============================================================================
// AHBU Akilli Ev - Guvenlik yapilandirmasi "gevsetme" siniflandirmasi (firmware isLoosening portu)   [CONTRACTS §2.6]
// ==============================================================================
//
// Tasarim: docs/superpowers/specs/2026-10-06-guvenlik-iklim-senaryo-mimarisi-design.md "Faz 2 tasarimi" F2.D.4 (karar 7.2b-7).
// Gevsetmenin TANIMI firmware'dedir (src/safety/SafetyCfgEdit.h isLoosening); isLoosening portu YALNIZ denetim kaydi ve arayuz
// bilgisi icindir, yetki karari DEGILDIR (bulutta owner/servis rolleri gevsetebilir, LAN'da firmware reddeder).
// Faz 2 incelemesi (G-1): isGasRelease ve isIntrusionLoosening ise bulut yolunun YETKI kararina girer (gaz vanasi uzaktan acilabilir
// kilinamaz; kurulu kipte hirsiz alarmi zayiflatilamaz). Firmware ayni siniflari VIA_CLOUD'da yine reddeder (asil karar panoda).
// Girdi: panonun GET /api/safety/config / cfg_dump JSON bicimi ({policy, sensors[], actuators[]}; adlar yok sayilir).
// Firmware ile ayrismamasi ortak vektor dosyasiyla denetlenir: tools/qa_stack/sim/fw/fixtures/loosening_vectors.json
// (firmware JS portu uretir; server/test/safety/safety_cfg_loosen.test.js okur). SAF modul, asla firlatmaz.

const SF_REACT = 0x01;
const SF_FAULT_CLOSE = 0x04;
const SF_ENTRY = 0x08;
const SF_AWAY_ONLY = 0x10;
const MAX_DI = 40;
const HAZARD_KINDS = Object.freeze(['water', 'gas', 'smoke']);
const INTRUSION_KINDS = Object.freeze(['door', 'window', 'motion']);
const EXIT_DEFAULT_S = 45;
const ENTRY_DEFAULT_S = 30;
const SENSOR_ID_RE = /^([db])([1-9][0-9]{0,3})$/;

function isObj(v) {
  return v !== null && typeof v === 'object' && !Array.isArray(v);
}
function int(v, def = 0) {
  if (v === true) return 1;
  if (v === false) return 0;
  return typeof v === 'number' && Number.isInteger(v) ? v : def;
}
function list(v) {
  return Array.isArray(v) ? v.filter(isObj) : [];
}

function sensorKey(s) {
  const m = typeof s.id === 'string' ? SENSOR_ID_RE.exec(s.id) : null;
  return m ? { src: m[1], index: Number(m[2]), key: s.id } : null;
}

function normSensor(s) {
  const k = sensorKey(s);
  if (!k) return null;
  return {
    key: k.key,
    src: k.src,
    index: k.index,
    kind: typeof s.kind === 'string' ? s.kind : '',
    zone: int(s.zone),
    active_open: int(s.active_open) ? 1 : 0,
    flags: int(s.flags),
    confirm_ms: int(s.confirm_ms),
  };
}

function zoneMask(zones) {
  let m = 0;
  for (const z of Array.isArray(zones) ? zones : []) if (Number.isInteger(z) && z >= 1 && z <= 4) m |= 1 << (z - 1);
  return m;
}

function normActuator(a) {
  return {
    relay: int(a.relay),
    relay2: int(a.relay2),
    kind: typeof a.kind === 'string' ? a.kind : '',
    close_mode: typeof a.close_mode === 'string' ? a.close_mode : 'energize',
    medium: typeof a.medium === 'string' ? a.medium : 'none',
    zone_mask: zoneMask(a.zones),
    fb_di: int(a.fb_di),
    fb_closed_active: int(a.fb_closed_active, 1) ? 1 : 0,
    fb_timeout_s: int(a.fb_timeout_s),
    run_limit_s: int(a.run_limit_s),
    exproof: a.exproof === true,
  };
}

function norm(doc) {
  const d = isObj(doc) ? doc : {};
  const pol = isObj(d.policy) ? d.policy : {};
  const intr = isObj(d.intrusion) ? d.intrusion : {};
  return {
    policyOn: pol.on === true,
    dryHold: int(pol.dry_hold_ms),
    exitS: (int(intr.exit_s) & 0xff) || EXIT_DEFAULT_S, // etkin deger (0 = varsayilan; firmware exitDelayS)
    entryS: (int(intr.entry_s) & 0xff) || ENTRY_DEFAULT_S,
    sensors: list(d.sensors).map(normSensor).filter(Boolean),
    actuators: list(d.actuators).map(normActuator),
  };
}

/**
 * Kalici DI kullanim gecmisinin sunucudaki alt siniri: belgedeki kablolu sensor/kumanda satirlari ve vana geri bildirim
 * girisleri (firmware diUseMask). Sunucu panonun ahbu_latch/di_hist kaydini bilmez; bu deger onun alt kumesidir.
 * @returns {bigint} bit = DI-1
 */
function diUseMask(doc) {
  const n = norm(doc);
  let m = 0n;
  for (const s of n.sensors) if (s.src === 'd' && s.index >= 1 && s.index <= MAX_DI) m |= 1n << BigInt(s.index - 1);
  for (const a of n.actuators) if (a.fb_di >= 1 && a.fb_di <= MAX_DI) m |= 1n << BigInt(a.fb_di - 1);
  return m;
}

/**
 * a -> b degisimi gevsetme mi? (firmware SafetyCfgEdit.h isLoosening ile ayni kurallar, ayni sira)
 * @param {object} a  onceki yapilandirma (JSON)
 * @param {object} b  sonraki yapilandirma (JSON)
 * @param {bigint|number} [diHist]  kalici DI kullanim gecmisi (bit = DI-1)
 */
// Kumanda rolu satiri kurali (firmware roleRowLoosening): EM-6 / FW2-2 gas_reset; Faz 2 (F2.B.3) arm_key ayni DI gecmisi kuraliyla,
// bolgesi anlamsiz (bolge degisimi gevsetme DEGIL).
function roleRowLoosening(x, y, hist, role) {
  const armKey = role === 'arm_key';
  for (const t of y.sensors) {
    if (t.kind !== role) continue;
    let existed = false;
    for (const s of x.sensors) {
      if (s.key !== t.key) continue;
      existed = true;
      if (s.kind !== t.kind || (!armKey && s.zone !== t.zone)) return true;
    }
    if (!existed && t.src === 'd' && t.index >= 1 && t.index <= MAX_DI && (hist & (1n << BigInt(t.index - 1)))) return true;
  }
  return false;
}

function isLoosening(a, b, diHist = 0n) {
  try {
    const x = norm(a);
    const y = norm(b);
    const hist = BigInt(diHist || 0);
    if (x.policyOn && !y.policyOn) return true;
    if (y.dryHold < x.dryHold) return true;
    if (roleRowLoosening(x, y, hist, 'gas_reset') || roleRowLoosening(x, y, hist, 'arm_key')) return true;
    for (const s of x.sensors) {
      if (!HAZARD_KINDS.includes(s.kind)) continue;
      const t = y.sensors.find((q) => q.key === s.key);
      if (!t) return true;
      if (t.kind !== s.kind || t.zone !== s.zone) return true;
      if ((s.flags & ~t.flags) & (SF_REACT | SF_FAULT_CLOSE)) return true;
      if (t.confirm_ms > s.confirm_ms) return true;
      if (s.active_open && !t.active_open) return true;
    }
    for (let i = 0; i < x.actuators.length; i++) {
      if (i >= y.actuators.length) return true;
      const p = x.actuators[i];
      const q = y.actuators[i];
      if (q.relay !== p.relay || q.relay2 !== p.relay2 || q.kind !== p.kind || q.close_mode !== p.close_mode || q.medium !== p.medium) return true;
      if (p.zone_mask & ~q.zone_mask) return true;
      if (p.fb_di !== 0 && (q.fb_di !== p.fb_di || q.fb_closed_active !== p.fb_closed_active || q.fb_timeout_s > p.fb_timeout_s)) return true;
      if (p.kind === 'siren' && q.run_limit_s < p.run_limit_s) return true;
      if (q.exproof && !p.exproof) return true;
    }
    for (let i = x.actuators.length; i < y.actuators.length; i++) {
      if (y.actuators[i].kind === 'fan' && y.actuators[i].exproof) return true; // EM-7
    }
    return false;
  } catch (_) {
    return false;
  }
}

const isGasValve = (a) => a.kind === 'valve' && a.medium === 'gas';

/**
 * Faz 2 incelemesi G-1a (firmware isGasRelease; karar 7.2b-8): a -> b gaz vanasini uzaktan acilabilir kiliyor mu? (mevcut gaz
 * vanasinin kimligi -- role(ler), tur, kip, akiskan -- korunmuyor ya da gas_reset satir kurali). YETKI karari: bulut yolu bunu
 * uygulayamaz (403 GAS_VALVE_LOCAL_ONLY; firmware gas_local_only). Yalniz seri CLI (fiziksel erisim). Asla firlatmaz.
 */
function isGasRelease(a, b, diHist = 0n) {
  try {
    const x = norm(a);
    const y = norm(b);
    if (roleRowLoosening(x, y, BigInt(diHist || 0), 'gas_reset')) return true;
    for (const p of x.actuators) {
      if (!isGasValve(p)) continue;
      const kept = y.actuators.some((q) => isGasValve(q) && q.relay === p.relay && q.relay2 === p.relay2 && q.close_mode === p.close_mode);
      if (!kept) return true;
    }
    return false;
  } catch (_) {
    return false;
  }
}

/**
 * Faz 2 incelemesi G-1b (firmware isIntrusionLoosening): a -> b hirsiz alarmini zayiflatiyor mu? (SF_REACT'li kapi/pencere/hareket
 * sensorunu silmek / alarm disi birakmak, SF_ENTRY / SF_AWAY_ONLY eklemek, NC -> NO, onay suresini uzatmak, etkin cikis/giris
 * gecikmesini uzatmak, arm_key satir kurali). YETKI karari: kurulu kipte bulut yolu uygulayamaz (409 INTRUSION_ARMED; firmware armed).
 * Asla firlatmaz.
 */
function isIntrusionLoosening(a, b, diHist = 0n) {
  try {
    const x = norm(a);
    const y = norm(b);
    if (roleRowLoosening(x, y, BigInt(diHist || 0), 'arm_key')) return true;
    if (y.exitS > x.exitS || y.entryS > x.entryS) return true;
    for (const s of x.sensors) {
      if (!INTRUSION_KINDS.includes(s.kind) || !(s.flags & SF_REACT)) continue;
      const t = y.sensors.find((q) => q.key === s.key);
      if (!t || !INTRUSION_KINDS.includes(t.kind) || !(t.flags & SF_REACT)) return true;
      if ((t.flags & ~s.flags) & (SF_ENTRY | SF_AWAY_ONLY)) return true;
      if (s.active_open && !t.active_open) return true;
      if (t.confirm_ms > s.confirm_ms) return true;
    }
    return false;
  } catch (_) {
    return false;
  }
}

module.exports = { isLoosening, isGasRelease, isIntrusionLoosening, diUseMask, HAZARD_KINDS, INTRUSION_KINDS };
