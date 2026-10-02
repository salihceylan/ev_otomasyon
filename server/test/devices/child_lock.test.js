'use strict';

// B12: COCUK KILIDI - tek uygulama (ozel rota + genel komut rotasi), PUBACK != uygulandi, serilestirme, no-op,
// ev basina hiz siniri, denetim kaydi, acil sifirlama / pano degisimi. HTTP testleri A'nin GERCEK middleware'i ile.

const test = require('node:test');
const assert = require('node:assert');

const { createIntegration } = require('./_integration');
const { createWorld, createServices, setTestEnv, expectHttp } = require('./_world');

const env = createIntegration();
const { world, state, bridge, helpers: h, api, tokenOf, sessionToken, skipIfUnavailable } = env;

// ------------------------------------------------------------------------------------------------
// Kullanicilar (HTTP testleri). Her test KENDI evini kurar: ev basina hiz siniri testler arasinda sizmasin.
// ------------------------------------------------------------------------------------------------
const mk = (email, role = 'user') => h.addUser({ email, role });
const owner = mk('sahip@example.test');
const resident = mk('sakin@example.test');
const guestOk = mk('misafir@example.test');
const guestExpired = mk('eski.misafir@example.test');
const staff = mk('servis@example.test', 'service_user');
const staff2 = mk('baska.servis@example.test', 'service_user');
const root = mk('root@example.test', 'super_user');
const stranger = mk('yabanci@example.test'); // baska evin sahibi
const strangerResident = mk('yabanci.sakin@example.test');
for (const u of state.users) u.token_version = 1;

let counter = 0;
function makeHome({ online = true, locked = null } = {}) {
  counter += 1;
  const home = h.addHome({ name: `Ev ${counter}`, owner });
  h.addMember(home, resident, 'resident');
  h.addMember(home, guestOk, 'guest', { valid_until: new Date(Date.now() + 3600 * 1000) });
  h.addMember(home, guestExpired, 'guest', { valid_until: new Date(Date.now() - 3600 * 1000) });
  h.addMember(home, staff, 'service_user');
  const dev = h.addDevice({
    home, uuid: `AHBU-CL-${String(counter).padStart(4, '0')}`, mac: `E8:F6:0A:CL:00:${String(counter).padStart(2, '0')}`,
    claimedBy: owner, online,
  });
  if (locked !== null) dev.child_lock_enabled = locked;
  return { home, dev };
}

const other = (() => {
  const home = h.addHome({ name: 'Baska Ev', owner: stranger });
  h.addMember(home, strangerResident, 'resident');
  h.addDevice({ home, uuid: 'AHBU-CL-9999', mac: 'E8:F6:0A:CL:99:99', claimedBy: stranger, online: true });
  return home;
})();

/**
 * Entegrasyon ortami (_integration.js) src/mqtt_bridge.js'i require.cache'e SAHTE olarak enjekte eder; gercek
 * (C paketi) modulu onbellegi gecici atlayarak yukler ve enjekte kaydi geri koyar.
 */
function requireRealBridge() {
  const filename = require.resolve('../../src/mqtt_bridge');
  const injected = require.cache[filename];
  delete require.cache[filename];
  try {
    return require(filename);
  } finally {
    if (injected) require.cache[filename] = injected;
    else delete require.cache[filename];
  }
}

const lockUrl = '/api/v1/devices/child-lock';
const lockBody = (home, enabled) => ({ home_id: home.id, enabled });
const cmdUrl = (dev) => `/api/v1/devices/${dev.id}/command`;
const cmdBody = (home, enabled) => ({ home_id: home.id, command: { cmd: 'set_child_lock', enabled } });
const auditOf = (home) => state.device_audit_logs.filter((a) => a.event === 'child_lock_set' && a.home_id === home.id);
const writesOf = () => world.db.sqls().filter((s) => /^(UPDATE|INSERT|DELETE)/.test(s));

test.beforeEach(() => {
  bridge.commands.length = 0;
  bridge.failPublish = false;
  bridge.connected = true;
});

// ------------------------------------------------------------------------------------------------
// Kimlik dogrulama + rol matrisi (iki giris yolu da)
// ------------------------------------------------------------------------------------------------
test('kimlik: token yok -> 401; baska evin sahibi/sakini -> 403 (IDOR yok); iki rotada da', async (t) => {
  if (skipIfUnavailable(t)) return;
  const { home, dev } = makeHome();
  assert.strictEqual((await api('post', lockUrl, null, lockBody(home, true))).status, 401);
  assert.strictEqual((await api('post', cmdUrl(dev), null, cmdBody(home, true))).status, 401);
  for (const user of [stranger, strangerResident]) {
    assert.strictEqual((await api('post', lockUrl, tokenOf(user), lockBody(home, true))).status, 403);
    assert.strictEqual((await api('post', cmdUrl(dev), tokenOf(user), cmdBody(home, true))).status, 403);
    assert.strictEqual((await api('get', `/api/v1/devices/child-lock/${home.id}`, tokenOf(user))).status, 403);
  }
  assert.strictEqual(bridge.commands.length, 0);
  assert.deepStrictEqual(writesOf(), [], 'yetkisiz isteklerde DB yazimi olmamali');
});

