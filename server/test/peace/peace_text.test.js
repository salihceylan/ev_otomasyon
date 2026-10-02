'use strict';

// Gece huzur hatırlatması metin üreticisi (WP-H §3.1) testleri: saf fonksiyonlar, ağ/DB/saat YOK.

const test = require('node:test');
const assert = require('node:assert/strict');

const peaceText = require('../../src/services/peace_text');

const { locative, buildSummary, buildTitle, DEFAULT_ROOM } = peaceText;

const room = (name, n = 1) => Array.from({ length: n }, () => ({ room: name }));

test('dışa açılan arayüz sabit: DEFAULT_ROOM + 3 fonksiyon', () => {
  assert.equal(DEFAULT_ROOM, 'Genel');
  assert.deepEqual(Object.keys(peaceText).sort(), ['DEFAULT_ROOM', 'buildSummary', 'buildTitle', 'locative']);
});

// ------------------------------------------------------------------------------
// locative
// ------------------------------------------------------------------------------

test('locative: kalın ünlü -> -da, ince ünlü -> -de', () => {
  const cases = [
    ['Salon', 'Salonda'],
    ['Banyo', 'Banyoda'],
    ['Balkon', 'Balkonda'],
    ['Koridor', 'Koridorda'],
    ['Garaj', 'Garajda'],
    ['Antre', 'Antrede'],
    ['Bahçe', 'Bahçede'],
    ['Kiler', 'Kilerde'],
    ['Yemek Odası Koridor', 'Yemek Odası Koridorda'],
  ];
  for (const [input, expected] of cases) assert.equal(locative(input), expected, input);
});

test('locative: sert ünsüzle bitince -ta/-te (ç f h k p s ş t)', () => {
  const cases = [
    ['Mutfak', 'Mutfakta'],
    ['Ofis', 'Ofiste'], // s + ince ünlü
    ['Çalışma Odası Dolap', 'Çalışma Odası Dolapta'], // p
    ['Kat', 'Katta'], // t
    ['Depo Raf', 'Depo Rafta'], // f
    ['Vestiyer Çiçek', 'Vestiyer Çiçekte'], // k + ince
    ['Muhtarlık', 'Muhtarlıkta'], // ı...k
    ['Kuş', 'Kuşta'], // ş
    ['Ağaç', 'Ağaçta'], // ç
    ['Çeh', 'Çehte'], // h + ince ünlü
  ];
  for (const [input, expected] of cases) assert.equal(locative(input), expected, input);
});

test('locative: ünlü uyumu SON KELİMENİN son ünlüsüne göre (ilk kelime önemsiz)', () => {
  assert.equal(locative('Küçük Salon'), 'Küçük Salonda'); // ilk kelime ince, son kalın
  assert.equal(locative('Salon Giriş'), 'Salon Girişte'); // ilk kalın, son ince + ş
  assert.equal(locative('Büyük Mutfak'), 'Büyük Mutfakta');
});

test('locative: iyelik (-sı -si -su -sü) -> -nda/-nde', () => {
  const cases = [
    ['Yatak Odası', 'Yatak Odasında'],
    ['Çocuk Odası', 'Çocuk Odasında'],
    ['Çamaşır Odası', 'Çamaşır Odasında'],
    ['Pasi', 'Pasinde'], // belirsiz yazımda iyelik varsayılır
    ['Banyosu', 'Banyosunda'],
    ['Evsü', 'Evsünde'],
  ];
  for (const [input, expected] of cases) assert.equal(locative(input), expected, input);
});

test('locative: gövdesiz "Su" iyelik değildir', () => {
  assert.equal(locative('Su'), 'Suda');
});

test('locative: İ/I tuzağı (Türkçe büyük/küçük harf) - büyük harfli yazımda doğru ek seçilir', () => {
  assert.equal(locative('KAPI'), 'KAPIda'); // I -> ı (kalın); düz toLowerCase "kapi" -> "-de" verirdi
  assert.equal(locative('KİLER'), 'KİLERde'); // İ -> i, son ünlü e
  assert.equal(locative('YATAK ODASI'), 'YATAK ODASInda'); // iyelik büyük harfle de tanınır
  assert.equal(locative('Işık'), 'Işıkta'); // ı kalın + k sert
  assert.equal(locative('İş'), 'İşte');
});

test('locative: boş / Genel / null / undefined / string olmayan -> Evde', () => {
  for (const input of ['', '   ', 'Genel', 'genel', ' GENEL ', null, undefined, 42, {}, [], true, NaN]) {
    assert.equal(locative(input), 'Evde', String(input));
  }
  assert.equal(locative(), 'Evde');
});

