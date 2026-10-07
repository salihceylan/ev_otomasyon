'use strict';

// C8 - Kopru: baglanti yasam dongusu, abonelik, ustel yeniden baglanma, yayin
// (cmd/sys/retained temizleme), cevrimdisi supurucu.

const test = require('node:test');
const assert = require('node:assert/strict');
const { MqttBridge, BrokerUnavailableError } = require('../../src/mqtt_bridge');
const { makeFakeClient, makeFakeMqttLib, makeFakeDb, makeFakeTimers, makeLogger, flush } = require('./_helpers');

const ENV = Object.freeze({
  MQTT_BACKEND_USER: 'backend_service',
  MQTT_BACKEND_PASS: 'test-only-placeholder-password-not-real',
});

function setup({ env = ENV, autoAck = true, db = makeFakeDb(), clock = { t: 1_700_000_000_000 } } = {}) {
  const client = makeFakeClient({ autoAck });
  const mqttLib = makeFakeMqttLib(client);
  const timers = makeFakeTimers();
  const logger = makeLogger();
  const bridge = new MqttBridge({
    mqttLib,
    db,
    logger,
    timers,
    env: { ...env },
    now: () => clock.t,
    random: () => 0.5, // jitter carpani tam 1.0
  });
  return { bridge, client, mqttLib, timers, logger, db, clock };
}

function connect({ bridge, client }) {
  bridge.init();
  client.connected = true;
  client.emit('connect', { sessionPresent: false });
}

test('init: kimlik yoksa BASLAMAZ (fail-closed), baglanti denenmez', () => {
  const { bridge, mqttLib, logger } = setup({ env: {} });
  assert.equal(bridge.init(), null);
  assert.equal(mqttLib.calls.length, 0);
  assert.ok(logger.lines.some((l) => l.startsWith('error:') && l.includes('fail-closed')));
  assert.equal(bridge.isConnected(), false);
});

test('init: sadece kullanici veya sadece parola varsa da baslamaz', () => {
  for (const env of [{ MQTT_BACKEND_USER: 'u' }, { MQTT_BACKEND_PASS: 'p' }]) {
    const { bridge, mqttLib } = setup({ env });
    assert.equal(bridge.init(), null);
    assert.equal(mqttLib.calls.length, 0);
  }
});

test('init: clean:false + sabit clientId + kimlik ortamdan; parola log\'a yazilmaz', () => {
  const a = setup();
  a.bridge.init();
  const b = setup();
  b.bridge.init();

  const opts = a.mqttLib.calls[0].options;
  assert.equal(a.mqttLib.calls[0].url, 'mqtt://127.0.0.1:1884');
  assert.equal(opts.clean, false);
  assert.equal(opts.username, 'backend_service');
  assert.equal(opts.password, ENV.MQTT_BACKEND_PASS);
  assert.match(opts.clientId, /^ev_backend_bridge_[A-Za-z0-9_-]+$/);
  assert.equal(opts.clientId, b.mqttLib.calls[0].options.clientId, 'clientId yeniden baslatmada AYNI olmali (rastgele degil)');
  assert.equal(opts.queueQoSZero, false);
  assert.equal(opts.reconnectPeriod, 1000);
  assert.ok(!a.logger.lines.join('\n').includes(ENV.MQTT_BACKEND_PASS), 'parola log\'a sizmamali');
});

test('init: MQTT_HOST/PORT/TLS/CLIENT_ID ortamdan okunur; init idempotenttir', () => {
  const { bridge, mqttLib } = setup({
    env: { ...ENV, MQTT_HOST: 'emqx.internal', MQTT_PORT: '8883', MQTT_TLS: 'true', MQTT_CLIENT_ID: 'bridge-blue' },
  });
  const c1 = bridge.init();
  const c2 = bridge.init();
  assert.equal(c1, c2);
  assert.equal(mqttLib.calls.length, 1, 'ikinci init yeni baglanti acmamali');
  assert.equal(mqttLib.calls[0].url, 'mqtts://emqx.internal:8883');
  assert.equal(mqttLib.calls[0].options.clientId, 'bridge-blue');
});

