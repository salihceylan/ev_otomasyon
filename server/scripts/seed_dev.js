#!/usr/bin/env node
'use strict';

// ==============================================================================
// AHBU Akilli Ev - GELISTIRME tohum calistiricisi (WP-C)
// ==============================================================================
//
// migrations/dev_seeds/*.sql dosyalarini calistirir (demo ev, demo cihaz, demo super kullanici).
// URETIMDE CALISMAZ ve sabit sir icermez: parola/PIN ortamdan gelir.
//
// KULLANIM (server/ dizininden):
//   ALLOW_DEV_SEEDS=true DEV_SEED_PASSWORD='<en az 10 karakter>' DEV_SEED_PIN=<6 hane> \
//   MIGRATE_CONFIRM=<veritabani_adi> node scripts/seed_dev.js
//
// Gerekenler
//   - NODE_ENV production OLMAMALI, ALLOW_DEV_SEEDS=true, MIGRATE_CONFIRM=<veritabani_adi>
//   - Once `scripts/migrate.js` ile TUM migration'lar uygulanmis olmali (bekleyen varsa durur)
// Opsiyonel: DEV_SEED_OWNER_EMAIL, DEV_SEED_SUPER_EMAIL (varsayilan: *@example.invalid), PIN_PEPPER
//   (varsa PIN ozeti HMAC'lenir; yoksa eski SHA-256 bicimi - gelistirme icin yeterli).
//
// Tohumlar `ON CONFLICT DO NOTHING` kullanir: mevcut satirlara DOKUNMAZ, yeniden calistirmak guvenlidir.

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { parseDatabaseUrl, describeTarget, assertConfirmed, requireSecretEnv, TargetError } = require('./lib/target');
const { listMigrationFiles } = require('./migrate');

const SEEDS_DIR = path.join(__dirname, '..', 'migrations', 'dev_seeds');
const EMAIL_RE = /^[A-Za-z0-9._%+-]{1,64}@[A-Za-z0-9.-]{1,190}$/;
const TOKEN_RE = /\{\{([A-Z0-9_]+)\}\}/g;

/** Gelistirme tohumuna izin var mi? Aksi halde TargetError. */
function assertDevSeedAllowed(env) {
  if (String(env.NODE_ENV || '').toLowerCase() === 'production') {
    throw new TargetError('Gelistirme tohumlari URETIMDE calistirilmaz (NODE_ENV=production).', 'PRODUCTION');
  }
  if (env.ALLOW_DEV_SEEDS !== 'true') {
    throw new TargetError('Gelistirme tohumu icin ALLOW_DEV_SEEDS=true gerekli (bilincli onay).', 'NOT_ALLOWED');
  }
  const target = parseDatabaseUrl(env.DATABASE_URL);
  assertConfirmed(env, target);
  return target;
}

function pickEmail(env, name, fallback) {
  const v = env[name] || fallback;
  if (!EMAIL_RE.test(v)) throw new TargetError(`${name} gecerli bir e-posta degil.`, 'BAD_ENV');
  return v.toLowerCase();
}

/** Ortamdan yer tutucu degerlerini uretir. PAROLA ve PIN log'a yazilmaz. */
function buildTokens(env, { bcrypt, pinLib } = {}) {
  const password = requireSecretEnv(env, 'DEV_SEED_PASSWORD', { minLength: 10, hint: 'Gelistirme demo hesaplari icin parola belirleyin.' });
  const pin = requireSecretEnv(env, 'DEV_SEED_PIN', { pattern: /^\d{6}$/, hint: '6 haneli rakam.' });
  const bc = bcrypt || require('bcryptjs');
  const passwordHash = bc.hashSync(password, 12);

  let pinHash;
  if (env.PIN_PEPPER && String(env.PIN_PEPPER).length >= 32) {
    const lib = pinLib || require('../src/utils/pin');
    pinHash = lib.hashPin(pin);
  } else {
    pinHash = crypto.createHash('sha256').update(pin, 'utf8').digest('hex'); // eski bicim (dogrulanir, yukseltilir)
  }
  return {
    DEV_PASSWORD_HASH: passwordHash,
    DEV_PIN_HASH: pinHash,
    DEV_OWNER_EMAIL: pickEmail(env, 'DEV_SEED_OWNER_EMAIL', 'dev.owner@example.invalid'),
    DEV_SUPER_EMAIL: pickEmail(env, 'DEV_SEED_SUPER_EMAIL', 'dev.super@example.invalid'),
  };
}

