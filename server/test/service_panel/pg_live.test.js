'use strict';

// WP-B2 - GERCEK PostgreSQL entegrasyon testleri (servis paneli, Home Admin atama, hesap silme, etiket yeniden uretimi).
//
// Varsayilan olarak ATLANIR (`npm test` PostgreSQL gerektirmez). Etkinlestirmek icin TAMAMEN migration'lanmis
// (001..030) bir veritabani verin:
//
//   DATABASE_URL=<hedef> MIGRATE_CONFIRM=<db> node scripts/migrate.js           # once migration'lar (027-029 dahil)
//   EV_PG_TEST_URL=postgresql://kullanici:parola@127.0.0.1:5432/<db> node --test test/service_panel/pg_live.test.js
//
// (WP-Q yerel QA yiginindaki gomulu PostgreSQL de kullanilabilir: tools/qa_stack.) UYGULAMA VERITABANINA
// (uretim/canli) KARSI CALISTIRMAYIN: kullanici/ev/cihaz satirlari olusturur ve siler.
//
// Gercek uygulama (createApp) + gercek auth_middleware + gercek servisler + gercek SQL: yalnizca MQTT koprusu ve
// e-posta tasiyicisi sahtedir (e-posta govdesinden OTP okunur). Her test KENDI satirlarini olusturur (etiketli:
// e-posta *-<etiket>@b2live.example.test, ev adi B2L-<ETIKET>-n, cihaz AHBU-B2L<ETIKET>-n) ve sonunda yalnizca
// bu etiketli satirlari siler.
//
// Neden: mock'lu testler SQL'in gercekten GECERLI ve DOGRU oldugunu (FK/ON DELETE, atomik transaction, kilitler,
// kismi UNIQUE indeksler, ON CONFLICT, anonimlestirmenin e-postayi serbest birakmasi) kanitlamaz.

const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');

const URL_ = process.env.EV_PG_TEST_URL;
const SKIP = URL_ ? false : 'EV_PG_TEST_URL tanimli degil (gercek PostgreSQL gerekir)';

const TAG = crypto.randomBytes(3).toString('hex'); // 6 hex kucuk harf
const DOMAIN = 'b2live.example.test';
const created = { users: new Set(), homes: new Set(), devices: new Set() };
let seq = 0;
let ctxPromise = null;
/** Calistirmalar arasi cakismayan rastgele telefon (kismi UNIQUE indeks: uq_users_phone). */
const uniquePhone = () => `+905${crypto.randomInt(0, 1e9).toString().padStart(9, '0')}`;

function getCtx() {
  if (ctxPromise) return ctxPromise;
  ctxPromise = (async () => {
    process.env.DATABASE_URL = URL_; // src/db.js ayni veritabanini kullansin
    process.env.NODE_ENV = 'test';
    process.env.BCRYPT_TEST_COST = '4';
    process.env.AUTH_CACHE_TTL_MS = '0';
    process.env.JWT_SECRET = crypto.randomBytes(32).toString('hex');
    process.env.PIN_PEPPER = crypto.randomBytes(32).toString('hex');
    process.env.LOCAL_KEY_SECRET = crypto.randomBytes(32).toString('hex');
    process.env.MQTT_PUBLIC_HOST = 'broker.test.invalid';
    process.env.MQTT_PUBLIC_PORT = '8884';
    // server.js / db.js `dotenv.config()` calistirir ve yerel `.env`'deki (canli olabilir) EKSIK degiskenleri yukler:
    // delete yerine BOS dizge atanir (dotenv var olan anahtari ezmez) -> EMQX/SMTP/OAuth/API anahtari asla devreye girmez.
    for (const k of ['EMQX_API_URL', 'EMQX_API_KEY', 'EMQX_API_SECRET', 'ALLOW_DEBUG_OTP', 'ADMIN_API_KEY', 'SMTP_HOST', 'SMTP_USER', 'SMTP_PASSWORD', 'GOOGLE_CLIENT_IDS', 'APPLE_CLIENT_IDS', 'MQTT_BACKEND_USER', 'MQTT_BACKEND_PASS']) process.env[k] = '';
    console.warn = () => {}; // EMQX_API_* tanimsiz uyarilarini sustur
    console.log = () => {}; // src/db.js her sorguyu console.log'a yazar (NODE_ENV != production)

    const request = require('supertest');
    const bcrypt = require('bcryptjs');
    const db = require('../../src/db');
    const mailer = require('../../src/utils/mailer');
    const jwtConfig = require('../../src/middlewares/jwt_config');
    const credentials = require('../../src/services/mqtt_credential_service');
    const { createApp } = require('../../src/server');

    const mails = [];
    mailer.setTransportFactory(() => ({
      sendMail: async (msg) => {
        mails.push({ to: String(msg.to), subject: String(msg.subject), text: String(msg.text) });
      },
    }));

    const bridge = {
      isConnected: () => true,
      init() {},
      end: async () => {},
      publishCommand: async () => ({}),
      publishSys: async () => ({}),
      clearRetained: async () => {},
    };
    const app = createApp({ db, mqttBridge: bridge, pushService: { upsertToken: async () => {}, disableToken: async () => {} } });
    const q = (text, params) => db.query(text, params);

    const api = (method, url, token, body) => {
      let r = request(app)[method](url);
      if (token) r = r.set('Authorization', `Bearer ${token}`);
      if (body !== undefined && method !== 'get') r = r.send(body);
      return r;
    };

    const helpers = {
      async user({ role = 'user', email, phone = null, password = null, social = false, name = 'Test Kisi', status = 'active' } = {}) {
        const n = ++seq;
        const mail = email || `u${n}-${TAG}@${DOMAIN}`;
        const hash = await bcrypt.hash(password || crypto.randomBytes(16).toString('hex'), 4);
        const r = await q(
          `INSERT INTO users (email, password_hash, full_name, role, phone, is_active, account_status, password_changed_at, google_id)
           VALUES ($1, $2, $3, $4, $5, TRUE, $6, $7, $8)
           RETURNING id, email, role, token_version`,
          [mail, hash, name, role, phone, status, password ? new Date() : null, social ? `g-${TAG}-${n}` : null]
        );
        created.users.add(r.rows[0].id);
        const u = { ...r.rows[0], password, name, phone };
        u.token = jwtConfig.signAccessToken({ id: u.id, role: u.role, token_version: u.token_version });
        return u;
      },
      async home({ owner = null, name } = {}) {
        const n = ++seq;
        const r = await q(
          `INSERT INTO homes (name, mqtt_username) VALUES ($1, $2) RETURNING id, name, mqtt_username`,
          [name || `B2L-${TAG}-${n}`, `h_${crypto.randomBytes(8).toString('hex')}`]
        );
        created.homes.add(r.rows[0].id);
        if (owner) await q(`INSERT INTO home_users (home_id, user_id, role) VALUES ($1, $2, 'owner')`, [r.rows[0].id, owner.id]);
        return r.rows[0];
      },
      async member(home, user, role, extra = {}) {
        await q(
          `INSERT INTO home_users (home_id, user_id, role, installer_expires_at, valid_from, valid_until) VALUES ($1, $2, $3, $4, $5, $6)`,
          [home.id, user.id, role, extra.installerExpiresAt || null, extra.validFrom || null, extra.validUntil || null]
        );
      },
      async device(home, { online = false, commissioned = false } = {}) {
        const n = ++seq;
        const uuid = `AHBU-B2L${TAG.toUpperCase()}-${n}`;
        const mac = `E8:F6:${TAG.slice(0, 2)}:${TAG.slice(2, 4)}:${(n >> 8).toString(16).padStart(2, '0')}:${(n & 255).toString(16).padStart(2, '0')}`.toUpperCase();
        const r = await q(
          `INSERT INTO devices (home_id, device_uuid, mac_address, setup_pin, is_claimed, is_online, is_commissioned, commissioned_at, last_seen_at)
           VALUES ($1, $2, $3, NULL, TRUE, $4, $5, $6, NOW()) RETURNING id, device_uuid`,
          [home.id, uuid, mac, online, commissioned, commissioned ? new Date() : null]
        );
        await q(
          `INSERT INTO device_inventory (device_uuid, mac_address, pin_hash, status, claimed_home_id) VALUES ($1, $2, 'CLAIMED_BURNED_PIN', 'CLAIMED', $3)`,
          [uuid, mac, home.id]
        );
        created.devices.add(uuid);
        return r.rows[0];
      },
      one: async (text, params) => (await q(text, params)).rows[0],
      rows: async (text, params) => (await q(text, params)).rows,
      count: async (table, where, params) => (await q(`SELECT count(*)::int AS n FROM ${table} WHERE ${where}`, params)).rows[0].n,
      lastOtp(toEmail) {
        for (let i = mails.length - 1; i >= 0; i--) {
          if (mails[i].to === toEmail) {
            const m = /iletin: (\d{6})/.exec(mails[i].text);
            if (m) return m[1];
          }
        }
        return null;
      },
      mailsTo: (to) => mails.filter((m) => m.to === to),
    };

    return { request, bcrypt, db, q, app, api, bridge, mails, mailer, jwtConfig, credentials, helpers };
  })();
  return ctxPromise;
}

