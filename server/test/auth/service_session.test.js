'use strict';

// A6: servis PIN'i ve servis oturumu (CONTRACTS §1.3)
//  - PIN yalnizca owner tarafindan; ozetli; tek kullanimlik; 2 saat; yeni PIN eskisini iptal eder
//  - giris kullanici satiri OLUSTURMAZ, global rol VERMEZ, refresh token YOK
//  - token yalnizca kendi evinin uclarina girer
//  - IP basina 10 deneme / 15 dk -> 429
//  - revokeHomeServiceAccess PIN ve oturumlari iptal eder

const test = require('node:test');
const assert = require('node:assert');
const express = require('express');
const request = require('supertest');
const jwt = require('jsonwebtoken');
const { setTestEnv, installFakeDb, makeAccessToken } = require('./_helpers');
const { createHomeStore } = require('./_home_store');

setTestEnv();
const fakeDb = installFakeDb();
let clock = Date.now();
const store = createHomeStore({ now: () => clock }).install(fakeDb);

const auth = require('../../src/middlewares/auth_middleware');
const authRoutes = require('../../src/routes/auth_routes');
const serviceRoutes = require('../../src/routes/service_routes');
const serviceTokenService = require('../../src/services/service_token_service');
const authService = require('../../src/services/auth_service');
const { errorHandler, asyncHandler } = require('../../src/middlewares/error_handler');

auth.configureAuthMiddleware({ cacheTtlMs: 0, now: () => clock });

const HOME = store.addHome({ name: 'Servis Evi' });
const OTHER = store.addHome({ name: 'Komsu Evi' });
const owner = store.addUser({ full_name: 'Ev Sahibi' });
const resident = store.addUser();
const guest = store.addUser();
const staff = store.addUser({ role: 'service_user' });
const superUser = store.addUser({ role: 'super_user' });
const stranger = store.addUser();
const otherOwner = store.addUser();
store.addMember(HOME, owner, 'owner');
store.addMember(HOME, resident, 'resident');
store.addMember(HOME, guest, 'guest', { valid_from: new Date(clock - 3600e3), valid_until: new Date(clock + 3600e3) });
store.addMember(HOME, staff, 'service_user');
store.addMember(OTHER, otherOwner, 'owner');

const app = express();
app.use(express.json());
app.use('/api/v1/auth', authRoutes);
app.get('/api/v1/homes', auth.authenticateToken, asyncHandler(async (req, res) => {
  const p = await authService.getProfile(req.user);
  res.json({ success: true, data: p.homes });
}));
app.post('/api/v1/homes/:homeId/commission-test', auth.authenticateToken, auth.requireHomeAccess(auth.HOME_ROLE_SETS.COMMISSION), (req, res) => res.json({ success: true, access: req.homeAccess }));
app.post('/api/v1/devices/claim', auth.authenticateToken, auth.rejectServiceSession, (req, res) => res.json({ success: true }));
app.use('/api/v1/homes/:home_id', serviceRoutes);
app.use(errorHandler);

const tok = (u) => makeAccessToken(u);
async function newPin(homeId = HOME.id, user = owner) {
  const res = await request(app).post(`/api/v1/homes/${homeId}/service-token`).set('Authorization', `Bearer ${tok(user)}`);
  assert.strictEqual(res.status, 201, JSON.stringify(res.body));
  return res.body.data.service_pin;
}
const login = (pin, name = 'Ali Usta') => request(app).post('/api/v1/auth/service-login').send({ service_pin: pin, technician_name: name });

test.beforeEach(() => {
  authRoutes.limiters.serviceLogin.reset();
  serviceRoutes.pinLimiter.reset();
});

test('PIN uretimi: kullanici basina saatte 10 -> 429', async () => {
  for (let i = 0; i < 10; i++) await newPin();
  const res = await request(app).post(`/api/v1/homes/${HOME.id}/service-token`).set('Authorization', `Bearer ${tok(owner)}`);
  assert.strictEqual(res.status, 429);
});

