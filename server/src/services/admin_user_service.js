'use strict';

// ==============================================================================
// AHBU Akilli Ev - Yonetici kullanici yonetimi (WP-A: A7)
// ==============================================================================
//
// Aktorler: super_user (tam yetki, korumalar dahilinde) ve service_user (staff).
//  - Staff yalnizca KENDI olusturdugu son kullanicilari (role='user') gorur/duzenler;
//    super kullanici detayini GOREMEZ (404). Parola BELIRLEYEMEZ/DEGISTIREMEZ: yalnizca
//    sifirlama/etkinlestirme baglantisi tetikler. Rol degistiremez, kalici silemez.
//  - Super: kendini dondurma/rolunu dusurme ENGELLI; son aktif super kullanici dondurulamaz,
//    dusurulemez, silinemez. Baska bir super kullanicinin parolasini degistirmek icin KENDI
//    mevcut parolasiyla yeniden dogrulama (current_password) gerekir. Kendi parolasi icin
//    /auth/change-password kullanilir.
//  - Parola / aktiflik / rol degisince: oturumlar iptal (token_version++ + refresh iptal + tum evlerdeki uygulama
//    MQTT kimlikleri: auth_service.revokeAllUserSessions, ayni transaction); kalici silmede de tum evlerdeki uygulama
//    MQTT kimlikleri iptal (paylasilan yardimci auth_service.revokeUserMqttCredentials). Acik baglantilar COMMIT sonrasi
//    atilir (auth_service.kickMqttUsernames).
//  - Kalici silme TEK transaction: tek sahibi oldugu ve baska uyesi olan ev varsa 409
//    (sahipsiz ev olusmaz); tek uyesi oldugu ev silinir; FK'ler temizlenir.
//  - Hata mesajlarinda constraint/SQL ayrintisi yoktur.

const bcrypt = require('bcryptjs');
const db = require('../db');
const { HttpError, isUuid } = require('../utils/helpers');
const { toBoundedInt, MAX_OFFSET } = require('../utils/ints');
const authService = require('./auth_service');
const serviceTokenService = require('./service_token_service');
const { invalidateUserAuthCache, invalidateServiceSessionCache } = require('../middlewares/auth_middleware');

const { normalizeEmail, normalizePhone, normalizeFullName, validatePassword } = authService;

const VALID_ROLES = Object.freeze(['super_user', 'service_user', 'user']);
const STAFF_ROLES = Object.freeze(['super_user', 'service_user']);
const TARGET_COLS = `id, email, full_name, phone, role, is_active, account_status, created_by_user_id,
  must_change_password, created_at, updated_at, admin_notes`;

function isSuper(actor) {
  return Boolean(actor && !actor.is_service_session && actor.role === 'super_user');
}

function isStaff(actor) {
  return Boolean(actor && !actor.is_service_session && actor.role === 'service_user');
}

function assertActor(actor) {
  if (!isSuper(actor) && !isStaff(actor)) {
    throw new HttpError(403, 'Bu işlem için yetkiniz bulunmamaktadır.', 'FORBIDDEN');
  }
}

function notFound() {
  return new HttpError(404, 'Kullanıcı bulunamadı.', 'NOT_FOUND');
}

/** Staff kapsami: kendisi veya kendi olusturdugu son kullanici. */
function staffCanSee(actor, target) {
  if (!target) return false;
  if (target.id === actor.id) return true;
  return target.role === 'user' && target.created_by_user_id === actor.id;
}

function cleanNotes(value) {
  if (value === undefined) return undefined;
  if (value === null) return null;
  const s = String(value).trim();
  return s ? s.slice(0, 2000) : null;
}

async function countOtherActiveSupers(q, excludeUserId) {
  const r = await q.query(
    `SELECT COUNT(*)::int AS n FROM users
      WHERE role = 'super_user' AND is_active = TRUE AND account_status = 'active' AND id <> $1`,
    [excludeUserId]
  );
  return Number(r.rows[0] ? r.rows[0].n : 0);
}

function mapPgError(err) {
  if (err && err.code === '23505') return new HttpError(409, 'Bu e-posta veya telefon başka bir hesapta kayıtlı.', 'CONFLICT');
  if (err && err.code === '23503') return new HttpError(409, 'Kullanıcı başka kayıtlarla ilişkili olduğu için işlem yapılamadı. Hesabı pasife alın.', 'CONFLICT');
  return err;
}