test.after(async () => {
  if (!ctxPromise) return;
  const c = await ctxPromise;
  try {
    const homes = [...created.homes];
    const users = [...created.users];
    const devices = [...created.devices];
    if (homes.length > 0) {
      await c.q('DELETE FROM device_audit_logs WHERE home_id = ANY ($1::uuid[])', [homes]);
      await c.q('DELETE FROM home_admin_assignment_logs WHERE home_id = ANY ($1::uuid[])', [homes]);
      await c.q('DELETE FROM homes WHERE id = ANY ($1::uuid[])', [homes]);
    }
    if (devices.length > 0) {
      await c.q('DELETE FROM device_audit_logs WHERE device_uuid = ANY ($1::text[])', [devices]);
      await c.q('DELETE FROM devices WHERE device_uuid = ANY ($1::text[])', [devices]);
      await c.q('DELETE FROM device_inventory WHERE device_uuid = ANY ($1::text[])', [devices]);
    }
    await c.q(`DELETE FROM device_inventory WHERE device_uuid LIKE $1`, [`AHBU-B2L${TAG.toUpperCase()}%`]);
    if (users.length > 0) {
      await c.q('DELETE FROM device_audit_logs WHERE actor_user_id = ANY ($1::uuid[])', [users]);
      await c.q('DELETE FROM home_admin_assignment_logs WHERE actor_user_id = ANY ($1::uuid[]) OR new_owner_id = ANY ($1::uuid[])', [users]);
      await c.q('DELETE FROM users WHERE id = ANY ($1::uuid[])', [users]);
    }
    // yeniden kayit testi: etiketli e-postalarla acilan hesaplar
    await c.q(`DELETE FROM users WHERE email LIKE $1`, [`%-${TAG}@${DOMAIN}`]);
  } catch (err) {
    console.error('[pg_live] temizlik hatasi (etiketli satirlar kalmis olabilir):', err.message);
  } finally {
    await c.db.pool.end().catch(() => {});
  }
});

const get = (c, url, token) => c.api('get', url, token);
const post = (c, url, token, body) => c.api('post', url, token, body === undefined ? {} : body);
const SUB = '/api/v1/service/subscribers';

// ================================================================================================
// Abone listesi
// ================================================================================================
test('PG abone listesi: staff yalniz KENDI (suresi dolmamis) evlerini gorur; super hepsini; arama ve sayfalama', { skip: SKIP }, async () => {
  const c = await getCtx();
  const h = c.helpers;
  const staff = await h.user({ role: 'service_user' });
  const staff2 = await h.user({ role: 'service_user' });
  const sup = await h.user({ role: 'super_user' });

  const ownerA = await h.user({ name: 'Ayse Sahip', phone: uniquePhone() });
  const ownerB = await h.user({ name: 'Bora Sahip' });
  const homeA = await h.home({ owner: ownerA, name: `B2L-${TAG}-Alfa Apt` });
  const homeB = await h.home({ owner: ownerB, name: `B2L-${TAG}-Beta Apt` });
  const homeC = await h.home({ name: `B2L-${TAG}-Gama Apt` }); // sahipsiz
  const homeExpired = await h.home({ owner: ownerB, name: `B2L-${TAG}-Suresi Dolmus` });
  await h.member(homeA, staff, 'service_user');
  await h.member(homeB, staff, 'service_user', { installerExpiresAt: new Date(Date.now() + 3600e3) });
  await h.member(homeExpired, staff, 'service_user', { installerExpiresAt: new Date(Date.now() - 3600e3) });
  await h.member(homeC, staff2, 'service_user');
  const devA1 = await h.device(homeA, { online: true, commissioned: true });
  await h.device(homeA, { online: false });
  await h.device(homeB, { online: false });

  // staff: A ve B (suresi dolmus ve baskasinin evi YOK)
  const r1 = await get(c, `${SUB}?q=${TAG}`, staff.token);
  assert.equal(r1.status, 200, JSON.stringify(r1.body));
  assert.equal(r1.headers['cache-control'], 'no-store');
  const names1 = r1.body.data.subscribers.map((s) => s.home_name).sort();
  assert.deepEqual(names1, [`B2L-${TAG}-Alfa Apt`, `B2L-${TAG}-Beta Apt`]);
  assert.equal(r1.body.data.total, 2);
  const alfa = r1.body.data.subscribers.find((s) => s.home_id === homeA.id);
  assert.equal(alfa.owner.full_name, 'Ayse Sahip');
  assert.equal(alfa.owner.email, ownerA.email);
  assert.equal(alfa.device_count, 2);
  assert.equal(alfa.online_count, 1);
  assert.equal(alfa.commissioned_count, 1);
  assert.ok(alfa.commissioned_at);
  assert.ok(alfa.last_seen_at);
  assert.ok(alfa.device_uuids.includes(devA1.device_uuid));

  // staff2: yalniz C (sahipsiz -> owner null)
  const r2 = await get(c, `${SUB}?q=${TAG}`, staff2.token);
  assert.deepEqual(r2.body.data.subscribers.map((s) => [s.home_name, s.owner]), [[`B2L-${TAG}-Gama Apt`, null]]);

  // super: etiketli dort evin hepsi
  const r3 = await get(c, `${SUB}?q=${TAG}&limit=100`, sup.token);
  assert.equal(r3.body.data.total, 4);

  // arama: ev adi, sahip adi, sahip e-postasi, cihaz UID, buyuk/kucuk harf duyarsiz
  const s1 = await get(c, `${SUB}?q=${encodeURIComponent(`alfa apt`)}`, sup.token);
  assert.ok(s1.body.data.subscribers.some((s) => s.home_id === homeA.id));
  const s2 = await get(c, `${SUB}?q=${encodeURIComponent('Bora Sahip')}`, sup.token);
  assert.ok(s2.body.data.subscribers.some((s) => s.home_id === homeB.id));
  const s3 = await get(c, `${SUB}?q=${encodeURIComponent(ownerA.email)}`, sup.token);
  assert.deepEqual(s3.body.data.subscribers.map((s) => s.home_id), [homeA.id]);
  const s4 = await get(c, `${SUB}?q=${encodeURIComponent(devA1.device_uuid)}`, sup.token);
  assert.deepEqual(s4.body.data.subscribers.map((s) => s.home_id), [homeA.id]);
  // LIKE joker karakterleri kacirilir: "%" her seyi eslestirmez
  const s5 = await get(c, `${SUB}?q=${encodeURIComponent('%')}`, sup.token);
  assert.equal(s5.body.data.total, 0);
  // SQL enjeksiyonu: arama degeri her zaman BAGLI parametredir (deyim yapisini degistiremez); tablolar yerinde
  for (const evil of ["' OR 1=1 --", "'; DROP TABLE homes; --", '\\', "%' OR h.id IS NOT NULL OR '%"]) {
    const inj = await get(c, `${SUB}?q=${encodeURIComponent(evil)}`, sup.token);
    assert.equal(inj.status, 200, evil);
    assert.equal(inj.body.data.total, 0, evil);
  }
  assert.ok((await h.one('SELECT count(*)::int AS n FROM homes')).n >= 4, 'homes tablosu yerinde');

  // sayfalama: limit=1 -> sirali ve tekrarsiz, total sabit
  const p1 = await get(c, `${SUB}?q=${TAG}&limit=1&offset=0`, sup.token);
  const p2 = await get(c, `${SUB}?q=${TAG}&limit=1&offset=1`, sup.token);
  const p4 = await get(c, `${SUB}?q=${TAG}&limit=1&offset=3`, sup.token);
  const p5 = await get(c, `${SUB}?q=${TAG}&limit=1&offset=4`, sup.token);
  assert.equal(p1.body.data.total, 4);
  assert.equal(p1.body.data.subscribers.length, 1);
  assert.notEqual(p1.body.data.subscribers[0].home_id, p2.body.data.subscribers[0].home_id);
  assert.equal(p4.body.data.subscribers.length, 1);
  assert.equal(p5.body.data.subscribers.length, 0);
});

