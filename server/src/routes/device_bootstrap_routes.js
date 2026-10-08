'use strict';

// ==============================================================================
// AHBU Akilli Ev - Pano bootstrap rotasi (CONTRACTS bolum 3f). Mount: /api/v1 ve /api
// ==============================================================================
//
//   POST /devices/bootstrap   {device_uuid, ts, nonce, fw?, sig}   JWT YOK (pano yerel anahtariyla imzalar)
//
// Oran siniri (bellek ici, surec basina): kart basina saatte 6, IP basina saatte 60; asimda 429 RATE_LIMITED (+Retry-After).
// IP siniri once uygulanir (kart kimligini degistirerek IP butcesi asilamaz). Yanit govdesi servisin urettigi gibi
// HAM yazilir (200 {status,mqtt} / 202 {status} / 401 sabit govde); servis hatasi global yakalayiciya gider (500).
// Bu router `/api/v1/devices` altindaki device_routes'tan ONCE baglanir.

const express = require('express');
const { asyncHandler } = require('../middlewares/error_handler');
const { noStore } = require('./route_helpers');

const HOUR = 60 * 60 * 1000;
const PER_DEVICE_PER_HOUR = 6;
const PER_IP_PER_HOUR = 60;

function deviceKey(req) {
  const b = req.body && typeof req.body === 'object' && !Array.isArray(req.body) ? req.body : {};
  const u = typeof b.device_uuid === 'string' ? b.device_uuid.trim().toUpperCase().slice(0, 64) : '';
  return u || 'invalid';
}

function createRouter(deps = {}) {
  const rateLimitFactory = deps.rateLimit || require('../middlewares/rate_limit');
  const { clientIp } = require('../middlewares/rate_limit');
  const svc = deps.bootstrapService || require('../services/device_bootstrap_service');

  const router = express.Router();
  const ipLimiter = rateLimitFactory({
    windowMs: HOUR,
    max: PER_IP_PER_HOUR,
    code: 'RATE_LIMITED',
    keyGenerator: (req) => `bootstrap-ip:${clientIp(req)}`,
  });
  const deviceLimiter = rateLimitFactory({
    windowMs: HOUR,
    max: PER_DEVICE_PER_HOUR,
    code: 'RATE_LIMITED',
    keyGenerator: (req) => `bootstrap-dev:${deviceKey(req)}`,
  });

  router.post(
    '/devices/bootstrap',
    ipLimiter,
    deviceLimiter,
    asyncHandler(async (req, res) => {
      const body = req.body && typeof req.body === 'object' && !Array.isArray(req.body) ? req.body : {};
      const result = await svc.bootstrap({ body, ip: clientIp(req) });
      noStore(res); // 200 yaniti MQTT parolasi tasir
      return res.status(result.http).json(result.body);
    })
  );

  router.limiters = { ipLimiter, deviceLimiter };
  return router;
}

module.exports = createRouter();
module.exports.createRouter = createRouter;
