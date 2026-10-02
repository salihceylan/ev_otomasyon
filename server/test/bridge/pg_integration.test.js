'use strict';

// C9 - GERCEK PostgreSQL entegrasyon testleri (kopru, zamanlayici, kural servisi).
//
// Varsayilan olarak ATLANIR (`npm test` PostgreSQL gerektirmez). Etkinlestirmek icin TAMAMEN
// migration'lanmis bir veritabani verin:
//
//   node scripts/migrate.js            (MIGRATE_CONFIRM=<db>, DATABASE_URL=<hedef>)   # once migration'lar
//   EV_PG_TEST_URL=postgresql://kullanici:parola@127.0.0.1:5432/<db> npm test
//   (veya yalnizca: EV_PG_TEST_URL=... node --test test/bridge/pg_integration.test.js)
//
// Her test KENDI satirlarini (rastgele ev/kullanici/cihaz) olusturur ve sonunda siler; baska verilere
// dokunmaz. ISTISNA: cevrimdisi supurucu testi tum cihazlari etkiler -> yalnizca EV_PG_TEST_EXCLUSIVE=1
// (veritabani yalniz testlere ayrilmissa) iken calisir.
//
// Neden: mock'lu testler SQL'in gercekten GECERLI ve DOGRU oldugunu kanitlamaz (ornegin atomik talebin
// es zamanli calisma altinda yalnizca bir kazanan uretmesi). Bu dosya ayni kodu gercek PostgreSQL'de dener.

const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');

const URL_ = process.env.EV_PG_TEST_URL;
const EXCLUSIVE = process.env.EV_PG_TEST_EXCLUSIVE === '1';
const SKIP = URL_ ? false : 'EV_PG_TEST_URL tanimli degil (gercek PostgreSQL gerekir)';

const { MqttBridge } = require('../../src/mqtt_bridge');
const { Scheduler, SQL } = require('../../src/scheduler');
const { createService } = require('../../src/services/scheduled_rules_service');

let pool = null;
function getDb() {
  if (!pool) {
    const { Pool } = require('pg');
    pool = new Pool({ connectionString: URL_, max: 12 });
    pool.on('error', () => {});
  }
  const db = {
    query: (text, params) => pool.query(text, params),
    async withTransaction(fn) {
      const client = await pool.connect();
      try {
        await client.query('BEGIN');
        const result = await fn({ query: (t, p) => client.query(t, p) });
        await client.query('COMMIT');
        return result;
      } catch (err) {
        await client.query('ROLLBACK').catch(() => {});
        throw err;
      } finally {
        client.release();
      }
    },
  };
  return db;
}

const silent = { log() {}, warn() {}, error() {} };
const hex = (n) => crypto.randomBytes(n).toString('hex');

/** Rastgele ev + sahip + cihaz(lar) + 8 kanal (1-2 panjur cifti, 3-8 isik). Temizleyici dondurur. */
async function makeFixture(db, { devices = 1 } = {}) {
  const tag = hex(5);
  const topic = `h_${hex(8)}`;
  const userId = (
    await db.query("INSERT INTO users (email, password_hash, full_name, role, is_active) VALUES ($1, $2, 'Test Kullanici', 'user', TRUE) RETURNING id", [
      `t_${tag}@example.invalid`,
      'x',
    ])
  ).rows[0].id;
  const homeId = (await db.query('INSERT INTO homes (name, mqtt_username) VALUES ($1, $2) RETURNING id', [`T-${tag}`, topic])).rows[0].id;
  await db.query("INSERT INTO home_users (home_id, user_id, role) VALUES ($1, $2, 'owner')", [homeId, userId]);

  const devs = [];
  for (let i = 0; i < devices; i++) {
    const uuid = `AHBU-T${tag}-${i}`.toUpperCase();
    const row = (
      await db.query('INSERT INTO devices (home_id, device_uuid, mac_address, is_claimed) VALUES ($1, $2, $3, TRUE) RETURNING id, device_uuid', [
        homeId,
        uuid,
        `T${tag}${i}`,
      ])
    ).rows[0];
    devs.push(row);
  }
  for (let ch = 1; ch <= 8; ch++) {
    const shutter = ch <= 2;
    await db.query(
      `INSERT INTO endpoints (home_id, device_id, channel_index, name, type, room, shutter_pair_index, shutter_duration_sec)
       VALUES ($1, $2, $3, $4, $5, 'Genel', $6, $7)`,
      [homeId, devs[0].id, ch, `K${ch}`, shutter ? 'shutter' : 'light', shutter ? 1 : null, shutter ? 20 : null]
    );
  }
  return {
    tag,
    topic,
    userId,
    homeId,
    devices: devs,
    async cleanup() {
      await db.query('DELETE FROM homes WHERE id = $1', [homeId]).catch(() => {});
      await db.query('DELETE FROM devices WHERE id = ANY($1::uuid[])', [devs.map((d) => d.id)]).catch(() => {});
      await db.query('DELETE FROM users WHERE id = $1', [userId]).catch(() => {});
    },
  };
}

const one = async (db, sql, params) => (await db.query(sql, params)).rows[0];

async function withFixture(opts, fn) {
  const db = getDb();
  const fx = await makeFixture(db, opts);
  try {
    await fn({ db, fx });
  } finally {
    await fx.cleanup();
  }
}

test.after(async () => {
  if (pool) await pool.end();
});