test('PG abone listesi: yer tutucu e-posta (telefon/Apple hesabi) sizdirilmaz; yetkisiz roller 403', { skip: SKIP }, async () => {
  const c = await getCtx();
  const h = c.helpers;
  const sup = await h.user({ role: 'super_user' });
  const phoneOwner = await h.user({ email: `phone_${TAG}${++seq}@ahbu.local`, name: 'Telefon Sahip' });
  const home = await h.home({ owner: phoneOwner, name: `B2L-${TAG}-Telefonlu` });
  const r = await get(c, `${SUB}?q=${encodeURIComponent(`B2L-${TAG}-Telefonlu`)}`, sup.token);
  assert.equal(r.body.data.subscribers[0].owner.email, null);
  assert.equal(r.body.data.subscribers[0].owner.full_name, 'Telefon Sahip');

  const user = await h.user();
  const resident = await h.user();
  await h.member(home, resident, 'resident');
  for (const u of [user, resident, phoneOwner]) {
    const x = await get(c, SUB, u.token);
    assert.equal(x.status, 403, `${u.role}`);
  }
  assert.equal((await get(c, SUB)).status, 401);
  // servis (PIN) oturumu
  const sid = (await c.q(
    `INSERT INTO service_sessions (home_id, technician_name, expires_at) VALUES ($1, 'Usta', NOW() + interval '1 hour') RETURNING id`,
    [home.id]
  )).rows[0].id;
  const sessionToken = c.jwtConfig.signServiceSessionToken({ sid, home_id: home.id, expiresInSec: 3600 });
  assert.equal((await get(c, SUB, sessionToken)).status, 403);
});

// ================================================================================================
// Home Admin atama
// ================================================================================================
async function richHome(c, { ownerEmail } = {}) {
  const h = c.helpers;
  const owner = await h.user({ email: ownerEmail, name: 'Eski Sahip' });
  const resident = await h.user({ name: 'Aile Uyesi' });
  const staff = await h.user({ role: 'service_user' });
  const home = await h.home({ owner, name: `B2L-${TAG}-${++seq}` });
  await h.member(home, resident, 'resident');
  await h.member(home, staff, 'service_user', { installerExpiresAt: new Date(Date.now() + 72 * 3600e3) });
  const dev = await h.device(home, { online: true });
  await c.credentials.issueUserCredential({ homeId: home.id, userId: owner.id });
  await c.credentials.issueUserCredential({ homeId: home.id, userId: resident.id });
  const tok = await h.one(
    `INSERT INTO service_tokens (home_id, created_by, pin_hash, expires_at) VALUES ($1, $2, $3, NOW() + interval '2 hours') RETURNING id`,
    [home.id, owner.id, `h1$${crypto.randomBytes(32).toString('hex')}`]
  );
  const session = await h.one(
    `INSERT INTO service_sessions (home_id, service_token_id, technician_name, expires_at) VALUES ($1, $2, 'Usta', NOW() + interval '2 hours') RETURNING id`,
    [home.id, tok.id]
  );
  await c.q(
    `INSERT INTO home_invitations (home_id, created_by, invite_code, expires_at) VALUES ($1, $2, $3, NOW() + interval '1 day')`,
    [home.id, owner.id, crypto.randomBytes(5).toString('hex').toUpperCase()]
  );
  await c.q(
    `INSERT INTO scheduled_rules (home_id, device_id, channel, channel_type, action, hour, minute, created_by) VALUES ($1, $2, 5, 'relay', 'on', 8, 30, $3)`,
    [home.id, dev.id, owner.id]
  );
  await c.q(
    `INSERT INTO home_transfers (home_id, from_user_id, target_identifier, code_hash, expires_at) VALUES ($1, $2, 'baska@example.test', $3, NOW() + interval '1 day')`,
    [home.id, owner.id, crypto.randomBytes(32).toString('hex')]
  );
  const serviceToken = c.jwtConfig.signServiceSessionToken({ sid: session.id, home_id: home.id, expiresInSec: 3600 });
  return { owner, resident, staff, home, dev, session, serviceToken };
}

