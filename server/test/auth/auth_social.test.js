'use strict';

// A4: Google / Apple girisi YALNIZCA dogrulanmis kimlik jetonu ile (imza + aud + iss + exp +
// email_verified). Gercek dogrulama kodu (google-auth-library / jose) yerel uretilmis anahtarlarla
// calistirilir; ag erisimi yoktur. Geri donus (fallback) yolu YOK; istemci e-postasina guvenilmez.

const test = require('node:test');
const assert = require('node:assert');
const crypto = require('crypto');
const express = require('express');
const request = require('supertest');
const jwt = require('jsonwebtoken');
const bcrypt = require('bcryptjs');
const jose = require('jose');
const { setTestEnv, installFakeDb } = require('./_helpers');
const { createAuthStore } = require('./_auth_store');

const GOOGLE_AUD = 'test-google-client.apps.googleusercontent.com';
const APPLE_AUD = 'tr.com.example.ahbu';

setTestEnv({ BCRYPT_TEST_COST: '4', GOOGLE_CLIENT_IDS: `baska-istemci,${GOOGLE_AUD}`, APPLE_CLIENT_IDS: APPLE_AUD });
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

// ---- Google: yerel RSA anahtari, gercek verifySignedJwtWithCertsAsync ----
const gKeys = crypto.generateKeyPairSync('rsa', { modulusLength: 2048 });
const gOther = crypto.generateKeyPairSync('rsa', { modulusLength: 2048 });
const G_KID = 'test-google-kid';
const gPublicPem = gKeys.publicKey.export({ type: 'spki', format: 'pem' });

authService.setIdentityVerifiers({
  google: (token, audiences) => authService.verifyGoogleIdToken(token, { audiences, certs: { [G_KID]: gPublicPem } }),
});

function googleToken(claims = {}, { key = gKeys.privateKey, expiresIn = 600 } = {}) {
  return jwt.sign(
    { iss: 'https://accounts.google.com', aud: GOOGLE_AUD, sub: 'g-sub-1', email: 'g.user@example.com', email_verified: true, name: 'Google Kisi', ...claims },
    key,
    { algorithm: 'RS256', keyid: G_KID, expiresIn }
  );
}

// ---- Apple: jose ile yerel JWKS, gercek jwtVerify ----
let appleKeys;
let appleJwks;
const A_KID = 'test-apple-kid';

async function appleToken(claims = {}, { exp = '10m', iss = 'https://appleid.apple.com', aud = APPLE_AUD } = {}) {
  return new jose.SignJWT({ email: 'a.user@privaterelay.appleid.com', email_verified: 'true', ...claims })
    .setProtectedHeader({ alg: 'RS256', kid: A_KID })
    .setIssuer(iss)
    .setAudience(aud)
    .setSubject(claims.sub || 'apple-sub-1')
    .setIssuedAt()
    .setExpirationTime(exp)
    .sign(appleKeys.privateKey);
}

test.before(async () => {
  appleKeys = await jose.generateKeyPair('RS256');
  const jwk = await jose.exportJWK(appleKeys.publicKey);
  jwk.kid = A_KID;
  jwk.alg = 'RS256';
  appleJwks = jose.createLocalJWKSet({ keys: [jwk] });
  authService.setIdentityVerifiers({
    apple: (token, audiences) => authService.verifyAppleIdentityToken(token, { audiences, jwks: appleJwks }),
  });
});

test.beforeEach(() => {
  for (const l of Object.values(authRoutes.limiters)) l.reset();
});

const post = (path, body) => request(app).post(`/api/v1/auth/${path}`).send(body);

// ----------------------------- GOOGLE ---------------------------------------
test('google: id_token yoksa 400; istemci e-postasi ile GIRIS YOK (fallback yok)', async () => {
  const before = store.users.size;
  const res = await post('google', { email: 'kurban@example.com', google_id: 'x', name: 'Saldirgan' });
  assert.strictEqual(res.status, 400);
  assert.strictEqual(store.users.size, before);
});

test('google: GOOGLE_CLIENT_IDS yoksa 503 (fail-closed)', async () => {
  const saved = process.env.GOOGLE_CLIENT_IDS;
  delete process.env.GOOGLE_CLIENT_IDS;
  try {
    const res = await post('google', { id_token: googleToken() });
    assert.strictEqual(res.status, 503);
  } finally {
    process.env.GOOGLE_CLIENT_IDS = saved;
  }
});

test('google: baska anahtarla imzalanmis / yanlis aud / yanlis iss / suresi dolmus -> 401', async () => {
  const cases = [
    googleToken({}, { key: gOther.privateKey }),
    googleToken({ aud: 'saldirgan-istemci' }),
    googleToken({ iss: 'https://evil.example' }),
    jwt.sign(
      { iss: 'https://accounts.google.com', aud: GOOGLE_AUD, sub: 'g', email: 'g@example.com', email_verified: true, iat: Math.floor(Date.now() / 1000) - 7200, exp: Math.floor(Date.now() / 1000) - 3600 },
      gKeys.privateKey,
      { algorithm: 'RS256', keyid: G_KID }
    ),
    'bozuk.jeton.degeri-bozuk.jeton.degeri',
  ];
  for (const t of cases) {
    const res = await post('google', { id_token: t });
    assert.strictEqual(res.status, 401, t.slice(0, 20));
    assert.strictEqual(res.body.code, 'INVALID_CREDENTIALS');
  }
});

