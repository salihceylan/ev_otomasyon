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

// ------------------------------------------------------------------------------------------------
// D12: PUT yarisi (kilitsiz okuma -> esitleme kanali degistirir) + sure yolunda kanal sirasinda kilit
// ------------------------------------------------------------------------------------------------

const TYPE_CHANGED = 'Kanal tipi değişti; listeyi yenileyin.';

/** Kilitsiz okuma (JOIN homes) dondukten hemen sonra `afterRead` calisir (esitlemenin araya girmesi). */
function raceAfterRead(ctx, afterRead) {
  const original = ctx.world.db._exec.bind(ctx.world.db);
  let fired = false;
  ctx.world.db._exec = async (tx, text, params) => {
    const sql = norm(text);
    // Gercek PG'deki WHERE kosulunu taklit et: tip kosulu SQL'de varsa ve satir artik light/plug degilse 0 satir.
    if (sql.startsWith('UPDATE endpoints SET name = COALESCE($1, name)') && sql.includes("type IN ('light', 'plug')") && params[2] !== null) {
      const row = ctx.world.state.endpoints.find((e) => e.id === params[3] && e.home_id === params[4]);
      if (row && !['light', 'plug'].includes(row.type)) return { rows: [], rowCount: 0 };
    }
    const out = await original(tx, text, params);
    if (!fired && sql.includes('FROM endpoints e JOIN devices d ON d.id = e.device_id JOIN homes h')) {
      fired = true;
      afterRead();
    }
    return out;
  };
}

test('D12 tip yarisi: kilitsiz okumadan sonra kanal panjur olursa PUT {type:plug} 409 CONFLICT; satir plug OLMAZ, ad/oda korunur', async () => {
  const ctx = setup();
  const target = ctx.ep(5);
  raceAfterRead(ctx, () => Object.assign(target, { type: 'shutter', shutter_pair_index: 3, shutter_duration_sec: 20 }));
  const err = await expectHttp(ctx.update(target, { type: 'plug', name: 'Salon Priz' }), 409, 'CONFLICT', { reason: 'TYPE_CHANGED' });
  assert.strictEqual(err.message, TYPE_CHANGED);
  assert.strictEqual(target.type, 'shutter', 'panjur satirina plug yazilmamali');
  assert.strictEqual(target.shutter_pair_index, 3);
  assert.strictEqual(target.name, 'Salon Aydınlatma', 'ayni islemde ad da yazilmaz (geri alinir)');
});

test('D12 tip yarisi: ayni tip (light) bile kosullu yazilir; satir panjur olduysa 409 ve tip light OLMAZ', async () => {
  const ctx = setup();
  const target = ctx.ep(6);
  raceAfterRead(ctx, () => Object.assign(target, { type: 'shutter', shutter_pair_index: 3, shutter_duration_sec: 20 }));
  await expectHttp(ctx.update(target, { type: 'light', room: 'Mutfak 2' }), 409, 'CONFLICT');
  assert.strictEqual(target.type, 'shutter');
  assert.strictEqual(target.room, 'Mutfak', 'oda da yazilmaz');
});

test('D12: panjur satirinda ayni tip (shutter) + ad -> tip YAZILMAZ (NULL), ad yazilir; tipsiz ad/oda guncellemesi kosulsuz', async () => {
  const ctx = setup();
  const seen = [];
  const original = ctx.world.db._exec.bind(ctx.world.db);
  ctx.world.db._exec = (tx, text, params) => {
    if (norm(text).startsWith('UPDATE endpoints SET name = COALESCE($1, name)')) seen.push(params[2]);
    return original(tx, text, params);
  };
  const r = await ctx.update(ctx.ep(1), { name: 'Salon Panjuru', type: 'shutter' });
  assert.strictEqual(r.name, 'Salon Panjuru');
  assert.strictEqual(r.type, 'shutter');
  const r2 = await ctx.update(ctx.ep(3), { room: 'Yatak Odasi' });
  assert.strictEqual(r2.room, 'Yatak Odasi');
  assert.deepStrictEqual(seen, [null, null], 'kozmetik olmayan tip UPDATE parametresine gecmez');
});

