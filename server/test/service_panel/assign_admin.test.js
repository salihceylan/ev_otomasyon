'use strict';

// WP-B2 / gorev 2: Home Admin atama
//   POST /api/v1/service/subscribers/:homeId/assign-admin/request-otp   (mevcut sahibe OTP)
//   POST /api/v1/service/subscribers/:homeId/assign-admin                (atama)
// Kapsam: rol/ev matrisi, sahibin OTP RIZASI (hedefe bagli, sayac, sure), ATOMIKLIK (gercek transaction + geri alma),
// eski sahibin erisiminin kesilmesi, sahip yok / zorla (super) modlari, hedef kisitlari, es zamanlilik, hiz siniri.

const test = require('node:test');
const assert = require('node:assert/strict');
const { createEnv, createClock, uid } = require('./_world');
const { createFakeFetch, silentLogger } = require('../devices/_world');

const clock = createClock();
const env = createEnv({ clock });
const { h, state, api, tokenOf } = env;
const { ServicePanelService, constants: C } = env.SRC('services/service_panel_service');
const { MqttCredentialService } = env.SRC('services/mqtt_credential_service');
const auth = env.SRC('middlewares/auth_middleware');
const pin = env.SRC('utils/pin');

let n = 0;
const SUB = '/api/v1/service/subscribers';
const actorOf = (u, extra = {}) => ({ userId: u.id, globalRole: u.role, ip: '203.0.113.7', ...extra });
const dbOf = () => ({ query: (t, p) => env.world.db.query(t, p), withTransaction: (fn) => env.world.db.withTransaction(fn) });

/** Servis ornegi: gercek servis + gercek MQTT kimlik servisi (sahte EMQX) + kayit tutan sahte temizlik. */
function makeSvc({ mqtt, emqx = true } = {}) {
  const fetchFn = createFakeFetch();
  const realMqtt =
    mqtt ||
    new MqttCredentialService({
      db: dbOf(),
      env: emqx ? { EMQX_API_URL: 'http://emqx.test.invalid:18083', EMQX_API_KEY: 'k', EMQX_API_SECRET: 's', MQTT_PUBLIC_HOST: 'b', MQTT_PUBLIC_PORT: '8884' } : {},
      fetch: fetchFn,
      logger: silentLogger,
      now: () => clock.now(),
    });
  const cleanupCalls = [];
  const cleanup = {
    cleanupHome: async (tx, homeId, options) => {
      cleanupCalls.push({ homeId, options, inTx: Boolean(tx && typeof tx.query === 'function') });
      await tx.query('DELETE FROM home_invitations WHERE home_id = $1', [homeId]);
      await tx.query('DELETE FROM scheduled_rules WHERE home_id = $1', [homeId]);
      await tx.query("UPDATE home_transfers SET status = 'CANCELLED' WHERE home_id = $1 AND status = 'PENDING'", [homeId]);
      return { cleaned: {}, skipped: [] };
    },
  };
  const svc = new ServicePanelService({ now: () => clock.now(), mqtt: realMqtt, cleanup });
  return { svc, fetchFn, cleanupCalls, mqtt: realMqtt };
}

/** Eski sahip + aile + staff + cihaz + MQTT kimlikleri + servis oturumu + davet + kural + bekleyen devir. */
function scenario({ ownerEmail } = {}) {
  const i = ++n;
  const owner = h.user({ full_name: 'Eski Sahip', email: ownerEmail || `owner${i}@example.test` });
  const resident = h.user({ full_name: 'Aile Üyesi' });
  const staff = h.user({ role: 'service_user', full_name: 'Servis Personeli' });
  const home = h.home({ name: `Ev ${i}`, owner });
  h.member(home, resident, 'resident');
  h.member(home, staff, 'service_user', { installer_expires_at: new Date(clock.now().getTime() + 72 * 3600e3) });
  const dev = h.device(home, { online: true });
  const inv = h.inventory({ uuid: dev.device_uuid, status: 'CLAIMED', claimed_home_id: home.id });
  inv.claimed_by_user_id = owner.id;
  dev.claimed_by = owner.id;
  const credOwner = h.appCredential(home, owner);
  const credResident = h.appCredential(home, resident);
  const { token, session } = h.serviceSession(home, { ownerId: owner.id });
  state.home_invitations.push({ id: uid(), home_id: home.id, created_by: owner.id, is_used: false, code_hash: `inv${i}` });
  state.scheduled_rules.push({ id: i, home_id: home.id, created_by: owner.id });
  state.home_transfers.push({ id: uid(), home_id: home.id, from_user_id: owner.id, target_identifier: 'baska@example.test', status: 'PENDING', code_hash: `tr${i}` });
  return { owner, resident, staff, home, dev, inv, credOwner, credResident, token, session };
}

const target = (extra = {}) => ({ fullName: 'Yeni Sahip', email: `yeni${++n}@example.test`, ...extra });
const ownersOf = (homeId) => state.home_users.filter((m) => m.home_id === homeId && m.role === 'owner').map((m) => m.user_id);
const rolesOf = (homeId) => state.home_users.filter((m) => m.home_id === homeId).map((m) => `${m.user_id}:${m.role}`).sort();

async function accessOf(user, home, roles = ['owner', 'resident', 'guest', 'service_user', 'super_user']) {
  const req = { user: { id: user.id, role: user.role, is_service_session: false }, params: { homeId: home.id }, body: {}, query: {} };
  let status = null;
  let called = false;
  const res = { status(c) { status = c; return this; }, json() { return this; } };
  await auth.requireHomeAccess(roles)(req, res, () => { called = true; });
  return called ? 200 : status;
}

async function requestOtp(svc, t, tg) {
  return svc.requestAssignAdminOtp({ actor: actorOf(t.staff), homeId: t.home.id, target: tg });
}

const rejects = async (promise, status, code, extra = {}) => {
  let caught = null;
  try {
    await promise;
  } catch (e) {
    caught = e;
  }
  assert.ok(caught, `HTTP ${status} ${code} bekleniyordu ama basarili oldu`);
  assert.equal(caught.status, status, `durum ${caught.status}: ${caught.message}`);
  if (code) assert.equal(caught.code, code, `kod ${caught.code}`);
  for (const [k, v] of Object.entries(extra)) assert.equal(caught.extra && caught.extra[k], v, `extra.${k}`);
  return caught;
};

// ================================================================================================
// OTP isteme
// ================================================================================================
test('request-otp: sahibe onay kodu e-postayla gider; kod hedef kişiye bağlı, özetli saklanır, yanıtta ve DB\'de düz metin YOK', async () => {
  const { svc } = makeSvc();
  const t = scenario();
  const tg = target({ fullName: 'Zeynep Hedef' });
  const r = await requestOtp(svc, t, tg);
  assert.equal(r.otp_required, true);
  assert.equal(r.expires_in, C.OTP_TTL_SECONDS);
  assert.equal(r.resend_after, C.OTP_RESEND_COOLDOWN_SECONDS);
  assert.match(r.owner_hint, /^o\*\*\*@e\*\*\*\.test$/);
  assert.ok(!('debug_code' in r), 'üretimde/test ortamında kod yanıtta dönmez');

  const mail = env.mailsTo(t.owner.email).pop();
  assert.ok(mail, 'sahibe e-posta gitti');
  const code = env.lastOtp(t.owner.email);
  assert.match(code, /^\d{6}$/);
  assert.ok(mail.text.includes('Zeynep Hedef'), 'sahip kimin için onay verdiğini görür');
  assert.ok(mail.text.includes(t.home.name));
  assert.ok(!JSON.stringify(r).includes(code));

  const row = state.home_admin_assign_otps.find((o) => o.home_id === t.home.id);
  assert.equal(row.target_identifier, tg.email);
  assert.equal(row.owner_user_id, t.owner.id);
  assert.equal(row.requested_by, t.staff.id);
  assert.ok(row.otp_hash.startsWith('h1$'), 'HMAC özeti');
  assert.ok(pin.verifyPin(code, row.otp_hash));
  assert.ok(!JSON.stringify(row).includes(code));
  assert.equal(row.attempts, 0);
  assert.ok(new Date(row.expires_at).getTime() - clock.now().getTime() <= C.OTP_TTL_SECONDS * 1000);
  // denetim kaydı (kod yok)
  const audit = state.device_audit_logs.find((a) => a.event === 'home_admin_otp_requested' && a.home_id === t.home.id);
  assert.ok(audit);
  assert.equal(audit.actor_user_id, t.staff.id);
  assert.ok(!JSON.stringify(audit).includes(code));
});

