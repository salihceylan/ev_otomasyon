'use strict';

// ==============================================================================
// AHBU Akıllı Ev - Gece huzur: ayar OKUMA v2 ve "Hepsini Kapat" v2            [WP-H §3.6]
// ==============================================================================
//
// Kullanım (device_service.js, 5 satırlık devir; ayrıntı raporun integrationRequests bölümünde):
//   const peace = createPeaceService({
//     db, publishCommand: (t, p) => this._publishCommand(t, p), newCommandId: () => this._newCommandId(),
//     audit: (q, a) => this._audit(q, a), httpError,
//   });
//   peace.getSettings({ homeId });                                     // GET  /peace-notification/:home_id
//   peace.closeAll({ actor, homeId, noticeId, includeShutters });      // POST /peace-notification/close-all
//   peace.closeLightsKeepingPlugs({ homeId, topicId });                // sendCommand all_lights_off / all_off (DAIRE-01)
//
// Bu modül YETKİ DENETLEMEZ (çağıran: DeviceService can('group') + route requireHomeAccess).
//
// v1'e (device_service.js) göre neden değişti?
//   * Açık lamba/panjur bilgisi CANLI cihazlardan okunur (peace_snapshot): çevrimdışı/bayat kartın
//     endpoints satırlarına güvenilmez; "Tüm lambalar kapalı" yanlış güven vermesin diye `stale` bilgisi döner.
//   * "Hepsini Kapat" panjurları da kapatır, yalnızca AÇIK olanlar için komut üretir (kapalı motoru yeniden
//     çalıştırmaz) ve evde `plug` varsa firmware'in toplu `all_lights_off` komutunu KULLANMAZ: o komut
//     uygulamada "priz" diye etiketlenen röleleri de kapatırdı.
//   * Bildirim kaydı ÇÖZÜLÜR (hangi geceki bildirimin kim tarafından kapatıldığı bilinir) ve denetim kaydı yazılır.
//
// Değişmez kurallar
//   * `endpoints` tablosuna ASLA yazılmaz: cihazın gerçek durumu yalnızca MQTT köprüsünün state yankısıyla
//     gelir. Komut PUBACK'i "uygulandı" demek değildir; iyimser yazım, cihaz uygulamazsa DB'yi yalancı yapardı.
//   * Önce YAYIN, sonra KAYIT. Yayın hatası yukarı fırlar ve bildirim çözülmez (komut gitmediyse "kapatıldı" denmez).
//     Yayın BAŞARILIYSA kayıt hatası komutu geri almaz (komutlar mutlaktır): loglanır, yanıt yine başarılıdır.
//   * Röle/panjur numaraları CONTRACTS §0 gereği 1 tabanlıdır. `endpoints.channel_index` de 1 tabanlıdır
//     (device_service.js SEED_ENDPOINTS_SQL: generate_series(1, N), pair = (n + 1) / 2), bu yüzden
//     `relay` = channel_index ve `shutter` = pair AYNEN, dönüşüm YOK.
//   * Bildirim çözümü 'sent' / 'no_recipients' ve 'sending' satırlarını çözer. 'sending' dahildir çünkü her push'un
//     `notice_id`si push anında 'sending' olan satırdır (değerlendirici 'sent'i push döndükten SONRA yazar; yavaş bir
//     FCM çağrısı ya da çöken süreç satırı 'sending'de bırakır). Güvenlidir: markSending yalnız 'claimed'i, yeniden talep
//     yalnız claimed/skipped_offline/failed'i eşler; çözülmüş satır bir daha talep edilemez, finish de ona yazmaz.
//     'claimed', 'skipped_offline', 'failed' (yeniden talep edilebilir) ve 'clear' satırlarına DOKUNULMAZ: aksi halde
//     değerlendirici çözülmüş bir satırı yeniden talep edip ikinci bildirim gönderebilirdi.
//   * Ev konusu (ev/{t}/cmd) evdeki TÜM panolara gider; komutlarda pano adresi yoktur. Çok panolu evde bir röle/panjur
//     numarası başka bir panodaki ışık-olmayan (priz, panjur) ya da kapalı bir ucu da etkilerdi: böyle numaralar
//     GÖNDERİLMEZ, `skipped_count` ile bildirilir ve bildirim ÇÖZÜLMEZ (ev gerçekte kapanmadı).

const DEFAULT_TIME = '23:30';
const DEFAULT_TIMEZONE = 'Europe/Istanbul';
const TIME_HHMM = /^([01]\d|2[0-3]):[0-5]\d$/;

