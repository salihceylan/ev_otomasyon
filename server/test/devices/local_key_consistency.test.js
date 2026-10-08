'use strict';

// pano-5: yerel anahtar tutarliligi (CONTRACTS lk_fp + 19).
//  - lk_fp = HMAC-SHA256(anahtar = local_key ASCII, ileti = 'ahbu-lk-fp/1|' + BUYUK HARF UID) hex ilk 8 (sozlesme vektorleri)
//  - acil sifirlama DEVIR (REASSIGNED): evli panoda (cevrimici de olsa) yeni anahtar BEKLEYEN yazilir ve uzlastiriciyla
//    iletilir; commit sonrasi set_local_key YAYINLANMAZ; yanitta anahtar yok
//  - acil sifirlama STOGA DONUS (UNCLAIMED, inceleme): yeni anahtar HEMEN gecerli (cihaz + envanter), bekleyen yok;
//    tek panolu evde kick'ten once set_local_key (en iyi caba); anahtar yanitta bir kez
//  - 'direct' planlarda onceki anahtar SAKLANMAZ (local_key_prev_* yok)
//  - GET .../local-key yanitinda local_key_fp (ayni formul)

const test = require('node:test');
const assert = require('node:assert');

const { createWorld, createServices, setTestEnv } = require('./_world');

const UUID = 'AHBU-S3-0001';
const REASON = 'Kiraci ulasilamiyor, daire teslim alindi';
const OLD_KEY = 'EskiAnahtar123456';

test('lk_fp: sozlesme test vektorleri; UID buyuk harfe cevrilir; gecersiz girdi null', () => {
  const { localKeyFingerprint } = require('../../src/utils/local_key_fp');
  assert.strictEqual(localKeyFingerprint('ABCDEFGH23456789', 'AHBU-S3-DD8754'), 'c7076562');
  assert.strictEqual(localKeyFingerprint('k3yTEST-9999', 'AHBU-S3-0A1B2C'), '9814f286');
  assert.strictEqual(localKeyFingerprint('k3yTEST-9999', 'ahbu-s3-0a1b2c'), '9814f286', 'UID buyuk harf');
  assert.strictEqual(localKeyFingerprint('', 'AHBU-S3-0A1B2C'), null);
  assert.strictEqual(localKeyFingerprint('k3yTEST-9999', ''), null);
  assert.strictEqual(localKeyFingerprint(null, 'AHBU-S3-0A1B2C'), null);
});

async function setup({ online = true } = {}) {
  setTestEnv();
  const world = createWorld();
  const svc = createServices(world);
  const h = world.helpers;
  const tech = h.addUser({ email: 'teknisyen@example.test', role: 'service_user' });
  const owner = h.addUser({ email: 'sahip@example.test' });
  const inv = h.addInventory({ uuid: UUID, pin: '246810', status: 'CLAIMED' });
  const home = h.addHome({ name: 'Daire 7', owner });
  h.addMember(home, tech, 'service_user', { installer_expires_at: new Date(world.clock.t + 3600000) });
  const oldKeyEnc = svc.secretBox.encrypt(OLD_KEY);
  const dev = h.addDevice({ home, uuid: UUID, mac: inv.mac_address, claimedBy: owner, online, local_key_enc: oldKeyEnc });
  Object.assign(inv, { claimed_home_id: home.id, claimed_by_user_id: owner.id, pin_hash: 'CLAIMED_BURNED_PIN', local_key_enc: oldKeyEnc });
  await svc.credentials.issueDeviceCredential({ homeId: home.id, deviceId: dev.id });
  const rearmed = [];
  svc.bridge.requestReconcile = (topicId) => rearmed.push(topicId);
  svc.credentials.kickUsernames = async () => ({ failed: 0 });
  const reset = (extra = {}) =>
    svc.deviceService.emergencyReset({
      actor: { userId: tech.id, globalRole: 'service_user', ip: '203.0.113.9' },
      deviceUuid: UUID,
      confirmUid: UUID,
      reason: REASON,
      ...extra,
    });
  return { world, ...svc, tech, owner, inv, home, dev, oldKeyEnc, reset, rearmed };
}

