'use strict';

// Yetki matrisi testi (CONTRACTS §1.4): her rol x her islem sinifi.

const test = require('node:test');
const assert = require('node:assert');
const express = require('express');
const request = require('supertest');
const jwt = require('jsonwebtoken');
const { setTestEnv, installFakeDb, uuid, makeAccessToken, makeServiceToken } = require('./_helpers');

setTestEnv();
const fakeDb = installFakeDb();
const auth = require('../../src/middlewares/auth_middleware');

const HOME = uuid();
const OTHER_HOME = uuid();
const NOW = Date.now();
const HOUR = 3600 * 1000;

const users = new Map();
const memberships = new Map(); // `${home}:${user}` -> row
const sessions = new Map();
const homes = new Set([HOME, OTHER_HOME]);

function addUser(name, role, extra = {}) {
  const u = { id: uuid(), email: `${name}@test.invalid`, full_name: name, role, is_active: true, account_status: 'active', token_version: 1, ...extra };
  users.set(u.id, u);
  return u;
}
function addMember(user, homeId, role, extra = {}) {
  memberships.set(`${homeId}:${user.id}`, { role, valid_from: null, valid_until: null, installer_expires_at: null, ...extra });
}

const P = {
  super: addUser('super', 'super_user'),
  staff: addUser('staff', 'service_user'),
  staffOutsider: addUser('staffOutsider', 'service_user'),
  owner: addUser('owner', 'user'),
  resident: addUser('resident', 'user'),
  guest: addUser('guest', 'user'),
  guestExpired: addUser('guestExpired', 'user'),
  guestFuture: addUser('guestFuture', 'user'),
  guestNoUntil: addUser('guestNoUntil', 'user'),
  stranger: addUser('stranger', 'user'),
  fakeStaff: addUser('fakeStaff', 'user'),
  legacyTempStaff: addUser('legacyTempStaff', 'service_user'),
  inactive: addUser('inactive', 'user', { is_active: false }),
  pending: addUser('pending', 'user', { account_status: 'pending_invite' }),
};
addMember(P.staff, HOME, 'service_user');
addMember(P.owner, HOME, 'owner');
addMember(P.resident, HOME, 'resident');
addMember(P.guest, HOME, 'guest', { valid_from: new Date(NOW - HOUR), valid_until: new Date(NOW + HOUR) });
addMember(P.guestExpired, HOME, 'guest', { valid_from: new Date(NOW - 3 * HOUR), valid_until: new Date(NOW - HOUR) });
addMember(P.guestFuture, HOME, 'guest', { valid_from: new Date(NOW + HOUR), valid_until: new Date(NOW + 2 * HOUR) });
addMember(P.guestNoUntil, HOME, 'guest', { valid_from: new Date(NOW - HOUR), valid_until: null });
addMember(P.fakeStaff, HOME, 'service_user');
addMember(P.legacyTempStaff, HOME, 'service_user', { installer_expires_at: new Date(NOW - HOUR) });
addMember(P.inactive, HOME, 'owner');
addMember(P.pending, HOME, 'owner');

const SID_OK = uuid();
const SID_REVOKED = uuid();
const SID_OTHER = uuid();
const SID_DB_EXPIRED = uuid();
sessions.set(SID_OK, { id: SID_OK, home_id: HOME, technician_name: 'Teknisyen', expires_at: new Date(NOW + HOUR), revoked_at: null });
sessions.set(SID_REVOKED, { id: SID_REVOKED, home_id: HOME, technician_name: 'T', expires_at: new Date(NOW + HOUR), revoked_at: new Date(NOW - 1000) });
sessions.set(SID_OTHER, { id: SID_OTHER, home_id: OTHER_HOME, technician_name: 'T', expires_at: new Date(NOW + HOUR), revoked_at: null });
sessions.set(SID_DB_EXPIRED, { id: SID_DB_EXPIRED, home_id: HOME, technician_name: 'T', expires_at: new Date(NOW - 1000), revoked_at: null });

fakeDb.on(/FROM users/, (params) => {
  const u = users.get(params[0]);
  return u ? [u] : [];
});
fakeDb.on(/FROM service_sessions/, (params) => {
  const s = sessions.get(params[0]);
  return s ? [s] : [];
});
fakeDb.on(/FROM home_users/, (params) => {
  const m = memberships.get(`${params[0]}:${params[1]}`);
  return m ? [m] : [];
});
fakeDb.on(/FROM homes WHERE id/, (params) => (homes.has(params[0]) ? [{ id: params[0] }] : []));

