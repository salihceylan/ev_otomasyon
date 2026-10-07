'use strict';

// ==============================================================================
// AHBU Akilli Ev - Guvenlik rotalari (WP-S4). Mount: /api/homes ve /api/v1/homes
// Tasarim: docs/superpowers/specs/2026-10-06-guvenlik-iklim-senaryo-mimarisi-design.md §5.2.4; CONTRACTS §1.5d.
//
//   GET  /:homeId/alarms?state=open|all&before=&limit=          alarm listesi           (view: tum roller)
//   POST /:homeId/alarms/:alarmId/ack {id?}                     alarm onayi/susturma    (safety_ack: misafir YOK)
//   POST /:homeId/devices/:deviceId/actuators/:actuatorId {to, id?}  eylemci komutu     (kapatma herkes; acma
//                                                               actuator_control: misafir YOK; gaz vanasi acma YOK)
//   POST /:homeId/devices/:deviceId/alarm-test {zone, id?}      bolge testi             (safety_test)
// Istege bagli `id` (<= 24, [A-Za-z0-9_.:-]) istemcinin komut kimligidir: panoya AYNEN gider ve state.last_id /
// last_rej.id'de geri yankilanir (uygulama reddi aninda kendi komutuyla eslestirir). Yoksa sunucu uretir.
//   GET  /:homeId/devices/:deviceId/safety-config               yapilandirma kopyasi    (view: tum roller; adlar)
//
// `homeId` YALNIZCA requireHomeAccess'ten (req.homeAccess.home_id) okunur. Eylemci yonu (acma/kapatma) yetkisi
// servis katmaninda (DeviceService.sendCommand -> capabilityForCommand) denetlenir: rota misafire de aciktir
// cunku misafir vanayi KAPATABILIR (§7.2b-4).
// ==============================================================================

const express = require('express');
const { rolesFor } = require('../utils/role_matrix');
const { handle, noStore, actorOf, clientIp, requireCapability, successResponse } = require('./route_helpers');

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
  const safetyService = deps.safetyService || require('../services/safety_service');
  const { authenticateToken, requireHomeAccess } = auth;

  const router = express.Router();
  const userKey = (req) => (req.user && (req.user.id || req.user.sid)) || clientIp(req) || 'anon';
  const commandLimiter = rateLimitFactory({
    windowMs: MINUTE,
    max: 60,
    code: 'RATE_LIMITED',
    keyGenerator: (req) => `safetycmd:${userKey(req)}`,
  });

  router.get(
    '/:homeId/alarms',
    authenticateToken,
    requireHomeAccess(rolesFor('view')),
    handle(async (req, res) => {
      const q = req.query || {};
      const limit = q.limit === undefined ? undefined : /^\d{1,4}$/.test(String(q.limit)) ? Number(q.limit) : -1;
      const result = await safetyService.listAlarms({
        actor: actorOf(req),
        homeId: req.homeAccess.home_id,
        state: q.state,
        before: q.before === undefined ? null : String(q.before),
        limit,
      });
      noStore(res); // canli alarm durumu: ara onbellek bayat liste gostermesin
      return successResponse(res, result);
    })
  );

  router.get(
    '/:homeId/devices/:deviceId/safety-config',
    authenticateToken,
    requireHomeAccess(rolesFor('view')),
    handle(async (req, res) => {
      const result = await safetyService.getSafetyConfig({
        actor: actorOf(req),
        homeId: req.homeAccess.home_id,
        deviceRef: String(req.params.deviceId || ''),
      });
      noStore(res);
      return successResponse(res, result);
    })
  );

  router.post(
    '/:homeId/alarms/:alarmId/ack',
    authenticateToken,
    requireHomeAccess(rolesFor('safety_ack')),
    requireCapability('safety_ack'),
    commandLimiter,
    handle(async (req, res) => {
      const result = await safetyService.ackAlarm({
        actor: actorOf(req),
        homeId: req.homeAccess.home_id,
        alarmId: String(req.params.alarmId || ''),
        commandId: pick(req.body, 'id'),
      });
      return successResponse(res, result, result && result.applied ? 'Alarm onaylandı.' : 'Onay panoya iletildi.', 200);
    })
  );

  router.post(
    '/:homeId/devices/:deviceId/actuators/:actuatorId',
    authenticateToken,
    requireHomeAccess(rolesFor('actuator_close')),
    commandLimiter,
    handle(async (req, res) => {
      const result = await safetyService.controlActuator({
        actor: actorOf(req),
        homeId: req.homeAccess.home_id,
        deviceRef: String(req.params.deviceId || ''),
        actuatorId: String(req.params.actuatorId || ''),
        to: pick(req.body, 'to', 'state'),
        commandId: pick(req.body, 'id'),
      });
      return successResponse(res, result, result && result.applied ? 'Komut uygulandı.' : 'Komut panoya iletildi.', 200);
    })
  );

  router.post(
    '/:homeId/devices/:deviceId/alarm-test',
    authenticateToken,
    requireHomeAccess(rolesFor('safety_test')),
    requireCapability('safety_test'),
    commandLimiter,
    handle(async (req, res) => {
      const result = await safetyService.testZone({
        actor: actorOf(req),
        homeId: req.homeAccess.home_id,
        deviceRef: String(req.params.deviceId || ''),
        zone: pick(req.body, 'zone'),
        commandId: pick(req.body, 'id'),
      });
      return successResponse(res, result, 'Bölge testi başlatıldı.', 200);
    })
  );

  return router;
}

module.exports = createRouter();
module.exports.createRouter = createRouter;
