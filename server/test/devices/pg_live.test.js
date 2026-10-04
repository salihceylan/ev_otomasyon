'use strict';

// B11 - GERCEK PostgreSQL entegrasyon testleri (cihaz servisi, endpoint servisi, MQTT kimlik servisi, migration 020/021).
//
// Varsayilan olarak ATLANIR (`npm test` PostgreSQL gerektirmez). Etkinlestirmek icin TAMAMEN migration'lanmis
// (001..030) bir veritabani verin:
//
//   DATABASE_URL=<hedef> MIGRATE_CONFIRM=<db> node scripts/migrate.js        # once migration'lar
//   EV_PG_TEST_URL=postgresql://kullanici:parola@127.0.0.1:5432/<db> node --test test/devices/pg_live.test.js
//
// (WP-Q yerel QA yiginindaki gomulu PostgreSQL de kullanilabilir: tools/qa_stack, `npm run up`.)
//
// Her test KENDI satirlarini olusturur (rastgele etiketli: e-posta *-<etiket>*@wpb-live.invalid, cihaz AHBU-WL<ETIKET>-n,
// ev adi WPBL-<ETIKET>-n) ve en sonda yalnizca bu etiketli satirlari siler; baska verilere dokunmaz. Yine de UYGULAMA
// VERITABANINA (uretim/canli) KARSI CALISTIRMAYIN: kullanici/ev/cihaz satirlari olusturur ve siler.
//
// Neden: mock'lu testler SQL'in gercekten GECERLI ve DOGRU oldugunu kanitlamaz (parametre tipi cikarimi, ON CONFLICT,
// FOR UPDATE, ayni anda calisan islemler, tetikleyici/FK davranisi...). Bu dosya ayni servis kodunu gercek
// PostgreSQL'de dener. Gercek bir hata (es zamanli cihaz kimligi rotasyonunda UNIQUE ihlali) bu yolla bulunmustur.

const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');

const URL_ = process.env.EV_PG_TEST_URL;
const SKIP = URL_ ? false : 'EV_PG_TEST_URL tanimli degil (gercek PostgreSQL gerekir)';

const TAG = crypto.randomBytes(3).toString('hex').toUpperCase(); // 6 hex, buyuk harf (cihaz UID / ev adi)
const ETAG = TAG.toLowerCase(); // e-postalar normalize edilirken kucuk harfe cevrilir
const REASON = 'Kiraci ulasilamiyor, daire teslim alindi';
const FIRMWARE_ID = /^[A-Za-z0-9._:-]{1,24}$/;

let ctxPromise = null;
let seq = 0;

/** Gecikmeli kurulum: ortam degiskenleri -> servisler -> havuz. Atlanan calistirmada hicbir sey yuklenmez. */
function getCtx() {
  if (ctxPromise) return ctxPromise;
  ctxPromise = (async () => {
    process.env.LOCAL_KEY_SECRET = crypto.randomBytes(32).toString('hex');
    process.env.PIN_PEPPER = crypto.randomBytes(32).toString('hex');
    process.env.MQTT_PUBLIC_HOST = 'broker.test.invalid';
    process.env.MQTT_PUBLIC_PORT = '8884';
    for (const k of ['EMQX_API_URL', 'EMQX_API_KEY', 'EMQX_API_SECRET', 'ALLOW_DEBUG_OTP']) delete process.env[k];

    const { Pool } = require('pg');
    const bcrypt = require('bcryptjs');
    const pool = new Pool({ connectionString: URL_, max: 20, connectionTimeoutMillis: 15000 });
    pool.on('error', () => {});
    const db = {
      query: (text, params) => pool.query(text, params),
      async withTransaction(fn) {
        const client = await pool.connect();
        try {
          await client.query('BEGIN');
          const result = await fn({ query: (t, p) => client.query(t, p) });
          await client.query('COMMIT');
          return result;
        } catch (err) {
          await client.query('ROLLBACK').catch(() => {});
          throw err;
        } finally {
          client.release();
        }
      },
    };

    const pin = require('../../src/utils/pin');
    const secretBox = require('../../src/utils/secret_box');
    const { DeviceService } = require('../../src/services/device_service');
    const { EndpointService } = require('../../src/services/endpoint_service');
    const { MqttCredentialService } = require('../../src/services/mqtt_credential_service');

    // Cihaz onayi (expectAck, DAIRE-03): pano yayinlanan komutu uygular ('auto').
    const bridge = require('./_ack_bridge').withAckSupport({
      connected: true,
      failPublish: false,
      commands: [],
      sys: [],
      cleared: [],
      isConnected() { return this.connected; },
      async publishCommand(topic, obj) {
        if (this.failPublish) throw new Error('broker down');
        this.commands.push({ topic, obj: JSON.parse(JSON.stringify(obj)) });
        return {};
      },
      async publishSys(topic, obj) { this.sys.push({ topic, obj: JSON.parse(JSON.stringify(obj)) }); return {}; },
      async publishToTopic(topic, obj) { this.sys.push({ topic, obj }); return {}; },
      async clearRetained(topic) { this.cleared.push(topic); },
    });
    const mailer = {
      sent: [],
      async sendClaimOtpEmail(a) { this.sent.push(a); return { sent: true }; },
      lastCode() { return this.sent.length ? this.sent[this.sent.length - 1].code : null; },
    };
    const invites = [];
    const silent = { warn() {}, error() {}, log() {} };
    const credentials = new MqttCredentialService({ db, logger: silent });
    const deviceService = new DeviceService({
      db,
      mqttBridge: bridge,
      mqttCredentials: credentials,
      mailer,
      inviteCustomer: async (a) => { invites.push(a); return { sent: true }; },
    });
    const endpointService = new EndpointService({ db, deviceService, mqttBridge: bridge });

    const q = (text, params) => db.query(text, params);
    const helpers = {
      async user({ email, role = 'user', phone = null } = {}) {
        const n = ++seq;
        const r = await q(
          `INSERT INTO users (email, password_hash, full_name, role, phone) VALUES ($1, 'x', 'Test Kullanici', $2, $3) RETURNING id, email, role`,
          [email || `u${n}-${ETAG}@wpb-live.invalid`, role, phone]
        );
        return r.rows[0];
      },
      async inventory({ uuid, pinPlain = '135790', status = 'IN_STOCK' } = {}) {
        const n = ++seq;
        const r = await q(
          `INSERT INTO device_inventory (device_uuid, mac_address, pin_hash, model, status)
           VALUES ($1, $2, $3, 'ESP32-S3-POE-ETH-8DI-8RO', $4) RETURNING id, device_uuid, mac_address`,
          [uuid || `AHBU-WL${TAG}-${n}`, `E8:F6:${TAG.slice(0, 2)}:${TAG.slice(2, 4)}:${(n >> 8).toString(16).padStart(2, '0')}:${(n & 255).toString(16).padStart(2, '0')}`.toUpperCase(), pin.hashPin(pinPlain), status]
        );
        return { ...r.rows[0], pin: pinPlain };
      },
      act: (u, extra = {}) => ({ userId: u.id, globalRole: u.role, ip: '127.0.0.1', ...extra }),
      rows: async (text, params) => (await q(text, params)).rows,
      one: async (text, params) => (await q(text, params)).rows[0],
      count: async (table, where, params) => (await q(`SELECT count(*)::int AS n FROM ${table} WHERE ${where}`, params)).rows[0].n,
    };

    return { pool, db, q, bcrypt, pin, secretBox, bridge, mailer, invites, credentials, deviceService, endpointService, helpers };
  })();
  return ctxPromise;
}

/** Hizli kurulum: sahip + sahiplenmis cihaz (+ cevrimici). */
async function makeHome(c, { online = true, pinPlain = '135790' } = {}) {
  const h = c.helpers;
  const owner = await h.user();
  const inv = await h.inventory({ pinPlain });
  const r = await c.deviceService.claimDevice({
    actor: h.act(owner), deviceUuid: inv.device_uuid, setupPin: pinPlain, homeName: `WPBL-${TAG}-${++seq}`,
  });
  const home = await h.one('SELECT * FROM homes WHERE id = $1', [r.home_id]);
  const dev = await h.one('SELECT * FROM devices WHERE device_uuid = $1', [inv.device_uuid]);
  if (online) await c.q('UPDATE devices SET is_online = TRUE, last_seen_at = NOW() WHERE id = $1', [dev.id]);
  const access = (a, extra = {}) => ({ userId: owner.id, globalRole: 'user', ip: '127.0.0.1', access: a, ...extra });
  return { owner, home, dev, uuid: inv.device_uuid, inv, access, r };
}