test('connect: abonelik QoS1 ile ev/+/status ve ev/+/state; isConnected true', async () => {
  const s = setup();
  connect(s);
  await flush();
  assert.equal(s.bridge.isConnected(), true);
  assert.equal(s.client.subscribed.length, 1);
  assert.deepEqual(s.client.subscribed[0].topics, ['ev/+/status', 'ev/+/state', 'ev/+/event']); // WP-S2: guvenlik olaylari
  assert.deepEqual(s.client.subscribed[0].opts, { qos: 1 });
  assert.ok(s.logger.lines.some((l) => l.includes('Dinlenen konular')));
});

test('abonelik broker tarafindan reddedilirse (granted qos=128) hata loglanir ve yeniden denenir', async () => {
  const s = setup();
  s.client.grant = (topics) => topics.map((t) => ({ topic: t, qos: 128 }));
  connect(s);
  await flush();
  assert.ok(s.logger.lines.some((l) => l.startsWith('error:') && l.includes('REDDEDILDI')));
  assert.ok(!s.logger.lines.some((l) => l.includes('Dinlenen konular')), 'basari gibi gosterilmemeli');
  const pending = s.timers.pendingTimeouts();
  assert.equal(pending.length, 1, 'yeniden abone olma zamanlayicisi kurulmali');

  // ACL duzeldi: ikinci denemede basarili
  s.client.grant = null;
  s.timers.fireTimeout(pending[0]);
  await flush();
  assert.equal(s.client.subscribed.length, 2);
  assert.ok(s.logger.lines.some((l) => l.includes('Dinlenen konular')));
});

test('GERCEK mqtt.js semantigi: SUBACK 0x80 `err` ("Subscribe error") ile gelir -> REDDEDILDI olarak loglanir ve yeniden denenir', async () => {
  const s = setup();
  // mqtt.js 5.x: ret durumunda cb(err, istenenListe) - granted qos'u 128 DEGIL
  s.client.subscribe = (topics, opts, cb) => {
    s.client.subscribed.push({ topics, opts });
    setImmediate(() => cb(new Error('Subscribe error: Unspecified error'), topics.map((t) => ({ topic: t, qos: 1 }))));
    return s.client;
  };
  connect(s);
  await flush();
  assert.ok(s.logger.lines.some((l) => l.startsWith('error:') && l.includes('REDDEDILDI')));
  assert.ok(!s.logger.lines.some((l) => l.includes('Dinlenen konular')));
  assert.equal(s.timers.pendingTimeouts().length, 1, 'yeniden abone olma zamanlayicisi kurulmali');
});

test('abonelik: kutuphanenin otomatik yeniden aboneligi KAPALI (her baglantida acikca abone olunur)', async () => {
  const s = setup();
  s.bridge.init();
  assert.equal(s.mqttLib.calls[0].options.resubscribe, false);
  s.client.connected = true;
  s.client.emit('connect', { sessionPresent: true });
  await flush();
  s.client.emit('connect', { sessionPresent: true });
  await flush();
  assert.equal(s.client.subscribed.length, 2, 'oturum surse bile her baglantida abone olunmali');
});

test('kismi abonelik reddi (biri 128) da hata sayilir', async () => {
  const s = setup();
  s.client.grant = (topics) => topics.map((t, i) => ({ topic: t, qos: i === 0 ? 1 : 128 }));
  connect(s);
  await flush();
  assert.ok(s.logger.lines.some((l) => l.includes('REDDEDILDI')));
});

test('ustel yeniden baglanma: her reconnect bekleme suresini ikiye katlar, tavanda durur, connect sifirlar', () => {
  const s = setup();
  s.bridge.init();
  const periods = [];
  for (let i = 0; i < 9; i++) {
    s.client.emit('reconnect');
    periods.push(s.client.options.reconnectPeriod);
  }
  assert.deepEqual(periods, [2000, 4000, 8000, 16000, 32000, 60000, 60000, 60000, 60000]);

  s.client.connected = true;
  s.client.emit('connect', {});
  assert.equal(s.client.options.reconnectPeriod, 1000, 'basarili baglantidan sonra taban sureye donmeli');
});

