'use strict';

// ==============================================================================
// AHBU Akilli Ev - Kimlik dogrulama uclari (/api/v1/auth/* ve eski /api/auth/*)
// ==============================================================================
// Tum yanitlar `Cache-Control: no-store` (token tasir). Hatalar global hata
// yakalayiciya (middlewares/error_handler) iletilir: { success:false, message, code }.

const crypto = require('node:crypto');
const express = require('express');
const db = require('../db');
const authService = require('../services/auth_service');
const serviceTokenService = require('../services/service_token_service');
const jwtConfig = require('../middlewares/jwt_config');
const { authenticateToken, rejectServiceSession, invalidateServiceSessionCache } = require('../middlewares/auth_middleware');
const { rateLimit, clientIp, limitKey, limitKey48 } = require('../middlewares/rate_limit');
const { asyncHandler } = require('../middlewares/error_handler');
const { successResponse, HttpError, isUuid } = require('../utils/helpers');

const router = express.Router();
const MIN = 60 * 1000;

// IP basina sayac anahtari: IPv6 /64 onekine indirgenir (M1-01; IPv4 aynen). Denetim `ip` alani tam adrestir.
function ipKey(prefix) {
  return (req) => `${prefix}:${limitKey(req)}`;
}

// Yenileme sayaci anahtari (uyelik-5): sunulan refresh token'in OZETI (token basina; ham token anahtarda TASINMAZ).
// Govdede token yoksa IP anahtari. Ortak NAT arkasindaki site sakinleri (ayni IP) birbirini kilitlemez.
function refreshTokenKey(req) {
  const raw = str(pick(req.body, ['refresh_token', 'refreshToken']));
  if (!raw) return `refresh-ip:${limitKey(req)}`;
  return `refresh-tok:${crypto.createHash('sha256').update(raw, 'utf8').digest('hex').slice(0, 32)}`;
}

// IP basina hiz sinirlari (CONTRACTS §1.3: service-login 10 / 15 dk). Ortak NAT (site, mobil operator) arkasinda cok
// sayida mesru istemci ayni IP'yi paylasir (uyelik-5): kimlik bazli sayaclar (loginFailures, _checkResendLimits)
// asil korumadir; IP sinirlari yalniz kaba tavandir.
const limiters = {
  login: rateLimit({ windowMs: 15 * MIN, max: 200, keyGenerator: ipKey('login') }),
  register: rateLimit({ windowMs: 60 * MIN, max: 50, keyGenerator: ipKey('register') }),
  refresh: rateLimit({ windowMs: 15 * MIN, max: 10, keyGenerator: refreshTokenKey }),
  refreshIp: rateLimit({ windowMs: 15 * MIN, max: 1000, keyGenerator: ipKey('refresh') }),
  logout: rateLimit({ windowMs: 15 * MIN, max: 60, keyGenerator: ipKey('logout') }),
  forgot: rateLimit({ windowMs: 60 * MIN, max: 50, keyGenerator: ipKey('forgot') }),
  reset: rateLimit({ windowMs: 15 * MIN, max: 30, keyGenerator: ipKey('reset') }),
  magic: rateLimit({ windowMs: 15 * MIN, max: 20, keyGenerator: ipKey('magic') }),
  otpSend: rateLimit({ windowMs: 60 * MIN, max: 10, keyGenerator: ipKey('otp-send') }),
  otpVerify: rateLimit({ windowMs: 15 * MIN, max: 30, keyGenerator: ipKey('otp-verify') }),
  social: rateLimit({ windowMs: 15 * MIN, max: 30, keyGenerator: ipKey('social') }),
  serviceLogin: rateLimit({ windowMs: 15 * MIN, max: 10, keyGenerator: ipKey('service-login') }),
  // Yetenek bilgisi (kimliksiz, ucuz): giris ekrani her acilista sorar; NAT arkasi coklu istemci icin hafif sinir
  // (giris sinirindan siki OLMAZ: uyelik-5 ile giris 200 / 15 dk oldu).
  capabilities: rateLimit({ windowMs: 15 * MIN, max: 600, keyGenerator: ipKey('capabilities') }),
  account: rateLimit({ windowMs: 15 * MIN, max: 10, keyGenerator: (req) => `account:${req.user && req.user.id ? req.user.id : clientIp(req)}` }),
  // Hesap silme: her istek parola tahmini olabilir -> kullanici basina siki sinir
  accountDelete: rateLimit({ windowMs: 15 * MIN, max: 5, keyGenerator: (req) => `account-delete:${req.user && req.user.id ? req.user.id : clientIp(req)}` }),
};

