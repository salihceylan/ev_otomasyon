'use strict';

// Yasal metin uclari, GERCEK baglama ile (createApp; sahte DB = test/auth/_auth_store, belgeler fixtures/draft):
//   GET  /yasal/:slug                         kimliksiz HTML (public, max-age=300; TASLAK bandi; kacirma; cerez/betik yok)
//   GET  /api/v1/legal | /api/legal           kimliksiz liste (zarf, sira terms -> privacy)
//   GET  /api/v1/legal/:id | /api/legal/:id   kimliksiz ayrinti + bloklar (id ya da slug); bilinmeyen 404 NOT_FOUND
//   POST /api/v1/legal/accept | /api/legal/accept
//        kullanici JWT; servis (PIN) oturumu 403; bilinmeyen belge / privacy / bozuk surum 400; eski surum 409
//        LEGAL_VERSION_MISMATCH + data.current_version; 200 {document, version, accepted_at}; tekrar ayni surum -> cift yok
// Gercek PostgreSQL karsiligi: legal_pg.test.js

const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const path = require('node:path');
const express = require('express');
const request = require('supertest');
const { setTestEnv, installFakeDb, makeAccessToken, makeServiceToken } = require('../auth/_helpers');
const { createAuthStore } = require('../auth/_auth_store');

setTestEnv({ BCRYPT_TEST_COST: '4', LOCAL_KEY_SECRET: crypto.randomBytes(32).toString('hex') });
const fakeDb = installFakeDb();
const store = createAuthStore().install(fakeDb);

const auth = require('../../src/middlewares/auth_middleware');
const { createApp } = require('../../src/server');
const { createLegalService } = require('../../src/services/legal_service');
const { createLegalRouter, createLegalPageHandler } = require('../../src/routes/legal_routes');
const { errorHandler, notFoundHandler } = require('../../src/middlewares/error_handler');
const { PAGE_CSP } = require('../../src/utils/legal_markdown');

const silent = { log() {}, info() {}, warn() {}, error() {} };
const FIX = path.join(__dirname, 'fixtures');
const legal = createLegalService({ dir: path.join(FIX, 'draft'), db: fakeDb, logger: silent });
const bridge = { isConnected: () => true, init() {}, end: async () => {} };
const pushService = { upsertToken: async () => {}, disableToken: async () => {}, disableAllTokensForUser: async () => 0 };
const app = createApp({ db: fakeDb, mqttBridge: bridge, pushService, legalService: legal });

const HOME_ID = crypto.randomUUID();
const sessions = new Map();
auth.configureAuthMiddleware({ cacheTtlMs: 0, loadServiceSession: async (sid) => sessions.get(sid) || null });

const TERMS = {
  id: 'terms',
  slug: 'kullanici-sozlesmesi',
  title: 'Kullanıcı Sözleşmesi ve Son Kullanıcı Lisans Koşulları',
  version: 1,
  effective_date: '2026-10-08',
  status: 'draft',
  requires_acceptance: true,
  url: '/yasal/kullanici-sozlesmesi',
};
const PRIVACY = {
  id: 'privacy',
  slug: 'gizlilik-politikasi',
  title: 'Gizlilik Politikası ve KVKK Aydınlatma Metni',
  version: 1,
  effective_date: '2026-10-08',
  status: 'draft',
  requires_acceptance: false,
  url: '/yasal/gizlilik-politikasi',
};

const bearer = (u) => `Bearer ${makeAccessToken(u)}`;
const accept = (user, body, url = '/api/v1/legal/accept') => request(app).post(url).set('Authorization', bearer(user)).send(body);

test.beforeEach(() => {
  const router = app.locals.legalRouter;
  if (router && router.limiters) for (const l of Object.values(router.limiters)) l.reset();
});