const OPS = Object.keys(auth.HOME_ROLE_SETS);

function buildApp() {
  const app = express();
  app.use(express.json());
  for (const op of OPS) {
    app.post(`/api/v1/homes/:homeId/op/${op}`, auth.authenticateToken, auth.requireHomeAccess(auth.HOME_ROLE_SETS[op]), (req, res) =>
      res.json({ success: true, access: req.homeAccess, user: req.user })
    );
  }
  app.post('/api/v1/devices/:id/command', auth.authenticateToken, auth.requireHomeAccess(auth.HOME_ROLE_SETS.CONTROL), (req, res) =>
    res.json({ success: true, access: req.homeAccess })
  );
  app.post('/api/v1/devices/claim', auth.authenticateToken, auth.rejectServiceSession, (req, res) => res.json({ success: true }));
  app.get('/api/v1/homes', auth.authenticateToken, (req, res) => res.json({ success: true, user: req.user }));
  app.get('/api/v1/admin/x', auth.authenticateToken, auth.requireServiceManager, (req, res) => res.json({ success: true }));
  app.get('/api/v1/admin/super', auth.authenticateToken, auth.requireSuperUser, (req, res) => res.json({ success: true }));
  return app;
}
const app = buildApp();

const tokenOf = (u) => makeAccessToken(u);
const svcToken = (sid, home = HOME) => makeServiceToken({ sid, home_id: home });

// Beklenen matris (1 = izinli). CONTRACTS §1.4
const EXPECT = {
  VIEW:          { super: 1, staff: 1, svc: 1, owner: 1, resident: 1, guest: 1 },
  CONTROL:       { super: 1, staff: 1, svc: 1, owner: 1, resident: 1, guest: 1 },
  GROUP_COMMAND: { super: 1, staff: 1, svc: 1, owner: 1, resident: 1, guest: 0 },
  CHILD_LOCK:    { super: 1, staff: 1, svc: 1, owner: 1, resident: 1, guest: 0 },
  CALIBRATE:     { super: 1, staff: 1, svc: 1, owner: 1, resident: 0, guest: 0 },
  RULES:         { super: 1, staff: 1, svc: 0, owner: 1, resident: 1, guest: 0 },
  MEMBERS:       { super: 1, staff: 0, svc: 0, owner: 1, resident: 0, guest: 0 },
  TRANSFER:      { super: 0, staff: 0, svc: 0, owner: 1, resident: 0, guest: 0 },
  SERVICE_PIN:   { super: 0, staff: 0, svc: 0, owner: 1, resident: 0, guest: 0 },
  COMMISSION:    { super: 1, staff: 1, svc: 1, owner: 0, resident: 0, guest: 0 },
  REPLACE_BOARD: { super: 1, staff: 1, svc: 1, owner: 1, resident: 0, guest: 0 },
  LOCAL_KEY:     { super: 0, staff: 1, svc: 1, owner: 1, resident: 1, guest: 0 },
};

test('matris kapsami: tum rol kumeleri test ediliyor', () => {
  assert.deepStrictEqual(Object.keys(EXPECT).sort(), OPS.slice().sort());
});

for (const op of OPS) {
  const principals = {
    super: () => tokenOf(P.super),
    staff: () => tokenOf(P.staff),
    svc: () => svcToken(SID_OK),
    owner: () => tokenOf(P.owner),
    resident: () => tokenOf(P.resident),
    guest: () => tokenOf(P.guest),
  };
  for (const [who, mk] of Object.entries(principals)) {
    const allowed = EXPECT[op][who] === 1;
    test(`matris: ${who} x ${op} -> ${allowed ? '200' : '403'}`, async () => {
      const res = await request(app).post(`/api/v1/homes/${HOME}/op/${op}`).set('Authorization', `Bearer ${mk()}`);
      assert.strictEqual(res.status, allowed ? 200 : 403, JSON.stringify(res.body));
      if (!allowed) assert.strictEqual(res.body.code, 'FORBIDDEN');
    });
  }

  // Yabanci kullanici / uye olmayan personel / sahte personel: her uc 403.
  for (const who of ['stranger', 'staffOutsider', 'fakeStaff', 'legacyTempStaff']) {
    test(`yabanci: ${who} x ${op} -> 403`, async () => {
      const res = await request(app).post(`/api/v1/homes/${HOME}/op/${op}`).set('Authorization', `Bearer ${tokenOf(P[who])}`);
      assert.strictEqual(res.status, 403);
      assert.strictEqual(res.body.code, 'FORBIDDEN');
    });
  }

  test(`servis oturumu baska ev x ${op} -> 403`, async () => {
    const res = await request(app).post(`/api/v1/homes/${HOME}/op/${op}`).set('Authorization', `Bearer ${svcToken(SID_OTHER, OTHER_HOME)}`);
    assert.strictEqual(res.status, 403);
  });

  test(`suresi dolmus misafir x ${op} -> 403 GUEST_EXPIRED`, async () => {
    for (const g of [P.guestExpired, P.guestFuture, P.guestNoUntil]) {
      const res = await request(app).post(`/api/v1/homes/${HOME}/op/${op}`).set('Authorization', `Bearer ${tokenOf(g)}`);
      assert.strictEqual(res.status, 403);
      assert.strictEqual(res.body.code, 'GUEST_EXPIRED');
    }
  });
}

