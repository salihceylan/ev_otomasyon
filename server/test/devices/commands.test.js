'use strict';

// B1 / B2 / B11: komut hatti (sendCommand, cocuk kilidi, toplu kapatma) - sema, rol matrisi, cevrimdisi 409, hata yutulmaz

const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');

const { createWorld, createServices, setTestEnv, expectHttp } = require('./_world');
const { norm } = require('./_fake_db');

function setup({ online = true } = {}) {
  setTestEnv();
  const world = createWorld();
  const svc = createServices(world);
  const h = world.helpers;
  const owner = h.addUser({ email: 'sahip@example.test' });
  const home = h.addHome({ name: 'Ev', owner });
  const otherHome = h.addHome({ name: 'Baska Ev' });
  const dev = h.addDevice({ home, uuid: 'AHBU-S3-0001', mac: 'E8:F6:0A:00:00:01', online });
  const otherDev = h.addDevice({ home: otherHome, uuid: 'AHBU-S3-0002', mac: 'E8:F6:0A:00:00:02', online: true });
  const eps = h.addEndpoints(home, dev, 8);
  const actor = (access) => ({ userId: owner.id, globalRole: 'user', ip: '10.0.0.1', access });
  const send = (command, o = {}) =>
    svc.deviceService.sendCommand({ actor: actor('owner'), homeId: home.id, deviceRef: dev.id, command, ...o });
  return { world, ...svc, owner, home, otherHome, dev, otherDev, eps, actor, send };
}

// ------------------------------------------------------------------------------------------------
test('basarili komut: broker\'a firmware sozlugunde yayinlanir, { delivered, device_online, command_id } doner', async () => {
  const ctx = setup();
  const r = await ctx.send({ relay: 5, state: true });
  assert.strictEqual(r.delivered, true);
  assert.strictEqual(r.device_online, true);
  assert.match(r.command_id, /^[A-Za-z0-9_-]{12}$/);

  assert.strictEqual(ctx.bridge.commands.length, 1);
  const pub = ctx.bridge.commands[0];
  assert.strictEqual(pub.topicId, ctx.home.mqtt_username, 'konu kimligi DB\'deki evden gelir (istemci girdisinden degil)');
  assert.deepStrictEqual(pub.obj, { relay: 5, state: true, id: r.command_id });
});

test('istemci komut kimligi (id) varsa korunur ve yanitla ayni doner', async () => {
  const ctx = setup();
  const r = await ctx.send({ relay: 5, cmd: 'toggle', id: 'abc-123' });
  assert.strictEqual(r.command_id, 'abc-123');
  assert.deepStrictEqual(ctx.bridge.commands[0].obj, { relay: 5, cmd: 'toggle', id: 'abc-123' });
});

test('her gecerli komut turu yayinlanir (relay, panjur, toplu, cocuk kilidi, kalibrasyon)', async () => {
  const ctx = setup();
  const cmds = [
    { relay: 5, state: false },
    { shutter: 1, cmd: 'up' },
    { shutter: 2, pos: 40 },
    { cmd: 'all_lights_off' },
    { cmd: 'all_shutters_stop' },
    { cmd: 'set_child_lock', enabled: true },
    { cmd: 'set_runtime', shutter: 1, sec: 24 },
  ];
  for (const c of cmds) await ctx.send(c);
  assert.deepStrictEqual(
    ctx.bridge.commands.map((p) => { const { id, ...rest } = p.obj; return rest; }),
    cmds
  );
  assert.ok(ctx.bridge.commands.every((p) => typeof p.obj.id === 'string' && p.obj.id.length <= 24));
  // komut hatti DB DURUMUNU onceden yazmaz (gercek durum cihazin state mesajiyla gelir). Tek istisna: cocuk kilidi
  // NIYETI (homes.child_lock_requested*) + denetim kaydi (ayrintili testler: child_lock.test.js).
  const writes = ctx.world.db.sqls().filter((s) => /^(UPDATE|INSERT|DELETE)/.test(s));
  assert.ok(writes.every((s) => /child_lock_requested|device_audit_logs/.test(s)), writes.join(' | '));
  assert.ok(writes.some((s) => /child_lock_requested/.test(s)));
});

