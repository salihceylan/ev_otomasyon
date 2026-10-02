'use strict';

// WP-H - GERCEK PostgreSQL test yardimcilari (KAPILI: EV_PG_TEST_URL yoksa kullanan testler ATLANIR).
//
// Hedef veritabani TAMAMEN migration'lanmis (030 dahil) olmalidir:
//   node scripts/migrate.js            (MIGRATE_CONFIRM=<db>, DATABASE_URL=<hedef>)
//   EV_PG_TEST_URL=postgresql://kullanici:parola@127.0.0.1:5432/<db> node --test test/peace/peace_service_pg.test.js
//
// Her test KENDI (rastgele) ev/kullanici/cihaz satirlarini olusturur ve sonunda siler; paylasilan bir
// veritabaninda baska evlere dokunmaz. Genel DELETE/TRUNCATE YOKTUR.

const crypto = require('node:crypto');

const PG_URL = process.env.EV_PG_TEST_URL;
const PG_SKIP = PG_URL ? false : 'EV_PG_TEST_URL tanimli degil (gercek PostgreSQL gerekir)';

const hex = (n) => crypto.randomBytes(n).toString('hex');
const silent = { log() {}, warn() {}, error() {} };

let pool = null;
function getPool() {
  if (!pool) {
    const { Pool } = require('pg');
    pool = new Pool({ connectionString: PG_URL, max: 12 });
    pool.on('error', () => {});
  }
  return pool;
}

/** src/db.js ile ayni sozlesme: { query, withTransaction } (gercek tek baglantili transaction). */
function getDb() {
  const p = getPool();
  return {
    query: (text, params) => p.query(text, params),
    async withTransaction(fn) {
      const client = await p.connect();
      try {
        await client.query('BEGIN');
        const result = await fn({ query: (text, params) => client.query(text, params) });
        await client.query('COMMIT');
        return result;
      } catch (err) {
        try {
          await client.query('ROLLBACK');
        } catch (_) {
          /* asil hata onemli */
        }
        throw err;
      } finally {
        client.release();
      }
    },
  };
}

async function closePool() {
  if (pool) {
    const p = pool;
    pool = null;
    await p.end();
  }
}

/** DeviceService._audit ile ayni INSERT (peace_service'e `audit` olarak verilir). */
function auditLikeDeviceService(q, { event, deviceUuid = null, homeId = null, actor = null, details = null }) {
  return q(
    `INSERT INTO device_audit_logs (event, device_uuid, home_id, actor_user_id, actor_role, ip_address, details)
     VALUES ($1, $2, $3, $4, $5, $6, $7)`,
    [
      event,
      deviceUuid,
      homeId,
      (actor && actor.userId) || null,
      (actor && (actor.globalRole || actor.access)) || null,
      (actor && actor.ip) || null,
      details ? JSON.stringify(details) : null,
    ]
  );
}

async function pgUser(db, tag) {
  return (
    await db.query("INSERT INTO users (email, password_hash, full_name, role, is_active) VALUES ($1, $2, 'Test Kullanici', 'user', TRUE) RETURNING id", [
      `ps_${tag}_${hex(3)}@example.invalid`,
      'x',
    ])
  ).rows[0].id;
}

/**
 * Rastgele ev + sahip + cihazlar.
 * devices: [{ online, seenSecAgo, endpoints:[{ ch, type, room, pair, on, pos }] }]
 * (seenSecAgo veritabani saatine gore; null = hic gorulmedi).
 */
async function pgFixture(db, { name, devices = [{ online: true, seenSecAgo: 10, endpoints: [] }] } = {}) {
  const tag = hex(5);
  const userId = await pgUser(db, tag);
  const topic = `h_${hex(8)}`;
  const homeId = (
    await db.query(
      "INSERT INTO homes (name, mqtt_username, timezone, peace_notification_time, peace_notification_enabled) VALUES ($1, $2, 'Europe/Istanbul', '23:30', TRUE) RETURNING id",
      [name || `PS-${tag}`, topic]
    )
  ).rows[0].id;
  await db.query("INSERT INTO home_users (home_id, user_id, role) VALUES ($1, $2, 'owner')", [homeId, userId]);

  const deviceIds = [];
  for (let i = 0; i < devices.length; i += 1) {
    const spec = devices[i];
    const id = (
      await db.query('INSERT INTO devices (home_id, device_uuid, mac_address, is_claimed) VALUES ($1, $2, $3, TRUE) RETURNING id', [
        homeId,
        `AHBU-S${tag}-${i}`.toUpperCase(),
        `S${tag}${i}`,
      ])
    ).rows[0].id;
    await db.query(
      "UPDATE devices SET is_online = $2, last_seen_at = CASE WHEN $3::int IS NULL THEN NULL ELSE now() - ($3::int * interval '1 second') END WHERE id = $1",
      [id, spec.online, spec.seenSecAgo === undefined ? null : spec.seenSecAgo]
    );
    for (const e of spec.endpoints || []) {
      await db.query(
        `INSERT INTO endpoints (home_id, device_id, channel_index, name, type, room, shutter_pair_index, current_state, current_position)
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)`,
        [homeId, id, e.ch, `K${e.ch}`, e.type, e.room === undefined ? 'Genel' : e.room, e.pair === undefined ? null : e.pair, Boolean(e.on), e.pos || 0]
      );
    }
    deviceIds.push(id);
  }

  return {
    tag,
    userId,
    homeId,
    topic,
    deviceIds,
    async cleanup() {
      // peace_notification_logs ev silinince CASCADE gider; denetim kaydi SET NULL oldugu icin ayrica silinir.
      await db.query('DELETE FROM device_audit_logs WHERE home_id = $1', [homeId]).catch(() => {});
      await db.query('DELETE FROM homes WHERE id = $1', [homeId]).catch(() => {});
      if (deviceIds.length > 0) await db.query('DELETE FROM devices WHERE id = ANY($1::uuid[])', [deviceIds]).catch(() => {});
      await db.query('DELETE FROM users WHERE id = $1', [userId]).catch(() => {});
    },
  };
}

async function withPgFixture(opts, fn) {
  const db = getDb();
  const fx = await pgFixture(db, opts);
  try {
    await fn({ db, fx });
  } finally {
    await fx.cleanup();
  }
}

/** Salon: 2 lamba acik + 1 panjur cifti (2 role, ikisi de %100) + kapali lamba (Mutfak). */
const OPEN_ENDPOINTS = Object.freeze([
  Object.freeze({ ch: 1, type: 'shutter', room: 'Salon', pos: 100 }),
  Object.freeze({ ch: 2, type: 'shutter', room: 'Salon', pos: 100 }),
  Object.freeze({ ch: 3, type: 'light', room: 'Salon', on: true }),
  Object.freeze({ ch: 4, type: 'light', room: 'Salon', on: true }),
  Object.freeze({ ch: 5, type: 'light', room: 'Mutfak', on: false }),
]);

module.exports = {
  PG_SKIP,
  hex,
  silent,
  getDb,
  closePool,
  auditLikeDeviceService,
  pgUser,
  pgFixture,
  withPgFixture,
  OPEN_ENDPOINTS,
};
