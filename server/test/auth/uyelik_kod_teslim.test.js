'use strict';

// UYELIK-K1 (karar D10): requestPasswordReset ve sendPhoneOtp'ta onceki GECERLI kodlar yalniz YENI kod BASARIYLA
// teslim edildikten sonra kapatilir. Teslim basarisizsa yalniz YENI kod iptal edilir, ESKI kod (ve sifirlama
// baglantisi) gecerli kalir; yanit aynen 503 DELIVERY_FAILED. Kullanici "Tekrar Kod Iste" 503 aldiginda elindeki
// 15 dk gecerli eski kodla devam edebilir.

const test = require('node:test');
const assert = require('node:assert');
const express = require('express');
const request = require('supertest');
const bcrypt = require('bcryptjs');
const { setTestEnv, installFakeDb } = require('./_helpers');
const { createAuthStore } = require('./_auth_store');

setTestEnv({ BCRYPT_TEST_COST: '4' });
const fakeDb = installFakeDb();
let clock = Date.now();
const store = createAuthStore({ now: () => clock }).install(fakeDb);

const authRoutes = require('../../src/routes/auth_routes');
const authService = require('../../src/services/auth_service');
const mailer = require('../../src/utils/mailer');
const { errorHandler } = require('../../src/middlewares/error_handler');

const app = express();
app.use(express.json());
app.use('/api/v1/auth', authRoutes);
app.use(errorHandler);
const server = app.listen(0, '127.0.0.1');
test.after(() => new Promise((resolve) => server.close(() => resolve())));

const post = (path, body) => request(server).post(`/api/v1/auth/${path}`).send(body || {});
const advance = (sec) => { clock += sec * 1000; };

const smtp = { fail: false, sent: [] };
const sms = { fail: false, sent: [] };

test.beforeEach(() => {
  for (const l of Object.values(authRoutes.limiters)) l.reset();
  delete process.env.ALLOW_DEBUG_OTP;
  process.env.NODE_ENV = 'test';
  smtp.fail = false;
  smtp.sent.length = 0;
  sms.fail = false;
  sms.sent.length = 0;
  mailer.setTransportFactory(() => ({
    sendMail: async (msg) => {
      if (smtp.fail) throw Object.assign(new Error('smtp gecici ariza'), { code: 'ETIMEDOUT' });
      smtp.sent.push(msg);
      return { messageId: 'x' };
    },
  }));
  authService.setSmsSender(async (phone, text) => {
    if (sms.fail) throw new Error('sms saglayici ariza');
    sms.sent.push({ phone, text });
    return { sent: true };
  });
  advance(3600);
});

