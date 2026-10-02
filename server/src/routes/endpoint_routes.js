'use strict';

// ==============================================================================
// AHBU Akilli Ev - Kontrol noktasi (endpoint) rotalari (WP-B, B8)
// Mount: /api/homes/:home_id/endpoints ve /api/v1/homes/:home_id/endpoints  (mergeParams)
//
//   GET  /            dairedeki tum kontrol noktalari          (durum gorme: tum roller)
//   PUT  /:id         kanal adi/oda/(light<->plug) + panjur kalibrasyonu (1..300 sn, `set_runtime` yayini)
//                     yetki: owner / staff / servis oturumu / super   (resident ve misafir HAYIR)
//   POST /:id/control tek uc nokta komutu (firmware sozlugune cevrilip sendCommand'dan gecer)
//
// `home_id` YALNIZCA requireHomeAccess'ten (req.homeAccess.home_id) okunur.
// ==============================================================================

const express = require('express');
const { rolesFor } = require('../utils/role_matrix');
const {
  handle,
  actorOf,
  clientIp,
  requireCapability,
  successResponse,
} = require('./route_helpers');

const MINUTE = 60 * 1000;

function createRouter(deps = {}) {
  const auth = deps.auth || require('../middlewares/auth_middleware');
  const rateLimitFactory = deps.rateLimit || require('../middlewares/rate_limit');
  const endpointService = deps.endpointService || require('../services/endpoint_service');
  const { authenticateToken, requireHomeAccess } = auth;

  const router = express.Router({ mergeParams: true });

  const userKey = (req) => (req.user && (req.user.id || req.user.sid)) || clientIp(req) || 'anon';
  const controlLimiter = rateLimitFactory({
    windowMs: MINUTE,
    max: 240,
    code: 'RATE_LIMITED',
    keyGenerator: (req) => `epcontrol:${userKey(req)}`,
  });
  const updateLimiter = rateLimitFactory({
    windowMs: MINUTE,
    max: 60,
    code: 'RATE_LIMITED',
    keyGenerator: (req) => `epupdate:${userKey(req)}`,
  });

  router.get(
    '/',
    authenticateToken,
    requireHomeAccess(rolesFor('view')),
    handle(async (req, res) => {
      const endpoints = await endpointService.getEndpointsByHome(req.homeAccess.home_id);
      return successResponse(res, endpoints);
    })
  );

  router.put(
    '/:id',
    authenticateToken,
    requireHomeAccess(rolesFor('calibrate')),
    requireCapability('calibrate'),
    updateLimiter,
    handle(async (req, res) => {
      const updated = await endpointService.updateEndpoint({
        actor: actorOf(req),
        homeId: req.homeAccess.home_id,
        endpointId: req.params.id,
        patch: req.body,
      });
      return successResponse(res, updated, 'Kontrol noktası güncellendi.');
    })
  );

  router.post(
    '/:id/control',
    authenticateToken,
    requireHomeAccess(rolesFor('control')),
    controlLimiter,
    handle(async (req, res) => {
      const result = await endpointService.controlEndpoint({
        actor: actorOf(req),
        homeId: req.homeAccess.home_id,
        endpointId: req.params.id,
        commandData: req.body,
      });
      return successResponse(res, result, 'Komut iletildi.');
    })
  );

  return router;
}

module.exports = createRouter();
module.exports.createRouter = createRouter;
