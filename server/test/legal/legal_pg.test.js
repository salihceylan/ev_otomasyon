'use strict';

// Yasal metinler GERCEK PostgreSQL'de (yalitilmis gecici veritabani; scripts/migrate.js 001..039):
//  - 039 semasi: kolon tipleri, CHECK'ler, FK ON DELETE CASCADE, indeks; dosya iki kez daha -> hata yok, veri korunur
//  - gercek uygulama (createApp + src/db): kayit + accept_terms_version -> kabul satiri ve users.terms_* AYNI
//    transaction'da (terms_accepted_at = accepted_at); 409 LEGAL_VERSION_MISMATCH'te hesap YOK; ATOMIKLIK: kabul
//    yazimi (tetikleyiciyle) bozulunca hesap da YOK (gercek ROLLBACK)
//  - POST /legal/accept: 200, idempotent (tek satir), user_agent 255'e kesilir, 409 + current_version, privacy 400;
//    /auth/me legal guncel; final sozlesmede eski kabul -> needs_acceptance true, personel false
// EV_PG_TEST_URL yoksa ATLANIR.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { PG_SKIP, openDatabase, setAppEnv, fakeBridge, fakePush } = require('./_pg');

const SQL_039 = fs.readFileSync(path.join(__dirname, '..', '..', 'migrations', '039_legal_acceptances.sql'), 'utf8');
const FIX = path.join(__dirname, 'fixtures');
const PASSWORD = 'Yasal-PG-Parola-2026';
const silent = { log() {}, info() {}, warn() {}, error() {} };

