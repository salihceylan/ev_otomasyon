'use strict';

// C8 - Kopru x GERCEK `mqtt` kutuphanesi x minimal loopback broker (test/bridge/_mini_broker.js).
// EMQX yerine GECMEZ; amac: sahte istemcilerin yakalayamayacagi kutuphane davranislarini
// (retain bayragi, QoS1 PUBACK, kalici oturum, yeniden baglanma, giden depo temizligi) denemek.

const test = require('node:test');
const assert = require('node:assert/strict');
const mqtt = require('mqtt');
const { MqttBridge, BrokerUnavailableError } = require('../../src/mqtt_bridge');
const { MiniBroker } = require('./_mini_broker');
const { makeFakeDb, makeLogger } = require('./_helpers');

const HOME = 'h_it';
const DEVICE_ROW = { home_id: 'home-1', device_id: 'dev-1', device_uuid: 'AHBU-S3-IT-0001' };
const PASS = `it-${Math.random().toString(36).slice(2)}-${Date.now()}`; // test icin rastgele, sabit sir degil

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// Zaman asimlari cömert tutulur: Windows'ta kapali loopback portuna baglanti denemeleri ve yuklu CI
// (tum paketler paralel) gecikebilir; basarida bekleme olmaz, yalnizca hata halinde beklenir.
async function waitFor(fn, { timeout = 10000, step = 20, label = 'kosul' } = {}) {
  const t0 = Date.now();
  for (;;) {
    const v = await fn();
    if (v) return v;
    if (Date.now() - t0 > timeout) throw new Error(`zaman asimi: ${label}`);
    await sleep(step);
  }
}

function connectClient(port, opts = {}) {
  return new Promise((resolve, reject) => {
    const c = mqtt.connect(`mqtt://127.0.0.1:${port}`, { reconnectPeriod: 0, clean: true, ...opts });
    c.once('connect', () => resolve(c));
    c.once('error', reject);
  });
}

const publish = (client, topic, payload, opts) =>
  new Promise((resolve, reject) => client.publish(topic, payload, opts, (err) => (err ? reject(err) : resolve())));

const endClient = (c) => new Promise((resolve) => c.end(true, {}, () => resolve()));

function makeBridge(port, extraEnv = {}, extraOpts = {}) {
  const db = makeFakeDb([
    { match: /FROM homes h LEFT JOIN devices d/, reply: { rows: [DEVICE_ROW], rowCount: 1 } },
  ]);
  const logger = makeLogger();
  const bridge = new MqttBridge({
    db,
    logger,
    env: {
      MQTT_HOST: '127.0.0.1',
      MQTT_PORT: String(port),
      MQTT_BACKEND_USER: 'backend_service',
      MQTT_BACKEND_PASS: PASS,
      MQTT_RECONNECT_MIN_MS: '100',
      MQTT_RECONNECT_MAX_MS: '1000',
      MQTT_PUBLISH_TIMEOUT_MS: '300',
      ...extraEnv,
    },
    ...extraOpts,
  });
  return { bridge, db, logger };
}

/** Her test: broker + (istege bagli) kopru + istemciler; hepsi finally'de kapatilir (acik tutamac kalmasin). */
async function withEnv(fn, { brokerOpts = {}, extraEnv = {} } = {}) {
  const broker = new MiniBroker(brokerOpts);
  const port = await broker.listen();
  const env = makeBridge(port, extraEnv);
  const clients = [];
  const track = async (opts) => {
    const c = await connectClient(port, opts);
    clients.push(c);
    return c;
  };
  try {
    await fn({ broker, port, ...env, track });
  } finally {
    await env.bridge.end({ force: true, timeoutMs: 500 }).catch(() => {});
    for (const c of clients) await endClient(c).catch(() => {});
    await broker.stop().catch(() => {});
  }
}

const deviceUpdates = (db) => db.calls.filter((c) => /UPDATE devices SET/.test(c.text));
// Yalnizca KOPRUNUN baglantisini kopar (cihaz istemcisi bagli kalsin ki yeniden gonderilen komutu gorebilsin).
const dropBridge = (broker) => broker.dropConnections((c) => String(c.clientId).startsWith('ev_backend_bridge_'));

test('baglanti: clean=false + sabit clientId + kimlik ortamdan; ev/+/status ve ev/+/state QoS1 abonelik', async () => {
  await withEnv(async ({ broker, bridge }) => {
    bridge.init();
    await waitFor(() => bridge.isConnected(), { label: 'kopru baglandi' });
    await waitFor(() => broker.subscribes.length > 0, { label: 'abonelik' });

    const c = broker.connects[0];
    assert.equal(c.clean, false);
    assert.match(c.clientId, /^ev_backend_bridge_/);
    assert.equal(c.username, 'backend_service');
    assert.equal(c.password, PASS);
    assert.deepEqual(broker.subscribes[0].filters, [
      { topic: 'ev/+/status', qos: 1 },
      { topic: 'ev/+/state', qos: 1 },
    ]);
  });
});