test('sureli teknisyen uyeligi (installer_expires_at gelecekte) gecerli; gecmiste 403', async () => {
  const timed = addUser('timedStaff', 'service_user');
  addMember(timed, HOME, 'service_user', { installer_expires_at: new Date(Date.now() + HOUR) });
  const ok = await request(app).post(`/api/v1/homes/${HOME}/op/COMMISSION`).set('Authorization', `Bearer ${tokenOf(timed)}`);
  assert.strictEqual(ok.status, 200);
  assert.strictEqual(ok.body.access.role, 'service_user');
  memberships.get(`${HOME}:${timed.id}`).installer_expires_at = new Date(Date.now() - 1000);
  const no = await request(app).post(`/api/v1/homes/${HOME}/op/COMMISSION`).set('Authorization', `Bearer ${tokenOf(timed)}`);
  assert.strictEqual(no.status, 403);
});

test('super_user bypass yalnizca listede acikca varsa (TRANSFER/SERVICE_PIN listesinde yok)', async () => {
  const r1 = await request(app).post(`/api/v1/homes/${HOME}/op/TRANSFER`).set('Authorization', `Bearer ${tokenOf(P.super)}`);
  assert.strictEqual(r1.status, 403);
  const r2 = await request(app).post(`/api/v1/homes/${HOME}/op/VIEW`).set('Authorization', `Bearer ${tokenOf(P.super)}`);
  assert.strictEqual(r2.status, 200);
  assert.strictEqual(r2.body.access.is_super, true);
  assert.strictEqual(r2.body.access.role, 'super_user');
});

test('super_user olmayan ev -> 404', async () => {
  const res = await request(app).post(`/api/v1/homes/${uuid()}/op/VIEW`).set('Authorization', `Bearer ${tokenOf(P.super)}`);
  assert.strictEqual(res.status, 404);
  assert.strictEqual(res.body.code, 'NOT_FOUND');
});

test('req.homeAccess sozlesme alanlari (uye)', async () => {
  const res = await request(app).post(`/api/v1/homes/${HOME}/op/VIEW`).set('Authorization', `Bearer ${tokenOf(P.guest)}`);
  assert.strictEqual(res.status, 200);
  const a = res.body.access;
  assert.strictEqual(a.home_id, HOME);
  assert.strictEqual(a.role, 'guest');
  assert.strictEqual(a.is_super, false);
  assert.strictEqual(a.is_service_session, false);
  assert.ok(a.valid_until);
});

test('req.homeAccess sozlesme alanlari (servis oturumu) ve req.user.id === null', async () => {
  const res = await request(app).post(`/api/v1/homes/${HOME}/op/VIEW`).set('Authorization', `Bearer ${svcToken(SID_OK)}`);
  assert.strictEqual(res.status, 200);
  assert.strictEqual(res.body.access.role, 'service_session');
  assert.strictEqual(res.body.access.is_service_session, true);
  assert.strictEqual(res.body.user.id, null);
  assert.strictEqual(res.body.user.role, 'service_session');
});

test('home_id UUID olmali (parseInt yok): sayi/dize -> 400 VALIDATION', async () => {
  for (const bad of ['101', '1', 'abc', `${HOME}x`]) {
    const res = await request(app).post(`/api/v1/homes/${bad}/op/VIEW`).set('Authorization', `Bearer ${tokenOf(P.owner)}`);
    assert.strictEqual(res.status, 400, bad);
    assert.strictEqual(res.body.code, 'VALIDATION');
  }
});

