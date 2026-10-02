'use strict';

// ==============================================================================
// AHBU Akilli Ev - Kontrol noktasi (endpoint) servisi (WP-B, B8)
//
//   GET  /homes/:homeId/endpoints            durum gorme (tum roller)
//   PUT  /homes/:homeId/endpoints/:id        kanal adi/oda + panjur kalibrasyonu (owner/staff/servis oturumu/super)
//   POST /homes/:homeId/endpoints/:id/control  tek uc nokta komutu (firmware sozlugune cevrilip sendCommand'dan gecer)
//
// Panjur kalibrasyonu (shutter_duration_sec 1..300): once cihaza `set_runtime` YAYINLANIR; DB yalnizca
// yayin basarili olduktan sonra guncellenir (DB ile cihaz sapmaz). Cevrimdisi -> 409 DEVICE_OFFLINE.
// ==============================================================================

const crypto = require('crypto');
const { isUuid } = require('../utils/helpers');
const { httpError } = require('../utils/http_errors');
const { can } = require('../utils/role_matrix');
const { RUNTIME_MIN_SEC, RUNTIME_MAX_SEC } = require('../utils/command_schema');

const NAME_MAX = 100;
const ROOM_MAX = 50;
// Kozmetik tip gecisi: yalnizca light <-> plug. Panjur/darbe donanim anlamlidir, DB'den degistirilemez.
const COSMETIC_TYPES = Object.freeze(['light', 'plug']);
// Eski istemcilerin gonderdigi, ARTIK DEGISTIRILEMEYEN alanlar (klemens eslemesi / kimlikler).
const IMMUTABLE_FIELDS = Object.freeze(['channel', 'channel_index', 'device_id', 'shutter_pair_index']);

function trimmedText(value, max, label) {
  if (typeof value !== 'string') throw httpError(400, `${label} metin olmalı.`, 'VALIDATION');
  const t = value.trim();
  if (t.length === 0 || t.length > max) {
    throw httpError(400, `${label} 1 ile ${max} karakter arasında olmalı.`, 'VALIDATION');
  }
  return t;
}

/** Eski/uyumlu istemciler icin takma adlar eklenir (channel, endpoint_type, shutter_position, online). */
function presentEndpoint(row) {
  return {
    id: row.id,
    home_id: row.home_id,
    device_id: row.device_id,
    device_uuid: row.device_uuid || null,
    channel_index: row.channel_index,
    name: row.name,
    type: row.type,
    room: row.room,
    shutter_pair_index: row.shutter_pair_index,
    shutter_duration_sec: row.shutter_duration_sec,
    current_state: row.current_state === true,
    current_position: row.current_position,
    device_online: row.device_online === true,
    created_at: row.created_at,
    updated_at: row.updated_at,
    // takma adlar (geri uyumluluk)
    channel: row.channel_index,
    endpoint_type: row.type,
    shutter_position: row.current_position,
    online: row.device_online === true,
  };
}

class EndpointService {
  /** @param {object} [deps] test icin: { db, deviceService, mqttBridge } */
  constructor(deps = {}) {
    this._deps = deps;
  }

  get db() {
    return this._deps.db || require('../db');
  }
  get deviceService() {
    return this._deps.deviceService || require('./device_service');
  }
  get bridge() {
    return this._deps.mqttBridge || require('../mqtt_bridge');
  }

  async getEndpointsByHome(homeId) {
    if (!isUuid(homeId)) throw httpError(400, 'Geçersiz daire kimliği (home_id).', 'VALIDATION');
    const res = await this.db.query(
      `SELECT e.id, e.home_id, e.device_id, e.channel_index, e.name, e.type, e.room, e.shutter_pair_index,
              e.shutter_duration_sec, e.current_state, e.current_position, e.created_at, e.updated_at,
              d.device_uuid, COALESCE(d.is_online, FALSE) AS device_online
         FROM endpoints e
         LEFT JOIN devices d ON d.id = e.device_id
        WHERE e.home_id = $1
        ORDER BY e.device_id ASC, e.channel_index ASC`,
      [homeId]
    );
    return res.rows.map(presentEndpoint);
  }

