'use strict';

// C8 - Zamanli kural uclari: rol matrisi, UUID/kimlik dogrulama, yanit sozlesmesi,
// hata sizintisi yok, hiz siniri. Kimlik dogrulama ara katmanlari ve servis ENJEKTE edilir
// (A paketinin auth_middleware'i ayri test edilir).

const test = require('node:test');
const assert = require('node:assert/strict');
const express = require('express');
const request = require('supertest');
const { createRouter, MANAGE_ROLES } = require('../../src/routes/scheduled_rules_routes');
const { ValidationError } = require('../../src/services/scheduled_rules_service');
const { HttpError } = require('../../src/utils/helpers');
const { makeLogger } = require('./_helpers');

const HOME = '11111111-1111-4111-8111-111111111111';
const OTHER_HOME = '22222222-2222-4222-8222-222222222222';

/**
 * A paketinin requireHomeAccess sozlesmesini taklit eden sahte ara katman:
 *  - super_user her eve girer; service_session yalniz kendi evine
 *  - uye degilse 403; gecerlilik suresi dolmus misafir 403 GUEST_EXPIRED; rol listede degilse 403
 */
function makeAuth({ memberships = {}, permissive = false } = {}) {
  const calls = { roles: [] };
  const deny = (res, status, code, message) => res.status(status).json({ success: false, message, code });
  return {
    calls,
    authenticateToken(req, res, next) {
      const raw = req.headers['x-test-user'];
      if (!raw) return deny(res, 401, 'INVALID_TOKEN', 'Token yok');
      req.user = JSON.parse(raw);
      return next();
    },
    requireHomeAccess(roles) {
      calls.roles.push(roles);
      return (req, res, next) => {
        const homeId = req.params.home_id;
        if (permissive) {
          // En kotu durum: ara katman HER SEYI gecirir; rol bilgisini yalnizca doldurur.
          const m = memberships[`${homeId}:${req.user.id}`];
          req.homeAccess = { home_id: homeId, role: req.user.role === 'service_session' ? 'service_session' : (m && m.role) };
          return next();
        }
        if (req.user.role === 'super_user') {
          req.homeAccess = { home_id: homeId, role: 'super_user', is_super: true };
          return next();
        }
        if (req.user.role === 'service_session') {
          if (req.user.home_id !== homeId) return deny(res, 403, 'FORBIDDEN', 'Bu eve erisim yok');
          if (!roles.includes('service_session')) return deny(res, 403, 'FORBIDDEN', 'Servis oturumu bu ucu kullanamaz');
          req.homeAccess = { home_id: homeId, role: 'service_session' };
          return next();
        }
        const m = memberships[`${homeId}:${req.user.id}`];
        if (!m) return deny(res, 403, 'FORBIDDEN', 'Bu eve erisim yok');
        if (m.role === 'guest' && m.expired) return deny(res, 403, 'GUEST_EXPIRED', 'Misafir suresi doldu');
        if (!roles.includes(m.role)) return deny(res, 403, 'FORBIDDEN', 'Yetersiz yetki');
        req.homeAccess = { home_id: homeId, role: m.role };
        return next();
      };
    },
  };
}

function makeService(overrides = {}) {
  const calls = [];
  const rec = (name, ret) => async (...args) => {
    calls.push({ name, args });
    return typeof ret === 'function' ? ret(...args) : ret;
  };
  return {
    calls,
    listRules: rec('listRules', [{ id: 1, channel: 3 }]),
    createRule: rec('createRule', (homeId, userId, body) => ({ id: 9, channel: body.channel, home_id: homeId, created_by: userId })),
    updateRule: rec('updateRule', (homeId, ruleId, body) => ({ id: ruleId, ...body })),
    deleteRule: rec('deleteRule', (homeId, ruleId) => ({ id: ruleId })),
    ...overrides,
  };
}

function makeLimiterFactory() {
  const created = [];
  const factory = (opts) => {
    const mw = (req, res, next) => next();
    created.push({ opts, mw });
    return mw;
  };
  factory.created = created;
  return factory;
}