test('locative: boşluk normalizasyonu (kırp, çoklu boşluk/sekme/satır sonu tek boşluk)', () => {
  assert.equal(locative('  Yatak   Odası  '), 'Yatak Odasında');
  assert.equal(locative('Yatak\t\nOdası'), 'Yatak Odasında');
  assert.equal(locative('Salon Giriş'), 'Salon Girişte'); // NBSP
});

test('locative: adın harf büyüklüğü olduğu gibi korunur (ilk harf büyütülmez)', () => {
  assert.equal(locative('salon'), 'salonda');
  assert.equal(locative('mutfak'), 'mutfakta');
});

test('locative: rakamla biten ad kesmeyle, sayının okunuşuna uyar', () => {
  assert.equal(locative('Oda 1'), "Oda 1'de"); // bir
  assert.equal(locative('Oda 3'), "Oda 3'te"); // üç
  assert.equal(locative('Oda 6'), "Oda 6'da"); // altı
  assert.equal(locative('Oda 10'), "Oda 10'da"); // on
  assert.equal(locative('Oda 20'), "Oda 20'de"); // yirmi
});

test('locative: kısa kısaltma harf adıyla okunur', () => {
  assert.equal(locative('WC'), "WC'de");
  assert.equal(locative('Blok A'), "Blok A'da");
});

test('locative: "Hol" yumuşak l ile ince ek alır', () => {
  assert.equal(locative('Hol'), 'Holde');
});

test('locative: aşırı uzun ad 50 karaktere kırpılır; kötü girdi istisna fırlatmaz', () => {
  const long = 'A'.repeat(200);
  const out = locative(long);
  assert.equal(out, `${'A'.repeat(50)}da`);
  assert.doesNotThrow(() => locative({ toString() { throw new Error('x'); } }));
  assert.doesNotThrow(() => locative(Symbol('s')));
});

// ------------------------------------------------------------------------------
// buildSummary
// ------------------------------------------------------------------------------

test('buildSummary: 1 oda', () => {
  assert.equal(buildSummary({ lights: room('Salon', 2), shutters: [] }), 'Salonda 2 lamba açık.');
  assert.equal(buildSummary({ lights: room('Mutfak', 1) }), 'Mutfakta 1 lamba açık.');
});

test('buildSummary: 2-3 oda, lamba sayısına göre azalan', () => {
  const lights = [...room('Mutfak', 1), ...room('Salon', 2)];
  assert.equal(buildSummary({ lights, shutters: [] }), 'Salonda 2, Mutfakta 1 lamba açık.');
  const three = [...room('Antre', 1), ...room('Salon', 3), ...room('Mutfak', 2)];
  assert.equal(buildSummary({ lights: three }), 'Salonda 3, Mutfakta 2, Antrede 1 lamba açık.');
});

test('buildSummary: sayı eşitse ada göre Türkçe sıralama (ç c den sonra, ı i den önce)', () => {
  assert.equal(
    buildSummary({ lights: [...room('Salon'), ...room('Çocuk Odası'), ...room('Banyo')] }),
    "Banyoda 1, Çocuk Odasında 1, Salonda 1 lamba açık.",
  );
  assert.equal(
    buildSummary({ lights: [...room('Işık Odası'), ...room('İş Odası')] }),
    'Işık Odasında 1, İş Odasında 1 lamba açık.',
  );
});

test('buildSummary: 4+ oda "N odada M lamba"ya özetlenir', () => {
  const lights = [...room('Salon', 3), ...room('Mutfak', 2), ...room('Banyo', 1), ...room('Antre', 1)];
  assert.equal(buildSummary({ lights, shutters: [] }), '4 odada 7 lamba açık.');
});

test('buildSummary: aynı odanın yazım türleri tek oda sayılır', () => {
  const lights = [{ room: 'Salon' }, { room: ' salon ' }, { room: 'SALON' }];
  assert.equal(buildSummary({ lights }), 'Salonda 3 lamba açık.');
});

test('buildSummary: lamba + panjur', () => {
  assert.equal(
    buildSummary({ lights: room('Salon', 2), shutters: room('Salon', 1) }),
    'Salonda 2 lamba, 1 panjur açık.',
  );
  assert.equal(
    buildSummary({ lights: [...room('Salon', 2), ...room('Mutfak', 1)], shutters: [{ room: 'Salon' }] }),
    'Salonda 2, Mutfakta 1 lamba, 1 panjur açık.',
  );
  const many = [...room('Salon'), ...room('Mutfak'), ...room('Banyo'), ...room('Antre')];
  assert.equal(buildSummary({ lights: many, shutters: room('Salon', 2) }), '4 odada 4 lamba, 2 panjur açık.');
});

