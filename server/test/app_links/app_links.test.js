'use strict';

// Uygulama baglantisi dogrulama dosyalari: utils/app_links (saf fonksiyonlar; G/C ve gunluk YOK).
//   - SHA-256 imza parmak izi: 32 bayt, iki nokta ayrimli onaltilik; buyuk harfe normalize; gecersiz -> null
//   - ANDROID_APP_LINK_CERT_SHA256: depodaki surum parmak izi HER ZAMAN ilk sirada; virgullu EK degerler normalize
//     edilir, gecersiz olan atlanir (uyari metni doner), tekrarlar ayiklanir
//   - Google Digital Asset Links (assetlinks.json) ve apple-app-site-association icerigi birebir
//   - APPLE_TEAM_ID: 10 karakter [A-Z0-9]; yoksa / gecersizse AASA uretilmez
// Express baglamasi (yollar, basliklar, HEAD, 404, tek uyari): app_links_routes.test.js

const test = require('node:test');
const assert = require('node:assert/strict');

const appLinks = require('../../src/utils/app_links');

const {
  normalizeCertSha256,
  resolveAndroidCertFingerprints,
  buildAssetLinks,
  normalizeAppleTeamId,
  buildAppleAppSiteAssociation,
  buildAppLinkDocuments,
} = appLinks;

const RELEASE_FP = 'C9:58:0E:1D:E0:39:09:0C:B5:9B:71:B6:EA:F9:58:2A:F2:97:5C:CB:92:2B:8D:BA:77:C1:58:87:E1:AC:E0:8F';
// Yalnizca test icin uydurma deger (hicbir gercek anahtara ait degil).
const EXTRA_FP = '0A:1B:2C:3D:4E:5F:60:71:82:93:A4:B5:C6:D7:E8:F9:0A:1B:2C:3D:4E:5F:60:71:82:93:A4:B5:C6:D7:E8:F9';
const TEAM = 'ABCDE12345';

const assetLinksBody = (fps) =>
  '[{"relation":["delegate_permission/common.handle_all_urls"],"target":{"namespace":"android_app",' +
  `"package_name":"com.ahbu.evotomasyon.ev_otomasyon","sha256_cert_fingerprints":${JSON.stringify(fps)}}}]`;

const aasaBody = (team) =>
  `{"applinks":{"apps":[],"details":[{"appIDs":["${team}.com.ahbu.evotomasyon.evOtomasyon"],` +
  '"components":[{"/":"/claim*"},{"/":"/reset-password*"},{"/":"/magic-login*"}],' +
  `"appID":"${team}.com.ahbu.evotomasyon.evOtomasyon","paths":["/claim*","/reset-password*","/magic-login*"]}]}}`;

test('sabitler: Android / iOS paket adlari ve depodaki surum imza parmak izi', () => {
  assert.equal(appLinks.ANDROID_PACKAGE_NAME, 'com.ahbu.evotomasyon.ev_otomasyon');
  assert.equal(appLinks.IOS_BUNDLE_ID, 'com.ahbu.evotomasyon.evOtomasyon');
  assert.deepEqual([...appLinks.DEFAULT_ANDROID_CERT_SHA256], [RELEASE_FP]);
  assert.deepEqual([...appLinks.APP_LINK_PATHS], ['/claim', '/reset-password', '/magic-login']);
});

test('normalizeCertSha256: gecerli parmak izi buyuk harfe normalize edilir, bas/son bosluk kirpilir', () => {
  assert.equal(normalizeCertSha256(RELEASE_FP), RELEASE_FP);
  assert.equal(normalizeCertSha256(RELEASE_FP.toLowerCase()), RELEASE_FP);
  assert.equal(normalizeCertSha256(`  ${EXTRA_FP.toLowerCase()}\t`), EXTRA_FP);
});

test('normalizeCertSha256: 32 bayt iki nokta ayrimli onaltilik olmayan her deger null', () => {
  const bad = [
    '',
    '   ',
    undefined,
    null,
    42,
    {},
    RELEASE_FP.replace(/:/g, ''), // ayracsiz 64 hane
    RELEASE_FP.replace(/:/g, '-'), // yanlis ayrac
    RELEASE_FP.slice(0, -3), // 31 bayt
    `${RELEASE_FP}:00`, // 33 bayt
    `${RELEASE_FP}:`, // sonda ayrac
    RELEASE_FP.replace('C9', 'G9'), // onaltilik disi
    RELEASE_FP.replace('C9:58', 'C:958'), // yanlis gruplama
    RELEASE_FP.replace('C9:58', 'C9: 58'), // icte bosluk
    'C9:58:0E',
  ];
  for (const v of bad) assert.equal(normalizeCertSha256(v), null, JSON.stringify(v));
});

test('resolveAndroidCertFingerprints: ortam yoksa / bossa yalnizca depodaki surum parmak izi', () => {
  for (const raw of [undefined, null, '', '   ', ' , ,']) {
    assert.deepEqual(resolveAndroidCertFingerprints(raw), { fingerprints: [RELEASE_FP], invalid: [] }, String(raw));
  }
});

