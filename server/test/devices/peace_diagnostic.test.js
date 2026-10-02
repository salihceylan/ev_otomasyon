'use strict';

// B8 / B11: gece huzur bildirimi (gercek sutunlar), sistem doktoru (TUM cihazlar)

const test = require('node:test');
const assert = require('node:assert');

const { createWorld, createServices, setTestEnv, expectHttp } = require('./_world');

function setup() {
  setTestEnv();
  const world = createWorld();
  const svc = createServices(world);
  const h = world.helpers;
  const owner = h.addUser({ email: 'sahip@example.test' });
  const home = h.addHome({ name: 'Ev', owner });
  const dev = h.addDevice({ home, uuid: 'AHBU-S3-0001', mac: 'E8:F6:0A:00:00:01', online: true });
  const eps = h.addEndpoints(home, dev, 8);
  const actor = (access) => ({ userId: owner.id, globalRole: 'user', ip: '10.0.0.1', access });
  return { world, ...svc, owner, home, dev, eps, actor };
}

const MISSING = '00000000-0000-4000-8000-000000000000';

// ------------------------------------------------------------------------------------------------
test('huzur bildirimi: SEMADA OLAN sutunlar kullanilir (current_state / current_position); state, is_active, shutter_position YOK', async () => {
  const ctx = setup();
  await ctx.deviceService.getPeaceNotificationSettings({ homeId: ctx.home.id });
  const text = ctx.world.db.sqls().join('\n');
  assert.ok(!/\be\.state\b/.test(text), 'endpoints.state sutunu yok');
  assert.ok(!/is_active/.test(text), 'endpoints.is_active sutunu yok');
  assert.ok(!/e\.shutter_position/.test(text), 'endpoints.shutter_position sutunu yok');
  // v2: sorgu peace_snapshot.js'te (canli anlik goruntu); sema sutunlari ayni
  assert.ok(/e\.current_state IS TRUE/.test(text));
  assert.ok(/e\.current_position >= \$3/.test(text));

  for (const file of ['device_service', 'peace_service', 'peace_snapshot']) {
    const src = require('fs').readFileSync(require.resolve('../../src/services/' + file), 'utf8');
    assert.ok(!/e\.state\b|e\.is_active|e\.shutter_position/.test(src), file);
  }
});

test('huzur bildirimi: acik lamba listesi/sayisi ve acik panjur sayisi (cift satirli panjur bir kez sayilir)', async () => {
  const ctx = setup();
  const ep = (n) => ctx.eps.find((e) => e.channel_index === n);
  ep(5).current_state = true; // Salon Aydinlatma
  ep(6).current_state = true; // Mutfak
  ep(7).current_state = true; // Koridor
  ep(8).current_state = false;
  ep(1).current_position = 50; ep(2).current_position = 50; // panjur 1 (iki satir ayni konum)
  ep(3).current_position = 0; ep(4).current_position = 0;

  const r = await ctx.deviceService.getPeaceNotificationSettings({ homeId: ctx.home.id });
  assert.strictEqual(r.home_id, ctx.home.id);
  assert.strictEqual(r.open_lights_count, 3);
  assert.deepStrictEqual(r.open_lights.map((l) => l.channel_index), [5, 6, 7]);
  assert.strictEqual(r.open_shutters_count, 1);
  assert.strictEqual(r.peace_notification_enabled, true);
  assert.strictEqual(r.peace_notification_time, '23:30');
  // v2 (WP-H): ozet metni peace_text.js'ten gelir (oda adlari ek alir: "Salonda ...")
  assert.match(r.summary_text, /Salon/);
  assert.match(r.summary_text, /Mutfak/);
  assert.match(r.summary_text, /Koridor/);
  assert.match(r.summary_text, /panjur/);
  assert.strictEqual(r.stale, false);
  assert.strictEqual(r.devices_online, 1);
  assert.strictEqual(r.timezone, 'Europe/Istanbul');
  assert.strictEqual(r.last_notice, null);
  assert.deepStrictEqual(r.open_shutters, [{ pair: 1, room: 'Salon', position: 50 }]);

  ep(5).current_state = ep(6).current_state = ep(7).current_state = false;
  ep(1).current_position = ep(2).current_position = 0;
  const calm = await ctx.deviceService.getPeaceNotificationSettings({ homeId: ctx.home.id });
  assert.strictEqual(calm.open_lights_count, 0);
  assert.strictEqual(calm.open_shutters_count, 0);
  assert.match(calm.summary_text, /huzur modunda/);
});

