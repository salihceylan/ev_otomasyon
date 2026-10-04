'use strict';

// Uyelik/kimlik duzeltmeleri - GERCEK PostgreSQL entegrasyon testleri (UYELIK-02/03/07/08/K1).
//
// Varsayilan olarak ATLANIR (`npm test` PostgreSQL gerektirmez). Etkinlestirmek icin TAMAMEN migration'lanmis bir
// TEST veritabani verin:
//   DATABASE_URL=<hedef> MIGRATE_CONFIRM=<db> node scripts/migrate.js
//   EV_PG_TEST_URL=postgresql://kullanici@127.0.0.1:5432/<db> node --test test/auth/uyelik_pg.test.js
// UYGULAMA VERITABANINA (uretim/canli) KARSI CALISTIRMAYIN: etiketli kullanici/ev/cihaz satirlari olusturur ve siler.
//
// Gercek uygulama (createApp) + gercek servisler + gercek SQL; yalniz MQTT koprusu, e-posta tasiyicisi ve SMS
// gonderici sahtedir. EMQX REST tanimsiz (kick atlanir): DB'den silme kanitlanir.

const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');

const URL_ = process.env.EV_PG_TEST_URL;
const SKIP = URL_ ? false : 'EV_PG_TEST_URL tanimli degil (gercek PostgreSQL gerekir)';

const TAG = crypto.randomBytes(3).toString('hex');
const DOMAIN = 'uyelikpg.example.test';
const PASSWORD = 'Uyelik-Parola-2026';
const created = { users: new Set(), homes: new Set(), devices: new Set(), phones: new Set() };
let seq = 0;
let ctxPromise = null;
const uniquePhone = () => {
  const p = `+905${crypto.randomInt(0, 1e9).toString().padStart(9, '0')}`;
  created.phones.add(p);
  return p;
};

