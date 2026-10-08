'use strict';

// A2: server.js - yapilandirma (fail-closed), saglik uclari, hata bicimi, CORS, helmet, govde siniri.

const test = require('node:test');
const assert = require('node:assert');
const crypto = require('crypto');
const request = require('supertest');
const express = require('express');
const { setTestEnv, installFakeDb } = require('./_helpers');

setTestEnv({ LOCAL_KEY_SECRET: crypto.randomBytes(32).toString('hex'), CORS_ORIGINS: 'https://panel.example.test' });
const fakeDb = installFakeDb();

const fakeBridge = {
  connected: true,
  isConnected() { return this.connected; },
  init() {},
  end: async () => {},
};

const { createApp, validateConfig, parseTrustProxy } = require('../../src/server');
const { errorHandler } = require('../../src/middlewares/error_handler');
const { HttpError } = require('../../src/utils/helpers');

const app = createApp({ db: fakeDb, mqttBridge: fakeBridge });

function withEnv(vars, fn) {
  const saved = {};
  for (const k of Object.keys(vars)) saved[k] = process.env[k];
  try {
    for (const [k, v] of Object.entries(vars)) {
      if (v === undefined) delete process.env[k];
      else process.env[k] = v;
    }
    return fn();
  } finally {
    for (const [k, v] of Object.entries(saved)) {
      if (v === undefined) delete process.env[k];
      else process.env[k] = v;
    }
  }
}

test('validateConfig: tum zorunlu degerler varken gecer', () => {
  assert.strictEqual(validateConfig(), true);
});

test('validateConfig: JWT_SECRET yok / kisa -> sunucu BASLAMAZ', () => {
  withEnv({ JWT_SECRET: undefined }, () => assert.throws(() => validateConfig(), /JWT_SECRET/));
  withEnv({ JWT_SECRET: 'kisa-sir' }, () => assert.throws(() => validateConfig(), /JWT_SECRET/));
  withEnv({ JWT_SECRET: 'x'.repeat(31) }, () => assert.throws(() => validateConfig(), /JWT_SECRET/));
});

test('validateConfig: PIN_PEPPER yok / kisa -> sunucu BASLAMAZ', () => {
  withEnv({ PIN_PEPPER: undefined }, () => assert.throws(() => validateConfig(), /PIN_PEPPER/));
  withEnv({ PIN_PEPPER: 'kisa' }, () => assert.throws(() => validateConfig(), /PIN_PEPPER/));
});

test('validateConfig: LOCAL_KEY_SECRET yok / gecersiz -> sunucu BASLAMAZ', () => {
  withEnv({ LOCAL_KEY_SECRET: undefined }, () => assert.throws(() => validateConfig(), /LOCAL_KEY_SECRET/));
  withEnv({ LOCAL_KEY_SECRET: 'zz' }, () => assert.throws(() => validateConfig(), /LOCAL_KEY_SECRET/));
});

test('trust proxy ayrisma: varsayilan loopback', () => {
  assert.strictEqual(parseTrustProxy(undefined), 'loopback');
  assert.strictEqual(parseTrustProxy('1'), 1);
  assert.strictEqual(parseTrustProxy('false'), false);
  assert.strictEqual(app.get('trust proxy'), 'loopback');
});

test('/health: 200, ic hata/bilesen metni YOK', async () => {
  fakeDb.on(/SELECT 1/, () => new Error('connect ECONNREFUSED 10.0.0.9:5432 secret-host'));
  const res = await request(app).get('/health');
  assert.strictEqual(res.status, 200);
  assert.strictEqual(res.body.status, 'ok');
  assert.ok(!JSON.stringify(res.body).includes('ECONNREFUSED'));
});

test('/ready: DB yoksa 503 + yalnizca up/down (hata metni yok)', async () => {
  fakeDb.on(/SELECT 1/, () => new Error('connect ECONNREFUSED 10.0.0.9:5432 secret-host'));
  const res = await request(app).get('/ready');
  assert.strictEqual(res.status, 503);
  assert.deepStrictEqual(res.body.components, { database: 'down', mqtt_bridge: 'up' });
  assert.ok(!JSON.stringify(res.body).includes('secret-host'));
});

test('/ready: DB varsa 200', async () => {
  fakeDb.on(/SELECT 1/, () => [{ ok: 1 }]);
  const res = await request(app).get('/ready');
  assert.strictEqual(res.status, 200);
  assert.strictEqual(res.body.status, 'ready');
});

test('404: sozlesme bicimi', async () => {
  const res = await request(app).get('/api/v1/yok-boyle-bir-uc');
  assert.strictEqual(res.status, 404);
  assert.strictEqual(res.body.success, false);
  assert.strictEqual(res.body.code, 'NOT_FOUND');
});

