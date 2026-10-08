'use strict';

// Faz 2 - GERCEK PostgreSQL (WP-G1, WP-N1, WP-I4, WP-C2):
//   - Gaz alarmi EXISTS: zamanlayici cihaz sorgusu ve gece huzur anlik goruntusu (alarms_home_open_idx).
//   - Hirsiz alarmi: alarms kind='intrusion' satiri, push talebinin device_uuid alt sorgusu, bolge uzlastirmasinin hirsiz
//     satirina dokunmamasi, arm uzlastirmasi, bolge olayinin hirsiz satirini bulmamasi.
//   - Buluttan yapilandirma yazimi: satir kilidi + ucus isareti ile ayni anda iki yamadan biri 409 CONFIG_PENDING; cevrimdisi
//     kuyruk zinciri (3 oge, her biri bir canli state sonrasi), pano kazanir, suresi dolan, erisimi kalmayan isteyen,
//     DELETE ... /pending; denetim kaydinda deger/ad yok.
// Varsayilan olarak ATLANIR. Etkinlestirmek: EV_PG_TEST_URL=postgresql://... (001..034 migration'lanmis).

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
      const pool = new Pool({ connectionString: URL_, max: 8, connectionTimeoutMillis: 15000 });
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

async function world({ online = true, stateRev = 7 } = {}) {
  const db = await getDb();
  const tag = crypto.randomBytes(4).toString('hex');
  const topic = `h_${tag}${tag}`;
  const uid = `AHBU-S3-${tag.slice(0, 6).toUpperCase()}`;
  const home = (await db.query('INSERT INTO homes (name, mqtt_username) VALUES ($1, $2) RETURNING id', [`F2 ${tag}`, topic])).rows[0];
  createdHomes.push(home.id);
  const safetyState = { v: 1, present: true, mode: 'normal', policy: 'on', cfg: { rev: stateRev, crc: '0000000a' }, zones: [], zones_complete: true, sensors: [], actuators: [] };
  const dev = (await db.query(
    'INSERT INTO devices (home_id, device_uuid, mac_address, is_online, last_seen_at, caps, safety_state) ' +
    "VALUES ($1, $2, $3, $4, CURRENT_TIMESTAMP, '[\"safety\",\"actuator\",\"event\",\"cfg\",\"intrusion\"]'::jsonb, $5::jsonb) RETURNING id",
    [home.id, uid, `02:02:${tag.slice(0, 2)}:${tag.slice(2, 4)}:${tag.slice(4, 6)}:${tag.slice(6, 8)}`, online, JSON.stringify(safetyState)]
  )).rows[0];
  const mkUser = async (role) => {
    const u = (await db.query("INSERT INTO users (email, full_name, password_hash) VALUES ($1, 'K', 'x') RETURNING id", [`f2-${role}-${tag}@test.invalid`])).rows[0];
    createdUsers.push(u.id);
    await db.query('INSERT INTO home_users (home_id, user_id, role) VALUES ($1, $2, $3)', [home.id, u.id, role]);
    return u.id;
  };
  const owner = await mkUser('owner');
  const staff = await mkUser('service_user');
  return { db, tag, topic, uid, homeId: home.id, deviceId: dev.id, owner, staff };
}

async function seedConfig(w, rev = 7) {
  const body = {
    policy: { on: true, dry_hold_ms: 10000 },
    zones: [{ id: 1, name: 'Ev' }],
    lights: [],
    sensors: [{ id: 'd3', kind: 'water', zone: 1, active_open: 0, flags: 1, confirm_ms: 1000, name: 'Evye' }],
    actuators: [],
  };
  await w.db.query("INSERT INTO device_configs (device_id, module, rev, crc, body) VALUES ($1, 'safety', $2, '0000000a', $3::jsonb)", [w.deviceId, rev, JSON.stringify(body)]);
}

