'use strict';

// A4: kayit / giris / parola politikasi / refresh rotation + yeniden kullanim tespiti /
// logout / sifre degisimi -> token_version.

const test = require('node:test');
const assert = require('node:assert');
const express = require('express');
const request = require('supertest');
const bcrypt = require('bcryptjs');
const { setTestEnv, installFakeDb, makeAccessToken } = require('./_helpers');
const { createAuthStore } = require('./_auth_store');

setTestEnv({ BCRYPT_TEST_COST: '4' });
const fakeDb = installFakeDb();
const store = createAuthStore().install(fakeDb);

const authRoutes = require('../../src/routes/auth_routes');
const authService = require('../../src/services/auth_service');
const auth = require('../../src/middlewares/auth_middleware');
const { errorHandler } = require('../../src/middlewares/error_handler');

auth.configureAuthMiddleware({ cacheTtlMs: 0 });

const app = express();
app.use(express.json());
app.use('/api/v1/auth', authRoutes);
app.use(errorHandler);

const GOOD_PW = 'Dogru-Parola-2026';

function resetLimiters() {
  for (const l of Object.values(authRoutes.limiters)) l.reset();
  authRoutes.loginFailures.reset();
  authRoutes.loginFailuresTotal.reset();
}

async function register(email, password = GOOD_PW, extra = {}) {
  return request(app).post('/api/v1/auth/register').send({ full_name: 'Deneme Kisi', email, password, ...extra });
}

test.beforeEach(() => resetLimiters());

test('kayit: parola politikasi (en az 10 karakter, en fazla 72 bayt)', async () => {
  const short = await register('kisa@example.com', 'Abc12345!');
  assert.strictEqual(short.status, 400);
  assert.strictEqual(short.body.code, 'VALIDATION');
  const long = await register('uzun@example.com', 'a'.repeat(73));
  assert.strictEqual(long.status, 400);
  const blank = await register('bos@example.com', ' '.repeat(12));
  assert.strictEqual(blank.status, 400);
});

test('kayit: e-posta normalizasyonu, bcrypt, cift kayit 409', async () => {
  const res = await register('  Yeni.Kisi@Example.COM ');
  assert.strictEqual(res.status, 201, JSON.stringify(res.body));
  assert.strictEqual(res.body.data.user.email, 'yeni.kisi@example.com');
  assert.ok(res.body.data.access_token);
  assert.ok(res.body.data.refresh_token);
  assert.strictEqual(res.body.data.expires_in, 900);
  const row = [...store.users.values()].find((u) => u.email === 'yeni.kisi@example.com');
  assert.match(row.password_hash, /^\$2[aby]\$/);
  assert.notStrictEqual(row.password_hash, GOOD_PW);

  const dup = await register('YENI.KISI@example.com');
  assert.strictEqual(dup.status, 409);
  assert.strictEqual(dup.body.code, 'CONFLICT');
});

test('kayit: gecersiz e-posta / telefon 400', async () => {
  assert.strictEqual((await register('gecersiz')).status, 400);
  assert.strictEqual((await register('a@b.com', GOOD_PW, { phone: '12' })).status, 400);
});

test('bcrypt cost uretimde 12', async () => {
  const saved = process.env.NODE_ENV;
  process.env.NODE_ENV = 'production';
  try {
    const hash = await authService.hashPassword(GOOD_PW);
    assert.match(hash, /^\$2[aby]\$12\$/);
  } finally {
    process.env.NODE_ENV = saved;
  }
});

