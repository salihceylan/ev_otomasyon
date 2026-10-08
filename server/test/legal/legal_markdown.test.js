'use strict';

// Yasal metinler: utils/legal_markdown (SAF; PG / dosya gerekmez).
//   - on bilgi (front matter): tipler, tirnakli deger, BOM + CRLF hosgorusu, hatalar LegalDocumentError
//   - govde alt kumesi: "# " "## " "### " baslik, bos satirla ayrilan paragraf (satirlar tek boslukla birlesir),
//     "- " madde, "N. " numarali madde (n korunur), satir ici **kalin** metinde aynen kalir
//   - HTML: kacirma, kalin -> <strong>, TASLAK bandi, "Surum N · Yururluk: GG.AA.YYYY", 404 sayfasi, CSP stil ozeti
//   - desteklenmeyen sozdizimi denetimi (belge yazarina uyari; gercek belgelerin uygunluk testi bunu kullanir)

const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const md = require('../../src/utils/legal_markdown');

const META = {
  id: 'terms',
  slug: 'kullanici-sozlesmesi',
  title: 'Kullanıcı Sözleşmesi',
  version: '1',
  effective_date: '2026-10-08',
  status: 'draft',
  requires_acceptance: 'true',
};

function frontMatter(over = {}) {
  const meta = { ...META, ...over };
  const lines = Object.entries(meta).filter(([, v]) => v !== undefined).map(([k, v]) => `${k}: ${v}`);
  return ['---', ...lines, '---'].join('\n');
}

const doc = (body = 'Metin.', over = {}) => `${frontMatter(over)}\n${body}\n`;

// ------------------------------------------------------------------------------------------------ on bilgi
test('on bilgi: tipler (surum sayi, onay boolean), tirnakli deger, BOM + CRLF, yorum satiri', () => {
  const text =
    '\uFEFF---\r\nid: terms\r\nslug: kullanici-sozlesmesi\r\n# yorum satiri\r\ntitle: "Kullanıcı Sözleşmesi"\r\n' +
    "version: 3\r\neffective_date: '2026-10-08'\r\nstatus: final\r\nrequires_acceptance: true\r\n---\r\nMetin.\r\n";
  const d = md.parseLegalDocument(text);
  assert.deepEqual(d.meta, {
    id: 'terms',
    slug: 'kullanici-sozlesmesi',
    title: 'Kullanıcı Sözleşmesi',
    version: 3,
    effective_date: '2026-10-08',
    status: 'final',
    requires_acceptance: true,
  });
  assert.deepEqual(d.blocks, [{ type: 'p', text: 'Metin.' }]);
  assert.equal(md.parseLegalDocument(doc('X', { requires_acceptance: 'false', id: 'privacy' })).meta.requires_acceptance, false);
});

test('on bilgi hatalari LegalDocumentError: eksik/kapanmamis blok, gecersiz deger, eksik/yinelenen anahtar, bos govde', () => {
  const bad = {
    'on bilgi yok': 'Metin.\n',
    'kapanmamis on bilgi': '---\nid: terms\nslug: kullanici-sozlesmesi\n',
    'surum 0': doc('X', { version: '0' }),
    'surum eksi': doc('X', { version: '-1' }),
    'surum kesirli': doc('X', { version: '1.5' }),
    'surum metin': doc('X', { version: 'bir' }),
    'surum basta sifir': doc('X', { version: '01' }),
    'surum cok buyuk': doc('X', { version: '12345678901' }),
    'tarih takvimde yok': doc('X', { effective_date: '2026-02-30' }),
    'tarih bicimi': doc('X', { effective_date: '08.10.2026' }),
    'durum': doc('X', { status: 'yayinda' }),
    'onay': doc('X', { requires_acceptance: 'evet' }),
    'id': doc('X', { id: 'kvkk' }),
    'slug': doc('X', { slug: 'Kullanici Sozlesmesi' }),
    'bos baslik': doc('X', { title: '""' }),
    'eksik anahtar': doc('X', { status: undefined }),
    'yinelenen anahtar': `${frontMatter()}`.replace('status: draft', 'status: draft\nstatus: final') + '\nX\n',
    'anahtar olmayan satir': frontMatter().replace('---\nid', '---\nbu satir anahtar degil\nid') + '\nX\n',
    'bos govde': `${frontMatter()}\n\n   \n`,
  };
  for (const [name, text] of Object.entries(bad)) {
    assert.throws(() => md.parseLegalDocument(text), md.LegalDocumentError, name);
  }
  // Hata iletisi belge govdesini TASIMAZ (loglanabilir)
  try {
    md.parseLegalDocument(doc('Gizli govde cumlesi', { version: 'x' }));
    assert.fail('hata beklenirdi');
  } catch (err) {
    assert.ok(err instanceof md.LegalDocumentError);
    assert.ok(!String(err.message).includes('Gizli govde cumlesi'));
  }
});

