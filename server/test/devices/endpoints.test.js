'use strict';

// B8 / B11: endpoint servisi - liste (takma adlar), kalibrasyon (1..300 + set_runtime yayini), ad/oda, kontrol ceviricisi

const test = require('node:test');
const assert = require('node:assert');

const { createWorld, createServices, setTestEnv, expectHttp } = require('./_world');
const { EndpointService } = require('../../src/services/endpoint_service');
const { norm } = require('./_fake_db');

function setup({ online = true } = {}) {
  setTestEnv();
  const world = createWorld();
  const svc = createServices(world);
  const h = world.helpers;
  const owner = h.addUser({ email: 'sahip@example.test' });
  const home = h.addHome({ name: 'Ev', owner });
  const otherHome = h.addHome({ name: 'Baska' });
  const dev = h.addDevice({ home, uuid: 'AHBU-S3-0001', mac: 'E8:F6:0A:00:00:01', online });
  const otherDev = h.addDevice({ home: otherHome, uuid: 'AHBU-S3-0002', mac: 'E8:F6:0A:00:00:02', online: true });
  const eps = h.addEndpoints(home, dev, 8);
  const otherEps = h.addEndpoints(otherHome, otherDev, 8);
  const endpointService = new EndpointService({ db: world.db, deviceService: svc.deviceService, mqttBridge: svc.bridge });
  const actor = (access) => ({ userId: owner.id, globalRole: 'user', ip: '10.0.0.1', access });
  const ep = (channel) => eps.find((e) => e.channel_index === channel);
  const update = (endpoint, patch, access = 'owner') =>
    endpointService.updateEndpoint({ actor: actor(access), homeId: home.id, endpointId: endpoint.id, patch });
  return { world, ...svc, owner, home, otherHome, dev, otherDev, eps, otherEps, endpointService, actor, ep, update };
}

// ------------------------------------------------------------------------------------------------
test('liste: yalnizca BU evin kanallari; takma adlar (channel, endpoint_type, shutter_position, online) + cihaz UUID; MAC yok', async () => {
  const ctx = setup();
  ctx.ep(5).current_state = true;
  ctx.ep(1).current_position = 60;
  const list = await ctx.endpointService.getEndpointsByHome(ctx.home.id);
  assert.strictEqual(list.length, 8);
  assert.ok(list.every((e) => e.home_id === ctx.home.id));
  const e5 = list.find((e) => e.channel_index === 5);
  assert.strictEqual(e5.channel, 5);
  assert.strictEqual(e5.endpoint_type, 'light');
  assert.strictEqual(e5.type, 'light');
  assert.strictEqual(e5.current_state, true);
  assert.strictEqual(e5.device_uuid, 'AHBU-S3-0001');
  assert.strictEqual(e5.device_online, true);
  assert.strictEqual(e5.online, true);
  const e1 = list.find((e) => e.channel_index === 1);
  assert.strictEqual(e1.shutter_position, 60);
  assert.strictEqual(e1.current_position, 60);
  assert.strictEqual(e1.shutter_pair_index, 1);
  assert.ok(list.every((e) => !('mac_address' in e)), 'MAC adresi yanita konmamali');
  await expectHttp(ctx.endpointService.getEndpointsByHome('1'), 400, 'VALIDATION');
  await expectHttp(ctx.endpointService.getEndpointsByHome('bozuk'), 400, 'VALIDATION');
});

// ------------------------------------------------------------------------------------------------
// Kalibrasyon
// ------------------------------------------------------------------------------------------------

test('kalibrasyon: set_runtime ONCE yayinlanir, DB yayindan SONRA guncellenir; panjur cifti (yukari+asagi) ayni sureyi paylasir', async () => {
  const ctx = setup();
  const order = [];
  const original = ctx.world.db._exec.bind(ctx.world.db);
  ctx.world.db._exec = (tx, text, params) => {
    if (norm(text).startsWith('UPDATE endpoints SET shutter_duration_sec')) order.push(`db@${ctx.bridge.commands.length}`);
    return original(tx, text, params);
  };

  const r = await ctx.update(ctx.ep(1), { shutter_duration_sec: 24 });
  assert.deepStrictEqual(order, ['db@1'], 'yayin DB guncellemesinden once olmali');
  assert.deepStrictEqual(ctx.bridge.commands[0], {
    topicId: ctx.home.mqtt_username,
    obj: { cmd: 'set_runtime', shutter: 1, sec: 24, id: r.command_id },
  });
  assert.strictEqual(r.delivered, true);
  assert.strictEqual(r.shutter_duration_sec, 24);
  assert.strictEqual(ctx.ep(1).shutter_duration_sec, 24);
  assert.strictEqual(ctx.ep(2).shutter_duration_sec, 24, 'ayni panjurun diger yonu de guncellenir');
  assert.strictEqual(ctx.ep(3).shutter_duration_sec, 20, 'diger panjura dokunulmaz');
  // diger evin ayni kanali etkilenmez
  assert.ok(ctx.otherEps.every((e) => e.shutter_duration_sec === null || e.shutter_duration_sec === 20));
});

