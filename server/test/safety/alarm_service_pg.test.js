'use strict';

// WP-S2/S3 - GERCEK PostgreSQL: alarm_service (tasarim §5.2.2-§5.2.4, test plani §5.5 "Sunucu").
//   - Yinelenen eid yine ack uretir ama tek satir acar.
//   - Olay kaybolunca state uzlastirmasi satiri acar (origin=state) ve push bir kez istenir.
//   - Kanitli kapanma: ayni bolge normal + mode normal + rev geri gitmemis -> cleared (device_state).
//   - Kanitsiz kayip: caps yok / safety yok / mode safe / rev geri gitti -> lost + owner'a bilgi push'u.
//   - Sirasiz teslim: once alarm_cleared, sonra alarm_raised -> mezar tasi, push YOK.
//   - valve_fault -> fault + ikinci push; alarm_silenced -> silenced.
//   - Cevrimdisi onay istegi: pano donunce yalniz ayni aid ile gonderilir; farkli aid'de dusurulur.
//   - Yerlesim esitlemenin syncActuators SQL'i gercek PG'de calisir.
//
// Varsayilan olarak ATLANIR. Etkinlestirmek: EV_PG_TEST_URL=postgresql://... (001..033 migration'lanmis).
// Her test kendi (rastgele etiketli) evini olusturur ve sonda siler. Uretim veritabanina KARSI CALISTIRMAYIN.

const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');

const URL_ = process.env.EV_PG_TEST_URL;
const SKIP = URL_ ? false : 'EV_PG_TEST_URL tanimli degil (gercek PostgreSQL gerekir)';

let poolPromise = null;
const createdHomes = [];
const createdUsers = [];

function getDb() {
  if (!poolPromise) {
    poolPromise = (async () => {
      const { Pool } = require('pg');
      const pool = new Pool({ connectionString: URL_, max: 6, connectionTimeoutMillis: 15000 });
      pool.on('error', () => {});
      return {
        pool,
        query: (t, p) => pool.query(t, p),
        async withTransaction(fn) {
          const client = await pool.connect();
          try {
            await client.query('BEGIN');
            const r = await fn({ query: (t, p) => client.query(t, p) });
            await client.query('COMMIT');
            return r;
          } catch (err) {
            await client.query('ROLLBACK').catch(() => {});
            throw err;
          } finally {
            client.release();
          }
        },
      };
    })();
  }
  return poolPromise;
}

test.after(async () => {
  if (!poolPromise) return;
  const db = await poolPromise;
  for (const id of createdHomes) await db.query('DELETE FROM homes WHERE id = $1', [id]).catch(() => {});
  for (const id of createdUsers) await db.query('DELETE FROM users WHERE id = $1', [id]).catch(() => {});
  await db.pool.end().catch(() => {});
});

async function world() {
  const db = await getDb();
  const tag = crypto.randomBytes(4).toString('hex');
  const topic = `h_${tag}${tag}`;
  const uid = `AHBU-S3-${tag.slice(0, 6).toUpperCase()}`;
  const home = (await db.query('INSERT INTO homes (name, mqtt_username) VALUES ($1, $2) RETURNING id', [`S2 ${tag}`, topic])).rows[0];
  createdHomes.push(home.id);
  const dev = (await db.query(
    'INSERT INTO devices (home_id, device_uuid, mac_address, is_online) VALUES ($1, $2, $3, TRUE) RETURNING id',
    [home.id, uid, `02:01:${tag.slice(0, 2)}:${tag.slice(2, 4)}:${tag.slice(4, 6)}:${tag.slice(6, 8)}`]
  )).rows[0];
  const owner = (await db.query("INSERT INTO users (email, full_name, password_hash) VALUES ($1, 'Sahip', 'x') RETURNING id", [`s2-${tag}@test.invalid`])).rows[0];
  createdUsers.push(owner.id);

  const published = [];
  const sys = [];
  const pushes = [];
  const push = {
    isConfigured: () => true,
    recipientsForHome: async (homeId, opts) => [{ id: null, token: `tok-${homeId}`, opts }],
    sendNotice: async (args) => {
      pushes.push(args);
      return { sent: 1, failed: 0, errors: [] };
    },
  };
  const timers = { setTimeout: (fn) => ({ fn, unref() {} }), clearTimeout() {} };
  const { createAlarmService } = require('../../src/services/alarm_service');
  const svc = createAlarmService({
    db,
    publishCommand: async (topicId, cmd) => published.push({ topicId, cmd }),
    publishSys: async (topicId, obj) => sys.push({ topicId, obj }),
    isConnected: () => true,
    getPush: () => push,
    logger: { log() {}, warn() {}, error() {} },
    timers,
    ackWindowMs: 0, // aninda gonder (test)
  });
  const base = { topicId: topic, homeId: home.id, deviceId: dev.id, uid };
  const event = (type, over = {}) => svc.handleEvent({
    ...base,
    event: { cfgDump: false, unknown: false, uid, type, zone: 1, kind: 'water', srcs: ['d3'], actions: [], at: null, at_up: 10, ...over },
  });
  const alarms = async () => (await db.query('SELECT * FROM alarms WHERE device_id = $1 ORDER BY id', [dev.id])).rows;
  const summary = (zones, over = {}) => ({
    v: 1, state_v: 3, present: true, policy: 'on', mode: 'normal', boot: 57, bn: '9f3a11c0', time_ok: false,
    cfg: { rev: 12, crc: '9a3c11f0' }, last_rej: null, zones, actuators: [], sensors: [], ...over,
  });
  const live = (sum, { caps = ['safety', 'actuator', 'event', 'cfg'], prev = null, hadCaps = true } = {}) =>
    svc.onLiveState({ ...base, caps, summary: sum, prev, hadCaps });
  return { db, svc, home, dev, owner, uid, topic, published, sys, pushes, event, alarms, summary, live };
}

