'use strict';

// C11 - Kopru <-> firmware SOZLESMESI (docs/CONTRACTS.md §2.4 ve §3b: firmware'in GERCEKLESMIS davranisi).
//
// Cihaz tarafinin gercek davranisi:
//   (1) `state` ve `status` QoS 0 yayinlanir; yalniz LWT (QoS 1, retained "offline") garantilidir.
//   (2) `state.last_id` bossa ALAN HIC YOKTUR (yok = gecerli; bayat/hata degil).
//   (3) `state.shutters[]` yalnizca YAPILANDIRILMIS (YUKARI+ASAGI) ciftleri icerir (pair 1 tabanli).
//   (4) `state.uid = "AHBU-S3-" + MAC son 3 bayt (6 hex, buyuk harf)`; clientId `ESP32S3_<12 hex MAC>`.
//   (5) `relays[].type` metindir.
//   (6) `child_lock` her state'te vardir.
//   (7) degisiklikte ~0.4 sn (250 ms birlestirme) ve 30 sn'de bir state yayinlanir.
//
// Gercek veritabani/broker yoktur (sahte db). Gercek PostgreSQL karsiligi: pg_integration.test.js (C11 testleri).

const test = require('node:test');
const assert = require('node:assert/strict');
const { MqttBridge, helpers, KeyedWorkQueue } = require('../../src/mqtt_bridge');
const { makeFakeDb, makeLogger, flush } = require('./_helpers');

