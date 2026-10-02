'use strict';

// WP-B2 / gorev 3: DELETE /api/v1/auth/account
//   - yumusak silme + anonimlestirme; ESKI E-POSTA SERBEST KALIR (ayni adresle yeniden kayit)
//   - yeniden dogrulama: parola (sifreli hesap) / "SİL" (sosyal-sifresiz hesap); staff/super 403
//   - TEK SAHIBI oldugu ev -> 409 SOLE_OWNER + ev listesi (once devir)
//   - tum oturumlar / refresh / push token / MQTT uygulama kimlikleri / uyelikler iptal; denetim kaydi; tek transaction

const test = require('node:test');
const assert = require('node:assert/strict');
const bcrypt = require('bcryptjs');
const { createEnv, uid } = require('./_world');

const env = createEnv();
const { h, state, api, tokenOf, world } = env;
const { AccountDeletionService, isDeleteConfirmation, isPasswordless } = env.SRC('services/account_deletion_service');

const URL = '/api/v1/auth/account';
const PASSWORD = 'Sifre-Test-12345';
let n = 0;

function pwUser(extra = {}) {
  const i = ++n;
  return h.user({
    email: `silinecek${i}@example.test`, full_name: 'Silinecek Kişi', phone: `+90555000${String(i).padStart(4, '0')}`,
    password_hash: bcrypt.hashSync(PASSWORD, 4), password_changed_at: new Date(), ...extra,
  });
}

/** Kullanicinin her turlu verisi: baska evde resident, ortak evde co-owner, MQTT kimlikleri, oturum, push, kural, davet, devir, PIN... */
function richUser(user = pwUser()) {
  const otherOwner = h.user();
  const homeX = h.home({ name: `Başkasının Evi ${++n}`, owner: otherOwner });
  h.member(homeX, user, 'resident');
  const shared = h.home({ name: `Ortak Ev ${++n}`, owner: otherOwner });
  h.member(shared, user, 'owner'); // ortak sahip: tek sahip DEĞİL (diğer owner var)
  const creds = [h.appCredential(homeX, user), h.appCredential(shared, user)];
  state.refresh_tokens.push({ id: uid(), user_id: user.id, token_hash: `rt${n}`, revoked_at: null });
  state.push_tokens.push({ id: uid(), user_id: user.id, token: `tok${n}`, platform: 'android' });
  state.scheduled_rules.push({ id: n, home_id: homeX.id, created_by: user.id });
  state.home_invitations.push({ id: uid(), home_id: shared.id, created_by: user.id, is_used: false, code_hash: `i${n}` });
  state.home_invitations.push({ id: uid(), home_id: shared.id, created_by: user.id, is_used: true, code_hash: `iu${n}` });
  state.home_transfers.push({ id: uid(), home_id: shared.id, from_user_id: user.id, target_identifier: 'x@example.test', status: 'PENDING', code_hash: `t${n}` });
  state.home_transfers.push({ id: uid(), home_id: homeX.id, from_user_id: otherOwner.id, target_identifier: user.email, status: 'PENDING', code_hash: `tt${n}` });
  const { token, session } = h.serviceSession(shared, { ownerId: user.id });
  state.password_resets.push({ id: ++n, user_id: user.id, identifier: user.email, used_at: null });
  state.password_resets.push({ id: ++n, user_id: null, identifier: user.email, used_at: null });
  if (user.phone) state.phone_otp_codes.push({ id: ++n, phone: user.phone });
  state.device_claim_otps.push({ id: ++n, requested_by: null, target_identifier: user.email, device_uuid: 'AHBU-X-1' });
  return { user, homeX, shared, otherOwner, creds, token, session };
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
  if (code) assert.equal(caught.code, code);
  for (const [k, v] of Object.entries(extra)) assert.deepEqual(caught.extra && caught.extra[k], v, `extra.${k}`);
  return caught;
};

