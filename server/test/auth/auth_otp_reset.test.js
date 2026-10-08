'use strict';

// A5: telefon OTP ve sifre sifirlama.
//  - kodlar DB'de HMAC ozeti; token SHA-256 ozeti; duz metin YOK
//  - yeniden istek: 60 sn bekleme + saatte 5
//  - deneme sayaci ATOMIK ve yeniden gonderimle SIFIRLANMAZ
//  - gonderim basarisiz -> hata (sahte basari yok)
//  - debug_* yalnizca ALLOW_DEBUG_OTP=true ve uretim disi
//  - kod/token LOG'LANMAZ
//  - sihirli baglanti: GET ile oturum ACILMAZ, POST tek kullanim

const test = require('node:test');
const assert = require('node:assert');
const crypto = require('crypto');
const express = require('express');
const request = require('supertest');
const bcrypt = require('bcryptjs');
const { setTestEnv, installFakeDb } = require('./_helpers');
const { createAuthStore } = require('./_auth_store');

setTestEnv({ BCRYPT_TEST_COST: '4' });
const fakeDb = installFakeDb();
let clock = Date.now();
const store = createAuthStore({ now: () => clock }).install(fakeDb);

const authRoutes = require('../../src/routes/auth_routes');
const authService = require('../../src/services/auth_service');
const mailer = require('../../src/utils/mailer');
const auth = require('../../src/middlewares/auth_middleware');
const { errorHandler } = require('../../src/middlewares/error_handler');

auth.configureAuthMiddleware({ cacheTtlMs: 0 });

const app = express();
app.use(express.json());
app.use('/api/v1/auth', authRoutes);
app.use(errorHandler);

const post = (path, body) => request(app).post(`/api/v1/auth/${path}`).send(body);
const advance = (sec) => { clock += sec * 1000; };

// Konsol yakalama: gizli degerlerin log'a dusmedigini dogrulamak icin.
const logs = [];
for (const level of ['log', 'info', 'warn', 'error', 'debug']) {
  const orig = console[level];
  console[level] = (...args) => {
    logs.push(args.map((a) => (a && a.stack ? a.stack : typeof a === 'string' ? a : JSON.stringify(a))).join(' '));
    if (process.env.TEST_VERBOSE) orig.apply(console, args);
  };
}
const logged = () => logs.join('\n');

let sentMails = [];
function useFakeSmtp({ fail = false } = {}) {
  mailer.setTransportFactory(() => ({
    sendMail: async (msg) => {
      if (fail) {
        const e = new Error(`SMTP 550 kod=${msg.text}`);
        e.code = 'EENVELOPE';
        throw e;
      }
      sentMails.push(msg);
      return { messageId: 'x' };
    },
  }));
}

test.beforeEach(() => {
  for (const l of Object.values(authRoutes.limiters)) l.reset();
  delete process.env.ALLOW_DEBUG_OTP;
  process.env.NODE_ENV = 'test';
  authService.setSmsSender(null);
  mailer.setTransportFactory(null);
  sentMails = [];
  advance(3600); // her test kendi saat penceresinde
});

// ============================== TELEFON OTP ==================================
test('otp: SMS servisi yok ve debug kapali -> 503 DELIVERY_FAILED, kod uretilmez', async () => {
  const before = store.otps.length;
  const res = await post('otp/send', { phone: '+905550000001' });
  assert.strictEqual(res.status, 503);
  assert.strictEqual(res.body.code, 'DELIVERY_FAILED');
  assert.strictEqual(store.otps.length, before);
});

test('otp: ALLOW_DEBUG_OTP uretimde YOK SAYILIR', async () => {
  process.env.ALLOW_DEBUG_OTP = 'true';
  process.env.NODE_ENV = 'production';
  const res = await post('otp/send', { phone: '+905550000002' });
  assert.strictEqual(res.status, 503);
  assert.strictEqual(res.body.debug_code, undefined);
});

test('otp: debug acik (gelistirme) -> debug_code; DB de yalnizca HMAC ozeti', async () => {
  process.env.ALLOW_DEBUG_OTP = 'true';
  const res = await post('otp/send', { phone: '+90 555 000 00 03' });
  assert.strictEqual(res.status, 200, JSON.stringify(res.body));
  const code = res.body.data.debug_code;
  assert.match(code, /^\d{6}$/);
  assert.strictEqual(res.body.data.resend_after, 60);
  const row = store.otps.filter((o) => o.phone === '+905550000003').pop();
  assert.match(row.otp_hash, /^h1\$[0-9a-f]{64}$/);
  assert.notStrictEqual(row.otp_hash.slice(3), crypto.createHash('sha256').update(code).digest('hex'));
  assert.ok(!logged().includes(code), 'OTP log a yazilmamali');
});

