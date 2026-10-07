// Firmware SafetyCfgEdit/SafetyCfgJson (src/safety/SafetyCfgEdit.h, SafetyCfgJson.h) JS portunun UYUMLULUK testi: firmware'in kendi Unity
// testlerinin (ev_otomasyon_servis_yazilimi/waveshare_s3_demo/test/test_safety_cfg_edit/test_main.cpp) BIREBIR portu.
import test from 'node:test';
import assert from 'node:assert/strict';
import { SensorKind, SensorSrc, defaultFlags, defaultConfirmMs, makeSensorConfig, MAX_SENSORS, MAX_ACTUATORS, MAX_RELAYS, NAME_LEN } from '../sim/fw/sensor_hub.js';
import { ActKind, CloseMode, Medium, AF_FAN_EXPROOF, makeActuatorConfig } from '../sim/fw/actuator_map.js';
import { defaultSafetyConfig, CfgErr, configCrc, DRY_HOLD_DEFAULT_MS } from '../sim/fw/safety_config.js';
import {
  EditOp, editInit, applyEdit, isLoosening, removeBit16, remapActPos, writeConfigJson, planDump, writeDumpPart, DUMP_PART_CAP, actuatorIdentityMap,
  diUseMask,
} from '../sim/fw/safety_cfg_edit.js';

const clone = (o) => JSON.parse(JSON.stringify(o));
const hex8 = (v) => (v >>> 0).toString(16).padStart(8, '0');
const sensor = (di, kind, zone, nc = 0) => makeSensorConfig({ src: SensorSrc.DI, index: di, kind, zone, active_open: nc, flags: defaultFlags(kind), confirm_ms: defaultConfirmMs(kind) });
const valve = (relay, medium, mode = CloseMode.DEENERGIZE_TO_CLOSE, zones = 1) => makeActuatorConfig({ relay, kind: ActKind.VALVE, close_mode: mode, medium, zone_mask: zones, fb_closed_active: 1, fb_timeout_s: 60 });
const siren = (relay, lim = 180) => makeActuatorConfig({ relay, kind: ActKind.SIREN, zone_mask: 1, run_limit_s: lim });
function base() {
  const c = defaultSafetyConfig();
  c.sens = [sensor(3, SensorKind.WATER, 1)];
  c.nSens = 1;
  c.act = [valve(5, Medium.WATER), siren(6), valve(7, Medium.WATER, CloseMode.ENERGIZE_TO_CLOSE)];
  c.nAct = 3;
  c.rev = 4;
  return c;
}
const edit = (op, o = {}) => ({ ...editInit(), op, ...o });

test('fw_safety_cfg_edit: sensor ekle/degistir/sil; eylemci yeni/degistir/sil (kaydirma), dolu tablo, bulunamayan oge', () => {
  const c = base();
  let r = applyEdit(c, edit(EditOp.SET_SENSOR, { sens: sensor(4, SensorKind.GAS, 1, 1) }));
  assert.equal(r.err, CfgErr.OK); assert.equal(r.out.nSens, 2); assert.equal(r.out.sens[1].index, 4); assert.equal(r.removedAct, -1);
  r = applyEdit(c, edit(EditOp.SET_SENSOR, { sens: sensor(3, SensorKind.WATER, 2) }));
  assert.equal(r.out.nSens, 1); assert.equal(r.out.sens[0].zone, 2); assert.equal(r.out.rev, 4);
  r = applyEdit(c, edit(EditOp.DEL_ACTUATOR, { actIndex: 1 }));
  assert.equal(r.err, CfgErr.OK); assert.equal(r.removedAct, 1); assert.equal(r.out.nAct, 2); assert.equal(r.out.act[1].relay, 7);
  assert.equal(applyEdit(c, edit(EditOp.DEL_ACTUATOR, { actIndex: 3 })).err, CfgErr.NOT_FOUND);
  r = applyEdit(c, edit(EditOp.DEL_SENSOR, { sens: { src: SensorSrc.DI, index: 3 } }));
  assert.equal(r.err, CfgErr.OK); assert.equal(r.out.nSens, 0);
  assert.equal(applyEdit(c, edit(EditOp.DEL_SENSOR, { sens: { src: SensorSrc.DI, index: 9 } })).err, CfgErr.NOT_FOUND);
  assert.equal(removeBit16(0x0005, 1), 0x0003);
  assert.equal(removeBit16(0x0003, 1), 0x0001);
  r = applyEdit(c, edit(EditOp.SET_ACTUATOR, { act: siren(8), actIndex: 0xFF }));
  assert.equal(r.err, CfgErr.OK); assert.equal(r.out.nAct, 4);
  r = applyEdit(c, edit(EditOp.SET_ACTUATOR, { act: valve(5, Medium.GAS), actIndex: 0 }));
  assert.equal(r.out.act[0].medium, Medium.GAS);
  assert.equal(applyEdit(c, edit(EditOp.SET_ACTUATOR, { act: siren(8), actIndex: 5 })).err, CfgErr.NOT_FOUND);
  const full = clone(c);
  full.act = Array.from({ length: MAX_ACTUATORS }, (_, i) => siren(i + 1));
  full.nAct = MAX_ACTUATORS;
  assert.equal(applyEdit(full, edit(EditOp.SET_ACTUATOR, { act: siren(8), actIndex: 0xFF })).err, CfgErr.FULL);
});