// ------------------------------------------------------------------------------------------------ govde
test('govde: basliklar, paragraf birlestirme, listeler, kalin aynen kalir, bosluklar sadelesir', () => {
  const body = [
    '# Ana Başlık',
    '',
    'Birinci   satır',
    'ikinci satır **kalın** devam.',
    '',
    '## İkinci',
    '### Üçüncü',
    '#### Dördüncü düzey desteklenmez',
    '',
    '- madde bir',
    '- madde iki',
    '  devamı',
    '',
    '1. bir',
    '2. iki',
    '7. yedi',
    '',
    '  - girintili madde',
    '#Bitisik',
  ].join('\n');
  assert.deepEqual(md.parseLegalBody(body), [
    { type: 'h1', text: 'Ana Başlık' },
    { type: 'p', text: 'Birinci satır ikinci satır **kalın** devam.' },
    { type: 'h2', text: 'İkinci' },
    { type: 'h3', text: 'Üçüncü' },
    { type: 'p', text: '#### Dördüncü düzey desteklenmez' },
    { type: 'li', text: 'madde bir' },
    { type: 'li', text: 'madde iki devamı' },
    { type: 'oli', text: 'bir', n: 1 },
    { type: 'oli', text: 'iki', n: 2 },
    { type: 'oli', text: 'yedi', n: 7 },
    { type: 'li', text: 'girintili madde #Bitisik' },
  ]);
});

test('govde: numarali satir paragrafi yalniz "1." ile keser (Kanunun 11. maddesi devam satiridir); kardes maddeler her numarayla', () => {
  assert.deepEqual(md.parseLegalBody("6698 sayılı Kanun'un\n11. maddesi uyarınca haklarınız:\n1. bilgi talep etme\n2. düzeltme"), [
    { type: 'p', text: "6698 sayılı Kanun'un 11. maddesi uyarınca haklarınız:" },
    { type: 'oli', text: 'bilgi talep etme', n: 1 },
    { type: 'oli', text: 'düzeltme', n: 2 },
  ]);
  assert.deepEqual(md.parseLegalBody('- Kanunun\n11. maddesi kapsamında'), [{ type: 'li', text: 'Kanunun 11. maddesi kapsamında' }]);
  assert.deepEqual(md.parseLegalBody('- madde\n1. yeni liste'), [{ type: 'li', text: 'madde' }, { type: 'oli', text: 'yeni liste', n: 1 }]);
  assert.deepEqual(md.parseLegalBody('Giriş\n- madde'), [{ type: 'p', text: 'Giriş' }, { type: 'li', text: 'madde' }]);
  assert.deepEqual(md.parseLegalBody('3. üç\n\n5. beş'), [{ type: 'oli', text: 'üç', n: 3 }, { type: 'oli', text: 'beş', n: 5 }]);
  assert.deepEqual(md.parseLegalBody('Metin\n## Başlık\nyeni paragraf'), [
    { type: 'p', text: 'Metin' },
    { type: 'h2', text: 'Başlık' },
    { type: 'p', text: 'yeni paragraf' },
  ]);
  assert.deepEqual(md.parseLegalBody('#\n\n- \n'), [{ type: 'p', text: '#' }, { type: 'p', text: '-' }], 'bos isaretler duz metin');
});

// ------------------------------------------------------------------------------------------------ HTML
test('satir ici HTML: kacirma, kalin -> strong, kapanmamis ** duz metin, bos kalin atlanir', () => {
  assert.equal(md.escapeHtml(`<x> & "y" 'z'`), '&lt;x&gt; &amp; &quot;y&quot; &#39;z&#39;');
  assert.equal(md.renderInlineHtml('a **b** c'), 'a <strong>b</strong> c');
  assert.equal(md.renderInlineHtml('**<b>&**'), '<strong>&lt;b&gt;&amp;</strong>');
  assert.equal(md.renderInlineHtml('a **b'), 'a **b');
  assert.equal(md.renderInlineHtml('a **b** c **d'), 'a <strong>b</strong> c **d');
  assert.equal(md.renderInlineHtml('x****y'), 'xy');
});

test('tarih: YYYY-AA-GG -> GG.AA.YYYY', () => {
  assert.equal(md.formatTrDate('2026-10-08'), '08.10.2026');
  assert.equal(md.formatTrDate('2027-01-31'), '31.01.2027');
});

