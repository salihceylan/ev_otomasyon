'use strict';
const { Pool } = require('pg');
const pool = new Pool({
  connectionString: process.env.DATABASE_URL || 'postgresql://ev_admin:GudeEvPg2026!SecurePass@127.0.0.1:5434/ev_otomasyon',
});

async function run() {
  try {
    const res = await pool.query(`
      SELECT 
        u.id, 
        u.email, 
        u.phone, 
        u.full_name, 
        u.role as user_role,
        hu.role as home_role, 
        h.name as home_name
      FROM users u
      LEFT JOIN home_users hu ON u.id = hu.user_id
      LEFT JOIN homes h ON hu.home_id = h.id
      ORDER BY u.created_at ASC
    `);
    console.log(JSON.stringify(res.rows, null, 2));
  } catch (e) {
    console.error(e);
  } finally {
    await pool.end();
  }
}
run();

