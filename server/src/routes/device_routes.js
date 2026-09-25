// ==============================================================================
// AHBU Akıllı Ev & Bina Otomasyonu - Cihaz API Rotaları (Faz 4.2 & Faz 6.3)
// ==============================================================================

const express = require('express');
const router = express.Router();
const deviceService = require('../services/device_service');
const { authenticateToken, requireHomeAccess } = require('../middlewares/auth_middleware');
const { successResponse, errorResponse } = require('../utils/helpers');

/**
 * @route   POST /api/v1/devices/claim veya POST /api/devices/claim
 * @desc    Karekod veya elle girilen UID/PIN ile panoyu kullanıcıya sahiplendirir (Zero-Trust Claiming)
 */
const handleClaim = async (req, res) => {
  try {
    const deviceUuid = req.body.device_uuid || req.body.uid;
    const setupPin = req.body.setup_pin || req.body.pin;
    const homeId = req.body.home_id || req.body.homeId;
    const homeName = req.body.home_name || req.body.homeName;
    const targetOwnerIdentifier = req.body.target_owner || req.body.owner_email || req.body.owner_phone;

    if (!deviceUuid || !setupPin) {
      return errorResponse(
        res,
        'Cihaz kimliği (device_uuid / uid) ve 6 haneli Kurulum PIN (setup_pin / pin) alanları zorunludur.',
        400
      );
    }

    const result = await deviceService.claimDevice({
      userId: req.user.id,
      homeId,
      homeName,
      deviceUuid,
      setupPin,
      targetOwnerIdentifier,
    });

    return successResponse(
      res,
      result,
      'Cihaz başarıyla dairenize tanımlandı ve tek kullanımlık PIN güvenle imha edildi.',
      200
    );
  } catch (err) {
    return errorResponse(res, err.message, err.statusCode || 500);
  }
};

router.post('/claim', authenticateToken, handleClaim);

/**
 * @route   POST /api/v1/devices/emergency-reset veya POST /api/devices/emergency-reset
 * @desc    Ulaşılamayan kiracı / acil servis sıfırlaması (Servis Sorumlusu / Süper Yönetici korumalı)
 */
const handleEmergencyReset = async (req, res) => {
  try {
    const isAuthorized = req.user.role === 'service_user' || 
                         req.user.role === 'super_user' || 
                         req.user.role === 'admin';

    if (!isAuthorized) {
      return errorResponse(
        res,
        'Bu acil sıfırlama işlemi yalnızca Yetkili Servis Sorumlusu veya Süper Yönetici tarafından yürütülebilir.',
        403
      );
    }

    const deviceUuid = req.body.device_uuid || req.body.deviceUuid || req.body.uid;
    const reason = req.body.reason;
    const newOwnerIdentifier = req.body.new_owner_identifier || req.body.newOwnerIdentifier;

    if (!deviceUuid || !reason) {
      return errorResponse(res, 'Cihaz kimliği (device_uuid) ve gerekçe (reason) zorunludur.', 400);
    }

    const result = await deviceService.emergencyReset({
      installerUserId: req.user.id,
      deviceUuid,
      reason,
      newOwnerIdentifier,
    });

    return successResponse(res, result, result.message, 200);
  } catch (err) {
    return errorResponse(res, err.message, err.statusCode || 500);
  }
};

router.post('/emergency-reset', authenticateToken, handleEmergencyReset);

/**
 * @route   GET /api/devices/home/:home_id
 * @desc    Daireye bağlı cihazları listeler
 */
router.get('/home/:home_id', authenticateToken, requireHomeAccess(['owner', 'resident', 'guest', 'service_user']), async (req, res) => {
  try {
    const devices = await deviceService.getDevicesByHome(req.params.home_id);
    return successResponse(res, devices);
  } catch (err) {
    return errorResponse(res, err.message, 500);
  }
});

/**
 * @route   POST /api/devices/:id/command
 * @desc    Cihaza doğrudan MQTT komutu gönderir
 */
router.post('/:id/command', authenticateToken, async (req, res) => {
  try {
    const { home_id, command } = req.body;
    if (!home_id || !command) {
      return errorResponse(res, 'home_id ve command nesnesi sağlanmalıdır.', 400);
    }

    const result = await deviceService.sendCommand(home_id, req.params.id, command);
    return successResponse(res, result, 'Komut cihaza iletildi.');
  } catch (err) {
    return errorResponse(res, err.message, err.statusCode || 500);
  }
});

/**
 * @route   GET /api/v1/devices/diagnostic/:home_id veya GET /api/v1/devices/diagnostic
 * @desc    ADIM 16: Sistem Doktoru (Self-Diagnostic) 3 katmanlı teşhis raporu
 */