test('request-otp: sahip yoksa kod gerekmez (otp_required=false), e-posta/OTP satırı oluşmaz', async () => {
  const { svc } = makeSvc();
  const staff = h.user({ role: 'service_user' });
  const home = h.home({ name: 'Sahipsiz' });
  h.member(home, staff, 'service_user');
  const before = env.mails.length;
  const r = await svc.requestAssignAdminOtp({ actor: actorOf(staff), homeId: home.id, target: target() });
  assert.equal(r.otp_required, false);
  assert.equal(env.mails.length, before);
  assert.equal(state.home_admin_assign_otps.filter((o) => o.home_id === home.id).length, 0);
});

test('request-otp: birden fazla sahip -> 409 MULTIPLE_OWNERS; yer tutucu e-postalı sahip -> 409 OWNER_UNREACHABLE (e-posta gitmez)', async () => {
  const { svc } = makeSvc();
  const t = scenario();
  const second = h.user();
  h.member(t.home, second, 'owner');
  await rejects(requestOtp(svc, t, target()), 409, 'MULTIPLE_OWNERS');

  const u = scenario({ ownerEmail: `phone_90555${++n}@ahbu.local` });
  const before = env.mails.length;
  await rejects(requestOtp(svc, u, target()), 409, 'OWNER_UNREACHABLE');
  assert.equal(env.mails.length, before);
  assert.equal(state.home_admin_assign_otps.filter((o) => o.home_id === u.home.id).length, 0);
});

test('request-otp: e-posta gönderilemezse 503 DELIVERY_FAILED; kod geçersiz kılınır ve bekleme kalkar (hemen yeniden denenebilir)', async () => {
  const { svc } = makeSvc();
  const t = scenario();
  env.mailControl.fail = true;
  try {
    const err = await rejects(requestOtp(svc, t, target()), 503, 'DELIVERY_FAILED');
    assert.equal(err.expose, true);
  } finally {
    env.mailControl.fail = false;
  }
  const row = state.home_admin_assign_otps.find((o) => o.home_id === t.home.id);
  assert.ok(new Date(row.expires_at).getTime() <= clock.now().getTime(), 'teslim edilmeyen kod süresi dolmuş sayılır');
  // bekleme (60 sn) beklenmeden yeniden istek mümkün
  const again = await requestOtp(svc, t, target());
  assert.equal(again.otp_required, true);
});

test('request-otp: 60 sn bekleme (429, Retry-After/resend_after); süre dolunca yeni kod; deneme sayacı 15 dk pencerede KORUNUR', async () => {
  const { svc } = makeSvc();
  const t = scenario();
  const tg = target();
  await requestOtp(svc, t, tg);
  const code1 = env.lastOtp(t.owner.email);
  const blocked = await rejects(requestOtp(svc, t, tg), 429, 'RATE_LIMITED');
  assert.ok(blocked.retryAfter >= 1 && blocked.retryAfter <= C.OTP_RESEND_COOLDOWN_SECONDS);
  assert.equal(blocked.extra.resend_after, blocked.retryAfter);

  // iki yanlış deneme, sonra yeniden istek: sayaç sıfırlanmaz
  const wrong = code1 === '123456' ? '654321' : '123456';
  for (let i = 0; i < 2; i++) {
    await rejects(svc.assignAdmin({ actor: actorOf(t.staff), homeId: t.home.id, target: tg, otpCode: wrong }), 400, 'VALIDATION');
  }
  clock.advance((C.OTP_RESEND_COOLDOWN_SECONDS + 1) * 1000);
  await requestOtp(svc, t, tg);
  const row = state.home_admin_assign_otps.find((o) => o.home_id === t.home.id);
  assert.equal(row.attempts, 2, 'yeniden istek deneme sayacını sıfırlamaz');
  const code2 = env.lastOtp(t.owner.email);
  assert.ok(pin.verifyPin(code2, row.otp_hash), 'yeni kod geçerli tek kod');
  // pencere (15 dk) dolunca sayaç sıfırlanır
  clock.advance((C.OTP_ATTEMPT_WINDOW_MINUTES * 60 + 5) * 1000);
  await requestOtp(svc, t, tg);
  assert.equal(state.home_admin_assign_otps.find((o) => o.home_id === t.home.id).attempts, 0);
});

test('request-otp: sayaç sınırdayken yeni kod GÖNDERİLMEZ (429)', async () => {
  const { svc } = makeSvc();
  const t = scenario();
  const tg = target();
  await requestOtp(svc, t, tg);
  const row = state.home_admin_assign_otps.find((o) => o.home_id === t.home.id);
  row.attempts = C.OTP_MAX_ATTEMPTS;
  clock.advance((C.OTP_RESEND_COOLDOWN_SECONDS + 1) * 1000);
  const before = env.mails.length;
  await rejects(requestOtp(svc, t, tg), 429, 'RATE_LIMITED');
  assert.equal(env.mails.length, before);
});