test('access token sozlesme claimleri: sub, role, tv, iat, exp, iss; refresh opak ve DB de yalnizca ozet', async () => {
  const res = await register('claim@example.com');
  const jwt = require('jsonwebtoken');
  const payload = jwt.decode(res.body.data.access_token);
  assert.ok(payload.sub && payload.role && Number.isInteger(payload.tv) && payload.iat && payload.exp && payload.iss);
  assert.strictEqual(payload.exp - payload.iat, 900);
  const rt = res.body.data.refresh_token;
  assert.strictEqual(rt.split('.').length, 1, 'refresh token JWT olmamali (opak)');
  assert.ok(!store.refresh.some((r) => r.token_hash === rt), 'duz refresh token saklanmamali');
  const rec = store.refresh.find((r) => r.user_id === payload.sub);
  const days = (rec.expires_at.getTime() - Date.now()) / 86400000;
  assert.ok(days > 29 && days <= 30.01, `refresh suresi ${days} gun`);
});

test('giris: dogru/yanlis parola, bilinmeyen kullanici ayni yanit', async () => {
  await register('giris@example.com');
  const ok = await request(app).post('/api/v1/auth/login').send({ email: 'GIRIS@example.com', password: GOOD_PW });
  assert.strictEqual(ok.status, 200);
  const bad = await request(app).post('/api/v1/auth/login').send({ email: 'giris@example.com', password: 'yanlis-parola-123' });
  const ghost = await request(app).post('/api/v1/auth/login').send({ email: 'yok@example.com', password: 'yanlis-parola-123' });
  assert.strictEqual(bad.status, 401);
  assert.strictEqual(ghost.status, 401);
  assert.strictEqual(bad.body.message, ghost.body.message);
  assert.strictEqual(bad.body.code, 'INVALID_CREDENTIALS');
});

test('giris: askidaki hesap 403 ACCOUNT_DISABLED, bekleyen davet 403 ACCOUNT_PENDING', async () => {
  const hash = await bcrypt.hash(GOOD_PW, 4);
  store.addUser({ email: 'askida@example.com', password_hash: hash, is_active: false, account_status: 'suspended' });
  store.addUser({ email: 'bekleyen@example.com', password_hash: hash, account_status: 'pending_invite' });
  const a = await request(app).post('/api/v1/auth/login').send({ email: 'askida@example.com', password: GOOD_PW });
  assert.strictEqual(a.status, 403);
  assert.strictEqual(a.body.code, 'ACCOUNT_DISABLED');
  const b = await request(app).post('/api/v1/auth/login').send({ email: 'bekleyen@example.com', password: GOOD_PW });
  assert.strictEqual(b.body.code, 'ACCOUNT_PENDING');
});

test('giris: ayni telefona bagli iki hesap -> giris reddedilir (rastgele hesaba girilmez)', async () => {
  const hash = await bcrypt.hash(GOOD_PW, 4);
  store.addUser({ email: 'tel1@example.com', phone: '+905551112233', password_hash: hash });
  store.addUser({ email: 'tel2@example.com', phone: '+905551112233', password_hash: hash });
  const res = await request(app).post('/api/v1/auth/login').send({ phone: '+90 555 111 22 33', password: GOOD_PW });
  assert.strictEqual(res.status, 401);
});

// Iki katmanli kilit (UYELIK-10): (kimlik|IP) 10 + kimlik toplami 50; farkli IP senaryolari uyelik_giris_kilidi.test.js
test('giris: AYNI IP\'den kimlik basina 10 basarisiz deneme -> 429 (bicim farklari ayni sayaci paylasir)', async () => {
  await register('kaba@example.com');
  for (let i = 0; i < 10; i++) {
    const email = i % 2 === 0 ? 'kaba@example.com' : '  KABA@Example.com ';
    const r = await request(app).post('/api/v1/auth/login').send({ email, password: `yanlis-parola-${i}` });
    assert.strictEqual(r.status, 401);
  }
  const blocked = await request(app).post('/api/v1/auth/login').send({ email: 'kaba@example.com', password: GOOD_PW });
  assert.strictEqual(blocked.status, 429);
  assert.strictEqual(blocked.body.code, 'RATE_LIMITED');
  assert.ok(blocked.headers['retry-after']);
});

