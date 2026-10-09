'use strict';

// CONTRACTS §3f: POST /api/v1/devices/bootstrap (ve /api) - rota katmani. JWT YOK. Oran siniri: kart basina saatte 6,
// IP basina saatte 60 (asimda 429). Servisin {http, body} sonucu AYNEN yazilir (200/202/401 govdeleri sozlesmede ham,
// {success,data} zarfi YOK). Is mantigi: bootstrap_service_pg.test.js; saf yardimcilar: bootstrap_sig.test.js.

const test = require('node:test');
const assert = require('node:assert/strict');
const express = require('express');
const request = require('supertest');

const { createRouter } = require('../../src/routes/device_bootstrap_routes');
const { DENIED_BODY } = require('../../src/services/device_bootstrap_service');
const { errorHandler } = require('../../src/middlewares/error_handler');

function build(result = { http: 202, body: { status: 'pending' } }) {
  const calls = [];
  const svc = {
    async bootstrap(args) {
      calls.push(args);
      return typeof result === 'function' ? result(args) : result;
    },
  };
  const router = createRouter({ bootstrapService: svc });
  const app = express();
  app.set('trust proxy', true);
  app.use(express.json());
  app.use('/api/v1', router);
  app.use('/api', router);
  app.use(errorHandler);
  return { app, calls, router };
}

const BODY = { device_uuid: 'AHBU-S3-DD8754', ts: 1791460000, nonce: 'a'.repeat(32), fw: '1.3.0', sig: 'b'.repeat(64) };

test('JWT gerekmez; govde + IP servise gider; 202 ham govde; no-store', async () => {
  const { app, calls } = build();
  const res = await request(app).post('/api/v1/devices/bootstrap').set('X-Forwarded-For', '203.0.113.7').send(BODY);
  assert.equal(res.status, 202);
  assert.deepEqual(res.body, { status: 'pending' });
  assert.match(res.headers['cache-control'], /no-store/);
  assert.deepEqual(calls[0].body, BODY);
  assert.equal(calls[0].ip, '203.0.113.7');
});

test('200 ham govde {status, mqtt}; eski /api oneki de calisir', async () => {
  const ok = { http: 200, body: { status: 'ok', mqtt: { host: 'mqtt.example.test', port: 8883, username: 'd_x', password: 'p' } } };
  const { app } = build(ok);
  const res = await request(app).post('/api/devices/bootstrap').send(BODY);
  assert.equal(res.status, 200);
  assert.deepEqual(res.body, ok.body);
});

test('401 govdesi sabit (neden sizmaz)', async () => {
  const { app } = build({ http: 401, body: DENIED_BODY });
  const res = await request(app).post('/api/v1/devices/bootstrap').send(BODY);
  assert.equal(res.status, 401);
  assert.deepEqual(res.body, DENIED_BODY);
  assert.equal(DENIED_BODY.code, 'BOOTSTRAP_DENIED');
  assert.deepEqual(Object.keys(DENIED_BODY).sort(), ['code', 'message', 'success']);
});

test('oran siniri (bireysel-6): ayni kart icin saatte 20 DOGRULANMIS istek (21. istek 429, servis cagrilmaz); kart kimligi buyuk/kucuk harf duyarsiz', async () => {
  const { app, calls } = build();
  for (let i = 0; i < 20; i += 1) {
    const uuid = i % 2 ? BODY.device_uuid.toLowerCase() : BODY.device_uuid;
    const r = await request(app).post('/api/v1/devices/bootstrap').set('X-Forwarded-For', `198.51.100.${i + 1}`).send({ ...BODY, device_uuid: uuid });
    assert.equal(r.status, 202, `istek ${i + 1}`);
  }
  const r21 = await request(app).post('/api/v1/devices/bootstrap').set('X-Forwarded-For', '198.51.100.99').send(BODY);
  assert.equal(r21.status, 429);
  assert.equal(r21.body.code, 'RATE_LIMITED');
  assert.ok(Number(r21.headers['retry-after']) > 0);
  assert.equal(calls.length, 20);
  // baska kart etkilenmez
  const other = await request(app).post('/api/v1/devices/bootstrap').set('X-Forwarded-For', '198.51.100.99').send({ ...BODY, device_uuid: 'AHBU-S3-000001' });
  assert.equal(other.status, 202);
});

test('oran siniri (bireysel-6): imzasi dogrulanmayan (401) istekler kart butcesini HARCAMAZ; 7 sahte istekten sonra gecerli istek gecer', async () => {
  let forged = true;
  const { app, calls } = build(() => (forged ? { http: 401, body: DENIED_BODY } : { http: 202, body: { status: 'pending' } }));
  for (let i = 0; i < 7; i += 1) {
    const r = await request(app).post('/api/v1/devices/bootstrap').set('X-Forwarded-For', `198.51.101.${i + 1}`).send(BODY);
    assert.equal(r.status, 401, `sahte ${i + 1}`);
  }
  forged = false;
  const ok = await request(app).post('/api/v1/devices/bootstrap').set('X-Forwarded-For', '198.51.101.50').send(BODY);
  assert.equal(ok.status, 202, 'gecerli istek hala kabul edilir');
  assert.equal(calls.length, 8);
  // cok sayida sahte istek de (IP siniri altinda kaldigi surece) karti kilitlemez
  forged = true;
  for (let i = 0; i < 25; i += 1) {
    await request(app).post('/api/v1/devices/bootstrap').set('X-Forwarded-For', `198.51.102.${i + 1}`).send(BODY);
  }
  forged = false;
  const still = await request(app).post('/api/v1/devices/bootstrap').set('X-Forwarded-For', '198.51.101.51').send(BODY);
  assert.equal(still.status, 202);
});

