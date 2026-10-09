'use strict';

// ==============================================================================
// AHBU Akilli Ev - Kuyruklanmis istegin sahibi hala yetkili mi? (ortak denetim)
// ==============================================================================
//
// Kullananlar: services/safety_cfg_sync.js (cevrimdisi panoya yapilandirma yamasi kuyrugu, F2.D.2 + guvenlik-5) ve
// services/alarm_service.js (cevrimdisi panoya kuyruklanan alarm onayi, sko-1 / sozlesme C11).
// SAF denetim + sorgu metinleri: G/C yalniz cagiranin verdigi `q` (db.query ya da transaction istemcisi) ile.
//   - Kullanici (by): hesap var, aktif, engelli durumda degil; global super_user ya da evde (suresi dolmamis) uyelik.
//     `roles` verilirse uyelik rolu bu kumede olmali; ev bazli 'service_user' yalniz kalici personelde (global rol
//     service_user/super_user) gecerlidir (auth_middleware.requireHomeAccess ile ayni kural).
//   - Servis (PIN) oturumu (sid): oturum satiri var, iptal edilmemis, suresi dolmamis.
//   - Ikisi de yok (eski kayit): kaydin zamanindan sonra evde iptal edilen bir servis oturumu varsa gecersiz.

const SQL = Object.freeze({
  // Ogenin sahibinin eve erisimi suruyor mu (member: suresi dolmamis uyelik var; home_role: o uyeligin rolu)
  access:
    "SELECT u.id, u.is_active, to_jsonb(u) ->> 'account_status' AS account_status, u.role AS global_role, " +
    'EXISTS (SELECT 1 FROM home_users hu WHERE hu.user_id = u.id AND hu.home_id = $2 ' +
    'AND (hu.installer_expires_at IS NULL OR hu.installer_expires_at > CURRENT_TIMESTAMP)) AS member, ' +
    '(SELECT hu.role FROM home_users hu WHERE hu.user_id = u.id AND hu.home_id = $2 ' +
    'AND (hu.installer_expires_at IS NULL OR hu.installer_expires_at > CURRENT_TIMESTAMP) LIMIT 1) AS home_role ' +
    'FROM users u WHERE u.id = $1',
  sessionById: 'SELECT revoked_at, expires_at FROM service_sessions WHERE id = $1 AND home_id = $2',
  // sid tasimayan ESKI kayit: kaydin zamanindan sonra evde iptal edilen bir servis oturumu varsa gecersiz
  sessionRevokedSince:
    'SELECT EXISTS (SELECT 1 FROM service_sessions WHERE home_id = $1 AND revoked_at IS NOT NULL AND revoked_at >= $2::timestamptz) AS revoked',
});

const BLOCKED_STATUSES = Object.freeze(['deleted', 'suspended', 'frozen', 'disabled', 'banned', 'blocked', 'inactive', 'locked']);
const STAFF_GLOBAL_ROLES = Object.freeze(['service_user', 'super_user']);
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/**
 * SQL.access satirina gore kullanici yetkili mi? (satir yok = hesap silinmis)
 * @param {object|null} u
 * @param {{roles?: ReadonlyArray<string>|null}} [opts] verilirse uyelik rolu bu kumede olmali
 */
function userAllowed(u, { roles = null } = {}) {
  if (!u || u.is_active === false) return false;
  if (u.account_status && BLOCKED_STATUSES.includes(String(u.account_status).toLowerCase())) return false;
  if (u.global_role === 'super_user') return true;
  if (u.member !== true) return false;
  if (!roles) return true;
  if (!roles.includes(u.home_role)) return false;
  return u.home_role !== 'service_user' || STAFF_GLOBAL_ROLES.includes(u.global_role);
}

async function userAccessOk(q, homeId, userId, opts) {
  const r = await q(SQL.access, [userId, homeId]);
  return userAllowed((r && r.rows && r.rows[0]) || null, opts);
}

/**
 * Servis (PIN) oturumunun kaydi hala gecerli mi? sid varsa oturum satiri (yok / iptal / suresi dolmus -> gecersiz);
 * sid yoksa (eski kayit) `at`tan sonra evde iptal edilen bir servis oturumu varsa gecersiz.
 */
async function sessionOk(q, homeId, { sid = null, at }, nowMs) {
  if (sid !== undefined && sid !== null) {
    if (typeof sid !== 'string' || !UUID_RE.test(sid)) return false;
    const r = await q(SQL.sessionById, [sid, homeId]);
    const s = r && r.rows && r.rows[0];
    if (!s || s.revoked_at) return false;
    const exp = s.expires_at ? new Date(s.expires_at).getTime() : NaN;
    return Number.isFinite(exp) && exp > nowMs;
  }
  const r = await q(SQL.sessionRevokedSince, [homeId, at]);
  return !(r && r.rows && r.rows[0] && r.rows[0].revoked === true);
}

module.exports = { SQL, BLOCKED_STATUSES, userAllowed, userAccessOk, sessionOk };
