'use strict';

// A10: daire devri.

const test = require('node:test');
const assert = require('node:assert');
const crypto = require('crypto');
const express = require('express');
const request = require('supertest');
const { setTestEnv, installFakeDb, makeAccessToken, makeServiceToken } = require('./_helpers');
const { createHomeStore } = require('./_home_store');

setTestEnv();
const fakeDb = installFakeDb();
const store = createHomeStore().install(fakeDb);

const auth = require('../../src/middlewares/auth_middleware');
const transferRoutes = require('../../src/routes/transfer_routes');
const TransferService = require('../../src/services/transfer_service');
const { errorHandler } = require('../../src/middlewares/error_handler');

auth.configureAuthMiddleware({ cacheTtlMs: 0 });

const calls = [];
TransferService.setDependencies({
  mqtt_credential_service: {
    revokeHomeAccess: async (args) => { calls.push(['revokeHomeAccess', args.homeId, Boolean(args.tx), Boolean(args.includeDevice)]); return { revoked: 2, usernames: ['a_old1', 'a_old2'] }; },
    kickUsernames: async (names) => { calls.push(['kick', names]); return { kicked: names.length, failed: 0, skipped: false }; },
  },
  home_cleanup: {
    cleanupHome: async (tx, homeId, opts) => { calls.push(['cleanupHome', homeId, Boolean(tx && tx.query), opts]); return { cleaned: {}, skipped: [] }; },
  },
});

const app = express();
app.use(express.json());
app.use('/api/v1', transferRoutes);
app.use(errorHandler);

const T = (u) => `Bearer ${makeAccessToken(u)}`;

function setupHome() {
  const home = store.addHome({ name: `Devir Evi ${store.homes.size}` });
  const owner = store.addUser({ email: `sahip${store.users.size}@example.com` });
  const resident = store.addUser();
  const guest = store.addUser();
  const staff = store.addUser({ role: 'service_user' });
  store.addMember(home, owner, 'owner');
  store.addMember(home, resident, 'resident');
  store.addMember(home, guest, 'guest', { valid_from: new Date(Date.now() - 1000), valid_until: new Date(Date.now() + 3600e3) });
  store.addMember(home, staff, 'service_user');
  const sid = crypto.randomUUID();
  store.sessions.push({ id: sid, home_id: home.id, technician_name: 'T', expires_at: new Date(Date.now() + 3600e3), revoked_at: null });
  return { home, owner, resident, guest, staff, sid };
}

const initiate = (who, homeId, body) => request(app).post(`/api/v1/homes/${homeId}/transfer-initiate`).set('Authorization', who).send(body);
const accept = (who, code) => request(app).post('/api/v1/homes/transfer-accept').set('Authorization', who).send({ transfer_code: code });

test.beforeEach(() => {
  calls.length = 0;
});

test('baslatma: hedef ZORUNLU; gecersiz hedef 400; kendine devir 400', async () => {
  const { home, owner } = setupHome();
  assert.strictEqual((await initiate(T(owner), home.id, {})).status, 400);
  assert.strictEqual((await initiate(T(owner), home.id, { target_identifier: 'gecersiz' })).status, 400);
  assert.strictEqual((await initiate(T(owner), home.id, { target_identifier: owner.email.toUpperCase() })).status, 400);
});

test('baslatma: owner -> 201, kod AHBU-TR-+16, hedef normalize, DB de yalnizca ozet; onceki bekleyen iptal', async () => {
  const { home, owner } = setupHome();
  const r1 = await initiate(T(owner), home.id, { target_identifier: ' Yeni.Sahip@Example.COM ' });
  assert.strictEqual(r1.status, 201, JSON.stringify(r1.body));
  const d = r1.body.data;
  assert.match(d.transfer_code, /^AHBU-TR-[A-Z0-9]{16}$/);
  assert.strictEqual(d.qr_payload, `AHBU-TRANSFER:${d.transfer_code}`);
  assert.strictEqual(d.target_identifier, 'yeni.sahip@example.com');
  const row = store.transfers.find((t) => t.home_id === home.id && t.status === 'PENDING');
  assert.strictEqual(row.transfer_code, null);
  assert.strictEqual(row.code_hash, crypto.createHash('sha256').update(d.transfer_code).digest('hex'));
  const r2 = await initiate(T(owner), home.id, { targetIdentifier: 'baska@example.com' });
  assert.strictEqual(r2.status, 201);
  assert.strictEqual(store.transfers.filter((t) => t.home_id === home.id && t.status === 'PENDING').length, 1);
});

