'use strict';

// UYELIK-03 (karar D5): DELETE /api/v1/auth/account - SOLE_OWNER yalniz baska UYESI ya da CIHAZI olan dairelerde.
// Uyesiz VE cihazsiz tek-sahipli ("bos") daireler hesap silmeyle AYNI transaction'da, yonetici kalici silme
// sirasiyla temizlenir: MQTT ev kimlikleri (uygulama + cihaz) iptal, servis PIN/oturum iptali, ev temizligi
// (home_cleanup, keepEndpoints:false), DELETE FROM homes; acik baglantilar COMMIT SONRASI atilir.
// Yanita `released_homes: <sayi>` eklenir. Engelleyen daire varsa 409 SOLE_OWNER govdesi aynen (yalniz engelleyenler)
// ve HICBIR sey silinmez (bos daire dahil).

const test = require('node:test');
const assert = require('node:assert/strict');
const bcrypt = require('bcryptjs');
const { createEnv, uid } = require('./_world');

const env = createEnv();
const { h, state, api, tokenOf, world } = env;
const { AccountDeletionService } = env.SRC('services/account_deletion_service');
const realMqtt = env.SRC('services/mqtt_credential_service');

const URL = '/api/v1/auth/account';
const PASSWORD = 'Sifre-Test-12345';
let n = 0;

function pwUser(extra = {}) {
  const i = ++n;
  return h.user({
    email: `bosdaire${i}@example.test`, full_name: 'Boş Daire Sahibi',
    password_hash: bcrypt.hashSync(PASSWORD, 4), password_changed_at: new Date(), ...extra,
  });
}

function deviceCredential(home) {
  const row = { id: uid(), username: `d_${home.mqtt_username}`, kind: 'device', home_id: home.id, user_id: null, expires_at: null };
  state.mqtt_credentials.push(row);
  return row;
}

/** Kick kaydeden MQTT servisi: silme islemleri GERCEK servis (sahte dunya DB'si), kick sahte. */
function recordingMqtt() {
  const kicked = [];
  const svc = Object.assign(Object.create(realMqtt), {
    kickUsernames: async (list) => { kicked.push(...list); return { kicked: list.length, failed: 0, skipped: false }; },
  });
  return { svc, kicked };
}

function recordingCleanup() {
  const calls = [];
  return { calls, mod: { cleanupHome: async (tx, homeId, opts) => { calls.push({ homeId, opts, inTx: Boolean(tx) }); return { cleaned: {}, skipped: [] }; } } };
}

test('bos daire (uyesiz + cihazsiz) tek sahibi: 200, released_homes 1, homes satiri yok; ev MQTT kimlikleri iptal + COMMIT sonrasi kick; servis PIN/oturum iptal; ev temizligi', async () => {
  const user = pwUser();
  const empty = h.home({ name: 'Boş Evim', owner: user });
  const myCred = h.appCredential(empty, user);
  const devCred = deviceCredential(empty); // cihaz stoga donmus olsa da kalmis cihaz kimligi
  const { token: pin, session } = h.serviceSession(empty, { ownerId: user.id });
  const { svc, kicked } = recordingMqtt();
  const cleanup = recordingCleanup();
  const logStart = world.db.log.length;

  const r = await new AccountDeletionService({ mqtt: svc, homeCleanup: cleanup.mod }).deleteAccount({ userId: user.id, password: PASSWORD });
  const log = world.db.log.slice(logStart);
  const sessionRevoke = log.find((l) => l.sql.startsWith('UPDATE service_sessions SET revoked_at = NOW(), revoked_reason = $2 WHERE home_id = $1'));
  assert.ok(sessionRevoke && sessionRevoke.tx !== null, 'servis oturumlari ayni transaction\'da iptal (onbellek de duser)');
  assert.deepEqual(sessionRevoke.params, [empty.id, 'home_deleted']);
  const homeDelete = log.findIndex((l) => l.sql === 'DELETE FROM homes WHERE id = $1');
  assert.ok(homeDelete > log.indexOf(sessionRevoke), 'sira: servis iptali -> DELETE FROM homes');
  assert.equal(new Set(log.filter((l) => /^(INSERT|UPDATE|DELETE)/.test(l.sql)).map((l) => l.tx)).size, 1, 'tum yazmalar TEK transaction');
  assert.equal(r.deleted, true);
  assert.equal(r.released_homes, 1);
  assert.equal(r.released_memberships, 1);
  assert.equal(state.homes.some((x) => x.id === empty.id), false, 'homes satiri silindi');
  assert.equal(state.mqtt_credentials.some((c) => c.home_id === empty.id), false, 'evin TUM MQTT kimlikleri gitti');
  assert.deepEqual(kicked.sort(), [myCred.username, devCred.username].sort(), 'uygulama + cihaz baglantisi atildi');
  assert.ok(pin.revoked_at || !state.service_tokens.includes(pin), 'servis PIN iptal');
  assert.ok(session.revoked_at || !state.service_sessions.includes(session), 'servis oturumu iptal');
  assert.deepEqual(cleanup.calls, [{ homeId: empty.id, opts: { keepEndpoints: false }, inTx: true }]);
  assert.equal(user.account_status, 'deleted');
  const audit = state.device_audit_logs.find((a) => a.event === 'account_deleted' && a.actor_user_id === user.id);
  assert.equal(audit.details.released_homes, 1);
});

