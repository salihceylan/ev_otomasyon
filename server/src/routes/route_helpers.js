'use strict';

// ==============================================================================
// WP-B route yardimcilari: hata esleme, async sarmalayici, aktor bilgisi, yetenek kapisi.
// (device_routes / home_device_routes / endpoint_routes / mqtt_routes ortak kullanir.)
// ==============================================================================

const { successResponse } = require('../utils/helpers');
const { toErrorResponse, summarizeError, httpError } = require('../utils/http_errors');
const { can, effectiveRole } = require('../utils/role_matrix');

/** Hatayi CONTRACTS §1.1 bicimine cevirip yanitlar (5xx'te ic mesaj sizmaz, loga yazilir). */
function sendError(res, err, tag = 'WP-B') {
  const { status, body, retryAfter, shouldLog } = toErrorResponse(err);
  if (shouldLog) {
    console.error(`[${tag}] ${summarizeError(err)}`);
  }
  if (retryAfter && typeof res.setHeader === 'function') {
    res.setHeader('Retry-After', String(retryAfter));
  }
  return res.status(status).json(body);
}

/** Async handler sarmalayici: firlatilan hata sendError ile yanitlanir (yutulmaz, sizmaz). */
function handle(fn, tag = 'WP-B') {
  return async function routeHandler(req, res, next) {
    try {
      await fn(req, res, next);
    } catch (err) {
      sendError(res, err, tag);
    }
  };
}

/** Sirlar (parola, anahtar, kimlik) iceren yanitlar onbelleklenmesin. */
function noStore(res) {
  res.setHeader('Cache-Control', 'no-store');
  res.setHeader('Pragma', 'no-cache');
}

function clientIp(req) {
  const raw = req.ip || (req.socket && req.socket.remoteAddress) || '';
  const ip = String(raw).replace(/^::ffff:/i, '');
  return ip || null;
}

/**
 * Istekten aktor bilgisi. `access`: requireHomeAccess sonrasi matristeki etkin rol.
 * Servis oturumunda userId null'dir (kullanici satiri yoktur).
 */
function actorOf(req) {
  const user = req.user || {};
  const isSession = user.is_service_session === true || user.role === 'service_session';
  return {
    userId: user.id || null,
    globalRole: isSession ? 'service_session' : user.role || null,
    isServiceSession: isSession,
    sessionId: user.sid || null,
    label: user.technician_name || user.full_name || null,
    email: user.email || null,
    ip: clientIp(req),
    access: req.homeAccess ? effectiveRole(req.homeAccess) : null,
  };
}

/**
 * Global rol kapisi (ev kapsamsiz uclar: OTP isteme, acil sifirlama, sahiplenme).
 * Servis (PIN) oturumu token'i HICBIR zaman gecemez.
 */
function requireGlobalRoles(allowed, message = 'Bu işlem için yetkiniz bulunmamaktadır.') {
  const set = new Set(allowed);
  return function globalRoleGate(req, res, next) {
    const user = req.user;
    const isSession = user && (user.is_service_session === true || user.role === 'service_session');
    if (!user || isSession || !set.has(user.role)) {
      return sendError(res, httpError(403, message, 'FORBIDDEN'));
    }
    return next();
  };
}

/**
 * Yetenek kapisi: requireHomeAccess'ten SONRA calisir; matristeki (role_matrix) etkin rol
 * yetenege sahip degilse 403. requireHomeAccess listesi yanlis kurulsa bile ikinci savunma hattidir.
 */
function requireCapability(capability) {
  return function capabilityGate(req, res, next) {
    if (!can(capability, req.homeAccess)) {
      return sendError(res, httpError(403, 'Bu işlem için yetkiniz yetersizdir.', 'FORBIDDEN'));
    }
    return next();
  };
}

module.exports = {
  sendError,
  handle,
  noStore,
  clientIp,
  actorOf,
  requireGlobalRoles,
  requireCapability,
  successResponse,
  httpError,
};