test('RETAINED tekrar teslim: state endpoint gunceller ama is_online DEGISTIRMEZ; canli state cevrimici yapar', async () => {
  await withEnv(async ({ broker, port, bridge, db, track }) => {
    // Kopru baglanmadan once cihaz retained state + status birakir (broker yeniden baslamis gibi)
    const device = await track({ clientId: 'dev-it' });
    await publish(device, `ev/${HOME}/state`, JSON.stringify({ ip: '10.1.1.9', relays: [{ id: 1, state: true }] }), { qos: 1, retain: true });
    await publish(device, `ev/${HOME}/status`, 'online', { qos: 1, retain: true });

    bridge.init();
    await waitFor(() => db.calls.some((c) => /UPDATE endpoints e SET current_state/.test(c.text)), { label: 'retained state islendi' });
    await waitFor(() => db.calls.some((c) => /UPDATE devices d/.test(c.text)), { label: 'retained status islendi' });

    // retained state: cihaz satiri yalnizca ip (is_online/last_seen YOK)
    const retainedDev = deviceUpdates(db).find((c) => c.params.includes('10.1.1.9'));
    assert.ok(retainedDev);
    assert.doesNotMatch(retainedDev.text, /is_online|last_seen_at/);
    // retained status: retain bayragi true -> last_seen ilerletilmez
    const statusCall = db.calls.find((c) => /UPDATE devices d/.test(c.text));
    assert.deepEqual(statusCall.params, [HOME, true, true]);
    assert.equal(bridge.counters.retained, 2);

    // Simdi CANLI state: cevrimici + last_seen
    await publish(device, `ev/${HOME}/state`, JSON.stringify({ ip: '10.1.1.9', relays: [{ id: 1, state: false }] }), { qos: 0, retain: true });
    await waitFor(() => deviceUpdates(db).some((c) => /is_online = TRUE/.test(c.text)), { label: 'canli state' });
    const live = deviceUpdates(db).find((c) => /is_online = TRUE/.test(c.text));
    assert.match(live.text, /last_seen_at = CURRENT_TIMESTAMP/);
    assert.equal(bridge.counters.retained, 2, 'canli mesaj retained sayilmamali');

    // Canli LWT (retain=false teslim): offline
    await publish(device, `ev/${HOME}/status`, 'offline', { qos: 1, retain: true });
    await waitFor(() => db.calls.some((c) => /UPDATE devices d/.test(c.text) && c.params[1] === false), { label: 'LWT offline' });
    const off = db.calls.filter((c) => /UPDATE devices d/.test(c.text)).pop();
    assert.deepEqual(off.params, [HOME, false, false]);
  });
});

test('komut: ev/{t}/cmd QoS1, retain=false, cihaza ulasir; PUBACK ile cozulur', async () => {
  await withEnv(async ({ broker, bridge, track }) => {
    const device = await track({ clientId: 'dev-it' });
    const got = [];
    device.on('message', (topic, payload, packet) => got.push({ topic, payload: payload.toString(), retain: packet.retain, qos: packet.qos }));
    await new Promise((res, rej) => device.subscribe(`ev/${HOME}/cmd`, { qos: 1 }, (e) => (e ? rej(e) : res())));

    bridge.init();
    await waitFor(() => bridge.isConnected());

    const res = await bridge.publishCommand(HOME, { relay: 3, state: true, id: 'it-1' });
    assert.equal(res.topic, `ev/${HOME}/cmd`);
    await waitFor(() => got.length === 1, { label: 'cihaz komutu aldi' });
    assert.deepEqual(JSON.parse(got[0].payload), { relay: 3, state: true, id: 'it-1' });
    assert.equal(got[0].qos, 1);
    assert.equal(got[0].retain, false);

    const sent = broker.publishedOn(`ev/${HOME}/cmd`);
    assert.equal(sent.length, 1);
    assert.equal(sent[0].qos, 1);
    assert.equal(sent[0].retain, false);
    assert.equal(broker.retained.has(`ev/${HOME}/cmd`), false, 'cmd ASLA retained saklanmaz');
  });
});