function build({ memberships, service = makeService(), permissive = false, logger = makeLogger(), rateLimit = makeLimiterFactory() } = {}) {
  const auth = makeAuth({ memberships, permissive });
  const app = express();
  app.use(express.json());
  const router = createRouter({ auth, service, rateLimit, logger });
  app.use('/api/v1/homes', router);
  app.use('/api/homes', router);
  // A'nin global hata yakalayicisini taklit eder (govde ayristirma hatalari 400 doner).
  // eslint-disable-next-line no-unused-vars
  app.use((err, req, res, next) => {
    const status = err.status && err.status < 500 ? err.status : 500;
    res.status(status).json({ success: false, code: status === 400 ? 'VALIDATION' : 'INTERNAL_ERROR' });
  });
  return { app, auth, service, logger, rateLimit };
}

const as = (user) => ({ 'x-test-user': JSON.stringify(user) });
const OWNER = { id: 'u-owner', role: 'user' };
const RESIDENT = { id: 'u-res', role: 'user' };
const GUEST = { id: 'u-guest', role: 'user' };
const EXPIRED_GUEST = { id: 'u-guest2', role: 'user' };
const STAFF = { id: 'u-staff', role: 'service_user' };
const SUPER = { id: 'u-super', role: 'super_user' };
const OUTSIDER = { id: 'u-out', role: 'user' };
const SESSION = { id: 'service_session:s1', role: 'service_session', home_id: HOME, sid: 's1' };

const MEMBERS = {
  [`${HOME}:u-owner`]: { role: 'owner' },
  [`${HOME}:u-res`]: { role: 'resident' },
  [`${HOME}:u-guest`]: { role: 'guest' },
  [`${HOME}:u-guest2`]: { role: 'guest', expired: true },
  [`${HOME}:u-staff`]: { role: 'service_user' },
};

const BODY = { channel: 3, channel_type: 'relay', action: 'on', hour: 8, minute: 30 };

// -- Rol matrisi: her rol x her uc --------------------------------------------------

const ENDPOINTS = [
  ['GET', '/scheduled-rules', null],
  ['POST', '/scheduled-rules', BODY],
  ['PUT', '/scheduled-rules/5', { enabled: false }],
  ['DELETE', '/scheduled-rules/5', null],
];

function call(app, method, path, user, body, base = '/api/v1/homes') {
  let req = request(app)[method.toLowerCase()](`${base}/${HOME}${path}`);
  if (user) req = req.set(as(user));
  return body ? req.send(body) : req;
}

test('rol matrisi: super/staff/owner/resident TUM uclara girer', async () => {
  for (const [name, user] of [['super', SUPER], ['staff', STAFF], ['owner', OWNER], ['resident', RESIDENT]]) {
    const { app } = build({ memberships: MEMBERS });
    for (const [method, path, body] of ENDPOINTS) {
      const res = await call(app, method, path, user, body);
      assert.ok(res.status < 300, `${name} ${method} ${path} -> ${res.status} ${JSON.stringify(res.body)}`);
    }
  }
});

test('rol matrisi: misafir (gecerli), suresi dolmus misafir, servis oturumu, uye olmayan, tokensiz HICBIR uca giremez', async () => {
  const cases = [
    ['guest', GUEST, 403, 'FORBIDDEN'],
    ['expired guest', EXPIRED_GUEST, 403, 'GUEST_EXPIRED'],
    ['service_session', SESSION, 403, 'FORBIDDEN'],
    ['outsider', OUTSIDER, 403, 'FORBIDDEN'],
    ['anon', null, 401, 'INVALID_TOKEN'],
  ];
  for (const [name, user, status, code] of cases) {
    const service = makeService();
    const { app } = build({ memberships: MEMBERS, service });
    for (const [method, path, body] of ENDPOINTS) {
      const res = await call(app, method, path, user, body);
      assert.equal(res.status, status, `${name} ${method} ${path}`);
      assert.equal(res.body.code, code, `${name} ${method} ${path}`);
    }
    assert.equal(service.calls.length, 0, `${name}: servis HIC cagrilmamali`);
  }
});