// ------------------------------------------------------------------------------
// WP-G1: gaz alarmi EXISTS
// ------------------------------------------------------------------------------
test('PG gaz alarmi: zamanlayici cihaz sorgusu ve gece anlik goruntusu acik gaz alarmini gorur; kapaninca gormez', { skip: SKIP }, async () => {
  const w = await world();
  const { SQL } = require('../../src/scheduler');
  const { loadLiveSnapshot } = require('../../src/services/peace_snapshot');
  const gas = async () => (await w.db.query(SQL.devices, [w.homeId, null])).rows[0].gas_alarm;
  assert.equal(await gas(), false);
  assert.equal((await loadLiveSnapshot(w.db, w.homeId)).gasAlarm, false);
  const a = (await w.db.query(
    "INSERT INTO alarms (home_id, device_id, aid, zone, kind, status, raised_at) VALUES ($1, $2, '9f3a11c0-1', 2, 'gas', 'latched', CURRENT_TIMESTAMP) RETURNING id",
    [w.homeId, w.deviceId]
  )).rows[0];
  await w.db.query("INSERT INTO alarms (home_id, device_id, aid, zone, kind, status, raised_at) VALUES ($1, $2, '9f3a11c0-2', 1, 'water', 'latched', CURRENT_TIMESTAMP)", [w.homeId, w.deviceId]);
  assert.equal(await gas(), true);
  assert.equal((await loadLiveSnapshot(w.db, w.homeId)).gasAlarm, true);
  await w.db.query("UPDATE alarms SET status = 'silenced' WHERE id = $1", [a.id]);
  assert.equal(await gas(), true, 'susturulmus gaz alarmi da acik sayilir');
  await w.db.query("UPDATE alarms SET status = 'cleared', cleared_at = CURRENT_TIMESTAMP, cleared_by = 'device_event' WHERE id = $1", [a.id]);
  assert.equal(await gas(), false, 'su alarmi tek basina anahtarlamayi durdurmaz');
  assert.equal((await loadLiveSnapshot(w.db, w.homeId)).gasAlarm, false);
});

// ------------------------------------------------------------------------------
// WP-I4 + WP-N1: hirsiz alarmi
// ------------------------------------------------------------------------------
function alarmSvc(w, pushes) {
  const { createAlarmService } = require('../../src/services/alarm_service');
  const push = {
    isConfigured: () => true,
    recipientsForHome: async () => [{ id: null, token: 'tok-x' }],
    sendNotice: async (a) => {
      pushes.push(a);
      return { sent: 1 };
    },
  };
  return createAlarmService({
    db: w.db, publishCommand: async () => {}, publishSys: async () => {}, getPush: () => push,
    logger: { log() {}, warn() {}, error() {} }, ackWindowMs: 0, sleep: async () => {},
  });
}

