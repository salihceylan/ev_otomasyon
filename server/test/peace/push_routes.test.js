'use strict';

// push_routes: PUT/DELETE /me/push-tokens. Sahte kimlik doğrulama + sahte pushService (ağ/DB YOK).
// Supertest, uygulamayı rastgele (ephemeral) bir porta kendisi bağlar; sabit port kullanılmaz.

const test = require('node:test');
const assert = require('node:assert/strict');
const express = require('express');
const request = require('supertest');

const { createPushRouter, RATE_MAX } = require('../../src/routes/push_routes');
const { createPushService, createPushRouter: createPushRouterFromService } = require('../../src/services/push_service');
const realRateLimit = require('../../src/middlewares/rate_limit');
const H = require('./_push_helpers');

const USER = { id: H.USER_ID, role: 'user', is_service_session: false };
const USER_2 = { id: 'bbbbbbbb-cccc-4ddd-8eee-ffffffffffff', role: 'user', is_service_session: false };
const SERVICE_SESSION = { id: null, role: 'service_session', is_service_session: true, home_id: H.HOME_ID };

function asHeader(user) {
  return JSON.stringify(user);
}

/** x-test-user başlığındaki kullanıcıyı req.user yapan sahte authenticateToken (mevcut route testleriyle aynı desen). */
function makeAuth() {
  const fn = (req, res, next) => {
    fn.count += 1;
    const raw = req.headers['x-test-user'];
    if (!raw) return res.status(401).json({ success: false, message: 'token yok', code: 'INVALID_TOKEN' });
    req.user = JSON.parse(raw);
    return next();
  };
  fn.count = 0;
  return fn;
}

function makePushService() {
  const calls = [];
  return {
    calls,
    failWith: null,
    async upsertToken(args) {
      calls.push({ name: 'upsertToken', args });
      if (this.failWith) throw this.failWith;
      return { id: 'row-1' };
    },
    async disableToken(args) {
      calls.push({ name: 'disableToken', args });
      if (this.failWith) throw this.failWith;
      return 1;
    },
  };
}

function build(opts = {}) {
  const pushService = makePushService();
  const authenticateToken = makeAuth();
  const logger = H.createLogger();
  const router = createPushRouter({ pushService, authenticateToken, logger, ...opts });
  const app = express();
  // Gerçek kurulumda server.js aynı router'ı iki önek altına bağlar.
  app.use('/api/v1', router);
  app.use('/api', router);
  return { app, pushService, authenticateToken, logger, router };
}

const VALID_BODY = { token: H.FAKE_TOKEN_A, platform: 'android', app_version: '1.2.3' };

// ---------------------------------------------------------------------------
// Kimlik doğrulama / yetki
// ---------------------------------------------------------------------------
test('kimlik doğrulamasız PUT ve DELETE -> 401, servis çağrılmaz', async () => {
  const { app, pushService } = build();
  for (const method of ['put', 'delete']) {
    const res = await request(app)[method]('/api/v1/me/push-tokens').send(VALID_BODY);
    assert.equal(res.status, 401, method);
    assert.equal(res.body.success, false);
    assert.equal(res.body.code, 'INVALID_TOKEN');
  }
  assert.equal(pushService.calls.length, 0);
});

test('servis oturumu (id yok / role service_session) -> 403 FORBIDDEN, servis çağrılmaz', async () => {
  const { app, pushService } = build();
  for (const user of [SERVICE_SESSION, { id: USER.id, role: 'service_session' }, { id: USER.id, is_service_session: true, role: 'user' }]) {
    for (const method of ['put', 'delete']) {
      const res = await request(app)[method]('/api/v1/me/push-tokens').set('x-test-user', asHeader(user)).send(VALID_BODY);
      assert.equal(res.status, 403, `${method} ${JSON.stringify(user)}`);
      assert.deepEqual(Object.keys(res.body).sort(), ['code', 'message', 'success']);
      assert.equal(res.body.code, 'FORBIDDEN');
      assert.equal(res.body.success, false);
    }
  }
  assert.equal(pushService.calls.length, 0);
});

