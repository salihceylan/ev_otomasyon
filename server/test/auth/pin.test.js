'use strict';

const test = require('node:test');
const assert = require('node:assert');
const crypto = require('crypto');
const { setTestEnv } = require('./_helpers');

setTestEnv();
const pin = require('../../src/utils/pin');

test('pin: hashPin "h1$" + 64 hex uretir ve deterministiktir', () => {
  const h1 = pin.hashPin('123456');
  const h2 = pin.hashPin(' 123456 ');
  assert.match(h1, /^h1\$[0-9a-f]{64}$/);
  assert.strictEqual(h1, h2);
  assert.notStrictEqual(pin.hashPin('123457'), h1);
});

test('pin: ozet yalin SHA-256 degildir (pepper kullanilir)', () => {
  const plain = crypto.createHash('sha256').update('123456').digest('hex');
  assert.notStrictEqual(pin.hashPin('123456').slice(3), plain);
});

test('pin: farkli PIN_PEPPER farkli ozet uretir', () => {
  const before = pin.hashPin('654321');
  const saved = process.env.PIN_PEPPER;
  process.env.PIN_PEPPER = crypto.randomBytes(40).toString('hex');
  try {
    assert.notStrictEqual(pin.hashPin('654321'), before);
  } finally {
    process.env.PIN_PEPPER = saved;
  }
});

test('pin: verifyPin dogru/yanlis PIN', () => {
  const stored = pin.hashPin('246810');
  assert.strictEqual(pin.verifyPin('246810', stored), true);
  assert.strictEqual(pin.verifyPin('246811', stored), false);
  assert.strictEqual(pin.verifyPin('', stored), false);
  assert.strictEqual(pin.verifyPin(null, stored), false);
  assert.strictEqual(pin.verifyPin('246810', ''), false);
  assert.strictEqual(pin.verifyPin('246810', null), false);
});

test('pin: eski tuzsuz SHA-256 ozeti dogrulanir ve yukseltme ozeti doner', () => {
  const legacy = crypto.createHash('sha256').update('112233').digest('hex');
  assert.strictEqual(pin.needsUpgrade(legacy), true);
  assert.strictEqual(pin.verifyPin('112233', legacy), true);
  assert.strictEqual(pin.verifyPin('112234', legacy), false);

  const ok = pin.verifyAndUpgrade('112233', legacy.toUpperCase());
  assert.strictEqual(ok.valid, true);
  assert.strictEqual(ok.upgradedHash, pin.hashPin('112233'));

  const bad = pin.verifyAndUpgrade('000000', legacy);
  assert.deepStrictEqual(bad, { valid: false, upgradedHash: null });

  const current = pin.verifyAndUpgrade('112233', pin.hashPin('112233'));
  assert.deepStrictEqual(current, { valid: true, upgradedHash: null });
  assert.strictEqual(pin.needsUpgrade(pin.hashPin('112233')), false);
});

test('pin: duz metin veya taninmayan bicim ASLA kabul edilmez', () => {
  assert.strictEqual(pin.verifyPin('123456', '123456'), false);
  assert.strictEqual(pin.verifyPin('123456', 'h1$zz'), false);
  assert.strictEqual(pin.verifyPin('123456', '$2a$10$abcdefghijklmnopqrstuv'), false);
});

test('pin: PIN_PEPPER yoksa/kisaysa fail-closed (hash ve dogrulama hata firlatir)', () => {
  const saved = process.env.PIN_PEPPER;
  try {
    delete process.env.PIN_PEPPER;
    assert.throws(() => pin.assertPinConfig(), pin.PinConfigError);
    assert.throws(() => pin.hashPin('123456'), pin.PinConfigError);
    const legacy = crypto.createHash('sha256').update('123456').digest('hex');
    assert.throws(() => pin.verifyPin('123456', legacy), pin.PinConfigError);

    process.env.PIN_PEPPER = 'kisa';
    assert.throws(() => pin.assertPinConfig(), /PIN_PEPPER/);
  } finally {
    process.env.PIN_PEPPER = saved;
  }
  assert.strictEqual(pin.assertPinConfig(), true);
});

test('pin: bos PIN ozetlenemez', () => {
  assert.throws(() => pin.hashPin('   '), TypeError);
});
