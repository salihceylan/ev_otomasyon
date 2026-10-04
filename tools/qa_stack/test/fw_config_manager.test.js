// ConfigManager.cpp (firmware) JS portu: kimlik/provizyon yardimcilari.
//  * setLocalKey / setApPass: RAM + NVS BIRLIKTE degisir ya da hicbiri (NVS yazilamazsa false, RAM eski degerde).
//  * provisionIfEmpty: ATOMIK ilk provizyon -- seri FACTORYINIT ve HTTP POST /api/factory/init ORTAK yolu (SERVIS-03/04):
//    tek kilit altinda "local_key bos mu" + bicim + ONCE ap_pass SONRA local_key; yarim kalirsa geri alma.
//  * NvsImage.failKeys: NVS yazma arizasi enjeksiyonu (bozuk/dolu NVS bolumu; firmware Preferences::putString 0 doner).
import test from 'node:test';
import assert from 'node:assert/strict';
import * as cmModule from '../sim/fw/config_manager.js';

const { ConfigManager, NvsImage } = cmModule;
const R = () => cmModule.ProvisionResult;

function makeCm() {
  const nvs = new NvsImage(null);
  const cm = new ConfigManager(nvs);
  cm.begin();
  return { nvs, cm };
}

const stored = (nvs) => nvs.get('cfg') || {};

/** NVS'e yazilan anahtarlari (deneme sirasiyla) kaydeder. */
function recordWrites(nvs) {
  const order = [];
  const orig = nvs.putKey.bind(nvs);
  nvs.putKey = (ns, key, value) => { order.push(key); return orig(ns, key, value); };
  return order;
}

test('setLocalKey/setApPass: NVS yazilamazsa false; RAM ESKI degerde kalir, NVS degismez (RAM + NVS birlikte ya da hicbiri)', () => {
  const { nvs, cm } = makeCm();
  assert.equal(cm.setLocalKey('ilk-anahtar-01'), true);
  assert.equal(cm.setApPass('ilk-parola-001'), true);
  assert.deepEqual([stored(nvs).lk, stored(nvs).ap_pw], ['ilk-anahtar-01', 'ilk-parola-001']);

  nvs.failKeys.add('lk');
  assert.equal(cm.setLocalKey('yeni-anahtar-02'), false);
  assert.equal(cm.config.local_key, 'ilk-anahtar-01', 'RAM geri alindi');
  assert.equal(stored(nvs).lk, 'ilk-anahtar-01', 'NVS degismedi');

  nvs.failKeys.add('ap_pw');
  assert.equal(cm.setApPass('yeni-parola-002'), false);
  assert.equal(cm.config.ap_pass, 'ilk-parola-001');
  assert.equal(stored(nvs).ap_pw, 'ilk-parola-001');

  // bicim hatasi NVS arizasindan bagimsiz: yine false, hicbir sey degismez
  nvs.failKeys.clear();
  assert.equal(cm.setLocalKey('kisa'), false);
  assert.equal(cm.config.local_key, 'ilk-anahtar-01');
  assert.equal(cm.setLocalKey('yeni-anahtar-02'), true, 'ariza gidince yazilir');
  assert.equal(stored(nvs).lk, 'yeni-anahtar-02');
});

test('clearLocalKey (seri RESETKEY): RAM her zaman silinir; NVS silinemezse false (firmware ile ayni)', () => {
  const { nvs, cm } = makeCm();
  cm.setLocalKey('ilk-anahtar-01');
  nvs.failKeys.add('lk');
  assert.equal(cm.clearLocalKey(), false);
  assert.equal(cm.hasLocalKey(), false, 'RAM silindi (yeniden acilista NVS degeri doner)');
  assert.equal(stored(nvs).lk, 'ilk-anahtar-01');
  nvs.failKeys.clear();
  assert.equal(cm.clearLocalKey(), true);
  assert.equal('lk' in stored(nvs), false);
  assert.equal(cm.clearLocalKey(), true, 'anahtar yoksa da basarili');
});

test('provisionIfEmpty: provizyonsuz cihazda ONCE ap_pass SONRA local_key yazar -> ok; provizyonluysa already_provisioned ve HICBIR SEY degismez', () => {
  const { nvs, cm } = makeCm();
  const order = recordWrites(nvs);
  assert.equal(cm.provisionIfEmpty('seri-anahtar-01', 'kurulum parola 1'), R().OK);
  assert.deepEqual(order, ['ap_pw', 'lk'], 'yazim sirasi: ap_pass, sonra local_key (CONTRACTS 3c)');
  assert.deepEqual([cm.config.local_key, cm.config.ap_pass], ['seri-anahtar-01', 'kurulum parola 1']);
  assert.deepEqual([stored(nvs).lk, stored(nvs).ap_pw], ['seri-anahtar-01', 'kurulum parola 1']);

  order.length = 0;
  assert.equal(cm.provisionIfEmpty('http-anahtar-02', 'baska-parola-2'), R().ALREADY);
  assert.equal(cm.provisionIfEmpty('kisa', 'x'), R().ALREADY, 'provizyonluysa bicimden ONCE denetlenir (CliParse/HTTP ile ayni)');
  assert.deepEqual(order, [], 'NVS\'e hic yazilmadi');
  assert.deepEqual([cm.config.local_key, cm.config.ap_pass], ['seri-anahtar-01', 'kurulum parola 1'], 'ikinci yazan EZEMEZ');
});