test('rol matrisi: owner/resident/staff/servis oturumu/super 200; gecerli misafir 403; suresi dolmus misafir GUEST_EXPIRED', async (t) => {
  if (skipIfUnavailable(t)) return;
  const allowed = [
    ['owner', () => tokenOf(owner)],
    ['resident', () => tokenOf(resident)],
    ['staff', () => tokenOf(staff)],
    ['super', () => tokenOf(root)],
  ];
  for (const [label, token] of allowed) {
    for (const via of ['route', 'command']) {
      const { home, dev } = makeHome();
      const res = via === 'route'
        ? await api('post', lockUrl, token(), lockBody(home, true))
        : await api('post', cmdUrl(dev), token(), cmdBody(home, true));
      assert.strictEqual(res.status, 200, `${label}/${via}: ${JSON.stringify(res.body)}`);
      assert.strictEqual(res.body.data.delivered, true);
    }
  }
  // servis (PIN) oturumu: yalnizca kendi evi
  const { home: sHome } = makeHome();
  const sess = sessionToken(sHome.id);
  assert.strictEqual((await api('post', lockUrl, sess, lockBody(sHome, true))).status, 200);
  const { home: otherSessHome } = makeHome();
  assert.strictEqual((await api('post', lockUrl, sess, lockBody(otherSessHome, true))).status, 403);

  // gecerli misafir: 403 FORBIDDEN (iki rota); suresi dolmus misafir: GUEST_EXPIRED
  const { home, dev } = makeHome();
  for (const [url, body] of [[lockUrl, lockBody(home, true)], [cmdUrl(dev), cmdBody(home, true)]]) {
    const guest = await api('post', url, tokenOf(guestOk), body);
    assert.strictEqual(guest.status, 403, url);
    assert.strictEqual(guest.body.code, 'FORBIDDEN');
    const expired = await api('post', url, tokenOf(guestExpired), body);
    assert.strictEqual(expired.status, 403);
    assert.strictEqual(expired.body.code, 'GUEST_EXPIRED');
  }
  // misafir durumu OKUYABILIR (durum gorme: tum roller)
  assert.strictEqual((await api('get', `/api/v1/devices/child-lock/${home.id}`, tokenOf(guestOk))).status, 200);
  assert.strictEqual((await api('get', `/api/v1/devices/child-lock/${home.id}`, tokenOf(guestExpired))).status, 403);
});

// ------------------------------------------------------------------------------------------------
// Sik boolean
// ------------------------------------------------------------------------------------------------
test('sikı boolean: "true"/"false"/1/0/null/eksik/nesne/dizi -> 400 VALIDATION; yayin ve DB yazimi YOK', async (t) => {
  if (skipIfUnavailable(t)) return;
  const { home, dev } = makeHome();
  const token = tokenOf(owner);
  const before = writesOf().length;
  for (const enabled of ['true', 'false', 'on', 1, 0, null, undefined, {}, []]) {
    const body = { home_id: home.id };
    if (enabled !== undefined) body.enabled = enabled;
    const res = await api('post', lockUrl, token, body);
    assert.strictEqual(res.status, 400, `enabled=${JSON.stringify(enabled)}`);
    assert.strictEqual(res.body.code, 'VALIDATION');
    const gen = await api('post', cmdUrl(dev), token, { home_id: home.id, command: { cmd: 'set_child_lock', enabled } });
    assert.strictEqual(gen.status, 400, `komut rotasi enabled=${JSON.stringify(enabled)}`);
  }
  // bilinmeyen alan (genel rota semasi)
  const extra = await api('post', cmdUrl(dev), token, { home_id: home.id, command: { cmd: 'set_child_lock', enabled: true, timestamp: 1 } });
  assert.strictEqual(extra.status, 400);
  assert.strictEqual(bridge.commands.length, 0);
  assert.strictEqual(writesOf().length, before);
});

// ------------------------------------------------------------------------------------------------
// Yanit sozlesmesi: PUBACK != uygulandi
// ------------------------------------------------------------------------------------------------
test('yanit: { requested, delivered, device_online, command_id, offline_devices } + notr mesaj; "kilitlendi" DENMEZ; DURUM yazilmaz', async (t) => {
  if (skipIfUnavailable(t)) return;
  const { home, dev } = makeHome({ locked: false });
  const res = await api('post', lockUrl, tokenOf(owner), lockBody(home, true));
  assert.strictEqual(res.status, 200, JSON.stringify(res.body));
  assert.strictEqual(res.body.message, 'Komut cihaza iletildi.');
  assert.deepStrictEqual(Object.keys(res.body.data).sort(), ['command_id', 'delivered', 'device_online', 'home_id', 'offline_devices', 'requested']);
  assert.strictEqual(res.body.data.requested, true);
  assert.strictEqual(res.body.data.delivered, true);
  assert.strictEqual(res.body.data.device_online, true);
  assert.match(res.body.data.command_id, /^[A-Za-z0-9_-]{12}$/);
  assert.deepStrictEqual(res.body.data.offline_devices, []);
  assert.ok(!/kilitlendi|aktif|kapali/i.test(JSON.stringify(res.body)), 'uygulandi iddiasi olmamali');
  assert.ok(!('child_lock_enabled' in res.body.data), 'istenen deger "durum" olarak donmemeli');
  assert.ok(!('message' in res.body.data), 'mesaj data icinde tekrarlanmamali');

  // REST DURUM yazmaz: gercek deger cihazin state.child_lock bildiriminden gelir (kopru)
  assert.strictEqual(dev.child_lock_enabled, false, 'devices.child_lock_enabled degismemeli');
  assert.strictEqual(home.child_lock_enabled, false, 'homes.child_lock_enabled degismemeli');
  const writes = writesOf().filter((s) => /child_lock/.test(s));
  assert.ok(!writes.some((s) => /child_lock_enabled\s*=/.test(s) && !/child_lock_requested/.test(s)), writes.join(' | '));
  // yalnizca NIYET kaydedildi
  assert.strictEqual(home.child_lock_requested, true);
  assert.ok(home.child_lock_requested_at);
});