// BASARISIZ parola girisi sayaclari (programatik kullanim; yalniz 401'de artar, basarida ikisi de sifirlanir).
// Iki katman: ucuncu kisi kendi IP'sinden yanlis deneyerek hesap sahibini KILITLEYEMEZ (UYELIK-10), dagitik
// denemenin de bir tavani vardir. Herhangi biri asilinca 429 RATE_LIMITED.
//  - (kimlik | IP) basina 10 / 15 dk
//  - kimlik basina TOPLAM 50 / 15 dk
const loginFailures = rateLimit({ windowMs: 15 * MIN, max: 10 });
const loginFailuresTotal = rateLimit({ windowMs: 15 * MIN, max: 50 });

// BASARISIZ servis PIN girisi butceleri (ev_uyelik-1; yalniz 401'de artar). PIN 6 hanedir (10^6): IP basina sinir
// (limiters.serviceLogin, /64 basina 10 / 15 dk) tek basina dagitik denemeyi durdurmaz.
//  - ag obegi (IPv4 tam adres, IPv6 /48) basina 20 / 15 dk; basarili giris bu sayaci sifirlar
//  - GENEL (tum istemciler) 100 / 15 dk; sabit tek anahtar (maxKeys tahliyesinden etkilenmez), basariyla SIFIRLANMAZ.
//    Genel butce dolunca YALNIZ bu pencerede en az SERVICE_PIN_NET_FAILS_WHEN_EXHAUSTED hatasi olan aglar engellenir
//    (inceleme): ~10 adresle butceyi doldurup TUM gecici teknisyenleri kilitlemek (ucuz DoS) mumkun olmasin; hatasi
//    olmayan (taze) ag denemesini yapar. Dagitik saldirgan dolu pencerede ag basina en cok bu kadar deneme yapabilir.
const serviceLoginFailNet = rateLimit({ windowMs: 15 * MIN, max: 20 });
const serviceLoginFailAll = rateLimit({ windowMs: 15 * MIN, max: 100 });
const SERVICE_PIN_FAIL_ALL_KEY = 'svc-pin-fail:all';
const SERVICE_PIN_NET_FAILS_WHEN_EXHAUSTED = 3;
let servicePinBudgetWarnedFor = null; // genel butce doldu uyarisi: pencere (resetAt) basina BIR kez

function pick(body, keys) {
  if (!body || typeof body !== 'object') return undefined;
  for (const k of keys) {
    const v = body[k];
    if (v !== undefined && v !== null && v !== '') return v;
  }
  return undefined;
}

function str(value) {
  return typeof value === 'string' ? value : (typeof value === 'number' ? String(value) : undefined);
}

router.use((req, res, next) => {
  res.setHeader('Cache-Control', 'no-store');
  res.setHeader('Pragma', 'no-cache');
  next();
});

// POST /auth/register
router.post('/register', limiters.register, asyncHandler(async (req, res) => {
  const result = await authService.register(
    {
      full_name: str(pick(req.body, ['full_name', 'fullName', 'name'])),
      email: str(pick(req.body, ['email'])),
      password: pick(req.body, ['password']),
      phone: str(pick(req.body, ['phone'])),
    },
    { ip: clientIp(req) }
  );
  return successResponse(res, result, 'Kayıt başarıyla tamamlandı.', 201);
}));

// POST /auth/login (e-posta veya telefon + sifre)
router.post('/login', limiters.login, asyncHandler(async (req, res) => {
  const identifier = str(pick(req.body, ['identifier', 'email', 'phone']));
  const password = req.body ? req.body.password : undefined;
  if (!identifier || typeof password !== 'string' || !password) {
    throw new HttpError(400, 'E-posta/telefon ve şifre alanları zorunludur.', 'VALIDATION');
  }
  // Normalize kimlik: "+90 555 ..." ve "+90555..." ayni sayaci paylasir.
  const parsed = authService.parseIdentifier(identifier);
  const ip = clientIp(req);
  // Sayac anahtari kimligin ham kopyasini TASIMAZ (M1-02): sha256(normalize kimlik) -> sabit 64 karakter; IP kismi
  // /64 indirgemeli (M1-01). Uzun kimlik reddedilmez (400 yeni bir istemci metni gerektirirdi); sayilmaya devam eder.
  const idDigest = crypto
    .createHash('sha256')
    .update(parsed ? parsed.value : identifier.trim().toLowerCase(), 'utf8')
    .digest('hex');
  const totalKey = `login-id:${idDigest}`;
  const pairKey = `${totalKey}|${limitKey(req)}`;
  const blocked = [loginFailures.peek(pairKey), loginFailuresTotal.peek(totalKey)].filter((s) => !s.allowed);
  if (blocked.length > 0) {
    const err = new HttpError(429, 'Çok fazla hatalı giriş denemesi. Lütfen daha sonra tekrar deneyin.', 'RATE_LIMITED');
    err.retryAfter = Math.max(...blocked.map((s) => s.retryAfter));
    throw err;
  }
  try {
    const result = await authService.login(identifier, password, { ip });
    loginFailures.resetKey(pairKey);
    loginFailuresTotal.resetKey(totalKey);
    return successResponse(res, result, 'Giriş başarılı.');
  } catch (err) {
    if (err && (err.status === 401 || err.statusCode === 401)) {
      loginFailures.consume(pairKey);
      loginFailuresTotal.consume(totalKey);
    }
    throw err;
  }
}));

