'use strict';

// A6: servis PIN'i ve servis oturumu (CONTRACTS §1.3)
//  - PIN yalnizca owner tarafindan; ozetli; tek kullanimlik; 2 saat; yeni PIN eskisini iptal eder
//  - giris kullanici satiri OLUSTURMAZ, global rol VERMEZ, refresh token YOK
//  - token yalnizca kendi evinin uclarina girer
//  - IP basina 10 deneme / 15 dk -> 429
//  - revokeHomeServiceAccess PIN ve oturumlari iptal eder

const test = require('node:test');
const assert = require('node:assert');
const express = require('express');
const request = require('supertest');
const jwt = require('jsonwebtoken');
const { setTestEnv, installFakeDb, makeAccessToken } = require('./_helpers');
const { createHomeStore } = require('./_home_store');

setTestEnv();
const fakeDb = installFakeDb();
let clock = Date.now();
const store = createHomeStore({ now: () => clock }).install(fakeDb);

const auth = require('../../src/middlewares/auth_middleware');
const authRoutes = require('../../src/routes/auth_routes');
const serviceRoutes = require('../../src/routes/service_routes');
const serviceTokenService = require('../../src/services/service_token_service');
const authService = require('../../src/services/auth_service');
const { errorHandler, asyncHandler } = require('../../src/middlewares/error_handler');

auth.configureAuthMiddleware({ cacheTtlMs: 0, now: () => clock });

// uyelik-6 / uyelik-12: servis oturumu MQTT kimlikleri (user_id bos) GERCEK MqttCredentialService ile silinir;
// baglanti atma (EMQX REST) sahte fetch ile kaydedilir.
const { MqttCredentialService } = require('../../src/services/mqtt_credential_service');
const kicked = [];
const mqttSvc = new MqttCredentialService({
  db: fakeDb,
  env: { EMQX_API_URL: 'http://emqx.test.invalid', EMQX_API_KEY: 'k', EMQX_API_SECRET: 's' },
  logger: { warn() {}, error() {}, log() {} },
  fetch: async (url, init = {}) => {
    const u = new URL(url);
    if ((init.method || 'GET') === 'GET') {
      return { ok: true, status: 200, json: async () => ({ data: [{ clientid: u.searchParams.get('username') }] }) };
    }
    kicked.push(decodeURIComponent(u.pathname.split('/').pop()));
    return { ok: true, status: 204, json: async () => ({}) };
  },
});
if (typeof serviceTokenService.setMqttCredentialService === 'function') serviceTokenService.setMqttCredentialService(mqttSvc);

const HOME = store.addHome({ name: 'Servis Evi' });
const OTHER = store.addHome({ name: 'Komsu Evi' });
const owner = store.addUser({ full_name: 'Ev Sahibi' });
const resident = store.addUser();
const guest = store.addUser();
const staff = store.addUser({ role: 'service_user' });
const superUser = store.addUser({ role: 'super_user' });
const stranger = store.addUser();
const otherOwner = store.addUser();
store.addMember(HOME, owner, 'owner');
store.addMember(HOME, resident, 'resident');
store.addMember(HOME, guest, 'guest', { valid_from: new Date(clock - 3600e3), valid_until: new Date(clock + 3600e3) });
store.addMember(HOME, staff, 'service_user');
store.addMember(OTHER, otherOwner, 'owner');

const app = express();
app.use(express.json());
app.use('/api/v1/auth', authRoutes);
app.get('/api/v1/homes', auth.authenticateToken, asyncHandler(async (req, res) => {
  const p = await authService.getProfile(req.user);
  res.json({ success: true, data: p.homes });
}));
app.post('/api/v1/homes/:homeId/commission-test', auth.authenticateToken, auth.requireHomeAccess(auth.HOME_ROLE_SETS.COMMISSION), (req, res) => res.json({ success: true, access: req.homeAccess }));
app.post('/api/v1/devices/claim', auth.authenticateToken, auth.rejectServiceSession, (req, res) => res.json({ success: true }));
app.use('/api/v1/homes/:home_id', serviceRoutes);
app.use(errorHandler);

