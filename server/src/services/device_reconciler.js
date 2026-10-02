'use strict';

// ==============================================================================
// AHBU Akilli Ev - Cihaz cevrimici olunca UZLASTIRMA (bekleyen niyetlerin yeniden uygulanmasi)  [plan §5d-3]
// ==============================================================================
//
// SORUN: REST yalnizca NIYET kaydeder; cihaz o sirada cevrimdisiysa komut kaybolur:
//   * Cocuk kilidi: `homes.child_lock_requested` (ve pano degisimi sonrasi `child_lock.sync: pending_device_online`)
//   * Panjur sureleri: pano degisiminden sonra yeni pano varsayilan sureleriyle acilir (`runtime_sync: pending_device_online`)
//   Pano cevrimici olunca bu niyetler cihaza (bir kez) uygulanmali ve bekleyen isaret temizlenmelidir.
//
// TASARIM (kopru `mqtt_bridge.js` bu modulu CANLI `state` mesajlarindan sonra cagirir; bkz. onLiveState):
//   * Tetik = cihazin CEVRIMICI DONEMI baslangici: ilk canli state (surec basladiktan sonra) veya
//     `offlineAfterSec` (varsayilan 120 sn) sessizlikten sonraki ilk canli state; canli `status: offline` donemi bitirir.
//     Kararli durumdaki cihazlar icin EK SORGU YOKTUR (her kalp atisinda veritabanina gidilmez).
//   * Ikinci tetik = YANKI ESLESMESI: evin bekleyen niyeti (kopru RESOLVE satirindan, ek sorgu yok) cihazin canli
//     state'indeki degerle AYNIysa kisa bir kontrolle niyet temizlenir. Boylece REST'ten cevrimici cihaza uygulanan
//     istek de ("bekleyen niyet" olarak) kalmaz; kalsaydi, sonradan yerel/LAN'dan degistirilen kilit bir sonraki
//     cevrimici donemde eski niyetle GERI ALINIRDI. Yankilar dakikada en cok bir kontrol uretir.
//   * Karar VERITABANINDAN, taze okumayla, `SETTLE_MS` sonra verilir (firmware `cmd` aboneliginden sonraki ilk
//     1500 ms'yi yok sayar; ayrica gecici/ara state'lere tepki verilmez).
//   * IDEMPOTENT: cihazin bildirdigi durum niyetle zaten ayniysa HICBIR sey yayinlanmaz; niyet temizlenir.
//   * DONGU YOK: yayin -> state yankisi -> (ayni) niyet = uyumlu -> temizle. Yayin yalnizca cihaz durumu niyetten
//     FARKLIYKEN yapilir; cihaz basina+niyet basina en cok MAX_ATTEMPTS deneme, ustel bekleme (5, 10, 20 sn),
//     ATTEMPT_WINDOW_MS penceresi; tukenince bu cevrimici donem icin birakilir (sonraki cevrimici donemde yeniden).
//   * CEVRIMDISI cihaza yayin DENENMEZ (veritabaninda canli degil / broker bagli degil -> deneme hakki harcanmaz).
//   * Hata IZOLASYONU: her ev kendi kuyruk seridinde (KeyedWorkQueue), cocuk kilidi ve panjur uzlastirmasi ayri
//     try/catch; bir evin/cihazin hatasi digerlerini etkilemez. Yayin kopruyle ayni yoldan (publishCommand: yalniz
//     backend `ev/{t}/cmd`, QoS1, retain=false) yapilir; komutlar CONTRACTS §2.3 semasiyla dogrulanir.
//   * Her yayin sonucu gunluge yazilir; kimlik bilgisi/anahtar/konu kimligi/komut kimligi YAZILMAZ.
//
// Niyet isaretleri (mevcut kolonlar):
//   - cocuk kilidi: homes.child_lock_requested (+ _at, _by). Cihaz bildirimi niyetle esitlenince NULL'lanir
//     (bekleyen niyet yoktur; gercek durum devices/homes.child_lock_enabled'dadir).
//   - panjur sureleri: devices.config_snapshot ->> 'runtime_sync' = 'pending' (replaceBoard yazar; burada 'synced').
//     Panjur sureleri cihazin state'inde YOKTUR; bu yuzden "pending" isareti zorunludur.
//
// Sinirlar (bilincli):
//   * Panjur uzlastirmasi YALNIZ tek panolu evde yapilir: ev konusu tum panolara gittiginden `set_runtime` ortak
//     panjur numarali saglam panonun kalibrasyonunu ezerdi. Cok panolu evde atlanir ve loglanir (isaret kalir).
//   * PUBACK = broker aldi; cihazin uyguladigini KANITLAMAZ. Cocuk kilidi icin kanit cihaz bildirimidir (dongu dogrular);
//     panjur suresi icin kanit yoktur: tum komutlar PUBACK alinca isaret `synced` olur.
//   * Surec yeniden baslayinca bellek ici deneme sayaclari sifirlanir (her cevrimici donem en cok MAX_ATTEMPTS).

