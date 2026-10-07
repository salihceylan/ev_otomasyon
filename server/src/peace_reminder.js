'use strict';

// ==============================================================================
// AHBU Akıllı Ev - Gece huzur hatırlatması (değerlendirici)                [WP-H §3.4]
// ==============================================================================
//
// Kullanım (server.js, kendi try/catch'i içinde; scheduler.js ile aynı yaşam döngüsü):
//   const peace = require('./peace_reminder').start({ db, push });   // dakika sınırına hizalanır
//   await peace.stop();                                              // zarif kapanış
//
// Davranış: `homes.peace_notification_time` (HH:MM, boşsa 23:30) saatinde, `homes.timezone`
// yerel saatiyle, her yerel gece EN ÇOK BİR KEZ: evin CANLI cihazlarında açık lamba/panjur varsa
// TEK bildirim kaydı (peace_notification_logs) açar ve owner/resident kullanıcıların push
// token'larına TEK push yollar. Hiçbir şey açık değilse sessiz kalır (kayıt 'clear').
// Cihaz canlı değilse bayat veriyle ASLA bildirmez ('skipped_offline', pencere bitene kadar yeniden dener).
// Evde açık GAZ alarmı varsa "lambaları kapat" önerisi gönderilmez ('skipped_hazard', aynı yeniden deneme; Faz 2
// F2.A.4; status değeri migration 034'le eklendi).
// Yalnızca DB OKUR ve push yollar: MQTT komutu YAYINLAMAZ, `endpoints` tablosuna YAZMAZ.
//
// Tasarım
//   - Tek-gece-tek-bildirim: `UNIQUE (home_id, local_date)` + atomik `INSERT ... ON CONFLICT DO UPDATE
//     ... WHERE <yeniden denenebilir> RETURNING`. Birden çok süreç/instance, yeniden başlatma ve
//     üst üste binen turlar yalnızca DB talebine güvenir; kazanan tektir.
//   - Telafi penceresi: "şimdiki yerel dakika == hedef dakika" eşitliği DEĞİL, `delta <= PEACE_CATCHUP_MIN`.
//     Böylece 23:31-00:30 arası yeniden başlatma ve DST boşluğu (var olmayan 02:30) gece yine bir kez ateşler.
//     `local_date` = hedefin ait olduğu yerel takvim günü (23:50 hedefi 00:20'de görülürse ÖNCEKİ gün).
//   - Gönderimden hemen önce ikinci canlı anlık görüntü: kullanıcı bu arada kapattıysa 'clear'.
//   - Yeniden deneme pencereye yayılır: skipped_offline/failed satırları seyrekleşen aralıkla (1, 2, 5 dk)
//     pencere bitene kadar denenir; deneme sınırı pencereyi kesmeyecek kadar geniştir (maxAttemptsFor).
//   - Evin yalnız bir kısmı canlıysa ve canlı cihazlarda açık bir şey yoksa 'clear' YAZILMAZ (çevrimdışı
//     kartın durumu bilinmiyor): skipped_offline + yeniden deneme.
//   - En çok bir push: push başlamadan satır 'sending' olur (yeniden talep edilemez); push gittikten sonra
//     kayıt yazımı hata verse bile 'failed'a düşülmez. Bunun bedeli: gönderim sırasında süreç çökerse o gece
//     bildirim tekrarlanmaz (çift bildirimden az kötü).
//   - Şema eksikse (migration henüz uygulanmadı) hatırlatma kalıcı kapanmaz; 5 dk'da bir yeniden denetlenir.
//   - Bir turda en çok 500 ev (ev başına 15 sn zaman aşımı, eşzamanlılık 10); işlenmiş evler aday
//     sorgusundan elenir, böylece geri kalanlar sonraki turda devam eder (23:30 yığılması).
//
// Bağımlılıklar ENJEKTE edilir (test: sahte db/push/zamanlayıcı; ağ ve gerçek zaman yok):
//   db   { query(text, params) }
//   push { recipientsForHome(homeId), sendNotice({tokens,title,body,data}), cleanup({olderThanDays}), isConfigured?() }
//   text { buildTitle(homeName), buildSummary({lights,shutters}) }   (varsayılan: ./services/peace_text)

const { loadLiveSnapshot } = require('./services/peace_snapshot');

const DEFAULT_TZ = 'Europe/Istanbul';
const DEFAULT_TIME = '23:30';
const DEFAULT_CATCHUP_MIN = 60;
const MAX_CATCHUP_MIN = 720; // aday saat listesi 1440 dakikayı aşmasın
const TICK_OFFSET_MS = 20 * 1000; // dakika başından sonra 20 sn: aynı dakikadaki zamanlı kurallar önce iner
const HOME_TIMEOUT_MS = 15 * 1000;
const CONCURRENCY = 10;
const MAX_HOMES_PER_TICK = 500;
// Yeniden deneme aralığı (skipped_offline/failed): deneme sayısı arttıkça seyrekleşir. Kısa kesintiler
// (Wi-Fi/router titremesi) hızla, uzun kesintiler ucuza (dakikada bir yazma yerine 5 dk'da bir) kapanır.
// ÖNEMLİ: deneme sınırı pencereden BAĞIMSIZ değildir ama onu KESMEZ: `maxAttemptsFor(catchupMin)`
// pencerenin sonuna kadar yetecek kadar deneme + marj verir; sınır yalnızca kaçak döngüye karşı sigortadır.
// `upToAttempts` = satırdaki (şimdiye dek yapılan) deneme sayısı; `gapSec` = bir sonraki denemeye kadar.
const RETRY_STEPS = Object.freeze([
  Object.freeze({ upToAttempts: 2, gapSec: 60 }),
  Object.freeze({ upToAttempts: 4, gapSec: 120 }),
  Object.freeze({ upToAttempts: Infinity, gapSec: 300 }),
]);
const RETRY_TOLERANCE_SEC = 10; // tur 20 sn ofsetli ama ms kayar: "tam 60 sn" koşulu bir turu kaçırmasın
const RETRY_ATTEMPT_MARGIN = 6; // kira devri (çöken sahiplenici) da deneme sayar
const CLAIM_LEASE_MIN = 2; // 'claimed' ve bu kadar süredir güncellenmeyen satır çöken sahiplenicidir
const FINISH_WRITE_TRIES = 3; // push gittikten sonra kayıt yazımı geçici hatada bu kadar denenir
const SCHEMA_RECHECK_MS = 5 * 60 * 1000; // eksik şema (rolling deploy) bu aralıkla yeniden denetlenir
const MAINTENANCE_EVERY_MS = 24 * 60 * 60 * 1000;
const LOG_RETENTION_DAYS = 90;
const TOKEN_RETENTION_DAYS = 30;
const WARN_INTERVAL_MS = 10 * 60 * 1000;
const STOP_WAIT_MS = 5000;
const MAX_REPORTED_ERRORS = 20;
const DRY_RUN_MEMORY = 2000;

