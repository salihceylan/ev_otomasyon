'use strict';

// SERVIS-01 - Uzlastirici: BEKLEYEN yerel anahtar (devices.local_key_pending_enc; acil sifirlama pano cevrimdisiyken
// yazar) cihaz CANLI olarak cevrimici olunca `ev/{t}/sys {cmd:'set_local_key', local_key, id}` ile iletilir; PUBACK
// sonrasi CAS ile takas edilir (gecerli = bekleyen, bekleyen = NULL) + envanter ayni degere + denetim kaydi (anahtarsiz).
// Basarisizsa bekleyen KALIR (ustel bekleme; sonraki cevrimici donemde yeniden). Anahtar ASLA loglanmaz.

const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');

process.env.LOCAL_KEY_SECRET = crypto.randomBytes(32).toString('hex');
const secretBox = require('../../src/utils/secret_box');

const { MqttBridge, KeyedWorkQueue } = require('../../src/mqtt_bridge');
const { createDeviceReconciler, SQL, constants } = require('../../src/services/device_reconciler');
const { makeFakeTimers, makeLogger, makeFakeClient, makeFakeMqttLib, makeFakeDb, flush } = require('./_helpers');

const { SETTLE_MS, BACKOFF_BASE_MS } = constants;
const T0 = Date.parse('2026-10-04T12:00:00Z');
const TOPIC = 'h_aaaaaaaaaaaaaaaa';
const CMD_ID_RE = /^[A-Za-z0-9._:-]{1,24}$/;

function makeWorld() {
  const w = {
    now: T0,
    homes: new Map(), // topic -> { id }
    devices: [], // { id, uuid, topic, live, currentEnc, pendingEnc, pendingAt }
    inventory: new Map(), // uuid -> { id, enc }
    audits: [],
    queries: [],
    sys: [], // basarili sys yayinlari { topic, obj }
    sysAttempts: 0,
    failSys: false,
    onSys: null, // yayin sirasinda calisacak kanca (es zamanli degisiklik taklidi)
    connected: true,
  };
  w.addHome = (topic) => {
    const h = { id: crypto.randomUUID() };
    w.homes.set(topic, h);
    return h;
  };
  w.addDevice = (topic, uuid, { live = true, currentKey = 'GecerliAnahtar12', pendingKey = null } = {}) => {
    const d = {
      id: crypto.randomUUID(),
      uuid,
      topic,
      live,
      currentEnc: secretBox.encrypt(currentKey),
      pendingEnc: pendingKey ? secretBox.encrypt(pendingKey) : null,
      pendingAt: pendingKey ? new Date(w.now) : null,
    };
    w.devices.push(d);
    w.inventory.set(uuid, { id: crypto.randomUUID(), enc: d.currentEnc });
    return d;
  };
  const byTopic = (topic) => w.devices.filter((d) => d.topic === topic);
  w.db = {
    async query(text, params) {
      w.queries.push({ text, params });
      switch (text) {
        case SQL.childLock:
        case SQL.runtimePending:
          return { rows: [] };
        case SQL.localKeyPending: {
          const h = w.homes.get(params[0]);
          if (!h) return { rows: [] };
          const devs = byTopic(params[0]);
          return {
            rows: devs.filter((d) => d.pendingEnc).map((d) => ({
              home_id: h.id, device_id: d.id, device_uuid: d.uuid, pending_enc: d.pendingEnc, live: d.live, device_count: devs.length,
            })),
          };
        }
        case SQL.localKeyLockInventory: {
          const inv = w.inventory.get(params[0]);
          return { rows: inv ? [{ id: inv.id }] : [] };
        }
        case SQL.localKeySwap: {
          const d = w.devices.find((x) => x.id === params[0]);
          if (d && d.pendingEnc === params[1]) {
            d.currentEnc = d.pendingEnc;
            d.pendingEnc = null;
            d.pendingAt = null;
            return { rows: [], rowCount: 1 };
          }
          return { rows: [], rowCount: 0 };
        }
        case SQL.localKeyInventory: {
          const inv = w.inventory.get(params[0]);
          if (inv) inv.enc = params[1];
          return { rows: [], rowCount: inv ? 1 : 0 };
        }
        case SQL.localKeyAudit:
          w.audits.push({ uuid: params[0], homeId: params[1], details: JSON.parse(params[2]) });
          return { rows: [], rowCount: 1 };
        default:
          throw new Error(`beklenmeyen sorgu: ${String(text).slice(0, 60)}`);
      }
    },
    async withTransaction(fn) {
      return fn({ query: (t, p) => w.db.query(t, p) });
    },
  };
  w.publishSys = async (topic, obj) => {
    w.sysAttempts += 1;
    if (w.onSys) await w.onSys(topic, obj);
    if (w.failSys) throw Object.assign(new Error('broker down'), { code: 'BROKER_UNAVAILABLE' });
    w.sys.push({ topic, obj: JSON.parse(JSON.stringify(obj)) });
    return {};
  };
  return w;
}

