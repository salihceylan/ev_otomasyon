'use strict';

// ==============================================================================
// AHBU Akilli Ev - Davet / uye uclari (WP-A: A9). Mount: /api/v1 ve /api
// ==============================================================================
// Kimlik dogrulama HER ROUTE'TA ayri uygulanir (router.use YOK): bu router /api altina
// baglandigi icin router.use, kendisine ait olmayan isteklere de 401 donerdi.
//
//   POST   /homes/:homeId/invitations           owner | super_user   (CONTRACTS §1.4 "Uye davet")
//   POST   /homes/join                          giris yapmis kullanici (servis oturumu HARIC)
//   GET    /homes/:homeId/members               super | staff | owner | resident | gecerli misafir
//   DELETE /homes/:homeId/members/:targetUserId owner | super_user   (CONTRACTS §1.4 "Uye cikar")

const express = require('express');
const InvitationService = require('../services/invitation_service');
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

const joinLimiter = rateLimit({
  windowMs: 15 * MIN,
  max: 10,
  keyGenerator: (req) => `join:${req.user && req.user.id ? req.user.id : 'anon'}:${clientIp(req)}`,
});
const joinIpLimiter = rateLimit({ windowMs: 15 * MIN, max: 30, keyGenerator: (req) => `join-ip:${clientIp(req)}` });
const inviteLimiter = rateLimit({
  windowMs: 60 * MIN,
  max: 30,
  keyGenerator: (req) => `invite:${req.user && req.user.id ? req.user.id : clientIp(req)}`,
});

function pick(body, keys) {
  if (!body || typeof body !== 'object') return undefined;
  for (const k of keys) {
    if (body[k] !== undefined && body[k] !== null && body[k] !== '') return body[k];
  }
  return undefined;
}

router.post(
  '/homes/:homeId/invitations',
  authenticateToken,
  requireHomeAccess(HOME_ROLE_SETS.MEMBERS),
  inviteLimiter,
  asyncHandler(async (req, res) => {
    const body = req.body || {};
    const invitation = await InvitationService.createInvitation(
      req.homeAccess.home_id,
      { userId: req.user.id },
      pick(body, ['role']) || 'resident',
      {
        durationHours: pick(body, ['duration_hours', 'durationHours']),
        validFrom: pick(body, ['valid_from', 'validFrom']),
        validUntil: pick(body, ['valid_until', 'validUntil']),
        guestName: pick(body, ['guest_name', 'guestName']),
      }
    );
    res.setHeader('Cache-Control', 'no-store');
    return successResponse(res, invitation, 'Davet kodu oluşturuldu.', 201);
  })
);

router.post(
  '/homes/join',
  joinIpLimiter,
  authenticateToken,
  rejectServiceSession,
  joinLimiter,
  asyncHandler(async (req, res) => {
    const code = pick(req.body, ['code', 'invite_code', 'inviteCode']);
    if (!code) throw new HttpError(400, 'Davet kodu zorunludur.', 'VALIDATION');
    const result = await InvitationService.joinHomeWithCode(code, req.user.id);
    return successResponse(res, result, result.message);
  })
);

router.get(
  '/homes/:homeId/members',
  authenticateToken,
  requireHomeAccess(['super_user', 'service_user', 'owner', 'resident', 'guest']),
  asyncHandler(async (req, res) => {
    const result = await InvitationService.getHomeMembers(req.homeAccess.home_id, req.homeAccess);
    return successResponse(res, result);
  })
);

router.delete(
  '/homes/:homeId/members/:targetUserId',
  authenticateToken,
  requireHomeAccess(HOME_ROLE_SETS.MEMBERS),
  asyncHandler(async (req, res) => {
    const result = await InvitationService.removeHomeMember(
      req.homeAccess.home_id,
      { userId: req.user.id, role: req.homeAccess.role, isSuper: req.homeAccess.is_super === true },
      req.params.targetUserId
    );
    return successResponse(res, result, result.message);
  })
);

module.exports = router;