test('PIN uretimi: yalnizca owner; 6 hane; DB de ozet; yanit no-store', async () => {
  const res = await request(app).post(`/api/v1/homes/${HOME.id}/service-token`).set('Authorization', `Bearer ${tok(owner)}`);
  assert.strictEqual(res.status, 201);
  assert.match(res.body.data.service_pin, /^\d{6}$/);
  assert.strictEqual(res.headers['cache-control'], 'no-store');
  const row = store.tokens[store.tokens.length - 1];
  assert.match(row.pin_hash, /^h1\$[0-9a-f]{64}$/);
  assert.ok(!JSON.stringify(row).includes(res.body.data.service_pin));
});

for (const [who, user] of Object.entries({ resident, guest, staff, superUser, stranger, otherOwner })) {
  test(`PIN uretimi: ${who} -> 403`, async () => {
    const res = await request(app).post(`/api/v1/homes/${HOME.id}/service-token`).set('Authorization', `Bearer ${tok(user)}`);
    assert.strictEqual(res.status, 403);
  });
}

test('PIN listesi/oturum listesi/iptal: yabanci kullanici ve misafir -> 403; owner -> PIN degeri DONMEZ', async () => {
  for (const path of ['service-tokens', 'service-sessions']) {
    assert.strictEqual((await request(app).get(`/api/v1/homes/${HOME.id}/${path}`).set('Authorization', `Bearer ${tok(stranger)}`)).status, 403);
    assert.strictEqual((await request(app).get(`/api/v1/homes/${HOME.id}/${path}`).set('Authorization', `Bearer ${tok(guest)}`)).status, 403);
  }
  assert.strictEqual((await request(app).post(`/api/v1/homes/${HOME.id}/service-access/revoke`).set('Authorization', `Bearer ${tok(stranger)}`)).status, 403);
  const pin = await newPin();
  const list = await request(app).get(`/api/v1/homes/${HOME.id}/service-tokens`).set('Authorization', `Bearer ${tok(owner)}`);
  assert.strictEqual(list.status, 200);
  assert.ok(!JSON.stringify(list.body).includes(pin));
  assert.ok(list.body.data.every((t) => !('service_pin' in t) && !('pin_hash' in t)));
});

test('yeni PIN eskisini iptal eder', async () => {
  const p1 = await newPin();
  const p2 = await newPin();
  assert.strictEqual((await login(p1)).status, 401);
  assert.strictEqual((await login(p2)).status, 200);
});

test('servis girisi: sozlesme yaniti, refresh YOK, kullanici satiri / uyelik OLUSMAZ', async () => {
  const usersBefore = store.users.size;
  const membersBefore = store.members.length;
  const pin = await newPin();
  const res = await login(pin);
  assert.strictEqual(res.status, 200, JSON.stringify(res.body));
  const d = res.body.data;
  assert.ok(d.access_token);
  assert.strictEqual(d.refresh_token, undefined);
  assert.strictEqual(d.expires_in, 7200);
  assert.strictEqual(d.scope, 'home_service');
  assert.deepStrictEqual(d.home, { id: HOME.id, name: 'Servis Evi' });
  const claims = jwt.decode(d.access_token);
  assert.strictEqual(claims.role, 'service_session');
  assert.strictEqual(claims.home_id, HOME.id);
  assert.ok(claims.sid);
  assert.strictEqual(store.users.size, usersBefore);
  assert.strictEqual(store.members.length, membersBefore);
  assert.strictEqual(store.sessions[store.sessions.length - 1].technician_name, 'Ali Usta');
});

test('PIN tek kullanimlik; eszamanli iki giristen yalnizca biri basarili', async () => {
  const pin = await newPin();
  const [a, b] = await Promise.all([login(pin), login(pin)]);
  assert.deepStrictEqual([a.status, b.status].sort(), [200, 401]);
  assert.strictEqual((await login(pin)).status, 401);
});

