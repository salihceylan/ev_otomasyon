'use strict';

// UYELIK-02 (karar D4): oturumlarin TOPLU iptali (POST /auth/logout-all, parola degisimi, parola sifirlama ve
// revokeAllUserSessions'i kullanan diger yollar) kullanicinin TUM uygulama MQTT kimliklerini
// (mqtt_credentials kind='app', user_id) refresh/token_version iptaliyle AYNI transaction'da siler ve acik
// baglantilari COMMIT SONRASI EMQX REST ile atar (kick). Kick en iyi cabadir: ag hatasi / servis hatasi yaniti BOZMAZ.
// Cihaz kimligine ve baska kullanicinin kimligine DOKUNULMAZ.
//
// Ag cagrisi (EMQX REST) globalThis.fetch ile sahtelenir; MQTT kimlik servisi GERCEK moduldur (sahte DB ile).

const test = require('node:test');
const assert = require('node:assert');
const crypto = require('crypto');
const express = require('express');
const request = require('supertest');
const bcrypt = require('bcryptjs');
const { setTestEnv, installFakeDb } = require('./_helpers');
const { createAuthStore } = require('./_auth_store');

const GOOGLE_AUD = 'test-google-client.apps.googleusercontent.com';
setTestEnv({
  BCRYPT_TEST_COST: '4',
  ALLOW_DEBUG_OTP: 'true',
  GOOGLE_CLIENT_IDS: GOOGLE_AUD,
  EMQX_API_URL: 'http://emqx.test.invalid:18083',
  EMQX_API_KEY: 'test-only-key',
  EMQX_API_SECRET: crypto.randomBytes(12).toString('hex'),
});

const fakeDb = installFakeDb();
const store = createAuthStore().install(fakeDb);

const authRoutes = require('../../src/routes/auth_routes');
const authService = require('../../src/services/auth_service');
const auth = require('../../src/middlewares/auth_middleware');
const { errorHandler } = require('../../src/middlewares/error_handler');

auth.configureAuthMiddleware({ cacheTtlMs: 0 });
authService.setPushService(null); // push bu dosyanin konusu degil (push_token_privacy.test.js)

const app = express();
app.use(express.json());
app.use('/api/v1/auth', authRoutes);
app.use(errorHandler);
const server = app.listen(0, '127.0.0.1');
test.after(() => new Promise((resolve) => server.close(() => resolve())));

// ---- EMQX REST sahtesi: cagrilar sahte DB gunlugune de yazilir (COMMIT'e gore sira denetimi) ----
const fetchLog = [];
let fetchMode = 'ok'; // 'ok' | 'down'
globalThis.fetch = async (url, init = {}) => {
  const method = init.method || 'GET';
  fetchLog.push({ method, url: String(url) });
  fakeDb.calls.push({ text: `FETCH ${method} ${url}`, params: [] });
  if (fetchMode === 'down') throw new Error('connect ECONNREFUSED gizli-emqx-ayrinti');
  const u = new URL(String(url));
  if (method === 'GET') {
    const username = u.searchParams.get('username');
    return { ok: true, status: 200, json: async () => ({ data: [{ clientid: `cid-${username}` }] }) };
  }
  return { ok: true, status: 204, json: async () => ({}) };
};
const kickedClientIds = () => fetchLog.filter((f) => f.method === 'DELETE').map((f) => decodeURIComponent(f.url.split('/clients/')[1]));

// Konsol yakalama: uyari metninde sir/ayrinti olmamali.
const logs = [];
for (const level of ['log', 'info', 'warn', 'error', 'debug']) {
  console[level] = (...args) => { logs.push(`${level}: ${args.map((a) => (typeof a === 'string' ? a : JSON.stringify(a))).join(' ')}`); };
}

const PW = 'Dogru-Parola-2026';
const post = (path, body, token) => {
  const r = request(server).post(`/api/v1/auth/${path}`);
  if (token) r.set('Authorization', `Bearer ${token}`);
  return r.send(body || {});
};