test('girdi doğrulama: ad, e-posta/telefon; hedef kısıtları (kendini atayamaz, servis/süper hesabı, pasif hesap, telefonla yeni hesap yok)', async () => {
  const { svc } = makeSvc();
  const t = scenario();
  const sup = h.user({ role: 'super_user' });
  const base = { actor: actorOf(t.staff), homeId: t.home.id };
  await rejects(svc.requestAssignAdminOtp({ ...base, target: { fullName: 'X', email: 'a@example.test' } }), 400, 'VALIDATION');
  await rejects(svc.requestAssignAdminOtp({ ...base, target: { fullName: 'Geçerli Ad' } }), 400, 'VALIDATION');
  await rejects(svc.requestAssignAdminOtp({ ...base, target: { fullName: 'Geçerli Ad', email: 'gecersiz' } }), 400, 'VALIDATION');
  await rejects(svc.requestAssignAdminOtp({ ...base, target: { fullName: 'Geçerli Ad', phone: '12' } }), 400, 'VALIDATION');
  await rejects(svc.requestAssignAdminOtp({ ...base, target: { fullName: 'Geçerli Ad', email: 123 } }), 400, 'VALIDATION');
  await rejects(svc.requestAssignAdminOtp({ ...base, homeId: 'uuid-degil', target: target() }), 400, 'VALIDATION');
  await rejects(svc.requestAssignAdminOtp({ ...base, homeId: uid(), target: target() }), 404, 'NOT_FOUND');

  // kendini atayamaz (staff e-postası ile)
  await rejects(svc.requestAssignAdminOtp({ ...base, target: { fullName: 'Kendim Ben', email: t.staff.email.toUpperCase() } }), 403, 'FORBIDDEN');
  // başka servis personeli / süper kullanıcı hesabı
  const otherStaff = h.user({ role: 'service_user' });
  await rejects(svc.requestAssignAdminOtp({ ...base, target: { fullName: 'Başka Servis', email: otherStaff.email } }), 403, 'FORBIDDEN');
  await rejects(svc.requestAssignAdminOtp({ ...base, target: { fullName: 'Süper Kişi', email: sup.email } }), 403, 'FORBIDDEN');
  // pasif hesap
  const frozen = h.user({ status: 'suspended' });
  await rejects(svc.requestAssignAdminOtp({ ...base, target: { fullName: 'Donmuş Kişi', email: frozen.email } }), 409, 'CONFLICT');
  const deleted = h.user({ status: 'deleted' });
  await rejects(svc.requestAssignAdminOtp({ ...base, target: { fullName: 'Silinmiş Kişi', email: deleted.email } }), 409, 'CONFLICT');
  // telefonla bilinmeyen hesap: yeni hesap açılamaz
  await rejects(svc.requestAssignAdminOtp({ ...base, target: { fullName: 'Telefon Kişi', phone: '+905551239999' } }), 400, 'VALIDATION');
  // teslim edilemeyen alanlar (yer tutucu e-postalarla ileride çakışma + davet gönderilemez)
  for (const bad of ['phone_905551230000@ahbu.local', 'x@kurum.local', 'apple.abc@users.noreply.invalid', 'y@ornek.invalid']) {
    await rejects(svc.requestAssignAdminOtp({ ...base, target: { fullName: 'Yer Tutucu', email: bad } }), 400, 'VALIDATION');
    await rejects(svc.assignAdmin({ actor: actorOf(sup), homeId: t.home.id, target: { fullName: 'Yer Tutucu', email: bad }, force: true, reason: 'Yer tutucu e-posta reddi testi gerekçesi' }), 400, 'VALIDATION');
  }
  assert.equal(state.users.filter((u) => /^(phone_905551230000@ahbu\.local|x@kurum\.local|y@ornek\.invalid)$/.test(u.email)).length, 0, 'yer tutucu adresle hesap açılmadı');
  assert.equal(state.home_admin_assign_otps.filter((o) => o.home_id === t.home.id).length, 0, 'imkansız hedef için sahibe kod gitmedi');
  // super de kendini atayamaz
  await rejects(svc.requestAssignAdminOtp({ actor: actorOf(sup), homeId: t.home.id, target: { fullName: 'Süper Ben', email: sup.email } }), 403, 'FORBIDDEN');
});

test('hedef zaten evin TEK sahibiyse 409 (sahibe kod gönderilmez; üyelikler boşuna silinmez); birden fazla sahipte super ile birleştirme mümkün', async () => {
  const { svc } = makeSvc();
  const t = scenario();
  const sup = h.user({ role: 'super_user' });
  const same = { fullName: 'Eski Sahip', email: t.owner.email };
  const mailsBefore = env.mails.length;
  await rejects(requestOtp(svc, t, same), 409, 'CONFLICT');
  await rejects(svc.assignAdmin({ actor: actorOf(t.staff), homeId: t.home.id, target: same, otpCode: '123456' }), 409, 'CONFLICT');
  await rejects(svc.assignAdmin({ actor: actorOf(sup), homeId: t.home.id, target: same, force: true, reason: 'Aynı kişiye zorla atama denemesi gerekçesi' }), 409, 'CONFLICT');
  assert.equal(env.mails.length, mailsBefore);
  assert.equal(rolesOf(t.home.id).length, 3, 'üyelikler korundu');
  // ortak sahiplerden birini tek sahip yapma (birleştirme): super + zorla
  const second = h.user();
  h.member(t.home, second, 'owner');
  const r = await svc.assignAdmin({ actor: actorOf(sup), homeId: t.home.id, target: { fullName: 'Ortak', email: second.email }, force: true, reason: 'Ortak sahiplerden biri tek sahip yapılıyor' });
  assert.deepEqual(ownersOf(t.home.id), [second.id]);
  assert.equal(r.previous_owner_count, 2);
});

test('request-otp: 1 günden eski süresi dolmuş OTP satırları (hedef kimliği içerir) oportunist olarak silinir', async () => {
  const { svc } = makeSvc();
  const stale = scenario();
  state.home_admin_assign_otps.push({
    id: uid(), home_id: stale.home.id, owner_user_id: stale.owner.id, target_identifier: 'eski-hedef@example.test', otp_hash: 'h1$x',
    expires_at: new Date(clock.now().getTime() - 2 * 86400000), attempts: 0, window_started_at: clock.now(), created_at: new Date(clock.now().getTime() - 2 * 86400000),
  });
  const t = scenario();
  await requestOtp(svc, t, target());
  assert.equal(state.home_admin_assign_otps.some((o) => o.home_id === stale.home.id), false, 'eski satır silindi');
  assert.equal(state.home_admin_assign_otps.some((o) => o.home_id === t.home.id), true, 'yeni satır duruyor');
});

// ================================================================================================
// Atama: sahibin rızası (OTP)
// ================================================================================================
test('atama: OTP YOKSA sahibi olan ev için 400 OWNER_CONSENT_REQUIRED; hiçbir şey değişmez', async () => {
  const { svc } = makeSvc();
  const t = scenario();
  const before = JSON.stringify(rolesOf(t.home.id));
  await rejects(svc.assignAdmin({ actor: actorOf(t.staff), homeId: t.home.id, target: target() }), 400, 'OWNER_CONSENT_REQUIRED');
  await rejects(svc.assignAdmin({ actor: actorOf(t.staff), homeId: t.home.id, target: target(), otpCode: '12345' }), 400, 'OWNER_CONSENT_REQUIRED');
  await rejects(svc.assignAdmin({ actor: actorOf(t.staff), homeId: t.home.id, target: target(), otpCode: '123456' }), 400, 'OWNER_CONSENT_REQUIRED', {});
  assert.equal(JSON.stringify(rolesOf(t.home.id)), before);
  assert.equal(state.home_admin_assignment_logs.filter((l) => l.home_id === t.home.id).length, 0);
});

test('atama: yanlış kod sayaç artırır (commit-then-throw: hata atılırken sayaç GERİ ALINMAZ); 5 yanlıştan sonra doğru kod bile 429', async () => {
  const { svc } = makeSvc();
  const t = scenario();
  const tg = target();
  await requestOtp(svc, t, tg);
  const code = env.lastOtp(t.owner.email);
  const wrong = code === '000000' ? '111111' : '000000';
  for (let i = 1; i <= 4; i++) {
    await rejects(svc.assignAdmin({ actor: actorOf(t.staff), homeId: t.home.id, target: tg, otpCode: wrong }), 400, 'VALIDATION', { remaining_attempts: C.OTP_MAX_ATTEMPTS - i });
    assert.equal(state.home_admin_assign_otps.find((o) => o.home_id === t.home.id).attempts, i, `sayaç ${i}`);
  }
  await rejects(svc.assignAdmin({ actor: actorOf(t.staff), homeId: t.home.id, target: tg, otpCode: wrong }), 400, 'VALIDATION', { remaining_attempts: 0 });
  const locked = await rejects(svc.assignAdmin({ actor: actorOf(t.staff), homeId: t.home.id, target: tg, otpCode: code }), 429, 'RATE_LIMITED');
  assert.ok(locked.retryAfter > 0);
  assert.equal(ownersOf(t.home.id)[0], t.owner.id, 'devir yapılmadı');
});

