'use strict';

// Entegrasyon (uctan uca): A paketinin GERCEK auth_middleware + JWT + pin.js + mailer + rate_limit'i ile
// B paketinin route/servis/MQTT-kimlik katmani. Yalnizca PostgreSQL (FakeDb) ve broker (FakeBridge) sahte.
// A'nin modulleri yuklenemezse testler ATLANIR (paralel gelistirme). Ortak ortam: _integration.js

const test = require('node:test');
const assert = require('node:assert');
const crypto = require('crypto');

const { createIntegration } = require('./_integration');

const env = createIntegration();
const { world, state, bridge, invites, helpers: h, mw, jwtConfig, mailer, pin, tokenOf, sessionToken, api, skipIfUnavailable } = env;
const secretBox = require('../../src/utils/secret_box');

// --- veri ---------------------------------------------------------------------------------------------
const mkUser = (email, role = 'user') => h.addUser({ email, role });
const owner = mkUser('sahip@example.test');
const resident = mkUser('sakin@example.test');
const guestOk = mkUser('misafir@example.test');
const guestExpired = mkUser('eski.misafir@example.test');
const staff = mkUser('servis@example.test', 'service_user');
const staff2 = mkUser('baska.servis@example.test', 'service_user');
const root = mkUser('root@example.test', 'super_user');
const customer = mkUser('musteri@example.test');
const customer2 = mkUser('musteri2@example.test');
const outsider = mkUser('yabanci@example.test');
const inactive = mkUser('pasif@example.test');
inactive.is_active = false;
for (const u of state.users) u.token_version = 1;

const home1 = h.addHome({ name: 'Daire 1', owner });
const home2 = h.addHome({ name: 'Daire 2' });
h.addMember(home1, resident, 'resident');
h.addMember(home1, guestOk, 'guest', { valid_until: new Date(Date.now() + 3600 * 1000) });
h.addMember(home1, guestExpired, 'guest', { valid_until: new Date(Date.now() - 3600 * 1000) });
h.addMember(home1, staff, 'service_user');

const keyEnc = secretBox.encrypt('YerelAnahtar12345');
const dev1 = h.addDevice({ home: home1, uuid: 'AHBU-S3-0001', mac: 'E8:F6:0A:00:00:01', claimedBy: owner, online: true, local_key_enc: keyEnc });
const eps1 = h.addEndpoints(home1, dev1, 8);
const inv1 = h.addInventory({ uuid: 'AHBU-S3-0001', pin: '999999', status: 'CLAIMED', mac: dev1.mac_address });
inv1.claimed_home_id = home1.id;
const dev2 = h.addDevice({ home: home2, uuid: 'AHBU-S3-0002', mac: 'E8:F6:0A:00:00:02', online: true });
h.addEndpoints(home2, dev2, 8);

// stoktaki cihazlar: PIN ozeti A'NIN GERCEK hashPin'iyle
const stock = (uuid, plainPin, mac) => {
  const row = h.addInventory({ uuid, pin: '000000', mac });
  if (pin) row.pin_hash = pin.hashPin(plainPin);
  return row;
};
const stockInv = stock('AHBU-S3-0050', '246802', 'E8:F6:0A:00:00:50');
const stockInv2 = stock('AHBU-S3-0051', '135791', 'E8:F6:0A:00:00:51');
const stockInv3 = stock('AHBU-S3-0052', '112233', 'E8:F6:0A:00:00:52');
const resetInv = h.addInventory({ uuid: 'AHBU-S3-0060', pin: '000000', status: 'CLAIMED', mac: 'E8:F6:0A:00:00:60' });
const resetHome = h.addHome({ name: 'Sifirlanacak', owner: outsider });
h.addMember(resetHome, staff, 'service_user');
const resetDev = h.addDevice({ home: resetHome, uuid: 'AHBU-S3-0060', mac: 'E8:F6:0A:00:00:60', claimedBy: outsider, online: false, local_key_enc: keyEnc });
h.addEndpoints(resetHome, resetDev, 8);
resetInv.claimed_home_id = resetHome.id;

