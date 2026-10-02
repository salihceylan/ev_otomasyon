'use strict';

// Ortak test yardimcilari (WP-H, evaluator). Dosya adi `_` ile basladigi icin `node --test`
// bunu test olarak CALISTIRMAZ ("*.test.js" deseni).
//
// Gercek veritabani / broker / FCM KULLANILMAZ: sahte db (gercek SQL anlamini JS ile taklit eder),
// sahte push, sahte metin, sahte zamanlayicilar ve sahte saat.

const { SQL: REMINDER_SQL, helpers } = require('../../src/peace_reminder');
const { SQL: SNAPSHOT_SQL, LIVE_WINDOW_SEC } = require('../../src/services/peace_snapshot');

const MIN = 60 * 1000;
const Z = (iso) => Date.parse(iso);

const HOME_A = '11111111-1111-4111-8111-111111111111';
const HOME_B = '22222222-2222-4222-8222-222222222222';
const HOME_C = '33333333-3333-4333-8333-333333333333';
const DEV_A = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const DEV_B = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';

/** Sessiz logger; cagrilari saklar (testlerde "sir sizmadi mi" denetimi icin). */
function makeLogger() {
  const lines = [];
  const push = (level) => (...args) => lines.push(`${level}: ${args.map(String).join(' ')}`);
  return { log: push('log'), warn: push('warn'), error: push('error'), lines };
}

/** Sahte zamanlayicilar: kendiliginden ilerlemez, testler `fire` ile tetikler. */
function makeFakeTimers() {
  let seq = 0;
  const timeouts = new Map();
  const setTimer = (fn, ms) => {
    const id = ++seq;
    const handle = { id, fn, ms, unref() { return handle; } };
    timeouts.set(id, handle);
    return handle;
  };
  const clearTimer = (h) => {
    if (h) timeouts.delete(h.id);
  };
  return {
    setTimer,
    clearTimer,
    pending: () => [...timeouts.values()],
    fire(h) {
      if (timeouts.has(h.id)) {
        timeouts.delete(h.id);
        return h.fn();
      }
      return undefined;
    },
  };
}

/** Bekleyen mikro/makro gorevlerin bitmesi icin kisa bekleme. */
async function flush(ms = 0) {
  await new Promise((resolve) => setImmediate(resolve));
  await new Promise((resolve) => setTimeout(resolve, ms));
  await new Promise((resolve) => setImmediate(resolve));
}

const FULL_SCHEMA = () => {
  const rows = [];
  for (const [table, columns] of Object.entries(helpers.REQUIRED_SCHEMA)) {
    for (const column of columns) rows.push({ table_name: table, column_name: column });
  }
  return rows;
};

/**
 * Gece huzur dunyasi: sahte veritabani, GERCEK SQL semantigini JS ile taklit eder
 * (aday secimi, ON CONFLICT talebi, kira suresi, nihai kayit guncellemesi, canli anlik goruntu).
 *
 * world.homes      [{ id, name, timezone, peace_notification_time, peace_notification_enabled }]
 * world.devices    [{ id, home_id, is_online, last_seen_ms }]
 * world.endpoints  [{ id, device_id, type, channel_index, shutter_pair_index, name, room, current_state, current_position }]
 * world.logs       peace_notification_logs satirlari
 * world.schemaRows information_schema satirlari (testler sonradan degistirebilir: rolling deploy)
 * world.onSnapshot (n, homeId) => void   her canli anlik goruntu sorgusundan ONCE (n = o evin sorgu sirasi)
 */
