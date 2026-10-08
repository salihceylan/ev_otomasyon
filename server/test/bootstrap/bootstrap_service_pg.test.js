'use strict';

// CONTRACTS §3f: device_bootstrap_service GERCEK PostgreSQL'de (yalitilmis gecici veritabani, migration 036 dahil).
//   - sahiplenilmis kart + dogru imza -> 200 {status:"ok", mqtt:{host,port,username,password}}; mqtt_credentials satiri
//     bcrypt ozetiyle (parola dogrulanir), ACL; denetim `device_bootstrap` (anahtar / parola YOK)
//   - sahiplenilmemis kart (envanter / evsiz cihaz satiri) -> 202 {status:"pending"}
//   - bilinmeyen / yanlis imza / zaman kaymasi / nonce tekrari / askida / iptal / bozuk govde -> 401 AYNI govde
//   - bekleyen yerel anahtarla dogrulama -> anahtar asil anahtar yapilir (uzlastirici ile ayni takas)
//   - inceleme: ONCEKI anahtar hicbir yolda gecmez (terfi, pano-6 rotasyonu + uzlastirici takasi, acil sifirlama stoga
//     donus): eski anahtari bilen kisi 401 alir, sunucu anahtari geri alinmaz; stoga donusten sonraki claim YENI anahtari alir
// EV_PG_TEST_URL yoksa ATLANIR.

const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const bcrypt = require('bcryptjs');

const { PG_SKIP, open } = require('../templates/_pg_isolated');
const { setTestEnv } = require('../devices/_world');

