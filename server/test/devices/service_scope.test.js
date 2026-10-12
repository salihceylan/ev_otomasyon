'use strict';

// Servis sorumlusu KAPSAMI (045) - cihaz servisi (sahte db): claim / acil sifirlama / pano degisimi.
// Gercek PostgreSQL karsiligi: test/service_panel/service_scope_pg.test.js.
//   - servis YALNIZ kendi stogundaki ya da kok stogundaki (service_owner_id NULL) karti kurar; baska servisin karti 403
//     ve PIN sayaci / OTP satirina DOKUNULMAZ
//   - claim: ev + kart sihirbazla sahiplendiren servisin kapsamina girer, servis uyeligi SURESIZ
//   - acil sifirlama: kapsam = evin servisi ya da (sahipsiz evde) servis uyeligi; evin servisi BASKASIYSA uyelik olsa bile 403
//   - devir: devreden servis evin sahibi olur
//   - pano degisimi: baska servisin karti evin servisinden farkliysa 403 (kok her karti takar); kurulan kart evin servisini izler

const test = require('node:test');
const assert = require('node:assert');

const { createWorld, createServices, setTestEnv, expectHttp } = require('./_world');

const PIN = '123456';
const REASON = 'Kiraci ulasilamiyor, daire teslim alindi';

function setup() {
  setTestEnv();
  const world = createWorld();
  const svc = createServices(world);
  const h = world.helpers;
  const svcA = h.addUser({ email: 'servis.a@example.test', role: 'service_user', full_name: 'Servis A' });
  const svcB = h.addUser({ email: 'servis.b@example.test', role: 'service_user', full_name: 'Servis B' });
  const root = h.addUser({ email: 'kok@example.test', role: 'super_user' });
  const customer = h.addUser({ email: 'musteri@example.test' });
  const act = (user, extra = {}) => ({ userId: user.id, globalRole: user.role, ip: '10.0.0.7', ...extra });
  const card = (uuid, owner = null, extra = {}) => {
    const inv = h.addInventory({ uuid, pin: PIN, ...extra });
    inv.service_owner_id = owner ? owner.id : null;
    return inv;
  };
  const claimFor = async (service, inv, email = customer.email) => {
    await svc.deviceService.requestClaimOtp({ actor: act(service), deviceUuid: inv.device_uuid, targetOwnerIdentifier: email });
    return svc.deviceService.claimDevice({
      actor: act(service), deviceUuid: inv.device_uuid, setupPin: PIN, targetOwnerIdentifier: email, otpCode: svc.mailer.lastCode(),
    });
  };
  return { world, ...svc, h, svcA, svcB, root, customer, act, card, claimFor };
}

test('claim: baska servisin stogundaki kart 403 (OTP istegi de); PIN sayaci, OTP satiri ve musteri e-postasi DEGISMEZ', async () => {
  const ctx = setup();
  const inv = ctx.card('AHBU-S3-0001', ctx.svcA);
  await expectHttp(
    ctx.deviceService.requestClaimOtp({ actor: ctx.act(ctx.svcB), deviceUuid: inv.device_uuid, targetOwnerIdentifier: ctx.customer.email }),
    403, 'FORBIDDEN'
  );
  await expectHttp(
    ctx.deviceService.claimDevice({ actor: ctx.act(ctx.svcB), deviceUuid: inv.device_uuid, setupPin: '000000', targetOwnerIdentifier: ctx.customer.email, otpCode: '123456' }),
    403, 'FORBIDDEN'
  );
  assert.strictEqual(inv.failed_attempts, 0, 'baska servisin kartinin PIN sayaci oynamadi');
  assert.strictEqual(inv.status, 'IN_STOCK');
  assert.strictEqual(ctx.world.state.device_claim_otps.length, 0);
  assert.strictEqual(ctx.mailer.sent.length, 0, 'baska servis icin musteriye kod gitmedi');
  assert.strictEqual(ctx.world.state.homes.length, 0);
});