// POST /auth/refresh (rotation; kullanilmis token tekrar gelirse aile iptal)
router.post('/refresh', limiters.refreshIp, limiters.refresh, asyncHandler(async (req, res) => {
  const refreshToken = str(pick(req.body, ['refresh_token', 'refreshToken']));
  if (!refreshToken) throw new HttpError(400, 'Refresh token zorunludur.', 'VALIDATION');
  const result = await authService.refreshToken(refreshToken, { ip: clientIp(req) });
  return successResponse(res, result, 'Oturum yenilendi.');
}));

// POST /auth/logout (bu cihazin oturum ailesini iptal eder). Govdede refresh_token YOKSA ve Authorization'da gecerli
// bir servis (PIN) oturumu belirteci varsa o oturum sunucuda kapatilir (uyelik-12): iptal + o evin servis oturumu MQTT
// kimlikleri silinip atilir. Gecersiz / eksik belirtec sessizce yok sayilir; yanit her durumda 200.
router.post('/logout', limiters.logout, asyncHandler(async (req, res) => {
  const refreshToken = str(pick(req.body, ['refresh_token', 'refreshToken']));
  if (refreshToken) {
    await authService.revokeToken(refreshToken);
  } else {
    await revokeOwnServiceSession(req);
  }
  return successResponse(res, null, 'Oturum sonlandırıldı.');
}));

/** uyelik-12: servis oturumunun kendi cikisi. En iyi caba: ASLA firlatmaz (yanit her durumda 200). */
async function revokeOwnServiceSession(req) {
  try {
    const header = req.headers && req.headers.authorization;
    const m = typeof header === 'string' ? header.match(/^Bearer\s+([A-Za-z0-9\-_]+\.[A-Za-z0-9\-_]+\.[A-Za-z0-9\-_]+)\s*$/i) : null;
    if (!m) return;
    const { payload, expired } = jwtConfig.verifyToken(m[1]);
    if (expired || !payload || payload.role !== 'service_session' || !isUuid(String(payload.sid || ''))) return;
    const r = await db.query(
      `UPDATE service_sessions SET revoked_at = NOW(), revoked_reason = 'self_logout'
        WHERE id = $1 AND revoked_at IS NULL
        RETURNING home_id`,
      [payload.sid]
    );
    const row = r.rows && r.rows[0];
    if (!row) return;
    invalidateServiceSessionCache(payload.sid);
    const mqtt = serviceTokenService._mqtt();
    if (mqtt && typeof mqtt.revokeServiceSessionAccess === 'function') {
      await mqtt.revokeServiceSessionAccess({ homeId: row.home_id }); // tx'siz: silinir ve atilir
    }
    if (typeof serviceTokenService.sweepEndedSessions === 'function') {
      await serviceTokenService.sweepEndedSessions({ homeId: row.home_id });
    }
  } catch (err) {
    console.warn('[AUTH] Servis oturumu cikisi tamamlanamadi:', err && err.code ? err.code : 'hata');
  }
}

// POST /auth/logout-all (tum cihazlar: refresh + token_version + uygulama MQTT kimlikleri tek transaction'da;
// acik MQTT baglantilari ve push belirtecleri COMMIT sonrasi - auth_service.revokeAllUserSessions)
router.post('/logout-all', authenticateToken, rejectServiceSession, limiters.account, asyncHandler(async (req, res) => {
  await authService.revokeAllUserSessions(req.user.id, { reason: 'logout_all' });
  return successResponse(res, null, 'Tüm oturumlarınız sonlandırıldı.');
}));

