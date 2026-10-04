'use strict';

// UYELIK-04 (karar D6): GET /api/v1/auth/capabilities (ve /api/auth/capabilities) - kimliksiz, hafif IP hiz siniri,
// 'Cache-Control: no-store'. Yanit { success:true, data:{ sms_otp, google, apple } } (yalniz boolean):
//   sms_otp = SMS gonderici bagli VEYA debug OTP izinli (ALLOW_DEBUG_OTP=true ve NODE_ENV!=='production')
//   google / apple = sunucu o yolu 503 SERVICE_UNAVAILABLE vermeden calistirabilir (GOOGLE_CLIENT_IDS / APPLE_CLIENT_IDS)
// Istemci giris ekraninda calismayan yollari bu bilgiyle gizler. Degerler auth_service'in 503 kosullarindan
// TURETILIR: yetenek false iken ilgili uc gercekten 503 verir, true iken vermez (tutarlilik testleri).

const test = require('node:test');
const assert = require('node:assert');
const express = require('express');
const request = require('supertest');
const { setTestEnv, installFakeDb } = require('./_helpers');
const { createAuthStore } = require('./_auth_store');

setTestEnv({ BCRYPT_TEST_COST: '4' });
const fakeDb = installFakeDb();
const store = createAuthStore().install(fakeDb);

const authRoutes = require('../../src/routes/auth_routes');
const authService = require('../../src/services/auth_service');
const { errorHandler } = require('../../src/middlewares/error_handler');

const app = express();
app.use(express.json());
app.use('/api/v1/auth', authRoutes);
app.use('/api/auth', authRoutes);
app.use(errorHandler);
const server = app.listen(0, '127.0.0.1');
test.after(() => new Promise((resolve) => server.close(() => resolve())));

const caps = (prefix = '/api/v1/auth') => request(server).get(`${prefix}/capabilities`);

test.beforeEach(() => {
  for (const l of Object.values(authRoutes.limiters)) l.reset();
  process.env.NODE_ENV = 'test';
  delete process.env.ALLOW_DEBUG_OTP;
  delete process.env.GOOGLE_CLIENT_IDS;
  delete process.env.APPLE_CLIENT_IDS;
  authService.setSmsSender(null);
});

test('uretim ortami, SMS gonderici YOK (ALLOW_DEBUG_OTP=true olsa bile) -> sms_otp false; OAuth yapilandirmasi yok -> google/apple false', async () => {
  process.env.NODE_ENV = 'production';
  process.env.ALLOW_DEBUG_OTP = 'true';
  const res = await caps();
  assert.strictEqual(res.status, 200, JSON.stringify(res.body));
  assert.strictEqual(res.body.success, true);
  assert.deepStrictEqual(res.body.data, { sms_otp: false, google: false, apple: false });
  assert.strictEqual(res.headers['cache-control'], 'no-store');
  // tutarlilik: yetenek false -> uc gercekten 503
  const otp = await request(server).post('/api/v1/auth/otp/send').send({ phone: '+905550001111' });
  assert.strictEqual(otp.status, 503);
  assert.strictEqual(otp.body.code, 'DELIVERY_FAILED');
});

test('kimlik gerektirmez (Authorization yok / gecersiz Bearer yok sayilir)', async () => {
  const res = await caps().set('Authorization', 'Bearer gecersiz.jeton.degeri');
  assert.strictEqual(res.status, 200);
  assert.strictEqual(typeof res.body.data.sms_otp, 'boolean');
});

test('sms_otp: SMS gonderici bagliysa uretimde de true; gelistirmede debug OTP acikken true', async () => {
  process.env.NODE_ENV = 'production';
  authService.setSmsSender(async () => ({ sent: true }));
  assert.strictEqual((await caps()).body.data.sms_otp, true);

  authService.setSmsSender(null);
  process.env.NODE_ENV = 'test';
  process.env.ALLOW_DEBUG_OTP = 'true';
  assert.strictEqual((await caps()).body.data.sms_otp, true);
  const otp = await request(server).post('/api/v1/auth/otp/send').send({ phone: '+905550002222' });
  assert.strictEqual(otp.status, 200, 'yetenek true -> uc calisir');

  process.env.ALLOW_DEBUG_OTP = 'false';
  assert.strictEqual((await caps()).body.data.sms_otp, false);
});

test('google / apple: istemci kimligi listesi doluysa true; bos/yalniz virgul ise false ve uc 503 verir', async () => {
  process.env.GOOGLE_CLIENT_IDS = ' , ';
  process.env.APPLE_CLIENT_IDS = '';
  let res = await caps();
  assert.deepStrictEqual([res.body.data.google, res.body.data.apple], [false, false]);
  assert.strictEqual((await request(server).post('/api/v1/auth/google').send({ id_token: 'x'.repeat(40) })).status, 503);
  assert.strictEqual((await request(server).post('/api/v1/auth/apple').send({ identity_token: 'x'.repeat(40) })).status, 503);

  process.env.GOOGLE_CLIENT_IDS = 'a.apps.googleusercontent.com';
  process.env.APPLE_CLIENT_IDS = 'com.ahbu.evotomasyon';
  res = await caps();
  assert.deepStrictEqual([res.body.data.google, res.body.data.apple], [true, true]);
  // yetenek true -> 503 YOK (eksik jeton 400)
  assert.strictEqual((await request(server).post('/api/v1/auth/google').send({})).status, 400);
  assert.strictEqual((await request(server).post('/api/v1/auth/apple').send({})).status, 400);
});

test('/api/auth/capabilities takma yolu; yanit yalniz uc boolean alan tasir', async () => {
  const res = await caps('/api/auth');
  assert.strictEqual(res.status, 200);
  assert.deepStrictEqual(Object.keys(res.body.data).sort(), ['apple', 'google', 'sms_otp']);
  for (const v of Object.values(res.body.data)) assert.strictEqual(typeof v, 'boolean');
  assert.strictEqual(res.headers['cache-control'], 'no-store');
});

test('hafif IP hiz siniri: sinir asilinca 429 RATE_LIMITED + Retry-After (giris sinirindan siki degil)', async () => {
  const limiter = authRoutes.limiters.capabilities;
  assert.ok(limiter, 'capabilities sinirlayicisi tanimli olmali');
  const max = limiter.options.max;
  assert.ok(max >= authRoutes.limiters.login.options.max, `hafif sinir (max=${max})`);
  for (let i = 0; i < max; i++) assert.strictEqual((await caps()).status, 200, `istek ${i + 1}`);
  const limited = await caps();
  assert.strictEqual(limited.status, 429);
  assert.strictEqual(limited.body.code, 'RATE_LIMITED');
  assert.ok(Number(limited.headers['retry-after']) >= 1);
});

test('yalniz GET: POST /capabilities 404', async () => {
  assert.strictEqual((await request(server).post('/api/v1/auth/capabilities').send({})).status, 404);
});

test('sahte DB: eslesmeyen SQL yok', () => {
  assert.deepStrictEqual(store.unmatched, []);
});
