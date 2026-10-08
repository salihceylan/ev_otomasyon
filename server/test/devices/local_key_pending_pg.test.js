'use strict';

// SERVIS-01 - GERCEK PostgreSQL: migration 032 (bekleyen yerel anahtar kolonlari + tetikleyici), uzlastiricinin CAS
// takas SQL'i, acil sifirlamanin bekleyen/telafi yollari ve etiket yeniden uretiminin bekleyeni temizlemesi.
//
// Varsayilan olarak ATLANIR (`npm test` PostgreSQL gerektirmez). Etkinlestirmek icin migration'lanmis (001..032) bir
// veritabani verin:
//   EV_PG_TEST_URL=postgresql://kullanici@127.0.0.1:5432/<db> node --test test/devices/local_key_pending_pg.test.js
// Her test KENDI satirlarini (rastgele etiketli) olusturur ve en sonda yalniz onlari siler. Uretim veritabanina KARSI
// CALISTIRMAYIN.

const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');

const URL_ = process.env.EV_PG_TEST_URL;
const SKIP = URL_ ? false : 'EV_PG_TEST_URL tanimli degil (gercek PostgreSQL gerekir)';

const TAG = crypto.randomBytes(3).toString('hex').toUpperCase();
const REASON = 'Kiraci ulasilamiyor, daire teslim alindi';
const PENDING_WARNING =
  'Yeni yerel anahtar şu an panoya iletilemedi (pano ya da bulut bağlantısı yok). Pano buluta bağlandığında otomatik ' +
  'iletilecek; o zamana kadar panonun mevcut anahtarı geçerli kalır.';

let ctxPromise = null;
let seq = 0;
const created = { users: [], homes: [], uuids: [] };

function getCtx() {
  if (ctxPromise) return ctxPromise;
  ctxPromise = (async () => {
    process.env.LOCAL_KEY_SECRET = crypto.randomBytes(32).toString('hex');
    process.env.PIN_PEPPER = crypto.randomBytes(32).toString('hex');
    process.env.MQTT_PUBLIC_HOST = 'broker.test.invalid';
    process.env.MQTT_PUBLIC_PORT = '8884';
    for (const k of ['EMQX_API_URL', 'EMQX_API_KEY', 'EMQX_API_SECRET']) delete process.env[k];
    process.env.DATABASE_URL = URL_; // inventory_service gercek src/db.js'i kullanir

    const { Pool } = require('pg');
    const pool = new Pool({ connectionString: URL_, max: 8, connectionTimeoutMillis: 15000 });
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
    const secretBox = require('../../src/utils/secret_box');
    const pin = require('../../src/utils/pin');
    const { DeviceService } = require('../../src/services/device_service');
    const { MqttCredentialService } = require('../../src/services/mqtt_credential_service');
    const silent = { warn() {}, error() {}, log() {} };
    const bridge = {
      connected: true,
      failSys: false,
      sys: [],
      rearmed: [],
      isConnected() { return this.connected; },
      async publishCommand() { return {}; },
      async publishSys(topicId, obj) {
        if (this.failSys) throw new Error('broker down');
        this.sys.push({ topicId, obj: JSON.parse(JSON.stringify(obj)) });
        return {};
      },
      async clearRetained() {},
      requestReconcile(topicId) { this.rearmed.push(topicId); },
    };
    const credentials = new MqttCredentialService({ db, logger: silent });
    const deviceService = new DeviceService({ db, mqttBridge: bridge, mqttCredentials: credentials });
    return { pool, db, secretBox, pin, bridge, deviceService };
  })();
  return ctxPromise;
}

