'use strict';

// ==============================================================================
// AHBU Akilli Ev - Envanter / fabrika erisim kapisi (WP-A: A8)
// ==============================================================================
//
//  - Birincil yol: JWT (authenticateToken) + global rol. Envanter islemleri super_user'dir;
//    listeleme/tekil sorgu icin istenirse servis personeli (allowStaff) - kapsami servis katmani daraltir.
//  - Ikincil yol (makine entegrasyonu): `X-Admin-Api-Key` basligi, yalnizca ADMIN_API_KEY ortam
//    degiskeni TANIMLI ve >= 32 karakter ise; sabit zamanli karsilastirma. Tanimli degilse yol
//    KAPALIDIR (fail-closed). Kod icinde VARSAYILAN ANAHTAR YOKTUR; kullanici parolalari asla
//    API anahtari olarak kabul edilmez.
//  - Gecersiz anahtar denemeleri IP basina sinirlanir.

const crypto = require('crypto');
const { authenticateToken } = require('./auth_middleware');
const { rateLimit, clientIp } = require('./rate_limit');
const { errorResponse } = require('../utils/helpers');

const MIN_API_KEY_LENGTH = 32;

const badKeyLimiter = rateLimit({
  windowMs: 15 * 60 * 1000,
  max: 10,
  keyGenerator: (req) => `admin-api-key:${clientIp(req)}`,
});

function digest(value) {
  return crypto.createHash('sha256').update(String(value), 'utf8').digest();
}

/** ADMIN_API_KEY yapilandirilmis mi (>= 32 karakter)? */
function isApiKeyConfigured() {
  const k = process.env.ADMIN_API_KEY;
  return typeof k === 'string' && k.length >= MIN_API_KEY_LENGTH;
}

/** Sabit zamanli dogrulama (ozetler esit uzunlukta oldugundan uzunluk bilgisi sizmaz). */
function isValidApiKey(provided) {
  if (!isApiKeyConfigured()) return false;
  if (typeof provided !== 'string' || provided.length === 0 || provided.length > 512) return false;
  return crypto.timingSafeEqual(digest(provided), digest(process.env.ADMIN_API_KEY));
}

function providedApiKey(req) {
  const h = req.headers || {};
  const v = h['x-admin-api-key'] || h['x-api-key'];
  return typeof v === 'string' ? v : null;
}

/**
 * @param {{allowApiKey?:boolean, allowStaff?:boolean}} [opts]
 *   allowApiKey: gecerli ADMIN_API_KEY ile erisime izin (varsayilan false)
 *   allowStaff : JWT ile service_user erisimi (varsayilan false; yalnizca super_user)
 * Basarida req.inventoryActor = { type: 'api_key'|'super_user'|'service_user', userId }
 */
function requireInventoryAccess({ allowApiKey = false, allowStaff = false } = {}) {
  return function inventoryGate(req, res, next) {
    const key = providedApiKey(req);
    if (key !== null) {
      if (allowApiKey && isValidApiKey(key)) {
        req.inventoryActor = { type: 'api_key', userId: null };
        return next();
      }
      // Gecersiz/kapali anahtar: JWT'ye DUSULMEZ, deneme sayilir.
      const s = badKeyLimiter.consume(`admin-api-key:${clientIp(req)}`);
      if (!s.allowed) {
        res.setHeader('Retry-After', String(s.retryAfter));
        return errorResponse(res, 'Çok fazla geçersiz deneme.', 429, null, 'RATE_LIMITED');
      }
      return errorResponse(res, 'Geçersiz veya izin verilmeyen API anahtarı.', 401, null, 'INVALID_TOKEN');
    }

    return authenticateToken(req, res, () => {
      const user = req.user;
      if (!user || user.is_service_session) {
        return errorResponse(res, 'Bu işlem için yetkiniz bulunmamaktadır.', 403, null, 'FORBIDDEN');
      }
      if (user.role === 'super_user') {
        req.inventoryActor = { type: 'super_user', userId: user.id };
        return next();
      }
      if (allowStaff && user.role === 'service_user') {
        req.inventoryActor = { type: 'service_user', userId: user.id };
        return next();
      }
      return errorResponse(res, 'Bu işlem için Süper Yönetici yetkisi gereklidir.', 403, null, 'FORBIDDEN');
    });
  };
}

// Geriye donuk: eski varsayilan disa aktarim = yalnizca super_user (JWT) veya gecerli API anahtari.
const requireAdminApiKey = requireInventoryAccess({ allowApiKey: true, allowStaff: false });

module.exports = requireAdminApiKey;
module.exports.requireInventoryAccess = requireInventoryAccess;
module.exports.isApiKeyConfigured = isApiKeyConfigured;
module.exports.isValidApiKey = isValidApiKey;
module.exports.badKeyLimiter = badKeyLimiter;
module.exports.MIN_API_KEY_LENGTH = MIN_API_KEY_LENGTH;
