'use strict';

// ==============================================================================
// AHBU Akilli Ev - Kimlik dogrulama ve ev bazli yetkilendirme middleware'leri
// ==============================================================================
//
// Sozlesme: docs/CONTRACTS.md §1.1-§1.4
//
// authenticateToken
//   - Bearer JWT (HS256 + iss) dogrulanir.
//   - Kullanici token'i: `sub` (UUID) + `tv` (token_version) zorunlu. Kullanici satiri
//     (aktiflik, hesap durumu, token_version, GUNCEL global rol) kisa onbellekle (<= 30 sn)
//     DB'den okunur. tv uyusmazligi / pasif hesap -> 401 INVALID_TOKEN.
//   - Suresi dolmus token -> 401 TOKEN_EXPIRED (servis oturumunda SERVICE_SESSION_EXPIRED).
//   - Servis oturumu token'i (role:'service_session', home_id, sid): `service_sessions`
//     satiri iptal edilmemis ve suresi dolmamis olmalidir. Bu token YALNIZCA kendi evini
//     hedefleyen isteklerde kabul edilir (yol segmenti / govde / sorgu home_id'si), aksi
//     halde 403 FORBIDDEN. Kullanici satiri yoktur: req.user.id === null.
//   - Basarida req.user = { id, email, full_name, role, token_version, is_service_session,
//     home_id?, sid?, technician_name? }.
//
// requireHomeAccess(allowedRoles)
//   allowedRoles icinde kullanilabilecek degerler:
//     'owner' | 'resident' | 'guest' | 'service_user'   -> home_users uyeligi (ev bazli rol)
//     'service_session'                                 -> PIN oturumu, yalnizca kendi home_id'si
//     'super_user'                                      -> global super kullanici; YALNIZCA listede
//                                                          ACIKCA varsa uyeliksiz gecer.
//   Kurallar:
//     - home_id UUID olmali (parseInt YOK). Kaynaklar: params.homeId|home_id, body.home_id|homeId,
//       query.home_id|homeId. Birden fazla kaynak farkli deger tasirsa 400 VALIDATION.
//     - 'service_user' uyeligi yalnizca global rolu service_user/super_user olan personel icin
//       gecerlidir (staff = home_users kaydi olan kalici servis personeli).
//     - Misafir: valid_from <= simdi <= valid_until; disindaysa 403 GUEST_EXPIRED
//       (valid_until bos olan misafir de suresi dolmus sayilir - fail-closed).
//     - Basarida req.homeAccess = { home_id, role, is_super, is_service_session, valid_until }.
//       role: ev bazli rol | 'super_user' | 'service_session'. is_super yalnizca super_user
//       istisnasi ile girildiyse true'dur.
//
// requireHomeMember      = requireHomeAccess(ALL_HOME_ACCESS_ROLES)
// requireServiceManager  = global rol service_user | super_user (servis oturumu HARIC)
// requireSuperUser       = global rol super_user (servis oturumu HARIC)
// rejectServiceSession   = ev kapsamli olmayan uclarda servis oturumu token'ini reddeder

const db = require('../db');
const { errorResponse, isUuid } = require('../utils/helpers');
const { verifyToken, JwtConfigError } = require('./jwt_config');

// ---------------------------------------------------------------------------
// Rol kumeleri (CONTRACTS §1.4 matrisi). Route dosyalari bunlari kullanabilir.
// ---------------------------------------------------------------------------
const HOME_MEMBER_ROLES = Object.freeze(['owner', 'resident', 'guest', 'service_user']);
const PSEUDO_ROLES = Object.freeze(['service_session', 'super_user']);
const KNOWN_ACCESS_ROLES = new Set([...HOME_MEMBER_ROLES, ...PSEUDO_ROLES]);
const STAFF_GLOBAL_ROLES = new Set(['service_user', 'super_user']);

const ALL_HOME_ACCESS_ROLES = Object.freeze([
  'super_user', 'service_user', 'service_session', 'owner', 'resident', 'guest',
]);