test.after(async () => {
  if (SKIP || !ctxPromise) return;
  const c = await ctxPromise;
  try {
    if (created.uuids.length) {
      await c.pool.query('DELETE FROM device_audit_logs WHERE device_uuid = ANY ($1::text[])', [created.uuids]);
      await c.pool.query('DELETE FROM emergency_reset_logs WHERE device_uuid = ANY ($1::text[])', [created.uuids]);
    }
    if (created.homes.length) await c.pool.query('DELETE FROM homes WHERE id = ANY ($1::uuid[])', [created.homes]);
    if (created.uuids.length) {
      await c.pool.query('DELETE FROM endpoints WHERE device_id IN (SELECT id FROM devices WHERE device_uuid = ANY ($1::text[]))', [created.uuids]);
      await c.pool.query('DELETE FROM devices WHERE device_uuid = ANY ($1::text[])', [created.uuids]);
      await c.pool.query('DELETE FROM device_inventory WHERE device_uuid = ANY ($1::text[])', [created.uuids]);
    }
    if (created.users.length) await c.pool.query('DELETE FROM users WHERE id = ANY ($1::uuid[])', [created.users]);
  } finally {
    await c.pool.end();
    try {
      await require('../../src/db').pool.end();
    } catch (_) {
      /* inventory_service hic yuklenmediyse havuz yok */
    }
  }
});

const one = async (c, sql, params) => (await c.pool.query(sql, params)).rows[0];

/** Ev + cihaz + envanter (anahtar: current), istenirse bekleyen anahtar ve cevrimici. */
async function makeDevice(c, { home = true, online = false, current = 'GecerliAnahtar12', pending = null } = {}) {
  const n = ++seq;
  const uuid = `AHBU-LK${TAG}-${n}`;
  created.uuids.push(uuid);
  const mac = `LK:${TAG}:${n}`;
  const curEnc = c.secretBox.encrypt(current);
  await c.pool.query(
    `INSERT INTO device_inventory (device_uuid, mac_address, pin_hash, model, status, local_key_enc)
     VALUES ($1, $2, 'CLAIMED_BURNED_PIN', 'ESP32-S3-POE-ETH-8DI-8RO', $3, $4)`,
    [uuid, mac, home ? 'CLAIMED' : 'IN_STOCK', curEnc]
  );
  let homeRow = null;
  if (home) {
    homeRow = (await c.pool.query('INSERT INTO homes (name, mqtt_username) VALUES ($1, $2) RETURNING id, mqtt_username', [`LK-${TAG}-${n}`, `h_${crypto.randomBytes(8).toString('hex')}`])).rows[0];
    created.homes.push(homeRow.id);
    await c.pool.query('UPDATE device_inventory SET claimed_home_id = $1 WHERE device_uuid = $2', [homeRow.id, uuid]);
  }
  const pendingEnc = pending ? c.secretBox.encrypt(pending) : null;
  const dev = (await c.pool.query(
    `INSERT INTO devices (home_id, device_uuid, mac_address, is_claimed, is_online, last_seen_at, local_key_enc,
                          local_key_pending_enc, local_key_pending_at)
     VALUES ($1, $2, $3, $4, $5, CASE WHEN $5 THEN CURRENT_TIMESTAMP ELSE NULL END, $6, $7,
             CASE WHEN $7::text IS NULL THEN NULL ELSE CURRENT_TIMESTAMP END)
     RETURNING id`,
    [homeRow ? homeRow.id : null, uuid, mac, Boolean(homeRow), online, curEnc, pendingEnc]
  )).rows[0];
  return { uuid, id: dev.id, home: homeRow, curEnc, pendingEnc };
}

const keysOf = async (c, uuid) => ({
  dev: await one(c, 'SELECT local_key_enc, local_key_pending_enc, local_key_pending_at FROM devices WHERE device_uuid = $1', [uuid]),
  inv: await one(c, 'SELECT local_key_enc FROM device_inventory WHERE device_uuid = $1', [uuid]),
});