test('sema ihlali: bilinmeyen alan/komut, tip, aralik -> 400 VALIDATION; yayin ve DB sorgusu YOK', async () => {
  const ctx = setup();
  const bad = [
    { relay: 5, state: 'ON' }, { relay: 0, state: true }, { relay: 41, state: true }, { relay: 5, state: true, extra: 1 },
    { shutter: 1, pos: 101 }, { shutter: 1, pos: -1 }, { shutter: 1, cmd: 'open' }, { cmd: 'reboot' }, { cmd: 'factory_reset' },
    { cmd: 'set_runtime', shutter: 1, sec: 301 }, { cmd: 'set_child_lock' }, {}, null, 'relay', [], { relay: 5 },
  ];
  for (const c of bad) await expectHttp(ctx.send(c), 400, 'VALIDATION');
  assert.strictEqual(ctx.bridge.commands.length, 0);
  assert.strictEqual(ctx.world.db.log.length, 0, 'gecersiz komut icin DB\'ye gidilmemeli');
});

// ------------------------------------------------------------------------------------------------
test('rol matrisi (servis katmani): misafir toplu komut/cocuk kilidi YOK; aile sakini kalibrasyon YOK', async () => {
  const ctx = setup();
  const asRole = (access, command) => ctx.send(command, { actor: ctx.actor(access) });

  // temel kontrol: herkes
  for (const access of ['super_user', 'service_user', 'service_session', 'owner', 'resident', 'guest']) {
    const r = await asRole(access, { relay: 5, state: true });
    assert.strictEqual(r.delivered, true, access);
  }
  // toplu / cocuk kilidi: misafir hariç
  for (const command of [{ cmd: 'all_off' }, { cmd: 'all_shutters_up' }, { cmd: 'set_child_lock', enabled: true }]) {
    for (const access of ['super_user', 'service_user', 'service_session', 'owner', 'resident']) {
      assert.strictEqual((await asRole(access, command)).delivered, true, `${access} ${command.cmd}`);
    }
    await expectHttp(asRole('guest', command), 403, 'FORBIDDEN');
  }
  // kalibrasyon: owner/staff/servis oturumu/super; resident ve misafir HAYIR
  const calibrate = { cmd: 'set_runtime', shutter: 1, sec: 20 };
  for (const access of ['super_user', 'service_user', 'service_session', 'owner']) {
    assert.strictEqual((await asRole(access, calibrate)).delivered, true, access);
  }
  await expectHttp(asRole('resident', calibrate), 403, 'FORBIDDEN');
  await expectHttp(asRole('guest', calibrate), 403, 'FORBIDDEN');
  // beyaz liste: bilinmeyen/bos rol = hicbir yetki
  for (const access of ['admin', '', null, undefined]) {
    await expectHttp(asRole(access, { relay: 5, state: true }), 403, 'FORBIDDEN');
  }
});

test('yetkisiz rolde yayin YAPILMAZ', async () => {
  const ctx = setup();
  const before = ctx.bridge.commands.length;
  await expectHttp(ctx.send({ cmd: 'all_off' }, { actor: ctx.actor('guest') }), 403, 'FORBIDDEN');
  assert.strictEqual(ctx.bridge.commands.length, before);
});

// ------------------------------------------------------------------------------------------------
test('CIHAZ CEVRIMDISI: 409 DEVICE_OFFLINE (device_online:false), yayin yapilmaz', async () => {
  const ctx = setup({ online: false });
  const e = await expectHttp(ctx.send({ relay: 5, state: true }), 409, 'DEVICE_OFFLINE', { device_online: false });
  assert.match(e.message, /çevrimdışı/);
  assert.strictEqual(ctx.bridge.commands.length, 0);
});

