'use strict';

// ==============================================================================
// AHBU Akilli Ev - Guvenlik alarm servisi (olay isleme, state uzlastirmasi, push)   [CONTRACTS §2.6]
// ==============================================================================
//
// Tasarim: docs/superpowers/specs/2026-10-06-guvenlik-iklim-senaryo-mimarisi-design.md §5.2.2-§5.2.4.
// Kopru (mqtt_bridge.js) bu servisi tembel kurar ve ev konusu sirasinda (ayni KeyedWorkQueue seridi) cagirir:
//   handleEvent  : ev/{t}/event (dogrulanmis; utils/safety_payload.validateEventPayload) -> TEK transaction:
//                  1) device_events (device_id, eid) tekillestirme (yinelenen -> yalniz ack)
//                  2) alarms guncellemesi (alarm_raised / valve_fault / valve_fault_cleared / alarm_silenced /
//                     alarm_cleared; sirasiz alarm_cleared -> mezar tasi, push YOK [O7])
//                  3) device_audit_logs `safety_<tur>`
//                  4) COMMIT sonrasi event_ack (pano basina 250 ms birlestirme, <= 8 eid, uid ZORUNLU)
//                  5) yeni acilan satir icin push (pending->claimed->sending->sent); acik (latched/fault) alarmda
//                     yarim kalan/basarisiz push retryStuckPushes ile yeniden denenir: EN AZ bir kez (sko-2, C12)
//   onLiveState  : CANLI state COMMIT'inden sonra; latched/fault bolge icin satiri olmayan alarmi acar
//                  (origin=state), kanitli kapanma (ayni bolge normal + mode normal + cfg rev geri gitmedi ->
//                  cleared/device_state), kanitsiz kayip (caps yok / safety yok / mode safe / rev geri -> lost +
//                  owner'a bilgi push'u) [O-9][O11]; cevrimdisi onay istegini yalniz ayni aid ile iletir [Y-9].
//                  Firmware `safety.zones[]`'a YALNIZ normal olmayan bolgeleri yazar: listede olmayan bolge NORMAL'dir
//                  (CONTRACTS §2.6; inceleme RV-1). Ayni bolgede BASKA aid ile kilit (yeni tehlike turu = yeni alarm,
//                  E2E-2) eski satiri `superseded` ile kapatir. Acik alarmi olmayan ve butun bolgeleri normal olan
//                  panoda acik alarm sorgusu her state'te yinelenmez (cihaz basina onbellek, 60 sn; RV-7).
//   handleCfgDump: cfg_dump parcalari (olay DEGIL; onaysiz) -> device_configs (eski rev yenisini ezmez).
//   requestConfig: Faz 2 F2.D - yapilandirma kopyasini tazele (force: 5 sn taban). Kopya dogrulanana kadar canli state'ler
//                  cfg_get'i dakikada en cok bir kez yeniler (eskiden dakika sinirina takilan istek bir daha yapilmiyordu).
//   Faz 2 F2.B.8 hirsiz alarmi: intrusion_alarm -> alarms kind='intrusion' (+ tek push), intrusion_cleared -> cleared /
//                  mezar tasi, arm_changed -> yalniz denetim. Bolge uzlastirmasi hirsiz satirina DOKUNMAZ; hirsiz satiri
//                  state'teki safety.arm ile ayri kuralla uzlastirilir (intrusionVerdict).
//
// Push alicilari: alarm -> owner + resident (push_service.recipientsForHome varsayilani); bilgi -> yalniz owner.
// Misafir ve servis rolleri HICBIR guvenlik push'u almaz (§7.2b-4).
//
// GUVENLIK/GIZLILIK: gunluge yalniz kisa kimlik onekleri ve sayilar yazilir; yuk, ad, jeton YAZILMAZ.
// Hata yalitimi: hicbir metot kopruye hata firlatmaz (sonuc nesnesi doner).

const crypto = require('crypto');
const { mergeCfgDumpParts } = require('../utils/safety_payload');
const { CAPABILITIES } = require('../utils/role_matrix');
const RA = require('./requester_access');

const ACK_WINDOW_MS = 250;
const MAX_ACK_EIDS = 8;
const CFG_DUMP_TTL_MS = 60 * 1000;
const CFG_DUMP_MAX_PENDING = 64;
const CFG_GET_MIN_INTERVAL_MS = 60 * 1000;
const CFG_GET_FORCE_INTERVAL_MS = 5 * 1000; // requestConfig({force}) taban araligi (Faz 2 F2.D)
const PUSH_RETRY_DELAY_MS = 5 * 1000; // basarisiz alarm push'u BIR kez yeniden denenir (gecici FCM/ag hatasi)
const ACK_REQUEST_TTL_MS = 24 * 3600 * 1000; // sko-1 (C11): cevrimdisi onay istegi en cok 24 sa bekler
const PUSH_RETRY_BATCH = 50; // sko-2 (C12): tur basina yeniden talep edilen en cok satir
// sko-2 (C12): acik (latched/fault) alarmda push EN AZ BIR KEZ teslim edilir: hic talep edilmemis (pending; ornegin
// COMMIT ile push arasinda yeniden baslatma), 2 dk'dan eski claimed/sending (surec gonderim sirasinda coktu) ve 5'ten az
// denenmis, 1 dk'dir bekleyen failed satir yeniden talep edilir (CAS). claimed/sending'te coken surec gondermis olabilir:
// yinelenen push BILINCLI kabul edilir (030 "en cok bir kez" kuralindan sapma; kacirilan gaz alarmi daha kotu).
// silenced (kullanici onayladi) ve kapali (cleared/lost) alarm yeniden denenmez. Iki push ayni updated_at'i paylasir:
// ikisi birden yarim kaldiysa once alarm push'u, ariza push'u satir 2 dk degismeden kalinca sonraki turda gider.
const PUSH_DUE =
  "status IN ('latched', 'fault') AND (push_status = 'pending' " +
  "OR (push_status IN ('claimed', 'sending') AND updated_at < CURRENT_TIMESTAMP - INTERVAL '2 minutes') " +
  "OR (push_status = 'failed' AND push_attempts < 5 AND updated_at < CURRENT_TIMESTAMP - INTERVAL '1 minute'))";
const FAULT_PUSH_DUE =
  "status = 'fault' AND (fault_push_status = 'pending' " +
  "OR (fault_push_status IN ('claimed', 'sending') AND updated_at < CURRENT_TIMESTAMP - INTERVAL '2 minutes'))";
const PUSH_ROW_COLS =
  'id, home_id, device_id, zone, kind, status, (SELECT d.device_uuid FROM devices d WHERE d.id = alarms.device_id) AS device_uuid';
const OPEN_STATUSES = Object.freeze(['latched', 'fault', 'silenced']);
const LIST_DEFAULT_LIMIT = 50;
const CLEAN_TTL_MS = 60 * 1000; // "acik alarm yok" onbellegi (onLiveState sorgusu atlanir; olay/acilis gecersiz kilar)
const CLEAN_MAX_DEVICES = 5000;
const LIST_MAX_LIMIT = 200;

