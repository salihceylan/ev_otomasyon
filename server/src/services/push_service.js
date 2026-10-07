'use strict';

// ==============================================================================
// AHBU Akıllı Ev - Push (FCM HTTP v1) servisi + token kayıt deposu            [WP-H §3.2]
// ==============================================================================
//
//   const { createPushService } = require('./services/push_service');
//   const push = createPushService({ db, logger });
//   await push.upsertToken({ userId, token, platform: 'android', appVersion: '1.2.0' });
//   const tokens = await push.recipientsForHome(homeId);            // [{ id, userId, token, platform }]
//   const r = await push.sendNotice({ tokens, title, body, data }); // { attempted, sent, failed, ... }
//
// Neden böyle?
//   - firebase-admin YOK: FCM v1 REST'i, zaten kurulu `google-auth-library` (yalnızca erişim
//     jetonu için) ve global `fetch` ile çağırıyoruz; yeni bağımlılık eklenmez. v1'de toplu gönderim
//     yoktur: jeton başına bir istek, eşzamanlılık <= 5.
//   - `google-auth-library` TEMBEL yüklenir (yalnızca varsayılan authFactory içinde): kimlik bilgisi
//     olmayan ortamda (test, geliştirme) modül yine yüklenir ve `isConfigured()` false döner.
//   - Yapılandırılmamışsa `sendNotice` ağa HİÇ çıkmaz ve fırlatmaz: hatırlatıcı yine kaydını yazar
//     (`no_recipients` + sebep), böylece "push henüz kurulmamış" gece hatırlatmasını düşürmez.
//   - Loglara yalnızca SAYILAR ve ev kimliği öneki yazılır; jeton, başlık/gövde, oda adı, hata
//     gövdesi ASLA yazılmaz (jeton cihaza bildirim gönderme yetkisidir; oda adları kişisel veridir).
//   - Bağımlılıkların hepsi (db, fetch, kimlik, saat, ortam) enjekte edilir; modül düzeyinde
//     gizli durum yoktur (test izolasyonu, çoklu örnek).
//
// authFactory sözleşmesi:
//   authFactory({ keyFile, credentials, scopes }) -> { getAccessToken(): Promise<string | { token }> }
//   (varsayılan: `new GoogleAuth({ keyFilename | credentials, scopes })`). 401/403 sonrası kimlik
//   nesnesi ATILIR ve factory yeniden çağrılır (önbellekteki bayat jeton yeniden kullanılmasın).

const FCM_SCOPE = 'https://www.googleapis.com/auth/firebase.messaging';
const MESSAGE_VERSION = 1;

const DEFAULT_TIMEOUT_MS = 5000; // jeton başına istek zaman aşımı
const MAX_CONCURRENCY = 5; // spec: eşzamanlılık <= 5
const MESSAGE_TTL_SEC = 3600; // gece hatırlatması sabaha kalırsa anlamsız; 1 saat sonra düş
const MAX_RETRY_AFTER_SEC = 3600;
const MAX_TITLE_CHARS = 100;
const MAX_BODY_CHARS = 400;
const MIN_START_BUDGET_MS = 50; // kalan süre bundan azsa yeni istek başlatılmaz (başlar başlamaz kesilecek istek yük bindirir)
const DEFAULT_DEADLINE_MS = 10000; // sendNotice toplam süre sınırı: evaluator ev zaman aşımının (15 sn) ve 2 dk'lık kira süresinin çok altında
const MAX_RECIPIENT_TOKENS = 100; // ev başına üst sınır (yeniden yüklemelerden biriken eski jetonlara karşı)
const MAX_RECIPIENT_TOKENS_PER_USER = 3; // kullanıcı başına: tek hesap alıcı listesini doldurup başkalarını dışarıda bırakamasın
const MAX_ACTIVE_TOKENS_PER_USER = 10; // kayıt anında kullanıcı başına üst sınır; fazlası (en eski) silinir
const ORPHAN_TOKEN_DAYS = 7; // hiçbir evde owner/resident olmayan kullanıcının bu kadar süredir görülmeyen jetonu temizlenir
const DEFAULT_CLEANUP_DAYS = 30;
const MAX_CLEANUP_DAYS = 3650;

const NOTICE_TYPE = 'peace_open_devices';
const NOTICE_ACTION = 'close_all';
const ANDROID_CHANNEL_ID = 'peace_reminder';
const APNS_CATEGORY = 'PEACE_CLOSE_ALL';

// --- Güvenlik push türleri (WP-S3, tasarım §5.2.3; kararlar §7.2b-3/4) ---
// safety_alarm: alarm açıldı / vana arızası (owner + resident). Android yüksek önem kanalı (uygulama oluşturur),
//   APNs `time-sensitive` (kritik uyarı izni başvurusu YOK, §7.2b-3). collapse = alarm_<ev>_<pano>_<bölge>.
// safety_info : alarm durumu doğrulanamadı (lost) / politika değişti (yalnız owner), bilgi kanalı.
const PUSH_KINDS = Object.freeze(['peace', 'safety_alarm', 'safety_info']);
const SAFETY_ALARM_TTL_SEC = 6 * 3600;
const SAFETY_INFO_TTL_SEC = 24 * 3600;
const SAFETY_ALARM_CHANNEL_ID = 'safety_alarm';
const SAFETY_INFO_CHANNEL_ID = 'safety_info';
const SAFETY_ALARM_CATEGORY = 'SAFETY_ALARM';
const SAFETY_INFO_CATEGORY = 'SAFETY_INFO';
const SAFETY_TOKEN_RE = /^[a-z][a-z0-9_]{0,23}$/; // kind / status / reason: kısa makine kodu
// Bildirim alabilecek ev rolleri: misafir ve servis rolleri HİÇBİR türde almaz (§7.2b-4).
const RECIPIENT_ROLES = Object.freeze(['owner', 'resident']);

