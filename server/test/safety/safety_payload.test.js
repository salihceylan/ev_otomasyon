'use strict';

// WP-S2 - state v:3 guvenlik eklerinin ve ev/{t}/event yukunun ayristirilmasi (tasarim §3.1-§3.4).
//   - v:2 yuku (caps yok): summary null, caps null -> "guvenlik desteklemiyor".
//   - v:3 ornegi (§3.2) birebir ozetlenir; sinirlar: sensors <= 56, actuators <= 16, zones <= 4 [D6].
//   - Bozuk ogeler atlanir ve sayilir (firlatmaz); bilinmeyen alanlar yok sayilir.
//   - Olay: katı dogrulama; uid + eid (<bn>-<n>) zorunlu; bilinmeyen tur "unknown" (gunluk + ack, islem yok).

const test = require('node:test');
const assert = require('node:assert/strict');

const P = require('../../src/utils/safety_payload');

const UID = 'AHBU-S3-1A2B3C';

function v3() {
  return {
    v: 3, uid: UID, fw: '1.2.0', seq: 1240, uptime: 3600, ip: '192.168.1.30', child_lock: false, last_id: 'c81f',
    caps: ['safety', 'actuator', 'event', 'cfg'],
    boot: 57, bn: '9f3a11c0', time_ok: true, epoch: 1791273600,
    cfg: { safety: { rev: 12, crc: '9a3c11f0' } },
    last_rej: { id: 'c820', code: 'zone_latched' },
    relays: [
      { id: 5, name: 'Ana Su Vanası', type: 'light', state: false, act: 'valve' },
      { id: 6, name: 'Siren', type: 'light', state: false, act: 'siren' },
    ],
    shutters: [], dis: [{ id: 3, state: true }],
    sensors: [
      { id: 'd3', src: 'di', kind: 'water', zone: 1, active: true, ok: true },
      { id: 'b1', src: 'bridge', kind: 'water', zone: 1, active: false, ok: false },
    ],
    actuators: [
      { id: 'a1', relay: 5, kind: 'valve', medium: 'water', zones: [1], pos: 'closed', fb: true, fault: false },
      { id: 'a2', relay: 6, kind: 'siren', zones: [1], on: true, fault: false },
    ],
    safety: {
      policy: 'on', mode: 'normal',
      zones: [{ id: 1, st: 'latched', kind: 'water', aid: '9f3a11c0-3', since: 1791273000, since_up: 3000, silenced: false, srcs: ['d3'] }],
    },
  };
}

test('v:2 yuku: caps yok -> desteklenmiyor; ozet null; hicbir alan atlanmaz', () => {
  const r = P.parseStateSafety({ v: 2, uid: UID, relays: [{ id: 1, state: true }], shutters: [] });
  assert.equal(r.caps, null);
  assert.equal(r.summary, null);
  assert.equal(r.supported, false);
  assert.equal(r.skipped, 0);
});

test('v:3 ornegi (§3.2) birebir ozetlenir', () => {
  const r = P.parseStateSafety(v3());
  assert.deepEqual(r.caps, ['safety', 'actuator', 'event', 'cfg']);
  assert.equal(r.supported, true);
  assert.equal(r.skipped, 0);
  assert.deepEqual(r.lastRej, { id: 'c820', code: 'zone_latched' });
  assert.deepEqual(r.summary, {
    v: 1,
    state_v: 3,
    present: true,
    policy: 'on',
    mode: 'normal',
    boot: 57,
    bn: '9f3a11c0',
    time_ok: true,
    cfg: { rev: 12, crc: '9a3c11f0' },
    last_rej: { id: 'c820', code: 'zone_latched' },
    zones: [{ id: 1, st: 'latched', kind: 'water', aid: '9f3a11c0-3', silenced: false, since: 1791273000, since_up: 3000, srcs: ['d3'] }],
    zones_complete: true,
    actuators: [
      { id: 'a1', relay: 5, kind: 'valve', medium: 'water', zones: [1], pos: 'closed', on: null, fb: true, fault: false },
      { id: 'a2', relay: 6, kind: 'siren', medium: null, zones: [1], pos: null, on: true, fb: null, fault: false },
    ],
    sensors: [
      { id: 'd3', src: 'di', kind: 'water', zone: 1, active: true, ok: true },
      { id: 'b1', src: 'bridge', kind: 'water', zone: 1, active: false, ok: false },
    ],
    arm: null, // Faz 2 F2.B.7: hirsiz alarmi kipi yok (safety.arm anahtari yok)
  });
});

