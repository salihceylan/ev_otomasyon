'use strict';

// Migration 045 (servis sorumlusu kapsami) GERCEK PostgreSQL'de (YALITILMIS gecici veritabani):
//   - 044'e kadar migrate -> eski (kapsamsiz) veri tohumlanir -> 045 uygulanir -> geri doldurma kurallari
//   - ev: en eski role='service_user' uyesi (kuresel rolu hala service_user); yoksa kart sahiplenen servis; yoksa NULL
//   - kart: kurulu kart evinin servisi; stok NULL; site: created_by servis ise o
//   - servis sahibinin uyeligi suresiz; uyeligi olmayan servis sahibine uyelik acilir
//   - ON DELETE SET NULL (servis hesabi silinirse kapsam koke duser); ikinci calistirma (psql) hicbir seyi degistirmez
//     ve kok'un NULL biraktigi / aktardigi kaydi yeniden atamaz
// EV_PG_TEST_URL yoksa ATLANIR (gercek PostgreSQL gerekir).

const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const { Pool } = require('pg');
const { PG_URL, PG_SKIP } = require('../templates/_pg_isolated');

const SQL_045 = fs.readFileSync(path.join(__dirname, '..', '..', 'migrations', '045_service_scope.sql'), 'utf8');
const SQL_PREVIEW = fs.readFileSync(path.join(__dirname, '..', '..', 'scripts', 'service_scope_backfill_preview.sql'), 'utf8');
const hex = (n) => crypto.randomBytes(n).toString('hex');

function withDatabase(url, name) {
  const u = new URL(url);
  u.pathname = `/${name}`;
  return u.toString();
}

async function adminDo(fn) {
  const { Client } = require('pg');
  const c = new Client({ connectionString: PG_URL, connectionTimeoutMillis: 15000 });
  await c.connect();
  try {
    return await fn(c);
  } finally {
    await c.end().catch(() => {});
  }
}

/** Gecici veritabani + migrate.js ile `to` surumune kadar (dahil) uygulanmis sema. */
async function openAt(tag, to) {
  const name = `m045_${tag}_${process.pid}`.toLowerCase().replace(/[^a-z0-9_]/g, '_').slice(0, 60);
  const created = await adminDo(async (c) => {
    await c.query(`DROP DATABASE IF EXISTS ${name}`);
    await c.query(`CREATE DATABASE ${name}`);
    return true;
  }).catch(() => false);
  if (!created) return null;
  const url = withDatabase(PG_URL, name);
  const { main } = require('../../scripts/migrate');
  const run = (argv) => main({ argv, env: { DATABASE_URL: url, MIGRATE_CONFIRM: name }, log: () => {}, errLog: () => {} });
  const pool = new Pool({ connectionString: url, max: 4 });
  pool.on('error', () => {});
  return {
    name,
    url,
    pool,
    migrate: async (argv) => {
      const rc = await run(argv);
      if (rc !== 0) throw new Error(`migrate.js cikis ${rc} (${argv.join(' ')})`);
    },
    async close() {
      await pool.end().catch(() => {});
      await adminDo((c) => c.query(`DROP DATABASE IF EXISTS ${name}`)).catch(() => {});
    },
    to,
  };
}

