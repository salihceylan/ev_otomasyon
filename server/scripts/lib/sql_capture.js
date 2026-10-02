'use strict';

// ==============================================================================
// WP-C modullerinin CALISAN SQL'ini yakalama (sema-sozlesme denetimi icin)
// ==============================================================================
//
// Dinamik olusturulan SQL (toplu UPDATE ... FROM (VALUES ...), degisken SET listeleri) metin
// taramasiyla tam gorulemez. Bu modul kopru, zamanlayici ve kural servisini, SQL'i kaydeden sahte
// bir veritabaniyla tum dallardan gecirir ve calisan ifadeleri dondurur. Gercek veritabani YOKTUR;
// yaniti sahtedir. Sonuc `sql_contract.checkStatements` ile migration semasina karsi denetlenir.

const path = require('path');

const SERVER = path.join(__dirname, '..', '..');
const silent = { log() {}, warn() {}, error() {} };

function makeRecorder(reply) {
  const statements = [];
  const run = (text, params) => {
    statements.push({ sql: text, where: 'capture' });
    const out = reply ? reply(text, params) : undefined;
    return Promise.resolve(out === undefined ? { rows: [], rowCount: 1 } : out);
  };
  const db = {
    query: run,
    async withTransaction(fn) {
      return fn({ query: run });
    },
  };
  return { db, statements };
}

async function captureBridge() {
  const { MqttBridge } = require(path.join(SERVER, 'src', 'mqtt_bridge'));
  const rec = makeRecorder((text) => {
    if (/FROM homes h LEFT JOIN devices d/.test(text)) {
      return { rows: [{ home_id: 'h1', device_id: 'd1', device_uuid: 'AHBU-CAP-0001' }], rowCount: 1 };
    }
    return undefined; // diger her sey: { rows: [], rowCount: 1 } (retained uzlastirma -> homes esitleme dali)
  });
  const bridge = new MqttBridge({ db: rec.db, logger: silent, env: {}, now: () => 1e12 });

  const live = {
    uid: 'AHBU-CAP-0001',
    fw: '1.1.0',
    ip: '10.0.0.1',
    child_lock: true,
    last_id: 'x1',
    relays: [{ id: 1, state: true }, { id: 2, state: false }],
    shutters: [{ pair: 1, pos: 40 }],
  };
  await bridge.handleIncomingMessage('ev/h_cap/state', JSON.stringify(live), { retain: false });
  await bridge.handleIncomingMessage('ev/h_cap/state', JSON.stringify({ ...live, child_lock: false }), { retain: true });
  await bridge.handleIncomingMessage('ev/h_cap/status', 'online', { retain: false });
  await bridge.handleIncomingMessage('ev/h_cap/status', 'offline', { retain: true });

  // cevrimdisi supurucu (baglanti ve gecis suresi simule edilir)
  bridge.connected = true;
  bridge.client = { connected: true };
  bridge.connectedSince = 0;
  await bridge.sweepOffline();
  return rec.statements;
}

async function captureScheduler() {
  const { Scheduler, SQL } = require(path.join(SERVER, 'src', 'scheduler'));
  const T = Date.parse('2026-10-01T05:30:20Z'); // Istanbul 08:30
  const rule = {
    id: 1,
    home_id: 'h1',
    device_id: null,
    channel: 3,
    channel_type: 'relay',
    action: 'on',
    hour: 8,
    minute: 30,
    days_of_week: [0, 1, 2, 3, 4, 5, 6],
    created_by: 'u1',
    last_run_at: null,
    schedule_changed_at: new Date(0),
    mqtt_username: 'h_cap',
    timezone: 'Europe/Istanbul',
  };
  const statements = [];
  for (const online of [true, false]) {
    // ikinci tur cihaz cevrimdisi: talebin geri birakilmasi (release) dali calisir
    const rec = makeRecorder((text) => {
      if (text === SQL.timezones) return { rows: [{ tz: 'Europe/Istanbul' }] };
      if (text === SQL.candidates) return { rows: [{ ...rule }] };
      if (text === SQL.claim) return { rows: [{ id: 1 }], rowCount: 1 };
      if (text === SQL.creator) {
        return { rows: [{ is_active: true, account_status: null, global_role: 'user', home_role: 'owner', installer_expires_at: null }] };
      }
      if (text === SQL.devices) return { rows: [{ id: 'd1', home_id: 'h1', is_online: online }] };
      return undefined;
    });
    const s = new Scheduler({ logger: silent, now: () => T });
    s.start({
      mqttBridge: { isConnected: () => true, publishCommand: async () => ({}) },
      db: rec.db,
    });
    await s.runTick(T);
    await s.stop();
    statements.push(...rec.statements);
  }
  return statements;
}