test('buildSummary: yalnız panjur (oda adı söylenmez)', () => {
  assert.equal(buildSummary({ lights: [], shutters: room('Salon', 1) }), '1 panjur açık.');
  assert.equal(buildSummary({ shutters: room('Salon', 2) }), '2 panjur açık.');
});

test('buildSummary: oda adı yok/Genel -> "Evde"', () => {
  assert.equal(buildSummary({ lights: [{ room: null }, { room: '' }, { room: 'Genel' }] }), 'Evde 3 lamba açık.');
  // sayı eşit: "genel" < "salon" olduğundan Evde önce gelir
  assert.equal(buildSummary({ lights: [{}, { room: 'Salon' }] }), 'Evde 1, Salonda 1 lamba açık.');
});

test('buildSummary: hiçbir şey açık değilse boş metin', () => {
  assert.equal(buildSummary({ lights: [], shutters: [] }), '');
  assert.equal(buildSummary({}), '');
});

test('buildSummary: kötü girdi istisna fırlatmaz; geçersiz girdiler yok sayılır', () => {
  for (const input of [undefined, null, 5, 'x', [], () => 1]) {
    assert.equal(buildSummary(input), '', String(input));
  }
  assert.equal(buildSummary({ lights: 'salon', shutters: 7 }), '');
  assert.equal(buildSummary({ lights: [null, undefined, 3, 'x', { room: 'Salon' }] }), 'Salonda 1 lamba açık.');
  assert.equal(buildSummary({ lights: [{ room: 42 }, { room: {} }] }), 'Evde 2 lamba açık.');
});

test('buildSummary: negatif/sıfır/NaN sayaç yok sayılır, pozitif tam sayı toplanır', () => {
  const lights = [
    { room: 'Salon', count: -3 },
    { room: 'Salon', count: 0 },
    { room: 'Salon', count: NaN },
    { room: 'Salon', count: Infinity },
    { room: 'Mutfak', count: 2 },
    { room: 'Mutfak', count: '3' },
  ];
  assert.equal(buildSummary({ lights, shutters: [{ count: -1 }, { count: 2 }] }), 'Mutfakta 5 lamba, 2 panjur açık.');
});

test('buildSummary: girdi nesnesini değiştirmez', () => {
  const input = { lights: [{ room: ' Mutfak ' }, { room: 'Salon' }, { room: 'Salon' }], shutters: [{ room: 'Salon' }] };
  const copy = JSON.parse(JSON.stringify(input));
  buildSummary(input);
  assert.deepEqual(input, copy);
});

test('buildSummary: Türkçe karakterler ASCII\'ye çevrilmez', () => {
  const out = buildSummary({ lights: room('Çocuk Odası', 2), shutters: room('Çocuk Odası') });
  assert.equal(out, 'Çocuk Odasında 2 lamba, 1 panjur açık.');
});

// ------------------------------------------------------------------------------
// buildTitle
// ------------------------------------------------------------------------------

test('buildTitle: ev adı korunur, boşsa "Evim"', () => {
  assert.equal(buildTitle('Gül Apartmanı 5'), 'Gül Apartmanı 5');
  assert.equal(buildTitle('  Şişli   Evi '), 'Şişli Evi');
  for (const input of ['', '   ', null, undefined, 7, {}, []]) assert.equal(buildTitle(input), 'Evim', String(input));
});

test('buildTitle: en çok 60 karakter (kırpılır, kod noktası güvenli)', () => {
  const long = 'Ç'.repeat(100);
  assert.equal(Array.from(buildTitle(long)).length, 60);
  assert.equal(buildTitle('a'.repeat(60)), 'a'.repeat(60));
  const emoji = '🏠'.repeat(70);
  const cut = buildTitle(emoji);
  assert.equal(Array.from(cut).length, 60);
  assert.ok(Array.from(cut).every((c) => c === '🏠'), 'vekil çifti ortadan bölünmemeli');
});

test('buildTitle: gizli biçim karakterleri ve denetim karakterleri temizlenir', () => {
  assert.equal(buildTitle('Ev​‮ Adı\u0000'), 'Ev Adı');
});
