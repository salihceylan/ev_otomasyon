'use strict';

// Yasal metin PG testleri icin YALITILMIS gecici veritabani (test/templates/_pg_isolated.js ile ayni kural: paylasilan
// veritabaninda DDL kosulmaz): CREATE DATABASE -> scripts/migrate.js (istege bagli --to NNN) -> test -> DROP.
// `to` verilirse zincir o migration'da durur (ornegin '038': 039 oncesi dayaniklilik). EV_PG_TEST_URL yoksa testler
// ATLANIR; CREATE DATABASE yetkisi yoksa `openDatabase()` null doner.
// Bu dosya `*.test.js` olmadigi icin test olarak calismaz.

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

async function migrate(url, name, argv = []) {
  const { main } = require('../../scripts/migrate');
  const rc = await main({ argv, env: { DATABASE_URL: url, MIGRATE_CONFIRM: name }, log: () => {}, errLog: () => {} });
  if (rc !== 0) throw new Error(`migrate.js cikis ${rc}`);
}

/**
 * @param {string} tag  veritabani adi eki (kucuk harf/rakam)
 * @param {{to?:string}} [opts]
 * @returns {Promise<null | {name:string, url:string, migrate:(argv?:string[])=>Promise<void>, drop:()=>Promise<void>}>}
 */
async function openDatabase(tag, { to } = {}) {
  const base = new URL(PG_URL).pathname.replace(/^\//, '') || 'postgres';
  const name = `${base}_${tag}_${process.pid}`.toLowerCase().replace(/[^a-z0-9_]/g, '_').slice(0, 60);
  const created = await admin(async (c) => {
    await c.query(`DROP DATABASE IF EXISTS ${name}`);
    await c.query(`CREATE DATABASE ${name}`);
    return true;
  }).catch(() => false);
  if (!created) return null;
  const url = withDatabase(PG_URL, name);
  await migrate(url, name, to ? ['--to', String(to)] : []);
  return {
    name,
    url,
    migrate: (argv = []) => migrate(url, name, argv),
    // Testin havuzu kapatilmis olmali; yine de acik kalan baglanti DROP'u engellemesin (PG 13+: WITH (FORCE)).
    drop: () => admin((c) => c.query(`DROP DATABASE IF EXISTS ${name} WITH (FORCE)`)).catch(() => {}),
  };
}

/**
 * src/db.js'i (DATABASE_URL'i modul yuklenirken okur) verilen veritabanina baglamak icin ortam. dotenv yalniz TANIMSIZ
 * anahtarlari yukler: yerel .env'deki olasi canli degerler BOS dizgeyle sabitlenir.
 */
function setAppEnv(url) {
  const crypto = require('node:crypto');
  process.env.DATABASE_URL = url;
  process.env.NODE_ENV = 'test';
  process.env.BCRYPT_TEST_COST = '4';
  process.env.AUTH_CACHE_TTL_MS = '0';
  process.env.JWT_SECRET = crypto.randomBytes(32).toString('hex');
  process.env.PIN_PEPPER = crypto.randomBytes(32).toString('hex');
  process.env.LOCAL_KEY_SECRET = crypto.randomBytes(32).toString('hex');
  process.env.MQTT_PUBLIC_HOST = 'broker.test.invalid';
  process.env.MQTT_PUBLIC_PORT = '8884';
  for (const k of ['EMQX_API_URL', 'EMQX_API_KEY', 'EMQX_API_SECRET', 'ALLOW_DEBUG_OTP', 'ADMIN_API_KEY', 'SMTP_HOST', 'SMTP_USER', 'SMTP_PASSWORD', 'GOOGLE_CLIENT_IDS', 'APPLE_CLIENT_IDS', 'MQTT_BACKEND_USER', 'MQTT_BACKEND_PASS', 'CORS_ORIGINS']) {
    process.env[k] = '';
  }
}

const fakeBridge = { isConnected: () => true, init() {}, end: async () => {}, publishCommand: async () => ({}), publishSys: async () => ({}), clearRetained: async () => {} };
const fakePush = { upsertToken: async () => {}, disableToken: async () => {}, disableAllTokensForUser: async () => 0 };

module.exports = { PG_URL, PG_SKIP, openDatabase, setAppEnv, fakeBridge, fakePush };
