'use strict';

// WP-S2/S4 - Kopru guvenlik kancalari (tasarim §3.1 kural 5, §3.4, §5.2.2, §5.2.4):
//   - ev/+/event aboneligi ve event dali: retained yok sayilir, 4 KB siniri, katı dogrulama, uid evin cihazi olmali,
//     cfg_dump ayri hatta, coalesce:false (ardisik iki olay da islenir).
//   - state v:3: caps + safety_state yazilir (ayni UPDATE, ek sorgu yok); COMMIT sonrasi alarm servisi bilgilendirilir.
//     v:2 (caps yok, onceden de yok): SQL ve sorgu sayisi BIREBIR eskisi gibi, alarm servisi CAGRILMAZ.
//     Eski firmware'e donus (caps yok ama onceden vardi): caps/safety_state NULL + alarm servisi (lost).
//   - Ret yankisi [Y5]: last_rej yalniz hedef uid'nin state'inden kabul edilir; last_id onaydir.

const test = require('node:test');
const assert = require('node:assert/strict');

const { MqttBridge, helpers, constants } = require('../../src/mqtt_bridge');
const { makeFakeDb, makeLogger } = require('../bridge/_helpers');

const TOPIC = 'h_0123456789abcdef';
const HOME_ID = '11111111-1111-4111-8111-111111111111';
const UID = 'AHBU-S3-A1B2C3';
const UID_B = 'AHBU-S3-0F0F0F';
const DEV = { home_id: HOME_ID, device_id: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', device_uuid: UID, has_caps: false, safety_state: null };
const DEV_B = { home_id: HOME_ID, device_id: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', device_uuid: UID_B, has_caps: false, safety_state: null };
const RESOLVE_RE = /FROM homes h LEFT JOIN devices d/;

function spyAlarms() {
  const spy = {
    events: [], dumps: [], live: [],
    async handleEvent(evt) { spy.events.push(evt); return { status: 'applied' }; },
    async handleCfgDump(evt) { spy.dumps.push(evt); return { status: 'stored' }; },
    async onLiveState(evt) { spy.live.push(evt); return { status: 'applied' }; },
    stop() {},
  };
  return spy;
}

function setup({ homeRows = [DEV], alarms = spyAlarms() } = {}) {
  const db = makeFakeDb([
    { match: RESOLVE_RE, reply: (_t, p) => (p[0] === TOPIC ? { rows: homeRows, rowCount: homeRows.length } : { rows: [], rowCount: 0 }) },
  ]);
  const logger = makeLogger();
  const bridge = new MqttBridge({ db, logger, env: {}, now: () => 1_800_000_000_000, alarmService: alarms });
  return { bridge, db, logger, alarms };
}

function v3state(over = {}) {
  return {
    v: 3, uid: UID, fw: '1.2.0', last_id: 'c81f', child_lock: false,
    caps: ['safety', 'actuator', 'event', 'cfg'], boot: 57, bn: '9f3a11c0', time_ok: false,
    cfg: { safety: { rev: 12, crc: '9a3c11f0' } },
    relays: [{ id: 1, state: false, type: 'light', name: 'X', act: 'valve' }], shutters: [],
    actuators: [{ id: 'a1', relay: 1, kind: 'valve', medium: 'water', zones: [1], pos: 'closed', fb: null, fault: false }],
    sensors: [{ id: 'd3', src: 'di', kind: 'water', zone: 1, active: true, ok: true }],
    safety: { policy: 'on', mode: 'normal', zones: [{ id: 1, st: 'latched', kind: 'water', aid: '9f3a11c0-3', silenced: false, srcs: ['d3'] }] },
    ...over,
  };
}

function ev(over = {}) {
  return { v: 1, uid: UID, eid: '9f3a11c0-3', type: 'alarm_raised', zone: 1, kind: 'water', srcs: ['d3'], at_up: 10, ...over };
}

test('abonelik ve konu: ev/+/event eklendi; event konusu taninir', () => {
  assert.deepEqual([...constants.SUBSCRIPTIONS], ['ev/+/status', 'ev/+/state', 'ev/+/event']);
  assert.deepEqual(helpers.parseIncomingTopic(`ev/${TOPIC}/event`), { topicId: TOPIC, kind: 'event' });
  assert.equal(constants.MAX_EVENT_BYTES, 4096);
});

test('event: gecerli olay alarm servisine cihaz cozulmus olarak gider; ardisik iki olay da islenir (coalesce yok)', async () => {
  const { bridge, alarms } = setup({ homeRows: [DEV, DEV_B] });
  await Promise.all([
    bridge.handleIncomingMessage(`ev/${TOPIC}/event`, JSON.stringify(ev())),
    bridge.handleIncomingMessage(`ev/${TOPIC}/event`, JSON.stringify(ev({ eid: '9f3a11c0-4', type: 'valve_fault', aid: '9f3a11c0-3' }))),
  ]);
  assert.equal(alarms.events.length, 2);
  assert.deepEqual(alarms.events.map((e) => e.event.eid), ['9f3a11c0-3', '9f3a11c0-4']);
  const e0 = alarms.events[0];
  assert.equal(e0.topicId, TOPIC);
  assert.equal(e0.homeId, HOME_ID);
  assert.equal(e0.deviceId, DEV.device_id);
  assert.equal(e0.uid, UID);
  assert.equal(bridge.counters.event, 2);
});

test('event: retained yok sayilir; 4 KB ustu reddedilir; bozuk JSON / gecersiz yuk / bilinmeyen uid islenmez', async () => {
  const { bridge, alarms } = setup();
  await bridge.handleIncomingMessage(`ev/${TOPIC}/event`, JSON.stringify(ev()), { retain: true });
  await bridge.handleIncomingMessage(`ev/${TOPIC}/event`, JSON.stringify(ev({ pad: 'x'.repeat(4200) })));
  await bridge.handleIncomingMessage(`ev/${TOPIC}/event`, '{bozuk');
  await bridge.handleIncomingMessage(`ev/${TOPIC}/event`, JSON.stringify(ev({ eid: 'nope' })));
  await bridge.handleIncomingMessage(`ev/${TOPIC}/event`, JSON.stringify(ev({ uid: UID_B })));
  assert.equal(alarms.events.length, 0);
  assert.equal(bridge.counters.oversize, 1);
  assert.ok(bridge.counters.invalid >= 2);
  assert.ok(bridge.counters.ignored >= 2);
});

test('event: cfg_dump olay hattina girmez, yapilandirma kopyasi guncelleyicisine gider', async () => {
  const { bridge, alarms } = setup();
  await bridge.handleIncomingMessage(`ev/${TOPIC}/event`, JSON.stringify({ v: 1, uid: UID, type: 'cfg_dump', module: 'safety', rev: 3, crc: '0000000a', part: 1, parts: 1, body: { a: 1 } }));
  assert.equal(alarms.events.length, 0);
  assert.equal(alarms.dumps.length, 1);
  assert.equal(alarms.dumps[0].deviceId, DEV.device_id);
  assert.equal(alarms.dumps[0].dump.module, 'safety');
});

test('state v:3 canli: caps + safety_state AYNI cihaz UPDATE\'inde; COMMIT sonrasi onLiveState (caps, ozet, onceki ozet)', async () => {
  const prev = { v: 1, cfg: { rev: 11, crc: '00000001' } };
  const { bridge, db, alarms } = setup({ homeRows: [{ ...DEV, has_caps: true, safety_state: prev }] });
  await bridge.handleIncomingMessage(`ev/${TOPIC}/state`, JSON.stringify(v3state()));
  const upd = db.calls.filter((c) => /^UPDATE devices SET/.test(c.text));
  assert.equal(upd.length, 1);
  assert.match(upd[0].text, /caps = \$\d+/);
  assert.match(upd[0].text, /safety_state = \$\d+/);
  const capsParam = upd[0].params.find((p) => typeof p === 'string' && p.startsWith('["safety"'));
  assert.equal(capsParam, '["safety","actuator","event","cfg"]');
  assert.equal(alarms.live.length, 1);
  const call = alarms.live[0];
  assert.deepEqual(call.caps, ['safety', 'actuator', 'event', 'cfg']);
  assert.equal(call.summary.zones[0].aid, '9f3a11c0-3');
  assert.deepEqual(call.prev, prev);
  assert.equal(call.hadCaps, true);
  assert.equal(call.uid, UID);
  assert.equal(call.deviceId, DEV.device_id);
});

test('state v:2 (caps yok, onceden de yok): cihaz UPDATE metni eskisiyle AYNI, alarm servisi CAGRILMAZ', async () => {
  const { bridge, db, alarms } = setup();
  const payload = { v: 2, uid: UID, fw: '1.1.2', last_id: 'x1', child_lock: false, relays: [{ id: 1, state: true }], shutters: [] };
  await bridge.handleIncomingMessage(`ev/${TOPIC}/state`, JSON.stringify(payload));
  const upd = db.calls.find((c) => /^UPDATE devices SET/.test(c.text));
  const expected = helpers.buildDeviceUpdate(DEV.device_id, helpers.validateStatePayload(payload).value, true);
  assert.equal(upd.text, expected.text);
  assert.doesNotMatch(upd.text, /caps|safety_state/);
  assert.equal(alarms.live.length, 0);
});

test('eski firmware\'e donus (caps yok ama onceden vardi): caps/safety_state NULL + onLiveState(caps null) -> lost', async () => {
  const { bridge, db, alarms } = setup({ homeRows: [{ ...DEV, has_caps: true, safety_state: { v: 1 } }] });
  await bridge.handleIncomingMessage(`ev/${TOPIC}/state`, JSON.stringify({ v: 2, uid: UID, relays: [], shutters: [] }));
  const upd = db.calls.find((c) => /^UPDATE devices SET/.test(c.text));
  assert.match(upd.text, /caps = NULL, safety_state = NULL/);
  assert.equal(alarms.live.length, 1);
  assert.equal(alarms.live[0].caps, null);
  assert.equal(alarms.live[0].hadCaps, true);
});

test('retained v:3 state: caps YAZILMAZ ve alarm servisi CAGRILMAZ (bayat olabilir)', async () => {
  const { bridge, db, alarms } = setup();
  await bridge.handleIncomingMessage(`ev/${TOPIC}/state`, JSON.stringify(v3state()), { retain: true });
  assert.ok(db.calls.every((c) => !/caps =/.test(c.text)));
  assert.equal(alarms.live.length, 0);
});

test('ret yankisi [Y5]: last_rej yalniz hedef uid\'nin canli state\'inden; baska panonun ayni kimlikli reddi sayilmaz', async () => {
  const { bridge } = setup({ homeRows: [DEV, DEV_B] });
  const p = bridge.expectOutcome(TOPIC, 'cmd01', 5000, { uid: UID });
  // B panosu ayni kimligi reddetti (duz relay komutu her panoya gider): A icin SAYILMAZ
  await bridge.handleIncomingMessage(`ev/${TOPIC}/state`, JSON.stringify(v3state({ uid: UID_B, last_id: undefined, last_rej: { id: 'cmd01', code: 'actuator_relay' } })));
  assert.equal(bridge.pendingAcks(), 1);
  await bridge.handleIncomingMessage(`ev/${TOPIC}/state`, JSON.stringify(v3state({ last_id: undefined, last_rej: { id: 'cmd01', code: 'zone_latched' } })));
  assert.deepEqual(await p, { ok: false, rejected: 'zone_latched' });

  const q = bridge.expectOutcome(TOPIC, 'cmd02', 5000, { uid: UID });
  await bridge.handleIncomingMessage(`ev/${TOPIC}/state`, JSON.stringify(v3state({ uid: UID_B, last_id: 'cmd02' })));
  assert.equal(bridge.pendingAcks(), 1, 'baska panonun last_id yankisi da sayilmaz');
  await bridge.handleIncomingMessage(`ev/${TOPIC}/state`, JSON.stringify(v3state({ last_id: 'cmd02' })));
  assert.deepEqual(await q, { ok: true });

  // retained ret yankisi sayilmaz; zaman asimi -> timeout
  const r = bridge.expectOutcome(TOPIC, 'cmd03', 20, { uid: UID });
  await bridge.handleIncomingMessage(`ev/${TOPIC}/state`, JSON.stringify(v3state({ last_rej: { id: 'cmd03', code: 'busy' } })), { retain: true });
  assert.deepEqual(await r, { ok: false, timeout: true });
});

test('expectAck (eski, boolean) davranisi AYNEN: last_id -> true; last_rej bekleyiciyi BITIRMEZ', async () => {
  const { bridge } = setup();
  const a = bridge.expectAck(TOPIC, 'old1', 30);
  await bridge.handleIncomingMessage(`ev/${TOPIC}/state`, JSON.stringify(v3state({ last_id: undefined, last_rej: { id: 'old1', code: 'busy' } })));
  assert.equal(await a, false, 'zaman asimi (ret yankisi boolean bekleyiciyi bitirmez)');
  const b = bridge.expectAck(TOPIC, 'old2', 5000);
  await bridge.handleIncomingMessage(`ev/${TOPIC}/state`, JSON.stringify({ v: 2, uid: UID, last_id: 'old2', relays: [], shutters: [] }));
  assert.equal(await b, true);
});

// ---- sko-2 (sozlesme C12): kapanista bekleyen alarm push'lari beklenir; yarim kalan push'lar yeniden denenir ----
test('sko-2: end() alarm servisini durdurmadan once bekleyen push islerini bekler (en cok timeoutMs/3 sn)', async () => {
  const order = [];
  let release = null;
  const alarms = { ...spyAlarms(), idle: () => new Promise((r) => { release = () => { order.push('idle'); r(); }; }), stop() { order.push('stop'); } };
  const { bridge } = setup({ alarms });
  const p = bridge.end();
  await new Promise((r) => setImmediate(r));
  assert.deepEqual(order, [], 'bekleyen push bitmeden alarm servisi durdurulmaz');
  release();
  await p;
  assert.deepEqual(order, ['idle', 'stop']);

  const stuck = { ...spyAlarms(), idle: () => new Promise(() => {}), stop() { order.push('stop2'); } };
  const s2 = setup({ alarms: stuck });
  const t0 = Date.now();
  await s2.bridge.end({ timeoutMs: 50 });
  assert.ok(order.includes('stop2'), 'sure dolunca yine durdurulur');
  assert.ok(Date.now() - t0 < 2000, 'kapanis sinirli bekler');
});

test('sko-2: kopru acilistan ~5 sn sonra bir kez ve dakikada bir retryStuckPushes cagirir; end() sonrasi cagirmaz', async () => {
  const { makeFakeClient, makeFakeMqttLib, makeFakeTimers } = require('../bridge/_helpers');
  const calls = [];
  const alarms = { ...spyAlarms(), async retryStuckPushes(opts) { calls.push(opts); return { claimed: 0, sent: 0 }; }, async idle() {} };
  const client = makeFakeClient();
  const timers = makeFakeTimers();
  const clock = { t: 1_800_000_000_000 };
  const bridge = new MqttBridge({
    mqttLib: makeFakeMqttLib(client), db: makeFakeDb([]), logger: makeLogger(), timers, now: () => clock.t, alarmService: alarms,
    env: { MQTT_BACKEND_USER: 'backend_service', MQTT_BACKEND_PASS: 'test-only-placeholder-password-not-real' },
  });
  bridge.init();
  const kick = timers.pendingTimeouts().find((h) => h.ms === 5000);
  assert.ok(kick, 'acilis tetigi (~5 sn)');
  timers.fireTimeout(kick);
  await new Promise((r) => setImmediate(r));
  assert.equal(calls.length, 1);
  assert.equal(calls[0].limit, 50);
  const sweep = timers.pendingIntervals()[0];
  clock.t += 30 * 1000;
  timers.fireInterval(sweep);
  await new Promise((r) => setImmediate(r));
  assert.equal(calls.length, 1, '60 sn dolmadan yinelenmez');
  clock.t += 30 * 1000;
  timers.fireInterval(sweep);
  await new Promise((r) => setImmediate(r));
  assert.equal(calls.length, 2, 'dakikada bir');
  await bridge.end({ timeoutMs: 50 });
  assert.equal(timers.pendingTimeouts().filter((h) => h.ms === 5000).length, 0);
  assert.equal(timers.pendingIntervals().length, 0);
});
