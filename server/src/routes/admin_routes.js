'use strict';

// ==============================================================================
// AHBU Akilli Ev - Super Yonetici & Servis Yonetimi uclari (WP-A: A7)
// Mount: /api/v1/admin (+ eski /api/admin)
// ==============================================================================
// Tum uclar JWT + global rol service_user | super_user (servis PIN oturumu HARIC).
// Ayrintili kapsam / koruma kurallari services/admin_user_service.js icindedir.

const express = require('express');
const adminUserService = require('../services/admin_user_service');
const { authenticateToken, requireRoot, requireServiceManager } = require('../middlewares/auth_middleware');
const serviceScopeService = require('../services/service_scope_service');
const { rateLimit } = require('../middlewares/rate_limit');
const { asyncHandler } = require('../middlewares/error_handler');
const { successResponse } = require('../utils/helpers');

const router = express.Router();

router.use(authenticateToken);
router.use(requireServiceManager);

const resetLimiter = rateLimit({
  windowMs: 60 * 60 * 1000,
  max: 20,
  keyGenerator: (req) => `admin-reset:${req.user && req.user.id ? req.user.id : 'anon'}`,
});

router.get('/users', asyncHandler(async (req, res) => {
  const { role, search, is_active, limit, offset } = req.query || {};
  const result = await adminUserService.listUsers({ role, search, is_active, limit, offset, currentUser: req.user });
  return successResponse(res, result);
}));

router.post('/users', asyncHandler(async (req, res) => {
  const b = req.body || {};
  const user = await adminUserService.createUser({
    full_name: b.full_name || b.fullName,
    email: b.email,
    password: b.password,
    phone: b.phone,
    role: b.role || 'user',
    admin_notes: b.admin_notes || b.adminNotes,
    currentUser: req.user,
  });
  res.setHeader('Cache-Control', 'no-store');
  return successResponse(res, user, `${user.full_name} (${user.role}) sisteme kaydedildi.`, 201);
}));

router.get('/users/:id', asyncHandler(async (req, res) => {
  const result = await adminUserService.getUserById(req.params.id, { currentUser: req.user });
  return successResponse(res, result);
}));

router.patch('/users/:id', asyncHandler(async (req, res) => {
  const b = req.body || {};
  const updated = await adminUserService.updateUser(req.params.id, {
    full_name: b.full_name !== undefined ? b.full_name : b.fullName,
    phone: b.phone,
    role: b.role,
    password: b.password,
    current_password: b.current_password !== undefined ? b.current_password : b.currentPassword,
    is_active: b.is_active !== undefined ? b.is_active : b.isActive,
    admin_notes: b.admin_notes !== undefined ? b.admin_notes : b.adminNotes,
    currentUser: req.user,
  });
  return successResponse(res, updated, 'Kullanıcı bilgileri güncellendi.');
}));

// Sifirlama / hesap etkinlestirme baglantisi (staff parola belirleyemez; bunu tetikler)
router.post('/users/:id/send-reset', resetLimiter, asyncHandler(async (req, res) => {
  const result = await adminUserService.sendPasswordReset(req.params.id, { currentUser: req.user });
  return successResponse(res, result, 'Sıfırlama bağlantısı gönderildi.');
}));

router.delete('/users/:id', asyncHandler(async (req, res) => {
  const result = await adminUserService.deleteUser(req.params.id, {
    currentUser: req.user,
    hardDelete: req.query && req.query.hard === 'true',
  });
  return successResponse(res, null, result.message);
}));

// KOK-YALNIZ (servis sorumlusu 403): butun sistemin ozeti
router.get('/service-summary', requireRoot, asyncHandler(async (req, res) => {
  const summary = await adminUserService.getServiceSummary();
  return successResponse(res, summary);
}));

// --- KAPSAMLAR ARASI AKTARIM (KOK-YALNIZ; servis sorumlusu 403) -----------------------------------------------------
// Govde: { service_user_id: "<uuid>" | null }  (null = kok kapsamina al). Alan ZORUNLU.
const hasServiceUserField = (b) => Object.prototype.hasOwnProperty.call(b, 'service_user_id') || Object.prototype.hasOwnProperty.call(b, 'serviceUserId');
const serviceUserOf = (b) => (hasServiceUserField(b) ? (b.service_user_id !== undefined ? b.service_user_id : b.serviceUserId) : undefined);
const rootActor = (req) => ({ userId: req.user.id, role: 'super_user', type: 'super_user', ip: req.ip || null });

router.patch('/homes/:homeId/service-owner', requireRoot, asyncHandler(async (req, res) => {
  const b = req.body && typeof req.body === 'object' ? req.body : {};
  const result = await serviceScopeService.transferHome({ homeId: req.params.homeId, serviceUserId: serviceUserOf(b), actor: rootActor(req) });
  return successResponse(res, result, result.message);
}));

router.patch('/sites/:siteId/service-owner', requireRoot, asyncHandler(async (req, res) => {
  const b = req.body && typeof req.body === 'object' ? req.body : {};
  const result = await serviceScopeService.transferSite({ siteId: req.params.siteId, serviceUserId: serviceUserOf(b), actor: rootActor(req) });
  return successResponse(res, result, result.message);
}));

module.exports = router;
