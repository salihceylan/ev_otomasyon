'use strict';

// GERCEK yasal metinler (server/legal/kullanici-sozlesmesi.md, gizlilik-politikasi.md) uctan uca: belge servisi + GERCEK
// baglama (createApp; sahte DB = test/auth/_auth_store, PG gerekmez). Bu metinleri sunucu yayimlar ve uygulama kayitta
// sozlesme surumunu buradan alir: belge EKSIK ya da BOZUKSA test ATLANMAZ, BASARISIZ olur (kayit uygulamada kilitlenir).
//   - iki belge yuklenir; yukleyici hata / uyari LOGLAMAZ (desteklenmeyen sozdizimi de uyaridir)
//   - dosya: UTF-8 (BOM yok), LF; on bilgi sozlesmeye uyar (id / slug / baslik / onay kurali; surum pozitif tamsayi;
//     effective_date takvim tarihi; status draft | final)
//   - govde bloklari: bos degil, yalniz izinli turler, metin bos degil, n yalniz oli'de, ** dengeli
//   - GET /yasal/<slug>: 200 HTML (tr, viewport, baslik, "Surum N · Yururluk: GG.AA.YYYY"), TASLAK bandi YALNIZ taslakta,
//     betik ve ham ** yok, public max-age=300
//   - GET /api/v1/legal ve /api/v1/legal/:id ayni belgeleri doner; kayit gercek guncel surumle kabul kaydi yazar
// Sozlesmenin kendisi (fixtures ile, belgeden bagimsiz): legal_service / legal_routes / legal_auth testleri.

const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const request = require('supertest');
const { setTestEnv, installFakeDb } = require('../auth/_helpers');
const { createAuthStore } = require('../auth/_auth_store');

setTestEnv({ BCRYPT_TEST_COST: '4', LOCAL_KEY_SECRET: crypto.randomBytes(32).toString('hex') });
const fakeDb = installFakeDb();
const store = createAuthStore().install(fakeDb);

const auth = require('../../src/middlewares/auth_middleware');
const { createApp } = require('../../src/server');
const { createLegalService, KNOWN_DOCUMENTS, DEFAULT_LEGAL_DIR } = require('../../src/services/legal_service');
const { parseLegalDocument, findUnsupportedSyntax, formatTrDate, PAGE_CSP } = require('../../src/utils/legal_markdown');

auth.configureAuthMiddleware({ cacheTtlMs: 0 });

// Sozlesmedeki baslik ve onay kurali (KVKK: aydinlatma metni onaya baglanmaz).
const EXPECTED = Object.freeze({
  terms: { slug: 'kullanici-sozlesmesi', title: 'Kullanıcı Sözleşmesi ve Son Kullanıcı Lisans Koşulları', requires: true },
  privacy: { slug: 'gizlilik-politikasi', title: 'Gizlilik Politikası ve KVKK Aydınlatma Metni', requires: false },
});
const BLOCK_TYPES = new Set(['h1', 'h2', 'h3', 'p', 'li', 'oli']);

const logs = [];
const capture = (level) => (...a) => logs.push({ level, text: a.map(String).join(' ') });
const legal = createLegalService({
  db: fakeDb,
  logger: { log: capture('log'), info: capture('info'), warn: capture('warn'), error: capture('error') },
});
const bridge = { isConnected: () => true, init() {}, end: async () => {} };
const pushService = { upsertToken: async () => {}, disableToken: async () => {}, disableAllTokensForUser: async () => 0 };
const app = createApp({ db: fakeDb, mqttBridge: bridge, pushService, legalService: legal });

const readRaw = (slug) => fs.readFileSync(path.join(DEFAULT_LEGAL_DIR, `${slug}.md`));

test('gercek belgeler: varsayilan dizin server/legal; iki belge de dosya olarak VAR', () => {
  assert.equal(legal.dir, DEFAULT_LEGAL_DIR);
  assert.equal(DEFAULT_LEGAL_DIR, path.join(__dirname, '..', '..', 'legal'));
  for (const known of KNOWN_DOCUMENTS) {
    const file = path.join(DEFAULT_LEGAL_DIR, `${known.slug}.md`);
    assert.ok(fs.existsSync(file), `eksik belge: server/legal/${known.slug}.md`);
  }
});