// ------------------------------------------------------------------------------------------------ HTML
test('GET /yasal/:slug: HTML (tr, viewport, surum satiri, TASLAK, kacirma), public max-age=300, siki CSP, cerez/betik yok', async () => {
  const res = await request(app).get('/yasal/kullanici-sozlesmesi');
  assert.equal(res.status, 200);
  assert.match(String(res.headers['content-type']), /^text\/html; charset=utf-8/i);
  assert.equal(res.headers['cache-control'], 'public, max-age=300');
  assert.equal(res.headers['content-security-policy'], PAGE_CSP);
  assert.equal(res.headers['x-content-type-options'], 'nosniff');
  assert.equal(res.headers['set-cookie'], undefined);
  const html = res.text;
  assert.match(html, /<html lang="tr">/);
  assert.match(html, /<meta name="viewport" content="width=device-width, initial-scale=1">/);
  assert.ok(html.includes('<title>Kullanıcı Sözleşmesi ve Son Kullanıcı Lisans Koşulları</title>'));
  assert.ok(html.includes('Sürüm 1 · Yürürlük: 08.10.2026'));
  assert.ok(html.includes('TASLAK'));
  assert.doesNotMatch(html, /<script/i);
  assert.ok(html.includes('&lt;script&gt;alert(&quot;x&quot;)&lt;/script&gt; &amp; &#39;tırnak&#39;'));
  assert.ok(html.includes('<strong>test</strong>'));
  assert.equal((html.match(/<h1>/g) || []).length, 1, 'govdenin basliga esit # satiri tekrarlanmaz');

  const head = await request(app).head('/yasal/gizlilik-politikasi');
  assert.equal(head.status, 200);
  const trailing = await request(app).get('/yasal/gizlilik-politikasi/');
  assert.equal(trailing.status, 200);
});

test('GET /yasal/:slug bilinmeyen / id / buyuk harf -> 404 HTML (no-store); sorgu dizgesi sayfaya YANSITILMAZ', async () => {
  for (const url of ['/yasal/yok-boyle', '/yasal/terms', '/yasal/KULLANICI-SOZLESMESI', '/yasal/kullanici-sozlesmesi.md']) {
    const res = await request(app).get(url);
    assert.equal(res.status, 404, url);
    assert.match(String(res.headers['content-type']), /^text\/html; charset=utf-8/i, url);
    assert.equal(res.headers['cache-control'], 'no-store', url);
    assert.match(res.text, /<html lang="tr">/);
    assert.match(res.text, /bulunamadı/);
    assert.ok(!res.text.includes('yok-boyle'));
  }
  const q = await request(app).get('/yasal/kullanici-sozlesmesi?x=%3Cb%3Eyansima-izi%3C%2Fb%3E');
  assert.equal(q.status, 200);
  assert.ok(!q.text.includes('yansima-izi'));
});

test('GET /yasal, /yasal/ ve ic ice yol: tarayiciya JSON degil 404 HTML (no-store, ayni CSP); yol yansitilmaz', async () => {
  for (const url of ['/yasal', '/yasal/', '/yasal/kullanici-sozlesmesi/ek-iz', '/yasal/a/b/c-iz']) {
    for (const method of ['get', 'head']) {
      const res = await request(app)[method](url);
      assert.equal(res.status, 404, `${method} ${url}`);
      assert.match(String(res.headers['content-type']), /^text\/html; charset=utf-8/i, `${method} ${url}`);
      assert.equal(res.headers['cache-control'], 'no-store', `${method} ${url}`);
      assert.equal(res.headers['content-security-policy'], PAGE_CSP, `${method} ${url}`);
      if (method === 'get') {
        assert.match(res.text, /<html lang="tr">/);
        assert.match(res.text, /bulunamadı/);
        assert.ok(!res.text.includes('-iz'), 'yol sayfaya yansimaz');
      }
    }
  }
  const post = await request(app).post('/yasal/kullanici-sozlesmesi').send({});
  assert.equal(post.status, 404, 'yalniz GET / HEAD');
  assert.equal(post.body.code, 'NOT_FOUND');
});

// ------------------------------------------------------------------------------------------------ JSON okuma
test('GET /api/v1/legal ve /api/legal: kimliksiz; basari zarfi; sira terms -> privacy; no-store', async () => {
  for (const url of ['/api/v1/legal', '/api/legal', '/api/v1/legal/']) {
    const res = await request(app).get(url).set('Authorization', 'Bearer gecersiz.belirtec.degeri');
    assert.equal(res.status, 200, url);
    assert.equal(res.body.success, true);
    assert.equal(typeof res.body.message, 'string');
    assert.deepEqual(res.body.data, { documents: [TERMS, PRIVACY] }, url);
    assert.equal(res.headers['cache-control'], 'no-store');
  }
});

