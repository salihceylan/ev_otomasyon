'use strict';

// Servis sorumlusu KAPSAMI (kiracilik, migration 045) - GERCEK PostgreSQL, YALITILMIS gecici veritabani, gercek uygulama.
// Tasarim: docs/superpowers/specs/2026-10-12-servis-kapsamli-super-yetki-design.md
//
// Kiracilar arasi OLUMSUZ testler (A servisi B'nin evini / kartini / musterisini / sitesini goremez, degistiremez, kuramaz;
// aktarim, servis hesabi yonetimi ve ozet servise 403) + olumlu testler (kendi evinde 72 saat SONRA da tam erisim, kendi
// kartini kaydetme/askiya alma/silme, musteri listeleme, claim/devir atamasi, kok aktarimi).
// EV_PG_TEST_URL yoksa ATLANIR.

const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const { PG_SKIP, open } = require('../templates/_pg_isolated');

const FIX = path.join(__dirname, '..', '..', '..', 'docs', 'contracts', 'template', 'fixtures');
const fixture = (f) => JSON.parse(fs.readFileSync(path.join(FIX, f), 'utf8'));
const hex = (n) => crypto.randomBytes(n).toString('hex');
const REASON = 'Kiraci ulasilamiyor, daire teslim alindi';
const PIN = '135790';

let ctxPromise = null;
let seq = 0;

function getCtx() {
  if (ctxPromise) return ctxPromise;
  ctxPromise = (async () => {
    const env = await open('scope045');
    if (!env) return null;
    process.env.DATABASE_URL = env.url; // src/db.js ayni (yalitilmis) veritabanini kullansin
    process.env.NODE_ENV = 'test';
    process.env.BCRYPT_TEST_COST = '4';
    process.env.AUTH_CACHE_TTL_MS = '0';
    process.env.JWT_SECRET = crypto.randomBytes(32).toString('hex');
    process.env.PIN_PEPPER = crypto.randomBytes(32).toString('hex');
    process.env.LOCAL_KEY_SECRET = crypto.randomBytes(32).toString('hex');
    process.env.MQTT_PUBLIC_HOST = 'broker.test.invalid';
    process.env.MQTT_PUBLIC_PORT = '8884';
    for (const k of ['EMQX_API_URL', 'EMQX_API_KEY', 'EMQX_API_SECRET', 'ALLOW_DEBUG_OTP', 'ADMIN_API_KEY', 'SMTP_HOST', 'SMTP_USER', 'SMTP_PASSWORD', 'GOOGLE_CLIENT_IDS', 'APPLE_CLIENT_IDS', 'MQTT_BACKEND_USER', 'MQTT_BACKEND_PASS']) process.env[k] = '';
    console.warn = () => {};
    console.log = () => {};

    const request = require('supertest');
    const db = require('../../src/db');
    const mailerUtil = require('../../src/utils/mailer');
    mailerUtil.setTransportFactory(() => ({ sendMail: async () => {} }));
    const jwtConfig = require('../../src/middlewares/jwt_config');
    const pin = require('../../src/utils/pin');
    const { DeviceService } = require('../../src/services/device_service');
    const { MqttCredentialService } = require('../../src/services/mqtt_credential_service');
    const { createApp } = require('../../src/server');

    const bridge = {
      connected: true, isConnected() { return true; }, init() {}, end: async () => {},
      async publishCommand() { return {}; }, async publishSys() { return {}; }, async publishToTopic() { return {}; }, async clearRetained() {},
    };
    const app = createApp({ db, mqttBridge: bridge, pushService: { upsertToken: async () => {}, disableToken: async () => {} } });

    const silent = { warn() {}, error() {}, log() {} };
    const mailer = {
      sent: [],
      async sendClaimOtpEmail(a) { this.sent.push(a); return { sent: true }; },
      lastCode() { return this.sent.length ? this.sent[this.sent.length - 1].code : null; },
    };
    const deviceService = new DeviceService({
      db: env.db,
      mqttBridge: require('../devices/_ack_bridge').withAckSupport({ ...bridge }),
      mqttCredentials: new MqttCredentialService({ db: env.db, logger: silent }),
      mailer,
      inviteCustomer: async () => ({ sent: true }),
    });

    const q = (text, params) => env.db.query(text, params);
    const one = async (text, params) => (await q(text, params)).rows[0];
    const api = (method, url, token, body) => {
      let r = request(app)[method](url);
      if (token) r = r.set('Authorization', `Bearer ${token}`);
      if (body !== undefined && method !== 'get' && method !== 'delete') r = r.send(body);
      return r;
    };
    const h = {
      async user(role, label, extra = {}) {
        const n = ++seq;
        const r = await q(
          `INSERT INTO users (email, password_hash, full_name, role, phone, is_active, account_status, email_verified, created_by_user_id, google_id)
           VALUES ($1, 'x', $2, $3, $4, TRUE, 'active', TRUE, $5, $6) RETURNING id, email, role, token_version, full_name`,
          [`${label || role}${n}-${hex(2)}@scope.test`, extra.name || `${label || role} ${n}`, role, extra.phone || null, extra.createdBy || null, extra.social ? `g-${hex(6)}` : null]
        );
        const u = r.rows[0];
        u.token = jwtConfig.signAccessToken({ id: u.id, role: u.role, token_version: u.token_version });
        return u;
      },
      async card({ owner = null, status = 'IN_STOCK', uuid } = {}) {
        const n = ++seq;
        const r = await q(
          `INSERT INTO device_inventory (device_uuid, mac_address, pin_hash, model, status, service_owner_id)
           VALUES ($1, $2, $3, 'ESP32-S3-POE-ETH-8DI-8RO', $4, $5) RETURNING id, device_uuid`,
          [uuid || `AHBU-SC${hex(2).toUpperCase()}-${n}`, `E8:F6:0C:${hex(1)}:${hex(1)}:${(n & 255).toString(16).padStart(2, '0')}`.toUpperCase(), pin.hashPin(PIN), status, owner ? owner.id : null]
        );
        return r.rows[0];
      },
      async home(name, { serviceOwner = null, owner = null } = {}) {
        const r = await q('INSERT INTO homes (name, mqtt_username, service_owner_id) VALUES ($1, $2, $3) RETURNING id, name', [name, `h_${hex(8)}`, serviceOwner ? serviceOwner.id : null]);
        if (owner) await q("INSERT INTO home_users (home_id, user_id, role) VALUES ($1, $2, 'owner')", [r.rows[0].id, owner.id]);
        return r.rows[0];
      },
      member: (home, user, role, extra = {}) =>
        q('INSERT INTO home_users (home_id, user_id, role, installer_expires_at) VALUES ($1, $2, $3, $4)', [home.id, user.id, role, extra.expires || null]),
      act: (u, extra = {}) => ({ userId: u.id, globalRole: u.role, ip: '127.0.0.1', ...extra }),
      owns: async (table, key, val) => (await one(`SELECT service_owner_id AS o FROM ${table} WHERE ${key} = $1`, [val])).o,
    };
    return { env, q, one, api, h, deviceService, mailer, request, app, pin };
  })();
  return ctxPromise;
}