// ------------------------------------------------------------------------------
// 0) Sema
// ------------------------------------------------------------------------------
test('PG: migration\'lar uygulanmis (schema_migrations) ve sema sozlesmesi CANLI veritabaninda TEMIZ', { skip: SKIP }, async () => {
  const db = getDb();
  const names = (await db.query('SELECT name FROM schema_migrations')).rows.map((r) => r.name);
  for (const required of ['022_scheduled_rules_fix.sql', '023_bridge_device_telemetry.sql', '025_child_lock_and_peace_constraints.sql', '026_devices_heartbeat_hot_updates.sql']) {
    assert.ok(names.includes(required), `${required} uygulanmamis: once scripts/migrate.js calistirin`);
  }
  const { check } = require('../../scripts/check_schema_contract');
  const contract = require('../../scripts/lib/sql_contract');
  const result = await check();
  const problems = await contract.verifyLiveSchema(db, result.refs);
  assert.deepEqual(problems, [], 'kodun kullandigi tablo/sutunlar canli veritabaninda eksik');
});

// ------------------------------------------------------------------------------
// 1) Kopru
// ------------------------------------------------------------------------------
test('PG kopru: CANLI state -> endpoint, cihaz telemetrisi, ack ve cocuk kilidi (devices + homes AYNI transaction)', { skip: SKIP }, async () => {
  await withFixture({}, async ({ db, fx }) => {
    const bridge = new MqttBridge({ db, logger: silent, env: {} });
    const dev = fx.devices[0];
    const state = {
      v: 2,
      uid: dev.device_uuid,
      fw: '1.2.3',
      ip: '10.9.8.7',
      child_lock: true,
      last_id: 'cmd-1',
      relays: [{ id: 3, state: true }, { id: 4, state: false }, { id: 1, state: true }],
      shutters: [{ pair: 1, pos: 40 }],
    };
    await bridge.handleIncomingMessage(`ev/${fx.topic}/state`, JSON.stringify(state), { retain: false });

    const d = await one(db, 'SELECT ip_address, firmware_version, is_online, last_seen_at, child_lock_enabled, last_ack_id, last_ack_at FROM devices WHERE id = $1', [dev.id]);
    assert.equal(d.ip_address, '10.9.8.7');
    assert.equal(d.firmware_version, '1.2.3');
    assert.equal(d.is_online, true);
    assert.ok(d.last_seen_at);
    assert.equal(d.child_lock_enabled, true);
    assert.equal(d.last_ack_id, 'cmd-1');
    assert.ok(d.last_ack_at);

    const eps = (await db.query('SELECT channel_index, current_state, current_position, type FROM endpoints WHERE device_id = $1 ORDER BY channel_index', [dev.id])).rows;
    assert.equal(eps.find((e) => e.channel_index === 3).current_state, true);
    assert.equal(eps.find((e) => e.channel_index === 4).current_state, false);
    // panjur cifti 1 (kanal 1 ve 2) konumu: shutter_pair_index = 1
    assert.equal(eps.find((e) => e.channel_index === 1).current_position, 40);
    assert.equal(eps.find((e) => e.channel_index === 2).current_position, 40);
    assert.equal(eps.find((e) => e.channel_index === 3).current_position, 0, 'isik kanalina konum yazilmamali');

    // C9: ev cocuk kilidi cihaz bildiriminden esitlenir
    assert.equal((await one(db, 'SELECT child_lock_enabled FROM homes WHERE id = $1', [fx.homeId])).child_lock_enabled, true);

    // kalp atisi: ayni last_id -> ack ZAMANI ilerlemez
    const ack1 = d.last_ack_at;
    await new Promise((r) => setTimeout(r, 30));
    await bridge.handleIncomingMessage(`ev/${fx.topic}/state`, JSON.stringify({ ...state, child_lock: false }), { retain: false });
    const d2 = await one(db, 'SELECT last_ack_at, child_lock_enabled FROM devices WHERE id = $1', [dev.id]);
    assert.equal(new Date(d2.last_ack_at).getTime(), new Date(ack1).getTime(), 'ayni last_id ack zamanini ilerletmemeli');
    assert.equal(d2.child_lock_enabled, false);
    assert.equal((await one(db, 'SELECT child_lock_enabled FROM homes WHERE id = $1', [fx.homeId])).child_lock_enabled, false);

    // yeni last_id -> ack zamani ilerler; bos last_id ack'i bozmaz
    await new Promise((r) => setTimeout(r, 30));
    await bridge.handleIncomingMessage(`ev/${fx.topic}/state`, JSON.stringify({ ...state, last_id: 'cmd-2' }), { retain: false });
    const d3 = await one(db, 'SELECT last_ack_id, last_ack_at FROM devices WHERE id = $1', [dev.id]);
    assert.equal(d3.last_ack_id, 'cmd-2');
    assert.ok(new Date(d3.last_ack_at).getTime() > new Date(ack1).getTime());
    await bridge.handleIncomingMessage(`ev/${fx.topic}/state`, JSON.stringify({ ...state, last_id: '' }), { retain: false });
    assert.equal((await one(db, 'SELECT last_ack_id FROM devices WHERE id = $1', [dev.id])).last_ack_id, 'cmd-2');
  });
});