const crypto = require('crypto');
const { validateCommand } = require('../utils/command_schema');

// ------------------------------------------------------------------------------
// Sabitler (ortam degiskeni DEGIL; plan §5d-3)
// ------------------------------------------------------------------------------
const MAX_ATTEMPTS = 3; // cihaz + niyet basina, pencere basina en cok deneme
const ATTEMPT_WINDOW_MS = 10 * 60 * 1000; // ilk denemeden itibaren; dolunca bu cevrimici donem icin birakilir
const BACKOFF_BASE_MS = 5 * 1000; // k. denemeden sonra bekleme = BASE * 2^(k-1): 5, 10, 20 sn
const SETTLE_MS = 2 * 1000; // cevrimici olduktan sonra ilk kontrol gecikmesi (firmware cmd'den sonra ilk 1500 ms yok sayar)
const RUNTIME_SPACING_MS = 150; // ardisik set_runtime yayinlari arasi (firmware komut kuyrugu 24 derinlik, FIFO)
const INTENT_MAX_AGE_SEC = 7 * 24 * 3600; // bu kadar eski niyet uygulanmaz, temizlenir (yerel/LAN degisikligini ezmesin)
const ECHO_CHECK_MIN_INTERVAL_MS = 60 * 1000; // niyetle UYUSAN canli state'ler icin en sik temizleme kontrolu (ev basina)
const ECHO_BLOCKED_BACKOFF_MS = 10 * 60 * 1000; // uyum var ama baska (cevrimdisi) cihaz uyumsuz: bu kadar sure tekrar bakma
const RUNTIME_MARKER_MAX_AGE_MS = 14 * 24 * 3600 * 1000;
const MAX_CONCURRENT_HOMES = 2; // es zamanli uzlastirilan ev sayisi
const MAX_PENDING_CHECKS = 20000; // toplu yeniden baglanmada (broker yeniden basladi) kontrol DUSMESIN: kayit hafif (kapanis)
const NOT_CONNECTED_RETRY_MS = 15 * 1000; // koprunun brokere baglanti kopuklugunda kontrolu bu aralikla yeniden planla
const MAX_NOT_CONNECTED_RETRIES = 8; // ... en cok bu kadar (yaklasik 2 dk); sonra sonraki cevrimici doneme birak
const TRACKED_IDLE_MS = 60 * 60 * 1000; // bu kadar suredir canli state gormeyen ev kaydi bellekten atilir
const GC_INTERVAL_MS = 60 * 1000;
const LOG_THROTTLE_MS = 10 * 60 * 1000; // ayni durum icin tekrar eden bilgi/uyari satirlari

