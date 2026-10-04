'use strict';

// Yer tutucu (teslim edilemeyen) e-postalar: telefon-OTP hesabi `phone_<no>@ahbu.local`, Apple gizli e-posta
// `apple.<ozet>@users.noreply.invalid`, silinmis hesap `deleted+<id>@deleted.invalid`.
//
// UYELIK-07 (karar D7): disari donen kullanici nesnesinde (publicUser: giris/kayit/me/sosyal/OTP/sifirlama yanitlari)
//   yer tutucu e-posta -> email: null. Sunucunun bu e-postayi ICERDE kullandigi yollar (giris kimligi, sosyal eslestirme)
//   bozulmaz: DB satiri aynen kalir.
// UYELIK-08 (karar D8): requestPasswordReset - bulunan kullanicinin e-postasi yer tutucuysa kullaniciya bagli sifirlama
//   talebi ACILMAZ ve mailer CAGRILMAZ; yanit kayitsiz kimlikteki genel 200 ile AYNIDIR (hesap varligi sizmaz: 60 sn /
//   saatte 5 sinirlari da kayitsiz kimlikle ayni isler).

const test = require('node:test');
const assert = require('node:assert');
const express = require('express');
const request = require('supertest');
const bcrypt = require('bcryptjs');
const { setTestEnv, installFakeDb, makeAccessToken } = require('./_helpers');
const { createAuthStore } = require('./_auth_store');

const APPLE_AUD = 'com.ahbu.test';
setTestEnv({ BCRYPT_TEST_COST: '4', APPLE_CLIENT_IDS: APPLE_AUD });
const fakeDb = installFakeDb();
let clock = Date.now();
const store = createAuthStore({ now: () => clock }).install(fakeDb);

const authRoutes = require('../../src/routes/auth_routes');
const authService = require('../../src/services/auth_service');
const mailer = require('../../src/utils/mailer');
const auth = require('../../src/middlewares/auth_middleware');
const { errorHandler } = require('../../src/middlewares/error_handler');

auth.configureAuthMiddleware({ cacheTtlMs: 0 });

const app = express();
app.use(express.json());
app.use('/api/v1/auth', authRoutes);
app.use(errorHandler);
const server = app.listen(0, '127.0.0.1');
test.after(() => new Promise((resolve) => server.close(() => resolve())));

const post = (path, body) => request(server).post(`/api/v1/auth/${path}`).send(body || {});
const advance = (sec) => { clock += sec * 1000; };

// mailer.sendPasswordResetEmail casusu (auth_service modul nesnesi uzerinden cagirir)
const resetMails = [];
const realSendReset = mailer.sendPasswordResetEmail;
mailer.sendPasswordResetEmail = async (args) => {
  resetMails.push(args.to);
  return realSendReset(args);
};

test.beforeEach(() => {
  for (const l of Object.values(authRoutes.limiters)) l.reset();
  process.env.NODE_ENV = 'test';
  delete process.env.ALLOW_DEBUG_OTP;
  mailer.setTransportFactory(() => ({ sendMail: async () => ({ messageId: 'x' }) }));
  resetMails.length = 0;
  authService.resetIdentityVerifiers();
  advance(3600);
});

function phoneUser(phone) {
  return store.addUser({ phone, email: `phone_${phone.replace(/[^0-9]/g, '')}@ahbu.local`, full_name: `Sakin (${phone.slice(-4)})`, password_hash: '!unusable' });
}

// ================================ UYELIK-07 ================================
test('telefon-OTP ile acilan hesap: yanittaki user.email null (DB\'de yer tutucu kalir); /auth/me de null', async () => {
  process.env.ALLOW_DEBUG_OTP = 'true';
  const phone = '+905557770001';
  const sent = await post('otp/send', { phone });
  assert.strictEqual(sent.status, 200, JSON.stringify(sent.body));
  const res = await post('otp/verify', { phone, code: sent.body.data.debug_code });
  assert.strictEqual(res.status, 200, JSON.stringify(res.body));
  assert.strictEqual(res.body.data.user.email, null);
  assert.strictEqual(res.body.data.user.phone, phone);

  const row = [...store.users.values()].find((u) => u.phone === phone);
  assert.match(row.email, /^phone_905557770001@ahbu\.local$/, 'ic kimlik (DB) aynen kalir');

  const me = await request(server).get('/api/v1/auth/me').set('Authorization', `Bearer ${res.body.data.access_token}`);
  assert.strictEqual(me.status, 200);
  assert.strictEqual(me.body.data.user.email, null);
  assert.strictEqual(JSON.stringify(me.body).includes('ahbu.local'), false);

  // ikinci giris ayni hesaba (telefonla eslestirme bozulmadi)
  advance(61);
  const again = await post('otp/send', { phone });
  const res2 = await post('otp/verify', { phone, code: again.body.data.debug_code });
  assert.strictEqual(res2.status, 200);
  assert.strictEqual(res2.body.data.user.id, res.body.data.user.id);
});

test('Apple e-postasini gizlerse: yanitta email null; DB yer tutucuyu tutar; ayni Apple kimligi ayni hesaba girer', async () => {
  authService.setIdentityVerifiers({
    apple: async () => ({ sub: 'apple-gizli-1', iss: 'https://appleid.apple.com', aud: APPLE_AUD, exp: Math.floor(Date.now() / 1000) + 600 }),
  });
  const res = await post('apple', { identity_token: 'x'.repeat(64) });
  assert.strictEqual(res.status, 200, JSON.stringify(res.body));
  assert.strictEqual(res.body.data.user.email, null);
  const row = [...store.users.values()].find((u) => u.apple_id === 'apple-gizli-1');
  assert.match(row.email, /@users\.noreply\.invalid$/);
  const res2 = await post('apple', { identity_token: 'y'.repeat(64) });
  assert.strictEqual(res2.status, 200);
  assert.strictEqual(res2.body.data.user.id, res.body.data.user.id);
  assert.strictEqual(res2.body.data.user.email, null);
});