// ------------------------------------------------------------------------------------------------
test('032: kolonlar (TEXT + TIMESTAMPTZ, NULL olabilir), aciklamalar ve tetikleyici katalogda', { skip: SKIP }, async () => {
  const c = await getCtx();
  const cols = (await c.pool.query(
    `SELECT column_name, data_type, is_nullable, col_description('devices'::regclass, ordinal_position) AS note
       FROM information_schema.columns
      WHERE table_name = 'devices' AND column_name IN ('local_key_enc', 'local_key_pending_enc', 'local_key_pending_at')
      ORDER BY column_name`
  )).rows;
  const by = Object.fromEntries(cols.map((r) => [r.column_name, r]));
  assert.equal(by.local_key_pending_enc.data_type, by.local_key_enc.data_type, 'local_key_enc ile ayni tip');
  assert.equal(by.local_key_pending_enc.data_type, 'text');
  assert.equal(by.local_key_pending_at.data_type, 'timestamp with time zone');
  assert.equal(by.local_key_pending_enc.is_nullable, 'YES');
  assert.ok(by.local_key_pending_enc.note && by.local_key_pending_at.note, 'COMMENT tanimli');
  const trg = await one(c, "SELECT tgname FROM pg_trigger WHERE tgrelid = 'devices'::regclass AND tgname = 'trg_devices_pending_key_superseded'");
  assert.ok(trg, 'tetikleyici yok');
});

test('uzlastirici SQL (gercek PG): bekleyen listesi + canlilik; CAS takas yalniz bekleyen eslesirse; envanter + denetim', { skip: SKIP }, async () => {
  const c = await getCtx();
  const { SQL } = require('../../src/services/device_reconciler');
  const d = await makeDevice(c, { online: true, pending: 'YeniAnahtar98765' });

  const rows = (await c.pool.query(SQL.localKeyPending, [d.home.mqtt_username, 120])).rows;
  assert.equal(rows.length, 1);
  assert.equal(rows[0].device_id, d.id);
  assert.equal(rows[0].device_uuid, d.uuid);
  assert.equal(rows[0].pending_enc, d.pendingEnc);
  assert.equal(rows[0].live, true);
  assert.equal(rows[0].device_count, 1);

  // yanlis beklenen deger: dokunulmaz
  const miss = await c.pool.query(SQL.localKeySwap, [d.id, c.secretBox.encrypt('BaskaAnahtar1234')]);
  assert.equal(miss.rowCount, 0);
  assert.equal((await keysOf(c, d.uuid)).dev.local_key_pending_enc, d.pendingEnc);

  await c.db.withTransaction(async (tx) => {
    assert.equal((await tx.query(SQL.localKeyLockInventory, [d.uuid])).rows.length, 1);
    const hit = await tx.query(SQL.localKeySwap, [d.id, d.pendingEnc]);
    assert.equal(hit.rowCount, 1);
    await tx.query(SQL.localKeyInventory, [d.uuid, d.pendingEnc]);
    await tx.query(SQL.localKeyAudit, [d.uuid, d.home.id, JSON.stringify({ via: 'test' })]);
  });
  const k = await keysOf(c, d.uuid);
  assert.equal(k.dev.local_key_enc, d.pendingEnc);
  assert.equal(k.dev.local_key_pending_enc, null);
  assert.equal(k.dev.local_key_pending_at, null);
  assert.equal(k.inv.local_key_enc, d.pendingEnc);
  const audit = await one(c, "SELECT actor_user_id, actor_role, details FROM device_audit_logs WHERE device_uuid = $1 AND event = 'local_key_rotated'", [d.uuid]);
  assert.ok(audit);
  assert.equal(audit.actor_user_id, null);
  assert.ok(!JSON.stringify(audit).includes('YeniAnahtar98765'));
  // inceleme: takas ONCEKI anahtari saklamaz (eski anahtari bilen kisi bootstrap ile geri aldiramaz)
  assert.doesNotMatch(SQL.localKeySwap, /local_key_prev/);
  const prevCols = (await c.pool.query(
    "SELECT column_name FROM information_schema.columns WHERE table_name = 'devices' AND column_name LIKE 'local_key_prev%'"
  )).rows;
  assert.deepEqual(prevCols, []);
});

