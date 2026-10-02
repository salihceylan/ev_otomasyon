// Firmware NetUtil.h JS portu: NetUtil.h'nin Unity testi yoktur (Arduino.h'a bagimli); ozellikler dosyadaki
// belgelenmis davranislardan elle turetilmistir.
import test from 'node:test';
import assert from 'node:assert/strict';
import * as netutil from '../sim/fw/netutil.js';
import {
  constantTimeEquals, isCleanUtf8, sanitizeUtf8, sanitizeInto, copyUtf8Truncated,
  parseIntStrict, epochFromUtc, isPrintableAsciiNoSpace, utf8SeqLen, MIN_VALID_EPOCH,
} from '../sim/fw/netutil.js';

test('fw_netutil: N6 -- timeReached firmware NetUtil.h icinden KALDIRILDI (isaretli hedef zaman deseni yok); zamanlayicilar net_time.js icindedir', () => {
  assert.equal('timeReached' in netutil, false, 'isaretli "hedef zaman gecti mi" yardimcisi geri eklenmemeli (24,86 gunde zamanlayici dondurur)');
  assert.equal(MIN_VALID_EPOCH, 1700000000, 'isTimeSynced esigi: Kasim 2023 sonrasi');
});

test('fw_netutil: constantTimeEquals uzunluk farkini da sonuca katar; null bos sayilir', () => {
  assert.equal(constantTimeEquals('abc', 'abc'), true);
  assert.equal(constantTimeEquals('abc', 'abd'), false);
  assert.equal(constantTimeEquals('abc', 'abcd'), false);
  assert.equal(constantTimeEquals('abcd', 'abc'), false);
  assert.equal(constantTimeEquals(null, ''), true);
  assert.equal(constantTimeEquals('', null), true);
  assert.equal(constantTimeEquals(null, 'x'), false);
  assert.equal(constantTimeEquals('a\u0000b', 'a'), true, 'C string semantigi: ilk NUL sonlandirir');
});

test('fw_netutil: utf8SeqLen RFC 3629 siniri (overlong / vekil / >U+10FFFF)', () => {
  const len = (...bytes) => utf8SeqLen(Buffer.from(bytes), 0, bytes.length);
  assert.equal(len(0x41), 1);
  assert.equal(len(0xC3, 0xBC), 2);
  assert.equal(len(0xC0, 0x80), 0, 'overlong 2 bayt');
  assert.equal(len(0xC1, 0xBF), 0);
  assert.equal(len(0xE2, 0x82, 0xAC), 3);
  assert.equal(len(0xE0, 0x80, 0x80), 0, 'overlong 3 bayt');
  assert.equal(len(0xED, 0xA0, 0x80), 0, 'UTF-16 vekil');
  assert.equal(len(0xF0, 0x9F, 0x98, 0x80), 4);
  assert.equal(len(0xF0, 0x80, 0x80, 0x80), 0, 'overlong 4 bayt');
  assert.equal(len(0xF4, 0x90, 0x80, 0x80), 0, '> U+10FFFF');
  assert.equal(len(0xF5, 0x80, 0x80, 0x80), 0);
  assert.equal(len(0x80), 0, 'devam bayti basta');
  assert.equal(len(0xC3), 0, 'kesik dizi');
});

test('fw_netutil: isCleanUtf8 kontrol karakterini reddeder (allowControl=false)', () => {
  assert.equal(isCleanUtf8('Salon üğş'), true);
  assert.equal(isCleanUtf8('a\nb'), false);
  assert.equal(isCleanUtf8('a\nb', true), true);
  assert.equal(isCleanUtf8('a\x7Fb'), false);
  assert.equal(isCleanUtf8(Buffer.from([0x61, 0xFF, 0x62])), false);
  assert.equal(isCleanUtf8(''), true);
});