test('PG Home Admin atama: sahip OTP ile onaylar -> devir; eski sahibin erisimi/oturumlari/MQTT kimlikleri kesilir; denetim yazilir', { skip: SKIP }, async () => {
  const c = await getCtx();
  const h = c.helpers;
  const t = await richHome(c);
  const newcomerEmail = `yeni-${TAG}-${++seq}@${DOMAIN}`;
  const body = { full_name: 'Yeni Sahip', email: newcomerEmail };

  // on kosul: eski sahip eve erisebilir, servis oturumu gecerli
  assert.equal((await get(c, `/api/v1/homes/${t.home.id}/devices`, t.owner.token)).status, 200);
  assert.equal((await get(c, `/api/v1/homes/${t.home.id}/devices`, t.serviceToken)).status, 200);

  // OTP olmadan atama reddedilir
  const noOtp = await post(c, `${SUB}/${t.home.id}/assign-admin`, t.staff.token, body);
  assert.equal(noOtp.status, 400);
  assert.equal(noOtp.body.code, 'OWNER_CONSENT_REQUIRED');
  assert.equal(await h.count('home_users', `home_id = $1 AND role = 'owner' AND user_id = $2`, [t.home.id, t.owner.id]), 1);

  // sahibe kod gider (e-posta); yanitta kod YOK
  const req1 = await post(c, `${SUB}/${t.home.id}/assign-admin/request-otp`, t.staff.token, body);
  assert.equal(req1.status, 200, JSON.stringify(req1.body));
  assert.equal(req1.body.data.otp_required, true);
  assert.ok(!JSON.stringify(req1.body).match(/\b\d{6}\b/), 'yanitta kod gorunmemeli');
  const code = h.lastOtp(t.owner.email);
  assert.match(code, /^\d{6}$/);
  assert.ok(h.mailsTo(t.owner.email)[0].text.includes('Yeni Sahip'), 'e-posta kime devredildigini soyler');

  // yanlis kod: sayac ARTAR (commit-then-throw)
  const wrong = await post(c, `${SUB}/${t.home.id}/assign-admin`, t.staff.token, { ...body, otp_code: code === '000000' ? '111111' : '000000' });
  assert.equal(wrong.status, 400);
  assert.equal(wrong.body.remaining_attempts, 4);
  assert.equal((await h.one('SELECT attempts FROM home_admin_assign_otps WHERE home_id = $1', [t.home.id])).attempts, 1);
  assert.equal(await h.count('home_users', `home_id = $1 AND role = 'owner' AND user_id = $2`, [t.home.id, t.owner.id]), 1);

  // baska kisi icin istenmis kod baska hedefle KULLANILAMAZ
  const other = await post(c, `${SUB}/${t.home.id}/assign-admin`, t.staff.token, { full_name: 'Baska Biri', email: `baska-${TAG}-${++seq}@${DOMAIN}`, otp_code: code });
  assert.equal(other.status, 400);
  assert.equal(other.body.code, 'OWNER_CONSENT_REQUIRED');

  // dogru kod: devir
  const ok = await post(c, `${SUB}/${t.home.id}/assign-admin`, t.staff.token, { ...body, otp_code: code });
  assert.equal(ok.status, 200, JSON.stringify(ok.body));
  assert.equal(ok.body.data.mode, 'owner_consent');
  assert.equal(ok.body.data.account_created, true);
  assert.equal(ok.body.data.new_owner.account_status, 'pending_invite');
  assert.equal(ok.body.data.previous_owner_count, 1);
  assert.ok(ok.body.data.revoked.memberships >= 2, 'sahip + aile uyesi kaldirildi');

  const newcomer = await h.one('SELECT id, role, account_status, created_by_user_id FROM users WHERE LOWER(email) = $1', [newcomerEmail]);
  assert.equal(newcomer.account_status, 'pending_invite');
  assert.equal(newcomer.role, 'user');
  assert.equal(newcomer.created_by_user_id, t.staff.id);
  created.users.add(newcomer.id);

  // uyelikler: yeni TEK owner + islemi yapan staff'in servis uyeligi korunur; eski sahip/aile YOK
  const members = await h.rows('SELECT user_id, role FROM home_users WHERE home_id = $1 ORDER BY role', [t.home.id]);
  assert.deepEqual(members.map((m) => [m.user_id, m.role]).sort(), [[newcomer.id, 'owner'], [t.staff.id, 'service_user']].sort());

  // eski sahibin erisimi kesildi (HTTP 403), servis oturumu iptal (401)
  assert.equal((await get(c, `/api/v1/homes/${t.home.id}/devices`, t.owner.token)).status, 403);
  assert.equal((await get(c, `/api/v1/homes/${t.home.id}/devices`, t.resident.token)).status, 403);
  assert.equal((await get(c, `/api/v1/homes/${t.home.id}/devices`, t.serviceToken)).status, 401);
  // ... ama eski sahibin hesabi ve oturumlari duzeyi bozulmadi (baska evleri icin)
  assert.equal((await get(c, '/api/v1/homes', t.owner.token)).status, 200);

  // evin uygulama MQTT kimlikleri ve ACL'leri gitti; cihaz kimligine dokunulmadi
  assert.equal(await h.count('mqtt_credentials', `home_id = $1 AND kind = 'app'`, [t.home.id]), 0);
  // temizlik: davet, kural, bekleyen devir
  assert.equal(await h.count('home_invitations', 'home_id = $1', [t.home.id]), 0);
  assert.equal(await h.count('scheduled_rules', 'home_id = $1', [t.home.id]), 0);
  assert.equal(await h.count('home_transfers', `home_id = $1 AND status = 'PENDING'`, [t.home.id]), 0);
  assert.equal(await h.count('service_sessions', 'home_id = $1 AND revoked_at IS NULL', [t.home.id]), 0);
  // cihaz sahipligi yeni sahibe gecti; OTP satiri tuketildi
  assert.equal((await h.one('SELECT claimed_by FROM devices WHERE id = $1', [t.dev.id])).claimed_by, newcomer.id);
  assert.equal((await h.one('SELECT claimed_by_user_id FROM device_inventory WHERE device_uuid = $1', [t.dev.device_uuid])).claimed_by_user_id, newcomer.id);
  assert.equal(await h.count('home_admin_assign_otps', 'home_id = $1', [t.home.id]), 0);

  // ayni kod ikinci kez KULLANILAMAZ (tuketildi): ayni hedef artik tek sahip (409), baska hedef icin kod yok (400)
  const again = await post(c, `${SUB}/${t.home.id}/assign-admin`, t.staff.token, { ...body, otp_code: code });
  assert.equal(again.status, 409);
  const replayOther = await post(c, `${SUB}/${t.home.id}/assign-admin`, t.staff.token, { full_name: 'Baska Hedef', email: `baska2-${TAG}-${++seq}@${DOMAIN}`, otp_code: code });
  assert.equal(replayOther.status, 400);
  assert.equal(replayOther.body.code, 'OWNER_CONSENT_REQUIRED');

  // denetim kaydi (kod/parola yok)
  const log = await h.one('SELECT * FROM home_admin_assignment_logs WHERE home_id = $1', [t.home.id]);
  assert.equal(log.mode, 'owner_consent');
  assert.equal(log.actor_user_id, t.staff.id);
  assert.equal(log.actor_role, 'service_user');
  assert.deepEqual(log.previous_owner_ids, [t.owner.id]);
  assert.equal(log.new_owner_id, newcomer.id);
  assert.equal(log.account_created, true);
  assert.ok(!JSON.stringify(log).includes(code));
  // yeni sahibe hesap kurulum daveti gitti
  assert.ok(h.mailsTo(newcomerEmail).some((m) => /etkinle/i.test(m.subject)), 'davet e-postasi');
});

test('PG Home Admin atama: 5 yanlis kod -> kilit (429); yeniden istek sayaci SIFIRLAMAZ', { skip: SKIP }, async () => {
  const c = await getCtx();
  const h = c.helpers;
  const t = await richHome(c);
  const body = { full_name: 'Deneme Kisi', email: `deneme-${TAG}-${++seq}@${DOMAIN}` };
  assert.equal((await post(c, `${SUB}/${t.home.id}/assign-admin/request-otp`, t.staff.token, body)).status, 200);
  const code = h.lastOtp(t.owner.email);
  const wrong = code === '123456' ? '654321' : '123456';
  for (let i = 0; i < 5; i++) {
    const r = await post(c, `${SUB}/${t.home.id}/assign-admin`, t.staff.token, { ...body, otp_code: wrong });
    assert.equal(r.status, 400, `deneme ${i + 1}`);
  }
  const locked = await post(c, `${SUB}/${t.home.id}/assign-admin`, t.staff.token, { ...body, otp_code: code });
  assert.equal(locked.status, 429, 'dogru kod bile kilitliyken kabul EDILMEZ');
  assert.ok(Number(locked.headers['retry-after']) > 0);
  // 60 sn bekleme gecmeden yeniden istek 429; bekleme sonrasi da sayac pencere icinde korunur
  const resend = await post(c, `${SUB}/${t.home.id}/assign-admin/request-otp`, t.staff.token, body);
  assert.equal(resend.status, 429);
  await c.q(`UPDATE home_admin_assign_otps SET created_at = NOW() - interval '2 minutes' WHERE home_id = $1`, [t.home.id]);
  const resend2 = await post(c, `${SUB}/${t.home.id}/assign-admin/request-otp`, t.staff.token, body);
  assert.equal(resend2.status, 429, 'deneme sayaci yeniden istekle sifirlanmaz (15 dk pencere)');
  assert.equal((await h.one('SELECT attempts FROM home_admin_assign_otps WHERE home_id = $1', [t.home.id])).attempts, 5);
  assert.equal(await h.count('home_users', `home_id = $1 AND role = 'owner' AND user_id = $2`, [t.home.id, t.owner.id]), 1);
});

