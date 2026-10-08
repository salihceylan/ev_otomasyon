'use strict';

// B1 / B11: route katmani - HER uc kimlik dogrulama + ev yetkisi; rol x uc matrisi; home_id yalniz dogrulanmis uyelikten

const test = require('node:test');
const assert = require('node:assert');
const request = require('supertest');

const { buildRouteEnv, listRoutes, HOME_A, HOME_B, USER } = require('./_routes_env');
const { httpError } = require('../../src/utils/http_errors');

const env = buildRouteEnv();
const { app, registry, deviceService, endpointService, mqttCredentials } = env;

// ------------------------------------------------------------------------------------------------
// Aktorler (HOME_A): super, staff, servis oturumu, owner, resident, misafir (+ disaridan biri, suresi dolmus misafir)
// ------------------------------------------------------------------------------------------------
const FUTURE = new Date(Date.now() + 3600 * 1000).toISOString();
const PAST = new Date(Date.now() - 3600 * 1000).toISOString();
registry.members.push(
  { home_id: HOME_A, user_id: 'u-owner', role: 'owner' },
  { home_id: HOME_A, user_id: 'u-res', role: 'resident' },
  { home_id: HOME_A, user_id: 'u-guest', role: 'guest', valid_until: FUTURE },
  { home_id: HOME_A, user_id: 'u-guest-exp', role: 'guest', valid_until: PAST },
  { home_id: HOME_A, user_id: 'u-staff', role: 'service_user' },
  { home_id: HOME_B, user_id: 'u-other', role: 'owner' },
);

const ACTORS = {
  super: { header: USER({ id: 'u-super', role: 'super_user' }) },
  staff: { header: USER({ id: 'u-staff', role: 'service_user' }) },
  session: { header: JSON.stringify({ id: null, role: 'service_session', is_service_session: true, home_id: HOME_A, sid: 'sid-1' }) },
  owner: { header: USER({ id: 'u-owner' }) },
  resident: { header: USER({ id: 'u-res' }) },
  guest: { header: USER({ id: 'u-guest' }) },
};
const ORDER = ['super', 'staff', 'session', 'owner', 'resident', 'guest'];
const OUTSIDER = USER({ id: 'u-out' });
const EXPIRED_GUEST = USER({ id: 'u-guest-exp' });

function allowed(...names) {
  return new Set(names);
}
const ALL = allowed(...ORDER);
const NOT_GUEST = allowed('super', 'staff', 'session', 'owner', 'resident');
const CALIBRATE = allowed('super', 'staff', 'session', 'owner');
const COMMISSION = allowed('super', 'staff', 'session');
const LOCAL_KEY = allowed('staff', 'session', 'owner', 'resident');

const UUID = 'AHBU-S3-0001';

// Her ev kapsamli uc: [aciklama, method, url, body, izinli roller, cagrilan servis metodu]
const CASES = [
  ['komut', 'post', '/api/v1/devices/dev-1/command', { home_id: HOME_A, command: { relay: 1, state: true } }, ALL, ['device', 'sendCommand']],
  ['endpoint kontrol', 'post', `/api/v1/homes/${HOME_A}/endpoints/e-1/control`, { cmd: 'toggle' }, ALL, ['endpoint', 'controlEndpoint']],
  ['endpoint listesi', 'get', `/api/v1/homes/${HOME_A}/endpoints`, null, ALL, ['endpoint', 'getEndpointsByHome']],
  ['endpoint kalibrasyon', 'put', `/api/v1/homes/${HOME_A}/endpoints/e-1`, { shutter_duration_sec: 20 }, CALIBRATE, ['endpoint', 'updateEndpoint']],
  ['cihaz listesi', 'get', `/api/v1/homes/${HOME_A}/devices`, null, ALL, ['device', 'listDevices']],
  ['cihaz listesi (eski yol)', 'get', `/api/v1/devices/home/${HOME_A}`, null, ALL, ['device', 'listDevices']],
  ['yerel anahtar', 'get', `/api/v1/homes/${HOME_A}/devices/${UUID}/local-key`, null, LOCAL_KEY, ['device', 'getLocalKey']],
  ['cihaz kimligi yenile', 'post', `/api/v1/homes/${HOME_A}/devices/${UUID}/mqtt-credential`, {}, CALIBRATE, ['device', 'reissueDeviceCredential']],
  ['devreye alma', 'post', `/api/v1/homes/${HOME_A}/commissioning`, { device_uuid: UUID, checks: {} }, COMMISSION, ['device', 'commissionHome']],
  ['devreye alma durumu', 'get', `/api/v1/homes/${HOME_A}/commissioning-status`, null, CALIBRATE, ['device', 'getCommissioningStatus']],
  ['MQTT kimligi (uygulama)', 'post', `/api/v1/homes/${HOME_A}/mqtt-credentials`, {}, ALL, ['mqtt', 'issueUserCredential']],
  ['pano degisimi', 'post', '/api/v1/devices/replace-board', { home_id: HOME_A, new_device_uuid: 'AHBU-S3-0002', setup_pin: '123456' }, CALIBRATE, ['device', 'replaceBoard']],
  ['cocuk kilidi yaz', 'post', '/api/v1/devices/child-lock', { home_id: HOME_A, enabled: true }, NOT_GUEST, ['device', 'setChildLock']],
  ['cocuk kilidi oku', 'get', `/api/v1/devices/child-lock/${HOME_A}`, null, ALL, ['device', 'getChildLock']],
  ['huzur oku', 'get', `/api/v1/devices/peace-notification/${HOME_A}`, null, ALL, ['device', 'getPeaceNotificationSettings']],
  ['huzur yaz', 'put', `/api/v1/devices/peace-notification/${HOME_A}`, { enabled: false }, NOT_GUEST, ['device', 'updatePeaceNotificationSettings']],
  ['hepsini kapat', 'post', '/api/v1/devices/peace-notification/close-all', { home_id: HOME_A }, NOT_GUEST, ['device', 'closeAllOpenLights']],
  ['teshis (yol)', 'get', `/api/v1/devices/diagnostic/${HOME_A}`, null, NOT_GUEST, ['device', 'getSystemDiagnostic']],
  ['teshis (sorgu)', 'get', `/api/v1/devices/diagnostic?home_id=${HOME_A}`, null, NOT_GUEST, ['device', 'getSystemDiagnostic']],
];

