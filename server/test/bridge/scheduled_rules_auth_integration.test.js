'use strict';

// C8 - Zamanli kural uclari x GERCEK auth_middleware (A paketi) entegrasyonu.
// Veritabani modulu bellek ici sahte ile degistirilir (gercek PostgreSQL YOK); JWT gizli degeri
// calisma aninda rastgele uretilir (koda gomulu sir yok). Her test dosyasi ayri surecte calisir
// (node --test), bu yuzden require.cache degisikligi baska testleri etkilemez.

const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const express = require('express');
const request = require('supertest');

process.env.JWT_SECRET = crypto.randomBytes(32).toString('hex');

// --- sahte veritabani (auth_middleware ve gercek servis bunu kullanir) ---------------
const HOME = '11111111-1111-4111-8111-111111111111';
const OTHER_HOME = '22222222-2222-4222-8222-222222222222';
const u = (n) => `00000000-0000-4000-8000-0000000000${String(n).padStart(2, '0')}`;
const USERS = {
  owner: { id: u(1), role: 'user' },
  resident: { id: u(2), role: 'user' },
  guest: { id: u(3), role: 'user' },
  expiredGuest: { id: u(4), role: 'user' },
  staff: { id: u(5), role: 'service_user' },
  fakeStaff: { id: u(6), role: 'user' }, // ev bazli 'service_user' kaydi var ama global rol personel DEGIL
  superUser: { id: u(7), role: 'super_user' },
  outsider: { id: u(8), role: 'user' },
};
const MEMBERSHIPS = {
  [`${HOME}:${USERS.owner.id}`]: { role: 'owner' },
  [`${HOME}:${USERS.resident.id}`]: { role: 'resident' },
  [`${HOME}:${USERS.guest.id}`]: { role: 'guest', valid_from: null, valid_until: new Date(Date.now() + 3600e3) },
  [`${HOME}:${USERS.expiredGuest.id}`]: { role: 'guest', valid_from: null, valid_until: new Date(Date.now() - 3600e3) },
  [`${HOME}:${USERS.staff.id}`]: { role: 'service_user' },
  [`${HOME}:${USERS.fakeStaff.id}`]: { role: 'service_user' },
};
const SESSION_ID = '99999999-9999-4999-8999-999999999999';

const dbCalls = [];
const fakeDb = {
  pool: {},
  async query(text, params) {
    dbCalls.push({ text, params });
    if (/FROM home_users/.test(text)) {
      const m = MEMBERSHIPS[`${params[0]}:${params[1]}`];
      return { rows: m ? [{ valid_from: null, valid_until: null, installer_expires_at: null, ...m }] : [] };
    }
    if (/SELECT id FROM homes WHERE id = \$1/.test(text)) {
      return { rows: params[0] === HOME ? [{ id: HOME }] : [] };
    }
    return { rows: [], rowCount: 0 };
  },
  async withTransaction(fn) {
    return fn({ query: fakeDb.query });
  },
};
const dbPath = require.resolve('../../src/db');
require.cache[dbPath] = { id: dbPath, filename: dbPath, loaded: true, exports: fakeDb };

const authMw = require('../../src/middlewares/auth_middleware');
const { signAccessToken, signServiceSessionToken } = require('../../src/middlewares/jwt_config');
const { createRouter } = require('../../src/routes/scheduled_rules_routes');
const { errorHandler, notFoundHandler } = require('../../src/middlewares/error_handler');

authMw.configureAuthMiddleware({
  cacheTtlMs: 0,
  loadUser: async (id) => {
    const user = Object.values(USERS).find((x) => x.id === id);
    return user
      ? { id: user.id, email: `${user.id}@example.invalid`, full_name: 'Test', role: user.role, is_active: true, account_status: 'active', token_version: 1 }
      : null;
  },
  loadServiceSession: async (sid) =>
    sid === SESSION_ID ? { id: sid, home_id: HOME, technician_name: 'Usta', expires_at: new Date(Date.now() + 3600e3), revoked_at: null } : null,
});

const serviceCalls = [];
const service = {
  listRules: async (homeId) => {
    serviceCalls.push(['listRules', homeId]);
    return [];
  },
  createRule: async (homeId, userId, body) => {
    serviceCalls.push(['createRule', homeId, userId]);
    return { id: 1, channel: body.channel };
  },
  updateRule: async (homeId, ruleId) => {
    serviceCalls.push(['updateRule', homeId, ruleId]);
    return { id: ruleId };
  },
  deleteRule: async (homeId, ruleId) => {
    serviceCalls.push(['deleteRule', homeId, ruleId]);
    return { id: ruleId };
  },
};

// Gercek hiz sinirlayici (A'nin rate_limit.js)
const rateLimit = require('../../src/middlewares/rate_limit');
const app = express();
app.use(express.json());
const router = createRouter({ auth: authMw, service, rateLimit, logger: { error() {}, log() {}, warn() {} } });
app.use('/api/v1/homes', router);
app.use('/api/homes', router);
app.use(notFoundHandler);
app.use(errorHandler);

const bearer = (token) => ({ Authorization: `Bearer ${token}` });
const userToken = (user, tv = 1) => signAccessToken({ id: user.id, role: user.role, token_version: tv });
const sessionToken = (homeId = HOME) => signServiceSessionToken({ sid: SESSION_ID, home_id: homeId });

const BODY = { channel: 3, channel_type: 'relay', action: 'on', hour: 8, minute: 30 };
const CALLS = [
  ['GET', '/scheduled-rules', null],
  ['POST', '/scheduled-rules', BODY],
  ['PUT', '/scheduled-rules/5', { enabled: false }],
  ['DELETE', '/scheduled-rules/5', null],
];

