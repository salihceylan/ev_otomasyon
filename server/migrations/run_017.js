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
  const sql = fs.readFileSync(path.join(__dirname, '017_device_claim_otp.sql'), 'utf8');
  try {
    await pool.query(sql);
    console.log('✅ Migration 017 (device_claim_otp) basariyla uygulandi');
  } catch (err) {
    console.error('❌ Migration 017 hatasi:', err.message);
    process.exit(1);
  } finally {
    await pool.end();
  }
}
run();
