'use strict';

// ==============================================================================
// AHBU Akilli Ev - Buluttan guvenlik yapilandirmasi yazimi (sys cfg_patch) ve cevrimdisi pano kuyrugu   [CONTRACTS §1.5d, §2.6]
// ==============================================================================
//
// Tasarim: docs/superpowers/specs/2026-10-06-guvenlik-iklim-senaryo-mimarisi-design.md "Faz 2 tasarimi" F2.D (kararlar F2-8, F2-9).
// K5: asil kaynak panodaki NVS'tir; bulut yalniz tek ogelik yama ISTER, karar ve dogrulama panoda verilir.
//
// REST (services/safety_service.js -> patch / cancel / view):
//   1. Govde (utils/safety_cfg_patch.js) -> 400; caps 'cfg' yok -> 409 FIRMWARE_UNSUPPORTED; sys yuku > 1024 B -> 400.
//   2. TEK transaction + device_configs satir kilidi (FOR UPDATE): kopya yoksa 409 CONFIG_NOT_AVAILABLE (+ cfg_get);
//      ucusta yama varsa (inflight, 30 sn) 409 CONFIG_PENDING.
//      Cevrimici: kuyrukta oge varsa 409 CONFIG_PENDING; base_rev != panonun son rev'i -> 409 CONFIG_CHANGED_ON_DEVICE
//      {data:{rev, crc, copy_rev}} (+ kopya bayatsa cfg_get); aksi halde inflight isareti yazilir ve COMMIT.
//      Cevrimdisi: base_rev = kuyruk bossa panonun son rev'i, doluysa son oge + 1 (aksi 409 CONFIG_CHANGED_ON_DEVICE);
//      en cok 16 oge (409 CONFIG_QUEUE_FULL); 202 {queued, position, expires_at, command_id}.
//   3. Cevrimici gonderim transaction DISINDA: bekleyici yayindan ONCE (kopru expectOutcome {uid, cfgRev: base_rev+1}),
//      ev/{t}/sys cfg_patch. Sonuc: uygulandi -> 200 {applied:true, rev, crc, command_id} + cfg_get (adlar);
//      ret -> cfg_conflict 409 CONFIG_CHANGED_ON_DEVICE, cfg_invalid 400 CONFIG_INVALID, zone_latched 409 ZONE_ALARM_ACTIVE,
//      cfg_storage 507 DEVICE_STORAGE_FULL, busy 503 DEVICE_BUSY, digerleri 409 DEVICE_REJECTED {reason};
//      10 sn sonuc yok -> 202 {applied:null, command_id}. Ucus isareti her durumda ikinci transaction'da temizlenir.
//   Neden ucus isareti: ag beklemesi (<= 10 sn) boyunca transaction ACIK tutulmaz (havuz baglantisi + idle_in_transaction
//   zaman asimi); ayni panoya ikinci yama DB duzeyinde reddedilir; surec cokerse isaret 30 sn sonra gecersizdir.
//
// Kuyruk (uzlastirici: kopru cfg yetenekli panonun CANLI state'inde onLiveState cagirir; cihaz basina tek ucus):
//   suresi dolan (24 sa) -> 'expired'; isteyenin eve erisimi kalmadi -> o ve sonrakiler 'revoked'; bas oge daha once
//   gonderilmis ve pano rev'i base_rev + 1 ise UYGULANDI sayilir (yanki kacti: cift uygulama yok); bas ogenin base_rev'i
//   panonun rev'inden farkliysa PANO KAZANIR: butun kuyruk 'conflict' ile duser + owner'a safety_info cfg_pending_dropped;
//   esitse bas oge gonderilir (tur basina tek oge; sonraki oge bir sonraki canli state'te). Firmware reddi cfg_invalid /
//   zone_latched / cfg_conflict / cfg_storage -> bas oge ve sonrakiler duser (bagimlilar) + bilgi push'u; busy / zaman asimi ->
//   oge kalir (en cok MAX_SEND_ATTEMPTS deneme / ATTEMPT_WINDOW_MS). Kuyruk bosken canli state'ler SORGU URETMEZ (bellek ici
//   'bos' onbellegi; REST eklemesi markPending ile gecersiz kilar).
//
// GIZLILIK: denetim kaydina ve gunluge yama DEGERI ve ADLAR yazilmaz (oge turu, kimligi, gevsetme bayragi, sonuc).

const crypto = require('crypto');
const { httpError } = require('../utils/http_errors');
const P = require('../utils/safety_cfg_patch');
const RA = require('./requester_access');
const { isLoosening, isGasRelease, isIntrusionLoosening, diUseMask } = require('../utils/safety_cfg_loosen');