test('provisionIfEmpty: bicim hatasi -> invalid_key / invalid_ap_pass; NVS\'e HIC dokunulmaz (yarim provizyon yok)', () => {
  const { nvs, cm } = makeCm();
  const order = recordWrites(nvs);
  const bell = String.fromCharCode(7);
  const nonAscii = String.fromCharCode(0xE7);
  assert.equal(cm.provisionIfEmpty('kisa', 'kurulum-parola-1'), R().INVALID_KEY);
  assert.equal(cm.provisionIfEmpty('bosluk iceren', 'kurulum-parola-1'), R().INVALID_KEY);
  assert.equal(cm.provisionIfEmpty('k'.repeat(33), 'kurulum-parola-1'), R().INVALID_KEY);
  assert.equal(cm.provisionIfEmpty('gecerli-anahtar', 'kisa'), R().INVALID_AP_PASS);
  assert.equal(cm.provisionIfEmpty('gecerli-anahtar', `kontrol${bell}karakter`), R().INVALID_AP_PASS, 'HTTP yalniz uzunluk denetler; aralik burada');
  assert.equal(cm.provisionIfEmpty('gecerli-anahtar', `parola-${nonAscii}-1234`), R().INVALID_AP_PASS);
  assert.equal(cm.provisionIfEmpty('gecerli-anahtar', 'p'.repeat(33)), R().INVALID_AP_PASS);
  assert.deepEqual(order, []);
  assert.equal(cm.hasLocalKey(), false);
  assert.equal(cm.config.ap_pass, '');
});

test('provisionIfEmpty: ap_pass NVS\'e yazilamazsa storage; local_key DENENMEZ, hicbir sey degismez', () => {
  const { nvs, cm } = makeCm();
  nvs.failKeys.add('ap_pw');
  const order = recordWrites(nvs);
  assert.equal(cm.provisionIfEmpty('yeni-anahtar-02', 'yeni-parola-002'), R().STORAGE);
  assert.deepEqual(order, ['ap_pw']);
  assert.equal(cm.hasLocalKey(), false);
  assert.equal(cm.config.ap_pass, '');
  assert.equal(stored(nvs).lk || '', '');
});

test('provisionIfEmpty: local_key NVS\'e yazilamazsa storage; ap_pass ESKI degerine geri alinir, cihaz PROVIZYONSUZ kalir; ariza gidince yeniden denenir', () => {
  const { nvs, cm } = makeCm();
  // RESETKEY sonrasi gibi: eski ap_pass duruyor, local_key yok
  assert.equal(cm.provisionIfEmpty('eski-anahtar-01', 'eski-parola-001'), R().OK);
  assert.equal(cm.clearLocalKey(), true);
  nvs.failKeys.add('lk');
  assert.equal(cm.provisionIfEmpty('yeni-anahtar-02', 'yeni-parola-002'), R().STORAGE);
  assert.equal(cm.hasLocalKey(), false);
  assert.deepEqual([cm.config.ap_pass, stored(nvs).ap_pw], ['eski-parola-001', 'eski-parola-001'], 'ap_pass RAM + NVS geri alindi');
  assert.equal('lk' in stored(nvs), false);

  nvs.failKeys.clear();
  assert.equal(cm.provisionIfEmpty('yeni-anahtar-02', 'yeni-parola-002'), R().OK, 'yeniden denenebilir');
  assert.deepEqual([stored(nvs).lk, stored(nvs).ap_pw], ['yeni-anahtar-02', 'yeni-parola-002']);
});

test('provisionIfEmpty: fabrika cihazinda (ap_pass hic yok) local_key yazilamazsa ap_pass NVS\'ten de kaldirilir; yeniden acilista bos', () => {
  const { nvs, cm } = makeCm();
  nvs.failKeys.add('lk');
  assert.equal(cm.provisionIfEmpty('yeni-anahtar-02', 'yeni-parola-002'), R().STORAGE);
  assert.equal(cm.config.ap_pass, '');
  assert.equal(stored(nvs).ap_pw || '', '');
  const again = new ConfigManager(nvs);
  again.begin();
  assert.deepEqual([again.config.local_key, again.config.ap_pass], ['', ''], 'yeniden acilis: provizyonsuz, ap_pass bos');
});