const TIME_RE = /^([01][0-9]|2[0-3]):[0-5][0-9]$/;
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

// Açılış öz-denetiminin gerektirdiği şema (migration 022 + 025 + 030)
const REQUIRED_SCHEMA = Object.freeze({
  homes: ['timezone', 'peace_notification_enabled', 'peace_notification_time'],
  peace_notification_logs: ['local_date', 'scheduled_for', 'status', 'attempts', 'details', 'push_sent_count', 'evaluated_at', 'updated_at'],
  push_tokens: ['id', 'user_id', 'token', 'disabled_at'],
});

// ------------------------------------------------------------------------------
// Saf zaman yardımcıları
// ------------------------------------------------------------------------------

/** scheduler.js yardımcıları yoksa/imzası değiştiyse kullanılan küçük Intl tabanlı eşdeğer. */
function createFallbackTimeHelpers() {
  const cache = new Map();
  const formatter = (tz) => {
    let f = cache.get(tz);
    if (!f) {
      f = new Intl.DateTimeFormat('en-US', {
        timeZone: tz,
        hourCycle: 'h23',
        year: 'numeric',
        month: '2-digit',
        day: '2-digit',
        hour: '2-digit',
        minute: '2-digit',
      });
      cache.set(tz, f);
    }
    return f;
  };
  const isValid = (tz) => {
    if (typeof tz !== 'string' || tz.length === 0 || tz.length > 64) return false;
    try {
      formatter(tz);
      return true;
    } catch (_) {
      return false;
    }
  };
  return {
    resolveTimeZone: (tz) => (isValid(tz) ? tz : DEFAULT_TZ),
    localParts(ms, tz) {
      const o = {};
      for (const p of formatter(tz).formatToParts(new Date(ms))) if (p.type !== 'literal') o[p.type] = p.value;
      let hour = parseInt(o.hour, 10);
      if (hour === 24) hour = 0; // bazı ICU sürümleri gece yarısını 24 verir
      return {
        year: parseInt(o.year, 10),
        month: parseInt(o.month, 10),
        day: parseInt(o.day, 10),
        hour,
        minute: parseInt(o.minute, 10),
        dateKey: `${o.year}-${o.month}-${o.day}`,
      };
    },
    floorMinute: (ms) => Math.floor(ms / 60000) * 60000,
  };
}

/**
 * scheduler.js `helpers`'ını (localParts, floorMinute, resolveTimeZone) kullanır; yoksa ya da
 * beklenen biçimde çalışmıyorsa kendi yardımcımıza düşer (scheduler'ın başkasınca değişmesi
 * gece hatırlatmasını sessizce bozmasın).
 */
function loadTimeHelpers() {
  const fallback = createFallbackTimeHelpers();
  try {
    const h = require('./scheduler').helpers;
    if (h && typeof h.localParts === 'function' && typeof h.floorMinute === 'function' && typeof h.resolveTimeZone === 'function') {
      const probe = h.localParts(Date.UTC(2026, 0, 15, 12, 5), 'UTC');
      if (probe && probe.hour === 12 && probe.minute === 5 && probe.dateKey === '2026-01-15' && h.floorMinute(90001) === 60000) {
        return h;
      }
    }
  } catch (_) {
    // yüklenemedi: fallback
  }
  return fallback;
}

/** Satırdaki deneme sayısına göre bir sonraki denemeye kadar BEKLEME (sn). */
function retryGapSec(attempts) {
  const n = Number.isFinite(attempts) ? attempts : 1;
  for (const step of RETRY_STEPS) if (n <= step.upToAttempts) return step.gapSec;
  return RETRY_STEPS[RETRY_STEPS.length - 1].gapSec;
}

/** Aynı bekleme, SQL'de uygulanan (toleranslı) biçimde: updated_at bu kadar eskiyse yeniden denenebilir. */
function retryDueSec(attempts) {
  return retryGapSec(attempts) - RETRY_TOLERANCE_SEC;
}

/** `col` deneme sütunu için CASE ifadesi (saniye); sabitlerden üretilir, kullanıcı girdisi içermez. */
function retryDueSql(col) {
  const parts = [];
  for (const step of RETRY_STEPS) {
    const due = step.gapSec - RETRY_TOLERANCE_SEC;
    parts.push(Number.isFinite(step.upToAttempts) ? `WHEN ${col} <= ${step.upToAttempts} THEN ${due}` : `ELSE ${due}`);
  }
  return `(CASE ${parts.join(' ')} END)`;
}

/**
 * Telafi penceresi boyunca yapılabilecek en çok deneme + marj. Pencereyi KESMEYECEK kadar geniştir
 * (eski sabit 6 deneme, dakikada bir denendiği için pencerenin ilk 6 dakikasında tükeniyordu).
 */
function maxAttemptsFor(catchupMin) {
  let t = 0;
  let n = 1; // 1. deneme hedef anında
  for (;;) {
    t += retryGapSec(n) / 60;
    if (t > catchupMin) break;
    n += 1;
  }
  return n + RETRY_ATTEMPT_MARGIN;
}

/** "23:30" -> 1410; geçersizse null. */
function parseHHMM(value) {
  if (typeof value !== 'string' || !TIME_RE.test(value)) return null;
  return parseInt(value.slice(0, 2), 10) * 60 + parseInt(value.slice(3, 5), 10);
}

function formatHHMM(minutes) {
  const m = ((minutes % 1440) + 1440) % 1440;
  return `${String(Math.floor(m / 60)).padStart(2, '0')}:${String(m % 60).padStart(2, '0')}`;
}

/** "2026-10-01" -> "2026-09-30" (takvim aritmetiği; DST'den bağımsız). */
function previousDateKey(dateKey) {
  const [y, m, d] = dateKey.split('-').map(Number);
  return new Date(Date.UTC(y, m - 1, d - 1)).toISOString().slice(0, 10);
}

/**
 * Bir saat diliminde "şimdi" için aday hedef saatleri: son (catchupMin + 1) DUVAR SAATİ dakikası.
 * Duvar saati kullanılır (gerçek geçen süre değil): DST boşluğunda var olmayan 02:30 hedefi de
 * 03:00 turunda aday olur. Tekrar eden saatte (sonbahar) aynı dize iki kez üretilmez.
 */
function candidateTargets(nowMs, tz, catchupMin, helpers) {
  const t0 = helpers.floorMinute(nowMs);
  const p = helpers.localParts(t0, tz);
  const nowMin = p.hour * 60 + p.minute;
  const targets = [];
  for (let k = 0; k <= catchupMin; k++) targets.push(formatHHMM(nowMin - k));
  return { targets, nowHHMM: formatHHMM(nowMin), today: p.dateKey, previous: previousDateKey(p.dateKey) };
}