// Jeton / sürüm doğrulaması (route ve servis aynı kuralı kullanır).
const TOKEN_MIN = 20;
const TOKEN_MAX = 512;
const TOKEN_RE = /^[\x21-\x7E]+$/; // görünür ASCII, boşluk yok
const APP_VERSION_MAX = 32;
const APP_VERSION_RE = /^[\x20-\x7E]+$/;
const PLATFORMS = Object.freeze(['android', 'ios']);
const SAFE_ID_RE = /^[A-Za-z0-9_-]{1,64}$/;
// Faz 2 F2.C.8: push data.device_uuid (uygulama SafetyPushNotice ile ayni kural: ^[A-Z0-9-]{1,32}$).
const DEVICE_UUID_DATA_RE = /^[A-Z0-9-]{1,32}$/;
const SAFE_CODE_RE = /^[A-Z][A-Z0-9_]{1,39}$/;

// FCM hata kodlarının sınıflandırması (https://firebase.google.com/docs/reference/fcm/rest/v1/ErrorCode).
// Yalnızca `details[].errorCode === 'UNREGISTERED'` jetonun KALICI geçersiz olduğunu kanıtlar. Düz bir
// HTTP 404 / `status: NOT_FOUND` ("Requested entity was not found") yanlış FCM_PROJECT_ID veya proje/API
// uyuşmazlığında da döner; bunu jeton hatası saymak tüm jetonları bir yazım hatasıyla devre dışı bırakırdı.
const INVALID_TOKEN_CODES = new Set(['UNREGISTERED']);
const TRANSIENT_CODES = new Set(['UNAVAILABLE', 'INTERNAL', 'QUOTA_EXCEEDED', 'RESOURCE_EXHAUSTED', 'DEADLINE_EXCEEDED']);
const PER_TOKEN_AUTH_CODES = new Set(['SENDER_ID_MISMATCH']); // jetona özgü; kimlik yenilemek çözmez

// ---------------------------------------------------------------------------
// Doğrulama (route da kullanır)
// ---------------------------------------------------------------------------
function validationError(message) {
  const err = new Error(message);
  err.status = 400;
  err.statusCode = 400;
  err.code = 'VALIDATION';
  return err;
}

/** Jeton: 20-512 karakter görünür ASCII. Başındaki/sonundaki boşluk atılır. @returns {string} */
function normalizeToken(token) {
  if (typeof token !== 'string') throw validationError('Bildirim anahtarı (token) metin olmalıdır.');
  const t = token.trim();
  if (t.length < TOKEN_MIN || t.length > TOKEN_MAX || !TOKEN_RE.test(t)) {
    throw validationError(`Bildirim anahtarı ${TOKEN_MIN}-${TOKEN_MAX} karakter uzunluğunda olmalı ve boşluk içermemelidir.`);
  }
  return t;
}

/** Platform beyaz listesi (küçük harfe çevrilir). @returns {'android'|'ios'} */
function normalizePlatform(platform) {
  const p = typeof platform === 'string' ? platform.trim().toLowerCase() : '';
  if (!PLATFORMS.includes(p)) throw validationError("Platform 'android' veya 'ios' olmalıdır.");
  return p;
}

/** Uygulama sürümü: isteğe bağlı, <= 32 karakter. @returns {string|null} */
function normalizeAppVersion(appVersion) {
  if (appVersion === undefined || appVersion === null || appVersion === '') return null;
  if (typeof appVersion !== 'string') throw validationError('Uygulama sürümü metin olmalıdır.');
  const v = appVersion.trim();
  if (v.length === 0) return null;
  if (v.length > APP_VERSION_MAX || !APP_VERSION_RE.test(v)) {
    throw validationError(`Uygulama sürümü en fazla ${APP_VERSION_MAX} yazdırılabilir karakter olmalıdır.`);
  }
  return v;
}

// ---------------------------------------------------------------------------
// FCM mesajı
// ---------------------------------------------------------------------------
function clampText(value, maxChars) {
  const s = typeof value === 'string' ? value : '';
  const chars = Array.from(s); // kod noktası bazlı: yarım vekil çifti (surrogate) bırakma
  return chars.length > maxChars ? chars.slice(0, maxChars - 1).join('') + '…' : s;
}

function toCount(value) {
  const n = Math.trunc(Number(value));
  return Number.isFinite(n) && n > 0 ? n : 0;
}

/**
 * `data` YALNIZ string değerler taşır (FCM v1 `map<string,string>`). Çağıran camelCase veya
 * snake_case verebilir; bilinen alanlar dışındakiler (kişisel veri sızmasın) aktarılmaz.
 */
function buildDataPayload(data) {
  const d = data && typeof data === 'object' ? data : {};
  const pick = (...keys) => {
    for (const k of keys) if (d[k] !== undefined && d[k] !== null) return d[k];
    return undefined;
  };
  const homeRaw = pick('home_id', 'homeId');
  const noticeRaw = pick('notice_id', 'noticeId');
  return {
    type: NOTICE_TYPE,
    home_id: homeRaw !== undefined && SAFE_ID_RE.test(String(homeRaw)) ? String(homeRaw) : '',
    notice_id: noticeRaw !== undefined ? String(noticeRaw).slice(0, 64) : '',
    open_lights: String(toCount(pick('open_lights', 'openLights'))),
    open_shutters: String(toCount(pick('open_shutters', 'openShutters'))),
    action: NOTICE_ACTION,
    v: String(MESSAGE_VERSION),
  };
}