test('fw_safety_cfg_edit: politika, bolge adi, isik secenegi', () => {
  const c = base();
  let r = applyEdit(c, edit(EditOp.SET_POLICY, { hasPolicyOn: 1, policyOn: 0 }));
  assert.equal(r.err, CfgErr.OK); assert.equal(r.out.pol.policy_on, 0); assert.equal(r.out.pol.dry_hold_ms, DRY_HOLD_DEFAULT_MS);
  r = applyEdit(c, edit(EditOp.SET_ZONE, { zoneId: 2, zoneName: 'Mutfak' }));
  assert.equal(r.out.zones[1].name, 'Mutfak');
  assert.equal(applyEdit(c, edit(EditOp.SET_ZONE, { zoneId: 5, zoneName: 'x' })).err, CfgErr.BAD_EDIT);
  r = applyEdit(c, edit(EditOp.SET_LIGHT, { lightRelay: 2, light: { dimmable: 1, dimmer_src: 1, dimmer_addr: 2, dimmer_ch: 3 } }));
  assert.equal(r.out.light[1].dimmer_ch, 3);
});

test('fw_safety_cfg_edit: gevsetme kurallari (karar 7.2b-7)', () => {
  const a = base();
  const mod = (fn) => { const b = clone(a); fn(b); return b; };
  assert.equal(isLoosening(a, clone(a)), false);
  assert.equal(isLoosening(a, mod((b) => { b.sens.push(sensor(4, SensorKind.WATER, 1)); b.nSens = 2; b.act.push(siren(8)); b.nAct = 4; })), false);
  assert.equal(isLoosening(a, mod((b) => { b.pol.policy_on = 0; })), true);
  assert.equal(isLoosening(a, mod((b) => { b.pol.dry_hold_ms = 5000; })), true);
  assert.equal(isLoosening(a, mod((b) => { b.pol.dry_hold_ms = 20000; })), false);
  assert.equal(isLoosening(a, mod((b) => { b.nSens = 0; b.sens = []; })), true);
  assert.equal(isLoosening(a, mod((b) => { b.sens[0].kind = SensorKind.DOOR; })), true);
  assert.equal(isLoosening(a, mod((b) => { b.sens[0].zone = 2; })), true);
  assert.equal(isLoosening(a, mod((b) => { b.sens[0].flags = 0; })), true);
  assert.equal(isLoosening(a, mod((b) => { b.sens[0].confirm_ms = 2000; })), true);
  assert.equal(isLoosening(a, mod((b) => { b.sens[0].confirm_ms = 500; })), false);
  assert.equal(isLoosening(a, mod((b) => { b.sens[0].active_open = 1; })), false);
  assert.equal(isLoosening(a, mod((b) => { b.sens[0].name = 'yeni ad'; })), false);
  assert.equal(isLoosening(a, mod((b) => { b.nAct = 2; b.act.pop(); })), true);
  assert.equal(isLoosening(a, mod((b) => { b.act[0].medium = Medium.GAS; })), true);
  assert.equal(isLoosening(a, mod((b) => { b.act[0].close_mode = CloseMode.ENERGIZE_TO_CLOSE; })), true);
  assert.equal(isLoosening(a, mod((b) => { b.act[0].relay = 8; })), true);
  assert.equal(isLoosening(a, mod((b) => { b.act[0].zone_mask = 0x03; })), false);
  assert.equal(isLoosening(a, mod((b) => { b.act[2].zone_mask = 0x02; })), true);
  assert.equal(isLoosening(a, mod((b) => { b.act[1].run_limit_s = 60; })), true);
  assert.equal(isLoosening(a, mod((b) => { b.act[1].kind = ActKind.GENERIC; })), true);
  assert.equal(isLoosening(a, mod((b) => { b.act[0].fb_di = 4; })), false);
  const f = mod((b) => { b.act[0].fb_di = 4; });
  assert.equal(isLoosening(f, mod((b) => { b.act[0].fb_di = 0; })), true);
  assert.equal(isLoosening(a, mod((b) => { b.act[0].aflags = AF_FAN_EXPROOF; })), true);
  assert.equal(isLoosening(a, mod((b) => { b.zones[0].name = 'Daire'; })), false);
  const g = mod((b) => { b.sens.push(sensor(8, SensorKind.ALARM_ACK, 0)); b.nSens = 2; });
  assert.equal(isLoosening(g, clone(a)), false);
});

