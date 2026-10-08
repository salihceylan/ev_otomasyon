'use strict';

// Faz 1 / IP-1.2: ahbu-template/1 dogrulayicisi (utils/template_schema.js) ORTAK ornek dosyalarla sinanir
// (docs/contracts/template/fixtures). ok_* -> gecerli; bad_* -> tam olarak `expect` kodu (+ path dolu).

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const { validateTemplate, canonicalJson, bodySha256, withMeta } = require('../../src/utils/template_schema');

const FIX = path.join(__dirname, '..', '..', '..', 'docs', 'contracts', 'template', 'fixtures');
const files = fs.readdirSync(FIX).filter((f) => f.endsWith('.json')).sort();
const load = (f) => JSON.parse(fs.readFileSync(path.join(FIX, f), 'utf8'));
const clone = (o) => JSON.parse(JSON.stringify(o));

test('ornek dosyalar bulundu (ok_* ve bad_*)', () => {
  assert.ok(files.filter((f) => f.startsWith('ok_')).length >= 4);
  assert.ok(files.filter((f) => f.startsWith('bad_')).length >= 20);
});

for (const f of files.filter((x) => x.startsWith('ok_'))) {
  test(`gecerli: ${f}`, () => {
    const r = validateTemplate(load(f));
    assert.deepEqual(r, { ok: true });
  });
}

for (const f of files.filter((x) => x.startsWith('bad_'))) {
  test(`gecersiz: ${f}`, () => {
    const { expect, template } = load(f);
    const r = validateTemplate(template);
    assert.equal(r.ok, false, 'gecersiz sayilmali');
    assert.equal(r.error, expect, `kod (path=${r.path})`);
    assert.equal(typeof r.path, 'string');
  });
}

test('path bicimi: relays[i].alan', () => {
  const t = load('ok_1p1.json');
  t.relays[3].name = '';
  assert.deepEqual(validateTemplate(t), { ok: false, error: 'invalid_name', path: 'relays[3].name' });
  const t2 = load('ok_1p1.json');
  t2.relays[0].runtime_s = 301;
  t2.relays[1].runtime_s = 301;
  assert.deepEqual(validateTemplate(t2), { ok: false, error: 'invalid_runtime', path: 'relays[0].runtime_s' });
});

test('kok / meta kodlari (firmware TemplateParse ile ayni)', () => {
  assert.deepEqual(validateTemplate(null), { ok: false, error: 'bad_field', path: 'template' });
  assert.equal(validateTemplate([]).error, 'bad_field');
  const cases = [
    [(t) => { t.meta.template_id = 'ABC'; }, 'invalid_template_id', 'meta.template_id'],
    [(t) => { t.meta.template_id = t.meta.template_id.toUpperCase(); }, 'invalid_template_id', 'meta.template_id'],
    [(t) => { t.meta.version = 0; }, 'invalid_version', 'meta.version'],
    [(t) => { t.meta.name = 'x'.repeat(49); }, 'invalid_name', 'meta.name'],
    [(t) => { t.meta.flat_type = ''; }, 'invalid_flat_type', 'meta.flat_type'],
    [(t) => { t.meta.site_id = 'yok'; }, 'invalid_site_id', 'meta.site_id'],
    [(t) => { delete t.meta.site_id; }, 'bad_field', 'meta.site_id'],
    [(t) => { t.meta.fazla = 1; }, 'bad_field', 'meta.fazla'],
    [(t) => { t.meta = 'x'; }, 'bad_field', 'meta'],
    [(t) => { delete t.safety; }, 'bad_field', 'safety'],
    [(t) => { t.ext_module.enabled = 1; }, 'bad_field', 'ext_module.enabled'],
    [(t) => { t.relays[2].room = 'x'.repeat(32); }, 'invalid_room', 'relays[2].room'],
    [(t) => { t.relays[2].load = 5; }, 'invalid_load', 'relays[2].load'],
    [(t) => { t.relays[2].fazla = 5; }, 'bad_field', 'relays[2].fazla'],
    [(t) => { t.dis[1].wiring = 'x'.repeat(49); }, 'invalid_wiring', 'dis[1].wiring'],
    [(t) => { t.relays[0].type = 'light'; delete t.relays[0].runtime_s; }, 'invalid_shutter_pair', 'relays[0].type'],
  ];
  for (const [mut, code, path] of cases) {
    const t = load('ok_1p1.json');
    mut(t);
    assert.deepEqual(validateTemplate(t), { ok: false, error: code, path }, code + ' ' + path);
  }
  const t3 = load('ok_1p1.json');
  t3.meta.site_id = null;
  assert.deepEqual(validateTemplate(t3), { ok: true });
});

