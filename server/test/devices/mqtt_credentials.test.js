'use strict';

// B7 / B11: mqtt_credential_service - salt-okunur uygulama kimligi, cihaz kimligi, iptal, kick, temizlik

const test = require('node:test');
const assert = require('node:assert');
const bcrypt = require('bcryptjs');
const fs = require('fs');

const { createWorld, createServices, setTestEnv, expectHttp, createFakeFetch, silentLogger } = require('./_world');
const { MqttCredentialService } = require('../../src/services/mqtt_credential_service');

function setup() {
  setTestEnv();
  const world = createWorld();
  const svc = createServices(world);
  const h = world.helpers;
  const owner = h.addUser({ email: 'sahip@example.test' });
  const resident = h.addUser({ email: 'sakin@example.test' });
  const home = h.addHome({ name: 'Ev', owner });
  const otherHome = h.addHome({ name: 'Baska Ev' });
  const dev = h.addDevice({ home, uuid: 'AHBU-S3-0001', mac: 'E8:F6:0A:00:00:01' });
  return { world, ...svc, owner, resident, home, otherHome, dev };
}

function enableEmqx() {
  process.env.EMQX_API_URL = 'http://emqx.test.invalid:18083/';
  process.env.EMQX_API_KEY = 'anahtar-x';
  process.env.EMQX_API_SECRET = 'gizli-y';
}

// ------------------------------------------------------------------------------------------------
test('uygulama kimligi: a_{t}_{rastgele}, SALT-OKUNUR ACL (yalniz state/status aboneligi, hic publish yok)', async () => {
  const ctx = setup();
  const c = await ctx.credentials.issueUserCredential({ homeId: ctx.home.id, userId: ctx.owner.id });
  const t = ctx.home.mqtt_username;

  assert.match(c.username, new RegExp(`^a_${t}_[0-9a-f]{10}$`));
  assert.strictEqual(c.client_id, c.username);
  assert.strictEqual(c.topic_id, t);
  assert.strictEqual(c.host, 'broker.test.invalid');
  assert.strictEqual(c.port, 8884);
  assert.strictEqual(c.password.length, 24);
  assert.match(c.password, /^[A-Za-z0-9]{24}$/);

  const acl = ctx.world.state.mqtt_acl.filter((a) => a.username === c.username);
  assert.deepStrictEqual(
    acl.map((a) => `${a.permission}:${a.action}:${a.topic}`).sort(),
    [`allow:subscribe:ev/${t}/state`, `allow:subscribe:ev/${t}/status`].sort()
  );
  assert.ok(acl.every((a) => a.action === 'subscribe'), 'uygulama kimligine publish verilmemeli');
  assert.ok(!ctx.world.state.mqtt_acl.some((a) => a.topic.endsWith('/cmd') || a.topic.endsWith('/sys')));

  // DB'de yalnizca bcrypt ozeti; parola yok
  const row = ctx.world.state.mqtt_credentials[0];
  assert.strictEqual(row.kind, 'app');
  assert.strictEqual(row.user_id, ctx.owner.id);
  assert.strictEqual(row.home_id, ctx.home.id);
  assert.match(row.password_hash, /^\$2[aby]\$10\$/);
  assert.ok(bcrypt.compareSync(c.password, row.password_hash));
  assert.ok(!JSON.stringify(ctx.world.state).includes(c.password));
  assert.strictEqual(row.is_superuser, false);
});

test('sure: varsayilan 12 saat; misafir bitisi daha erkense o; gecmis bitis 403 GUEST_EXPIRED', async () => {
  const ctx = setup();
  const now = ctx.world.clock.t;

  const normal = await ctx.credentials.issueUserCredential({ homeId: ctx.home.id, userId: ctx.owner.id });
  assert.strictEqual(new Date(normal.expires_at).getTime() - now, 12 * 3600 * 1000);

  const guestEnd = new Date(now + 90 * 60 * 1000);
  const guest = await ctx.credentials.issueUserCredential({ homeId: ctx.home.id, userId: ctx.resident.id, validUntil: guestEnd });
  assert.strictEqual(new Date(guest.expires_at).getTime(), guestEnd.getTime(), 'min(12 saat, misafir bitisi)');

  const farEnd = new Date(now + 48 * 3600 * 1000);
  const far = await ctx.credentials.issueUserCredential({ homeId: ctx.home.id, userId: ctx.resident.id, validUntil: farEnd.toISOString() });
  assert.strictEqual(new Date(far.expires_at).getTime() - now, 12 * 3600 * 1000);

  await expectHttp(
    ctx.credentials.issueUserCredential({ homeId: ctx.home.id, userId: ctx.resident.id, validUntil: new Date(now - 1000) }),
    403, 'GUEST_EXPIRED'
  );
  await expectHttp(
    ctx.credentials.issueUserCredential({ homeId: ctx.home.id, userId: ctx.resident.id, validUntil: new Date(now) }),
    403, 'GUEST_EXPIRED'
  );
  await assert.rejects(ctx.credentials.issueUserCredential({ homeId: ctx.home.id, userId: ctx.resident.id, validUntil: 'bozuk-tarih' }), TypeError);
});