// POST /auth/change-password (mevcut sifre ile; diger tum oturumlar duser)
router.post('/change-password', authenticateToken, rejectServiceSession, limiters.account, asyncHandler(async (req, res) => {
  const result = await authService.changePassword(
    req.user.id,
    {
      current_password: pick(req.body, ['current_password', 'currentPassword', 'old_password']),
      new_password: pick(req.body, ['new_password', 'newPassword']),
    },
    { ip: clientIp(req) }
  );
  return successResponse(res, result, 'Şifreniz değiştirildi. Diğer tüm oturumlarınız kapatıldı.');
}));

// DELETE /auth/account { password } veya (sifresiz/sosyal hesap) { confirm: "SİL" }
// Yumusak silme + anonimlestirme (WP-B2, services/account_deletion_service.js). Staff/super 403;
// tek sahibi oldugu ve baska uyesi/cihazi olan ev varsa 409 SOLE_OWNER + ev listesi; bos (uyesiz+cihazsiz)
// tek-sahipli evler silinir (released_homes). Eski e-posta serbest kalir (yeniden kayit mumkun).
router.delete('/account', authenticateToken, rejectServiceSession, limiters.accountDelete, asyncHandler(async (req, res) => {
  const result = await authService.deleteAccount({
    userId: req.user.id,
    password: str(pick(req.body, ['password', 'current_password', 'currentPassword'])),
    confirm: str(pick(req.body, ['confirm', 'confirmation'])),
    ip: clientIp(req),
  });
  return successResponse(res, result, result.message);
}));

// POST /auth/forgot-password (kod + tek kullanimlik baglanti e-postasi)
router.post('/forgot-password', limiters.forgot, asyncHandler(async (req, res) => {
  const identifier = str(pick(req.body, ['identifier', 'email', 'phone']));
  if (!identifier) throw new HttpError(400, 'E-posta veya telefon zorunludur.', 'VALIDATION');
  const result = await authService.requestPasswordReset(identifier, { ip: clientIp(req) });
  return successResponse(res, result, result.message);
}));

// POST /auth/reset-password (kod veya baglanti token'i ile yeni sifre)
router.post('/reset-password', limiters.reset, asyncHandler(async (req, res) => {
  const result = await authService.resetPassword(
    {
      identifier: str(pick(req.body, ['identifier', 'email', 'phone'])),
      code: str(pick(req.body, ['code', 'otp_code', 'otpCode', 'otp'])),
      token: str(pick(req.body, ['token', 'magic_token', 'magicToken'])),
      new_password: pick(req.body, ['new_password', 'newPassword', 'password']),
    },
    { ip: clientIp(req) }
  );
  return successResponse(res, result, result.message);
}));

// POST /auth/magic-login { token } - tek kullanimlik baglanti ile giris
router.post('/magic-login', limiters.magic, asyncHandler(async (req, res) => {
  const token = str(pick(req.body, ['token', 'magic_token', 'magicToken']));
  const result = await authService.magicLogin(token, { ip: clientIp(req) });
  return successResponse(res, result, 'Giriş başarılı.');
}));

// GET /auth/magic-login/:token - GET ile oturum ACILMAZ (baglanti on-izleyicileri/tarayici
// gecmisi token'i tuketip oturum acmasin). Istemci token'i POST ile gondermelidir.
router.get('/magic-login/:token?', (req, res) => {
  res.setHeader('Allow', 'POST');
  return res.status(405).json({
    success: false,
    message: 'Bu bağlantı uygulama içinden açılmalıdır.',
    code: 'METHOD_NOT_ALLOWED',
  });
});

