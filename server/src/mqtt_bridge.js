'use strict';

// ==============================================================================
// AHBU Akilli Ev - MQTT koprusu (backend <-> EMQX)            [CONTRACTS.md §2]
// ==============================================================================
//
// Gorevleri
//   1) Cihazlarin yayinladigi `ev/{t}/state` ve `ev/{t}/status` mesajlarini dinleyip
//      veritabanina (endpoints / devices) yansitmak.
//   2) Sunucudan cihaza komut yayinlamak: `ev/{t}/cmd` (QoS1, retain=false) ve
//      yonetim komutlari `ev/{t}/sys`. Uygulamalar MQTT'ye YAYIN YAPAMAZ; tum komutlar
//      REST -> sunucu -> bu kopru uzerinden gecer.
//
// Onemli davranislar
//   - `packet.retain` farkindaligi: broker'in abonelik aninda tekrar teslim ettigi
//     (retained) `state` yalnizca endpoint verisini gunceller; `is_online` ve
//     `last_seen_at` DEGISMEZ (eski bir mesaj cihazin simdi canli oldugunu kanitlamaz).
//     Cevrimici bilgisi yalnizca canli `status`/LWT ve canli `state` ile gelir.
//   - COCUK KILIDI tek dogruluk kaynagi = cihaz bildirimi (`state.child_lock`): CANLI state
//     `devices.child_lock_enabled`'i yazar ve AYNI transaction'da `homes.child_lock_enabled`'i
//     bool_and(devices...) ile esitler (REST servisi homes'u okur). RETAINED state kilidi YAZMAZ
//     (bayat retained yeni uygulanmis komutu ezmesin); yalnizca CEVRIMDISI/bilinmeyen panoda
//     uzlastirilir (`is_online IS NOT TRUE`). `last_id` bos dizge (taze pano) gecerlidir.
//   - Cihaz esleme `state.uid` ile yapilir (yoksa evin tek cihazi; belirsizse yok sayilir).
//   - Her mesaj dogrulanir (tip/aralik, 64 KB sinir) ve ayri try/catch icinde islenir;
//     bozuk bir mesaj kopruyu asla durdurmaz.
//   - Endpoint guncellemeleri TOPLU `UPDATE ... FROM (VALUES ...) ... IS DISTINCT FROM`
//     ile ve tek transaction icinde yapilir (degismeyen satira yazilmaz).
//   - Ayni konu (ev) icin mesajlar sirayla, farkli evler sinirli es zamanlilikla islenir;
//     bekleyen eski `state` yenisiyle birlestirilir (hucum/yeniden-oynatma baski kontrolu).
//   - Firmware sozlesmesi (CONTRACTS §3b, C11): cihaz `state`/`status`'u QoS 0 yayinlar (yalniz LWT QoS 1
//     retained "offline"); kopru hicbir kararda QoS'e bakmaz. `state.last_id` bossa alan HIC yoktur
//     (yok = gecerli; ack'e dokunulmaz); `shutters[]` yalniz yapilandirilmis ciftleri tasir (raporlanmayan
//     cift silinmez/sifirlanmaz); `uid` ("AHBU-S3-" + 6 hex) buyuk/kucuk harf duyarsiz eslenir; `relays[].type`
//     metindir (kopru durum guncellemesinde kullanmaz; yerlesim esitleme servisi kullanir - asagida);
//     `child_lock` her state'te vardir. Kayip "online" status'u canli state ile telafi edilir (her canli state
//     cihazi cevrimici yapar).
//   - Yuk: kalp atisi 30 sn, degisiklikte ~0.4 sn. Mesaj basina <= 1 transaction ve 5 sorgu; ayni eve ait
//     bekleyen eski state'ler birlestirilir; degismeyen satira yazilmaz. devices.last_seen_at/is_online
//     INDEKSLENMEZ (migration 026): her kalp atisi HOT guncelleme olarak kalir.
//   - 120 sn sessiz kalan cihaz "cevrimdisi" sayilir (supurucu). Cihaz kalp atisi 30 sn.
//   - `clean:false` + sabit clientId, abonelik `granted` kontrolu, ustel yeniden baglanma.
//   - Komut yayini asla offline kuyruga alinmaz (bayat komut gec calismasin): baglanti yoksa
//     `BrokerUnavailableError` (HTTP 502, BROKER_UNAVAILABLE) ile reddedilir.
//   - CEVRIMICI OLUNCA UZLASTIRMA (plan §5d-3, services/device_reconciler.js; yalniz `reconcile: true` ile -
//     uretim tekili): canli (retained OLMAYAN) state COMMIT edildikten sonra uzlastirici cagrilir; cihaz cevrimici
//     doneminin basinda bekleyen niyet (cocuk kilidi, pano degisimi sonrasi panjur sureleri) cihaz durumundan
//     farkliysa `publishCommand` yoluyla bir kez uygulanir. Ana state yolunu (toplu UPDATE, retain farkindaligi,
//     sorgu/transaction sayisi) DEGISTIRMEZ: ek sorgular ayri, sonradan ve hata yalitimli calisir.
//   - CIHAZ ONAYI BEKLEME (DAIRE-03): `expectAck(topicId, commandId, timeoutMs)` -> Promise<boolean>. Firmware
//     basarili komutta `state.last_id`'yi komut kimligine esitler ve hemen yayinlar; reddettigi komutta last_id
//     DEGISMEZ. Bekleyici YAYINDAN ONCE kurulur (hizli yanki kacmaz); yalniz CANLI state onaydir (retained bayat
//     olabilir) ve kuyruk birlestirmesinden ONCE denetlenir (ara state'teki yanki kaybolmaz). Zaman asimi / end() /
//     cancelAck -> false. Toplam bekleyici sayisi ACK_MAX_WAITERS ile sinirlidir (dolunca yeni bekleme 503).
//   - YERLESIM ESITLEME (WP-L, CONTRACTS §2.4b): services/endpoint_layout_sync.js; yalniz `layoutSync: true` ile
//     (uretim tekili). Dogrulanmis her state'in HAM yukunden panonun bildirdigi yerlesim (role id + tip + ad, panjur
//     ciftleri) cikarilir (utils/endpoint_layout.js `extractReportedLayout`; en kucuk suphede null). Yalniz CANLI
//     (retained OLMAYAN) state COMMIT edildikten sonra, uzlastirici bildiriminin ardindan servise bildirilir; servis
//     `endpoints` satirlarini kendi kuyrugunda / transaction'inda uzlastirir. Ana state yolunu DEGISTIRMEZ ve hata
//     yalitimlidir (cikarma ve bildirim ayri try/catch). `ENDPOINT_LAYOUT_SYNC=off|0|false` servisi hic kurmaz.
//
// Ortam degiskenleri (CONTRACTS §6): MQTT_HOST, MQTT_PORT, MQTT_BACKEND_USER,
// MQTT_BACKEND_PASS. Opsiyonel: MQTT_TLS=true, MQTT_CLIENT_ID, MQTT_OFFLINE_AFTER_SEC,
// MQTT_RECONNECT_MIN_MS, MQTT_RECONNECT_MAX_MS, MQTT_PUBLISH_TIMEOUT_MS (varsayilan 5000),
// ENDPOINT_LAYOUT_SYNC (off / 0 / false = yerlesim esitleme kapali; varsayilan acik).
//
// GUVENLIK: yuk (payload) icerigi ve parolalar log'a YAZILMAZ (sys komutlari gizli deger
// tasiyabilir). Yalnizca konu, bayt sayisi ve hata mesaji loglanir.

const os = require('os');
const net = require('net');
const { HttpError } = require('./utils/helpers');

// ------------------------------------------------------------------------------
// Sabitler
// ------------------------------------------------------------------------------
const TOPIC_ID_RE = /^[A-Za-z0-9_-]{1,64}$/;
const COMMAND_TOPIC_RE = /^ev\/([A-Za-z0-9_-]{1,64})\/(cmd|sys)$/;
const INCOMING_TOPIC_RE = /^ev\/([A-Za-z0-9_-]{1,64})\/(state|status)$/;
const UID_RE = /^[A-Za-z0-9][A-Za-z0-9_.-]{2,63}$/;
const FW_RE = /^[0-9A-Za-z][0-9A-Za-z._+-]{0,31}$/;
const LAST_ID_RE = /^[A-Za-z0-9_.:-]{1,24}$/;

const MAX_PAYLOAD_BYTES = 64 * 1024; // gelen mesaj ust siniri
const MAX_COMMAND_BYTES = 1024; // giden komut ust siniri (firmware JSON havuzu kucuktur)
const MAX_ARRAY_ITEMS = 64;
const MAX_RELAY_ID = 64;
const MAX_SHUTTER_PAIR = 32;
const ACK_MAX_WAITERS = 1000; // es zamanli cihaz onayi bekleyicisi ust siniri (bellek korumasi)
const ACK_MAX_TIMEOUT_MS = 30 * 1000; // tek bekleyicinin en uzun suresi

