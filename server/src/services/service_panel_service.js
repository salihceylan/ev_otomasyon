'use strict';

// ==============================================================================
// AHBU Akilli Ev - Servis paneli: abone listesi + Home Admin atama (WP-B2)
// ==============================================================================
//
// Uclar (routes/service_panel_routes.js):
//   GET  /service/subscribers                                  abone (ev) listesi
//   POST /service/subscribers/:homeId/assign-admin/request-otp mevcut sahibe onay kodu (OTP)
//   POST /service/subscribers/:homeId/assign-admin             Home Admin (owner) atama
//
// YETKI (CONTRACTS §1.4): yalnizca staff (global rol service_user) ve super_user. Servis (PIN) oturumu,
// owner, resident ve misafir HAYIR. Kapsam EV BAZLIDIR:
//   - super_user : tum evler
//   - staff      : yalnizca home_users'ta SURESI DOLMAMIS 'service_user' uyeligi olan evler
//                  (kurulum penceresi - installer_expires_at - dolan ev listeden de duser)
// Iletisim bilgisi (sahip adi, e-posta, telefon) yalnizca kapsamdaki evler icin doner.
//
// HOME ADMIN ATAMA kurallari:
//   * Evin sahibi (owner) YOKSA: onay kodu gerekmez; hedef icin (yoksa) 'pending_invite' hesap acilir,
//     etkinlestirme e-postasi gider ve hedef owner olur. Mevcut uyeler korunur.
//   * Sahibi VARSA: sahibin RIZASI zorunludur. Sahibe e-postayla 6 haneli kod gider (request-otp);
//     kod HEDEF KISIYE baglidir (sahip "X'e devredilecek" onayini verir) ve assign-admin'de aranir.
//     Onay verilince daire devri (transfer_service.acceptTransfer ile ayni) uygulanir: tum uyelikler
//     kalkar (islemi yapan servis personelinin kendi servis uyeligi haric), hedef TEK owner olur,
//     servis PIN/oturumlari ve evin uygulama MQTT kimlikleri iptal edilir, davet/kural/devir temizligi
//     (home_cleanup) calisir. Eski sahibin BASKA evlerdeki oturumlari DUSMEZ (hesap duzeyinde degil,
//     EV duzeyinde iptal).
//   * Sahibe ULASILAMIYORSA (e-posta yok / gonderilemedi): yalniz super_user, gerekce (>= 15 karakter)
//     ile `force: true` gondererek zorlayabilir. Denetim kaydi `mode = 'forced'` + gerekce.
//   * Hedef: servis personeli kendini (veya baska servis/super hesabini) sahip yapamaz; hesap aktif olmali.
//   * Hepsi TEK gercek transaction'dir (db.withTransaction). Basarisiz onay kodu denemesinin sayaci,
//     hata firlatilmadan ONCE commit edilir ("commit-then-throw"; ROLLBACK sayaci geri alirdi).
//   * Kod / parola / PIN loglanmaz ve denetim kaydina yazilmaz.

const crypto = require('crypto');
const { HttpError, isUuid } = require('../utils/helpers');

// --- Sabitler ---------------------------------------------------------------
const OTP_TTL_SECONDS = 15 * 60;
const OTP_RESEND_COOLDOWN_SECONDS = 60;
const OTP_MAX_ATTEMPTS = 5;
const OTP_ATTEMPT_WINDOW_MINUTES = 15;
const FORCE_REASON_MIN_LENGTH = 15;
const FORCE_REASON_MAX_LENGTH = 500;
const DEFAULT_PAGE_SIZE = 50;
const MAX_PAGE_SIZE = 100;
const MAX_OFFSET = 1000000;
const MAX_SEARCH_LENGTH = 64;
const MAX_LISTED_DEVICE_UUIDS = 10;

// Telefonla / Apple ile acilan hesaplarin teslim edilemeyen yer tutucu e-postalari (auth_service)
const PLACEHOLDER_EMAIL = /@(?:ahbu\.local|users\.noreply\.invalid)$/i;
// Hicbir kosulda teslim edilemeyen alanlar (utils/mailer.isValidRecipient ile ayni kural)
const UNDELIVERABLE_EMAIL = /\.(?:invalid|local)$/i;

const MODES = Object.freeze({ NO_OWNER: 'no_owner', OWNER_CONSENT: 'owner_consent', FORCED: 'forced' });
const BLOCKED_TARGET_ROLES = Object.freeze(['service_user', 'super_user']);
const BLOCKED_TARGET_STATUSES = Object.freeze(['suspended', 'deleted']);

// --- Saf yardimcilar --------------------------------------------------------

/** Hata uretici: errorHandler `retryAfter` (Retry-After + retry_after) ve `extra` (govdeye eklenir) alanlarini bilir. */
function httpError(status, message, code, extra = {}) {
  const err = new HttpError(status, message, code);
  if (Number.isFinite(extra.retryAfter)) err.retryAfter = extra.retryAfter;
  if (extra.body && typeof extra.body === 'object') err.extra = extra.body;
  if (extra.expose === true) err.expose = true;
  return err;
}

function maskEmail(email) {
  const s = String(email || '');
  const at = s.indexOf('@');
  if (at < 1) return '***';
  const domain = s.slice(at + 1);
  const dot = domain.lastIndexOf('.');
  return `${s[0]}***@${domain[0] || ''}***${dot > 0 ? domain.slice(dot) : ''}`;
}