test('her cagri yeni kimlik uretir (oturum basina): kullanici adi ve parola tekrarlanmaz', async () => {
  const ctx = setup();
  const names = new Set();
  const passwords = new Set();
  for (let i = 0; i < 8; i++) {
    ctx.world.clock.advance(1000);
    const c = await ctx.credentials.issueUserCredential({ homeId: ctx.home.id, userId: ctx.owner.id });
    names.add(c.username);
    passwords.add(c.password);
  }
  assert.strictEqual(names.size, 8);
  assert.strictEqual(passwords.size, 8);
});

test('etkin uygulama kimligi siniri (10): fazlasi silinir ve baglantisi atilir; baska kullanici/ev etkilenmez', async () => {
  const ctx = setup();
  enableEmqx();
  const first = await ctx.credentials.issueUserCredential({ homeId: ctx.home.id, userId: ctx.owner.id });
  await ctx.credentials.issueUserCredential({ homeId: ctx.home.id, userId: ctx.resident.id });
  for (let i = 0; i < 10; i++) {
    ctx.world.clock.advance(1000);
    await ctx.credentials.issueUserCredential({ homeId: ctx.home.id, userId: ctx.owner.id });
  }
  const mine = ctx.world.state.mqtt_credentials.filter((c) => c.user_id === ctx.owner.id);
  assert.strictEqual(mine.length, 10, 'en fazla 10 etkin kimlik');
  assert.ok(!mine.some((c) => c.username === first.username), 'en eski kimlik silinmeli');
  assert.ok(ctx.timeline.includes(`kick:${first.username}`), 'silinen kimligin baglantisi atilmali');
  assert.strictEqual(ctx.world.state.mqtt_credentials.filter((c) => c.user_id === ctx.resident.id).length, 1);
  // silinen kimligin ACL satirlari da gider
  assert.ok(!ctx.world.state.mqtt_acl.some((a) => a.username === first.username));
});

test('servis (PIN) oturumu kimligi: userId bos olabilir', async () => {
  const ctx = setup();
  const c = await ctx.credentials.issueUserCredential({ homeId: ctx.home.id, userId: null, validUntil: new Date(ctx.world.clock.t + 3600000) });
  assert.strictEqual(ctx.world.state.mqtt_credentials[0].user_id, null);
  assert.strictEqual(new Date(c.expires_at).getTime() - ctx.world.clock.t, 3600000);
});

test('bilinmeyen ev 404; MQTT_PUBLIC_HOST/PORT yoksa genel 500 (yapilandirma ayrintisi sizmaz)', async () => {
  const ctx = setup();
  await expectHttp(ctx.credentials.issueUserCredential({ homeId: '00000000-0000-4000-8000-000000000000', userId: ctx.owner.id }), 404, 'NOT_FOUND');

  delete process.env.MQTT_PUBLIC_HOST;
  const e = await expectHttp(ctx.credentials.issueUserCredential({ homeId: ctx.home.id, userId: ctx.owner.id }), 500, 'INTERNAL');
  assert.ok(!/MQTT_PUBLIC/.test(e.message));
  process.env.MQTT_PUBLIC_HOST = 'broker.test.invalid';
  process.env.MQTT_PUBLIC_PORT = 'abc';
  await expectHttp(ctx.credentials.issueUserCredential({ homeId: ctx.home.id, userId: ctx.owner.id }), 500, 'INTERNAL');
  process.env.MQTT_PUBLIC_PORT = '70000';
  await expectHttp(ctx.credentials.issueUserCredential({ homeId: ctx.home.id, userId: ctx.owner.id }), 500, 'INTERNAL');
});

