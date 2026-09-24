const { Pool } = require('pg');
require('dotenv').config();

const pool = new Pool({
  connectionString: process.env.DATABASE_URL,
  max: 20,
  idleTimeoutMillis: 30000,
  connectionTimeoutMillis: 5000,
});

pool.on('error', (err) => {
  console.error('[DB-ERROR] Beklenmeyen veritabani havuz hatasi:', err.message);
});

async function query(text, params) {
  const start = Date.now();
  try {
    const res = await pool.query(text, params);
    const duration = Date.now() - start;
    if (process.env.NODE_ENV !== 'production') {
      console.log('[DB-QUERY]', { text, duration: `${duration}ms`, rows: res.rowCount });
    }
    return res;
  } catch (error) {
    console.error('[DB-QUERY-ERROR]', { text, error: error.message });
    throw error;
  }
}

module.exports = {
  pool,
  query,
};

