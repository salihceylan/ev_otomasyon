'use strict';

// WP-L D3 + D4 - GERCEK PostgreSQL: pano yerlesimi degisince (kanal 5-6 lambadan panjura)
//   D3: esitlemenin kapattigi role kurali {enabled:true} ile yeniden ACILAMAZ; uyumlu kural acilir;
//       kapatma her zaman serbest.
//   D4: zamanlayici atesleme aninda kanalin guncel tipine bakar: role kurali panjur kanalinda
//       yayinlanmaz ('skipped_invalid' gunluk satiri, yuva tuketilir); lamba kanalinda yayinlanir.
//
// Varsayilan olarak ATLANIR. Etkinlestirmek icin migration'lanmis bir veritabani:
//   EV_PG_TEST_URL=postgresql://... node --test test/bridge/scheduled_rules_layout_pg.test.js
// Her test kendi rastgele ev/kullanici/cihazini kurar ve sonunda siler.
// Esitleme burada dogrudan SQL ile benzetilir (endpoint_layout_sync'in yazdigi son durum:
// kanal tipi + kuralin kapatilmasi); boylece test yalniz kural/zamanlayici katmanini sinar.

const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');

const URL_ = process.env.EV_PG_TEST_URL;
const SKIP = URL_ ? false : 'EV_PG_TEST_URL tanimli degil (gercek PostgreSQL gerekir)';

const { Scheduler, SQL } = require('../../src/scheduler');
const { createService, ValidationError } = require('../../src/services/scheduled_rules_service');

let pool = null;
function getDb() {
  if (!pool) {
    const { Pool } = require('pg');
    pool = new Pool({ connectionString: URL_, max: 6 });
    pool.on('error', () => {});
  }
  return {
    query: (text, params) => pool.query(text, params),
    async withTransaction(fn) {
      const client = await pool.connect();
      try {
        await client.query('BEGIN');
        const result = await fn({ query: (t, p) => client.query(t, p) });
        await client.query('COMMIT');
        return result;
      } catch (err) {
        await client.query('ROLLBACK').catch(() => {});
        throw err;
      } finally {
        client.release();
      }
    },
  };
}

test.after(async () => {
  if (pool) await pool.end();
});

const silent = { log() {}, warn() {}, error() {} };
const hex = (n) => crypto.randomBytes(n).toString('hex');
const one = async (db, sql, params) => (await db.query(sql, params)).rows[0];

/** Ev + sahip + tek cihaz + 8 kanal (1-2 panjur cifti 1, 3-8 isik). */
async function makeFixture(db) {
  const tag = hex(5);
  const topic = `h_${hex(8)}`;
  const userId = (
    await db.query("INSERT INTO users (email, password_hash, full_name, role, is_active) VALUES ($1, 'x', 'Test Kullanici', 'user', TRUE) RETURNING id", [
      `t_${tag}@example.invalid`,
    ])
  ).rows[0].id;
  const homeId = (await db.query('INSERT INTO homes (name, mqtt_username) VALUES ($1, $2) RETURNING id', [`T-${tag}`, topic])).rows[0].id;
  await db.query("INSERT INTO home_users (home_id, user_id, role) VALUES ($1, $2, 'owner')", [homeId, userId]);
  const deviceId = (
    await db.query('INSERT INTO devices (home_id, device_uuid, mac_address, is_claimed, is_online) VALUES ($1, $2, $3, TRUE, TRUE) RETURNING id', [
      homeId,
      `AHBU-L${tag}`.toUpperCase(),
      `L${tag}`,
    ])
  ).rows[0].id;
  for (let ch = 1; ch <= 8; ch++) {
    const shutter = ch <= 2;
    await db.query(
      `INSERT INTO endpoints (home_id, device_id, channel_index, name, type, room, shutter_pair_index, shutter_duration_sec)
       VALUES ($1, $2, $3, $4, $5, 'Genel', $6, $7)`,
      [homeId, deviceId, ch, `K${ch}`, shutter ? 'shutter' : 'light', shutter ? 1 : null, shutter ? 20 : null]
    );
  }
  return {
    topic,
    userId,
    homeId,
    deviceId,
    async cleanup() {
      await db.query('DELETE FROM homes WHERE id = $1', [homeId]).catch(() => {});
      await db.query('DELETE FROM devices WHERE id = $1', [deviceId]).catch(() => {});
      await db.query('DELETE FROM users WHERE id = $1', [userId]).catch(() => {});
    },
  };
}

async function withFixture(fn) {
  const db = getDb();
  const fx = await makeFixture(db);
  try {
    await fn({ db, fx });
  } finally {
    await fx.cleanup();
  }
}

