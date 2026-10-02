#!/usr/bin/env node
'use strict';

// ==============================================================================
// DEV SEED: demo kullanicilar (ev sahibi / sakin / servis personeli)   (YALNIZCA GELISTIRME)
// ==============================================================================
// Eski migrations/seed_demo_credentials.js buraya tasindi ve duzeltildi (WP-C, denetim 2026-10-01):
//   - SABIT PAROLALAR ve sabit baglanti dizesi KALDIRILDI: parola DEV_SEED_PASSWORD ortamindan gelir.
//   - Gercek/olasi gercek e-posta alanlari yerine *.example.invalid kullanilir.
//   - Mevcut kullanicinin parolasini EZMEZ (ON CONFLICT DO NOTHING).
//   - Kaldirilmis 'installer' rolu yerine kalici servis personeli: global rol `service_user` +
//     home_users rolu `service_user`.
// URETIMDE CALISMAZ (NODE_ENV=production reddedilir; ALLOW_DEV_SEEDS=true ve MIGRATE_CONFIRM gerekir).
//
// KULLANIM (server/ dizininden; once `node scripts/seed_dev.js` ile demo ev olusmus olmali):
//   ALLOW_DEV_SEEDS=true DEV_SEED_PASSWORD='...' DEV_SEED_PIN=123456 MIGRATE_CONFIRM=<db> \
//   node migrations/dev_seeds/seed_demo_credentials.js
// (DEV_SEED_PIN burada kullanilmaz ama ortak dogrulama icin tanimli olmalidir.)

const path = require('path');
const { Pool } = require('pg');
const { assertDevSeedAllowed, buildTokens } = require(path.join(__dirname, '..', '..', 'scripts', 'seed_dev'));

const DEMO_HOME_TOPIC = 'h_0000000000000101'; // dev_seeds/002_demo_home.sql

async function run() {
  const env = process.env;
  assertDevSeedAllowed(env);
  const tokens = buildTokens(env);
  const passwordHash = tokens.DEV_PASSWORD_HASH;

  const pool = new Pool({ connectionString: env.DATABASE_URL });
  try {
    const home = await pool.query('SELECT id FROM homes WHERE mqtt_username = $1 LIMIT 1', [DEMO_HOME_TOPIC]);
    if (home.rows.length === 0) {
      throw new Error('Demo ev bulunamadi. Once `node scripts/seed_dev.js` calistirin.');
    }
    const homeId = home.rows[0].id;

    const people = [
      { email: 'dev.admin@example.invalid', name: 'Dev Daire Admini', globalRole: 'user', homeRole: 'owner' },
      { email: 'dev.sakin@example.invalid', name: 'Dev Daire Sakini', globalRole: 'user', homeRole: 'resident' },
      { email: 'dev.servis@example.invalid', name: 'Dev Yetkili Servis', globalRole: 'service_user', homeRole: 'service_user' },
    ];
    for (const p of people) {
      await pool.query(
        `INSERT INTO users (email, full_name, password_hash, role, is_active)
         VALUES ($1, $2, $3, $4, TRUE)
         ON CONFLICT (email) DO NOTHING`,
        [p.email, p.name, passwordHash, p.globalRole]
      );
      const u = await pool.query('SELECT id FROM users WHERE email = $1', [p.email]);
      await pool.query(
        `INSERT INTO home_users (home_id, user_id, role) VALUES ($1, $2, $3)
         ON CONFLICT (home_id, user_id) DO NOTHING`,
        [homeId, u.rows[0].id, p.homeRole]
      );
    }
    console.log('Demo kullanicilar olusturuldu (parola DEV_SEED_PASSWORD; yazdirilmadi).');
  } finally {
    await pool.end();
  }
}

if (require.main === module) {
  try {
    require('dotenv').config({ path: path.join(__dirname, '..', '..', '.env') });
  } catch (_) {
    /* yut */
  }
  run().catch((err) => {
    console.error(`HATA: ${err.message}`);
    process.exit(1);
  });
}

module.exports = { run };
