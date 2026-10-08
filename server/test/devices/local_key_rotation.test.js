'use strict';

// pano-6: erisimi biten kisinin bildigi yerel anahtar BEKLEYEN yolla dondurulur (pano-5 altyapisi; yalniz tek panolu ev;
// firmware degismez).
//  - scheduleRotation(homeId, {tx, reason}): tek pano + bekleyen yok -> yeni anahtar bekleyen + denetim
//    'local_key_rotation_scheduled' {reason} (anahtar YOK) -> {scheduled:true, topicId}; 0 pano 'no_device'; cok pano
//    'multi_board' (bir kez log); bekleyen varsa 'already_pending' (ikinci rotasyon yazmaz)
//  - afterCommit: evin konusu icin uzlastirici istenir (COMMIT sonrasi, en iyi caba)
//  - servis oturumu: anahtari okuyan oturum isaretlenir (local_key_read_at); bitince (iptal / sure) supurucu rotasyon
//    planlar + key_rotated_at; anahtari OKUMAMIS oturumda ve suren oturumda rotasyon yok
// Tetikleyiciler (devir, uye cikarma, assign-admin, hesap silme) kendi test dosyalarinda.

const test = require('node:test');
const assert = require('node:assert');
const crypto = require('crypto');

const { createWorld, createServices, setTestEnv } = require('./_world');
const { injectModule } = require('./_routes_env');

setTestEnv();
process.env.JWT_SECRET = process.env.JWT_SECRET || crypto.randomBytes(32).toString('hex');
let currentDb = null;
injectModule('db.js', {
  query: (t, p) => currentDb.query(t, p),
  withTransaction: (fn) => currentDb.withTransaction(fn),
  pool: { end: async () => {} },
});

const { LocalKeyRotation } = require('../../src/services/local_key_rotation');
const serviceTokenService = require('../../src/services/service_token_service');

const OLD_KEY = 'EskiAnahtar12345';

function setup({ devices = 1, pending = false } = {}) {
  setTestEnv();
  const world = createWorld();
  currentDb = world.db;
  const svc = createServices(world);
  const h = world.helpers;
  const owner = h.addUser({ email: 'sahip@example.test' });
  const home = h.addHome({ name: 'Daire 3', owner });
  const devs = [];
  for (let i = 0; i < devices; i++) {
    devs.push(h.addDevice({ home, uuid: `AHBU-S3-00${i + 1}0`, mac: `E8:F6:0A:00:01:0${i}`, local_key_enc: svc.secretBox.encrypt(OLD_KEY) }));
  }
  if (pending && devs[0]) devs[0].local_key_pending_enc = svc.secretBox.encrypt('BekleyenAnahtar1');
  const reconciles = [];
  const logs = [];
  const rotation = new LocalKeyRotation({
    secretBox: svc.secretBox,
    requestReconcile: (t) => reconciles.push(t),
    logger: { log: (m) => logs.push(String(m)), warn: (m) => logs.push(String(m)), error: (m) => logs.push(String(m)) },
  });
  serviceTokenService.setLocalKeyRotation(rotation);
  return { world, ...svc, h, owner, home, devs, rotation, reconciles, logs };
}

const audits = (ctx, event) => ctx.world.state.device_audit_logs.filter((a) => a.event === event);
const inTx = (ctx, fn) => ctx.world.db.withTransaction(fn);

test('scheduleRotation: tek panolu evde yeni anahtar BEKLEYEN yazilir + denetim (anahtarsiz); COMMIT sonrasi uzlastirici', async () => {
  const ctx = setup();
  const dev = ctx.devs[0];
  const r = await inTx(ctx, (tx) => ctx.rotation.scheduleRotation(ctx.home.id, { tx, reason: 'member_removed' }));
  assert.deepStrictEqual(r, { scheduled: true, topicId: ctx.home.mqtt_username, deviceUuid: dev.device_uuid });
  assert.ok(dev.local_key_pending_enc, 'bekleyen yazildi');
  const newKey = ctx.secretBox.decrypt(dev.local_key_pending_enc);
  assert.ok(ctx.secretBox.isValidLocalKey(newKey));
  assert.notStrictEqual(newKey, OLD_KEY);
  assert.strictEqual(ctx.secretBox.decrypt(dev.local_key_enc), OLD_KEY, 'gecerli anahtar degismez (pano iletilene kadar)');
  assert.ok(dev.local_key_pending_at instanceof Date);
  const a = audits(ctx, 'local_key_rotation_scheduled');
  assert.strictEqual(a.length, 1);
  assert.deepStrictEqual(a[0].details, { reason: 'member_removed' });
  assert.strictEqual(a[0].device_uuid, dev.device_uuid);
  assert.strictEqual(a[0].home_id, ctx.home.id);
  assert.ok(!JSON.stringify(ctx.world.state.device_audit_logs).includes(newKey), 'anahtar denetimde yok');
  assert.deepStrictEqual(ctx.reconciles, [], 'islem icinde uzlastirici istenmez');
  ctx.rotation.afterCommit(r);
  assert.deepStrictEqual(ctx.reconciles, [ctx.home.mqtt_username]);
  assert.ok(!ctx.logs.join('\n').includes(newKey), 'anahtar loglanmaz');
});

