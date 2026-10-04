'use strict';

// WP-L duzeltmeleri (KARARLAR D5, D6, D13): satirlari yeniden tohumlayan / silen cihaz akislari ile yerlesim esitleme.
//   D5  - acil sifirlama (REASSIGNED / UNCLAIMED), pano degisimi ve sahiplenme upsert'unun ON CONFLICT dali
//         devices.reported_layout ve reported_layout_at alanlarini NULL'lar (eski dairenin pano adlari kalmaz;
//         yeni satirlar "henuz esitlenmemis" sayilir).
//   D6  - REASSIGNED transaction'i COMMIT edildikten SONRA koprunun invalidateLayout(deviceId) metodu (varsa) bir kez
//         cagrilir; en iyi caba: yoksa / patlarsa sifirlama yine basarilidir; commit basarisizsa cagrilmaz.
//   D13 - ev biliniyorsa temizlikten (ve ev kilidinden) ONCE evin TUM cihaz satirlari id sirasiyla FOR UPDATE kilitlenir.
// Gercek PostgreSQL karsiliklari: layout_flows_pg.test.js.

const test = require('node:test');
const assert = require('node:assert');

const { createWorld, createServices, setTestEnv } = require('./_world');

const UUID = 'AHBU-S3-0001';
const UUID_B = 'AHBU-S3-0009';
const REASON = 'Kiraci ulasilamiyor, daire teslim alindi';
const STALE_LAYOUT = { v: 1, relays: [{ id: 1, type: 'light', name: 'Eski Dairenin Adi' }] };

/** Kurulu ev: sahip + yeni sahip adayi, (cevrimici) cihaz, 8 kanal, eski taban; istege bagli ikinci pano. */
async function setup({ secondDevice = false } = {}) {
  setTestEnv();
  const world = createWorld();
  const svc = createServices(world);
  const h = world.helpers;

  const root = h.addUser({ email: 'root@example.test', role: 'super_user' });
  const owner = h.addUser({ email: 'sahip@example.test' });
  const newbie = h.addUser({ email: 'yeni.sahip@example.test', full_name: 'Yeni Sahip' });

  const inv = h.addInventory({ uuid: UUID, pin: '246810', status: 'CLAIMED' });
  const home = h.addHome({ name: 'Daire 7', owner });
  const dev = h.addDevice({ home, uuid: UUID, mac: inv.mac_address, claimedBy: owner, online: true });
  h.addEndpoints(home, dev, 8);
  dev.reported_layout = STALE_LAYOUT;
  dev.reported_layout_at = new Date(world.clock.t - 60000);
  inv.claimed_home_id = home.id;
  inv.claimed_by_user_id = owner.id;
  inv.pin_hash = 'CLAIMED_BURNED_PIN';

  let devB = null;
  if (secondDevice) {
    const invB = h.addInventory({ uuid: UUID_B, pin: '135790', status: 'CLAIMED' });
    devB = h.addDevice({ home, uuid: UUID_B, mac: invB.mac_address, claimedBy: owner, online: true });
    h.addEndpoints(home, devB, 8);
    invB.claimed_home_id = home.id;
  }

  await svc.credentials.issueDeviceCredential({ homeId: home.id, deviceId: dev.id });
  svc.timeline.length = 0;
  world.db.log.length = 0;
  world.db.commits = 0;

  const reset = (overrides = {}) =>
    svc.deviceService.emergencyReset({
      actor: { userId: root.id, globalRole: 'super_user', ip: '203.0.113.9' },
      deviceUuid: UUID,
      confirmUid: UUID,
      reason: REASON,
      ...overrides,
    });
  return { world, ...svc, root, owner, newbie, inv, home, dev, devB, reset };
}

/** Kopruye invalidateLayout casusu ekler; cagri anindaki transaction durumu kaydedilir. */
function spyInvalidate(ctx, { throws = null } = {}) {
  const calls = [];
  ctx.bridge.invalidateLayout = (deviceId) => {
    calls.push({ deviceId, openTx: ctx.world.db.openTx, commits: ctx.world.db.commits });
    if (throws) throw throws;
  };
  return calls;
}

const indexOf = (db, fragment) => db.log.findIndex((l) => l.sql.includes(fragment));

// ------------------------------------------------------------------------------------------------
// D5 - taban sifirlama
// ------------------------------------------------------------------------------------------------
test('D5 acil sifirlama REASSIGNED: cihaz satirinin tabani (reported_layout + _at) NULL olur', async () => {
  const ctx = await setup();
  const r = await ctx.reset({ newOwnerIdentifier: 'yeni.sahip@example.test' });
  assert.strictEqual(r.action, 'REASSIGNED');
  assert.strictEqual(ctx.dev.reported_layout, null, 'eski taban kalmamali');
  assert.strictEqual(ctx.dev.reported_layout_at, null);
  const upd = ctx.world.db.find('UPDATE devices SET home_id = $1, is_claimed = TRUE');
  assert.strictEqual(upd.length, 1);
  assert.match(upd[0].sql, /reported_layout = NULL, reported_layout_at = NULL/);
});