/**
 * Bir evin hedef saati için pencere hesabı. `delta` = hedeften bu yana geçen duvar saati dakikası.
 * @returns {{delta:number, dateKey:string, scheduledForMs:number}|null}  null = pencere dışı
 */
function computeWindow(nowMs, tz, timeStr, catchupMin, helpers) {
  const t0 = helpers.floorMinute(nowMs);
  const p = helpers.localParts(t0, tz);
  const nowMin = p.hour * 60 + p.minute;
  const target = parseHHMM(timeStr) !== null ? parseHHMM(timeStr) : parseHHMM(DEFAULT_TIME);
  const delta = (nowMin - target + 1440) % 1440;
  if (delta > catchupMin) return null;
  // Hedef bugünün saatinden SONRAYSA (gece yarısı aşımı) bildirim önceki yerel geceye aittir.
  const dateKey = target > nowMin ? previousDateKey(p.dateKey) : p.dateKey;
  return { delta, dateKey, scheduledForMs: t0 - delta * 60000 };
}

// ------------------------------------------------------------------------------
// Ortam ayarları
// ------------------------------------------------------------------------------

const BOOL_UNSET = 'unset';
const BOOL_UNKNOWN = 'unknown';

/** @returns {boolean|'unset'|'unknown'} boş = 'unset'; tanınmayan yazım = 'unknown' (çağıran güvenli tarafı seçer). */
function parseBool(raw) {
  if (raw === undefined || raw === null || String(raw).trim() === '') return BOOL_UNSET;
  const v = String(raw).trim().toLowerCase();
  if (['true', '1', 'yes', 'on'].includes(v)) return true;
  if (['false', '0', 'no', 'off'].includes(v)) return false;
  return BOOL_UNKNOWN;
}

/**
 * @returns {{enabled:boolean, dryRun:boolean, allowlist:string[]|null, catchupMin:number, maxAttempts:number, warnings:string[]}}
 *   allowlist: null = kısıtlama yok; dizi (boş olabilir) = yalnızca bu evler.
 *
 * Güvenlik anahtarları "güvenli tarafa" düşer (yazım hatası sessizce gerçek gönderime yol açmasın):
 *   DRY_RUN tanınmayan değer -> AÇIK (hiç push gitmez); ENABLED tanınmayan değer -> KAPALI. İkisi de uyarır.
 */
function parseConfig(env = {}) {
  const warnings = [];
  const rawEnabled = parseBool(env.PEACE_REMINDER_ENABLED);
  let enabled = true;
  if (rawEnabled === BOOL_UNKNOWN) {
    enabled = false;
    warnings.push('PEACE_REMINDER_ENABLED taninmayan deger, hatirlatma KAPALI sayildi (true/false kullanin)');
  } else if (rawEnabled !== BOOL_UNSET) {
    enabled = rawEnabled;
  }
  const rawDry = parseBool(env.PEACE_REMINDER_DRY_RUN);
  let dryRun = false;
  if (rawDry === BOOL_UNKNOWN) {
    dryRun = true;
    warnings.push('PEACE_REMINDER_DRY_RUN taninmayan deger, DRY_RUN ACIK sayildi (push gonderilmez; true/false kullanin)');
  } else if (rawDry !== BOOL_UNSET) {
    dryRun = rawDry;
  }

  let allowlist = null;
  const rawList = env.PEACE_REMINDER_HOME_ALLOWLIST;
  if (typeof rawList === 'string' && rawList.trim() !== '') {
    const parts = rawList.split(',').map((s) => s.trim().toLowerCase()).filter(Boolean);
    allowlist = parts.filter((s) => UUID_RE.test(s));
    if (allowlist.length !== parts.length) warnings.push('PEACE_REMINDER_HOME_ALLOWLIST: gecersiz kimlikler yok sayildi');
    // Dolu ama tamamı geçersiz liste "kimse" demektir (yanlışlıkla herkese göndermekten güvenlidir).
  }

  let catchupMin = DEFAULT_CATCHUP_MIN;
  const rawCatch = env.PEACE_CATCHUP_MIN;
  if (rawCatch !== undefined && rawCatch !== null && String(rawCatch).trim() !== '') {
    const n = Number(String(rawCatch).trim());
    if (Number.isInteger(n) && n >= 1 && n <= MAX_CATCHUP_MIN) catchupMin = n;
    else warnings.push(`PEACE_CATCHUP_MIN gecersiz, ${DEFAULT_CATCHUP_MIN} kullaniliyor`);
  }
  return { enabled, dryRun, allowlist, catchupMin, maxAttempts: maxAttemptsFor(catchupMin), warnings };
}

// ------------------------------------------------------------------------------
// SQL
// ------------------------------------------------------------------------------
const TIME_RE_SQL = "'^([01][0-9]|2[0-3]):[0-5][0-9]$'";
const RAW_TIME_SQL = `COALESCE(h.peace_notification_time, '${DEFAULT_TIME}')`;
// NULL (ayarlanmamış) ve biçimi bozuk değer 23:30 sayılır; HH:MM CHECK'i (025) yeni bozuk veriyi zaten engeller.
const EFFECTIVE_TIME_SQL = `(CASE WHEN ${RAW_TIME_SQL} ~ ${TIME_RE_SQL} THEN ${RAW_TIME_SQL} ELSE '${DEFAULT_TIME}' END)`;
const ENABLED_SQL = 'COALESCE(h.peace_notification_enabled, TRUE) = TRUE';
const HAS_DEVICE_SQL = 'EXISTS (SELECT 1 FROM devices d WHERE d.home_id = h.id)';