test('PG hirsiz alarmi: olay -> kind intrusion satiri + push (device_uuid); bolge uzlastirmasi dokunmaz; arm cozumu kapatir', { skip: SKIP }, async () => {
  const w = await world();
  const pushes = [];
  const svc = alarmSvc(w, pushes);
  const { validateEventPayload } = require('../../src/utils/safety_payload');
  const ev = validateEventPayload({ v: 1, uid: w.uid, eid: '9f3a11c0-21', bn: '9f3a11c0', boot: 1, n: 21, type: 'intrusion_alarm', zone: 2, kind: 'intrusion', srcs: ['d9'], at_up: 5 }).value;
  const r = await svc.handleEvent({ topicId: w.topic, homeId: w.homeId, deviceId: w.deviceId, uid: w.uid, event: ev });
  await svc.idle();
  assert.equal(r.opened, true);
  const row = (await w.db.query('SELECT kind, zone, status, origin, push_status FROM alarms WHERE device_id = $1', [w.deviceId])).rows[0];
  assert.deepEqual(row, { kind: 'intrusion', zone: 2, status: 'latched', origin: 'event', push_status: 'sent' });
  assert.equal(pushes[0].title, 'Hırsız alarmı');
  assert.equal(pushes[0].data.device_uuid, w.uid, 'talep RETURNING alt sorgusu gercek PG\'de calisir');

  // bolge olayi (aid'siz valve_fault) ayni bolgedeki hirsiz satirini BULMAZ
  const vf = validateEventPayload({ v: 1, uid: w.uid, eid: '9f3a11c0-22', bn: '9f3a11c0', boot: 1, n: 22, type: 'valve_fault', zone: 2, kind: 'water', at_up: 6 }).value;
  await svc.handleEvent({ topicId: w.topic, homeId: w.homeId, deviceId: w.deviceId, uid: w.uid, event: vf });
  assert.equal((await w.db.query('SELECT status FROM alarms WHERE device_id = $1', [w.deviceId])).rows[0].status, 'latched');

  const caps = ['safety', 'actuator', 'event', 'cfg', 'intrusion'];
  const base = { present: true, mode: 'normal', policy: 'on', cfg: { rev: 7, crc: '0000000a' }, zones: [], zones_complete: true, sensors: [] };
  await svc.onLiveState({ topicId: w.topic, homeId: w.homeId, deviceId: w.deviceId, uid: w.uid, caps, summary: { ...base, arm: { mode: 'away', st: 'alarm', ok: true, aid: '9f3a11c0-21', srcs: ['d9'] } }, hadCaps: true });
  assert.equal((await w.db.query('SELECT status FROM alarms WHERE device_id = $1', [w.deviceId])).rows[0].status, 'latched', 'zones[] bos ve tam: hirsiz satiri KAPANMAZ');
  await svc.onLiveState({ topicId: w.topic, homeId: w.homeId, deviceId: w.deviceId, uid: w.uid, caps, summary: { ...base, arm: { mode: 'off', st: 'idle', ok: true, aid: null, srcs: [] } }, hadCaps: true });
  await svc.idle();
  const fin = (await w.db.query('SELECT status, cleared_by FROM alarms WHERE device_id = $1', [w.deviceId])).rows[0];
  assert.deepEqual(fin, { status: 'cleared', cleared_by: 'device_state' });

  // mezar tasi: bilinmeyen aid'li intrusion_cleared (bolge 1 yer tutucu) listelenmez
  const cl = validateEventPayload({ v: 1, uid: w.uid, eid: '9f3a11c0-30', bn: '9f3a11c0', boot: 1, n: 30, type: 'intrusion_cleared', aid: '9f3a11c0-29', via: 'lan', at_up: 9 }).value;
  await svc.handleEvent({ topicId: w.topic, homeId: w.homeId, deviceId: w.deviceId, uid: w.uid, event: cl });
  const tomb = (await w.db.query("SELECT kind, zone, origin FROM alarms WHERE device_id = $1 AND aid = '9f3a11c0-29'", [w.deviceId])).rows[0];
  assert.deepEqual(tomb, { kind: 'intrusion', zone: 1, origin: 'tomb' });
});

// ------------------------------------------------------------------------------
// WP-C2: buluttan yapilandirma yazimi
// ------------------------------------------------------------------------------
function cfgSync(w, { outcome = () => ({ ok: true }), delayMs = 0, connected = true } = {}) {
  const { SafetyCfgSync } = require('../../src/services/safety_cfg_sync');
  const sys = [];
  const pushes = [];
  const sync = new SafetyCfgSync({
    db: w.db,
    publishSys: async (t, o) => {
      sys.push(o);
    },
    expectOutcome: async () => {
      if (delayMs) await new Promise((r) => setTimeout(r, delayMs));
      return outcome();
    },
    cancelAck: () => {},
    isConnected: () => connected,
    requestConfig: async () => true,
    pushInfo: async (a) => pushes.push(a),
    logger: { log() {}, warn() {}, error() {} },
  });
  return { sync, sys, pushes };
}