test('D5 acil sifirlama UNCLAIMED (stoga donus): eski dairenin pano adlari tabanda kalmaz', async () => {
  const ctx = await setup();
  const r = await ctx.reset();
  assert.strictEqual(r.action, 'UNCLAIMED');
  assert.strictEqual(ctx.dev.reported_layout, null);
  assert.strictEqual(ctx.dev.reported_layout_at, null);
  const upd = ctx.world.db.find('UPDATE devices SET home_id = NULL, is_claimed = FALSE, claimed_by = NULL, claimed_at = NULL');
  assert.strictEqual(upd.length, 1);
  assert.match(upd[0].sql, /reported_layout = NULL, reported_layout_at = NULL/);
});

test('D5 pano degisimi: yeni panonun ONCEDEN VAR OLAN satiri (ON CONFLICT dali) bayat tabanla kalmaz', async () => {
  const ctx = await setup();
  const h = ctx.world.helpers;
  const NEW = 'AHBU-S3-0002';
  const newInv = h.addInventory({ uuid: NEW, pin: '135790', status: 'IN_STOCK' });
  const stale = h.addDevice({ uuid: NEW, mac: newInv.mac_address }); // stoktaki pano: eski kullanimdan kalan satir
  stale.reported_layout = STALE_LAYOUT;
  stale.reported_layout_at = new Date(ctx.world.clock.t - 3600000);
  const r = await ctx.deviceService.replaceBoard({
    actor: { userId: ctx.owner.id, globalRole: 'user', ip: '198.51.100.4', access: 'owner' },
    homeId: ctx.home.id,
    oldDeviceUuid: UUID,
    newDeviceUuid: NEW,
    setupPin: '135790',
    reason: 'Pano yandi',
  });
  assert.strictEqual(r.new_device_uuid, NEW);
  assert.strictEqual(stale.home_id, ctx.home.id, 'ayni satir yeniden kullanildi (ON CONFLICT)');
  assert.strictEqual(stale.reported_layout, null);
  assert.strictEqual(stale.reported_layout_at, null);
  const ins = ctx.world.db.find('INSERT INTO devices (home_id, device_uuid, mac_address, is_claimed');
  assert.strictEqual(ins.length, 1);
  assert.match(ins[0].sql, /ON CONFLICT \(device_uuid\) DO UPDATE SET .*reported_layout = NULL, reported_layout_at = NULL/);
});

test('D5 sahiplenme: onceden var olan cihaz satiri (ON CONFLICT dali) bayat tabanla kalmaz', async () => {
  setTestEnv();
  const world = createWorld();
  const svc = createServices(world);
  const h = world.helpers;
  const customer = h.addUser({ email: 'ev.sahibi@example.test' });
  const inv = h.addInventory({ uuid: UUID, pin: '123456' });
  const stale = h.addDevice({ uuid: UUID, mac: inv.mac_address }); // stoga donmus cihazin satiri
  stale.reported_layout = STALE_LAYOUT;
  stale.reported_layout_at = new Date(world.clock.t - 3600000);
  const r = await svc.deviceService.claimDevice({
    actor: { userId: customer.id, globalRole: 'user', ip: '10.0.0.7' },
    deviceUuid: UUID,
    setupPin: '123456',
  });
  assert.strictEqual(r.device_uuid, UUID);
  assert.strictEqual(world.state.devices.length, 1, 'ayni satir yeniden kullanildi (ON CONFLICT)');
  assert.strictEqual(stale.reported_layout, null);
  assert.strictEqual(stale.reported_layout_at, null);
  const ins = world.db.find('INSERT INTO devices (home_id, device_uuid, mac_address, is_claimed');
  assert.match(ins[0].sql, /ON CONFLICT \(device_uuid\) DO UPDATE SET .*reported_layout = NULL, reported_layout_at = NULL/);
});

// ------------------------------------------------------------------------------------------------
// D6 - REASSIGNED sonrasi esitleme onbellegi
// ------------------------------------------------------------------------------------------------
test('D6 REASSIGNED: COMMIT SONRASI kopru invalidateLayout(deviceId) BIR kez cagrilir', async () => {
  const ctx = await setup();
  const calls = spyInvalidate(ctx);
  const r = await ctx.reset({ newOwnerIdentifier: 'yeni.sahip@example.test' });
  assert.strictEqual(r.action, 'REASSIGNED');
  assert.deepStrictEqual(calls.map((c) => c.deviceId), [ctx.dev.id]);
  assert.strictEqual(calls[0].openTx, 0, 'transaction kapanmis olmali');
  assert.strictEqual(calls[0].commits, 1, 'COMMIT edilmis olmali');
});