/** Esitlemenin son durumu: kanal 5-6 panjur cifti 3 oldu. */
async function makePair3Shutter(db, fx) {
  await db.query(
    "UPDATE endpoints SET type = 'shutter', shutter_pair_index = 3, shutter_duration_sec = 20 WHERE device_id = $1 AND channel_index IN (5, 6)",
    [fx.deviceId]
  );
}

async function insertRule(db, fx, over = {}) {
  const r = { channel: 5, channel_type: 'relay', action: 'on', hour: 8, minute: 30, enabled: true, device_id: null, ...over };
  return (
    await db.query(
      `INSERT INTO scheduled_rules (home_id, device_id, channel, channel_type, action, hour, minute, created_by, enabled)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9) RETURNING id`,
      [fx.homeId, r.device_id, r.channel, r.channel_type, r.action, r.hour, r.minute, fx.userId, r.enabled]
    )
  ).rows[0].id;
}

const SLOT = Date.parse('2031-03-04T05:30:20Z'); // Istanbul 08:30; gelecek (schedule_changed_at yuvadan once)

/** Zamanlayiciyi yalniz bu testin evine kapsamlar (paylasilan veritabaninda baska evlere dokunmaz). */
function scopedScheduler(db, fx, bridge, nowMs) {
  const scoped = {
    query: (text, params) =>
      text === SQL.candidates
        ? db.query(text, params).then((r) => ({ ...r, rows: r.rows.filter((x) => x.home_id === fx.homeId) }))
        : db.query(text, params),
  };
  const s = new Scheduler({ logger: silent, now: () => nowMs });
  s.db = scoped;
  s.mqttBridge = bridge;
  s._lastHousekeeping = nowMs;
  return s;
}

function fakeBridge() {
  const published = [];
  return {
    published,
    isConnected: () => true,
    async publishCommand(topic, cmd) {
      published.push({ topic, cmd });
      return {};
    },
  };
}

// ------------------------------------------------------------------------------
// D3
// ------------------------------------------------------------------------------
test('PG D3: kanal 5 panjur olmus evde kapali role kurali {enabled:true} ile ACILAMAZ; panjur kurali acilir; kapatma serbest', { skip: SKIP }, async () => {
  await withFixture(async ({ db, fx }) => {
    const svc = createService({ db });
    // Kural kanal 5 lambayken servisle olusturulur (gecerli)
    const relay = await svc.createRule(fx.homeId, fx.userId, { channel: 5, channel_type: 'relay', action: 'on', hour: 7, minute: 0 });
    // Esitleme: kanal 5-6 panjur cifti 3; role kurali kapatildi
    await makePair3Shutter(db, fx);
    await db.query('UPDATE scheduled_rules SET enabled = FALSE WHERE id = $1', [relay.id]);

    await assert.rejects(
      () => svc.updateRule(fx.homeId, relay.id, { enabled: true }),
      (e) => e instanceof ValidationError && e.status === 400 && e.code === 'VALIDATION' && /Kanal 5 bir panjura ayrılmış/.test(e.message)
    );
    assert.equal((await one(db, 'SELECT enabled FROM scheduled_rules WHERE id = $1', [relay.id])).enabled, false, 'kural kapali kalmali (geri alindi)');

    // Ayni kanala uygun panjur kurali (cift 3) kapaliysa yeniden acilabilir
    const shutterId = await insertRule(db, fx, { channel: 3, channel_type: 'shutter', action: 'open', enabled: false });
    const opened = await svc.updateRule(fx.homeId, shutterId, { enabled: true });
    assert.equal(opened.enabled, true);
    const row = await one(db, 'SELECT enabled, last_run_at, schedule_changed_at FROM scheduled_rules WHERE id = $1', [shutterId]);
    assert.equal(row.enabled, true);
    assert.equal(row.last_run_at, null);
    assert.ok(row.schedule_changed_at);

    // Lamba kanali (7) kapali role kurali da acilabilir
    const lightId = await insertRule(db, fx, { channel: 7, enabled: false });
    assert.equal((await svc.updateRule(fx.homeId, lightId, { enabled: true })).enabled, true);

    // Kapatma dogrulamasiz serbest: panjur kanalinda kalmis ACIK role kurali kapatilabilir
    const staleId = await insertRule(db, fx, { channel: 6, enabled: true });
    assert.equal((await svc.updateRule(fx.homeId, staleId, { enabled: false })).enabled, false);
    assert.equal((await one(db, 'SELECT enabled FROM scheduled_rules WHERE id = $1', [staleId])).enabled, false);
  });
});