test('claim: servis kendi / kok stogundaki karti kurar -> ev + kart kendi kapsamina girer, uyelik SURESIZ; kok kurarsa ev kok kalir', async () => {
  const ctx = setup();
  const own = ctx.card('AHBU-S3-0001', ctx.svcA);
  const r = await ctx.claimFor(ctx.svcA, own);
  const { state } = ctx.world;
  const home = state.homes.find((x) => x.id === r.home_id);
  assert.strictEqual(home.service_owner_id, ctx.svcA.id);
  assert.strictEqual(own.service_owner_id, ctx.svcA.id);
  const m = state.home_users.find((x) => x.home_id === home.id && x.role === 'service_user');
  assert.strictEqual(m.user_id, ctx.svcA.id);
  assert.strictEqual(m.installer_expires_at, null);
  assert.strictEqual(r.technician_access_expires_at, undefined);
  assert.strictEqual(r.technician_access_unlimited, true);

  // kok stogundaki kart (NULL): servis kurabilir; kart evin servisine gecer
  const rootStock = ctx.card('AHBU-S3-0002', null);
  const r2 = await ctx.claimFor(ctx.svcB, rootStock, 'musteri2@example.test');
  assert.strictEqual(state.homes.find((x) => x.id === r2.home_id).service_owner_id, ctx.svcB.id);
  assert.strictEqual(rootStock.service_owner_id, ctx.svcB.id);

  // kok kurarsa: ev kok (NULL); kart evin servisini (NULL) izler
  const svcAStock = ctx.card('AHBU-S3-0003', ctx.svcA);
  const r3 = await ctx.claimFor(ctx.root, svcAStock, 'musteri3@example.test');
  assert.strictEqual(state.homes.find((x) => x.id === r3.home_id).service_owner_id || null, null);
  assert.strictEqual(svcAStock.service_owner_id, null);
  assert.ok(!state.home_users.some((x) => x.home_id === r3.home_id && x.role === 'service_user'), 'kok icin servis uyeligi acilmaz');
});

test('claim: musterinin baska servisin kapsamindaki bos evi devralinmaz (yeni ev); kendi kapsamindaki ya da sahipsiz bos ev yeniden kullanilir', async () => {
  const ctx = setup();
  const { h, world } = ctx;
  const homeB = h.addHome({ name: 'B nin bos evi', owner: ctx.customer });
  homeB.service_owner_id = ctx.svcB.id;
  const inv = ctx.card('AHBU-S3-0001', ctx.svcA);
  const r = await ctx.claimFor(ctx.svcA, inv);
  assert.notStrictEqual(r.home_id, homeB.id, 'B nin evi A tarafindan devralinmadi');
  assert.strictEqual(homeB.service_owner_id, ctx.svcB.id);
  assert.strictEqual(world.state.homes.find((x) => x.id === r.home_id).service_owner_id, ctx.svcA.id);

  // kendi kapsamindaki bos ev yeniden kullanilir
  const ctx2 = setup();
  const homeA = ctx2.h.addHome({ name: 'A nin bos evi', owner: ctx2.customer });
  homeA.service_owner_id = ctx2.svcA.id;
  const r2 = await ctx2.claimFor(ctx2.svcA, ctx2.card('AHBU-S3-0001', ctx2.svcA));
  assert.strictEqual(r2.home_id, homeA.id);
  // sahipsiz bos ev: servis sahiplenir -> servisin olur
  const ctx3 = setup();
  const homeN = ctx3.h.addHome({ name: 'Sahipsiz bos ev', owner: ctx3.customer });
  const r3 = await ctx3.claimFor(ctx3.svcA, ctx3.card('AHBU-S3-0001', ctx3.svcA));
  assert.strictEqual(r3.home_id, homeN.id);
  assert.strictEqual(homeN.service_owner_id, ctx3.svcA.id);
});