test.after(async () => {
  if (!ctxPromise) return;
  const c = await ctxPromise;
  if (!c) return;
  try {
    await require('../../src/db').pool.end(); // uygulamanin havuzu (src/db.js)
  } catch (_) {
    /* en iyi caba */
  }
  try {
    await c.env.close(); // yalitilmis veritabanini dusurur
  } catch (_) {
    /* temizlik en iyi caba */
  }
});

async function rejects(promise, status, code) {
  let err = null;
  try {
    await promise;
  } catch (e) {
    err = e;
  }
  assert.ok(err, `HTTP ${status} ${code || ''} bekleniyordu`);
  assert.equal(err.status, status, err.message);
  if (code) assert.equal(err.code, code, err.message);
  return err;
}

// ================================================================================================
// device_service: claim / acil sifirlama / pano degisimi kapsami
// ================================================================================================
test('PG kapsam - claim: servis kendi/kok stogundaki karti kurar, evi ve karti kendi kapsamina alir; baska servisin karti 403 (PIN sayaci oynamaz)', { skip: PG_SKIP }, async (t) => {
  const c = await getCtx();
  if (!c) return t.skip('CREATE DATABASE yetkisi yok');
  const { h, deviceService: svc, mailer, q, one } = c;
  const svcA = await h.user('service_user', 'svcA');
  const svcB = await h.user('service_user', 'svcB');
  const root = await h.user('super_user', 'root');
  const custEmail = (label) => `${label}-${hex(3)}@scope.test`.toLowerCase();

  const cardA = await h.card({ owner: svcA });
  const cardR = await h.card({}); // kok stogu
  const cardB = await h.card({ owner: svcB });

  // --- baska servisin stogundaki kart: OTP istegi de claim de 403; PIN sayaci DEGISMEZ
  const target = custEmail('musteriA');
  await rejects(svc.requestClaimOtp({ actor: h.act(svcB), deviceUuid: cardA.device_uuid, targetOwnerIdentifier: target }), 403, 'FORBIDDEN');
  await rejects(svc.claimDevice({ actor: h.act(svcB), deviceUuid: cardA.device_uuid, setupPin: '000000', targetOwnerIdentifier: target, otpCode: '123456' }), 403, 'FORBIDDEN');
  assert.equal((await one('SELECT failed_attempts FROM device_inventory WHERE id = $1', [cardA.id])).failed_attempts, 0, 'baska servisin kartinin PIN sayaci oynamadi');
  assert.equal(mailer.sent.length, 0, 'baska servis icin musteriye kod gitmedi');

  // --- servis KENDI stogundaki karti kurar: ev + kart servisin kapsamina girer, uyelik SURESIZ
  await svc.requestClaimOtp({ actor: h.act(svcA), deviceUuid: cardA.device_uuid, targetOwnerIdentifier: target });
  const r = await svc.claimDevice({ actor: h.act(svcA), deviceUuid: cardA.device_uuid, setupPin: PIN, targetOwnerIdentifier: target, otpCode: mailer.lastCode() });
  assert.equal(r.service_owner_id, svcA.id);
  assert.equal(r.technician_access_expires_at, undefined, 'kurulum penceresi alani artik donmez');
  assert.equal(r.technician_access_unlimited, true);
  assert.equal(await h.owns('homes', 'id', r.home_id), svcA.id);
  assert.equal(await h.owns('device_inventory', 'id', cardA.id), svcA.id);
  const mem = await one("SELECT installer_expires_at FROM home_users WHERE home_id = $1 AND user_id = $2 AND role = 'service_user'", [r.home_id, svcA.id]);
  assert.equal(mem.installer_expires_at, null, 'servis uyeligi suresiz');
  const cust = await one('SELECT id, created_by_user_id, role FROM users WHERE email = $1', [target]);
  assert.equal(cust.created_by_user_id, svcA.id, 'musteri servisin acmasi');

  // --- servis KOK stogundaki karti da kurar (karti kendi stogu degilse bile): kart evin servisine gecer
  const t2 = custEmail('musteriB');
  await svc.requestClaimOtp({ actor: h.act(svcB), deviceUuid: cardR.device_uuid, targetOwnerIdentifier: t2 });
  const r2 = await svc.claimDevice({ actor: h.act(svcB), deviceUuid: cardR.device_uuid, setupPin: PIN, targetOwnerIdentifier: t2, otpCode: mailer.lastCode() });
  assert.equal(await h.owns('homes', 'id', r2.home_id), svcB.id);
  assert.equal(await h.owns('device_inventory', 'id', cardR.id), svcB.id, 'kok stogundaki kart kurulunca evin servisine gecer');

  // --- super_user sahiplendirirse ev kok kalir (NULL); karti kimin stogundaysa evin servisi = NULL
  const t3 = custEmail('musteriC');
  await svc.requestClaimOtp({ actor: h.act(root), deviceUuid: cardB.device_uuid, targetOwnerIdentifier: t3 });
  const r3 = await svc.claimDevice({ actor: h.act(root), deviceUuid: cardB.device_uuid, setupPin: PIN, targetOwnerIdentifier: t3, otpCode: mailer.lastCode() });
  assert.equal(await h.owns('homes', 'id', r3.home_id), null, 'kok kurulumu: ev kok kapsaminda');
  assert.equal(await h.owns('device_inventory', 'id', cardB.id), null, 'kart evin servisini (kok) izler');
  assert.equal(r3.service_owner_id, null);
  assert.equal(await one('SELECT count(*)::int AS n FROM home_users WHERE home_id = $1 AND role = $2', [r3.home_id, 'service_user']).then((x) => x.n), 0, 'kok icin servis uyeligi acilmaz');

  // --- musteri kendi karti ile (servis kartini kendi uygulamasindan) sahiplenirse: ev kok, kart kok kapsamina duser
  const cardA2 = await h.card({ owner: svcA });
  const selfCust = await h.user('user', 'selfcust');
  const r4 = await svc.claimDevice({ actor: h.act(selfCust), deviceUuid: cardA2.device_uuid, setupPin: PIN });
  assert.equal(await h.owns('homes', 'id', r4.home_id), null);
  assert.equal(await h.owns('device_inventory', 'id', cardA2.id), null);

  // --- musterinin baska servisin kapsamindaki BOS evi, baska servis tarafindan sahiplenilmez (yeni ev acilir)
  const cust5 = await h.user('user', 'cust5');
  const emptyHomeB = await h.home('B bos ev', { serviceOwner: svcB, owner: cust5 });
  const cardA3 = await h.card({ owner: svcA });
  await svc.requestClaimOtp({ actor: h.act(svcA), deviceUuid: cardA3.device_uuid, targetOwnerIdentifier: cust5.email });
  const r5 = await svc.claimDevice({ actor: h.act(svcA), deviceUuid: cardA3.device_uuid, setupPin: PIN, targetOwnerIdentifier: cust5.email, otpCode: mailer.lastCode() });
  assert.notEqual(r5.home_id, emptyHomeB.id, 'B nin bos evi A tarafindan devralinmadi');
  assert.equal(await h.owns('homes', 'id', emptyHomeB.id), svcB.id, 'B nin evi degismedi');
  assert.equal(await h.owns('homes', 'id', r5.home_id), svcA.id);
  await q('SELECT 1');
});