test('komut yuku sozlesmeyle: ev/{t}/cmd, QoS1, retain=false, {cmd:"set_child_lock", enabled:bool, id} (GERCEK kopru)', async (t) => {
  let helpers;
  try {
    helpers = require('../bridge/_helpers');
  } catch (err) {
    t.skip(`C paketi test yardimcilari yuklenemedi: ${err.message}`);
    return;
  }
  const { MqttBridge } = requireRealBridge();
  setTestEnv();
  const w = createWorld();
  const client = helpers.makeFakeClient();
  const realBridge = new MqttBridge({
    mqttLib: helpers.makeFakeMqttLib(client), db: helpers.makeFakeDb(), logger: helpers.makeLogger(),
    timers: helpers.makeFakeTimers(), env: { MQTT_BACKEND_USER: 'backend_service', MQTT_BACKEND_PASS: 'test-only-placeholder' },
    now: () => Date.now(), random: () => 0.5,
  });
  realBridge.init();
  client.connected = true;
  client.emit('connect', { sessionPresent: false });

  const svc = createServices(w, { mqttBridge: realBridge });
  const user = w.helpers.addUser({ email: 'a@example.test' });
  const home = w.helpers.addHome({ name: 'Ev', owner: user });
  w.helpers.addDevice({ home, uuid: 'AHBU-CL-0001', mac: 'E8:F6:0A:00:00:01', online: true });
  const actor = { userId: user.id, globalRole: 'user', ip: '10.0.0.1', access: 'owner' };

  const r = await svc.deviceService.setChildLock({ actor, homeId: home.id, enabled: true });
  const pub = client.published.filter((p) => p.topic.endsWith('/cmd'));
  assert.strictEqual(pub.length, 1);
  assert.strictEqual(pub[0].topic, `ev/${home.mqtt_username}/cmd`);
  assert.deepStrictEqual(pub[0].opts, { qos: 1, retain: false });
  assert.deepStrictEqual(JSON.parse(pub[0].payload), { cmd: 'set_child_lock', enabled: true, id: r.command_id });

  await svc.deviceService.setChildLock({ actor, homeId: home.id, enabled: false });
  assert.strictEqual(JSON.parse(client.published.filter((p) => p.topic.endsWith('/cmd')).at(-1).payload).enabled, false);
});

// ------------------------------------------------------------------------------------------------
// 409 / 502 / kismi cevrimdisi
// ------------------------------------------------------------------------------------------------
test('tum panolar cevrimdisi: 409 DEVICE_OFFLINE (+offline_devices), SIFIR DB yazimi, yayin yok', async (t) => {
  if (skipIfUnavailable(t)) return;
  const { home, dev } = makeHome({ online: false });
  const before = writesOf().length;
  for (const [url, body] of [[lockUrl, lockBody(home, true)], [cmdUrl(dev), cmdBody(home, true)]]) {
    const res = await api('post', url, tokenOf(owner), body);
    assert.strictEqual(res.status, 409);
    assert.strictEqual(res.body.code, 'DEVICE_OFFLINE');
    assert.strictEqual(res.body.device_online, false);
    assert.deepStrictEqual(res.body.offline_devices, [dev.device_uuid]);
    assert.match(res.body.message, /çevrimdışı/);
  }
  assert.strictEqual(bridge.commands.length, 0);
  assert.strictEqual(writesOf().length, before, 'cevrimdisiyken DB yazimi olmamali');
  assert.strictEqual(home.child_lock_requested, undefined);
  assert.deepStrictEqual(auditOf(home), []);
});

test('yayin basarisiz: 502 BROKER_UNAVAILABLE; niyet ve denetim kaydi GERI ALINIR (rollback), DB degismez', async (t) => {
  if (skipIfUnavailable(t)) return;
  const { home, dev } = makeHome({ locked: false });
  bridge.failPublish = true;
  for (const [url, body] of [[lockUrl, lockBody(home, true)], [cmdUrl(dev), cmdBody(home, true)]]) {
    const res = await api('post', url, tokenOf(owner), body);
    assert.strictEqual(res.status, 502, url);
    assert.strictEqual(res.body.code, 'BROKER_UNAVAILABLE');
  }
  assert.strictEqual(home.child_lock_requested, undefined, 'niyet geri alinmali');
  assert.strictEqual(home.child_lock_enabled, false);
  assert.deepStrictEqual(auditOf(home), [], 'denetim kaydi kalmamali');

  bridge.failPublish = false;
  bridge.connected = false;
  const down = await api('post', lockUrl, tokenOf(owner), lockBody(home, true));
  assert.strictEqual(down.status, 502);
  assert.strictEqual(home.child_lock_requested, undefined);
});

test('kismi cevrimdisi (coklu pano): komut yayinlanir, offline_devices listelenir, mesaj bunu belirtir', async (t) => {
  if (skipIfUnavailable(t)) return;
  const { home, dev } = makeHome({ online: true });
  const second = h.addDevice({ home, uuid: 'AHBU-CL-7001', mac: 'E8:F6:0A:CL:70:01', claimedBy: owner, online: false });
  const res = await api('post', lockUrl, tokenOf(owner), lockBody(home, true));
  assert.strictEqual(res.status, 200, JSON.stringify(res.body));
  assert.deepStrictEqual(res.body.data.offline_devices, [second.device_uuid]);
  assert.match(res.body.message, /bazı panolar çevrimdışı/);
  assert.strictEqual(bridge.commands.length, 1);
  assert.strictEqual(auditOf(home)[0].details.devices_offline, 1);
  assert.strictEqual(auditOf(home)[0].details.devices_online, 1);
  void dev;
});

test('pano bulunmayan ev 404 (iki rota); bilinmeyen cihaz referansi 404', async (t) => {
  if (skipIfUnavailable(t)) return;
  const empty = h.addHome({ name: 'Bos Ev', owner });
  const res = await api('post', lockUrl, tokenOf(owner), lockBody(empty, true));
  assert.strictEqual(res.status, 404);
  const { home } = makeHome();
  const ghost = await api('post', '/api/v1/devices/AHBU-YOK-0001/command', tokenOf(owner), cmdBody(home, true));
  assert.strictEqual(ghost.status, 404);
  assert.strictEqual(bridge.commands.length, 0);
});

