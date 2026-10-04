'use strict';

// WP-L - Uc nokta yerlesim esitleme: GERCEK PostgreSQL entegrasyon testleri.
//
// Varsayilan olarak ATLANIR (`npm test` PostgreSQL gerektirmez). Etkinlestirmek icin 001..031 uygulanmis bir
// veritabani verin (desen: test/bridge/reconcile_pg.test.js):
//   EV_PG_TEST_URL=postgresql://kullanici@127.0.0.1:5432/<db> node --test test/layout/layout_pg.test.js
//
// Her test KENDI satirlarini (rastgele ev / cihaz / kullanici / uc nokta / kural) olusturur ve sonunda siler;
// baska verilere dokunmaz. Neden gercek PG: servisin SQL'i (FOR UPDATE kilit sirasi, ON CONFLICT, JSONB taban,
// int[] parametreli kural kapatma, CHECK/UNIQUE kisitlari, updated_at tetikleyicisi) mock'la kanitlanamaz.
// Plan: docs/superpowers/plans/2026-10-03-uc-nokta-yerlesim-esitleme.md, Task 5.

const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');

const URL_ = process.env.EV_PG_TEST_URL;
const SKIP = URL_ ? false : 'EV_PG_TEST_URL tanimli degil (gercek PostgreSQL gerekir)';

const { MqttBridge } = require('../../src/mqtt_bridge');
const { createEndpointLayoutSync, constants } = require('../../src/services/endpoint_layout_sync');
const { extractReportedLayout, seedDefaults, parseBase, serializeBase, DEFAULT_SHUTTER_SEC } = require('../../src/utils/endpoint_layout');
const { fwState } = require('./_helpers');

const { SHRINK_CONFIRM_MS, AUDIT_EVENT } = constants;
const DEVICE_SERVICE_PATH = path.join(__dirname, '..', '..', 'src', 'services', 'device_service.js');

const silent = { log() {}, warn() {}, error() {} };
const hex = (n) => crypto.randomBytes(n).toString('hex');

// ------------------------------------------------------------------------------
// Veritabani sarmalayicisi (src/db.js yuzeyi: query + withTransaction)
// ------------------------------------------------------------------------------
let pool = null;
function getPool() {
  if (!pool) {
    const { Pool } = require('pg');
    pool = new Pool({ connectionString: URL_, max: 8 });
    pool.on('error', () => {});
  }
  return pool;
}

/**
 * @param {object} [hooks]
 * @param {Function} [hooks.beforeTx]  withTransaction geri cagrimi calismadan once (tek seferlik) calisir
 * @param {Function} [hooks.onQuery]   her kilitsiz sorgu metni icin cagrilir (sira kaydi)
 */
