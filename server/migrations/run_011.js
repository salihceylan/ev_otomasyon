#!/usr/bin/env node
'use strict';
require('dotenv').config({ path: '/home/salihceylan/ev_otomasyon/server/.env' });
const { Pool } = require('pg');
const pool = new Pool({ connectionString: 'postgresql://ev_admin:GudeEvPg2026!SecurePass@127.0.0.1:5434/ev_otomasyon' });

async function run() {
  try {
    // Mevcut tabloyu UUID'e yükselt
    // Önce INTEGER kolonu UUID'e çevir
    const colCheck = await pool.query(
      "SELECT data_type FROM information_schema.columns WHERE table_name='scheduled_rules' AND column_name='home_id'"
    );
    
    if (colCheck.rows.length > 0 && colCheck.rows[0].data_type === 'integer') {
      console.log('home_id INTEGER -> UUID donusumu yapiliyor...');
      await pool.query('ALTER TABLE scheduled_rules ALTER COLUMN home_id TYPE UUID USING NULL');
      await pool.query('ALTER TABLE scheduled_rules ALTER COLUMN device_id TYPE UUID USING NULL');
      await pool.query('ALTER TABLE scheduled_rules ALTER COLUMN created_by TYPE UUID USING NULL');
      console.log('Tip donusumu tamamlandi');
    } else {
      console.log('Tipler zaten dogru veya tablo yok');
    }

    // FK constraint ekle (tekrar dene)
    try {
      await pool.query('ALTER TABLE scheduled_rules ADD CONSTRAINT fk_sr_home FOREIGN KEY (home_id) REFERENCES homes(id) ON DELETE CASCADE');
      console.log('FK home_id eklendi');
    } catch (e) {
      console.log('FK home_id:', e.message.split('\n')[0]);
    }

    try {
      await pool.query('ALTER TABLE scheduled_rules ADD CONSTRAINT fk_sr_device FOREIGN KEY (device_id) REFERENCES devices(id) ON DELETE SET NULL');
      console.log('FK device_id eklendi');
    } catch (e) {
      console.log('FK device_id:', e.message.split('\n')[0]);
    }

    try {
      await pool.query('ALTER TABLE scheduled_rules ADD CONSTRAINT fk_sr_creator FOREIGN KEY (created_by) REFERENCES users(id) ON DELETE CASCADE');
      console.log('FK created_by eklendi');
    } catch (e) {
      console.log('FK created_by:', e.message.split('\n')[0]);
    }

    // Kolon kontrol
    const cols = await pool.query(
      "SELECT column_name, data_type FROM information_schema.columns WHERE table_name='scheduled_rules' ORDER BY ordinal_position"
    );
    console.log('\nScheduled_rules tablosu kolonlari:');
    cols.rows.forEach(c => console.log(' -', c.column_name, ':', c.data_type));
    console.log('\nMigration 011 UUID duzeltmesi tamamlandi!');
  } catch (err) {
    console.error('Hata:', err.message);
    process.exit(1);
  }
  await pool.end();
}
run();