test('huzur bildirimi: bilinmeyen ev 404 NOT_FOUND (genel 500 degil)', async () => {
  const ctx = setup();
  await expectHttp(ctx.deviceService.getPeaceNotificationSettings({ homeId: MISSING }), 404, 'NOT_FOUND');
  await expectHttp(ctx.deviceService.updatePeaceNotificationSettings({ actor: ctx.actor('owner'), homeId: MISSING, enabled: true }), 404, 'NOT_FOUND');
});

test('huzur ayari: saat SS:DD (24 saat) bicimi dogrulanir; boolean olmayan enabled ve bos guncelleme 400', async () => {
  const ctx = setup();
  const update = (o, access = 'owner') =>
    ctx.deviceService.updatePeaceNotificationSettings({ actor: ctx.actor(access), homeId: ctx.home.id, ...o });

  for (const t of ['00:00', '09:05', '23:59', '23:30', '12:00']) {
    const r = await update({ notificationTime: t });
    assert.strictEqual(r.settings.peace_notification_time, t);
  }
  for (const t of ['24:00', '25:00', '23:60', '9:5', '9:05', '2330', 'abc', '', '23:30:00', ' 23:30', 2330, null, true]) {
    if (t === null) continue; // null = alan verilmedi
    await expectHttp(update({ notificationTime: t }), 400, 'VALIDATION');
  }
  assert.strictEqual(ctx.home.peace_notification_time, '12:00', 'gecersiz saat veritabanini degistirmemeli');

  for (const enabled of ['true', 1, 0, 'evet']) {
    await expectHttp(update({ enabled }), 400, 'VALIDATION');
  }
  await expectHttp(update({}), 400, 'VALIDATION');
  const r = await update({ enabled: false });
  assert.strictEqual(r.settings.peace_notification_enabled, false);
  assert.strictEqual(ctx.home.peace_notification_enabled, false);
  assert.strictEqual(ctx.home.peace_notification_time, '12:00', 'verilmeyen alan korunur');
});

test('huzur ayari: misafir ve bilinmeyen rol degistiremez (403); aile sakini ve sahip degistirebilir', async () => {
  const ctx = setup();
  for (const access of ['guest', 'hacker', null]) {
    await expectHttp(ctx.deviceService.updatePeaceNotificationSettings({ actor: ctx.actor(access), homeId: ctx.home.id, enabled: false }), 403, 'FORBIDDEN');
  }
  assert.strictEqual(ctx.home.peace_notification_enabled, true);
  for (const access of ['resident', 'owner', 'service_user', 'service_session', 'super_user']) {
    const r = await ctx.deviceService.updatePeaceNotificationSettings({ actor: ctx.actor(access), homeId: ctx.home.id, enabled: false });
    assert.strictEqual(r.settings.peace_notification_enabled, false, access);
  }
});

// ------------------------------------------------------------------------------------------------
// Sistem doktoru
// ------------------------------------------------------------------------------------------------

test('tanı: TUM cihazlar degerlendirilir (LIMIT 1 yok); tek saglikli cihaz -> ok', async () => {
  const ctx = setup();
  ctx.dev.last_seen_at = new Date(ctx.world.clock.t - 30 * 1000);
  ctx.dev.firmware_version = '1.1.0';
  ctx.dev.ip_address = '192.168.1.30';

  const r = await ctx.deviceService.getSystemDiagnostic({ homeId: ctx.home.id });
  assert.strictEqual(r.diagnosis_level, 'ok');
  assert.strictEqual(r.cloud.status, 'OK');
  assert.strictEqual(r.cloud.db_connected, true);
  assert.strictEqual(r.cloud.mqtt_bridge_connected, true);
  assert.strictEqual(r.devices.length, 1);
  assert.strictEqual(r.devices[0].device_uuid, 'AHBU-S3-0001');
  assert.strictEqual(r.devices[0].online, true);
  assert.strictEqual(r.endpoint_count, 8);
  assert.strictEqual(r.home_network.status, 'OK');
  assert.strictEqual(r.home_network.device_ip, '192.168.1.30');
  assert.strictEqual(r.hardware_power.is_online, true);
  assert.strictEqual(r.hardware_power.firmware_version, '1.1.0');
  assert.ok(!('mac_address' in r.hardware_power), 'MAC adresi yanita konmamali');
  assert.strictEqual(r.action_recommendation, null);
  assert.ok(ctx.world.db.sqls().every((s) => !/FROM devices d[\s\S]*LIMIT 1/.test(s)));
});