test('PG Home Admin atama: sahip yok -> kod gerekmez; pending_invite hesap + davet; uyeler korunur', { skip: SKIP }, async () => {
  const c = await getCtx();
  const h = c.helpers;
  const staff = await h.user({ role: 'service_user' });
  const resident = await h.user();
  const home = await h.home({ name: `B2L-${TAG}-${++seq}` });
  await h.member(home, staff, 'service_user');
  await h.member(home, resident, 'resident');
  const email = `sahipsiz-${TAG}-${++seq}@${DOMAIN}`;

  const rq = await post(c, `${SUB}/${home.id}/assign-admin/request-otp`, staff.token, { full_name: 'Ilk Admin', email });
  assert.equal(rq.status, 200);
  assert.equal(rq.body.data.otp_required, false);
  assert.equal(await h.count('home_admin_assign_otps', 'home_id = $1', [home.id]), 0);

  const r = await post(c, `${SUB}/${home.id}/assign-admin`, staff.token, { full_name: 'Ilk Admin', email });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.data.mode, 'no_owner');
  assert.equal(r.body.data.account_created, true);
  const u = await h.one('SELECT id, account_status FROM users WHERE LOWER(email) = $1', [email]);
  created.users.add(u.id);
  assert.equal(u.account_status, 'pending_invite');
  const members = await h.rows('SELECT user_id, role FROM home_users WHERE home_id = $1', [home.id]);
  assert.deepEqual(members.map((m) => `${m.user_id}:${m.role}`).sort(), [`${u.id}:owner`, `${resident.id}:resident`, `${staff.id}:service_user`].sort());
  assert.equal((await h.one('SELECT mode FROM home_admin_assignment_logs WHERE home_id = $1', [home.id])).mode, 'no_owner');

  // mevcut ETKIN hesap (yeni kod gerekmez, hesap yeniden olusturulmaz): ayni ev icin ikinci atama artik sahip VAR -> kod ister
  const second = await post(c, `${SUB}/${home.id}/assign-admin`, staff.token, { full_name: 'Ikinci', email: `ikinci-${TAG}-${++seq}@${DOMAIN}` });
  assert.equal(second.status, 400);
  assert.equal(second.body.code, 'OWNER_CONSENT_REQUIRED');
});

test('PG Home Admin atama: sahibe ulasilamiyor -> yalniz super ZORLAYABILIR (gerekce >= 15, denetim kaydi)', { skip: SKIP }, async () => {
  const c = await getCtx();
  const h = c.helpers;
  const sup = await h.user({ role: 'super_user' });
  const t = await richHome(c, { ownerEmail: `phone_${TAG}${++seq}@ahbu.local` });
  const target = await h.user({ name: 'Zorla Hedef' });
  const body = { full_name: 'Zorla Hedef', email: target.email };

  // yer tutucu e-posta -> OTP gonderilemez
  const rq = await post(c, `${SUB}/${t.home.id}/assign-admin/request-otp`, t.staff.token, body);
  assert.equal(rq.status, 409);
  assert.equal(rq.body.code, 'OWNER_UNREACHABLE');

  // staff zorlayamaz
  const staffForce = await post(c, `${SUB}/${t.home.id}/assign-admin`, t.staff.token, { ...body, force: true, reason: 'Ev sahibine ulasilamiyor, yerinde teslim' });
  assert.equal(staffForce.status, 403);

  // super: gerekce zorunlu
  const noReason = await post(c, `${SUB}/${t.home.id}/assign-admin`, sup.token, { ...body, force: true, reason: 'kisa' });
  assert.equal(noReason.status, 400);

  const forced = await post(c, `${SUB}/${t.home.id}/assign-admin`, sup.token, { ...body, force: true, reason: 'Ev sahibine ulasilamiyor, yerinde teslim alindi' });
  assert.equal(forced.status, 200, JSON.stringify(forced.body));
  assert.equal(forced.body.data.mode, 'forced');
  assert.equal(forced.body.data.account_created, false);
  const owners = await h.rows(`SELECT user_id FROM home_users WHERE home_id = $1 AND role = 'owner'`, [t.home.id]);
  assert.deepEqual(owners.map((o) => o.user_id), [target.id]);
  const log = await h.one('SELECT * FROM home_admin_assignment_logs WHERE home_id = $1', [t.home.id]);
  assert.equal(log.mode, 'forced');
  assert.equal(log.actor_role, 'super_user');
  assert.match(log.reason, /yerinde teslim/);
  assert.equal((await get(c, `/api/v1/homes/${t.home.id}/devices`, t.owner.token)).status, 403);
  // mevcut ETKIN hesaba bilgilendirme e-postasi gitti
  assert.ok(h.mailsTo(target.email).some((m) => /yetkisi verildi/i.test(m.subject)));
});

test('PG Home Admin atama: kapsam/yetki matrisi (staff baska ev, suresi dolmus servis, owner, resident, misafir, servis oturumu)', { skip: SKIP }, async () => {
  const c = await getCtx();
  const h = c.helpers;
  const t = await richHome(c);
  const body = { full_name: 'Hedef Kisi', email: `hedef-${TAG}-${++seq}@${DOMAIN}`, otp_code: '123456' };
  const guest = await h.user();
  await h.member(t.home, guest, 'guest', { validFrom: new Date(Date.now() - 3600e3), validUntil: new Date(Date.now() + 3600e3) });
  const otherStaff = await h.user({ role: 'service_user' });
  const expiredStaff = await h.user({ role: 'service_user' });
  await h.member(t.home, expiredStaff, 'service_user', { installerExpiresAt: new Date(Date.now() - 3600e3) });

  const cases = [
    ['owner', t.owner.token, 403],
    ['resident', t.resident.token, 403],
    ['misafir', guest.token, 403],
    ['staff (baska ev)', otherStaff.token, 403],
    ['staff (suresi dolmus uyelik)', expiredStaff.token, 403],
    ['servis oturumu', t.serviceToken, 403],
    ['kimliksiz', null, 401],
  ];
  for (const url of [`${SUB}/${t.home.id}/assign-admin`, `${SUB}/${t.home.id}/assign-admin/request-otp`]) {
    for (const [label, token, status] of cases) {
      const r = await post(c, url, token, body);
      assert.equal(r.status, status, `${label} -> ${url}: ${JSON.stringify(r.body)}`);
    }
  }
  assert.equal(await h.count('home_users', `home_id = $1 AND role = 'owner' AND user_id = $2`, [t.home.id, t.owner.id]), 1);
  assert.equal(await h.count('home_admin_assignment_logs', 'home_id = $1', [t.home.id]), 0);
});

test('PG Home Admin atama: hedef kisitlari (kendini atayamaz, servis/super hesabi olamaz, pasif hesap, telefon-ile-yeni-hesap yok)', { skip: SKIP }, async () => {
  const c = await getCtx();
  const h = c.helpers;
  const sup = await h.user({ role: 'super_user' });
  const t = await richHome(c);
  const url = `${SUB}/${t.home.id}/assign-admin`;
  // OTP sartinin onune gecmek icin zorla (super) yolu; hedef kontrolleri moddan bagimsizdir
  const force = (b) => ({ ...b, force: true, reason: 'Hedef kisitlari testi gerekcesi yeterince uzun' });

  const self = await post(c, url, sup.token, force({ full_name: 'Kendim', email: sup.email }));
  assert.equal(self.status, 403);
  const staffTarget = await post(c, url, sup.token, force({ full_name: 'Baska Servis', email: t.staff.email }));
  assert.equal(staffTarget.status, 403);
  const frozen = await h.user({ status: 'suspended' });
  const frozenRes = await post(c, url, sup.token, force({ full_name: 'Donmus', email: frozen.email }));
  assert.equal(frozenRes.status, 409);
  const sameOwner = await post(c, url, sup.token, force({ full_name: 'Eski Sahip', email: t.owner.email }));
  assert.equal(sameOwner.status, 409, 'hedef zaten tek sahip');
  const placeholder = await post(c, url, sup.token, force({ full_name: 'Yer Tutucu', email: 'phone_905550000000@ahbu.local' }));
  assert.equal(placeholder.status, 400, 'teslim edilemeyen yer tutucu adres hesap adresi olamaz');
  const phoneOnly = await post(c, url, sup.token, force({ full_name: 'Telefon Kisi', phone: '+905551230000' }));
  assert.equal(phoneOnly.status, 400);
  const invalid = await post(c, url, sup.token, force({ full_name: 'X', email: 'gecersiz' }));
  assert.equal(invalid.status, 400);
  assert.equal(await h.count('home_users', `home_id = $1 AND role = 'owner' AND user_id = $2`, [t.home.id, t.owner.id]), 1);

  // telefonla MEVCUT hesap bulunur
  const phone = uniquePhone();
  const byPhone = await h.user({ phone, name: 'Telefonlu Hesap' });
  const okPhone = await post(c, url, sup.token, force({ full_name: 'Telefonlu Hesap', phone }));
  assert.equal(okPhone.status, 200, JSON.stringify(okPhone.body));
  assert.equal(okPhone.body.data.new_owner.id, byPhone.id);
});