const SQL = Object.freeze({
  insertEvent:
    'INSERT INTO device_events (device_id, eid, type, body) VALUES ($1, $2, $3, $4::jsonb) ' +
    'ON CONFLICT (device_id, eid) DO NOTHING RETURNING eid',
  // guvenlik-1: ayni (device_id, aid) satiri BASKA eve aitse (pano stoga donup baska eve sahiplendi, kilit suruyor)
  // satir yeni eve tasinip YENIDEN ACILIR; ayni evdeki kapali satir / mezar tasi kurali AYNEN (DO NOTHING etkisi).
  insertRaised:
    'INSERT INTO alarms (home_id, device_id, aid, zone, kind, status, origin, sources, raised_at, device_epoch) ' +
    "VALUES ($1, $2, $3, $4, $5, 'latched', $6, $7::jsonb, CURRENT_TIMESTAMP, $8) " +
    'ON CONFLICT (device_id, aid) DO UPDATE SET home_id = EXCLUDED.home_id, zone = EXCLUDED.zone, kind = EXCLUDED.kind, ' +
    "status = 'latched', origin = EXCLUDED.origin, sources = EXCLUDED.sources, raised_at = CURRENT_TIMESTAMP, " +
    'device_epoch = EXCLUDED.device_epoch, acked_by = NULL, acked_at = NULL, ack_requested_at = NULL, ack_requested_by = NULL, ' +
    'ack_requested_sid = NULL, ' +
    "cleared_at = NULL, cleared_by = NULL, push_status = 'pending', push_attempts = 0, fault_push_status = NULL, " +
    'updated_at = CURRENT_TIMESTAMP WHERE alarms.home_id <> EXCLUDED.home_id RETURNING id',
  findAlarm:
    'SELECT id, aid, status FROM alarms WHERE device_id = $1 AND ' +
    "(($2::varchar IS NOT NULL AND aid = $2::varchar) OR ($2::varchar IS NULL AND zone = $3 AND kind <> 'intrusion' AND status NOT IN ('cleared', 'lost'))) " +
    'ORDER BY id DESC LIMIT 1 FOR UPDATE',
  setFault:
    "UPDATE alarms SET status = 'fault', fault_push_status = COALESCE(fault_push_status, 'pending'), updated_at = CURRENT_TIMESTAMP " +
    "WHERE id = $1 AND status NOT IN ('cleared', 'lost') RETURNING id, fault_push_status",
  clearFault:
    "UPDATE alarms SET status = CASE WHEN acked_at IS NOT NULL THEN 'silenced' ELSE 'latched' END, updated_at = CURRENT_TIMESTAMP " +
    "WHERE id = $1 AND status = 'fault'",
  setSilenced:
    "UPDATE alarms SET status = CASE WHEN status = 'fault' THEN 'fault' ELSE 'silenced' END, " +
    'acked_at = COALESCE(acked_at, CURRENT_TIMESTAMP), updated_at = CURRENT_TIMESTAMP ' +
    "WHERE id = $1 AND status NOT IN ('cleared', 'lost')",
  setCleared:
    "UPDATE alarms SET status = 'cleared', cleared_at = CURRENT_TIMESTAMP, cleared_by = $2, updated_at = CURRENT_TIMESTAMP " +
    "WHERE id = $1 AND status <> 'cleared'",
  insertTomb:
    'INSERT INTO alarms (home_id, device_id, aid, zone, kind, status, origin, raised_at, cleared_at, cleared_by, push_status) ' +
    "VALUES ($1, $2, $3, $4, $5, 'cleared', 'tomb', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, 'device_event', 'skipped') " +
    'ON CONFLICT (device_id, aid) DO NOTHING',
  audit:
    'INSERT INTO device_audit_logs (event, device_uuid, home_id, actor_user_id, actor_role, ip_address, details) ' +
    "VALUES ($1, $2, $3, NULL, 'device', NULL, $4::jsonb)",
  // sko-1: sunucunun kendi karari (kuyruktaki onay istegi dusuruldu)
  auditSystem:
    'INSERT INTO device_audit_logs (event, device_uuid, home_id, actor_user_id, actor_role, ip_address, details) ' +
    "VALUES ($1, $2, $3, NULL, 'system', NULL, $4::jsonb)",
  // guvenlik-1: yalniz panonun SIMDIKI evine ait acik satirlar uzlastirilir; baska evde acik kalmis satir lost olur.
  openAlarms:
    'SELECT id, aid, zone, kind, status, ack_requested_at, ack_requested_by, ack_requested_sid FROM alarms ' +
    "WHERE device_id = $1 AND home_id = $2 AND status NOT IN ('cleared', 'lost') ORDER BY id",
  loseOtherHomes:
    "UPDATE alarms SET status = 'lost', cleared_at = CURRENT_TIMESTAMP, cleared_by = 'lost', ack_requested_at = NULL, " +
    'ack_requested_by = NULL, ack_requested_sid = NULL, updated_at = CURRENT_TIMESTAMP ' +
    "WHERE device_id = $1 AND home_id <> $2 AND status NOT IN ('cleared', 'lost') RETURNING id",
  setStatus:
    "UPDATE alarms SET status = $2, updated_at = CURRENT_TIMESTAMP WHERE id = $1 AND status NOT IN ('cleared', 'lost') AND status <> $2",
  setLost:
    "UPDATE alarms SET status = 'lost', cleared_at = CURRENT_TIMESTAMP, cleared_by = 'lost', ack_requested_at = NULL, " +
    "ack_requested_sid = NULL, updated_at = CURRENT_TIMESTAMP WHERE id = $1 AND status NOT IN ('cleared', 'lost') RETURNING id",
  dropAckRequest:
    'UPDATE alarms SET ack_requested_at = NULL, ack_requested_by = NULL, ack_requested_sid = NULL WHERE id = $1 AND ack_requested_at IS NOT NULL',
  takeAckRequest:
    'UPDATE alarms SET ack_requested_at = NULL, acked_by = ack_requested_by, acked_at = CURRENT_TIMESTAMP, ' +
    'ack_requested_sid = NULL, updated_at = CURRENT_TIMESTAMP WHERE id = $1 AND ack_requested_at IS NOT NULL RETURNING id',
  claimPush:
    "UPDATE alarms SET push_status = 'claimed', push_attempts = push_attempts + 1, updated_at = CURRENT_TIMESTAMP " +
    "WHERE id = $1 AND push_status = 'pending' RETURNING id, home_id, device_id, zone, kind, status, (SELECT d.device_uuid FROM devices d WHERE d.id = alarms.device_id) AS device_uuid",
  setPush: 'UPDATE alarms SET push_status = $2, updated_at = CURRENT_TIMESTAMP WHERE id = $1',
  claimFaultPush:
    "UPDATE alarms SET fault_push_status = 'claimed', updated_at = CURRENT_TIMESTAMP " +
    "WHERE id = $1 AND fault_push_status = 'pending' RETURNING id, home_id, device_id, zone, kind, status, (SELECT d.device_uuid FROM devices d WHERE d.id = alarms.device_id) AS device_uuid",
  setFaultPush: 'UPDATE alarms SET fault_push_status = $2, updated_at = CURRENT_TIMESTAMP WHERE id = $1',
  // sko-2: yeniden talep (PUSH_DUE / FAULT_PUSH_DUE; listeleme + ayni kosulla CAS: iki ornek ayni satiri alamaz)
  stuckPushes: `SELECT id FROM alarms WHERE ${PUSH_DUE} ORDER BY id LIMIT $1`,
  claimRetry:
    "UPDATE alarms SET push_status = 'claimed', push_attempts = push_attempts + 1, updated_at = CURRENT_TIMESTAMP " +
    `WHERE id = $1 AND ${PUSH_DUE} RETURNING ${PUSH_ROW_COLS}`,
  stuckFaultPushes: `SELECT id FROM alarms WHERE ${FAULT_PUSH_DUE} ORDER BY id LIMIT $1`,
  claimFaultRetry:
    "UPDATE alarms SET fault_push_status = 'claimed', updated_at = CURRENT_TIMESTAMP " +
    `WHERE id = $1 AND ${FAULT_PUSH_DUE} RETURNING ${PUSH_ROW_COLS}`,
  deviceUuid: 'SELECT device_uuid FROM devices WHERE id = $1',
  configOf: 'SELECT rev, crc FROM device_configs WHERE device_id = $1 AND module = $2',
  configBody: 'SELECT rev, crc, body, updated_at FROM device_configs WHERE device_id = $1 AND module = $2',
  upsertConfig:
    'INSERT INTO device_configs (device_id, module, rev, crc, body, updated_at) ' +
    'VALUES ($1, $2, $3, $4, $5::jsonb, CURRENT_TIMESTAMP) ' +
    'ON CONFLICT (device_id, module) DO UPDATE SET rev = EXCLUDED.rev, crc = EXCLUDED.crc, body = EXCLUDED.body, ' +
    // Eski (gecikmis) dokum yenisini ezmez; ANCAK pano rev'i geriledi ise (fabrika sifirlamasi) panonun SON BILDIRDIGI (rev, crc) ile
    // ayni dokum yazilir, aksi halde kopya kalici bayat kalirdi (Faz 2 incelemesi RG-1).
    'updated_at = CURRENT_TIMESTAMP WHERE device_configs.rev <= EXCLUDED.rev OR EXISTS (SELECT 1 FROM devices d WHERE d.id = EXCLUDED.device_id ' +
    "AND d.safety_state -> 'cfg' ->> 'rev' = EXCLUDED.rev::text AND lower(d.safety_state -> 'cfg' ->> 'crc') = lower(EXCLUDED.crc)) RETURNING rev",
  list:
    'SELECT a.id, a.device_id, d.device_uuid, a.aid, a.zone, a.kind, a.status, a.origin, a.sources, a.raised_at, ' +
    'a.device_epoch, a.acked_by, a.acked_at, a.ack_requested_at, a.cleared_at, a.cleared_by ' +
    'FROM alarms a JOIN devices d ON d.id = a.device_id ' +
    "WHERE a.home_id = $1 AND a.origin <> 'tomb' " +
    "AND ($2::boolean IS FALSE OR a.status NOT IN ('cleared', 'lost')) " +
    'AND ($3::bigint IS NULL OR a.id < $3::bigint) ' +
    'ORDER BY a.id DESC LIMIT $4',
  getAlarm:
    'SELECT a.id, a.home_id, a.device_id, d.device_uuid, a.aid, a.zone, a.kind, a.status, ' +
    'COALESCE(d.is_online, FALSE) AS is_online, d.caps, d.safety_state, h.mqtt_username AS topic_id ' +
    'FROM alarms a JOIN devices d ON d.id = a.device_id JOIN homes h ON h.id = a.home_id ' +
    'WHERE a.id = $1 AND a.home_id = $2',
  requestAck:
    'UPDATE alarms SET ack_requested_at = CURRENT_TIMESTAMP, ack_requested_by = $3, ack_requested_sid = $4, updated_at = CURRENT_TIMESTAMP ' +
    "WHERE id = $1 AND home_id = $2 AND status NOT IN ('cleared', 'lost') RETURNING id",
  markAcked:
    'UPDATE alarms SET acked_by = $2, acked_at = COALESCE(acked_at, CURRENT_TIMESTAMP), updated_at = CURRENT_TIMESTAMP WHERE id = $1',
});