const SQL = Object.freeze({
  selfCheck:
    'SELECT table_name, column_name FROM information_schema.columns ' +
    'WHERE table_schema = current_schema() AND table_name = ANY($1::text[])',
  // $1 = izinli ev listesi (NULL = kısıt yok)
  zones:
    `SELECT DISTINCT COALESCE(h.timezone, '${DEFAULT_TZ}') AS tz FROM homes h ` +
    `WHERE ${ENABLED_SQL} AND ${HAS_DEVICE_SQL} AND ($1::uuid[] IS NULL OR h.id = ANY($1::uuid[]))`,
  // $1 ham saat dilimi, $2 aday saatler, $3 üst sınır, $4 şimdiki HH:MM, $5 bugün, $6 dün,
  // $7 en çok deneme, $8 izinli ev listesi.
  // Elenen evler: nihai kaydı olanlar ('sending' dahil), deneme hakkı bitenler ve yeniden deneme aralığı
  // HENÜZ dolmayanlar (skipped_offline/failed: aksi halde çevrimdışı evler her dakika talep edilip
  // deneme hakkını dakikalar içinde tüketirdi). Elenmezse ilk 500 ev her turda yeniden talep edilip
  // kaybedilir ve sıradakiler hiç işlenmezdi. SIRALAMA: hiç denenmemiş evler (kayıt yok, deneme 0) önce,
  // sonra az denenenler; kalıcı çevrimdışı evler yeni evlerin 500'lük dilimini işgal edemez.
  // Hedef şimdiki saatten SONRAYSA kayıt DÜNÜN tarihindedir (gece yarısı aşımı). UNIQUE (home_id, local_date)
  // yüzünden LEFT JOIN ev başına en çok bir satır verir.
  candidates:
    `SELECT h.id, h.name, COALESCE(h.timezone, '${DEFAULT_TZ}') AS timezone, ` +
    `h.peace_notification_time AS raw_time, ${EFFECTIVE_TIME_SQL} AS peace_time ` +
    'FROM homes h ' +
    'LEFT JOIN peace_notification_logs l ON l.home_id = h.id ' +
    `AND l.local_date = (CASE WHEN ${EFFECTIVE_TIME_SQL} > $4 THEN $6::date ELSE $5::date END) ` +
    `WHERE ${ENABLED_SQL} ` +
    `AND COALESCE(h.timezone, '${DEFAULT_TZ}') = $1 ` +
    `AND ${EFFECTIVE_TIME_SQL} = ANY($2::text[]) ` +
    `AND ${HAS_DEVICE_SQL} ` +
    'AND ($8::uuid[] IS NULL OR h.id = ANY($8::uuid[])) ' +
    "AND (l.id IS NULL OR (l.attempts < $7 AND (l.status = 'claimed' " +
    "OR (l.status IN ('skipped_offline', 'skipped_hazard', 'failed') " +
    `AND l.updated_at <= CURRENT_TIMESTAMP - ${retryDueSql('l.attempts')} * INTERVAL '1 second')))) ` +
    'ORDER BY COALESCE(l.attempts, 0), h.id LIMIT $3',
  // Atomik talep: tek kazanan. Yeniden talep edilebilenler: bekleyen (skipped_offline/failed; deneme hakkı varsa
  // VE yeniden deneme aralığı dolduysa) ve çöken sahiplenici (claimed + kira süresi dolmuş). 'sending' (push
  // başladı) ASLA yeniden talep edilmez: gönderim sonucu bilinmiyorsa ikinci push atmaktansa susulur.
  // Satır dönmezse başkası sahip ya da nihai.
  claim:
    'INSERT INTO peace_notification_logs (home_id, local_date, scheduled_for, status, attempts, triggered_at, updated_at) ' +
    "VALUES ($1, $2::date, $3::timestamptz, 'claimed', 1, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP) " +
    'ON CONFLICT (home_id, local_date) DO UPDATE ' +
    "SET status = 'claimed', attempts = peace_notification_logs.attempts + 1, updated_at = CURRENT_TIMESTAMP " +
    'WHERE peace_notification_logs.attempts < $4 ' +
    "AND ((peace_notification_logs.status IN ('skipped_offline', 'skipped_hazard', 'failed') " +
    `AND peace_notification_logs.updated_at <= CURRENT_TIMESTAMP - ${retryDueSql('peace_notification_logs.attempts')} * INTERVAL '1 second') ` +
    "OR (peace_notification_logs.status = 'claimed' " +
    `AND peace_notification_logs.updated_at < CURRENT_TIMESTAMP - INTERVAL '${CLAIM_LEASE_MIN} minutes')) ` +
    'RETURNING id, attempts',
  // Push gönderiminden HEMEN ÖNCE: 'claimed' -> 'sending'. Tek kazananlı; kira devredildiyse (rowCount 0) gönderilmez.
  markSending:
    "UPDATE peace_notification_logs SET status = 'sending', updated_at = CURRENT_TIMESTAMP " +
    "WHERE id = $1 AND status = 'claimed' AND attempts = $2",
  // Yalnızca kendi talebimizin satırı güncellenir (kira devralındıysa attempts değişmiştir).
  finish:
    'UPDATE peace_notification_logs SET status = $2, open_lights_count = $3, open_shutters_count = $4, ' +
    'summary_text = $5, details = $6::jsonb, push_sent_count = $7, evaluated_at = CURRENT_TIMESTAMP, ' +
    'updated_at = CURRENT_TIMESTAMP ' +
    "WHERE id = $1 AND status IN ('claimed', 'sending') AND attempts = $8",
  purgeLogs: "DELETE FROM peace_notification_logs WHERE triggered_at < CURRENT_TIMESTAMP - ($1::int * INTERVAL '1 day')",
});

// ------------------------------------------------------------------------------
// Küçük yardımcılar
// ------------------------------------------------------------------------------

function safeMessage(err) {
  const m = err && err.message ? String(err.message) : 'bilinmeyen hata';
  return m.replace(/\s+/g, ' ').slice(0, 180);
}

/** Push hatalarında MESAJ loglanmaz (üçüncü taraf mesajı token içerebilir); yalnızca kod/ad. */
function pushErrorLabel(err) {
  return String((err && (err.code || err.name)) || 'PUSH_ERROR').slice(0, 40);
}

function shortId(id) {
  return String(id).slice(0, 8);
}

function toCount(value) {
  const n = typeof value === 'number' ? value : parseInt(value, 10);
  return Number.isFinite(n) && n > 0 ? Math.trunc(n) : 0;
}

class TimeoutError extends Error {
  constructor(label) {
    super(`${label} zaman asimina ugradi`);
    this.name = 'TimeoutError';
  }
}

/** Kayıt `details` JSON'u: kişisel veri/token içermez. */
function buildDetails(snapshot, extra = {}) {
  const lights = (snapshot && snapshot.lights) || [];
  const shutters = (snapshot && snapshot.shutters) || [];
  const out = {
    lights: lights.map((l) => ({ endpoint_id: l.endpointId, channel: l.channel, room: l.room })),
    shutters: shutters.map((s) => ({ pair: s.pair, room: s.room, pos: s.position })),
  };
  // Evin bir kısmı ulaşılamazken verilen karar eksik bilgiyle verilmiştir: kayıt bunu belirtir.
  if (isPartiallyOffline(snapshot)) {
    out.devices_live = snapshot.devicesLive;
    out.devices_total = snapshot.devicesTotal;
  }
  return { ...out, ...extra };
}

/** Evde en az bir canlı cihaz var ama bazıları ulaşılamıyor mu? (çevrimdışı cihazın durumu "bilinmiyor"dur, "kapalı" değil) */
function isPartiallyOffline(snapshot) {
  return Boolean(snapshot) && Number.isFinite(snapshot.devicesTotal) && Number.isFinite(snapshot.devicesLive) &&
    snapshot.devicesLive > 0 && snapshot.devicesLive < snapshot.devicesTotal;
}

