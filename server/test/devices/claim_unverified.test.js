'use strict';

// uyelik-1 (claim / acil sifirlama yeni sahip) + bireysel-3 (yaniti kaybolan claim):
//  - personel claim'inde DOGRULANMAMIS mevcut musteri hesabi OTP dogrulandiktan sonra AYNI tx'te etkisizlestirilir
//    (parola, oturumlar, MQTT), hesap pending_invite olur ve COMMIT sonrasi davet gider; yanit customer_account
//    {created:false, status:'pending_invite', invite_sent, security_reset} + uyari.
//  - dogrulanmis aktif musteriye DOKUNULMAZ (customer_account alani YOK); mevcut pending_invite musteriye davet yeniden gider.
//  - acil sifirlama yeni sahip: telefonla verilen + gercek e-postali hesap 400; dogrulanmamis e-posta hedefi sifirlanir + davet.
//  - ayni sahibin yeniden claim'i 409 CONFLICT reason ALREADY_YOURS + data {home_id, home_name}.
// GERCEK auth_service (etkisizlestirme SQL'i sahte dunya DB'sinde) kullanilir: db.js require.cache uzerinden vekil.

const test = require('node:test');
const assert = require('node:assert');
const crypto = require('crypto');
const bcrypt = require('bcryptjs');

const { createWorld, createServices, setTestEnv, expectHttp } = require('./_world');
const { injectModule } = require('./_routes_env');

setTestEnv();
process.env.JWT_SECRET = process.env.JWT_SECRET || crypto.randomBytes(32).toString('hex');
process.env.BCRYPT_TEST_COST = '4';
let currentDb = null;
injectModule('db.js', {
  query: (t, p) => currentDb.query(t, p),
  withTransaction: (fn) => currentDb.withTransaction(fn),
  pool: { end: async () => {} },
});
const authService = require('../../src/services/auth_service');
authService.setPushService(null);

const PIN = '123456';
const UUID = 'AHBU-S3-0001';

function setup({ customer = {} } = {}) {
  setTestEnv();
  const world = createWorld();
  currentDb = world.db;
  const svc = createServices(world, { authService });
  authService.setMqttCredentialService(svc.credentials);
  const h = world.helpers;
  const tech = h.addUser({ email: 'teknisyen@example.test', role: 'service_user' });
  const cust = h.addUser({ email: 'musteri@example.test', ...customer });
  Object.assign(cust, { token_version: 1, ...customer });
  const inv = h.addInventory({ uuid: UUID, pin: PIN });
  const act = (u) => ({ userId: u.id, globalRole: u.role, ip: '10.0.0.9' });
  return { world, ...svc, h, tech, cust, inv, act };
}

async function staffClaim(ctx, target = ctx.cust.email) {
  await ctx.deviceService.requestClaimOtp({ actor: ctx.act(ctx.tech), deviceUuid: UUID, targetOwnerIdentifier: target });
  return ctx.deviceService.claimDevice({
    actor: ctx.act(ctx.tech), deviceUuid: UUID, setupPin: PIN, targetOwnerIdentifier: target, otpCode: ctx.mailer.lastCode(),
  });
}

test('uyelik-1: dogrulanmamis kayitli musteriyle claim -> hesap sifirlanir (parola, tv, oturumlar, MQTT), pending_invite, davet + uyari', async () => {
  const ctx = setup({ customer: { email_verified: false, account_status: 'active', password_hash: bcrypt.hashSync('Saldirgan-Parola-9', 4) } });
  const oldHash = ctx.cust.password_hash;
  ctx.world.state.refresh_tokens.push({ id: crypto.randomUUID(), user_id: ctx.cust.id, revoked_at: null });
  const otherHome = ctx.h.addHome({ name: 'Saldirgan Evi' });
  const cred = await ctx.credentials.issueUserCredential({ homeId: otherHome.id, userId: ctx.cust.id });

  const r = await staffClaim(ctx);
  const u = ctx.world.state.users.find((x) => x.id === ctx.cust.id);
  assert.notStrictEqual(u.password_hash, oldHash, 'parola degisti');
  assert.strictEqual(bcrypt.compareSync('Saldirgan-Parola-9', u.password_hash), false);
  assert.strictEqual(u.account_status, 'pending_invite');
  assert.strictEqual(u.token_version, 2, 'token_version artti');
  assert.ok(ctx.world.state.refresh_tokens.every((x) => x.user_id !== ctx.cust.id || x.revoked_at), 'refresh tokenlar iptal');
  assert.ok(!ctx.world.state.mqtt_credentials.some((c) => c.username === cred.username), 'uygulama MQTT kimligi silindi');
  assert.deepStrictEqual(r.customer_account, { created: false, status: 'pending_invite', invite_sent: true, security_reset: true });
  assert.deepStrictEqual(ctx.deviceService.invites.map((i) => i.userId), [ctx.cust.id], 'davet gonderildi');
  assert.ok(r.warnings.includes('Müşterinin doğrulanmamış mevcut hesabı güvenlik için sıfırlandı; şifre belirleme e-postası gönderildi.'));
  // musteri yine de evin sahibi
  assert.ok(ctx.world.state.home_users.some((m) => m.home_id === r.home_id && m.user_id === ctx.cust.id && m.role === 'owner'));
  const audit = ctx.world.state.device_audit_logs.find((a) => a.event === 'device_claimed');
  assert.strictEqual(audit.details.customer_account_reset, true);
});

