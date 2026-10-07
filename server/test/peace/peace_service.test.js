'use strict';

// WP-H / peace_service - ayar GET v2 ve "Hepsini Kapat" v2.
//
// Hermetik: sahte db (peace_snapshot SQL'ini _helpers.js dunyasi, geri kalan SQL'i bu dosya JS ile
// taklit eder), sahte yayinci, sahte uyku, sahte audit. Ag / gercek DB / broker / zamanlayici YOK.
// Gercek olanlar: peace_snapshot, peace_text, utils/http_errors (httpError).

const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const assert = require('node:assert/strict');

const service = require('../../src/services/peace_service');
const { createPeaceService, RESOLVABLE_STATUSES, CHUNK_SIZE, CHUNK_DELAY_MS, SQL, helpers } = service;
const { httpError } = require('../../src/utils/http_errors');
const { makePeaceWorld, makeLogger, Z, HOME_A, HOME_B, DEV_A, DEV_B } = require('./_helpers');

const NOW = Z('2026-10-01T20:30:20Z');
const TOPIC = 'h_0123456789abcdef';
const ACTOR_ID = '5f1c0000-0000-4000-8000-000000000001';
const ACTOR = { userId: ACTOR_ID, globalRole: 'user', access: 'owner', ip: '203.0.113.7' };
const VISIBLE = ['sent', 'no_recipients', 'resolved'];

// ------------------------------------------------------------------------------
// Sahte dunya
// ------------------------------------------------------------------------------

const light = (id, channel, room, on = true, device = DEV_A) => ({
  id, device_id: device, type: 'light', channel_index: channel, shutter_pair_index: null, name: `Lamba ${channel}`, room, current_state: on, current_position: 0,
});
const shutter = (id, channel, pair, position, room = 'Salon', device = DEV_A) => ({
  id, device_id: device, type: 'shutter', channel_index: channel, shutter_pair_index: pair, name: `Panjur ${channel}`, room, current_state: false, current_position: position,
});
const plug = (id, channel, device = DEV_A) => ({
  id, device_id: device, type: 'plug', channel_index: channel, shutter_pair_index: null, name: `Priz ${channel}`, room: 'Salon', current_state: true, current_position: 0,
});
const liveDevice = (id = DEV_A, home = HOME_A, over = {}) => ({ id, home_id: home, is_online: true, last_seen_ms: NOW - 5000, ...over });
const logRow = (id, over = {}) => ({
  id, home_id: HOME_A, local_date: '2026-10-01', status: 'sent', triggered_at: NOW - 3600 * 1000, resolved_at: null,
  open_lights_count: 2, open_shutters_count: 1, summary_text: 'Salonda 2 lamba, 1 panjur açık.', resolved_by_user: false, ...over,
});

/**
 * @param {object} [o]
 * @param {object[]} [o.homes] ev satirlari (varsayilan: HOME_A)
 * @param {object[]} [o.devices]
 * @param {object[]} [o.endpoints]
 * @param {object[]} [o.logs]
 * @param {Function} [o.publish] (topic, payload, n) => Promise (hata firlatabilir)
 * @param {Function} [o.audit]   (q, args) => Promise (hata firlatabilir)
 * @param {Function} [o.failQuery] (text) => boolean: true ise o sorgu reddedilir
 * @param {boolean} [o.noTx]     db.withTransaction YOK
 */
function makeEnv(o = {}) {
  const base = makePeaceWorld({
    clock: { ms: NOW },
    homes: o.homes || [{ id: HOME_A, name: 'Gül Apartmanı 5', mqtt_username: TOPIC }],
    devices: o.devices || [liveDevice()],
    endpoints: o.endpoints || [],
  });
  const world = base.world;
  world.logs.push(...(o.logs || []).map((l) => ({ ...l })));
  const events = [];
  const queries = [];
  const published = [];
  const sleeps = [];
  const audits = [];
  let nextLogId = 5000;
  let cmdSeq = 0;

  const home = (id) => world.homes.find((h) => h.id === id);
  const homeEndpoints = (homeId) => {
    const ids = new Set(world.devices.filter((d) => d.home_id === homeId).map((d) => d.id));
    return world.endpoints.filter((e) => ids.has(e.device_id));
  };
  const resolvable = (l) => RESOLVABLE_STATUSES.includes(l.status);

  function resolveNotice([actorId, firstId, noticeId, homeId]) {
    let target = noticeId;
    if (target === null || target === undefined) {
      const candidates = world.logs
        .filter((l) => l.home_id === homeId && l.local_date !== null && l.local_date !== undefined && !l.resolved_at && resolvable(l))
        .sort((a, b) => (a.local_date < b.local_date ? 1 : a.local_date > b.local_date ? -1 : 0));
      target = candidates.length ? candidates[0].id : null;
    }
    const row = world.logs.find((l) => l.id === target);
    if (!row || row.home_id !== homeId || row.resolved_at || !resolvable(row)) return { rows: [], rowCount: 0 };
    Object.assign(row, {
      status: 'resolved', resolved_by_user: true, resolved_at: NOW, resolved_by_user_id: actorId, resolved_via: 'close_all', command_id: firstId, updated_at: NOW,
    });
    return { rows: [{ id: row.id }], rowCount: 1 };
  }

  function lastNotice([homeId]) {
    const rows = world.logs
      .filter((l) => l.home_id === homeId && l.local_date && VISIBLE.includes(l.status))
      .sort((a, b) => (a.local_date < b.local_date ? 1 : a.local_date > b.local_date ? -1 : b.id - a.id));
    if (!rows.length) return { rows: [] };
    const l = rows[0];
    return {
      rows: [{
        id: l.id, local_date: l.local_date, status: l.status, summary_text: l.summary_text,
        open_lights_count: l.open_lights_count, open_shutters_count: l.open_shutters_count,
        triggered_at: new Date(l.triggered_at), resolved_at: l.resolved_at ? new Date(l.resolved_at) : null,
      }],
    };
  }

  function runQuery(text, params) {
    queries.push({ text, params });
    if (o.failQuery && o.failQuery(text)) return Promise.reject(new Error('baglanti koptu'));
    if (text === SQL.home) {
      const h = home(params[0]);
      return Promise.resolve({
        rows: h ? [{ id: h.id, name: h.name, peace_notification_enabled: h.peace_notification_enabled, peace_notification_time: h.peace_notification_time, timezone: h.timezone }] : [],
      });
    }
    if (text === SQL.topic) {
      const h = home(params[0]);
      return Promise.resolve({ rows: h ? [{ mqtt_username: h.mqtt_username }] : [] });
    }
    if (text === SQL.hasPlug) {
      return Promise.resolve({ rows: [{ has_plug: homeEndpoints(params[0]).some((e) => e.type === 'plug') }] });
    }
    if (text === SQL.layout) {
      events.push('q:layout');
      return Promise.resolve({
        rows: homeEndpoints(params[0]).map((e) => ({
          device_id: e.device_id, type: e.type, channel_index: e.channel_index, shutter_pair_index: e.shutter_pair_index, current_position: e.current_position,
        })),
      });
    }
    if (text === SQL.lastNotice) return Promise.resolve(lastNotice(params));
    if (text === SQL.resolveNotice) {
      events.push('q:resolve');
      return Promise.resolve(resolveNotice(params));
    }
    if (text === SQL.insertManual) {
      events.push('q:manual');
      const [homeId, lights, shutters, summary, actorId, firstId] = params;
      world.logs.push({
        id: nextLogId++, home_id: homeId, local_date: null, status: 'manual', open_lights_count: lights, open_shutters_count: shutters,
        summary_text: summary, resolved_by_user: true, resolved_at: NOW, resolved_via: 'close_all', resolved_by_user_id: actorId, command_id: firstId,
      });
      return Promise.resolve({ rows: [], rowCount: 1 });
    }
    return base.db.query(text, params); // peace_snapshot sorgusu
  }

  const db = {
    query: (text, params) => runQuery(text, params),
    txCount: 0,
  };
  if (!o.noTx) {
    db.withTransaction = async (fn) => {
      db.txCount += 1;
      events.push('tx:begin');
      const backup = world.logs.map((l) => ({ ...l }));
      try {
        const result = await fn({ query: (t, p) => runQuery(t, p) });
        events.push('tx:commit');
        return result;
      } catch (err) {
        world.logs.splice(0, world.logs.length, ...backup);
        events.push('tx:rollback');
        throw err;
      }
    };
  }

  const logger = makeLogger();
  const svc = createPeaceService({
    db,
    logger,
    now: () => new Date(NOW),
    newCommandId: () => `cmd${String(++cmdSeq).padStart(9, '0')}`,
    publishCommand: async (topic, payload) => {
      events.push('publish');
      published.push({ topic, payload });
      if (o.publish) await o.publish(topic, payload, published.length);
    },
    audit: async (q, args) => {
      events.push('audit');
      audits.push(args);
      if (o.audit) await o.audit(q, args);
    },
    httpError,
    sleep: async (ms) => {
      events.push(`sleep:${ms}`);
      sleeps.push(ms);
    },
  });
  return { svc, world, db, events, queries, published, sleeps, audits, logger };
}

/** Standart ev: Salon 1 lamba + Mutfak 1 lamba acik (biri kapali), 1. panjur acik, 2. panjur kapali. */
const standardEndpoints = () => [
  light('l1', 5, 'Salon'),
  light('l2', 6, 'Mutfak', false),
  light('l3', 7, 'Mutfak'),
  shutter('s1', 1, 1, 100),
  shutter('s2', 2, 1, 100),
  shutter('s3', 3, 2, 0),
  shutter('s4', 4, 2, 0),
];

const writesToEndpoints = (queries) => queries.filter((q) => /\b(UPDATE|INSERT\s+INTO|DELETE\s+FROM)\s+endpoints\b/i.test(q.text));

async function rejects(promise) {
  try {
    await promise;
  } catch (err) {
    return err;
  }
  assert.fail('hata bekleniyordu');
  return null;
}

// ==============================================================================
// Sabitler / arayuz
// ==============================================================================

