'use strict';

// DAIRE-03 - Kopru: cihaz ONAYI bekleme (expectAck). Firmware basarili komutta state.last_id'yi komut kimligine esitler
// ve hemen yayinlar (SmartAutomation.cpp ok -> _lastId, MqttManager triggerPublish); reddedilen komutta last_id DEGISMEZ.
// Bekleyici YAYINDAN ONCE kurulur; yalniz CANLI state onaydir (retained bayat olabilir); zaman asimi / end() -> false.

const test = require('node:test');
const assert = require('node:assert/strict');
const { MqttBridge } = require('../../src/mqtt_bridge');
const { makeFakeDb, makeLogger, makeFakeTimers } = require('./_helpers');

const HOME = 'h_0123456789abcdef';
const OTHER = 'h_fedcba9876543210';
const HOME_ID = '11111111-1111-4111-8111-111111111111';
const DEV = { home_id: HOME_ID, device_id: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', device_uuid: 'AHBU-S3-0001' };

function setup() {
  const db = makeFakeDb([{ match: /FROM homes h LEFT JOIN devices d/, reply: { rows: [DEV], rowCount: 1 } }]);
  const timers = makeFakeTimers();
  const logger = makeLogger();
  const bridge = new MqttBridge({ db, logger, env: {}, timers, now: () => 1_700_000_000_000 });
  return { bridge, db, timers, logger };
}

const state = (obj) => Buffer.from(JSON.stringify({ uid: DEV.device_uuid, ...obj }));
const live = (bridge, topic, obj) => bridge.handleIncomingMessage(`ev/${topic}/state`, state(obj), { retain: false });
const settled = async (p) => {
  let done = false;
  let value;
  p.then((v) => { done = true; value = v; });
  await new Promise((resolve) => setImmediate(resolve));
  return { done, value };
};

test('CANLI state last_id === komut kimligi -> true; bekleyici temizlenir', async () => {
  const { bridge, timers } = setup();
  const p = bridge.expectAck(HOME, 'cmd-1', 4000);
  assert.equal(timers.pendingTimeouts().length, 1, 'zaman asimi kuruldu');
  assert.equal(timers.pendingTimeouts()[0].ms, 4000);
  await live(bridge, HOME, { last_id: 'cmd-1', relays: [{ id: 1, state: true }] });
  assert.equal(await p, true);
  assert.equal(timers.pendingTimeouts().length, 0, 'zaman asimi iptal edildi');
  assert.equal(bridge.pendingAcks(), 0);
});

test('RETAINED state onay SAYILMAZ (bayat olabilir); baska kimlik / baska ev konusu da sayilmaz; zaman asiminda false', async () => {
  const { bridge, timers } = setup();
  const p = bridge.expectAck(HOME, 'cmd-2', 4000);
  await bridge.handleIncomingMessage(`ev/${HOME}/state`, state({ last_id: 'cmd-2' }), { retain: true });
  await live(bridge, HOME, { last_id: 'baska-id' });
  await live(bridge, OTHER, { last_id: 'cmd-2' });
  assert.deepEqual(await settled(p), { done: false, value: undefined }, 'hala bekliyor');
  const [t] = timers.pendingTimeouts();
  timers.fireTimeout(t);
  assert.equal(await p, false);
  assert.equal(bridge.pendingAcks(), 0);
});

test('last_id alani olmayan (bos) canli state onay degildir', async () => {
  const { bridge, timers } = setup();
  const p = bridge.expectAck(HOME, 'cmd-3', 4000);
  await bridge.handleIncomingMessage(`ev/${HOME}/state`, Buffer.from(JSON.stringify({ uid: DEV.device_uuid, last_id: '' })), { retain: false });
  assert.equal((await settled(p)).done, false);
  timers.fireTimeout(timers.pendingTimeouts()[0]);
  assert.equal(await p, false);
});

test('yanki kuyruk BIRLESTIRMESINDEN once islenir: ara state\'teki last_id kaybolmaz', async () => {
  const { bridge, db } = setup();
  // ilk state'in veritabani isi yavas: sonraki iki state ayni ev kuyrugunda birlesir (yalniz en yenisi islenir)
  let release;
  const gate = new Promise((resolve) => { release = resolve; });
  db.addRule({ match: /FROM homes h LEFT JOIN devices d/, reply: () => gate.then(() => ({ rows: [DEV], rowCount: 1 })) });
  const p = bridge.expectAck(HOME, 'cmd-4', 4000);
  const first = live(bridge, HOME, { last_id: 'onceki' });
  const mid = live(bridge, HOME, { last_id: 'cmd-4' });
  const last = live(bridge, HOME, { last_id: 'sonraki' });
  assert.equal(await p, true, 'aradaki yanki onay sayilmali');
  release();
  await Promise.all([first, mid, last]);
});

test('end(): bekleyen TUM onaylar false; zamanlayicilar temizlenir', async () => {
  const { bridge, timers } = setup();
  const a = bridge.expectAck(HOME, 'cmd-5', 4000);
  const b = bridge.expectAck(OTHER, 'cmd-6', 4000);
  await bridge.end({ force: true, timeoutMs: 10 });
  assert.deepEqual(await Promise.all([a, b]), [false, false]);
  assert.equal(timers.pendingTimeouts().filter((t) => t.ms === 4000).length, 0);
  assert.equal(bridge.pendingAcks(), 0);
});

test('cancelAck: bekleyen false olur; ayni kimlige birden cok bekleyici desteklenir', async () => {
  const { bridge } = setup();
  const a = bridge.expectAck(HOME, 'cmd-7', 4000);
  const b = bridge.expectAck(HOME, 'cmd-7', 4000);
  bridge.cancelAck(HOME, 'cmd-7');
  assert.deepEqual(await Promise.all([a, b]), [false, false]);
  assert.equal(bridge.pendingAcks(), 0);
  bridge.cancelAck(HOME, 'yok'); // bekleyeni olmayan iptal: sessiz
});

test('ust sinir: bekleyici sayisi dolunca yeni expectAck SENKRON 503 firlatir (cagiran henuz yayin yapmamistir)', async () => {
  const { bridge } = setup();
  const { ACK_MAX_WAITERS } = require('../../src/mqtt_bridge').constants;
  assert.ok(Number.isInteger(ACK_MAX_WAITERS) && ACK_MAX_WAITERS >= 100);
  const all = [];
  for (let i = 0; i < ACK_MAX_WAITERS; i += 1) all.push(bridge.expectAck(HOME, `c${i}`, 4000));
  assert.throws(() => bridge.expectAck(HOME, 'fazla', 4000), (err) => err.status === 503 && err.code === 'SERVICE_UNAVAILABLE');
  await bridge.end({ force: true, timeoutMs: 10 });
  assert.ok((await Promise.all(all)).every((v) => v === false));
});

test('gecersiz girdi: konu / komut kimligi dogrulanir (TypeError); sure ust siniri uygulanir', () => {
  const { bridge, timers } = setup();
  assert.throws(() => bridge.expectAck('ev/x', 'cmd', 4000), TypeError);
  assert.throws(() => bridge.expectAck(HOME, '', 4000), TypeError);
  assert.throws(() => bridge.expectAck(HOME, 'x'.repeat(25), 4000), TypeError);
  bridge.expectAck(HOME, 'uzun', 10 * 60 * 1000);
  assert.ok(timers.pendingTimeouts()[0].ms <= 30 * 1000, 'en cok 30 sn');
});
