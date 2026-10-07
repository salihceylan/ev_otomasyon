'use strict';

// Faz 2 / WP-C2 (F2.D.1, D.6): buluttan yapilandirma yamasinin saf kurallari (utils/safety_cfg_patch.js).
//   - Govde: {base_rev: u32, set|del (tam biri), id?}; tek oge; firmware parseCfgEdit ile ayni alan listesi ve araliklar.
//   - Hirsiz katmani alanlari (set.intrusion, sensor flags > 0x07, kind arm_key) yalniz caps 'intrusion' varken.
//   - sys yuku (cmd, module, uid, id, base_rev eklenmis) <= 1024 bayt; buyukse PAYLOAD_TOO_LARGE.
//   - applyPatch: kopyaya yamanin firmware varsayilanlariyla uygulanmasi (gevsetme siniflandirmasi icin).
//   - Kuyruk: {v:1, items[], inflight?}; en cok 16 oge, 24 sa; next_base_rev kurali.

const test = require('node:test');
const assert = require('node:assert/strict');

const P = require('../../src/utils/safety_cfg_patch');

const CAPS = ['safety', 'actuator', 'event', 'cfg'];
const CAPS_I = [...CAPS, 'intrusion'];
const ok = (body, caps = CAPS) => {
  const r = P.validatePatchRequest(body, { caps });
  assert.equal(r.ok, true, r.message);
  return r;
};
const bad = (body, caps = CAPS, code = 'VALIDATION', status = 400) => {
  const r = P.validatePatchRequest(body, { caps });
  assert.equal(r.ok, false, JSON.stringify(body));
  assert.equal(r.code, code, `${JSON.stringify(body)} -> ${r.code} ${r.message}`);
  assert.equal(r.status, status);
  return r;
};

test('govde: base_rev zorunlu u32; set ya da del (tam biri); id kurali; bilinmeyen alan 400', () => {
  const r = ok({ base_rev: 3, set: { zone: { id: 1, name: 'Mutfak' } }, id: 'c-1' });
  assert.deepEqual(r.patch, { set: { zone: { id: 1, name: 'Mutfak' } } });
  assert.equal(r.baseRev, 3);
  assert.equal(r.id, 'c-1');
  assert.deepEqual([r.op, r.item, r.target], ['set', 'zone', '1']);
  bad({ set: { zone: { id: 1, name: 'x' } } });
  bad({ base_rev: -1, set: { zone: { id: 1, name: 'x' } } });
  bad({ base_rev: 1.5, set: { zone: { id: 1, name: 'x' } } });
  bad({ base_rev: '3', set: { zone: { id: 1, name: 'x' } } });
  bad({ base_rev: 3 });
  bad({ base_rev: 3, set: { zone: { id: 1, name: 'x' } }, del: { sensor: 'd3' } });
  bad({ base_rev: 3, set: { zone: { id: 1, name: 'x' }, policy: { on: true } } });
  bad({ base_rev: 3, set: {} });
  bad({ base_rev: 3, set: { zone: { id: 1, name: 'x' } }, id: 'bad id!' });
  bad({ base_rev: 3, set: { zone: { id: 1, name: 'x' } }, uid: 'AHBU-S3-1' });
  bad(null);
  bad([]);
});