const DEFAULTS = Object.freeze({
  host: '127.0.0.1',
  port: 1884, // docker-compose: 127.0.0.1:1884 -> EMQX 1883 (yalnizca ev yigini)
  keepaliveSec: 30,
  connectTimeoutMs: 10 * 1000,
  reconnectMinMs: 1000,
  reconnectMaxMs: 60 * 1000,
  publishTimeoutMs: 5 * 1000,
  offlineAfterSec: 120,
  sweepIntervalMs: 30 * 1000,
  queueConcurrency: 4,
  queueMaxPending: 5000,
  resubscribeDelayMs: 10 * 1000,
  warnIntervalMs: 60 * 1000,
});

const SUBSCRIPTIONS = Object.freeze(['ev/+/status', 'ev/+/state']);

// ------------------------------------------------------------------------------
// Hatalar
// ------------------------------------------------------------------------------

/**
 * Broker'a yayin yapilamadi (baglanti yok / zaman asimi / ret). HTTP 502 BROKER_UNAVAILABLE.
 * `name` bilerek 'HttpError' birakilir: global hata yakalayici (middlewares/error_handler.js) HttpError'u
 * `err.name === 'HttpError'` ile taniyip `code` alanini (BROKER_UNAVAILABLE) istemciye gecirir.
 * Ayirt etmek icin `instanceof BrokerUnavailableError` veya `err.code` kullanin.
 */
class BrokerUnavailableError extends HttpError {
  constructor(message = 'MQTT sunucusuna bağlantı yok; komut iletilemedi.', cause = null) {
    super(502, message, 'BROKER_UNAVAILABLE');
    if (cause) this.cause = cause;
  }
}

// ------------------------------------------------------------------------------
// Saf yardimcilar (test edilebilir)
// ------------------------------------------------------------------------------

function isValidTopicId(value) {
  return typeof value === 'string' && TOPIC_ID_RE.test(value);
}

/** `ev/{id}/{state|status}` -> { topicId, kind } | null */
function parseIncomingTopic(topic) {
  if (typeof topic !== 'string') return null;
  const m = INCOMING_TOPIC_RE.exec(topic);
  return m ? { topicId: m[1], kind: m[2] } : null;
}

/** `status` yuku: yalnizca "online" / "offline" (buyuk-kucuk harf duyarsiz). Aksi null. */
function parseStatusPayload(text) {
  if (typeof text !== 'string') return null;
  const t = text.trim().toLowerCase();
  if (t === 'online') return true;
  if (t === 'offline') return false;
  return null;
}

function isIntInRange(v, min, max) {
  return typeof v === 'number' && Number.isInteger(v) && v >= min && v <= max;
}

/**
 * `state` yukunu dogrular ve normalize eder (CONTRACTS §2.4).
 *
 * Katı tip kurali: `state` yalnizca boolean, `pos` yalnizca 0..100 tamsayi. Gecersiz
 * girdiler SESSIZCE DUZELTILMEZ; ilgili kayit atlanir ve `skipped` sayaci artar.
 * Kok nesne degilse `{ ok:false }` doner.
 *
 * @returns {{ok:false, reason:string} | {ok:true, value:{
 *   uid:string|null, fw:string|null, ip:string|null, childLock:boolean|null, lastId:string|null,
 *   relays:Array<{id:number,state:boolean}>, shutters:Array<{pair:number,pos:number}>, skipped:number }}}
 */
function validateStatePayload(obj) {
  if (obj === null || typeof obj !== 'object' || Array.isArray(obj)) {
    return { ok: false, reason: 'kok nesne degil' };
  }
  let skipped = 0;
  const out = {
    uid: null,
    fw: null,
    ip: null,
    childLock: null,
    lastId: null,
    relays: [],
    shutters: [],
    skipped: 0,
  };

  if (obj.uid !== undefined) {
    if (typeof obj.uid === 'string' && UID_RE.test(obj.uid.trim())) out.uid = obj.uid.trim().toUpperCase();
    else skipped++;
  }
  if (obj.fw !== undefined) {
    if (typeof obj.fw === 'string' && FW_RE.test(obj.fw.trim())) out.fw = obj.fw.trim();
    else skipped++;
  }
  if (obj.ip !== undefined) {
    if (typeof obj.ip === 'string' && obj.ip.length <= 45 && net.isIP(obj.ip) !== 0) out.ip = obj.ip;
    else skipped++;
  }
  if (obj.child_lock !== undefined) {
    if (typeof obj.child_lock === 'boolean') out.childLock = obj.child_lock;
    else skipped++;
  }
  if (obj.last_id !== undefined) {
    if (obj.last_id === '') {
      // Taze pano henuz komut almadi: bos dizge GECERLI ("ack yok"); her kalp atisinda uyari uretmez.
      out.lastId = null;
    } else if (typeof obj.last_id === 'string' && LAST_ID_RE.test(obj.last_id)) {
      out.lastId = obj.last_id;
    } else {
      skipped++;
    }
  }

  if (obj.relays !== undefined) {
    if (!Array.isArray(obj.relays)) {
      skipped++;
    } else {
      const byId = new Map();
      for (const r of obj.relays.slice(0, MAX_ARRAY_ITEMS)) {
        if (r && typeof r === 'object' && isIntInRange(r.id, 1, MAX_RELAY_ID) && typeof r.state === 'boolean') {
          byId.set(r.id, r.state); // ayni id tekrar ederse sonuncu gecerli
        } else {
          skipped++;
        }
      }
      if (obj.relays.length > MAX_ARRAY_ITEMS) skipped++;
      out.relays = [...byId].map(([id, state]) => ({ id, state }));
    }
  }

  if (obj.shutters !== undefined) {
    if (!Array.isArray(obj.shutters)) {
      skipped++;
    } else {
      const byPair = new Map();
      for (const s of obj.shutters.slice(0, MAX_ARRAY_ITEMS)) {
        if (s && typeof s === 'object' && isIntInRange(s.pair, 1, MAX_SHUTTER_PAIR) && isIntInRange(s.pos, 0, 100)) {
          byPair.set(s.pair, s.pos);
        } else {
          skipped++;
        }
      }
      if (obj.shutters.length > MAX_ARRAY_ITEMS) skipped++;
      out.shutters = [...byPair].map(([pair, pos]) => ({ pair, pos }));
    }
  }

  out.skipped = skipped;
  return { ok: true, value: out };
}

/** Toplu role durumu guncellemesi. Degismeyen satira yazilmaz (IS DISTINCT FROM). */
function buildRelayStateUpdate(deviceId, relays) {
  if (!Array.isArray(relays) || relays.length === 0) return null;
  const values = [deviceId];
  const rows = relays.map((r) => {
    values.push(r.id, r.state);
    const n = values.length;
    return `($${n - 1}::int, $${n}::boolean)`;
  });
  const text =
    'UPDATE endpoints e SET current_state = v.state, updated_at = CURRENT_TIMESTAMP ' +
    `FROM (VALUES ${rows.join(', ')}) AS v(channel, state) ` +
    'WHERE e.device_id = $1 AND e.channel_index = v.channel ' +
    'AND e.current_state IS DISTINCT FROM v.state';
  return { text, values };
}

/**
 * Toplu panjur konumu guncellemesi. `pair` 1 tabanlidir; `shutter_pair_index` bos
 * kayitlar icin `pair N` = role 2N-1 ve 2N kuralina dusulur (CONTRACTS §0).
 */
function buildShutterPositionUpdate(deviceId, shutters) {
  if (!Array.isArray(shutters) || shutters.length === 0) return null;
  const values = [deviceId];
  const rows = shutters.map((s) => {
    values.push(s.pair, s.pos);
    const n = values.length;
    return `($${n - 1}::int, $${n}::int)`;
  });
  const text =
    'UPDATE endpoints e SET current_position = v.pos, updated_at = CURRENT_TIMESTAMP ' +
    `FROM (VALUES ${rows.join(', ')}) AS v(pair, pos) ` +
    "WHERE e.device_id = $1 AND e.type = 'shutter' " +
    'AND (e.shutter_pair_index = v.pair OR ' +
    '(e.shutter_pair_index IS NULL AND e.channel_index IN (v.pair * 2 - 1, v.pair * 2))) ' +
    'AND e.current_position IS DISTINCT FROM v.pos';
  return { text, values };
}

/**
 * Cihaz telemetri guncellemesi.
 * @param {boolean} live  true: canli mesaj (cevrimici + last_seen + ack). false: retained
 *                        tekrar teslim (yalnizca ip/fw/cocuk kilidi; cevrimici bilgisi DEGISMEZ).
 */