test('kalibrasyon sinirlari: 1..300 tamsayi; 0, 301, ondalik, metin, null hata; sinirlar kabul', async () => {
  const ctx = setup();
  for (const v of [1, 300]) {
    const r = await ctx.update(ctx.ep(3), { shutter_duration_sec: v });
    assert.strictEqual(r.shutter_duration_sec, v);
  }
  const before = ctx.bridge.commands.length;
  for (const v of [0, 301, -5, 24.5, '24', 'abc', NaN, true, {}, []]) {
    await expectHttp(ctx.update(ctx.ep(3), { shutter_duration_sec: v }), 400, 'VALIDATION');
  }
  assert.strictEqual(ctx.bridge.commands.length, before, 'gecersiz degerde yayin yapilmaz');
  assert.strictEqual(ctx.ep(3).shutter_duration_sec, 300);
});

test('kalibrasyon yalniz PANJUR kanallarinda; isik kanalinda 400', async () => {
  const ctx = setup();
  await expectHttp(ctx.update(ctx.ep(5), { shutter_duration_sec: 20 }), 400, 'VALIDATION');
  assert.strictEqual(ctx.bridge.commands.length, 0);
});

test('kalibrasyon: cihaz CEVRIMDISI -> 409 ve DB DEGISMEZ (cihaz ile DB sapmaz)', async () => {
  const ctx = setup({ online: false });
  await expectHttp(ctx.update(ctx.ep(1), { shutter_duration_sec: 33 }), 409, 'DEVICE_OFFLINE', { device_online: false });
  assert.strictEqual(ctx.ep(1).shutter_duration_sec, 20);
  assert.strictEqual(ctx.bridge.commands.length, 0);
});

test('kalibrasyon: yayin hatasi YUTULMAZ (502) ve DB degismez; broker yoksa 502', async () => {
  const ctx = setup();
  ctx.bridge.failPublish = true;
  await expectHttp(ctx.update(ctx.ep(1), { shutter_duration_sec: 33 }), 502, 'BROKER_UNAVAILABLE');
  assert.strictEqual(ctx.ep(1).shutter_duration_sec, 20);
  ctx.bridge.failPublish = false;
  ctx.bridge.connected = false;
  await expectHttp(ctx.update(ctx.ep(1), { shutter_duration_sec: 33 }), 502, 'BROKER_UNAVAILABLE');
  assert.strictEqual(ctx.ep(1).shutter_duration_sec, 20);
});

test('camelCase (shutterDurationSec) gecis donemi icin kabul edilir', async () => {
  const ctx = setup();
  const r = await ctx.update(ctx.ep(1), { shutterDurationSec: 18 });
  assert.strictEqual(r.shutter_duration_sec, 18);
});

// ------------------------------------------------------------------------------------------------
// Ad / oda / tip
// ------------------------------------------------------------------------------------------------

test('kanal adi ve oda cihaz cevrimdisiyken de degistirilir (yayin gerekmez); yalnizca verilen alan guncellenir', async () => {
  const ctx = setup({ online: false });
  const r = await ctx.update(ctx.ep(5), { name: '  Oturma Odasi Avize  ' });
  assert.strictEqual(r.name, 'Oturma Odasi Avize');
  assert.strictEqual(r.room, 'Salon', 'oda dokunulmaz');
  const r2 = await ctx.update(ctx.ep(5), { room: 'Misafir Odasi' });
  assert.strictEqual(r2.room, 'Misafir Odasi');
  assert.strictEqual(r2.name, 'Oturma Odasi Avize');
  assert.strictEqual(ctx.bridge.commands.length, 0);
});

