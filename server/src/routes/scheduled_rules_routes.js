'use strict';

// ==============================================================================
// AHBU Akilli Ev - Zamanli kural uclari                              [CONTRACTS §1.5]
// ==============================================================================
//
//   GET    /homes/:homeId/scheduled-rules
//   POST   /homes/:homeId/scheduled-rules
//   PUT    /homes/:homeId/scheduled-rules/:ruleId
//   DELETE /homes/:homeId/scheduled-rules/:ruleId
//
// Baglama (server.js): app.use('/api/homes', r); app.use('/api/v1/homes', r)  (degismedi)
//
// Yetki (CONTRACTS §1.4): olustur/duzenle/sil/listele -> super_user, staff (home_users
// 'service_user'), owner, resident. MISAFIR ve SERVIS OTURUMU (PIN) ERISEMEZ. Her istekte
// `requireHomeAccess` uyelik + misafir suresi (GUEST_EXPIRED) + servis oturumu kapsamini dogrular;
// ek olarak burada "derinlemesine savunma" ile misafir/servis oturumu acikca reddedilir.
//
// Yanit: { success, message, data:{...} }. Gecis donemi icin eski istemcilerin okudugu ust duzey
// takma alanlar da eklenir: { rules } / { rule } ve hata govdesinde { error }.

const express = require('express');
const { isUuid, HttpError } = require('../utils/helpers');

// requireHomeAccess rol listesi. `service_session` ve `guest` KASITLI olarak yoktur.
// Tek dogruluk kaynagi auth_middleware.HOME_ROLE_SETS.RULES'tur (CONTRACTS §1.4); yoksa
// asagidaki yedek liste kullanilir (ayni kume).
const MANAGE_ROLES = Object.freeze(['owner', 'resident', 'service_user', 'super_user']);
const MAX_RULE_ID = 2147483647;

// server.js bu yollara baglar (degismedi).
const MOUNT_PATHS = Object.freeze(['/api/v1/homes', '/api/homes']);