// Bildirim çözümü için çözülebilir durumlar (migration 030 status kümesinin alt kümesi). 'sending' dahil (bkz. başlık).
const RESOLVABLE_STATUSES = Object.freeze(['sent', 'no_recipients', 'sending']);
// last_notice için gösterilebilir durumlar: değerlendiricinin nihai sonuçları + çözülmüş.
const NOTICE_VISIBLE_STATUSES = Object.freeze(['sent', 'no_recipients', 'resolved']);

// Firmware komut kuyruğu 24 (SmartAutomation.cpp); 16'lı gruplar arasında beklenir ki kuyruk taşmasın.
const CHUNK_SIZE = 16;
const CHUNK_DELAY_MS = 150;

const MAX_RELAY = 40; // command_schema.js MAX_RELAY (firmware MAX_TOTAL_RELAYS)
const MAX_SHUTTER_PAIR = MAX_RELAY / 2;
const MAX_NOTICE_ID = 2147483647; // peace_notification_logs.id SERIAL (INTEGER)

const TEXT_STALE = 'Cihaz çevrimdışı; açık lamba bilgisi güncel değil.';
const TEXT_ALL_CLOSED = 'Tüm lambalar kapalı, eviniz huzur modunda.'; // v1 metni, istemci bunu bekler
const OPEN_SHUTTER_MIN_POS_DEFAULT = 1; // peace_snapshot.OPEN_SHUTTER_MIN_POS yoksa (enjekte sahte) varsayılan

const AUDIT_EVENT = 'peace_close_all';

// SQL sabitleri tek yerde (testler aynı metni tanır). Durum listesi sabit dizilerden üretilir: kullanıcı girdisi YOK.
const sqlList = (items) => items.map((s) => `'${s}'`).join(', ');
const RESOLVABLE_SQL = sqlList(RESOLVABLE_STATUSES);
const VISIBLE_SQL = sqlList(NOTICE_VISIBLE_STATUSES);

const SQL = Object.freeze({
  home: 'SELECT id, name, peace_notification_enabled, peace_notification_time, timezone FROM homes WHERE id = $1',
  topic: 'SELECT mqtt_username FROM homes WHERE id = $1',
  // Evde 'plug' (uygulamada priz etiketli röle) varsa toplu all_lights_off KULLANILAMAZ. Cihaz canlı olmasa da
  // bakılır: komut ev konusuna (ev/{t}/cmd) gider, tüm panolar alır.
  hasPlug: "SELECT EXISTS (SELECT 1 FROM endpoints WHERE home_id = $1 AND type = 'plug') AS has_plug",
  // Yalnızca ÇOK PANOLU evlerde: ev konusu tüm panolara gittiği için numara çakışmasını bulmak üzere evin TÜM uçları
  // (çevrimdışı panolar dahil: geri geldiğinde komutu alabilirler). Ev başına <= panolar x 40 satır.
  layout:
    'SELECT device_id, type, channel_index, shutter_pair_index, current_position, actuator_type ' +
    'FROM endpoints WHERE home_id = $1',
  // local_date metne çevrilir: pg DATE'i yerel gece yarısı Date'ine çevirir ve gün kayabilir.
  lastNotice:
    "SELECT id, to_char(local_date, 'YYYY-MM-DD') AS local_date, status, summary_text, " +
    'open_lights_count, open_shutters_count, triggered_at, resolved_at ' +
    'FROM peace_notification_logs ' +
    `WHERE home_id = $1 AND local_date IS NOT NULL AND status IN (${VISIBLE_SQL}) ` +
    'ORDER BY local_date DESC, id DESC LIMIT 1',
  // $1 = çözen kullanıcı (NULL olabilir: servis oturumu), $2 = ilk komut kimliği (NULL olabilir),
  // $3 = istemcinin bildirim kimliği (NULL = evin en yeni çözülebilir bildirimi), $4 = ev.
  // Durum kısıtı iç sorguda da dış WHERE'de de ZORUNLU (bkz. dosya başlığı).
  resolveNotice:
    "UPDATE peace_notification_logs SET status = 'resolved', resolved_by_user = TRUE, " +
    'resolved_at = CURRENT_TIMESTAMP, resolved_by_user_id = $1::uuid, ' +
    "resolved_via = 'close_all', command_id = $2::varchar, updated_at = CURRENT_TIMESTAMP " +
    'WHERE id = COALESCE($3::int, (SELECT id FROM peace_notification_logs ' +
    'WHERE home_id = $4::uuid AND local_date IS NOT NULL AND resolved_at IS NULL ' +
    `AND status IN (${RESOLVABLE_SQL}) ORDER BY local_date DESC LIMIT 1)) ` +
    `AND home_id = $4::uuid AND resolved_at IS NULL AND status IN (${RESOLVABLE_SQL}) RETURNING id`,
  // Elle kapatma satırı: local_date NULL (UNIQUE (home_id, local_date) ile çakışmaz).
  insertManual:
    'INSERT INTO peace_notification_logs (home_id, open_lights_count, open_shutters_count, summary_text, ' +
    'status, resolved_by_user, resolved_at, resolved_via, resolved_by_user_id, command_id, updated_at) ' +
    "VALUES ($1, $2, $3, $4, 'manual', TRUE, CURRENT_TIMESTAMP, 'close_all', $5::uuid, $6::varchar, CURRENT_TIMESTAMP)",
});