// ------------------------------------------------------------------------------------------------
// NO-OP (her gecis panoda NVS yazar ve bip calar)
// ------------------------------------------------------------------------------------------------
test('NO-OP: cevrimici tum panolar zaten istenen degeri bildiriyorsa komut YAYINLANMAZ (no_change, command_id:null)', async (t) => {
  if (skipIfUnavailable(t)) return;
  const { home, dev } = makeHome({ locked: true });
  const before = writesOf().length;
  for (const [url, body] of [[lockUrl, lockBody(home, true)], [cmdUrl(dev), cmdBody(home, true)]]) {
    const res = await api('post', url, tokenOf(resident), body);
    assert.strictEqual(res.status, 200, JSON.stringify(res.body));
    assert.strictEqual(res.body.data.no_change, true);
    assert.strictEqual(res.body.data.delivered, true);
    assert.strictEqual(res.body.data.command_id, null);
    assert.strictEqual(res.body.data.requested, true);
  }
  const first = await api('post', lockUrl, tokenOf(resident), lockBody(home, true));
  assert.strictEqual(first.body.message, 'Çocuk kilidi zaten istenen durumda.');
  assert.strictEqual(bridge.commands.length, 0, 'no-op: broker\'a hicbir sey gitmemeli');
  assert.strictEqual(writesOf().length, before, 'no-op: DB yazimi/denetim kaydi olmamali');
});

test('NO-OP YOK: pano farkli bildiriyorsa, durum bilinmiyorsa (NULL) veya karsit yonde bekleyen niyet varsa yayinlanir', async (t) => {
  if (skipIfUnavailable(t)) return;
  const token = tokenOf(owner);

  const a = makeHome({ locked: false });
  assert.strictEqual((await api('post', lockUrl, token, lockBody(a.home, true))).body.data.no_change, undefined);

  const b = makeHome(); // child_lock_enabled bilinmiyor (NULL/undefined)
  assert.strictEqual((await api('post', lockUrl, token, lockBody(b.home, false))).body.data.no_change, undefined);

  // pano kilitli bildiriyor ama KARSIT yonde (acma) bekleyen niyet var (henuz yansimamis): kilitle istegi yayinlanir
  const c = makeHome({ locked: true });
  c.home.child_lock_requested = false;
  const res = await api('post', lockUrl, token, lockBody(c.home, true));
  assert.strictEqual(res.status, 200);
  assert.strictEqual(res.body.data.no_change, undefined);
  assert.strictEqual(c.home.child_lock_requested, true);
  assert.strictEqual(bridge.commands.length, 3);
});

test('NO-OP: bir cevrimici pano bile farkliysa yayinlanir (coklu pano)', async (t) => {
  if (skipIfUnavailable(t)) return;
  const { home } = makeHome({ locked: true });
  h.addDevice({ home, uuid: 'AHBU-CL-7101', mac: 'E8:F6:0A:CL:71:01', claimedBy: owner, online: true }).child_lock_enabled = false;
  const res = await api('post', lockUrl, tokenOf(owner), lockBody(home, true));
  assert.strictEqual(res.status, 200);
  assert.strictEqual(res.body.data.no_change, undefined);
  assert.strictEqual(bridge.commands.length, 1);
});

// ------------------------------------------------------------------------------------------------
// Tek uygulama: genel komut rotasi ile ozel rota AYNI davranis
// ------------------------------------------------------------------------------------------------
test('tek uygulama: iki rota ayni yuk, ayni niyet, ayni denetim olayi (child_lock_set) uretir; fark yalnizca "via"', async (t) => {
  if (skipIfUnavailable(t)) return;
  const results = {};
  for (const via of ['route', 'command']) {
    const { home, dev } = makeHome({ locked: false });
    bridge.commands.length = 0;
    const res = via === 'route'
      ? await api('post', lockUrl, tokenOf(resident), lockBody(home, true))
      : await api('post', cmdUrl(dev), tokenOf(resident), cmdBody(home, true));
    assert.strictEqual(res.status, 200, `${via}: ${JSON.stringify(res.body)}`);
    const { id, ...payload } = bridge.commands[0].obj;
    const audit = auditOf(home);
    assert.strictEqual(audit.length, 1, `${via}: tek denetim kaydi`);
    results[via] = {
      topic: bridge.commands[0].topicId === home.mqtt_username,
      payload,
      idMatches: id === res.body.data.command_id,
      shape: Object.keys(res.body.data).sort(),
      intent: [home.child_lock_requested, home.child_lock_requested_by],
      audit: { event: audit[0].event, actor: audit[0].actor_user_id, role: audit[0].actor_role, ip: Boolean(audit[0].ip_address) },
      details: { ...audit[0].details, command_id: undefined, via: undefined },
      via: audit[0].details.via,
    };
  }
  assert.strictEqual(results.route.via, 'child_lock_route');
  assert.strictEqual(results.command.via, 'command_route');
  const strip = ({ via, ...rest }) => rest;
  assert.deepStrictEqual(strip(results.route), strip(results.command));
  assert.deepStrictEqual(results.route.payload, { cmd: 'set_child_lock', enabled: true });
  assert.deepStrictEqual(results.route.intent, [true, resident.id]);
});

test('genel rotada istemci komut kimligi (id) korunur; ozel rotada sunucu uretir', async (t) => {
  if (skipIfUnavailable(t)) return;
  const { home, dev } = makeHome({ locked: false });
  const res = await api('post', cmdUrl(dev), tokenOf(owner), {
    home_id: home.id, command: { cmd: 'set_child_lock', enabled: true, id: 'istemci-id-1' },
  });
  assert.strictEqual(res.status, 200);
  assert.strictEqual(res.body.data.command_id, 'istemci-id-1');
  assert.strictEqual(bridge.commands[0].obj.id, 'istemci-id-1');
  assert.strictEqual(auditOf(home)[0].details.command_id, 'istemci-id-1');
});