test('atama: kod HEDEFE bağlı (başka kişi için kullanılamaz), süresi dolunca ve sahip değişince geçersiz', async () => {
  const { svc } = makeSvc();
  const t = scenario();
  const tg = target();
  await requestOtp(svc, t, tg);
  const code = env.lastOtp(t.owner.email);
  // başka hedef
  await rejects(svc.assignAdmin({ actor: actorOf(t.staff), homeId: t.home.id, target: target({ fullName: 'Başka Biri' }), otpCode: code }), 400, 'OWNER_CONSENT_REQUIRED');
  // hedef büyük/küçük harf farkı aynı kişidir (normalize)
  const upper = { ...tg, email: tg.email.toUpperCase() };
  // sahip değişti (örn. devir): kod artık geçersiz
  const row = state.home_admin_assign_otps.find((o) => o.home_id === t.home.id);
  const realOwner = row.owner_user_id;
  row.owner_user_id = uid();
  await rejects(svc.assignAdmin({ actor: actorOf(t.staff), homeId: t.home.id, target: upper, otpCode: code }), 400, 'OWNER_CONSENT_REQUIRED');
  row.owner_user_id = realOwner;
  // süre doldu
  clock.advance((C.OTP_TTL_SECONDS + 5) * 1000);
  await rejects(svc.assignAdmin({ actor: actorOf(t.staff), homeId: t.home.id, target: upper, otpCode: code }), 400, 'OWNER_CONSENT_REQUIRED');
  assert.equal(ownersOf(t.home.id)[0], t.owner.id);
  assert.equal(row.attempts, 0, 'bu hatalar sayaç harcamaz');
});

// ================================================================================================
// Atama: devir etkileri + atomiklik
// ================================================================================================
test('atama (sahip OTP ile onayladı): TEK owner; eski sahip/aile erişimi, servis PIN/oturumu, uygulama MQTT kimlikleri, davet/kural/bekleyen devir iptal; staff uyeliği ve cihaz kimliği korunur; denetim kaydı', async () => {
  const { svc, fetchFn, cleanupCalls } = makeSvc();
  const t = scenario();
  const tg = target({ fullName: 'Yeni Sahip' });
  const staffRowBefore = state.home_users.find((m) => m.user_id === t.staff.id && m.home_id === t.home.id);
  const deviceCredential = { id: uid(), username: `d_${t.home.mqtt_username}`, kind: 'device', home_id: t.home.id, user_id: null };
  state.mqtt_credentials.push(deviceCredential);
  // ön koşul: eski sahip eve erişir
  assert.equal(await accessOf(t.owner, t.home), 200);
  assert.equal(await accessOf(t.resident, t.home), 200);

  await requestOtp(svc, t, tg);
  const code = env.lastOtp(t.owner.email);
  const r = await svc.assignAdmin({ actor: actorOf(t.staff), homeId: t.home.id, target: tg, otpCode: code });

  // yanıt
  assert.equal(r.mode, 'owner_consent');
  assert.equal(r.home_id, t.home.id);
  assert.equal(r.account_created, true);
  assert.equal(r.invite_sent, true);
  assert.equal(r.previous_owner_count, 1);
  assert.equal(r.new_owner.full_name, 'Yeni Sahip');
  assert.equal(r.new_owner.email, tg.email);
  assert.equal(r.new_owner.account_status, 'pending_invite');
  assert.deepEqual(r.revoked, { memberships: 2, service_pins: 1, service_sessions: 1, app_credentials: 2 });
  assert.ok(!r.warnings, 'EMQX ayarlı: bağlantılar atıldı, uyarı yok');
  assert.ok(!JSON.stringify(r).includes(code));

  // yeni hesap: pending_invite, kullanılamaz parola, oluşturan = staff
  const newcomer = state.users.find((u) => u.email === tg.email);
  assert.equal(newcomer.account_status, 'pending_invite');
  assert.equal(newcomer.role, 'user');
  assert.equal(newcomer.created_by_user_id, t.staff.id);
  assert.ok(!newcomer.password_hash.startsWith('h1$'));
  assert.ok(env.mailsTo(tg.email).some((m) => /etkinle/i.test(m.subject)), 'hesap kurulum daveti gitti');

  // üyelikler: yeni TEK owner + işlemi yapan staff'in servis üyeliği (süresi aynen)
  assert.deepEqual(rolesOf(t.home.id), [`${newcomer.id}:owner`, `${t.staff.id}:service_user`].sort());
  assert.equal(state.home_users.find((m) => m.user_id === t.staff.id).installer_expires_at, staffRowBefore.installer_expires_at);
  // eski sahip ve aile üyesi ARTIK eve erişemez (gerçek requireHomeAccess)
  assert.equal(await accessOf(t.owner, t.home), 403);
  assert.equal(await accessOf(t.resident, t.home), 403);
  assert.equal(await accessOf(newcomer, t.home), 200);
  // eski sahibin HESABI ve başka evlerdeki durumu etkilenmedi
  assert.equal(t.owner.is_active, true);
  assert.equal(t.owner.token_version, 1, 'hesap düzeyinde oturum iptali YOK (yalnızca bu eve ait erişim)');

  // servis PIN'i/oturumu iptal; uygulama MQTT kimlikleri silindi, cihaz kimliği KORUNDU
  assert.ok(t.token.revoked_at);
  assert.ok(t.session.revoked_at);
  assert.equal(t.session.revoked_reason, 'admin_assigned');
  assert.equal(state.mqtt_credentials.filter((c) => c.home_id === t.home.id && c.kind === 'app').length, 0);
  assert.equal(state.mqtt_credentials.filter((c) => c.home_id === t.home.id && c.kind === 'device').length, 1);
  // commit sonrası açık bağlantılar atıldı
  const kicked = fetchFn.calls.filter((c) => c.method === 'DELETE').map((c) => decodeURIComponent(c.url.split('/').pop())).sort();
  assert.deepEqual(kicked, [t.credOwner.username, t.credResident.username].sort());

  // temizlik: aynı transaction içinde, uç noktalar korunur
  assert.deepEqual(cleanupCalls, [{ homeId: t.home.id, options: { keepEndpoints: true }, inTx: true }]);
  assert.equal(state.home_invitations.filter((i) => i.home_id === t.home.id).length, 0);
  assert.equal(state.scheduled_rules.filter((x) => x.home_id === t.home.id).length, 0);
  assert.equal(state.home_transfers.filter((x) => x.home_id === t.home.id && x.status === 'PENDING').length, 0, 'eski sahibin bekleyen devri iptal');

  // cihaz / envanter sahipliği yeni sahibe
  assert.equal(t.dev.claimed_by, newcomer.id);
  assert.equal(t.inv.claimed_by_user_id, newcomer.id);
  // OTP tüketildi (tek kullanımlık)
  assert.equal(state.home_admin_assign_otps.filter((o) => o.home_id === t.home.id).length, 0);
  // aynı kodla tekrar: aynı hedef artık zaten tek sahip (409); başka hedef için kod tüketilmiş/bağlı değil (400)
  await rejects(svc.assignAdmin({ actor: actorOf(t.staff), homeId: t.home.id, target: tg, otpCode: code }), 409, 'CONFLICT');
  await rejects(svc.assignAdmin({ actor: actorOf(t.staff), homeId: t.home.id, target: target(), otpCode: code }), 400, 'OWNER_CONSENT_REQUIRED');

  // denetim kaydı (kod/parola yok)
  const log = state.home_admin_assignment_logs.find((l) => l.home_id === t.home.id);
  assert.deepEqual(
    [log.mode, log.actor_user_id, log.actor_role, log.new_owner_id, log.account_created, log.reason, log.home_name],
    ['owner_consent', t.staff.id, 'service_user', newcomer.id, true, null, t.home.name]
  );
  assert.deepEqual(log.previous_owner_ids, [t.owner.id]);
  assert.equal(log.ip_address, '203.0.113.7');
  assert.ok(!JSON.stringify(log).includes(code));
});