test('kullanıcı kimliği UUID değilse 403 (DB hatasına düşmez)', async () => {
  const { app, pushService } = build();
  const res = await request(app).put('/api/v1/me/push-tokens').set('x-test-user', asHeader({ id: '42', role: 'user' })).send(VALID_BODY);
  assert.equal(res.status, 403);
  assert.equal(pushService.calls.length, 0);
});

test('router kimlik doğrulamasını route bazında uygular: ilgisiz yollar 404 olur ve auth çağrılmaz', async () => {
  const { app, authenticateToken } = build();
  const res = await request(app).get('/api/v1/homes').send();
  assert.equal(res.status, 404);
  const res2 = await request(app).put('/api/v1/baska/yol').send(VALID_BODY);
  assert.equal(res2.status, 404);
  assert.equal(authenticateToken.count, 0);
});

test('router yol öneki eklemez: yalnızca /me/push-tokens (hem /api/v1 hem /api), kök veya iç içe yol yok', async () => {
  const { app, pushService } = build();
  const hdr = ['x-test-user', asHeader(USER)];
  assert.equal((await request(app).put('/api/v1/me/push-tokens').set(...hdr).send(VALID_BODY)).status, 200);
  assert.equal((await request(app).put('/api/me/push-tokens').set(...hdr).send(VALID_BODY)).status, 200);
  assert.equal((await request(app).put('/me/push-tokens').set(...hdr).send(VALID_BODY)).status, 404);
  assert.equal((await request(app).put('/api/v1/push-tokens').set(...hdr).send(VALID_BODY)).status, 404);
  assert.equal((await request(app).put('/api/v1/me/push/tokens').set(...hdr).send(VALID_BODY)).status, 404);
  assert.equal((await request(app).get('/api/v1/me/push-tokens').set(...hdr)).status, 404); // GET yok
  assert.equal(pushService.calls.length, 2);
});

// ---------------------------------------------------------------------------
// PUT
// ---------------------------------------------------------------------------
test('PUT başarılı: servis doğru argümanlarla çağrılır, yanıt biçimi', async () => {
  const { app, pushService } = build();
  const res = await request(app)
    .put('/api/v1/me/push-tokens')
    .set('x-test-user', asHeader(USER))
    .send({ token: `  ${H.FAKE_TOKEN_A} `, platform: 'iOS', app_version: '2.0.1+7' });
  assert.equal(res.status, 200);
  assert.deepEqual(res.body, { success: true, message: 'Bildirim anahtarı kaydedildi.', data: { registered: true } });
  assert.match(res.headers['cache-control'], /no-store/);
  assert.deepEqual(pushService.calls, [{
    name: 'upsertToken',
    args: { userId: USER.id, token: H.FAKE_TOKEN_A, platform: 'ios', appVersion: '2.0.1+7' },
  }]);
});

test('PUT: app_version isteğe bağlı (camelCase da kabul); gövdedeki user_id yok sayılır', async () => {
  const { app, pushService } = build();
  await request(app).put('/api/v1/me/push-tokens').set('x-test-user', asHeader(USER))
    .send({ token: H.FAKE_TOKEN_A, platform: 'android', user_id: USER_2.id }).expect(200);
  await request(app).put('/api/v1/me/push-tokens').set('x-test-user', asHeader(USER))
    .send({ token: H.FAKE_TOKEN_A, platform: 'android', appVersion: '9' }).expect(200);
  assert.equal(pushService.calls[0].args.appVersion, null);
  assert.equal(pushService.calls[0].args.userId, USER.id, 'başka kullanıcıya jeton bağlanamaz');
  assert.equal(pushService.calls[1].args.appVersion, '9');
});