/** Temizlige tabi tum ev verisiyle dolu bir ev (uyeler, kimlikler, kural, davet, servis PIN/oturum, devir, kilit). */
async function richHome(c) {
  const h = c.helpers;
  const q = c.q;
  const t = await makeHome(c);
  const resident = await h.user();
  const guest = await h.user();
  const staff = await h.user({ role: 'service_user' });
  await q(`INSERT INTO home_users (home_id, user_id, role) VALUES ($1, $2, 'resident')`, [t.home.id, resident.id]);
  await q(`INSERT INTO home_users (home_id, user_id, role, valid_from, valid_until) VALUES ($1, $2, 'guest', NOW() - interval '1 hour', NOW() + interval '1 day')`, [t.home.id, guest.id]);
  await q(`INSERT INTO home_users (home_id, user_id, role, installer_expires_at) VALUES ($1, $2, 'service_user', NOW() + interval '1 hour')`, [t.home.id, staff.id]);
  await c.credentials.issueUserCredential({ homeId: t.home.id, userId: t.owner.id });
  await c.credentials.issueUserCredential({ homeId: t.home.id, userId: resident.id });
  const rule = await h.one(
    `INSERT INTO scheduled_rules (home_id, device_id, channel, channel_type, action, hour, minute, created_by)
     VALUES ($1, $2, 5, 'relay', 'on', 8, 30, $3) RETURNING id`, [t.home.id, t.dev.id, t.owner.id]);
  await q(`INSERT INTO scheduled_rule_runs (rule_id, home_id, device_id, slot_at, status) VALUES ($1, $2, $3, NOW(), 'sent')`, [rule.id, t.home.id, t.dev.id]);
  await q(`INSERT INTO home_invitations (home_id, created_by, invite_code, expires_at) VALUES ($1, $2, $3, NOW() + interval '1 day')`, [t.home.id, t.owner.id, crypto.randomBytes(5).toString('hex').toUpperCase()]);
  const tok = await h.one(
    `INSERT INTO service_tokens (home_id, created_by, token, pin_hash, expires_at) VALUES ($1, $2, $3, $4, NOW() + interval '2 hours') RETURNING id`,
    [t.home.id, t.owner.id, crypto.randomBytes(8).toString('hex'), crypto.randomBytes(16).toString('hex')]);
  await q(`INSERT INTO service_sessions (home_id, service_token_id, technician_name, expires_at) VALUES ($1, $2, 'Ali Usta', NOW() + interval '2 hours')`, [t.home.id, tok.id]);
  await q(`INSERT INTO peace_notification_logs (home_id, open_lights_count) VALUES ($1, 2)`, [t.home.id]);
  await q(
    `INSERT INTO home_transfers (home_id, from_user_id, target_identifier, transfer_code, expires_at, code_hash) VALUES ($1, $2, 'x@example.invalid', $3, NOW() + interval '1 day', $4)`,
    [t.home.id, t.owner.id, crypto.randomBytes(8).toString('hex'), crypto.randomBytes(16).toString('hex')]);
  await q('UPDATE devices SET child_lock_enabled = TRUE WHERE id = $1', [t.dev.id]);
  await q('UPDATE homes SET child_lock_enabled = TRUE, child_lock_requested = TRUE, child_lock_requested_at = NOW(), child_lock_requested_by = $2 WHERE id = $1', [t.home.id, t.owner.id]);
  return { ...t, resident, guest, staff };
}

async function rejects(promise, status, code) {
  let caught = null;
  try { await promise; } catch (e) { caught = e; }
  assert.ok(caught, `HTTP ${status} ${code} bekleniyordu ama basarili oldu`);
  assert.equal(caught.status, status, `durum ${caught.status}: ${caught.message}`);
  if (code) assert.equal(caught.code, code, `kod ${caught.code}`);
  return caught;
}

const actorOf = (u, extra = {}) => ({ userId: u.id, globalRole: u.role, ip: '203.0.113.9', ...extra });
const clearBridge = (c) => { c.bridge.commands.length = 0; c.bridge.sys.length = 0; c.bridge.cleared.length = 0; };

test.after(async () => {
  if (!ctxPromise) return;
  const c = await ctxPromise;
  const like = `AHBU-WL${TAG}-%`;
  try {
    const homes = (await c.q(`SELECT id FROM homes WHERE name LIKE $1`, [`WPBL-${TAG}-%`])).rows.map((r) => r.id);
    if (homes.length > 0) {
      // home_id'si olan denetim/gunluk satirlari ev silinince NULL'a doner (yetim kalir): once bunlar silinir
      await c.q(`DELETE FROM device_audit_logs WHERE home_id = ANY ($1::uuid[])`, [homes]);
      await c.q(`DELETE FROM emergency_reset_logs WHERE home_id = ANY ($1::uuid[])`, [homes]);
      await c.q(`DELETE FROM device_replacement_logs WHERE home_id = ANY ($1::uuid[])`, [homes]);
      await c.q(`DELETE FROM commissioning_logs WHERE home_id = ANY ($1::uuid[])`, [homes]);
      await c.q(`DELETE FROM homes WHERE id = ANY ($1::uuid[])`, [homes]);
    }
    await c.q(`DELETE FROM device_claim_otps WHERE device_uuid LIKE $1`, [like]);
    await c.q(`DELETE FROM device_audit_logs WHERE device_uuid LIKE $1`, [like]);
    await c.q(`DELETE FROM emergency_reset_logs WHERE device_uuid LIKE $1`, [like]);
    await c.q(`DELETE FROM device_replacement_logs WHERE old_device_uuid LIKE $1 OR new_device_uuid LIKE $1`, [like]);
    await c.q(`DELETE FROM commissioning_logs WHERE device_uuid LIKE $1`, [like]);
    await c.q(`DELETE FROM devices WHERE device_uuid LIKE $1`, [like]);
    await c.q(`DELETE FROM device_inventory WHERE device_uuid LIKE $1`, [like]);
    await c.q(`DELETE FROM users WHERE email LIKE $1`, [`%-${ETAG}%@wpb-live.invalid`]);
  } catch (err) {
    console.error('[pg_live] temizlik hatasi (etiketli satirlar kalmis olabilir):', err.message);
  } finally {
    await c.pool.end().catch(() => {});
  }
});

// ================================================================================================
// Sahiplenme (claim)
// ================================================================================================
test('PG claim: ev, uyelik, cihaz, 8 kanal, envanter, cihaz kimligi (bcrypt + 4 ACL), denetim; tekrar sahiplenme 409', { skip: SKIP }, async () => {
  const c = await getCtx();
  const h = c.helpers;
  const owner = await h.user();
  const inv = await h.inventory({ pinPlain: '135790' });
  const r = await c.deviceService.claimDevice({ actor: h.act(owner), deviceUuid: inv.device_uuid, setupPin: '135790', homeName: `WPBL-${TAG}-${++seq}` });

  const home = await h.one('SELECT * FROM homes WHERE id = $1', [r.home_id]);
  assert.match(home.mqtt_username, /^h_[0-9a-f]{16}$/);
  assert.deepEqual((await h.rows('SELECT user_id, role FROM home_users WHERE home_id = $1', [home.id])).map((m) => [m.user_id, m.role]), [[owner.id, 'owner']]);
  const dev = await h.one('SELECT * FROM devices WHERE device_uuid = $1', [inv.device_uuid]);
  assert.equal(dev.home_id, home.id);
  assert.equal(dev.is_claimed, true);
  assert.equal(dev.setup_pin, null);
  assert.equal(c.secretBox.decrypt(dev.local_key_enc).length, 16);
  const eps = await h.rows('SELECT channel_index, type, shutter_pair_index, shutter_duration_sec, name FROM endpoints WHERE device_id = $1 ORDER BY channel_index', [dev.id]);
  assert.equal(eps.length, 8);
  assert.deepEqual(eps.filter((e) => e.type === 'shutter').map((e) => [e.channel_index, e.shutter_pair_index, e.shutter_duration_sec]), [[1, 1, 20], [2, 1, 20], [3, 2, 20], [4, 2, 20]]);
  const invRow = await h.one('SELECT * FROM device_inventory WHERE id = $1', [inv.id]);
  assert.equal(invRow.status, 'CLAIMED');
  assert.equal(invRow.pin_hash, 'CLAIMED_BURNED_PIN');
  assert.equal(invRow.local_key_enc, dev.local_key_enc);

  const cred = r.device_credential;
  assert.equal(cred.username, `d_${home.mqtt_username}`);
  assert.equal(cred.mqtt_server, 'broker.test.invalid');
  assert.equal(cred.mqtt_port, 8884);
  const credRow = await h.one('SELECT * FROM mqtt_credentials WHERE home_id = $1', [home.id]);
  assert.equal(credRow.kind, 'device');
  assert.ok(await c.bcrypt.compare(cred.password, credRow.password_hash));
  const acl = await h.rows('SELECT action, topic FROM mqtt_acl WHERE username = $1 ORDER BY action, topic', [cred.username]);
  assert.deepEqual(acl.map((a) => `${a.action}:${a.topic.split('/')[2]}`), ['publish:state', 'publish:status', 'subscribe:cmd', 'subscribe:sys']);
  const audit = await h.rows('SELECT event, ip_address, details FROM device_audit_logs WHERE device_uuid = $1', [inv.device_uuid]);
  assert.equal(audit.length, 1);
  assert.equal(audit[0].event, 'device_claimed');
  assert.ok(!JSON.stringify(audit[0]).includes(cred.password));
  await rejects(c.deviceService.claimDevice({ actor: h.act(owner), deviceUuid: inv.device_uuid, setupPin: '135790' }), 409, 'CONFLICT');
});

test('PG claim yarisi: 6 es zamanli sahiplenme -> TAM 1 basari (FOR UPDATE); digerleri 409; yetim ev kalmaz', { skip: SKIP }, async () => {
  const c = await getCtx();
  const h = c.helpers;
  const users = [];
  for (let i = 0; i < 6; i++) users.push(await h.user());
  const inv = await h.inventory({ pinPlain: '246810' });
  const settled = await Promise.allSettled(users.map((u) => c.deviceService.claimDevice({ actor: h.act(u), deviceUuid: inv.device_uuid, setupPin: '246810', homeName: `WPBL-${TAG}-${++seq}` })));
  const ok = settled.filter((s) => s.status === 'fulfilled');
  assert.equal(ok.length, 1, JSON.stringify(settled.map((s) => (s.status === 'rejected' ? s.reason.message : 'ok'))));
  assert.ok(settled.filter((s) => s.status === 'rejected').every((s) => s.reason.status === 409));
  assert.equal(await h.count('devices', 'device_uuid = $1', [inv.device_uuid]), 1);
  const orphans = await h.rows(
    `SELECT h.id FROM homes h
      WHERE h.id <> $1
        AND EXISTS (SELECT 1 FROM home_users hu WHERE hu.home_id = h.id AND hu.user_id = ANY ($2::uuid[]))
        AND NOT EXISTS (SELECT 1 FROM devices d WHERE d.home_id = h.id)`,
    [ok[0].value.home_id, users.map((u) => u.id)]
  );
  assert.equal(orphans.length, 0, 'yarisi kaybedenler icin yetim ev kalmamali');
});