test('requireHomeAccess rol listesi: misafir ve servis oturumu YOK; super_user/owner/resident/service_user var', () => {
  const { auth } = build();
  assert.ok(auth.calls.roles.length >= 1);
  for (const roles of auth.calls.roles) {
    assert.deepEqual([...roles].sort(), [...MANAGE_ROLES].sort());
    assert.equal(roles.includes('guest'), false);
    assert.equal(roles.includes('service_session'), false);
  }
});

test('DERINLEMESINE SAVUNMA: ara katman her seyi gecirse bile misafir ve servis oturumu reddedilir', async () => {
  for (const [name, user] of [['guest', GUEST], ['service_session', SESSION]]) {
    const service = makeService();
    const { app } = build({ memberships: MEMBERS, service, permissive: true });
    for (const [method, path, body] of ENDPOINTS) {
      const res = await call(app, method, path, user, body);
      assert.equal(res.status, 403, `${name} ${method} ${path}`);
      assert.equal(res.body.code, 'FORBIDDEN');
    }
    assert.equal(service.calls.length, 0);
  }
  // permissive ara katmanda yetkili rol hala calisir
  const { app } = build({ memberships: MEMBERS, permissive: true });
  assert.equal((await call(app, 'GET', '/scheduled-rules', OWNER)).status, 200);
});

test('baska evin uyesi (owner) bu evde yetkisiz', async () => {
  const memberships = { ...MEMBERS, [`${OTHER_HOME}:u-owner`]: { role: 'owner' } };
  const { app } = build({ memberships });
  const res = await request(app).get(`/api/v1/homes/${OTHER_HOME}/scheduled-rules`).set(as(RESIDENT));
  assert.equal(res.status, 403);
});

// -- Kimlik / parametre dogrulama ----------------------------------------------------

test(':homeId UUID degilse 400 VALIDATION (parseInt davranisi yok)', async () => {
  const service = makeService();
  const { app } = build({ memberships: MEMBERS, service });
  for (const bad of ['101', 'abc', '1; DROP TABLE homes', '11111111-1111-4111-8111-11111111111']) {
    const res = await request(app).get(`/api/v1/homes/${encodeURIComponent(bad)}/scheduled-rules`).set(as(OWNER));
    assert.equal(res.status, 400, bad);
    assert.equal(res.body.code, 'VALIDATION');
  }
  assert.equal(service.calls.length, 0);
});

test(':ruleId gecersizse 404 (servise ulasmaz)', async () => {
  const service = makeService();
  const { app } = build({ memberships: MEMBERS, service });
  for (const bad of ['abc', '0', '-1', '1.5', '99999999999', '5;', '%20']) {
    for (const method of ['PUT', 'DELETE']) {
      const res = await request(app)[method.toLowerCase()](`/api/v1/homes/${HOME}/scheduled-rules/${bad}`).set(as(OWNER)).send({ enabled: false });
      assert.equal(res.status, 404, `${method} ${bad}`);
      assert.equal(res.body.code, 'NOT_FOUND');
    }
  }
  assert.equal(service.calls.length, 0);
});

test('govde JSON nesnesi degilse 400', async () => {
  const service = makeService();
  const { app } = build({ memberships: MEMBERS, service });
  for (const body of [[1, 2], 'x']) {
    const res = await request(app).post(`/api/v1/homes/${HOME}/scheduled-rules`).set(as(OWNER)).set('Content-Type', 'application/json').send(JSON.stringify(body));
    assert.ok(res.status === 400, `${JSON.stringify(body)} -> ${res.status}`);
  }
  assert.equal(service.calls.length, 0);
});

// -- Yanit sozlesmesi ---------------------------------------------------------------

