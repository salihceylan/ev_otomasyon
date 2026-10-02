'use strict';

// B13: firmware gerceklesmesiyle (CONTRACTS §3b) uyum - sys yuku, komut id biçimi, yerel anahtar karakter kumesi,
// cihaz MQTT kimligi yanit sekli (mqtt_server DNS adi + mqtt_port), cihaz uid biçimi

const test = require('node:test');
const assert = require('node:assert');
const bcrypt = require('bcryptjs');

const { createWorld, createServices, setTestEnv, expectHttp } = require('./_world');
const { EndpointService } = require('../../src/services/endpoint_service');
const secretBox = require('../../src/utils/secret_box');
const { MqttCredentialService, looksLikeIpAddress } = require('../../src/services/mqtt_credential_service');

const FIRMWARE_ID = /^[A-Za-z0-9._:-]{1,24}$/;
const FIRMWARE_LOCAL_KEY = /^[\x21-\x7E]{8,32}$/;
const UID = 'AHBU-S3-1A2B3C'; // firmware uid biçimi: AHBU-S3-<STA MAC son 3 bayt, 6 hex, BUYUK>

/** Kurulu ev: sahip + servis personeli + cevrimici cihaz (firmware uid biçimi) + kanallar + kimlikler. */
async function setup({ emqx = false } = {}) {
  setTestEnv();
  if (emqx) {
    process.env.EMQX_API_URL = 'http://emqx.test.invalid:18083';
    process.env.EMQX_API_KEY = 'test-key';
    process.env.EMQX_API_SECRET = 'test-secret';
  }
  const world = createWorld();
  const svc = createServices(world);
  const h = world.helpers;
  const owner = h.addUser({ email: 'sahip@example.test' });
  const tech = h.addUser({ email: 'teknisyen@example.test', role: 'service_user' });
  const newOwner = h.addUser({ email: 'yeni.sahip@example.test' });
  const home = h.addHome({ name: 'Daire 9', owner });
  h.addMember(home, tech, 'service_user', { installer_expires_at: new Date(world.clock.t + 3600000) });
  const inv = h.addInventory({ uuid: UID, pin: '246810', status: 'CLAIMED' });
  const oldKeyEnc = svc.secretBox.encrypt('EskiAnahtar123456');
  const dev = h.addDevice({ home, uuid: UID, mac: inv.mac_address, claimedBy: owner, online: true, local_key_enc: oldKeyEnc });
  const eps = h.addEndpoints(home, dev, 8);
  inv.claimed_home_id = home.id;
  inv.claimed_by_user_id = owner.id;
  inv.pin_hash = 'CLAIMED_BURNED_PIN';
  inv.local_key_enc = oldKeyEnc;
  await svc.credentials.issueDeviceCredential({ homeId: home.id, deviceId: dev.id });
  svc.bridge.commands.length = 0;
  svc.bridge.topics.length = 0;
  const endpointService = new EndpointService({ db: world.db, deviceService: svc.deviceService, mqttBridge: svc.bridge });
  const access = (a) => ({ userId: owner.id, globalRole: 'user', ip: '203.0.113.9', access: a });
  const staff = { userId: tech.id, globalRole: 'service_user', ip: '203.0.113.9', access: 'service_user' };
  return { world, ...svc, h, owner, tech, newOwner, home, inv, dev, eps, endpointService, access, staff };
}

// ------------------------------------------------------------------------------------------------
// (1) sys yuku ve yerel anahtar
// ------------------------------------------------------------------------------------------------
test('yerel anahtar: uretilen HER anahtar firmware biçimine uyar (8..32 karakter, ASCII 0x21-0x7E, bosluk yok)', () => {
  setTestEnv();
  const seen = new Set();
  for (let i = 0; i < 3000; i++) {
    const key = secretBox.generateLocalKey();
    assert.match(key, FIRMWARE_LOCAL_KEY);
    assert.ok(secretBox.isValidLocalKey(key));
    assert.strictEqual(key.length, 16);
    seen.add(key);
  }
  assert.ok(seen.size > 2990, 'anahtarlar rastgele olmali');
  for (const bad of ['', 'kisa', 'bosluk iceren anahtar', 'x'.repeat(33), 'Çğüşıö-anahtar', 'tab\tli-anahtar', null, 12345678, undefined]) {
    assert.strictEqual(secretBox.isValidLocalKey(bad), false, String(bad));
  }
  for (const good of ['abcdefgh', 'x'.repeat(32), '!@#$%^&*()_+-=', 'A1b2C3d4']) assert.ok(secretBox.isValidLocalKey(good), good);
});

