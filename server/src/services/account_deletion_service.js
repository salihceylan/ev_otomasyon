'use strict';

// ==============================================================================
// AHBU Akilli Ev - Hesap silme: yumusak silme + anonimlestirme (WP-B2)
// ==============================================================================
//
// Uc: DELETE /api/v1/auth/account   govde { password }  veya (sosyal / sifresiz hesap) { confirm: "SİL" }
//
// KURALLAR
//  * Yeniden dogrulama: sifreli hesapta mevcut PAROLA zorunlu (yanlis -> 400 INVALID_CREDENTIALS;
//    yalniz `confirm` gonderilirse 403 REAUTH_REQUIRED). Sifresiz hesapta (Google / Apple / telefon OTP ile
//    acilmis ve hic parola belirlememis) "SİL" yazarak onay yeterlidir.
//  * Staff (service_user) ve super_user kendi hesabini bu uctan SILEMEZ (403): yonetici hesaplari yalniz
//    super yonetici tarafindan yonetilir (son aktif super korumasi admin_user_service'te).
//  * TEK SAHIBI oldugu ve BASKA UYESI ya da CIHAZI olan ev varsa 409 SOLE_OWNER + (yalniz bu) ev listesi: once
//    daire devri (transfer) yapilmali. Boylece sahipsiz ev olusmaz ve baska uyelerin erisimi sessizce kopmaz.
//  * Uyesiz VE cihazsiz tek-sahipli ("bos") evler kimsenin erisimini koparmadigi icin engel DEGILDIR (UYELIK-03):
//    ayni transaction'da yonetici kalici silme sirasiyla temizlenir (MQTT ev kimlikleri uygulama + cihaz, servis
//    PIN/oturumlari, home_cleanup keepEndpoints:false, DELETE FROM homes); yanitta `released_homes` sayisi.
//  * Silme FIZIKSEL DEGILDIR (denetim/gunluk satirlari kullanici satirina isaret eder): e-posta
//    `deleted+<id>@deleted.invalid` olur (ESKI E-POSTA SERBEST KALIR -> ayni adresle yeniden kayit mumkun),
//    telefon / google_id / apple_id NULL, ad "Silinmiş Kullanıcı", is_active FALSE, account_status 'deleted',
//    deleted_at dolu (migration 027).
//  * Iptal edilenler: tum oturumlar (refresh token satirlari silinir, token_version++), push token'lar
//    (tablo varsa), bu kullanicinin TUM evlerdeki uygulama MQTT kimlikleri (commit sonrasi baglanti atilir),
//    ev uyelikleri, kullanicinin urettigi bekleyen davet/devir/servis PIN'leri, olusturdugu zamanli kurallar,
//    iletisim bilgisi tasiyan tek kullanimlik kodlar (sifre sifirlama, telefon OTP, claim/atama OTP).
//  * Her sey TEK gercek transaction'dir (db.withTransaction) ve denetim kaydi (device_audit_logs
//    'account_deleted', sir/kisisel veri icermez) ayni transaction'da yazilir.

const crypto = require('crypto');
const { HttpError, isUuid } = require('../utils/helpers');

const DELETED_NAME = 'Silinmiş Kullanıcı';
const DELETED_EMAIL_DOMAIN = 'deleted.invalid';
const PLACEHOLDER_EMAIL = /@(?:ahbu\.local|users\.noreply\.invalid)$/i;

/**
 * Teslim edilemeyen yer tutucu e-posta mi? Telefon-OTP hesabi (`phone_<no>@ahbu.local`), Apple gizli e-posta
 * (`apple.<ozet>@users.noreply.invalid`) ve silinmis hesap (`deleted+<id>@deleted.invalid`). auth_service disari
 * donen kullanici nesnesinde bunlari null gosterir (UYELIK-07) ve bu adreslere sifirlama kodu gondermez (UYELIK-08).
 */
function isPlaceholderEmail(email) {
  const s = String(email || '').trim().toLowerCase();
  return PLACEHOLDER_EMAIL.test(s) || s.endsWith(`@${DELETED_EMAIL_DOMAIN}`);
}

function httpError(status, message, code, extra = {}) {
  const err = new HttpError(status, message, code);
  if (extra.body && typeof extra.body === 'object') err.extra = extra.body;
  return err;
}

/** "SİL" onayi: bosluk/buyuk-kucuk harf ve Turkce i/İ farki gozetilmez ("sil", "Sil", "SIL", "SİL"). */
function isDeleteConfirmation(value) {
  if (typeof value !== 'string') return false;
  const s = value.normalize('NFC').trim().toLocaleUpperCase('tr-TR');
  return s === 'SİL' || s === 'SIL';
}

