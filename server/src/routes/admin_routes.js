'use strict';

// ==============================================================================
// AHBU Akıllı Ev & Bina Otomasyonu - Süper Yönetici & Servis Yönetimi Rotaları
// ==============================================================================

const express = require('express');
const router = express.Router();
const adminUserService = require('../services/admin_user_service');
const {
  authenticateToken,
  requireSuperUser,
  requireServiceManager,
} = require('../middlewares/auth_middleware');

// Tüm admin rotaları oturum (JWT) ve en az Servis Yöneticisi / Süper Kullanıcı rolü gerektirir
router.use(authenticateToken);
router.use(requireServiceManager);

/**
 * @route   GET /api/admin/users
 * @desc    Kullanıcıları filtreleme (rol, arama, aktiflik) ile listeler
 */
router.get('/users', async (req, res, next) => {
  try {
    const { role, search, is_active, limit, offset } = req.query;
    const result = await adminUserService.listUsers({
      role,
      search,
      is_active,
      limit: limit ? parseInt(limit, 10) : 50,
      offset: offset ? parseInt(offset, 10) : 0,
      currentUser: req.user,
    });

    res.json({
      success: true,
      data: result,
    });
  } catch (err) {
    next(err);
  }
});

/**
 * @route   POST /api/admin/users
 * @desc    Yeni kullanıcı (Süper Kullanıcı, Servis Sorumlusu, Daire Kullanıcısı) oluşturur
 */
router.post('/users', async (req, res, next) => {
  try {
    const { full_name, email, password, phone, role, admin_notes } = req.body;
    const user = await adminUserService.createUser({
      full_name,
      email,
      password,
      phone,
      role: role || 'user',
      admin_notes,
      currentUser: req.user,
    });

    res.status(201).json({
      success: true,
      message: `${user.full_name} (${user.role}) başarıyla sisteme kaydedildi.`,
      data: user,
    });
  } catch (err) {
    next(err);
  }
});

/**
 * @route   GET /api/admin/users/:id
 * @desc    Kullanıcı detayını (bağlı evler, servis logları) getirir
 */
router.get('/users/:id', async (req, res, next) => {
  try {
    const result = await adminUserService.getUserById(req.params.id);
    res.json({
      success: true,
      data: result,
    });
  } catch (err) {
    next(err);
  }
});

/**
 * @route   PATCH /api/admin/users/:id
 * @desc    Kullanıcı bilgilerini, rolünü veya şifresini günceller
 */
router.patch('/users/:id', async (req, res, next) => {
  try {
    const { full_name, phone, role, password, is_active, admin_notes } = req.body;
    const updated = await adminUserService.updateUser(req.params.id, {
      full_name,
      phone,
      role,
      password,
      is_active,
      admin_notes,
      currentUser: req.user,
    });

    res.json({
      success: true,
      message: 'Kullanıcı bilgileri başarıyla güncellendi.',
      data: updated,
    });
  } catch (err) {
    next(err);
  }
});

/**
 * @route   DELETE /api/admin/users/:id
 * @desc    Kullanıcıyı pasife alır veya kalıcı siler
 */
router.delete('/users/:id', async (req, res, next) => {
  try {
    const hardDelete = req.query.hard === 'true';
    const result = await adminUserService.deleteUser(req.params.id, {
      currentUser: req.user,
      hardDelete,
    });

    res.json({
      success: true,
      message: result.message,
    });
  } catch (err) {
    next(err);
  }
});

/**
 * @route   GET /api/admin/service-summary
 * @desc    Sistem ve servis özet istatistiklerini getirir (Sadece Süper Kullanıcı)
 */
router.get('/service-summary', requireSuperUser, async (req, res, next) => {
  try {
    const summary = await adminUserService.getServiceSummary();
    res.json({
      success: true,
      data: summary,
    });
  } catch (err) {
    next(err);
  }
});

module.exports = router;