test('baslatma/durum/iptal: resident/misafir/staff/super/servis oturumu/yabanci 403 (devir yalnizca owner)', async () => {
  const { home, resident, guest, staff, sid } = setupHome();
  const superUser = store.addUser({ role: 'super_user' });
  const stranger = store.addUser();
  const svc = `Bearer ${makeServiceToken({ sid, home_id: home.id })}`;
  for (const who of [T(resident), T(guest), T(staff), T(superUser), svc, T(stranger)]) {
    assert.strictEqual((await initiate(who, home.id, { target_identifier: 'x@example.com' })).status, 403);
    assert.strictEqual((await request(app).get(`/api/v1/homes/${home.id}/transfer-status`).set('Authorization', who)).status, 403);
    assert.strictEqual((await request(app).post(`/api/v1/homes/${home.id}/transfer-cancel`).set('Authorization', who)).status, 403);
  }
});

test('kabul: hedef kullanici devralir; eski aile cikar; servis/MQTT/temizlik yalnizca bu ev; refresh oturumlarina DOKUNULMAZ', async () => {
  const { home, owner, resident, sid } = setupHome();
  const target = store.addUser({ email: 'devralan@example.com' });
  const code = (await initiate(T(owner), home.id, { target_identifier: 'devralan@example.com' })).body.data.transfer_code;
  const before = fakeDb.calls.length;

  const res = await accept(T(target), code.toLowerCase());
  assert.strictEqual(res.status, 200, JSON.stringify(res.body));
  assert.strictEqual(res.body.data.home.id, home.id);
  assert.strictEqual(res.body.data.home.role, 'owner');

  const members = store.members.filter((m) => m.home_id === home.id);
  assert.deepStrictEqual(members.map((m) => [m.user_id, m.role]), [[target.id, 'owner']]);
  assert.strictEqual(store.member(home.id, owner.id), undefined);
  assert.strictEqual(store.member(home.id, resident.id), undefined);
  assert.ok(store.sessions.find((x) => x.id === sid).revoked_at, 'servis oturumu iptal');
  assert.deepStrictEqual(calls[0], ['revokeHomeAccess', home.id, true, false]);
  assert.strictEqual(calls[1][0], 'cleanupHome');
  assert.strictEqual(calls[1][1], home.id);
  assert.strictEqual(calls[1][2], true);
  assert.deepStrictEqual(calls[1][3], { keepEndpoints: true, cancelPendingTransfers: false });
  assert.deepStrictEqual(calls[2], ['kick', ['a_old1', 'a_old2']]);
  assert.ok(store.deviceUpdates.some((u) => u[0] === 'inventory' && u[1] === target.id && u[2] === home.id));

  const sqls = fakeDb.calls.slice(before).map((c) => c.text).join('\n');
  assert.ok(!/refresh_tokens/.test(sqls), 'baska evlerdeki oturumlar dusmemeli');
  assert.ok(!/token_version\s*=\s*token_version\s*\+\s*1/.test(sqls), 'token_version artirilmamali');
});

test('kabul: hedefle eslesmeyen kullanici 403 ve hedef kimlik SIZDIRILMAZ; devir beklemede kalir', async () => {
  const { home, owner } = setupHome();
  const code = (await initiate(T(owner), home.id, { target_identifier: 'gizli.hedef@example.com' })).body.data.transfer_code;
  const intruder = store.addUser({ email: 'saldirgan@example.com' });
  const res = await accept(T(intruder), code);
  assert.strictEqual(res.status, 403);
  assert.ok(!JSON.stringify(res.body).includes('gizli.hedef'));
  assert.strictEqual(store.transfers.find((t) => t.home_id === home.id).status, 'PENDING');
  assert.ok(store.member(home.id, owner.id));
});

test('kabul: telefon hedefi normalize edilerek eslesir', async () => {
  const { home, owner } = setupHome();
  const target = store.addUser({ phone: '+905559876543' });
  const code = (await initiate(T(owner), home.id, { target_identifier: '+90 555 987 65 43' })).body.data.transfer_code;
  assert.strictEqual((await accept(T(target), code)).status, 200);
});