/**
 * Sifresiz hesap: kullanicinin bildigi bir parola HIC belirlenmemis (password_changed_at bos), parola degisimi
 * beklenmiyor ve hesap sosyal/telefon kimligiyle acilmis. (Sifreli kayit `register` password_changed_at yazar;
 * sifirlama / degistirme de yazar.)
 */
function isPasswordless(user) {
  if (user.password_changed_at) return false;
  if (user.must_change_password === true) return false;
  return Boolean(user.google_id || user.apple_id || PLACEHOLDER_EMAIL.test(String(user.email || '')));
}

class AccountDeletionService {
  /**
   * @param {object} [deps] test icin: { db, auth, mqtt, serviceTokens, homeCleanup, authMiddleware, now }
   */
  constructor(deps = {}) {
    this._deps = deps;
  }

  get db() {
    return this._deps.db || require('../db');
  }
  get auth() {
    return this._deps.auth || require('./auth_service');
  }
  get mqtt() {
    return this._deps.mqtt || require('./mqtt_credential_service');
  }
  get serviceTokens() {
    return this._deps.serviceTokens || require('./service_token_service');
  }
  get homeCleanup() {
    return this._deps.homeCleanup || require('./home_cleanup');
  }
  get authMiddleware() {
    return this._deps.authMiddleware || require('../middlewares/auth_middleware');
  }

  /**
   * Bos (uyesiz + cihazsiz) tek-sahipli evi `tx` icinde siler; yonetici kalici silme sirasi: MQTT ev kimlikleri
   * (uygulama + cihaz; kick COMMIT sonrasi), servis PIN/oturum iptali, ev temizligi, DELETE FROM homes.
   * @returns {Promise<string[]>} COMMIT sonrasi atilacak MQTT kullanici adlari
   */
  async _releaseEmptyHome(tx, homeId) {
    const r = await this.mqtt.revokeHomeAccess({ homeId, includeDevice: true, tx });
    await this.serviceTokens.revokeHomeServiceAccess(homeId, tx, 'home_deleted');
    await this.homeCleanup.cleanupHome(tx, homeId, { keepEndpoints: false });
    await tx.query('DELETE FROM homes WHERE id = $1', [homeId]);
    return r && Array.isArray(r.usernames) ? r.usernames : [];
  }