test('otp: SMS gonderici varsa kod yalnizca SMS ile gider (yanitta yok); basarisiz gonderim 503', async () => {
  const sms = [];
  authService.setSmsSender(async (phone, text) => { sms.push({ phone, text }); return { sent: true }; });
  const res = await post('otp/send', { phone: '+905550000004' });
  assert.strictEqual(res.status, 200);
  assert.strictEqual(res.body.data.debug_code, undefined);
  assert.strictEqual(sms.length, 1);
  const code = sms[0].text.match(/\d{6}/)[0];
  assert.ok(!logged().includes(code));

  authService.setSmsSender(async () => { throw new Error('sms down'); });
  advance(61);
  const fail = await post('otp/send', { phone: '+905550000004' });
  assert.strictEqual(fail.status, 503);
  const last = store.otps.filter((o) => o.phone === '+905550000004').pop();
  assert.ok(last.consumed_at, 'gonderilemeyen kod gecersiz kilinmali');
});

test('otp: 60 sn icinde yeniden istek -> 429 + resend_after; saatte en fazla 5', async () => {
  process.env.ALLOW_DEBUG_OTP = 'true';
  const phone = '+905550000005';
  assert.strictEqual((await post('otp/send', { phone })).status, 200);
  const again = await post('otp/send', { phone });
  assert.strictEqual(again.status, 429);
  assert.strictEqual(again.body.code, 'RATE_LIMITED');
  assert.ok(again.body.resend_after > 0 && again.body.resend_after <= 60);
  assert.ok(Number(again.headers['retry-after']) > 0);
  for (let i = 0; i < 4; i++) {
    advance(61);
    assert.strictEqual((await post('otp/send', { phone })).status, 200, `gonderim ${i + 2}`);
  }
  advance(61);
  const sixth = await post('otp/send', { phone });
  assert.strictEqual(sixth.status, 429);
});

test('otp: deneme sayaci atomik; 5 hatadan sonra kilit; YENIDEN GONDERIM SAYACI SIFIRLAMAZ', async () => {
  process.env.ALLOW_DEBUG_OTP = 'true';
  const phone = '+905550000006';
  const first = await post('otp/send', { phone });
  const code1 = first.body.data.debug_code;
  const wrong = code1 === '000000' ? '111111' : '000000';
  for (let i = 1; i <= 5; i++) {
    const r = await post('otp/verify', { phone, code: wrong });
    assert.strictEqual(r.status, 401);
    assert.strictEqual(r.body.remaining_attempts, 5 - i);
  }
  const locked = await post('otp/verify', { phone, code: code1 });
  assert.strictEqual(locked.status, 429);

  advance(61);
  const second = await post('otp/send', { phone });
  assert.strictEqual(second.status, 200);
  const row = store.otps.filter((o) => o.phone === phone).pop();
  assert.strictEqual(row.attempts, 5, 'yeni kod onceki deneme sayisini tasir');
  const still = await post('otp/verify', { phone, code: second.body.data.debug_code });
  assert.strictEqual(still.status, 429);
});

test('otp: dogru kod -> giris (yeni hesap); ayni kod ikinci kez kullanilamaz', async () => {
  process.env.ALLOW_DEBUG_OTP = 'true';
  const phone = '+905550000007';
  const s = await post('otp/send', { phone });
  const code = s.body.data.debug_code;
  const ok = await post('otp/verify', { phone, code });
  assert.strictEqual(ok.status, 200, JSON.stringify(ok.body));
  assert.ok(ok.body.data.access_token);
  const u = [...store.users.values()].find((x) => x.phone === phone);
  assert.ok(u);
  const reuse = await post('otp/verify', { phone, code });
  assert.strictEqual(reuse.status, 401);
});

test('otp: ayni telefonlu iki hesap -> 409 (rastgele hesaba giris yok)', async () => {
  process.env.ALLOW_DEBUG_OTP = 'true';
  const phone = '+905550000008';
  store.addUser({ phone });
  store.addUser({ phone });
  const s = await post('otp/send', { phone });
  const r = await post('otp/verify', { phone, code: s.body.data.debug_code });
  assert.strictEqual(r.status, 409);
});

