'use strict';

// ==============================================================================
// AHBU Akilli Ev - Cihaz cevrimici olunca UZLASTIRMA (bekleyen niyetlerin yeniden uygulanmasi)  [plan §5d-3]
// ==============================================================================
//
// SORUN: REST yalnizca NIYET kaydeder; cihaz o sirada cevrimdisiysa komut kaybolur:
//   * Cocuk kilidi: `homes.child_lock_requested` (ve pano degisimi sonrasi `child_lock.sync: pending_device_online`)
//   * Panjur sureleri: pano degisiminden sonra yeni pano varsayilan sureleriyle acilir (`runtime_sync: pending_device_online`)
//   * Yerel anahtar (SERVIS-01): acil sifirlama pano cevrimdisiyken yeni anahtari BEKLEYEN yazar
//     (`devices.local_key_pending_enc`, migration 032); panonun gercek anahtari `local_key_enc`'de kalir.
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
//   - yerel anahtar: devices.local_key_pending_enc (sifreli). Yalniz `publishSys` verildiyse uzlastirilir (kopru verir):
//     `ev/{t}/sys {cmd:'set_local_key', local_key, id}` yayinlanir; PUBACK sonrasi TEK transaction'da CAS takas
//     (local_key_enc = bekleyen, bekleyen = NULL; yalniz bekleyen hala yayinlananla ayniysa) + envanter ayni degere +
//     device_audit_logs 'local_key_rotated' (anahtarsiz). Basarisiz yayinda bekleyen KALIR (ustel bekleme / sonraki
//     cevrimici donem). Firmware sys komutunu yankilamaz: kanit PUBACK'tir. Anahtar ve sifreli deger ASLA loglanmaz.
//     Cok panolu evde atlanir (ev konusu tum panolara gider: diger panonun anahtari da degisirdi).
//
// Guvenlik yapilandirmasi kuyrugu (Faz 2 F2.D.2; device_configs.pending): kopru cfg yetenekli panonun HER canli state'inde
//   onSafetyState cagirir; is cihaz basina sirali (`cfg:<deviceId>` anahtari, birlestirmeli) olarak services/safety_cfg_sync.js'e
//   devredilir (kuyruk bosken sorgu yok). publishSys + expectOutcome verilmezse kapalidir.
//
// Sinirlar (bilincli):
//   * Panjur uzlastirmasi YALNIZ tek panolu evde yapilir: ev konusu tum panolara gittiginden `set_runtime` ortak
//     panjur numarali saglam panonun kalibrasyonunu ezerdi. Cok panolu evde atlanir ve loglanir (isaret kalir).
//   * PUBACK = broker aldi; cihazin uyguladigini KANITLAMAZ. Cocuk kilidi icin kanit cihaz bildirimidir (dongu dogrular).
//     Panjur suresi (sko-3): komut yankisi veren panoda (caps 'intrusion'; firmware state.last_id / last_rej, ayni kapi
//     safety_cfg_sync.echoesCfgId) her set_runtime icin bekleyici YAYINDAN ONCE kurulur; isaret yalniz butun ciftler
//     ONAYLANINCA `synced` olur (ret / zaman asimi -> deneme sayilir, geri cekilme, isaret bekler). Yanki vermeyen ya da
//     caps'i bilinmeyen panoda eski davranis: tum komutlar PUBACK alinca `synced`.
//   * Surec yeniden baslayinca bellek ici deneme sayaclari sifirlanir (her cevrimici donem en cok MAX_ATTEMPTS).

const crypto = require('crypto');
const { validateCommand } = require('../utils/command_schema');