// ------------------------------------------------------------------------------
// Saf yardımcılar (G/Ç yok; testte tek tek sınanır)
// ------------------------------------------------------------------------------

/** HH:MM ise aynen, NULL/bozuk ise 23:30 (servis katmanı ve değerlendirici aynı kuralı uygular). */
function normalizeTime(value) {
  return typeof value === 'string' && TIME_HHMM.test(value) ? value : DEFAULT_TIME;
}

function normalizeTimezone(value) {
  return typeof value === 'string' && value.trim() !== '' ? value.trim() : DEFAULT_TIMEZONE;
}

function toIso(value) {
  if (value === null || value === undefined) return null;
  const date = value instanceof Date ? value : new Date(value);
  return Number.isNaN(date.getTime()) ? null : date.toISOString();
}

/** pg DATE'i 'YYYY-MM-DD' metni (to_char) gelir; sürücü Date verirse yerel bileşenlerle çevrilir. */
function toDateKey(value) {
  if (value === null || value === undefined) return null;
  if (value instanceof Date) {
    if (Number.isNaN(value.getTime())) return null;
    const pad = (n) => String(n).padStart(2, '0');
    return `${value.getFullYear()}-${pad(value.getMonth() + 1)}-${pad(value.getDate())}`;
  }
  return String(value);
}

function toCount(value) {
  const n = Number(value);
  return Number.isFinite(n) && n > 0 ? Math.trunc(n) : 0;
}

function isIntInRange(value, min, max) {
  return Number.isInteger(value) && value >= min && value <= max;
}

/**
 * Çok panolu evde numara çakışmalarını bulur (tek panolu evde ÇAĞRILMAZ). Komutta pano adresi olmadığı için
 * `relay:N` / `shutter:P` evdeki her panoya gider:
 *  - relays: kanalı ışık-OLMAYAN (priz, panjur rölesi, ...) bir ucu olan kanal numaraları -> relay:N o ucu da keserdi.
 *  - pairs: bir panoda panjur çifti P yok / orada kapalı (ya da çift kanalları panjur değil) olan çiftler ->
 *    shutter:P kapalı motoru yeniden çalıştırırdı ya da panjur olmayan röleyi sürerdi.
 *
 * @param {object[]} rows  SQL.layout satırları
 * @returns {{relays:Set<number>, pairs:Set<number>}}
 */
function findSharedConflicts(rows, minOpenPos = OPEN_SHUTTER_MIN_POS_DEFAULT) {
  const relays = new Set();
  const perPair = new Map(); // pair -> Map(deviceId -> { openShutter:boolean, other:boolean })
  const touch = (pair, deviceId) => {
    if (!perPair.has(pair)) perPair.set(pair, new Map());
    const byDevice = perPair.get(pair);
    if (!byDevice.has(deviceId)) byDevice.set(deviceId, { openShutter: false, other: false });
    return byDevice.get(deviceId);
  };

  for (const row of Array.isArray(rows) ? rows : []) {
    const channel = Number(row.channel_index);
    if (!isIntInRange(channel, 1, MAX_RELAY)) continue;
    // Eylemci kanali (WP-S2 [Y3]) isik degildir: relay:N baska panonun vanasini/sirenini surerdi.
    if (row.type !== 'light' || (row.actuator_type !== undefined && row.actuator_type !== null)) relays.add(channel);
    if (row.type === 'shutter') {
      const rawPair = row.shutter_pair_index === null || row.shutter_pair_index === undefined ? null : Number(row.shutter_pair_index);
      const pair = rawPair !== null && isIntInRange(rawPair, 1, MAX_SHUTTER_PAIR) ? rawPair : Math.floor((channel + 1) / 2);
      const position = row.current_position === null || row.current_position === undefined ? null : Number(row.current_position);
      const entry = touch(pair, row.device_id);
      if (position !== null && position >= minOpenPos) entry.openShutter = true;
    } else {
      touch(Math.floor((channel + 1) / 2), row.device_id).other = true;
    }
  }

  const pairs = new Set();
  for (const [pair, byDevice] of perPair) {
    // Çift, kendisine ulaşan HER panoda açık bir panjur değilse belirsizdir.
    for (const entry of byDevice.values()) {
      if (!entry.openShutter || entry.other) {
        pairs.add(pair);
        break;
      }
    }
  }
  return { relays, pairs };
}

