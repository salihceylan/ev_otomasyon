const express = require('express');
const router = express.Router();
const authService = require('../services/auth_service');
const serviceTokenService = require('../services/service_token_service');
const { authenticateToken } = require('../middlewares/auth_middleware');
const { successResponse, errorResponse } = require('../utils/helpers');

// POST /api/auth/register (Yeni Kullanıcı Kaydı)
router.post('/register', async (req, res) => {
  try {
    const { full_name, email, password, phone } = req.body;
    if (!full_name || !email || !password) {
      return errorResponse(res, 'Ad Soyad, E-posta ve Şifre alanları zorunludur.', 400);
    }
    const result = await authService.register({ full_name, email, password, phone });
    return successResponse(res, result, 'Kayıt başarıyla tamamlandı', 201);
  } catch (err) {
    return errorResponse(res, err.message, 400);
  }
});

// POST /api/auth/login (E-posta / Telefon + Şifre ile Giriş)
router.post('/login', async (req, res) => {
  try {
    const identifier = req.body.email || req.body.phone || req.body.identifier;
    const { password } = req.body;
    if (!identifier || !password) {
      return errorResponse(res, 'E-posta/Telefon ve şifre alanları zorunludur.', 400);
    }
    const result = await authService.login(identifier, password);
    return successResponse(res, result, 'Giriş başarılı');
  } catch (err) {
    return errorResponse(res, err.message, 401);
  }
});

// POST /api/auth/refresh (JWT Refresh Token ile Sessiz Oturum Yenileme)
router.post('/refresh', async (req, res) => {
  try {
    const refreshToken = req.body.refresh_token || req.body.refreshToken;
    if (!refreshToken) {
      return errorResponse(res, 'Refresh token zorunludur.', 400);
    }
    const result = await authService.refreshToken(refreshToken);
    return successResponse(res, result, 'Oturum başarıyla yenilendi');
  } catch (err) {
    return errorResponse(res, err.message, 401);
  }
});

// POST /api/auth/logout (Oturumu Kapat / Refresh Token İptal)
router.post('/logout', async (req, res) => {
  try {
    const refreshToken = req.body.refresh_token || req.body.refreshToken;
    if (refreshToken) {
      await authService.revokeToken(refreshToken);
    }
    return successResponse(res, null, 'Oturum başarıyla sonlandırıldı');
  } catch (err) {
    return errorResponse(res, err.message, 500);
  }
});

// POST /api/auth/forgot-password veya /api/v1/auth/forgot-password (Şifre Sıfırlama OTP & Magic Token)
router.post('/forgot-password', async (req, res) => {
  try {
    const identifier = req.body.email || req.body.phone || req.body.identifier;
    if (!identifier) {
      return errorResponse(res, 'E-posta veya telefon adresi zorunludur.', 400);
    }
    const result = await authService.requestPasswordReset(identifier);
    return successResponse(res, result, result.message);
  } catch (err) {
    return errorResponse(res, err.message, 400);
  }
});

// POST /api/auth/reset-password veya /api/v1/auth/reset-password (OTP / Magic Token ile Yeni Şifre)
router.post('/reset-password', async (req, res) => {
  try {
    const identifier = req.body.email || req.body.phone || req.body.identifier;
    const code = req.body.code || req.body.otp_code || req.body.otp;
    const token = req.body.token || req.body.magic_token;
    const new_password = req.body.new_password || req.body.password;

    if ((!token && (!identifier || !code)) || !new_password) {
      return errorResponse(res, 'Kurtarma kodu (veya bağlantı) ve en az 6 haneli yeni şifre zorunludur.', 400);
    }

    const result = await authService.resetPassword({ identifier, code, token, new_password });
    return successResponse(res, result, 'Şifreniz başarıyla yenilendi, tüm eski oturumlar kapatıldı.');
  } catch (err) {
    return errorResponse(res, err.message, 400);
  }
});

// GET /api/auth/magic-login/:token veya /api/v1/auth/magic-login/:token (Sihirli Bağlantı ile Tek Tıkla Giriş)
router.get('/magic-login/:token', async (req, res) => {
  try {
    const { token } = req.params;
    const result = await authService.magicLogin(token);
    return successResponse(res, result, 'Sihirli bağlantı ile oturum açıldı');
  } catch (err) {
    return errorResponse(res, err.message, 400);
  }
});

// POST /api/auth/service-login (Kurulumcu / Teknisyen 2 Saatlik Geçici PIN ile Giriş)
router.post('/service-login', async (req, res) => {
  try {
    const { service_pin, technician_name, technician_email } = req.body;
    if (!service_pin) {
      return errorResponse(res, 'Servis PIN kodu zorunludur.', 400);
    }
    const result = await serviceTokenService.loginWithServicePin(service_pin, technician_email, technician_name);
    return successResponse(res, result, 'Teknisyen servis girişi başarılı');
  } catch (err) {
    return errorResponse(res, err.message, err.statusCode || 403);
  }
});

// GET /api/auth/me (Profil ve Ev Listesi)
router.get('/me', authenticateToken, async (req, res) => {
  try {
    const result = await authService.getProfile(req.user.id);
    return successResponse(res, result);
  } catch (err) {
    return errorResponse(res, err.message, 500);
  }
});

// GET /api/auth/homes veya GET /api/homes yönlendirmesi
router.get('/homes', authenticateToken, async (req, res) => {
  try {
    const result = await authService.getProfile(req.user.id);
    return successResponse(res, result.homes);
  } catch (err) {
    return errorResponse(res, err.message, 500);
  }
});

// ==========================================
// ADIM 18: Sosyal & Şifresiz Giriş Uç Noktaları
// ==========================================

// POST /api/auth/google veya /api/v1/auth/google
router.post('/google', async (req, res) => {
  try {
    const { id_token, email, name, full_name, google_id } = req.body;
    const result = await authService.loginWithGoogle({
      id_token,
      email,
      full_name: full_name || name,
      google_id,
    });
    return successResponse(res, result, 'Google ile giriş başarılı');
  } catch (err) {
    return errorResponse(res, err.message, 400);
  }
});

// POST /api/auth/apple veya /api/v1/auth/apple
router.post('/apple', async (req, res) => {
  try {
    const { identity_token, user_id, email, name, full_name } = req.body;
    const result = await authService.loginWithApple({
      identity_token,
      user_id,
      email,
      full_name: full_name || name,
    });
    return successResponse(res, result, 'Apple ile giriş başarılı');
  } catch (err) {
    return errorResponse(res, err.message, 400);
  }
});

// POST /api/auth/otp/send veya /api/v1/auth/otp/send
router.post('/otp/send', async (req, res) => {
  try {
    const { phone } = req.body;
    const result = await authService.sendPhoneOtp(phone);
    return successResponse(res, result, result.message);
  } catch (err) {
    return errorResponse(res, err.message, 400);
  }
});

// POST /api/auth/otp/verify veya /api/v1/auth/otp/verify
router.post('/otp/verify', async (req, res) => {
  try {
    const { phone, code, otp } = req.body;
    const result = await authService.verifyPhoneOtp(phone, code || otp);
    return successResponse(res, result, 'Telefon doğrulaması ve giriş başarılı');
  } catch (err) {
    return errorResponse(res, err.message, 401);
  }
});

module.exports = router;