test('PG kapsam - acil sifirlama ve pano degisimi: baska servis 403; kendi evinde sinirsiz (72 saat sonra da); devirde servis evin sahibi olur', { skip: PG_SKIP }, async (t) => {
  const c = await getCtx();
  if (!c) return t.skip('CREATE DATABASE yetkisi yok');
  const { h, deviceService: svc, mailer, q, one } = c;
  const svcA = await h.user('service_user', 'svcA2');
  const svcB = await h.user('service_user', 'svcB2');
  const root = await h.user('super_user', 'root2');
  const claimFor = async (service, label, card) => {
    const email = `${label}-${hex(3)}@scope.test`;
    await svc.requestClaimOtp({ actor: h.act(service), deviceUuid: card.device_uuid, targetOwnerIdentifier: email });
    const r = await svc.claimDevice({ actor: h.act(service), deviceUuid: card.device_uuid, setupPin: PIN, targetOwnerIdentifier: email, otpCode: mailer.lastCode() });
    return { ...r, email };
  };

  // A nin evi (kendi stogundaki kartla); servis uyeliginin 72 saatlik penceresi yok: eski pencereyi taklit et
  const cardA = await h.card({ owner: svcA });
  const a = await claimFor(svcA, 'cA', cardA);
  await q("UPDATE home_users SET installer_expires_at = NOW() - INTERVAL '5 days' WHERE home_id = $1 AND role = 'service_user'", [a.home_id]);
  const reset = (actor, card, extra = {}) => svc.emergencyReset({ actor: h.act(actor), deviceUuid: card.device_uuid, confirmUid: card.device_uuid, reason: REASON, ...extra });

  // B, A nin evindeki kartin acil sifirlamasini YAPAMAZ (uyelik yok / baska kapsam)
  await rejects(reset(svcB, cardA), 403, 'FORBIDDEN');
  assert.equal((await one('SELECT status FROM device_inventory WHERE id = $1', [cardA.id])).status, 'CLAIMED', 'baska servis kartin durumunu degistiremedi');
  // B bu eve (eski) bir uyelikle girse bile evin servisi A: 403
  await h.member({ id: a.home_id }, svcB, 'service_user', { expires: new Date(Date.now() + 3600e3) });
  await rejects(reset(svcB, cardA), 403, 'FORBIDDEN');
  await q("DELETE FROM home_users WHERE home_id = $1 AND user_id = $2", [a.home_id, svcB.id]);

  // A (kendi evi; kurulum penceresi coktan bitti): stoga alma izinli, kart A nin stogunda kalir
  const out = await reset(svcA, cardA);
  assert.equal(out.action, 'UNCLAIMED');
  assert.equal(out.service_owner_id, svcA.id);
  assert.equal(await h.owns('device_inventory', 'id', cardA.id), svcA.id, 'stoga donen kart ayni servisin stogunda');
  assert.equal(await h.owns('homes', 'id', a.home_id), svcA.id);

  // devir: KOK evinde (service_owner_id NULL) eski servis uyeligi olan A devreder -> ev A nin olur
  const root1 = await h.user('user', 'ownerR');
  const cardR = await h.card({});
  const rr = await claimFor(root, 'cR', cardR); // kok kurdu: ev NULL
  assert.equal(await h.owns('homes', 'id', rr.home_id), null);
  await h.member({ id: rr.home_id }, svcA, 'service_user', { expires: new Date(Date.now() + 3600e3) }); // eski pencereli uyelik
  const newOwner = await h.user('user', 'newOwner');
  const dev = await reset(svcA, cardR, { newOwnerIdentifier: newOwner.email });
  assert.equal(dev.action, 'REASSIGNED');
  assert.equal(dev.service_owner_id, svcA.id);
  assert.equal(await h.owns('homes', 'id', rr.home_id), svcA.id, 'devreden servis evin sahibi olur');
  assert.equal(await h.owns('device_inventory', 'id', cardR.id), svcA.id);
  const m = await one("SELECT installer_expires_at FROM home_users WHERE home_id = $1 AND user_id = $2 AND role = 'service_user'", [rr.home_id, svcA.id]);
  assert.equal(m.installer_expires_at, null, 'suresiz servis uyeligi');
  void root1;

  // pano degisimi: A, kendi evine B nin stogundaki karti TAKAMAZ (403, PIN sayaci oynamaz); kendi / kok stogundaki karti takar
  const cardA2 = await h.card({ owner: svcA });
  const b = await claimFor(svcB, 'cB', await h.card({ owner: svcB }));
  const cardB2 = await h.card({ owner: svcB });
  const replace = (actor, homeId, card, access) => svc.replaceBoard({
    actor: { ...h.act(actor), access }, homeId, newDeviceUuid: card.device_uuid, setupPin: PIN, reason: 'ariza',
  });
  await rejects(replace(svcA, rr.home_id, cardB2, 'service_user'), 403, 'FORBIDDEN');
  assert.equal((await one('SELECT failed_attempts FROM device_inventory WHERE id = $1', [cardB2.id])).failed_attempts, 0);
  const ok = await replace(svcA, rr.home_id, cardA2, 'service_user');
  assert.equal(ok.home_id, rr.home_id);
  assert.equal(await h.owns('device_inventory', 'id', cardA2.id), svcA.id, 'takilan kart evin servisinde');
  // super_user her karti takabilir: kart evin servisine (A) gecer
  const cardB3 = await h.card({ owner: svcB });
  await replace(root, rr.home_id, cardB3, 'super_user');
  assert.equal(await h.owns('device_inventory', 'id', cardB3.id), svcA.id, 'kok B nin kartini A nin evine takti: kart evin servisini izler');
  // B nin evi dokunulmaz
  assert.equal(await h.owns('homes', 'id', b.home_id), svcB.id);
});