test('tanı: birden fazla cihaz - biri haberlesiyor biri degil -> warning, cihaz bazli seviyeler', async () => {
  const ctx = setup();
  const second = ctx.world.helpers.addDevice({ home: ctx.home, uuid: 'AHBU-S3-0009', mac: 'E8:F6:0A:00:00:09', online: false });
  ctx.dev.last_seen_at = new Date(ctx.world.clock.t - 10 * 1000);
  second.last_seen_at = new Date(ctx.world.clock.t - 2 * 3600 * 1000);

  const r = await ctx.deviceService.getSystemDiagnostic({ homeId: ctx.home.id });
  assert.strictEqual(r.devices.length, 2);
  const byId = Object.fromEntries(r.devices.map((d) => [d.device_uuid, d]));
  assert.strictEqual(byId['AHBU-S3-0001'].level, 'ok');
  assert.strictEqual(byId['AHBU-S3-0009'].level, 'error');
  assert.strictEqual(byId['AHBU-S3-0009'].power_status, 'SUSPECTED_OFFLINE_OR_POWER_OUTAGE');
  assert.strictEqual(r.diagnosis_level, 'warning');
  assert.match(r.diagnosis_title, /Bazı Panolar/);
  assert.match(r.diagnosis_summary, /2 panodan 1/);
});

test('tanı: hicbir cihaz haberlesmiyorsa error; gecikmeli (<=300 sn) warning; hic gorulmemis cihaz error', async () => {
  const ctx = setup();
  ctx.dev.last_seen_at = new Date(ctx.world.clock.t - 200 * 1000);
  let r = await ctx.deviceService.getSystemDiagnostic({ homeId: ctx.home.id });
  assert.strictEqual(r.diagnosis_level, 'warning');
  assert.strictEqual(r.home_network.status, 'WARNING');
  assert.match(r.home_network.seconds_since_last_seen + '', /^\d+$/);

  ctx.dev.last_seen_at = new Date(ctx.world.clock.t - 3600 * 1000);
  r = await ctx.deviceService.getSystemDiagnostic({ homeId: ctx.home.id });
  assert.strictEqual(r.diagnosis_level, 'error');
  assert.match(r.action_recommendation, /Wi-Fi/);

  ctx.dev.last_seen_at = null;
  r = await ctx.deviceService.getSystemDiagnostic({ homeId: ctx.home.id });
  assert.strictEqual(r.diagnosis_level, 'error');
  assert.strictEqual(r.home_network.seconds_since_last_seen, null);
});

test('tanı: broker kopuksa bulut DEGRADED; cihaz yoksa UNCLAIMED yonlendirmesi; bilinmeyen ev 404', async () => {
  const ctx = setup();
  ctx.dev.last_seen_at = new Date(ctx.world.clock.t - 5 * 1000);
  ctx.bridge.connected = false;
  const r = await ctx.deviceService.getSystemDiagnostic({ homeId: ctx.home.id });
  assert.strictEqual(r.cloud.status, 'DEGRADED');
  assert.strictEqual(r.cloud.mqtt_bridge_connected, false);

  const empty = ctx.world.helpers.addHome({ name: 'Bos' });
  const u = await ctx.deviceService.getSystemDiagnostic({ homeId: empty.id });
  assert.strictEqual(u.home_network.status, 'UNCLAIMED');
  assert.strictEqual(u.hardware_power.status, 'UNCLAIMED');
  assert.deepStrictEqual(u.devices, []);
  assert.strictEqual(u.diagnosis_level, 'warning');

  await expectHttp(ctx.deviceService.getSystemDiagnostic({ homeId: MISSING }), 404, 'NOT_FOUND');
});

test('tanı: veritabani sorgusu basarisizsa bulut DEGRADED ve db_connected:false (teshis yine doner)', async () => {
  const ctx = setup();
  const original = ctx.world.db.query.bind(ctx.world.db);
  ctx.world.db.query = async (text, params) => {
    if (String(text).trim() === 'SELECT 1') throw new Error('db down');
    return original(text, params);
  };
  const r = await ctx.deviceService.getSystemDiagnostic({ homeId: ctx.home.id });
  assert.strictEqual(r.cloud.db_connected, false);
  assert.strictEqual(r.cloud.status, 'DEGRADED');
  assert.strictEqual(r.devices.length, 1);
});

test('tanı: sessiz "ilk daire" yedegi YOK (home_id zorunlu; kullanicinin ilk evine dusulmez)', () => {
  const src = require('fs').readFileSync(require.resolve('../../src/services/device_service'), 'utf8');
  assert.ok(!/ORDER BY created_at ASC LIMIT 1/.test(src.replace(/home_users WHERE home_id = \$1 AND role = 'owner' ORDER BY created_at ASC LIMIT 1/, '')));
  assert.ok(!/fallbackRes/.test(src));
});
