'use strict';

// Faz 1 / IP-1.3, IP-1.4, IP-1.6: site_template_service GERCEK PostgreSQL'de (yalitilmis gecici veritabani, migration 035).
// Site CRUD + flat_stats, toplu daire, kart baglama, yumusak silme (409 SITE_HAS_DEVICES), sablon surumleme (ayni govde
// surum artirmaz), surum degismezligi, 422 TEMPLATE_INVALID, yazim kaydi (usb|eth|lan; ok -> daire written), yerel anahtar
// (denetim kaydi; anahtar denetime yazilmaz). EV_PG_TEST_URL yoksa ATLANIR.

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

test('site_template_service gercek PG: uctan uca', { skip: PG_SKIP }, async () => {
  const env = await open('t035svc');
  if (!env) return;
  process.env.LOCAL_KEY_SECRET = process.env.LOCAL_KEY_SECRET || crypto.randomBytes(32).toString('hex');
  const secretBox = require('../../src/utils/secret_box');
  const { SiteTemplateService } = require('../../src/services/site_template_service');
  const svc = new SiteTemplateService({ db: env.db, secretBox });
  const { db } = env;
  try {
    const staff = (await db.query("INSERT INTO users (full_name, email, password_hash, role) VALUES ('Servis', 'svc035@example.test', 'x', 'service_user') RETURNING id")).rows[0];
    const actor = { userId: staff.id, globalRole: 'service_user', ip: '10.0.0.5' };

    // --- Site
    await expectHttp(svc.createSite(actor, { name: '' }), 400, 'VALIDATION');
    await expectHttp(svc.createSite(actor, { name: 'X', contact_email: 'bozuk' }), 400, 'VALIDATION');
    const site = await svc.createSite(actor, {
      name: 'Güneş Sitesi', address: 'Bahar Cd. 1', city: 'İzmir', district: 'Bornova', contact_name: 'Ali Veli',
      contact_phone: '+90 555 000 00 00', contact_email: 'Yonetim@Example.test', block_count: 2, flat_count: 48, notes: 'not',
    });
    assert.equal(site.name, 'Güneş Sitesi');
    assert.equal(site.contact_email, 'yonetim@example.test');
    const upd = await svc.updateSite(site.id, { notes: null, flat_count: 50 });
    assert.equal(upd.notes, null);
    assert.equal(upd.flat_count, 50);
    await expectHttp(svc.getSite(crypto.randomUUID()), 404, 'NOT_FOUND');

    // --- Toplu daire: var olan blok+no atlanir
    const b1 = await svc.bulkCreateFlats(site.id, { block: 'A', from: 1, to: 3, flat_type: '2+1' });
    assert.equal(b1.created.length, 3);
    const b2 = await svc.bulkCreateFlats(site.id, { block: 'A', from: 3, to: 4 });
    assert.equal(b2.created.length, 1);
    assert.equal(b2.skipped, 1);
    await expectHttp(svc.bulkCreateFlats(site.id, { block: 'A', from: 1, to: 600 }), 400, 'VALIDATION');
    let flats = await svc.listFlats(site.id);
    assert.deepEqual(flats.map((f) => `${f.block}-${f.number}`), ['A-1', 'A-2', 'A-3', 'A-4']);
    assert.ok(flats.every((f) => f.status === 'planned' && f.last_write === null));
    const sites = await svc.listSites();
    assert.deepEqual(sites.find((s) => s.id === site.id).flat_stats, { planned: 4, written: 0, installed: 0, handed_over: 0 });

    // --- Sablon: olustur (sunucu meta doldurur), ayni govde surum artirmaz, farkli govde v2
    await expectHttp(svc.createTemplate(actor, { site_id: site.id, body: fixture('bad_relay_count.json').template }), 422, 'TEMPLATE_INVALID');
    const raw = fixture('ok_1p1.json');
    raw.meta.template_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    raw.meta.version = 99;
    const t1 = await svc.createTemplate(actor, { site_id: site.id, body: raw });
    assert.equal(t1.current_version, 1);
    assert.equal(t1.body.meta.template_id, t1.id);
    assert.equal(t1.body.meta.version, 1);
    assert.equal(t1.body.meta.site_id, site.id);
    const same = await svc.updateTemplate(actor, t1.id, { body: raw });
    assert.equal(same.created, false);
    assert.equal(same.current_version, 1);
    const changed = fixture('ok_1p1.json');
    changed.relays[2].name = 'Salon Avize';
    const t2 = await svc.updateTemplate(actor, t1.id, { body: changed });
    assert.equal(t2.created, true);
    assert.equal(t2.current_version, 2);
    assert.equal(t2.body.meta.version, 2);
    const err = await expectHttp(svc.updateTemplate(actor, t1.id, { body: fixture('bad_light_runtime.json').template }), 422, 'TEMPLATE_INVALID');
    assert.equal(err.extra.error, 'invalid_runtime');
    assert.equal(err.extra.path, 'relays[2].runtime_s');
    const versions = await svc.listVersions(t1.id);
    assert.deepEqual(versions.map((v) => v.version), [2, 1]);
    assert.ok(versions.every((v) => /^[0-9a-f]{64}$/.test(v.sha256)));
    const v1 = await svc.getVersion(t1.id, '1');
    assert.equal(v1.body.relays[2].name, 'Salon Aydınlatma');
    assert.equal((await svc.getTemplate(t1.id)).body.relays[2].name, 'Salon Avize');
    await assert.rejects(db.query("UPDATE install_template_versions SET body = '{}' WHERE template_id = $1", [t1.id]), (e) => e.code === '55000');

    // Genel sablon + liste filtresi
    const g = await svc.createTemplate(actor, { site_id: null, body: fixture('ok_2p1_genel.json') });
    assert.equal(g.site_id, null);
    assert.deepEqual((await svc.listTemplates({ siteId: site.id })).map((t) => t.id), [t1.id]);
    assert.deepEqual(new Set((await svc.listTemplates({ siteId: site.id, includeGlobal: true })).map((t) => t.id)), new Set([t1.id, g.id]));
    assert.deepEqual(svc.validate({ body: fixture('ok_3p1_vana_dimmer.json') }), { ok: true });
    await expectHttp(Promise.resolve().then(() => svc.validate({ body: fixture('bad_mode.json').template })), 422, 'TEMPLATE_INVALID');

    // --- Daire guncelle + kart bagla
    const flatA1 = flats[0];
    const flatA2 = flats[1];
    await svc.updateFlat(site.id, flatA1.id, { template_id: t1.id });
    await expectHttp(svc.updateFlat(site.id, flatA2.id, { number: '1' }), 409, 'CONFLICT');
    await expectHttp(svc.updateFlat(site.id, flatA2.id, { status: 'bogus' }), 400, 'VALIDATION');
    const localKey = 'YerelAnahtar-035-abcdef';
    await db.query(
      "INSERT INTO device_inventory (device_uuid, mac_address, pin_hash, model, local_key_enc) VALUES ('AHBU-T035-0001', 'E8:F6:0A:35:00:01', 'x', 'M', $1)",
      [secretBox.encrypt(localKey)]
    );
    await expectHttp(svc.linkFlatDevice(site.id, flatA1.id, 'AHBU-YOK-0001'), 404, 'NOT_FOUND');
    const linked = await svc.linkFlatDevice(site.id, flatA1.id, 'ahbu-t035-0001');
    assert.equal(linked.device_uuid, 'AHBU-T035-0001');
    await expectHttp(svc.linkFlatDevice(site.id, flatA2.id, 'AHBU-T035-0001'), 409, 'DEVICE_ALREADY_LINKED');
    await expectHttp(svc.deleteFlat(site.id, flatA1.id), 409, 'CONFLICT');

    // --- Yazim kaydi: lan/eth/usb; ok -> written; last_write
    const base = { device_uuid: 'AHBU-T035-0001', template_id: t1.id, flat_id: flatA1.id };
    await expectHttp(svc.recordWrite(actor, { ...base, version: 9, via: 'usb', result: 'ok' }), 404, 'NOT_FOUND');
    await expectHttp(svc.recordWrite(actor, { ...base, version: 1, via: 'wifi', result: 'ok' }), 400, 'VALIDATION');
    const wErr = await svc.recordWrite(actor, { ...base, version: 1, via: 'eth', result: 'error', error_code: 'local_loosen_forbidden' });
    assert.equal(wErr.flat_status, 'planned');
    const wOk = await svc.recordWrite(actor, { ...base, version: 2, via: 'lan', result: 'ok' });
    assert.equal(wOk.flat_status, 'written');
    assert.equal(wOk.via, 'lan');
    await svc.recordWrite(actor, { device_uuid: 'AHBU-T035-0001', template_id: t1.id, version: 2, via: 'usb', result: 'ok' });
    flats = await svc.listFlats(site.id);
    const a1 = flats.find((f) => f.id === flatA1.id);
    assert.equal(a1.status, 'written');
    assert.equal(a1.last_write.version, 2);
    assert.equal(a1.last_write.via, 'lan');

    // --- Site silme: kart bagli -> 409; ayir -> silinir (listeden kalkar)
    await expectHttp(svc.deleteSite(site.id), 409, 'SITE_HAS_DEVICES');
    // --- Yerel anahtar: denetim kaydi, anahtar denetime yazilmaz
    const k = await svc.getInventoryLocalKey(actor, 'AHBU-T035-0001');
    assert.equal(k.local_key, localKey);
    const audit = await db.query("SELECT event, actor_user_id, actor_role, ip_address, details::text AS d FROM device_audit_logs WHERE device_uuid = 'AHBU-T035-0001'");
    assert.equal(audit.rows.length, 1);
    assert.equal(audit.rows[0].event, 'inventory_local_key_read');
    assert.equal(audit.rows[0].actor_user_id, staff.id);
    assert.equal(audit.rows[0].actor_role, 'service_user');
    assert.ok(!audit.rows[0].d.includes(localKey));
    await expectHttp(svc.getInventoryLocalKey(actor, 'AHBU-YOK-0001'), 404, 'NOT_FOUND');

    await svc.linkFlatDevice(site.id, flatA1.id, null);
    await svc.deleteSite(site.id);
    assert.ok(!(await svc.listSites()).some((s) => s.id === site.id));
    await expectHttp(svc.getSite(site.id), 404, 'NOT_FOUND');

    // --- Sablon yumusak silme: listeden kalkar, surumler ve yazimlar kalir
    await svc.deleteTemplate(t1.id);
    await expectHttp(svc.getTemplate(t1.id), 404, 'NOT_FOUND');
    assert.equal((await svc.listVersions(t1.id)).length, 2);
    assert.equal((await db.query('SELECT COUNT(*)::int AS n FROM template_writes WHERE template_id = $1', [t1.id])).rows[0].n, 3);
    await expectHttp(svc.deleteTemplate(t1.id), 404, 'NOT_FOUND');
  } finally {
    await env.close();
  }
});
