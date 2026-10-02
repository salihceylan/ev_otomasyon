'use strict';

// ==============================================================================
// AHBU Akilli Ev - Aile daveti, ev uyeleri ve uye cikarma (WP-A: A9)
// ==============================================================================
//
//  - Davet rolu beyaz listesi: 'resident' | 'guest'  ('owner' YALNIZCA devirle; eski 'member' -> 'resident').
//  - Kod: "AHBU-" + 10 karakter (generateCode, crypto.randomInt). DB'de YALNIZCA SHA-256 ozeti.
//  - Katilim: GERCEK transaction (db.withTransaction) + davet satiri FOR UPDATE + atomik
//    `UPDATE ... WHERE is_used = FALSE ... RETURNING` ile tek kullanim.
//  - Misafir: valid_from < valid_until, sure en cok 72 saat.
//  - Uye listesi: suresi dolmus misafir goremez (requireHomeAccess -> GUEST_EXPIRED);
//    misafire iletisim bilgisi (e-posta/telefon) gosterilmez.
//  - Uye cikarma: ev sahibi baska bir ev sahibini, super kullanici son ev sahibini cikaramaz;
//    cikarilan uyenin bu evdeki MQTT kimlikleri iptal edilir (WP-B revokeUserAccess).
//  - Hatalar HttpError (400/403/404/409/410).

const db = require('../db');
const { HttpError, generateCode, sha256Hex, isUuid } = require('../utils/helpers');

const CODE_PREFIX = 'AHBU-';
const QR_PREFIX = 'AHBU-INVITE:';
const CODE_LENGTH = 10;
const RESIDENT_INVITE_TTL_MS = 24 * 60 * 60 * 1000;
const GUEST_MAX_DURATION_MS = 72 * 60 * 60 * 1000;
const GUEST_DEFAULT_HOURS = 8;
const GUEST_MAX_START_AHEAD_MS = 30 * 24 * 60 * 60 * 1000;
const GUEST_START_GRACE_MS = 5 * 60 * 1000;
const MAX_ACTIVE_INVITATIONS = 20;

/** WP-B'nin MQTT kimlik servisi (dosya henuz yoksa null; testte enjekte edilebilir). */
let mqttCredentialOverride;
function getMqttCredentialService() {
  if (mqttCredentialOverride !== undefined) return mqttCredentialOverride;
  try {
    return require('./mqtt_credential_service');
  } catch (err) {
    if (err && err.code === 'MODULE_NOT_FOUND' && /mqtt_credential_service/.test(String(err.message))) return null;
    throw err;
  }
}

async function kickAfterCommit(usernames) {
  const svc = getMqttCredentialService();
  if (!svc || typeof svc.kickUsernames !== 'function' || !usernames || usernames.length === 0) return null;
  try {
    return await svc.kickUsernames(usernames);
  } catch (err) {
    console.warn('[INVITATION] MQTT baglanti atma basarisiz:', err && err.message);
    return null;
  }
}

function normalizeRole(role) {
  const r = typeof role === 'string' ? role.trim().toLowerCase() : 'resident';
  if (r === 'resident' || r === 'member' || r === '') return 'resident';
  if (r === 'guest') return 'guest';
  return null;
}

/** Kullanici girisini "AHBU-XXXXXXXXXX" bicimine getirir; gecersizse null. */
function normalizeInviteCode(input) {
  if (typeof input !== 'string' && typeof input !== 'number') return null;
  let s = String(input).trim().toUpperCase().replace(/\s+/g, '');
  if (s.startsWith(QR_PREFIX)) s = s.slice(QR_PREFIX.length);
  if (!s.startsWith(CODE_PREFIX)) s = CODE_PREFIX + s;
  return new RegExp(`^${CODE_PREFIX}[A-Z0-9]{${CODE_LENGTH}}$`).test(s) ? s : null;
}

function hashInviteCode(code) {
  return sha256Hex(code);
}

function parseDate(value, field) {
  if (value === undefined || value === null || value === '') return null;
  const d = new Date(value);
  if (Number.isNaN(d.getTime())) {
    throw new HttpError(400, `Geçersiz tarih: ${field}.`, 'VALIDATION');
  }
  return d;
}