test('GET: { success, message, data:{rules} } + gecis donemi ust duzey rules; /api ve /api/v1 ayni', async () => {
  const { app } = build({ memberships: MEMBERS });
  for (const base of ['/api/v1/homes', '/api/homes']) {
    const res = await call(app, 'GET', '/scheduled-rules', OWNER, null, base);
    assert.equal(res.status, 200);
    assert.equal(res.body.success, true);
    assert.deepEqual(res.body.data.rules, [{ id: 1, channel: 3 }]);
    assert.deepEqual(res.body.rules, res.body.data.rules);
  }
});

test('POST: 201, ev URL\'den, kullanici token\'dan; govdedeki home_id/created_by etkisiz', async () => {
  const service = makeService();
  const { app } = build({ memberships: MEMBERS, service });
  const res = await call(app, 'POST', '/scheduled-rules', RESIDENT, { ...BODY, home_id: OTHER_HOME, created_by: 'x' });
  assert.equal(res.status, 201);
  assert.equal(res.body.success, true);
  assert.equal(res.body.data.rule.id, 9);
  assert.deepEqual(res.body.rule, res.body.data.rule);
  const c = service.calls.find((x) => x.name === 'createRule');
  assert.equal(c.args[0], HOME);
  assert.equal(c.args[1], 'u-res');
});

test('PUT/DELETE: ruleId sayi olarak servise gecer; yanit 200', async () => {
  const service = makeService();
  const { app } = build({ memberships: MEMBERS, service });
  const put = await call(app, 'PUT', '/scheduled-rules/5', OWNER, { enabled: false });
  assert.equal(put.status, 200);
  assert.equal(put.body.data.rule.id, 5);
  const del = await call(app, 'DELETE', '/scheduled-rules/5', OWNER);
  assert.equal(del.status, 200);
  assert.equal(del.body.success, true);
  assert.deepEqual(del.body.data, { id: 5 });
  assert.deepEqual(service.calls.map((c) => [c.name, c.args[0], c.args[1]]), [['updateRule', HOME, 5], ['deleteRule', HOME, 5]]);
});

test('hata sozlesmesi: VALIDATION 400 + errors listesi + gecis donemi "error" alani', async () => {
  const service = makeService({
    createRule: async () => {
      throw new ValidationError([{ field: 'hour', message: 'Gecersiz saat (0..23)' }, { field: 'channel', message: 'Gecersiz kanal' }]);
    },
  });
  const { app } = build({ memberships: MEMBERS, service });
  const res = await call(app, 'POST', '/scheduled-rules', OWNER, BODY);
  assert.equal(res.status, 400);
  assert.equal(res.body.success, false);
  assert.equal(res.body.code, 'VALIDATION');
  assert.equal(res.body.message, 'Gecersiz saat (0..23)');
  assert.equal(res.body.error, res.body.message);
  assert.deepEqual(res.body.errors.map((e) => e.field), ['hour', 'channel']);
});

test('servis HttpError kodlari aynen aktarilir (404 NOT_FOUND, 409 CONFLICT)', async () => {
  const service = makeService({
    updateRule: async () => {
      throw new HttpError(404, 'Kural bulunamadi', 'NOT_FOUND');
    },
    createRule: async () => {
      throw new HttpError(409, 'Bir evde en fazla 50 zamanli kural olabilir', 'CONFLICT');
    },
  });
  const { app } = build({ memberships: MEMBERS, service });
  const a = await call(app, 'PUT', '/scheduled-rules/5', OWNER, { enabled: true });
  assert.deepEqual([a.status, a.body.code], [404, 'NOT_FOUND']);
  const b = await call(app, 'POST', '/scheduled-rules', OWNER, BODY);
  assert.deepEqual([b.status, b.body.code], [409, 'CONFLICT']);
});