const OUTCOME_TIMEOUT_MS = 10 * 1000;
const MAX_SEND_ATTEMPTS = 3;
const ATTEMPT_WINDOW_MS = 10 * 60 * 1000;
const EMPTY_TTL_MS = 10 * 60 * 1000;
const EMPTY_MAX = 10000;
const DROP_CODES = Object.freeze(['cfg_invalid', 'zone_latched', 'cfg_conflict', 'cfg_storage', 'gas_local_only', 'armed']);

const SQL = Object.freeze({
  lock: "SELECT rev, crc, body, pending FROM device_configs WHERE device_id = $1 AND module = 'safety' FOR UPDATE",
  peek: "SELECT rev, crc, body, pending FROM device_configs WHERE device_id = $1 AND module = 'safety'",
  device: 'SELECT caps, safety_state, COALESCE(is_online, FALSE) AS is_online FROM devices WHERE id = $1',
  setPending: "UPDATE device_configs SET pending = $2::jsonb WHERE device_id = $1 AND module = 'safety'",
  view:
    'SELECT d.safety_state, c.rev AS copy_rev, c.pending FROM devices d ' +
    "LEFT JOIN device_configs c ON c.device_id = d.id AND c.module = 'safety' WHERE d.id = $1",
  // Kuyruktaki ogenin sahibinin eve erisimi suruyor mu (rol yeniden denetlenmez; F2.D.2 madde 2). Ortak: requester_access.
  access: RA.SQL.access,
  audit:
    'INSERT INTO device_audit_logs (event, device_uuid, home_id, actor_user_id, actor_role, ip_address, details) ' +
    'VALUES ($1, $2, $3, $4, $5, $6, $7::jsonb)',
  // guvenlik-5: servis (PIN) oturumunun kuyruktaki ogesi: oturum iptal / suresi dolmus ise oge (ve sonrakiler) duser;
  // sid tasimayan ESKI oge: ogenin zamanindan sonra evde iptal edilen bir servis oturumu varsa duser (requester_access)
  sessionById: RA.SQL.sessionById,
  sessionRevokedSince: RA.SQL.sessionRevokedSince,
});

// Surec geneli "kuyruk bos" onbellegi: REST (safety_service) ve kopru uzlastiricisi ayni sureci paylasir.
const emptyCache = new Map(); // deviceId -> dogrulama zamani (ms)

function markEmpty(deviceId, nowMs) {
  if (emptyCache.size >= EMPTY_MAX) emptyCache.clear();
  emptyCache.set(deviceId, nowMs);
}
/** REST bu cihaz icin kuyruga oge ekledi: sonraki canli state kuyrugu okur. */
function markPending(deviceId) {
  emptyCache.delete(deviceId);
}
function _resetEmptyCache() {
  emptyCache.clear();
}

function isObj(v) {
  return v !== null && typeof v === 'object' && !Array.isArray(v);
}
function stateCfgOf(safetyState) {
  const cfg = isObj(safetyState) && isObj(safetyState.cfg) ? safetyState.cfg : null;
  return cfg && Number.isInteger(cfg.rev) ? { rev: cfg.rev, crc: typeof cfg.crc === 'string' ? cfg.crc : null } : null;
}
/** Pano hirsiz alarmi kurulu mu (son canli state ozeti; Faz 2 incelemesi G-1b). */
function armedOf(safetyState) {
  const arm = isObj(safetyState) && isObj(safetyState.arm) ? safetyState.arm : null;
  return Boolean(arm && typeof arm.mode === 'string' && arm.mode !== 'off');
}
/**
 * Firmware cfg_patch basarisinda last_id yankisi veriyor mu (Faz 2 incelemesi R2): yanki (WP-C1) ve hirsiz katmani (caps 'intrusion')
 * ayni surumde (1.2.1) geldi. Yankili panoda "rev = base_rev + 1" cikarimi yapilmaz (baska kaynakli degisikligi uygulandi sayardi).
 */
function echoesCfgId(caps) {
  return Array.isArray(caps) && caps.includes('intrusion');
}
function short(v) {
  return String(v || '-').slice(0, 8);
}
function errKind(err) {
  const code = err && typeof err.code === 'string' && /^[A-Za-z0-9_]{1,40}$/.test(err.code) ? err.code : null;
  return code || (err && typeof err.name === 'string' && /^[A-Za-z0-9_$]{1,40}$/.test(err.name) ? err.name : 'Error');
}
function defaultCommandId() {
  return crypto.randomBytes(9).toString('base64url');
}

