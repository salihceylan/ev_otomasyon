'use strict';

// tarama-sunucu-cihaz-site-6 - GERCEK PostgreSQL (yalitilmis gecici veritabani, migration 035+):
//   sozlesme C2  yazim kaydi: daire template_id dolu ve yazilan sablondan farkliysa kayit eklenir, daire durumu DEGISMEZ,
//                yanit warning 'FLAT_TEMPLATE_MISMATCH' + flat_template_id; DEVICE_LINKED_ELSEWHERE varsa o doner (tek alan).
//                last_write ve last_ok_write template_id tasir.
//   sozlesme C13 PUT .../flats/:flatId/device: ayni kart -> degisiklik yok; 'written' dairede null -> 'planned';
//                installed/handed_over dairede farkli kart ya da null: degisim kaydi (old=mevcut, new=kart) varsa baglanir ve
//                durum korunur; yoksa super_user degilse 409 INVALID_STATUS_TRANSITION; super_user ise baglanir ve durum
//                yeniden hesaplanir (null -> planned; kartta dairenin sablonuyla ok yazim varsa written, yoksa planned).
// EV_PG_TEST_URL yoksa ATLANIR.

const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');

const { PG_SKIP, open } = require('./_pg_isolated');

const FIX = path.join(__dirname, '..', '..', '..', 'docs', 'contracts', 'template', 'fixtures');
const fixture = (f) => JSON.parse(fs.readFileSync(path.join(FIX, f), 'utf8'));
const C13_MSG = 'Kurulmuş ya da teslim edilmiş dairenin kartı yalnız Pano Değişimi ile ya da yönetici tarafından değiştirilebilir.';

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

