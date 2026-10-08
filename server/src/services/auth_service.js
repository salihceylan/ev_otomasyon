'use strict';

// ==============================================================================
// AHBU Akilli Ev - Kimlik dogrulama servisi (WP-A: A4 + A5)
// ==============================================================================
//
// Sozlesme: docs/CONTRACTS.md §1.2
//  - Access token: 15 dk JWT (sub, role, tv, iat, exp, iss) -> middlewares/jwt_config
//  - Refresh token: OPAK rastgele deger; DB'de YALNIZCA SHA-256 ozeti; her kullanimda doner
//    (rotation); kullanilmis token tekrar gelirse AILE (family_id) iptal edilir; 30 gun.
//  - Sifre: en az 10 karakter (en fazla 72 bayt - bcrypt siniri), bcrypt cost 12.
//  - Sifre degisimi / sifirlama / dondurma -> refresh token'lar iptal + token_version++ + TUM evlerdeki uygulama
//    MQTT kimlikleri silinir (ayni transaction), acik baglantilar COMMIT sonrasi atilir (UYELIK-02).
//  - Yer tutucu e-posta (telefon-OTP / Apple gizli / silinmis) disari donen kullanici nesnesinde null (UYELIK-07).
//  - Google / Apple: YALNIZCA dogrulanmis kimlik jetonu (imza + aud + iss + exp + email_verified).
//    Jeton yok/gecersiz -> giris REDDEDILIR. Istemciden gelen e-posta/kimlik alanina GUVENILMEZ.
//  - OTP / sifirlama kodlari: crypto.randomInt, DB'de HMAC(PIN_PEPPER) ozeti; yeniden istek 60 sn
//    + saatte 5; deneme sayaci ATOMIK ve yeniden gonderimle SIFIRLANMAZ; kod/token LOG'LANMAZ;
//    debug_* alanlari yalnizca ALLOW_DEBUG_OTP=true VE NODE_ENV!=='production'.
//  - Sihirli baglanti GET ile oturum ACMAZ: POST + tek kullanim.
//  - Yasal metinler (migration 039, services/legal_service): disari donen kullanici nesnesi `legal`
//    {terms_accepted_version, terms_current_version, terms_status, needs_acceptance} tasir. Kayitta accept_terms_version
//    guncel surumse kabul hesapla AYNI transaction'da yazilir; farkliysa 409 LEGAL_VERSION_MISMATCH, hesap ACILMAZ.

const crypto = require('crypto');
const bcrypt = require('bcryptjs');
const db = require('../db');
const { HttpError, generateNumericPin, sha256Hex, isUuid } = require('../utils/helpers');
const jwtConfig = require('../middlewares/jwt_config');
const { invalidateUserAuthCache, invalidateServiceSessionCache } = require('../middlewares/auth_middleware');
const pin = require('../utils/pin');
const mailer = require('../utils/mailer');
// Yalniz saf yardimci (modul yuklenirken db/auth_service gerektirmez; silme servisi auth_service'i tembel kullanir).
const { isPlaceholderEmail } = require('./account_deletion_service');
// Saf yardimcilar + varsayilan belge servisi (modul yuklenirken db gerektirmez).
const { legalUserState, parseVersionInput, getDefaultLegalService } = require('./legal_service');

// ---------------------------------------------------------------------------
// Sabitler
// ---------------------------------------------------------------------------
const PASSWORD_MIN_LENGTH = 10;
const PASSWORD_MAX_BYTES = 72;
const RESEND_COOLDOWN_SEC = 60;
const MAX_SENDS_PER_HOUR = 5;
const MAX_CODE_ATTEMPTS = 5;
const ACCOUNT_SETUP_TTL_SEC = 72 * 3600;
const ADMIN_RESET_TTL_SEC = 60 * 60;
// Oturum iptali sonrasi push belirteci devre disi birakma: yanit en cok bu kadar bekler (plan §5d-1).
const PUSH_REVOKE_TIMEOUT_MS = 3000;
// Oturum iptali sonrasi MQTT baglanti atma (EMQX REST): yanit en cok bu kadar bekler, atma arka planda surer.
const MQTT_KICK_WAIT_MS = 5000;
const TIMED_OUT = Symbol('push_revoke_timed_out');
const GOOGLE_ISSUERS = ['accounts.google.com', 'https://accounts.google.com'];
const APPLE_ISSUER = 'https://appleid.apple.com';
const APPLE_JWKS_URL = 'https://appleid.apple.com/auth/keys';
const DEFAULT_APP_PUBLIC_URL = 'https://evotomasyon.gudeteknoloji.com.tr';
const EMAIL_RE = /^[^\s@<>()[\]\\,;:"]+@[^\s@<>()[\]\\,;:"]+\.[^\s@<>()[\]\\,;:"]{2,}$/;
const BCRYPT_HASH_RE = /^\$2[aby]\$\d{2}\$[./A-Za-z0-9]{53}$/;

// terms_version (migration 039) to_jsonb ile okunur: 039 uygulanmamis veritabaninda da giris / kayit / profil sorgulari
// calisir (alan NULL; yanlis dagitim sirasinda kimlik yolu kopmasin). Yazim yolu (legal_service) kolonu dogrudan kullanir
// ve sema-sozlesme denetcisi onu denetler. Tum USER_COLS sorgulari tabloyu takma adsiz `users` olarak anar.
const USER_COLS = `id, email, full_name, phone, role, is_active, account_status, token_version,
  must_change_password, email_verified, google_id, apple_id, (to_jsonb(users) ->> 'terms_version')::int AS terms_version`;

// bcrypt cost: uretimde HER ZAMAN 12. Yalnizca NODE_ENV=test iken BCRYPT_TEST_COST ile
// testleri hizlandirmak icin dusurulebilir.
function bcryptCost() {
  if (process.env.NODE_ENV === 'test' && /^\d+$/.test(String(process.env.BCRYPT_TEST_COST || ''))) {
    return Math.max(4, Math.min(12, Number(process.env.BCRYPT_TEST_COST)));
  }
  return 12;
}

function isDebugOtpAllowed() {
  return process.env.ALLOW_DEBUG_OTP === 'true' && process.env.NODE_ENV !== 'production';
}

/**
 * Yaniti kaybolan yenilemenin tekrar toleransi (uyelik-2, sn). Varsayilan 3600: arka plan alarm servisinin 15 dk'lik
 * yenileme araligini ve yeniden denemelerini kapsar. 0 = kapali (eski davranis: her tekrar aile iptali). En cok 1 gun.
 */
function refreshRetryGraceSec() {
  const raw = process.env.REFRESH_RETRY_GRACE_SEC;
  if (raw === undefined || raw === null || String(raw).trim() === '') return 3600;
  const n = Number(raw);
  if (!Number.isFinite(n) || n < 0) return 3600;
  return Math.min(86400, Math.floor(n));
}

function csvEnv(name) {
  return String(process.env[name] || '')
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean);
}

function appPublicUrl() {
  return String(process.env.APP_PUBLIC_URL || DEFAULT_APP_PUBLIC_URL).replace(/\/+$/, '');
}

function httpError(status, message, code, extra) {
  const err = new HttpError(status, message, code);
  if (extra && typeof extra === 'object') {
    if (Number.isFinite(extra.retryAfter)) err.retryAfter = extra.retryAfter;
    if (extra.expose === true) err.expose = true;
    if (extra.body) err.extra = extra.body;
  }
  return err;
}

function invalidCredentials() {
  return httpError(401, 'Geçersiz e-posta / telefon veya şifre.', 'INVALID_CREDENTIALS');
}

// ---------------------------------------------------------------------------
// Normalizasyon yardimcilari (diger servisler de kullanir)
// ---------------------------------------------------------------------------
function normalizeEmail(value) {
  if (typeof value !== 'string') return null;
  const s = value.trim().toLowerCase();
  if (!s || s.length > 254 || !EMAIL_RE.test(s)) return null;
  return s;
}

function normalizePhone(value) {
  if (value === null || value === undefined) return null;
  if (typeof value !== 'string' && typeof value !== 'number') return null;
  const s = String(value).trim().replace(/[\s\-().]/g, '');
  if (!/^\+?\d{10,15}$/.test(s)) return null;
  return s;
}

/** E-posta ya da telefon. Gecersizse null. */
function parseIdentifier(raw) {
  if (typeof raw !== 'string' && typeof raw !== 'number') return null;
  const s = String(raw).trim();
  if (!s) return null;
  if (s.includes('@')) {
    const email = normalizeEmail(s);
    return email ? { kind: 'email', value: email } : null;
  }
  const phone = normalizePhone(s);
  return phone ? { kind: 'phone', value: phone } : null;
}

function normalizeFullName(value, fallback = null) {
  if (typeof value !== 'string') return fallback;
  // Kontrol karakterleri temizlenir.
  // eslint-disable-next-line no-control-regex
  const s = value.replace(/[\u0000-\u001f\u007f]/g, ' ').replace(/\s+/g, ' ').trim();
  if (s.length < 2) return fallback;
  return s.slice(0, 100);
}

function validatePassword(password) {
  if (typeof password !== 'string' || password.length === 0) {
    throw httpError(400, 'Şifre zorunludur.', 'VALIDATION');
  }
  if (password.length < PASSWORD_MIN_LENGTH) {
    throw httpError(400, `Şifre en az ${PASSWORD_MIN_LENGTH} karakter olmalıdır.`, 'VALIDATION');
  }
  if (Buffer.byteLength(password, 'utf8') > PASSWORD_MAX_BYTES) {
    throw httpError(400, `Şifre en fazla ${PASSWORD_MAX_BYTES} bayt olabilir.`, 'VALIDATION');
  }
  if (!password.trim()) {
    throw httpError(400, 'Şifre yalnızca boşluktan oluşamaz.', 'VALIDATION');
  }
}

function isValidCodeFormat(code) {
  return typeof code === 'string' && /^\d{6}$/.test(code.trim());
}

/** @param {object} legal  AuthService._legalState(user) (legal_service.legalUserState) */
function publicUser(user, legal) {
  return {
    id: user.id,
    // Teslim edilemeyen yer tutucu e-posta disari VERILMEZ (istemci "Belirtilmedi" gosterir); DB satiri aynen kalir.
    email: isPlaceholderEmail(user.email) ? null : user.email,
    full_name: user.full_name,
    phone: user.phone || null,
    role: user.role || 'user',
    must_change_password: Boolean(user.must_change_password),
    email_verified: Boolean(user.email_verified),
    legal,
  };
}

