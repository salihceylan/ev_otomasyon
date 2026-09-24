// ==============================================================================
// AHBU Akıllı Ev & Bina Otomasyonu - Daire Devir API Rotaları (ADIM 13)
// ==============================================================================

const express = require('express');
const router = express.Router();
const TransferService = require('../services/transfer_service');
const { authenticateToken } = require('../middlewares/auth_middleware');
const { successResponse, errorResponse } = require('../utils/helpers');

// Tüm devir rotaları kimlik doğrulaması gerektirir
router.use(authenticateToken);

/**
 * @route   POST /api/v1/homes/:homeId/transfer-initiate
 * @desc    Ev sahibi daire devir sürecini başlatır (48 saat geçerli AHBU-TR-XXXXXX kodu üretir)
 */
router.post('/homes/:homeId/transfer-initiate', async (req, res) => {
  try {
    const { homeId } = req.params;
    const userId = req.user.id;
    const targetIdentifier = req.body.target_identifier || req.body.targetIdentifier;

    const result = await TransferService.initiateTransfer({
      homeId,
      fromUserId: userId,
      targetIdentifier,
    });

    return successResponse(res, result.transfer, 'Daire devir kodu başarıyla üretildi.', 201);
  } catch (err) {
    return errorResponse(res, err.message, err.status || err.statusCode || 500);
  }
});

/**
 * @route   POST /api/v1/homes/transfer-accept
 * @desc    Yeni kullanıcı devir kodunu onaylayarak daireyi devralır (Eski aile azledilir)
 */
router.post('/homes/transfer-accept', async (req, res) => {
  try {
    const transferCode = req.body.transfer_code || req.body.transferCode || req.body.code;
    const userId = req.user.id;

    if (!transferCode) {
      return errorResponse(res, 'Devir kodu (transfer_code) zorunludur.', 400);
    }

    const result = await TransferService.acceptTransfer({
      transferCode,
      newUserId: userId,
    });

    return successResponse(res, result, result.message, 200);
  } catch (err) {
    return errorResponse(res, err.message, err.status || err.statusCode || 500);
  }
});

/**
 * @route   GET /api/v1/homes/:homeId/transfer-status
 * @desc    Dairenin bekleyen devir durumunu sorgular
 */
router.get('/homes/:homeId/transfer-status', async (req, res) => {
  try {
    const { homeId } = req.params;
    const userId = req.user.id;

    const result = await TransferService.getTransferStatus(homeId, userId);
    return successResponse(res, result);
  } catch (err) {
    return errorResponse(res, err.message, err.status || err.statusCode || 500);
  }
});

/**
 * @route   POST /api/v1/homes/:homeId/transfer-cancel
 * @desc    Ev sahibi bekleyen devir işlemini iptal eder
 */
router.post('/homes/:homeId/transfer-cancel', async (req, res) => {
  try {
    const { homeId } = req.params;
    const userId = req.user.id;

    const result = await TransferService.cancelTransfer(homeId, userId);
    return successResponse(res, result, result.message);
  } catch (err) {
    return errorResponse(res, err.message, err.status || err.statusCode || 500);
  }
});

module.exports = router;

