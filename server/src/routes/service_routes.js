'use strict';

// ==============================================================================
// AHBU Akilli Ev - Ev bazli servis erisimi uclari (WP-A: A6)
// Mount: /api/v1/homes/:home_id  (eski /api/homes/:home_id)
// ==============================================================================
//
//   POST /service-token          ev sahibi 2 saatlik, tek kullanimlik servis PIN'i uretir (PIN bir kez doner)
//   GET  /service-tokens         PIN gecmisi (PIN degeri DONMEZ)
//   GET  /service-sessions       acik servis oturumlari
//   POST /service-access/revoke  tum PIN'leri ve acik servis oturumlarini iptal eder
//
// NOT: POST /commissioning ve GET /commissioning-status WP-B (B9) kapsamindadir
// (routes/home_device_routes.js; server.js bu router'dan ONCE baglar). Eski surum
// ("varsayilan tumu test edildi") buradan KALDIRILDI.

const express = require('express');
const serviceTokenService = require('../services/service_token_service');
const { authenticateToken, requireHomeAccess, HOME_ROLE_SETS } = require('../middlewares/auth_middleware');
const { rateLimit, clientIp } = require('../middlewares/rate_limit');
const { asyncHandler } = require('../middlewares/error_handler');
const { successResponse } = require('../utils/helpers');

const router = express.Router({ mergeParams: true });

const pinLimiter = rateLimit({
  windowMs: 60 * 60 * 1000,
  max: 10,
  keyGenerator: (req) => `service-pin:${req.user && req.user.id ? req.user.id : clientIp(req)}`,
});

function noStore(res) {
  res.setHeader('Cache-Control', 'no-store');
  res.setHeader('Pragma', 'no-cache');
}

// POST /homes/:home_id/service-token (yalnizca owner - CONTRACTS §1.4 "Servis PIN uret")
router.post(
  '/service-token',
  authenticateToken,
  requireHomeAccess(HOME_ROLE_SETS.SERVICE_PIN),
  pinLimiter,
  asyncHandler(async (req, res) => {
    const result = await serviceTokenService.createServiceToken(req.user.id, req.homeAccess.home_id);
    noStore(res);
    return successResponse(res, result, 'Geçici servis PIN kodu oluşturuldu.', 201);
  })
);

// GET /homes/:home_id/service-tokens
router.get(
  '/service-tokens',
  authenticateToken,
  requireHomeAccess(HOME_ROLE_SETS.SERVICE_PIN),
  asyncHandler(async (req, res) => {
    const list = await serviceTokenService.listServiceTokens(req.homeAccess.home_id);
    return successResponse(res, list);
  })
);

// GET /homes/:home_id/service-sessions
router.get(
  '/service-sessions',
  authenticateToken,
  requireHomeAccess(HOME_ROLE_SETS.SERVICE_PIN),
  asyncHandler(async (req, res) => {
    const list = await serviceTokenService.listActiveSessions(req.homeAccess.home_id);
    return successResponse(res, list);
  })
);

// POST /homes/:home_id/service-access/revoke
router.post(
  '/service-access/revoke',
  authenticateToken,
  requireHomeAccess(HOME_ROLE_SETS.SERVICE_PIN),
  asyncHandler(async (req, res) => {
    const result = await serviceTokenService.revokeHomeServiceAccess(req.homeAccess.home_id, null, 'owner_revoked');
    return successResponse(res, result, 'Servis erişimi kapatıldı.');
  })
);

router.pinLimiter = pinLimiter;
module.exports = router;