// ------------------------------------------------------------------------------
// D4
// ------------------------------------------------------------------------------
test('PG D4: role kurali kanali panjurken atesleninca YAYIN YOK, gunlukte skipped_invalid; lamba kanalinda ve uygun panjur ciftinde yayin var', { skip: SKIP }, async () => {
  await withFixture(async ({ db, fx }) => {
    await makePair3Shutter(db, fx);
    // Kapatmayi kacirmis (yaris/eski) ACIK kurallar
    const relayOnShutter = await insertRule(db, fx, { channel: 5, action: 'on' });
    const relayOnLight = await insertRule(db, fx, { channel: 7, action: 'off' });
    const shutterOk = await insertRule(db, fx, { channel: 3, channel_type: 'shutter', action: 'close' });
    const shutterOnLights = await insertRule(db, fx, { channel: 2, channel_type: 'shutter', action: 'open' }); // kanal 3-4 isik

    const bridge = fakeBridge();
    const s = scopedScheduler(db, fx, bridge, SLOT);
    const r1 = await s.runTick(SLOT);
    assert.equal(r1.due, 4, JSON.stringify(r1));
    assert.equal(r1.sent, 2, JSON.stringify(r1));
    assert.equal(r1.skipped, 2, JSON.stringify(r1));

    const cmds = bridge.published.map((p) => p.cmd);
    assert.ok(cmds.every((c) => c.relay !== 5), 'panjur kanalina role komutu gitmemeli');
    assert.ok(cmds.every((c) => c.shutter !== 2), 'isik ciftine panjur komutu gitmemeli');
    assert.ok(cmds.some((c) => c.relay === 7 && c.state === false));
    assert.ok(cmds.some((c) => c.shutter === 3 && c.cmd === 'down'));
    assert.ok(bridge.published.every((p) => p.topic === fx.topic));

    const runs = new Map(
      (await db.query('SELECT rule_id, status, detail, attempts, command_id FROM scheduled_rule_runs WHERE home_id = $1', [fx.homeId])).rows.map((r) => [
        Number(r.rule_id),
        r,
      ])
    );
    assert.equal(runs.size, 4);
    assert.deepEqual(
      [runs.get(relayOnShutter).status, runs.get(relayOnShutter).detail, runs.get(relayOnShutter).command_id],
      ['skipped_invalid', 'kanal artik panjur; role kurali calistirilmadi', null]
    );
    assert.deepEqual([runs.get(shutterOnLights).status, runs.get(shutterOnLights).detail], ['skipped_invalid', 'kanal cifti artik panjur degil']);
    assert.equal(runs.get(relayOnLight).status, 'sent');
    assert.equal(runs.get(shutterOk).status, 'sent');

    // Kalici durum: talep GERI BIRAKILMAZ (last_run_at = yuva); pencere icinde yeniden denenmez
    for (const id of [relayOnShutter, shutterOnLights]) {
      const rr = await one(db, 'SELECT last_run_at, enabled FROM scheduled_rules WHERE id = $1', [id]);
      assert.equal(new Date(rr.last_run_at).toISOString(), '2031-03-04T05:30:00.000Z');
      assert.equal(rr.enabled, true, 'zamanlayici kurali kapatmaz, yalniz atlar');
    }
    const r2 = await s.runTick(SLOT + 60000);
    assert.equal(r2.due, 0);
    assert.equal(bridge.published.length, 2);
    assert.equal((await one(db, 'SELECT attempts FROM scheduled_rule_runs WHERE rule_id = $1', [relayOnShutter])).attempts, 1);
  });
});

test('PG D4: ayni kanal (5) lambayken role kurali yayinlanir; hedef sorgusu gercek SQL ile gecerli', { skip: SKIP }, async () => {
  await withFixture(async ({ db, fx }) => {
    const ruleId = await insertRule(db, fx, { channel: 5, action: 'on' });
    const bridge = fakeBridge();
    const r = await scopedScheduler(db, fx, bridge, SLOT).runTick(SLOT);
    assert.equal(r.sent, 1, JSON.stringify(r));
    assert.deepEqual({ relay: bridge.published[0].cmd.relay, state: bridge.published[0].cmd.state }, { relay: 5, state: true });
    assert.equal((await one(db, 'SELECT status FROM scheduled_rule_runs WHERE rule_id = $1', [ruleId])).status, 'sent');

    // Hedef sorgusu dogrudan: cihaz + kanal dizisi
    const rows = (await db.query(SQL.target, [fx.deviceId, [1, 2, 5]])).rows.sort((a, b) => a.channel_index - b.channel_index);
    assert.deepEqual(rows.map((x) => [x.channel_index, x.type]), [[1, 'shutter'], [2, 'shutter'], [5, 'light']]);
  });
});