test('clearRetained: state/status/cmd/sys retained kayitlari broker\'dan SILINIR', async () => {
  await withEnv(async ({ broker, bridge, track }) => {
    const device = await track({ clientId: 'dev-it' });
    for (const k of ['state', 'status', 'cmd', 'sys']) {
      await publish(device, `ev/${HOME}/${k}`, 'x', { qos: 1, retain: true });
    }
    await publish(device, 'ev/h_other/state', 'dokunma', { qos: 1, retain: true });
    assert.equal(broker.retained.size, 5);

    bridge.init();
    await waitFor(() => bridge.isConnected());
    const res = await bridge.clearRetained(HOME);
    assert.equal(res.topics.length, 4);
    for (const k of ['state', 'status', 'cmd', 'sys']) assert.equal(broker.retained.has(`ev/${HOME}/${k}`), false, k);
    assert.equal(broker.retained.has('ev/h_other/state'), true, 'baska evin mesajina dokunulmamali');

    // yeni abone artik retained gormez
    const spy = await track({ clientId: 'spy' });
    const seen = [];
    spy.on('message', (t) => seen.push(t));
    await new Promise((res2, rej) => spy.subscribe(`ev/${HOME}/#`, { qos: 0 }, (e) => (e ? rej(e) : res2())));
    await sleep(100);
    assert.deepEqual(seen, []);
  });
});

test('baglanti kopmasi: kopru "kopuk" olur, komut reddedilir; broker donunce AYNI clientId ile kalici oturumla yeniden baglanir ve yeniden abone olur', async () => {
  await withEnv(async ({ broker, bridge, db, track }) => {
    bridge.init();
    await waitFor(() => bridge.isConnected());
    const firstClientId = broker.connects[0].clientId;
    const subsBefore = broker.subscribes.length;

    broker.dropConnections();
    await waitFor(() => !bridge.isConnected(), { label: 'kopru kopuk' });
    await assert.rejects(() => bridge.publishCommand(HOME, { relay: 1, state: true }), (e) => e instanceof BrokerUnavailableError && e.code === 'BROKER_UNAVAILABLE');

    await waitFor(() => bridge.isConnected(), { timeout: 15000, label: 'yeniden baglandi' });
    const second = broker.connects[1];
    assert.equal(second.clientId, firstClientId, 'clientId sabit olmali');
    assert.equal(second.clean, false);
    assert.equal(second.sessionPresent, true, 'kalici oturum surdurulmeli');
    await waitFor(() => broker.subscribes.length > subsBefore, { label: 'yeniden abonelik' });

    // yeniden baglandiktan sonra mesajlar islenir
    const device = await track({ clientId: 'dev-it' });
    await publish(device, `ev/${HOME}/state`, JSON.stringify({ relays: [{ id: 2, state: true }] }), { qos: 0 });
    await waitFor(() => db.calls.some((c) => /UPDATE endpoints e SET current_state/.test(c.text)), { label: 'kopmadan sonra state islendi' });
  });
});

test('broker hic yokken bekleme suresi USTEL artar (+jitter, tavan 1 sn); broker donunce taban sureye doner', async () => {
  const broker = new MiniBroker();
  const port = await broker.listen();
  const { bridge } = makeBridge(port);
  try {
    bridge.init();
    await waitFor(() => bridge.isConnected());
    const base = bridge.client.options.reconnectPeriod;
    assert.equal(base, 100);

    // Kopru ILK baglantisinin SUBSCRIBE'i, broker durdurulurken henuz broker'a ULASMAMIS olabilir (yukte yaris):
    // yeniden abonelik, "toplam abonelik sayisi" ile DEGIL, sonraki BAGLANTIDA gelen abonelikle dogrulanir.
    const connectsBefore = broker.connects.length;
    await broker.stop(); // dinleme de durur: baglanma denemeleri BASARISIZ
    await waitFor(() => !bridge.isConnected(), { label: 'kopuk' });
    // her basarisiz denemeden sonra sure iki katina cikar (jitter +-%20): en az 160 ms'e ulasmali
    await waitFor(() => bridge.client.options.reconnectPeriod >= 160, { timeout: 20000, label: 'ustel artis' });
    const grown = bridge.client.options.reconnectPeriod;
    assert.ok(grown <= 1200, `tavan (1000 ms + jitter) asilmamali: ${grown}`);

    broker.forgetSessions(); // broker YENIDEN BASLADI: kalici oturumlar ve abonelikler kayip
    await broker.listen(port); // ayni portta geri geldi
    await waitFor(() => bridge.isConnected(), { timeout: 20000, label: 'geri baglandi' });
    assert.equal(bridge.client.options.reconnectPeriod, 100, 'basarili baglantidan sonra taban sure');

    // oturum yoktu (sessionPresent=false): kopru ACIKCA yeniden abone olmali; yoksa hic mesaj almazdi
    assert.equal(broker.connects[broker.connects.length - 1].sessionPresent, false);
    await waitFor(
      () => broker.subscribes.some((s) => s.connectSeq >= connectsBefore && s.filters.length === 2 && String(s.clientId).startsWith('ev_backend_bridge_')),
      { label: 'yeniden abonelik' }
    );
    const device = await connectClient(port, { clientId: 'dev-after-restart' });
    try {
      await publish(device, `ev/${HOME}/state`, JSON.stringify({ relays: [{ id: 4, state: true }] }), { qos: 0 });
      await waitFor(() => bridge.db.calls.some((c) => /UPDATE endpoints e SET current_state/.test(c.text)), { label: 'yeniden basladiktan sonra state islendi' });
    } finally {
      await endClient(device);
    }
  } finally {
    await bridge.end({ force: true, timeoutMs: 500 }).catch(() => {});
    await broker.stop().catch(() => {});
  }
});