test('yeniden baglanma suresine +-%20 jitter uygulanir', () => {
  const clientA = setup();
  clientA.bridge.random = () => 0; // en dusuk: x0.8
  clientA.bridge.init();
  clientA.client.emit('reconnect');
  assert.equal(clientA.client.options.reconnectPeriod, 1600);

  const clientB = setup();
  clientB.bridge.random = () => 1; // en yuksek: x1.2
  clientB.bridge.init();
  clientB.client.emit('reconnect');
  assert.equal(clientB.client.options.reconnectPeriod, 2400);
});

test('close/offline/end olaylari baglantiyi "kopuk" yapar', () => {
  for (const ev of ['close', 'offline', 'end']) {
    const s = setup();
    connect(s);
    assert.equal(s.bridge.isConnected(), true);
    s.client.connected = false;
    s.client.emit(ev);
    assert.equal(s.bridge.isConnected(), false, `${ev} sonrasi kopuk olmali`);
  }
});

test('mesaj olayi: packet.retain bayragi islemeye aktarilir', async () => {
  const db = makeFakeDb([
    {
      match: /FROM homes h LEFT JOIN devices d/,
      reply: { rows: [{ home_id: 'h1', device_id: 'd1', device_uuid: 'AHBU-S3-0001' }], rowCount: 1 },
    },
  ]);
  const s = setup({ db });
  connect(s);
  s.client.emit('message', 'ev/h_abc/state', Buffer.from('{"ip":"10.0.0.7","relays":[{"id":1,"state":true}]}'), { retain: true });
  s.client.emit('message', 'ev/h_abc/state', Buffer.from('{"ip":"10.0.0.8"}'), { retain: false });
  await flush(10);
  const devUpdates = db.calls.filter((c) => /UPDATE devices SET/.test(c.text));
  assert.equal(devUpdates.length >= 1, true);
  // retained mesaj is_online yazmaz; canli olan yazar
  const retained = devUpdates.find((c) => c.params.includes('10.0.0.7'));
  const live = devUpdates.find((c) => c.params.includes('10.0.0.8'));
  assert.ok(retained && !/is_online/.test(retained.text));
  assert.ok(live && /is_online = TRUE/.test(live.text));
});

// -- Yayin --------------------------------------------------------------------

test('publishCommand: ev/{t}/cmd, QoS1, retain=false, JSON; yuk icerigi log\'a yazilmaz', async () => {
  const s = setup();
  connect(s);
  const res = await s.bridge.publishCommand('h_0123456789abcdef', { relay: 3, state: true, id: 'GIZLI-ID-42' });
  assert.equal(res.topic, 'ev/h_0123456789abcdef/cmd');
  assert.equal(res.payload, '{"relay":3,"state":true,"id":"GIZLI-ID-42"}');
  const pub = s.client.published[0];
  assert.equal(pub.topic, 'ev/h_0123456789abcdef/cmd');
  assert.deepEqual(pub.opts, { qos: 1, retain: false });
  assert.ok(!s.logger.lines.join('\n').includes('GIZLI-ID-42'));
});

test('publishCommand: baglanti yoksa BrokerUnavailableError (502 BROKER_UNAVAILABLE) ve KUYRUGA ALINMAZ', async () => {
  const s = setup();
  s.bridge.init(); // baglanti olayi gelmedi
  await assert.rejects(
    () => s.bridge.publishCommand('h_abc', { relay: 1, state: true }),
    (err) => {
      assert.ok(err instanceof BrokerUnavailableError);
      assert.equal(err.status, 502);
      assert.equal(err.statusCode, 502);
      assert.equal(err.code, 'BROKER_UNAVAILABLE');
      return true;
    }
  );
  assert.equal(s.client.published.length, 0, 'cevrimdisiyken mqtt.js kuyruguna yayin birakilmamali');

  // hic init edilmemis kopru
  const cold = new MqttBridge({ env: {}, logger: makeLogger() });
  await assert.rejects(() => cold.publishCommand('h_abc', { relay: 1 }), BrokerUnavailableError);
});