test('D12 sure yolu: transaction BASINDA cihazin satirlari kanal sirasinda FOR UPDATE kilitlenir; UPDATE\'ler kilitten sonra', async () => {
  const ctx = setup();
  await ctx.update(ctx.ep(2), { shutter_duration_sec: 30, name: 'Salon Asagi' });
  const txQueries = ctx.world.db.log.filter((l) => l.tx !== null);
  assert.ok(txQueries.length >= 3);
  const first = txQueries[0];
  assert.match(first.sql, /^SELECT .* FROM endpoints WHERE home_id = \$1 AND device_id = \$2 ORDER BY channel_index ASC FOR UPDATE$/);
  assert.deepStrictEqual(first.params, [ctx.home.id, ctx.dev.id]);
  assert.strictEqual(ctx.ep(1).shutter_duration_sec, 30);
  assert.strictEqual(ctx.ep(2).shutter_duration_sec, 30);
  assert.strictEqual(ctx.ep(2).name, 'Salon Asagi');
});

test('D12 sure yolu: her satir transaction\'da EN COK BIR KEZ guncellenir (hedef: ad+sure tek UPDATE; cift UPDATE hedefi disarida birakir)', async () => {
  // Ayni satirin ikinci UPDATE'i (xmin = bu islem) PG'de FK yeniden denetimini (devices/homes FOR KEY SHARE) tetikler;
  // esitleme devices FOR UPDATE tutup kanal kilidinde beklerken bu 40P01 dongusu kurar (gercek PG: endpoints_pg (b)).
  const ctx = setup();
  await ctx.update(ctx.ep(2), { shutter_duration_sec: 32, name: 'Salon Asagi' });
  const ups = ctx.world.db.log.filter((l) => l.tx !== null && l.sql.startsWith('UPDATE endpoints'));
  assert.strictEqual(ups.length, 2);
  assert.ok(ups[0].sql.startsWith('UPDATE endpoints SET name = COALESCE($1, name)'));
  assert.match(ups[0].sql, /shutter_duration_sec = COALESCE\(\$6::int, shutter_duration_sec\)/);
  assert.strictEqual(ups[0].params[5], 32, 'hedefin suresi ilk UPDATE ile yazilir');
  assert.ok(ups[1].sql.startsWith('UPDATE endpoints SET shutter_duration_sec = COALESCE($1::int, shutter_duration_sec)'));
  assert.match(ups[1].sql, /AND id <> \$5$/);
  assert.strictEqual(ups[1].params[4], ctx.ep(2).id, 'cift UPDATE hedef satiri ikinci kez yazmaz');
  // ad/oda/tip yolunda sure parametresi NULL (sure kolonuna dokunulmaz)
  await ctx.update(ctx.ep(5), { name: 'Avize' });
  const last = ctx.world.db.log.filter((l) => l.sql.startsWith('UPDATE endpoints SET name')).at(-1);
  assert.strictEqual(last.params[5], null);
  assert.strictEqual(ctx.ep(5).shutter_duration_sec, null);
});

test('C14: panjur satirina ad/oda gelince ciftin IKI satirina yazilir (kilit sirasi, satir basina tek UPDATE); diger cift ve isik etkilenmez', async () => {
  const ctx = setup();
  const r = await ctx.update(ctx.ep(1), { room: 'Yatak Odasi' });
  assert.strictEqual(r.room, 'Yatak Odasi');
  assert.strictEqual(ctx.ep(2).room, 'Yatak Odasi', 'ciftin ASAGI satiri da');
  assert.strictEqual(ctx.ep(3).room, 'Oda', 'baska cift degismez');
  assert.strictEqual(ctx.ep(5).room, 'Salon', 'isik satiri degismez');
  const txQ = ctx.world.db.log.filter((l) => l.tx !== null);
  assert.match(txQ[0].sql, /ORDER BY channel_index ASC FOR UPDATE$/, 'sure yolundaki kilit sirasi');
  const ups = txQ.filter((l) => l.sql.startsWith('UPDATE endpoints'));
  assert.strictEqual(ups.length, 2, 'hedef + cift: satir basina tek UPDATE');
  assert.strictEqual(ups[1].params[4], ctx.ep(1).id, 'cift UPDATE hedefi disarida birakir');
  // ad + oda + sure birlikte: diger satir TEK UPDATE'te hepsini alir
  ctx.world.db.log.length = 0;
  await ctx.update(ctx.ep(4), { name: 'Oda Panjuru', room: 'Calisma', shutter_duration_sec: 33 });
  for (const ch of [3, 4]) {
    assert.deepStrictEqual([ctx.ep(ch).name, ctx.ep(ch).room, ctx.ep(ch).shutter_duration_sec], ['Oda Panjuru', 'Calisma', 33], `kanal ${ch}`);
  }
  assert.strictEqual(ctx.world.db.log.filter((l) => l.tx !== null && l.sql.startsWith('UPDATE endpoints')).length, 2);
});

