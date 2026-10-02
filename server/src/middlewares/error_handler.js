'use strict';

// ==============================================================================
// AHBU Akilli Ev - Global hata yakalayici ve async route sarmalayici
// ==============================================================================
//
// Sozlesme (CONTRACTS §1.1):
//   { success:false, message:"Kullaniciya gosterilebilir Turkce mesaj", code:"MAKINE_KODU" }
//   5xx hatalarinda ham ic mesaj (SQL, constraint adi, yigin) istemciye DONMEZ; log'a yazilir.
//
// Kaynaklar:
//   - HttpError (utils/helpers): status + code + mesaj. 4xx mesajlari istemciye gider.
//     5xx'te yalnizca `expose === true` ise mesaj gider, aksi halde genel mesaj.
//     `retryAfter` (sn) varsa `Retry-After` basligi ve `retry_after` alani eklenir.
//     `extra` (duz nesne) varsa yanit govdesine eklenir (ornegin { resend_after }).
//   - Eski kod: err.status / err.statusCode tasiyan Error -> 4xx ise mesaj gider.
//   - body-parser: 413 (PAYLOAD_TOO_LARGE), gecersiz JSON (400 VALIDATION).
//   - Diger her sey: 500 INTERNAL + genel mesaj.

const crypto = require('crypto');

const DEFAULT_CODES = {
  400: 'VALIDATION',
  401: 'INVALID_TOKEN',
  403: 'FORBIDDEN',
  404: 'NOT_FOUND',
  409: 'CONFLICT',
  410: 'GONE',
  413: 'PAYLOAD_TOO_LARGE',
  415: 'UNSUPPORTED_MEDIA_TYPE',
  423: 'LOCKED',
  429: 'RATE_LIMITED',
  500: 'INTERNAL',
  502: 'BAD_GATEWAY',
  503: 'SERVICE_UNAVAILABLE',
};

const GENERIC_5XX = {
  500: 'Sunucu hatası meydana geldi.',
  502: 'Bağlı servis şu anda yanıt vermiyor.',
  503: 'Servis geçici olarak kullanılamıyor.',
};

function defaultCode(status) {
  return DEFAULT_CODES[status] || (status >= 500 ? 'INTERNAL' : 'ERROR');
}

function errorStatus(err) {
  const s = Number(err && (err.status || err.statusCode));
  return Number.isInteger(s) && s >= 400 && s <= 599 ? s : 500;
}

// eslint-disable-next-line no-unused-vars
function errorHandler(err, req, res, next) {
  if (res.headersSent) {
    return next(err);
  }

  // body-parser hatalari
  if (err && err.type === 'entity.too.large') {
    return res.status(413).json({ success: false, message: 'İstek gövdesi çok büyük.', code: 'PAYLOAD_TOO_LARGE' });
  }
  if (err && (err.type === 'entity.parse.failed' || (err instanceof SyntaxError && 'body' in err))) {
    return res.status(400).json({ success: false, message: 'Geçersiz JSON gövdesi.', code: 'VALIDATION' });
  }
  if (err && (err.type === 'encoding.unsupported' || err.type === 'charset.unsupported')) {
    return res.status(415).json({ success: false, message: 'Desteklenmeyen içerik kodlaması.', code: 'UNSUPPORTED_MEDIA_TYPE' });
  }

  const status = errorStatus(err);
  const isHttpError = Boolean(err && err.name === 'HttpError');
  // 5xx'te yalnizca bilincli HttpError kodu gecer (ECONNREFUSED gibi sistem kodlari sizmaz).
  const codeAllowed = isHttpError || status < 500;
  const code = (codeAllowed && err && typeof err.code === 'string' && /^[A-Z][A-Z0-9_]{1,40}$/.test(err.code))
    ? err.code
    : defaultCode(status);

  let message;
  if (status < 500) {
    message = err && typeof err.message === 'string' && err.message ? err.message : 'İstek işlenemedi.';
  } else if (isHttpError && err.expose === true && typeof err.message === 'string') {
    message = err.message;
  } else {
    message = GENERIC_5XX[status] || GENERIC_5XX[500];
  }

  if (status >= 500) {
    const ref = crypto.randomBytes(6).toString('hex');
    // Ic ayrinti yalnizca sunucu log'una (istek govdesi/basliklari LOG'LANMAZ).
    console.error(`[HATA ${ref}] ${req.method} ${req.originalUrl ? String(req.originalUrl).split('?')[0] : ''} -> ${status}`, err && err.stack ? err.stack : err);
    res.setHeader('X-Error-Ref', ref);
  }

  const body = { success: false, message, code };
  if (err && Number.isFinite(err.retryAfter) && err.retryAfter > 0) {
    const ra = Math.ceil(err.retryAfter);
    res.setHeader('Retry-After', String(ra));
    body.retry_after = ra;
  }
  if (err && err.extra && typeof err.extra === 'object' && !Array.isArray(err.extra) && status < 500) {
    for (const [k, v] of Object.entries(err.extra)) {
      if (!(k in body)) body[k] = v;
    }
  }
  return res.status(status).json(body);
}

function notFoundHandler(req, res) {
  return res.status(404).json({ success: false, message: 'İstenen API ucu bulunamadı.', code: 'NOT_FOUND' });
}

/** async route'larda yakalanmayan hatalari global yakalayiciya iletir. */
function asyncHandler(fn) {
  return function wrapped(req, res, next) {
    try {
      const out = fn(req, res, next);
      if (out && typeof out.catch === 'function') out.catch(next);
    } catch (err) {
      next(err);
    }
  };
}

module.exports = {
  errorHandler,
  notFoundHandler,
  asyncHandler,
  defaultCode,
};