test('publishCommand: gecersiz konu kimligi / yuk reddedilir', async () => {
  const s = setup();
  connect(s);
  for (const bad of ['', 'a/b', 'a+b', '#', 'x y', null, undefined, 5]) {
    await assert.rejects(() => s.bridge.publishCommand(bad, { relay: 1 }), TypeError, `reddedilmeli: ${String(bad)}`);
  }
  await assert.rejects(() => s.bridge.publishCommand('h_abc', null), TypeError);
  await assert.rejects(() => s.bridge.publishCommand('h_abc', [1]), TypeError);
  await assert.rejects(() => s.bridge.publishCommand('h_abc', { pad: 'x'.repeat(2000) }), RangeError);
  assert.equal(s.client.published.length, 0);
});

test('publishCommand: PUBACK gelmezse zaman asimi, paket giden depodan SILINIR (bayat komut tekrar gonderilmez)', async () => {
  const s = setup({ autoAck: false });
  connect(s);
  const p = s.bridge.publishCommand('h_abc', { relay: 1, state: true });
  const timeout = s.timers.pendingTimeouts().find((t) => t.ms === 5000);
  assert.ok(timeout, '5 sn yayin zaman asimi kurulmali');
  s.timers.fireTimeout(timeout);
  await assert.rejects(p, BrokerUnavailableError);
  assert.deepEqual(s.client.removed, [s.client.published[0].id]);
});

test('publishCommand: broker hatasi BrokerUnavailableError olarak yuzeye cikar (yutulmaz)', async () => {
  const s = setup();
  connect(s);
  s.client.publishError = new Error('Connection closed');
  await assert.rejects(
    () => s.bridge.publishCommand('h_abc', { relay: 1, state: false }),
    (err) => err instanceof BrokerUnavailableError && err.cause && err.cause.message === 'Connection closed'
  );
});

test('publishSys: ev/{t}/sys, QoS1, retain=false', async () => {
  const s = setup();
  connect(s);
  await s.bridge.publishSys('h_abc', { cmd: 'set_local_key', key: 'x' });
  const pub = s.client.published[0];
  assert.equal(pub.topic, 'ev/h_abc/sys');
  assert.deepEqual(pub.opts, { qos: 1, retain: false });
  assert.ok(!s.logger.lines.join('\n').includes('set_local_key'), 'sys yuku log\'a yazilmamali');
});

test('publishToTopic: yalnizca ev/{id}/cmd ve ev/{id}/sys; diger konular reddedilir', async () => {
  const s = setup();
  connect(s);
  await s.bridge.publishToTopic('ev/h_abc/cmd', { cmd: 'all_lights_off' });
  await s.bridge.publishToTopic('ev/h_abc/sys', { cmd: 'noop' });
  assert.deepEqual(
    s.client.published.map((p) => p.topic),
    ['ev/h_abc/cmd', 'ev/h_abc/sys']
  );
  for (const bad of ['ev/h_abc/state', 'ev/h_abc/status', 'ev/+/cmd', 'ev/#', '$SYS/broker', 'ev/h_abc/cmd/x', 'ev//cmd', 'ahbu/h/command', '', null]) {
    await assert.rejects(() => s.bridge.publishToTopic(bad, { a: 1 }), TypeError, `reddedilmeli: ${String(bad)}`);
  }
  assert.equal(s.client.published.length, 2);
});

test('clearRetained: state/status/cmd/sys konularina BOS yuk + retain=true + QoS1', async () => {
  const s = setup();
  connect(s);
  const res = await s.bridge.clearRetained('h_0123456789abcdef');
  assert.deepEqual(res.topics, [
    'ev/h_0123456789abcdef/state',
    'ev/h_0123456789abcdef/status',
    'ev/h_0123456789abcdef/cmd',
    'ev/h_0123456789abcdef/sys',
  ]);
  assert.equal(s.client.published.length, 4);
  for (const p of s.client.published) {
    assert.equal(p.payload, '');
    assert.deepEqual(p.opts, { qos: 1, retain: true });
  }
});

