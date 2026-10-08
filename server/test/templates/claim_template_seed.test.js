'use strict';

// Faz 1 / IP-1.5 (K-S8): claim entegrasyonu. Envanter karti bir daireye bagliysa ev adi "<site> <blok>-<no>", uc noktalar
// karta SON BASARIYLA yazilan sablon surumunden tohumlanir (lamba/darbe/panjur cifti, oda, sure, eylemci, dimmer) ve daire
// `installed` olur. Bagli degilse davranis AYNEN (sabit tohum). Hata olursa (PIN) daire durumu degismez (tek transaction).
// Sahte dunya (test/devices/_world.js) uretim SQL'inin anlamini taklit eder.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const { createWorld, createServices, setTestEnv, expectHttp, uid } = require('../devices/_world');
const { endpointRowsFromTemplate } = require('../../src/utils/template_schema');

const FIX = path.join(__dirname, '..', '..', '..', 'docs', 'contracts', 'template', 'fixtures');
const fixture = (f) => JSON.parse(fs.readFileSync(path.join(FIX, f), 'utf8'));
const PIN = '123456';
const UUID = 'AHBU-S3-0001';

function setup() {
  setTestEnv();
  const world = createWorld();
  const svc = createServices(world);
  const customer = world.helpers.addUser({ email: 'ev.sahibi@example.test' });
  const inv = world.helpers.addInventory({ uuid: UUID, pin: PIN });
  const act = (user) => ({ userId: user.id, globalRole: user.role, ip: '10.0.0.7' });
  return { world, ...svc, customer, inv, act };
}

function linkFlat(world, { body = null, writes = null, status = 'written', siteDeleted = false } = {}) {
  const site = { id: uid(), name: 'Güneş Sitesi', deleted_at: siteDeleted ? new Date() : null };
  const flat = { id: uid(), site_id: site.id, block: 'A', number: '12', device_uuid: UUID, status };
  world.state.sites.push(site);
  world.state.site_flats.push(flat);
  if (body) {
    const templateId = body.meta.template_id;
    world.state.install_template_versions.push({ template_id: templateId, version: body.meta.version, body });
    const list = writes || [{ version: body.meta.version, result: 'ok' }];
    list.forEach((w, i) => {
      world.state.template_writes.push({
        id: i + 1, device_uuid: UUID, template_id: templateId, version: w.version, result: w.result,
        created_at: new Date(Date.parse('2026-10-08T10:00:00Z') + i * 1000),
      });
    });
  }
  return { site, flat };
}

const claim = (ctx, overrides = {}) =>
  ctx.deviceService.claimDevice({ actor: ctx.act(ctx.customer), deviceUuid: UUID, setupPin: PIN, ...overrides });

test('endpointRowsFromTemplate: tip/cift/sure/oda/eylemci/dimmer eslemesi (saf)', () => {
  const rows = endpointRowsFromTemplate(fixture('ok_3p1_vana_dimmer.json'));
  assert.equal(rows.length, 8);
  assert.deepEqual(rows[0], {
    channel_index: 1, name: 'Salon Panjur Yukarı', type: 'shutter', room: 'Salon', shutter_pair_index: 1,
    shutter_duration_sec: 25, actuator_type: null, dimmable: false, dimmer_source: null,
  });
  assert.equal(rows[3].shutter_pair_index, 2);
  assert.equal(rows[3].shutter_duration_sec, 30);
  assert.deepEqual(
    { type: rows[4].type, dimmable: rows[4].dimmable, dimmer_source: rows[4].dimmer_source, pair: rows[4].shutter_pair_index, sec: rows[4].shutter_duration_sec },
    { type: 'light', dimmable: true, dimmer_source: 'modbus', pair: null, sec: null }
  );
  assert.equal(rows[7].actuator_type, 'valve');
  assert.equal(rows[7].type, 'light', 'eylemci rolesi tipini korur (033)');
  const ext = endpointRowsFromTemplate(fixture('ok_dubleks_ekmodul16.json'));
  assert.equal(ext.length, 16);
  assert.equal(ext[14].actuator_type, 'siren');
  const imp = fixture('ok_1p1.json');
  imp.relays[7] = { ch: 8, name: 'Kapı Otomatı', room: '', type: 'impulse', pulse_ms: 500 };
  const r8 = endpointRowsFromTemplate(imp)[7];
  assert.equal(r8.type, 'impulse');
  assert.equal(r8.room, 'Genel', 'bos oda: addan turetilir, yoksa Genel');
  assert.equal(endpointRowsFromTemplate(fixture('bad_relay_count.json').template), null, 'gecersiz sablon: null');
});