// ------------------------------------------------------------------------------------------------
// Denetim kaydi
// ------------------------------------------------------------------------------------------------
test('denetim: child_lock_set -> kim (kullanici/rol), nereden (IP), ne (enabled, command_id, pano sayilari); sir yok; oturumda userId null', async (t) => {
  if (skipIfUnavailable(t)) return;
  const { home } = makeHome({ locked: false });
  await api('post', lockUrl, tokenOf(staff), lockBody(home, true));
  const [a] = auditOf(home);
  assert.strictEqual(a.event, 'child_lock_set');
  assert.strictEqual(a.actor_user_id, staff.id);
  assert.strictEqual(a.actor_role, 'service_user');
  assert.ok(a.ip_address);
  assert.strictEqual(a.details.enabled, true);
  assert.match(a.details.command_id, /^[A-Za-z0-9_-]{12}$/);
  assert.strictEqual(a.details.devices_online, 1);
  assert.strictEqual(a.details.devices_offline, 0);
  assert.strictEqual(a.details.via, 'child_lock_route');
  assert.ok(!/password|pin|token|local_key/i.test(JSON.stringify(a)));

  const { home: sh } = makeHome({ locked: false });
  await api('post', lockUrl, sessionToken(sh.id), lockBody(sh, true));
  const [s] = auditOf(sh);
  assert.strictEqual(s.actor_user_id, null);
  assert.strictEqual(s.actor_role, 'service_session');
  assert.strictEqual(sh.child_lock_requested_by, null);
});

// ------------------------------------------------------------------------------------------------
// Serilestirme / eszamanlilik
// ------------------------------------------------------------------------------------------------
test('ESZAMANLILIK: ayni ev icin iki gecis seri hale getirilir (advisory kilit); ters sirada commit OLMAZ; niyet son yayinla ayni', async () => {
  setTestEnv();
  const w = createWorld();
  const svc = createServices(w);
  const user = w.helpers.addUser({ email: 'a@example.test' });
  const home = w.helpers.addHome({ name: 'Ev', owner: user });
  const dev = w.helpers.addDevice({ home, uuid: 'AHBU-CL-0001', mac: 'E8:F6:0A:00:00:01', online: true });
  dev.child_lock_enabled = false;
  const actor = { userId: user.id, globalRole: 'user', ip: '10.0.0.1', access: 'owner' };

  // T1 (kilitle) once baslar, T2 (ac) hemen ardindan: ikisi de eszamanli
  const p1 = svc.deviceService.setChildLock({ actor, homeId: home.id, enabled: true });
  await new Promise((resolve) => setImmediate(resolve));
  const p2 = svc.deviceService.setChildLock({ actor, homeId: home.id, enabled: false });
  const [r1, r2] = await Promise.all([p1, p2]);

  // sirayla yayinlandi; ikinci istek, ilkinin NIYETINI gordu ("zaten false" kisa devresi YANLIS calismadi)
  assert.deepStrictEqual(svc.bridge.commands.map((c) => c.obj.enabled), [true, false]);
  assert.strictEqual(r1.no_change, undefined);
  assert.strictEqual(r2.no_change, undefined, 'bekleyen karsit niyet varken no-op yapilmamali');
  assert.strictEqual(home.child_lock_requested, false, 'son niyet son yayinla ayni olmali');
  assert.deepStrictEqual(
    w.state.device_audit_logs.filter((a) => a.event === 'child_lock_set').map((a) => a.details.enabled),
    [true, false]
  );

  // seri hale getirme: T2'nin ev okumasi, T1 COMMIT olduktan SONRA
  const log = w.db.log;
  const tx1 = log.find((l) => l.sql.includes('pg_advisory_xact_lock')).tx;
  const tx2 = [...new Set(log.filter((l) => l.sql.includes('pg_advisory_xact_lock')).map((l) => l.tx))].find((id) => id !== tx1);
  const lastOfTx1 = Math.max(...log.map((l, i) => (l.tx === tx1 ? i : -1)));
  const firstReadOfTx2 = log.findIndex((l) => l.tx === tx2 && l.sql.includes('FROM homes WHERE id = $1'));
  assert.ok(lastOfTx1 >= 0 && firstReadOfTx2 > lastOfTx1, `T2 okumasi (${firstReadOfTx2}) T1 bitisinden (${lastOfTx1}) sonra olmali`);
  assert.ok(log.filter((l) => l.sql.includes('pg_advisory_xact_lock')).every((l) => l.params[0] === `child-lock:${home.id}`));
});

test('ESZAMANLILIK: farkli evler birbirini BEKLETMEZ (kilit anahtari ev basina)', async () => {
  setTestEnv();
  const w = createWorld();
  const svc = createServices(w);
  const user = w.helpers.addUser({ email: 'a@example.test' });
  const actor = { userId: user.id, globalRole: 'user', ip: '10.0.0.1', access: 'owner' };
  const mkHome = (n) => {
    const home = w.helpers.addHome({ name: `Ev ${n}`, owner: user });
    w.helpers.addDevice({ home, uuid: `AHBU-CL-${n}000`, mac: `E8:F6:0A:00:00:0${n}`, online: true });
    return home;
  };
  const [h1, h2] = [mkHome(1), mkHome(2)];
  await Promise.all([
    svc.deviceService.setChildLock({ actor, homeId: h1.id, enabled: true }),
    svc.deviceService.setChildLock({ actor, homeId: h2.id, enabled: true }),
  ]);
  const keys = new Set(w.db.log.filter((l) => l.sql.includes('pg_advisory_xact_lock')).map((l) => l.params[0]));
  assert.deepStrictEqual([...keys].sort(), [`child-lock:${h1.id}`, `child-lock:${h2.id}`].sort());
});

test('ESZAMANLILIK: ayni anda 10 ayni-yonlu istek hatasiz tamamlanir; her biri tutarli sonuc doner', async () => {
  setTestEnv();
  const w = createWorld();
  const svc = createServices(w);
  const user = w.helpers.addUser({ email: 'a@example.test' });
  const home = w.helpers.addHome({ name: 'Ev', owner: user });
  w.helpers.addDevice({ home, uuid: 'AHBU-CL-0001', mac: 'E8:F6:0A:00:00:01', online: true });
  const actor = { userId: user.id, globalRole: 'user', ip: '10.0.0.1', access: 'owner' };
  const results = await Promise.all(Array.from({ length: 10 }, () => svc.deviceService.setChildLock({ actor, homeId: home.id, enabled: true })));
  assert.ok(results.every((r) => r.delivered === true && r.requested === true));
  assert.strictEqual(w.db.rollbacks, 0);
  assert.strictEqual(home.child_lock_requested, true);
});