test('broker baglantisi yoksa 502 BROKER_UNAVAILABLE; yayin hatasi YUTULMAZ (basarili gibi donulmez)', async () => {
  const ctx = setup();
  ctx.bridge.connected = false;
  await expectHttp(ctx.send({ relay: 5, state: true }), 502, 'BROKER_UNAVAILABLE');

  ctx.bridge.connected = true;
  ctx.bridge.failPublish = true;
  const e = await expectHttp(ctx.send({ relay: 5, state: true }), 502, 'BROKER_UNAVAILABLE');
  assert.ok(!/broker down/.test(e.message), 'ic hata mesaji sizmamali');
  assert.strictEqual(ctx.bridge.commands.length, 0);
});

test('IDOR: baska evin cihazina komut gonderilemez (404); cihaz referansi UUID veya device_uuid olabilir', async () => {
  const ctx = setup();
  // otherDev baska evde: bu ev uzerinden erisim 404
  await expectHttp(ctx.send({ relay: 5, state: true }, { deviceRef: ctx.otherDev.id }), 404, 'NOT_FOUND');
  await expectHttp(ctx.send({ relay: 5, state: true }, { deviceRef: 'AHBU-S3-0002' }), 404, 'NOT_FOUND');
  assert.strictEqual(ctx.bridge.commands.length, 0);

  // dogru cihaz: DB id ile ve device_uuid ile
  assert.strictEqual((await ctx.send({ relay: 5, state: true }, { deviceRef: ctx.dev.id })).delivered, true);
  assert.strictEqual((await ctx.send({ relay: 5, state: true }, { deviceRef: 'ahbu-s3-0001' })).delivered, true);
  assert.ok(ctx.bridge.commands.every((c) => c.topicId === ctx.home.mqtt_username));

  // bozuk referans / bozuk home_id
  await expectHttp(ctx.send({ relay: 5, state: true }, { deviceRef: 'bozuk' }), 400, 'VALIDATION');
  await expectHttp(ctx.send({ relay: 5, state: true }, { deviceRef: '' }), 400, 'VALIDATION');
  await expectHttp(ctx.send({ relay: 5, state: true }, { homeId: 'bozuk' }), 400, 'VALIDATION');
});

test('panjur kanallari role komutuyla surulemez (cift yon riski); panjur komutu ve isik rolesi calisir', async () => {
  const ctx = setup();
  await expectHttp(ctx.send({ relay: 1, state: true }), 400, 'VALIDATION'); // kanal 1 = panjur yukari
  await expectHttp(ctx.send({ relay: 2, cmd: 'toggle' }), 400, 'VALIDATION');
  assert.strictEqual((await ctx.send({ shutter: 1, cmd: 'up' })).delivered, true);
  assert.strictEqual((await ctx.send({ relay: 5, state: true })).delivered, true);
  assert.strictEqual(ctx.bridge.commands.length, 2);
});

// ------------------------------------------------------------------------------------------------
// Toplu kapatma (huzur bildirimi)
// ------------------------------------------------------------------------------------------------

// v2 (WP-H): mantik peace_service.js'te (test/peace/**, gercek PostgreSQL: test/peace/peace_service_pg.test.js); burada
// DeviceService'in payi + uctan uca baglanti sinanir: yetki, canli veriye gore komut uretimi, "iyimser DB yazimi YOK", bildirim cozme.