test('C2 + C13: farkli sablon yazimi daireyi Yazildi yapmaz; kurulmus/teslim edilmis dairenin karti korunur', { skip: PG_SKIP }, async () => {
  const env = await open('t040fwl');
  if (!env) return;
  process.env.LOCAL_KEY_SECRET = process.env.LOCAL_KEY_SECRET || crypto.randomBytes(32).toString('hex');
  const secretBox = require('../../src/utils/secret_box');
  const { SiteTemplateService } = require('../../src/services/site_template_service');
  const svc = new SiteTemplateService({ db: env.db, secretBox });
  const { db } = env;
  try {
    const staffRow = (await db.query("INSERT INTO users (full_name, email, password_hash, role) VALUES ('Servis', 'svcfwl@example.test', 'x', 'service_user') RETURNING id")).rows[0];
    const supRow = (await db.query("INSERT INTO users (full_name, email, password_hash, role) VALUES ('Kok', 'supfwl@example.test', 'x', 'super_user') RETURNING id")).rows[0];
    const staff = { userId: staffRow.id, globalRole: 'service_user', ip: '10.0.0.5' };
    const sup = { userId: supRow.id, globalRole: 'super_user', ip: '10.0.0.6' };
    const site = await svc.createSite(staff, { name: 'Yazim Sitesi' });
    await svc.bulkCreateFlats(site.id, { block: 'C', from: 1, to: 8 });
    const [f1, f2, f3, f4, f5, f6, f7, f8] = await svc.listFlats(site.id);
    const t1 = await svc.createTemplate(staff, { site_id: site.id, body: fixture('ok_1p1.json') });
    const t2 = await svc.createTemplate(staff, { site_id: site.id, body: fixture('ok_2p1_genel.json') });
    const inv = async (uuid, status = 'IN_STOCK') => db.query(
      "INSERT INTO device_inventory (device_uuid, mac_address, pin_hash, model, status) VALUES ($1, $2, 'x', 'M', $3)",
      [uuid, `E8:F6:0B:${crypto.randomBytes(3).toString('hex').match(/../g).join(':')}`, status]
    );
    for (let i = 1; i <= 12; i += 1) await inv(`AHBU-FWL-${String(i).padStart(4, '0')}`);
    const card = (i) => `AHBU-FWL-${String(i).padStart(4, '0')}`;
    const flatOf = async (id) => (await svc.listFlats(site.id)).find((f) => f.id === id);
    const setStatus = (id, status) => db.query('UPDATE site_flats SET status = $2 WHERE id = $1', [id, status]);

    // ---- C2: daire T1'e ayarli, eski listeyle T2 yazildi -> kayit eklenir, daire 'planned' kalir + uyari
    await svc.updateFlat(site.id, f1.id, { template_id: t1.id });
    await svc.linkFlatDevice(site.id, f1.id, card(1), staff);
    const w = await svc.recordWrite(staff, { device_uuid: card(1), template_id: t2.id, version: 1, flat_id: f1.id, via: 'usb', result: 'ok' });
    assert.equal(w.flat_status, 'planned', 'baska sablonun yazimi Yazildi yapmaz');
    assert.equal(w.warning, 'FLAT_TEMPLATE_MISMATCH');
    assert.equal(w.flat_template_id, t1.id);
    assert.equal(w.template_id, t2.id, 'kayit eklendi');
    let a1 = await flatOf(f1.id);
    assert.equal(a1.status, 'planned');
    assert.equal(a1.last_write.template_id, t2.id);
    assert.equal(a1.last_ok_write.template_id, t2.id, 'last_ok_write sablon kimligini tasir (arac farkli sablonu isaretler)');
    // dogru sablon: written, uyari yok
    const w2 = await svc.recordWrite(staff, { device_uuid: card(1), template_id: t1.id, version: 1, flat_id: f1.id, via: 'eth', result: 'ok' });
    assert.equal(w2.flat_status, 'written');
    assert.equal(w2.warning, undefined);
    a1 = await flatOf(f1.id);
    assert.equal(a1.last_ok_write.template_id, t1.id);
    // sablonsuz daire: bugunku gibi written
    await svc.linkFlatDevice(site.id, f2.id, card(2), staff);
    const w3 = await svc.recordWrite(staff, { device_uuid: card(2), template_id: t2.id, version: 1, flat_id: f2.id, via: 'usb', result: 'ok' });
    assert.equal(w3.flat_status, 'written');
    assert.equal(w3.warning, undefined);
    // DEVICE_LINKED_ELSEWHERE oncelikli (tek uyari alani)
    await svc.updateFlat(site.id, f3.id, { template_id: t1.id });
    const w4 = await svc.recordWrite(staff, { device_uuid: card(2), template_id: t2.id, version: 1, flat_id: f3.id, via: 'usb', result: 'ok' });
    assert.equal(w4.warning, 'DEVICE_LINKED_ELSEWHERE');
    assert.equal(w4.flat_template_id, undefined);
    assert.equal(w4.flat_status, 'planned');

    // ---- C13: ayni kart -> degisiklik yok
    const same = await svc.linkFlatDevice(site.id, f1.id, card(1), staff);
    assert.equal(same.status, 'written');
    // 'written' daireden kart ayrilinca 'planned'
    const detached = await svc.linkFlatDevice(site.id, f1.id, null, staff);
    assert.deepEqual([detached.device_uuid, detached.status], [null, 'planned']);

    // installed / handed_over: personel ayiramaz ve degisim kaydi olmadan baska kart baglayamaz
    await svc.updateFlat(site.id, f4.id, { template_id: t1.id });
    await svc.linkFlatDevice(site.id, f4.id, card(4), staff);
    await setStatus(f4.id, 'handed_over');
    let e = await expectHttp(svc.linkFlatDevice(site.id, f4.id, null, staff), 409, 'INVALID_STATUS_TRANSITION');
    assert.equal(e.message, C13_MSG);
    e = await expectHttp(svc.linkFlatDevice(site.id, f4.id, card(5), staff), 409, 'INVALID_STATUS_TRANSITION');
    assert.equal(e.message, C13_MSG);
    assert.deepEqual([(await flatOf(f4.id)).device_uuid, (await flatOf(f4.id)).status], [card(4), 'handed_over'], 'degismedi');

    // degisim kaydi (old=mevcut, new=kart) varsa baglanir ve durum korunur
    await db.query("UPDATE device_inventory SET status = 'CLAIMED' WHERE device_uuid = $1", [card(6)]);
    const home = (await db.query("INSERT INTO homes (name, mqtt_username) VALUES ('FWL', $1) RETURNING id", [`h_${crypto.randomBytes(8).toString('hex')}`])).rows[0];
    await db.query(
      "INSERT INTO device_replacement_logs (home_id, old_device_uuid, new_device_uuid, replaced_by_user_id, endpoints_migrated_count, reason) VALUES ($1, $2, $3, $4, 0, 'test')",
      [home.id, card(4), card(6), staffRow.id]
    );
    const swapped = await svc.linkFlatDevice(site.id, f4.id, card(6), staff);
    assert.deepEqual([swapped.device_uuid, swapped.status], [card(6), 'handed_over']);

    // super_user: ayirir -> planned
    await svc.linkFlatDevice(site.id, f5.id, card(7), staff);
    await setStatus(f5.id, 'installed');
    const supDetach = await svc.linkFlatDevice(site.id, f5.id, null, sup);
    assert.deepEqual([supDetach.device_uuid, supDetach.status], [null, 'planned']);
    // super_user: baska kart -> kartta bu dairenin sablonuyla ok yazim varsa written, yoksa planned
    await svc.updateFlat(site.id, f6.id, { template_id: t1.id });
    await svc.linkFlatDevice(site.id, f6.id, card(8), staff);
    await setStatus(f6.id, 'installed');
    await svc.recordWrite(staff, { device_uuid: card(9), template_id: t1.id, version: 1, via: 'usb', result: 'ok' });
    const supWritten = await svc.linkFlatDevice(site.id, f6.id, card(9), sup);
    assert.deepEqual([supWritten.device_uuid, supWritten.status], [card(9), 'written']);
    await svc.updateFlat(site.id, f7.id, { template_id: t1.id });
    await svc.linkFlatDevice(site.id, f7.id, card(10), staff);
    await setStatus(f7.id, 'handed_over');
    const supPlanned = await svc.linkFlatDevice(site.id, f7.id, card(11), sup);
    assert.deepEqual([supPlanned.device_uuid, supPlanned.status], [card(11), 'planned']);

    // planned dairede ayirma/baglama bugunku gibi
    await svc.linkFlatDevice(site.id, f8.id, card(12), staff);
    const p8 = await svc.linkFlatDevice(site.id, f8.id, null, staff);
    assert.deepEqual([p8.device_uuid, p8.status], [null, 'planned']);
  } finally {
    await env.close();
  }
});
