'use strict';

// Uygulama baglantisi dogrulama dosyalari, GERCEK baglama ile (createApp; sahte DB, MQTT yok):
//   GET|HEAD /.well-known/assetlinks.json             her zaman 200 application/json (Google Digital Asset Links)
//   GET|HEAD /.well-known/apple-app-site-association  APPLE_TEAM_ID gecerliyse 200 application/json;
//   GET|HEAD /apple-app-site-association              yoksa / gecersizse mevcut JSON 404 (notFoundHandler)
//   Basliklar: Cache-Control public, max-age=3600; X-Content-Type-Options nosniff. Kimliksiz, yonlendirmesiz,
//   hiz siniri yok. ANDROID_APP_LINK_CERT_SHA256 ek parmak izleri: gecerli eklenir, gecersiz atlanir (TEK uyari),
//   tekrar ayiklanir, kucuk harf normalize.
// Govdeler createApp aninda ortamdan bir kez uretilir: her senaryo kendi uygulamasini kurar ve ortam degiskenlerini
// yalnizca kurulum boyunca ayarlar (yerel .env'deki degerler testi etkilemez).
// Saf fonksiyonlar: app_links.test.js

const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const request = require('supertest');
const { setTestEnv, installFakeDb } = require('../auth/_helpers');

setTestEnv({ LOCAL_KEY_SECRET: crypto.randomBytes(32).toString('hex') });
const fakeDb = installFakeDb();
const bridge = { isConnected: () => true, init() {}, end: async () => {} };

const { createApp } = require('../../src/server');

const RELEASE_FP = 'C9:58:0E:1D:E0:39:09:0C:B5:9B:71:B6:EA:F9:58:2A:F2:97:5C:CB:92:2B:8D:BA:77:C1:58:87:E1:AC:E0:8F';
// Yalnizca test icin uydurma deger (hicbir gercek anahtara ait degil).
const EXTRA_FP = '0A:1B:2C:3D:4E:5F:60:71:82:93:A4:B5:C6:D7:E8:F9:0A:1B:2C:3D:4E:5F:60:71:82:93:A4:B5:C6:D7:E8:F9';
const TEAM = 'ABCDE12345';

const ASSET_LINKS = '/.well-known/assetlinks.json';
const AASA_URLS = ['/.well-known/apple-app-site-association', '/apple-app-site-association'];

// Spesifikasyondaki metin, bayt bayt (anahtar sirasi dahil).
const ASSET_LINKS_DEFAULT_BODY =
  '[{"relation":["delegate_permission/common.handle_all_urls"],"target":{"namespace":"android_app",' +
  '"package_name":"com.ahbu.evotomasyon.ev_otomasyon","sha256_cert_fingerprints":' +
  '["C9:58:0E:1D:E0:39:09:0C:B5:9B:71:B6:EA:F9:58:2A:F2:97:5C:CB:92:2B:8D:BA:77:C1:58:87:E1:AC:E0:8F"]}}]';
const assetLinksBody = (fps) =>
  '[{"relation":["delegate_permission/common.handle_all_urls"],"target":{"namespace":"android_app",' +
  `"package_name":"com.ahbu.evotomasyon.ev_otomasyon","sha256_cert_fingerprints":${JSON.stringify(fps)}}}]`;
const AASA_BODY =
  '{"applinks":{"apps":[],"details":[{"appIDs":["ABCDE12345.com.ahbu.evotomasyon.evOtomasyon"],' +
  '"components":[{"/":"/claim*"},{"/":"/reset-password*"},{"/":"/magic-login*"}],' +
  '"appID":"ABCDE12345.com.ahbu.evotomasyon.evOtomasyon","paths":["/claim*","/reset-password*","/magic-login*"]}]}}';
const NOT_FOUND_BODY = { success: false, message: 'İstenen API ucu bulunamadı.', code: 'NOT_FOUND' };

const APP_LINK_ENV = ['ANDROID_APP_LINK_CERT_SHA256', 'APPLE_TEAM_ID'];