const svcOf = (name) => ({ device: deviceService, endpoint: endpointService, mqtt: mqttCredentials }[name]);

function send(method, url, header, body) {
  let r = request(app)[method](url);
  if (header) r = r.set('x-test-user', header);
  if (body !== null && body !== undefined && method !== 'get') r = r.send(body);
  return r;
}

test.beforeEach(() => {
  for (const s of [deviceService, endpointService, mqttCredentials]) {
    s.calls.length = 0;
    s.failWith = {};
  }
});

// ------------------------------------------------------------------------------------------------
// Yapisal denetim: HER uc authenticateToken ile baslar; ev kapsamli ucta requireHomeAccess + dogru rol listesi vardir
// ------------------------------------------------------------------------------------------------
test('B1 yapisal: tum uclarin ilk middleware halkasi authenticateToken; ev kapsamli ucta requireHomeAccess ve rol listesi var', () => {
  const all = [
    ...listRoutes(env.routers.device, '/devices'),
    ...listRoutes(env.routers.homeDevice, '/homes'),
    ...listRoutes(env.routers.endpoint, '/homes/:home_id/endpoints'),
    ...listRoutes(env.routers.mqtt, '/homes'),
  ];

  // Kesin uc listesi: yeni bir uc eklenirse bu test KIRILIR ve ucun kapisi/matrisi gozden gecirilir.
  const EXPECTED = [
    'POST /devices/claim/request-otp', 'POST /devices/claim', 'POST /devices/emergency-reset', 'POST /devices/replace-board',
    'POST /devices/child-lock', 'GET /devices/child-lock/:home_id', 'GET /devices/peace-notification/:home_id',
    'PUT /devices/peace-notification/:home_id', 'POST /devices/peace-notification/close-all',
    'GET /devices/diagnostic/:home_id', 'GET /devices/diagnostic', 'GET /devices/home/:home_id', 'POST /devices/:id/command',
    'GET /homes/:homeId/devices', 'GET /homes/:homeId/devices/:uuid/local-key',
    'POST /homes/:homeId/devices/:uuid/mqtt-credential', 'POST /homes/:homeId/commissioning',
    'GET /homes/:homeId/commissioning-status', 'GET /homes/:home_id/endpoints/', 'PUT /homes/:home_id/endpoints/:id',
    'POST /homes/:home_id/endpoints/:id/control', 'POST /homes/:homeId/mqtt-credentials',
  ];
  assert.deepStrictEqual(all.map((r) => `${r.method} ${r.path}`).sort(), [...EXPECTED].sort());

  const GLOBAL_ONLY = new Set(['POST /devices/claim/request-otp', 'POST /devices/claim', 'POST /devices/emergency-reset']);
  for (const r of all) {
    const key = `${r.method} ${r.path}`;
    assert.strictEqual(r.handlers[0].__tag, 'authenticateToken', `${key}: ilk middleware authenticateToken degil`);
    const homeGate = r.handlers.find((h) => h.__tag === 'homeAccess');
    if (GLOBAL_ONLY.has(key)) {
      assert.strictEqual(homeGate, undefined, `${key}: ev kapsamsiz uc`);
      assert.ok(r.handlers.length >= 4, `${key}: kimlik + global rol kapisi + hiz siniri + isleyici olmali`);
    } else {
      assert.ok(homeGate, `${key}: requireHomeAccess YOK (IDOR riski)`);
      assert.ok(Array.isArray(homeGate.__roles) && homeGate.__roles.length > 0, `${key}: rol listesi bos`);
    }
  }
});