test('HTTP: bos daire tek sahibi silinir (200) ve yanit released_homes tasir; homes satiri yok', async () => {
  const user = pwUser();
  const empty = h.home({ name: 'HTTP Boş Ev', owner: user });
  const r = await api('delete', URL, tokenOf(user), { password: PASSWORD });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.data.released_homes, 1);
  assert.equal(state.homes.some((x) => x.id === empty.id), false);
});

test('released_homes her basarili yanitta bulunur (bos daire yoksa 0)', async () => {
  const user = pwUser();
  const r = await new AccountDeletionService({}).deleteAccount({ userId: user.id, password: PASSWORD });
  assert.equal(r.released_homes, 0);
});

test('1 cihazli tek-sahipli daire -> 409 SOLE_OWNER (govde alanlari aynen); hicbir sey silinmez', async () => {
  const user = pwUser();
  const home = h.home({ name: 'Cihazlı Ev', owner: user });
  h.device(home);
  const r = await api('delete', URL, tokenOf(user), { password: PASSWORD });
  assert.equal(r.status, 409, JSON.stringify(r.body));
  assert.equal(r.body.code, 'SOLE_OWNER');
  assert.ok(r.body.message.includes('devredin'));
  assert.deepEqual(r.body.homes, [{ id: home.id, name: 'Cihazlı Ev', other_member_count: 0, device_count: 1 }]);
  assert.ok(state.homes.some((x) => x.id === home.id));
  assert.equal(user.account_status, 'active');
});

test('1 uyeli tek-sahipli daire -> 409 SOLE_OWNER; hicbir sey silinmez', async () => {
  const user = pwUser();
  const home = h.home({ name: 'Üyeli Ev', owner: user });
  h.member(home, h.user(), 'resident');
  const r = await api('delete', URL, tokenOf(user), { password: PASSWORD });
  assert.equal(r.status, 409, JSON.stringify(r.body));
  assert.equal(r.body.code, 'SOLE_OWNER');
  assert.deepEqual(r.body.homes, [{ id: home.id, name: 'Üyeli Ev', other_member_count: 1, device_count: 0 }]);
  assert.ok(state.homes.some((x) => x.id === home.id));
});

test('karma: bos daire + engelleyen daire -> 409 yalniz ENGELLEYEN listelenir; bos daire de SILINMEZ (atomik)', async () => {
  const user = pwUser();
  const empty = h.home({ name: 'A Boş', owner: user });
  const busy = h.home({ name: 'B Dolu', owner: user });
  h.device(busy);
  const cred = h.appCredential(empty, user);
  const r = await api('delete', URL, tokenOf(user), { password: PASSWORD });
  assert.equal(r.status, 409);
  assert.deepEqual(r.body.homes.map((x) => x.id), [busy.id]);
  assert.ok(state.homes.some((x) => x.id === empty.id), 'bos daire korunur');
  assert.ok(state.mqtt_credentials.includes(cred));
  assert.equal(user.account_status, 'active');
});

test('ortak sahipli daire bos olsa da SILINMEZ (diger sahip kalir)', async () => {
  const user = pwUser();
  const co = h.home({ name: 'Ortak Boş', owner: user });
  const coOwner = h.user();
  h.member(co, coOwner, 'owner');
  const r = await new AccountDeletionService({}).deleteAccount({ userId: user.id, password: PASSWORD });
  assert.equal(r.released_homes, 0);
  assert.ok(state.homes.some((x) => x.id === co.id));
  assert.ok(state.home_users.some((m) => m.home_id === co.id && m.user_id === coOwner.id));
});

test('ATOMIK: bos daire silindikten sonra hata olursa daire ve hesap geri gelir', async () => {
  const user = pwUser();
  const empty = h.home({ name: 'Geri Alınan Boş Ev', owner: user });
  const hook = { matcher: (sql) => sql.startsWith('DELETE FROM refresh_tokens'), fn: () => { throw new Error('beklenen test hatası'); } };
  world.db.handlers.unshift(hook);
  try {
    await assert.rejects(new AccountDeletionService({}).deleteAccount({ userId: user.id, password: PASSWORD }), /beklenen test hatası/);
  } finally {
    world.db.handlers.splice(world.db.handlers.indexOf(hook), 1);
  }
  assert.ok(state.homes.some((x) => x.id === empty.id), 'homes satiri geri alindi');
  assert.ok(state.home_users.some((m) => m.home_id === empty.id && m.user_id === user.id));
  assert.equal(user.account_status, 'active');
});