const handleDiagnostic = async (req, res) => {
  try {
    let homeId = req.params.home_id || req.query.home_id || req.query.homeId;
    if (homeId === '0' || homeId === 0) homeId = null;

    const result = await deviceService.getSystemDiagnostic({
      userId: req.user.id,
      homeId,
    });
    return successResponse(res, result, 'Teşhis raporu oluşturuldu.', 200);
  } catch (err) {
    return errorResponse(res, err.message, err.statusCode || 500);
  }
};

router.get('/diagnostic/:home_id', authenticateToken, handleDiagnostic);
router.get('/diagnostic', authenticateToken, handleDiagnostic);

/**
 * @route   POST /api/v1/devices/replace-board
 * @desc    ADIM 16: Felaket Kurtarma (Disaster Recovery) - Tek tıkla pano değişimi
 */
router.post('/replace-board', authenticateToken, async (req, res) => {
  try {
    const { home_id, homeId, old_device_uuid, oldDeviceUuid, new_device_uuid, newDeviceUuid, setup_pin, setupPin, reason } = req.body;
    const targetHomeId = home_id || homeId;
    const targetOldUuid = old_device_uuid || oldDeviceUuid;
    const targetNewUuid = new_device_uuid || newDeviceUuid;
    const targetPin = setup_pin || setupPin;

    if (!targetHomeId || !targetNewUuid || !targetPin) {
      return errorResponse(res, 'home_id, new_device_uuid ve setup_pin zorunludur.', 400);
    }

    const result = await deviceService.replaceBoard({
      userId: req.user.id,
      homeId: targetHomeId,
      oldDeviceUuid: targetOldUuid,
      newDeviceUuid: targetNewUuid,
      setupPin: targetPin,
      reason,
    });

    return successResponse(res, result, result.message, 200);
  } catch (err) {
    return errorResponse(res, err.message, err.statusCode || 500);
  }
});

/**
 * @route   POST /api/v1/devices/child-lock
 * @desc    ADIM 17: Çocuk Kilidi (Fiziksel Duvar Anahtarlarını Kilitler/Açar)
 */
router.post('/child-lock', authenticateToken, async (req, res) => {
  try {
    const { home_id, homeId, enabled } = req.body;
    const targetHomeId = home_id || homeId;

    if (!targetHomeId || enabled === undefined) {
      return errorResponse(res, 'home_id ve enabled parametreleri zorunludur.', 400);
    }

    const result = await deviceService.setChildLock(targetHomeId, !!enabled);
    return successResponse(res, result, result.message, 200);
  } catch (err) {
    return errorResponse(res, err.message, err.statusCode || 500);
  }
});

/**
 * @route   GET /api/v1/devices/child-lock/:home_id
 * @desc    ADIM 17: Çocuk Kilidi Durumu
 */
router.get('/child-lock/:home_id', authenticateToken, async (req, res) => {
  try {
    const result = await deviceService.getChildLock(req.params.home_id);
    return successResponse(res, result);
  } catch (err) {
    return errorResponse(res, err.message, err.statusCode || 500);
  }
});

/**
 * @route   GET /api/v1/devices/peace-notification/:home_id
 * @desc    ADIM 17: Gece Huzur Bildirimi Durumu ve Açık Lambalar
 */
router.get('/peace-notification/:home_id', authenticateToken, async (req, res) => {
  try {
    const result = await deviceService.getPeaceNotificationSettings(req.params.home_id);
    return successResponse(res, result);
  } catch (err) {
    return errorResponse(res, err.message, err.statusCode || 500);
  }
});

/**
 * @route   PUT /api/v1/devices/peace-notification/:home_id
 * @desc    ADIM 17: Gece Huzur Bildirimi Ayarlarını Güncelle (Saat, Aktiflik)
 */
router.put('/peace-notification/:home_id', authenticateToken, async (req, res) => {
  try {
    const { enabled, notification_time, notificationTime } = req.body;
    const result = await deviceService.updatePeaceNotificationSettings(req.params.home_id, {
      enabled,
      notificationTime: notification_time || notificationTime,
    });
    return successResponse(res, result, result.message, 200);
  } catch (err) {
    return errorResponse(res, err.message, err.statusCode || 500);
  }
});

/**
 * @route   POST /api/v1/devices/peace-notification/close-all
 * @desc    ADIM 17: "Salonda 2 lamba açık. [Hepsini Kapat]" tek tıkla açık lambaları kapatır
 */
router.post('/peace-notification/close-all', authenticateToken, async (req, res) => {
  try {
    const { home_id, homeId } = req.body;
    const targetHomeId = home_id || homeId;

    if (!targetHomeId) {
      return errorResponse(res, 'home_id zorunludur.', 400);
    }

    const result = await deviceService.closeAllOpenLights(targetHomeId, req.user.id);
    return successResponse(res, result, result.message, 200);
  } catch (err) {
    return errorResponse(res, err.message, err.statusCode || 500);
  }
});

module.exports = router;