test('B1 yapisal: rol listeleri yetki matrisinin birebir ayni (CONTRACTS §1.4)', () => {
  const rolesOf = (router, prefix, method, p) => {
    const route = listRoutes(router, prefix).find((r) => r.method === method && r.path === `${prefix}${p}`);
    assert.ok(route, `${method} ${prefix}${p} bulunamadi`);
    return new Set(route.handlers.find((h) => h.__tag === 'homeAccess').__roles);
  };
  const map = (names) => new Set(names.map((n) => ({ super: 'super_user', staff: 'service_user', session: 'service_session', owner: 'owner', resident: 'resident', guest: 'guest' }[n])));
  const eq = (actual, expectedNames, label) => assert.deepStrictEqual([...actual].sort(), [...map(expectedNames)].sort(), label);

  eq(rolesOf(env.routers.device, '/devices', 'POST', '/:id/command'), ORDER, 'komut');
  eq(rolesOf(env.routers.device, '/devices', 'POST', '/replace-board'), [...CALIBRATE], 'pano degisimi');
  eq(rolesOf(env.routers.device, '/devices', 'POST', '/child-lock'), [...NOT_GUEST], 'cocuk kilidi');
  eq(rolesOf(env.routers.device, '/devices', 'POST', '/peace-notification/close-all'), [...NOT_GUEST], 'hepsini kapat');
  eq(rolesOf(env.routers.homeDevice, '/homes', 'POST', '/:homeId/commissioning'), [...COMMISSION], 'devreye alma');
  eq(rolesOf(env.routers.homeDevice, '/homes', 'GET', '/:homeId/devices/:uuid/local-key'), [...LOCAL_KEY], 'yerel anahtar');
  eq(rolesOf(env.routers.endpoint, '/homes/:home_id/endpoints', 'PUT', '/:id'), [...CALIBRATE], 'kalibrasyon');
  eq(rolesOf(env.routers.mqtt, '/homes', 'POST', '/:homeId/mqtt-credentials'), ORDER, 'mqtt-credentials');
});

// ------------------------------------------------------------------------------------------------
// HTTP matrisi: her uc x her rol
// ------------------------------------------------------------------------------------------------
for (const [label, method, url, body, allowedRoles, [svcName, methodName]] of CASES) {
  test(`matris: ${label} (${method.toUpperCase()}) - izinli roller ulasir, digerleri 403 ve servis CAGRILMAZ`, async () => {
    const svc = svcOf(svcName);
    for (const role of ORDER) {
      svc.calls.length = 0;
      const res = await send(method, url, ACTORS[role].header, body);
      if (allowedRoles.has(role)) {
        assert.strictEqual(res.status, 200, `${role}: ${res.status} ${JSON.stringify(res.body)}`);
        assert.strictEqual(res.body.success, true);
        assert.strictEqual(svc.calls.filter((c) => c.name === methodName).length, 1, `${role}: servis cagrilmali`);
      } else {
        assert.strictEqual(res.status, 403, `${role}: ${res.status} ${JSON.stringify(res.body)}`);
        assert.strictEqual(res.body.success, false);
        assert.strictEqual(svc.calls.length, 0, `${role}: yetkisiz istek servise ULASMAMALI`);
      }
    }
  });

  test(`kimliksiz/disaridan/suresi dolmus misafir: ${label} -> 401 / 403 / GUEST_EXPIRED`, async () => {
    const svc = svcOf(svcName);
    const anon = await send(method, url, null, body);
    assert.strictEqual(anon.status, 401);
    const out = await send(method, url, OUTSIDER, body);
    assert.strictEqual(out.status, 403);
    const expired = await send(method, url, EXPIRED_GUEST, body);
    assert.strictEqual(expired.status, 403);
    assert.strictEqual(expired.body.code, 'GUEST_EXPIRED');
    assert.strictEqual(svc.calls.length, 0);
  });
}