/** Güvenlik verisi: YALNIZ bilinen alanlar, hepsi dizge (kişisel veri / serbest metin aktarılmaz). */
function buildSafetyData(type, data) {
  const d = data && typeof data === 'object' ? data : {};
  const pick = (...keys) => {
    for (const k of keys) if (d[k] !== undefined && d[k] !== null) return d[k];
    return undefined;
  };
  const safeId = (v) => (v !== undefined && SAFE_ID_RE.test(String(v)) ? String(v) : '');
  const token = (v) => (v !== undefined && SAFETY_TOKEN_RE.test(String(v)) ? String(v) : '');
  const out = {
    type,
    v: String(MESSAGE_VERSION),
    home_id: safeId(pick('home_id', 'homeId')),
    device_id: safeId(pick('device_id', 'deviceId')),
    alarm_id: safeId(pick('alarm_id', 'alarmId')),
  };
  // Faz 2 F2.C.8: panonun uid'si (devices.device_uuid; uygulama kart anahtari). Gecersiz bicim ATILIR (alan yazilmaz).
  const uuidRaw = pick('device_uuid', 'deviceUuid');
  if (typeof uuidRaw === 'string' && DEVICE_UUID_DATA_RE.test(uuidRaw.trim().toUpperCase())) {
    out.device_uuid = uuidRaw.trim().toUpperCase();
  }
  if (type === 'safety_alarm') {
    const zone = Math.trunc(Number(pick('zone')));
    out.zone = Number.isInteger(zone) && zone >= 1 && zone <= 4 ? String(zone) : '';
    out.kind = token(pick('kind'));
    out.status = token(pick('status'));
  } else {
    out.reason = token(pick('reason'));
  }
  return out;
}

/** safety_alarm / safety_info FCM v1 gövdesi. */
function buildSafetyMessage({ token, title, body, data, nowMs, kind }) {
  const alarm = kind === 'safety_alarm';
  const payload = buildSafetyData(kind, data);
  const ttl = alarm ? SAFETY_ALARM_TTL_SEC : SAFETY_INFO_TTL_SEC;
  const collapse = alarm
    ? `alarm_${payload.home_id || 'unknown'}_${payload.device_id || 'unknown'}_${payload.zone || '0'}`
    : `safety_info_${payload.home_id || 'unknown'}`;
  const expirySec = Math.floor(Number(nowMs) / 1000) + ttl;
  return {
    message: {
      token,
      notification: { title: clampText(title, MAX_TITLE_CHARS), body: clampText(body, MAX_BODY_CHARS) },
      data: payload,
      android: {
        priority: 'HIGH',
        ttl: `${ttl}s`,
        collapse_key: collapse,
        notification: { channel_id: alarm ? SAFETY_ALARM_CHANNEL_ID : SAFETY_INFO_CHANNEL_ID, tag: collapse },
      },
      apns: {
        headers: {
          'apns-priority': alarm ? '10' : '5',
          'apns-collapse-id': collapse,
          'apns-expiration': String(expirySec),
        },
        payload: {
          aps: {
            category: alarm ? SAFETY_ALARM_CATEGORY : SAFETY_INFO_CATEGORY,
            'thread-id': payload.home_id || 'unknown',
            sound: 'default',
            'interruption-level': alarm ? 'time-sensitive' : 'active',
          },
        },
      },
    },
  };
}

/**
 * FCM HTTP v1 mesaj gövdesi. Aynı ev için gelen yeni bildirim eskisinin YERİNE geçsin diye
 * collapse anahtarları ev bazlıdır (yeniden deneme çift bildirim üretmez).
 * `kind`: 'peace' (varsayılan; gece hatırlatması, AYNEN) | 'safety_alarm' | 'safety_info' (WP-S3).
 * @param {{ token:string, title:string, body:string, data?:object, nowMs:number, kind?:string }} p
 */
function buildMessage({ token, title, body, data, nowMs, kind }) {
  if (kind === 'safety_alarm' || kind === 'safety_info') return buildSafetyMessage({ token, title, body, data, nowMs, kind });
  const payload = buildDataPayload(data);
  const collapse = `peace_${payload.home_id || 'unknown'}`;
  const expirySec = Math.floor(Number(nowMs) / 1000) + MESSAGE_TTL_SEC;
  return {
    message: {
      token,
      notification: { title: clampText(title, MAX_TITLE_CHARS), body: clampText(body, MAX_BODY_CHARS) },
      data: payload,
      android: {
        priority: 'HIGH',
        ttl: `${MESSAGE_TTL_SEC}s`,
        collapse_key: collapse,
        notification: { channel_id: ANDROID_CHANNEL_ID, tag: collapse },
      },
      apns: {
        headers: {
          'apns-priority': '10',
          'apns-collapse-id': collapse,
          'apns-expiration': String(expirySec),
        },
        payload: {
          aps: { category: APNS_CATEGORY, 'thread-id': payload.home_id || 'unknown', sound: 'default' },
        },
      },
    },
  };
}

// ---------------------------------------------------------------------------
// Hata ayrıştırma / sınıflandırma
// ---------------------------------------------------------------------------
/** FCM hata gövdesinden makine kodunu çıkarır (güvensiz metin ASLA yansıtılmaz). */
function parseFcmError(text) {
  let obj;
  try {
    obj = JSON.parse(text);
  } catch (_) {
    return { code: null, fcmCode: null, tokenRelated: false };
  }
  const e = obj && typeof obj === 'object' ? obj.error : null;
  if (!e || typeof e !== 'object') return { code: null, fcmCode: null, tokenRelated: false };

  let fcmCode = null;
  let tokenRelated = false;
  for (const detail of Array.isArray(e.details) ? e.details : []) {
    if (!detail || typeof detail !== 'object') continue;
    if (typeof detail.errorCode === 'string') fcmCode = detail.errorCode;
    if (Array.isArray(detail.fieldViolations)
      && detail.fieldViolations.some((v) => v && /token/i.test(String(v.field)))) {
      tokenRelated = true;
    }
  }
  const msg = typeof e.message === 'string' ? e.message : '';
  if (/registration token|message\.token/i.test(msg)) tokenRelated = true;

  const safe = (c) => (c && SAFE_CODE_RE.test(c) ? c : null);
  const code = fcmCode || (typeof e.status === 'string' ? e.status : null);
  // `fcmCode` yalnızca FcmError ayrıntısından gelir (gRPC `status` metni DEĞİL): jeton geçersizliği
  // kararı yalnızca buna dayanır.
  return { code: safe(code), fcmCode: safe(fcmCode), tokenRelated };
}