// ------------------------------------------------------------------------------
// Saf yardimcilar
// ------------------------------------------------------------------------------
const TITLES = Object.freeze({ water: 'Su baskını alarmı', gas: 'Gaz kaçağı alarmı', smoke: 'Duman alarmı', intrusion: 'Hırsız alarmı' });

function alarmTitle(kind) {
  return TITLES[kind] || 'Güvenlik alarmı';
}

// Faz 2 F2.A.5: gaz ve duman metinleri davranis talimati tasir (187 dogalgaz acil, 112); su metni AYNEN.
function alarmBody({ kind, zone }) {
  const z = Number.isInteger(zone) ? ` (bölge ${zone})` : '';
  if (kind === 'water') return `Evinizde su algılandı${z}. Vana pano tarafından kapatıldı; uygulamadan durumu kontrol edin.`;
  if (kind === 'gas') {
    return `Gaz kaçağı algılandı${z}. Gaz vanası kapatıldı. Ortamı havalandırın, elektrik anahtarlarına dokunmayın; gerekirse 187'yi arayın.`;
  }
  if (kind === 'smoke') return `Duman algılandı${z}. Evde biri varsa hemen dışarı çıkın ve 112'yi arayın. Pano su vanasını kapatmaz.`;
  if (kind === 'intrusion') return `Ev alarmı tetiklendi${z}. Uygulamadan durumu kontrol edin; tehlikedeyseniz 112'yi arayın.`; // F2.B.7
  return `Güvenlik alarmı${z}. Uygulamadan durumu kontrol edin.`;
}

/** Vana arizasi (valve_fault) push basligi: alarm turune gore (F2.A.5). */
function faultTitle(kind) {
  return kind === 'gas' ? 'Gaz vanası kapanmadı!' : 'Vana kapanmadı!';
}

/** Vana arizasi push govdesi: alarm turune gore; bilinmeyen tur bugunku genel metni alir (F2.A.5). */
function faultBody(kind) {
  if (kind === 'water') return 'Su vanası kapanmadı! Ana su vanasını elle kapatın ve panoyu kontrol edin.';
  if (kind === 'gas') return "Gaz vanası kapanmadı! Sayaçtaki ana gaz vanasını elle kapatın, ortamı havalandırın ve 187'yi arayın.";
  return 'Vana kapanmadı! Ana vanayı elle kapatın ve panoyu kontrol edin.';
}

function infoText(reason, extra = {}) {
  if (reason === 'policy_off') {
    return { title: 'Güvenlik tepkileri kapatıldı', body: `Panodaki güvenlik tepkileri kapatıldı${extra.via ? ` (${extra.via})` : ''}. Bilginiz dışındaysa kurulumcunuza başvurun.` };
  }
  if (reason === 'policy_on') return { title: 'Güvenlik tepkileri açıldı', body: 'Panodaki güvenlik tepkileri yeniden açıldı.' };
  if (reason === 'cfg_pending_dropped') {
    // Faz 2 F2.D.2: cevrimdisi panoya siralanan yamalar uygulanamadi (pano kazanir: yerel degisiklik ezilmez)
    return {
      title: 'Bekleyen yapılandırma iptal edildi',
      body: 'Pano çevrimdışıyken sıraya alınan yapılandırma değişiklikleri uygulanamadı ve iptal edildi; panodaki yapılandırma geçerli.',
    };
  }
  return { title: 'Alarm durumu doğrulanamadı', body: 'Alarm durumu doğrulanamadı, panoyu kontrol edin.' };
}

function short(v) {
  return String(v || '-').slice(0, 8);
}

function errKind(err) {
  const code = err && typeof err.code === 'string' && /^[A-Za-z0-9_]{1,40}$/.test(err.code) ? err.code : null;
  return code || (err && typeof err.name === 'string' && /^[A-Za-z0-9_$]{1,40}$/.test(err.name) ? err.name : 'Error');
}

function newCommandId() {
  return crypto.randomBytes(9).toString('base64url');
}

/**
 * Hirsiz alarmi satirinin state'e gore karari (F2.B.8): arm yok (sensor kalmadi / eski firmware) ya da arm.ok=false -> lost;
 * st=alarm ve ayni aid -> keep; bilinmeyen st -> keep (dokunma); aksi (st != alarm ya da baska aid) -> cleared.
 */
