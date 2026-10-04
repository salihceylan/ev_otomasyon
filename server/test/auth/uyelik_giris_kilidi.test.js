'use strict';

// UYELIK-10 (karar D9): basarisiz parola girisi icin IKI KATMANLI kilit (surec bellegi, 15 dk sabit pencere):
//   - (kimlik | IP) basina 10 basarisiz deneme  -> o IP'den o kimlik icin 429
//   - kimlik basina TOPLAM 50 basarisiz deneme  -> tum IP'lerden o kimlik icin 429 (dagitik deneme tavani)
// Ikisi de YALNIZ 401'de artar; basarili giriste ikisi de sifirlanir; herhangi biri asilinca 429 RATE_LIMITED
// (mevcut govde + Retry-After). Ucuncu kisi kendi IP'sinden 10 yanlis deneme yaparak hesap sahibini KILITLEYEMEZ.
//
// Farkli istemci IP'leri: uygulama `trust proxy` ile X-Forwarded-For'dan req.ip turetir (uretimde nginx).

const test = require('node:test');
const assert = require('node:assert');
const express = require('express');
const request = require('supertest');
const bcrypt = require('bcryptjs');
const { setTestEnv, installFakeDb } = require('./_helpers');
const { createAuthStore } = require('./_auth_store');

setTestEnv({ BCRYPT_TEST_COST: '4' });
const fakeDb = installFakeDb();
const store = createAuthStore().install(fakeDb);

const authRoutes = require('../../src/routes/auth_routes');
const { errorHandler } = require('../../src/middlewares/error_handler');

const app = express();
app.set('trust proxy', true);
app.use(express.json());
app.use('/api/v1/auth', authRoutes);
app.use(errorHandler);
const server = app.listen(0, '127.0.0.1');
test.after(() => new Promise((resolve) => server.close(() => resolve())));

const PW = 'Dogru-Parola-2026';
const HASH = bcrypt.hashSync(PW, 4);
const LOCK_MESSAGE = 'Çok fazla hatalı giriş denemesi. Lütfen daha sonra tekrar deneyin.';
let n = 0;

const login = (identifier, password, ip) =>
  request(server).post('/api/v1/auth/login').set('X-Forwarded-For', ip).send({ identifier, password });

function user(extra = {}) {
  return store.addUser({ email: `kilit${++n}@example.com`, password_hash: HASH, ...extra });
}

/** `count` kadar yanlis parola; her yanit 401 olmali. */
async function failMany(email, ip, count) {
  for (let i = 0; i < count; i++) {
    const r = await login(email, `yanlis-parola-${i}`, ip);
    assert.strictEqual(r.status, 401, `${ip} deneme ${i + 1}: ${JSON.stringify(r.body)}`);
  }
}

test.beforeEach(() => {
  // IP basina genel giris siniri (30/15 dk) bu dosyanin konusu degil: testler her IP'yi 30 istegin altinda tutar.
  for (const l of Object.values(authRoutes.limiters)) l.reset();
  authRoutes.loginFailures.reset();
  authRoutes.loginFailuresTotal.reset();
});

test('ucuncu kisi BASKA IP\'den 10 yanlis deneme yapsa da hesap sahibi kendi IP\'sinden dogru parolayla girer (200)', async () => {
  const u = user();
  await failMany(u.email, '203.0.113.7', 10);
  const ok = await login(u.email, PW, '198.51.100.20');
  assert.strictEqual(ok.status, 200, JSON.stringify(ok.body));
});

test('farkli IP\'lerden toplam 10 yanlis + dogru parola -> 200', async () => {
  const u = user();
  for (let i = 1; i <= 10; i++) await failMany(u.email, `203.0.113.${i}`, 1);
  const ok = await login(u.email, PW, '198.51.100.21');
  assert.strictEqual(ok.status, 200, JSON.stringify(ok.body));
});

test('AYNI IP\'den 10 yanlis -> o IP icin 429 (dogru parola dahil; govde + Retry-After); baska IP etkilenmez', async () => {
  const u = user();
  await failMany(u.email, '203.0.113.50', 10);
  const blocked = await login(u.email, PW, '203.0.113.50');
  assert.strictEqual(blocked.status, 429);
  assert.strictEqual(blocked.body.success, false);
  assert.strictEqual(blocked.body.code, 'RATE_LIMITED');
  assert.strictEqual(blocked.body.message, LOCK_MESSAGE);
  assert.ok(Number(blocked.headers['retry-after']) >= 1);
  assert.ok(blocked.body.retry_after >= 1);
  // farkli bicim (buyuk harf/bosluk) ayni sayaci paylasir
  const variant = await login(`  ${u.email.toUpperCase()} `, PW, '203.0.113.50');
  assert.strictEqual(variant.status, 429);
  const other = await login(u.email, PW, '198.51.100.22');
  assert.strictEqual(other.status, 200);
});