test('claim: musteri (user) kendi uygulamasindan servis kartini sahiplenirse ev ve kart KOK kapsamina duser (evin servisi yok)', async () => {
  const ctx = setup();
  const inv = ctx.card('AHBU-S3-0001', ctx.svcA);
  const r = await ctx.deviceService.claimDevice({ actor: ctx.act(ctx.customer), deviceUuid: inv.device_uuid, setupPin: PIN });
  assert.strictEqual(ctx.world.state.homes.find((x) => x.id === r.home_id).service_owner_id || null, null);
  assert.strictEqual(inv.service_owner_id, null, 'kart evin servisini (yok) izler');
});

async function installed(ctx, owner = null) {
  const { h } = ctx;
  const inv = ctx.card('AHBU-S3-0001', owner, { status: 'CLAIMED' });
  const home = h.addHome({ name: 'Daire', owner: ctx.customer });
  if (owner) home.service_owner_id = owner.id;
  const oldKeyEnc = ctx.secretBox.encrypt('EskiAnahtar123456');
  const dev = h.addDevice({ home, uuid: inv.device_uuid, mac: inv.mac_address, claimedBy: ctx.customer, online: false, local_key_enc: oldKeyEnc });
  h.addEndpoints(home, dev, 8);
  inv.claimed_home_id = home.id;
  inv.claimed_by_user_id = ctx.customer.id;
  inv.pin_hash = 'CLAIMED_BURNED_PIN';
  inv.local_key_enc = oldKeyEnc;
  return { inv, home, dev };
}

test('acil sifirlama: evin servisi BASKASIYSA uyelik olsa bile 403; evin servisi sureli uyeligi dolmus olsa da izinli (72 saat yok)', async () => {
  const ctx = setup();
  const { inv, home } = await installed(ctx, ctx.svcA);
  const reset = (who, extra = {}) => ctx.deviceService.emergencyReset({ actor: ctx.act(who), deviceUuid: inv.device_uuid, confirmUid: inv.device_uuid, reason: REASON, ...extra });
  // B: uyelik yok -> 403
  await expectHttp(reset(ctx.svcB), 403, 'FORBIDDEN');
  // B: (eski) gecerli uyelik var ama evin servisi A -> 403
  ctx.h.addMember(home, ctx.svcB, 'service_user', { installer_expires_at: new Date(ctx.world.clock.t + 3600000) });
  await expectHttp(reset(ctx.svcB), 403, 'FORBIDDEN');
  assert.strictEqual(inv.status, 'CLAIMED');
  assert.ok(ctx.world.state.home_users.some((m) => m.user_id === ctx.customer.id), 'hicbir uyelik silinmedi');
  // A: uyeligi hic yok / suresi coktan dolmus; yine de evin servisi -> izinli
  ctx.h.addMember(home, ctx.svcA, 'service_user', { installer_expires_at: new Date(ctx.world.clock.t - 5 * 86400000) });
  const out = await reset(ctx.svcA);
  assert.strictEqual(out.action, 'UNCLAIMED');
  assert.strictEqual(out.service_owner_id, ctx.svcA.id);
  assert.strictEqual(inv.service_owner_id, ctx.svcA.id, 'stoga donen kart ayni servisin stogunda');
  assert.strictEqual(home.service_owner_id, ctx.svcA.id);
});