// ================================================================================================
// HTTP: ev erisimi, uyelik, abone listesi, musteriler, envanter, site/sablon, aktarim
// ================================================================================================
test('PG kapsam - HTTP: ev erisimi (72 saat sonra da), baska servis 403, uyelik/servis kaldirilamaz, servis alani', { skip: PG_SKIP }, async (t) => {
  const c = await getCtx();
  if (!c) return t.skip('CREATE DATABASE yetkisi yok');
  const { h, api, q, one } = c;
  const svcA = await h.user('service_user', 'svcA3', { name: 'Servis Bir', phone: `+905${crypto.randomInt(0, 1e9).toString().padStart(9, '0')}` });
  const svcB = await h.user('service_user', 'svcB3');
  const root = await h.user('super_user', 'root3');
  const custA = await h.user('user', 'custA3');
  const custB = await h.user('user', 'custB3');
  const HA = await h.home('A evi', { serviceOwner: svcA, owner: custA });
  const HB = await h.home('B evi', { serviceOwner: svcB, owner: custB });
  const custR = await h.user('user', 'custR3');
  const HR = await h.home('Kok evi', { owner: custR });
  // A nin uyeligi: 72 saatlik pencere COKTAN bitmis (eski veri); yine de kapsam sayesinde sinirsiz erisim
  await h.member(HA, svcA, 'service_user', { expires: new Date(Date.now() - 5 * 86400e3) });
  await h.member(HB, svcB, 'service_user');
  // B nin HA da kalmis eski (pencereli) uyeligi: evin servisi A oldugu icin GECERSIZ
  await h.member(HA, svcB, 'service_user', { expires: new Date(Date.now() + 3600e3) });

  const dev = (home, who) => api('get', `/api/v1/homes/${home.id}/devices`, who.token);
  assert.equal((await dev(HA, svcA)).status, 200, 'A kendi evi: pencere bitmis olsa da');
  assert.equal((await dev(HA, svcB)).status, 403, 'B A nin evi: eski uyelik bile gecersiz');
  assert.equal((await dev(HB, svcA)).status, 403, 'A B nin evi');
  assert.equal((await dev(HB, svcB)).status, 200);
  assert.equal((await dev(HA, root)).status, 200);
  assert.equal((await dev(HR, svcA)).status, 403, 'kok evi (service_owner_id NULL, uyelik yok): servis 403');
  assert.equal((await dev(HR, root)).status, 200);

  // kapsamli super: yalniz ev sahibi/sakin uclari (devir) servise kapali; MQTT kimligi suresiz (pencereye bagli degil)
  const tr = await api('post', `/api/v1/homes/${HA.id}/transfer-initiate`, svcA.token, { target_identifier: 'x@scope.test' });
  assert.equal(tr.status, 403, 'daire devri yalniz ev sahibi');
  const cred = await api('post', `/api/v1/homes/${HA.id}/mqtt-credentials`, svcA.token, {});
  assert.equal(cred.status, 200, JSON.stringify(cred.body));
  assert.ok(cred.body.data.expires_in > 3600, `MQTT kimligi kurulum penceresiyle kisalmaz: ${cred.body.data.expires_in}`);
  assert.equal((await api('post', `/api/v1/homes/${HB.id}/mqtt-credentials`, svcA.token, {})).status, 403);

  // uyelik: servis ev sahibini cikarabilir (kapsamli super) ama KENDI servis uyeligi cikarilamaz; musteri servisi KALDIRAMAZ
  const members = await api('get', `/api/v1/homes/${HA.id}/members`, svcA.token);
  assert.equal(members.status, 200);
  assert.equal((await api('get', `/api/v1/homes/${HA.id}/members`, svcB.token)).status, 403);
  const rm = (who, home, target) => api('delete', `/api/v1/homes/${home.id}/members/${target.id}`, who.token);
  assert.equal((await rm(custA, HA, svcA)).status, 403, 'musteri servisi kaldiramaz');
  assert.equal((await rm(svcA, HA, svcA)).status, 403, 'servis kendini cikaramaz (kapsam service_owner_id de)');
  assert.ok((await one("SELECT 1 AS x FROM home_users WHERE home_id = $1 AND user_id = $2", [HA.id, svcA.id])), 'servis uyeligi korundu');
  const resident = await h.user('user', 'res3');
  await h.member(HA, resident, 'resident');
  assert.equal((await rm(svcA, HA, resident)).status, 200, 'servis kendi evinin uyesini cikarir');
  assert.equal((await rm(svcA, HB, custB)).status, 403, 'baska servisin evinden uye cikaramaz');

  // ev sahibi servis bilgisini gorur: {name, phone} (e-posta YOK); kok evinde null
  const homes = await api('get', '/api/v1/homes', custA.token);
  assert.equal(homes.status, 200);
  const mine = homes.body.data.find((x) => x.id === HA.id);
  assert.deepEqual(Object.keys(mine.service).sort(), ['name', 'phone']);
  assert.equal(mine.service.name, svcA.full_name);
  assert.ok(mine.service.phone);
  assert.ok(!JSON.stringify(mine.service).includes('@'), 'servis e-postasi sizmaz');
  const rootHomes = await api('get', '/api/v1/homes', custR.token);
  assert.equal(rootHomes.body.data[0].service, null, 'kok kapsamindaki evde servis alani null');

  // abone listesi: A yalniz kendi evleri; B yalniz kendi evleri; kok hepsi; baska servisin evinde Home Admin atama 403
  const subs = (who) => api('get', `/api/v1/service/subscribers?limit=100`, who.token);
  const ids = (res) => res.body.data.subscribers.map((s) => s.home_id);
  assert.ok(ids(await subs(svcA)).includes(HA.id) && !ids(await subs(svcA)).includes(HB.id) && !ids(await subs(svcA)).includes(HR.id));
  assert.ok(ids(await subs(svcB)).includes(HB.id) && !ids(await subs(svcB)).includes(HA.id));
  const allIds = ids(await subs(root));
  assert.ok([HA.id, HB.id, HR.id].every((x) => allIds.includes(x)));
  const target = { full_name: 'Yeni Sahip', email: `yeni-${hex(3)}@scope.test` };
  assert.equal((await api('post', `/api/v1/service/subscribers/${HB.id}/assign-admin/request-otp`, svcA.token, target)).status, 403);
  assert.equal((await api('post', `/api/v1/service/subscribers/${HR.id}/assign-admin`, svcA.token, target)).status, 403, 'sahipsiz (kok) ev: servis yonetemez');

  // daire devri (musteri -> musteri) servis kapsamini ve servis uyeligini DEGISTIRMEZ
  const buyer = await h.user('user', 'buyer3');
  const init = await api('post', `/api/v1/homes/${HA.id}/transfer-initiate`, custA.token, { target_identifier: buyer.email });
  assert.equal(init.status, 201, JSON.stringify(init.body));
  const accept = await api('post', '/api/v1/homes/transfer-accept', buyer.token, { transfer_code: init.body.data.transfer_code });
  assert.equal(accept.status, 200, JSON.stringify(accept.body));
  assert.equal(await h.owns('homes', 'id', HA.id), svcA.id, 'devir servis kapsamini degistirmez');
  assert.ok(await one("SELECT 1 AS x FROM home_users WHERE home_id = $1 AND user_id = $2 AND role = 'service_user'", [HA.id, svcA.id]), 'servis uyeligi devirde korunur');
  assert.equal((await one("SELECT role FROM home_users WHERE home_id = $1 AND user_id = $2", [HA.id, buyer.id])).role, 'owner');
  assert.equal((await dev(HA, svcA)).status, 200, 'servis devirden sonra da erisir');
  assert.equal((await api('get', '/api/v1/homes', buyer.token)).body.data[0].service.name, svcA.full_name, 'yeni ev sahibi servisi gorur');

  // kok'a gecmis uyelik penceresi servisi etkilemez: kural (zamanli) olusturma kendi evinde calisir
  const rules = await api('get', `/api/v1/homes/${HA.id}/scheduled-rules`, svcA.token);
  assert.equal(rules.status, 200);
  assert.equal((await api('get', `/api/v1/homes/${HA.id}/scheduled-rules`, svcB.token)).status, 403);
  void q;
});