// ------------------------------------------------------------------------------
// SQL (tek noktada; testler esitlikle eslestirir). Hepsi ayri sorgu: biri hata verirse digeri etkilenmez.
// Canlilik: is_online VE last_seen_at son $2 sn icinde (kopru sessizlik esigiyle ayni).
// ------------------------------------------------------------------------------
const SQL = Object.freeze({
  // Evin niyeti + evdeki TUM cihazlarin bildirdigi kilit durumu ve canlilik (taze okuma).
  childLock: `
SELECT h.id AS home_id,
       h.child_lock_requested AS requested,
       h.child_lock_requested_at::text AS requested_at_text,
       EXTRACT(EPOCH FROM (CURRENT_TIMESTAMP - h.child_lock_requested_at))::bigint AS requested_age_sec,
       d.id AS device_id,
       d.device_uuid,
       (d.is_online IS TRUE AND d.last_seen_at IS NOT NULL
         AND d.last_seen_at > CURRENT_TIMESTAMP - ($2::int * INTERVAL '1 second')) AS live,
       COALESCE(d.child_lock_enabled, FALSE) AS child_lock_enabled
  FROM homes h
  LEFT JOIN devices d ON d.home_id = h.id
 WHERE h.mqtt_username = $1
 ORDER BY d.created_at ASC NULLS LAST, d.id`,

  // Niyet karsilandi: tum cihazlar istenen degeri bildiriyor. Yaris korumasi: niyet/zaman damgasi hala ayni (REST arada
  // yeni istek yazdiysa DOKUNULMAZ); zaman damgasi METIN olarak karsilastirilir (mikrosaniye hassasiyeti korunur).
  clearSatisfied: `
UPDATE homes
   SET child_lock_requested = NULL, child_lock_requested_at = NULL, child_lock_requested_by = NULL
 WHERE id = $1
   AND child_lock_requested = $2
   AND child_lock_requested_at::text IS NOT DISTINCT FROM $3
   AND NOT EXISTS (SELECT 1 FROM devices d WHERE d.home_id = homes.id
                    AND COALESCE(d.child_lock_enabled, FALSE) IS DISTINCT FROM $2)`,

  // Bayat niyet: cihaz durumuna bakilmaksizin temizlenir (ayni yaris korumasi).
  clearExpired: `
UPDATE homes
   SET child_lock_requested = NULL, child_lock_requested_at = NULL, child_lock_requested_by = NULL
 WHERE id = $1
   AND child_lock_requested = $2
   AND child_lock_requested_at::text IS NOT DISTINCT FROM $3`,

  // Bekleyen panjur suresi isareti olan cihazlar (yalnizca bu evin).
  runtimePending: `
SELECT h.id AS home_id,
       d.id AS device_id,
       d.device_uuid,
       (d.is_online IS TRUE AND d.last_seen_at IS NOT NULL
         AND d.last_seen_at > CURRENT_TIMESTAMP - ($2::int * INTERVAL '1 second')) AS live,
       d.config_snapshot ->> 'home_id' AS marker_home_id,
       d.config_snapshot ->> 'replaced_at' AS marker_replaced_at,
       (SELECT COUNT(*)::int FROM devices x WHERE x.home_id = h.id) AS device_count
  FROM homes h
  JOIN devices d ON d.home_id = h.id
 WHERE h.mqtt_username = $1
   AND d.config_snapshot ->> 'runtime_sync' = 'pending'
 ORDER BY d.created_at ASC, d.id`,

  // Cihazin panjur ciftleri ve sureleri (yukari/asagi satirlari ayni sureyi paylasir).
  runtimeShutters: `
SELECT e.shutter_pair_index AS pair, MAX(e.shutter_duration_sec)::int AS sec
  FROM endpoints e
 WHERE e.device_id = $1 AND e.type = 'shutter' AND e.shutter_pair_index IS NOT NULL
 GROUP BY e.shutter_pair_index
 ORDER BY e.shutter_pair_index`,

  // Isaret: pending -> synced. Yalniz hala AYNI isaretse (replaced_at ayni): yeni bir pano degisimi isareti yeniden
  // kurduysa dokunmaz.
  runtimeDone: `
UPDATE devices
   SET config_snapshot = jsonb_set(jsonb_set(config_snapshot, '{runtime_sync}', '"synced"'::jsonb),
                                   '{runtime_synced_at}', to_jsonb(CURRENT_TIMESTAMP))
 WHERE id = $1
   AND config_snapshot ->> 'runtime_sync' = 'pending'
   AND config_snapshot ->> 'replaced_at' IS NOT DISTINCT FROM $2`,
});

// ------------------------------------------------------------------------------
// Yardimcilar
// ------------------------------------------------------------------------------
function defaultCommandId() {
  // 12 karakter [A-Za-z0-9_-]: firmware `id` kurali ^[A-Za-z0-9._:-]{1,24}$ ile uyumlu; HER yayin yeni kimlik alir
  // (cihaz tekrar gelen ayni kimligi YOK SAYAR).
  return crypto.randomBytes(9).toString('base64url');
}

function shortId(value) {
  return String(value || '-').slice(0, 8);
}

function errorKind(err) {
  const code = err && typeof err.code === 'string' && /^[A-Za-z0-9_]{1,40}$/.test(err.code) ? err.code : null;
  return code || (err && typeof err.name === 'string' && /^[A-Za-z0-9_$]{1,40}$/.test(err.name) ? err.name : 'Error');
}

function backoffMs(attempts) {
  return BACKOFF_BASE_MS * 2 ** Math.max(0, attempts - 1);
}

