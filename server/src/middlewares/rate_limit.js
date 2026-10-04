'use strict';

// ==============================================================================
// AHBU Akilli Ev - Bellek ici hiz sinirlayici (rate limit) fabrikasi
// ==============================================================================
//
// Kullanim (Express middleware):
//
//   const { rateLimit, clientIp } = require('../middlewares/rate_limit');
//   const loginLimiter = rateLimit({
//     windowMs: 15 * 60 * 1000,                      // pencere (ms)
//     max: 10,                                       // pencere basina izin verilen istek
//     keyGenerator: (req) => `login:${clientIp(req)}`, // anahtar (varsayilan: istemci IP)
//     code: 'RATE_LIMITED',                          // yanit kodu (varsayilan RATE_LIMITED)
//   });
//   router.post('/login', loginLimiter, handler);
//
// Asimda: HTTP 429 + `Retry-After` basligi +
//   { success:false, message, code:'RATE_LIMITED', retry_after:<sn> }
//
// Programatik kullanim (servis katmaninda, ornegin yalnizca BASARISIZ denemeleri saymak):
//   const r = limiter.consume('pin:' + uid);   // sayaci artirir -> { allowed, remaining, retryAfter }
//   const s = limiter.peek('pin:' + uid);      // artirmadan durum
//   limiter.resetKey('pin:' + uid);            // basarida sifirla
//
// NOT: Sayaclar surec belleginde tutulur (tek instance icin yeterli). Coklu instance
// dagitiminda kalici kilitler (PIN deneme sayaci vb.) ayrica veritabaninda tutulmalidir.
// Zamanlayici (setInterval) kullanilmaz; suresi dolan kayitlar istek sirasinda temizlenir,
// bu yuzden testlerde/kapanista acik kalan tutamac (handle) birakmaz.

const net = require('node:net');

const DEFAULT_WINDOW_MS = 15 * 60 * 1000;
const DEFAULT_MAX = 10;
const DEFAULT_MAX_KEYS = 50000;

/**
 * Istemci IP adresi. `app.set('trust proxy', ...)` ayari server.js'te yapilir;
 * boylece `req.ip` yalnizca guvenilen vekil (nginx) zincirinden turetilir.
 * X-Forwarded-For basligi burada DOGRUDAN okunmaz (sahtelenebilir).
 */
function clientIp(req) {
  if (!req) return 'unknown';
  const ip = req.ip || (req.socket && req.socket.remoteAddress) || (req.connection && req.connection.remoteAddress);
  if (!ip) return 'unknown';
  // IPv4-mapped IPv6 (::ffff:1.2.3.4) -> 1.2.3.4
  return String(ip).replace(/^::ffff:/i, '');
}

/**
 * Sinirlayici anahtari icin istemci agi (M1-01): IPv4 (ve ::ffff: eslemesi) aynen; IPv6 /64 onekine indirgenir.
 * Tek bir IPv6 abonesi tipik olarak bir /64 alir (2^64 adres): tam adresle anahtarlama adres dondurerek her
 * IP basina sinirin ve (kimlik | IP) kilidinin etrafindan dolasilmasina izin verirdi. Denetim kaydi (ip) icin
 * `clientIp` (tam adres) kullanilir; bu yardimci YALNIZ sayac anahtarlari icindir.
 * Ornek: '2001:db8:1:2::1' -> '2001:db8:1:2::/64'.
 */
function limitKey(req) {
  const ip = clientIp(req);
  if (ip === 'unknown' || net.isIPv4(ip)) return ip;
  const addr = ip.split('%')[0]; // bolge kimligi (fe80::1%eth0)
  if (!net.isIPv6(addr)) return ip;
  let text = addr.toLowerCase();
  const v4 = text.match(/^(.*:)(\d+\.\d+\.\d+\.\d+)$/); // gomulu IPv4 kuyrugu -> iki hextet
  if (v4) {
    const o = v4[2].split('.').map(Number);
    text = `${v4[1]}${((o[0] << 8) | o[1]).toString(16)}:${((o[2] << 8) | o[3]).toString(16)}`;
  }
  const [head, tail] = text.includes('::') ? text.split('::') : [text, null];
  const headParts = head ? head.split(':') : [];
  const tailParts = tail ? tail.split(':') : [];
  const groups = tail === null ? headParts : [...headParts, ...Array(8 - headParts.length - tailParts.length).fill('0'), ...tailParts];
  return `${groups.slice(0, 4).map((g) => parseInt(g, 16).toString(16)).join(':')}::/64`;
}

function defaultMessage(retryAfterSec) {
  return `Çok fazla istek gönderildi. Lütfen ${retryAfterSec} saniye sonra tekrar deneyin.`;
}

/**
 * Hiz sinirlayici fabrikasi.
 *
 * @param {object}   opts
 * @param {number}   [opts.windowMs=900000]   Sabit pencere suresi (ms).
 * @param {number}   [opts.max=10]            Pencere basina izin verilen istek sayisi.
 * @param {Function} [opts.keyGenerator]      (req) => string. Varsayilan: istemci IP.
 *                                            null/undefined/'' donerse IP kullanilir.
 * @param {string}   [opts.code='RATE_LIMITED'] Yanittaki makine kodu.
 * @param {string|Function} [opts.message]    Sabit metin veya (retryAfterSec) => metin.
 * @param {number}   [opts.statusCode=429]
 * @param {Function} [opts.skip]              (req) => true ise sayilmaz.
 * @param {boolean}  [opts.skipSuccessfulRequests=false] true ise yanit < 400 olan
 *                                            istekler sayactan geri dusulur (yalnizca
 *                                            basarisiz denemeler sayilir; ornek: login).
 * @param {Function} [opts.now=Date.now]      Test icin saat enjeksiyonu.
 * @param {number}   [opts.maxKeys=50000]     Bellek korumasi: en fazla anahtar sayisi.
 * @returns {Function} Express middleware; ek olarak consume/peek/resetKey/reset/size metotlari.
 */