function buildDeviceUpdate(deviceId, v, live) {
  const values = [deviceId];
  const sets = [];
  const changes = []; // retained yolunda gereksiz yazimi onlemek icin
  const add = (column, value) => {
    values.push(value);
    const ph = `$${values.length}`;
    sets.push(`${column} = ${ph}`);
    changes.push(`${column} IS DISTINCT FROM ${ph}`);
    return ph;
  };

  if (v.ip) add('ip_address', v.ip);
  if (v.fw) add('firmware_version', v.fw);
  // Cocuk kilidi YALNIZCA canli state'ten yazilir: bayat retained, yeni uygulanmis bir komutu ezmesin.
  // (Cevrimdisi pano icin retained uzlastirmasi: buildChildLockReconcile.)
  if (live && v.childLock !== null && v.childLock !== undefined) add('child_lock_enabled', v.childLock);

  if (live) {
    sets.push('is_online = TRUE', 'last_seen_at = CURRENT_TIMESTAMP');
    if (v.lastId) {
      values.push(v.lastId);
      const ph = `$${values.length}`;
      // Ack zamani yalnizca kimlik degisince ilerler (kalp atisi ayni last_id'yi tekrarlar).
      sets.push(
        `last_ack_at = CASE WHEN last_ack_id IS DISTINCT FROM ${ph} THEN CURRENT_TIMESTAMP ELSE last_ack_at END`,
        `last_ack_id = ${ph}`
      );
    }
    return { text: `UPDATE devices SET ${sets.join(', ')} WHERE id = $1`, values };
  }

  if (sets.length === 0) return null;
  return {
    text: `UPDATE devices SET ${sets.join(', ')} WHERE id = $1 AND (${changes.join(' OR ')})`,
    values,
  };
}

/**
 * Retained state'ten cocuk kilidi UZLASTIRMASI: yalnizca cevrimdisi (veya durumu bilinmeyen) pano icin.
 * Cevrimici panoda canli state esastir; bayat retained yeni komutu ezmemelidir.
 */
function buildChildLockReconcile(deviceId, childLock) {
  if (typeof childLock !== 'boolean') return null;
  return {
    text:
      'UPDATE devices SET child_lock_enabled = $2 ' +
      'WHERE id = $1 AND is_online IS NOT TRUE AND child_lock_enabled IS DISTINCT FROM $2',
    values: [deviceId, childLock],
  };
}

/**
 * Cocuk kilidi TEK DOGRULUK KAYNAGI = cihaz bildirimi: evin kilidi, evdeki cihazlarin bildirimlerinin
 * `bool_and`'idir (cihaz yoksa degismez). REST servisi `homes.child_lock_enabled`'i okur.
 */
function buildHomeChildLockSync(homeId) {
  return {
    text:
      'UPDATE homes h SET child_lock_enabled = s.v ' +
      'FROM (SELECT bool_and(COALESCE(d.child_lock_enabled, FALSE)) AS v FROM devices d WHERE d.home_id = $1) s ' +
      'WHERE h.id = $1 AND s.v IS NOT NULL AND h.child_lock_enabled IS DISTINCT FROM s.v',
    values: [homeId],
  };
}

/** Onay bekleyicisi anahtari: konu ve komut kimligi kurallari `|` icermez. */
function ackKey(topicId, commandId) {
  return `${topicId}|${commandId}`;
}

/** Bir komut/sys yuku icin JSON uretir; boyut ve tip denetimi yapar. */
function serializeCommand(obj) {
  if (obj === null || typeof obj !== 'object' || Array.isArray(obj)) {
    throw new TypeError('Komut yuku bir nesne olmalidir');
  }
  const json = JSON.stringify(obj);
  if (Buffer.byteLength(json, 'utf8') > MAX_COMMAND_BYTES) {
    throw new RangeError(`Komut yuku ${MAX_COMMAND_BYTES} bayti asiyor`);
  }
  return json;
}

// ------------------------------------------------------------------------------
// Anahtarli is kuyrugu: ayni anahtar (ev) icin sirali, genel olarak sinirli es zamanlilik.
// ------------------------------------------------------------------------------
class KeyedWorkQueue {
  constructor({ concurrency = DEFAULTS.queueConcurrency, maxPending = DEFAULTS.queueMaxPending } = {}) {
    this.concurrency = concurrency;
    this.maxPending = maxPending;
    this._lanes = new Map(); // key -> { jobs:[], running:boolean, queued:boolean }
    this._ready = []; // calisacak anahtarlar (FIFO); her anahtar en fazla bir kez
    this._active = 0;
    this._pending = 0;
    this._idleWaiters = [];
    this.stats = { enqueued: 0, coalesced: 0, dropped: 0, completed: 0, failed: 0 };
  }

  get pending() {
    return this._pending;
  }

  get active() {
    return this._active;
  }

  /**
   * @param {string} key      Siralama anahtari (ev konu kimligi)
   * @param {string} kind     'state' | 'status' ...
   * @param {Function} run    async is
   * @param {{coalesce?:boolean}} opts  true: ayni anahtarin SON bekleyen isi ayni turdeyse
   *                                    onun yerine gecer (yalnizca en yeni durum anlamli).
   * @returns {Promise<{value?:any,error?:Error,dropped?:boolean}>} asla reddetmez
   */
  push(key, kind, run, { coalesce = false } = {}) {
    return new Promise((resolve) => {
      let lane = this._lanes.get(key);
      if (!lane) {
        lane = { jobs: [], running: false, queued: false };
        this._lanes.set(key, lane);
      }
      const last = lane.jobs[lane.jobs.length - 1];
      if (coalesce && last && last.coalesce && last.kind === kind && !last.started) {
        last.run = run;
        last.waiters.push(resolve);
        this.stats.coalesced++;
        return;
      }
      if (this._pending >= this.maxPending) {
        this.stats.dropped++;
        if (lane.jobs.length === 0) this._lanes.delete(key);
        resolve({ dropped: true });
        return;
      }
      lane.jobs.push({ kind, run, coalesce, started: false, waiters: [resolve] });
      this._pending++;
      this.stats.enqueued++;
      if (!lane.running && !lane.queued) {
        lane.queued = true;
        this._ready.push(key);
      }
      this._pump();
    });
  }

  _pump() {
    while (this._active < this.concurrency && this._ready.length > 0) {
      const key = this._ready.shift();
      const lane = this._lanes.get(key);
      if (!lane) continue;
      lane.queued = false;
      if (lane.running || lane.jobs.length === 0) continue;
      this._start(key, lane);
    }
  }

  _start(key, lane) {
    const job = lane.jobs[0];
    job.started = true;
    lane.running = true;
    this._active++;
    Promise.resolve()
      .then(() => job.run())
      .then(
        (value) => this._finish(key, lane, job, { value }),
        (error) => this._finish(key, lane, job, { error })
      );
  }

  _finish(key, lane, job, result) {
    lane.jobs.shift();
    lane.running = false;
    this._active--;
    this._pending--;
    if (result.error) this.stats.failed++;
    else this.stats.completed++;
    for (const w of job.waiters) w(result);
    if (lane.jobs.length > 0) {
      lane.queued = true;
      this._ready.push(key);
    } else {
      this._lanes.delete(key);
    }
    this._pump();
    if (this._pending === 0) {
      const waiters = this._idleWaiters;
      this._idleWaiters = [];
      for (const w of waiters) w(true);
    }
  }

  /** Bekleyen/calisan her sey bitince cozulur (kapanis ve testler icin). */
  drain(timeoutMs = 5000) {
    if (this._pending === 0) return Promise.resolve(true);
    return new Promise((resolve) => {
      const timer = setTimeout(() => resolve(false), timeoutMs);
      if (typeof timer.unref === 'function') timer.unref();
      this._idleWaiters.push((ok) => {
        clearTimeout(timer);
        resolve(ok);
      });
    });
  }

  clear() {
    for (const lane of this._lanes.values()) {
      // Calisan isi bozma; yalniz baslamamislari at.
      const keep = lane.jobs.filter((j) => j.started);
      const drop = lane.jobs.filter((j) => !j.started);
      for (const j of drop) {
        this._pending--;
        for (const w of j.waiters) w({ dropped: true });
      }
      lane.jobs = keep;
    }
  }
}

// ------------------------------------------------------------------------------
// Kopru
// ------------------------------------------------------------------------------
// `h.child_lock_requested` (021): bekleyen cocuk kilidi niyeti — uzlastiriciya EK SORGU OLMADAN iletilir (plan §5d-3).
const RESOLVE_HOME_SQL =
  'SELECT h.id AS home_id, h.child_lock_requested, d.id AS device_id, d.device_uuid ' +
  'FROM homes h LEFT JOIN devices d ON d.home_id = h.id ' +
  'WHERE h.mqtt_username = $1';