function getCtx() {
  if (ctxPromise) return ctxPromise;
  ctxPromise = (async () => {
    process.env.DATABASE_URL = URL_;
    process.env.NODE_ENV = 'test';
    process.env.BCRYPT_TEST_COST = '4';
    process.env.AUTH_CACHE_TTL_MS = '0';
    process.env.JWT_SECRET = crypto.randomBytes(32).toString('hex');
    process.env.PIN_PEPPER = crypto.randomBytes(32).toString('hex');
    process.env.LOCAL_KEY_SECRET = crypto.randomBytes(32).toString('hex');
    process.env.MQTT_PUBLIC_HOST = 'broker.test.invalid';
    process.env.MQTT_PUBLIC_PORT = '8884';
    // dotenv yalniz TANIMSIZ anahtarlari yukler: canli olabilecek yerel .env degerleri BOS dizgeyle sabitlenir.
    for (const k of ['EMQX_API_URL', 'EMQX_API_KEY', 'EMQX_API_SECRET', 'ALLOW_DEBUG_OTP', 'ADMIN_API_KEY', 'SMTP_HOST', 'SMTP_USER', 'SMTP_PASSWORD', 'GOOGLE_CLIENT_IDS', 'APPLE_CLIENT_IDS', 'MQTT_BACKEND_USER', 'MQTT_BACKEND_PASS']) process.env[k] = '';
    console.warn = () => {};
    console.log = () => {};

    const request = require('supertest');
    const bcrypt = require('bcryptjs');
    const db = require('../../src/db');
    const mailer = require('../../src/utils/mailer');
    const jwtConfig = require('../../src/middlewares/jwt_config');
    const credentials = require('../../src/services/mqtt_credential_service');
    const authService = require('../../src/services/auth_service');
    const { createApp } = require('../../src/server');

    const mail = { fail: false, sent: [] };
    mailer.setTransportFactory(() => ({
      sendMail: async (msg) => {
        if (mail.fail) throw new Error('smtp gecici ariza');
        mail.sent.push({ to: String(msg.to), text: String(msg.text) });
      },
    }));
    const sms = { fail: false, sent: [] };
    authService.setSmsSender(async (phone, text) => {
      if (sms.fail) throw new Error('sms ariza');
      sms.sent.push({ phone, text });
      return { sent: true };
    });

    const bridge = { isConnected: () => true, init() {}, end: async () => {}, publishCommand: async () => ({}), publishSys: async () => ({}), clearRetained: async () => {} };
    const app = createApp({ db, mqttBridge: bridge, pushService: { upsertToken: async () => {}, disableToken: async () => {}, disableAllTokensForUser: async () => 0 } });
    const q = (text, params) => db.query(text, params);
    const api = (method, url, token, body) => {
      let r = request(app)[method](url);
      if (token) r = r.set('Authorization', `Bearer ${token}`);
      if (body !== undefined && method !== 'get') r = r.send(body);
      return r;
    };

    const h = {
      async user({ email, phone = null, password = PASSWORD } = {}) {
        const n = ++seq;
        const mailAddr = email || `u${n}-${TAG}@${DOMAIN}`;
        const r = await q(
          `INSERT INTO users (email, password_hash, full_name, role, phone, is_active, account_status, password_changed_at)
           VALUES ($1, $2, 'Uyelik Test', 'user', $3, TRUE, 'active', NOW())
           RETURNING id, email, role, token_version`,
          [mailAddr, await bcrypt.hash(password, 4), phone]
        );
        created.users.add(r.rows[0].id);
        const u = { ...r.rows[0], phone };
        u.token = jwtConfig.signAccessToken({ id: u.id, role: u.role, token_version: u.token_version });
        return u;
      },
      async home(owner) {
        const r = await q(`INSERT INTO homes (name, mqtt_username) VALUES ($1, $2) RETURNING id, name, mqtt_username`, [`UPG-${TAG}-${++seq}`, `h_${crypto.randomBytes(8).toString('hex')}`]);
        created.homes.add(r.rows[0].id);
        if (owner) await q(`INSERT INTO home_users (home_id, user_id, role) VALUES ($1, $2, 'owner')`, [r.rows[0].id, owner.id]);
        return r.rows[0];
      },
      async member(home, user, role = 'resident') {
        await q(`INSERT INTO home_users (home_id, user_id, role) VALUES ($1, $2, $3)`, [home.id, user.id, role]);
      },
      async device(home) {
        const n = ++seq;
        const uuid = `AHBU-UPG${TAG.toUpperCase()}-${n}`;
        const mac = `E8:F6:${TAG.slice(0, 2)}:${TAG.slice(2, 4)}:${(n >> 8).toString(16).padStart(2, '0')}:${(n & 255).toString(16).padStart(2, '0')}`.toUpperCase();
        await q(
          `INSERT INTO devices (home_id, device_uuid, mac_address, setup_pin, is_claimed, is_online, is_commissioned, last_seen_at)
           VALUES ($1, $2, $3, NULL, TRUE, FALSE, FALSE, NOW())`,
          [home.id, uuid, mac]
        );
        created.devices.add(uuid);
      },
      count: async (table, where, params) => (await q(`SELECT count(*)::int AS n FROM ${table} WHERE ${where}`, params)).rows[0].n,
      one: async (text, params) => (await q(text, params)).rows[0],
    };
    return { db, q, api, h, mail, sms, credentials, authService };
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
      await c.q('DELETE FROM homes WHERE id = ANY ($1::uuid[])', [homes]);
    }
    if (devices.length > 0) await c.q('DELETE FROM devices WHERE device_uuid = ANY ($1::text[])', [devices]);
    await c.q('DELETE FROM phone_otp_codes WHERE phone = ANY ($1::text[])', [[...created.phones]]);
    await c.q('DELETE FROM password_resets WHERE identifier = ANY ($1::text[]) OR identifier LIKE $2', [[...created.phones], `%-${TAG}@${DOMAIN}`]);
    const otpUsers = await c.q('SELECT id FROM users WHERE phone = ANY ($1::text[])', [[...created.phones]]);
    for (const r of otpUsers.rows) users.push(r.id);
    if (users.length > 0) {
      await c.q('DELETE FROM device_audit_logs WHERE actor_user_id = ANY ($1::uuid[])', [users]);
      await c.q('DELETE FROM users WHERE id = ANY ($1::uuid[])', [users]);
    }
  } catch (err) {
    console.error('[uyelik_pg] temizlik hatasi (etiketli satirlar kalmis olabilir):', err.message);
  } finally {
    await c.db.pool.end().catch(() => {});
  }
});

async function loginOf(c, u) {
  const r = await c.api('post', '/api/v1/auth/login', null, { identifier: u.email, password: PASSWORD });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  return r.body.data;
}