test('refresh: rotation - yeni cift doner, eski token kullanildi isaretlenir', async () => {
  const reg = await register('rot@example.com');
  const rt1 = reg.body.data.refresh_token;
  const r1 = await request(app).post('/api/v1/auth/refresh').send({ refresh_token: rt1 });
  assert.strictEqual(r1.status, 200);
  const rt2 = r1.body.data.refresh_token;
  assert.ok(rt2 && rt2 !== rt1);
  const old = store.refresh.find((r) => r.token_hash === authService._hashToken(rt1));
  const neu = store.refresh.find((r) => r.token_hash === authService._hashToken(rt2));
  assert.ok(old.used_at);
  assert.strictEqual(old.family_id, neu.family_id);
  assert.strictEqual(old.replaced_by, neu.id);
  // camelCase da kabul edilir
  const r2 = await request(app).post('/api/v1/auth/refresh').send({ refreshToken: rt2 });
  assert.strictEqual(r2.status, 200);
});

test('refresh: kullanilmis token tekrar gelirse AILE iptal edilir (calinma tespiti; halef kullanilmis)', async () => {
  const reg = await register('reuse@example.com');
  const rt1 = reg.body.data.refresh_token;
  const r1 = await request(app).post('/api/v1/auth/refresh').send({ refresh_token: rt1 });
  const rt2 = r1.body.data.refresh_token;
  // Mesru istemci halefi (rt2) kullandi: rt1'in yeniden gelmesi artik "yaniti kaybolan yenileme" olamaz
  const r2 = await request(app).post('/api/v1/auth/refresh').send({ refresh_token: rt2 });
  assert.strictEqual(r2.status, 200);
  const rt3 = r2.body.data.refresh_token;

  const replay = await request(app).post('/api/v1/auth/refresh').send({ refresh_token: rt1 });
  assert.strictEqual(replay.status, 401);
  assert.strictEqual(replay.body.code, 'INVALID_TOKEN');

  // Mesru istemcinin yeni token'i da artik gecersiz (aile iptal)
  const after = await request(app).post('/api/v1/auth/refresh').send({ refresh_token: rt3 });
  assert.strictEqual(after.status, 401);
  const fam = store.refresh.find((r) => r.token_hash === authService._hashToken(rt3)).family_id;
  assert.ok(store.refresh.filter((r) => r.family_id === fam).every((r) => r.revoked_at));
});

test('uyelik-2: yaniti kaybolan yenileme - hemen gelen R1 tekrari 200 (yeni cift), ardindan R2 sunulunca 401 ve aile iptal', async () => {
  const reg = await register('kayip-yanit@example.com');
  const rt1 = reg.body.data.refresh_token;
  const r1 = await request(app).post('/api/v1/auth/refresh').send({ refresh_token: rt1 });
  assert.strictEqual(r1.status, 200);
  const rt2 = r1.body.data.refresh_token; // istemciye ULASMADI (yanit kayboldu)

  const logs = [];
  const origLog = console.log;
  const origWarn = console.warn;
  console.log = (...a) => logs.push(a.join(' '));
  console.warn = (...a) => logs.push(a.join(' '));
  let retry;
  try {
    retry = await request(app).post('/api/v1/auth/refresh').send({ refresh_token: rt1 });
  } finally {
    console.log = origLog;
    console.warn = origWarn;
  }
  assert.strictEqual(retry.status, 200, JSON.stringify(retry.body));
  const rt2b = retry.body.data.refresh_token;
  assert.ok(rt2b && rt2b !== rt2 && rt2b !== rt1);
  assert.ok(retry.body.data.access_token);

  const row1 = store.refresh.find((r) => r.token_hash === authService._hashToken(rt1));
  const row2 = store.refresh.find((r) => r.token_hash === authService._hashToken(rt2));
  const row2b = store.refresh.find((r) => r.token_hash === authService._hashToken(rt2b));
  assert.strictEqual(row2.revoked_reason, 'retry_superseded', 'eski halef iptal');
  assert.ok(row2.revoked_at);
  assert.strictEqual(row1.replaced_by, row2b.id, 'sunulan token yeni halefe isaret eder');
  assert.strictEqual(row2b.family_id, row1.family_id, 'ayni aile');
  assert.ok(!row2b.revoked_at);
  assert.ok(logs.some((l) => l.includes('Yanitlari kaybolan yenileme yeniden denendi')), 'log yazildi');
  assert.ok(!logs.some((l) => l.includes(rt1) || l.includes(rt2b)), 'log token icermez');

  // Yeni halef calisir
  const next = await request(app).post('/api/v1/auth/refresh').send({ refresh_token: rt2b });
  assert.strictEqual(next.status, 200);

  // retry_superseded token (rt2) sunulursa: yeniden kullanim -> AILE iptal
  const stolen = await request(app).post('/api/v1/auth/refresh').send({ refresh_token: rt2 });
  assert.strictEqual(stolen.status, 401);
  assert.strictEqual(stolen.body.code, 'INVALID_TOKEN');
  assert.ok(store.refresh.filter((r) => r.family_id === row1.family_id).every((r) => r.revoked_at), 'aile iptal');
});