function parseRetryAfter(value) {
  if (value === undefined || value === null) return null;
  const n = Number(String(value).trim());
  if (Number.isFinite(n) && n >= 0) return Math.min(Math.ceil(n), MAX_RETRY_AFTER_SEC);
  return null; // HTTP-date biçimi desteklenmez: yalnızca raporlanan bir ipucu
}

/**
 * @returns {{ outcome:'sent'|'invalid'|'failed', status:number, code:string|null, transient:boolean }}
 */
function classify(attempt) {
  const { status, code, fcmCode } = attempt;
  if (status >= 200 && status < 300) return { outcome: 'sent', status, code: null, transient: false };
  if (status === 0) return { outcome: 'failed', status, code, transient: true }; // ağ / zaman aşımı
  if (fcmCode && INVALID_TOKEN_CODES.has(fcmCode)) {
    return { outcome: 'invalid', status, code: fcmCode, transient: false };
  }
  if (status === 404) {
    // UNREGISTERED kanıtı yok: büyük olasılıkla yapılandırma (FCM_PROJECT_ID / API etkin değil).
    // Jetonlara DOKUNMA; operatör düzeltince bir sonraki denemede gider.
    return { outcome: 'failed', status, code: code || 'HTTP_404', transient: true, config404: true };
  }
  if (status === 400 && code === 'INVALID_ARGUMENT' && attempt.tokenRelated) {
    return { outcome: 'invalid', status, code, transient: false };
  }
  if (status === 429 || status >= 500 || (code && TRANSIENT_CODES.has(code))) {
    return { outcome: 'failed', status, code: code || `HTTP_${status}`, transient: true };
  }
  if (status === 401 || status === 403) {
    // Yenileme sonrası hâlâ reddedildi: kimlik/yetki sorunu operatör düzeltince geçer -> yeniden denenebilir.
    const perToken = code && PER_TOKEN_AUTH_CODES.has(code);
    return { outcome: 'failed', status, code: code || `HTTP_${status}`, transient: !perToken };
  }
  return { outcome: 'failed', status, code: code || `HTTP_${status}`, transient: false };
}

// ---------------------------------------------------------------------------
// Varsayılan kimlik üretici (google-auth-library TEMBEL yüklenir)
// ---------------------------------------------------------------------------
function defaultAuthFactory({ keyFile, credentials, scopes }) {
  const { GoogleAuth } = require('google-auth-library');
  const opts = { scopes };
  if (keyFile) opts.keyFilename = keyFile;
  else if (credentials) opts.credentials = credentials;
  return new GoogleAuth(opts);
}

function nonEmpty(value) {
  return typeof value === 'string' && value.trim() !== '' ? value.trim() : '';
}

/**
 * `promise` `ms` içinde bitmezse `{ code: 'TIMEOUT' }` ile reddeder. İptal edilemeyen işler (OAuth/metadata
 * çağrısı) için: yarışı kaybeden söz yetim kalır ama yakalanmamış ret üretmez.
 */
function withTimeout(promise, ms) {
  let timer;
  const timeout = new Promise((_, reject) => {
    timer = setTimeout(() => reject(Object.assign(new Error('timeout'), { code: 'TIMEOUT' })), Math.max(1, ms));
  });
  Promise.resolve(promise).catch(() => {});
  return Promise.race([promise, timeout]).finally(() => clearTimeout(timer));
}

async function runPool(items, limit, worker) {
  const results = new Array(items.length);
  let next = 0;
  const runners = [];
  for (let r = 0; r < Math.min(limit, items.length); r += 1) {
    runners.push((async () => {
      for (;;) {
        const i = next;
        next += 1;
        if (i >= items.length) return;
        results[i] = await worker(items[i]);
      }
    })());
  }
  await Promise.all(runners);
  return results;
}

// ---------------------------------------------------------------------------
// Servis
// ---------------------------------------------------------------------------
/**
 * @param {object} deps
 * @param {{query:Function}} [deps.db]      varsayılan: ../db (tembel)
 * @param {object}   [deps.logger]          log/warn/error (varsayılan console)
 * @param {Function} [deps.fetchImpl]       varsayılan: global fetch (çağrı anında çözülür)
 * @param {Function} [deps.authFactory]     bkz. dosya başlığı
 * @param {object}   [deps.env]             varsayılan: process.env
 * @param {Function} [deps.now]             () => ms
 * @param {number}   [deps.timeoutMs]       varsayılan 5000
 * @param {number}   [deps.concurrency]     varsayılan/üst sınır 5
 * @param {number}   [deps.deadlineMs]      sendNotice toplam süre sınırı (varsayılan 10 sn; çağrı başına ezilebilir)
 * @param {Function} [deps.monotonic]       () => ms tekdüze saat (varsayılan performance.now); süre sınırı içindir
 */