async function captureService() {
  const { createService } = require(path.join(SERVER, 'src', 'services', 'scheduled_rules_service'));
  const existing = {
    id: 5,
    home_id: 'h1',
    device_id: null,
    channel: 3,
    channel_type: 'relay',
    action: 'on',
    hour: 8,
    minute: 30,
    days_of_week: [0, 1, 2, 3, 4, 5, 6],
    label: 'x',
    enabled: false,
    created_by: 'u1',
  };
  const DEV = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
  const rec = makeRecorder((text, params) => {
    if (/pg_advisory_xact_lock/.test(text)) return { rows: [{}] };
    if (/^SELECT id FROM homes WHERE id/.test(text)) return { rows: [{ id: 'h1' }] };
    if (/SELECT COUNT\(\*\)/.test(text)) return { rows: [{ n: 1 }] };
    if (/^SELECT id FROM devices/.test(text)) return { rows: [{ id: DEV }] };
    if (/FROM endpoints WHERE home_id/.test(text)) {
      return { rows: [{ channel_index: 1, type: 'shutter' }, { channel_index: 2, type: 'shutter' }, { channel_index: 3, type: 'light' }, { channel_index: 4, type: 'light' }] };
    }
    if (/INSERT INTO scheduled_rules/.test(text)) return { rows: [{ ...existing, id: 9, created_by_name: 'A', created_at: new Date(), updated_at: new Date() }] };
    if (/FOR UPDATE$/.test(text.trim())) return { rows: [{ ...existing }] };
    if (/WITH upd AS/.test(text)) return { rows: [{ ...existing, created_by_name: 'A', created_at: new Date(), updated_at: new Date() }] };
    if (/^DELETE FROM scheduled_rules WHERE id/.test(text)) return { rows: [{ id: 5 }], rowCount: 1 };
    if (/FROM scheduled_rules sr LEFT JOIN users u/.test(text)) return { rows: [{ ...existing, created_by_name: 'A', created_at: new Date(), updated_at: new Date() }] };
    return undefined;
  });
  const svc = createService({ db: rec.db });
  const home = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
  await svc.listRules(home);
  await svc.createRule(home, 'u1', { channel: 3, channel_type: 'relay', action: 'on', hour: 8, minute: 30, device_id: DEV, label: 'l', days_of_week: [1, 2], enabled: true });
  // her alan + zamanlama degisikligi (last_run_at / schedule_changed_at SET dali)
  await svc.updateRule(home, 5, { channel: 4, channel_type: 'relay', action: 'off', hour: 9, minute: 5, days_of_week: [1], device_id: DEV, label: 'y', enabled: true });
  await svc.updateRule(home, 5, { label: 'yalniz etiket' });
  await svc.deleteRule(home, 5);
  await svc.homeCleanupHook({ query: rec.db.query }, home);
  return rec.statements;
}

/** Kopru + zamanlayici + kural servisi: calisan SQL ifadeleri. */
async function captureWpCStatements() {
  const all = [];
  for (const [name, fn] of [['mqtt_bridge', captureBridge], ['scheduler', captureScheduler], ['scheduled_rules_service', captureService]]) {
    const st = await fn();
    for (const s of st) all.push({ sql: s.sql, where: `capture:${name}` });
  }
  return all;
}

module.exports = { captureWpCStatements, captureBridge, captureScheduler, captureService };