test('otp: gecersiz girdiler 400', async () => {
  assert.strictEqual((await post('otp/send', { phone: '123' })).status, 400);
  assert.strictEqual((await post('otp/verify', { phone: '+905550000009', code: '12' })).status, 400);
});

// ============================== SIFRE SIFIRLAMA ==============================
async function makeUser(email, password = 'Eski-Parola-2026') {
  return store.addUser({ email, password_hash: await bcrypt.hash(password, 4), email_verified: false });
}

test('sifirlama: SMTP yok ve debug kapali -> herkes icin ayni 503 (hesap varligi sizmaz)', async () => {
  await makeUser('smtpyok@example.com');
  const a = await post('forgot-password', { email: 'smtpyok@example.com' });
  const b = await post('forgot-password', { email: 'olmayan@example.com' });
  assert.strictEqual(a.status, 503);
  assert.strictEqual(b.status, 503);
  assert.deepStrictEqual(a.body, b.body);
});

test('sifirlama: kayitli/kayitsiz kimlik ayni yanit; e-posta yalnizca kayitliya; yanitta kod YOK', async () => {
  useFakeSmtp();
  await makeUser('reset1@example.com');
  const a = await post('forgot-password', { email: 'RESET1@example.com' });
  const b = await post('forgot-password', { email: 'kimseyok@example.com' });
  assert.strictEqual(a.status, 200);
  assert.strictEqual(b.status, 200);
  assert.deepStrictEqual(Object.keys(a.body.data).sort(), Object.keys(b.body.data).sort());
  assert.strictEqual(a.body.data.debug_code, undefined);
  assert.strictEqual(sentMails.length, 1);
  assert.strictEqual(sentMails[0].to, 'reset1@example.com');
  assert.ok(!/\d{6}/.test(sentMails[0].subject), 'kod konu satirinda olmamali');
  const code = sentMails[0].text.match(/kodunuz: (\d{6})/)[1];
  const token = decodeURIComponent(sentMails[0].text.match(/#token=([^\s]+)/)[1]);
  const row = store.resets.filter((r) => r.identifier === 'reset1@example.com').pop();
  assert.match(row.code_hash, /^h1\$/);
  assert.strictEqual(row.token_hash, crypto.createHash('sha256').update(token).digest('hex'));
  assert.ok(!logged().includes(code), 'kod log a yazilmamali');
  assert.ok(!logged().includes(token), 'token log a yazilmamali');
});

test('sifirlama: dogru kod -> parola degisir, tv++, tum refresh iptal, e-posta dogrulanir, otomatik giris', async () => {
  useFakeSmtp();
  const u = await makeUser('reset2@example.com');
  store.refresh.push({ id: crypto.randomUUID(), user_id: u.id, token_hash: 'eski', family_id: crypto.randomUUID(), expires_at: new Date(clock + 1e9), used_at: null, revoked_at: null });
  await post('forgot-password', { email: 'reset2@example.com' });
  const code = sentMails.pop().text.match(/kodunuz: (\d{6})/)[1];
  const res = await post('reset-password', { email: 'reset2@example.com', code, new_password: 'Yepyeni-Parola-1' });
  assert.strictEqual(res.status, 200, JSON.stringify(res.body));
  assert.ok(res.body.data.access_token);
  const after = store.users.get(u.id);
  assert.strictEqual(after.token_version, 2);
  assert.strictEqual(after.email_verified, true);
  assert.ok(await bcrypt.compare('Yepyeni-Parola-1', after.password_hash));
  assert.ok(store.refresh.find((r) => r.token_hash === 'eski').revoked_at);
  // ayni kod tekrar kullanilamaz
  const again = await post('reset-password', { email: 'reset2@example.com', code, new_password: 'Baska-Parola-22' });
  assert.strictEqual(again.status, 400);
});

test('sifirlama: yeni parola politikaya uymali', async () => {
  const r = await post('reset-password', { email: 'x@example.com', code: '123456', new_password: 'kisa' });
  assert.strictEqual(r.status, 400);
});

test('sifirlama: 5 hatali kod -> kilit (429); yeniden istek sayaci sifirlamaz', async () => {
  useFakeSmtp();
  await makeUser('reset3@example.com');
  await post('forgot-password', { email: 'reset3@example.com' });
  const code = sentMails.pop().text.match(/kodunuz: (\d{6})/)[1];
  const wrong = code === '999999' ? '888888' : '999999';
  for (let i = 1; i <= 5; i++) {
    const r = await post('reset-password', { email: 'reset3@example.com', code: wrong, new_password: 'Yeni-Parola-2026' });
    assert.strictEqual(r.status, 400);
    assert.strictEqual(r.body.remaining_attempts, 5 - i);
  }
  const locked = await post('reset-password', { email: 'reset3@example.com', code, new_password: 'Yeni-Parola-2026' });
  assert.strictEqual(locked.status, 429);
  advance(61);
  await post('forgot-password', { email: 'reset3@example.com' });
  const code2 = sentMails.pop().text.match(/kodunuz: (\d{6})/)[1];
  const still = await post('reset-password', { email: 'reset3@example.com', code: code2, new_password: 'Yeni-Parola-2026' });
  assert.strictEqual(still.status, 429);
});

test('sifirlama: IP basina saatte 50 istek siniri (kimlikten bagimsiz; ortak NAT icin uyelik-5)', async () => {
  useFakeSmtp();
  for (let i = 0; i < 50; i++) {
    const r = await post('forgot-password', { email: `ip-limit-${i}@example.com` });
    assert.strictEqual(r.status, 200);
  }
  const blocked = await post('forgot-password', { email: 'ip-limit-x@example.com' });
  assert.strictEqual(blocked.status, 429);
  assert.strictEqual(blocked.body.code, 'RATE_LIMITED');
});

test('sifirlama: kimlik basina 60 sn bekleme ve saatte 5 istek (kayitsiz kimlik icin de ayni)', async () => {
  useFakeSmtp();
  for (const email of ['limit@example.com', 'limit-yok@example.com']) {
    authRoutes.limiters.forgot.reset(); // yalnizca kimlik bazli (DB) siniri sinanir
    if (email === 'limit@example.com') await makeUser(email);
    assert.strictEqual((await post('forgot-password', { email })).status, 200);
    const fast = await post('forgot-password', { email });
    assert.strictEqual(fast.status, 429);
    assert.ok(fast.body.resend_after > 0);
    for (let i = 0; i < 4; i++) { advance(61); assert.strictEqual((await post('forgot-password', { email })).status, 200); }
    advance(61);
    assert.strictEqual((await post('forgot-password', { email })).status, 429);
  }
});

test('sifirlama: e-posta gonderimi basarisiz -> 503 ve talep gecersiz kilinir; SMTP hata ayrintisi/kod log a dusmez', async () => {
  useFakeSmtp({ fail: true });
  await makeUser('mailfail@example.com');
  const res = await post('forgot-password', { email: 'mailfail@example.com' });
  assert.strictEqual(res.status, 503);
  assert.strictEqual(res.body.code, 'DELIVERY_FAILED');
  const row = store.resets.filter((r) => r.identifier === 'mailfail@example.com').pop();
  assert.ok(row.used_at);
  assert.ok(!/kod=/.test(logged()), 'SMTP hata mesaji (icerik) log a yazilmamali');
  assert.ok(!logged().includes('mailfail@example.com'), 'alici adresi acik yazilmamali');
});

test('sihirli baglanti: GET oturum ACMAZ (405) ve token tuketilmez; POST tek kullanimlik giris', async () => {
  useFakeSmtp();
  await makeUser('magic@example.com');
  await post('forgot-password', { email: 'magic@example.com' });
  const token = decodeURIComponent(sentMails.pop().text.match(/#token=([^\s]+)/)[1]);
  const get = await request(app).get(`/api/v1/auth/magic-login/${encodeURIComponent(token)}`);
  assert.strictEqual(get.status, 405);
  assert.strictEqual(get.body.access_token, undefined);
  const ok = await post('magic-login', { token });
  assert.strictEqual(ok.status, 200, JSON.stringify(ok.body));
  assert.ok(ok.body.data.access_token);
  const again = await post('magic-login', { token });
  assert.strictEqual(again.status, 400);
});

test('uyelik-10: davet bekleyen hesapla magic-login -> 403 ACCOUNT_PENDING ve baglanti TUKETILMEZ (parola belirlemede kullanilir)', async () => {
  useFakeSmtp();
  const u = await makeUser('bekleyen-magic@example.com');
  u.account_status = 'pending_invite';
  await post('forgot-password', { email: 'bekleyen-magic@example.com' });
  const token = decodeURIComponent(sentMails.pop().text.match(/#token=([^\s]+)/)[1]);
  const res = await post('magic-login', { token });
  assert.strictEqual(res.status, 403, JSON.stringify(res.body));
  assert.strictEqual(res.body.code, 'ACCOUNT_PENDING');
  const row = store.resets.filter((r) => r.identifier === 'bekleyen-magic@example.com').pop();
  assert.strictEqual(row.used_at, null, 'baglanti gecerli kalir');
  // ayni baglanti parola belirlemede calisir ve hesabi etkinlestirir
  const set = await post('reset-password', { token, new_password: 'Yeni-Bekleyen-Parola-1' });
  assert.strictEqual(set.status, 200, JSON.stringify(set.body));
  assert.strictEqual(store.users.get(u.id).account_status, 'active');
});

test('uyelik-10: askidaki hesapla magic-login -> 403 ACCOUNT_DISABLED, baglanti tuketilmez; gecersiz baglanti 400', async () => {
  useFakeSmtp();
  const u = await makeUser('askida-magic@example.com');
  await post('forgot-password', { email: 'askida-magic@example.com' });
  const token = decodeURIComponent(sentMails.pop().text.match(/#token=([^\s]+)/)[1]);
  u.account_status = 'suspended';
  u.is_active = false;
  const res = await post('magic-login', { token });
  assert.strictEqual(res.status, 403);
  assert.strictEqual(res.body.code, 'ACCOUNT_DISABLED');
  assert.strictEqual(store.resets.filter((r) => r.identifier === 'askida-magic@example.com').pop().used_at, null);
  assert.strictEqual((await post('magic-login', { token: 'z'.repeat(43) })).status, 400);
});

test('sifirlama baglantisi (token) ile yeni parola; ikinci kullanim reddedilir', async () => {
  useFakeSmtp();
  await makeUser('linkreset@example.com');
  await post('forgot-password', { email: 'linkreset@example.com' });
  const token = decodeURIComponent(sentMails.pop().text.match(/#token=([^\s]+)/)[1]);
  const ok = await post('reset-password', { token, new_password: 'Baglanti-Parola-1' });
  assert.strictEqual(ok.status, 200);
  const again = await post('reset-password', { token, new_password: 'Baglanti-Parola-2' });
  assert.strictEqual(again.status, 400);
});

test('hesap kurulum daveti (pending_invite): kod ile parola belirlenince hesap aktiflesir', async () => {
  useFakeSmtp();
  const u = store.addUser({ email: 'davetli@example.com', account_status: 'pending_invite', password_hash: await bcrypt.hash('rastgele-kullanilamaz', 4) });
  // WP-B cagri bicimi: nesne ({ userId, email, fullName })
  const invObj = await authService.createAccountSetupInvite({ userId: u.id, email: 'yok-sayilir@example.com', fullName: 'X' });
  assert.strictEqual(invObj.sent, true);
  assert.strictEqual(sentMails.pop().to, 'davetli@example.com', 'alici DB den okunur, cagiranin e-postasi degil');
  advance(61);
  const inv = await authService.createAccountSetupInvite(u.id);
  assert.strictEqual(inv.sent, true);
  assert.strictEqual(inv.debug_code, undefined);
  const mail = sentMails.pop();
  assert.match(mail.subject, /etkinleştir/i);
  const code = mail.text.match(/kodunuz: (\d{6})/)[1];
  const res = await post('reset-password', { email: 'davetli@example.com', code, new_password: 'Davet-Parola-2026' });
  assert.strictEqual(res.status, 200, JSON.stringify(res.body));
  assert.strictEqual(store.users.get(u.id).account_status, 'active');
});

test('sifirlama: gecersiz kimlik bicimi 400', async () => {
  assert.strictEqual((await post('forgot-password', { email: 'gecersiz' })).status, 400);
});

test('debug: ALLOW_DEBUG_OTP=true ise SMTP olmadan debug_code/debug_token doner (yalnizca gelistirme)', async () => {
  process.env.ALLOW_DEBUG_OTP = 'true';
  await makeUser('debug@example.com');
  const res = await post('forgot-password', { email: 'debug@example.com' });
  assert.strictEqual(res.status, 200);
  assert.match(res.body.data.debug_code, /^\d{6}$/);
  assert.ok(res.body.data.debug_token);
});

test('sahte DB: eslesmeyen SQL yok', () => {
  assert.deepStrictEqual(store.unmatched, []);
});
