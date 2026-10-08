'use strict';

// ==============================================================================
// AHBU Akilli Ev - Zamanli kural sahibinin yetkisi (saf fonksiyon)
// ==============================================================================
//
// Zamanlayici (scheduler.js) kurali CALISTIRMA aninda bu kurala gore denetler; kural servisi (kullanim-5) ayni kurali
// listede `creator_active` olarak gosterir ve yetkisi biten sahibin kuralini duzenleyen yetkili uyeye USTLENDIRIR.
// Dongusel bagimlilik olmasin diye utils altinda (scheduler.js ve scheduled_rules_service.js ikisi de buradan alir).

const AUTHORIZED_HOME_ROLES = new Set(['owner', 'resident', 'service_user']);
// Hesap durumu sutunu (users.account_status) opsiyoneldir; bilinen engelli degerler:
const BLOCKED_ACCOUNT_STATUSES = new Set([
  'suspended',
  'frozen',
  'disabled',
  'deleted',
  'locked',
  'banned',
  'inactive',
  'blocked',
]);

function toMs(v) {
  if (v === null || v === undefined) return null;
  if (v instanceof Date) {
    const t = v.getTime();
    return Number.isFinite(t) ? t : null;
  }
  if (typeof v === 'number') return Number.isFinite(v) ? v : null;
  const t = Date.parse(String(v));
  return Number.isFinite(t) ? t : null;
}

/**
 * Kural sahibi hala kural yonetmeye yetkili mi?
 * @param {{is_active?, account_status?, global_role?, home_role?, installer_expires_at?}|null} row
 */
function isCreatorAuthorized(row, nowMs = Date.now()) {
  if (!row) return false; // kullanici silinmis
  if (row.is_active === false) return false;
  const status = row.account_status ? String(row.account_status).toLowerCase() : null;
  if (status && BLOCKED_ACCOUNT_STATUSES.has(status)) return false;
  if (row.global_role === 'super_user') return true;
  if (!AUTHORIZED_HOME_ROLES.has(row.home_role)) return false;
  if (row.home_role === 'service_user' && row.installer_expires_at) {
    const exp = toMs(row.installer_expires_at);
    if (exp !== null && exp < nowMs) return false; // suresi dolmus gecici servis erisimi
  }
  return true;
}

module.exports = { isCreatorAuthorized, AUTHORIZED_HOME_ROLES, BLOCKED_ACCOUNT_STATUSES };