const GAS_LOCAL_TEXT = 'Gaz vanasını açılabilir kılan değişiklik yalnız panonun başında (seri bağlantı) yapılabilir.';
const ARMED_TEXT = 'Alarm kurulu; alarmı zayıflatan değişiklik için önce alarmı kapatın.';
const REJECT_MAP = Object.freeze({
  cfg_invalid: [400, 'CONFIG_INVALID', 'Pano yapılandırmayı geçersiz buldu.'],
  zone_latched: [409, 'ZONE_ALARM_ACTIVE', 'Alarm süren bölgenin yapılandırması değiştirilemez; önce alarmı sonlandırın.'],
  cfg_storage: [507, 'DEVICE_STORAGE_FULL', 'Panonun yapılandırma belleği dolu; kurulumcunuza başvurun.'],
  busy: [503, 'DEVICE_BUSY', 'Pano meşgul; birkaç saniye sonra yeniden deneyin.'],
  gas_local_only: [403, 'GAS_VALVE_LOCAL_ONLY', GAS_LOCAL_TEXT],
  armed: [409, 'INTRUSION_ARMED', ARMED_TEXT],
});
const CHANGED_TEXT = 'Pano yapılandırması bu arada değişti; güncel hali okunup yeniden denenmeli.';
const CHAIN_CONFLICT_TEXT = 'Bekleyen değişikliklerle çelişiyor; kuyruğu iptal edip planı yeniden gönderin.'; // guvenlik-4

class SafetyCfgSync {
  /**
   * @param {object} deps
   * @param {{query:Function, withTransaction:Function}} deps.db
   * @param {(topicId:string, obj:object)=>Promise} deps.publishSys
   * @param {(topicId, id, ms, {uid, cfgRev})=>Promise<object>} deps.expectOutcome
   * @param {(topicId, id)=>void} [deps.cancelAck]
   * @param {()=>boolean} [deps.isConnected]
   * @param {(args)=>Promise} [deps.requestConfig]  alarm servisi requestConfig ({topicId, deviceId, uid, force})
   * @param {(args)=>Promise} [deps.pushInfo]       alarm servisi pushInfo (owner'a safety_info)
   * @param {()=>number} [deps.now] @param {()=>string} [deps.newCommandId] @param {object} [deps.logger]
   */
  constructor(deps = {}) {
    if (!deps.db || typeof deps.db.query !== 'function') throw new TypeError('SafetyCfgSync: db zorunludur');
    this.db = deps.db;
    this._deps = deps;
    this.now = typeof deps.now === 'function' ? deps.now : Date.now;
    this.newCommandId = typeof deps.newCommandId === 'function' ? deps.newCommandId : defaultCommandId;
    this.logger = deps.logger || console;
    this._busy = new Set();
    this._attempts = new Map(); // `${deviceId}|${itemId}` -> {n, first}
    this.counters = { patched: 0, queued: 0, sent: 0, applied: 0, inferred: 0, dropped: 0, errors: 0 };
  }

  _tx(fn) {
    if (typeof this.db.withTransaction === 'function') return this.db.withTransaction((tx) => fn((t, p) => tx.query(t, p)));
    return fn((t, p) => this.db.query(t, p));
  }

  _log(level, message) {
    try {
      const fn = this.logger && (this.logger[level] || this.logger.log);
      if (typeof fn === 'function') fn.call(this.logger, `[SAFETY-CFG] ${message}`);
    } catch (_) {
      /* gunluk hatasi isi bozmasin */
    }
  }

  async _requestConfig(args) {
    try {
      if (typeof this._deps.requestConfig === 'function') await this._deps.requestConfig({ ...args, force: true });
    } catch (_) {
      /* en iyi caba */
    }
  }

  async _audit(q, { event, uid, homeId, actorId = null, role = 'system', ip = null, details }) {
    await q(SQL.audit, [event, uid || null, homeId || null, actorId, role, ip, JSON.stringify(details)]);
  }