function rateLimit(opts = {}) {
  const windowMs = Number.isFinite(opts.windowMs) && opts.windowMs > 0 ? opts.windowMs : DEFAULT_WINDOW_MS;
  const max = Number.isFinite(opts.max) && opts.max >= 0 ? Math.floor(opts.max) : DEFAULT_MAX;
  const keyGenerator = typeof opts.keyGenerator === 'function' ? opts.keyGenerator : null;
  const code = opts.code || 'RATE_LIMITED';
  const statusCode = opts.statusCode || 429;
  const skip = typeof opts.skip === 'function' ? opts.skip : null;
  const skipSuccessfulRequests = opts.skipSuccessfulRequests === true;
  const now = typeof opts.now === 'function' ? opts.now : Date.now;
  const maxKeys = Number.isFinite(opts.maxKeys) && opts.maxKeys > 0 ? opts.maxKeys : DEFAULT_MAX_KEYS;
  const message = opts.message;

  /** @type {Map<string, {count:number, resetAt:number}>} */
  const hits = new Map();
  let lastSweep = now();

  function sweep(t) {
    if (t - lastSweep < Math.min(windowMs, 60 * 1000) && hits.size < maxKeys) return;
    lastSweep = t;
    for (const [k, v] of hits) {
      if (v.resetAt <= t) hits.delete(k);
    }
    // Hala cok fazla anahtar varsa en eskileri at (Map ekleme sirasini korur).
    while (hits.size >= maxKeys) {
      const oldest = hits.keys().next().value;
      if (oldest === undefined) break;
      hits.delete(oldest);
    }
  }

  function getEntry(key, t) {
    let entry = hits.get(key);
    if (!entry || entry.resetAt <= t) {
      sweep(t);
      entry = { count: 0, resetAt: t + windowMs };
      hits.set(key, entry);
    }
    return entry;
  }

  function status(entry, t) {
    const retryAfter = Math.max(1, Math.ceil((entry.resetAt - t) / 1000));
    return {
      allowed: entry.count <= max,
      count: entry.count,
      limit: max,
      remaining: Math.max(0, max - entry.count),
      retryAfter,
      resetAt: entry.resetAt,
    };
  }

  function normalizeKey(raw, req) {
    if (raw === null || raw === undefined || raw === '') return `ip:${clientIp(req)}`;
    return String(raw);
  }

  /** Sayaci bir artirir ve durumu doner. */
  function consume(key) {
    const t = now();
    const entry = getEntry(String(key), t);
    entry.count += 1;
    return status(entry, t);
  }

  /** Sayaci artirmadan durumu doner (izin verilecek mi?). */
  function peek(key) {
    const t = now();
    const entry = hits.get(String(key));
    if (!entry || entry.resetAt <= t) {
      return { allowed: true, count: 0, limit: max, remaining: max, retryAfter: 0, resetAt: t + windowMs };
    }
    const s = status(entry, t);
    // peek "bir sonraki istek kabul edilir mi?" sorusunu yanitlar.
    s.allowed = entry.count < max;
    return s;
  }

  function resetKey(key) {
    hits.delete(String(key));
  }

  function reset() {
    hits.clear();
  }

  function sendLimited(res, s) {
    const text = typeof message === 'function' ? message(s.retryAfter) : (message || defaultMessage(s.retryAfter));
    res.setHeader('Retry-After', String(s.retryAfter));
    return res.status(statusCode).json({
      success: false,
      message: text,
      code,
      retry_after: s.retryAfter,
    });
  }

  function middleware(req, res, next) {
    try {
      if (skip && skip(req)) return next();
    } catch (_) {
      // skip hatasi durumunda sinirlama UYGULANIR (fail-closed).
    }

    let key;
    try {
      key = normalizeKey(keyGenerator ? keyGenerator(req) : null, req);
    } catch (_) {
      key = normalizeKey(null, req);
    }

    const s = consume(key);
    res.setHeader('RateLimit-Limit', String(max));
    res.setHeader('RateLimit-Remaining', String(s.remaining));
    res.setHeader('RateLimit-Reset', String(s.retryAfter));

    if (!s.allowed) {
      return sendLimited(res, s);
    }

    if (skipSuccessfulRequests && typeof res.on === 'function') {
      res.on('finish', () => {
        if (res.statusCode < 400) {
          const entry = hits.get(key);
          if (entry && entry.count > 0) entry.count -= 1;
        }
      });
    }

    return next();
  }

  middleware.consume = consume;
  middleware.peek = peek;
  middleware.resetKey = resetKey;
  middleware.reset = reset;
  middleware.size = () => hits.size;
  middleware.keys = () => Array.from(hits.keys()); // tani/test: tutulan anahtarlar (bellek denetimi)
  middleware.options = Object.freeze({ windowMs, max, code, statusCode });
  return middleware;
}

module.exports = rateLimit;
module.exports.rateLimit = rateLimit;
module.exports.clientIp = clientIp;
module.exports.limitKey = limitKey;