test('baska evin uyesi bu eve erisemez (IDOR): HOME_B owner\'i HOME_A uclarinda 403', async () => {
  const other = USER({ id: 'u-other' });
  for (const [, method, url, body, , [svcName]] of CASES) {
    const res = await send(method, url, other, body);
    assert.strictEqual(res.status, 403, `${method} ${url}`);
    assert.strictEqual(svcOf(svcName).calls.length, 0);
  }
});

// ------------------------------------------------------------------------------------------------
// home_id YALNIZCA dogrulanmis uyelikten
// ------------------------------------------------------------------------------------------------
test('home_id servise requireHomeAccess sonucundan (kucuk harfe normallestirilmis) gider; govde ham degeri degil', async () => {
  const res = await send('post', '/api/v1/devices/dev-1/command', ACTORS.owner.header, {
    home_id: HOME_A.toUpperCase(),
    command: { relay: 1, state: true },
  });
  assert.strictEqual(res.status, 200);
  const call = deviceService.calls.find((c) => c.name === 'sendCommand');
  assert.strictEqual(call.args.homeId, HOME_A, 'servis dogrulanmis (normallestirilmis) home_id almali');
  assert.strictEqual(call.args.deviceRef, 'dev-1');
  assert.deepStrictEqual(call.args.command, { relay: 1, state: true });
  assert.strictEqual(call.args.actor.userId, 'u-owner');
  assert.strictEqual(call.args.actor.access, 'owner');
});

test('camelCase homeId govdesi de kabul edilir; home_id ve homeId uyusmazsa 400', async () => {
  const ok = await send('post', '/api/v1/devices/child-lock', ACTORS.owner.header, { homeId: HOME_A, enabled: true });
  assert.strictEqual(ok.status, 200);
  const bad = await send('post', '/api/v1/devices/child-lock', ACTORS.owner.header, { home_id: HOME_A, homeId: HOME_B, enabled: true });
  assert.strictEqual(bad.status, 400);
  const missing = await send('post', '/api/v1/devices/child-lock', ACTORS.owner.header, { enabled: true });
  assert.strictEqual(missing.status, 400);
  assert.strictEqual(deviceService.calls.filter((c) => c.name === 'setChildLock').length, 1);
});

test('teshis home_id olmadan 400 (sessiz "ilk ev" yok)', async () => {
  const res = await send('get', '/api/v1/devices/diagnostic', ACTORS.owner.header);
  assert.strictEqual(res.status, 400);
  assert.strictEqual(deviceService.calls.length, 0);
});

test('servis oturumu yalnizca KENDI evinde calisir; baska eve 403; kullanici kimligi yok', async () => {
  const denied = await send('get', `/api/v1/homes/${HOME_B}/devices`, ACTORS.session.header);
  assert.strictEqual(denied.status, 403);
  assert.strictEqual(deviceService.calls.length, 0);

  const own = await send('get', `/api/v1/homes/${HOME_A}/devices/${UUID}/local-key`, ACTORS.session.header);
  assert.strictEqual(own.status, 200);
  const actor = deviceService.calls[0].args.actor;
  assert.strictEqual(actor.isServiceSession, true);
  assert.strictEqual(actor.userId, null);
  assert.strictEqual(actor.access, 'service_session');
  assert.strictEqual(actor.sessionId, 'sid-1');
});

// ------------------------------------------------------------------------------------------------
// Ev kapsamsiz uclar: sahiplenme / OTP / acil sifirlama
// ------------------------------------------------------------------------------------------------
test('claim: normal kullanici/staff/super gecer; servis oturumu ve kimliksiz 403/401; home_id GOVDEDEN alinmaz', async () => {
  const body = { device_uuid: UUID, setup_pin: '123456', home_id: HOME_B, homeId: HOME_B };
  const user = await send('post', '/api/v1/devices/claim', USER({ id: 'claim-user-1' }), body);
  assert.strictEqual(user.status, 200);
  const args = deviceService.calls.find((c) => c.name === 'claimDevice').args;
  assert.ok(!('homeId' in args) && !('home_id' in args), 'home_id servise iletilmemeli');
  assert.strictEqual(args.deviceUuid, UUID);
  assert.strictEqual(args.setupPin, '123456');
  assert.strictEqual(args.actor.userId, 'claim-user-1');

  const staff = await send('post', '/api/v1/devices/claim', USER({ id: 'claim-staff-1', role: 'service_user' }), body);
  assert.strictEqual(staff.status, 200);
  const sup = await send('post', '/api/v1/devices/claim', USER({ id: 'claim-super-1', role: 'super_user' }), body);
  assert.strictEqual(sup.status, 200);

  deviceService.calls.length = 0;
  const session = await send('post', '/api/v1/devices/claim', ACTORS.session.header, body);
  assert.strictEqual(session.status, 403);
  const anon = await send('post', '/api/v1/devices/claim', null, body);
  assert.strictEqual(anon.status, 401);
  const weird = await send('post', '/api/v1/devices/claim', USER({ id: 'x', role: 'admin' }), body);
  assert.strictEqual(weird.status, 403);
  assert.strictEqual(deviceService.calls.length, 0);
});