test('bireysel-9: etiket karekodu / sifirlama / giris baglantisi tarayicida statik Turkce sayfa; sorgu/yol YANSITILMAZ; guvenli basliklar', async () => {
  const urls = [
    '/claim?uid=AHBU-S3-ABC123&pin=123456',
    '/reset-password?token=gizli-belirtec-degeri-777',
    '/magic-login',
    '/magic-login/gizli-sihirli-belirtec-888',
  ];
  for (const url of urls) {
    const res = await request(app).get(url);
    assert.strictEqual(res.status, 200, url);
    assert.match(String(res.headers['content-type']), /^text\/html; charset=utf-8/i, url);
    const body = res.text;
    assert.ok(body.includes('Bu bağlantı AHBU uygulamasında açılmalıdır.'), url);
    assert.ok(body.includes('Karekod Tara'), url);
    for (const secret of ['AHBU-S3-ABC123', '123456', 'gizli-belirtec-degeri-777', 'gizli-sihirli-belirtec-888', 'uid=', 'pin=']) {
      assert.ok(!body.includes(secret), `${url}: ${secret} yansitilmamali`);
    }
    assert.strictEqual(res.headers['cache-control'], 'no-store', url);
    assert.strictEqual(res.headers['referrer-policy'], 'no-referrer', url);
    assert.strictEqual(res.headers['x-content-type-options'], 'nosniff', url);
    assert.strictEqual(res.headers['content-security-policy'], "default-src 'none'; style-src 'unsafe-inline'", url);
  }
  // API altindaki bilinmeyen yol JSON 404 kalir; GET /api/v1/auth/magic-login/:token 405 AYNEN
  const api404 = await request(app).get('/api/v1/claim?uid=AHBU-S3-ABC123&pin=123456');
  assert.strictEqual(api404.status, 404);
  assert.strictEqual(api404.body.code, 'NOT_FOUND');
  const m = await request(app).get('/api/v1/auth/magic-login/abc');
  assert.strictEqual(m.status, 405);
  assert.strictEqual(m.body.code, 'METHOD_NOT_ALLOWED');
  // POST /claim (tarayici disi) sayfa uretmez
  assert.strictEqual((await request(app).post('/claim').send({})).status, 404);
});

test('govde siniri 256 KB -> 413 PAYLOAD_TOO_LARGE', async () => {
  const big = { x: 'a'.repeat(300 * 1024) };
  const res = await request(app).post('/api/v1/auth/login').send(big);
  assert.strictEqual(res.status, 413);
  assert.strictEqual(res.body.code, 'PAYLOAD_TOO_LARGE');
});

test('bozuk JSON -> 400 VALIDATION', async () => {
  const res = await request(app).post('/api/v1/auth/login').set('Content-Type', 'application/json').send('{"a":');
  assert.strictEqual(res.status, 400);
  assert.strictEqual(res.body.code, 'VALIDATION');
});

test('CORS: izinsiz origin -> 403; izinli origin -> CORS basligi; Origin yok (mobil) -> etkilenmez', async () => {
  const bad = await request(app).get('/health').set('Origin', 'https://evil.example');
  assert.strictEqual(bad.status, 403);
  const good = await request(app).get('/health').set('Origin', 'https://panel.example.test');
  assert.strictEqual(good.status, 200);
  assert.strictEqual(good.headers['access-control-allow-origin'], 'https://panel.example.test');
  const mobile = await request(app).get('/health');
  assert.strictEqual(mobile.status, 200);
  assert.strictEqual(mobile.headers['access-control-allow-origin'], undefined);
});

test('helmet basliklari ve x-powered-by yok', async () => {
  const res = await request(app).get('/health');
  assert.strictEqual(res.headers['x-powered-by'], undefined);
  assert.strictEqual(res.headers['x-content-type-options'], 'nosniff');
  assert.ok(res.headers['content-security-policy']);
});

test('eski /api/... takma yollari calisir (auth, homes)', async () => {
  const a = await request(app).post('/api/auth/login').send({});
  assert.strictEqual(a.status, 400);
  const b = await request(app).get('/api/homes');
  assert.strictEqual(b.status, 401);
  const c = await request(app).post('/api/homes/join').send({ code: 'x' });
  assert.strictEqual(c.status, 401);
});

test('yonlendirme: sozlesme uclari dogru router a ulasir (v1 + eski /api takma yolu)', async () => {
  const H = '11111111-2222-4333-8444-555555555555';
  const routes = [
    ['post', `/homes/${H}/mqtt-credentials`],
    ['get', `/homes/${H}/devices`],
    ['post', `/homes/${H}/commissioning`],
    ['get', `/homes/${H}/commissioning-status`],
    ['post', `/homes/${H}/service-token`],
    ['get', `/homes/${H}/service-tokens`],
    ['get', `/homes/${H}/scheduled-rules`],
    ['get', `/homes/${H}/endpoints`],
    ['post', `/homes/${H}/invitations`],
    ['get', `/homes/${H}/members`],
    ['post', `/homes/${H}/transfer-initiate`],
    ['post', '/homes/join'],
    ['post', '/homes/transfer-accept'],
    ['post', '/devices/AHBU-X1/command'],
    ['post', '/devices/claim'],
    ['get', '/homes'],
    ['get', '/auth/me'],
    ['get', '/admin/users'],
  ];
  for (const prefix of ['/api/v1', '/api']) {
    for (const [method, path] of routes) {
      const res = await request(app)[method](prefix + path).send({});
      assert.strictEqual(res.status, 401, `${method.toUpperCase()} ${prefix}${path} -> ${res.status}`);
    }
  }
  const inv = await request(app).get('/api/v1/admin/inventory');
  assert.strictEqual(inv.status, 401);
});

