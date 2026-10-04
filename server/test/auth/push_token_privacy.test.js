'use strict';

// S1 (plan §5d-1) - PUSH BELIRTECI GIZLILIGI: oturumlar TOPLU iptal edilince kullanicinin push belirteclerinin
// de devre disi kalmasi (aksi halde gece bildirimi: ev adi + acik lamba ozeti, cikis yapmis telefona duser).
//
//   * POST /auth/logout-all, parola degisimi, parola sifirlama, sosyal baglama (on-hesap-ele-gecirme savunmasi):
//     belirtecler COMMIT SONRASI kapanir (transaction icinde ikinci baglanti/dis cagri yok).
//   * push hatasi / zaman asimi / modul yok / tablo yok: oturum iptali ve yanit AYNEN surer (log'da belirtec yok).
//   * FCM yapilandirilmamis olsa da belirtec devre disi birakilir (yalnizca veritabani islemidir).
//   * Tek cihaz cikisi (POST /auth/logout) belirteclere DOKUNMAZ (istemci DELETE /me/push-tokens cagirir).
//
// Admin akislari (parola atama, rol iptali, dondurma) test/auth/admin.test.js icinde.

const test = require('node:test');
const assert = require('node:assert');
const crypto = require('crypto');
const express = require('express');
const request = require('supertest');
const bcrypt = require('bcryptjs');
const { setTestEnv, installFakeDb } = require('./_helpers');
const { createAuthStore } = require('./_auth_store');

const GOOGLE_AUD = 'test-google-client.apps.googleusercontent.com';

setTestEnv({ BCRYPT_TEST_COST: '4', ALLOW_DEBUG_OTP: 'true', GOOGLE_CLIENT_IDS: GOOGLE_AUD });
// FCM YAPILANDIRILMAMIS: belirtec devre disi birakma yine de calismali.
delete process.env.FCM_PROJECT_ID;
delete process.env.FCM_SERVICE_ACCOUNT_FILE;
delete process.env.GOOGLE_APPLICATION_CREDENTIALS;

const fakeDb = installFakeDb();
const store = createAuthStore().install(fakeDb);

const authRoutes = require('../../src/routes/auth_routes');
const authService = require('../../src/services/auth_service');
const auth = require('../../src/middlewares/auth_middleware');
const { createPushService } = require('../../src/services/push_service');
const { errorHandler } = require('../../src/middlewares/error_handler');

auth.configureAuthMiddleware({ cacheTtlMs: 0 });

// push_tokens UPDATE'i icin degistirilebilir davranis (varsayilan: bellek ici depo)
let pushUpdateFailure = null;
fakeDb.on(/UPDATE push_tokens SET disabled_at/, (params, text) => (pushUpdateFailure ? pushUpdateFailure() : store.handle(params, text)));

const app = express();
app.use(express.json());
app.use('/api/v1/auth', authRoutes);
app.use(errorHandler);

// TEK kalici sunucu (istek basina yeni sunucu degil): Windows'ta tam test kosusunda cok sayida kisa omurlu loopback
// sunucusu "connect EADDRINUSE" (efemer port cakismasi) riskini artirir.
const server = app.listen(0, '127.0.0.1');
test.after(() => new Promise((resolve) => server.close(() => resolve())));

const PW = 'Dogru-Parola-2026';
const NEW_PW = 'Yepyeni-Parola-2027';
const post = (path, body, token) => {
  const r = request(server).post(`/api/v1/auth/${path}`);
  if (token) r.set('Authorization', `Bearer ${token}`);
  return r.send(body || {});
};

// Konsol yakalama: log'a belirtec / sir dusmedigini dogrulamak icin.
const logs = [];
for (const level of ['log', 'info', 'warn', 'error', 'debug']) {
  console[level] = (...args) => { logs.push(`${level}: ${args.map((a) => (typeof a === 'string' ? a : JSON.stringify(a))).join(' ')}`); };
}
const logged = () => logs.join('\n');
const warnings = () => logs.filter((l) => l.startsWith('warn:'));

test.beforeEach(() => {
  for (const l of Object.values(authRoutes.limiters)) l.reset();
  authRoutes.loginFailures.reset();
  authRoutes.loginFailuresTotal.reset();
  authService.setPushService(undefined); // varsayilan: tembel, veritabani tabanli ornek
  authService._pushRevokeTimeoutMs = undefined;
  pushUpdateFailure = null;
  logs.length = 0;
  fakeDb.calls.length = 0;
});

