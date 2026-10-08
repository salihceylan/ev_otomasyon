'use strict';

// Site / daire / sablon duzeltmeleri - GERCEK PostgreSQL (yalitilmis gecici veritabani, migration 035+).
//   atolye-7  daire satiri last_write {version, via, at, result, error_code, device_uuid} + last_ok_write (dairenin
//             kartiyla son basarili yazim); kart degisiminde (yeni kartin bu sablonla basarili yazimi yoksa) ve sablon
//             degisiminde 'written' -> 'planned' (installed / handed_over'a dokunulmaz)
//   atolye-8  IN_STOCK olmayan kart: degisim kaydi (eski = dairenin karti, yeni = kart) varsa ya da super_user ise baglanir
//   servis_kurulum-10  daire durumu yalniz ileri; installed / handed_over icin kart sart; geri alma yalniz super_user
//             (aksi 409 INVALID_STATUS_TRANSITION)
//   atolye-10 kart BASKA daireye bagliyken yazim kaydi eklenir, daire durumu degismez, warning DEVICE_LINKED_ELSEWHERE
//   atolye-13 PUT /templates/:id base_version eski + govde farkli -> 409 TEMPLATE_CHANGED {current_version}
//   atolye-14 site_id'siz sablon listesi yalniz genel (site_id IS NULL) sablonlar
// EV_PG_TEST_URL yoksa ATLANIR.

const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');

const { PG_SKIP, open } = require('./_pg_isolated');

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