test('yonlendirme: /homes/join bir homeId sanilmaz (ev router larindan once baglanir)', async () => {
  const crypto2 = require('crypto');
  const uid = crypto2.randomUUID();
  fakeDb.on(/FROM users\s+WHERE id = \$1/, (p) => (p[0] === uid ? [{ id: uid, email: 'j@test.invalid', full_name: 'j', role: 'user', is_active: true, account_status: 'active', token_version: 1 }] : []));
  const { makeAccessToken } = require('./_helpers');
  const tok = makeAccessToken({ id: uid, role: 'user', token_version: 1 });
  const res = await request(app).post('/api/v1/homes/join').set('Authorization', `Bearer ${tok}`).send({ code: 'kisa' });
  assert.strictEqual(res.status, 400);
  assert.match(res.body.message, /davet/i);
});

test('yonlendirme: bilinmeyen ev alt yolu 404 (401 degil)', async () => {
  const res = await request(app).get('/api/v1/homes/11111111-2222-4333-8444-555555555555/yok-boyle');
  assert.strictEqual(res.status, 404);
});

test('hata yakalayici: 5xx ic mesaj SIZMAZ; HttpError 4xx mesaj/kod gecer; retry_after', async () => {
  const mini = express();
  mini.get('/boom', () => { throw new Error('duplicate key value violates unique constraint "users_email_key"'); });
  mini.get('/sys', () => { const e = new Error('connect ECONNREFUSED'); e.code = 'ECONNREFUSED'; throw e; });
  mini.get('/http', () => { throw new HttpError(409, 'Cakisma var', 'CONFLICT'); });
  mini.get('/rl', () => { const e = new HttpError(429, 'Yavas', 'RATE_LIMITED'); e.retryAfter = 42; throw e; });
  mini.get('/legacy', () => { const e = new Error('Eski 400 mesaji'); e.statusCode = 400; throw e; });
  mini.get('/svc', () => { const e = new HttpError(503, 'gizli ic ayrinti', 'DELIVERY_FAILED'); throw e; });
  mini.get('/svc-exposed', () => { const e = new HttpError(503, 'Gosterilebilir metin', 'DELIVERY_FAILED'); e.expose = true; throw e; });
  mini.use(errorHandler);

  const boom = await request(mini).get('/boom');
  assert.strictEqual(boom.status, 500);
  assert.strictEqual(boom.body.code, 'INTERNAL');
  assert.ok(!JSON.stringify(boom.body).includes('users_email_key'));

  const sys = await request(mini).get('/sys');
  assert.strictEqual(sys.body.code, 'INTERNAL');

  const http = await request(mini).get('/http');
  assert.strictEqual(http.status, 409);
  assert.deepStrictEqual(http.body, { success: false, message: 'Cakisma var', code: 'CONFLICT' });

  const rl = await request(mini).get('/rl');
  assert.strictEqual(rl.status, 429);
  assert.strictEqual(rl.headers['retry-after'], '42');
  assert.strictEqual(rl.body.retry_after, 42);

  const legacy = await request(mini).get('/legacy');
  assert.strictEqual(legacy.status, 400);
  assert.strictEqual(legacy.body.code, 'VALIDATION');

  const svc = await request(mini).get('/svc');
  assert.strictEqual(svc.status, 503);
  assert.strictEqual(svc.body.code, 'DELIVERY_FAILED');
  assert.ok(!svc.body.message.includes('gizli'));

  const exposed = await request(mini).get('/svc-exposed');
  assert.strictEqual(exposed.body.message, 'Gosterilebilir metin');
});

test('createApp: push servisi (app.locals.pushService) auth_service e verilir -> oturum toplu iptalinde BU ornek cagrilir (plan §5d-1)', async () => {
  const authService = require('../../src/services/auth_service');
  const calls = [];
  const fakePush = {
    isConfigured: () => false,
    upsertToken: async () => ({ id: null }),
    disableToken: async () => 0,
    disableAllTokensForUser: async (uid) => { calls.push(uid); return 3; },
  };
  const injected = createApp({ db: fakeDb, mqttBridge: fakeBridge, pushService: fakePush });
  try {
    assert.strictEqual(injected.locals.pushService, fakePush);
    const uid = '33333333-3333-4333-8333-333333333333';
    assert.strictEqual(await authService.revokePushTokens(uid, { reason: 'test' }), 3);
    assert.deepStrictEqual(calls, [uid]);
  } finally {
    authService.setPushService(undefined); // diger testler varsayilan ornekle calissin
  }
});
