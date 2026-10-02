#!/usr/bin/env node
'use strict';

// ==============================================================================
// DEV ARACI: kullanici / ev uyeligi listesi   (YALNIZCA GELISTIRME)
// ==============================================================================
// Eski migrations/list_demo_users.js buraya tasindi (WP-C, denetim 2026-10-01): sabit baglanti
// dizesi (parola dahil) KALDIRILDI; yalnizca DATABASE_URL okunur. Parola ozetlerini YAZDIRMAZ.
// URETIMDE CALISMAZ.
//
// KULLANIM (server/ dizininden):
//   ALLOW_DEV_SEEDS=true MIGRATE_CONFIRM=<db> node migrations/dev_seeds/list_demo_users.js

const path = require('path');
const { Pool } = require('pg');
const { parseDatabaseUrl, describeTarget, assertConfirmed, TargetError } = require(path.join(__dirname, '..', '..', 'scripts', 'lib', 'target'));

async function run() {
  const env = process.env;
  if (String(env.NODE_ENV || '').toLowerCase() === 'production') {
    throw new TargetError('Gelistirme araci URETIMDE calistirilmaz.', 'PRODUCTION');
  }
  if (env.ALLOW_DEV_SEEDS !== 'true') {
    throw new TargetError('ALLOW_DEV_SEEDS=true gerekli.', 'NOT_ALLOWED');
  }
  const target = parseDatabaseUrl(env.DATABASE_URL);
  assertConfirmed(env, target);
  console.log(`Hedef: ${describeTarget(target)}  [GELISTIRME]`);

  const pool = new Pool({ connectionString: env.DATABASE_URL });
  try {
    const res = await pool.query(`
      SELECT u.id, u.email, u.full_name, u.role AS global_role, hu.role AS home_role, h.name AS home_name
        FROM users u
        LEFT JOIN home_users hu ON u.id = hu.user_id
        LEFT JOIN homes h ON hu.home_id = h.id
       ORDER BY u.created_at ASC
    `);
    console.log(JSON.stringify(res.rows, null, 2));
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
