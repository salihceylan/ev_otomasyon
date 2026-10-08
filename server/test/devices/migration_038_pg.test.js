'use strict';

// kullanim-4 / guvenlik-1: migration 038 veri onarimi GERCEK PostgreSQL'de (YALITILMIS gecici veritabani).
//   - eski (evden ayrilmis) panoya bagli kalmis zamanli kural, degisim kaydindaki yeni panoya tasinir; A -> B -> C zinciri
//   - eslesmeyen kurala dokunulmaz
//   - evden ayrilmis panonun acik alarmi lost/detached olur; evdeki panonun alarmi ve kapali satirlar korunur
//   - ikinci calistirma no-op
// EV_PG_TEST_URL yoksa ATLANIR.

const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const { PG_SKIP, open } = require('../templates/_pg_isolated');

const SQL_038 = fs.readFileSync(path.join(__dirname, '..', '..', 'migrations', '038_replace_board_repairs.sql'), 'utf8');
const hex = (n) => crypto.randomBytes(n).toString('hex');

test('038: kural tasima (zincir dahil) + acik alarm onarimi; ikinci calistirma no-op', { skip: PG_SKIP }, async (t) => {
  const env = await open('m038');
  if (!env) {
    t.skip('CREATE DATABASE yetkisi yok');
    return;
  }
  const { db } = env;
  try {
    const user = (await db.query("INSERT INTO users (email, full_name, password_hash) VALUES ($1, 'Sahip', 'x') RETURNING id", [`m038-${hex(4)}@test.invalid`])).rows[0];
    const home = (await db.query('INSERT INTO homes (name, mqtt_username) VALUES ($1, $2) RETURNING id', ['M038', `h_${hex(8)}`])).rows[0];
    const other = (await db.query('INSERT INTO homes (name, mqtt_username) VALUES ($1, $2) RETURNING id', ['M038-B', `h_${hex(8)}`])).rows[0];
    const dev = async (homeId, uuid) =>
      (await db.query('INSERT INTO devices (home_id, device_uuid, mac_address) VALUES ($1, $2, $3) RETURNING id, device_uuid', [homeId, uuid, `E8:F6:0A:${hex(1)}:${hex(1)}:${hex(1)}`])).rows[0];
    // A -> B -> C zinciri: A ve B evden ayrildi, C evde
    const a = await dev(null, `AHBU-M38-A${hex(2)}`.toUpperCase());
    const b = await dev(null, `AHBU-M38-B${hex(2)}`.toUpperCase());
    const c = await dev(home.id, `AHBU-M38-C${hex(2)}`.toUpperCase());
    // tek adimli degisim: D -> E
    const d = await dev(null, `AHBU-M38-D${hex(2)}`.toUpperCase());
    const e = await dev(home.id, `AHBU-M38-E${hex(2)}`.toUpperCase());
    // baska evdeki ilgisiz cihaz
    const x = await dev(other.id, `AHBU-M38-X${hex(2)}`.toUpperCase());
    const log = (o, n) => db.query(
      'INSERT INTO device_replacement_logs (home_id, old_device_uuid, new_device_uuid, replaced_by_user_id) VALUES ($1, $2, $3, $4)',
      [home.id, o.device_uuid, n.device_uuid, user.id]
    );
    await log(a, b);
    await log(b, c);
    await log(d, e);
    const rule = async (homeId, deviceId) => (await db.query(
      "INSERT INTO scheduled_rules (home_id, device_id, channel, channel_type, action, hour, minute, created_by) VALUES ($1, $2, 5, 'relay', 'on', 8, 0, $3) RETURNING id",
      [homeId, deviceId, user.id]
    )).rows[0].id;
    const rA = await rule(home.id, a.id);
    const rD = await rule(home.id, d.id);
    const rX = await rule(other.id, x.id);
    const alarm = async (homeId, deviceId, status, aid) => (await db.query(
      'INSERT INTO alarms (home_id, device_id, aid, zone, kind, status, raised_at, ack_requested_at, ack_requested_by) VALUES ($1, $2, $3, 1, $4, $5, now(), now(), $6) RETURNING id',
      [homeId, deviceId, aid, 'gas', status, user.id]
    )).rows[0].id;
    const alOpen = await alarm(home.id, d.id, 'latched', `${hex(4)}-1`);
    const alCleared = await alarm(home.id, d.id, 'cleared', `${hex(4)}-2`);
    const alHome = await alarm(home.id, e.id, 'latched', `${hex(4)}-3`);

    await db.withTransaction((tx) => tx.query(SQL_038));

    const devOf = async (id) => (await db.query('SELECT device_id FROM scheduled_rules WHERE id = $1', [id])).rows[0].device_id;
    assert.equal(await devOf(rA), c.id, 'A -> B -> C zinciri izlendi');
    assert.equal(await devOf(rD), e.id, 'tek adim');
    assert.equal(await devOf(rX), x.id, 'eslesmeyen kurala dokunulmaz');
    const al = async (id) => (await db.query('SELECT status, cleared_by, cleared_at, ack_requested_at, ack_requested_by FROM alarms WHERE id = $1', [id])).rows[0];
    const o = await al(alOpen);
    assert.equal(o.status, 'lost');
    assert.equal(o.cleared_by, 'detached');
    assert.ok(o.cleared_at);
    assert.equal(o.ack_requested_at, null);
    assert.equal(o.ack_requested_by, null);
    assert.equal((await al(alCleared)).status, 'cleared');
    assert.equal((await al(alHome)).status, 'latched', 'evdeki panonun alarmi korunur');

    // ikinci calistirma: hicbir satir degismez
    const snap = async () => JSON.stringify((await db.query(
      'SELECT id, device_id, updated_at FROM scheduled_rules ORDER BY id'
    )).rows) + JSON.stringify((await db.query('SELECT id, status, updated_at FROM alarms ORDER BY id')).rows);
    const before = await snap();
    await db.withTransaction((tx) => tx.query(SQL_038));
    assert.equal(await snap(), before, 'idempotent');
  } finally {
    await env.close();
  }
});