test('belge sayfasi: lang tr, viewport, baslik kacirilir, surum/yururluk satiri, TASLAK yalniz taslakta, listeler gruplanir', () => {
  const parsed = md.parseLegalDocument(
    doc('Giriş **önemli** <script>alert(1)</script>\n\n- a\n- b\n\n2. iki\n3. üç', { title: 'Sözleşme & <Koşullar>' })
  );
  const html = md.renderDocumentPage(parsed);
  assert.match(html, /^<!doctype html>/i);
  assert.match(html, /<html lang="tr">/);
  assert.match(html, /<meta charset="utf-8">/);
  assert.match(html, /<meta name="viewport" content="width=device-width, initial-scale=1">/);
  assert.match(html, /<title>Sözleşme &amp; &lt;Koşullar&gt;<\/title>/);
  assert.match(html, /<h1>Sözleşme &amp; &lt;Koşullar&gt;<\/h1>/);
  assert.ok(html.includes('Sürüm 1 · Yürürlük: 08.10.2026'));
  assert.ok(html.includes('TASLAK'));
  assert.doesNotMatch(html, /<script/i);
  assert.ok(html.includes('&lt;script&gt;alert(1)&lt;/script&gt;'));
  assert.ok(html.includes('<strong>önemli</strong>'));
  assert.match(html, /<ul><li>a<\/li><li>b<\/li><\/ul>/);
  assert.match(html, /<ol><li value="2">iki<\/li><li value="3">üç<\/li><\/ol>/);

  const final = md.renderDocumentPage(md.parseLegalDocument(doc('Metin.', { status: 'final', version: '4', effective_date: '2027-01-02' })));
  assert.ok(!final.includes('TASLAK'));
  assert.ok(final.includes('Sürüm 4 · Yürürlük: 02.01.2027'));
});

test('belge sayfasi: govde basliga esit # ile basliyorsa baslik tekrarlanmaz; farkliysa ikisi de kalir', () => {
  const same = md.renderDocumentPage(md.parseLegalDocument(doc('# Kullanıcı  **Sözleşmesi**\n\nMetin.')));
  assert.equal((same.match(/<h1>/g) || []).length, 1);
  const other = md.renderDocumentPage(md.parseLegalDocument(doc('# Başka Başlık\n\nMetin.')));
  assert.equal((other.match(/<h1>/g) || []).length, 2);
});

test('withoutTitleHeading: yalniz ILK blok basliga esit h1 ise duser (buyuk/kucuk harf, bosluk, ** farki onemsiz)', () => {
  const title = 'Kullanıcı Sözleşmesi';
  const p = { type: 'p', text: 'Metin.' };
  assert.deepEqual(md.withoutTitleHeading([{ type: 'h1', text: 'KULLANICI  **SÖZLEŞMESİ**' }, p], title), [p]);
  for (const blocks of [
    [{ type: 'h1', text: 'Başka' }, p],
    [{ type: 'h2', text: title }, p],
    [p, { type: 'h1', text: title }],
    [],
  ]) {
    assert.deepEqual(md.withoutTitleHeading(blocks, title), blocks);
  }
  const input = [{ type: 'h1', text: title }, p];
  md.withoutTitleHeading(input, title);
  assert.equal(input.length, 2, 'girdi dizisi degismez');
});

test('404 sayfasi ve CSP: ayni stil, stil yalniz SHA-256 ozetiyle, betik/unsafe-inline yok', () => {
  const nf = md.renderNotFoundPage();
  assert.match(nf, /<html lang="tr">/);
  assert.match(nf, /bulunamadı/);
  assert.doesNotMatch(nf, /<script/i);

  const page = md.renderDocumentPage(md.parseLegalDocument(doc()));
  for (const html of [page, nf]) {
    const m = /<style>([\s\S]*?)<\/style>/.exec(html);
    assert.ok(m, 'tek stil blogu');
    const hash = crypto.createHash('sha256').update(m[1], 'utf8').digest('base64');
    assert.ok(md.PAGE_CSP.includes(`style-src 'sha256-${hash}'`), 'CSP stil ozeti sayfadaki stille ayni');
    assert.doesNotMatch(html, /\sstyle="/, 'satir ici style ozniteligi yok (ozet onu kapsamaz)');
  }
  assert.match(md.PAGE_CSP, /default-src 'none'/);
  assert.match(md.PAGE_CSP, /frame-ancestors 'none'/);
  assert.doesNotMatch(md.PAGE_CSP, /unsafe-inline|script-src/);
});

// ------------------------------------------------------------------------------------------------ uygunluk denetimi
test('desteklenmeyen sozdizimi: kod, tablo, alinti, ####, * / + madde, ic ice liste, HTML, baglanti, gorsel, bitisik baslik, kapanmamis kalin', () => {
  const body = [
    '# Başlık', //  1
    '```', //  2
    '| a | b |', //  3
    '> alıntı', //  4
    '#### dört', //  5
    '* yıldız', //  6
    '+ artı', //  7
    '- ana', //  8
    '  - iç içe', //  9
    'metin <b>kalın</b>', // 10
    '[bağlantı](https://x.test)', // 11
    '![görsel](a.png)', // 12
    '##Bitişik', // 13
    '', // 14
    'açık **kalın kapanmadı', // 15
    'sürüyor', // 16
  ].join('\n');
  const found = md.findUnsupportedSyntax(body).map((x) => x.line);
  assert.deepEqual(found, [2, 3, 4, 5, 6, 7, 9, 10, 11, 12, 13, 15]);
  for (const x of md.findUnsupportedSyntax(body)) assert.equal(typeof x.reason, 'string');

  const clean = '# Başlık\n\nParagraf **kalın** ve\nsatır **iki satıra\nyayılan kalın** metin.\n\n- madde\n1. bir\n\nKanun 11. madde a < b';
  assert.deepEqual(md.findUnsupportedSyntax(clean), []);
});
