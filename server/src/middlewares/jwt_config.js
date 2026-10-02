'use strict';

// ==============================================================================
// AHBU Akilli Ev - JWT yapilandirmasi, sure (TTL) ayarlari ve imzalama/dogrulama
// ==============================================================================
//
// Sozlesme (docs/CONTRACTS.md §1.2, §1.3):
//  - Access token: HS256, 15 dk. Claim'ler: sub, role (global), tv (token_version), iat, exp, iss.
//  - Servis oturumu token'i: role:"service_session", home_id, sid; 2 saat; refresh YOK.
//  - Refresh token: opak, 30 gun (auth_service).
//  - JWT_SECRET yoksa veya 32 karakterden kisaysa sunucu BASLAMAZ (varsayilan deger YOK).
//
// Sure override'lari (A16 - emulator QA'sinda yenileme/bitis akisini dakikalar icinde sinamak icin):
//   ACCESS_TOKEN_TTL_SEC     (varsayilan 900)
//   SERVICE_SESSION_TTL_SEC  (varsayilan 7200)
//   REFRESH_TOKEN_TTL_SEC    (varsayilan 2592000 = 30 gun)
//   OTP_TTL_SEC              (varsayilan: telefon OTP 300, sifre sifirlama kodu 900)
// GUVENLIK:
//   - NODE_ENV === 'production' iken override'lar SESSIZCE YOK SAYILIR, varsayilanlar kullanilir.
//   - Uretim disinda da deger [MIN_TTL_OVERRIDE_SEC, varsayilan] araligina kirpilir: override
//     sureyi yalnizca KISALTABILIR, asla varsayilandan uzun yapamaz (NODE_ENV unutulsa bile
//     guvenlik zayiflamaz).

const jwt = require('jsonwebtoken');

const MIN_SECRET_LENGTH = 32;
const ALGORITHM = 'HS256';
const CLOCK_TOLERANCE_SEC = 5;
const DEFAULT_ISSUER = 'ahbu-ev-otomasyon';

const DEFAULT_TTLS = Object.freeze({
  ACCESS_TOKEN_TTL_SEC: 15 * 60,
  SERVICE_SESSION_TTL_SEC: 2 * 60 * 60,
  REFRESH_TOKEN_TTL_SEC: 30 * 24 * 60 * 60,
  PHONE_OTP_TTL_SEC: 5 * 60,
  RESET_CODE_TTL_SEC: 15 * 60,
});
const MIN_TTL_OVERRIDE_SEC = 10;

// Geriye donuk uyumluluk icin sabitler (varsayilan degerler).
const ACCESS_TOKEN_TTL_SEC = DEFAULT_TTLS.ACCESS_TOKEN_TTL_SEC;
const SERVICE_SESSION_TTL_SEC = DEFAULT_TTLS.SERVICE_SESSION_TTL_SEC;

class JwtConfigError extends Error {
  constructor(message) {
    super(message);
    this.name = 'JwtConfigError';
  }
}

function isProduction() {
  return process.env.NODE_ENV === 'production';
}

/**
 * Ortam override'ini guvenli bicimde cozer.
 * @param {string} envName
 * @param {number} defaultSec
 */
function resolveTtl(envName, defaultSec) {
  if (isProduction()) return defaultSec;
  const raw = process.env[envName];
  if (raw === undefined || raw === null || String(raw).trim() === '') return defaultSec;
  if (!/^\d+$/.test(String(raw).trim())) return defaultSec;
  const v = Number(String(raw).trim());
  if (!Number.isSafeInteger(v) || v <= 0) return defaultSec;
  return Math.min(defaultSec, Math.max(MIN_TTL_OVERRIDE_SEC, v));
}

function getAccessTokenTtlSec() {
  return resolveTtl('ACCESS_TOKEN_TTL_SEC', DEFAULT_TTLS.ACCESS_TOKEN_TTL_SEC);
}
function getServiceSessionTtlSec() {
  return resolveTtl('SERVICE_SESSION_TTL_SEC', DEFAULT_TTLS.SERVICE_SESSION_TTL_SEC);
}
function getRefreshTokenTtlSec() {
  return resolveTtl('REFRESH_TOKEN_TTL_SEC', DEFAULT_TTLS.REFRESH_TOKEN_TTL_SEC);
}
function getPhoneOtpTtlSec() {
  return resolveTtl('OTP_TTL_SEC', DEFAULT_TTLS.PHONE_OTP_TTL_SEC);
}
function getResetCodeTtlSec() {
  return resolveTtl('OTP_TTL_SEC', DEFAULT_TTLS.RESET_CODE_TTL_SEC);
}

