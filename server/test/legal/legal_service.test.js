'use strict';

// Yasal metinler: services/legal_service (PG gerekmez; belgeler test/legal/fixtures altindan).
//   - yukleyici: yalniz bilinen iki belge (<slug>.md), sira terms -> privacy, url "/yasal/<slug>"
//   - eksik / bos dizin: bos liste, asla firlatmaz (sunucu yine baslar)
//   - gecersiz belge atlanir (log yalniz dosya adi + neden; govde LOGA YAZILMAZ); sozlesme kurallari: id <-> slug
//     eslesmesi, KVKK aydinlatma metni (privacy) ONAY ISTEYEMEZ, kullanici sozlesmesi (terms) onay ister
//   - legalUserState: needs_acceptance yalniz belge yuklu + status final + personel degil + (kabul yok | eski)
//   - parseVersionInput: pozitif tamsayi (sayi ya da rakam dizgesi); aksi 400 VALIDATION
//   - GERCEK belgeler (server/legal/*.md, baska ajan yazar): varsa sozlesmeye ve govde alt kumesine uyar

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const legalModule = require('../../src/services/legal_service');
const { findUnsupportedSyntax, parseLegalDocument } = require('../../src/utils/legal_markdown');

const { createLegalService, legalUserState, parseVersionInput, KNOWN_DOCUMENTS, DEFAULT_LEGAL_DIR } = legalModule;
const FIX = path.join(__dirname, 'fixtures');

function quietLogger() {
  const logs = [];
  const push = (level) => (...a) => logs.push({ level, text: a.map(String).join(' ') });
  return { logs, logger: { log: push('log'), info: push('info'), warn: push('warn'), error: push('error') } };
}

const TERMS_TITLE = 'Kullanıcı Sözleşmesi ve Son Kullanıcı Lisans Koşulları';
const PRIVACY_TITLE = 'Gizlilik Politikası ve KVKK Aydınlatma Metni';

test('bilinen belgeler sozlesmeyle ayni: terms -> kullanici-sozlesmesi (onay ister), privacy -> gizlilik-politikasi (onay ISTEMEZ)', () => {
  assert.deepEqual(KNOWN_DOCUMENTS.map((d) => [d.id, d.slug, d.requiresAcceptance]), [
    ['terms', 'kullanici-sozlesmesi', true],
    ['privacy', 'gizlilik-politikasi', false],
  ]);
  assert.equal(DEFAULT_LEGAL_DIR, path.join(__dirname, '..', '..', 'legal'));
});

test('fixtures/draft: liste sirasi terms, privacy; meta tipleri ve url', () => {
  const q = quietLogger();
  const svc = createLegalService({ dir: path.join(FIX, 'draft'), logger: q.logger });
  assert.deepEqual(svc.listDocuments(), [
    { id: 'terms', slug: 'kullanici-sozlesmesi', title: TERMS_TITLE, version: 1, effective_date: '2026-10-08', status: 'draft', requires_acceptance: true, url: '/yasal/kullanici-sozlesmesi' },
    { id: 'privacy', slug: 'gizlilik-politikasi', title: PRIVACY_TITLE, version: 1, effective_date: '2026-10-08', status: 'draft', requires_acceptance: false, url: '/yasal/gizlilik-politikasi' },
  ]);
  assert.deepEqual(svc.getTermsState(), { version: 1, status: 'draft' });
  assert.deepEqual(q.logs.filter((l) => l.level === 'error'), []);
});

test('getDocument: id ya da slug ile; bloklar; bilinmeyen -> null; donen nesne paylasilan durumu bozamaz', () => {
  const svc = createLegalService({ dir: path.join(FIX, 'draft'), logger: quietLogger().logger });
  const byId = svc.getDocument('terms');
  const bySlug = svc.getDocument('kullanici-sozlesmesi');
  assert.deepEqual(byId, bySlug);
  assert.equal(byId.url, '/yasal/kullanici-sozlesmesi');
  // Govdenin basliga esit ilk "# " satiri bloklarda tekrarlanmaz (uygulama basligi ayrica gosterir; HTML sayfa da atlar)
  assert.deepEqual(byId.blocks.slice(0, 3), [
    { type: 'p', text: 'Bu metin yalnızca **test** amaçlıdır. İkinci satır aynı paragrafa katılır.' },
    { type: 'h2', text: '1. Taraflar' },
    { type: 'li', text: 'Hizmet sağlayıcı: Örnek Şirket' },
  ]);
  assert.ok(!byId.blocks.some((b) => b.type === 'h1'));
  assert.ok(byId.blocks.some((b) => b.type === 'oli' && b.n === 2 && b.text === 'İkinci madde'));
  for (const key of ['yok', 'TERMS', '', null, undefined, 'gizlilik', '../draft/kullanici-sozlesmesi']) {
    assert.equal(svc.getDocument(key), null, String(key));
  }
  byId.blocks.push({ type: 'p', text: 'kirletme' });
  byId.title = 'degisti';
  const again = svc.getDocument('terms');
  assert.equal(again.title, TERMS_TITLE);
  assert.ok(!again.blocks.some((b) => b.text === 'kirletme'));
});