test('sozlesme-1 (C7): IP butcesini yalniz basarisiz (200/202 disi) istekler harcar; ortak NAT arkasinda 61 sahiplenilmemis kart 202 alir', async () => {
  const { app, calls } = build();
  for (let i = 0; i < 61; i += 1) {
    const r = await request(app).post('/api/v1/devices/bootstrap').set('X-Forwarded-For', '192.0.2.10').send({ ...BODY, device_uuid: `AHBU-IP-${String(i).padStart(4, '0')}` });
    assert.equal(r.status, 202, `istek ${i + 1}`);
  }
  assert.equal(calls.length, 61);
  // 200 (sahiplenilmis pano kimligini alir) de harcamaz
  const ok = build({ http: 200, body: { status: 'ok', mqtt: { host: 'h', port: 8883, username: 'd_x', password: 'p' } } });
  for (let i = 0; i < 61; i += 1) {
    const r = await request(ok.app).post('/api/v1/devices/bootstrap').set('X-Forwarded-For', '192.0.2.12').send({ ...BODY, device_uuid: `AHBU-OK-${String(i).padStart(4, '0')}` });
    assert.equal(r.status, 200, `istek ${i + 1}`);
  }
});

test('oran siniri: ayni IP icin saatte 60 BASARISIZ istek (61. istek 429, servis cagrilmaz); butce doluyken gecerli imzali istek de 429 (once bakilir)', async () => {
  let verdict = { http: 401, body: DENIED_BODY };
  const { app, calls } = build(() => verdict);
  for (let i = 0; i < 60; i += 1) {
    const r = await request(app).post('/api/v1/devices/bootstrap').set('X-Forwarded-For', '192.0.2.10').send({ ...BODY, device_uuid: `AHBU-IP-${String(i).padStart(4, '0')}` });
    assert.equal(r.status, 401, `istek ${i + 1}`);
  }
  const r61 = await request(app).post('/api/v1/devices/bootstrap').set('X-Forwarded-For', '192.0.2.10').send({ ...BODY, device_uuid: 'AHBU-IP-9999' });
  assert.equal(r61.status, 429);
  assert.equal(r61.body.code, 'RATE_LIMITED');
  assert.ok(Number(r61.headers['retry-after']) > 0);
  assert.equal(calls.length, 60, '61. istek servise gitmez');
  verdict = { http: 202, body: { status: 'pending' } };
  const valid = await request(app).post('/api/v1/devices/bootstrap').set('X-Forwarded-For', '192.0.2.10').send({ ...BODY, device_uuid: 'AHBU-IP-8888' });
  assert.equal(valid.status, 429, 'IP butcesi doluyken gecerli istek de reddedilir');
  assert.equal(calls.length, 60);
  const otherIp = await request(app).post('/api/v1/devices/bootstrap').set('X-Forwarded-For', '192.0.2.11').send({ ...BODY, device_uuid: 'AHBU-IP-9999' });
  assert.equal(otherIp.status, 202);
});

test('gecersiz govde (dizi / bos) servise yine gider (401 karari serviste; neden sizmaz)', async () => {
  const { app, calls } = build({ http: 401, body: DENIED_BODY });
  const res = await request(app).post('/api/v1/devices/bootstrap').send('[1,2]').set('Content-Type', 'application/json');
  assert.equal(res.status, 401);
  assert.deepEqual(calls[0].body, {});
});

test('servis hatasi: 500 genel (401 degil, ic ayrinti yok)', async () => {
  const { app } = build(() => {
    throw new Error('veritabani yok');
  });
  const res = await request(app).post('/api/v1/devices/bootstrap').send(BODY);
  assert.equal(res.status, 500);
  assert.doesNotMatch(JSON.stringify(res.body), /veritabani/);
});

test('server.createApp: /api/v1 ve /api altinda bagli; JWT istemez (401 BOOTSTRAP_DENIED, INVALID_TOKEN degil)', async () => {
  const { createApp } = require('../../src/server');
  const db = { query: async () => ({ rows: [] }), withTransaction: async (fn) => fn({ query: async () => ({ rows: [] }) }) };
  const app = createApp({ db, mqttBridge: { isConnected: () => false } });
  for (const p of ['/api/v1/devices/bootstrap', '/api/devices/bootstrap']) {
    const res = await request(app).post(p).send({ device_uuid: 'AHBU-S3-000009' });
    assert.equal(res.status, 401, p);
    assert.deepEqual(res.body, DENIED_BODY);
  }
});
