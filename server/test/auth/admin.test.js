'use strict';

// A7: yonetici kullanici yonetimi.
//  - staff son kullanicinin parolasini DEGISTIREMEZ (yalnizca sifirlama baglantisi)
//  - staff super kullanici detayini goremez; liste created_by kapsamli
//  - kendini / son super kullaniciyi dondurma-dusurme engeli
//  - baska super kullanicinin parolasi icin aktorun mevcut parolasi ile yeniden dogrulama
//  - parola/aktiflik/rol degisince oturumlar iptal; dondurmada MQTT kimlikleri iptal
//  - kalici silme tek transaction; sahipsiz ev olusmaz; constraint sizmaz

const test = require('node:test');
const assert = require('node:assert');
const crypto = require('crypto');
const express = require('express');
const request = require('supertest');
const bcrypt = require('bcryptjs');
const { setTestEnv, installFakeDb, makeAccessToken, makeServiceToken } = require('./_helpers');
const { createAuthStore } = require('./_auth_store');

setTestEnv({ BCRYPT_TEST_COST: '4', ALLOW_DEBUG_OTP: 'true' });
const fakeDb = installFakeDb();
const store = createAuthStore().install(fakeDb);

// ---- yonetim SQL'leri icin ek modeller ----
const memberships = []; // { home_id, user_id, role }
const homes = new Set();
const deleted = { homes: [], users: [] };
let failUserDelete = false;

fakeDb.on(/SELECT COUNT\(\*\)::int AS total FROM users u/, (p, t) => [{ total: listFilter(p, t).length }]);
fakeDb.on(/FROM users u\s+LEFT JOIN users creator/, (p, t) => listFilter(p.slice(0, -2), t).map((u) => ({ ...u })));
fakeDb.on(/SELECT COUNT\(\*\)::int AS n FROM users\s+WHERE role = 'super_user'/, (p) =>
  [{ n: [...store.users.values()].filter((u) => u.role === 'super_user' && u.is_active && u.account_status === 'active' && u.id !== p[0]).length }]);
fakeDb.on(/UPDATE users SET [\s\S]*updated_at = CURRENT_TIMESTAMP WHERE id = \$(\d+)\s+RETURNING/, (p, t) => {
  const m = t.match(/UPDATE users SET ([\s\S]*?)(?:, )?updated_at = CURRENT_TIMESTAMP WHERE id = \$(\d+)/);
  const u = store.users.get(p[Number(m[2]) - 1]);
  if (!u) return [];
  for (const part of m[1].split(/,\s*/).filter(Boolean)) {
    const mm = part.match(/^(\w+) = \$(\d+)$/);
    if (mm) u[mm[1]] = p[Number(mm[2]) - 1];
  }
  return [{ ...u }];
});
fakeDb.on(/UPDATE users SET is_active = FALSE, account_status = 'suspended'/, (p) => {
  const u = store.users.get(p[0]);
  if (u) { u.is_active = false; u.account_status = 'suspended'; }
  return [];
});
fakeDb.on(/SELECT home_id FROM home_users WHERE user_id = \$1/, (p) => memberships.filter((m) => m.user_id === p[0]).map((m) => ({ home_id: m.home_id })));
fakeDb.on(/FROM home_users hu\s+WHERE hu\.user_id = \$1 AND hu\.role = 'owner'/, (p) =>
  memberships.filter((m) => m.user_id === p[0] && m.role === 'owner').map((m) => ({
    home_id: m.home_id,
    other_owners: memberships.filter((o) => o.home_id === m.home_id && o.role === 'owner' && o.user_id !== p[0]).length,
    other_members: memberships.filter((o) => o.home_id === m.home_id && o.user_id !== p[0]).length,
  })));