test('govde home_id ile komut ucu: uye 200, yabanci 403, eksik 400', async () => {
  const ok = await request(app).post('/api/v1/devices/abc/command').set('Authorization', `Bearer ${tokenOf(P.resident)}`).send({ home_id: HOME });
  assert.strictEqual(ok.status, 200);
  const no = await request(app).post('/api/v1/devices/abc/command').set('Authorization', `Bearer ${tokenOf(P.stranger)}`).send({ home_id: HOME });
  assert.strictEqual(no.status, 403);
  const missing = await request(app).post('/api/v1/devices/abc/command').set('Authorization', `Bearer ${tokenOf(P.resident)}`).send({});
  assert.strictEqual(missing.status, 400);
});

test('yol ve govde home_id uyusmazligi -> 400 (IDOR savunmasi)', async () => {
  const res = await request(app)
    .post(`/api/v1/homes/${HOME}/op/VIEW`)
    .set('Authorization', `Bearer ${tokenOf(P.owner)}`)
    .send({ home_id: OTHER_HOME });
  assert.strictEqual(res.status, 400);
  assert.strictEqual(res.body.code, 'VALIDATION');
});

test('servis oturumu: ev kapsami olmayan uca giremez (claim) -> 403', async () => {
  const res = await request(app).post('/api/v1/devices/claim').set('Authorization', `Bearer ${svcToken(SID_OK)}`).send({});
  assert.strictEqual(res.status, 403);
});

test('servis oturumu: govdede baska ev -> 403; kendi evi -> 200', async () => {
  const bad = await request(app).post('/api/v1/devices/x/command').set('Authorization', `Bearer ${svcToken(SID_OK)}`).send({ home_id: OTHER_HOME });
  assert.strictEqual(bad.status, 403);
  const ok = await request(app).post('/api/v1/devices/x/command').set('Authorization', `Bearer ${svcToken(SID_OK)}`).send({ home_id: HOME });
  assert.strictEqual(ok.status, 200);
});

test('servis oturumu: GET /homes izinli (ev listesi)', async () => {
  const res = await request(app).get('/api/v1/homes').set('Authorization', `Bearer ${svcToken(SID_OK)}`);
  assert.strictEqual(res.status, 200);
});

test('servis oturumu: iptal edilmis / DB suresi dolmus -> 401 SERVICE_SESSION_EXPIRED', async () => {
  for (const sid of [SID_REVOKED, SID_DB_EXPIRED, uuid()]) {
    const res = await request(app).post(`/api/v1/homes/${HOME}/op/VIEW`).set('Authorization', `Bearer ${svcToken(sid)}`);
    assert.strictEqual(res.status, 401);
    assert.strictEqual(res.body.code, 'SERVICE_SESSION_EXPIRED');
  }
});

test('servis oturumu: token home_id ile DB home_id farkliysa -> 401', async () => {
  const res = await request(app).post(`/api/v1/homes/${OTHER_HOME}/op/VIEW`).set('Authorization', `Bearer ${svcToken(SID_OK, OTHER_HOME)}`);
  assert.strictEqual(res.status, 401);
});

test('servis oturumu: suresi dolmus JWT -> 401 SERVICE_SESSION_EXPIRED', async () => {
  const expired = jwt.sign(
    { sub: `service_session:${SID_OK}`, role: 'service_session', home_id: HOME, sid: SID_OK, exp: Math.floor(NOW / 1000) - 60 },
    process.env.JWT_SECRET,
    { algorithm: 'HS256', issuer: 'ahbu-ev-otomasyon' }
  );
  const res = await request(app).post(`/api/v1/homes/${HOME}/op/VIEW`).set('Authorization', `Bearer ${expired}`);
  assert.strictEqual(res.status, 401);
  assert.strictEqual(res.body.code, 'SERVICE_SESSION_EXPIRED');
});

test('servis oturumu global rol kapilarindan gecemez', async () => {
  const a = await request(app).get('/api/v1/admin/x?home_id=' + HOME).set('Authorization', `Bearer ${svcToken(SID_OK)}`);
  assert.strictEqual(a.status, 403);
  const b = await request(app).get('/api/v1/admin/super?home_id=' + HOME).set('Authorization', `Bearer ${svcToken(SID_OK)}`);
  assert.strictEqual(b.status, 403);
});

