'use strict';

// ==============================================================================
// AHBU Akıllı Ev - Push jetonu uçları                                     [WP-H §3.2]
// ==============================================================================
// Mount: server.js bu router'ı `/api/v1` ve `/api` altına bağlar (router YOL ÖNEKİ EKLEMEZ).
//
//   PUT    /me/push-tokens   { token, platform:'android'|'ios', app_version? }  -> { registered:true }
//   DELETE /me/push-tokens   { token }                                           -> { registered:false }
//
// Kurallar:
//   - Kimlik doğrulama HER ROUTE'TA ayrı uygulanır (router.use YOK): router `/api` altına da bağlandığı
//     için router.use, kendisine ait olmayan isteklere de 401 döndürürdü (invitation_routes ile aynı gerekçe).
//   - Jeton bir KULLANICI cihazına aittir: servis oturumları (kullanıcı satırı yok, `req.user.id` null)
//     403 FORBIDDEN alır. authenticateToken zaten ev kapsamsız yolu servis oturumuna kapatır; burada
//     ikinci savunma hattı olarak yinelenir.
//   - Hız sınırı kullanıcı başına 20/dk (jeton yenileme uygulama açılışında olur; döngüye girerse
//     DB'yi yormasın). Sayaç kimlik doğrulamadan SONRA çalışır ki anahtar kullanıcı olsun.
//   - Hata biçimi CONTRACTS §1.1: { success:false, message, code }. Ham iç mesaj istemciye dönmez;
//     loga yalnızca hata adı/kodu yazılır (jeton ve gövde ASLA).

const express = require('express');
const { normalizeToken, normalizePlatform, normalizeAppVersion } = require('../services/push_service');

const MIN = 60 * 1000;
const RATE_WINDOW_MS = MIN;
const RATE_MAX = 20;
const BODY_LIMIT = '8kb';
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function sendError(res, status, message, code) {
  return res.status(status).json({ success: false, message, code });
}

function isServiceSession(user) {
  return Boolean(user) && (user.is_service_session === true || user.role === 'service_session');
}

/** İlk bulunan dolu alan (snake_case tercih; CONTRACTS §0: camelCase geçiş döneminde kabul). */
function pick(body, keys) {
  if (!body || typeof body !== 'object' || Array.isArray(body)) return undefined;
  for (const k of keys) {
    if (body[k] !== undefined && body[k] !== null && body[k] !== '') return body[k];
  }
  return undefined;
}

/**
 * `rateLimit` seçeneği üç biçimde gelebilir: hazır middleware (consume metodu olan veya 3 parametreli),
 * middleware_fabrikası (rate_limit.js'in `rateLimit(opts)`'ı) ya da hiç yok (modül tembel yüklenir).
 * Hiçbiri kullanılamazsa küçük bir bellek içi sınırlayıcıya düşülür.
 */
function resolveLimiter(rateLimit, keyGenerator) {
  const opts = { windowMs: RATE_WINDOW_MS, max: RATE_MAX, keyGenerator };
  try {
    if (typeof rateLimit === 'function' && (typeof rateLimit.consume === 'function' || rateLimit.length === 3)) {
      return rateLimit;
    }
    let factory = typeof rateLimit === 'function' ? rateLimit : null;
    if (!factory) {
      const mod = require('../middlewares/rate_limit');
      factory = typeof mod === 'function' ? mod : mod && mod.rateLimit;
    }
    if (typeof factory === 'function') {
      const mw = factory(opts);
      if (typeof mw === 'function') return mw;
    }
  } catch (_) {
    // modül yok / imza farklı: yerel sınırlayıcıya düş
  }
  return localLimiter(opts);
}

function localLimiter({ windowMs, max, keyGenerator }) {
  const hits = new Map();
  return function localRateLimit(req, res, next) {
    const t = Date.now();
    const key = String(keyGenerator(req));
    let entry = hits.get(key);
    if (!entry || entry.resetAt <= t) {
      if (hits.size > 10000) hits.clear(); // bellek koruması
      entry = { count: 0, resetAt: t + windowMs };
      hits.set(key, entry);
    }
    entry.count += 1;
    if (entry.count > max) {
      const retryAfter = Math.max(1, Math.ceil((entry.resetAt - t) / 1000));
      res.setHeader('Retry-After', String(retryAfter));
      return res.status(429).json({
        success: false,
        message: `Çok fazla istek gönderildi. Lütfen ${retryAfter} saniye sonra tekrar deneyin.`,
        code: 'RATE_LIMITED',
        retry_after: retryAfter,
      });
    }
    return next();
  };
}

/**
 * @param {object}   deps
 * @param {object}   deps.pushService          createPushService() örneği (upsertToken, disableToken)
 * @param {Function} deps.authenticateToken    auth_middleware.authenticateToken
 * @param {Function} [deps.rateLimit]          middleware veya rate_limit.js fabrikası
 * @param {object}   [deps.logger]
 * @returns {import('express').Router}
 */
