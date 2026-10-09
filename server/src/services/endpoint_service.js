'use strict';

// ==============================================================================
// AHBU Akilli Ev - Kontrol noktasi (endpoint) servisi (WP-B, B8)
//
//   GET  /homes/:homeId/endpoints            durum gorme (tum roller)
//   PUT  /homes/:homeId/endpoints/:id        kanal adi/oda + panjur kalibrasyonu (owner/staff/servis oturumu/super)
//   POST /homes/:homeId/endpoints/:id/control  tek uc nokta komutu (firmware sozlugune cevrilip sendCommand'dan gecer)
//
// Panjur kalibrasyonu (shutter_duration_sec 1..300): once cihaza `set_runtime` YAYINLANIR ve cihaz ONAYI beklenir
// (DAIRE-03): firmware basarili komutta state.last_id'yi komut kimligine esitler; panjur hareket halindeyken / cift
// yapilandirilmamisken komutu REDDEDER ve last_id degismez. Onay RUNTIME_ACK_TIMEOUT_MS icinde gelmezse 409 CONFLICT
// ve DB'ye YAZILMAZ; DB yalnizca pano komutu uyguladiktan sonra guncellenir (DB ile cihaz sapmaz).
// Cevrimdisi -> 409 DEVICE_OFFLINE.
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
// Kilitsiz okumadan sonra kanal yerlesimi (esitleme) degistiyse.
const TYPE_CHANGED_MESSAGE = 'Kanal tipi değişti; listeyi yenileyin.';
// set_runtime cihaz onayi (state.last_id yankisi) bekleme suresi. Firmware basarili komutu hemen (~0,25 sn birlestirme)
// yayinlar; istemci zaman asimi (10 sn) yayin (en cok 5 sn) + bu bekleme icine sigar.
const RUNTIME_ACK_TIMEOUT_MS = 4000;
const RUNTIME_NOT_APPLIED_MESSAGE =
  'Pano panjur süresini uygulamadı (panjur hareket halinde olabilir). Panjuru durdurup yeniden deneyin.';

/**
 * Kilit altindaki satirlarda hedef hala `pair` numarali panjurun bir yonu mu ve cift tam (iki panjur satiri) mi?
 * @param {Array<{id:string, type:string, shutter_pair_index:number|null}>} rows cihazin kilitli satirlari
 */