test('5xx: ham SQL/kisit/yigin mesaji ISTEMCIYE DONMEZ; log\'a yazilir', async () => {
  const leak = 'duplicate key value violates unique constraint "scheduled_rules_pkey" DETAIL: secret-table-detail';
  const service = makeService({
    listRules: async () => {
      throw new Error(leak);
    },
    createRule: async () => {
      throw Object.assign(new Error(leak), { code: '42P01' });
    },
  });
  const logger = makeLogger();
  const { app } = build({ memberships: MEMBERS, service, logger });
  for (const [method, path, body] of [['GET', '/scheduled-rules', null], ['POST', '/scheduled-rules', BODY]]) {
    const res = await call(app, method, path, OWNER, body);
    assert.equal(res.status, 500);
    assert.equal(res.body.code, 'INTERNAL_ERROR');
    assert.ok(!JSON.stringify(res.body).includes('constraint'), 'ic mesaj sizmamali');
    assert.ok(!JSON.stringify(res.body).includes('secret-table-detail'));
  }
  assert.ok(logger.lines.some((l) => l.includes('duplicate key')), 'ayrinti sunucu log\'una yazilmali');
});

test('veritabani kisit hatalari anlamli kodlara eslenir (23503 -> 409, 23514 -> 400), ayrinti sizmaz', async () => {
  const service = makeService({
    updateRule: async () => {
      throw Object.assign(new Error('violates foreign key constraint "fk_sr_device"'), { code: '23503' });
    },
    deleteRule: async () => {
      throw Object.assign(new Error('violates check constraint "scheduled_rules_channel_check"'), { code: '23514' });
    },
  });
  const { app } = build({ memberships: MEMBERS, service });
  const a = await call(app, 'PUT', '/scheduled-rules/5', OWNER, { device_id: HOME });
  assert.deepEqual([a.status, a.body.code], [409, 'CONFLICT']);
  assert.ok(!JSON.stringify(a.body).includes('fk_sr_device'));
  const b = await call(app, 'DELETE', '/scheduled-rules/5', OWNER);
  assert.deepEqual([b.status, b.body.code], [400, 'VALIDATION']);
  assert.ok(!JSON.stringify(b.body).includes('scheduled_rules_channel_check'));
});

test('yazma uclarinda hiz siniri: kullanici + ev anahtari, 60 / 10 dk; GET sinirlanmaz', async () => {
  const rateLimit = makeLimiterFactory();
  const { app } = build({ memberships: MEMBERS, rateLimit });
  assert.equal(rateLimit.created.length, 1);
  const { opts } = rateLimit.created[0];
  assert.equal(opts.max, 60);
  assert.equal(opts.windowMs, 10 * 60 * 1000);
  assert.equal(opts.code, 'RATE_LIMITED');
  const key = opts.keyGenerator({ user: { id: 'u-owner' }, scheduledHomeId: HOME });
  assert.equal(key, `scheduled_rules:u-owner:${HOME}`);
  assert.notEqual(key, opts.keyGenerator({ user: { id: 'u-res' }, scheduledHomeId: HOME }));
  assert.notEqual(key, opts.keyGenerator({ user: { id: 'u-owner' }, scheduledHomeId: OTHER_HOME }));
  // GET ucu limiter'a bagli degil (sahte limiter sayaci olmadigindan dogrudan 200)
  assert.equal((await call(app, 'GET', '/scheduled-rules', OWNER)).status, 200);
});

test('gercek hiz sinirlayici ile: 60 yazma gecer, 61. istek 429 RATE_LIMITED (Retry-After)', async () => {
  const rateLimit = require('../../src/middlewares/rate_limit');
  const { app } = build({ memberships: MEMBERS, rateLimit });
  let last;
  for (let i = 0; i < 61; i++) {
    last = await call(app, 'POST', '/scheduled-rules', OWNER, BODY);
    if (i < 60) assert.equal(last.status, 201, `istek ${i + 1}`);
  }
  assert.equal(last.status, 429);
  assert.equal(last.body.code, 'RATE_LIMITED');
  assert.ok(last.headers['retry-after']);
  // baska kullanici etkilenmez
  assert.equal((await call(app, 'POST', '/scheduled-rules', RESIDENT, BODY)).status, 201);
});

test('varsayilan (tembel) yonlendirici modulu yuklenirken veritabani/ortam gerektirmez', () => {
  // require zaten yukarida basarili; fonksiyon (middleware) olarak disa aciliyor
  const mod = require('../../src/routes/scheduled_rules_routes');
  assert.equal(typeof mod, 'function');
  assert.equal(typeof mod.createRouter, 'function');
});

