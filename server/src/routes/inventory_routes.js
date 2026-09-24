// ==============================================================================
// AHBU Akıllı Ev & Bina Otomasyonu - Envanter API Rotaları (Faz 6.2)
// ==============================================================================

const express = require('express');
const router = express.Router();
const inventoryService = require('../services/inventory_service');
const requireAdminApiKey = require('../middlewares/admin_api_key_middleware');

// Tüm envanter uç noktaları Admin API Key ile korunur
router.use(requireAdminApiKey);

/**
 * @route   POST /api/v1/admin/inventory/register
 * @desc    Yeni üretilen ESP32-S3 panosunu envantere kaydeder (IN_STOCK) ve QR claim linki üretir
 */
router.post('/register', async (req, res, next) => {
  try {
    const { device_uuid, mac_address, pin, model, batch_no } = req.body;
    const result = await inventoryService.registerDevice({
      device_uuid,
      mac_address,
      pin,
      model,
      batch_no,
    });

    res.status(201).json({
      success: true,
      message: 'Cihaz başarıyla envantere kaydedildi.',
      data: result,
    });
  } catch (err) {
    next(err);
  }
});

/**
 * @route   GET /api/v1/admin/inventory
 * @desc    Envanterdeki cihazları listeler
 */
router.get('/', async (req, res, next) => {
  try {
    const { status, batch_no, search, limit, offset } = req.query;
    const result = await inventoryService.listInventory({
      status,
      batch_no,
      search,
      limit: limit ? parseInt(limit, 10) : undefined,
      offset: offset ? parseInt(offset, 10) : undefined,
    });

    res.json({
      success: true,
      data: result,
    });
  } catch (err) {
    next(err);
  }
});

/**
 * @route   GET /api/v1/admin/inventory/:uuid
 * @desc    Belirli bir cihazın envanter durumunu sorgular
 */
router.get('/:uuid', async (req, res, next) => {
  try {
    const { uuid } = req.params;
    const result = await inventoryService.getByUuid(uuid);

    res.json({
      success: true,
      data: result,
    });
  } catch (err) {
    next(err);
  }
});

/**
 * @route   PATCH /api/v1/admin/inventory/:uuid/status
 * @desc    Cihaz durumunu günceller (SUSPENDED / IN_STOCK / REVOKED)
 */
router.patch('/:uuid/status', async (req, res, next) => {
  try {
    const { uuid } = req.params;
    const { status } = req.body;
    const result = await inventoryService.updateStatus(uuid, status);

    res.json({
      success: true,
      message: `Cihaz durumu '${status}' olarak güncellendi.`,
      data: result,
    });
  } catch (err) {
    next(err);
  }
});

/**
 * @route   DELETE /api/v1/admin/inventory/:uuid
 * @desc    Cihazı envanterden siler (Süper Yönetici)
 */
router.delete('/:uuid', async (req, res, next) => {
  try {
    const { uuid } = req.params;
    const result = await inventoryService.deleteDevice(uuid);

    res.json({
      success: true,
      message: result.message,
    });
  } catch (err) {
    next(err);
  }
});

module.exports = router;

