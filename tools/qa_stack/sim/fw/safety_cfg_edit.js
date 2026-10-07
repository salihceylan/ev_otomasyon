// safety/SafetyCfgEdit.h + safety/SafetyCfgJson.h (firmware) JavaScript portu. SAF MANTIK.
//  * applyEdit(): tek ogeli yama (sensor/eylemci ekle-degistir-sil, politika, bolge adi, isik secenegi); rev'i yonetici artirir.
//  * isLoosening(): karar 7.2b-7 -- LAN'dan yalniz ekleme/sikilastirma.
//  * remapActPos(): silinen eylemciden sonraki konum bitleri kayar; calisirken eklenen su vanasinin konumu anlik role seviyesinden benimsenir.
//  * writeConfigJson()/planDump()/writeDumpPart(): GET /api/safety/config ve cfg_dump (her parca <= 3500 bayt).
import {
  MAX_SENSORS, MAX_ACTUATORS, MAX_ZONES, MAX_RELAYS, SF_REACT, SF_FAULT_CLOSE, SF_ENTRY, SF_AWAY_ONLY, SensorKind, SensorSrc, MAX_DI, hazardOf, sensorIdCode,
  sensorIdText, isIntrusionKind,
} from './sensor_hub.js';
import { ActKind, CloseMode, Medium, AF_FAN_EXPROOF, isValve, isPulseValve, isGasValve, relayBit, relayLevelFor, actKindText } from './actuator_map.js';
import { CfgErr, configCrc, exitDelayS, entryDelayS } from './safety_config.js';

export const EditOp = Object.freeze({
  NONE: 0, SET_SENSOR: 1, SET_ACTUATOR: 2, SET_POLICY: 3, SET_ZONE: 4, SET_LIGHT: 5, DEL_SENSOR: 6, DEL_ACTUATOR: 7, SET_INTRUSION: 8,
});
export const DUMP_PART_CAP = 3500;
export const DUMP_ENVELOPE_RESERVE = 260;
export const DUMP_MAX_PARTS = 12;

const clone = (o) => JSON.parse(JSON.stringify(o));
const hex8 = (v) => (v >>> 0).toString(16).padStart(8, '0');
const blen = (s) => Buffer.byteLength(s, 'utf8');

export function editInit() {
  return {
    op: EditOp.NONE, sens: null, act: null, actIndex: 0xFF, hasPolicyOn: 0, policyOn: 0, hasDryHold: 0, dryHoldMs: 0,
    zoneId: 0, zoneName: '', lightRelay: 0, light: null, hasExit: 0, exitS: 0, hasEntry: 0, entryS: 0,
  };
}

export function removeBit16(bits, idx) {
  if (idx >= 16) return bits;
  const low = bits & ((1 << idx) - 1);
  const high = (bits >> (idx + 1)) << idx;
  return (low | high) & 0xFFFF;
}

