'use strict';

// Ortak test yardimcilari (WP-L yerlesim esitleme). Dosya adi `_` ile basladigi icin `node --test` bunu test
// olarak CALISTIRMAZ ("*.test.js" deseni).
//
// Gercek veritabani KULLANILMAZ: servisin SQL'ini (SQL.x metin esitligiyle) taklit eden bellek ici dunya ve elle
// ilerletilen saat (`w.now`). Transaction ROLLBACK'i dunyanin anlik goruntusunu geri yukleyerek taklit edilir.

const crypto = require('node:crypto');
const { extractReportedLayout, seedDefaults } = require('../../src/utils/endpoint_layout');

const T0 = Date.parse('2026-10-03T09:00:00Z');

// Panonun fabrika yerlesimi (ConfigManager.cpp applyDefaults).
const FW_NAMES = Object.freeze([
  'Salon Panjur (Yukari)', 'Salon Panjur (Asagi)', 'Oda Panjur (Yukari)', 'Oda Panjur (Asagi)',
  'Salon Aydinlatma', 'Mutfak Aydinlatma', 'Koridor Aydinlatma', 'Balkon Aydinlatma',
]);
const FW_TYPES = Object.freeze(['shutter_up', 'shutter_down', 'shutter_up', 'shutter_down', 'light', 'light', 'light', 'light']);

/**
 * Pano `state` yuku uretir.
 * @param {object} [o]
 * @param {number} [o.count]  role sayisi (varsayilan 8; 9+ ek modul roleleri `light`)
 * @param {Object<number,{name?:string,type?:string}>} [o.set]  kanal bazinda ad/tip degisikligi
 * @param {Object<number,number>} [o.pos]  panjur cifti -> konum (varsayilan 0)
 */
function fwState({ count = 8, set = {}, pos = {}, v = 2 } = {}) {
  const relays = [];
  for (let i = 0; i < count; i += 1) {
    const id = i + 1;
    const over = set[id] || {};
    relays.push({
      id,
      name: over.name !== undefined ? over.name : i < 8 ? FW_NAMES[i] : `Ek Modül Röle ${id - 8}`,
      type: over.type !== undefined ? over.type : i < 8 ? FW_TYPES[i] : 'light',
      state: false,
    });
  }
  const shutters = [];
  for (let p = 1; p <= Math.floor(count / 2); p += 1) {
    if (relays[2 * p - 2].type === 'shutter_up') {
      shutters.push({ pair: p, pos: pos[p] !== undefined ? pos[p] : 0, moving: false, dir: 0, target: 255 });
    }
  }
  return { v, uid: 'AHBU-S3-A1B2C3', relays, shutters, dis: [] };
}

/** extractReportedLayout(fwState(o)); gecersiz test girdisinde hemen hata verir. */
function layoutOf(o) {
  const layout = extractReportedLayout(fwState(o));
  if (!layout) throw new Error('gecersiz test yerlesimi');
  return layout;
}

/** Sessiz logger; satirlari saklar. */
function makeLogger() {
  const lines = [];
  const push = (level) => (...args) => lines.push(`${level}: ${args.map(String).join(' ')}`);
  return { log: push('log'), warn: push('warn'), error: push('error'), lines };
}

function clone(v) {
  return v === undefined ? undefined : JSON.parse(JSON.stringify(v));
}

/**
 * Bellek ici dunya + sahte db.
 * @param {object} SQL  servisin disa aktardigi SQL nesnesi (metinler esitlikle eslenir)
 */