test('claim: snake_case ve camelCase gecis alanlari; target_owner / otp_code servise iletilir', async () => {
  const res = await send('post', '/api/v1/devices/claim', USER({ id: 'claim-user-2', role: 'service_user' }), {
    deviceUuid: UUID, setupPin: '654321', homeName: 'Daire 9', targetOwner: 'musteri@example.test', otpCode: '111222',
  });
  assert.strictEqual(res.status, 200);
  const args = deviceService.calls[0].args;
  assert.deepStrictEqual(
    { d: args.deviceUuid, p: args.setupPin, n: args.homeName, t: args.targetOwnerIdentifier, o: args.otpCode },
    { d: UUID, p: '654321', n: 'Daire 9', t: 'musteri@example.test', o: '111222' }
  );
});

test('OTP isteme: yalnizca staff/super; normal kullanici ve servis oturumu 403', async () => {
  const body = { device_uuid: UUID, target_owner: 'musteri@example.test' };
  for (const [header, status] of [
    [USER({ id: 'otp-staff-1', role: 'service_user' }), 200],
    [USER({ id: 'otp-super-1', role: 'super_user' }), 200],
    [USER({ id: 'otp-user-1', role: 'user' }), 403],
    [ACTORS.session.header, 403],
    [null, 401],
  ]) {
    deviceService.calls.length = 0;
    const res = await send('post', '/api/v1/devices/claim/request-otp', header, body);
    assert.strictEqual(res.status, status);
    assert.strictEqual(deviceService.calls.length, status === 200 ? 1 : 0);
  }
});

test('acil sifirlama: yalnizca staff/super (owner dahil herkes 403); alanlar servise iletilir', async () => {
  const body = { device_uuid: UUID, confirm_uid: UUID, reason: 'Kiraci ulasilamiyor, daire teslim', new_owner_identifier: 'yeni@example.test' };
  for (const [header, status] of [
    [USER({ id: 'rst-staff-1', role: 'service_user' }), 200],
    [USER({ id: 'rst-super-1', role: 'super_user' }), 200],
    [ACTORS.owner.header, 403],
    [ACTORS.resident.header, 403],
    [ACTORS.guest.header, 403],
    [ACTORS.session.header, 403],
    [null, 401],
  ]) {
    deviceService.calls.length = 0;
    const res = await send('post', '/api/v1/devices/emergency-reset', header, body);
    assert.strictEqual(res.status, status, JSON.stringify(res.body));
    assert.strictEqual(deviceService.calls.length, status === 200 ? 1 : 0);
  }
  const res = await send('post', '/api/v1/devices/emergency-reset', USER({ id: 'rst-staff-2', role: 'service_user' }), body);
  const args = deviceService.calls.find((c) => c.name === 'emergencyReset').args;
  assert.deepStrictEqual(
    { d: args.deviceUuid, c: args.confirmUid, r: args.reason, n: args.newOwnerIdentifier },
    { d: UUID, c: UUID, r: body.reason, n: 'yeni@example.test' }
  );
  assert.strictEqual(res.status, 200);
});

// ------------------------------------------------------------------------------------------------
// Hiz sinirlari (IP + kullanici + cihaz)
// ------------------------------------------------------------------------------------------------
test('hiz siniri: claim kullanici+UID basina 15 dk\'da 10; 11. istek 429 RATE_LIMITED + Retry-After', async () => {
  const header = USER({ id: 'rl-claim-user' });
  const body = { device_uuid: 'AHBU-RL-0001', setup_pin: '123456' };
  for (let i = 1; i <= 10; i++) {
    const res = await send('post', '/api/v1/devices/claim', header, body);
    assert.strictEqual(res.status, 200, `istek ${i}`);
  }
  const limited = await send('post', '/api/v1/devices/claim', header, body);
  assert.strictEqual(limited.status, 429);
  assert.strictEqual(limited.body.code, 'RATE_LIMITED');
  assert.ok(Number(limited.headers['retry-after']) > 0);
  assert.ok(limited.body.retry_after > 0);
  // baska cihaz UID'si ayri sayac
  const other = await send('post', '/api/v1/devices/claim', header, { device_uuid: 'AHBU-RL-0002', setup_pin: '123456' });
  assert.strictEqual(other.status, 200);
});