/** @returns {{err:number, out:object, removedAct:number}} */
export function applyEdit(cur, e) {
  const out = clone(cur);
  out.sens = out.sens.slice(0, out.nSens);
  out.act = out.act.slice(0, out.nAct);
  const r = (err, removedAct = -1) => ({ err, out, removedAct });
  switch (e.op) {
    case EditOp.SET_SENSOR: {
      const i = out.sens.findIndex((s) => s.src === e.sens.src && s.index === e.sens.index);
      if (i >= 0) { out.sens[i] = clone(e.sens); return r(CfgErr.OK); }
      if (out.nSens >= MAX_SENSORS) return r(CfgErr.FULL);
      out.sens.push(clone(e.sens));
      out.nSens++;
      return r(CfgErr.OK);
    }
    case EditOp.DEL_SENSOR: {
      const i = out.sens.findIndex((s) => s.src === e.sens.src && s.index === e.sens.index);
      if (i < 0) return r(CfgErr.NOT_FOUND);
      out.sens.splice(i, 1);
      out.nSens--;
      return r(CfgErr.OK);
    }
    case EditOp.SET_ACTUATOR: {
      if (e.actIndex < out.nAct) { out.act[e.actIndex] = clone(e.act); return r(CfgErr.OK); }
      if (e.actIndex !== 0xFF && e.actIndex !== out.nAct) return r(CfgErr.NOT_FOUND);
      if (out.nAct >= MAX_ACTUATORS) return r(CfgErr.FULL);
      out.act.push(clone(e.act));
      out.nAct++;
      return r(CfgErr.OK);
    }
    case EditOp.DEL_ACTUATOR: {
      if (e.actIndex >= out.nAct) return r(CfgErr.NOT_FOUND);
      out.act.splice(e.actIndex, 1);
      out.nAct--;
      return r(CfgErr.OK, e.actIndex);
    }
    case EditOp.SET_POLICY:
      if (!e.hasPolicyOn && !e.hasDryHold) return r(CfgErr.BAD_EDIT);
      if (e.hasPolicyOn) out.pol.policy_on = e.policyOn ? 1 : 0;
      if (e.hasDryHold) out.pol.dry_hold_ms = e.dryHoldMs >>> 0;
      return r(CfgErr.OK);
    case EditOp.SET_ZONE:
      if (e.zoneId < 1 || e.zoneId > MAX_ZONES) return r(CfgErr.BAD_EDIT);
      out.zones[e.zoneId - 1] = { name: e.zoneName };
      return r(CfgErr.OK);
    case EditOp.SET_LIGHT:
      if (e.lightRelay < 1 || e.lightRelay > MAX_RELAYS) return r(CfgErr.BAD_EDIT);
      out.light[e.lightRelay - 1] = clone(e.light);
      return r(CfgErr.OK);
    case EditOp.SET_INTRUSION:   // Faz 2 (F2.B.7): hirsiz cikis/giris gecikmeleri (Policy.exit_s/entry_s)
      if (!e.hasExit && !e.hasEntry) return r(CfgErr.BAD_EDIT);
      if (e.hasExit) out.pol.exit_s = e.exitS & 0xFF;
      if (e.hasEntry) out.pol.entry_s = e.entryS & 0xFF;
      return r(CfgErr.OK);
    default:
      return r(CfgErr.BAD_EDIT);
  }
}

/**
 * Kalici DI kullanim gecmisi (NVS "ahbu_latch/di_hist"; inceleme turu 2 FW2-2): sensor/kumanda satirlari ve vana geri bildirim girisleri
 * (kablolu DI; kopru yuvasi girmez). @returns {bigint} bit = DI-1
 */
export function diUseMask(c) {
  let m = 0n;
  for (let i = 0; i < c.nSens; i++) {
    const s = c.sens[i];
    if (s.src === SensorSrc.DI && s.index >= 1 && s.index <= MAX_DI) m |= 1n << BigInt(s.index - 1);
  }
  for (let i = 0; i < c.nAct; i++) {
    const d = c.act[i].fb_di || 0;
    if (d >= 1 && d <= MAX_DI) m |= 1n << BigInt(d - 1);
  }
  return m;
}

// Kumanda rolu satiri kurali (firmware roleRowLoosening): EM-6 mevcut satiri role cevirmek / GAS_RESET bolgesi; FW2-2 karsiligi olmayan
// YENI satirin DI'si kalici kullanim gecmisinde; Faz 2 (F2.B.3) ARM_KEY ayni kuralla (bolge anlamsiz).
export function roleRowLoosening(a, b, diHist, role) {
  const hist = BigInt(diHist || 0);
  const armKey = role === SensorKind.ARM_KEY;
  for (let j = 0; j < b.nSens; j++) {
    const t = b.sens[j];
    if (t.kind !== role) continue;
    let existed = false;
    for (let i = 0; i < a.nSens; i++) {
      const s = a.sens[i];
      if (s.src !== t.src || s.index !== t.index) continue;
      existed = true;
      if (s.kind !== t.kind || (!armKey && s.zone !== t.zone)) return true;
    }
    if (!existed && t.src === SensorSrc.DI && t.index >= 1 && t.index <= MAX_DI && (hist & (1n << BigInt(t.index - 1)))) return true;
  }
  return false;
}