// ------------------------------------------------------------------------------
// Uzlastirici
// ------------------------------------------------------------------------------
class DeviceReconciler {
  /**
   * @param {object} deps
   * @param {{query:Function}} deps.db                         (zorunlu)
   * @param {(topicId:string, cmd:object)=>Promise} deps.publishCommand  kopru yayin yolu (zorunlu)
   * @param {()=>boolean} [deps.isConnected]                   false ise yayin denenmez (deneme hakki harcanmaz)
   * @param {object} [deps.logger]                             log/warn/error
   * @param {()=>number} [deps.now]                            ms
   * @param {{setTimeout:Function, clearTimeout:Function}} [deps.timers]
   * @param {number} [deps.offlineAfterSec]                    kopru ile ayni (cevrimici donem ayirimi + canlilik)
   * @param {()=>string} [deps.newCommandId]
   * @param {Function} [deps.QueueClass]                       KeyedWorkQueue (varsayilan: mqtt_bridge'den tembel)
   * @param {(ms:number)=>Promise<void>} [deps.sleep]          set_runtime araligi (varsayilan: timers ile)
   */
  constructor(deps = {}) {
    if (!deps.db || typeof deps.db.query !== 'function') throw new TypeError('DeviceReconciler: db (query) zorunludur');
    if (typeof deps.publishCommand !== 'function') throw new TypeError('DeviceReconciler: publishCommand zorunludur');
    this.db = deps.db;
    this.publishCommand = deps.publishCommand;
    this.isConnected = typeof deps.isConnected === 'function' ? deps.isConnected : () => true;
    this.logger = deps.logger || console;
    this.now = typeof deps.now === 'function' ? deps.now : Date.now;
    this.timers = deps.timers || {
      setTimeout: (...a) => setTimeout(...a),
      clearTimeout: (...a) => clearTimeout(...a),
    };
    this.offlineAfterSec = Number.isInteger(deps.offlineAfterSec) && deps.offlineAfterSec >= 30 ? deps.offlineAfterSec : 120;
    this.gapMs = this.offlineAfterSec * 1000;
    this.newCommandId = typeof deps.newCommandId === 'function' ? deps.newCommandId : defaultCommandId;
    this._sleep = typeof deps.sleep === 'function'
      ? deps.sleep
      : (ms) => new Promise((resolve) => {
        const h = this.timers.setTimeout(resolve, ms);
        if (h && typeof h.unref === 'function') h.unref();
      });

    const QueueClass = deps.QueueClass || require('../mqtt_bridge').KeyedWorkQueue;
    this._queue = new QueueClass({ concurrency: MAX_CONCURRENT_HOMES, maxPending: MAX_PENDING_CHECKS });

    this._homes = new Map(); // topicId -> { homeId, devices:Map<deviceId,lastLiveMs>, budgets:Map, timer, touched, logs:Map }
    this._stopped = false;
    this._lastGcAt = 0;
    this.counters = {
      checks: 0,
      published: 0,
      publishFailed: 0,
      satisfied: 0,
      expired: 0,
      exhausted: 0,
      skippedOffline: 0,
      skippedMultiDevice: 0,
      skippedNotConnected: 0,
      runtimeSynced: 0,
      errors: 0,
    };
  }

  // -- Gunluk -------------------------------------------------------------------
  _log(level, message) {
    const fn = this.logger && (this.logger[level] || this.logger.log);
    if (typeof fn !== 'function') return;
    try {
      fn.call(this.logger, `[RECONCILE] ${message}`);
    } catch (_) {
      /* gunluk hatasi uzlastirmayi bozmasin */
    }
  }

  /** Ayni (ev, anahtar) icin LOG_THROTTLE_MS icinde tek satir. */
  _logOnce(home, key, level, message) {
    const t = this.now();
    const last = home.logs.get(key);
    if (last !== undefined && t - last < LOG_THROTTLE_MS) return;
    home.logs.set(key, t);
    if (home.logs.size > 50) {
      for (const [k, ts] of home.logs) if (t - ts >= LOG_THROTTLE_MS) home.logs.delete(k);
    }
    this._log(level, message);
  }

  // -- Kopru tarafi giris noktalari -------------------------------------------------
  /**
   * Canli (retained OLMAYAN) state islendikten ve COMMIT edildikten sonra kopru cagirir. Ucuz: yalniz bellek.
   *  - Cevrimici donemin ilk state'inde (ilk gorulme / `gapMs` sessizlik sonrasi) bir kontrol planlar.
   *  - `intent` (evin bekleyen cocuk kilidi niyeti, yoksa null) cihazin bildirdigi `reported` degerle AYNIysa
   *    (yanki) niyeti temizlemek icin kisa bir kontrol planlar (ev basina en sik `ECHO_CHECK_MIN_INTERVAL_MS`).
   */
  onLiveState({ topicId, homeId, deviceId, intent = null, reported = null } = {}) {
    if (this._stopped || typeof topicId !== 'string' || !topicId || !deviceId) return;
    const t = this.now();
    let home = this._homes.get(topicId);
    if (!home) {
      home = { homeId: homeId || null, devices: new Map(), budgets: new Map(), timer: null, touched: t, logs: new Map(), disconnectedRetries: 0, echoCheckAfter: 0 };
      this._homes.set(topicId, home);
    }
    home.touched = t;
    if (homeId) home.homeId = homeId;
    const prev = home.devices.get(deviceId);
    home.devices.set(deviceId, t);
    if (prev === undefined || t - prev >= this.gapMs) {
      this._resetBudgets(home, deviceId); // yeni cevrimici donem: taze deneme hakki
      home.disconnectedRetries = 0;
      this._schedule(topicId, home, SETTLE_MS);
    } else if (typeof intent === 'boolean' && intent === reported && t >= home.echoCheckAfter) {
      // yanki: bekleyen niyet cihazin bildirdigiyle ayni -> temizle (yayin gerekmez)
      home.echoCheckAfter = t + ECHO_CHECK_MIN_INTERVAL_MS;
      this._schedule(topicId, home, SETTLE_MS);
    }
    if (t - this._lastGcAt >= GC_INTERVAL_MS) this._gc(t);
  }

