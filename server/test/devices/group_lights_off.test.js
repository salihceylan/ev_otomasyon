'use strict';

// DAIRE-01: toplu "isiklari kapat" (all_lights_off / all_off) komutu firmware'de priz tipi olmadigi icin uygulamada
// 'plug' (priz) diye isaretlenen roleleri de kapatirdi. Evde priz varsa sendCommand "Hepsini Kapat" (peace_service)
// ile AYNI kurali uygular: yalniz ACIK isik roleleri icin {relay:N, state:false, id}. Priz yoksa davranis AYNEN.

const test = require('node:test');
const assert = require('node:assert');

const { createWorld, createServices, setTestEnv, expectHttp } = require('./_world');

function setup({ plug = false, open = [] } = {}) {
  setTestEnv();
  const world = createWorld();
  const svc = createServices(world);
  const h = world.helpers;
  const owner = h.addUser({ email: 'sahip@example.test' });
  const home = h.addHome({ name: 'Ev', owner });
  const dev = h.addDevice({ home, uuid: 'AHBU-S3-0001', mac: 'E8:F6:0A:00:00:01', online: true });
  const eps = h.addEndpoints(home, dev, 8);
  const ep = (n) => eps.find((e) => e.channel_index === n);
  if (plug) {
    ep(8).type = 'plug'; // buzdolabi/modem prizi: kapanmamali
    ep(8).current_state = true;
  }
  for (const n of open) ep(n).current_state = true;
  const actor = (access = 'owner') => ({ userId: owner.id, globalRole: 'user', ip: '10.0.0.1', access });
  const send = (command, access) => svc.deviceService.sendCommand({ actor: actor(access), homeId: home.id, deviceRef: dev.id, command });
  return { world, ...svc, home, dev, eps, ep, send };
}

test('priz VARSA all_lights_off: yalniz ACIK isik roleleri tek tek kapanir; priz ve kapali lambalar dokunulmaz', async () => {
  const ctx = setup({ plug: true, open: [5, 7] });
  const r = await ctx.send({ cmd: 'all_lights_off' });

  const objs = ctx.bridge.commands.map((c) => c.obj);
  assert.deepStrictEqual(objs.map(({ id, ...rest }) => rest), [{ relay: 5, state: false }, { relay: 7, state: false }]);
  assert.ok(!objs.some((o) => o.cmd === 'all_lights_off'), 'priz varken toplu komut YAYINLANMAZ');
  assert.ok(!objs.some((o) => o.relay === 8), 'priz kapatilmaz');
  assert.ok(ctx.bridge.commands.every((c) => c.topicId === ctx.home.mqtt_username));
  // yanit istemciyle uyumlu: delivered + device_online + command_id (ilk komut) + command_ids
  assert.strictEqual(r.delivered, true);
  assert.strictEqual(r.device_online, true);
  assert.deepStrictEqual(r.command_ids, objs.map((o) => o.id));
  assert.strictEqual(r.command_id, objs[0].id);
  assert.ok(r.command_ids.every((id) => /^[A-Za-z0-9._:-]{1,24}$/.test(id)));
  // komut hatti DB'ye iyimser yazmaz
  assert.strictEqual(ctx.ep(5).current_state, true);
});

test('all_off (esanlamli) ayni kurali izler', async () => {
  const ctx = setup({ plug: true, open: [6] });
  await ctx.send({ cmd: 'all_off' });
  assert.deepStrictEqual(ctx.bridge.commands.map(({ obj: { id, ...rest } }) => rest), [{ relay: 6, state: false }]);
});

test('priz YOKSA davranis AYNEN: tek {cmd:"all_lights_off"}; istemci kimligi korunur', async () => {
  const ctx = setup({ plug: false, open: [5, 6] });
  const r = await ctx.send({ cmd: 'all_lights_off', id: 'istemci-1' });
  assert.deepStrictEqual(ctx.bridge.commands.map((c) => c.obj), [{ cmd: 'all_lights_off', id: 'istemci-1' }]);
  assert.deepStrictEqual(r, { delivered: true, device_online: true, command_id: 'istemci-1' });

  const ctx2 = setup({ plug: false });
  await ctx2.send({ cmd: 'all_off' });
  assert.deepStrictEqual(ctx2.bridge.commands.map((c) => c.obj.cmd), ['all_off'], 'kapali evde de toplu komut aynen gider');
});

test('priz var, acik lamba YOK: komut yayinlanmaz; yanit delivered:true, command_id:null, no_change:true', async () => {
  const ctx = setup({ plug: true });
  const r = await ctx.send({ cmd: 'all_lights_off' });
  assert.strictEqual(ctx.bridge.commands.length, 0, 'yalniz priz acik: toplu komut prizi kapatirdi, hicbir sey gonderilmez');
  assert.deepStrictEqual(r, { delivered: true, device_online: true, command_id: null, command_ids: [], no_change: true });
});

test('diger toplu komutlar (panjur) priz kuralindan etkilenmez', async () => {
  const ctx = setup({ plug: true, open: [5] });
  await ctx.send({ cmd: 'all_shutters_down' });
  assert.deepStrictEqual(ctx.bridge.commands.map((c) => c.obj.cmd), ['all_shutters_down']);
});

test('yetki ve cevrimdisi kurallari degismez: misafir 403; cevrimdisi 409 (yayin yok)', async () => {
  const ctx = setup({ plug: true, open: [5] });
  await expectHttp(ctx.send({ cmd: 'all_lights_off' }, 'guest'), 403, 'FORBIDDEN');
  ctx.dev.is_online = false;
  await expectHttp(ctx.send({ cmd: 'all_lights_off' }), 409, 'DEVICE_OFFLINE');
  assert.strictEqual(ctx.bridge.commands.length, 0);
});

test('yayin hatasi YUTULMAZ: 502 BROKER_UNAVAILABLE', async () => {
  const ctx = setup({ plug: true, open: [5] });
  ctx.bridge.failPublish = true;
  await expectHttp(ctx.send({ cmd: 'all_lights_off' }), 502, 'BROKER_UNAVAILABLE');
});
