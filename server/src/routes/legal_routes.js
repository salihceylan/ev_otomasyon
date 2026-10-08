'use strict';

// ==============================================================================
// AHBU Akilli Ev - Yasal metin uclari (belgeler ve kabul: services/legal_service.js, migration 039)
// ==============================================================================
// Mount (server.js): createLegalRouter -> '/api/v1' ve '/api' (router YOL ONEKI EKLEMEZ). router.use YOK: '/api'
// altina da baglandigi icin kimlik HER ROUTE'TA ayri uygulanir (push_routes / invitation_routes ile ayni gerekce).
// Sayfa: app.get(['/yasal', '/yasal/:slug', '/yasal/*'], createLegalPageHandler(...)).
//
//   GET  /yasal/:slug     kimliksiz HTML sayfa. 200 'public, max-age=300'; bilinmeyen slug (ve slug'siz '/yasal',
//                         ic ice yol) 404 HTML 'no-store' (tarayiciya JSON degil).
//                         Cerez ve betik yok; CSP stili yalniz SHA-256 ozetiyle izinler; istekten hicbir deger yansimaz.
//   GET  /legal           kimliksiz: data.documents [{id, slug, title, version, effective_date, status,
//                         requires_acceptance, url:"/yasal/<slug>"}], sira terms -> privacy; belge yoksa bos liste
//   GET  /legal/:id       kimliksiz: tek belge + blocks (id: terms | privacy ya da slug); yoksa 404 NOT_FOUND
//   POST /legal/accept    kullanici JWT; servis (PIN) oturumu 403 FORBIDDEN. Govde {document:"terms", version:N}
//                         -> 200 {document, version, accepted_at}. Bilinmeyen ya da onay istemeyen belge (privacy) ve
//                         bozuk surum 400 VALIDATION; guncel olmayan surum 409 LEGAL_VERSION_MISMATCH
//                         (data.current_version). Son kabul ayni surumse yeni kayit yazilmaz (200, ayni accepted_at).
// JSON yanitlari 'no-store': surum degisince istemci eski surumu onbellekten onaylayip 409 dongusune girmesin.
// Hiz siniri: okuma IP basina 600 / 15 dk (GET /auth/capabilities ile ayni), kabul kullanici basina 30 / 15 dk.

const express = require('express');
const { authenticateToken: defaultAuthenticateToken, rejectServiceSession } = require('../middlewares/auth_middleware');
const { rateLimit, clientIp, limitKey } = require('../middlewares/rate_limit');
const { asyncHandler } = require('../middlewares/error_handler');
const { successResponse, HttpError } = require('../utils/helpers');
const { PAGE_CSP } = require('../utils/legal_markdown');

const MIN = 60 * 1000;
const PAGE_CACHE_CONTROL = 'public, max-age=300';

/** Ilk dolu alan (snake_case; CONTRACTS §0: gecis doneminde esdeger adlar da kabul). */
function pick(body, keys) {
  if (!body || typeof body !== 'object' || Array.isArray(body)) return undefined;
  for (const k of keys) {
    if (body[k] !== undefined && body[k] !== null && body[k] !== '') return body[k];
  }
  return undefined;
}

function noStore(req, res, next) {
  res.setHeader('Cache-Control', 'no-store');
  next();
}

/**
 * @param {{legal:object, authenticateToken?:Function}} deps  authenticateToken yalniz testte degistirilir
 * @returns {express.Router} `router.limiters` = { read, accept }
 */
function createLegalRouter({ legal, authenticateToken = defaultAuthenticateToken } = {}) {
  if (!legal) throw new TypeError('createLegalRouter: legal servisi zorunludur.');
  const router = express.Router();
  const limiters = {
    read: rateLimit({ windowMs: 15 * MIN, max: 600, keyGenerator: (req) => `legal-read:${limitKey(req)}` }),
    accept: rateLimit({
      windowMs: 15 * MIN,
      max: 30,
      keyGenerator: (req) => `legal-accept:${req.user && req.user.id ? req.user.id : limitKey(req)}`,
    }),
  };

  router.get('/legal', noStore, limiters.read, (req, res) => successResponse(res, { documents: legal.listDocuments() }));

  // Sira: kimlik -> servis oturumu reddi -> kullanici basina sayac (anahtar kullanici olsun).
  router.post('/legal/accept', noStore, authenticateToken, rejectServiceSession, limiters.accept, asyncHandler(async (req, res) => {
    const result = await legal.accept({
      userId: req.user.id,
      document: pick(req.body, ['document', 'id', 'slug']),
      version: pick(req.body, ['version']),
      ip: clientIp(req),
      userAgent: req.get('user-agent'),
    });
    return successResponse(res, result, 'Onayınız kaydedildi.');
  }));

  router.get('/legal/:id', noStore, limiters.read, (req, res, next) => {
    const doc = legal.getDocument(req.params.id);
    if (!doc) return next(new HttpError(404, 'Yasal belge bulunamadı.', 'NOT_FOUND'));
    return successResponse(res, doc);
  });

  router.limiters = limiters;
  return router;
}

/** GET /yasal/:slug isleyicisi (sayfa yuklemede bir kez uretilir; istekten deger yansitilmaz). */
function createLegalPageHandler({ legal } = {}) {
  if (!legal) throw new TypeError('createLegalPageHandler: legal servisi zorunludur.');
  return function legalPage(req, res) {
    const page = legal.getPage(String(req.params.slug || ''));
    res.setHeader('Cache-Control', page.status === 200 ? PAGE_CACHE_CONTROL : 'no-store');
    res.setHeader('Content-Security-Policy', PAGE_CSP);
    res.setHeader('Referrer-Policy', 'no-referrer');
    res.setHeader('X-Content-Type-Options', 'nosniff');
    res.setHeader('Content-Type', 'text/html; charset=utf-8');
    return res.status(page.status).send(page.html);
  };
}

module.exports = { createLegalRouter, createLegalPageHandler, PAGE_CACHE_CONTROL };
