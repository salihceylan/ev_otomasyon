const express = require('express');
const router = express.Router();
const InvitationService = require('../services/invitation_service');
const { authenticateToken } = require('../middlewares/auth_middleware');

// Tüm rotalar oturum açmış kullanıcı gerektirir
router.use(authenticateToken);

/**
 * POST /api/v1/homes/:homeId/invitations
 * Ev sahibi için aile davet kodu veya süreli misafir QR'ı üretir.
 * Body: { role: 'member'|'guest', durationHours: 8, validFrom, validUntil, guestName }
 */
router.post('/homes/:homeId/invitations', async (req, res, next) => {
  try {
    const { homeId } = req.params;
    const userId = req.user.id;
    const { role = 'member', durationHours, validFrom, validUntil, guestName } = req.body;

    const result = await InvitationService.createInvitation(homeId, userId, role, {
      durationHours,
      validFrom,
      validUntil,
      guestName,
    });
    return res.status(201).json(result);
  } catch (error) {
    return next(error);
  }
});

/**
 * POST /api/v1/homes/join
 * Aile bireyi veya misafir davet kodunu girerek (veya QR okutarak) eve katılır.
 * Body: { code: 'AHBU-XXXXXX' veya 'AHBU-INVITE:AHBU-XXXXXX' }
 */
router.post('/homes/join', async (req, res, next) => {
  try {
    const { code } = req.body;
    const userId = req.user.id;

    if (!code) {
      return res.status(400).json({ error: 'Davet kodu zorunludur' });
    }

    const result = await InvitationService.joinHomeWithCode(code, userId);
    return res.status(200).json(result);
  } catch (error) {
    return next(error);
  }
});

/**
 * GET /api/v1/homes/:homeId/members
 * Evdeki aile bireylerini ve süreli misafirleri listeler.
 */
router.get('/homes/:homeId/members', async (req, res, next) => {
  try {
    const { homeId } = req.params;
    const userId = req.user.id;

    const result = await InvitationService.getHomeMembers(homeId, userId);
    return res.status(200).json(result);
  } catch (error) {
    return next(error);
  }
});

/**
 * DELETE /api/v1/homes/:homeId/members/:targetUserId
 * Ev sahibi bir üyeyi veya misafiri evden çıkarır ve erişimini iptal eder.
 */
router.delete('/homes/:homeId/members/:targetUserId', async (req, res, next) => {
  try {
    const { homeId, targetUserId } = req.params;
    const requesterId = req.user.id;

    const result = await InvitationService.removeHomeMember(homeId, requesterId, targetUserId);
    return res.status(200).json(result);
  } catch (error) {
    return next(error);
  }
});

module.exports = router;