test('PG kopru: RETAINED state is_online/last_seen/ack degistirmez; cocuk kilidini yalniz CEVRIMDISI panoda uzlastirir', { skip: SKIP }, async () => {
  await withFixture({}, async ({ db, fx }) => {
    const bridge = new MqttBridge({ db, logger: silent, env: {} });
    const dev = fx.devices[0];
    const retained = { uid: dev.device_uuid, ip: '10.1.1.1', child_lock: true, last_id: 'old', relays: [{ id: 3, state: true }] };

    // pano cevrimici (bilinen) ve kilit false: bayat retained kilidi EZEMEZ
    await db.query('UPDATE devices SET is_online = TRUE, child_lock_enabled = FALSE, last_seen_at = NULL WHERE id = $1', [dev.id]);
    await bridge.handleIncomingMessage(`ev/${fx.topic}/state`, JSON.stringify(retained), { retain: true });
    let d = await one(db, 'SELECT is_online, last_seen_at, child_lock_enabled, last_ack_id, ip_address FROM devices WHERE id = $1', [dev.id]);
    assert.equal(d.child_lock_enabled, false, 'cevrimici panoda retained kilidi yazmamali');
    assert.equal(d.last_seen_at, null, 'retained last_seen ilerletmemeli');
    assert.equal(d.last_ack_id, null, 'retained ack yazmamali');
    assert.equal(d.ip_address, '10.1.1.1', 'ip bilgisi retained\'dan alinabilir');
    assert.equal((await one(db, 'SELECT current_state FROM endpoints WHERE device_id = $1 AND channel_index = 3', [dev.id])).current_state, true, 'endpoint retained\'dan guncellenir');

    // pano cevrimdisi: retained kilit uzlastirilir ve ev esitlenir
    await db.query('UPDATE devices SET is_online = FALSE WHERE id = $1', [dev.id]);
    await bridge.handleIncomingMessage(`ev/${fx.topic}/state`, JSON.stringify(retained), { retain: true });
    d = await one(db, 'SELECT is_online, child_lock_enabled FROM devices WHERE id = $1', [dev.id]);
    assert.equal(d.child_lock_enabled, true, 'cevrimdisi panoda retained kilit uzlastirilmali');
    assert.equal(d.is_online, false, 'retained pano cevrimici YAPMAZ');
    assert.equal((await one(db, 'SELECT child_lock_enabled FROM homes WHERE id = $1', [fx.homeId])).child_lock_enabled, true);
  });
});

test('PG kopru: status - canli online/offline, retained last_seen ilerletmez', { skip: SKIP }, async () => {
  await withFixture({}, async ({ db, fx }) => {
    const bridge = new MqttBridge({ db, logger: silent, env: {} });
    const id = fx.devices[0].id;

    await bridge.handleIncomingMessage(`ev/${fx.topic}/status`, 'online', { retain: false });
    let d = await one(db, 'SELECT is_online, last_seen_at FROM devices WHERE id = $1', [id]);
    assert.equal(d.is_online, true);
    assert.ok(d.last_seen_at);
    const seen = new Date(d.last_seen_at).getTime();

    await new Promise((r) => setTimeout(r, 30));
    await bridge.handleIncomingMessage(`ev/${fx.topic}/status`, 'online', { retain: true });
    d = await one(db, 'SELECT is_online, last_seen_at FROM devices WHERE id = $1', [id]);
    assert.equal(new Date(d.last_seen_at).getTime(), seen, 'retained status last_seen ilerletmemeli');

    await bridge.handleIncomingMessage(`ev/${fx.topic}/status`, 'offline', { retain: false });
    d = await one(db, 'SELECT is_online FROM devices WHERE id = $1', [id]);
    assert.equal(d.is_online, false);
  });
});

test('PG kopru: iki cihazli evde uid ile esleme; ev kilidi = bool_and(cihazlar)', { skip: SKIP }, async () => {
  await withFixture({ devices: 2 }, async ({ db, fx }) => {
    const bridge = new MqttBridge({ db, logger: silent, env: {} });
    const [a, b] = fx.devices;
    await bridge.handleIncomingMessage(`ev/${fx.topic}/state`, JSON.stringify({ uid: a.device_uuid, child_lock: true }), { retain: false });
    // b henuz bildirmedi (varsayilan false) -> ev kilidi false (bool_and)
    assert.equal((await one(db, 'SELECT child_lock_enabled FROM homes WHERE id = $1', [fx.homeId])).child_lock_enabled, false);
    await bridge.handleIncomingMessage(`ev/${fx.topic}/state`, JSON.stringify({ uid: b.device_uuid, child_lock: true }), { retain: false });
    assert.equal((await one(db, 'SELECT child_lock_enabled FROM homes WHERE id = $1', [fx.homeId])).child_lock_enabled, true);

    // uid olmadan belirsiz -> atilir (hicbir cihaz degismez)
    await db.query('UPDATE devices SET ip_address = NULL WHERE home_id = $1', [fx.homeId]);
    await bridge.handleIncomingMessage(`ev/${fx.topic}/state`, JSON.stringify({ ip: '10.0.0.9' }), { retain: false });
    assert.equal((await db.query('SELECT 1 FROM devices WHERE home_id = $1 AND ip_address IS NOT NULL', [fx.homeId])).rows.length, 0);
    // baska evin uid'si -> atilir
    await bridge.handleIncomingMessage(`ev/${fx.topic}/state`, JSON.stringify({ uid: 'AHBU-BASKA-EV', ip: '10.0.0.9' }), { retain: false });
    assert.equal((await db.query('SELECT 1 FROM devices WHERE home_id = $1 AND ip_address IS NOT NULL', [fx.homeId])).rows.length, 0);
  });
});

test('PG kopru: CHECK/NOT NULL ihlali sessiz degil - bozuk panjur konumu veritabanina GIRMEZ (dogrulama + CHECK)', { skip: SKIP }, async () => {
  await withFixture({}, async ({ db, fx }) => {
    const bridge = new MqttBridge({ db, logger: silent, env: {} });
    await bridge.handleIncomingMessage(
      `ev/${fx.topic}/state`,
      JSON.stringify({ uid: fx.devices[0].device_uuid, shutters: [{ pair: 1, pos: 300 }, { pair: 1, pos: -5 }] }),
      { retain: false }
    );
    assert.equal((await one(db, 'SELECT current_position FROM endpoints WHERE device_id = $1 AND channel_index = 1', [fx.devices[0].id])).current_position, 0);
    // veritabani CHECK'i de ayni sinirda (savunma derinligi)
    await assert.rejects(() => db.query('UPDATE endpoints SET current_position = 300 WHERE device_id = $1 AND channel_index = 1', [fx.devices[0].id]), (e) => e.code === '23514');
  });
});

