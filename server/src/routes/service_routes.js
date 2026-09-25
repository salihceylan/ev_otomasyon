const express = require('express');
const router = express.Router({ mergeParams: true });
const serviceTokenService = require('../services/service_token_service');
const { authenticateToken, requireHomeAccess } = require('../middlewares/auth_middleware');
const { successResponse, errorResponse } = require('../utils/helpers');
const db = require('../db');

// FAZ 4 - Adım 4.3: Ev sahibinin 2 saat geçerli yetkili servis PIN'i üretmesi
// POST /api/homes/:home_id/service-token
router.post('/service-token', authenticateToken, requireHomeAccess(['owner']), async (req, res) => {
  try {
    const result = await serviceTokenService.createServiceToken(req.user.id, req.params.home_id);
    return successResponse(res, result, 'Gecici servis PIN kodu olusturuldu.', 201);
  } catch (err) {
    return errorResponse(res, err.message, err.statusCode || 500);
  }
});

// GET /api/homes/:home_id/service-tokens (Aktif ve Geçmiş Servis PIN'lerini Listele)
router.get('/service-tokens', authenticateToken, requireHomeAccess(['owner']), async (req, res) => {
  try {
    const listRes = await db.query(
      `SELECT st.id, st.service_pin, st.expires_at, st.is_used, st.created_at, u.full_name as created_by_name
       FROM service_tokens st
       JOIN users u ON st.created_by = u.id
       WHERE st.home_id = $1
       ORDER BY st.created_at DESC
       LIMIT 10`,
      [req.params.home_id]
    );
    return successResponse(res, listRes.rows);
  } catch (err) {
    return errorResponse(res, err.message, 500);
  }
});

// POST /api/homes/:home_id/commissioning
// ADIM 11: Yetkili Servis Sorumlusunun sistemi test edip "Çalışır" olarak onaylaması (Commissioning)
router.post('/commissioning', authenticateToken, requireHomeAccess(['service_user']), async (req, res) => {
  try {
    const { notes, tests_passed = true } = req.body;
    const homeId = req.params.home_id;
    const technicianId = req.user.id;

    // 1. Dairedeki cihazı güncelle
    const updateRes = await db.query(
      `UPDATE devices 
       SET is_commissioned = TRUE, 
           commissioned_at = CURRENT_TIMESTAMP, 
           commissioned_by = $1, 
           commissioning_status = 'APPROVED_WORKING',
           commissioning_notes = $2
       WHERE home_id = $3
       RETURNING id, device_uuid, is_commissioned, commissioning_status, commissioned_at`,
      [technicianId, notes || 'Sistem yetkili servis sorumlusu tarafından test edildi ve onaylandı.', homeId]
    );

    // 2. Devreye alma günlüğüne ekle
    await db.query(
      `INSERT INTO commissioning_logs (home_id, device_id, technician_id, tests_passed, notes)
       VALUES ($1, $2, $3, $4, $5)`,
      [homeId, updateRes.rows[0] ? updateRes.rows[0].id : null, technicianId, tests_passed, notes || 'Başarılı test']
    );

    return successResponse(
      res,
      {
        commissioned: true,
        status: 'APPROVED_WORKING',
        technician: req.user.full_name || req.user.email,
        commissioned_at: new Date().toISOString(),
        device: updateRes.rows[0] || null,
      },
      'Sistem başarıyla test edildi ve "ÇALIŞIR" olarak onaylandı.'
    );
  } catch (err) {
    return errorResponse(res, err.message, 500);
  }
});

// GET /api/homes/:home_id/commissioning-status
router.get('/commissioning-status', authenticateToken, requireHomeAccess(['owner', 'service_user', 'super_user']), async (req, res) => {
  try {
    const homeId = req.params.home_id;
    const resDb = await db.query(
      `SELECT d.is_commissioned, d.commissioned_at, d.commissioning_status, d.commissioning_notes, u.full_name as technician_name
       FROM devices d
       LEFT JOIN users u ON d.commissioned_by = u.id
       WHERE d.home_id = $1
       LIMIT 1`,
      [homeId]
    );

    if (resDb.rows.length === 0) {
      return successResponse(res, { is_commissioned: false, status: 'NO_DEVICE' });
    }

    return successResponse(res, resDb.rows[0]);
  } catch (err) {
    return errorResponse(res, err.message, 500);
  }
});

module.exports = router;