// ------------------------------------------------------------------------------------------------
// Ev basina hiz siniri
// ------------------------------------------------------------------------------------------------
test('hiz siniri: EV basina dakikada 6; iki rota ayni sayaci kullanir; 7. istek 429 RATE_LIMITED + Retry-After; baska ev etkilenmez', async (t) => {
  if (skipIfUnavailable(t)) return;
  const { home, dev } = makeHome({ locked: false });
  const token = tokenOf(owner);
  let enabled = true;
  for (let i = 1; i <= 6; i++) {
    const res = i % 2
      ? await api('post', lockUrl, token, lockBody(home, enabled))
      : await api('post', cmdUrl(dev), token, cmdBody(home, enabled));
    assert.strictEqual(res.status, 200, `istek ${i}: ${JSON.stringify(res.body)}`);
    enabled = !enabled;
  }
  for (const [url, body] of [[lockUrl, lockBody(home, true)], [cmdUrl(dev), cmdBody(home, true)]]) {
    const limited = await api('post', url, token, body);
    assert.strictEqual(limited.status, 429, url);
    assert.strictEqual(limited.body.code, 'RATE_LIMITED');
    assert.ok(limited.body.retry_after > 0);
    assert.ok(Number(limited.headers['retry-after']) > 0);
  }
  // baska ev ayri sayac
  const { home: home2 } = makeHome({ locked: false });
  assert.strictEqual((await api('post', lockUrl, token, lockBody(home2, true))).status, 200);
  // genel rotadaki DIGER komutlar bu sinira TABI DEGIL
  const relay = await api('post', cmdUrl(dev), token, { home_id: home.id, command: { relay: 5, state: true } });
  assert.strictEqual(relay.status, 200);
});

// ------------------------------------------------------------------------------------------------
// GET /child-lock
// ------------------------------------------------------------------------------------------------
test('GET: Cache-Control no-store; { child_lock_enabled, requested, devices[], in_sync }; REST yazimi durumu DEGISTIRMEZ', async (t) => {
  if (skipIfUnavailable(t)) return;
  const { home, dev } = makeHome({ locked: false });
  home.child_lock_enabled = false;
  const url = `/api/v1/devices/child-lock/${home.id}`;

  const before = await api('get', url, tokenOf(owner));
  assert.strictEqual(before.status, 200);
  assert.match(String(before.headers['cache-control']), /no-store/);
  assert.deepStrictEqual(before.body.data, {
    home_id: home.id, child_lock_enabled: false, requested: null, requested_at: null,
    devices: [{ device_uuid: dev.device_uuid, online: true, child_lock_enabled: false }], in_sync: true,
  });

  // komut gonderildi: niyet gorunur, gercek durum (cihaz bildirimi) HENUZ degismedi
  await api('post', lockUrl, tokenOf(owner), lockBody(home, true));
  const mid = await api('get', url, tokenOf(owner));
  assert.strictEqual(mid.body.data.child_lock_enabled, false, 'cihaz bildirmeden kilitli denmemeli');
  assert.strictEqual(mid.body.data.requested, true);
  assert.ok(mid.body.data.requested_at);

  // kopru: cihaz bildirdi (devices + homes esitlendi)
  dev.child_lock_enabled = true;
  home.child_lock_enabled = true;
  const after = await api('get', url, tokenOf(owner));
  assert.strictEqual(after.body.data.child_lock_enabled, true);
  assert.strictEqual(after.body.data.in_sync, true);

  // tutarsizlik: cevrimici pano homes degerinden farkli
  dev.child_lock_enabled = false;
  const drift = await api('get', url, tokenOf(owner));
  assert.strictEqual(drift.body.data.in_sync, false);
  // cevrimdisi pano tutarlilik hesabina girmez
  dev.is_online = false;
  assert.strictEqual((await api('get', url, tokenOf(owner))).body.data.in_sync, true);
});

test('GET: bilinmeyen/yetkisiz ev; getChildLock hatada FIRLATIR (sessizce false donmez)', async (t) => {
  if (skipIfUnavailable(t)) return;
  const res = await api('get', `/api/v1/devices/child-lock/${other.id}`, tokenOf(owner));
  assert.strictEqual(res.status, 403);
  const svc = createServices(createWorld());
  await expectHttp(svc.deviceService.getChildLock({ homeId: '00000000-0000-4000-8000-000000000000' }), 404, 'NOT_FOUND');
});

// ------------------------------------------------------------------------------------------------
// Kullaniciya donen metinler: dogru Turkce karakterler
// ------------------------------------------------------------------------------------------------
test('kullaniciya donen metinler dogru Turkce karakterlerle (UTF-8)', async (t) => {
  if (skipIfUnavailable(t)) return;
  const { home, dev } = makeHome({ online: false });
  const off = await api('post', lockUrl, tokenOf(owner), lockBody(home, true));
  assert.strictEqual(off.body.message, 'Pano çevrimdışı; çocuk kilidi komutu iletilemedi.');

  const svc = createServices(createWorld());
  const user = svc.deviceService; // servis hata metinleri
  await assert.rejects(
    user.setChildLock({ actor: { userId: 'u', access: 'guest' }, homeId: home.id, enabled: true }),
    (e) => e.message === 'Çocuk kilidini değiştirme yetkiniz yok.'
  );
  const live = makeHome();
  bridge.failPublish = true;
  const down = await api('post', lockUrl, tokenOf(owner), lockBody(live.home, true));
  assert.match(down.body.message, /üzerinden iletilemedi/);
  bridge.failPublish = false;
  void dev;
});