/** {{ADI}} yer tutucularini tirnak kacisli degerlerle doldurur; bilinmeyen yer tutucu hata verir. */
function renderSeed(sql, tokens) {
  const unknown = new Set();
  const out = String(sql).replace(TOKEN_RE, (match, name) => {
    if (!Object.prototype.hasOwnProperty.call(tokens, name)) {
      unknown.add(name);
      return match;
    }
    return String(tokens[name]).replace(/'/g, "''");
  });
  if (unknown.size > 0) {
    throw new TargetError(`Bilinmeyen tohum yer tutucusu: ${[...unknown].join(', ')}`, 'BAD_SEED');
  }
  return out;
}

function listSeedFiles(dir = SEEDS_DIR, fsApi = fs) {
  return fsApi
    .readdirSync(dir, { withFileTypes: true })
    .filter((e) => e.isFile() && /\.sql$/i.test(e.name))
    .map((e) => e.name)
    .sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));
}

async function main(deps = {}) {
  const env = deps.env || process.env;
  const log = deps.log || ((...a) => console.log(...a));
  const errLog = deps.errLog || ((...a) => console.error(...a));
  const fsApi = deps.fsApi || fs;

  let target;
  let tokens;
  try {
    target = assertDevSeedAllowed(env);
    tokens = buildTokens(env, deps);
  } catch (err) {
    errLog(`HATA: ${err.message}`);
    return 2;
  }
  log(`Hedef: ${describeTarget(target)}  [GELISTIRME TOHUMU]`);

  const seedDir = deps.seedsDir || SEEDS_DIR;
  const seeds = listSeedFiles(seedDir, fsApi);
  const Client = deps.Client || require('pg').Client;
  const client = new Client({ connectionString: env.DATABASE_URL, application_name: 'ev_seed_dev', connectionTimeoutMillis: 10000 });

  try {
    await client.connect();
    // Bekleyen migration varsa tohum sema uyumsuz olabilir.
    const t = await client.query("SELECT to_regclass('public.schema_migrations') AS t");
    if (!t.rows[0] || !t.rows[0].t) {
      errLog('HATA: schema_migrations yok. Once `node scripts/migrate.js` ile migration\'lari uygulayin.');
      return 1;
    }
    const applied = await client.query('SELECT name FROM schema_migrations');
    const appliedNames = new Set(applied.rows.map((r) => r.name));
    const pending = listMigrationFiles(deps.migrationsDir || path.join(__dirname, '..', 'migrations'), fsApi).filter((f) => !appliedNames.has(f.name));
    if (pending.length > 0) {
      errLog(`HATA: ${pending.length} bekleyen migration var (${pending.map((p) => p.name).join(', ')}). Once migrate calistirin.`);
      return 1;
    }

    await client.query('BEGIN');
    try {
      for (const name of seeds) {
        const sql = renderSeed(fsApi.readFileSync(path.join(seedDir, name), 'utf8'), tokens);
        log(`Tohum: ${name}`);
        await client.query(sql);
      }
      await client.query('COMMIT');
    } catch (err) {
      await client.query('ROLLBACK').catch(() => {});
      throw err;
    }
    log('Gelistirme tohumlari tamam (parola/PIN ortamdan; yazdirilmadi).');
    return 0;
  } catch (err) {
    errLog(`HATA: ${err.message}`);
    return 1;
  } finally {
    try {
      await client.end();
    } catch (_) {
      /* yut */
    }
  }
}

module.exports = { main, assertDevSeedAllowed, buildTokens, renderSeed, listSeedFiles, SEEDS_DIR };

if (require.main === module) {
  try {
    require('dotenv').config({ path: path.join(__dirname, '..', '.env') });
  } catch (_) {
    /* yut */
  }
  main().then(
    (code) => process.exit(code),
    (err) => {
      console.error(`HATA: ${err && err.message ? err.message : err}`);
      process.exit(1);
    }
  );
}