function cleanGuestName(value) {
  if (typeof value !== 'string') return null;
  // eslint-disable-next-line no-control-regex
  const s = value.replace(/[\u0000-\u001f\u007f]/g, ' ').replace(/\s+/g, ' ').trim();
  return s ? s.slice(0, 100) : null;
}

function memberAccessState(row, nowMs) {
  if (row.role === 'service_user') {
    const end = row.installer_expires_at ? new Date(row.installer_expires_at).getTime() : null;
    return end !== null && nowMs >= end ? 'expired' : 'active';
  }
  if (row.role !== 'guest') return 'active';
  const from = row.valid_from ? new Date(row.valid_from).getTime() : null;
  const until = row.valid_until ? new Date(row.valid_until).getTime() : null;
  if (from !== null && nowMs < from) return 'not_started';
  if (until === null || nowMs > until) return 'expired';
  return 'active';
}

class InvitationService {
  /** Test icin MQTT kimlik servisini enjekte eder (null = yok). undefined ile sifirlanir. */
  static setMqttCredentialService(svc) {
    mqttCredentialOverride = svc;
  }

  /**
   * Davet kodu uretir. Yetki route katmaninda (requireHomeAccess MEMBERS: owner / super_user).
   * @param {string} homeId
   * @param {{userId:string}} actor
   * @param {string} role 'resident' | 'guest'
   * @param {{durationHours?:number, validFrom?:string, validUntil?:string, guestName?:string}} options
   */
  static async createInvitation(homeId, actor, role = 'resident', options = {}) {
    const actorId = actor && typeof actor === 'object' ? actor.userId : actor;
    if (!isUuid(String(homeId || '')) || !isUuid(String(actorId || ''))) {
      throw new HttpError(400, 'Geçersiz istek.', 'VALIDATION');
    }
    const cleanRole = normalizeRole(role);
    if (!cleanRole) {
      throw new HttpError(400, 'Davet yalnızca aile bireyi (resident) veya misafir (guest) için üretilebilir. Ev sahipliği yalnızca devirle aktarılır.', 'VALIDATION');
    }

    const nowMs = Date.now();
    let guestValidFrom = null;
    let guestValidUntil = null;
    let expiresAt;

    if (cleanRole === 'guest') {
      const from = parseDate(options.validFrom, 'valid_from') || new Date(nowMs);
      let until = parseDate(options.validUntil, 'valid_until');
      if (!until) {
        const hoursRaw = options.durationHours === undefined || options.durationHours === null || options.durationHours === ''
          ? GUEST_DEFAULT_HOURS
          : Number(options.durationHours);
        if (!Number.isInteger(hoursRaw) || hoursRaw < 1 || hoursRaw > 72) {
          throw new HttpError(400, 'Misafir süresi 1 ile 72 saat arasında bir tam sayı olmalıdır.', 'VALIDATION');
        }
        until = new Date(from.getTime() + hoursRaw * 60 * 60 * 1000);
      }
      if (from.getTime() >= until.getTime()) {
        throw new HttpError(400, 'Misafir başlangıç zamanı bitişten önce olmalıdır.', 'VALIDATION');
      }
      if (until.getTime() - from.getTime() > GUEST_MAX_DURATION_MS) {
        throw new HttpError(400, 'Misafir erişimi en fazla 72 saat olabilir.', 'VALIDATION');
      }
      if (from.getTime() < nowMs - GUEST_START_GRACE_MS) {
        throw new HttpError(400, 'Misafir başlangıç zamanı geçmişte olamaz.', 'VALIDATION');
      }
      if (from.getTime() > nowMs + GUEST_MAX_START_AHEAD_MS) {
        throw new HttpError(400, 'Misafir başlangıç zamanı en fazla 30 gün ilerisi olabilir.', 'VALIDATION');
      }
      guestValidFrom = from;
      guestValidUntil = until;
      expiresAt = until; // kod, misafirlik bitene kadar kullanilabilir
    } else {
      expiresAt = new Date(nowMs + RESIDENT_INVITE_TTL_MS);
    }

    const guestName = cleanRole === 'guest' ? cleanGuestName(options.guestName) : null;

    const active = await db.query(
      `SELECT COUNT(*)::int AS n FROM home_invitations
        WHERE home_id = $1 AND is_used = FALSE AND expires_at > NOW()`,
      [homeId]
    );
    if (active.rows[0] && Number(active.rows[0].n) >= MAX_ACTIVE_INVITATIONS) {
      throw new HttpError(409, 'Bu ev için çok fazla aktif davet var. Kullanılmayan davetlerin süresinin dolmasını bekleyin.', 'CONFLICT');
    }

    const homeRes = await db.query('SELECT id, name FROM homes WHERE id = $1', [homeId]);
    if (homeRes.rows.length === 0) throw new HttpError(404, 'Daire bulunamadı.', 'NOT_FOUND');

    for (let attempt = 0; attempt < 3; attempt++) {
      const code = CODE_PREFIX + generateCode(CODE_LENGTH);
      try {
        const ins = await db.query(
          `INSERT INTO home_invitations
             (home_id, created_by, invite_code, code_hash, role, expires_at, guest_valid_from, guest_valid_until, guest_name)
           VALUES ($1, $2, NULL, $3, $4, $5, $6, $7, $8)
           RETURNING id, home_id, role, expires_at, guest_valid_from, guest_valid_until, guest_name, created_at`,
          [homeId, actorId, hashInviteCode(code), cleanRole, expiresAt, guestValidFrom, guestValidUntil, guestName]
        );
        const row = ins.rows[0] || {};
        return {
          id: row.id,
          home_id: row.home_id || homeId,
          home_name: homeRes.rows[0].name,
          code,
          invite_code: code,
          role: row.role || cleanRole,
          expires_at: row.expires_at || expiresAt,
          guest_name: row.guest_name || guestName,
          guest_valid_from: row.guest_valid_from || guestValidFrom,
          guest_valid_until: row.guest_valid_until || guestValidUntil,
          qr_payload: `${QR_PREFIX}${code}`,
        };
      } catch (err) {
        if (err && err.code === '23505') continue; // kod cakismasi (cok dusuk olasilik): yeniden uret
        throw err;
      }
    }
    const err = new HttpError(503, 'Davet kodu şu anda üretilemedi. Lütfen tekrar deneyin.', 'SERVICE_UNAVAILABLE');
    err.expose = true;
    throw err;
  }