  /**
   * Kanal adi / oda / (light<->plug) tip ve panjur kalibrasyonu.
   * @param {{actor:object, homeId:string, endpointId:string, patch:object}} p
   */
  async updateEndpoint({ actor, homeId, endpointId, patch }) {
    if (!can('calibrate', actor && actor.access)) {
      throw httpError(403, 'Kanal adı ve panjur kalibrasyonu yalnızca ev sahibi veya yetkili servis tarafından değiştirilebilir.', 'FORBIDDEN');
    }
    if (!isUuid(homeId)) throw httpError(400, 'Geçersiz daire kimliği (home_id).', 'VALIDATION');
    if (!isUuid(endpointId)) throw httpError(400, 'Geçersiz kontrol noktası kimliği.', 'VALIDATION');
    if (!patch || typeof patch !== 'object' || Array.isArray(patch)) {
      throw httpError(400, 'Güncellenecek alanlar bir nesne olmalı.', 'VALIDATION');
    }

    const forbidden = IMMUTABLE_FIELDS.find((k) => Object.prototype.hasOwnProperty.call(patch, k));
    if (forbidden) {
      throw httpError(400, 'Kanal eşlemesi (klemens) bu uçtan değiştirilemez.', 'VALIDATION');
    }

    const has = (k) => Object.prototype.hasOwnProperty.call(patch, k) && patch[k] !== undefined && patch[k] !== null;
    const name = has('name') ? trimmedText(patch.name, NAME_MAX, 'Ad') : null;
    const room = has('room') ? trimmedText(patch.room, ROOM_MAX, 'Oda') : null;
    const type = has('type') ? String(patch.type) : null;
    const durationRaw = has('shutter_duration_sec')
      ? patch.shutter_duration_sec
      : has('shutterDurationSec')
      ? patch.shutterDurationSec
      : undefined;

    let durationSec = null;
    if (durationRaw !== undefined) {
      if (typeof durationRaw !== 'number' || !Number.isInteger(durationRaw) ||
          durationRaw < RUNTIME_MIN_SEC || durationRaw > RUNTIME_MAX_SEC) {
        throw httpError(
          400,
          `Panjur çalışma süresi ${RUNTIME_MIN_SEC} ile ${RUNTIME_MAX_SEC} saniye arasında bir tamsayı olmalı.`,
          'VALIDATION'
        );
      }
      durationSec = durationRaw;
    }

    if (name === null && room === null && type === null && durationSec === null) {
      throw httpError(400, 'Güncellenecek alan yok (name, room, type veya shutter_duration_sec).', 'VALIDATION');
    }

    const epRes = await this.db.query(
      `SELECT e.id, e.device_id, e.type, e.shutter_pair_index,
              COALESCE(d.is_online, FALSE) AS is_online, h.mqtt_username AS topic_id
         FROM endpoints e
         JOIN devices d ON d.id = e.device_id
         JOIN homes h ON h.id = e.home_id
        WHERE e.id = $1 AND e.home_id = $2`,
      [endpointId, homeId]
    );
    if (epRes.rows.length === 0) throw httpError(404, 'Kontrol noktası bulunamadı.', 'NOT_FOUND');
    const ep = epRes.rows[0];

    if (type !== null && type !== ep.type) {
      if (!COSMETIC_TYPES.includes(type) || !COSMETIC_TYPES.includes(ep.type)) {
        throw httpError(400, 'Kanal tipi yalnızca lamba ile priz arasında değiştirilebilir.', 'VALIDATION');
      }
    }

    let commandId = null;
    if (durationSec !== null) {
      if (ep.type !== 'shutter' || !ep.shutter_pair_index) {
        throw httpError(400, 'Çalışma süresi yalnızca panjur kanalları için ayarlanabilir.', 'VALIDATION');
      }
      if (!ep.is_online) {
        throw httpError(409, 'Cihaz çevrimdışı; panjur süresi cihaza iletilemedi.', 'DEVICE_OFFLINE', { device_online: false });
      }
      commandId = crypto.randomBytes(9).toString('base64url');
      // Yayin hatasi YUTULMAZ: DB cihazdan once degismez.
      await this._publishRuntime(ep.topic_id, ep.shutter_pair_index, durationSec, commandId);
    }

    const updated = await this.db.withTransaction(async (tx) => {
      const res = await tx.query(
        `UPDATE endpoints
            SET name = COALESCE($1, name),
                room = COALESCE($2, room),
                type = COALESCE($3, type),
                updated_at = CURRENT_TIMESTAMP
          WHERE id = $4 AND home_id = $5
          RETURNING id`,
        [name, room, type, endpointId, homeId]
      );
      if (res.rows.length === 0) throw httpError(404, 'Kontrol noktası bulunamadı.', 'NOT_FOUND');

      if (durationSec !== null) {
        // Panjur cifti (yukari + asagi satiri) ayni sureyi paylasir.
        await tx.query(
          `UPDATE endpoints SET shutter_duration_sec = $1, updated_at = CURRENT_TIMESTAMP
            WHERE home_id = $2 AND device_id = $3 AND shutter_pair_index = $4`,
          [durationSec, homeId, ep.device_id, ep.shutter_pair_index]
        );
      }

      const out = await tx.query(
        `SELECT e.id, e.home_id, e.device_id, e.channel_index, e.name, e.type, e.room, e.shutter_pair_index,
                e.shutter_duration_sec, e.current_state, e.current_position, e.created_at, e.updated_at,
                d.device_uuid, COALESCE(d.is_online, FALSE) AS device_online
           FROM endpoints e
           LEFT JOIN devices d ON d.id = e.device_id
          WHERE e.id = $1`,
        [endpointId]
      );
      return out.rows[0];
    });

    const result = presentEndpoint(updated);
    if (commandId) {
      result.delivered = true;
      result.command_id = commandId;
    }
    return result;
  }