fakeDb.on(/DELETE FROM homes WHERE id = \$1/, (p) => {
  deleted.homes.push(p[0]);
  for (let i = memberships.length - 1; i >= 0; i--) if (memberships[i].home_id === p[0]) memberships.splice(i, 1);
  return [];
});
fakeDb.on(/DELETE FROM users WHERE id = \$1/, (p) => {
  if (failUserDelete) {
    const e = new Error('update or delete on table "users" violates foreign key constraint "gizli_fk_adi"');
    e.code = '23503';
    return e;
  }
  deleted.users.push(p[0]);
  store.users.delete(p[0]);
  return [];
});
fakeDb.on(/UPDATE (home_invitations SET used_by|home_transfers SET accepted_by|users SET created_by_user_id) = NULL/, () => []);
fakeDb.on(/UPDATE service_tokens SET revoked_at|UPDATE service_sessions SET revoked_at/, () => []);
fakeDb.on(/FROM homes h JOIN home_users hu ON h\.id = hu\.home_id|FROM commissioning_logs cl\s+LEFT JOIN homes h/, () => []);

function listFilter(params, text) {
  let list = [...store.users.values()];
  const roleM = text.match(/u\.role = \$(\d+)/);
  if (roleM) list = list.filter((u) => u.role === params[Number(roleM[1]) - 1]);
  const scope = text.match(/u\.created_by_user_id = \$(\d+)\) OR u\.id = \$(\d+)/);
  if (scope) {
    const staffId = params[Number(scope[1]) - 1];
    list = list.filter((u) => (u.role === 'user' && u.created_by_user_id === staffId) || u.id === staffId);
  }
  return list;
}

const auth = require('../../src/middlewares/auth_middleware');
const adminRoutes = require('../../src/routes/admin_routes');
const adminUserService = require('../../src/services/admin_user_service');
const mailer = require('../../src/utils/mailer');
const { errorHandler } = require('../../src/middlewares/error_handler');

auth.configureAuthMiddleware({ cacheTtlMs: 0 });

const mqttCalls = [];
adminUserService.setMqttCredentialService({
  revokeUserAccess: async ({ homeId, userId, tx }) => { mqttCalls.push(['user', homeId, userId, Boolean(tx)]); return { revoked: 1, usernames: [`a_${homeId}_${userId}`] }; },
  revokeHomeAccess: async ({ homeId, includeDevice, tx }) => { mqttCalls.push(['home', homeId, includeDevice, Boolean(tx)]); return { revoked: 1, usernames: [`d_${homeId}`] }; },
  kickUsernames: async (names) => { mqttCalls.push(['kick', names]); return { kicked: names.length, failed: 0, skipped: false }; },
});
const sentMails = [];
mailer.setTransportFactory(() => ({ sendMail: async (m) => { sentMails.push(m); } }));

const app = express();
app.use(express.json());
app.use('/api/v1/admin', adminRoutes);
app.use(errorHandler);

const PW = 'Yonetici-Parola-1';
const hash = bcrypt.hashSync(PW, 4);
const super1 = store.addUser({ role: 'super_user', email: 'super1@example.com', password_hash: hash, email_verified: true });
const staff = store.addUser({ role: 'service_user', email: 'staff@example.com', password_hash: hash });
const staff2 = store.addUser({ role: 'service_user', email: 'staff2@example.com', password_hash: hash });
const staffUser = store.addUser({ role: 'user', email: 'musteri@example.com', created_by_user_id: staff.id, password_hash: hash });
const foreignUser = store.addUser({ role: 'user', email: 'yabanci@example.com', created_by_user_id: staff2.id, password_hash: hash });
const plain = store.addUser({ role: 'user', email: 'sade@example.com', password_hash: hash });

const T = (u) => `Bearer ${makeAccessToken(store.users.get(u.id) || u)}`;
const api = (method, path, who, body) => {
  const r = request(app)[method](`/api/v1/admin${path}`).set('Authorization', who);
  return body ? r.send(body) : r;
};

test.beforeEach(() => {
  mqttCalls.length = 0;
  failUserDelete = false;
});