export function isLoosening(a, b, diHist = 0n) {
  if (a.pol.policy_on && !b.pol.policy_on) return true;
  if (b.pol.dry_hold_ms < a.pol.dry_hold_ms) return true;
  if (roleRowLoosening(a, b, diHist, SensorKind.GAS_RESET) || roleRowLoosening(a, b, diHist, SensorKind.ARM_KEY)) return true;
  for (let i = 0; i < a.nSens; i++) {
    const s = a.sens[i];
    if (hazardOf(s.kind) === 0) continue;
    const t = b.sens.slice(0, b.nSens).find((x) => x.src === s.src && x.index === s.index);
    if (!t) return true;
    if (t.kind !== s.kind || t.zone !== s.zone) return true;
    if ((s.flags & ~t.flags) & (SF_REACT | SF_FAULT_CLOSE)) return true;
    if (t.confirm_ms > s.confirm_ms) return true;
    if (s.active_open && !t.active_open) return true;
  }
  for (let i = 0; i < a.nAct; i++) {
    if (i >= b.nAct) return true;
    const x = a.act[i];
    const y = b.act[i];
    if (y.relay !== x.relay || (y.relay2 || 0) !== (x.relay2 || 0) || y.kind !== x.kind || y.close_mode !== x.close_mode || y.medium !== x.medium) return true;
    if (x.zone_mask & ~y.zone_mask) return true;
    if (x.fb_di !== 0 && (y.fb_di !== x.fb_di || y.fb_closed_active !== x.fb_closed_active || y.fb_timeout_s > x.fb_timeout_s)) return true;
    if (x.kind === ActKind.SIREN && y.run_limit_s < x.run_limit_s) return true;
    if ((y.aflags & AF_FAN_EXPROOF) && !(x.aflags & AF_FAN_EXPROOF)) return true;
  }
  for (let i = a.nAct; i < b.nAct; i++) {   // EM-7: yeni ex-proof fan satiri
    if (b.act[i].kind === ActKind.FAN && (b.act[i].aflags & AF_FAN_EXPROOF)) return true;
  }
  return false;
}

/** Faz 2 incelemesi G-1a (firmware isGasRelease): b gaz vanasini uzaktan acilabilir kiliyor mu? Bulut yolu uygulayamaz (gas_local_only). */
export function isGasRelease(a, b, diHist = 0n) {
  if (roleRowLoosening(a, b, diHist, SensorKind.GAS_RESET)) return true;
  for (let i = 0; i < a.nAct && i < MAX_ACTUATORS; i++) {
    const x = a.act[i];
    if (!isGasValve(x)) continue;
    let kept = false;
    for (let j = 0; j < b.nAct && j < MAX_ACTUATORS && !kept; j++) {
      const y = b.act[j];
      kept = isGasValve(y) && y.relay === x.relay && (y.relay2 || 0) === (x.relay2 || 0) && y.close_mode === x.close_mode;
    }
    if (!kept) return true;
  }
  return false;
}

/** Faz 2 incelemesi G-1b (firmware isIntrusionLoosening): b hirsiz alarmini zayiflatiyor mu? Kurulu kipte bulut yolu uygulayamaz (armed). */
export function isIntrusionLoosening(a, b, diHist = 0n) {
  if (roleRowLoosening(a, b, diHist, SensorKind.ARM_KEY)) return true;
  if (exitDelayS(b.pol) > exitDelayS(a.pol) || entryDelayS(b.pol) > entryDelayS(a.pol)) return true;
  for (let i = 0; i < a.nSens && i < MAX_SENSORS; i++) {
    const s = a.sens[i];
    if (!isIntrusionKind(s.kind) || !(s.flags & SF_REACT)) continue;
    const t = b.sens.slice(0, b.nSens).find((x) => x.src === s.src && x.index === s.index);
    if (!t || !isIntrusionKind(t.kind) || !(t.flags & SF_REACT)) return true;
    if ((t.flags & ~s.flags) & (SF_ENTRY | SF_AWAY_ONLY)) return true;
    if (s.active_open && !t.active_open) return true;
    if (t.confirm_ms > s.confirm_ms) return true;
  }
  return false;
}