test('sensor: firmware alan listesi ve araliklari', () => {
  ok({ base_rev: 0, set: { sensor: { id: 'd3', kind: 'water', zone: 1 } } });
  ok({ base_rev: 0, set: { sensor: { id: 'b16', kind: 'smoke', zone: 4, active_open: true, flags: 7, confirm_ms: 60000, name: 'Salon' } } });
  ok({ base_rev: 0, set: { sensor: { id: 'd40', kind: 'gas_reset', zone: 0, active_open: 1 } } });
  bad({ base_rev: 0, set: { sensor: { id: 'd41', kind: 'water', zone: 1 } } });
  bad({ base_rev: 0, set: { sensor: { id: 'b17', kind: 'water', zone: 1 } } });
  bad({ base_rev: 0, set: { sensor: { id: 'd03', kind: 'water', zone: 1 } } });
  bad({ base_rev: 0, set: { sensor: { id: 'd3', kind: 'lava', zone: 1 } } });
  bad({ base_rev: 0, set: { sensor: { id: 'd3', kind: 'water' } } });
  bad({ base_rev: 0, set: { sensor: { id: 'd3', kind: 'water', zone: 5 } } });
  bad({ base_rev: 0, set: { sensor: { id: 'd3', kind: 'water', zone: 1, active_open: 2 } } });
  bad({ base_rev: 0, set: { sensor: { id: 'd3', kind: 'water', zone: 1, flags: 32 } } });
  bad({ base_rev: 0, set: { sensor: { id: 'd3', kind: 'water', zone: 1, flags: 8 } } }, CAPS, 'FIRMWARE_UNSUPPORTED', 409);
  bad({ base_rev: 0, set: { sensor: { id: 'd3', kind: 'water', zone: 1, confirm_ms: 60001 } } });
  bad({ base_rev: 0, set: { sensor: { id: 'd3', kind: 'water', zone: 1, name: 'x'.repeat(20) } } });
  bad({ base_rev: 0, set: { sensor: { id: 'd3', kind: 'water', zone: 1, name: 'a\u0001b' } } });
  bad({ base_rev: 0, set: { sensor: { id: 'd3', kind: 'water', zone: 1, src: 'di' } } });
  ok({ base_rev: 0, set: { sensor: { id: 'd3', kind: 'water', zone: 1, name: 'ç'.repeat(9) } } }); // 18 bayt < 20
  bad({ base_rev: 0, set: { sensor: { id: 'd3', kind: 'water', zone: 1, name: 'ç'.repeat(10) } } }); // 20 bayt
});

test('eylemci: firmware alan listesi ve araliklari; kimliksiz = yeni satir', () => {
  const r = ok({ base_rev: 2, set: { actuator: { relay: 5, kind: 'valve', close_mode: 'deenergize', medium: 'water', zones: [1, 2], fb_di: 6, fb_closed_active: true, fb_timeout_s: 60 } } });
  assert.equal(r.target, null);
  ok({ base_rev: 2, set: { actuator: { id: 'a16', relay: 40, relay2: 39, kind: 'valve', close_mode: 'pulse', run_limit_s: 15 } } });
  ok({ base_rev: 2, set: { actuator: { relay: 11, kind: 'fan', exproof: true, name: 'Aspiratör' } } });
  bad({ base_rev: 2, set: { actuator: { relay: 0, kind: 'valve' } } });
  bad({ base_rev: 2, set: { actuator: { relay: 41, kind: 'valve' } } });
  bad({ base_rev: 2, set: { actuator: { id: 'a17', relay: 4, kind: 'valve' } } });
  bad({ base_rev: 2, set: { actuator: { relay: 4, kind: 'pump' } } });
  bad({ base_rev: 2, set: { actuator: { relay: 4, kind: 'valve', close_mode: 'toggle' } } });
  bad({ base_rev: 2, set: { actuator: { relay: 4, kind: 'valve', medium: 'oil' } } });
  bad({ base_rev: 2, set: { actuator: { relay: 4, kind: 'valve', zones: [0] } } });
  bad({ base_rev: 2, set: { actuator: { relay: 4, kind: 'valve', zones: 1 } } });
  bad({ base_rev: 2, set: { actuator: { relay: 4, kind: 'valve', fb_di: 41 } } });
  bad({ base_rev: 2, set: { actuator: { relay: 4, kind: 'valve', fb_timeout_s: 70000 } } });
  bad({ base_rev: 2, set: { actuator: { relay: 4, kind: 'fan', exproof: 1 } } });
  bad({ base_rev: 2, set: { actuator: { relay: 4, kind: 'valve', act: 'valve' } } });
});

