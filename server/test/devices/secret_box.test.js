'use strict';

// B0: utils/secret_box.js - AES-256-GCM kutusu (CONTRACTS §3, §6)

const test = require('node:test');
const assert = require('node:assert');
const crypto = require('crypto');

const secretBox = require('../../src/utils/secret_box');

// Test anahtari her kosumda rastgele uretilir (kodda sabit anahtar/sir YOK).
const ORIGINAL = process.env.LOCAL_KEY_SECRET;
function useKey(hex) {
  if (hex === undefined) delete process.env.LOCAL_KEY_SECRET;
  else process.env.LOCAL_KEY_SECRET = hex;
}
function randomKeyHex() {
  return crypto.randomBytes(32).toString('hex');
}

test.afterEach(() => useKey(ORIGINAL));

test('encrypt/decrypt gidis-donus: ayni metin geri gelir', () => {
  useKey(randomKeyHex());
  const stored = secretBox.encrypt('yerel-anahtar-Ab3dE5gH');
  assert.notStrictEqual(stored, 'yerel-anahtar-Ab3dE5gH');
  assert.strictEqual(secretBox.decrypt(stored), 'yerel-anahtar-Ab3dE5gH');
});

test('sifreli deger duz metni icermez ve v1 bicimindedir', () => {
  useKey(randomKeyHex());
  const plain = 'GizliAnahtar12345';
  const stored = secretBox.encrypt(plain);
  assert.ok(!stored.includes(plain));
  const parts = stored.split(':');
  assert.strictEqual(parts.length, 4);
  assert.strictEqual(parts[0], 'v1');
});

test('her sifrelemede IV rastgeledir (ayni metin farkli sifreli deger uretir)', () => {
  useKey(randomKeyHex());
  const a = secretBox.encrypt('ayni-metin-ayni-metin');
  const b = secretBox.encrypt('ayni-metin-ayni-metin');
  assert.notStrictEqual(a, b);
  assert.strictEqual(secretBox.decrypt(a), secretBox.decrypt(b));
});

test('unicode metin korunur', () => {
  useKey(randomKeyHex());
  const plain = 'Şifre-çöğüİ-123';
  assert.strictEqual(secretBox.decrypt(secretBox.encrypt(plain)), plain);
});

test('kurcalanmis (tampered) sifreli deger cozulemez', () => {
  useKey(randomKeyHex());
  const stored = secretBox.encrypt('degistirilmemeli');
  const parts = stored.split(':');
  // sifreli govdenin ilk baytini degistir
  const body = Buffer.from(parts[3], 'base64url');
  body[0] ^= 0x01;
  parts[3] = body.toString('base64url');
  assert.throws(() => secretBox.decrypt(parts.join(':')), /cozulemedi/);

  // etiket (tag) degisikligi
  const parts2 = stored.split(':');
  const tag = Buffer.from(parts2[2], 'base64url');
  tag[0] ^= 0xff;
  parts2[2] = tag.toString('base64url');
  assert.throws(() => secretBox.decrypt(parts2.join(':')), /cozulemedi/);
});

test('yanlis anahtarla cozme basarisiz olur', () => {
  useKey(randomKeyHex());
  const stored = secretBox.encrypt('baska-anahtar');
  useKey(randomKeyHex());
  assert.throws(() => secretBox.decrypt(stored), /cozulemedi/);
});

test('bozuk bicimli degerler genel hatayla reddedilir', () => {
  useKey(randomKeyHex());
  for (const bad of ['', 'abc', 'v1:a:b', 'v2:a:b:c', 'v1:::', null, undefined, 42, {}]) {
    assert.throws(() => secretBox.decrypt(bad), /cozulemedi/, `kabul edilmemeliydi: ${String(bad)}`);
  }
});

test('LOCAL_KEY_SECRET yoksa encrypt/decrypt ACIK hata firlatir (fail-closed)', () => {
  const key = randomKeyHex();
  useKey(key);
  const stored = secretBox.encrypt('bir-deger-1234');
  useKey(undefined);
  assert.throws(() => secretBox.encrypt('x'), /LOCAL_KEY_SECRET/);
  assert.throws(() => secretBox.decrypt(stored), /LOCAL_KEY_SECRET/);
  assert.strictEqual(secretBox.isConfigured(), false);
});

test('LOCAL_KEY_SECRET gecersizse (63 hex, hex olmayan, bos) hata verir', () => {
  for (const bad of ['', 'zz'.repeat(32), randomKeyHex().slice(0, 63), randomKeyHex() + 'aa']) {
    useKey(bad);
    assert.throws(() => secretBox.encrypt('x'), /LOCAL_KEY_SECRET/, `kabul edilmemeliydi: ${bad.length} karakter`);
    assert.strictEqual(secretBox.isConfigured(), false);
  }
});

test('hata mesajlari anahtari veya duz metni icermez', () => {
  const key = randomKeyHex();
  useKey(key);
  const stored = secretBox.encrypt('cok-gizli-deger');
  useKey(randomKeyHex());
  try {
    secretBox.decrypt(stored);
    assert.fail('hata bekleniyordu');
  } catch (err) {
    assert.ok(!err.message.includes(key));
    assert.ok(!err.message.includes('cok-gizli-deger'));
  }
});

test('encrypt: bos, metin olmayan ve cok uzun girdiyi reddeder', () => {
  useKey(randomKeyHex());
  assert.throws(() => secretBox.encrypt(''), TypeError);
  assert.throws(() => secretBox.encrypt(null), TypeError);
  assert.throws(() => secretBox.encrypt(123), TypeError);
  assert.throws(() => secretBox.encrypt('a'.repeat(5000)), TypeError);
});

test('generateLocalKey: 16 karakter, belirlenen alfabe, tekrarsiz', () => {
  const seen = new Set();
  for (let i = 0; i < 500; i++) {
    const k = secretBox.generateLocalKey();
    assert.strictEqual(k.length, 16);
    assert.ok(/^[A-HJ-NP-Za-km-z2-9]{16}$/.test(k), `beklenmeyen karakter: ${k}`);
    assert.ok(!/[0O1Il]/.test(k), 'karisan karakter olmamali');
    seen.add(k);
  }
  assert.strictEqual(seen.size, 500, 'anahtarlar benzersiz olmali');
});

test('generateLocalKey sifrelenip geri cozulebilir ve firmware uzunluk sinirina (8-32) uyar', () => {
  useKey(randomKeyHex());
  const k = secretBox.generateLocalKey();
  assert.ok(k.length >= 8 && k.length <= 32);
  assert.strictEqual(secretBox.decrypt(secretBox.encrypt(k)), k);
});

test('kaynak kodda Math.random kullanilmaz (CONTRACTS §0: rastgelelik)', () => {
  const src = require('fs').readFileSync(require.resolve('../../src/utils/secret_box'), 'utf8');
  assert.ok(!/Math\.random\s*\(/.test(src), 'Math.random() cagrisi olmamali');
  assert.ok(/crypto\.randomInt/.test(src) && /crypto\.randomBytes/.test(src));
});