function createRouter(deps = {}) {
  const auth = deps.auth || require('../middlewares/auth_middleware');
  const service = deps.service || require('../services/scheduled_rules_service');
  const rateLimitMod = deps.rateLimit || require('../middlewares/rate_limit');
  const makeLimiter = typeof rateLimitMod === 'function' ? rateLimitMod : rateLimitMod.rateLimit;
  const { authenticateToken, requireHomeAccess } = auth;
  const logger = deps.logger || console;
  const manageRoles = (auth.HOME_ROLE_SETS && auth.HOME_ROLE_SETS.RULES) || MANAGE_ROLES;

  const router = express.Router({ mergeParams: true });

  function userIdOf(req) {
    return req.user && (req.user.id || req.user.sub) ? String(req.user.id || req.user.sub) : null;
  }

  /** Etkin ev rolu (super uyeliksiz gecerse 'super_user'). */
  function homeRoleOf(req) {
    const a = req.homeAccess || {};
    if (a.is_super === true || (req.user && req.user.role === 'super_user' && !a.role)) return 'super_user';
    return a.role || null;
  }

  function fail(res, status, message, code, extra) {
    const body = { success: false, message, code, error: message };
    if (extra) Object.assign(body, extra);
    return res.status(status).json(body);
  }

  function sendError(res, err, ctx) {
    if (err instanceof HttpError && err.status < 500) {
      const extra = Array.isArray(err.errors) ? { errors: err.errors } : null;
      return fail(res, err.status, err.message, err.code || 'ERROR', extra);
    }
    // Veritabani kisitlari: ic ayrinti sizdirmadan anlamli kodlar
    if (err && err.code === '23503') return fail(res, 409, 'Kayıt başka bir kayıtla ilişkili veya değişmiş', 'CONFLICT');
    if (err && err.code === '23514') return fail(res, 400, 'Geçersiz değer', 'VALIDATION');
    // 5xx: ham mesaj istemciye DONMEZ; yalnizca log'a yazilir.
    logger.error(`[ScheduledRules] ${ctx} hatasi: ${err && err.message ? err.message : err}`);
    return fail(res, 500, 'Sunucu hatası. Lütfen daha sonra tekrar deneyin.', 'INTERNAL_ERROR');
  }

  // :homeId dogrulama + requireHomeAccess uyumlulugu (o `home_id` adini okur)
  function prepareHome(req, res, next) {
    const homeId = req.params.homeId;
    if (typeof homeId !== 'string' || !isUuid(homeId)) {
      return fail(res, 400, 'Geçersiz ev kimliği', 'VALIDATION');
    }
    req.params.home_id = homeId;
    req.scheduledHomeId = homeId.toLowerCase();
    return next();
  }

  // Derinlemesine savunma: misafir ve servis oturumu (PIN) kural yonetemez / goremez.
  function denyGuestAndServiceSession(req, res, next) {
    const globalRole = req.user && req.user.role;
    const homeRole = req.homeAccess && req.homeAccess.role;
    if (globalRole === 'service_session' || homeRole === 'service_session' || homeRole === 'guest') {
      return fail(res, 403, 'Bu işlem için yetkiniz yok', 'FORBIDDEN');
    }
    return next();
  }

  function parseRuleId(req, res, next) {
    const raw = req.params.ruleId;
    if (typeof raw !== 'string' || !/^\d{1,10}$/.test(raw) || Number(raw) > MAX_RULE_ID || Number(raw) < 1) {
      return fail(res, 404, 'Kural bulunamadı', 'NOT_FOUND');
    }
    req.ruleId = Number(raw);
    return next();
  }

  function requireJsonObject(req, res, next) {
    const b = req.body;
    if (b === null || typeof b !== 'object' || Array.isArray(b)) {
      return fail(res, 400, 'İstek gövdesi bir JSON nesnesi olmalı', 'VALIDATION');
    }
    return next();
  }

  const writeLimiter = makeLimiter({
    windowMs: 10 * 60 * 1000,
    max: 60,
    keyGenerator: (req) => `scheduled_rules:${userIdOf(req) || 'anon'}:${req.scheduledHomeId || ''}`,
    code: 'RATE_LIMITED',
  });

  const guard = [authenticateToken, prepareHome, requireHomeAccess([...manageRoles]), denyGuestAndServiceSession];

  // GET /homes/:homeId/scheduled-rules
  router.get('/:homeId/scheduled-rules', ...guard, async (req, res) => {
    try {
      const rules = await service.listRules(req.scheduledHomeId);
      return res.status(200).json({ success: true, message: 'Zamanlı kurallar listelendi', data: { rules }, rules });
    } catch (err) {
      return sendError(res, err, 'LIST');
    }
  });

  // POST /homes/:homeId/scheduled-rules
  router.post('/:homeId/scheduled-rules', ...guard, writeLimiter, requireJsonObject, async (req, res) => {
    try {
      const userId = userIdOf(req);
      if (!userId) return fail(res, 401, 'Oturum doğrulanamadı', 'INVALID_TOKEN');
      // kullanim-5: ev rolu servise (personelin tek sahipli evde kurdugu kural sahip adina kaydedilir)
      const rule = await service.createRule(req.scheduledHomeId, userId, req.body, { role: homeRoleOf(req), ip: req.ip || null });
      return res.status(201).json({ success: true, message: 'Zamanlı kural oluşturuldu', data: { rule }, rule });
    } catch (err) {
      return sendError(res, err, 'CREATE');
    }
  });

  // PUT /homes/:homeId/scheduled-rules/:ruleId
  router.put('/:homeId/scheduled-rules/:ruleId', ...guard, parseRuleId, writeLimiter, requireJsonObject, async (req, res) => {
    try {
      // kullanim-5: duzenleyen (yetkisi biten sahibin kuralini ustlenir)
      const rule = await service.updateRule(req.scheduledHomeId, req.ruleId, req.body, {
        userId: userIdOf(req),
        role: homeRoleOf(req),
        ip: req.ip || null,
      });
      return res.status(200).json({ success: true, message: 'Zamanlı kural güncellendi', data: { rule }, rule });
    } catch (err) {
      return sendError(res, err, 'UPDATE');
    }
  });

  // DELETE /homes/:homeId/scheduled-rules/:ruleId
  router.delete('/:homeId/scheduled-rules/:ruleId', ...guard, parseRuleId, writeLimiter, async (req, res) => {
    try {
      const result = await service.deleteRule(req.scheduledHomeId, req.ruleId);
      return res.status(200).json({ success: true, message: 'Zamanlı kural silindi', data: result });
    } catch (err) {
      return sendError(res, err, 'DELETE');
    }
  });

  return router;
}

// Varsayilan yonlendirici ILK ISTEKTE olusturulur: modul yuklenirken veritabani/ortam
// bagimliliklari (auth_middleware -> db) cozulmez (testler ve sirali baslatma icin).
let defaultRouter = null;
function lazyRouter(req, res, next) {
  if (!defaultRouter) defaultRouter = createRouter();
  return defaultRouter(req, res, next);
}

module.exports = lazyRouter;
module.exports.createRouter = createRouter;
module.exports.MANAGE_ROLES = MANAGE_ROLES;
module.exports.mountPaths = MOUNT_PATHS; // server.js: app.use(path, router)
