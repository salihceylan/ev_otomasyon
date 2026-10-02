'use strict';

// ==============================================================================
// AHBU Akıllı Ev - Gece huzur hatırlatması: CANLI durum anlık görüntüsü      [WP-H §3.3]
// ==============================================================================
//
// Kullanım (peace_reminder.js):
//   const { loadLiveSnapshot } = require('./services/peace_snapshot');
//   const snap = await loadLiveSnapshot(db, homeId);
//   snap.live            -> en az bir cihaz CANLI mı? (false ise "bilinmiyor": bildirim YAPILMAZ)
//   snap.lights          -> [{ endpointId, deviceId, channel, name, room }]  açık lambalar
//   snap.shutters        -> [{ pair, deviceId, room, position }]            açık panjur çiftleri
//
// Neden "canlı" süzgeci?
//   endpoints.current_state / current_position yalnızca MQTT köprüsü tarafından, cihazın retained
//   state mesajından yazılır. Cihaz çevrimdışı olduğunda, elektrik gidip geldiğinde (röleler KAPALI
//   açılır) ya da köprü yeniden başladığında (retained tekrar oynatılır, last_seen_at ilerlemez) bu
//   değerler BAYAT kalabilir. Bayat veriye bakıp "lamba açık" diye gece yarısı uyarmak yanlış alarm
//   olur; bu yüzden yalnızca `devices.is_online IS TRUE` VE `last_seen_at` son 120 sn içinde olan
//   cihazların satırlarına güvenilir (köprünün süpürücü eşiğiyle aynı: mqtt_bridge.js).
//   Süre karşılaştırması VERİTABANI saatiyle yapılır (uygulama sunucusunun saati kayık olabilir).
//
// Açık tanımı:
//   lamba  = endpoints.type = 'light' VE current_state = TRUE
//   panjur = bir panjur ÇİFTİNİN (yukarı + aşağı röle) en büyük current_position değeri >= 1.
//            Firmware: yukarı = 100, aşağı = 0 (CONTRACTS §0). Çiftin iki satırı aynı konumu taşır.
//            Çift numarası COALESCE(shutter_pair_index, (channel_index + 1) / 2): köprü de pair'i
//            boş olan eski satırları kanal numarasından çözer. Çift numarası CİHAZA özeldir
//            (iki cihazlı evde ikisinde de "1. panjur" vardır) -> tekilleştirme (cihaz, çift) ile.
//   plug ve impulse satırları lamba/panjur sayılmaz.

const OPEN_SHUTTER_MIN_POS = 1; // current_position >= 1 -> açık (0 = tam kapalı)
const LIVE_WINDOW_SEC = 120; // mqtt_bridge.js süpürücü eşiğiyle aynı
const DEFAULT_ROOM = 'Genel'; // endpoints.room varsayılanı (migration 001)

const SQL = Object.freeze({
  // Her cihaz EN AZ bir satır döner (LEFT JOIN): toplam/canlı cihaz sayısı bundan çıkar.
  // Uç satırları yalnızca AÇIK olanlarla sınırlıdır; böylece büyük evlerde veri küçük kalır.
  // $1 = home_id, $2 = canlılık penceresi (sn), $3 = panjur açık eşiği
  snapshot:
    'SELECT d.id AS device_id, ' +
    'COALESCE(d.is_online IS TRUE AND d.last_seen_at >= CURRENT_TIMESTAMP - ($2::int * INTERVAL \'1 second\'), FALSE) AS live, ' +
    'e.id AS endpoint_id, e.type, e.channel_index, ' +
    'COALESCE(e.shutter_pair_index, (e.channel_index + 1) / 2) AS pair, ' +
    "e.name, COALESCE(e.room, '" + DEFAULT_ROOM + "') AS room, e.current_state, e.current_position " +
    'FROM devices d ' +
    'LEFT JOIN endpoints e ON e.device_id = d.id ' +
    "AND ((e.type = 'light' AND e.current_state IS TRUE) OR (e.type = 'shutter' AND e.current_position >= $3)) " +
    'WHERE d.home_id = $1 ' +
    'ORDER BY d.id, e.channel_index',
});