test('erisim: duz kullanici HER admin ucunda 403 (yabanci kullanici)', async () => {
  const id = staffUser.id;
  const endpoints = [
    ['get', '/users'], ['post', '/users', { full_name: 'A B', email: 'ab@example.com' }], ['get', `/users/${id}`],
    ['patch', `/users/${id}`, { full_name: 'X Y' }], ['post', `/users/${id}/send-reset`], ['delete', `/users/${id}`],
    ['get', '/service-summary'],
  ];
  for (const [m, p, b] of endpoints) {
    const r = await api(m, p, T(plain), b);
    assert.strictEqual(r.status, 403, `${m} ${p}`);
    assert.strictEqual(r.body.code, 'FORBIDDEN');
  }
  assert.strictEqual(store.users.get(id).full_name !== 'X Y', true);
});

test('erisim: duz kullanici / servis oturumu / tokensiz -> 401/403', async () => {
  assert.strictEqual((await request(app).get('/api/v1/admin/users')).status, 401);
  assert.strictEqual((await api('get', '/users', T(plain))).status, 403);
  const svc = `Bearer ${makeServiceToken({ sid: crypto.randomUUID(), home_id: crypto.randomUUID() })}`;
  store.addUser(); // yer tutucu
  assert.ok([401, 403].includes((await api('get', '/users', svc)).status));
  assert.strictEqual((await api('get', '/service-summary', T(staff))).status, 403);
});

test('liste: staff yalnizca kendi olusturdugu son kullanicilari (+ kendisini) gorur', async () => {
  const r = await api('get', '/users', T(staff));
  assert.strictEqual(r.status, 200);
  const ids = r.body.data.users.map((u) => u.id).sort();
  assert.deepStrictEqual(ids, [staff.id, staffUser.id].sort());
  const all = await api('get', '/users', T(super1));
  assert.ok(all.body.data.users.length >= 6);
});

test('detay: staff super kullaniciyi ve kapsam disi kullaniciyi GOREMEZ (404)', async () => {
  assert.strictEqual((await api('get', `/users/${super1.id}`, T(staff))).status, 404);
  assert.strictEqual((await api('get', `/users/${foreignUser.id}`, T(staff))).status, 404);
  assert.strictEqual((await api('get', `/users/${staffUser.id}`, T(staff))).status, 200);
  assert.strictEqual((await api('get', `/users/${super1.id}`, T(super1))).status, 200);
});

test('olusturma: staff parola BELIRLEYEMEZ; parolasiz -> pending_invite + etkinlestirme e-postasi', async () => {
  const withPw = await api('post', '/users', T(staff), { full_name: 'Yeni Musteri', email: 'yeni.musteri@example.com', password: 'Staff-Bildigi-1' });
  assert.strictEqual(withPw.status, 403);
  const before = sentMails.length;
  const ok = await api('post', '/users', T(staff), { full_name: 'Yeni Musteri', email: 'yeni.musteri@example.com' });
  assert.strictEqual(ok.status, 201, JSON.stringify(ok.body));
  assert.strictEqual(ok.body.data.account_status, 'pending_invite');
  assert.strictEqual(ok.body.data.invite_sent, true);
  assert.strictEqual(sentMails.length, before + 1);
  const created = [...store.users.values()].find((u) => u.email === 'yeni.musteri@example.com');
  assert.strictEqual(created.created_by_user_id, staff.id);
  assert.ok(!(await bcrypt.compare('Staff-Bildigi-1', created.password_hash)));
  // staff baska rol olusturamaz
  assert.strictEqual((await api('post', '/users', T(staff), { full_name: 'X Y', email: 'x.staff@example.com', role: 'service_user' })).status, 403);
});