const STATUS_UPDATE_SQL =
  'UPDATE devices d ' +
  'SET is_online = $2::boolean, ' +
  'last_seen_at = CASE WHEN $2::boolean AND NOT $3::boolean THEN CURRENT_TIMESTAMP ELSE d.last_seen_at END ' +
  'FROM homes h ' +
  'WHERE d.home_id = h.id AND h.mqtt_username = $1 ' +
  'AND (d.is_online IS DISTINCT FROM $2::boolean OR ($2::boolean AND NOT $3::boolean))';

const SWEEP_OFFLINE_SQL =
  'UPDATE devices SET is_online = FALSE ' +
  'WHERE is_online = TRUE ' +
  "AND (last_seen_at IS NULL OR last_seen_at < CURRENT_TIMESTAMP - ($1::int * INTERVAL '1 second')) " +
  'RETURNING id';

class MqttBridge {
  /**
   * @param {object} [opts]  Test enjeksiyonu: { mqttLib, db, logger, now, random, env, timers }
   */
  constructor(opts = {}) {
    this._mqttLib = opts.mqttLib || null; // lazily require('mqtt')
    this._dbOverride = opts.db || null; // lazily require('./db')
    this.logger = opts.logger || console;
    this.now = opts.now || Date.now;
    this.random = opts.random || Math.random;
    this.env = opts.env || process.env;
    this.timers = opts.timers || {
      setTimeout: (...a) => setTimeout(...a),
      clearTimeout: (...a) => clearTimeout(...a),
      setInterval: (...a) => setInterval(...a),
      clearInterval: (...a) => clearInterval(...a),
    };

    this.client = null;
    this.connected = false;
    this.connectedSince = null;
    this.lastMessageAt = null;

    // Uzlastirici (plan §5d-3): `reconcile: true` (uretim tekili) -> tembel olusturulur; `reconciler`: hazir ornek
    // (test). Varsayilan KAPALI: dogrudan `new MqttBridge({...})` ile kurulan ornekler ek sorgu/zamanlayici uretmez.
    this._reconciler = opts.reconciler || null;
    this._reconcilerInjected = this._reconciler !== null; // enjekte ornek end()'de atilmaz (test sahibi yonetir)
    this._reconcileEnabled = this._reconciler !== null || opts.reconcile === true;

    // Yerlesim esitleme (WP-L, CONTRACTS §2.4b): `layoutSync: true` (uretim tekili) -> tembel olusturulur;
    // `layoutSyncer`: hazir ornek (test). Varsayilan KAPALI: dogrudan `new MqttBridge({...})` ile kurulan ornekler
    // yerlesim cikarmaz, ek sorgu uretmez. ENDPOINT_LAYOUT_SYNC tembel olusturma aninda okunur (bkz. _getLayoutSync).
    this._layoutSync = opts.layoutSyncer || null;
    this._layoutSyncInjected = this._layoutSync !== null; // enjekte ornek end()'de atilmaz (test sahibi yonetir)
    this._layoutSyncEnabled = this._layoutSync !== null || opts.layoutSync === true;
    this._layoutExtract = null; // extractReportedLayout (tembel yuklenir)
    this._layoutClosed = false; // end() kurar, init() sifirlar: kapanmis kopru servisi yeniden kurmaz / yerlesim cikarmaz

    this._backoffMs = DEFAULTS.reconnectMinMs;
    this._resubscribeTimer = null;
    this._resubscribeDelayMs = DEFAULTS.resubscribeDelayMs;
    this._sweepTimer = null;
    this._warned = new Map(); // anahtar -> son uyari zamani
    this._ackWaiters = new Map(); // ackKey(topicId, commandId) -> Set<{ finish(ok) }> (DAIRE-03)
    this._ackCount = 0;
    this._queue = new KeyedWorkQueue({
      concurrency: DEFAULTS.queueConcurrency,
      maxPending: DEFAULTS.queueMaxPending,
    });
    this.counters = {
      received: 0,
      state: 0,
      status: 0,
      retained: 0,
      ignored: 0,
      invalid: 0,
      oversize: 0,
      dbErrors: 0,
      swept: 0,
    };
  }

  // -- Yapilandirma ve yardimcilar ---------------------------------------------
  get db() {
    return this._dbOverride || (this._dbOverride = require('./db'));
  }

  get mqttLib() {
    return this._mqttLib || (this._mqttLib = require('mqtt'));
  }

  _int(name, fallback, min = 0) {
    const raw = this.env[name];
    if (raw === undefined || raw === '') return fallback;
    const n = Number.parseInt(raw, 10);
    return Number.isFinite(n) && n >= min ? n : fallback;
  }

  _warnOnce(key, message) {
    const t = this.now();
    const last = this._warned.get(key);
    if (last !== undefined && t - last < DEFAULTS.warnIntervalMs) return;
    this._warned.set(key, t);
    if (this._warned.size > 2000) {
      // Bellek korumasi: eski anahtarlari at.
      for (const [k, ts] of this._warned) {
        if (t - ts >= DEFAULTS.warnIntervalMs) this._warned.delete(k);
      }
    }
    this.logger.warn(`[MQTT-BRIDGE] ${message}`);
  }

  _readConfig() {
    const env = this.env;
    const host = env.MQTT_HOST || DEFAULTS.host;
    const port = this._int('MQTT_PORT', DEFAULTS.port, 1);
    const tls = String(env.MQTT_TLS || '').toLowerCase() === 'true';
    const username = env.MQTT_BACKEND_USER || '';
    const password = env.MQTT_BACKEND_PASS || '';
    let clientId = env.MQTT_CLIENT_ID;
    if (!clientId) {
      // Sabit ama makineye ozgu: ayni konak yeniden basladiginda ayni kalici oturumu surdurur;
      // farkli konaklar birbirinin oturumunu atmaz.
      const hostPart = String(os.hostname() || 'host').replace(/[^A-Za-z0-9_-]/g, '').slice(0, 32) || 'host';
      clientId = `ev_backend_bridge_${hostPart}`;
    }
    return {
      url: `${tls ? 'mqtts' : 'mqtt'}://${host}:${port}`,
      host,
      port,
      username,
      password,
      clientId,
      reconnectMinMs: this._int('MQTT_RECONNECT_MIN_MS', DEFAULTS.reconnectMinMs, 100),
      reconnectMaxMs: this._int('MQTT_RECONNECT_MAX_MS', DEFAULTS.reconnectMaxMs, 1000),
      publishTimeoutMs: this._int('MQTT_PUBLISH_TIMEOUT_MS', DEFAULTS.publishTimeoutMs, 200),
      offlineAfterSec: this._int('MQTT_OFFLINE_AFTER_SEC', DEFAULTS.offlineAfterSec, 30),
    };
  }

  _jitter(ms) {
    return Math.max(100, Math.round(ms * (0.8 + 0.4 * this.random())));
  }

  // -- Yasam dongusu -----------------------------------------------------------
  init() {
    if (this.client) return this.client; // idempotent
    this._layoutClosed = false; // yeniden acilis: yerlesim esitleme tembel olarak yeniden kurulabilir

    const cfg = this._readConfig();
    this._cfg = cfg;

    if (!cfg.username || !cfg.password) {
      // Fail-closed: kimlik yoksa baglanmayiz; API ayakta kalir, komutlar 502 doner.
      this.logger.error(
        '[MQTT-BRIDGE] MQTT_BACKEND_USER / MQTT_BACKEND_PASS tanimli degil. Kopru BASLATILMADI (fail-closed).'
      );
      return null;
    }

    this._backoffMs = cfg.reconnectMinMs;
    this.logger.log(`[MQTT-BRIDGE] Broker baglantisi baslatiliyor: ${cfg.url} (kullanici: ${cfg.username}, clean=false)`);

    const client = this.mqttLib.connect(cfg.url, {
      username: cfg.username,
      password: cfg.password,
      clientId: cfg.clientId,
      clean: false,
      keepalive: DEFAULTS.keepaliveSec,
      connectTimeout: DEFAULTS.connectTimeoutMs,
      reconnectPeriod: cfg.reconnectMinMs,
      // Cevrimdisiyken QoS0 yayinlari kuyruga alinmaz (komutlar zaten yalniz QoS1 + denetimli).
      queueQoSZero: false,
      // Kutuphanenin otomatik yeniden aboneligi KAPALI: abonelik her 'connect'te burada ACIKCA yapilir ve
      // broker yaniti (SUBACK) denetlenir. (Kutuphane yalniz oturum YOKSA kendi yeniden abone olur ve
      // sonucu bildirmez; ayrica ayni konuya ikinci abonelik cagrisini sessizce atlar.)
      resubscribe: false,
    });
    this.client = client;

    client.on('connect', (connack) => this._onConnect(connack));
    client.on('reconnect', () => this._onReconnect());
    client.on('close', () => this._markDisconnected('close'));
    client.on('offline', () => this._markDisconnected('offline'));
    client.on('end', () => this._markDisconnected('end'));
    client.on('error', (err) => {
      this._warnOnce('client-error', `Broker hatasi: ${err && err.message ? err.message : 'bilinmiyor'}`);
    });
    client.on('message', (topic, payload, packet) => {
      this.handleIncomingMessage(topic, payload, { retain: !!(packet && packet.retain) }).catch(() => {});
    });

    this._startSweeper();
    return client;
  }