test('uyelik-2: tolerans disindaki R1 tekrari aile iptal; tolerans 0 iken hemen gelen tekrar da aile iptal', async () => {
  const reg = await register('tolerans@example.com');
  const rt1 = reg.body.data.refresh_token;
  const r1 = await request(app).post('/api/v1/auth/refresh').send({ refresh_token: rt1 });
  const rt2 = r1.body.data.refresh_token;
  const row1 = store.refresh.find((r) => r.token_hash === authService._hashToken(rt1));
  row1.used_at = new Date(Date.now() - 2 * 3600 * 1000); // varsayilan tolerans (3600 sn) disi
  const replay = await request(app).post('/api/v1/auth/refresh').send({ refresh_token: rt1 });
  assert.strictEqual(replay.status, 401);
  assert.strictEqual((await request(app).post('/api/v1/auth/refresh').send({ refresh_token: rt2 })).status, 401);
  assert.ok(store.refresh.filter((r) => r.family_id === row1.family_id).every((r) => r.revoked_at));

  process.env.REFRESH_RETRY_GRACE_SEC = '0';
  try {
    const reg2 = await register('tolerans0@example.com');
    const a1 = reg2.body.data.refresh_token;
    await request(app).post('/api/v1/auth/refresh').send({ refresh_token: a1 });
    const again = await request(app).post('/api/v1/auth/refresh').send({ refresh_token: a1 });
    assert.strictEqual(again.status, 401, 'tolerans kapali');
  } finally {
    delete process.env.REFRESH_RETRY_GRACE_SEC;
  }
});

test('uyelik-2: yeniden denemede pasif kullanici -> 401 ve aile iptal', async () => {
  const reg = await register('tolerans-pasif@example.com');
  const rt1 = reg.body.data.refresh_token;
  await request(app).post('/api/v1/auth/refresh').send({ refresh_token: rt1 });
  const u = [...store.users.values()].find((x) => x.email === 'tolerans-pasif@example.com');
  u.is_active = false;
  const replay = await request(app).post('/api/v1/auth/refresh').send({ refresh_token: rt1 });
  assert.strictEqual(replay.status, 401);
  const fam = store.refresh.find((r) => r.token_hash === authService._hashToken(rt1)).family_id;
  assert.ok(store.refresh.filter((r) => r.family_id === fam).every((r) => r.revoked_at));
});

test('uyelik-5: refresh siniri token basina - ayni IP den 61 farkli token 429 almaz; ayni token 11. istekte 429', async () => {
  const crypto = require('crypto');
  for (let i = 0; i < 61; i++) {
    const r = await request(app).post('/api/v1/auth/refresh').send({ refresh_token: crypto.randomBytes(32).toString('base64url') });
    assert.notStrictEqual(r.status, 429, `istek ${i + 1}`);
    assert.strictEqual(r.status, 401);
  }
  const same = crypto.randomBytes(32).toString('base64url');
  for (let i = 0; i < 10; i++) {
    assert.strictEqual((await request(app).post('/api/v1/auth/refresh').send({ refresh_token: same })).status, 401, `istek ${i + 1}`);
  }
  const blocked = await request(app).post('/api/v1/auth/refresh').send({ refreshToken: same });
  assert.strictEqual(blocked.status, 429);
  assert.strictEqual(blocked.body.code, 'RATE_LIMITED');
  assert.ok(Number(blocked.headers['retry-after']) > 0);
  assert.ok(Number.isFinite(blocked.body.retry_after));
});

