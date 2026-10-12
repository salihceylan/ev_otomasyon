'use strict';

// ==============================================================================
// AHBU Akilli Ev - Envanter uclari (WP-A: A8/A11). Mount: /api/v1/admin/inventory (+ eski /api/admin/inventory)
// ==============================================================================
// Servis sorumlusu kapsami (045, tasarim 2026-10-12): service_user fabrika aracindan KENDI stoguna kart kaydeder ve YALNIZ
// kendi kartlarini yonetir; kok stogu (service_owner_id NULL) ve baska servisin karti 404. Kok (super_user) her seyi.
//   POST   /register      super_user (JWT) | service_user (kendi stoguna) | gecerli ADMIN_API_KEY (kok stogu)
//                         -> local_key + PIN'li QR BIR KEZ
//   GET    /              super_user / API anahtari (tumu), service_user (YALNIZCA kendi stogu)
//   GET    /:uuid         ayni kapsam
//   PATCH  /:uuid/status  super_user | service_user (kendi karti; REVOKED haric: askiya alma / aktif etme) (JWT)
//   DELETE /:uuid         super_user | service_user (kendi karti) (JWT)
//   POST   /:uuid/reissue-label  super_user | service_user (kendi karti) (JWT; API anahtari KABUL EDILMEZ). Yalniz
//                                IN_STOCK ve hicbir daireye baglanmamis cihaz: yeni PIN (BIR KEZ), eski PIN gecersiz.
//                                Yerel anahtar DEGISMEZ ve yanitta YOKTUR (atolye-2).
//   POST   /:uuid/clear-pin-lock super_user | service_user (kendi karti) (JWT): PIN deneme kilidi/sayaci sifirlanir;
//                                PIN ve anahtar degismez (bireysel-7). Saatte 30.
//   PATCH  /:uuid/service-owner  YALNIZ KOK (super_user JWT): kartin stok sahibini degistirir {service_user_id|null}
//                                (kapsamlar arasi aktarim; kurulu kart evinin servisini izler -> 409)

const express = require('express');
const inventoryService = require('../services/inventory_service');
const serviceScopeService = require('../services/service_scope_service');
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

// PIN kilidi kaldirma: kullanici basina saatte 30 (bireysel-7)
const clearLockLimiter = rateLimit({
  windowMs: 60 * 60 * 1000,
  max: 30,
  keyGenerator: (req) => `inventory-clear-lock:${req.inventoryActor && req.inventoryActor.userId ? req.inventoryActor.userId : clientIp(req)}`,
});

function noStore(res) {
  res.setHeader('Cache-Control', 'no-store');
  res.setHeader('Pragma', 'no-cache');
}

/** Denetim/kapsam icin aktor: { userId, role: 'super_user'|'service_user'|null, type, ip }. */
function auditActor(req) {
  const actor = req.inventoryActor || {};
  return {
    userId: actor.userId || null,
    role: actor.type === 'super_user' || actor.type === 'service_user' ? actor.type : null,
    type: actor.type || null,
    ip: clientIp(req),
  };
}

router.post(
  '/register',
  requireInventoryAccess({ allowApiKey: true, allowStaff: true }),
  asyncHandler(async (req, res) => {
    const b = req.body || {};
    const result = await inventoryService.registerDevice(
      {
        device_uuid: b.device_uuid || b.deviceUuid,
        mac_address: b.mac_address || b.macAddress,
        pin: b.pin || b.setup_pin,
        model: b.model,
        batch_no: b.batch_no || b.batchNo,
      },
      req.inventoryActor
    );
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
  requireInventoryAccess({ allowApiKey: false, allowStaff: true }),
  asyncHandler(async (req, res) => {
    const result = await inventoryService.updateStatus(req.params.uuid, req.body ? req.body.status : undefined, auditActor(req));
    return successResponse(res, result, `Cihaz durumu '${result.status}' olarak güncellendi.`);
  })
);

// KOK-YALNIZ: kartin stok sahibini (servis kapsami) degistirir
router.patch(
  '/:uuid/service-owner',
  requireInventoryAccess({ allowApiKey: false, allowStaff: false }),
  asyncHandler(async (req, res) => {
    const b = req.body || {};
    const hasField = Object.prototype.hasOwnProperty.call(b, 'service_user_id') || Object.prototype.hasOwnProperty.call(b, 'serviceUserId');
    const result = await serviceScopeService.transferInventory({
      deviceUuid: req.params.uuid,
      serviceUserId: hasField ? (b.service_user_id !== undefined ? b.service_user_id : b.serviceUserId) : undefined,
      actor: auditActor(req),
    });
    return successResponse(res, result, result.message);
  })
);

router.post(
  '/:uuid/reissue-label',
  requireInventoryAccess({ allowApiKey: false, allowStaff: true }),
  reissueLimiter,
  asyncHandler(async (req, res) => {
    const result = await inventoryService.reissueLabel(req.params.uuid, auditActor(req));
    noStore(res); // tek seferlik PIN
    return successResponse(res, result, result.message, 200);
  })
);

// bireysel-7: PIN deneme kilidini kaldirma (super_user | kendi kartinda servis; PIN/anahtar degismez)
router.post(
  '/:uuid/clear-pin-lock',
  requireInventoryAccess({ allowApiKey: false, allowStaff: true }),
  clearLockLimiter,
  asyncHandler(async (req, res) => {
    const result = await inventoryService.clearPinLock(req.params.uuid, auditActor(req));
    return successResponse(res, result, 'Kurulum PIN kilidi kaldırıldı.');
  })
);

router.delete(
  '/:uuid',
  requireInventoryAccess({ allowApiKey: false, allowStaff: true }),
  asyncHandler(async (req, res) => {
    const result = await inventoryService.deleteDevice(req.params.uuid, auditActor(req));
    return successResponse(res, null, result.message);
  })
);

router.reissueLimiter = reissueLimiter;
router.clearLockLimiter = clearLockLimiter;
module.exports = router;