const lastMailCode = () => smtp.sent.at(-1).text.match(/kodunuz: (\d{6})/)[1];
const lastMailToken = () => decodeURIComponent(smtp.sent.at(-1).text.match(/#token=([^\s]+)/)[1]);
const lastSmsCode = () => sms.sent.at(-1).text.match(/(\d{6})/)[1];

async function makeUser(email) {
  return store.addUser({ email, password_hash: await bcrypt.hash('Eski-Parola-2026', 4) });
}

// ============================== SIFRE SIFIRLAMA ==============================
test('sifirlama: yeni kod teslim EDILEMEZSE 503 ve ESKI kod gecerli kalir (yeni kod iptal)', async () => {
  await makeUser('k1.kod@example.com');
  assert.strictEqual((await post('forgot-password', { email: 'k1.kod@example.com' })).status, 200);
  const code1 = lastMailCode();

  advance(61);
  smtp.fail = true;
  const again = await post('forgot-password', { email: 'k1.kod@example.com' });
  assert.strictEqual(again.status, 503);
  assert.strictEqual(again.body.code, 'DELIVERY_FAILED');
  const rows = store.resets.filter((r) => r.identifier === 'k1.kod@example.com');
  assert.strictEqual(rows.length, 2);
  assert.ok(rows[1].used_at, 'teslim edilemeyen YENI kod iptal');
  assert.strictEqual(rows[0].used_at, null, 'ESKI kod gecerli kalir');

  const ok = await post('reset-password', { email: 'k1.kod@example.com', code: code1, new_password: 'Yeni-Parola-2026' });
  assert.strictEqual(ok.status, 200, JSON.stringify(ok.body));
});

test('sifirlama: teslim basarisizsa ESKI baglanti (token) da gecerli kalir', async () => {
  await makeUser('k1.link@example.com');
  await post('forgot-password', { email: 'k1.link@example.com' });
  const token1 = lastMailToken();
  advance(61);
  smtp.fail = true;
  assert.strictEqual((await post('forgot-password', { email: 'k1.link@example.com' })).status, 503);
  const ok = await post('reset-password', { token: token1, new_password: 'Baglanti-Parola-1' });
  assert.strictEqual(ok.status, 200, JSON.stringify(ok.body));
});

test('sifirlama: yeni kod TESLIM EDILINCE eski kod ve eski baglanti gecersiz olur; yeni kod calisir', async () => {
  await makeUser('k1.yeni@example.com');
  await post('forgot-password', { email: 'k1.yeni@example.com' });
  const code1 = lastMailCode();
  const token1 = lastMailToken();
  advance(61);
  assert.strictEqual((await post('forgot-password', { email: 'k1.yeni@example.com' })).status, 200);
  const code2 = lastMailCode();
  const rows = store.resets.filter((r) => r.identifier === 'k1.yeni@example.com');
  assert.ok(rows[0].used_at, 'eski talep kapatildi');
  assert.strictEqual(rows[1].used_at, null, 'yeni talep acik');

  assert.strictEqual((await post('reset-password', { token: token1, new_password: 'Baglanti-Parola-2' })).status, 400);
  if (code1 !== code2) {
    const old = await post('reset-password', { email: 'k1.yeni@example.com', code: code1, new_password: 'Yeni-Parola-2026' });
    assert.strictEqual(old.status, 400);
  }
  const ok = await post('reset-password', { email: 'k1.yeni@example.com', code: code2, new_password: 'Yeni-Parola-2026' });
  assert.strictEqual(ok.status, 200, JSON.stringify(ok.body));
});

test('sifirlama: kayitsiz kimlikte yanit ve sinirlar degismez (her talep kullanicisiz satir)', async () => {
  const id = 'k1.kayitsiz@example.com';
  assert.strictEqual((await post('forgot-password', { email: id })).status, 200);
  assert.strictEqual((await post('forgot-password', { email: id })).status, 429);
  assert.ok(store.resets.filter((r) => r.identifier === id).every((r) => r.user_id === null));
});

// ============================== TELEFON OTP ==============================
test('telefon OTP: yeni SMS gonderilemezse 503 ve ESKI kod gecerli kalir (yeni kod iptal)', async () => {
  const phone = '+905558880001';
  assert.strictEqual((await post('otp/send', { phone })).status, 200);
  const code1 = lastSmsCode();

  advance(61);
  sms.fail = true;
  const again = await post('otp/send', { phone });
  assert.strictEqual(again.status, 503);
  assert.strictEqual(again.body.code, 'DELIVERY_FAILED');
  const rows = store.otps.filter((o) => o.phone === phone);
  assert.ok(rows[1].consumed_at, 'teslim edilemeyen YENI kod iptal');
  assert.strictEqual(rows[0].consumed_at, null, 'ESKI kod gecerli kalir');

  const ok = await post('otp/verify', { phone, code: code1 });
  assert.strictEqual(ok.status, 200, JSON.stringify(ok.body));
});

test('telefon OTP: yeni kod TESLIM EDILINCE eski kod gecersiz; yeni kod calisir', async () => {
  const phone = '+905558880002';
  await post('otp/send', { phone });
  const code1 = lastSmsCode();
  advance(61);
  assert.strictEqual((await post('otp/send', { phone })).status, 200);
  const code2 = lastSmsCode();
  const rows = store.otps.filter((o) => o.phone === phone);
  assert.ok(rows[0].consumed_at, 'eski kod kapatildi');
  assert.strictEqual(rows[1].consumed_at, null);
  if (code1 !== code2) assert.strictEqual((await post('otp/verify', { phone, code: code1 })).status, 401);
  assert.strictEqual((await post('otp/verify', { phone, code: code2 })).status, 200);
});

test('sahte DB: eslesmeyen SQL yok', () => {
  assert.deepStrictEqual(store.unmatched, []);
});