const HOME = 'h_0123456789abcdef';
const HOME_ID = '11111111-1111-4111-8111-111111111111';
const DEV = { home_id: HOME_ID, device_id: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', device_uuid: 'AHBU-S3-1A2B3C' };

/** Firmware'in yayinladigi `state` yuku (CONTRACTS §2.4 + §3b): last_id ALANI YOK. */
function firmwareState(over = {}) {
  const base = {
    v: 2,
    uid: 'AHBU-S3-1A2B3C',
    fw: '1.1.0',
    seq: 1234,
    uptime: 3600,
    ip: '192.168.1.30',
    child_lock: false,
    relays: [
      { id: 1, name: 'Salon Panjur Yukarı', type: 'shutter', state: false },
      { id: 2, name: 'Salon Panjur Aşağı', type: 'shutter', state: false },
      { id: 3, name: 'Salon Avize', type: 'light', state: true },
      { id: 4, name: 'Kombi', type: 'impulse', state: false },
    ],
    shutters: [{ pair: 1, pos: 100, moving: false, dir: 0, target: 255 }],
    dis: [{ id: 1, state: false }, { id: 2, state: true }],
  };
  return { ...base, ...over };
}

function setup(devices = [DEV]) {
  const db = makeFakeDb([
    {
      match: /FROM homes h LEFT JOIN devices d/,
      reply: (_t, params) => (params[0] === HOME ? { rows: devices, rowCount: devices.length } : { rows: [], rowCount: 0 }),
    },
  ]);
  const logger = makeLogger();
  const bridge = new MqttBridge({ db, logger, env: {}, now: () => 1_700_000_000_000 });
  return { bridge, db, logger };
}

const send = (bridge, obj, retain = false, topic = HOME) => bridge.handleIncomingMessage(`ev/${topic}/state`, Buffer.from(JSON.stringify(obj)), { retain });
const writes = (db) => db.calls.filter((c) => /^UPDATE /.test(c.text));
const warnings = (logger) => logger.lines.filter((l) => l.startsWith('warn:'));

// ------------------------------------------------------------------------------
// (2) last_id alani hic yok
// ------------------------------------------------------------------------------
test('C11 (2): last_id ALANI HIC YOKSA state gecerli: atlanan alan/uyari/gecersiz sayaci YOK, ack yazilmaz', async () => {
  const payload = firmwareState();
  assert.equal(Object.prototype.hasOwnProperty.call(payload, 'last_id'), false, 'firmware bos last_id alanini hic yollamaz');

  const check = helpers.validateStatePayload(payload);
  assert.equal(check.ok, true);
  assert.equal(check.value.skipped, 0, 'yok = gecerli; atlanan alan sayilmaz');
  assert.equal(check.value.lastId, null);

  const { bridge, db, logger } = setup();
  await send(bridge, payload);
  assert.equal(bridge.counters.invalid, 0);
  assert.deepEqual(warnings(logger), [], 'her kalp atisinda uyari uretmemeli');
  const dev = writes(db).find((c) => /^UPDATE devices SET/.test(c.text));
  assert.ok(dev, 'cihaz telemetrisi yazilmali');
  assert.doesNotMatch(dev.text, /last_ack/, 'last_id yokken ack alanlarina DOKUNULMAZ (onceki ack silinmez)');
  assert.match(dev.text, /is_online = TRUE/);
});

test('C11 (2): ack sonrasi gelen last_id\'siz kalp atislari onceki ack\'i BOZMAZ (hicbir sorgu last_ack\'i degistirmez)', async () => {
  const { bridge, db } = setup();
  await send(bridge, firmwareState({ last_id: 'cmd-7' }));
  const first = writes(db).filter((c) => /last_ack_id = /.test(c.text));
  assert.equal(first.length, 1, 'ilk mesaj ack yazar');
  const before = db.calls.length;

  for (let i = 0; i < 3; i++) await send(bridge, firmwareState({ seq: 2000 + i }));
  const later = db.calls.slice(before).filter((c) => /last_ack/.test(c.text));
  assert.deepEqual(later, [], 'last_id yokken ack satirina dokunan SQL olmamali');
});

// ------------------------------------------------------------------------------
// (3) shutters[] yalnizca yapilandirilmis ciftler
// ------------------------------------------------------------------------------
test('C11 (3): shutters[] yalniz raporlanan cifti gunceller; eksik cift ASLA silinmez/sifirlanmaz', async () => {
  const { bridge, db } = setup();

  // iki cift yapilandirilmis -> sonra yalniz cift 2 -> sonra bos dizi -> sonra alan hic yok
  await send(bridge, firmwareState({ shutters: [{ pair: 1, pos: 30 }, { pair: 2, pos: 60 }] }));
  await send(bridge, firmwareState({ shutters: [{ pair: 2, pos: 40, moving: true, dir: 2, target: 10 }] }));
  await send(bridge, firmwareState({ shutters: [] }));
  const { shutters, ...noShutters } = firmwareState();
  await send(bridge, noShutters);

  const shutterWrites = writes(db).filter((c) => /SET current_position/.test(c.text));
  assert.equal(shutterWrites.length, 2, 'bos dizi ve alansiz mesajlar panjur yazmaz');
  assert.deepEqual(shutterWrites[0].params, [DEV.device_id, 1, 30, 2, 60]);
  assert.deepEqual(shutterWrites[1].params, [DEV.device_id, 2, 40], 'yalniz cift 2: cift 1 parametre listesinde YOK');

  const all = db.calls.map((c) => c.text).join('\n');
  assert.doesNotMatch(all, /DELETE/i, 'eksik cift icin silme yok');
  assert.doesNotMatch(all, /current_position\s*=\s*0\b/, 'eksik cift sifirlanmaz');
});

test('C11 (3): pair 1 tabanli - pair 0 / pair 33 / pos disi degerler atlanir, gecerli cift yazilir', () => {
  const r = helpers.validateStatePayload({ shutters: [{ pair: 0, pos: 10 }, { pair: 1, pos: 10 }, { pair: 33, pos: 10 }, { pair: 2, pos: 101 }, { pair: 2, pos: 100 }] });
  assert.deepEqual(r.value.shutters, [{ pair: 1, pos: 10 }, { pair: 2, pos: 100 }]);
  assert.equal(r.value.skipped, 3);
});

// ------------------------------------------------------------------------------
// (4) uid / clientId bicimi
// ------------------------------------------------------------------------------
test('C11 (4): uid "AHBU-S3-" + 6 hex BUYUK harf; kucuk/karisik harf ve veritabaninda kucuk harfli kayit da eslesir', async () => {
  for (const [wire, stored] of [
    ['AHBU-S3-1A2B3C', 'AHBU-S3-1A2B3C'],
    ['ahbu-s3-1a2b3c', 'AHBU-S3-1A2B3C'],
    ['Ahbu-S3-1a2B3c', 'AHBU-S3-1A2B3C'],
    ['AHBU-S3-1A2B3C', 'ahbu-s3-1a2b3c'], // fabrika araci kucuk harfle kaydetmis olsa da
  ]) {
    const { bridge, db } = setup([{ ...DEV, device_uuid: stored }]);
    await send(bridge, firmwareState({ uid: wire }));
    const dev = writes(db).find((c) => /^UPDATE devices SET/.test(c.text));
    assert.ok(dev, `uid ${wire} / kayit ${stored} eslesmeli`);
    assert.equal(dev.params[0], DEV.device_id);
  }
});

test('C11 (4): ayni evdeki iki cihaz kendi uid\'siyle eslesir; bilinmeyen uid yok sayilir ve hicbir sey yazilmaz', async () => {
  const B = { home_id: HOME_ID, device_id: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', device_uuid: 'AHBU-S3-FFEEDD' };
  const { bridge, db } = setup([DEV, B]);
  await send(bridge, firmwareState({ uid: 'AHBU-S3-FFEEDD', ip: '192.168.1.99' }));
  const dev = writes(db).find((c) => /^UPDATE devices SET/.test(c.text));
  assert.equal(dev.params[0], B.device_id);
  assert.equal(dev.params[1], '192.168.1.99');

  const before = writes(db).length;
  await send(bridge, firmwareState({ uid: 'AHBU-S3-000000' }));
  assert.equal(writes(db).length, before, 'tanimsiz uid: yazim yok');
  assert.equal(bridge.counters.ignored, 1);
});

test('C11 (4): beklenmedik uid bicimleri (clientId bicimi, bos, sayi, null) dogrulayiciyi cokertmez; kopru clientId ile ESLEME YAPMAZ', () => {
  // Eslesme yalniz state.uid ile; clientId (ESP32S3_<12 hex MAC>) kopru icin anlamsizdir.
  for (const uid of ['ESP32S3_A1B2C3D4E5F6', 'AHBU-S3-1A2B3C', 'x', '', 12345, null, {}, 'AHBU S3 1A2B3C']) {
    const r = helpers.validateStatePayload({ uid });
    assert.equal(r.ok, true);
  }
  assert.equal(helpers.validateStatePayload({ uid: 'ahbu-s3-1a2b3c' }).value.uid, 'AHBU-S3-1A2B3C');
  assert.equal(helpers.validateStatePayload({ uid: 'x' }).value.uid, null, 'cok kisa uid atlanir');
});

// ------------------------------------------------------------------------------
// (5) relays[].type metin, (6) child_lock her state'te
// ------------------------------------------------------------------------------
test('C11 (5): relays[].type metin (light/shutter/impulse/plug); ek alanlar (name/type) kopruyu etkilemez, atlama sayilmaz', () => {
  const r = helpers.validateStatePayload({
    relays: [
      { id: 1, name: 'Salon Avize', type: 'light', state: true },
      { id: 2, name: 'Kombi / Termostat Rölesi', type: 'impulse', state: false },
      { id: 3, type: 'plug', state: true, runtime_sec: 20 },
      { id: 4, type: 7, state: false }, // beklenmedik tur: kopru type KULLANMAZ, atlanmaz
    ],
  });
  assert.equal(r.value.skipped, 0);
  assert.deepEqual(r.value.relays, [
    { id: 1, state: true },
    { id: 2, state: false },
    { id: 3, state: true },
    { id: 4, state: false },
  ]);
});

test('C11 (6): child_lock her state\'te var: canli state her seferinde devices + homes\'u TEK transaction\'da esitler', async () => {
  const { bridge, db } = setup();
  for (const lock of [false, true, true, false]) await send(bridge, firmwareState({ child_lock: lock }));
  assert.equal(db.txLog.filter((x) => x === 'BEGIN').length, 4);
  assert.equal(db.txLog.filter((x) => x === 'COMMIT').length, 4);
  const lockWrites = writes(db).filter((c) => /^UPDATE devices SET[\s\S]*child_lock_enabled = \$\d+/.test(c.text));
  assert.deepEqual(lockWrites.map((c) => c.params[c.params.length - 1]), [false, true, true, false]);
  assert.equal(writes(db).filter((c) => /^UPDATE homes h SET child_lock_enabled/.test(c.text)).length, 4);
});

// ------------------------------------------------------------------------------
// (1) QoS 0 durum + LWT QoS 1 retained "offline"
// ------------------------------------------------------------------------------
test('C11 (1): QoS koprude hicbir kararda kullanilmaz - canli state/status ayni sekilde islenir (handleIncomingMessage QoS almaz)', async () => {
  const { bridge, db } = setup();
  await bridge.handleIncomingMessage(`ev/${HOME}/status`, Buffer.from('online'), { retain: false });
  await send(bridge, firmwareState());
  assert.ok(db.calls.some((c) => /UPDATE devices d/.test(c.text) && c.params[1] === true), 'status online islenir');
  assert.ok(db.calls.some((c) => /^UPDATE devices SET/.test(c.text)), 'state islenir');
});

test('C11 (1): LWT "offline" (canli, retain=false) sonrasi ilk canli state cihazi yeniden cevrimici yapar (kayip "online" status\'u telafisi)', async () => {
  const { bridge, db } = setup();
  // cihaz yeniden baglandi; QoS 0 "online" kayboldu, eski baglantinin LWT'si geldi
  await bridge.handleIncomingMessage(`ev/${HOME}/status`, Buffer.from('offline'), { retain: false });
  await send(bridge, firmwareState());
  const order = db.calls.filter((c) => /UPDATE devices/.test(c.text));
  assert.match(order[0].text, /UPDATE devices d/);
  assert.deepEqual(order[0].params, [HOME, false, false], 'LWT: canli offline');
  assert.match(order[1].text, /^UPDATE devices SET/);
  assert.match(order[1].text, /is_online = TRUE/, 'sonraki canli state cevrimici yapar (30 sn kalp atisi telafisi)');
});

test('C11 (1): abonelik aninda teslim edilen RETAINED "offline" status cihazi cevrimdisi yapar; retained "online" last_seen ilerletmez', async () => {
  const { bridge, db } = setup();
  await bridge.handleIncomingMessage(`ev/${HOME}/status`, Buffer.from('offline'), { retain: true });
  await bridge.handleIncomingMessage(`ev/${HOME}/status`, Buffer.from('online'), { retain: true });
  const w = db.calls.filter((c) => /UPDATE devices d/.test(c.text));
  assert.deepEqual(w[0].params, [HOME, false, true]);
  assert.deepEqual(w[1].params, [HOME, true, true], 'retained online: 3. parametre true -> last_seen_at ilerlemez (SQL CASE)');
  assert.match(w[1].text, /CASE WHEN \$2::boolean AND NOT \$3::boolean THEN CURRENT_TIMESTAMP ELSE d\.last_seen_at END/);
});

// ------------------------------------------------------------------------------
// (7) yuk profili: 30 sn kalp atisi + ~0.4 sn degisiklik patlamalari
// ------------------------------------------------------------------------------
function makeFleetDb(homes) {
  return makeFakeDb([
    {
      match: /FROM homes h LEFT JOIN devices d/,
      reply: (_t, params) => {
        const n = homes.get(params[0]);
        return n === undefined
          ? { rows: [], rowCount: 0 }
          : { rows: [{ home_id: `home-${n}`, device_id: `dev-${n}`, device_uuid: `AHBU-S3-${n.toString(16).padStart(6, '0').toUpperCase()}` }], rowCount: 1 };
      },
    },
  ]);
}

test('C11 (7): kalp atisi butcesi - mesaj basina EN FAZLA 1 transaction ve 5 sorgu (cozumle + cihaz + role + panjur + ev esitleme)', async () => {
  const N = 300;
  const homes = new Map();
  for (let i = 1; i <= N; i++) homes.set(`h_${i.toString(16).padStart(16, '0')}`, i);
  const db = makeFleetDb(homes);
  const bridge = new MqttBridge({ db, logger: makeLogger(), env: {}, now: () => 1_700_000_000_000 });

  await Promise.all(
    [...homes].map(([topic, n]) =>
      bridge.handleIncomingMessage(
        `ev/${topic}/state`,
        Buffer.from(JSON.stringify(firmwareState({ uid: `AHBU-S3-${n.toString(16).padStart(6, '0').toUpperCase()}` }))),
        { retain: false }
      )
    )
  );
  const begins = db.txLog.filter((x) => x === 'BEGIN').length;
  assert.equal(begins, N, 'her ev icin tam 1 transaction');
  assert.ok(db.calls.length <= N * 5, `mesaj basina <= 5 sorgu (olculen ${(db.calls.length / N).toFixed(2)})`);
  assert.equal(bridge._queue.stats.dropped, 0);
  assert.equal(bridge._queue.stats.failed, 0);
  assert.equal(bridge.counters.dbErrors, 0);
  assert.equal(bridge.counters.invalid, 0);
});

test('C11 (7): ~0.4 sn degisiklik patlamasi - ayni eve gelen 60 state birlesir (olculen 4-5, en fazla 8 transaction) ve SON durum yazilir', async () => {
  const slowDb = makeFakeDb([
    {
      match: /FROM homes h LEFT JOIN devices d/,
      reply: { rows: [DEV], rowCount: 1 },
    },
  ]);
  const delay = () => new Promise((r) => setTimeout(r, 2));
  const rawQuery = slowDb.query;
  const rawTx = slowDb.withTransaction;
  slowDb.query = async (t, p) => {
    await delay();
    return rawQuery(t, p);
  };
  slowDb.withTransaction = (fn) =>
    rawTx(async (tx) =>
      fn({
        query: async (t, p) => {
          await delay();
          return tx.query(t, p);
        },
      })
    );
  const bridge = new MqttBridge({ db: slowDb, logger: makeLogger(), env: {}, now: () => 1_700_000_000_000 });

  const pending = [];
  for (let i = 0; i < 60; i++) {
    pending.push(
      send(bridge, firmwareState({ seq: i, relays: [{ id: 3, type: 'light', state: i % 2 === 0 }, { id: 4, type: 'light', state: i === 59 }] }))
    );
    if (i % 10 === 0) await flush(); // cihazin 250 ms birlestirmesi: patlama araliklarla gelir
  }
  await Promise.all(pending);
  await bridge._queue.drain(2000);

  const begins = slowDb.txLog.filter((x) => x === 'BEGIN').length;
  assert.ok(begins <= 8, `60 mesaj en fazla 8 transaction'a inmeli (olculen ${begins})`);
  assert.ok(bridge._queue.stats.coalesced >= 45, `bekleyen eski state'ler birlesmeli (birlesen ${bridge._queue.stats.coalesced})`);

  const relayWrites = writes(slowDb).filter((c) => /SET current_state/.test(c.text));
  const last = relayWrites[relayWrites.length - 1];
  assert.deepEqual(last.params, [DEV.device_id, 3, false, 4, true], 'son yazilan durum SON mesajdir (i=59)');
});

test('C11 (7): KeyedWorkQueue - farkli evler sinirli es zamanlilikla, ayni ev sirayla; kuyruk siniri asilinca eski state dusurulur (bellek sinirli)', async () => {
  const q = new KeyedWorkQueue({ concurrency: 4, maxPending: 50 });
  let maxActive = 0;
  let active = 0;
  const done = [];
  const jobs = [];
  for (let home = 0; home < 20; home++) {
    jobs.push(
      q.push(`h${home}`, 'state', async () => {
        active++;
        maxActive = Math.max(maxActive, active);
        await new Promise((r) => setTimeout(r, 1));
        active--;
        done.push(home);
      })
    );
  }
  await Promise.all(jobs);
  assert.ok(maxActive <= 4, `es zamanlilik <= 4 (olculen ${maxActive})`);
  assert.equal(done.length, 20);

  // 60 farkli ev ayni anda: maxPending 50 -> fazlasi dusurulur ama koprude hata/aski olmaz
  const flood = [];
  for (let i = 0; i < 60; i++) flood.push(q.push(`f${i}`, 'state', async () => { await new Promise((r) => setTimeout(r, 1)); }));
  const results = await Promise.all(flood);
  assert.equal(results.filter((r) => r.dropped).length, 10);
  assert.equal(q.pending, 0);
});