  _onConnect(connack) {
    this.connected = true;
    this.connectedSince = this.now();
    this._backoffMs = this._cfg.reconnectMinMs;
    this._resubscribeDelayMs = DEFAULTS.resubscribeDelayMs;
    if (this.client && this.client.options) this.client.options.reconnectPeriod = this._cfg.reconnectMinMs;
    const present = connack && connack.sessionPresent ? ' (oturum surduruldu)' : '';
    this.logger.log(`[MQTT-BRIDGE] EMQX Broker baglantisi BASARILI${present}`);
    this._subscribe();
  }

  _onReconnect() {
    // Ustel geri cekilme: her yeniden deneme oncesi bir sonraki bekleme suresini ikiye katla.
    this._backoffMs = Math.min(this._cfg.reconnectMaxMs, this._backoffMs * 2);
    if (this.client && this.client.options) {
      this.client.options.reconnectPeriod = this._jitter(this._backoffMs);
    }
  }

  _markDisconnected(reason) {
    if (this.connected) {
      this.logger.warn(`[MQTT-BRIDGE] Broker baglantisi kesildi (${reason})`);
    }
    this.connected = false;
    this.connectedSince = null;
    if (this._resubscribeTimer) {
      this.timers.clearTimeout(this._resubscribeTimer);
      this._resubscribeTimer = null;
    }
  }

  _subscribe() {
    if (!this.client) return;
    this.client.subscribe([...SUBSCRIPTIONS], { qos: 1 }, (err, granted) => {
      if (err) {
        // mqtt.js, SUBACK 0x80 (reddedildi) durumunda `err` ("Subscribe error: ...") ile doner ve
        // `granted` ISTENEN listeyi tasir (qos=128 DEGIL); bu yuzden ret burada yakalanir.
        const refused = /^Subscribe error/i.test(String(err.message || ''));
        this.logger.error(
          refused
            ? `[MQTT-BRIDGE] Abonelik broker tarafindan REDDEDILDI (${err.message}). ACL/kimlik yapilandirmasini kontrol edin; yeniden denenecek.`
            : `[MQTT-BRIDGE] Konu dinleme hatasi: ${err.message}`
        );
        this._scheduleResubscribe();
        return;
      }
      const rejected = (Array.isArray(granted) ? granted : []).filter(
        (g) => !g || (typeof g.qos === 'number' && g.qos >= 128)
      );
      if (rejected.length > 0) {
        const names = rejected.map((g) => (g && g.topic) || '?').join(', ');
        this.logger.error(
          `[MQTT-BRIDGE] Abonelik broker tarafindan REDDEDILDI (${names}). ACL/kimlik yapilandirmasini kontrol edin; yeniden denenecek.`
        );
        this._scheduleResubscribe();
        return;
      }
      this._resubscribeDelayMs = DEFAULTS.resubscribeDelayMs;
      this.logger.log(`[MQTT-BRIDGE] Dinlenen konular: ${SUBSCRIPTIONS.join(', ')}`);
    });
  }

  _scheduleResubscribe() {
    if (this._resubscribeTimer || !this.connected) return;
    const delay = this._resubscribeDelayMs;
    this._resubscribeDelayMs = Math.min(5 * 60 * 1000, this._resubscribeDelayMs * 2);
    this._resubscribeTimer = this.timers.setTimeout(() => {
      this._resubscribeTimer = null;
      if (this.connected) this._subscribe();
    }, delay);
    if (this._resubscribeTimer && typeof this._resubscribeTimer.unref === 'function') this._resubscribeTimer.unref();
  }

  isConnected() {
    return this.connected === true && !!this.client && this.client.connected !== false;
  }

  getStatus() {
    const status = {
      connected: this.isConnected(),
      connected_since: this.connectedSince ? new Date(this.connectedSince).toISOString() : null,
      last_message_at: this.lastMessageAt ? new Date(this.lastMessageAt).toISOString() : null,
      queue_pending: this._queue.pending,
      counters: { ...this.counters, queue: { ...this._queue.stats } },
    };
    if (this._reconciler && typeof this._reconciler.stats === 'function') status.reconcile = this._reconciler.stats();
    if (this._layoutSync && typeof this._layoutSync.stats === 'function') {
      try {
        status.layout_sync = this._layoutSync.stats();
      } catch (_) {
        /* istatistik hatasi durum raporunu bozmasin */
      }
    }
    return status;
  }

  // -- Cevrimici olunca uzlastirma (plan §5d-3) ---------------------------------------
  /** Tembel olusturma: moduller tam yuklendikten sonra (tekil, modul yuklenirken olusturulur) ilk kullanimda. */
  _getReconciler() {
    if (this._reconciler) return this._reconciler;
    if (!this._reconcileEnabled) return null;
    try {
      const { createDeviceReconciler } = require('./services/device_reconciler');
      this._reconciler = createDeviceReconciler({
        db: this.db,
        publishCommand: (topicId, cmd) => this.publishCommand(topicId, cmd),
        // Bekleyen yerel anahtar (SERVIS-01): `ev/{t}/sys` yonetim yayini (yuk loglanmaz).
        publishSys: (topicId, obj) => this.publishSys(topicId, obj),
        isConnected: () => this.isConnected(),
        logger: this.logger,
        now: this.now,
        timers: this.timers,
        offlineAfterSec: (this._cfg && this._cfg.offlineAfterSec) || DEFAULTS.offlineAfterSec,
        QueueClass: KeyedWorkQueue,
      });
    } catch (err) {
      this._reconcileEnabled = false; // yuklenemedi: kopru etkilenmez
      this._warnOnce('reconcile-init', `Uzlastirici baslatilamadi (devre disi): ${err && err.message ? err.message : 'bilinmiyor'}`);
      return null;
    }
    return this._reconciler;
  }

  /** Hata YALITIMI: uzlastirici kopruyu/mesaj isleme hattini asla bozmaz. */
  _notifyReconciler(method, ...args) {
    try {
      const r = this._getReconciler();
      if (r && typeof r[method] === 'function') r[method](...args);
    } catch (err) {
      this._warnOnce('reconcile-notify', `Uzlastirici bildirimi hatasi: ${err && err.message ? err.message : 'bilinmiyor'}`);
    }
  }

  /**
   * Sunucu tarafinda bu ev icin yeni bir BEKLEYEN niyet yazildi (ornegin acil sifirlama yerel anahtari bekleyen yapti,
   * SERVIS-01/K1): uzlastirici evin cevrimici donem kaydini sifirlar, boylece cihazin SONRAKI canli state'i kontrol
   * planlar (pano kopruyle kisa kopukluk boyunca bagli kalmissa yeni donem hic baslamazdi). En iyi caba: ASLA firlatmaz.
   */
  requestReconcile(topicId) {
    if (!this._reconcileEnabled || !isValidTopicId(topicId)) return;
    this._notifyReconciler('rearm', topicId);
  }

  // -- Yerlesim esitleme (WP-L, CONTRACTS §2.4b) --------------------------------------
  /**
   * Tembel olusturma (`_getReconciler` deseni). Kapatma anahtari: ENDPOINT_LAYOUT_SYNC = off / 0 / false
   * (buyuk-kucuk harf duyarsiz, bosluk kirpilmis) ise servis OLUSTURULMAZ; enjekte edilen ornek bundan etkilenmez.
   * Yuklenemezse / kurulamazsa kopru etkilenmez (bir kez uyarir, yeniden denemez).
   */
  _getLayoutSync() {
    if (this._layoutClosed) return null; // end() sonrasi (gec teslim edilen mesaj) servis yeniden KURULMAZ
    if (this._layoutSync) return this._layoutSync;
    if (!this._layoutSyncEnabled) return null;
    const raw = this.env.ENDPOINT_LAYOUT_SYNC;
    const flag = raw === undefined || raw === null ? '' : String(raw).trim().toLowerCase();
    if (flag === 'off' || flag === '0' || flag === 'false') return null;
    try {
      const { createEndpointLayoutSync } = require('./services/endpoint_layout_sync');
      this._layoutSync = createEndpointLayoutSync({
        db: this.db,
        logger: this.logger,
        now: this.now,
        timers: this.timers,
        QueueClass: KeyedWorkQueue,
      });
    } catch (err) {
      this._layoutSyncEnabled = false; // yuklenemedi: kopru etkilenmez
      this._warnOnce('layout-init', `Yerlesim esitleme baslatilamadi (devre disi): ${err && err.message ? err.message : 'bilinmiyor'}`);
      return null;
    }
    return this._layoutSync;
  }

