'use strict';

// ==============================================================================
// AHBU Akilli Ev - Daire devri uclari (WP-A: A10). Mount: /api/v1 ve /api
// ==============================================================================
// Kimlik dogrulama HER ROUTE'TA ayri (router.use YOK).
// CONTRACTS §1.4: "Daire devri" yalnizca owner (super_user dahil degil).
//
//   POST /homes/:homeId/transfer-initiate   owner   { target_identifier } (ZORUNLU)
//   POST /homes/transfer-accept             giris yapmis kullanici (hedef kimlikle eslesmeli)
//   GET  /homes/:homeId/transfer-status     owner
//   POST /homes/:homeId/transfer-cancel     owner

const express = require('express');
const TransferService = require('../services/transfer_service');
const {
  authenticateToken,
  requireHomeAccess,
  rejectServiceSession,
  HOME_ROLE_SETS,
} = require('../middlewares/auth_middleware');
const { rateLimit, clientIp } = require('../middlewares/rate_limit');
const { asyncHandler } = require('../middlewares/error_handler');
const { successResponse, HttpError } = require('../utils/helpers');

const router = express.Router();
const MIN = 60 * 1000;

const initiateLimiter = rateLimit({
  windowMs: 60 * MIN,
  max: 10,
  keyGenerator: (req) => `transfer-init:${req.user && req.user.id ? req.user.id : clientIp(req)}`,
});
const acceptLimiter = rateLimit({
  windowMs: 15 * MIN,
  max: 10,
  keyGenerator: (req) => `transfer-accept:${req.user && req.user.id ? req.user.id : 'anon'}:${clientIp(req)}`,
});
const acceptIpLimiter = rateLimit({ windowMs: 15 * MIN, max: 30, keyGenerator: (req) => `transfer-accept-ip:${clientIp(req)}` });

function pick(body, keys) {
  if (!body || typeof body !== 'object') return undefined;
  for (const k of keys) {
    if (body[k] !== undefined && body[k] !== null && body[k] !== '') return body[k];
  }
  return undefined;
}

function noStore(res) {
  res.setHeader('Cache-Control', 'no-store');
  res.setHeader('Pragma', 'no-cache');
}

router.post(
  '/homes/:homeId/transfer-initiate',
  authenticateToken,
  requireHomeAccess(HOME_ROLE_SETS.TRANSFER),
  initiateLimiter,
  asyncHandler(async (req, res) => {
    const result = await TransferService.initiateTransfer({
      homeId: req.homeAccess.home_id,
      fromUserId: req.user.id,
      targetIdentifier: pick(req.body, ['target_identifier', 'targetIdentifier']),
    });
    noStore(res);
    return successResponse(res, result, 'Daire devir kodu üretildi.', 201);
  })
);

router.post(
  '/homes/transfer-accept',
  acceptIpLimiter,
  authenticateToken,
  rejectServiceSession,
  acceptLimiter,
  asyncHandler(async (req, res) => {
    const code = pick(req.body, ['transfer_code', 'transferCode', 'code']);
    if (!code) throw new HttpError(400, 'Devir kodu (transfer_code) zorunludur.', 'VALIDATION');
    const result = await TransferService.acceptTransfer({ transferCode: code, newUserId: req.user.id });
    return successResponse(res, result, result.message);
  })
);

router.get(
  '/homes/:homeId/transfer-status',
  authenticateToken,
  requireHomeAccess(HOME_ROLE_SETS.TRANSFER),
  asyncHandler(async (req, res) => {
    const result = await TransferService.getTransferStatus(req.homeAccess.home_id);
    return successResponse(res, result);
  })
);

router.post(
  '/homes/:homeId/transfer-cancel',
  authenticateToken,
  requireHomeAccess(HOME_ROLE_SETS.TRANSFER),
  asyncHandler(async (req, res) => {
    const result = await TransferService.cancelTransfer(req.homeAccess.home_id);
    return successResponse(res, result, result.message);
  })
);

module.exports = router;
