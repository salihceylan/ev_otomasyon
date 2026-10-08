'use strict';

// Faz 1 / IP-1.3, IP-1.4, IP-1.6: site / daire / sablon / yazim kaydi / yerel anahtar rotalari (CONTRACTS §3e).
// Rota katmani: HER uc authenticateToken + requireServiceManager (service_user + super_user; servis PIN oturumu,
// owner, resident, misafir 403). Servis sahte (kayit tutan); is mantigi site_template_service_pg.test.js'te.

const test = require('node:test');
const assert = require('node:assert/strict');
const express = require('express');
const request = require('supertest');

const { createFakeAuth, listRoutes, injectModule, USER } = require('../devices/_routes_env');

/** Kayit tutan sahte servis: TUM argumanlar kaydedilir ({name, args:[...]}). */
function createRecorder(methodNames, canned = {}) {
  const calls = [];
  const svc = { calls, failWith: {} };
  for (const name of methodNames) {
    svc[name] = async (...args) => {
      calls.push({ name, args });
      if (svc.failWith[name]) throw svc.failWith[name];
      return canned[name] !== undefined ? canned[name] : { ok: true };
    };
  }
  return svc;
}
const { httpError } = require('../../src/utils/http_errors');
const { errorHandler } = require('../../src/middlewares/error_handler');

/** auth_middleware.requireServiceManager ile ayni kural (gercegi db.js gerektirir). */
function requireServiceManager(req, res, next) {
  if (!req.user) return res.status(401).json({ success: false, code: 'INVALID_TOKEN', message: 'x' });
  if (req.user.is_service_session || !['service_user', 'super_user'].includes(req.user.role)) {
    return res.status(403).json({ success: false, code: 'FORBIDDEN', message: 'Bu işlem için Servis Sorumlusu veya Süper Yönetici yetkisi gereklidir.' });
  }
  return next();
}
requireServiceManager.__tag = 'requireServiceManager';

const fakeAuth = () => ({ ...createFakeAuth({ members: [] }), requireServiceManager });
injectModule('middlewares/auth_middleware.js', fakeAuth());
const { createRouter } = require('../../src/routes/site_template_routes');

const SITE = '8c1d2e3f-4a5b-4c6d-8e7f-0123456789ab';
const FLAT = '11111111-2222-4333-8444-555555555555';
const TPL = '3f2a9c1e-5b7d-4e8f-9a01-23456789abcd';
const ACTORS = {
  super: USER({ id: 'u-super', role: 'super_user' }),
  staff: USER({ id: 'u-staff', role: 'service_user' }),
  session: JSON.stringify({ id: null, role: 'service_session', is_service_session: true, home_id: SITE, sid: 's1' }),
  user: USER({ id: 'u-owner', role: 'user' }),
};
const METHODS = [
  'listSites', 'createSite', 'getSite', 'updateSite', 'deleteSite', 'listFlats', 'bulkCreateFlats', 'updateFlat', 'deleteFlat',
  'linkFlatDevice', 'listTemplates', 'createTemplate', 'getTemplate', 'updateTemplate', 'deleteTemplate', 'listVersions',
  'getVersion', 'validate', 'recordWrite', 'getInventoryLocalKey',
];

function build(canned = {}) {
  const svc = createRecorder(METHODS, {
    createTemplate: { id: TPL, current_version: 1, created: true },
    updateTemplate: { id: TPL, current_version: 2, created: true },
    getInventoryLocalKey: { local_key: 'GizliAnahtar123456' },
    validate: { ok: true },
    ...canned,
  });
  const auth = fakeAuth();
  const router = createRouter({ auth, rateLimit: () => (_q, _r, next) => next(), siteTemplateService: svc });
  const app = express();
  app.use(express.json());
  app.use('/api/v1', router);
  app.use('/api', router);
  app.use(errorHandler);
  return { app, router, svc, auth };
}