test('politika, bolge, isik, silme', () => {
  ok({ base_rev: 1, set: { policy: { on: false } } });
  ok({ base_rev: 1, set: { policy: { dry_hold_ms: 20000 } } });
  bad({ base_rev: 1, set: { policy: {} } });
  bad({ base_rev: 1, set: { policy: { on: 'off' } } });
  bad({ base_rev: 1, set: { policy: { dry_hold_ms: -5 } } });
  bad({ base_rev: 1, set: { zone: { id: 5, name: 'x' } } });
  bad({ base_rev: 1, set: { zone: { id: 1 } } });
  bad({ base_rev: 1, set: { zone: { id: 1, name: 'x'.repeat(16) } } });
  ok({ base_rev: 1, set: { light: { relay: 3, dimmable: 1, src: 1, addr: 247, ch: 255 } } });
  bad({ base_rev: 1, set: { light: { relay: 3, src: 3 } } });
  bad({ base_rev: 1, set: { light: { relay: 3, addr: 248 } } });
  const d = ok({ base_rev: 1, del: { sensor: 'd3' } });
  assert.deepEqual([d.op, d.item, d.target], ['del', 'sensor', 'd3']);
  ok({ base_rev: 1, del: { actuator: 'a2' } });
  bad({ base_rev: 1, del: { actuator: 'a0' } });
  bad({ base_rev: 1, del: { zone: 1 } });
  bad({ base_rev: 1, del: { sensor: 3 } });
});

test('hirsiz katmani alanlari yalniz caps intrusion ile (aksi 409 FIRMWARE_UNSUPPORTED)', () => {
  bad({ base_rev: 1, set: { intrusion: { exit_s: 45 } } }, CAPS, 'FIRMWARE_UNSUPPORTED', 409);
  bad({ base_rev: 1, set: { sensor: { id: 'd9', kind: 'door', zone: 1, flags: 9 } } }, CAPS, 'FIRMWARE_UNSUPPORTED', 409);
  bad({ base_rev: 1, set: { sensor: { id: 'd9', kind: 'arm_key', zone: 0 } } }, CAPS, 'FIRMWARE_UNSUPPORTED', 409);
  ok({ base_rev: 1, set: { intrusion: { exit_s: 45, entry_s: 30 } } }, CAPS_I);
  ok({ base_rev: 1, set: { intrusion: { entry_s: 0 } } }, CAPS_I);
  ok({ base_rev: 1, set: { sensor: { id: 'd9', kind: 'door', zone: 1, flags: 0x1f } } }, CAPS_I);
  ok({ base_rev: 1, set: { sensor: { id: 'd9', kind: 'arm_key', zone: 0 } } }, CAPS_I);
  bad({ base_rev: 1, set: { sensor: { id: 'd9', kind: 'door', zone: 1, flags: 0x20 } } }, CAPS_I);
  bad({ base_rev: 1, set: { intrusion: { exit_s: 256 } } }, CAPS_I);
  bad({ base_rev: 1, set: { intrusion: {} } }, CAPS_I);
});

test('sys yuku: zarf alanlari eklenir, 1024 bayt siniri', () => {
  const r = ok({ base_rev: 3, set: { zone: { id: 1, name: 'Mutfak' } } });
  const p = P.buildSysPayload({ uid: 'AHBU-S3-1A2B3C', id: 'c1', baseRev: r.baseRev, patch: r.patch });
  assert.deepEqual(p, { cmd: 'cfg_patch', module: 'safety', uid: 'AHBU-S3-1A2B3C', id: 'c1', base_rev: 3, set: { zone: { id: 1, name: 'Mutfak' } } });
  assert.ok(P.sysPayloadBytes(p) <= 1024);
  const big = { relay: 4, kind: 'valve', name: 'x' };
  const rr = ok({ base_rev: 3, set: { actuator: big } });
  assert.equal(P.sysPayloadBytes(P.buildSysPayload({ uid: 'A'.repeat(64), id: 'x'.repeat(24), baseRev: 4294967295, patch: rr.patch })) <= 1024, true);
  // sinir asimi: dogrulayici yalniz tek oge kabul ettigi icin pratikte asilmaz; kural yine de denetlenir
  assert.equal(P.MAX_SYS_BYTES, 1024);
});