/**
 * Calisirken yama (EM-2/EM-3): yeni tablodaki her eylemcinin eski tablodaki karsiligi (yoksa -1). Kimlik: role(ler), tur, kip, akiskan,
 * geri bildirim girisi. Her eski satir en cok bir kez eslenir. @returns {number[]} MAX_ACTUATORS uzunlugunda
 */
export function actuatorIdentityMap(oldC, newC) {
  const map = new Array(MAX_ACTUATORS).fill(-1);
  const used = new Array(MAX_ACTUATORS).fill(false);
  for (let j = 0; j < newC.nAct && j < MAX_ACTUATORS; j++) {
    const y = newC.act[j];
    for (let i = 0; i < oldC.nAct && i < MAX_ACTUATORS; i++) {
      const x = oldC.act[i];
      if (used[i] || x.relay !== y.relay || (x.relay2 || 0) !== (y.relay2 || 0) || x.kind !== y.kind || x.close_mode !== y.close_mode
        || x.medium !== y.medium || x.fb_di !== y.fb_di || x.fb_closed_active !== y.fb_closed_active) continue;
      used[i] = true;
      map[j] = i;
      break;
    }
  }
  return map;
}

/** @returns {{open:number, known:number}} */
export function remapActPos(oldC, oldOpen, oldKnown, newC, curLevels) {
  let open = 0;
  let known = 0;
  for (let j = 0; j < newC.nAct && j < MAX_ACTUATORS; j++) {
    const y = newC.act[j];
    if (!isValve(y)) continue;
    const bj = 1 << j;
    let matched = false;
    for (let i = 0; i < oldC.nAct && i < MAX_ACTUATORS && !matched; i++) {
      const x = oldC.act[i];
      if (x.relay !== y.relay || (x.relay2 || 0) !== (y.relay2 || 0) || x.kind !== y.kind || x.close_mode !== y.close_mode || x.medium !== y.medium) continue;
      matched = true;
      if (oldKnown & (1 << i)) { known |= bj; if (oldOpen & (1 << i)) open |= bj; }
    }
    if (matched || isPulseValve(y) || isGasValve(y)) continue;
    const level = (curLevels & relayBit(y.relay)) !== 0n;
    known |= bj;
    if (level === relayLevelFor(y, false)) open |= bj;
  }
  return { open: open & 0xFFFF, known: known & 0xFFFF };
}

// ------------------------------------------------------------------------------------------------ JSON
const KIND = {
  [SensorKind.WATER]: 'water', [SensorKind.GAS]: 'gas', [SensorKind.SMOKE]: 'smoke', [SensorKind.DOOR]: 'door', [SensorKind.WINDOW]: 'window',
  [SensorKind.MOTION]: 'motion', [SensorKind.GENERIC]: 'generic', [SensorKind.ALARM_ACK]: 'alarm_ack', [SensorKind.VALVE_CLOSE]: 'valve_close',
  [SensorKind.GAS_RESET]: 'gas_reset', [SensorKind.ARM_KEY]: 'arm_key',
};
export const KIND_BY_TEXT = Object.fromEntries(Object.entries(KIND).map(([k, v]) => [v, Number(k)]));
export const closeModeText = (m) => (m === CloseMode.DEENERGIZE_TO_CLOSE ? 'deenergize' : m === CloseMode.PULSE_TWO_RELAY ? 'pulse' : 'energize');
const mediumTxt = (m) => (m === Medium.WATER ? 'water' : m === Medium.GAS ? 'gas' : 'none');
const esc = (s) => JSON.stringify(String(s ?? ''));

export function writeSensorCfg(s) {
  return `{"id":"${sensorIdText(sensorIdCode(s))}","kind":"${KIND[s.kind] ?? 'unknown'}","zone":${s.zone},"active_open":${s.active_open ? 1 : 0},"flags":${s.flags},"confirm_ms":${s.confirm_ms},"name":${esc(s.name)}}`;
}