test('PG kopru: cevrimdisi supurucu 120 sn sessiz cihazi cevrimdisi yapar (YALNIZ EV_PG_TEST_EXCLUSIVE=1: tum cihazlari etkiler)', { skip: SKIP || (EXCLUSIVE ? false : 'EV_PG_TEST_EXCLUSIVE=1 degil (supurucu tum cihazlari etkiler)') }, async () => {
  await withFixture({ devices: 2 }, async ({ db, fx }) => {
    const [stale, fresh] = fx.devices;
    await db.query("UPDATE devices SET is_online = TRUE, last_seen_at = NOW() - INTERVAL '10 minutes' WHERE id = $1", [stale.id]);
    await db.query("UPDATE devices SET is_online = TRUE, last_seen_at = NOW() - INTERVAL '10 seconds' WHERE id = $1", [fresh.id]);
    const bridge = new MqttBridge({ db, logger: silent, env: {} });
    bridge.connected = true;
    bridge.client = { connected: true };
    bridge.connectedSince = 0;
    const n = await bridge.sweepOffline();
    assert.ok(n >= 1);
    assert.equal((await one(db, 'SELECT is_online FROM devices WHERE id = $1', [stale.id])).is_online, false);
    assert.equal((await one(db, 'SELECT is_online FROM devices WHERE id = $1', [fresh.id])).is_online, true);
  });
});

// ------------------------------------------------------------------------------
// 1b) Kopru <-> firmware sozlesmesi (C11, CONTRACTS §3b) - gercek PostgreSQL
// ------------------------------------------------------------------------------
/** Sorgu/transaction sayan sarmalayici (kalp atisi butcesi olcumu). */
function countingDb(db) {
  const c = { q: 0, tx: 0 };
  return {
    c,
    query: (t, p) => {
      c.q++;
      return db.query(t, p);
    },
    withTransaction: (fn) => {
      c.tx++;
      return db.withTransaction((tx) =>
        fn({
          query: (t, p) => {
            c.q++;
            return tx.query(t, p);
          },
        })
      );
    },
  };
}

const firmwareState = (uid, over = {}) => ({
  v: 2,
  uid,
  fw: '1.1.0',
  seq: 1,
  uptime: 3600,
  ip: '192.168.1.30',
  child_lock: false,
  relays: Array.from({ length: 8 }, (_, i) => ({ id: i + 1, name: `K${i + 1}`, type: i < 2 ? 'shutter' : 'light', state: false })),
  shutters: [{ pair: 1, pos: 100, moving: false, dir: 0, target: 255 }],
  dis: [{ id: 1, state: false }],
  ...over,
});

test('PG kopru C11: last_id alani HIC yok, kismi panjur cifti (yalniz cift 2), kucuk harfli uid - eksik cift korunur', { skip: SKIP }, async () => {
  await withFixture({}, async ({ db, fx }) => {
    const bridge = new MqttBridge({ db, logger: silent, env: {} });
    const dev = fx.devices[0];
    // iki panjur cifti: kanal 1-2 (cift 1, konum 77) ve kanal 3-4 (cift 2)
    await db.query("UPDATE endpoints SET type = 'shutter', shutter_pair_index = 2, shutter_duration_sec = 20 WHERE device_id = $1 AND channel_index IN (3, 4)", [dev.id]);
    await db.query('UPDATE endpoints SET current_position = 77 WHERE device_id = $1 AND channel_index IN (1, 2)', [dev.id]);
    const pos = async () =>
      Object.fromEntries((await db.query('SELECT channel_index, current_position FROM endpoints WHERE device_id = $1 ORDER BY 1', [dev.id])).rows.map((r) => [r.channel_index, r.current_position]));

    // yalniz cift 2 raporlanir (cift 1 yapilandirilmamis/raporlanmiyor); uid kucuk harfli; last_id ALANI YOK
    const msg = firmwareState(dev.device_uuid.toLowerCase(), { shutters: [{ pair: 2, pos: 40, moving: true, dir: 2, target: 10 }] });
    assert.equal(Object.prototype.hasOwnProperty.call(msg, 'last_id'), false);
    await bridge.handleIncomingMessage(`ev/${fx.topic}/state`, JSON.stringify(msg), { retain: false });
    let p = await pos();
    assert.equal(p[3], 40);
    assert.equal(p[4], 40);
    assert.equal(p[1], 77, 'raporlanmayan cift 1 SIFIRLANMAZ/silinmez');
    assert.equal(p[2], 77);
    const d = await one(db, 'SELECT is_online, last_ack_id, last_ack_at FROM devices WHERE id = $1', [dev.id]);
    assert.equal(d.is_online, true, 'kucuk harfli uid ile cihaz eslesti');
    assert.equal(d.last_ack_id, null, 'last_id yok -> ack yazilmaz');
    assert.equal(bridge.counters.invalid, 0);

    // bos dizi ve alansiz mesaj konumlara dokunmaz
    await bridge.handleIncomingMessage(`ev/${fx.topic}/state`, JSON.stringify(firmwareState(dev.device_uuid, { shutters: [] })), { retain: false });
    const { shutters, ...noShutters } = firmwareState(dev.device_uuid);
    await bridge.handleIncomingMessage(`ev/${fx.topic}/state`, JSON.stringify(noShutters), { retain: false });
    p = await pos();
    assert.deepEqual([p[1], p[2], p[3], p[4]], [77, 77, 40, 40]);

    // ack sonrasi last_id'siz kalp atislari onceki ack'i silmez
    await bridge.handleIncomingMessage(`ev/${fx.topic}/state`, JSON.stringify(firmwareState(dev.device_uuid, { last_id: 'cmd-9' })), { retain: false });
    await bridge.handleIncomingMessage(`ev/${fx.topic}/state`, JSON.stringify(firmwareState(dev.device_uuid, { seq: 3 })), { retain: false });
    assert.equal((await one(db, 'SELECT last_ack_id FROM devices WHERE id = $1', [dev.id])).last_ack_id, 'cmd-9');
  });
});

