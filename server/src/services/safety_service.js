'use strict';

// ==============================================================================
// AHBU Akilli Ev - Guvenlik rotalari servisi (alarm listesi, onay, eylemci, bolge testi)   [CONTRACTS §1.5d]
// ==============================================================================
//
// Tasarim: docs/superpowers/specs/2026-10-06-guvenlik-iklim-senaryo-mimarisi-design.md §5.2.4.
// Komutlar TEK hattan gecer: DeviceService.sendCommand (sema + rol matrisi + hedef denetimi + cevrimdisi 409 + yayin
// + hedef uid'nin onay/ret yankisi). Bu servis yalniz komutu ALARM SATIRINDAN / cihaz kaydindan kurar:
//   - alarm onayi: zone ve aid alarm satirindan gelir [Y-9] (kullanicinin gormedigi yeni alarm onaylanmaz:
//     firmware `stale_ack` doner); uid cihazin device_uuid'sidir.
//   - pano cevrimdisiysa onay ISTEGI kaydedilir (alarms.ack_requested_*); uzlastirici pano donunce YALNIZ ayni aid ile
//     iletir. Vana acma ASLA kuyruga alinmaz (cevrimdisi -> 409).
// Faz 2 (tasarim "Faz 2 tasarimi"): hirsiz alarmi kipi (armDevice, F2.B) ve buluttan yapilandirma yamasi
//   (patchSafetyConfig / cancelSafetyConfigPending, GET ekleri; mantik services/safety_cfg_sync.js, F2.D).

const { httpError } = require('../utils/http_errors');
const { can } = require('../utils/role_matrix');

const LIST_STATES = Object.freeze(['open', 'all']);
const OPEN_STATUSES = Object.freeze(['latched', 'fault', 'silenced']);
const ID_RE = /^[1-9][0-9]{0,17}$/;

/** Istemcinin komut kimligi (istege bagli): verilmisse komuta eklenir; bicimini komut semasi denetler (gecersiz -> 400). */
function withCommandId(command, commandId) {
  return commandId === undefined || commandId === null ? command : { ...command, id: commandId };
}

class SafetyService {
  /** @param {{deviceService?, alarmService?, db?}} [deps] test enjeksiyonu */
  constructor(deps = {}) {
    this._deps = deps;
    this._alarms = null;
  }

  get deviceService() {
    return this._deps.deviceService || require('./device_service');
  }

  /**
   * Buluttan yapilandirma yamasi (F2.D). Kopru tekilinin yayin/bekleyici yollarini ve alarm servisinin cfg_get sinirini
   * paylasir. Test enjeksiyonunda (alarmService verilip db verilmezse) null: GET ekleri atlanir.
   */
  get cfgSync() {
    if (this._deps.cfgSync) return this._deps.cfgSync;
    if (this._deps.alarmService && !this._deps.db) return null;
    if (!this._cfgSync) {
      const { SafetyCfgSync } = require('./safety_cfg_sync');
      const bridge = require('../mqtt_bridge');
      this._cfgSync = new SafetyCfgSync({
        db: this._deps.db || require('../db'),
        publishSys: (t, o) => bridge.publishSys(t, o),
        expectOutcome: (...a) => bridge.expectOutcome(...a),
        cancelAck: (t, id) => bridge.cancelAck(t, id),
        isConnected: () => (typeof bridge.isConnected === 'function' ? bridge.isConnected() : false),
        requestConfig: (a) => (typeof bridge.requestSafetyConfig === 'function' ? bridge.requestSafetyConfig(a) : null),
      });
    }
    return this._cfgSync;
  }

  /** Durumsuz alarm sorgulari (liste, satir, onay istegi): ayri ornek; olay hatti kopruye aittir. */
  get alarms() {
    if (this._deps.alarmService) return this._deps.alarmService;
    if (!this._alarms) {
      const { createAlarmService } = require('./alarm_service');
      const bridge = require('../mqtt_bridge');
      this._alarms = createAlarmService({
        db: this._deps.db || require('../db'),
        publishCommand: (t, c) => bridge.publishCommand(t, c),
        isConnected: () => (typeof bridge.isConnected === 'function' ? bridge.isConnected() : false),
      });
    }
    return this._alarms;
  }