function makeRec(w, extra = {}) {
  const timers = makeFakeTimers();
  const logger = makeLogger();
  const rec = createDeviceReconciler({
    db: w.db,
    publishCommand: async () => { throw new Error('cmd yayini beklenmiyordu'); },
    publishSys: w.publishSys,
    secretBox,
    isConnected: () => w.connected,
    logger,
    now: () => w.now,
    timers,
    offlineAfterSec: 120,
    QueueClass: KeyedWorkQueue,
    sleep: async () => {},
    ...extra,
  });
  return { rec, timers, logger };
}

const live = (rec, w, topic, device) => rec.onLiveState({ topicId: topic, homeId: w.homes.get(topic).id, deviceId: device.id });

async function runTimer(w, rec, timers, expectedDelay) {
  const pending = timers.pendingTimeouts();
  assert.equal(pending.length, 1, `tam bir zamanlayici bekleniyordu (${pending.length})`);
  const [h] = pending;
  if (expectedDelay !== undefined) assert.equal(h.ms, expectedDelay, 'zamanlayici suresi');
  w.now += h.ms;
  timers.fireTimeout(h);
  await rec.whenIdle();
}

function assertNoSecretInLogs(logger, key, enc) {
  for (const line of logger.lines) {
    assert.ok(!line.includes(key), `anahtar log'a yazilmis: ${line}`);
    if (enc) assert.ok(!line.includes(enc), `sifreli deger log'a yazilmis: ${line}`);
  }
}

test('cevrimici donem basinda bekleyen anahtar: sys set_local_key yayinlanir; PUBACK sonrasi CAS takas + envanter + denetim (anahtarsiz)', async () => {
  const w = makeWorld();
  w.addHome(TOPIC);
  const d = w.addDevice(TOPIC, 'AHBU-S3-0001', { pendingKey: 'YeniAnahtar98765' });
  const pendingEnc = d.pendingEnc;
  const { rec, timers, logger } = makeRec(w);

  live(rec, w, TOPIC, d);
  assert.equal(w.queries.length, 0, 'tetik aninda sorgu yok');
  await runTimer(w, rec, timers, SETTLE_MS);

  assert.equal(w.sys.length, 1);
  assert.equal(w.sys[0].topic, TOPIC);
  assert.deepEqual(Object.keys(w.sys[0].obj).sort(), ['cmd', 'id', 'local_key']);
  assert.equal(w.sys[0].obj.cmd, 'set_local_key');
  assert.equal(w.sys[0].obj.local_key, 'YeniAnahtar98765');
  assert.match(w.sys[0].obj.id, CMD_ID_RE);

  assert.equal(d.currentEnc, pendingEnc, 'gecerli anahtar = bekleyen');
  assert.equal(d.pendingEnc, null);
  assert.equal(d.pendingAt, null);
  assert.equal(w.inventory.get('AHBU-S3-0001').enc, pendingEnc, 'envanter ayni sifreli degere');
  assert.equal(w.audits.length, 1);
  assert.equal(w.audits[0].uuid, 'AHBU-S3-0001');
  assert.equal(w.audits[0].homeId, w.homes.get(TOPIC).id);
  assert.ok(!JSON.stringify(w.audits[0]).includes('YeniAnahtar98765') && !JSON.stringify(w.audits[0]).includes(pendingEnc));
  // kilit sirasi: once envanter (acil sifirlama / claim ile ayni), sonra cihaz CAS
  const order = w.queries.map((q) => q.text).filter((t) => [SQL.localKeyLockInventory, SQL.localKeySwap, SQL.localKeyInventory, SQL.localKeyAudit].includes(t));
  assert.deepEqual(order, [SQL.localKeyLockInventory, SQL.localKeySwap, SQL.localKeyInventory, SQL.localKeyAudit]);
  assert.equal(rec.stats().localKeyRotated, 1);
  assertNoSecretInLogs(logger, 'YeniAnahtar98765', pendingEnc);
  assert.ok(logger.lines.some((l) => /yerel_anahtar .*sonuc=uygulandi/.test(l)), logger.lines.join('\n'));
  assert.equal(timers.pendingTimeouts().length, 0, 'tamamlandi: yeniden kontrol yok');
});

