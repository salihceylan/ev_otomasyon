'use strict';

// Servis sorumlusu KAPSAMI (045) - requireHomeAccess: kiraci (service_user + homes.service_owner_id = kullanici)
//   - uyeliksiz ve kurulum penceresiz (is_super + is_tenant_admin; role izin listesinde super_user varsa 'super_user', yoksa 'service_user')
//   - hicbir rol kumesinde service_user/super_user yoksa (daire devri, servis PIN'i, hirsiz alarmi kurma) kapsam bir sey vermez
//   - evin servisi BASKA servisse kalan servis uyeligi gecersiz; sahipsiz (kok) evde eski uyelik kurali aynen
//   - role_matrix: kiraci icin etkin rol kapinin verdigi rol (local_key service_user'a acik, super_user'a kapali)
//   - requireRoot: yalniz global super_user (kiraci ve servis oturumu 403)

const test = require('node:test');
const assert = require('node:assert');
const express = require('express');
const request = require('supertest');
const { setTestEnv, installFakeDb, uuid, makeAccessToken, makeServiceToken } = require('./_helpers');

setTestEnv();
const fakeDb = installFakeDb();
const auth = require('../../src/middlewares/auth_middleware');
const roleMatrix = require('../../src/utils/role_matrix');

const NOW = Date.now();
const HOUR = 3600 * 1000;
const HOME_A = uuid(); // servis A nin evi
const HOME_B = uuid(); // servis B nin evi
const HOME_ROOT = uuid(); // sahipsiz (kok) ev
const users = new Map();
const memberships = new Map();
const homes = new Map(); // id -> service_owner_id

function addUser(name, role, extra = {}) {
  const u = { id: uuid(), email: `${name}@test.invalid`, full_name: name, role, is_active: true, account_status: 'active', token_version: 1, ...extra };
  users.set(u.id, u);
  return u;
}
function addMember(user, homeId, role, extra = {}) {
  memberships.set(`${homeId}:${user.id}`, { role, valid_from: null, valid_until: null, installer_expires_at: null, ...extra });
}

const P = {
  root: addUser('root', 'super_user'),
  svcA: addUser('svcA', 'service_user'),
  svcB: addUser('svcB', 'service_user'),
  demoted: addUser('demoted', 'user'), // eskiden servisti, artik 'user' (service_owner_id ona isaret ederse bile yetki yok)
  owner: addUser('owner', 'user'),
  suspendedSvc: addUser('suspendedSvc', 'service_user', { is_active: false }),
};
homes.set(HOME_A, P.svcA.id);
homes.set(HOME_B, P.svcB.id);
homes.set(HOME_ROOT, null);
addMember(P.owner, HOME_A, 'owner');
// A nin uyeligi: 72 saatlik pencere COKTAN bitmis (eski veri); yine de kapsam sayesinde erisim surer
addMember(P.svcA, HOME_A, 'service_user', { installer_expires_at: new Date(NOW - 5 * 24 * HOUR) });
// B nin A evinde kalmis eski gecerli uyeligi: evin servisi A oldugu icin GECERSIZ
addMember(P.svcB, HOME_A, 'service_user', { installer_expires_at: new Date(NOW + HOUR) });
addMember(P.svcB, HOME_B, 'service_user');
// kok evinde eski (pencereli) servis uyeligi: eski kural aynen
addMember(P.svcA, HOME_ROOT, 'service_user', { installer_expires_at: new Date(NOW + HOUR) });

fakeDb.on(/FROM users/, (params) => (users.has(params[0]) ? [users.get(params[0])] : []));
fakeDb.on(/FROM home_users/, (params) => {
  const m = memberships.get(`${params[0]}:${params[1]}`);
  return m ? [m] : [];
});
let columnMissing = false; // migration 045 uygulanmamis veritabani simulasyonu
fakeDb.on(/SELECT service_owner_id FROM homes WHERE id = \$1/, (params) => {
  if (columnMissing) throw Object.assign(new Error('column "service_owner_id" does not exist'), { code: '42703' });
  return homes.has(params[0]) ? [{ service_owner_id: homes.get(params[0]) }] : [];
});
fakeDb.on(/SELECT id FROM homes WHERE id = \$1/, (params) => (homes.has(params[0]) ? [{ id: params[0] }] : []));