const checks = (ok = true) => ({
  relays: { ok, detail: 'ok' }, buttons: { ok, detail: 'ok' }, shutters: { ok, detail: 'ok' }, network: { ok, detail: 'ok' }, cloud: { ok, detail: 'ok' },
});

// ------------------------------------------------------------------------------------------------
test('A middleware: token yok / bozuk / suresi dolmus / pasif hesap / surum uyusmazligi -> 401', async (t) => {
  if (skipIfUnavailable(t)) return;
  const url = `/api/v1/homes/${home1.id}/devices`;
  assert.strictEqual((await api('get', url, null)).status, 401);
  assert.strictEqual((await api('get', url, 'bozuk.token.degeri')).status, 401);

  const expired = require('jsonwebtoken').sign({ sub: owner.id, role: 'user', tv: 1 }, process.env.JWT_SECRET, { algorithm: 'HS256', expiresIn: -60, issuer: 'test-issuer' });
  const e = await api('get', url, expired);
  assert.strictEqual(e.status, 401);
  assert.strictEqual(e.body.code, 'TOKEN_EXPIRED');

  assert.strictEqual((await api('get', url, tokenOf(inactive))).status, 401);
  const stale = jwtConfig.signAccessToken({ id: owner.id, role: 'user', token_version: 99 });
  assert.strictEqual((await api('get', url, stale)).status, 401);
});

test('owner: cihaz listesi, endpoint listesi ve komut calisir; baska evde 403', async (t) => {
  if (skipIfUnavailable(t)) return;
  const token = tokenOf(owner);
  const list = await api('get', `/api/v1/homes/${home1.id}/devices`, token);
  assert.strictEqual(list.status, 200, JSON.stringify(list.body));
  assert.strictEqual(list.body.data.length, 1);
  assert.strictEqual(list.body.data[0].device_uuid, 'AHBU-S3-0001');
  assert.strictEqual(list.body.data[0].online, true);
  assert.ok(!('local_key_enc' in list.body.data[0]));

  const eps = await api('get', `/api/v1/homes/${home1.id}/endpoints`, token);
  assert.strictEqual(eps.status, 200);
  assert.strictEqual(eps.body.data.length, 8);

  bridge.commands.length = 0;
  const cmd = await api('post', `/api/v1/devices/${dev1.id}/command`, token, { home_id: home1.id, command: { relay: 5, state: true } });
  assert.strictEqual(cmd.status, 200, JSON.stringify(cmd.body));
  assert.strictEqual(cmd.body.data.delivered, true);
  assert.strictEqual(cmd.body.data.device_online, true);
  assert.deepStrictEqual(bridge.commands[0].topicId, home1.mqtt_username);
  assert.strictEqual(bridge.commands[0].obj.relay, 5);

  const other = await api('get', `/api/v1/homes/${home2.id}/devices`, token);
  assert.strictEqual(other.status, 403);
  const idor = await api('post', `/api/v1/devices/${dev2.id}/command`, token, { home_id: home1.id, command: { relay: 5, state: true } });
  assert.strictEqual(idor.status, 404, 'baska evin cihazi bu ev uzerinden: 404');
  const idor2 = await api('post', `/api/v1/devices/${dev2.id}/command`, token, { home_id: home2.id, command: { relay: 5, state: true } });
  assert.strictEqual(idor2.status, 403, 'baska evin kimligiyle: uyelik yok');
});

