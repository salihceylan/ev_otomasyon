'use strict';

// uyelik-1: personel akislarinda (claim / Home Admin atama / acil sifirlama yeni sahip) DOGRULANMAMIS onceden acilmis
// hesabin etkisizlestirilmesi (on-hesap ele gecirme savunmasi): auth_service.neutralizeUnverifiedAccount.
//  - yalniz email_verified=FALSE hesapta calisir (dogrulanmis hesaba DOKUNULMAZ)
//  - parola kullanilamaz ozete degisir, token_version++, must_change_password=FALSE, password_changed_at=NULL,
//    active -> pending_invite (diger durumlar aynen), TUM oturumlar + uygulama MQTT kimlikleri ayni tx'te iptal
//  - COMMIT sonrasi isler (onbellek, push belirteci, MQTT atma) finishNeutralize ile; asla firlatmaz

const test = require('node:test');
const assert = require('node:assert');
const crypto = require('crypto');
const bcrypt = require('bcryptjs');
const { setTestEnv, installFakeDb } = require('./_helpers');
const { createAuthStore } = require('./_auth_store');

setTestEnv({ BCRYPT_TEST_COST: '4' });
const fakeDb = installFakeDb();
const store = createAuthStore().install(fakeDb);

const authService = require('../../src/services/auth_service');

const kicked = [];
authService.setMqttCredentialService(Object.assign(Object.create(require('../../src/services/mqtt_credential_service')), {
  kickUsernames: async (names) => { kicked.push(...names); return { requested: names.length, kicked: names.length, failed: 0, skipped: false, errors: [] }; },
}));
const pushDisabled = [];
authService.setPushService({ disableAllTokensForUser: async (uid) => { pushDisabled.push(uid); return 1; } });

function seedUser(fields = {}) {
  const u = store.addUser({
    email: `onhesap-${crypto.randomBytes(4).toString('hex')}@example.com`,
    password_hash: bcrypt.hashSync('Saldirgan-Parola-1', 4),
    password_changed_at: new Date(),
    ...fields,
  });
  store.refresh.push({ id: crypto.randomUUID(), user_id: u.id, token_hash: `rt-${u.id}`, family_id: crypto.randomUUID(), expires_at: new Date(Date.now() + 1e9), used_at: null, revoked_at: null });
  const cred = store.addMqttCred(u.id, { home_id: crypto.randomUUID() });
  return { u, cred };
}

test('uyelik-1: neutralizeUnverifiedAccount - dogrulanmamis aktif hesap etkisizlesir (parola, tv, durum, oturumlar, MQTT)', async () => {
  assert.strictEqual(typeof authService.neutralizeUnverifiedAccount, 'function');
  const { u, cred } = seedUser({ email_verified: false, account_status: 'active', must_change_password: true });
  const oldHash = u.password_hash;
  const unusableHash = await authService._unusablePasswordHash();
  const r = await fakeDb.withTransaction((tx) =>
    authService.neutralizeUnverifiedAccount(u.id, { tx, reason: 'staff_claim_unverified', unusableHash })
  );
  assert.strictEqual(r.neutralized, true);
  const row = store.users.get(u.id);
  assert.notStrictEqual(row.password_hash, oldHash);
  assert.strictEqual(row.password_hash, unusableHash);
  assert.strictEqual(await bcrypt.compare('Saldirgan-Parola-1', row.password_hash), false, 'eski parola gecmez');
  assert.strictEqual(row.token_version, 2, 'token_version BIR kez artar');
  assert.strictEqual(row.account_status, 'pending_invite');
  assert.strictEqual(row.must_change_password, false);
  assert.strictEqual(row.password_changed_at, null);
  assert.ok(store.refresh.filter((x) => x.user_id === u.id).every((x) => x.revoked_at), 'refresh tokenlar iptal');
  assert.ok(!store.mqttCreds.includes(cred), 'uygulama MQTT kimligi silindi');
  assert.deepStrictEqual(r.mqttUsernames, [cred.username], 'atilacak adlar doner (tx icinde atma YOK)');
  assert.deepStrictEqual(kicked, []);

  // COMMIT sonrasi isler
  await authService.finishNeutralize(u.id, r, { reason: 'staff_claim_unverified' });
  assert.deepStrictEqual(kicked, [cred.username]);
  assert.ok(pushDisabled.includes(u.id));
});

test('uyelik-1: dogrulanmis hesaba DOKUNULMAZ; pending_invite dogrulanmamis hesap durumu korunur; tx zorunlu', async () => {
  const { u, cred } = seedUser({ email_verified: true, account_status: 'active' });
  const before = { ...store.users.get(u.id) };
  const unusableHash = await authService._unusablePasswordHash();
  const r = await fakeDb.withTransaction((tx) => authService.neutralizeUnverifiedAccount(u.id, { tx, reason: 'x', unusableHash }));
  assert.deepStrictEqual(r, { neutralized: false, mqttUsernames: [] });
  assert.deepStrictEqual(store.users.get(u.id), before);
  assert.ok(store.mqttCreds.includes(cred));
  assert.ok(store.refresh.filter((x) => x.user_id === u.id).every((x) => !x.revoked_at));

  const p = seedUser({ email_verified: false, account_status: 'pending_invite' });
  const r2 = await fakeDb.withTransaction((tx) => authService.neutralizeUnverifiedAccount(p.u.id, { tx, reason: 'x', unusableHash }));
  assert.strictEqual(r2.neutralized, true);
  assert.strictEqual(store.users.get(p.u.id).account_status, 'pending_invite');

  const s = seedUser({ email_verified: false, account_status: 'suspended', is_active: false });
  await fakeDb.withTransaction((tx) => authService.neutralizeUnverifiedAccount(s.u.id, { tx, reason: 'x', unusableHash }));
  assert.strictEqual(store.users.get(s.u.id).account_status, 'suspended', 'askidaki hesap askida kalir');

  await assert.rejects(authService.neutralizeUnverifiedAccount(u.id, { reason: 'x', unusableHash }), TypeError);
  await assert.rejects(fakeDb.withTransaction((tx) => authService.neutralizeUnverifiedAccount(u.id, { tx, reason: 'x' })), TypeError);
});

test('uyelik-1: finishNeutralize asla firlatmaz (etkisizlestirme olmadiysa hicbir sey yapmaz)', async () => {
  kicked.length = 0;
  await authService.finishNeutralize(crypto.randomUUID(), { neutralized: false, mqttUsernames: [] }, { reason: 'x' });
  await authService.finishNeutralize(null, null, {});
  assert.deepStrictEqual(kicked, []);
});

test('sahte DB: eslesmeyen SQL yok', () => {
  assert.deepStrictEqual(store.unmatched, []);
});