function isSamePairLocked(rows, endpointId, pair) {
  // uuid karsilastirmasi harf duyarsiz (PG uuid'i kucuk harfle dondurur; istemci buyuk harfle gonderebilir)
  const wanted = String(endpointId).toLowerCase();
  const target = rows.find((r) => String(r.id).toLowerCase() === wanted);
  if (!target || target.type !== 'shutter' || target.shutter_pair_index !== pair) return false;
  const mates = rows.filter((r) => r.shutter_pair_index === pair);
  return mates.length === 2 && mates.every((r) => r.type === 'shutter');
}

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
    // Guvenlik/K4 (WP-S1/S2, migration 033): kolon sorgudan geldiyse eklenir (eski sorgu/sahte satirda anahtar yok)
    ...(row.actuator_type !== undefined ? { actuator_type: row.actuator_type || null } : {}),
    ...(row.dimmable !== undefined ? { dimmable: row.dimmable === true } : {}),
    ...(row.dimmer_source !== undefined ? { dimmer_source: row.dimmer_source || null } : {}),
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
              e.actuator_type, e.dimmable, e.dimmer_source,
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

    // Tip yalnizca kozmetik bir degerle yazilir; ayni tip no-op (or. shutter) icin tip YAZILMAZ (NULL).
    const typeParam = type !== null && COSMETIC_TYPES.includes(type) ? type : null;

    let commandId = null;
    if (durationSec !== null) {
      if (ep.type !== 'shutter' || !ep.shutter_pair_index) {
        throw httpError(400, 'Çalışma süresi yalnızca panjur kanalları için ayarlanabilir.', 'VALIDATION');
      }
      if (!ep.is_online) {
        throw httpError(409, 'Cihaz çevrimdışı; panjur süresi cihaza iletilemedi.', 'DEVICE_OFFLINE', { device_online: false });
      }
      commandId = crypto.randomBytes(9).toString('base64url');
      // Yayin hatasi YUTULMAZ: DB cihazdan once degismez. Pano komutu uygulamadiysa (onay yok) DB'ye yazilmaz.
      const applied = await this._publishRuntime(ep.topic_id, ep.shutter_pair_index, durationSec, commandId);
      if (!applied) {
        console.warn(`[ENDPOINT] set_runtime cihaz onayi gelmedi (cift ${ep.shutter_pair_index}); DB guncellenmedi`);
        throw httpError(409, RUNTIME_NOT_APPLIED_MESSAGE, 'CONFLICT', { reason: 'NOT_APPLIED' });
      }
    }

    // uygulama-ekranlar-7 (sozlesme C14): panjur satirina ad/oda gelirse ciftin IKI satirina yazilir (oda cipleri ve ad tutarli).
    const pairText = ep.type === 'shutter' && Boolean(ep.shutter_pair_index) && (name !== null || room !== null);
    const updated = await this.db.withTransaction(async (tx) => {
      let pairOk = false;
      if (durationSec !== null || pairText) {
        // Kilit sirasi esitlemeyle ayni (endpoint_layout_sync rowsLocked): cihazin satirlari kanal sirasinda.
        // Hedef ve cift satirlari bu kumenin icindedir; sonraki UPDATE'ler yeni kilit almaz (40P01 dongusu yok).
        const locked = await tx.query(
          `SELECT id, channel_index, type, shutter_pair_index
             FROM endpoints WHERE home_id = $1 AND device_id = $2 ORDER BY channel_index ASC FOR UPDATE`,
          [homeId, ep.device_id]
        );
        pairOk = isSamePairLocked(locked.rows, endpointId, ep.shutter_pair_index);
        // Yalniz ad/oda: kilitsiz okumadan sonra esitleme cifti bozduysa yalniz hedef satir yazilir (eski davranis).
        if (!pairOk && durationSec !== null) {
          // set_runtime yayinlandi ve pano ONAYLADI (cift panoda tanimli); ancak onay beklenirken esitleme DB'deki
          // kanal yerlesimini degistirdi. DB'ye yazilmaz, istemci listeyi yenileyip yeniden dener. (Pano cifti artik
          // tanimiyorsa komutu reddeder ve onay gelmez: yukarida 409 "uygulamadi".)
          console.warn(`[ENDPOINT] set_runtime onaylandi (cift ${ep.shutter_pair_index}) ama kanal artik bu panjur degil; DB guncellenmedi`);
          throw httpError(409, TYPE_CHANGED_MESSAGE, 'CONFLICT', { reason: 'TYPE_CHANGED' });
        }
      }

      // Tip yaziliyorsa satir hala light/plug olmali (kilitsiz okumadan sonra esitleme panjur yapmis olabilir).
      // Her satir bu islemde EN COK BIR KEZ guncellenir: ayni satirin ikinci UPDATE'i FK yeniden denetimini
      // (devices/homes FOR KEY SHARE) tetikler; esitleme devices FOR UPDATE tutarken bu bir kilit dongusu kurar.
      // Bu yuzden hedefin suresi de bu UPDATE ile yazilir, cift UPDATE'i hedefi disarida birakir.
      const res = await tx.query(
        `UPDATE endpoints
            SET name = COALESCE($1, name),
                room = COALESCE($2, room),
                type = COALESCE($3, type),
                shutter_duration_sec = COALESCE($6::int, shutter_duration_sec),
                updated_at = CURRENT_TIMESTAMP
          WHERE id = $4 AND home_id = $5 AND ($3::varchar IS NULL OR type IN ('light', 'plug'))
          RETURNING id`,
        [name, room, typeParam, endpointId, homeId, durationSec]
      );
      if (res.rows.length === 0) {
        if (typeParam !== null) throw httpError(409, TYPE_CHANGED_MESSAGE, 'CONFLICT', { reason: 'TYPE_CHANGED' });
        throw httpError(404, 'Kontrol noktası bulunamadı.', 'NOT_FOUND');
      }

      if (pairOk) {
        // Panjur cifti (yukari + asagi satiri) ayni sureyi, adi ve odayi paylasir; hedef satir yukarida yazildi. Diger
        // satir TEK UPDATE ile (verilmeyen alan COALESCE ile korunur).
        await tx.query(
          `UPDATE endpoints SET shutter_duration_sec = COALESCE($1::int, shutter_duration_sec), name = COALESCE($6, name), room = COALESCE($7, room),
                  updated_at = CURRENT_TIMESTAMP
            WHERE home_id = $2 AND device_id = $3 AND shutter_pair_index = $4 AND type = 'shutter' AND id <> $5`,
          [durationSec, homeId, ep.device_id, ep.shutter_pair_index, endpointId, name, room]
        );
      }

      const out = await tx.query(
        `SELECT e.id, e.home_id, e.device_id, e.channel_index, e.name, e.type, e.room, e.shutter_pair_index,
                e.shutter_duration_sec, e.current_state, e.current_position, e.created_at, e.updated_at,
              e.actuator_type, e.dimmable, e.dimmer_source,
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

  /**
   * set_runtime yayini + cihaz onayi. Onay bekleyicisi YAYINDAN ONCE kurulur (hizli yanki kacmaz); yayin hatasinda
   * iptal edilir. @returns {Promise<boolean>} true = pano komutu uyguladi (CANLI state.last_id === commandId)
   */
  async _publishRuntime(topicId, pair, sec, commandId) {
    const bridge = this.bridge;
    if (typeof bridge.isConnected === 'function' && !bridge.isConnected()) {
      throw httpError(502, 'MQTT broker bağlantısı yok; panjur süresi cihaza iletilemedi.', 'BROKER_UNAVAILABLE');
    }
    const ack = bridge.expectAck(topicId, commandId, RUNTIME_ACK_TIMEOUT_MS);
    try {
      await bridge.publishCommand(topicId, { cmd: 'set_runtime', shutter: pair, sec, id: commandId });
    } catch (err) {
      if (typeof bridge.cancelAck === 'function') bridge.cancelAck(topicId, commandId);
      console.error('[ENDPOINT] set_runtime yayinlanamadi:', err && err.message);
      throw httpError(502, 'Panjur süresi MQTT broker üzerinden iletilemedi.', 'BROKER_UNAVAILABLE');
    }
    return ack;
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