test('GET /api/v1/legal/:id (id ya da slug): ayrinti + bloklar; bilinmeyen 404 NOT_FOUND', async () => {
  const a = await request(app).get('/api/v1/legal/terms');
  const b = await request(app).get('/api/legal/kullanici-sozlesmesi');
  assert.equal(a.status, 200);
  assert.deepEqual(a.body.data, b.body.data);
  const { blocks, ...meta } = a.body.data;
  assert.deepEqual(meta, TERMS);
  assert.deepEqual(blocks.slice(0, 3), [
    { type: 'p', text: 'Bu metin yalnızca **test** amaçlıdır. İkinci satır aynı paragrafa katılır.' },
    { type: 'h2', text: '1. Taraflar' },
    { type: 'li', text: 'Hizmet sağlayıcı: Örnek Şirket' },
  ]);
  assert.deepEqual(blocks.filter((x) => x.type === 'oli'), [
    { type: 'oli', text: 'Birinci madde', n: 1 },
    { type: 'oli', text: 'İkinci madde', n: 2 },
  ]);
  for (const blk of blocks) {
    assert.ok(['h1', 'h2', 'h3', 'p', 'li', 'oli'].includes(blk.type));
    assert.deepEqual(Object.keys(blk).sort(), blk.type === 'oli' ? ['n', 'text', 'type'] : ['text', 'type']);
  }
  const p = await request(app).get('/api/v1/legal/privacy');
  assert.equal(p.status, 200);
  assert.equal(p.body.data.requires_acceptance, false);

  for (const url of ['/api/v1/legal/yok', '/api/legal/TERMS', '/api/v1/legal/accept']) {
    const nf = await request(app).get(url);
    assert.equal(nf.status, 404, url);
    assert.equal(nf.body.success, false);
    assert.equal(nf.body.code, 'NOT_FOUND');
  }
});

test('yasal yonlendirici baska uclari etkilemez: bilinmeyen API ucu 404 JSON, POST /api/v1/legal 404', async () => {
  const x = await request(app).get('/api/v1/yok-boyle-bir-uc');
  assert.equal(x.status, 404);
  assert.equal(x.body.code, 'NOT_FOUND');
  const y = await request(app).post('/api/v1/legal').send({});
  assert.equal(y.status, 404);
  const me = await request(app).get('/api/v1/auth/me');
  assert.equal(me.status, 401, 'kimlik uclari aynen korunur');
});

// ------------------------------------------------------------------------------------------------ kabul
test('POST accept: kimlik yok 401; servis (PIN) oturumu 403 FORBIDDEN (kendi evine atifli govdeyle de); kayit yazilmaz', async () => {
  const none = await request(app).post('/api/v1/legal/accept').send({ document: 'terms', version: 1 });
  assert.equal(none.status, 401);

  const sid = crypto.randomUUID();
  sessions.set(sid, { id: sid, home_id: HOME_ID, technician_name: 'Teknisyen', expires_at: new Date(Date.now() + 3600e3), revoked_at: null });
  const token = makeServiceToken({ sid, home_id: HOME_ID });
  for (const body of [{ document: 'terms', version: 1 }, { document: 'terms', version: 1, home_id: HOME_ID }]) {
    for (const url of ['/api/v1/legal/accept', '/api/legal/accept']) {
      const res = await request(app).post(url).set('Authorization', `Bearer ${token}`).send(body);
      assert.equal(res.status, 403, `${url} ${JSON.stringify(body)}`);
      assert.equal(res.body.code, 'FORBIDDEN');
    }
  }
  assert.equal(store.legalAcceptances.length, 0);
});

test('POST accept: bilinmeyen / eksik belge, privacy (aydinlatma onaya baglanmaz), bozuk surum -> 400 VALIDATION', async () => {
  const user = store.addUser();
  const cases = [
    {},
    { version: 1 },
    { document: 'cerez', version: 1 },
    { document: 'privacy', version: 1 },
    { document: 'gizlilik-politikasi', version: 1 },
    { document: 'terms' },
    { document: 'terms', version: 0 },
    { document: 'terms', version: -1 },
    { document: 'terms', version: 1.5 },
    { document: 'terms', version: 'bir' },
    { document: 'terms', version: true },
    { document: ['terms'], version: 1 },
  ];
  for (const body of cases) {
    const res = await accept(user, body);
    assert.equal(res.status, 400, JSON.stringify(body));
    assert.equal(res.body.code, 'VALIDATION', JSON.stringify(body));
  }
  assert.equal(store.acceptancesOf(user.id).length, 0);
  assert.equal(store.users.get(user.id).terms_version, null);
});

test('POST accept: eski / ileri surum -> 409 LEGAL_VERSION_MISMATCH + data.current_version; kayit yazilmaz', async () => {
  const user = store.addUser();
  for (const version of [2, '7']) {
    const res = await accept(user, { document: 'terms', version });
    assert.equal(res.status, 409);
    assert.equal(res.body.success, false);
    assert.equal(res.body.code, 'LEGAL_VERSION_MISMATCH');
    assert.deepEqual(res.body.data, { current_version: 1 });
    assert.equal(typeof res.body.message, 'string');
  }
  assert.equal(store.acceptancesOf(user.id).length, 0);
});