async function register(email) {
  const res = await post('register', { full_name: 'Deneme Kisi', email, password: PW });
  assert.strictEqual(res.status, 201, JSON.stringify(res.body));
  return { ...res.body.data, id: res.body.data.user.id };
}

/** push_tokens UPDATE'inin gunlukteki sirasi: yalniz tx DISINDA (COMMIT'ten sonra) olmali. */
function pushUpdateIndexes() {
  return fakeDb.calls.map((c, i) => (/UPDATE push_tokens SET disabled_at/.test(c.text) ? i : -1)).filter((i) => i >= 0);
}
function insideTransaction(index) {
  let depth = 0;
  for (let i = 0; i < index; i++) {
    const t = fakeDb.calls[i].text;
    if (t === 'BEGIN') depth++;
    else if (t === 'COMMIT' || t === 'ROLLBACK') depth--;
  }
  return depth > 0;
}

// ======================================================================================================
// 1) logout-all
// ======================================================================================================
test('logout-all: kullanicinin TUM etkin belirteclerini kapatir, baska kullanicinin belirtecine dokunmaz; yanit DEGISMEZ', async () => {
  const me = await register('push.logoutall@example.com');
  const other = await register('push.baskasi@example.com');
  store.addPushToken(me.id);
  store.addPushToken(me.id);
  store.addPushToken(me.id, { disabled_at: new Date(Date.now() - 1000) }); // zaten kapali
  const othersToken = store.addPushToken(other.id);

  const res = await post('logout-all', {}, me.access_token);
  assert.strictEqual(res.status, 200);
  assert.strictEqual(res.body.success, true);
  assert.strictEqual(res.body.message, 'Tüm oturumlarınız sonlandırıldı.');
  assert.strictEqual(res.body.data, null);

  assert.strictEqual(store.activePushTokens(me.id).length, 0, 'belirtecler kapanmali');
  assert.ok(!othersToken.disabled_at, 'baska kullanicinin belirteci etkilenmemeli');
  // oturumlar da duser
  assert.strictEqual((await post('refresh', { refresh_token: me.refresh_token })).status, 401);
  // transaction DISINDA, tek sorgu, kullanici kimligi parametre
  const idx = pushUpdateIndexes();
  assert.strictEqual(idx.length, 1);
  assert.strictEqual(insideTransaction(idx[0]), false);
  assert.deepStrictEqual(fakeDb.calls[idx[0]].params, [me.id]);
});

test('logout-all: belirtec yoksa da basarili (rowCount 0)', async () => {
  const me = await register('push.bos@example.com');
  const res = await post('logout-all', {}, me.access_token);
  assert.strictEqual(res.status, 200);
  assert.strictEqual(pushUpdateIndexes().length, 1);
});

// ======================================================================================================
// 2) parola degisimi / sifirlama: COMMIT SONRASI
// ======================================================================================================
test('change-password: belirtecler transaction COMMIT edildikten SONRA kapanir; yeni oturum yanit verir; belirtec log da yok', async () => {
  const me = await register('push.degis@example.com');
  const t1 = store.addPushToken(me.id);
  const t2 = store.addPushToken(me.id);
  fakeDb.calls.length = 0;

  const res = await post('change-password', { current_password: PW, new_password: NEW_PW }, me.access_token);
  assert.strictEqual(res.status, 200, JSON.stringify(res.body));
  assert.ok(res.body.data.access_token && res.body.data.refresh_token, 'bu cihaz icin yeni oturum');
  assert.ok(t1.disabled_at && t2.disabled_at);

  const idx = pushUpdateIndexes();
  assert.strictEqual(idx.length, 1, 'tek devre disi birakma sorgusu');
  assert.strictEqual(insideTransaction(idx[0]), false, 'transaction ICINDE olmamali');
  const commitIdx = fakeDb.calls.findIndex((c) => c.text === 'COMMIT');
  assert.ok(commitIdx >= 0 && idx[0] > commitIdx, 'COMMIT sonrasi cagrilmali');
  assert.ok(!logged().includes(t1.token) && !logged().includes(t2.token), 'belirtec log a yazilmamali');
});