test('yayin BASARISIZ: bekleyen anahtar KALIR (takas/envanter/denetim yok); ustel bekleme sonrasi yeniden denenir', async () => {
  const w = makeWorld();
  w.addHome(TOPIC);
  const d = w.addDevice(TOPIC, 'AHBU-S3-0001', { pendingKey: 'YeniAnahtar98765' });
  const before = { current: d.currentEnc, pending: d.pendingEnc };
  const { rec, timers, logger } = makeRec(w);
  w.failSys = true;

  live(rec, w, TOPIC, d);
  await runTimer(w, rec, timers, SETTLE_MS);
  assert.equal(w.sysAttempts, 1);
  assert.deepEqual({ current: d.currentEnc, pending: d.pendingEnc }, before, 'hicbir sey degismez');
  assert.equal(w.inventory.get('AHBU-S3-0001').enc, before.current);
  assert.equal(w.audits.length, 0);
  assert.ok(!w.queries.some((q) => q.text === SQL.localKeySwap), 'basarisiz yayinda takas denenmez');
  assertNoSecretInLogs(logger, 'YeniAnahtar98765', before.pending);

  // ustel bekleme (5 sn) sonra ikinci deneme basarili
  w.failSys = false;
  await runTimer(w, rec, timers, BACKOFF_BASE_MS);
  assert.equal(w.sys.length, 1);
  assert.equal(d.currentEnc, before.pending);
  assert.equal(d.pendingEnc, null);
});

test('cevrimdisi (canli degil) cihaza yayin DENENMEZ; bekleyen kalir', async () => {
  const w = makeWorld();
  w.addHome(TOPIC);
  const d = w.addDevice(TOPIC, 'AHBU-S3-0001', { pendingKey: 'YeniAnahtar98765', live: false });
  const { rec, timers } = makeRec(w);
  live(rec, w, TOPIC, d);
  await runTimer(w, rec, timers, SETTLE_MS);
  assert.equal(w.sysAttempts, 0);
  assert.ok(d.pendingEnc);
});

test('kopru brokere bagli degil: yayin denenmez, deneme hakki harcanmaz; baglanti donunce uygulanir', async () => {
  const w = makeWorld();
  w.addHome(TOPIC);
  const d = w.addDevice(TOPIC, 'AHBU-S3-0001', { pendingKey: 'YeniAnahtar98765' });
  const { rec, timers } = makeRec(w);
  w.connected = false;
  live(rec, w, TOPIC, d);
  await runTimer(w, rec, timers, SETTLE_MS);
  assert.equal(w.sysAttempts, 0);
  w.connected = true;
  await runTimer(w, rec, timers); // NOT_CONNECTED_RETRY_MS sonra
  assert.equal(w.sys.length, 1);
  assert.equal(d.pendingEnc, null);
});