  // ===========================================================================
  // REST
  // ===========================================================================
  /**
   * @param {{actor:object, homeId:string, device:{id, device_uuid, is_online, topic_id, caps}, body:object}} p
   */
  async patch({ actor, homeId, device, body }) {
    const caps = Array.isArray(device && device.caps) ? device.caps : [];
    const v = P.validatePatchRequest(body, { caps });
    if (!v.ok) throw httpError(v.status, v.message, v.code);
    if (!caps.includes('cfg')) {
      throw httpError(409, 'Bu pano yazılımı buluttan yapılandırmayı desteklemiyor; pano yazılımını güncelleyin.', 'FIRMWARE_UNSUPPORTED');
    }
    const uid = String(device.device_uuid || '').toUpperCase();
    const id = v.id || this.newCommandId();
    const sys = P.buildSysPayload({ uid, id, baseRev: v.baseRev, patch: v.patch });
    if (P.sysPayloadBytes(sys) > P.MAX_SYS_BYTES) throw httpError(400, 'Yama panonun kabul ettiği boyutu (1024 bayt) aşıyor.', 'PAYLOAD_TOO_LARGE');
    const topicId = device.topic_id;
    const nowMs = this.now();
    const nowIso = new Date(nowMs).toISOString();

    let pre;
    try {
      pre = await this._tx(async (q) => {
        const cr = await q(SQL.lock, [device.id]);
        const row = cr && cr.rows && cr.rows[0];
        if (!row) return { kind: 'not_available' };
        const dr = await q(SQL.device, [device.id]);
        const dev = (dr && dr.rows && dr.rows[0]) || {};
        let st = stateCfgOf(dev.safety_state);
        // guvenlik-3: sahadaki eski firmware yapilandirilmamis panoda state'e cfg yazmaz (present:false); kopya varsa taban
        // kopyanin rev'i olur (pano base_rev'i kendisi dogrular; uyusmazlik cfg_conflict olur).
        if (!st && caps.includes('cfg') && isObj(dev.safety_state) && dev.safety_state.present === false && Number.isInteger(Number(row.rev))) {
          st = { rev: Number(row.rev), crc: typeof row.crc === 'string' ? row.crc : null };
        }
        if (!st) return { kind: 'not_available' };
        const queue = P.parsePending(row.pending);
        const copyRev = Number(row.rev);
        if (P.inflightActive(queue, nowMs)) return { kind: 'pending' };
        queue.inflight = null;
        const next = P.applyPatch(row.body, v.patch);
        const hist = diUseMask(row.body);
        const intrLoose = isIntrusionLoosening(row.body, next, hist);
        const loosening = isLoosening(row.body, next, hist) || intrLoose;
        // Faz 2 incelemesi G-1: bulut yolu gevsetebilir (D.4) ama gaz vanasini uzaktan acilabilir kilamaz (7.2b-8) ve kurulu kipte
        // hirsiz alarmini zayiflatamaz (F2-3). Kopya bayat olabilir: asil karar panoda (gas_local_only / armed).
        const blocked = isGasRelease(row.body, next, hist) ? 'gas_local' : (intrLoose && armedOf(dev.safety_state) ? 'armed' : null);
        if (blocked) {
          await this._audit(q, {
            event: 'safety_config_patch', uid, homeId, actorId: (actor && actor.userId) || null, role: (actor && actor.access) || null,
            ip: (actor && actor.ip) || null,
            details: { op: v.op, item: v.item, target: v.target, loosening: true, result: `rejected_${blocked}`, via: 'cloud', command_id: id },
          });
          return { kind: blocked };
        }
        if (dev.is_online === true) {
          if (queue.items.length > 0) return { kind: 'pending' };
          if (v.baseRev !== st.rev) return { kind: 'changed', st, copyRev };
          queue.inflight = { id, at: nowIso };
          await q(SQL.setPending, [device.id, JSON.stringify(P.serializePending(queue))]);
          return { kind: 'send', loosening, copyRev };
        }
        queue.items = queue.items.filter((it) => !P.isExpired(it, nowMs));
        const expected = P.nextBaseRev(queue, st.rev);
        if (v.baseRev !== expected) return { kind: 'changed', st: { rev: expected, crc: st.crc }, copyRev };
        if (queue.items.length >= P.MAX_PENDING_ITEMS) return { kind: 'full' };
        // guvenlik-4: yeni yama kopya + kuyruktaki yamalar zincirine gore dogrulanir (yeniden numaralanan / bulunamayan
        // hedef, ayni roleye ikinci kimliksiz ekleme): kuyruga ALINMAZ.
        if (P.chainConflict(row.body, queue.items, v.patch)) return { kind: 'chain_conflict' };
        queue.items.push({
          id, base_rev: v.baseRev, patch: v.patch, by: (actor && actor.userId) || null, role: (actor && actor.access) || null, at: nowIso, loosening,
          sid: (actor && actor.sessionId) || null, // guvenlik-5: servis (PIN) oturumu kimligi (iptal edilince oge duser)
        });
        await q(SQL.setPending, [device.id, JSON.stringify(P.serializePending(queue))]);
        await this._audit(q, {
          event: 'safety_config_patch', uid, homeId, actorId: (actor && actor.userId) || null, role: (actor && actor.access) || null,
          ip: (actor && actor.ip) || null,
          details: { op: v.op, item: v.item, target: v.target, loosening, result: 'queued', via: 'cloud', command_id: id },
        });
        return { kind: 'queued', position: queue.items.length };
      });
    } catch (err) {
      this.counters.errors += 1;
      throw err;
    }

    if (pre.kind === 'not_available') {
      await this._requestConfig({ topicId, deviceId: device.id, uid });
      throw httpError(409, 'Pano yapılandırması henüz okunmadı; biraz sonra yeniden deneyin.', 'CONFIG_NOT_AVAILABLE');
    }
    if (pre.kind === 'gas_local') throw httpError(403, GAS_LOCAL_TEXT, 'GAS_VALVE_LOCAL_ONLY');
    if (pre.kind === 'armed') throw httpError(409, ARMED_TEXT, 'INTRUSION_ARMED');
    if (pre.kind === 'pending') throw httpError(409, 'Bu pano için bekleyen yapılandırma değişiklikleri var.', 'CONFIG_PENDING');
    if (pre.kind === 'full') throw httpError(409, 'Bekleyen değişiklik sınırı doldu.', 'CONFIG_QUEUE_FULL');
    if (pre.kind === 'chain_conflict') throw httpError(409, CHAIN_CONFLICT_TEXT, 'CONFIG_CHANGED_ON_DEVICE');
    if (pre.kind === 'changed') {
      if (pre.copyRev !== pre.st.rev) await this._requestConfig({ topicId, deviceId: device.id, uid });
      throw httpError(409, CHANGED_TEXT, 'CONFIG_CHANGED_ON_DEVICE', { data: { rev: pre.st.rev, crc: pre.st.crc, copy_rev: pre.copyRev } });
    }
    if (pre.kind === 'queued') {
      markPending(device.id);
      this.counters.queued += 1;
      return { queued: true, position: pre.position, expires_at: new Date(nowMs + P.PENDING_TTL_MS).toISOString(), command_id: id };
    }

    // Cevrimici gonderim (transaction disinda)
    const outcome = await this._sendAndWait({ topicId, uid, id, baseRev: v.baseRev, sys });
    await this._clearInflight(device.id, id).catch((err) => this._log('warn', `ucus isareti temizlenemedi (${errKind(err)})`));
    if (outcome.publishError) throw httpError(502, 'Komut MQTT broker üzerinden iletilemedi.', 'BROKER_UNAVAILABLE');
    if (outcome.ok === true) {
      this.counters.patched += 1;
      try {
        await this._tx((q) => this._audit(q, {
          event: 'safety_config_patch', uid, homeId, actorId: (actor && actor.userId) || null, role: (actor && actor.access) || null,
          ip: (actor && actor.ip) || null,
          details: { op: v.op, item: v.item, target: v.target, loosening: pre.loosening, result: 'applied', via: 'cloud', command_id: id },
        }));
      } catch (err) {
        this._log('warn', `denetim kaydi yazilamadi ev=${short(homeId)} (${errKind(err)})`);
      }
      await this._requestConfig({ topicId, deviceId: device.id, uid });
      const cfg = outcome.cfg && Number.isInteger(outcome.cfg.rev) ? outcome.cfg : { rev: v.baseRev + 1, crc: null };
      return { applied: true, rev: cfg.rev, crc: cfg.crc || null, command_id: id };
    }
    if (outcome.rejected) {
      const code = String(outcome.rejected);
      if (code === 'cfg_conflict') {
        await this._requestConfig({ topicId, deviceId: device.id, uid });
        const cfg = outcome.cfg || {};
        throw httpError(409, CHANGED_TEXT, 'CONFIG_CHANGED_ON_DEVICE', {
          data: { rev: Number.isInteger(cfg.rev) ? cfg.rev : null, crc: cfg.crc || null, copy_rev: pre.copyRev },
        });
      }
      const m = REJECT_MAP[code];
      if (m) throw httpError(m[0], m[2], m[1]);
      throw httpError(409, 'Pano yapılandırma değişikliğini reddetti.', 'DEVICE_REJECTED', { reason: code });
    }
    return { applied: null, command_id: id };
  }