/**
 * Uygulamayi verilen ortamla kurar (yalnizca kurulum boyunca; tanimsiz anahtar = degisken yok) ve `fn(app, warnings)`
 * cagirir. warnings: kurulum VE sonraki istekler boyunca yazilan [APP-LINKS] uyarilari.
 */
async function withApp(env, fn) {
  const warnings = [];
  const origWarn = console.warn;
  console.warn = (...args) => {
    const line = args.map(String).join(' ');
    if (line.includes('[APP-LINKS]')) warnings.push(line);
    else origWarn(...args);
  };
  try {
    const saved = {};
    for (const k of APP_LINK_ENV) saved[k] = process.env[k];
    let app;
    try {
      for (const k of APP_LINK_ENV) {
        if (env[k] === undefined) delete process.env[k];
        else process.env[k] = env[k];
      }
      app = createApp({ db: fakeDb, mqttBridge: bridge });
    } finally {
      for (const k of APP_LINK_ENV) {
        if (saved[k] === undefined) delete process.env[k];
        else process.env[k] = saved[k];
      }
    }
    return await fn(app, warnings);
  } finally {
    console.warn = origWarn;
  }
}

function assertWellKnownHeaders(res, label) {
  assert.equal(res.status, 200, label);
  assert.equal(res.headers['content-type'], 'application/json', label);
  assert.equal(res.headers['cache-control'], 'public, max-age=3600', label);
  assert.equal(res.headers['x-content-type-options'], 'nosniff', label);
  assert.equal(res.headers.location, undefined, label);
}

test('assetlinks.json: kimliksiz 200, application/json, Digital Asset Links icerigi birebir, onbellek + nosniff', async () => {
  await withApp({}, async (app, warnings) => {
    const res = await request(app).get(ASSET_LINKS);
    assertWellKnownHeaders(res, ASSET_LINKS);
    assert.equal(res.text, ASSET_LINKS_DEFAULT_BODY);
    assert.equal(res.headers['content-length'], String(Buffer.byteLength(ASSET_LINKS_DEFAULT_BODY)));
    assert.deepEqual(warnings, []);
  });
});

test('assetlinks.json: gecersiz Authorization basligi ve art arda istekler engellenmez (JWT / hiz siniri yok)', async () => {
  await withApp({}, async (app) => {
    const withBadJwt = await request(app).get(ASSET_LINKS).set('Authorization', 'Bearer gecersiz.jwt.degeri');
    assertWellKnownHeaders(withBadJwt, 'gecersiz JWT');
    assert.equal(withBadJwt.text, ASSET_LINKS_DEFAULT_BODY);
    for (let i = 1; i <= 30; i += 1) {
      const res = await request(app).get(ASSET_LINKS);
      assert.equal(res.status, 200, `istek ${i}`);
    }
  });
});

test('HEAD: assetlinks.json ve iki AASA yolu ayni basliklarla 200, govdesiz', async () => {
  await withApp({ APPLE_TEAM_ID: TEAM }, async (app) => {
    for (const [url, body] of [[ASSET_LINKS, ASSET_LINKS_DEFAULT_BODY], ...AASA_URLS.map((u) => [u, AASA_BODY])]) {
      const res = await request(app).head(url);
      assertWellKnownHeaders(res, `HEAD ${url}`);
      assert.equal(res.headers['content-length'], String(Buffer.byteLength(body)), `HEAD ${url}`);
      assert.ok(!res.text, `HEAD ${url}: govde olmamali`);
    }
  });
});

test('ANDROID_APP_LINK_CERT_SHA256: gecerli ek eklenir, gecersiz atlanir (TEK uyari), tekrar ayiklanir, kucuk harf normalize', async () => {
  const raw = ` ${EXTRA_FP.toLowerCase()} , bozuk-parmak-izi, ${RELEASE_FP.toLowerCase()}, ${EXTRA_FP} ,12:34`;
  await withApp({ ANDROID_APP_LINK_CERT_SHA256: raw }, async (app, warnings) => {
    for (let i = 1; i <= 3; i += 1) {
      const res = await request(app).get(ASSET_LINKS);
      assertWellKnownHeaders(res, `istek ${i}`);
      assert.equal(res.text, assetLinksBody([RELEASE_FP, EXTRA_FP]), `istek ${i}`);
    }
    assert.equal(warnings.length, 1, warnings.join('\n'));
    assert.match(warnings[0], /ANDROID_APP_LINK_CERT_SHA256/);
    assert.ok(warnings[0].includes('bozuk-parmak-izi') && warnings[0].includes('12:34'), warnings[0]);
  });
});