function maskPhone(phone) {
  const d = String(phone || '').replace(/\D/g, '');
  return d.length >= 4 ? `***${d.slice(-2)}` : '***';
}

/** Gercekten e-posta ile ulasilabilir adres mi? (yer tutucu adresler ulasilamaz sayilir) */
function isDeliverableEmail(email) {
  return typeof email === 'string' && email.includes('@') && !PLACEHOLDER_EMAIL.test(email) && !UNDELIVERABLE_EMAIL.test(email);
}

function secondsUntil(date, now) {
  return Math.max(1, Math.ceil((new Date(date).getTime() - now.getTime()) / 1000));
}

function isDebugOtpAllowed(env) {
  return env.ALLOW_DEBUG_OTP === 'true' && env.NODE_ENV !== 'production';
}

/** Tamsayiya cevirir ve [min, max] araligina kirpar; sayi degilse (veya zeroIsFallback ve 0 ise) `fallback`. */
function toBoundedInt(value, { min, max, fallback, zeroIsFallback = false }) {
  const n = Number.parseInt(value, 10);
  if (!Number.isFinite(n) || (zeroIsFallback && n === 0)) return fallback;
  return Math.min(max, Math.max(min, n));
}

function actorScope(actor) {
  if (!actor || !isUuid(String(actor.userId || '')) || actor.isServiceSession === true) {
    throw httpError(403, 'Bu işlem yalnızca yetkili servis personeli veya süper yönetici içindir.', 'FORBIDDEN');
  }
  if (actor.globalRole === 'super_user') return { isSuper: true, isStaff: false };
  if (actor.globalRole === 'service_user') return { isSuper: false, isStaff: true };
  throw httpError(403, 'Bu işlem yalnızca yetkili servis personeli veya süper yönetici içindir.', 'FORBIDDEN');
}

function publicOwner(row) {
  if (!row || !row.owner_id) return null;
  return {
    full_name: row.owner_full_name || null,
    email: isDeliverableEmail(row.owner_email) ? row.owner_email : null,
    phone: row.owner_phone || null,
    account_status: row.owner_account_status || null,
  };
}

class ServicePanelService {
  /**
   * @param {object} [deps] test icin: { db, pin, mailer, auth, mqtt, serviceTokens, cleanup, authMiddleware, now, env }
   */
  constructor(deps = {}) {
    this._deps = deps;
  }