  /**
   * Dogrulanmis state'in HAM yukunden panonun bildirdigi yerlesim (yoksa / supheliyse null). Esitleme kapaliysa
   * cikarici HIC cagrilmaz. Hata YALITIMI: cikarma hatasi ana state yolunu etkilemez (yerlesim yok sayilir).
   */
  _extractLayout(obj) {
    try {
      if (this._layoutClosed || !this._getLayoutSync()) return null;
      if (!this._layoutExtract) this._layoutExtract = require('./utils/endpoint_layout').extractReportedLayout;
      return this._layoutExtract(obj);
    } catch (err) {
      // Yalniz hata turu: ileti yuk icerigi (ad) tasiyabilir.
      this._warnOnce('layout-extract', `Yerlesim cikarma hatasi: ${err && err.name ? err.name : 'bilinmiyor'}`);
      return null;
    }
  }

  /**
   * Hata YALITIMI: yerlesim esitleme kopruyu/mesaj isleme hattini asla bozmaz. Yalniz MEVCUT ornek kullanilir
   * (burada olusturulmaz): end() sonrasi biten, onceden baslamis bir state isi yeni servis kurmaz.
   * @param {'onLiveState'|'onOffline'} method
   */
  _notifyLayoutSync(method, arg) {
    try {
      const s = this._layoutSync;
      if (s && typeof s[method] === 'function') s[method](arg);
    } catch (err) {
      // Yalniz hata turu: ileti ad / kimlik tasiyabilir.
      this._warnOnce('layout-notify', `Yerlesim esitleme bildirimi hatasi: ${err && err.name ? err.name : 'bilinmiyor'}`);
    }
  }

  /**
   * Bir cihazin yerlesim esitleme onbellegini atar (genel; ornegin acil sifirlama satirlari yeniden tohumladiktan
   * sonra device_service cagirir): ayni imzali sonraki canli state RECHECK beklenmeden yeniden kontrol edilir.
   * Yalniz MEVCUT servis kullanilir (burada kurulmaz); servis yoksa no-op. En iyi caba: ASLA firlatmaz.
   */
  invalidateLayout(deviceId) {
    try {
      const s = this._layoutSync;
      if (s && typeof s.invalidate === 'function') s.invalidate(deviceId);
    } catch (err) {
      // Yalniz hata turu: ileti kimlik tasiyabilir.
      this._warnOnce('layout-invalidate', `Yerlesim onbellegi gecersizlestirilemedi: ${err && err.name ? err.name : 'bilinmiyor'}`);
    }
  }

  /** Zarif kapanis: sureci acik tutan tutamaclari birakir. */
  end({ force = false, timeoutMs = 3000 } = {}) {
    this._layoutClosed = true; // gec teslim edilen mesaj yerlesim servisini yeniden kurmasin (init() sifirlar)
    this._stopSweeper();
    if (this._resubscribeTimer) {
      this.timers.clearTimeout(this._resubscribeTimer);
      this._resubscribeTimer = null;
    }
    this._queue.clear();
    // Bekleyen cihaz onaylari: kapanista onay gelemez -> hepsi false (cagiran "uygulanmadi" sayar, DB'ye yazmaz).
    for (const set of [...this._ackWaiters.values()]) {
      for (const waiter of [...set]) waiter.finish(false);
    }
    if (this._reconciler && typeof this._reconciler.stop === 'function') {
      try {
        this._reconciler.stop();
      } catch (_) {
        /* kapanis engellenmez */
      }
      // Tembel olusturulan ornek atilir: init() yeniden cagrilirsa taze (durdurulmamis) bir uzlastirici kurulur.
      if (!this._reconcilerInjected) this._reconciler = null;
    }
    if (this._layoutSync) {
      try {
        if (typeof this._layoutSync.stop === 'function') this._layoutSync.stop();
      } catch (_) {
        /* kapanis engellenmez */
      }
      // Tembel olusturulan ornek atilir: init() yeniden cagrilirsa (yeni mesajda) taze bir servis kurulur.
      if (!this._layoutSyncInjected) this._layoutSync = null;
    }
    const client = this.client;
    this.client = null;
    this.connected = false;
    this.connectedSince = null;
    if (!client) return Promise.resolve();
    return new Promise((resolve) => {
      let done = false;
      const finish = () => {
        if (done) return;
        done = true;
        resolve();
      };
      const timer = this.timers.setTimeout(finish, timeoutMs);
      if (timer && typeof timer.unref === 'function') timer.unref();
      try {
        client.end(force, {}, () => {
          this.timers.clearTimeout(timer);
          finish();
        });
      } catch (_) {
        finish();
      }
    });
  }

  stop(opts) {
    return this.end(opts);
  }

  shutdown(opts) {
    return this.end(opts);
  }

  // -- Gelen mesajlar ----------------------------------------------------------
  /**
   * @param {string} topic
   * @param {Buffer|string} payload
   * @param {{retain?:boolean}} [meta]
   * @returns {Promise<void>} asla reddetmez; test ve kapanis icin islem bitince cozulur.
   */
  async handleIncomingMessage(topic, payload, meta = {}) {
    try {
      this.counters.received++;
      this.lastMessageAt = this.now();

      const parsed = parseIncomingTopic(topic);
      if (!parsed) {
        this.counters.ignored++;
        return;
      }
      const retain = meta && meta.retain === true;
      if (retain) this.counters.retained++;

      const size = typeof payload === 'string' ? Buffer.byteLength(payload, 'utf8') : payload ? payload.length : 0;
      if (size === 0) {
        // Bos yuk = retained temizleme (clearRetained'in kendi yankisi) -> yok say.
        this.counters.ignored++;
        return;
      }
      if (size > MAX_PAYLOAD_BYTES) {
        this.counters.oversize++;
        this._warnOnce(`oversize:${parsed.topicId}`, `Cok buyuk mesaj atildi [${parsed.topicId}/${parsed.kind}] (${size} bayt)`);
        return;
      }
      const text = typeof payload === 'string' ? payload : payload.toString('utf8');

      if (parsed.kind === 'status') {
        const online = parseStatusPayload(text);
        if (online === null) {
          this.counters.invalid++;
          this._warnOnce(`badstatus:${parsed.topicId}`, `Gecersiz status yuku atildi [${parsed.topicId}]`);
          return;
        }
        this.counters.status++;
        await this._queue.push(parsed.topicId, 'status', () => this._processStatus(parsed.topicId, online, retain));
        return;
      }

      let obj;
      try {
        obj = JSON.parse(text);
      } catch (_) {
        this.counters.invalid++;
        this._warnOnce(`badjson:${parsed.topicId}`, `Gecersiz JSON state atildi [${parsed.topicId}]`);
        return;
      }
      const check = validateStatePayload(obj);
      if (!check.ok) {
        this.counters.invalid++;
        this._warnOnce(`badstate:${parsed.topicId}`, `Gecersiz state yuku atildi [${parsed.topicId}]: ${check.reason}`);
        return;
      }
      if (check.value.skipped > 0) {
        this._warnOnce(
          `partial:${parsed.topicId}`,
          `State yukunde ${check.value.skipped} gecersiz alan/kayit atlandi [${parsed.topicId}]`
        );
      }
      this.counters.state++;
      // Cihaz onayi (DAIRE-03): yalniz CANLI state; kuyruga/birlestirmeye girmeden (ara state'teki yanki kaybolmasin).
      if (!retain && check.value.lastId && this._ackCount > 0) {
        this._settleAcks(ackKey(parsed.topicId, check.value.lastId), true);
      }
      // Yerlesim (WP-L): dogrulama BASARILI olduktan sonra HAM yukten cikarilir (esitleme kapaliysa cikarilmaz).
      // Kapanisa girer: kuyruk birlestirmesi en yeni mesajin degerini + yerlesimini birlikte kullanir.
      const layout = this._layoutSyncEnabled ? this._extractLayout(obj) : null;
      await this._queue.push(parsed.topicId, 'state', () => this._processState(parsed.topicId, check.value, retain, layout), {
        coalesce: true,
      });
    } catch (err) {
      this.counters.dbErrors++;
      this._warnOnce('handle-error', `Mesaj isleme hatasi: ${err && err.message ? err.message : 'bilinmiyor'}`);
    }
  }