  /**
   * @param {{userId:string, password?:string, confirm?:string, ip?:string}} p
   * @returns {{deleted:true, deleted_at:string, released_memberships:number, released_homes:number, message:string, warnings?:string[]}}
   */
  async deleteAccount({ userId, password, confirm, ip } = {}) {
    if (!isUuid(String(userId || ''))) {
      throw httpError(403, 'Bu işlem için kullanıcı hesabı gereklidir.', 'FORBIDDEN');
    }
    const db = this.db;

    // --- 1) Yeniden dogrulama (yavas bcrypt islem DISINDA; satir kilidi tutulmaz) ---
    const cur = await db.query(
      `SELECT id, email, phone, role, is_active, account_status, password_hash, password_changed_at,
              must_change_password, google_id, apple_id
         FROM users WHERE id = $1`,
      [userId]
    );
    const user = cur.rows[0];
    if (!user || user.account_status === 'deleted') {
      throw httpError(404, 'Hesap bulunamadı.', 'NOT_FOUND');
    }
    if (user.role === 'service_user' || user.role === 'super_user') {
      throw httpError(
        403,
        'Servis personeli ve yönetici hesapları bu menüden silinemez. Süper yöneticiye başvurun.',
        'FORBIDDEN'
      );
    }

    const hasPassword = typeof password === 'string' && password.length > 0;
    if (hasPassword) {
      const ok = await this.auth._comparePassword(password, user.password_hash);
      if (!ok) throw httpError(400, 'Şifre hatalı.', 'INVALID_CREDENTIALS');
    } else if (isPasswordless(user)) {
      if (!isDeleteConfirmation(confirm)) {
        throw httpError(400, 'Hesabı silmek için "SİL" yazarak onaylayın.', 'VALIDATION');
      }
    } else {
      throw httpError(403, 'Hesabı silmek için mevcut şifrenizi girin.', 'REAUTH_REQUIRED');
    }

    // --- 2) Tek transaction: sahip kontrolu + temizlik + anonimlestirme + denetim ---
    const outcome = await db.withTransaction(async (tx) => {
      const q = (text, params) => tx.query(text, params);

      const locked = await q(
        `SELECT id, email, phone, role, account_status FROM users WHERE id = $1 FOR UPDATE`,
        [userId]
      );
      const row = locked.rows[0];
      if (!row || row.account_status === 'deleted') throw httpError(404, 'Hesap bulunamadi.', 'NOT_FOUND');
      if (row.role === 'service_user' || row.role === 'super_user') {
        throw httpError(403, 'Servis personeli ve yönetici hesapları bu menüden silinemez.', 'FORBIDDEN');
      }

      // TEK sahibi oldugu evler (uyelik satirlari kilitli: es zamanli devir/uye cikarma siralanir).
      // Engel yalniz baska UYESI ya da CIHAZI olan ev; bos ev asagida silinir (UYELIK-03).
      const sole = await q(
        `SELECT hu.home_id AS id, h.name,
                (SELECT COUNT(*)::int FROM home_users m WHERE m.home_id = hu.home_id AND m.user_id <> $1) AS other_member_count,
                (SELECT COUNT(*)::int FROM devices d WHERE d.home_id = hu.home_id) AS device_count
           FROM home_users hu
           JOIN homes h ON h.id = hu.home_id
          WHERE hu.user_id = $1 AND hu.role = 'owner'
            AND NOT EXISTS (SELECT 1 FROM home_users o WHERE o.home_id = hu.home_id AND o.role = 'owner' AND o.user_id <> $1)
          ORDER BY h.name ASC, hu.home_id ASC
          FOR UPDATE OF hu`,
        [userId]
      );
      const soleHomes = sole.rows.map((h) => ({
        id: h.id,
        name: h.name,
        other_member_count: Number(h.other_member_count) || 0,
        device_count: Number(h.device_count) || 0,
      }));
      const blocking = soleHomes.filter((h) => h.other_member_count > 0 || h.device_count > 0);
      if (blocking.length > 0) {
        throw httpError(
          409,
          'Tek sahibi olduğunuz daire(ler) var. Hesabınızı silmeden önce daire sahipliğini başka bir kullanıcıya devredin.',
          'SOLE_OWNER',
          { body: { homes: blocking } }
        );
      }
      const emptyHomeIds = soleHomes.map((h) => h.id); // engel yoksa kalan tek-sahipli evlerin hepsi bos

      // Kisisel veri tasiyan tek kullanimlik kodlar icin eski kimlikler (normalize e-posta + telefon)
      const identifiers = [row.email ? String(row.email).toLowerCase() : null, row.phone || null].filter(Boolean);

      // Uygulama MQTT kimlikleri (TUM evler; paylasilan yardimci revokeAllUserAccess); ACL satirlari FK CASCADE ile gider
      const creds = await this.mqtt.revokeAllUserAccess({ userId, tx });
      const usernames = creds && Array.isArray(creds.usernames) ? creds.usernames.slice() : [];
      const appCredentialCount = usernames.length;

      // Ev uyelikleri
      const memberships = await q('DELETE FROM home_users WHERE user_id = $1 RETURNING home_id', [userId]);

      // Bos tek-sahipli evler: kimsenin erisimi kopmaz -> ev silinir (cihaz kimligi dahil MQTT, servis PIN/oturum)
      for (const homeId of emptyHomeIds) {
        usernames.push(...(await this._releaseEmptyHome(tx, homeId)));
      }

      // Push token'lar (tablo 030 ile gelir; yoksa atlanir)
      const push = await q('SELECT to_regclass($1) AS t', ['public.push_tokens']);
      if (push.rows[0] && push.rows[0].t) {
        await q('DELETE FROM push_tokens WHERE user_id = $1', [userId]);
      }

      // Kullanicinin urettigi bekleyen erisimler
      await q('DELETE FROM home_invitations WHERE created_by = $1 AND is_used = FALSE', [userId]);
      await q(
        `UPDATE home_transfers SET status = 'CANCELLED'
          WHERE status = 'PENDING' AND (from_user_id = $1 OR target_identifier = ANY($2::text[]))`,
        [userId, identifiers]
      );
      await q(
        `UPDATE service_sessions SET revoked_at = NOW(), revoked_reason = 'account_deleted'
          WHERE revoked_at IS NULL AND service_token_id IN (SELECT id FROM service_tokens WHERE created_by = $1)`,
        [userId]
      );
      await q('UPDATE service_tokens SET revoked_at = NOW() WHERE created_by = $1 AND revoked_at IS NULL AND used_at IS NULL', [userId]);
      await q('DELETE FROM scheduled_rules WHERE created_by = $1', [userId]);

      // Iletisim bilgisi tasiyan kodlar / talepler
      await q('DELETE FROM password_resets WHERE user_id = $1 OR identifier = ANY($2::text[])', [userId, identifiers]);
      await q('DELETE FROM phone_otp_codes WHERE phone = ANY($1::text[])', [identifiers]);
      await q('DELETE FROM device_claim_otps WHERE requested_by = $1 OR target_identifier = ANY($2::text[])', [userId, identifiers]);
      await q(
        'DELETE FROM home_admin_assign_otps WHERE owner_user_id = $1 OR requested_by = $1 OR target_identifier = ANY($2::text[])',
        [userId, identifiers]
      );

      // Oturumlar: refresh token satirlari silinir (token_version asagida artar)
      await q('DELETE FROM refresh_tokens WHERE user_id = $1', [userId]);

      // Anonimlestirme: e-posta SERBEST kalir; kullanilamaz rastgele parola ozeti
      const placeholderHash = `!deleted:${crypto.randomBytes(16).toString('hex')}`; // bcrypt bicimi DEGIL: hicbir parola eslesmez
      const upd = await q(
        `UPDATE users
            SET email = $2,
                full_name = $3,
                phone = NULL,
                google_id = NULL,
                apple_id = NULL,
                password_hash = $4,
                is_active = FALSE,
                account_status = 'deleted',
                deleted_at = NOW(),
                email_verified = FALSE,
                must_change_password = FALSE,
                admin_notes = NULL,
                token_version = token_version + 1,
                updated_at = CURRENT_TIMESTAMP
          WHERE id = $1 AND account_status <> 'deleted'
          RETURNING deleted_at`,
        [userId, `deleted+${userId}@${DELETED_EMAIL_DOMAIN}`, DELETED_NAME, placeholderHash]
      );
      if (upd.rows.length === 0) throw httpError(404, 'Hesap bulunamadi.', 'NOT_FOUND');

      await q(
        `INSERT INTO device_audit_logs (event, device_uuid, home_id, actor_user_id, actor_role, ip_address, details)
         VALUES ($1, $2, $3, $4, $5, $6, $7)`,
        [
          'account_deleted',
          null,
          null,
          userId,
          row.role,
          ip || null,
          JSON.stringify({
            released_memberships: (memberships.rows || []).length,
            revoked_app_credentials: appCredentialCount,
            released_homes: emptyHomeIds.length,
            reauth: hasPassword ? 'password' : 'confirm',
          }),
        ]
      );

      return {
        deletedAt: upd.rows[0].deleted_at,
        usernames,
        released: (memberships.rows || []).length,
        releasedHomes: emptyHomeIds.length,
      };
    });

    // --- 3) Commit SONRASI: onbellek + acik MQTT baglantilari (hata silmeyi bozmaz) ---
    const warnings = [];
    const mw = this.authMiddleware;
    if (mw && typeof mw.invalidateUserAuthCache === 'function') mw.invalidateUserAuthCache(userId);
    // Silinen evlerin servis (PIN) oturumlari: onbellekteki oturum da hemen duser
    if (outcome.releasedHomes > 0 && mw && typeof mw.invalidateServiceSessionCache === 'function') mw.invalidateServiceSessionCache();
    if (outcome.usernames.length > 0) {
      try {
        const kick = await this.mqtt.kickUsernames(outcome.usernames);
        if (kick && (kick.skipped || kick.failed > 0)) {
          warnings.push('Açık MQTT bağlantıları anında kesilemedi; kimlikler silindi, bağlantılar yeniden doğrulamada düşer.');
        }
      } catch (_) {
        warnings.push('Açık MQTT bağlantıları anında kesilemedi; kimlikler silindi.');
      }
    }

    const data = {
      deleted: true,
      deleted_at: outcome.deletedAt instanceof Date ? outcome.deletedAt.toISOString() : outcome.deletedAt,
      released_memberships: outcome.released,
      released_homes: outcome.releasedHomes,
      message: 'Hesabınız silindi. Kişisel verileriniz anonimleştirildi ve tüm oturumlarınız sonlandırıldı.',
    };
    if (warnings.length > 0) data.warnings = warnings;
    return data;
  }
}

module.exports = new AccountDeletionService();
module.exports.AccountDeletionService = AccountDeletionService;
module.exports.isDeleteConfirmation = isDeleteConfirmation;
module.exports.isPasswordless = isPasswordless;
module.exports.isPlaceholderEmail = isPlaceholderEmail;
module.exports.DELETED_NAME = DELETED_NAME;
module.exports.DELETED_EMAIL_DOMAIN = DELETED_EMAIL_DOMAIN;