test('alarm_raised: satir acilir + push bir kez; yinelenen eid yine ack uretir ama ikinci satir/push YOK', { skip: SKIP }, async () => {
  const w = await world();
  const r1 = await w.event('alarm_raised', { eid: '9f3a11c0-3', aid: '9f3a11c0-3' });
  assert.equal(r1.status, 'applied');
  await w.svc.idle();
  const r2 = await w.event('alarm_raised', { eid: '9f3a11c0-3', aid: '9f3a11c0-3' });
  assert.equal(r2.status, 'duplicate');
  await w.svc.idle();
  const rows = await w.alarms();
  assert.equal(rows.length, 1);
  assert.equal(rows[0].status, 'latched');
  assert.equal(rows[0].origin, 'event');
  assert.equal(rows[0].push_status, 'sent');
  assert.deepEqual(rows[0].sources, ['d3']);
  assert.equal(w.pushes.length, 1);
  assert.equal(w.pushes[0].kind, 'safety_alarm');
  const acks = w.published.filter((p) => p.cmd.cmd === 'event_ack');
  assert.equal(acks.length, 2, 'yinelenen olay da onaylanir');
  assert.deepEqual(acks.map((a) => a.cmd.eids), [['9f3a11c0-3'], ['9f3a11c0-3']]);
  assert.ok(acks.every((a) => a.cmd.uid === w.uid && a.topicId === w.topic));
  const ev = await w.db.query('SELECT COUNT(*)::int AS n FROM device_events WHERE device_id = $1', [w.dev.id]);
  assert.equal(ev.rows[0].n, 1);
  const audit = await w.db.query("SELECT event FROM device_audit_logs WHERE home_id = $1 AND event = 'safety_alarm_raised'", [w.home.id]);
  assert.equal(audit.rows.length, 1);
});

test('valve_fault -> fault + ikinci push; valve_fault_cleared -> latched; alarm_silenced -> silenced; alarm_cleared -> cleared', { skip: SKIP }, async () => {
  const w = await world();
  await w.event('alarm_raised', { eid: 'aaaa0001-1' });
  await w.event('valve_fault', { eid: 'aaaa0001-2', aid: 'aaaa0001-1' });
  await w.svc.idle();
  let [row] = await w.alarms();
  assert.equal(row.status, 'fault');
  assert.equal(row.fault_push_status, 'sent');
  assert.equal(w.pushes.length, 2);
  await w.event('valve_fault_cleared', { eid: 'aaaa0001-3', aid: 'aaaa0001-1' });
  [row] = await w.alarms();
  assert.equal(row.status, 'latched');
  // aid tasimayan susturma olayi: bolgenin acik alarmi kullanilir
  await w.event('alarm_silenced', { eid: 'aaaa0001-4' });
  [row] = await w.alarms();
  assert.equal(row.status, 'silenced');
  assert.ok(row.acked_at);
  await w.event('alarm_cleared', { eid: 'aaaa0001-5', aid: 'aaaa0001-1' });
  [row] = await w.alarms();
  assert.equal(row.status, 'cleared');
  assert.equal(row.cleared_by, 'device_event');
  await w.svc.idle();
  assert.equal(w.pushes.length, 2, 'fault push tekrarlanmaz');
});