test('konu kimligi joker/ayirici karakter iceriyorsa ACL URETILMEZ (joker konu enjeksiyonu engeli)', async () => {
  const ctx = setup();
  for (const bad of ['h_+', 'h_#', 'a/b', 'ev/#', 'x y', '', 'h_' + 'a'.repeat(70)]) {
    const home = ctx.world.helpers.addHome({ name: 'Bozuk', topic: bad || 'bos' });
    home.mqtt_username = bad;
    await expectHttp(ctx.credentials.issueUserCredential({ homeId: home.id, userId: ctx.owner.id }), 500, 'INTERNAL');
    await expectHttp(ctx.credentials.issueDeviceCredential({ homeId: home.id }), 500, 'INTERNAL');
  }
  assert.strictEqual(ctx.world.state.mqtt_acl.length, 0);
  assert.strictEqual(ctx.credentials.isValidTopicId('h_0123456789abcdef'), true);
  assert.strictEqual(ctx.credentials.isValidTopicId('home_101'), true);
});

test('yeni ev konu kimligi: h_ + 16 hex, benzersiz ve tahmin edilemez', () => {
  const ctx = setup();
  const ids = new Set();
  for (let i = 0; i < 500; i++) {
    const id = ctx.credentials.generateTopicId();
    assert.match(id, /^h_[0-9a-f]{16}$/);
    ids.add(id);
  }
  assert.strictEqual(ids.size, 500);
});

// ------------------------------------------------------------------------------------------------
test('cihaz kimligi: d_{t}, ACL pub state/status + sub cmd/sys; yeniden uretim eskisini DEGISTIRIR (rotasyon)', async () => {
  const ctx = setup();
  enableEmqx();
  const t = ctx.home.mqtt_username;
  const a = await ctx.credentials.issueDeviceCredential({ homeId: ctx.home.id, deviceId: ctx.dev.id });
  assert.strictEqual(a.username, `d_${t}`);
  assert.strictEqual(a.client_id, `d_${t}`);
  assert.deepStrictEqual(a.previous_usernames, []);
  const acl = ctx.world.state.mqtt_acl.filter((x) => x.username === a.username).map((x) => `${x.action}:${x.topic}`).sort();
  assert.deepStrictEqual(acl, [
    `publish:ev/${t}/state`, `publish:ev/${t}/status`, `subscribe:ev/${t}/cmd`, `subscribe:ev/${t}/sys`,
    `publish:ev/${t}/event`, // WP-S1: guvenlik olaylari (migration 033 mevcut kimliklere ayni satiri ekler)
  ].sort());
  const row1 = ctx.world.state.mqtt_credentials[0];
  assert.match(row1.password_hash, /^\$2[aby]\$10\$/);
  assert.strictEqual(row1.expires_at, null, 'cihaz kimliginin suresi yok');
  assert.strictEqual(row1.device_id, ctx.dev.id);
  const firstHash = row1.password_hash;

  const b = await ctx.credentials.issueDeviceCredential({ homeId: ctx.home.id, deviceId: ctx.dev.id });
  assert.strictEqual(ctx.world.state.mqtt_credentials.filter((c) => c.kind === 'device').length, 1, 'evin tek cihaz kimligi olur');
  assert.notStrictEqual(b.password, a.password);
  assert.notStrictEqual(ctx.world.state.mqtt_credentials[0].password_hash, firstHash);
  assert.ok(!bcrypt.compareSync(a.password, ctx.world.state.mqtt_credentials[0].password_hash), 'eski parola gecersiz');
  assert.ok(bcrypt.compareSync(b.password, ctx.world.state.mqtt_credentials[0].password_hash));
  assert.deepStrictEqual(b.previous_usernames, [`d_${t}`]);
  assert.ok(ctx.timeline.includes(`kick:d_${t}`), 'eski cihaz baglantisi atilmali');
  assert.strictEqual(ctx.world.state.mqtt_acl.filter((x) => x.username === a.username).length, 5, 'ACL yinelenmemeli');
});

test('tx verilirse DB islemleri cagiranin transaction\'inda yapilir ve KICK YAPILMAZ (commit sonrasi cagiranin isi)', async () => {
  const ctx = setup();
  enableEmqx();
  await ctx.credentials.issueDeviceCredential({ homeId: ctx.home.id, deviceId: ctx.dev.id });
  ctx.timeline.length = 0;
  ctx.world.db.log.length = 0;
  const r = await ctx.world.db.withTransaction((tx) =>
    ctx.credentials.issueDeviceCredential({ homeId: ctx.home.id, deviceId: ctx.dev.id, tx })
  );
  assert.deepStrictEqual(r.previous_usernames, [`d_${ctx.home.mqtt_username}`]);
  assert.deepStrictEqual(ctx.timeline, [], 'tx modunda ag cagrisi yapilmamali');
  assert.strictEqual(ctx.world.db.commits >= 1, true);
  assert.deepStrictEqual(ctx.world.db.nonTxQueries(), []);
});

