'use strict';

// ==============================================================================
// AHBU Akilli Ev - Kimlik dogrulama uclari (/api/v1/auth/* ve eski /api/auth/*)
// ==============================================================================
// Tum yanitlar `Cache-Control: no-store` (token tasir). Hatalar global hata
// yakalayiciya (middlewares/error_handler) iletilir: { success:false, message, code }.

const express = require('express');
const authService = require('../services/auth_service');
const serviceTokenService = require('../services/service_token_service');
const { authenticateToken, rejectServiceSession } = require('../middlewares/auth_middleware');
const { rateLimit, clientIp } = require('../middlewares/rate_limit');
const { asyncHandler } = require('../middlewares/error_handler');
const { successResponse, HttpError } = require('../utils/helpers');

const router = express.Router();
const MIN = 60 * 1000;

function ipKey(prefix) {
  return (req) => `${prefix}:${clientIp(req)}`;
}

// IP basina hiz sinirlari (CONTRACTS §1.3: service-login 10 / 15 dk).
const limiters = {
  login: rateLimit({ windowMs: 15 * MIN, max: 30, keyGenerator: ipKey('login') }),
  register: rateLimit({ windowMs: 60 * MIN, max: 10, keyGenerator: ipKey('register') }),
  refresh: rateLimit({ windowMs: 15 * MIN, max: 60, keyGenerator: ipKey('refresh') }),
  logout: rateLimit({ windowMs: 15 * MIN, max: 60, keyGenerator: ipKey('logout') }),
  forgot: rateLimit({ windowMs: 60 * MIN, max: 10, keyGenerator: ipKey('forgot') }),
  reset: rateLimit({ windowMs: 15 * MIN, max: 30, keyGenerator: ipKey('reset') }),
  magic: rateLimit({ windowMs: 15 * MIN, max: 20, keyGenerator: ipKey('magic') }),
  otpSend: rateLimit({ windowMs: 60 * MIN, max: 10, keyGenerator: ipKey('otp-send') }),
  otpVerify: rateLimit({ windowMs: 15 * MIN, max: 30, keyGenerator: ipKey('otp-verify') }),
  social: rateLimit({ windowMs: 15 * MIN, max: 30, keyGenerator: ipKey('social') }),
  serviceLogin: rateLimit({ windowMs: 15 * MIN, max: 10, keyGenerator: ipKey('service-login') }),
  account: rateLimit({ windowMs: 15 * MIN, max: 10, keyGenerator: (req) => `account:${req.user && req.user.id ? req.user.id : clientIp(req)}` }),
  // Hesap silme: her istek parola tahmini olabilir -> kullanici basina siki sinir
  accountDelete: rateLimit({ windowMs: 15 * MIN, max: 5, keyGenerator: (req) => `account-delete:${req.user && req.user.id ? req.user.id : clientIp(req)}` }),
};

// Kimlik (e-posta/telefon) basina BASARISIZ giris sayaci (programatik kullanim).
const loginFailures = rateLimit({ windowMs: 15 * MIN, max: 10 });

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
  const failKey = `login-id:${parsed ? parsed.value : identifier.trim().toLowerCase()}`;
  const state = loginFailures.peek(failKey);
  if (!state.allowed) {
    const err = new HttpError(429, 'Çok fazla hatalı giriş denemesi. Lütfen daha sonra tekrar deneyin.', 'RATE_LIMITED');
    err.retryAfter = state.retryAfter;
    throw err;
  }
  try {
    const result = await authService.login(identifier, password, { ip: clientIp(req) });
    loginFailures.resetKey(failKey);
    return successResponse(res, result, 'Giriş başarılı.');
  } catch (err) {
    if (err && (err.status === 401 || err.statusCode === 401)) loginFailures.consume(failKey);
    throw err;
  }
}));

// POST /auth/refresh (rotation; kullanilmis token tekrar gelirse aile iptal)
router.post('/refresh', limiters.refresh, asyncHandler(async (req, res) => {
  const refreshToken = str(pick(req.body, ['refresh_token', 'refreshToken']));
  if (!refreshToken) throw new HttpError(400, 'Refresh token zorunludur.', 'VALIDATION');
  const result = await authService.refreshToken(refreshToken, { ip: clientIp(req) });
  return successResponse(res, result, 'Oturum yenilendi.');
}));

// POST /auth/logout (bu cihazin oturum ailesini iptal eder)
router.post('/logout', limiters.logout, asyncHandler(async (req, res) => {
  const refreshToken = str(pick(req.body, ['refresh_token', 'refreshToken']));
  if (refreshToken) await authService.revokeToken(refreshToken);
  return successResponse(res, null, 'Oturum sonlandırıldı.');
}));

// POST /auth/logout-all (tum cihazlar)
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
// tek sahibi oldugu ev varsa 409 SOLE_OWNER + ev listesi. Eski e-posta serbest kalir (yeniden kayit mumkun).
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
  const result = await serviceTokenService.loginWithServicePin(
    pin,
    str(pick(req.body, ['technician_name', 'technicianName'])),
    { ip: clientIp(req) }
  );
  return successResponse(res, result, 'Yetkili servis oturumu başlatıldı.');
}));

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
module.exports = router;