function toInt(value) {
  if (typeof value === 'number' && Number.isFinite(value)) return Math.trunc(value);
  if (typeof value === 'string' && /^-?\d{1,9}$/.test(value.trim())) return parseInt(value, 10);
  return null;
}

/** pg bazı sürücülerde boolean yerine 't'/'true' dönebilir; yalnızca açıkça doğru olan doğrudur. */
function isTrue(value) {
  return value === true || value === 't' || value === 'true';
}

/**
 * `db.query(text, params)` (src/db.js) ya da `db.pool.query` arayüzünü ortak bir işleve çevirir.
 * Başka bir şey verilirse net bir hata (yanlış bağımlılık sessizce "hiçbir şey açık değil" olmasın).
 */
function resolveQuery(db) {
  if (db && typeof db.query === 'function') return (text, params) => db.query(text, params);
  if (db && db.pool && typeof db.pool.query === 'function') return (text, params) => db.pool.query(text, params);
  throw new TypeError('peace_snapshot: db (query) zorunludur');
}

/**
 * Bir evin CANLI cihazlarındaki açık lamba/panjurları döndürür. Yalnızca OKUR.
 *
 * @param {{query:Function}} db  src/db.js benzeri
 * @param {string} homeId        UUID
 * @returns {Promise<{devicesTotal:number, devicesLive:number, live:boolean,
 *   lights:Array<{endpointId:string, deviceId:string, channel:number, name:string, room:string}>,
 *   shutters:Array<{pair:number, deviceId:string, room:string, position:number}>}>}
 *   live=false -> hiçbir cihaz canlı değil: listeler BOŞTUR ve çağıran "bilinmiyor" saymalıdır.
 */
async function loadLiveSnapshot(db, homeId) {
  const query = resolveQuery(db);
  const res = await query(SQL.snapshot, [homeId, LIVE_WINDOW_SEC, OPEN_SHUTTER_MIN_POS]);
  const rows = (res && res.rows) || [];

  const devices = new Map(); // device_id -> canlı mı
  const lights = [];
  const shutterPairs = new Map(); // `${device}:${pair}` -> { pair, deviceId, room, position }

  for (const row of rows) {
    const deviceId = String(row.device_id);
    const live = isTrue(row.live);
    // Aynı cihaz birden çok satırla gelir; biri bile canlıysa canlı sayılır (hepsi aynı değeri taşır).
    devices.set(deviceId, devices.get(deviceId) === true || live);
    if (!live || row.endpoint_id === null || row.endpoint_id === undefined) continue; // bayat veriye GÜVENME

    const room = typeof row.room === 'string' && row.room.trim() !== '' ? row.room : DEFAULT_ROOM;
    if (row.type === 'light' && isTrue(row.current_state)) {
      lights.push({
        endpointId: String(row.endpoint_id),
        deviceId,
        channel: toInt(row.channel_index),
        name: row.name === null || row.name === undefined ? '' : String(row.name),
        room,
      });
    } else if (row.type === 'shutter') {
      const position = toInt(row.current_position);
      const pair = toInt(row.pair);
      if (position === null || pair === null || position < OPEN_SHUTTER_MIN_POS) continue;
      const key = `${deviceId}:${pair}`;
      const known = shutterPairs.get(key);
      if (!known) shutterPairs.set(key, { pair, deviceId, room, position });
      else if (position > known.position) known.position = position; // MAX(current_position)
    }
  }

  const devicesLive = [...devices.values()].filter(Boolean).length;
  const live = devicesLive > 0;
  const shutters = [...shutterPairs.values()].sort(
    (a, b) => (a.deviceId < b.deviceId ? -1 : a.deviceId > b.deviceId ? 1 : 0) || a.pair - b.pair
  );
  return {
    devicesTotal: devices.size,
    devicesLive,
    live,
    lights: live ? lights : [],
    shutters: live ? shutters : [],
  };
}

module.exports = {
  OPEN_SHUTTER_MIN_POS,
  LIVE_WINDOW_SEC,
  loadLiveSnapshot,
  SQL,
};