class AdminUserService {
  /**
   * Test icin MQTT kimlik servisi enjeksiyonu (null = yok; undefined = gercek). Tek kaynak auth_service'tir:
   * oturum iptali (revokeAllUserSessions) ve yonetici akislari AYNI ornegi kullanir.
   */
  setMqttCredentialService(svc) {
    authService.setMqttCredentialService(svc);
  }

  async _getTarget(q, userId, { forUpdate = false } = {}) {
    if (!isUuid(String(userId || ''))) return null;
    const r = await q.query(`SELECT ${TARGET_COLS} FROM users WHERE id = $1${forUpdate ? ' FOR UPDATE' : ''}`, [userId]);
    return r.rows[0] || null;
  }

  /** Listeleme. Staff: yalnizca kendi olusturdugu son kullanicilar (+ kendisi). */
  async listUsers({ role, search, is_active, limit = 50, offset = 0, currentUser } = {}) {
    assertActor(currentUser);
    const conditions = [];
    const params = [];

    if (role && role !== 'all') {
      if (!VALID_ROLES.includes(role)) throw new HttpError(400, 'Geçersiz rol filtresi.', 'VALIDATION');
      params.push(role);
      conditions.push(`u.role = $${params.length}`);
    }
    if (is_active !== undefined && is_active !== null && is_active !== '') {
      params.push(is_active === true || is_active === 'true');
      conditions.push(`u.is_active = $${params.length}`);
    }
    if (typeof search === 'string' && search.trim()) {
      const escaped = search.trim().toLowerCase().slice(0, 64).replace(/[\\%_]/g, (c) => `\\${c}`);
      params.push(`%${escaped}%`);
      const p = `$${params.length}`;
      conditions.push(`(LOWER(u.full_name) LIKE ${p} OR LOWER(u.email) LIKE ${p} OR COALESCE(u.phone, '') LIKE ${p})`);
    }
    if (isStaff(currentUser)) {
      params.push(currentUser.id);
      const p = `$${params.length}`;
      conditions.push(`((u.role = 'user' AND u.created_by_user_id = ${p}) OR u.id = ${p})`);
    }

    const where = conditions.length ? `WHERE ${conditions.join(' AND ')}` : '';
    const pageSize = toBoundedInt(limit, { min: 1, max: 100, fallback: 50, zeroIsFallback: true });
    const pageOffset = toBoundedInt(offset, { min: 0, max: MAX_OFFSET, fallback: 0 });

    const countRes = await db.query(`SELECT COUNT(*)::int AS total FROM users u ${where}`, params);
    const listParams = params.slice();
    listParams.push(pageSize, pageOffset);
    const listRes = await db.query(
      `SELECT u.id, u.email, u.full_name, u.phone, u.role, u.is_active, u.account_status,
              u.created_at, u.updated_at, u.admin_notes,
              creator.email AS created_by_email, creator.full_name AS created_by_name,
              (SELECT COUNT(*)::int FROM home_users hu WHERE hu.user_id = u.id) AS home_count,
              (SELECT COUNT(*)::int FROM commissioning_logs cl WHERE cl.technician_id = u.id) AS commissioning_count
         FROM users u
         LEFT JOIN users creator ON u.created_by_user_id = creator.id
         ${where}
        ORDER BY CASE WHEN u.role = 'super_user' THEN 1 WHEN u.role = 'service_user' THEN 2 ELSE 3 END,
                 u.created_at DESC
        LIMIT $${listParams.length - 1} OFFSET $${listParams.length}`,
      listParams
    );

    return {
      total: Number(countRes.rows[0] ? countRes.rows[0].total : 0),
      limit: pageSize,
      offset: pageOffset,
      users: listRes.rows,
    };
  }

