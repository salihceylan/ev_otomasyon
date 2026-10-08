'use strict';

// Faz 1 bagimsiz inceleme duzeltmeleri - GERCEK PostgreSQL (yalitilmis gecici veritabani, migration 035).
//   1  yerel anahtar (kullanici karari 2026-10-08): HER envanter kartinda (stok, iptal, askida, sahiplenilmis) doner;
//      anahtar yoksa 404; denetim kaydi (envanter durumu + home_id) anahtardan ONCE, yazilamazsa anahtar verilmez
//   2  es zamanli PUT /templates/:id yanlis 404 vermez (surum 2 ve 3 olusur)
//   3  deleteSite <-> linkFlatDevice yarisi: "silinmis site + karta bagli daire" olusmaz
//   4  recordWrite: silinmis sablon / silinmis site / baska sitenin sablonu reddedilir
//   5  deleteTemplate daireleri ayirir (template_id NULL)
//   6  linkFlatDevice yalniz IN_STOCK kart (409 DEVICE_NOT_IN_STOCK)
//   8  acil sifirlama ve pano degisimi devices.template_* alanlarini temizler
// EV_PG_TEST_URL yoksa ATLANIR.

const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');

const { PG_SKIP, open } = require('./_pg_isolated');
const { setTestEnv } = require('../devices/_world');

const FIX = path.join(__dirname, '..', '..', '..', 'docs', 'contracts', 'template', 'fixtures');
const fixture = (f) => JSON.parse(fs.readFileSync(path.join(FIX, f), 'utf8'));

async function expectHttp(promise, status, code) {
  let caught = null;
  try {
    await promise;
  } catch (err) {
    caught = err;
  }
  assert.ok(caught, `HTTP ${status} ${code} bekleniyordu`);
  assert.equal(caught.status, status, caught.message);
  if (code) assert.equal(caught.code, code, caught.message);
  return caught;
}