test('olusturma: super parola verirse ilk giriste degistirme zorunlu; parola politikasi uygulanir; cift e-posta 409', async () => {
  assert.strictEqual((await api('post', '/users', T(super1), { full_name: 'Kisa Parola', email: 'kisa.p@example.com', password: 'kisa' })).status, 400);
  const r = await api('post', '/users', T(super1), { full_name: 'Personel Bir', email: 'personel1@example.com', password: 'Gecici-Parola-2026', role: 'service_user' });
  assert.strictEqual(r.status, 201);
  assert.strictEqual(r.body.data.must_change_password, true);
  assert.strictEqual(r.body.data.account_status, 'active');
  assert.strictEqual((await api('post', '/users', T(super1), { full_name: 'Personel Bir', email: 'PERSONEL1@example.com' })).status, 409);
});

test('guncelleme: staff parola/rol DEGISTIREMEZ, kapsam disi kullanici 404; ad/telefon degisebilir', async () => {
  assert.strictEqual((await api('patch', `/users/${staffUser.id}`, T(staff), { password: 'Yeni-Parola-2026' })).status, 403);
  assert.strictEqual((await api('patch', `/users/${staffUser.id}`, T(staff), { role: 'service_user' })).status, 403);
  assert.strictEqual((await api('patch', `/users/${foreignUser.id}`, T(staff), { full_name: 'Degisti' })).status, 404);
  const ok = await api('patch', `/users/${staffUser.id}`, T(staff), { full_name: 'Musteri Yeni Ad', phone: '+905551119988' });
  assert.strictEqual(ok.status, 200, JSON.stringify(ok.body));
  assert.strictEqual(store.users.get(staffUser.id).full_name, 'Musteri Yeni Ad');
});

test('sifirlama baglantisi: staff kendi kullanicisina gonderebilir; super kullaniciya/kapsam disina 404', async () => {
  const before = sentMails.length;
  const r = await api('post', `/users/${staffUser.id}/send-reset`, T(staff));
  assert.strictEqual(r.status, 200, JSON.stringify(r.body));
  assert.strictEqual(sentMails.length, before + 1);
  assert.strictEqual((await api('post', `/users/${super1.id}/send-reset`, T(staff))).status, 404);
  assert.strictEqual((await api('post', `/users/${foreignUser.id}/send-reset`, T(staff))).status, 404);
});

test('super: kendini donduramaz / rolunu dusuremez / admin ekranindan kendi parolasini degistiremez', async () => {
  assert.strictEqual((await api('patch', `/users/${super1.id}`, T(super1), { is_active: false })).status, 400);
  assert.strictEqual((await api('patch', `/users/${super1.id}`, T(super1), { role: 'user' })).status, 400);
  assert.strictEqual((await api('patch', `/users/${super1.id}`, T(super1), { password: 'Yeni-Parola-2026' })).status, 400);
  assert.strictEqual((await api('delete', `/users/${super1.id}`, T(super1))).status, 400);
});

test('son aktif super kullanici dondurulamaz / dusurulemez / silinemez (409); baska aktif super varsa izinli', async () => {
  const superB = store.addUser({ role: 'super_user', email: 'superb@example.com', password_hash: hash });
  const activeSupers = () => [...store.users.values()].filter((u) => u.role === 'super_user' && u.is_active);
  // Yalnizca super1 (aktor) ve superB aktif.
  const others = activeSupers().filter((u) => u.id !== super1.id && u.id !== superB.id);
  others.forEach((u) => { u.is_active = false; });

  // super1 aktif kaldigi icin superB dondurulabilir.
  assert.strictEqual((await api('patch', `/users/${superB.id}`, T(super1), { is_active: false })).status, 200);
  store.users.get(superB.id).is_active = true;
  store.users.get(superB.id).account_status = 'active';

  // super1 pasif olursa superB SON aktif superdir: dondurma / rol dusurme / silme 409.
  // (Pasif aktorun token'i gecersiz oldugundan servis katmani dogrudan sinanir.)
  store.users.get(super1.id).is_active = false;
  const actor = { id: super1.id, role: 'super_user' };
  await assert.rejects(adminUserService.updateUser(superB.id, { is_active: false, currentUser: actor }), (e) => e.status === 409);
  await assert.rejects(adminUserService.updateUser(superB.id, { role: 'user', currentUser: actor }), (e) => e.status === 409);
  await assert.rejects(adminUserService.deleteUser(superB.id, { currentUser: actor }), (e) => e.status === 409);
  await assert.rejects(adminUserService.deleteUser(superB.id, { currentUser: actor, hardDelete: true }), (e) => e.status === 409);
  assert.strictEqual(store.users.get(superB.id).is_active, true);
  assert.strictEqual(store.users.get(superB.id).role, 'super_user');

  store.users.get(super1.id).is_active = true;
  others.forEach((u) => { u.is_active = true; });
});