test('PG Home Admin atama: ATOMIK - devir ortasinda hata olursa hicbir degisiklik kalmaz (OTP de tuketilmez)', { skip: SKIP }, async () => {
  const c = await getCtx();
  const h = c.helpers;
  const { ServicePanelService } = require('../../src/services/service_panel_service');
  const t = await richHome(c);
  const body = { full_name: 'Atomik Hedef', email: `atomik-${TAG}-${++seq}@${DOMAIN}` };
  assert.equal((await post(c, `${SUB}/${t.home.id}/assign-admin/request-otp`, t.staff.token, body)).status, 200);
  const code = h.lastOtp(t.owner.email);

  // MQTT kimlik iptali (devrin SON adimlarindan biri) patlar -> tum islem geri alinmali
  const broken = new ServicePanelService({
    mqtt: { revokeHomeAccess: async () => { throw new Error('beklenen test hatasi'); }, kickUsernames: async () => ({}) },
  });
  const actor = { userId: t.staff.id, globalRole: 'service_user', ip: '127.0.0.1' };
  await assert.rejects(
    broken.assignAdmin({ actor, homeId: t.home.id, target: { fullName: body.full_name, email: body.email }, otpCode: code }),
    /beklenen test hatasi/
  );
  assert.equal(await h.count('users', 'LOWER(email) = $1', [body.email]), 0, 'olusturulan hesap geri alindi');
  assert.equal(await h.count('home_users', `home_id = $1 AND role = 'owner' AND user_id = $2`, [t.home.id, t.owner.id]), 1);
  assert.equal(await h.count('home_users', 'home_id = $1', [t.home.id]), 3, 'uyelikler korundu');
  assert.equal(await h.count('mqtt_credentials', `home_id = $1 AND kind = 'app'`, [t.home.id]), 2);
  assert.equal(await h.count('home_invitations', 'home_id = $1', [t.home.id]), 1);
  assert.equal(await h.count('service_sessions', 'home_id = $1 AND revoked_at IS NULL', [t.home.id]), 1);
  assert.equal(await h.count('home_admin_assignment_logs', 'home_id = $1', [t.home.id]), 0);
  assert.equal(await h.count('home_admin_assign_otps', 'home_id = $1', [t.home.id]), 1, 'OTP tuketilmedi');
  // ayni kodla dogru servis simdi basarili olur
  const ok = await post(c, `${SUB}/${t.home.id}/assign-admin`, t.staff.token, { ...body, otp_code: code });
  assert.equal(ok.status, 200, JSON.stringify(ok.body));
  const u = await h.one('SELECT id FROM users WHERE LOWER(email) = $1', [body.email]);
  created.users.add(u.id);
});

test('PG Home Admin atama: iki es zamanli atama -> yalniz biri kazanir (ev satiri kilidi + tek kullanimlik OTP)', { skip: SKIP }, async () => {
  const c = await getCtx();
  const h = c.helpers;
  const t = await richHome(c);
  const body = { full_name: 'Yaris Hedef', email: `yaris-${TAG}-${++seq}@${DOMAIN}` };
  assert.equal((await post(c, `${SUB}/${t.home.id}/assign-admin/request-otp`, t.staff.token, body)).status, 200);
  const code = h.lastOtp(t.owner.email);
  const results = await Promise.all([0, 1, 2].map(() => post(c, `${SUB}/${t.home.id}/assign-admin`, t.staff.token, { ...body, otp_code: code })));
  const statuses = results.map((r) => r.status).sort();
  assert.deepEqual(statuses.filter((s) => s === 200), [200], `tam bir basari bekleniyordu: ${JSON.stringify(results.map((r) => [r.status, r.body.code]))}`);
  assert.equal(await h.count('home_admin_assignment_logs', 'home_id = $1', [t.home.id]), 1);
  assert.equal(await h.count('home_users', `home_id = $1 AND role = 'owner'`, [t.home.id]), 1);
  const u = await h.one('SELECT id FROM users WHERE LOWER(email) = $1', [body.email]);
  created.users.add(u.id);
});

// ================================================================================================
// Hesap silme
// ================================================================================================
const PASSWORD = 'Sifre-Test-12345';

test('PG hesap silme: sifre ile -> anonimlestirme, oturumlar/MQTT/push/uyelikler iptal, ESKI E-POSTA SERBEST (yeniden kayit)', { skip: SKIP }, async () => {
  const c = await getCtx();
  const h = c.helpers;
  const email = `silinecek-${TAG}-${++seq}@${DOMAIN}`;
  const user = await h.user({ email, password: PASSWORD, phone: uniquePhone(), name: 'Silinecek Kisi' });

  // gercek giris -> refresh token
  const login = await post(c, '/api/v1/auth/login', null, { identifier: email, password: PASSWORD });
  assert.equal(login.status, 200, JSON.stringify(login.body));
  const refresh = login.body.data.refresh_token;
  const access = login.body.data.access_token;

  // baska evde RESIDENT (sahibi degil) + MQTT kimligi + push token + zamanli kural/davet
  const otherOwner = await h.user();
  const home = await h.home({ owner: otherOwner, name: `B2L-${TAG}-${++seq}` });
  await h.member(home, user, 'resident');
  await c.credentials.issueUserCredential({ homeId: home.id, userId: user.id });
  await c.q(`INSERT INTO push_tokens (user_id, token, platform) VALUES ($1, $2, 'android')`, [user.id, `tok-${TAG}-${seq}-${'x'.repeat(24)}`]);
  await c.q(
    `INSERT INTO password_resets (user_id, identifier, code_hash, token_hash, expires_at) VALUES ($1, $2, 'h1$x', $3, NOW() + interval '1 hour')`,
    [user.id, email, crypto.randomBytes(16).toString('hex')]
  );

  // yanlis sifre / eksik sifre
  const bad = await c.api('delete', '/api/v1/auth/account', access, { password: 'yanlis-sifre-123' });
  assert.equal(bad.status, 400);
  assert.equal(bad.body.code, 'INVALID_CREDENTIALS');
  const missing = await c.api('delete', '/api/v1/auth/account', access, { confirm: 'SİL' });
  assert.equal(missing.status, 403);
  assert.equal(missing.body.code, 'REAUTH_REQUIRED');
  assert.equal((await h.one('SELECT account_status FROM users WHERE id = $1', [user.id])).account_status, 'active');

  const del = await c.api('delete', '/api/v1/auth/account', access, { password: PASSWORD });
  assert.equal(del.status, 200, JSON.stringify(del.body));
  assert.equal(del.body.data.deleted, true);
  assert.equal(del.body.data.released_memberships, 1);

  // anonimlestirme
  const row = await h.one('SELECT * FROM users WHERE id = $1', [user.id]);
  assert.equal(row.account_status, 'deleted');
  assert.equal(row.is_active, false);
  assert.ok(row.deleted_at);
  assert.equal(row.email, `deleted+${user.id}@deleted.invalid`);
  assert.equal(row.phone, null);
  assert.equal(row.google_id, null);
  assert.equal(row.full_name, 'Silinmiş Kullanıcı');
  assert.ok(!row.password_hash.startsWith('$2'), 'parola ozeti kullanilamaz');
  // iptaller
  assert.equal(await h.count('home_users', 'user_id = $1', [user.id]), 0);
  assert.equal(await h.count('mqtt_credentials', 'user_id = $1', [user.id]), 0);
  assert.equal(await h.count('refresh_tokens', 'user_id = $1', [user.id]), 0);
  assert.equal(await h.count('push_tokens', 'user_id = $1', [user.id]), 0);
  assert.equal(await h.count('password_resets', 'user_id = $1', [user.id]), 0);
  // eski access token ve refresh token ARTIK GECERSIZ
  assert.equal((await get(c, '/api/v1/homes', access)).status, 401);
  const refreshed = await post(c, '/api/v1/auth/refresh', null, { refresh_token: refresh });
  assert.equal(refreshed.status, 401);
  // eski kimlikle giris artik mumkun degil
  const relogin = await post(c, '/api/v1/auth/login', null, { identifier: email, password: PASSWORD });
  assert.equal(relogin.status, 401);
  // denetim kaydi (kisisel veri yok)
  const audit = await h.one(`SELECT * FROM device_audit_logs WHERE event = 'account_deleted' AND actor_user_id = $1`, [user.id]);
  assert.ok(audit);
  assert.ok(!JSON.stringify(audit).includes(email));

  // AYNI E-POSTAYLA YENIDEN KAYIT mumkun ve yeni hesap temiz
  const reg = await post(c, '/api/v1/auth/register', null, { full_name: 'Yeniden Kayit', email, password: PASSWORD });
  assert.equal(reg.status, 201, JSON.stringify(reg.body));
  assert.notEqual(reg.body.data.user.id, user.id);
  assert.deepEqual(reg.body.data.homes, []);
  created.users.add(reg.body.data.user.id);
  // ... ve ayni telefonla da
  const reg2 = await post(c, '/api/v1/auth/register', null, { full_name: 'Telefon Yeniden', email: `ikinci-${TAG}-${++seq}@${DOMAIN}`, password: PASSWORD, phone: user.phone || '+905559990000' });
  created.users.add(reg2.body.data && reg2.body.data.user && reg2.body.data.user.id);
  assert.equal(reg2.status, 201, JSON.stringify(reg2.body));
});