  // --- bagimliliklar (tembel; modul yuklenirken db.js / DATABASE_URL gerektirmez) ---
  get db() {
    return this._deps.db || require('../db');
  }
  get pin() {
    return this._deps.pin || require('../utils/pin');
  }
  get mailer() {
    return this._deps.mailer || require('../utils/panel_mail');
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
  get cleanup() {
    return this._deps.cleanup || require('./home_cleanup');
  }
  get authMiddleware() {
    return this._deps.authMiddleware || require('../middlewares/auth_middleware');
  }
  get env() {
    return this._deps.env || process.env;
  }
  _now() {
    return this._deps.now ? this._deps.now() : new Date();
  }

  async _pinMatches(plain, stored) {
    const result = await this.pin.verifyPin(plain, stored);
    return result === true || Boolean(result && result.valid === true);
  }

  async _audit(q, { event, homeId = null, actor = null, details = null }) {
    await q(
      `INSERT INTO device_audit_logs (event, device_uuid, home_id, actor_user_id, actor_role, ip_address, details)
       VALUES ($1, $2, $3, $4, $5, $6, $7)`,
      [
        event,
        null,
        homeId,
        (actor && actor.userId) || null,
        (actor && actor.globalRole) || null,
        (actor && actor.ip) || null,
        details ? JSON.stringify(details) : null,
      ]
    );
  }

  // ===========================================================================
  // 1) Abone listesi
  // ===========================================================================

  /**
   * Kapsamdaki evlerin sayfali listesi.
   * @param {{actor:object, q?:string, limit?:any, offset?:any}} p
   * @returns {{subscribers:Array, total:number, count:number, limit:number, offset:number}}
   */
  async listSubscribers({ actor, q, limit, offset } = {}) {
    const scope = actorScope(actor);
    const pageSize = toBoundedInt(limit, { min: 1, max: MAX_PAGE_SIZE, fallback: DEFAULT_PAGE_SIZE, zeroIsFallback: true });
    const pageOffset = toBoundedInt(offset, { min: 0, max: MAX_OFFSET, fallback: 0 });

    const params = [];
    const conditions = [];
    if (!scope.isSuper) {
      // staff: yalnizca kendi (suresi dolmamis) servis uyeligi olan evler
      params.push(actor.userId);
      conditions.push(
        `EXISTS (SELECT 1 FROM home_users sm
                  WHERE sm.home_id = h.id AND sm.user_id = $${params.length} AND sm.role = 'service_user'
                    AND (sm.installer_expires_at IS NULL OR sm.installer_expires_at > NOW()))`
      );
    }
    const term = typeof q === 'string' ? q.trim().slice(0, MAX_SEARCH_LENGTH) : '';
    if (term) {
      const escaped = term.replace(/[\\%_]/g, (c) => `\\${c}`);
      params.push(`%${escaped}%`);
      const p = `$${params.length}`;
      conditions.push(
        `(h.name ILIKE ${p} OR COALESCE(h.address, '') ILIKE ${p}
          OR ou.full_name ILIKE ${p} OR ou.email ILIKE ${p} OR COALESCE(ou.phone, '') ILIKE ${p}
          OR EXISTS (SELECT 1 FROM devices sd WHERE sd.home_id = h.id AND sd.device_uuid ILIKE ${p}))`
      );
    }
    const where = conditions.length > 0 ? `WHERE ${conditions.join(' AND ')}` : '';

    // Sahip: evin en eski 'owner' uyesi (normalde tek)
    const base = `FROM homes h
      LEFT JOIN users ou ON ou.id = (
        SELECT hu.user_id FROM home_users hu
         WHERE hu.home_id = h.id AND hu.role = 'owner'
         ORDER BY hu.created_at ASC, hu.id ASC
         LIMIT 1)
      ${where}`;

    const db = this.db;
    const countRes = await db.query(`SELECT COUNT(*)::int AS total ${base}`, params);
    const total = Number((countRes.rows[0] || {}).total || 0);

    const pageParams = params.slice();
    pageParams.push(pageSize, pageOffset);
    const pageRes = await db.query(
      `SELECT h.id AS home_id, h.name AS home_name, h.address AS home_address, h.created_at AS home_created_at,
              ou.id AS owner_id, ou.full_name AS owner_full_name, ou.email AS owner_email,
              ou.phone AS owner_phone, ou.account_status AS owner_account_status
         ${base}
        ORDER BY h.created_at DESC, h.id ASC
        LIMIT $${pageParams.length - 1} OFFSET $${pageParams.length}`,
      pageParams
    );
    const homes = pageRes.rows || [];

    // Cihaz ozetleri yalnizca bu sayfadaki evler icin hesaplanir
    const stats = new Map();
    if (homes.length > 0) {
      const devRes = await db.query(
        `SELECT d.home_id,
                COUNT(*)::int AS device_count,
                COUNT(*) FILTER (WHERE d.is_online = TRUE)::int AS online_count,
                COUNT(*) FILTER (WHERE d.is_commissioned = TRUE)::int AS commissioned_count,
                MAX(d.commissioned_at) FILTER (WHERE d.is_commissioned = TRUE) AS commissioned_at,
                MAX(d.last_seen_at) AS last_seen_at,
                (array_agg(d.device_uuid ORDER BY d.created_at ASC, d.id ASC))[1:${MAX_LISTED_DEVICE_UUIDS}] AS device_uuids
           FROM devices d
          WHERE d.home_id = ANY($1::uuid[])
          GROUP BY d.home_id`,
        [homes.map((h) => h.home_id)]
      );
      for (const row of devRes.rows || []) stats.set(row.home_id, row);
    }

    const subscribers = homes.map((h) => {
      const s = stats.get(h.home_id) || {};
      return {
        home_id: h.home_id,
        home_name: h.home_name,
        home_address: h.home_address || null,
        owner: publicOwner(h),
        device_count: Number(s.device_count || 0),
        online_count: Number(s.online_count || 0),
        commissioned_count: Number(s.commissioned_count || 0),
        commissioned_at: s.commissioned_at || null,
        last_seen_at: s.last_seen_at || null,
        device_uuids: Array.isArray(s.device_uuids) ? s.device_uuids : [],
        created_at: h.home_created_at || null,
      };
    });
    return { subscribers, total, count: subscribers.length, limit: pageSize, offset: pageOffset };
  }

  // ===========================================================================
  // 2) Home Admin atama - ortak yardimcilar
  // ===========================================================================

  /** Govde (ad + e-posta|telefon) -> normalize hedef. Gecersizse 400. */
  _parseTarget(input) {
    const auth = this.auth;
    const raw = input && typeof input === 'object' ? input : {};
    const fullName = auth.normalizeFullName(raw.fullName);
    if (!fullName) throw httpError(400, 'Ad soyad en az 2 karakter olmalıdır.', 'VALIDATION');

    const present = (v) => v !== undefined && v !== null && String(v).trim() !== '';
    let email = null;
    let phone = null;
    if (present(raw.email)) {
      email = auth.normalizeEmail(raw.email);
      if (!email) throw httpError(400, 'Geçerli bir e-posta adresi giriniz.', 'VALIDATION');
      // Teslim edilemeyen adresler (yer tutucu alanlari dahil) hesap adresi olamaz: telefon/Apple hesaplarinin
      // yer tutucu e-postalariyla (phone_...@ahbu.local) ileride CAKISMA yaratir ve davet gonderilemez.
      if (UNDELIVERABLE_EMAIL.test(email)) {
        throw httpError(400, 'Teslim edilebilir bir e-posta adresi giriniz.', 'VALIDATION');
      }
    }
    if (present(raw.phone)) {
      phone = auth.normalizePhone(raw.phone);
      if (!phone) throw httpError(400, 'Geçerli bir telefon numarası giriniz.', 'VALIDATION');
    }
    if (!email && !phone) {
      throw httpError(400, 'Atanacak kişinin e-posta adresi veya telefon numarası zorunludur.', 'VALIDATION');
    }
    return { fullName, email, phone, key: email || phone, keyType: email ? 'email' : 'phone' };
  }

  /** Islemi yapanin etkin hesap + (staff icin) bu evdeki GECERLI servis uyeligi dogrulamasi. */
  async _assertActorMayAct(q, scope, actor, homeId) {
    const me = await q('SELECT id, role, is_active, account_status FROM users WHERE id = $1', [actor.userId]);
    const row = me.rows[0];
    if (!row || row.is_active === false || row.account_status !== 'active') {
      throw httpError(403, 'Hesabınız aktif değil.', 'FORBIDDEN');
    }
    if (row.role !== actor.globalRole) {
      throw httpError(403, 'Yetki bilgisi güncel değil. Lütfen yeniden giriş yapın.', 'FORBIDDEN');
    }
    if (scope.isStaff) {
      const mem = await q(
        `SELECT 1 FROM home_users
          WHERE home_id = $1 AND user_id = $2 AND role = 'service_user'
            AND (installer_expires_at IS NULL OR installer_expires_at > NOW())`,
        [homeId, actor.userId]
      );
      if (mem.rows.length === 0) {
        throw httpError(403, 'Bu dairede servis yetkiniz yok veya servis süreniz doldu.', 'FORBIDDEN');
      }
    }
    return row;
  }

  async _loadOwners(q, homeId, { lock = false } = {}) {
    const res = await q(
      `SELECT hu.user_id AS id, u.email, u.full_name, u.phone, u.account_status
         FROM home_users hu
         JOIN users u ON u.id = hu.user_id
        WHERE hu.home_id = $1 AND hu.role = 'owner'
        ORDER BY hu.created_at ASC, hu.id ASC${lock ? '\n        FOR UPDATE OF hu' : ''}`,
      [homeId]
    );
    return res.rows || [];
  }

  async _findTargetUser(q, target) {
    const res =
      target.keyType === 'email'
        ? await q(
            'SELECT id, email, full_name, phone, role, is_active, account_status FROM users WHERE LOWER(email) = $1',
            [target.key]
          )
        : await q(
            'SELECT id, email, full_name, phone, role, is_active, account_status FROM users WHERE phone = $1',
            [target.key]
          );
    if (res.rows.length > 1) {
      throw httpError(409, 'Bu telefon numarası birden fazla hesapta kayıtlı. E-posta adresi ile deneyin.', 'CONFLICT');
    }
    return res.rows[0] || null;
  }

  /** Hedef hesap atanabilir mi? (yoksa/yeni hesap kosullari da burada kontrol edilir) */
  _assertTargetAllowed(user, target, actor) {
    if (!user) {
      if (!target.email) {
        throw httpError(
          400,
          'Bu telefon numarasına bağlı bir hesap yok. Yeni hesap açmak için müşterinin e-posta adresini girin.',
          'VALIDATION'
        );
      }
      return;
    }
    if (user.id === actor.userId) {
      throw httpError(403, 'Kendinizi Home Admin olarak atayamazsınız.', 'FORBIDDEN');
    }
    if (BLOCKED_TARGET_ROLES.includes(user.role)) {
      throw httpError(403, 'Servis personeli ve yönetici hesapları Home Admin olarak atanamaz.', 'FORBIDDEN');
    }
    if (user.is_active === false || BLOCKED_TARGET_STATUSES.includes(user.account_status)) {
      throw httpError(409, 'Atanacak hesap aktif değil.', 'CONFLICT');
    }
  }

  /** Hedef zaten evin TEK sahibiyse atama anlamsiz ve yikicidir (uyelikler bosuna silinirdi): 409. */
  _assertNotAlreadySoleOwner(owners, targetUser) {
    if (targetUser && owners.length === 1 && owners[0].id === targetUser.id) {
      throw httpError(409, 'Atanacak kişi zaten bu dairenin ev sahibi.', 'CONFLICT');
    }
  }

  // ===========================================================================
  // 3) Home Admin atama - mevcut sahibe onay kodu
  // ===========================================================================

  /**
   * Mevcut ev sahibine, hedef kisiye devir icin 6 haneli onay kodu gonderir.
   * Sahip yoksa kod gerekmez (otp_required: false).
   * @returns {{otp_required:boolean, message:string, expires_in?:number, resend_after?:number, owner_hint?:string, debug_code?:string}}
   */
  async requestAssignAdminOtp({ actor, homeId, target: targetInput } = {}) {
    const scope = actorScope(actor);
    if (!isUuid(String(homeId || ''))) throw httpError(400, 'Geçersiz daire kimliği (home_id).', 'VALIDATION');
    const target = this._parseTarget(targetInput);
    const db = this.db;
    const q = (text, params) => db.query(text, params);

    const homeRes = await q('SELECT id, name FROM homes WHERE id = $1', [homeId]);
    const home = homeRes.rows[0];
    if (!home) throw httpError(404, 'Daire bulunamadı.', 'NOT_FOUND');
    await this._assertActorMayAct(q, scope, actor, homeId);

    const owners = await this._loadOwners(q, homeId);
    if (owners.length === 0) {
      return {
        otp_required: false,
        message: 'Bu dairede mevcut ev sahibi yok; onay kodu gerekmez. Doğrudan atama yapabilirsiniz.',
      };
    }
    if (owners.length > 1) {
      throw httpError(
        409,
        'Bu dairede birden fazla ev sahibi kayıtlı; onay kodu ile atama yapılamaz. Süper yöneticiye başvurun.',
        'MULTIPLE_OWNERS'
      );
    }
    const owner = owners[0];

    // Imkansiz hedefler icin sahibe bos yere kod gonderilmez
    const targetUser = await this._findTargetUser(q, target);
    this._assertTargetAllowed(targetUser, target, actor);
    this._assertNotAlreadySoleOwner(owners, targetUser);

    if (!isDeliverableEmail(owner.email)) {
      throw httpError(
        409,
        'Mevcut ev sahibine e-posta ile ulaşılamıyor. Süper yönetici gerekçeli zorla atama yapabilir.',
        'OWNER_UNREACHABLE'
      );
    }

    // Kisisel veri (hedef kimligi) tutma suresi: 1 gunden eski suresi dolmus kodlar oportunist olarak silinir
    await q("DELETE FROM home_admin_assign_otps WHERE expires_at < NOW() - INTERVAL '1 day'");

    // Kod uret, ozetini sakla. Yeniden istek: 60 sn bekleme + deneme sayaci (15 dk pencere) KORUNUR.
    const code = String(crypto.randomInt(0, 1000000)).padStart(6, '0');
    const otpHash = await this.pin.hashPin(code);
    const expiresAt = new Date(this._now().getTime() + OTP_TTL_SECONDS * 1000);
    const up = await q(
      `INSERT INTO home_admin_assign_otps
              (home_id, owner_user_id, target_identifier, target_name, otp_hash, expires_at, attempts, window_started_at, requested_by)
       VALUES ($1, $2, $3, $4, $5, $6, 0, NOW(), $7)
       ON CONFLICT (home_id) DO UPDATE SET
         owner_user_id = EXCLUDED.owner_user_id,
         target_identifier = EXCLUDED.target_identifier,
         target_name = EXCLUDED.target_name,
         otp_hash = EXCLUDED.otp_hash,
         expires_at = EXCLUDED.expires_at,
         requested_by = EXCLUDED.requested_by,
         created_at = NOW(),
         attempts = CASE WHEN home_admin_assign_otps.window_started_at < NOW() - ($8 * INTERVAL '1 minute')
                         THEN 0 ELSE home_admin_assign_otps.attempts END,
         window_started_at = CASE WHEN home_admin_assign_otps.window_started_at < NOW() - ($8 * INTERVAL '1 minute')
                                  THEN NOW() ELSE home_admin_assign_otps.window_started_at END
       WHERE home_admin_assign_otps.created_at < NOW() - ($9 * INTERVAL '1 second')
       RETURNING attempts, window_started_at`,
      [
        homeId,
        owner.id,
        target.key,
        target.fullName,
        otpHash,
        expiresAt,
        actor.userId,
        OTP_ATTEMPT_WINDOW_MINUTES,
        OTP_RESEND_COOLDOWN_SECONDS,
      ]
    );

    if (up.rows.length === 0) {
      const w = await q(
        `SELECT GREATEST(1, CEIL($2 - EXTRACT(EPOCH FROM (NOW() - created_at))))::int AS wait_seconds
           FROM home_admin_assign_otps WHERE home_id = $1`,
        [homeId, OTP_RESEND_COOLDOWN_SECONDS]
      );
      const wait = (w.rows[0] && Number(w.rows[0].wait_seconds)) || OTP_RESEND_COOLDOWN_SECONDS;
      throw httpError(429, `Yeni kod istemek için ${wait} saniye bekleyin.`, 'RATE_LIMITED', {
        retryAfter: wait,
        body: { resend_after: wait },
      });
    }
    const attempts = Number(up.rows[0].attempts) || 0;
    if (attempts >= OTP_MAX_ATTEMPTS) {
      const windowEnd = new Date(up.rows[0].window_started_at).getTime() + OTP_ATTEMPT_WINDOW_MINUTES * 60 * 1000;
      const wait = Math.max(1, Math.ceil((windowEnd - this._now().getTime()) / 1000));
      throw httpError(
        429,
        'Bu daire için çok fazla hatalı onay kodu denemesi yapıldı. Lütfen daha sonra tekrar deneyin.',
        'RATE_LIMITED',
        { retryAfter: wait, body: { resend_after: wait } }
      );
    }

    // Gonderim sonucu YUZEYE cikar (SMTP yok / hata = hata). Kod hicbir yerde loglanmaz.
    let sendResult;
    try {
      sendResult = await this.mailer.sendAssignAdminOtpEmail({
        to: owner.email,
        homeName: home.name,
        targetName: target.fullName,
        targetHint: target.keyType === 'email' ? maskEmail(target.key) : maskPhone(target.key),
        code,
        expiresMinutes: Math.round(OTP_TTL_SECONDS / 60),
      });
    } catch (_) {
      sendResult = { sent: false, reason: 'SEND_FAILED' };
    }
    const debugAllowed = isDebugOtpAllowed(this.env);
    if (!sendResult || sendResult.sent !== true) {
      if (!debugAllowed) {
        // Teslim edilmeyen kodu gecersiz kil ve beklemeyi kaldir (deneme sayaci korunur)
        await q(
          `UPDATE home_admin_assign_otps
              SET expires_at = NOW(), created_at = NOW() - INTERVAL '1 day'
            WHERE home_id = $1 AND otp_hash = $2`,
          [homeId, otpHash]
        );
        throw httpError(
          503,
          'Mevcut ev sahibine onay e-postası gönderilemedi. Ulaşılamıyorsa süper yönetici gerekçeli zorla atama yapabilir.',
          'DELIVERY_FAILED',
          { expose: true }
        );
      }
    }

    await this._audit(q, {
      event: 'home_admin_otp_requested',
      homeId,
      actor,
      details: { target_type: target.keyType },
    });

    const result = {
      otp_required: true,
      message: `Onay kodu ev sahibine (${maskEmail(owner.email)}) gönderildi.`,
      owner_hint: maskEmail(owner.email),
      expires_in: OTP_TTL_SECONDS,
      resend_after: OTP_RESEND_COOLDOWN_SECONDS,
    };
    if (debugAllowed) result.debug_code = code; // yalnizca gelistirmede (ALLOW_DEBUG_OTP=true, uretimde ASLA)
    return result;
  }

  /** Sahibin onay kodunu dogrular ve tuketir. Sayaci etkileyen basarisizlik { ok:false, error } doner (firlatilmaz). */
  async _verifyOwnerConsent(q, { homeId, owner, target, otpCode }) {
    const code = typeof otpCode === 'string' || typeof otpCode === 'number' ? String(otpCode).trim() : '';
    if (!/^\d{6}$/.test(code)) {
      throw httpError(
        400,
        'Mevcut ev sahibinin onay kodu (6 hane) zorunludur. Önce sahibe kod gönderin.',
        'OWNER_CONSENT_REQUIRED'
      );
    }
    const res = await q(
      `SELECT id, owner_user_id, target_identifier, otp_hash, attempts, expires_at, window_started_at
         FROM home_admin_assign_otps
        WHERE home_id = $1
        FOR UPDATE`,
      [homeId]
    );
    const row = res.rows[0];
    const now = this._now();
    if (!row || new Date(row.expires_at).getTime() <= now.getTime() || row.owner_user_id !== owner.id) {
      throw httpError(
        400,
        'Geçerli bir onay kodu bulunamadı veya süresi doldu. Mevcut ev sahibine yeni kod gönderin.',
        'OWNER_CONSENT_REQUIRED'
      );
    }
    if (row.target_identifier !== target.key) {
      throw httpError(
        400,
        'Onay kodu başka bir kişi için istenmiş. Aynı kişi bilgileriyle yeniden kod isteyin.',
        'OWNER_CONSENT_REQUIRED'
      );
    }
    if (Number(row.attempts) >= OTP_MAX_ATTEMPTS) {
      const windowEnd = new Date(row.window_started_at).getTime() + OTP_ATTEMPT_WINDOW_MINUTES * 60 * 1000;
      const wait = Math.max(1, Math.ceil((windowEnd - now.getTime()) / 1000));
      return {
        ok: false,
        error: httpError(429, 'Çok fazla hatalı onay kodu denemesi yapıldı. Lütfen daha sonra tekrar deneyin.', 'RATE_LIMITED', {
          retryAfter: wait,
        }),
      };
    }
    if (!(await this._pinMatches(code, row.otp_hash))) {
      const upd = await q('UPDATE home_admin_assign_otps SET attempts = attempts + 1 WHERE id = $1 RETURNING attempts', [row.id]);
      const remaining = Math.max(0, OTP_MAX_ATTEMPTS - (Number(upd.rows[0] && upd.rows[0].attempts) || 0));
      return {
        ok: false,
        error: httpError(400, `Hatalı onay kodu. Kalan deneme hakkı: ${remaining}`, 'VALIDATION', {
          body: { remaining_attempts: remaining },
        }),
      };
    }
    await q('DELETE FROM home_admin_assign_otps WHERE id = $1', [row.id]);
    return { ok: true };
  }

  // ===========================================================================
  // 4) Home Admin atama
  // ===========================================================================

  /**
   * Eve yeni Home Admin (owner) atar. Ayrintilar dosya basligindadir.
   * @param {{actor:object, homeId:string, target:{fullName,email,phone}, otpCode?:string, force?:boolean, reason?:string}} p
   */
  async assignAdmin({ actor, homeId, target: targetInput, otpCode, force = false, reason } = {}) {
    const scope = actorScope(actor);
    if (!isUuid(String(homeId || ''))) throw httpError(400, 'Geçersiz daire kimliği (home_id).', 'VALIDATION');
    const target = this._parseTarget(targetInput);

    const forced = force === true || force === 'true';
    let reasonText = null;
    if (forced) {
      if (!scope.isSuper) {
        throw httpError(403, 'Zorla atama yalnızca süper yönetici tarafından yapılabilir.', 'FORBIDDEN');
      }
      reasonText = typeof reason === 'string' ? reason.trim() : '';
      if (reasonText.length < FORCE_REASON_MIN_LENGTH) {
        throw httpError(400, `Zorla atama için gerekçe en az ${FORCE_REASON_MIN_LENGTH} karakter olmalı.`, 'VALIDATION');
      }
      if (reasonText.length > FORCE_REASON_MAX_LENGTH) {
        throw httpError(400, `Gerekçe en fazla ${FORCE_REASON_MAX_LENGTH} karakter olabilir.`, 'VALIDATION');
      }
    }

    // Yeni hesap gerekirse kullanilamaz rastgele parolanin ozeti (yavas bcrypt) islem DISINDA hesaplanir.
    const preUser = await this._findTargetUser((t, p) => this.db.query(t, p), target);
    const unusableHash =
      !preUser && target.email ? await this.auth._unusablePasswordHash() : null;

    const outcome = await this.db.withTransaction(async (tx) => {
      const q = (text, params) => tx.query(text, params);

      // 1) Evi kilitle: es zamanli atama / devir / acil sifirlama siralanir
      const homeRes = await q('SELECT id, name, mqtt_username FROM homes WHERE id = $1 FOR UPDATE', [homeId]);
      const home = homeRes.rows[0];
      if (!home) throw httpError(404, 'Daire bulunamadı.', 'NOT_FOUND');

      // 2) Islemi yapan: etkin hesap + (staff) bu evde gecerli servis uyeligi
      await this._assertActorMayAct(q, scope, actor, homeId);

      // 3) Mevcut sahipler ve mod
      const owners = await this._loadOwners(q, homeId, { lock: true });
      let mode;
      if (owners.length === 0) {
        mode = MODES.NO_OWNER;
      } else if (forced) {
        mode = MODES.FORCED;
      } else {
        if (owners.length > 1) {
          throw httpError(
            409,
            'Bu dairede birden fazla ev sahibi kayıtlı; onay kodu ile atama yapılamaz. Süper yöneticiye başvurun.',
            'MULTIPLE_OWNERS'
          );
        }
        mode = MODES.OWNER_CONSENT;
      }

      // 4) Hedef hesap (var mi, atanabilir mi) - sayaclara dokunmadan, hatalar rollback eder
      let targetUser = await this._findTargetUser(q, target);
      this._assertTargetAllowed(targetUser, target, actor);
      this._assertNotAlreadySoleOwner(owners, targetUser);

      // 5) Sahibin rizasi (OTP). Basarisiz denemenin sayaci COMMIT edilip hata sonra atilir.
      if (mode === MODES.OWNER_CONSENT) {
        const consent = await this._verifyOwnerConsent(q, { homeId, owner: owners[0], target, otpCode });
        if (!consent.ok) return { ok: false, error: consent.error };
      } else if (mode === MODES.FORCED) {
        // Beklemekte olan sahip onay kodu gecersiz kalir
        await q('DELETE FROM home_admin_assign_otps WHERE home_id = $1', [homeId]);
      }

      // 6) Hedef hesap yoksa 'pending_invite' + kullanilamaz rastgele parola ile ac
      let accountCreated = false;
      if (!targetUser) {
        if (target.phone) {
          const taken = await q('SELECT 1 FROM users WHERE phone = $1', [target.phone]);
          if (taken.rows.length > 0) {
            throw httpError(409, 'Bu telefon numarası başka bir hesapta kayıtlı.', 'CONFLICT');
          }
        }
        const ins = await q(
          `INSERT INTO users (full_name, email, password_hash, phone, role, is_active, account_status, created_by_user_id)
           VALUES ($1, $2, $3, $4, 'user', TRUE, 'pending_invite', $5)
           ON CONFLICT (email) DO NOTHING
           RETURNING id, email, full_name, phone, role, is_active, account_status`,
          [target.fullName, target.email, unusableHash, target.phone, actor.userId]
        );
        if (ins.rows.length > 0) {
          targetUser = ins.rows[0];
          accountCreated = true;
        } else {
          // yaris: ayni e-posta bu arada acildi
          targetUser = await this._findTargetUser(q, target);
          if (!targetUser) throw httpError(409, 'Hesap oluşturulamadı. Lütfen tekrar deneyin.', 'CONFLICT');
          this._assertTargetAllowed(targetUser, target, actor);
        }
      }

      // 7) Uyelikler: sahip varsa daire DEVRI (tum uyelikler kalkar; islemi yapan staff'in servis uyeligi haric)
      let removedMemberships = 0;
      if (mode !== MODES.NO_OWNER) {
        const removed = await q(
          `DELETE FROM home_users
            WHERE home_id = $1
              AND ($2::uuid IS NULL OR NOT (user_id = $2::uuid AND role = 'service_user'))
            RETURNING user_id`,
          [homeId, scope.isStaff ? actor.userId : null]
        );
        removedMemberships = (removed.rows || []).length;
      }
      await q(
        `INSERT INTO home_users (home_id, user_id, role)
         VALUES ($1, $2, 'owner')
         ON CONFLICT (home_id, user_id) DO UPDATE
            SET role = 'owner', valid_from = NULL, valid_until = NULL, installer_expires_at = NULL`,
        [homeId, targetUser.id]
      );

      // 8) Cihaz / envanter sahipligi
      await q('UPDATE device_inventory SET claimed_by_user_id = $1 WHERE claimed_home_id = $2', [targetUser.id, homeId]);
      await q('UPDATE devices SET claimed_by = $1 WHERE home_id = $2', [targetUser.id, homeId]);

      // 9) Erisim iptali (bu eve ozgu): servis PIN/oturumlari her modda; devirde ayrica evin uygulama MQTT
      //    kimlikleri ve davet/kural/bekleyen devir temizligi
      const service = await this.serviceTokens.revokeHomeServiceAccess(homeId, tx, 'admin_assigned');
      let usernames = [];
      let cleanup = null;
      if (mode !== MODES.NO_OWNER) {
        const revoked = await this.mqtt.revokeHomeAccess({ homeId, tx });
        usernames = (revoked && revoked.usernames) || [];
        cleanup = await this.cleanup.cleanupHome(tx, homeId, { keepEndpoints: true });
      }

      // 10) Denetim kaydi (kod/parola YOK)
      await q(
        `INSERT INTO home_admin_assignment_logs
                (home_id, home_name, actor_user_id, actor_role, ip_address, mode, previous_owner_ids, new_owner_id, account_created, reason)
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)`,
        [
          homeId,
          home.name,
          actor.userId,
          actor.globalRole,
          actor.ip || null,
          mode,
          JSON.stringify(owners.map((o) => o.id)),
          targetUser.id,
          accountCreated,
          reasonText,
        ]
      );

      return {
        ok: true,
        home,
        mode,
        owners,
        targetUser,
        accountCreated,
        removedMemberships,
        service,
        usernames,
        cleanup,
      };
    });

    if (!outcome.ok) throw outcome.error;

    // --- Commit SONRASI yan etkiler (hicbiri atamayi bozmaz; hatalar `warnings` olarak doner) ---
    const warnings = [];
    const mw = this.authMiddleware;
    if (mw && typeof mw.invalidateServiceSessionCache === 'function') mw.invalidateServiceSessionCache();

    if (outcome.usernames.length > 0) {
      try {
        const kick = await this.mqtt.kickUsernames(outcome.usernames);
        if (kick && kick.failed > 0) {
          warnings.push(`${kick.failed} MQTT bağlantısı atılamadı; kimlikler silindi, açık bağlantılar yeniden doğrulamada düşer.`);
        } else if (kick && kick.skipped) {
          warnings.push('EMQX yönetim API ayarı yok; açık MQTT bağlantıları atılamadı (kimlikler silindi).');
        }
      } catch (_) {
        warnings.push('MQTT bağlantıları atılamadı; kimlikler silindi.');
      }
    }

    // Yeni sahibe: hesap kurulum daveti (pending_invite) veya bilgilendirme (etkin hesap)
    let inviteSent = null;
    const t = outcome.targetUser;
    try {
      if (t.account_status === 'pending_invite') {
        const invite = await this.auth.createAccountSetupInvite(t.id);
        inviteSent = Boolean(invite && invite.sent);
        if (!inviteSent) {
          warnings.push(
            'Hesap etkinleştirme e-postası gönderilemedi; kullanıcı uygulamada "Şifremi unuttum" ile hesabını etkinleştirebilir.'
          );
        }
      } else if (isDeliverableEmail(t.email)) {
        const note = await this.mailer.sendHomeAdminAssignedEmail({ to: t.email, fullName: t.full_name, homeName: outcome.home.name });
        inviteSent = Boolean(note && note.sent);
      }
    } catch (_) {
      inviteSent = false;
      if (t.account_status === 'pending_invite') warnings.push('Hesap etkinleştirme e-postası gönderilemedi.');
    }

    // Onceki sahibe (yalniz zorla atamada): ona sorulmadan devredildi
    if (outcome.mode === MODES.FORCED) {
      for (const o of outcome.owners) {
        if (!isDeliverableEmail(o.email)) continue;
        try {
          await this.mailer.sendOwnerReassignedNoticeEmail({ to: o.email, fullName: o.full_name, homeName: outcome.home.name });
        } catch (_) {
          /* bildirim en iyi cabadir */
        }
      }
    }

    const data = {
      home_id: outcome.home.id,
      home_name: outcome.home.name,
      mode: outcome.mode,
      new_owner: {
        id: t.id,
        full_name: t.full_name,
        email: isDeliverableEmail(t.email) ? t.email : null,
        phone: t.phone || null,
        account_status: t.account_status,
      },
      account_created: outcome.accountCreated,
      invite_sent: inviteSent,
      previous_owner_count: outcome.owners.length,
      revoked: {
        memberships: outcome.removedMemberships,
        service_pins: (outcome.service && outcome.service.revoked_pins) || 0,
        service_sessions: (outcome.service && outcome.service.revoked_sessions) || 0,
        app_credentials: outcome.usernames.length,
      },
      message:
        outcome.mode === MODES.NO_OWNER
          ? `${t.full_name} "${outcome.home.name}" dairesinin Home Admin'i olarak atandı.`
          : `"${outcome.home.name}" dairesinin yönetimi ${t.full_name} adlı kullanıcıya devredildi. Önceki erişimler kaldırıldı.`,
    };
    if (warnings.length > 0) {
      data.warnings = warnings;
      data.partial = true;
    }
    return data;
  }
}

module.exports = new ServicePanelService();
module.exports.ServicePanelService = ServicePanelService;
module.exports.MODES = MODES;
module.exports.constants = Object.freeze({
  OTP_TTL_SECONDS,
  OTP_RESEND_COOLDOWN_SECONDS,
  OTP_MAX_ATTEMPTS,
  OTP_ATTEMPT_WINDOW_MINUTES,
  FORCE_REASON_MIN_LENGTH,
  DEFAULT_PAGE_SIZE,
  MAX_PAGE_SIZE,
});
module.exports.isDeliverableEmail = isDeliverableEmail;