test('045: geri doldurma kurallari (044 -> 045), servis uyeligi suresiz, ON DELETE SET NULL, tekrar calistirma no-op', { skip: PG_SKIP }, async (t) => {
  const env = await openAt('backfill');
  if (!env) {
    t.skip('CREATE DATABASE yetkisi yok');
    return;
  }
  const q = (text, params) => env.pool.query(text, params);
  try {
    await env.migrate(['--to', '044']);
    const cols = await q("SELECT 1 FROM information_schema.columns WHERE table_name = 'homes' AND column_name = 'service_owner_id'");
    assert.equal(cols.rows.length, 0, '044 sonrasi kolon henuz yok');

    // --- eski veri ---
    const user = async (role, label) =>
      (await q("INSERT INTO users (email, full_name, password_hash, role) VALUES ($1, $2, 'x', $3) RETURNING id", [`${label}-${hex(3)}@test.invalid`, label, role])).rows[0].id;
    const svcA = await user('service_user', 'svcA');
    const svcB = await user('service_user', 'svcB');
    const root = await user('super_user', 'root');
    const cust1 = await user('user', 'cust1');
    const cust2 = await user('user', 'cust2');
    const exSvc = await user('user', 'exsvc'); // eskiden servisti, artik 'user'
    const home = async (name) => (await q('INSERT INTO homes (name, mqtt_username) VALUES ($1, $2) RETURNING id', [name, `h_${hex(8)}`])).rows[0].id;
    const member = (h, u, role, expires = null, ageMin = 0) =>
      q("INSERT INTO home_users (home_id, user_id, role, installer_expires_at, created_at) VALUES ($1, $2, $3, $4, NOW() - ($5 * INTERVAL '1 minute'))", [h, u, role, expires, ageMin]);
    const card = async (uuid, status, { homeId = null, claimedBy = null } = {}) =>
      (await q(
        "INSERT INTO device_inventory (device_uuid, mac_address, pin_hash, status, claimed_home_id, claimed_by_user_id, claimed_at) VALUES ($1, $2, 'x', $3, $4, $5, CASE WHEN $4::uuid IS NULL THEN NULL ELSE NOW() END) RETURNING id",
        [uuid, `E8:F6:0A:${hex(1)}:${hex(1)}:${hex(1)}`.toUpperCase(), status, homeId, claimedBy]
      )).rows[0].id;
    const past = new Date(Date.now() - 3600e3);

    const H1 = await home('H1'); // tek servis, penceresi dolmus
    await member(H1, cust1, 'owner');
    await member(H1, svcA, 'service_user', past, 100);
    const H2 = await home('H2'); // iki servis: en eskisi (svcB) secilir
    await member(H2, cust2, 'owner');
    await member(H2, svcA, 'service_user', null, 10);
    await member(H2, svcB, 'service_user', past, 500);
    const H3 = await home('H3'); // servis uyeligi yok; karti sahiplenen servis (kural 2)
    await member(H3, cust1, 'owner');
    const H4 = await home('H4'); // servisi yok, karti musteri sahiplenmis -> kok
    await member(H4, cust2, 'owner');
    const H5 = await home('H5'); // servis uyeligi var ama kullanici artik 'user' -> sayilmaz -> kok
    await member(H5, cust1, 'owner');
    await member(H5, exSvc, 'service_user', null, 5);

    const C1 = await card('AHBU-M45-C1', 'CLAIMED', { homeId: H1, claimedBy: cust1 });
    const C2 = await card('AHBU-M45-C2', 'IN_STOCK');
    const C3 = await card('AHBU-M45-C3', 'CLAIMED', { homeId: H2, claimedBy: cust2 });
    const C4 = await card('AHBU-M45-C4', 'CLAIMED', { homeId: H4, claimedBy: cust2 });
    const C5 = await card('AHBU-M45-C5', 'REVOKED');
    const C6 = await card('AHBU-M45-C6', 'CLAIMED', { homeId: H3, claimedBy: svcA });

    const site = async (name, createdBy) => (await q('INSERT INTO sites (name, created_by) VALUES ($1, $2) RETURNING id', [name, createdBy])).rows[0].id;
    const S1 = await site('S1', svcA);
    const S2 = await site('S2', root);
    const S3 = await site('S3', null);
    const S4 = await site('S4', cust1);

    // --- dagitim oncesi SALT-OKUNUR onizleme (scripts/service_scope_backfill_preview.sql): 045 oncesi (kolonsuz) calisir ---
    const previewResults = await env.pool.query(SQL_PREVIEW);
    assert.ok(Array.isArray(previewResults) && previewResults.length === 5, 'onizleme 5 sonuc kumesi uretir');
    const previewByHome = new Map(previewResults[0].rows.map((r) => [r.home_id, r.secilecek_servis_eposta]));
    assert.match(previewByHome.get(H1), /^svcA-/);
    assert.match(previewByHome.get(H2), /^svcB-/, 'onizleme de en eski servisi secer');
    assert.match(previewByHome.get(H3), /^svcA-/);
    assert.equal(previewByHome.get(H4), null);
    assert.equal(previewByHome.get(H5), null);
    const multi = previewResults[1].rows.map((r) => r.home_id);
    assert.deepEqual(multi, [H2], 'birden fazla servis adayi olan ev listelenir');
    assert.equal((await q('SELECT COUNT(*)::int AS n FROM users')).rows[0].n, 6, 'onizleme veri degistirmedi');

    // --- 045 ---
    await env.migrate([]);

    const owner = async (table, id) => (await q(`SELECT service_owner_id AS o FROM ${table} WHERE id = $1`, [id])).rows[0].o;
    // onizleme ile gercek geri doldurma AYNI sonucu verir
    for (const [homeId, email] of previewByHome) {
      const o = await owner('homes', homeId);
      const actual = o ? (await q('SELECT email FROM users WHERE id = $1', [o])).rows[0].email : null;
      assert.equal(actual, email, `onizleme == geri doldurma (${homeId})`);
    }
    assert.equal(await owner('homes', H1), svcA, 'H1: tek servis uyesi');
    assert.equal(await owner('homes', H2), svcB, 'H2: en eski servis uyesi (svcB)');
    assert.equal(await owner('homes', H3), svcA, 'H3: kart sahiplenen servis (kural 2)');
    assert.equal(await owner('homes', H4), null, 'H4: kok');
    assert.equal(await owner('homes', H5), null, 'H5: servis uyeligi var ama kullanici artik service_user degil -> kok');
    assert.equal(await owner('device_inventory', C1), svcA, 'kurulu kart evinin servisi');
    assert.equal(await owner('device_inventory', C2), null, 'stoktaki kart kok');
    assert.equal(await owner('device_inventory', C3), svcB);
    assert.equal(await owner('device_inventory', C4), null);
    assert.equal(await owner('device_inventory', C5), null, 'REVOKED kart (evsiz) kok');
    assert.equal(await owner('device_inventory', C6), svcA, 'kural 2 ile servise giden evin karti');
    assert.equal(await owner('sites', S1), svcA, 'created_by servis ise');
    assert.equal(await owner('sites', S2), null, 'created_by kok');
    assert.equal(await owner('sites', S3), null);
    assert.equal(await owner('sites', S4), null, 'created_by musteri');

    // servis sahibinin uyeligi suresiz; uyeligi olmayan servis sahibine acilir
    const m = async (h, u) => (await q('SELECT role, installer_expires_at AS e FROM home_users WHERE home_id = $1 AND user_id = $2', [h, u])).rows[0];
    assert.equal((await m(H1, svcA)).e, null, 'H1: pencere kaldirildi');
    assert.equal((await m(H2, svcB)).e, null, 'H2: svcB penceresi kaldirildi');
    assert.equal((await m(H2, svcA)).role, 'service_user', 'H2: servis olmayan eski uyelik korunur');
    const m3 = await m(H3, svcA);
    assert.deepEqual([m3.role, m3.e], ['service_user', null], 'H3: uyeligi olmayan servis sahibine suresiz uyelik acildi');
    assert.equal(await m(H4, svcA), undefined, 'kok evine uyelik acilmaz');

    // dizinler + FK davranisi: servis hesabi silinirse kapsam koke duser
    const idx = (await q("SELECT indexname FROM pg_indexes WHERE indexname IN ('idx_homes_service_owner','idx_device_inventory_service_owner','idx_sites_service_owner')")).rows;
    assert.equal(idx.length, 3);

    // --- tekrar calistirma (psql): hicbir sey degismez; kok'un NULL biraktigi/aktardigi kayit yeniden atanmaz ---
    await q('UPDATE homes SET service_owner_id = NULL WHERE id = $1', [H1]); // kok H1'i kendi kapsamina aldi
    await q('UPDATE homes SET service_owner_id = $2 WHERE id = $1', [H2, svcA]); // kok H2'yi svcA'ya aktardi
    const snap = async () => JSON.stringify([
      (await q('SELECT id, service_owner_id FROM homes ORDER BY id')).rows,
      (await q('SELECT id, service_owner_id FROM device_inventory ORDER BY id')).rows,
      (await q('SELECT id, service_owner_id FROM sites ORDER BY id')).rows,
      (await q('SELECT home_id, user_id, role, installer_expires_at FROM home_users ORDER BY home_id, user_id')).rows,
    ]);
    const before = await snap();
    const client = await env.pool.connect();
    try {
      await client.query('BEGIN');
      await client.query(SQL_045);
      await client.query('COMMIT');
    } catch (e) {
      await client.query('ROLLBACK').catch(() => {});
      throw e;
    } finally {
      client.release();
    }
    assert.equal(await snap(), before, 'ikinci calistirma no-op (geri doldurma atlanir)');
    assert.equal(await owner('homes', H1), null, 'kok kapsamina alinan ev yeniden atanmadi');
    assert.equal(await owner('homes', H2), svcA, 'aktarilan ev geri alinmadi');

    // ON DELETE SET NULL
    await q('DELETE FROM users WHERE id = $1', [svcA]);
    assert.equal(await owner('homes', H2), null);
    assert.equal(await owner('homes', H3), null);
    assert.equal(await owner('device_inventory', C6), null);
    assert.equal(await owner('sites', S1), null);
    // baska servisin (svcB) karti dokunulmaz
    assert.equal(await owner('device_inventory', C3), svcB);
  } finally {
    await env.close();
  }
});