// sko-3: set_runtime onayi (panonun canli state yankisi) bekleme suresi
const RUNTIME_OUTCOME_TIMEOUT_MS = 5000;
/** Komut sonucunu (last_id / last_rej) yankilayan pano mu? safety_cfg_sync.echoesCfgId ile ayni kapi. */
function echoesCommandOutcome(caps) {
  return Array.isArray(caps) && caps.includes('intrusion');
}
const { localKeyFingerprint, isValidFingerprint } = require('../utils/local_key_fp');

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
// Faz 2 incelemesi RG-2: guvenlik yapilandirmasi kuyrugu AYRI seritte (bir is panodan yanit icin <= 10 sn bekler; ev uzlastirmasini
// tikamasin). Cihaz basina tek ucus ayrica SafetyCfgSync._busy ile.
const MAX_CONCURRENT_CFG = 4;
const MAX_PENDING_CFG = 5000;
const MAX_PENDING_CHECKS = 20000; // toplu yeniden baglanmada (broker yeniden basladi) kontrol DUSMESIN: kayit hafif (kapanis)
const NOT_CONNECTED_RETRY_MS = 15 * 1000; // koprunun brokere baglanti kopuklugunda kontrolu bu aralikla yeniden planla
const MAX_NOT_CONNECTED_RETRIES = 8; // ... en cok bu kadar (yaklasik 2 dk); sonra sonraki cevrimici doneme birak
const TRACKED_IDLE_MS = 60 * 60 * 1000; // bu kadar suredir canli state gormeyen ev kaydi bellekten atilir
const GC_INTERVAL_MS = 60 * 1000;
const LOG_THROTTLE_MS = 10 * 60 * 1000; // ayni durum icin tekrar eden bilgi/uyari satirlari
// pano-5: iz bildiren (firmware 1.3.1) panoda set_local_key yayinindan sonra state'te yeni anahtar izinin beklenecegi sure
const LOCAL_KEY_CONFIRM_MS = 30 * 1000;
const MAX_MISMATCH_KEYS = 5000; // (cihaz, iz) basina bir kez uyari: bellek siniri

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
       d.caps,
       (SELECT COUNT(*)::int FROM devices x WHERE x.home_id = h.id) AS device_count
  FROM homes h
  JOIN devices d ON d.home_id = h.id
 WHERE h.mqtt_username = $1
   AND d.config_snapshot ->> 'runtime_sync' = 'pending'
 ORDER BY d.created_at ASC, d.id`,

  // Cihazin panjur ciftleri ve sureleri (yukari/asagi satirlari ayni sureyi paylasir). YALNIZ eski panonun GERCEK
  // ciftleri: anlik goruntude (config_snapshot.endpoints) ayni kanal + cift numarasiyla panjur olan VE iki satiri da
  // hala panjur olan ciftler. Yerlesim esitlemenin actigi cift (yer tutucu sure) panonun kendi kalibrasyonunu ezmesin.
  // Sure GUNCEL satirdan (sihirbazin yeni olcumu buraya yazilir). Bozuk / dizi olmayan anlik goruntu = cift yok.
  runtimeShutters: `
SELECT e.shutter_pair_index AS pair, MAX(e.shutter_duration_sec)::int AS sec
  FROM endpoints e
  JOIN devices d ON d.id = e.device_id
 WHERE e.device_id = $1 AND e.type = 'shutter' AND e.shutter_pair_index IS NOT NULL
   AND EXISTS (
     SELECT 1
       FROM jsonb_array_elements(CASE WHEN jsonb_typeof(d.config_snapshot -> 'endpoints') = 'array'
                                      THEN d.config_snapshot -> 'endpoints' ELSE '[]'::jsonb END) s
      WHERE jsonb_typeof(s) = 'object'
        AND s ->> 'type' = 'shutter'
        AND s ->> 'channel_index' = e.channel_index::text
        AND s ->> 'shutter_pair_index' = e.shutter_pair_index::text)
 GROUP BY e.shutter_pair_index