test('hepsini kapat (v2): priz YOKSA tek {cmd:"all_lights_off"}; GERCEK acik lamba sayisi doner; DB iyimser yazilmaz, elle kayit satiri eklenir', async () => {
  const ctx = setup();
  const ep = (n) => ctx.eps.find((e) => e.channel_index === n);
  ep(5).current_state = true;
  ep(6).current_state = true;
  ep(7).current_state = true;

  const r = await ctx.deviceService.closeAllOpenLights({ actor: ctx.actor('owner'), homeId: ctx.home.id });
  assert.strictEqual(r.closed_count, 3, 'yalniz acik LAMBA sayisi (panjur sayilmaz)');
  assert.strictEqual(r.delivered, true);
  assert.strictEqual(r.nothing_to_do, false);
  assert.strictEqual(ctx.bridge.commands.length, 1);
  assert.deepStrictEqual(ctx.bridge.commands[0].obj, { cmd: 'all_lights_off', id: r.command_id });
  assert.ok(!('channels' in ctx.bridge.commands[0].obj) && !('timestamp' in ctx.bridge.commands[0].obj));

  // gercek durum cihazin state yankisiyla gelir: sunucu endpoints'e IYIMSER yazmaz (v1 yaziyordu)
  assert.ok([5, 6, 7].every((n) => ep(n).current_state === true));
  const logs = ctx.world.state.peace_notification_logs;
  assert.strictEqual(logs.length, 1);
  assert.strictEqual(logs[0].status, 'manual');
  assert.strictEqual(logs[0].open_lights_count, 3);
  assert.strictEqual(logs[0].resolved_by_user, true);
});

test('hepsini kapat (v2): evde priz VARSA yalniz acik isik roleleri tek tek kapanir (priz dokunulmaz)', async () => {
  const ctx = setup();
  const ep = (n) => ctx.eps.find((e) => e.channel_index === n);
  ep(5).current_state = true;
  ep(6).current_state = true;
  ep(7).current_state = true;
  ep(8).type = 'plug'; // priz: lamba degil, kapatilmamali
  ep(8).current_state = true;

  const r = await ctx.deviceService.closeAllOpenLights({ actor: ctx.actor('owner'), homeId: ctx.home.id });
  assert.strictEqual(r.closed_count, 3);
  assert.deepStrictEqual(
    ctx.bridge.commands.map((c) => c.obj),
    [5, 6, 7].map((n, i) => ({ relay: n, state: false, id: r.command_ids[i] }))
  );
  assert.ok(!ctx.bridge.commands.some((c) => c.obj.cmd === 'all_lights_off'), 'priz varken toplu komut YOK');
});

test('hepsini kapat (v2): acik panjur cifti icin {shutter:P, cmd:"down"}; include_shutters:false ise panjura dokunulmaz', async () => {
  const ctx = setup();
  ctx.eps.find((e) => e.channel_index === 5).current_state = true;
  ctx.eps.find((e) => e.channel_index === 1).current_position = 100; // panjur 1 (iki rolenin ikisi de konum tasir)
  ctx.eps.find((e) => e.channel_index === 2).current_position = 100;

  const r = await ctx.deviceService.closeAllOpenLights({ actor: ctx.actor('owner'), homeId: ctx.home.id });
  assert.strictEqual(r.closed_shutters, 1);
  assert.deepStrictEqual(
    ctx.bridge.commands.map((c) => c.obj),
    [{ cmd: 'all_lights_off', id: r.command_ids[0] }, { shutter: 1, cmd: 'down', id: r.command_ids[1] }]
  );

  const ctx2 = setup();
  ctx2.eps.find((e) => e.channel_index === 5).current_state = true;
  ctx2.eps.find((e) => e.channel_index === 1).current_position = 100;
  const r2 = await ctx2.deviceService.closeAllOpenLights({ actor: ctx2.actor('owner'), homeId: ctx2.home.id, includeShutters: false });
  assert.strictEqual(r2.closed_shutters, 0);
  assert.deepStrictEqual(ctx2.bridge.commands.map((c) => c.obj.cmd), ['all_lights_off']);
});