test('bootstrap servisi gercek PG', { skip: PG_SKIP }, async () => {
  const env = await open('t036boot');
  if (!env) return;
  setTestEnv();
  const { db } = env;
  const logs = [];
  const logger = { log: (...a) => logs.push(a.join(' ')), warn: (...a) => logs.push(a.join(' ')), error: (...a) => logs.push(a.join(' ')) };
  try {
    const pin = require('../../src/utils/pin');
    const secretBox = require('../../src/utils/secret_box');
    const { DeviceService } = require('../../src/services/device_service');
    const { MqttCredentialService } = require('../../src/services/mqtt_credential_service');
    const { DeviceBootstrapService, DENIED_BODY, signBootstrap } = require('../../src/services/device_bootstrap_service');
    const credentials = new MqttCredentialService({ db, logger, env: process.env });
    let nowMs = Date.parse('2026-10-08T12:00:00Z');
    const svc = new DeviceBootstrapService({ db, credentials, secretBox, logger, now: () => nowMs });
    const deviceService = new DeviceService({
      db,
      mqttBridge: { isConnected: () => true, async publishCommand() {}, async publishSys() {}, async publishToTopic() {}, async clearRetained() {} },
      mqttCredentials: credentials,
      mailer: { async sendClaimOtpEmail() { return { sent: true }; } },
      inviteCustomer: async () => ({ sent: true }),
      env: process.env,
    });
    const owner = (await db.query("INSERT INTO users (full_name, email, password_hash, role) VALUES ('O', 'o@boot036.test', 'x', 'user') RETURNING id")).rows[0];
    const keys = {};
    let mac = 0;
    const inv = async (uuid, status = 'IN_STOCK') => {
      keys[uuid] = `Anahtar-${uuid}-${crypto.randomBytes(4).toString('hex')}`;
      mac += 1;
      await db.query(
        "INSERT INTO device_inventory (device_uuid, mac_address, pin_hash, model, status, local_key_enc) VALUES ($1, $2, $3, 'ESP32-S3-POE-ETH-8DI-8RO', $4, $5)",
        [uuid, `E8:F6:0A:36:00:${String(mac).padStart(2, '0')}`, pin.hashPin('135790'), status, secretBox.encrypt(keys[uuid])]
      );
    };
    const ts = () => Math.floor(nowMs / 1000);
    const req = (uuid, { key = keys[uuid], t = ts(), nonce = crypto.randomBytes(16).toString('hex') } = {}) => ({
      device_uuid: uuid, ts: t, nonce, fw: '1.3.0', sig: signBootstrap(key, uuid, t, nonce),
    });
    const call = (body) => svc.bootstrap({ body, ip: '203.0.113.5' });

    // --- sahiplenilmemis: 202
    await inv('AHBU-B036-0001');
    assert.deepEqual(await call(req('AHBU-B036-0001')), { http: 202, body: { status: 'pending' } });

    // --- sahiplenilmis: 200 + kullanilabilir kimlik
    const claim = await deviceService.claimDevice({ actor: { userId: owner.id, globalRole: 'user', ip: '127.0.0.1' }, deviceUuid: 'AHBU-B036-0001', setupPin: '135790', homeName: 'Ev' });
    const r = await call(req('AHBU-B036-0001'));
    assert.equal(r.http, 200);
    assert.deepEqual(Object.keys(r.body).sort(), ['mqtt', 'status']);
    assert.equal(r.body.status, 'ok');
    assert.deepEqual(Object.keys(r.body.mqtt).sort(), ['host', 'password', 'port', 'username']);
    assert.equal(r.body.mqtt.host, process.env.MQTT_PUBLIC_HOST);
    assert.equal(r.body.mqtt.port, Number(process.env.MQTT_PUBLIC_PORT));
    const cred = (await db.query("SELECT username, password_hash, device_id FROM mqtt_credentials WHERE home_id = $1 AND kind = 'device'", [claim.home_id])).rows;
    assert.equal(cred.length, 1, 'eski cihaz kimligi silindi, tek kimlik');
    assert.equal(cred[0].username, r.body.mqtt.username);
    assert.ok(await bcrypt.compare(r.body.mqtt.password, cred[0].password_hash), 'parola bcrypt ozetiyle dogrulanir');
    assert.notEqual(cred[0].password_hash, r.body.mqtt.password);
    const acl = await db.query("SELECT topic FROM mqtt_acl WHERE username = $1 ORDER BY topic", [cred[0].username]);
    assert.ok(acl.rows.some((x) => x.topic.endsWith('/state')));
    const audit = (await db.query("SELECT event, home_id, actor_role, ip_address, details::text AS d FROM device_audit_logs WHERE event = 'device_bootstrap' ORDER BY id")).rows;
    assert.equal(audit.length, 2, '202 ve 200 denetlenir');
    assert.equal(audit[1].home_id, claim.home_id);
    assert.equal(audit[1].ip_address, '203.0.113.5');
    const allAudit = JSON.stringify((await db.query('SELECT * FROM device_audit_logs')).rows);
    assert.ok(!allAudit.includes(r.body.mqtt.password), 'parola denetimde yok');
    assert.ok(!allAudit.includes(keys['AHBU-B036-0001']), 'anahtar denetimde yok');

    // --- 401: hepsi AYNI govde
    const denied = { http: 401, body: DENIED_BODY };
    const good = req('AHBU-B036-0001');
    assert.equal((await call(good)).http, 200);
    assert.deepEqual(await call(good), denied, 'nonce tekrari');
    assert.deepEqual(await call(req('AHBU-B036-0001', { key: 'yanlis-anahtar' })), denied, 'yanlis imza');
    assert.deepEqual(await call(req('AHBU-B036-0001', { t: ts() - 301 })), denied, 'zaman kaymasi geri');
    assert.deepEqual(await call(req('AHBU-B036-0001', { t: ts() + 301 })), denied, 'zaman kaymasi ileri');
    assert.equal((await call(req('AHBU-B036-0001', { t: ts() + 299 }))).http, 200, 'sinir icinde');
    assert.deepEqual(await call(req('AHBU-YOK-0001', { key: 'x' })), denied, 'bilinmeyen kart');
    assert.deepEqual(await call({ device_uuid: 'AHBU-B036-0001' }), denied, 'bozuk govde');
    await inv('AHBU-B036-0002', 'SUSPENDED');
    await inv('AHBU-B036-0003', 'REVOKED');
    assert.deepEqual(await call(req('AHBU-B036-0002')), denied, 'askida');
    assert.deepEqual(await call(req('AHBU-B036-0003')), denied, 'iptal');

    // Nonce: baska kartta ayni nonce kullanilabilir; suresi gecmis nonce kayitlari temizlenir
    const n = crypto.randomBytes(16).toString('hex');
    await inv('AHBU-B036-0004');
    assert.equal((await call(req('AHBU-B036-0004', { nonce: n }))).http, 202);
    assert.equal((await call(req('AHBU-B036-0001', { nonce: n }))).http, 200);
    nowMs += 20 * 60 * 1000;
    await call(req('AHBU-B036-0004'));
    const left = (await db.query("SELECT COUNT(*)::int AS n FROM device_bootstrap_nonces WHERE device_uuid = 'AHBU-B036-0004'")).rows[0].n;
    assert.equal(left, 1, 'eski nonce temizlendi, yenisi kaldi');

    // --- bekleyen anahtarla dogrulama -> asil anahtar yapilir
    const pendingKey = 'BekleyenAnahtar-036';
    const pendingEnc = secretBox.encrypt(pendingKey);
    await db.query(
      "UPDATE devices SET local_key_pending_enc = $1, local_key_pending_at = NOW() WHERE device_uuid = 'AHBU-B036-0001'",
      [pendingEnc]
    );
    const rp = await call(req('AHBU-B036-0001', { key: pendingKey }));
    assert.equal(rp.http, 200);
    const dev = (await db.query("SELECT local_key_enc, local_key_pending_enc, local_key_pending_at FROM devices WHERE device_uuid = 'AHBU-B036-0001'")).rows[0];
    assert.equal(secretBox.decrypt(dev.local_key_enc), pendingKey);
    assert.equal(dev.local_key_pending_enc, null);
    assert.equal(dev.local_key_pending_at, null);
    const invRow = (await db.query("SELECT local_key_enc FROM device_inventory WHERE device_uuid = 'AHBU-B036-0001'")).rows[0];
    assert.equal(secretBox.decrypt(invRow.local_key_enc), pendingKey);
    const rot = (await db.query("SELECT details FROM device_audit_logs WHERE event = 'local_key_rotated' AND device_uuid = 'AHBU-B036-0001'")).rows;
    assert.equal(rot.length, 1);
    assert.equal(rot[0].details.via, 'bootstrap');
    // --- inceleme: terfiden sonra ESKI anahtar (or. cikarilan uyenin bildigi) GECMEZ; sunucu anahtari geri alinmaz
    const credBefore = (await db.query("SELECT password_hash FROM mqtt_credentials WHERE home_id = $1 AND kind = 'device'", [claim.home_id])).rows[0];
    assert.deepEqual(await call(req('AHBU-B036-0001')), denied, 'terfiden sonra eski anahtar 401');
    const devOld = (await db.query("SELECT local_key_enc, local_key_pending_enc FROM devices WHERE device_uuid = 'AHBU-B036-0001'")).rows[0];
    assert.equal(secretBox.decrypt(devOld.local_key_enc), pendingKey, 'gecerli anahtar degismedi');
    assert.equal(devOld.local_key_pending_enc, null);
    const invOld = (await db.query("SELECT local_key_enc FROM device_inventory WHERE device_uuid = 'AHBU-B036-0001'")).rows[0];
    assert.equal(secretBox.decrypt(invOld.local_key_enc), pendingKey, 'envanter eski anahtara donmedi');
    const credAfter = (await db.query("SELECT password_hash FROM mqtt_credentials WHERE home_id = $1 AND kind = 'device'", [claim.home_id])).rows[0];
    assert.equal(credAfter.password_hash, credBefore.password_hash, 'eski anahtara cihaz kimligi uretilmedi (pano atilmadi)');
    assert.equal((await db.query("SELECT COUNT(*)::int AS n FROM device_audit_logs WHERE event = 'local_key_reverted'")).rows[0].n, 0);
    assert.equal((await call(req('AHBU-B036-0001', { key: pendingKey }))).http, 200, 'yeni anahtar gecmeye devam eder');
    const prevCols = (await db.query(
      "SELECT column_name FROM information_schema.columns WHERE table_name = 'devices' AND column_name LIKE 'local_key_prev%'"
    )).rows;
    assert.deepEqual(prevCols, [], 'onceki anahtar kolonu yok');

    // --- pano-6: uye cikarilinca rotasyon -> (eski firmware) uzlastirici PUBACK takasi -> eski anahtar 401
    {
      const { LocalKeyRotation } = require('../../src/services/local_key_rotation');
      const { SQL } = require('../../src/services/device_reconciler');
      const rotation = new LocalKeyRotation({ db, secretBox, logger, requestReconcile: () => {} });
      await inv('AHBU-B036-0005');
      const c5 = await deviceService.claimDevice({ actor: { userId: owner.id, globalRole: 'user', ip: '127.0.0.1' }, deviceUuid: 'AHBU-B036-0005', setupPin: '135790', homeName: 'Ev5' });
      assert.equal((await call(req('AHBU-B036-0005'))).http, 200, 'rotasyondan once mevcut anahtar gecer');
      const sch = await db.withTransaction((tx) => rotation.scheduleRotation(c5.home_id, { tx, reason: 'member_removed' }));
      assert.equal(sch.scheduled, true);
      const d5 = (await db.query("SELECT id, local_key_pending_enc FROM devices WHERE device_uuid = 'AHBU-B036-0005'")).rows[0];
      await db.withTransaction(async (tx) => {
        await tx.query(SQL.localKeyLockInventory, ['AHBU-B036-0005']);
        assert.equal((await tx.query(SQL.localKeySwap, [d5.id, d5.local_key_pending_enc])).rowCount, 1);
        await tx.query(SQL.localKeyInventory, ['AHBU-B036-0005', d5.local_key_pending_enc]);
      });
      assert.deepEqual(await call(req('AHBU-B036-0005')), denied, 'cikarilan uyenin bildigi eski anahtar 401');
      assert.equal((await call(req('AHBU-B036-0005', { key: secretBox.decrypt(d5.local_key_pending_enc) }))).http, 200);
      const k5 = (await db.query("SELECT local_key_enc FROM devices WHERE device_uuid = 'AHBU-B036-0005'")).rows[0];
      assert.equal(k5.local_key_enc, d5.local_key_pending_enc, 'yeni anahtar gecerli kaldi');
    }

    // --- acil sifirlama STOGA DONUS: eski anahtar envanterde kalmaz; sonraki musterinin claim'i YENI anahtari alir
    {
      const root = (await db.query("INSERT INTO users (full_name, email, password_hash, role) VALUES ('R', 'r@boot036.test', 'x', 'super_user') RETURNING id")).rows[0];
      const buyer = (await db.query("INSERT INTO users (full_name, email, password_hash, role) VALUES ('B', 'b@boot036.test', 'x', 'user') RETURNING id")).rows[0];
      await inv('AHBU-B036-0006');
      const c6 = await deviceService.claimDevice({ actor: { userId: owner.id, globalRole: 'user', ip: '127.0.0.1' }, deviceUuid: 'AHBU-B036-0006', setupPin: '135790', homeName: 'Ev6' });
      const er = await deviceService.emergencyReset({
        actor: { userId: root.id, globalRole: 'super_user', ip: '127.0.0.1' },
        deviceUuid: 'AHBU-B036-0006', confirmUid: 'AHBU-B036-0006', reason: 'Kiraci ulasilamiyor, daire teslim alindi',
      });
      assert.equal(er.action, 'UNCLAIMED');
      assert.ok(secretBox.isValidLocalKey(er.local_key), 'stoga donus: anahtar yanitta bir kez');
      const inv6 = (await db.query("SELECT local_key_enc FROM device_inventory WHERE device_uuid = 'AHBU-B036-0006'")).rows[0];
      assert.equal(secretBox.decrypt(inv6.local_key_enc), er.local_key, 'envanter anahtari artik eski anahtar degil');
      const d6 = (await db.query("SELECT local_key_enc, local_key_pending_enc, home_id FROM devices WHERE device_uuid = 'AHBU-B036-0006'")).rows[0];
      assert.equal(secretBox.decrypt(d6.local_key_enc), er.local_key);
      assert.equal(d6.local_key_pending_enc, null);
      assert.equal(d6.home_id, null);
      assert.deepEqual(await call(req('AHBU-B036-0006')), denied, 'eski sahibin anahtari 401');
      const c7 = await deviceService.claimDevice({ actor: { userId: buyer.id, globalRole: 'user', ip: '127.0.0.1' }, deviceUuid: 'AHBU-B036-0006', setupPin: er.setup_pin, homeName: 'Yeni Ev' });
      assert.notEqual(c7.home_id, c6.home_id);
      const d7 = (await db.query("SELECT local_key_enc FROM devices WHERE device_uuid = 'AHBU-B036-0006'")).rows[0];
      assert.equal(secretBox.decrypt(d7.local_key_enc), er.local_key, 'yeni musterinin panosu yeni anahtarla');
      assert.deepEqual(await call(req('AHBU-B036-0006')), denied, 'yeni dairede eski anahtar 401 (cihaz kimligi alinamaz)');
      assert.equal((await call(req('AHBU-B036-0006', { key: er.local_key }))).http, 200);
    }

    // --- gunluk: sir yok
    const joined = logs.join('\n');
    for (const k of Object.values(keys)) assert.ok(!joined.includes(k));
    assert.ok(!joined.includes(pendingKey));
    assert.ok(!joined.includes(r.body.mqtt.password));
  } finally {
    await env.close();
  }
});