test('039 + yasal metin uclari gercek PG', { skip: PG_SKIP }, async (t) => {
  const dbx = await openDatabase('legal');
  if (!dbx) {
    t.skip('CREATE DATABASE yetkisi yok');
    return;
  }
  setAppEnv(dbx.url);
  const saved = { log: console.log, warn: console.warn, error: console.error };
  console.log = () => {}; // db.js gelistirmede her sorguyu loglar
  console.warn = () => {};
  const db = require('../../src/db');
  try {
    const request = require('supertest');
    const bcrypt = require('bcryptjs');
    const authService = require('../../src/services/auth_service');
    const { createApp } = require('../../src/server');
    const { createLegalService } = require('../../src/services/legal_service');
    const DRAFT = createLegalService({ dir: path.join(FIX, 'draft'), db, logger: silent });
    const FINAL = createLegalService({ dir: path.join(FIX, 'final'), db, logger: silent });
    const app = createApp({ db, mqttBridge: fakeBridge, pushService: fakePush, legalService: DRAFT });
    const q = (text, params) => db.query(text, params);
    const one = async (text, params) => (await q(text, params)).rows[0];
    let n = 0;
    const mail = (tag) => `${tag}-${++n}@legalpg.example.test`;
    const register = (email, extra = {}, ua = 'AHBU-PG/1.0') =>
      request(app).post('/api/v1/auth/register').set('User-Agent', ua).send({ full_name: 'Yasal PG', email, password: PASSWORD, ...extra });
    const login = async (email) => {
      const r = await request(app).post('/api/v1/auth/login').send({ email, password: PASSWORD });
      assert.equal(r.status, 200, JSON.stringify(r.body));
      return r.body.data;
    };

    await t.test('039 semasi: tipler, CHECK, FK CASCADE, indeks; dosya iki kez daha (idempotent)', async () => {
      const cols = await q(
        `SELECT table_name, column_name, data_type, is_nullable, column_default
           FROM information_schema.columns
          WHERE (table_name = 'users' AND column_name IN ('terms_version', 'terms_accepted_at')) OR table_name = 'legal_acceptances'
          ORDER BY table_name, ordinal_position`
      );
      const byName = Object.fromEntries(cols.rows.map((r) => [`${r.table_name}.${r.column_name}`, r]));
      assert.equal(byName['users.terms_version'].data_type, 'integer');
      assert.equal(byName['users.terms_version'].is_nullable, 'YES');
      assert.equal(byName['users.terms_accepted_at'].data_type, 'timestamp with time zone');
      assert.deepEqual(
        cols.rows.filter((r) => r.table_name === 'legal_acceptances').map((r) => [r.column_name, r.data_type, r.is_nullable]),
        [
          ['id', 'bigint', 'NO'],
          ['user_id', 'uuid', 'NO'],
          ['document', 'text', 'NO'],
          ['version', 'integer', 'NO'],
          ['accepted_at', 'timestamp with time zone', 'NO'],
          ['ip_address', 'text', 'YES'],
          ['user_agent', 'text', 'YES'],
        ]
      );
      const idx = await one("SELECT indexdef FROM pg_indexes WHERE indexname = 'idx_legal_acceptances_user_doc'");
      assert.match(idx.indexdef, /\(user_id, document, accepted_at DESC\)/);

      const u = await one("INSERT INTO users (full_name, email, password_hash) VALUES ('S', $1, 'x') RETURNING id", [mail('sema')]);
      await assert.rejects(q("INSERT INTO legal_acceptances (user_id, document, version) VALUES ($1, 'cerez', 1)", [u.id]), (e) => e.code === '23514');
      await assert.rejects(q("INSERT INTO legal_acceptances (user_id, document, version) VALUES ($1, 'terms', 0)", [u.id]), (e) => e.code === '23514');
      await assert.rejects(q("INSERT INTO legal_acceptances (user_id, document, version) VALUES (gen_random_uuid(), 'terms', 1)"), (e) => e.code === '23503');
      const row = await one("INSERT INTO legal_acceptances (user_id, document, version) VALUES ($1, 'privacy', 1) RETURNING accepted_at, ip_address", [u.id]);
      assert.ok(row.accepted_at instanceof Date, 'accepted_at varsayilani');
      assert.equal(row.ip_address, null);

      for (let i = 0; i < 2; i += 1) {
        await db.withTransaction((tx) => tx.query(SQL_039));
      }
      assert.equal((await one('SELECT count(*)::int AS n FROM legal_acceptances WHERE user_id = $1', [u.id])).n, 1, 'veri korunur');
      assert.equal((await one("SELECT count(*)::int AS n FROM pg_indexes WHERE tablename = 'legal_acceptances'")).n, 2, 'PK + tek indeks');
      assert.equal((await one("SELECT count(*)::int AS n FROM schema_migrations WHERE name = '039_legal_acceptances.sql'")).n, 1);

      await q('DELETE FROM users WHERE id = $1', [u.id]);
      assert.equal((await one('SELECT count(*)::int AS n FROM legal_acceptances WHERE user_id = $1', [u.id])).n, 0, 'ON DELETE CASCADE');
    });

    await t.test('kayit + accept_terms_version: kabul satiri ve users.terms_* ayni transaction (ayni zaman damgasi)', async () => {
      const email = mail('kayit');
      const res = await register(email, { accept_terms_version: 1 });
      assert.equal(res.status, 201, JSON.stringify(res.body));
      assert.deepEqual(res.body.data.user.legal, { terms_accepted_version: 1, terms_current_version: 1, terms_status: 'draft', needs_acceptance: false });
      const row = await one(
        `SELECT u.terms_version, u.terms_accepted_at = la.accepted_at AS same_time, la.document, la.version, la.ip_address, la.user_agent
           FROM users u JOIN legal_acceptances la ON la.user_id = u.id
          WHERE u.email = $1`,
        [email]
      );
      assert.equal(row.terms_version, 1);
      assert.equal(row.same_time, true);
      assert.equal(row.document, 'terms');
      assert.equal(row.version, 1);
      assert.equal(row.user_agent, 'AHBU-PG/1.0');
      assert.ok(row.ip_address);

      const plain = mail('kabulsuz');
      assert.equal((await register(plain)).status, 201);
      const p = await one('SELECT terms_version, terms_accepted_at FROM users WHERE email = $1', [plain]);
      assert.deepEqual(p, { terms_version: null, terms_accepted_at: null });
      assert.equal((await one('SELECT count(*)::int AS n FROM legal_acceptances la JOIN users u ON u.id = la.user_id WHERE u.email = $1', [plain])).n, 0);
    });

    await t.test('kayit: surum uyusmazligi 409 ve hesap YOK', async () => {
      const email = mail('uyusmaz');
      const res = await register(email, { accept_terms_version: 2 });
      assert.equal(res.status, 409);
      assert.equal(res.body.code, 'LEGAL_VERSION_MISMATCH');
      assert.deepEqual(res.body.data, { current_version: 1 });
      assert.equal((await one('SELECT count(*)::int AS n FROM users WHERE email = $1', [email])).n, 0);
    });

    await t.test('kayit ATOMIK: kabul yazimi bozulursa (tetikleyici) 500 ve hesap YOK; tetikleyici kalkinca kayit olur', async () => {
      await q(`CREATE OR REPLACE FUNCTION legal_test_fail() RETURNS trigger LANGUAGE plpgsql AS $$
               BEGIN
                 IF NEW.user_agent = 'ATOMIK-HATA' THEN RAISE EXCEPTION 'legal test hatasi'; END IF;
                 RETURN NEW;
               END $$`);
      await q('CREATE TRIGGER trg_legal_test_fail BEFORE INSERT ON legal_acceptances FOR EACH ROW EXECUTE FUNCTION legal_test_fail()');
      const email = mail('atomik');
      try {
        console.error = () => {};
        const res = await register(email, { accept_terms_version: 1 }, 'ATOMIK-HATA');
        console.error = saved.error;
        assert.equal(res.status, 500);
        assert.equal((await one('SELECT count(*)::int AS n FROM users WHERE email = $1', [email])).n, 0, 'hesap geri alindi');
      } finally {
        console.error = saved.error;
        await q('DROP TRIGGER IF EXISTS trg_legal_test_fail ON legal_acceptances');
        await q('DROP FUNCTION IF EXISTS legal_test_fail()');
      }
      const ok = await register(email, { accept_terms_version: 1 }, 'ATOMIK-HATA');
      assert.equal(ok.status, 201, JSON.stringify(ok.body));
    });

    await t.test('POST /legal/accept: 200, idempotent, user_agent 255, 409, privacy 400; /auth/me guncel', async () => {
      const email = mail('kabul');
      assert.equal((await register(email)).status, 201);
      const s = await login(email);
      const auth = `Bearer ${s.access_token}`;
      const ua = `AHBU/1.0 ${'y'.repeat(400)}`;
      const r1 = await request(app).post('/api/v1/legal/accept').set('Authorization', auth).set('User-Agent', ua).send({ document: 'terms', version: 1 });
      assert.equal(r1.status, 200, JSON.stringify(r1.body));
      assert.equal(r1.body.data.document, 'terms');
      assert.equal(r1.body.data.version, 1);
      const r2 = await request(app).post('/api/legal/accept').set('Authorization', auth).send({ document: 'terms', version: 1 });
      assert.equal(r2.status, 200);
      assert.equal(r2.body.data.accepted_at, r1.body.data.accepted_at, 'ayni kabul');
      const rows = (await q('SELECT la.user_agent, la.version FROM legal_acceptances la JOIN users u ON u.id = la.user_id WHERE u.email = $1', [email])).rows;
      assert.equal(rows.length, 1, 'cift satir yok');
      assert.equal(rows[0].user_agent, ua.slice(0, 255));
      const u = await one('SELECT terms_version FROM users WHERE email = $1', [email]);
      assert.equal(u.terms_version, 1);

      const stale = await request(app).post('/api/v1/legal/accept').set('Authorization', auth).send({ document: 'terms', version: 2 });
      assert.equal(stale.status, 409);
      assert.deepEqual(stale.body.data, { current_version: 1 });
      const priv = await request(app).post('/api/v1/legal/accept').set('Authorization', auth).send({ document: 'privacy', version: 1 });
      assert.equal(priv.status, 400);
      assert.equal(priv.body.code, 'VALIDATION');

      const me = await request(app).get('/api/v1/auth/me').set('Authorization', auth);
      assert.equal(me.status, 200);
      assert.deepEqual(me.body.data.user.legal, { terms_accepted_version: 1, terms_current_version: 1, terms_status: 'draft', needs_acceptance: false });

      // Final ikinci surum yayimlandi: eski kabul -> needs_acceptance; personel muaf
      authService.setLegalService(FINAL);
      try {
        const me2 = await request(app).get('/api/v1/auth/me').set('Authorization', auth);
        assert.deepEqual(me2.body.data.user.legal, { terms_accepted_version: 1, terms_current_version: 2, terms_status: 'final', needs_acceptance: true });
        const staffMail = mail('personel');
        await q("INSERT INTO users (full_name, email, password_hash, role) VALUES ('P', $1, $2, 'service_user')", [staffMail, await bcrypt.hash(PASSWORD, 4)]);
        const st = await login(staffMail);
        assert.deepEqual(st.user.legal, { terms_accepted_version: null, terms_current_version: 2, terms_status: 'final', needs_acceptance: false });
      } finally {
        authService.setLegalService(DRAFT);
      }
    });
  } finally {
    Object.assign(console, saved);
    await db.pool.end().catch(() => {});
    await dbx.drop();
  }
});