test('komut hatti: cevrimdisi 409, broker 502, sema 400 - HTTP durum ve kodlariyla', async (t) => {
  if (skipIfUnavailable(t)) return;
  const token = tokenOf(owner);
  const post = (command) => api('post', `/api/v1/devices/${dev1.id}/command`, token, { home_id: home1.id, command });

  const bad = await post({ relay: 5, state: 'ON' });
  assert.strictEqual(bad.status, 400);
  assert.strictEqual(bad.body.code, 'VALIDATION');

  dev1.is_online = false;
  const off = await post({ relay: 5, state: true });
  assert.strictEqual(off.status, 409);
  assert.strictEqual(off.body.code, 'DEVICE_OFFLINE');
  dev1.is_online = true;

  bridge.failPublish = true;
  const down = await post({ relay: 5, state: true });
  assert.strictEqual(down.status, 502);
  assert.strictEqual(down.body.code, 'BROKER_UNAVAILABLE');
  bridge.failPublish = false;
});

test('misafir: temel komut calisir, toplu komut/cocuk kilidi 403; suresi dolmus misafir GUEST_EXPIRED', async (t) => {
  if (skipIfUnavailable(t)) return;
  const token = tokenOf(guestOk);
  const post = (command) => api('post', `/api/v1/devices/${dev1.id}/command`, token, { home_id: home1.id, command });
  assert.strictEqual((await post({ relay: 5, state: true })).status, 200);
  assert.strictEqual((await post({ cmd: 'all_off' })).status, 403);
  assert.strictEqual((await post({ cmd: 'set_child_lock', enabled: true })).status, 403);
  assert.strictEqual((await api('post', '/api/v1/devices/child-lock', token, { home_id: home1.id, enabled: true })).status, 403);
  assert.strictEqual((await api('post', '/api/v1/devices/peace-notification/close-all', token, { home_id: home1.id })).status, 403);

  const exp = await api('get', `/api/v1/homes/${home1.id}/devices`, tokenOf(guestExpired));
  assert.strictEqual(exp.status, 403);
  assert.strictEqual(exp.body.code, 'GUEST_EXPIRED');
});

test('aile sakini: kalibrasyon/devreye alma 403, yerel anahtar 200; owner kalibrasyon yapar', async (t) => {
  if (skipIfUnavailable(t)) return;
  const res = tokenOf(resident);
  const ep = eps1.find((e) => e.channel_index === 1);
  assert.strictEqual((await api('put', `/api/v1/homes/${home1.id}/endpoints/${ep.id}`, res, { shutter_duration_sec: 30 })).status, 403);
  assert.strictEqual((await api('post', `/api/v1/homes/${home1.id}/commissioning`, res, { device_uuid: 'AHBU-S3-0001', checks: checks() })).status, 403);
  const key = await api('get', `/api/v1/homes/${home1.id}/devices/AHBU-S3-0001/local-key`, res);
  assert.strictEqual(key.status, 200);
  assert.deepStrictEqual(key.body.data, { local_key: 'YerelAnahtar12345' });
  assert.match(String(key.headers['cache-control']), /no-store/);

  const own = await api('put', `/api/v1/homes/${home1.id}/endpoints/${ep.id}`, tokenOf(owner), { shutter_duration_sec: 31, name: 'Salon Panjuru' });
  assert.strictEqual(own.status, 200, JSON.stringify(own.body));
  assert.strictEqual(ep.shutter_duration_sec, 31);
  assert.strictEqual(ep.name, 'Salon Panjuru');
  assert.strictEqual(bridge.commands.at(-1).obj.cmd, 'set_runtime');
});