test('PG kapsam - HTTP: evin (suresiz) servis uyeligi ev sahibinin hesap silmesini ENGELLEMEZ (cihazsiz ev silinir); cihazli ev yine engeller', { skip: PG_SKIP }, async (t) => {
  const c = await getCtx();
  if (!c) return t.skip('CREATE DATABASE yetkisi yok');
  const { h, one, request, app } = c;
  const svcA = await h.user('service_user', 'svcA7');
  const cust = await h.user('user', 'custDel7', { social: true });
  const home = await h.home('Silinecek ev', { serviceOwner: svcA, owner: cust });
  await h.member(home, svcA, 'service_user');
  const del = (u) => request(app).delete('/api/v1/auth/account').set('Authorization', `Bearer ${u.token}`).send({ confirm: 'SİL' });
  const withDevice = await h.user('user', 'custDev7', { social: true });
  const homeD = await h.home('Cihazli ev', { serviceOwner: svcA, owner: withDevice });
  await h.member(homeD, svcA, 'service_user');
  await c.q("INSERT INTO devices (home_id, device_uuid, mac_address, is_claimed) VALUES ($1, $2, $3, TRUE)", [homeD.id, `AHBU-DEL7-${hex(2).toUpperCase()}`, `E8:F6:0E:${hex(1)}:${hex(1)}:${hex(1)}`.toUpperCase()]);
  const blocked = await del(withDevice);
  assert.equal(blocked.status, 409, JSON.stringify(blocked.body));
  assert.equal(blocked.body.code, 'SOLE_OWNER');
  const ok = await del(cust);
  assert.equal(ok.status, 200, JSON.stringify(ok.body));
  assert.equal(await one('SELECT 1 AS x FROM homes WHERE id = $1', [home.id]), undefined, 'cihazsiz bos ev silindi');
  assert.ok(await one('SELECT 1 AS x FROM homes WHERE id = $1', [homeD.id]));
});