/**
 * Canlı anlık görüntüden kapatma komutlarını üretir.
 *  - Lambalar: `hasPlug` yoksa TEK {cmd:'all_lights_off'}; varsa yalnız AÇIK ışık röleleri için
 *    {relay:<1 tabanlı>, state:false}. Komut ev konusuna gider (tüm panolar alır): aynı kanal numarası
 *    birden çok panoda açıksa tek komut yeter (tekilleştirilir), sayıda ise her açık lamba sayılır.
 *  - Panjurlar (includeShutters): her AÇIK çift için {shutter:<pair>, cmd:'down'}. `all_shutters_down` KULLANILMAZ:
 *    zaten kapalı motorları yeniden çalıştırırdı.
 *  - `conflicts` (yalnız çok panolu ev, bkz. findSharedConflicts): çakışan numara için komut ÜRETİLMEZ; o lamba/panjur
 *    `skippedLights` / `skippedShutters` olarak sayılır (kapatılmış sayılmaz).
 * Geçersiz kanal/çift numaralı satırlar (CHECK ihlali; olmaması gerekir) komut üretmez ve SAYILMAZ.
 *
 * @returns {{commands:object[], closedLights:number, closedShutters:number, skippedLights:number, skippedShutters:number}}
 */
function buildCloseCommands({ lights, shutters, includeShutters, hasPlug, newCommandId, conflicts }) {
  const commands = [];
  let closedLights = 0;
  let closedShutters = 0;
  let skippedLights = 0;
  let skippedShutters = 0;
  const openLights = Array.isArray(lights) ? lights : [];
  const openShutters = Array.isArray(shutters) ? shutters : [];
  const blockedRelays = conflicts && conflicts.relays ? conflicts.relays : new Set();
  const blockedPairs = conflicts && conflicts.pairs ? conflicts.pairs : new Set();

  if (openLights.length > 0) {
    if (!hasPlug) {
      commands.push({ cmd: 'all_lights_off', id: newCommandId() });
      closedLights = openLights.length;
    } else {
      const seenChannels = new Set();
      for (const light of openLights) {
        if (!isIntInRange(light.channel, 1, MAX_RELAY)) continue;
        if (blockedRelays.has(light.channel)) {
          skippedLights += 1;
          continue;
        }
        closedLights += 1;
        if (seenChannels.has(light.channel)) continue;
        seenChannels.add(light.channel);
        commands.push({ relay: light.channel, state: false, id: newCommandId() });
      }
    }
  }

  if (includeShutters) {
    const seenPairs = new Set();
    for (const shutter of openShutters) {
      if (!isIntInRange(shutter.pair, 1, MAX_SHUTTER_PAIR)) continue;
      if (blockedPairs.has(shutter.pair)) {
        skippedShutters += 1;
        continue;
      }
      closedShutters += 1;
      if (seenPairs.has(shutter.pair)) continue;
      seenPairs.add(shutter.pair);
      commands.push({ shutter: shutter.pair, cmd: 'down', id: newCommandId() });
    }
  }
  return { commands, closedLights, closedShutters, skippedLights, skippedShutters };
}

/** "2 lamba ve 1 panjur" / "2 lamba" / "1 panjur" (tam sayı, çoğul eki yok). */
function describeCounts(lights, shutters) {
  const parts = [];
  if (lights > 0) parts.push(`${lights} lamba`);
  if (shutters > 0) parts.push(`${shutters} panjur`);
  return parts.join(' ve ');
}