test('requireServiceManager / requireSuperUser global rolu DB den okur', async () => {
  assert.strictEqual((await request(app).get('/api/v1/admin/x').set('Authorization', `Bearer ${tokenOf(P.staff)}`)).status, 200);
  assert.strictEqual((await request(app).get('/api/v1/admin/x').set('Authorization', `Bearer ${tokenOf(P.owner)}`)).status, 403);
  assert.strictEqual((await request(app).get('/api/v1/admin/super').set('Authorization', `Bearer ${tokenOf(P.staff)}`)).status, 403);
  assert.strictEqual((await request(app).get('/api/v1/admin/super').set('Authorization', `Bearer ${tokenOf(P.super)}`)).status, 200);
  // Token'da super_user yazsa bile DB'de user ise super degildir.
  const forged = makeAccessToken({ id: P.owner.id, role: 'super_user', token_version: 1 });
  assert.strictEqual((await request(app).get('/api/v1/admin/super').set('Authorization', `Bearer ${forged}`)).status, 403);
});

test('token: yok -> 401 INVALID_TOKEN; bozuk imza -> 401 INVALID_TOKEN', async () => {
  const a = await request(app).get('/api/v1/homes');
  assert.strictEqual(a.status, 401);
  assert.strictEqual(a.body.code, 'INVALID_TOKEN');
  const forged = jwt.sign({ sub: P.owner.id, role: 'user', tv: 1 }, 'x'.repeat(64), { algorithm: 'HS256', issuer: 'ahbu-ev-otomasyon', expiresIn: 60 });
  const b = await request(app).get('/api/v1/homes').set('Authorization', `Bearer ${forged}`);
  assert.strictEqual(b.status, 401);
  assert.strictEqual(b.body.code, 'INVALID_TOKEN');
});

test('token: alg=none ve yanlis issuer reddedilir', async () => {
  const header = Buffer.from(JSON.stringify({ alg: 'none', typ: 'JWT' })).toString('base64url');
  const body = Buffer.from(JSON.stringify({ sub: P.super.id, role: 'super_user', tv: 1, iss: 'ahbu-ev-otomasyon', exp: Math.floor(NOW / 1000) + 600 })).toString('base64url');
  const none = `${header}.${body}.`;
  const r1 = await request(app).get('/api/v1/homes').set('Authorization', `Bearer ${none}`);
  assert.strictEqual(r1.status, 401);
  const wrongIss = jwt.sign({ sub: P.owner.id, role: 'user', tv: 1 }, process.env.JWT_SECRET, { algorithm: 'HS256', issuer: 'baska', expiresIn: 60 });
  const r2 = await request(app).get('/api/v1/homes').set('Authorization', `Bearer ${wrongIss}`);
  assert.strictEqual(r2.status, 401);
});

test('token: suresi dolmus -> 401 TOKEN_EXPIRED', async () => {
  const expired = jwt.sign({ sub: P.owner.id, role: 'user', tv: 1, exp: Math.floor(NOW / 1000) - 60 }, process.env.JWT_SECRET, { algorithm: 'HS256', issuer: 'ahbu-ev-otomasyon' });
  const res = await request(app).get('/api/v1/homes').set('Authorization', `Bearer ${expired}`);
  assert.strictEqual(res.status, 401);
  assert.strictEqual(res.body.code, 'TOKEN_EXPIRED');
});

test('token: eski bicim (id claim, sub/tv yok) -> 401 TOKEN_EXPIRED (istemci yenilesin)', async () => {
  const legacy = jwt.sign({ id: P.owner.id, role: 'user' }, process.env.JWT_SECRET, { algorithm: 'HS256', issuer: 'ahbu-ev-otomasyon', expiresIn: 60 });
  const res = await request(app).get('/api/v1/homes').set('Authorization', `Bearer ${legacy}`);
  assert.strictEqual(res.status, 401);
  assert.strictEqual(res.body.code, 'TOKEN_EXPIRED');
});