  async getUserById(userId, { currentUser } = {}) {
    assertActor(currentUser);
    const target = await this._getTarget(db, userId);
    if (!target) throw notFound();
    if (isStaff(currentUser) && !staffCanSee(currentUser, target)) throw notFound();

    const creator = target.created_by_user_id
      ? (await db.query('SELECT email, full_name FROM users WHERE id = $1', [target.created_by_user_id])).rows[0]
      : null;
    const homesRes = await db.query(
      `SELECT h.id, h.name, h.address, hu.role, hu.created_at
         FROM homes h JOIN home_users hu ON h.id = hu.home_id
        WHERE hu.user_id = $1`,
      [target.id]
    );
    let commissioningLogs = [];
    if (target.role === 'service_user') {
      const logs = await db.query(
        `SELECT cl.id, cl.home_id, h.name AS home_name, cl.tests_passed, cl.notes, cl.created_at
           FROM commissioning_logs cl
           LEFT JOIN homes h ON cl.home_id = h.id
          WHERE cl.technician_id = $1
          ORDER BY cl.created_at DESC
          LIMIT 20`,
        [target.id]
      );
      commissioningLogs = logs.rows;
    }
    return {
      user: {
        ...target,
        created_by_email: creator ? creator.email : null,
        created_by_name: creator ? creator.full_name : null,
      },
      homes: homesRes.rows,
      commissioning_logs: commissioningLogs,
    };
  }

  /**
   * Kullanici olusturur.
   *  - super_user: her rol; parola verirse ilk giriste degistirme zorunlu (must_change_password).
   *    Parola vermezse hesap 'pending_invite' olur ve etkinlestirme e-postasi gider.
   *  - service_user: yalnizca role='user'; PAROLA BELIRLEYEMEZ -> 'pending_invite' + e-posta.
   */
  async createUser({ full_name, email, password, phone, role = 'user', admin_notes, currentUser } = {}) {
    assertActor(currentUser);
    const name = normalizeFullName(full_name);
    if (!name) throw new HttpError(400, 'Ad soyad en az 2 karakter olmalıdır.', 'VALIDATION');
    const cleanEmail = normalizeEmail(email);
    if (!cleanEmail) throw new HttpError(400, 'Geçerli bir e-posta adresi giriniz.', 'VALIDATION');
    let cleanPhone = null;
    if (phone !== undefined && phone !== null && String(phone).trim() !== '') {
      cleanPhone = normalizePhone(phone);
      if (!cleanPhone) throw new HttpError(400, 'Geçerli bir telefon numarası giriniz.', 'VALIDATION');
    }
    const cleanRole = String(role || 'user').trim().toLowerCase();
    if (!VALID_ROLES.includes(cleanRole)) throw new HttpError(400, 'Geçersiz rol.', 'VALIDATION');

    if (isStaff(currentUser)) {
      if (cleanRole !== 'user') {
        throw new HttpError(403, 'Servis sorumluları yalnızca standart daire kullanıcısı tanımlayabilir.', 'FORBIDDEN');
      }
      if (password !== undefined && password !== null && String(password) !== '') {
        throw new HttpError(403, 'Servis sorumluları kullanıcı parolası belirleyemez; hesap etkinleştirme e-postası gönderilir.', 'FORBIDDEN');
      }
    }

    const withPassword = isSuper(currentUser) && typeof password === 'string' && password.length > 0;
    if (withPassword) validatePassword(password);

    const exists = await db.query('SELECT id FROM users WHERE LOWER(email) = $1', [cleanEmail]);
    if (exists.rows.length > 0) throw new HttpError(409, 'Bu e-posta adresi sistemde zaten kayıtlı.', 'CONFLICT');
    if (cleanPhone) {
      const p = await db.query('SELECT id FROM users WHERE phone = $1', [cleanPhone]);
      if (p.rows.length > 0) throw new HttpError(409, 'Bu telefon numarası sistemde zaten kayıtlı.', 'CONFLICT');
    }

    const passwordHash = withPassword
      ? await bcrypt.hash(password, authServiceCost())
      : await authService._unusablePasswordHash();

    let created;
    try {
      const ins = await db.query(
        `INSERT INTO users (full_name, email, password_hash, phone, role, is_active, account_status,
                            must_change_password, created_by_user_id, admin_notes)
         VALUES ($1, $2, $3, $4, $5, TRUE, $6, $7, $8, $9)
         RETURNING id, email, full_name, phone, role, is_active, account_status, must_change_password, created_at, admin_notes`,
        [
          name,
          cleanEmail,
          passwordHash,
          cleanPhone,
          cleanRole,
          withPassword ? 'active' : 'pending_invite',
          withPassword,
          currentUser.id,
          cleanNotes(admin_notes) || null,
        ]
      );
      created = ins.rows[0];
    } catch (err) {
      throw mapPgError(err);
    }

    let invite = null;
    if (!withPassword) {
      invite = await authService.createAccountSetupInvite(created.id);
    }
    const out = { ...created };
    if (invite) {
      out.invite_sent = Boolean(invite.sent);
      if (!invite.sent) out.invite_warning = 'Etkinleştirme e-postası gönderilemedi; daha sonra "sıfırlama bağlantısı gönder" ile tekrar deneyin.';
      if (invite.debug_code) out.debug_code = invite.debug_code;
    }
    return out;
  }