test('google: email_verified=false -> 401', async () => {
  const res = await post('google', { id_token: googleToken({ email_verified: false, sub: 'g-unv' }) });
  assert.strictEqual(res.status, 401);
});

test('google: gecerli jeton -> hesap olusur (google_id, email_verified), tekrar giriste ayni hesap', async () => {
  const res = await post('google', { id_token: googleToken({ sub: 'g-new', email: 'Yeni.Google@Example.com' }) });
  assert.strictEqual(res.status, 200, JSON.stringify(res.body));
  assert.strictEqual(res.body.data.user.email, 'yeni.google@example.com');
  assert.ok(res.body.data.access_token && res.body.data.refresh_token);
  const u = [...store.users.values()].find((x) => x.google_id === 'g-new');
  assert.ok(u && u.email_verified === true);
  const again = await post('google', { id_token: googleToken({ sub: 'g-new', email: 'yeni.google@example.com' }) });
  assert.strictEqual(again.body.data.user.id, u.id);
});

test('google: govdedeki e-posta yok sayilir; kimlik jetondan gelir', async () => {
  const res = await post('google', { id_token: googleToken({ sub: 'g-body', email: 'gercek@example.com' }), email: 'kurban@example.com' });
  assert.strictEqual(res.status, 200);
  assert.strictEqual(res.body.data.user.email, 'gercek@example.com');
});

test('google: dogrulanmamis e-postali mevcut hesaba baglanirken eski parola ve oturumlar iptal (on-hesap ele gecirme savunmasi)', async () => {
  const pw = 'Saldirgan-Parola-1';
  const victim = store.addUser({ email: 'onhesap@example.com', password_hash: await bcrypt.hash(pw, 4), email_verified: false });
  // Saldirganin (on-kayit) acik oturumu
  store.refresh.push({ id: crypto.randomUUID(), user_id: victim.id, token_hash: 'x', family_id: crypto.randomUUID(), expires_at: new Date(Date.now() + 1e9), used_at: null, revoked_at: null });

  const res = await post('google', { id_token: googleToken({ sub: 'g-victim', email: 'onhesap@example.com' }) });
  assert.strictEqual(res.status, 200);
  assert.strictEqual(res.body.data.user.id, victim.id);
  const u = store.users.get(victim.id);
  assert.strictEqual(u.google_id, 'g-victim');
  assert.strictEqual(u.email_verified, true);
  assert.strictEqual(u.token_version, 2);
  assert.ok(!(await bcrypt.compare(pw, u.password_hash)), 'eski parola gecersiz olmali');
  assert.ok(store.refresh.filter((r) => r.user_id === victim.id && r.token_hash === 'x').every((r) => r.revoked_at));
});

test('uyelik-8: e-posta+sifreyle kayitli dogrulanmamis hesap Google ile baglaninca password_changed_at NULL, hesap sifresiz sayilir', async () => {
  const { isPasswordless } = require('../../src/services/account_deletion_service');
  const pw = 'Kayit-Parolasi-2026';
  const u0 = store.addUser({
    email: 'kayitli-dogrulanmamis@example.com', password_hash: await bcrypt.hash(pw, 4), email_verified: false,
    password_changed_at: new Date(Date.now() - 86400000),
  });
  const res = await post('google', { id_token: googleToken({ sub: 'g-sifresiz', email: 'kayitli-dogrulanmamis@example.com' }) });
  assert.strictEqual(res.status, 200, JSON.stringify(res.body));
  const u = store.users.get(u0.id);
  assert.strictEqual(u.password_changed_at, null, 'bilinen parola artik yok');
  assert.strictEqual(u.must_change_password, false);
  assert.strictEqual(isPasswordless(u), true, 'hesap silme SİL onayiyla calisir');
});

test('uyelik-8: must_change_password=TRUE dogrulanmamis hesap Google ile girince bayrak FALSE', async () => {
  const u0 = store.addUser({
    email: 'zorunlu-degisim@example.com', password_hash: await bcrypt.hash('Gecici-Parola-2026', 4), email_verified: false,
    must_change_password: true, password_changed_at: new Date(),
  });
  const res = await post('google', { id_token: googleToken({ sub: 'g-zorunlu', email: 'zorunlu-degisim@example.com' }) });
  assert.strictEqual(res.status, 200, JSON.stringify(res.body));
  assert.strictEqual(res.body.data.user.must_change_password, false);
  const u = store.users.get(u0.id);
  assert.strictEqual(u.must_change_password, false);
  assert.strictEqual(u.password_changed_at, null);
});

