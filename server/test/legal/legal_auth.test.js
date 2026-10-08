'use strict';

// Kayit + publicUser.legal (sahte DB = test/auth/_auth_store; belgeler test/legal/fixtures):
//  - POST /auth/register accept_terms_version (ve acceptTermsVersion): guncel surumse kabul kaydi hesapla AYNI
//    transaction'da yazilir; farkli surum 409 LEGAL_VERSION_MISMATCH (+ data.current_version) ve hesap ACILMAZ;
//    alan yoksa hesap kabulsuz acilir; bozuk bicim 400 VALIDATION; kabul yazilamazsa hesap da yok (ROLLBACK)
//  - publicUser.legal {terms_accepted_version, terms_current_version, terms_status, needs_acceptance}: kayit, giris,
//    /auth/me ve sosyal giris yanitlarinda; needs_acceptance yalniz final belge + personel degil + (kabul yok | eski)
//  - belge servisi hata verse de giris BOZULMAZ (legal alanlari null, needs_acceptance false)
// Gercek PostgreSQL karsiligi (gercek ROLLBACK): legal_pg.test.js

const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const express = require('express');
const request = require('supertest');
const bcrypt = require('bcryptjs');
const { setTestEnv, installFakeDb } = require('../auth/_helpers');
const { createAuthStore } = require('../auth/_auth_store');

const GOOGLE_AUD = 'legal-test.apps.googleusercontent.com';
setTestEnv({ BCRYPT_TEST_COST: '4', GOOGLE_CLIENT_IDS: GOOGLE_AUD });
const fakeDb = installFakeDb();
const store = createAuthStore().install(fakeDb);

// Sahte DB transaction'i geri ALMAZ: bu dosyada users / legal_acceptances anlik goruntusu alinir ve hata olursa
// geri yuklenir (ROLLBACK taklidi). Kayit ile kabulun AYNI withTransaction cagrisinda oldugu boylece sinanir;
// gercek geri alma legal_pg.test.js'te kanitlanir.
const plainTx = fakeDb.withTransaction.bind(fakeDb);
fakeDb.withTransaction = async (fn) => {
  const users = new Map([...store.users].map(([k, v]) => [k, { ...v }]));
  const acceptances = store.legalAcceptances.map((a) => ({ ...a }));
  try {
    return await plainTx(fn);
  } catch (err) {
    store.users = users;
    store.legalAcceptances = acceptances;
    throw err;
  }
};

const authRoutes = require('../../src/routes/auth_routes');
const authService = require('../../src/services/auth_service');
const auth = require('../../src/middlewares/auth_middleware');
const { errorHandler } = require('../../src/middlewares/error_handler');
const { createLegalService } = require('../../src/services/legal_service');

auth.configureAuthMiddleware({ cacheTtlMs: 0 });

const silent = { log() {}, info() {}, warn() {}, error() {} };
const FIX = path.join(__dirname, 'fixtures');
const DRAFT = createLegalService({ dir: path.join(FIX, 'draft'), logger: silent });
const FINAL = createLegalService({ dir: path.join(FIX, 'final'), logger: silent });
const NONE = createLegalService({ dir: path.join(FIX, 'boyle-bir-dizin-yok'), logger: silent });

const app = express();
app.use(express.json());
app.use('/api/v1/auth', authRoutes);
app.use('/api/auth', authRoutes);
app.use(errorHandler);

const PASSWORD = 'Yasal-Parola-2026';
let seq = 0;
const email = (tag) => `${tag}-${++seq}@legal.example.test`;

function register(mail, extra = {}, url = '/api/v1/auth/register') {
  return request(app).post(url).send({ full_name: 'Yasal Deneme', email: mail, password: PASSWORD, ...extra });
}

const userByEmail = (mail) => [...store.users.values()].find((u) => u.email === mail) || null;

function legalOf(accepted, current, status, needs) {
  return { terms_accepted_version: accepted, terms_current_version: current, terms_status: status, needs_acceptance: needs };
}