test.beforeEach(() => {
  for (const l of Object.values(authRoutes.limiters)) l.reset();
  authRoutes.loginFailures.reset();
  authRoutes.loginFailuresTotal.reset();
  authService.setMqttCredentialService(undefined); // varsayilan: gercek mqtt_credential_service (sahte DB + sahte fetch)
  fetchMode = 'ok';
  fetchLog.length = 0;
  logs.length = 0;
  fakeDb.calls.length = 0;
});

async function register(email) {
  const res = await post('register', { full_name: 'Deneme Kisi', email, password: PW });
  assert.strictEqual(res.status, 201, JSON.stringify(res.body));
  return { ...res.body.data, id: res.body.data.user.id };
}

/** Kullaniciya iki evde uygulama kimligi + bir cihaz kimligi + baska kullanicinin kimligi. */
function seedCreds(userId, otherUserId) {
  const homeA = crypto.randomUUID();
  const homeB = crypto.randomUUID();
  const mine = [store.addMqttCred(userId, { home_id: homeA }), store.addMqttCred(userId, { home_id: homeB })];
  const device = store.addMqttCred(null, { home_id: homeA, kind: 'device' });
  const others = otherUserId ? [store.addMqttCred(otherUserId, { home_id: homeA })] : [];
  return { mine, device, others };
}

const indexOf = (re) => fakeDb.calls.findIndex((c) => re.test(c.text));
const indexesOf = (re) => fakeDb.calls.map((c, i) => (re.test(c.text) ? i : -1)).filter((i) => i >= 0);
/** index'i kapsayan BEGIN..COMMIT araligi (yoksa null). */
function txRangeOf(index) {
  let begin = -1;
  for (let i = index; i >= 0; i--) {
    const t = fakeDb.calls[i].text;
    if (t === 'COMMIT' || t === 'ROLLBACK') { if (i !== index) return null; }
    if (t === 'BEGIN') { begin = i; break; }
  }
  if (begin < 0) return null;
  for (let j = index; j < fakeDb.calls.length; j++) {
    if (fakeDb.calls[j].text === 'COMMIT') return [begin, j];
    if (fakeDb.calls[j].text === 'ROLLBACK') return null;
  }
  return null;
}

/** Ortak beklenti: kullanicinin uygulama kimlikleri silinir (ayni tx), COMMIT sonrasi atilir; digerleri kalir. */
function assertRevokedAndKicked(seed, { refreshRe = /UPDATE refresh_tokens SET revoked_at = NOW\(\), revoked_reason = \$2/ } = {}) {
  assert.deepStrictEqual(store.appCredsOf(seed.mine[0].user_id), [], 'kullanicinin uygulama kimlikleri silinmeli');
  assert.ok(store.mqttCreds.includes(seed.device), 'cihaz kimligi KALMALI');
  for (const o of seed.others) assert.ok(store.mqttCreds.includes(o), 'baska kullanicinin kimligi KALMALI');

  const del = indexOf(/DELETE FROM mqtt_credentials WHERE user_id = \$1 AND kind = 'app'/);
  assert.ok(del >= 0, 'MQTT kimlik silme sorgusu calismali');
  const range = txRangeOf(del);
  assert.ok(range, 'MQTT kimlik silme bir transaction icinde olmali');
  const refresh = indexesOf(refreshRe).filter((i) => i > range[0] && i < range[1]);
  assert.ok(refresh.length >= 1, 'refresh iptali ile AYNI transaction');

  assert.deepStrictEqual(kickedClientIds().sort(), seed.mine.map((c) => `cid-${c.username}`).sort(), 'acik baglantilar atilmali');
  for (const i of indexesOf(/^FETCH /)) assert.ok(i > range[1], 'kick COMMIT SONRASI');
}