function intrusionVerdict(arm, aid) {
  if (!arm || arm.ok !== true) return 'lost';
  if (arm.st === 'unknown') return 'keep';
  if (arm.st === 'alarm' && arm.aid === aid) return 'keep';
  return 'cleared';
}

/** State'ten acilan hirsiz satirinin bolgesi: ilk kaynak sensorunun bolgesi (sensors[]), yoksa 1. */
function intrusionZone(arm, summary) {
  const sensors = summary && Array.isArray(summary.sensors) ? summary.sensors : [];
  for (const id of arm.srcs || []) {
    const s = sensors.find((x) => x && x.id === id);
    if (s && Number.isInteger(s.zone) && s.zone >= 1 && s.zone <= 4) return s.zone;
  }
  return 1;
}

function revOf(summary) {
  return summary && summary.cfg && Number.isInteger(summary.cfg.rev) ? summary.cfg.rev : null;
}

// ------------------------------------------------------------------------------
// Servis
// ------------------------------------------------------------------------------
class AlarmService {
  /**
   * @param {object} deps
   * @param {{query:Function, withTransaction:Function}} deps.db
   * @param {(topicId:string, cmd:object)=>Promise} deps.publishCommand   ev/{t}/cmd (QoS1)
   * @param {(topicId:string, obj:object)=>Promise} [deps.publishSys]    ev/{t}/sys (cfg_get)
   * @param {()=>boolean} [deps.isConnected]
   * @param {()=>object|null} [deps.getPush]   push servisi (start() enjekte eder; yoksa push atlanir: 'skipped')
   * @param {object} [deps.logger] @param {object} [deps.timers] @param {()=>number} [deps.now]
   * @param {number} [deps.ackWindowMs]  event_ack birlestirme penceresi (0 = aninda)
   * @param {number} [deps.pushRetryDelayMs] basarisiz alarm push'unun tek yeniden denemesinden once bekleme
   * @param {(ms:number)=>Promise} [deps.sleep] bekleme (test enjeksiyonu)
   */
  constructor(deps = {}) {
    if (!deps.db || typeof deps.db.query !== 'function' || typeof deps.db.withTransaction !== 'function') {
      throw new TypeError('AlarmService: db (query, withTransaction) zorunludur');
    }
    if (typeof deps.publishCommand !== 'function') throw new TypeError('AlarmService: publishCommand zorunludur');
    this._deps = deps;
    this.db = deps.db;
    this.logger = deps.logger || console;
    this.timers = deps.timers || { setTimeout: (...a) => setTimeout(...a), clearTimeout: (...a) => clearTimeout(...a) };
    this.now = typeof deps.now === 'function' ? deps.now : Date.now;
    this.ackWindowMs = Number.isFinite(deps.ackWindowMs) && deps.ackWindowMs >= 0 ? deps.ackWindowMs : ACK_WINDOW_MS;
    this.pushRetryDelayMs =
      Number.isFinite(deps.pushRetryDelayMs) && deps.pushRetryDelayMs >= 0 ? deps.pushRetryDelayMs : PUSH_RETRY_DELAY_MS;
    this._sleep =
      typeof deps.sleep === 'function'
        ? deps.sleep
        : (ms) =>
            new Promise((resolve) => {
              const t = setTimeout(resolve, ms);
              if (t && typeof t.unref === 'function') t.unref();
            });
    this._acks = new Map(); // `${topic}|${uid}` -> { topicId, uid, eids:Set, timer }
    this._inflight = new Set(); // COMMIT sonrasi push islerinin sozleri (idle() icin)
    this._dumps = new Map(); // cfg_dump parcalari
    this._cfgGetAt = new Map(); // deviceId -> son cfg_get zamani
    this._cfgVerified = new Map(); // deviceId -> kopyanin esit oldugu dogrulanan `rev|crc`
    this._clean = new Map(); // deviceId -> acik alarmi olmadigi son dogrulama zamani (RV-7)
    this._warnedAt = new Map();
    this._retrying = null; // sko-2: suren retryStuckPushes turu (tek ucus)
    this.counters = { events: 0, duplicates: 0, unknown: 0, opened: 0, cleared: 0, lost: 0, acks: 0, pushes: 0, pushRetries: 0, errors: 0 };
  }

  _log(level, message) {
    try {
      const fn = this.logger && (this.logger[level] || this.logger.log);
      if (typeof fn === 'function') fn.call(this.logger, `[ALARM] ${message}`);
    } catch (_) {
      /* gunluk hatasi isi bozmasin */
    }
  }

  _warn(key, message) {
    const t = this.now();
    const last = this._warnedAt.get(key);
    if (last !== undefined && t - last < 60 * 1000) return;
    this._warnedAt.set(key, t);
    if (this._warnedAt.size > 500) this._warnedAt.clear();
    this._log('warn', message);
  }

  _track(promise) {
    const p = Promise.resolve(promise).catch(() => {});
    this._inflight.add(p);
    p.finally(() => this._inflight.delete(p));
    return p;
  }

  /** COMMIT sonrasi baslatilan push islerinin bitmesini bekler (kapanis ve testler). */
  async idle() {
    while (this._inflight.size > 0) await Promise.all([...this._inflight]);
  }

  // -- event_ack birlestirme ----------------------------------------------------
  /** Olay onayi kuyrugu: pano (uid) basina pencere; uid ZORUNLU (ev konusu tum panolara gider) [Y4]. */
  queueAck(topicId, uid, eid) {
    try {
      if (!topicId || !uid || !eid) return;
      const key = `${topicId}|${uid}`;
      let slot = this._acks.get(key);
      if (!slot) {
        slot = { topicId, uid, eids: new Set(), timer: null };
        this._acks.set(key, slot);
      }
      slot.eids.add(eid);
      if (this.ackWindowMs === 0) {
        this._flushAck(key);
        return;
      }
      if (!slot.timer) {
        slot.timer = this.timers.setTimeout(() => this._flushAck(key), this.ackWindowMs);
        if (slot.timer && typeof slot.timer.unref === 'function') slot.timer.unref();
      }
    } catch (_) {
      /* onay en iyi caba: pano yeniden dener */
    }
  }

  async _flushAck(key) {
    const slot = this._acks.get(key);
    if (!slot) return;
    this._acks.delete(key);
    if (slot.timer) this.timers.clearTimeout(slot.timer);
    const eids = [...slot.eids];
    const connected = typeof this._deps.isConnected === 'function' ? this._deps.isConnected() : true;
    if (!connected) return; // pano yeniden dener (5/10/20/40/60 sn)
    for (let i = 0; i < eids.length; i += MAX_ACK_EIDS) {
      const batch = eids.slice(i, i + MAX_ACK_EIDS);
      try {
        await this._deps.publishCommand(slot.topicId, { cmd: 'event_ack', uid: slot.uid, eids: batch });
        this.counters.acks += 1;
      } catch (err) {
        this._warn('ack', `event_ack yayinlanamadi (${errKind(err)}); pano yeniden deneyecek`);
        return;
      }
    }
  }