test('cok panolu ev: ev konusu tum panolara gider -> otomatik iletilmez (atlanir, bir kez uyarilir)', async () => {
  const w = makeWorld();
  w.addHome(TOPIC);
  const a = w.addDevice(TOPIC, 'AHBU-S3-000A', { pendingKey: 'YeniAnahtar98765' });
  w.addDevice(TOPIC, 'AHBU-S3-000B');
  const { rec, timers, logger } = makeRec(w);
  live(rec, w, TOPIC, a);
  await runTimer(w, rec, timers, SETTLE_MS);
  assert.equal(w.sysAttempts, 0);
  assert.ok(a.pendingEnc);
  assert.ok(logger.lines.some((l) => /yerel_anahtar .*atlandi/.test(l)), logger.lines.join('\n'));
});

test('CAS: yayin sirasinda bekleyen anahtar degistiyse (yeni acil sifirlama) takas YAPILMAZ; envanter/denetim yok', async () => {
  const w = makeWorld();
  w.addHome(TOPIC);
  const d = w.addDevice(TOPIC, 'AHBU-S3-0001', { pendingKey: 'YeniAnahtar98765' });
  const newer = secretBox.encrypt('DahaYeniAnahtar1');
  w.onSys = async () => { d.pendingEnc = newer; }; // es zamanli REST yazimi
  const invBefore = w.inventory.get('AHBU-S3-0001').enc;
  const currentBefore = d.currentEnc;
  const { rec, timers } = makeRec(w);
  live(rec, w, TOPIC, d);
  await runTimer(w, rec, timers, SETTLE_MS);
  assert.equal(d.pendingEnc, newer, 'yeni bekleyen korunur');
  assert.equal(d.currentEnc, currentBefore);
  assert.equal(w.inventory.get('AHBU-S3-0001').enc, invBefore);
  assert.equal(w.audits.length, 0);
});

test('bozuk / cozulemeyen bekleyen deger: yayin YAPILMAZ, hata sayilir, log sir icermez', async () => {
  const w = makeWorld();
  w.addHome(TOPIC);
  const d = w.addDevice(TOPIC, 'AHBU-S3-0001', { pendingKey: 'YeniAnahtar98765' });
  d.pendingEnc = 'v1:bozuk:deger:xx';
  const { rec, timers, logger } = makeRec(w);
  live(rec, w, TOPIC, d);
  await runTimer(w, rec, timers, SETTLE_MS);
  assert.equal(w.sysAttempts, 0);
  assert.ok(rec.stats().errors >= 1);
  assertNoSecretInLogs(logger, 'YeniAnahtar98765', 'v1:bozuk:deger:xx');
});

test('publishSys verilmezse yerel anahtar uzlastirmasi KAPALI: ek sorgu yok (eski kurulumlar)', async () => {
  const w = makeWorld();
  w.addHome(TOPIC);
  const d = w.addDevice(TOPIC, 'AHBU-S3-0001', { pendingKey: 'YeniAnahtar98765' });
  const { rec, timers } = makeRec(w, { publishSys: undefined });
  live(rec, w, TOPIC, d);
  await runTimer(w, rec, timers, SETTLE_MS);
  assert.ok(!w.queries.some((q) => q.text === SQL.localKeyPending));
  assert.ok(d.pendingEnc);
});

test('tek-ucus: ayni ev icin es zamanli iki kontrol TEK yayin uretir', async () => {
  const w = makeWorld();
  w.addHome(TOPIC);
  w.addDevice(TOPIC, 'AHBU-S3-0001', { pendingKey: 'YeniAnahtar98765' });
  const { rec } = makeRec(w);
  await Promise.all([rec.checkNow(TOPIC), rec.checkNow(TOPIC), rec.checkNow(TOPIC)]);
  await rec.whenIdle();
  assert.equal(w.sys.length, 1);
});

