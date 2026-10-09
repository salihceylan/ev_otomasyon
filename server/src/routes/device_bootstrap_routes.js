'use strict';

// ==============================================================================
// AHBU Akilli Ev - Pano bootstrap rotasi (CONTRACTS bolum 3f). Mount: /api/v1 ve /api
// ==============================================================================
//
//   POST /devices/bootstrap   {device_uuid, ts, nonce, fw?, sig}   JWT YOK (pano yerel anahtariyla imzalar)
//
// Oran siniri (bellek ici, surec basina): kart basina saatte 20, IP basina saatte 60; asimda 429 RATE_LIMITED (+Retry-After).
// IP butcesine ONCE bakilir (dolmussa kart butcesine ve servise gidilmez: kart kimligini degistirerek asilamaz); IP
// butcesini YALNIZ basarisiz istekler harcar (sonuc 200/202 DEGILSE; sozlesme C7, sozlesme-1): ortak NAT arkasinda 10 dk'da
// bir 202 alan cok sayida sahiplenilmemis pano, sahiplenilen panonun bootstrap'ini kilitleyemez. Kart butcesini YALNIZ
// imzasi dogrulanan (401 olmayan) istekler harcar (bireysel-6): sahte istekler gercek kartin hakkini tuketip onu
// kilitleyemez; kart butcesi panonun dogal yoklamasindan (30 dk / bekleyen sahiplenmede daha sik) genis tutulur.
// Yanit govdesi servisin urettigi gibi HAM yazilir (200 {status,mqtt} / 202 {status} / 401 sabit govde); servis hatasi
// global yakalayiciya gider (500). Bu router `/api/v1/devices` altindaki device_routes'tan ONCE baglanir.

const express = require('express');
const { asyncHandler } = require('../middlewares/error_handler');
const { noStore } = require('./route_helpers');
const { HttpError } = require('../utils/helpers');

const HOUR = 60 * 60 * 1000;
const PER_DEVICE_PER_HOUR = 20;
const PER_IP_PER_HOUR = 60;

function deviceKey(req) {
  const b = req.body && typeof req.body === 'object' && !Array.isArray(req.body) ? req.body : {};
  const u = typeof b.device_uuid === 'string' ? b.device_uuid.trim().toUpperCase().slice(0, 64) : '';
  return u || 'invalid';
}

function createRouter(deps = {}) {
  const rateLimitFactory = deps.rateLimit || require('../middlewares/rate_limit');
  const { clientIp } = require('../middlewares/rate_limit');
  const svc = deps.bootstrapService || require('../services/device_bootstrap_service');

  const router = express.Router();
  const ipLimiter = rateLimitFactory({
    windowMs: HOUR,
    max: PER_IP_PER_HOUR,
    code: 'RATE_LIMITED',
    keyGenerator: (req) => `bootstrap-ip:${clientIp(req)}`,
  });
  const deviceLimiter = rateLimitFactory({
    windowMs: HOUR,
    max: PER_DEVICE_PER_HOUR,
    code: 'RATE_LIMITED',
    keyGenerator: (req) => `bootstrap-dev:${deviceKey(req)}`,
  });

  const tooMany = (s) => {
    const err = new HttpError(429, `Çok fazla istek gönderildi. Lütfen ${s.retryAfter} saniye sonra tekrar deneyin.`, 'RATE_LIMITED');
    err.retryAfter = s.retryAfter;
    return err;
  };

  router.post(
    '/devices/bootstrap',
    asyncHandler(async (req, res) => {
      // IP butcesi (sozlesme C7): once bakilir (dolmussa kart butcesine ve servise gidilmez); yalniz basarisiz istek harcar.
      const ipKey = `bootstrap-ip:${clientIp(req)}`;
      const ipState = ipLimiter.peek(ipKey);
      if (!ipState.allowed) throw tooMany(ipState);
      let succeeded = false;
      try {
        // Kart butcesi (bireysel-6): once bakilir (dolmussa servis cagrilmaz), YALNIZ dogrulanmis istekte harcanir.
        const k = `bootstrap-dev:${deviceKey(req)}`;
        const s = deviceLimiter.peek(k);
        if (!s.allowed) throw tooMany(s);
        const body = req.body && typeof req.body === 'object' && !Array.isArray(req.body) ? req.body : {};
        const result = await svc.bootstrap({ body, ip: clientIp(req) });
        if (result.http !== 401) deviceLimiter.consume(k);
        succeeded = result.http === 200 || result.http === 202;
        noStore(res); // 200 yaniti MQTT parolasi tasir
        return res.status(result.http).json(result.body);
      } finally {
        if (!succeeded) ipLimiter.consume(ipKey);
      }
    })
  );

  router.limiters = { ipLimiter, deviceLimiter };
  return router;
}

module.exports = createRouter();
module.exports.createRouter = createRouter;