test('uyelik-1: davet gonderilemezse mevcut "Sifremi unuttum" uyarisi', async () => {
  const ctx = setup({ customer: { email_verified: false, account_status: 'active' } });
  ctx.deviceService._deps.inviteCustomer = async () => ({ sent: false });
  const r = await staffClaim(ctx);
  assert.deepStrictEqual(r.customer_account, { created: false, status: 'pending_invite', invite_sent: false, security_reset: true });
  assert.ok(r.warnings.some((w) => w.includes('Şifremi unuttum')));
});

test('uyelik-1: email_verified=TRUE aktif musteriye DOKUNULMAZ (customer_account yok, davet yok)', async () => {
  const ctx = setup({ customer: { email_verified: true, account_status: 'active', password_hash: 'mevcut-ozet' } });
  const r = await staffClaim(ctx);
  const u = ctx.world.state.users.find((x) => x.id === ctx.cust.id);
  assert.strictEqual(u.password_hash, 'mevcut-ozet');
  assert.strictEqual(u.account_status, 'active');
  assert.strictEqual(u.token_version, 1);
  assert.strictEqual(r.customer_account, undefined);
  assert.strictEqual(r.warnings, undefined);
  assert.deepStrictEqual(ctx.deviceService.invites, []);
});

test('uyelik-1: mevcut pending_invite musteriye davet YENIDEN gider (security_reset:false)', async () => {
  const ctx = setup({ customer: { email_verified: false, account_status: 'pending_invite' } });
  const r = await staffClaim(ctx);
  assert.deepStrictEqual(r.customer_account, { created: false, status: 'pending_invite', invite_sent: true, security_reset: false });
  assert.deepStrictEqual(ctx.deviceService.invites.map((i) => i.userId), [ctx.cust.id]);
  assert.ok(!(r.warnings || []).some((w) => w.includes('güvenlik için sıfırlandı')));
});

test('uyelik-1: yeni musteri hesabi -> customer_account security_reset:false ile', async () => {
  const ctx = setup();
  const r = await staffClaim(ctx, 'yepyeni@example.test');
  assert.deepStrictEqual(r.customer_account, { created: true, status: 'pending_invite', invite_sent: true, security_reset: false });
});

test('uyelik-1: yanlis OTP de hesap SIFIRLANMAZ (once OTP dogrulanir)', async () => {
  const ctx = setup({ customer: { email_verified: false, account_status: 'active', password_hash: 'eski-ozet' } });
  await ctx.deviceService.requestClaimOtp({ actor: ctx.act(ctx.tech), deviceUuid: UUID, targetOwnerIdentifier: ctx.cust.email });
  const wrong = String((Number(ctx.mailer.lastCode()) + 1) % 1000000).padStart(6, '0');
  await expectHttp(
    ctx.deviceService.claimDevice({ actor: ctx.act(ctx.tech), deviceUuid: UUID, setupPin: PIN, targetOwnerIdentifier: ctx.cust.email, otpCode: wrong }),
    400,
    'VALIDATION'
  );
  const u = ctx.world.state.users.find((x) => x.id === ctx.cust.id);
  assert.strictEqual(u.password_hash, 'eski-ozet');
  assert.strictEqual(u.account_status, 'active');
});

// ---------------------------------------------------------------- bireysel-3
test('bireysel-3: ayni sahibin yeniden claim i -> 409 CONFLICT reason ALREADY_YOURS + data {home_id, home_name}; yeni kimlik URETILMEZ', async () => {
  const ctx = setup();
  const owner = ctx.h.addUser({ email: 'kendi@example.test' });
  const first = await ctx.deviceService.claimDevice({ actor: ctx.act(owner), deviceUuid: UUID, setupPin: PIN, homeName: 'Kendi Evim' });
  const credsBefore = ctx.world.state.mqtt_credentials.map((c) => c.username);
  const err = await expectHttp(
    ctx.deviceService.claimDevice({ actor: ctx.act(owner), deviceUuid: UUID, setupPin: PIN }),
    409,
    'CONFLICT'
  );
  assert.strictEqual(err.message, 'Bu cihaz zaten sizin dairenize tanımlı.');
  assert.strictEqual(err.extra.reason, 'ALREADY_YOURS');
  assert.deepStrictEqual(err.extra.data, { home_id: first.home_id, home_name: 'Kendi Evim' });
  assert.deepStrictEqual(ctx.world.state.mqtt_credentials.map((c) => c.username), credsBefore, 'yeni kimlik yok');
  assert.strictEqual(ctx.inv.failed_attempts, 0, 'PIN sayacina dokunulmaz');
});