test('arayuz: sabitler ve ihrac edilenler', () => {
  // 'sending' dahil: push'un notice_id'si push aninda 'sending' olan satirdir (F1)
  assert.deepEqual([...RESOLVABLE_STATUSES], ['sent', 'no_recipients', 'sending']);
  assert.equal(CHUNK_SIZE, 16);
  assert.equal(CHUNK_DELAY_MS, 150);
  assert.equal(typeof createPeaceService, 'function');
});

test('olusturma: zorunlu bagimlilik eksikse TypeError (sessizce bozuk servis uretilmez)', () => {
  const ok = { db: { query: async () => ({ rows: [] }) }, publishCommand: async () => {}, newCommandId: () => 'x', audit: async () => {}, httpError };
  assert.doesNotThrow(() => createPeaceService(ok));
  for (const key of ['db', 'publishCommand', 'newCommandId', 'audit', 'httpError']) {
    const deps = { ...ok };
    delete deps[key];
    assert.throws(() => createPeaceService(deps), TypeError, key);
  }
  assert.throws(() => createPeaceService(), TypeError);
});

// ==============================================================================
// getSettings
// ==============================================================================

test('getSettings: v2 sekli, eski anahtarlar korunur, acik lamba+panjur Turkce ozet', async () => {
  const { svc } = makeEnv({
    homes: [{ id: HOME_A, name: 'Ev', mqtt_username: TOPIC, peace_notification_time: '22:45', peace_notification_enabled: true, timezone: 'Europe/Berlin' }],
    endpoints: standardEndpoints(),
    logs: [logRow(1)],
  });
  const out = await svc.getSettings({ homeId: HOME_A });

  assert.deepEqual(Object.keys(out).sort(), [
    'devices_online', 'devices_total', 'enabled', 'home_id', 'last_notice', 'open_lights', 'open_lights_count', 'open_shutters',
    'open_shutters_count', 'peace_notification_enabled', 'peace_notification_time', 'stale', 'summary_text', 'time', 'timezone',
  ]);
  assert.equal(out.home_id, HOME_A);
  assert.equal(out.enabled, true);
  assert.equal(out.peace_notification_enabled, true);
  assert.equal(out.time, '22:45');
  assert.equal(out.peace_notification_time, '22:45');
  assert.equal(out.timezone, 'Europe/Berlin');
  assert.equal(out.devices_total, 1);
  assert.equal(out.devices_online, 1);
  assert.equal(out.stale, false);
  assert.equal(out.open_lights_count, 2);
  assert.equal(out.open_shutters_count, 1);
  assert.deepEqual(out.open_lights, [
    { id: 'l1', channel_index: 5, name: 'Lamba 5', room: 'Salon' },
    { id: 'l3', channel_index: 7, name: 'Lamba 7', room: 'Mutfak' },
  ]);
  assert.deepEqual(out.open_shutters, [{ pair: 1, room: 'Salon', position: 100 }]);
  assert.equal(out.summary_text, 'Mutfakta 1, Salonda 1 lamba, 1 panjur açık.');
});

test('getSettings: NULL saat/etkin -> etkin true, saat 23:30; bozuk saat 23:30; etkin=false korunur', async () => {
  const mk = (over) => makeEnv({ homes: [{ id: HOME_A, name: 'Ev', mqtt_username: TOPIC, ...over }], endpoints: [] });
  let out = await mk({ peace_notification_time: null, peace_notification_enabled: null, timezone: null }).svc.getSettings({ homeId: HOME_A });
  assert.equal(out.enabled, true);
  assert.equal(out.peace_notification_enabled, true);
  assert.equal(out.time, '23:30');
  assert.equal(out.peace_notification_time, '23:30');
  assert.equal(out.timezone, 'Europe/Istanbul');

  for (const bad of ['9:05', '24:00', '23.30', '', 'abc', 2330]) {
    out = await mk({ peace_notification_time: bad }).svc.getSettings({ homeId: HOME_A });
    assert.equal(out.time, '23:30', `bozuk saat ${JSON.stringify(bad)}`);
  }

  out = await mk({ peace_notification_enabled: false, peace_notification_time: '07:05' }).svc.getSettings({ homeId: HOME_A });
  assert.equal(out.enabled, false);
  assert.equal(out.peace_notification_enabled, false);
  assert.equal(out.time, '07:05');
});

test('getSettings: tum lambalar kapali -> v1 metni, stale=false', async () => {
  const { svc } = makeEnv({ endpoints: [light('l1', 5, 'Salon', false), shutter('s1', 1, 1, 0)] });
  const out = await svc.getSettings({ homeId: HOME_A });
  assert.equal(out.stale, false);
  assert.equal(out.open_lights_count, 0);
  assert.equal(out.open_shutters_count, 0);
  assert.deepEqual(out.open_lights, []);
  assert.deepEqual(out.open_shutters, []);
  assert.equal(out.summary_text, 'Tüm lambalar kapalı, eviniz huzur modunda.');
});

test('getSettings: bayat/cevrimdisi cihaz -> stale, sayilar 0, bilgi guncel degil metni (bayat lamba GOSTERILMEZ)', async () => {
  for (const device of [
    liveDevice(DEV_A, HOME_A, { last_seen_ms: NOW - 121 * 1000 }), // 120 sn penceresi disinda
    liveDevice(DEV_A, HOME_A, { is_online: false }),
    liveDevice(DEV_A, HOME_A, { last_seen_ms: null }),
  ]) {
    const { svc } = makeEnv({ devices: [device], endpoints: standardEndpoints() });
    const out = await svc.getSettings({ homeId: HOME_A });
    assert.equal(out.stale, true);
    assert.equal(out.devices_total, 1);
    assert.equal(out.devices_online, 0);
    assert.equal(out.open_lights_count, 0);
    assert.equal(out.open_shutters_count, 0);
    assert.deepEqual(out.open_lights, []);
    assert.deepEqual(out.open_shutters, []);
    assert.equal(out.summary_text, 'Cihaz çevrimdışı; açık lamba bilgisi güncel değil.');
  }
});

test('getSettings: hic cihaz yok -> stale, devices_total 0', async () => {
  const { svc } = makeEnv({ devices: [], endpoints: [] });
  const out = await svc.getSettings({ homeId: HOME_A });
  assert.equal(out.stale, true);
  assert.equal(out.devices_total, 0);
  assert.equal(out.devices_online, 0);
  assert.equal(out.summary_text, 'Cihaz çevrimdışı; açık lamba bilgisi güncel değil.');
});

test('getSettings: iki cihazdan biri bayatsa yalniz canli cihazin acik lambasi sayilir', async () => {
  const { svc } = makeEnv({
    devices: [liveDevice(DEV_A), liveDevice(DEV_B, HOME_A, { last_seen_ms: NOW - 600 * 1000 })],
    endpoints: [light('a1', 5, 'Salon', true, DEV_A), light('b1', 5, 'Mutfak', true, DEV_B)],
  });
  const out = await svc.getSettings({ homeId: HOME_A });
  assert.equal(out.stale, false);
  assert.equal(out.devices_total, 2);
  assert.equal(out.devices_online, 1);
  assert.equal(out.open_lights_count, 1);
  assert.equal(out.open_lights[0].id, 'a1');
});

test('getSettings: last_notice = yalniz sent/no_recipients/resolved ve local_date dolu en yeni satir', async () => {
  const { svc } = makeEnv({
    endpoints: [],
    logs: [
      logRow(1, { local_date: '2026-09-28', status: 'sent', summary_text: 'eski' }),
      logRow(2, { local_date: '2026-09-30', status: 'resolved', resolved_at: NOW - 1800 * 1000, summary_text: 'Salonda 1 lamba açık.', open_lights_count: 1, open_shutters_count: 0 }),
      logRow(3, { local_date: '2026-10-01', status: 'clear' }), // gorunmez
      logRow(4, { local_date: '2026-10-02', status: 'claimed' }), // gorunmez
      logRow(5, { local_date: '2026-10-03', status: 'skipped_offline' }), // gorunmez
      logRow(6, { local_date: '2026-10-03', status: 'failed' }), // gorunmez
      logRow(7, { local_date: '2026-10-04', status: 'sending' }), // gorunmez
      logRow(8, { local_date: null, status: 'manual', triggered_at: NOW }), // elle kapatma satiri: gorunmez
      logRow(9, { home_id: HOME_B, local_date: '2026-10-05', status: 'sent' }), // baska ev
    ],
  });
  const out = await svc.getSettings({ homeId: HOME_A });
  assert.deepEqual(out.last_notice, {
    id: 2,
    local_date: '2026-09-30',
    status: 'resolved',
    summary_text: 'Salonda 1 lamba açık.',
    open_lights_count: 1,
    open_shutters_count: 0,
    created_at: new Date(NOW - 3600 * 1000).toISOString(),
    resolved_at: new Date(NOW - 1800 * 1000).toISOString(),
  });
});

test('getSettings: last_notice cozulmemisse resolved_at null; yoksa last_notice null; sorgu filtresi dogru', async () => {
  let env = makeEnv({ endpoints: [], logs: [logRow(1, { status: 'no_recipients' })] });
  let out = await env.svc.getSettings({ homeId: HOME_A });
  assert.equal(out.last_notice.status, 'no_recipients');
  assert.equal(out.last_notice.resolved_at, null);
  assert.equal(out.last_notice.local_date, '2026-10-01');

  env = makeEnv({ endpoints: [], logs: [logRow(1, { status: 'clear' }), logRow(2, { local_date: null, status: 'manual' })] });
  out = await env.svc.getSettings({ homeId: HOME_A });
  assert.equal(out.last_notice, null);

  // SQL: ev kapsamli, local_date dolu, yalniz gorunur durumlar
  assert.match(SQL.lastNotice, /WHERE home_id = \$1 AND local_date IS NOT NULL AND status IN \('sent', 'no_recipients', 'resolved'\)/);
  assert.match(SQL.lastNotice, /ORDER BY local_date DESC, id DESC LIMIT 1/);
  const q = env.queries.find((x) => x.text === SQL.lastNotice);
  assert.deepEqual(q.params, [HOME_A]);
});