test('scheduleRotation: pano yok -> no_device; cok panolu ev -> multi_board (yazim yok, bir kez log); bekleyen varken ikinci rotasyon yazmaz', async () => {
  const none = setup({ devices: 0 });
  assert.deepStrictEqual(await inTx(none, (tx) => none.rotation.scheduleRotation(none.home.id, { tx, reason: 'member_removed' })), { scheduled: false, reason: 'no_device' });

  const multi = setup({ devices: 2 });
  for (let i = 0; i < 2; i++) {
    const r = await inTx(multi, (tx) => multi.rotation.scheduleRotation(multi.home.id, { tx, reason: 'home_transfer' }));
    assert.deepStrictEqual(r, { scheduled: false, reason: 'multi_board' });
  }
  assert.ok(multi.devs.every((d) => !d.local_key_pending_enc), 'cok panolu evde bekleyen yazilmaz');
  assert.strictEqual(audits(multi, 'local_key_rotation_scheduled').length, 0);
  assert.strictEqual(multi.logs.filter((l) => /cok panolu/i.test(l)).length, 1, 'bir kez loglanir');
  multi.rotation.afterCommit({ scheduled: false, reason: 'multi_board' });
  assert.deepStrictEqual(multi.reconciles, []);

  const pend = setup({ pending: true });
  const before = pend.devs[0].local_key_pending_enc;
  const r = await inTx(pend, (tx) => pend.rotation.scheduleRotation(pend.home.id, { tx, reason: 'member_removed' }));
  assert.deepStrictEqual(r, { scheduled: false, reason: 'already_pending' });
  assert.strictEqual(pend.devs[0].local_key_pending_enc, before, 'mevcut bekleyen korunur');
  assert.strictEqual(audits(pend, 'local_key_rotation_scheduled').length, 0);
});

test('getLocalKey: servis OTURUMU anahtari okuyunca oturum isaretlenir (local_key_read_at); kullanici okumasi isaretlemez', async () => {
  const ctx = setup();
  const sid = crypto.randomUUID();
  ctx.world.state.service_sessions.push({ id: sid, home_id: ctx.home.id, expires_at: new Date(ctx.world.clock.t + 3600e3), revoked_at: null, local_key_read_at: null, key_rotated_at: null });
  const r = await ctx.deviceService.getLocalKey({
    actor: { userId: null, globalRole: 'service_session', isServiceSession: true, sessionId: sid, access: 'service_session', ip: '10.0.0.5' },
    homeId: ctx.home.id,
    deviceUuid: ctx.devs[0].device_uuid,
  });
  assert.strictEqual(r.local_key, OLD_KEY);
  const s = ctx.world.state.service_sessions.find((x) => x.id === sid);
  assert.ok(s.local_key_read_at instanceof Date, 'okuma isaretlendi');

  const before = ctx.world.db.log.filter((l) => /local_key_read_at/.test(l.sql)).length;
  await ctx.deviceService.getLocalKey({
    actor: { userId: ctx.owner.id, globalRole: 'user', access: 'owner', ip: '10.0.0.6' },
    homeId: ctx.home.id,
    deviceUuid: ctx.devs[0].device_uuid,
  });
  assert.strictEqual(ctx.world.db.log.filter((l) => /local_key_read_at/.test(l.sql)).length, before, 'sahip okumasi oturum isaretlemez');
});

