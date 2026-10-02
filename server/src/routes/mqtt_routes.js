'use strict';

// ==============================================================================
// AHBU Akilli Ev - MQTT kimlik rotasi (WP-B, B7). Mount: /api/homes ve /api/v1/homes
//
//   POST /:homeId/mqtt-credentials
//     Uyelik + (misafir) sure dogrulanir (requireHomeAccess). Yanit (CONTRACTS §1.5):
//       { host, port, username, password, client_id, expires_at, topic_id }
//     SALT-OKUNUR kimlik: yalnizca ev/{t}/state ve ev/{t}/status aboneligi. Sure = min(12 saat, misafir bitisi).
//     Istemci sure dolmadan yeniler. Komutlar MQTT'den degil REST'ten (POST /devices/:id/command) gider.
// ==============================================================================

const express = require('express');
const { rolesFor } = require('../utils/role_matrix');
const { httpError } = require('../utils/http_errors');
const {
  handle,
  noStore,
  actorOf,
  clientIp,
  successResponse,
} = require('./route_helpers');

const MINUTE = 60 * 1000;

function createRouter(deps = {}) {
  const auth = deps.auth || require('../middlewares/auth_middleware');
  const rateLimitFactory = deps.rateLimit || require('../middlewares/rate_limit');
  const credentials = deps.mqttCredentials || require('../services/mqtt_credential_service');
  const { authenticateToken, requireHomeAccess } = auth;

  const router = express.Router();

  const limiter = rateLimitFactory({
    windowMs: 60 * MINUTE,
    max: 60,
    code: 'RATE_LIMITED',
    keyGenerator: (req) =>
      `mqttcred:${(req.user && (req.user.id || req.user.sid)) || clientIp(req) || 'anon'}|${
        (req.homeAccess && req.homeAccess.home_id) || ''
      }`,
  });

  router.post(
    '/:homeId/mqtt-credentials',
    authenticateToken,
    requireHomeAccess(rolesFor('mqtt_credentials')),
    limiter,
    handle(async (req, res) => {
      const actor = actorOf(req);
      const access = req.homeAccess;

      // Sure sinirlari: misafir -> erisim penceresinin bitisi; servis (PIN) oturumu -> oturum bitisi.
      let validUntil = null;
      if (actor.access === 'guest') {
        validUntil = access.valid_until || null;
        if (!validUntil) {
          // Bitis tarihi olmayan misafir icin sure hesaplanamaz: fail-closed.
          throw httpError(403, 'Misafir erişim süresi tanımlı değil.', 'GUEST_EXPIRED');
        }
      } else if (actor.isServiceSession) {
        validUntil = access.valid_until || (req.user && req.user.session_expires_at) || null;
      }

      const credential = await credentials.issueUserCredential({
        homeId: access.home_id,
        userId: actor.userId, // servis oturumunda null
        validUntil,
      });

      noStore(res);
      return successResponse(
        res,
        {
          host: credential.host,
          port: credential.port,
          username: credential.username,
          password: credential.password,
          client_id: credential.client_id,
          expires_at: credential.expires_at,
          topic_id: credential.topic_id,
        },
        'MQTT kimliği oluşturuldu.',
        200
      );
    })
  );

  return router;
}

module.exports = createRouter();
module.exports.createRouter = createRouter;