test('getSettings: ev yok -> 404 NOT_FOUND "Daire bulunamadı."; ev kimligi bos -> 404', async () => {
  const { svc } = makeEnv({ endpoints: [] });
  let err = await rejects(svc.getSettings({ homeId: '99999999-9999-4999-8999-999999999999' }));
  assert.equal(err.status, 404);
  assert.equal(err.code, 'NOT_FOUND');
  assert.equal(err.message, 'Daire bulunamadı.');
  err = await rejects(svc.getSettings({ homeId: '' }));
  assert.equal(err.status, 404);
});

test('getSettings: salt okunur (yazma sorgusu yok) ve sorgu parametreleri ev kimligidir', async () => {
  const { svc, queries } = makeEnv({ endpoints: standardEndpoints() });
  await svc.getSettings({ homeId: HOME_A });
  assert.ok(queries.length >= 3);
  for (const q of queries) {
    assert.doesNotMatch(q.text, /^\s*(UPDATE|INSERT|DELETE)\b/i);
    assert.equal(q.params[0], HOME_A);
  }
});

// ==============================================================================
// closeAll: komut uretimi
// ==============================================================================

test('closeAll: yalniz lamba (plug yok) -> TEK all_lights_off, 1 komut, id newCommandId()', async () => {
  const { svc, published } = makeEnv({ endpoints: [light('l1', 5, 'Salon'), light('l2', 6, 'Mutfak'), light('l3', 7, 'Koridor', false)] });
  const out = await svc.closeAll({ actor: ACTOR, homeId: HOME_A });
  assert.equal(published.length, 1);
  assert.equal(published[0].topic, TOPIC);
  assert.deepEqual(published[0].payload, { cmd: 'all_lights_off', id: 'cmd000000001' });
  assert.equal(out.closed_lights, 2);
  assert.equal(out.closed_shutters, 0);
  assert.equal(out.closed_count, 2);
  assert.deepEqual(out.command_ids, ['cmd000000001']);
  assert.equal(out.command_id, 'cmd000000001');
});

test('closeAll: evde plug varsa tek tek role (1 tabanli kanal = channel_index), all_lights_off YOK', async () => {
  const { svc, published } = makeEnv({
    endpoints: [light('l1', 5, 'Salon'), light('l2', 6, 'Mutfak', false), light('l3', 8, 'Balkon'), plug('p1', 7)],
  });
  const out = await svc.closeAll({ actor: ACTOR, homeId: HOME_A, includeShutters: false });
  assert.deepEqual(
    published.map((p) => p.payload),
    [
      { relay: 5, state: false, id: 'cmd000000001' },
      { relay: 8, state: false, id: 'cmd000000002' },
    ]
  );
  assert.ok(published.every((p) => p.payload.cmd === undefined));
  assert.ok(published.every((p) => p.payload.relay >= 1)); // 0 tabanli kanal ASLA
  assert.equal(out.closed_lights, 2);
  assert.deepEqual(out.command_ids, ['cmd000000001', 'cmd000000002']);
});

test('closeAll: plug yalniz KAPALI/lamba disi satirdaysa bile varlik yeterli; plug sorgusu yalniz acik lamba varken calisir', async () => {
  const none = makeEnv({ endpoints: [shutter('s1', 1, 1, 100)] });
  await none.svc.closeAll({ actor: ACTOR, homeId: HOME_A });
  assert.equal(none.queries.some((q) => q.text === SQL.hasPlug), false);
  const some = makeEnv({ endpoints: [light('l1', 5, 'Salon'), plug('p1', 6)] });
  await some.svc.closeAll({ actor: ACTOR, homeId: HOME_A });
  assert.deepEqual(some.queries.find((q) => q.text === SQL.hasPlug).params, [HOME_A]);
});

test('closeAll: panjur ciftleri down (yalniz ACIK cift, NULL shutter_pair_index dahil), all_shutters_down YOK', async () => {
  const eps = [
    shutter('s1', 1, 1, 100),
    shutter('s2', 2, 1, 100), // ayni cift: tek komut
    shutter('s3', 3, 2, 0), // kapali cift: komut YOK
    shutter('s4', 4, 2, 0),
    { ...shutter('s5', 5, null, 40), channel_index: 5 }, // NULL pair -> (5+1)/2 = 3
    shutter('s6', 6, null, 40),
  ];
  const { svc, published } = makeEnv({ endpoints: eps });
  const out = await svc.closeAll({ actor: ACTOR, homeId: HOME_A });
  assert.deepEqual(
    published.map((p) => p.payload),
    [
      { shutter: 1, cmd: 'down', id: 'cmd000000001' },
      { shutter: 3, cmd: 'down', id: 'cmd000000002' },
    ]
  );
  assert.ok(published.every((p) => p.payload.cmd !== 'all_shutters_down'));
  assert.equal(out.closed_lights, 0);
  assert.equal(out.closed_shutters, 2);
  assert.equal(out.closed_count, 0);
});

test('closeAll: lamba + panjur birlikte, sirayla (once lamba sonra panjur); includeShutters:false panjur komutu uretmez', async () => {
  let env = makeEnv({ endpoints: standardEndpoints() });
  let out = await env.svc.closeAll({ actor: ACTOR, homeId: HOME_A });
  assert.deepEqual(
    env.published.map((p) => p.payload),
    [
      { cmd: 'all_lights_off', id: 'cmd000000001' },
      { shutter: 1, cmd: 'down', id: 'cmd000000002' },
    ]
  );
  assert.equal(out.closed_lights, 2);
  assert.equal(out.closed_shutters, 1);
  assert.equal(out.message, 'Huzur modu: 2 lamba ve 1 panjur için kapatma komutu cihaza iletildi.');

  env = makeEnv({ endpoints: standardEndpoints() });
  out = await env.svc.closeAll({ actor: ACTOR, homeId: HOME_A, includeShutters: false });
  assert.deepEqual(env.published.map((p) => p.payload), [{ cmd: 'all_lights_off', id: 'cmd000000001' }]);
  assert.equal(out.closed_shutters, 0);
  assert.equal(out.message, 'Huzur modu: 2 lamba için kapatma komutu cihaza iletildi.');

  // includeShutters: null/undefined -> varsayilan true
  env = makeEnv({ endpoints: [shutter('s1', 1, 1, 100)] });
  out = await env.svc.closeAll({ actor: ACTOR, homeId: HOME_A, includeShutters: null });
  assert.equal(out.closed_shutters, 1);
  assert.equal(out.message, 'Huzur modu: 1 panjur için kapatma komutu cihaza iletildi.');
});

test('closeAll: bayat cihazin acik lambasi/panjuru komut uretmez; canli cihaz yeterli', async () => {
  const { svc, published } = makeEnv({
    devices: [liveDevice(DEV_A), liveDevice(DEV_B, HOME_A, { last_seen_ms: NOW - 900 * 1000 })],
    endpoints: [light('a1', 5, 'Salon', false, DEV_A), light('b1', 6, 'Mutfak', true, DEV_B), shutter('bs', 1, 1, 100, 'Salon', DEV_B)],
  });
  const out = await svc.closeAll({ actor: ACTOR, homeId: HOME_A });
  assert.equal(published.length, 0);
  assert.equal(out.closed_lights, 0);
  assert.equal(out.closed_shutters, 0);
});

test('closeAll: plug evinde iki cihazda ayni kanal -> tek role komutu, ama iki lamba sayilir; gecersiz kanal atlanir', async () => {
  const { svc, published } = makeEnv({
    devices: [liveDevice(DEV_A), liveDevice(DEV_B)],
    endpoints: [light('a1', 5, 'Salon', true, DEV_A), light('b1', 5, 'Salon', true, DEV_B), light('x1', 0, 'Salon', true, DEV_A), light('x2', 41, 'Salon', true, DEV_A), plug('p1', 9)],
  });
  const out = await svc.closeAll({ actor: ACTOR, homeId: HOME_A });
  assert.deepEqual(published.map((p) => p.payload.relay), [5]);
  assert.equal(out.closed_lights, 2);
});

test('buildCloseCommands (saf): kanal 1 tabanli, hic acik yoksa bos, ids benzersiz', () => {
  let n = 0;
  const id = () => `i${++n}`;
  const empty = { commands: [], closedLights: 0, closedShutters: 0, skippedLights: 0, skippedShutters: 0 };
  assert.deepEqual(helpers.buildCloseCommands({ lights: [], shutters: [], includeShutters: true, hasPlug: true, newCommandId: id }), empty);
  assert.deepEqual(helpers.buildCloseCommands({ lights: undefined, shutters: null, includeShutters: true, hasPlug: false, newCommandId: id }), empty);
  const r = helpers.buildCloseCommands({
    lights: [{ channel: 1 }, { channel: 40 }],
    shutters: [{ pair: 1 }, { pair: 20 }, { pair: 21 }, { pair: 0 }],
    includeShutters: true,
    hasPlug: true,
    newCommandId: id,
  });
  assert.deepEqual(r.commands.map((c) => c.relay ?? c.shutter), [1, 40, 1, 20]);
  assert.equal(new Set(r.commands.map((c) => c.id)).size, r.commands.length);
  assert.equal(r.closedLights, 2);
  assert.equal(r.closedShutters, 2);
});

// ==============================================================================
// closeAll: hatalar (404 / 409 / 502 / 400)
// ==============================================================================

test('closeAll: ev yok -> 404 NOT_FOUND; cihaz yok -> 404 "Daireye bağlı pano bulunamadı."', async () => {
  let env = makeEnv({ endpoints: [] });
  let err = await rejects(env.svc.closeAll({ actor: ACTOR, homeId: '99999999-9999-4999-8999-999999999999' }));
  assert.equal(err.status, 404);
  assert.equal(err.code, 'NOT_FOUND');
  assert.equal(err.message, 'Daire bulunamadı.');

  env = makeEnv({ devices: [], endpoints: [] });
  err = await rejects(env.svc.closeAll({ actor: ACTOR, homeId: HOME_A }));
  assert.equal(err.status, 404);
  assert.equal(err.code, 'NOT_FOUND');
  assert.equal(err.message, 'Daireye bağlı pano bulunamadı.');
  assert.equal(env.published.length, 0);
  assert.equal(env.audits.length, 0);
});