const tok = (u) => makeAccessToken(u);
async function newPin(homeId = HOME.id, user = owner) {
  const res = await request(app).post(`/api/v1/homes/${homeId}/service-token`).set('Authorization', `Bearer ${tok(user)}`);
  assert.strictEqual(res.status, 201, JSON.stringify(res.body));
  return res.body.data.service_pin;
}
const login = (pin, name = 'Ali Usta') => request(app).post('/api/v1/auth/service-login').send({ service_pin: pin, technician_name: name });

test.beforeEach(() => {
  authRoutes.limiters.serviceLogin.reset();
  serviceRoutes.pinLimiter.reset();
  if (authRoutes.serviceLoginFailures) {
    authRoutes.serviceLoginFailures.net.reset();
    authRoutes.serviceLoginFailures.all.reset();
  }
});

// ev_uyelik-1: dagitik kaba kuvvete karsi YALNIZ hatali denemeleri sayan ag (/48) ve genel butce.
// Farkli istemci adresleri icin ayri uygulama: trust proxy + X-Forwarded-For (yalniz bu test uygulamasinda).
const proxApp = express();
proxApp.set('trust proxy', true);
proxApp.use(express.json());
proxApp.use('/api/v1/auth', authRoutes);
proxApp.use(errorHandler);
const loginFrom = (ip, pin) =>
  request(proxApp).post('/api/v1/auth/service-login').set('X-Forwarded-For', ip).send({ service_pin: pin, technician_name: 'Usta' });
const wrongPinFor = (pin) => String((Number(pin) + 1) % 1000000).padStart(6, '0');

test('ev_uyelik-1: genel butce (100 / 15 dk) dolunca YALNIZ bu pencerede >= 3 hatasi olan aglar engellenir; taze ag dogru PIN ile girer (DoS yok); yalniz 401 ler sayilir', async () => {
  assert.ok(authRoutes.serviceLoginFailures, 'router.serviceLoginFailures disa acik olmali');
  const pin = await newPin();
  const wrong = wrongPinFor(pin);
  // bicimi gecersiz PIN (400) butceyi harcamaz
  assert.strictEqual((await loginFrom('198.51.100.250', '12ab56')).status, 400);
  const warns = [];
  const origWarn = console.warn;
  console.warn = (...a) => warns.push(a.join(' '));
  try {
    for (let i = 0; i < 100; i++) {
      const r = await loginFrom(`10.${Math.floor(i / 200)}.${i % 200}.${(i % 7) + 1}`, wrong);
      assert.strictEqual(r.status, 401, `deneme ${i + 1}: ${r.status}`);
    }
    // genel butce doldu: bu pencerede 3 hatali denemesi olan ag ENGELLENIR (dogru PIN dahil; PIN tuketilmez)
    for (let i = 0; i < 3; i++) assert.strictEqual((await loginFrom('198.51.100.7', wrong)).status, 401, `saldirgan deneme ${i + 1}`);
    const blocked = await loginFrom('198.51.100.7', pin);
    assert.strictEqual(blocked.status, 429, JSON.stringify(blocked.body));
    assert.strictEqual(blocked.body.code, 'RATE_LIMITED');
    assert.match(blocked.body.message, /servis PIN/);
    assert.ok(Number(blocked.headers['retry-after']) > 0);
    assert.ok(
      store.tokens.some((t) => !t.used_at && !t.revoked_at && t.created_by === owner.id && t.home_id === HOME.id),
      'bloklanan istek PIN i TUKETMEDI'
    );
    // esigin altinda (bu pencerede 1 hatasi olan) ag denemeye devam eder
    assert.strictEqual((await loginFrom('10.0.0.1', wrong)).status, 401);
    // taze ag (bu pencerede hatasi yok) dogru PIN ile GIRER: genel butce tek basina gecici teknisyeni kilitlemez
    const fresh = await loginFrom('203.0.113.77', pin);
    assert.strictEqual(fresh.status, 200, JSON.stringify(fresh.body));
  } finally {
    console.warn = origWarn;
  }
  const budgetWarns = warns.filter((w) => w.includes('Servis PIN genel hata butcesi doldu'));
  assert.strictEqual(budgetWarns.length, 1, 'pencere basina BIR kez uyari');
  assert.ok(!budgetWarns[0].includes(wrong) && !budgetWarns[0].includes('10.0.'), 'uyari PIN/IP icermez');
});