test('staff (uyeligi olan) devreye alir; uyeligi olmayan staff 403; super devreye alir ama yerel anahtari GOREMEZ', async (t) => {
  if (skipIfUnavailable(t)) return;
  const url = `/api/v1/homes/${home1.id}/commissioning`;
  const ok = await api('post', url, tokenOf(staff), { device_uuid: 'AHBU-S3-0001', checks: checks(true), notes: 'tamam' });
  assert.strictEqual(ok.status, 200, JSON.stringify(ok.body));
  assert.strictEqual(ok.body.data.tests_passed, true);
  assert.strictEqual(dev1.is_commissioned, true);

  assert.strictEqual((await api('post', url, tokenOf(staff2), { device_uuid: 'AHBU-S3-0001', checks: checks() })).status, 403);

  const failing = await api('post', url, tokenOf(root), { device_uuid: 'AHBU-S3-0001', checks: checks(false), tests_passed: true });
  assert.strictEqual(failing.status, 200);
  assert.strictEqual(failing.body.data.tests_passed, false, 'istemci tests_passed degeri yok sayilmali');
  assert.strictEqual(dev1.is_commissioned, false);
  assert.strictEqual((await api('get', `/api/v1/homes/${home1.id}/devices/AHBU-S3-0001/local-key`, tokenOf(root))).status, 403);
});

test('servis (PIN) oturumu: yalniz kendi evinde calisir; claim/sifirlama/baska ev 403; kullanici satiri yok', async (t) => {
  if (skipIfUnavailable(t)) return;
  const token = sessionToken(home1.id);
  const commission = await api('post', `/api/v1/homes/${home1.id}/commissioning`, token, { device_uuid: 'AHBU-S3-0001', checks: checks(true) });
  assert.strictEqual(commission.status, 200, JSON.stringify(commission.body));
  const log = state.commissioning_logs.at(-1);
  assert.strictEqual(log.technician_id, null);
  assert.strictEqual(log.technician_label, 'Veli Usta');
  assert.ok(log.service_session_id);

  assert.strictEqual((await api('get', `/api/v1/homes/${home1.id}/devices/AHBU-S3-0001/local-key`, token)).status, 200);
  assert.strictEqual((await api('get', `/api/v1/homes/${home2.id}/devices`, token)).status, 403);
  assert.strictEqual((await api('post', '/api/v1/devices/claim', token, { device_uuid: 'AHBU-S3-0050', setup_pin: '246802' })).status, 403);
  assert.strictEqual((await api('post', '/api/v1/devices/emergency-reset', token, { device_uuid: 'AHBU-S3-0001', confirm_uid: 'AHBU-S3-0001', reason: 'x'.repeat(20) })).status, 403);
  assert.strictEqual((await api('post', '/api/v1/devices/claim/request-otp', token, { device_uuid: 'AHBU-S3-0050', target_owner: 'a@b.co' })).status, 403);
  assert.strictEqual((await api('post', `/api/v1/homes/${home1.id}/mqtt-credentials`, token, {})).status, 200);
});

test('MQTT kimligi: owner 12 saat, misafir kendi bitisine kadar, suresi dolmus misafir 403; yanit sozlesme alanlari', async (t) => {
  if (skipIfUnavailable(t)) return;
  const url = `/api/v1/homes/${home1.id}/mqtt-credentials`;
  const o = await api('post', url, tokenOf(owner), {});
  assert.strictEqual(o.status, 200, JSON.stringify(o.body));
  assert.deepStrictEqual(Object.keys(o.body.data).sort(), ['client_id', 'expires_at', 'host', 'password', 'port', 'topic_id', 'username']);
  assert.match(o.body.data.username, new RegExp(`^a_${home1.mqtt_username}_`));
  assert.strictEqual(o.body.data.topic_id, home1.mqtt_username);
  const hours = (new Date(o.body.data.expires_at) - Date.now()) / 3600000;
  assert.ok(hours > 11.9 && hours <= 12, `sure ~12 saat: ${hours}`);

  const g = await api('post', url, tokenOf(guestOk), {});
  assert.strictEqual(g.status, 200);
  const guestMs = new Date(g.body.data.expires_at) - Date.now();
  assert.ok(guestMs > 0 && guestMs <= 3600 * 1000 + 1000, 'misafir kimligi erisim bitisini asmamali');
  const cred = state.mqtt_credentials.find((c) => c.username === g.body.data.username);
  assert.ok(cred.password_hash.startsWith('$2'), 'bcrypt ozeti');
  assert.ok(!JSON.stringify(state).includes(g.body.data.password));
  // yalniz abonelik
  const acl = state.mqtt_acl.filter((a) => a.username === g.body.data.username);
  assert.ok(acl.length === 2 && acl.every((a) => a.action === 'subscribe'));

  assert.strictEqual((await api('post', url, tokenOf(guestExpired), {})).status, 403);
  assert.strictEqual((await api('post', url, tokenOf(outsider), {})).status, 403);
});