test('hepsini kapat (v2): notice_id verilirse O bildirim cozulur ve kayit komut kimligine baglanir; baska evin bildirimi cozulmez', async () => {
  const ctx = setup();
  ctx.eps.find((e) => e.channel_index === 5).current_state = true;
  const logs = ctx.world.state.peace_notification_logs;
  logs.push({ id: 41, home_id: ctx.home.id, local_date: '2026-10-01', status: 'sent', resolved_at: null });
  logs.push({ id: 42, home_id: ctx.otherHome.id, local_date: '2026-10-01', status: 'sent', resolved_at: null });

  const r = await ctx.deviceService.closeAllOpenLights({ actor: ctx.actor('owner'), homeId: ctx.home.id, noticeId: 42 });
  assert.strictEqual(r.resolved, false, 'baska evin bildirimi cozulemez');
  assert.strictEqual(logs.find((l) => l.id === 42).status, 'sent');

  const ok = await ctx.deviceService.closeAllOpenLights({ actor: ctx.actor('owner'), homeId: ctx.home.id, noticeId: 41 });
  assert.strictEqual(ok.resolved, true);
  assert.strictEqual(ok.notice_id, 41);
  const row = logs.find((l) => l.id === 41);
  assert.strictEqual(row.status, 'resolved');
  assert.strictEqual(row.resolved_via, 'close_all');
  assert.strictEqual(row.command_id, ok.command_id);
  assert.strictEqual(row.resolved_by_user_id, ctx.owner.id);
});

test('hepsini kapat: yayin hatasi 502 ve DB/gunluk DEGISMEZ (eski kod DB\'yi yayindan once yaziyordu)', async () => {
  const ctx = setup();
  ctx.eps.find((e) => e.channel_index === 5).current_state = true;
  ctx.bridge.failPublish = true;
  await expectHttp(ctx.deviceService.closeAllOpenLights({ actor: ctx.actor('owner'), homeId: ctx.home.id }), 502, 'BROKER_UNAVAILABLE');
  assert.strictEqual(ctx.eps.find((e) => e.channel_index === 5).current_state, true);
  assert.strictEqual(ctx.world.state.peace_notification_logs.length, 0);
});

test('hepsini kapat: cevrimdisi 409, pano yok 404, misafir 403; kayitlara gore ACIK BIR SEY YOKSA v2 komut GONDERMEZ (nothing_to_do)', async () => {
  const off = setup({ online: false });
  await expectHttp(off.deviceService.closeAllOpenLights({ actor: off.actor('owner'), homeId: off.home.id }), 409, 'DEVICE_OFFLINE');

  const ctx = setup();
  await expectHttp(ctx.deviceService.closeAllOpenLights({ actor: ctx.actor('guest'), homeId: ctx.home.id }), 403, 'FORBIDDEN');
  const empty = ctx.world.helpers.addHome({ name: 'Bos' });
  await expectHttp(ctx.deviceService.closeAllOpenLights({ actor: ctx.actor('owner'), homeId: empty.id }), 404, 'NOT_FOUND');

  const none = await ctx.deviceService.closeAllOpenLights({ actor: ctx.actor('resident'), homeId: ctx.home.id });
  assert.strictEqual(none.closed_count, 0);
  assert.strictEqual(none.delivered, true);
  assert.strictEqual(none.nothing_to_do, true, 'sunucu kayitlarina gore kapatilacak sey yok; istemci "kapatildi" gostermemeli');
  assert.strictEqual(none.command_id, null);
  assert.strictEqual(ctx.bridge.commands.length, 0, 'komut gonderilmez (v1 yine de gonderiyordu)');
});

// ------------------------------------------------------------------------------------------------
test('kaynak kodda olmayan/eski yollar yok: mqttBridge.publish, ahbu/ konu bicimi, command konusu, yutulan MQTT hatasi', () => {
  const src = fs.readFileSync(require.resolve('../../src/services/device_service'), 'utf8');
  assert.ok(!/mqttBridge\.publish\(/.test(src));
  assert.ok(!/ahbu\/\$\{/.test(src));
  assert.ok(!/\/command`/.test(src));
  assert.ok(!/console\.warn\('MQTT/.test(src), 'MQTT hatasini sadece loglayip yutan blok kalmamali');
  assert.ok(!/catch \(mqErr\)/.test(src));
  assert.ok(/publishCommand/.test(src));
});
