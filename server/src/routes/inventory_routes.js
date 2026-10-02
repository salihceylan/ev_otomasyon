'use strict';

// ==============================================================================
// AHBU Akilli Ev - Envanter uclari (WP-A: A8/A11). Mount: /api/v1/admin/inventory (+ eski /api/admin/inventory)
// ==============================================================================
//   POST   /register      super_user (JWT) veya gecerli ADMIN_API_KEY  -> local_key + PIN'li QR BIR KEZ
//   GET    /              super_user / API anahtari (tumu), service_user (yalnizca kendi stogu)
//   GET    /:uuid         ayni kapsam
//   PATCH  /:uuid/status  YALNIZCA super_user (JWT)
//   DELETE /:uuid         YALNIZCA super_user (JWT)
//   POST   /:uuid/reissue-label  YALNIZCA super_user (JWT; API anahtari KABUL EDILMEZ). Yalniz IN_STOCK ve
//                                hicbir daireye baglanmamis cihaz: yeni PIN + yeni yerel anahtar (BIR KEZ), eski PIN gecersiz.

const express = require('express');
const inventoryService = require('../services/inventory_service');
const { requireInventoryAccess } = require('../middlewares/admin_api_key_middleware');
const { rateLimit, clientIp } = require('../middlewares/rate_limit');
const { asyncHandler } = require('../middlewares/error_handler');
const { successResponse } = require('../utils/helpers');

const router = express.Router();

// Etiket yeniden uretimi her seferinde yeni gizli deger uretir: kullanici basina saatte 20
const reissueLimiter = rateLimit({
  windowMs: 60 * 60 * 1000,
  max: 20,
  keyGenerator: (req) => `inventory-reissue:${req.inventoryActor && req.inventoryActor.userId ? req.inventoryActor.userId : clientIp(req)}`,
});

function noStore(res) {
  res.setHeader('Cache-Control', 'no-store');
  res.setHeader('Pragma', 'no-cache');
}

router.post(
  '/register',
  requireInventoryAccess({ allowApiKey: true, allowStaff: false }),
  asyncHandler(async (req, res) => {
    const b = req.body || {};
    const result = await inventoryService.registerDevice({
      device_uuid: b.device_uuid || b.deviceUuid,
      mac_address: b.mac_address || b.macAddress,
      pin: b.pin || b.setup_pin,
      model: b.model,
      batch_no: b.batch_no || b.batchNo,
    });
    noStore(res);
    return successResponse(res, result, 'Cihaz envantere kaydedildi.', 201);
  })
);

router.get(
  '/',
  requireInventoryAccess({ allowApiKey: true, allowStaff: true }),
  asyncHandler(async (req, res) => {
    const { status, batch_no, search, limit, offset } = req.query || {};
    const result = await inventoryService.listInventory({ status, batch_no, search, limit, offset }, req.inventoryActor);
    return successResponse(res, result);
  })
);

router.get(
  '/:uuid',
  requireInventoryAccess({ allowApiKey: true, allowStaff: true }),
  asyncHandler(async (req, res) => {
    const result = await inventoryService.getByUuid(req.params.uuid, req.inventoryActor);
    return successResponse(res, result);
  })
);

router.patch(
  '/:uuid/status',
  requireInventoryAccess({ allowApiKey: false, allowStaff: false }),
  asyncHandler(async (req, res) => {
    const result = await inventoryService.updateStatus(req.params.uuid, req.body ? req.body.status : undefined);
    return successResponse(res, result, `Cihaz durumu '${result.status}' olarak güncellendi.`);
  })
);

router.post(
  '/:uuid/reissue-label',
  requireInventoryAccess({ allowApiKey: false, allowStaff: false }),
  reissueLimiter,
  asyncHandler(async (req, res) => {
    const actor = req.inventoryActor || {};
    const result = await inventoryService.reissueLabel(req.params.uuid, {
      userId: actor.userId || null,
      role: actor.type === 'super_user' ? 'super_user' : null,
      ip: clientIp(req),
    });
    noStore(res); // tek seferlik PIN + yerel anahtar
    return successResponse(res, result, result.message, 200);
  })
);

router.delete(
  '/:uuid',
  requireInventoryAccess({ allowApiKey: false, allowStaff: false }),
  asyncHandler(async (req, res) => {
    const result = await inventoryService.deleteDevice(req.params.uuid);
    return successResponse(res, null, result.message);
  })
);

router.reissueLimiter = reissueLimiter;
module.exports = router;