test('sahiplenme (gercek PIN ozeti): yanlis PIN 403 + kalan hak; dogru PIN 200 + tek seferlik kimlik; ikinci sahiplenme 409', async (t) => {
  if (skipIfUnavailable(t)) return;
  const url = '/api/v1/devices/claim';
  const wrong = await api('post', url, tokenOf(customer), { device_uuid: 'AHBU-S3-0050', setup_pin: '000000' });
  assert.strictEqual(wrong.status, 403);
  assert.strictEqual(wrong.body.code, 'FORBIDDEN');
  assert.strictEqual(wrong.body.remaining_attempts, 4);
  assert.strictEqual(stockInv.failed_attempts, 1);

  const ok = await api('post', url, tokenOf(customer), { device_uuid: 'ahbu-s3-0050', setup_pin: '246802', home_name: 'Evim 1', home_id: home2.id });
  assert.strictEqual(ok.status, 200, JSON.stringify(ok.body));
  assert.match(String(ok.headers['cache-control']), /no-store/);
  const data = ok.body.data;
  assert.notStrictEqual(data.home_id, home2.id, 'govdedeki home_id yok sayilmali');
  assert.strictEqual(data.home_name, 'Evim 1');
  assert.strictEqual(data.device_uuid, 'AHBU-S3-0050');
  assert.strictEqual(data.device_credential.password.length, 24);
  assert.match(data.device_credential.username, /^d_h_[0-9a-f]{16}$/);
  assert.strictEqual(stockInv.status, 'CLAIMED');
  assert.strictEqual(stockInv.pin_hash, 'CLAIMED_BURNED_PIN');
  assert.ok(!JSON.stringify(state).includes('246802'));

  const again = await api('post', url, tokenOf(customer2), { device_uuid: 'AHBU-S3-0050', setup_pin: '246802' });
  assert.strictEqual(again.status, 409);
  assert.strictEqual(again.body.code, 'CONFLICT');
});

test('5 yanlis PIN -> 423 PIN_LOCKED + Retry-After (HTTP); kilitliyken dogru PIN de 423', async (t) => {
  if (skipIfUnavailable(t)) return;
  const token = tokenOf(customer2);
  const url = '/api/v1/devices/claim';
  const body = (p) => ({ device_uuid: 'AHBU-S3-0051', setup_pin: p });
  for (let i = 0; i < 4; i++) assert.strictEqual((await api('post', url, token, body('000000'))).status, 403);
  const locked = await api('post', url, token, body('000000'));
  assert.strictEqual(locked.status, 423);
  assert.strictEqual(locked.body.code, 'PIN_LOCKED');
  assert.ok(locked.body.retry_after > 0);
  assert.ok(Number(locked.headers['retry-after']) > 0);
  const still = await api('post', url, token, body('135791'));
  assert.strictEqual(still.status, 423);
  assert.strictEqual(stockInv2.status, 'IN_STOCK');
});