// POST /auth/service-login { service_pin, technician_name } (CONTRACTS §1.3)
router.post('/service-login', limiters.serviceLogin, asyncHandler(async (req, res) => {
  const pin = str(pick(req.body, ['service_pin', 'servicePin', 'pin']));
  if (!pin) throw new HttpError(400, 'Servis PIN kodu zorunludur.', 'VALIDATION');
  // Hatali deneme butceleri (ev_uyelik-1): engellenen istekte PIN DENENMEZ (dogru PIN de tuketilmez).
  //  - ag butcesi doluysa o ag engellenir (ag sayaci sifirlanana kadar)
  //  - genel butce doluysa YALNIZ bu pencerede >= SERVICE_PIN_NET_FAILS_WHEN_EXHAUSTED hatasi olan ag engellenir; engel
  //    genel ya da ag penceresinden HANGISI once biterse kalkar
  const netKey = `svc-pin-fail:${limitKey48(req)}`;
  const net = serviceLoginFailNet.peek(netKey);
  const all = serviceLoginFailAll.peek(SERVICE_PIN_FAIL_ALL_KEY);
  let retryAfter = 0;
  if (!net.allowed) retryAfter = net.retryAfter;
  else if (!all.allowed && net.count >= SERVICE_PIN_NET_FAILS_WHEN_EXHAUSTED) retryAfter = Math.min(net.retryAfter, all.retryAfter);
  if (retryAfter > 0) {
    const err = new HttpError(429, 'Çok fazla hatalı servis PIN denemesi. Lütfen daha sonra tekrar deneyin.', 'RATE_LIMITED');
    err.retryAfter = retryAfter;
    throw err;
  }
  try {
    const result = await serviceTokenService.loginWithServicePin(
      pin,
      str(pick(req.body, ['technician_name', 'technicianName'])),
      { ip: clientIp(req) }
    );
    serviceLoginFailNet.resetKey(netKey); // genel sayac SIFIRLANMAZ
    return successResponse(res, result, 'Yetkili servis oturumu başlatıldı.');
  } catch (err) {
    if (err && (err.status === 401 || err.statusCode === 401)) {
      serviceLoginFailNet.consume(netKey);
      const total = serviceLoginFailAll.consume(SERVICE_PIN_FAIL_ALL_KEY);
      if (total.count >= total.limit && servicePinBudgetWarnedFor !== total.resetAt) {
        servicePinBudgetWarnedFor = total.resetAt;
        console.warn(
          `[AUTH] Servis PIN genel hata butcesi doldu; bu pencerede ${SERVICE_PIN_NET_FAILS_WHEN_EXHAUSTED}+ hatali denemesi olan aglar gecici olarak engelleniyor.`
        );
      }
    }
    throw err;
  }
}));

// GET /auth/capabilities - kimliksiz: giris yollari sunucuda calisir mi (UYELIK-04). Istemci calismayan yolu
// (ornegin SMS saglayicisi bagli degilken telefon-OTP) giris ekraninda gizler. { sms_otp, google, apple } (boolean).
router.get('/capabilities', limiters.capabilities, (req, res) => successResponse(res, authService.getCapabilities()));

// GET /auth/me (profil + evler; servis oturumunda tek ev)
router.get('/me', authenticateToken, asyncHandler(async (req, res) => {
  const result = await authService.getProfile(req.user);
  return successResponse(res, result);
}));

// GET /auth/homes (GET /homes ile ayni)
router.get('/homes', authenticateToken, asyncHandler(async (req, res) => {
  const result = await authService.getProfile(req.user);
  return successResponse(res, result.homes);
}));

// POST /auth/google { id_token } - YALNIZCA dogrulanmis jeton; geri donus yolu YOK.
router.post('/google', limiters.social, asyncHandler(async (req, res) => {
  const result = await authService.loginWithGoogle(
    { id_token: str(pick(req.body, ['id_token', 'idToken'])) },
    { ip: clientIp(req) }
  );
  return successResponse(res, result, 'Google ile giriş başarılı.');
}));

// POST /auth/apple { identity_token, full_name?, nonce? } - YALNIZCA dogrulanmis jeton.
router.post('/apple', limiters.social, asyncHandler(async (req, res) => {
  const result = await authService.loginWithApple(
    {
      identity_token: str(pick(req.body, ['identity_token', 'identityToken', 'id_token'])),
      full_name: str(pick(req.body, ['full_name', 'fullName', 'name'])),
      nonce: str(pick(req.body, ['nonce', 'raw_nonce', 'rawNonce'])),
    },
    { ip: clientIp(req) }
  );
  return successResponse(res, result, 'Apple ile giriş başarılı.');
}));

// POST /auth/otp/send { phone }
router.post('/otp/send', limiters.otpSend, asyncHandler(async (req, res) => {
  const result = await authService.sendPhoneOtp(str(pick(req.body, ['phone'])), { ip: clientIp(req) });
  return successResponse(res, result, result.message);
}));

// POST /auth/otp/verify { phone, code }
router.post('/otp/verify', limiters.otpVerify, asyncHandler(async (req, res) => {
  const result = await authService.verifyPhoneOtp(
    str(pick(req.body, ['phone'])),
    str(pick(req.body, ['code', 'otp'])),
    { ip: clientIp(req) }
  );
  return successResponse(res, result, 'Telefon doğrulaması ve giriş başarılı.');
}));

router.limiters = limiters;
router.loginFailures = loginFailures;
router.loginFailuresTotal = loginFailuresTotal;
router.serviceLoginFailures = { net: serviceLoginFailNet, all: serviceLoginFailAll };
module.exports = router;