test('inceleme duzeltmeleri gercek PG', { skip: PG_SKIP }, async () => {
  const env = await open('t035rev');
  if (!env) return;
  setTestEnv();
  const { db } = env;
  try {
    const pin = require('../../src/utils/pin');
    const secretBox = require('../../src/utils/secret_box');
    const { SiteTemplateService } = require('../../src/services/site_template_service');
    const { DeviceService } = require('../../src/services/device_service');
    const { MqttCredentialService } = require('../../src/services/mqtt_credential_service');
    const svc = new SiteTemplateService({ db, secretBox });
    const silent = { warn() {}, error() {}, log() {} };
    const deviceService = new DeviceService({
      db,
      mqttBridge: require('../devices/_ack_bridge').withAckSupport({
        connected: true, isConnected() { return true; }, async publishCommand() { return {}; }, async publishSys() { return {}; },
        async publishToTopic() { return {}; }, async clearRetained() {},
      }),
      mqttCredentials: new MqttCredentialService({ db, logger: silent, env: process.env }),
      mailer: { async sendClaimOtpEmail() { return { sent: true }; } },
      inviteCustomer: async () => ({ sent: true }),
      env: process.env,
    });

    const staff = (await db.query("INSERT INTO users (full_name, email, password_hash, role) VALUES ('S', 's@rev035.test', 'x', 'service_user') RETURNING id")).rows[0];
    const sup = (await db.query("INSERT INTO users (full_name, email, password_hash, role) VALUES ('Z', 'z@rev035.test', 'x', 'super_user') RETURNING id")).rows[0];
    const owner = (await db.query("INSERT INTO users (full_name, email, password_hash, role) VALUES ('O', 'o@rev035.test', 'x', 'user') RETURNING id")).rows[0];
    const sActor = { userId: staff.id, globalRole: 'service_user', ip: '10.0.0.9' };
    const zActor = { userId: sup.id, globalRole: 'super_user', ip: '10.0.0.8' };
    let macN = 0;
    const inv = async (uuid, status = 'IN_STOCK') => {
      macN += 1;
      await db.query(
        "INSERT INTO device_inventory (device_uuid, mac_address, pin_hash, model, status, local_key_enc) VALUES ($1, $2, $3, 'ESP32-S3-POE-ETH-8DI-8RO', $4, $5)",
        [uuid, `E8:F6:0A:35:9${Math.floor(macN / 10)}:0${macN % 10}`, pin.hashPin('135790'), status, secretBox.encrypt(`Anahtar-${uuid}`)]
      );
    };

    // ---------------------------------------------------------------- 1) yerel anahtar
    await inv('AHBU-R035-0001');
    await inv('AHBU-R035-0002', 'REVOKED');
    await inv('AHBU-R035-0003', 'SUSPENDED');
    await inv('AHBU-R035-0004');
    await inv('AHBU-R035-0005');
    const k1 = await svc.getInventoryLocalKey(sActor, 'AHBU-R035-0001');
    assert.equal(k1.local_key, 'Anahtar-AHBU-R035-0001');
    const k1s = await svc.getInventoryLocalKey(zActor, 'AHBU-R035-0001');
    assert.equal(k1s.local_key, k1.local_key, 'super_user da okur');
    const audit = (await db.query("SELECT home_id, actor_role, details FROM device_audit_logs WHERE event = 'inventory_local_key_read' AND device_uuid = 'AHBU-R035-0001' ORDER BY id")).rows;
    assert.equal(audit.length, 2);
    assert.equal(audit[0].details.inventory_status, 'IN_STOCK');
    assert.equal(audit[0].home_id, null);
    assert.ok(!JSON.stringify(audit).includes('Anahtar-'), 'anahtar denetime yazilmaz');
    for (const [u, st] of [['AHBU-R035-0002', 'REVOKED'], ['AHBU-R035-0003', 'SUSPENDED']]) {
      assert.equal((await svc.getInventoryLocalKey(sActor, u)).local_key, `Anahtar-${u}`, st);
      const a = (await db.query("SELECT details FROM device_audit_logs WHERE event = 'inventory_local_key_read' AND device_uuid = $1", [u])).rows;
      assert.equal(a.length, 1);
      assert.equal(a[0].details.inventory_status, st);
    }
    // Sahiplenilmis (musteri) karti: anahtar doner; denetimde CLAIMED + ev kimligi
    const claimed = await deviceService.claimDevice({ actor: { userId: owner.id, globalRole: 'user', ip: '127.0.0.1' }, deviceUuid: 'AHBU-R035-0004', setupPin: '135790', homeName: 'Ev' });
    const k4 = await svc.getInventoryLocalKey(sActor, 'AHBU-R035-0004');
    const devKey = (await db.query("SELECT local_key_enc FROM devices WHERE device_uuid = 'AHBU-R035-0004'")).rows[0].local_key_enc;
    assert.equal(k4.local_key, secretBox.decrypt(devKey), 'panodaki gecerli anahtar (devices) doner');
    const a4 = (await db.query("SELECT home_id, details FROM device_audit_logs WHERE event = 'inventory_local_key_read' AND device_uuid = 'AHBU-R035-0004'")).rows;
    assert.equal(a4.length, 1);
    assert.equal(a4[0].details.inventory_status, 'CLAIMED');
    assert.equal(a4[0].home_id, claimed.home_id);
    // Anahtari olmayan kart: 404, denetim kaydi yok
    await db.query("INSERT INTO device_inventory (device_uuid, mac_address, pin_hash, model) VALUES ('AHBU-R035-0099', 'E8:F6:0A:35:99:99', 'x', 'M')");
    await expectHttp(svc.getInventoryLocalKey(sActor, 'AHBU-R035-0099'), 404, 'NOT_FOUND');
    assert.equal((await db.query("SELECT COUNT(*)::int AS n FROM device_audit_logs WHERE device_uuid = 'AHBU-R035-0099'")).rows[0].n, 0);
    // Denetim kaydi yazilamazsa anahtar VERILMEZ (fail-closed)
    const failing = new SiteTemplateService({
      db: { query: (t, p) => (String(t).includes('INSERT INTO device_audit_logs') ? Promise.reject(new Error('denetim yok')) : db.query(t, p)) },
      secretBox,
    });
    await assert.rejects(failing.getInventoryLocalKey(sActor, 'AHBU-R035-0001'), /denetim yok/);

    // ---------------------------------------------------------------- 6) kart baglama yalniz IN_STOCK
    const site = await svc.createSite(sActor, { name: 'Ay Sitesi' });
    const { created } = await svc.bulkCreateFlats(site.id, { block: 'A', from: 1, to: 4 });
    for (const u of ['AHBU-R035-0002', 'AHBU-R035-0003', 'AHBU-R035-0004']) {
      await expectHttp(svc.linkFlatDevice(site.id, created[0].id, u), 409, 'DEVICE_NOT_IN_STOCK');
    }
    await svc.linkFlatDevice(site.id, created[0].id, 'AHBU-R035-0001');

    // ---------------------------------------------------------------- 2) es zamanli PUT
    const tpl = await svc.createTemplate(sActor, { site_id: site.id, body: fixture('ok_1p1.json') });
    const b1 = fixture('ok_1p1.json');
    b1.relays[2].name = 'Bir';
    const b2 = fixture('ok_1p1.json');
    b2.relays[2].name = 'Iki';
    const [r1, r2] = await Promise.all([svc.updateTemplate(sActor, tpl.id, { body: b1 }), svc.updateTemplate(sActor, tpl.id, { body: b2 })]);
    assert.deepEqual([r1.current_version, r2.current_version].sort(), [2, 3]);
    assert.deepEqual((await svc.listVersions(tpl.id)).map((v) => v.version), [3, 2, 1]);

    // ---------------------------------------------------------------- 4) recordWrite reddi
    const other = await svc.createSite(sActor, { name: 'Gunes' });
    const otherTpl = await svc.createTemplate(sActor, { site_id: other.id, body: fixture('ok_1p1.json') });
    const globalTpl = await svc.createTemplate(sActor, { site_id: null, body: fixture('ok_2p1_genel.json') });
    const w = { device_uuid: 'AHBU-R035-0001', flat_id: created[0].id, via: 'usb', result: 'ok' };
    await expectHttp(svc.recordWrite(sActor, { ...w, template_id: otherTpl.id, version: 1 }), 422, 'TEMPLATE_SITE_MISMATCH');
    await svc.recordWrite(sActor, { ...w, template_id: globalTpl.id, version: 1 }); // genel sablon: kabul
    await svc.recordWrite(sActor, { ...w, template_id: tpl.id, version: 3 });
    await svc.recordWrite(sActor, { device_uuid: 'AHBU-R035-0005', template_id: otherTpl.id, version: 1, via: 'lan', result: 'ok' }); // dairesiz: kabul

    // ---------------------------------------------------------------- 5) deleteTemplate daireleri ayirir
    await svc.updateFlat(site.id, created[1].id, { template_id: tpl.id });
    await svc.updateFlat(site.id, created[2].id, { template_id: tpl.id });
    await svc.deleteTemplate(tpl.id);
    const flats = await svc.listFlats(site.id);
    assert.ok(flats.every((f) => f.template_id === null), 'silinen sablon dairelerden ayrildi');
    await expectHttp(svc.recordWrite(sActor, { ...w, template_id: tpl.id, version: 3 }), 409, 'TEMPLATE_DELETED');
    await expectHttp(svc.recordWrite(sActor, { device_uuid: 'AHBU-R035-0005', template_id: tpl.id, version: 1, via: 'eth', result: 'error' }), 409, 'TEMPLATE_DELETED');

    // Silinmis sitenin dairesine yazim
    const gone = await svc.createSite(sActor, { name: 'Gidecek' });
    const gf = (await svc.bulkCreateFlats(gone.id, { block: 'B', from: 1, to: 1 })).created[0];
    await svc.deleteSite(gone.id);
    await expectHttp(svc.recordWrite(sActor, { device_uuid: 'AHBU-R035-0005', template_id: globalTpl.id, version: 1, flat_id: gf.id, via: 'usb', result: 'ok' }), 409, 'SITE_DELETED');

    // ---------------------------------------------------------------- 3) deleteSite <-> linkFlatDevice yarisi
    for (let round = 0; round < 6; round += 1) {
      const uuid = `AHBU-R035-1${String(round).padStart(3, '0')}`;
      await inv(uuid);
      const s = await svc.createSite(sActor, { name: `Yaris ${round}` });
      const f = (await svc.bulkCreateFlats(s.id, { block: 'C', from: 1, to: 1 })).created[0];
      await Promise.allSettled([svc.linkFlatDevice(s.id, f.id, uuid), svc.deleteSite(s.id)]);
      const row = (await db.query('SELECT s.deleted_at, f.device_uuid FROM sites s JOIN site_flats f ON f.site_id = s.id WHERE s.id = $1', [s.id])).rows[0];
      assert.ok(!(row.deleted_at && row.device_uuid), `tur ${round}: silinmis site + bagli kart olusmamali`);
    }

    // ---------------------------------------------------------------- 8) acil sifirlama / pano degisimi template_* temizler
    const tid = '3f2a9c1e-5b7d-4e8f-9a01-23456789abcd';
    await db.query("UPDATE devices SET template_id = $1, template_version = 4, template_reported_at = NOW() WHERE device_uuid = 'AHBU-R035-0004'", [tid]);
    await deviceService.emergencyReset({ actor: zActor, deviceUuid: 'AHBU-R035-0004', confirmUid: 'AHBU-R035-0004', reason: 'Kiraci ulasilamiyor, acil servis sifirlamasi' });
    let d = (await db.query("SELECT template_id, template_version, template_reported_at FROM devices WHERE device_uuid = 'AHBU-R035-0004'")).rows[0];
    assert.deepEqual(d, { template_id: null, template_version: null, template_reported_at: null });

    await inv('AHBU-R035-0006');
    const c2 = await deviceService.claimDevice({ actor: { userId: owner.id, globalRole: 'user', ip: '127.0.0.1' }, deviceUuid: 'AHBU-R035-0005', setupPin: '135790', homeName: 'Ev2' });
    await db.query("UPDATE devices SET template_id = $1, template_version = 2 WHERE device_uuid = 'AHBU-R035-0005'", [tid]);
    await deviceService.replaceBoard({
      actor: { ...zActor, access: 'super_user' }, homeId: c2.home_id, oldDeviceUuid: 'AHBU-R035-0005', newDeviceUuid: 'AHBU-R035-0006',
      setupPin: '135790', reason: 'Eski pano arizali, yenisiyle degistirildi',
    });
    d = (await db.query("SELECT template_id, template_version FROM devices WHERE device_uuid = 'AHBU-R035-0005'")).rows[0];
    assert.deepEqual(d, { template_id: null, template_version: null });
    assert.ok(claimed.home_id);

    // ---------------------------------------------------------------- 8) kopru tpl SQL'i gercek PG'de
    const { buildTemplateUpdate, validateStatePayload } = require('../../src/mqtt_bridge').helpers;
    const devId = (await db.query("SELECT id FROM devices WHERE device_uuid = 'AHBU-R035-0006'")).rows[0].id;
    const st = (o) => validateStatePayload({ uid: 'AHBU-R035-0006', ...o }).value;
    let q = buildTemplateUpdate(devId, st({ fw: '1.3.0', tpl: { id: tid, ver: 5 } }), true);
    assert.equal((await db.query(q.text, q.values)).rowCount, 1);
    assert.equal((await db.query(q.text, q.values)).rowCount, 0, 'degismeyen tpl yeniden yazilmaz');
    q = buildTemplateUpdate(devId, st({ fw: '1.3.0' }), true);
    assert.equal((await db.query(q.text, q.values)).rowCount, 1);
    d = (await db.query('SELECT template_id, template_version FROM devices WHERE id = $1', [devId])).rows[0];
    assert.deepEqual(d, { template_id: null, template_version: null });
  } finally {
    await env.close();
  }
});