test('PUT doğrulama: geçersiz platform / kısa-uzun-boşluklu-ASCII dışı jeton / uzun sürüm / eksik alan -> 400 VALIDATION', async () => {
  const { app, pushService } = build();
  const bad = [
    { token: H.FAKE_TOKEN_A, platform: 'windows' },
    { token: H.FAKE_TOKEN_A },
    { token: H.FAKE_TOKEN_A, platform: 42 },
    { platform: 'android' },
    { token: 'kisa', platform: 'android' },
    { token: 'a'.repeat(19), platform: 'ios' },
    { token: 'a'.repeat(513), platform: 'ios' },
    { token: `${'a'.repeat(15)} ${'b'.repeat(15)}`, platform: 'ios' },
    { token: `${'a'.repeat(30)}ş`, platform: 'ios' },
    { token: { $ne: null }, platform: 'ios' },
    { token: [H.FAKE_TOKEN_A], platform: 'ios' },
    { token: H.FAKE_TOKEN_A, platform: 'ios', app_version: 'x'.repeat(33) },
    { token: H.FAKE_TOKEN_A, platform: 'ios', app_version: { a: 1 } },
  ];
  for (const body of bad) {
    const res = await request(app).put('/api/v1/me/push-tokens').set('x-test-user', asHeader(USER)).send(body);
    assert.equal(res.status, 400, JSON.stringify(body).slice(0, 80));
    assert.equal(res.body.success, false);
    assert.equal(res.body.code, 'VALIDATION');
    assert.equal(typeof res.body.message, 'string');
    assert.deepEqual(Object.keys(res.body).sort(), ['code', 'message', 'success']);
  }
  assert.equal(pushService.calls.length, 0);
});

test('PUT sınır değerleri: 20 ve 512 karakterlik jeton kabul, 32 karakterlik sürüm kabul', async () => {
  const { app, pushService } = build();
  for (const token of ['a'.repeat(20), 'b'.repeat(512)]) {
    await request(app).put('/api/v1/me/push-tokens').set('x-test-user', asHeader(USER))
      .send({ token, platform: 'android', app_version: 'v'.repeat(32) }).expect(200);
  }
  assert.equal(pushService.calls.length, 2);
});

test('gövde JSON nesnesi değilse / bozuk JSON ise 400 VALIDATION', async () => {
  const { app, pushService } = build();
  const arr = await request(app).put('/api/v1/me/push-tokens').set('x-test-user', asHeader(USER)).send([1, 2]);
  assert.equal(arr.status, 400);
  assert.equal(arr.body.code, 'VALIDATION');

  const empty = await request(app).put('/api/v1/me/push-tokens').set('x-test-user', asHeader(USER));
  assert.equal(empty.status, 400);

  const broken = await request(app).put('/api/v1/me/push-tokens').set('x-test-user', asHeader(USER))
    .set('Content-Type', 'application/json').send('{"token": ');
  assert.equal(broken.status, 400);
  assert.deepEqual(Object.keys(broken.body).sort(), ['code', 'message', 'success']);
  assert.equal(broken.body.code, 'VALIDATION');
  assert.equal(pushService.calls.length, 0);
});

test('çok büyük gövde -> 413 (8 kB sınırı)', async () => {
  const { app } = build();
  const res = await request(app).put('/api/v1/me/push-tokens').set('x-test-user', asHeader(USER))
    .send({ token: 'a'.repeat(20), platform: 'ios', pad: 'z'.repeat(20000) });
  assert.equal(res.status, 413);
  assert.equal(res.body.code, 'PAYLOAD_TOO_LARGE');
});

// ---------------------------------------------------------------------------
// DELETE
// ---------------------------------------------------------------------------
test('DELETE başarılı: yalnızca çağıranın jetonu için servis çağrılır', async () => {
  const { app, pushService } = build();
  const res = await request(app).delete('/api/v1/me/push-tokens').set('x-test-user', asHeader(USER)).send({ token: H.FAKE_TOKEN_A });
  assert.equal(res.status, 200);
  assert.deepEqual(res.body, { success: true, message: 'Bildirim anahtarı kaldırıldı.', data: { registered: false } });
  assert.deepEqual(pushService.calls, [{ name: 'disableToken', args: { token: H.FAKE_TOKEN_A, userId: USER.id } }]);
});

test('DELETE: token eksik/geçersiz -> 400; gövde yok -> 400', async () => {
  const { app, pushService } = build();
  for (const body of [{}, { token: 'kisa' }, { token: 5 }, { token: `${'a'.repeat(10)} ${'b'.repeat(10)}` }]) {
    const res = await request(app).delete('/api/v1/me/push-tokens').set('x-test-user', asHeader(USER)).send(body);
    assert.equal(res.status, 400);
    assert.equal(res.body.code, 'VALIDATION');
  }
  assert.equal((await request(app).delete('/api/v1/me/push-tokens').set('x-test-user', asHeader(USER))).status, 400);
  assert.equal(pushService.calls.length, 0);
});

