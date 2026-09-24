'use strict';

const express = require('express');
const router = express.Router({ mergeParams: true });
const { authenticateToken } = require('../middlewares/auth_middleware');
const svc = require('../services/scheduled_rules_service');
const db = require('../db');

/**
 * Kullanıcının bu home'a yetkisi var mı ve admin mi kontrol et
 */
async function requireHomeAdmin(req, res, next) {
  try {
    const homeId = req.params.homeId || req.params.home_id || req.body.home_id || req.body.homeId;
    if (!homeId) return res.status(400).json({ error: 'home_id gerekli' });

    const memberRes = await db.query(
      `SELECT role FROM home_users WHERE home_id = $1 AND user_id = $2`,
      [homeId, req.user.id]
    );
    if (memberRes.rows.length === 0) {
      return res.status(403).json({ error: 'Bu eve erişim yetkiniz yok' });
    }
    const role = memberRes.rows[0].role;
    if (role !== 'admin' && role !== 'owner') {
      return res.status(403).json({ error: 'Sadece ev yöneticisi kural yönetebilir' });
    }
    req.homeId = homeId;
    req.memberRole = role;
    next();
  } catch (err) {
    console.error('[ScheduledRules] requireHomeAdmin error:', err);
    res.status(500).json({ error: 'Yetki kontrol hatası' });
  }
}

/**
 * Kullanıcının bu home'a üye mi kontrol et (okuma için)
 */
async function requireHomeMember(req, res, next) {
  try {
    const homeId = req.params.homeId || req.params.home_id || req.query.home_id;
    if (!homeId) return res.status(400).json({ error: 'home_id gerekli' });

    const memberRes = await db.query(
      `SELECT role FROM home_users WHERE home_id = $1 AND user_id = $2`,
      [homeId, req.user.id]
    );
    if (memberRes.rows.length === 0) {
      return res.status(403).json({ error: 'Bu eve erişim yetkiniz yok' });
    }
    req.homeId = homeId;
    req.memberRole = memberRes.rows[0].role;
    next();
  } catch (err) {
    console.error('[ScheduledRules] requireHomeMember error:', err);
    res.status(500).json({ error: 'Yetki kontrol hatası' });
  }
}

// GET /api/homes/:homeId/scheduled-rules — Kuralları listele
router.get('/:homeId/scheduled-rules', authenticateToken, requireHomeMember, async (req, res) => {
  try {
    const rules = await svc.listRules(req.homeId);
    res.json({ rules });
  } catch (err) {
    console.error('[ScheduledRules] LIST error:', err);
    res.status(500).json({ error: 'Kurallar alınamadı' });
  }
});

// POST /api/homes/:homeId/scheduled-rules — Yeni kural ekle
router.post('/:homeId/scheduled-rules', authenticateToken, requireHomeAdmin, async (req, res) => {
  try {
    const homeId = req.homeId;
    const { deviceId, channel, channelType, action, hour, minute, daysOfWeek, label } = req.body;
    if (channel === undefined || action === undefined || hour === undefined || minute === undefined) {
      return res.status(400).json({ error: 'channel, action, hour, minute zorunlu' });
    }

    const rule = await svc.createRule(homeId, req.user.id, {
      deviceId,
      channel: parseInt(channel),
      channelType,
      action,
      hour: parseInt(hour),
      minute: parseInt(minute),
      daysOfWeek,
      label,
    });
    res.status(201).json({ rule });
  } catch (err) {
    console.error('[ScheduledRules] CREATE error:', err);
    res.status(400).json({ error: err.message });
  }
});

// PUT /api/homes/:homeId/scheduled-rules/:ruleId — Kural güncelle
router.put('/:homeId/scheduled-rules/:ruleId', authenticateToken, requireHomeAdmin, async (req, res) => {
  try {
    const ruleId = parseInt(req.params.ruleId);
    const rule = await svc.updateRule(ruleId, req.homeId, req.body);
    res.json({ rule });
  } catch (err) {
    console.error('[ScheduledRules] UPDATE error:', err);
    res.status(400).json({ error: err.message });
  }
});

// DELETE /api/homes/:homeId/scheduled-rules/:ruleId — Kural sil
router.delete('/:homeId/scheduled-rules/:ruleId', authenticateToken, requireHomeAdmin, async (req, res) => {
  try {
    const ruleId = parseInt(req.params.ruleId);
    await svc.deleteRule(ruleId, req.homeId);
    res.json({ success: true });
  } catch (err) {
    console.error('[ScheduledRules] DELETE error:', err);
    res.status(400).json({ error: err.message });
  }
});

module.exports = router;