  // -- Olay isleme ---------------------------------------------------------------
  /**
   * @param {{topicId:string, homeId:string, deviceId:string, uid:string, deviceUuid?:string, event:object}} p
   * @returns {Promise<{status:'applied'|'duplicate'|'unknown'|'error', alarmId?:number, opened?:boolean}>}
   */
  async handleEvent({ topicId, homeId, deviceId, uid, event }) {
    this.counters.events += 1;
    let out;
    try {
      out = await this.db.withTransaction((tx) => this._applyEvent(tx, { homeId, deviceId, uid, event }));
    } catch (err) {
      this.counters.errors += 1;
      this._warn('event-db', `olay islenemedi ev=${short(homeId)} tur=${event && event.type} (${errKind(err)})`);
      return { status: 'error' }; // onay GONDERILMEZ: pano yeniden dener
    }
    this.queueAck(topicId, uid, event.eid);
    if (event && (event.type === 'alarm_raised' || event.type === 'intrusion_alarm')) this._clean.delete(deviceId);
    if (out.status === 'duplicate') this.counters.duplicates += 1;
    if (out.status === 'unknown') this.counters.unknown += 1;
    if (out.opened) {
      this.counters.opened += 1;
      this._track(this.pushAlarm(out.alarmId));
    }
    if (out.faultPush) this._track(this.pushFault(out.alarmId));
    if (out.info) this._track(this.pushInfo({ homeId, deviceId, deviceUuid: uid, alarmId: null, ...out.info }));
    return { status: out.status, alarmId: out.alarmId, opened: out.opened === true };
  }

  async _applyEvent(tx, { homeId, deviceId, uid, event }) {
    const ins = await tx.query(SQL.insertEvent, [deviceId, event.eid, String(event.type).slice(0, 24), JSON.stringify(event)]);
    if (!ins || !ins.rows || ins.rows.length === 0) return { status: 'duplicate' };
    if (event.unknown) {
      await tx.query(SQL.audit, [`safety_${String(event.type).slice(0, 30)}`, uid, homeId, JSON.stringify({ eid: event.eid, unknown: true })]);
      return { status: 'unknown' };
    }

    const aid = event.aid || (event.type === 'alarm_raised' ? event.eid : null);
    const kind = event.kind || 'generic';
    const result = { status: 'applied', alarmId: null, opened: false, faultPush: false, info: null };

    switch (event.type) {
      case 'alarm_raised':
      case 'intrusion_alarm': { // F2.B.8: hirsiz alarmi da bir alarms satiridir (kind='intrusion', aid = eid)
        const r = await tx.query(SQL.insertRaised, [
          homeId, deviceId, aid, event.zone, kind, 'event', JSON.stringify(event.srcs || []), event.at,
        ]);
        if (r && r.rows && r.rows.length > 0) {
          result.alarmId = r.rows[0].id;
          result.opened = true; // cakisma (mezar tasi / state satiri) -> push YOK [O7]
        }
        break;
      }
      case 'valve_fault':
      case 'valve_fault_cleared':
      case 'alarm_silenced':
      case 'alarm_cleared': {
        const found = await tx.query(SQL.findAlarm, [deviceId, aid, event.zone]);
        const row = found && found.rows && found.rows[0];
        if (!row) {
          // Sirasiz teslim: alarm_raised henuz gelmedi -> kapali mezar tasi (sonraki alarm_raised push uretmez) [O7]
          if (event.type === 'alarm_cleared' && aid) await tx.query(SQL.insertTomb, [homeId, deviceId, aid, event.zone, kind]);
          break;
        }
        result.alarmId = row.id;
        if (event.type === 'valve_fault') {
          const r = await tx.query(SQL.setFault, [row.id]);
          const f = r && r.rows && r.rows[0];
          result.faultPush = Boolean(f && f.fault_push_status === 'pending');
        } else if (event.type === 'valve_fault_cleared') {
          await tx.query(SQL.clearFault, [row.id]);
        } else if (event.type === 'alarm_silenced') {
          await tx.query(SQL.setSilenced, [row.id]);
        } else {
          await tx.query(SQL.setCleared, [row.id, 'device_event']);
          this.counters.cleared += 1;
        }
        break;
      }
      case 'intrusion_cleared': { // F2.B.8: cozme; bilinmeyen aid -> mezar tasi (sonraki intrusion_alarm push uretmez)
        const found = aid ? await tx.query(SQL.findAlarm, [deviceId, aid, null]) : null;
        const row = found && found.rows && found.rows[0];
        if (!row) {
          // Olay bolge tasimaz; zone NOT NULL (1..4) oldugu icin mezar tasina 1 yazilir (mezar tasi listelenmez).
          if (aid) await tx.query(SQL.insertTomb, [homeId, deviceId, aid, event.zone || 1, 'intrusion']);
          break;
        }
        result.alarmId = row.id;
        await tx.query(SQL.setCleared, [row.id, 'device_event']);
        this.counters.cleared += 1;
        break;
      }
      case 'policy_changed':
        if (event.policy) result.info = { reason: event.policy === 'off' ? 'policy_off' : 'policy_on', via: event.via };
        break;
      default:
        break; // test_result, sensor_fault, safe_mode, nvs_fail ...: gunluk + denetim
    }

    const details = { eid: event.eid };
    if (aid) details.aid = aid;
    if (event.zone) details.zone = event.zone;
    if (event.kind) details.kind = event.kind;
    if (event.policy) details.policy = event.policy;
    if (event.mode) details.mode = event.mode;
    if (event.via) details.via = event.via;
    if (event.reason) details.reason = event.reason;
    if (event.type === 'test_result') details.ok = event.ok;
    await tx.query(SQL.audit, [`safety_${event.type}`.slice(0, 40), uid, homeId, JSON.stringify(details)]);
    return result;
  }