const device = (w, over = {}) => ({ id: w.deviceId, device_uuid: w.uid, is_online: true, topic_id: w.topic, caps: ['safety', 'actuator', 'event', 'cfg'], ...over });

test('PG yapilandirma: ayni panoya ayni anda iki yama -> biri uygulanir, digeri 409 CONFIG_PENDING (satir kilidi + ucus isareti)', { skip: SKIP }, async () => {
  const w = await world();
  await seedConfig(w);
  const { sync } = cfgSync(w, { delayMs: 300, outcome: () => ({ ok: true, cfg: { rev: 8, crc: '0000000b' } }) });
  const actor = { userId: w.owner, access: 'owner' };
  const body = (n) => ({ base_rev: 7, set: { zone: { id: 1, name: `Z${n}` } } });
  const res = await Promise.allSettled([
    sync.patch({ actor, homeId: w.homeId, device: device(w), body: body(1) }),
    sync.patch({ actor, homeId: w.homeId, device: device(w), body: body(2) }),
  ]);
  const ok = res.filter((r) => r.status === 'fulfilled');
  const bad = res.filter((r) => r.status === 'rejected');
  assert.equal(ok.length, 1);
  assert.equal(bad.length, 1);
  assert.equal(bad[0].reason.code, 'CONFIG_PENDING');
  assert.equal(ok[0].value.applied, true);
  const p = (await w.db.query("SELECT pending FROM device_configs WHERE device_id = $1 AND module = 'safety'", [w.deviceId])).rows[0];
  assert.equal(p.pending, null, 'ucus isareti temizlendi');
  const audits = (await w.db.query("SELECT actor_user_id, actor_role, details FROM device_audit_logs WHERE home_id = $1 AND event = 'safety_config_patch'", [w.homeId])).rows;
  assert.equal(audits.length, 1);
  assert.equal(audits[0].actor_user_id, w.owner);
  assert.equal(JSON.stringify(audits[0].details).includes('Z1') || JSON.stringify(audits[0].details).includes('Z2'), false, 'ad yok');
});

test('PG yapilandirma: cevrimdisi kuyruk zinciri (3 oge, her biri bir canli state sonrasi); denetim aktoru isteyen', { skip: SKIP }, async () => {
  const w = await world({ online: false });
  await seedConfig(w);
  let rev = 8;
  const { sync, sys } = cfgSync(w, { outcome: () => ({ ok: true, cfg: { rev: rev++, crc: '0000000b' } }) });
  const owner = { userId: w.owner, access: 'owner' };
  const staff = { userId: w.staff, access: 'service_user' };
  const dev = device(w, { is_online: false });
  assert.equal((await sync.patch({ actor: owner, homeId: w.homeId, device: dev, body: { base_rev: 7, set: { zone: { id: 1, name: 'Gizli1' } } } })).position, 1);
  assert.equal((await sync.patch({ actor: staff, homeId: w.homeId, device: dev, body: { base_rev: 8, set: { policy: { on: false } } } })).position, 2);
  assert.equal((await sync.patch({ actor: owner, homeId: w.homeId, device: dev, body: { base_rev: 9, del: { sensor: 'd3' } } })).position, 3);
  const view = await sync.view({ deviceId: w.deviceId, includePending: true });
  assert.deepEqual([view.state_rev, view.next_base_rev, view.pending.length], [7, 10, 3]);
  assert.deepEqual(view.pending.map((x) => x.loosening), [false, true, true]);

  await w.db.query('UPDATE devices SET is_online = TRUE WHERE id = $1', [w.deviceId]);
  const live = (r) => sync.onLiveState({ topicId: w.topic, homeId: w.homeId, deviceId: w.deviceId, uid: w.uid, caps: ['safety', 'cfg'], summary: { cfg: { rev: r, crc: 'x' } } });
  await live(7);
  await live(8);
  await live(9);
  assert.deepEqual(sys.map((o) => o.base_rev), [7, 8, 9]);
  const p = (await w.db.query("SELECT pending FROM device_configs WHERE device_id = $1 AND module = 'safety'", [w.deviceId])).rows[0];
  assert.equal(p.pending, null);
  const audits = (await w.db.query(
    "SELECT actor_user_id, actor_role, details FROM device_audit_logs WHERE home_id = $1 AND event = 'safety_config_patch' ORDER BY id",
    [w.homeId]
  )).rows;
  assert.deepEqual(audits.map((a) => [a.details.result, a.actor_role]), [
    ['queued', 'owner'], ['queued', 'service_user'], ['queued', 'owner'], ['applied', 'owner'], ['applied', 'service_user'], ['applied', 'owner'],
  ]);
  assert.equal(audits[4].actor_user_id, w.staff);
  assert.equal(JSON.stringify(audits).includes('Gizli1'), false);
});