test('PG kopru C11: kalp atisi butcesi (mesaj basina <= 1 tx / 5 sorgu), DEGISMEYEN state endpoint satirini YENIDEN YAZMAZ (xmin sabit), ~0.4 sn patlama birlesir', { skip: SKIP }, async () => {
  const db = getDb();
  const N = 24;
  const fixtures = [];
  try {
    for (let i = 0; i < N; i++) fixtures.push(await makeFixture(db));
    const counting = countingDb(db);
    const bridge = new MqttBridge({ db: counting, logger: silent, env: {} });
    const heartbeat = (fx, over = {}) => bridge.handleIncomingMessage(`ev/${fx.topic}/state`, JSON.stringify(firmwareState(fx.devices[0].device_uuid, over)), { retain: false });
    const xminOf = async () => (await db.query('SELECT id, xmin::text AS x FROM endpoints WHERE home_id = ANY($1::uuid[]) ORDER BY id', [fixtures.map((f) => f.homeId)])).rows;

    // dalga 1: ilk bildirim (bazi satirlar degisir)
    await Promise.all(fixtures.map((fx) => heartbeat(fx, { relays: firmwareState('x').relays.map((r) => ({ ...r, state: r.id === 3 })) })));
    const afterFirst = await xminOf();

    // dalga 2-3: AYNI durum (30 sn'lik kalp atisi): hicbir endpoint satiri yeniden yazilmamali
    counting.c.q = 0;
    counting.c.tx = 0;
    for (let w = 0; w < 2; w++) {
      await Promise.all(fixtures.map((fx) => heartbeat(fx, { seq: 10 + w, relays: firmwareState('x').relays.map((r) => ({ ...r, state: r.id === 3 })) })));
    }
    assert.equal(counting.c.tx, N * 2, 'mesaj basina tam 1 transaction');
    assert.ok(counting.c.q <= N * 2 * 5, `mesaj basina <= 5 sorgu (olculen ${(counting.c.q / (N * 2)).toFixed(2)})`);
    assert.deepEqual(await xminOf(), afterFirst, 'IS DISTINCT FROM: degismeyen endpoint satirlari yazilmadi (xmin ayni)');
    assert.equal(bridge.counters.dbErrors, 0);

    // ~0.4 sn degisiklik patlamasi: ayni eve 100 state; en fazla birkac transaction, SON durum yazilir
    counting.c.tx = 0;
    const fx = fixtures[0];
    const burst = [];
    for (let i = 0; i < 100; i++) burst.push(heartbeat(fx, { seq: 100 + i, relays: firmwareState('x').relays.map((r) => ({ ...r, state: ((i * 37) >> (r.id - 1)) % 2 === 1 })) }));
    await Promise.all(burst);
    assert.ok(counting.c.tx <= 10, `100 state en fazla 10 transaction'a inmeli (olculen ${counting.c.tx})`);
    const last = 99;
    const eps = (await db.query('SELECT channel_index, current_state FROM endpoints WHERE device_id = $1 ORDER BY channel_index', [fx.devices[0].id])).rows;
    for (const e of eps) assert.equal(e.current_state, ((last * 37) >> (e.channel_index - 1)) % 2 === 1, `kanal ${e.channel_index} son duruma esit olmali`);
  } finally {
    for (const fx of fixtures) await fx.cleanup();
  }
});

test('PG sema: devices uzerinde kalp atisiyla degisen sutunlari (last_seen_at / is_online) kapsayan indeks YOK (HOT guncelleme; 026)', { skip: SKIP }, async () => {
  const db = getDb();
  const idx = (await db.query("SELECT indexname, indexdef FROM pg_indexes WHERE schemaname = 'public' AND tablename = 'devices'")).rows;
  assert.ok(idx.length > 0);
  assert.deepEqual(
    idx.filter((i) => /last_seen_at|is_online/.test(i.indexdef)).map((i) => i.indexname),
    [],
    'last_seen_at/is_online indekslenirse her kalp atisi HOT disi guncelleme olur (tum indekslere yazim + sisme)'
  );
});

// ------------------------------------------------------------------------------
// 2) Zamanlayici (gercek talep/gunluk SQL'i, es zamanlilik)
// ------------------------------------------------------------------------------
const SLOT = Date.parse('2031-03-04T05:30:20Z'); // Istanbul 08:30, gelecek: schedule_changed_at (simdi) yuvadan once

async function insertRule(db, fx, over = {}) {
  const r = {
    channel: 3,
    channel_type: 'relay',
    action: 'on',
    hour: 8,
    minute: 30,
    device_id: null,
    ...over,
  };
  return (
    await db.query(
      `INSERT INTO scheduled_rules (home_id, device_id, channel, channel_type, action, hour, minute, created_by)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8) RETURNING id`,
      [fx.homeId, r.device_id, r.channel, r.channel_type, r.action, r.hour, r.minute, fx.userId]
    )
  ).rows[0].id;
}