const OPS = Object.keys(auth.HOME_ROLE_SETS);
const app = express();
app.use(express.json());
for (const op of OPS) {
  app.post(`/api/v1/homes/:homeId/op/${op}`, auth.authenticateToken, auth.requireHomeAccess(auth.HOME_ROLE_SETS[op]), (req, res) =>
    res.json({ success: true, access: req.homeAccess })
  );
}
app.get('/api/v1/admin/root', auth.authenticateToken, auth.requireRoot, (req, res) => res.json({ success: true }));

const T = (u) => `Bearer ${makeAccessToken(u)}`;
const call = (who, home, op) => request(app).post(`/api/v1/homes/${home}/op/${op}`).set('Authorization', T(who)).send({});

test('kiraci: kendi evinde izin listesinde super_user/service_user olan HER islem acik (pencere bitmis olsa da); rol listeye gore', async () => {
  for (const op of OPS) {
    const list = auth.HOME_ROLE_SETS[op];
    const expectRole = list.includes('super_user') ? 'super_user' : list.includes('service_user') ? 'service_user' : null;
    const r = await call(P.svcA, HOME_A, op);
    if (expectRole) {
      assert.strictEqual(r.status, 200, `${op}: ${JSON.stringify(r.body)}`);
      assert.strictEqual(r.body.access.role, expectRole, `${op}: rol`);
      assert.strictEqual(r.body.access.is_super, true);
      assert.strictEqual(r.body.access.is_tenant_admin, true);
      assert.strictEqual(r.body.access.valid_until, null);
      assert.strictEqual(r.body.access.installer_expires_at, null, 'kurulum penceresi YOK');
      assert.strictEqual(r.body.access.home_id, HOME_A);
    } else {
      assert.strictEqual(r.status, 403, `${op}: ev sahibi/sakin-yalniz islemlerde kapsam bir sey vermez`);
    }
  }
  // ev sahibi-yalniz islemler somut olarak
  for (const op of ['TRANSFER', 'SERVICE_PIN']) assert.strictEqual((await call(P.svcA, HOME_A, op)).status, 403, op);
  assert.strictEqual((await call(P.svcA, HOME_A, 'MEMBERS')).status, 200);
  assert.strictEqual((await call(P.svcA, HOME_A, 'COMMISSION')).status, 200);
  // hirsiz alarmi kurma/cozme hicbir servis rolunde yok (role_matrix safety_arm)
  assert.strictEqual(roleMatrix.can('safety_arm', 'super_user'), false);
  assert.strictEqual(roleMatrix.can('safety_arm', 'service_user'), false);
});

test('kiraci: baska servisin evi 403 (kalan gecerli uyelik olsa bile); kendi kapsaminda olmayan sahipsiz ev yalniz eski uyelik kuraliyla', async () => {
  for (const op of OPS) {
    const list = auth.HOME_ROLE_SETS[op];
    if (!list.includes('super_user') && !list.includes('service_user')) continue;
    assert.strictEqual((await call(P.svcA, HOME_B, op)).status, 403, `A -> B evi (${op})`);
    assert.strictEqual((await call(P.svcB, HOME_A, op)).status, 403, `B -> A evi: kalan uyelik gecersiz (${op})`);
  }
  // sahipsiz (kok) ev: uyeligi olmayan servis 403; pencereli eski uyelik aynen calisir (rol 'service_user', is_super false)
  assert.strictEqual((await call(P.svcB, HOME_ROOT, 'VIEW')).status, 403);
  const legacy = await call(P.svcA, HOME_ROOT, 'VIEW');
  assert.strictEqual(legacy.status, 200);
  assert.strictEqual(legacy.body.access.role, 'service_user');
  assert.strictEqual(legacy.body.access.is_super, false);
  assert.strictEqual(legacy.body.access.is_tenant_admin, undefined);
  assert.ok(legacy.body.access.installer_expires_at, 'eski kural: pencere aranir');
  // MEMBERS (owner | super_user) listesinde eski uyelik super vermez
  assert.strictEqual((await call(P.svcA, HOME_ROOT, 'MEMBERS')).status, 403);
  // pencere dolunca sahipsiz evde erisim biter
  memberships.get(`${HOME_ROOT}:${P.svcA.id}`).installer_expires_at = new Date(NOW - HOUR);
  assert.strictEqual((await call(P.svcA, HOME_ROOT, 'VIEW')).status, 403);
});