test.beforeEach(() => {
  for (const l of Object.values(authRoutes.limiters)) l.reset();
  authRoutes.loginFailures.reset();
  authRoutes.loginFailuresTotal.reset();
  authService.setLegalService(DRAFT);
  store.failLegalInsert = false;
});

// ------------------------------------------------------------------------------------------------ kayit
test('kayit: accept_terms_version yok -> hesap KABULSUZ acilir; yanitta legal (taslak: needs_acceptance false)', async () => {
  const mail = email('yok');
  const before = fakeDb.findCalls(/legal_acceptances/).length;
  const res = await register(mail);
  assert.equal(res.status, 201, JSON.stringify(res.body));
  assert.deepEqual(res.body.data.user.legal, legalOf(null, 1, 'draft', false));
  const u = userByEmail(mail);
  assert.equal(store.acceptancesOf(u.id).length, 0);
  assert.equal(u.terms_version, null);
  assert.equal(fakeDb.findCalls(/legal_acceptances/).length, before, 'kabul tablosuna hic dokunulmaz');

  const nul = await register(email('null'), { accept_terms_version: null });
  assert.equal(nul.status, 201, 'null = alan yok');
  assert.equal(nul.body.data.user.legal.terms_accepted_version, null);
});

test('kayit: guncel surumle -> kabul kaydi (terms, surum, ip, user_agent) + users.terms_*; hesapla AYNI transaction', async () => {
  const mail = email('kabul');
  const res = await register(mail, { accept_terms_version: 1 }).set('User-Agent', 'AHBU-Test/1.0 (Android)');
  assert.equal(res.status, 201, JSON.stringify(res.body));
  assert.deepEqual(res.body.data.user.legal, legalOf(1, 1, 'draft', false));
  const u = userByEmail(mail);
  const rows = store.acceptancesOf(u.id);
  assert.equal(rows.length, 1);
  assert.equal(rows[0].document, 'terms');
  assert.equal(rows[0].version, 1);
  assert.equal(rows[0].user_agent, 'AHBU-Test/1.0 (Android)');
  assert.match(String(rows[0].ip_address), /127\.0\.0\.1|::1/);
  assert.equal(u.terms_version, 1);
  assert.ok(u.terms_accepted_at instanceof Date);

  const calls = fakeDb.calls.map((c) => c.text);
  const iUser = calls.findLastIndex((t) => /INSERT INTO users/.test(t));
  const iAcc = calls.findLastIndex((t) => /INSERT INTO legal_acceptances/.test(t));
  const iUpd = calls.findLastIndex((t) => /UPDATE users SET terms_version/.test(t));
  const iBegin = calls.lastIndexOf('BEGIN', iUser);
  const iCommit = calls.indexOf('COMMIT', iUpd);
  assert.ok(iBegin >= 0 && iBegin < iUser && iUser < iAcc && iAcc < iUpd && iUpd < iCommit, 'BEGIN < users < kabul < users.terms_* < COMMIT');
  assert.ok(!calls.slice(iBegin + 1, iCommit).some((t) => t === 'COMMIT' || t === 'BEGIN' || t === 'ROLLBACK'), 'tek transaction');
});

test('kayit: camelCase acceptTermsVersion, rakam dizgesi ve eski /api/auth yolu', async () => {
  const a = await register(email('camel'), { acceptTermsVersion: 1 });
  assert.equal(a.status, 201, JSON.stringify(a.body));
  assert.equal(a.body.data.user.legal.terms_accepted_version, 1);
  const b = await register(email('dizge'), { accept_terms_version: '1' }, '/api/auth/register');
  assert.equal(b.status, 201, JSON.stringify(b.body));
  assert.equal(b.body.data.user.legal.terms_accepted_version, 1);
});