test('PG ayni sahip icin es zamanli sahiplenmeler: bos ev yarisi YOK (advisory kilit) -> her cihaz ayri evde, her evde tek cihaz kimligi', { skip: SKIP }, async () => {
  const c = await getCtx();
  const h = c.helpers;
  const owner = await h.user();
  // sahibin cihazsiz BIR evi var: es zamanli sahiplenmelerin ikisi de bu bos evi secmeye calisir
  const empty = await h.one(`INSERT INTO homes (name, mqtt_username) VALUES ($1, 'h_' || substr(md5(random()::text), 1, 16)) RETURNING id`, [`WPBL-${TAG}-${++seq}`]);
  await c.q(`INSERT INTO home_users (home_id, user_id, role) VALUES ($1, $2, 'owner')`, [empty.id, owner.id]);
  const invs = [];
  for (let i = 0; i < 3; i++) invs.push(await h.inventory({ pinPlain: '112233' }));
  const settled = await Promise.allSettled(
    invs.map((inv) => c.deviceService.claimDevice({ actor: h.act(owner), deviceUuid: inv.device_uuid, setupPin: '112233', homeName: `WPBL-${TAG}-${++seq}` }))
  );
  assert.ok(settled.every((s) => s.status === 'fulfilled'), JSON.stringify(settled.filter((s) => s.status === 'rejected').map((s) => s.reason.message)));
  const homeIds = settled.map((s) => s.value.home_id);
  assert.equal(new Set(homeIds).size, 3, 'her cihaz AYRI evde (bir ev = bir pano)');
  assert.ok(homeIds.includes(empty.id), 'bos ev kullanildi');
  for (const id of homeIds) {
    assert.equal(await h.count('devices', 'home_id = $1', [id]), 1);
    assert.equal(await h.count('mqtt_credentials', `home_id = $1 AND kind = 'device'`, [id]), 1);
  }
});

test('PG PIN sayaci ATOMIK: 8 es zamanli yanlis PIN -> tam 5 sayilir, 423 kilit; kilitliyken dogru PIN reddedilir', { skip: SKIP }, async () => {
  const c = await getCtx();
  const h = c.helpers;
  const users = [];
  for (let i = 0; i < 8; i++) users.push(await h.user());
  const inv = await h.inventory({ pinPlain: '111222' });
  const settled = await Promise.allSettled(users.map((u) => c.deviceService.claimDevice({ actor: h.act(u), deviceUuid: inv.device_uuid, setupPin: '999999' })));
  assert.ok(settled.every((s) => s.status === 'rejected'));
  assert.deepEqual(settled.map((s) => s.reason.status).sort(), [403, 403, 403, 403, 423, 423, 423, 423]);
  const row = await h.one('SELECT failed_attempts, locked_until, status FROM device_inventory WHERE id = $1', [inv.id]);
  assert.equal(row.failed_attempts, 5);
  assert.ok(row.locked_until && new Date(row.locked_until) > new Date());
  const e = await rejects(c.deviceService.claimDevice({ actor: h.act(users[0]), deviceUuid: inv.device_uuid, setupPin: '111222' }), 423, 'PIN_LOCKED');
  assert.ok(e.extra && e.extra.retry_after > 0);
  assert.equal((await h.one('SELECT failed_attempts FROM device_inventory WHERE id = $1', [inv.id])).failed_attempts, 5, 'kilitliyken sayac artmaz');
});

test('PG staff claim: OTP zorunlu; yanlis OTP atomik sayac (5 -> 429); dogru OTP ile musteri hesabi pending_invite + 72 saatlik servis uyeligi', { skip: SKIP }, async () => {
  const c = await getCtx();
  const h = c.helpers;
  const staff = await h.user({ role: 'service_user' });
  const inv = await h.inventory({ pinPlain: '654321' });
  const target = `musteri-${ETAG}-${++seq}@wpb-live.invalid`;
  const base = { actor: h.act(staff), deviceUuid: inv.device_uuid, setupPin: '654321' };

  await rejects(c.deviceService.claimDevice({ ...base, targetOwnerIdentifier: target }), 400, 'VALIDATION'); // OTP yok
  await rejects(c.deviceService.claimDevice(base), 400, 'VALIDATION'); // staff hedefsiz
  const otpRes = await c.deviceService.requestClaimOtp({ actor: h.act(staff), deviceUuid: inv.device_uuid, targetOwnerIdentifier: target });
  assert.equal(otpRes.resend_after, 60);
  const code = c.mailer.lastCode();
  assert.match(code, /^\d{6}$/);
  assert.ok(!JSON.stringify(await h.one('SELECT otp_hash, attempts FROM device_claim_otps WHERE device_uuid = $1', [inv.device_uuid])).includes(code), 'OTP duz metin saklanmaz');
  await rejects(c.deviceService.requestClaimOtp({ actor: h.act(staff), deviceUuid: inv.device_uuid, targetOwnerIdentifier: target }), 429, 'RATE_LIMITED');

  const wrong = code === '000000' ? '000001' : '000000';
  for (let i = 1; i <= 5; i++) {
    const e = await rejects(c.deviceService.claimDevice({ ...base, targetOwnerIdentifier: target, otpCode: wrong }), 400, 'VALIDATION');
    assert.equal(e.extra.remaining_attempts, 5 - i);
  }
  await rejects(c.deviceService.claimDevice({ ...base, targetOwnerIdentifier: target, otpCode: code }), 429, 'RATE_LIMITED'); // sayac dolu: dogru kod bile reddedilir

  const inv2 = await h.inventory({ pinPlain: '654321' });
  await c.deviceService.requestClaimOtp({ actor: h.act(staff), deviceUuid: inv2.device_uuid, targetOwnerIdentifier: target });
  const r = await c.deviceService.claimDevice({ actor: h.act(staff), deviceUuid: inv2.device_uuid, setupPin: '654321', targetOwnerIdentifier: target, otpCode: c.mailer.lastCode(), homeName: `WPBL-${TAG}-${++seq}` });
  const customer = await h.one('SELECT id, role, account_status, password_hash, created_by_user_id FROM users WHERE email = $1', [target]);
  assert.equal(customer.role, 'user');
  assert.equal(customer.account_status, 'pending_invite');
  assert.equal(customer.created_by_user_id, staff.id);
  assert.match(customer.password_hash, /^\$2[aby]\$12\$/, 'bcrypt cost 12, kullanilamaz rastgele parola');
  const mem = await h.rows('SELECT user_id, role, installer_expires_at FROM home_users WHERE home_id = $1', [r.home_id]);
  assert.deepEqual(mem.map((m) => m.role).sort(), ['owner', 'service_user']);
  assert.equal(mem.find((m) => m.role === 'owner').user_id, customer.id);
  const hours = (new Date(mem.find((m) => m.role === 'service_user').installer_expires_at) - Date.now()) / 3600000;
  assert.ok(hours > 71 && hours <= 72.01, `servis uyeligi suresi: ${hours} saat`);
  assert.equal(r.customer_account.status, 'pending_invite');
  assert.equal(await h.count('device_claim_otps', 'device_uuid = $1', [inv2.device_uuid]), 0, 'OTP tuketildi');
});

test('PG OTP: es zamanli istekler -> yalniz biri gonderilir (ON CONFLICT ... WHERE atomik); yeniden istek sayaci sifirlamaz; mail hatasi 502', { skip: SKIP }, async () => {
  const c = await getCtx();
  const h = c.helpers;
  const staff = await h.user({ role: 'service_user' });
  const inv = await h.inventory();
  const target = `otp-${ETAG}-${++seq}@wpb-live.invalid`;
  const sent0 = c.mailer.sent.length;
  const settled = await Promise.allSettled([1, 2, 3].map(() => c.deviceService.requestClaimOtp({ actor: h.act(staff), deviceUuid: inv.device_uuid, targetOwnerIdentifier: target })));
  assert.equal(settled.filter((s) => s.status === 'fulfilled').length, 1);
  assert.ok(settled.filter((s) => s.status === 'rejected').every((s) => s.reason.status === 429));
  assert.equal(c.mailer.sent.length - sent0, 1, 'tek e-posta');

  const args = { actor: h.act(staff), deviceUuid: inv.device_uuid, targetOwnerIdentifier: target };
  await c.q(`UPDATE device_claim_otps SET attempts = 3, created_at = NOW() - interval '2 minutes' WHERE device_uuid = $1`, [inv.device_uuid]);
  await c.deviceService.requestClaimOtp(args);
  assert.equal((await h.one('SELECT attempts FROM device_claim_otps WHERE device_uuid = $1', [inv.device_uuid])).attempts, 3, 'pencere icinde sayac KORUNUR');
  await c.q(`UPDATE device_claim_otps SET window_started_at = NOW() - interval '16 minutes', created_at = NOW() - interval '2 minutes' WHERE device_uuid = $1`, [inv.device_uuid]);
  await c.deviceService.requestClaimOtp(args);
  assert.equal((await h.one('SELECT attempts FROM device_claim_otps WHERE device_uuid = $1', [inv.device_uuid])).attempts, 0, 'pencere dolunca sifirlanir');

  const orig = c.mailer.sendClaimOtpEmail;
  c.mailer.sendClaimOtpEmail = async () => ({ sent: false, reason: 'SMTP' });
  try {
    await c.q(`UPDATE device_claim_otps SET created_at = NOW() - interval '2 minutes' WHERE device_uuid = $1`, [inv.device_uuid]);
    await rejects(c.deviceService.requestClaimOtp(args), 502, 'MAIL_UNAVAILABLE');
  } finally {
    c.mailer.sendClaimOtpEmail = orig;
  }
  assert.ok(new Date((await h.one('SELECT expires_at FROM device_claim_otps WHERE device_uuid = $1', [inv.device_uuid])).expires_at) <= new Date(), 'teslim edilmeyen kod gecersiz kilindi');
});