test('atama: ATOMİK - devir ortasında (MQTT kimlik iptali) hata olursa hiçbir değişiklik KALMAZ; OTP tüketilmez, hesap açılmaz', async () => {
  const failing = { revokeHomeAccess: async () => { throw new Error('beklenen test hatası'); }, kickUsernames: async () => ({}) };
  const { svc } = makeSvc({ mqtt: failing });
  const t = scenario();
  const tg = target();
  await requestOtp(svc, t, tg);
  const code = env.lastOtp(t.owner.email);
  const snapshot = () => JSON.stringify({
    roles: rolesOf(t.home.id), users: state.users.length, inv: state.home_invitations.length, rules: state.scheduled_rules.length,
    transfers: state.home_transfers.map((x) => x.status), tokenRev: t.token.revoked_at, sessRev: t.session.revoked_at,
    claimed: [t.dev.claimed_by, t.inv.claimed_by_user_id], creds: state.mqtt_credentials.length, logs: state.home_admin_assignment_logs.length,
    otp: state.home_admin_assign_otps.map((o) => [o.id, o.attempts]),
  });
  const before = snapshot();
  await assert.rejects(svc.assignAdmin({ actor: actorOf(t.staff), homeId: t.home.id, target: tg, otpCode: code }), /beklenen test hatası/);
  assert.equal(snapshot(), before, 'transaction tümüyle geri alındı');
  assert.ok(env.world.db.rollbacks >= 1);
  assert.equal(state.users.find((u) => u.email === tg.email), undefined);

  // aynı kodla DOĞRU servis artık başarılı olur
  const { svc: good } = makeSvc();
  const ok = await good.assignAdmin({ actor: actorOf(t.staff), homeId: t.home.id, target: tg, otpCode: code });
  assert.equal(ok.mode, 'owner_consent');
});

test('atama: tüm adımlar TEK transaction içinde (havuza düşen sorgu yok)', async () => {
  const { svc } = makeSvc();
  const t = scenario();
  const tg = target();
  await requestOtp(svc, t, tg);
  const code = env.lastOtp(t.owner.email);
  const startLog = env.world.db.log.length;
  await svc.assignAdmin({ actor: actorOf(t.staff), homeId: t.home.id, target: tg, otpCode: code });
  // commit SONRASI yan etki (hesap kurulum daveti: password_resets) bilerek transaction dışındadır
  const mutating = env.world.db.log.slice(startLog).filter((l) => /^(INSERT|UPDATE|DELETE)/.test(l.sql) && !l.sql.includes('password_resets'));
  assert.ok(mutating.length >= 8);
  assert.deepEqual(mutating.filter((l) => l.tx === null).map((l) => l.sql.slice(0, 60)), [], 'tüm yazmalar withTransaction içinde');
  assert.equal(new Set(mutating.map((l) => l.tx)).size, 1, 'tek transaction');
  const afterCommit = env.world.db.log.slice(startLog).filter((l) => l.sql.includes('password_resets'));
  assert.ok(afterCommit.length > 0 && afterCommit.every((l) => l.tx === null), 'davet commit sonrası, havuz üzerinden');
});

test('atama: aynı kodla eşzamanlı üç istek -> yalnızca BİRİ başarılı (ev satırı kilidi + tek kullanımlık OTP)', async () => {
  const t = scenario();
  const tg = target();
  const { svc: first } = makeSvc();
  await requestOtp(first, t, tg);
  const code = env.lastOtp(t.owner.email);
  const results = await Promise.allSettled([0, 1, 2].map(() => makeSvc().svc.assignAdmin({ actor: actorOf(t.staff), homeId: t.home.id, target: tg, otpCode: code })));
  const ok = results.filter((r) => r.status === 'fulfilled');
  assert.equal(ok.length, 1, JSON.stringify(results.map((r) => r.status === 'fulfilled' ? 'ok' : r.reason.code)));
  assert.equal(state.home_admin_assignment_logs.filter((l) => l.home_id === t.home.id).length, 1);
  assert.equal(ownersOf(t.home.id).length, 1);
  assert.equal(state.users.filter((u) => u.email === tg.email).length, 1, 'tek hesap');
});

// ================================================================================================
// Atama: sahip yok / mevcut hesaplar / zorla
// ================================================================================================
test('atama (sahip YOK): kod gerekmez, pending_invite hesap + davet; mevcut üyeler ve uygulama kimlikleri KORUNUR', async () => {
  const { svc, fetchFn } = makeSvc();
  const staff = h.user({ role: 'service_user' });
  const resident = h.user();
  const home = h.home({ name: 'Sahipsiz Ev' });
  h.member(home, staff, 'service_user');
  h.member(home, resident, 'resident');
  const cred = h.appCredential(home, resident);
  const tg = target({ fullName: 'İlk Admin' });
  const r = await svc.assignAdmin({ actor: actorOf(staff), homeId: home.id, target: tg });
  assert.equal(r.mode, 'no_owner');
  assert.equal(r.account_created, true);
  assert.equal(r.previous_owner_count, 0);
  const u = state.users.find((x) => x.email === tg.email);
  assert.equal(u.account_status, 'pending_invite');
  assert.deepEqual(rolesOf(home.id), [`${u.id}:owner`, `${resident.id}:resident`, `${staff.id}:service_user`].sort());
  assert.ok(state.mqtt_credentials.includes(cred), 'uygulama kimlikleri korunur');
  assert.equal(fetchFn.calls.length, 0);
  assert.equal(state.home_admin_assignment_logs.at(-1).mode, 'no_owner');
  assert.deepEqual(state.home_admin_assignment_logs.at(-1).previous_owner_ids, []);
  assert.ok(env.mailsTo(tg.email).some((m) => /etkinle/i.test(m.subject)));
});

test('uyelik-6: atama (sahip YOK) de evin servis oturumu MQTT kimligi (user_id bos) silinir ve atilir; kullanici kimlikleri KORUNUR', async () => {
  const { svc, fetchFn } = makeSvc();
  const staff = h.user({ role: 'service_user' });
  const resident = h.user();
  const home = h.home({ name: 'Sahipsiz Servisli Ev' });
  h.member(home, staff, 'service_user');
  h.member(home, resident, 'resident');
  const residentCred = h.appCredential(home, resident);
  const sessionCred = h.appCredential(home, null);
  const r = await svc.assignAdmin({ actor: actorOf(staff), homeId: home.id, target: target({ fullName: 'Servisli Admin' }) });
  assert.equal(r.mode, 'no_owner');
  assert.ok(!state.mqtt_credentials.includes(sessionCred), 'servis oturumu kimligi silindi');
  assert.ok(state.mqtt_credentials.includes(residentCred), 'kullanici kimligi korunur');
  assert.ok(fetchFn.calls.some((c) => c.method === 'DELETE' && decodeURIComponent(c.url).includes(sessionCred.username)), 'baglanti atildi');
});