test('hiz siniri: OTP isteme (cihaz+hedef) saatte 5; 6. istek 429', async () => {
  const header = USER({ id: 'rl-otp-staff', role: 'service_user' });
  const body = { device_uuid: 'AHBU-RL-0010', target_owner: 'rl@example.test' };
  for (let i = 1; i <= 5; i++) {
    assert.strictEqual((await send('post', '/api/v1/devices/claim/request-otp', header, body)).status, 200, `istek ${i}`);
  }
  const limited = await send('post', '/api/v1/devices/claim/request-otp', header, body);
  assert.strictEqual(limited.status, 429);
  assert.strictEqual(limited.body.code, 'RATE_LIMITED');
});

test('hiz siniri: acil sifirlama kullanici basina saatte 10', async () => {
  const header = USER({ id: 'rl-reset-staff', role: 'service_user' });
  const body = { device_uuid: UUID, confirm_uid: UUID, reason: 'Kiraci ulasilamiyor, daire teslim' };
  for (let i = 1; i <= 10; i++) {
    assert.strictEqual((await send('post', '/api/v1/devices/emergency-reset', header, body)).status, 200, `istek ${i}`);
  }
  assert.strictEqual((await send('post', '/api/v1/devices/emergency-reset', header, body)).status, 429);
});

test('hiz siniri: cihaz kimligi yeniden uretimi 15 dk\'da 5', async () => {
  const header = USER({ id: 'rl-cred-owner' });
  registry.members.push({ home_id: HOME_A, user_id: 'rl-cred-owner', role: 'owner' });
  const url = `/api/v1/homes/${HOME_A}/devices/${UUID}/mqtt-credential`;
  for (let i = 1; i <= 5; i++) assert.strictEqual((await send('post', url, header, {})).status, 200, `istek ${i}`);
  assert.strictEqual((await send('post', url, header, {})).status, 429);
});

// ------------------------------------------------------------------------------------------------
// Hata esleme ve yanit bicimi
// ------------------------------------------------------------------------------------------------
test('hata yanitlari: PIN_LOCKED 423 + retry_after + Retry-After; DEVICE_OFFLINE 409; BROKER_UNAVAILABLE 502', async () => {
  deviceService.failWith.claimDevice = httpError(423, 'Cihaz kilitli.', 'PIN_LOCKED', { retry_after: 600 });
  let res = await send('post', '/api/v1/devices/claim', USER({ id: 'err-user-1' }), { device_uuid: UUID, setup_pin: '123456' });
  assert.strictEqual(res.status, 423);
  assert.deepStrictEqual(res.body, { success: false, message: 'Cihaz kilitli.', code: 'PIN_LOCKED', retry_after: 600 });
  assert.strictEqual(res.headers['retry-after'], '600');

  deviceService.failWith.sendCommand = httpError(409, 'Cihaz cevrimdisi; komut iletilmedi.', 'DEVICE_OFFLINE', { device_online: false });
  res = await send('post', '/api/v1/devices/dev-1/command', ACTORS.owner.header, { home_id: HOME_A, command: { relay: 1, state: true } });
  assert.strictEqual(res.status, 409);
  assert.strictEqual(res.body.code, 'DEVICE_OFFLINE');
  assert.strictEqual(res.body.device_online, false);

  deviceService.failWith.sendCommand = httpError(502, 'Komut MQTT broker uzerinden iletilemedi.', 'BROKER_UNAVAILABLE');
  res = await send('post', '/api/v1/devices/dev-1/command', ACTORS.owner.header, { home_id: HOME_A, command: { relay: 1, state: true } });
  assert.strictEqual(res.status, 502);
  assert.strictEqual(res.body.code, 'BROKER_UNAVAILABLE');
});

test('beklenmeyen hata: 500 + GENEL mesaj (SQL/kisit/yigin sizmaz)', async () => {
  const orig = console.error;
  console.error = () => {};
  try {
    const e = new Error('duplicate key value violates unique constraint "devices_mac_address_key" SECRET');
    e.code = '23505';
    deviceService.failWith.listDevices = e;
    const res = await send('get', `/api/v1/homes/${HOME_A}/devices`, ACTORS.owner.header);
    assert.strictEqual(res.status, 500);
    assert.strictEqual(res.body.success, false);
    assert.ok(!/devices_mac_address_key|SECRET|duplicate/.test(JSON.stringify(res.body)));
    assert.strictEqual(res.body.code, 'INTERNAL');
  } finally {
    console.error = orig;
  }
});