test('gercek e-posta aynen doner (buyuk/kucuk harf normalize); silinmis hesap yer tutucusu da null', async () => {
  const reg = await post('register', { full_name: 'Gercek Kisi', email: 'Gercek.Kisi@Example.com', password: 'Dogru-Parola-2026' });
  assert.strictEqual(reg.status, 201, JSON.stringify(reg.body));
  assert.strictEqual(reg.body.data.user.email, 'gercek.kisi@example.com');

  const gone = store.addUser({ email: 'deleted+0a1b@deleted.invalid', account_status: 'active' });
  const profile = await authService.getProfile(gone.id);
  assert.strictEqual(profile.user.email, null);
  // buyuk harfli yer tutucu da yakalanir
  const upper = store.addUser({ email: 'PHONE_905550000099@AHBU.LOCAL' });
  assert.strictEqual((await authService.getProfile(upper.id)).user.email, null);
  // yer tutucuya BENZEYEN gercek alan adlari dokunulmaz
  const similar = store.addUser({ email: 'kisi@ahbu.local.example.com' });
  assert.strictEqual((await authService.getProfile(similar.id)).user.email, 'kisi@ahbu.local.example.com');
});

test('parola ile giris (telefon kimligi) yer tutucu e-postali hesapta da kullaniciyi bulur; yanit email null', async () => {
  const phone = '+905557770002';
  const u = phoneUser(phone);
  u.password_hash = await bcrypt.hash('Telefon-Parola-2026', 4);
  const res = await post('login', { phone, password: 'Telefon-Parola-2026' });
  assert.strictEqual(res.status, 200, JSON.stringify(res.body));
  assert.strictEqual(res.body.data.user.id, u.id);
  assert.strictEqual(res.body.data.user.email, null);
  const tok = makeAccessToken(store.users.get(u.id));
  const me = await request(server).get('/api/v1/auth/me').set('Authorization', `Bearer ${tok}`);
  assert.strictEqual(me.body.data.user.email, null);
});

// ================================ UYELIK-08 ================================
test('sifremi unuttum (telefon) - yalniz SMS ile acilmis hesap: mailer CAGRILMAZ, kullaniciya bagli talep ACILMAZ, yanit kayitsiz numarayla AYNI', async () => {
  const phone = '+905557770003';
  const u = phoneUser(phone);
  const a = await post('forgot-password', { phone });
  const b = await post('forgot-password', { phone: '+905557779999' }); // kayitsiz
  assert.strictEqual(a.status, 200, JSON.stringify(a.body));
  assert.strictEqual(b.status, 200);
  assert.deepStrictEqual(a.body, b.body, 'yanit govdesi birebir ayni');
  assert.deepStrictEqual(resetMails, [], 'yer tutucu adrese gonderim DENENMEMELI');
  assert.strictEqual(store.resets.filter((r) => r.user_id === u.id).length, 0, 'kullaniciya bagli sifirlama talebi acilmamali');
  // ayni kimlik 60 sn icinde: ikisi de 429 (sinir davranisi da ayni -> hesap varligi sizmaz)
  const a2 = await post('forgot-password', { phone });
  const b2 = await post('forgot-password', { phone: '+905557779999' });
  assert.deepStrictEqual([a2.status, b2.status], [429, 429]);
  assert.strictEqual(a2.body.code, b2.body.code);
  // kod girilse bile hesap ele gecirilemez
  const row = store.resets.filter((r) => r.identifier === phone).pop();
  assert.ok(row, 'sinir sayaci icin kayitsiz kimlik gibi (kullanicisiz) satir yazilir');
  assert.strictEqual(row.user_id, null);
});

test('sifremi unuttum: Apple gizli e-postasi kimlik olarak yazilsa da gonderim yok; yanit genel 200', async () => {
  const hidden = 'apple.0123456789abcdef01234567@users.noreply.invalid';
  // normalizeEmail .invalid alanini kabul eder (bicim gecerli) -> kullanici bulunur ama teslim edilemez
  store.addUser({ email: hidden, apple_id: 'apple-sifre' });
  const res = await post('forgot-password', { email: hidden });
  assert.strictEqual(res.status, 200, JSON.stringify(res.body));
  assert.deepStrictEqual(resetMails, []);
  assert.strictEqual(res.body.data.debug_code, undefined);
});

test('sifremi unuttum (telefon) - gercek e-postasi olan hesap: kod GERCEK e-postaya gider (degismedi)', async () => {
  const phone = '+905557770004';
  const u = store.addUser({ phone, email: 'telefonlu.gercek@example.com', password_hash: await bcrypt.hash('Eski-Parola-2026', 4) });
  const res = await post('forgot-password', { phone });
  assert.strictEqual(res.status, 200, JSON.stringify(res.body));
  assert.deepStrictEqual(resetMails, ['telefonlu.gercek@example.com']);
  assert.strictEqual(store.resets.filter((r) => r.user_id === u.id).length, 1);
});

test('debug OTP acikken bile yer tutucu hesaba debug_code DONMEZ (kayitsiz kimlik gibi)', async () => {
  process.env.ALLOW_DEBUG_OTP = 'true';
  const phone = '+905557770005';
  phoneUser(phone);
  const res = await post('forgot-password', { phone });
  assert.strictEqual(res.status, 200);
  assert.strictEqual(res.body.data.debug_code, undefined);
  assert.deepStrictEqual(resetMails, []);
});

test('sahte DB: eslesmeyen SQL yok', () => {
  assert.deepStrictEqual(store.unmatched, []);
});