test('sys yuku (acil sifirlama): {cmd:"set_local_key", local_key, id} - alan adi local_key (key takma adi YOK), anahtar firmware biçiminde ve DB ile ayni', async () => {
  const ctx = await setup();
  const r = await ctx.deviceService.emergencyReset({
    actor: ctx.staff, deviceUuid: UID, confirmUid: UID, reason: 'Kiraci ulasilamiyor, daire teslim alindi',
  });
  assert.strictEqual(r.local_key_publish, 'published');
  assert.strictEqual(ctx.bridge.topics.length, 1);
  const sys = ctx.bridge.topics[0];
  assert.strictEqual(sys.topic, `ev/${ctx.home.mqtt_username}/sys`);
  assert.deepStrictEqual(Object.keys(sys.obj).sort(), ['cmd', 'id', 'local_key']);
  assert.strictEqual(sys.obj.cmd, 'set_local_key');
  assert.ok(!('key' in sys.obj), 'firmware `key` takma adini kabul eder ama backend local_key kullanir');
  assert.match(sys.obj.local_key, FIRMWARE_LOCAL_KEY);
  assert.match(sys.obj.id, FIRMWARE_ID);
  assert.strictEqual(secretBox.decrypt(ctx.inv.local_key_enc), sys.obj.local_key, 'cihaza giden anahtar envanterdeki yeni anahtarla ayni olmali');
  assert.ok(!('local_key' in r) || r.local_key_publish !== 'published', 'cihaza iletildiyse yanitta anahtar donmez');
});

// ------------------------------------------------------------------------------------------------
// (2) komut id biçimi: ^[A-Za-z0-9._:-]{1,24}$
// ------------------------------------------------------------------------------------------------
test('komut id: sunucunun urettigi her id firmware kuralina (1..24, [A-Za-z0-9._:-]) uyar ve UUID degil (kisa rastgele)', async () => {
  const ctx = await setup();
  const ids = new Set();
  for (let i = 0; i < 3000; i++) {
    const id = ctx.deviceService._newCommandId();
    assert.match(id, FIRMWARE_ID);
    assert.ok(id.length <= 24 && id.length >= 8, id);
    ids.add(id);
  }
  assert.ok(ids.size > 2990, 'idler benzersiz olmali');
});

test('komut id: TUM yayin yollarinda (genel komut, cocuk kilidi, toplu lamba, set_runtime, sifirlama) id firmware kuralina uyar', async () => {
  const ctx = await setup();
  // genel komut (istemci id vermedi -> sunucu uretir)
  await ctx.deviceService.sendCommand({ actor: ctx.access('owner'), homeId: ctx.home.id, deviceRef: UID, command: { relay: 5, state: true } });
  // istemci id'si (kurala uyan) AYNEN korunur
  await ctx.deviceService.sendCommand({ actor: ctx.access('owner'), homeId: ctx.home.id, deviceRef: UID, command: { relay: 6, state: false, id: 'istemci.id:1-a_b' } });
  // cocuk kilidi + toplu lamba
  await ctx.deviceService.setChildLock({ actor: ctx.access('owner'), homeId: ctx.home.id, enabled: true });
  // v2: kayitlara gore acik lamba yoksa komut gonderilmez; acik bir lamba kurulur (priz yok -> all_lights_off)
  ctx.eps.find((e) => e.channel_index === 5).current_state = true;
  await ctx.deviceService.closeAllOpenLights({ actor: ctx.access('owner'), homeId: ctx.home.id });
  // set_runtime
  const shutterEp = ctx.eps.find((e) => e.channel_index === 1);
  await ctx.endpointService.updateEndpoint({ actor: ctx.access('owner'), homeId: ctx.home.id, endpointId: shutterEp.id, patch: { shutter_duration_sec: 24 } });
  // acil sifirlama (cocuk kilidi sifirlama + sys)
  await ctx.deviceService.emergencyReset({ actor: ctx.staff, deviceUuid: UID, confirmUid: UID, reason: 'Kiraci ulasilamiyor, daire teslim alindi' });

  const published = [...ctx.bridge.commands.map((c) => c.obj), ...ctx.bridge.topics.map((t) => t.obj)];
  assert.ok(published.length >= 6, `yayin sayisi: ${published.length}`);
  for (const obj of published) {
    assert.ok(typeof obj.id === 'string', `id eksik: ${JSON.stringify(obj)}`);
    assert.match(obj.id, FIRMWARE_ID, JSON.stringify(obj));
  }
  assert.ok(published.some((o) => o.id === 'istemci.id:1-a_b'), 'istemci id\'si degismeden gitmeli');
  assert.ok(published.some((o) => o.cmd === 'set_runtime'));
  assert.ok(published.some((o) => o.cmd === 'all_lights_off'));
});