  /** Bekleyici yayindan ONCE kurulur; yayin hatasi -> bekleyici iptal ({publishError}). ASLA firlatmaz (yayin disi). */
  async _sendAndWait({ topicId, uid, id, baseRev, sys }) {
    const waiter = this._deps.expectOutcome(topicId, id, OUTCOME_TIMEOUT_MS, { uid, cfgRev: baseRev + 1 });
    try {
      await this._deps.publishSys(topicId, sys);
      this.counters.sent += 1;
    } catch (err) {
      try {
        if (typeof this._deps.cancelAck === 'function') this._deps.cancelAck(topicId, id);
      } catch (_) {
        /* yut */
      }
      Promise.resolve(waiter).catch(() => {});
      this._log('warn', `cfg_patch yayinlanamadi (${errKind(err)})`);
      return { ok: false, publishError: true };
    }
    const out = await waiter;
    return out && typeof out === 'object' ? out : { ok: false, timeout: true };
  }

  async _clearInflight(deviceId, id) {
    await this._tx(async (q) => {
      const r = await q(SQL.lock, [deviceId]);
      const row = r && r.rows && r.rows[0];
      if (!row) return;
      const queue = P.parsePending(row.pending);
      if (!queue.inflight || queue.inflight.id !== id) return;
      queue.inflight = null;
      await q(SQL.setPending, [deviceId, JSON.stringify(P.serializePending(queue))]);
    });
  }