function makeWorld(SQL) {
  const sqlName = (text) => Object.keys(SQL).find((k) => SQL[k] === text) || '?';
  const w = {
    now: T0,
    devices: new Map(), // id -> { id, home_id, device_uuid, reported_layout, is_commissioned? }
    endpoints: [], // { id, home_id, device_id, channel_index, name, type, room, shutter_pair_index, ... }
    rules: [], // { id, home_id, device_id, channel_type, channel, enabled }
    audits: [], // { event, device_uuid, home_id, details }
    calls: [], // { name, text, params, inTx }
    txLog: [], // 'BEGIN' | 'COMMIT' | 'ROLLBACK'
    failWhen: null, // (text, params, inTx) => Error | null   (sorgu bazinda hata)
    failTx: null, // Error: withTransaction, geri cagrim calismadan firlatir
    beforeTx: null, // async () => void : kilitsiz okuma ile transaction arasina girer (tek seferlik)
    hold: null, // Promise: cozulene kadar tum sorgular bekler
    seq: 0,
  };

  /** commissioned: devices.is_commissioned (verilmezse false; elle eklenen cihaz satirinda alan yoksa da false). */
  w.addDevice = ({ homeId = crypto.randomUUID(), uuid = 'AHBU-S3-A1B2C3', base = null, commissioned = false } = {}) => {
    const d = { id: crypto.randomUUID(), home_id: homeId, device_uuid: uuid, reported_layout: base, is_commissioned: commissioned === true };
    w.devices.set(d.id, d);
    return d;
  };
  /** Tohum sablonu satirlari (kanal `from`..`to`). */
  w.seed = (d, to = 8, from = 1) => {
    for (let c = from; c <= to; c += 1) {
      const s = seedDefaults(c);
      w.endpoints.push({
        id: `ep-${d.id.slice(0, 4)}-${c}`,
        home_id: d.home_id,
        device_id: d.id,
        channel_index: c,
        name: s.name,
        type: s.type,
        room: s.room,
        shutter_pair_index: s.pair,
        shutter_duration_sec: s.durationSec,
        current_state: false,
        current_position: 0,
      });
    }
  };
  w.rowsOf = (d) => w.endpoints.filter((e) => e.device_id === d.id).sort((a, b) => a.channel_index - b.channel_index);
  w.row = (d, channel) => w.endpoints.find((e) => e.device_id === d.id && e.channel_index === channel) || null;
  w.removeRows = (d, pred) => {
    w.endpoints = w.endpoints.filter((e) => !(e.device_id === d.id && pred(e)));
  };
  w.addRule = (d, channelType, channel, { enabled = true, homeId = d.home_id, deviceId = null } = {}) => {
    const r = { id: `rule-${(w.seq += 1)}`, home_id: homeId, device_id: deviceId, channel_type: channelType, channel, enabled };
    w.rules.push(r);
    return r;
  };
  /** Sorgu adlari (SQL anahtari); `from`: bu cagri indeksinden itibaren. */
  w.names = (from = 0) => w.calls.slice(from).map((c) => c.name);
  w.find = (name) => w.calls.filter((c) => c.name === name);

  function exec(text, params, inTx) {
    w.calls.push({ name: sqlName(text), text, params, inTx });
    const err = typeof w.failWhen === 'function' ? w.failWhen(text, params, inTx) : null;
    if (err) throw err;
    switch (text) {
      case SQL.device:
      case SQL.deviceLocked: {
        const d = w.devices.get(params[0]);
        if (!d) return { rows: [], rowCount: 0 };
        return {
          rows: [
            {
              id: d.id,
              home_id: d.home_id,
              device_uuid: d.device_uuid,
              reported_layout: clone(d.reported_layout),
              is_commissioned: d.is_commissioned === true,
            },
          ],
          rowCount: 1,
        };
      }
      case SQL.rows:
      case SQL.rowsLocked: {
        const rows = w.endpoints
          .filter((e) => e.device_id === params[0])
          .sort((a, b) => a.channel_index - b.channel_index)
          .map((e) => ({
            id: e.id,
            channel_index: e.channel_index,
            name: e.name,
            type: e.type,
            room: e.room,
            shutter_pair_index: e.shutter_pair_index,
            shutter_duration_sec: e.shutter_duration_sec,
          }));
        return { rows, rowCount: rows.length };
      }
      case SQL.insertRow: {
        const [homeId, deviceId, channel, name, type, room, pair, sec, state, position] = params;
        if (w.endpoints.some((e) => e.device_id === deviceId && e.channel_index === channel)) return { rows: [], rowCount: 0 };
        w.endpoints.push({
          id: `ep-new-${(w.seq += 1)}`,
          home_id: homeId,
          device_id: deviceId,
          channel_index: channel,
          name,
          type,
          room,
          shutter_pair_index: pair,
          shutter_duration_sec: sec,
          current_state: state,
          current_position: position,
        });
        return { rows: [], rowCount: 1 };
      }
      case SQL.updateRow: {
        const [id, deviceId, name, type, room, pair, sec, position] = params;
        const e = w.endpoints.find((x) => x.id === id && x.device_id === deviceId);
        if (!e) return { rows: [], rowCount: 0 };
        Object.assign(e, { name, type, room, shutter_pair_index: pair, shutter_duration_sec: sec });
        if (position !== null && position !== undefined) e.current_position = position;
        return { rows: [], rowCount: 1 };
      }
      case SQL.deleteAbove: {
        const before = w.endpoints.length;
        w.endpoints = w.endpoints.filter((e) => !(e.device_id === params[0] && e.channel_index > params[1]));
        return { rows: [], rowCount: before - w.endpoints.length };
      }
      case SQL.disableRules: {
        const [homeId, deviceId, relayChannels, shutterPairs] = params;
        // D14: device_id NULL kural yalniz evde tek cihaz varsa
        const homeDevices = [...w.devices.values()].filter((x) => x.home_id === homeId).length;
        const hit = w.rules.filter(
          (r) =>
            r.home_id === homeId &&
            (r.device_id === deviceId || (r.device_id === null && homeDevices === 1)) &&
            r.enabled === true &&
            ((r.channel_type === 'relay' && relayChannels.includes(r.channel)) ||
              (r.channel_type === 'shutter' && shutterPairs.includes(r.channel)))
        );
        for (const r of hit) r.enabled = false;
        return { rows: hit.map((r) => ({ id: r.id })), rowCount: hit.length };
      }
      case SQL.saveBase: {
        const d = w.devices.get(params[0]);
        if (!d) return { rows: [], rowCount: 0 };
        d.reported_layout = JSON.parse(params[1]);
        return { rows: [], rowCount: 1 };
      }
      case SQL.audit: {
        w.audits.push({ event: params[0], device_uuid: params[1], home_id: params[2], details: JSON.parse(params[3]), raw: params[3] });
        return { rows: [], rowCount: 1 };
      }
      default:
        throw new Error(`beklenmeyen sorgu: ${String(text).slice(0, 60)}`);
    }
  }

  function snapshot() {
    return {
      devices: [...w.devices.values()].map((d) => clone(d)),
      endpoints: clone(w.endpoints),
      rules: clone(w.rules),
      audits: clone(w.audits),
    };
  }
  function restore(snap) {
    for (const s of snap.devices) Object.assign(w.devices.get(s.id), s); // nesne kimligi korunur (testler `d` tutar)
    w.endpoints = snap.endpoints;
    for (const s of snap.rules) Object.assign(w.rules.find((r) => r.id === s.id), s);
    w.audits = snap.audits;
  }

  w.db = {
    async query(text, params) {
      if (w.hold) await w.hold;
      return exec(text, params, false);
    },
    async withTransaction(fn) {
      if (w.beforeTx) {
        const hook = w.beforeTx;
        w.beforeTx = null;
        await hook();
      }
      if (w.failTx) throw w.failTx;
      w.txLog.push('BEGIN');
      const snap = snapshot();
      try {
        const result = await fn({ query: async (text, params) => exec(text, params, true) });
        w.txLog.push('COMMIT');
        return result;
      } catch (err) {
        restore(snap);
        w.txLog.push('ROLLBACK');
        throw err;
      }
    },
  };
  return w;
}

module.exports = { T0, FW_NAMES, FW_TYPES, fwState, layoutOf, makeLogger, makeWorld };