  /** Canli `status: offline` (LWT): cevrimici donem biter; sonraki canli state yeni donemdir. */
  onOffline(topicId) {
    const home = this._homes.get(topicId);
    if (home) home.devices.clear();
  }

  /** Bekleyen zamanlayicilari iptal eder, kuyrugu bosaltir (kopru kapanisi). */
  stop() {
    this._stopped = true;
    for (const home of this._homes.values()) {
      if (home.timer) this.timers.clearTimeout(home.timer.handle);
      home.timer = null;
    }
    this._queue.clear();
  }

  /** Testler / operatör: kuyruktaki isler bitene kadar bekler. */
  whenIdle(timeoutMs = 5000) {
    return this._queue.drain(timeoutMs);
  }

  /** Bir ev icin kontrolu hemen (kuyrukta, sirali) calistirir. */
  checkNow(topicId) {
    if (this._stopped) return Promise.resolve({ dropped: true });
    return this._queue.push(topicId, 'reconcile', () => this._check(topicId), { coalesce: true });
  }

  stats() {
    return { homes: this._homes.size, ...this.counters, queue: { ...this._queue.stats, pending: this._queue.pending } };
  }

  // -- Planlama -------------------------------------------------------------------
  _schedule(topicId, home, delayMs) {
    if (this._stopped) return;
    const delay = Math.max(1, Math.round(delayMs));
    const at = this.now() + delay;
    if (home.timer && home.timer.at <= at) return; // daha erken (ya da ayni) bir kontrol zaten planli
    if (home.timer) this.timers.clearTimeout(home.timer.handle);
    const handle = this.timers.setTimeout(() => {
      home.timer = null;
      this.checkNow(topicId).catch(() => {});
    }, delay);
    if (handle && typeof handle.unref === 'function') handle.unref();
    home.timer = { handle, at };
  }

  /**
   * Kopru brokere bagli degilken (kisa kopukluk) yayin denenmez ve deneme hakki HARCANMAZ; kontrol sinirli sayida
   * yeniden planlanir (aksi halde kopukluk sirasinda dusen kontrol, sonraki cevrimici doneme kadar kaybolurdu).
   */
  _deferUntilConnected(topicId, home) {
    this.counters.skippedNotConnected += 1;
    if (home.disconnectedRetries < MAX_NOT_CONNECTED_RETRIES) {
      home.disconnectedRetries += 1;
      this._schedule(topicId, home, NOT_CONNECTED_RETRY_MS);
    }
  }

  _resetBudgets(home, deviceId) {
    for (const key of [...home.budgets.keys()]) {
      if (key.endsWith(`|${deviceId}`)) home.budgets.delete(key);
    }
  }

  _dropBudgets(home, kind, deviceId = null) {
    for (const key of [...home.budgets.keys()]) {
      if (key.startsWith(`${kind}|`) && (deviceId === null || key.endsWith(`|${deviceId}`))) home.budgets.delete(key);
    }
  }

  _gc(t) {
    this._lastGcAt = t;
    for (const [topicId, home] of this._homes) {
      for (const [deviceId, ts] of home.devices) {
        if (t - ts >= TRACKED_IDLE_MS) home.devices.delete(deviceId);
      }
      if (home.devices.size === 0 && home.budgets.size === 0 && !home.timer && t - home.touched >= TRACKED_IDLE_MS) {
        this._homes.delete(topicId);
      }
    }
  }

  // -- Deneme butcesi ---------------------------------------------------------------
  /** Niyet degisti (anahtar farkli) ise butce sifirlanir. */
  _entry(home, key, intentKey) {
    const e = home.budgets.get(key);
    if (e && e.intentKey !== intentKey) {
      home.budgets.delete(key);
      return undefined;
    }
    return e;
  }