// -- C9: istemciye donen mesajlar DOGRU Turkce karakterlerle (UTF-8) ------------------------------

test('C9: yol katmani mesajlari UTF-8 Turkce (Geçersiz ev kimliği, Kural bulunamadı, İstek gövdesi ...) ve ASCII\'ye indirgenmemis', async () => {
  const service = makeService({
    listRules: async () => {
      throw new Error('ic hata');
    },
    updateRule: async () => {
      throw Object.assign(new Error('x'), { code: '23503' });
    },
    deleteRule: async () => {
      throw Object.assign(new Error('x'), { code: '23514' });
    },
  });
  const { app } = build({ memberships: MEMBERS, service });
  const seen = {};
  seen.badHome = (await request(app).get('/api/v1/homes/101/scheduled-rules').set(as(OWNER))).body.message;
  seen.badRule = (await request(app).put(`/api/v1/homes/${HOME}/scheduled-rules/abc`).set(as(OWNER)).send({ enabled: true })).body.message;
  seen.guest = (await call(build({ memberships: MEMBERS, permissive: true }).app, 'GET', '/scheduled-rules', GUEST)).body.message;
  seen.notObject = (await request(app).post(`/api/v1/homes/${HOME}/scheduled-rules`).set(as(OWNER)).set('Content-Type', 'application/json').send('[]')).body.message;
  seen.internal = (await call(app, 'GET', '/scheduled-rules', OWNER)).body.message;
  seen.fk = (await call(app, 'PUT', '/scheduled-rules/5', OWNER, { enabled: true })).body.message;
  seen.check = (await call(app, 'DELETE', '/scheduled-rules/5', OWNER)).body.message;
  const ok = build({ memberships: MEMBERS });
  seen.list = (await call(ok.app, 'GET', '/scheduled-rules', OWNER)).body.message;
  seen.create = (await call(ok.app, 'POST', '/scheduled-rules', OWNER, BODY)).body.message;
  seen.update = (await call(ok.app, 'PUT', '/scheduled-rules/5', OWNER, { enabled: false })).body.message;
  seen.delete = (await call(ok.app, 'DELETE', '/scheduled-rules/5', OWNER)).body.message;

  assert.equal(seen.badHome, 'Geçersiz ev kimliği');
  assert.equal(seen.badRule, 'Kural bulunamadı');
  assert.equal(seen.guest, 'Bu işlem için yetkiniz yok');
  assert.equal(seen.notObject, 'İstek gövdesi bir JSON nesnesi olmalı');
  assert.equal(seen.internal, 'Sunucu hatası. Lütfen daha sonra tekrar deneyin.');
  assert.equal(seen.fk, 'Kayıt başka bir kayıtla ilişkili veya değişmiş');
  assert.equal(seen.check, 'Geçersiz değer');
  assert.equal(seen.list, 'Zamanlı kurallar listelendi');
  assert.equal(seen.create, 'Zamanlı kural oluşturuldu');
  assert.equal(seen.update, 'Zamanlı kural güncellendi');
  assert.equal(seen.delete, 'Zamanlı kural silindi');
  for (const [k, m] of Object.entries(seen)) {
    assert.doesNotMatch(m, /\b(Gecersiz|olmali|bulunamadi|icin|islem|hatasi|Lutfen|degismis|iliskili|Istek|govdesi|olusturuldu|guncellendi|Zamanli)\b/, `${k}: ASCII'ye indirgenmis: ${m}`);
  }
});

test('C9: Turkce mesajlar HTTP govdesinde UTF-8 olarak (charset=utf-8) tasinir', async () => {
  const { app } = build({ memberships: MEMBERS });
  const res = await request(app).get('/api/v1/homes/101/scheduled-rules').set(as(OWNER));
  assert.match(res.headers['content-type'], /charset=utf-8/i);
  assert.equal(Buffer.from(res.text, 'utf8').includes(Buffer.from('Geçersiz ev kimliği', 'utf8')), true);
});