test('ev_uyelik-1: ayni /48 in farkli /64 lerinden 21. hatali deneme 429; baska /48 etkilenmez', async () => {
  const pin = await newPin();
  const wrong = wrongPinFor(pin);
  for (let i = 0; i < 20; i++) {
    const r = await loginFrom(`2001:db8:77:${(i + 1).toString(16)}::1`, wrong);
    assert.strictEqual(r.status, 401, `deneme ${i + 1}`);
  }
  const blocked = await loginFrom('2001:db8:77:ff::9', wrong);
  assert.strictEqual(blocked.status, 429);
  assert.strictEqual(blocked.body.code, 'RATE_LIMITED');
  const other = await loginFrom('2001:db8:78:1::1', pin);
  assert.strictEqual(other.status, 200, 'baska /48 den dogru PIN gecer');
});

test('ev_uyelik-1: sinirin altinda dogru PIN 200; basari ag sayacini sifirlar, genel sayaci sifirlamaz', async () => {
  const { net, all } = authRoutes.serviceLoginFailures;
  const pin = await newPin();
  const wrong = wrongPinFor(pin);
  for (let i = 0; i < 5; i++) assert.strictEqual((await loginFrom('192.0.2.10', wrong)).status, 401);
  assert.strictEqual(net.peek('svc-pin-fail:192.0.2.10').count, 5);
  assert.strictEqual(all.peek('svc-pin-fail:all').count, 5);
  const ok = await loginFrom('192.0.2.10', pin);
  assert.strictEqual(ok.status, 200, JSON.stringify(ok.body));
  assert.strictEqual(net.peek('svc-pin-fail:192.0.2.10').count, 0, 'ag sayaci sifirlandi');
  assert.strictEqual(all.peek('svc-pin-fail:all').count, 5, 'genel sayac korunur');
});

test('PIN uretimi: kullanici basina saatte 10 -> 429', async () => {
  for (let i = 0; i < 10; i++) await newPin();
  const res = await request(app).post(`/api/v1/homes/${HOME.id}/service-token`).set('Authorization', `Bearer ${tok(owner)}`);
  assert.strictEqual(res.status, 429);
});


// hesap-uyelik-7: ara katman (requireHomeAccess) uyeligi okuduktan SONRA ama servis INSERT'inden ONCE sahiplik gider
// (es zamanli devir kabulu): ilk uyelik okumasindan sonra satir silinir.
function dropMembershipAfterMiddleware(home, user) {
  let fired = false;
  fakeDb.on(/FROM home_users\s+WHERE home_id = \$1 AND user_id = \$2/, async (p, t) => {
    const out = await store.handle(p, t);
    if (!fired && /installer_expires_at/.test(t) && p[0] === home.id && p[1] === user.id) {
      fired = true;
      store.members = store.members.filter((m) => !(m.home_id === home.id && m.user_id === user.id));
    }
    return out;
  });
}
const txSlice = (re) => {
  const texts = fakeDb.calls.map((c) => c.text);
  const begin = texts.lastIndexOf('BEGIN');
  return texts.slice(begin, texts.indexOf('COMMIT', begin) + 1).filter((t) => t === 'BEGIN' || t === 'COMMIT' || re.test(t));
};

