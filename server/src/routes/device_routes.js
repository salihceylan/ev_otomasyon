'use strict';

// ==============================================================================
// AHBU Akilli Ev - Cihaz API rotalari (WP-B). Mount: /api/devices ve /api/v1/devices
//
// B1: HER uc `authenticateToken` + (ev kapsamliysa) `requireHomeAccess(rol listesi)` + yetenek kapisi.
//     `home_id` YALNIZCA dogrulanmis uyelikten (req.homeAccess.home_id) okunur; govde/sorgu degeri esas alinmaz.
//     Komutlar yalnizca buradan (REST) gider; uygulama MQTT'ye dogrudan yayin yapmaz.
//
//   POST /claim/request-otp          servis personeli -> musteriye OTP (staff/super)
//   POST /claim                      sahiplenme (home_id KABUL EDILMEZ)
//   POST /emergency-reset            acil sifirlama (staff yalniz uyesi oldugu evde / super)
//   POST /replace-board              pano degisimi
//   POST /:id/command                cihaza komut {home_id, command}
//   POST /child-lock                 cocuk kilidi            GET /child-lock/:home_id
//   GET|PUT /peace-notification/:home_id   POST /peace-notification/close-all
//   GET /diagnostic/:home_id         sistem doktoru (tum cihazlar)
//   GET /home/:home_id               (eski) cihaz listesi
// ==============================================================================

const express = require('express');
const { rolesFor, can } = require('../utils/role_matrix');
const { validateCommand } = require('../utils/command_schema');
const {
  handle,
  noStore,
  actorOf,
  clientIp,
  requireGlobalRoles,
  requireCapability,
  sendError,
  httpError,
  successResponse,
} = require('./route_helpers');

const MINUTE = 60 * 1000;