test('parola ile silme: anonimleştirme + tüm bağlı veriler iptal; e-posta/telefon/sosyal kimlik SERBEST; denetim kaydı', async () => {
  const kicked = [];
  const svc = new AccountDeletionService({ mqtt: { kickUsernames: async (l) => { kicked.push(...l); return { kicked: l.length, failed: 0, skipped: false }; } } });
  const t = richUser(pwUser({ google_id: 'google-sub-1' }));
  const { user } = t;
  const email = user.email;
  const phone = user.phone;

  const r = await svc.deleteAccount({ userId: user.id, password: PASSWORD, ip: '198.51.100.9' });
  assert.equal(r.deleted, true);
  assert.equal(r.released_memberships, 2);
  assert.ok(r.deleted_at);
  assert.ok(r.message.includes('anonimleştirildi'));
  assert.ok(!r.warnings);

  // anonimleştirme
  assert.equal(user.account_status, 'deleted');
  assert.equal(user.is_active, false);
  assert.ok(user.deleted_at);
  assert.equal(user.email, `deleted+${user.id}@deleted.invalid`);
  assert.equal(user.phone, null);
  assert.equal(user.google_id, null);
  assert.equal(user.apple_id, null);
  assert.equal(user.full_name, 'Silinmiş Kullanıcı');
  assert.equal(user.token_version, 2, 'mevcut access token\'lar geçersiz');
  assert.ok(!/^\$2[aby]\$/.test(user.password_hash), 'parola özeti kullanılamaz (bcrypt biçimi değil)');
  assert.ok(!JSON.stringify(user).includes(email) && !JSON.stringify(user).includes(phone), 'kişisel veri kalmadı');

  // bağlı veriler
  assert.equal(state.home_users.filter((m) => m.user_id === user.id).length, 0);
  assert.equal(state.mqtt_credentials.filter((c) => c.user_id === user.id).length, 0);
  assert.deepEqual(kicked.sort(), t.creds.map((c) => c.username).sort(), 'commit sonrası açık bağlantılar atıldı');
  assert.equal(state.refresh_tokens.filter((x) => x.user_id === user.id).length, 0);
  assert.equal(state.push_tokens.filter((x) => x.user_id === user.id).length, 0);
  assert.equal(state.scheduled_rules.filter((x) => x.created_by === user.id).length, 0);
  assert.equal(state.home_invitations.filter((i) => i.created_by === user.id && !i.is_used).length, 0, 'bekleyen davetler silindi');
  assert.equal(state.home_invitations.filter((i) => i.created_by === user.id && i.is_used).length, 1, 'kullanılmış davet geçmişi korunur');
  assert.ok(state.home_transfers.every((x) => x.status === 'CANCELLED'), 'kullanıcının başlattığı VE kullanıcıya gelen bekleyen devirler iptal');
  assert.ok(t.token.revoked_at && t.session.revoked_at, 'kullanıcının ürettiği servis PIN/oturumu iptal');
  assert.equal(state.password_resets.length, 0);
  assert.equal(state.phone_otp_codes.length, 0);
  assert.equal(state.device_claim_otps.length, 0);
  // diğer kullanıcıların verisi dokunulmadı
  assert.ok(state.home_users.some((m) => m.user_id === t.otherOwner.id && m.home_id === t.shared.id), 'ortak evin diğer sahibi KALDI');

  // denetim kaydı: kişisel veri / sır yok
  const audit = state.device_audit_logs.find((a) => a.event === 'account_deleted');
  assert.equal(audit.actor_user_id, user.id);
  assert.equal(audit.ip_address, '198.51.100.9');
  assert.deepEqual(audit.details, { released_memberships: 2, revoked_app_credentials: 2, reauth: 'password' });
  assert.ok(!JSON.stringify(audit).includes(email));
  assert.ok(!JSON.stringify(audit).includes(PASSWORD));
});

