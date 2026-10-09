'use strict';

// WP-L duzeltmeleri (KARARLAR D5, D6, D13; D15 akis testleri) - GERCEK PostgreSQL.
//
// Varsayilan olarak ATLANIR. Etkinlestirmek icin migration'lanmis (001..031) bir veritabani verin:
//   EV_PG_TEST_URL=postgresql://kullanici@127.0.0.1:5432/<db> node --test test/devices/layout_flows_pg.test.js
//
// Her test KENDI satirlarini (rastgele etiketli: cihaz AHBU-LF<ETIKET>-n, ev adi LFPG-<ETIKET>-n, e-posta
// *-<etiket>@lf-pg.invalid) olusturur ve sonunda yalniz bunlari siler. Uretim veritabanina karsi CALISTIRMAYIN.
//   D5  - acil sifirlama (REASSIGNED / UNCLAIMED), pano degisimi ve sahiplenme upsert'unun ON CONFLICT dali tabani NULL'lar.
//   D6  - REASSIGNED sonrasi gercek kopru + gercek esitleme: ayni imzali canli state RECHECK beklenmeden esitlenir.
//   D13 - iki panolu evde esitleme(B) ile acil sifirlama(A) ayni anda: kilitlenme (40P01) YOK, ikisi de biter.

const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');

const URL_ = process.env.EV_PG_TEST_URL;
const SKIP = URL_ ? false : 'EV_PG_TEST_URL tanimli degil (gercek PostgreSQL gerekir)';

const TAG = crypto.randomBytes(3).toString('hex').toUpperCase();
const ETAG = TAG.toLowerCase();
const REASON = 'Kiraci ulasilamiyor, daire teslim alindi';
const STALE = JSON.stringify({ v: 1, relays: [{ id: 1, type: 'light', name: 'Eski Dairenin Adi' }] });

let ctxPromise = null;
let seq = 0;