test('pano-5 (gercek PG): localKeyRow / localKeySwap (iz onayi, CAS) / localKeyAuditEvent SQL; geri donus SQL i yok', { skip: SKIP }, async () => {
  const c = await getCtx();
  const { SQL } = require('../../src/services/device_reconciler');
  const d = await makeDevice(c, { online: true, pending: 'YeniAnahtar55555' });
  const row = (await c.pool.query(SQL.localKeyRow, [d.id])).rows[0];
  assert.equal(row.device_uuid, d.uuid);
  assert.equal(row.home_id, d.home.id);
  assert.equal(row.current_enc, d.curEnc);
  assert.equal(row.pending_enc, d.pendingEnc);
  assert.ok(!('prev_enc' in row), 'onceki anahtar okunmaz');
  assert.equal(row.device_count, 1);
  assert.equal(SQL.localKeyRevert, undefined, 'geri donus SQL i yok');
  // pano dogruladi: takas kesinlesir; yanlis bekleyende dokunulmaz
  assert.equal((await c.pool.query(SQL.localKeySwap, [d.id, c.secretBox.encrypt('Baska')])).rowCount, 0);
  assert.equal((await c.pool.query(SQL.localKeySwap, [d.id, d.pendingEnc])).rowCount, 1);
  const k = await one(c, 'SELECT local_key_enc, local_key_pending_enc, local_key_pending_at FROM devices WHERE id = $1', [d.id]);
  assert.equal(k.local_key_enc, d.pendingEnc);
  assert.equal(k.local_key_pending_enc, null);
  assert.equal(k.local_key_pending_at, null);
  await c.pool.query(SQL.localKeyAuditEvent, ['local_key_mismatch', d.uuid, d.home.id, JSON.stringify({ via: 'state' })]);
  const a = await one(c, "SELECT actor_role, details FROM device_audit_logs WHERE device_uuid = $1 AND event = 'local_key_mismatch'", [d.uuid]);
  assert.equal(a.actor_role, 'system');
  assert.deepEqual(a.details, { via: 'state' });
});

test('tetikleyici: SAHIPSIZ kayitta bekleyene dokunmadan anahtar degisimi bekleyeni temizler; evdeki kayitta ve bekleyeni ACIKCA yazan guncellemede dokunmaz', { skip: SKIP }, async () => {
  const c = await getCtx();
  const orphan = await makeDevice(c, { home: false, pending: 'BekleyenAnahtar1' });
  const label = c.secretBox.encrypt('EtiketAnahtari12');
  // inventory_service.reissueLabel'in yetim cihaz satiri SQL'i (aynen)
  await c.pool.query('UPDATE devices SET local_key_enc = $1, updated_at = CURRENT_TIMESTAMP WHERE device_uuid = $2 AND home_id IS NULL', [label, orphan.uuid]);
  let k = await keysOf(c, orphan.uuid);
  assert.equal(k.dev.local_key_enc, label);
  assert.equal(k.dev.local_key_pending_enc, null, 'yeni etiket anahtari esas: bekleyen temizlenir');
  assert.equal(k.dev.local_key_pending_at, null);

  // evdeki (claim / pano degisimi gibi) kayitta dogrudan degisim bekleyene DOKUNMAZ
  const homed = await makeDevice(c, { home: true, pending: 'BekleyenAnahtar2' });
  await c.pool.query('UPDATE devices SET local_key_enc = $1 WHERE id = $2', [c.secretBox.encrypt('BaskaAnahtar1234'), homed.id]);
  assert.equal((await keysOf(c, homed.uuid)).dev.local_key_pending_enc, homed.pendingEnc);

  // sahipsiz kayitta bekleyeni ACIKCA yazan guncelleme (acil sifirlama / telafi / takas) tetikleyiciden etkilenmez
  const orphan2 = await makeDevice(c, { home: false, pending: 'BekleyenAnahtar3' });
  const fresh = c.secretBox.encrypt('YeniBekleyen1234');
  await c.pool.query('UPDATE devices SET local_key_enc = $1, local_key_pending_enc = $2 WHERE id = $3', [orphan2.pendingEnc, fresh, orphan2.id]);
  k = await keysOf(c, orphan2.uuid);
  assert.equal(k.dev.local_key_pending_enc, fresh);
});

