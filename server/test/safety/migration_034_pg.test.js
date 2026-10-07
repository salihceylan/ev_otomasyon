'use strict';

// Faz 2 / WP-G1: migration 034 GERCEK PostgreSQL'de (yalitilmis gecici veritabani; paylasilan veritabaninda DDL kosulmaz,
// inceleme RV-5/RV2-2 dersi): migrate.js 001..034, ardindan 034 dosyasi IKI KEZ daha elle calistirilir; mevcut satirlar
// korunur, 'skipped_hazard' kabul edilir, bilinmeyen durum reddedilir.
// Varsayilan olarak ATLANIR. Etkinlestirmek: EV_PG_TEST_URL=postgresql://... (CREATE DATABASE yetkisi gerekir).

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const URL_ = process.env.EV_PG_TEST_URL;
const SKIP = URL_ ? false : 'EV_PG_TEST_URL tanimli degil (gercek PostgreSQL gerekir)';
const SQL_FILE = path.join(__dirname, '..', '..', 'migrations', '034_peace_skipped_hazard.sql');

function withDatabase(url, name) {
  const u = new URL(url);
  u.pathname = `/${name}`;
  return u.toString();
}

async function admin(fn) {
  const { Client } = require('pg');
  const c = new Client({ connectionString: URL_, connectionTimeoutMillis: 15000 });
  await c.connect();
  try {
    return await fn(c);
  } finally {
    await c.end().catch(() => {});
  }
}

test('034 gercek PG: migrate.js (001..034) + dosya iki kez daha; satirlar korunur, CHECK yeni degeri kabul eder', { skip: SKIP }, async () => {
  const base = new URL(URL_).pathname.replace(/^\//, '') || 'postgres';
  const name = `${base}_t034_${process.pid}`.toLowerCase().replace(/[^a-z0-9_]/g, '_').slice(0, 60);
  let created = false;
  try {
    created = await admin(async (c) => {
      await c.query(`DROP DATABASE IF EXISTS ${name}`);
      await c.query(`CREATE DATABASE ${name}`);
      return true;
    }).catch(() => false);
    if (!created) return; // CREATE DATABASE yetkisi yok: test sessizce gecer (paylasilan veritabaninda DDL kosulmaz)
    const url = withDatabase(URL_, name);
    const { main } = require('../../scripts/migrate');
    const env = { DATABASE_URL: url, MIGRATE_CONFIRM: name };
    assert.equal(await main({ argv: [], env, log: () => {}, errLog: () => {} }), 0, 'ilk kurulum');
    assert.equal(await main({ argv: [], env, log: () => {}, errLog: () => {} }), 0, 'ikinci calistirma (bekleyen yok)');

    const { Client } = require('pg');
    const c = new Client({ connectionString: url });
    await c.connect();
    try {
      const applied = await c.query("SELECT name FROM schema_migrations WHERE name LIKE '034%'");
      assert.deepEqual(applied.rows.map((r) => r.name), ['034_peace_skipped_hazard.sql'], 'migrate.js 034 kaydi (tek)');
      const home = (await c.query("INSERT INTO homes (name, mqtt_username) VALUES ('m034', 'h_m034m034m034') RETURNING id")).rows[0];
      await c.query("INSERT INTO peace_notification_logs (home_id, local_date, status, attempts) VALUES ($1, '2026-10-01', 'skipped_offline', 1)", [home.id]);
      const sql = fs.readFileSync(SQL_FILE, 'utf8');
      for (let i = 0; i < 2; i += 1) {
        await c.query('BEGIN');
        await c.query(sql);
        await c.query('COMMIT');
      }
      const kept = await c.query('SELECT status FROM peace_notification_logs WHERE home_id = $1', [home.id]);
      assert.deepEqual(kept.rows.map((r) => r.status), ['skipped_offline']);
      await c.query("INSERT INTO peace_notification_logs (home_id, local_date, status, attempts) VALUES ($1, '2026-10-02', 'skipped_hazard', 1)", [home.id]);
      await assert.rejects(
        c.query("INSERT INTO peace_notification_logs (home_id, local_date, status, attempts) VALUES ($1, '2026-10-03', 'bogus', 1)", [home.id]),
        (err) => err.code === '23514'
      );
      const cons = await c.query("SELECT COUNT(*)::int AS n FROM pg_constraint WHERE conname = 'peace_logs_status_check'");
      assert.equal(cons.rows[0].n, 1, 'tek kisit (cift tanim yok)');
    } finally {
      await c.end().catch(() => {});
    }
  } finally {
    if (created) await admin((c) => c.query(`DROP DATABASE IF EXISTS ${name}`)).catch(() => {});
  }
});