test('kiraci: servis rolu dusurulmus / pasif hesap yetki alamaz; kok her evde; servis oturumu degismez', async () => {
  // service_owner_id eski servise isaret etse de hesap artik 'user'
  homes.set(HOME_B, P.demoted.id);
  assert.strictEqual((await call(P.demoted, HOME_B, 'VIEW')).status, 403);
  assert.strictEqual((await call(P.svcB, HOME_B, 'VIEW')).status, 403, 'evin servisi artik baska hesap: eski uyelik gecersiz');
  homes.set(HOME_B, P.svcB.id);
  assert.strictEqual((await call(P.svcB, HOME_B, 'VIEW')).status, 200);
  // pasif servis hesabi 401
  homes.set(HOME_B, P.suspendedSvc.id);
  assert.strictEqual((await call(P.suspendedSvc, HOME_B, 'VIEW')).status, 401);
  homes.set(HOME_B, P.svcB.id);
  // kok: super_user her evde, is_tenant_admin yok
  const r = await call(P.root, HOME_B, 'MEMBERS');
  assert.strictEqual(r.status, 200);
  assert.strictEqual(r.body.access.role, 'super_user');
  assert.strictEqual(r.body.access.is_tenant_admin, undefined);
  // servis oturumu (PIN): yalniz kendi evi ve listede service_session varsa
  const sid = uuid();
  fakeDb.on(/FROM service_sessions/, (p) => (p[0] === sid ? [{ id: sid, home_id: HOME_A, technician_name: 't', expires_at: new Date(NOW + HOUR), revoked_at: null }] : []));
  const s = await request(app).post(`/api/v1/homes/${HOME_A}/op/VIEW`).set('Authorization', `Bearer ${makeServiceToken({ sid, home_id: HOME_A })}`).send({});
  assert.strictEqual(s.status, 200);
  assert.strictEqual(s.body.access.role, 'service_session');
  assert.strictEqual(s.body.access.is_tenant_admin, undefined);
});

test('migration 045 uygulanmamis veritabani (42703): kiraci kapsami yok, eski uyelik kurali aynen (erisim kesilmez)', async () => {
  memberships.get(`${HOME_ROOT}:${P.svcA.id}`).installer_expires_at = new Date(Date.now() + HOUR); // (onceki test bitirmisti)
  columnMissing = true;
  try {
    // pencereli gecerli eski uyelik calisir
    assert.strictEqual((await call(P.svcA, HOME_ROOT, 'VIEW')).status, 200);
    // kapsam yok -> suresi bitmis uyelik (tenant penceresi) erisim vermez; owner normal
    assert.strictEqual((await call(P.svcA, HOME_A, 'VIEW')).status, 403);
    assert.strictEqual((await call(P.owner, HOME_A, 'VIEW')).status, 200);
  } finally {
    columnMissing = false;
  }
  assert.strictEqual((await call(P.svcA, HOME_A, 'VIEW')).status, 200, 'kolon geri gelince kapsam yeniden gecerli');
});

test('role_matrix.effectiveRole: kiraci icin kapinin verdigi rol (is_super olsa da); local_key kiraciya acik', () => {
  const tenantStaff = { home_id: 'x', role: 'service_user', is_super: true, is_tenant_admin: true };
  const tenantSuper = { home_id: 'x', role: 'super_user', is_super: true, is_tenant_admin: true };
  assert.strictEqual(roleMatrix.effectiveRole(tenantStaff), 'service_user');
  assert.strictEqual(roleMatrix.effectiveRole(tenantSuper), 'super_user');
  assert.strictEqual(roleMatrix.can('local_key', tenantStaff), true, 'local_key service_user a acik');
  assert.strictEqual(roleMatrix.can('local_key', { role: 'super_user', is_super: true }), false, 'kok icin degismedi');
  assert.strictEqual(roleMatrix.can('safety_arm', tenantSuper), false);
  assert.strictEqual(roleMatrix.can('safety_arm', tenantStaff), false);
  assert.strictEqual(roleMatrix.can('actuator_control', tenantSuper), true);
});

test('requireRoot: yalniz global super_user; kiraci/servis oturumu/kullanici 403; tokensiz 401', async () => {
  const go = (token) => request(app).get('/api/v1/admin/root').set('Authorization', token);
  assert.strictEqual((await go(T(P.root))).status, 200);
  for (const who of [P.svcA, P.svcB, P.owner]) assert.strictEqual((await go(T(who))).status, 403, who.email);
  assert.strictEqual((await request(app).get('/api/v1/admin/root')).status, 401);
  const svcTok = `Bearer ${makeServiceToken({ sid: uuid(), home_id: HOME_A })}`;
  assert.ok([401, 403].includes((await go(svcTok)).status));
});