test('silinen hesap: eski e-posta ve telefonla YENİDEN KAYIT mümkün (yeni hesap temiz); eski oturum/giriş geçersiz', async () => {
  const t = richUser(pwUser());
  const { user } = t;
  const email = user.email;
  const phone = user.phone;
  const token = tokenOf(user);
  assert.equal((await api('get', '/api/v1/homes', token)).status === 401, false, 'ön koşul: silinmeden önce token geçerli');

  const del = await api('delete', URL, token, { password: PASSWORD });
  assert.equal(del.status, 200, JSON.stringify(del.body));
  assert.equal(del.body.success, true);
  assert.equal(del.body.data.deleted, true);

  // eski access token ARTIK geçersiz (token_version + hesap durumu)
  const afterToken = await api('get', '/api/v1/homes', token);
  assert.equal(afterToken.status, 401);
  // eski kimlikle giriş artık mümkün değil
  const login = await api('post', '/api/v1/auth/login', null, { identifier: email, password: PASSWORD });
  assert.equal(login.status, 401);

  // aynı e-posta + telefonla yeniden kayıt
  const reg = await api('post', '/api/v1/auth/register', null, { full_name: 'Yeniden Kayıt', email, password: PASSWORD, phone });
  assert.equal(reg.status, 201, JSON.stringify(reg.body));
  assert.notEqual(reg.body.data.user.id, user.id, 'yeni hesap');
  assert.equal(reg.body.data.user.email, email);
  assert.deepEqual(reg.body.data.homes, [], 'eski hesabın evleri/verisi yeni hesaba SIZMAZ');
  // yeni hesap normal çalışır; eski satır anonim kaldı
  assert.equal(user.account_status, 'deleted');
  assert.equal(state.users.filter((u) => String(u.email).toLowerCase() === email.toLowerCase()).length, 1);
});

test('yanlış parola 400 INVALID_CREDENTIALS; parola yerine yalnız "SİL" 403 REAUTH_REQUIRED; hiçbir şey silinmez', async () => {
  const svc = new AccountDeletionService({});
  const t = richUser(pwUser());
  const before = JSON.stringify({ u: t.user, m: state.home_users.length, c: state.mqtt_credentials.length, r: state.refresh_tokens.length });
  await rejects(svc.deleteAccount({ userId: t.user.id, password: 'yanlis-parola-1' }), 400, 'INVALID_CREDENTIALS');
  await rejects(svc.deleteAccount({ userId: t.user.id, confirm: 'SİL' }), 403, 'REAUTH_REQUIRED');
  await rejects(svc.deleteAccount({ userId: t.user.id }), 403, 'REAUTH_REQUIRED');
  await rejects(svc.deleteAccount({ userId: t.user.id, password: '' }), 403, 'REAUTH_REQUIRED');
  assert.equal(JSON.stringify({ u: t.user, m: state.home_users.length, c: state.mqtt_credentials.length, r: state.refresh_tokens.length }), before);
  assert.equal(state.device_audit_logs.filter((a) => a.event === 'account_deleted' && a.actor_user_id === t.user.id).length, 0);
});

test('sosyal / sifresiz hesap: "SİL" yazarak onay (Türkçe büyük-küçük harf farkı gözetilmez); parola ile silinemez', async () => {
  const svc = new AccountDeletionService({});
  for (const [label, extra] of [
    ['Google', { google_id: 'g-1' }],
    ['Apple', { apple_id: 'a-1' }],
    ['telefon OTP', { email: `phone_90555${++n}@ahbu.local` }],
  ]) {
    const u = h.user({ full_name: `${label} Kişi`, ...extra });
    assert.equal(isPasswordless(u), true, label);
    await rejects(svc.deleteAccount({ userId: u.id }), 400, 'VALIDATION');
    await rejects(svc.deleteAccount({ userId: u.id, confirm: 'evet' }), 400, 'VALIDATION');
    await rejects(svc.deleteAccount({ userId: u.id, confirm: 'sill' }), 400, 'VALIDATION');
    await rejects(svc.deleteAccount({ userId: u.id, password: 'tahmin-parola-1' }), 400, 'INVALID_CREDENTIALS');
    assert.equal(u.account_status, 'active');
    const r = await svc.deleteAccount({ userId: u.id, confirm: ' sil ' });
    assert.equal(r.deleted, true, label);
    assert.equal(u.account_status, 'deleted');
    assert.deepEqual(state.device_audit_logs.at(-1).details.reauth, 'confirm');
  }
  // onay ifadesi varyantları
  for (const word of ['SİL', 'sil', 'Sil', 'SIL', 'sİl', ' SİL ', 'SİL'.normalize('NFD')]) assert.equal(isDeleteConfirmation(word), true, JSON.stringify(word));
  for (const word of ['', 'S', 'SİLL', 'delete', null, undefined, 5, ['SİL']]) assert.equal(isDeleteConfirmation(word), false, String(word));
});