test('closeAll: canli cihaz yok -> 409 DEVICE_OFFLINE (device_online:false), yayin/kayit/audit YOK', async () => {
  for (const device of [liveDevice(DEV_A, HOME_A, { is_online: false }), liveDevice(DEV_A, HOME_A, { last_seen_ms: NOW - 200 * 1000 })]) {
    const env = makeEnv({ devices: [device], endpoints: standardEndpoints(), logs: [logRow(1)] });
    const err = await rejects(env.svc.closeAll({ actor: ACTOR, homeId: HOME_A }));
    assert.equal(err.status, 409);
    assert.equal(err.code, 'DEVICE_OFFLINE');
    assert.equal(err.message, 'Cihaz çevrimdışı; lambalar kapatılamadı.');
    assert.deepEqual(err.extra, { device_online: false });
    assert.equal(env.published.length, 0);
    assert.equal(env.audits.length, 0);
    assert.equal(env.db.txCount, 0);
    assert.equal(env.world.logs[0].status, 'sent'); // bildirim cozulmedi
    assert.equal(env.world.logs.length, 1);
  }
});

test('closeAll: yayin hatasi -> DUR, hata AYNEN yukari (502), bildirim cozulmez, hicbir sey yazilmaz', async () => {
  const brokerError = httpError(502, 'Komut MQTT broker üzerinden iletilemedi.', 'BROKER_UNAVAILABLE');
  const env = makeEnv({
    endpoints: [light('l1', 5, 'Salon'), plug('p1', 6), light('l2', 7, 'Mutfak'), light('l3', 8, 'Balkon')],
    logs: [logRow(1, { status: 'sent' })],
    publish: async (_t, _p, n) => {
      if (n === 2) throw brokerError;
    },
  });
  const err = await rejects(env.svc.closeAll({ actor: ACTOR, homeId: HOME_A }));
  assert.equal(err, brokerError); // sarmalanmadi, ayni nesne
  assert.equal(err.status, 502);
  assert.equal(err.code, 'BROKER_UNAVAILABLE');
  assert.equal(env.published.length, 2); // 3. komut denenmedi
  assert.equal(env.db.txCount, 0);
  assert.equal(env.audits.length, 0);
  assert.equal(env.events.includes('q:resolve'), false);
  assert.equal(env.world.logs.length, 1);
  assert.equal(env.world.logs[0].status, 'sent');
  assert.equal(env.world.logs[0].resolved_at, null);
  assert.deepEqual(writesToEndpoints(env.queries), []);
  assert.ok(env.logger.lines.some((l) => /yayin 1\/3/.test(l)));
});

test('closeAll: ilk yayin 502 -> ayni sekilde cozme yok (tek komut)', async () => {
  const env = makeEnv({
    endpoints: [light('l1', 5, 'Salon')],
    logs: [logRow(1)],
    publish: async () => {
      throw httpError(502, 'MQTT broker bağlantısı yok; komut iletilemedi.', 'BROKER_UNAVAILABLE');
    },
  });
  const err = await rejects(env.svc.closeAll({ actor: ACTOR, homeId: HOME_A }));
  assert.equal(err.code, 'BROKER_UNAVAILABLE');
  assert.equal(env.world.logs[0].status, 'sent');
  assert.equal(env.events.filter((e) => e === 'publish').length, 1);
});

test('closeAll: yayinci 409 firlatirsa da olduğu gibi yukari (DEVICE_OFFLINE korunur)', async () => {
  const offline = httpError(409, 'Cihaz çevrimdışı.', 'DEVICE_OFFLINE', { device_online: false });
  const env = makeEnv({ endpoints: [light('l1', 5, 'Salon')], publish: async () => { throw offline; } });
  const err = await rejects(env.svc.closeAll({ actor: ACTOR, homeId: HOME_A }));
  assert.equal(err, offline);
});

test('closeAll: noticeId/includeShutters dogrulamasi -> 400 VALIDATION, DB\'ye HIC dokunmadan', async () => {
  for (const bad of [0, -1, 1.5, 'abc', '1.5', '-3', '', ' 5', true, {}, [], NaN, 2147483648, '99999999999']) {
    const env = makeEnv({ endpoints: standardEndpoints() });
    const err = await rejects(env.svc.closeAll({ actor: ACTOR, homeId: HOME_A, noticeId: bad }));
    assert.equal(err.status, 400, `noticeId ${JSON.stringify(bad)}`);
    assert.equal(err.code, 'VALIDATION');
    assert.equal(env.queries.length, 0);
    assert.equal(env.published.length, 0);
  }
  for (const bad of ['true', 'false', 0, 1, {}, 'yes']) {
    const env = makeEnv({ endpoints: standardEndpoints() });
    const err = await rejects(env.svc.closeAll({ actor: ACTOR, homeId: HOME_A, includeShutters: bad }));
    assert.equal(err.status, 400, `includeShutters ${JSON.stringify(bad)}`);
    assert.equal(err.code, 'VALIDATION');
    assert.equal(env.queries.length, 0);
  }
});

test('closeAll: gecerli noticeId (sayi ve rakam metni) kabul edilir; resolve parametresi sayidir', async () => {
  for (const [given, expected] of [[1, 1], ['1', 1], [2147483647, 2147483647], [undefined, null], [null, null]]) {
    const env = makeEnv({ endpoints: [light('l1', 5, 'Salon')], logs: [logRow(1)] });
    await env.svc.closeAll({ actor: ACTOR, homeId: HOME_A, noticeId: given });
    const q = env.queries.find((x) => x.text === SQL.resolveNotice);
    assert.equal(q.params[2], expected, `noticeId ${String(given)}`);
  }
});

// ==============================================================================
// closeAll: hicbir sey acik degil
// ==============================================================================

test('closeAll: hicbir sey acik degil -> yayin YOK, bildirim yine cozulur, sifirlarla doner', async () => {
  const env = makeEnv({ endpoints: [light('l1', 5, 'Salon', false), shutter('s1', 1, 1, 0)], logs: [logRow(1, { status: 'sent' })] });
  const out = await env.svc.closeAll({ actor: ACTOR, homeId: HOME_A });
  assert.equal(env.published.length, 0);
  assert.equal(out.closed_lights, 0);
  assert.equal(out.closed_shutters, 0);
  assert.equal(out.closed_count, 0);
  assert.deepEqual(out.command_ids, []);
  assert.equal(out.command_id, null);
  assert.equal(out.delivered, true);
  assert.equal(out.device_online, true);
  assert.equal(out.resolved, true);
  assert.equal(out.notice_id, 1);
  assert.equal(out.message, 'Sunucu kayıtlarına göre açık lamba ya da panjur yok; cihaza komut gönderilmedi, bildirim kapatıldı.');
  assert.equal(out.nothing_to_do, true); // istemci 'kapatildi' gostermemeli (F2)
  const row = env.world.logs[0];
  assert.equal(row.status, 'resolved');
  assert.equal(row.command_id, null); // komut yok -> command_id NULL
  assert.equal(row.resolved_by_user_id, ACTOR_ID);
  assert.equal(env.audits.length, 1); // yine denetim kaydi
});

test('closeAll: hicbir sey acik degil ve cozulecek bildirim yok -> elle satir EKLENMEZ, resolved:false', async () => {
  const env = makeEnv({ endpoints: [light('l1', 5, 'Salon', false)], logs: [] });
  const out = await env.svc.closeAll({ actor: ACTOR, homeId: HOME_A });
  assert.equal(env.world.logs.length, 0);
  assert.equal(out.resolved, false);
  assert.equal(out.notice_id, null);
  assert.equal(out.message, 'Sunucu kayıtlarına göre açık lamba ya da panjur yok; cihaza komut gönderilmedi.');
  assert.equal(out.nothing_to_do, true);
});

// ==============================================================================
// closeAll: bildirim cozme
// ==============================================================================

test('closeAll: bildirim cozer (ortak yol): durum resolved, cozen kullanici, via, ilk komut kimligi', async () => {
  const env = makeEnv({ endpoints: standardEndpoints(), logs: [logRow(7, { status: 'sent' })] });
  const out = await env.svc.closeAll({ actor: ACTOR, homeId: HOME_A });
  assert.equal(out.resolved, true);
  assert.equal(out.notice_id, 7);
  const row = env.world.logs[0];
  assert.equal(row.status, 'resolved');
  assert.equal(row.resolved_by_user, true);
  assert.ok(row.resolved_at);
  assert.equal(row.resolved_by_user_id, ACTOR_ID);
  assert.equal(row.resolved_via, 'close_all');
  assert.equal(row.command_id, 'cmd000000001');
  assert.equal(env.world.logs.length, 1); // elle satir EKLENMEDI
  const q = env.queries.find((x) => x.text === SQL.resolveNotice);
  assert.deepEqual(q.params, [ACTOR_ID, 'cmd000000001', null, HOME_A]);
});

test('closeAll: no_recipients satiri da cozulur', async () => {
  const env = makeEnv({ endpoints: [light('l1', 5, 'Salon')], logs: [logRow(1, { status: 'no_recipients' })] });
  const out = await env.svc.closeAll({ actor: ACTOR, homeId: HOME_A });
  assert.equal(out.resolved, true);
  assert.equal(env.world.logs[0].status, 'resolved');
});