test('servis personeli: OTP iste -> musteri e-postasina gider (gercek mailer) -> claim; hesap pending_invite + davet; teknisyen SURELI uye', async (t) => {
  if (skipIfUnavailable(t)) return;
  const sent = [];
  mailer.setTransportFactory(() => ({ sendMail: async (msg) => { sent.push(msg); } }));
  try {
    const staffToken = tokenOf(staff);
    const target = 'yeni.musteri@example.test';

    const otpRes = await api('post', '/api/v1/devices/claim/request-otp', staffToken, { device_uuid: 'AHBU-S3-0052', target_owner: target });
    assert.strictEqual(otpRes.status, 200, JSON.stringify(otpRes.body));
    assert.ok(!('debug_code' in otpRes.body.data));
    assert.strictEqual(sent.length, 1);
    assert.strictEqual(sent[0].to, target);
    const code = /(\d{6})/.exec(sent[0].text)[1];
    assert.ok(!JSON.stringify(otpRes.body).includes(code), 'kod yanitta olmamali');

    // OTP'siz / yanlis OTP
    const noOtp = await api('post', '/api/v1/devices/claim', staffToken, { device_uuid: 'AHBU-S3-0052', setup_pin: '112233', target_owner: target });
    assert.strictEqual(noOtp.status, 400);
    const wrongOtp = await api('post', '/api/v1/devices/claim', staffToken, { device_uuid: 'AHBU-S3-0052', setup_pin: '112233', target_owner: target, otp_code: code === '000000' ? '111111' : '000000' });
    assert.strictEqual(wrongOtp.status, 400);
    assert.strictEqual(wrongOtp.body.remaining_attempts, 4);
    // servis personeli target_owner'siz sahiplenemez; normal kullanici target_owner veremez
    assert.strictEqual((await api('post', '/api/v1/devices/claim', staffToken, { device_uuid: 'AHBU-S3-0052', setup_pin: '112233' })).status, 400);
    assert.strictEqual((await api('post', '/api/v1/devices/claim', tokenOf(customer), { device_uuid: 'AHBU-S3-0052', setup_pin: '112233', target_owner: target, otp_code: code })).status, 403);

    const ok = await api('post', '/api/v1/devices/claim', staffToken, { device_uuid: 'AHBU-S3-0052', setup_pin: '112233', target_owner: target, otp_code: code });
    assert.strictEqual(ok.status, 200, JSON.stringify(ok.body));
    assert.strictEqual(ok.body.data.customer_account.status, 'pending_invite');
    assert.strictEqual(ok.body.data.customer_account.invite_sent, true);
    assert.deepStrictEqual(invites, [target]);
    const created = state.users.find((u) => u.email === target);
    assert.strictEqual(created.account_status, 'pending_invite');
    assert.match(created.password_hash, /^\$2[aby]\$12\$/);
    assert.strictEqual(stockInv3.claimed_by_user_id, created.id, 'sahip musteri (teknisyen degil)');
    assert.ok(ok.body.data.technician_access_expires_at);

    // teknisyen artik bu evin servis uyesi: yerel anahtari alabilir; baska servis personeli alamaz
    const homeId = ok.body.data.home_id;
    assert.strictEqual((await api('get', `/api/v1/homes/${homeId}/devices/AHBU-S3-0052/local-key`, staffToken)).status, 200);
    assert.strictEqual((await api('get', `/api/v1/homes/${homeId}/devices/AHBU-S3-0052/local-key`, tokenOf(staff2))).status, 403);
    // OTP tek kullanimlik
    assert.strictEqual(state.device_claim_otps.length, 0);
  } finally {
    mailer.setTransportFactory(null);
  }
});

test('OTP gonderilemezse (SMTP yok) 502 MAIL_UNAVAILABLE; kod sizmaz', async (t) => {
  if (skipIfUnavailable(t)) return;
  mailer.setTransportFactory(null);
  delete process.env.SMTP_HOST;
  const res = await api('post', '/api/v1/devices/claim/request-otp', tokenOf(staff), { device_uuid: 'AHBU-S3-0051', target_owner: 'yok@example.test' });
  assert.ok([502, 429, 409].includes(res.status), String(res.status));
  if (res.status === 502) assert.strictEqual(res.body.code, 'MAIL_UNAVAILABLE');
  assert.ok(!/\d{6}/.test(JSON.stringify(res.body)));
});

