'use strict';

// Faz 1 / IP-1.5 (K-S8): claimDevice GERCEK PostgreSQL'de (yalitilmis gecici veritabani, migration 035). Daireye bagli kart:
// ev adi daireden, uc noktalar son BASARILI yazimin surumunden (jsonb_to_recordset tohumu), daire installed, denetim
// kaydinda sablon kimligi/surumu. Bagli olmayan kart: sabit tohum. EV_PG_TEST_URL yoksa ATLANIR.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const { PG_SKIP, open } = require('./_pg_isolated');
const { setTestEnv } = require('../devices/_world');

const FIX = path.join(__dirname, '..', '..', '..', 'docs', 'contracts', 'template', 'fixtures');
const fixture = (f) => JSON.parse(fs.readFileSync(path.join(FIX, f), 'utf8'));

test('claim + sablon tohumu gercek PG', { skip: PG_SKIP }, async () => {
  const env = await open('t035claim');
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
      mqttBridge: { isConnected: () => true, async publishCommand() {}, async publishSys() {}, async publishToTopic() {}, async clearRetained() {} },
      mqttCredentials: credentials,
      mailer: { async sendClaimOtpEmail() { return { sent: true }; } },
      inviteCustomer: async () => ({ sent: true }),
      env: process.env,
    });
    const sts = new SiteTemplateService({ db, secretBox });

    const staff = (await db.query("INSERT INTO users (full_name, email, password_hash, role) VALUES ('S', 's@claim035.test', 'x', 'service_user') RETURNING id")).rows[0];
    const owner = (await db.query("INSERT INTO users (full_name, email, password_hash, role) VALUES ('O', 'o@claim035.test', 'x', 'user') RETURNING id, role")).rows[0];
    const owner2 = (await db.query("INSERT INTO users (full_name, email, password_hash, role) VALUES ('P', 'p@claim035.test', 'x', 'user') RETURNING id, role")).rows[0];
    const sActor = { userId: staff.id, globalRole: 'service_user' };
    for (const [uuid, mac] of [['AHBU-C035-0001', 'E8:F6:0A:35:C0:01'], ['AHBU-C035-0002', 'E8:F6:0A:35:C0:02']]) {
      await db.query(
        "INSERT INTO device_inventory (device_uuid, mac_address, pin_hash, model, status) VALUES ($1, $2, $3, 'ESP32-S3-POE-ETH-8DI-8RO', 'IN_STOCK')",
        [uuid, mac, pin.hashPin('135790')]
      );
    }

    const site = await sts.createSite(sActor, { name: 'Güneş Sitesi' });
    const { created } = await sts.bulkCreateFlats(site.id, { block: 'B', from: 7, to: 7 });
    const flat = created[0];
    await sts.linkFlatDevice(site.id, flat.id, 'AHBU-C035-0001');
    const tpl = await sts.createTemplate(sActor, { site_id: site.id, body: fixture('ok_3p1_vana_dimmer.json') });
    const v2body = fixture('ok_3p1_vana_dimmer.json');
    v2body.relays[6].name = 'Çocuk Odası Avize';
    await sts.updateTemplate(sActor, tpl.id, { body: v2body });
    await sts.recordWrite(sActor, { device_uuid: 'AHBU-C035-0001', template_id: tpl.id, version: 1, flat_id: flat.id, via: 'usb', result: 'ok' });
    await sts.recordWrite(sActor, { device_uuid: 'AHBU-C035-0001', template_id: tpl.id, version: 2, flat_id: flat.id, via: 'eth', result: 'ok' });
    await sts.recordWrite(sActor, { device_uuid: 'AHBU-C035-0001', template_id: tpl.id, version: 1, flat_id: flat.id, via: 'lan', result: 'error', error_code: 'busy' });

    const r = await deviceService.claimDevice({ actor: { userId: owner.id, globalRole: 'user', ip: '127.0.0.1' }, deviceUuid: 'AHBU-C035-0001', setupPin: '135790', homeName: 'Yok Sayilir' });
    assert.equal(r.home_name, 'Güneş Sitesi B-7');
    const eps = (await db.query(
      `SELECT e.channel_index, e.name, e.type, e.room, e.shutter_pair_index, e.shutter_duration_sec, e.actuator_type, e.dimmable, e.dimmer_source
         FROM endpoints e JOIN devices d ON d.id = e.device_id WHERE d.device_uuid = 'AHBU-C035-0001' ORDER BY e.channel_index`
    )).rows;
    assert.equal(eps.length, 8);
    assert.equal(eps[6].name, 'Çocuk Odası Avize', 'son basarili yazim (v2)');
    assert.deepEqual(
      { t: eps[0].type, p: eps[0].shutter_pair_index, s: eps[0].shutter_duration_sec, room: eps[2].room, s3: eps[2].shutter_duration_sec },
      { t: 'shutter', p: 1, s: 25, room: 'Yatak Odası', s3: 30 }
    );
    assert.equal(eps[7].actuator_type, 'valve');
    assert.equal(eps[4].dimmable, true);
    assert.equal(eps[4].dimmer_source, 'modbus');
    const f = await sts.listFlats(site.id);
    assert.equal(f[0].status, 'installed');
    const audit = (await db.query("SELECT details FROM device_audit_logs WHERE event = 'device_claimed' AND device_uuid = 'AHBU-C035-0001'")).rows[0];
    assert.equal(audit.details.template_id, tpl.id);
    assert.equal(audit.details.template_version, 2);

    // Bagli olmayan kart: sabit tohum
    const r2 = await deviceService.claimDevice({ actor: { userId: owner2.id, globalRole: 'user', ip: '127.0.0.1' }, deviceUuid: 'AHBU-C035-0002', setupPin: '135790', homeName: 'Daire 9' });
    assert.equal(r2.home_name, 'Daire 9');
    const e2 = (await db.query("SELECT e.name FROM endpoints e JOIN devices d ON d.id = e.device_id WHERE d.device_uuid = 'AHBU-C035-0002' ORDER BY e.channel_index")).rows;
    assert.equal(e2[0].name, 'Salon Panjur Yukarı');
  } finally {
    await env.close();
  }
});