test('suresi dolmus PIN reddedilir', async () => {
  const pin = await newPin();
  const row = store.tokens[store.tokens.length - 1];
  const ttlMs = row.expires_at.getTime() - clock;
  assert.ok(ttlMs > 2 * 3600e3 - 5000 && ttlMs <= 2 * 3600e3, `PIN suresi ${ttlMs} ms`);
  row.expires_at = new Date(clock - 1000); // 2 saat gecti
  const res = await login(pin);
  assert.strictEqual(res.status, 401);
});

test('oturum kapsami: kendi evi 200, baska ev 403, ev kapsamsiz uc 403, /homes yalnizca kendi evi', async () => {
  const pin = await newPin();
  const t = (await login(pin)).body.data.access_token;
  const own = await request(app).post(`/api/v1/homes/${HOME.id}/commission-test`).set('Authorization', `Bearer ${t}`);
  assert.strictEqual(own.status, 200);
  assert.strictEqual(own.body.access.is_service_session, true);
  assert.strictEqual((await request(app).post(`/api/v1/homes/${OTHER.id}/commission-test`).set('Authorization', `Bearer ${t}`)).status, 403);
  assert.strictEqual((await request(app).post('/api/v1/devices/claim').set('Authorization', `Bearer ${t}`).send({})).status, 403);
  // servis oturumu PIN uretemez (owner degil)
  assert.strictEqual((await request(app).post(`/api/v1/homes/${HOME.id}/service-token`).set('Authorization', `Bearer ${t}`)).status, 403);
  const homes = await request(app).get('/api/v1/homes').set('Authorization', `Bearer ${t}`);
  assert.strictEqual(homes.status, 200);
  assert.strictEqual(homes.body.data.length, 1);
  assert.strictEqual(homes.body.data[0].id, HOME.id);
  assert.strictEqual(homes.body.data[0].role, 'service_session');
});

test('revokeHomeServiceAccess: acik oturum aninda 401 SERVICE_SESSION_EXPIRED, kullanilmamis PIN iptal', async () => {
  const pinA = await newPin();
  const t = (await login(pinA)).body.data.access_token;
  const pinB = await newPin();
  const r = await serviceTokenService.revokeHomeServiceAccess(HOME.id, null, 'test');
  assert.ok(r.revoked_sessions >= 1);
  assert.ok(r.revoked_pins >= 1);
  const res = await request(app).post(`/api/v1/homes/${HOME.id}/commission-test`).set('Authorization', `Bearer ${t}`);
  assert.strictEqual(res.status, 401);
  assert.strictEqual(res.body.code, 'SERVICE_SESSION_EXPIRED');
  assert.strictEqual((await login(pinB)).status, 401);
});

test('owner "servis erisimini kapat" ucu ayni etkiyi yapar', async () => {
  const pin = await newPin();
  const t = (await login(pin)).body.data.access_token;
  const res = await request(app).post(`/api/v1/homes/${HOME.id}/service-access/revoke`).set('Authorization', `Bearer ${tok(owner)}`);
  assert.strictEqual(res.status, 200);
  assert.strictEqual((await request(app).post(`/api/v1/homes/${HOME.id}/commission-test`).set('Authorization', `Bearer ${t}`)).status, 401);
});

test('IP basina 10 deneme / 15 dk -> 429 RATE_LIMITED', async () => {
  for (let i = 0; i < 10; i++) {
    const r = await login(String(100000 + i));
    assert.strictEqual(r.status, 401);
  }
  const blocked = await login('123456');
  assert.strictEqual(blocked.status, 429);
  assert.strictEqual(blocked.body.code, 'RATE_LIMITED');
  assert.ok(blocked.headers['retry-after']);
});

test('PIN bicimi gecersiz -> 400; teknisyen adi kontrol karakterlerinden temizlenir', async () => {
  assert.strictEqual((await login('12ab56')).status, 400);
  const pin = await newPin();
  const res = await login(pin, 'Ali\u0000\nUsta\t');
  assert.strictEqual(res.status, 200);
  assert.strictEqual(store.sessions[store.sessions.length - 1].technician_name, 'Ali Usta');
});

test('sahte DB: eslesmeyen SQL yok', () => {
  assert.deepStrictEqual(store.unmatched, []);
});