test('etiket yeniden uretimi (gercek inventory_service.reissueLabel; atolye-2): yerel anahtar DEGISMEZ; yetim cihazin anahtari ve bekleyeni aynen; yanitta local_key yok', { skip: SKIP }, async () => {
  const c = await getCtx();
  const d = await makeDevice(c, { home: false, pending: 'BekleyenAnahtar4' });
  const inventoryService = require('../../src/services/inventory_service');
  const savedLog = console.log;
  console.log = () => {}; // src/db.js gelistirme kipinde her sorguyu loglar
  let r;
  try {
    r = await inventoryService.reissueLabel(d.uuid, { userId: null, role: 'super_user', ip: '127.0.0.1' });
  } finally {
    console.log = savedLog;
  }
  const k = await keysOf(c, d.uuid);
  assert.ok(!('local_key' in r), 'yanitta local_key yok');
  assert.ok(r.setup_pin, 'yeni PIN yanitta');
  assert.equal(k.dev.local_key_enc, d.curEnc, 'cihaz anahtari degismez');
  assert.equal(k.inv.local_key_enc, d.curEnc, 'envanter anahtari degismez');
  assert.equal(k.dev.local_key_pending_enc, d.pendingEnc, 'bekleyen anahtara dokunulmaz');
});

test('acil sifirlama (gercek PG; inceleme): STOGA DONUS -> anahtar hemen gecerli (cevrimdisi skipped_offline, cevrimici published); DEVIR -> pending; ev/konu yok -> skipped', { skip: SKIP }, async () => {
  const c = await getCtx();
  const root = (await c.pool.query(
    "INSERT INTO users (email, password_hash, full_name, role) VALUES ($1, 'x', 'Kok', 'super_user') RETURNING id, role",
    [`lk-root-${TAG.toLowerCase()}@wpb-live.invalid`]
  )).rows[0];
  const buyer = (await c.pool.query(
    "INSERT INTO users (email, password_hash, full_name, role, email_verified) VALUES ($1, 'x', 'Yeni Sahip', 'user', TRUE) RETURNING id, email",
    [`lk-buyer0-${TAG.toLowerCase()}@wpb-live.invalid`]
  )).rows[0];
  created.users.push(root.id, buyer.id);
  const actor = { userId: root.id, globalRole: 'super_user', ip: '127.0.0.1' };
  const reset = (uuid, extra = {}) => c.deviceService.emergencyReset({ actor, deviceUuid: uuid, confirmUid: uuid, reason: REASON, ...extra });
  const setKeys = (x) => x.obj && x.obj.cmd === 'set_local_key';

  // 1) stoga donus, pano cevrimdisi: bekleyen YOK; yeni anahtar cihaz + envanterde gecerli; yanitta bir kez; yayin yok
  const off = await makeDevice(c, { online: false });
  c.bridge.rearmed.length = 0;
  const sys0 = c.bridge.sys.filter(setKeys).length;
  const r1 = await reset(off.uuid);
  assert.equal(r1.action, 'UNCLAIMED');
  assert.equal(r1.local_key_publish, 'skipped_offline');
  assert.ok(c.secretBox.isValidLocalKey(r1.local_key));
  let k = await keysOf(c, off.uuid);
  assert.equal(c.secretBox.decrypt(k.dev.local_key_enc), r1.local_key);
  assert.equal(c.secretBox.decrypt(k.inv.local_key_enc), r1.local_key, 'envanter eski anahtar DEGIL');
  assert.equal(k.dev.local_key_pending_enc, null);
  assert.equal(c.bridge.sys.filter(setKeys).length, sys0, 'cevrimdisi panoya yayin denenmez');
  assert.deepEqual(c.bridge.rearmed, []);

  // 2) stoga donus, pano cevrimici + bagli kopru (tek panolu ev): kick ten once set_local_key (yeni anahtar)
  const on = await makeDevice(c, { online: true });
  const r2 = await reset(on.uuid);
  assert.equal(r2.local_key_publish, 'published');
  const sent = c.bridge.sys.filter(setKeys).pop();
  assert.equal(sent.topicId, on.home.mqtt_username);
  assert.equal(sent.obj.local_key, r2.local_key);
  k = await keysOf(c, on.uuid);
  assert.equal(c.secretBox.decrypt(k.dev.local_key_enc), r2.local_key);
  assert.equal(c.secretBox.decrypt(k.inv.local_key_enc), r2.local_key);
  assert.equal(k.dev.local_key_pending_enc, null);

  // 3) devir (cevrimici): bekleyen yol; gecerli anahtar korunur; yanitta anahtar yok; uzlastirici istenir
  const re = await makeDevice(c, { online: true });
  c.bridge.rearmed.length = 0;
  const r3 = await reset(re.uuid, { newOwnerIdentifier: buyer.email });
  assert.equal(r3.action, 'REASSIGNED');
  assert.equal(r3.local_key_publish, 'pending');
  assert.ok(!('local_key' in r3));
  assert.ok(!(r3.warnings || []).includes(PENDING_WARNING), 'fx2 S-1: bekleyen anahtar uyari degildir');
  k = await keysOf(c, re.uuid);
  assert.equal(k.dev.local_key_enc, re.curEnc, 'gecerli anahtar korunur');
  assert.equal(k.inv.local_key_enc, re.curEnc);
  assert.ok(c.secretBox.isValidLocalKey(c.secretBox.decrypt(k.dev.local_key_pending_enc)));
  assert.ok(k.dev.local_key_pending_at instanceof Date);
  assert.deepEqual(c.bridge.rearmed, [re.home.mqtt_username]);

  // 4) ev/konu yok (stoktaki cihaz satiri): 'direct' -> anahtar hemen degisir, yanitta bir kez (skipped)
  const stock = await makeDevice(c, { home: false });
  const r4 = await reset(stock.uuid);
  assert.equal(r4.local_key_publish, 'skipped');
  assert.ok(c.secretBox.isValidLocalKey(r4.local_key));
  k = await keysOf(c, stock.uuid);
  assert.equal(c.secretBox.decrypt(k.dev.local_key_enc), r4.local_key);
  assert.equal(c.secretBox.decrypt(k.inv.local_key_enc), r4.local_key);
  assert.equal(k.dev.local_key_pending_enc, null);
});