test('closeAll: yeniden talep edilebilir / nihai-olmayan satirlara (claimed/failed/skipped_offline/clear) ASLA dokunulmaz', async () => {
  const states = ['claimed', 'failed', 'skipped_offline', 'clear'];
  // 1) ortak yol: cozulebilir satir yok -> hicbiri cozulmez, elle satir eklenir
  let logs = states.map((status, i) => logRow(i + 1, { status, local_date: `2026-10-0${i + 1}` }));
  let env = makeEnv({ endpoints: [light('l1', 5, 'Salon')], logs });
  let out = await env.svc.closeAll({ actor: ACTOR, homeId: HOME_A });
  assert.equal(out.resolved, false);
  assert.equal(out.notice_id, null);
  for (let i = 0; i < states.length; i += 1) {
    assert.equal(env.world.logs[i].status, states[i]);
    assert.equal(env.world.logs[i].resolved_at, null);
    assert.equal(env.world.logs[i].resolved_by_user_id, undefined);
  }
  assert.equal(env.world.logs.length, states.length + 1);
  assert.equal(env.world.logs[states.length].status, 'manual');

  // 2) acik noticeId ile bile: o satir devam ediyorsa cozulmez
  for (let i = 0; i < states.length; i += 1) {
    logs = states.map((status, j) => logRow(j + 1, { status, local_date: `2026-10-0${j + 1}` }));
    env = makeEnv({ endpoints: [light('l1', 5, 'Salon')], logs });
    out = await env.svc.closeAll({ actor: ACTOR, homeId: HOME_A, noticeId: i + 1 });
    assert.equal(out.resolved, false, states[i]);
    assert.equal(env.world.logs[i].status, states[i]);
    assert.equal(env.world.logs[i].resolved_at, null);
  }
});

test('closeAll: ortak yolda en yeni CozULEBILIR satir secilir (daha yeni claimed/failed atlanir)', async () => {
  const env = makeEnv({
    endpoints: [light('l1', 5, 'Salon')],
    logs: [
      logRow(1, { local_date: '2026-09-28', status: 'sent' }),
      logRow(2, { local_date: '2026-09-29', status: 'no_recipients' }),
      logRow(3, { local_date: '2026-09-30', status: 'failed' }),
      logRow(4, { local_date: '2026-10-01', status: 'claimed' }),
      logRow(5, { local_date: null, status: 'manual' }), // elle kapatma satiri: aday degil
    ],
  });
  const out = await env.svc.closeAll({ actor: ACTOR, homeId: HOME_A });
  assert.equal(out.notice_id, 2);
  assert.deepEqual(env.world.logs.map((l) => l.status), ['sent', 'resolved', 'failed', 'claimed', 'manual']);
});

test('closeAll: acik noticeId baska evin / var olmayan satirsa cozulmez, elle satir eklenir', async () => {
  const env = makeEnv({
    homes: [{ id: HOME_A, name: 'A', mqtt_username: TOPIC }, { id: HOME_B, name: 'B', mqtt_username: 'h_other' }],
    endpoints: [light('l1', 5, 'Salon')],
    logs: [logRow(1, { home_id: HOME_B, status: 'sent' })],
  });
  let out = await env.svc.closeAll({ actor: ACTOR, homeId: HOME_A, noticeId: 1 });
  assert.equal(out.resolved, false);
  assert.equal(env.world.logs[0].status, 'sent');
  assert.equal(env.world.logs[0].resolved_at, null);

  out = await env.svc.closeAll({ actor: ACTOR, homeId: HOME_A, noticeId: 424242 });
  assert.equal(out.resolved, false);
  assert.equal(env.world.logs.filter((l) => l.status === 'manual').length, 2);
});

test('closeAll: ayni noticeId ikinci dokunus -> tekrar cozulmez; acik sey varsa yine yayin + elle satir', async () => {
  const env = makeEnv({ endpoints: [light('l1', 5, 'Salon')], logs: [logRow(1, { status: 'sent' })] });
  const first = await env.svc.closeAll({ actor: ACTOR, homeId: HOME_A, noticeId: 1 });
  assert.equal(first.resolved, true);
  const resolvedAt = env.world.logs[0].resolved_at;
  assert.equal(env.world.logs.length, 1);

  const second = await env.svc.closeAll({ actor: ACTOR, homeId: HOME_A, noticeId: 1 }); // lamba hala "acik" (state yankisi gelmedi)
  assert.equal(second.resolved, false);
  assert.equal(second.notice_id, null);
  assert.equal(env.published.length, 2); // zararsiz yeniden kapatma
  assert.equal(env.world.logs[0].status, 'resolved');
  assert.equal(env.world.logs[0].command_id, 'cmd000000001'); // ilk cozumun kaydi ezilmedi
  assert.equal(env.world.logs[0].resolved_at, resolvedAt);
  assert.equal(env.world.logs.length, 2);
  assert.equal(env.world.logs[1].status, 'manual');
});

test('closeAll: ikinci dokunus ve artik acik sey yoksa -> yayin yok, elle satir yok', async () => {
  const env = makeEnv({ endpoints: [light('l1', 5, 'Salon', false)], logs: [logRow(1, { status: 'resolved', resolved_at: NOW })] });
  const out = await env.svc.closeAll({ actor: ACTOR, homeId: HOME_A, noticeId: 1 });
  assert.equal(out.resolved, false);
  assert.equal(env.published.length, 0);
  assert.equal(env.world.logs.length, 1);
});

test('closeAll: elle kapatma satiri sutunlari (cozulecek bildirim yokken)', async () => {
  const env = makeEnv({ endpoints: standardEndpoints(), logs: [] });
  const out = await env.svc.closeAll({ actor: ACTOR, homeId: HOME_A });
  assert.equal(out.resolved, false);
  assert.equal(out.notice_id, null);
  assert.equal(env.world.logs.length, 1);
  const row = env.world.logs[0];
  assert.equal(row.home_id, HOME_A);
  assert.equal(row.status, 'manual');
  assert.equal(row.local_date, null); // UNIQUE (home_id, local_date) ile cakismaz
  assert.equal(row.open_lights_count, 2);
  assert.equal(row.open_shutters_count, 1);
  assert.equal(row.summary_text, '2 lamba ve 1 panjur tek tıkla kapatıldı.');
  assert.equal(row.resolved_by_user, true);
  assert.ok(row.resolved_at);
  assert.equal(row.resolved_via, 'close_all');
  assert.equal(row.resolved_by_user_id, ACTOR_ID);
  assert.equal(row.command_id, 'cmd000000001');
  assert.doesNotMatch(row.summary_text, /Salon|Mutfak/); // oda adi / kisisel veri yok
});

test('closeAll: servis oturumu (actor.userId yok) -> cozen kullanici NULL, audit yine yazilir', async () => {
  const env = makeEnv({ endpoints: [light('l1', 5, 'Salon')], logs: [logRow(1)] });
  const sessionActor = { userId: null, globalRole: 'service_session', access: 'service_session' };
  await env.svc.closeAll({ actor: sessionActor, homeId: HOME_A });
  assert.equal(env.world.logs[0].resolved_by_user_id, null);
  assert.equal(env.audits.length, 1);
  assert.equal(env.audits[0].actor, sessionActor);
  // actor hic verilmese de calisir
  const env2 = makeEnv({ endpoints: [light('l1', 5, 'Salon')], logs: [logRow(1)] });
  await env2.svc.closeAll({ homeId: HOME_A });
  assert.equal(env2.world.logs[0].resolved_by_user_id, null);
});

