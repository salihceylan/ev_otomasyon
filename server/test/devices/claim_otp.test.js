'use strict';

// B4 / B11: requestClaimOtp - yalnizca staff/super, bekleme + sayac korumasi, gonderim hatasi yuzeye cikar

const test = require('node:test');
const assert = require('node:assert');

const { createWorld, createServices, setTestEnv, expectHttp, fakePin } = require('./_world');

const UUID = 'AHBU-S3-0001';

function setup(inventory = {}) {
  setTestEnv();
  const world = createWorld();
  const svc = createServices(world);
  const tech = world.helpers.addUser({ email: 'teknisyen@example.test', role: 'service_user' });
  const customer = world.helpers.addUser({ email: 'musteri@example.test', phone: '+905551112233' });
  const inv = world.helpers.addInventory({ uuid: UUID, pin: '123456', ...inventory });
  const act = (u) => ({ userId: u.id, globalRole: u.role, ip: '10.1.2.3' });
  const req = (target = customer.email, uuid = UUID, who = tech) =>
    svc.deviceService.requestClaimOtp({ actor: act(who), deviceUuid: uuid, targetOwnerIdentifier: target });
  return { world, ...svc, tech, customer, inv, act, req };
}

test('yalnizca staff/super: normal kullanici, servis oturumu ve aktorsuz cagri reddedilir (DB\'ye dokunmadan)', async () => {
  const ctx = setup();
  const user = ctx.world.helpers.addUser({ email: 'sakin@example.test' });
  await expectHttp(ctx.req(ctx.customer.email, UUID, user), 403, 'FORBIDDEN');
  await expectHttp(
    ctx.deviceService.requestClaimOtp({ actor: { userId: null, globalRole: 'service_session' }, deviceUuid: UUID, targetOwnerIdentifier: ctx.customer.email }),
    403, 'FORBIDDEN'
  );
  await expectHttp(ctx.deviceService.requestClaimOtp({ actor: null, deviceUuid: UUID, targetOwnerIdentifier: 'a@b.co' }), 403, 'FORBIDDEN');
  assert.strictEqual(ctx.world.db.log.length, 0);
  assert.strictEqual(ctx.mailer.sent.length, 0);

  const root = ctx.world.helpers.addUser({ email: 'root@example.test', role: 'super_user' });
  const ok = await ctx.req(ctx.customer.email, UUID, root);
  assert.strictEqual(ok.resend_after, 60);
});

test('basarili istek: kod yalnizca musteri e-postasina gider, yanitta ve DB\'de DUZ METIN yok', async () => {
  const ctx = setup();
  const r = await ctx.req();
  const code = ctx.mailer.lastCode();
  assert.match(code, /^\d{6}$/);
  assert.strictEqual(ctx.mailer.sent[0].to, ctx.customer.email);
  assert.strictEqual(ctx.mailer.sent[0].deviceUuid, UUID);

  assert.strictEqual(r.expires_in, 900);
  assert.strictEqual(r.resend_after, 60);
  assert.ok(!('debug_code' in r), 'debug_code yalnizca ALLOW_DEBUG_OTP ile');
  assert.ok(!JSON.stringify(r).includes(code), 'kod yanitta olmamali');
  assert.ok(!r.message.includes(ctx.customer.email), 'e-posta maskelenmeli');
  assert.match(r.message, /m\*\*\*@e\*\*\*\.test/);

  const row = ctx.world.state.device_claim_otps[0];
  assert.match(row.otp_hash, /^h1\$/);
  assert.ok(!row.otp_hash.includes(code), 'ozet duz metin kodu icermemeli');
  assert.strictEqual(row.attempts, 0);
  assert.strictEqual(row.requested_by, ctx.tech.id);
  assert.strictEqual(new Date(row.expires_at).getTime() - ctx.world.clock.t, 900 * 1000);

  // denetim kaydi (IP dahil)
  const audit = ctx.world.state.device_audit_logs[0];
  assert.strictEqual(audit.event, 'claim_otp_requested');
  assert.strictEqual(audit.ip_address, '10.1.2.3');
  assert.ok(!JSON.stringify(audit).includes(code));
});