  /**
   * Davet koduyla eve katilim. Tek transaction; davet tek kullanimlik.
   * @returns {{home:object, already_member:boolean, message:string}}
   */
  static async joinHomeWithCode(inviteCode, userId) {
    if (!isUuid(String(userId || ''))) throw new HttpError(403, 'Bu işlem için yetkiniz yok.', 'FORBIDDEN');
    const code = normalizeInviteCode(inviteCode);
    if (!code) throw new HttpError(400, 'Geçerli bir davet kodu giriniz.', 'VALIDATION');
    const codeHash = hashInviteCode(code);

    return db.withTransaction(async (tx) => {
      const invRes = await tx.query(
        `SELECT i.id, i.home_id, i.role, i.is_used, i.expires_at, i.guest_valid_from, i.guest_valid_until,
                h.name AS home_name, h.address AS home_address
           FROM home_invitations i
           JOIN homes h ON h.id = i.home_id
          WHERE i.code_hash = $1
          FOR UPDATE OF i`,
        [codeHash]
      );
      if (invRes.rows.length === 0) {
        throw new HttpError(404, 'Geçersiz veya bulunamayan davet kodu.', 'NOT_FOUND');
      }
      const inv = invRes.rows[0];
      const nowMs = Date.now();
      if (inv.is_used) throw new HttpError(410, 'Bu davet kodu daha önce kullanılmış.', 'GONE');
      if (new Date(inv.expires_at).getTime() <= nowMs) {
        throw new HttpError(410, 'Bu davet kodunun geçerlilik süresi dolmuş.', 'GONE');
      }
      const role = normalizeRole(inv.role);
      if (!role) throw new HttpError(410, 'Bu davet artık geçerli değil.', 'GONE');
      if (role === 'guest' && (!inv.guest_valid_until || new Date(inv.guest_valid_until).getTime() <= nowMs)) {
        throw new HttpError(410, 'Bu misafir erişiminin süresi sona ermiş.', 'GONE');
      }

      const existingRes = await tx.query(
        'SELECT role, valid_from, valid_until FROM home_users WHERE home_id = $1 AND user_id = $2 FOR UPDATE',
        [inv.home_id, userId]
      );
      const existing = existingRes.rows[0] || null;

      const consume = async () => {
        const used = await tx.query(
          `UPDATE home_invitations
              SET is_used = TRUE, used_by = $2, used_at = NOW()
            WHERE id = $1 AND is_used = FALSE AND expires_at > NOW()
            RETURNING id`,
          [inv.id, userId]
        );
        if (used.rows.length === 0) throw new HttpError(410, 'Bu davet kodu daha önce kullanılmış.', 'GONE');
      };

      const homePayload = (finalRole, validFrom, validUntil) => ({
        id: inv.home_id,
        name: inv.home_name,
        address: inv.home_address || null,
        role: finalRole,
        valid_from: validFrom || null,
        valid_until: validUntil || null,
      });

      if (existing) {
        if (existing.role === 'guest' && role === 'guest') {
          await consume();
          await tx.query(
            'UPDATE home_users SET valid_from = $3, valid_until = $4 WHERE home_id = $1 AND user_id = $2',
            [inv.home_id, userId, inv.guest_valid_from, inv.guest_valid_until]
          );
          return {
            home: homePayload('guest', inv.guest_valid_from, inv.guest_valid_until),
            already_member: false,
            message: `"${inv.home_name}" evindeki misafir süreniz yenilendi.`,
          };
        }
        if (existing.role === 'guest' && role === 'resident') {
          await consume();
          await tx.query(
            `UPDATE home_users SET role = 'resident', valid_from = NULL, valid_until = NULL
              WHERE home_id = $1 AND user_id = $2`,
            [inv.home_id, userId]
          );
          return {
            home: homePayload('resident', null, null),
            already_member: false,
            message: `"${inv.home_name}" evine aile bireyi olarak katıldınız.`,
          };
        }
        // Zaten uye: davet TUKETILMEZ, rol degismez.
        return {
          home: homePayload(existing.role, existing.valid_from, existing.valid_until),
          already_member: true,
          message: 'Zaten bu evin bir üyesisiniz.',
        };
      }

      await consume();
      await tx.query(
        `INSERT INTO home_users (home_id, user_id, role, valid_from, valid_until)
         VALUES ($1, $2, $3, $4, $5)`,
        [
          inv.home_id,
          userId,
          role,
          role === 'guest' ? inv.guest_valid_from : null,
          role === 'guest' ? inv.guest_valid_until : null,
        ]
      );
      return {
        home: homePayload(role, role === 'guest' ? inv.guest_valid_from : null, role === 'guest' ? inv.guest_valid_until : null),
        already_member: false,
        message: role === 'guest'
          ? `"${inv.home_name}" evine süreli misafir olarak katıldınız.`
          : `"${inv.home_name}" evine aile bireyi olarak katıldınız.`,
      };
    });
  }