// ------------------------------------------------------------------------------------------------
// Acil sifirlama / pano degisimi (B5 / B6)
// ------------------------------------------------------------------------------------------------
async function lifecycleSetup({ online = true, locked = true } = {}) {
  setTestEnv();
  const w = createWorld();
  const svc = createServices(w);
  const lh = w.helpers;
  const tech = lh.addUser({ email: 'servis@example.test', role: 'service_user' });
  const ownerU = lh.addUser({ email: 'sahip@example.test' });
  const inv = lh.addInventory({ uuid: 'AHBU-LC-0001', pin: '246810', status: 'CLAIMED' });
  const home = lh.addHome({ name: 'Ev', owner: ownerU });
  lh.addMember(home, tech, 'service_user', { installer_expires_at: new Date(w.clock.t + 3600000) });
  const keyEnc = svc.secretBox.encrypt('EskiAnahtar123456');
  const dev = lh.addDevice({ home, uuid: 'AHBU-LC-0001', mac: inv.mac_address, claimedBy: ownerU, online, local_key_enc: keyEnc });
  lh.addEndpoints(home, dev, 8);
  inv.claimed_home_id = home.id;
  inv.pin_hash = 'CLAIMED_BURNED_PIN';
  if (locked) {
    dev.child_lock_enabled = true;
    home.child_lock_enabled = true;
    home.child_lock_requested = true;
    home.child_lock_requested_at = new Date(w.clock.t - 1000);
    home.child_lock_requested_by = ownerU.id;
  }
  await svc.credentials.issueDeviceCredential({ homeId: home.id, deviceId: dev.id });
  svc.timeline.length = 0;
  w.db.log.length = 0;
  return { w, ...svc, tech, ownerU, inv, home, dev, lh };
}

const resetCall = (c, o = {}) =>
  c.deviceService.emergencyReset({
    actor: { userId: c.tech.id, globalRole: 'service_user', ip: '203.0.113.9' },
    deviceUuid: 'AHBU-LC-0001', confirmUid: 'AHBU-LC-0001', reason: 'Kiraci ulasilamiyor, daire teslim alindi', ...o,
  });

test('acil sifirlama: homes + devices cocuk kilidi ve NIYET sifirlanir; panoya {cmd:"set_child_lock", enabled:false} yayinlanir (kick\'ten ONCE)', async () => {
  const c = await lifecycleSetup({ online: true, locked: true });
  const r = await resetCall(c);

  assert.strictEqual(r.child_lock_reset, 'published');
  assert.strictEqual(c.home.child_lock_enabled, false);
  assert.strictEqual(c.dev.child_lock_enabled, false, 'devices.child_lock_enabled de sifirlanmali');
  assert.strictEqual(c.home.child_lock_requested, null, 'bekleyen niyet temizlenmeli (kopru yeni sahibin panosunu kilitlemesin)');
  assert.strictEqual(c.home.child_lock_requested_by, null);

  const lockCmds = c.bridge.commands.filter((x) => x.obj.cmd === 'set_child_lock');
  assert.strictEqual(lockCmds.length, 1);
  assert.strictEqual(lockCmds[0].topicId, c.home.mqtt_username);
  assert.strictEqual(lockCmds[0].obj.enabled, false);
  assert.match(lockCmds[0].obj.id, /^[A-Za-z0-9_-]{12}$/);
  // sira: kilit sifirlama -> yerel anahtar (sys) -> (baglanti atma yok: EMQX tanimsiz) -> retained temizligi
  const t = c.timeline;
  assert.ok(t.indexOf('publishCommand') >= 0 && t.indexOf('publishCommand') < t.indexOf('publishSys') && t.indexOf('publishSys') < t.indexOf('clearRetained'), t.join(','));
  // yerel anahtar C paketinin publishSys'iyle (yuk loglanmaz) iletildi
  assert.strictEqual(c.bridge.topics[0].via, 'publishSys');
  assert.strictEqual(c.bridge.topics[0].topic, `ev/${c.home.mqtt_username}/sys`);
});

test('acil sifirlama: yeni sahibe devirde de kilit sifirlanir (REASSIGNED)', async () => {
  const c = await lifecycleSetup({ online: true, locked: true });
  const buyer = c.lh.addUser({ email: 'yeni@example.test' });
  const r = await resetCall(c, { newOwnerIdentifier: buyer.email });
  assert.strictEqual(r.action, 'REASSIGNED');
  assert.strictEqual(r.child_lock_reset, 'published');
  assert.strictEqual(c.dev.child_lock_enabled, false);
  assert.strictEqual(c.home.child_lock_enabled, false);
  assert.strictEqual(c.bridge.commands.filter((x) => x.obj.cmd === 'set_child_lock' && x.obj.enabled === false).length, 1);
});

test('acil sifirlama: pano cevrimdisi -> child_lock_reset "skipped_offline" + uyari (DB yine sifirlanir); yayin hatasi -> "failed" + uyari, sifirlama TAMAMLANIR', async () => {
  const off = await lifecycleSetup({ online: false, locked: true });
  const r1 = await resetCall(off);
  assert.strictEqual(r1.child_lock_reset, 'skipped_offline');
  assert.ok(r1.warnings.some((w) => /çocuk kilidi sıfırlanamadı/.test(w)), JSON.stringify(r1.warnings));
  assert.strictEqual(r1.partial, true);
  assert.strictEqual(off.dev.child_lock_enabled, false);
  assert.strictEqual(off.bridge.commands.length, 0);

  const bad = await lifecycleSetup({ online: true, locked: true });
  bad.bridge.failPublish = true;
  const r2 = await resetCall(bad);
  assert.strictEqual(r2.action, 'UNCLAIMED');
  assert.strictEqual(r2.child_lock_reset, 'failed');
  assert.ok(r2.warnings.some((w) => /Çocuk kilidi sıfırlama komutu panoya iletilemedi/.test(w)), JSON.stringify(r2.warnings));
  assert.match(r2.setup_pin, /^\d{6}$/, 'sifirlama commit edildi; PIN doner');
});

