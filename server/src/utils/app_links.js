'use strict';

// ==============================================================================
// Uygulama baglantisi dogrulama dosyalari: Android App Links + iOS Universal Links (2026-10-09)
// ==============================================================================
// Saf fonksiyonlar (G/C ve gunluk YOK; ortam nesnesini cagiran verir). server.js createApp aninda govdeleri BIR KEZ
// uretir, donen uyarilari bir kez loglar ve kimliksiz sunar:
//   GET /.well-known/assetlinks.json              Google Digital Asset Links (her zaman)
//   GET /.well-known/apple-app-site-association   Apple AASA (yalniz APPLE_TEAM_ID gecerliyse; aksi JSON 404)
//   GET /apple-app-site-association               eski iOS konumu, ayni govde
// Ortam:
//   ANDROID_APP_LINK_CERT_SHA256  virgullu EK SHA-256 imza parmak izleri (or. Google Play uygulama imzalama anahtari).
//                                 Depodaki surum anahtari parmak izi HER ZAMAN ilk siradadir. Bicim: 32 bayt, iki nokta
//                                 ayrimli onaltilik; buyuk harfe normalize, gecersiz atlanir, tekrar ayiklanir. Parmak
//                                 izi gizli DEGILDIR: uyari gecersiz degeri yazar.
//   APPLE_TEAM_ID                 Apple Developer Team ID, 10 karakter [A-Z0-9]. Yoksa / gecersizse AASA yayinlanmaz.
// Yollar Android manifestindeki autoVerify intent-filter'i (pathPrefix /claim, /reset-password, /magic-login) ile aynidir.

const ANDROID_PACKAGE_NAME = 'com.ahbu.evotomasyon.ev_otomasyon';
const IOS_BUNDLE_ID = 'com.ahbu.evotomasyon.evOtomasyon';
// Yeni surum imza (yukleme) anahtari. Google Play uygulama imzalama kullanilirsa onun parmak izi ortamdan EK verilir.
const DEFAULT_ANDROID_CERT_SHA256 = Object.freeze([
  'C9:58:0E:1D:E0:39:09:0C:B5:9B:71:B6:EA:F9:58:2A:F2:97:5C:CB:92:2B:8D:BA:77:C1:58:87:E1:AC:E0:8F',
]);
const APP_LINK_PATHS = Object.freeze(['/claim', '/reset-password', '/magic-login']);

const CERT_SHA256 = /^[0-9A-F]{2}(?::[0-9A-F]{2}){31}$/;
const TEAM_ID = /^[A-Z0-9]{10}$/;

/**
 * SHA-256 imza parmak izini kanonik bicime getirir.
 * @param {unknown} value
 * @returns {string|null} "AA:BB:..." (32 bayt, buyuk harf) ya da gecersizse null
 */
function normalizeCertSha256(value) {
  if (typeof value !== 'string') return null;
  const v = value.trim().toUpperCase();
  return CERT_SHA256.test(v) ? v : null;
}

/**
 * Yayinlanacak parmak izleri: depodaki varsayilan + ortamdaki gecerli ekler (sira korunur, tekrar yok).
 * @param {unknown} raw ANDROID_APP_LINK_CERT_SHA256 (virgullu)
 * @returns {{fingerprints: string[], invalid: string[]}} invalid: atlanan ham degerler (kirpilmis)
 */
function resolveAndroidCertFingerprints(raw) {
  const fingerprints = [...DEFAULT_ANDROID_CERT_SHA256];
  const invalid = [];
  for (const entry of typeof raw === 'string' ? raw.split(',') : []) {
    const trimmed = entry.trim();
    if (!trimmed) continue;
    const fp = normalizeCertSha256(trimmed);
    if (!fp) invalid.push(trimmed);
    else if (!fingerprints.includes(fp)) fingerprints.push(fp);
  }
  return { fingerprints, invalid };
}

/** Google Digital Asset Links bildirimi (assetlinks.json govdesi). */
function buildAssetLinks(fingerprints) {
  return [
    {
      relation: ['delegate_permission/common.handle_all_urls'],
      target: {
        namespace: 'android_app',
        package_name: ANDROID_PACKAGE_NAME,
        sha256_cert_fingerprints: [...fingerprints],
      },
    },
  ];
}

/**
 * @param {unknown} value
 * @returns {string|null} 10 karakter [A-Z0-9] Team ID ya da null (kucuk harf DUZELTILMEZ, gecersiz sayilir)
 */
function normalizeAppleTeamId(value) {
  if (typeof value !== 'string') return null;
  const v = value.trim();
  return TEAM_ID.test(v) ? v : null;
}

/** apple-app-site-association: yeni (iOS 13+: appIDs + components) ve eski (appID + paths) bicim birlikte. */
function buildAppleAppSiteAssociation(teamId) {
  const appId = `${teamId}.${IOS_BUNDLE_ID}`;
  const patterns = APP_LINK_PATHS.map((p) => `${p}*`);
  return {
    applinks: {
      apps: [],
      details: [
        {
          appIDs: [appId],
          components: patterns.map((p) => ({ '/': p })),
          appID: appId,
          paths: patterns,
        },
      ],
    },
  };
}

/**
 * Ortamdan iki dogrulama dosyasinin JSON govdelerini uretir. Gunluk YAZMAZ: uyari metinlerini doner (cagiran bir kez
 * loglar; degisken basina en fazla bir uyari). Degerler JSON.stringify ile yazilir: kontrol karakterleri kacisli, tek satir.
 * @param {Record<string, string|undefined>} [env]
 * @returns {{assetLinks: string, appleAppSiteAssociation: string|null, warnings: string[]}}
 */
function buildAppLinkDocuments(env = {}) {
  const source = env || {};
  const warnings = [];

  const { fingerprints, invalid } = resolveAndroidCertFingerprints(source.ANDROID_APP_LINK_CERT_SHA256);
  if (invalid.length > 0) {
    warnings.push(
      `ANDROID_APP_LINK_CERT_SHA256: ${invalid.length} gecersiz parmak izi atlandi (32 bayt, iki nokta ayrimli onaltilik ` +
        `bekleniyor): ${invalid.map((v) => JSON.stringify(v)).join(', ')}`,
    );
  }

  const rawTeam = typeof source.APPLE_TEAM_ID === 'string' ? source.APPLE_TEAM_ID.trim() : '';
  const teamId = normalizeAppleTeamId(rawTeam);
  if (rawTeam && !teamId) {
    warnings.push(
      `APPLE_TEAM_ID gecersiz (10 karakter A-Z / 0-9 bekleniyor): ${JSON.stringify(rawTeam)}; ` +
        'apple-app-site-association yayinlanmadi (404).',
    );
  }

  return {
    assetLinks: JSON.stringify(buildAssetLinks(fingerprints)),
    appleAppSiteAssociation: teamId ? JSON.stringify(buildAppleAppSiteAssociation(teamId)) : null,
    warnings,
  };
}

module.exports = {
  ANDROID_PACKAGE_NAME,
  IOS_BUNDLE_ID,
  DEFAULT_ANDROID_CERT_SHA256,
  APP_LINK_PATHS,
  normalizeCertSha256,
  resolveAndroidCertFingerprints,
  buildAssetLinks,
  normalizeAppleTeamId,
  buildAppleAppSiteAssociation,
  buildAppLinkDocuments,
};