test('hesap-uyelik-7: servis PIN uretimi yetkiyi ayni islemde FOR SHARE ile yeniden dogrular; ara katmandan sonra sahiplik giderse 403, PIN yok', async () => {
  const h = store.addHome({ name: 'Yaris Servis Evi' });
  const seller = store.addUser();
  store.addMember(h, seller, 'owner');
  const before = store.tokens.length;
  dropMembershipAfterMiddleware(h, seller);
  const r = await request(app).post(`/api/v1/homes/${h.id}/service-token`).set('Authorization', `Bearer ${tok(seller)}`);
  assert.strictEqual(r.status, 403, JSON.stringify(r.body));
  assert.strictEqual(r.body.message, 'Bu işlem için yetkiniz yok.');
  assert.strictEqual(store.tokens.length, before, 'PIN uretilmedi');
  const ok = await request(app).post(`/api/v1/homes/${HOME.id}/service-token`).set('Authorization', `Bearer ${tok(owner)}`);
  assert.strictEqual(ok.status, 201);
  const seq = txSlice(/FOR SHARE|INSERT INTO service_tokens/).map((t) => (/FOR SHARE/.test(t) ? 'share' : /INSERT/.test(t) ? 'insert' : t));
  assert.deepStrictEqual(seq, ['BEGIN', 'share', 'insert', 'COMMIT']);
});

test('PIN uretimi: yalnizca owner; 6 hane; DB de ozet; yanit no-store', async () => {
  const res = await request(app).post(`/api/v1/homes/${HOME.id}/service-token`).set('Authorization', `Bearer ${tok(owner)}`);
  assert.strictEqual(res.status, 201);
  assert.match(res.body.data.service_pin, /^\d{6}$/);
  assert.strictEqual(res.headers['cache-control'], 'no-store');
  const row = store.tokens[store.tokens.length - 1];
  assert.match(row.pin_hash, /^h1\$[0-9a-f]{64}$/);
  assert.ok(!JSON.stringify(row).includes(res.body.data.service_pin));
});

for (const [who, user] of Object.entries({ resident, guest, staff, superUser, stranger, otherOwner })) {
  test(`PIN uretimi: ${who} -> 403`, async () => {
    const res = await request(app).post(`/api/v1/homes/${HOME.id}/service-token`).set('Authorization', `Bearer ${tok(user)}`);
    assert.strictEqual(res.status, 403);
  });
}

test('PIN listesi/oturum listesi/iptal: yabanci kullanici ve misafir -> 403; owner -> PIN degeri DONMEZ', async () => {
  for (const path of ['service-tokens', 'service-sessions']) {
    assert.strictEqual((await request(app).get(`/api/v1/homes/${HOME.id}/${path}`).set('Authorization', `Bearer ${tok(stranger)}`)).status, 403);
    assert.strictEqual((await request(app).get(`/api/v1/homes/${HOME.id}/${path}`).set('Authorization', `Bearer ${tok(guest)}`)).status, 403);
  }
  assert.strictEqual((await request(app).post(`/api/v1/homes/${HOME.id}/service-access/revoke`).set('Authorization', `Bearer ${tok(stranger)}`)).status, 403);
  const pin = await newPin();
  const list = await request(app).get(`/api/v1/homes/${HOME.id}/service-tokens`).set('Authorization', `Bearer ${tok(owner)}`);
  assert.strictEqual(list.status, 200);
  assert.ok(!JSON.stringify(list.body).includes(pin));
  assert.ok(list.body.data.every((t) => !('service_pin' in t) && !('pin_hash' in t)));
});

test('yeni PIN eskisini iptal eder', async () => {
  const p1 = await newPin();
  const p2 = await newPin();
  assert.strictEqual((await login(p1)).status, 401);
  assert.strictEqual((await login(p2)).status, 200);
});