test('caps var ama safety anahtari yok: present=false (yapilandirilmamis/bozuk); caps safety icermiyorsa supported=false', () => {
  const s = v3();
  delete s.safety;
  const r = P.parseStateSafety(s);
  assert.equal(r.supported, true);
  assert.equal(r.summary.present, false);
  assert.equal(r.summary.mode, null);
  assert.deepEqual(r.summary.zones, []);
  const s2 = v3();
  s2.caps = ['event'];
  assert.equal(P.parseStateSafety(s2).supported, false);
});

test('sinirlar ve bozuk ogeler: sensors <= 56, actuators <= 16, zones <= 4; bozuk oge atlanir ve sayilir', () => {
  const s = v3();
  s.sensors = Array.from({ length: 60 }, (_, i) => ({ id: i < 40 ? `d${i + 1}` : `b${i - 39}`, src: i < 40 ? 'di' : 'bridge', kind: 'water', zone: 1, active: false, ok: true }));
  s.actuators = Array.from({ length: 18 }, (_, i) => ({ id: `a${(i % 16) + 1}`, relay: 1, kind: 'generic', zones: [1], on: false, fault: false }));
  s.safety.zones = [
    { id: 1, st: 'normal' }, { id: 2, st: 'bogus' }, { id: 9, st: 'latched' }, 'x', { id: 3, st: 'fault', aid: 'NOPE' },
    { id: 4, st: 'test' },
  ];
  s.caps = ['safety', 'x'.repeat(20), 5];
  const r = P.parseStateSafety(s);
  assert.equal(r.summary.sensors.length, 56);
  assert.equal(r.summary.actuators.length, 16);
  assert.deepEqual(r.summary.zones.map((z) => [z.id, z.st, z.aid]), [[1, 'normal', null], [3, 'fault', null], [4, 'test', null]]);
  assert.deepEqual(r.caps, ['safety']);
  assert.ok(r.skipped >= 4 + 2 + 2 + 2, `skipped=${r.skipped}`);
});

test('bilinmeyen eylemci/sensor turu "unknown"/"generic" olur, firlatmaz; kimliksiz oge atlanir', () => {
  const s = v3();
  s.actuators.push({ id: 'a3', relay: 7, kind: 'pump', zones: [1] }, { relay: 8, kind: 'valve' });
  s.sensors.push({ id: 'd9', src: 'di', kind: 'lava', zone: 1, active: false, ok: true }, { src: 'di' });
  const r = P.parseStateSafety(s);
  assert.equal(r.summary.actuators.find((a) => a.id === 'a3').kind, 'generic');
  assert.equal(r.summary.sensors.find((x) => x.id === 'd9').kind, 'generic');
  assert.equal(r.summary.actuators.length, 3);
  assert.equal(r.summary.sensors.length, 3);
});

// ------------------------------------------------------------------------------
// Olay yuku
// ------------------------------------------------------------------------------
function ev(over = {}) {
  return {
    v: 1, uid: UID, eid: '9f3a11c0-3', bn: '9f3a11c0', boot: 57, n: 3,
    type: 'alarm_raised', zone: 1, kind: 'water', srcs: ['d3'],
    at: 1791273000, at_up: 3000, actions: [{ a: 'a1', do: 'close' }, { a: 'a2', do: 'on' }],
    ...over,
  };
}