test('transaction geri alinirsa kimlikler de geri alinir', async () => {
  const ctx = setup();
  const before = await ctx.credentials.issueDeviceCredential({ homeId: ctx.home.id, deviceId: ctx.dev.id });
  const hashBefore = ctx.world.state.mqtt_credentials[0].password_hash;
  await assert.rejects(
    ctx.world.db.withTransaction(async (tx) => {
      await ctx.credentials.issueDeviceCredential({ homeId: ctx.home.id, deviceId: ctx.dev.id, tx });
      throw new Error('sonradan hata');
    }),
    /sonradan hata/
  );
  assert.strictEqual(ctx.world.state.mqtt_credentials.length, 1);
  assert.strictEqual(ctx.world.state.mqtt_credentials[0].password_hash, hashBefore);
  assert.strictEqual(ctx.world.state.mqtt_acl.length, 5);
  assert.ok(bcrypt.compareSync(before.password, ctx.world.state.mqtt_credentials[0].password_hash));
});

// ------------------------------------------------------------------------------------------------
test('revokeUserAccess: yalniz O kullanicinin BU evdeki kimlikleri silinir ve baglantilari atilir', async () => {
  const ctx = setup();
  enableEmqx();
  const own1 = await ctx.credentials.issueUserCredential({ homeId: ctx.home.id, userId: ctx.owner.id });
  ctx.world.clock.advance(1000);
  const own2 = await ctx.credentials.issueUserCredential({ homeId: ctx.home.id, userId: ctx.owner.id });
  const res1 = await ctx.credentials.issueUserCredential({ homeId: ctx.home.id, userId: ctx.resident.id });
  const ownElsewhere = await ctx.credentials.issueUserCredential({ homeId: ctx.otherHome.id, userId: ctx.owner.id });
  const dev = await ctx.credentials.issueDeviceCredential({ homeId: ctx.home.id, deviceId: ctx.dev.id });
  ctx.timeline.length = 0;

  const r = await ctx.credentials.revokeUserAccess({ homeId: ctx.home.id, userId: ctx.owner.id });
  assert.strictEqual(r.revoked, 2);
  assert.deepStrictEqual([...r.usernames].sort(), [own1.username, own2.username].sort());
  assert.strictEqual(r.kick.kicked, 2);

  const left = ctx.world.state.mqtt_credentials.map((c) => c.username);
  assert.ok(left.includes(res1.username), 'baska kullanici etkilenmemeli');
  assert.ok(left.includes(ownElsewhere.username), 'kullanicinin BASKA evdeki kimligi korunmali');
  assert.ok(left.includes(dev.username), 'cihaz kimligi etkilenmemeli');
  assert.ok(!left.includes(own1.username) && !left.includes(own2.username));
  assert.ok(!ctx.world.state.mqtt_acl.some((a) => a.username === own1.username), 'ACL satirlari da silinmeli');
  assert.deepStrictEqual(ctx.timeline.sort(), [`kick:${own1.username}`, `kick:${own2.username}`].sort());

  // idempotent
  const again = await ctx.credentials.revokeUserAccess({ homeId: ctx.home.id, userId: ctx.owner.id });
  assert.strictEqual(again.revoked, 0);
  await assert.rejects(ctx.credentials.revokeUserAccess({ homeId: ctx.home.id }), TypeError);
  await assert.rejects(ctx.credentials.revokeUserAccess({ userId: ctx.owner.id }), TypeError);
});

test('revokeHomeAccess: evin TUM uygulama kimlikleri silinir; cihaz kimligi varsayilan olarak KALIR; includeDevice ile gider', async () => {
  const ctx = setup();
  enableEmqx();
  const a = await ctx.credentials.issueUserCredential({ homeId: ctx.home.id, userId: ctx.owner.id });
  const b = await ctx.credentials.issueUserCredential({ homeId: ctx.home.id, userId: ctx.resident.id });
  const other = await ctx.credentials.issueUserCredential({ homeId: ctx.otherHome.id, userId: ctx.owner.id });
  const d = await ctx.credentials.issueDeviceCredential({ homeId: ctx.home.id, deviceId: ctx.dev.id });
  ctx.timeline.length = 0;

  const r = await ctx.credentials.revokeHomeAccess({ homeId: ctx.home.id });
  assert.strictEqual(r.revoked, 2);
  assert.deepStrictEqual([...r.usernames].sort(), [a.username, b.username].sort());
  assert.deepStrictEqual(
    ctx.world.state.mqtt_credentials.map((c) => c.username).sort(),
    [d.username, other.username].sort()
  );

  const r2 = await ctx.credentials.revokeHomeAccess({ homeId: ctx.home.id, includeDevice: true });
  assert.deepStrictEqual(r2.usernames, [d.username]);
  assert.deepStrictEqual(ctx.world.state.mqtt_credentials.map((c) => c.username), [other.username], 'baska evin kimligi korunur');
  await assert.rejects(ctx.credentials.revokeHomeAccess({}), TypeError);
});