test('PG yapilandirma: pano kazanir (kuyruk duser + bilgi push), suresi dolan, erisimi kalmayan isteyen, DELETE pending', { skip: SKIP }, async () => {
  const w = await world({ online: false });
  await seedConfig(w);
  const { sync, sys, pushes } = cfgSync(w);
  const dev = device(w, { is_online: false });
  await sync.patch({ actor: { userId: w.owner, access: 'owner' }, homeId: w.homeId, device: dev, body: { base_rev: 7, set: { zone: { id: 1, name: 'A' } } } });
  await w.db.query('UPDATE devices SET is_online = TRUE WHERE id = $1', [w.deviceId]);
  await sync.onLiveState({ topicId: w.topic, homeId: w.homeId, deviceId: w.deviceId, uid: w.uid, caps: ['cfg'], summary: { cfg: { rev: 9, crc: 'x' } } });
  assert.equal(sys.length, 0);
  assert.equal(pushes.length, 1);
  assert.equal(pushes[0].reason, 'cfg_pending_dropped');

  // suresi dolan + erisimi kalmayan
  const old = new Date(Date.now() - 25 * 3600 * 1000).toISOString();
  const now = new Date().toISOString();
  const pending = {
    v: 1,
    items: [
      { id: 'e1', base_rev: 9, patch: { set: { zone: { id: 1, name: 'B' } } }, by: w.owner, role: 'owner', at: old, loosening: false },
      { id: 'r1', base_rev: 9, patch: { set: { zone: { id: 1, name: 'C' } } }, by: w.staff, role: 'service_user', at: now, loosening: false },
    ],
  };
  await w.db.query("UPDATE device_configs SET pending = $2::jsonb WHERE device_id = $1 AND module = 'safety'", [w.deviceId, JSON.stringify(pending)]);
  await w.db.query('DELETE FROM home_users WHERE home_id = $1 AND user_id = $2', [w.homeId, w.staff]);
  const { markPending } = require('../../src/services/safety_cfg_sync');
  markPending(w.deviceId);
  await sync.onLiveState({ topicId: w.topic, homeId: w.homeId, deviceId: w.deviceId, uid: w.uid, caps: ['cfg'], summary: { cfg: { rev: 9, crc: 'x' } } });
  const drops = (await w.db.query(
    "SELECT details FROM device_audit_logs WHERE home_id = $1 AND event = 'safety_config_pending_dropped' ORDER BY id", [w.homeId]
  )).rows.map((r) => [r.details.reason, r.details.count]);
  assert.deepEqual(drops, [['conflict', 1], ['expired', 1], ['revoked', 1]]);
  assert.equal(sys.length, 0);

  // DELETE pending
  await w.db.query("UPDATE device_configs SET pending = $2::jsonb WHERE device_id = $1 AND module = 'safety'", [w.deviceId, JSON.stringify({ v: 1, items: [pending.items[1]] })]);
  assert.deepEqual(await sync.cancel({ actor: { userId: w.owner, access: 'owner' }, homeId: w.homeId, device: dev }), { dropped: 1 });
  const p = (await w.db.query("SELECT pending FROM device_configs WHERE device_id = $1 AND module = 'safety'", [w.deviceId])).rows[0];
  assert.equal(p.pending, null);
});

