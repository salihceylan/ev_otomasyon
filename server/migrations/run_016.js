#!/usr/bin/env node
'use strict';
const fs = require('fs');
const path = require('path');
require('dotenv').config({ path: path.join(__dirname, '../.env') });
const { Pool } = require('pg');

const pool = new Pool({
  connectionString: process.env.DATABASE_URL || 'postgresql://ev_admin:GudeEvPg2026!SecurePass@127.0.0.1:5434/ev_otomasyon',
});

async function run() {
  const sqlFile = path.join(__dirname, '016_remove_installer_role.sql');
  const sql = fs.readFileSync(sqlFile, 'utf8');
  try {
    console.log('Migration 016 baslatiliyor: Teknisyenler siliniyor...');
    await pool.query(sql);
    console.log('Migration 016 basariyla uygulandi: Tum teknisyen kullanicilar silindi ve rol kisitlamasi guncellendi.');
  } catch (err) {
    console.error('Migration 016 hatasi:', err.message);
    process.exit(1);
  }
  await pool.end();
}
run();