test('daireye bagli + yazilmis sablon: ev adi daireden, uc noktalar sablondan, daire installed', async () => {
  const ctx = setup();
  const body = fixture('ok_3p1_vana_dimmer.json');
  const { flat } = linkFlat(ctx.world, { body });
  const r = await claim(ctx, { homeName: 'Kullanici Adi' });
  assert.equal(r.home_name, 'Güneş Sitesi A-12');
  const { state } = ctx.world;
  assert.equal(state.homes[0].name, 'Güneş Sitesi A-12');
  const dev = state.devices[0];
  const eps = state.endpoints.filter((e) => e.device_id === dev.id).sort((a, b) => a.channel_index - b.channel_index);
  assert.equal(eps.length, 8);
  assert.deepEqual(eps.map((e) => e.name), body.relays.map((x) => x.name));
  assert.equal(eps[2].room, 'Yatak Odası');
  assert.equal(eps[2].shutter_duration_sec, 30);
  assert.equal(eps[7].actuator_type, 'valve');
  assert.equal(eps[4].dimmable, true);
  assert.equal(flat.status, 'installed');
  assert.ok(!ctx.world.db.log.some((l) => l.sql.includes('generate_series')), 'sabit tohum kullanilmadi');
});

test('son BASARILI yazim esas: sonraki hatali yazim yok sayilir', async () => {
  const ctx = setup();
  const v1 = fixture('ok_1p1.json');
  linkFlat(ctx.world, { body: v1, writes: [{ version: 1, result: 'ok' }, { version: 1, result: 'error' }] });
  await claim(ctx);
  const eps = ctx.world.state.endpoints;
  assert.equal(eps.find((e) => e.channel_index === 4).name, 'Yatak Odası');
});

test('daireye bagli ama yazim yok: ev adi daireden, uc noktalar sabit tohumdan', async () => {
  const ctx = setup();
  const { flat } = linkFlat(ctx.world, { status: 'planned' });
  const r = await claim(ctx);
  assert.equal(r.home_name, 'Güneş Sitesi A-12');
  const eps = ctx.world.state.endpoints;
  assert.equal(eps.length, 8);
  assert.equal(eps.find((e) => e.channel_index === 1).name, 'Salon Panjur Yukarı');
  assert.equal(eps.find((e) => e.channel_index === 5).name, 'Salon Aydınlatma');
  assert.equal(flat.status, 'installed');
});

test('teslim edilmis daire durumu geri cekilmez', async () => {
  const ctx = setup();
  const { flat } = linkFlat(ctx.world, { status: 'handed_over' });
  await claim(ctx);
  assert.equal(flat.status, 'handed_over');
});

test('silinmis sitenin dairesi: bugunku davranis', async () => {
  const ctx = setup();
  linkFlat(ctx.world, { body: fixture('ok_1p1.json'), siteDeleted: true });
  const r = await claim(ctx, { homeName: 'Daire 5' });
  assert.equal(r.home_name, 'Daire 5');
  assert.equal(ctx.world.state.endpoints.find((e) => e.channel_index === 1).name, 'Salon Panjur Yukarı');
});

test('daireye bagli degil: davranis aynen (ad + sabit tohum)', async () => {
  const ctx = setup();
  const r = await claim(ctx, { homeName: 'Daire 5' });
  assert.equal(r.home_name, 'Daire 5');
  assert.equal(ctx.world.state.endpoints.length, 8);
  assert.ok(ctx.world.db.log.some((l) => l.sql.includes('generate_series')));
});

test('sahibin bos evi yeniden kullanilirsa adi daireden guncellenir', async () => {
  const ctx = setup();
  const home = ctx.world.helpers.addHome({ name: 'Evim', owner: ctx.customer });
  linkFlat(ctx.world, { body: fixture('ok_1p1.json') });
  const r = await claim(ctx);
  assert.equal(r.home_id, home.id);
  assert.equal(r.home_name, 'Güneş Sitesi A-12');
  assert.equal(home.name, 'Güneş Sitesi A-12');
});

test('yanlis PIN: daire durumu ve ev adi degismez (geri alma)', async () => {
  const ctx = setup();
  const { flat } = linkFlat(ctx.world, { body: fixture('ok_1p1.json') });
  await expectHttp(claim(ctx, { setupPin: '000000' }), 403, 'FORBIDDEN');
  assert.equal(flat.status, 'written');
  assert.equal(ctx.world.state.homes.length, 0);
  assert.equal(ctx.world.state.endpoints.length, 0);
});