function buildCloseMessage({ closedLights, closedShutters, resolved, skippedLights = 0, skippedShutters = 0 }) {
  const skipped = skippedLights + skippedShutters;
  if (closedLights + closedShutters > 0 || skipped > 0) {
    const parts = [];
    if (closedLights + closedShutters > 0) {
      parts.push(`Huzur modu: ${describeCounts(closedLights, closedShutters)} için kapatma komutu cihaza iletildi.`);
    }
    if (skipped > 0) {
      parts.push(`${describeCounts(skippedLights, skippedShutters)} birden fazla panonun ortak bağlantısı nedeniyle uzaktan kapatılamadı; lütfen elle kontrol edin.`);
    }
    return parts.join(' ');
  }
  // Komut gönderilmedi: kayıt durumu bayat olabilir, bu yüzden "kapatıldı" DEĞİL, "komut gönderilmedi" denir.
  return resolved
    ? 'Sunucu kayıtlarına göre açık lamba ya da panjur yok; cihaza komut gönderilmedi, bildirim kapatıldı.'
    : 'Sunucu kayıtlarına göre açık lamba ya da panjur yok; cihaza komut gönderilmedi.';
}

/** Elle kapatma satırının özeti: kişisel veri / oda adı içermez. */
function buildManualSummary(lights, shutters) {
  return `${describeCounts(lights, shutters)} tek tıkla kapatıldı.`;
}

/**
 * `noticeId` / `includeShutters` doğrulaması (DB'ye dokunmadan ÖNCE).
 * noticeId: yok/null -> null; pozitif tam sayı (ya da yalnız rakamlardan oluşan metin: FCM `data` değerleri
 * metindir, istemci olduğu gibi geri yollayabilir) -> sayı; diğer her şey 400 VALIDATION.
 */
function parseCloseInput({ noticeId, includeShutters }, httpError) {
  let notice = null;
  if (noticeId !== undefined && noticeId !== null) {
    const candidate = typeof noticeId === 'string' && /^\d{1,10}$/.test(noticeId) ? Number(noticeId) : noticeId;
    if (!isIntInRange(candidate, 1, MAX_NOTICE_ID)) {
      throw httpError(400, 'Bildirim kimliği (notice_id) pozitif bir tam sayı olmalı.', 'VALIDATION');
    }
    notice = candidate;
  }
  let shutters = true;
  if (includeShutters !== undefined && includeShutters !== null) {
    if (typeof includeShutters !== 'boolean') {
      throw httpError(400, '"include_shutters" alanı true veya false olmalı.', 'VALIDATION');
    }
    shutters = includeShutters;
  }
  return { noticeId: notice, includeShutters: shutters };
}

// ------------------------------------------------------------------------------
// Servis
// ------------------------------------------------------------------------------

function defaultSleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/** Ev kimliğinin ilk 8 karakteri: loglarda tam kimlik/kişisel veri yok. */
function shortId(homeId) {
  return String(homeId).slice(0, 8);
}

/**
 * @param {object} deps
 * @param {{query:Function, withTransaction?:Function}} deps.db  src/db.js
 * @param {(topicId:string, payload:object)=>Promise} deps.publishCommand  DeviceService._publishCommand (502 fırlatır)
 * @param {()=>string} deps.newCommandId                                    DeviceService._newCommandId
 * @param {(q:Function, a:object)=>Promise} deps.audit                      DeviceService._audit (q = (text, params) => Promise)
 * @param {(status:number, message:string, code?:string, extra?:object)=>Error} deps.httpError
 * @param {{loadLiveSnapshot:Function}} [deps.snapshot]  varsayılan ./peace_snapshot
 * @param {{buildSummary:Function}} [deps.text]          varsayılan ./peace_text
 * @param {()=>(Date|number)} [deps.now]                 yalnızca süre ölçümü için
 * @param {(ms:number)=>Promise} [deps.sleep]            varsayılan setTimeout tabanlı
 * @param {{warn?:Function, error?:Function}} [deps.logger]  varsayılan console
 */