test('kimlik basina TOPLAM 50 dagitik yanlis deneme -> 429 (yeni IP\'den dogru parola dahil)', async () => {
  const u = user();
  for (let k = 1; k <= 5; k++) await failMany(u.email, `192.0.2.${k}`, 10);
  const blocked = await login(u.email, PW, '198.51.100.23');
  assert.strictEqual(blocked.status, 429);
  assert.strictEqual(blocked.body.code, 'RATE_LIMITED');
  assert.strictEqual(blocked.body.message, LOCK_MESSAGE);
  assert.ok(Number(blocked.headers['retry-after']) >= 1);
  // baska kimlik etkilenmez
  const v = user();
  assert.strictEqual((await login(v.email, PW, '198.51.100.23')).status, 200);
});

test('basarili giris IKI sayaci da sifirlar', async () => {
  const u = user();
  await failMany(u.email, '192.0.2.100', 9);
  for (let k = 1; k <= 4; k++) await failMany(u.email, `192.0.2.${100 + k}`, 10); // toplam 49
  const ok = await login(u.email, PW, '192.0.2.100');
  assert.strictEqual(ok.status, 200, JSON.stringify(ok.body));
  // sifirlanmasaydi: (kimlik|IP) 9 -> 1 deneme sonra kilit; toplam 49 -> 1 deneme sonra kilit
  await failMany(u.email, '192.0.2.100', 10);
  assert.strictEqual((await login(u.email, PW, '192.0.2.100')).status, 429, '(kimlik|IP) yeniden 10 hatada kilitlenir');
});

test('yalniz 401 sayilir: askidaki hesapta dogru parola (403) ve eksik alan (400) sayaci ARTIRMAZ', async () => {
  const u = user({ is_active: false, account_status: 'suspended' });
  for (let i = 0; i < 12; i++) {
    const r = await login(u.email, PW, '203.0.113.90');
    assert.strictEqual(r.status, 403, `deneme ${i + 1}`);
  }
  for (let i = 0; i < 12; i++) {
    const r = await request(server).post('/api/v1/auth/login').set('X-Forwarded-For', '203.0.113.91').send({ identifier: u.email });
    assert.strictEqual(r.status, 400);
  }
});

test('M1-01: ayni IPv6 /64 icinden 50 farkli adres -> (kimlik|IP) kilidi o /64 icin 10\'da tutar; baska agdan sahibi girer', async () => {
  const u = user();
  const statuses = [];
  for (let i = 1; i <= 50; i++) {
    const r = await login(u.email, `yanlis-${i}`, `2001:db8:1:2::${i.toString(16)}`);
    statuses.push(r.status);
  }
  assert.deepStrictEqual(statuses.slice(0, 10), Array(10).fill(401));
  assert.deepStrictEqual(statuses.slice(10), Array(40).fill(429), 'ayni /64: 11. denemeden itibaren kilit');
  // toplam sayac yalniz 10 artti (kilitli istekler sayilmaz): baska agdan dogru parola gecer
  const ok = await login(u.email, PW, '198.51.100.30');
  assert.strictEqual(ok.status, 200, JSON.stringify(ok.body));
  // komsu /64 ayri sayilir
  assert.strictEqual((await login(u.email, PW, '2001:db8:1:3::1')).status, 200);
});

test('M1-02: sayac anahtari kimligin ham kopyasini tasimaz; uzun kimlikte de sabit uzunluk (sha256)', async () => {
  const long = `${'a'.repeat(5000)}x`;
  const r = await login(long, 'yanlis-parola', '203.0.113.120');
  assert.strictEqual(r.status, 401, JSON.stringify(r.body));
  const total = authRoutes.loginFailuresTotal.keys();
  const pair = authRoutes.loginFailures.keys();
  assert.strictEqual(total.length, 1);
  assert.match(total[0], /^login-id:[0-9a-f]{64}$/);
  assert.strictEqual(pair.length, 1);
  assert.strictEqual(pair[0], `${total[0]}|203.0.113.120`);
  assert.ok(!pair[0].includes('aaaa'), 'ham kimlik bellekte tutulmaz');
});

test('sahte DB: eslesmeyen SQL yok', () => {
  assert.deepStrictEqual(store.unmatched, []);
});