test('servis girisi: sozlesme yaniti, refresh YOK, kullanici satiri / uyelik OLUSMAZ', async () => {
  const usersBefore = store.users.size;
  const membersBefore = store.members.length;
  const pin = await newPin();
  const res = await login(pin);
  assert.strictEqual(res.status, 200, JSON.stringify(res.body));
  const d = res.body.data;
  assert.ok(d.access_token);
  assert.strictEqual(d.refresh_token, undefined);
  assert.strictEqual(d.expires_in, 7200);
  assert.strictEqual(d.scope, 'home_service');
  assert.deepStrictEqual(d.home, { id: HOME.id, name: 'Servis Evi' });
  const claims = jwt.decode(d.access_token);
  assert.strictEqual(claims.role, 'service_session');
  assert.strictEqual(claims.home_id, HOME.id);
  assert.ok(claims.sid);
  assert.strictEqual(store.users.size, usersBefore);
  assert.strictEqual(store.members.length, membersBefore);
  assert.strictEqual(store.sessions[store.sessions.length - 1].technician_name, 'Ali Usta');
});

test('PIN tek kullanimlik; eszamanli iki giristen yalnizca biri basarili', async () => {
  const pin = await newPin();
  const [a, b] = await Promise.all([login(pin), login(pin)]);
  assert.deepStrictEqual([a.status, b.status].sort(), [200, 401]);
  assert.strictEqual((await login(pin)).status, 401);
});

test('suresi dolmus PIN reddedilir', async () => {
  const pin = await newPin();
  const row = store.tokens[store.tokens.length - 1];
  const ttlMs = row.expires_at.getTime() - clock;
  assert.ok(ttlMs > 2 * 3600e3 - 5000 && ttlMs <= 2 * 3600e3, `PIN suresi ${ttlMs} ms`);
  row.expires_at = new Date(clock - 1000); // 2 saat gecti
  const res = await login(pin);
  assert.strictEqual(res.status, 401);
});

test('oturum kapsami: kendi evi 200, baska ev 403, ev kapsamsiz uc 403, /homes yalnizca kendi evi', async () => {
  const pin = await newPin();
  const t = (await login(pin)).body.data.access_token;
  const own = await request(app).post(`/api/v1/homes/${HOME.id}/commission-test`).set('Authorization', `Bearer ${t}`);
  assert.strictEqual(own.status, 200);
  assert.strictEqual(own.body.access.is_service_session, true);
  assert.strictEqual((await request(app).post(`/api/v1/homes/${OTHER.id}/commission-test`).set('Authorization', `Bearer ${t}`)).status, 403);
  assert.strictEqual((await request(app).post('/api/v1/devices/claim').set('Authorization', `Bearer ${t}`).send({})).status, 403);
  // servis oturumu PIN uretemez (owner degil)
  assert.strictEqual((await request(app).post(`/api/v1/homes/${HOME.id}/service-token`).set('Authorization', `Bearer ${t}`)).status, 403);
  const homes = await request(app).get('/api/v1/homes').set('Authorization', `Bearer ${t}`);
  assert.strictEqual(homes.status, 200);
  assert.strictEqual(homes.body.data.length, 1);
  assert.strictEqual(homes.body.data[0].id, HOME.id);
  assert.strictEqual(homes.body.data[0].role, 'service_session');
});

test('revokeHomeServiceAccess: acik oturum aninda 401 SERVICE_SESSION_EXPIRED, kullanilmamis PIN iptal', async () => {
  const pinA = await newPin();
  const t = (await login(pinA)).body.data.access_token;
  const pinB = await newPin();
  const r = await serviceTokenService.revokeHomeServiceAccess(HOME.id, null, 'test');
  assert.ok(r.revoked_sessions >= 1);
  assert.ok(r.revoked_pins >= 1);
  const res = await request(app).post(`/api/v1/homes/${HOME.id}/commission-test`).set('Authorization', `Bearer ${t}`);
  assert.strictEqual(res.status, 401);
  assert.strictEqual(res.body.code, 'SERVICE_SESSION_EXPIRED');
  assert.strictEqual((await login(pinB)).status, 401);
});

