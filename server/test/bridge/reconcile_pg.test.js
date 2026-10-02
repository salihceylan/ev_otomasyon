'use strict';

// S2 (plan §5d-3) - cevrimici olunca UZLASTIRMA: GERCEK PostgreSQL entegrasyon testleri.
//
// Varsayilan olarak ATLANIR (`npm test` PostgreSQL gerektirmez). Etkinlestirmek icin migration'lanmis bir veritabani verin
// (bkz. pg_integration.test.js basligi):
//   EV_PG_TEST_URL=postgresql://kullanici@127.0.0.1:5432/<db> node --test test/bridge/reconcile_pg.test.js
//
// Her test KENDI satirlarini (rastgele ev/kullanici/cihaz) olusturur ve sonunda siler; baska verilere dokunmaz.
// Neden: uzlastiricinin SQL'i (zaman damgasi METIN karsilastirmasi, JSONB isaret guncellemesi, canlilik ifadesi,
// bigint -> metin donusu) mock'la kanitlanamaz.

const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');

const URL_ = process.env.EV_PG_TEST_URL;
const SKIP = URL_ ? false : 'EV_PG_TEST_URL tanimli degil (gercek PostgreSQL gerekir)';

const { MqttBridge } = require('../../src/mqtt_bridge');
const { SQL, constants } = require('../../src/services/device_reconciler');
const { makeFakeTimers, makeFakeClient, makeFakeMqttLib, flush } = require('./_helpers');

const { SETTLE_MS, INTENT_MAX_AGE_SEC } = constants;

