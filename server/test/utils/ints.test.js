'use strict';

const test = require('node:test');
const assert = require('node:assert');

const { toBoundedInt, MAX_OFFSET } = require('../../src/utils/ints');

const OFFSET = { min: 0, max: MAX_OFFSET, fallback: 0 };

test('40 haneli sayi: 1e+39 DEGIL, ust sinira kirpilir (PG bigint hatasi uretmez)', () => {
  const v = toBoundedInt('9'.repeat(40), OFFSET);
  // 18 haneden uzun dizgi duz tamsayi sayilmaz -> fallback; her durumda SQL'e guvenli bir sayi gider.
  assert.ok(Number.isInteger(v));
  assert.ok(v >= 0 && v <= MAX_OFFSET);
  assert.ok(!String(v).includes('e'));
});

test('18 haneye kadar buyuk sayi ust sinira kirpilir', () => {
  assert.strictEqual(toBoundedInt('999999999999999999', OFFSET), MAX_OFFSET);
  assert.strictEqual(toBoundedInt(5e15, OFFSET), MAX_OFFSET);
});

test('gecersiz girdiler fallback olur: ussel gösterim, hex, harf karisik, bos, null, obje, NaN, Infinity', () => {
  for (const bad of ['1e5', '0x10', '12abc', 'abc', '', ' ', null, undefined, {}, [], NaN, Infinity, -Infinity]) {
    assert.strictEqual(toBoundedInt(bad, { min: 0, max: 100, fallback: 7 }), 7, String(bad));
  }
});

test('aralik kirpma ve zeroIsFallback', () => {
  const lim = { min: 1, max: 100, fallback: 50, zeroIsFallback: true };
  assert.strictEqual(toBoundedInt('0', lim), 50);
  assert.strictEqual(toBoundedInt('-5', lim), 1);
  assert.strictEqual(toBoundedInt('1000', lim), 100);
  assert.strictEqual(toBoundedInt(' 25 ', lim), 25);
  assert.strictEqual(toBoundedInt('+30', lim), 30);
  assert.strictEqual(toBoundedInt(12.9, lim), 12);
  assert.strictEqual(toBoundedInt('0', { min: 0, max: 10, fallback: 3 }), 0);
});