export function writeActuatorCfg(a, idx) {
  const zones = [];
  for (let z = 0; z < MAX_ZONES; z++) if (a.zone_mask & (1 << z)) zones.push(z + 1);
  return `{"id":"a${idx + 1}","relay":${a.relay}${isPulseValve(a) ? `,"relay2":${a.relay2}` : ''},"kind":"${actKindText(a.kind)}","close_mode":"${closeModeText(a.close_mode)}","medium":"${mediumTxt(a.medium)}","zones":[${zones.join(',')}],"fb_di":${a.fb_di},"fb_closed_active":${a.fb_closed_active ? 1 : 0},"fb_timeout_s":${a.fb_timeout_s},"run_limit_s":${a.run_limit_s},"exproof":${a.aflags & AF_FAN_EXPROOF ? 'true' : 'false'},"name":${esc(a.name)}}`;
}

export function writeCfgHead(c) {
  const zones = [];
  for (let z = 0; z < MAX_ZONES; z++) zones.push(`{"id":${z + 1},"name":${esc(c.zones[z]?.name ?? '')}}`);
  const lights = [];
  for (let r = 0; r < MAX_RELAYS; r++) {
    const l = c.light[r];
    if (!l || (!l.dimmable && !l.dimmer_src && !l.dimmer_addr && !l.dimmer_ch)) continue;
    lights.push(`{"relay":${r + 1},"dimmable":${l.dimmable},"src":${l.dimmer_src},"addr":${l.dimmer_addr},"ch":${l.dimmer_ch}}`);
  }
  return `,"policy":{"on":${c.pol.policy_on ? 'true' : 'false'},"dry_hold_ms":${c.pol.dry_hold_ms >>> 0}}`
    + `,"intrusion":{"exit_s":${(c.pol.exit_s || 0) & 0xFF},"entry_s":${(c.pol.entry_s || 0) & 0xFF}}`
    + `,"zones":[${zones.join(',')}],"lights":[${lights.join(',')}]`;
}

export function writeConfigJson(c) {
  const sens = c.sens.slice(0, c.nSens).map(writeSensorCfg).join(',');
  const act = c.act.slice(0, c.nAct).map((a, i) => writeActuatorCfg(a, i)).join(',');
  return `{"rev":${c.rev >>> 0},"crc":"${hex8(configCrc(c))}"${writeCfgHead(c)},"sensors":[${sens}],"actuators":[${act}]}`;
}

/** @returns {{s0:number,s1:number,a0:number,a1:number,head:number}[]} (bos dizi = sigmadi) */
export function planDump(c, cap = DUMP_PART_CAP, maxParts = DUMP_MAX_PARTS) {
  const headLen = blen(writeCfgHead(c));
  const parts = [];
  let s = 0;
  let a = 0;
  while (parts.length < maxParts) {
    const p = { head: parts.length === 0 ? 1 : 0, s0: s, s1: s, a0: a, a1: a };
    let used = DUMP_ENVELOPE_RESERVE + (p.head ? headLen : 0);
    if (used > cap) return [];
    let progress = p.head !== 0;
    while (s < c.nSens) {
      const l = blen(writeSensorCfg(c.sens[s]));
      if (used + l + 1 > cap) break;
      used += l + 1; s++; p.s1 = s; progress = true;
    }
    if (s >= c.nSens) {
      while (a < c.nAct) {
        const l = blen(writeActuatorCfg(c.act[a], a));
        if (used + l + 1 > cap) break;
        used += l + 1; a++; p.a1 = a; progress = true;
      }
    }
    parts.push(p);
    if (s >= c.nSens && a >= c.nAct) return parts;
    if (!progress) return [];
  }
  return [];
}

export function writeDumpPart(c, p, part, parts, uid) {
  const sens = [];
  for (let i = p.s0; i < p.s1; i++) sens.push(writeSensorCfg(c.sens[i]));
  const act = [];
  for (let i = p.a0; i < p.a1; i++) act.push(writeActuatorCfg(c.act[i], i));
  return `{"v":1,"uid":"${uid}","type":"cfg_dump","module":"safety","rev":${c.rev >>> 0},"crc":"${hex8(configCrc(c))}","part":${part},"parts":${parts}${p.head ? writeCfgHead(c) : ''},"sensors":[${sens.join(',')}],"actuators":[${act.join(',')}]}`;
}