test('kayit: farkli surum -> 409 LEGAL_VERSION_MISMATCH + data.current_version; hesap ACILMAZ, kabul yazilmaz', async () => {
  for (const v of [2, '9']) {
    const mail = email('uyusmaz');
    const res = await register(mail, { accept_terms_version: v });
    assert.equal(res.status, 409, JSON.stringify(res.body));
    assert.equal(res.body.code, 'LEGAL_VERSION_MISMATCH');
    assert.deepEqual(res.body.data, { current_version: 1 });
    assert.equal(userByEmail(mail), null, 'hesap acilmadi');
  }
  // sunucuda sozlesme yoksa hicbir surum guncel degildir
  authService.setLegalService(NONE);
  const mail = email('belgesiz');
  const res = await register(mail, { accept_terms_version: 1 });
  assert.equal(res.status, 409);
  assert.equal(res.body.code, 'LEGAL_VERSION_MISMATCH');
  assert.deepEqual(res.body.data, { current_version: null });
  assert.equal(userByEmail(mail), null);
  assert.equal(store.legalAcceptances.filter((a) => !store.users.has(a.user_id)).length, 0);
});

test('kayit: bozuk accept_terms_version -> 400 VALIDATION; hesap acilmaz', async () => {
  for (const v of [0, -1, 1.5, 'abc', '1.0', true, false, {}, [1]]) {
    const mail = email('bozuk');
    const res = await register(mail, { accept_terms_version: v });
    assert.equal(res.status, 400, `${JSON.stringify(v)} -> ${JSON.stringify(res.body)}`);
    assert.equal(res.body.code, 'VALIDATION');
    assert.equal(userByEmail(mail), null);
  }
});

test('kayit: diger alan hatalari once (400), surum denetimi e-posta cakismasindan once (409 LEGAL_VERSION_MISMATCH)', async () => {
  const bad = await register('gecersiz-eposta', { accept_terms_version: 2 });
  assert.equal(bad.status, 400);
  const mail = email('cakisma');
  assert.equal((await register(mail)).status, 201);
  const dupStale = await register(mail, { accept_terms_version: 2 });
  assert.equal(dupStale.body.code, 'LEGAL_VERSION_MISMATCH');
  const dupFresh = await register(mail, { accept_terms_version: 1 });
  assert.equal(dupFresh.status, 409);
  assert.equal(dupFresh.body.code, 'CONFLICT');
});

test('kayit ATOMIK: kabul yazilamazsa 500, hesap ACILMAZ (ROLLBACK); sonra ayni e-postayla kayit olur', async () => {
  const mail = email('atomik');
  store.failLegalInsert = true;
  const savedError = console.error;
  console.error = () => {};
  let res;
  try {
    res = await register(mail, { accept_terms_version: 1 });
  } finally {
    console.error = savedError;
    store.failLegalInsert = false;
  }
  assert.equal(res.status, 500);
  assert.equal(res.body.code, 'INTERNAL');
  assert.ok(!JSON.stringify(res.body).includes('legal_acceptances'), 'ic ayrinti sizmaz');
  assert.equal(userByEmail(mail), null, 'hesap geri alindi');
  const calls = fakeDb.calls.map((c) => c.text);
  const iAcc = calls.findLastIndex((t) => /INSERT INTO legal_acceptances/.test(t));
  assert.equal(calls[iAcc + 1], 'ROLLBACK');

  const ok = await register(mail, { accept_terms_version: 1 });
  assert.equal(ok.status, 201, JSON.stringify(ok.body));
  assert.equal(store.acceptancesOf(userByEmail(mail).id).length, 1);
});

// ------------------------------------------------------------------------------------------------ publicUser.legal
async function loginAs(fields) {
  const mail = email('giris');
  store.addUser({ email: mail, password_hash: await bcrypt.hash(PASSWORD, 4), ...fields });
  const res = await request(app).post('/api/v1/auth/login').send({ email: mail, password: PASSWORD });
  assert.equal(res.status, 200, JSON.stringify(res.body));
  return res.body.data;
}

