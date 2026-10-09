'use strict';

// ==============================================================================
// AHBU Akilli Ev & Bina Otomasyonu - API sunucusu (WP-A: A2)
// ==============================================================================
//
// Acilis kurallari (fail-closed):
//   - DATABASE_URL yoksa db.js yuklenmez (sunucu baslamaz).
//   - JWT_SECRET yoksa / 32 karakterden kisaysa sunucu BASLAMAZ.
//   - PIN_PEPPER yoksa / 32 karakterden kisaysa sunucu BASLAMAZ.
//   - LOCAL_KEY_SECRET (utils/secret_box) yoksa / gecersizse sunucu BASLAMAZ.
//
// Ag:
//   - BIND_HOST (varsayilan 127.0.0.1): yalnizca yerel vekil (nginx) erisir.
//   - trust proxy (TRUST_PROXY, varsayilan 'loopback'): req.ip yalnizca guvenilen vekil zincirinden.
//   - CORS_ORIGINS (virgullu): bossa tarayici kokenleri REDDEDILIR; Origin basligi olmayan
//     (mobil) istemciler etkilenmez.
//   - Govde siniri 256 KB; helmet guvenlik basliklari.
//
// Surec saglamligi (plan §5d-5; PM2/systemd yeniden baslatmaya guvenir):
//   - unhandledRejection / uncaughtException: yigin izi + maskelenmis mesaj (utils/fatal_log; sir/jeton/PIN/govde YOK).
//     uncaughtException: zarif kapanis + cikis kodu 1 (sureci yoneten yeniden baslatir). unhandledRejection: yalniz log.
//   - SIGTERM/SIGINT: sirali kapanis -> HTTP (dinlemeyi birak, bosta baglantilari kapat, surenleri sinirli bekle,
//     sonra kes) -> zamanlayici + gece hatirlatmasi -> MQTT kimlik temizligi -> MQTT koprusu -> pg havuzu.
//     Her adim kendi zaman asimina sahiptir (takilan adim sonrakini engellemez); TOPLAM 10 sn, sonra zorla cikis.
//   - Surec yoneticisi bekleme suresini >= 12 sn tutmalidir (PM2 kill_timeout 12000 / systemd TimeoutStopSec=15);
//     PM2 varsayilani 1600 ms'dir ve zarif kapanisi yarida keser.
//
// Testler createApp() ile uygulamayi dinlemeden olusturur (supertest).

require('dotenv').config();

const express = require('express');
const cors = require('cors');
const helmet = require('helmet');

const { assertJwtConfig } = require('./middlewares/jwt_config');
const { assertPinConfig } = require('./utils/pin');
const { authenticateToken } = require('./middlewares/auth_middleware');
const { errorHandler, notFoundHandler, asyncHandler } = require('./middlewares/error_handler');
const { rejectNulBytes } = require('./middlewares/reject_nul');
const { successResponse } = require('./utils/helpers');
const { describeFatal, redactSensitive } = require('./utils/fatal_log');
const { buildAppLinkDocuments } = require('./utils/app_links');

const BODY_LIMIT = '256kb';
// Zarif kapanis zaman butcesi (plan §5d-5). Havuz/baglanti zaman asimi degerleri (db.js) burada DEGISTIRILMEZ.
const SHUTDOWN_TIMEOUT_MS = 10 * 1000; // toplam sinir; asilirsa zorla cikis
const HTTP_DRAIN_MS = 3 * 1000; // suren isteklerin bitmesi icin azami bekleme; sonra baglantilar kesilir
const STEP_TIMEOUT_MS = 2500; // tek bir kapanis adimi (zamanlayici / MQTT / pg) icin azami bekleme
const IDLE_SWEEP_MS = 100; // kapanista bosta kalan keep-alive baglantilarini kapatma araligi
const SERVICE_NAME = 'AHBU Ev Otomasyonu Backend API';
const VERSION = '1.1.0';

// bireysel-9: uygulama baglantisi tarayicida acilinca gosterilen STATIK sayfa (istekten hicbir deger yansitilmaz).
const APP_LINK_TEXT =
  'Bu bağlantı AHBU uygulamasında açılmalıdır. Etiketteki karekodu uygulamadaki Karekod Tara ile okutun; uygulama ' +
  'yüklü değilse önce yükleyin. Şifre sıfırlama ya da giriş bağlantısıysa uygulama yüklü telefonda bağlantıya ' +
  'yeniden dokunun.';