test('rearm: ayni cevrimici donemde yeni niyet yazilinca SONRAKI canli state kontrol planlar (K1: kopru kisa kopuklugu)', async () => {
  const w = makeWorld();
  w.addHome(TOPIC);
  const d = w.addDevice(TOPIC, 'AHBU-S3-0001');
  const { rec, timers } = makeRec(w);
  live(rec, w, TOPIC, d);
  await runTimer(w, rec, timers, SETTLE_MS); // bekleyen yok: hicbir sey
  w.now += 30 * 1000;
  live(rec, w, TOPIC, d); // ayni donem: kontrol planlanmaz
  assert.equal(timers.pendingTimeouts().length, 0);

  d.pendingEnc = secretBox.encrypt('YeniAnahtar98765'); // acil sifirlama BEKLEYEN yazdi
  rec.rearm(TOPIC);
  w.now += 30 * 1000;
  live(rec, w, TOPIC, d);
  await runTimer(w, rec, timers, SETTLE_MS);
  assert.equal(w.sys.length, 1);
  assert.equal(d.pendingEnc, null);
});

// ------------------------------------------------------------------------------------------------
// Kopru baglantisi: gercek MqttBridge, uzlastiriciya publishSys (ev/{t}/sys, QoS1, retain=false) baglanir
// ------------------------------------------------------------------------------------------------
test('kopru: uzlastirici sys yayinini kopru yolundan yapar (ev/{t}/sys, QoS1, retain=false); requestReconcile yeniden kurar', async () => {
  const w = makeWorld();
  const home = w.addHome(TOPIC);
  const d = w.addDevice(TOPIC, 'AHBU-S3-0001', { pendingKey: 'YeniAnahtar98765' });
  const db = makeFakeDb([
    { match: /FROM homes h LEFT JOIN devices d/, reply: { rows: [{ home_id: home.id, device_id: d.id, device_uuid: d.uuid }], rowCount: 1 } },
  ]);
  const baseQuery = db.query;
  db.query = (text, params) => (Object.values(SQL).includes(text) ? w.db.query(text, params) : baseQuery(text, params));
  db.withTransaction = (fn) => fn({ query: (t, p) => db.query(t, p) });
  const timers = makeFakeTimers();
  const client = makeFakeClient();
  const logger = makeLogger();
  const bridge = new MqttBridge({
    db,
    logger,
    env: { MQTT_BACKEND_USER: 'u', MQTT_BACKEND_PASS: 'p' },
    now: () => w.now,
    timers,
    mqttLib: makeFakeMqttLib(client),
    reconcile: true,
  });
  bridge.init();
  client.connected = true;
  client.emit('connect', { sessionPresent: false });
  await flush();
  try {
    bridge.requestReconcile(TOPIC); // uzlastirici henuz yokken de guvenli (tembel kurulur)
    await bridge.handleIncomingMessage(`ev/${TOPIC}/state`, Buffer.from(JSON.stringify({ uid: d.uuid })), { retain: false });
    const settle = timers.pendingTimeouts().filter((t) => t.ms === SETTLE_MS);
    assert.equal(settle.length, 1);
    w.now += SETTLE_MS;
    timers.fireTimeout(settle[0]);
    await bridge._reconciler.whenIdle();
    await flush();
    const sys = client.published.filter((p) => p.topic === `ev/${TOPIC}/sys`);
    assert.equal(sys.length, 1);
    assert.deepEqual(sys[0].opts, { qos: 1, retain: false });
    assert.equal(JSON.parse(sys[0].payload).local_key, 'YeniAnahtar98765');
    assert.equal(d.pendingEnc, null, 'PUBACK sonrasi takas');
    assertNoSecretInLogs(logger, 'YeniAnahtar98765');
  } finally {
    await bridge.end({ force: true, timeoutMs: 20 });
  }
});