test('M1-03 (gercek PG): cevrimdisi panoda DEVIR -> "kilit kapali" niyeti yazilir, bildirilen kilit durumu korunur; uzlastirici SQL farki gorur', { skip: SKIP }, async () => {
  const c = await getCtx();
  const root = (await c.pool.query(
    "INSERT INTO users (email, password_hash, full_name, role) VALUES ($1, 'x', 'Kok', 'super_user') RETURNING id",
    [`lk-root2-${TAG.toLowerCase()}@wpb-live.invalid`]
  )).rows[0];
  const buyer = (await c.pool.query(
    "INSERT INTO users (email, password_hash, full_name, role) VALUES ($1, 'x', 'Yeni Sahip', 'user') RETURNING id, email",
    [`lk-buyer-${TAG.toLowerCase()}@wpb-live.invalid`]
  )).rows[0];
  created.users.push(root.id, buyer.id);
  const d = await makeDevice(c, { online: false });
  await c.pool.query('UPDATE devices SET child_lock_enabled = TRUE WHERE id = $1', [d.id]);
  await c.pool.query('UPDATE homes SET child_lock_enabled = TRUE WHERE id = $1', [d.home.id]);
  const r = await c.deviceService.emergencyReset({
    actor: { userId: root.id, globalRole: 'super_user', ip: '127.0.0.1' },
    deviceUuid: d.uuid, confirmUid: d.uuid, reason: REASON, newOwnerIdentifier: buyer.email,
  });
  assert.equal(r.action, 'REASSIGNED');
  assert.equal(r.child_lock_reset, 'skipped_offline');
  assert.ok(r.warnings.includes('Pano çevrimdışı; çocuk kilidi sıfırlama komutu gönderilemedi. Kilit, pano bağlandığında otomatik kaldırılacak.'), JSON.stringify(r.warnings));
  const home = await one(c, 'SELECT child_lock_requested, child_lock_requested_at, peace_notification_time FROM homes WHERE id = $1', [d.home.id]);
  assert.equal(home.child_lock_requested, false);
  assert.ok(home.child_lock_requested_at instanceof Date);
  assert.equal(home.peace_notification_time, '23:30');
  const dev = await one(c, 'SELECT child_lock_enabled, home_id FROM devices WHERE id = $1', [d.id]);
  assert.equal(dev.child_lock_enabled, true, 'bildirilen durum korunur (niyet karsilanmis sayilmaz)');
  assert.equal(dev.home_id, d.home.id);
});