/**
 * push.sendNotice sonucu -> kayıt durumu.
 *
 * Kısmi başarı (sent > 0) NİHAİDİR: push_service gönderim sonucunu alıcı bazında dönmez ve bir kez
 * gönderilmiş alıcıya yeniden göndermek çift bildirim demektir. Teslim edilemeyen ama kalıcı geçersiz
 * OLMAYAN alıcı sayısı `push.failed_other` olarak kayda geçer (gözlemlenebilirlik; sıfırsa alan yazılmaz).
 */
function classifyPushResult(res) {
  const r = res && typeof res === 'object' ? res : {};
  const sent = toCount(r.sent);
  const failed = toCount(r.failed);
  const disabled = Array.isArray(r.disabledTokenIds) ? r.disabledTokenIds.length : 0;
  const push = { attempted: toCount(r.attempted), sent, failed };
  if (sent > 0) {
    const other = Math.max(0, failed - disabled);
    if (other > 0) push.failed_other = other;
    return { status: 'sent', push };
  }
  const errors = Array.isArray(r.errors) ? r.errors : [];
  if (errors.some((e) => e && e.code === 'PUSH_NOT_CONFIGURED')) return { status: 'no_recipients', reason: 'push_not_configured', push };
  if (r.transient) return { status: 'failed', reason: 'push_transient', push };
  // Hiçbiri teslim edilmedi ve yeniden denenecek değil: token'lar bayat mıydı (kalıcı geçersiz -> push_rejected)
  // yoksa mesajın kendisi mi reddedildi (400/403 vb. -> push_error)? Operatör ikisini ayırt edebilsin.
  if (push.attempted > 0) return { status: 'no_recipients', reason: disabled > 0 ? 'push_rejected' : 'push_error', push };
  return { status: 'no_recipients', reason: 'no_tokens', push };
}

function emptySummary() {
  return {
    zones: 0,
    candidates: 0,
    claimed: 0,
    clear: 0,
    sent: 0,
    noRecipients: 0,
    skippedOffline: 0,
    skippedHazard: 0,
    failed: 0,
    lost: 0,
    dryRun: 0,
    errors: [],
  };
}

// ------------------------------------------------------------------------------
// Motor
// ------------------------------------------------------------------------------
class PeaceReminder {
  /**
   * @param {object} opts { db, push, text?, logger?, now?, setTimer?, clearTimer?, env?, timeHelpers? }
   */
  constructor(opts = {}) {
    if (!opts.db || typeof opts.db.query !== 'function') throw new TypeError('peace_reminder: db (query) zorunludur');
    if (!opts.push || typeof opts.push.recipientsForHome !== 'function' || typeof opts.push.sendNotice !== 'function') {
      throw new TypeError('peace_reminder: push (recipientsForHome, sendNotice) zorunludur');
    }
    this.db = opts.db;
    this.push = opts.push;
    this.text = opts.text || null; // tembel: ./services/peace_text
    this.logger = opts.logger || console;
    this.now = opts.now || Date.now;
    this.setTimer = opts.setTimer || ((fn, ms) => setTimeout(fn, ms));
    this.clearTimer = opts.clearTimer || ((handle) => clearTimeout(handle));
    this.time = opts.timeHelpers || loadTimeHelpers();
    this.config = parseConfig(opts.env || process.env);

    this._started = false;
    this._disabled = false; // yalnızca kill switch (PEACE_REMINDER_ENABLED)
    this._schemaOk = false;
    this._schemaCheckedAt = null; // son BAŞARILI denetimin zamanı (eksik şema ise yeniden denetim aralığı için)
    this._schemaReported = false;
    this._checking = null;
    this._timer = null;
    this._running = null;
    this._lastMaintenance = null;
    this._warned = new Map();
    this._dryLogged = new Set();
  }

  /** Zamanlayıcıyı başlatır ve şema öz-denetimini arka planda yapar. Asla fırlatmaz (yapılandırma dışında). */
  start() {
    if (this._started || this._disabled) return this;
    for (const w of this.config.warnings) this.logger.warn(`[PEACE] ${w}`);
    if (!this.config.enabled) {
      this._disabled = true;
      this.logger.log('[PEACE] Gece huzur hatirlatmasi PEACE_REMINDER_ENABLED=false ile devre disi');
      return this;
    }
    this._started = true;
    this.ready().catch(() => {});
    this._scheduleNext();
    this.logger.log(
      `[PEACE] Gece huzur hatirlatmasi baslatildi (telafi ${this.config.catchupMin} dk${this.config.dryRun ? ', DRY_RUN' : ''}` +
        `${this.config.allowlist ? `, izinli ev ${this.config.allowlist.length}` : ''})`
    );
    return this;
  }

  /** Zarif durdurma: yeni tur planlanmaz, çalışan tur (en fazla 5 sn) beklenir. */
  async stop() {
    this._started = false;
    this._clearTimer();
    const running = this._running;
    if (running) {
      let t;
      const limit = new Promise((resolve) => {
        t = this.setTimer(resolve, STOP_WAIT_MS);
        if (t && typeof t.unref === 'function') t.unref();
      });
      try {
        await Promise.race([running.catch(() => {}), limit]);
      } finally {
        this.clearTimer(t);
      }
    }
  }

  isRunning() {
    return this._started;
  }

  /**
   * Şema öz-denetimi tamamlanana kadar bekler; true = çalışmaya hazır.
   * Eksik şema KALICI devre dışı bırakmaz (rolling deploy: kod migration'dan önce başlayabilir): zamanlayıcı
   * çalışmaya devam eder ve denetim SCHEMA_RECHECK_MS aralığıyla yinelenir; şema tamamlanınca hatırlatma
   * yeniden başlatmaya gerek kalmadan etkinleşir.
   */
  async ready(nowMs) {
    if (this._disabled) return false;
    if (this._schemaOk) return true;
    const t = nowMs === undefined ? this.now() : nowMs;
    if (this._schemaCheckedAt !== null && t - this._schemaCheckedAt < SCHEMA_RECHECK_MS) return false;
    if (!this._checking) {
      this._checking = this._selfCheck(t).finally(() => {
        this._checking = null;
      });
    }
    await this._checking;
    return this._schemaOk;
  }

  _clearTimer() {
    if (this._timer) {
      this.clearTimer(this._timer);
      this._timer = null;
    }
  }

  _scheduleNext() {
    if (!this._started) return;
    const delay = 60000 - (this.now() % 60000) + TICK_OFFSET_MS;
    this._timer = this.setTimer(() => this._onTimer(), delay);
    if (this._timer && typeof this._timer.unref === 'function') this._timer.unref();
  }