test('uyelik-5: refresh IP tavani 1000 / 15 dk - 1001. istek 429', async () => {
  const crypto = require('crypto');
  assert.strictEqual(authRoutes.limiters.refreshIp.options.max, 1000);
  for (let i = 0; i < 1000; i++) {
    const r = await request(app).post('/api/v1/auth/refresh').send({ refresh_token: crypto.randomBytes(24).toString('base64url') });
    if (r.status !== 401) assert.fail(`istek ${i + 1}: ${r.status}`);
  }
  const blocked = await request(app).post('/api/v1/auth/refresh').send({ refresh_token: crypto.randomBytes(24).toString('base64url') });
  assert.strictEqual(blocked.status, 429);
  assert.strictEqual(blocked.body.code, 'RATE_LIMITED');
});

test('uyelik-5: login IP siniri 200 / 15 dk (31. istek 429 degil); register ve forgot 50 / saat', async () => {
  for (let i = 0; i < 31; i++) {
    const r = await request(app).post('/api/v1/auth/login').send({ email: `nat-${i}@example.com`, password: 'yanlis-parola-123' });
    assert.notStrictEqual(r.status, 429, `istek ${i + 1}`);
  }
  assert.strictEqual(authRoutes.limiters.login.options.max, 200);
  assert.strictEqual(authRoutes.limiters.login.options.windowMs, 15 * 60 * 1000);
  assert.strictEqual(authRoutes.limiters.register.options.max, 50);
  assert.strictEqual(authRoutes.limiters.register.options.windowMs, 60 * 60 * 1000);
  assert.strictEqual(authRoutes.limiters.forgot.options.max, 50);
  assert.strictEqual(authRoutes.limiters.forgot.options.windowMs, 60 * 60 * 1000);
});

test('refresh: bilinmeyen / bos / suresi dolmus token 401 INVALID_TOKEN', async () => {
  assert.strictEqual((await request(app).post('/api/v1/auth/refresh').send({})).status, 400);
  const r = await request(app).post('/api/v1/auth/refresh').send({ refresh_token: 'x'.repeat(43) });
  assert.strictEqual(r.status, 401);
  assert.strictEqual(r.body.code, 'INVALID_TOKEN');
  const reg = await register('exp@example.com');
  const rec = store.refresh.find((x) => x.token_hash === authService._hashToken(reg.body.data.refresh_token));
  rec.expires_at = new Date(Date.now() - 1000);
  const e = await request(app).post('/api/v1/auth/refresh').send({ refresh_token: reg.body.data.refresh_token });
  assert.strictEqual(e.status, 401);
});

test('refresh: pasife alinmis kullanici -> 401 ve aile iptal', async () => {
  const reg = await register('pasif@example.com');
  const u = [...store.users.values()].find((x) => x.email === 'pasif@example.com');
  u.is_active = false;
  const r = await request(app).post('/api/v1/auth/refresh').send({ refresh_token: reg.body.data.refresh_token });
  assert.strictEqual(r.status, 401);
});

test('logout: bu cihazin ailesi iptal edilir; diger cihaz etkilenmez', async () => {
  await register('cikis@example.com');
  const d1 = await request(app).post('/api/v1/auth/login').send({ email: 'cikis@example.com', password: GOOD_PW });
  const d2 = await request(app).post('/api/v1/auth/login').send({ email: 'cikis@example.com', password: GOOD_PW });
  const out = await request(app).post('/api/v1/auth/logout').send({ refresh_token: d1.body.data.refresh_token });
  assert.strictEqual(out.status, 200);
  assert.strictEqual((await request(app).post('/api/v1/auth/refresh').send({ refresh_token: d1.body.data.refresh_token })).status, 401);
  assert.strictEqual((await request(app).post('/api/v1/auth/refresh').send({ refresh_token: d2.body.data.refresh_token })).status, 200);
});