test('komut id: firmware kuralina uymayan istemci id\'si (25 karakter, bosluk, UUID uzunlugu, ozel karakter) 400 ile reddedilir; yayin yapilmaz', async () => {
  const ctx = await setup();
  for (const id of ['x'.repeat(25), 'a b', '9f1c2e34-5b6a-4c7d-8e9f-0a1b2c3d4e5f', 'a/b', 'a#b', 'a+b', '', 42, 'é']) {
    await expectHttp(
      ctx.deviceService.sendCommand({ actor: ctx.access('owner'), homeId: ctx.home.id, deviceRef: UID, command: { relay: 5, state: true, id } }),
      400, 'VALIDATION'
    );
  }
  assert.strictEqual(ctx.bridge.commands.length, 0);
});

// ------------------------------------------------------------------------------------------------
// (4) cihaz uid biçimi AHBU-S3-<6 hex BUYUK>
// ------------------------------------------------------------------------------------------------
test('cihaz uid: AHBU-S3-<6 hex buyuk> kabul edilir (kucuk harf girdi normalize edilir); bozuk biçimler 400', async () => {
  setTestEnv();
  const world = createWorld();
  const svc = createServices(world);
  const user = world.helpers.addUser({ email: 'sahip@example.test' });
  const act = { userId: user.id, globalRole: 'user', ip: '10.0.0.1' };
  world.helpers.addInventory({ uuid: 'AHBU-S3-9F00AA', pin: '123456' });
  const r = await svc.deviceService.claimDevice({ actor: act, deviceUuid: ' ahbu-s3-9f00aa ', setupPin: '123456' });
  assert.strictEqual(r.device_uuid, 'AHBU-S3-9F00AA');
  for (const bad of ['', 'S3-9F00AA', 'AHBU-', 'AHBU S3 9F00AA', 'AHBU-S3-ÇÇÇÇÇÇ', 'AHBU-' + 'X'.repeat(40), null, 42]) {
    await expectHttp(svc.deviceService.claimDevice({ actor: act, deviceUuid: bad, setupPin: '123456' }), 400, 'VALIDATION');
  }
});

// ------------------------------------------------------------------------------------------------
// (5) cihaz MQTT kimligi yaniti: mqtt_server (DNS adi) + mqtt_port; servis sihirbazi bunu POST /api/mqtt/config'e yazar
// ------------------------------------------------------------------------------------------------
function assertFirmwareCredentialShape(cred, ctx, label) {
  assert.strictEqual(cred.mqtt_server, 'broker.test.invalid', `${label}: mqtt_server DNS adi (MQTT_PUBLIC_HOST)`);
  assert.strictEqual(cred.mqtt_port, 8884, `${label}: mqtt_port`);
  assert.strictEqual(cred.host, cred.mqtt_server, `${label}: host geriye donuk uyumluluk icin ayni`);
  assert.strictEqual(cred.port, cred.mqtt_port, `${label}: port geriye donuk uyumluluk icin ayni`);
  assert.ok(!looksLikeIpAddress(cred.mqtt_server), `${label}: IP olmamali`);
  assert.match(cred.username, /^d_h_[0-9a-f]{16}$/, `${label}: user d_<t>`);
  assert.strictEqual(cred.topic_id, cred.username.slice(2));
  assert.match(cred.password, /^[A-Za-z0-9]{24}$/, `${label}: pass <= 31 karakter (firmware mqtt_pass[32])`);
  assert.ok(cred.password.length <= 31);
  assert.deepStrictEqual(
    Object.keys(cred).filter((k) => !['warnings'].includes(k)).sort(),
    ['client_id', 'host', 'mqtt_port', 'mqtt_server', 'password', 'port', 'topic_id', 'username'],
    `${label}: yanit alanlari`
  );
  const row = ctx.world.state.mqtt_credentials.find((c) => c.kind === 'device' && c.username === cred.username);
  assert.ok(row && bcrypt.compareSync(cred.password, row.password_hash), `${label}: parola DB ozetiyle eslesmeli`);
}

test('cihaz kimligi yaniti (claim): mqtt_server DNS adi + mqtt_port, user d_<t>, 24 karakterlik parola', async () => {
  setTestEnv();
  const world = createWorld();
  const svc = createServices(world);
  const user = world.helpers.addUser({ email: 'sahip@example.test' });
  world.helpers.addInventory({ uuid: UID, pin: '123456' });
  const r = await svc.deviceService.claimDevice({ actor: { userId: user.id, globalRole: 'user', ip: '10.0.0.1' }, deviceUuid: UID, setupPin: '123456' });
  assertFirmwareCredentialShape(r.device_credential, { world }, 'claim');
});