  // -- State uzlastirmasi ---------------------------------------------------------
  /**
   * CANLI state COMMIT'inden sonra. caps yoksa ve onceden de yoksa (v:2 pano) HICBIR sorgu yapmaz.
   * @param {{topicId, homeId, deviceId, uid, caps:string[]|null, summary:object|null, prev:object|null, hadCaps:boolean}} p
   */
  async onLiveState({ topicId, homeId, deviceId, uid, caps, summary, prev = null, hadCaps = false }) {
    try {
      if ((caps === null || caps === undefined) && !hadCaps) return { status: 'skipped' };
      const noSafety = !Array.isArray(caps) || !caps.includes('safety') || !summary || summary.present !== true;
      const unsafeMode = !noSafety && summary.mode !== 'normal';
      const prevRev = revOf(prev);
      const rev = revOf(summary);
      const revRegressed = prevRev !== null && (rev === null || rev < prevRev);
      const provable = !noSafety && !unsafeMode && !revRegressed;

      const zones = !noSafety && Array.isArray(summary.zones) ? summary.zones : [];
      // RV2-1: eksik/bozuk liste (zones_complete=false) listede olmayan bolge icin kanit degildir; alan yoksa (eski ozet) tam sayilir.
      const zonesComplete = noSafety || summary.zones_complete !== false;
      const arm = !noSafety && summary.arm && typeof summary.arm === 'object' ? summary.arm : null;
      const armAlarm = Boolean(arm && arm.st === 'alarm');
      const anyActive = zones.some((z) => z && (z.st === 'latched' || z.st === 'fault')) || armAlarm;
      const cleanAt = this._clean.get(deviceId);
      // guvenlik-3: kopya tazeleme yapilandirilmamis (present:false) panoda da (firmware 1.3.1 cfg{rev,crc} yazar); caps 'cfg' sart
      const wantsCfg = Boolean(summary && summary.cfg && Array.isArray(caps) && caps.includes('cfg'));
      if (!anyActive && zonesComplete && cleanAt !== undefined && this.now() - cleanAt < CLEAN_TTL_MS) {
        if (wantsCfg) this._track(this._maybeRequestConfig({ topicId, deviceId, uid, summary, prev }));
        return { status: 'applied', opened: 0, lost: 0, cached: true };
      }
      // guvenlik-1: pano baska eve tasindiysa eski evde acik kalmis satirlar kapanir (bilgi push'u YOK: eski ev)
      const stale = await this.db.query(SQL.loseOtherHomes, [deviceId, homeId]);
      if (stale && stale.rows && stale.rows.length > 0) this.counters.lost += stale.rows.length;
      const res = await this.db.query(SQL.openAlarms, [deviceId, homeId]);
      const rows = (res && res.rows) || [];
      // Sozlesme: zones[] yalniz normal OLMAYAN bolgeleri listeler; listede yoksa bolge normaldir (kanit gucu `provable`).
      // Liste eksikse (zones_complete=false) listede olmayan bolge bilinmiyor sayilir (null: dokunma) [RV2-1].
      const zoneOf = (id) => zones.find((z) => z && z.id === id) || (zonesComplete ? { id, st: 'normal', aid: null } : null);
      const lostIds = [];

      for (const row of rows) {
        if (noSafety) {
          if (await this._markLost(row.id)) lostIds.push(row.id);
          continue;
        }
        if (row.kind === 'intrusion') {
          // F2.B.8 KRITIK: bolge uzlastirmasi hirsiz satirina DOKUNMAZ (hirsiz alarmi zones[]'ta yer almaz).
          const verdict = intrusionVerdict(arm, row.aid);
          if (verdict === 'cleared') {
            await this.db.query(SQL.setCleared, [row.id, 'device_state']);
            this.counters.cleared += 1;
          } else if (verdict === 'lost' && (await this._markLost(row.id))) {
            lostIds.push(row.id);
          }
          continue;
        }
        const z = zoneOf(Number(row.zone));
        if (!z) continue; // liste eksik ve bolge bildirilmedi: bilinmiyor, dokunma [RV2-1]
        const active = z.st === 'latched' || z.st === 'fault';
        if (active && z.aid && z.aid === row.aid) {
          const target = z.st === 'fault' ? 'fault' : z.silenced ? 'silenced' : 'latched';
          if (row.status !== target) await this.db.query(SQL.setStatus, [row.id, target]);
          if (row.ack_requested_at) await this._deliverAckRequest({ topicId, homeId, uid, row });
          continue;
        }
        if (active && !z.aid) continue; // kimliksiz kilit: karar verilemez
        // Bolge normal/test ya da bolgede BASKA bir alarm kimligi var: bu satirin kilidi kalkmis
        if (row.ack_requested_at) await this.db.query(SQL.dropAckRequest, [row.id]);
        if (provable) {
          await this.db.query(SQL.setCleared, [row.id, active ? 'superseded' : 'device_state']);
          this.counters.cleared += 1;
        } else if (await this._markLost(row.id)) {
          lostIds.push(row.id);
        }
      }

      const opened = [];
      if (!noSafety) {
        const known = new Set(rows.map((r) => r.aid));
        // F2.B.8: olayi kaybolmus hirsiz alarmi state'ten acilir; bolge ilk kaynak sensorunden (yoksa 1).
        if (armAlarm && arm.ok === true && arm.aid && !known.has(arm.aid)) {
          const r = await this.db.query(SQL.insertRaised, [
            homeId, deviceId, arm.aid, intrusionZone(arm, summary), 'intrusion', 'state', JSON.stringify(arm.srcs || []), null,
          ]);
          const id = r && r.rows && r.rows[0] && r.rows[0].id;
          if (id) opened.push(id);
        }
        for (const z of zones) {
          if ((z.st !== 'latched' && z.st !== 'fault') || !z.aid || known.has(z.aid)) continue;
          const r = await this.db.query(SQL.insertRaised, [
            homeId, deviceId, z.aid, z.id, z.kind || 'generic', 'state', JSON.stringify(z.srcs || []), Number.isInteger(z.since) ? z.since : null,
          ]);
          const id = r && r.rows && r.rows[0] && r.rows[0].id;
          if (id) {
            if (z.st === 'fault') await this.db.query(SQL.setStatus, [id, 'fault']);
            else if (z.silenced) await this.db.query(SQL.setStatus, [id, 'silenced']);
            opened.push(id);
          }
        }
      }

      for (const id of opened) {
        this.counters.opened += 1;
        this._track(this.pushAlarm(id));
      }
      if (rows.length === 0 && opened.length === 0 && !anyActive && zonesComplete) {
        if (this._clean.size >= CLEAN_MAX_DEVICES) this._clean.clear();
        this._clean.set(deviceId, this.now());
      } else {
        this._clean.delete(deviceId);
      }
      for (const id of lostIds) {
        this.counters.lost += 1;
        this._track(this.pushInfo({ homeId, deviceId, deviceUuid: uid, alarmId: id, reason: 'alarm_lost' }));
      }
      if (wantsCfg) this._track(this._maybeRequestConfig({ topicId, deviceId, uid, summary, prev }));
      return { status: 'applied', opened: opened.length, lost: lostIds.length };
    } catch (err) {
      this.counters.errors += 1;
      this._warn('live', `state uzlastirmasi hatasi ev=${short(homeId)} (${errKind(err)})`);
      return { status: 'error' };
    }
  }

  async _markLost(id) {
    const r = await this.db.query(SQL.setLost, [id]);
    return Boolean(r && r.rows && r.rows.length > 0);
  }

  /**
   * Cevrimdisiyken istenen onay: yalniz state'teki bolge aid'si satirin aid'siyle AYNIYSA gonderilir [Y-9].
   * sko-1 (sozlesme C11): istek 24 saatten eskiyse ya da isteyen artik yetkili degilse panoya GITMEZ; istek duser ve
   * device_audit_logs 'alarm_ack_request_dropped' {reason: expired|revoked}.
   */
  async _deliverAckRequest({ topicId, homeId, uid, row }) {
    const connected = typeof this._deps.isConnected === 'function' ? this._deps.isConnected() : true;
    if (!connected) return;
    const reason = await this._ackRequestBlocked(homeId, row);
    if (reason) {
      const dropped = await this.db.query(SQL.dropAckRequest, [row.id]);
      if (dropped && dropped.rowCount === 0) return; // baska ornek zaten dusurdu/iletti
      await this.db.query(SQL.auditSystem, [
        'alarm_ack_request_dropped', uid, homeId, JSON.stringify({ alarm_id: Number(row.id), zone: Number(row.zone), reason }),
      ]);
      this._log('log', `bekleyen alarm onayi dusuruldu ev=${short(homeId)} (${reason})`);
      return;
    }
    const taken = await this.db.query(SQL.takeAckRequest, [row.id]); // CAS: tek gonderim
    if (!taken || !taken.rows || taken.rows.length === 0) return;
    try {
      await this._deps.publishCommand(topicId, { cmd: 'alarm_ack', zone: Number(row.zone), aid: row.aid, uid, id: newCommandId() });
    } catch (err) {
      this._warn('ack-req', `bekleyen alarm onayi iletilemedi (${errKind(err)})`);
    }
  }

  /**
   * Kuyruktaki onay istegi neden iletilemez? null = iletilebilir. Kullanici (by): aktif hesap + onay ucunun rol kumesi
   * (role_matrix safety_ack) ya da super_user; servis oturumu (sid): var, iptal edilmemis, suresi dolmamis; ikisi de
   * yoksa (eski satir) istekten sonra evde iptal edilen servis oturumu varsa gecersiz (services/requester_access.js).
   */
  async _ackRequestBlocked(homeId, row) {
    const at = row.ack_requested_at ? new Date(row.ack_requested_at).getTime() : NaN;
    const nowMs = this.now();
    if (!Number.isFinite(at) || nowMs - at > ACK_REQUEST_TTL_MS) return 'expired';
    const q = (text, params) => this.db.query(text, params);
    const ok = row.ack_requested_by
      ? await RA.userAccessOk(q, homeId, row.ack_requested_by, { roles: CAPABILITIES.safety_ack })
      : await RA.sessionOk(q, homeId, { sid: row.ack_requested_sid || null, at: new Date(at).toISOString() }, nowMs);
    return ok ? null : 'revoked';
  }