test('sirasiz teslim: once alarm_cleared (bilinmeyen aid) -> mezar tasi; sonra alarm_raised -> yeni satir/push YOK', { skip: SKIP }, async () => {
  const w = await world();
  await w.event('alarm_cleared', { eid: 'bbbb0001-5', aid: 'bbbb0001-1' });
  await w.event('alarm_raised', { eid: 'bbbb0001-1' });
  await w.svc.idle();
  const rows = await w.alarms();
  assert.equal(rows.length, 1);
  assert.equal(rows[0].origin, 'tomb');
  assert.equal(rows[0].status, 'cleared');
  assert.equal(rows[0].push_status, 'skipped');
  assert.equal(w.pushes.length, 0);
});

test('bilinmeyen tur: device_events + ack, alarms satiri YOK', { skip: SKIP }, async () => {
  const w = await world();
  const r = await w.svc.handleEvent({ topicId: w.topic, homeId: w.home.id, deviceId: w.dev.id, uid: w.uid,
    event: { cfgDump: false, unknown: true, uid: w.uid, eid: 'cccc0001-1', type: 'future_thing', zone: null, kind: null, srcs: [], actions: [] } });
  assert.equal(r.status, 'unknown');
  assert.equal((await w.alarms()).length, 0);
  assert.equal(w.published.filter((p) => p.cmd.cmd === 'event_ack').length, 1);
});

test('state uzlastirmasi: olay kayboldu -> origin=state satiri + push; ayni state tekrar -> yeni satir yok', { skip: SKIP }, async () => {
  const w = await world();
  const s = w.summary([{ id: 1, st: 'latched', kind: 'water', aid: 'dddd0001-3', silenced: false, since: null, since_up: 5, srcs: ['d3'] }]);
  await w.live(s);
  await w.live(s, { prev: s });
  await w.svc.idle();
  const rows = await w.alarms();
  assert.equal(rows.length, 1);
  assert.equal(rows[0].origin, 'state');
  assert.equal(rows[0].aid, 'dddd0001-3');
  assert.equal(rows[0].status, 'latched');
  assert.equal(w.pushes.length, 1);
  // state'te susturuldu ve sonra fault: durum esitlenir
  await w.live(w.summary([{ id: 1, st: 'latched', kind: 'water', aid: 'dddd0001-3', silenced: true, srcs: [] }]), { prev: s });
  assert.equal((await w.alarms())[0].status, 'silenced');
  await w.live(w.summary([{ id: 1, st: 'fault', kind: 'water', aid: 'dddd0001-3', silenced: true, srcs: [] }]), { prev: s });
  assert.equal((await w.alarms())[0].status, 'fault');
});

test('kanitli kapanma: ayni bolge normal + mode normal + rev geri gitmedi -> cleared (device_state); push yok', { skip: SKIP }, async () => {
  const w = await world();
  await w.event('alarm_raised', { eid: 'eeee0001-1' });
  const prev = w.summary([{ id: 1, st: 'latched', aid: 'eeee0001-1', srcs: [] }]);
  await w.live(w.summary([], { cfg: { rev: 12, crc: '9a3c11f0' } }), { prev });   // firmware bicimi: normal bolge listede YOK [RV-1]
  await w.svc.idle();
  const [row] = await w.alarms();
  assert.equal(row.status, 'cleared');
  assert.equal(row.cleared_by, 'device_state');
  assert.equal(w.pushes.filter((p) => p.kind === 'safety_info').length, 0);
});