test('closeAll: cozme SQL durum kisiti ZORUNLU (ic ve dis WHERE), devam eden durum adi icermez', () => {
  const sql = SQL.resolveNotice;
  const restriction = "status IN ('sent', 'no_recipients', 'sending')";
  assert.equal(sql.split(restriction).length - 1, 2); // alt sorgu + dis WHERE
  assert.match(sql, /WHERE id = COALESCE\(\$3::int, \(SELECT id FROM peace_notification_logs WHERE home_id = \$4::uuid AND local_date IS NOT NULL AND resolved_at IS NULL AND status IN/);
  assert.match(sql, /AND home_id = \$4::uuid AND resolved_at IS NULL AND status IN \('sent', 'no_recipients', 'sending'\) RETURNING id$/);
  for (const forbidden of ['claimed', 'failed', 'skipped_offline', "'clear'", "'manual'"]) {
    assert.equal(sql.includes(forbidden), false, forbidden);
  }
  for (const col of ["status = 'resolved'", 'resolved_by_user = TRUE', 'resolved_at = CURRENT_TIMESTAMP', 'resolved_by_user_id = $1::uuid', "resolved_via = 'close_all'", 'command_id = $2::varchar', 'updated_at = CURRENT_TIMESTAMP']) {
    assert.ok(sql.includes(col), col);
  }
  assert.match(SQL.insertManual, /'manual'/);
  assert.doesNotMatch(SQL.insertManual, /local_date/);
});

// ==============================================================================
// closeAll: yayin sonrasi kayit, audit, sira
// ==============================================================================

test('closeAll: once YAYIN sonra KAYIT: tum yayinlar bitmeden tek transaction acilmaz; audit ayni transaction icinde', async () => {
  const env = makeEnv({ endpoints: standardEndpoints(), logs: [logRow(1)] });
  await env.svc.closeAll({ actor: ACTOR, homeId: HOME_A });
  assert.deepEqual(env.events, ['publish', 'publish', 'tx:begin', 'q:resolve', 'audit', 'tx:commit']);
  assert.equal(env.db.txCount, 1);
});

test('closeAll: audit bicimi (event, homeId, actor, details)', async () => {
  const env = makeEnv({ endpoints: standardEndpoints(), logs: [logRow(3)] });
  await env.svc.closeAll({ actor: ACTOR, homeId: HOME_A, noticeId: 3 });
  assert.equal(env.audits.length, 1);
  const a = env.audits[0];
  assert.equal(a.event, 'peace_close_all');
  assert.equal(a.homeId, HOME_A);
  assert.equal(a.actor, ACTOR);
  assert.deepEqual(a.details, {
    closed_lights: 2,
    closed_shutters: 1,
    skipped_count: 0,
    notice_id: 3,
    requested_notice_id: 3,
    resolved: true,
    command_ids: ['cmd000000001', 'cmd000000002'],
  });
  // audit'e gecen q, transaction'in q'sudur: DeviceService._audit(q, ...) ile ayni imza
  let seenQ = null;
  const env2 = makeEnv({ endpoints: [light('l1', 5, 'Salon')], audit: async (q) => { seenQ = q; } });
  await env2.svc.closeAll({ actor: ACTOR, homeId: HOME_A });
  assert.equal(typeof seenQ, 'function');
  await seenQ(SQL.topic, [HOME_A]); // (text, params) => Promise
});

test('closeAll: db.withTransaction yoksa ardisik sorguyla calisir (yedek yol)', async () => {
  const env = makeEnv({ endpoints: [light('l1', 5, 'Salon')], logs: [logRow(1)], noTx: true });
  const out = await env.svc.closeAll({ actor: ACTOR, homeId: HOME_A });
  assert.equal(out.resolved, true);
  assert.equal(env.world.logs[0].status, 'resolved');
  assert.equal(env.audits.length, 1);
});

test('closeAll: yayin SONRASI kayit/audit hatasi -> komutlar mutlak: loglanir, basarili doner (resolved:false), transaction geri alinir', async () => {
  for (const failing of ['audit', 'resolve']) {
    const env = makeEnv({
      endpoints: standardEndpoints(),
      logs: [logRow(1, { status: 'sent' })],
      audit: failing === 'audit' ? async () => { throw new Error('audit tablosu yok'); } : undefined,
      failQuery: failing === 'resolve' ? (text) => text === SQL.resolveNotice : undefined,
    });
    const out = await env.svc.closeAll({ actor: ACTOR, homeId: HOME_A, noticeId: 1 });
    assert.equal(out.delivered, true, failing);
    assert.equal(out.resolved, false);
    assert.equal(out.notice_id, null);
    assert.equal(out.closed_lights, 2);
    assert.equal(out.closed_shutters, 1);
    assert.deepEqual(out.command_ids, ['cmd000000001', 'cmd000000002']);
    assert.equal(env.published.length, 2);
    assert.equal(env.world.logs.length, 1); // geri alindi
    assert.equal(env.world.logs[0].status, 'sent');
    assert.ok(env.logger.lines.some((l) => l.startsWith('error:') && /komutlar iletildi ama kayit yazilamadi/.test(l)));
    assert.deepEqual(writesToEndpoints(env.queries), []);
  }
});

test('closeAll: sunucu hatasi mesaji logda kisisel veri/oda adi icermez (yalniz ev kimligi oneki)', async () => {
  const env = makeEnv({ endpoints: standardEndpoints() });
  await env.svc.closeAll({ actor: ACTOR, homeId: HOME_A });
  const joined = env.logger.lines.join('\n');
  assert.doesNotMatch(joined, /Salon|Mutfak|Gül/);
  assert.doesNotMatch(joined, new RegExp(HOME_A)); // tam kimlik yok
  assert.match(joined, new RegExp(HOME_A.slice(0, 8)));
});

// ==============================================================================
// closeAll: yanit sekli
// ==============================================================================

test('closeAll: v1 yanit anahtarlari KALIR + v2 anahtarlari', async () => {
  const env = makeEnv({ endpoints: standardEndpoints(), logs: [logRow(1)] });
  const out = await env.svc.closeAll({ actor: ACTOR, homeId: HOME_A });
  assert.deepEqual(Object.keys(out).sort(), [
    'closed_count', 'closed_lights', 'closed_shutters', 'command_id', 'command_ids', 'delivered', 'device_online', 'message', 'nothing_to_do', 'notice_id', 'resolved',
    'skipped_count',
  ]);
  for (const v1 of ['closed_count', 'delivered', 'device_online', 'command_id', 'message']) assert.ok(v1 in out, v1);
  assert.equal(out.delivered, true);
  assert.equal(out.device_online, true);
  assert.equal(typeof out.resolved, 'boolean');
  assert.equal(out.closed_count, out.closed_lights);
});

// ==============================================================================
// closeAll: gruplama / gecikme
// ==============================================================================

function bigEnv(lightCount, shutterCount) {
  const endpoints = [plug('plug', 40)];
  for (let i = 0; i < lightCount; i += 1) endpoints.push(light(`bl${i}`, 5 + i, 'Salon'));
  for (let p = 1; p <= shutterCount; p += 1) endpoints.push(shutter(`bs${p}`, 2 * p - 1, p % 2 ? p : null, 100));
  return makeEnv({ endpoints, logs: [logRow(1)] });
}

test('closeAll: 36 komut -> her 16 komuttan sonra 150 ms bekler (16. ve 32. sonrasi), son parcadan sonra beklemez', async () => {
  const env = bigEnv(24, 12);
  const out = await env.svc.closeAll({ actor: ACTOR, homeId: HOME_A });
  assert.equal(env.published.length, 36);
  assert.equal(out.command_ids.length, 36);
  assert.equal(new Set(out.command_ids).size, 36);
  assert.deepEqual(env.sleeps, [150, 150]);
  const shape = env.events.filter((e) => e === 'publish' || e.startsWith('sleep'));
  assert.deepEqual(
    [shape.indexOf('sleep:150'), shape.lastIndexOf('sleep:150')],
    [16, 33] // 16 yayindan sonra, sonra 16 daha + onceki uyku
  );
  // yayin tamamen bittikten sonra kayit
  assert.ok(env.events.indexOf('tx:begin') > env.events.lastIndexOf('publish'));
});

test('closeAll: tam 16 komut -> bekleme YOK; 17 komut -> 1 bekleme; tek komut -> yok', async () => {
  let env = bigEnv(16, 0);
  await env.svc.closeAll({ actor: ACTOR, homeId: HOME_A });
  assert.equal(env.published.length, 16);
  assert.deepEqual(env.sleeps, []);

  env = bigEnv(17, 0);
  await env.svc.closeAll({ actor: ACTOR, homeId: HOME_A });
  assert.equal(env.published.length, 17);
  assert.deepEqual(env.sleeps, [150]);

  env = makeEnv({ endpoints: standardEndpoints() });
  await env.svc.closeAll({ actor: ACTOR, homeId: HOME_A });
  assert.deepEqual(env.sleeps, []);
});

test('closeAll: yayin PUBACK beklenerek ardisik (bir onceki bitmeden sonraki baslamaz)', async () => {
  let inFlight = 0;
  let maxInFlight = 0;
  const env = makeEnv({
    endpoints: [light('l1', 5, 'Salon'), light('l2', 6, 'Mutfak'), light('l3', 7, 'Balkon'), plug('p', 8)],
    publish: async () => {
      inFlight += 1;
      maxInFlight = Math.max(maxInFlight, inFlight);
      await new Promise((resolve) => setImmediate(resolve));
      inFlight -= 1;
    },
  });
  await env.svc.closeAll({ actor: ACTOR, homeId: HOME_A });
  assert.equal(env.published.length, 3);
  assert.equal(maxInFlight, 1);
});

// ==============================================================================
// endpoints'e asla yazilmaz
// ==============================================================================

test('endpoints tablosuna HICBIR yolda yazilmaz (calisma zamani)', async () => {
  const scenarios = [
    makeEnv({ endpoints: standardEndpoints(), logs: [logRow(1)] }),
    makeEnv({ endpoints: [light('l1', 5, 'Salon'), plug('p', 6)], logs: [] }),
    makeEnv({ endpoints: [light('l1', 5, 'Salon', false)], logs: [] }),
  ];
  for (const env of scenarios) {
    await env.svc.closeAll({ actor: ACTOR, homeId: HOME_A });
    await env.svc.getSettings({ homeId: HOME_A });
    assert.deepEqual(writesToEndpoints(env.queries), []);
    for (const e of env.world.endpoints) {
      // sahte dunya endpoint satirlarini hic degistirmedi
      assert.ok(e.current_state === true || e.current_state === false);
    }
  }
  // lambalar acik kaldi (iyimser yazim yok): cihazin state yankisi gelene kadar DB'ye guvenilir
  const env = makeEnv({ endpoints: [light('l1', 5, 'Salon')], logs: [] });
  await env.svc.closeAll({ actor: ACTOR, homeId: HOME_A });
  assert.equal(env.world.endpoints[0].current_state, true);
});

test('statik: kaynakta endpoints uzerinde UPDATE/INSERT/DELETE yok; SQL yalniz bilinen tablolari kullanir', () => {
  const file = path.join(__dirname, '..', '..', 'src', 'services', 'peace_service.js');
  const source = fs.readFileSync(file, 'utf8');
  const code = source.replace(/\/\*[\s\S]*?\*\//g, '').replace(/^\s*\/\/.*$/gm, '');
  assert.doesNotMatch(code, /\b(UPDATE|INSERT\s+INTO|DELETE\s+FROM)\s+endpoints\b/i);
  assert.doesNotMatch(code, /\bUPDATE\s+endpoints\b/i);
  assert.doesNotMatch(code, /Math\.random/);
  assert.doesNotMatch(code, /all_shutters_down/); // kapali motorlari yeniden calistirmaz
  // sorgu metinleri
  for (const text of Object.values(SQL)) {
    assert.doesNotMatch(text, /\b(UPDATE|INSERT\s+INTO|DELETE\s+FROM)\s+endpoints\b/i);
  }
  assert.ok(
    source.split('\n').length <= 640,
    'dosya boyutu makul kalmali (hedef ~500; cok panolu koruma ile ~590; DAIRE-01 ortak "isiklari kapat" kurali ile ~620)'
  );
});

// ==============================================================================
// Varsayilan bagimliliklar
// ==============================================================================

test('varsayilanlar: snapshot/text/sleep/logger/now verilmeden de kurulur ve gercek peace_text ile calisir', async () => {
  const base = makePeaceWorld({
    clock: { ms: NOW },
    homes: [{ id: HOME_A, name: 'Ev', mqtt_username: TOPIC }],
    devices: [liveDevice()],
    endpoints: [light('l1', 5, 'Yatak Odası')],
  });
  const db = {
    query: (text, params) => {
      if (text === SQL.home) return Promise.resolve({ rows: [{ id: HOME_A, peace_notification_enabled: true, peace_notification_time: '23:30', timezone: 'Europe/Istanbul' }] });
      if (text === SQL.lastNotice) return Promise.resolve({ rows: [] });
      return base.db.query(text, params);
    },
  };
  const svc = createPeaceService({ db, publishCommand: async () => {}, newCommandId: () => 'x', audit: async () => {}, httpError });
  const out = await svc.getSettings({ homeId: HOME_A });
  assert.equal(out.summary_text, 'Yatak Odasında 1 lamba açık.');
});

test('varsayilan sleep gercekten bekler (setTimeout tabanli), 1 komut oldugunda cagrilmaz', async () => {
  // 17 plug'li lamba -> bir sleep; varsayilan sleep 150 ms: toplam sure >= ~140 ms olmali
  const base = makePeaceWorld({
    clock: { ms: NOW },
    homes: [{ id: HOME_A, name: 'Ev', mqtt_username: TOPIC }],
    devices: [liveDevice()],
    endpoints: [plug('p', 40), ...Array.from({ length: 17 }, (_, i) => light(`l${i}`, 5 + i, 'Salon'))],
  });
  const db = {
    query: (text, params) => {
      if (text === SQL.topic) return Promise.resolve({ rows: [{ mqtt_username: TOPIC }] });
      if (text === SQL.hasPlug) return Promise.resolve({ rows: [{ has_plug: true }] });
      if (text === SQL.resolveNotice) return Promise.resolve({ rows: [] });
      if (text === SQL.insertManual) return Promise.resolve({ rows: [] });
      return base.db.query(text, params);
    },
  };
  let n = 0;
  const svc = createPeaceService({
    db, publishCommand: async () => {}, newCommandId: () => `id${++n}`, audit: async () => {}, httpError, logger: makeLogger(),
  });
  const started = Date.now();
  const out = await svc.closeAll({ actor: ACTOR, homeId: HOME_A });
  assert.equal(out.command_ids.length, 17);
  assert.ok(Date.now() - started >= 140);
});

test('mesaj yardimcilari: tam sayi, cogul eki yok, UTF-8', () => {
  assert.equal(helpers.buildCloseMessage({ closedLights: 1, closedShutters: 0, resolved: false }), 'Huzur modu: 1 lamba için kapatma komutu cihaza iletildi.');
  assert.equal(helpers.buildCloseMessage({ closedLights: 3, closedShutters: 2, resolved: true }), 'Huzur modu: 3 lamba ve 2 panjur için kapatma komutu cihaza iletildi.');
  assert.equal(helpers.buildManualSummary(0, 2), '2 panjur tek tıkla kapatıldı.');
  assert.equal(helpers.normalizeTime('00:00'), '00:00');
  assert.equal(helpers.normalizeTime('23:59'), '23:59');
  assert.equal(helpers.normalizeTime(null), '23:30');
});

// ==============================================================================
// F1: 'sending' satiri cozulur (push notice_id'si push aninda 'sending' olan satirdir)
// ==============================================================================

const { SQL: REMINDER_SQL } = require('../../src/peace_reminder');

test("closeAll: 'sending' satiri notice_id ile cozulur (yavas FCM / cokmus surec); degerlendirici sonradan ezmez, yeniden talep/gonderim olmaz", async () => {
  const env = makeEnv({ endpoints: [light('l1', 5, 'Salon')], logs: [logRow(1, { status: 'sending', attempts: 1, push_sent_count: 0 })] });
  const out = await env.svc.closeAll({ actor: ACTOR, homeId: HOME_A, noticeId: 1 });
  assert.equal(out.resolved, true);
  assert.equal(out.notice_id, 1);
  assert.equal(env.world.logs.length, 1); // elle satir EKLENMEDI
  assert.equal(env.world.logs[0].status, 'resolved');
  assert.equal(env.world.logs[0].resolved_by_user_id, ACTOR_ID);

  // Degerlendirici sonradan: finish cozulmus satira yazmaz (rowCount 0, hata yok), markSending/claim eslesmez
  const finish = await env.db.query(REMINDER_SQL.finish, [1, 'sent', 2, 1, 'ozet', '{}', 1, 1]);
  assert.equal(finish.rowCount, 0);
  const marked = await env.db.query(REMINDER_SQL.markSending, [1, 1]);
  assert.equal(marked.rowCount, 0);
  const claimed = await env.db.query(REMINDER_SQL.claim, [HOME_A, '2026-10-01', new Date(NOW).toISOString(), 6]);
  assert.equal(claimed.rowCount, 0); // ayni gece ikinci bildirim talep edilemez
  assert.equal(env.world.logs[0].status, 'resolved');
});

test("closeAll: noticeId verilmese de en yeni cozulebilir satir 'sending' ise o cozulur (orphan satir)", async () => {
  const env = makeEnv({ endpoints: [light('l1', 5, 'Salon')], logs: [logRow(1, { local_date: '2026-09-30', status: 'sent' }), logRow(2, { status: 'sending' })] });
  const out = await env.svc.closeAll({ actor: ACTOR, homeId: HOME_A });
  assert.equal(out.notice_id, 2);
  assert.deepEqual(env.world.logs.map((l) => l.status), ['sent', 'resolved']);
});

test("claim/markSending kaynak sozlesmesi: 'resolved' satir yeniden talep edilemez, finish yalniz claimed/sending'e yazar", () => {
  assert.match(REMINDER_SQL.markSending, /status = 'claimed'/);
  assert.match(REMINDER_SQL.finish, /status IN \('claimed', 'sending'\)/);
  for (const sql of [REMINDER_SQL.claim, REMINDER_SQL.markSending, REMINDER_SQL.finish]) assert.equal(sql.includes("'resolved'"), false);
  assert.match(REMINDER_SQL.claim, /status IN \('skipped_offline', 'skipped_hazard', 'failed'\)/);
});

// ==============================================================================
// F2: "acik sey yok" yaniti kapatildi demez
// ==============================================================================

test('closeAll: nothing_to_do yalniz komut gonderilmediginde true; komut varsa false', async () => {
  let env = makeEnv({ endpoints: [light('l1', 5, 'Salon', false)] });
  let out = await env.svc.closeAll({ actor: ACTOR, homeId: HOME_A });
  assert.equal(out.nothing_to_do, true);
  assert.equal(out.skipped_count, 0);
  assert.equal(out.delivered, true); // v1 uyumu: istemci hata gostermesin
  assert.match(out.message, /komut gönderilmedi/);

  env = makeEnv({ endpoints: [light('l1', 5, 'Salon')] });
  out = await env.svc.closeAll({ actor: ACTOR, homeId: HOME_A });
  assert.equal(out.nothing_to_do, false);
});

// ==============================================================================
// F3: cok panolu ev - ev konusu tum panolara gider
// ==============================================================================

const TWO_BOARDS = () => [liveDevice(DEV_A), liveDevice(DEV_B)];

test('closeAll (cok panolu): ayni kanalda baska panoda priz -> o kanal GONDERILMEZ, digerleri gider, bildirim COZULMEZ', async () => {
  const env = makeEnv({
    devices: TWO_BOARDS(),
    endpoints: [light('a5', 5, 'Salon', true, DEV_A), light('a6', 6, 'Mutfak', true, DEV_A), plug('bp', 5, DEV_B)],
    logs: [logRow(1, { status: 'sent' })],
  });
  const out = await env.svc.closeAll({ actor: ACTOR, homeId: HOME_A, noticeId: 1 });
  assert.deepEqual(env.published.map((p) => p.payload), [{ relay: 6, state: false, id: 'cmd000000001' }]);
  assert.equal(out.closed_lights, 1);
  assert.equal(out.skipped_count, 1);
  assert.equal(out.nothing_to_do, false);
  assert.equal(out.resolved, false); // ev gercekte kapanmadi
  assert.equal(out.notice_id, null);
  assert.equal(env.world.logs[0].status, 'sent');
  assert.equal(env.world.logs.at(-1).status, 'manual'); // tiklama gunlugu (1 lamba kapatildi)
  assert.equal(env.world.logs.at(-1).open_lights_count, 1);
  assert.equal(out.message, 'Huzur modu: 1 lamba için kapatma komutu cihaza iletildi. 1 lamba birden fazla panonun ortak bağlantısı nedeniyle uzaktan kapatılamadı; lütfen elle kontrol edin.');
  assert.equal(env.audits[0].details.skipped_count, 1);
  assert.deepEqual(env.queries.find((q) => q.text === SQL.layout).params, [HOME_A]);
  assert.ok(env.logger.lines.some((l) => l.startsWith('warn:') && /ortak konu/.test(l)));
});

test('closeAll (cok panolu): hepsi atlanirsa yayin yok, elle satir yok, bildirim acik, audit yine yazilir', async () => {
  const env = makeEnv({
    devices: TWO_BOARDS(),
    endpoints: [light('a5', 5, 'Salon', true, DEV_A), plug('bp', 5, DEV_B)],
    logs: [logRow(1, { status: 'sent' })],
  });
  const out = await env.svc.closeAll({ actor: ACTOR, homeId: HOME_A });
  assert.equal(env.published.length, 0);
  assert.equal(out.closed_lights, 0);
  assert.equal(out.skipped_count, 1);
  assert.equal(out.nothing_to_do, false);
  assert.equal(out.resolved, false);
  assert.equal(out.command_id, null);
  assert.equal(out.message, '1 lamba birden fazla panonun ortak bağlantısı nedeniyle uzaktan kapatılamadı; lütfen elle kontrol edin.');
  assert.equal(env.world.logs.length, 1);
  assert.equal(env.world.logs[0].status, 'sent');
  assert.equal(env.audits.length, 1);
  assert.equal(env.events.includes('q:resolve'), false);
});

test('closeAll (cok panolu): iki panoda ayni kanal da isik ise guvenli (tek role komutu); baska panoda panjur rolesi ise cakisir', async () => {
  let env = makeEnv({
    devices: TWO_BOARDS(),
    endpoints: [light('a5', 5, 'Salon', true, DEV_A), light('b5', 5, 'Salon', false, DEV_B), plug('ap', 9, DEV_A)],
  });
  let out = await env.svc.closeAll({ actor: ACTOR, homeId: HOME_A });
  assert.deepEqual(env.published.map((p) => p.payload.relay), [5]);
  assert.equal(out.skipped_count, 0);

  env = makeEnv({
    devices: TWO_BOARDS(),
    endpoints: [light('a1', 1, 'Salon', true, DEV_A), shutter('bs1', 1, 1, 0, 'Salon', DEV_B), plug('ap', 9, DEV_A)],
  });
  out = await env.svc.closeAll({ actor: ACTOR, homeId: HOME_A, includeShutters: false });
  assert.equal(env.published.length, 0);
  assert.equal(out.skipped_count, 1);
});

test('closeAll (cok panolu): panjur cifti baska panoda KAPALI ise atlanir; tum panolarda acik ise tek down', async () => {
  const env = makeEnv({
    devices: TWO_BOARDS(),
    endpoints: [
      shutter('a1', 1, 1, 100, 'Salon', DEV_A), shutter('a2', 2, 1, 100, 'Salon', DEV_A),
      shutter('b1', 1, 1, 0, 'Salon', DEV_B), shutter('b2', 2, 1, 0, 'Salon', DEV_B), // cift 1: B'de kapali -> belirsiz
      shutter('a3', 3, 2, 100, 'Mutfak', DEV_A), shutter('b3', 3, 2, 100, 'Mutfak', DEV_B), // cift 2: ikisinde de acik
    ],
    logs: [logRow(1)],
  });
  const out = await env.svc.closeAll({ actor: ACTOR, homeId: HOME_A });
  assert.deepEqual(env.published.map((p) => p.payload), [{ shutter: 2, cmd: 'down', id: 'cmd000000001' }]);
  assert.equal(out.closed_shutters, 2);
  assert.equal(out.skipped_count, 1);
  assert.equal(out.resolved, false);
  assert.match(out.message, /1 panjur birden fazla panonun ortak bağlantısı/);
});

test('closeAll: tek panolu evde ya da plug yoksa duzen sorgusu CALISMAZ; layout hatasi yayindan ONCE yukari cikar', async () => {
  // tek pano + plug + panjur
  let env = makeEnv({ endpoints: [light('l1', 5, 'Salon'), plug('p', 6), shutter('s1', 1, 1, 100)] });
  await env.svc.closeAll({ actor: ACTOR, homeId: HOME_A });
  assert.equal(env.queries.some((q) => q.text === SQL.layout), false);
  assert.equal(env.published.length, 2);

  // cok pano, plug yok, panjur yok -> all_lights_off (tum panolarin isiklari), sorgu yok
  env = makeEnv({ devices: TWO_BOARDS(), endpoints: [light('a1', 5, 'Salon', true, DEV_A), light('b1', 5, 'Mutfak', true, DEV_B)] });
  const out = await env.svc.closeAll({ actor: ACTOR, homeId: HOME_A });
  assert.deepEqual(env.published.map((p) => p.payload.cmd), ['all_lights_off']);
  assert.equal(out.closed_lights, 2);
  assert.equal(env.queries.some((q) => q.text === SQL.layout), false);

  // layout sorgusu patlarsa hicbir komut gitmemis olmali
  env = makeEnv({
    devices: TWO_BOARDS(),
    endpoints: [light('a1', 5, 'Salon', true, DEV_A), plug('bp', 6, DEV_B)],
    failQuery: (text) => text === SQL.layout,
  });
  await rejects(env.svc.closeAll({ actor: ACTOR, homeId: HOME_A }));
  assert.equal(env.published.length, 0);
  assert.equal(env.audits.length, 0);
});

test('findSharedConflicts (saf): ISIK-OLMAYAN kanallar ve belirsiz panjur ciftleri', () => {
  const rows = [
    { device_id: 'A', type: 'light', channel_index: 5, shutter_pair_index: null, current_position: 0 },
    { device_id: 'B', type: 'plug', channel_index: 5, shutter_pair_index: null, current_position: 0 },
    { device_id: 'A', type: 'shutter', channel_index: 1, shutter_pair_index: null, current_position: 100 }, // NULL pair -> 1
    { device_id: 'B', type: 'shutter', channel_index: 2, shutter_pair_index: 1, current_position: 100 },
    { device_id: 'A', type: 'light', channel_index: 0, shutter_pair_index: null, current_position: 0 }, // gecersiz: yok sayilir
  ];
  let r = helpers.findSharedConflicts(rows);
  assert.deepEqual([...r.relays].sort((a, b) => a - b), [1, 2, 5]); // panjur rolesi de isik degildir
  assert.equal(r.pairs.has(1), false); // cift 1 iki panoda da acik
  assert.equal(r.pairs.has(3), true); // kanal 5/6 isik/priz: o cifte panjur komutu belirsiz

  r = helpers.findSharedConflicts([...rows, { device_id: 'C', type: 'shutter', channel_index: 1, shutter_pair_index: 1, current_position: null }]);
  assert.equal(r.pairs.has(1), true); // bilinmeyen konum = acik sayilmaz

  r = helpers.findSharedConflicts([...rows, { device_id: 'C', type: 'light', channel_index: 2, shutter_pair_index: null, current_position: 0 }]);
  assert.equal(r.pairs.has(1), true); // panjur olmayan role ayni cifte denk geliyor

  r = helpers.findSharedConflicts(undefined);
  assert.equal(r.relays.size + r.pairs.size, 0);
});

test('buildCloseCommands (saf): conflicts ile atlanan lamba/panjur kapatilmis SAYILMAZ', () => {
  let n = 0;
  const r = helpers.buildCloseCommands({
    lights: [{ channel: 5 }, { channel: 6 }],
    shutters: [{ pair: 1 }, { pair: 2 }],
    includeShutters: true,
    hasPlug: true,
    newCommandId: () => `i${++n}`,
    conflicts: { relays: new Set([5]), pairs: new Set([2]) },
  });
  assert.deepEqual(r.commands.map((c) => c.relay ?? c.shutter), [6, 1]);
  assert.deepEqual([r.closedLights, r.closedShutters, r.skippedLights, r.skippedShutters], [1, 1, 1, 1]);
});

// ==============================================================================
// F4: gercek SQL metinleri - yer tutucu / parametre / tip sozlesmesi
// (Gercek PostgreSQL'e karsi calistirma: peace_integration PG testi, bkz. integrationRequests)
// ==============================================================================

test('SQL sozlesmesi: yer tutucular 1..N bitisik, calisma zamani parametre sayisiyla ayni, cok kullanilanlar tipli', async () => {
  const placeholders = (text) => [...new Set([...text.matchAll(/\$(\d+)/g)].map((m) => Number(m[1])))].sort((a, b) => a - b);
  const expected = { home: 1, topic: 1, hasPlug: 1, layout: 1, lastNotice: 1, resolveNotice: 4, insertManual: 6 };

  // Hepsini tetikleyen senaryo: cok pano + plug + panjur, cozulecek bildirim yok (elle satir) + ayar okuma
  const env = makeEnv({
    devices: TWO_BOARDS(),
    endpoints: [light('a1', 5, 'Salon', true, DEV_A), plug('p', 6, DEV_A), shutter('s1', 1, 1, 100, 'Salon', DEV_A), shutter('b1', 1, 1, 100, 'Salon', DEV_B)],
    logs: [],
  });
  await env.svc.getSettings({ homeId: HOME_A });
  await env.svc.closeAll({ actor: ACTOR, homeId: HOME_A });

  for (const [name, count] of Object.entries(expected)) {
    assert.deepEqual(placeholders(SQL[name]), Array.from({ length: count }, (_, i) => i + 1), `${name} yer tutucular`);
    const calls = env.queries.filter((q) => q.text === SQL[name]);
    assert.ok(calls.length > 0, `${name} calistirilmadi`);
    for (const c of calls) assert.equal(c.params.length, count, `${name} parametre sayisi`);
  }

  // $N NULL gelebilir / birden cok yerde kullanilir -> PostgreSQL tip cikarimi hatasi (42P08) olmasin diye HER kullanim tipli
  assert.doesNotMatch(SQL.resolveNotice, /\$\d+(?!\d)(?!::)/, 'resolveNotice: tipsiz yer tutucu');
  assert.match(SQL.insertManual, /\$5::uuid/);
  assert.match(SQL.insertManual, /\$6::varchar/);
  assert.match(SQL.resolveNotice, /COALESCE\(\$3::int, \(SELECT id FROM/);
});

// ------------------------------------------------------------------------------
// Faz 2 / WP-G1 (F2.A.4): gaz alarmi acik evde "Hepsini kapat" -> 409 HAZARD_ACTIVE
// ------------------------------------------------------------------------------
test('F2.A.4 closeAll: evde acik gaz alarmi -> 409 HAZARD_ACTIVE, HICBIR komut yayinlanmaz, kayit yazilmaz', async () => {
  const env = makeEnv({ homes: [{ id: HOME_A, name: 'Gül Apartmanı 5', mqtt_username: TOPIC, gas_alarm: true }], endpoints: standardEndpoints() });
  const err = await rejects(env.svc.closeAll({ actor: ACTOR, homeId: HOME_A }));
  assert.equal(err.status, 409);
  assert.equal(err.code, 'HAZARD_ACTIVE');
  assert.match(err.message, /[Gg]az alarmı/);
  assert.equal(env.published.length, 0);
  assert.equal(env.audits.length, 0);
});

test('F2.A.4 closeAll: gaz alarmi yokken davranis aynen (komutlar gider)', async () => {
  const env = makeEnv({ homes: [{ id: HOME_A, name: 'Gül Apartmanı 5', mqtt_username: TOPIC, gas_alarm: false }], endpoints: standardEndpoints() });
  const out = await env.svc.closeAll({ actor: ACTOR, homeId: HOME_A });
  assert.ok(env.published.length > 0);
  assert.equal(out.delivered, true);
});