function makePeaceWorld({ homes = [], devices = [], endpoints = [], schemaRows = FULL_SCHEMA(), clock } = {}) {
  const world = {
    schemaRows,
    homes: homes.map((h) => ({ timezone: 'Europe/Istanbul', peace_notification_time: '23:30', peace_notification_enabled: true, ...h })),
    devices,
    endpoints,
    logs: [],
    purged: 0,
    snapshotCalls: new Map(),
    onSnapshot: null,
    failOn: null, // (text, params) => Error | null
    clock: clock || { ms: Z('2026-10-01T20:30:20Z') },
  };
  let nextId = 1;
  const calls = [];

  const nowMs = () => world.clock.ms;
  const hasDevices = (homeId) => world.devices.some((d) => d.home_id === homeId);
  const allowed = (id, allow) => allow === null || allow === undefined || allow.includes(id);
  const effTime = (h) => (/^([01][0-9]|2[0-3]):[0-5][0-9]$/.test(h.peace_notification_time ?? '23:30') ? h.peace_notification_time ?? '23:30' : '23:30');
  const tzOf = (h) => h.timezone || 'Europe/Istanbul';

  // Yeniden deneme araligi: SQL'deki CASE ile ayni sabitlerden (helpers.retryDueSec)
  const retryDue = (l) => l.updated_at <= nowMs() - helpers.retryDueSec(l.attempts) * 1000;
  const logFor = (h, nowHHMM, today, previous) => {
    const date = effTime(h) > nowHHMM ? previous : today;
    return world.logs.find((l) => l.home_id === h.id && l.local_date === date) || null;
  };

  function candidates([tz, targets, limit, nowHHMM, today, previous, maxAttempts, allow]) {
    return world.homes
      .filter((h) => h.peace_notification_enabled !== false && tzOf(h) === tz && targets.includes(effTime(h)) && hasDevices(h.id) && allowed(h.id, allow))
      .filter((h) => {
        const l = logFor(h, nowHHMM, today, previous);
        if (!l) return true; // LEFT JOIN: kayit yok
        return l.attempts < maxAttempts && (l.status === 'claimed' || (['skipped_offline', 'failed'].includes(l.status) && retryDue(l)));
      })
      // ORDER BY COALESCE(l.attempts, 0), h.id: hic denenmemisler once
      .sort((a, b) => {
        const la = logFor(a, nowHHMM, today, previous);
        const lb = logFor(b, nowHHMM, today, previous);
        return ((la ? la.attempts : 0) - (lb ? lb.attempts : 0)) || (a.id < b.id ? -1 : 1);
      })
      .slice(0, limit)
      .map((h) => ({ id: h.id, name: h.name, timezone: tzOf(h), raw_time: h.peace_notification_time ?? null, peace_time: effTime(h) }));
  }

  function claim([homeId, localDate, scheduledIso, maxAttempts]) {
    const existing = world.logs.find((l) => l.home_id === homeId && l.local_date === localDate);
    if (!existing) {
      const row = {
        id: nextId++,
        home_id: homeId,
        local_date: localDate,
        scheduled_for: scheduledIso,
        status: 'claimed',
        attempts: 1,
        triggered_at: nowMs(),
        updated_at: nowMs(),
        open_lights_count: 0,
        open_shutters_count: 0,
        summary_text: null,
        details: null,
        push_sent_count: 0,
      };
      world.logs.push(row);
      return { rows: [{ id: row.id, attempts: 1 }], rowCount: 1 };
    }
    const leaseExpired = existing.status === 'claimed' && existing.updated_at < nowMs() - 2 * MIN;
    if (existing.attempts < maxAttempts && ((['skipped_offline', 'failed'].includes(existing.status) && retryDue(existing)) || leaseExpired)) {
      existing.status = 'claimed';
      existing.attempts += 1;
      existing.updated_at = nowMs();
      return { rows: [{ id: existing.id, attempts: existing.attempts }], rowCount: 1 };
    }
    return { rows: [], rowCount: 0 };
  }

  function markSending([id, attempts]) {
    const row = world.logs.find((l) => l.id === id);
    if (!row || row.status !== 'claimed' || row.attempts !== attempts) return { rows: [], rowCount: 0 };
    Object.assign(row, { status: 'sending', updated_at: nowMs() });
    return { rows: [], rowCount: 1 };
  }

  function finish([id, status, lights, shutters, summary, details, pushSent, attempts]) {
    const row = world.logs.find((l) => l.id === id);
    if (!row || !['claimed', 'sending'].includes(row.status) || row.attempts !== attempts) return { rows: [], rowCount: 0 };
    Object.assign(row, {
      status,
      open_lights_count: lights,
      open_shutters_count: shutters,
      summary_text: summary,
      details: JSON.parse(details),
      push_sent_count: pushSent,
      evaluated_at: nowMs(),
      updated_at: nowMs(),
    });
    return { rows: [], rowCount: 1 };
  }

  function snapshot([homeId, windowSec, minPos]) {
    const n = (world.snapshotCalls.get(homeId) || 0) + 1;
    world.snapshotCalls.set(homeId, n);
    if (world.onSnapshot) world.onSnapshot(n, homeId);
    const rows = [];
    for (const d of world.devices.filter((x) => x.home_id === homeId)) {
      const live = d.is_online === true && d.last_seen_ms !== null && d.last_seen_ms !== undefined && d.last_seen_ms >= nowMs() - windowSec * 1000;
      const open = world.endpoints.filter(
        (e) => e.device_id === d.id && ((e.type === 'light' && e.current_state === true) || (e.type === 'shutter' && e.current_position >= minPos))
      );
      const base = { device_id: d.id, live };
      if (open.length === 0) rows.push({ ...base, endpoint_id: null, type: null, channel_index: null, pair: null, name: null, room: null, current_state: null, current_position: null });
      for (const e of open) {
        rows.push({
          ...base,
          endpoint_id: e.id,
          type: e.type,
          channel_index: e.channel_index,
          pair: e.shutter_pair_index ?? Math.floor((e.channel_index + 1) / 2),
          name: e.name,
          room: e.room ?? 'Genel',
          current_state: e.current_state,
          current_position: e.current_position,
        });
      }
    }
    return { rows, rowCount: rows.length };
  }

  function run(text, params) {
    calls.push({ text, params });
    if (world.failOn) {
      const err = world.failOn(text, params);
      if (err) return Promise.reject(err);
    }
    if (text === REMINDER_SQL.selfCheck) return Promise.resolve({ rows: world.schemaRows });
    if (text === REMINDER_SQL.zones) {
      const allow = params[0];
      const tzs = [...new Set(world.homes.filter((h) => h.peace_notification_enabled !== false && hasDevices(h.id) && allowed(h.id, allow)).map(tzOf))];
      return Promise.resolve({ rows: tzs.map((tz) => ({ tz })) });
    }
    if (text === REMINDER_SQL.candidates) return Promise.resolve({ rows: candidates(params) });
    if (text === REMINDER_SQL.claim) return Promise.resolve(claim(params));
    if (text === REMINDER_SQL.markSending) return Promise.resolve(markSending(params));
    if (text === REMINDER_SQL.finish) return Promise.resolve(finish(params));
    if (text === REMINDER_SQL.purgeLogs) {
      world.purged += 1;
      return Promise.resolve({ rows: [], rowCount: 0 });
    }
    if (text === SNAPSHOT_SQL.snapshot) return Promise.resolve(snapshot(params));
    return Promise.reject(new Error(`beklenmeyen sorgu: ${text.slice(0, 60)}`));
  }

  const db = {
    calls,
    query: (text, params) => run(text, params),
    count: (sql) => calls.filter((c) => c.text === sql).length,
  };
  return { world, db, clock: world.clock };
}

