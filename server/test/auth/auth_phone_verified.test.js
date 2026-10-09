'use strict';

// hesap-uyelik-3 (sozlesme C9): telefon-OTP girisi yalniz DOGRULANMIS telefona baglanir (users.phone_verified, 041).
//  - kayitta (dogrulanmadan) yazilan telefon OTP ile o hesabi ACMAZ: 409 CONFLICT, reason PHONE_NOT_VERIFIED; telefon
//    baska hesaptan dusurulmez, yeni hesap acilmaz, OTP tuketilir
//  - OTP ile acilan (yer tutucu e-postali) hesap phone_verified=TRUE; yer tutucu hesap bayrak FALSE olsa da girer (TRUE yapilir)
//  - neutralizeUnverifiedAccount dogrulanmamis telefonu NULL'lar (gercek sahibi numarayi kullanabilir)

const test = require('node:test');
const assert = require('node:assert');
const crypto = require('crypto');
const express = require('express');
const request = require('supertest');
const { setTestEnv, installFakeDb } = require('./_helpers');
const { createAuthStore } = require('./_auth_store');

setTestEnv({ BCRYPT_TEST_COST: '4', ALLOW_DEBUG_OTP: 'true' });
const fakeDb = installFakeDb();
const store = createAuthStore({ now: () => Date.now() }).install(fakeDb);

const authService = require('../../src/services/auth_service');
const authRoutes = require('../../src/routes/auth_routes');
const auth = require('../../src/middlewares/auth_middleware');
const { errorHandler } = require('../../src/middlewares/error_handler');

auth.configureAuthMiddleware({ cacheTtlMs: 0 });
authService.setMqttCredentialService(Object.assign(Object.create(require('../../src/services/mqtt_credential_service')), {
  kickUsernames: async (names) => ({ requested: names.length, kicked: names.length, failed: 0, skipped: false, errors: [] }),
}));
authService.setPushService({ disableAllTokensForUser: async () => 0 });

const app = express();
app.use(express.json());
app.use('/api/v1/auth', authRoutes);
app.use(errorHandler);
const post = (p, body) => request(app).post(`/api/v1/auth/${p}`).send(body);
let n = 0;
const newPhone = () => `+90555${String(1000000 + (n++) * 7919 + crypto.randomInt(0, 7000)).slice(-7)}`;
const MSG = 'Bu telefon numarası doğrulanmamış bir hesapta kayıtlı. E-posta adresiniz ve şifrenizle giriş yapın.';

async function otp(phone) {
  const s = await post('otp/send', { phone });
  assert.strictEqual(s.status, 200, JSON.stringify(s.body));
  return post('otp/verify', { phone, code: s.body.data.debug_code });
}

test('kayitta dogrulanmadan yazilan telefon OTP ile o hesaba giris VERMEZ: 409 PHONE_NOT_VERIFIED; hesap/telefon degismez', async () => {
  const victimPhone = newPhone();
  const reg = await post('register', { full_name: 'Baskasi', email: `saldirgan-${n}@example.com`, password: 'Saldirgan-Parola-1', phone: victimPhone });
  assert.strictEqual(reg.status, 201, JSON.stringify(reg.body));
  const regId = reg.body.data.user.id;
  assert.strictEqual(store.users.get(regId).phone_verified, false, 'kayit telefonu dogrulanmamis');
  const usersBefore = store.users.size;

  const v = await otp(victimPhone);
  assert.strictEqual(v.status, 409, JSON.stringify(v.body));
  assert.strictEqual(v.body.code, 'CONFLICT');
  assert.strictEqual(v.body.reason, 'PHONE_NOT_VERIFIED');
  assert.strictEqual(v.body.message, MSG);
  assert.strictEqual(v.body.data, undefined, 'oturum/hesap bilgisi donmez');
  assert.strictEqual(store.users.size, usersBefore, 'yeni hesap acilmaz');
  assert.strictEqual(store.users.get(regId).phone, victimPhone, 'telefon baska hesaptan dusurulmez');
  assert.strictEqual(store.users.get(regId).phone_verified, false);
  assert.ok(store.otps.filter((o) => o.phone === victimPhone).every((o) => o.consumed_at), 'OTP tuketildi');
});

test('OTP ile acilan yer tutucu hesap phone_verified=TRUE; ikinci OTP girisi ayni hesaba', async () => {
  const phone = newPhone();
  const first = await otp(phone);
  assert.strictEqual(first.status, 200, JSON.stringify(first.body));
  const id = first.body.data.user.id;
  assert.strictEqual(store.users.get(id).phone_verified, true);
  for (const o of store.otps) if (o.phone === phone) o.created_at = new Date(Date.now() - 120 * 1000); // yeniden gonderim beklemesi
  const again = await otp(phone);
  assert.strictEqual(again.status, 200);
  assert.strictEqual(again.body.data.user.id, id);
});

test('yer tutucu (OTP) hesap bayrak FALSE kalmis olsa da girer ve bayrak TRUE yapilir (041 oncesi / dagitim arasi kayit)', async () => {
  const phone = newPhone();
  const u = store.addUser({ phone, email: `phone_${phone.replace(/[^0-9]/g, '')}@ahbu.local`, phone_verified: false });
  const v = await otp(phone);
  assert.strictEqual(v.status, 200, JSON.stringify(v.body));
  assert.strictEqual(v.body.data.user.id, u.id);
  assert.strictEqual(store.users.get(u.id).phone_verified, true);
});

test('dogrulanmis telefonlu gercek e-postali hesap (sosyal baglanmis OTP hesabi) OTP ile girer', async () => {
  const phone = newPhone();
  const u = store.addUser({ phone, email: `gercek-${n}@example.com`, phone_verified: true, email_verified: true });
  const v = await otp(phone);
  assert.strictEqual(v.status, 200, JSON.stringify(v.body));
  assert.strictEqual(v.body.data.user.id, u.id);
});

test('neutralizeUnverifiedAccount dogrulanmamis telefonu NULL\'lar; dogrulanmis telefona dokunmaz', async () => {
  const unusableHash = await authService._unusablePasswordHash();
  const a = store.addUser({ phone: newPhone(), email: `onhesap-${n}@example.com`, email_verified: false, phone_verified: false });
  await fakeDb.withTransaction((tx) => authService.neutralizeUnverifiedAccount(a.id, { tx, reason: 'x', unusableHash }));
  assert.strictEqual(store.users.get(a.id).phone, null, 'dogrulanmamis telefon serbest kalir');
  const phone = newPhone();
  const b = store.addUser({ phone, email: `onhesap2-${n}@example.com`, email_verified: false, phone_verified: true });
  await fakeDb.withTransaction((tx) => authService.neutralizeUnverifiedAccount(b.id, { tx, reason: 'x', unusableHash }));
  assert.strictEqual(store.users.get(b.id).phone, phone);
});