const CASES = [
  ['get', '/sites', null, 'listSites', 200],
  ['post', '/sites', { name: 'Güneş' }, 'createSite', 201],
  ['get', `/sites/${SITE}`, null, 'getSite', 200],
  ['patch', `/sites/${SITE}`, { notes: 'x' }, 'updateSite', 200],
  ['delete', `/sites/${SITE}`, null, 'deleteSite', 200],
  ['get', `/sites/${SITE}/flats`, null, 'listFlats', 200],
  ['post', `/sites/${SITE}/flats/bulk`, { block: 'A', from: 1, to: 24 }, 'bulkCreateFlats', 201],
  ['patch', `/sites/${SITE}/flats/${FLAT}`, { status: 'written' }, 'updateFlat', 200],
  ['delete', `/sites/${SITE}/flats/${FLAT}`, null, 'deleteFlat', 200],
  ['put', `/sites/${SITE}/flats/${FLAT}/device`, { device_uuid: 'AHBU-S3-0001' }, 'linkFlatDevice', 200],
  ['get', `/templates?site_id=${SITE}&include_global=1`, null, 'listTemplates', 200],
  ['post', '/templates', { site_id: SITE, body: {} }, 'createTemplate', 201],
  ['post', '/templates/validate', { body: {} }, 'validate', 200],
  ['get', `/templates/${TPL}`, null, 'getTemplate', 200],
  ['put', `/templates/${TPL}`, { body: {} }, 'updateTemplate', 200],
  ['delete', `/templates/${TPL}`, null, 'deleteTemplate', 200],
  ['get', `/templates/${TPL}/versions`, null, 'listVersions', 200],
  ['get', `/templates/${TPL}/versions/3`, null, 'getVersion', 200],
  ['post', '/template-writes', { device_uuid: 'AHBU-S3-0001', template_id: TPL, version: 1, via: 'lan', result: 'ok' }, 'recordWrite', 201],
  ['get', '/admin/inventory/AHBU-S3-0001/local-key', null, 'getInventoryLocalKey', 200],
];

test('yapisal: §3e uclarinin tamami; her uc authenticateToken + requireServiceManager ile baslar (router.use yok)', () => {
  const { router, auth } = build();
  const routes = listRoutes(router, '');
  assert.deepEqual(routes.map((r) => `${r.method} ${r.path}`).sort(), [
    'GET /sites', 'POST /sites', 'GET /sites/:siteId', 'PATCH /sites/:siteId', 'DELETE /sites/:siteId',
    'GET /sites/:siteId/flats', 'POST /sites/:siteId/flats/bulk', 'PATCH /sites/:siteId/flats/:flatId',
    'DELETE /sites/:siteId/flats/:flatId', 'PUT /sites/:siteId/flats/:flatId/device',
    'GET /templates', 'POST /templates', 'POST /templates/validate', 'GET /templates/:id', 'PUT /templates/:id',
    'DELETE /templates/:id', 'GET /templates/:id/versions', 'GET /templates/:id/versions/:version',
    'POST /template-writes', 'GET /admin/inventory/:uuid/local-key',
  ].sort());
  for (const r of routes) {
    assert.equal(r.handlers[0], auth.authenticateToken, `${r.method} ${r.path}`);
    assert.equal(r.handlers[1], auth.requireServiceManager, `${r.method} ${r.path}`);
  }
  assert.equal(router.stack.filter((l) => !l.route).length, 0, 'router.use yok');
});

for (const [method, path, body, svcMethod, okStatus] of CASES) {
  test(`yetki matrisi: ${method.toUpperCase()} ${path.split('?')[0]}`, async () => {
    for (const [who, header] of Object.entries(ACTORS)) {
      const { app, svc } = build();
      let req = request(app)[method](`/api/v1${path}`).set('x-test-user', header);
      if (body) req = req.send(body);
      const res = await req;
      if (who === 'super' || who === 'staff') {
        assert.equal(res.status, okStatus, `${who}: ${JSON.stringify(res.body)}`);
        assert.equal(res.body.success, true);
        assert.equal(svc.calls.length, 1);
        assert.equal(svc.calls[0].name, svcMethod);
      } else {
        assert.equal(res.status, 403, who);
        assert.equal(svc.calls.length, 0, `${who}: servis cagrilmamali`);
      }
    }
    const { app } = build();
    const anon = await request(app)[method](`/api/v1${path}`);
    assert.equal(anon.status, 401);
  });
}