test('baska super kullanicinin parolasi: aktorun mevcut parolasi ile yeniden dogrulama sart', async () => {
  const target = store.addUser({ role: 'super_user', email: 'hedef.super@example.com', password_hash: hash });
  const noReauth = await api('patch', `/users/${target.id}`, T(super1), { password: 'Yeni-Super-Parola-1' });
  assert.strictEqual(noReauth.status, 403);
  assert.strictEqual(noReauth.body.code, 'REAUTH_REQUIRED');
  const wrong = await api('patch', `/users/${target.id}`, T(super1), { password: 'Yeni-Super-Parola-1', current_password: 'yanlis-parola-1' });
  assert.strictEqual(wrong.status, 403);
  const ok = await api('patch', `/users/${target.id}`, T(super1), { password: 'Yeni-Super-Parola-1', current_password: PW });
  assert.strictEqual(ok.status, 200, JSON.stringify(ok.body));
  const u = store.users.get(target.id);
  assert.ok(await bcrypt.compare('Yeni-Super-Parola-1', u.password_hash));
  assert.strictEqual(u.must_change_password, true);
  assert.ok(u.token_version >= 2, 'oturumlar iptal (tv++)');
});

test('super baska kullaniciya parola atar -> oturumlari iptal, ilk giriste degistirme zorunlu', async () => {
  const u0 = store.addUser({ email: 'parola.atanan@example.com', password_hash: hash });
  store.refresh.push({ id: crypto.randomUUID(), user_id: u0.id, token_hash: 'rt', family_id: crypto.randomUUID(), expires_at: new Date(Date.now() + 1e9), used_at: null, revoked_at: null });
  const r = await api('patch', `/users/${u0.id}`, T(super1), { password: 'Atanan-Parola-2026' });
  assert.strictEqual(r.status, 200);
  assert.strictEqual(store.users.get(u0.id).must_change_password, true);
  assert.ok(store.refresh.find((x) => x.token_hash === 'rt').revoked_at);
});

test('dondurma (soft delete / is_active=false): oturumlar + TUM evlerdeki MQTT kimlikleri iptal', async () => {
  const u1 = store.addUser({ email: 'dondur@example.com', password_hash: hash, created_by_user_id: staff.id });
  memberships.push({ home_id: 'ev-1', user_id: u1.id, role: 'resident' }, { home_id: 'ev-2', user_id: u1.id, role: 'guest' });
  const tvBefore = store.users.get(u1.id).token_version;
  const r = await api('delete', `/users/${u1.id}`, T(staff));
  assert.strictEqual(r.status, 200, JSON.stringify(r.body));
  const u = store.users.get(u1.id);
  assert.strictEqual(u.is_active, false);
  assert.strictEqual(u.account_status, 'suspended');
  assert.strictEqual(u.token_version, tvBefore + 1);
  assert.deepStrictEqual(mqttCalls.filter((c) => c[0] === 'user').map((c) => [c[1], c[3]]), [['ev-1', true], ['ev-2', true]]);
  assert.deepStrictEqual(mqttCalls.find((c) => c[0] === 'kick')[1].sort(), [`a_ev-1_${u1.id}`, `a_ev-2_${u1.id}`].sort());
});

