'use strict';

// ==============================================================================
// AHBU Akilli Ev - Ev kapsamli cihaz rotalari (WP-B). Mount: /api/homes ve /api/v1/homes
// (serviceRoutes'tan ONCE baglanmalidir: eski /commissioning uclari yerine gecer)
//
//   GET  /:homeId/devices                        [{ device_uuid, name, online, last_seen_at, firmware }]
//   GET  /:homeId/devices/:uuid/local-key        { local_key }    owner/resident/staff/servis oturumu
//   POST /:homeId/devices/:uuid/mqtt-credential  cihaz MQTT kimligini yeniden uret (tek seferlik yanit)
//   POST /:homeId/commissioning                  { device_uuid, checks:{relays,buttons,shutters,network,cloud}, notes }
//   GET  /:homeId/commissioning-status           dairedeki tum cihazlarin devreye alma durumu
//
// `homeId` YALNIZCA requireHomeAccess'ten (req.homeAccess.home_id) okunur.
// ==============================================================================

const express = require('express');
const { rolesFor } = require('../utils/role_matrix');
const {
  handle,
  noStore,
  actorOf,
  clientIp,
  requireCapability,
  successResponse,
} = require('./route_helpers');

const MINUTE = 60 * 1000;

function pick(body, ...names) {
  const b = body && typeof body === 'object' ? body : {};
  for (const n of names) {
    if (b[n] !== undefined && b[n] !== null) return b[n];
  }
  return undefined;
}

function createRouter(deps = {}) {
  const auth = deps.auth || require('../middlewares/auth_middleware');
  const rateLimitFactory = deps.rateLimit || require('../middlewares/rate_limit');
  const deviceService = deps.deviceService || require('../services/device_service');
  const { authenticateToken, requireHomeAccess } = auth;

  const router = express.Router();

  const userKey = (req) => (req.user && (req.user.id || req.user.sid)) || clientIp(req) || 'anon';
  const credentialLimiter = rateLimitFactory({
    windowMs: 15 * MINUTE,
    max: 5,
    code: 'RATE_LIMITED',
    keyGenerator: (req) =>
      `devcred:${userKey(req)}|${(req.homeAccess && req.homeAccess.home_id) || ''}|${String(req.params.uuid || '').toUpperCase()}`,
  });
  const commissioningLimiter = rateLimitFactory({
    windowMs: 15 * MINUTE,
    max: 20,
    code: 'RATE_LIMITED',
    keyGenerator: (req) => `commission:${userKey(req)}|${(req.homeAccess && req.homeAccess.home_id) || ''}`,
  });

  // Cihaz listesi (durum gorme: tum roller; ag bilgisi (IP) misafire verilmez)
  router.get(
    '/:homeId/devices',
    authenticateToken,
    requireHomeAccess(rolesFor('view')),
    handle(async (req, res) => {
      const actor = actorOf(req);
      const devices = await deviceService.listDevices({
        homeId: req.homeAccess.home_id,
        includeNetwork: actor.access !== 'guest',
      });
      return successResponse(res, devices);
    })
  );

  // Yerel anahtar (LAN dogrudan mod): her okuma denetim kaydina yazilir
  router.get(
    '/:homeId/devices/:uuid/local-key',
    authenticateToken,
    requireHomeAccess(rolesFor('local_key')),
    requireCapability('local_key'),
    handle(async (req, res) => {
      const result = await deviceService.getLocalKey({
        actor: actorOf(req),
        homeId: req.homeAccess.home_id,
        deviceUuid: req.params.uuid,
      });
      noStore(res);
      return successResponse(res, result);
    })
  );

  // Cihaz MQTT kimligini yeniden uret (kurulum yarida kaldiysa / kimlik kaybolduysa). Tek seferlik yanit.
  router.post(
    '/:homeId/devices/:uuid/mqtt-credential',
    authenticateToken,
    requireHomeAccess(rolesFor('device_credential')),
    requireCapability('device_credential'),
    credentialLimiter,
    handle(async (req, res) => {
      const result = await deviceService.reissueDeviceCredential({
        actor: actorOf(req),
        homeId: req.homeAccess.home_id,
        deviceUuid: req.params.uuid,
      });
      noStore(res);
      return successResponse(res, result, 'Cihaz MQTT kimliği yenilendi. Parola yalnızca şimdi gösterilir.', 200);
    })
  );

  // Devreye alma: tests_passed SUNUCUDA hesaplanir (istemci degeri yok sayilir)
  router.post(
    '/:homeId/commissioning',
    authenticateToken,
    requireHomeAccess(rolesFor('commission')),
    requireCapability('commission'),
    commissioningLimiter,
    handle(async (req, res) => {
      const result = await deviceService.commissionHome({
        actor: actorOf(req),
        homeId: req.homeAccess.home_id,
        deviceUuid: pick(req.body, 'device_uuid', 'deviceUuid'),
        checks: pick(req.body, 'checks'),
        notes: pick(req.body, 'notes'),
      });
      const message = result.tests_passed
        ? 'Tüm zorunlu kontroller başarılı; sistem "çalışır" olarak onaylandı.'
        : 'Bazı zorunlu kontroller başarısız; sistem onaylanmadı.';
      return successResponse(res, result, message, 200);
    })
  );

  router.get(
    '/:homeId/commissioning-status',
    authenticateToken,
    requireHomeAccess(rolesFor('calibrate')),
    handle(async (req, res) => {
      const result = await deviceService.getCommissioningStatus({ homeId: req.homeAccess.home_id });
      return successResponse(res, result);
    })
  );

  return router;
}

module.exports = createRouter();
module.exports.createRouter = createRouter;