test('getPage: yuklu slug 200 HTML, bilinmeyen / id / bozuk slug 404 HTML', () => {
  const svc = createLegalService({ dir: path.join(FIX, 'draft'), logger: quietLogger().logger });
  const ok = svc.getPage('kullanici-sozlesmesi');
  assert.equal(ok.status, 200);
  assert.match(ok.html, /<html lang="tr">/);
  assert.ok(ok.html.includes('TASLAK'));
  for (const slug of ['terms', 'yok', 'Kullanici-Sozlesmesi', '..', '']) {
    const nf = svc.getPage(slug);
    assert.equal(nf.status, 404, slug);
    assert.match(nf.html, /bulunamadı/);
  }
});

test('eksik dizin: bos liste, terms durumu null, firlatmaz (sunucu baslar); bir kez uyari', () => {
  const q = quietLogger();
  const svc = createLegalService({ dir: path.join(FIX, 'boyle-bir-dizin-yok'), logger: q.logger });
  assert.doesNotThrow(() => svc.load());
  assert.deepEqual(svc.listDocuments(), []);
  assert.equal(svc.getTermsState(), null);
  assert.equal(svc.getDocument('terms'), null);
  assert.equal(svc.getPage('kullanici-sozlesmesi').status, 404);
  svc.listDocuments();
  assert.equal(q.logs.filter((l) => l.level === 'warn').length, 1, 'yukleme tek sefer');
});

test('bos dizin: bos liste (dizindeki baska dosyalar okunmaz)', () => {
  const q = quietLogger();
  const svc = createLegalService({ dir: path.join(FIX, 'empty'), logger: q.logger });
  assert.deepEqual(svc.listDocuments(), []);
  assert.equal(svc.getTermsState(), null);
  assert.deepEqual(q.logs.filter((l) => l.level === 'error'), []);
});

test('gecersiz belgeler atlanir: bozuk on bilgi ve KVKK kurali (privacy onay isteyemez); log dosya adi + neden, govde YOK', () => {
  const q = quietLogger();
  const svc = createLegalService({ dir: path.join(FIX, 'invalid'), logger: q.logger });
  assert.deepEqual(svc.listDocuments(), []);
  const errors = q.logs.filter((l) => l.level === 'error').map((l) => l.text);
  assert.equal(errors.length, 2, errors.join('\n'));
  assert.ok(errors.some((t) => t.includes('kullanici-sozlesmesi.md')));
  assert.ok(errors.some((t) => t.includes('gizlilik-politikasi.md') && /KVKK|onay/i.test(t)));
  assert.ok(!errors.join('\n').includes('Gizli kalmasi gereken govde cumlesi'));
});

test('id / slug dosya adiyla uyusmazsa belge atlanir; dogru dosya yuklenir', () => {
  const q = quietLogger();
  const svc = createLegalService({ dir: path.join(FIX, 'mismatch'), logger: q.logger });
  assert.deepEqual(svc.listDocuments().map((d) => [d.id, d.version, d.status]), [['privacy', 4, 'final']]);
  assert.equal(svc.getTermsState(), null);
  assert.equal(q.logs.filter((l) => l.level === 'error').length, 1);
});

test('final belgeler: terms durumu surum + final', () => {
  const svc = createLegalService({ dir: path.join(FIX, 'final'), logger: quietLogger().logger });
  assert.deepEqual(svc.getTermsState(), { version: 2, status: 'final' });
  assert.equal(svc.getDocument('privacy').blocks[0].type, 'p');
  assert.ok(!svc.getPage('kullanici-sozlesmesi').html.includes('TASLAK'));
});