function createPeaceService(deps = {}) {
  const { db, publishCommand, newCommandId, audit, httpError } = deps;
  if (!db || typeof db.query !== 'function') throw new TypeError('peace_service: db (query) zorunludur');
  if (typeof publishCommand !== 'function') throw new TypeError('peace_service: publishCommand zorunludur');
  if (typeof newCommandId !== 'function') throw new TypeError('peace_service: newCommandId zorunludur');
  if (typeof audit !== 'function') throw new TypeError('peace_service: audit zorunludur');
  if (typeof httpError !== 'function') throw new TypeError('peace_service: httpError zorunludur');

  const snapshot = deps.snapshot || require('./peace_snapshot');
  const text = deps.text || require('./peace_text');
  const sleep = typeof deps.sleep === 'function' ? deps.sleep : defaultSleep;
  const now = typeof deps.now === 'function' ? deps.now : () => new Date();
  const logger = deps.logger || console;

  const logInfo = (message) => {
    if (logger && typeof logger.log === 'function') logger.log(message);
  };
  const logWarn = (message) => {
    if (logger && typeof logger.warn === 'function') logger.warn(message);
  };
  const logError = (message) => {
    if (logger && typeof logger.error === 'function') logger.error(message);
  };

  const assertHomeId = (homeId) => {
    if (typeof homeId !== 'string' || homeId === '') throw httpError(404, 'Daire bulunamadı.', 'NOT_FOUND');
  };

  // --- closeAll ve closeLightsKeepingPlugs ORTAK adımları (aynı kural tek yerde) ---
  /** Evde 'plug' (priz) uç noktası var mı? Ev konusu tüm panolara gider: evin tamamına bakılır. */
  async function homeHasPlug(homeId) {
    const res = await db.query(SQL.hasPlug, [homeId]);
    const row = res && res.rows && res.rows[0];
    return Boolean(row && (row.has_plug === true || row.has_plug === 't'));
  }
  /** Canlı anlık görüntü; pano yoksa 404, hiçbir pano canlı değilse 409 DEVICE_OFFLINE. */
  async function loadLive(homeId) {
    const snap = await snapshot.loadLiveSnapshot(db, homeId);
    if (snap.devicesTotal === 0) throw httpError(404, 'Daireye bağlı pano bulunamadı.', 'NOT_FOUND');
    if (!snap.live) throw httpError(409, 'Cihaz çevrimdışı; lambalar kapatılamadı.', 'DEVICE_OFFLINE', { device_online: false });
    return snap;
  }
  /** Yalnız ÇOK PANOLU evde numara çakışmaları (findSharedConflicts); tek panolu evde sorgu yok, null. */
  async function loadConflicts(homeId, snap) {
    if (snap.devicesTotal <= 1) return null;
    const res = await db.query(SQL.layout, [homeId]);
    const minPos = Number.isFinite(snapshot.OPEN_SHUTTER_MIN_POS) ? snapshot.OPEN_SHUTTER_MIN_POS : OPEN_SHUTTER_MIN_POS_DEFAULT;
    return findSharedConflicts(res && res.rows, minPos);
  }
  /** Sırayla, PUBACK beklenerek yayın; her CHUNK_SIZE komutta kısa mola (firmware kuyruğu). Hata -> DUR, fırlat. */
  async function publishAll(topicId, homeId, commands, label) {
    for (let i = 0; i < commands.length; i += 1) {
      try {
        await publishCommand(topicId, commands[i]);
      } catch (err) {
        logWarn(`[PEACE] ${label} ev ${shortId(homeId)}: yayin ${i}/${commands.length} komuttan sonra durdu`);
        throw err;
      }
      if ((i + 1) % CHUNK_SIZE === 0 && i + 1 < commands.length) await sleep(CHUNK_DELAY_MS);
    }
  }

  /** Tek transaction (db.withTransaction varsa); yoksa ardışık sorgu (yalnızca eski/sahte db'ler için). */
  async function inTransaction(fn) {
    if (typeof db.withTransaction === 'function') {
      return db.withTransaction((tx) => fn((t, p) => tx.query(t, p)));
    }
    return fn((t, p) => db.query(t, p));
  }

  function mapLastNotice(row) {
    if (!row) return null;
    return {
      id: row.id,
      local_date: toDateKey(row.local_date),
      status: row.status,
      summary_text: row.summary_text === undefined ? null : row.summary_text,
      open_lights_count: toCount(row.open_lights_count),
      open_shutters_count: toCount(row.open_shutters_count),
      created_at: toIso(row.triggered_at),
      resolved_at: toIso(row.resolved_at),
    };
  }

  /**
   * GET ayarlar v2 (v1 anahtarları KALIR: Flutter hem `enabled`/`time` hem uzun adları okur).
   * Yalnızca OKUR.
   */
  async function getSettings({ homeId }) {
    assertHomeId(homeId);
    const homeRes = await db.query(SQL.home, [homeId]);
    const home = homeRes && homeRes.rows && homeRes.rows[0];
    if (!home) throw httpError(404, 'Daire bulunamadı.', 'NOT_FOUND');

    const snap = await snapshot.loadLiveSnapshot(db, homeId);
    const noticeRes = await db.query(SQL.lastNotice, [homeId]);

    const enabled = home.peace_notification_enabled !== false; // NULL = varsayılan açık
    const time = normalizeTime(home.peace_notification_time);
    const stale = !snap.live;

    // Bayat/çevrimdışı: "açık lamba yok" DEMEYİZ (bilinmiyor); sayılar 0 ve listeler boş.
    const lights = stale ? [] : snap.lights;
    const shutters = stale ? [] : snap.shutters;

    let summary = TEXT_ALL_CLOSED;
    if (stale) summary = TEXT_STALE;
    else if (lights.length + shutters.length > 0) {
      summary = text.buildSummary({ lights, shutters }) || TEXT_ALL_CLOSED;
    }

    return {
      home_id: home.id || homeId,
      enabled,
      time,
      peace_notification_enabled: enabled,
      peace_notification_time: time,
      timezone: normalizeTimezone(home.timezone),
      devices_total: snap.devicesTotal,
      devices_online: snap.devicesLive,
      stale,
      open_lights_count: lights.length,
      open_shutters_count: shutters.length,
      open_lights: lights.map((l) => ({ id: l.endpointId, channel_index: l.channel, name: l.name, room: l.room })),
      open_shutters: shutters.map((s) => ({ pair: s.pair, room: s.room, position: s.position })),
      summary_text: summary,
      last_notice: mapLastNotice(noticeRes && noticeRes.rows && noticeRes.rows[0]),
    };
  }

  /**
   * Yayından SONRA kayıt: bildirimi çöz, çözülmediyse (ve bir şey kapatıldıysa) elle satır ekle, denetim yaz.
   * Hepsi TEK transaction. Dönüş: çözülen bildirim kimliği (ya da null).
   */
  async function recordClose({ actor, homeId, noticeId, commandIds, closedLights, closedShutters, skippedCount = 0 }) {
    const actorId = actor && typeof actor.userId === 'string' && actor.userId !== '' ? actor.userId : null;
    const firstId = commandIds.length > 0 ? commandIds[0] : null;

    return inTransaction(async (q) => {
      // Kapatılamayan (belirsiz numaralı) öğe kaldıysa ev kapanmış sayılmaz: bildirim açık kalır.
      let resolvedId = null;
      if (skippedCount === 0) {
        const res = await q(SQL.resolveNotice, [actorId, firstId, noticeId, homeId]);
        const resolvedRow = res && res.rows && res.rows[0];
        resolvedId = resolvedRow ? resolvedRow.id : null;
      }

      // Çözülecek bildirim yoksa ama gerçekten bir şey kapatıldıysa: elle kapatma satırı (tıklama günlüğü).
      if (resolvedId === null && closedLights + closedShutters > 0) {
        await q(SQL.insertManual, [
          homeId,
          closedLights,
          closedShutters,
          buildManualSummary(closedLights, closedShutters),
          actorId,
          firstId,
        ]);
      }

      await audit(q, {
        event: AUDIT_EVENT,
        homeId,
        actor,
        details: {
          closed_lights: closedLights,
          closed_shutters: closedShutters,
          skipped_count: skippedCount,
          notice_id: resolvedId,
          requested_notice_id: noticeId,
          resolved: resolvedId !== null,
          command_ids: commandIds,
        },
      });
      return resolvedId;
    });
  }

  /**
   * POST close-all v2. Hata sözleşmesi: 400 VALIDATION, 404 NOT_FOUND, 409 DEVICE_OFFLINE, 502 BROKER_UNAVAILABLE
   * (yayıncıdan olduğu gibi yukarı çıkar).
   */
  async function closeAll({ actor, homeId, noticeId, includeShutters } = {}) {
    const input = parseCloseInput({ noticeId, includeShutters }, httpError);
    assertHomeId(homeId);

    const topicRes = await db.query(SQL.topic, [homeId]);
    const topicRow = topicRes && topicRes.rows && topicRes.rows[0];
    if (!topicRow) throw httpError(404, 'Daire bulunamadı.', 'NOT_FOUND');
    const topicId = topicRow.mqtt_username;

    const snap = await loadLive(homeId);
    const hasPlug = snap.lights.length > 0 ? await homeHasPlug(homeId) : false;

    // Çok panolu ev: ev konusu tüm panolara gider, numara çakışmaları komuttan ÖNCE ayıklanır (bkz. başlık).
    // Sorgu YAYINDAN önce: hata verirse hiçbir komut gitmemiştir.
    const needsPerItem = (hasPlug && snap.lights.length > 0) || (input.includeShutters && snap.shutters.length > 0);
    const conflicts = needsPerItem ? await loadConflicts(homeId, snap) : null;

    const { commands, closedLights, closedShutters, skippedLights, skippedShutters } = buildCloseCommands({
      lights: snap.lights, shutters: snap.shutters, includeShutters: input.includeShutters, hasPlug, newCommandId, conflicts,
    });
    const skippedCount = skippedLights + skippedShutters;
    if (skippedCount > 0) {
      logWarn(`[PEACE] close-all ev ${shortId(homeId)}: ${skippedCount} oge cok panolu ortak konu nedeniyle atlandi`);
    }

    // Yayın hatası -> bildirim ÇÖZÜLMEZ ve hiçbir şey yazılmaz.
    const startedAt = Number(now());
    await publishAll(topicId, homeId, commands, 'close-all');

    const commandIds = commands.map((c) => c.id);
    let resolvedId = null;
    try {
      resolvedId = await recordClose({
        actor,
        homeId,
        noticeId: input.noticeId,
        commandIds,
        closedLights,
        closedShutters,
        skippedCount,
      });
    } catch (err) {
      // Komutlar yayınlandı ve mutlaktır: kayıt hatası onları geri alamaz; tekrar dokunuş zararsızdır.
      logError(`[PEACE] close-all ev ${shortId(homeId)}: komutlar iletildi ama kayit yazilamadi: ${err && err.message}`);
      resolvedId = null;
    }
    if (commands.length > 0) {
      logInfo(`[PEACE] close-all ev ${shortId(homeId)}: ${commands.length} komut, ${Number(now()) - startedAt} ms`);
    }

    const resolved = resolvedId !== null;
    return {
      closed_lights: closedLights,
      closed_shutters: closedShutters,
      closed_count: closedLights, // v1 anahtarı: yalnız lamba sayısı
      skipped_count: skippedCount, // ortak ev konusu nedeniyle komut gönderilemeyen lamba+panjur (çok panolu ev)
      // true = sunucu kayıtlarına göre kapatılacak bir şey YOKTU ve hiçbir komut gönderilmedi. Kayıtlar (state yankısı)
      // bayat olabilir; istemci bunu "kapatıldı" diye göstermemeli.
      nothing_to_do: commands.length === 0 && skippedCount === 0,
      delivered: true, // broker PUBACK (cihaza uygulandı demek DEĞİL; gerçek durum state yankısıyla gelir)
      device_online: true,
      command_ids: commandIds,
      command_id: commandIds.length > 0 ? commandIds[0] : null,
      notice_id: resolvedId,
      resolved,
      message: buildCloseMessage({ closedLights, closedShutters, resolved, skippedLights, skippedShutters }),
    };
  }

  /**
   * Toplu "ışıkları kapat" (DeviceService.sendCommand: all_lights_off / all_off) için "Hepsini Kapat" ile AYNI kural
   * (DAIRE-01): firmware'de priz tipi yoktur, toplu komut prizleri de kapatırdı. Evde priz YOKSA null (hiçbir şey
   * yayınlanmaz; çağıran toplu komutu aynen yayınlar); varsa yalnız AÇIK ışık röleleri {relay:N, state:false, id}
   * (çok panolu evde ortak numaralar atlanır). Panjur/kayıt yok. Hatalar: 404, 409 DEVICE_OFFLINE, 502.
   */
  async function closeLightsKeepingPlugs({ homeId, topicId } = {}) {
    assertHomeId(homeId);
    if (!(await homeHasPlug(homeId))) return null;
    const snap = await loadLive(homeId);
    const conflicts = snap.lights.length > 0 ? await loadConflicts(homeId, snap) : null;
    const { commands, closedLights, skippedLights } = buildCloseCommands({
      lights: snap.lights, shutters: [], includeShutters: false, hasPlug: true, newCommandId, conflicts,
    });
    if (skippedLights > 0) logWarn(`[PEACE] isik-kapat ev ${shortId(homeId)}: ${skippedLights} lamba ortak konu nedeniyle atlandi`);
    await publishAll(topicId, homeId, commands, 'isik-kapat');
    return { commandIds: commands.map((c) => c.id), closedLights, skippedLights };
  }

  return { getSettings, closeAll, closeLightsKeepingPlugs };
}

module.exports = {
  createPeaceService,
  RESOLVABLE_STATUSES,
  CHUNK_SIZE,
  CHUNK_DELAY_MS,
  SQL,
  helpers: { buildCloseCommands, findSharedConflicts, buildCloseMessage, buildManualSummary, parseCloseInput, normalizeTime },
};