  /** DELETE .../safety-config/pending: kuyrugu bosaltir (ucustaki yama etkilenmez; sonucu state'te gorunur). */
  async cancel({ actor, homeId, device }) {
    const uid = String(device.device_uuid || '').toUpperCase();
    const dropped = await this._tx(async (q) => {
      const r = await q(SQL.lock, [device.id]);
      const row = r && r.rows && r.rows[0];
      if (!row) return 0;
      const queue = P.parsePending(row.pending);
      const n = queue.items.length;
      if (n === 0) return 0;
      queue.items = [];
      await q(SQL.setPending, [device.id, JSON.stringify(P.serializePending(queue))]);
      await this._audit(q, {
        event: 'safety_config_pending_dropped', uid, homeId, actorId: (actor && actor.userId) || null, role: (actor && actor.access) || null,
        ip: (actor && actor.ip) || null, details: { reason: 'cancelled', count: n },
      });
      return n;
    });
    if (dropped > 0) this.counters.dropped += dropped;
    return { dropped };
  }

  /** GET ekleri: {state_rev, next_base_rev, pending?} (pending yalniz includePending: safety_config yetenegi). */
  async view({ deviceId, includePending = false }) {
    const r = await this.db.query(SQL.view, [deviceId]);
    const row = (r && r.rows && r.rows[0]) || {};
    const st = stateCfgOf(row.safety_state);
    const queue = P.parsePending(row.pending);
    const out = { state_rev: st ? st.rev : null, next_base_rev: P.nextBaseRev(queue, st ? st.rev : null) };
    if (includePending) out.pending = P.pendingSummary(queue);
    return out;
  }

  // ===========================================================================
  // Kuyruk uzlastirmasi
  // ===========================================================================
  /**
   * Kopru -> uzlastirici: cfg yetenekli panonun CANLI state'i. ASLA firlatmaz.
   * @param {{topicId, homeId, deviceId, uid, caps:string[], summary:object}} p
   */
  async onLiveState({ topicId, homeId, deviceId, uid, caps, summary, lastId = null, cfgId = null } = {}) {
    if (!Array.isArray(caps) || !caps.includes('cfg') || !deviceId || !topicId) return { status: 'skipped' };
    const stateRev = summary && summary.cfg && Number.isInteger(summary.cfg.rev) ? summary.cfg.rev : null;
    if (stateRev === null) return { status: 'skipped' };
    const nowMs = this.now();
    const seen = emptyCache.get(deviceId);
    if (seen !== undefined && nowMs - seen < EMPTY_TTL_MS) return { status: 'empty' };
    if (this._busy.has(deviceId)) return { status: 'busy' };
    this._busy.add(deviceId);
    try {
      return await this._processQueue({
        topicId, homeId, deviceId, uid: String(uid || '').toUpperCase(), stateRev, nowMs, echoes: echoesCfgId(caps), lastId, cfgId,
      });
    } catch (err) {
      this.counters.errors += 1;
      this._log('warn', `kuyruk uzlastirma hatasi ev=${short(homeId)} (${errKind(err)})`);
      return { status: 'error' };
    } finally {
      this._busy.delete(deviceId);
    }
  }

  _attemptKey(deviceId, itemId) {
    return `${deviceId}|${itemId}`;
  }

  _canAttempt(deviceId, itemId, nowMs) {
    const e = this._attempts.get(this._attemptKey(deviceId, itemId));
    if (!e) return true;
    if (nowMs - e.first >= ATTEMPT_WINDOW_MS) {
      this._attempts.delete(this._attemptKey(deviceId, itemId));
      return true;
    }
    return e.n < MAX_SEND_ATTEMPTS;
  }

