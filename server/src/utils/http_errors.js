'use strict';

// ==============================================================================
// Hata -> HTTP yanit eslemesi (CONTRACTS §1.1). Express'ten bagimsiz, saf fonksiyonlar.
//
//   httpError(status, message, code, extra)  servis katmaninda `throw httpError(409, '...', 'CONFLICT')`
//   toErrorResponse(err)                     -> { status, body, retryAfter, shouldLog }
//
// Kurallar:
//   - 5xx hatalarinda HAM IC MESAJ (SQL, kisit adi, yigin) istemciye DONMEZ; yalnizca bilincli
//     HttpError mesajlari (biz yazdik) iletilir, diger her sey genel mesajla yanitlanir.
//   - Makine kodlari: VALIDATION, INVALID_TOKEN, FORBIDDEN, NOT_FOUND, CONFLICT, DEVICE_OFFLINE,
//     PIN_LOCKED (423, retry_after), RATE_LIMITED (429), BROKER_UNAVAILABLE (502), GUEST_EXPIRED ...
// ==============================================================================

const { HttpError } = require('./helpers');

const CODE_BY_STATUS = Object.freeze({
  400: 'VALIDATION',
  401: 'INVALID_TOKEN',
  403: 'FORBIDDEN',
  404: 'NOT_FOUND',
  409: 'CONFLICT',
  423: 'PIN_LOCKED',
  429: 'RATE_LIMITED',
  502: 'BROKER_UNAVAILABLE',
});

const GENERIC_SERVER_MESSAGE = 'Sunucu hatası oluştu. Lütfen daha sonra tekrar deneyin.';
const DEADLOCK_MESSAGE = 'Eşzamanlı işlem çakışması oluştu. Lütfen tekrar deneyin.';

// Yanita eklenmesine izin verilen ek alanlar (beyaz liste; ic bilgi sizmasin).
// ack_queued (WP-S4): cevrimdisi panoya alarm onayi istegi kaydedildi (pano donunce ayni alarm surerse iletilir).
// data (Faz 2 F2.D.3): 409 CONFIG_CHANGED_ON_DEVICE -> {rev, crc, copy_rev} (panonun guncel yapilandirma surumu).
const EXPOSED_EXTRA_KEYS = Object.freeze(['retry_after', 'remaining_attempts', 'device_online', 'offline_devices', 'reason', 'ack_queued', 'data']);

/**
 * @param {number} status
 * @param {string} message  kullaniciya gosterilebilir (ASCII Turkce)
 * @param {string} [code]   makine kodu (varsayilan: duruma gore)
 * @param {object} [extra]  { retry_after, remaining_attempts, device_online, offline_devices, reason }
 *                          reason: ayni kodun (or. 409 CONFLICT) altinda makine-okur ayirici (NOT_APPLIED | TYPE_CHANGED)
 */
function httpError(status, message, code = null, extra = null) {
  const err = new HttpError(status, message, code);
  if (extra && typeof extra === 'object') err.extra = extra;
  return err;
}

function isValidStatus(status) {
  return Number.isInteger(status) && status >= 400 && status <= 599;
}

function pickExtra(extra) {
  const out = {};
  if (extra && typeof extra === 'object') {
    for (const key of EXPOSED_EXTRA_KEYS) {
      if (extra[key] !== undefined && extra[key] !== null) out[key] = extra[key];
    }
  }
  return out;
}

/**
 * @returns {{status:number, body:object, retryAfter:number|null, shouldLog:boolean}}
 */
function toErrorResponse(err) {
  // 1) Bilincli HttpError: mesaj ve kod aynen iletilir (5xx dahil; mesaji biz yazdik).
  if (err instanceof HttpError) {
    const status = isValidStatus(err.status) ? err.status : 500;
    const extra = pickExtra(err.extra);
    const body = {
      success: false,
      message: String(err.message || GENERIC_SERVER_MESSAGE),
      code: err.code || CODE_BY_STATUS[status] || 'INTERNAL',
      ...extra,
    };
    const retryAfter = Number.isFinite(extra.retry_after) ? Math.max(1, Math.ceil(extra.retry_after)) : null;
    return { status, body, retryAfter, shouldLog: status >= 500 };
  }

  // 2) PostgreSQL kilitlenme / serilestirme cakismasi: gecici, yeniden denenebilir.
  if (err && (err.code === '40P01' || err.code === '40001')) {
    return {
      status: 409,
      body: { success: false, message: DEADLOCK_MESSAGE, code: 'CONFLICT' },
      retryAfter: null,
      shouldLog: true,
    };
  }

  // 3) Eski bicim: `err.statusCode = 4xx` ile atilan duz Error (yalnizca 4xx mesaji acilir).
  const legacyStatus = err && (err.statusCode || err.status);
  if (isValidStatus(legacyStatus) && legacyStatus < 500 && typeof err.message === 'string' && err.message) {
    return {
      status: legacyStatus,
      body: { success: false, message: err.message, code: CODE_BY_STATUS[legacyStatus] || 'VALIDATION' },
      retryAfter: null,
      shouldLog: false,
    };
  }

  // 4) Diger her sey: ic ayrinti SIZDIRILMAZ.
  return {
    status: 500,
    body: { success: false, message: GENERIC_SERVER_MESSAGE, code: 'INTERNAL' },
    retryAfter: null,
    shouldLog: true,
  };
}

/** Log icin guvenli ozet (sir icermez: yalniz ad, ileti, PG kodu, yiginin ilk satirlari). */
function summarizeError(err) {
  if (!err) return 'bilinmeyen hata';
  const name = err.name || 'Error';
  const pgCode = typeof err.code === 'string' && /^[0-9A-Z]{5}$/.test(err.code) ? ` [${err.code}]` : '';
  const stack = typeof err.stack === 'string' ? err.stack.split('\n').slice(1, 4).join(' | ').trim() : '';
  return `${name}${pgCode}: ${err.message}${stack ? ` -- ${stack}` : ''}`;
}

module.exports = {
  httpError,
  toErrorResponse,
  summarizeError,
  CODE_BY_STATUS,
  GENERIC_SERVER_MESSAGE,
};