  /**
   * Kullanici gunceller.
   * @param {object} p { full_name, phone, role, password, current_password, is_active, admin_notes, currentUser }
   */
  async updateUser(userId, { full_name, phone, role, password, current_password, is_active, admin_notes, currentUser } = {}) {
    assertActor(currentUser);
    const actorIsSuper = isSuper(currentUser);
    const wantsPassword = password !== undefined && password !== null && String(password) !== '';
    const wantsRole = role !== undefined && role !== null && role !== '';
    const wantsActive = is_active !== undefined && is_active !== null && is_active !== '';
    const nextActive = wantsActive ? (is_active === true || is_active === 'true') : undefined;

    // On kontroller (DB'siz)
    if (wantsPassword && !actorIsSuper) {
      throw new HttpError(403, 'Servis sorumluları parola değiştiremez; sıfırlama bağlantısı gönderin.', 'FORBIDDEN');
    }
    if (wantsRole && !actorIsSuper) {
      throw new HttpError(403, 'Rol atama yetkisi yalnızca Süper Yöneticilere aittir.', 'FORBIDDEN');
    }
    if (wantsRole && !VALID_ROLES.includes(String(role))) {
      throw new HttpError(400, 'Geçersiz rol.', 'VALIDATION');
    }
    if (currentUser.id === userId) {
      if (wantsPassword) throw new HttpError(400, 'Kendi şifreniz için şifre değiştirme ekranını kullanın.', 'VALIDATION');
      if (wantsRole && role !== currentUser.role) throw new HttpError(400, 'Kendi rolünüzü değiştiremezsiniz.', 'VALIDATION');
      if (wantsActive && nextActive === false) throw new HttpError(400, 'Kendi hesabınızı donduramazsınız.', 'VALIDATION');
    }
    if (wantsPassword) validatePassword(String(password));

    const outcome = await (async () => {
      try {
        return await db.withTransaction(async (tx) => {
          const target = await this._getTarget(tx, userId, { forUpdate: true });
          if (!target) throw notFound();
          if (!actorIsSuper && !staffCanSee(currentUser, target)) throw notFound();
          if (!actorIsSuper && target.id === currentUser.id && (wantsActive || wantsRole)) {
            throw new HttpError(403, 'Bu işlem için yetkiniz yok.', 'FORBIDDEN');
          }

          // Baska bir super kullanicinin parolasi: aktorun kendi parolasi ile yeniden dogrulama.
          if (wantsPassword && target.role === 'super_user' && target.id !== currentUser.id) {
            if (typeof current_password !== 'string' || !current_password) {
              throw new HttpError(403, 'Başka bir Süper Yöneticinin parolasını değiştirmek için kendi mevcut parolanızı girin.', 'REAUTH_REQUIRED');
            }
            const me = await tx.query('SELECT password_hash FROM users WHERE id = $1', [currentUser.id]);
            const ok = me.rows[0] && (await authService._comparePassword(current_password, me.rows[0].password_hash));
            if (!ok) throw new HttpError(403, 'Mevcut parolanız doğrulanamadı.', 'REAUTH_REQUIRED');
          }

          // Son aktif super kullanici korumasi
          const demotingSuper = target.role === 'super_user' && wantsRole && role !== 'super_user';
          const freezingSuper = target.role === 'super_user' && wantsActive && nextActive === false;
          if ((demotingSuper || freezingSuper) && (await countOtherActiveSupers(tx, target.id)) === 0) {
            throw new HttpError(409, 'Son aktif Süper Yönetici dondurulamaz veya rolü düşürülemez.', 'CONFLICT');
          }

          const sets = [];
          const params = [];
          const add = (sql, value) => {
            params.push(value);
            sets.push(`${sql} = $${params.length}`);
          };
          if (full_name !== undefined) {
            const n = normalizeFullName(full_name);
            if (!n) throw new HttpError(400, 'Ad soyad en az 2 karakter olmalıdır.', 'VALIDATION');
            add('full_name', n);
          }
          if (phone !== undefined) {
            if (phone === null || String(phone).trim() === '') add('phone', null);
            else {
              const p = normalizePhone(phone);
              if (!p) throw new HttpError(400, 'Geçerli bir telefon numarası giriniz.', 'VALIDATION');
              add('phone', p);
            }
          }
          if (admin_notes !== undefined) add('admin_notes', cleanNotes(admin_notes));
          const roleChanged = wantsRole && role !== target.role;
          if (roleChanged) add('role', role);
          const activeChanged = wantsActive && nextActive !== target.is_active;
          if (activeChanged) {
            add('is_active', nextActive);
            add('account_status', nextActive ? (target.account_status === 'suspended' ? 'active' : target.account_status) : 'suspended');
          }
          sets.push('updated_at = CURRENT_TIMESTAMP');

          params.push(target.id);
          const upd = await tx.query(
            `UPDATE users SET ${sets.join(', ')} WHERE id = $${params.length}
             RETURNING id, email, full_name, phone, role, is_active, account_status, must_change_password,
                       created_at, updated_at, admin_notes`,
            params
          );
          let updated = upd.rows[0];

          // Oturum iptalinde silinen uygulama MQTT kimlikleri (TUM evler); baglantilar COMMIT sonrasi atilir.
          const usernames = [];
          const revokeInfo = {};
          if (wantsPassword) {
            // Super baska kullaniciya parola atarsa: ilk giriste degistirme zorunlu.
            const u = await authService.setPassword(target.id, String(password), { tx, mustChange: true, revokedMqtt: usernames, revokeInfo });
            updated = { ...updated, must_change_password: u.must_change_password };
          }

          const revokeSessions = roleChanged || (activeChanged && nextActive === false);
          if (revokeSessions) {
            const revoked = await authService.revokeAllUserSessions(target.id, {
              tx,
              reason: activeChanged && nextActive === false ? 'account_suspended' : 'role_changed',
            });
            usernames.push(...revoked.mqttUsernames);
            if (revoked.serviceSessionsRevoked) revokeInfo.serviceSessionsRevoked = true;
          }
          // Personel rolunden 'user'a dusurulen hesabin ev bazli servis uyelikleri kalkar (uyelik-13): eski servis
          // evlerinde personel olarak kalmasin (requireHomeAccess zaten reddeder; listede de gorunmesin).
          if (roleChanged && role === 'user' && STAFF_ROLES.includes(target.role)) {
            await tx.query("DELETE FROM home_users WHERE user_id = $1 AND role = 'service_user'", [target.id]);
          }
          // Oturumlar toplu iptal edildiyse (parola atama dahil) push belirteci COMMIT sonrasi kapatilir.
          const pushReason = wantsPassword
            ? 'admin_password_set'
            : (activeChanged && nextActive === false ? 'account_suspended' : 'role_changed');
          return {
            updated,
            usernames,
            sessionsRevoked: Boolean(wantsPassword || revokeSessions),
            serviceSessionsRevoked: Boolean(revokeInfo.serviceSessionsRevoked),
            pushReason,
          };
        });
      } catch (err) {
        throw mapPgError(err);
      }
    })();

    invalidateUserAuthCache(userId);
    if (outcome.serviceSessionsRevoked) invalidateServiceSessionCache();
    // Push belirteci gizliligi (plan §5d-1): COMMIT sonrasi; hata/yapilandirma yoklugu islemi bozmaz.
    if (outcome.sessionsRevoked) await authService.revokePushTokens(userId, { reason: outcome.pushReason });
    await authService.kickMqttUsernames(outcome.usernames, { reason: outcome.pushReason });
    return outcome.updated;
  }