// ================================================================================================
// Cocuk kilidi, uc noktalar, devreye alma, huzur, komut hatti
// ================================================================================================
test('PG cocuk kilidi: niyet yazilir (durum DEGIL), yayin ONCE; no-op; ters niyet; cevrimdisi 409; yayin hatasi geri alinir; es zamanli seri islenir', { skip: SKIP }, async () => {
  const c = await getCtx();
  const h = c.helpers;
  const t = await makeHome(c);
  clearBridge(c);
  const r1 = await c.deviceService.setChildLock({ actor: t.access('owner'), homeId: t.home.id, enabled: true });
  assert.equal(r1.requested, true);
  assert.equal(r1.delivered, true);
  assert.match(r1.command_id, FIRMWARE_ID);
  assert.deepEqual(c.bridge.commands.map((x) => [x.obj.cmd, x.obj.enabled]), [['set_child_lock', true]]);
  let home = await h.one('SELECT * FROM homes WHERE id = $1', [t.home.id]);
  assert.equal(home.child_lock_requested, true);
  assert.equal(home.child_lock_requested_by, t.owner.id);
  assert.equal(home.child_lock_enabled, false, 'REST gercek durumu YAZMAZ');
  assert.equal(await h.count('device_audit_logs', `home_id = $1 AND event = 'child_lock_set'`, [t.home.id]), 1);

  await c.q('UPDATE devices SET child_lock_enabled = TRUE WHERE id = $1', [t.dev.id]); // cihaz bildirimi (kopru)
  await c.q('UPDATE homes SET child_lock_enabled = TRUE WHERE id = $1', [t.home.id]);
  clearBridge(c);
  const r2 = await c.deviceService.setChildLock({ actor: t.access('owner'), homeId: t.home.id, enabled: true });
  assert.equal(r2.no_change, true);
  assert.equal(c.bridge.commands.length, 0);
  const g = await c.deviceService.getChildLock({ homeId: t.home.id });
  assert.equal(g.in_sync, true);
  const r3 = await c.deviceService.setChildLock({ actor: t.access('resident'), homeId: t.home.id, enabled: false });
  assert.equal(r3.requested, false);
  await rejects(c.deviceService.setChildLock({ actor: t.access('guest'), homeId: t.home.id, enabled: true }), 403, 'FORBIDDEN');

  await c.q('UPDATE devices SET is_online = FALSE WHERE id = $1', [t.dev.id]);
  const before = await h.one('SELECT child_lock_requested, child_lock_requested_at FROM homes WHERE id = $1', [t.home.id]);
  const e = await rejects(c.deviceService.setChildLock({ actor: t.access('owner'), homeId: t.home.id, enabled: true }), 409, 'DEVICE_OFFLINE');
  assert.equal(e.extra.device_online, false);
  assert.deepEqual(await h.one('SELECT child_lock_requested, child_lock_requested_at FROM homes WHERE id = $1', [t.home.id]), before);

  await c.q('UPDATE devices SET is_online = TRUE WHERE id = $1', [t.dev.id]);
  c.bridge.failPublish = true;
  const audits = await h.count('device_audit_logs', `home_id = $1 AND event = 'child_lock_set'`, [t.home.id]);
  try {
    await rejects(c.deviceService.setChildLock({ actor: t.access('owner'), homeId: t.home.id, enabled: true }), 502, 'BROKER_UNAVAILABLE');
  } finally {
    c.bridge.failPublish = false;
  }
  assert.equal((await h.one('SELECT child_lock_requested FROM homes WHERE id = $1', [t.home.id])).child_lock_requested, before.child_lock_requested);
  assert.equal(await h.count('device_audit_logs', `home_id = $1 AND event = 'child_lock_set'`, [t.home.id]), audits, 'basarisiz yayin icin denetim satiri kalmaz');

  const t2 = await makeHome(c);
  clearBridge(c);
  const settled = await Promise.allSettled(Array.from({ length: 8 }, (_, i) => c.deviceService.setChildLock({ actor: t2.access('owner'), homeId: t2.home.id, enabled: i % 2 === 0 })));
  assert.ok(settled.every((s) => s.status === 'fulfilled'), JSON.stringify(settled.filter((s) => s.status === 'rejected').map((s) => s.reason.message)));
  const nonNoop = settled.filter((s) => !s.value.no_change).length;
  assert.equal(await h.count('device_audit_logs', `home_id = $1 AND event = 'child_lock_set'`, [t2.home.id]), nonNoop);
  assert.equal(c.bridge.commands.length, nonNoop);
  assert.equal((await h.one('SELECT child_lock_requested FROM homes WHERE id = $1', [t2.home.id])).child_lock_requested, c.bridge.commands.at(-1).obj.enabled);
});

test('PG uc noktalar: liste (MAC yok), yeniden adlandirma, tip degisimi, panjur suresi (set_runtime ONCE, sonra DB), kontrol, IDOR 404', { skip: SKIP }, async () => {
  const c = await getCtx();
  const h = c.helpers;
  const eps = c.endpointService;
  const t = await makeHome(c);
  const list = await eps.getEndpointsByHome(t.home.id);
  assert.equal(list.length, 8);
  for (const k of ['id', 'channel', 'endpoint_type', 'shutter_position', 'online', 'name']) assert.ok(k in list[0], `eksik alan: ${k}`);
  assert.ok(!('mac_address' in list[0]) && !('local_key_enc' in list[0]));

  const light = list.find((e) => e.channel === 5);
  await eps.updateEndpoint({ actor: t.access('owner'), homeId: t.home.id, endpointId: light.id, patch: { name: 'Salon Avize', room: 'Salon' } });
  assert.equal((await h.one('SELECT name FROM endpoints WHERE id = $1', [light.id])).name, 'Salon Avize');
  await eps.updateEndpoint({ actor: t.access('owner'), homeId: t.home.id, endpointId: light.id, patch: { type: 'plug' } });
  assert.equal((await h.one('SELECT type FROM endpoints WHERE id = $1', [light.id])).type, 'plug');
  const shutterEp = list.find((e) => e.channel === 1);
  await rejects(eps.updateEndpoint({ actor: t.access('owner'), homeId: t.home.id, endpointId: shutterEp.id, patch: { type: 'light' } }), 400, 'VALIDATION');
  await rejects(eps.updateEndpoint({ actor: t.access('resident'), homeId: t.home.id, endpointId: light.id, patch: { name: 'X' } }), 403, 'FORBIDDEN');

  clearBridge(c);
  await eps.updateEndpoint({ actor: t.access('owner'), homeId: t.home.id, endpointId: shutterEp.id, patch: { shutter_duration_sec: 24 } });
  assert.deepEqual(c.bridge.commands.map((x) => [x.obj.cmd, x.obj.shutter, x.obj.sec]), [['set_runtime', 1, 24]]);
  assert.deepEqual((await h.rows('SELECT shutter_duration_sec FROM endpoints WHERE device_id = $1 AND shutter_pair_index = 1 ORDER BY channel_index', [t.dev.id])).map((d) => d.shutter_duration_sec), [24, 24]);
  assert.equal((await h.one('SELECT shutter_duration_sec FROM endpoints WHERE device_id = $1 AND channel_index = 3', [t.dev.id])).shutter_duration_sec, 20);

  c.bridge.failPublish = true;
  try {
    await rejects(eps.updateEndpoint({ actor: t.access('owner'), homeId: t.home.id, endpointId: shutterEp.id, patch: { shutter_duration_sec: 30 } }), 502, 'BROKER_UNAVAILABLE');
  } finally {
    c.bridge.failPublish = false;
  }
  assert.equal((await h.one('SELECT shutter_duration_sec FROM endpoints WHERE id = $1', [shutterEp.id])).shutter_duration_sec, 24);
  await c.q('UPDATE devices SET is_online = FALSE WHERE id = $1', [t.dev.id]);
  await rejects(eps.updateEndpoint({ actor: t.access('owner'), homeId: t.home.id, endpointId: shutterEp.id, patch: { shutter_duration_sec: 31 } }), 409, 'DEVICE_OFFLINE');
  await c.q('UPDATE devices SET is_online = TRUE WHERE id = $1', [t.dev.id]);

  clearBridge(c);
  await eps.controlEndpoint({ actor: t.access('owner'), homeId: t.home.id, endpointId: light.id, commandData: { state: true } });
  await eps.controlEndpoint({ actor: t.access('owner'), homeId: t.home.id, endpointId: shutterEp.id, commandData: { command: 'up' } });
  assert.equal(c.bridge.commands[0].obj.relay, 5);
  assert.equal(c.bridge.commands[0].obj.state, true);
  assert.equal(c.bridge.commands[1].obj.shutter, 1);
  assert.equal(c.bridge.commands[1].obj.cmd, 'up');
  for (const x of c.bridge.commands) assert.match(x.obj.id, FIRMWARE_ID);

  const other = await makeHome(c);
  await rejects(eps.updateEndpoint({ actor: other.access('owner'), homeId: other.home.id, endpointId: light.id, patch: { name: 'Calma' } }), 404, 'NOT_FOUND');
});