test('PG kapsam - HTTP: musteriler (liste/detay/degistirme/silme) yalniz kendi kapsaminda; servis hesabi yonetimi ve aktarim yalniz kok', { skip: PG_SKIP }, async (t) => {
  const c = await getCtx();
  if (!c) return t.skip('CREATE DATABASE yetkisi yok');
  const { h, api, q, one } = c;
  const svcA = await h.user('service_user', 'svcA4');
  const svcB = await h.user('service_user', 'svcB4');
  const root = await h.user('super_user', 'root4');
  const HA = await h.home('A4', { serviceOwner: svcA });
  const HB = await h.home('B4', { serviceOwner: svcB });
  const custA = await h.user('user', 'custA4', { createdBy: svcA.id });
  const custB = await h.user('user', 'custB4', { createdBy: svcB.id });
  const custMember = await h.user('user', 'custM4'); // yalniz A nin evinde uye (A actirmadi)
  const custShared = await h.user('user', 'custS4'); // hem A hem B nin evinde uye
  const custOnlyA = await h.user('user', 'custO4'); // yalniz A nin evinde uye
  await h.member(HA, custA, 'resident');
  await h.member(HB, custB, 'resident');
  await h.member(HA, custMember, 'resident');
  await h.member(HA, custShared, 'resident');
  await h.member(HB, custShared, 'resident');
  await h.member(HA, custOnlyA, 'resident');
  const stranger = await h.user('user', 'stranger4');

  const list = await api('get', '/api/v1/admin/users?limit=100', svcA.token);
  assert.equal(list.status, 200, JSON.stringify(list.body));
  const got = new Set(list.body.data.users.map((u) => u.id));
  for (const u of [custA, custMember, custShared, custOnlyA, svcA]) assert.ok(got.has(u.id), `A listesinde olmali: ${u.email}`);
  for (const u of [custB, svcB, root, stranger]) assert.ok(!got.has(u.id), `A listesinde OLMAMALI: ${u.email}`);
  assert.ok(list.body.data.users.every((u) => u.role !== 'super_user'));

  // detay: kapsam disi 404; ortak musteride yalniz A nin evleri
  assert.equal((await api('get', `/api/v1/admin/users/${custB.id}`, svcA.token)).status, 404);
  assert.equal((await api('get', `/api/v1/admin/users/${svcB.id}`, svcA.token)).status, 404);
  assert.equal((await api('get', `/api/v1/admin/users/${root.id}`, svcA.token)).status, 404);
  const shared = await api('get', `/api/v1/admin/users/${custShared.id}`, svcA.token);
  assert.equal(shared.status, 200);
  assert.deepEqual(shared.body.data.homes.map((x) => x.id), [HA.id], 'ortak musterinin B deki uyeligi A ya sizmaz');

  // degistirme / dondurma / sifirlama baglantisi / not
  assert.equal((await api('patch', `/api/v1/admin/users/${custB.id}`, svcA.token, { full_name: 'Ele Gecirildi' })).status, 404);
  assert.equal((await api('post', `/api/v1/admin/users/${custB.id}/send-reset`, svcA.token)).status, 404);
  assert.equal((await one('SELECT full_name FROM users WHERE id = $1', [custB.id])).full_name !== 'Ele Gecirildi', true);
  assert.equal((await api('patch', `/api/v1/admin/users/${custMember.id}`, svcA.token, { admin_notes: 'servis notu', is_active: false })).status, 200, 'uye musteri: dondurma + not');
  assert.equal((await api('patch', `/api/v1/admin/users/${custMember.id}`, svcA.token, { is_active: true })).status, 200, 'acma');
  // parola/rol: servis HICBIR kullanicida degistiremez
  assert.equal((await api('patch', `/api/v1/admin/users/${custA.id}`, svcA.token, { role: 'service_user' })).status, 403);
  assert.equal((await api('patch', `/api/v1/admin/users/${custA.id}`, svcA.token, { password: 'Yeni-Parola-123' })).status, 403);

  // kalici silme: yalniz butun uyelikleri kendi evlerindeyse
  assert.equal((await api('delete', `/api/v1/admin/users/${custShared.id}?hard=true`, svcA.token)).status, 403, 'ortak musteri (B de de uye): kalici silinemez');
  assert.ok(await one('SELECT 1 AS x FROM users WHERE id = $1', [custShared.id]));
  assert.equal((await api('delete', `/api/v1/admin/users/${custB.id}?hard=true`, svcA.token)).status, 404);
  const del = await api('delete', `/api/v1/admin/users/${custOnlyA.id}?hard=true`, svcA.token);
  assert.equal(del.status, 200, JSON.stringify(del.body));
  assert.equal(await one('SELECT 1 AS x FROM users WHERE id = $1', [custOnlyA.id]), undefined);

  // ESKI: servis hesabi acma/silme/dondurma + rol degistirme + ozet + aktarim YALNIZ KOK
  assert.equal((await api('post', '/api/v1/admin/users', svcA.token, { full_name: 'Yeni Servis', email: `ys-${hex(3)}@scope.test`, role: 'service_user' })).status, 403);
  assert.equal((await api('post', '/api/v1/admin/users', svcA.token, { full_name: 'Yeni Super', email: `su-${hex(3)}@scope.test`, role: 'super_user' })).status, 403);
  assert.equal((await api('patch', `/api/v1/admin/users/${svcB.id}`, svcA.token, { is_active: false })).status, 404, 'baska servis dondurulamaz');
  assert.equal((await api('delete', `/api/v1/admin/users/${svcB.id}`, svcA.token)).status, 404, 'baska servis silinemez/dondurulamaz');
  assert.equal((await api('patch', `/api/v1/admin/users/${svcA.id}`, svcA.token, { role: 'super_user' })).status, 403, 'kendini super yapamaz');
  assert.equal((await api('patch', `/api/v1/admin/users/${svcA.id}`, svcA.token, { role: 'user' })).status, 403);
  assert.equal((await one('SELECT role FROM users WHERE id = $1', [svcA.id])).role, 'service_user');
  assert.equal((await api('get', '/api/v1/admin/service-summary', svcA.token)).status, 403);
  assert.equal((await api('get', '/api/v1/admin/service-summary', root.token)).status, 200);
  for (const who of [svcA, svcB, stranger]) {
    assert.equal((await api('patch', `/api/v1/admin/homes/${HA.id}/service-owner`, who.token, { service_user_id: svcB.id })).status, 403, `ev aktarimi: ${who.email}`);
    assert.equal((await api('patch', `/api/v1/admin/sites/${crypto.randomUUID()}/service-owner`, who.token, { service_user_id: svcB.id })).status, 403);
    assert.equal((await api('patch', `/api/v1/admin/inventory/AHBU-NONE-1/service-owner`, who.token, { service_user_id: svcB.id })).status, 403);
  }
  assert.equal(await h.owns('homes', 'id', HA.id), svcA.id, 'yetkisiz aktarim denemesi hicbir seyi degistirmedi');

  // KOK aktarir: ev + evdeki kartlar + uyelikler; eski servis erisimi kaybeder, yeni servis kazanir
  const cardInA = await h.card({ owner: svcA, status: 'CLAIMED' });
  await q('UPDATE device_inventory SET claimed_home_id = $1 WHERE id = $2', [HA.id, cardInA.id]);
  await h.member(HA, svcA, 'service_user');
  const bad = await api('patch', `/api/v1/admin/homes/${HA.id}/service-owner`, root.token, { service_user_id: custA.id });
  assert.equal(bad.status, 404, 'hedef service_user olmali');
  assert.equal((await api('patch', `/api/v1/admin/homes/${HA.id}/service-owner`, root.token, {})).status, 400, 'alan zorunlu');
  const moved = await api('patch', `/api/v1/admin/homes/${HA.id}/service-owner`, root.token, { service_user_id: svcB.id });
  assert.equal(moved.status, 200, JSON.stringify(moved.body));
  assert.equal(moved.body.data.previous_service_owner_id, svcA.id);
  assert.equal(await h.owns('homes', 'id', HA.id), svcB.id);
  assert.equal(await h.owns('device_inventory', 'id', cardInA.id), svcB.id, 'evdeki kart ev ile birlikte gecer');
  assert.equal((await one("SELECT count(*)::int AS n FROM home_users WHERE home_id = $1 AND user_id = $2", [HA.id, svcA.id])).n, 0, 'eski servis uyeligi kalkti');
  assert.equal((await one("SELECT installer_expires_at FROM home_users WHERE home_id = $1 AND user_id = $2", [HA.id, svcB.id])).installer_expires_at, null);
  assert.equal((await api('get', `/api/v1/homes/${HA.id}/devices`, svcA.token)).status, 403, 'eski servis erisimi kaybetti');
  assert.equal((await api('get', `/api/v1/homes/${HA.id}/devices`, svcB.token)).status, 200, 'yeni servis erisim kazandi');
  const audit = await one("SELECT actor_role, details FROM device_audit_logs WHERE event = 'home_service_owner_changed' AND home_id = $1", [HA.id]);
  assert.equal(audit.actor_role, 'super_user');
  assert.equal(audit.details.from, svcA.id);
  // koke geri al (null)
  assert.equal((await api('patch', `/api/v1/admin/homes/${HA.id}/service-owner`, root.token, { service_user_id: null })).status, 200);
  assert.equal(await h.owns('homes', 'id', HA.id), null);
  assert.equal((await api('get', `/api/v1/homes/${HA.id}/devices`, svcB.token)).status, 403);
});