test('kabul: ikinci kullanim / suresi dolmus / iptal edilmis / baslatan artik sahip degil -> 410', async () => {
  const s1 = setupHome();
  const t1 = store.addUser({ email: 't1@example.com' });
  const c1 = (await initiate(T(s1.owner), s1.home.id, { target_identifier: 't1@example.com' })).body.data.transfer_code;
  assert.strictEqual((await accept(T(t1), c1)).status, 200);
  assert.strictEqual((await accept(T(t1), c1)).status, 410);

  const s2 = setupHome();
  const t2 = store.addUser({ email: 't2@example.com' });
  const c2 = (await initiate(T(s2.owner), s2.home.id, { target_identifier: 't2@example.com' })).body.data.transfer_code;
  store.transfers.find((t) => t.home_id === s2.home.id && t.status === 'PENDING').expires_at = new Date(Date.now() - 1000);
  assert.strictEqual((await accept(T(t2), c2)).status, 410);

  const s3 = setupHome();
  const t3 = store.addUser({ email: 't3@example.com' });
  const c3 = (await initiate(T(s3.owner), s3.home.id, { target_identifier: 't3@example.com' })).body.data.transfer_code;
  assert.strictEqual((await request(app).post(`/api/v1/homes/${s3.home.id}/transfer-cancel`).set('Authorization', T(s3.owner))).status, 200);
  assert.strictEqual((await accept(T(t3), c3)).status, 410);

  const s4 = setupHome();
  const t4 = store.addUser({ email: 't4@example.com' });
  const c4 = (await initiate(T(s4.owner), s4.home.id, { target_identifier: 't4@example.com' })).body.data.transfer_code;
  store.members = store.members.filter((m) => !(m.home_id === s4.home.id && m.user_id === s4.owner.id));
  assert.strictEqual((await accept(T(t4), c4)).status, 410);
});

test('kabul: eszamanli iki kabulden yalnizca biri basarili', async () => {
  const { home, owner } = setupHome();
  const target = store.addUser({ email: 'yaris@example.com' });
  const code = (await initiate(T(owner), home.id, { target_identifier: 'yaris@example.com' })).body.data.transfer_code;
  const [a, b] = await Promise.all([accept(T(target), code), accept(T(target), code)]);
  assert.deepStrictEqual([a.status, b.status].sort(), [200, 410]);
  assert.strictEqual(store.members.filter((m) => m.home_id === home.id).length, 1);
});

test('kabul: bozuk kod 400, bilinmeyen kod 410, servis oturumu 403, tokensiz 401', async () => {
  const { home, sid } = setupHome();
  const u = store.addUser();
  assert.strictEqual((await accept(T(u), 'AHBU-TR-123')).status, 400);
  assert.strictEqual((await accept(T(u), 'AHBU-TR-ZZZZZZZZZZZZZZZZ')).status, 410);
  assert.strictEqual((await accept(`Bearer ${makeServiceToken({ sid, home_id: home.id })}`, 'AHBU-TR-ZZZZZZZZZZZZZZZZ')).status, 403);
  assert.strictEqual((await request(app).post('/api/v1/homes/transfer-accept').send({ transfer_code: 'x' })).status, 401);
});

test('durum: kod DONMEZ (yalnizca ozet saklanir)', async () => {
  const { home, owner } = setupHome();
  const code = (await initiate(T(owner), home.id, { target_identifier: 'durum@example.com' })).body.data.transfer_code;
  const st = await request(app).get(`/api/v1/homes/${home.id}/transfer-status`).set('Authorization', T(owner));
  assert.strictEqual(st.status, 200);
  assert.strictEqual(st.body.data.pending_transfer.target_identifier, 'durum@example.com');
  assert.ok(!JSON.stringify(st.body).includes(code));
});

test('baslatma: kullanici basina saatte 10 -> 429', async () => {
  const { home, owner } = setupHome();
  for (let i = 0; i < 10; i++) {
    assert.strictEqual((await initiate(T(owner), home.id, { target_identifier: `r${i}@example.com` })).status, 201);
  }
  assert.strictEqual((await initiate(T(owner), home.id, { target_identifier: 'r@example.com' })).status, 429);
});

test('sahte DB: eslesmeyen SQL yok', () => {
  assert.deepStrictEqual(store.unmatched, []);
});
