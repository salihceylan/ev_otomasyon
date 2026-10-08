'use strict';

// ==============================================================================
// AHBU Akilli Ev - Site / daire / kurulum sablonu / yazim kaydi rotalari (Faz 1, CONTRACTS §3e). Mount: /api/v1 ve /api
// ==============================================================================
//
//   GET    /sites                                   site listesi (+ flat_stats)
//   POST   /sites                                   site olustur
//   GET    /sites/:siteId                           site
//   PATCH  /sites/:siteId                           site guncelle
//   DELETE /sites/:siteId                           yumusak silme (dairesine kart bagliysa 409 SITE_HAS_DEVICES)
//   GET    /sites/:siteId/flats                     daireler (+ last_write)
//   POST   /sites/:siteId/flats/bulk                {block, from, to, flat_type?, template_id?}
//   PATCH  /sites/:siteId/flats/:flatId             {flat_type, template_id, status, block, number} (durum yalniz ileri)
//   DELETE /sites/:siteId/flats/:flatId
//   PUT    /sites/:siteId/flats/:flatId/device      {device_uuid} | {device_uuid:null}
//   GET    /templates?site_id=&include_global=1      (site_id yoksa yalniz genel sablonlar)
//   POST   /templates                               {site_id, body} -> sablon + surum 1
//   POST   /templates/validate                      {body} -> {ok:true} | 422 TEMPLATE_INVALID {error, path}
//   GET    /templates/:id                           guncel surum + body
//   PUT    /templates/:id                           {body, base_version?} -> yeni surum (ayni govde: created:false;
//                                                    eski base_version + farkli govde: 409 TEMPLATE_CHANGED)
//   DELETE /templates/:id                           yumusak
//   GET    /templates/:id/versions                  surum listesi
//   GET    /templates/:id/versions/:version         surum govdesi
//   POST   /template-writes                         karta yazim kaydi (via usb | eth | lan)
//   GET    /admin/inventory/:uuid/local-key         Ethernet yazimi icin yerel anahtar (denetim kaydi + oran siniri)
//
// YETKI: HER uc authenticateToken + requireServiceManager (global rol service_user | super_user; servis PIN oturumu,
// ev sahibi, sakin, misafir 403). Kimlik HER ROUTE'TA ayri uygulanir (router.use YOK): router `/api` altina da
// baglandigi icin router.use kendisine ait olmayan isteklere de 401 donerdi.

const express = require('express');
const { asyncHandler } = require('../middlewares/error_handler');
const { successResponse } = require('../utils/helpers');
const { actorOf, clientIp, noStore } = require('./route_helpers');

const HOUR = 60 * 60 * 1000;
const LOCAL_KEY_MAX_PER_HOUR = 60;

function truthy(v) {
  return v === '1' || v === 'true' || v === true;
}