test('gercek belgeler yuklenir: liste terms -> privacy; yukleyici hata / uyari loglamaz', () => {
  legal.load();
  const docs = legal.listDocuments();
  assert.deepEqual(docs.map((d) => d.id), ['terms', 'privacy']);
  assert.deepEqual(logs.filter((l) => l.level === 'warn' || l.level === 'error'), [], 'yukleyici uyarisi');
});

for (const known of KNOWN_DOCUMENTS) {
  const want = EXPECTED[known.id];

  test(`gercek ${known.slug}.md: UTF-8 (BOM yok), LF; on bilgi sozlesmeye uyar`, () => {
    const raw = readRaw(known.slug);
    assert.notDeepEqual([...raw.subarray(0, 3)], [0xef, 0xbb, 0xbf], 'BOM olmamali');
    const text = raw.toString('utf8');
    assert.equal(Buffer.from(text, 'utf8').equals(raw), true, 'gecerli UTF-8');
    assert.equal(text.includes('\r'), false, 'LF satir sonu');
    assert.ok(text.startsWith('---\n'), 'on bilgi ilk satirda');

    const parsed = parseLegalDocument(text);
    const { meta } = parsed;
    assert.equal(meta.id, known.id);
    assert.equal(meta.slug, want.slug);
    assert.equal(meta.title, want.title);
    assert.equal(meta.requires_acceptance, want.requires);
    assert.ok(Number.isInteger(meta.version) && meta.version > 0, 'surum pozitif tamsayi');
    assert.match(meta.effective_date, /^\d{4}-\d{2}-\d{2}$/);
    const d = new Date(`${meta.effective_date}T00:00:00Z`);
    assert.equal(d.toISOString().slice(0, 10), meta.effective_date, 'takvim tarihi');
    assert.ok(['draft', 'final'].includes(meta.status));
    assert.deepEqual(findUnsupportedSyntax(parsed.body), [], 'desteklenmeyen sozdizimi');
  });

  test(`gercek ${known.slug}.md: govde bloklari bos degil ve blok modeline uyar`, () => {
    const doc = legal.getDocument(known.id);
    assert.ok(doc, 'belge yuklenmeli');
    assert.equal(doc.slug, want.slug);
    assert.equal(doc.url, `/yasal/${want.slug}`);
    assert.ok(doc.blocks.length > 0, 'blok yok');
    assert.ok(doc.blocks.some((b) => b.type === 'h2'), 'bolum basligi (##) yok');
    assert.ok(doc.blocks.some((b) => b.type === 'p'), 'paragraf yok');
    for (const [i, b] of doc.blocks.entries()) {
      const where = `blok ${i} (${b.type})`;
      assert.ok(BLOCK_TYPES.has(b.type), where);
      assert.equal(typeof b.text, 'string', where);
      assert.ok(b.text.trim().length > 0, `${where}: bos metin`);
      assert.equal(/\s{2,}|^\s|\s$/.test(b.text), false, `${where}: fazla bosluk`);
      assert.equal((b.text.match(/\*\*/g) || []).length % 2, 0, `${where}: kapanmamis **`);
      if (b.type === 'oli') assert.ok(Number.isInteger(b.n) && b.n > 0, `${where}: n`);
      else assert.equal('n' in b, false, `${where}: n yalniz oli'de`);
    }
    // Baslik govdede tekrarlanmaz (uygulama ve sayfa basligi ayrica gosterir).
    assert.ok(!(doc.blocks[0].type === 'h1' && doc.blocks[0].text === doc.title), 'baslik tekrari');
  });

  test(`GET /yasal/${want.slug} (gercek belge): 200 HTML, surum satiri, TASLAK bandi yalniz taslakta`, async () => {
    const doc = legal.getDocument(known.id);
    const res = await request(app).get(`/yasal/${want.slug}`);
    assert.equal(res.status, 200);
    assert.match(String(res.headers['content-type']), /^text\/html; charset=utf-8/i);
    assert.equal(res.headers['cache-control'], 'public, max-age=300');
    assert.equal(res.headers['content-security-policy'], PAGE_CSP);
    assert.equal(res.headers['set-cookie'], undefined);
    const html = res.text;
    assert.match(html, /<html lang="tr">/);
    assert.match(html, /<meta name="viewport" content="width=device-width, initial-scale=1">/);
    assert.ok(html.includes(`<title>${want.title}</title>`));
    assert.ok(html.includes(`<h1>${want.title}</h1>`));
    assert.ok(html.includes(`Sürüm ${doc.version} · Yürürlük: ${formatTrDate(doc.effective_date)}`));
    const banner = /<p class="taslak" role="note"><strong>TASLAK<\/strong>/.test(html);
    assert.equal(banner, doc.status === 'draft', `TASLAK bandi (status ${doc.status})`);
    assert.doesNotMatch(html, /<script/i);
    assert.equal(html.includes('**'), false, 'ham ** kalmamali');
    if (doc.blocks.some((b) => b.text.includes('**'))) assert.ok(html.includes('<strong>'));
    assert.equal((html.match(/<h1>/g) || []).length, 1, 'tek h1');
    assert.equal((html.match(/<h2>/g) || []).length, doc.blocks.filter((b) => b.type === 'h2').length);
  });
}