test('legalUserState: needs_acceptance yalniz yuklu + final + personel degil + (kabul yok | eski surum)', () => {
  const final2 = { version: 2, status: 'final' };
  const draft2 = { version: 2, status: 'draft' };
  const st = (user, terms) => legalUserState(user, terms);
  assert.deepEqual(st({ role: 'user', terms_version: null }, null), {
    terms_accepted_version: null, terms_current_version: null, terms_status: null, needs_acceptance: false,
  });
  assert.deepEqual(st({ role: 'user', terms_version: null }, draft2), {
    terms_accepted_version: null, terms_current_version: 2, terms_status: 'draft', needs_acceptance: false,
  });
  assert.deepEqual(st({ role: 'user', terms_version: null }, final2), {
    terms_accepted_version: null, terms_current_version: 2, terms_status: 'final', needs_acceptance: true,
  });
  assert.equal(st({ role: 'user', terms_version: 1 }, final2).needs_acceptance, true, 'eski surum');
  assert.equal(st({ role: 'user', terms_version: 2 }, final2).needs_acceptance, false, 'guncel');
  assert.equal(st({ role: 'user', terms_version: 3 }, final2).needs_acceptance, false, 'ileri surum (belge geri alindiysa)');
  assert.equal(st({ terms_version: undefined }, final2).needs_acceptance, true, 'rol yok = kullanici');
  assert.equal(st({ role: 'service_user', terms_version: null }, final2).needs_acceptance, false, 'personel');
  assert.equal(st({ role: 'super_user', terms_version: null }, final2).needs_acceptance, false, 'super kullanici');
  assert.equal(st({ role: 'user', terms_version: '2' }, final2).terms_accepted_version, 2, 'sayisal dizge');
  for (const bad of [0, -1, 1.5, 'x', true]) {
    assert.equal(st({ role: 'user', terms_version: bad }, final2).terms_accepted_version, null, String(bad));
  }
  assert.equal(st(null, final2).needs_acceptance, true);
});

test('accept: kullanici kimligi UUID degilse veritabanina gitmeden 404 NOT_FOUND (servis oturumu id null)', async () => {
  const calls = [];
  const db = { withTransaction: async () => calls.push('tx'), query: async () => calls.push('q') };
  const svc = createLegalService({ dir: path.join(FIX, 'draft'), db, logger: quietLogger().logger });
  for (const userId of [null, undefined, '', 'abc', 42]) {
    await assert.rejects(svc.accept({ userId, document: 'terms', version: 1 }), (e) => e.status === 404 && e.code === 'NOT_FOUND', String(userId));
  }
  assert.deepEqual(calls, []);
});

test('parseVersionInput: pozitif tamsayi ya da rakam dizgesi; bos -> null (istege bagli); aksi 400 VALIDATION', () => {
  assert.equal(parseVersionInput(1), 1);
  assert.equal(parseVersionInput('2'), 2);
  assert.equal(parseVersionInput(' 3 '), 3);
  for (const empty of [undefined, null, '']) {
    assert.equal(parseVersionInput(empty, { optional: true }), null);
    assert.throws(() => parseVersionInput(empty), (e) => e.status === 400 && e.code === 'VALIDATION');
  }
  for (const bad of [0, -1, 1.5, 'abc', '1.0', '0x1', '1e3', true, {}, [], [1], NaN, Infinity, 2 ** 31, '99999999999']) {
    assert.throws(() => parseVersionInput(bad, { optional: true }), (e) => e.status === 400 && e.code === 'VALIDATION', String(bad));
  }
});

// ------------------------------------------------------------------------------------------------ gercek belgeler
// server/legal/*.md baska bir ajan tarafindan yazilir; dosya yoksa test ATLANIR (sozlesme yine yukaridaki testlerle sinanir).
for (const known of KNOWN_DOCUMENTS) {
  const file = path.join(DEFAULT_LEGAL_DIR, `${known.slug}.md`);
  const exists = fs.existsSync(file);
  test(`GERCEK belge server/legal/${known.slug}.md sozlesmeye ve govde alt kumesine uyar`, { skip: exists ? false : 'dosya henuz yok' }, () => {
    const text = fs.readFileSync(file, 'utf8');
    assert.equal(text.includes('\r'), false, 'LF satir sonu');
    const parsed = parseLegalDocument(text);
    assert.equal(parsed.meta.id, known.id);
    assert.equal(parsed.meta.slug, known.slug);
    assert.equal(parsed.meta.requires_acceptance, known.requiresAcceptance);
    assert.equal(parsed.meta.title, known.id === 'terms' ? TERMS_TITLE : PRIVACY_TITLE);
    assert.ok(parsed.blocks.length > 0);
    const body = text.slice(text.indexOf('\n---', 3) + 4);
    assert.deepEqual(findUnsupportedSyntax(body), [], 'desteklenmeyen sozdizimi');
    const q = quietLogger();
    const svc = createLegalService({ logger: q.logger });
    const loaded = svc.getDocument(known.id);
    assert.ok(loaded, `yukleyici belgeyi kabul etmeli: ${q.logs.map((l) => l.text).join(' | ')}`);
    assert.equal(loaded.version, parsed.meta.version);
  });
}
