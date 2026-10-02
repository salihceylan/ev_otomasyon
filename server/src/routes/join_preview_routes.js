'use strict';

// ==============================================================================
// AHBU Akilli Ev - Davet / devir kodu onizleme ucu (WP-B2). Mount: /api/v1 ve /api
// ==============================================================================
// Kimlik dogrulama ROUTE bazlidir (router.use YOK): router /api altina da baglandigi icin router.use,
// kendisine ait olmayan isteklere de 401 donerdi (invitation_routes ile ayni gerekce).
//
//   POST /homes/join-preview   { code }   giris yapmis kullanici (servis PIN oturumu HARIC)
//        -> { kind, is_transfer, home_name, resident_count, role, expires_at, already_member?, guest_valid_* }
//        Kodu TUKETMEZ. Gecersiz / kullanilmis / suresi dolmus kod: 410 GONE. Baska hesaba ait devir kodu: 403.
//
// Hiz siniri `/homes/join` ile ayni sertlikte ama AYRI sayaclarla (onizleme katilimi tuketmez; yine de kod
// numaralandirmasi yapilamaz): IP basina 30 / 15 dk, kullanici basina 10 / 15 dk.

const express = require('express');
const { asyncHandler } = require('../middlewares/error_handler');
const { successResponse, HttpError } = require('../utils/helpers');
const { clientIp, noStore } = require('./route_helpers');

const MIN = 60 * 1000;

function pick(body, ...names) {
  const b = body && typeof body === 'object' ? body : {};
  for (const n of names) {
    if (b[n] !== undefined && b[n] !== null && b[n] !== '') return b[n];
  }
  return undefined;
}

function createRouter(deps = {}) {
  const auth = deps.auth || require('../middlewares/auth_middleware');
  const rateLimitFactory = deps.rateLimit || require('../middlewares/rate_limit');
  const preview = deps.joinPreviewService || require('../services/join_preview_service');
  const { authenticateToken, rejectServiceSession } = auth;

  const router = express.Router();
  const ipLimiter = rateLimitFactory({ windowMs: 15 * MIN, max: 30, keyGenerator: (req) => `join-preview-ip:${clientIp(req)}` });
  const userLimiter = rateLimitFactory({
    windowMs: 15 * MIN,
    max: 10,
    keyGenerator: (req) => `join-preview:${req.user && req.user.id ? req.user.id : 'anon'}:${clientIp(req)}`,
  });

  router.post(
    '/homes/join-preview',
    ipLimiter,
    authenticateToken,
    rejectServiceSession,
    userLimiter,
    asyncHandler(async (req, res) => {
      const code = pick(req.body, 'code', 'invite_code', 'inviteCode', 'transfer_code', 'transferCode');
      if (!code) throw new HttpError(400, 'Davet veya devir kodu zorunludur.', 'VALIDATION');
      const result = await preview.previewCode({ userId: req.user.id, code });
      noStore(res);
      return successResponse(res, result);
    })
  );

  router.limiters = { ipLimiter, userLimiter };
  return router;
}

module.exports = createRouter();
module.exports.createRouter = createRouter;