test('POST accept: 200 {document, version, accepted_at}; kayit (ip, user_agent en cok 255) + users.terms_*; tekrar -> cift yok; /auth/me guncel', async () => {
  const user = store.addUser();
  const ua = `AHBU/1.0 ${'x'.repeat(300)}`;
  const res = await accept(user, { document: 'terms', version: 1 }).set('User-Agent', ua);
  assert.equal(res.status, 200, JSON.stringify(res.body));
  assert.equal(res.body.success, true);
  assert.deepEqual(Object.keys(res.body.data).sort(), ['accepted_at', 'document', 'version']);
  assert.equal(res.body.data.document, 'terms');
  assert.equal(res.body.data.version, 1);
  assert.ok(!Number.isNaN(Date.parse(res.body.data.accepted_at)));
  assert.equal(res.headers['cache-control'], 'no-store');

  const rows = store.acceptancesOf(user.id);
  assert.equal(rows.length, 1);
  assert.equal(rows[0].document, 'terms');
  assert.equal(rows[0].version, 1);
  assert.equal(rows[0].user_agent, ua.slice(0, 255));
  assert.match(String(rows[0].ip_address), /127\.0\.0\.1|::1/);
  assert.equal(store.users.get(user.id).terms_version, 1);
  assert.ok(store.users.get(user.id).terms_accepted_at instanceof Date);

  // tekrar (slug + rakam dizgesi, eski yol): ayni kabul doner, ikinci satir YAZILMAZ
  const again = await accept(user, { document: 'kullanici-sozlesmesi', version: '1' }, '/api/legal/accept');
  assert.equal(again.status, 200, JSON.stringify(again.body));
  assert.equal(again.body.data.accepted_at, res.body.data.accepted_at);
  assert.equal(store.acceptancesOf(user.id).length, 1);

  const me = await request(app).get('/api/v1/auth/me').set('Authorization', bearer(user));
  assert.equal(me.status, 200);
  assert.deepEqual(me.body.data.user.legal, {
    terms_accepted_version: 1,
    terms_current_version: 1,
    terms_status: 'draft',
    needs_acceptance: false,
  });
});

test('POST accept: personel de kabul edebilir; kabul kullaniciya ozeldir', async () => {
  const staff = store.addUser({ role: 'service_user' });
  const other = store.addUser();
  const res = await accept(staff, { document: 'terms', version: 1 });
  assert.equal(res.status, 200);
  assert.equal(store.acceptancesOf(staff.id).length, 1);
  assert.equal(store.acceptancesOf(other.id).length, 0);
  assert.equal(store.users.get(other.id).terms_version, null);
});

test('POST accept: kullanici basina hiz siniri (429 RATE_LIMITED)', async () => {
  const user = store.addUser();
  const limiter = app.locals.legalRouter.limiters.accept;
  const max = limiter.options.max;
  for (let i = 0; i < max; i += 1) assert.equal((await accept(user, { document: 'terms', version: 1 })).status, 200);
  const blocked = await accept(user, { document: 'terms', version: 1 });
  assert.equal(blocked.status, 429);
  assert.equal(blocked.body.code, 'RATE_LIMITED');
  assert.equal(store.acceptancesOf(user.id).length, 1);
});

// ------------------------------------------------------------------------------------------------ belge yok
test('belge dizini yoksa: liste bos, ayrinti 404, sayfa 404, kabul 400 (sunucu yine calisir)', async () => {
  const empty = createLegalService({ dir: path.join(FIX, 'boyle-bir-dizin-yok'), db: fakeDb, logger: silent });
  const mini = express();
  mini.use(express.json());
  mini.use((req, res, next) => {
    req.user = { id: crypto.randomUUID(), role: 'user', is_service_session: false };
    next();
  });
  mini.use('/api/v1', createLegalRouter({ legal: empty, authenticateToken: (req, res, next) => next() }));
  mini.get('/yasal/:slug', createLegalPageHandler({ legal: empty }));
  mini.use(notFoundHandler);
  mini.use(errorHandler);

  const list = await request(mini).get('/api/v1/legal');
  assert.equal(list.status, 200);
  assert.deepEqual(list.body.data, { documents: [] });
  assert.equal((await request(mini).get('/api/v1/legal/terms')).status, 404);
  assert.equal((await request(mini).get('/yasal/kullanici-sozlesmesi')).status, 404);
  const acc = await request(mini).post('/api/v1/legal/accept').send({ document: 'terms', version: 1 });
  assert.equal(acc.status, 400);
  assert.equal(acc.body.code, 'VALIDATION');
});

test('sahte depo: tum SQL taninir', () => {
  assert.deepEqual(store.unmatched, []);
});
