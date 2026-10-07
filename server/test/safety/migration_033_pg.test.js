'use strict';

// WP-S1 - GERCEK PostgreSQL: migration 033 (alarms, device_events, device_configs, devices.caps/safety_state,
// endpoints.actuator_type/dimmable/dimmer_source, mevcut cihaz kimliklerine ev/{t}/event ACL satiri).
//
// Varsayilan olarak ATLANIR (`npm test` PostgreSQL gerektirmez). Etkinlestirmek icin migration'lanmis (001..033)
// bir veritabani verin:
//   EV_PG_TEST_URL=postgresql://postgres@127.0.0.1:55432/<db> node --test test/safety/migration_033_pg.test.js
// Her test TEK transaction icinde calisir ve ROLLBACK ile biter: veritabaninda iz kalmaz. Uretim veritabanina
// KARSI CALISTIRMAYIN.
// Inceleme turu 2 RV2-2: 033'u (DDL, AccessExclusiveLock) paralel kosan diger PG test dosyalariyla AYNI veritabaninda calistirmak
// kilitlenme uretir ve kurban DIGER dosya olabilir (onlarin temizligi hatayi yutar, satir sizar). Bu yuzden dosya, yetki varsa KENDI
// gecici veritabaninda (`<db>_t033_<pid>`, scripts/migrate.js ile 001..033 kurulur, sonda silinir) kosar; CREATE DATABASE yetkisi yoksa
// verilen veritabanina doner (kilitlenme kurbani test yeniden denenir).

const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');

const URL_ = process.env.EV_PG_TEST_URL;
const SKIP = URL_ ? false : 'EV_PG_TEST_URL tanimli degil (gercek PostgreSQL gerekir)';
const SQL_FILE = path.join(__dirname, '..', '..', 'migrations', '033_safety_alarms.sql');

let poolPromise = null;
let isolatedDb = null;

function withDatabase(url, name) {
  const u = new URL(url);
  u.pathname = `/${name}`;
  return u.toString();
}