  /** Yapilandirma kopyasi panodan farkliysa sys cfg_get (cihaz basina dakikada en cok bir) [§4.2]. */
  async _maybeRequestConfig({ topicId, deviceId, uid, summary }) {
    if (typeof this._deps.publishSys !== 'function') return;
    const cur = summary.cfg;
    // Kopyanin bu (rev, crc) icin dogrulandigi biliniyorsa sorgu yok. Faz 2 duzeltmesi: eskiden "onceki state ile ayni rev"
    // erken donus sayiliyordu; dakika sinirina takilan cfg_get bir daha istenmez, kopya kalici bayat kalirdi.
    if (this._cfgVerified.get(deviceId) === `${cur.rev}|${cur.crc}`) return;
    const t = this.now();
    const last = this._cfgGetAt.get(deviceId);
    if (last !== undefined && t - last < CFG_GET_MIN_INTERVAL_MS) return;
    const r = await this.db.query(SQL.configOf, [deviceId, 'safety']);
    const row = r && r.rows && r.rows[0];
    this._cfgGetAt.set(deviceId, t);
    if (this._cfgGetAt.size > 5000) this._cfgGetAt.clear();
    if (row && Number(row.rev) === cur.rev && String(row.crc).toLowerCase() === cur.crc) {
      if (this._cfgVerified.size > 5000) this._cfgVerified.clear();
      this._cfgVerified.set(deviceId, `${cur.rev}|${cur.crc}`);
      return;
    }
    this._cfgVerified.delete(deviceId);
    await this._publishCfgGet(topicId, uid);
  }

  async _publishCfgGet(topicId, uid) {
    try {
      await this._deps.publishSys(topicId, { cmd: 'cfg_get', module: 'safety', uid });
      return true;
    } catch (err) {
      this._warn('cfg-get', `cfg_get yayinlanamadi (${errKind(err)})`);
      return false;
    }
  }

  /**
   * Yapilandirma kopyasini tazele (Faz 2 F2.D: buluttan yama uygulandi / cakisma / kopya yok). `force` dakika sinirini
   * CFG_GET_FORCE_INTERVAL_MS tabanina indirir (yanit beklenmez; kopya cfg_dump ile gelir). ASLA firlatmaz.
   * @returns {Promise<boolean>} istek yayinlandi mi
   */
  async requestConfig({ topicId, deviceId, uid, force = false } = {}) {
    try {
      if (typeof this._deps.publishSys !== 'function' || !topicId || !deviceId || !uid) return false;
      const t = this.now();
      const last = this._cfgGetAt.get(deviceId);
      const floor = force ? CFG_GET_FORCE_INTERVAL_MS : CFG_GET_MIN_INTERVAL_MS;
      if (last !== undefined && t - last < floor) return false;
      this._cfgGetAt.set(deviceId, t);
      this._cfgVerified.delete(deviceId);
      return await this._publishCfgGet(topicId, uid);
    } catch (_) {
      return false;
    }
  }

  // -- cfg_dump -------------------------------------------------------------------
  /** @returns {Promise<{status:'stored'|'partial'|'stale'|'error'}>} */
  async handleCfgDump({ deviceId, dump }) {
    try {
      const t = this.now();
      for (const [k, v] of this._dumps) if (t - v.at > CFG_DUMP_TTL_MS) this._dumps.delete(k);
      let body = dump.body;
      if (dump.parts > 1) {
        const key = `${deviceId}|${dump.module}|${dump.rev}|${dump.crc}`;
        let entry = this._dumps.get(key);
        if (!entry) {
          if (this._dumps.size >= CFG_DUMP_MAX_PENDING) this._dumps.delete(this._dumps.keys().next().value);
          entry = { at: t, parts: dump.parts, got: new Map() };
          this._dumps.set(key, entry);
        }
        entry.got.set(dump.part, dump.body);
        if (entry.got.size < entry.parts) return { status: 'partial' };
        this._dumps.delete(key);
        body = Array.from({ length: entry.parts }, (_, i) => entry.got.get(i + 1));
      }
      body = mergeCfgDumpParts(Array.isArray(body) ? body : [body]); // tek belge (GET /api/safety/config bicimi)
      const r = await this.db.query(SQL.upsertConfig, [deviceId, dump.module, dump.rev, dump.crc, JSON.stringify(body)]);
      return { status: r && r.rows && r.rows.length > 0 ? 'stored' : 'stale' };
    } catch (err) {
      this.counters.errors += 1;
      this._warn('cfg-dump', `cfg_dump yazilamadi (${errKind(err)})`);
      return { status: 'error' };
    }
  }

  // -- Push -----------------------------------------------------------------------
  _push() {
    try {
      return typeof this._deps.getPush === 'function' ? this._deps.getPush() : null;
    } catch (_) {
      return null;
    }
  }

  /** Alarm push'u: en cok bir kez (claim). Alicilar owner + resident. */
  async pushAlarm(alarmId) {
    return this._pushOnce(alarmId, { claim: SQL.claimPush, set: SQL.setPush, fault: false });
  }

  /** valve_fault icin ikinci push (fault_push_status) [D5]. */
  async pushFault(alarmId) {
    return this._pushOnce(alarmId, { claim: SQL.claimFaultPush, set: SQL.setFaultPush, fault: true });
  }

  async _pushOnce(alarmId, { claim, set, fault }) {
    if (alarmId === null || alarmId === undefined) return null;
    try {
      const r = await this.db.query(claim, [alarmId]);
      const row = r && r.rows && r.rows[0];
      if (!row) return null; // zaten islendi / baska ornek aldi
      const push = this._push();
      if (!push || typeof push.isConfigured !== 'function' || !push.isConfigured()) {
        await this.db.query(set, [alarmId, 'skipped']);
        return 'skipped';
      }
      const tokens = await push.recipientsForHome(row.home_id);
      if (!tokens || tokens.length === 0) {
        await this.db.query(set, [alarmId, 'skipped']);
        return 'skipped';
      }
      await this.db.query(set, [alarmId, 'sending']);
      const notice = {
        kind: 'safety_alarm',
        title: fault ? faultTitle(row.kind) : alarmTitle(row.kind),
        body: fault ? faultBody(row.kind) : alarmBody({ kind: row.kind, zone: Number(row.zone) }),
        data: {
          home_id: row.home_id,
          device_id: row.device_id,
          device_uuid: row.device_uuid || null,
          alarm_id: row.id,
          zone: Number(row.zone),
          kind: row.kind,
          status: fault ? 'fault' : row.status,
        },
      };
      let result = await this._trySend(push, { ...notice, tokens });
      if (!(result && result.sent > 0)) {
        // Tek yeniden deneme (gecici FCM/ag hatasi): alicilar yeniden okunur (gecersiz belirtecler kapatilmis olabilir).
        this.counters.pushRetries += 1;
        await this._sleep(this.pushRetryDelayMs);
        const again = await push.recipientsForHome(row.home_id);
        if (again && again.length > 0) result = await this._trySend(push, { ...notice, tokens: again });
      }
      const status = result && result.sent > 0 ? 'sent' : 'failed';
      await this.db.query(set, [alarmId, status]);
      this.counters.pushes += 1;
      return status;
    } catch (err) {
      this.counters.errors += 1;
      this._warn('push', `alarm push hatasi (${errKind(err)})`);
      try {
        await this.db.query(set, [alarmId, 'failed']);
      } catch (_) {
        /* yut */
      }
      return 'failed';
    }
  }