test('change-password: yanlis mevcut parola -> belirtecler KAPANMAZ (oturum iptali yok)', async () => {
  const me = await register('push.yanlis@example.com');
  const t = store.addPushToken(me.id);
  const res = await post('change-password', { current_password: 'yanlis-parola-1', new_password: NEW_PW }, me.access_token);
  assert.strictEqual(res.status, 400);
  assert.ok(!t.disabled_at);
  assert.strictEqual(pushUpdateIndexes().length, 0);
});

test('reset-password (kod ve baglanti): belirtecler COMMIT sonrasi kapanir; yanit otomatik giris verir', async () => {
  for (const mode of ['code', 'token']) {
    const email = `push.sifirla.${mode}@example.com`;
    const reg = await register(email);
    const t = store.addPushToken(reg.id);
    const fp = await post('forgot-password', { email });
    assert.strictEqual(fp.status, 200, JSON.stringify(fp.body));
    fakeDb.calls.length = 0;

    const body = mode === 'code'
      ? { email, code: fp.body.data.debug_code, new_password: NEW_PW }
      : { token: fp.body.data.debug_token, new_password: NEW_PW };
    const res = await post('reset-password', body);
    assert.strictEqual(res.status, 200, JSON.stringify(res.body));
    assert.ok(res.body.data.access_token, 'otomatik giris');
    assert.ok(t.disabled_at, `${mode}: belirtec kapanmali`);

    const idx = pushUpdateIndexes();
    assert.strictEqual(idx.length, 1, mode);
    assert.strictEqual(insideTransaction(idx[0]), false, mode);
    assert.ok(idx[0] > fakeDb.calls.findIndex((c) => c.text === 'COMMIT'), mode);
    for (const l of Object.values(authRoutes.limiters)) l.reset();
  }
});

test('reset-password: gecersiz kod -> belirtecler KAPANMAZ', async () => {
  const email = 'push.sifirla.gecersiz@example.com';
  const reg = await register(email);
  const t = store.addPushToken(reg.id);
  await post('forgot-password', { email });
  const res = await post('reset-password', { email, code: '000000', new_password: NEW_PW });
  assert.strictEqual(res.status, 400);
  assert.ok(!t.disabled_at);
});

// ======================================================================================================
// 3) sosyal baglama (on-hesap-ele-gecirme savunmasi)
// ======================================================================================================
test('google: dogrulanmamis e-postali hesaba baglanirken oturumlar kapanir -> o hesabin belirtecleri de kapanir (COMMIT sonrasi); dogrulanmis baglamada dokunulmaz', async () => {
  authService.setIdentityVerifiers({
    google: async (token) => ({
      iss: 'https://accounts.google.com', aud: GOOGLE_AUD, sub: `sub-${token.slice(-8)}`, exp: Math.floor(Date.now() / 1000) + 600,
      email: token.startsWith('unverified') ? 'on.hesap@example.com' : 'mesru.hesap@example.com', email_verified: true,
    }),
  });
  try {
    // Saldirganin on-kaydi (e-posta dogrulanmamis) + kendi telefonunun belirteci
    const attacker = store.addUser({ email: 'on.hesap@example.com', password_hash: await bcrypt.hash('Saldirgan-Parola-1', 4), email_verified: false });
    const aTok = store.addPushToken(attacker.id);
    // Mesru, dogrulanmis hesap
    const legit = store.addUser({ email: 'mesru.hesap@example.com', password_hash: await bcrypt.hash(PW, 4), email_verified: true });
    const lTok = store.addPushToken(legit.id);
    fakeDb.calls.length = 0;

    await authService.loginWithGoogle({ id_token: 'unverified-0123456789abcdef' });
    assert.ok(aTok.disabled_at, 'on-kayitli saldirgan hesabinin belirteci kapanmali');
    const idx = pushUpdateIndexes();
    assert.strictEqual(idx.length, 1);
    assert.strictEqual(insideTransaction(idx[0]), false);
    assert.ok(idx[0] > fakeDb.calls.findIndex((c) => c.text === 'COMMIT'));

    await authService.loginWithGoogle({ id_token: 'verified-0123456789abcdefgh' });
    assert.ok(!lTok.disabled_at, 'dogrulanmis hesapta oturum iptali yok -> belirtece dokunulmaz');
    assert.strictEqual(pushUpdateIndexes().length, 1, 'ikinci baglama ek sorgu uretmemeli');
  } finally {
    authService.resetIdentityVerifiers();
  }
});

