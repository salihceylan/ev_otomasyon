#!/usr/bin/env node
'use strict';

// ==============================================================================
// AHBU Akilli Ev - Legacy MQTT kimligini bcrypt'e YUKSELTME (WP-C)
// ==============================================================================
//
// Gecis donemi araci. EMQX tek PostgreSQL authenticator'i bcrypt dogrular (emqx_config/emqx.conf);
// eski paylasilan SHA-256 ozetli `mqtt_users` satirlari bu yuzden KABUL EDILMEZ. Sahadaki eski
// firmware'in gomulu kimligini gecis suresince calisir tutmak icin satirin ozeti, GERCEK parola
// dogrulanarak bcrypt'e cevrilir. Parola YALNIZCA ortamdan okunur; repoda/log'da YOKTUR.
//
// KULLANIM (server/ dizininden):
//   LEGACY_MQTT_USER=home_101 LEGACY_MQTT_PASS='<eski kimligin parolasi>' \
//   MIGRATE_CONFIRM=<veritabani_adi> node scripts/upgrade_legacy_mqtt_user.js
//
//   - Satir yoksa, superuser ise (legacy superuser KABUL EDILMEZ; backend icin
//     create_backend_mqtt_user.js) veya parola eslesmiyorsa HICBIR SEY DEGISMEZ.
//   - Zaten bcrypt ise (parola dogruysa) "yukseltilmis" der ve cikar.

const path = require('path');
const crypto = require('crypto');
const { parseDatabaseUrl, describeTarget, assertConfirmed, requireSecretEnv, TargetError } = require('./lib/target');

const USER_RE = /^[A-Za-z0-9_.-]{3,64}$/;
const BCRYPT_RE = /^\$2[aby]\$\d{2}\$/;

function sha256Hex(value) {
  return crypto.createHash('sha256').update(String(value), 'utf8').digest('hex');
}

function safeEqualHex(a, b) {
  const ba = Buffer.from(String(a), 'utf8');
  const bb = Buffer.from(String(b), 'utf8');
  if (ba.length !== bb.length) {
    crypto.timingSafeEqual(ba, ba);
    return false;
  }
  return crypto.timingSafeEqual(ba, bb);
}

async function main(deps = {}) {
  const env = deps.env || process.env;
  const log = deps.log || ((...a) => console.log(...a));
  const errLog = deps.errLog || ((...a) => console.error(...a));

  let target;
  let username;
  let password;
  try {
    target = parseDatabaseUrl(env.DATABASE_URL);
    assertConfirmed(env, target);
    username = String(env.LEGACY_MQTT_USER || '');
    if (!USER_RE.test(username)) {
      throw new TargetError('LEGACY_MQTT_USER gecerli bir kullanici adi degil.', 'BAD_ENV');
    }
    password = requireSecretEnv(env, 'LEGACY_MQTT_PASS', { minLength: 1 });
  } catch (err) {
    errLog(`HATA: ${err.message}`);
    return 2;
  }
  log(`Hedef: ${describeTarget(target)}`);

  const bcrypt = deps.bcrypt || require('bcryptjs');
  const Client = deps.Client || require('pg').Client;
  const client = new Client({ connectionString: env.DATABASE_URL, application_name: 'ev_upgrade_legacy_mqtt', connectionTimeoutMillis: 10000 });
  try {
    await client.connect();
    const res = await client.query('SELECT password_hash, is_superuser FROM mqtt_users WHERE username = $1', [username]);
    if (res.rows.length === 0) {
      errLog(`HATA: "${username}" mqtt_users tablosunda yok.`);
      return 1;
    }
    const row = res.rows[0];
    if (row.is_superuser === true) {
      errLog('HATA: Legacy superuser yukseltilmez/kabul edilmez. Backend icin scripts/create_backend_mqtt_user.js kullanin.');
      return 1;
    }

    const stored = String(row.password_hash || '');
    if (BCRYPT_RE.test(stored)) {
      if (bcrypt.compareSync(password, stored)) {
        log(`"${username}" zaten bcrypt'e yukseltilmis (parola dogru).`);
        return 0;
      }
      errLog('HATA: Parola eslesmiyor; degisiklik yapilmadi.');
      return 1;
    }
    if (!safeEqualHex(sha256Hex(password), stored.toLowerCase())) {
      errLog('HATA: Parola eslesmiyor; degisiklik yapilmadi.');
      return 1;
    }

    const upgraded = bcrypt.hashSync(password, 12);
    // Yalnizca ozet hala eskiyse (yaris durumunda baska bir calistirma yazmis olabilir) guncelle.
    const up = await client.query(
      'UPDATE mqtt_users SET password_hash = $2 WHERE username = $1 AND password_hash = $3',
      [username, upgraded, row.password_hash]
    );
    if (up.rowCount !== 1) {
      errLog('HATA: Satir bu arada degisti; yeniden calistirin.');
      return 1;
    }
    log(`"${username}" bcrypt'e yukseltildi (parola degismedi; eski firmware ayni parolayla baglanmaya devam eder).`);
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

module.exports = { main, sha256Hex, safeEqualHex, USER_RE, BCRYPT_RE };

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