test('basarili yanit bicimi { success, message, data }', async () => {
  const res = await send('get', `/api/v1/homes/${HOME_A}/devices/${UUID}/local-key`, ACTORS.owner.header);
  assert.strictEqual(res.status, 200);
  assert.deepStrictEqual(Object.keys(res.body).sort(), ['data', 'message', 'success']);
  assert.deepStrictEqual(res.body.data, { local_key: 'AnahtarAnahtar123' });
});

test('sir iceren yanitlar onbelleklenmez (Cache-Control: no-store)', async () => {
  const secretCalls = [
    ['post', '/api/v1/devices/claim', USER({ id: 'ns-user-1' }), { device_uuid: UUID, setup_pin: '123456' }],
    ['post', '/api/v1/devices/claim/request-otp', USER({ id: 'ns-staff-1', role: 'service_user' }), { device_uuid: UUID, target_owner: 'a@b.co' }],
    ['post', '/api/v1/devices/emergency-reset', USER({ id: 'ns-staff-2', role: 'service_user' }), { device_uuid: UUID, confirm_uid: UUID, reason: 'x'.repeat(20) }],
    ['post', '/api/v1/devices/replace-board', ACTORS.owner.header, { home_id: HOME_A, new_device_uuid: 'AHBU-S3-0002', setup_pin: '123456' }],
    ['get', `/api/v1/homes/${HOME_A}/devices/${UUID}/local-key`, ACTORS.owner.header, null],
    ['post', `/api/v1/homes/${HOME_A}/mqtt-credentials`, ACTORS.owner.header, {}],
    ['post', `/api/v1/homes/${HOME_A}/devices/${UUID}/mqtt-credential`, ACTORS.owner.header, {}],
  ];
  for (const [method, url, header, body] of secretCalls) {
    const res = await send(method, url, header, body);
    assert.strictEqual(res.status, 200, `${method} ${url}: ${res.status}`);
    assert.match(String(res.headers['cache-control']), /no-store/, `${method} ${url}`);
  }
});

// ------------------------------------------------------------------------------------------------
// Uc-ozel davranislar
// ------------------------------------------------------------------------------------------------
test('mqtt-credentials: misafir bitisi (valid_until) servise gider; owner icin sinir yok; servis oturumu bitisi', async () => {
  const guest = await send('post', `/api/v1/homes/${HOME_A}/mqtt-credentials`, ACTORS.guest.header, {});
  assert.strictEqual(guest.status, 200);
  let call = mqttCredentials.calls.at(-1).args;
  assert.strictEqual(call.homeId, HOME_A);
  assert.strictEqual(call.userId, 'u-guest');
  assert.strictEqual(new Date(call.validUntil).toISOString(), FUTURE);

  const owner = await send('post', `/api/v1/homes/${HOME_A}/mqtt-credentials`, ACTORS.owner.header, {});
  assert.strictEqual(owner.status, 200);
  call = mqttCredentials.calls.at(-1).args;
  assert.strictEqual(call.validUntil, null);
  assert.strictEqual(call.userId, 'u-owner');

  const session = await send('post', `/api/v1/homes/${HOME_A}/mqtt-credentials`, JSON.stringify({
    id: null, role: 'service_session', is_service_session: true, home_id: HOME_A, sid: 's', session_expires_at: FUTURE,
  }), {});
  assert.strictEqual(session.status, 200);
  call = mqttCredentials.calls.at(-1).args;
  assert.strictEqual(call.userId, null);
  assert.strictEqual(new Date(call.validUntil).toISOString(), FUTURE);
});

test('mqtt-credentials: yanit yalnizca sozlesme alanlarini icerir (ic alanlar sizmaz)', async () => {
  const res = await send('post', `/api/v1/homes/${HOME_A}/mqtt-credentials`, ACTORS.owner.header, {});
  assert.deepStrictEqual(
    Object.keys(res.body.data).sort(),
    ['client_id', 'expires_at', 'expires_in', 'host', 'password', 'port', 'topic_id', 'username']
  );
  assert.ok(Number.isInteger(res.body.data.expires_in) && res.body.data.expires_in >= 0, 'kullanim-10: tam sayi sn');
  assert.ok(!JSON.stringify(res.body).includes('gizli-ic-alan'));
});