test('olay: §3.4 ornegi gecerli; uid buyuk harfe, eid kucuk harfe normalize', () => {
  const r = P.validateEventPayload(ev({ uid: 'ahbu-s3-1a2b3c', eid: '9F3A11C0-3' }));
  assert.equal(r.ok, true, r.reason);
  assert.equal(r.value.uid, UID);
  assert.equal(r.value.eid, '9f3a11c0-3');
  assert.equal(r.value.type, 'alarm_raised');
  assert.equal(r.value.zone, 1);
  assert.equal(r.value.kind, 'water');
  assert.deepEqual(r.value.srcs, ['d3']);
  assert.equal(r.value.at, 1791273000);
  assert.equal(r.value.aid, '9f3a11c0-3', 'alarm_raised: alarm kimligi olayin kendi eid\'si');
  assert.equal(r.value.unknown, false);
});

test('olay: uid / eid zorunlu ve bicimli; kok nesne; alarm turlerinde zone zorunlu', () => {
  for (const bad of [
    null, [], 'x',
    ev({ uid: undefined }), ev({ uid: 'x' }),
    ev({ eid: undefined }), ev({ eid: 'b57-3' }), ev({ eid: '9f3a11c0-123456' }),
    ev({ type: 5 }), ev({ zone: 0 }), ev({ zone: 5 }), ev({ zone: undefined }),
    ev({ type: 'alarm_cleared', zone: undefined }),
  ]) {
    assert.equal(P.validateEventPayload(bad).ok, false, JSON.stringify(bad));
  }
});

test('olay: diger alarm turleri aid tasiyabilir (yoksa null); bilinmeyen tur unknown=true (islem yok, ack var)', () => {
  const c = P.validateEventPayload(ev({ type: 'alarm_cleared', eid: '9f3a11c0-9', aid: '9f3a11c0-3' }));
  assert.equal(c.ok, true);
  assert.equal(c.value.aid, '9f3a11c0-3');
  const f = P.validateEventPayload(ev({ type: 'valve_fault', eid: '9f3a11c0-4', aid: undefined }));
  assert.equal(f.value.aid, null);
  const u = P.validateEventPayload(ev({ type: 'future_thing', zone: undefined }));
  assert.equal(u.ok, true);
  assert.equal(u.value.unknown, true);
  const p = P.validateEventPayload({ v: 1, uid: UID, eid: '9f3a11c0-7', type: 'policy_changed', policy: 'off', via: 'lan' });
  assert.equal(p.ok, true);
  assert.equal(p.value.policy, 'off');
  assert.equal(p.value.via, 'lan');
});

test('olay: srcs <= 8, actions <= 16; bozuk dizi ogeleri atlanir', () => {
  const r = P.validateEventPayload(ev({
    srcs: ['d1', 'd2', 'd3', 'd4', 'd5', 'd6', 'd7', 'd8', 'd9', 'zz', 7],
    actions: Array.from({ length: 20 }, (_, i) => ({ a: `a${(i % 16) + 1}`, do: 'close' })).concat([{ a: 'q', do: 'x' }]),
  }));
  assert.equal(r.ok, true);
  assert.equal(r.value.srcs.length, 8);
  assert.equal(r.value.actions.length, 16);
});

test('cfg_dump: olay hattina girmez, ayri sonuc doner (parca bilgisiyle)', () => {
  const r = P.validateEventPayload({ v: 1, uid: UID, type: 'cfg_dump', module: 'safety', rev: 12, crc: '9a3c11f0', part: 1, parts: 2, body: { a: 1 } });
  assert.equal(r.ok, true);
  assert.equal(r.value.cfgDump, true);
  assert.equal(r.value.module, 'safety');
  assert.equal(r.value.part, 1);
  assert.equal(r.value.parts, 2);
  assert.equal(P.validateEventPayload({ v: 1, uid: UID, type: 'cfg_dump', module: 'safety', rev: 12, crc: 'zz', part: 1, parts: 1, body: {} }).ok, false);
});