  async _publishRuntime(topicId, pair, sec, commandId) {
    const bridge = this.bridge;
    if (typeof bridge.isConnected === 'function' && !bridge.isConnected()) {
      throw httpError(502, 'MQTT broker bağlantısı yok; panjur süresi cihaza iletilemedi.', 'BROKER_UNAVAILABLE');
    }
    try {
      await bridge.publishCommand(topicId, { cmd: 'set_runtime', shutter: pair, sec, id: commandId });
    } catch (err) {
      console.error('[ENDPOINT] set_runtime yayinlanamadi:', err && err.message);
      throw httpError(502, 'Panjur süresi MQTT broker üzerinden iletilemedi.', 'BROKER_UNAVAILABLE');
    }
  }

  /**
   * Tek uc noktaya komut: istek govdesi ({cmd|command, pos|value, state}) firmware sozlugune
   * (CONTRACTS §2.3) cevrilir ve deviceService.sendCommand'dan gecer (sema + rol + cevrimdisi + yayin).
   */
  async controlEndpoint({ actor, homeId, endpointId, commandData }) {
    if (!isUuid(homeId)) throw httpError(400, 'Geçersiz daire kimliği (home_id).', 'VALIDATION');
    if (!isUuid(endpointId)) throw httpError(400, 'Geçersiz kontrol noktası kimliği.', 'VALIDATION');
    if (!commandData || typeof commandData !== 'object' || Array.isArray(commandData)) {
      throw httpError(400, 'Komut gövdesi bir nesne olmalı.', 'VALIDATION');
    }

    const epRes = await this.db.query(
      'SELECT id, device_id, type, channel_index, shutter_pair_index FROM endpoints WHERE id = $1 AND home_id = $2',
      [endpointId, homeId]
    );
    if (epRes.rows.length === 0) throw httpError(404, 'Kontrol noktası bulunamadı.', 'NOT_FOUND');
    const ep = epRes.rows[0];

    const cmd = commandData.cmd !== undefined ? commandData.cmd : commandData.command;
    const toInt = (v) => (typeof v === 'string' && /^\d{1,3}$/.test(v.trim()) ? parseInt(v, 10) : v);
    const toBool = (v) => (v === 'true' ? true : v === 'false' ? false : v);

    let command = null;
    if (ep.type === 'shutter') {
      const pair = ep.shutter_pair_index || Math.ceil(ep.channel_index / 2);
      if (commandData.pos !== undefined) {
        command = { shutter: pair, pos: toInt(commandData.pos) };
      } else if ((cmd === 'pos' || cmd === 'position') && commandData.value !== undefined) {
        command = { shutter: pair, pos: toInt(commandData.value) };
      } else if (cmd !== undefined) {
        command = { shutter: pair, cmd };
      }
    } else if (cmd === 'toggle') {
      command = { relay: ep.channel_index, cmd: 'toggle' };
    } else if (commandData.state !== undefined) {
      command = { relay: ep.channel_index, state: toBool(commandData.state) };
    } else if (cmd === 'on' || cmd === 'off') {
      command = { relay: ep.channel_index, state: cmd === 'on' };
    }

    if (!command) throw httpError(400, 'Geçerli bir komut belirtilmedi.', 'VALIDATION');

    return this.deviceService.sendCommand({
      actor,
      homeId,
      deviceRef: ep.device_id,
      command,
    });
  }
}

const instance = new EndpointService();

module.exports = instance;
module.exports.EndpointService = EndpointService;