const HOME_ROLE_SETS = Object.freeze({
  VIEW: ALL_HOME_ACCESS_ROLES,
  CONTROL: ALL_HOME_ACCESS_ROLES,
  GROUP_COMMAND: Object.freeze(['super_user', 'service_user', 'service_session', 'owner', 'resident']),
  CHILD_LOCK: Object.freeze(['super_user', 'service_user', 'service_session', 'owner', 'resident']),
  CALIBRATE: Object.freeze(['super_user', 'service_user', 'service_session', 'owner']),
  RULES: Object.freeze(['super_user', 'service_user', 'owner', 'resident']),
  MEMBERS: Object.freeze(['super_user', 'owner']),
  TRANSFER: Object.freeze(['owner']),
  SERVICE_PIN: Object.freeze(['owner']),
  COMMISSION: Object.freeze(['super_user', 'service_user', 'service_session']),
  REPLACE_BOARD: Object.freeze(['super_user', 'service_user', 'service_session', 'owner']),
  LOCAL_KEY: Object.freeze(['service_user', 'service_session', 'owner', 'resident']),
});

// ---------------------------------------------------------------------------
// Durum yukleyiciler + kisa onbellek (<= 30 sn). Test/DI icin degistirilebilir.
// ---------------------------------------------------------------------------
const MAX_CACHE_TTL_MS = 30 * 1000;

async function defaultLoadUser(userId) {
  const r = await db.query(
    `SELECT id, email, full_name, role, is_active, account_status, token_version
       FROM users
      WHERE id = $1`,
    [userId]
  );
  return r.rows[0] || null;
}

async function defaultLoadServiceSession(sid) {
  const r = await db.query(
    `SELECT id, home_id, technician_name, expires_at, revoked_at
       FROM service_sessions
      WHERE id = $1`,
    [sid]
  );
  return r.rows[0] || null;
}

const config = {
  loadUser: defaultLoadUser,
  loadServiceSession: defaultLoadServiceSession,
  cacheTtlMs: (() => {
    const v = Number(process.env.AUTH_CACHE_TTL_MS);
    return Number.isFinite(v) && v >= 0 ? Math.min(v, MAX_CACHE_TTL_MS) : MAX_CACHE_TTL_MS;
  })(),
  now: () => Date.now(),
};

const userCache = new Map(); // userId -> { row, at }
const sessionCache = new Map(); // sid -> { row, at }
const CACHE_MAX_ENTRIES = 10000;

function cacheGet(cache, key) {
  if (config.cacheTtlMs <= 0) return undefined;
  const hit = cache.get(key);
  if (!hit) return undefined;
  if (config.now() - hit.at > config.cacheTtlMs) {
    cache.delete(key);
    return undefined;
  }
  return hit.row;
}

function cacheSet(cache, key, row) {
  if (config.cacheTtlMs <= 0) return;
  if (cache.size >= CACHE_MAX_ENTRIES) {
    const oldest = cache.keys().next().value;
    if (oldest !== undefined) cache.delete(oldest);
  }
  cache.set(key, { row, at: config.now() });
}

async function getUserState(userId, { fresh = false } = {}) {
  if (!fresh) {
    const cached = cacheGet(userCache, userId);
    if (cached !== undefined) return cached;
  }
  const row = await config.loadUser(userId);
  cacheSet(userCache, userId, row);
  return row;
}

async function getServiceSession(sid, { fresh = false } = {}) {
  if (!fresh) {
    const cached = cacheGet(sessionCache, sid);
    if (cached !== undefined) return cached;
  }
  const row = await config.loadServiceSession(sid);
  cacheSet(sessionCache, sid, row);
  return row;
}

/** Ayni surecteki onbellegi aninda dusurur (sifre degisimi, dondurma, rol degisimi...). */
function invalidateUserAuthCache(userId) {
  if (userId === undefined || userId === null) return;
  userCache.delete(String(userId));
}

function invalidateServiceSessionCache(sid) {
  if (sid === undefined || sid === null) {
    sessionCache.clear();
    return;
  }
  sessionCache.delete(String(sid));
}