test('cfg_dump: firmware v1.2.0 bicimi (oge dizileri kokte, body YOK) kabul edilir; parcalar tek belgeye birlesir', () => {
  const part1 = {
    v: 1, uid: UID, type: 'cfg_dump', module: 'safety', rev: 7, crc: '9A3C11F0', part: 1, parts: 2,
    policy: { on: true, dry_hold_ms: 10000 }, zones: [{ id: 1, name: 'Mutfak' }], lights: [],
    sensors: [{ id: 'd3', kind: 'water', zone: 1, active_open: 0, flags: 3, confirm_ms: 3000, name: 'Evye alti' }], actuators: [],
  };
  const part2 = { v: 1, uid: UID, type: 'cfg_dump', module: 'safety', rev: 7, crc: '9a3c11f0', part: 2, parts: 2, sensors: [],
    actuators: [{ id: 'a1', relay: 5, kind: 'valve', close_mode: 'deenergize', medium: 'water', zones: [1], fb_di: 0, fb_closed_active: 1, fb_timeout_s: 30, run_limit_s: 0, exproof: false, name: 'Ana vana' }] };
  const r1 = P.validateEventPayload(part1);
  const r2 = P.validateEventPayload(part2);
  assert.equal(r1.ok, true);
  assert.equal(r2.ok, true);
  assert.equal(r1.value.crc, '9a3c11f0');
  assert.deepEqual(Object.keys(r1.value.body).sort(), ['actuators', 'lights', 'policy', 'sensors', 'zones']);
  const merged = P.mergeCfgDumpParts([r1.value.body, r2.value.body]);
  assert.deepEqual(merged.policy, { on: true, dry_hold_ms: 10000 });
  assert.equal(merged.sensors[0].name, 'Evye alti');
  assert.equal(merged.actuators[0].name, 'Ana vana');
  assert.deepEqual(merged.zones, [{ id: 1, name: 'Mutfak' }]);
  // sensors/actuators dizisi yoksa ya da bicimsizse reddedilir
  const { sensors, ...noSensors } = part2;
  assert.equal(Array.isArray(sensors), true);
  assert.equal(P.validateEventPayload(noSensors).ok, false);
  assert.equal(P.validateEventPayload({ ...part2, zones: 'x' }).ok, false);
  // eski kayit bicimi {parts:[...]} de duzlestirilir
  assert.equal(P.mergeCfgDumpParts([{ parts: [r1.value.body, r2.value.body] }]).actuators.length, 1);
});

test('state: yerel kumanda rolleri (alarm_ack/valve_close/gas_reset) sensor turu olarak korunur', () => {
  const r = P.parseStateSafety({ v: 3, caps: ['safety'], sensors: [{ id: 'd8', src: 'di', kind: 'alarm_ack', zone: 1, active: false, ok: true }] });
  assert.equal(r.summary.sensors[0].kind, 'alarm_ack');
});

// Inceleme turu 2 RV2-1: zones[] eksik/bozuk gelirse (dizi degil, bilinmeyen durum, gecersiz oge, sinir asimi) listede olmayan bolge
// "normal" sayilamaz: ozet zones_complete=false tasir ve alarm uzlastirmasi o bolgelere dokunmaz.
test('state: zones_complete -- dizi degilse ya da oge dusurulduyse false; anahtar yoksa ya da tam ise true', () => {
  assert.equal(P.parseStateSafety(v3()).summary.zones_complete, true);
  let s = v3();
  s.safety.zones = [];
  assert.equal(P.parseStateSafety(s).summary.zones_complete, true);
  s = v3();
  delete s.safety.zones;
  assert.equal(P.parseStateSafety(s).summary.zones_complete, true, 'anahtar yok = bolgelerin hepsi normal (sozlesme)');
  s = v3();
  s.safety.zones = { 1: 'latched' };
  assert.equal(P.parseStateSafety(s).summary.zones_complete, false, 'dizi degil');
  s = v3();
  s.safety.zones = [{ id: 1, st: 'latched', aid: '9f3a11c0-3' }, { id: 2, st: 'alarm', aid: '9f3a11c0-4' }];
  const r = P.parseStateSafety(s);
  assert.deepEqual(r.summary.zones.map((z) => z.id), [1]);
  assert.equal(r.summary.zones_complete, false, 'bilinmeyen durum (ileri surum) dusuruldu');
  s = v3();
  s.safety.zones = [{ id: 1, st: 'normal' }, 'x'];
  assert.equal(P.parseStateSafety(s).summary.zones_complete, false, 'gecersiz oge');
  s = v3();
  delete s.safety;
  assert.equal(P.parseStateSafety(s).summary.zones_complete, false, 'safety yok: bolge bilgisi yok');
});