/**
 * Zamanlayiciyi YALNIZCA bu testin evine kapsamlar: aday sorgusunun sonucu fixture evine suzulur ve gunluk
 * temizligi atlanir. Boylece paylasilan bir veritabaninda (QA) BASKA evlerin kurallari talep edilip
 * last_run_at'i gelecege tasinmaz (bu, gercek calismalari yillarca engellerdi) ve eski gunlukler silinmez.
 */
function scopedScheduler(db, fx, bridge, nowMs) {
  const scoped = {
    query: (text, params) =>
      text === SQL.candidates
        ? db.query(text, params).then((r) => ({ ...r, rows: r.rows.filter((x) => x.home_id === fx.homeId) }))
        : db.query(text, params),
  };
  const s = new Scheduler({ logger: silent, now: () => nowMs });
  s.db = scoped;
  s.mqttBridge = bridge;
  s._lastHousekeeping = nowMs; // gunluk temizligi (genel DELETE) calismasin
  return s;
}

function fakeBridge() {
  const published = [];
  return {
    published,
    isConnected: () => true,
    async publishCommand(topic, cmd) {
      published.push({ topic, cmd });
      return {};
    },
  };
}

test('PG zamanlayici: vadesi gelen kural yayinlanir, last_run_at = yuva, calisma gunlugu "sent"; tekrar turda calismaz', { skip: SKIP }, async () => {
  await withFixture({}, async ({ db, fx }) => {
    await db.query('UPDATE devices SET is_online = TRUE WHERE id = $1', [fx.devices[0].id]);
    const ruleId = await insertRule(db, fx);
    const bridge = fakeBridge();
    const s = scopedScheduler(db, fx, bridge, SLOT);

    const r1 = await s.runTick(SLOT);
    assert.equal(r1.sent, 1, JSON.stringify(r1));
    assert.equal(bridge.published.length, 1);
    assert.equal(bridge.published[0].topic, fx.topic);
    assert.deepEqual({ relay: bridge.published[0].cmd.relay, state: bridge.published[0].cmd.state }, { relay: 3, state: true });

    const rule = await one(db, 'SELECT last_run_at FROM scheduled_rules WHERE id = $1', [ruleId]);
    assert.equal(new Date(rule.last_run_at).toISOString(), '2031-03-04T05:30:00.000Z');
    const run = await one(db, 'SELECT status, command_id, attempts, device_id FROM scheduled_rule_runs WHERE rule_id = $1', [ruleId]);
    assert.equal(run.status, 'sent');
    assert.equal(run.command_id, bridge.published[0].cmd.id);
    assert.equal(run.attempts, 1);
    assert.equal(run.device_id, null, 'kural device_id belirtmemisti (evin tek cihazi kullanildi)');

    // ayni dakika + telafi penceresi icindeki sonraki turlar tekrar calistirmaz
    const r2 = await s.runTick(SLOT + 5000);
    const r3 = await s.runTick(SLOT + 60000);
    assert.equal(r2.due + r3.due, 0);
    assert.equal(bridge.published.length, 1);
  });
});

test('PG zamanlayici: ES ZAMANLI iki instance ayni kurali yalnizca BIR KEZ yayinlar (atomik UPDATE ... RETURNING)', { skip: SKIP }, async () => {
  await withFixture({}, async ({ db, fx }) => {
    await db.query('UPDATE devices SET is_online = TRUE WHERE id = $1', [fx.devices[0].id]);
    const ids = [];
    for (let i = 0; i < 6; i++) ids.push(await insertRule(db, fx, { channel: 3 + (i % 5) }));
    const bridge = fakeBridge();
    const mk = () => scopedScheduler(db, fx, bridge, SLOT);
    const results = await Promise.all([mk().runTick(SLOT), mk().runTick(SLOT), mk().runTick(SLOT), mk().runTick(SLOT)]);
    assert.equal(bridge.published.length, 6, `her kural TAM BIR kez: ${bridge.published.length} yayin`);
    assert.equal(results.reduce((a, r) => a + r.sent, 0), 6);
    // Kaybedenlerin bir kismi talep asamasinda kaybeder (lost_claim); gec kalan instance'lar kurali adaylar arasinda
    // zaten "calismis" gorur. Kesin sayi zamanlamaya baglidir: yalnizca ust sinir ve tutarlilik denetlenir.
    const lost = results.reduce((a, r) => a + r.lost, 0);
    assert.ok(lost >= 0 && lost <= 18, `kaybeden sayisi mantikli aralikta olmali: ${lost}`);
    const runs = (await db.query('SELECT rule_id, status FROM scheduled_rule_runs WHERE rule_id = ANY($1::int[])', [ids])).rows;
    assert.equal(runs.length, 6, 'her kural icin tek gunluk satiri');
    assert.ok(runs.every((r) => r.status === 'sent'));
  });
});

test('PG zamanlayici: cevrimdisi cihaz atlanir ve talep GERI BIRAKILIR; sonraki turda (pencere icinde) calisir', { skip: SKIP }, async () => {
  await withFixture({}, async ({ db, fx }) => {
    await db.query('UPDATE devices SET is_online = FALSE WHERE id = $1', [fx.devices[0].id]);
    const ruleId = await insertRule(db, fx);
    const bridge = fakeBridge();
    const s = scopedScheduler(db, fx, bridge, SLOT);

    const r1 = await s.runTick(SLOT);
    assert.equal(r1.skipped, 1);
    assert.equal(bridge.published.length, 0);
    assert.equal((await one(db, 'SELECT last_run_at FROM scheduled_rules WHERE id = $1', [ruleId])).last_run_at, null, 'talep geri birakilmali');
    assert.equal((await one(db, 'SELECT status FROM scheduled_rule_runs WHERE rule_id = $1', [ruleId])).status, 'skipped_offline');

    await db.query('UPDATE devices SET is_online = TRUE WHERE id = $1', [fx.devices[0].id]);
    const r2 = await s.runTick(SLOT + 60000);
    assert.equal(r2.sent, 1);
    const run = await one(db, 'SELECT status, attempts FROM scheduled_rule_runs WHERE rule_id = $1', [ruleId]);
    assert.deepEqual([run.status, run.attempts], ['sent', 2], 'ayni yuva tek satir (ON CONFLICT), deneme sayisi artar');
  });
});