test('atama: hedef MEVCUT etkin hesapsa yeni hesap açılmaz (bilgilendirme e-postası); pending_invite hesapsa davet yeniden gider; telefonla da bulunur', async () => {
  const { svc } = makeSvc();
  const staff = h.user({ role: 'service_user' });
  const mk = (extra) => {
    const home = h.home({ name: `Mevcut ${++n}` });
    h.member(home, staff, 'service_user');
    return home;
  };
  const active = h.user({ full_name: 'Etkin Hesap', phone: '+905557770001' });
  const pending = h.user({ full_name: 'Bekleyen', status: 'pending_invite' });
  const usersBefore = state.users.length;

  const r1 = await svc.assignAdmin({ actor: actorOf(staff), homeId: mk().id, target: { fullName: 'Etkin Hesap', email: active.email } });
  assert.equal(r1.account_created, false);
  assert.equal(r1.new_owner.id, active.id);
  assert.equal(r1.new_owner.account_status, 'active');
  assert.ok(env.mailsTo(active.email).some((m) => /yetkisi verildi/i.test(m.subject)));

  const r2 = await svc.assignAdmin({ actor: actorOf(staff), homeId: mk().id, target: { fullName: 'Bekleyen', email: pending.email } });
  assert.equal(r2.account_created, false);
  assert.equal(r2.invite_sent, true);
  assert.ok(env.mailsTo(pending.email).some((m) => /etkinle/i.test(m.subject)));

  // uyelik-1: kayitta telefon DOGRULANMAZ -> telefonla bulunan gercek e-postali hesap atanamaz (e-posta istenir)
  const h3 = mk();
  const e3 = await rejects(svc.assignAdmin({ actor: actorOf(staff), homeId: h3.id, target: { fullName: 'Etkin Hesap', phone: '+90 555 777 00 01' } }), 400, 'VALIDATION');
  assert.equal(e3.message, 'Bu numara e-postalı bir hesaba kayıtlı; atama için hesabın e-posta adresini girin.');
  assert.equal(ownersOf(h3.id).length, 0);
  // telefon-OTP ile acilmis (yer tutucu e-postali) hesap telefonla bulunur ve atanir
  const otpUser = h.user({ full_name: 'Telefon Hesabi', phone: '+905557770002', email: 'phone_905557770002@ahbu.local' });
  const r3 = await svc.assignAdmin({ actor: actorOf(staff), homeId: mk().id, target: { fullName: 'Telefon Hesabi', phone: '+90 555 777 00 02' } });
  assert.equal(r3.new_owner.id, otpUser.id, 'telefon normalize edilip mevcut hesap bulunur');
  assert.equal(state.users.length, usersBefore + 1, 'yeni hesap açılmadı');
});

test('uyelik-1: atama - telefonla istenen onay kodu da gercek e-postali hesapta 400 (sahibe bosuna kod gitmez)', async () => {
  const { svc } = makeSvc();
  const t = scenario();
  h.user({ full_name: 'Telefonlu', phone: '+905557770003' });
  await rejects(svc.requestAssignAdminOtp({ actor: actorOf(t.staff), homeId: t.home.id, target: { fullName: 'Telefonlu', phone: '+905557770003' } }), 400, 'VALIDATION');
  assert.equal(env.mailsTo(t.owner.email).length, 0);
});

test('uyelik-1: atama - dogrulanmamis e-posta hedefi (sahip YOK / zorla / sahip onayi) etkisizlestirilir, davet gider, guvenlik notu doner', async () => {
  const runCase = async (mode) => {
    const { svc } = makeSvc();
    const staff = h.user({ role: 'service_user' });
    let home;
    let otpCode;
    let actor = actorOf(staff);
    let extra = {};
    const victim = h.user({ full_name: 'Kurban Hesap', password_hash: 'saldirgan-ozet' });
    victim.email_verified = false;
    const cred = h.appCredential(h.home({ name: `Baska ${++n}` }), victim);
    if (mode === 'no_owner') {
      home = h.home({ name: `Sahipsiz ${++n}` });
      h.member(home, staff, 'service_user');
    } else {
      const t = scenario();
      home = t.home;
      actor = actorOf(t.staff);
      if (mode === 'forced') {
        actor = actorOf(h.user({ role: 'super_user' }));
        extra = { force: true, reason: 'Sahibe ulaşılamıyor, zorunlu devir.' };
      } else {
        await requestOtp(svc, t, { fullName: 'Kurban Hesap', email: victim.email });
        otpCode = env.lastOtp(t.owner.email);
      }
    }
    const r = await svc.assignAdmin({ actor, homeId: home.id, target: { fullName: 'Kurban Hesap', email: victim.email }, otpCode, ...extra });
    assert.equal(r.mode, mode);
    const u = state.users.find((x) => x.id === victim.id);
    assert.notEqual(u.password_hash, 'saldirgan-ozet', `${mode}: parola kullanilamaz yapildi`);
    assert.equal(u.account_status, 'pending_invite', mode);
    assert.equal(u.token_version, 2, mode);
    assert.ok(!state.mqtt_credentials.includes(cred), `${mode}: uygulama MQTT kimligi silindi`);
    assert.equal(r.new_owner.account_status, 'pending_invite');
    assert.equal(r.invite_sent, true);
    assert.ok(env.mailsTo(victim.email).some((m) => /etkinle/i.test(m.subject)), `${mode}: davet`);
    assert.ok((r.warnings || []).some((w) => w.includes('güvenlik için sıfırlandı')), `${mode}: guvenlik notu`);
    assert.notEqual(r.partial, true, 'bilgi notu kismi basarisizlik sayilmaz');
  };
  await runCase('no_owner');
  await runCase('forced');
  await runCase('owner_consent');
});

test('uyelik-1: telefonla bulunan YER TUTUCU e-postali hesap (telefon-OTP ile acilmis) etkisizlestirilmez; dogrudan atanir', async () => {
  const { svc } = makeSvc();
  const sup = h.user({ role: 'super_user' });
  const phone = '+905559990011';
  const phoneUser = h.user({ full_name: 'Telefon Kisi', phone, email: 'phone_905559990011@ahbu.local', password_hash: 'kendi-ozeti' });
  phoneUser.email_verified = false;
  const t = scenario();
  const r = await svc.assignAdmin({ actor: actorOf(sup), homeId: t.home.id, target: { fullName: 'Telefon Kisi', phone }, force: true, reason: 'Sahibe ulaşılamıyor, zorunlu devir.' });
  assert.equal(r.new_owner.id, phoneUser.id);
  const u = state.users.find((x) => x.id === phoneUser.id);
  assert.equal(u.password_hash, 'kendi-ozeti', 'parola korunur');
  assert.equal(u.account_status, 'active');
  assert.equal(u.token_version, 1, 'oturumlari dusmez');
  assert.ok(!(r.warnings || []).some((w) => w.includes('güvenlik için sıfırlandı')));
});