test('sifreli hesap "sifresiz" sayılmaz: password_changed_at dolu, must_change_password veya sosyal kimlik yoksa parola ZORUNLU', async () => {
  const svc = new AccountDeletionService({});
  const cases = [
    h.user({ google_id: 'g-2', password_changed_at: new Date() }), // sosyal ama sonradan parola belirledi
    h.user({}), // sosyal kimliği yok, yer tutucu e-posta yok
    h.user({ google_id: 'g-3', must_change_password: true }),
  ];
  for (const u of cases) {
    assert.equal(isPasswordless(u), false);
    await rejects(svc.deleteAccount({ userId: u.id, confirm: 'SİL' }), 403, 'REAUTH_REQUIRED');
    assert.equal(u.account_status, 'active');
  }
});

test('staff ve super_user hesabını bu uçtan SİLEMEZ (doğru parola ile bile 403); servis PIN oturumu 403; kimliksiz 401', async () => {
  for (const role of ['service_user', 'super_user']) {
    const u = pwUser({ role });
    const r = await api('delete', URL, tokenOf(u), { password: PASSWORD });
    assert.equal(r.status, 403, role);
    assert.equal(r.body.code, 'FORBIDDEN');
    assert.equal(u.account_status, 'active');
    assert.ok(u.email.endsWith('@example.test'), 'anonimleştirilmedi');
  }
  const home = h.home({ name: 'PIN evi' });
  const { session } = h.serviceSession(home);
  assert.equal((await api('delete', URL, env.sessionToken(home, session), { password: PASSWORD })).status, 403);
  assert.equal((await api('delete', URL, null, { password: PASSWORD })).status, 401);
});

test('SOLE_OWNER: tek sahibi olduğu ev varsa 409 + ev listesi (id, name, other_member_count, device_count); hiçbir şey silinmez; ortak sahipli ev engel DEĞİL', async () => {
  const user = pwUser();
  const alone = h.home({ name: 'Yalnız Ev', owner: user });
  const alone2 = h.home({ name: 'Boş Ev', owner: user });
  h.member(alone, h.user(), 'resident');
  h.member(alone, h.user(), 'guest', { valid_until: new Date(Date.now() + 3600e3) });
  h.device(alone);
  h.device(alone);
  const co = h.home({ name: 'Ortak Sahipli' });
  h.member(co, user, 'owner');
  h.member(co, h.user(), 'owner');
  const cred = h.appCredential(alone, user);

  const r = await api('delete', URL, tokenOf(user), { password: PASSWORD });
  assert.equal(r.status, 409, JSON.stringify(r.body));
  assert.equal(r.body.success, false);
  assert.equal(r.body.code, 'SOLE_OWNER');
  assert.ok(r.body.message.includes('devredin'));
  assert.deepEqual(r.body.homes, [
    { id: alone2.id, name: 'Boş Ev', other_member_count: 0, device_count: 0 },
    { id: alone.id, name: 'Yalnız Ev', other_member_count: 2, device_count: 2 },
  ]);
  assert.equal(user.account_status, 'active');
  assert.equal(state.home_users.filter((m) => m.user_id === user.id).length, 3, 'üyelik silinmedi');
  assert.ok(state.mqtt_credentials.includes(cred), 'MQTT kimliği korundu');
  assert.equal(state.device_audit_logs.filter((a) => a.event === 'account_deleted' && a.actor_user_id === user.id).length, 0);

  // devir: sahipliği başka kullanıcıya geçir -> silme başarılı; ortak ev yeni (tek) owner'ı korur
  for (const home of [alone, alone2]) {
    state.home_users.splice(state.home_users.findIndex((m) => m.home_id === home.id && m.user_id === user.id), 1);
    h.member(home, h.user(), 'owner');
  }
  const ok = await api('delete', URL, tokenOf(user), { password: PASSWORD });
  assert.equal(ok.status, 200, JSON.stringify(ok.body));
  assert.equal(ok.body.data.released_memberships, 1, 'yalnız ortak ev üyeliği kaldı');
  assert.equal(state.home_users.filter((m) => m.home_id === co.id && m.role === 'owner').length, 1, 'ortak evin diğer sahibi KALDI');
});