test('kanitsiz kayip: mode=safe / rev geri gitti / safety yok / caps yok -> lost + owner bilgi push\'u', { skip: SKIP }, async () => {
  const cases = [
    ['mode safe', (w) => w.live(w.summary([], { mode: 'safe' }))],
    ['rev geri', (w) => w.live(w.summary([], { cfg: { rev: 3, crc: '00000000' } }), { prev: w.summary([], { cfg: { rev: 12, crc: '9a3c11f0' } }) })],
    ['safety yok', (w) => w.live(w.summary([], { present: false, mode: null }))],
    ['caps yok', (w) => w.live(null, { caps: null, hadCaps: true })],
    ['caps safety icermiyor', (w) => w.live(w.summary([]), { caps: ['event'] })],
  ];
  for (const [name, run] of cases) {
    const w = await world();
    await w.event('alarm_raised', { eid: 'ffff0001-1' });
    await w.svc.idle();
    await run(w);
    await w.svc.idle();
    const [row] = await w.alarms();
    assert.equal(row.status, 'lost', name);
    assert.equal(row.cleared_by, 'lost', name);
    const info = w.pushes.filter((p) => p.kind === 'safety_info');
    assert.equal(info.length, 1, name);
    assert.equal(info[0].data.reason, 'alarm_lost', name);
    // ikinci state yeni push uretmez
    await run(w);
    await w.svc.idle();
    assert.equal(w.pushes.filter((p) => p.kind === 'safety_info').length, 1, `${name}: tek bilgi push'u`);
  }
});

test('bolgede yeni aid (onceki kilit kalkmis, yeni alarm): eski satir cleared, yeni satir state ile acilir', { skip: SKIP }, async () => {
  const w = await world();
  await w.event('alarm_raised', { eid: 'abab0001-1' });
  await w.live(w.summary([{ id: 1, st: 'latched', aid: 'abab0001-7', srcs: [] }]));
  await w.svc.idle();
  const rows = await w.alarms();
  assert.deepEqual(rows.map((r) => [r.aid, r.status, r.origin]), [['abab0001-1', 'cleared', 'event'], ['abab0001-7', 'latched', 'state']]);
});

test('cevrimdisi onay istegi: pano donunce yalniz ayni aid ile alarm_ack gonderilir; farkli aid\'de dusurulur', { skip: SKIP }, async () => {
  const w = await world();
  await w.event('alarm_raised', { eid: 'acac0001-1', zone: 2 });
  const [row] = await w.alarms();
  await w.db.query('UPDATE alarms SET ack_requested_at = now(), ack_requested_by = $2 WHERE id = $1', [row.id, w.owner.id]);
  await w.live(w.summary([{ id: 2, st: 'latched', aid: 'acac0001-1', srcs: [] }]));
  const ack = w.published.filter((p) => p.cmd.cmd === 'alarm_ack');
  assert.equal(ack.length, 1);
  assert.equal(ack[0].cmd.zone, 2);
  assert.equal(ack[0].cmd.aid, 'acac0001-1');
  assert.equal(ack[0].cmd.uid, w.uid);
  assert.match(ack[0].cmd.id, /^[A-Za-z0-9_-]{1,24}$/);
  const after = (await w.alarms())[0];
  assert.equal(after.ack_requested_at, null);
  assert.equal(after.acked_by, w.owner.id);
  // ikinci state yeniden gondermez
  await w.live(w.summary([{ id: 2, st: 'latched', aid: 'acac0001-1', srcs: [] }]));
  assert.equal(w.published.filter((p) => p.cmd.cmd === 'alarm_ack').length, 1);

  const w2 = await world();
  await w2.event('alarm_raised', { eid: 'adad0001-1' });
  const [r2] = await w2.alarms();
  await w2.db.query('UPDATE alarms SET ack_requested_at = now(), ack_requested_by = $2 WHERE id = $1', [r2.id, w2.owner.id]);
  await w2.live(w2.summary([{ id: 1, st: 'latched', aid: 'adad0001-9', srcs: [] }]));
  assert.equal(w2.published.filter((p) => p.cmd.cmd === 'alarm_ack').length, 0, 'kullanicinin gormedigi yeni alarm onaylanmaz [Y-9]');
  const old = (await w2.alarms()).find((r) => r.aid === 'adad0001-1');
  assert.equal(old.ack_requested_at, null, 'istek dusuruldu');
});