test('eski /api oneki de calisir; parametreler servise aynen gider', async () => {
  const { app, svc } = build();
  const res = await request(app).put(`/api/sites/${SITE}/flats/${FLAT}/device`).set('x-test-user', ACTORS.staff).send({ device_uuid: null });
  assert.equal(res.status, 200);
  assert.deepEqual(svc.calls[0].args.slice(0, 3), [SITE, FLAT, null]);
  // atolye-8: aktor (super_user IN_STOCK olmayan karti baglayabilir) servise gider
  assert.equal(svc.calls[0].args[3].globalRole, 'service_user');
  const r2 = await request(app).get(`/api/v1/templates?site_id=${SITE}&include_global=1`).set('x-test-user', ACTORS.super);
  assert.equal(r2.status, 200);
  assert.deepEqual(svc.calls[1].args, [{ siteId: SITE, includeGlobal: true }]);
});

test('PUT /templates/:id ayni govde: 200 + created:false; yeni surum: 200 + created:true', async () => {
  const { app } = build({ updateTemplate: { id: TPL, current_version: 3, created: false } });
  const res = await request(app).put(`/api/v1/templates/${TPL}`).set('x-test-user', ACTORS.staff).send({ body: {} });
  assert.equal(res.status, 200);
  assert.equal(res.body.data.created, false);
});

test('422 TEMPLATE_INVALID: error + path yanitta (CONTRACTS §3e)', async () => {
  const { app, svc } = build();
  svc.failWith.validate = httpError(422, 'Şablon geçersiz.', 'TEMPLATE_INVALID', { error: 'invalid_runtime', path: 'relays[3].runtime_s' });
  const res = await request(app).post('/api/v1/templates/validate').set('x-test-user', ACTORS.staff).send({ body: {} });
  assert.equal(res.status, 422);
  assert.equal(res.body.success, false);
  assert.equal(res.body.code, 'TEMPLATE_INVALID');
  assert.equal(res.body.error, 'invalid_runtime');
  assert.equal(res.body.path, 'relays[3].runtime_s');
});

test('yerel anahtar: no-store, aktor (kullanici + rol + ip) servise gider', async () => {
  const { app, svc } = build();
  const res = await request(app).get('/api/v1/admin/inventory/AHBU-S3-0001/local-key').set('x-test-user', ACTORS.staff);
  assert.equal(res.status, 200);
  assert.equal(res.body.data.local_key, 'GizliAnahtar123456');
  assert.match(res.headers['cache-control'], /no-store/);
  const [actor, uuid] = svc.calls[0].args;
  assert.equal(uuid, 'AHBU-S3-0001');
  assert.equal(actor.userId, 'u-staff');
  assert.equal(actor.globalRole, 'service_user');
});

test('yerel anahtar oran siniri: kullanici basina sinir asilinca 429', async () => {
  const realRateLimit = require('../../src/middlewares/rate_limit');
  const svc = createRecorder(METHODS, { getInventoryLocalKey: { local_key: 'k' } });
  const router = createRouter({ auth: fakeAuth(), rateLimit: realRateLimit, siteTemplateService: svc, localKeyMax: 2 });
  const app = express();
  app.use(express.json());
  app.use('/api/v1', router);
  const go = () => request(app).get('/api/v1/admin/inventory/AHBU-S3-0001/local-key').set('x-test-user', ACTORS.staff);
  assert.equal((await go()).status, 200);
  assert.equal((await go()).status, 200);
  const third = await go();
  assert.equal(third.status, 429);
  assert.equal(svc.calls.length, 2);
});