test('uyelik-6: servis erisimini kapat -> evin servis oturumu MQTT kimlikleri (user_id bos) silinir ve atilir; yanit yalniz sayilar', async () => {
  assert.strictEqual(typeof serviceTokenService.setMqttCredentialService, 'function');
  const svcCred = store.addMqttCred({ home_id: HOME.id, user_id: null });
  const ownerCred = store.addMqttCred({ home_id: HOME.id, user_id: owner.id });
  const otherCred = store.addMqttCred({ home_id: OTHER.id, user_id: null });
  kicked.length = 0;
  const pin = await newPin();
  await login(pin);
  const res = await request(app).post(`/api/v1/homes/${HOME.id}/service-access/revoke`).set('Authorization', `Bearer ${tok(owner)}`);
  assert.strictEqual(res.status, 200, JSON.stringify(res.body));
  assert.deepStrictEqual(Object.keys(res.body.data).sort(), ['revoked_pins', 'revoked_sessions']);
  assert.ok(!JSON.stringify(res.body).includes(svcCred.username), 'kullanici adi yanitta yok');
  assert.ok(!store.mqttCreds.includes(svcCred), 'servis oturumu kimligi silindi');
  assert.ok(store.mqttCreds.includes(ownerCred) && store.mqttCreds.includes(otherCred), 'kullanici ve baska ev kimligi korunur');
  assert.deepStrictEqual(kicked, [svcCred.username], 'baglanti atildi');
});

test('uyelik-12: servis oturumu Bearer ile cikis -> oturum iptal (self_logout), sonraki istek 401, oturum MQTT kimligi silinir', async () => {
  const pin = await newPin();
  const t = (await login(pin)).body.data.access_token;
  const sid = jwt.decode(t).sid;
  const cred = store.addMqttCred({ home_id: HOME.id, user_id: null });
  kicked.length = 0;
  const out = await request(app).post('/api/v1/auth/logout').set('Authorization', `Bearer ${t}`).send({});
  assert.strictEqual(out.status, 200, JSON.stringify(out.body));
  const row = store.sessions.find((x) => x.id === sid);
  assert.ok(row.revoked_at, 'oturum iptal');
  assert.strictEqual(row.revoked_reason, 'self_logout');
  const after = await request(app).post(`/api/v1/homes/${HOME.id}/commission-test`).set('Authorization', `Bearer ${t}`);
  assert.strictEqual(after.status, 401);
  assert.strictEqual(after.body.code, 'SERVICE_SESSION_EXPIRED');
  assert.ok(!store.mqttCreds.includes(cred), 'servis oturumu MQTT kimligi silindi');
  assert.deepStrictEqual(kicked, [cred.username]);
});

test('uyelik-12: belirtecsiz / gecersiz belirtecli / kullanici belirtecli govdesiz cikis 200 ve hicbir sey iptal edilmez', async () => {
  const pin = await newPin();
  const t = (await login(pin)).body.data.access_token;
  const sid = jwt.decode(t).sid;
  assert.strictEqual((await request(app).post('/api/v1/auth/logout').send({})).status, 200);
  assert.strictEqual((await request(app).post('/api/v1/auth/logout').set('Authorization', 'Bearer bozuk.belirtec.degeri').send({})).status, 200);
  assert.strictEqual((await request(app).post('/api/v1/auth/logout').set('Authorization', `Bearer ${tok(owner)}`).send({})).status, 200);
  assert.strictEqual(store.sessions.find((x) => x.id === sid).revoked_at, null, 'baska cikis servis oturumuna dokunmaz');
  assert.strictEqual((await request(app).post(`/api/v1/homes/${HOME.id}/commission-test`).set('Authorization', `Bearer ${t}`)).status, 200);
});