test('PG hesap silme: SOLE_OWNER 409 + ev listesi (devir sonrasi basarili); co-owner varsa engel yok', { skip: SKIP }, async () => {
  const c = await getCtx();
  const h = c.helpers;
  const owner = await h.user({ password: PASSWORD });
  const alone = await h.home({ owner, name: `B2L-${TAG}-Yalniz ${++seq}` });
  const shared = await h.home({ owner, name: `B2L-${TAG}-Ortak ${++seq}` });
  const coOwner = await h.user();
  await h.member(shared, coOwner, 'owner'); // ortak sahip: bu ev engel DEGIL
  const tenant = await h.user();
  await h.member(alone, tenant, 'resident');
  await h.device(alone);

  const r = await c.api('delete', '/api/v1/auth/account', owner.token, { password: PASSWORD });
  assert.equal(r.status, 409, JSON.stringify(r.body));
  assert.equal(r.body.code, 'SOLE_OWNER');
  assert.deepEqual(r.body.homes.map((x) => x.id), [alone.id]);
  assert.equal(r.body.homes[0].other_member_count, 1);
  assert.equal(r.body.homes[0].device_count, 1);
  assert.equal((await h.one('SELECT account_status FROM users WHERE id = $1', [owner.id])).account_status, 'active');
  assert.equal(await h.count('home_users', 'user_id = $1', [owner.id]), 2, 'hicbir uyelik silinmedi');

  // devir: sahipligi baska kullaniciya gecir (devir mekanizmasi: kod + kabul)
  await c.q(`DELETE FROM home_users WHERE home_id = $1 AND user_id = $2`, [alone.id, owner.id]);
  await c.q(`INSERT INTO home_users (home_id, user_id, role) VALUES ($1, $2, 'owner') ON CONFLICT DO NOTHING`, [alone.id, tenant.id]);
  const ok = await c.api('delete', '/api/v1/auth/account', owner.token, { password: PASSWORD });
  assert.equal(ok.status, 200, JSON.stringify(ok.body));
  // ortak ev: co-owner KALDI
  assert.deepEqual((await h.rows(`SELECT user_id FROM home_users WHERE home_id = $1 AND role = 'owner'`, [shared.id])).map((x) => x.user_id), [coOwner.id]);
});

test('PG hesap silme: sosyal/sifresiz hesap "SİL" ile; staff ve super bu uctan silemez (403)', { skip: SKIP }, async () => {
  const c = await getCtx();
  const h = c.helpers;
  const social = await h.user({ social: true, name: 'Google Kisi' });
  const noConfirm = await c.api('delete', '/api/v1/auth/account', social.token, {});
  assert.equal(noConfirm.status, 400);
  const wrongWord = await c.api('delete', '/api/v1/auth/account', social.token, { confirm: 'evet' });
  assert.equal(wrongWord.status, 400);
  const ok = await c.api('delete', '/api/v1/auth/account', social.token, { confirm: 'sil' }); // Turkce buyuk/kucuk harf duyarsiz
  assert.equal(ok.status, 200, JSON.stringify(ok.body));
  const row = await h.one('SELECT account_status, google_id FROM users WHERE id = $1', [social.id]);
  assert.deepEqual([row.account_status, row.google_id], ['deleted', null]);

  for (const role of ['service_user', 'super_user']) {
    const u = await h.user({ role, password: PASSWORD });
    const r = await c.api('delete', '/api/v1/auth/account', u.token, { password: PASSWORD });
    assert.equal(r.status, 403, role);
    assert.equal((await h.one('SELECT account_status FROM users WHERE id = $1', [u.id])).account_status, 'active');
  }
  // sifreli hesap yalniz "SİL" yazarak silemez (parolasiz silinemez)
  const pw = await h.user({ password: PASSWORD });
  const r = await c.api('delete', '/api/v1/auth/account', pw.token, { confirm: 'SİL' });
  assert.equal(r.status, 403);
  assert.equal(r.body.code, 'REAUTH_REQUIRED');
  assert.equal((await c.api('delete', '/api/v1/auth/account', null, { password: PASSWORD })).status, 401);
});

// ================================================================================================
// Etiket yeniden uretimi
// ================================================================================================
test('PG etiket yeniden uretimi: yalniz super; IN_STOCK; eski PIN gecersiz, yeni PIN ile sahiplenilir; denetim', { skip: SKIP }, async () => {
  const c = await getCtx();
  const h = c.helpers;
  const sup = await h.user({ role: 'super_user' });
  const staff = await h.user({ role: 'service_user' });
  const normal = await h.user();
  const uuid = `AHBU-B2L${TAG.toUpperCase()}-${++seq}`;
  created.devices.add(uuid);
  const reg = await post(c, '/api/v1/admin/inventory/register', sup.token, { device_uuid: uuid, mac_address: `E8:F6:${TAG.slice(0, 2)}:${TAG.slice(2, 4)}:A0:01`, pin: '111111' });
  assert.equal(reg.status, 201, JSON.stringify(reg.body));
  const oldKeyEnc = (await h.one('SELECT local_key_enc FROM device_inventory WHERE device_uuid = $1', [uuid])).local_key_enc;

  // yetki: staff / normal / API anahtari / kimliksiz
  for (const [label, token, status] of [['staff', staff.token, 403], ['normal', normal.token, 403], ['kimliksiz', null, 401]]) {
    const r = await post(c, `/api/v1/admin/inventory/${uuid}/reissue-label`, token, {});
    assert.equal(r.status, status, label);
  }
  const apiKeyAttempt = await c.request(c.app).post(`/api/v1/admin/inventory/${uuid}/reissue-label`).set('X-Admin-Api-Key', 'x'.repeat(40)).send({});
  assert.equal(apiKeyAttempt.status, 401, 'API anahtari ile yeniden uretim YOK');

  const r = await post(c, `/api/v1/admin/inventory/${uuid}/reissue-label`, sup.token, {});
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.headers['cache-control'], 'no-store');
  const { setup_pin: newPin, local_key: newKey, qr_claim_url: url, device } = r.body.data;
  assert.match(newPin, /^\d{6}$/);
  assert.match(newKey, /^[\x21-\x7E]{8,32}$/);
  assert.ok(url.includes(`uid=${uuid}`) && url.includes(`pin=${newPin}`));
  assert.equal(device.label_reissue_count, 1);
  assert.notEqual(newPin, '111111');
  // anahtar sifreli saklandi ve degisti
  const inv = await h.one('SELECT * FROM device_inventory WHERE device_uuid = $1', [uuid]);
  assert.notEqual(inv.local_key_enc, oldKeyEnc);
  assert.equal(require('../../src/utils/secret_box').decrypt(inv.local_key_enc), newKey);
  assert.ok(!JSON.stringify(inv).includes(newPin) && !JSON.stringify(inv).includes(newKey), 'duz metin saklanmadi');
  // denetim: PIN/anahtar degeri yok
  const audit = await h.one(`SELECT * FROM device_audit_logs WHERE event = 'inventory_label_reissued' AND device_uuid = $1`, [uuid]);
  assert.equal(audit.actor_user_id, sup.id);
  assert.ok(!JSON.stringify(audit).includes(newPin) && !JSON.stringify(audit).includes(newKey));

  // ESKI PIN artik gecersiz; YENI PIN ile sahiplenilir
  const oldClaim = await post(c, '/api/v1/devices/claim', normal.token, { device_uuid: uuid, setup_pin: '111111' });
  assert.equal(oldClaim.status, 403, JSON.stringify(oldClaim.body));
  const newClaim = await post(c, '/api/v1/devices/claim', normal.token, { device_uuid: uuid, setup_pin: newPin });
  assert.equal(newClaim.status, 200, JSON.stringify(newClaim.body));
  created.homes.add(newClaim.body.data.home_id);
  // sahiplenilen cihaza etiket yeniden uretilemez
  const claimedRe = await post(c, `/api/v1/admin/inventory/${uuid}/reissue-label`, sup.token, {});
  assert.equal(claimedRe.status, 409);
  // yerel anahtar yeniden uretilen anahtardir (envanter anahtari sahiplenmede korunur)
  const dev = await h.one('SELECT local_key_enc FROM devices WHERE device_uuid = $1', [uuid]);
  assert.equal(require('../../src/utils/secret_box').decrypt(dev.local_key_enc), newKey);
  // bilinmeyen cihaz 404, gecersiz kimlik 400
  assert.equal((await post(c, '/api/v1/admin/inventory/AHBU-YOKTUR-999/reissue-label', sup.token, {})).status, 404);
  assert.equal((await post(c, '/api/v1/admin/inventory/gecersiz/reissue-label', sup.token, {})).status, 400);
});