test('fw_safety_cfg_edit: act_pos kaydirma ve yeni vanada anlik role seviyesinin benimsenmesi', () => {
  const oldC = base();
  const n = clone(oldC);
  n.act = [oldC.act[0], oldC.act[2], valve(8, Medium.WATER)];
  n.nAct = 3;
  let p = remapActPos(oldC, 0x0001, 0x0005, n, 1n << 7n);
  assert.equal(p.known, 0x0007);
  assert.equal(p.open, 0x0005);
  p = remapActPos(oldC, 0x0001, 0x0005, n, 0n);
  assert.equal(p.open, 0x0001);
});

test('fw_safety_cfg_edit: yapilandirma JSON alanlari ve kacis', () => {
  const c = base();
  c.sens[0].name = 'Banyo "zemin"\\';
  c.act[0].name = 'Ana Vana';
  let s = writeConfigJson(c);
  assert.ok(s.includes('"rev":4'));
  assert.ok(s.includes('"policy":{"on":true,"dry_hold_ms":10000}'));
  assert.ok(s.includes('{"id":1,"name":"Ev"}'));
  assert.ok(s.includes('{"id":"d3","kind":"water","zone":1,"active_open":0,"flags":1,"confirm_ms":1000,"name":"Banyo \\"zemin\\"\\\\"}'));
  assert.ok(s.includes('{"id":"a1","relay":5,"kind":"valve","close_mode":"deenergize","medium":"water","zones":[1],"fb_di":0,"fb_closed_active":1,"fb_timeout_s":60,"run_limit_s":0,"exproof":false,"name":"Ana Vana"}'));
  assert.ok(s.includes('"lights":[]'));
  assert.ok(s.includes(`"crc":"${hex8(configCrc(c))}"`));
  c.act[1].name = String.fromCharCode(1);
  s = writeConfigJson(c);
  assert.ok(s.includes(`"name":"${String.fromCharCode(92)}u0001"`));
  assert.doesNotThrow(() => JSON.parse(s));
});

test('fw_safety_cfg_edit: cfg_dump parcalari <= 3500 bayt, her oge tam bir kez; bos yapilandirma tek parca', () => {
  const c = defaultSafetyConfig();
  for (let i = 0; i < MAX_SENSORS; i++) {
    const s = sensor((i % 40) + 1, SensorKind.WATER, 1);
    if (i >= 40) { s.src = SensorSrc.BRIDGE; s.index = i - 39; }
    s.name = 'x'.repeat(NAME_LEN - 1);
    c.sens.push(s);
  }
  c.nSens = MAX_SENSORS;
  for (let i = 0; i < MAX_ACTUATORS; i++) c.act.push({ ...valve(i + 1, Medium.WATER), name: 'y'.repeat(NAME_LEN - 1) });
  c.nAct = MAX_ACTUATORS;
  for (let r = 0; r < MAX_RELAYS; r++) c.light[r].dimmable = 1;
  const parts = planDump(c, DUMP_PART_CAP);
  assert.ok(parts.length >= 3);
  let sens = 0;
  let act = 0;
  parts.forEach((p, k) => {
    const s = writeDumpPart(c, p, k + 1, parts.length, 'AHBU-S3-0A0010');
    assert.ok(Buffer.byteLength(s) <= DUMP_PART_CAP);
    const j = JSON.parse(s);
    assert.equal(j.type, 'cfg_dump');
    assert.equal(j.module, 'safety');
    assert.equal('policy' in j, k === 0);
    sens += j.sensors.length;
    act += j.actuators.length;
  });
  assert.equal(sens, MAX_SENSORS);
  assert.equal(act, MAX_ACTUATORS);
  assert.equal(planDump(defaultSafetyConfig(), DUMP_PART_CAP).length, 1);
});

