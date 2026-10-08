'use strict';

// 039 ONCESI dayaniklilik (GERCEK PostgreSQL, yalitilmis gecici veritabani: scripts/migrate.js --to 038):
// yeni kod 039 uygulanmamis veritabaninda giris / kayit / profil yanitlarini BOZMAZ (users.terms_version to_jsonb ile
// okunur -> null). accept_terms_version'li kayit 500 doner ve hesap ACILMAZ (transaction geri alinir). 039 uygulaninca
// ayni surec kabulu yazar. Dagitim sirasi yine "once migration, sonra sunucu"dur; bu test yanlis siradaki pencereyi sinar.
// EV_PG_TEST_URL yoksa ATLANIR.

const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { PG_SKIP, openDatabase, setAppEnv, fakeBridge, fakePush } = require('./_pg');

const FIX = path.join(__dirname, 'fixtures');
const PASSWORD = 'Yasal-Eski-Sema-2026';
const silent = { log() {}, info() {}, warn() {}, error() {} };

test('039 oncesi veritabani: giris/me/kayit calisir, kabullu kayit geri alinir; 039 sonrasi kabul yazilir', { skip: PG_SKIP }, async (t) => {
  const dbx = await openDatabase('pre039', { to: '038' });
  if (!dbx) {
    t.skip('CREATE DATABASE yetkisi yok');
    return;
  }
  setAppEnv(dbx.url);
  const saved = { log: console.log, warn: console.warn, error: console.error };
  console.log = () => {};
  console.warn = () => {};
  console.error = () => {};
  const db = require('../../src/db');
  try {
    const request = require('supertest');
    const bcrypt = require('bcryptjs');
    const { createApp } = require('../../src/server');
    const { createLegalService } = require('../../src/services/legal_service');
    const legal = createLegalService({ dir: path.join(FIX, 'draft'), db, logger: silent });
    const app = createApp({ db, mqttBridge: fakeBridge, pushService: fakePush, legalService: legal });
    const one = async (text, params) => (await db.query(text, params)).rows[0];

    const pre = await one(
      `SELECT to_regclass('public.legal_acceptances') AS tbl,
              EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'users' AND column_name = 'terms_version') AS col,
              (SELECT max(name) FROM schema_migrations) AS last`
    );
    assert.deepEqual(pre, { tbl: null, col: false, last: '038_replace_board_repairs.sql' }, 'on kosul: 039 yok');

    const old = 'eski-sema@legalpg.example.test';
    await db.query("INSERT INTO users (full_name, email, password_hash, role) VALUES ('Eski', $1, $2, 'user')", [old, await bcrypt.hash(PASSWORD, 4)]);
    const login = await request(app).post('/api/v1/auth/login').send({ email: old, password: PASSWORD });
    assert.equal(login.status, 200, JSON.stringify(login.body));
    assert.deepEqual(login.body.data.user.legal, { terms_accepted_version: null, terms_current_version: 1, terms_status: 'draft', needs_acceptance: false });
    const me = await request(app).get('/api/v1/auth/me').set('Authorization', `Bearer ${login.body.data.access_token}`);
    assert.equal(me.status, 200);
    assert.equal(me.body.data.user.legal.terms_accepted_version, null);

    const reg = await request(app).post('/api/v1/auth/register').send({ full_name: 'Yeni', email: 'kabulsuz@legalpg.example.test', password: PASSWORD });
    assert.equal(reg.status, 201, JSON.stringify(reg.body));

    const failing = 'kabullu@legalpg.example.test';
    const bad = await request(app).post('/api/v1/auth/register').send({ full_name: 'Yeni', email: failing, password: PASSWORD, accept_terms_version: 1 });
    assert.equal(bad.status, 500);
    assert.equal((await one('SELECT count(*)::int AS n FROM users WHERE email = $1', [failing])).n, 0, 'hesap geri alindi');

    await dbx.migrate();
    const ok = await request(app).post('/api/v1/auth/register').send({ full_name: 'Yeni', email: failing, password: PASSWORD, accept_terms_version: 1 });
    assert.equal(ok.status, 201, JSON.stringify(ok.body));
    assert.equal(ok.body.data.user.legal.terms_accepted_version, 1);
    assert.equal((await one('SELECT count(*)::int AS n FROM legal_acceptances')).n, 1);
  } finally {
    Object.assign(console, saved);
    await db.pool.end().catch(() => {});
    await dbx.drop();
  }
});