test('D12: ad/oda/tip guncellemesinde kilit sorgusu YOK (tek satir UPDATE)', async () => {
  const ctx = setup();
  await ctx.update(ctx.ep(5), { name: 'Avize', type: 'plug' });
  assert.strictEqual(ctx.world.db.log.filter((l) => l.sql.includes('FOR UPDATE')).length, 0);
});

test('D12 sure yolu yarisi: yayindan sonra kanal panjur olmaktan cikarsa 409 CONFLICT; DB (sure + ad) DEGISMEZ', async () => {
  const ctx = setup();
  const target = ctx.ep(1);
  const mate = ctx.ep(2);
  raceAfterRead(ctx, () => {
    Object.assign(target, { type: 'light', shutter_pair_index: null, shutter_duration_sec: null });
    Object.assign(mate, { type: 'light', shutter_pair_index: null, shutter_duration_sec: null });
  });
  const err = await expectHttp(ctx.update(target, { shutter_duration_sec: 33, name: 'X' }), 409, 'CONFLICT', { reason: 'TYPE_CHANGED' });
  assert.strictEqual(err.message, TYPE_CHANGED);
  assert.strictEqual(ctx.bridge.commands.length, 1, 'yayin transaction oncesi yapildi (tasarim: yayin once, DB sonra)');
  assert.strictEqual(target.name, 'Salon Panjur Yukarı');
  assert.strictEqual(target.shutter_duration_sec, null);
  assert.strictEqual(mate.shutter_duration_sec, null);
});

test('D12 sure yolu yarisi: cift numarasi degisirse (hedef artik baska ciftte) 409; hicbir satira sure yazilmaz', async () => {
  const ctx = setup();
  const target = ctx.ep(3);
  raceAfterRead(ctx, () => {
    // esitleme benzeri: kanal 3-4 artik cift 1 olarak numaralandi (eski cift 2 yok)
    Object.assign(target, { shutter_pair_index: 1 });
    Object.assign(ctx.ep(4), { shutter_pair_index: 1 });
  });
  await expectHttp(ctx.update(target, { shutter_duration_sec: 44 }), 409, 'CONFLICT');
  assert.ok(ctx.eps.every((e) => e.shutter_duration_sec !== 44));
});

test('D12 sure yolu yarisi: ciftin diger yonu panjur olmaktan cikarsa (cift bozuk) 409', async () => {
  const ctx = setup();
  raceAfterRead(ctx, () => Object.assign(ctx.ep(2), { type: 'light', shutter_pair_index: null, shutter_duration_sec: null }));
  await expectHttp(ctx.update(ctx.ep(1), { shutter_duration_sec: 45 }), 409, 'CONFLICT');
  assert.strictEqual(ctx.ep(1).shutter_duration_sec, 20);
});

test('D12 sure yolu yarisi: satir silinirse (kuculme) 409; baska satira yazilmaz', async () => {
  const ctx = setup();
  const target = ctx.ep(3);
  raceAfterRead(ctx, () => ctx.world.state.endpoints.splice(ctx.world.state.endpoints.indexOf(target), 1));
  await expectHttp(ctx.update(target, { shutter_duration_sec: 46 }), 409, 'CONFLICT');
  assert.strictEqual(ctx.ep(4).shutter_duration_sec, 20);
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