test('uyelik-6: revokeServiceSessionAccess yalniz evin servis (PIN) oturumu kimliklerini (user_id bos) siler; tx yoksa atar, tx varsa atmaz', async () => {
  const ctx = setup();
  enableEmqx();
  const svcA = await ctx.credentials.issueUserCredential({ homeId: ctx.home.id, userId: null });
  const svcB = await ctx.credentials.issueUserCredential({ homeId: ctx.home.id, userId: null });
  const own = await ctx.credentials.issueUserCredential({ homeId: ctx.home.id, userId: ctx.owner.id });
  const otherSvc = await ctx.credentials.issueUserCredential({ homeId: ctx.otherHome.id, userId: null });
  const d = await ctx.credentials.issueDeviceCredential({ homeId: ctx.home.id, deviceId: ctx.dev.id });
  ctx.timeline.length = 0;

  assert.strictEqual(typeof ctx.credentials.revokeServiceSessionAccess, 'function');
  const r = await ctx.credentials.revokeServiceSessionAccess({ homeId: ctx.home.id });
  assert.strictEqual(r.revoked, 2);
  assert.deepStrictEqual([...r.usernames].sort(), [svcA.username, svcB.username].sort());
  assert.deepStrictEqual(
    ctx.world.state.mqtt_credentials.map((c) => c.username).sort(),
    [own.username, otherSvc.username, d.username].sort(),
    'kullanici, cihaz ve baska evin kimligi korunur'
  );
  assert.deepStrictEqual(ctx.timeline.filter((x) => x.startsWith('kick:')).sort(), [`kick:${svcA.username}`, `kick:${svcB.username}`].sort());

  const svcC = await ctx.credentials.issueUserCredential({ homeId: ctx.home.id, userId: null });
  ctx.timeline.length = 0;
  const r2 = await ctx.world.db.withTransaction((tx) => ctx.credentials.revokeServiceSessionAccess({ homeId: ctx.home.id, tx }));
  assert.deepStrictEqual(r2.usernames, [svcC.username]);
  assert.ok(!('kick' in r2));
  assert.deepStrictEqual(ctx.timeline, [], 'tx modunda atma cagiranin isi');
  await assert.rejects(ctx.credentials.revokeServiceSessionAccess({}), TypeError);
});

test('revokeDeviceCredential: yalniz cihaz kimligi', async () => {
  const ctx = setup();
  await ctx.credentials.issueUserCredential({ homeId: ctx.home.id, userId: ctx.owner.id });
  await ctx.credentials.issueDeviceCredential({ homeId: ctx.home.id, deviceId: ctx.dev.id });
  const r = await ctx.credentials.revokeDeviceCredential({ homeId: ctx.home.id, deviceId: ctx.dev.id });
  assert.strictEqual(r.revoked, 1);
  assert.deepStrictEqual(ctx.world.state.mqtt_credentials.map((c) => c.kind), ['app']);
});

test('tx ile iptal: DB satirlari silinir ama KICK yapilmaz; usernames donus degerindedir', async () => {
  const ctx = setup();
  enableEmqx();
  const a = await ctx.credentials.issueUserCredential({ homeId: ctx.home.id, userId: ctx.owner.id });
  ctx.timeline.length = 0;
  const r = await ctx.world.db.withTransaction((tx) => ctx.credentials.revokeHomeAccess({ homeId: ctx.home.id, tx }));
  assert.deepStrictEqual(r.usernames, [a.username]);
  assert.ok(!('kick' in r), 'tx modunda kick cagiran sorumlulugundadir');
  assert.deepStrictEqual(ctx.timeline, []);
  const k = await ctx.credentials.kickUsernames(r.usernames);
  assert.strictEqual(k.kicked, 1);
});