let pool = null;
function getDb() {
  if (!pool) {
    const { Pool } = require('pg');
    pool = new Pool({ connectionString: URL_, max: 6 });
    pool.on('error', () => {});
  }
  return {
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
}

test.after(async () => {
  if (pool) await pool.end().catch(() => {});
});

const hex = (n) => crypto.randomBytes(n).toString('hex');
const silent = { log() {}, warn() {}, error() {} };

/** Ev + n cihaz (+ isteğe bagli panjur/isik kanallari ilk cihaza). */
async function makeFixture(db, { devices = 1, shutters = [] } = {}) {
  const tag = hex(5);
  const topic = `h_${hex(8)}`;
  const homeId = (await db.query('INSERT INTO homes (name, mqtt_username) VALUES ($1, $2) RETURNING id', [`R-${tag}`, topic])).rows[0].id;
  const devs = [];
  for (let i = 0; i < devices; i += 1) {
    const uuid = `AHBU-R${tag}-${i}`.toUpperCase();
    devs.push((await db.query(
      'INSERT INTO devices (home_id, device_uuid, mac_address, is_claimed) VALUES ($1, $2, $3, TRUE) RETURNING id, device_uuid',
      [homeId, uuid, `R${tag}${i}`]
    )).rows[0]);
  }
  let ch = 1;
  for (const [pair, sec] of shutters) {
    for (const k of [0, 1]) {
      await db.query(
        `INSERT INTO endpoints (home_id, device_id, channel_index, name, type, room, shutter_pair_index, shutter_duration_sec)
         VALUES ($1, $2, $3, $4, 'shutter', 'Genel', $5, $6)`,
        [homeId, devs[0].id, ch + k, `P${pair}`, pair, sec]
      );
    }
    ch += 2;
  }
  return {
    topic,
    homeId,
    devices: devs,
    async cleanup() {
      await db.query('DELETE FROM homes WHERE id = $1', [homeId]).catch(() => {});
      await db.query('DELETE FROM devices WHERE id = ANY($1::uuid[])', [devs.map((d) => d.id)]).catch(() => {});
    },
  };
}

async function withFixture(opts, fn) {
  const db = getDb();
  const fx = await makeFixture(db, opts);
  try {
    await fn(db, fx);
  } finally {
    await fx.cleanup();
  }
}

const one = async (db, sql, params) => (await db.query(sql, params)).rows[0];

// ------------------------------------------------------------------------------
// SQL anlamlari (gercek PostgreSQL)
// ------------------------------------------------------------------------------
test('SQL.childLock: niyet, cihaz durumu, CANLILIK (is_online + son gorulme) ve tur donusumleri', { skip: SKIP }, async () => {
  await withFixture({ devices: 3 }, async (db, fx) => {
    const [a, b, c] = fx.devices;
    await db.query("UPDATE devices SET is_online = TRUE, last_seen_at = CURRENT_TIMESTAMP - INTERVAL '5 seconds' WHERE id = $1", [a.id]);
    await db.query("UPDATE devices SET is_online = TRUE, last_seen_at = CURRENT_TIMESTAMP - INTERVAL '500 seconds' WHERE id = $1", [b.id]); // bayat
    await db.query('UPDATE devices SET is_online = FALSE, child_lock_enabled = TRUE WHERE id = $1', [c.id]);
    await db.query('UPDATE homes SET child_lock_requested = TRUE, child_lock_requested_at = CURRENT_TIMESTAMP WHERE id = $1', [fx.homeId]);

    const rows = (await db.query(SQL.childLock, [fx.topic, 120])).rows;
    assert.equal(rows.length, 3);
    const byId = new Map(rows.map((r) => [r.device_id, r]));
    assert.equal(byId.get(a.id).live, true);
    assert.equal(byId.get(b.id).live, false, 'is_online TRUE ama son gorulme 120 sn eski -> canli degil');
    assert.equal(byId.get(c.id).live, false);
    assert.equal(byId.get(c.id).child_lock_enabled, true);
    assert.equal(byId.get(a.id).child_lock_enabled, false);
    for (const r of rows) {
      assert.equal(r.requested, true);
      assert.equal(typeof r.requested_at_text, 'string');
      assert.ok(Number.isFinite(Number(r.requested_age_sec)), 'bigint metin olarak gelir; Number() ile okunur');
    }
    // cihazsiz ev: tek satir, device_id NULL
    const empty = await db.query('INSERT INTO homes (name, mqtt_username) VALUES ($1, $2) RETURNING id', ['bos', `h_${hex(8)}`]);
    try {
      const e = (await db.query(SQL.childLock, [(await one(db, 'SELECT mqtt_username FROM homes WHERE id = $1', [empty.rows[0].id])).mqtt_username, 120])).rows;
      assert.equal(e.length, 1);
      assert.equal(e[0].device_id, null);
    } finally {
      await db.query('DELETE FROM homes WHERE id = $1', [empty.rows[0].id]);
    }
  });
});

test('SQL.clearSatisfied / clearExpired: yalniz hepsi uyumluysa ve niyet+zaman damgasi AYNIYSA temizler (mikrosaniye hassasiyeti)', { skip: SKIP }, async () => {
  await withFixture({ devices: 2 }, async (db, fx) => {
    await db.query('UPDATE homes SET child_lock_requested = TRUE, child_lock_requested_at = CURRENT_TIMESTAMP, child_lock_requested_by = NULL WHERE id = $1', [fx.homeId]);
    const r = (await db.query(SQL.childLock, [fx.topic, 120])).rows[0];
    const args = (value, at) => [fx.homeId, value, at];

    assert.equal((await db.query(SQL.clearSatisfied, args(true, r.requested_at_text))).rowCount, 0, 'cihazlar FALSE: uyumsuz');
    await db.query('UPDATE devices SET child_lock_enabled = TRUE WHERE id = $1', [fx.devices[0].id]);
    assert.equal((await db.query(SQL.clearSatisfied, args(true, r.requested_at_text))).rowCount, 0, 'ikinci cihaz hala uyumsuz');
    await db.query('UPDATE devices SET child_lock_enabled = TRUE WHERE home_id = $1', [fx.homeId]);
    assert.equal((await db.query(SQL.clearSatisfied, args(false, r.requested_at_text))).rowCount, 0, 'yanlis deger');
    assert.equal((await db.query(SQL.clearSatisfied, args(true, '2000-01-01 00:00:00+00'))).rowCount, 0, 'yanlis zaman damgasi (REST yeni istek yazmis)');
    // son hassasiyet: mikrosaniye farki bile farkli niyettir
    const shifted = await one(db, "SELECT (child_lock_requested_at + INTERVAL '1 microsecond')::text AS t FROM homes WHERE id = $1", [fx.homeId]);
    assert.equal((await db.query(SQL.clearSatisfied, args(true, shifted.t))).rowCount, 0);

    assert.equal((await db.query(SQL.clearSatisfied, args(true, r.requested_at_text))).rowCount, 1);
    const h = await one(db, 'SELECT child_lock_requested, child_lock_requested_at, child_lock_requested_by FROM homes WHERE id = $1', [fx.homeId]);
    assert.deepEqual(h, { child_lock_requested: null, child_lock_requested_at: null, child_lock_requested_by: null });

    // bayat niyet: yas hesabi + cihaz durumundan bagimsiz temizleme
    await db.query("UPDATE homes SET child_lock_requested = FALSE, child_lock_requested_at = CURRENT_TIMESTAMP - INTERVAL '20 days' WHERE id = $1", [fx.homeId]);
    const old = (await db.query(SQL.childLock, [fx.topic, 120])).rows[0];
    assert.ok(Number(old.requested_age_sec) > INTENT_MAX_AGE_SEC);
    assert.equal((await db.query(SQL.clearExpired, args(false, old.requested_at_text))).rowCount, 1);
  });
});

test('SQL.runtimePending / runtimeShutters / runtimeDone: replaceBoard isareti (JSONB), pair basina sure, yalniz AYNI isareti temizler', { skip: SKIP }, async () => {
  await withFixture({ devices: 1, shutters: [[1, 24], [2, 31]] }, async (db, fx) => {
    const dev = fx.devices[0];
    const replacedAt = new Date().toISOString();
    // replaceBoard'in yazdigi bicim: JSON METNI parametre olarak (jsonb kolonuna)
    await db.query('UPDATE devices SET config_snapshot = $2 WHERE id = $1', [dev.id, JSON.stringify({
      replaced_at: replacedAt, old_device_uuid: 'AHBU-OLD', new_device_uuid: dev.device_uuid, home_id: fx.homeId, runtime_sync: 'pending', endpoints: [{ channel_index: 1 }],
    })]);
    await db.query('UPDATE devices SET is_online = TRUE, last_seen_at = CURRENT_TIMESTAMP WHERE id = $1', [dev.id]);

    const rows = (await db.query(SQL.runtimePending, [fx.topic, 120])).rows;
    assert.equal(rows.length, 1);
    assert.equal(rows[0].device_id, dev.id);
    assert.equal(rows[0].home_id, fx.homeId);
    assert.equal(rows[0].marker_home_id, fx.homeId);
    assert.equal(rows[0].marker_replaced_at, replacedAt);
    assert.equal(rows[0].device_count, 1);
    assert.equal(rows[0].live, true);

    const sh = (await db.query(SQL.runtimeShutters, [dev.id])).rows;
    assert.deepEqual(sh.map((r) => [r.pair, r.sec]), [[1, 24], [2, 31]], 'yukari/asagi satirlari tek cift olur');

    assert.equal((await db.query(SQL.runtimeDone, [dev.id, 'baska-isaret'])).rowCount, 0);
    assert.equal((await db.query(SQL.runtimeDone, [dev.id, replacedAt])).rowCount, 1);
    const after = await one(db, "SELECT config_snapshot ->> 'runtime_sync' AS s, config_snapshot ->> 'runtime_synced_at' AS at, jsonb_array_length(config_snapshot -> 'endpoints') AS n FROM devices WHERE id = $1", [dev.id]);
    assert.equal(after.s, 'synced');
    assert.ok(after.at, 'uygulanma zamani yazilmali');
    assert.equal(after.n, 1, 'anlik goruntunun geri kalani korunur');
    assert.equal((await db.query(SQL.runtimePending, [fx.topic, 120])).rows.length, 0, 'artik bekleyen yok');
    assert.equal((await db.query(SQL.runtimeDone, [dev.id, replacedAt])).rowCount, 0, 'ikinci temizleme etkisiz');
  });
});

// ------------------------------------------------------------------------------
// Uctan uca: gercek kopru state yolu + gercek SQL + sahte istemci/zamanlayici
// ------------------------------------------------------------------------------
function makeBridge(db) {
  const timers = makeFakeTimers();
  const client = makeFakeClient();
  const bridge = new MqttBridge({
    db,
    logger: silent,
    env: { MQTT_BACKEND_USER: 'u', MQTT_BACKEND_PASS: 'p' },
    timers,
    mqttLib: makeFakeMqttLib(client),
    reconcile: true,
  });
  return { bridge, timers, client };
}
async function connect({ bridge, client }) {
  bridge.init();
  client.connected = true;
  client.emit('connect', { sessionPresent: false });
  await flush();
}
const sendState = (bridge, topic, uid, obj, retain = false) =>
  bridge.handleIncomingMessage(`ev/${topic}/state`, Buffer.from(JSON.stringify({ uid, ...obj })), { retain });
const fire = async (ctx) => {
  const pending = ctx.timers.pendingTimeouts();
  assert.equal(pending.length, 1);
  ctx.timers.fireTimeout(pending[0]);
  await ctx.bridge._reconciler.whenIdle();
  await flush();
  return pending[0].ms;
};

test('UCTAN UCA (cocuk kilidi): pano degisimi sonrasi yeni pano cevrimici olunca niyet BIR KEZ uygulanir, yanki gelince niyet temizlenir', { skip: SKIP }, async () => {
  await withFixture({ devices: 1 }, async (db, fx) => {
    const dev = fx.devices[0];
    await db.query('UPDATE homes SET child_lock_enabled = TRUE, child_lock_requested = TRUE, child_lock_requested_at = CURRENT_TIMESTAMP WHERE id = $1', [fx.homeId]);
    const ctx = makeBridge(db);
    await connect(ctx);
    try {
      // yeni pano ilk acilis: kilitsiz bildirir
      await sendState(ctx.bridge, fx.topic, dev.device_uuid, { child_lock: false, relays: [{ id: 1, state: false }] });
      assert.equal(ctx.client.published.length, 0, 'henuz yayin yok (SETTLE)');
      assert.equal(await fire(ctx), SETTLE_MS);
      assert.equal(ctx.client.published.length, 1);
      const pub = ctx.client.published[0];
      assert.equal(pub.topic, `ev/${fx.topic}/cmd`);
      assert.deepEqual(pub.opts, { qos: 1, retain: false });
      const cmd = JSON.parse(pub.payload);
      assert.equal(cmd.cmd, 'set_child_lock');
      assert.equal(cmd.enabled, true);
      assert.match(cmd.id, /^[A-Za-z0-9._:-]{1,24}$/);
      const pending = await one(db, 'SELECT child_lock_requested FROM homes WHERE id = $1', [fx.homeId]);
      assert.equal(pending.child_lock_requested, true, 'yanki gelene kadar niyet bekler');

      // cihaz uyguladi ve yanki state'i gonderdi
      await sendState(ctx.bridge, fx.topic, dev.device_uuid, { child_lock: true, last_id: cmd.id });
      // yanki (RESOLVE satirindaki niyet = bildirilen deger) 5 sn'lik ustel bekleme beklenmeden kisa kontrol planlar
      assert.equal(await fire(ctx), SETTLE_MS);
      assert.equal(ctx.client.published.length, 1, 'ikinci yayin OLMAMALI (dongu yok)');
      const done = await one(db, 'SELECT child_lock_enabled, child_lock_requested, child_lock_requested_at, child_lock_requested_by FROM homes WHERE id = $1', [fx.homeId]);
      assert.deepEqual(done, { child_lock_enabled: true, child_lock_requested: null, child_lock_requested_at: null, child_lock_requested_by: null });
      assert.equal(ctx.timers.pendingTimeouts().length, 0);
    } finally {
      await ctx.bridge.end({ force: true, timeoutMs: 50 });
    }
  });
});

test('UCTAN UCA (panjur): pano degisimi isareti olan yeni pano cevrimici olunca her panjur cifti set_runtime ile uygulanir, isaret synced olur; RETAINED state tetiklemez', { skip: SKIP }, async () => {
  await withFixture({ devices: 1, shutters: [[1, 24], [2, 31]] }, async (db, fx) => {
    const dev = fx.devices[0];
    await db.query('UPDATE devices SET config_snapshot = $2 WHERE id = $1', [dev.id, JSON.stringify({
      replaced_at: new Date().toISOString(), old_device_uuid: 'AHBU-OLD', new_device_uuid: dev.device_uuid, home_id: fx.homeId, runtime_sync: 'pending', endpoints: [],
    })]);
    const ctx = makeBridge(db);
    await connect(ctx);
    // aralik beklemesi gercek zamanlayicidan degil: yayin arasi bekleme icin uzlastiriciya sahte uyku ver
    ctx.bridge._getReconciler();
    ctx.bridge._reconciler._sleep = async () => {};
    try {
      await sendState(ctx.bridge, fx.topic, dev.device_uuid, { child_lock: false }, true); // retained: tetiklemez
      assert.equal(ctx.timers.pendingTimeouts().length, 0);

      await sendState(ctx.bridge, fx.topic, dev.device_uuid, { child_lock: false });
      await fire(ctx);
      const cmds = ctx.client.published.map((p) => JSON.parse(p.payload));
      assert.deepEqual(cmds.map((c) => [c.cmd, c.shutter, c.sec]), [['set_runtime', 1, 24], ['set_runtime', 2, 31]]);
      assert.equal(new Set(cmds.map((c) => c.id)).size, 2, 'her komut ayri kimlik');
      const s = await one(db, "SELECT config_snapshot ->> 'runtime_sync' AS s FROM devices WHERE id = $1", [dev.id]);
      assert.equal(s.s, 'synced');

      // yeniden baglanma (yeni donem): isaret yok -> yayin yok
      ctx.bridge._reconciler._homes.get(fx.topic).devices.clear();
      await sendState(ctx.bridge, fx.topic, dev.device_uuid, { child_lock: false });
      await fire(ctx);
      assert.equal(ctx.client.published.length, 2);
    } finally {
      await ctx.bridge.end({ force: true, timeoutMs: 50 });
    }
  });
});

test('UCTAN UCA (idempotent): niyet yok / zaten ayni durum -> HICBIR sey yayinlanmaz', { skip: SKIP }, async () => {
  await withFixture({ devices: 1 }, async (db, fx) => {
    const dev = fx.devices[0];
    const ctx = makeBridge(db);
    await connect(ctx);
    try {
      await sendState(ctx.bridge, fx.topic, dev.device_uuid, { child_lock: true });
      await fire(ctx);
      assert.equal(ctx.client.published.length, 0, 'niyet yok');

      await db.query('UPDATE homes SET child_lock_requested = TRUE, child_lock_requested_at = CURRENT_TIMESTAMP WHERE id = $1', [fx.homeId]);
      ctx.bridge._reconciler._homes.get(fx.topic).devices.clear();
      await sendState(ctx.bridge, fx.topic, dev.device_uuid, { child_lock: true }); // cihaz zaten kilitli
      await fire(ctx);
      assert.equal(ctx.client.published.length, 0, 'ayni durum');
      assert.equal((await one(db, 'SELECT child_lock_requested FROM homes WHERE id = $1', [fx.homeId])).child_lock_requested, null, 'niyet temizlendi');
    } finally {
      await ctx.bridge.end({ force: true, timeoutMs: 50 });
    }
  });
});

test('UCTAN UCA (REST ile cevrimici cihaz): istek yazilir, cihaz yankilar -> bekleyen niyet TEMIZLENIR (yayin yok); sonradan yerel degisiklik ezilmez', { skip: SKIP }, async () => {
  await withFixture({ devices: 1 }, async (db, fx) => {
    const dev = fx.devices[0];
    const ctx = makeBridge(db);
    await connect(ctx);
    try {
      // cihaz cevrimici doneme girdi (niyet yok): tek kontrol, yayin yok
      await sendState(ctx.bridge, fx.topic, dev.device_uuid, { child_lock: false });
      await fire(ctx);
      assert.equal(ctx.client.published.length, 0);

      // REST kilidi istedi (niyet yazildi, komut ayri yolla yayinlanir) ve cihaz uygulayip yankiladi
      await db.query('UPDATE homes SET child_lock_requested = TRUE, child_lock_requested_at = CURRENT_TIMESTAMP WHERE id = $1', [fx.homeId]);
      await sendState(ctx.bridge, fx.topic, dev.device_uuid, { child_lock: true });
      await fire(ctx);
      assert.equal(ctx.client.published.length, 0, 'uzlastirici yayin yapmaz: cihaz zaten uygulamis');
      assert.equal((await one(db, 'SELECT child_lock_requested FROM homes WHERE id = $1', [fx.homeId])).child_lock_requested, null);

      // sonradan yerel/LAN'dan kilit acildi; yeniden baglanma (yeni donem) eski niyetle GERI ALMAMALI
      ctx.bridge._reconciler._homes.get(fx.topic).devices.clear();
      await sendState(ctx.bridge, fx.topic, dev.device_uuid, { child_lock: false });
      await fire(ctx);
      assert.equal(ctx.client.published.length, 0, 'bayat niyet yok -> yerel degisiklik ezilmez');
    } finally {
      await ctx.bridge.end({ force: true, timeoutMs: 50 });
    }
  });
});