function getJwtSecret() {
  const secret = process.env.JWT_SECRET;
  if (!secret || String(secret).length < MIN_SECRET_LENGTH) {
    throw new JwtConfigError(
      `[AUTH] JWT_SECRET tanimli degil veya ${MIN_SECRET_LENGTH} karakterden kisa. Sunucu baslatilmadi (fail-closed).`
    );
  }
  return String(secret);
}

function getIssuer() {
  return process.env.JWT_ISSUER || DEFAULT_ISSUER;
}

/** server.js acilisinda cagrilir. */
function assertJwtConfig() {
  getJwtSecret();
  return true;
}

/**
 * Kullanici access token'i.
 * @param {{id:string, role?:string, token_version?:number}} user
 */
function signAccessToken(user) {
  if (!user || !user.id) throw new TypeError('[AUTH] signAccessToken: kullanici kimligi zorunludur.');
  const tv = Number.isInteger(Number(user.token_version)) ? Number(user.token_version) : 1;
  return jwt.sign(
    { sub: String(user.id), role: user.role || 'user', tv },
    getJwtSecret(),
    { algorithm: ALGORITHM, expiresIn: getAccessTokenTtlSec(), issuer: getIssuer() }
  );
}

/**
 * Servis oturumu token'i (tek ev kapsamli, refresh yok).
 * @param {{sid:string, home_id:string, expiresInSec?:number}} p
 */
function signServiceSessionToken({ sid, home_id, expiresInSec }) {
  if (!sid || !home_id) throw new TypeError('[AUTH] signServiceSessionToken: sid ve home_id zorunludur.');
  const maxTtl = getServiceSessionTtlSec();
  const wanted = Number.isFinite(expiresInSec) ? Math.floor(expiresInSec) : maxTtl;
  const ttl = Math.max(1, Math.min(maxTtl, wanted));
  return jwt.sign(
    { sub: `service_session:${sid}`, role: 'service_session', home_id: String(home_id), sid: String(sid) },
    getJwtSecret(),
    { algorithm: ALGORITHM, expiresIn: ttl, issuer: getIssuer() }
  );
}

/**
 * Imza + algoritma + issuer dogrulanir. Sure ayrica raporlanir (expired) ki cagiran
 * TOKEN_EXPIRED / SERVICE_SESSION_EXPIRED ile INVALID_TOKEN ayrimini yapabilsin.
 * Imza gecersizse hata firlatir.
 * @param {string} token
 * @param {{nowMs?: number}} [opts]
 * @returns {{ payload: object, expired: boolean }}
 */
function verifyToken(token, opts = {}) {
  const payload = jwt.verify(token, getJwtSecret(), {
    algorithms: [ALGORITHM],
    issuer: getIssuer(),
    ignoreExpiration: true,
  });
  const nowMs = Number.isFinite(opts.nowMs) ? opts.nowMs : Date.now();
  const nowSec = Math.floor(nowMs / 1000);
  const expired = typeof payload.exp !== 'number' || payload.exp + CLOCK_TOLERANCE_SEC < nowSec;
  return { payload, expired };
}

module.exports = {
  ALGORITHM,
  ACCESS_TOKEN_TTL_SEC,
  SERVICE_SESSION_TTL_SEC,
  DEFAULT_TTLS,
  MIN_TTL_OVERRIDE_SEC,
  CLOCK_TOLERANCE_SEC,
  MIN_SECRET_LENGTH,
  JwtConfigError,
  isProduction,
  getAccessTokenTtlSec,
  getServiceSessionTtlSec,
  getRefreshTokenTtlSec,
  getPhoneOtpTtlSec,
  getResetCodeTtlSec,
  getJwtSecret,
  getIssuer,
  assertJwtConfig,
  signAccessToken,
  signServiceSessionToken,
  verifyToken,
};