function createRouter(deps = {}) {
  const auth = deps.auth || require('../middlewares/auth_middleware');
  const rateLimitFactory = deps.rateLimit || require('../middlewares/rate_limit');
  const svc = deps.siteTemplateService || require('../services/site_template_service');
  const { authenticateToken, requireServiceManager } = auth;

  const router = express.Router();
  const guard = [authenticateToken, requireServiceManager];

  const userKey = (req) => (req.user && req.user.id) || clientIp(req) || 'anon';
  const localKeyLimiter = rateLimitFactory({
    windowMs: HOUR,
    max: Number.isFinite(deps.localKeyMax) ? deps.localKeyMax : LOCAL_KEY_MAX_PER_HOUR,
    code: 'RATE_LIMITED',
    keyGenerator: (req) => `tpl-local-key:${userKey(req)}`,
  });

  const body = (req) => (req.body && typeof req.body === 'object' ? req.body : {});

  // --- Siteler -----------------------------------------------------------------
  router.get('/sites', ...guard, asyncHandler(async (req, res) => {
    noStore(res); // iletisim bilgisi icerir
    return successResponse(res, await svc.listSites());
  }));

  router.post('/sites', ...guard, asyncHandler(async (req, res) => {
    const site = await svc.createSite(actorOf(req), body(req));
    return successResponse(res, site, 'Site oluşturuldu.', 201);
  }));

  router.get('/sites/:siteId', ...guard, asyncHandler(async (req, res) => {
    noStore(res);
    return successResponse(res, await svc.getSite(req.params.siteId));
  }));

  router.patch('/sites/:siteId', ...guard, asyncHandler(async (req, res) => {
    return successResponse(res, await svc.updateSite(req.params.siteId, body(req)), 'Site güncellendi.');
  }));

  router.delete('/sites/:siteId', ...guard, asyncHandler(async (req, res) => {
    return successResponse(res, await svc.deleteSite(req.params.siteId), 'Site silindi.');
  }));

  // --- Daireler ----------------------------------------------------------------
  router.get('/sites/:siteId/flats', ...guard, asyncHandler(async (req, res) => {
    return successResponse(res, await svc.listFlats(req.params.siteId));
  }));

  router.post('/sites/:siteId/flats/bulk', ...guard, asyncHandler(async (req, res) => {
    const result = await svc.bulkCreateFlats(req.params.siteId, body(req));
    return successResponse(res, result, 'Daireler oluşturuldu.', 201);
  }));

  router.patch('/sites/:siteId/flats/:flatId', ...guard, asyncHandler(async (req, res) => {
    return successResponse(res, await svc.updateFlat(req.params.siteId, req.params.flatId, body(req), actorOf(req)), 'Daire güncellendi.');
  }));

  router.delete('/sites/:siteId/flats/:flatId', ...guard, asyncHandler(async (req, res) => {
    return successResponse(res, await svc.deleteFlat(req.params.siteId, req.params.flatId), 'Daire silindi.');
  }));

  router.put('/sites/:siteId/flats/:flatId/device', ...guard, asyncHandler(async (req, res) => {
    const b = body(req);
    const deviceUuid = Object.prototype.hasOwnProperty.call(b, 'device_uuid') ? b.device_uuid : undefined;
    const flat = await svc.linkFlatDevice(req.params.siteId, req.params.flatId, deviceUuid, actorOf(req));
    return successResponse(res, flat, deviceUuid ? 'Kart daireye bağlandı.' : 'Kart bağlantısı kaldırıldı.');
  }));

  // --- Sablonlar ---------------------------------------------------------------
  router.get('/templates', ...guard, asyncHandler(async (req, res) => {
    const q = req.query || {};
    const list = await svc.listTemplates({ siteId: q.site_id, includeGlobal: truthy(q.include_global) });
    return successResponse(res, list);
  }));

  router.post('/templates', ...guard, asyncHandler(async (req, res) => {
    const tpl = await svc.createTemplate(actorOf(req), body(req));
    return successResponse(res, tpl, 'Şablon oluşturuldu (sürüm 1).', 201);
  }));

  // '/templates/validate' POST'u '/templates/:id' ile cakismaz (o yolda POST yok); yine de once tanimlanir.
  router.post('/templates/validate', ...guard, asyncHandler(async (req, res) => {
    return successResponse(res, await svc.validate(body(req)), 'Şablon geçerli.');
  }));

  router.get('/templates/:id', ...guard, asyncHandler(async (req, res) => {
    return successResponse(res, await svc.getTemplate(req.params.id));
  }));

  router.put('/templates/:id', ...guard, asyncHandler(async (req, res) => {
    const tpl = await svc.updateTemplate(actorOf(req), req.params.id, body(req));
    const message = tpl && tpl.created === false ? 'Şablon değişmedi; mevcut sürüm korundu.' : 'Şablonun yeni sürümü kaydedildi.';
    return successResponse(res, tpl, message);
  }));

  router.delete('/templates/:id', ...guard, asyncHandler(async (req, res) => {
    return successResponse(res, await svc.deleteTemplate(req.params.id), 'Şablon silindi.');
  }));

  router.get('/templates/:id/versions', ...guard, asyncHandler(async (req, res) => {
    return successResponse(res, await svc.listVersions(req.params.id));
  }));

  router.get('/templates/:id/versions/:version', ...guard, asyncHandler(async (req, res) => {
    return successResponse(res, await svc.getVersion(req.params.id, req.params.version));
  }));

  // --- Karta yazim kaydi -------------------------------------------------------
  router.post('/template-writes', ...guard, asyncHandler(async (req, res) => {
    const row = await svc.recordWrite(actorOf(req), body(req));
    return successResponse(res, row, 'Yazım kaydedildi.', 201);
  }));

  // --- Yerel anahtar (Ethernet yazimi, K-S4) -----------------------------------
  router.get('/admin/inventory/:uuid/local-key', ...guard, localKeyLimiter, asyncHandler(async (req, res) => {
    const result = await svc.getInventoryLocalKey(actorOf(req), req.params.uuid);
    noStore(res);
    return successResponse(res, result);
  }));

  router.limiters = { localKeyLimiter };
  return router;
}

module.exports = createRouter();
module.exports.createRouter = createRouter;