function getDb(hooks = {}) {
  const p = getPool();
  return {
    query: (text, params) => {
      if (hooks.onQuery) hooks.onQuery(text);
      return p.query(text, params);
    },
    async withTransaction(fn) {
      if (hooks.beforeTx) {
        const hook = hooks.beforeTx; // tek seferlik; test kancayi sonradan atayabilir
        hooks.beforeTx = null;
        await hook();
      }
      if (hooks.onTx) hooks.onTx();
      const client = await p.connect();
      try {
        await client.query('BEGIN');
        const result = await fn({ query: (t, q) => client.query(t, q) });
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
  if (pool) await pool.end().catch(() => {});
});

// ------------------------------------------------------------------------------
// Fikstur: ev + cihaz(lar) + kullanici + tohum satirlari (seedDefaults ile)
// ------------------------------------------------------------------------------
async function seedRows(db, homeId, deviceId, count) {
  for (let c = 1; c <= count; c += 1) {
    const s = seedDefaults(c);
    await db.query(
      'INSERT INTO endpoints (home_id, device_id, channel_index, name, type, room, shutter_pair_index, shutter_duration_sec) ' +
        'VALUES ($1, $2, $3, $4, $5, $6, $7, $8)',
      [homeId, deviceId, c, s.name, s.type, s.room, s.pair, s.durationSec]
    );
  }
}

async function makeFixture(db, { devices = 1, seed = 8 } = {}) {
  const tag = hex(5);
  const topic = `h_${hex(8)}`;
  const homeId = (await db.query('INSERT INTO homes (name, mqtt_username) VALUES ($1, $2) RETURNING id', [`L-${tag}`, topic])).rows[0].id;
  const userId = (
    await db.query("INSERT INTO users (email, password_hash, full_name) VALUES ($1, 'x', 'Test') RETURNING id", [`l-${tag}@test.invalid`])
  ).rows[0].id;
  const devs = [];
  for (let i = 0; i < devices; i += 1) {
    const uuid = `AHBU-L${tag}-${i}`.toUpperCase();
    devs.push(
      (
        await db.query(
          'INSERT INTO devices (home_id, device_uuid, mac_address, is_claimed) VALUES ($1, $2, $3, TRUE) RETURNING id, device_uuid',
          [homeId, uuid, `L${tag}${i}`]
        )
      ).rows[0]
    );
  }
  if (seed > 0) await seedRows(db, homeId, devs[0].id, seed);
  const extraHomes = [];
  return {
    topic,
    homeId,
    userId,
    devices: devs,
    dev: devs[0],
    async addHome() {
      const id = (await db.query('INSERT INTO homes (name, mqtt_username) VALUES ($1, $2) RETURNING id', [`L2-${tag}`, `h_${hex(8)}`])).rows[0].id;
      extraHomes.push(id);
      return id;
    },
    async addRule({ deviceId = null, channelType, channel, action }) {
      const r = await db.query(
        'INSERT INTO scheduled_rules (home_id, device_id, channel, channel_type, action, hour, minute, created_by) ' +
          'VALUES ($1, $2, $3, $4, $5, 7, 30, $6) RETURNING id',
        [homeId, deviceId, channel, channelType, action, userId]
      );
      return r.rows[0].id;
    },
    async cleanup() {
      const uuids = devs.map((d) => d.device_uuid);
      await db.query('DELETE FROM device_audit_logs WHERE device_uuid = ANY($1::text[])', [uuids]).catch(() => {});
      await db.query('DELETE FROM homes WHERE id = ANY($1::uuid[])', [[homeId, ...extraHomes]]).catch(() => {});
      await db.query('DELETE FROM devices WHERE id = ANY($1::uuid[])', [devs.map((d) => d.id)]).catch(() => {});
      await db.query('DELETE FROM users WHERE id = $1', [userId]).catch(() => {});
    },
  };
}

async function withFixture(opts, fn) {
  const db = getDb(opts.hooks || {});
  const fx = await makeFixture(db, opts);
  try {
    await fn(db, fx);
  } finally {
    await fx.cleanup();
  }
}

const ROWS_SQL =
  'SELECT id, channel_index, name, type, room, shutter_pair_index, shutter_duration_sec, current_state, current_position, ' +
  'updated_at::text AS updated_at FROM endpoints WHERE device_id = $1 ORDER BY channel_index';
const rowsOf = async (db, dev) => (await db.query(ROWS_SQL, [dev.id])).rows;
const rowAt = (rows, channel) => rows.find((r) => r.channel_index === channel);
const auditsOf = async (db, dev) =>
  (
    await db.query('SELECT id, home_id, actor_user_id, actor_role, details, details::text AS details_text FROM device_audit_logs WHERE device_uuid = $1 AND event = $2 ORDER BY id', [
      dev.device_uuid,
      AUDIT_EVENT,
    ])
  ).rows;
const baseOf = async (db, dev) => (await db.query('SELECT reported_layout, reported_layout_at::text AS at FROM devices WHERE id = $1', [dev.id])).rows[0];
const ruleEnabled = async (db, id) => (await db.query('SELECT enabled FROM scheduled_rules WHERE id = $1', [id])).rows[0].enabled;

/** extractReportedLayout(fwState(o)); gecersiz test girdisinde hemen hata verir. */
function layoutOf(o) {
  const layout = extractReportedLayout(fwState(o));
  if (!layout) throw new Error('gecersiz test yerlesimi');
  return layout;
}

function makeSync(db, extra = {}) {
  return createEndpointLayoutSync({ db, logger: silent, ...extra });
}

const sync = (svc, fx, layout) => svc.syncNow({ homeId: fx.homeId, deviceId: fx.dev.id, layout });

const SHUTTER_56 = { 5: { type: 'shutter_up', name: 'Salon (Yukari)' }, 6: { type: 'shutter_down', name: 'Salon (Asagi)' } };
const LIGHT_12 = { 1: { type: 'light', name: 'Röle 1 Aydınlatma' }, 2: { type: 'light', name: 'Röle 2 Aydınlatma' } };

/** 1..count tum roleler panjur cifti (adlar panonun fabrika adlari kalir: ad vermeden yalniz tip degisti). */
function allShutters(count) {
  const set = {};
  for (let c = 1; c <= count; c += 1) set[c] = { type: c % 2 === 1 ? 'shutter_up' : 'shutter_down' };
  return set;
}

// ==============================================================================
// 1-4: tohum -> esitleme uctan uca, tip gecisleri, idempotency
// ==============================================================================
test('1) varsayilan pano: satirlar DEGISMEZ, devices.reported_layout yazilir, denetim kaydi YOK', { skip: SKIP }, async () => {
  await withFixture({}, async (db, fx) => {
    const before = await rowsOf(db, fx.dev);
    assert.equal(before.length, 8);
    const svc = makeSync(db);
    const res = await sync(svc, fx, layoutOf({}));
    assert.equal(res.status, 'applied', JSON.stringify(res));
    assert.equal(res.summary.baseSaved, true);
    assert.equal(res.summary.inserted + res.summary.retyped + res.summary.renamed + res.summary.reroomed + res.summary.deleted, 0);

    const after = await rowsOf(db, fx.dev);
    assert.deepEqual(
      after.map((r) => [r.channel_index, r.name, r.type, r.room, r.shutter_pair_index, r.shutter_duration_sec]),
      before.map((r) => [r.channel_index, r.name, r.type, r.room, r.shutter_pair_index, r.shutter_duration_sec])
    );
    const base = await baseOf(db, fx.dev);
    assert.ok(base.reported_layout, 'taban yazilmali');
    assert.ok(base.at, 'reported_layout_at yazilmali');
    assert.equal(base.reported_layout.v, 1);
    assert.equal(base.reported_layout.relays.length, 8);
    assert.equal((await auditsOf(db, fx.dev)).length, 0, 'satir degismedi: denetim kaydi yok');
  });
});

test('2) 5-6 panjur: iki satir shutter, cift 3, sure 20, pano adlari; kimlikler AYNI kalir; denetim kaydi 1 satir', { skip: SKIP }, async () => {
  await withFixture({}, async (db, fx) => {
    const before = await rowsOf(db, fx.dev);
    const svc = makeSync(db);
    const res = await sync(svc, fx, layoutOf({ set: SHUTTER_56 }));
    assert.equal(res.status, 'applied', JSON.stringify(res));

    const after = await rowsOf(db, fx.dev);
    assert.equal(after.length, 8);
    for (const c of [5, 6]) {
      const r = rowAt(after, c);
      assert.equal(r.id, rowAt(before, c).id, `kanal ${c} kimligi korunur`);
      assert.equal(r.type, 'shutter');
      assert.equal(r.shutter_pair_index, 3);
      assert.equal(r.shutter_duration_sec, DEFAULT_SHUTTER_SEC);
      assert.equal(r.room, 'Salon');
    }
    assert.equal(rowAt(after, 5).name, 'Salon (Yukari)');
    assert.equal(rowAt(after, 6).name, 'Salon (Asagi)');
    // diger satirlar dokunulmadi
    for (const c of [1, 2, 3, 4, 7, 8]) {
      assert.deepEqual(rowAt(after, c), rowAt(before, c), `kanal ${c} dokunulmadi`);
    }
    const audits = await auditsOf(db, fx.dev);
    assert.equal(audits.length, 1);
    assert.equal(audits[0].home_id, fx.homeId);
    assert.equal(audits[0].actor_user_id, null);
    assert.equal(audits[0].actor_role, 'device');
    const d = audits[0].details;
    assert.equal(d.relays, 8);
    assert.equal(d.retyped, 2);
    assert.equal(d.renamed, 2);
    assert.equal(d.inserted, 0);
    assert.equal(d.deleted, 0);
    assert.deepEqual(d.rules_disabled, []);
  });
});

test('3) ayni bildirim ikinci kez: SIFIR yazma (updated_at ve reported_layout_at degismez, denetim kaydi artmaz)', { skip: SKIP }, async () => {
  await withFixture({}, async (db, fx) => {
    const svc = makeSync(db);
    const layout = layoutOf({ set: SHUTTER_56 });
    assert.equal((await sync(svc, fx, layout)).status, 'applied');
    const rows1 = await rowsOf(db, fx.dev);
    const base1 = await baseOf(db, fx.dev);
    await new Promise((r) => setTimeout(r, 15)); // zaman damgasi farki olusabilsin

    const res = await sync(svc, fx, layout);
    assert.equal(res.status, 'noop', JSON.stringify(res));
    const rows2 = await rowsOf(db, fx.dev);
    assert.deepEqual(rows2, rows1, 'updated_at dahil hicbir alan degismedi');
    const base2 = await baseOf(db, fx.dev);
    assert.equal(base2.at, base1.at, 'taban yeniden yazilmadi');
    assert.equal((await auditsOf(db, fx.dev)).length, 1);
  });
});

test('4) 1-2 lamba: type light, cift/sure NULL, konum 0', { skip: SKIP }, async () => {
  await withFixture({}, async (db, fx) => {
    await db.query('UPDATE endpoints SET current_position = 55 WHERE device_id = $1 AND channel_index IN (1, 2)', [fx.dev.id]);
    const svc = makeSync(db);
    const res = await sync(svc, fx, layoutOf({ set: LIGHT_12 }));
    assert.equal(res.status, 'applied', JSON.stringify(res));
    const rows = await rowsOf(db, fx.dev);
    for (const c of [1, 2]) {
      const r = rowAt(rows, c);
      assert.equal(r.type, 'light');
      assert.equal(r.shutter_pair_index, null);
      assert.equal(r.shutter_duration_sec, null);
      assert.equal(r.current_position, 0);
      assert.equal(r.name, LIGHT_12[c].name);
      assert.equal(r.room, 'Genel');
    }
    assert.equal(rowAt(rows, 3).type, 'shutter', 'ikinci cift dokunulmadi');
    assert.equal(rowAt(rows, 3).shutter_pair_index, 2);
  });
});

// ==============================================================================
// 5: zamanli kurallar
// ==============================================================================
test('5) zamanli kurallar: sinifi degisen kanal 5 (relay) ve cift 1 (shutter) kurallari KAPANIR; baska kanal ve baska cihazin kurali etkilenmez', { skip: SKIP }, async () => {
  await withFixture({ devices: 2 }, async (db, fx) => {
    const other = fx.devices[1];
    // D14: iki panolu evde device_id NULL kural kapatilmaz (bkz. 22); sinif degisimi kapatmasi bu cihaza bagli kuralla sinanir
    const relay5 = await fx.addRule({ deviceId: fx.dev.id, channelType: 'relay', channel: 5, action: 'on' });
    const shutter1 = await fx.addRule({ deviceId: fx.dev.id, channelType: 'shutter', channel: 1, action: 'open' });
    const relay7 = await fx.addRule({ channelType: 'relay', channel: 7, action: 'on' });
    const shutter2 = await fx.addRule({ channelType: 'shutter', channel: 2, action: 'close' });
    const otherDev5 = await fx.addRule({ deviceId: other.id, channelType: 'relay', channel: 5, action: 'on' });
    const thisDev6 = await fx.addRule({ deviceId: fx.dev.id, channelType: 'relay', channel: 6, action: 'off' });

    const svc = makeSync(db);
    const res = await sync(svc, fx, layoutOf({ set: { ...SHUTTER_56, ...LIGHT_12 } }));
    assert.equal(res.status, 'applied', JSON.stringify(res));
    assert.equal(res.summary.rulesDisabled, 3);

    assert.equal(await ruleEnabled(db, relay5), false, 'kanal 5 role kurali artik panjur motorunu surerdi');
    assert.equal(await ruleEnabled(db, thisDev6), false, 'bu cihaza ozgu kanal 6 kurali');
    assert.equal(await ruleEnabled(db, shutter1), false, 'cift 1 artik lamba');
    assert.equal(await ruleEnabled(db, relay7), true, 'baska kanal');
    assert.equal(await ruleEnabled(db, shutter2), true, 'baska cift');
    assert.equal(await ruleEnabled(db, otherDev5), true, 'baska cihazin kurali');

    const audits = await auditsOf(db, fx.dev);
    assert.equal(audits.length, 1);
    assert.deepEqual([...audits[0].details.rules_disabled].sort((a, b) => a - b), [relay5, shutter1, thisDev6].sort((a, b) => a - b));
  });
});

// ==============================================================================
// 6: ek modul buyume / kuculme (onayli silme)
// ==============================================================================
test('6) ek modul: 16 role -> 8 yeni satir; 8 role -> ilk bildirimde SILINMEZ, onay suresi sonra ikinci bildirimde silinir (+ kurali kapanir)', { skip: SKIP }, async () => {
  await withFixture({}, async (db, fx) => {
    let clock = Date.now();
    const svc = makeSync(db, { now: () => clock });

    const res16 = await sync(svc, fx, layoutOf({ count: 16 }));
    assert.equal(res16.status, 'applied', JSON.stringify(res16));
    assert.equal(res16.summary.inserted, 8);
    let rows = await rowsOf(db, fx.dev);
    assert.equal(rows.length, 16);
    for (let c = 9; c <= 16; c += 1) {
      const r = rowAt(rows, c);
      assert.equal(r.name, `Ek Modül Röle ${c - 8}`);
      assert.equal(r.type, 'light');
      assert.equal(r.room, 'Genel');
      assert.equal(r.shutter_pair_index, null);
      assert.equal(r.current_state, false);
    }
    const rule12 = await fx.addRule({ channelType: 'relay', channel: 12, action: 'on' });

    // kuculme: ilk gorus
    const resA = await sync(svc, fx, layoutOf({ count: 8 }));
    assert.notEqual(resA.status, 'error', JSON.stringify(resA));
    assert.equal(resA.summary.pendingShrink, true);
    assert.equal(resA.summary.deleted, 0);
    rows = await rowsOf(db, fx.dev);
    assert.equal(rows.length, 16, 'tek bildirim satir silemez');
    assert.equal(await ruleEnabled(db, rule12), true);

    // onay suresi dolmadan tekrar: yine silinmez
    clock += SHRINK_CONFIRM_MS - 1000;
    const resB = await sync(svc, fx, layoutOf({ count: 8 }));
    assert.equal(resB.summary.pendingShrink, true);
    assert.equal((await rowsOf(db, fx.dev)).length, 16);

    // onay suresi doldu: silinir
    clock += 1000;
    const resC = await sync(svc, fx, layoutOf({ count: 8 }));
    assert.equal(resC.status, 'applied', JSON.stringify(resC));
    assert.equal(resC.summary.deleted, 8);
    assert.equal(resC.summary.pendingShrink, false);
    rows = await rowsOf(db, fx.dev);
    assert.deepEqual(
      rows.map((r) => r.channel_index),
      [1, 2, 3, 4, 5, 6, 7, 8]
    );
    assert.equal(await ruleEnabled(db, rule12), false, 'silinen kanalin kurali kapanir');
    const audits = await auditsOf(db, fx.dev);
    assert.equal(audits.length, 2);
    assert.equal(audits[1].details.deleted, 8);
    assert.deepEqual(audits[1].details.rules_disabled, [rule12]);
  });
});

// ==============================================================================
// 7-8: ad kurallari (taban) ve yaris
// ==============================================================================
test('7) ad kurallari: pano adi ozel -> alinir; kullanici PUT adi sonraki ayni bildirimde KORUNUR; panoda ad degisince pano adi kazanir', { skip: SKIP }, async () => {
  await withFixture({}, async (db, fx) => {
    const svc = makeSync(db);
    // a) pano kanal 6'ya ad verdi, bulut sablon adinda
    const resA = await sync(svc, fx, layoutOf({ set: { 6: { name: 'Mutfak Spot' } } }));
    assert.equal(resA.status, 'applied', JSON.stringify(resA));
    let r6 = rowAt(await rowsOf(db, fx.dev), 6);
    assert.equal(r6.name, 'Mutfak Spot');
    assert.equal(r6.room, 'Mutfak');
    assert.equal(r6.type, 'light');
    const base = parseBase((await baseOf(db, fx.dev)).reported_layout);
    assert.equal(base.relays[5].name, 'Mutfak Spot');

    // b) kullanici bulutta ad verdi (PUT benzeri); pano ayni adi bildirmeye devam ediyor -> korunur
    await db.query('UPDATE endpoints SET name = $2 WHERE device_id = $1 AND channel_index = 6', [fx.dev.id, 'Tezgah']);
    const resB = await sync(svc, fx, layoutOf({ set: { 6: { name: 'Mutfak Spot' } } }));
    assert.equal(resB.status, 'noop', JSON.stringify(resB));
    r6 = rowAt(await rowsOf(db, fx.dev), 6);
    assert.equal(r6.name, 'Tezgah', 'kullanici adi korunur');

    // c) panoda ad degisti -> son yazan kazanir
    const resC = await sync(svc, fx, layoutOf({ set: { 6: { name: 'Mutfak Tezgah' } } }));
    assert.equal(resC.status, 'applied', JSON.stringify(resC));
    r6 = rowAt(await rowsOf(db, fx.dev), 6);
    assert.equal(r6.name, 'Mutfak Tezgah');
    assert.equal(r6.room, 'Mutfak');
    const base2 = parseBase((await baseOf(db, fx.dev)).reported_layout);
    assert.equal(base2.relays[5].name, 'Mutfak Tezgah');

    // d) pano fabrika adina dondu, bulut hala eski pano adini gosteriyor -> sablon adi
    const resD = await sync(svc, fx, layoutOf({}));
    assert.equal(resD.status, 'applied', JSON.stringify(resD));
    r6 = rowAt(await rowsOf(db, fx.dev), 6);
    assert.equal(r6.name, 'Mutfak Aydınlatma');
  });
});

test('8) yaris: kilitsiz okumadan SONRA, transaction\'dan ONCE kullanici adi degistirir -> karar kilitli veriye gore (kullanici adi ezilmez)', { skip: SKIP }, async () => {
  const order = [];
  const hooks = {
    onQuery: (text) => {
      if (/FROM endpoints e WHERE e\.device_id/.test(text) && !/FOR UPDATE/.test(text)) order.push('rows');
    },
    onTx: () => order.push('tx'),
    beforeTx: null,
  };
  await withFixture({ hooks }, async (db, fx) => {
    const svc = makeSync(db);
    // Kilitsiz plan: bulut sablon adinda -> 'Mutfak Spot' yazilacak. Araya kullanici 'Tezgah' girer.
    hooks.beforeTx = async () => {
      order.push('hook');
      await getPool().query('UPDATE endpoints SET name = $2 WHERE device_id = $1 AND channel_index = 6', [fx.dev.id, 'Tezgah']);
    };
    const res = await sync(svc, fx, layoutOf({ set: { 6: { name: 'Mutfak Spot' } } }));
    assert.equal(res.status, 'applied', JSON.stringify(res));
    assert.deepEqual(order, ['rows', 'hook', 'tx'], 'kanca kilitsiz okuma ile transaction arasina girdi');
    const r6 = rowAt(await rowsOf(db, fx.dev), 6);
    assert.equal(r6.name, 'Tezgah', 'kilitsiz plan (Mutfak Spot) uygulanmadi; kilitli veriyle yeniden karar verildi');
    assert.equal(res.summary.renamed, 0);
    const base = parseBase((await baseOf(db, fx.dev)).reported_layout);
    assert.equal(base.relays[5].name, 'Mutfak Spot', 'taban yine yazildi');
  });
});

// ==============================================================================
// 9-10: yetki siniri ve kisitlar
// ==============================================================================
test('9) cihaz baska eve tasinmis (home_id farkli) -> HICBIR sey yazilmaz', { skip: SKIP }, async () => {
  await withFixture({}, async (db, fx) => {
    const home2 = await fx.addHome();
    await db.query('UPDATE devices SET home_id = $2 WHERE id = $1', [fx.dev.id, home2]);
    const before = await rowsOf(db, fx.dev);
    const svc = makeSync(db);
    const res = await sync(svc, fx, layoutOf({ set: SHUTTER_56 }));
    assert.equal(res.status, 'skipped');
    assert.equal(res.reason, 'home_mismatch');
    assert.deepEqual(await rowsOf(db, fx.dev), before);
    assert.equal((await baseOf(db, fx.dev)).reported_layout, null);
    assert.equal((await auditsOf(db, fx.dev)).length, 0);
    assert.equal(svc.stats().skipped, 1);
  });
});

test('10) 40 role (20 panjur cifti) bildirimi CHECK/UNIQUE ihlali olmadan uygulanir', { skip: SKIP }, async () => {
  await withFixture({}, async (db, fx) => {
    const svc = makeSync(db);
    const res = await sync(svc, fx, layoutOf({ count: 40, set: allShutters(40) }));
    assert.equal(res.status, 'applied', JSON.stringify(res));
    assert.equal(res.summary.inserted, 32);
    assert.equal(res.summary.retyped, 4, 'kanal 5-8 lamba -> panjur');
    const rows = await rowsOf(db, fx.dev);
    assert.equal(rows.length, 40);
    for (const r of rows) {
      assert.equal(r.type, 'shutter');
      assert.equal(r.shutter_pair_index, Math.ceil(r.channel_index / 2));
      assert.equal(r.shutter_duration_sec, DEFAULT_SHUTTER_SEC);
    }
    assert.equal(rowAt(rows, 1).name, 'Salon Panjur Yukarı', 'tohum adi korunur (pano adi fabrika adi)');
    assert.equal(rowAt(rows, 5).name, 'Panjur 3 Yukarı', 'sinif degisti, pano adi fabrika adi -> tarafsiz ad');
    assert.equal(rowAt(rows, 9).name, 'Panjur 5 Yukarı');
    assert.equal(rowAt(rows, 9).room, 'Genel');
    assert.equal(rowAt(rows, 40).name, 'Panjur 20 Aşağı');
    // idempotent: ayni bildirim -> noop
    const again = await sync(svc, fx, layoutOf({ count: 40, set: allShutters(40) }));
    assert.equal(again.status, 'noop', JSON.stringify(again));
  });
});

// ==============================================================================
// 11: kopru uctan uca (gercek state yolu + gercek servis)
// ==============================================================================
test('11) kopru uctan uca: canli state satirlari esitler; RETAINED state esitlemez', { skip: SKIP }, async () => {
  await withFixture({}, async (db, fx) => {
    const bridge = new MqttBridge({ db, logger: silent, env: {}, layoutSync: true });
    try {
      const payload = (o) => Buffer.from(JSON.stringify({ ...fwState(o), uid: fx.dev.device_uuid }));
      const topic = `ev/${fx.topic}/state`;

      await bridge.handleIncomingMessage(topic, payload({ set: SHUTTER_56 }), { retain: true });
      if (bridge._layoutSync) await bridge._layoutSync.whenIdle();
      let rows = await rowsOf(db, fx.dev);
      assert.equal(rowAt(rows, 5).type, 'light', 'retained state satir degistirmez');
      assert.equal((await baseOf(db, fx.dev)).reported_layout, null);

      await bridge.handleIncomingMessage(topic, payload({ set: SHUTTER_56 }), { retain: false });
      assert.ok(bridge._layoutSync, 'canli state servisi olusturdu');
      await bridge._layoutSync.whenIdle();
      rows = await rowsOf(db, fx.dev);
      assert.equal(rowAt(rows, 5).type, 'shutter');
      assert.equal(rowAt(rows, 6).type, 'shutter');
      assert.equal(rowAt(rows, 5).shutter_pair_index, 3);
      assert.equal(rowAt(rows, 5).name, 'Salon (Yukari)');
      assert.ok((await baseOf(db, fx.dev)).reported_layout);
      const dev = (await db.query('SELECT is_online FROM devices WHERE id = $1', [fx.dev.id])).rows[0];
      assert.equal(dev.is_online, true, 'ana state yolu da calisti');
      const st = bridge.getStatus();
      assert.equal(st.layout_sync.applied, 1);
      assert.equal(st.layout_sync.errors, 0);
      assert.equal(st.counters.dbErrors, 0);
    } finally {
      await bridge.end({ force: true, timeoutMs: 50 });
    }
  });
});

// ==============================================================================
// 12-15: denetim kaydi gizliligi, taban bicimi, zaman damgasi, uretim tohumu
// ==============================================================================
test('12) denetim kaydi ayrintisinda pano adi GECMEZ (yalniz sayilar ve kural kimlikleri)', { skip: SKIP }, async () => {
  await withFixture({}, async (db, fx) => {
    const svc = makeSync(db);
    const set = { 5: { type: 'shutter_up', name: 'Zumrut Spot Q7 (Yukari)' }, 6: { type: 'shutter_down', name: 'Zumrut Spot Q7 (Asagi)' } };
    const res = await sync(svc, fx, layoutOf({ set }));
    assert.equal(res.status, 'applied', JSON.stringify(res));
    assert.equal(rowAt(await rowsOf(db, fx.dev), 5).name, 'Zumrut Spot Q7 (Yukari)');
    const audits = await auditsOf(db, fx.dev);
    assert.equal(audits.length, 1);
    assert.equal(audits[0].details_text.includes('Zumrut'), false, 'ad denetim kaydina girmez');
    assert.equal(audits[0].details_text.includes(fx.topic), false, 'konu kimligi girmez');
    assert.deepEqual(Object.keys(audits[0].details).sort(), ['deleted', 'inserted', 'relays', 'renamed', 'reroomed', 'retyped', 'rules_disabled']);
    for (const k of ['deleted', 'inserted', 'relays', 'renamed', 'reroomed', 'retyped']) assert.equal(typeof audits[0].details[k], 'number');
  });
});

test('13) devices.reported_layout parseBase\'ten gecer ve bildirimle (id/tip/ad) ALAN BAZINDA ayni', { skip: SKIP }, async () => {
  await withFixture({}, async (db, fx) => {
    const svc = makeSync(db);
    const layout = layoutOf({ count: 10, set: { ...SHUTTER_56, 7: { type: 'impulse', name: 'Kapı Kilidi' } } });
    assert.equal((await sync(svc, fx, layout)).status, 'applied');
    const raw = (await baseOf(db, fx.dev)).reported_layout;
    const parsed = parseBase(raw);
    assert.ok(parsed, 'JSONB taban parseBase ile okunur');
    assert.deepEqual(parsed, serializeBase(layout)); // JSONB anahtar sirasi korunmaz: alan bazinda karsilastirma
    assert.equal(parsed.relays.length, 10);
    assert.equal(parsed.relays[6].type, 'impulse');
    assert.equal(parsed.relays[6].name, 'Kapı Kilidi');
    assert.equal(rowAt(await rowsOf(db, fx.dev), 7).type, 'impulse');
  });
});

test('14) varsayilan tohum + varsayilan pano -> endpoints.updated_at DEGISMEZ (taban yazilsa da satirlara dokunulmaz)', { skip: SKIP }, async () => {
  await withFixture({}, async (db, fx) => {
    const before = await rowsOf(db, fx.dev);
    await new Promise((r) => setTimeout(r, 15));
    const svc = makeSync(db);
    const res = await sync(svc, fx, layoutOf({}));
    assert.equal(res.status, 'applied', JSON.stringify(res));
    const after = await rowsOf(db, fx.dev);
    assert.deepEqual(after.map((r) => r.updated_at), before.map((r) => r.updated_at));
    assert.deepEqual(after, before);
    assert.ok((await baseOf(db, fx.dev)).reported_layout);
    // ikinci kez: taban ayni -> transaction bile acilmaz
    const again = await sync(svc, fx, layoutOf({}));
    assert.equal(again.status, 'noop');
    assert.equal(again.summary.baseSaved, false);
  });
});

test('15) uretim tohum SQL\'i (device_service SEED_ENDPOINTS_SQL) ile seedDefaults(1..16) gercek PG\'de BIREBIR ayni', { skip: SKIP }, async () => {
  const src = fs.readFileSync(DEVICE_SERVICE_PATH, 'utf8');
  const m = src.match(/const SEED_ENDPOINTS_SQL = `([\s\S]*?)`;/);
  assert.ok(m, 'SEED_ENDPOINTS_SQL kaynaktan ayiklanamadi');
  const seedSql = m[1];
  await withFixture({ seed: 0 }, async (db, fx) => {
    const r = await db.query(seedSql, [fx.homeId, fx.dev.id, 16]);
    assert.equal(r.rowCount, 16);
    const rows = await rowsOf(db, fx.dev);
    assert.equal(rows.length, 16);
    for (let c = 1; c <= 16; c += 1) {
      const row = rowAt(rows, c);
      const s = seedDefaults(c);
      assert.deepEqual(
        { name: row.name, type: row.type, room: row.room, pair: row.shutter_pair_index, durationSec: row.shutter_duration_sec },
        { name: s.name, type: s.type, room: s.room, pair: s.pair, durationSec: s.durationSec },
        `kanal ${c}`
      );
    }
    // uretim tohumu + varsayilan pano: esitleme satirlara dokunmaz (iki sablon tutarli)
    const svc = makeSync(db);
    const res = await sync(svc, fx, layoutOf({ count: 16 }));
    assert.equal(res.status, 'applied', JSON.stringify(res));
    assert.equal(res.summary.inserted + res.summary.retyped + res.summary.renamed + res.summary.reroomed + res.summary.deleted, 0);
    assert.equal((await auditsOf(db, fx.dev)).length, 0);
  });
});

// ==============================================================================
// 16-17: eszamanlilik
// ==============================================================================
test('16) iki es zamanli syncNow (ayni cihaz, iki ayri servis ornegi) -> kilitlenme yok, tam BIR uygulama, sonuc tutarli', { skip: SKIP }, async () => {
  await withFixture({}, async (db, fx) => {
    const a = makeSync(db);
    const b = makeSync(db);
    const layout = layoutOf({ set: SHUTTER_56 });
    const [ra, rb] = await Promise.all([sync(a, fx, layout), sync(b, fx, layout)]);
    assert.notEqual(ra.status, 'error', JSON.stringify(ra));
    assert.notEqual(rb.status, 'error', JSON.stringify(rb));
    assert.deepEqual([ra.status, rb.status].sort(), ['applied', 'noop']);
    const rows = await rowsOf(db, fx.dev);
    assert.equal(rows.length, 8);
    assert.equal(rowAt(rows, 5).type, 'shutter');
    assert.equal(rowAt(rows, 6).type, 'shutter');
    assert.equal((await auditsOf(db, fx.dev)).length, 1, 'tek denetim kaydi');
    assert.equal(a.stats().errors + b.stats().errors, 0);

    // ayni ornekte es zamanli iki cagri (ev kuyrugu siralar): yine hatasiz ve tutarli
    const layout2 = layoutOf({ set: { ...SHUTTER_56, ...LIGHT_12 } });
    const [r1, r2] = await Promise.all([sync(a, fx, layout2), sync(a, fx, layout2)]);
    assert.deepEqual([r1.status, r2.status].sort(), ['applied', 'noop']);
    assert.equal(rowAt(await rowsOf(db, fx.dev), 1).type, 'light');
  });
});

test('17a) kullanici PUT\'u ile yaris (kilit tutan transaction): pano tarafi degismeyen kanalda KULLANICI adi korunur, degisen kanal yazilir', { skip: SKIP }, async () => {
  await withFixture({}, async (db, fx) => {
    const svc = makeSync(db);
    // taban: kanal 6 pano adi 'Mutfak Spot'
    assert.equal((await sync(svc, fx, layoutOf({ set: { 6: { name: 'Mutfak Spot' } } }))).status, 'applied');

    const user = await getPool().connect();
    try {
      await user.query('BEGIN');
      await user.query('UPDATE endpoints SET name = $2 WHERE device_id = $1 AND channel_index = 6', [fx.dev.id, 'Tezgah']);
      // pano kanal 5'e ad verdi (yazilacak bir sey var -> transaction + FOR UPDATE kanal 6'da bekler)
      let settled = false;
      const p = sync(svc, fx, layoutOf({ set: { 5: { name: 'Salon Spot' }, 6: { name: 'Mutfak Spot' } } })).then((r) => {
        settled = true;
        return r;
      });
      await new Promise((r) => setTimeout(r, 200));
      assert.equal(settled, false, 'esitleme kullanicinin kilidini bekliyor');
      await user.query('COMMIT');
      const res = await p;
      assert.equal(res.status, 'applied', JSON.stringify(res));
    } finally {
      await user.query('ROLLBACK').catch(() => {});
      user.release();
    }
    const rows = await rowsOf(db, fx.dev);
    assert.equal(rowAt(rows, 5).name, 'Salon Spot');
    assert.equal(rowAt(rows, 6).name, 'Tezgah', 'belge 5.3: pano tarafinda degisiklik yok -> kullanici adi korunur');
    assert.equal(svc.stats().errors, 0);
  });
});

test('17b) kullanici PUT\'u ile yaris: panoda da ad degistiyse PANO adi kazanir (son yazan)', { skip: SKIP }, async () => {
  await withFixture({}, async (db, fx) => {
    const svc = makeSync(db);
    assert.equal((await sync(svc, fx, layoutOf({ set: { 6: { name: 'Mutfak Spot' } } }))).status, 'applied');

    const user = await getPool().connect();
    try {
      await user.query('BEGIN');
      await user.query('UPDATE endpoints SET name = $2 WHERE device_id = $1 AND channel_index = 6', [fx.dev.id, 'Tezgah']);
      const p = sync(svc, fx, layoutOf({ set: { 6: { name: 'Mutfak Tezgah' } } }));
      await new Promise((r) => setTimeout(r, 200));
      await user.query('COMMIT');
      const res = await p;
      assert.equal(res.status, 'applied', JSON.stringify(res));
    } finally {
      await user.query('ROLLBACK').catch(() => {});
      user.release();
    }
    const r6 = rowAt(await rowsOf(db, fx.dev), 6);
    assert.equal(r6.name, 'Mutfak Tezgah', 'belge 5.3: panoda ad degisti -> pano adi kazanir');
    assert.equal(svc.stats().errors, 0);
  });
});

// ==============================================================================
// 18-19: D1 gecici (fabrika) pano korumasi - pano degisimi benzetimi
// ==============================================================================
const devFlags = async (db, dev) =>
  (await db.query('SELECT is_commissioned, reported_layout FROM devices WHERE id = $1', [dev.id])).rows[0];
const userView = (rows) =>
  rows.map((r) => [r.id, r.channel_index, r.name, r.type, r.room, r.shutter_pair_index, r.shutter_duration_sec]);

/**
 * Pano degisimi benzetimi: eski cihazin (devs[0]) 16 satiri kullanici verisiyle ozellestirilir, kurallar eklenir;
 * replaceBoard gibi eski cihaz evden cikar (home_id NULL) ve satirlar `UPDATE endpoints SET device_id` ile YENI cihaz
 * satirina (devs[1]: taban NULL, is_commissioned FALSE) tasinir.
 */
async function replaceBoardFixture(db, fx) {
  const [oldDev, newDev] = fx.devices;
  const q = 'UPDATE endpoints SET name = $3, type = $4, room = $5, shutter_pair_index = $6, shutter_duration_sec = $7 ' +
    'WHERE device_id = $1 AND channel_index = $2';
  await db.query(q, [oldDev.id, 5, 'Mutfak Stor Yukarı', 'shutter', 'Mutfak', 3, 35]);
  await db.query(q, [oldDev.id, 6, 'Mutfak Stor Aşağı', 'shutter', 'Mutfak', 3, 35]);
  await db.query(q, [oldDev.id, 9, 'Bahçe Sulama', 'light', 'Bahçe', null, null]);
  await db.query(q, [oldDev.id, 12, 'Havuz Işığı', 'light', 'Bahçe', null, null]);
  const pair3 = await fx.addRule({ channelType: 'shutter', channel: 3, action: 'close' });
  const relay9 = await fx.addRule({ channelType: 'relay', channel: 9, action: 'on' });
  const relay12 = await fx.addRule({ deviceId: newDev.id, channelType: 'relay', channel: 12, action: 'off' });
  // replaceBoard: eski cihaz evden cikar, satirlar yeni cihaza tasinir
  await db.query('UPDATE devices SET home_id = NULL, is_claimed = FALSE WHERE id = $1', [oldDev.id]);
  const moved = await db.query('UPDATE endpoints SET device_id = $2 WHERE device_id = $1', [oldDev.id, newDev.id]);
  assert.equal(moved.rowCount, 16);
  const flags = await devFlags(db, newDev);
  assert.equal(flags.reported_layout, null, 'on kosul: yeni cihaz satirinda taban bos');
  assert.notEqual(flags.is_commissioned, true, 'on kosul: yeni cihaz devreye alinmamis');
  return { newDev, rules: { pair3, relay9, relay12 } };
}

test('18) D1 pano degisimi + FABRIKA ayarli yeni pano: hicbir kullanici verisi kaybolmaz, kurallar acik, 9-16 durur; eski yerlesim bildirilince her sey yerinde ve taban yazilir', { skip: SKIP }, async () => {
  await withFixture({ devices: 2, seed: 16 }, async (db, fx) => {
    const { newDev, rules } = await replaceBoardFixture(db, fx);
    const before = userView(await rowsOf(db, newDev));
    let clock = Date.now();
    const svc = makeSync(db, { now: () => clock });
    const syncNew = (layout) => svc.syncNow({ homeId: fx.homeId, deviceId: newDev.id, layout });
    const allRulesOn = async () => {
      for (const id of Object.values(rules)) assert.equal(await ruleEnabled(db, id), true, `kural ${id} acik kalmali`);
    };

    // yeni pano fabrika ayarinda baglandi; kuculme onay suresi gecse de (3 bildirim) hicbir sey silinmez
    for (const step of [0, SHRINK_CONFIRM_MS, SHRINK_CONFIRM_MS]) {
      clock += step;
      const res = await syncNew(layoutOf({}));
      assert.equal(res.status, 'noop', JSON.stringify(res));
      assert.equal(res.summary.deferred, 10, '5-6 panjurdan roleye (2) + 9-16 silme (8) ertelendi');
      assert.equal(res.summary.pendingShrink, false);
      assert.deepEqual(userView(await rowsOf(db, newDev)), before, 'ad/oda/sure/ek modul satirlari ve kimlikler aynen');
      assert.equal((await devFlags(db, newDev)).reported_layout, null, 'taban yazilmaz');
      await allRulesOn();
    }
    assert.equal(svc.stats().deferred, 3);
    assert.equal(svc.stats().errors, 0);
    assert.equal((await auditsOf(db, newDev)).length, 0);

    // servis sorumlusu yeni panoyu ESKI yerlesimle yapilandirdi
    clock += 5000;
    const back = await syncNew(layoutOf({ count: 16, set: { 5: { type: 'shutter_up' }, 6: { type: 'shutter_down' } } }));
    assert.equal(back.status, 'applied', JSON.stringify(back));
    assert.equal(back.summary.deferred, undefined);
    assert.deepEqual(userView(await rowsOf(db, newDev)), before, 'her sey yerinde');
    const r5 = rowAt(await rowsOf(db, newDev), 5);
    assert.deepEqual([r5.name, r5.room, r5.shutter_duration_sec], ['Mutfak Stor Yukarı', 'Mutfak', 35]);
    const base = parseBase((await devFlags(db, newDev)).reported_layout);
    assert.ok(base, 'taban artik yazildi');
    assert.equal(base.relays.length, 16);
    await allRulesOn();
    assert.equal((await auditsOf(db, newDev)).length, 0, 'satir degismedi: denetim kaydi yok');
  });
});

test('19) D1 ayri senaryo: yeni cihaz DEVREYE ALINDIKTAN sonra fabrika bildirimi normal kurallarla uygulanir', { skip: SKIP }, async () => {
  await withFixture({ devices: 2, seed: 16 }, async (db, fx) => {
    const { newDev, rules } = await replaceBoardFixture(db, fx);
    await db.query('UPDATE devices SET is_commissioned = TRUE WHERE id = $1', [newDev.id]);
    const svc = makeSync(db);
    const res = await svc.syncNow({ homeId: fx.homeId, deviceId: newDev.id, layout: layoutOf({}) });
    assert.equal(res.status, 'applied', JSON.stringify(res));
    assert.equal(res.summary.deferred, undefined);
    assert.equal(res.summary.pendingShrink, true, 'normal kural: kuculme ilk kez goruldu');
    const rows = await rowsOf(db, newDev);
    assert.equal(rowAt(rows, 5).type, 'light');
    assert.equal(rowAt(rows, 5).shutter_duration_sec, null);
    assert.equal(await ruleEnabled(db, rules.pair3), false, 'panjurdan roleye donen cift 3 kurali kapanir');
    assert.ok((await devFlags(db, newDev)).reported_layout, 'taban yazilir');
  });
});

// ==============================================================================
// 20: D2 lamba -> darbe kural kapatma; 21: D9 tek vekilli ad
// ==============================================================================
test('20) D2 light -> impulse: o kanalin ROLE kurali kapanir; baska kanal ve light <-> plug etkilenmez', { skip: SKIP }, async () => {
  await withFixture({}, async (db, fx) => {
    await db.query("UPDATE endpoints SET type = 'plug' WHERE device_id = $1 AND channel_index = 8", [fx.dev.id]);
    const relay7 = await fx.addRule({ channelType: 'relay', channel: 7, action: 'on' });
    const relay6 = await fx.addRule({ channelType: 'relay', channel: 6, action: 'on' });
    const relay8 = await fx.addRule({ channelType: 'relay', channel: 8, action: 'on' });
    const svc = makeSync(db);
    const res = await sync(svc, fx, layoutOf({ set: { 7: { type: 'impulse', name: 'Garaj Kapısı' } } }));
    assert.equal(res.status, 'applied', JSON.stringify(res));
    assert.equal(rowAt(await rowsOf(db, fx.dev), 7).type, 'impulse');
    assert.equal(rowAt(await rowsOf(db, fx.dev), 8).type, 'plug', 'priz korunur');
    assert.equal(await ruleEnabled(db, relay7), false, '"lambayi ac" kurali kapi darbesini tetiklemesin');
    assert.equal(await ruleEnabled(db, relay6), true);
    assert.equal(await ruleEnabled(db, relay8), true, 'light <-> plug kozmetik');
    assert.deepEqual((await auditsOf(db, fx.dev))[0].details.rules_disabled, [relay7]);

    // ters yon: impulse -> light da kapatir
    await db.query('UPDATE scheduled_rules SET enabled = TRUE WHERE id = $1', [relay7]);
    const res2 = await sync(svc, fx, layoutOf({ set: { 7: { name: 'Garaj Kapısı' } } }));
    assert.equal(res2.status, 'applied', JSON.stringify(res2));
    assert.equal(rowAt(await rowsOf(db, fx.dev), 7).type, 'light');
    assert.equal(await ruleEnabled(db, relay7), false);
  });
});

test('21) D9 tek (eslesmemis) vekil iceren pano adi: saveBase 22P02 vermeden yazilir, ad iyi bicimli', { skip: SKIP }, async () => {
  await withFixture({}, async (db, fx) => {
    const svc = makeSync(db);
    const bad = 'Mutfak ' + String.fromCharCode(0xd800) + ' Spot';
    assert.equal(bad.isWellFormed(), false, 'on kosul');
    const res = await sync(svc, fx, layoutOf({ set: { 6: { name: bad } } }));
    assert.equal(res.status, 'applied', JSON.stringify(res));
    assert.equal(svc.stats().errors, 0);
    const r6 = rowAt(await rowsOf(db, fx.dev), 6);
    assert.equal(r6.name, 'Mutfak Spot');
    assert.equal(r6.name.isWellFormed(), true);
    const base = parseBase((await baseOf(db, fx.dev)).reported_layout);
    assert.equal(base.relays[5].name, 'Mutfak Spot');
  });
});

// ==============================================================================
// 22: D14 cok panolu evde device_id NULL kural
// ==============================================================================
test('22) D14 device_id NULL kural yalniz evde TEK cihaz varsa kapatilir; iki panolu evde kalir, bu cihaza bagli kural kapanir', { skip: SKIP }, async () => {
  await withFixture({ devices: 2 }, async (db, fx) => {
    const other = fx.devices[1];
    const nullRelay5 = await fx.addRule({ channelType: 'relay', channel: 5, action: 'on' });
    const ownRelay5 = await fx.addRule({ deviceId: fx.dev.id, channelType: 'relay', channel: 5, action: 'off' });
    const nullShutter1 = await fx.addRule({ channelType: 'shutter', channel: 1, action: 'open' });
    const svc = makeSync(db);
    const res = await sync(svc, fx, layoutOf({ set: SHUTTER_56 }));
    assert.equal(res.status, 'applied', JSON.stringify(res));
    assert.equal(await ruleEnabled(db, nullRelay5), true, 'iki panolu ev: NULL kural baska panoya ait olabilir');
    assert.equal(await ruleEnabled(db, ownRelay5), false);
    assert.deepEqual((await auditsOf(db, fx.dev))[0].details.rules_disabled, [ownRelay5]);

    // ikinci pano evden cikti: artik tek cihaz -> NULL kural bu panonundur ve kapatilir
    await db.query('UPDATE devices SET home_id = NULL WHERE id = $1', [other.id]);
    const res2 = await sync(svc, fx, layoutOf({ set: { ...SHUTTER_56, ...LIGHT_12 } }));
    assert.equal(res2.status, 'applied', JSON.stringify(res2));
    assert.equal(await ruleEnabled(db, nullShutter1), false, 'tek cihazli ev: NULL panjur kurali kapanir');
    assert.equal(await ruleEnabled(db, nullRelay5), true, 'kanal 5 bu calismada sinif degistirmedi');
  });
});