test('D6 commit BASARISIZ olursa invalidateLayout cagrilmaz', async () => {
  const ctx = await setup();
  const calls = spyInvalidate(ctx);
  ctx.world.db.handlers.unshift({
    matcher: 'INSERT INTO emergency_reset_logs',
    fn: () => {
      throw Object.assign(new Error('disk dolu'), { code: '53100' });
    },
  });
  await assert.rejects(ctx.reset({ newOwnerIdentifier: 'yeni.sahip@example.test' }), /disk dolu/);
  assert.strictEqual(ctx.world.db.rollbacks, 1);
  assert.deepStrictEqual(calls, []);
});

test('D6 kopruda invalidateLayout YOKSA ya da PATLARSA sifirlama yine basarili', async () => {
  const ctx = await setup();
  assert.strictEqual(typeof ctx.bridge.invalidateLayout, 'undefined');
  const r = await ctx.reset({ newOwnerIdentifier: 'yeni.sahip@example.test' });
  assert.strictEqual(r.action, 'REASSIGNED');

  const ctx2 = await setup();
  const calls = spyInvalidate(ctx2, { throws: new Error('onbellek patladi') });
  const r2 = await ctx2.reset({ newOwnerIdentifier: 'yeni.sahip@example.test' });
  assert.strictEqual(r2.action, 'REASSIGNED');
  assert.strictEqual(calls.length, 1);
  assert.strictEqual(ctx2.dev.home_id, ctx2.home.id);
});

// ------------------------------------------------------------------------------------------------
// D13 - cok panolu evde kilit sirasi
// ------------------------------------------------------------------------------------------------
test('D13 ev biliniyorsa evin TUM cihaz satirlari id sirasiyla, ev kilidinden ve temizlikten ONCE kilitlenir', async () => {
  for (const owner of [null, 'yeni.sahip@example.test']) {
    const ctx = await setup({ secondDevice: true });
    await ctx.reset(owner ? { newOwnerIdentifier: owner } : {});
    const db = ctx.world.db;
    const lock = db.find('SELECT id FROM devices WHERE home_id = $1 ORDER BY id FOR UPDATE');
    assert.strictEqual(lock.length, 1, `${owner || 'stok'}: tek kilit sorgusu`);
    assert.deepStrictEqual(lock[0].params, [ctx.home.id]);
    assert.notStrictEqual(lock[0].tx, null, 'transaction icinde');
    const iLock = indexOf(db, 'SELECT id FROM devices WHERE home_id = $1 ORDER BY id FOR UPDATE');
    assert.ok(iLock > indexOf(db, 'FROM devices WHERE device_uuid = $1 FOR UPDATE'), 'cihaz satiri okunduktan sonra');
    assert.ok(iLock < indexOf(db, 'FROM homes WHERE id = $1 FOR UPDATE'), 'ev kilidinden once');
    assert.ok(iLock < indexOf(db, 'DELETE FROM home_users WHERE home_id = $1'), 'temizlikten once');
    assert.ok(iLock < indexOf(db, 'UPDATE devices SET child_lock_enabled = FALSE WHERE home_id = $1'));
  }
});

test('D13 ev yoksa (stoktaki cihaz) ev cihazlari kilidi yapilmaz', async () => {
  const ctx = await setup();
  ctx.world.helpers.addInventory({ uuid: 'AHBU-S3-0002', pin: '111222', status: 'IN_STOCK' });
  const r = await ctx.reset({ deviceUuid: 'AHBU-S3-0002', confirmUid: 'AHBU-S3-0002' });
  assert.strictEqual(r.home_id, null);
  assert.strictEqual(ctx.world.db.count('ORDER BY id FOR UPDATE'), 0);
});

test('D13 kilit gercekten beklenir: baska islem ikinci panonun satirini tutarken sifirlama ev kilidine gecmez', async () => {
  const ctx = await setup({ secondDevice: true });
  const db = ctx.world.db;
  let release;
  const gate = new Promise((resolve) => {
    release = resolve;
  });
  let held;
  const heldReady = new Promise((resolve) => {
    held = resolve;
  });
  // esitleme(B) benzeri: B'nin cihaz satirini kilitler ve bekler
  const other = db.withTransaction(async (tx) => {
    await tx.query('SELECT id FROM devices WHERE home_id = $1 AND device_uuid = $2 FOR UPDATE', [ctx.home.id, UUID_B]);
    held();
    await gate;
  });
  await heldReady;
  const pReset = ctx.reset();
  for (let i = 0; i < 10; i += 1) await new Promise((resolve) => setImmediate(resolve));
  assert.strictEqual(db.count('FROM homes WHERE id = $1 FOR UPDATE'), 0, 'B kilidi birakilana kadar ev kilidine gecilmemeli');
  release();
  await other;
  const r = await pReset;
  assert.strictEqual(r.action, 'UNCLAIMED');
  assert.strictEqual(db.count('FROM homes WHERE id = $1 FOR UPDATE'), 1);
});