test('atama: yeni hesapta telefon başka hesapta kayıtlıysa 409; davet e-postası gönderilemezse atama YİNE başarılı (uyarı + partial)', async () => {
  const { svc } = makeSvc();
  const staff = h.user({ role: 'service_user' });
  const home = h.home({ name: 'Telefon Çakışma' });
  h.member(home, staff, 'service_user');
  h.user({ phone: '+905558880001' });
  await rejects(svc.assignAdmin({ actor: actorOf(staff), homeId: home.id, target: { fullName: 'Yeni Kişi', email: `yeni${++n}@example.test`, phone: '+905558880001' } }), 409, 'CONFLICT');
  assert.equal(ownersOf(home.id).length, 0, 'geri alındı');

  env.mailControl.fail = true;
  try {
    const r = await svc.assignAdmin({ actor: actorOf(staff), homeId: home.id, target: target() });
    assert.equal(r.mode, 'no_owner');
    assert.equal(r.invite_sent, false);
    assert.equal(r.partial, true);
    assert.ok(r.warnings.some((w) => /etkinleştirme e-postası/i.test(w)));
    assert.equal(ownersOf(home.id).length, 1, 'atama kalıcı');
  } finally {
    env.mailControl.fail = false;
  }
});

test('zorla atama: yalnız super_user, gerekçe >= 15; OTP aranmaz; bekleyen kod silinir; önceki sahibe bildirim; denetim kaydında gerekçe', async () => {
  const { svc } = makeSvc();
  const sup = h.user({ role: 'super_user' });
  const t = scenario();
  const tg = target();
  await requestOtp(svc, t, tg); // bekleyen kod
  const base = { homeId: t.home.id, target: tg, force: true };
  // staff zorlayamaz
  await rejects(svc.assignAdmin({ actor: actorOf(t.staff), ...base, reason: 'Ev sahibine ulaşılamıyor, yerinde teslim' }), 403, 'FORBIDDEN');
  // gerekçe zorunlu / kısa / çok uzun
  await rejects(svc.assignAdmin({ actor: actorOf(sup), ...base }), 400, 'VALIDATION');
  await rejects(svc.assignAdmin({ actor: actorOf(sup), ...base, reason: 'kısa gerekçe' }), 400, 'VALIDATION');
  await rejects(svc.assignAdmin({ actor: actorOf(sup), ...base, reason: 'x'.repeat(501) }), 400, 'VALIDATION');
  assert.equal(ownersOf(t.home.id)[0], t.owner.id);

  const reason = 'Ev sahibine ulaşılamıyor, daire yerinde teslim alındı';
  const r = await svc.assignAdmin({ actor: actorOf(sup), ...base, reason });
  assert.equal(r.mode, 'forced');
  assert.deepEqual(ownersOf(t.home.id), [state.users.find((u) => u.email === tg.email).id]);
  assert.equal(state.home_admin_assign_otps.filter((o) => o.home_id === t.home.id).length, 0, 'bekleyen onay kodu geçersiz');
  assert.equal(await accessOf(t.owner, t.home), 403);
  const log = state.home_admin_assignment_logs.at(-1);
  assert.deepEqual([log.mode, log.actor_role, log.reason], ['forced', 'super_user', reason]);
  // önceki sahibe "devredildi" bildirimi
  assert.ok(env.mailsTo(t.owner.email).some((m) => /devredildi/i.test(m.subject)));
  // super üyelik olmadan işlem yapar: staff'in servis üyeliği (başkasının) silinir — super için korunacak satır yok
  assert.ok(!state.home_users.some((m) => m.home_id === t.home.id && m.user_id === t.staff.id), 'super zorla atamasında diğer personelin üyeliği de kalkar');
});

test('pano-6: atama owner/resident uyeligini silince tek panolu evin yerel anahtari BEKLEYEN yolla doner (ayni tx, COMMIT sonrasi uzlastirici); sahip YOK modunda donmez', async () => {
  const { LocalKeyRotation } = env.SRC('services/local_key_rotation');
  const reconciles = [];
  const rotation = new LocalKeyRotation({ requestReconcile: (topicId) => reconciles.push(topicId), logger: silentLogger });
  const sup = h.user({ role: 'super_user' });
  const t = scenario();
  const { svc } = makeSvc();
  svc._deps.rotation = rotation;
  const r = await svc.assignAdmin({ actor: actorOf(sup), homeId: t.home.id, target: target(), force: true, reason: 'Ev sahibine ulaşılamıyor, yerinde teslim alındı' });
  assert.equal(r.mode, 'forced');
  assert.ok(t.dev.local_key_pending_enc, 'bekleyen anahtar yazildi');
  const a = state.device_audit_logs.filter((x) => x.event === 'local_key_rotation_scheduled' && x.home_id === t.home.id);
  assert.equal(a.length, 1);
  assert.deepEqual(a[0].details, { reason: 'admin_assigned' });
  assert.deepEqual(reconciles, [t.home.mqtt_username]);

  // sahip YOK: uyelik silinmez -> rotasyon yok
  const lone = h.user();
  const home2 = h.home({ name: 'Sahipsiz Ev' });
  h.member(home2, lone, 'resident');
  const dev2 = h.device(home2);
  const r2 = await svc.assignAdmin({ actor: actorOf(sup), homeId: home2.id, target: target() });
  assert.equal(r2.mode, 'no_owner');
  assert.ok(!dev2.local_key_pending_enc, 'sahip yok modunda rotasyon yok');
  assert.deepEqual(reconciles, [t.home.mqtt_username]);
});

test('zorla atama: sahibi ulaşılamaz (yer tutucu e-posta) evde staff OTP ile ilerleyemez, super zorlayabilir', async () => {
  const { svc } = makeSvc();
  const sup = h.user({ role: 'super_user' });
  const t = scenario({ ownerEmail: `phone_90555${++n}@ahbu.local` });
  await rejects(requestOtp(svc, t, target()), 409, 'OWNER_UNREACHABLE');
  await rejects(svc.assignAdmin({ actor: actorOf(t.staff), homeId: t.home.id, target: target(), otpCode: '123456' }), 400, 'OWNER_CONSENT_REQUIRED');
  const r = await svc.assignAdmin({ actor: actorOf(sup), homeId: t.home.id, target: target(), force: true, reason: 'Sahibin e-postası yok, yerinde teslim alındı' });
  assert.equal(r.mode, 'forced');
  assert.ok(!r.warnings || r.warnings.length === 0, 'ulaşılamayan sahibe bildirim denenmez');
});

test('zorla atama: birden fazla sahipli evde yalnız super (staff 409 MULTIPLE_OWNERS)', async () => {
  const { svc } = makeSvc();
  const sup = h.user({ role: 'super_user' });
  const t = scenario();
  h.member(t.home, h.user(), 'owner');
  await rejects(svc.assignAdmin({ actor: actorOf(t.staff), homeId: t.home.id, target: target(), otpCode: '123456' }), 409, 'MULTIPLE_OWNERS');
  const r = await svc.assignAdmin({ actor: actorOf(sup), homeId: t.home.id, target: target(), force: true, reason: 'Birden fazla sahip kaydı düzeltiliyor' });
  assert.equal(r.previous_owner_count, 2);
  assert.equal(ownersOf(t.home.id).length, 1);
});