test('safety kodlari: zones, oge ayristirici (SafetyCfgApi), count, act_zone, invalid_light, capraz kurallar', () => {
  const cases = [
    [(t) => { t.safety.zones = [{ id: 2, name: 'Kat' }]; t.safety.sensors = []; t.safety.actuators[0].zones = [2]; }, 'bad_zone', 'safety.zones'],
    [(t) => { t.safety.zones.push({ id: 1, name: 'Tekrar' }); }, 'bad_zone', 'safety.zones[1].id'],
    [(t) => { t.safety.zones[0].name = ''; }, 'bad_name', 'safety.zones[0].name'],
    [(t) => { t.safety.zones = 'x'; }, 'bad_zone', 'safety.zones'],
    [(t) => { t.safety.policy.on = 1; }, 'bad_field', 'safety.policy'],
    [(t) => { t.safety.intrusion = { exit_s: 300 }; }, 'bad_value', 'safety.intrusion.exit_s'],
    [(t) => { t.safety.sensors[0].id = 'd41'; }, 'bad_id', 'safety.sensors[0]'],
    [(t) => { t.safety.sensors[0].id = 'd9'; }, 'sensor_di_range', 'safety.sensors'],
    [(t) => { t.safety.sensors[0].kind = 'fire'; }, 'bad_kind', 'safety.sensors[0]'],
    [(t) => { t.safety.sensors[0].zone = '1'; }, 'bad_zone', 'safety.sensors[0]'],
    [(t) => { t.safety.sensors[0].active_open = 2; }, 'bad_value', 'safety.sensors[0]'],
    [(t) => { t.safety.sensors[0].name = 'x'.repeat(20); }, 'bad_name', 'safety.sensors[0]'],
    [(t) => { t.safety.sensors[0].fazla = 1; }, 'bad_field', 'safety.sensors[0]'],
    [(t) => { t.safety.sensors[0].confirm_ms = 50; }, 'confirm_range', 'safety.sensors'],
    [(t) => { t.safety.sensors = 'x'; }, 'bad_field', 'safety.sensors'],
    [(t) => { t.safety.sensors = Array.from({ length: 57 }, () => ({})); }, 'count', 'safety.sensors'],
    [(t) => { t.safety.actuators[0].id = 'a1'; }, 'bad_field', 'safety.actuators[0]'],
    [(t) => { t.safety.actuators[0].relay = 41; }, 'bad_relay', 'safety.actuators[0]'],
    [(t) => { t.safety.actuators[0].relay = 9; }, 'act_relay_range', 'safety.actuators'],
    [(t) => { t.safety.actuators[0].kind = 'pump'; }, 'bad_kind', 'safety.actuators[0]'],
    [(t) => { t.safety.actuators[0].medium = 'oil'; }, 'bad_value', 'safety.actuators[0]'],
    [(t) => { t.safety.actuators[0].zones = [5]; }, 'bad_zone', 'safety.actuators[0]'],
    [(t) => { t.safety.actuators[0].zones = [2]; }, 'act_zone', 'safety.actuators[0].zones'],
    [(t) => { t.safety.actuators[0].zones = []; }, 'act_zone', 'safety.actuators'],
    [(t) => { delete t.safety.actuators[0].medium; }, 'valve_medium', 'safety.actuators'],
    [(t) => { t.safety.actuators[0].close_mode = 'pulse'; }, 'pulse_relay2', 'safety.actuators'],
    [(t) => { t.relays[7].type = 'impulse'; t.relays[7].pulse_ms = 500; }, 'act_relay_impulse', 'safety.actuators'],
    [(t) => { t.safety.actuators[0].fb_di = 3; }, 'fb_di_conflict', 'safety.actuators'],
    [(t) => { t.safety.actuators.push({ relay: 7, kind: 'siren', zones: [1], run_limit_s: 5 }); }, 'siren_run_limit', 'safety.actuators'],
    [(t) => { t.safety.lights[0].relay = 1; }, 'invalid_light', 'safety.lights[0].relay'],
    [(t) => { t.safety.lights.push({ relay: 5 }); }, 'invalid_light', 'safety.lights[1].relay'],
    [(t) => { t.safety.lights[0].src = 3; }, 'bad_value', 'safety.lights[0]'],
    [(t) => { t.safety.lights[0].relay = 0; }, 'bad_relay', 'safety.lights[0]'],
    [(t) => { t.safety.lights = Array.from({ length: 9 }, () => ({})); }, 'count', 'safety.lights'],
    [(t) => { t.safety.sensors.push({ id: 'd5', kind: 'arm_key', zone: 0, active_open: 0, name: 'Anahtar' }); t.dis[4].target_relay = 0; }, 'arm_key_not_nc', 'safety.sensors'],
    [(t) => { t.safety.sensors.push({ id: 'b1', kind: 'alarm_ack', zone: 0 }); }, 'sensor_src', 'safety.sensors'],
  ];
  for (const [mut, code, path] of cases) {
    const t = load('ok_3p1_vana_dimmer.json');
    mut(t);
    assert.deepEqual(validateTemplate(t), { ok: false, error: code, path }, code + ' ' + path);
  }
  const ok = load('ok_3p1_vana_dimmer.json');
  ok.safety.sensors.push({ id: 'b2', kind: 'water', zone: 1, active_open: false, flags: 5, confirm_ms: 2000, name: 'Köprü Su' });
  ok.safety.intrusion = { exit_s: 45, entry_s: 30 };
  assert.deepEqual(validateTemplate(ok), { ok: true });
});

test('withMeta sunucu kimligini/surumunu yazar; canonicalJson anahtar sirasindan bagimsiz; sha256 kararli', () => {
  const t = load('ok_1p1.json');
  const id = '11111111-2222-4333-8444-555555555555';
  const out = withMeta(t, { templateId: id, version: 7, siteId: null });
  assert.equal(out.meta.template_id, id);
  assert.equal(out.meta.version, 7);
  assert.equal(out.meta.site_id, null);
  assert.equal(t.meta.version, 1, 'girdi degismez');
  const a = { b: 1, a: { d: [1, { y: 1, x: 2 }], c: 'ş' } };
  const b = { a: { c: 'ş', d: [1, { x: 2, y: 1 }] }, b: 1 };
  assert.equal(canonicalJson(a), canonicalJson(b));
  assert.equal(bodySha256(a), bodySha256(clone(b)));
  assert.match(bodySha256(a), /^[0-9a-f]{64}$/);
});