test('clearRetained: baglanti yoksa reddeder; kismi basarisizlikta err.failed listesi doner', async () => {
  const cold = setup();
  cold.bridge.init();
  await assert.rejects(() => cold.bridge.clearRetained('h_abc'), BrokerUnavailableError);
  await assert.rejects(() => cold.bridge.clearRetained('a/b'), TypeError);

  const s = setup();
  connect(s);
  let n = 0;
  const origPublish = s.client.publish;
  s.client.publish = (topic, payload, opts, cb) => {
    n++;
    if (n === 2) {
      s.client.published.push({ topic, payload, opts, id: ++s.client._lastId });
      setImmediate(() => cb(new Error('PUBACK yok')));
      return s.client;
    }
    return origPublish(topic, payload, opts, cb);
  };
  await assert.rejects(
    () => s.bridge.clearRetained('h_abc'),
    (err) => err instanceof BrokerUnavailableError && Array.isArray(err.failed) && err.failed.length === 1 && err.failed[0] === 'ev/h_abc/status'
  );
});

// -- Cevrimdisi supurucu ------------------------------------------------------

test('supurucu: baglanti yokken veya baglanti yeniyken CALISMAZ (broker kesintisi herkesi offline yapmasin)', async () => {
  const db = makeFakeDb([{ match: /UPDATE devices SET is_online = FALSE/, reply: { rows: [{ id: 1 }], rowCount: 1 } }]);
  const s = setup({ db });
  s.bridge.init();
  assert.equal(await s.bridge.sweepOffline(), 0, 'baglanti yok');

  connect(s);
  assert.equal(await s.bridge.sweepOffline(), 0, 'baglanti yeni kuruldu: kalp atislari icin beklenmeli');
  s.clock.t += 119 * 1000;
  assert.equal(await s.bridge.sweepOffline(), 0);
  assert.equal(db.calls.length, 0);

  s.clock.t += 2 * 1000; // 121 sn
  assert.equal(await s.bridge.sweepOffline(), 1);
  assert.equal(db.calls.length, 1);
  assert.match(db.calls[0].text, /UPDATE devices SET is_online = FALSE/);
  assert.match(db.calls[0].text, /last_seen_at IS NULL OR last_seen_at < CURRENT_TIMESTAMP/);
  assert.deepEqual(db.calls[0].params, [120]);
});

test('supurucu: MQTT_OFFLINE_AFTER_SEC ile esik ayarlanir; DB hatasi yutulur', async () => {
  const db = makeFakeDb([{ match: /UPDATE devices SET is_online = FALSE/, reply: new Error('db down') }]);
  const s = setup({ db, env: { ...ENV, MQTT_OFFLINE_AFTER_SEC: '90' } });
  connect(s);
  s.clock.t += 100 * 1000;
  assert.equal(await s.bridge.sweepOffline(), 0);
  assert.deepEqual(db.calls[0].params, [90]);
  assert.equal(s.bridge.counters.dbErrors, 1);
});

test('supurucu zamanlayicisi init ile baslar, end ile durur; end istemciyi kapatir', async () => {
  const s = setup();
  s.bridge.init();
  assert.equal(s.timers.pendingIntervals().length, 1);
  assert.equal(s.timers.pendingIntervals()[0].ms, 30 * 1000);
  await s.bridge.end();
  assert.equal(s.timers.pendingIntervals().length, 0);
  assert.equal(s.client.ended, true);
  assert.equal(s.bridge.isConnected(), false);
  await assert.rejects(() => s.bridge.publishCommand('h_abc', { a: 1 }), BrokerUnavailableError);
  // stop/shutdown takma adlari
  assert.equal(typeof s.bridge.stop, 'function');
  assert.equal(typeof s.bridge.shutdown, 'function');
});

test('getStatus: sayaclar ve baglanti bilgisi (sir icermez)', () => {
  const s = setup();
  connect(s);
  const st = s.bridge.getStatus();
  assert.equal(st.connected, true);
  assert.equal(typeof st.counters.received, 'number');
  assert.ok(!JSON.stringify(st).includes(ENV.MQTT_BACKEND_PASS));
});