test('PG devreye alma: tests_passed SUNUCUDA hesaplanir; kontrol sonuclari ayri tabloda; basarisiz -> TESTS_FAILED; servis oturumu kullanici satiri olusturmaz', { skip: SKIP }, async () => {
  const c = await getCtx();
  const h = c.helpers;
  const t = await makeHome(c);
  const staff = await h.user({ role: 'service_user' });
  const checks = Object.fromEntries(['relays', 'buttons', 'shutters', 'network', 'cloud'].map((n) => [n, { ok: true, detail: `${n} tamam` }]));
  const actor = { userId: staff.id, globalRole: 'service_user', access: 'service_user', ip: '127.0.0.1' };
  const r = await c.deviceService.commissionHome({ actor, homeId: t.home.id, deviceUuid: t.uuid, checks, notes: 'Kurulum tamam' });
  assert.equal(r.tests_passed, true);
  const dev = await h.one('SELECT is_commissioned, commissioning_status, commissioned_by FROM devices WHERE id = $1', [t.dev.id]);
  assert.equal(dev.is_commissioned, true);
  assert.equal(dev.commissioning_status, 'APPROVED_WORKING');
  assert.equal(dev.commissioned_by, staff.id);
  assert.equal((await h.rows('SELECT 1 FROM commissioning_checks cc JOIN commissioning_logs cl ON cl.id = cc.commissioning_log_id WHERE cl.device_id = $1', [t.dev.id])).length, 5);
  assert.ok(JSON.stringify(await c.deviceService.getCommissioningStatus({ homeId: t.home.id })).includes('APPROVED_WORKING'));

  const r2 = await c.deviceService.commissionHome({ actor, homeId: t.home.id, deviceUuid: t.uuid, checks: { ...checks, buttons: { ok: false, detail: 'buton 3 calismiyor' } }, notes: null });
  assert.equal(r2.tests_passed, false);
  const dev2 = await h.one('SELECT is_commissioned, commissioning_status FROM devices WHERE id = $1', [t.dev.id]);
  assert.equal(dev2.is_commissioned, false);
  assert.equal(dev2.commissioning_status, 'TESTS_FAILED');
  await rejects(c.deviceService.commissionHome({ actor, homeId: t.home.id, deviceUuid: t.uuid, checks: { relays: { ok: true } }, notes: null }), 400, 'VALIDATION');

  const label = `Ali Usta ${crypto.randomBytes(3).toString('hex')}`;
  const sess = { userId: null, globalRole: 'service_session', access: 'service_session', ip: '127.0.0.1', label, sessionId: crypto.randomUUID() };
  const t0 = (await h.one('SELECT clock_timestamp() AS t')).t;
  assert.equal((await c.deviceService.commissionHome({ actor: sess, homeId: t.home.id, deviceUuid: t.uuid, checks, notes: 'oturumla' })).tests_passed, true);
  // Kullanici satiri olusmaz. Tum tabloyu saymak, ayni veritabaninda paralel calisan PG test dosyalarinin
  // kullanici eklemesiyle yarisir (2026-10-04 kapisinda 39 !== 38). Bu cagrinin olusturabilecegi satirlar aranir:
  // oturum etiketiyle adlandirilmis ya da bu eve uye olan yeni kullanici.
  const created = await h.rows(
    `SELECT u.id FROM users u
      WHERE u.created_at >= $1
        AND (u.full_name = $2 OR EXISTS (SELECT 1 FROM home_users hu WHERE hu.user_id = u.id AND hu.home_id = $3))`,
    [t0, label, t.home.id]
  );
  assert.equal(created.length, 0, 'kullanici satiri olusmaz');
  const log = await h.one(
    'SELECT technician_id, technician_label, service_session_id FROM commissioning_logs WHERE device_id = $1 ORDER BY created_at DESC LIMIT 1',
    [t.dev.id]
  );
  assert.equal(log.technician_id, null);
  assert.equal(log.technician_label, label, 'teknisyen etiketi oturumdan yazilir');
  assert.equal(log.service_session_id, sess.sessionId, 'oturum kimligi yazilir');
});

test('PG huzur bildirimi + toplu lamba kapatma + teshis + yerel anahtar + cihaz listesi + kimlik yenileme + komut hatti (IDOR/rol/cevrimdisi)', { skip: SKIP }, async () => {
  const c = await getCtx();
  const h = c.helpers;
  const svc = c.deviceService;
  const t = await makeHome(c);
  await c.q('UPDATE endpoints SET current_state = TRUE WHERE device_id = $1 AND channel_index IN (5, 6)', [t.dev.id]);
  await c.q('UPDATE endpoints SET current_position = 40 WHERE device_id = $1 AND channel_index IN (1, 2)', [t.dev.id]);
  // v2 (WP-H): yalniz CANLI cihaza guvenilir: is_online + son 120 sn icinde last_seen_at (veritabani saatiyle)
  await c.q('UPDATE devices SET last_seen_at = CURRENT_TIMESTAMP WHERE id = $1', [t.dev.id]);
  const s = await svc.getPeaceNotificationSettings({ homeId: t.home.id });
  assert.equal(s.open_lights_count, 2);
  assert.equal(s.open_shutters_count, 1);
  await svc.updatePeaceNotificationSettings({ actor: t.access('owner'), homeId: t.home.id, enabled: false, notificationTime: '22:15' });
  const home = await h.one('SELECT peace_notification_enabled, peace_notification_time FROM homes WHERE id = $1', [t.home.id]);
  assert.equal(home.peace_notification_enabled, false);
  assert.equal(home.peace_notification_time, '22:15');
  await rejects(svc.updatePeaceNotificationSettings({ actor: t.access('owner'), homeId: t.home.id, notificationTime: '25:99' }), 400, 'VALIDATION');
  await rejects(svc.updatePeaceNotificationSettings({ actor: t.access('guest'), homeId: t.home.id, enabled: true }), 403, 'FORBIDDEN');

  clearBridge(c);
  const closed = await svc.closeAllOpenLights({ actor: t.access('owner'), homeId: t.home.id });
  assert.equal(closed.closed_count, 2);
  assert.equal(closed.closed_shutters, 1, 'acik panjur cifti de asagi iner (v2)');
  assert.deepEqual(c.bridge.commands.map((x) => x.obj.cmd), ['all_lights_off', 'down']);
  assert.match(closed.command_id, FIRMWARE_ID);
  assert.equal((await h.one('SELECT status FROM peace_notification_logs WHERE home_id = $1', [t.home.id])).status, 'manual');
  await rejects(svc.closeAllOpenLights({ actor: t.access('guest'), homeId: t.home.id }), 403, 'FORBIDDEN');

  const diag = await svc.getSystemDiagnostic({ homeId: t.home.id });
  assert.equal(diag.cloud.db_connected, true);
  assert.equal(diag.devices.length, 1);
  assert.equal(diag.endpoint_count, 8);

  const lk = await svc.getLocalKey({ actor: t.access('owner'), homeId: t.home.id, deviceUuid: t.uuid });
  assert.equal(lk.local_key, c.secretBox.decrypt(t.dev.local_key_enc));
  assert.equal(await h.count('device_audit_logs', `event = 'local_key_read' AND home_id = $1`, [t.home.id]), 1);
  await rejects(svc.getLocalKey({ actor: t.access('guest'), homeId: t.home.id, deviceUuid: t.uuid }), 403, 'FORBIDDEN');
  const list = await svc.listDevices({ homeId: t.home.id });
  assert.equal(list.length, 1);
  assert.equal(list[0].device_uuid, t.uuid);

  const first = await h.one(`SELECT password_hash FROM mqtt_credentials WHERE home_id = $1 AND kind = 'device'`, [t.home.id]);
  const re = await svc.reissueDeviceCredential({ actor: t.access('owner'), homeId: t.home.id, deviceUuid: t.uuid });
  const second = await h.rows(`SELECT password_hash FROM mqtt_credentials WHERE home_id = $1 AND kind = 'device'`, [t.home.id]);
  assert.equal(second.length, 1);
  assert.notEqual(second[0].password_hash, first.password_hash);
  assert.ok(await c.bcrypt.compare(re.password, second[0].password_hash));
  assert.equal(re.mqtt_server, 'broker.test.invalid');

  clearBridge(c);
  const ok = await svc.sendCommand({ actor: t.access('owner'), homeId: t.home.id, deviceRef: t.uuid, command: { relay: 5, state: true, id: 'abc123' } });
  assert.equal(ok.delivered, true);
  assert.deepEqual(c.bridge.commands.map((x) => x.obj), [{ relay: 5, state: true, id: 'abc123' }]);
  await rejects(svc.sendCommand({ actor: t.access('owner'), homeId: t.home.id, deviceRef: t.uuid, command: { relay: 1, state: true } }), 400, 'VALIDATION');
  await rejects(svc.sendCommand({ actor: t.access('guest'), homeId: t.home.id, deviceRef: t.uuid, command: { cmd: 'all_lights_off' } }), 403, 'FORBIDDEN');
  await rejects(svc.sendCommand({ actor: t.access('owner'), homeId: t.home.id, deviceRef: t.uuid, command: { relay: 5, state: 'ON' } }), 400, 'VALIDATION');
  const other = await makeHome(c);
  await rejects(svc.sendCommand({ actor: t.access('owner'), homeId: t.home.id, deviceRef: other.uuid, command: { relay: 5, state: true } }), 404, 'NOT_FOUND');
  await c.q('UPDATE devices SET is_online = FALSE WHERE id = $1', [t.dev.id]);
  const e = await rejects(svc.sendCommand({ actor: t.access('owner'), homeId: t.home.id, deviceRef: t.uuid, command: { relay: 5, state: true } }), 409, 'DEVICE_OFFLINE');
  assert.equal(e.extra.device_online, false);
  await rejects(svc.closeAllOpenLights({ actor: t.access('owner'), homeId: t.home.id }), 409, 'DEVICE_OFFLINE');
});