test('token: token_version uyusmazligi -> 401 INVALID_TOKEN (oturum iptali)', async () => {
  const u = addUser('tvUser', 'user');
  const tok = makeAccessToken(u);
  assert.strictEqual((await request(app).get('/api/v1/homes').set('Authorization', `Bearer ${tok}`)).status, 200);
  u.token_version = 2; // sifre degisti
  auth.invalidateUserAuthCache(u.id);
  const res = await request(app).get('/api/v1/homes').set('Authorization', `Bearer ${tok}`);
  assert.strictEqual(res.status, 401);
  assert.strictEqual(res.body.code, 'INVALID_TOKEN');
});

test('token: pasif / pending_invite / silinmis kullanici -> 401 INVALID_TOKEN', async () => {
  for (const u of [P.inactive, P.pending]) {
    const res = await request(app).post(`/api/v1/homes/${HOME}/op/VIEW`).set('Authorization', `Bearer ${tokenOf(u)}`);
    assert.strictEqual(res.status, 401);
    assert.strictEqual(res.body.code, 'INVALID_TOKEN');
  }
  const ghost = makeAccessToken({ id: uuid(), role: 'user', token_version: 1 });
  const res = await request(app).get('/api/v1/homes').set('Authorization', `Bearer ${ghost}`);
  assert.strictEqual(res.status, 401);
});

test('onbellek: TTL icinde DB yeniden okunmaz, invalidate ile hemen dusurulur', async () => {
  let t = NOW;
  let loads = 0;
  const u = { id: uuid(), email: 'c@test.invalid', full_name: 'c', role: 'user', is_active: true, account_status: 'active', token_version: 1 };
  auth.configureAuthMiddleware({
    cacheTtlMs: 30_000,
    now: () => t,
    loadUser: async (id) => {
      loads += 1;
      return id === u.id ? { ...u } : null;
    },
  });
  try {
    const tok = makeAccessToken(u);
    await request(app).get('/api/v1/homes').set('Authorization', `Bearer ${tok}`);
    await request(app).get('/api/v1/homes').set('Authorization', `Bearer ${tok}`);
    assert.strictEqual(loads, 1);
    t += 31_000;
    await request(app).get('/api/v1/homes').set('Authorization', `Bearer ${tok}`);
    assert.strictEqual(loads, 2);
    u.is_active = false;
    auth.invalidateUserAuthCache(u.id);
    const res = await request(app).get('/api/v1/homes').set('Authorization', `Bearer ${tok}`);
    assert.strictEqual(res.status, 401);
  } finally {
    auth.resetAuthMiddlewareConfig();
    auth.configureAuthMiddleware({ cacheTtlMs: 0 });
  }
});

test('onbellek TTL ust siniri 30 sn (daha buyuk deger kirpilir)', async () => {
  let t = NOW;
  let loads = 0;
  const u = { id: uuid(), email: 'd@test.invalid', full_name: 'd', role: 'user', is_active: true, account_status: 'active', token_version: 1 };
  auth.configureAuthMiddleware({
    cacheTtlMs: 10 * 60 * 1000,
    now: () => t,
    loadUser: async () => {
      loads += 1;
      return { ...u };
    },
  });
  try {
    const tok = makeAccessToken(u);
    await request(app).get('/api/v1/homes').set('Authorization', `Bearer ${tok}`);
    t += 31_000; // 10 dk istenmis olsa da 30 sn sonra yeniden okunmali
    await request(app).get('/api/v1/homes').set('Authorization', `Bearer ${tok}`);
    assert.strictEqual(loads, 2);
  } finally {
    auth.resetAuthMiddlewareConfig();
    auth.configureAuthMiddleware({ cacheTtlMs: 0 });
  }
});

test('requireHomeAccess: bilinmeyen rol tanim aninda hata (fail-loud)', () => {
  assert.throws(() => auth.requireHomeAccess(['owner', 'admin']), /bilinmeyen rol/);
  assert.throws(() => auth.requireHomeAccess([]), TypeError);
});

test('DB hatasi -> 500 INTERNAL, ic mesaj sizmaz', async () => {
  fakeDb.on(/FROM home_users/, () => new Error('relation "secret_table" does not exist'));
  try {
    const res = await request(app).post(`/api/v1/homes/${HOME}/op/VIEW`).set('Authorization', `Bearer ${tokenOf(P.owner)}`);
    assert.strictEqual(res.status, 500);
    assert.ok(!JSON.stringify(res.body).includes('secret_table'));
  } finally {
    fakeDb.on(/FROM home_users/, (params) => {
      const m = memberships.get(`${params[0]}:${params[1]}`);
      return m ? [m] : [];
    });
  }
});