  /** GET /homes/:homeId/alarms?state=open|all&before=<id>&limit=<1..200> */
  async listAlarms({ homeId, state = 'open', before = null, limit = 50 }) {
    const st = state === undefined || state === null || state === '' ? 'open' : state;
    if (!LIST_STATES.includes(st)) throw httpError(400, '"state" yalnız "open" ya da "all" olabilir.', 'VALIDATION');
    if (before !== null && before !== undefined && before !== '' && !ID_RE.test(String(before))) {
      throw httpError(400, '"before" bir alarm kimliği (pozitif tamsayı) olmalı.', 'VALIDATION');
    }
    const n = limit === undefined || limit === null ? 50 : limit;
    if (!Number.isInteger(n) || n < 1 || n > 200) throw httpError(400, '"limit" 1 ile 200 arasında olmalı.', 'VALIDATION');
    return this.alarms.listAlarms({ homeId, state: st, before: before === '' ? null : before, limit: n });
  }

  /** POST /homes/:homeId/alarms/:alarmId/ack */
  async ackAlarm({ actor, homeId, alarmId, commandId }) {
    if (!can('safety_ack', actor && actor.access)) throw httpError(403, 'Alarmı onaylama yetkiniz yok.', 'FORBIDDEN');
    if (typeof alarmId !== 'string' || !ID_RE.test(alarmId)) throw httpError(400, 'Geçersiz alarm kimliği.', 'VALIDATION');
    const row = await this.alarms.getAlarm({ alarmId, homeId });
    if (!row) throw httpError(404, 'Alarm bulunamadı.', 'NOT_FOUND');
    if (!OPEN_STATUSES.includes(row.status)) throw httpError(409, 'Alarm zaten kapanmış.', 'ALARM_NOT_OPEN');
    if (row.kind === 'intrusion') {
      // F2.B.7: hirsiz alarmi onaylanmaz, kip cozulerek kapatilir (POST .../devices/:id/arm {mode:'off'}).
      throw httpError(409, 'Hırsız alarmı onaylanmaz, çözülür.', 'ALARM_USE_DISARM');
    }
    if (!row.is_online) {
      const queued = await this.alarms.requestAck({
        alarmId,
        homeId,
        userId: (actor && actor.userId) || null,
        sessionId: (actor && actor.sessionId) || null, // sko-1: servis (PIN) oturumu; teslimden once gecerliligi denetlenir
      });
      throw httpError(409, 'Pano çevrimdışı; onay pano bağlanınca (aynı alarm sürüyorsa) iletilecek.', 'DEVICE_OFFLINE', {
        device_online: false,
        ack_queued: queued === true,
      });
    }
    const result = await this.deviceService.sendCommand({
      actor,
      homeId,
      deviceRef: row.device_id,
      command: withCommandId(
        { cmd: 'alarm_ack', zone: Number(row.zone), aid: row.aid, uid: String(row.device_uuid || '').toUpperCase() },
        commandId
      ),
    });
    if (result && result.applied === true) await this.alarms.markAcked({ alarmId, userId: (actor && actor.userId) || null });
    return { ...result, alarm_id: Number(alarmId) };
  }

  async _uidOf(homeId, deviceRef) {
    const ref = typeof deviceRef === 'string' ? deviceRef.trim() : '';
    if (!ref) throw httpError(400, 'Cihaz kimliği zorunludur.', 'VALIDATION');
    const isUuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(ref);
    const device = await this.deviceService._findHomeDevice(homeId, isUuid ? { id: ref } : { uuid: ref.toUpperCase() });
    return { ref, uid: String(device.device_uuid || '').toUpperCase() };
  }

  /**
   * GET /homes/:homeId/devices/:deviceId/safety-config: panonun yapilandirma kopyasi (cfg_dump; sensor/eylemci/bolge
   * ADLARI yalniz burada, state'te yok [B12]). Bicim panonun GET /api/safety/config yanitiyla aynidir (+ device_uuid,
   * updated_at). Kopya henuz gelmediyse 404 CONFIG_NOT_AVAILABLE (sunucu farki gorunce cfg_get ister).
   */
  async getSafetyConfig({ actor, homeId, deviceRef }) {
    const ref = typeof deviceRef === 'string' ? deviceRef.trim() : '';
    if (!ref) throw httpError(400, 'Cihaz kimliği zorunludur.', 'VALIDATION');
    const isUuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(ref);
    const device = await this.deviceService._findHomeDevice(homeId, isUuid ? { id: ref } : { uuid: ref.toUpperCase() });
    const cfg = await this.alarms.getConfig({ deviceId: device.id, module: 'safety' });
    if (!cfg) {
      // guvenlik-3: kopya yok -> panodan iste (cfg_get, en iyi caba; hata yutulur), yine 404 (istemci kisa aralikla yeniden okur)
      try {
        const sync = this.cfgSync;
        if (sync && typeof sync._requestConfig === 'function') {
          await sync._requestConfig({ topicId: device.topic_id, deviceId: device.id, uid: String(device.device_uuid || '').toUpperCase() });
        }
      } catch (_) {
        /* en iyi caba */
      }
      throw httpError(404, 'Panonun güvenlik yapılandırması henüz sunucuya ulaşmadı.', 'CONFIG_NOT_AVAILABLE');
    }
    const out = { device_uuid: String(device.device_uuid || '').toUpperCase(), ...cfg };
    // Faz 2 F2.D.6: state_rev (panonun son bildirdigi rev), next_base_rev (kuyruk varsa son oge + 1) ve bekleyen ozeti
    // (yalniz safety_config yetkilisine; deger/ad icermez).
    const sync = this.cfgSync;
    if (sync) Object.assign(out, await sync.view({ deviceId: device.id, includePending: can('safety_config', actor && actor.access) }));
    return out;
  }