test('calisma zamani DDL YOK (CREATE TABLE koddan kalkti)', async () => {
  const ctx = setup();
  await ctx.req();
  assert.ok(ctx.world.db.sqls().every((s) => !/CREATE\s+(TABLE|INDEX)/i.test(s)));
});

test('cihaz durumu: envanterde yok 404, CLAIMED 409, SUSPENDED/REVOKED 403 - mail gitmez', async () => {
  const ctx = setup();
  await expectHttp(ctx.req(ctx.customer.email, 'AHBU-YOK-1'), 404, 'NOT_FOUND');
  for (const [status, httpStatus] of [['CLAIMED', 409], ['SUSPENDED', 403], ['REVOKED', 403]]) {
    const c = setup({ status });
    await expectHttp(c.req(), httpStatus, null);
    assert.strictEqual(c.mailer.sent.length, 0);
  }
});

test('gecersiz girdi: uuid / hedef bicimi 400', async () => {
  const ctx = setup();
  await expectHttp(ctx.req(ctx.customer.email, 'bozuk'), 400, 'VALIDATION');
  await expectHttp(ctx.req('bu-bir-eposta-degil'), 400, 'VALIDATION');
  await expectHttp(ctx.req(''), 400, 'VALIDATION');
  await expectHttp(
    ctx.deviceService.requestClaimOtp({ actor: ctx.act(ctx.tech), deviceUuid: UUID, targetOwnerIdentifier: undefined }),
    400, 'VALIDATION'
  );
  assert.strictEqual(ctx.mailer.sent.length, 0);
});

test('servis personeli kendi e-postasina/hesabina kod isteyemez (403)', async () => {
  const ctx = setup();
  await expectHttp(ctx.req(ctx.tech.email), 403, 'FORBIDDEN');
  await expectHttp(ctx.req(ctx.tech.email.toUpperCase()), 403, 'FORBIDDEN');
  assert.strictEqual(ctx.mailer.sent.length, 0);
});

test('yeniden istek: 60 sn bekleme (429 + retry_after); sure dolunca yeni kod, eskisi gecersiz olur', async () => {
  const ctx = setup();
  await ctx.req();
  const first = ctx.mailer.lastCode();
  const e = await expectHttp(ctx.req(), 429, 'RATE_LIMITED');
  assert.ok(e.extra.retry_after >= 1 && e.extra.retry_after <= 60, `retry_after=${e.extra.retry_after}`);
  assert.strictEqual(ctx.mailer.sent.length, 1, 'bekleme suresinde ikinci mail gitmemeli');

  ctx.world.clock.advance(61 * 1000);
  await ctx.req();
  assert.strictEqual(ctx.mailer.sent.length, 2);
  assert.strictEqual(ctx.world.state.device_claim_otps.length, 1, '(cihaz, hedef) basina tek satir');
  const second = ctx.mailer.lastCode();
  // satirdaki ozet yenisine ait
  assert.strictEqual(ctx.world.state.device_claim_otps[0].otp_hash, fakePin.hashPin(second));
  if (first !== second) assert.notStrictEqual(ctx.world.state.device_claim_otps[0].otp_hash, fakePin.hashPin(first));
});

test('YENIDEN ISTEK DENEME SAYACINI SIFIRLAMAZ (15 dk pencere); pencere dolunca sifirlanir', async () => {
  const ctx = setup();
  await ctx.req();
  const row = ctx.world.state.device_claim_otps[0];
  row.attempts = 3; // 3 hatali deneme yapilmis

  ctx.world.clock.advance(61 * 1000);
  await ctx.req();
  assert.strictEqual(row.attempts, 3, 'yeni kod istemek sayaci sifirlayip kaba kuvvete yol acmamali');

  ctx.world.clock.advance(15 * 60 * 1000);
  await ctx.req();
  assert.strictEqual(row.attempts, 0, 'pencere dolunca sayac yenilenir');
});