/** Govde alanlari: snake_case esas, camelCase gecis donemi icin kabul. */
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

  const limiter = (name, { windowMs, max, key }) =>
    rateLimitFactory({
      windowMs,
      max,
      code: 'RATE_LIMITED',
      keyGenerator: (req) => `${name}:${key(req)}`,
    });

  const userKey = (req) => (req.user && (req.user.id || req.user.sid)) || clientIp(req) || 'anon';
  const uidKey = (req) => String(pick(req.body, 'device_uuid', 'deviceUuid', 'uid') || '').trim().toUpperCase().slice(0, 64);
  const homeKey = (req) => (req.homeAccess && req.homeAccess.home_id) || 'nohome';

  // --- Hiz sinirlari (IP + kullanici + cihaz); PIN/OTP kilitleri ayrica veritabaninda tutulur ---
  const claimIp = limiter('devclaim-ip', { windowMs: 15 * MINUTE, max: 30, key: (req) => clientIp(req) || 'unknown' });
  const claimUserUid = limiter('devclaim-user-uid', {
    windowMs: 15 * MINUTE,
    max: 10,
    key: (req) => `${userKey(req)}|${uidKey(req)}`,
  });
  const otpIp = limiter('devotp-ip', { windowMs: 15 * MINUTE, max: 10, key: (req) => clientIp(req) || 'unknown' });
  const otpTarget = limiter('devotp-target', {
    windowMs: 60 * MINUTE,
    max: 5,
    key: (req) =>
      `${uidKey(req)}|${String(pick(req.body, 'target_owner', 'targetOwner', 'owner_email', 'owner_phone') || '')
        .trim()
        .toLowerCase()
        .slice(0, 255)}`,
  });
  const resetUser = limiter('devreset-user', { windowMs: 60 * MINUTE, max: 10, key: userKey });
  const replaceUser = limiter('devreplace-user', {
    windowMs: 15 * MINUTE,
    max: 10,
    key: (req) => `${userKey(req)}|${homeKey(req)}`,
  });
  const commandUser = limiter('devcmd-user', { windowMs: MINUTE, max: 240, key: userKey });
  const settingsUser = limiter('devsettings-user', { windowMs: MINUTE, max: 60, key: userKey });
  // Cocuk kilidi: her gecis panoda NVS yazar ve bip calar -> EV basina sinir (dakikada 6, saatte 30).
  // Hem POST /child-lock hem de genel komut rotasindaki set_child_lock ayni sayaclari kullanir.
  const childLockMinute = limiter('devchildlock-min', { windowMs: MINUTE, max: 6, key: homeKey });
  const childLockHour = limiter('devchildlock-hour', { windowMs: 60 * MINUTE, max: 30, key: homeKey });
  const applyChildLockLimits = (req, res, next) =>
    childLockMinute(req, res, (err) => (err ? next(err) : childLockHour(req, res, next)));
  // Ev kotasi YALNIZCA gecerli VE yetkili istekler icin harcanir: bozuk girdi (400) ve yetkisiz rol (403, ornegin misafir)
  // sahibin kilit kotasini tuketemez. Yetki/dogrulama sonucunu servis katmani yine verir (400/403); bu kapi yalnizca sayar.
  const childLockBodyGate = (req, res, next) => {
    const check = validateCommand({ cmd: 'set_child_lock', enabled: pick(req.body, 'enabled') });
    if (!check.ok) return sendError(res, httpError(400, check.error, 'VALIDATION'));
    return next();
  };
  const isChildLockCommand = (req) =>
    Boolean(req.body && req.body.command && typeof req.body.command === 'object' && req.body.command.cmd === 'set_child_lock');
  const childLockCommandGate = (req, res, next) => {
    if (!isChildLockCommand(req)) return next();
    if (!validateCommand(req.body.command).ok || !can('child_lock', req.homeAccess)) return next();
    return applyChildLockLimits(req, res, next);
  };

  // ---------------------------------------------------------------------------
  // Sahiplenme (claim)
  // ---------------------------------------------------------------------------

  router.post(
    '/claim/request-otp',
    authenticateToken,
    requireGlobalRoles(['service_user', 'super_user'], 'Doğrulama kodu yalnızca yetkili servis personeli tarafından istenebilir.'),
    otpIp,
    otpTarget,
    handle(async (req, res) => {
      const result = await deviceService.requestClaimOtp({
        actor: actorOf(req),
        deviceUuid: pick(req.body, 'device_uuid', 'deviceUuid', 'uid'),
        targetOwnerIdentifier: pick(req.body, 'target_owner', 'targetOwner', 'owner_email', 'owner_phone'),
      });
      noStore(res);
      return successResponse(res, result, result.message, 200);
    })
  );

  router.post(
    '/claim',
    authenticateToken,
    requireGlobalRoles(['user', 'service_user', 'super_user'], 'Cihaz sahiplenme için kullanıcı hesabı gereklidir.'),
    claimIp,
    claimUserUid,
    handle(async (req, res) => {
      // home_id KABUL EDILMEZ: ev sunucuda belirlenir.
      const result = await deviceService.claimDevice({
        actor: actorOf(req),
        deviceUuid: pick(req.body, 'device_uuid', 'deviceUuid', 'uid'),
        setupPin: pick(req.body, 'setup_pin', 'setupPin', 'pin'),
        homeName: pick(req.body, 'home_name', 'homeName'),
        targetOwnerIdentifier: pick(req.body, 'target_owner', 'targetOwner', 'owner_email', 'owner_phone'),
        otpCode: pick(req.body, 'otp_code', 'otpCode'),
      });
      noStore(res); // tek seferlik cihaz kimligi icerir
      return successResponse(res, result, 'Cihaz dairenize tanımlandı.', 200);
    })
  );

  // ---------------------------------------------------------------------------
  // Acil sifirlama (ev kapsamsiz: cihazdan ev turetilir; staff yetkisi serviste dogrulanir)
  // ---------------------------------------------------------------------------

  router.post(
    '/emergency-reset',
    authenticateToken,
    requireGlobalRoles(['service_user', 'super_user'], 'Acil sıfırlama yalnızca yetkili servis personeli veya süper yönetici içindir.'),
    resetUser,
    handle(async (req, res) => {
      const result = await deviceService.emergencyReset({
        actor: actorOf(req),
        deviceUuid: pick(req.body, 'device_uuid', 'deviceUuid', 'uid'),
        confirmUid: pick(req.body, 'confirm_uid', 'confirmUid'),
        reason: pick(req.body, 'reason'),
        newOwnerIdentifier: pick(req.body, 'new_owner_identifier', 'newOwnerIdentifier'),
      });
      noStore(res); // tek seferlik PIN icerir
      return successResponse(res, result, result.message || 'Acil sıfırlama tamamlandı.', 200);
    })
  );

  // ---------------------------------------------------------------------------
  // Pano degisimi (owner / staff / servis oturumu / super)
  // ---------------------------------------------------------------------------

  router.post(
    '/replace-board',
    authenticateToken,
    requireHomeAccess(rolesFor('replace_board')),
    requireCapability('replace_board'),
    replaceUser,
    handle(async (req, res) => {
      const result = await deviceService.replaceBoard({
        actor: actorOf(req),
        homeId: req.homeAccess.home_id,
        oldDeviceUuid: pick(req.body, 'old_device_uuid', 'oldDeviceUuid'),
        newDeviceUuid: pick(req.body, 'new_device_uuid', 'newDeviceUuid'),
        setupPin: pick(req.body, 'setup_pin', 'setupPin'),
        reason: pick(req.body, 'reason'),
      });
      noStore(res);
      return successResponse(res, result, result.message, 200);
    })
  );

  // ---------------------------------------------------------------------------
  // Cocuk kilidi / gece huzur bildirimi / toplu kapatma
  // ---------------------------------------------------------------------------

  router.post(
    '/child-lock',
    authenticateToken,
    requireHomeAccess(rolesFor('child_lock')),
    requireCapability('child_lock'),
    settingsUser,
    childLockBodyGate,
    applyChildLockLimits,
    handle(async (req, res) => {
      const result = await deviceService.setChildLock({
        actor: actorOf(req),
        homeId: req.homeAccess.home_id,
        enabled: pick(req.body, 'enabled'),
      });
      // PUBACK != uygulandi: "kilitlendi" denmez; gercek deger cihazin state.child_lock bildiriminden gelir.
      let message = 'Komut cihaza iletildi.';
      if (result.no_change) message = 'Çocuk kilidi zaten istenen durumda.';
      else if (result.offline_devices && result.offline_devices.length > 0) message = 'Komut iletildi; bazı panolar çevrimdışı.';
      return successResponse(res, result, message, 200);
    })
  );

  router.get(
    '/child-lock/:home_id',
    authenticateToken,
    requireHomeAccess(rolesFor('view')),
    handle(async (req, res) => {
      const result = await deviceService.getChildLock({ homeId: req.homeAccess.home_id });
      noStore(res); // durum anlik goruntusu: ara onbellek bayat kilit durumu gostermesin
      return successResponse(res, result);
    })
  );

  router.get(
    '/peace-notification/:home_id',
    authenticateToken,
    requireHomeAccess(rolesFor('view')),
    handle(async (req, res) => {
      const result = await deviceService.getPeaceNotificationSettings({ homeId: req.homeAccess.home_id });
      noStore(res); // canli anlik goruntu: ara onbellek bayat "acik lamba" gostermesin
      return successResponse(res, result);
    })
  );

  router.put(
    '/peace-notification/:home_id',
    authenticateToken,
    requireHomeAccess(rolesFor('child_lock')),
    requireCapability('child_lock'),
    settingsUser,
    handle(async (req, res) => {
      const result = await deviceService.updatePeaceNotificationSettings({
        actor: actorOf(req),
        homeId: req.homeAccess.home_id,
        enabled: pick(req.body, 'enabled'),
        notificationTime: pick(req.body, 'notification_time', 'notificationTime'),
      });
      return successResponse(res, result, result.message, 200);
    })
  );

  router.post(
    '/peace-notification/close-all',
    authenticateToken,
    requireHomeAccess(rolesFor('group')),
    requireCapability('group'),
    commandUser,
    handle(async (req, res) => {
      const result = await deviceService.closeAllOpenLights({
        actor: actorOf(req),
        homeId: req.homeAccess.home_id,
        noticeId: pick(req.body, 'notice_id', 'noticeId'), // bildirimden gelen tiklama: o kaydi cozer (WP-H)
        includeShutters: pick(req.body, 'include_shutters', 'includeShutters'),
      });
      return successResponse(res, result, result.message, 200);
    })
  );

  // ---------------------------------------------------------------------------
  // Sistem doktoru (misafir HARIC; ev agi/IP bilgisi icerir)
  // ---------------------------------------------------------------------------

  const diagnosticHandler = handle(async (req, res) => {
    const result = await deviceService.getSystemDiagnostic({ homeId: req.homeAccess.home_id });
    return successResponse(res, result, 'Teşhis raporu oluşturuldu.', 200);
  });
  router.get(
    '/diagnostic/:home_id',
    authenticateToken,
    requireHomeAccess(rolesFor('child_lock')),
    requireCapability('child_lock'),
    diagnosticHandler
  );
  // home_id sorgu parametresiyle (?home_id=...): requireHomeAccess yoksa/gecersizse 400 doner (sessiz "ilk ev" YOK).
  router.get(
    '/diagnostic',
    authenticateToken,
    requireHomeAccess(rolesFor('child_lock')),
    requireCapability('child_lock'),
    diagnosticHandler
  );

  // ---------------------------------------------------------------------------
  // (Eski) cihaz listesi - yeni sozlesme: GET /homes/:homeId/devices (home_device_routes.js)
  // ---------------------------------------------------------------------------

  router.get(
    '/home/:home_id',
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

  // ---------------------------------------------------------------------------
  // Komut: POST /devices/:id/command { home_id, command }  (CONTRACTS §1.5)
  // Sema + rol matrisi (misafir: toplu/cocuk kilidi YOK; kalibrasyon yalniz owner/servis) + cevrimdisi 409.
  // ---------------------------------------------------------------------------

  router.post(
    '/:id/command',
    authenticateToken,
    requireHomeAccess(rolesFor('control')),
    commandUser,
    childLockCommandGate,
    handle(async (req, res) => {
      const result = await deviceService.sendCommand({
        actor: actorOf(req),
        homeId: req.homeAccess.home_id,
        deviceRef: req.params.id,
        command: req.body ? req.body.command : undefined,
      });
      return successResponse(res, result, 'Komut cihaza iletildi.', 200);
    })
  );

  return router;
}

module.exports = createRouter();
module.exports.createRouter = createRouter;