// ================================================================================================
// Acil sifirlama, pano degisimi
// ================================================================================================
test('PG acil sifirlama (stoga don): yetki, yeni rastgele PIN, cleanup (kural/davet/servis/devir/log), kimlik iptali, kilit sifirlama, MQTT yan etkileri', { skip: SKIP }, async () => {
  const c = await getCtx();
  const h = c.helpers;
  const svc = c.deviceService;
  const t = await richHome(c);
  const stranger = await h.user({ role: 'service_user' });
  await rejects(svc.emergencyReset({ actor: actorOf(stranger), deviceUuid: t.uuid, confirmUid: t.uuid, reason: REASON }), 403, 'FORBIDDEN');
  await rejects(svc.emergencyReset({ actor: actorOf(t.staff), deviceUuid: t.uuid, confirmUid: 'AHBU-OTHER', reason: REASON }), 400, 'VALIDATION');
  await rejects(svc.emergencyReset({ actor: actorOf(t.staff), deviceUuid: t.uuid, confirmUid: t.uuid, reason: 'kisa' }), 400, 'VALIDATION');
  assert.equal((await h.one('SELECT status FROM device_inventory WHERE id = $1', [t.inv.id])).status, 'CLAIMED', 'reddedilen istek bir sey degistirmez');
  const oldKey = (await h.one('SELECT local_key_enc FROM devices WHERE id = $1', [t.dev.id])).local_key_enc;

  clearBridge(c);
  const r = await svc.emergencyReset({ actor: actorOf(t.staff), deviceUuid: t.uuid, confirmUid: t.uuid, reason: REASON });
  assert.equal(r.action, 'UNCLAIMED');
  assert.match(r.setup_pin, /^\d{6}$/);
  assert.equal(r.affected_users_count, 4);
  assert.equal(r.local_key_publish, 'published');
  assert.equal(r.child_lock_reset, 'published');
  assert.ok(!('local_key' in r), 'cihaza iletildiyse anahtar yanitta donmez');

  assert.equal(await h.count('home_users', 'home_id = $1', [t.home.id]), 0);
  const dev = await h.one('SELECT * FROM devices WHERE id = $1', [t.dev.id]);
  assert.equal(dev.home_id, null);
  assert.equal(dev.is_claimed, false);
  assert.equal(dev.child_lock_enabled, false);
  assert.equal(dev.setup_pin, null);
  assert.notEqual(dev.local_key_enc, oldKey);
  assert.equal(await h.count('endpoints', 'device_id = $1', [t.dev.id]), 0);
  assert.equal(await h.count('mqtt_credentials', 'home_id = $1', [t.home.id]), 0);
  assert.equal(await h.count('mqtt_acl', 'username LIKE $1', [`%${t.home.mqtt_username}%`]), 0, 'ACL satirlari CASCADE ile silinir');
  assert.equal(await h.count('scheduled_rules', 'home_id = $1', [t.home.id]), 0);
  assert.equal(await h.count('scheduled_rule_runs', 'home_id = $1', [t.home.id]), 0);
  assert.equal(await h.count('home_invitations', 'home_id = $1', [t.home.id]), 0);
  assert.equal(await h.count('service_tokens', 'home_id = $1 AND revoked_at IS NULL', [t.home.id]), 0, 'servis PIN iptal');
  assert.equal(await h.count('service_sessions', `home_id = $1 AND revoked_at IS NOT NULL AND revoked_reason = 'home_reset'`, [t.home.id]), 1);
  assert.equal(await h.count('peace_notification_logs', 'home_id = $1', [t.home.id]), 0);
  assert.equal(await h.count('home_transfers', `home_id = $1 AND status = 'PENDING'`, [t.home.id]), 0);
  assert.equal(await h.count('home_transfers', `home_id = $1 AND status = 'CANCELLED'`, [t.home.id]), 1);
  const home = await h.one('SELECT * FROM homes WHERE id = $1', [t.home.id]);
  assert.equal(home.child_lock_enabled, false);
  assert.equal(home.child_lock_requested, null);
  assert.equal(home.peace_notification_time, '23:30');

  const inv = await h.one('SELECT * FROM device_inventory WHERE id = $1', [t.inv.id]);
  assert.equal(inv.status, 'IN_STOCK');
  assert.equal(inv.claimed_home_id, null);
  assert.ok(c.pin.verifyPin(r.setup_pin, inv.pin_hash), 'donen PIN envanter ozetiyle dogrulanir');
  assert.equal(inv.local_key_enc, dev.local_key_enc);
  const log = await h.one('SELECT * FROM emergency_reset_logs WHERE device_uuid = $1', [t.uuid]);
  assert.equal(log.action, 'UNCLAIMED');
  assert.equal(log.installer_user_id, t.staff.id);
  assert.equal(log.ip_address, '203.0.113.9');
  assert.equal(log.previous_owner_ids.length, 4);
  assert.deepEqual(c.bridge.commands.map((x) => [x.obj.cmd, x.obj.enabled]), [['set_child_lock', false]]);
  assert.equal(c.bridge.sys.length, 1);
  assert.deepEqual(Object.keys(c.bridge.sys[0].obj).sort(), ['cmd', 'id', 'local_key']);
  assert.equal(c.secretBox.decrypt(inv.local_key_enc), c.bridge.sys[0].obj.local_key);
  assert.match(c.bridge.sys[0].obj.local_key, /^[\x21-\x7E]{8,32}$/);
  assert.deepEqual(c.bridge.cleared, [t.home.mqtt_username]);
  // bu harness'ta EMQX yonetim API'si YOK: baglanti atma atlanir -> tek, beklenen uyari
  assert.deepEqual(r.warnings, ['EMQX yönetim API ayarı yok; açık MQTT bağlantıları atılamadı (kimlikler silindi).']);

  await rejects(svc.emergencyReset({ actor: actorOf(t.staff), deviceUuid: t.uuid, confirmUid: t.uuid, reason: REASON }), 403, 'FORBIDDEN');
  const root = await h.user({ role: 'super_user' });
  const r2 = await svc.emergencyReset({ actor: actorOf(root), deviceUuid: t.uuid, confirmUid: t.uuid, reason: REASON });
  assert.equal(r2.action, 'UNCLAIMED');
  assert.equal(r2.local_key_publish, 'skipped', 'evi olmayan (stoktaki) cihaz: yayin konusu yok');
  assert.equal(r2.local_key.length, 16);
});

test('PG acil sifirlama (yeni sahibe devir) + REVOKED/SUSPENDED yalniz super', { skip: SKIP }, async () => {
  const c = await getCtx();
  const h = c.helpers;
  const svc = c.deviceService;
  let t = await richHome(c);
  const newOwner = await h.user();
  const root = await h.user({ role: 'super_user' });
  const r = await svc.emergencyReset({ actor: actorOf(root), deviceUuid: t.uuid, confirmUid: t.uuid, reason: REASON, newOwnerIdentifier: newOwner.email });
  assert.equal(r.action, 'REASSIGNED');
  assert.equal(r.new_owner.id, newOwner.id);
  assert.equal(r.device_credential.mqtt_server, 'broker.test.invalid');
  assert.deepEqual((await h.rows('SELECT user_id, role FROM home_users WHERE home_id = $1', [t.home.id])).map((m) => [m.user_id, m.role]), [[newOwner.id, 'owner']]);
  const dev = await h.one('SELECT * FROM devices WHERE id = $1', [t.dev.id]);
  assert.equal(dev.home_id, t.home.id);
  assert.equal(dev.claimed_by, newOwner.id);
  assert.equal(dev.is_commissioned, false);
  assert.equal(dev.child_lock_enabled, false);
  assert.equal(await h.count('endpoints', 'device_id = $1', [t.dev.id]), 8, 'kanallar varsayilanla yeniden uretilir');
  assert.deepEqual((await h.rows('SELECT kind FROM mqtt_credentials WHERE home_id = $1', [t.home.id])).map((x) => x.kind), ['device']);
  assert.ok(await c.bcrypt.compare(r.device_credential.password, (await h.one('SELECT password_hash FROM mqtt_credentials WHERE home_id = $1', [t.home.id])).password_hash));
  const inv = await h.one('SELECT status, claimed_by_user_id, pin_hash FROM device_inventory WHERE id = $1', [t.inv.id]);
  assert.equal(inv.status, 'CLAIMED');
  assert.equal(inv.claimed_by_user_id, newOwner.id);
  assert.equal(inv.pin_hash, 'CLAIMED_BURNED_PIN');

  t = await richHome(c);
  const newOwner2 = await h.user();
  const r2 = await svc.emergencyReset({ actor: actorOf(t.staff), deviceUuid: t.uuid, confirmUid: t.uuid, reason: REASON, newOwnerIdentifier: newOwner2.email });
  assert.equal(r2.action, 'REASSIGNED');
  const sm = (await h.rows('SELECT user_id, role, installer_expires_at FROM home_users WHERE home_id = $1', [t.home.id])).find((m) => m.role === 'service_user');
  assert.equal(sm.user_id, t.staff.id);
  const hours = (new Date(sm.installer_expires_at) - Date.now()) / 3600000;
  assert.ok(hours > 71 && hours <= 72.01, `servis uyeligi: ${hours} saat`);

  const t3 = await richHome(c);
  await rejects(svc.emergencyReset({ actor: actorOf(t3.staff), deviceUuid: t3.uuid, confirmUid: t3.uuid, reason: REASON, newOwnerIdentifier: t3.staff.email }), 403, 'FORBIDDEN');
  const otherStaff = await h.user({ role: 'service_user' });
  await rejects(svc.emergencyReset({ actor: actorOf(t3.staff), deviceUuid: t3.uuid, confirmUid: t3.uuid, reason: REASON, newOwnerIdentifier: otherStaff.email }), 403, 'FORBIDDEN');
  await rejects(svc.emergencyReset({ actor: actorOf(t3.staff), deviceUuid: t3.uuid, confirmUid: t3.uuid, reason: REASON, newOwnerIdentifier: `yok-${ETAG}@wpb-live.invalid` }), 404, 'NOT_FOUND');

  for (const status of ['REVOKED', 'SUSPENDED']) {
    const x = await richHome(c);
    await c.q('UPDATE device_inventory SET status = $2 WHERE id = $1', [x.inv.id, status]);
    await rejects(svc.emergencyReset({ actor: actorOf(x.staff), deviceUuid: x.uuid, confirmUid: x.uuid, reason: REASON }), 403, 'FORBIDDEN');
    assert.equal(await h.count('home_users', 'home_id = $1', [x.home.id]), 4, 'hicbir sey silinmedi');
    assert.equal((await svc.emergencyReset({ actor: actorOf(root), deviceUuid: x.uuid, confirmUid: x.uuid, reason: REASON })).action, 'UNCLAIMED');
    assert.equal((await h.one('SELECT status FROM device_inventory WHERE id = $1', [x.inv.id])).status, 'IN_STOCK');
  }
});

