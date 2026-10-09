'use strict';

// Sahip kararlari 2026-10-09 GERCEK PostgreSQL'de (yalitilmis gecici veritabani, scripts/migrate.js 001..044):
//  11  042: users.phone kanonik "+905XXXXXXXXX"; cakisan satirlar DEGISMEZ; bekleyen devir hedefi / OTP kodu cevrilir;
//      telefonla giris her yazimla kanonik hesabi bulur
//  13  DELETE /api/v1/homes/:homeId/members/me (ve /api): owner 409 OWNER_CANNOT_LEAVE; resident ayrilir -> uyelik +
//      uygulama MQTT kimligi silinir, yerel anahtar bekleyen, cihaz kimligi dondurulur, denetim 'member_left'; uye
//      olmayan 404; misafir /api yolundan ayrilir; servis oturumu 403
//  14  alarm listesi: sahiplik doneminden once kapanmis alarm gizli, acik alarm ve yeni alarm gorunur
//  16  super kalici silme: panolu evin tek sahibi 409 SOLE_OWNER_WITH_DEVICES; bos ev silinir
//  17A uzlastirici SQL'i cred_rotation_pending; yeni kimlik (bootstrap yolu) isareti kaldirir; fw < 1.3.0 atlanir
//  17B cihaz kimligi client_id = ESP32S3_<MAC>; 044 eski satirlari cevirir (uygulama NULL, cok panolu ev NULL)
//  18  guvenlik yapilandirmasi sorgusu (sensor / eylemci)
// EV_PG_TEST_URL yoksa ATLANIR.

const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const { PG_SKIP, openDatabase, setAppEnv } = require('../legal/_pg');

const MIG = path.join(__dirname, '..', '..', 'migrations');
const SQL_042 = fs.readFileSync(path.join(MIG, '042_phone_canonical.sql'), 'utf8');
const SQL_044 = fs.readFileSync(path.join(MIG, '044_mqtt_client_binding.sql'), 'utf8');