// ---- S1 (plan §5d-1): oturumlar toplu iptal edilince push belirteci de COMMIT SONRASI kapanir ----
test('push belirteci gizliligi: parola atama / rol degisimi / dondurma / pasife alma -> belirtecler kapanir; yalniz ad degisimi dokunmaz', async () => {
  const authService = require('../../src/services/auth_service');
  authService.setPushService(undefined); // varsayilan: veritabani tabanli ornek (FCM'den bagimsiz)
  const mk = (email) => {
    const u = store.addUser({ email, password_hash: hash, created_by_user_id: staff.id });
    return { u, tok: store.addPushToken(u.id) };
  };
  const tx = () => fakeDb.calls.map((c, i) => [c.text, i]);
  const pushIdx = () => tx().filter(([t]) => /UPDATE push_tokens SET disabled_at/.test(t)).map(([, i]) => i);

  // 1) yalniz ad: oturum iptali yok -> belirtec KALIR
  const a = mk('push.ad@example.com');
  fakeDb.calls.length = 0;
  assert.strictEqual((await api('patch', `/users/${a.u.id}`, T(super1), { full_name: 'Sadece Ad Degisti' })).status, 200);
  assert.ok(!a.tok.disabled_at);
  assert.strictEqual(pushIdx().length, 0);

  // 2) super parola atar -> oturumlar + belirtec kapanir; COMMIT'ten SONRA
  const b = mk('push.parola@example.com');
  fakeDb.calls.length = 0;
  assert.strictEqual((await api('patch', `/users/${b.u.id}`, T(super1), { password: 'Atanan-Parola-2026' })).status, 200);
  assert.ok(b.tok.disabled_at, 'parola atama belirteci kapatmali');
  assert.strictEqual(pushIdx().length, 1);
  assert.ok(pushIdx()[0] > fakeDb.calls.findIndex((c) => c.text === 'COMMIT'), 'COMMIT sonrasi');

  // 3) rol degisimi
  const c = mk('push.rol@example.com');
  assert.strictEqual((await api('patch', `/users/${c.u.id}`, T(super1), { role: 'service_user' })).status, 200);
  assert.ok(c.tok.disabled_at, 'rol degisimi belirteci kapatmali');

  // 4) dondurma (is_active=false)
  const d = mk('push.dondur@example.com');
  assert.strictEqual((await api('patch', `/users/${d.u.id}`, T(super1), { is_active: false })).status, 200);
  assert.ok(d.tok.disabled_at, 'dondurma belirteci kapatmali');

  // 5) pasife alma (soft delete)
  const e = mk('push.pasif@example.com');
  assert.strictEqual((await api('delete', `/users/${e.u.id}`, T(staff))).status, 200);
  assert.ok(e.tok.disabled_at, 'pasife alma belirteci kapatmali');

  // 6) kalici silme: kullanici satiri gider (push_tokens FK CASCADE); ek devre disi birakma sorgusu gerekmez
  const f2 = mk('push.kalici@example.com');
  fakeDb.calls.length = 0;
  assert.strictEqual((await api('delete', `/users/${f2.u.id}?hard=true`, T(super1))).status, 200);
  assert.strictEqual(pushIdx().length, 0);
});