test('supurucu: anahtari okumus + iptal/suresi dolmus oturum -> rotasyon + key_rotated_at; okumamis / suren oturumda rotasyon yok; tekrar tur is yapmaz', async () => {
  const ctx = setup();
  const now = ctx.world.clock.t;
  const other = setup();
  // iki ayri dunya olmasin: ikinci ev ayni dunyada
  currentDb = ctx.world.db;
  serviceTokenService.setLocalKeyRotation(ctx.rotation);
  const home2 = ctx.h.addHome({ name: 'Daire 4', owner: ctx.owner });
  const dev2 = ctx.h.addDevice({ home: home2, uuid: 'AHBU-S3-0990', mac: 'E8:F6:0A:00:09:90', local_key_enc: ctx.secretBox.encrypt(OLD_KEY) });
  const home3 = ctx.h.addHome({ name: 'Daire 5', owner: ctx.owner });
  const dev3 = ctx.h.addDevice({ home: home3, uuid: 'AHBU-S3-0991', mac: 'E8:F6:0A:00:09:91', local_key_enc: ctx.secretBox.encrypt(OLD_KEY) });
  const home4 = ctx.h.addHome({ name: 'Daire 6', owner: ctx.owner });
  const dev4 = ctx.h.addDevice({ home: home4, uuid: 'AHBU-S3-0992', mac: 'E8:F6:0A:00:09:92', local_key_enc: ctx.secretBox.encrypt(OLD_KEY) });
  const S = ctx.world.state.service_sessions;
  const mk = (homeId, extra) => {
    const row = { id: crypto.randomUUID(), home_id: homeId, expires_at: new Date(now + 3600e3), revoked_at: null, local_key_read_at: null, key_rotated_at: null, ...extra };
    S.push(row);
    return row;
  };
  const revokedRead = mk(ctx.home.id, { revoked_at: new Date(now - 1000), local_key_read_at: new Date(now - 5000) });
  const expiredRead = mk(home2.id, { expires_at: new Date(now - 1000), local_key_read_at: new Date(now - 5000) });
  const revokedNotRead = mk(home3.id, { revoked_at: new Date(now - 1000) });
  const activeRead = mk(home4.id, { local_key_read_at: new Date(now - 5000) });

  const r = await serviceTokenService.sweepEndedSessions();
  assert.deepStrictEqual(r, { homes: 2, scheduled: 2 });
  assert.ok(ctx.devs[0].local_key_pending_enc, 'iptal edilen + okumus oturumun evi');
  assert.ok(dev2.local_key_pending_enc, 'suresi dolan + okumus oturumun evi');
  assert.ok(!dev3.local_key_pending_enc, 'anahtari okumamis oturum: rotasyon yok');
  assert.ok(!dev4.local_key_pending_enc, 'suren oturum: rotasyon yok');
  assert.ok(revokedRead.key_rotated_at instanceof Date);
  assert.ok(expiredRead.key_rotated_at instanceof Date);
  assert.strictEqual(revokedNotRead.key_rotated_at, null);
  assert.strictEqual(activeRead.key_rotated_at, null);
  const reasons = audits(ctx, 'local_key_rotation_scheduled').map((a) => a.details.reason);
  assert.deepStrictEqual(reasons, ['service_session_ended', 'service_session_ended']);
  assert.deepStrictEqual(ctx.reconciles.sort(), [ctx.home.mqtt_username, home2.mqtt_username].sort(), 'COMMIT sonrasi uzlastirici');

  const again = await serviceTokenService.sweepEndedSessions();
  assert.deepStrictEqual(again, { homes: 0, scheduled: 0 }, 'isaretli oturumlar tekrar islenmez');

  // ev kapsamli tur (iptal ucu / kendi cikisi): yalniz o ev
  activeRead.revoked_at = new Date(now);
  const scoped = await serviceTokenService.sweepEndedSessions({ homeId: ctx.home.id });
  assert.deepStrictEqual(scoped, { homes: 0, scheduled: 0 }, 'baska evin oturumu kapsam disi');
  const scoped4 = await serviceTokenService.sweepEndedSessions({ homeId: home4.id });
  assert.deepStrictEqual(scoped4, { homes: 1, scheduled: 1 });
  assert.ok(dev4.local_key_pending_enc);
  assert.ok(other); // ikinci kurulum yalniz dunya sifirlamasi icin
});

test('supurucu: cok panolu evde rotasyon yapilmaz ama oturum isaretlenir (sonsuz tekrar yok)', async () => {
  const ctx = setup({ devices: 2 });
  const now = ctx.world.clock.t;
  const s = { id: crypto.randomUUID(), home_id: ctx.home.id, expires_at: new Date(now + 3600e3), revoked_at: new Date(now - 10), local_key_read_at: new Date(now - 100), key_rotated_at: null };
  ctx.world.state.service_sessions.push(s);
  assert.deepStrictEqual(await serviceTokenService.sweepEndedSessions(), { homes: 1, scheduled: 0 });
  assert.ok(s.key_rotated_at instanceof Date);
  assert.ok(ctx.devs.every((d) => !d.local_key_pending_enc));
  assert.deepStrictEqual(ctx.reconciles, []);
});

test('supurucu zamanlayicisi: unref, tekrar baslatma yeni zamanlayici kurmaz, durdurulur', () => {
  const realSet = global.setInterval;
  const realClear = global.clearInterval;
  const made = [];
  const cleared = [];
  global.setInterval = (fn, ms) => {
    const t = { fn, ms, unrefed: false, unref() { this.unrefed = true; return this; } };
    made.push(t);
    return t;
  };
  global.clearInterval = (t) => cleared.push(t);
  try {
    serviceTokenService.startSweeper();
    serviceTokenService.startSweeper();
    assert.strictEqual(made.length, 1);
    assert.strictEqual(made[0].ms, 5 * 60 * 1000);
    assert.strictEqual(made[0].unrefed, true);
    serviceTokenService.stopSweeper();
    assert.deepStrictEqual(cleared, [made[0]]);
    serviceTokenService.stopSweeper();
    assert.strictEqual(cleared.length, 1);
  } finally {
    global.setInterval = realSet;
    global.clearInterval = realClear;
  }
});