test('PG etiket yeniden uretimi: IN_STOCK degilse (SUSPENDED/REVOKED) 409; kilitli cihazin kilidi ve sayaci sifirlanir', { skip: SKIP }, async () => {
  const c = await getCtx();
  const h = c.helpers;
  const sup = await h.user({ role: 'super_user' });
  const uuid = `AHBU-B2L${TAG.toUpperCase()}-${++seq}`;
  created.devices.add(uuid);
  await c.q(
    `INSERT INTO device_inventory (device_uuid, mac_address, pin_hash, status, failed_attempts, locked_until)
     VALUES ($1, $2, 'h1$x', 'IN_STOCK', 5, NOW() + interval '15 minutes')`,
    [uuid, `E8:F6:${TAG.slice(0, 2)}:${TAG.slice(2, 4)}:B0:02`]
  );
  for (const status of ['SUSPENDED', 'REVOKED']) {
    await c.q('UPDATE device_inventory SET status = $2 WHERE device_uuid = $1', [uuid, status]);
    const r = await post(c, `/api/v1/admin/inventory/${uuid}/reissue-label`, sup.token, {});
    assert.equal(r.status, 409, status);
  }
  await c.q(`UPDATE device_inventory SET status = 'IN_STOCK' WHERE device_uuid = $1`, [uuid]);
  const ok = await post(c, `/api/v1/admin/inventory/${uuid}/reissue-label`, sup.token, {});
  assert.equal(ok.status, 200, JSON.stringify(ok.body));
  const inv = await h.one('SELECT failed_attempts, locked_until, label_reissue_count FROM device_inventory WHERE device_uuid = $1', [uuid]);
  assert.deepEqual([inv.failed_attempts, inv.locked_until, inv.label_reissue_count], [0, null, 1]);
  const again = await post(c, `/api/v1/admin/inventory/${uuid}/reissue-label`, sup.token, {});
  assert.equal(again.body.data.device.label_reissue_count, 2);
  assert.notEqual(again.body.data.setup_pin + again.body.data.local_key, ok.body.data.setup_pin + ok.body.data.local_key);
});

// ================================================================================================
// Davet / devir kodu onizleme (join-preview) - gercek davet/devir akisiyla
// ================================================================================================
test('PG join-preview: davet onizleme kodu TUKETMEZ (sonra katilim calisir, kullanilmis kod 410); devir onizleme yalniz HEDEF hesaba', { skip: SKIP }, async () => {
  const c = await getCtx();
  const h = c.helpers;
  const owner = await h.user({ name: 'Onizleme Sahip' });
  const home = await h.home({ owner, name: `B2L-${TAG}-Onizleme ${++seq}` });
  const member = await h.user();
  await h.member(home, member, 'resident');
  const joiner = await h.user();

  // davet: gercek rota ile uret
  const inv = await post(c, `/api/v1/homes/${home.id}/invitations`, owner.token, { role: 'resident' });
  assert.equal(inv.status, 201, JSON.stringify(inv.body));
  const code = inv.body.data.code;
  const p1 = await post(c, '/api/v1/homes/join-preview', joiner.token, { code });
  assert.equal(p1.status, 200, JSON.stringify(p1.body));
  assert.equal(p1.body.data.kind, 'invitation');
  assert.equal(p1.body.data.home_name, home.name);
  assert.equal(p1.body.data.resident_count, 2, 'owner + resident');
  assert.equal(p1.body.data.role, 'resident');
  assert.equal(p1.body.data.already_member, false);
  // onizleme kodu tuketmedi: ikinci onizleme + gercek katilim calisir
  assert.equal((await post(c, '/api/v1/homes/join-preview', joiner.token, { code })).status, 200);
  assert.equal((await post(c, '/api/v1/homes/join', joiner.token, { code })).status, 200);
  // artik kullanilmis kod: 410 GONE (onizleme de)
  const p2 = await post(c, '/api/v1/homes/join-preview', (await h.user()).token, { code });
  assert.equal(p2.status, 410);
  assert.equal(p2.body.code, 'GONE');
  // zaten uye olan icin already_member
  const inv2 = await post(c, `/api/v1/homes/${home.id}/invitations`, owner.token, { role: 'resident' });
  const p3 = await post(c, '/api/v1/homes/join-preview', joiner.token, { code: inv2.body.data.code });
  assert.equal(p3.body.data.already_member, true);

  // devir: hedef e-posta ile uret; yalniz hedef onizler
  const target = await h.user({ name: 'Devir Hedef' });
  const stranger = await h.user();
  const tr = await post(c, `/api/v1/homes/${home.id}/transfer-initiate`, owner.token, { target_identifier: target.email });
  assert.equal(tr.status, 201, JSON.stringify(tr.body));
  const trCode = tr.body.data.code;
  const t1 = await post(c, '/api/v1/homes/join-preview', target.token, { code: trCode });
  assert.equal(t1.status, 200, JSON.stringify(t1.body));
  assert.deepEqual([t1.body.data.kind, t1.body.data.is_transfer, t1.body.data.role, t1.body.data.home_name], ['transfer', true, 'owner', home.name]);
  assert.ok(!JSON.stringify(t1.body).includes(target.email));
  const t2 = await post(c, '/api/v1/homes/join-preview', stranger.token, { code: trCode });
  assert.equal(t2.status, 403);
  assert.ok(!JSON.stringify(t2.body).includes(home.name));
  const own = await post(c, '/api/v1/homes/join-preview', owner.token, { code: trCode });
  assert.equal(own.status, 400);
  // devir onizleme tuketmedi: kabul calisir
  assert.equal((await post(c, '/api/v1/homes/transfer-accept', target.token, { code: trCode })).status, 200);
  assert.equal((await post(c, '/api/v1/homes/join-preview', target.token, { code: trCode })).status, 410);
  // bilinmeyen kodlar
  assert.equal((await post(c, '/api/v1/homes/join-preview', target.token, { code: 'AHBU-ABCDEFGHJK' })).status, 410);
  assert.equal((await post(c, '/api/v1/homes/join-preview', target.token, { code: 'AHBU-TR-ABCDEFGHJKMNPQRS' })).status, 410);
  assert.equal((await post(c, '/api/v1/homes/join-preview', null, { code })).status, 401);
});