// ------------------------------------------------------------------------------------------------ UYELIK-02
test('PG logout-all: kullanicinin TUM evlerdeki uygulama MQTT kimlikleri silinir; cihaz ve baska kullanici kimligi kalir', { skip: SKIP }, async () => {
  const c = await getCtx();
  const u = await c.h.user();
  const other = await c.h.user();
  const homeA = await c.h.home(u);
  const homeB = await c.h.home(other);
  await c.h.member(homeB, u);
  await c.credentials.issueUserCredential({ homeId: homeA.id, userId: u.id });
  await c.credentials.issueUserCredential({ homeId: homeB.id, userId: u.id });
  await c.credentials.issueUserCredential({ homeId: homeB.id, userId: other.id });
  await c.credentials.issueDeviceCredential({ homeId: homeA.id });
  const s = await loginOf(c, u);

  const res = await c.api('post', '/api/v1/auth/logout-all', s.access_token, {});
  assert.equal(res.status, 200, JSON.stringify(res.body));
  assert.equal(await c.h.count('mqtt_credentials', `user_id = $1 AND kind = 'app'`, [u.id]), 0);
  assert.equal(await c.h.count('mqtt_credentials', `user_id = $1 AND kind = 'app'`, [other.id]), 1);
  assert.equal(await c.h.count('mqtt_credentials', `home_id = $1 AND kind = 'device'`, [homeA.id]), 1);
  assert.equal(await c.h.count('refresh_tokens', 'user_id = $1 AND revoked_at IS NULL', [u.id]), 0);
});

test('PG change-password: uygulama MQTT kimlikleri silinir, yeni oturum doner', { skip: SKIP }, async () => {
  const c = await getCtx();
  const u = await c.h.user();
  const home = await c.h.home(u);
  await c.credentials.issueUserCredential({ homeId: home.id, userId: u.id });
  const s = await loginOf(c, u);
  const res = await c.api('post', '/api/v1/auth/change-password', s.access_token, { current_password: PASSWORD, new_password: 'Yepyeni-Parola-2027' });
  assert.equal(res.status, 200, JSON.stringify(res.body));
  assert.ok(res.body.data.access_token);
  assert.equal(await c.h.count('mqtt_credentials', `user_id = $1 AND kind = 'app'`, [u.id]), 0);
});

// ------------------------------------------------------------------------------------------------ UYELIK-03
test('PG hesap silme: uyesiz+cihazsiz tek-sahipli daire ayni transaction\'da silinir (200, released_homes 1, homes satiri yok)', { skip: SKIP }, async () => {
  const c = await getCtx();
  const u = await c.h.user();
  const empty = await c.h.home(u);
  await c.credentials.issueUserCredential({ homeId: empty.id, userId: u.id });
  await c.credentials.issueDeviceCredential({ homeId: empty.id }); // stoga donmus panodan kalan kimlik
  await c.q(`INSERT INTO service_tokens (home_id, created_by, pin_hash, expires_at) VALUES ($1, $2, $3, NOW() + interval '1 hour')`, [empty.id, u.id, crypto.randomBytes(16).toString('hex')]);
  await c.q(`INSERT INTO home_invitations (home_id, created_by, code_hash, role, expires_at) VALUES ($1, $2, $3, 'resident', NOW() + interval '1 day')`, [empty.id, u.id, crypto.randomBytes(16).toString('hex')]);

  const res = await c.api('delete', '/api/v1/auth/account', u.token, { password: PASSWORD });
  assert.equal(res.status, 200, JSON.stringify(res.body));
  assert.equal(res.body.data.released_homes, 1);
  assert.equal(await c.h.count('homes', 'id = $1', [empty.id]), 0);
  assert.equal(await c.h.count('mqtt_credentials', 'home_id = $1', [empty.id]), 0);
  assert.equal(await c.h.count('service_tokens', 'home_id = $1', [empty.id]), 0);
  assert.equal(await c.h.count('home_invitations', 'home_id = $1', [empty.id]), 0);
  assert.equal((await c.h.one('SELECT account_status FROM users WHERE id = $1', [u.id])).account_status, 'deleted');
  created.homes.delete(empty.id);
});

test('PG hesap silme: 1 cihazli ya da 1 uyeli tek-sahipli daire -> 409 SOLE_OWNER (govde aynen); hicbir sey silinmez', { skip: SKIP }, async () => {
  const c = await getCtx();
  const u1 = await c.h.user();
  const withDevice = await c.h.home(u1);
  await c.h.device(withDevice);
  const r1 = await c.api('delete', '/api/v1/auth/account', u1.token, { password: PASSWORD });
  assert.equal(r1.status, 409, JSON.stringify(r1.body));
  assert.equal(r1.body.code, 'SOLE_OWNER');
  assert.deepEqual(r1.body.homes, [{ id: withDevice.id, name: withDevice.name, other_member_count: 0, device_count: 1 }]);
  assert.equal(await c.h.count('homes', 'id = $1', [withDevice.id]), 1);

  const u2 = await c.h.user();
  const withMember = await c.h.home(u2);
  const empty = await c.h.home(u2);
  await c.h.member(withMember, await c.h.user());
  const r2 = await c.api('delete', '/api/v1/auth/account', u2.token, { password: PASSWORD });
  assert.equal(r2.status, 409, JSON.stringify(r2.body));
  assert.deepEqual(r2.body.homes.map((x) => [x.id, x.other_member_count, x.device_count]), [[withMember.id, 1, 0]]);
  assert.equal(await c.h.count('homes', 'id = $1', [empty.id]), 1, 'atomik: bos daire de silinmedi');
  assert.equal((await c.h.one('SELECT account_status FROM users WHERE id = $1', [u2.id])).account_status, 'active');
});