  async _onTimer() {
    this._timer = null;
    if (!this._started) return;
    const p = this.runTick(this.now()).catch((err) => {
      this._warnOnce('tick', `Tur hatasi: ${safeMessage(err)}`);
    });
    this._running = p;
    await p;
    this._running = null;
    this._scheduleNext();
  }

  _warnOnce(key, message, level = 'warn') {
    const t = this.now();
    const last = this._warned.get(key);
    if (last !== undefined && t - last < WARN_INTERVAL_MS) return;
    this._warned.set(key, t);
    this.logger[level](`[PEACE] ${message}`);
  }

  /** information_schema ile gerekli tablo/kolonlar var mı; yoksa (azaltılmış sıklıkta) error logu, hatırlatma BEKLEMEDE. */
  async _selfCheck(nowMs) {
    let rows;
    try {
      const res = await this.db.query(SQL.selfCheck, [Object.keys(REQUIRED_SCHEMA)]);
      rows = (res && res.rows) || [];
    } catch (err) {
      // Veritabanı geçici olarak yoksa denetim "yapıldı" sayılmaz: sonraki turda hemen yeniden denenir.
      this._warnOnce('selfcheck', `Sema oz-denetimi yapilamadi: ${safeMessage(err)}`);
      return;
    }
    const present = new Set(rows.map((r) => `${r.table_name}.${r.column_name}`));
    const missing = [];
    for (const [table, columns] of Object.entries(REQUIRED_SCHEMA)) {
      for (const column of columns) if (!present.has(`${table}.${column}`)) missing.push(`${table}.${column}`);
    }
    this._schemaCheckedAt = nowMs;
    if (missing.length > 0) {
      this._schemaOk = false;
      this._schemaReported = true;
      this._warnOnce(
        'schema',
        `Gerekli sema eksik, gece huzur hatirlatmasi BEKLEMEDE (migration 022/025/030 uygulanmali; ${Math.round(SCHEMA_RECHECK_MS / 60000)} dk'da bir yeniden denetlenir): ${missing.slice(0, 12).join(', ')}`,
        'error'
      );
      return;
    }
    this._schemaOk = true;
    if (this._schemaReported) this.logger.log('[PEACE] Sema tamamlandi, gece huzur hatirlatmasi etkinlesti');
  }

  /**
   * Tek bir dakika turu. Test ve elle tetikleme için dışa açıktır.
   * @param {number} [nowMs]
   */
  async runTick(nowMs = this.now()) {
    const summary = emptySummary();
    if (this._disabled) return summary;
    try {
      if (!(await this.ready(nowMs))) return summary;
      await this._maybeMaintenance(nowMs);

      const allow = this.config.allowlist;
      const zonesRes = await this.db.query(SQL.zones, [allow]);
      const rawZones = [...new Set(((zonesRes && zonesRes.rows) || []).map((r) => r.tz).filter(Boolean))];
      summary.zones = rawZones.length;

      const work = [];
      for (const rawTz of rawZones) {
        const remaining = MAX_HOMES_PER_TICK - work.length;
        if (remaining <= 0) break;
        const tz = this.time.resolveTimeZone(rawTz);
        if (tz !== rawTz) this._warnOnce(`tz:${rawTz}`, `Gecersiz saat dilimi "${String(rawTz).slice(0, 64)}", ${tz} kullaniliyor`);
        const win = candidateTargets(nowMs, tz, this.config.catchupMin, this.time);
        const res = await this.db.query(SQL.candidates, [
          rawTz,
          win.targets,
          remaining,
          win.nowHHMM,
          win.today,
          win.previous,
          this.config.maxAttempts,
          allow,
        ]);
        for (const home of (res && res.rows) || []) work.push({ home, tz });
      }
      summary.candidates = work.length;
      if (work.length === 0) return summary;

      for (let i = 0; i < work.length; i += CONCURRENCY) {
        const chunk = work.slice(i, i + CONCURRENCY);
        const settled = await Promise.allSettled(
          chunk.map(({ home, tz }) => this._withTimeout(this._processHome(home, tz, nowMs), HOME_TIMEOUT_MS, `Ev ${shortId(home.id)}`))
        );
        settled.forEach((r, idx) => {
          const home = chunk[idx].home;
          if (r.status === 'fulfilled') {
            this._count(summary, r.value);
          } else {
            summary.failed++;
            if (summary.errors.length < MAX_REPORTED_ERRORS) summary.errors.push({ home: shortId(home.id), message: safeMessage(r.reason) });
            this.logger.error(`[PEACE] Ev ${shortId(home.id)} hatasi: ${safeMessage(r.reason)}`);
          }
        });
      }
      if (summary.claimed + summary.failed + summary.dryRun > 0) {
        this.logger.log(
          `[PEACE] Tur: aday ${summary.candidates}, talep ${summary.claimed}, gonderilen ${summary.sent}, temiz ${summary.clear}, ` +
            `alici yok ${summary.noRecipients}, cevrimdisi ${summary.skippedOffline}, gaz alarmi ${summary.skippedHazard}, hata ${summary.failed}`
        );
      }
    } catch (err) {
      this._warnOnce('tick', `Tur hatasi: ${safeMessage(err)}`);
      if (summary.errors.length < MAX_REPORTED_ERRORS) summary.errors.push({ home: null, message: safeMessage(err) });
    }
    return summary;
  }

  _count(summary, outcome) {
    const status = outcome && outcome.status;
    if (status === 'lost') summary.lost++;
    else if (status === 'dry_run') summary.dryRun++;
    else if (status === 'outside_window') return;
    else {
      summary.claimed++;
      if (status === 'clear') summary.clear++;
      else if (status === 'sent') summary.sent++;
      else if (status === 'no_recipients') summary.noRecipients++;
      else if (status === 'skipped_offline') summary.skippedOffline++;
      else if (status === 'skipped_hazard') summary.skippedHazard++;
      else summary.failed++;
    }
  }

  _withTimeout(promise, ms, label) {
    return new Promise((resolve, reject) => {
      const t = this.setTimer(() => reject(new TimeoutError(label)), ms);
      if (t && typeof t.unref === 'function') t.unref();
      Promise.resolve(promise).then(
        (v) => {
          this.clearTimer(t);
          resolve(v);
        },
        (e) => {
          this.clearTimer(t);
          reject(e);
        }
      );
    });
  }

  /** Günde bir: eski bildirim kayıtları ve devre dışı token'lar temizlenir (DRY_RUN yazmaz). */
  async _maybeMaintenance(nowMs) {
    if (this.config.dryRun) return;
    if (this._lastMaintenance !== null && nowMs - this._lastMaintenance < MAINTENANCE_EVERY_MS) return;
    this._lastMaintenance = nowMs;
    try {
      await this.db.query(SQL.purgeLogs, [LOG_RETENTION_DAYS]);
    } catch (err) {
      this._warnOnce('purge', `Bildirim kaydi temizligi hatasi: ${safeMessage(err)}`);
    }
    try {
      if (typeof this.push.cleanup === 'function') await this.push.cleanup({ olderThanDays: TOKEN_RETENTION_DAYS });
    } catch (err) {
      this._warnOnce('cleanup', `Push token temizligi hatasi: ${pushErrorLabel(err)}`);
    }
  }

