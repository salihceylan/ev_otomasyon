'use strict';

// utils/tenant_scope.js: saf kapsam kararlari (servis sorumlusu kapsami, migration 045)

const test = require('node:test');
const assert = require('node:assert');
const ts = require('../../src/utils/tenant_scope');

const A = '11111111-1111-4111-8111-111111111111';
const B = '22222222-2222-4222-8222-222222222222';
const ROOT = { userId: '99999999-9999-4999-8999-999999999999', globalRole: 'super_user' };
const SVC_A = { userId: A, globalRole: 'service_user' };
const SVC_B = { userId: B, globalRole: 'service_user' };

test('aktor bicimleri: actorOf (userId/globalRole), req.user (id/role), envanter aktoru (type)', () => {
  assert.strictEqual(ts.isRoot(ROOT), true);
  assert.strictEqual(ts.isRoot({ id: 'r', role: 'super_user' }), true);
  assert.strictEqual(ts.isRoot({ type: 'super_user', userId: 'r' }), true);
  assert.strictEqual(ts.isRoot({ type: 'api_key', userId: null }), true, 'fabrika API anahtari kok-esdeger');
  assert.strictEqual(ts.isRoot(null), true, 'dahili cagri (aktor yok) kok sayilir');
  assert.strictEqual(ts.isRoot(SVC_A), false);
  assert.strictEqual(ts.isRoot({ userId: 'u', globalRole: 'user' }), false);
  assert.strictEqual(ts.isRoot({ isServiceSession: true, globalRole: 'service_session' }), false, 'servis oturumu kok degil');
  assert.strictEqual(ts.isService(SVC_A), true);
  assert.strictEqual(ts.isService({ id: A, role: 'service_user' }), true);
  assert.strictEqual(ts.isService({ type: 'service_user', userId: A }), true);
  assert.strictEqual(ts.isService({ globalRole: 'service_user' }), false, 'kimliksiz servis aktoru gecersiz');
  assert.strictEqual(ts.isService(ROOT), false);
  assert.strictEqual(ts.actorId({ userId: 'ABC' }), 'abc');
  assert.strictEqual(ts.sameId(A.toUpperCase(), A), true);
  assert.strictEqual(ts.sameId(null, null), false, 'null != null (kimliksiz esitlik yetki vermez)');
});

test('inventoryScope / mayInstall / mayManageCard: kok, kiraci, kok stogu, baska servis', () => {
  const own = { service_owner_id: A, status: 'CLAIMED' };
  const foreign = { service_owner_id: B, status: 'IN_STOCK' };
  const rootStock = { service_owner_id: null, status: 'IN_STOCK' };
  const rootInstalled = { service_owner_id: null, status: 'CLAIMED' };
  assert.strictEqual(ts.inventoryScope(ROOT, foreign), 'root');
  assert.strictEqual(ts.inventoryScope(SVC_A, own), 'tenant');
  assert.strictEqual(ts.inventoryScope(SVC_A, foreign), null);
  assert.strictEqual(ts.inventoryScope(SVC_A, rootStock), 'root_stock');
  assert.strictEqual(ts.inventoryScope(SVC_A, rootInstalled), null, 'kurulu kok karti servise kapali');
  assert.strictEqual(ts.inventoryScope({ userId: 'u', globalRole: 'user' }, own), null);
  // kurma: kendi + kok stogu (durumdan bagimsiz: claim kendi durum kontrolunu yapar), baska servis HAYIR
  assert.strictEqual(ts.mayInstall(SVC_A, own), true);
  assert.strictEqual(ts.mayInstall(SVC_A, rootStock), true);
  assert.strictEqual(ts.mayInstall(SVC_A, foreign), false);
  assert.strictEqual(ts.mayInstall(ROOT, foreign), true);
  assert.strictEqual(ts.mayInstall({ userId: 'u', globalRole: 'user' }, rootStock), false);
  // yonetme: yalniz kendi karti (kok stogu yonetilemez)
  assert.strictEqual(ts.mayManageCard(SVC_A, own), true);
  assert.strictEqual(ts.mayManageCard(SVC_A, rootStock), false);
  assert.strictEqual(ts.mayManageCard(SVC_A, foreign), false);
  assert.strictEqual(ts.mayManageCard(ROOT, rootStock), true);
});

test('siteScope: kok her site; servis yalniz kendi sitesi; sahipsiz site servise kapali', () => {
  assert.strictEqual(ts.siteScope(ROOT, { service_owner_id: B }), 'root');
  assert.strictEqual(ts.siteScope(SVC_A, { service_owner_id: A }), 'tenant');
  assert.strictEqual(ts.siteScope(SVC_A, { service_owner_id: B }), null);
  assert.strictEqual(ts.siteScope(SVC_A, { service_owner_id: null }), null);
  assert.strictEqual(ts.siteScope({ userId: 'u', globalRole: 'user' }, { service_owner_id: A }), null);
  assert.strictEqual(ts.siteScope(SVC_A, null), null);
});

test('homeScope / userInScope: sorgu yardimcilari (kok sorgu yapmaz; servis kendi evi/musterisi)', async () => {
  const calls = [];
  const q = async (text, params) => {
    calls.push({ text, params });
    if (/service_owner_id FROM homes/.test(text)) return { rows: params[0] === 'h-a' ? [{ service_owner_id: A }] : params[0] === 'h-root' ? [{ service_owner_id: null }] : [] };
    if (/FROM users u/.test(text)) return { rows: params[1] === 'cust-a' ? [{ x: 1 }] : [] };
    return { rows: [] };
  };
  assert.strictEqual(await ts.homeScope(q, ROOT, 'h-a'), 'root');
  assert.strictEqual(calls.length, 0, 'kok icin sorgu yok');
  assert.strictEqual(await ts.homeScope(q, SVC_A, 'h-a'), 'tenant');
  assert.strictEqual(await ts.homeScope(q, SVC_B, 'h-a'), null);
  assert.strictEqual(await ts.homeScope(q, SVC_A, 'h-root'), null, 'sahipsiz ev');
  assert.strictEqual(await ts.homeScope(q, SVC_A, 'h-yok'), null, 'olmayan ev');
  assert.strictEqual(await ts.homeScope({ query: q }, SVC_A, 'h-a'), 'tenant', '{ query } nesnesi de kabul');
  assert.strictEqual(await ts.userInScope(q, ROOT, 'herkes'), true);
  assert.strictEqual(await ts.userInScope(q, SVC_A, A), true, 'kendisi');
  assert.strictEqual(await ts.userInScope(q, SVC_A, 'cust-a'), true);
  assert.strictEqual(await ts.userInScope(q, SVC_A, 'cust-b'), false);
  assert.strictEqual(await ts.userInScope(q, { userId: 'u', globalRole: 'user' }, 'cust-a'), false);
  assert.match(ts.customerScopeSql('u', '$3'), /u\.role = 'user'.*u\.created_by_user_id = \$3[\s\S]*sc_h\.service_owner_id = \$3[\s\S]*OR u\.id = \$3/);
});
