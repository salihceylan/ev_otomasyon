const { Pool } = require('pg');
require('dotenv').config();

// Yanlis veritabanina (ornegin ayni sunucudaki uretim kapi sistemine) sessizce
// dusmemek icin DATABASE_URL zorunludur. pg varsayilanlarina (localhost:5432) dusulmez.
if (!process.env.DATABASE_URL) {
  throw new Error(
    '[DB] DATABASE_URL tanimli degil. Sunucu baslatilmadi (yanlis veritabanina baglanmayi onlemek icin).'
  );
}

const pool = new Pool({
  connectionString: process.env.DATABASE_URL,
  max: 20,
  idleTimeoutMillis: 30000,
  connectionTimeoutMillis: 5000,
  // Acik kalan transaction ve takili sorgularin havuzu kilitlemesini onler.
  statement_timeout: 15000,
  idle_in_transaction_session_timeout: 20000,
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

/**
 * Gercek (tek baglantili) transaction calistirir.
 *
 * ONEMLI: `db.query('BEGIN')` KULLANMAYIN. query() havuzdan her cagrida farkli bir
 * baglanti alabilir; BEGIN, sorgular ve COMMIT farkli baglantilara dusebilir ve
 * ROLLBACK hicbir seyi geri almaz.
 *
 * Kullanim:
 *   const sonuc = await db.withTransaction(async (tx) => {
 *     await tx.query('UPDATE ...', [..]);
 *     const r = await tx.query('SELECT ... FOR UPDATE', [..]);
 *     return r.rows[0];
 *   });
 * Callback hata firlatirsa ROLLBACK yapilir ve hata yeniden firlatilir.
 */
async function withTransaction(fn) {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const tx = { query: (text, params) => client.query(text, params) };
    const result = await fn(tx);
    await client.query('COMMIT');
    return result;
  } catch (err) {
    try {
      await client.query('ROLLBACK');
    } catch (rollbackErr) {
      console.error('[DB-ERROR] ROLLBACK basarisiz:', rollbackErr.message);
    }
    throw err;
  } finally {
    client.release();
  }
}

module.exports = {
  pool,
  query,
  withTransaction,
};