test('cleanupExpired: suresi dolan uygulama kimlikleri silinir + atilir; cihaz ve gecerli kimlikler kalir', async () => {
  const ctx = setup();
  enableEmqx();
  const short = await ctx.credentials.issueUserCredential({
    homeId: ctx.home.id, userId: ctx.resident.id, validUntil: new Date(ctx.world.clock.t + 60 * 1000),
  });
  const long = await ctx.credentials.issueUserCredential({ homeId: ctx.home.id, userId: ctx.owner.id });
  const dev = await ctx.credentials.issueDeviceCredential({ homeId: ctx.home.id, deviceId: ctx.dev.id });
  ctx.timeline.length = 0;

  const none = await ctx.credentials.cleanupExpired();
  assert.strictEqual(none.deleted, 0);

  ctx.world.clock.advance(61 * 1000);
  const r = await ctx.credentials.cleanupExpired();
  assert.strictEqual(r.deleted, 1);
  assert.deepStrictEqual(r.usernames, [short.username]);
  assert.deepStrictEqual(ctx.timeline, [`kick:${short.username}`]);
  assert.deepStrictEqual(
    ctx.world.state.mqtt_credentials.map((c) => c.username).sort(),
    [long.username, dev.username].sort()
  );

  ctx.world.clock.advance(13 * 3600 * 1000);
  const r2 = await ctx.credentials.cleanupExpired();
  assert.deepStrictEqual(r2.usernames, [long.username]);
  assert.deepStrictEqual(ctx.world.state.mqtt_credentials.map((c) => c.kind), ['device']);
});

test('zamanlayici: startCleanup periyodik temizler, tekrar baslatma yinelenmez, stopCleanup durdurur', async (t) => {
  // Sahte zamanlayici: gercek sureye bagli olmadigi icin yuk altinda dalgalanmaz.
  t.mock.timers.enable({ apis: ['setInterval'] });
  const ctx = setup();
  let runs = 0;
  const svc = new MqttCredentialService({ db: ctx.world.db, env: process.env, logger: silentLogger, fetch: createFakeFetch() });
  svc.cleanupExpired = async () => {
    runs += 1;
    return { deleted: 0 };
  };
  svc.startCleanup({ intervalMs: 1000 });
  svc.startCleanup({ intervalMs: 1000 }); // ikinci cagri yeni zamanlayici acmaz
  t.mock.timers.tick(3000);
  await new Promise((resolve) => setImmediate(resolve));
  assert.strictEqual(runs, 3, 'her periyotta bir kez (yinelenmeden) calismali');
  svc.stopCleanup();
  t.mock.timers.tick(5000);
  await new Promise((resolve) => setImmediate(resolve));
  assert.strictEqual(runs, 3, 'stopCleanup sonrasi calismamali');
  svc.stopCleanup(); // tekrar guvenli

  // varsayilan periyot 60 sn
  svc.startCleanup();
  t.mock.timers.tick(59000);
  await new Promise((resolve) => setImmediate(resolve));
  assert.strictEqual(runs, 3);
  t.mock.timers.tick(1000);
  await new Promise((resolve) => setImmediate(resolve));
  assert.strictEqual(runs, 4);
  svc.stopCleanup();
});

test('zamanlayici hata yutmaz ama sureci de dusurmez (loglanir)', async (t) => {
  t.mock.timers.enable({ apis: ['setInterval'] });
  const ctx = setup();
  const errors = [];
  const svc = new MqttCredentialService({
    db: ctx.world.db, env: process.env, fetch: createFakeFetch(), logger: { warn() {}, error: (...a) => errors.push(a.join(' ')) },
  });
  svc.cleanupExpired = async () => {
    throw new Error('veritabani yok');
  };
  svc.startCleanup({ intervalMs: 1000 });
  t.mock.timers.tick(2000);
  await new Promise((resolve) => setImmediate(resolve));
  svc.stopCleanup();
  assert.ok(errors.length >= 1);
  assert.ok(errors[0].includes('veritabani yok'));
});

// ------------------------------------------------------------------------------------------------
// EMQX REST kick
// ------------------------------------------------------------------------------------------------

