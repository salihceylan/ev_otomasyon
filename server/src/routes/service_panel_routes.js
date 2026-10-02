'use strict';

// ==============================================================================
// AHBU Akilli Ev - Servis paneli rotalari (WP-B2). Mount: /api/v1/service ve /api/service
// ==============================================================================
//
//   GET  /subscribers                                    abone (ev) listesi (?q=&limit=&offset=)
//   POST /subscribers/:homeId/assign-admin/request-otp   mevcut sahibe onay kodu (OTP)  { full_name, email|phone }
//   POST /subscribers/:homeId/assign-admin               Home Admin atama
//                                                        { full_name, email|phone, otp_code?, force?, reason? }
//
// YETKI: JWT + global rol service_user | super_user (servis PIN oturumu, owner, resident, misafir HAYIR).
// Ev kapsamli uclarda ayrica `requireHomeAccess(['super_user', 'service_user'])`: staff yalnizca home_users'ta
// suresi dolmamis 'service_user' uyeligi olan evlerde; super_user her evde. `homeId` YALNIZCA dogrulanmis
// uyelikten (req.homeAccess.home_id) okunur. Hata govdesi CONTRACTS §1.1: { success:false, message, code }.
// Kimlik dogrulama HER ROUTE'TA ayri uygulanir (router.use YOK): router `/api` altina da baglandigi icin
// router.use kendisine ait olmayan isteklere de 401 donerdi.

const express = require('express');
const { asyncHandler } = require('../middlewares/error_handler');
const { successResponse } = require('../utils/helpers');
const { actorOf, clientIp, noStore } = require('./route_helpers');

const MINUTE = 60 * 1000;
const STAFF_ROLES = Object.freeze(['super_user', 'service_user']);

/** Govde alanlari: snake_case esas, camelCase gecis donemi icin kabul. Ilk dolu deger doner. */
function pick(body, ...names) {
  const b = body && typeof body === 'object' ? body : {};
  for (const n of names) {
    if (b[n] !== undefined && b[n] !== null && b[n] !== '') return b[n];
  }
  return undefined;
}

function targetOf(body) {
  return {
    fullName: pick(body, 'full_name', 'fullName', 'name'),
    email: pick(body, 'email'),
    phone: pick(body, 'phone'),
  };
}

function createRouter(deps = {}) {
  const auth = deps.auth || require('../middlewares/auth_middleware');
  const rateLimitFactory = deps.rateLimit || require('../middlewares/rate_limit');
  const panel = deps.servicePanelService || require('../services/service_panel_service');
  const { authenticateToken, requireServiceManager, requireHomeAccess } = auth;

  const router = express.Router();

  const userKey = (req) => (req.user && req.user.id) || clientIp(req) || 'anon';
  const homeKey = (req) => (req.homeAccess && req.homeAccess.home_id) || 'nohome';
  const limiter = (name, { windowMs, max, key }) =>
    rateLimitFactory({
      windowMs,
      max,
      code: 'RATE_LIMITED',
      keyGenerator: (req) => `${name}:${key(req)}`,
    });

  // --- Hiz sinirlari (kullanici + ev); OTP/deneme kilitleri ayrica veritabaninda tutulur ---
  const listUser = limiter('svcpanel-list', { windowMs: MINUTE, max: 120, key: userKey });
  const otpUserHome = limiter('svcpanel-otp-home', { windowMs: 60 * MINUTE, max: 5, key: (req) => `${userKey(req)}|${homeKey(req)}` });
  const otpIp = limiter('svcpanel-otp-ip', { windowMs: 15 * MINUTE, max: 10, key: (req) => clientIp(req) || 'unknown' });
  const assignUser = limiter('svcpanel-assign-user', { windowMs: 15 * MINUTE, max: 10, key: userKey });
  const assignHome = limiter('svcpanel-assign-home', { windowMs: 60 * MINUTE, max: 10, key: homeKey });

  const homeGuard = [authenticateToken, requireServiceManager, requireHomeAccess([...STAFF_ROLES])];

  // GET /subscribers
  router.get(
    '/subscribers',
    authenticateToken,
    requireServiceManager,
    listUser,
    asyncHandler(async (req, res) => {
      const result = await panel.listSubscribers({
        actor: actorOf(req),
        q: req.query ? req.query.q : undefined,
        limit: req.query ? req.query.limit : undefined,
        offset: req.query ? req.query.offset : undefined,
      });
      noStore(res); // iletisim bilgisi icerir
      return successResponse(res, result);
    })
  );

  // POST /subscribers/:homeId/assign-admin/request-otp
  router.post(
    '/subscribers/:homeId/assign-admin/request-otp',
    ...homeGuard,
    otpIp,
    otpUserHome,
    asyncHandler(async (req, res) => {
      const result = await panel.requestAssignAdminOtp({
        actor: actorOf(req),
        homeId: req.homeAccess.home_id,
        target: targetOf(req.body),
      });
      noStore(res);
      return successResponse(res, result, result.message);
    })
  );

  // POST /subscribers/:homeId/assign-admin
  router.post(
    '/subscribers/:homeId/assign-admin',
    ...homeGuard,
    assignUser,
    assignHome,
    asyncHandler(async (req, res) => {
      const result = await panel.assignAdmin({
        actor: actorOf(req),
        homeId: req.homeAccess.home_id,
        target: targetOf(req.body),
        otpCode: pick(req.body, 'otp_code', 'otpCode', 'code'),
        force: pick(req.body, 'force'),
        reason: pick(req.body, 'reason'),
      });
      noStore(res);
      return successResponse(res, result, result.message);
    })
  );

  // Testler / operasyon: sayaclari sifirlamak veya incelemek icin (auth_routes.limiters ile ayni kural)
  router.limiters = { listUser, otpIp, otpUserHome, assignUser, assignHome };
  return router;
}

module.exports = createRouter();
module.exports.createRouter = createRouter;