function createPushService(deps = {}) {
  const env = deps.env || process.env;
  const logger = deps.logger || console;
  const nowMs = () => {
    const v = typeof deps.now === 'function' ? deps.now() : Date.now();
    return v instanceof Date ? v.getTime() : Number(v);
  };
  const authFactory = typeof deps.authFactory === 'function' ? deps.authFactory : defaultAuthFactory;
  const timeoutMs = Number.isFinite(deps.timeoutMs) && deps.timeoutMs > 0 ? deps.timeoutMs : DEFAULT_TIMEOUT_MS;
  const concurrency = Number.isInteger(deps.concurrency) && deps.concurrency > 0
    ? Math.min(deps.concurrency, MAX_CONCURRENCY)
    : MAX_CONCURRENCY;
  const defaultDeadlineMs = Number.isFinite(deps.deadlineMs) && deps.deadlineMs > 0 ? deps.deadlineMs : DEFAULT_DEADLINE_MS;
  const monotonic = typeof deps.monotonic === 'function' ? deps.monotonic : () => performance.now();

  let authClient = null; // örnekler arası paylaşılmaz; 401/403 sonrası atılır

  const getDb = () => deps.db || require('../db');

  function log(level, message) {
    const fn = logger && (logger[level] || logger.log);
    if (typeof fn !== 'function') return;
    try {
      fn.call(logger, `[PUSH] ${message}`);
    } catch (_) {
      // loglama hatası gönderimi bozmasın
    }
  }

  // --- yapılandırma ---------------------------------------------------------
  // Servis hesabı anahtarı YALNIZCA dosya yoluyla verilir: özel anahtarı ortam değişkenine gömmek
  // (crash dökümü, ps, compose dosyası) sızıntının olağan yoludur; gömülü JSON seçeneği bilerek YOK.
  function credentialSource() {
    return { file: nonEmpty(env.FCM_SERVICE_ACCOUNT_FILE) || nonEmpty(env.GOOGLE_APPLICATION_CREDENTIALS) };
  }

  /** Yalnızca değişken ADLARINA bakar; hiçbir dosyayı okumaz, ağa çıkmaz. */
  function isConfigured() {
    const src = credentialSource();
    return nonEmpty(env.FCM_PROJECT_ID) !== '' && src.file !== '';
  }

  async function fetchAccessToken() {
    if (!authClient) {
      const src = credentialSource();
      authClient = authFactory({
        keyFile: src.file,
        scopes: [FCM_SCOPE],
      });
    }
    const raw = await authClient.getAccessToken();
    const token = typeof raw === 'string' ? raw : raw && raw.token;
    if (typeof token !== 'string' || token === '') throw new Error('empty access token');
    return token;
  }

  // --- token deposu ---------------------------------------------------------
  /**
   * Jetonu kullanıcıya bağlar (paylaşılan telefonda yeni kullanıcıya yeniden bağlama dahil).
   *
   * Kullanıcı başına en fazla MAX_ACTIVE_TOKENS_PER_USER etkin jeton tutulur: kayıt ucu rastgele
   * jeton dizeleriyle doldurulursa tablo sınırsız büyümesin ve gerçek cihazlar alıcı listesinden
   * itilmesin. Taşan (en eski görülen) jetonlar AYNI deyimde silinir (tek deyim = atomik); kayıt
   * edilen jeton hiçbir zaman budanmaz. DELETE seçildi (devre dışı bırakma değil): devre dışı satır
   * 30 gün tabloda kalırdı. Silinen gerçek bir cihaz, uygulama açılışındaki yeniden kayıtla döner.
   * @returns {Promise<{id:string|null}>}
   */
  async function upsertToken({ userId, token, platform, appVersion } = {}) {
    if (typeof userId !== 'string' || userId === '') throw validationError('Kullanıcı kimliği zorunludur.');
    const t = normalizeToken(token);
    const p = normalizePlatform(platform);
    const v = normalizeAppVersion(appVersion);
    const r = await getDb().query(
      `WITH upserted AS (
         INSERT INTO push_tokens (user_id, token, platform, app_version, created_at, last_seen_at, disabled_at)
         VALUES ($1, $2, $3, $4, now(), now(), NULL)
         ON CONFLICT (token) DO UPDATE
            SET user_id      = EXCLUDED.user_id,
                platform     = EXCLUDED.platform,
                app_version  = EXCLUDED.app_version,
                last_seen_at = now(),
                disabled_at  = NULL
         RETURNING id
       ), pruned AS (
         DELETE FROM push_tokens
          WHERE id IN (
            SELECT id FROM push_tokens
             WHERE user_id = $1 AND disabled_at IS NULL AND token <> $2
             ORDER BY last_seen_at DESC, id
             OFFSET $5
          )
       )
       SELECT id FROM upserted`,
      [userId, t, p, v, MAX_ACTIVE_TOKENS_PER_USER - 1]
    );
    return { id: (r.rows && r.rows[0] && r.rows[0].id) || null };
  }

  /**
   * Kullanıcının TÜM etkin jetonlarını devre dışı bırakır (oturumlar kapatılınca / parola sıfırlanınca /
   * hesap askıya alınınca: kaybolan veya satılan telefon eski sahibin ev ve oda adlarını gece
   * bildirimiyle göstermeye devam etmesin). Çağıran `tx` verirse aynı işlemde çalışır.
   * @param {string|{userId:string, tx?:{query:Function}}} arg
   * @returns {Promise<number>} etkilenen satır sayısı
   */
  async function disableAllTokensForUser(arg) {
    const userId = arg && typeof arg === 'object' ? arg.userId : arg;
    const runner = (arg && typeof arg === 'object' && arg.tx) || getDb();
    if (typeof userId !== 'string' || userId === '') throw validationError('Kullanıcı kimliği zorunludur.');
    const r = await runner.query(
      'UPDATE push_tokens SET disabled_at = now() WHERE user_id = $1 AND disabled_at IS NULL',
      [userId]
    );
    return r.rowCount || 0;
  }

  /**
   * Jetonu devre dışı bırakır (silmez: temizlik `cleanup` ile 30+ gün sonra). `userId` verilirse
   * yalnızca o kullanıcının jetonu etkilenir (başkasının jetonunu iptal edemez).
   * @returns {Promise<number>} etkilenen satır sayısı
   */
  async function disableToken({ token, userId } = {}) {
    const t = normalizeToken(token);
    const db = getDb();
    const r = userId
      ? await db.query(
        `UPDATE push_tokens SET disabled_at = now()
          WHERE token = $1 AND user_id = $2 AND disabled_at IS NULL`,
        [t, userId]
      )
      : await db.query(
        `UPDATE push_tokens SET disabled_at = now()
          WHERE token = $1 AND disabled_at IS NULL`,
        [t]
      );
    return r.rowCount || 0;
  }

  /**
   * Evin bildirim alacak cihazları: yalnızca owner + resident (misafir/servis hariç), aktif hesap,
   * devre dışı olmayan jeton. `roles` (WP-S3): bu kümenin ALT kümesi (ör. bilgi push'u yalnız ['owner']);
   * misafir/servis rolü verilse de süzülür, geçerli rol kalmazsa sorgu yapılmaz.
   * @returns {Promise<Array<{id:string,userId:string,token:string,platform:string}>>}
   */
  async function recipientsForHome(homeId, { roles } = {}) {
    if (roles !== undefined) {
      const wanted = (Array.isArray(roles) ? roles : []).filter((r) => RECIPIENT_ROLES.includes(r));
      const uniq = RECIPIENT_ROLES.filter((r) => wanted.includes(r));
      if (uniq.length === 0) return [];
      const rr = await getDb().query(
        `SELECT id, user_id, token, platform
           FROM (
             SELECT pt.id, pt.user_id, pt.token, pt.platform, pt.last_seen_at,
                    row_number() OVER (PARTITION BY pt.user_id ORDER BY pt.last_seen_at DESC, pt.id) AS rn
               FROM home_users hu
               JOIN users u        ON u.id = hu.user_id
                                  AND u.is_active IS NOT FALSE
                                  AND u.account_status = 'active'
               JOIN push_tokens pt ON pt.user_id = u.id
                                  AND pt.disabled_at IS NULL
              WHERE hu.home_id = $1
                AND hu.role IN ('owner', 'resident')
                AND hu.role = ANY($4::text[])
           ) ranked
          WHERE rn <= $2
          ORDER BY last_seen_at DESC, id
          LIMIT $3`,
        [homeId, MAX_RECIPIENT_TOKENS_PER_USER, MAX_RECIPIENT_TOKENS, uniq]
      );
      return (rr.rows || []).map((row) => ({ id: row.id, userId: row.user_id, token: row.token, platform: row.platform }));
    }
    // Önce kullanıcı başına en yeni N jeton (row_number), SONRA genel LIMIT: tek bir hesap ne kadar
    // jeton kaydederse kaydetsin listeden en çok N yer alır; ev sahibinin gerçek cihazı itilmez.
    const r = await getDb().query(
      `SELECT id, user_id, token, platform
         FROM (
           SELECT pt.id, pt.user_id, pt.token, pt.platform, pt.last_seen_at,
                  row_number() OVER (PARTITION BY pt.user_id ORDER BY pt.last_seen_at DESC, pt.id) AS rn
             FROM home_users hu
             JOIN users u        ON u.id = hu.user_id
                                AND u.is_active IS NOT FALSE
                                AND u.account_status = 'active'
             JOIN push_tokens pt ON pt.user_id = u.id
                                AND pt.disabled_at IS NULL
            WHERE hu.home_id = $1
              AND hu.role IN ('owner', 'resident')
         ) ranked
        WHERE rn <= $2
        ORDER BY last_seen_at DESC, id
        LIMIT $3`,
      [homeId, MAX_RECIPIENT_TOKENS_PER_USER, MAX_RECIPIENT_TOKENS]
    );
    return (r.rows || []).map((row) => ({
      id: row.id,
      userId: row.user_id,
      token: row.token,
      platform: row.platform,
    }));
  }

  /**
   * Bakım: (a) `disabled_at`'i `olderThanDays`+ gün eski jetonları, (b) hiçbir evde owner/resident olmayan
   * kullanıcıların ORPHAN_TOKEN_DAYS+ gündür görülmeyen jetonlarını siler. (b) ev üyeliği olmayan
   * hesapların (misafir, ev kurmamış, çıkarılmış) biriken/sahte jetonlarını sınırlar; yeni katılan bir
   * kullanıcının jetonu uygulama açılışında tazelendiği (last_seen_at) için etkilenmez.
   * @returns {Promise<number>} silinen satır
   */
  async function cleanup({ olderThanDays = DEFAULT_CLEANUP_DAYS } = {}) {
    const days = Number.isInteger(olderThanDays) && olderThanDays >= 1 && olderThanDays <= MAX_CLEANUP_DAYS
      ? olderThanDays
      : DEFAULT_CLEANUP_DAYS;
    const r = await getDb().query(
      `DELETE FROM push_tokens pt
        WHERE (pt.disabled_at IS NOT NULL
               AND pt.disabled_at < now() - ($1::int * interval '1 day'))
           OR (pt.last_seen_at < now() - ($2::int * interval '1 day')
               AND NOT EXISTS (
                 SELECT 1 FROM home_users hu
                  WHERE hu.user_id = pt.user_id
                    AND hu.role IN ('owner', 'resident')
               ))`,
      [days, ORPHAN_TOKEN_DAYS]
    );
    return r.rowCount || 0;
  }

  // --- gönderim -------------------------------------------------------------
  async function markTokensDisabled(targets) {
    const ids = targets.filter((t) => t.id).map((t) => t.id);
    const raw = targets.filter((t) => !t.id).map((t) => t.token);
    const db = getDb();
    if (ids.length > 0) {
      await db.query(
        'UPDATE push_tokens SET disabled_at = now() WHERE id = ANY($1::uuid[]) AND disabled_at IS NULL',
        [ids]
      );
    }
    if (raw.length > 0) {
      await db.query(
        'UPDATE push_tokens SET disabled_at = now() WHERE token = ANY($1::text[]) AND disabled_at IS NULL',
        [raw]
      );
    }
  }

  /**
   * @param {{ tokens:Array<string|{id?:string,token:string}>, title:string, body:string, data?:object }} p
   * @returns {Promise<{attempted:number, sent:number, failed:number, disabledTokenIds:string[],
   *   transient:boolean, errors:Array<{status?:number,code:string}>, retryAfterSec?:number}>}
   *   `transient`: hiçbir jeton kabul edilmediyse (sent === 0) ve en az bir hata yeniden denenebilirse true.
   *   Kısmi başarıda false: çağıran "sent" sayar ve yeniden denemez (çift bildirim olmasın).
   *   `deadlineMs`: TOPLAM süre sınırı (erişim jetonu alma + tüm istekler + yeniden denemeler dahil).
   *   Süre dolunca yeni jeton BAŞLATILMAZ (kalanlar DEADLINE_EXCEEDED, geçici) ve sürmekte olan
   *   istekler kalan süreyle sınırlanır: çağıran (evaluator) söz asla askıda kalmaz, kira süresi dolmadan
   *   ikinci bir örnek aynı alıcılara yeniden göndermez.
   */
  async function sendNotice({ tokens, title, body, data, deadlineMs, kind } = {}) {
    const msgKind = PUSH_KINDS.includes(kind) ? kind : 'peace';
    const result = { attempted: 0, sent: 0, failed: 0, disabledTokenIds: [], transient: false, errors: [] };

    if (!isConfigured()) {
      result.errors.push({ code: 'PUSH_NOT_CONFIGURED' });
      return result;
    }

    // Jeton listesini normalleştir + tekilleştir (aynı jetona iki bildirim gitmesin).
    const seen = new Set();
    const targets = [];
    for (const item of Array.isArray(tokens) ? tokens : []) {
      const token = typeof item === 'string' ? item : item && item.token;
      if (typeof token !== 'string' || token === '' || seen.has(token)) continue;
      seen.add(token);
      targets.push({ id: item && typeof item === 'object' && item.id ? item.id : null, token });
    }
    if (targets.length === 0) return result;

    if (typeof title !== 'string' || title === '' || typeof body !== 'string' || body === '') {
      result.errors.push({ code: 'VALIDATION' });
      return result;
    }

    const fetchFn = deps.fetchImpl || globalThis.fetch;
    if (typeof fetchFn !== 'function') {
      result.errors.push({ code: 'FETCH_UNAVAILABLE' });
      return result;
    }

    const url = `https://fcm.googleapis.com/v1/projects/${encodeURIComponent(nonEmpty(env.FCM_PROJECT_ID))}/messages:send`;
    const homePrefix = String((data && (data.home_id || data.homeId)) || '').slice(0, 8);
    const sentAtMs = nowMs();

    const budgetMs = Number.isFinite(deadlineMs) && deadlineMs > 0 ? deadlineMs : defaultDeadlineMs;
    const deadlineAt = monotonic() + budgetMs;
    const remainingMs = () => deadlineAt - monotonic();
    const stepTimeoutMs = () => Math.max(1, Math.min(timeoutMs, remainingMs()));

    // Erişim jetonu: tek-uçuş (single-flight). Yenileme de tek-uçuş: eşzamanlı 5 istek aynı anda
    // 401 alırsa kimlik bir kez yenilenir, her istek yeni jetonla bir kez yeniden denenir.
    // Jeton alma da zaman aşımlıdır (metadata/oauth2 çağrısı takılabilir); aşımda kimlik nesnesi atılır
    // ki takılmış istemci bir sonraki denemede yeniden kullanılmasın.
    const cred = { token: null, gen: 0, inflight: null };
    function acquire(forceNew) {
      if (cred.inflight) return cred.inflight;
      const gen = cred.gen;
      cred.inflight = (async () => {
        if (forceNew) authClient = null;
        let token;
        try {
          token = await withTimeout(fetchAccessToken(), stepTimeoutMs());
        } catch (err) {
          if (err && err.code === 'TIMEOUT') authClient = null;
          throw err;
        }
        if (cred.gen === gen) cred.gen += 1;
        cred.token = token;
        return token;
      })().finally(() => { cred.inflight = null; });
      return cred.inflight;
    }
    async function bearerFor() {
      if (cred.token) return { token: cred.token, gen: cred.gen };
      const token = await acquire(false);
      return { token, gen: cred.gen };
    }
    async function refreshFrom(failedGen) {
      if (cred.gen !== failedGen && cred.token) return { token: cred.token, gen: cred.gen }; // başkası yeniledi
      const token = await acquire(true);
      return { token, gen: cred.gen };
    }

    async function postOnce(target, bearer) {
      const ctrl = new AbortController();
      const timer = setTimeout(() => ctrl.abort(), stepTimeoutMs());
      const aborted = new Promise((_, reject) => {
        ctrl.signal.addEventListener('abort', () => reject(new Error('timeout')), { once: true });
      });
      aborted.catch(() => {}); // yarış kaybedilirse yakalanmamış ret olmasın
      try {
        const payload = JSON.stringify(buildMessage({ token: target.token, title, body, data, nowMs: sentAtMs, kind: msgKind }));
        const res = await Promise.race([
          fetchFn(url, {
            method: 'POST',
            headers: {
              Authorization: `Bearer ${bearer.token}`,
              'Content-Type': 'application/json; charset=UTF-8',
            },
            body: payload,
            signal: ctrl.signal,
          }),
          aborted,
        ]);
        const status = Number(res && res.status) || 0;
        let text = '';
        if (status >= 300) {
          try {
            text = await Promise.race([typeof res.text === 'function' ? res.text() : Promise.resolve(''), aborted]);
          } catch (_) {
            text = '';
          }
        }
        const parsed = status >= 300 ? parseFcmError(text) : { code: null, fcmCode: null, tokenRelated: false };
        const retryHeader = res.headers && typeof res.headers.get === 'function' ? res.headers.get('retry-after') : null;
        return {
          status,
          code: parsed.code,
          fcmCode: parsed.fcmCode,
          tokenRelated: parsed.tokenRelated,
          retryAfterSec: parseRetryAfter(retryHeader),
          bearerGen: bearer.gen,
        };
      } catch (_) {
        return { status: 0, code: ctrl.signal.aborted ? 'TIMEOUT' : 'NETWORK', tokenRelated: false, retryAfterSec: null };
      } finally {
        clearTimeout(timer);
      }
    }

    const authFailure = (err) => (err && err.code === 'TIMEOUT' ? 'AUTH_TIMEOUT' : 'AUTH_FAILED');

    async function sendOne(target) {
      try {
        // Süre doldu: yeni jeton başlatma (kalanlar geçici hata; kısmi başarıda çağıran yine "sent" sayar).
        if (remainingMs() < MIN_START_BUDGET_MS) {
          return { target, outcome: 'failed', status: 0, code: 'DEADLINE_EXCEEDED', transient: true, retryAfterSec: null };
        }
        let bearer;
        try {
          bearer = await bearerFor();
        } catch (err) {
          return { target, outcome: 'failed', status: 0, code: authFailure(err), transient: true, retryAfterSec: null };
        }
        let attempt = await postOnce(target, bearer);
        const authRejected = (attempt.status === 401 || attempt.status === 403)
          && !(attempt.code && PER_TOKEN_AUTH_CODES.has(attempt.code));
        if (authRejected) {
          if (remainingMs() < MIN_START_BUDGET_MS) {
            return { target, outcome: 'failed', status: attempt.status, code: 'DEADLINE_EXCEEDED', transient: true, retryAfterSec: null };
          }
          try {
            bearer = await refreshFrom(bearer.gen);
          } catch (err) {
            return { target, outcome: 'failed', status: attempt.status, code: authFailure(err), transient: true, retryAfterSec: null };
          }
          attempt = await postOnce(target, bearer); // tek yeniden deneme
        }
        return { target, ...classify(attempt), retryAfterSec: attempt.retryAfterSec };
      } catch (_) {
        return { target, outcome: 'failed', status: 0, code: 'UNEXPECTED', transient: true, retryAfterSec: null };
      }
    }

    result.attempted = targets.length;
    const outcomes = await runPool(targets, concurrency, sendOne);

    const invalid = [];
    const errorKeys = new Set();
    let transientFailures = 0;
    let config404 = 0;
    for (const o of outcomes) {
      if (o.outcome === 'sent') {
        result.sent += 1;
        continue;
      }
      result.failed += 1;
      if (o.outcome === 'invalid') {
        invalid.push(o.target);
        if (o.target.id) result.disabledTokenIds.push(o.target.id);
      }
      if (o.transient) transientFailures += 1;
      if (o.config404) config404 += 1;
      if (Number.isFinite(o.retryAfterSec) && (result.retryAfterSec === undefined || o.retryAfterSec > result.retryAfterSec)) {
        result.retryAfterSec = o.retryAfterSec;
      }
      const key = `${o.status}|${o.code}`;
      if (!errorKeys.has(key)) {
        errorKeys.add(key);
        result.errors.push({ status: o.status, code: o.code });
      }
    }
    result.transient = result.sent === 0 && transientFailures > 0;

    if (invalid.length > 0) {
      try {
        await markTokensDisabled(invalid);
      } catch (err) {
        log('error', `gecersiz jeton isaretleme hatasi (${invalid.length} adet): ${err && err.code ? err.code : 'DB'}`);
      }
    }

    if (config404 > 0) {
      // Tek satır (jeton başına değil); değişken DEĞERİ yazılmaz, yalnızca ad: operatör neye bakacağını bilir.
      log('error', `FCM 404 (jeton gecersizlik kaniti yok) adet=${config404}: FCM_PROJECT_ID / Firebase proje-API eslesmesi `
        + 'kontrol edilmeli; jetonlar devre disi BIRAKILMADI');
    }

    log('log', `gonderim home=${homePrefix || '-'} denenen=${result.attempted} gonderilen=${result.sent} `
      + `basarisiz=${result.failed} devre_disi=${invalid.length} gecici=${result.transient}`);
    return result;
  }

  return {
    isConfigured,
    upsertToken,
    disableToken,
    disableAllTokensForUser,
    recipientsForHome,
    sendNotice,
    cleanup,
  };
}

/**
 * Şartname §3.2 arayüzü createPushRouter'ı bu modülden de bekler; gerçek uygulama routes/push_routes.js'te.
 * Tembel require: route dosyası bu modülü yüklediği için döngüsel bağımlılık doğmaz.
 */
function createPushRouter(deps) {
  return require('../routes/push_routes').createPushRouter(deps);
}

module.exports = {
  createPushService,
  createPushRouter,
  MESSAGE_VERSION,
  PUSH_KINDS,
  RECIPIENT_ROLES,
  // Route ve testler için
  normalizeToken,
  normalizePlatform,
  normalizeAppVersion,
  buildMessage,
  defaultAuthFactory,
  FCM_SCOPE,
  TOKEN_MIN,
  TOKEN_MAX,
  APP_VERSION_MAX,
  PLATFORMS,
  MAX_ACTIVE_TOKENS_PER_USER,
  MAX_RECIPIENT_TOKENS_PER_USER,
  parseFcmError,
};