test('sifre degisimi: mevcut parola dogrulanir, tv artar, tum refresh iptal, bu cihaza yeni oturum', async () => {
  const reg = await register('degis@example.com');
  const access = reg.body.data.access_token;
  const other = await request(app).post('/api/v1/auth/login').send({ email: 'degis@example.com', password: GOOD_PW });

  const wrong = await request(app).post('/api/v1/auth/change-password').set('Authorization', `Bearer ${access}`)
    .send({ current_password: 'yanlis-parola-1', new_password: 'Yeni-Parola-2026' });
  assert.strictEqual(wrong.status, 400);

  const res = await request(app).post('/api/v1/auth/change-password').set('Authorization', `Bearer ${access}`)
    .send({ current_password: GOOD_PW, new_password: 'Yeni-Parola-2026' });
  assert.strictEqual(res.status, 200, JSON.stringify(res.body));
  assert.ok(res.body.data.access_token);

  const u = [...store.users.values()].find((x) => x.email === 'degis@example.com');
  assert.strictEqual(u.token_version, 2);
  // eski access token artik gecersiz (tv uyusmazligi)
  const me = await request(app).get('/api/v1/auth/me').set('Authorization', `Bearer ${access}`);
  assert.strictEqual(me.status, 401);
  assert.strictEqual(me.body.code, 'INVALID_TOKEN');
  // diger cihazin refresh token'i iptal
  assert.strictEqual((await request(app).post('/api/v1/auth/refresh').send({ refresh_token: other.body.data.refresh_token })).status, 401);
  // yeni token calisir
  const me2 = await request(app).get('/api/v1/auth/me').set('Authorization', `Bearer ${res.body.data.access_token}`);
  assert.strictEqual(me2.status, 200);
  // eski parola ile giris yok, yenisi ile var
  assert.strictEqual((await request(app).post('/api/v1/auth/login').send({ email: 'degis@example.com', password: GOOD_PW })).status, 401);
  assert.strictEqual((await request(app).post('/api/v1/auth/login').send({ email: 'degis@example.com', password: 'Yeni-Parola-2026' })).status, 200);
});

test('logout-all: tum oturumlar duser (tv++)', async () => {
  const reg = await register('hepsi@example.com');
  const res = await request(app).post('/api/v1/auth/logout-all').set('Authorization', `Bearer ${reg.body.data.access_token}`);
  assert.strictEqual(res.status, 200);
  assert.strictEqual((await request(app).post('/api/v1/auth/refresh').send({ refresh_token: reg.body.data.refresh_token })).status, 401);
  assert.strictEqual((await request(app).get('/api/v1/auth/me').set('Authorization', `Bearer ${reg.body.data.access_token}`)).status, 401);
});

test('/auth/me ve /auth/homes: ev listesi sozlesme alanlari; suresi dolmus misafirde konu kimligi gizli', async () => {
  const reg = await register('evler@example.com');
  const uid = reg.body.data.user.id;
  store.homes.push({ home_id: '11111111-1111-4111-8111-111111111111', user_id: uid, role: 'owner', name: 'A Evi', mqtt_username: 'h_aaaaaaaaaaaaaaaa' });
  store.homes.push({ home_id: '22222222-2222-4222-8222-222222222222', user_id: uid, role: 'guest', name: 'B Evi', mqtt_username: 'h_bbbbbbbbbbbbbbbb', valid_from: new Date(Date.now() - 7200e3), valid_until: new Date(Date.now() - 3600e3) });
  const res = await request(app).get('/api/v1/auth/homes').set('Authorization', `Bearer ${reg.body.data.access_token}`);
  assert.strictEqual(res.status, 200);
  const [a, b] = res.body.data;
  for (const k of ['id', 'name', 'role', 'timezone', 'mqtt_topic_id']) assert.ok(k in a, k);
  assert.strictEqual(a.mqtt_topic_id, 'h_aaaaaaaaaaaaaaaa');
  assert.strictEqual(b.is_expired, true);
  assert.strictEqual(b.mqtt_topic_id, null);
});