test('UCTAN UCA: bekleyen anahtar + kopru CANLI state -> uzlastirici sys set_local_key yayinlar ve gercek SQL ile takas eder', { skip: SKIP }, async () => {
  const c = await getCtx();
  const { MqttBridge } = require('../../src/mqtt_bridge');
  const { constants } = require('../../src/services/device_reconciler');
  const { makeFakeTimers, makeFakeClient, makeFakeMqttLib, flush } = require('../bridge/_helpers');
  const d = await makeDevice(c, { online: false, pending: 'UctanUcaAnahtar1' });
  const timers = makeFakeTimers();
  const client = makeFakeClient();
  const lines = [];
  const logger = { log: (m) => lines.push(String(m)), warn: (m) => lines.push(String(m)), error: (m) => lines.push(String(m)) };
  const bridge = new MqttBridge({ db: c.db, logger, env: { MQTT_BACKEND_USER: 'u', MQTT_BACKEND_PASS: 'p' }, timers, mqttLib: makeFakeMqttLib(client), reconcile: true });
  bridge.init();
  client.connected = true;
  client.emit('connect', { sessionPresent: false });
  await flush();
  try {
    await bridge.handleIncomingMessage(`ev/${d.home.mqtt_username}/state`, Buffer.from(JSON.stringify({ uid: d.uuid, child_lock: false })), { retain: false });
    const settle = timers.pendingTimeouts().filter((t) => t.ms === constants.SETTLE_MS);
    assert.equal(settle.length, 1);
    timers.fireTimeout(settle[0]);
    await bridge._reconciler.whenIdle();
    await flush();
    const sys = client.published.filter((p) => p.topic === `ev/${d.home.mqtt_username}/sys`);
    assert.equal(sys.length, 1);
    assert.equal(JSON.parse(sys[0].payload).local_key, 'UctanUcaAnahtar1');
    const k = await keysOf(c, d.uuid);
    assert.equal(k.dev.local_key_enc, d.pendingEnc);
    assert.equal(k.dev.local_key_pending_enc, null);
    assert.equal(k.inv.local_key_enc, d.pendingEnc);
    assert.ok(!lines.some((l) => l.includes('UctanUcaAnahtar1') || l.includes(d.pendingEnc)), 'anahtar loglanmaz');
  } finally {
    await bridge.end({ force: true, timeoutMs: 20 });
  }
});