test('acil sifirlama (HTTP): owner 403, uyeligi olmayan staff 403, uyeligi olan staff 200 + tek seferlik rastgele PIN', async (t) => {
  if (skipIfUnavailable(t)) return;
  const url = '/api/v1/devices/emergency-reset';
  const body = { device_uuid: 'AHBU-S3-0060', confirm_uid: 'AHBU-S3-0060', reason: 'Kiraci ulasilamiyor, daire teslim alindi' };
  assert.strictEqual((await api('post', url, tokenOf(outsider), body)).status, 403, 'ev sahibi sifirlayamaz');
  assert.strictEqual((await api('post', url, tokenOf(staff2), body)).status, 403, 'uyeligi olmayan staff');
  assert.strictEqual((await api('post', url, tokenOf(staff), { ...body, confirm_uid: 'AHBU-S3-0001' })).status, 400, 'yanlis teyit');
  assert.strictEqual((await api('post', url, tokenOf(staff), { ...body, reason: 'kisa' })).status, 400);

  const ok = await api('post', url, tokenOf(staff), body);
  assert.strictEqual(ok.status, 200, JSON.stringify(ok.body));
  assert.match(String(ok.headers['cache-control']), /no-store/);
  assert.strictEqual(ok.body.data.action, 'UNCLAIMED');
  assert.match(ok.body.data.setup_pin, /^\d{6}$/);
  assert.notStrictEqual(ok.body.data.setup_pin, '123456');
  assert.strictEqual(resetInv.status, 'IN_STOCK');
  assert.ok(pin.verifyPin(ok.body.data.setup_pin, resetInv.pin_hash), 'yeni PIN gercek hashPin ile saklandi');
  assert.strictEqual(state.endpoints.filter((e) => e.home_id === resetHome.id).length, 0);
  assert.strictEqual(state.home_users.filter((m) => m.home_id === resetHome.id).length, 0);
  assert.ok(!JSON.stringify(state).includes(ok.body.data.setup_pin));
  assert.ok(bridge.cleared.includes(resetHome.mqtt_username), 'retained temizlendi');
});

test('hiz siniri (A\'nin gercek sinirlayicisi): claim 11. istek 429 + Retry-After', async (t) => {
  if (skipIfUnavailable(t)) return;
  const token = tokenOf(outsider);
  let last = null;
  for (let i = 1; i <= 11; i++) {
    last = await api('post', '/api/v1/devices/claim', token, { device_uuid: 'AHBU-S3-0999', setup_pin: '123456' });
    if (i <= 10) assert.strictEqual(last.status, 404, `istek ${i}`); // envanterde yok
  }
  assert.strictEqual(last.status, 429);
  assert.strictEqual(last.body.code, 'RATE_LIMITED');
  assert.ok(Number(last.headers['retry-after']) > 0);
});

test('guvenlik basliklari / sir sizintisi: hata yanitlari ham SQL icermez', async (t) => {
  if (skipIfUnavailable(t)) return;
  const orig = console.error;
  console.error = () => {};
  try {
    const res = await api('get', `/api/v1/homes/${home1.id}/endpoints`, tokenOf(owner));
    assert.strictEqual(res.status, 200);
    // DB hatasi enjekte et
    const original = world.db._exec.bind(world.db);
    world.db._exec = (tx, text, params) => {
      if (String(text).replace(/\s+/g, ' ').includes('FROM endpoints e LEFT JOIN')) return Promise.reject(Object.assign(new Error('SELECT secret FROM x -- baglanti dizesi'), { code: '42P01' }));
      return original(tx, text, params);
    };
    const err = await api('get', `/api/v1/homes/${home1.id}/endpoints`, tokenOf(owner));
    world.db._exec = original;
    assert.strictEqual(err.status, 500);
    assert.ok(!/SELECT|secret|baglanti/.test(JSON.stringify(err.body)));
  } finally {
    console.error = orig;
  }
});

test.after(() => env.teardown());