function clearAuthCaches() {
  userCache.clear();
  sessionCache.clear();
}

/**
 * Test / bagimlilik enjeksiyonu. Uretimde cagrilmasi gerekmez.
 * @param {{loadUser?:Function, loadServiceSession?:Function, cacheTtlMs?:number, now?:Function}} opts
 */
function configureAuthMiddleware(opts = {}) {
  if (typeof opts.loadUser === 'function') config.loadUser = opts.loadUser;
  if (typeof opts.loadServiceSession === 'function') config.loadServiceSession = opts.loadServiceSession;
  if (Number.isFinite(opts.cacheTtlMs) && opts.cacheTtlMs >= 0) {
    config.cacheTtlMs = Math.min(opts.cacheTtlMs, MAX_CACHE_TTL_MS);
  }
  if (typeof opts.now === 'function') config.now = opts.now;
  clearAuthCaches();
}

function resetAuthMiddlewareConfig() {
  config.loadUser = defaultLoadUser;
  config.loadServiceSession = defaultLoadServiceSession;
  config.cacheTtlMs = MAX_CACHE_TTL_MS;
  config.now = () => Date.now();
  clearAuthCaches();
}

// ---------------------------------------------------------------------------
// Yardimcilar
// ---------------------------------------------------------------------------
function extractBearer(req) {
  const header = req.headers && (req.headers.authorization || req.headers.Authorization);
  if (!header || typeof header !== 'string') return null;
  const m = header.match(/^Bearer\s+([A-Za-z0-9\-_]+\.[A-Za-z0-9\-_]+\.[A-Za-z0-9\-_]+)\s*$/i);
  return m ? m[1] : null;
}

function deny401(res, code, message) {
  return errorResponse(res, message, 401, null, code);
}

function deny403(res, message = 'Bu işlem için yetkiniz bulunmamaktadır.', code = 'FORBIDDEN') {
  return errorResponse(res, message, 403, null, code);
}

