'use strict';

const test = require('node:test');
const assert = require('node:assert');
const express = require('express');
const request = require('supertest');

const { rateLimit, clientIp } = require('../../src/middlewares/rate_limit');
const rateLimitDefault = require('../../src/middlewares/rate_limit');

function appWith(limiter, status = 200) {
  const app = express();
  app.use(express.json());
  app.post('/x', limiter, (req, res) => res.status(status).json({ ok: true }));
  return app;
}

test('rate_limit: modul hem fonksiyon hem { rateLimit } olarak disa acilir', () => {
  assert.strictEqual(typeof rateLimitDefault, 'function');
  assert.strictEqual(rateLimitDefault, rateLimit);
});

test('rate_limit: max asilinca 429 + Retry-After + RATE_LIMITED', async () => {
  const limiter = rateLimit({ windowMs: 60_000, max: 3 });
  const app = appWith(limiter);
  for (let i = 0; i < 3; i++) {
    const ok = await request(app).post('/x');
    assert.strictEqual(ok.status, 200);
  }
  const res = await request(app).post('/x');
  assert.strictEqual(res.status, 429);
  assert.strictEqual(res.body.success, false);
  assert.strictEqual(res.body.code, 'RATE_LIMITED');
  assert.ok(Number(res.headers['retry-after']) >= 1);
  assert.ok(res.body.retry_after >= 1);
});

test('rate_limit: ozel code ve mesaj kullanilir', async () => {
  const limiter = rateLimit({ windowMs: 60_000, max: 0, code: 'PIN_RATE', message: 'yavas' });
  const res = await request(appWith(limiter)).post('/x');
  assert.strictEqual(res.status, 429);
  assert.strictEqual(res.body.code, 'PIN_RATE');
  assert.strictEqual(res.body.message, 'yavas');
});

test('rate_limit: pencere dolunca sayac sifirlanir (enjekte saat)', () => {
  let t = 1_000_000;
  const limiter = rateLimit({ windowMs: 1000, max: 2, now: () => t });
  assert.strictEqual(limiter.consume('k').allowed, true);
  assert.strictEqual(limiter.consume('k').allowed, true);
  assert.strictEqual(limiter.consume('k').allowed, false);
  t += 1001;
  assert.strictEqual(limiter.consume('k').allowed, true);
});

test('rate_limit: keyGenerator anahtarlari birbirinden ayirir', async () => {
  const limiter = rateLimit({ windowMs: 60_000, max: 1, keyGenerator: (req) => `u:${req.body.user}` });
  const app = appWith(limiter);
  assert.strictEqual((await request(app).post('/x').send({ user: 'a' })).status, 200);
  assert.strictEqual((await request(app).post('/x').send({ user: 'b' })).status, 200);
  assert.strictEqual((await request(app).post('/x').send({ user: 'a' })).status, 429);
});

test('rate_limit: keyGenerator hata firlatirsa IP anahtarina duser (sinirlama surer)', async () => {
  const limiter = rateLimit({ windowMs: 60_000, max: 1, keyGenerator: () => { throw new Error('x'); } });
  const app = appWith(limiter);
  assert.strictEqual((await request(app).post('/x')).status, 200);
  assert.strictEqual((await request(app).post('/x')).status, 429);
});

test('rate_limit: skipSuccessfulRequests yalnizca basarisiz istekleri sayar', async () => {
  const limiter = rateLimit({ windowMs: 60_000, max: 2, skipSuccessfulRequests: true });
  const okApp = appWith(limiter, 200);
  for (let i = 0; i < 5; i++) {
    assert.strictEqual((await request(okApp).post('/x')).status, 200);
  }
  const failLimiter = rateLimit({ windowMs: 60_000, max: 2, skipSuccessfulRequests: true });
  const failApp = appWith(failLimiter, 401);
  assert.strictEqual((await request(failApp).post('/x')).status, 401);
  assert.strictEqual((await request(failApp).post('/x')).status, 401);
  assert.strictEqual((await request(failApp).post('/x')).status, 429);
});

test('rate_limit: peek sayaci artirmaz, resetKey sifirlar', () => {
  const limiter = rateLimit({ windowMs: 60_000, max: 2 });
  assert.strictEqual(limiter.peek('z').allowed, true);
  limiter.consume('z');
  limiter.consume('z');
  assert.strictEqual(limiter.peek('z').allowed, false);
  assert.strictEqual(limiter.peek('z').allowed, false);
  limiter.resetKey('z');
  assert.strictEqual(limiter.peek('z').allowed, true);
});

test('rate_limit: bellek korumasi maxKeys asilmaz', () => {
  const limiter = rateLimit({ windowMs: 60_000, max: 5, maxKeys: 10 });
  for (let i = 0; i < 100; i++) limiter.consume(`k${i}`);
  assert.ok(limiter.size() <= 10, `size=${limiter.size()}`);
});

test('rate_limit: clientIp IPv4-mapped adresi sadeleştirir ve X-Forwarded-For okumaz', () => {
  assert.strictEqual(clientIp({ ip: '::ffff:10.0.0.5' }), '10.0.0.5');
  assert.strictEqual(
    clientIp({ ip: '1.2.3.4', headers: { 'x-forwarded-for': '9.9.9.9' } }),
    '1.2.3.4'
  );
  assert.strictEqual(clientIp({ socket: { remoteAddress: '5.6.7.8' } }), '5.6.7.8');
});
