'use strict';

// DAIRE-03 (+ DAIRE-K3): panjur kalibrasyonu (PUT endpoints/:id shutter_duration_sec) cihaz ONAYINI bekler.
// Firmware basarili komutta state.last_id'yi komut kimligine esitler ve hemen yayinlar; panjur hareket halindeyken /
// cift yapilandirilmamisken komutu REDDEDER ve last_id DEGISMEZ. Sunucu onay gelmezse 409 CONFLICT doner ve DB'ye
// YAZMAZ (pano ile DB sapmaz); onay gelirse DB bugunku gibi yazilir.

const test = require('node:test');
const assert = require('node:assert');

const { createWorld, createServices, setTestEnv, expectHttp } = require('./_world');
const { EndpointService } = require('../../src/services/endpoint_service');

const NOT_APPLIED = 'Pano panjur süresini uygulamadı (panjur hareket halinde olabilir). Panjuru durdurup yeniden deneyin.';

function setup() {
  setTestEnv();
  const world = createWorld();
  const svc = createServices(world);
  const h = world.helpers;
  const owner = h.addUser({ email: 'sahip@example.test' });
  const home = h.addHome({ name: 'Ev', owner });
  const dev = h.addDevice({ home, uuid: 'AHBU-S3-0001', mac: 'E8:F6:0A:00:00:01', online: true });
  const eps = h.addEndpoints(home, dev, 8);
  const endpointService = new EndpointService({ db: world.db, deviceService: svc.deviceService, mqttBridge: svc.bridge });
  const actor = { userId: owner.id, globalRole: 'user', ip: '10.0.0.1', access: 'owner' };
  const ep = (channel) => eps.find((e) => e.channel_index === channel);
  const update = (endpoint, patch) => endpointService.updateEndpoint({ actor, homeId: home.id, endpointId: endpoint.id, patch });
  return { world, ...svc, home, dev, eps, ep, update };
}

test('onay gelirse: 200 + DB yazilir; onay bekleyicisi YAYINDAN ONCE kurulur (4000 ms), komut kimligiyle eslesir', async () => {
  const ctx = setup();
  const r = await ctx.update(ctx.ep(1), { shutter_duration_sec: 24 });

  assert.strictEqual(r.delivered, true);
  assert.strictEqual(r.shutter_duration_sec, 24);
  assert.strictEqual(ctx.ep(1).shutter_duration_sec, 24);
  assert.strictEqual(ctx.ep(2).shutter_duration_sec, 24, 'ciftin diger yonu de yazilir');

  assert.strictEqual(ctx.bridge.ackWaits.length, 1, 'onay beklenmeli');
  const wait = ctx.bridge.ackWaits[0];
  assert.deepStrictEqual(wait, { topicId: ctx.home.mqtt_username, commandId: r.command_id, timeoutMs: 4000, afterPublish: false });
  assert.strictEqual(ctx.bridge.commands.length, 1);
  assert.strictEqual(ctx.bridge.commands[0].obj.id, r.command_id);
});

test('onay GELMEZSE (pano reddetti / hareket halinde): 409 CONFLICT + acik mesaj; DB DEGISMEZ (iki satir da)', async () => {
  const ctx = setup();
  ctx.bridge.ackMode = 'never';
  const err = await expectHttp(ctx.update(ctx.ep(1), { shutter_duration_sec: 33 }), 409, 'CONFLICT', { reason: 'NOT_APPLIED' });
  assert.strictEqual(err.message, NOT_APPLIED);
  assert.strictEqual(ctx.bridge.commands.length, 1, 'komut yayinlandi (pano reddetti)');
  assert.strictEqual(ctx.ep(1).shutter_duration_sec, 20, 'DB yazilmamali');
  assert.strictEqual(ctx.ep(2).shutter_duration_sec, 20, 'cift satiri da yazilmamali');
  const writes = ctx.world.db.sqls().filter((s) => /^UPDATE endpoints/.test(s));
  assert.deepStrictEqual(writes, [], 'endpoints UPDATE calismamali');
});

test('onay gelmeyen istekte ayni govdedeki ad/oda da yazilmaz (istek butunuyle reddedilir)', async () => {
  const ctx = setup();
  ctx.bridge.ackMode = 'never';
  await expectHttp(ctx.update(ctx.ep(2), { shutter_duration_sec: 30, name: 'Salon Aşağı Yeni' }), 409, 'CONFLICT');
  assert.strictEqual(ctx.ep(2).name, 'Salon Panjur Aşağı');
  assert.strictEqual(ctx.ep(2).shutter_duration_sec, 20);
});

test('yayin hatasi: 502 BROKER_UNAVAILABLE; onay bekleyicisi iptal edilir (sizinti yok), DB degismez', async () => {
  const ctx = setup();
  ctx.bridge.failPublish = true;
  await expectHttp(ctx.update(ctx.ep(1), { shutter_duration_sec: 33 }), 502, 'BROKER_UNAVAILABLE');
  assert.strictEqual(ctx.bridge.ackWaits.length, 1, 'bekleyici yayindan once kuruldu');
  assert.deepStrictEqual(ctx.bridge.ackCancels, [{ topicId: ctx.home.mqtt_username, commandId: ctx.bridge.ackWaits[0].commandId }]);
  assert.strictEqual(ctx.ep(1).shutter_duration_sec, 20);
});

test('sure icermeyen PUT (ad/oda/tip) onay BEKLEMEZ ve yayin yapmaz', async () => {
  const ctx = setup();
  ctx.bridge.ackMode = 'never';
  const r = await ctx.update(ctx.ep(5), { name: 'Salon Avize' });
  assert.strictEqual(r.name, 'Salon Avize');
  assert.strictEqual(ctx.bridge.ackWaits.length, 0);
  assert.strictEqual(ctx.bridge.commands.length, 0);
});
