// Gercek (gomulu) PostgreSQL: yasam dongusu, orijinal pg_ctl ile temiz kapanis, PgCredentialStore ve
// broker uctan uca (mqtt_* tablolari test SEMASINDA yaratilir; calisan QA yiginina dokunulmaz).
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import pg from 'pg';
import { PgManager, readPostmasterPid, stopPgByDataDir } from '../lib/pg.js';
import { PgCredentialStore } from '../lib/credstore.js';
import { createLogger, freePort, pidAlive, randomB64Url, sleep, tcpProbe, waitFor } from '../lib/util.js';
import { connect, endClients, hashPw, subscribe, tmpDir } from './_helpers.js';
import { startBroker } from '../lib/broker.js';

const DDL = `
CREATE TABLE mqtt_credentials (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  username text UNIQUE NOT NULL,
  password_hash text NOT NULL,
  kind text NOT NULL CHECK (kind IN ('device','app','backend')),
  home_id uuid, user_id uuid, device_id uuid,
  expires_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE mqtt_acl (
  id bigserial PRIMARY KEY,
  username text NOT NULL,
  permission text NOT NULL CHECK (permission IN ('allow','deny')),
  action text NOT NULL CHECK (action IN ('publish','subscribe','all')),
  topic text NOT NULL
);
CREATE INDEX ON mqtt_acl (username);
`;