const APP_LINK_PAGE =
  '<!doctype html><html lang="tr"><head><meta charset="utf-8">' +
  '<meta name="viewport" content="width=device-width, initial-scale=1"><meta name="referrer" content="no-referrer">' +
  '<title>AHBU Akıllı Ev</title></head>' +
  '<body style="margin:0;font-family:system-ui,-apple-system,Segoe UI,Roboto,sans-serif;background:#f4f6f8;color:#1b2430">' +
  '<main style="max-width:32rem;margin:12vh auto;padding:1.5rem;background:#fff;border-radius:12px;' +
  'box-shadow:0 1px 4px rgba(0,0,0,.08);line-height:1.5">' +
  '<h1 style="font-size:1.25rem;margin:0 0 .75rem">AHBU Akıllı Ev</h1>' +
  `<p style="margin:0">${APP_LINK_TEXT}</p>` +
  '</main></body></html>';

/**
 * Modul varsa yukler, yoksa null doner (B/C paketlerinin dosyalari henuz olmayabilir).
 * Modul VAR ama icinde hata varsa hata yukari tasinir (sessizce yutulmaz).
 */
function optionalRequire(specifier, label) {
  let resolved;
  try {
    resolved = require.resolve(specifier);
  } catch (_) {
    console.warn(`[SERVER] ${label || specifier} bulunamadi; atlandi.`);
    return null;
  }
  return require(resolved);
}

function csv(value) {
  return String(value || '')
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean);
}

function parseTrustProxy(raw) {
  if (raw === undefined || raw === null || String(raw).trim() === '') return 'loopback';
  const v = String(raw).trim();
  if (v === 'false' || v === '0') return false;
  if (/^\d+$/.test(v)) return Number(v);
  return v; // ornegin "loopback, 10.0.0.0/8"
}

/** Acilista zorunlu yapilandirma denetimi. Eksikse HATA firlatir (sunucu baslamaz). */
function validateConfig() {
  assertJwtConfig();
  assertPinConfig();
  const secretBox = optionalRequire('./utils/secret_box', 'utils/secret_box');
  if (secretBox && typeof secretBox.isConfigured === 'function' && !secretBox.isConfigured()) {
    throw new Error('[CONFIG] LOCAL_KEY_SECRET tanımlı değil veya geçersiz (32 bayt = 64 hex). Sunucu başlatılmadı.');
  }
  const adminKey = process.env.ADMIN_API_KEY;
  if (adminKey && adminKey.length < 32) {
    console.warn('[CONFIG] ADMIN_API_KEY 32 karakterden kisa; API anahtari yolu KAPALI.');
  }
  if (process.env.ALLOW_DEBUG_OTP === 'true' && process.env.NODE_ENV === 'production') {
    console.warn('[CONFIG] ALLOW_DEBUG_OTP uretimde YOK SAYILIR.');
  }
  return true;
}

function corsMiddleware() {
  const allowed = new Set(csv(process.env.CORS_ORIGINS));
  const corsHandler = cors({
    origin: (origin, cb) => cb(null, Boolean(origin) && allowed.has(origin)),
    methods: ['GET', 'POST', 'PUT', 'PATCH', 'DELETE'],
    allowedHeaders: ['Authorization', 'Content-Type'],
    maxAge: 600,
    credentials: false,
  });
  return function originGate(req, res, next) {
    const origin = req.headers.origin;
    // Mobil istemciler Origin gondermez: etkilenmez.
    if (origin && !allowed.has(origin)) {
      return res.status(403).json({ success: false, message: 'İzin verilmeyen kaynak (origin).', code: 'FORBIDDEN' });
    }
    return corsHandler(req, res, next);
  };
}

/**
 * Uygulama baglantisi dogrulama dosyasi isleyicisi (assetlinks.json / apple-app-site-association): onceden uretilmis
 * JSON, Content-Type tam olarak `application/json` (Buffer gonderilir: Express charset eklemez), herkese acik onbellek
 * 1 sa, nosniff. HEAD istegini Express ayni GET rotasiyla karsilar (govdesiz, ayni basliklar).
 */