test('acil sifirlama: sahipsiz (kok) evde eski kural (servis uyeligi) gecerli; devreden servis evin sahibi olur, kart onun stogunda', async () => {
  const ctx = setup();
  const { inv, home } = await installed(ctx, null);
  const newOwner = ctx.h.addUser({ email: 'yeni.sahip@example.test', full_name: 'Yeni Sahip' });
  const reset = (who, extra = {}) => ctx.deviceService.emergencyReset({ actor: ctx.act(who), deviceUuid: inv.device_uuid, confirmUid: inv.device_uuid, reason: REASON, ...extra });
  // uyeligi olmayan servis: 403 (sahipsiz ev servise kapali)
  await expectHttp(reset(ctx.svcA, { newOwnerIdentifier: newOwner.email }), 403, 'FORBIDDEN');
  ctx.h.addMember(home, ctx.svcA, 'service_user', { installer_expires_at: new Date(ctx.world.clock.t + 3600000) });
  const out = await reset(ctx.svcA, { newOwnerIdentifier: newOwner.email });
  assert.strictEqual(out.action, 'REASSIGNED');
  assert.strictEqual(out.service_owner_id, ctx.svcA.id);
  assert.strictEqual(home.service_owner_id, ctx.svcA.id, 'devreden servis evin sahibi');
  assert.strictEqual(inv.service_owner_id, ctx.svcA.id);
  const m = ctx.world.state.home_users.find((x) => x.home_id === home.id && x.user_id === ctx.svcA.id && x.role === 'service_user');
  assert.ok(m && m.installer_expires_at === null, 'suresiz uyelik');

  // kok devrederse evin servisi degismez (ve evin servisinin uyeligi silinen uyelikler arasindan geri acilir)
  const ctx2 = setup();
  const t2 = await installed(ctx2, ctx2.svcB);
  const no2 = ctx2.h.addUser({ email: 'yeni2@example.test' });
  const out2 = await ctx2.deviceService.emergencyReset({ actor: ctx2.act(ctx2.root), deviceUuid: t2.inv.device_uuid, confirmUid: t2.inv.device_uuid, reason: REASON, newOwnerIdentifier: no2.email });
  assert.strictEqual(out2.action, 'REASSIGNED');
  assert.strictEqual(t2.home.service_owner_id, ctx2.svcB.id, 'kok devri servis kapsamini degistirmez');
  assert.ok(ctx2.world.state.home_users.some((x) => x.home_id === t2.home.id && x.user_id === ctx2.svcB.id && x.role === 'service_user'), 'evin servisinin uyeligi korunur');
});

test('pano degisimi: baska servisin stogundaki yeni pano 403 (PIN sayaci oynamaz); kendi / kok kartini takar ve kart evin servisini izler; kok her karti', async () => {
  const ctx = setup();
  const { inv: oldInv, home } = await installed(ctx, ctx.svcA);
  const foreign = ctx.card('AHBU-S3-0002', ctx.svcB);
  const own = ctx.card('AHBU-S3-0003', ctx.svcA);
  const rootStock = ctx.card('AHBU-S3-0004', null);
  const replace = (actorUser, card, access) => ctx.deviceService.replaceBoard({
    actor: { ...ctx.act(actorUser), access }, homeId: home.id, oldDeviceUuid: oldInv.device_uuid, newDeviceUuid: card.device_uuid, setupPin: PIN, reason: 'Pano yandi',
  });
  await expectHttp(replace(ctx.svcA, foreign, 'service_user'), 403, 'FORBIDDEN');
  assert.strictEqual(foreign.failed_attempts, 0, 'baska servisin kartinin PIN sayaci oynamadi');
  assert.strictEqual(foreign.status, 'IN_STOCK');
  assert.strictEqual(oldInv.status, 'CLAIMED', 'eski pano devrede kaldi');
  await replace(ctx.svcA, own, 'service_user');
  assert.strictEqual(own.service_owner_id, ctx.svcA.id);
  assert.strictEqual(own.status, 'CLAIMED');
  // ev sahibi (user) baska servisin kartini takamaz; kok stogundaki karti takar -> kart evin servisinin (A) olur
  await expectHttp(replace(ctx.customer, foreign, 'owner'), 403, 'FORBIDDEN');
  assert.strictEqual(foreign.failed_attempts, 0);
  // kok her karti takabilir: kart evin servisine (A) gecer
  const c2 = setup();
  const t2 = await installed(c2, c2.svcA);
  const f2 = c2.card('AHBU-S3-0009', c2.svcB);
  await c2.deviceService.replaceBoard({
    actor: { ...c2.act(c2.root), access: 'super_user' }, homeId: t2.home.id, oldDeviceUuid: t2.inv.device_uuid, newDeviceUuid: f2.device_uuid, setupPin: PIN, reason: 'x',
  });
  assert.strictEqual(f2.service_owner_id, c2.svcA.id, 'kok B nin kartini A nin evine takti: kart evin servisini izler');
  assert.strictEqual(rootStock.service_owner_id, null, 'kok stogundaki kart dokunulmadi');
});