test('atama: staff servis üyeliği süresi dolmuşsa / başka evdeyse / pasifse servis katmanı da reddeder (derinlemesine savunma)', async () => {
  const { svc } = makeSvc();
  const t = scenario();
  state.home_users.find((m) => m.user_id === t.staff.id).installer_expires_at = new Date(clock.now().getTime() - 1000);
  await rejects(requestOtp(svc, t, target()), 403, 'FORBIDDEN');
  await rejects(svc.assignAdmin({ actor: actorOf(t.staff), homeId: t.home.id, target: target(), otpCode: '123456' }), 403, 'FORBIDDEN');
  const outsider = h.user({ role: 'service_user' });
  await rejects(svc.assignAdmin({ actor: actorOf(outsider), homeId: t.home.id, target: target(), otpCode: '123456' }), 403, 'FORBIDDEN');
  const frozen = h.user({ role: 'service_user', status: 'suspended' });
  h.member(t.home, frozen, 'service_user');
  await rejects(svc.assignAdmin({ actor: actorOf(frozen), homeId: t.home.id, target: target(), otpCode: '123456' }), 403, 'FORBIDDEN');
  // rol bilgisi güncel değil (JWT/önbellek eski)
  const demoted = h.user({ role: 'user' });
  await rejects(svc.assignAdmin({ actor: actorOf(demoted, { globalRole: 'service_user' }), homeId: t.home.id, target: target(), otpCode: '123456' }), 403, 'FORBIDDEN');
  assert.equal(ownersOf(t.home.id)[0], t.owner.id);
});

test('atama sonrası staff aynı evi aboneler listesinde görmeye devam eder (servis üyeliği korundu)', async () => {
  const { svc } = makeSvc();
  const t = scenario();
  const tg = target();
  await requestOtp(svc, t, tg);
  await svc.assignAdmin({ actor: actorOf(t.staff), homeId: t.home.id, target: tg, otpCode: env.lastOtp(t.owner.email) });
  const list = await svc.listSubscribers({ actor: actorOf(t.staff), q: t.home.name });
  assert.equal(list.total, 1);
  assert.equal(list.subscribers[0].owner.email, tg.email);
});

// ================================================================================================
// HTTP: yetki matrisi, hiz siniri, yanit sekli
// ================================================================================================
test('HTTP yetki matrisi: owner/resident/misafir/başka staff/süresi dolmuş staff/servis oturumu/normal kullanıcı reddedilir; staff ve super geçer', async () => {
  const t = scenario();
  const sup = h.user({ role: 'super_user' });
  const guest = h.user();
  h.member(t.home, guest, 'guest', { valid_until: new Date(Date.now() + 3600e3) });
  const otherStaff = h.user({ role: 'service_user' });
  const expiredStaff = h.user({ role: 'service_user' });
  h.member(t.home, expiredStaff, 'service_user', { installer_expires_at: new Date(Date.now() - 1000) });
  const normal = h.user();
  const body = { full_name: 'Hedef Kişi', email: `hedef${++n}@example.test`, otp_code: '123456' };
  const cases = [
    ['owner', tokenOf(t.owner), 403],
    ['resident', tokenOf(t.resident), 403],
    ['misafir', tokenOf(guest), 403],
    ['başka evin staff\'ı', tokenOf(otherStaff), 403],
    ['süresi dolmuş servis üyeliği', tokenOf(expiredStaff), 403],
    ['normal kullanıcı', tokenOf(normal), 403],
    ['servis oturumu', env.sessionToken(t.home, t.session), 403],
    ['kimliksiz', null, 401],
  ];
  for (const url of [`${SUB}/${t.home.id}/assign-admin`, `${SUB}/${t.home.id}/assign-admin/request-otp`]) {
    for (const [label, token, status] of cases) {
      const r = await api('post', url, token, body);
      assert.equal(r.status, status, `${label} -> ${url} : ${JSON.stringify(r.body)}`);
      assert.equal(r.body.success, false);
    }
  }
  assert.equal(ownersOf(t.home.id)[0], t.owner.id, 'reddedilen isteklerde hiçbir şey değişmedi');
  assert.equal(state.home_admin_assignment_logs.filter((l) => l.home_id === t.home.id).length, 0);
  // geçersiz ev kimliği / bilinmeyen ev (super)
  assert.equal((await api('post', `${SUB}/gecersiz/assign-admin`, tokenOf(sup), body)).status, 400);
  assert.equal((await api('post', `${SUB}/${uid()}/assign-admin`, tokenOf(sup), body)).status, 404);
});

test('HTTP: request-otp -> assign-admin uçtan uca (staff); yanıt şekli ve /api/ takma yolu; hata gövdesi remaining_attempts', async () => {
  const t = scenario();
  const tok = tokenOf(t.staff);
  const body = { full_name: 'Uçtan Uca', email: `uc${++n}@example.test` };
  const rq = await api('post', `/api/service/subscribers/${t.home.id}/assign-admin/request-otp`, tok, body);
  assert.equal(rq.status, 200, JSON.stringify(rq.body));
  assert.equal(rq.body.success, true);
  assert.equal(rq.body.data.otp_required, true);
  assert.equal(rq.headers['cache-control'], 'no-store');
  assert.ok(!JSON.stringify(rq.body).match(/\b\d{6}\b/), 'yanıtta kod görünmez');
  const code = env.lastOtp(t.owner.email);

  const bad = await api('post', `${SUB}/${t.home.id}/assign-admin`, tok, { ...body, otp_code: code === '999999' ? '888888' : '999999' });
  assert.equal(bad.status, 400);
  assert.equal(bad.body.code, 'VALIDATION');
  assert.equal(bad.body.remaining_attempts, C.OTP_MAX_ATTEMPTS - 1);

  const ok = await api('post', `${SUB}/${t.home.id}/assign-admin`, tok, { ...body, otp_code: code });
  assert.equal(ok.status, 200, JSON.stringify(ok.body));
  assert.deepEqual(Object.keys(ok.body.data).sort(), ['account_created', 'home_id', 'home_name', 'invite_sent', 'message', 'mode', 'new_owner', 'previous_owner_count', 'revoked', 'warnings', 'partial'].filter((k) => k in ok.body.data).sort());
  assert.equal(ok.body.data.mode, 'owner_consent');
  assert.equal(ok.body.message, ok.body.data.message);
  assert.equal(ownersOf(t.home.id).length, 1);
  assert.notEqual(ownersOf(t.home.id)[0], t.owner.id);
});

test('HTTP: camelCase gövde (fullName, otpCode) kabul edilir; force/reason super için çalışır, staff için 403', async () => {
  const t = scenario();
  const sup = h.user({ role: 'super_user' });
  const tg = { fullName: 'Camel Kişi', email: `camel${++n}@example.test` };
  const staffForce = await api('post', `${SUB}/${t.home.id}/assign-admin`, tokenOf(t.staff), { ...tg, force: true, reason: 'Staff zorlayamaz ama gerekçe uzun' });
  assert.equal(staffForce.status, 403);
  const r = await api('post', `${SUB}/${t.home.id}/assign-admin`, tokenOf(sup), { ...tg, force: true, reason: 'Super zorla atama için yeterince uzun gerekçe' });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.data.mode, 'forced');
});

test('HTTP hız sınırı: request-otp (kullanıcı+ev) saatte 5; aşımda 429 RATE_LIMITED + Retry-After', async () => {
  const t = scenario({ ownerEmail: `phone_90555${++n}@ahbu.local` }); // her istek servis katmanında 409 ile biter; sınırlayıcı yine de sayar
  const tok = tokenOf(t.staff);
  const body = { full_name: 'Sınır Kişi', email: `sinir${++n}@example.test` };
  const statuses = [];
  for (let i = 0; i < 7; i++) statuses.push((await api('post', `${SUB}/${t.home.id}/assign-admin/request-otp`, tok, body)).status);
  assert.deepEqual(statuses, [409, 409, 409, 409, 409, 429, 429]);
  const limited = await api('post', `${SUB}/${t.home.id}/assign-admin/request-otp`, tok, body);
  assert.equal(limited.body.code, 'RATE_LIMITED');
  assert.ok(Number(limited.headers['retry-after']) >= 1);
});