function wellKnownJson(json) {
  const payload = Buffer.from(json, 'utf8');
  return function sendWellKnownJson(req, res) {
    res.setHeader('Cache-Control', 'public, max-age=3600');
    res.setHeader('X-Content-Type-Options', 'nosniff');
    res.setHeader('Content-Type', 'application/json');
    return res.status(200).send(payload);
  };
}

/**
 * Express uygulamasini olusturur (dinlemez).
 * @param {{db?:object, mqttBridge?:object, pushService?:object, legalService?:object}} [deps]
 *   legalService: services/legal_service ornegi (varsayilan: server/legal dizini; testler kendi belgelerini verir)
 */
function createApp(deps = {}) {
  const db = deps.db || require('./db');
  const mqttBridge = deps.mqttBridge || require('./mqtt_bridge');

  const authRoutes = require('./routes/auth_routes');
  const serviceRoutes = require('./routes/service_routes');
  const servicePanelRoutes = require('./routes/service_panel_routes');
  const joinPreviewRoutes = require('./routes/join_preview_routes');
  const adminRoutes = require('./routes/admin_routes');
  const inventoryRoutes = require('./routes/inventory_routes');
  const invitationRoutes = require('./routes/invitation_routes');
  const transferRoutes = require('./routes/transfer_routes');
  const siteTemplateRoutes = require('./routes/site_template_routes');
  const deviceBootstrapRoutes = require('./routes/device_bootstrap_routes');
  const authService = require('./services/auth_service');

  // WP-B / WP-C rotalari (dosya yoksa mount atlanir).
  const deviceRoutes = optionalRequire('./routes/device_routes', 'routes/device_routes');
  const endpointRoutes = optionalRequire('./routes/endpoint_routes', 'routes/endpoint_routes');
  const mqttRoutes = optionalRequire('./routes/mqtt_routes', 'routes/mqtt_routes');
  const homeDeviceRoutes = optionalRequire('./routes/home_device_routes', 'routes/home_device_routes');
  const scheduledRulesRoutes = optionalRequire('./routes/scheduled_rules_routes', 'routes/scheduled_rules_routes');
  const safetyRoutes = optionalRequire('./routes/safety_routes', 'routes/safety_routes'); // WP-S4: alarm/eylemci

  const app = express();
  app.disable('x-powered-by');
  app.set('trust proxy', parseTrustProxy(process.env.TRUST_PROXY));

  app.use(helmet({
    contentSecurityPolicy: { directives: { defaultSrc: ["'none'"], frameAncestors: ["'none'"] } },
    crossOriginResourcePolicy: { policy: 'same-site' },
  }));
  app.use(corsMiddleware());
  // Kapanis sirasinda (start().shutdown) yanitlar baglantiyi kapatir: keep-alive baglantilari kapanisi geciktirmesin.
  // Kapanis baslamadan ONCE gelip suren istekler icin de gecerlidir (baslik, yanit yazilirken denetlenir).
  app.use((req, res, next) => {
    if (app.locals.shuttingDown === true) {
      res.setHeader('Connection', 'close');
    } else {
      const writeHead = res.writeHead;
      res.writeHead = function writeHeadDuringShutdown(...args) {
        if (app.locals.shuttingDown === true && !this.headersSent) this.setHeader('Connection', 'close');
        return writeHead.apply(this, args);
      };
    }
    next();
  });
  app.use(express.json({ limit: BODY_LIMIT }));
  // NUL (\u0000) iceren metin PostgreSQL'de 22021 -> 500 olur; tek noktadan 400'e cevrilir (govde, sorgu, yol).
  app.use(rejectNulBytes);

  // --- Saglik ---------------------------------------------------------------
  // Canlilik: yalnizca surec ayakta mi (ic hata metni / bilesen ayrintisi YOK).
  app.get('/health', (req, res) => {
    res.setHeader('Cache-Control', 'no-store');
    return res.status(200).json({ status: 'ok', service: SERVICE_NAME, version: VERSION, timestamp: new Date().toISOString() });
  });

  // Hazirlik: veritabani ve MQTT koprusu (yalnizca up/down; hata metni YOK).
  app.get('/ready', async (req, res) => {
    res.setHeader('Cache-Control', 'no-store');
    let database = 'down';
    try {
      const r = await db.query('SELECT 1 AS ok');
      if (r && r.rows && r.rows.length > 0) database = 'up';
    } catch (_) {
      database = 'down';
    }
    let mqtt = 'down';
    try {
      mqtt = mqttBridge && typeof mqttBridge.isConnected === 'function' && mqttBridge.isConnected() ? 'up' : 'down';
    } catch (_) {
      mqtt = 'down';
    }
    const draining = app.locals.shuttingDown === true; // kapaniyor: yeni trafik almamali
    const ready = database === 'up' && !draining;
    return res.status(ready ? 200 : 503).json({
      status: ready ? 'ready' : (draining ? 'shutting_down' : 'not_ready'),
      components: { database, mqtt_bridge: mqtt },
      timestamp: new Date().toISOString(),
    });
  });

  // --- Kimlik ---------------------------------------------------------------
  app.use('/api/v1/auth', authRoutes);
  app.use('/api/auth', authRoutes);

  // --- Yasal metinler (migration 039; belgeler server/legal/<slug>.md) -------
  // Okuma kimliksiz, kabul kullanici JWT'si; kimlik route bazli (router.use YOK). '/api/v1' altindaki diger
  // yonlendiricilerden ONCE baglanir. Ayni ornek auth_service'e verilir (publicUser.legal); sayfa '/yasal/:slug'
  // asagida. Eksik / gecersiz belge sunucuyu durdurmaz (liste bos, needs_acceptance false).
  const { createLegalService } = require('./services/legal_service');
  const { createLegalRouter, createLegalPageHandler } = require('./routes/legal_routes');
  const legalService = deps.legalService || createLegalService({ db });
  app.locals.legalService = legalService;
  if (typeof authService.setLegalService === 'function') authService.setLegalService(legalService);
  const legalRouter = createLegalRouter({ legal: legalService });
  app.locals.legalRouter = legalRouter;
  app.use('/api/v1', legalRouter);
  app.use('/api', legalRouter);

  // --- Ev listesi (GET /api/v1/homes ve eski /api/homes) ---------------------
  const handleGetHomes = asyncHandler(async (req, res) => {
    res.setHeader('Cache-Control', 'no-store');
    const result = await authService.getProfile(req.user);
    return successResponse(res, result.homes);
  });
  app.get('/api/v1/homes', authenticateToken, handleGetHomes);
  app.get('/api/homes', authenticateToken, handleGetHomes);

  // --- WP-A: davet ve devir (route bazli kimlik; '/homes/join' ve '/homes/transfer-accept'
  //     ev-kapsamli '/homes/:homeId' router'larindan ONCE baglanir ki 'join' bir homeId sanilmasin)
  app.use('/api/v1', invitationRoutes);
  app.use('/api', invitationRoutes);
  app.use('/api/v1', transferRoutes);
  app.use('/api', transferRoutes);
  // --- WP-B2: davet/devir kodu onizleme (POST /homes/join-preview; kodu tuketmez; kimlik route bazli) ---
  app.use('/api/v1', joinPreviewRoutes);
  app.use('/api', joinPreviewRoutes);

  // --- WP-H: push belirteci (PUT|DELETE /me/push-tokens). Router yol oneki eklemez; kimlik her route'ta ayri.
  //     pushService app.locals'ta tutulur: start() ayni ornegi gece hatirlatmasina verir.
  const { createPushService } = require('./services/push_service');
  const { createPushRouter } = require('./routes/push_routes');
  const pushService = deps.pushService || createPushService({ db });
  app.locals.pushService = pushService;
  // Push belirteci gizliligi (plan §5d-1): oturumlar toplu iptal edilince (logout-all, parola degisimi/sifirlama,
  // dondurma/rol iptali, sosyal baglama) auth_service ayni ornekle belirtecleri devre disi birakir.
  if (typeof authService.setPushService === 'function') authService.setPushService(pushService);
  const pushRouter = createPushRouter({ pushService, authenticateToken });
  app.use('/api/v1', pushRouter);
  app.use('/api', pushRouter);

  // --- WP-B: cihaz / komut / MQTT kimlik -----------------------------------
  // mqtt_routes ve home_device_routes yollari '/:homeId/...' bicimindedir -> '/api/v1/homes' altina
  // baglanir (CONTRACTS §1.5: POST /api/v1/homes/:homeId/mqtt-credentials). Modul `mountPaths`
  // disa aciyorsa o kullanilir. home_device_routes, serviceRoutes'tan ONCE baglanir.
  const HOME_MOUNTS = ['/api/v1/homes', '/api/homes'];
  const mountsOf = (router) => (Array.isArray(router.mountPaths) && router.mountPaths.length > 0 ? router.mountPaths : HOME_MOUNTS);
  if (mqttRoutes) {
    for (const p of mountsOf(mqttRoutes)) app.use(p, mqttRoutes);
  }
  if (homeDeviceRoutes) {
    for (const p of mountsOf(homeDeviceRoutes)) app.use(p, homeDeviceRoutes);
  }
  // --- WP-S4: guvenlik (alarm listesi/onayi, eylemci, bolge testi); serviceRoutes'tan ONCE
  if (safetyRoutes) {
    for (const p of mountsOf(safetyRoutes)) app.use(p, safetyRoutes);
  }
  // --- CONTRACTS 3f: pano bootstrap (POST /devices/bootstrap; JWT YOK, imzali). device_routes'tan ONCE baglanir.
  app.use('/api/v1', deviceBootstrapRoutes);
  app.use('/api', deviceBootstrapRoutes);
  if (deviceRoutes) {
    app.use('/api/v1/devices', deviceRoutes);
    app.use('/api/devices', deviceRoutes);
  }
  if (endpointRoutes) {
    app.use('/api/v1/homes/:home_id/endpoints', endpointRoutes);
    app.use('/api/homes/:home_id/endpoints', endpointRoutes);
  }

  // --- WP-C: zamanli kurallar ----------------------------------------------
  if (scheduledRulesRoutes) {
    for (const p of mountsOf(scheduledRulesRoutes)) app.use(p, scheduledRulesRoutes);
  }

  // --- WP-A: ev bazli servis erisimi ve yonetim ------------------------------
  app.use('/api/v1/homes/:home_id', serviceRoutes);
  app.use('/api/homes/:home_id', serviceRoutes);
  // --- WP-B2: servis paneli (abone listesi + Home Admin atama); staff/super, kimlik route bazli ---
  app.use('/api/v1/service', servicePanelRoutes);
  app.use('/api/service', servicePanelRoutes);
  // --- Faz 1 (CONTRACTS §3e): site / daire / kurulum sablonu / yazim kaydi / envanter yerel anahtari. Yollar tam
  //     (/sites, /templates, /template-writes, /admin/inventory/:uuid/local-key); kimlik route bazli (router.use YOK).
  //     inventoryRoutes / adminRoutes'tan ONCE baglanir (GET /admin/inventory/:uuid/local-key burada karsilanir).
  app.use('/api/v1', siteTemplateRoutes);
  app.use('/api', siteTemplateRoutes);
  app.use('/api/v1/admin/inventory', inventoryRoutes);
  app.use('/api/admin/inventory', inventoryRoutes);
  app.use('/api/v1/admin', adminRoutes);
  app.use('/api/admin', adminRoutes);

  // --- Uygulama baglantilari tarayicida (bireysel-9) -------------------------
  // Etiket karekodu (/claim?uid=&pin=), sifre sifirlama ve sihirli giris baglantilari telefon kamerasiyla/tarayicida
  // acilirsa JSON 404 yerine statik yonlendirme sayfasi doner. Sorgu dizgesi / yol YANSITILMAZ (PIN/belirtec sayfaya
  // ve onbellege dusmez); oturum ACILMAZ, hicbir sey tuketilmez. GET /api/v1/auth/magic-login/:token 405 AYNEN kalir.
  app.get(['/claim', '/reset-password', '/magic-login', '/magic-login/:token'], (req, res) => {
    res.setHeader('Cache-Control', 'no-store');
    res.setHeader('Referrer-Policy', 'no-referrer');
    res.setHeader('Content-Security-Policy', "default-src 'none'; style-src 'unsafe-inline'");
    res.setHeader('X-Content-Type-Options', 'nosniff');
    res.setHeader('Content-Type', 'text/html; charset=utf-8');
    return res.status(200).send(APP_LINK_PAGE);
  });

  // --- Uygulama baglantisi dogrulama dosyalari (Android App Links / iOS Universal Links) --------------------------
  // Google (Digital Asset Links) ve Apple (CDN) dogrulayicilari bu dosyalari kimliksiz ve yonlendirmesiz ceker: JWT /
  // hiz siniri YOK, dogrudan 200 application/json (HEAD de). Govdeler burada ortamdan BIR KEZ uretilir (utils/app_links;
  // gecersiz deger kurulumda bir kez uyari); ortam degisince sunucu yeniden baslatilir. APPLE_TEAM_ID yoksa / gecersizse
  // AASA yollari BAGLANMAZ ve notFoundHandler'a duser (JSON 404 aynen).
  const appLinkDocs = buildAppLinkDocuments(process.env);
  for (const warning of appLinkDocs.warnings) console.warn(`[APP-LINKS] ${warning}`);
  app.get('/.well-known/assetlinks.json', wellKnownJson(appLinkDocs.assetLinks));
  if (appLinkDocs.appleAppSiteAssociation) {
    app.get(['/.well-known/apple-app-site-association', '/apple-app-site-association'], wellKnownJson(appLinkDocs.appleAppSiteAssociation));
  }

  // --- Yasal metin sayfalari (kimliksiz; public, max-age=300; bilinmeyen slug 404 HTML) ------------------------------
  // '/yasal', '/yasal/' ve ic ice yollar da tarayiciya JSON degil 404 HTML sayfasi doner (slug yok -> bulunamadi).
  app.get(['/yasal', '/yasal/:slug', '/yasal/*'], createLegalPageHandler({ legal: legalService }));

  // --- 404 + global hata yakalayici -----------------------------------------
  app.use(notFoundHandler);
  app.use(errorHandler);

  return app;
}