test('5 hatali deneme sonrasi yeni kod ISTENEMEZ (429) ve mail gitmez', async () => {
  const ctx = setup();
  await ctx.req();
  ctx.world.state.device_claim_otps[0].attempts = 5;
  ctx.world.clock.advance(61 * 1000);
  const before = ctx.mailer.sent.length;
  const e = await expectHttp(ctx.req(), 429, 'RATE_LIMITED');
  assert.ok(e.extra.retry_after > 0);
  assert.strictEqual(ctx.mailer.sent.length, before);
});

test('E-POSTA GONDERIM HATASI YUZEYE CIKAR (502) ve teslim edilmeyen kod gecersiz kilinir', async () => {
  const ctx = setup();
  ctx.mailer.failWith = { sent: false, reason: 'SMTP_NOT_CONFIGURED', error: 'E-posta servisi yapilandirilmamis.' };
  const e = await expectHttp(ctx.req(), 502, 'MAIL_UNAVAILABLE');
  assert.match(e.message, /gönderilemedi/);
  const row = ctx.world.state.device_claim_otps[0];
  assert.ok(new Date(row.expires_at).getTime() <= ctx.world.clock.t, 'teslim edilmeyen kod gecersiz');

  // bekleme kaldirildi: mail duzelince hemen tekrar denenebilir; sayac korunur
  ctx.mailer.failWith = null;
  const ok = await ctx.req();
  assert.strictEqual(ok.resend_after, 60);
  assert.strictEqual(ctx.mailer.sent.length, 1);
});

test('mailer istisna firlatirsa da 502; gecersiz alici 400', async () => {
  const ctx = setup();
  ctx.mailer.failWith = new Error('SMTP baglanti hatasi: gizli-ayrinti');
  const e = await expectHttp(ctx.req(), 502, 'MAIL_UNAVAILABLE');
  assert.ok(!/gizli-ayrinti/.test(e.message), 'ic hata mesaji sizmamali');

  const ctx2 = setup();
  ctx2.mailer.failWith = { sent: false, reason: 'INVALID_RECIPIENT' };
  await expectHttp(ctx2.req(), 400, 'VALIDATION');
});

test('debug kodu yalnizca ALLOW_DEBUG_OTP=true ve uretim disinda doner', async () => {
  // gelistirme: mail gitmese bile devam eder ve kodu doner
  const ctx = setup();
  process.env.ALLOW_DEBUG_OTP = 'true';
  process.env.NODE_ENV = 'development';
  ctx.mailer.failWith = { sent: false, reason: 'SMTP_NOT_CONFIGURED' };
  const dev = await ctx.req();
  assert.match(dev.debug_code, /^\d{6}$/);

  // uretim: bayrak YOK SAYILIR
  const ctx2 = setup();
  process.env.ALLOW_DEBUG_OTP = 'true';
  process.env.NODE_ENV = 'production';
  ctx2.mailer.failWith = { sent: false, reason: 'SMTP_NOT_CONFIGURED' };
  await expectHttp(ctx2.req(), 502, 'MAIL_UNAVAILABLE');
  const ctx3 = setup();
  process.env.ALLOW_DEBUG_OTP = 'true';
  process.env.NODE_ENV = 'production';
  const prod = await ctx3.req();
  assert.ok(!('debug_code' in prod));

  // bayrak yoksa gelistirmede de donmez
  const ctx4 = setup();
  process.env.NODE_ENV = 'development';
  const none = await ctx4.req();
  assert.ok(!('debug_code' in none));
  process.env.NODE_ENV = 'test';
});

test('telefonla hedef: hesabin e-postasina gider; kayitsiz telefon 400', async () => {
  const ctx = setup();
  await ctx.req('+90 (555) 111 22 33');
  assert.strictEqual(ctx.mailer.sent[0].to, ctx.customer.email);
  await expectHttp(ctx.req('+905550000000'), 400, 'VALIDATION');
});

test('hedefin e-postasi buyuk/kucuk harf duyarsiz tek satira indirgenir', async () => {
  const ctx = setup();
  await ctx.req('Musteri@Example.TEST');
  ctx.world.clock.advance(61 * 1000);
  await ctx.req('musteri@example.test');
  assert.strictEqual(ctx.world.state.device_claim_otps.length, 1);
  assert.strictEqual(ctx.world.state.device_claim_otps[0].target_identifier, 'musteri@example.test');
});