function escapeRegExp(s) {
  return String(s).replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

// Servis oturumu token'inin ev referansi tasimadan kullanilabilecegi uclar.
const SERVICE_SESSION_GLOBAL_ALLOW = [
  { method: 'GET', path: /^\/api(?:\/v1)?\/homes\/?$/i },
  { method: 'GET', path: /^\/api(?:\/v1)?\/auth\/me\/?$/i },
  { method: 'POST', path: /^\/api(?:\/v1)?\/auth\/logout\/?$/i },
];

/**
 * Servis oturumu isteginin kendi evini hedefleyip hedeflemedigini yapisal olarak denetler.
 * (Derinlemesine savunma: route'ta requireHomeAccess unutulsa bile token baska bir eve
 * veya ev kapsami olmayan bir uca ulasamaz.)
 */
function requestTargetsHome(req, homeId) {
  const h = String(homeId || '').toLowerCase();
  if (!isUuid(h)) return false;
  const path = String(req.originalUrl || req.url || '').split('?')[0];
  const method = String(req.method || 'GET').toUpperCase();

  const values = [];
  if (req.body && typeof req.body === 'object') values.push(req.body.home_id, req.body.homeId);
  if (req.query && typeof req.query === 'object') values.push(req.query.home_id, req.query.homeId);
  const referenced = values.filter((v) => v !== undefined && v !== null && v !== '');
  // Govde/sorgu baska bir eve isaret ediyorsa reddet.
  if (referenced.some((v) => String(v).toLowerCase() !== h)) return false;

  const segment = new RegExp(`(?:^|/)${escapeRegExp(h)}(?:/|$)`, 'i');
  if (segment.test(path)) return true;
  if (referenced.length > 0) return true;
  return SERVICE_SESSION_GLOBAL_ALLOW.some((rule) => rule.method === method && rule.path.test(path));
}

// ---------------------------------------------------------------------------
// authenticateToken
// ---------------------------------------------------------------------------
async function authenticateToken(req, res, next) {
  const token = extractBearer(req);
  if (!token) {
    return deny401(res, 'INVALID_TOKEN', 'Yetkilendirme belirteci (token) sağlanmadı.');
  }

  let verified;
  try {
    verified = verifyToken(token, { nowMs: config.now() });
  } catch (err) {
    if (err instanceof JwtConfigError) {
      console.error('[AUTH] JWT yapilandirma hatasi:', err.message);
      return errorResponse(res, 'Sunucu yapılandırma hatası.', 500, null, 'INTERNAL');
    }
    return deny401(res, 'INVALID_TOKEN', 'Geçersiz yetkilendirme belirteci.');
  }

  const { payload, expired } = verified;
  const isServiceSession = payload.role === 'service_session';

  if (expired) {
    if (isServiceSession) {
      return deny401(res, 'SERVICE_SESSION_EXPIRED', 'Servis oturumunuzun süresi doldu.');
    }
    return deny401(res, 'TOKEN_EXPIRED', 'Oturum süreniz doldu.');
  }

  try {
    if (isServiceSession) {
      const sid = payload.sid;
      const homeId = typeof payload.home_id === 'string' ? payload.home_id.toLowerCase() : null;
      if (!isUuid(sid) || !isUuid(homeId)) {
        return deny401(res, 'INVALID_TOKEN', 'Geçersiz servis oturumu belirteci.');
      }
      const session = await getServiceSession(sid);
      const nowMs = config.now();
      if (
        !session ||
        session.revoked_at ||
        !session.expires_at ||
        new Date(session.expires_at).getTime() <= nowMs ||
        String(session.home_id).toLowerCase() !== homeId
      ) {
        return deny401(res, 'SERVICE_SESSION_EXPIRED', 'Servis oturumu sona ermiş veya iptal edilmiş.');
      }
      if (!requestTargetsHome(req, homeId)) {
        return deny403(res, 'Servis oturumu yalnızca ilgili daire için geçerlidir.');
      }
      req.user = {
        id: null,
        role: 'service_session',
        is_service_session: true,
        home_id: homeId,
        sid,
        technician_name: session.technician_name || null,
        full_name: session.technician_name || 'Yetkili Servis',
        email: null,
        session_expires_at: session.expires_at,
      };
      return next();
    }

    const userId = typeof payload.sub === 'string' ? payload.sub : null;
    if (!isUuid(userId)) {
      // Eski bicim token (sub/tv yok): istemci yenileme denesin.
      if (payload.id && isUuid(String(payload.id))) {
        return deny401(res, 'TOKEN_EXPIRED', 'Oturum yenilenmeli.');
      }
      return deny401(res, 'INVALID_TOKEN', 'Geçersiz yetkilendirme belirteci.');
    }
    if (!Number.isInteger(payload.tv)) {
      return deny401(res, 'TOKEN_EXPIRED', 'Oturum yenilenmeli.');
    }

    let user = await getUserState(userId);
    // Coklu instance: onbellekteki tv eskiyse (yeni giris), bir kez taze oku.
    if (user && Number(user.token_version) !== payload.tv) {
      user = await getUserState(userId, { fresh: true });
    }
    if (!user) {
      return deny401(res, 'INVALID_TOKEN', 'Oturum geçersiz.');
    }
    if (user.is_active === false || (user.account_status && user.account_status !== 'active')) {
      return deny401(res, 'INVALID_TOKEN', 'Hesabınız aktif değil.');
    }
    if (Number(user.token_version) !== payload.tv) {
      return deny401(res, 'INVALID_TOKEN', 'Oturumunuz sonlandırıldı. Lütfen tekrar giriş yapın.');
    }

    req.user = {
      id: String(user.id),
      email: user.email || null,
      full_name: user.full_name || null,
      role: user.role || 'user',
      token_version: Number(user.token_version),
      is_service_session: false,
    };
    return next();
  } catch (err) {
    console.error('[AUTH] Kimlik dogrulama hatasi:', err && err.message);
    return errorResponse(res, 'Yetki doğrulama sırasında sunucu hatası oluştu.', 500, null, 'INTERNAL');
  }
}

// ---------------------------------------------------------------------------
// requireHomeAccess
// ---------------------------------------------------------------------------
function pickHomeId(req) {
  const candidates = [];
  const push = (v) => {
    if (v !== undefined && v !== null && v !== '') candidates.push(String(v).trim());
  };
  if (req.params) {
    push(req.params.homeId);
    push(req.params.home_id);
  }
  if (req.body && typeof req.body === 'object') {
    push(req.body.home_id);
    push(req.body.homeId);
  }
  if (req.query && typeof req.query === 'object') {
    push(req.query.home_id);
    push(req.query.homeId);
  }
  if (candidates.length === 0) return { value: null, conflict: false };
  const first = candidates[0].toLowerCase();
  const conflict = candidates.some((c) => c.toLowerCase() !== first);
  return { value: candidates[0], conflict };
}

function guestWindowError(membership, nowMs) {
  const from = membership.valid_from ? new Date(membership.valid_from).getTime() : null;
  const until = membership.valid_until ? new Date(membership.valid_until).getTime() : null;
  if (from !== null && Number.isFinite(from) && nowMs < from) {
    return 'Misafir erişim süreniz henüz başlamamıştır.';
  }
  if (until === null || !Number.isFinite(until) || nowMs > until) {
    return 'Misafir erişim süreniz sona ermiştir. Ev sahibinden yeni erişim talep ediniz.';
  }
  return null;
}

function requireHomeAccess(allowedRoles = ALL_HOME_ACCESS_ROLES) {
  if (!Array.isArray(allowedRoles) || allowedRoles.length === 0) {
    throw new TypeError('requireHomeAccess: en az bir rol içeren dizi zorunludur.');
  }
  const unknown = allowedRoles.filter((r) => !KNOWN_ACCESS_ROLES.has(r));
  if (unknown.length > 0) {
    throw new TypeError(`requireHomeAccess: bilinmeyen rol(ler): ${unknown.join(', ')}`);
  }
  const allowed = new Set(allowedRoles);

  return async function homeAccessMiddleware(req, res, next) {
    try {
      if (!req.user) {
        return deny401(res, 'INVALID_TOKEN', 'Kimlik doğrulaması gerekli.');
      }

      const picked = pickHomeId(req);
      if (!picked.value) {
        return errorResponse(res, 'Daire kimliği (home_id) zorunludur.', 400, null, 'VALIDATION');
      }
      if (picked.conflict) {
        return errorResponse(res, 'İstekteki daire kimlikleri birbiriyle uyuşmuyor.', 400, null, 'VALIDATION');
      }
      if (!isUuid(picked.value)) {
        return errorResponse(res, 'Geçersiz daire kimliği (home_id).', 400, null, 'VALIDATION');
      }
      const homeId = picked.value.toLowerCase();

      // 1) Servis oturumu: yalnizca kendi evi ve yalnizca acikca izin verilen uclar.
      if (req.user.is_service_session || req.user.role === 'service_session') {
        if (!allowed.has('service_session')) {
          return deny403(res, 'Servis oturumu bu işlem için yetkili değildir.');
        }
        if (String(req.user.home_id || '').toLowerCase() !== homeId) {
          return deny403(res, 'Servis oturumu yalnızca ilgili daire için geçerlidir.');
        }
        req.homeAccess = {
          home_id: homeId,
          role: 'service_session',
          is_super: false,
          is_service_session: true,
          valid_until: req.user.session_expires_at || null,
        };
        return next();
      }

      // 2) Super kullanici: YALNIZCA listede acikca varsa uyeliksiz gecer.
      if (req.user.role === 'super_user' && allowed.has('super_user')) {
        const homeRes = await db.query('SELECT id FROM homes WHERE id = $1', [homeId]);
        if (homeRes.rows.length === 0) {
          return errorResponse(res, 'Daire bulunamadı.', 404, null, 'NOT_FOUND');
        }
        req.homeAccess = {
          home_id: homeId,
          role: 'super_user',
          is_super: true,
          is_service_session: false,
          valid_until: null,
        };
        return next();
      }

      if (!isUuid(req.user.id)) {
        return deny403(res);
      }

      // 3) Ev uyeligi (home_users) zorunlu.
      const memberRes = await db.query(
        `SELECT role, valid_from, valid_until, installer_expires_at
           FROM home_users
          WHERE home_id = $1 AND user_id = $2`,
        [homeId, req.user.id]
      );
      if (memberRes.rows.length === 0) {
        return deny403(res, 'Bu daireye erişim yetkiniz bulunmamaktadır.');
      }

      const membership = memberRes.rows[0];
      const role = membership.role;
      const nowMs = config.now();

      if (!HOME_MEMBER_ROLES.includes(role)) {
        return deny403(res, 'Bu daireye erişim yetkiniz bulunmamaktadır.');
      }

      if (role === 'guest') {
        const msg = guestWindowError(membership, nowMs);
        if (msg) return deny403(res, msg, 'GUEST_EXPIRED');
      }

      if (role === 'service_user') {
        // Ev bazli servis rolu yalnizca kalici servis personeli (global rol) icin gecerlidir.
        if (!STAFF_GLOBAL_ROLES.has(req.user.role)) {
          return deny403(res, 'Bu daireye erişim yetkiniz bulunmamaktadır.');
        }
        // Eski gecici (PIN) servis kayitlari: suresi dolduysa erisim yok.
        if (membership.installer_expires_at && new Date(membership.installer_expires_at).getTime() <= nowMs) {
          return deny403(res, 'Servis erişim süreniz dolmuştur.');
        }
      }

      if (!allowed.has(role)) {
        return deny403(res, 'Bu işlem için yetkiniz yetersizdir.');
      }

      req.homeAccess = {
        home_id: homeId,
        role,
        is_super: false,
        is_service_session: false,
        valid_until: role === 'guest' ? membership.valid_until : null,
      };
      return next();
    } catch (err) {
      console.error('[AUTH] Ev yetki dogrulama hatasi:', err && err.message);
      return errorResponse(res, 'Yetki doğrulama sırasında sunucu hatası oluştu.', 500, null, 'INTERNAL');
    }
  };
}

const requireHomeMember = requireHomeAccess(ALL_HOME_ACCESS_ROLES);

// ---------------------------------------------------------------------------
// Global rol kapilari
// ---------------------------------------------------------------------------
function requireSuperUser(req, res, next) {
  if (!req.user) return deny401(res, 'INVALID_TOKEN', 'Kimlik doğrulaması gerekli.');
  if (req.user.is_service_session || req.user.role !== 'super_user') {
    return deny403(res, 'Bu işlem için Süper Yönetici yetkisi gereklidir.');
  }
  return next();
}

function requireServiceManager(req, res, next) {
  if (!req.user) return deny401(res, 'INVALID_TOKEN', 'Kimlik doğrulaması gerekli.');
  if (req.user.is_service_session || !STAFF_GLOBAL_ROLES.has(req.user.role)) {
    return deny403(res, 'Bu işlem için Servis Sorumlusu veya Süper Yönetici yetkisi gereklidir.');
  }
  return next();
}

function rejectServiceSession(req, res, next) {
  if (req.user && (req.user.is_service_session || req.user.role === 'service_session')) {
    return deny403(res, 'Servis oturumu bu işlem için yetkili değildir.');
  }
  return next();
}

module.exports = {
  authenticateToken,
  requireHomeAccess,
  requireHomeMember,
  requireSuperUser,
  requireServiceManager,
  rejectServiceSession,
  // Rol kumeleri
  HOME_MEMBER_ROLES,
  ALL_HOME_ACCESS_ROLES,
  HOME_ROLE_SETS,
  // Onbellek yonetimi
  invalidateUserAuthCache,
  invalidateServiceSessionCache,
  clearAuthCaches,
  // Test / DI
  configureAuthMiddleware,
  resetAuthMiddlewareConfig,
  _internals: { requestTargetsHome, pickHomeId, extractBearer },
};