  _recordAttempt(deviceId, itemId, nowMs) {
    const key = this._attemptKey(deviceId, itemId);
    const e = this._attempts.get(key) || { n: 0, first: nowMs };
    e.n += 1;
    this._attempts.set(key, e);
    if (this._attempts.size > 5000) this._attempts.clear();
  }

  /**
   * guvenlik-5: servis (PIN) oturumunun kuyruktaki ogesi hala gecerli mi? sid varsa oturum satiri (yok / iptal / suresi
   * dolmus -> gecersiz; service_user installer_expires_at kuralıyla tutarli); sid yoksa (eski oge) ogenin zamanindan sonra
   * evde iptal edilen bir servis oturumu varsa gecersiz.
   */
  async _sessionItemOk(q, homeId, item) {
    return RA.sessionOk(q, homeId, { sid: item.sid, at: item.at }, this.now());
  }

  async _firstRevoked(q, homeId, items) {
    const cache = new Map();
    for (let i = 0; i < items.length; i += 1) {
      const by = items[i].by;
      if (!by) {
        // servis (PIN) oturumu (kullanicisiz): oturum iptal edildi / suresi doldu ise oge ve sonrakiler duser (guvenlik-5)
        if (items[i].role !== 'service_session') continue;
        const key = items[i].sid ? `sid:${items[i].sid}` : `at:${items[i].at}`;
        if (!cache.has(key)) cache.set(key, await this._sessionItemOk(q, homeId, items[i]));
        if (!cache.get(key)) return i;
        continue;
      }
      if (!cache.has(by)) cache.set(by, await RA.userAccessOk(q, homeId, by));
      if (!cache.get(by)) return i;
    }
    return -1;
  }