  _canAttempt(entry, t) {
    if (!entry) return { ok: true };
    if (entry.attempts >= MAX_ATTEMPTS) return { ok: false, reason: 'exhausted' };
    if (t - entry.windowStart >= ATTEMPT_WINDOW_MS) return { ok: false, reason: 'exhausted' };
    if (t < entry.nextAt) return { ok: false, reason: 'backoff', waitMs: entry.nextAt - t };
    return { ok: true };
  }

  _recordAttempt(home, key, intentKey, t) {
    let e = home.budgets.get(key);
    if (!e || e.intentKey !== intentKey) {
      e = { intentKey, attempts: 0, windowStart: t, nextAt: 0, donePairs: new Set() };
      home.budgets.set(key, e);
    }
    e.attempts += 1;
    e.nextAt = t + backoffMs(e.attempts);
    return e;
  }

  // -- Kontrol (ev basina, sirali) ----------------------------------------------------
  async _check(topicId) {
    if (this._stopped) return;
    this.counters.checks += 1;
    let home = this._homes.get(topicId);
    if (!home) {
      home = { homeId: null, devices: new Map(), budgets: new Map(), timer: null, touched: this.now(), logs: new Map(), disconnectedRetries: 0, echoCheckAfter: 0 };
      this._homes.set(topicId, home);
    }
    // Bir turun hatasi digerini etkilemez.
    for (const [kind, fn] of [['child_lock', this._checkChildLock], ['runtime', this._checkRuntime]]) {
      try {
        await fn.call(this, topicId, home);
      } catch (err) {
        this.counters.errors += 1;
        this._logOnce(home, `error|${kind}|${errorKind(err)}`, 'warn',
          `${kind} kontrol hatasi home=${shortId(home.homeId)}: ${errorKind(err)}`);
      }
    }
  }