test('ad/oda dogrulamasi: bos, cok uzun, metin olmayan reddedilir; guncellenecek alan yoksa 400', async () => {
  const ctx = setup();
  for (const name of ['', '   ', 'x'.repeat(101), 42, true, {}]) {
    await expectHttp(ctx.update(ctx.ep(5), { name }), 400, 'VALIDATION');
  }
  for (const room of ['', 'x'.repeat(51), 7]) {
    await expectHttp(ctx.update(ctx.ep(5), { room }), 400, 'VALIDATION');
  }
  await expectHttp(ctx.update(ctx.ep(5), {}), 400, 'VALIDATION');
  await expectHttp(ctx.update(ctx.ep(5), { name: null, room: null }), 400, 'VALIDATION');
  await expectHttp(ctx.endpointService.updateEndpoint({ actor: ctx.actor('owner'), homeId: ctx.home.id, endpointId: ctx.ep(5).id, patch: null }), 400, 'VALIDATION');
  await expectHttp(ctx.endpointService.updateEndpoint({ actor: ctx.actor('owner'), homeId: ctx.home.id, endpointId: ctx.ep(5).id, patch: [1] }), 400, 'VALIDATION');
  assert.strictEqual(ctx.ep(5).name, 'Salon Aydınlatma');
});

test('tip yalnizca light<->plug degisir; panjur/darbe tipi DB\'den degistirilemez; ayni tip no-op', async () => {
  const ctx = setup();
  const r = await ctx.update(ctx.ep(5), { type: 'plug' });
  assert.strictEqual(r.type, 'plug');
  assert.strictEqual(r.endpoint_type, 'plug');
  await ctx.update(ctx.ep(5), { type: 'light' });
  await ctx.update(ctx.ep(5), { name: 'x', type: 'light' }); // ayni tip
  for (const type of ['shutter', 'impulse', 'robot']) {
    await expectHttp(ctx.update(ctx.ep(5), { type }), 400, 'VALIDATION');
  }
  await expectHttp(ctx.update(ctx.ep(1), { type: 'light' }), 400, 'VALIDATION'); // panjurdan isiga
  assert.strictEqual(ctx.ep(1).type, 'shutter');
});

test('klemens eslemesi alanlari (channel, channel_index, device_id, shutter_pair_index) degistirilemez', async () => {
  const ctx = setup();
  for (const field of ['channel', 'channel_index', 'device_id', 'shutter_pair_index']) {
    await expectHttp(ctx.update(ctx.ep(5), { name: 'x', [field]: 7 }), 400, 'VALIDATION');
  }
  assert.strictEqual(ctx.ep(5).channel_index, 5);
});

test('yetki: aile sakini ve misafir kalibrasyon/ad/oda degistiremez (403); bilinmeyen rol 403; owner/staff/oturum/super olur', async () => {
  const ctx = setup();
  for (const access of ['resident', 'guest', 'hacker', null]) {
    await expectHttp(ctx.update(ctx.ep(5), { name: 'x' }, access), 403, 'FORBIDDEN');
    await expectHttp(ctx.update(ctx.ep(1), { shutter_duration_sec: 30 }, access), 403, 'FORBIDDEN');
  }
  assert.strictEqual(ctx.ep(5).name, 'Salon Aydınlatma');
  for (const access of ['owner', 'service_user', 'service_session', 'super_user']) {
    const r = await ctx.update(ctx.ep(5), { name: `ad-${access}` }, access);
    assert.strictEqual(r.name, `ad-${access}`);
  }
});

test('IDOR: baska evin kanali bu ev uzerinden guncellenemez/kontrol edilemez (404)', async () => {
  const ctx = setup();
  const foreign = ctx.otherEps[4];
  await expectHttp(ctx.update(foreign, { name: 'calindi' }), 404, 'NOT_FOUND');
  assert.notStrictEqual(foreign.name, 'calindi');
  await expectHttp(
    ctx.endpointService.controlEndpoint({ actor: ctx.actor('owner'), homeId: ctx.home.id, endpointId: foreign.id, commandData: { cmd: 'toggle' } }),
    404, 'NOT_FOUND'
  );
  assert.strictEqual(ctx.bridge.commands.length, 0);
  await expectHttp(ctx.endpointService.updateEndpoint({ actor: ctx.actor('owner'), homeId: ctx.home.id, endpointId: 'bozuk', patch: { name: 'x' } }), 400, 'VALIDATION');
});

// ------------------------------------------------------------------------------------------------
// controlEndpoint: istek govdesi -> firmware komutu -> sendCommand (sema + rol + cevrimdisi + yayin)
// ------------------------------------------------------------------------------------------------