// ------------------------------------------------------------------------------------------------ UYELIK-K1
test('PG sifirlama: yeni kod teslim edilemezse (503) eski kod gecerli kalir; teslim edilince eski kod kapanir', { skip: SKIP }, async () => {
  const c = await getCtx();
  const u = await c.h.user();
  c.mail.fail = false;
  assert.equal((await c.api('post', '/api/v1/auth/forgot-password', null, { email: u.email })).status, 200);
  const code1 = /kodunuz: (\d{6})/.exec(c.mail.sent.filter((m) => m.to === u.email).at(-1).text)[1];
  // 60 sn bekleme: son talebi gecmise al (yalniz bu test kimligi)
  await c.q(`UPDATE password_resets SET created_at = created_at - interval '2 minutes' WHERE identifier = $1`, [u.email]);
  c.mail.fail = true;
  try {
    const again = await c.api('post', '/api/v1/auth/forgot-password', null, { email: u.email });
    assert.equal(again.status, 503);
    assert.equal(again.body.code, 'DELIVERY_FAILED');
  } finally {
    c.mail.fail = false;
  }
  assert.equal(await c.h.count('password_resets', 'identifier = $1 AND used_at IS NULL', [u.email]), 1, 'yalniz eski kod acik');
  const ok = await c.api('post', '/api/v1/auth/reset-password', null, { email: u.email, code: code1, new_password: 'Sifirlanan-Parola-1' });
  assert.equal(ok.status, 200, JSON.stringify(ok.body));

  // teslim BASARILI yeni talep: eskisi kapanir, yalniz yenisi acik kalir
  const v = await c.h.user();
  assert.equal((await c.api('post', '/api/v1/auth/forgot-password', null, { email: v.email })).status, 200);
  const first = await c.h.one('SELECT id FROM password_resets WHERE identifier = $1 ORDER BY created_at DESC LIMIT 1', [v.email]);
  await c.q(`UPDATE password_resets SET created_at = created_at - interval '2 minutes' WHERE identifier = $1`, [v.email]);
  assert.equal((await c.api('post', '/api/v1/auth/forgot-password', null, { email: v.email })).status, 200);
  const open = await c.q('SELECT id FROM password_resets WHERE identifier = $1 AND used_at IS NULL', [v.email]);
  assert.equal(open.rows.length, 1);
  assert.notEqual(open.rows[0].id, first.id, 'eski talep kapandi, yenisi acik');
});

test('PG telefon OTP: yeni SMS gonderilemezse (503) eski kod gecerli kalir', { skip: SKIP }, async () => {
  const c = await getCtx();
  const phone = uniquePhone();
  assert.equal((await c.api('post', '/api/v1/auth/otp/send', null, { phone })).status, 200);
  const code1 = /(\d{6})/.exec(c.sms.sent.filter((m) => m.phone === phone).at(-1).text)[1];
  await c.q(`UPDATE phone_otp_codes SET created_at = created_at - interval '2 minutes' WHERE phone = $1`, [phone]);
  c.sms.fail = true;
  try {
    assert.equal((await c.api('post', '/api/v1/auth/otp/send', null, { phone })).status, 503);
  } finally {
    c.sms.fail = false;
  }
  assert.equal(await c.h.count('phone_otp_codes', 'phone = $1 AND consumed_at IS NULL', [phone]), 1);
  const ok = await c.api('post', '/api/v1/auth/otp/verify', null, { phone, code: code1 });
  assert.equal(ok.status, 200, JSON.stringify(ok.body));
  // UYELIK-07: telefonla acilan hesapta yanittaki e-posta null, DB'de yer tutucu
  assert.equal(ok.body.data.user.email, null);
  const row = await c.h.one('SELECT email FROM users WHERE phone = $1', [phone]);
  assert.match(row.email, /@ahbu\.local$/);

  // UYELIK-08: ayni (yalniz SMS) hesap icin sifremi unuttum -> kullaniciya bagli talep ACILMAZ, gonderim yok
  const before = c.mail.sent.length;
  const fp = await c.api('post', '/api/v1/auth/forgot-password', null, { phone });
  assert.equal(fp.status, 200, JSON.stringify(fp.body));
  assert.equal(c.mail.sent.length, before);
  assert.equal(await c.h.count('password_resets', 'user_id = $1', [ok.body.data.user.id]), 0);
});