  /** Sifirlama / etkinlestirme baglantisi gonderir (staff: yalnizca kendi kullanicilari). */
  async sendPasswordReset(userId, { currentUser } = {}) {
    assertActor(currentUser);
    const target = await this._getTarget(db, userId);
    if (!target) throw notFound();
    if (isStaff(currentUser) && !staffCanSee(currentUser, target)) throw notFound();
    if (target.role === 'super_user' && !isSuper(currentUser)) throw notFound();
    if (target.is_active === false || target.account_status === 'suspended') {
      throw new HttpError(409, 'Askıya alınmış hesaba bağlantı gönderilemez.', 'CONFLICT');
    }
    const purpose = target.account_status === 'pending_invite' ? 'account_setup' : 'reset';
    const r = await authService.issueUserCode(target.id, { purpose });
    if (!r.sent && !r.debug_code) {
      const err = new HttpError(503, 'E-posta gönderilemedi. Lütfen daha sonra tekrar deneyin.', 'DELIVERY_FAILED');
      err.expose = true;
      throw err;
    }
    const out = { sent: Boolean(r.sent), purpose, expires_at: r.expires_at };
    if (r.debug_code) out.debug_code = r.debug_code;
    return out;
  }

  /**
   * Pasife alma (varsayilan) veya kalici silme (yalnizca super_user).
   */
  async deleteUser(userId, { currentUser, hardDelete = false } = {}) {
    assertActor(currentUser);
    if (!isUuid(String(userId || ''))) throw notFound();
    if (currentUser.id === userId) {
      throw new HttpError(400, 'Kendi hesabınızı bu menüden silemez veya donduramazsınız.', 'VALIDATION');
    }
    if (hardDelete && !isSuper(currentUser)) {
      throw new HttpError(403, 'Kalıcı silme yalnızca Süper Yöneticilere aittir.', 'FORBIDDEN');
    }

    let outcome;
    try {
      outcome = await db.withTransaction(async (tx) => {
        const target = await this._getTarget(tx, userId, { forUpdate: true });
        if (!target) throw notFound();
        if (isStaff(currentUser) && !staffCanSee(currentUser, target)) throw notFound();
        if (target.role === 'super_user') {
          if (!isSuper(currentUser)) throw notFound();
          if ((await countOtherActiveSupers(tx, target.id)) === 0) {
            throw new HttpError(409, 'Son aktif Süper Yönetici silinemez veya dondurulamaz.', 'CONFLICT');
          }
        }

        if (!hardDelete) {
          await tx.query(
            `UPDATE users SET is_active = FALSE, account_status = 'suspended', updated_at = CURRENT_TIMESTAMP
              WHERE id = $1`,
            [target.id]
          );
          // Oturumlar + TUM evlerdeki uygulama MQTT kimlikleri (ayni transaction)
          const revoked = await authService.revokeAllUserSessions(target.id, { tx, reason: 'account_suspended' });
          return { target, usernames: revoked.mqttUsernames, deletedHomes: 0, sessionsRevoked: true };
        }

        // --- Kalici silme ---
        const owned = await tx.query(
          `SELECT hu.home_id,
                  (SELECT COUNT(*)::int FROM home_users o
                    WHERE o.home_id = hu.home_id AND o.role = 'owner' AND o.user_id <> $1) AS other_owners,
                  (SELECT COUNT(*)::int FROM home_users m
                    WHERE m.home_id = hu.home_id AND m.user_id <> $1) AS other_members
             FROM home_users hu
            WHERE hu.user_id = $1 AND hu.role = 'owner'`,
          [target.id]
        );
        const blocked = (owned.rows || []).filter((h) => Number(h.other_owners) === 0 && Number(h.other_members) > 0);
        if (blocked.length > 0) {
          throw new HttpError(
            409,
            'Kullanıcı, başka üyeleri olan bir dairenin tek sahibi. Önce daireyi devredin veya üyeleri çıkarın.',
            'CONFLICT'
          );
        }
        const homesToDelete = (owned.rows || [])
          .filter((h) => Number(h.other_owners) === 0 && Number(h.other_members) === 0)
          .map((h) => h.home_id);

        const usernames = await authService.revokeUserMqttCredentials(target.id, { tx });
        const mqtt = authService.getMqttCredentialService();
        for (const homeId of homesToDelete) {
          if (mqtt && typeof mqtt.revokeHomeAccess === 'function') {
            const r = await mqtt.revokeHomeAccess({ homeId, includeDevice: true, tx });
            if (r && Array.isArray(r.usernames)) usernames.push(...r.usernames);
          }
          const svc = await serviceTokenService.revokeHomeServiceAccess(homeId, tx, 'home_deleted');
          if (svc && Array.isArray(svc.mqtt_usernames)) usernames.push(...svc.mqtt_usernames);
          await tx.query('DELETE FROM homes WHERE id = $1', [homeId]);
        }

        // ON DELETE kurali olmayan (NO ACTION) referanslar
        await tx.query('UPDATE home_invitations SET used_by = NULL WHERE used_by = $1', [target.id]);
        await tx.query('UPDATE home_transfers SET accepted_by = NULL WHERE accepted_by = $1', [target.id]);
        await tx.query('UPDATE users SET created_by_user_id = NULL WHERE created_by_user_id = $1', [target.id]);

        await tx.query('DELETE FROM users WHERE id = $1', [target.id]);
        return { target, usernames, deletedHomes: homesToDelete.length };
      });
    } catch (err) {
      throw mapPgError(err);
    }

    invalidateUserAuthCache(userId);
    invalidateServiceSessionCache();
    // Pasife alma: push belirteci COMMIT sonrasi kapatilir (kalici silmede push_tokens FK CASCADE ile gider).
    if (outcome.sessionsRevoked) await authService.revokePushTokens(userId, { reason: 'account_suspended' });
    await authService.kickMqttUsernames(outcome.usernames, { reason: hardDelete ? 'user_deleted' : 'account_suspended' });

    if (!hardDelete) {
      return { success: true, message: 'Kullanıcı pasife alındı; tüm oturumları sonlandırıldı.' };
    }
    return {
      success: true,
      message: outcome.deletedHomes > 0
        ? `Kullanıcı kalıcı olarak silindi (${outcome.deletedHomes} boş daire kaldırıldı).`
        : 'Kullanıcı kalıcı olarak silindi.',
    };
  }