test('kick: Basic kimlik + /api/v5/clients?username= listesi + istemci basina DELETE; kullanici adi URL-kodlanir', async () => {
  const ctx = setup();
  enableEmqx();
  const r = await ctx.credentials.kickUsernames(['a_h_0123456789abcdef_0a1b2c3d4e', 'a b&c=d']);
  assert.strictEqual(r.requested, 2);
  assert.strictEqual(r.kicked, 2);
  assert.strictEqual(r.failed, 0);
  assert.strictEqual(r.skipped, false);

  const calls = ctx.fetchFn.calls;
  assert.strictEqual(calls.length, 4);
  const auth = calls[0].headers.Authorization;
  assert.strictEqual(auth, `Basic ${Buffer.from('anahtar-x:gizli-y').toString('base64')}`);
  assert.ok(calls[0].url.startsWith('http://emqx.test.invalid:18083/api/v5/clients?username=a_h_0123456789abcdef_0a1b2c3d4e'));
  assert.strictEqual(calls[0].method, 'GET');
  assert.strictEqual(calls[1].method, 'DELETE');
  assert.ok(calls[1].url.endsWith('/api/v5/clients/a_h_0123456789abcdef_0a1b2c3d4e'));
  assert.ok(calls[2].url.includes('username=a%20b%26c%3Dd'), 'kullanici adi sorguda kodlanmali');
  assert.ok(calls[3].url.endsWith('/api/v5/clients/a%20b%26c%3Dd'));
});

test('kick: EMQX_API_* yoksa ATLANIR ve uyari loglanir (sessiz basari degil: skipped=true)', async () => {
  const ctx = setup(); // EMQX tanimli degil
  const warnings = [];
  const svc = new MqttCredentialService({
    db: ctx.world.db, env: process.env, fetch: ctx.fetchFn, logger: { warn: (m) => warnings.push(m), error() {} },
  });
  const r = await svc.kickUsernames(['a_x']);
  assert.strictEqual(r.skipped, true);
  assert.strictEqual(r.kicked, 0);
  assert.strictEqual(ctx.fetchFn.calls.length, 0);
  assert.strictEqual(warnings.length, 1);
  assert.match(warnings[0], /EMQX_API/);

  // bos liste ag kullanmaz ve uyari vermez
  const empty = await svc.kickUsernames([]);
  assert.deepStrictEqual(empty, { requested: 0, kicked: 0, failed: 0, skipped: false, errors: [] });
  assert.strictEqual(warnings.length, 1);
});

test('kick: hatalar FIRLATILMAZ, sayilir ve ozetlenir (sir icermez); 404 basari sayilir', async () => {
  const ctx = setup();
  enableEmqx();

  ctx.fetchFn.failAll = true;
  const r = await ctx.credentials.kickUsernames(['u1', 'u2']);
  assert.strictEqual(r.failed, 2);
  assert.strictEqual(r.kicked, 0);
  assert.ok(r.errors.every((e) => !/anahtar-x|gizli-y|Basic/.test(e)));

  ctx.fetchFn.failAll = false;
  ctx.fetchFn.deleteStatus = 500;
  const r2 = await ctx.credentials.kickUsernames(['u1']);
  assert.strictEqual(r2.failed, 1);

  ctx.fetchFn.deleteStatus = 404; // zaten bagli degil
  const r3 = await ctx.credentials.kickUsernames(['u1']);
  assert.strictEqual(r3.kicked, 1);
  assert.strictEqual(r3.failed, 0);
});

test('kick: liste istegi basarisizsa (HTTP hata) failed sayilir ve sonraki kullanici denenir', async () => {
  const ctx = setup();
  enableEmqx();
  const calls = [];
  const flaky = async (url, init = {}) => {
    calls.push(String(url));
    if (String(url).includes('username=bad')) return { ok: false, status: 503, json: async () => ({}) };
    return createFakeFetch()(url, init);
  };
  const svc = new MqttCredentialService({ db: ctx.world.db, env: process.env, fetch: flaky, logger: silentLogger });
  const r = await svc.kickUsernames(['bad', 'good']);
  assert.strictEqual(r.failed, 1);
  assert.strictEqual(r.kicked, 1);
  assert.ok(r.errors[0].includes('503'));
});

test('kick: ayni kullanici adi tekrar edilse bile bir kez istenir', async () => {
  const ctx = setup();
  enableEmqx();
  await ctx.credentials.kickUsernames(['x', 'x', 'x', '', null]);
  assert.strictEqual(ctx.fetchFn.calls.filter((c) => c.method === 'GET').length, 1);
});