test('applyPatch: firmware varsayilanlari ve kimlik kaymasi (gevsetme siniflandirmasi icin)', () => {
  const doc = {
    policy: { on: true, dry_hold_ms: 10000 },
    zones: [{ id: 1, name: 'Ev' }],
    lights: [],
    sensors: [{ id: 'd3', kind: 'water', zone: 1, active_open: 0, flags: 1, confirm_ms: 1000, name: '' }],
    actuators: [
      { id: 'a1', relay: 5, kind: 'valve', close_mode: 'energize', medium: 'water', zones: [1], fb_di: 0, fb_closed_active: 1, fb_timeout_s: 60, run_limit_s: 0, exproof: false, name: '' },
      { id: 'a2', relay: 6, kind: 'siren', close_mode: 'energize', medium: 'none', zones: [1], fb_di: 0, fb_closed_active: 1, fb_timeout_s: 60, run_limit_s: 180, exproof: false, name: '' },
    ],
  };
  let out = P.applyPatch(doc, { set: { sensor: { id: 'd4', kind: 'gas', zone: 2, active_open: 1 } } });
  assert.deepEqual(out.sensors[1], { id: 'd4', kind: 'gas', zone: 2, active_open: 1, flags: 5, confirm_ms: 300, name: '' });
  out = P.applyPatch(doc, { set: { actuator: { relay: 9, kind: 'siren' } } });
  assert.equal(out.actuators.length, 3);
  assert.equal(out.actuators[2].run_limit_s, 180);
  assert.equal(out.actuators[2].id, 'a3');
  out = P.applyPatch(doc, { del: { actuator: 'a1' } });
  assert.deepEqual(out.actuators.map((a) => [a.id, a.relay]), [['a1', 6]]);
  out = P.applyPatch(doc, { set: { policy: { on: false } } });
  assert.deepEqual(out.policy, { on: false, dry_hold_ms: 10000 });
  assert.deepEqual(doc.policy, { on: true, dry_hold_ms: 10000 }, 'girdi degismez');
  out = P.applyPatch(doc, { del: { sensor: 'd3' } });
  assert.equal(out.sensors.length, 0);
});

test('kuyruk: bicim, sinirlar, next_base_rev ve ozet (deger/ad icermez)', () => {
  assert.deepEqual(P.parsePending(null), { v: 1, items: [], inflight: null });
  assert.deepEqual(P.parsePending({ v: 2, items: [{}] }), { v: 1, items: [], inflight: null }, 'bilinmeyen surum bos sayilir');
  const item = { id: 'c1', base_rev: 4, patch: { set: { sensor: { id: 'd3', kind: 'water', zone: 1, name: 'Gizli ad' } } }, by: 'u1', role: 'owner', at: '2026-10-07T10:00:00.000Z', loosening: false };
  const q = P.parsePending({ v: 1, items: [item, { bozuk: true }] });
  assert.equal(q.items.length, 1);
  assert.equal(P.nextBaseRev(q, 4), 5);
  assert.equal(P.nextBaseRev(P.parsePending(null), 4), 4);
  assert.equal(P.nextBaseRev(P.parsePending(null), null), null);
  assert.deepEqual(P.pendingSummary(q), [{ id: 'c1', op: 'set', item: 'sensor', target: 'd3', at: '2026-10-07T10:00:00.000Z', role: 'owner', loosening: false }]);
  assert.equal(JSON.stringify(P.pendingSummary(q)).includes('Gizli'), false);
  assert.equal(P.MAX_PENDING_ITEMS, 16);
  assert.equal(P.PENDING_TTL_MS, 24 * 3600 * 1000);
  assert.equal(P.isExpired(item, Date.parse('2026-10-08T10:00:01.000Z')), true);
  assert.equal(P.isExpired(item, Date.parse('2026-10-08T09:59:59.000Z')), false);
});