test('PG kapsam - HTTP: envanter (kayit/liste/askiya alma/etiket/PIN kilidi/silme) ve fabrika araci yalniz kendi kartlari; yerel anahtar', { skip: PG_SKIP }, async (t) => {
  const c = await getCtx();
  if (!c) return t.skip('CREATE DATABASE yetkisi yok');
  const { h, api, one } = c;
  const svcA = await h.user('service_user', 'svcA5');
  const svcB = await h.user('service_user', 'svcB5');
  const root = await h.user('super_user', 'root5');
  const reg = (who, uuid, macTail) => api('post', '/api/v1/admin/inventory/register', who.token, { device_uuid: uuid, mac_address: `E8:F6:0D:5${macTail}:00:01`, pin: '246810' });
  const uA = `AHBU-INV5A-${hex(2).toUpperCase()}`;
  const uB = `AHBU-INV5B-${hex(2).toUpperCase()}`;
  const uR = `AHBU-INV5R-${hex(2).toUpperCase()}`;
  assert.equal((await reg(svcA, uA, '1')).status, 201);
  assert.equal((await reg(svcB, uB, '2')).status, 201);
  assert.equal((await reg(root, uR, '3')).status, 201);
  assert.equal(await h.owns('device_inventory', 'device_uuid', uA), svcA.id);
  assert.equal(await h.owns('device_inventory', 'device_uuid', uB), svcB.id);
  assert.equal(await h.owns('device_inventory', 'device_uuid', uR), null, 'kok kok stoguna');

  const list = await api('get', '/api/v1/admin/inventory?limit=100', svcA.token);
  const uuids = list.body.data.items.map((i) => i.device_uuid);
  assert.ok(uuids.includes(uA) && !uuids.includes(uB) && !uuids.includes(uR), 'liste/arama yalniz kendi kartlari');
  assert.equal((await api('get', `/api/v1/admin/inventory?search=${uB}`, svcA.token)).body.data.total, 0, 'arama baska kapsama sizmaz');
  assert.equal(list.body.data.stats.total, list.body.data.total, 'ozet de kapsamli');
  assert.equal((await api('get', `/api/v1/admin/inventory/${uB}`, svcA.token)).status, 404);
  assert.equal((await api('get', `/api/v1/admin/inventory`, root.token)).body.data.items.some((i) => i.service_owner_id === svcA.id && i.service_owner_email === svcA.email), true, 'kok stok sahibini gorur');

  // yonetim: kendi karti serbest; baskasi / kok stogu 404; REVOKED yalniz kok
  const st = (who, uuid, status) => api('patch', `/api/v1/admin/inventory/${uuid}/status`, who.token, { status });
  assert.equal((await st(svcA, uA, 'SUSPENDED')).status, 200);
  assert.equal((await st(svcA, uA, 'IN_STOCK')).status, 200);
  assert.equal((await st(svcA, uA, 'REVOKED')).status, 403);
  assert.equal((await st(svcA, uB, 'SUSPENDED')).status, 404);
  assert.equal((await st(svcA, uR, 'SUSPENDED')).status, 404, 'kok stogu servis tarafindan yonetilemez');
  assert.equal((await one('SELECT status FROM device_inventory WHERE device_uuid = $1', [uB])).status, 'IN_STOCK');
  const relabel = await api('post', `/api/v1/admin/inventory/${uA}/reissue-label`, svcA.token, {});
  assert.equal(relabel.status, 200, JSON.stringify(relabel.body));
  assert.match(relabel.body.data.setup_pin, /^\d{6}$/);
  assert.equal((await api('post', `/api/v1/admin/inventory/${uB}/reissue-label`, svcA.token, {})).status, 404);
  assert.equal((await api('post', `/api/v1/admin/inventory/${uA}/clear-pin-lock`, svcA.token, {})).status, 200);
  assert.equal((await api('post', `/api/v1/admin/inventory/${uR}/clear-pin-lock`, svcA.token, {})).status, 404);
  const audit = await one("SELECT actor_role FROM device_audit_logs WHERE event = 'inventory_label_reissued' AND device_uuid = $1", [uA]);
  assert.equal(audit.actor_role, 'service_user', 'denetim kaydi gercek rolu yazar');
  assert.equal((await api('delete', `/api/v1/admin/inventory/${uB}`, svcA.token)).status, 404);
  assert.equal((await api('delete', `/api/v1/admin/inventory/${uR}`, svcA.token)).status, 404);

  // yerel anahtar (Ethernet yazimi): kendi karti + kok stogundaki kurulabilir kart; baska servisin karti 404 ve denetim YOK
  assert.equal((await api('get', `/api/v1/admin/inventory/${uA}/local-key`, svcA.token)).status, 200);
  assert.equal((await api('get', `/api/v1/admin/inventory/${uR}/local-key`, svcA.token)).status, 200, 'kok stogundaki IN_STOCK kart kurulabilir');
  assert.equal((await api('get', `/api/v1/admin/inventory/${uB}/local-key`, svcA.token)).status, 404);
  assert.equal((await one("SELECT count(*)::int AS n FROM device_audit_logs WHERE event = 'inventory_local_key_read' AND device_uuid = $1", [uB])).n, 0);

  // aktarim: servis 403; kok aktarir -> yeni sahip gorur, eski goremez; kurulu kart 409
  assert.equal((await api('patch', `/api/v1/admin/inventory/${uA}/service-owner`, svcA.token, { service_user_id: svcB.id })).status, 403);
  assert.equal((await api('patch', `/api/v1/admin/inventory/${uA}/service-owner`, root.token, { service_user_id: svcB.id })).status, 200);
  assert.equal((await api('get', `/api/v1/admin/inventory/${uA}`, svcB.token)).status, 200);
  assert.equal((await api('get', `/api/v1/admin/inventory/${uA}`, svcA.token)).status, 404);
  // stoktaki kendi karti siler
  assert.equal((await api('delete', `/api/v1/admin/inventory/${uB}`, svcB.token)).status, 200);
});