// ======================================================================================================
// 4) Tek cihaz cikisi / yenileme: sunucu tarafi belirtece DOKUNMAZ (istemci DELETE /me/push-tokens cagirir)
// ======================================================================================================
test('POST /auth/logout (tek cihaz) ve refresh: belirteclere dokunulmaz', async () => {
  const me = await register('push.tek.cihaz@example.com');
  const t = store.addPushToken(me.id);
  const rf = await post('refresh', { refresh_token: me.refresh_token });
  assert.strictEqual(rf.status, 200);
  const lo = await post('logout', { refresh_token: rf.body.data.refresh_token });
  assert.strictEqual(lo.status, 200);
  assert.ok(!t.disabled_at);
  assert.strictEqual(pushUpdateIndexes().length, 0);
});

// ======================================================================================================
// 5) Push hatasi / yapilandirma: oturum iptalini ASLA bozmaz
// ======================================================================================================
test('push servisi HATA verirse: logout-all yine 200, oturumlar kapanir, log da belirtec/ayrinti yok (yalniz hata kodu + kullanici oneki)', async () => {
  const me = await register('push.hata@example.com');
  const secretToken = 'GIZLI-BELIRTEC-' + crypto.randomBytes(16).toString('hex');
  authService.setPushService({
    disableAllTokensForUser: async () => {
      const e = new Error(`veritabani hatasi ${secretToken}`);
      e.code = 'XX000';
      throw e;
    },
  });
  const res = await post('logout-all', {}, me.access_token);
  assert.strictEqual(res.status, 200);
  assert.strictEqual(res.body.message, 'Tüm oturumlarınız sonlandırıldı.');
  assert.strictEqual((await post('refresh', { refresh_token: me.refresh_token })).status, 401, 'oturum iptali bozulmamali');

  const w = warnings();
  assert.strictEqual(w.length, 1);
  assert.match(w[0], /Push belirteci devre disi birakilamadi/);
  assert.match(w[0], /XX000/);
  assert.ok(w[0].includes(me.id.slice(0, 8)));
  assert.ok(!logged().includes(secretToken), 'hata MESAJI (gizli deger tasiyabilir) log a yazilmamali');
  assert.ok(!logged().includes(me.id), 'tam kullanici kimligi yazilmamali');
});

test('push servisi HATA verirse: change-password ve reset-password da basarili (yeni oturum doner)', async () => {
  const boom = async () => { throw Object.assign(new Error('boom'), { code: '57014' }); };
  authService.setPushService({ disableAllTokensForUser: boom });

  const me = await register('push.hata.degis@example.com');
  const cp = await post('change-password', { current_password: PW, new_password: NEW_PW }, me.access_token);
  assert.strictEqual(cp.status, 200, JSON.stringify(cp.body));
  assert.ok(cp.body.data.access_token);

  const email = 'push.hata.sifirla@example.com';
  await register(email);
  const fp = await post('forgot-password', { email });
  const rp = await post('reset-password', { email, code: fp.body.data.debug_code, new_password: NEW_PW });
  assert.strictEqual(rp.status, 200, JSON.stringify(rp.body));
  assert.ok(rp.body.data.access_token);
  assert.strictEqual(warnings().length, 2);
});

test('push tablosu yok (42P01: migration 030 uygulanmamis): SESSIZ gecilir (uyari yok), akis surer', async () => {
  const me = await register('push.tablo.yok@example.com');
  pushUpdateFailure = () => Object.assign(new Error('relation "push_tokens" does not exist'), { code: '42P01' });
  const res = await post('logout-all', {}, me.access_token);
  assert.strictEqual(res.status, 200);
  assert.strictEqual(warnings().length, 0, 'sessiz');
  assert.strictEqual((await post('refresh', { refresh_token: me.refresh_token })).status, 401);
});

test('push modulu yok/devre disi (setPushService(null)) veya gecersiz nesne: sessizce gecilir, push sorgusu yok', async () => {
  await register('push.devre.disi@example.com');
  for (const svc of [null, {}, { disableAllTokensForUser: 'fonksiyon-degil' }]) {
    authService.setPushService(svc);
    fakeDb.calls.length = 0;
    const lg = await post('login', { email: 'push.devre.disi@example.com', password: PW });
    assert.strictEqual(lg.status, 200);
    const res = await post('logout-all', {}, lg.body.data.access_token);
    assert.strictEqual(res.status, 200, String(svc));
    assert.strictEqual(pushUpdateIndexes().length, 0, String(svc));
  }
  assert.strictEqual(warnings().length, 0);
});