test('site/daire/sablon duzeltmeleri gercek PG', { skip: PG_SKIP }, async () => {
  const env = await open('t035g2');
  if (!env) return;
  process.env.LOCAL_KEY_SECRET = process.env.LOCAL_KEY_SECRET || crypto.randomBytes(32).toString('hex');
  const secretBox = require('../../src/utils/secret_box');
  const { SiteTemplateService } = require('../../src/services/site_template_service');
  const svc = new SiteTemplateService({ db: env.db, secretBox });
  const { db } = env;
  try {
    const staffRow = (await db.query("INSERT INTO users (full_name, email, password_hash, role) VALUES ('Servis', 'svcg2@example.test', 'x', 'service_user') RETURNING id")).rows[0];
    const supRow = (await db.query("INSERT INTO users (full_name, email, password_hash, role) VALUES ('Kok', 'supg2@example.test', 'x', 'super_user') RETURNING id")).rows[0];
    const staff = { userId: staffRow.id, globalRole: 'service_user', ip: '10.0.0.5' };
    const sup = { userId: supRow.id, globalRole: 'super_user', ip: '10.0.0.6' };
    const site = await svc.createSite(staff, { name: 'Ay Sitesi' });
    await svc.bulkCreateFlats(site.id, { block: 'B', from: 1, to: 4 });
    const flats = await svc.listFlats(site.id);
    const [f1, f2, f3, f4] = flats;
    const t1 = await svc.createTemplate(staff, { site_id: site.id, body: fixture('ok_1p1.json') });
    const changed = fixture('ok_1p1.json');
    changed.relays[2].name = 'Salon Avize';
    const t1v2 = await svc.updateTemplate(staff, t1.id, { body: changed });
    assert.equal(t1v2.current_version, 2);
    const t2 = await svc.createTemplate(staff, { site_id: site.id, body: fixture('ok_2p1_genel.json') });
    const inv = async (uuid, status = 'IN_STOCK') => db.query(
      "INSERT INTO device_inventory (device_uuid, mac_address, pin_hash, model, status) VALUES ($1, $2, 'x', 'M', $3)",
      [uuid, `E8:F6:0A:${crypto.randomBytes(3).toString('hex').match(/../g).join(':')}`, status]
    );
    await inv('AHBU-G2-0001');
    await inv('AHBU-G2-0002');
    await inv('AHBU-G2-0003');

    // --- atolye-7: last_write / last_ok_write
    await svc.updateFlat(site.id, f1.id, { template_id: t1.id });
    await svc.linkFlatDevice(site.id, f1.id, 'AHBU-G2-0001', staff);
    const okW = await svc.recordWrite(staff, { device_uuid: 'AHBU-G2-0001', template_id: t1.id, version: 1, flat_id: f1.id, via: 'usb', result: 'ok' });
    assert.equal(okW.flat_status, 'written');
    await svc.recordWrite(staff, { device_uuid: 'AHBU-G2-0001', template_id: t1.id, version: 2, flat_id: f1.id, via: 'eth', result: 'error', error_code: 'local_loosen_forbidden' });
    let a1 = (await svc.listFlats(site.id)).find((f) => f.id === f1.id);
    assert.equal(a1.last_write.version, 2);
    assert.equal(a1.last_write.result, 'error');
    assert.equal(a1.last_write.error_code, 'local_loosen_forbidden');
    assert.equal(a1.last_write.device_uuid, 'AHBU-G2-0001');
    assert.equal(a1.last_write.via, 'eth');
    assert.ok(a1.last_write.at);
    assert.deepEqual(Object.keys(a1.last_ok_write).sort(), ['at', 'device_uuid', 'version', 'via']);
    assert.equal(a1.last_ok_write.version, 1);
    assert.equal(a1.last_ok_write.via, 'usb');
    assert.equal(a1.status, 'written');

    // kart degisimi: yeni kartin bu sablonla basarili yazimi yok -> planned; last_ok_write yeni karta gore (yok)
    a1 = await svc.linkFlatDevice(site.id, f1.id, 'AHBU-G2-0002', staff);
    assert.equal(a1.status, 'planned', 'kart degisti: yazildi durumu karta bagli');
    assert.equal(a1.last_ok_write, null);
    // yeni kart bu sablonla yazilinca written; baska karta gecip geri donmek (yazimi var) durumu korur
    await svc.recordWrite(staff, { device_uuid: 'AHBU-G2-0002', template_id: t1.id, version: 2, flat_id: f1.id, via: 'lan', result: 'ok' });
    await svc.linkFlatDevice(site.id, f1.id, null, staff);
    a1 = await svc.linkFlatDevice(site.id, f1.id, 'AHBU-G2-0002', staff);
    assert.equal(a1.status, 'written');
    // sablon degisimi: written -> planned
    a1 = await svc.updateFlat(site.id, f1.id, { template_id: t2.id }, staff);
    assert.equal(a1.status, 'planned');

    // --- servis_kurulum-10: yalniz ileri; installed/handed_over kart ister; geri alma yalniz super
    await svc.updateFlat(site.id, f2.id, { status: 'written' }, staff);
    await expectHttp(svc.updateFlat(site.id, f2.id, { status: 'planned' }, staff), 409, 'INVALID_STATUS_TRANSITION');
    const e = await expectHttp(svc.updateFlat(site.id, f2.id, { status: 'installed' }, staff), 409, 'INVALID_STATUS_TRANSITION');
    assert.equal(e.message, 'Daire durumu bu şekilde değiştirilemez.');
    assert.equal((await svc.updateFlat(site.id, f2.id, { status: 'planned' }, sup)).status, 'planned', 'super geri alabilir');
    await svc.linkFlatDevice(site.id, f2.id, 'AHBU-G2-0003', staff);
    assert.equal((await svc.updateFlat(site.id, f2.id, { status: 'installed' }, staff)).status, 'installed');
    assert.equal((await svc.updateFlat(site.id, f2.id, { status: 'handed_over' }, staff)).status, 'handed_over');
    await expectHttp(svc.updateFlat(site.id, f2.id, { status: 'installed' }, staff), 409, 'INVALID_STATUS_TRANSITION');
    assert.equal((await svc.updateFlat(site.id, f2.id, { status: 'handed_over' }, staff)).status, 'handed_over', 'ayni durum serbest');

    // --- atolye-10: kart baska daireye bagliyken yazim -> kayit var, durum degismez, uyari
    await svc.updateFlat(site.id, f3.id, { template_id: t1.id }, staff);
    const wElse = await svc.recordWrite(staff, { device_uuid: 'AHBU-G2-0003', template_id: t1.id, version: 2, flat_id: f3.id, via: 'usb', result: 'ok' });
    assert.equal(wElse.warning, 'DEVICE_LINKED_ELSEWHERE');
    assert.equal(wElse.linked_flat_id, f2.id);
    assert.equal(wElse.flat_status, 'planned');
    assert.equal((await svc.listFlats(site.id)).find((f) => f.id === f3.id).status, 'planned');
    assert.equal((await db.query('SELECT COUNT(*)::int AS n FROM template_writes WHERE id = $1', [wElse.id])).rows[0].n, 1, 'kayit eklendi');

    // --- atolye-8: IN_STOCK olmayan kart
    await inv('AHBU-G2-0004', 'CLAIMED');
    await inv('AHBU-G2-0005', 'CLAIMED');
    await svc.linkFlatDevice(site.id, f4.id, 'AHBU-G2-0001', staff); // eski kart (stokta)
    await expectHttp(svc.linkFlatDevice(site.id, f4.id, 'AHBU-G2-0004', staff), 409, 'DEVICE_NOT_IN_STOCK');
    const home = (await db.query("INSERT INTO homes (name, mqtt_username) VALUES ('Ev', 'h_g2g2g2g2g2g2g2g2') RETURNING id")).rows[0];
    await db.query(
      "INSERT INTO device_replacement_logs (home_id, old_device_uuid, new_device_uuid, replaced_by_user_id) VALUES ($1, 'AHBU-G2-0001', 'AHBU-G2-0004', $2)",
      [home.id, staffRow.id]
    );
    assert.equal((await svc.linkFlatDevice(site.id, f4.id, 'AHBU-G2-0004', staff)).device_uuid, 'AHBU-G2-0004', 'degisim kaydi var');
    await expectHttp(svc.linkFlatDevice(site.id, f3.id, 'AHBU-G2-0005', staff), 409, 'DEVICE_NOT_IN_STOCK');
    assert.equal((await svc.linkFlatDevice(site.id, f3.id, 'AHBU-G2-0005', sup)).device_uuid, 'AHBU-G2-0005', 'super_user');

    // --- atolye-13: es zamanli duzenleme
    const cur = await svc.getTemplate(t1.id);
    const c3 = fixture('ok_1p1.json');
    c3.relays[2].name = 'Salon Lamba';
    const conflict = await expectHttp(svc.updateTemplate(staff, t1.id, { body: c3, base_version: 1 }), 409, 'TEMPLATE_CHANGED');
    assert.equal(conflict.message, 'Şablon siz düzenlerken değişti.');
    assert.deepEqual(conflict.extra.data, { current_version: cur.current_version });
    const same = await svc.updateTemplate(staff, t1.id, { body: changed, base_version: 1 });
    assert.equal(same.created, false, 'govde ayni: eski base_version catisma degil');
    const ok3 = await svc.updateTemplate(staff, t1.id, { body: c3, base_version: cur.current_version });
    assert.equal(ok3.current_version, 3);
    await expectHttp(svc.updateTemplate(staff, t1.id, { body: c3, base_version: 'x' }), 400, 'VALIDATION');

    // --- atolye-14: site_id'siz liste yalniz genel sablonlar
    const g = await svc.createTemplate(staff, { site_id: null, body: fixture('ok_3p1_vana_dimmer.json') });
    const all = await svc.listTemplates({});
    assert.deepEqual(all.map((t) => t.id), [g.id]);
    assert.deepEqual((await svc.listTemplates({ includeGlobal: true })).map((t) => t.id), [g.id], 'include_global site_id siz yok sayilir');
    assert.deepEqual(new Set((await svc.listTemplates({ siteId: site.id, includeGlobal: true })).map((t) => t.id)), new Set([t1.id, t2.id, g.id]));
  } finally {
    await env.close();
  }
});
