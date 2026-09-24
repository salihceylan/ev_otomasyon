#!/usr/bin/env node
'use strict';
const fs = require('fs');
require('dotenv').config({ path: '/home/salihceylan/ev_otomasyon/server/.env' });
const { Pool } = require('pg');

const pool = new Pool({
  connectionString: process.env.DATABASE_URL || 'postgresql://ev_admin:GudeEvPg2026!SecurePass@127.0.0.1:5434/ev_otomasyon',
});

async function run() {
  const sql = fs.readFileSync('/home/salihceylan/ev_otomasyon/server/migrations/013_password_reset.sql', 'utf8');
  try {
    await pool.query(sql);
    console.log('Migration 013 basariyla uygulandi');
  } catch (err) {
    console.error('Migration 013 hatasi:', err.message);
    process.exit(1);
  }
  await pool.end();
}
run();