test('push servisi TAKILIRSA: yanit en cok zaman asimi kadar bekler, 200 doner; gec gelen hata unhandledRejection uretmez', async () => {
  const me = await register('push.takildi@example.com');
  authService._pushRevokeTimeoutMs = 80;
  let rejectLater;
  authService.setPushService({
    disableAllTokensForUser: () => new Promise((_, reject) => { rejectLater = reject; }), // asla cozulmez
  });
  const unhandled = [];
  const onUnhandled = (e) => unhandled.push(e);
  process.on('unhandledRejection', onUnhandled);
  try {
    const t0 = Date.now();
    const res = await post('logout-all', {}, me.access_token);
    const elapsed = Date.now() - t0;
    assert.strictEqual(res.status, 200);
    assert.ok(elapsed < 2500, `yanit gecikmemeli (${elapsed} ms)`);
    assert.strictEqual(warnings().filter((w) => /zaman asimina/.test(w)).length, 1);
    rejectLater(new Error('gec hata'));
    await new Promise((r) => setTimeout(r, 30));
    assert.deepStrictEqual(unhandled, []);
  } finally {
    process.removeListener('unhandledRejection', onUnhandled);
  }
});

// ======================================================================================================
// 6) FCM yapilandirilmamis: belirtec yine kapanir (yalnizca veritabani islemi)
// ======================================================================================================
test('FCM yapilandirilmamis (isConfigured=false) iken de belirtecler kapanir; enjekte push_service ornegi kullanilir', async () => {
  const push = createPushService({ db: fakeDb, env: {}, logger: { log() {}, warn() {}, error() {} } });
  assert.strictEqual(push.isConfigured(), false);
  authService.setPushService(push);

  const me = await register('push.fcm.yok@example.com');
  const t = store.addPushToken(me.id);
  const res = await post('logout-all', {}, me.access_token);
  assert.strictEqual(res.status, 200);
  assert.ok(t.disabled_at, 'FCM yapilandirmasi olmasa da belirtec kapanmali');
});

test('varsayilan (tembel) push ornegi de calisir: setPushService(undefined)', async () => {
  authService.setPushService(undefined);
  const me = await register('push.varsayilan@example.com');
  const t = store.addPushToken(me.id);
  assert.strictEqual((await post('logout-all', {}, me.access_token)).status, 200);
  assert.ok(t.disabled_at);
});

test('revokePushTokens: gecersiz kullanici kimligi 0 doner ve fırlatmaz', async () => {
  for (const bad of [undefined, null, '', 42, {}]) {
    assert.strictEqual(await authService.revokePushTokens(bad), 0);
  }
});

test('revokeAllUserSessions({tx}) belirtece KENDISI dokunmaz (cagiran COMMIT sonrasi cagirir); {disablePushTokens:true} zorlar', async () => {
  const me = await register('push.tx@example.com');
  const t = store.addPushToken(me.id);
  fakeDb.calls.length = 0;
  await fakeDb.withTransaction(async (tx) => {
    await authService.revokeAllUserSessions(me.id, { tx, reason: 'test' });
  });
  assert.ok(!t.disabled_at, 'tx icindeyken belirtec kapanmaz');
  assert.strictEqual(pushUpdateIndexes().length, 0);

  await authService.revokeAllUserSessions(me.id, { reason: 'test', disablePushTokens: true });
  assert.ok(t.disabled_at);
});

// ======================================================================================================
// 7) Enjekte push ornegi (server.js createApp() uygulamanin ornegini verir: server_app.test.js)
// ======================================================================================================
test('enjekte push ornegi kullanilir: logout-all -> disableAllTokensForUser(userId) bir kez cagrilir', async () => {
  const calls = [];
  const fake = { disableAllTokensForUser: async (uid) => { calls.push(uid); return 2; } };
  authService.setPushService(fake);
  const me = await register('push.enjekte@example.com');
  assert.strictEqual((await post('logout-all', {}, me.access_token)).status, 200);
  assert.deepStrictEqual(calls, [me.id]);
  assert.strictEqual(await authService.revokePushTokens(me.id), 2);
});

test('sahte DB: eslesmeyen SQL yok (kapsam kontrolu)', () => {
  assert.deepStrictEqual(store.unmatched, []);
});