test('PG zamanlayici: kural sahibi evden cikarilirsa kural CALISMAZ (yetki calistirma aninda denetlenir)', { skip: SKIP }, async () => {
  await withFixture({}, async ({ db, fx }) => {
    await db.query('UPDATE devices SET is_online = TRUE WHERE id = $1', [fx.devices[0].id]);
    const ruleId = await insertRule(db, fx);
    await db.query('DELETE FROM home_users WHERE home_id = $1 AND user_id = $2', [fx.homeId, fx.userId]);
    const bridge = fakeBridge();
    const s = scopedScheduler(db, fx, bridge, SLOT);
    const r = await s.runTick(SLOT);
    assert.equal(r.skipped, 1);
    assert.equal(bridge.published.length, 0);
    assert.equal((await one(db, 'SELECT status FROM scheduled_rule_runs WHERE rule_id = $1', [ruleId])).status, 'skipped_creator');
  });
});

test('PG zamanlayici: hesap dondurulursa (account_status=suspended) kural CALISMAZ', { skip: SKIP }, async () => {
  await withFixture({}, async ({ db, fx }) => {
    await db.query('UPDATE devices SET is_online = TRUE WHERE id = $1', [fx.devices[0].id]);
    const ruleId = await insertRule(db, fx);
    await db.query("UPDATE users SET account_status = 'suspended' WHERE id = $1", [fx.userId]);
    const bridge = fakeBridge();
    const s = scopedScheduler(db, fx, bridge, SLOT);
    await s.runTick(SLOT);
    assert.equal(bridge.published.length, 0);
    assert.equal((await one(db, 'SELECT status FROM scheduled_rule_runs WHERE rule_id = $1', [ruleId])).status, 'skipped_creator');
  });
});

test('PG zamanlayici: olusturulmadan ONCE baslayan yuva telafi edilmez (schedule_changed_at)', { skip: SKIP }, async () => {
  await withFixture({}, async ({ db, fx }) => {
    await db.query('UPDATE devices SET is_online = TRUE WHERE id = $1', [fx.devices[0].id]);
    await insertRule(db, fx);
    const bridge = fakeBridge();
    const past = Date.parse('2020-01-01T05:30:20Z'); // yuva, kural olusturma zamanindan (simdi) ONCE
    const s = scopedScheduler(db, fx, bridge, past);
    const r = await s.runTick(past);
    assert.equal(r.due, 0);
    assert.equal(bridge.published.length, 0);
  });
});

// ------------------------------------------------------------------------------
// 3) Kural servisi (gercek SQL, kisitlar, es zamanlilik)
// ------------------------------------------------------------------------------
test('PG servis: CRUD, uc nokta dogrulamasi, kanal 1 tabanli, gunluk/cascade davranisi', { skip: SKIP }, async () => {
  await withFixture({}, async ({ db, fx }) => {
    const svc = createService({ db });
    const rule = await svc.createRule(fx.homeId, fx.userId, { channel: 3, channel_type: 'relay', action: 'on', hour: 8, minute: 30, days_of_week: [1, 3, 5], label: 'Sabah' });
    assert.equal(rule.channel, 3);
    assert.deepEqual(rule.days_of_week, [1, 3, 5]);
    assert.equal(rule.enabled, true);
    assert.ok(rule.created_by_name);

    // panjur cifti 1 (kanal 1-2) panjur kurali kabul; role kurali reddedilir
    await svc.createRule(fx.homeId, fx.userId, { channel: 1, channel_type: 'shutter', action: 'open', hour: 7, minute: 0 });
    await assert.rejects(() => svc.createRule(fx.homeId, fx.userId, { channel: 1, channel_type: 'relay', action: 'on', hour: 7, minute: 0 }), (e) => e.status === 400 && e.code === 'VALIDATION');
    await assert.rejects(() => svc.createRule(fx.homeId, fx.userId, { channel: 9, channel_type: 'relay', action: 'on', hour: 7, minute: 0 }), (e) => e.status === 400);
    await assert.rejects(() => svc.createRule(fx.homeId, fx.userId, { channel: 2, channel_type: 'shutter', action: 'open', hour: 7, minute: 0 }), (e) => e.status === 400, 'panjur 2 (kanal 3/4) isik');

    const list = await svc.listRules(fx.homeId);
    assert.deepEqual(list.map((r) => [r.hour, r.minute]), [[7, 0], [8, 30]], 'saate gore sirali');

    // guncelleme: zamanlama degisikligi last_run_at'i sifirlar
    await db.query("UPDATE scheduled_rules SET last_run_at = NOW() WHERE id = $1", [rule.id]);
    const sameLabel = await svc.updateRule(fx.homeId, rule.id, { label: 'Yeni etiket' });
    assert.ok(sameLabel.last_run_at, 'etiket degisimi son calismayi sifirlamaz');
    const moved = await svc.updateRule(fx.homeId, rule.id, { hour: 9 });
    assert.equal(moved.last_run_at, null, 'saat degisimi son calismayi sifirlar');
    assert.equal(moved.hour, 9);

    // baska evin kurali guncellenemez / silinemez
    const other = await makeFixture(db);
    try {
      await assert.rejects(() => createService({ db }).updateRule(other.homeId, rule.id, { label: 'x' }), (e) => e.status === 404);
      await assert.rejects(() => createService({ db }).deleteRule(other.homeId, rule.id), (e) => e.status === 404);
    } finally {
      await other.cleanup();
    }

    // gunluk + silme: kural silinince gunluk satiri KALIR (rule_id NULL), home_id ile
    await db.query("INSERT INTO scheduled_rule_runs (rule_id, home_id, slot_at, status) VALUES ($1, $2, NOW(), 'sent')", [rule.id, fx.homeId]);
    await svc.deleteRule(fx.homeId, rule.id);
    const orphanRun = await one(db, 'SELECT rule_id FROM scheduled_rule_runs WHERE home_id = $1', [fx.homeId]);
    assert.equal(orphanRun.rule_id, null, 'ON DELETE SET NULL');
    await assert.rejects(() => svc.deleteRule(fx.homeId, rule.id), (e) => e.status === 404);

    // temizlik kancasi: ev kurallari + gunlugu tek transaction'da siler
    const cleaned = await db.withTransaction((tx) => svc.homeCleanupHook(tx, fx.homeId));
    assert.ok(cleaned.rules >= 1);
    assert.equal((await db.query('SELECT 1 FROM scheduled_rules WHERE home_id = $1', [fx.homeId])).rows.length, 0);
    assert.equal((await db.query('SELECT 1 FROM scheduled_rule_runs WHERE home_id = $1', [fx.homeId])).rows.length, 0);
  });
});