// ---- Inceleme turu (entegrasyon) (Unity: test_safety_cfg_edit) ----
test('fw_safety_cfg_edit: yeni ex-proof fan ve mevcut satiri GAS_RESET e cevirmek gevsetmedir (EM-6/EM-7)', () => {
  const a = base();
  const fan = makeActuatorConfig({ relay: 9, kind: ActKind.FAN, zone_mask: 0x01 });
  const withAct = (c, x) => { const o = structuredClone(c); o.act = [...o.act.slice(0, o.nAct), x]; o.nAct += 1; return o; };
  const withSens = (c, x) => { const o = structuredClone(c); o.sens = [...o.sens.slice(0, o.nSens), x]; o.nSens += 1; return o; };
  assert.equal(isLoosening(a, withAct(a, fan)), false);
  assert.equal(isLoosening(a, withAct(a, { ...fan, aflags: AF_FAN_EXPROOF })), true);
  let f = withSens(a, sensor(9, SensorKind.DOOR, 1));
  let b = structuredClone(f); b.sens[1].kind = SensorKind.GAS_RESET;
  assert.equal(isLoosening(f, b), true);
  f = withSens(a, sensor(9, SensorKind.VALVE_CLOSE, 1));
  b = structuredClone(f); b.sens[1].kind = SensorKind.GAS_RESET;
  assert.equal(isLoosening(f, b), true);
  f = withSens(a, sensor(9, SensorKind.GAS_RESET, 1));
  b = structuredClone(f); b.sens[1].zone = 0;
  assert.equal(isLoosening(f, b), true);
  assert.equal(isLoosening(a, withSens(a, sensor(9, SensorKind.GAS_RESET, 1))), false);
});

// Inceleme turu 2 FW2-2 (Unity: test_loosening_gas_reset_on_used_di)
test('fw_safety_cfg_edit: kullanilmis DI ye yeni GAS_RESET (iki adimli yol) gevsetmedir (FW2-2)', () => {
  const a = base();
  const withSens = (c, x) => { const o = structuredClone(c); o.sens = [...o.sens.slice(0, o.nSens), x]; o.nSens += 1; return o; };
  const dropLast = (c) => { const o = structuredClone(c); o.nSens -= 1; o.sens = o.sens.slice(0, o.nSens); return o; };
  let f = withSens(a, sensor(9, SensorKind.DOOR, 1));
  const hist = diUseMask(f);
  assert.ok((hist & (1n << 8n)) !== 0n);
  assert.ok((hist & (1n << 2n)) !== 0n);
  let b = dropLast(f);
  assert.equal(isLoosening(f, b, hist), false);
  assert.equal(isLoosening(b, withSens(b, sensor(9, SensorKind.GAS_RESET, 1)), hist), true);
  assert.equal(isLoosening(b, withSens(b, sensor(9, SensorKind.GAS_RESET, 1)), 0n), false);
  assert.equal(isLoosening(b, withSens(b, sensor(10, SensorKind.GAS_RESET, 1)), hist), false);
  assert.equal(isLoosening(b, withSens(b, sensor(9, SensorKind.DOOR, 1)), hist), false);
  f = withSens(a, sensor(9, SensorKind.GAS_RESET, 1));
  const h2 = diUseMask(f);
  b = dropLast(f);
  assert.equal(isLoosening(f, b, h2), false);
  assert.equal(isLoosening(b, withSens(b, sensor(9, SensorKind.GAS_RESET, 0)), h2), true);
  f = structuredClone(a);
  f.act[0].fb_di = 11;
  f = withSens(f, { ...sensor(4, SensorKind.WATER, 1), src: SensorSrc.BRIDGE });
  const h3 = diUseMask(f);
  assert.ok((h3 & (1n << 10n)) !== 0n);
  assert.equal(h3 & (1n << 3n), 0n);
});

test('fw_safety_cfg_edit: eylemci kimlik eslemesi', () => {
  const oldC = base();
  const n = structuredClone(oldC);
  n.act = [structuredClone(oldC.act[2]), { ...structuredClone(oldC.act[0]), zone_mask: 0x03 }, valve(8, Medium.WATER)];
  n.nAct = 3;
  let map = actuatorIdentityMap(oldC, n);
  assert.deepEqual(map.slice(0, 3), [2, 0, -1]);
  assert.ok(map.slice(3).every((x) => x === -1));
  const m2 = structuredClone(oldC);
  m2.act[0].medium = Medium.GAS;
  map = actuatorIdentityMap(oldC, m2);
  assert.equal(map[0], -1);
  assert.equal(map[1], 1);
});