test('google: dogrulanmis e-postali mevcut hesaba parola korunarak baglanir', async () => {
  const pw = 'Mesru-Parola-2026';
  const owner = store.addUser({ email: 'dogru@example.com', password_hash: await bcrypt.hash(pw, 4), email_verified: true });
  const res = await post('google', { id_token: googleToken({ sub: 'g-owner', email: 'dogru@example.com' }) });
  assert.strictEqual(res.status, 200);
  const u = store.users.get(owner.id);
  assert.strictEqual(u.google_id, 'g-owner');
  assert.ok(await bcrypt.compare(pw, u.password_hash));
});

test('google: e-posta baska bir Google kimligine bagliysa 409', async () => {
  store.addUser({ email: 'bagli@example.com', google_id: 'g-ilk', email_verified: true });
  const res = await post('google', { id_token: googleToken({ sub: 'g-ikinci', email: 'bagli@example.com' }) });
  assert.strictEqual(res.status, 409);
});

test('google: askidaki hesap giremez', async () => {
  store.addUser({ email: 'askida.g@example.com', google_id: 'g-askida', is_active: false, account_status: 'suspended' });
  const res = await post('google', { id_token: googleToken({ sub: 'g-askida', email: 'askida.g@example.com' }) });
  assert.strictEqual(res.status, 403);
});

// ----------------------------- APPLE ----------------------------------------
test('apple: identity_token yoksa 400; istemcinin user_id/email alanlariyla GIRIS YOK', async () => {
  const before = store.users.size;
  const res = await post('apple', { user_id: 'apple-sub-1', email: 'kurban@example.com' });
  assert.strictEqual(res.status, 400);
  assert.strictEqual(store.users.size, before);
});

test('apple: APPLE_CLIENT_IDS yoksa 503', async () => {
  const saved = process.env.APPLE_CLIENT_IDS;
  delete process.env.APPLE_CLIENT_IDS;
  try {
    assert.strictEqual((await post('apple', { identity_token: await appleToken() })).status, 503);
  } finally {
    process.env.APPLE_CLIENT_IDS = saved;
  }
});

test('apple: yanlis iss / yanlis aud / suresi dolmus / imzasi bozuk -> 401', async () => {
  const bad = [
    await appleToken({}, { iss: 'https://evil.example' }),
    await appleToken({}, { aud: 'baska.uygulama' }),
    await appleToken({}, { exp: Math.floor(Date.now() / 1000) - 60 }),
  ];
  const good = await appleToken();
  bad.push(good.slice(0, -4) + (good.endsWith('AAAA') ? 'BBBB' : 'AAAA'));
  for (const t of bad) {
    const res = await post('apple', { identity_token: t });
    assert.strictEqual(res.status, 401);
  }
});

test('apple: gecerli jeton -> hesap (apple_id); ad yalnizca gorunen ad olarak alinir', async () => {
  const res = await post('apple', { identity_token: await appleToken({ sub: 'apple-ok', email: 'ok@privaterelay.appleid.com' }), full_name: 'Elma Kisi' });
  assert.strictEqual(res.status, 200, JSON.stringify(res.body));
  const u = [...store.users.values()].find((x) => x.apple_id === 'apple-ok');
  assert.ok(u);
  assert.strictEqual(u.full_name, 'Elma Kisi');
  assert.strictEqual(u.email, 'ok@privaterelay.appleid.com');
});

test('apple: e-posta paylasilmadiysa teslim edilemeyen yer tutucu (.invalid) ile hesap', async () => {
  const res = await post('apple', { identity_token: await appleToken({ sub: 'apple-noemail', email: undefined, email_verified: undefined }) });
  assert.strictEqual(res.status, 200);
  const u = [...store.users.values()].find((x) => x.apple_id === 'apple-noemail');
  assert.match(u.email, /@users\.noreply\.invalid$/);
});

test('apple: nonce gonderildiyse eslesmeli', async () => {
  const raw = 'ham-nonce-degeri-123';
  const hashed = crypto.createHash('sha256').update(raw).digest('hex');
  const tok = await appleToken({ sub: 'apple-nonce', nonce: hashed });
  assert.strictEqual((await post('apple', { identity_token: tok, nonce: 'baska-nonce' })).status, 401);
  assert.strictEqual((await post('apple', { identity_token: tok, nonce: raw })).status, 200);
});

test('apple: dogrulanmamis e-posta mevcut hesaba BAGLANMAZ (ayri hesap acilir)', async () => {
  const existing = store.addUser({ email: 'hedef@example.com', email_verified: true });
  const res = await post('apple', { identity_token: await appleToken({ sub: 'apple-unv', email: 'hedef@example.com', email_verified: 'false' }) });
  assert.strictEqual(res.status, 200);
  assert.notStrictEqual(res.body.data.user.id, existing.id);
  assert.strictEqual(store.users.get(existing.id).apple_id, null);
});

test('sahte DB: eslesmeyen SQL yok', () => {
  assert.deepStrictEqual(store.unmatched, []);
});