  /**
   * sko-2 (sozlesme C12): acik alarmda yarim kalan ya da basarisiz alarm/ariza push'larini yeniden talep eder (CAS) ve
   * gonderir. Kopru acilistan ~5 sn sonra bir kez ve dakikada bir cagirir. Tek ucus (suren tur varsa onun sozu doner);
   * idle() bekler; asla firlatmaz.
   * @returns {Promise<{claimed:number, sent:number}>}
   */
  retryStuckPushes({ limit = PUSH_RETRY_BATCH } = {}) {
    if (this._retrying) return this._retrying;
    const n = Number.isInteger(limit) && limit > 0 ? Math.min(limit, 500) : PUSH_RETRY_BATCH;
    const run = (async () => {
      const out = { claimed: 0, sent: 0 };
      try {
        for (const [list, claim, set, fault] of [
          [SQL.stuckPushes, SQL.claimRetry, SQL.setPush, false],
          [SQL.stuckFaultPushes, SQL.claimFaultRetry, SQL.setFaultPush, true],
        ]) {
          const r = await this.db.query(list, [n]);
          for (const row of (r && r.rows) || []) {
            const status = await this._pushOnce(row.id, { claim, set, fault });
            if (status === null) continue; // baska ornek/yol aldi
            out.claimed += 1;
            if (status === 'sent') out.sent += 1;
          }
        }
      } catch (err) {
        this.counters.errors += 1;
        this._warn('push-retry', `alarm push yeniden deneme hatasi (${errKind(err)})`);
      }
      if (out.claimed > 0) this._log('log', `yarim kalan alarm push'u yeniden denendi: ${out.claimed} (gonderilen ${out.sent})`);
      return out;
    })();
    this._retrying = run;
    run.then(() => {
      if (this._retrying === run) this._retrying = null;
    });
    this._track(run);
    return run;
  }

  /** sendNotice; firlatirsa null (yeniden deneme karari cagirana). */
  async _trySend(push, args) {
    try {
      return await push.sendNotice(args);
    } catch (err) {
      this._warn('push-send', `alarm push gonderilemedi (${errKind(err)})`);
      return null;
    }
  }

  /** Bilgi push'u (alarm dogrulanamadi / politika degisti): YALNIZ owner. */
  async pushInfo({ homeId, deviceId, deviceUuid = null, alarmId = null, reason, via = null }) {
    try {
      const push = this._push();
      if (!push || typeof push.isConfigured !== 'function' || !push.isConfigured()) return 'skipped';
      const tokens = await push.recipientsForHome(homeId, { roles: ['owner'] });
      if (!tokens || tokens.length === 0) return 'skipped';
      const text = infoText(reason, { via });
      const result = await push.sendNotice({
        tokens,
        kind: 'safety_info',
        title: text.title,
        body: text.body,
        data: { home_id: homeId, device_id: deviceId, device_uuid: deviceUuid, alarm_id: alarmId, reason },
      });
      this.counters.pushes += 1;
      return result && result.sent > 0 ? 'sent' : 'failed';
    } catch (err) {
      this._warn('push-info', `bilgi push hatasi (${errKind(err)})`);
      return 'failed';
    }
  }

  // -- Sorgu (rotalar) --------------------------------------------------------------
  /**
   * Panonun guvenlik yapilandirma kopyasi (cfg_dump; adlar burada, state'te yok [B12]). Yoksa null.
   * Donus bicimi GET /api/safety/config ile aynidir (+ updated_at): {rev, crc, policy, zones, lights, sensors, actuators}.
   */
  async getConfig({ deviceId, module = 'safety' }) {
    const r = await this.db.query(SQL.configBody, [deviceId, module]);
    const row = r && r.rows && r.rows[0];
    if (!row) return null;
    const merged = mergeCfgDumpParts([row.body]);
    return {
      rev: Number(row.rev),
      crc: String(row.crc).toLowerCase(),
      updated_at: row.updated_at instanceof Date ? row.updated_at.toISOString() : row.updated_at,
      ...merged,
    };
  }

  /** GET /homes/:id/alarms?state=open|all&before=<id>&limit= */
  async listAlarms({ homeId, state = 'open', before = null, limit = LIST_DEFAULT_LIMIT }) {
    const n = Number.isInteger(limit) && limit >= 1 ? Math.min(limit, LIST_MAX_LIMIT) : LIST_DEFAULT_LIMIT;
    const beforeId = before === null || before === undefined || before === '' ? null : String(before);
    const res = await this.db.query(SQL.list, [homeId, state !== 'all', beforeId, n]);
    const items = ((res && res.rows) || []).map((r) => ({
      id: Number(r.id),
      device_id: r.device_id,
      device_uuid: r.device_uuid,
      aid: r.aid,
      zone: Number(r.zone),
      kind: r.kind,
      status: r.status,
      origin: r.origin,
      sources: Array.isArray(r.sources) ? r.sources : [],
      raised_at: r.raised_at ? new Date(r.raised_at).toISOString() : null,
      device_epoch: r.device_epoch === null || r.device_epoch === undefined ? null : Number(r.device_epoch),
      acked_at: r.acked_at ? new Date(r.acked_at).toISOString() : null,
      ack_requested: Boolean(r.ack_requested_at),
      cleared_at: r.cleared_at ? new Date(r.cleared_at).toISOString() : null,
      cleared_by: r.cleared_by || null,
    }));
    return { items, next_before: items.length === n ? items[items.length - 1].id : null };
  }

  getAlarm({ alarmId, homeId }) {
    return this.db.query(SQL.getAlarm, [alarmId, homeId]).then((r) => (r && r.rows && r.rows[0]) || null);
  }

  /**
   * Cevrimdisi panoya onay istegi kaydi (yalniz ack; vana acma ASLA kuyruga alinmaz). sessionId: servis (PIN) oturumu
   * (kullanici satiri yok); teslimden once oturumun gecerliligi denetlenir (sko-1).
   */
  async requestAck({ alarmId, homeId, userId, sessionId = null }) {
    const r = await this.db.query(SQL.requestAck, [alarmId, homeId, userId || null, sessionId || null]);
    return Boolean(r && r.rows && r.rows.length > 0);
  }

  markAcked({ alarmId, userId }) {
    return this.db.query(SQL.markAcked, [alarmId, userId || null]);
  }

  stats() {
    return { ...this.counters, pending_acks: this._acks.size };
  }

  stop() {
    for (const slot of this._acks.values()) if (slot.timer) this.timers.clearTimeout(slot.timer);
    this._acks.clear();
    this._dumps.clear();
  }
}

function createAlarmService(deps) {
  return new AlarmService(deps);
}

module.exports = {
  createAlarmService,
  AlarmService,
  SQL,
  OPEN_STATUSES,
  constants: Object.freeze({ ACK_WINDOW_MS, MAX_ACK_EIDS, CFG_DUMP_TTL_MS, CFG_GET_MIN_INTERVAL_MS, CFG_GET_FORCE_INTERVAL_MS, LIST_MAX_LIMIT, PUSH_RETRY_DELAY_MS, ACK_REQUEST_TTL_MS, PUSH_RETRY_BATCH }),
  helpers: { alarmTitle, alarmBody, faultTitle, faultBody, infoText, revOf, intrusionVerdict, intrusionZone },
};
