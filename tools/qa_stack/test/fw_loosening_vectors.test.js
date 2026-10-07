// Faz 2 F2.D.4: gevsetme ortak test vektorleri (sim/fw/fixtures/loosening_vectors.json) firmware portundan (safety_cfg_edit.js
// isLoosening) URETILIR; sunucu portu ayni dosyayi okur. Bu test dosyanin portla guncel oldugunu denetler (port degisirse:
// `node sim/fw/fixtures/gen_loosening_vectors.js`).
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { FIXTURE, renderFixture, buildVectors } from '../sim/fw/fixtures/gen_loosening_vectors.js';

test('loosening_vectors.json firmware portuyla guncel (yeniden uretilmis cikti birebir ayni)', () => {
  assert.equal(fs.readFileSync(FIXTURE, 'utf8'), renderFixture());
});

test('vektor kumesi her iki sonucu ve temel kurallari kapsar', () => {
  const v = buildVectors();
  assert.ok(v.length >= 40);
  assert.ok(v.some((x) => x.expected) && v.some((x) => !x.expected));
  const byName = Object.fromEntries(v.map((x) => [x.name, x.expected]));
  assert.equal(byName['ayni yapilandirma'], false);
  assert.equal(byName['politika kapatma'], true);
  assert.equal(byName['hic kullanilmamis DI ye yeni gas_reset'], false);
  assert.equal(byName['gecmiste kullanilmis DI ye yeni gas_reset'], true);
});

// Faz 2 incelemesi G-1: bulut yolunun uygulayamadigi iki sinif da vektorlerde (sunucu portu ayni sonucu vermeli)
test('vektorler gas_release ve intrusion_loosening siniflarini iki yonlu kapsar', () => {
  const v = buildVectors();
  const by = Object.fromEntries(v.map((x) => [x.name, x]));
  for (const k of ['gas_release', 'intrusion_loosening']) {
    assert.ok(v.some((x) => x[k] === true) && v.some((x) => x[k] === false), k);
  }
  assert.equal(by['gaz vanasini suya cevirme'].gas_release, true);
  assert.equal(by['gaz vanasini silme'].gas_release, true);
  assert.equal(by['gaz vanasi bolge daraltma (acmaz)'].gas_release, false);
  assert.equal(by['gaz vanasi bolge daraltma (acmaz)'].expected, true);
  assert.equal(by['onundeki siren silinince gaz vanasi kayar (kimlik ayni)'].gas_release, false);
  assert.equal(by['kapi kontagini gas_reset yapma'].gas_release, true);
  assert.equal(by['kapi alarm disi (flags 0)'].intrusion_loosening, true);
  assert.equal(by['kapi alarm disi (flags 0)'].expected, false);
  assert.equal(by['kapi sensoru silme (tehlike degil)'].intrusion_loosening, true);
  assert.equal(by['giris gecikmesini kisaltma'].intrusion_loosening, false);
  assert.equal(by['gecmiste kullanilmis DI ye yeni arm_key'].intrusion_loosening, true);
  assert.equal(by['hareket evde de etkin (sikilastirma)'].intrusion_loosening, false);
  for (const x of v) if (x.gas_release) assert.equal(x.expected, true, `${x.name}: gaz acma sinifi LAN gevsetmesinin alt kumesi`);
});