test('PG kapsam - HTTP: site/daire/sablon/yazim kaydi: kendi sitesinde tam yetki; baska servisin sitesi 404; genel sablon salt-okunur; site aktarimi yalniz kok', { skip: PG_SKIP }, async (t) => {
  const c = await getCtx();
  if (!c) return t.skip('CREATE DATABASE yetkisi yok');
  const { h, api, one } = c;
  const svcA = await h.user('service_user', 'svcA6');
  const svcB = await h.user('service_user', 'svcB6');
  const root = await h.user('super_user', 'root6');

  // site: acan servis sahibi olur; kok actiginda sahipsiz
  const sA = await api('post', '/api/v1/sites', svcA.token, { name: `A Sitesi ${hex(2)}` });
  assert.equal(sA.status, 201, JSON.stringify(sA.body));
  const sB = await api('post', '/api/v1/sites', svcB.token, { name: `B Sitesi ${hex(2)}` });
  const sR = await api('post', '/api/v1/sites', root.token, { name: `Kok Sitesi ${hex(2)}` });
  assert.equal(await h.owns('sites', 'id', sA.body.data.id), svcA.id);
  assert.equal(await h.owns('sites', 'id', sR.body.data.id), null);

  const names = async (who) => (await api('get', '/api/v1/sites', who.token)).body.data.map((s) => s.id);
  const lA = await names(svcA);
  assert.ok(lA.includes(sA.body.data.id) && !lA.includes(sB.body.data.id) && !lA.includes(sR.body.data.id), 'liste kapsamli');
  assert.ok((await names(root)).includes(sB.body.data.id));

  // baska servisin / sahipsiz site: goremez, degistiremez, silemez, daire ekleyemez
  for (const [label, siteId] of [['B nin sitesi', sB.body.data.id], ['kok sitesi', sR.body.data.id]]) {
    assert.equal((await api('get', `/api/v1/sites/${siteId}`, svcA.token)).status, 404, label);
    assert.equal((await api('patch', `/api/v1/sites/${siteId}`, svcA.token, { notes: 'x' })).status, 404, label);
    assert.equal((await api('delete', `/api/v1/sites/${siteId}`, svcA.token)).status, 404, label);
    assert.equal((await api('get', `/api/v1/sites/${siteId}/flats`, svcA.token)).status, 404, label);
    assert.equal((await api('post', `/api/v1/sites/${siteId}/flats/bulk`, svcA.token, { block: 'A', from: 1, to: 2 })).status, 404, label);
  }
  assert.equal((await one('SELECT notes FROM sites WHERE id = $1', [sB.body.data.id])).notes, null);

  // kendi sitesi: daire + sablon + kart baglama + yazim kaydi + yerel anahtar
  const flats = await api('post', `/api/v1/sites/${sA.body.data.id}/flats/bulk`, svcA.token, { block: 'A', from: 1, to: 3 });
  assert.equal(flats.status, 201, JSON.stringify(flats.body));
  const [f1, f2] = flats.body.data.created;
  const tpl = await api('post', '/api/v1/templates', svcA.token, { site_id: sA.body.data.id, body: fixture('ok_1p1.json') });
  assert.equal(tpl.status, 201, JSON.stringify(tpl.body));
  const tplB = await api('post', '/api/v1/templates', svcB.token, { site_id: sB.body.data.id, body: fixture('ok_1p1.json') });
  assert.equal(tplB.status, 201);
  assert.equal((await api('post', '/api/v1/templates', svcA.token, { site_id: sB.body.data.id, body: fixture('ok_1p1.json') })).status, 404, 'baska servisin sitesine sablon');

  // sablon okuma/degistirme kapsami
  assert.equal((await api('get', `/api/v1/templates/${tplB.body.data.id}`, svcA.token)).status, 404);
  assert.equal((await api('get', `/api/v1/templates/${tplB.body.data.id}/versions`, svcA.token)).status, 404);
  assert.equal((await api('put', `/api/v1/templates/${tplB.body.data.id}`, svcA.token, { body: fixture('ok_1p1.json') })).status, 404);
  assert.equal((await api('delete', `/api/v1/templates/${tplB.body.data.id}`, svcA.token)).status, 404);
  assert.equal((await api('get', `/api/v1/templates?site_id=${sB.body.data.id}`, svcA.token)).status, 404, 'baska servisin sitesinin sablon listesi');
  // genel sablon: kok olusturur; servis okur/kullanir, degistiremez
  const gen = await api('post', '/api/v1/templates', root.token, { site_id: null, body: fixture('ok_2p1_genel.json') });
  assert.equal(gen.status, 201, JSON.stringify(gen.body));
  assert.equal((await api('post', '/api/v1/templates', svcA.token, { site_id: null, body: fixture('ok_2p1_genel.json') })).status, 403);
  assert.equal((await api('get', `/api/v1/templates/${gen.body.data.id}`, svcA.token)).status, 200, 'servis genel sablonu okur');
  assert.equal((await api('put', `/api/v1/templates/${gen.body.data.id}`, svcA.token, { body: fixture('ok_2p1_genel.json') })).status, 403);
  assert.equal((await api('delete', `/api/v1/templates/${gen.body.data.id}`, svcA.token)).status, 403);
  assert.equal((await api('patch', `/api/v1/sites/${sA.body.data.id}/flats/${f2.id}`, svcA.token, { template_id: gen.body.data.id })).status, 200, 'genel sablonu daireye atayabilir (kullanir)');
  const listed = (await api('get', `/api/v1/templates?site_id=${sA.body.data.id}&include_global=1`, svcA.token)).body.data.map((x) => x.id);
  assert.ok(listed.includes(tpl.body.data.id) && listed.includes(gen.body.data.id) && !listed.includes(tplB.body.data.id));

  // kart baglama: kendi + kok stogu; baska servisin karti 403
  const cA = await h.card({ owner: svcA });
  const cB = await h.card({ owner: svcB });
  const cR = await h.card({});
  const link = (who, flat, uuid) => api('put', `/api/v1/sites/${sA.body.data.id}/flats/${flat.id}/device`, who.token, { device_uuid: uuid });
  assert.equal((await link(svcA, f1, cB.device_uuid)).status, 403, 'baska servisin karti daireye baglanamaz');
  assert.equal((await link(svcA, f1, cA.device_uuid)).status, 200);
  assert.equal((await link(svcA, f2, cR.device_uuid)).status, 200, 'kok stogundaki kart');
  assert.equal((await link(svcB, f1, cB.device_uuid)).status, 404, 'B A nin dairesine dokunamaz');

  // yazim kaydi: kendi sitesi + kendi karti; baska servisin karti / sablonu 404
  const write = (who, body) => api('post', '/api/v1/template-writes', who.token, { via: 'usb', result: 'ok', version: 1, ...body });
  assert.equal((await write(svcA, { device_uuid: cA.device_uuid, template_id: tpl.body.data.id, flat_id: f1.id })).status, 201);
  assert.equal((await write(svcA, { device_uuid: cB.device_uuid, template_id: tpl.body.data.id })).status, 404, 'baska servisin kartina yazim kaydi');
  assert.equal((await write(svcA, { device_uuid: cA.device_uuid, template_id: tplB.body.data.id })).status, 404, 'baska servisin sablonu');
  assert.equal((await write(svcB, { device_uuid: cA.device_uuid, template_id: tplB.body.data.id, flat_id: f1.id })).status, 404, 'B A nin dairesine/kartina yazamaz');

  // site aktarimi yalniz kok
  const moveSite = (who) => api('patch', `/api/v1/admin/sites/${sA.body.data.id}/service-owner`, who.token, { service_user_id: svcB.id });
  assert.equal((await moveSite(svcA)).status, 403);
  assert.equal((await moveSite(svcB)).status, 403);
  assert.equal(await h.owns('sites', 'id', sA.body.data.id), svcA.id);
  assert.equal((await moveSite(root)).status, 200);
  assert.equal(await h.owns('sites', 'id', sA.body.data.id), svcB.id);
  assert.equal((await api('get', `/api/v1/sites/${sA.body.data.id}`, svcA.token)).status, 404, 'eski servis siteyi kaybetti');
  assert.equal((await api('get', `/api/v1/sites/${sA.body.data.id}`, svcB.token)).status, 200);
});