/** Yalitilmis veritabani: olusturulup migrate.js ile kurulur. Yetki/kurulum hatasinda null (verilen veritabani kullanilir). */
async function createIsolatedDb() {
  const { Client } = require('pg');
  const base = new URL(URL_).pathname.replace(/^\//, '') || 'postgres';
  const name = `${base}_t033_${process.pid}`.toLowerCase().replace(/[^a-z0-9_]/g, '_').slice(0, 60);
  const admin = new Client({ connectionString: URL_, connectionTimeoutMillis: 15000 });
  try {
    await admin.connect();
    await admin.query(`DROP DATABASE IF EXISTS ${name}`);
    await admin.query(`CREATE DATABASE ${name}`);
  } catch (_) {
    return null;
  } finally {
    await admin.end().catch(() => {});
  }
  const url = withDatabase(URL_, name);
  const { main } = require('../../scripts/migrate');
  const rc = await main({ argv: [], env: { DATABASE_URL: url, MIGRATE_CONFIRM: name }, log: () => {}, errLog: () => {} });
  if (rc !== 0) {
    await dropIsolatedDb(name);
    return null;
  }
  return { name, url };
}

async function dropIsolatedDb(name) {
  const { Client } = require('pg');
  const admin = new Client({ connectionString: URL_, connectionTimeoutMillis: 15000 });
  try {
    await admin.connect();
    await admin.query(`DROP DATABASE IF EXISTS ${name}`);
  } catch (_) {
    /* temizlik en iyi caba */
  } finally {
    await admin.end().catch(() => {});
  }
}

function getPool() {
  if (!poolPromise) {
    poolPromise = (async () => {
      const { Pool } = require('pg');
      isolatedDb = await createIsolatedDb();
      const pool = new Pool({ connectionString: isolatedDb ? isolatedDb.url : URL_, max: 4, connectionTimeoutMillis: 15000 });
      pool.on('error', () => {});
      return pool;
    })();
  }
  return poolPromise;
}

test.after(async () => {
  if (poolPromise) await (await poolPromise).end().catch(() => {});
  if (isolatedDb) await dropIsolatedDb(isolatedDb.name);
});

/**
 * fn(client) BEGIN ... ROLLBACK icinde; savepoint'ler beklenen hatalar icin (hata transaction'i bozmaz).
 * Yalitilmis veritabani kurulamadiysa (yetki yok) 033 (DDL) paralel kosan diger PG test dosyalariyla AYNI veritabaninda calisir: kilitlenme
 * kurbani bu dosyaysa test en cok 3 kez yeniden denenir (inceleme RV-5/RV2-2; uretim goc araci tek transaction + lock_timeout ile calisir).
 */
async function inRollback(fn) {
  const pool = await getPool();
  for (let attempt = 1; ; attempt++) {
    const client = await pool.connect();
    try {
      await client.query('BEGIN');
      await fn(client);
      return;
    } catch (err) {
      if (!(err && err.code === '40P01' && attempt < 3)) throw err;
    } finally {
      await client.query('ROLLBACK').catch(() => {});
      client.release();
    }
    await new Promise((r) => setTimeout(r, 50 * attempt));
  }
}

async function expectPgError(client, sql, params, code) {
  await client.query('SAVEPOINT sp');
  try {
    await client.query(sql, params);
    assert.fail(`hata bekleniyordu (${code}): ${sql}`);
  } catch (err) {
    if (err && err.code === 'ERR_ASSERTION') throw err;
    assert.equal(err.code, code, `${sql}: ${err.message}`);
  } finally {
    await client.query('ROLLBACK TO SAVEPOINT sp');
  }
}

async function fixture(client) {
  const tag = crypto.randomBytes(4).toString('hex');
  const topic = `h_${tag}${tag}`;
  const home = (await client.query(
    "INSERT INTO homes (name, mqtt_username) VALUES ($1, $2) RETURNING id",
    [`S1 ${tag}`, topic]
  )).rows[0];
  const dev = (await client.query(
    'INSERT INTO devices (home_id, device_uuid, mac_address) VALUES ($1, $2, $3) RETURNING id',
    [home.id, `AHBU-S3-${tag.slice(0, 6).toUpperCase()}`, `02:00:${tag.slice(0, 2)}:${tag.slice(2, 4)}:${tag.slice(4, 6)}:${tag.slice(6, 8)}`]
  )).rows[0];
  const user = (await client.query(
    "INSERT INTO users (email, full_name, password_hash) VALUES ($1, 'S1', 'x') RETURNING id",
    [`s1-${tag}@test.invalid`]
  )).rows[0];
  // 033 ONCESI uretilmis cihaz kimligi (event satiri YOK) + uygulama kimligi (yalniz abonelik)
  const cred = (await client.query(
    "INSERT INTO mqtt_credentials (username, password_hash, kind, home_id, device_id) VALUES ($1, 'x', 'device', $2, $3) RETURNING id",
    [`d_${topic}`, home.id, dev.id]
  )).rows[0];
  await client.query(
    `INSERT INTO mqtt_acl (credential_id, username, permission, action, topic) VALUES
       ($1, $2, 'allow', 'publish', $3), ($1, $2, 'allow', 'publish', $4),
       ($1, $2, 'allow', 'subscribe', $5), ($1, $2, 'allow', 'subscribe', $6)`,
    [cred.id, `d_${topic}`, `ev/${topic}/state`, `ev/${topic}/status`, `ev/${topic}/cmd`, `ev/${topic}/sys`]
  );
  const app = (await client.query(
    "INSERT INTO mqtt_credentials (username, password_hash, kind, home_id, user_id, expires_at) VALUES ($1, 'x', 'app', $2, $3, now() + interval '1 hour') RETURNING id",
    [`a_${topic}_0123456789`, home.id, user.id]
  )).rows[0];
  await client.query(
    `INSERT INTO mqtt_acl (credential_id, username, permission, action, topic) VALUES
       ($1, $2, 'allow', 'subscribe', $3), ($1, $2, 'allow', 'subscribe', $4)`,
    [app.id, `a_${topic}_0123456789`, `ev/${topic}/state`, `ev/${topic}/status`]
  );
  return { home, dev, user, topic, credId: cred.id, appId: app.id };
}

test('033 sema: UUID FK kolonlari, kolon tipleri ve varsayilanlar', { skip: SKIP }, async () => {
  await inRollback(async (client) => {
    const cols = (await client.query(
      `SELECT table_name, column_name, data_type, is_nullable, column_default
         FROM information_schema.columns
        WHERE (table_name IN ('alarms', 'device_events', 'device_configs'))
           OR (table_name = 'devices' AND column_name IN ('caps', 'safety_state'))
           OR (table_name = 'endpoints' AND column_name IN ('actuator_type', 'dimmable', 'dimmer_source'))`
    )).rows;
    const col = (t, c) => cols.find((r) => r.table_name === t && r.column_name === c);
    for (const [t, c] of [['alarms', 'home_id'], ['alarms', 'device_id'], ['alarms', 'acked_by'], ['alarms', 'ack_requested_by'],
      ['device_events', 'device_id'], ['device_configs', 'device_id']]) {
      assert.equal(col(t, c).data_type, 'uuid', `${t}.${c} UUID olmali`);
    }
    assert.equal(col('alarms', 'id').data_type, 'bigint');
    assert.equal(col('devices', 'caps').data_type, 'jsonb');
    assert.equal(col('devices', 'safety_state').data_type, 'jsonb');
    assert.equal(col('endpoints', 'dimmable').is_nullable, 'NO');
    assert.equal(col('endpoints', 'dimmable').column_default, 'false');
    assert.equal(col('alarms', 'push_status').column_default.startsWith("'pending'"), true);
  });
});

test('033 kisitlar: UNIQUE (device_id, aid), status/origin/zone CHECK, actuator_type/dimmer_source CHECK, FK', { skip: SKIP }, async () => {
  await inRollback(async (client) => {
    const fx = await fixture(client);
    const ins = 'INSERT INTO alarms (home_id, device_id, aid, zone, kind, status, raised_at) VALUES ($1, $2, $3, $4, $5, $6, now())';
    await client.query(ins, [fx.home.id, fx.dev.id, '9f3a11c0-1', 1, 'water', 'latched']);
    await expectPgError(client, ins, [fx.home.id, fx.dev.id, '9f3a11c0-1', 1, 'water', 'latched'], '23505');
    await expectPgError(client, ins, [fx.home.id, fx.dev.id, '9f3a11c0-2', 5, 'water', 'latched'], '23514');
    await expectPgError(client, ins, [fx.home.id, fx.dev.id, '9f3a11c0-3', 1, 'water', 'open'], '23514');
    await expectPgError(
      client,
      "INSERT INTO alarms (home_id, device_id, aid, zone, kind, status, origin, raised_at) VALUES ($1, $2, 'x-1', 1, 'water', 'cleared', 'bogus', now())",
      [fx.home.id, fx.dev.id],
      '23514'
    );
    await expectPgError(client, ins, [fx.home.id, crypto.randomUUID(), 'x-2', 1, 'water', 'latched'], '23503');
    // ON CONFLICT (device_id, aid) DO NOTHING: alarm_service'in tekillestirmesi
    const again = await client.query(`${ins} ON CONFLICT (device_id, aid) DO NOTHING`, [fx.home.id, fx.dev.id, '9f3a11c0-1', 1, 'water', 'latched']);
    assert.equal(again.rowCount, 0);

    const ep = 'INSERT INTO endpoints (home_id, device_id, channel_index, name, type, actuator_type, dimmer_source) VALUES ($1, $2, $3, $4, $5, $6, $7)';
    await client.query(ep, [fx.home.id, fx.dev.id, 5, 'Ana Su Vanasi', 'light', 'valve', null]);
    await expectPgError(client, ep, [fx.home.id, fx.dev.id, 6, 'X', 'light', 'pump', null], '23514');
    await expectPgError(client, ep, [fx.home.id, fx.dev.id, 7, 'X', 'light', null, 'zigbee'], '23514');
    // endpoints.type CHECK degismedi: 'valve' TIP olarak hala reddedilir (eylemci yalniz actuator_type'ta)
    await expectPgError(client, ep, [fx.home.id, fx.dev.id, 8, 'X', 'valve', null, null], '23514');

    // device_events birincil anahtar = tekillestirme
    const ev = "INSERT INTO device_events (device_id, eid, type, body) VALUES ($1, $2, 'alarm_raised', '{}'::jsonb) ON CONFLICT DO NOTHING";
    assert.equal((await client.query(ev, [fx.dev.id, '9f3a11c0-1'])).rowCount, 1);
    assert.equal((await client.query(ev, [fx.dev.id, '9f3a11c0-1'])).rowCount, 0);

    // Cihaz silinince alarmlar / olaylar / yapilandirma kopyasi CASCADE; kullanici silinince acked_by NULL
    await client.query('UPDATE alarms SET acked_by = $1 WHERE device_id = $2', [fx.user.id, fx.dev.id]);
    await client.query('DELETE FROM users WHERE id = $1', [fx.user.id]);
    assert.equal((await client.query('SELECT acked_by FROM alarms WHERE device_id = $1', [fx.dev.id])).rows[0].acked_by, null);
    await client.query("INSERT INTO device_configs (device_id, module, rev, crc, body) VALUES ($1, 'safety', 1, '00000000', '{}'::jsonb)", [fx.dev.id]);
    await client.query('DELETE FROM mqtt_credentials WHERE device_id = $1', [fx.dev.id]);
    await client.query('DELETE FROM devices WHERE id = $1', [fx.dev.id]);
    for (const t of ['alarms', 'device_events', 'device_configs']) {
      assert.equal(Number((await client.query(`SELECT COUNT(*)::int AS n FROM ${t} WHERE device_id = $1`, [fx.dev.id])).rows[0].n), 0, t);
    }
  });
});

test('033 IKI KEZ calistirilir: ACL event satiri bir kez eklenir, uygulama kimligine eklenmez; satir sayilari degismez', { skip: SKIP }, async () => {
  const sql = fs.readFileSync(SQL_FILE, 'utf8');
  await inRollback(async (client) => {
    const fx = await fixture(client);
    const counts = async () => {
      const r = await client.query(
        `SELECT (SELECT COUNT(*)::int FROM mqtt_acl) AS acl, (SELECT COUNT(*)::int FROM alarms) AS alarms,
                (SELECT COUNT(*)::int FROM device_events) AS events, (SELECT COUNT(*)::int FROM device_configs) AS configs,
                (SELECT COUNT(*)::int FROM endpoints) AS endpoints`
      );
      return r.rows[0];
    };
    await client.query(sql); // 1. calistirma (migrate.js zaten uyguladi: bu ikinci; fixture'in kimligi icin ilk)
    const after1 = await counts();
    const mine = await client.query('SELECT action, topic FROM mqtt_acl WHERE credential_id = $1 ORDER BY action, topic', [fx.credId]);
    assert.deepEqual(mine.rows.map((r) => `${r.action}:${r.topic}`), [
      `publish:ev/${fx.topic}/event`,
      `publish:ev/${fx.topic}/state`,
      `publish:ev/${fx.topic}/status`,
      `subscribe:ev/${fx.topic}/cmd`,
      `subscribe:ev/${fx.topic}/sys`,
    ]);
    const app = await client.query("SELECT COUNT(*)::int AS n FROM mqtt_acl WHERE credential_id = $1 AND action = 'publish'", [fx.appId]);
    assert.equal(app.rows[0].n, 0, 'uygulama kimligi yayin izni ALMAZ');

    await client.query(sql); // 2. calistirma: hicbir satir sayisi degismez
    assert.deepEqual(await counts(), after1);
    await client.query(sql); // 3.: yine ayni
    assert.deepEqual(await counts(), after1);
  });
});

test('033 sonrasi yeni cihaz kimligi (mqtt_credential_service) event satirini kendisi alir; 033 yeniden calisinca yinelenmez', { skip: SKIP }, async () => {
  const sql = fs.readFileSync(SQL_FILE, 'utf8');
  await inRollback(async (client) => {
    const fx = await fixture(client);
    process.env.MQTT_PUBLIC_HOST = process.env.MQTT_PUBLIC_HOST || 'broker.test.invalid';
    process.env.MQTT_PUBLIC_PORT = process.env.MQTT_PUBLIC_PORT || '8884';
    const { MqttCredentialService } = require('../../src/services/mqtt_credential_service');
    const svc = new MqttCredentialService({
      db: { query: (t, p) => client.query(t, p), withTransaction: (fn) => fn({ query: (t, p) => client.query(t, p) }) },
      logger: { warn() {}, error() {}, log() {} },
    });
    const tx = { query: (t, p) => client.query(t, p) };
    const issued = await svc.issueDeviceCredential({ homeId: fx.home.id, deviceId: fx.dev.id, tx });
    const before = await client.query(
      "SELECT COUNT(*)::int AS n FROM mqtt_acl WHERE username = $1 AND action = 'publish' AND topic = $2",
      [issued.username, `ev/${fx.topic}/event`]
    );
    assert.equal(before.rows[0].n, 1);
    await client.query(sql);
    const after = await client.query(
      "SELECT COUNT(*)::int AS n FROM mqtt_acl WHERE username = $1 AND action = 'publish' AND topic = $2",
      [issued.username, `ev/${fx.topic}/event`]
    );
    assert.equal(after.rows[0].n, 1, 'NOT EXISTS: yinelenmez');
  });
});