  /**
   * Ev uyeleri. Erisim (gecerli misafir dahil) route katmaninda dogrulanir.
   * @param {string} homeId
   * @param {{role:string}} access req.homeAccess
   */
  static async getHomeMembers(homeId, access) {
    const viewerRole = access && access.role ? access.role : 'guest';
    const includeContact = viewerRole !== 'guest';
    const r = await db.query(
      `SELECT hu.user_id, hu.role, hu.valid_from, hu.valid_until, hu.installer_expires_at, hu.created_at,
              u.full_name, u.email, u.phone
         FROM home_users hu
         JOIN users u ON u.id = hu.user_id
        WHERE hu.home_id = $1
          AND NOT (hu.role = 'service_user' AND hu.installer_expires_at IS NOT NULL AND hu.installer_expires_at <= NOW())
        ORDER BY CASE hu.role WHEN 'owner' THEN 1 WHEN 'resident' THEN 2 WHEN 'guest' THEN 3 ELSE 4 END,
                 hu.created_at ASC`,
      [homeId]
    );
    const nowMs = Date.now();
    const members = r.rows.map((row) => {
      const state = memberAccessState(row, nowMs);
      const out = {
        user_id: row.user_id,
        full_name: row.full_name,
        role: row.role,
        valid_from: row.valid_from || null,
        // Sureli teknisyen uyeliginde bitis installer_expires_at'tir (ev sahibi kimin ne zamana kadar
        // erisimi oldugunu gorur).
        valid_until: row.role === 'service_user' ? (row.installer_expires_at || null) : (row.valid_until || null),
        is_expired: state !== 'active',
        access_state: state,
        joined_at: row.created_at || null,
      };
      if (includeContact) {
        out.email = row.email || null;
        out.phone = row.phone || null;
      }
      return out;
    });
    return { members };
  }