  async _processQueue({ topicId, homeId, deviceId, uid, stateRev, nowMs, echoes = false, lastId = null, cfgId = null }) {
    const nowIso = new Date(nowMs).toISOString();
    const connected = typeof this._deps.isConnected === 'function' ? this._deps.isConnected() : true;
    const plan = await this._tx(async (q) => {
      const r = await q(SQL.lock, [deviceId]);
      const row = r && r.rows && r.rows[0];
      if (!row) return { empty: true };
      const queue = P.parsePending(row.pending);
      if (queue.items.length === 0 && !P.inflightActive(queue, nowMs)) {
        if (row.pending !== null && row.pending !== undefined) await q(SQL.setPending, [deviceId, null]);
        return { empty: true };
      }
      if (P.inflightActive(queue, nowMs)) return { busy: true };
      queue.inflight = null;
      const drops = [];
      const inferred = [];
      const expired = queue.items.filter((it) => P.isExpired(it, nowMs));
      if (expired.length > 0) {
        queue.items = queue.items.filter((it) => !P.isExpired(it, nowMs));
        drops.push({ reason: 'expired', count: expired.length, push: false });
      }
      const rev = await this._firstRevoked(q, homeId, queue.items);
      if (rev >= 0) {
        drops.push({ reason: 'revoked', count: queue.items.length - rev, push: false });
        queue.items = queue.items.slice(0, rev);
      }
      let send = null;
      while (queue.items.length > 0) {
        const head = queue.items[0];
        // yanki kacti ama pano uyguladi: cift uygulama yok. Yankili firmware'de (R2) yalniz state.last_id bas ogeyse ya da (sko-5,
        // C6; firmware 1.3.2) state.cfg.safety.id bas ogeyse (araya giren komut last_id'yi degistirmis olabilir); aksi halde rev
        // artisi baska kaynaktandir (LAN/CLI) ve asagidaki "pano kazanir" kurali isler. cfgId yoksa bugunku davranis.
        if (head.sent_at && stateRev === head.base_rev + 1 && (!echoes || lastId === head.id || (cfgId !== null && cfgId === head.id))) {
          inferred.push(head);
          queue.items.shift();
          continue;
        }
        if (head.base_rev !== stateRev) {
          drops.push({ reason: 'conflict', count: queue.items.length, push: true }); // pano kazanir (K5)
          queue.items = [];
          break;
        }
        if (!connected || !this._canAttempt(deviceId, head.id, nowMs)) break;
        head.sent_at = nowIso;
        queue.inflight = { id: head.id, at: nowIso };
        send = { ...head };
        break;
      }
      await q(SQL.setPending, [deviceId, JSON.stringify(P.serializePending(queue))]);
      for (const d of drops) {
        await this._audit(q, { event: 'safety_config_pending_dropped', uid, homeId, details: { reason: d.reason, count: d.count } });
      }
      for (const it of inferred) {
        await this._audit(q, {
          event: 'safety_config_patch', uid, homeId, actorId: it.by || null, role: it.role || null,
          details: { ...this._itemDetails(it), result: 'applied_inferred', via: 'queue', command_id: it.id },
        });
      }
      return { send, drops, inferred, remaining: queue.items.length };
    });

    if (plan.empty) {
      markEmpty(deviceId, nowMs);
      return { status: 'empty' };
    }
    if (plan.busy) return { status: 'inflight' };
    this.counters.inferred += plan.inferred.length;
    for (const d of plan.drops) {
      this.counters.dropped += d.count;
      if (d.push) await this._pushDropped({ homeId, deviceId, uid });
    }
    if (plan.inferred.length > 0) await this._requestConfig({ topicId, deviceId, uid });
    if (!plan.send) {
      if (plan.remaining === 0) markEmpty(deviceId, nowMs);
      return { status: 'applied', sent: 0, dropped: plan.drops.length, inferred: plan.inferred.length };
    }

    const head = plan.send;
    const sys = P.buildSysPayload({ uid, id: head.id, baseRev: head.base_rev, patch: head.patch });
    const outcome = await this._sendAndWait({ topicId, uid, id: head.id, baseRev: head.base_rev, sys });
    let result = 'kept';
    let dropPush = false;
    const after = await this._tx(async (q) => {
      const r = await q(SQL.lock, [deviceId]);
      const row = r && r.rows && r.rows[0];
      if (!row) return 0;
      const queue = P.parsePending(row.pending);
      if (queue.inflight && queue.inflight.id === head.id) queue.inflight = null;
      const isHead = queue.items.length > 0 && queue.items[0].id === head.id;
      if (isHead && outcome.ok === true) {
        queue.items.shift();
        result = 'applied';
        await this._audit(q, {
          event: 'safety_config_patch', uid, homeId, actorId: head.by || null, role: head.role || null,
          details: { ...this._itemDetails(head), result: 'applied', via: 'queue', command_id: head.id },
        });
      } else if (isHead && outcome.rejected && DROP_CODES.includes(String(outcome.rejected))) {
        const n = queue.items.length;
        queue.items = [];
        result = 'dropped';
        dropPush = true;
        await this._audit(q, { event: 'safety_config_pending_dropped', uid, homeId, details: { reason: String(outcome.rejected), count: n } });
        this.counters.dropped += n;
      } else if (isHead && (outcome.rejected || outcome.publishError)) {
        delete queue.items[0].sent_at; // pano uygulamadi (ret) / hic gitmedi: "uygulandi" cikarimi yapilmasin
      }
      await q(SQL.setPending, [deviceId, JSON.stringify(P.serializePending(queue))]);
      return queue.items.length;
    });
    if (result === 'applied') {
      this.counters.applied += 1;
      this._attempts.delete(this._attemptKey(deviceId, head.id));
      await this._requestConfig({ topicId, deviceId, uid });
    } else if (result === 'kept') {
      this._recordAttempt(deviceId, head.id, nowMs);
    }
    if (dropPush) await this._pushDropped({ homeId, deviceId, uid });
    if (after === 0) markEmpty(deviceId, nowMs);
    this._log('log', `kuyruk ev=${short(homeId)} oge=${result} kalan=${after}`);
    return { status: 'applied', sent: 1, result, remaining: after };
  }

  _itemDetails(it) {
    const op = isObj(it.patch) && isObj(it.patch.set) ? 'set' : 'del';
    const inner = (isObj(it.patch) && it.patch[op]) || {};
    const item = Object.keys(inner)[0] || null;
    return { op, item, target: P.targetOf(item, inner[item]), loosening: it.loosening === true };
  }

  async _pushDropped({ homeId, deviceId, uid }) {
    try {
      if (typeof this._deps.pushInfo === 'function') {
        await this._deps.pushInfo({ homeId, deviceId, deviceUuid: uid, alarmId: null, reason: 'cfg_pending_dropped' });
      }
    } catch (_) {
      /* bilgi push'u en iyi caba */
    }
  }

  stats() {
    return { ...this.counters, busy: this._busy.size };
  }
}

module.exports = {
  SafetyCfgSync,
  SQL,
  markPending,
  _resetEmptyCache,
  constants: Object.freeze({ OUTCOME_TIMEOUT_MS, MAX_SEND_ATTEMPTS, ATTEMPT_WINDOW_MS, EMPTY_TTL_MS, DROP_CODES }),
};