test('push belirteci gizliligi: push hatasi/modul yoklugu admin islemini BOZMAZ (200, oturumlar yine iptal)', async () => {
  const authService = require('../../src/services/auth_service');
  const warn = console.warn;
  const warned = [];
  console.warn = (...a) => warned.push(a.join(' '));
  try {
    authService.setPushService({ disableAllTokensForUser: async () => { throw Object.assign(new Error('gizli-ayrinti-123'), { code: 'XX000' }); } });
    const u1 = store.addUser({ email: 'push.hata.admin@example.com', password_hash: hash, created_by_user_id: staff.id });
    store.refresh.push({ id: crypto.randomUUID(), user_id: u1.id, token_hash: 'rt-push-hata', family_id: crypto.randomUUID(), expires_at: new Date(Date.now() + 1e9), used_at: null, revoked_at: null });
    const r = await api('patch', `/users/${u1.id}`, T(super1), { is_active: false });
    assert.strictEqual(r.status, 200, JSON.stringify(r.body));
    assert.ok(store.refresh.find((x) => x.token_hash === 'rt-push-hata').revoked_at, 'oturum iptali bozulmamali');
    assert.strictEqual(warned.length, 1);
    assert.ok(!warned[0].includes('gizli-ayrinti-123'));

    authService.setPushService(null); // modul yok: sessiz
    const u2 = store.addUser({ email: 'push.yok.admin@example.com', password_hash: hash, created_by_user_id: staff.id });
    assert.strictEqual((await api('delete', `/users/${u2.id}`, T(staff))).status, 200);
    assert.strictEqual(warned.length, 1, 'modul yokken uyari de yok');
  } finally {
    console.warn = warn;
    authService.setPushService(undefined);
  }
});

test('kalici silme: yalnizca super; staff 403', async () => {
  const u2 = store.addUser({ email: 'kalici.staff@example.com', created_by_user_id: staff.id });
  assert.strictEqual((await api('delete', `/users/${u2.id}?hard=true`, T(staff))).status, 403);
});

test('kalici silme: baska uyeli evin TEK sahibi ise 409 (sahipsiz ev olusmaz)', async () => {
  const u3 = store.addUser({ email: 'tek.sahip@example.com' });
  memberships.push({ home_id: 'ev-3', user_id: u3.id, role: 'owner' }, { home_id: 'ev-3', user_id: 'baska-uye', role: 'resident' });
  const r = await api('delete', `/users/${u3.id}?hard=true`, T(super1));
  assert.strictEqual(r.status, 409);
  assert.ok(store.users.has(u3.id));
  assert.ok(fakeDb.rollbacks > 0);
});

test('kalici silme: tek uyesi oldugu ev silinir, MQTT (ev + kullanici) iptal ve kick, kullanici silinir', async () => {
  const u4 = store.addUser({ email: 'silinecek@example.com' });
  memberships.push({ home_id: 'ev-4', user_id: u4.id, role: 'owner' }, { home_id: 'ev-5', user_id: u4.id, role: 'resident' });
  const r = await api('delete', `/users/${u4.id}?hard=true`, T(super1));
  assert.strictEqual(r.status, 200, JSON.stringify(r.body));
  assert.ok(!store.users.has(u4.id));
  assert.ok(deleted.homes.includes('ev-4'));
  assert.ok(!deleted.homes.includes('ev-5'));
  assert.ok(mqttCalls.some((c) => c[0] === 'home' && c[1] === 'ev-4' && c[2] === true && c[3] === true));
  assert.ok(mqttCalls.some((c) => c[0] === 'user' && c[1] === 'ev-5'));
  assert.ok(mqttCalls.some((c) => c[0] === 'kick'));
});

test('kalici silme: FK hatasi -> 409 genel mesaj (constraint adi SIZMAZ)', async () => {
  const u5 = store.addUser({ email: 'fk@example.com' });
  failUserDelete = true;
  const r = await api('delete', `/users/${u5.id}?hard=true`, T(super1));
  assert.strictEqual(r.status, 409);
  assert.ok(!JSON.stringify(r.body).includes('gizli_fk_adi'));
});

test('servis ozeti yalnizca super', async () => {
  fakeDb.on(/FROM users\s*$/, () => [{ total_users: 3 }]);
  const r = await api('get', '/service-summary', T(super1));
  assert.strictEqual(r.status, 200);
});