// ------------------------------------------------------------------------------------------------
test('parola hicbir yere loglanmaz (console), kaynakta Math.random ve sabit kimlik yok', async () => {
  const ctx = setup();
  const captured = [];
  const orig = { log: console.log, warn: console.warn, error: console.error, info: console.info };
  console.log = console.warn = console.error = console.info = (...a) => captured.push(a.join(' '));
  let c;
  try {
    const svc = new MqttCredentialService({ db: ctx.world.db, env: process.env, now: () => ctx.world.clock.now() });
    c = await svc.issueUserCredential({ homeId: ctx.home.id, userId: ctx.owner.id });
    await svc.kickUsernames([c.username]); // EMQX yok -> uyari loglanir (parolasiz)
  } finally {
    Object.assign(console, orig);
  }
  assert.ok(captured.every((line) => !line.includes(c.password)), 'parola log\'a yazilmamali');

  const src = fs.readFileSync(require.resolve('../../src/services/mqtt_credential_service'), 'utf8');
  assert.ok(!/Math\.random\s*\(/.test(src));
  assert.ok(!/home_101|PassHome|GudeBackend|sha256/i.test(src), 'eski paylasilan kimlik/sha256 kalintisi');
});

test('migration 020: tablo/sutun adlari EMQX sozlesmesiyle uyumlu ve idempotent', () => {
  const sql = fs.readFileSync(require.resolve('../../migrations/020_mqtt_credentials.sql'), 'utf8');
  for (const frag of [
    'CREATE TABLE IF NOT EXISTS mqtt_credentials', 'username', 'password_hash', 'is_superuser', 'expires_at',
    'CREATE TABLE IF NOT EXISTS mqtt_acl', 'permission', 'action', 'topic',
    'ON DELETE CASCADE',
  ]) {
    assert.ok(sql.includes(frag), `eksik: ${frag}`);
  }
  assert.ok(!/^\s*(BEGIN|COMMIT)\s*;/im.test(sql), 'migration kendi transaction\'ini acmamali (runner sarmalar)');
  // her CREATE/ALTER idempotent
  for (const m of sql.matchAll(/CREATE\s+(UNIQUE\s+)?(TABLE|INDEX)\s+(?!IF NOT EXISTS)/gi)) {
    assert.fail(`IF NOT EXISTS yok: ${m[0]}`);
  }
  assert.ok(!/password\s+VARCHAR|plain/i.test(sql), 'duz metin parola kolonu olmamali');
});

test('generatePassword: 24 karakter, yalniz harf/rakam, her cagrida farkli; revokeDeviceCredential deviceId olmadan evin cihaz kimligini siler', async () => {
  const ctx = setup();
  const a = ctx.credentials.generatePassword();
  const b = ctx.credentials.generatePassword();
  assert.match(a, /^[A-Za-z0-9]{24}$/);
  assert.notStrictEqual(a, b);

  await ctx.credentials.issueDeviceCredential({ homeId: ctx.home.id, deviceId: ctx.dev.id });
  await ctx.credentials.issueUserCredential({ homeId: ctx.home.id, userId: ctx.owner.id });
  const r = await ctx.credentials.revokeDeviceCredential({ homeId: ctx.home.id });
  assert.strictEqual(r.revoked, 1);
  assert.deepStrictEqual(ctx.world.state.mqtt_credentials.map((c) => c.kind), ['app'], 'uygulama kimligi korunur');
});

test('cihaz kimligi rotasyonu: ev basina advisory kilit DELETE/INSERT\'ten ONCE ve AYNI transaction\'da alinir (es zamanli rotasyon UNIQUE ihlali vermez)', async () => {
  const ctx = setup();
  ctx.world.db.log.length = 0;
  await ctx.credentials.issueDeviceCredential({ homeId: ctx.home.id, deviceId: ctx.dev.id });
  const log = ctx.world.db.log;
  const lockIdx = log.findIndex((l) => l.sql.includes('pg_advisory_xact_lock'));
  const delIdx = log.findIndex((l) => l.sql.includes("DELETE FROM mqtt_credentials WHERE home_id = $1 AND kind = 'device'"));
  assert.ok(lockIdx >= 0 && delIdx > lockIdx, 'kilit eski kimligi silmeden ONCE alinmali');
  assert.strictEqual(log[lockIdx].params[0], `mqtt-device-cred:${ctx.home.id}`);
  assert.notStrictEqual(log[lockIdx].tx, null, 'kilit transaction icinde');
  assert.strictEqual(log[lockIdx].tx, log[delIdx].tx, 'kilit ve silme AYNI transaction');

  const settled = await Promise.allSettled([1, 2, 3, 4].map(() => ctx.credentials.issueDeviceCredential({ homeId: ctx.home.id, deviceId: ctx.dev.id })));
  assert.ok(settled.every((s) => s.status === 'fulfilled'), JSON.stringify(settled.filter((s) => s.status === 'rejected').map((s) => s.reason.message)));
  assert.strictEqual(ctx.world.state.mqtt_credentials.filter((c) => c.kind === 'device').length, 1);
});