test('push_tokens tablosu henüz yoksa (030 uygulanmadı) silme yine başarılı; tablo varsa token\'lar silinir', async () => {
  world.flags.pushTokensTable = false;
  try {
    const u = pwUser();
    state.push_tokens.push({ id: uid(), user_id: u.id, token: 'kalan', platform: 'ios' });
    const r = await new AccountDeletionService({}).deleteAccount({ userId: u.id, password: PASSWORD });
    assert.equal(r.deleted, true);
    assert.equal(state.push_tokens.filter((x) => x.user_id === u.id).length, 1, 'tablo yoksa dokunulmaz (çökmez)');
  } finally {
    world.flags.pushTokensTable = true;
  }
});

test('ATOMİK: silme ortasında hata olursa hiçbir değişiklik kalmaz (kullanıcı, üyelikler, MQTT kimlikleri, oturumlar)', async () => {
  const t = richUser(pwUser());
  const snapshot = () => JSON.stringify({
    u: t.user, m: state.home_users.length, c: state.mqtt_credentials.map((x) => x.id), r: state.refresh_tokens.length,
    p: state.push_tokens.length, i: state.home_invitations.length, rules: state.scheduled_rules.length, tr: state.home_transfers.map((x) => x.status),
    st: [t.token.revoked_at, t.session.revoked_at], pr: state.password_resets.length, a: state.device_audit_logs.length,
  });
  const before = snapshot();
  // 'refresh_tokens' silme adimi (anonimlestirmeden ONCE) patlar
  const hook = { matcher: (sql) => sql.startsWith('DELETE FROM refresh_tokens'), fn: () => { throw new Error('beklenen test hatası'); } };
  world.db.handlers.unshift(hook);
  try {
    await assert.rejects(new AccountDeletionService({}).deleteAccount({ userId: t.user.id, password: PASSWORD }), /beklenen test hatası/);
  } finally {
    world.db.handlers.splice(world.db.handlers.indexOf(hook), 1);
  }
  assert.equal(snapshot(), before, 'transaction tümüyle geri alındı');
  assert.equal(t.user.account_status, 'active');
  assert.ok(world.db.rollbacks >= 1);
  // hata giderilince silme başarılı
  assert.equal((await new AccountDeletionService({}).deleteAccount({ userId: t.user.id, password: PASSWORD })).deleted, true);
});

test('tüm yazmalar TEK transaction içinde (parola doğrulaması işlem dışı, havuza düşen yazma yok)', async () => {
  const u = pwUser();
  richUser(u);
  const start = world.db.log.length;
  await new AccountDeletionService({}).deleteAccount({ userId: u.id, password: PASSWORD });
  const writes = world.db.log.slice(start).filter((l) => /^(INSERT|UPDATE|DELETE)/.test(l.sql));
  assert.ok(writes.length >= 14);
  assert.deepEqual(writes.filter((l) => l.tx === null).map((l) => l.sql.slice(0, 50)), []);
  assert.equal(new Set(writes.map((l) => l.tx)).size, 1);
  const reads = world.db.log.slice(start).filter((l) => l.sql.includes('password_hash') && l.tx === null);
  assert.equal(reads.length, 1, 'ön okuma (parola doğrulaması) işlem dışı');
});