  /**
   * Uye / misafir cikarma. Yetki: requireHomeAccess(MEMBERS) -> owner | super_user.
   * @param {string} homeId
   * @param {{userId:string, role:string, isSuper:boolean}} actor
   * @param {string} targetUserId
   */
  static async removeHomeMember(homeId, actor, targetUserId) {
    if (!isUuid(String(targetUserId || ''))) {
      throw new HttpError(400, 'Geçersiz kullanıcı kimliği.', 'VALIDATION');
    }
    const actorIsSuper = Boolean(actor && actor.isSuper);
    if (!actorIsSuper && actor && actor.userId === targetUserId) {
      throw new HttpError(400, 'Ev sahibi kendisini evden çıkaramaz. Sahipliği devretmek için daire devrini kullanın.', 'VALIDATION');
    }

    const mqtt = getMqttCredentialService();
    const outcome = await db.withTransaction(async (tx) => {
      const targetRes = await tx.query(
        'SELECT role FROM home_users WHERE home_id = $1 AND user_id = $2 FOR UPDATE',
        [homeId, targetUserId]
      );
      if (targetRes.rows.length === 0) {
        throw new HttpError(404, 'Kullanıcı bu evde bulunamadı.', 'NOT_FOUND');
      }
      const targetRole = targetRes.rows[0].role;
      if (targetRole === 'owner') {
        if (!actorIsSuper) {
          throw new HttpError(403, 'Ev sahibi başka bir ev sahibini evden çıkaramaz.', 'FORBIDDEN');
        }
        const owners = await tx.query(
          `SELECT COUNT(*)::int AS n FROM home_users WHERE home_id = $1 AND role = 'owner'`,
          [homeId]
        );
        if (!owners.rows[0] || Number(owners.rows[0].n) <= 1) {
          throw new HttpError(409, 'Evin son sahibi çıkarılamaz. Önce daire devri yapılmalıdır.', 'CONFLICT');
        }
      }

      await tx.query('DELETE FROM home_users WHERE home_id = $1 AND user_id = $2', [homeId, targetUserId]);

      let usernames = [];
      if (mqtt && typeof mqtt.revokeUserAccess === 'function') {
        const revoked = await mqtt.revokeUserAccess({ homeId, userId: targetUserId, tx });
        usernames = (revoked && revoked.usernames) || [];
      }
      return { usernames };
    });

    const kick = await kickAfterCommit(outcome.usernames);
    const result = { message: 'Kullanıcı evden çıkarıldı ve erişimi iptal edildi.' };
    if (kick && (kick.skipped || kick.failed > 0)) {
      result.warning = 'Açık MQTT bağlantısı anında kesilemedi; kimlik iptal edildi.';
    }
    return result;
  }
}

module.exports = InvitationService;
module.exports.normalizeInviteCode = normalizeInviteCode;
module.exports.hashInviteCode = hashInviteCode;
module.exports.normalizeRole = normalizeRole;
module.exports.MAX_ACTIVE_INVITATIONS = MAX_ACTIVE_INVITATIONS;