test('fw_netutil: sanitizeUtf8 gecersiz baytlari U+FFFD, kontrol karakterlerini bosluk yapar', () => {
  assert.equal(sanitizeUtf8('abc'), 'abc');
  assert.equal(sanitizeUtf8('a\tb\nc'), 'a b c');
  assert.equal(sanitizeUtf8(Buffer.from([0x61, 0xFF, 0x62])), 'a�b');
  assert.equal(sanitizeUtf8('ü'), 'ü');
  assert.equal(sanitizeUtf8('x'.repeat(300)).length, 256, 'en fazla 256 bayt');
});

test('fw_netutil: sanitizeInto karakteri ortadan kesmez, sigmayan karakter kesme noktasidir', () => {
  assert.equal(sanitizeInto(8, 'abc'), 'abc');
  assert.equal(sanitizeInto(4, 'abcdef'), 'abc');                     // cap-1 = 3 bayt
  assert.equal(sanitizeInto(4, 'abü'), 'ab');                    // 2 + 2 bayt + NUL = 5 > 4 -> sigmaz
  assert.equal(sanitizeInto(5, 'abü'), 'abü');
  assert.equal(sanitizeInto(8, Buffer.from([0x61, 0xFF, 0x62])), 'a?b');
  assert.equal(sanitizeInto(8, 'a\tb'), 'a b');
  assert.equal(sanitizeInto(8, null), '');
});

test('fw_netutil: copyUtf8Truncated UTF-8 karakterini ortadan kesmez', () => {
  assert.equal(copyUtf8Truncated(32, 'Salon'), 'Salon');
  assert.equal(copyUtf8Truncated(6, 'abcüü'), 'abcü');   // 3+2=5 bayt, 6. bayt karakter ortasi
  assert.equal(copyUtf8Truncated(5, 'abcü'), 'abc');               // cap-1=4: 'abc' + C3 (yarim) -> geri cekil
  assert.equal(copyUtf8Truncated(1, 'abc'), '');
  assert.equal(copyUtf8Truncated(8, null), '');
});

test('fw_netutil: parseIntStrict yalnizca [-]?[0-9]{1,9}', () => {
  assert.equal(parseIntStrict('0'), 0);
  assert.equal(parseIntStrict('42'), 42);
  assert.equal(parseIntStrict('-7'), -7);
  assert.equal(parseIntStrict('123456789'), 123456789);
  assert.equal(parseIntStrict('1234567890'), null, '10 hane');
  assert.equal(parseIntStrict(''), null);
  assert.equal(parseIntStrict('-'), null);
  assert.equal(parseIntStrict('+5'), null);
  assert.equal(parseIntStrict('5a'), null);
  assert.equal(parseIntStrict(' 5'), null);
  assert.equal(parseIntStrict('1.5'), null);
  assert.equal(parseIntStrict(null), null);
});

test('fw_netutil: epochFromUtc bilinen degerler', () => {
  assert.equal(epochFromUtc(1970, 1, 1, 0, 0, 0), 0);
  assert.equal(epochFromUtc(2000, 3, 1, 0, 0, 0), 951868800);
  assert.equal(epochFromUtc(2023, 11, 14, 22, 13, 20), 1700000000);
  assert.equal(epochFromUtc(2024, 2, 29, 12, 0, 0), Date.UTC(2024, 1, 29, 12, 0, 0) / 1000);
  assert.equal(epochFromUtc(1969, 12, 31, 23, 59, 59), -1);
  for (const [y, m, d] of [[1999, 12, 31], [2026, 10, 1], [2100, 3, 1], [1900, 3, 1], [2038, 1, 19]]) {
    assert.equal(epochFromUtc(y, m, d, 1, 2, 3), Date.UTC(y, m - 1, d, 1, 2, 3) / 1000, `${y}-${m}-${d}`);
  }
});

test('fw_netutil: isPrintableAsciiNoSpace', () => {
  assert.equal(isPrintableAsciiNoSpace('abcXYZ019!~'), true);
  assert.equal(isPrintableAsciiNoSpace('a b'), false);
  assert.equal(isPrintableAsciiNoSpace('a\x7Fb'), false);
  assert.equal(isPrintableAsciiNoSpace('aüb'), false);
  assert.equal(isPrintableAsciiNoSpace(''), true);
});
