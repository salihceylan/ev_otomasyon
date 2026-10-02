'use strict';

// Test yardimcilari (WP-A). Bu dosya `*.test.js` olmadigi icin test olarak calismaz.
//
// - Sir degerleri koda YAZILMAZ: JWT_SECRET / PIN_PEPPER her test surecinde rastgele uretilir.
// - Gercek veritabani yoktur: `src/db.js` require.cache uzerinden sahte modulle degistirilir.
//   (node --test her test dosyasini ayri surecte calistirdigi icin degisiklik sizmaz.)

const crypto = require('crypto');
const path = require('path');

const SRC = path.join(__dirname, '..', '..', 'src');

function setTestEnv(overrides = {}) {
  process.env.NODE_ENV = 'test';
  process.env.JWT_SECRET = crypto.randomBytes(48).toString('hex');
  process.env.PIN_PEPPER = crypto.randomBytes(48).toString('hex');
  process.env.AUTH_CACHE_TTL_MS = '0';
  process.env.DATABASE_URL = process.env.DATABASE_URL || 'postgres://test-only-not-used/none';
  delete process.env.ALLOW_DEBUG_OTP;
  delete process.env.ADMIN_API_KEY;
  delete process.env.INVENTORY_ADMIN_API_KEY;
  delete process.env.GOOGLE_CLIENT_IDS;
  delete process.env.APPLE_CLIENT_IDS;
  for (const [k, v] of Object.entries(overrides)) {
    if (v === undefined || v === null) delete process.env[k];
    else process.env[k] = String(v);
  }
}

/**
 * Programlanabilir sahte DB.
 *   db.on(/SELECT .* FROM users/, (params, text) => [ {..row..} ])
 * Eslesen ilk isleyici kullanilir; isleyici dizi, {rows,rowCount} veya Error donebilir.
 * Eslesme yoksa bos sonuc doner. Tum cagrilar db.calls icinde kaydedilir.
 */
function createFakeDb() {
  const handlers = [];
  const calls = [];
  const db = {
    calls,
    txCount: 0,
    rollbacks: 0,
    commits: 0,
    on(pattern, fn) {
      handlers.unshift({ pattern, fn });
      return db;
    },
    reset() {
      handlers.length = 0;
      calls.length = 0;
      db.txCount = 0;
      db.rollbacks = 0;
      db.commits = 0;
    },
    async query(text, params = []) {
      calls.push({ text: String(text), params });
      for (const h of handlers) {
        const hit = typeof h.pattern === 'string' ? String(text).includes(h.pattern) : h.pattern.test(String(text));
        if (!hit) continue;
        const out = await h.fn(params, String(text));
        if (out instanceof Error) throw out;
        if (Array.isArray(out)) return { rows: out, rowCount: out.length };
        if (out && Array.isArray(out.rows)) return { rowCount: out.rows.length, ...out };
        return { rows: [], rowCount: 0 };
      }
      return { rows: [], rowCount: 0 };
    },
    async withTransaction(fn) {
      db.txCount += 1;
      calls.push({ text: 'BEGIN', params: [] });
      try {
        const result = await fn({ query: (t, p) => db.query(t, p), inTransaction: true });
        calls.push({ text: 'COMMIT', params: [] });
        db.commits += 1;
        return result;
      } catch (err) {
        calls.push({ text: 'ROLLBACK', params: [] });
        db.rollbacks += 1;
        throw err;
      }
    },
    pool: { end: async () => {} },
    findCalls(pattern) {
      return calls.filter((c) => (typeof pattern === 'string' ? c.text.includes(pattern) : pattern.test(c.text)));
    },
  };
  return db;
}

function installModule(relPathFromSrc, exportsObj) {
  const full = require.resolve(path.join(SRC, relPathFromSrc));
  require.cache[full] = { id: full, filename: full, loaded: true, exports: exportsObj, children: [], paths: [] };
  return full;
}

function installFakeDb(db = createFakeDb()) {
  installModule('db.js', db);
  return db;
}

function requireSrc(relPathFromSrc) {
  return require(path.join(SRC, relPathFromSrc));
}

function uuid() {
  return crypto.randomUUID();
}

function makeAccessToken(user) {
  const { signAccessToken } = requireSrc('middlewares/jwt_config.js');
  return signAccessToken(user);
}

function makeServiceToken({ sid, home_id, expiresInSec }) {
  const { signServiceSessionToken } = requireSrc('middlewares/jwt_config.js');
  return signServiceSessionToken({ sid, home_id, expiresInSec });
}

module.exports = {
  SRC,
  setTestEnv,
  createFakeDb,
  installFakeDb,
  installModule,
  requireSrc,
  uuid,
  makeAccessToken,
  makeServiceToken,
};
