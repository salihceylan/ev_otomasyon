'use strict';

// B12 (mesaj dili): KULLANICIYA DONEN metinler dogru Turkce karakterlerle (UTF-8) yazilir.
// ASCII'ye katlanmis Turkce ("degil", "icin", "olmali", "cevrimdisi", "baglanti" ...) kaldiysa bu test kirilir.
// Log mesajlari (console.*, logger.*) ve gelistiriciye donuk dahili hatalar (new Error / TypeError) ASCII kalabilir.

const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const path = require('path');
const { stringLiterals } = require('./_source_strings');

const SRC = path.join(__dirname, '..', '..', 'src');

// Kullaniciya mesaj ureten WP-B dosyalari
const FILES = [
  'services/device_service.js',
  'services/endpoint_service.js',
  'services/mqtt_credential_service.js',
  'utils/command_schema.js',
  'utils/http_errors.js',
  'routes/route_helpers.js',
  'routes/device_routes.js',
  'routes/home_device_routes.js',
  'routes/endpoint_routes.js',
  'routes/mqtt_routes.js',
];

// Dogru yazilisi ozel harf (c g i o s u) gerektiren sozcuklerin ASCII'ye katlanmis halleri
const FOLDED_WORDS = [
  'degil', 'icin', 'icinde', 'olmali', 'olmalidir', 'gecersiz', 'gecerli', 'gecin', 'gecmis', 'cevrimdisi', 'cevrimici',
  'bulunamadi', 'baglanti', 'baglantisi', 'baglantilari', 'baglanamadi', 'bagli', 'gonder\\w*', 'dogrula\\w*', 'sifirla\\w*',
  'sifre\\w*', 'hatali', 'lutfen', 'musteri\\w*', 'kullanici\\w*', 'kullanin', 'islem\\w*', 'olustur\\w*', 'guncell\\w*',
  'erisim\\w*', 'yalnizca', 'tarafindan', 'yonetici\\w*', 'kimligi', 'alani', 'alanlari', 'arasinda', 'tanimli', 'tanimlan\\w*',
  'kayitli', 'yapildi', 'yapilamaz', 'yapilabilir', 'yapilandirma', 'edilmis', 'alindi', 'alinmis',
  'atilamadi', 'atildi', 'gosterilir', 'baska', 'ayni', 'tum', 'acik', 'kapali\\w*', 'kapatildi', 'kapatilamadi', 'basarisiz',
  'basarili', 'ariza', 'gerekce', 'askiya', 'yazin', 'kaldirildi', 'simdi', 'sure',
  'suresi', 'sureniz', 'once', 'ornek', 'bicim\\w*', 'iceren', 'icermeli', 'iceremez', 'govdesi', 'kontrolu', 'stoga',
  'uzerinden', 'surulemez', 'calisma', 'calisir', 'role', 'teshis', 'degis\\w*', 'degistir\\w*', 'uctan', 'eslem\\w*',
  'gorunur', 'gorunuyor', 'duser', 'bos', 'hakki', 'iletisime', 'ulasil\\w*',
];
const FOLDED = new RegExp(`(?:^|[^A-Za-z0-9_])(?:${FOLDED_WORDS.join('|')})(?![A-Za-z0-9_])`, 'i');

const TURKISH_CHARS = /[çğıöşüÇĞİÖŞÜ]/;
// Kullaniciya DONMEYEN baglamlar: log cagrilari, dahili Error/TypeError, tanilama dizisi, require
const INTERNAL_CONTEXT = /(?:console\.\w+|\blogger\.\w+|\bnew\s+(?:Type|Range)?Error|\.errors\.push|\brequire)\s*\(\s*$/;
const SQL_LIKE = /\b(SELECT|INSERT INTO|UPDATE|DELETE FROM|CREATE TABLE|ALTER TABLE)\b/;

function userFacingSentences(rel) {
  const src = fs.readFileSync(path.join(SRC, rel), 'utf8');
  return stringLiterals(src).filter((lit) => {
    if (!/\s/.test(lit.raw) || !/[A-Za-z]/.test(lit.raw)) return false; // tek sozcuk/kimlik/yol: cumle degil
    if (SQL_LIKE.test(lit.raw) && /\b(FROM|SET|VALUES|WHERE|RETURNING)\b/.test(lit.raw)) return false;
    if (INTERNAL_CONTEXT.test(lit.ctx)) return false;
    if (lit.raw.startsWith('[')) return false; // [ETIKET] log satiri
    return true;
  });
}

test('tarayici: ASCII-katlanmis metni yakalar, dogru Turkceyi ve log/dahili metinleri atlar', () => {
  const src = [
    "throw httpError(400, 'Gecersiz deger icin tekrar deneyin.', 'VALIDATION');",
    "throw httpError(400, 'Geçersiz değer için tekrar deneyin.', 'VALIDATION');",
    "console.error('Komut yayinlanamadi: baglanti yok');",
    "throw new TypeError('homeId zorunludur, gecerli olmali');",
    "const sql = 'SELECT 1 FROM x WHERE ok icin';",
  ].join('\n');
  const found = stringLiterals(src).filter((lit) => /\s/.test(lit.raw) && !INTERNAL_CONTEXT.test(lit.ctx) && !SQL_LIKE.test(lit.raw));
  const flagged = found.filter((lit) => FOLDED.test(lit.raw)).map((lit) => lit.raw);
  assert.deepStrictEqual(flagged, ['Gecersiz deger icin tekrar deneyin.']);
});

for (const rel of FILES) {
  test(`${rel}: kullaniciya donen metinlerde ASCII-katlanmis Turkce yok`, () => {
    const offenders = userFacingSentences(rel)
      .filter((lit) => FOLDED.test(lit.raw))
      .map((lit) => `${rel}:${lit.line}  ${lit.raw}`);
    assert.deepStrictEqual(offenders, [], `ASCII-katlanmis kullanici metni:\n  ${offenders.join('\n  ')}`);
  });
}

test('tarama gercekten kapsamli: cok sayida cumle bulunur ve cogu Turkce ozel harf icerir (bozuk ayirici sessizce gecmesin)', () => {
  let sentences = 0;
  let withTurkishChars = 0;
  for (const rel of FILES) {
    const list = userFacingSentences(rel);
    sentences += list.length;
    withTurkishChars += list.filter((lit) => TURKISH_CHARS.test(lit.raw)).length;
  }
  assert.ok(sentences >= 150, `beklenenden az cumle bulundu: ${sentences}`);
  assert.ok(withTurkishChars >= 120, `Turkce ozel harfli cumle az: ${withTurkishChars}`);
});

test('kaynak dosyalari gecerli UTF-8 (yerine koyma karakteri U+FFFD yok) ve BOM icermez', () => {
  for (const rel of FILES) {
    const buf = fs.readFileSync(path.join(SRC, rel));
    assert.ok(!(buf[0] === 0xef && buf[1] === 0xbb && buf[2] === 0xbf), `${rel}: BOM var`);
    assert.ok(!buf.toString('utf8').includes('�'), `${rel}: bozuk UTF-8 (U+FFFD)`);
  }
});