function positiveMs(value, fallback) {
  return Number.isFinite(value) && value > 0 ? value : fallback;
}

/**
 * HTTP sunucusunu kapatir: dinlemeyi birakir, bosta kalan keep-alive baglantilarini DUZENLI araliklarla kapatir
 * (Node yalniz close() aninda bosta olanlari kapatir: o anda mesgul olan baglanti isi bitince acik kalir ve
 * close geri cagrisini keepAliveTimeout'a, yani 65 sn'ye kadar geciktirirdi) ve `drainMs` sonra kalanlari keser.
 * @returns {Promise<void>} sunucu tamamen kapaninca (veya sure dolup baglantilar kesilince) cozulur; asla reddetmez
 */
function closeHttpServer(server, drainMs) {
  return new Promise((resolve) => {
    let finished = false;
    let sweep = null;
    let cut = null;
    const finish = () => {
      if (finished) return;
      finished = true;
      if (sweep) clearInterval(sweep);
      if (cut) clearTimeout(cut);
      resolve();
    };
    const closeIdle = () => {
      try {
        if (typeof server.closeIdleConnections === 'function') server.closeIdleConnections();
      } catch (_) {
        /* yut */
      }
    };
    try {
      server.close(finish); // dinlemeyi birakir; son baglanti kapaninca (ya da sunucu zaten kapaliysa) geri cagri
    } catch (_) {
      finish();
      return;
    }
    closeIdle();
    // Bu zamanlayicilar unref: surecin acik kalmasini yalnizca shutdown()'in (unref edilmeyen) zorla-cikis zamanlayicisi belirler.
    sweep = setInterval(closeIdle, IDLE_SWEEP_MS);
    if (typeof sweep.unref === 'function') sweep.unref();
    cut = setTimeout(() => {
      try {
        if (typeof server.closeAllConnections === 'function') server.closeAllConnections();
      } catch (_) {
        /* yut */
      }
      const grace = setTimeout(finish, 200); // kesilen soketlerin close olayi icin kisa pay; sonra her halde devam
      if (typeof grace.unref === 'function') grace.unref();
    }, drainMs);
    if (typeof cut.unref === 'function') cut.unref();
  });
}

