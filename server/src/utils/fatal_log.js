'use strict';

// ==============================================================================
// Sürec duzeyi hatalarin (unhandledRejection / uncaughtException) GUVENLI gunlugu     [plan §5d-5, S3]
// ==============================================================================
//
// Amac: sureci yoneten (PM2/systemd) ve operator icin yigin izi (stack) yazmak; ANCAK sir / jeton / PIN / gövde
// SIZDIRMAMAK. Ham `console.error(err)` / `console.error(reason)` uc yoldan sizdirir:
//   1) Error.message icine giren degerler (ornegin JSON.parse hatasi girdinin parcasini, driver hatasi sorgu
//      parametresini, SMTP hatasi alici adresini tasiyabilir),
//   2) Error DEGIL bir nesneyle reddedilen Promise (ornegin bir HTTP yaniti/istek nesnesi) -> tum alanlari dokulur,
//   3) `cause` zinciri ve ek alanlar (err.detail, err.config ...) -> yalnizca BILINEN guvenli alanlar yazilir.
//
// Yazilanlar: hata ADI, kisa KOD, maskelenmis ve kisaltilmis MESAJ, yigin KARELERI ("at ..." satirlari; yalnizca kod
// konumlari), en fazla 2 seviye `cause`. Error olmayan neden: yalnizca TUR (+ nesnede yalnizca ANAHTAR adlari).
// Modul ASLA firlatmaz (patlayan getter / Proxy / dairesel nesne dahil): gunluk, kapanisi engellememelidir.

const MAX_MESSAGE = 400;
const MAX_FRAMES = 12;
const MAX_CAUSE_DEPTH = 2;
const MAX_KEYS = 10;
const MAX_STRING_REASON = 160;

// Siralama onemli: once belirgin sir bicimleri, sonra genel "uzun opak dizi".
const REDACTIONS = [
  [/\bBearer\s+[A-Za-z0-9._~+/=-]{8,}/gi, 'Bearer [GIZLENDI]'],
  [/\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}(?:\.[A-Za-z0-9_-]*)?/g, '[JWT]'],
  [
    /((?:password|passwd|pass|pwd|pin|token|secret|authorization|api[_-]?key|otp|local[_-]?key|private[_-]?key|credential)s?["']?\s*[:=]\s*)(?:"[^"]*"|'[^']*'|[^\s,;&)}\]]+)/gi,
    '$1[GIZLENDI]',
  ],
  [/[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+/g, '[e-posta]'],
  [/\b[A-Za-z0-9_-]{28,}={0,2}/g, '[GIZLENDI]'], // jeton / ozet / anahtar benzeri uzun opak diziler
  [/\b\d{6,}\b/g, '[sayi]'], // PIN / OTP / telefon benzeri uzun rakam dizileri
];

/** Mesaj metnindeki sir benzeri parcalari maskeler ve kisaltir. Firlatmaz. */
function redactSensitive(value, max = MAX_MESSAGE) {
  try {
    let s = typeof value === 'string' ? value : String(value);
    // eslint-disable-next-line no-control-regex
    s = s.replace(/[\u0000-\u001f\u007f]+/g, ' ');
    for (const [re, to] of REDACTIONS) s = s.replace(re, to);
    s = s.trim();
    return s.length > max ? `${s.slice(0, max)}...` : s;
  } catch (_) {
    return '[okunamadi]';
  }
}

/** Ozellik okuma: getter/Proxy patlarsa undefined (gunluk firlatmaz). */
function safeGet(obj, key) {
  try {
    return obj[key];
  } catch (_) {
    return undefined;
  }
}

function safeCode(code) {
  return typeof code === 'string' && /^[A-Za-z0-9_.-]{1,40}$/.test(code) ? code : null;
}

function safeName(name) {
  return typeof name === 'string' && /^[A-Za-z0-9_$.]{1,60}$/.test(name) ? name : 'Error';
}

/** Yigin izinden YALNIZCA "at ..." karelerini alir (ilk satirlar mesaj icerir -> alinmaz). */
function stackFrames(stack) {
  if (typeof stack !== 'string') return [];
  return stack
    .split('\n')
    .filter((l) => /^\s+at\s/.test(l))
    .slice(0, MAX_FRAMES)
    .map((l) => `    ${l.trim()}`);
}

function describeError(err, depth) {
  const code = safeCode(safeGet(err, 'code'));
  const message = safeGet(err, 'message');
  const head = `${safeName(safeGet(err, 'name'))}${code ? ` [${code}]` : ''}: ${redactSensitive(message === undefined ? '' : message)}`;
  const lines = [head, ...stackFrames(safeGet(err, 'stack'))];
  const cause = safeGet(err, 'cause');
  if (depth < MAX_CAUSE_DEPTH && cause !== undefined && cause !== null) {
    lines.push(`  neden: ${describeReason(cause, depth + 1)}`);
  }
  return lines.join('\n');
}

function describeReason(reason, depth = 0) {
  try {
    if (reason instanceof Error) return describeError(reason, depth);
    // Error benzeri (farkli realm / yapay nesne): yalnizca bilinen alanlar
    if (reason && typeof reason === 'object' && typeof safeGet(reason, 'message') === 'string' && typeof safeGet(reason, 'stack') === 'string') {
      return describeError(reason, depth);
    }
    if (typeof reason === 'string') return `Error olmayan neden (metin): ${redactSensitive(reason, MAX_STRING_REASON)}`;
    if (reason === null || reason === undefined) return `Error olmayan neden (${reason === null ? 'null' : 'undefined'})`;
    if (typeof reason === 'object') {
      // Degerler ASLA yazilmaz (govde/istek/yanit nesnesi olabilir): yalnizca tur ve anahtar adlari.
      let keys = [];
      try {
        keys = Object.keys(reason).slice(0, MAX_KEYS).map((k) => redactSensitive(k, 24));
      } catch (_) {
        keys = [];
      }
      const ctor = safeGet(reason, 'constructor');
      const ctorName = ctor && typeof safeGet(ctor, 'name') === 'string' ? safeName(safeGet(ctor, 'name')) : 'Object';
      return `Error olmayan neden (${ctorName}; anahtarlar: ${keys.join(', ') || '-'})`;
    }
    return `Error olmayan neden (${typeof reason})`;
  } catch (_) {
    return 'Error olmayan neden (okunamadi)';
  }
}

/**
 * @param {string} tag      ornegin 'UNCAUGHT-EXCEPTION'
 * @param {*} reason        Error veya herhangi bir deger
 * @param {{origin?:string}} [meta]
 * @returns {string} tek bir gunluk metni (cok satirli)
 */
function describeFatal(tag, reason, meta = {}) {
  const origin = meta && typeof meta.origin === 'string' && /^[A-Za-z_]{1,40}$/.test(meta.origin) ? ` (${meta.origin})` : '';
  return `[${tag}]${origin} ${describeReason(reason)}`;
}

module.exports = { describeFatal, redactSensitive, describeReason, stackFrames };