  /** POST /homes/:homeId/devices/:deviceId/safety-config (F2.D.1): tek ogelik yama; 200 uygulandi / 202 kuyruk ya da sonuc yok. */
  async patchSafetyConfig({ actor, homeId, deviceRef, body }) {
    if (!can('safety_config', actor && actor.access)) throw httpError(403, 'Güvenlik yapılandırmasını değiştirme yetkiniz yok.', 'FORBIDDEN');
    const device = await this._deviceOf(homeId, deviceRef);
    return this.cfgSync.patch({ actor, homeId, device, body });
  }

  /** DELETE /homes/:homeId/devices/:deviceId/safety-config/pending (F2.D.2): {dropped: n}. */
  async cancelSafetyConfigPending({ actor, homeId, deviceRef }) {
    if (!can('safety_config', actor && actor.access)) throw httpError(403, 'Güvenlik yapılandırmasını değiştirme yetkiniz yok.', 'FORBIDDEN');
    const device = await this._deviceOf(homeId, deviceRef);
    return this.cfgSync.cancel({ actor, homeId, device });
  }

  async _deviceOf(homeId, deviceRef) {
    const ref = typeof deviceRef === 'string' ? deviceRef.trim() : '';
    if (!ref) throw httpError(400, 'Cihaz kimliği zorunludur.', 'VALIDATION');
    const isUuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(ref);
    return this.deviceService._findHomeDevice(homeId, isUuid ? { id: ref } : { uuid: ref.toUpperCase() });
  }

  /** POST /homes/:homeId/devices/:deviceId/actuators/:actuatorId { to } */
  async controlActuator({ actor, homeId, deviceRef, actuatorId, to, commandId }) {
    if (typeof to !== 'string') throw httpError(400, 'Hedef durum (to) zorunludur: open | closed | on | off.', 'VALIDATION');
    const { ref, uid } = await this._uidOf(homeId, deviceRef);
    return this.deviceService.sendCommand({
      actor,
      homeId,
      deviceRef: ref,
      command: withCommandId({ actuator: actuatorId, to, uid }, commandId),
    });
  }

  /**
   * POST /homes/:homeId/devices/:deviceId/arm { mode, id? } (Faz 2 F2.B.7): hirsiz alarmi kurma (away|home) / cozme (off).
   * Yetki safety_arm (YALNIZ owner/resident). caps 'intrusion' yoksa 409 FIRMWARE_UNSUPPORTED; cevrimdisi 409 DEVICE_OFFLINE
   * (KUYRUGA ALINMAZ); last_rej -> 409 DEVICE_REJECTED reason not_ready|unsupported. Yanit {delivered, applied, command_id}.
   */
  async armDevice({ actor, homeId, deviceRef, mode, commandId }) {
    if (!can('safety_arm', actor && actor.access)) throw httpError(403, 'Alarm kipini değiştirme yetkiniz yok.', 'FORBIDDEN');
    if (typeof mode !== 'string') throw httpError(400, 'Alarm kipi (mode) zorunludur: away | home | off.', 'VALIDATION');
    const { ref, uid } = await this._uidOf(homeId, deviceRef);
    return this.deviceService.sendCommand({
      actor,
      homeId,
      deviceRef: ref,
      command: withCommandId({ cmd: 'safety_arm', mode, uid }, commandId),
    });
  }

  /** POST /homes/:homeId/devices/:deviceId/alarm-test { zone } */
  async testZone({ actor, homeId, deviceRef, zone, commandId }) {
    const { ref, uid } = await this._uidOf(homeId, deviceRef);
    return this.deviceService.sendCommand({
      actor,
      homeId,
      deviceRef: ref,
      command: withCommandId({ cmd: 'alarm_test', zone, uid }, commandId),
    });
  }
}

const instance = new SafetyService();

module.exports = instance;
module.exports.SafetyService = SafetyService;