/** Tek kapanis adimi: hata yutulur ve loglanir; `timeoutMs` icinde bitmezse sonraki adima gecilir. */
async function runShutdownStep(name, fn, timeoutMs) {
  let timer = null;
  try {
    await Promise.race([
      Promise.resolve().then(fn),
      new Promise((resolve) => {
        timer = setTimeout(() => {
          console.error(`[SERVER] Kapanis adimi zaman asimina ugradi (${name}); sonraki adima geciliyor.`);
          resolve();
        }, timeoutMs);
        if (typeof timer.unref === 'function') timer.unref();
      }),
    ]);
  } catch (err) {
    console.error(`[SERVER] Kapanis adimi basarisiz (${name}): ${redactSensitive(err && err.message)}`);
  } finally {
    if (timer) clearTimeout(timer);
  }
}

/** Surec duzeyi hata gunlugu: ASLA firlatmaz (log hatasi kapanisi engellemesin). */
function logFatal(tag, reason, meta) {
  try {
    console.error(describeFatal(tag, reason, meta));
  } catch (_) {
    try {
      console.error(`[${tag}] (gunluk yazilamadi)`);
    } catch (__) {
      /* yut */
    }
  }
}

/**
 * Sunucuyu baslatir: yapilandirma denetimi -> dinleme -> MQTT koprusu -> zamanlayici.
 * @param {{shutdownTimeoutMs?:number, httpDrainMs?:number, stepTimeoutMs?:number}} [options]  yalnizca testler zaman butcesini kisaltir
 * @returns {{ app, server, shutdown: Function }}
 */