  async _checkChildLock(topicId, home) {
    const res = await this.db.query(SQL.childLock, [topicId, this.offlineAfterSec]);
    const rows = (res && res.rows) || [];
    if (rows.length === 0) return;
    const first = rows[0];
    if (first.home_id) home.homeId = first.home_id;

    const requested = first.requested;
    if (requested !== true && requested !== false) {
      this._dropBudgets(home, 'child_lock'); // bekleyen niyet yok
      return;
    }
    const requestedAtText = first.requested_at_text || null;
    const tag = `home=${shortId(home.homeId)}`;
    const wanted = requested ? 'kilitli' : 'kilitsiz';

    // Bayat niyet: LAN/yerel degisikligi ezmesin; cihaz durumuna bakmadan temizle.
    const age = Number(first.requested_age_sec);
    if (Number.isFinite(age) && age > INTENT_MAX_AGE_SEC) {
      const r = await this.db.query(SQL.clearExpired, [first.home_id, requested, requestedAtText]);
      this._dropBudgets(home, 'child_lock');
      if (r && r.rowCount > 0) {
        this.counters.expired += 1;
        this._log('log', `cocuk_kilidi ${tag} sonuc=niyet_bayat (>${Math.round(INTENT_MAX_AGE_SEC / 86400)} gun) temizlendi; uygulanmadi`);
      }
      return;
    }

    const devices = rows.filter((r) => r.device_id);
    if (devices.length === 0) return;
    const mismatch = devices.filter((d) => d.child_lock_enabled !== requested);

    // 1) Hepsi niyetle ayni -> IDEMPOTENT: hicbir sey yayinlanmaz; niyet temizlenir.
    if (mismatch.length === 0) {
      const r = await this.db.query(SQL.clearSatisfied, [first.home_id, requested, requestedAtText]);
      this._dropBudgets(home, 'child_lock');
      this.counters.satisfied += 1;
      if (r && r.rowCount > 0) this._log('log', `cocuk_kilidi ${tag} sonuc=uyumlu istenen=${wanted}; bekleyen niyet temizlendi`);
      return;
    }

    // 2) Fark yalniz cevrimdisi cihazlarda -> yayin DENENMEZ (cihaz donunce kendi cevrimici donemi tetikler).
    const liveMismatch = mismatch.filter((d) => d.live === true);
    if (liveMismatch.length === 0) {
      home.echoCheckAfter = this.now() + ECHO_BLOCKED_BACKOFF_MS; // yankilar bu sure boyunca yeni kontrol uretmesin
      this.counters.skippedOffline += 1;
      this._logOnce(home, 'child_lock|offline', 'log', `cocuk_kilidi ${tag} sonuc=beklemede (fark yalniz cevrimdisi cihazlarda; yayin yok)`);
      return;
    }

    // 3) Deneme butcesi (cihaz + niyet basina)
    const t = this.now();
    const intentKey = `${requested}|${requestedAtText || ''}`;
    const statuses = liveMismatch.map((d) => this._canAttempt(this._entry(home, `child_lock|${d.device_id}`, intentKey), t));
    if (!statuses.some((s) => s.ok)) {
      const waits = statuses.filter((s) => s.reason === 'backoff').map((s) => s.waitMs);
      if (waits.length > 0) {
        this._schedule(topicId, home, Math.min(...waits)); // bekleme dolunca yeniden dogrula (yanki gelmis olabilir)
        return;
      }
      this.counters.exhausted += 1;
      this._logOnce(home, 'child_lock|exhausted', 'warn',
        `cocuk_kilidi ${tag} sonuc=deneme_hakki_bitti (${MAX_ATTEMPTS}/${MAX_ATTEMPTS}); istenen=${wanted}; niyet bekliyor, `
        + 'sonraki cevrimici donemde yeniden denenecek');
      return;
    }

    // 4) Yayin (yalniz backend `cmd`; CONTRACTS §2.3: {cmd:'set_child_lock', enabled, id})
    if (!this.isConnected()) {
      this._deferUntilConnected(topicId, home); // deneme hakki HARCANMAZ
      this._logOnce(home, 'child_lock|notconnected', 'warn', `cocuk_kilidi ${tag} sonuc=ertelendi (MQTT koprusu bagli degil)`);
      return;
    }
    home.disconnectedRetries = 0;
    const v = validateCommand({ cmd: 'set_child_lock', enabled: requested, id: this.newCommandId() });
    if (!v.ok) {
      this._log('error', `cocuk_kilidi ${tag} sonuc=gecersiz_komut`);
      return;
    }
    let result = 'yayinlandi';
    let failure = null;
    try {
      await this.publishCommand(topicId, v.command);
      this.counters.published += 1;
    } catch (err) {
      result = 'yayin_basarisiz';
      failure = errorKind(err);
      this.counters.publishFailed += 1;
    }
    const entries = liveMismatch.map((d) => this._recordAttempt(home, `child_lock|${d.device_id}`, intentKey, t));
    const attempts = Math.max(...entries.map((e) => e.attempts));
    this._log(result === 'yayinlandi' ? 'log' : 'warn',
      `cocuk_kilidi ${tag} cihaz=${liveMismatch.map((d) => d.device_uuid).join(',')} deneme=${attempts}/${MAX_ATTEMPTS} `
      + `sonuc=${result}${failure ? ` hata=${failure}` : ''} istenen=${wanted}`);
    // Yanki/uyum dogrulamasi (ve gerekirse sonraki deneme) icin ustel bekleme sonrasi yeniden kontrol
    this._schedule(topicId, home, Math.min(...entries.map((e) => e.nextAt - t)));
  }

  async _checkRuntime(topicId, home) {
    const res = await this.db.query(SQL.runtimePending, [topicId, this.offlineAfterSec]);
    const rows = (res && res.rows) || [];
    if (rows.length === 0) {
      this._dropBudgets(home, 'runtime');
      return;
    }
    const t = this.now();
    for (const row of rows) {
      if (row.home_id) home.homeId = row.home_id;
      const tag = `home=${shortId(home.homeId)}`;
      // Isaret bu eve ve yakin zamana ait olmali (cihaz baska eve tasindiysa / eski isaretse uygulanmaz).
      const replacedAtMs = Date.parse(row.marker_replaced_at || '');
      if (row.marker_home_id !== row.home_id || !Number.isFinite(replacedAtMs) || t - replacedAtMs > RUNTIME_MARKER_MAX_AGE_MS) {
        this._logOnce(home, `runtime|stale|${row.device_id}`, 'warn', `panjur_suresi ${tag} sonuc=isaret_gecersiz (baska ev / bayat); uygulanmadi`);
        continue;
      }
      if (Number(row.device_count) !== 1) {
        // Ev konusu tum panolara gider: ortak panjur numarali saglam panonun kalibrasyonu ezilirdi.
        this.counters.skippedMultiDevice += 1;
        this._logOnce(home, `runtime|multi|${row.device_id}`, 'warn',
          `panjur_suresi ${tag} sonuc=atlandi (evde ${Number(row.device_count)} pano var; ev konusu hepsine gider). Elle kalibre edin`);
        continue;
      }
      if (row.live !== true) {
        this.counters.skippedOffline += 1; // cevrimdisi: yayin yok; cihaz donunce yeni donem tetikler
        continue;
      }
      try {
        await this._syncRuntime(topicId, home, row, tag, t);
      } catch (err) {
        // bir cihazin hatasi digerini etkilemez (tek panolu evde tek satir; yine de yalitilir)
        this.counters.errors += 1;
        this._logOnce(home, `error|runtime|${row.device_id}|${errorKind(err)}`, 'warn', `panjur_suresi ${tag} kontrol hatasi: ${errorKind(err)}`);
      }
    }
  }