test('PG yapilandirma (guvenlik-5): iptal edilen servis oturumunun kuyruk ogesi duser; gecerli oturumunki gider; sid siz eski oge iptal sonrasi duser', { skip: SKIP }, async () => {
  const w = await world({ online: false });
  await seedConfig(w);
  const { sync, sys } = cfgSync(w, { outcome: () => ({ ok: true, cfg: { rev: 8, crc: '0000000b' } }) });
  const mkSession = async ({ revoked = false, expiresInS = 3600 } = {}) => (await w.db.query(
    `INSERT INTO service_sessions (home_id, technician_name, expires_at, revoked_at)
     VALUES ($1, 'Usta', NOW() + ($2::int * INTERVAL '1 second'), CASE WHEN $3::boolean THEN NOW() ELSE NULL END) RETURNING id`,
    [w.homeId, expiresInS, revoked]
  )).rows[0].id;
  const dev = device(w, { is_online: false });
  const { markPending } = require('../../src/services/safety_cfg_sync');
  const live = () => sync.onLiveState({ topicId: w.topic, homeId: w.homeId, deviceId: w.deviceId, uid: w.uid, caps: ['cfg'], summary: { cfg: { rev: 7, crc: 'x' } } });
  const setOnline = (on) => w.db.query('UPDATE devices SET is_online = $2 WHERE id = $1', [w.deviceId, on]);
  const pendingOf = async () => (await w.db.query("SELECT pending FROM device_configs WHERE device_id = $1 AND module = 'safety'", [w.deviceId])).rows[0].pending;

  // (1) oturum kuyruga ekledi, sonra iptal edildi -> canli state'te 'revoked' ile duser
  const sid = await mkSession();
  await sync.patch({ actor: { userId: null, access: 'service_session', sessionId: sid }, homeId: w.homeId, device: dev, body: { base_rev: 7, set: { zone: { id: 1, name: 'S1' } } } });
  assert.equal((await pendingOf()).items[0].sid, sid);
  await w.db.query('UPDATE service_sessions SET revoked_at = NOW() WHERE id = $1', [sid]);
  await setOnline(true);
  markPending(w.deviceId);
  await live();
  assert.equal(sys.length, 0, 'iptal edilmis oturumun yamasi gitmez');
  assert.equal(await pendingOf(), null);

  // (2) gecerli oturum -> gider
  await setOnline(false);
  const sid2 = await mkSession();
  await sync.patch({ actor: { userId: null, access: 'service_session', sessionId: sid2 }, homeId: w.homeId, device: dev, body: { base_rev: 7, set: { zone: { id: 1, name: 'S2' } } } });
  await setOnline(true);
  markPending(w.deviceId);
  await live();
  assert.equal(sys.length, 1, 'gecerli oturumun yamasi gider');

  // (3) sid'siz ESKI oge: ogeden sonra iptal edilen oturum varsa duser
  const at = new Date(Date.now() - 60 * 1000).toISOString();
  await w.db.query("UPDATE device_configs SET pending = $2::jsonb WHERE device_id = $1 AND module = 'safety'", [
    w.deviceId, JSON.stringify({ v: 1, items: [{ id: 'old1', base_rev: 7, patch: { set: { zone: { id: 1, name: 'S3' } } }, by: null, role: 'service_session', at, loosening: false }] }),
  ]);
  await mkSession({ revoked: true });
  markPending(w.deviceId);
  await live();
  assert.equal(sys.length, 1, 'eski oge gitmedi');
  assert.equal(await pendingOf(), null);
});
