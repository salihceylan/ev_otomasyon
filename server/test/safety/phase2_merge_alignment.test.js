'use strict';

// Faz 2 birlestirme hizalamasi (FW 1.2.1 <-> SRV): firmware cfg_dump'in 1. parcasina "intrusion":{exit_s, entry_s} yazar
// (SafetyCfgJson.h writeCfgHead) ve state.sensors'ta arm_key kumandasini ilan eder. Sunucu kopyasi bunlari KORUMALI (uygulama
// sihirbazi GET .../safety-config'ten gecikmeleri okur); v1.2.0 kopyasinin bicimi degismemeli. Uctan uca karsiligi:
// tools/qa_stack/test/f2_cross_layer_contract.test.js.

const test = require('node:test');
const assert = require('node:assert/strict');

const { validateEventPayload, mergeCfgDumpParts, parseStateSafety, CONTROL_KINDS } = require('../../src/utils/safety_payload');

const dumpPart = (extra = {}) => ({
  v: 1, type: 'cfg_dump', uid: 'AHBU-S3-0C00F2', module: 'safety', rev: 4, crc: '0BA07D91', part: 1, parts: 1,
  policy: { on: true, dry_hold_ms: 10000 }, zones: [{ id: 1, name: 'Ev' }], lights: [], sensors: [], actuators: [], ...extra,
});

test('cfg_dump: firmware 1.2.1 "intrusion" govdede ve birlesik kopyada korunur', () => {
  const v = validateEventPayload(dumpPart({ intrusion: { exit_s: 20, entry_s: 0 } }));
  assert.equal(v.ok, true);
  assert.deepEqual(v.value.body.intrusion, { exit_s: 20, entry_s: 0 });
  const merged = mergeCfgDumpParts([v.value.body, { sensors: [{ id: 'd3', kind: 'door' }], actuators: [] }]);
  assert.deepEqual(merged.intrusion, { exit_s: 20, entry_s: 0 });
  assert.equal(merged.sensors.length, 1);
});

test('cfg_dump: v1.2.0 bicimi (intrusion yok) degismez; nesne olmayan intrusion reddedilir', () => {
  const v = validateEventPayload(dumpPart());
  assert.equal(v.ok, true);
  assert.equal('intrusion' in v.value.body, false);
  assert.deepEqual(Object.keys(mergeCfgDumpParts([v.value.body])), ['policy', 'zones', 'lights', 'sensors', 'actuators']);
  assert.equal(validateEventPayload(dumpPart({ intrusion: [20, 15] })).ok, false);
  assert.equal(validateEventPayload(dumpPart({ intrusion: 20 })).ok, false);
});

test('state.sensors: arm_key yerel kumanda rolu olarak korunur (generic\'e dusmez)', () => {
  assert.ok(CONTROL_KINDS.includes('arm_key'));
  const st = {
    v: 3, uid: 'AHBU-S3-0C00F2', caps: ['safety', 'actuator', 'event', 'cfg', 'intrusion'],
    sensors: [{ id: 'd6', kind: 'arm_key', zone: 0, active: false, ok: true }, { id: 'd3', kind: 'door', zone: 1, active: false, ok: true }],
    safety: { zones: [], arm: { mode: 'off', st: 'idle', ok: true } },
  };
  const out = parseStateSafety(st);
  assert.deepEqual(out.summary.sensors.map((s) => s.kind), ['arm_key', 'door']);
  assert.equal(out.skipped, 0);
});

test('applyPatch kopyasi: flags verilmeyen yeni sensorde firmware varsayilan bayraklari (defaultFlags); v1.2.0 kopyasinda eskisi gibi', () => {
  const { applyPatch } = require('../../src/utils/safety_cfg_patch');
  const v121 = { policy: { on: true, dry_hold_ms: 10000 }, intrusion: { exit_s: 0, entry_s: 0 }, sensors: [], actuators: [] };
  const flagsOf = (doc, kind) => applyPatch(doc, { set: { sensor: { id: 'd5', kind, zone: 1 } } }).sensors[0].flags;
  // firmware 1.2.1 SensorTypes.h defaultFlags: kapi REACT|ENTRY, hareket REACT|AWAY_ONLY, gaz REACT|FAULT_CLOSE, digerleri REACT
  assert.deepEqual(['door', 'window', 'motion', 'gas', 'water'].map((k) => flagsOf(v121, k)), [0x09, 0x01, 0x11, 0x05, 0x01]);
  const v120 = { policy: { on: true, dry_hold_ms: 10000 }, sensors: [], actuators: [] };
  assert.deepEqual(['door', 'motion', 'gas'].map((k) => flagsOf(v120, k)), [0x01, 0x01, 0x05]);
  assert.equal(applyPatch(v121, { set: { sensor: { id: 'd5', kind: 'door', zone: 1, flags: 1 } } }).sensors[0].flags, 1);
});

test('FIRMWARE_UNSUPPORTED metni gercek hirsiz katmani surumunu (v1.2.1) gosterir', () => {
  const { validatePatchRequest } = require('../../src/utils/safety_cfg_patch');
  for (const set of [{ intrusion: { exit_s: 10 } }, { sensor: { id: 'd6', kind: 'arm_key', zone: 0 } }, { sensor: { id: 'd3', kind: 'door', zone: 1, flags: 9 } }]) {
    const v = validatePatchRequest({ base_rev: 1, set }, { caps: ['safety', 'cfg'] });
    assert.equal(v.ok, false);
    assert.equal(v.code, 'FIRMWARE_UNSUPPORTED');
    assert.match(v.message, /v1\.2\.1'e güncelleyin/);
  }
});