test('bireysel-3: baska kullanicinin claim i -> reason SIZ 409 (ev bilgisi sizmaz)', async () => {
  const ctx = setup();
  const owner = ctx.h.addUser({ email: 'sahip.bir@example.test' });
  const other = ctx.h.addUser({ email: 'baska.biri@example.test' });
  await ctx.deviceService.claimDevice({ actor: ctx.act(owner), deviceUuid: UUID, setupPin: PIN, homeName: 'Gizli Ev' });
  const err = await expectHttp(ctx.deviceService.claimDevice({ actor: ctx.act(other), deviceUuid: UUID, setupPin: PIN }), 409, 'CONFLICT');
  assert.ok(!err.extra || err.extra.reason === undefined, 'reason yok');
  assert.ok(!JSON.stringify(err.extra || {}).includes('Gizli Ev'));
  assert.ok(!err.message.includes('Gizli Ev'));
});

// ---------------------------------------------------------------- acil sifirlama yeni sahip
function resetSetup(newOwnerFields) {
  const ctx = setup();
  const oldOwner = ctx.h.addUser({ email: 'eski.sahip@example.test' });
  const home = ctx.h.addHome({ name: 'Devredilecek Ev', owner: oldOwner });
  ctx.h.addMember(home, ctx.tech, 'service_user');
  const dev = ctx.h.addDevice({ home, uuid: UUID, claimedBy: oldOwner });
  ctx.inv.status = 'CLAIMED';
  ctx.inv.claimed_home_id = home.id;
  const target = ctx.h.addUser({ email: 'yeni.sahip@example.test', phone: '+905556667788', ...newOwnerFields });
  Object.assign(target, newOwnerFields);
  const reset = (identifier) => ctx.deviceService.emergencyReset({
    actor: ctx.act(ctx.tech), deviceUuid: UUID, confirmUid: UUID, reason: 'Kiraci tasindi, yeni sahip atanmali.', newOwnerIdentifier: identifier,
  });
  return { ctx, home, dev, target, reset };
}

test('uyelik-1: acil sifirlama - telefonla verilen ve gercek e-postali hesaba denk gelen yeni sahip 400 VALIDATION', async () => {
  const { ctx, home, target, reset } = resetSetup({ email_verified: true });
  const err = await expectHttp(reset(target.phone), 400, 'VALIDATION');
  assert.strictEqual(err.message, 'Bu numara e-postalı bir hesaba kayıtlı; atama için hesabın e-posta adresini girin.');
  assert.ok(ctx.world.state.home_users.some((m) => m.home_id === home.id && m.role === 'owner'), 'hicbir sey degismedi');
});

test('uyelik-1: acil sifirlama - yer tutucu e-postali (telefon-OTP) hesap telefonla atanabilir', async () => {
  const { ctx, home, reset } = resetSetup({ email_verified: false });
  const phoneUser = ctx.h.addUser({ email: 'phone_905551110000@ahbu.local', phone: '+905551110000' });
  // telefon-OTP ile acilmis hesabin e-postasi dogrulanmamistir: yine de SIFIRLANMAZ (yalniz e-postayla bulunan hedef)
  Object.assign(phoneUser, { email_verified: false, password_hash: 'kendi-ozeti', token_version: 1 });
  const r = await reset('+905551110000');
  assert.strictEqual(r.action, 'REASSIGNED');
  assert.ok(ctx.world.state.home_users.some((m) => m.home_id === home.id && m.user_id === phoneUser.id && m.role === 'owner'));
  const u = ctx.world.state.users.find((x) => x.id === phoneUser.id);
  assert.strictEqual(u.password_hash, 'kendi-ozeti', 'parola korunur');
  assert.strictEqual(u.account_status, 'active');
  assert.ok(!(r.warnings || []).some((w) => w.includes('güvenlik için sıfırlandı')));
});

test('uyelik-1: acil sifirlama - dogrulanmamis e-posta hedefi sifirlanir, davet gider ve uyari doner', async () => {
  const { ctx, target, reset } = resetSetup({ email_verified: false, account_status: 'active', password_hash: 'saldirgan-ozet' });
  const r = await reset(target.email);
  assert.strictEqual(r.action, 'REASSIGNED');
  const u = ctx.world.state.users.find((x) => x.id === target.id);
  assert.notStrictEqual(u.password_hash, 'saldirgan-ozet');
  assert.strictEqual(u.account_status, 'pending_invite');
  assert.deepStrictEqual(ctx.deviceService.invites.map((i) => i.userId), [target.id]);
  assert.ok(r.warnings.some((w) => w.includes('doğrulanmamış mevcut hesabı güvenlik için sıfırlandı')));
});

test('uyelik-1: acil sifirlama - dogrulanmis e-posta hedefi aynen (sifirlama/davet yok)', async () => {
  const { ctx, target, reset } = resetSetup({ email_verified: true, password_hash: 'mesru-ozet' });
  const r = await reset(target.email);
  assert.strictEqual(r.action, 'REASSIGNED');
  assert.strictEqual(ctx.world.state.users.find((x) => x.id === target.id).password_hash, 'mesru-ozet');
  assert.deepStrictEqual(ctx.deviceService.invites, []);
  assert.ok(!(r.warnings || []).some((w) => w.includes('güvenlik için sıfırlandı')));
});