test('DELETE: jeton sorgu parametresinden alınmaz (URL/proxy loglarına sızmasın)', async () => {
  const { app, pushService } = build();
  const res = await request(app).delete(`/api/v1/me/push-tokens?token=${H.FAKE_TOKEN_A}`).set('x-test-user', asHeader(USER));
  assert.equal(res.status, 400);
  assert.equal(pushService.calls.length, 0);
});

// ---------------------------------------------------------------------------
// Hata biçimi / sızıntı
// ---------------------------------------------------------------------------
test('servis beklenmeyen hata fırlatırsa 500 INTERNAL, ham mesaj/jeton sızmaz; log sır içermez', async () => {
  const { app, pushService, logger } = build();
  pushService.failWith = Object.assign(new Error(`insert failed for ${H.FAKE_TOKEN_A} password=hunter2`), { code: '23503' });
  const res = await request(app).put('/api/v1/me/push-tokens').set('x-test-user', asHeader(USER)).send(VALID_BODY);
  assert.equal(res.status, 500);
  assert.deepEqual(Object.keys(res.body).sort(), ['code', 'message', 'success']);
  assert.equal(res.body.code, 'INTERNAL');
  assert.doesNotMatch(JSON.stringify(res.body), /hunter2|fake-fcm-token/);
  const logs = logger.lines.join('\n');
  assert.match(logs, /23503/);
  assert.doesNotMatch(logs, /hunter2|fake-fcm-token/);
});

test('servis VALIDATION kodlu hata fırlatırsa 400 olarak iletilir', async () => {
  const { app, pushService } = build();
  pushService.failWith = Object.assign(new Error('Platform geçersiz.'), { code: 'VALIDATION' });
  const res = await request(app).put('/api/v1/me/push-tokens').set('x-test-user', asHeader(USER)).send(VALID_BODY);
  assert.equal(res.status, 400);
  assert.equal(res.body.code, 'VALIDATION');
});

// ---------------------------------------------------------------------------
// Hız sınırı
// ---------------------------------------------------------------------------
test('varsayılan hız sınırı: kullanıcı başına 20/dk; 21. istek 429 RATE_LIMITED + Retry-After; başka kullanıcı etkilenmez', async () => {
  assert.equal(RATE_MAX, 20);
  const { app, pushService } = build({ rateLimit: realRateLimit });
  for (let i = 0; i < 20; i += 1) {
    const ok = await request(app).put('/api/v1/me/push-tokens').set('x-test-user', asHeader(USER)).send(VALID_BODY);
    assert.equal(ok.status, 200, `istek ${i + 1}`);
  }
  const limited = await request(app).put('/api/v1/me/push-tokens').set('x-test-user', asHeader(USER)).send(VALID_BODY);
  assert.equal(limited.status, 429);
  assert.equal(limited.body.success, false);
  assert.equal(limited.body.code, 'RATE_LIMITED');
  assert.ok(Number(limited.headers['retry-after']) >= 1);
  assert.equal(pushService.calls.length, 20, 'sınırlanan istek servise ulaşmaz');

  // PUT ve DELETE aynı kullanıcı sayacını paylaşır
  const del = await request(app).delete('/api/v1/me/push-tokens').set('x-test-user', asHeader(USER)).send({ token: H.FAKE_TOKEN_A });
  assert.equal(del.status, 429);

  const other = await request(app).put('/api/v1/me/push-tokens').set('x-test-user', asHeader(USER_2)).send(VALID_BODY);
  assert.equal(other.status, 200);
});

test('rateLimit seçeneği verilmezse de (modül tembel çözülür) 20/dk uygulanır', async () => {
  const { app } = build();
  let last;
  for (let i = 0; i < 21; i += 1) {
    last = await request(app).put('/api/v1/me/push-tokens').set('x-test-user', asHeader(USER)).send(VALID_BODY);
  }
  assert.equal(last.status, 429);
  assert.equal(last.body.code, 'RATE_LIMITED');
});