test('resolveAndroidCertFingerprints: gecerli ek eklenir, gecersiz atlanir, tekrar ayiklanir, kucuk harf normalize', () => {
  const raw = ` ${EXTRA_FP.toLowerCase()} , parmak-izi-degil, ${RELEASE_FP.toLowerCase()},${EXTRA_FP}, 12:34 `;
  assert.deepEqual(resolveAndroidCertFingerprints(raw), {
    fingerprints: [RELEASE_FP, EXTRA_FP],
    invalid: ['parmak-izi-degil', '12:34'],
  });
});

test('resolveAndroidCertFingerprints: depodaki varsayilan liste degistirilmez', () => {
  const out = resolveAndroidCertFingerprints(EXTRA_FP);
  out.fingerprints.push('X');
  assert.deepEqual([...appLinks.DEFAULT_ANDROID_CERT_SHA256], [RELEASE_FP]);
  assert.deepEqual(resolveAndroidCertFingerprints('').fingerprints, [RELEASE_FP]);
});

test('buildAssetLinks: Google Digital Asset Links bicimi birebir', () => {
  assert.equal(JSON.stringify(buildAssetLinks([RELEASE_FP])), assetLinksBody([RELEASE_FP]));
  assert.equal(JSON.stringify(buildAssetLinks([RELEASE_FP, EXTRA_FP])), assetLinksBody([RELEASE_FP, EXTRA_FP]));
});

test('normalizeAppleTeamId: 10 karakter [A-Z0-9]; bas/son bosluk kirpilir; aksi null', () => {
  assert.equal(normalizeAppleTeamId(TEAM), TEAM);
  assert.equal(normalizeAppleTeamId(`  ${TEAM} `), TEAM);
  assert.equal(normalizeAppleTeamId('Z9Y8X7W6V5'), 'Z9Y8X7W6V5');
  const bad = [undefined, null, '', '   ', 'ABCDE1234', 'ABCDE123456', 'abcde12345', 'ABCDE-1234', 'ABCDE 1234', 'ABCDÉ12345', 1234567890];
  for (const v of bad) assert.equal(normalizeAppleTeamId(v), null, JSON.stringify(v));
});

test('buildAppleAppSiteAssociation: yeni (appIDs + components) ve eski (appID + paths) iOS bicimi birlikte, birebir', () => {
  assert.equal(JSON.stringify(buildAppleAppSiteAssociation(TEAM)), aasaBody(TEAM));
});

test('buildAppLinkDocuments: ortam yoksa yalnizca assetlinks (varsayilan parmak izi), AASA yok, uyari yok', () => {
  for (const env of [undefined, {}, { ANDROID_APP_LINK_CERT_SHA256: '', APPLE_TEAM_ID: '' }, { APPLE_TEAM_ID: '   ' }]) {
    const docs = buildAppLinkDocuments(env);
    assert.equal(docs.assetLinks, assetLinksBody([RELEASE_FP]), JSON.stringify(env));
    assert.equal(docs.appleAppSiteAssociation, null, JSON.stringify(env));
    assert.deepEqual(docs.warnings, [], JSON.stringify(env));
  }
});

test('buildAppLinkDocuments: gecerli ek parmak izi + APPLE_TEAM_ID -> iki govde, uyari yok', () => {
  const docs = buildAppLinkDocuments({ ANDROID_APP_LINK_CERT_SHA256: EXTRA_FP.toLowerCase(), APPLE_TEAM_ID: TEAM });
  assert.equal(docs.assetLinks, assetLinksBody([RELEASE_FP, EXTRA_FP]));
  assert.equal(docs.appleAppSiteAssociation, aasaBody(TEAM));
  assert.deepEqual(docs.warnings, []);
});

test('buildAppLinkDocuments: gecersiz degerler atlanir; her degisken icin TEK uyari metni (deger dahil, kontrol karakteri kacisli)', () => {
  const docs = buildAppLinkDocuments({ ANDROID_APP_LINK_CERT_SHA256: `bozuk-1, ${EXTRA_FP}, bozuk\n2`, APPLE_TEAM_ID: 'kisa' });
  assert.equal(docs.assetLinks, assetLinksBody([RELEASE_FP, EXTRA_FP]));
  assert.equal(docs.appleAppSiteAssociation, null);
  assert.equal(docs.warnings.length, 2);
  const [fpWarning, teamWarning] = docs.warnings;
  assert.match(fpWarning, /ANDROID_APP_LINK_CERT_SHA256/);
  assert.ok(fpWarning.includes('bozuk-1'), fpWarning);
  assert.ok(fpWarning.includes('bozuk\\n2'), fpWarning);
  assert.ok(!fpWarning.includes(EXTRA_FP), 'gecerli deger uyarida yer almaz');
  assert.match(teamWarning, /APPLE_TEAM_ID/);
  assert.ok(teamWarning.includes('kisa'), teamWarning);
  for (const w of docs.warnings) assert.ok(!/[\r\n]/.test(w), 'uyari tek satir olmali');
});