function start(options = {}) {
  validateConfig();
  const totalMs = positiveMs(options.shutdownTimeoutMs, SHUTDOWN_TIMEOUT_MS);
  const drainMs = positiveMs(options.httpDrainMs, HTTP_DRAIN_MS);
  const stepMs = positiveMs(options.stepTimeoutMs, STEP_TIMEOUT_MS);

  const db = require('./db');
  const mqttBridge = require('./mqtt_bridge');
  const app = createApp({ db, mqttBridge });

  const port = Number(process.env.PORT || 5000);
  const host = process.env.BIND_HOST || '127.0.0.1';

  const server = app.listen(port, host, () => {
    console.log('==================================================');
    console.log(`  AHBU Akilli Ev API Sunucusu Calisiyor (${host}:${port})`);
    console.log('==================================================');
  });
  server.headersTimeout = 20 * 1000;
  server.requestTimeout = 30 * 1000;
  server.keepAliveTimeout = 65 * 1000;

  // Yasal metinler acilista bir kez yuklenir: eksik / gecersiz belge HEMEN loglanir (load() firlatmaz; sunucu baslar).
  try {
    if (app.locals.legalService && typeof app.locals.legalService.load === 'function') app.locals.legalService.load();
  } catch (err) {
    console.error('[SERVER] Yasal metinler yuklenemedi:', err && err.message);
  }

  // MQTT koprusu. Guvenlik alarm push'u (WP-S3) icin ayni push servisi kopruye enjekte edilir (gece hatirlatmasiyla ortak).
  if (typeof mqttBridge.setPushService === 'function') mqttBridge.setPushService(app.locals.pushService);
  try {
    mqttBridge.init();
  } catch (err) {
    console.error('[SERVER] MQTT koprusu baslatilamadi:', err && err.message);
  }

  // Suresi dolan uygulama MQTT kimliklerinin temizligi (WP-B)
  const mqttCredentialService = optionalRequire('./services/mqtt_credential_service', 'services/mqtt_credential_service');
  if (mqttCredentialService && typeof mqttCredentialService.startCleanup === 'function') {
    try {
      mqttCredentialService.startCleanup();
    } catch (err) {
      console.error('[SERVER] MQTT kimlik temizligi baslatilamadi:', err && err.message);
    }
  }

  // pano-6: yerel anahtari okumus servis oturumu bitince evin anahtari bekleyen yolla doner (5 dk'da bir, unref'li)
  const serviceTokenService = optionalRequire('./services/service_token_service', 'services/service_token_service');
  if (serviceTokenService && typeof serviceTokenService.startSweeper === 'function') {
    try {
      serviceTokenService.startSweeper();
    } catch (err) {
      console.error('[SERVER] Servis oturumu supurucusu baslatilamadi:', err && err.message);
    }
  }

  // Zamanli kural motoru (WP-C: scheduler.start({ mqttBridge, db }))
  let scheduler = null;
  try {
    scheduler = optionalRequire('./scheduler', 'scheduler');
    if (scheduler && typeof scheduler.start === 'function') {
      scheduler.start({ mqttBridge, db });
      console.log('  Zamanli kural motoru aktif.');
    } else {
      console.warn('  [UYARI] scheduler bulunamadi; zamanli kurallar PASIF.');
    }
  } catch (err) {
    console.error('  [UYARI] Zamanli kural motoru baslatilamadi; zamanli kurallar PASIF:', err && err.message);
    scheduler = null;
  }

  // Gece hatirlatmasi (WP-H): KENDI try/catch'i icinde; migration 030 henuz uygulanmadiysa ya da push
  // yapilandirmasi yoksa sunucu etkilenmez (hatirlatma kendini kapatir/yeniden dener, uygulama ici yedek calisir).
  let peaceReminder = null;
  const peaceOptions = { db, push: app.locals.pushService };
  try {
    peaceReminder = require('./peace_reminder').start(peaceOptions);
  } catch (err) {
    console.error('  [UYARI] Gece hatirlatmasi baslatilamadi (hatirlatma PASIF):', err && err.message);
    peaceReminder = null;
  }

  let shuttingDown = false;
  async function shutdown(signal, exitCode = 0) {
    if (shuttingDown) return;
    shuttingDown = true;
    app.locals.shuttingDown = true; // /ready 503 + yanitlar "Connection: close"
    if (exitCode) process.exitCode = exitCode; // zarif yol yarida kalsa da cikis kodu korunur
    console.log(`[SERVER] Kapaniyor (${signal})...`);
    // Zorla cikis zamanlayicisi UNREF EDILMEZ: olay dongusu bosalip surec, process.exit(1) cagrilmadan kod 0 ile
    // sessizce bitmesin (uncaughtException -> cikis kodu 1 garantisi).
    const force = setTimeout(() => {
      console.error('[SERVER] Zarif kapanis zaman asimina ugradi; zorla cikiliyor.');
      process.exit(exitCode || 1);
    }, totalMs);

    // 1) HTTP: dinlemeyi birak, bosta baglantilari kapat, suren istekleri sinirli bekle (sonra kes)
    await closeHttpServer(server, drainMs);
    // 2) Zamanlayici + gece hatirlatmasi: yeni tur planlanmaz, calisan tur sinirli beklenir (bagimsiz: paralel)
    await Promise.all([
      runShutdownStep('scheduler', async () => { if (scheduler && typeof scheduler.stop === 'function') await scheduler.stop(); }, stepMs),
      runShutdownStep('peace-reminder', async () => { if (peaceReminder && typeof peaceReminder.stop === 'function') await peaceReminder.stop(); }, stepMs),
    ]);
    // 3) MQTT kimlik temizligi, MQTT koprusu (zamanlayicilar + baglanti), en sonda pg havuzu
    await runShutdownStep('mqtt-cred-cleanup', async () => { if (mqttCredentialService && typeof mqttCredentialService.stopCleanup === 'function') mqttCredentialService.stopCleanup(); }, stepMs);
    await runShutdownStep('service-session-sweep', async () => { if (serviceTokenService && typeof serviceTokenService.stopSweeper === 'function') serviceTokenService.stopSweeper(); }, stepMs);
    await runShutdownStep('mqtt', async () => { if (typeof mqttBridge.end === 'function') await mqttBridge.end({ timeoutMs: Math.max(300, stepMs - 300) }); }, stepMs);
    await runShutdownStep('db', async () => { if (db.pool && typeof db.pool.end === 'function') await db.pool.end(); }, stepMs);
    clearTimeout(force);
    console.log('[SERVER] Kapandi.');
    process.exit(exitCode);
  }

  const onSignal = (signal) => () => {
    shutdown(signal).catch(() => process.exit(1));
  };
  process.on('SIGTERM', onSignal('SIGTERM'));
  process.on('SIGINT', onSignal('SIGINT'));
  // unhandledRejection: yalniz log (surec durumu bozulmadi; beklenmeyen durumlari operator gorur).
  process.on('unhandledRejection', (reason) => {
    logFatal('UNHANDLED-REJECTION', reason);
  });
  // uncaughtException: surec durumu belirsiz -> zarif kapanip cikis kodu 1 (sureci yoneten yeniden baslatir).
  process.on('uncaughtException', (err, origin) => {
    logFatal('UNCAUGHT-EXCEPTION', err, { origin });
    shutdown('uncaughtException', 1).catch(() => process.exit(1));
  });

  return { app, server, shutdown };
}

if (require.main === module) {
  try {
    start();
  } catch (err) {
    console.error('[SERVER] Baslatma hatasi:', err && err.message ? err.message : err);
    process.exit(1);
  }
}

module.exports = { createApp, start, validateConfig, parseTrustProxy, closeHttpServer, runShutdownStep };