function createPushRouter({ pushService, authenticateToken, rateLimit, logger } = {}) {
  if (!pushService || typeof pushService.upsertToken !== 'function' || typeof pushService.disableToken !== 'function') {
    throw new TypeError('createPushRouter: pushService (upsertToken, disableToken) zorunludur.');
  }
  if (typeof authenticateToken !== 'function') {
    // Kimlik doğrulamasız jeton ucu ASLA kurulmaz (fail-closed).
    throw new TypeError('createPushRouter: authenticateToken zorunludur.');
  }
  const log = logger || console;

  const router = express.Router();
  const jsonBody = express.json({ limit: BODY_LIMIT });

  const limiter = resolveLimiter(
    rateLimit,
    (req) => `push-token:${req.user && req.user.id ? req.user.id : (req.ip || 'unknown')}`
  );

  /** Kimlik doğrulama sonrası: yalnızca gerçek kullanıcı (servis oturumu / kimliksiz -> 403). */
  function requireUserIdentity(req, res, next) {
    if (!req.user) return sendError(res, 401, 'Kimlik doğrulaması gerekli.', 'INVALID_TOKEN');
    if (isServiceSession(req.user) || typeof req.user.id !== 'string' || !UUID_RE.test(req.user.id)) {
      return sendError(res, 403, 'Servis oturumları bildirim anahtarı kaydedemez.', 'FORBIDDEN');
    }
    return next();
  }

  /** Doğrulama (400 VALIDATION) dışındaki hatalar genel 500 olur; ayrıntı yalnızca loga (sır içermeden). */
  function fail(res, err, action) {
    if (err && err.code === 'VALIDATION') {
      return sendError(res, 400, err.message, 'VALIDATION');
    }
    const kind = err && typeof err.code === 'string' && /^[0-9A-Z]{5}$/.test(err.code) ? err.code : (err && err.name) || 'Error';
    if (log && typeof log.error === 'function') log.error(`[PUSH] ${action} hatasi: ${kind}`);
    return sendError(res, 500, 'Sunucu hatası oluştu. Lütfen daha sonra tekrar deneyin.', 'INTERNAL');
  }

  router.put(
    '/me/push-tokens',
    authenticateToken,
    requireUserIdentity,
    limiter,
    jsonBody,
    async (req, res) => {
      try {
        const body = req.body;
        if (!body || typeof body !== 'object' || Array.isArray(body)) {
          return sendError(res, 400, 'İstek gövdesi geçerli bir JSON nesnesi olmalıdır.', 'VALIDATION');
        }
        const token = normalizeToken(pick(body, ['token']));
        const platform = normalizePlatform(pick(body, ['platform']));
        const appVersion = normalizeAppVersion(pick(body, ['app_version', 'appVersion']));
        await pushService.upsertToken({ userId: req.user.id, token, platform, appVersion });
        res.setHeader('Cache-Control', 'no-store');
        return res.status(200).json({
          success: true,
          message: 'Bildirim anahtarı kaydedildi.',
          data: { registered: true },
        });
      } catch (err) {
        return fail(res, err, 'jeton kaydi');
      }
    }
  );

  router.delete(
    '/me/push-tokens',
    authenticateToken,
    requireUserIdentity,
    limiter,
    jsonBody,
    async (req, res) => {
      try {
        const body = req.body;
        if (!body || typeof body !== 'object' || Array.isArray(body)) {
          return sendError(res, 400, 'İstek gövdesi geçerli bir JSON nesnesi olmalıdır.', 'VALIDATION');
        }
        const token = normalizeToken(pick(body, ['token']));
        // Yalnızca çağıranın kendi jetonu: başkasının jetonunu iptal etmek mümkün değil.
        // Jeton yoksa da başarı döner (idempotent çıkış; jetonun var olup olmadığı sızmaz).
        await pushService.disableToken({ token, userId: req.user.id });
        res.setHeader('Cache-Control', 'no-store');
        return res.status(200).json({
          success: true,
          message: 'Bildirim anahtarı kaldırıldı.',
          data: { registered: false },
        });
      } catch (err) {
        return fail(res, err, 'jeton silme');
      }
    }
  );

  // Gövde ayrıştırma hataları (bozuk JSON, büyük gövde) yalnızca bu router'ın route'larından gelir.
  // eslint-disable-next-line no-unused-vars
  router.use((err, req, res, next) => {
    if (err && err.type === 'entity.too.large') {
      return sendError(res, 413, 'İstek gövdesi çok büyük.', 'PAYLOAD_TOO_LARGE');
    }
    if (err && (err.type === 'entity.parse.failed' || (err instanceof SyntaxError && 'body' in err))) {
      return sendError(res, 400, 'Geçersiz JSON gövdesi.', 'VALIDATION');
    }
    if (log && typeof log.error === 'function') {
      log.error(`[PUSH] beklenmeyen route hatasi: ${(err && err.name) || 'Error'}`);
    }
    return sendError(res, 500, 'Sunucu hatası oluştu. Lütfen daha sonra tekrar deneyin.', 'INTERNAL');
  });

  return router;
}

module.exports = { createPushRouter, RATE_MAX, RATE_WINDOW_MS };