test('gomulu PostgreSQL: yasam dongusu, kimlik deposu ve broker uctan uca', async (t) => {
  const root = tmpDir('qa_pg_');
  const dataDir = path.join(root, 'pgdata');
  const password = randomB64Url(18);
  const port = await freePort();
  const pgm = new PgManager({ dataDir, password, port, database: 'ev_qa_test', logFile: path.join(root, 'pg.log') });
  let broker;
  let store;

  try {
    await t.test('initdb + start: PostgreSQL 18, UTF8, gen_random_uuid/generate_series/FOR UPDATE, uzantilar', async () => {
      assert.equal(pgm.isInitialised(), false);
      const st = await pgm.start();
      assert.equal(st.running, true);
      assert.ok(pidAlive(st.pid));
      assert.equal(await tcpProbe('127.0.0.1', port), true);

      const v = await pgm.query('SHOW server_version_num');
      assert.ok(Number(v.rows[0].server_version_num) >= 180000, `surum: ${v.rows[0].server_version_num}`);
      assert.equal((await pgm.query('SHOW server_encoding')).rows[0].server_encoding, 'UTF8');

      const g = await pgm.query('SELECT gen_random_uuid() AS u, (SELECT count(*) FROM generate_series(1,16))::int AS n');
      assert.match(g.rows[0].u, /^[0-9a-f-]{36}$/);
      assert.equal(g.rows[0].n, 16);

      // migration 001 CREATE EXTENSION kullanir
      await pgm.query('CREATE EXTENSION IF NOT EXISTS "pgcrypto"');
      await pgm.query('CREATE EXTENSION IF NOT EXISTS "uuid-ossp"');
      const crypt = await pgm.query("SELECT crypt('x', gen_salt('bf', 4)) AS h");
      assert.match(crypt.rows[0].h, /^\$2a\$04\$/);

      const c = new pg.Client({ connectionString: pgm.connectionString });
      await c.connect();
      await c.query('CREATE TEMP TABLE t(id int primary key, v int)');
      await c.query('BEGIN');
      await c.query('INSERT INTO t VALUES (1, 0)');
      const lock = await c.query('SELECT * FROM t WHERE id = 1 FOR UPDATE');
      await c.query('COMMIT');
      await c.end();
      assert.equal(lock.rowCount, 1);
    });

    await t.test('PgCredentialStore: tablolar yokken hazir degil; broker cokmeden bekler, tablolar olusunca devreye girer', async () => {
      await pgm.query('CREATE SCHEMA qa_test');
      store = new PgCredentialStore({ connectionString: pgm.connectionString, schema: 'qa_test' });
      assert.equal(await store.isReady(), false);

      const backend = { username: 'backend_service', password: randomB64Url(16) };
      broker = await startBroker({
        store, backend, host: '127.0.0.1', port: 0, wsPort: null, controlPort: null,
        log: createLogger(null), storePollMs: 100,
      });
      assert.equal(broker.isStoreReady(), false);

      // backend ortamdan: tablolar olmadan da baglanir
      await endClients(await connect({ port: broker.port, username: backend.username, password: backend.password }));
      // cihaz: CONNACK 3 (sunucu hazir degil)
      await assert.rejects(connect({ port: broker.port, username: 'd_h_x', password: 'p' }), (e) => e.code === 3);

      // migration 020 benzeri tablolari olustur
      await pgm.query(`SET search_path TO qa_test; ${DDL}`);
      await waitFor(() => broker.isStoreReady(), { timeoutMs: 5000, label: 'broker tablolari algilamadi' });
      assert.equal(await store.isReady(), true);
    });

    await t.test('kimlik: bcrypt, expires_at, ACL, silme (PostgreSQL uzerinde)', async () => {
      const c = new pg.Client({ connectionString: pgm.connectionString, options: '-c search_path=qa_test' });
      await c.connect();
      const T = 'h_aaaaaaaaaaaaaaaa';
      await c.query('INSERT INTO mqtt_credentials (username, password_hash, kind) VALUES ($1,$2,$3)', [`d_${T}`, hashPw('dev-pw'), 'device']);
      await c.query("INSERT INTO mqtt_credentials (username, password_hash, kind, expires_at) VALUES ($1,$2,'app', now() + interval '1 hour')", [`a_${T}_ok`, hashPw('app-pw')]);
      await c.query("INSERT INTO mqtt_credentials (username, password_hash, kind, expires_at) VALUES ($1,$2,'app', now() - interval '1 minute')", [`a_${T}_old`, hashPw('app-pw')]);
      for (const [u, perm, act, top] of [
        [`d_${T}`, 'allow', 'publish', `ev/${T}/state`],
        [`d_${T}`, 'allow', 'subscribe', `ev/${T}/cmd`],
        [`a_${T}_ok`, 'allow', 'subscribe', `ev/${T}/state`],
        [`a_${T}_old`, 'allow', 'subscribe', `ev/${T}/state`],
      ]) {
        await c.query('INSERT INTO mqtt_acl (username, permission, action, topic) VALUES ($1,$2,$3,$4)', [u, perm, act, top]);
      }

      const dev = await connect({ port: broker.port, username: `d_${T}`, password: 'dev-pw' });
      assert.equal((await subscribe(dev, `ev/${T}/cmd`)).granted, true);
      assert.equal((await subscribe(dev, `ev/${T}/state`)).granted, false);
      await endClients(dev);

      const app = await connect({ port: broker.port, username: `a_${T}_ok`, password: 'app-pw' });
      assert.equal((await subscribe(app, `ev/${T}/state`)).granted, true);
      assert.equal((await subscribe(app, `ev/${T}/cmd`)).granted, false);
      await endClients(app);

      await assert.rejects(connect({ port: broker.port, username: `a_${T}_old`, password: 'app-pw' }), (e) => e.code === 4, 'suresi dolmus');
      await assert.rejects(connect({ port: broker.port, username: `d_${T}`, password: 'yanlis' }), (e) => e.code === 4);

      // sunucunun "uye cikar" davranisi: satirlar silinir -> yeni baglanti reddedilir
      await c.query('DELETE FROM mqtt_acl WHERE username = $1', [`a_${T}_ok`]);
      await c.query('DELETE FROM mqtt_credentials WHERE username = $1', [`a_${T}_ok`]);
      await assert.rejects(connect({ port: broker.port, username: `a_${T}_ok`, password: 'app-pw' }), (e) => e.code === 4);
      await c.end();
    });

    await t.test('temiz kapanis: pg_ctl stop -m fast, sureç kalmaz; veri kalici; oksuz temizlik', async () => {
      await broker.close();
      broker = null;
      await store.close();
      store = null;

      const before = await pgm.status();
      assert.equal(before.running, true);
      const pid = before.pid;

      const res = await pgm.stop();
      assert.equal(res.stopped, true);
      assert.equal(res.forced, false, 'temiz kapanis (zorla oldurme degil)');
      await waitFor(() => !pidAlive(pid), { timeoutMs: 10000, label: 'postgres sureci hala canli' });
      assert.equal(fs.existsSync(path.join(dataDir, 'postmaster.pid')), false);
      assert.equal(await tcpProbe('127.0.0.1', port), false);

      // yeniden baslat: veri kalici
      const pgm2 = new PgManager({ dataDir, password, port, database: 'ev_qa_test', logFile: path.join(root, 'pg.log') });
      await pgm2.start();
      const rows = await pgm2.query('SELECT count(*)::int AS n FROM qa_test.mqtt_credentials');
      assert.equal(rows.rows[0].n, 2, 'silinenler haric kayitlar kalici');
      assert.ok(readPostmasterPid(dataDir));

      // yonetici nesne olmadan temizleme (run.js down yolu)
      const pid2 = readPostmasterPid(dataDir);
      const r = await stopPgByDataDir(dataDir);
      assert.equal(r.stopped, true);
      await waitFor(() => !pidAlive(pid2), { timeoutMs: 10000, label: 'oksuz temizlik sonrasi surec canli' });
      assert.equal(await tcpProbe('127.0.0.1', port), false);

      // zaten kapali: zararsiz
      const again = await stopPgByDataDir(dataDir);
      assert.equal(again.stopped, false);
      assert.equal(again.reason, 'not_running');
    });

    await t.test('reset: veri dizinini siler', async () => {
      await pgm.reset();
      assert.equal(fs.existsSync(dataDir), false);
    });
  } finally {
    if (broker) await broker.close().catch(() => {});
    if (store) await store.close().catch(() => {});
    await stopPgByDataDir(dataDir).catch(() => {});
    await sleep(200);
    fs.rmSync(root, { recursive: true, force: true, maxRetries: 10, retryDelay: 200 });
  }
});