test('eşzamanlı iki silme isteği: yalnızca biri başarılı olur, ikincisi 404', async () => {
  const u = pwUser();
  richUser(u);
  const results = await Promise.allSettled([1, 2].map(() => new AccountDeletionService({}).deleteAccount({ userId: u.id, password: PASSWORD })));
  assert.equal(results.filter((r) => r.status === 'fulfilled').length, 1);
  const failed = results.find((r) => r.status === 'rejected');
  assert.equal(failed.reason.status, 404);
  assert.equal(state.device_audit_logs.filter((a) => a.event === 'account_deleted' && a.actor_user_id === u.id).length, 1);
});

test('olmayan / zaten silinmiş hesap 404; geçersiz kimlik 403', async () => {
  const svc = new AccountDeletionService({});
  await rejects(svc.deleteAccount({ userId: uid(), password: PASSWORD }), 404, 'NOT_FOUND');
  await rejects(svc.deleteAccount({ userId: 'x', password: PASSWORD }), 403, 'FORBIDDEN');
  await rejects(svc.deleteAccount({}), 403, 'FORBIDDEN');
  const u = pwUser();
  await svc.deleteAccount({ userId: u.id, password: PASSWORD });
  await rejects(svc.deleteAccount({ userId: u.id, password: PASSWORD }), 404, 'NOT_FOUND');
});

test('MQTT bağlantısı atılamazsa silme YİNE başarılı (uyarı döner)', async () => {
  const u = pwUser();
  const home = h.home({ name: 'Kick Evi', owner: h.user() });
  h.member(home, u, 'resident');
  h.appCredential(home, u);
  const svc = new AccountDeletionService({ mqtt: { kickUsernames: async () => ({ kicked: 0, failed: 1, skipped: false }) } });
  const r = await svc.deleteAccount({ userId: u.id, password: PASSWORD });
  assert.equal(r.deleted, true);
  assert.equal(r.warnings.length, 1);
  const svc2 = new AccountDeletionService({ mqtt: { kickUsernames: async () => { throw new Error('ag'); } } });
  const u2 = pwUser();
  h.member(home, u2, 'resident');
  h.appCredential(home, u2);
  assert.equal((await svc2.deleteAccount({ userId: u2.id, password: PASSWORD })).warnings.length, 1);
});

test('silinmiş hesap ASLA oturum açamaz: is_active yanlışlıkla TRUE yapılsa bile oturum/giriş reddedilir (derinlemesine savunma)', async () => {
  const authService = env.SRC('services/auth_service');
  const u = pwUser();
  await new AccountDeletionService({}).deleteAccount({ userId: u.id, password: PASSWORD });
  u.is_active = true; // yönetici "aktifleştir" hatası
  assert.throws(() => authService._assertUserCanSignIn(u), (e) => e.status === 403 && e.code === 'ACCOUNT_DISABLED');
  // erişim jetonu da geçersiz (hesap durumu 'deleted')
  assert.equal((await api('get', '/api/v1/homes', tokenOf(u))).status, 401);
  // yeniden kayıt sonrası aynı e-posta yeni hesaba aittir
  assert.ok(u.email.startsWith('deleted+'));
});

test('HTTP hız sınırı: hesap silme denemeleri kullanıcı başına 15 dk\'da 5; aşımda 429 RATE_LIMITED', async () => {
  const u = pwUser();
  const tok = tokenOf(u);
  const statuses = [];
  for (let i = 0; i < 7; i++) statuses.push((await api('delete', URL, tok, { password: 'yanlis-parola-1' })).status);
  assert.deepEqual(statuses, [400, 400, 400, 400, 400, 429, 429]);
  assert.equal(u.account_status, 'active');
  const limited = await api('delete', URL, tok, { password: PASSWORD });
  assert.equal(limited.status, 429, 'sınır aşıldıktan sonra doğru parola bile geçmez');
  assert.equal(limited.body.code, 'RATE_LIMITED');
});

test('HTTP /api/auth/account takma yolu da çalışır ve yanıt önbelleğe alınmaz', async () => {
  const u = pwUser();
  const r = await api('delete', '/api/auth/account', tokenOf(u), { password: PASSWORD });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.headers['cache-control'], 'no-store');
});