test('listAlarms: open | all, before ile sayfalama, ev disi satir gelmez', { skip: SKIP }, async () => {
  const w = await world();
  await w.event('alarm_raised', { eid: 'a1a10001-1', zone: 1 });
  await w.event('alarm_raised', { eid: 'a1a10001-2', zone: 2 });
  await w.event('alarm_cleared', { eid: 'a1a10001-3', zone: 2, aid: 'a1a10001-2' });
  const open = await w.svc.listAlarms({ homeId: w.home.id, state: 'open' });
  assert.deepEqual(open.items.map((a) => a.aid), ['a1a10001-1']);
  assert.equal(open.items[0].device_uuid, w.uid);
  const all = await w.svc.listAlarms({ homeId: w.home.id, state: 'all' });
  assert.equal(all.items.length, 2);
  const page = await w.svc.listAlarms({ homeId: w.home.id, state: 'all', limit: 1 });
  assert.equal(page.items.length, 1);
  assert.ok(page.next_before);
  const other = await world();
  assert.equal((await other.svc.listAlarms({ homeId: other.home.id, state: 'all' })).items.length, 0);
});

test('cfg_dump: tek ve cok parcali dokum device_configs\'e yazilir; eski rev yenisini ezmez', { skip: SKIP }, async () => {
  const w = await world();
  const dump = (rev, part, parts, body) => w.svc.handleCfgDump({ deviceId: w.dev.id, dump: { cfgDump: true, uid: w.uid, module: 'safety', rev, crc: '0000000a', part, parts, body } });
  assert.equal((await dump(5, 1, 1, { sensors: [], actuators: [] })).status, 'stored');
  const head = { policy: { on: true, dry_hold_ms: 10000 }, zones: [{ id: 1, name: 'Ev' }], lights: [], sensors: [{ id: 'd3', name: 'Evye' }], actuators: [] };
  assert.equal((await dump(6, 2, 2, { sensors: [], actuators: [{ id: 'a1', name: 'Vana' }] })).status, 'partial');
  assert.equal((await dump(6, 1, 2, head)).status, 'stored');
  let row = (await w.db.query("SELECT rev, crc, body FROM device_configs WHERE device_id = $1 AND module = 'safety'", [w.dev.id])).rows[0];
  assert.equal(Number(row.rev), 6);
  assert.deepEqual(row.body, { policy: head.policy, zones: head.zones, lights: [], sensors: [{ id: 'd3', name: 'Evye' }], actuators: [{ id: 'a1', name: 'Vana' }] });
  const cfg = await w.svc.getConfig({ deviceId: w.dev.id });
  assert.equal(cfg.rev, 6);
  assert.equal(cfg.actuators[0].name, 'Vana');
  assert.equal(await w.svc.getConfig({ deviceId: w.dev.id, module: 'climate' }), null);
  assert.equal((await dump(4, 1, 1, { sensors: [], actuators: [] })).status, 'stale');
  row = (await w.db.query("SELECT rev FROM device_configs WHERE device_id = $1 AND module = 'safety'", [w.dev.id])).rows[0];
  assert.equal(Number(row.rev), 6);
});

test('yerlesim esitleme syncActuators SQL\'i gercek PG\'de: degisen satirlar doner, ayni deger tekrar yazilmaz', { skip: SKIP }, async () => {
  const w = await world();
  await w.db.query(
    "INSERT INTO endpoints (home_id, device_id, channel_index, name, type) VALUES ($1, $2, 5, 'Vana', 'light'), ($1, $2, 6, 'Lamba', 'light')",
    [w.home.id, w.dev.id]
  );
  const { SQL } = require('../../src/services/endpoint_layout_sync');
  const r1 = await w.db.query(SQL.syncActuators, [w.dev.id, [5, 6], ['valve', null]]);
  assert.deepEqual(r1.rows.map((r) => [r.channel_index, r.actuator_type]), [[5, 'valve']]);
  const r2 = await w.db.query(SQL.syncActuators, [w.dev.id, [5, 6], ['valve', null]]);
  assert.equal(r2.rowCount, 0);
  const { SQL: SCHED } = require('../../src/scheduler');
  const t = await w.db.query(SCHED.target, [w.dev.id, [5]]);
  assert.equal(t.rows[0].actuator_type, 'valve');
  const snapshot = require('../../src/services/peace_snapshot');
  await w.db.query('UPDATE endpoints SET current_state = TRUE WHERE device_id = $1', [w.dev.id]);
  await w.db.query('UPDATE devices SET is_online = TRUE, last_seen_at = now() WHERE id = $1', [w.dev.id]);
  const snap = await snapshot.loadLiveSnapshot(w.db, w.home.id);
  assert.deepEqual(snap.lights.map((l) => l.channel), [6], 'vana lamba sayilmaz');
});