async function hit(method, path, headers, body, home = HOME, base = '/api/v1/homes') {
  let req = request(app)[method.toLowerCase()](`${base}/${home}${path}`);
  if (headers) req = req.set(headers);
  return body ? req.send(body) : req;
}

test('GERCEK auth_middleware: owner/resident/staff/super TUM uclara girer', async () => {
  for (const who of ['owner', 'resident', 'staff', 'superUser']) {
    for (const [method, path, body] of CALLS) {
      const res = await hit(method, path, bearer(userToken(USERS[who])), body);
      assert.ok(res.status < 300, `${who} ${method} ${path} -> ${res.status} ${JSON.stringify(res.body)}`);
    }
  }
});

test('GERCEK auth_middleware: eski /api yolu da calisir', async () => {
  const res = await hit('GET', '/scheduled-rules', bearer(userToken(USERS.owner)), null, HOME, '/api/homes');
  assert.equal(res.status, 200);
});

test('GERCEK auth_middleware: gecerli misafir, suresi dolmus misafir, sahte staff, uye olmayan reddedilir', async () => {
  serviceCalls.length = 0;
  const cases = [
    ['guest', 403, 'FORBIDDEN'],
    ['expiredGuest', 403, 'GUEST_EXPIRED'],
    ['fakeStaff', 403, 'FORBIDDEN'], // 'service_user' uyeligi var ama global rol personel degil
    ['outsider', 403, 'FORBIDDEN'],
  ];
  for (const [who, status, code] of cases) {
    for (const [method, path, body] of CALLS) {
      const res = await hit(method, path, bearer(userToken(USERS[who])), body);
      assert.equal(res.status, status, `${who} ${method} ${path}`);
      assert.equal(res.body.code, code, `${who} ${method} ${path}`);
    }
  }
  assert.equal(serviceCalls.length, 0, 'yetkisiz isteklerde servis cagrilmamali');
});

test('GERCEK auth_middleware: servis (PIN) oturumu hicbir kural ucuna GIREMEZ (kendi evinde bile)', async () => {
  serviceCalls.length = 0;
  for (const [method, path, body] of CALLS) {
    const res = await hit(method, path, bearer(sessionToken()), body);
    assert.equal(res.status, 403, `${method} ${path} -> ${res.status} ${JSON.stringify(res.body)}`);
    assert.equal(res.body.code, 'FORBIDDEN');
  }
  assert.equal(serviceCalls.length, 0);
});

test('GERCEK auth_middleware: servis oturumu baska evin kural ucuna da giremez', async () => {
  const res = await hit('GET', '/scheduled-rules', bearer(sessionToken()), null, OTHER_HOME);
  assert.equal(res.status, 403);
});

test('GERCEK auth_middleware: tokensiz 401, gecersiz/eski surum (tv) 401', async () => {
  const none = await hit('GET', '/scheduled-rules', null, null);
  assert.equal(none.status, 401);
  const garbage = await hit('GET', '/scheduled-rules', bearer('abc.def.ghi'), null);
  assert.equal(garbage.status, 401);
  const staleTv = await hit('GET', '/scheduled-rules', bearer(userToken(USERS.owner, 99)), null);
  assert.equal(staleTv.status, 401);
  assert.equal(staleTv.body.code, 'INVALID_TOKEN');
});

test('GERCEK auth_middleware: super_user var olmayan evde 404; gecersiz UUID 400', async () => {
  const missing = await hit('GET', '/scheduled-rules', bearer(userToken(USERS.superUser)), null, OTHER_HOME);
  assert.equal(missing.status, 404);
  const bad = await hit('GET', '/scheduled-rules', bearer(userToken(USERS.owner)), null, '101');
  assert.equal(bad.status, 400);
  assert.equal(bad.body.code, 'VALIDATION');
});

test('GERCEK auth_middleware: govdedeki farkli home_id ev kimligi catismasi olarak REDDEDILIR (400)', async () => {
  serviceCalls.length = 0;
  const res = await hit('POST', '/scheduled-rules', bearer(userToken(USERS.owner)), { ...BODY, home_id: OTHER_HOME });
  assert.equal(res.status, 400);
  assert.equal(serviceCalls.length, 0);
  // govdedeki home_id URL ile ayniysa sorun yok (Flutter ScheduledRule.toJson home_id gonderir)
  const same = await hit('POST', '/scheduled-rules', bearer(userToken(USERS.owner)), { ...BODY, home_id: HOME });
  assert.equal(same.status, 201);
});

test('GERCEK auth_middleware: servis cagrisina gecen kimlikler dogru (ev URL\'den, kullanici token\'dan)', async () => {
  serviceCalls.length = 0;
  await hit('POST', '/scheduled-rules', bearer(userToken(USERS.resident)), BODY);
  assert.deepEqual(serviceCalls[0], ['createRule', HOME, USERS.resident.id]);
});

test('router, auth_middleware.HOME_ROLE_SETS.RULES kumesini kullanir (matris tek yerde)', () => {
  assert.ok(authMw.HOME_ROLE_SETS && Array.isArray(authMw.HOME_ROLE_SETS.RULES));
  for (const role of authMw.HOME_ROLE_SETS.RULES) {
    assert.ok(['super_user', 'service_user', 'owner', 'resident'].includes(role), role);
  }
  assert.equal(authMw.HOME_ROLE_SETS.RULES.includes('guest'), false);
  assert.equal(authMw.HOME_ROLE_SETS.RULES.includes('service_session'), false);
});