// ======================================================================================================
test('logout-all: TUM evlerdeki uygulama MQTT kimlikleri ayni transaction\'da silinir, COMMIT sonrasi atilir; yanit DEGISMEZ', async () => {
  const me = await register('mqtt.logoutall@example.com');
  const other = await register('mqtt.baskasi@example.com');
  const seed = seedCreds(me.id, other.id);
  fakeDb.calls.length = 0;

  const res = await post('logout-all', {}, me.access_token);
  assert.strictEqual(res.status, 200, JSON.stringify(res.body));
  assert.strictEqual(res.body.message, 'Tüm oturumlarınız sonlandırıldı.');
  assert.strictEqual(res.body.data, null);
  assertRevokedAndKicked(seed);
  // REST oturumlari da duser
  assert.strictEqual((await post('refresh', { refresh_token: me.refresh_token })).status, 401);
});

test('change-password: diger cihazlarin uygulama MQTT kimlikleri silinir + atilir; bu cihaza yeni oturum doner', async () => {
  const me = await register('mqtt.degis@example.com');
  const seed = seedCreds(me.id);
  fakeDb.calls.length = 0;

  const res = await post('change-password', { current_password: PW, new_password: 'Yepyeni-Parola-2027' }, me.access_token);
  assert.strictEqual(res.status, 200, JSON.stringify(res.body));
  assert.ok(res.body.data.access_token);
  assertRevokedAndKicked(seed);
});

test('reset-password (kod): uygulama MQTT kimlikleri silinir + atilir', async () => {
  const me = await register('mqtt.sifirla@example.com');
  const forgot = await post('forgot-password', { email: 'mqtt.sifirla@example.com' });
  assert.strictEqual(forgot.status, 200, JSON.stringify(forgot.body));
  const seed = seedCreds(me.id);
  fakeDb.calls.length = 0;
  fetchLog.length = 0;

  const res = await post('reset-password', { email: 'mqtt.sifirla@example.com', code: forgot.body.data.debug_code, new_password: 'Sifirlanan-Parola-1' });
  assert.strictEqual(res.status, 200, JSON.stringify(res.body));
  assertRevokedAndKicked(seed);
});

test('kick basarisiz (EMQX erisilemez): logout-all YINE 200, kimlikler silinir; uyari log\'unda ag ayrintisi/kimlik adi yok', async () => {
  const me = await register('mqtt.emqxyok@example.com');
  const seed = seedCreds(me.id);
  fetchMode = 'down';

  const res = await post('logout-all', {}, me.access_token);
  assert.strictEqual(res.status, 200, JSON.stringify(res.body));
  assert.deepStrictEqual(store.appCredsOf(me.id), []);
  assert.ok(fetchLog.length >= 1, 'kick denenmeli');
  const text = logs.join('\n');
  assert.ok(!text.includes('gizli-emqx-ayrinti'), 'ag hata ayrintisi log\'a yazilmamali');
  for (const c of seed.mine) assert.ok(!text.includes(c.username), 'kimlik adi log\'a yazilmamali');
});

test('kick servisi FIRLATSA bile parola degisimi 200 (en iyi caba)', async () => {
  const real = require('../../src/services/mqtt_credential_service');
  const svc = Object.assign(Object.create(real), { kickUsernames: async () => { throw new Error('gizli-kick-ayrinti'); } });
  authService.setMqttCredentialService(svc);
  const me = await register('mqtt.kickhata@example.com');
  seedCreds(me.id);

  const res = await post('change-password', { current_password: PW, new_password: 'Yepyeni-Parola-2028' }, me.access_token);
  assert.strictEqual(res.status, 200, JSON.stringify(res.body));
  assert.deepStrictEqual(store.appCredsOf(me.id), [], 'kimlikler yine silinmeli');
  assert.ok(!logs.join('\n').includes('gizli-kick-ayrinti'));
});

test('kick TAKILIRSA yanit en cok bekleme suresi kadar gecikir (atma arka planda surer)', async () => {
  const real = require('../../src/services/mqtt_credential_service');
  let release = null;
  const svc = Object.assign(Object.create(real), { kickUsernames: () => new Promise((resolve) => { release = resolve; }) });
  authService.setMqttCredentialService(svc);
  authService._mqttKickWaitMs = 50;
  try {
    const me = await register('mqtt.kicktakildi@example.com');
    seedCreds(me.id);
    const t0 = Date.now();
    const res = await post('logout-all', {}, me.access_token);
    assert.strictEqual(res.status, 200);
    assert.ok(Date.now() - t0 < 3000, 'yanit kick\'i beklememeli');
    assert.deepStrictEqual(store.appCredsOf(me.id), []);
    assert.ok(logs.some((l) => l.startsWith('warn:') && l.includes('zaman asimina')));
  } finally {
    authService._mqttKickWaitMs = undefined;
    if (release) release({ requested: 2, kicked: 2, failed: 0, skipped: false, errors: [] });
  }
});