test('PG pano degisimi: yanlis PIN sayaci kalici, kanallar/adlar/sureler tasinir (stale kanal UNIQUE cakismasi), eski REVOKED, yeni kimlik, kilit niyeti', { skip: SKIP }, async () => {
  const c = await getCtx();
  const h = c.helpers;
  const t = await makeHome(c);
  const eps = await h.rows('SELECT id, channel_index FROM endpoints WHERE device_id = $1 ORDER BY channel_index', [t.dev.id]);
  await c.q(`UPDATE endpoints SET name = 'Salon Avize' WHERE id = $1`, [eps.find((e) => e.channel_index === 5).id]);
  await c.q('UPDATE endpoints SET shutter_duration_sec = 24 WHERE device_id = $1 AND shutter_pair_index = 1', [t.dev.id]);
  await c.q('UPDATE devices SET child_lock_enabled = TRUE WHERE id = $1', [t.dev.id]);
  await c.q('UPDATE homes SET child_lock_enabled = TRUE WHERE id = $1', [t.home.id]);

  const newInv = await h.inventory({ pinPlain: '999111' });
  const NEW = newInv.device_uuid;
  const otherHome = await h.one(`INSERT INTO homes (name, mqtt_username) VALUES ($1, 'h_' || substr(md5(random()::text), 1, 16)) RETURNING id`, [`WPBL-${TAG}-${++seq}`]);
  const staleDev = await h.one(`INSERT INTO devices (home_id, device_uuid, mac_address, is_claimed) VALUES ($1, $2, $3, FALSE) RETURNING id`, [otherHome.id, NEW, newInv.mac_address]);
  await c.q(`INSERT INTO endpoints (home_id, device_id, channel_index, name, type) VALUES ($1, $2, 1, 'Stale 1', 'light'), ($1, $2, 2, 'Stale 2', 'light')`, [otherHome.id, staleDev.id]);
  await c.q('UPDATE devices SET home_id = NULL WHERE id = $1', [staleDev.id]); // yetim ama kanallari duruyor

  const args = { homeId: t.home.id, oldDeviceUuid: t.uuid, newDeviceUuid: NEW, reason: 'Pano yandi' };
  await rejects(c.deviceService.replaceBoard({ actor: t.access('owner'), ...args, setupPin: '000000' }), 403, 'FORBIDDEN');
  assert.equal((await h.one('SELECT failed_attempts FROM device_inventory WHERE id = $1', [newInv.id])).failed_attempts, 1, 'yanlis PIN sayaci COMMIT edilir');
  await rejects(c.deviceService.replaceBoard({ actor: t.access('resident'), ...args, setupPin: '999111' }), 403, 'FORBIDDEN');

  const r = await c.deviceService.replaceBoard({ actor: t.access('owner'), ...args, setupPin: '999111' });
  assert.equal(r.migrated_endpoints_count, 8);
  assert.equal(r.device_credential.mqtt_server, 'broker.test.invalid');
  assert.equal(r.child_lock.sync, 'pending_device_online');
  assert.deepEqual(r.shutter_runtimes.map((x) => [x.shutter, x.sec]).sort(), [[1, 24], [2, 20]]);
  const newDev = await h.one('SELECT * FROM devices WHERE device_uuid = $1', [NEW]);
  assert.equal(newDev.home_id, t.home.id);
  assert.equal(newDev.claimed_by, t.owner.id);
  assert.equal(newDev.id, staleDev.id, 'yetim kayit yeniden kullanilir (ON CONFLICT device_uuid)');
  const oldDev = await h.one('SELECT home_id, is_claimed, device_status FROM devices WHERE id = $1', [t.dev.id]);
  assert.equal(oldDev.home_id, null);
  assert.equal(oldDev.device_status, 'REPLACED_DAMAGED');
  const moved = await h.rows('SELECT channel_index, name, shutter_duration_sec FROM endpoints WHERE device_id = $1 ORDER BY channel_index', [newDev.id]);
  assert.equal(moved.length, 8, 'stale kanallar silindi, 8 kanal tasindi');
  assert.equal(moved.find((e) => e.channel_index === 5).name, 'Salon Avize');
  assert.equal(moved.find((e) => e.channel_index === 1).shutter_duration_sec, 24);
  assert.equal(await h.count('endpoints', 'device_id = $1', [t.dev.id]), 0);
  assert.equal((await h.one('SELECT status FROM device_inventory WHERE device_uuid = $1', [t.uuid])).status, 'REVOKED');
  const ninv = await h.one('SELECT status, pin_hash, claimed_home_id FROM device_inventory WHERE id = $1', [newInv.id]);
  assert.equal(ninv.status, 'CLAIMED');
  assert.equal(ninv.pin_hash, 'CLAIMED_BURNED_PIN');
  assert.equal(ninv.claimed_home_id, t.home.id);
  const creds = await h.rows(`SELECT device_id, password_hash FROM mqtt_credentials WHERE home_id = $1 AND kind = 'device'`, [t.home.id]);
  assert.equal(creds.length, 1);
  assert.equal(creds[0].device_id, newDev.id);
  assert.ok(await c.bcrypt.compare(r.device_credential.password, creds[0].password_hash));
  const home = await h.one('SELECT child_lock_requested, child_lock_requested_by FROM homes WHERE id = $1', [t.home.id]);
  assert.equal(home.child_lock_requested, true);
  assert.equal(home.child_lock_requested_by, t.owner.id);
  const rl = await h.one('SELECT * FROM device_replacement_logs WHERE home_id = $1', [t.home.id]);
  assert.equal(rl.old_device_uuid, t.uuid);
  assert.equal(rl.endpoints_migrated_count, 8);
  assert.equal(rl.replaced_by_user_id, t.owner.id);
  assert.equal(rl.config_snapshot.endpoints.length, 8);
  assert.equal(rl.config_snapshot.runtime_sync, undefined, 'gunluk anlik goruntusu "bekliyor" isareti tasimaz');

  // S2 (plan §5d-3): bekleyen panjur suresi isareti gercek JSONB kolonunda + kopru uzlastiricisi SQL'i bunu okur
  const marker = await h.one(
    "SELECT config_snapshot ->> 'runtime_sync' AS s, config_snapshot ->> 'home_id' AS home_id, config_snapshot ->> 'replaced_at' AS at FROM devices WHERE id = $1",
    [newDev.id]
  );
  assert.equal(marker.s, 'pending');
  assert.equal(marker.home_id, t.home.id);
  assert.ok(Number.isFinite(Date.parse(marker.at)));
  const { SQL: reconcileSql } = require('../../src/services/device_reconciler');
  await c.q('UPDATE devices SET is_online = TRUE, last_seen_at = NOW() WHERE id = $1', [newDev.id]);
  const pendingRows = (await c.q(reconcileSql.runtimePending, [t.home.mqtt_username, 120])).rows;
  assert.equal(pendingRows.length, 1);
  assert.equal(pendingRows[0].device_id, newDev.id);
  assert.equal(pendingRows[0].marker_home_id, t.home.id);
  assert.equal(pendingRows[0].device_count, 1);
  assert.equal(pendingRows[0].live, true);
  assert.deepEqual((await c.q(reconcileSql.runtimeShutters, [newDev.id])).rows.map((x) => [x.pair, x.sec]), [[1, 24], [2, 20]]);
  const cl = (await c.q(reconcileSql.childLock, [t.home.mqtt_username, 120])).rows;
  assert.equal(cl.length, 1);
  assert.equal(cl[0].requested, true, 'pano degisimi cocuk kilidi niyetini kaydetti');
  assert.equal(cl[0].child_lock_enabled, false, 'yeni pano varsayilan olarak kilitsiz');
  await rejects(c.deviceService.replaceBoard({ actor: t.access('owner'), ...args, setupPin: '999111' }), 409, 'CONFLICT'); // yeni pano artik CLAIMED
});