test('ANDROID_APP_LINK_CERT_SHA256: yalnizca gecersiz degerler -> depodaki parmak izi yine yayinlanir', async () => {
  await withApp({ ANDROID_APP_LINK_CERT_SHA256: 'bozuk' }, async (app, warnings) => {
    const res = await request(app).get(ASSET_LINKS);
    assertWellKnownHeaders(res, 'yalniz gecersiz');
    assert.equal(res.text, ASSET_LINKS_DEFAULT_BODY);
    assert.equal(warnings.length, 1);
  });
});

test('apple-app-site-association: APPLE_TEAM_ID yoksa / bossa iki yolda da mevcut JSON 404 (notFoundHandler), uyari yok', async () => {
  for (const env of [{}, { APPLE_TEAM_ID: '' }, { APPLE_TEAM_ID: '   ' }]) {
    await withApp(env, async (app, warnings) => {
      for (const url of AASA_URLS) {
        const res = await request(app).get(url);
        assert.equal(res.status, 404, `${JSON.stringify(env)} ${url}`);
        assert.deepEqual(res.body, NOT_FOUND_BODY, url);
        assert.notEqual(res.headers['cache-control'], 'public, max-age=3600', url);
      }
      assert.deepEqual(warnings, []);
    });
  }
});

test('apple-app-site-association: gecerli APPLE_TEAM_ID -> iki yolda 200 application/json, yeni + eski iOS bicimi birebir; kimliksiz', async () => {
  await withApp({ APPLE_TEAM_ID: TEAM }, async (app, warnings) => {
    for (const url of AASA_URLS) {
      const res = await request(app).get(url);
      assertWellKnownHeaders(res, url);
      assert.equal(res.text, AASA_BODY, url);
      const withBadJwt = await request(app).get(url).set('Authorization', 'Bearer gecersiz.jwt.degeri');
      assertWellKnownHeaders(withBadJwt, `${url} gecersiz JWT`);
    }
    // assetlinks.json Team ID'den bagimsiz
    assert.equal((await request(app).get(ASSET_LINKS)).text, ASSET_LINKS_DEFAULT_BODY);
    assert.deepEqual(warnings, []);
  });
});

test('apple-app-site-association: gecersiz APPLE_TEAM_ID -> 404 (notFoundHandler) + kurulumda TEK uyari', async () => {
  for (const team of ['ABCDE1234', 'ABCDE123456', 'abcde12345', 'ABCDE-1234', 'TEAMID']) {
    await withApp({ APPLE_TEAM_ID: team }, async (app, warnings) => {
      for (const url of AASA_URLS) {
        const res = await request(app).get(url);
        assert.equal(res.status, 404, `${team} ${url}`);
        assert.deepEqual(res.body, NOT_FOUND_BODY, `${team} ${url}`);
      }
      assert.equal(warnings.length, 1, `${team}: ${warnings.join('\n')}`);
      assert.match(warnings[0], /APPLE_TEAM_ID/);
    });
  }
});

test('yalnizca GET/HEAD; diger .well-known yollari ve POST mevcut JSON 404 olarak kalir', async () => {
  await withApp({ APPLE_TEAM_ID: TEAM }, async (app) => {
    for (const url of ['/.well-known/security.txt', '/.well-known/assetlinks', '/.well-known/apple-app-site-association.json']) {
      const res = await request(app).get(url);
      assert.equal(res.status, 404, url);
      assert.deepEqual(res.body, NOT_FOUND_BODY, url);
    }
    for (const url of [ASSET_LINKS, ...AASA_URLS]) {
      const res = await request(app).post(url).send({});
      assert.equal(res.status, 404, `POST ${url}`);
      assert.equal(res.body.code, 'NOT_FOUND', `POST ${url}`);
    }
  });
});
