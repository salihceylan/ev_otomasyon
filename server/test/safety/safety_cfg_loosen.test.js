'use strict';

// Faz 2 / WP-C2 (F2.D.4): gevsetme siniflandirmasinin sunucu portu (utils/safety_cfg_loosen.js) firmware isLoosening ile
// AYRISMAZ: ortak vektor dosyasi firmware JS portundan uretilir (tools/qa_stack/sim/fw/fixtures/loosening_vectors.json) ve
// sunucu her vektorde ayni sonucu vermelidir. Sunucu portu yalniz DENETIM KAYDI ve bilgi icindir (yetki karari degil).

const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('path');
const fs = require('fs');

const { isLoosening, isGasRelease, isIntrusionLoosening, diUseMask } = require('../../src/utils/safety_cfg_loosen');

const FIXTURE = path.join(__dirname, '..', '..', '..', 'tools', 'qa_stack', 'sim', 'fw', 'fixtures', 'loosening_vectors.json');

test('ortak vektorler: sunucu portu firmware portuyla HER vektorde ayni sonucu verir', () => {
  const { vectors } = JSON.parse(fs.readFileSync(FIXTURE, 'utf8'));
  assert.ok(vectors.length >= 40);
  const wrong = vectors.filter((v) => isLoosening(v.a, v.b, BigInt(v.di_hist)) !== v.expected).map((v) => v.name);
  assert.deepEqual(wrong, []);
});

test('diUseMask: kablolu sensor/kumanda satirlari ve vana geri bildirim girisleri (kopru haric)', () => {
  const doc = {
    sensors: [{ id: 'd3', kind: 'water' }, { id: 'b2', kind: 'smoke' }, { id: 'd40', kind: 'door' }],
    actuators: [{ id: 'a1', relay: 5, kind: 'valve', fb_di: 6 }, { id: 'a2', relay: 7, kind: 'siren', fb_di: 0 }],
  };
  assert.equal(diUseMask(doc), (1n << 2n) | (1n << 39n) | (1n << 5n));
  assert.equal(diUseMask({}), 0n);
  assert.equal(diUseMask(null), 0n);
});

test('bozuk/eksik belge firlatmaz (bos tablo sayilir)', () => {
  assert.equal(isLoosening(null, null), false);
  assert.equal(isLoosening({ policy: { on: true } }, { policy: { on: false } }), true);
  assert.equal(isLoosening({ sensors: 'x', actuators: 5 }, {}), false);
});

// Faz 2 incelemesi G-1: bulut yolunun UYGULAYAMADIGI iki sinif (firmware isGasRelease / isIntrusionLoosening) ayni vektorlerle
// firmware portundan ayrismaz. Sunucu bunlari YETKI kararinda kullanir: gaz -> 403 GAS_VALVE_LOCAL_ONLY, kurulu kipte hirsiz
// zayiflatmasi -> 409 INTRUSION_ARMED (firmware de reddeder: gas_local_only / armed).
test('ortak vektorler: isGasRelease ve isIntrusionLoosening firmware portuyla HER vektorde ayni', () => {
  const { vectors } = JSON.parse(fs.readFileSync(FIXTURE, 'utf8'));
  assert.ok(vectors.every((v) => typeof v.gas_release === 'boolean' && typeof v.intrusion_loosening === 'boolean'));
  assert.ok(vectors.some((v) => v.gas_release) && vectors.some((v) => v.intrusion_loosening));
  const wrongGas = vectors.filter((v) => isGasRelease(v.a, v.b, BigInt(v.di_hist)) !== v.gas_release).map((v) => v.name);
  const wrongIntr = vectors.filter((v) => isIntrusionLoosening(v.a, v.b, BigInt(v.di_hist)) !== v.intrusion_loosening).map((v) => v.name);
  assert.deepEqual(wrongGas, []);
  assert.deepEqual(wrongIntr, []);
});

test('G-1 siniflari bozuk belgede firlatmaz (false)', () => {
  assert.equal(isGasRelease(null, null), false);
  assert.equal(isIntrusionLoosening({ sensors: 5 }, 'x'), false);
});