  // ----------------------------------------------------------------------------
  // Ev başına değerlendirme
  // ----------------------------------------------------------------------------

  async _processHome(home, tz, nowMs) {
    const parsed = parseHHMM(home.peace_time);
    if (home.raw_time !== null && home.raw_time !== undefined && parseHHMM(home.raw_time) === null) {
      this._warnOnce(`time:${home.id}`, `Ev ${shortId(home.id)}: gecersiz saat bicimi, ${DEFAULT_TIME} kullaniliyor`);
    }
    const win = computeWindow(nowMs, tz, parsed === null ? DEFAULT_TIME : home.peace_time, this.config.catchupMin, this.time);
    if (!win) return { status: 'outside_window' }; // SQL adayı ile JS penceresi uyuşmadı: güvenli taraf = bildirme

    if (this.config.dryRun) return this._dryRun(home, win);

    // 1) ATOMIK talep: yalnızca bir süreç kazanır
    const claim = await this.db.query(SQL.claim, [home.id, win.dateKey, new Date(win.scheduledForMs).toISOString(), this.config.maxAttempts]);
    const row = claim && claim.rows && claim.rows[0];
    if (!row) return { status: 'lost' };
    const ticket = { noticeId: row.id, attempts: toCount(row.attempts), homeId: home.id, sendStarted: false };

    try {
      return await this._evaluate(home, ticket, win);
    } catch (err) {
      this.logger.error(`[PEACE] Ev ${shortId(home.id)} degerlendirme hatasi: ${safeMessage(err)}`);
      if (ticket.sendStarted) {
        // Push gönderimi BAŞLADI (satır 'sending'): teslim edilmiş olabilir. 'failed' (yeniden denenebilir) yazmak
        // ikinci bir push demektir; satır 'sending' kalır ve bu gece bir daha talep edilmez (en çok bir bildirim).
        return { status: 'failed' };
      }
      // Kayıt 'claimed' kalmasın: sonraki turda yeniden denenir (kira süresini beklemeden).
      await this._finish(ticket, { status: 'failed', details: { lights: [], shutters: [], reason: 'exception' } }).catch(() => {});
      return { status: 'failed' };
    }
  }

  async _dryRun(home, win) {
    const snap = await loadLiveSnapshot(this.db, home.id);
    const key = `${home.id}:${win.dateKey}`;
    if (!this._dryLogged.has(key)) {
      if (this._dryLogged.size >= DRY_RUN_MEMORY) this._dryLogged.clear();
      this._dryLogged.add(key);
      this.logger.log(
        `[PEACE] DRY_RUN ev ${shortId(home.id)}: ${snap.live ? `canli, ${snap.lights.length} lamba, ${snap.shutters.length} panjur acik` : 'canli cihaz yok'} (yazma/gonderim yok)`
      );
    }
    return { status: 'dry_run' };
  }

  async _evaluate(home, ticket, win) {
    const homeId = home.id;

    // 2) CANLI anlık görüntü: bayat veriyle asla bildirme
    const snap = await loadLiveSnapshot(this.db, homeId);
    if (!snap.live) {
      await this._finish(ticket, { status: 'skipped_offline', details: buildDetails(null, { reason: 'no_live_device' }) });
      return { status: 'skipped_offline' };
    }
    // 3) Açık bir şey yoksa sessiz kal. AMA evin bir kısmı ulaşılamıyorsa "hiçbir şey açık değil" demek doğru
    // olmaz (çevrimdışı kartın durumu BİLİNMİYOR): nihai 'clear' yazılmaz, cihaz dönene/pencere bitene dek yeniden denenir.
    if (snap.lights.length + snap.shutters.length === 0) {
      if (isPartiallyOffline(snap)) {
        await this._finish(ticket, { status: 'skipped_offline', details: buildDetails(snap, { reason: 'partial_offline' }) });
        return { status: 'skipped_offline' };
      }
      await this._finish(ticket, { status: 'clear', details: buildDetails(null) });
      return { status: 'clear' };
    }

    // Faz 2 F2.A.4: gaz alarmı açık evde "lambaları kapat" önerisi tehlikelidir (anahtarlama kıvılcımı): push YOK.
    // 'skipped_hazard' pencere içinde yeniden denenir (alarm kapanırsa bildirim yine gider).
    if (snap.gasAlarm === true) {
      await this._finish(ticket, { status: 'skipped_hazard', details: buildDetails(snap, { reason: 'gas_alarm' }) });
      return { status: 'skipped_hazard' };
    }

    // Kayıt, push olmasa bile uygulama içi yedek (last_notice) için sayıları ve özeti taşır.
    const base = { lights: snap.lights.length, shutters: snap.shutters.length, summary: this._summary(snap), details: buildDetails(snap) };

    if (typeof this.push.isConfigured === 'function' && !this.push.isConfigured()) {
      await this._finish(ticket, { ...base, status: 'no_recipients', details: buildDetails(snap, { reason: 'push_not_configured' }) });
      return { status: 'no_recipients' };
    }
    const recipients = await this.push.recipientsForHome(homeId);
    if (!Array.isArray(recipients) || recipients.length === 0) {
      await this._finish(ticket, { ...base, status: 'no_recipients', details: buildDetails(snap, { reason: 'no_tokens' }) });
      return { status: 'no_recipients' };
    }

    // 4) Gönderimden HEMEN ÖNCE yeniden anlık görüntü: kullanıcı bu arada kapatmış olabilir
    const fresh = await loadLiveSnapshot(this.db, homeId);
    if (!fresh.live) {
      await this._finish(ticket, { ...base, status: 'skipped_offline', details: buildDetails(snap, { reason: 'went_offline' }) });
      return { status: 'skipped_offline' };
    }
    if (fresh.lights.length + fresh.shutters.length === 0) {
      if (isPartiallyOffline(fresh)) {
        await this._finish(ticket, { status: 'skipped_offline', details: buildDetails(fresh, { reason: 'partial_offline' }) });
        return { status: 'skipped_offline' };
      }
      await this._finish(ticket, { status: 'clear', details: buildDetails(null, { reason: 'closed_before_send' }) });
      return { status: 'clear' };
    }
    if (fresh.gasAlarm === true) {
      await this._finish(ticket, { ...base, status: 'skipped_hazard', details: buildDetails(fresh, { reason: 'gas_alarm' }) });
      return { status: 'skipped_hazard' };
    }
    const final = { lights: fresh.lights.length, shutters: fresh.shutters.length, summary: this._summary(fresh) };

    // Gönderimden ÖNCE niyeti kaydet: 'claimed' -> 'sending'. Bundan sonra bu satır yeniden talep edilemez
    // (kira devri, hata sonrası yeniden deneme yok); push gittikten sonra kayıt yazımı çökse bile ikinci push gitmez.
    const marked = await this.db.query(SQL.markSending, [ticket.noticeId, ticket.attempts]);
    if (marked && marked.rowCount === 0) {
      this._warnOnce(`lease:${ticket.homeId}`, `Ev ${shortId(ticket.homeId)}: kayit baska ornek tarafindan devralindi, push gonderilmedi`);
      return { status: 'lost' };
    }
    ticket.sendStarted = true;

    // 5) Tek push (alıcı başına cihaz token'ları); token/başlık/gövde LOGLANMAZ
    let result;
    try {
      result = await this.push.sendNotice({
        tokens: recipients.map((r) => ({ id: r.id, token: r.token, platform: r.platform })),
        title: this._title(home.name),
        body: final.summary,
        data: {
          type: 'peace_open_devices',
          home_id: String(homeId),
          notice_id: String(ticket.noticeId),
          open_lights: String(final.lights),
          open_shutters: String(final.shutters),
          action: 'close_all',
          v: '1',
        },
      });
    } catch (err) {
      this.logger.error(`[PEACE] Ev ${shortId(homeId)} push hatasi: ${pushErrorLabel(err)}`);
      await this._finish(ticket, {
        status: 'failed',
        lights: final.lights,
        shutters: final.shutters,
        summary: final.summary,
        details: buildDetails(fresh, { reason: 'push_exception' }),
      });
      return { status: 'failed' };
    }

    const verdict = classifyPushResult(result);
    if (verdict.push.failed_other > 0) {
      this.logger.warn(`[PEACE] Ev ${shortId(homeId)}: ${verdict.push.failed_other} aliciya gecici/diger hata ile ulasilamadi (kismi teslim, yeniden gonderilmez)`);
    }
    try {
      await this._finish(ticket, {
        status: verdict.status,
        lights: final.lights,
        shutters: final.shutters,
        summary: final.summary,
        pushSent: verdict.push.sent,
        details: buildDetails(fresh, { ...(verdict.reason ? { reason: verdict.reason } : {}), push: verdict.push }),
      });
    } catch (err) {
      // Push zaten gitti: durumu 'failed'a ÇEVİRME (yeniden gönderim olur). Satır 'sending' kalır = tekrar gönderilmez.
      this.logger.error(`[PEACE] Ev ${shortId(homeId)}: push islendi ama kayit yazilamadi (satir 'sending' kaldi, yeniden gonderilmeyecek): ${safeMessage(err)}`);
    }
    return { status: verdict.status };
  }