test('publicUser.legal (final sozlesme): kabul yok / eski -> needs_acceptance true; guncel / ileri -> false; personel false; /auth/me ayni', async () => {
  authService.setLegalService(FINAL);
  const cases = [
    [{ terms_version: null }, legalOf(null, 2, 'final', true)],
    [{ terms_version: 1 }, legalOf(1, 2, 'final', true)],
    [{ terms_version: 2 }, legalOf(2, 2, 'final', false)],
    [{ terms_version: 3 }, legalOf(3, 2, 'final', false)],
    [{ role: 'service_user', terms_version: null }, legalOf(null, 2, 'final', false)],
    [{ role: 'super_user', terms_version: 1 }, legalOf(1, 2, 'final', false)],
  ];
  for (const [fields, expected] of cases) {
    const s = await loginAs(fields);
    assert.deepEqual(s.user.legal, expected, JSON.stringify(fields));
    const me = await request(app).get('/api/v1/auth/me').set('Authorization', `Bearer ${s.access_token}`);
    assert.equal(me.status, 200);
    assert.deepEqual(me.body.data.user.legal, expected, `me ${JSON.stringify(fields)}`);
  }
});

test('publicUser.legal (taslak sozlesme): kabul olmasa da needs_acceptance false', async () => {
  const s = await loginAs({ terms_version: null });
  assert.deepEqual(s.user.legal, legalOf(null, 1, 'draft', false));
});

test('publicUser.legal: sozlesme yuklu degilse alanlar null, needs_acceptance false', async () => {
  authService.setLegalService(NONE);
  const s = await loginAs({ terms_version: 1 });
  assert.deepEqual(s.user.legal, legalOf(1, null, null, false));
});

test('kayit (final sozlesme): kabulsuz -> needs_acceptance true; guncel surumle (2) -> false', async () => {
  authService.setLegalService(FINAL);
  const a = await register(email('final-yok'));
  assert.equal(a.status, 201);
  assert.deepEqual(a.body.data.user.legal, legalOf(null, 2, 'final', true));
  const b = await register(email('final-kabul'), { accept_terms_version: 2 });
  assert.equal(b.status, 201, JSON.stringify(b.body));
  assert.deepEqual(b.body.data.user.legal, legalOf(2, 2, 'final', false));
  const c = await register(email('final-eski'), { accept_terms_version: 1 });
  assert.equal(c.status, 409);
  assert.deepEqual(c.body.data, { current_version: 2 });
});

test('Google girisi yaniti da legal tasir', async () => {
  authService.setLegalService(FINAL);
  authService.setIdentityVerifiers({
    google: async () => ({
      sub: 'google-legal-1',
      iss: 'https://accounts.google.com',
      aud: GOOGLE_AUD,
      exp: Math.floor(Date.now() / 1000) + 600,
      email: 'google.legal@example.test',
      email_verified: true,
      name: 'Google Yasal',
    }),
  });
  try {
    const res = await request(app).post('/api/v1/auth/google').send({ id_token: 'x'.repeat(64) });
    assert.equal(res.status, 200, JSON.stringify(res.body));
    assert.deepEqual(res.body.data.user.legal, legalOf(null, 2, 'final', true));
  } finally {
    authService.resetIdentityVerifiers();
  }
});

test('belge servisi hata verse de giris BOZULMAZ: legal alanlari null, needs_acceptance false', async () => {
  authService.setLegalService({
    getTermsState() {
      throw new Error('disk okunamadi');
    },
  });
  const savedWarn = console.warn;
  console.warn = () => {};
  try {
    const s = await loginAs({ terms_version: 1 });
    assert.deepEqual(s.user.legal, legalOf(1, null, null, false));
  } finally {
    console.warn = savedWarn;
  }
});

test('sahte depo: tum SQL taninir', () => {
  assert.deepEqual(store.unmatched, []);
});