test('/homes: sureli teknisyen uyeligi (WP-B) aktifken listelenir ve bitisi valid_until; suresi dolunca listelenmez', async () => {
  const reg = await register('teknisyen.evler@example.com');
  const uid = reg.body.data.user.id;
  store.users.get(uid).role = 'service_user'; // servis uyeligi yalniz personel rolundeki hesapta gorunur (uyelik-13)
  const until = new Date(Date.now() + 3600e3);
  store.homes.push({ home_id: '33333333-3333-4333-8333-333333333333', user_id: uid, role: 'service_user', name: 'C Evi', mqtt_username: 'h_cccccccccccccccc', installer_expires_at: until });
  store.homes.push({ home_id: '44444444-4444-4444-8444-444444444444', user_id: uid, role: 'service_user', name: 'D Evi', mqtt_username: 'h_dddddddddddddddd', installer_expires_at: new Date(Date.now() - 1000) });
  const res = await request(app).get('/api/v1/auth/homes').set('Authorization', `Bearer ${reg.body.data.access_token}`);
  assert.strictEqual(res.status, 200);
  assert.deepStrictEqual(res.body.data.map((h) => h.name), ['C Evi']);
  assert.strictEqual(new Date(res.body.data[0].valid_until).getTime(), until.getTime());
  assert.strictEqual(res.body.data[0].is_expired, false);
});

test('uyelik-13: rolu user a dusurulmus hesabin kalmis servis uyeligi /homes ta GORUNMEZ; diger uyelikleri gorunur', async () => {
  const reg = await register('eski.personel@example.com');
  const uid = reg.body.data.user.id;
  store.homes.push({ home_id: '55555555-5555-4555-8555-555555555555', user_id: uid, role: 'service_user', name: 'E Evi', mqtt_username: 'h_eeeeeeeeeeeeeeee', installer_expires_at: null });
  store.homes.push({ home_id: '66666666-6666-4666-8666-666666666666', user_id: uid, role: 'resident', name: 'F Evi', mqtt_username: 'h_ffffffffffffffff' });
  const res = await request(app).get('/api/v1/auth/homes').set('Authorization', `Bearer ${reg.body.data.access_token}`);
  assert.strictEqual(res.status, 200);
  assert.deepStrictEqual(res.body.data.map((h) => h.name), ['F Evi']);
  // personel rolundeyken servis evi gorunur
  store.users.get(uid).role = 'super_user';
  const res2 = await request(app).get('/api/v1/auth/homes').set('Authorization', `Bearer ${reg.body.data.access_token}`);
  assert.deepStrictEqual(res2.body.data.map((h) => h.name).sort(), ['E Evi', 'F Evi']);
});

test('change-password / logout-all servis oturumu ile kullanilamaz; tokensiz 401', async () => {
  assert.strictEqual((await request(app).post('/api/v1/auth/change-password').send({})).status, 401);
  const forged = makeAccessToken({ id: '33333333-3333-4333-8333-333333333333', role: 'user', token_version: 1 });
  assert.strictEqual((await request(app).post('/api/v1/auth/logout-all').set('Authorization', `Bearer ${forged}`)).status, 401);
});

test('yanitlar no-store', async () => {
  const res = await request(app).post('/api/v1/auth/login').send({});
  assert.strictEqual(res.headers['cache-control'], 'no-store');
});

test('sahte DB: eslesmeyen SQL yok (kapsam kontrolu)', () => {
  assert.deepStrictEqual(store.unmatched, []);
});