test('pano-5: CEVRIMICI + bagli kopruda da DEVIR anahtari BEKLEYEN yazar; commit sonrasi set_local_key YAYINLANMAZ; uzlastirici kurulur', async () => {
  const ctx = await setup({ online: true });
  const newbie = ctx.world.helpers.addUser({ email: 'yeni.sahip0@example.test', full_name: 'Yeni' });
  newbie.email_verified = true;
  const r = await ctx.reset({ newOwnerIdentifier: newbie.email });
  assert.strictEqual(r.action, 'REASSIGNED');
  assert.strictEqual(r.local_key_publish, 'pending');
  assert.ok(!('local_key' in r), 'pending iken anahtar donmez');
  assert.strictEqual(ctx.bridge.topics.filter((t) => t.obj && t.obj.cmd === 'set_local_key').length, 0, 'sys yayini YOK');
  assert.strictEqual(ctx.dev.local_key_enc, ctx.oldKeyEnc, 'panodaki gercek anahtar gecerli kalir');
  assert.strictEqual(ctx.inv.local_key_enc, ctx.oldKeyEnc);
  assert.ok(ctx.dev.local_key_pending_enc, 'yeni anahtar bekleyen');
  assert.deepStrictEqual(ctx.rearmed, [ctx.home.mqtt_username], 'uzlastirici bu ev icin kurulur');
});

test('inceleme: STOGA DONUSTE bekleyen YAZILMAZ; yeni anahtar cihaz + envanterde gecerli; kick ten once set_local_key; yanitta anahtar', async () => {
  const ctx = await setup({ online: true });
  const r = await ctx.reset();
  assert.strictEqual(r.action, 'UNCLAIMED');
  assert.strictEqual(r.local_key_publish, 'published');
  assert.ok(ctx.secretBox.isValidLocalKey(r.local_key));
  assert.strictEqual(ctx.secretBox.decrypt(ctx.dev.local_key_enc), r.local_key);
  assert.strictEqual(ctx.secretBox.decrypt(ctx.inv.local_key_enc), r.local_key, 'envanter eski anahtar DEGIL');
  assert.ok(!ctx.dev.local_key_pending_enc);
  assert.deepStrictEqual(ctx.rearmed, []);
  const sys = ctx.bridge.topics.filter((t) => t.obj && t.obj.cmd === 'set_local_key');
  assert.strictEqual(sys.length, 1);
  assert.strictEqual(sys[0].obj.local_key, r.local_key);
});

test('pano-5: ev/konu yok (direct): anahtar hemen degisir, yanitta bir kez doner (skipped); ESKI anahtar SAKLANMAZ', async () => {
  const ctx = await setup({ online: false });
  // pano evden ayrilmis (yetim cihaz satiri) ama envanter CLAIMED kalmis: ev/konu yok -> direct
  ctx.dev.home_id = null;
  ctx.inv.claimed_home_id = null;
  ctx.world.state.home_users.length = 0;
  const actor = { userId: ctx.world.helpers.addUser({ email: 'root@example.test', role: 'super_user' }).id, globalRole: 'super_user', ip: '203.0.113.9' };
  const r = await ctx.deviceService.emergencyReset({ actor, deviceUuid: UUID, confirmUid: UUID, reason: REASON });
  assert.strictEqual(r.local_key_publish, 'skipped');
  assert.ok(ctx.secretBox.isValidLocalKey(r.local_key), 'skipped: anahtar bir kez doner');
  assert.strictEqual(ctx.secretBox.decrypt(ctx.dev.local_key_enc), r.local_key);
  assert.strictEqual(ctx.secretBox.decrypt(ctx.inv.local_key_enc), r.local_key);
  assert.ok(!ctx.dev.local_key_prev_enc, 'onceki anahtar saklanmaz');
  assert.ok(!ctx.world.db.sqls().some((s) => s.includes('local_key_prev')), 'SQL onceki anahtara dokunmaz');
});

test('pano-5 (h): GET local-key yanitinda local_key_fp (ayni formul)', async () => {
  const ctx = await setup({ online: true });
  const { localKeyFingerprint } = require('../../src/utils/local_key_fp');
  const r = await ctx.deviceService.getLocalKey({ actor: { userId: ctx.owner.id, access: 'owner' }, homeId: ctx.home.id, deviceUuid: UUID });
  assert.strictEqual(r.local_key, OLD_KEY);
  assert.strictEqual(r.local_key_fp, localKeyFingerprint(OLD_KEY, UUID));
  assert.match(r.local_key_fp, /^[0-9a-f]{8}$/);
});