test('UCTAN UCA (pano-5 g): lk_fp bildiren pano -> PUBACK te takas YOK; yeni iz gorulunce takas (via:state); uyumsuz iz bir kez denetlenir', { skip: SKIP }, async () => {
  const c = await getCtx();
  const { MqttBridge } = require('../../src/mqtt_bridge');
  const { constants } = require('../../src/services/device_reconciler');
  const { localKeyFingerprint } = require('../../src/utils/local_key_fp');
  const { makeFakeTimers, makeFakeClient, makeFakeMqttLib, flush } = require('../bridge/_helpers');
  const d = await makeDevice(c, { online: false, pending: 'FpUctanAnahtar01' });
  const fpOld = localKeyFingerprint('GecerliAnahtar12', d.uuid);
  const fpNew = localKeyFingerprint('FpUctanAnahtar01', d.uuid);
  const timers = makeFakeTimers();
  const client = makeFakeClient();
  const lines = [];
  const logger = { log: (m) => lines.push(String(m)), warn: (m) => lines.push(String(m)), error: (m) => lines.push(String(m)) };
  const bridge = new MqttBridge({ db: c.db, logger, env: { MQTT_BACKEND_USER: 'u', MQTT_BACKEND_PASS: 'p' }, timers, mqttLib: makeFakeMqttLib(client), reconcile: true });
  bridge.init();
  client.connected = true;
  client.emit('connect', { sessionPresent: false });
  await flush();
  const state = (fp) => bridge.handleIncomingMessage(`ev/${d.home.mqtt_username}/state`, Buffer.from(JSON.stringify({ uid: d.uuid, child_lock: false, lk_fp: fp })), { retain: false });
  const audits = async (event) => (await c.pool.query('SELECT details FROM device_audit_logs WHERE device_uuid = $1 AND event = $2', [d.uuid, event])).rows;
  try {
    await state(fpOld);
    await bridge._reconciler.whenIdle();
    let row = await one(c, 'SELECT local_key_fp, local_key_fp_at FROM devices WHERE id = $1', [d.id]);
    assert.equal(row.local_key_fp, fpOld, 'iz yazildi');
    assert.ok(row.local_key_fp_at instanceof Date);

    const settle = timers.pendingTimeouts().filter((t) => t.ms === constants.SETTLE_MS);
    assert.equal(settle.length, 1);
    timers.fireTimeout(settle[0]);
    await bridge._reconciler.whenIdle();
    await flush();
    const sys = client.published.filter((p) => p.topic === `ev/${d.home.mqtt_username}/sys`);
    assert.equal(sys.length, 1);
    assert.equal(JSON.parse(sys[0].payload).cmd, 'set_local_key');
    let k = await keysOf(c, d.uuid);
    assert.equal(k.dev.local_key_enc, d.curEnc, 'PUBACK te takas YOK (iz bildiren pano)');
    assert.equal(k.dev.local_key_pending_enc, d.pendingEnc);
    assert.equal(timers.pendingTimeouts().filter((t) => t.ms === constants.LOCAL_KEY_CONFIRM_MS).length, 1, 'onay bekleniyor');

    // pano yeni anahtari uyguladi: state'te yeni iz -> takas kesinlesir
    await state(fpNew);
    await bridge._reconciler.whenIdle();
    k = await keysOf(c, d.uuid);
    assert.equal(k.dev.local_key_enc, d.pendingEnc);
    assert.equal(k.dev.local_key_pending_enc, null);
    assert.equal(k.inv.local_key_enc, d.pendingEnc);
    const pv = await one(c, 'SELECT local_key_fp FROM devices WHERE id = $1', [d.id]);
    assert.equal(pv.local_key_fp, fpNew);
    const rot = await audits('local_key_rotated');
    assert.equal(rot.length, 1);
    assert.deepEqual(rot[0].details, { via: 'state' });

    // uyumsuz iz: (cihaz, iz) basina BIR kez denetim
    await state('00000000');
    await bridge._reconciler.whenIdle();
    await state('00000000');
    await bridge._reconciler.whenIdle();
    assert.equal((await audits('local_key_mismatch')).length, 1);
    assert.ok(!lines.some((l) => l.includes('FpUctanAnahtar01') || l.includes('GecerliAnahtar12')), 'anahtar loglanmaz');
  } finally {
    await bridge.end({ force: true, timeoutMs: 20 });
  }
});