  async _processStatus(topicId, online, retain) {
    try {
      await this.db.query(STATUS_UPDATE_SQL, [topicId, online, retain]);
      // Canli LWT/offline: cevrimici donem biter (retained 'offline' bayat olabilir: sayilmaz).
      if (!online && !retain && this._reconcileEnabled) this._notifyReconciler('onOffline', topicId);
      // Yerlesim esitleme (WP-L): evin cihaz onbellegi atilir; yeni kimlikle donen pano ilk canli state'te hemen
      // kontrol edilir (acil sifirlama / pano degisimi sonrasi tohum sablonu RECHECK_MS boyunca kalmasin).
      if (!online && !retain) this._notifyLayoutSync('onOffline', topicId);
    } catch (err) {
      this.counters.dbErrors++;
      this._warnOnce('db-status', `Status guncelleme hatasi [${topicId}]: ${err.message}`);
    }
  }

  /** @param {object|null} [layout]  extractReportedLayout sonucu (yerlesim esitleme kapali / yuk supheli ise null) */
  async _processState(topicId, v, retain, layout = null) {
    try {
      const res = await this.db.query(RESOLVE_HOME_SQL, [topicId]);
      const rows = (res && res.rows) || [];
      if (rows.length === 0) {
        this.counters.ignored++;
        this._warnOnce(`unknown:${topicId}`, `Bilinmeyen ev konusu icin state atildi [${topicId}]`);
        return;
      }
      const devices = rows.filter((r) => r.device_id);
      let device = null;
      if (v.uid) {
        device = devices.find((d) => String(d.device_uuid || '').toUpperCase() === v.uid) || null;
        if (!device) {
          this.counters.ignored++;
          this._warnOnce(`uid:${topicId}:${v.uid}`, `State uid bu eve ait bir cihazla eslesmiyor [${topicId}]`);
          return;
        }
      } else if (devices.length === 1) {
        device = devices[0];
      } else {
        this.counters.ignored++;
        this._warnOnce(
          `ambiguous:${topicId}`,
          devices.length === 0
            ? `Evde kayitli cihaz yok; state atildi [${topicId}]`
            : `Evde birden fazla cihaz var ve state uid icermiyor; atildi [${topicId}]`
        );
        return;
      }

      const hasChildLock = v.childLock !== null && v.childLock !== undefined;
      const deviceUpdate = buildDeviceUpdate(device.device_id, v, !retain);
      // canli: kilit deviceUpdate icinde yazilir; retained: yalnizca cevrimdisi panoda uzlastirilir
      const childLockReconcile = retain && hasChildLock ? buildChildLockReconcile(device.device_id, v.childLock) : null;
      const relayUpdate = buildRelayStateUpdate(device.device_id, v.relays);
      const shutterUpdate = buildShutterPositionUpdate(device.device_id, v.shutters);
      if (!deviceUpdate && !childLockReconcile && !relayUpdate && !shutterUpdate) return;

      await this.db.withTransaction(async (tx) => {
        let syncHome = !retain && hasChildLock;
        if (deviceUpdate) await tx.query(deviceUpdate.text, deviceUpdate.values);
        if (childLockReconcile) {
          const r = await tx.query(childLockReconcile.text, childLockReconcile.values);
          if (r && r.rowCount > 0) syncHome = true;
        }
        if (relayUpdate) await tx.query(relayUpdate.text, relayUpdate.values);
        if (shutterUpdate) await tx.query(shutterUpdate.text, shutterUpdate.values);
        if (syncHome && device.home_id) {
          const q = buildHomeChildLockSync(device.home_id);
          await tx.query(q.text, q.values);
        }
      });
      // COMMIT sonrasi (hata yalitimli): cihaz cevrimici doneminin basinda bekleyen niyet uzlastirilir (plan §5d-3).
      // Yalnizca CANLI state kanittir; retained tekrar teslim cihazin simdi canli oldugunu gostermez.
      if (!retain && this._reconcileEnabled) {
        const pending = rows.length > 0 ? rows[0].child_lock_requested : null; // evin bekleyen niyeti (RESOLVE satiri)
        this._notifyReconciler('onLiveState', {
          topicId,
          homeId: device.home_id,
          deviceId: device.device_id,
          intent: typeof pending === 'boolean' ? pending : null,
          reported: typeof v.childLock === 'boolean' ? v.childLock : null,
        });
      }
      // Yerlesim esitleme (WP-L): yalniz CANLI state + gecerli yerlesim; COMMIT sonrasi, hata yalitimli. Bayat
      // retained mesaj satir degistirmez. (Canli state'te deviceUpdate her zaman dolu: yukaridaki erken donus atlamaz.)
      if (!retain && layout) {
        this._notifyLayoutSync('onLiveState', { topicId, homeId: device.home_id, deviceId: device.device_id, layout });
      }
    } catch (err) {
      this.counters.dbErrors++;
      this._warnOnce(`db-state:${topicId}`, `State guncelleme hatasi [${topicId}]: ${err.message}`);
    }
  }

  // -- Cevrimdisi supurucu -----------------------------------------------------
  _startSweeper() {
    if (this._sweepTimer) return;
    this._sweepTimer = this.timers.setInterval(() => {
      this.sweepOffline().catch(() => {});
    }, DEFAULTS.sweepIntervalMs);
    if (this._sweepTimer && typeof this._sweepTimer.unref === 'function') this._sweepTimer.unref();
  }

  _stopSweeper() {
    if (this._sweepTimer) {
      this.timers.clearInterval(this._sweepTimer);
      this._sweepTimer = null;
    }
  }

  /**
   * `offlineAfterSec` saniyedir canli mesaj gelmeyen cihazlari cevrimdisi isaretler.
   * Baglanti yoksa veya baglanti yeni kurulduysa (kalp atislarinin gelmesi icin bekleme
   * suresi dolmadan) CALISMAZ; aksi halde broker kesintisi tum cihazlari yanlis
   * "cevrimdisi" gosterirdi.
   * @returns {Promise<number>} cevrimdisi yapilan cihaz sayisi
   */
  async sweepOffline() {
    const after = (this._cfg && this._cfg.offlineAfterSec) || DEFAULTS.offlineAfterSec;
    if (!this.isConnected() || this.connectedSince === null) return 0;
    if (this.now() - this.connectedSince < after * 1000) return 0;
    try {
      const res = await this.db.query(SWEEP_OFFLINE_SQL, [after]);
      const n = (res && (res.rowCount !== undefined ? res.rowCount : (res.rows || []).length)) || 0;
      if (n > 0) {
        this.counters.swept += n;
        this.logger.log(`[MQTT-BRIDGE] ${n} cihaz ${after} sn sessiz kaldigi icin cevrimdisi isaretlendi`);
      }
      return n;
    } catch (err) {
      this.counters.dbErrors++;
      this._warnOnce('db-sweep', `Cevrimdisi supurucu hatasi: ${err.message}`);
      return 0;
    }
  }

  // -- Yayin -------------------------------------------------------------------
  /**
   * Tek bir yayin. Baglanti yoksa reddeder (offline kuyruga ALINMAZ); PUBACK gelmezse
   * zaman asimina ugrar ve paket giden depodan cikarilir ki yeniden baglaninca bayat
   * komut tekrar gonderilmesin.
   */
  _publish(topic, payload, { qos = 1, retain = false, timeoutMs } = {}) {
    const limit = timeoutMs || (this._cfg && this._cfg.publishTimeoutMs) || DEFAULTS.publishTimeoutMs;
    return new Promise((resolve, reject) => {
      const client = this.client;
      if (!client || !this.isConnected()) {
        return reject(new BrokerUnavailableError());
      }
      let settled = false;
      let messageId = null;
      const timer = this.timers.setTimeout(() => {
        if (settled) return;
        settled = true;
        if (messageId !== null && typeof client.removeOutgoingMessage === 'function') {
          try {
            client.removeOutgoingMessage(messageId);
          } catch (_) {
            /* yut: temizlik best-effort */
          }
        }
        reject(new BrokerUnavailableError('MQTT yayını zaman aşımına uğradı; komut iletilemedi.'));
      }, limit);
      if (timer && typeof timer.unref === 'function') timer.unref();

      const onAck = (err) => {
        if (settled) return;
        settled = true;
        this.timers.clearTimeout(timer);
        if (err) {
          this._warnOnce('publish-error', `Yayin hatasi [${topic}]: ${err.message}`);
          return reject(new BrokerUnavailableError('MQTT yayını başarısız; komut iletilemedi.', err));
        }
        resolve({ topic, bytes: Buffer.byteLength(payload || '', 'utf8') });
      };

      try {
        client.publish(topic, payload, { qos, retain }, onAck);
        if (qos > 0 && typeof client.getLastMessageId === 'function') {
          // mesaj kimligi YALNIZCA bu yayina ait oldugu dogrulanirsa alinir (yanlis kaydi silmemek icin).
          const id = client.getLastMessageId();
          const entry = client.outgoing && client.outgoing[id];
          if (entry && entry.cb === onAck) messageId = id;
        }
      } catch (err) {
        if (!settled) {
          settled = true;
          this.timers.clearTimeout(timer);
          reject(new BrokerUnavailableError('MQTT yayını başarısız; komut iletilemedi.', err));
        }
      }
    });
  }