test('PG servis: ev basina EN FAZLA 50 kural - 60 ES ZAMANLI olusturmadan tam 50 basarili, 10 CONFLICT (advisory kilit)', { skip: SKIP }, async () => {
  await withFixture({}, async ({ db, fx }) => {
    const svc = createService({ db });
    const attempts = Array.from({ length: 60 }, (_, i) =>
      svc.createRule(fx.homeId, fx.userId, { channel: 3 + (i % 6), channel_type: 'relay', action: i % 2 ? 'on' : 'off', hour: i % 24, minute: i % 60 }).then(
        () => 'ok',
        (e) => e.code || e.message
      )
    );
    const out = await Promise.all(attempts);
    assert.equal(out.filter((x) => x === 'ok').length, 50, JSON.stringify(out));
    assert.equal(out.filter((x) => x === 'CONFLICT').length, 10);
    assert.equal((await one(db, 'SELECT COUNT(*)::int AS n FROM scheduled_rules WHERE home_id = $1', [fx.homeId])).n, 50);
  });
});

test('PG sema: tablo kisitlari (tip/eylem CHECK, kanal araligi, FK) gercekten islenir; ev silinince kurallar CASCADE', { skip: SKIP }, async () => {
  await withFixture({}, async ({ db, fx }) => {
    const bad = (extra) =>
      db.query(
        `INSERT INTO scheduled_rules (home_id, channel, channel_type, action, hour, minute, created_by) VALUES ($1, $2, $3, $4, 8, 0, $5)`,
        [fx.homeId, extra.channel, extra.type, extra.action, fx.userId]
      );
    await assert.rejects(() => bad({ channel: 1, type: 'shutter', action: 'on' }), (e) => e.code === '23514', 'panjura "on"');
    await assert.rejects(() => bad({ channel: 1, type: 'relay', action: 'open' }), (e) => e.code === '23514', 'role "open"');
    await assert.rejects(() => bad({ channel: 0, type: 'relay', action: 'on' }), (e) => e.code === '23514', '0 tabanli kanal');
    await assert.rejects(() => bad({ channel: 65, type: 'relay', action: 'on' }), (e) => e.code === '23514');
    await assert.rejects(
      () => db.query("INSERT INTO scheduled_rules (home_id, channel, action, hour, minute, created_by) VALUES ($1, 1, 'on', 8, 0, $2)", ['00000000-0000-4000-8000-000000000000', fx.userId]),
      (e) => e.code === '23503',
      'olmayan ev FK'
    );
    const id = (await bad({ channel: 3, type: 'relay', action: 'on' }).then(() => one(db, 'SELECT id FROM scheduled_rules WHERE home_id = $1', [fx.homeId]))).id;
    assert.ok(id);
    await db.query('DELETE FROM homes WHERE id = $1', [fx.homeId]);
    assert.equal((await db.query('SELECT 1 FROM scheduled_rules WHERE id = $1', [id])).rows.length, 0, 'ev silinince kural CASCADE');
  });
});

test('PG sema: cocuk kilidi NOT NULL (025) ve gece huzur saati HH:MM CHECK', { skip: SKIP }, async () => {
  await withFixture({}, async ({ db, fx }) => {
    await assert.rejects(() => db.query('UPDATE homes SET child_lock_enabled = NULL WHERE id = $1', [fx.homeId]), (e) => e.code === '23502');
    await assert.rejects(() => db.query('UPDATE devices SET child_lock_enabled = NULL WHERE id = $1', [fx.devices[0].id]), (e) => e.code === '23502');
    for (const bad of ['9:5', '24:00', '23:60', '23-30', '', 'yok']) {
      await assert.rejects(() => db.query('UPDATE homes SET peace_notification_time = $2 WHERE id = $1', [fx.homeId, bad]), (e) => e.code === '23514', bad);
    }
    for (const ok of ['00:00', '23:59', '09:05', null]) {
      await db.query('UPDATE homes SET peace_notification_time = $2 WHERE id = $1', [fx.homeId, ok]);
    }
  });
});