test('GET /api/v1/legal ve /api/v1/legal/:id gercek belgeleri doner (uygulamanin okudugu bicim)', async () => {
  const list = await request(app).get('/api/v1/legal');
  assert.equal(list.status, 200);
  assert.deepEqual(list.body.data.documents, legal.listDocuments());
  for (const known of KNOWN_DOCUMENTS) {
    for (const key of [known.id, known.slug]) {
      const res = await request(app).get(`/api/v1/legal/${key}`);
      assert.equal(res.status, 200, key);
      assert.deepEqual(res.body.data, legal.getDocument(known.id), key);
    }
  }
});

test('kayit gercek guncel surumle: kabul kaydi yazilir; eski / ileri surum 409 ve hesap acilmaz; legal durumu dogru', async () => {
  const terms = legal.getDocument('terms');
  const ok = await request(app)
    .post('/api/v1/auth/register')
    .send({ full_name: 'Gercek Metin', email: 'gercek-metin@legal.example.test', password: 'Gercek-Metin-2026', accept_terms_version: terms.version });
  assert.equal(ok.status, 201, JSON.stringify(ok.body));
  assert.deepEqual(ok.body.data.user.legal, {
    terms_accepted_version: terms.version,
    terms_current_version: terms.version,
    terms_status: terms.status,
    needs_acceptance: false,
  });
  const user = [...store.users.values()].find((u) => u.email === 'gercek-metin@legal.example.test');
  assert.deepEqual(store.acceptancesOf(user.id).map((a) => [a.document, a.version]), [['terms', terms.version]]);

  const stale = await request(app)
    .post('/api/v1/auth/register')
    .send({ full_name: 'Gercek Metin', email: 'gercek-eski@legal.example.test', password: 'Gercek-Metin-2026', accept_terms_version: terms.version + 1 });
  assert.equal(stale.status, 409);
  assert.equal(stale.body.code, 'LEGAL_VERSION_MISMATCH');
  assert.deepEqual(stale.body.data, { current_version: terms.version });
  assert.equal([...store.users.values()].some((u) => u.email === 'gercek-eski@legal.example.test'), false);

  // Kabulsuz hesap: taslak sozlesmede onay istenmez, kesinlesmis sozlesmede istenir.
  const plain = await request(app)
    .post('/api/v1/auth/register')
    .send({ full_name: 'Gercek Metin', email: 'gercek-kabulsuz@legal.example.test', password: 'Gercek-Metin-2026' });
  assert.equal(plain.status, 201, JSON.stringify(plain.body));
  assert.equal(plain.body.data.user.legal.needs_acceptance, terms.status === 'final');
});

test('sahte depo: tum SQL taninir', () => {
  assert.deepEqual(store.unmatched, []);
});