test('acil sifirlama: ev yoksa (stokta cihaz) child_lock_reset "skipped"; commit sonrasi komut yayini yok', async () => {
  const c = await lifecycleSetup({ online: true, locked: false });
  c.lh.addInventory({ uuid: 'AHBU-LC-0002', pin: '111222', status: 'IN_STOCK' });
  const root = c.lh.addUser({ email: 'root@example.test', role: 'super_user' });
  const r = await c.deviceService.emergencyReset({
    actor: { userId: root.id, globalRole: 'super_user', ip: '1.1.1.1' }, deviceUuid: 'AHBU-LC-0002', confirmUid: 'AHBU-LC-0002',
    reason: 'Stoktaki cihazin PIN yenilemesi',
  });
  assert.strictEqual(r.child_lock_reset, 'skipped');
  assert.strictEqual(c.bridge.commands.length, 0);
});

async function replaceSetup({ homeLocked = true, oldLocked = false } = {}) {
  const c = await lifecycleSetup({ online: true, locked: false });
  c.newInv = c.lh.addInventory({ uuid: 'AHBU-LC-0002', pin: '135790', status: 'IN_STOCK' });
  c.home.child_lock_enabled = homeLocked;
  c.dev.child_lock_enabled = oldLocked;
  return c;
}
const replaceCall = (c) =>
  c.deviceService.replaceBoard({
    actor: { userId: c.tech.id, globalRole: 'service_user', ip: '198.51.100.4', access: 'service_user', label: 'Ali Usta' },
    homeId: c.home.id, oldDeviceUuid: 'AHBU-LC-0001', newDeviceUuid: 'AHBU-LC-0002', setupPin: '135790', reason: 'Pano yandı',
  });

test('pano degisimi: onceki kilit YENI panoya yeniden uygulanmak uzere NIYET olarak tasinir (pano henuz cevrimdisi: pending_device_online)', async () => {
  const c = await replaceSetup({ homeLocked: true });
  const r = await replaceCall(c);
  assert.deepStrictEqual(r.child_lock, { enabled: true, sync: 'pending_device_online' });
  assert.strictEqual(c.home.child_lock_requested, true, 'niyet: yeni pano cevrimici olunca kilit yeniden uygulanmali');
  assert.strictEqual(c.home.child_lock_requested_by, c.tech.id);
  const newDev = c.w.state.devices.find((d) => d.device_uuid === 'AHBU-LC-0002');
  assert.ok(!newDev.child_lock_enabled, 'yeni panonun GERCEK durum bayragi degistirilmemeli (cihaz bildirir)');
  assert.strictEqual(c.bridge.commands.filter((x) => x.obj.cmd === 'set_child_lock').length, 0, 'yeni pano cevrimdisi: komut yayini yok');
  assert.strictEqual(c.w.state.device_audit_logs.find((a) => a.event === 'board_replaced').details.child_lock_carried, true);
});

test('pano degisimi: eski panonun kendi bayragi kilitliyse de tasinir; kilit yoksa dokunulmaz (not_required)', async () => {
  const a = await replaceSetup({ homeLocked: false, oldLocked: true });
  const ra = await replaceCall(a);
  assert.strictEqual(ra.child_lock.enabled, true);
  assert.strictEqual(a.home.child_lock_requested, true);

  const b = await replaceSetup({ homeLocked: false, oldLocked: false });
  const rb = await replaceCall(b);
  assert.deepStrictEqual(rb.child_lock, { enabled: false, sync: 'not_required' });
  assert.ok(b.home.child_lock_requested === undefined || b.home.child_lock_requested === null);
  assert.ok(!b.w.db.sqls().some((s) => s.includes('UPDATE homes SET child_lock_requested')), 'kilit yoksa niyet yazilmamali');
});

// ------------------------------------------------------------------------------------------------
test('kaynak: cocuk kilidi icin devices/homes DURUM yazimi YOK; "kilitlendi" (uygulandi) iddiasi YOK; tek uygulama', () => {
  const fs = require('fs');
  const strip = (text) => text.replace(/\/\*[\s\S]*?\*\//g, '').replace(/\/\/.*$/gm, '');
  const src = fs.readFileSync(require.resolve('../../src/services/device_service'), 'utf8');
  assert.ok(!/UPDATE homes SET child_lock_enabled = \$/.test(src), 'REST istenen degeri durum olarak yazmamali');
  assert.ok(!/UPDATE devices SET child_lock_enabled = \$/.test(src));
  assert.ok(/child_lock_set/.test(src));
  assert.ok(/pg_advisory_xact_lock\(hashtext\(\$1\)\)/.test(src));

  // Cocuk kilidi akisinin (uygulama + ince sarmalayici + GET) kodu: "kilitlendi" gibi uygulandi iddiasi icermemeli.
  // (PIN kilidi mesajlari baska bir konudur ve bu bolumun disindadir.)
  const section = src.slice(src.indexOf('async _applyChildLock('), src.indexOf('async getPeaceNotificationSettings('));
  assert.ok(section.length > 500, 'cocuk kilidi bolumu bulunamadi');
  assert.ok(!/kilitlendi|kilitli kalmis olabilir.*basar/i.test(strip(section)), 'uygulandi iddiasi olmamali');
  const routes = fs.readFileSync(require.resolve('../../src/routes/device_routes'), 'utf8');
  assert.ok(!/kilitlendi/i.test(strip(routes)), 'route mesajlarinda uygulandi iddiasi olmamali');

  // Tek uygulama: genel komut yolu cocuk kilidini AYNI fonksiyona devreder
  assert.ok(/KINDS\.CHILD_LOCK[\s\S]{0,200}_applyChildLock\(/.test(src), 'sendCommand set_child_lock icin _applyChildLock kullanmali');
  assert.ok(/async setChildLock\([^)]*\)\s*\{\s*return this\._applyChildLock\(/.test(src), 'setChildLock ince sarmalayici olmali');
});

test.after(() => env.teardown());