function homeAccessState(row, nowMs) {
  if (row.role === 'service_user') {
    // Sureli teknisyen uyeligi (WP-B: kurulum sonrasi installer_expires_at).
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

// ---------------------------------------------------------------------------
// Kimlik saglayici dogrulayicilari (varsayilan: gercek kutuphaneler; testte enjekte edilir)
// ---------------------------------------------------------------------------
let googleClient = null;
let appleJwks = null;

/**
 * Google ID token dogrulama: imza (Google sertifikalari), aud (izinli istemci kimlikleri),
 * iss, exp. `certs` verilirse (test) uzak sertifika yerine onlar kullanilir.
 */
async function verifyGoogleIdToken(idToken, { audiences, certs } = {}) {
  const { OAuth2Client } = require('google-auth-library');
  if (!googleClient) googleClient = new OAuth2Client();
  let ticket;
  if (certs) {
    ticket = await googleClient.verifySignedJwtWithCertsAsync(idToken, certs, audiences, GOOGLE_ISSUERS);
  } else {
    ticket = await googleClient.verifyIdToken({ idToken, audience: audiences });
  }
  return ticket.getPayload();
}

/**
 * Apple identity token dogrulama: JWKS imzasi (RS256), iss, aud, exp.
 * `jwks` verilirse (test) uzak anahtar seti yerine o kullanilir.
 */
async function verifyAppleIdentityToken(identityToken, { audiences, jwks } = {}) {
  const { createRemoteJWKSet, jwtVerify } = require('jose');
  if (!jwks && !appleJwks) appleJwks = createRemoteJWKSet(new URL(APPLE_JWKS_URL));
  const { payload } = await jwtVerify(identityToken, jwks || appleJwks, {
    issuer: APPLE_ISSUER,
    audience: audiences,
    algorithms: ['RS256'],
  });
  return payload;
}

const defaultVerifiers = {
  google: (token, audiences) => verifyGoogleIdToken(token, { audiences }),
  apple: (token, audiences) => verifyAppleIdentityToken(token, { audiences }),
};

// ---------------------------------------------------------------------------
// Servis
// ---------------------------------------------------------------------------
class AuthService {
  constructor() {
    this._verifiers = { ...defaultVerifiers };
    this._smsSender = null;
    this._dummyHashPromise = null;
    // undefined: ilk kullanimda varsayilan ornek kurulur; null: bilincli devre disi (modul yok / test)
    this._pushService = undefined;
    // undefined: varsayilan mqtt_credential_service modulu; null: bilincli devre disi (modul yok / test)
    this._mqttCredentials = undefined;
    // Yasal metin servisi (legal_service); server.js createApp() uygulamanin ornegini verir. Yoksa varsayilan (server/legal).
    this._legal = null;
  }

  /** server.js createApp() ve testler: publicUser.legal ve kayittaki sozlesme kabulu bu servisi kullanir. */
  setLegalService(svc) {
    this._legal = svc || null;
  }

  _getLegal() {
    return this._legal || getDefaultLegalService();
  }

  /** publicUser.legal. Belge servisi hata verse de giris / profil BOZULMAZ (alanlar null, onay istenmez). */
  _legalState(user) {
    let terms = null;
    try {
      terms = this._getLegal().getTermsState();
    } catch (err) {
      console.warn(`[AUTH] Yasal metin durumu okunamadi (${(err && err.name) || 'hata'}); legal alanlari bos donuyor.`);
      terms = null;
    }
    return legalUserState(user, terms);
  }

  // ----------------------------- DI / test ---------------------------------
  setIdentityVerifiers({ google, apple } = {}) {
    if (typeof google === 'function') this._verifiers.google = google;
    if (typeof apple === 'function') this._verifiers.apple = apple;
  }

  resetIdentityVerifiers() {
    this._verifiers = { ...defaultVerifiers };
  }

  /** SMS gonderici: async (phone, text) => ({ sent:boolean }) . Yoksa SMS gonderilemez. */
  setSmsSender(fn) {
    this._smsSender = typeof fn === 'function' ? fn : null;
  }

  /**
   * MQTT kimlik servisi (`mqtt_credential_service` ornegi; `revokeAllUserAccess`, `kickUsernames` ve yonetici kalici
   * silmesinde `revokeHomeAccess` kullanilir). `undefined` verilirse varsayilan modul kullanilir, `null` verilirse
   * MQTT kimlik iptali ATLANIR (modul yok / test). admin_user_service ayni ornegi buradan alir.
   */
  setMqttCredentialService(svc) {
    this._mqttCredentials = svc === undefined ? undefined : svc;
  }

  getMqttCredentialService() {
    if (this._mqttCredentials !== undefined) return this._mqttCredentials;
    try {
      return require('./mqtt_credential_service');
    } catch (err) {
      if (err && err.code === 'MODULE_NOT_FOUND' && /mqtt_credential_service/.test(String(err.message))) return null;
      throw err;
    }
  }

  /**
   * Push servisi (`push_service.createPushService` ornegi; yalnizca `disableAllTokensForUser` kullanilir).
   * server.js createApp() uygulamanin ornegini verir. `undefined` verilirse varsayilan ornek tembel kurulur,
   * `null` verilirse push belirteci devre disi birakma ATLANIR (modul yok / test).
   */
  setPushService(svc) {
    this._pushService = svc === undefined ? undefined : svc;
  }

  _getPushService() {
    if (this._pushService !== undefined) return this._pushService;
    try {
      // Belirteci devre disi birakmak yalnizca veritabani islemidir: FCM yapilandirmasi GEREKTIRMEZ.
      const { createPushService } = require('./push_service');
      this._pushService = createPushService({ db });
    } catch (_) {
      this._pushService = null; // modul yuklenemedi: sessizce atla
    }
    return this._pushService;
  }

  // ----------------------------- Yetenekler (UYELIK-04) --------------------
  // Asagidaki kosullar ilgili uclarin 503 kosullarinin TEK kaynagidir (sendPhoneOtp, loginWithGoogle,
  // loginWithApple); GET /auth/capabilities ayni kosullari istemciye bildirir.
  _googleAudiences() {
    return csvEnv('GOOGLE_CLIENT_IDS');
  }

  _appleAudiences() {
    return csvEnv('APPLE_CLIENT_IDS');
  }

  /** Telefon OTP gonderilebilir mi: SMS gonderici bagli VEYA debug OTP izinli (uretimde asla). */
  _canSendPhoneOtp() {
    return Boolean(this._smsSender) || isDebugOtpAllowed();
  }

  /** GET /auth/capabilities: giris yollari sunucuda 503 vermeden calisir mi (yalniz boolean; sir/ayrinti yok). */
  getCapabilities() {
    return {
      sms_otp: this._canSendPhoneOtp(),
      google: this._googleAudiences().length > 0,
      apple: this._appleAudiences().length > 0,
    };
  }

  // ----------------------------- Yardimcilar --------------------------------
  _hashToken(token) {
    return sha256Hex(token);
  }

  async hashPassword(password) {
    validatePassword(password);
    return bcrypt.hash(password, bcryptCost());
  }

  async _unusablePasswordHash() {
    return bcrypt.hash(crypto.randomBytes(32).toString('hex'), bcryptCost());
  }

  _getDummyHash() {
    if (!this._dummyHashPromise) {
      this._dummyHashPromise = bcrypt.hash(crypto.randomBytes(16).toString('hex'), bcryptCost());
    }
    return this._dummyHashPromise;
  }

  /** Kullanici bulunamasa da ayni sure harcanir (zamanlama ile hesap tespiti engellenir). */
  async _dummyCompare(password) {
    try {
      await bcrypt.compare(typeof password === 'string' ? password : 'x', await this._getDummyHash());
    } catch (_) {
      // yok sayilir
    }
  }

  async _comparePassword(password, hash) {
    if (typeof password !== 'string' || !password || typeof hash !== 'string' || !BCRYPT_HASH_RE.test(hash)) {
      await this._dummyCompare(password);
      return false;
    }
    try {
      return await bcrypt.compare(password, hash);
    } catch (_) {
      return false;
    }
  }

  async _findUserById(q, userId) {
    if (!isUuid(String(userId || ''))) return null;
    const r = await q.query(`SELECT ${USER_COLS} FROM users WHERE id = $1`, [userId]);
    return r.rows[0] || null;
  }

  _assertUserCanSignIn(user) {
    // 'deleted' (hesap silme, migration 027): anonimlestirilmis hesap ASLA oturum acamaz (derinlemesine savunma;
    // parola/kimlik zaten kullanilamaz, is_active yonetici islemiyle yanlislikla TRUE yapilsa bile).
    if (user.is_active === false || user.account_status === 'suspended' || user.account_status === 'deleted') {
      throw httpError(403, 'Hesabınız askıya alınmış. Destek ile iletişime geçin.', 'ACCOUNT_DISABLED');
    }
    if (user.account_status === 'pending_invite') {
      throw httpError(403, 'Hesabınızı etkinleştirmeniz gerekiyor. E-postanızdaki kodu kullanın.', 'ACCOUNT_PENDING');
    }
  }

  // ----------------------------- Oturum ------------------------------------
  /**
   * Access + refresh token cifti uretir; refresh token yalnizca ozetiyle saklanir.
   * @returns {{ tokens: object, refreshId: string|null }}
   */
  async _issueSession(user, { tx, familyId, ip } = {}) {
    const q = tx || db;
    const accessToken = jwtConfig.signAccessToken({
      id: user.id,
      role: user.role || 'user',
      token_version: user.token_version,
    });
    const refreshToken = crypto.randomBytes(32).toString('base64url');
    const family = familyId && isUuid(String(familyId)) ? familyId : crypto.randomUUID();
    const refreshTtl = jwtConfig.getRefreshTokenTtlSec();
    const expiresAt = new Date(Date.now() + refreshTtl * 1000);
    const ins = await q.query(
      `INSERT INTO refresh_tokens (user_id, token_hash, family_id, expires_at, created_ip)
       VALUES ($1, $2, $3, $4, $5)
       RETURNING id`,
      [user.id, this._hashToken(refreshToken), family, expiresAt, ip ? String(ip).slice(0, 64) : null]
    );
    const accessTtl = jwtConfig.getAccessTokenTtlSec();
    return {
      refreshId: ins.rows[0] ? ins.rows[0].id : null,
      tokens: {
        access_token: accessToken,
        refresh_token: refreshToken,
        token: accessToken, // geriye donuk uyumluluk
        token_type: 'Bearer',
        expires_in: accessTtl,
        refresh_expires_in: refreshTtl,
      },
    };
  }

  /** Eski arayuz (geriye donuk): yeni oturum uretir. */
  async generateTokens(user) {
    const { tokens } = await this._issueSession(user);
    return tokens;
  }

  async listHomesForUser(userId) {
    const r = await db.query(
      `SELECT h.id, h.name, h.address, h.mqtt_username,
              COALESCE(to_jsonb(h) ->> 'timezone', 'Europe/Istanbul') AS timezone,
              hu.role, hu.valid_from, hu.valid_until, hu.installer_expires_at
         FROM home_users hu
         JOIN homes h ON h.id = hu.home_id
         JOIN users u ON u.id = hu.user_id
        WHERE hu.user_id = $1
          AND NOT (hu.role = 'service_user' AND hu.installer_expires_at IS NOT NULL AND hu.installer_expires_at <= NOW())
          -- uyelik-13: personel rolunden dusurulmus hesabin kalmis servis uyeligi listelenmez (erisim zaten yok)
          AND NOT (hu.role = 'service_user' AND u.role NOT IN ('service_user', 'super_user'))
        ORDER BY h.name ASC`,
      [userId]
    );
    const nowMs = Date.now();
    return r.rows.map((row) => {
      const state = homeAccessState(row, nowMs);
      const visibleTopic = state === 'active' ? row.mqtt_username : null;
      const validUntil = row.role === 'service_user' ? (row.installer_expires_at || null) : (row.valid_until || null);
      return {
        id: row.id,
        name: row.name,
        address: row.address || null,
        role: row.role,
        timezone: row.timezone || 'Europe/Istanbul',
        mqtt_topic_id: visibleTopic,
        mqtt_username: visibleTopic, // gecis donemi (istemci mqtt_topic_id'ye gecene kadar)
        valid_from: row.valid_from || null,
        valid_until: validUntil,
        access_state: state,
        is_expired: state !== 'active',
      };
    });
  }

  async listHomesForServiceSession(homeId) {
    const r = await db.query(
      `SELECT h.id, h.name, h.mqtt_username,
              COALESCE(to_jsonb(h) ->> 'timezone', 'Europe/Istanbul') AS timezone
         FROM homes h
        WHERE h.id = $1`,
      [homeId]
    );
    return r.rows.map((row) => ({
      id: row.id,
      name: row.name,
      role: 'service_session',
      timezone: row.timezone || 'Europe/Istanbul',
      mqtt_topic_id: row.mqtt_username,
      mqtt_username: row.mqtt_username,
      access_state: 'active',
      is_expired: false,
    }));
  }

  /**
   * GET /homes ve /auth/me icin. `principal` req.user'dir (servis oturumu dahil).
   */
  async getProfile(principal) {
    if (principal && typeof principal === 'object' && principal.is_service_session) {
      return {
        user: { id: null, role: 'service_session', full_name: principal.technician_name || 'Yetkili Servis' },
        homes: await this.listHomesForServiceSession(principal.home_id),
      };
    }
    const userId = principal && typeof principal === 'object' ? principal.id : principal;
    const user = await this._findUserById(db, userId);
    if (!user) throw httpError(404, 'Kullanıcı bulunamadı.', 'NOT_FOUND');
    return { user: publicUser(user, this._legalState(user)), homes: await this.listHomesForUser(user.id) };
  }

  async _buildUserAuthResponse(user, { ip, tx } = {}) {
    const { tokens } = await this._issueSession(user, { ip, tx });
    return {
      ...tokens,
      user: publicUser(user, this._legalState(user)),
      homes: await this.listHomesForUser(user.id),
    };
  }

  // ----------------------------- Giris / kayit -----------------------------
  async login(identifier, password, { ip } = {}) {
    const id = parseIdentifier(identifier);
    if (!id || typeof password !== 'string' || !password) {
      await this._dummyCompare(password);
      throw invalidCredentials();
    }

    const r = id.kind === 'email'
      ? await db.query(`SELECT ${USER_COLS}, password_hash FROM users WHERE LOWER(email) = $1`, [id.value])
      : await db.query(`SELECT ${USER_COLS}, password_hash FROM users WHERE phone = $1`, [id.value]);

    // Ayni telefonlu birden fazla hesap -> belirsiz, giris reddedilir.
    if (r.rows.length !== 1) {
      await this._dummyCompare(password);
      throw invalidCredentials();
    }

    const user = r.rows[0];
    const ok = await this._comparePassword(password, user.password_hash);
    if (!ok) throw invalidCredentials();

    this._assertUserCanSignIn(user);
    await db.query('UPDATE users SET last_login_at = NOW() WHERE id = $1', [user.id]);
    return this._buildUserAuthResponse(user, { ip });
  }

  /**
   * Yeni hesap. `accept_terms_version` (istege bagli): guncel Kullanici Sozlesmesi surumu olmali; kabul kaydi hesapla
   * AYNI transaction'da yazilir (kabul yazilamazsa hesap da acilmaz). Farkli surum (ya da sozlesme yuklu degil) 409
   * LEGAL_VERSION_MISMATCH + data.current_version ve hesap ACILMAZ; bozuk bicim 400. Alan yoksa hesap kabulsuz acilir.
   */
  async register({ full_name, email, password, phone, accept_terms_version } = {}, { ip, userAgent } = {}) {
    const name = normalizeFullName(full_name);
    if (!name) throw httpError(400, 'Ad soyad en az 2 karakter olmalıdır.', 'VALIDATION');
    const cleanEmail = normalizeEmail(email);
    if (!cleanEmail) throw httpError(400, 'Geçerli bir e-posta adresi giriniz.', 'VALIDATION');
    let cleanPhone = null;
    if (phone !== undefined && phone !== null && String(phone).trim() !== '') {
      cleanPhone = normalizePhone(phone);
      if (!cleanPhone) throw httpError(400, 'Geçerli bir telefon numarası giriniz.', 'VALIDATION');
    }
    validatePassword(password);
    const termsVersion = parseVersionInput(accept_terms_version, { optional: true });
    const legal = termsVersion === null ? null : this._getLegal();
    if (legal) legal.assertCurrentTermsVersion(termsVersion); // 409: hesap kontrolunden ONCE (istemci surumu yeniler)

    const existingEmail = await db.query('SELECT id FROM users WHERE LOWER(email) = $1', [cleanEmail]);
    if (existingEmail.rows.length > 0) {
      throw httpError(409, 'Bu e-posta adresi zaten kayıtlı. Giriş yapın veya şifrenizi sıfırlayın.', 'CONFLICT');
    }
    if (cleanPhone) {
      const existingPhone = await db.query('SELECT id FROM users WHERE phone = $1', [cleanPhone]);
      if (existingPhone.rows.length > 0) {
        throw httpError(409, 'Bu telefon numarası zaten kayıtlı.', 'CONFLICT');
      }
    }

    const passwordHash = await bcrypt.hash(password, bcryptCost());
    const createUser = async (q) => {
      const ins = await q.query(
        `INSERT INTO users (full_name, email, password_hash, phone, role, is_active, account_status, password_changed_at)
         VALUES ($1, $2, $3, $4, 'user', TRUE, 'active', NOW())
         RETURNING ${USER_COLS}`,
        [name, cleanEmail, passwordHash, cleanPhone]
      );
      const row = ins.rows[0];
      if (!legal) return row;
      const accepted = await legal.recordAcceptance(q, { userId: row.id, document: 'terms', version: termsVersion, ip, userAgent });
      return { ...row, terms_version: accepted.version };
    };
    let user;
    try {
      user = legal ? await db.withTransaction(createUser) : await createUser(db);
    } catch (err) {
      if (err && err.code === '23505') {
        throw httpError(409, 'Bu e-posta veya telefon zaten kayıtlı.', 'CONFLICT');
      }
      throw err;
    }
    return this._buildUserAuthResponse(user, { ip });
  }

  // ----------------------------- Refresh rotation --------------------------
  async refreshToken(rawToken, { ip } = {}) {
    if (typeof rawToken !== 'string' || rawToken.length < 20 || rawToken.length > 4096) {
      throw httpError(401, 'Geçersiz oturum. Lütfen tekrar giriş yapın.', 'INVALID_TOKEN');
    }
    const tokenHash = this._hashToken(rawToken);

    const outcome = await db.withTransaction(async (tx) => {
      const upd = await tx.query(
        `UPDATE refresh_tokens
            SET used_at = NOW()
          WHERE token_hash = $1
            AND used_at IS NULL
            AND revoked_at IS NULL
            AND expires_at > NOW()
          RETURNING id, user_id, family_id`,
        [tokenHash]
      );

      if (upd.rows.length === 0) {
        const ex = await tx.query(
          `SELECT id, user_id, family_id, used_at, revoked_at, revoked_reason, replaced_by,
                  (used_at IS NOT NULL AND used_at > NOW() - make_interval(secs => $2::int)) AS within_grace
             FROM refresh_tokens WHERE token_hash = $1
             FOR UPDATE`,
          [tokenHash, refreshRetryGraceSec()]
        );
        const row = ex.rows[0];
        // Yaniti kaybolan yenilemenin tekrari (uyelik-2): istemci R1'i kullandi, sunucu R2'yi uretti ama yanit
        // ulasmadi. R2 HIC kullanilmadiysa ve tolerans icindeysek bu calinma degil yeniden denemedir: R2
        // 'retry_superseded' ile iptal edilir, AYNI aileden yeni cift doner. R2 sonradan sunulursa aile iptal edilir.
        if (row && row.revoked_reason !== 'retry_superseded' && row.used_at && !row.revoked_at && row.replaced_by && row.within_grace === true) {
          const succ = await tx.query('SELECT id, used_at, revoked_at FROM refresh_tokens WHERE id = $1 FOR UPDATE', [row.replaced_by]);
          const s = succ.rows[0];
          if (s && !s.used_at && !s.revoked_at) {
            await tx.query(
              `UPDATE refresh_tokens SET revoked_at = NOW(), revoked_reason = 'retry_superseded'
                WHERE id = $1 AND revoked_at IS NULL`,
              [s.id]
            );
            const user = await this._findUserById(tx, row.user_id);
            if (!user || user.is_active === false || user.account_status !== 'active') {
              await tx.query(
                `UPDATE refresh_tokens SET revoked_at = NOW(), revoked_reason = 'inactive'
                  WHERE family_id = $1 AND revoked_at IS NULL`,
                [row.family_id]
              );
              return { status: 'invalid' };
            }
            const { tokens, refreshId } = await this._issueSession(user, { tx, familyId: row.family_id, ip });
            if (refreshId) {
              await tx.query('UPDATE refresh_tokens SET replaced_by = $1 WHERE id = $2', [refreshId, row.id]);
            }
            return { status: 'ok', tokens, user, retried: true };
          }
        }
        if (row && (row.used_at || row.revoked_reason === 'retry_superseded')) {
          // Yeniden kullanim: calinmis olabilir -> tum aile iptal (COMMIT edilmesi icin hata firlatilmaz).
          await tx.query(
            `UPDATE refresh_tokens
                SET revoked_at = NOW(), revoked_reason = 'reuse_detected'
              WHERE family_id = $1 AND revoked_at IS NULL`,
            [row.family_id]
          );
          return { status: 'reuse', userId: row.user_id };
        }
        return { status: 'invalid' };
      }

      const row = upd.rows[0];
      const user = await this._findUserById(tx, row.user_id);
      if (!user || user.is_active === false || user.account_status !== 'active') {
        await tx.query(
          `UPDATE refresh_tokens SET revoked_at = NOW(), revoked_reason = 'inactive'
            WHERE family_id = $1 AND revoked_at IS NULL`,
          [row.family_id]
        );
        return { status: 'invalid' };
      }

      const { tokens, refreshId } = await this._issueSession(user, { tx, familyId: row.family_id, ip });
      if (refreshId) {
        await tx.query('UPDATE refresh_tokens SET replaced_by = $1 WHERE id = $2', [refreshId, row.id]);
      }
      return { status: 'ok', tokens, user };
    });

    if (outcome.status === 'reuse') {
      console.warn(`[AUTH] Refresh token yeniden kullanimi tespit edildi; oturum ailesi iptal edildi (kullanici ${outcome.userId}).`);
      throw httpError(401, 'Oturumunuz güvenlik nedeniyle sonlandırıldı. Lütfen tekrar giriş yapın.', 'INVALID_TOKEN');
    }
    if (outcome.status !== 'ok') {
      throw httpError(401, 'Geçersiz veya süresi dolmuş oturum. Lütfen tekrar giriş yapın.', 'INVALID_TOKEN');
    }
    if (outcome.retried) {
      console.warn(`[AUTH] Yanitlari kaybolan yenileme yeniden denendi (kullanici ${outcome.user.id}).`);
    }
    return { ...outcome.tokens, must_change_password: Boolean(outcome.user.must_change_password) };
  }

  /** Logout: bu cihazin oturum ailesini iptal eder (token sahipligi yeterli yetkidir). */
  async revokeToken(rawToken) {
    if (typeof rawToken !== 'string' || !rawToken || rawToken.length > 4096) return;
    await db.query(
      `UPDATE refresh_tokens
          SET revoked_at = NOW(), revoked_reason = 'logout'
        WHERE family_id IN (SELECT family_id FROM refresh_tokens WHERE token_hash = $1)
          AND revoked_at IS NULL`,
      [this._hashToken(rawToken)]
    );
  }

  /**
   * Kullanicinin TUM oturumlarini sonlandirir: refresh token'lar iptal + token_version++ (mevcut access token'lar
   * en gec onbellek suresi icinde gecersiz olur) + TUM evlerdeki uygulama MQTT kimlikleri silinir (UYELIK-02: diger
   * cihazin acik canli kanali da kesilir; EMQX kimligi token_version'i bilmez). Hepsi TEK transaction'dadir.
   *
   * PUSH BELIRTECI GIZLILIGI (plan §5d-1): oturumlar kapaninca kullanicinin push belirteclerinin de devre disi
   * kalmasi gerekir; aksi halde gece bildirimi (ev adi + acik lamba ozeti) cikis yapmis telefona duser.
   *  - `tx` YOKSA (ornegin /auth/logout-all) servis kendi transaction'ini acar; COMMIT SONRASI belirtecler devre
   *    disi birakilir ve acik MQTT baglantilari atilir (en iyi caba: hata yaniti bozmaz).
   *  - `tx` VARSA cagiran COMMIT'ten SONRA `revokePushTokens(userId)` ve donen `mqttUsernames` icin
   *    `kickMqttUsernames(...)` cagirmalidir (transaction icinde dis cagri/ikinci baglanti yok; tx geri alinirsa
   *    belirtece / baglantiya dokunulmaz).
   * SERVIS PIN'LERI (uyelik-7): reason 'role_changed' DISINDA kullanicinin urettigi kullanilmamis servis PIN'leri ve
   * bunlarla acilmis servis oturumlari da ayni transaction'da kapanir; o evlerin servis oturumu MQTT kimlikleri
   * (user_id bos) silinir (adlar `mqttUsernames`e eklenir). `tx` ile cagiran, `serviceSessionsRevoked` ise COMMIT
   * SONRASI `invalidateServiceSessionCache()` cagirir (tx'siz yolda servis kendisi yapar).
   * @param {string} userId
   * @param {{tx?:object, reason?:string, bumpTokenVersion?:boolean, disablePushTokens?:boolean}} [opts]
   * @returns {Promise<{mqttUsernames:string[], serviceSessionsRevoked:boolean}>} tx ile: COMMIT sonrasi atilacak
   *   adlar; tx'siz: bos (atildi)
   */
  async revokeAllUserSessions(userId, { tx, reason = 'revoke_all', bumpTokenVersion = true, disablePushTokens } = {}) {
    if (!userId) return { mqttUsernames: [], serviceSessionsRevoked: false };
    if (!tx) {
      const out = await db.withTransaction((t) =>
        this.revokeAllUserSessions(userId, { tx: t, reason, bumpTokenVersion, disablePushTokens: false })
      );
      invalidateUserAuthCache(userId);
      if (out.serviceSessionsRevoked) invalidateServiceSessionCache();
      if (disablePushTokens !== false) await this.revokePushTokens(userId, { reason });
      await this.kickMqttUsernames(out.mqttUsernames, { reason });
      return { mqttUsernames: [], serviceSessionsRevoked: out.serviceSessionsRevoked };
    }
    if (bumpTokenVersion) {
      await tx.query('UPDATE users SET token_version = token_version + 1 WHERE id = $1', [userId]);
    }
    await tx.query(
      `UPDATE refresh_tokens SET revoked_at = NOW(), revoked_reason = $2
        WHERE user_id = $1 AND revoked_at IS NULL`,
      [userId, String(reason).slice(0, 40)]
    );
    const mqttUsernames = await this.revokeUserMqttCredentials(userId, { tx });
    let serviceSessionsRevoked = false;
    if (reason !== 'role_changed') {
      const svc = await this._revokeUserServicePins(userId, { tx, reason });
      mqttUsernames.push(...svc.mqttUsernames);
      serviceSessionsRevoked = svc.sessionsRevoked;
    }
    invalidateUserAuthCache(userId);
    if (disablePushTokens === true) {
      await this.revokePushTokens(userId, { reason });
    }
    return { mqttUsernames, serviceSessionsRevoked };
  }

  /**
   * uyelik-7: kullanicinin urettigi KULLANILMAMIS servis PIN'lerini ve bu PIN'lerle acilmis servis oturumlarini `tx`
   * icinde iptal eder; oturumlarin evlerindeki servis oturumu MQTT kimlikleri (user_id bos) silinir (kick YOK).
   * @returns {Promise<{mqttUsernames:string[], sessionsRevoked:boolean}>}
   */
  async _revokeUserServicePins(userId, { tx, reason }) {
    await tx.query(
      `UPDATE service_tokens SET revoked_at = NOW()
        WHERE created_by = $1 AND revoked_at IS NULL AND used_at IS NULL`,
      [userId]
    );
    const sessions = await tx.query(
      `UPDATE service_sessions SET revoked_at = NOW(), revoked_reason = $2
        WHERE revoked_at IS NULL AND service_token_id IN (SELECT id FROM service_tokens WHERE created_by = $1)
        RETURNING id, home_id`,
      [userId, String(reason).slice(0, 40)]
    );
    const rows = sessions.rows || [];
    const names = [];
    const svc = this.getMqttCredentialService();
    if (svc && typeof svc.revokeServiceSessionAccess === 'function') {
      for (const homeId of [...new Set(rows.map((r) => r.home_id).filter(Boolean))]) {
        const r = await svc.revokeServiceSessionAccess({ homeId, tx });
        if (r && Array.isArray(r.usernames)) names.push(...r.usernames);
      }
    }
    return { mqttUsernames: names, sessionsRevoked: rows.length > 0 };
  }

  /**
   * uyelik-1: personel akislarinda (claim, Home Admin atama, acil sifirlama yeni sahip) DOGRULANMAMIS onceden acilmis
   * hesabi etkisizlestirir (on-hesap ele gecirme savunmasi): baskasinin kaydettigi parola gecersiz, token_version++,
   * aktif hesap 'pending_invite' olur ve TUM oturumlar + uygulama MQTT kimlikleri AYNI tx'te iptal edilir. Dogrulanmis
   * hesaba DOKUNULMAZ. Kullanilamaz bcrypt ozeti (_unusablePasswordHash) yavas oldugu icin tx DISINDA hesaplanip verilir.
   * Cagiran COMMIT SONRASI `finishNeutralize(userId, sonuc, { reason })` cagirir (sosyal giris savunmasina DOKUNULMAZ).
   * @returns {Promise<{neutralized:boolean, mqttUsernames:string[], serviceSessionsRevoked?:boolean}>}
   */
  async neutralizeUnverifiedAccount(userId, { tx, reason = 'unverified_reset', unusableHash } = {}) {
    if (!tx) throw new TypeError('neutralizeUnverifiedAccount: tx zorunludur.');
    if (typeof unusableHash !== 'string' || !BCRYPT_HASH_RE.test(unusableHash)) {
      throw new TypeError('neutralizeUnverifiedAccount: kullanilamaz parola ozeti (unusableHash) zorunludur.');
    }
    const r = await tx.query(
      `UPDATE users
          SET password_hash = $2,
              token_version = token_version + 1,
              must_change_password = FALSE,
              password_changed_at = NULL,
              account_status = CASE WHEN account_status = 'active' THEN 'pending_invite' ELSE account_status END,
              updated_at = CURRENT_TIMESTAMP
        WHERE id = $1 AND email_verified = FALSE
        RETURNING id`,
      [userId, unusableHash]
    );
    if (!r.rows || r.rows.length === 0) return { neutralized: false, mqttUsernames: [] };
    const revoked = await this.revokeAllUserSessions(userId, { tx, reason, bumpTokenVersion: false });
    return {
      neutralized: true,
      mqttUsernames: revoked.mqttUsernames,
      serviceSessionsRevoked: Boolean(revoked.serviceSessionsRevoked),
    };
  }

  /**
   * neutralizeUnverifiedAccount'in COMMIT SONRASI isleri: kimlik onbellegi, push belirtecleri, acik MQTT baglantilari.
   * En iyi caba: ASLA firlatmaz (yaniti bozmaz).
   */
  async finishNeutralize(userId, result, { reason = 'unverified_reset' } = {}) {
    if (!userId || !result || result.neutralized !== true) return;
    try {
      invalidateUserAuthCache(userId);
      if (result.serviceSessionsRevoked) invalidateServiceSessionCache();
      await this.revokePushTokens(userId, { reason });
      await this.kickMqttUsernames(result.mqttUsernames, { reason });
    } catch (_) {
      /* en iyi caba */
    }
  }

  /**
   * Kullanicinin TUM evlerdeki uygulama MQTT kimliklerini `tx` icinde siler (paylasilan yardimci:
   * mqtt_credential_service.revokeAllUserAccess; oturumlarin toplu iptali ve yonetici dondurma/kalici silme kullanir).
   * Ag cagrisi (kick) YAPILMAZ: cagiran COMMIT SONRASI `kickMqttUsernames(usernames)` cagirir. Servis yoksa bos liste.
   * @returns {Promise<string[]>} atilacak kullanici adlari
   */
  async revokeUserMqttCredentials(userId, { tx } = {}) {
    if (!tx) throw new TypeError('revokeUserMqttCredentials: tx zorunludur (baglanti atma COMMIT sonrasi yapilir).');
    const svc = this.getMqttCredentialService();
    if (!userId || !svc || typeof svc.revokeAllUserAccess !== 'function') return [];
    const r = await svc.revokeAllUserAccess({ userId, tx });
    return r && Array.isArray(r.usernames) ? r.usernames.slice() : [];
  }

  /**
   * COMMIT SONRASI: silinen MQTT kimliklerinin acik baglantilarini atar (EMQX REST). En iyi caba: ASLA firlatmaz,
   * yaniti bozmaz ve en cok MQTT_KICK_WAIT_MS bekler (atma arka planda surer). Log'a kullanici adi / hata ayrintisi
   * YAZILMAZ (yalniz neden, sayi ve hata kodu).
   * @returns {Promise<boolean>} tum baglantilar atildi mi (yapilandirma yok / hata / zaman asimi: false)
   */
  async kickMqttUsernames(usernames, { reason = 'sessions_revoked' } = {}) {
    const list = Array.isArray(usernames) ? usernames.filter((u) => typeof u === 'string' && u) : [];
    if (list.length === 0) return true;
    const who = `${String(reason).replace(/[^A-Za-z0-9_.-]/g, '?').slice(0, 30)}, ${list.length} kimlik`;
    let timer = null;
    try {
      const svc = this.getMqttCredentialService();
      if (!svc || typeof svc.kickUsernames !== 'function') return false;
      const limitMs = Number.isFinite(this._mqttKickWaitMs) && this._mqttKickWaitMs > 0
        ? this._mqttKickWaitMs
        : MQTT_KICK_WAIT_MS; // alan yalnizca testlerde ezilir
      const work = Promise.resolve().then(() => svc.kickUsernames(list));
      work.catch(() => {}); // zaman asiminda gec gelen hata yutulur
      const timeout = new Promise((resolve) => {
        timer = setTimeout(() => resolve(TIMED_OUT), limitMs);
        if (typeof timer.unref === 'function') timer.unref();
      });
      const r = await Promise.race([work, timeout]);
      if (r === TIMED_OUT) {
        console.warn(`[AUTH] MQTT baglanti atma zaman asimina ugradi (${who}); arka planda surer.`);
        return false;
      }
      // Yapilandirma yok / kismi hata: mqtt_credential_service zaten uyari yazar.
      return !(r && (r.skipped || r.failed > 0));
    } catch (err) {
      const kind = err && typeof err.code === 'string' && /^[A-Za-z0-9_]{1,12}$/.test(err.code) ? err.code : (err && err.name) || 'Error';
      console.warn(`[AUTH] MQTT baglanti atma basarisiz (${who}): ${kind}`);
      return false;
    } finally {
      if (timer) clearTimeout(timer);
    }
  }

  /**
   * Kullanicinin TUM etkin push belirteclerini devre disi birakir (plan §5d-1). COMMIT SONRASI cagrilir.
   *
   * Kurallar:
   *  - ASLA firlatmaz: push hatasi oturum iptalini / yaniti bozmaz (hata yalnizca loglanir; log'a belirtec,
   *    gövde, e-posta YAZILMAZ — yalnizca hata kodu ve kullanici kimliginin ilk 8 karakteri).
   *  - Push modulu yoksa / `push_tokens` tablosu henuz yoksa (migration 030 uygulanmamis) SESSIZCE atlanir.
   *  - FCM yapilandirmasina BAKILMAZ: belirtec kaydi FCM'den bagimsiz oldugu icin FCM sonradan yapilandirilinca
   *    cikis yapmis telefonlara bildirim gitmesin diye devre disi birakma her durumda yapilir.
   *  - Veritabani takilirsa en cok PUSH_REVOKE_TIMEOUT_MS beklenir (yanit gecikmesin; islem arka planda surer).
   * @returns {Promise<number>} devre disi birakilan satir sayisi (hata/atlama: 0)
   */
  async revokePushTokens(userId, { reason = 'sessions_revoked' } = {}) {
    if (typeof userId !== 'string' || !userId) return 0;
    let svc;
    try {
      svc = this._getPushService();
    } catch (_) {
      return 0;
    }
    if (!svc || typeof svc.disableAllTokensForUser !== 'function') return 0;

    const who = `${String(reason).replace(/[^A-Za-z0-9_.-]/g, '?').slice(0, 30)}, kullanici ${userId.slice(0, 8)}`;
    const limitMs = Number.isFinite(this._pushRevokeTimeoutMs) && this._pushRevokeTimeoutMs > 0
      ? this._pushRevokeTimeoutMs
      : PUSH_REVOKE_TIMEOUT_MS; // alan yalnizca testlerde ezilir
    let timer = null;
    try {
      const work = Promise.resolve().then(() => svc.disableAllTokensForUser(userId));
      const timeout = new Promise((resolve) => {
        timer = setTimeout(() => resolve(TIMED_OUT), limitMs);
        if (typeof timer.unref === 'function') timer.unref();
      });
      // Zaman asiminda `work` arka planda surer; gec gelen hata yutulur (unhandledRejection olmasin).
      work.catch(() => {});
      const r = await Promise.race([work, timeout]);
      if (r === TIMED_OUT) {
        console.warn(`[AUTH] Push belirteci devre disi birakma zaman asimina ugradi (${who}); arka planda surer.`);
        return 0;
      }
      return Number.isFinite(r) ? r : 0;
    } catch (err) {
      if (err && err.code === '42P01') return 0; // push_tokens yok: push henuz kurulmamis
      const kind = err && typeof err.code === 'string' && /^[A-Za-z0-9_]{1,12}$/.test(err.code) ? err.code : (err && err.name) || 'Error';
      console.warn(`[AUTH] Push belirteci devre disi birakilamadi (${who}): ${kind}`);
      return 0;
    } finally {
      if (timer) clearTimeout(timer);
    }
  }

  /**
   * Parolayi ayarlar (bcrypt 12) ve tum oturumlari sonlandirir (uygulama MQTT kimlikleri dahil). Yonetici akislari
   * da kullanir. `tx` ile cagrilirsa silinen MQTT kimlik adlari `revokedMqtt` dizisine eklenir; cagiran COMMIT
   * SONRASI `kickMqttUsernames(revokedMqtt)` cagirir. `revokeInfo` nesnesi verilirse servis oturumu kapandiysa
   * `revokeInfo.serviceSessionsRevoked = true` yazilir (cagiran COMMIT sonrasi invalidateServiceSessionCache; uyelik-7).
   * @returns {Promise<object>} guncel kullanici satiri
   */
  async setPassword(userId, newPassword, { tx, mustChange = false, markEmailVerified = false, activate = false, revokedMqtt, revokeInfo } = {}) {
    validatePassword(newPassword);
    const q = tx || db;
    const hash = await bcrypt.hash(newPassword, bcryptCost());
    const r = await q.query(
      `UPDATE users
          SET password_hash = $1,
              must_change_password = $2,
              password_changed_at = NOW(),
              token_version = token_version + 1,
              email_verified = CASE WHEN $3 THEN TRUE ELSE email_verified END,
              account_status = CASE WHEN $4 AND account_status = 'pending_invite' THEN 'active' ELSE account_status END
        WHERE id = $5
        RETURNING ${USER_COLS}`,
      [hash, Boolean(mustChange), Boolean(markEmailVerified), Boolean(activate), userId]
    );
    if (r.rows.length === 0) throw httpError(404, 'Kullanıcı bulunamadı.', 'NOT_FOUND');
    const { mqttUsernames, serviceSessionsRevoked } = await this.revokeAllUserSessions(userId, { tx, reason: 'password_changed', bumpTokenVersion: false });
    if (Array.isArray(revokedMqtt)) revokedMqtt.push(...mqttUsernames);
    if (serviceSessionsRevoked && revokeInfo && typeof revokeInfo === 'object') revokeInfo.serviceSessionsRevoked = true;
    return r.rows[0];
  }

  async changePassword(userId, { current_password, new_password } = {}, { ip } = {}) {
    if (typeof current_password !== 'string' || !current_password) {
      throw httpError(400, 'Mevcut şifre zorunludur.', 'VALIDATION');
    }
    validatePassword(new_password);
    if (current_password === new_password) {
      throw httpError(400, 'Yeni şifre mevcut şifreden farklı olmalıdır.', 'VALIDATION');
    }
    const r = await db.query(`SELECT ${USER_COLS}, password_hash FROM users WHERE id = $1`, [userId]);
    const user = r.rows[0];
    if (!user) throw httpError(404, 'Kullanıcı bulunamadı.', 'NOT_FOUND');
    const ok = await this._comparePassword(current_password, user.password_hash);
    if (!ok) throw httpError(400, 'Mevcut şifre hatalı.', 'INVALID_CREDENTIALS');

    const revokedMqtt = [];
    const revokeInfo = {};
    const updated = await db.withTransaction(async (tx) => {
      const u = await this.setPassword(userId, new_password, { tx, mustChange: false, revokedMqtt, revokeInfo });
      return u;
    });
    invalidateUserAuthCache(userId);
    if (revokeInfo.serviceSessionsRevoked) invalidateServiceSessionCache();
    // Push belirteci gizliligi (plan §5d-1): COMMIT sonrasi, hata/yapilandirma yoklugu akisi bozmaz.
    // Bu cihaz oturumda KALIR ama belirteci de kapanir: istemci yeni oturumdan sonra belirtecini yeniden kaydeder
    // (PUT /me/push-tokens; docs/FLUTTER_API_CHANGES.md).
    await this.revokePushTokens(userId, { reason: 'password_changed' });
    // Uygulama MQTT kimlikleri tx icinde silindi: diger cihazlarin acik canli kanali COMMIT sonrasi kesilir
    // (bu cihaz yeni oturumla kimligi yeniden alir: POST /homes/:id/mqtt-credentials).
    await this.kickMqttUsernames(revokedMqtt, { reason: 'password_changed' });
    // Bu cihaz icin yeni oturum (diger tum cihazlar dusurulur).
    return this._buildUserAuthResponse(updated, { ip });
  }

  // ----------------------------- Kod (OTP) altyapisi ------------------------
  /**
   * Ayni anahtar icin yeniden gonderim sinirlarini denetler (60 sn bekleme + saatte 5)
   * ve yeni koda tasinacak deneme sayisini doner. Cagri bir transaction icinde ve
   * anahtar bazli advisory kilit altinda yapilir.
   */
  async _checkResendLimits(tx, { table, keyCol, key }) {
    const r = await tx.query(
      `SELECT COUNT(*)::int AS sends,
              MIN(created_at) AS first_at,
              MAX(created_at) AS last_at,
              COALESCE(MAX(attempts), 0)::int AS max_attempts,
              NOW() AS db_now
         FROM ${table}
        WHERE ${keyCol} = $1
          AND created_at > NOW() - INTERVAL '1 hour'`,
      [key]
    );
    const row = r.rows[0] || {};
    const sends = Number(row.sends || 0);
    const nowMs = row.db_now ? new Date(row.db_now).getTime() : Date.now();
    if (row.last_at) {
      const elapsed = (nowMs - new Date(row.last_at).getTime()) / 1000;
      if (elapsed < RESEND_COOLDOWN_SEC) {
        const wait = Math.max(1, Math.ceil(RESEND_COOLDOWN_SEC - elapsed));
        throw httpError(429, `Yeni kod istemek için ${wait} saniye bekleyin.`, 'RATE_LIMITED', {
          retryAfter: wait,
          body: { resend_after: wait },
        });
      }
    }
    if (sends >= MAX_SENDS_PER_HOUR) {
      const firstMs = row.first_at ? new Date(row.first_at).getTime() : nowMs;
      const wait = Math.max(1, Math.ceil((firstMs + 3600 * 1000 - nowMs) / 1000));
      throw httpError(429, 'Bir saat içinde çok fazla kod istendi. Lütfen daha sonra tekrar deneyin.', 'RATE_LIMITED', {
        retryAfter: wait,
        body: { resend_after: wait },
      });
    }
    return { carriedAttempts: Math.min(MAX_CODE_ATTEMPTS, Number(row.max_attempts || 0)) };
  }

  // ----------------------------- Sifre sifirlama ---------------------------
  _resetLink(token) {
    // Token URL parcasinda (#) tasinir; sunucu/proxy loglarina dusmez.
    return `${appPublicUrl()}/reset-password#token=${encodeURIComponent(token)}`;
  }

  async requestPasswordReset(identifier, { ip } = {}) {
    const id = parseIdentifier(identifier);
    if (!id) throw httpError(400, 'Geçerli bir e-posta adresi veya telefon numarası giriniz.', 'VALIDATION');

    const debug = isDebugOtpAllowed();
    if (!debug && !mailer.isMailerConfigured()) {
      // Herkes icin ayni yanit (hesap varligi sizmaz).
      throw httpError(503, 'Şifre sıfırlama e-postası şu anda gönderilemiyor. Lütfen daha sonra tekrar deneyin.', 'DELIVERY_FAILED', { expose: true });
    }

    const code = generateNumericPin(6);
    const token = crypto.randomBytes(32).toString('base64url');
    const ttlSec = jwtConfig.getResetCodeTtlSec();

    const created = await db.withTransaction(async (tx) => {
      await tx.query('SELECT pg_advisory_xact_lock(hashtext($1))', [`pwreset:${id.value}`]);
      const { carriedAttempts } = await this._checkResendLimits(tx, {
        table: 'password_resets',
        keyCol: 'identifier',
        key: id.value,
      });

      const userRes = id.kind === 'email'
        ? await tx.query(
          `SELECT ${USER_COLS} FROM users
            WHERE LOWER(email) = $1 AND is_active = TRUE AND account_status IN ('active', 'pending_invite')`,
          [id.value]
        )
        : await tx.query(
          `SELECT ${USER_COLS} FROM users
            WHERE phone = $1 AND is_active = TRUE AND account_status IN ('active', 'pending_invite')`,
          [id.value]
        );
      const found = userRes.rows.length === 1 ? userRes.rows[0] : null;
      // Yer tutucu e-postali hesap (telefon-OTP / Apple gizli) e-postayla teslim edilemez (UYELIK-08): kayitsiz kimlik
      // gibi islenir -> kullaniciya bagli talep ACILMAZ, gonderim denenmez. Yazilan kullanicisiz (tuketilemez) satir
      // yalniz 60 sn / saatte 5 sinirlarinin kayitsiz kimlikle AYNI islemesi icindir (aksi halde hesap varligi sizar).
      const user = found && !isPlaceholderEmail(found.email) ? found : null;

      // Onceki gecerli talepler burada KAPATILMAZ: yeni kod teslim edilince kapatilir (UYELIK-K1, asagida).
      const ins = await tx.query(
        `INSERT INTO password_resets (user_id, identifier, code_hash, token_hash, expires_at, attempts, purpose)
         VALUES ($1, $2, $3, $4, NOW() + make_interval(secs => $5::int), $6, 'reset')
         RETURNING id`,
        [user ? user.id : null, id.value, pin.hashPin(code), this._hashToken(token), ttlSec, carriedAttempts]
      );
      return { user, resetId: ins.rows[0] ? ins.rows[0].id : null };
    });

    const response = {
      message: 'Eğer kayıtlı bir hesap varsa şifre sıfırlama kodu gönderildi.',
      expires_in: ttlSec,
      resend_after: RESEND_COOLDOWN_SEC,
    };

    if (!created.user) return response;

    const result = await mailer.sendPasswordResetEmail({
      to: created.user.email,
      code,
      link: this._resetLink(token),
      expiresMinutes: Math.max(1, Math.round(ttlSec / 60)),
    });
    if (!result.sent && !debug) {
      // Yalniz teslim edilemeyen YENI talep iptal; elde olan ESKI gecerli kod/baglanti kullanilabilir kalir (UYELIK-K1).
      if (created.resetId) {
        await db.query('UPDATE password_resets SET used_at = NOW() WHERE id = $1', [created.resetId]);
      }
      if (result.reason === mailer.REASONS.INVALID_RECIPIENT) return response; // genel yanit (hesap varligi sizmaz)
      throw httpError(503, 'Şifre sıfırlama e-postası gönderilemedi. Lütfen daha sonra tekrar deneyin.', 'DELIVERY_FAILED', { expose: true });
    }
    // Yeni kod teslim edildi (ya da gelistirmede debug): onceki talepler artik gecersiz (gecerli tek kod budur).
    if (created.resetId) {
      await db.query(
        `UPDATE password_resets SET used_at = NOW()
          WHERE identifier = $1 AND used_at IS NULL AND id <> $2`,
        [id.value, created.resetId]
      );
    }
    if (debug) {
      response.debug_code = code;
      response.debug_token = token;
    }
    return response;
  }

  /**
   * Belirli bir kullanici icin sifre sifirlama/hesap kurulum kodu+baglantisi uretip e-postalar.
   * Yonetici akislari (A7) ve servis kurulumunda musteri hesabi (WP-B) kullanir.
   * @param {string} userId
   * @param {{purpose?:'reset'|'account_setup', tx?:object, ttlSec?:number}} [opts]
   * @returns {Promise<{sent:boolean, reason?:string, expires_at:Date, debug_code?:string, debug_token?:string}>}
   */
  async issueUserCode(userId, { purpose = 'reset', tx, ttlSec } = {}) {
    if (!['reset', 'account_setup'].includes(purpose)) throw new TypeError('issueUserCode: geçersiz amaç');
    const q = tx || db;
    const user = await this._findUserById(q, userId);
    if (!user) throw httpError(404, 'Kullanıcı bulunamadı.', 'NOT_FOUND');
    const identifier = normalizeEmail(user.email);
    if (!identifier) throw httpError(400, 'Kullanıcının geçerli bir e-posta adresi yok.', 'VALIDATION');

    const ttl = Number.isFinite(ttlSec) && ttlSec > 0
      ? Math.floor(ttlSec)
      : (purpose === 'account_setup' ? ACCOUNT_SETUP_TTL_SEC : ADMIN_RESET_TTL_SEC);
    const code = generateNumericPin(6);
    const token = crypto.randomBytes(32).toString('base64url');

    await q.query(`UPDATE password_resets SET used_at = NOW() WHERE identifier = $1 AND used_at IS NULL`, [identifier]);
    const ins = await q.query(
      `INSERT INTO password_resets (user_id, identifier, code_hash, token_hash, expires_at, attempts, purpose)
       VALUES ($1, $2, $3, $4, NOW() + make_interval(secs => $5::int), 0, $6)
       RETURNING id, expires_at`,
      [user.id, identifier, pin.hashPin(code), this._hashToken(token), ttl, purpose]
    );

    const link = this._resetLink(token);
    const result = purpose === 'account_setup'
      ? await mailer.sendAccountSetupEmail({ to: user.email, fullName: user.full_name, code, link, expiresHours: Math.max(1, Math.round(ttl / 3600)) })
      : await mailer.sendPasswordResetEmail({ to: user.email, code, link, expiresMinutes: Math.max(1, Math.round(ttl / 60)) });

    const out = {
      sent: Boolean(result.sent),
      expires_at: ins.rows[0] ? ins.rows[0].expires_at : null,
    };
    if (!result.sent) out.reason = result.reason;
    if (isDebugOtpAllowed()) {
      out.debug_code = code;
      out.debug_token = token;
    }
    return out;
  }

  /**
   * WP-B icin kisayol: servis kurulumunda acilan 'pending_invite' musteri hesabina davet.
   * Iki cagri bicimi kabul edilir: createAccountSetupInvite(userId, { tx })
   * veya createAccountSetupInvite({ userId, email?, fullName? }, { tx }) - e-posta/ad DB'den okunur.
   */
  async createAccountSetupInvite(userOrId, { tx } = {}) {
    const userId = userOrId && typeof userOrId === 'object' ? (userOrId.userId || userOrId.id) : userOrId;
    return this.issueUserCode(userId, { purpose: 'account_setup', tx });
  }

  /** Kod veya sihirli baglanti ile sifirlama talebini ATOMIK tuketir. @returns satir */
  async _consumeResetRequest({ identifier, code, token, allowedPurposes = ['reset', 'account_setup'] }) {
    if (typeof token === 'string' && token.trim()) {
      const t = token.trim();
      if (t.length > 512) throw httpError(400, 'Geçersiz veya süresi dolmuş bağlantı.', 'VALIDATION');
      const r = await db.query(
        `UPDATE password_resets
            SET used_at = NOW()
          WHERE token_hash = $1
            AND used_at IS NULL
            AND expires_at > NOW()
            AND purpose = ANY($2::text[])
          RETURNING id, user_id, identifier, purpose`,
        [this._hashToken(t), allowedPurposes]
      );
      if (r.rows.length === 0) throw httpError(400, 'Geçersiz veya süresi dolmuş bağlantı.', 'VALIDATION');
      return r.rows[0];
    }

    const id = parseIdentifier(identifier);
    if (!id || !isValidCodeFormat(code)) {
      throw httpError(400, 'Geçerli bir kimlik ve 6 haneli kod giriniz.', 'VALIDATION');
    }

    // Deneme sayaci ATOMIK artirilir (kod dogru olsa bile bir deneme sayilir).
    const att = await db.query(
      `UPDATE password_resets
          SET attempts = attempts + 1
        WHERE id = (
                SELECT id FROM password_resets
                 WHERE identifier = $1 AND used_at IS NULL AND expires_at > NOW()
                 ORDER BY created_at DESC
                 LIMIT 1
              )
          AND attempts < $2
          AND purpose = ANY($3::text[])
        RETURNING id, user_id, code_hash, attempts, purpose`,
      [id.value, MAX_CODE_ATTEMPTS, allowedPurposes]
    );
    if (att.rows.length === 0) {
      const locked = await db.query(
        `SELECT attempts FROM password_resets
          WHERE identifier = $1 AND used_at IS NULL AND expires_at > NOW()
          ORDER BY created_at DESC LIMIT 1`,
        [id.value]
      );
      if (locked.rows[0] && Number(locked.rows[0].attempts) >= MAX_CODE_ATTEMPTS) {
        throw httpError(429, 'Çok fazla hatalı deneme yapıldı. Lütfen daha sonra yeni kod isteyin.', 'RATE_LIMITED', { retryAfter: 3600 });
      }
      throw httpError(400, 'Geçersiz veya süresi dolmuş kod.', 'VALIDATION');
    }

    const row = att.rows[0];
    if (!pin.verifyPin(code.trim(), row.code_hash) || !row.user_id) {
      const remaining = Math.max(0, MAX_CODE_ATTEMPTS - Number(row.attempts));
      throw httpError(400, 'Hatalı kod.', 'VALIDATION', { body: { remaining_attempts: remaining } });
    }

    const consumed = await db.query(
      `UPDATE password_resets SET used_at = NOW()
        WHERE id = $1 AND used_at IS NULL
        RETURNING id, user_id, identifier, purpose`,
      [row.id]
    );
    if (consumed.rows.length === 0) throw httpError(400, 'Geçersiz veya süresi dolmuş kod.', 'VALIDATION');
    return consumed.rows[0];
  }

  async resetPassword({ identifier, code, token, new_password } = {}, { ip } = {}) {
    validatePassword(new_password);
    const request = await this._consumeResetRequest({ identifier, code, token });
    if (!request.user_id) throw httpError(400, 'Geçersiz veya süresi dolmuş kod.', 'VALIDATION');

    const revokedMqtt = [];
    const revokeInfo = {};
    const user = await db.withTransaction(async (tx) => {
      const current = await this._findUserById(tx, request.user_id);
      if (!current || current.is_active === false || current.account_status === 'suspended') {
        throw httpError(400, 'Geçersiz veya süresi dolmuş kod.', 'VALIDATION');
      }
      const updated = await this.setPassword(current.id, new_password, {
        tx,
        mustChange: false,
        markEmailVerified: true,
        activate: true,
        revokedMqtt,
        revokeInfo,
      });
      // Kullaniciya ait diger acik talepler kapatilir.
      await tx.query('UPDATE password_resets SET used_at = NOW() WHERE user_id = $1 AND used_at IS NULL', [current.id]);
      return updated;
    });
    invalidateUserAuthCache(user.id);
    if (revokeInfo.serviceSessionsRevoked) invalidateServiceSessionCache();
    // Push belirteci gizliligi (plan §5d-1): tum oturumlar kapandi -> COMMIT sonrasi belirteclerde de kapat.
    // Yanit bu cihaza yeni oturum verir; istemci belirtecini yeniden kaydeder (PUT /me/push-tokens).
    await this.revokePushTokens(user.id, { reason: 'password_reset' });
    await this.kickMqttUsernames(revokedMqtt, { reason: 'password_reset' });

    const auth = await this._buildUserAuthResponse(user, { ip });
    return { ...auth, message: 'Şifreniz yenilendi. Diğer tüm oturumlarınız kapatıldı.' };
  }

  /** POST /auth/magic-login: tek kullanimlik baglanti ile giris (GET ile oturum ACILMAZ). */
  async magicLogin(token, { ip } = {}) {
    if (typeof token !== 'string' || !token.trim()) {
      throw httpError(400, 'Bağlantı kodu zorunludur.', 'VALIDATION');
    }
    // Hesap durumu baglanti TUKETILMEDEN denetlenir (uyelik-10): davet bekleyen hesap (ACCOUNT_PENDING) ayni
    // baglantiyla parolasini belirleyebilsin; askidaki hesap baglantiyi bosa harcamasin. Baglanti sahibi zaten
    // gizli degeri bildigi icin durumun aciklanmasi bilgi sizdirmaz (parolali giriste sira DEGISMEZ).
    const t = token.trim();
    if (t.length > 512) throw httpError(400, 'Geçersiz veya süresi dolmuş bağlantı.', 'VALIDATION');
    const pre = await db.query(
      `SELECT user_id FROM password_resets
        WHERE token_hash = $1 AND used_at IS NULL AND expires_at > NOW() AND purpose = ANY($2::text[])`,
      [this._hashToken(t), ['reset']]
    );
    const preUser = pre.rows[0] && pre.rows[0].user_id ? await this._findUserById(db, pre.rows[0].user_id) : null;
    if (!preUser) throw httpError(400, 'Geçersiz veya süresi dolmuş bağlantı.', 'VALIDATION');
    this._assertUserCanSignIn(preUser);

    const request = await this._consumeResetRequest({ token: t, allowedPurposes: ['reset'] });
    const user = await this._findUserById(db, request.user_id);
    if (!user) throw httpError(400, 'Geçersiz veya süresi dolmuş bağlantı.', 'VALIDATION');
    this._assertUserCanSignIn(user);
    await db.query('UPDATE users SET email_verified = TRUE, last_login_at = NOW() WHERE id = $1', [user.id]);
    return this._buildUserAuthResponse({ ...user, email_verified: true }, { ip });
  }

  // ----------------------------- Telefon OTP -------------------------------
  async _sendSms(phone, text) {
    if (!this._smsSender) return { sent: false, reason: 'SMS_NOT_CONFIGURED' };
    try {
      const r = await this._smsSender(phone, text);
      return r && r.sent ? { sent: true } : { sent: false, reason: 'SEND_FAILED' };
    } catch (_) {
      return { sent: false, reason: 'SEND_FAILED' };
    }
  }

  async sendPhoneOtp(phone, { ip } = {}) {
    const cleanPhone = normalizePhone(phone);
    if (!cleanPhone) throw httpError(400, 'Geçerli bir telefon numarası giriniz (örn: +905xxxxxxxxx).', 'VALIDATION');

    const debug = isDebugOtpAllowed();
    if (!this._canSendPhoneOtp()) {
      throw httpError(503, 'SMS doğrulama servisi şu anda kullanılamıyor.', 'DELIVERY_FAILED', { expose: true });
    }

    const code = generateNumericPin(6);
    const ttlSec = jwtConfig.getPhoneOtpTtlSec();
    const otpId = await db.withTransaction(async (tx) => {
      await tx.query('SELECT pg_advisory_xact_lock(hashtext($1))', [`phoneotp:${cleanPhone}`]);
      const { carriedAttempts } = await this._checkResendLimits(tx, {
        table: 'phone_otp_codes',
        keyCol: 'phone',
        key: cleanPhone,
      });
      // Onceki gecerli kod burada KAPATILMAZ: yeni kod teslim edilince kapatilir (UYELIK-K1, asagida).
      const ins = await tx.query(
        `INSERT INTO phone_otp_codes (phone, otp_hash, expires_at, attempts)
         VALUES ($1, $2, NOW() + make_interval(secs => $3::int), $4)
         RETURNING id`,
        [cleanPhone, pin.hashPin(code), ttlSec, carriedAttempts]
      );
      return ins.rows[0] ? ins.rows[0].id : null;
    });

    if (this._smsSender) {
      const sms = await this._sendSms(cleanPhone, `AHBU doğrulama kodunuz: ${code}. Kimseyle paylaşmayın.`);
      if (!sms.sent && !debug) {
        // Yalniz teslim edilemeyen YENI kod iptal; elde olan ESKI gecerli kod kullanilabilir kalir.
        if (otpId) await db.query('UPDATE phone_otp_codes SET consumed_at = NOW() WHERE id = $1', [otpId]);
        throw httpError(503, 'Doğrulama kodu gönderilemedi. Lütfen daha sonra tekrar deneyin.', 'DELIVERY_FAILED', { expose: true });
      }
    }
    // Yeni kod teslim edildi (SMS ya da gelistirmede debug): onceki kodlar artik gecersiz (gecerli tek kod budur).
    if (otpId) {
      await db.query(
        `UPDATE phone_otp_codes SET consumed_at = NOW()
          WHERE phone = $1 AND consumed_at IS NULL AND id <> $2`,
        [cleanPhone, otpId]
      );
    }

    const out = {
      message: 'Doğrulama kodu gönderildi.',
      expires_in: ttlSec,
      resend_after: RESEND_COOLDOWN_SEC,
    };
    if (debug) out.debug_code = code;
    return out;
  }

  async verifyPhoneOtp(phone, code, { ip } = {}) {
    const cleanPhone = normalizePhone(phone);
    if (!cleanPhone || !isValidCodeFormat(code)) {
      throw httpError(400, 'Telefon numarası ve 6 haneli doğrulama kodu zorunludur.', 'VALIDATION');
    }

    const att = await db.query(
      `UPDATE phone_otp_codes
          SET attempts = attempts + 1
        WHERE id = (
                SELECT id FROM phone_otp_codes
                 WHERE phone = $1 AND consumed_at IS NULL AND expires_at > NOW()
                 ORDER BY created_at DESC
                 LIMIT 1
              )
          AND attempts < $2
        RETURNING id, otp_hash, attempts`,
      [cleanPhone, MAX_CODE_ATTEMPTS]
    );
    if (att.rows.length === 0) {
      const locked = await db.query(
        `SELECT attempts FROM phone_otp_codes
          WHERE phone = $1 AND consumed_at IS NULL AND expires_at > NOW()
          ORDER BY created_at DESC LIMIT 1`,
        [cleanPhone]
      );
      if (locked.rows[0] && Number(locked.rows[0].attempts) >= MAX_CODE_ATTEMPTS) {
        throw httpError(429, 'Çok fazla hatalı deneme yapıldı. Lütfen daha sonra yeni kod isteyin.', 'RATE_LIMITED', { retryAfter: 3600 });
      }
      throw httpError(401, 'Doğrulama kodunun süresi dolmuş veya kod talep edilmemiş.', 'INVALID_CREDENTIALS');
    }

    const row = att.rows[0];
    if (!pin.verifyPin(code.trim(), row.otp_hash)) {
      const remaining = Math.max(0, MAX_CODE_ATTEMPTS - Number(row.attempts));
      throw httpError(401, 'Hatalı doğrulama kodu.', 'INVALID_CREDENTIALS', { body: { remaining_attempts: remaining } });
    }
    const consumed = await db.query(
      'UPDATE phone_otp_codes SET consumed_at = NOW() WHERE id = $1 AND consumed_at IS NULL RETURNING id',
      [row.id]
    );
    if (consumed.rows.length === 0) {
      throw httpError(401, 'Doğrulama kodunun süresi dolmuş veya kod kullanılmış.', 'INVALID_CREDENTIALS');
    }

    const users = await db.query(`SELECT ${USER_COLS} FROM users WHERE phone = $1`, [cleanPhone]);
    if (users.rows.length > 1) {
      throw httpError(409, 'Bu telefon numarası birden fazla hesapta kayıtlı. Lütfen e-posta ile giriş yapın.', 'CONFLICT');
    }
    let user = users.rows[0];
    if (!user) {
      const dummyEmail = `phone_${cleanPhone.replace(/[^0-9]/g, '')}@ahbu.local`;
      try {
        const ins = await db.query(
          `INSERT INTO users (full_name, phone, email, password_hash, role, is_active, account_status)
           VALUES ($1, $2, $3, $4, 'user', TRUE, 'active')
           RETURNING ${USER_COLS}`,
          [`Sakin (${cleanPhone.slice(-4)})`, cleanPhone, dummyEmail, await this._unusablePasswordHash()]
        );
        user = ins.rows[0];
      } catch (err) {
        if (err && err.code === '23505') {
          throw httpError(409, 'Hesap oluşturulamadı; lütfen tekrar deneyin.', 'CONFLICT');
        }
        throw err;
      }
    }
    this._assertUserCanSignIn(user);
    await db.query('UPDATE users SET last_login_at = NOW() WHERE id = $1', [user.id]);
    return this._buildUserAuthResponse(user, { ip });
  }

  // ----------------------------- Sosyal giris ------------------------------
  async loginWithGoogle({ id_token } = {}, { ip } = {}) {
    const audiences = this._googleAudiences();
    if (audiences.length === 0) {
      throw httpError(503, 'Google ile giriş şu anda kullanılamıyor.', 'SERVICE_UNAVAILABLE', { expose: true });
    }
    if (typeof id_token !== 'string' || id_token.length < 20 || id_token.length > 8192) {
      throw httpError(400, 'Google kimlik jetonu (id_token) zorunludur.', 'VALIDATION');
    }

    let payload;
    try {
      payload = await this._verifiers.google(id_token, audiences);
    } catch (_) {
      throw httpError(401, 'Google kimliği doğrulanamadı.', 'INVALID_CREDENTIALS');
    }
    // Kutuphanenin denetimlerine ek olarak savunmaci kontroller.
    if (!payload || typeof payload.sub !== 'string' || !payload.sub) {
      throw httpError(401, 'Google kimliği doğrulanamadı.', 'INVALID_CREDENTIALS');
    }
    if (!GOOGLE_ISSUERS.includes(payload.iss)) {
      throw httpError(401, 'Google kimliği doğrulanamadı.', 'INVALID_CREDENTIALS');
    }
    const aud = Array.isArray(payload.aud) ? payload.aud : [payload.aud];
    if (!aud.some((a) => audiences.includes(a))) {
      throw httpError(401, 'Google kimliği doğrulanamadı.', 'INVALID_CREDENTIALS');
    }
    if (typeof payload.exp !== 'number' || payload.exp * 1000 < Date.now() - 5000) {
      throw httpError(401, 'Google kimlik jetonunun süresi dolmuş.', 'INVALID_CREDENTIALS');
    }
    if (payload.email_verified !== true && payload.email_verified !== 'true') {
      throw httpError(401, 'Google e-posta adresi doğrulanmamış.', 'INVALID_CREDENTIALS');
    }
    const email = normalizeEmail(payload.email);
    if (!email) throw httpError(401, 'Google hesabında geçerli e-posta yok.', 'INVALID_CREDENTIALS');

    return this._loginWithSocial(
      { provider: 'google', subject: payload.sub, email, emailVerified: true, fullName: payload.name },
      { ip }
    );
  }

  async loginWithApple({ identity_token, full_name, nonce } = {}, { ip } = {}) {
    const audiences = this._appleAudiences();
    if (audiences.length === 0) {
      throw httpError(503, 'Apple ile giriş şu anda kullanılamıyor.', 'SERVICE_UNAVAILABLE', { expose: true });
    }
    if (typeof identity_token !== 'string' || identity_token.length < 20 || identity_token.length > 8192) {
      throw httpError(400, 'Apple kimlik jetonu (identity_token) zorunludur.', 'VALIDATION');
    }

    let payload;
    try {
      payload = await this._verifiers.apple(identity_token, audiences);
    } catch (_) {
      throw httpError(401, 'Apple kimliği doğrulanamadı.', 'INVALID_CREDENTIALS');
    }
    if (!payload || typeof payload.sub !== 'string' || !payload.sub) {
      throw httpError(401, 'Apple kimliği doğrulanamadı.', 'INVALID_CREDENTIALS');
    }
    if (payload.iss !== APPLE_ISSUER) throw httpError(401, 'Apple kimliği doğrulanamadı.', 'INVALID_CREDENTIALS');
    const aud = Array.isArray(payload.aud) ? payload.aud : [payload.aud];
    if (!aud.some((a) => audiences.includes(a))) {
      throw httpError(401, 'Apple kimliği doğrulanamadı.', 'INVALID_CREDENTIALS');
    }
    if (typeof payload.exp !== 'number' || payload.exp * 1000 < Date.now() - 5000) {
      throw httpError(401, 'Apple kimlik jetonunun süresi dolmuş.', 'INVALID_CREDENTIALS');
    }
    // Istemci ham nonce gonderdiyse jetondaki (SHA-256) nonce ile eslesmeli (tekrar oynatma savunmasi).
    if (typeof nonce === 'string' && nonce) {
      const expected = sha256Hex(nonce);
      if (payload.nonce !== expected && payload.nonce !== nonce) {
        throw httpError(401, 'Apple kimliği doğrulanamadı.', 'INVALID_CREDENTIALS');
      }
    }

    const emailVerified = payload.email_verified === true || payload.email_verified === 'true';
    const email = emailVerified ? normalizeEmail(payload.email) : null;

    return this._loginWithSocial(
      { provider: 'apple', subject: payload.sub, email, emailVerified, fullName: full_name },
      { ip }
    );
  }

  /**
   * Dogrulanmis sosyal kimlikle hesabi bulur / baglar / olusturur.
   * On-hesap-ele-gecirme savunmasi: e-postasi DOGRULANMAMIS mevcut hesaba ilk kez sosyal
   * kimlik baglanirken o hesabin parolasi ve tum oturumlari gecersiz kilinir.
   */
  async _loginWithSocial({ provider, subject, email, emailVerified, fullName }, { ip } = {}) {
    const idCol = provider === 'google' ? 'google_id' : 'apple_id';
    const fallbackName = provider === 'google' ? 'Google Kullanıcısı' : 'Apple Kullanıcısı';

    let user;
    let sessionsRevoked = false; // on-hesap-ele-gecirme savunmasi calistiysa (push belirteci gizliligi, plan §5d-1)
    let serviceSessionsRevoked = false; // ayni savunmada kapanan servis (PIN) oturumlari (uyelik-7)
    const revokedMqtt = []; // ayni savunmada silinen uygulama MQTT kimlikleri (COMMIT sonrasi atilir)
    try {
      user = await db.withTransaction(async (tx) => {
        let r = await tx.query(`SELECT ${USER_COLS} FROM users WHERE ${idCol} = $1 FOR UPDATE`, [subject]);
        let found = r.rows[0] || null;

        if (!found && email && emailVerified) {
          r = await tx.query(`SELECT ${USER_COLS} FROM users WHERE LOWER(email) = $1 FOR UPDATE`, [email]);
          found = r.rows[0] || null;
          if (found) {
            if (found[idCol] && found[idCol] !== subject) {
              throw httpError(409, 'Bu e-posta adresi başka bir hesapla ilişkili.', 'CONFLICT');
            }
            if (!found.email_verified) {
              const unusable = await this._unusablePasswordHash();
              // Parola gecersiz kilindi: hesap artik SIFRESIZ sayilir (uyelik-8; hesap silme "SİL" onayiyla calisir,
              // eski "parolayi degistir" zorunlulugu da anlamsizdir).
              const upd = await tx.query(
                `UPDATE users
                    SET ${idCol} = $1, email_verified = TRUE, password_hash = $2,
                        token_version = token_version + 1,
                        password_changed_at = NULL, must_change_password = FALSE,
                        account_status = CASE WHEN account_status = 'pending_invite' THEN 'active' ELSE account_status END
                  WHERE id = $3
                  RETURNING ${USER_COLS}`,
                [subject, unusable, found.id]
              );
              // Eski hesabin TUM oturumlari + uygulama MQTT kimlikleri (token_version yukarida artti).
              const revoked = await this.revokeAllUserSessions(found.id, { tx, reason: 'social_link', bumpTokenVersion: false });
              revokedMqtt.push(...revoked.mqttUsernames);
              sessionsRevoked = true;
              serviceSessionsRevoked = Boolean(revoked.serviceSessionsRevoked);
              found = upd.rows[0];
            } else {
              const upd = await tx.query(
                `UPDATE users SET ${idCol} = $1,
                        account_status = CASE WHEN account_status = 'pending_invite' THEN 'active' ELSE account_status END
                  WHERE id = $2
                  RETURNING ${USER_COLS}`,
                [subject, found.id]
              );
              found = upd.rows[0];
            }
          }
        }

        if (!found) {
          let accountEmail = email;
          if (!accountEmail) {
            if (provider !== 'apple') throw httpError(401, 'Kimlik doğrulanamadı.', 'INVALID_CREDENTIALS');
            // Apple e-posta paylasmadiysa teslim edilemeyen yer tutucu (.invalid) kullanilir.
            accountEmail = `apple.${sha256Hex(subject).slice(0, 24)}@users.noreply.invalid`;
          }
          const ins = await tx.query(
            `INSERT INTO users (full_name, email, password_hash, ${idCol}, role, is_active, account_status, email_verified)
             VALUES ($1, $2, $3, $4, 'user', TRUE, 'active', $5)
             RETURNING ${USER_COLS}`,
            [normalizeFullName(fullName, fallbackName), accountEmail, await this._unusablePasswordHash(), subject, Boolean(email && emailVerified)]
          );
          found = ins.rows[0];
        }

        this._assertUserCanSignIn(found);
        await tx.query('UPDATE users SET last_login_at = NOW() WHERE id = $1', [found.id]);
        return found;
      });
    } catch (err) {
      if (err && err.code === '23505') {
        throw httpError(409, 'Hesap eşleştirilemedi; lütfen tekrar deneyin.', 'CONFLICT');
      }
      throw err;
    }

    invalidateUserAuthCache(user.id);
    if (serviceSessionsRevoked) invalidateServiceSessionCache();
    // Eski (dogrulanmamis) hesabin oturumlari kapandi: o hesapla kayit edilmis push belirteclerini de kapat
    // (onceden kayit olan saldirganin telefonu ev bildirimlerini almaya devam etmesin). COMMIT sonrasi.
    if (sessionsRevoked) {
      await this.revokePushTokens(user.id, { reason: 'social_link' });
      await this.kickMqttUsernames(revokedMqtt, { reason: 'social_link' });
    }
    return this._buildUserAuthResponse(user, { ip });
  }

  // ----------------------------- Hesap silme (WP-B2) ------------------------
  /**
   * DELETE /auth/account: yumusak silme + anonimlestirme. Ayrintilar ve kurallar
   * `account_deletion_service.js` basligindadir (sifre / "SİL" onayi, SOLE_OWNER, staff/super yasagi).
   * @param {{userId:string, password?:string, confirm?:string, ip?:string}} params
   */
  async deleteAccount(params = {}) {
    // Tembel yukleme: account_deletion_service auth_service'i (parola karsilastirma) tembel kullanir.
    const { AccountDeletionService } = require('./account_deletion_service');
    if (!this._accountDeletion) this._accountDeletion = new AccountDeletionService({ auth: this });
    return this._accountDeletion.deleteAccount(params);
  }
}

const authService = new AuthService();

module.exports = authService;
module.exports.AuthService = AuthService;
module.exports.normalizeEmail = normalizeEmail;
module.exports.normalizePhone = normalizePhone;
module.exports.parseIdentifier = parseIdentifier;
module.exports.normalizeFullName = normalizeFullName;
module.exports.validatePassword = validatePassword;
module.exports.verifyGoogleIdToken = verifyGoogleIdToken;
module.exports.verifyAppleIdentityToken = verifyAppleIdentityToken;
module.exports.PASSWORD_MIN_LENGTH = PASSWORD_MIN_LENGTH;
module.exports.MAX_CODE_ATTEMPTS = MAX_CODE_ATTEMPTS;
module.exports.RESEND_COOLDOWN_SEC = RESEND_COOLDOWN_SEC;
module.exports.MAX_SENDS_PER_HOUR = MAX_SENDS_PER_HOUR;