  async _syncRuntime(topicId, home, row, tag, t) {
    const key = `runtime|${row.device_id}`;
    const intentKey = row.marker_replaced_at;
    const status = this._canAttempt(this._entry(home, key, intentKey), t);
    if (!status.ok) {
      if (status.reason === 'backoff') {
        this._schedule(topicId, home, status.waitMs);
      } else {
        this.counters.exhausted += 1;
        this._logOnce(home, `runtime|exhausted|${row.device_id}`, 'warn',
          `panjur_suresi ${tag} cihaz=${row.device_uuid} sonuc=deneme_hakki_bitti (${MAX_ATTEMPTS}/${MAX_ATTEMPTS}); isaret bekliyor`);
      }
      return;
    }

    const sh = await this.db.query(SQL.runtimeShutters, [row.device_id]);
    const pairs = ((sh && sh.rows) || [])
      .map((r) => ({ pair: Number(r.pair), sec: Number(r.sec) }))
      .filter((p) => Number.isInteger(p.pair) && Number.isInteger(p.sec));
    const entryBefore = this._entry(home, key, intentKey);
    const done = entryBefore ? entryBefore.donePairs : new Set();
    const todo = pairs.filter((p) => !done.has(p.pair));

    if (!this.isConnected() && todo.length > 0) {
      this._deferUntilConnected(topicId, home); // deneme hakki HARCANMAZ
      this._logOnce(home, 'runtime|notconnected', 'warn', `panjur_suresi ${tag} sonuc=ertelendi (MQTT koprusu bagli degil)`);
      return;
    }
    home.disconnectedRetries = 0;

    let ok = 0;
    let invalid = 0;
    let failure = null;
    for (let i = 0; i < todo.length; i += 1) {
      const p = todo[i];
      const v = validateCommand({ cmd: 'set_runtime', shutter: p.pair, sec: p.sec, id: this.newCommandId() });
      if (!v.ok) {
        invalid += 1; // aralik disi sure (1..300) / gecersiz panjur numarasi: uygulanamaz, atlanir
        continue;
      }
      if (i > 0) await this._sleep(RUNTIME_SPACING_MS); // FIFO + kuyruk derinligi: ardisik yayinlari ayir
      try {
        await this.publishCommand(topicId, v.command);
        this.counters.published += 1;
        done.add(p.pair);
        ok += 1;
      } catch (err) {
        failure = errorKind(err);
        this.counters.publishFailed += 1;
        break; // sirayi bozma: kalanlar sonraki denemede
      }
    }

    const complete = failure === null;
    if (!complete) {
      const e = this._recordAttempt(home, key, intentKey, t);
      e.donePairs = done;
      this._log('warn', `panjur_suresi ${tag} cihaz=${row.device_uuid} deneme=${e.attempts}/${MAX_ATTEMPTS} sonuc=kismi `
        + `yayinlanan=${ok}/${todo.length} hata=${failure}`);
      this._schedule(topicId, home, e.nextAt - t);
      return;
    }

    // Hepsi PUBACK aldi (ya da uygulanacak panjur yok): isaret temizlenir
    const r = await this.db.query(SQL.runtimeDone, [row.device_id, row.marker_replaced_at]);
    home.budgets.delete(key);
    this.counters.runtimeSynced += 1;
    this._log('log', `panjur_suresi ${tag} cihaz=${row.device_uuid} sonuc=uygulandi yayinlanan=${ok} atlanan_gecersiz=${invalid} `
      + `${r && r.rowCount > 0 ? 'isaret_temizlendi' : 'isaret_zaten_degismis'}`);
  }
}

function createDeviceReconciler(deps) {
  return new DeviceReconciler(deps);
}

module.exports = {
  createDeviceReconciler,
  DeviceReconciler,
  SQL,
  constants: Object.freeze({
    MAX_ATTEMPTS,
    ATTEMPT_WINDOW_MS,
    BACKOFF_BASE_MS,
    SETTLE_MS,
    RUNTIME_SPACING_MS,
    INTENT_MAX_AGE_SEC,
    RUNTIME_MARKER_MAX_AGE_MS,
    MAX_CONCURRENT_HOMES,
  }),
};
