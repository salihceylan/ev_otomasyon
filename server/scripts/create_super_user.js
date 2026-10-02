#!/usr/bin/env node
'use strict';

// ==============================================================================
// AHBU Akilli Ev - Ilk super kullanici olusturma (WP-C)
// ==============================================================================
//
// Neden: migrations/014 icindeki "ilk super kullanici" tohumu (sabit parola ozetli, gercek bir
// hesabi yonetici yapan) KALDIRILDI. Temiz bir kurulumda ilk yonetici bu betikle, parola
// ORTAMDAN verilerek olusturulur. Parola log'a/ekrana yazilmaz.
//
// KULLANIM (server/ dizininden):
//   SUPER_USER_EMAIL=yonetici@ornek.com SUPER_USER_PASSWORD='<en az 12 karakter>' \
//   MIGRATE_CONFIRM=<veritabani_adi> node scripts/create_super_user.js
//
//   Secenekler (kullanici ZATEN varsa):
//     --promote         mevcut kullaniciyi super_user yapar ve aktiflestirir (parolaya dokunmaz)
//     --reset-password  parolayi SUPER_USER_PASSWORD ile degistirir ve tum oturumlari dusurur
//   Secenek yoksa mevcut kullaniciya DOKUNULMAZ.
//
// Opsiyonel: SUPER_USER_NAME (varsayilan "Sistem Yoneticisi")

const path = require('path');
const { parseDatabaseUrl, describeTarget, assertConfirmed, requireSecretEnv, TargetError } = require('./lib/target');

const EMAIL_RE = /^[A-Za-z0-9._%+-]{1,64}@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$/;

function parseArgs(argv) {
  const o = { promote: false, resetPassword: false, errors: [] };
  for (const a of argv) {
    if (a === '--promote') o.promote = true;
    else if (a === '--reset-password') o.resetPassword = true;
    else o.errors.push(`Bilinmeyen secenek: ${a}`);
  }
  return o;
}

async function main(deps = {}) {
  const env = deps.env || process.env;
  const argv = deps.argv || process.argv.slice(2);
  const log = deps.log || ((...a) => console.log(...a));
  const errLog = deps.errLog || ((...a) => console.error(...a));

  const opts = parseArgs(argv);
  if (opts.errors.length > 0) {
    opts.errors.forEach((e) => errLog(`HATA: ${e}`));
    return 2;
  }

  let target;
  let email;
  let password;
  let fullName;
  try {
    target = parseDatabaseUrl(env.DATABASE_URL);
    assertConfirmed(env, target);
    email = String(requireSecretEnv(env, 'SUPER_USER_EMAIL', { pattern: EMAIL_RE })).trim().toLowerCase();
    password = requireSecretEnv(env, 'SUPER_USER_PASSWORD', { minLength: 12, hint: 'En az 12 karakter.' });
    fullName = String(env.SUPER_USER_NAME || 'Sistem Yoneticisi').trim().slice(0, 100) || 'Sistem Yoneticisi';
  } catch (err) {
    errLog(`HATA: ${err.message}`);
    return err instanceof TargetError ? 2 : 1;
  }
  log(`Hedef: ${describeTarget(target)}`);

  const bcrypt = deps.bcrypt || require('bcryptjs');
  const Client = deps.Client || require('pg').Client;
  const client = new Client({ connectionString: env.DATABASE_URL, application_name: 'ev_create_super_user', connectionTimeoutMillis: 10000 });
  try {
    await client.connect();
    const hash = bcrypt.hashSync(password, 12);

    await client.query('BEGIN');
    try {
      const ins = await client.query(
        `INSERT INTO users (email, password_hash, full_name, role, is_active)
         VALUES ($1, $2, $3, 'super_user', TRUE)
         ON CONFLICT (email) DO NOTHING
         RETURNING id`,
        [email, hash, fullName]
      );
      if (ins.rows.length > 0) {
        await client.query('COMMIT');
        log(`Super kullanici olusturuldu: ${email}`);
        return 0;
      }

      // Kullanici zaten var.
      if (!opts.promote && !opts.resetPassword) {
        await client.query('ROLLBACK');
        log(`Kullanici zaten var: ${email}. Degisiklik yapilmadi (--promote / --reset-password ile degistirilebilir).`);
        return 0;
      }
      if (opts.promote) {
        await client.query("UPDATE users SET role = 'super_user', is_active = TRUE WHERE email = $1", [email]);
        log(`Kullanici super_user yapildi ve aktiflestirildi: ${email}`);
      }
      if (opts.resetPassword) {
        // token_version artisi eski access/refresh oturumlarini dusurur.
        await client.query('UPDATE users SET password_hash = $2, token_version = token_version + 1 WHERE email = $1', [email, hash]);
        log(`Parola degistirildi ve oturumlar dusuruldu: ${email}`);
      }
      await client.query('COMMIT');
      return 0;
    } catch (err) {
      await client.query('ROLLBACK').catch(() => {});
      throw err;
    }
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

module.exports = { main, parseArgs, EMAIL_RE };

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