// ---- Inceleme turu (entegrasyon) ----

test('RV-1: alarm_cleared kaybolsa da firmware bicimindeki state (bolge listede yok) satiri kapatir; bekleyen onay istegi dusurulur', { skip: SKIP }, async () => {
  const w = await world();
  await w.event('alarm_raised', { eid: 'abab0001-1' });
  await w.svc.idle();
  await w.db.query('UPDATE alarms SET ack_requested_at = CURRENT_TIMESTAMP WHERE device_id = $1', [w.dev.id]);
  const prev = w.summary([{ id: 1, st: 'latched', aid: 'abab0001-1', srcs: [] }]);
  await w.live(w.summary([]), { prev });
  await w.svc.idle();
  const [row] = await w.alarms();
  assert.equal(row.status, 'cleared');
  assert.equal(row.cleared_by, 'device_state');
  const r = await w.db.query('SELECT ack_requested_at FROM alarms WHERE device_id = $1', [w.dev.id]);
  assert.equal(r.rows[0].ack_requested_at, null);
});

test('E2E-2: kilitli bolgede yeni tur yeni aid ile gelir: yeni satir + push; eski satir superseded kapanir', { skip: SKIP }, async () => {
  const w = await world();
  await w.event('alarm_raised', { eid: 'acac0001-1', kind: 'water' });
  await w.svc.idle();
  await w.event('alarm_raised', { eid: 'acac0001-4', kind: 'gas' });
  await w.svc.idle();
  await w.live(w.summary([{ id: 1, st: 'latched', kind: 'gas', aid: 'acac0001-4', silenced: false, srcs: ['d3', 'd4'] }]));
  await w.svc.idle();
  const rows = (await w.alarms()).sort((a, b) => Number(a.id) - Number(b.id));
  assert.equal(rows.length, 2);
  assert.equal(rows[0].status, 'cleared');
  assert.equal(rows[0].cleared_by, 'superseded');
  assert.equal(rows[1].aid, 'acac0001-4');
  assert.equal(rows[1].status, 'latched');
  assert.equal(rows[1].kind, 'gas');
  assert.equal(w.pushes.filter((p) => p.kind !== 'safety_info').length, 2, 'tirmanma ayri alarm push u uretir');
});

// Faz 2 incelemesi RG-1: pano rev'i geriledi (fabrika sifirlamasi NVS_NS_SAFETY'yi siler; device_configs satiri korunur). Panonun
// SON BILDIRDIGI (devices.safety_state.cfg) rev+crc ile ayni dokum, kopyadan kucuk rev'li olsa da yazilir; aksi halde kopya kalici bayat
// kalir (bulut okumasi suresiz CONFIG_NOT_AVAILABLE). Panonun bildirmedigi eski dokum yine yazilmaz.
test('RG-1: pano rev\'i geriledi -> state ile ayni (rev, crc) dokum kopyayi gunceller; bayat dokum yine reddedilir', { skip: SKIP }, async () => {
  const w = await world();
  const dump = (rev, crc) => w.svc.handleCfgDump({ deviceId: w.dev.id, dump: { cfgDump: true, uid: w.uid, module: 'safety', rev, crc, part: 1, parts: 1, body: { sensors: [], actuators: [] } } });
  assert.equal((await dump(7, '00000007')).status, 'stored');
  await w.db.query('UPDATE devices SET safety_state = $2::jsonb WHERE id = $1', [w.dev.id, JSON.stringify({ present: true, mode: 'normal', cfg: { rev: 1, crc: '0000abcd' } })]);
  assert.equal((await dump(3, '00000003')).status, 'stale', 'panonun bildirmedigi eski rev');
  assert.equal((await dump(1, '0000ffff')).status, 'stale', 'ayni rev ama farkli crc');
  assert.equal((await dump(1, '0000abcd')).status, 'stored', 'panonun bildirdigi rev + crc');
  const row = (await w.db.query("SELECT rev, crc FROM device_configs WHERE device_id = $1 AND module = 'safety'", [w.dev.id])).rows[0];
  assert.equal(Number(row.rev), 1);
  assert.equal(String(row.crc).toLowerCase(), '0000abcd');
  assert.equal((await dump(2, '00000002')).status, 'stored', 'ileri rev her zaman yazilir');
});
