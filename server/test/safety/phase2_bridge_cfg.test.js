'use strict';

// Faz 2 / WP-C2 (F2.D.1 madde 8): kopru tarafi.
//   - expectOutcome(topic, id, ms, {uid, cfgRev}): firmware cfg_patch basarisinda (v1.2.0) last_id YAZMAZ; sonuc ayni uid'nin
//     CANLI state'indeki cfg.safety.rev = cfgRev ile de kabul edilir. Sonuc yapilandirma ozetini (rev, crc) tasir.
//     last_id (firmware C1 sonrasi) ve last_rej yollari aynen; baska pano / retained state sayilmaz.
//   - cfg yetenekli panonun canli state'i uzlastiriciya (onSafetyState) bildirilir (bekleyen kuyruk); v:2 panoda bildirilmez.

const test = require('node:test');
const assert = require('node:assert/strict');

const { MqttBridge } = require('../../src/mqtt_bridge');
const { makeFakeDb, makeLogger } = require('../bridge/_helpers');

const TOPIC = 'h_0123456789abcdef';
const HOME_ID = '11111111-1111-4111-8111-111111111111';
const UID = 'AHBU-S3-A1B2C3';
const UID_B = 'AHBU-S3-0F0F0F';
const DEV = { home_id: HOME_ID, device_id: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', device_uuid: UID, has_caps: true, safety_state: null };
const DEV_B = { home_id: HOME_ID, device_id: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', device_uuid: UID_B, has_caps: true, safety_state: null };
const RESOLVE_RE = /FROM homes h LEFT JOIN devices d/;

function setup({ reconciler = null } = {}) {
  const db = makeFakeDb([
    { match: RESOLVE_RE, reply: (_t, p) => (p[0] === TOPIC ? { rows: [DEV, DEV_B], rowCount: 2 } : { rows: [], rowCount: 0 }) },
  ]);
  const alarms = { async onLiveState() { return { status: 'applied' }; }, async handleEvent() {}, async handleCfgDump() {}, stop() {} };
  const bridge = new MqttBridge({ db, logger: makeLogger(), env: {}, now: () => 1_800_000_000_000, alarmService: alarms, reconciler });
  return { bridge, db };
}

function state(over = {}) {
  return {
    v: 3, uid: UID, fw: '1.2.0', last_id: 'zz1', caps: ['safety', 'actuator', 'event', 'cfg'], boot: 57, bn: '9f3a11c0',
    cfg: { safety: { rev: 12, crc: '9a3c11f0' } }, relays: [], shutters: [], safety: { policy: 'on', mode: 'normal', zones: [] },
    ...over,
  };
}

test('cfgRev: ayni uid\'nin canli state\'inde rev = cfgRev -> {ok:true, cfg}; baska pano ve retained sayilmaz', async () => {
  const { bridge } = setup();
  const p = bridge.expectOutcome(TOPIC, 'cp1', 5000, { uid: UID, cfgRev: 13 });
  await bridge.handleIncomingMessage(`ev/${TOPIC}/state`, JSON.stringify(state({ uid: UID_B, cfg: { safety: { rev: 13, crc: '00000001' } } })));
  await bridge.handleIncomingMessage(`ev/${TOPIC}/state`, JSON.stringify(state({ cfg: { safety: { rev: 13, crc: '00000002' } } })), { retain: true });
  await bridge.handleIncomingMessage(`ev/${TOPIC}/state`, JSON.stringify(state({ cfg: { safety: { rev: 12, crc: '9a3c11f0' } } })));
  assert.equal(bridge.pendingAcks(), 1, 'henuz sonuc yok');
  await bridge.handleIncomingMessage(`ev/${TOPIC}/state`, JSON.stringify(state({ cfg: { safety: { rev: 13, crc: 'ABCDEF01' } } })));
  assert.deepEqual(await p, { ok: true, cfg: { rev: 13, crc: 'abcdef01' } });
  assert.equal(bridge.pendingAcks(), 0);
});

test('cfgRev bekleyicisi: last_id (firmware C1) ve last_rej yollari da sonuclandirir; zaman asimi', async () => {
  const { bridge } = setup();
  const a = bridge.expectOutcome(TOPIC, 'cp2', 5000, { uid: UID, cfgRev: 13 });
  await bridge.handleIncomingMessage(`ev/${TOPIC}/state`, JSON.stringify(state({ last_id: 'cp2', cfg: { safety: { rev: 13, crc: '0000000a' } } })));
  assert.deepEqual(await a, { ok: true, cfg: { rev: 13, crc: '0000000a' } });
  const b = bridge.expectOutcome(TOPIC, 'cp3', 5000, { uid: UID, cfgRev: 14 });
  await bridge.handleIncomingMessage(`ev/${TOPIC}/state`, JSON.stringify(state({ last_rej: { id: 'cp3', code: 'cfg_conflict' } })));
  const rb = await b;
  assert.equal(rb.rejected, 'cfg_conflict');
  assert.deepEqual(rb.cfg, { rev: 12, crc: '9a3c11f0' }, 'ret anindaki pano yapilandirma ozeti');
  const c = bridge.expectOutcome(TOPIC, 'cp4', 20, { uid: UID, cfgRev: 15 });
  assert.deepEqual(await c, { ok: false, timeout: true });
  assert.equal(bridge.pendingAcks(), 0);
});

test('cfgRev gecersizse TypeError (yayin oncesi); cfgRev olmayan bekleyici eskisi gibi {ok:true}', async () => {
  const { bridge } = setup();
  assert.throws(() => bridge.expectOutcome(TOPIC, 'cp5', 100, { uid: UID, cfgRev: -1 }), TypeError);
  const p = bridge.expectOutcome(TOPIC, 'cp6', 5000, { uid: UID });
  await bridge.handleIncomingMessage(`ev/${TOPIC}/state`, JSON.stringify(state({ last_id: 'cp6' })));
  assert.deepEqual(await p, { ok: true });
});

test('cfg yetenekli canli state uzlastiriciya onSafetyState ile bildirilir; v:2 ve retained bildirilmez', async () => {
  const seen = [];
  const reconciler = { onLiveState() {}, onSafetyState(a) { seen.push(a); }, onOffline() {}, stop() {}, stats() { return {}; } };
  const { bridge } = setup({ reconciler });
  await bridge.handleIncomingMessage(`ev/${TOPIC}/state`, JSON.stringify(state()));
  await bridge.handleIncomingMessage(`ev/${TOPIC}/state`, JSON.stringify(state()), { retain: true });
  await bridge.handleIncomingMessage(`ev/${TOPIC}/state`, JSON.stringify(state({ caps: ['safety', 'actuator', 'event'] })));
  await bridge.handleIncomingMessage(`ev/${TOPIC}/state`, JSON.stringify({ v: 2, uid: UID, relays: [], shutters: [] }));
  assert.equal(seen.length, 1);
  assert.equal(seen[0].deviceId, DEV.device_id);
  assert.equal(seen[0].uid, UID);
  assert.equal(seen[0].summary.cfg.rev, 12);
  assert.ok(seen[0].caps.includes('cfg'));
});

// Faz 2 incelemesi R2: last_id yankili firmware (1.2.1, caps 'intrusion') icin rev cikarimi YAPILMAZ: baska kaynakli (LAN/CLI) rev
// artisi bulut yamasini "uygulandi" saymaz; ardindan gelen cfg_conflict reddi sonuca ulasir.
test('R2: yankili firmware (caps intrusion) baska kaynakli rev artisi bekleyiciyi cozmez; ret ulasir', async () => {
  const { bridge } = setup();
  const CAPS_I = ['safety', 'actuator', 'event', 'cfg', 'intrusion'];
  const p = bridge.expectOutcome(TOPIC, 'cloud1', 5000, { uid: UID, cfgRev: 13 });
  await bridge.handleIncomingMessage(`ev/${TOPIC}/state`, JSON.stringify(state({ fw: '1.2.1', caps: CAPS_I, last_id: 'lan-77', cfg: { safety: { rev: 13, crc: '11111111' } } })));
  assert.equal(bridge.pendingAcks(), 1, 'yabanci rev artisi uygulandi sayilmadi');
  await bridge.handleIncomingMessage(`ev/${TOPIC}/state`, JSON.stringify(state({
    fw: '1.2.1', caps: CAPS_I, last_id: 'lan-77', last_rej: { id: 'cloud1', code: 'cfg_conflict' }, cfg: { safety: { rev: 13, crc: '11111111' } },
  })));
  const out = await p;
  assert.equal(out.ok, false);
  assert.equal(out.rejected, 'cfg_conflict');
  // yankili firmware'de last_id yolu aynen
  const q = bridge.expectOutcome(TOPIC, 'cloud2', 5000, { uid: UID, cfgRev: 14 });
  await bridge.handleIncomingMessage(`ev/${TOPIC}/state`, JSON.stringify(state({ fw: '1.2.1', caps: CAPS_I, last_id: 'cloud2', cfg: { safety: { rev: 14, crc: '22222222' } } })));
  assert.deepEqual(await q, { ok: true, cfg: { rev: 14, crc: '22222222' } });
});

// Faz 2 incelemesi R3: yapilandirma yamasi bekleyicisi cihaz durumu (devices.safety_state: state_rev) DB'ye yazildiktan SONRA cozulur;
// istemci yanittan hemen sonra GET ile okudugunda state_rev yeni degerdir.
test('R3: cfgRev bekleyicisi safety_state yazimindan SONRA cozulur (last_id ve rev yollari)', async () => {
  for (const viaLastId of [true, false]) {
    const writes = [];
    let atResolve = null;
    const db = makeFakeDb([{ match: RESOLVE_RE, reply: (_t, p) => (p[0] === TOPIC ? { rows: [DEV], rowCount: 1 } : { rows: [], rowCount: 0 }) }]);
    db.addRule({ match: (t) => /UPDATE/.test(t) && /safety_state/.test(t), reply: () => new Promise((r) => setTimeout(() => { writes.push('safety_state'); r({ rows: [], rowCount: 1 }); }, 30)) });
    const alarms = { async onLiveState() { return { status: 'applied' }; }, async handleEvent() {}, async handleCfgDump() {}, stop() {} };
    const bridge = new MqttBridge({ db, logger: makeLogger(), env: {}, now: () => 1_800_000_000_000, alarmService: alarms });
    const p = bridge.expectOutcome(TOPIC, 'cp1', 5000, { uid: UID, cfgRev: 13 }).then((o) => { atResolve = writes.length; return o; });
    const h = bridge.handleIncomingMessage(`ev/${TOPIC}/state`, JSON.stringify(state({ last_id: viaLastId ? 'cp1' : 'zz1', cfg: { safety: { rev: 13, crc: '9a3c11f0' } } })));
    const out = await p;
    await h;
    assert.equal(out.ok, true);
    assert.equal(atResolve, 1, `yanit DB guncellemesinden sonra (last_id=${viaLastId})`);
  }
  // cfgRev'siz (guvenlik komutu) bekleyici eskisi gibi hemen cozulur (DAIRE-03)
  const writes = [];
  let atResolve = null;
  const db = makeFakeDb([{ match: RESOLVE_RE, reply: (_t, p) => (p[0] === TOPIC ? { rows: [DEV], rowCount: 1 } : { rows: [], rowCount: 0 }) }]);
  db.addRule({ match: (t) => /UPDATE/.test(t) && /safety_state/.test(t), reply: () => new Promise((r) => setTimeout(() => { writes.push('w'); r({ rows: [], rowCount: 1 }); }, 30)) });
  const bridge = new MqttBridge({ db, logger: makeLogger(), env: {}, now: () => 1_800_000_000_000, alarmService: { async onLiveState() { return {}; }, async handleEvent() {}, async handleCfgDump() {}, stop() {} } });
  const p = bridge.expectOutcome(TOPIC, 'k1', 5000, { uid: UID }).then((o) => { atResolve = writes.length; return o; });
  const h = bridge.handleIncomingMessage(`ev/${TOPIC}/state`, JSON.stringify(state({ last_id: 'k1' })));
  await p;
  await h;
  assert.equal(atResolve, 0);
});

test('R2: uzlastiriciya bildirilen canli state last_id tasir (kuyruk cikarimi icin)', async () => {
  const seen = [];
  const reconciler = { onLiveState() {}, onSafetyState(a) { seen.push(a); }, onOffline() {}, stop() {}, stats() { return {}; } };
  const { bridge } = setup({ reconciler });
  await bridge.handleIncomingMessage(`ev/${TOPIC}/state`, JSON.stringify(state({ last_id: 'q-7' })));
  assert.equal(seen[0].lastId, 'q-7');
  assert.equal(seen[0].cfgId, null, 'cfg.safety.id yok (eski firmware)');
});

test('sko-5 (C6): uzlastiriciya bildirilen canli state cfg.safety.id tasir (cfgId); ozete yazilmaz', async () => {
  const seen = [];
  const reconciler = { onLiveState() {}, onSafetyState(a) { seen.push(a); }, onOffline() {}, stop() {}, stats() { return {}; } };
  const { bridge } = setup({ reconciler });
  await bridge.handleIncomingMessage(`ev/${TOPIC}/state`, JSON.stringify(state({ last_id: 'relay-9', cfg: { safety: { rev: 13, crc: '9a3c11f0', id: 'q-7' } } })));
  assert.equal(seen[0].lastId, 'relay-9');
  assert.equal(seen[0].cfgId, 'q-7');
  assert.deepEqual(seen[0].summary.cfg, { rev: 13, crc: '9a3c11f0' });
});