test('fabrika olarak verilen rateLimit doğru seçeneklerle çağrılır (anahtar kullanıcıya göre)', async () => {
  const seen = [];
  const factory = (opts) => {
    seen.push(opts);
    return (req, res, next) => next();
  };
  const { app } = build({ rateLimit: factory });
  assert.equal(seen.length, 1);
  assert.equal(seen[0].max, 20);
  assert.equal(seen[0].windowMs, 60 * 1000);
  assert.equal(seen[0].keyGenerator({ user: { id: 'u-1' } }), 'push-token:u-1');
  await request(app).put('/api/v1/me/push-tokens').set('x-test-user', asHeader(USER)).send(VALID_BODY).expect(200);
});

test('hazır middleware olarak verilen rateLimit aynen kullanılır', async () => {
  let hits = 0;
  const mw = (req, res, next) => { hits += 1; return next(); };
  const { app } = build({ rateLimit: mw });
  await request(app).put('/api/v1/me/push-tokens').set('x-test-user', asHeader(USER)).send(VALID_BODY).expect(200);
  assert.equal(hits, 1);
});

test('hız sınırı kimlik doğrulamadan SONRA çalışır: kimliksiz istekler kullanıcı sayacını tüketmez', async () => {
  let hits = 0;
  const mw = (req, res, next) => { hits += 1; return next(); };
  const { app } = build({ rateLimit: mw });
  await request(app).put('/api/v1/me/push-tokens').send(VALID_BODY).expect(401);
  await request(app).put('/api/v1/me/push-tokens').set('x-test-user', asHeader(SERVICE_SESSION)).send(VALID_BODY).expect(403);
  assert.equal(hits, 0);
});

// ---------------------------------------------------------------------------
// Kurulum güvenliği
// ---------------------------------------------------------------------------
test('pushService veya authenticateToken eksikse router kurulmaz (fail-closed)', () => {
  assert.throws(() => createPushRouter({ authenticateToken: makeAuth() }), TypeError);
  assert.throws(() => createPushRouter({ pushService: makePushService() }), TypeError);
  assert.throws(() => createPushRouter({ pushService: {}, authenticateToken: makeAuth() }), TypeError);
  assert.throws(() => createPushRouter(), TypeError);
});

test('createPushRouter push_service.js üzerinden de erişilebilir (şartname §3.2)', () => {
  assert.equal(typeof createPushRouterFromService, 'function');
  const router = createPushRouterFromService({ pushService: makePushService(), authenticateToken: makeAuth() });
  assert.equal(typeof router, 'function');
});

// ---------------------------------------------------------------------------
// Gerçek servis ile uçtan uca (sahte db)
// ---------------------------------------------------------------------------
test('gerçek createPushService + sahte db: PUT -> upsert SQL parametreleri, DELETE -> kullanıcıya özel devre dışı bırakma', async () => {
  const db = H.createFakeDb(() => ({ rows: [{ id: 'row-7' }], rowCount: 1 }));
  const pushService = createPushService({ db, logger: H.createLogger(), env: {} });
  const authenticateToken = makeAuth();
  const app = express();
  app.use('/api/v1', createPushRouter({ pushService, authenticateToken, logger: H.createLogger() }));

  await request(app).put('/api/v1/me/push-tokens').set('x-test-user', asHeader(USER)).send(VALID_BODY).expect(200);
  assert.deepEqual(db.calls[0].params.slice(0, 4), [USER.id, H.FAKE_TOKEN_A, 'android', '1.2.3']);
  assert.match(db.calls[0].text, /DELETE FROM push_tokens/, 'kullanıcı başına üst sınır aynı deyimde');

  await request(app).delete('/api/v1/me/push-tokens').set('x-test-user', asHeader(USER_2)).send({ token: H.FAKE_TOKEN_A }).expect(200);
  assert.match(db.calls[1].text, /UPDATE push_tokens SET disabled_at/);
  assert.deepEqual(db.calls[1].params, [H.FAKE_TOKEN_A, USER_2.id]);
});
