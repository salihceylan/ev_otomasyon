'use strict';

// atolye-7 / atolye-8 (inceleme) - pano degisimi + site dairesi, GERCEK PostgreSQL (yalitilmis gecici veritabani, 035+):
//   - yeni kart BASKA daireye bagliysa super olmayan 409 DEVICE_LINKED_TO_FLAT; islem tamamen geri alinir
//   - super_user gecersiz kilarsa o daire kartsiz + 'planned' (uq_site_flats_device ihlali yok: once bag kaldirilir)
//   - degistirilen dairenin 'written' durumu: yeni kartin bu dairenin sablonuyla basarili yazimi yoksa 'planned', varsa aynen
// EV_PG_TEST_URL yoksa ATLANIR.

const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');

const { PG_SKIP, open } = require('../templates/_pg_isolated');
const { setTestEnv } = require('./_world');

const FIX = path.join(__dirname, '..', '..', '..', 'docs', 'contracts', 'template', 'fixtures');
const fixture = (f) => JSON.parse(fs.readFileSync(path.join(FIX, f), 'utf8'));
const PIN = '135790';
const REASON = 'Eski pano arizali, yenisiyle degistirildi';

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

test('pano degisimi + site dairesi (atolye-7/8) gercek PG', { skip: PG_SKIP }, async () => {
  const env = await open('t038rbf');
  if (!env) return;
  setTestEnv();
  const { db } = env;
  try {
    const pin = require('../../src/utils/pin');
    const secretBox = require('../../src/utils/secret_box');
    const { DeviceService } = require('../../src/services/device_service');
    const { MqttCredentialService } = require('../../src/services/mqtt_credential_service');
    const { SiteTemplateService } = require('../../src/services/site_template_service');
    const silent = { warn() {}, error() {}, log() {} };
    const credentials = new MqttCredentialService({ db, logger: silent, env: process.env });
    const deviceService = new DeviceService({
      db,
      mqttBridge: { isConnected: () => true, async publishCommand() {}, async publishSys() {}, async clearRetained() {} },
      mqttCredentials: credentials,
      mailer: { async sendClaimOtpEmail() { return { sent: true }; } },
      inviteCustomer: async () => ({ sent: true }),
      env: process.env,
    });
    const sites = new SiteTemplateService({ db, secretBox });

    const ownerRow = (await db.query("INSERT INTO users (full_name, email, password_hash, role) VALUES ('O', 'o@rbf.test', 'x', 'user') RETURNING id")).rows[0];
    const supRow = (await db.query("INSERT INTO users (full_name, email, password_hash, role) VALUES ('S', 's@rbf.test', 'x', 'super_user') RETURNING id")).rows[0];
    const sup = { userId: supRow.id, globalRole: 'super_user', ip: '10.0.0.6' };
    let mac = 0;
    const inv = async (uuid) => {
      mac += 1;
      await db.query(
        "INSERT INTO device_inventory (device_uuid, mac_address, pin_hash, model, status, local_key_enc) VALUES ($1, $2, $3, 'ESP32-S3-POE-ETH-8DI-8RO', 'IN_STOCK', $4)",
        [uuid, `E8:F6:0A:38:00:${String(mac).padStart(2, '0')}`, pin.hashPin(PIN), secretBox.encrypt(`Anahtar-${uuid}-${crypto.randomBytes(3).toString('hex')}`)]
      );
    };
    const flatRow = async (id) => (await db.query('SELECT device_uuid, status FROM site_flats WHERE id = $1', [id])).rows[0];
    const setFlat = (id, uuid, status, templateId) =>
      db.query('UPDATE site_flats SET device_uuid = $2, status = $3, template_id = $4 WHERE id = $1', [id, uuid, status, templateId]);

    const site = await sites.createSite(sup, { name: 'Degisim Sitesi' });
    await sites.bulkCreateFlats(site.id, { block: 'A', from: 1, to: 4 });
    const [fa, fb, fc, fd] = await sites.listFlats(site.id);
    const tpl = await sites.createTemplate(sup, { site_id: site.id, body: fixture('ok_1p1.json') });

    // --- senaryo 1: eski kart dairede (written), yeni kart BASKA dairede (written)
    for (const u of ['AHBU-RBF-0001', 'AHBU-RBF-0002', 'AHBU-RBF-0003', 'AHBU-RBF-0004']) await inv(u);
    const c1 = await deviceService.claimDevice({ actor: { userId: ownerRow.id, globalRole: 'user', ip: '127.0.0.1' }, deviceUuid: 'AHBU-RBF-0001', setupPin: PIN, homeName: 'Daire A1' });
    await setFlat(fa.id, 'AHBU-RBF-0001', 'written', tpl.id);
    await setFlat(fb.id, 'AHBU-RBF-0002', 'written', tpl.id);
    const args = { homeId: c1.home_id, oldDeviceUuid: 'AHBU-RBF-0001', newDeviceUuid: 'AHBU-RBF-0002', setupPin: PIN, reason: REASON };
    const ownerActor = { userId: ownerRow.id, globalRole: 'user', ip: '127.0.0.1', access: 'owner' };

    const e = await expectHttp(deviceService.replaceBoard({ actor: ownerActor, ...args }), 409, 'DEVICE_LINKED_TO_FLAT');
    assert.equal(e.message, 'Kart bir daireye bağlı; önce daireden ayırın.');
    assert.deepEqual(await flatRow(fa.id), { device_uuid: 'AHBU-RBF-0001', status: 'written' });
    assert.deepEqual(await flatRow(fb.id), { device_uuid: 'AHBU-RBF-0002', status: 'written' });
    assert.equal((await db.query("SELECT status FROM device_inventory WHERE device_uuid = 'AHBU-RBF-0002'")).rows[0].status, 'IN_STOCK', 'geri alindi');
    assert.equal((await db.query("SELECT COUNT(*)::int AS n FROM devices WHERE device_uuid = 'AHBU-RBF-0002'")).rows[0].n, 0);

    const r = await deviceService.replaceBoard({ actor: { ...sup, access: 'super_user' }, ...args });
    assert.equal(r.new_device_uuid, 'AHBU-RBF-0002');
    assert.ok((r.warnings || []).some((w) => w.includes('başka bir daireye bağlıydı')), JSON.stringify(r.warnings));
    assert.deepEqual(await flatRow(fb.id), { device_uuid: null, status: 'planned' }, 'diger daire kartsiz + planned');
    assert.deepEqual(await flatRow(fa.id), { device_uuid: 'AHBU-RBF-0002', status: 'planned' }, 'yeni kartta bu sablonun basarili yazimi yok');

    // --- senaryo 2: yeni karta bu dairenin sablonu basariyla yazilmis -> written korunur (owner yetkisiyle)
    const c3 = await deviceService.claimDevice({ actor: { userId: ownerRow.id, globalRole: 'user', ip: '127.0.0.1' }, deviceUuid: 'AHBU-RBF-0003', setupPin: PIN, homeName: 'Daire A3' });
    await setFlat(fc.id, 'AHBU-RBF-0003', 'written', tpl.id);
    await db.query("INSERT INTO template_writes (device_uuid, template_id, version, via, result) VALUES ('AHBU-RBF-0004', $1, 1, 'usb', 'ok')", [tpl.id]);
    const r2 = await deviceService.replaceBoard({
      actor: ownerActor, homeId: c3.home_id, oldDeviceUuid: 'AHBU-RBF-0003', newDeviceUuid: 'AHBU-RBF-0004', setupPin: PIN, reason: REASON,
    });
    assert.ok(!(r2.warnings || []).some((w) => w.includes('başka bir daireye')));
    assert.deepEqual(await flatRow(fc.id), { device_uuid: 'AHBU-RBF-0004', status: 'written' });
    assert.deepEqual(await flatRow(fd.id), { device_uuid: null, status: 'planned' }, 'ilgisiz daireye dokunulmaz');
  } finally {
    await env.close();
  }
});