HAVING COUNT(*) = 2
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

  // Bekleyen yerel anahtari olan cihazlar (yalnizca bu evin; SERVIS-01). Deger SIFRELIDIR (yalniz yayinda cozulur).
  // key_fp (pano-5, migration 037): panonun canli state'te bildirdigi anahtar izi; NULL = eski firmware (iz bildirmez).
  localKeyPending: `
SELECT h.id AS home_id,
       d.id AS device_id,
       d.device_uuid,
       d.local_key_pending_enc AS pending_enc,
       (d.is_online IS TRUE AND d.last_seen_at IS NOT NULL
         AND d.last_seen_at > CURRENT_TIMESTAMP - ($2::int * INTERVAL '1 second')) AS live,
       (SELECT COUNT(*)::int FROM devices x WHERE x.home_id = h.id) AS device_count,
       d.local_key_fp AS key_fp
  FROM homes h
  JOIN devices d ON d.home_id = h.id
 WHERE h.mqtt_username = $1
   AND d.local_key_pending_enc IS NOT NULL
 ORDER BY d.created_at ASC, d.id`,

  // Takas islemi kilit sirasi acil sifirlama / claim ile AYNI: once envanter satiri, sonra cihaz (40P01 dongusu yok).
  localKeyLockInventory: 'SELECT id FROM device_inventory WHERE device_uuid = $1 FOR UPDATE',

  // CAS takas: yalniz bekleyen anahtar hala YAYINLANANLA ayniysa (arada yeni acil sifirlama / etiket yenileme yazdiysa
  // dokunulmaz). Kanit: eski firmware'de PUBACK, iz bildiren panoda (pano-5 g) state'teki yeni anahtar izi. ONCEKI anahtar
  // SAKLANMAZ (inceleme): eski anahtari bilen kisi (cikarilan uye, biten servis oturumu) bootstrap ile geri aldiramaz.
  // Takasi kacirmis eski firmware'li panonun kurtarma yolu seri konsol RESETKEY + FACTORYINIT'tir.
  localKeySwap: `
UPDATE devices
   SET local_key_enc = local_key_pending_enc, local_key_pending_enc = NULL, local_key_pending_at = NULL
 WHERE id = $1 AND local_key_pending_enc = $2`,

  // pano-5 (g): iz karsilastirmasi icin cihazin anahtarlari (sifreli; yalniz bellekte cozulur): gecerli + bekleyen.
  localKeyRow: `
SELECT d.id AS device_id,
       d.device_uuid,
       d.home_id,
       d.local_key_enc AS current_enc,
       d.local_key_pending_enc AS pending_enc,
       (SELECT COUNT(*)::int FROM devices x WHERE x.home_id = d.home_id) AS device_count
  FROM devices d
 WHERE d.id = $1 AND d.home_id IS NOT NULL`,

  // Envanter ayni sifreli degere (sonraki sahiplenme / pano degisimi envanter anahtarini esas alir).
  localKeyInventory: 'UPDATE device_inventory SET local_key_enc = $2, updated_at = CURRENT_TIMESTAMP WHERE device_uuid = $1',

  // Denetim kaydi: anahtar / sifreli deger YAZILMAZ.
  localKeyAudit: `
INSERT INTO device_audit_logs (event, device_uuid, home_id, actor_user_id, actor_role, ip_address, details)
VALUES ('local_key_rotated', $1, $2, NULL, 'system', NULL, $3::jsonb)`,

  // pano-5: local_key_rotated / local_key_mismatch (anahtarsiz).
  localKeyAuditEvent: `
INSERT INTO device_audit_logs (event, device_uuid, home_id, actor_user_id, actor_role, ip_address, details)
VALUES ($1, $2, $3, NULL, 'system', NULL, $4::jsonb)`,
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
   * @param {(topicId:string, obj:object)=>Promise} [deps.publishSys]  `ev/{t}/sys` yayini; YOKSA yerel anahtar
   *                                                          uzlastirmasi kapali (SERVIS-01)
   * @param {{decrypt:Function, isValidLocalKey:Function}} [deps.secretBox]  varsayilan utils/secret_box
   * @param {()=>boolean} [deps.isConnected]                   false ise yayin denenmez (deneme hakki harcanmaz)
   * @param {object} [deps.logger]                             log/warn/error
   * @param {()=>number} [deps.now]                            ms
   * @param {{setTimeout:Function, clearTimeout:Function}} [deps.timers]
   * @param {number} [deps.offlineAfterSec]                    kopru ile ayni (cevrimici donem ayirimi + canlilik)
   * @param {()=>string} [deps.newCommandId]
   * @param {Function} [deps.QueueClass]                       KeyedWorkQueue (varsayilan: mqtt_bridge'den tembel)
   * @param {(ms:number)=>Promise<void>} [deps.sleep]          set_runtime araligi (varsayilan: timers ile)
   * @param {Function} [deps.expectOutcome]                    Faz 2: yapilandirma yamasi sonuc bekleyicisi (kopru)
   * @param {Function} [deps.cancelAck] @param {Function} [deps.pushInfo] @param {Function} [deps.requestConfig]
   * @param {{onLiveState:Function}} [deps.cfgSync]           hazir yapilandirma kuyrugu (test)
   */
  constructor(deps = {}) {
    if (!deps.db || typeof deps.db.query !== 'function') throw new TypeError('DeviceReconciler: db (query) zorunludur');
    if (typeof deps.publishCommand !== 'function') throw new TypeError('DeviceReconciler: publishCommand zorunludur');
    this.db = deps.db;
    this.publishCommand = deps.publishCommand;
    this.publishSys = typeof deps.publishSys === 'function' ? deps.publishSys : null;
    // sko-3: komut sonucu bekleyicisi (kopru expectOutcome) ve iptali; yoksa set_runtime icin PUBACK yeterli sayilir
    this._expectOutcome = typeof deps.expectOutcome === 'function' ? deps.expectOutcome : null;
    this._cancelAck = typeof deps.cancelAck === 'function' ? deps.cancelAck : null;
    this._secretBox = deps.secretBox || null;
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
    this._cfgQueue = new QueueClass({ concurrency: MAX_CONCURRENT_CFG, maxPending: MAX_PENDING_CFG });

    // Faz 2 F2.D.2: guvenlik yapilandirmasi kuyrugu (sys yayincisi + sonuc bekleyicisi varsa)
    this._cfgSync = deps.cfgSync || null;
    if (!this._cfgSync && this.publishSys && typeof deps.expectOutcome === 'function') {
      const { SafetyCfgSync } = require('./safety_cfg_sync');
      this._cfgSync = new SafetyCfgSync({
        db: this.db,
        publishSys: this.publishSys,
        expectOutcome: deps.expectOutcome,
        cancelAck: deps.cancelAck,
        isConnected: () => this.isConnected(),
        requestConfig: deps.requestConfig,
        pushInfo: deps.pushInfo,
        now: this.now,
        logger: this.logger,
      });
    }

    this._homes = new Map(); // topicId -> { homeId, devices:Map<deviceId,lastLiveMs>, budgets:Map, timer, touched, logs:Map }
    this._stopped = false;
    this._lastGcAt = 0;
    this._lkMismatchSeen = new Set(); // pano-5: (cihaz, iz) basina bir kez uyumsuzluk kaydi
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
      localKeyRotated: 0,
      localKeyMismatch: 0,
      errors: 0,
    };
  }

  /** Tembel: modul yuklenirken LOCAL_KEY_SECRET gerektirmez. */
  get secretBox() {
    if (!this._secretBox) this._secretBox = require('../utils/secret_box');
    return this._secretBox;
  }

  /** Tek transaction (db.withTransaction varsa); yoksa ardisik sorgu (yalniz sahte db'ler icin). */
  _inTransaction(fn) {
    if (typeof this.db.withTransaction === 'function') return this.db.withTransaction((tx) => fn((t, p) => tx.query(t, p)));
    return fn((t, p) => this.db.query(t, p));
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
      home = { homeId: homeId || null, devices: new Map(), budgets: new Map(), timer: null, touched: t, logs: new Map(), disconnectedRetries: 0, echoCheckAfter: 0, awaitingKey: new Map() };
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

  /**
   * Faz 2 F2.D.2: cfg yetenekli panonun canli state'i -> guvenlik yapilandirmasi kuyrugu. Ucuz: kuyruk bosken (bellek ici
   * onbellek) sorgu yok; is cihaz basina sirali ve birlestirmeli. ASLA firlatmaz.
   */
  onSafetyState(args = {}) {
    if (this._stopped || !this._cfgSync || !args || !args.deviceId) return;
    this._cfgQueue
      .push(`cfg:${args.deviceId}`, 'cfg', () => this._cfgSync.onLiveState(args), { coalesce: true })
      .catch(() => {});
  }

  /**
   * pano-5 (g): panonun canli state'teki yerel anahtar izi (lk_fp, firmware 1.3.1). Kopru gecerli iz icin her canli
   * state'te cagirir; `changed` (veritabanindaki iz degisti) ya da bu cihaz icin bekleyen bir onay yoksa HIC is yapilmaz
   * (ek sorgu yok). Is ev seridinde (kontrollerle sirali) calisir. ASLA firlatmaz.
   */
  onLocalKeyFp({ topicId, homeId, deviceId, fp, changed = true } = {}) {
    if (this._stopped || !this.publishSys || typeof topicId !== 'string' || !topicId || !deviceId || !isValidFingerprint(fp)) return;
    let home = this._homes.get(topicId);
    if (!home) {
      if (!changed) return;
      home = { homeId: homeId || null, devices: new Map(), budgets: new Map(), timer: null, touched: this.now(), logs: new Map(), disconnectedRetries: 0, echoCheckAfter: 0, awaitingKey: new Map() };
      this._homes.set(topicId, home);
    }
    if (homeId) home.homeId = homeId;
    if (!changed && !home.awaitingKey.has(deviceId)) return;
    this._queue
      .push(topicId, `lkfp:${deviceId}`, () => this._handleLocalKeyFp(topicId, home, deviceId, fp), { coalesce: true })
      .catch(() => {});
  }

  /** Canli `status: offline` (LWT): cevrimici donem biter; sonraki canli state yeni donemdir. */
  onOffline(topicId) {
    const home = this._homes.get(topicId);
    if (home) home.devices.clear();
  }

  /**
   * Sunucu (REST) bu ev icin yeni bir BEKLEYEN niyet yazdi (or. acil sifirlama yerel anahtari bekleyen yapti):
   * cevrimici donem kaydi sifirlanir, cihazin SONRAKI canli state'i yeni donem sayilir ve kontrol planlanir. Pano
   * kopruyle kisa kopukluk boyunca (< offlineAfterSec) bagli kaldiysa yeni donem hic baslamaz, niyet beklerdi (SERVIS-K1).
   */
  rearm(topicId) {
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
    this._cfgQueue.clear();
  }

  /** Testler / operatör: kuyruktaki isler (ev uzlastirmasi + yapilandirma seridi) bitene kadar bekler. */
  async whenIdle(timeoutMs = 5000) {
    const [a, b] = await Promise.all([this._queue.drain(timeoutMs), this._cfgQueue.drain(timeoutMs)]);
    return a && b;
  }

  /** Bir ev icin kontrolu hemen (kuyrukta, sirali) calistirir. */
  checkNow(topicId) {
    if (this._stopped) return Promise.resolve({ dropped: true });
    return this._queue.push(topicId, 'reconcile', () => this._check(topicId), { coalesce: true });
  }

  stats() {
    const out = { homes: this._homes.size, ...this.counters, queue: { ...this._queue.stats, pending: this._queue.pending } };
    out.safety_cfg_queue = { ...this._cfgQueue.stats, pending: this._cfgQueue.pending };
    if (this._cfgSync && typeof this._cfgSync.stats === 'function') out.safety_cfg = this._cfgSync.stats();
    return out;
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
      home = { homeId: null, devices: new Map(), budgets: new Map(), timer: null, touched: this.now(), logs: new Map(), disconnectedRetries: 0, echoCheckAfter: 0, awaitingKey: new Map() };
      this._homes.set(topicId, home);
    }
    // Bir turun hatasi digerini etkilemez.
    const kinds = [['child_lock', this._checkChildLock], ['runtime', this._checkRuntime], ['local_key', this._checkLocalKey]];
    for (const [kind, fn] of kinds) {
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

    // sko-3: yanki veren panoda her komut panonun ONAYIYLA tamamlanir (bekleyici yayindan ONCE kurulur)
    const confirm = this._expectOutcome !== null && echoesCommandOutcome(row.caps);
    const uid = String(row.device_uuid || '').toUpperCase();
    let ok = 0;
    let invalid = 0;
    let failure = null;
    let unconfirmed = 0;
    for (let i = 0; i < todo.length; i += 1) {
      const p = todo[i];
      const v = validateCommand({ cmd: 'set_runtime', shutter: p.pair, sec: p.sec, id: this.newCommandId() });
      if (!v.ok) {
        invalid += 1; // aralik disi sure (1..300) / gecersiz panjur numarasi: uygulanamaz, atlanir
        continue;
      }
      if (i > 0) await this._sleep(RUNTIME_SPACING_MS); // FIFO + kuyruk derinligi: ardisik yayinlari ayir
      let waiter = null;
      if (confirm) {
        try {
          waiter = Promise.resolve(this._expectOutcome(topicId, v.command.id, RUNTIME_OUTCOME_TIMEOUT_MS, { uid }));
        } catch (_) {
          waiter = null; // gecersiz hedef kimligi: onay beklenemez (eski davranis)
        }
      }
      try {
        await this.publishCommand(topicId, v.command);
        this.counters.published += 1;
      } catch (err) {
        if (waiter && this._cancelAck) {
          try {
            this._cancelAck(topicId, v.command.id);
          } catch (_) {
            /* iptal en iyi caba */
          }
        }
        failure = errorKind(err);
        this.counters.publishFailed += 1;
        break; // sirayi bozma: kalanlar sonraki denemede
      }
      if (waiter) {
        const out = await waiter.catch(() => null);
        if (out && out.ok === true) {
          done.add(p.pair);
          ok += 1;
        } else {
          unconfirmed += 1; // ret (or. cift panoda tanimli degil) ya da zaman asimi: cift tamamlanmadi
          const code = out && typeof out.rejected === 'string' && /^[A-Za-z0-9_]{1,24}$/.test(out.rejected) ? out.rejected : null;
          const why = out && out.rejected ? `reddedildi(${code || 'diger'})` : 'onay_yok';
          this._log('warn', `panjur_suresi ${tag} cihaz=${row.device_uuid} cift=${p.pair} sonuc=${why}`);
        }
      } else {
        done.add(p.pair);
        ok += 1;
      }
    }

    const complete = failure === null && unconfirmed === 0;
    if (!complete) {
      const e = this._recordAttempt(home, key, intentKey, t);
      e.donePairs = done;
      this._log('warn', `panjur_suresi ${tag} cihaz=${row.device_uuid} deneme=${e.attempts}/${MAX_ATTEMPTS} sonuc=kismi `
        + `yayinlanan=${ok}/${todo.length} hata=${failure || 'onaylanmadi'}`);
      this._schedule(topicId, home, e.nextAt - t);
      return;
    }

    // Hepsi onaylandi (yanki veren pano) / PUBACK aldi (eski pano) ya da uygulanacak panjur yok: isaret temizlenir
    const r = await this.db.query(SQL.runtimeDone, [row.device_id, row.marker_replaced_at]);
    home.budgets.delete(key);
    this.counters.runtimeSynced += 1;
    this._log('log', `panjur_suresi ${tag} cihaz=${row.device_uuid} sonuc=uygulandi yayinlanan=${ok} atlanan_gecersiz=${invalid} `
      + `${r && r.rowCount > 0 ? 'isaret_temizlendi' : 'isaret_zaten_degismis'}`);
  }

  // -- Bekleyen yerel anahtar (SERVIS-01) ----------------------------------------------
  async _checkLocalKey(topicId, home) {
    if (!this.publishSys) return; // sys yayincisi yok (eski kurulum / test): kapali, ek sorgu yok
    const res = await this.db.query(SQL.localKeyPending, [topicId, this.offlineAfterSec]);
    const rows = (res && res.rows) || [];
    if (rows.length === 0) {
      this._dropBudgets(home, 'local_key');
      return;
    }
    const t = this.now();
    for (const row of rows) {
      if (row.home_id) home.homeId = row.home_id;
      const tag = `home=${shortId(home.homeId)}`;
      if (Number(row.device_count) !== 1) {
        // Ev konusu tum panolara gider: set_local_key evdeki DIGER panonun anahtarini da degistirirdi.
        this.counters.skippedMultiDevice += 1;
        this._logOnce(home, `local_key|multi|${row.device_id}`, 'warn',
          `yerel_anahtar ${tag} sonuc=atlandi (evde ${Number(row.device_count)} pano var; ev konusu hepsine gider)`);
        continue;
      }
      if (row.live !== true) {
        this.counters.skippedOffline += 1; // cevrimdisi: yayin yok; cihaz donunce yeni donem tetikler
        continue;
      }
      try {
        await this._syncLocalKey(topicId, home, row, tag, t);
      } catch (err) {
        this.counters.errors += 1;
        this._logOnce(home, `error|local_key|${row.device_id}|${errorKind(err)}`, 'warn', `yerel_anahtar ${tag} kontrol hatasi: ${errorKind(err)}`);
      }
    }
  }

  async _syncLocalKey(topicId, home, row, tag, t) {
    const key = `local_key|${row.device_id}`;
    const intentKey = String(row.pending_enc); // yeni bekleyen anahtar = yeni niyet (butce sifirlanir); loglanmaz
    // pano-5 (g): iz bildiren panoda kanit state'teki yeni anahtar izidir (PUBACK degil). Yayindan sonra
    // LOCAL_KEY_CONFIRM_MS beklenir; onay (onLocalKeyFp) gelmezse deneme sayilir ve ustel beklemeyle yeniden yayinlanir.
    const fpCapable = isValidFingerprint(row.key_fp);
    const awaiting = home.awaitingKey.get(row.device_id);
    if (awaiting && (!fpCapable || awaiting.pendingEnc !== row.pending_enc)) home.awaitingKey.delete(row.device_id);
    else if (awaiting) {
      if (t < awaiting.until) {
        this._schedule(topicId, home, awaiting.until - t);
        return;
      }
      home.awaitingKey.delete(row.device_id);
      const e = this._recordAttempt(home, key, intentKey, t);
      this._log('warn', `yerel_anahtar ${tag} cihaz=${row.device_uuid} deneme=${e.attempts}/${MAX_ATTEMPTS} sonuc=onay_gelmedi `
        + '(state\'te yeni anahtar izi gorulmedi); bekleyen anahtar korunur');
      if (e.attempts < MAX_ATTEMPTS) this._schedule(topicId, home, e.nextAt - t);
      else {
        this.counters.exhausted += 1;
        this._logOnce(home, `local_key|exhausted|${row.device_id}`, 'warn',
          `yerel_anahtar ${tag} cihaz=${row.device_uuid} sonuc=deneme_hakki_bitti (${MAX_ATTEMPTS}/${MAX_ATTEMPTS}); bekleyen anahtar korunur`);
      }
      return;
    }
    const status = this._canAttempt(this._entry(home, key, intentKey), t);
    if (!status.ok) {
      if (status.reason === 'backoff') {
        this._schedule(topicId, home, status.waitMs);
      } else {
        this.counters.exhausted += 1;
        this._logOnce(home, `local_key|exhausted|${row.device_id}`, 'warn',
          `yerel_anahtar ${tag} cihaz=${row.device_uuid} sonuc=deneme_hakki_bitti (${MAX_ATTEMPTS}/${MAX_ATTEMPTS}); bekleyen anahtar korunur`);
      }
      return;
    }
    if (!this.isConnected()) {
      this._deferUntilConnected(topicId, home); // deneme hakki HARCANMAZ
      this._logOnce(home, 'local_key|notconnected', 'warn', `yerel_anahtar ${tag} sonuc=ertelendi (MQTT koprusu bagli degil)`);
      return;
    }
    home.disconnectedRetries = 0;

    let localKey = null;
    try {
      localKey = this.secretBox.decrypt(row.pending_enc);
    } catch (_) {
      localKey = null;
    }
    if (!localKey || !this.secretBox.isValidLocalKey(localKey)) {
      // Cozulemeyen / firmware bicimine uymayan deger panoya GONDERILMEZ; bekleyen korunur (operator incelemeli).
      this.counters.errors += 1;
      this._logOnce(home, `local_key|invalid|${row.device_id}`, 'error',
        `yerel_anahtar ${tag} cihaz=${row.device_uuid} sonuc=gecersiz_bekleyen (cozulemedi ya da bicim disi); yayin yok`);
      return;
    }

    let failure = null;
    try {
      // CONTRACTS §3b: alan adi `local_key`; kopru sys yukunu loglamaz.
      await this.publishSys(topicId, { cmd: 'set_local_key', local_key: localKey, id: this.newCommandId() });
      this.counters.published += 1;
    } catch (err) {
      failure = errorKind(err);
      this.counters.publishFailed += 1;
    }
    if (failure) {
      const e = this._recordAttempt(home, key, intentKey, t);
      this._log('warn', `yerel_anahtar ${tag} cihaz=${row.device_uuid} deneme=${e.attempts}/${MAX_ATTEMPTS} sonuc=yayin_basarisiz `
        + `hata=${failure}; bekleyen anahtar korunur`);
      this._schedule(topicId, home, e.nextAt - t);
      return;
    }

    if (fpCapable) {
      // pano-5 (g): takas YAPILMAZ; pano yeni anahtarin izini state'te bildirince onLocalKeyFp kesinlestirir.
      home.awaitingKey.set(row.device_id, { pendingEnc: row.pending_enc, until: t + LOCAL_KEY_CONFIRM_MS });
      this._schedule(topicId, home, LOCAL_KEY_CONFIRM_MS);
      this._log('log', `yerel_anahtar ${tag} cihaz=${row.device_uuid} sonuc=iletildi (state'te yeni anahtar izi bekleniyor)`);
      return;
    }

    // Eski firmware (iz yok): kanit PUBACK. CAS takas + envanter + denetim TEK transaction'da (kilit sirasi: envanter ->
    // cihaz). Onceki anahtar saklanmaz (bkz. SQL.localKeySwap).
    let swapped;
    try {
      swapped = await this._inTransaction(async (q) => {
        await q(SQL.localKeyLockInventory, [row.device_uuid]);
        const r = await q(SQL.localKeySwap, [row.device_id, row.pending_enc]);
        if (!r || !r.rowCount) return false; // bekleyen arada degisti (yeni sifirlama / etiket): dokunulmaz
        await q(SQL.localKeyInventory, [row.device_uuid, row.pending_enc]);
        await q(SQL.localKeyAudit, [row.device_uuid, row.home_id || home.homeId || null, JSON.stringify({ via: 'reconciler' })]);
        return true;
      });
    } catch (err) {
      // Pano anahtari ALDI ama kayit yazilamadi: bekleyen korunur; ustel bekleme sonra ayni anahtarla yeniden denenir.
      const e = this._recordAttempt(home, key, intentKey, t);
      this.counters.errors += 1;
      this._log('warn', `yerel_anahtar ${tag} cihaz=${row.device_uuid} sonuc=takas_yazilamadi hata=${errorKind(err)}; yeniden denenecek`);
      this._schedule(topicId, home, e.nextAt - t);
      return;
    }
    home.budgets.delete(key);
    if (swapped) this.counters.localKeyRotated += 1;
    this._log('log', `yerel_anahtar ${tag} cihaz=${row.device_uuid} sonuc=${swapped ? 'uygulandi' : 'isaret_zaten_degismis'}`);
  }

  /** Sifreli anahtarin izi (cozulemezse null). Anahtar bellekte kalir, loglanmaz. */
  _fpOf(enc, deviceUuid) {
    if (!enc) return null;
    try {
      const k = this.secretBox.decrypt(enc);
      return k ? localKeyFingerprint(k, deviceUuid) : null;
    } catch (_) {
      return null;
    }
  }

  /**
   * pano-5 (g): panonun bildirdigi iz hangi anahtara uyuyor?
   *  - bekleyen -> CAS takas kesinlesir (via:'state')
   *  - gecerli -> tutarli, is yok
   *  - hicbiri (onceki anahtar dahil) -> (cihaz, iz) basina bir kez uyari + local_key_mismatch denetimi (anahtarsiz).
   *    Onceki anahtara GERI DONUS YOKTUR (inceleme): sunucu onceki anahtari saklamaz; takasi kacirmis panonun kurtarma
   *    yolu seri konsol RESETKEY + FACTORYINIT'tir.
   */
  async _handleLocalKeyFp(topicId, home, deviceId, fp) {
    if (this._stopped) return;
    try {
      const res = await this.db.query(SQL.localKeyRow, [deviceId]);
      const row = res && res.rows && res.rows[0];
      if (!row) return;
      if (row.home_id) home.homeId = row.home_id;
      const tag = `home=${shortId(home.homeId)}`;
      const homeId = row.home_id || home.homeId || null;

      if (row.pending_enc && this._fpOf(row.pending_enc, row.device_uuid) === fp) {
        const swapped = await this._inTransaction(async (q) => {
          await q(SQL.localKeyLockInventory, [row.device_uuid]);
          const r = await q(SQL.localKeySwap, [row.device_id, row.pending_enc]);
          if (!r || !r.rowCount) return false;
          await q(SQL.localKeyInventory, [row.device_uuid, row.pending_enc]);
          await q(SQL.localKeyAuditEvent, ['local_key_rotated', row.device_uuid, homeId, JSON.stringify({ via: 'state' })]);
          return true;
        });
        home.awaitingKey.delete(deviceId);
        home.budgets.delete(`local_key|${deviceId}`);
        if (swapped) this.counters.localKeyRotated += 1;
        this._log('log', `yerel_anahtar ${tag} cihaz=${row.device_uuid} sonuc=${swapped ? 'uygulandi (pano dogruladi)' : 'isaret_zaten_degismis'}`);
        return;
      }
      if (this._fpOf(row.current_enc, row.device_uuid) === fp) return; // tutarli

      const mk = `${deviceId}|${fp}`;
      if (this._lkMismatchSeen.has(mk)) return;
      if (this._lkMismatchSeen.size >= MAX_MISMATCH_KEYS) this._lkMismatchSeen.clear();
      this._lkMismatchSeen.add(mk);
      this.counters.localKeyMismatch += 1;
      this._log('warn', `yerel_anahtar ${tag} cihaz=${row.device_uuid} sonuc=uyumsuz (panonun anahtar izi sunucudaki anahtarlarla eslesmiyor)`);
      await this.db.query(SQL.localKeyAuditEvent, ['local_key_mismatch', row.device_uuid, homeId, JSON.stringify({ via: 'state' })]);
    } catch (err) {
      this.counters.errors += 1;
      this._logOnce(home, `error|local_key_fp|${deviceId}|${errorKind(err)}`, 'warn', `yerel_anahtar izi kontrol hatasi: ${errorKind(err)}`);
    }
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
    LOCAL_KEY_CONFIRM_MS,
  }),
};