test('PUBACK gelmezse komut reddedilir ve BAYAT KOMUT yeniden baglanmada TEKRAR GONDERILMEZ', async () => {
  await withEnv(async ({ broker, bridge, track }) => {
    const device = await track({ clientId: 'dev-it' });
    const got = [];
    device.on('message', (_t, payload) => got.push(payload.toString()));
    await new Promise((res, rej) => device.subscribe(`ev/${HOME}/cmd`, { qos: 1 }, (e) => (e ? rej(e) : res())));

    bridge.init();
    await waitFor(() => bridge.isConnected());

    broker.ackPublishes = false; // broker iletir ama PUBACK vermez
    await assert.rejects(() => bridge.publishCommand(HOME, { relay: 1, state: true, id: 'stale' }), BrokerUnavailableError);
    await waitFor(() => got.length === 1, { label: 'ilk (kopruden cikan) teslim' });

    // Broker duzeldi ve baglanti koptu: kalici oturumla yeniden baglanma, giden depoda KALAN paketi
    // yeniden gonderirdi (kaldirilmadiysa). Kaldirildigi icin cihaz ikinci kopya ALMAMALI.
    broker.ackPublishes = true;
    dropBridge(broker);
    await waitFor(() => !bridge.isConnected());
    await waitFor(() => bridge.isConnected(), { timeout: 15000, label: 'yeniden baglandi' });
    await sleep(600);
    assert.equal(got.length, 1, `bayat komut tekrar teslim edildi: ${got.length} kopya`);
    assert.equal(broker.publishedOn(`ev/${HOME}/cmd`).length, 1, 'broker yeniden gonderilen paket gormemeli');
  });
});

test('KONTROL: giden depodan silme olmasaydi ayni senaryoda bayat komut yeniden gonderilirdi (test duyarli mi?)', async () => {
  await withEnv(async ({ broker, bridge, track }) => {
    const device = await track({ clientId: 'dev-it' });
    const got = [];
    device.on('message', (_t, payload) => got.push(payload.toString()));
    await new Promise((res, rej) => device.subscribe(`ev/${HOME}/cmd`, { qos: 1 }, (e) => (e ? rej(e) : res())));

    bridge.init();
    await waitFor(() => bridge.isConnected());
    // temizligi devre disi birak (kopru mantigini degistirmeden istemci yuzeyini)
    bridge.client.removeOutgoingMessage = () => bridge.client;

    broker.ackPublishes = false;
    await assert.rejects(() => bridge.publishCommand(HOME, { relay: 1, state: true, id: 'stale' }), BrokerUnavailableError);
    await waitFor(() => got.length === 1);
    broker.ackPublishes = true;
    dropBridge(broker);
    await waitFor(() => !bridge.isConnected());
    await waitFor(() => bridge.isConnected(), { timeout: 15000 });
    await sleep(600);
    // mqtt.js kalici oturumda PUBACK'i gelmemis QoS1 paketi yeniden baglaninca YENIDEN GONDERIR:
    // koruma olmasa bayat komut ikinci kez cihaza ulasirdi. Bu, korumanin gerekli oldugunu kanitlar.
    assert.equal(got.length, 2, `koruma kapaliyken bayat komutun yeniden gonderilmesi beklenir (gelen: ${got.length})`);
  });
});

test('abonelik reddi (SUBACK 0x80): kopru bunu hata olarak gorur, "baglandi" diye gostermez', async () => {
  await withEnv(
    async ({ bridge, logger }) => {
      bridge.init();
      await waitFor(() => logger.lines.some((l) => l.includes('REDDEDILDI')), { label: 'ret loglandi' });
      assert.ok(!logger.lines.some((l) => l.includes('Dinlenen konular')));
      assert.ok(bridge.isConnected(), 'baglanti var ama abonelik yok: yeniden denenecek');
    },
    { brokerOpts: { rejectSubscribe: () => true } }
  );
});

test('kapanis: end() suruculeri durdurur, sonraki yayin reddedilir', async () => {
  await withEnv(async ({ bridge }) => {
    bridge.init();
    await waitFor(() => bridge.isConnected());
    await bridge.end();
    assert.equal(bridge.isConnected(), false);
    await assert.rejects(() => bridge.publishCommand(HOME, { a: 1 }), BrokerUnavailableError);
  });
});