  /**
   * Kaydı nihai/ara duruma çeker. Geçici DB hatasında FINISH_WRITE_TRIES kez dener (push gittikten sonra
   * kaydın yazılamaması çift gönderime yol açmasın diye); hâlâ olmazsa son hatayı fırlatır.
   * Talep başkasına geçtiyse (kira devri) yazmaz ve uyarır.
   */
  async _finish(ticket, f) {
    const details = JSON.stringify(f.details || { lights: [], shutters: [] });
    const params = [ticket.noticeId, f.status, f.lights || 0, f.shutters || 0, f.summary || null, details, f.pushSent || 0, ticket.attempts];
    let res;
    for (let attempt = 1; ; attempt++) {
      try {
        res = await this.db.query(SQL.finish, params);
        break;
      } catch (err) {
        if (attempt >= FINISH_WRITE_TRIES) throw err;
      }
    }
    if (res && res.rowCount === 0) {
      this._warnOnce(`lease:${ticket.homeId}`, `Ev ${shortId(ticket.homeId)}: kayit baska ornek tarafindan devralindi, durum yazilmadi`);
    }
  }

  /** Metin üretimi bozulsa bile hatırlatma susmasın: basit yedek cümle. */
  _summary(snapshot) {
    const input = {
      lights: snapshot.lights.map((l) => ({ room: l.room })),
      shutters: snapshot.shutters.map((s) => ({ room: s.room })),
    };
    try {
      const text = this._getText().buildSummary(input);
      if (typeof text === 'string' && text.trim() !== '') return text;
    } catch (err) {
      this._warnOnce('text', `Metin uretici hatasi (yedek cumle): ${safeMessage(err)}`);
    }
    const parts = [];
    if (input.lights.length > 0) parts.push(`${input.lights.length} lamba`);
    if (input.shutters.length > 0) parts.push(`${input.shutters.length} panjur`);
    return `${parts.join(', ')} açık.`;
  }

  _title(homeName) {
    try {
      const title = this._getText().buildTitle(homeName);
      if (typeof title === 'string' && title.trim() !== '') return title;
    } catch (err) {
      this._warnOnce('text', `Metin uretici hatasi (yedek baslik): ${safeMessage(err)}`);
    }
    return typeof homeName === 'string' && homeName.trim() !== '' ? homeName.trim().slice(0, 60) : 'Evim';
  }

  _getText() {
    if (!this.text) this.text = require('./services/peace_text');
    return this.text;
  }
}

/**
 * server.js girişi: yeni bir örnek oluşturup başlatır (modül düzeyinde gizli durum YOK;
 * kapanışta dönen örneğin `stop()`'u çağrılır).
 * @param {{db:object, push:object, text?:object, logger?:object, now?:Function, setTimer?:Function,
 *          clearTimer?:Function, env?:object}} deps
 * @returns {PeaceReminder}
 */
function start(deps = {}) {
  return new PeaceReminder(deps).start();
}

module.exports = {
  PeaceReminder,
  start,
  SQL,
  helpers: {
    DEFAULT_TZ,
    DEFAULT_TIME,
    DEFAULT_CATCHUP_MIN,
    RETRY_STEPS,
    RETRY_TOLERANCE_SEC,
    SCHEMA_RECHECK_MS,
    FINISH_WRITE_TRIES,
    maxAttemptsFor,
    retryGapSec,
    retryDueSec,
    retryDueSql,
    isPartiallyOffline,
    MAX_HOMES_PER_TICK,
    CONCURRENCY,
    HOME_TIMEOUT_MS,
    TICK_OFFSET_MS,
    LOG_RETENTION_DAYS,
    TOKEN_RETENTION_DAYS,
    REQUIRED_SCHEMA,
    createFallbackTimeHelpers,
    loadTimeHelpers,
    parseHHMM,
    formatHHMM,
    previousDateKey,
    candidateTargets,
    computeWindow,
    parseConfig,
    buildDetails,
    classifyPushResult,
  },
};