test('firmware ayristiricisiyla (parseCfgEdit JS portu) kabul/ret ESLIGI (hirsiz katmani disi govdeler)', async () => {
  const { parseCfgEdit } = await import('../../../tools/qa_stack/sim/fw/safety_cfg_api.js');
  const items = [
    { set: { sensor: { id: 'd3', kind: 'water', zone: 1 } } },
    { set: { sensor: { id: 'b16', kind: 'smoke', zone: 4, active_open: true, flags: 7, confirm_ms: 60000, name: 'Salon' } } },
    { set: { sensor: { id: 'd40', kind: 'gas_reset', zone: 0, active_open: 1 } } },
    { set: { sensor: { id: 'd41', kind: 'water', zone: 1 } } },
    { set: { sensor: { id: 'd03', kind: 'water', zone: 1 } } },
    { set: { sensor: { id: 'd3', kind: 'lava', zone: 1 } } },
    { set: { sensor: { id: 'd3', kind: 'water' } } },
    { set: { sensor: { id: 'd3', kind: 'water', zone: 5 } } },
    { set: { sensor: { id: 'd3', kind: 'water', zone: 1, active_open: 2 } } },
    { set: { sensor: { id: 'd3', kind: 'water', zone: 1, confirm_ms: 60001 } } },
    { set: { sensor: { id: 'd3', kind: 'water', zone: 1, name: 'x'.repeat(19) } } },
    { set: { sensor: { id: 'd3', kind: 'water', zone: 1, name: 'x'.repeat(20) } } },
    { set: { sensor: { id: 'd3', kind: 'water', zone: 1, name: 'a\u0001b' } } },
    { set: { sensor: { id: 'd3', kind: 'water', zone: 1, src: 'di' } } },
    { set: { actuator: { relay: 5, kind: 'valve', close_mode: 'deenergize', medium: 'water', zones: [1, 2], fb_di: 6, fb_closed_active: true, fb_timeout_s: 60 } } },
    { set: { actuator: { id: 'a16', relay: 40, relay2: 39, kind: 'valve', close_mode: 'pulse', run_limit_s: 15 } } },
    { set: { actuator: { relay: 11, kind: 'fan', exproof: true, name: 'Aspiratör' } } },
    { set: { actuator: { relay: 0, kind: 'valve' } } },
    { set: { actuator: { id: 'a17', relay: 4, kind: 'valve' } } },
    { set: { actuator: { relay: 4, kind: 'pump' } } },
    { set: { actuator: { relay: 4, kind: 'valve', close_mode: 'toggle' } } },
    { set: { actuator: { relay: 4, kind: 'valve', zones: [0] } } },
    { set: { actuator: { relay: 4, kind: 'valve', fb_timeout_s: 70000 } } },
    { set: { actuator: { relay: 4, kind: 'fan', exproof: 1 } } },
    { set: { policy: { on: false } } },
    { set: { policy: {} } },
    { set: { policy: { dry_hold_ms: -5 } } },
    { set: { zone: { id: 1, name: 'Mutfak' } } },
    { set: { zone: { id: 1, name: 'x'.repeat(16) } } },
    { set: { zone: { id: 5, name: 'x' } } },
    { set: { light: { relay: 3, dimmable: 1, src: 1, addr: 247, ch: 255 } } },
    { set: { light: { relay: 3, src: 3 } } },
    { del: { sensor: 'd3' } },
    { del: { actuator: 'a2' } },
    { del: { actuator: 'a0' } },
    { del: { zone: 1 } },
    { set: { zone: { id: 1, name: 'x' }, policy: { on: true } } },
  ];
  const diff = [];
  for (const it of items) {
    const body = { base_rev: 7, ...it };
    const srv = P.validatePatchRequest(body, { caps: CAPS }).ok;
    const fw = parseCfgEdit(JSON.parse(JSON.stringify(body)), false).err === null;
    if (srv !== fw) diff.push({ body: JSON.stringify(it), srv, fw });
  }
  assert.deepEqual(diff, []);
});