test('MQTT kimlik servisi yoksa (null) oturum iptali yine calisir; MQTT sorgusu yapilmaz', async () => {
  authService.setMqttCredentialService(null);
  const me = await register('mqtt.servisyok@example.com');
  seedCreds(me.id);
  fakeDb.calls.length = 0;

  const res = await post('logout-all', {}, me.access_token);
  assert.strictEqual(res.status, 200);
  assert.strictEqual(indexOf(/mqtt_credentials/), -1);
  assert.strictEqual((await post('refresh', { refresh_token: me.refresh_token })).status, 401);
});

test('kullanicinin MQTT kimligi yoksa kick cagrisi yapilmaz', async () => {
  const me = await register('mqtt.kimlikyok@example.com');
  const res = await post('logout-all', {}, me.access_token);
  assert.strictEqual(res.status, 200);
  assert.strictEqual(fetchLog.length, 0);
});

test('google on-hesap ele gecirme savunmasi (dogrulanmamis hesaba baglama): eski oturumlarla birlikte MQTT kimlikleri de iptal + kick', async () => {
  const victim = store.addUser({ email: 'mqtt.onhesap@example.com', password_hash: await bcrypt.hash('Saldirgan-Parola-1', 4), email_verified: false });
  store.refresh.push({ id: crypto.randomUUID(), user_id: victim.id, token_hash: 'mqtt-onhesap', family_id: crypto.randomUUID(), expires_at: new Date(Date.now() + 1e9), used_at: null, revoked_at: null });
  const seed = seedCreds(victim.id);
  authService.setIdentityVerifiers({
    google: async () => ({
      sub: 'g-mqtt-victim', iss: 'https://accounts.google.com', aud: GOOGLE_AUD,
      exp: Math.floor(Date.now() / 1000) + 600, email: 'mqtt.onhesap@example.com', email_verified: true,
    }),
  });
  try {
    fakeDb.calls.length = 0;
    const res = await post('google', { id_token: 'x'.repeat(64) });
    assert.strictEqual(res.status, 200, JSON.stringify(res.body));
    assert.strictEqual(res.body.data.user.id, victim.id);
    assert.ok(store.refresh.find((r) => r.token_hash === 'mqtt-onhesap').revoked_at);
    assertRevokedAndKicked(seed, { refreshRe: /UPDATE refresh_tokens SET revoked_at = NOW\(\)/ });
  } finally {
    authService.resetIdentityVerifiers();
  }
});

test('google: dogrulanmis hesaba normal baglama oturum/MQTT kimligine DOKUNMAZ', async () => {
  const owner = store.addUser({ email: 'mqtt.dogru@example.com', password_hash: await bcrypt.hash(PW, 4), email_verified: true });
  const seed = seedCreds(owner.id);
  authService.setIdentityVerifiers({
    google: async () => ({
      sub: 'g-mqtt-owner', iss: 'https://accounts.google.com', aud: GOOGLE_AUD,
      exp: Math.floor(Date.now() / 1000) + 600, email: 'mqtt.dogru@example.com', email_verified: true,
    }),
  });
  try {
    const res = await post('google', { id_token: 'y'.repeat(64) });
    assert.strictEqual(res.status, 200, JSON.stringify(res.body));
    assert.strictEqual(store.appCredsOf(owner.id).length, seed.mine.length);
    assert.strictEqual(fetchLog.length, 0);
  } finally {
    authService.resetIdentityVerifiers();
  }
});

test('sahte DB: eslesmeyen SQL yok', () => {
  assert.deepStrictEqual(store.unmatched, []);
});