test('pano-6: yerel anahtari OKUMUS servis oturumu owner iptaliyle ya da kendi cikisiyla bitince o evin anahtari hemen BEKLEYEN yolla doner', async () => {
  const { LocalKeyRotation } = require('../../src/services/local_key_rotation');
  const reconciles = [];
  const fakeBox = { generateLocalKey: () => 'YeniAnahtar0000', encrypt: (k) => `enc(${k.length})` };
  serviceTokenService.setLocalKeyRotation(new LocalKeyRotation({ secretBox: fakeBox, requestReconcile: (t) => reconciles.push(t), logger: { warn() {}, log() {}, error() {} } }));
  try {
    const mk = () => {
      const home = store.addHome({ name: `Anahtar Evi ${store.homes.size}` });
      const own = store.addUser();
      store.addMember(home, own, 'owner');
      return { home, own, dev: store.addDevice(home) };
    };
    // (1) owner iptali
    const a = mk();
    const ta = (await login(await newPin(a.home.id, a.own))).body.data.access_token;
    const rowA = store.sessions.find((x) => x.id === jwt.decode(ta).sid);
    rowA.local_key_read_at = new Date(clock); // oturum anahtari okudu (GET local-key isaretler)
    const res = await request(app).post(`/api/v1/homes/${a.home.id}/service-access/revoke`).set('Authorization', `Bearer ${tok(a.own)}`);
    assert.strictEqual(res.status, 200, JSON.stringify(res.body));
    assert.ok(a.dev.local_key_pending_enc, 'iptal sonrasi rotasyon');
    assert.ok(rowA.key_rotated_at, 'oturum isaretlendi');
    const audA = store.audits.filter((x) => x.event === 'local_key_rotation_scheduled' && x.home_id === a.home.id);
    assert.deepStrictEqual(audA.map((x) => x.details), [{ reason: 'service_session_ended' }]);

    // (2) kendi cikisi
    const b = mk();
    const tb = (await login(await newPin(b.home.id, b.own))).body.data.access_token;
    store.sessions.find((x) => x.id === jwt.decode(tb).sid).local_key_read_at = new Date(clock);
    assert.strictEqual((await request(app).post('/api/v1/auth/logout').set('Authorization', `Bearer ${tb}`).send({})).status, 200);
    assert.ok(b.dev.local_key_pending_enc, 'kendi cikisi sonrasi rotasyon');

    // (3) anahtari okumamis oturum: rotasyon yok
    const c = mk();
    await login(await newPin(c.home.id, c.own));
    assert.strictEqual((await request(app).post(`/api/v1/homes/${c.home.id}/service-access/revoke`).set('Authorization', `Bearer ${tok(c.own)}`)).status, 200);
    assert.strictEqual(c.dev.local_key_pending_enc, null);
    assert.deepStrictEqual(reconciles, [a.home.mqtt_username, b.home.mqtt_username]);
  } finally {
    serviceTokenService.setLocalKeyRotation(undefined);
  }
});

test('owner "servis erisimini kapat" ucu ayni etkiyi yapar', async () => {
  const pin = await newPin();
  const t = (await login(pin)).body.data.access_token;
  const res = await request(app).post(`/api/v1/homes/${HOME.id}/service-access/revoke`).set('Authorization', `Bearer ${tok(owner)}`);
  assert.strictEqual(res.status, 200);
  assert.strictEqual((await request(app).post(`/api/v1/homes/${HOME.id}/commission-test`).set('Authorization', `Bearer ${t}`)).status, 401);
});

test('IP basina 10 deneme / 15 dk -> 429 RATE_LIMITED', async () => {
  for (let i = 0; i < 10; i++) {
    const r = await login(String(100000 + i));
    assert.strictEqual(r.status, 401);
  }
  const blocked = await login('123456');
  assert.strictEqual(blocked.status, 429);
  assert.strictEqual(blocked.body.code, 'RATE_LIMITED');
  assert.ok(blocked.headers['retry-after']);
});

test('PIN bicimi gecersiz -> 400; teknisyen adi kontrol karakterlerinden temizlenir', async () => {
  assert.strictEqual((await login('12ab56')).status, 400);
  const pin = await newPin();
  const res = await login(pin, 'Ali\u0000\nUsta\t');
  assert.strictEqual(res.status, 200);
  assert.strictEqual(store.sessions[store.sessions.length - 1].technician_name, 'Ali Usta');
});

test('sahte DB: eslesmeyen SQL yok', () => {
  assert.deepStrictEqual(store.unmatched, []);
});