test('kontrol: isik state/toggle/on/off ve panjur up/down/stop/pos dogru firmware komutuna cevrilir', async () => {
  const ctx = setup();
  const control = (endpoint, commandData, access = 'owner') =>
    ctx.endpointService.controlEndpoint({ actor: ctx.actor(access), homeId: ctx.home.id, endpointId: endpoint.id, commandData });
  const last = () => { const { id, ...rest } = ctx.bridge.commands[ctx.bridge.commands.length - 1].obj; return rest; };

  await control(ctx.ep(5), { state: true });
  assert.deepStrictEqual(last(), { relay: 5, state: true });
  await control(ctx.ep(5), { state: 'false' });
  assert.deepStrictEqual(last(), { relay: 5, state: false });
  await control(ctx.ep(6), { cmd: 'toggle' });
  assert.deepStrictEqual(last(), { relay: 6, cmd: 'toggle' });
  await control(ctx.ep(7), { cmd: 'on' });
  assert.deepStrictEqual(last(), { relay: 7, state: true });
  await control(ctx.ep(7), { command: 'off' });
  assert.deepStrictEqual(last(), { relay: 7, state: false });

  // panjur: pair = shutter_pair_index (1 tabanli); her iki satir (yukari/asagi) ayni panjur
  await control(ctx.ep(1), { cmd: 'up' });
  assert.deepStrictEqual(last(), { shutter: 1, cmd: 'up' });
  await control(ctx.ep(4), { cmd: 'stop' });
  assert.deepStrictEqual(last(), { shutter: 2, cmd: 'stop' });
  await control(ctx.ep(3), { pos: 40 });
  assert.deepStrictEqual(last(), { shutter: 2, pos: 40 });
  await control(ctx.ep(3), { pos: '75' });
  assert.deepStrictEqual(last(), { shutter: 2, pos: 75 });
  await control(ctx.ep(1), { cmd: 'pos', value: 10 });
  assert.deepStrictEqual(last(), { shutter: 1, pos: 10 });
});

test('kontrol: gecersiz/bos komut 400; sema ihlali (pos 101, bilinmeyen cmd) 400; cevrimdisi 409', async () => {
  const ctx = setup();
  const control = (endpoint, commandData, o = {}) =>
    ctx.endpointService.controlEndpoint({ actor: ctx.actor('owner'), homeId: ctx.home.id, endpointId: endpoint.id, commandData, ...o });
  await expectHttp(control(ctx.ep(5), {}), 400, 'VALIDATION');
  await expectHttp(control(ctx.ep(5), null), 400, 'VALIDATION');
  await expectHttp(control(ctx.ep(5), { state: 'ON' }), 400, 'VALIDATION');
  await expectHttp(control(ctx.ep(1), { pos: 101 }), 400, 'VALIDATION');
  await expectHttp(control(ctx.ep(1), { cmd: 'open' }), 400, 'VALIDATION');
  assert.strictEqual(ctx.bridge.commands.length, 0);

  const off = setup({ online: false });
  await expectHttp(
    off.endpointService.controlEndpoint({ actor: off.actor('owner'), homeId: off.home.id, endpointId: off.ep(5).id, commandData: { state: true } }),
    409, 'DEVICE_OFFLINE'
  );
});

test('kontrol: rol matrisi sendCommand\'dan gecer (misafir temel kontrol yapabilir; kalibrasyon komutu yapamaz)', async () => {
  const ctx = setup();
  const r = await ctx.endpointService.controlEndpoint({
    actor: ctx.actor('guest'), homeId: ctx.home.id, endpointId: ctx.ep(5).id, commandData: { state: true },
  });
  assert.strictEqual(r.delivered, true);
  // misafir kalibrasyon komutu (set_runtime) gonderemez
  await expectHttp(
    ctx.deviceService.sendCommand({
      actor: ctx.actor('guest'), homeId: ctx.home.id, deviceRef: ctx.dev.id, command: { cmd: 'set_runtime', shutter: 1, sec: 5 },
    }),
    403, 'FORBIDDEN'
  );
  assert.strictEqual(ctx.bridge.commands.length, 1, 'yalnizca temel kontrol yayinlandi');
});

test('kaynak: eski parseInt(home_id) ve LIMIT 1 yedekleri yok; sabit sutun listesi kullanilir', () => {
  const src = require('fs').readFileSync(require.resolve('../../src/services/endpoint_service'), 'utf8');
  assert.ok(!/parseInt\(homeId/.test(src));
  assert.ok(!/SELECT e\.\*/.test(src), 'e.* yerine acik sutun listesi (sozlesme sabit kalsin)');
  assert.ok(!/mac_address/.test(src));
});