test('commissioning: yalniz device_uuid/checks/notes servise gider; istemci tests_passed YOK SAYILIR', async () => {
  const res = await send('post', `/api/v1/homes/${HOME_A}/commissioning`, ACTORS.staff.header, {
    device_uuid: UUID, checks: { relays: { ok: true } }, notes: 'tamam', tests_passed: true, testsPassed: true, commissioned: true,
  });
  assert.strictEqual(res.status, 200);
  const args = deviceService.calls.find((c) => c.name === 'commissionHome').args;
  assert.deepStrictEqual(Object.keys(args).sort(), ['actor', 'checks', 'deviceUuid', 'homeId', 'notes']);
  assert.strictEqual(args.homeId, HOME_A);
});

test('replace-board: alanlar servise iletilir; home_id dogrulanmis uyelikten', async () => {
  const res = await send('post', '/api/v1/devices/replace-board', ACTORS.staff.header, {
    home_id: HOME_A, old_device_uuid: UUID, new_device_uuid: 'AHBU-S3-0002', setup_pin: '135790', reason: 'Yandi',
  });
  assert.strictEqual(res.status, 200);
  const args = deviceService.calls.find((c) => c.name === 'replaceBoard').args;
  assert.deepStrictEqual(
    { h: args.homeId, o: args.oldDeviceUuid, n: args.newDeviceUuid, p: args.setupPin, r: args.reason },
    { h: HOME_A, o: UUID, n: 'AHBU-S3-0002', p: '135790', r: 'Yandi' }
  );
});

test('endpoint PUT: govde patch olarak aynen servise gider; yetkisiz rolde servis cagrilmaz', async () => {
  const res = await send('put', `/api/v1/homes/${HOME_A}/endpoints/e-9`, ACTORS.owner.header, { name: 'Yeni ad', shutter_duration_sec: 30 });
  assert.strictEqual(res.status, 200);
  const args = endpointService.calls[0].args;
  assert.strictEqual(args.endpointId, 'e-9');
  assert.strictEqual(args.homeId, HOME_A);
  assert.deepStrictEqual(args.patch, { name: 'Yeni ad', shutter_duration_sec: 30 });
  endpointService.calls.length = 0;
  const denied = await send('put', `/api/v1/homes/${HOME_A}/endpoints/e-9`, ACTORS.resident.header, { name: 'x' });
  assert.strictEqual(denied.status, 403);
  assert.strictEqual(endpointService.calls.length, 0);
});

test('route kaynaginda eski guvensiz kaliplar yok: govdeden home_id, ham hata mesaji, ilk-ev yedegi', () => {
  const fs = require('fs');
  for (const f of ['device_routes', 'home_device_routes', 'endpoint_routes', 'mqtt_routes']) {
    const src = fs.readFileSync(require.resolve(`../../src/routes/${f}`), 'utf8');
    assert.ok(!/req\.body\.home_id\s*\|\|/.test(src), `${f}: home_id govdeden dogrudan okunmamali`);
    assert.ok(!/req\.params\.home_id\s*\|\|/.test(src), `${f}: home_id parametreden dogrudan okunmamali`);
    assert.ok(!/err\.message,\s*err\.statusCode/.test(src), `${f}: ham hata mesaji yanita basilmamali`);
    assert.ok(!/errorResponse\(res, err\.message/.test(src), `${f}: ham hata mesaji yanita basilmamali`);
    assert.ok(/authenticateToken/.test(src), `${f}: kimlik dogrulama yok`);
  }
});

test('mqtt-credentials: bitis tarihi OLMAYAN misafir (ara katman atlasa bile) fail-closed 403 GUEST_EXPIRED; kimlik uretilmez', async () => {
  const express = require('express');
  const recorder = {
    calls: [],
    issueUserCredential: async (args) => {
      recorder.calls.push(args);
      return {};
    },
  };
  const router = require('../../src/routes/mqtt_routes').createRouter({
    auth: {
      authenticateToken: (req, _res, next) => { req.user = { id: 'u-guest-x', role: 'user' }; next(); },
      requireHomeAccess: () => (req, _res, next) => { req.homeAccess = { home_id: HOME_A, role: 'guest', valid_until: null }; next(); },
    },
    rateLimit: () => (_req, _res, next) => next(),
    mqttCredentials: recorder,
  });
  const standalone = express();
  standalone.use(express.json());
  standalone.use('/api/v1/homes', router);

  const res = await request(standalone).post(`/api/v1/homes/${HOME_A}/mqtt-credentials`).send({});
  assert.strictEqual(res.status, 403);
  assert.strictEqual(res.body.code, 'GUEST_EXPIRED');
  assert.strictEqual(recorder.calls.length, 0, 'sure belirsizken kimlik uretilmemeli');
});