function getCtx() {
  if (ctxPromise) return ctxPromise;
  ctxPromise = (async () => {
    process.env.LOCAL_KEY_SECRET = crypto.randomBytes(32).toString('hex');
    process.env.PIN_PEPPER = crypto.randomBytes(32).toString('hex');
    process.env.MQTT_PUBLIC_HOST = 'broker.test.invalid';
    process.env.MQTT_PUBLIC_PORT = '8884';
    for (const k of ['EMQX_API_URL', 'EMQX_API_KEY', 'EMQX_API_SECRET', 'ALLOW_DEBUG_OTP']) delete process.env[k];

    const { Pool } = require('pg');
    const pool = new Pool({ connectionString: URL_, max: 12, connectionTimeoutMillis: 15000 });
    pool.on('error', () => {});
    const db = {
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
    const pin = require('../../src/utils/pin');
    const { DeviceService } = require('../../src/services/device_service');
    const { MqttCredentialService } = require('../../src/services/mqtt_credential_service');
    const silent = { warn() {}, error() {}, log() {} };
    const credentials = new MqttCredentialService({ db, logger: silent });
    const fakeBridge = {
      isConnected: () => true,
      async publishCommand() { return {}; },
      async publishSys() { return {}; },
      async publishToTopic() { return {}; },
      async clearRetained() {},
    };
    const makeService = (mqttBridge = fakeBridge) => new DeviceService({
      db,
      mqttBridge,
      mqttCredentials: credentials,
      mailer: { async sendClaimOtpEmail() { return { sent: true }; } },
      inviteCustomer: async () => ({ sent: true }),
    });
    const q = (text, params) => db.query(text, params);
    const one = async (text, params) => (await q(text, params)).rows[0];
    const helpers = {
      async user({ role = 'user' } = {}) {
        const n = ++seq;
        return one(
          `INSERT INTO users (email, password_hash, full_name, role) VALUES ($1, 'x', 'Test Kullanici', $2) RETURNING id, email, role`,
          [`u${n}-${ETAG}@lf-pg.invalid`, role]
        );
      },
      async inventory({ pinPlain = '135790', status = 'IN_STOCK' } = {}) {
        const n = ++seq;
        const r = await one(
          `INSERT INTO device_inventory (device_uuid, mac_address, pin_hash, model, status)
           VALUES ($1, $2, $3, 'ESP32-S3-POE-ETH-8DI-8RO', $4) RETURNING id, device_uuid, mac_address`,
          [`AHBU-LF${TAG}-${n}`, `LF:${TAG}:${n}`, pin.hashPin(pinPlain), status]
        );
        return { ...r, pin: pinPlain };
      },
      act: (u, extra = {}) => ({ userId: u.id, globalRole: u.role, ip: '127.0.0.1', ...extra }),
    };
    return { pool, db, q, one, pin, credentials, makeService, svc: makeService(), helpers, silent };
  })();
  return ctxPromise;
}

/** Sahip + sahiplenmis cihaz (claim: ev, 8 tohum kanal, cihaz kimligi). */
async function makeHome(c) {
  const owner = await c.helpers.user();
  const inv = await c.helpers.inventory();
  const r = await c.svc.claimDevice({ actor: c.helpers.act(owner), deviceUuid: inv.device_uuid, setupPin: inv.pin, homeName: `LFPG-${TAG}-${++seq}` });
  const dev = await c.one('SELECT id, device_uuid FROM devices WHERE device_uuid = $1', [inv.device_uuid]);
  const home = await c.one('SELECT id, mqtt_username FROM homes WHERE id = $1', [r.home_id]);
  return { owner, inv, dev, home };
}

const layoutRow = async (c, deviceId) => c.one('SELECT reported_layout, reported_layout_at FROM devices WHERE id = $1', [deviceId]);
const types = async (c, deviceId) =>
  (await c.q('SELECT channel_index AS ch, type FROM endpoints WHERE device_id = $1 ORDER BY channel_index', [deviceId])).rows
    .map((r) => `${r.ch}:${r.type}`)
    .join(' ');

test.after(async () => {
  if (!ctxPromise) return;
  const c = await ctxPromise;
  const like = `AHBU-LF${TAG}-%`;
  try {
    const homes = (await c.q('SELECT id FROM homes WHERE name LIKE $1', [`LFPG-${TAG}-%`])).rows.map((r) => r.id);
    if (homes.length > 0) {
      await c.q('DELETE FROM device_audit_logs WHERE home_id = ANY ($1::uuid[])', [homes]);
      await c.q('DELETE FROM emergency_reset_logs WHERE home_id = ANY ($1::uuid[])', [homes]);
      await c.q('DELETE FROM device_replacement_logs WHERE home_id = ANY ($1::uuid[])', [homes]);
      await c.q('DELETE FROM homes WHERE id = ANY ($1::uuid[])', [homes]);
    }
    await c.q('DELETE FROM device_audit_logs WHERE device_uuid LIKE $1', [like]);
    await c.q('DELETE FROM emergency_reset_logs WHERE device_uuid LIKE $1', [like]);
    await c.q('DELETE FROM device_replacement_logs WHERE old_device_uuid LIKE $1 OR new_device_uuid LIKE $1', [like]);
    await c.q('DELETE FROM devices WHERE device_uuid LIKE $1', [like]);
    await c.q('DELETE FROM device_inventory WHERE device_uuid LIKE $1', [like]);
    await c.q('DELETE FROM users WHERE email LIKE $1', [`%-${ETAG}@lf-pg.invalid`]);
  } catch (err) {
    console.error('[layout_flows_pg] temizlik hatasi (etiketli satirlar kalmis olabilir):', err.message);
  } finally {
    await c.pool.end().catch(() => {});
  }
});

// ------------------------------------------------------------------------------------------------
// D5 - taban sifirlama (gercek SQL)
// ------------------------------------------------------------------------------------------------
test('PG D5 acil sifirlama REASSIGNED ve UNCLAIMED: reported_layout ve reported_layout_at NULL olur', { skip: SKIP }, async () => {
  const c = await getCtx();
  const root = await c.helpers.user({ role: 'super_user' });
  for (const reassign of [true, false]) {
    const t = await makeHome(c);
    await c.q('UPDATE devices SET reported_layout = $2::jsonb, reported_layout_at = NOW() WHERE id = $1', [t.dev.id, STALE]);
    const newOwner = reassign ? await c.helpers.user() : null;
    const r = await c.svc.emergencyReset({
      actor: c.helpers.act(root), deviceUuid: t.dev.device_uuid, confirmUid: t.dev.device_uuid, reason: REASON,
      ...(newOwner ? { newOwnerIdentifier: newOwner.email } : {}),
    });
    assert.equal(r.action, reassign ? 'REASSIGNED' : 'UNCLAIMED');
    assert.deepEqual(await layoutRow(c, t.dev.id), { reported_layout: null, reported_layout_at: null }, r.action);
  }
});

test('PG D5 pano degisimi ve sahiplenme: onceden var olan cihaz satiri (ON CONFLICT dali) bayat tabanla kalmaz', { skip: SKIP }, async () => {
  const c = await getCtx();
  // pano degisimi: yeni panonun eski kullanimdan kalmis (sahipsiz) satiri
  const t = await makeHome(c);
  const newInv = await c.helpers.inventory();
  const stale = await c.one(
    `INSERT INTO devices (device_uuid, mac_address, is_claimed, reported_layout, reported_layout_at)
     VALUES ($1, $2, FALSE, $3::jsonb, NOW()) RETURNING id`,
    [newInv.device_uuid, newInv.mac_address, STALE]
  );
  const r = await c.svc.replaceBoard({
    actor: { userId: t.owner.id, globalRole: 'user', ip: '127.0.0.1', access: 'owner' },
    homeId: t.home.id, oldDeviceUuid: t.dev.device_uuid, newDeviceUuid: newInv.device_uuid, setupPin: newInv.pin, reason: 'Pano yandi',
  });
  assert.equal(r.new_device_uuid, newInv.device_uuid);
  const after = await c.one('SELECT id, home_id, reported_layout, reported_layout_at FROM devices WHERE device_uuid = $1', [newInv.device_uuid]);
  assert.equal(after.id, stale.id, 'ayni satir (ON CONFLICT)');
  assert.equal(after.home_id, t.home.id);
  assert.equal(after.reported_layout, null);
  assert.equal(after.reported_layout_at, null);

  // sahiplenme: stoga donmus cihazin satiri
  const owner = await c.helpers.user();
  const inv = await c.helpers.inventory();
  const old = await c.one(
    `INSERT INTO devices (device_uuid, mac_address, is_claimed, reported_layout, reported_layout_at)
     VALUES ($1, $2, FALSE, $3::jsonb, NOW()) RETURNING id`,
    [inv.device_uuid, inv.mac_address, STALE]
  );
  const cl = await c.svc.claimDevice({ actor: c.helpers.act(owner), deviceUuid: inv.device_uuid, setupPin: inv.pin, homeName: `LFPG-${TAG}-${++seq}` });
  const dev = await c.one('SELECT id, home_id, reported_layout, reported_layout_at FROM devices WHERE device_uuid = $1', [inv.device_uuid]);
  assert.equal(dev.id, old.id, 'ayni satir (ON CONFLICT)');
  assert.equal(dev.home_id, cl.home_id);
  assert.equal(dev.reported_layout, null);
  assert.equal(dev.reported_layout_at, null);
});

// ------------------------------------------------------------------------------------------------
// D6 - REASSIGNED sonrasi gercek kopru + gercek esitleme
// ------------------------------------------------------------------------------------------------
test('PG D6 REASSIGNED: satirlar tohuma doner; ayni imzali sonraki canli state RECHECK beklenmeden panoya esitlenir', { skip: SKIP }, async () => {
  const c = await getCtx();
  const { MqttBridge } = require('../../src/mqtt_bridge');
  const { makeFakeTimers, makeFakeClient, makeFakeMqttLib, flush } = require('../bridge/_helpers');
  const { fwState } = require('../layout/_helpers');
  const t = await makeHome(c);
  const root = await c.helpers.user({ role: 'super_user' });
  const newOwner = await c.helpers.user();

  let clock = Date.parse('2026-10-04T09:00:00Z');
  const client = makeFakeClient();
  const bridge = new MqttBridge({
    db: c.db, logger: c.silent, env: { MQTT_BACKEND_USER: 'u', MQTT_BACKEND_PASS: 'p' }, timers: makeFakeTimers(),
    mqttLib: makeFakeMqttLib(client), layoutSync: true, now: () => clock,
  });
  bridge.init();
  client.connected = true;
  client.emit('connect', { sessionPresent: false });
  await flush();
  const svc = c.makeService(bridge);
  const state = { ...fwState({ set: { 5: { type: 'shutter_up' }, 6: { type: 'shutter_down' }, 8: { type: 'impulse' } } }), uid: t.dev.device_uuid };
  const send = async () => {
    await bridge.handleIncomingMessage(`ev/${t.home.mqtt_username}/state`, Buffer.from(JSON.stringify(state)), { retain: false });
    assert.ok(bridge._layoutSync, 'esitleme servisi kuruldu');
    assert.equal(await bridge._layoutSync.whenIdle(5000), true);
  };
  const BOARD = '1:shutter 2:shutter 3:shutter 4:shutter 5:shutter 6:shutter 7:light 8:impulse';
  try {
    await send();
    assert.equal(await types(c, t.dev.id), BOARD, 'ilk canli state esitlendi');

    const r = await svc.emergencyReset({
      actor: c.helpers.act(root), deviceUuid: t.dev.device_uuid, confirmUid: t.dev.device_uuid, reason: REASON, newOwnerIdentifier: newOwner.email,
    });
    assert.equal(r.action, 'REASSIGNED');
    // Tohum (sahip karari 2026-10-09): sabit rol yok, 1-8 lamba.
    assert.equal(await types(c, t.dev.id), '1:light 2:light 3:light 4:light 5:light 6:light 7:light 8:light', 'satirlar tohuma dondu');

    clock += 30 * 1000; // hiz siniri gecti, RECHECK (5 dk) DOLMADI
    await send();
    assert.equal(await types(c, t.dev.id), BOARD, 'tohum sablonu RECHECK beklenmeden panoya esitlendi');
  } finally {
    await bridge.end({ force: true, timeoutMs: 50 });
  }
});

// ------------------------------------------------------------------------------------------------
// D13 - iki panolu evde esitleme(B) + acil sifirlama(A) es zamanli: kilitlenme yok
// ------------------------------------------------------------------------------------------------
test('PG D13 iki panolu ev: esitleme(B) satirlarini kilitliyken acil sifirlama(A) -> 40P01 YOK, ikisi de biter', { skip: SKIP }, async () => {
  const c = await getCtx();
  const { createEndpointLayoutSync } = require('../../src/services/endpoint_layout_sync');
  const { seedDefaults } = require('../../src/utils/endpoint_layout');
  const { KeyedWorkQueue } = require('../../src/mqtt_bridge');
  const { layoutOf } = require('../layout/_helpers');
  const t = await makeHome(c);
  const root = await c.helpers.user({ role: 'super_user' });
  const n = ++seq;
  const devB = await c.one(
    'INSERT INTO devices (home_id, device_uuid, mac_address, is_claimed) VALUES ($1, $2, $3, TRUE) RETURNING id, device_uuid',
    [t.home.id, `AHBU-LF${TAG}-${n}`, `LF:${TAG}:B${n}`]
  );
  for (let ch = 1; ch <= 8; ch += 1) {
    const s = seedDefaults(ch);
    await c.q(
      `INSERT INTO endpoints (home_id, device_id, channel_index, name, type, room, shutter_pair_index, shutter_duration_sec)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8)`,
      [t.home.id, devB.id, ch, s.name, s.type, s.room, s.pair, s.durationSec]
    );
  }
  await c.q(
    `INSERT INTO scheduled_rules (home_id, device_id, channel, channel_type, action, hour, minute, created_by, enabled)
     VALUES ($1, $2, 5, 'relay', 'on', 7, 0, $3, TRUE)`,
    [t.home.id, devB.id, t.owner.id]
  );

  // esitleme(B): satir kilidini (endpoints ... FOR UPDATE) aldiktan sonra kapida bekler
  let reached;
  const reachedP = new Promise((resolve) => { reached = resolve; });
  let open;
  const gateP = new Promise((resolve) => { open = resolve; });
  const hookedDb = {
    query: (text, params) => c.db.query(text, params),
    async withTransaction(fn) {
      const client = await c.pool.connect();
      let held = false;
      try {
        await client.query('BEGIN');
        const result = await fn({
          query: async (text, params) => {
            const res = await client.query(text, params);
            if (!held && /FROM endpoints[\s\S]*FOR UPDATE/.test(String(text))) {
              held = true;
              reached();
              await gateP;
            }
            return res;
          },
        });
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
  const sync = createEndpointLayoutSync({ db: hookedDb, logger: c.silent, QueueClass: KeyedWorkQueue });
  const t0 = Date.now();
  const pSync = sync.syncNow({ homeId: t.home.id, deviceId: devB.id, layout: layoutOf({ set: { 5: { type: 'shutter_up' }, 6: { type: 'shutter_down' } } }) });
  await reachedP;
  const pReset = c.svc
    .emergencyReset({ actor: c.helpers.act(root), deviceUuid: t.dev.device_uuid, confirmUid: t.dev.device_uuid, reason: REASON })
    .then((r) => ({ ok: r }), (err) => ({ err }));
  setTimeout(() => open(), 400); // sifirlama kilit beklerken esitleme devam etsin
  const [syncResult, resetResult] = await Promise.all([pSync, pReset]);
  const ms = Date.now() - t0;
  sync.stop();

  assert.ok(!resetResult.err, `sifirlama hatasi: ${resetResult.err && resetResult.err.code} ${resetResult.err && resetResult.err.message}`);
  assert.equal(resetResult.ok.action, 'UNCLAIMED');
  assert.notEqual(syncResult.status, 'error', `esitleme hatasi: ${JSON.stringify(syncResult)}`);
  assert.equal(syncResult.status, 'applied');
  assert.ok(ms < 5000, `sure ${ms} ms`);
  // sifirlama esitlemeden SONRA calisti: evin kurallari ve kanallari temizlendi
  assert.equal((await c.one('SELECT count(*)::int AS n FROM scheduled_rules WHERE home_id = $1', [t.home.id])).n, 0);
  await c.q('DELETE FROM endpoints WHERE device_id = $1', [devB.id]);
});