  /** Super yonetici icin ozet istatistikler. */
  async getServiceSummary() {
    const countsRes = await db.query(`
      SELECT COUNT(*) FILTER (WHERE role = 'super_user')::int AS total_super_users,
             COUNT(*) FILTER (WHERE role = 'service_user')::int AS total_service_users,
             COUNT(*) FILTER (WHERE role = 'user')::int AS total_regular_users,
             COUNT(*)::int AS total_users
        FROM users`);
    const homesRes = await db.query('SELECT COUNT(*)::int AS total_homes FROM homes');
    const devicesRes = await db.query(`
      SELECT COUNT(*)::int AS total_devices,
             COUNT(*) FILTER (WHERE is_claimed = TRUE)::int AS claimed_devices,
             COUNT(*) FILTER (WHERE is_commissioned = TRUE)::int AS commissioned_devices,
             COUNT(*) FILTER (WHERE is_commissioned = FALSE AND is_claimed = TRUE)::int AS pending_commissioning
        FROM devices`);
    const c = countsRes.rows[0] || {};
    const d = devicesRes.rows[0] || {};
    return {
      users: {
        total_users: Number(c.total_users || 0),
        super_users: Number(c.total_super_users || 0),
        service_users: Number(c.total_service_users || 0),
        regular_users: Number(c.total_regular_users || 0),
      },
      homes: { total_homes: Number((homesRes.rows[0] || {}).total_homes || 0) },
      devices: {
        total_devices: Number(d.total_devices || 0),
        claimed_devices: Number(d.claimed_devices || 0),
        commissioned_devices: Number(d.commissioned_devices || 0),
        pending_commissioning: Number(d.pending_commissioning || 0),
      },
    };
  }
}

// bcrypt cost: auth_service ile ayni kural (uretimde 12).
function authServiceCost() {
  if (process.env.NODE_ENV === 'test' && /^\d+$/.test(String(process.env.BCRYPT_TEST_COST || ''))) {
    return Math.max(4, Math.min(12, Number(process.env.BCRYPT_TEST_COST)));
  }
  return 12;
}

module.exports = new AdminUserService();
module.exports.AdminUserService = AdminUserService;