  /**
   * Cihaza komut: `ev/{topicId}/cmd` (QoS1, retain=false). `topicId` = homes.mqtt_username.
   * Cagiranlar (device_service) icin eski imza korunur: publishCommand(mqtt_username, obj).
   * @returns {Promise<{topic:string, payload:string}>}
   */
  async publishCommand(topicId, commandObj) {
    if (!isValidTopicId(topicId)) throw new TypeError('Gecersiz konu kimligi (topicId)');
    const payload = serializeCommand(commandObj);
    const topic = `ev/${topicId}/cmd`;
    await this._publish(topic, payload, { qos: 1, retain: false });
    // Yuk icerigi LOGLANMAZ.
    this.logger.log(`[MQTT-BRIDGE] Komut gonderildi [${topic}] (${Buffer.byteLength(payload, 'utf8')} bayt)`);
    return { topic, payload };
  }

  /**
   * Cihaz ONAYI bekleyicisi (DAIRE-03). Firmware basarili komutta `state.last_id`'yi komut kimligine esitler ve hemen
   * yayinlar; reddettigi komutta (or. panjur hareket halindeyken set_runtime) last_id DEGISMEZ. Bu yuzden PUBACK
   * "uygulandi" demek degildir; onay CANLI state'teki last_id yankisidir.
   *  - YAYINDAN ONCE kurulmalidir (Promise yurutucusu eszamanli kaydeder: hizli yanki kacmaz).
   *  - CANLI state last_id === commandId -> true. Retained state onay SAYILMAZ. Zaman asimi / end() / cancelAck -> false.
   *  - Asla reddetmez. Ust sinir dolduysa (ACK_MAX_WAITERS) ESZAMANLI 503 firlatir: cagiran henuz yayin yapmamistir.
   * @param {string} topicId    ev konu kimligi (homes.mqtt_username)
   * @param {string} commandId  komutun `id` alani (firmware kurali ^[A-Za-z0-9._:-]{1,24}$)
   * @param {number} timeoutMs  1..ACK_MAX_TIMEOUT_MS
   * @returns {Promise<boolean>}
   */
  expectAck(topicId, commandId, timeoutMs) {
    if (!isValidTopicId(topicId)) throw new TypeError('Gecersiz konu kimligi (topicId)');
    if (typeof commandId !== 'string' || !LAST_ID_RE.test(commandId)) throw new TypeError('Gecersiz komut kimligi (commandId)');
    if (this._ackCount >= ACK_MAX_WAITERS) {
      this._warnOnce('ack-limit', `Cihaz onayi bekleyici siniri (${ACK_MAX_WAITERS}) doldu; yeni bekleme reddedildi`);
      throw new HttpError(503, 'Sunucu şu anda çok sayıda cihaz onayı bekliyor; birkaç saniye sonra yeniden deneyin.', 'SERVICE_UNAVAILABLE');
    }
    const requested = Number.isFinite(timeoutMs) ? Math.round(timeoutMs) : ACK_MAX_TIMEOUT_MS;
    const ms = Math.min(Math.max(requested, 1), ACK_MAX_TIMEOUT_MS);
    const key = ackKey(topicId, commandId);
    return new Promise((resolve) => {
      const waiter = { done: false, timer: null, finish: null };
      waiter.finish = (ok) => {
        if (waiter.done) return;
        waiter.done = true;
        if (waiter.timer) this.timers.clearTimeout(waiter.timer);
        const set = this._ackWaiters.get(key);
        if (set) {
          set.delete(waiter);
          if (set.size === 0) this._ackWaiters.delete(key);
        }
        this._ackCount -= 1;
        resolve(ok === true);
      };
      let set = this._ackWaiters.get(key);
      if (!set) {
        set = new Set();
        this._ackWaiters.set(key, set);
      }
      set.add(waiter);
      this._ackCount += 1;
      waiter.timer = this.timers.setTimeout(() => waiter.finish(false), ms);
      if (waiter.timer && typeof waiter.timer.unref === 'function') waiter.timer.unref();
    });
  }

  /** Bekleyen onayi false ile kapatir (or. yayin basarisiz oldu). Bekleyen yoksa sessiz. */
  cancelAck(topicId, commandId) {
    this._settleAcks(ackKey(topicId, commandId), false);
  }

  /** Bekleyen cihaz onayi sayisi (izleme/test). */
  pendingAcks() {
    return this._ackCount;
  }

  _settleAcks(key, ok) {
    const set = this._ackWaiters.get(key);
    if (!set) return;
    for (const waiter of [...set]) waiter.finish(ok);
  }

  /** Yonetim komutu: `ev/{topicId}/sys` (yalnizca backend; ornek: set_local_key). Gizli deger tasiyabilir. */
  async publishSys(topicId, obj) {
    if (!isValidTopicId(topicId)) throw new TypeError('Gecersiz konu kimligi (topicId)');
    const payload = serializeCommand(obj);
    const topic = `ev/${topicId}/sys`;
    await this._publish(topic, payload, { qos: 1, retain: false });
    this.logger.log(`[MQTT-BRIDGE] Sys komutu gonderildi [${topic}]`);
    return { topic, payload };
  }

  /**
   * Genel yayin (ornegin zamanlayici). YALNIZCA `ev/{id}/cmd` ve `ev/{id}/sys` konularina
   * izin verilir (CONTRACTS §2.1). Yuk icerigi loglanmaz.
   */
  async publishToTopic(topic, payloadObj) {
    const m = typeof topic === 'string' ? COMMAND_TOPIC_RE.exec(topic) : null;
    if (!m) throw new TypeError('Izin verilmeyen MQTT konusu (yalnizca ev/{id}/cmd ve ev/{id}/sys)');
    const payload = typeof payloadObj === 'string' ? payloadObj : serializeCommand(payloadObj);
    if (Buffer.byteLength(payload, 'utf8') > MAX_COMMAND_BYTES) throw new RangeError('Komut yuku cok buyuk');
    await this._publish(topic, payload, { qos: 1, retain: false });
    this.logger.log(`[MQTT-BRIDGE] Konuya gonderildi [${topic}] (${Buffer.byteLength(payload, 'utf8')} bayt)`);
    return { topic, payload };
  }

  /**
   * Bir evin retained mesajlarini temizler (state/status/cmd/sys konularina bos, retained
   * yayin). Daire devri / acil sifirlama / pano degisiminde cagrilir. Kismen basarisizsa
   * `BrokerUnavailableError` (err.failed = basarisiz konular) firlatir.
   */
  async clearRetained(topicId) {
    if (!isValidTopicId(topicId)) throw new TypeError('Gecersiz konu kimligi (topicId)');
    if (!this.client || !this.isConnected()) throw new BrokerUnavailableError();
    const topics = ['state', 'status', 'cmd', 'sys'].map((k) => `ev/${topicId}/${k}`);
    const results = await Promise.allSettled(topics.map((t) => this._publish(t, '', { qos: 1, retain: true })));
    const failed = topics.filter((_, i) => results[i].status === 'rejected');
    if (failed.length > 0) {
      const err = new BrokerUnavailableError(`Retained temizleme kısmen başarısız (${failed.length}/${topics.length})`);
      err.failed = failed;
      throw err;
    }
    this.logger.log(`[MQTT-BRIDGE] Retained mesajlar temizlendi [ev/${topicId}/*]`);
    return { topics };
  }
}

// Uretim tekili: cevrimici olunca uzlastirma ACIK (plan §5d-3) + yerlesim esitleme ACIK (WP-L, CONTRACTS §2.4b;
// ENDPOINT_LAYOUT_SYNC=off ile kapatilir). Testlerin kendi `new MqttBridge(...)` ornekleri KAPALI.
const mqttBridge = new MqttBridge({ reconcile: true, layoutSync: true });

module.exports = mqttBridge;
module.exports.MqttBridge = MqttBridge;
module.exports.BrokerUnavailableError = BrokerUnavailableError;
module.exports.KeyedWorkQueue = KeyedWorkQueue;
module.exports.helpers = {
  isValidTopicId,
  parseIncomingTopic,
  parseStatusPayload,
  validateStatePayload,
  buildRelayStateUpdate,
  buildShutterPositionUpdate,
  buildDeviceUpdate,
  buildChildLockReconcile,
  buildHomeChildLockSync,
  serializeCommand,
};
module.exports.constants = { MAX_PAYLOAD_BYTES, MAX_COMMAND_BYTES, SUBSCRIPTIONS, DEFAULTS, ACK_MAX_WAITERS, ACK_MAX_TIMEOUT_MS };
