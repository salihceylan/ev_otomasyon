'use strict';

// Faz 1 PG testleri icin YALITILMIS gecici veritabani: CREATE DATABASE -> migrate.js (001..035) -> test -> DROP.
// Paylasilan veritabaninda DDL kosulmaz (inceleme RV-5/RV2-2 dersi). EV_PG_TEST_URL yoksa testler ATLANIR;
// CREATE DATABASE yetkisi yoksa `open()` null doner (test sessizce gecer).

const PG_URL = process.env.EV_PG_TEST_URL;
const PG_SKIP = PG_URL ? false : 'EV_PG_TEST_URL tanimli degil (gercek PostgreSQL gerekir)';

function withDatabase(url, name) {
  const u = new URL(url);
  u.pathname = `/${name}`;
  return u.toString();
}

async function admin(fn) {
  const { Client } = require('pg');
  const c = new Client({ connectionString: PG_URL, connectionTimeoutMillis: 15000 });
  await c.connect();
  try {
    return await fn(c);
  } finally {
    await c.end().catch(() => {});
  }
}

/** @returns {Promise<null | {db, pool, url, close: Function}>} */
async function open(tag) {
  const base = new URL(PG_URL).pathname.replace(/^\//, '') || 'postgres';
  const name = `${base}_${tag}_${process.pid}`.toLowerCase().replace(/[^a-z0-9_]/g, '_').slice(0, 60);
  const created = await admin(async (c) => {
    await c.query(`DROP DATABASE IF EXISTS ${name}`);
    await c.query(`CREATE DATABASE ${name}`);
    return true;
  }).catch(() => false);
  if (!created) return null;
  const url = withDatabase(PG_URL, name);
  const { main } = require('../../scripts/migrate');
  const rc = await main({ argv: [], env: { DATABASE_URL: url, MIGRATE_CONFIRM: name }, log: () => {}, errLog: () => {} });
  if (rc !== 0) throw new Error(`migrate.js cikis ${rc}`);
  const { Pool } = require('pg');
  const pool = new Pool({ connectionString: url, max: 8 });
  pool.on('error', () => {});
  const db = {
    query: (text, params) => pool.query(text, params),
    async withTransaction(fn) {
      const client = await pool.connect();
      try {
        await client.query('BEGIN');
        const result = await fn({ query: (text, params) => client.query(text, params) });
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
  return {
    db,
    pool,
    url,
    async close() {
      await pool.end().catch(() => {});
      await admin((c) => c.query(`DROP DATABASE IF EXISTS ${name}`)).catch(() => {});
    },
  };
}

module.exports = { PG_URL, PG_SKIP, open };