test('sahip kararlari 2026-10-09 gercek PG', { skip: PG_SKIP }, async (t) => {
  const dbx = await openDatabase('karar');
  if (!dbx) {
    t.skip('CREATE DATABASE yetkisi yok');
    return;
  }
  setAppEnv(dbx.url);
  const saved = { log: console.log, warn: console.warn, error: console.error };
  console.log = () => {};
  console.warn = () => {};
  const db = require('../../src/db');
  try {
    const request = require('supertest');
    const bcrypt = require('bcryptjs');
    const jwtConfig = require('../../src/middlewares/jwt_config');
    const secretBox = require('../../src/utils/secret_box');
    const credentials = require('../../src/services/mqtt_credential_service');
    const { SQL: RSQL } = require('../../src/services/device_reconciler');
    const deviceService = require('../../src/services/device_service');
    const { createApp } = require('../../src/server');
    const bridge = { isConnected: () => true, init() {}, end: async () => {}, publishCommand: async () => ({}), publishSys: async () => ({}), clearRetained: async () => {} };
    const app = createApp({ db, mqttBridge: bridge, pushService: { upsertToken: async () => {}, disableToken: async () => {} } });
    const q = (text, params) => db.query(text, params);
    const one = async (text, params) => (await q(text, params)).rows[0];
    let seq = 0;
    const api = (method, url, token, body) => {
      let r = request(app)[method](url);
      if (token) r = r.set('Authorization', `Bearer ${token}`);
      if (body !== undefined && method !== 'get') r = r.send(body);
      return r;
    };
    const user = async ({ role = 'user', phone = null, password = null } = {}) => {
      const n = ++seq;
      const hash = await bcrypt.hash(password || crypto.randomBytes(12).toString('hex'), 4);
      const u = await one(
        `INSERT INTO users (email, password_hash, full_name, role, phone, is_active, account_status, email_verified)
         VALUES ($1, $2, 'Karar Test', $3, $4, TRUE, 'active', TRUE) RETURNING id, email, role, token_version, phone`,
        [`k${n}@karar.example.test`, hash, role, phone]
      );
      u.token = jwtConfig.signAccessToken({ id: u.id, role: u.role, token_version: u.token_version });
      return u;
    };
    const home = async (owner) => {
      const h = await one('INSERT INTO homes (name, mqtt_username) VALUES ($1, $2) RETURNING id, mqtt_username', [
        `Karar ${++seq}`,
        `h_${crypto.randomBytes(8).toString('hex')}`,
      ]);
      if (owner) await q(`INSERT INTO home_users (home_id, user_id, role) VALUES ($1, $2, 'owner')`, [h.id, owner.id]);
      return h;
    };
    const member = (h, u, role) =>
      q(
        `INSERT INTO home_users (home_id, user_id, role, valid_from, valid_until, installer_expires_at)
         VALUES ($1, $2, $3, $4, $5, $6)`,
        [
          h.id, u.id, role,
          role === 'guest' ? new Date(Date.now() - 60000) : null,
          role === 'guest' ? new Date(Date.now() + 3600000) : null,
          role === 'service_user' ? new Date(Date.now() + 3600000) : null,
        ]
      );
    const device = async (h, { fw = '1.3.1', mac } = {}) => {
      const n = ++seq;
      const m = mac || `E8:F6:0A:${(n >> 16 & 255).toString(16).padStart(2, '0')}:${(n >> 8 & 255).toString(16).padStart(2, '0')}:${(n & 255).toString(16).padStart(2, '0')}`.toUpperCase();
      return one(
        `INSERT INTO devices (home_id, device_uuid, mac_address, is_claimed, is_online, last_seen_at, firmware_version, local_key_enc)
         VALUES ($1, $2, $3, TRUE, TRUE, NOW(), $4, $5) RETURNING id, device_uuid, mac_address`,
        [h.id, `AHBU-KARAR-${n}`, m, fw, secretBox.encrypt('EskiAnahtar12345')]
      );
    };

    await t.test('11: 042 telefonlari kanonik bicime cevirir; cakisma atlanir; giris her yazimla bulur', async () => {
      const a = await user({ phone: '05321112233', password: 'Telefon-Parola-2026' });
      const b = await user({ phone: '905321112244' });
      const c = await user({ phone: '0532 111 22 55' });
      const d = await user({ phone: '5321112266' });
      const x1 = await user({ phone: '05321112288' });
      const x2 = await user({ phone: '+905321112288' });
      const de = await user({ phone: '+4915112345678' });
      const h = await home(a);
      await q(
        `INSERT INTO home_transfers (home_id, from_user_id, target_identifier, transfer_code, status, expires_at)
         VALUES ($1, $2, '0532 111 22 99', $3, 'PENDING', NOW() + INTERVAL '1 hour')`,
        [h.id, a.id, `K-${crypto.randomBytes(6).toString('hex')}`]
      );
      await db.withTransaction((tx) => tx.query(SQL_042));
      await db.withTransaction((tx) => tx.query(SQL_042)); // idempotent
      const phoneOf = async (u) => (await one('SELECT phone FROM users WHERE id = $1', [u.id])).phone;
      assert.equal(await phoneOf(a), '+905321112233');
      assert.equal(await phoneOf(b), '+905321112244');
      assert.equal(await phoneOf(c), '+905321112255');
      assert.equal(await phoneOf(d), '+905321112266');
      assert.equal(await phoneOf(x1), '05321112288', 'cakisan satir degismez');
      assert.equal(await phoneOf(x2), '+905321112288');
      assert.equal(await phoneOf(de), '+4915112345678', 'TR disi korunur');
      assert.equal((await one('SELECT target_identifier FROM home_transfers WHERE home_id = $1', [h.id])).target_identifier, '+905321112299');
      for (const typed of ['0532 111 22 33', '905321112233', '5321112233']) {
        const r = await api('post', '/api/v1/auth/login', null, { phone: typed, password: 'Telefon-Parola-2026' });
        assert.equal(r.status, 200, `${typed}: ${JSON.stringify(r.body)}`);
        assert.equal(r.body.data.user.id, a.id);
      }
    });

    await t.test('13 + 17A + 17B: evden ayrilma; owner 409; resident ayrilinca anahtar bekler, cihaz kimligi dondurulur', async () => {
      const owner = await user();
      const resident = await user();
      const guest = await user();
      const tech = await user({ role: 'service_user' });
      const outsider = await user();
      const h = await home(owner);
      await member(h, resident, 'resident');
      await member(h, guest, 'guest');
      await member(h, tech, 'service_user');
      const dev = await device(h, { fw: '1.3.1', mac: 'e8:f6:0a:dd:87:54' });
      const devCred = await credentials.issueDeviceCredential({ homeId: h.id, deviceId: dev.id });
      const bound = await one(`SELECT client_id FROM mqtt_credentials WHERE username = $1`, [devCred.username]);
      assert.equal(bound.client_id, 'ESP32S3_E8F60ADD8754', '17B: cihaz kimligi panonun istemci kimligine bagli');
      const appCred = await credentials.issueUserCredential({ homeId: h.id, userId: resident.id });
      assert.equal((await one('SELECT client_id FROM mqtt_credentials WHERE username = $1', [appCred.username])).client_id, null);

      const own = await api('delete', `/api/v1/homes/${h.id}/members/me`, owner.token);
      assert.equal(own.status, 409, JSON.stringify(own.body));
      assert.equal(own.body.code, 'OWNER_CANNOT_LEAVE');
      assert.equal(own.body.message, 'Ev sahibi evden ayrılamaz; önce evi devredin.');
      assert.equal((await api('delete', `/api/v1/homes/${h.id}/members/me`, outsider.token)).status, 404);

      const res = await api('delete', `/api/v1/homes/${h.id}/members/me`, resident.token);
      assert.equal(res.status, 200, JSON.stringify(res.body));
      assert.deepEqual(res.body.data, { left: true, home_id: h.id });
      assert.equal((await one('SELECT count(*)::int AS n FROM home_users WHERE home_id = $1 AND user_id = $2', [h.id, resident.id])).n, 0);
      assert.equal((await one('SELECT count(*)::int AS n FROM mqtt_credentials WHERE user_id = $1', [resident.id])).n, 0, 'uygulama kimligi silindi');
      const d1 = await one('SELECT local_key_pending_enc FROM devices WHERE id = $1', [dev.id]);
      assert.ok(d1.local_key_pending_enc, 'pano-6: yerel anahtar bekleyen');
      const c1 = await one(`SELECT expires_at <= NOW() AS dead FROM mqtt_credentials WHERE home_id = $1 AND kind = 'device'`, [h.id]);
      assert.equal(c1.dead, true, '17A: cihaz kimligi gecersiz');
      const audit = await one(`SELECT actor_role, details FROM device_audit_logs WHERE event = 'member_left' AND home_id = $1`, [h.id]);
      assert.equal(audit.actor_role, 'resident');
      assert.ok(await one(`SELECT 1 FROM device_audit_logs WHERE event = 'device_credential_rotated' AND home_id = $1`, [h.id]));

      // Uzlastirici: yeni kimlik gelene kadar set_local_key yok; yeni kimlik (bootstrap yolu) isareti kaldirir
      const pend = (await q(RSQL.localKeyPending, [h.mqtt_username, 120])).rows[0];
      assert.equal(pend.cred_rotation_pending, true);
      await credentials.issueDeviceCredential({ homeId: h.id, deviceId: dev.id });
      assert.equal((await q(RSQL.localKeyPending, [h.mqtt_username, 120])).rows[0].cred_rotation_pending, false);

      // Misafir /api yolundan ayrilir (cihaz kimligi dondurulmez); servis personeli ayrilinca dondurulur
      const g = await api('delete', `/api/homes/${h.id}/members/me`, guest.token);
      assert.equal(g.status, 200, JSON.stringify(g.body));
      assert.equal((await one(`SELECT expires_at IS NULL AS live FROM mqtt_credentials WHERE home_id = $1 AND kind = 'device'`, [h.id])).live, true);
      assert.equal((await api('delete', `/api/v1/homes/${h.id}/members/me`, tech.token)).status, 200);
      assert.equal((await one(`SELECT expires_at <= NOW() AS dead FROM mqtt_credentials WHERE home_id = $1 AND kind = 'device'`, [h.id])).dead, true);

      // Servis oturumu ayrilamaz
      const sess = await one(
        `INSERT INTO service_sessions (home_id, technician_name, expires_at) VALUES ($1, 'Usta', NOW() + INTERVAL '1 hour') RETURNING id`,
        [h.id]
      ).catch(() => null);
      if (sess) {
        const st = jwtConfig.signServiceSessionToken({ sid: sess.id, home_id: h.id, expiresInSec: 600 });
        assert.equal((await api('delete', `/api/v1/homes/${h.id}/members/me`, st)).status, 403);
      }
    });

    await t.test('17A: firmware < 1.3.0 olan panoda cihaz kimligi dondurulmez, atlama denetime yazilir', async () => {
      const owner = await user();
      const resident = await user();
      const h = await home(owner);
      await member(h, resident, 'resident');
      const dev = await device(h, { fw: '1.2.0' });
      await credentials.issueDeviceCredential({ homeId: h.id, deviceId: dev.id });
      assert.equal((await api('delete', `/api/v1/homes/${h.id}/members/me`, resident.token)).status, 200);
      assert.equal((await one(`SELECT expires_at IS NULL AS live FROM mqtt_credentials WHERE home_id = $1 AND kind = 'device'`, [h.id])).live, true);
      const sk = await one(`SELECT details FROM device_audit_logs WHERE event = 'device_credential_rotation_skipped' AND home_id = $1`, [h.id]);
      assert.equal(sk.details.skip, 'old_firmware');
    });

    await t.test('14: alarm listesi sahiplik doneminden onceki kapanmis alarmlari gostermez', async () => {
      const owner = await user();
      const h = await home(owner);
      const dev = await device(h);
      const alarm = (aid, status, ago) =>
        q(
          `INSERT INTO alarms (home_id, device_id, aid, zone, kind, status, raised_at) VALUES ($1, $2, $3, 1, 'water', $4, NOW() - $5::interval)`,
          [h.id, dev.id, aid, status, ago]
        );
      await alarm('1-1', 'cleared', '3 days');
      await alarm('1-2', 'latched', '3 days');
      await alarm('1-3', 'cleared', '1 hour');
      await q(`UPDATE homes SET ownership_epoch = NOW() - INTERVAL '1 day' WHERE id = $1`, [h.id]);
      const r = await api('get', `/api/v1/homes/${h.id}/alarms?state=all`, owner.token);
      assert.equal(r.status, 200, JSON.stringify(r.body));
      assert.deepEqual(r.body.data.items.map((i) => i.aid).sort(), ['1-2', '1-3']);
    });

    await t.test('16: super kalici silme - panolu evin tek sahibi 409 SOLE_OWNER_WITH_DEVICES; bos ev silinir', async () => {
      const sup = await user({ role: 'super_user' });
      const withDev = await user();
      const h = await home(withDev);
      await device(h);
      const r = await api('delete', `/api/v1/admin/users/${withDev.id}?hard=true`, sup.token);
      assert.equal(r.status, 409, JSON.stringify(r.body));
      assert.equal(r.body.code, 'SOLE_OWNER_WITH_DEVICES');
      assert.ok(await one('SELECT 1 FROM users WHERE id = $1', [withDev.id]), 'hesap silinmedi');

      const empty = await user();
      const e = await home(empty);
      await q(`INSERT INTO legal_acceptances (user_id, document, version) VALUES ($1, 'terms', 1)`, [empty.id]);
      const ok = await api('delete', `/api/v1/admin/users/${empty.id}?hard=true`, sup.token);
      assert.equal(ok.status, 200, JSON.stringify(ok.body));
      assert.match(ok.body.message, /üyesi ve panosu olmayan 1 daire kaydı/);
      assert.equal((await one('SELECT count(*)::int AS n FROM homes WHERE id = $1', [e.id])).n, 0);
      // Karar 15: kabul satiri kalir, anonim
      assert.equal((await one(`SELECT count(*)::int AS n FROM legal_acceptances WHERE user_id IS NULL AND document = 'terms'`)).n >= 1, true);
    });

    await t.test('17B: 044 eski client_id degerlerini cevirir (tek pano MAC, cok pano NULL, uygulama NULL)', async () => {
      const o1 = await user();
      const single = await home(o1);
      await device(single, { mac: 'AA:BB:CC:00:11:22' });
      const multi = await home(await user());
      await device(multi);
      await device(multi);
      const ins = (h, kind, username) =>
        q(
          `INSERT INTO mqtt_credentials (username, password_hash, is_superuser, kind, home_id, client_id) VALUES ($1, '$2a$04$x', FALSE, $2, $3, $1)`,
          [username, kind, h.id]
        );
      await ins(single, 'device', `d_${single.mqtt_username}`);
      await ins(multi, 'device', `d_${multi.mqtt_username}`);
      await ins(single, 'app', `a_${single.mqtt_username}_0011223344`);
      await db.withTransaction((tx) => tx.query(SQL_044));
      await db.withTransaction((tx) => tx.query(SQL_044));
      const cid = async (u) => (await one('SELECT client_id FROM mqtt_credentials WHERE username = $1', [u])).client_id;
      assert.equal(await cid(`d_${single.mqtt_username}`), 'ESP32S3_AABBCC001122');
      assert.equal(await cid(`d_${multi.mqtt_username}`), null);
      assert.equal(await cid(`a_${single.mqtt_username}_0011223344`), null);
    });

    await t.test('18: guvenlik yapilandirmasi sorgusu sensor / eylemci sayar, yalniz bolge adi saymaz', async () => {
      const h = await home(await user());
      const dev = await device(h);
      const has = async () => (await one(deviceService.SQL.HAS_SAFETY_CONFIG, [h.id])).has_safety_config;
      assert.equal(await has(), false);
      await q(
        `INSERT INTO device_configs (device_id, module, rev, crc, body) VALUES ($1, 'safety', 1, '00000001', $2::jsonb)`,
        [dev.id, JSON.stringify({ sensors: [], actuators: [], zones: [{ id: 1, name: 'Ev' }] })]
      );
      assert.equal(await has(), false);
      await q(`UPDATE device_configs SET body = $2::jsonb WHERE device_id = $1`, [dev.id, JSON.stringify({ sensors: [{ id: 'd3', kind: 'water', zone: 1 }] })]);
      assert.equal(await has(), true);
    });
  } finally {
    console.log = saved.log;
    console.warn = saved.warn;
    console.error = saved.error;
    await db.pool.end().catch(() => {});
    await dbx.drop();
  }
});