// ================================================================================================
// MQTT kimlik servisi, migration 021 (FK / tetikleyici)
// ================================================================================================
test('PG MQTT kimlikleri: 10 kimlik siniri, sure, gecmis bitis 403, sure dolan temizlik, iptal (ACL CASCADE), cihaz kimligi rotasyonu (ES ZAMANLI dahil), es zamanli uretim', { skip: SKIP }, async () => {
  const c = await getCtx();
  const h = c.helpers;
  const cr = c.credentials;
  const t = await makeHome(c);
  const u = await h.user();
  await c.q(`INSERT INTO home_users (home_id, user_id, role) VALUES ($1, $2, 'resident')`, [t.home.id, u.id]);
  let evicted = 0;
  for (let i = 0; i < 12; i++) {
    const r = await cr.issueUserCredential({ homeId: t.home.id, userId: u.id });
    evicted += r.evicted_usernames.length;
    assert.match(r.username, new RegExp(`^a_${t.home.mqtt_username}_[0-9a-f]{10}$`));
  }
  assert.equal(await h.count('mqtt_credentials', `home_id = $1 AND user_id = $2 AND kind = 'app'`, [t.home.id, u.id]), 10);
  assert.equal(evicted, 2);
  assert.deepEqual((await h.rows('SELECT DISTINCT action FROM mqtt_acl a JOIN mqtt_credentials m ON m.id = a.credential_id WHERE m.user_id = $1', [u.id])).map((x) => x.action), ['subscribe'], 'uygulama kimligi yalniz abone');

  const ttl = async (validUntil) => new Date((await cr.issueUserCredential({ homeId: t.home.id, userId: u.id, validUntil })).expires_at).getTime() - Date.now();
  assert.ok(Math.abs((await ttl(null)) - 12 * 3600000) < 5000);
  assert.ok(Math.abs((await ttl(new Date(Date.now() + 90 * 60000))) - 90 * 60000) < 5000);
  await rejects(cr.issueUserCredential({ homeId: t.home.id, userId: u.id, validUntil: new Date(Date.now() - 1000) }), 403, 'GUEST_EXPIRED');

  await c.q(`UPDATE mqtt_credentials SET expires_at = NOW() - interval '1 minute' WHERE id IN (SELECT id FROM mqtt_credentials WHERE home_id = $1 AND user_id = $2 AND kind = 'app' LIMIT 2)`, [t.home.id, u.id]);
  assert.equal((await cr.cleanupExpired()).deleted >= 2, true);

  const rv = await cr.revokeUserAccess({ homeId: t.home.id, userId: u.id });
  assert.ok(rv.revoked >= 8);
  assert.equal(await h.count('mqtt_credentials', 'home_id = $1 AND user_id = $2', [t.home.id, u.id]), 0);
  assert.equal(await h.count('mqtt_credentials', `home_id = $1 AND kind = 'device'`, [t.home.id]), 1, 'cihaz kimligi dokunulmadi');
  assert.equal(await h.count('mqtt_acl', `username LIKE $1`, [`a_${t.home.mqtt_username}_%`]), 0, 'ACL satirlari CASCADE');

  const before = await h.one(`SELECT id FROM mqtt_credentials WHERE home_id = $1 AND kind = 'device'`, [t.home.id]);
  const d = await cr.issueDeviceCredential({ homeId: t.home.id, deviceId: t.dev.id });
  assert.deepEqual(d.previous_usernames, [`d_${t.home.mqtt_username}`]);
  const after = await h.rows(`SELECT id FROM mqtt_credentials WHERE home_id = $1 AND kind = 'device'`, [t.home.id]);
  assert.equal(after.length, 1);
  assert.notEqual(after[0].id, before.id);
  assert.equal(await h.count('mqtt_acl', 'username = $1', [`d_${t.home.mqtt_username}`]), 4);

  // ES ZAMANLI rotasyon: advisory kilit olmadan biri UNIQUE (23505) ihlaliyle dusuyordu (gercek PostgreSQL'de gozlendi)
  const settled = await Promise.allSettled([1, 2, 3, 4].map(() => cr.issueDeviceCredential({ homeId: t.home.id, deviceId: t.dev.id })));
  assert.deepEqual(settled.filter((s) => s.status === 'rejected').map((s) => `${s.reason.code || ''} ${s.reason.message}`), [], 'es zamanli rotasyonlar sirayla basarili olmali');
  assert.equal(await h.count('mqtt_credentials', `home_id = $1 AND kind = 'device'`, [t.home.id]), 1);

  const u2 = await h.user();
  await c.q(`INSERT INTO home_users (home_id, user_id, role) VALUES ($1, $2, 'resident')`, [t.home.id, u2.id]);
  const s2 = await Promise.allSettled(Array.from({ length: 12 }, () => cr.issueUserCredential({ homeId: t.home.id, userId: u2.id })));
  assert.ok(s2.every((s) => s.status === 'fulfilled'), s2.filter((s) => s.status === 'rejected').map((s) => `${s.reason.code || ''} ${s.reason.message}`).join(' | '));
  const n2 = await h.count('mqtt_credentials', `home_id = $1 AND user_id = $2 AND kind = 'app'`, [t.home.id, u2.id]);
  assert.ok(n2 >= 10 && n2 <= 12, `es zamanli uretimde sayi: ${n2}`);
  await rejects(cr.issueUserCredential({ homeId: '00000000-0000-4000-8000-000000000000', userId: u.id }), 404, 'NOT_FOUND');
});

test('PG 021 FK/tetikleyici: kullanici silinince cihaz/denetim kaydi kalir (SET NULL); ev silinince envanter SUSPENDED + cihaz ORPHANED + kanal/kimlik CASCADE; WP-B tablolarinda silmeyi engelleyen FK yok', { skip: SKIP }, async () => {
  const c = await getCtx();
  const h = c.helpers;
  const a = await makeHome(c);
  await c.deviceService.setChildLock({ actor: a.access('owner'), homeId: a.home.id, enabled: true }); // denetim satiri (actor = owner)
  await c.q('DELETE FROM home_users WHERE user_id = $1', [a.owner.id]);
  await c.q('DELETE FROM users WHERE id = $1', [a.owner.id]);
  assert.equal((await h.one('SELECT claimed_by FROM devices WHERE id = $1', [a.dev.id])).claimed_by, null);
  const aud = await h.rows('SELECT actor_user_id FROM device_audit_logs WHERE home_id = $1', [a.home.id]);
  assert.ok(aud.length >= 2 && aud.every((x) => x.actor_user_id === null), 'denetim kayitlari kalir, actor NULL');

  const b = await makeHome(c);
  await c.q('DELETE FROM homes WHERE id = $1', [b.home.id]);
  const inv = await h.one('SELECT status, claimed_home_id FROM device_inventory WHERE id = $1', [b.inv.id]);
  assert.equal(inv.status, 'SUSPENDED');
  assert.equal(inv.claimed_home_id, null);
  const dev = await h.one('SELECT home_id, is_claimed, device_status FROM devices WHERE id = $1', [b.dev.id]);
  assert.equal(dev.home_id, null);
  assert.equal(dev.is_claimed, false);
  assert.equal(dev.device_status, 'ORPHANED');
  assert.equal(await h.count('endpoints', 'device_id = $1', [b.dev.id]), 0);
  assert.equal(await h.count('mqtt_credentials', 'username = $1', [`d_${b.home.mqtt_username}`]), 0);
  const u = await h.user();
  await rejects(c.deviceService.claimDevice({ actor: h.act(u), deviceUuid: b.uuid, setupPin: '135790' }), 403, 'FORBIDDEN');
  const root = await h.user({ role: 'super_user' });
  const rr = await c.deviceService.emergencyReset({ actor: actorOf(root), deviceUuid: b.uuid, confirmUid: b.uuid, reason: REASON });
  assert.equal(rr.action, 'UNCLAIMED');
  const again = await c.deviceService.claimDevice({ actor: h.act(await h.user()), deviceUuid: b.uuid, setupPin: rr.setup_pin, homeName: `WPBL-${TAG}-${++seq}` });
  assert.equal(again.device_uuid, b.uuid, 'sifirlama sonrasi yeni PIN ile yeniden sahiplenilebilir');

  const mine = new Set(['devices', 'device_inventory', 'endpoints', 'mqtt_credentials', 'mqtt_acl', 'commissioning_logs', 'commissioning_checks', 'emergency_reset_logs', 'device_replacement_logs', 'device_audit_logs', 'device_claim_otps']);
  const fks = await h.rows(
    `SELECT con.conrelid::regclass::text AS tbl, att.attname AS col, con.confrelid::regclass::text AS ref, con.confdeltype AS del
       FROM pg_constraint con JOIN pg_attribute att ON att.attrelid = con.conrelid AND att.attnum = ANY (con.conkey)
      WHERE con.contype = 'f' AND con.confrelid IN ('users'::regclass, 'homes'::regclass, 'devices'::regclass) ORDER BY 1, 2`
  );
  const blocking = fks.filter((f) => (f.del === 'a' || f.del === 'r') && mine.has(f.tbl)).map((f) => `${f.tbl}.${f.col}->${f.ref}`);
  assert.deepEqual(blocking, [], 'WP-B tablolarinda silmeyi engelleyen FK');
});