/** Sahte push servisi: cagrilari saklar, sonucu test belirler. */
function makeFakePush({ configured = true, recipients, result, throwError = null } = {}) {
  const push = {
    calls: { recipients: [], send: [], cleanup: [] },
    configured,
    recipients:
      recipients === undefined
        ? [
            { id: 'tok-1', userId: 'user-1', token: 'FAKE-TOKEN-AAAA-0000000001', platform: 'android' },
            { id: 'tok-2', userId: 'user-2', token: 'FAKE-TOKEN-BBBB-0000000002', platform: 'ios' },
          ]
        : recipients,
    result: result || { attempted: 2, sent: 2, failed: 0, disabledTokenIds: [], transient: false, errors: [] },
    throwError,
    isConfigured() {
      return push.configured;
    },
    async recipientsForHome(homeId) {
      push.calls.recipients.push(homeId);
      return push.recipients;
    },
    async sendNotice(args) {
      push.calls.send.push(args);
      if (push.throwError) throw push.throwError;
      return typeof push.result === 'function' ? push.result(args) : push.result;
    },
    async cleanup(args) {
      push.calls.cleanup.push(args);
      return { deleted: 0 };
    },
  };
  return push;
}

/** Sahte metin uretici (gercek peace_text'e bagimli degiliz). */
function makeFakeText() {
  return {
    buildTitle: (name) => `T:${name || 'Evim'}`,
    buildSummary: ({ lights, shutters }) => (lights.length + shutters.length === 0 ? '' : `S:${lights.length}L${shutters.length}S`),
  };
}

/** Bir evi ve canli cihazini kurar (varsayilan: Istanbul 23:30, evde 1 canli cihaz, 1 acik lamba). */
function standardWorld({ lampOn = true, homeOverrides = {}, deviceOverrides = {}, extraHomes = [], extraDevices = [], extraEndpoints = [] } = {}) {
  const clock = { ms: Z('2026-10-01T20:30:20Z') };
  const built = makePeaceWorld({
    clock,
    homes: [{ id: HOME_A, name: 'Gül Apartmanı 5', ...homeOverrides }, ...extraHomes],
    devices: [{ id: DEV_A, home_id: HOME_A, is_online: true, last_seen_ms: clock.ms - 10 * 1000, ...deviceOverrides }, ...extraDevices],
    endpoints: [
      { id: 'ep-1', device_id: DEV_A, type: 'light', channel_index: 5, shutter_pair_index: null, name: 'Salon avize', room: 'Salon', current_state: lampOn, current_position: 0 },
      { id: 'ep-2', device_id: DEV_A, type: 'light', channel_index: 6, shutter_pair_index: null, name: 'Mutfak', room: 'Mutfak', current_state: false, current_position: 0 },
      ...extraEndpoints,
    ],
  });
  return { ...built, clock };
}

module.exports = {
  MIN,
  Z,
  HOME_A,
  HOME_B,
  HOME_C,
  DEV_A,
  DEV_B,
  LIVE_WINDOW_SEC,
  makeLogger,
  makeFakeTimers,
  makePeaceWorld,
  makeFakePush,
  makeFakeText,
  standardWorld,
  flush,
};