test('cihaz kimligi yaniti: acil sifirlama (yeni sahibe devir), pano degisimi ve kimlik yenileme AYNI sekli doner', async () => {
  // acil sifirlama -> yeni sahip
  let ctx = await setup();
  const reset = await ctx.deviceService.emergencyReset({
    actor: ctx.staff, deviceUuid: UID, confirmUid: UID, reason: 'Kiraci ulasilamiyor, daire teslim alindi',
    newOwnerIdentifier: 'yeni.sahip@example.test',
  });
  assert.strictEqual(reset.action, 'REASSIGNED');
  assertFirmwareCredentialShape(reset.device_credential, ctx, 'acil sifirlama');

  // pano degisimi
  ctx = await setup();
  const NEW = 'AHBU-S3-0A0B0C';
  ctx.h.addInventory({ uuid: NEW, pin: '135790', status: 'IN_STOCK' });
  const rb = await ctx.deviceService.replaceBoard({
    actor: ctx.access('owner'), homeId: ctx.home.id, oldDeviceUuid: UID, newDeviceUuid: NEW, setupPin: '135790', reason: 'Pano yandi',
  });
  assertFirmwareCredentialShape(rb.device_credential, ctx, 'pano degisimi');

  // kimlik yenileme (duz yanit)
  ctx = await setup();
  const re = await ctx.deviceService.reissueDeviceCredential({ actor: ctx.access('owner'), homeId: ctx.home.id, deviceUuid: UID });
  assertFirmwareCredentialShape(re, ctx, 'kimlik yenileme');
});

test('MQTT_PUBLIC_HOST bir IP adresiyse (firmware TLS ana makine adiyla dogrular) bir kez UYARI loglanir; kimlik yine uretilir (yerel/QA icin)', async () => {
  setTestEnv({ MQTT_PUBLIC_HOST: '10.0.2.2', MQTT_PUBLIC_PORT: '1883' });
  const world = createWorld();
  const warnings = [];
  const credentials = new MqttCredentialService({
    db: world.db, env: process.env, logger: { warn: (m) => warnings.push(m), error() {}, log() {} }, now: () => world.clock.now(),
  });
  const a = credentials.getBrokerInfo();
  const b = credentials.getBrokerInfo();
  assert.deepStrictEqual(a, { host: '10.0.2.2', port: 1883 });
  assert.deepStrictEqual(b, a);
  assert.strictEqual(warnings.length, 1, 'uyari bir kez');
  assert.match(warnings[0], /DNS adi/);
  assert.ok(!/10\.0\.2\.2/.test(warnings[0]), 'uyari degeri yazmaz');

  // DNS adinda uyari yok
  setTestEnv({ MQTT_PUBLIC_HOST: 'evotomasyon.gudeteknoloji.com.tr', MQTT_PUBLIC_PORT: '8884' });
  warnings.length = 0;
  const ok = new MqttCredentialService({ db: world.db, env: process.env, logger: { warn: (m) => warnings.push(m), error() {}, log() {} } });
  assert.deepStrictEqual(ok.getBrokerInfo(), { host: 'evotomasyon.gudeteknoloji.com.tr', port: 8884 });
  assert.strictEqual(warnings.length, 0);
  for (const host of ['10.0.2.2', '192.168.1.5', '::1', '[2001:db8::1]']) assert.ok(looksLikeIpAddress(host), host);
  for (const host of ['broker.example.com', 'localhost', 'a1.b2.c3', '1.2.3']) assert.ok(!looksLikeIpAddress(host), host);
});

// ------------------------------------------------------------------------------------------------
// (3) state'te last_id olmayabilir: teslim bilgisi last_id'ye BAGLI degildir
// ------------------------------------------------------------------------------------------------
test('delivered, cihaz state\'indeki last_id\'ye bagli DEGIL: yanit yayin kabulune (broker) dayanir; kaynakta last_id okumasi yok', async () => {
  const ctx = await setup();
  const r = await ctx.deviceService.sendCommand({ actor: ctx.access('owner'), homeId: ctx.home.id, deviceRef: UID, command: { relay: 5, state: true } });
  assert.deepStrictEqual(Object.keys(r).sort(), ['command_id', 'delivered', 'device_online']);
  assert.strictEqual(r.delivered, true);
  const fs = require('fs');
  for (const f of ['services/device_service.js', 'services/endpoint_service.js', 'routes/device_routes.js']) {
    const src = fs.readFileSync(require.resolve(`../../src/${f}`), 'utf8').replace(/\/\*[\s\S]*?\*\//g, '').replace(/\/\/.*$/gm, '');
    assert.ok(!/\blast_id\b|\blast_ack_id\b/.test(src), `${f}: last_id/last_ack_id okunmamali (alan state'te bulunmayabilir)`);
  }
});
