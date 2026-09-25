'use strict';
const bcrypt = require('bcryptjs');
const { Pool } = require('pg');

const pool = new Pool({
  connectionString: process.env.DATABASE_URL || 'postgresql://ev_admin:GudeEvPg2026!SecurePass@127.0.0.1:5434/ev_otomasyon',
});

async function seedTestUsers() {
  try {
    const salt = await bcrypt.genSalt(10);
    const adminPass = await bcrypt.hash('GudeAdmin2026!', salt);
    const memberPass = await bcrypt.hash('GudeSakin2026!', salt);
    const installerPass = await bcrypt.hash('GudeServis2026!', salt);

    // Ev ID'sini al
    const homeRes = await pool.query("SELECT id FROM homes WHERE mqtt_username = 'home_101' LIMIT 1");
    if (homeRes.rows.length === 0) {
      console.error('home_101 evi bulunamadi!');
      process.exit(1);
    }
    const homeId = homeRes.rows[0].id;

    // 1. Daire Admini (Owner)
    await pool.query(`
      INSERT INTO users (email, phone, full_name, password_hash, is_active)
      VALUES ('admin@ahbu.com', '+905551112233', 'Ahmet Demir (Daire Admini)', $1, TRUE)
      ON CONFLICT (email) DO UPDATE SET password_hash = $1, full_name = 'Ahmet Demir (Daire Admini)', is_active = TRUE
    `, [adminPass]);

    const adminUser = (await pool.query("SELECT id FROM users WHERE email = 'admin@ahbu.com'")).rows[0];
    await pool.query(`
      INSERT INTO home_users (home_id, user_id, role)
      VALUES ($1, $2, 'owner')
      ON CONFLICT (home_id, user_id) DO UPDATE SET role = 'owner'
    `, [homeId, adminUser.id]);

    // Ayrıca salih@gudeteknoloji.com.tr kullanıcısının da şifresini teyit et
    await pool.query(`
      UPDATE users SET password_hash = $1 WHERE email = 'salih@gudeteknoloji.com.tr'
    `, [adminPass]);

    // 2. Daire Kullanıcısı (Resident / Aile Bireyi)
    await pool.query(`
      INSERT INTO users (email, phone, full_name, password_hash, is_active)
      VALUES ('sakin@ahbu.com', '+905552223344', 'Ayşe Demir (Daire Sakini)', $1, TRUE)
      ON CONFLICT (email) DO UPDATE SET password_hash = $1, full_name = 'Ayşe Demir (Daire Sakini)', is_active = TRUE
    `, [memberPass]);

    const memberUser = (await pool.query("SELECT id FROM users WHERE email = 'sakin@ahbu.com'")).rows[0];
    await pool.query(`
      INSERT INTO home_users (home_id, user_id, role)
      VALUES ($1, $2, 'resident')
      ON CONFLICT (home_id, user_id) DO UPDATE SET role = 'resident'
    `, [homeId, memberUser.id]);

    // 3. Saha & Servis Sorumlusu (Service User)
    await pool.query(`
      INSERT INTO users (email, phone, full_name, password_hash, role, is_active)
      VALUES ('servis@ahbu.com', '+905553334455', 'Murat Usta (Servis Sorumlusu)', $1, 'service_user', TRUE)
      ON CONFLICT (email) DO UPDATE SET password_hash = $1, full_name = 'Murat Usta (Servis Sorumlusu)', role = 'service_user', is_active = TRUE
    `, [installerPass]);

    const serviceUser = (await pool.query("SELECT id FROM users WHERE email = 'servis@ahbu.com'")).rows[0];
    await pool.query(`
      INSERT INTO home_users (home_id, user_id, role)
      VALUES ($1, $2, 'service_user')
      ON CONFLICT (home_id, user_id) DO UPDATE SET role = 'service_user'
    `, [homeId, serviceUser.id]);

    console.log('✅ Demo kullanicilari basariyla olusturuldu / guncellendi!');
  } catch (err) {
    console.error('Hata:', err.message);
  } finally {
    await pool.end();
  }
}

seedTestUsers();
