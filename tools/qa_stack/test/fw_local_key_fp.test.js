// Firmware LocalKeyFp (src/LocalKeyFp.h) + ConfigManager::localKeyFp JS portunun UYUMLULUK testi: firmware Unity testinin
// (ev_otomasyon_servis_yazilimi/waveshare_s3_demo/test/test_lk_fp/test_main.cpp) portu + sozlesme 1 ortak test vektorleri (sunucu ve arac
// testleriyle ayni). lk_fp = HMAC-SHA256(local_key ASCII, "ahbu-lk-fp/1|" + buyuk harfli UID) hex'inin ilk 8 karakteri (pano-5).
import test from 'node:test';
import assert from 'node:assert/strict';
import { MSG_PREFIX, buildMessage, toHex8, valid, compute } from '../sim/fw/local_key_fp.js';
import { ConfigManager, NvsImage } from '../sim/fw/config_manager.js';

test('fw_local_key_fp: ileti = onek + buyuk harfli UID; bos/uzun UID reddedilir', () => {
  assert.equal(MSG_PREFIX, 'ahbu-lk-fp/1|');
  assert.equal(buildMessage('AHBU-S3-DD8754'), 'ahbu-lk-fp/1|AHBU-S3-DD8754');
  assert.equal(buildMessage('ahbu-s3-0a1b2c'), 'ahbu-lk-fp/1|AHBU-S3-0A1B2C');
  assert.equal(buildMessage(''), null);
  assert.equal(buildMessage(null), null);
  assert.equal(buildMessage('A'.repeat(33)), null);
  assert.equal(buildMessage('A'.repeat(32)), `ahbu-lk-fp/1|${'A'.repeat(32)}`);
});

test('fw_local_key_fp: ilk 4 bayt kucuk harf hex; gecerli iz bicimi', () => {
  assert.equal(toHex8(Buffer.from([0xC7, 0x07, 0x65, 0x62, 0xFF])), 'c7076562');
  assert.equal(valid('c7076562'), true);
  assert.equal(valid('0000abcd'), true);
  for (const v of ['C7076562', 'c707656', 'c70765621', 'c70765g2', '', null, undefined, 12345678]) assert.equal(valid(v), false, String(v));
});

test('fw_local_key_fp: sozlesme vektorleri', () => {
  assert.equal(compute('ABCDEFGH23456789', 'AHBU-S3-DD8754'), 'c7076562');
  assert.equal(compute('k3yTEST-9999', 'AHBU-S3-0A1B2C'), '9814f286');
  assert.equal(compute('k3yTEST-9999', 'ahbu-s3-0a1b2c'), '9814f286');
  assert.equal(compute('', 'AHBU-S3-DD8754'), null);
  assert.equal(compute(null, 'AHBU-S3-DD8754'), null);
  assert.equal(compute('ABCDEFGH23456789', ''), null);
});

test('fw_local_key_fp: ConfigManager.localKeyFp provizyonluyken iz, provizyonsuzken null; anahtar degisince yeniden hesaplanir', () => {
  const cm = new ConfigManager(new NvsImage(null));
  cm.begin();
  const uid = 'AHBU-S3-DD8754';
  assert.equal(cm.localKeyFp(uid), null, 'provizyonsuz: iz yok');
  const g0 = cm.keyGeneration();
  assert.equal(cm.provisionIfEmpty('ABCDEFGH23456789', 'ap-pass-1234'), 'ok');
  assert.ok(cm.keyGeneration() !== g0, 'anahtar degisim sayaci artar');
  assert.equal(cm.localKeyFp(uid), 'c7076562');
  assert.equal(cm.localKeyFp(uid), 'c7076562', 'onbellekten');
  const g1 = cm.keyGeneration();
  assert.equal(cm.setLocalKey('k3yTEST-9999'), true);
  assert.ok(cm.keyGeneration() !== g1);
  assert.equal(cm.localKeyFp('AHBU-S3-0A1B2C'), '9814f286');
  assert.equal(cm.setLocalKey('kisa'), false, 'gecersiz anahtar: degismez');
  assert.equal(cm.localKeyFp('AHBU-S3-0A1B2C'), '9814f286');
  cm.clearLocalKey();
  assert.equal(cm.localKeyFp('AHBU-S3-0A1B2C'), null, 'RESETKEY: iz yok');
});
