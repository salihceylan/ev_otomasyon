const express = require('express');
const router = express.Router({ mergeParams: true });
const endpointService = require('../services/endpoint_service');
const { authenticateToken, requireHomeAccess } = require('../middlewares/auth_middleware');
const { successResponse, errorResponse } = require('../utils/helpers');

// GET /api/homes/:home_id/endpoints (Dairedeki Tum Kontrol Noktalari)
router.get('/', authenticateToken, requireHomeAccess(['owner', 'resident', 'service_user', 'guest']), async (req, res) => {
  try {
    const endpoints = await endpointService.getEndpointsByHome(req.params.home_id);
    return successResponse(res, endpoints);
  } catch (err) {
    return errorResponse(res, err.message, 500);
  }
});

// PUT /api/homes/:home_id/endpoints/:id (Oda, İsim, Tip, Motor Kalibrasyon Süresi Güncelleme)
// ADIM 11 RBAC Kuralı: Aile Sakini donanım/klemens/motor sürelerini DEĞİŞTİREMEZ. Yalnızca Yetkili Servis Sorumlusu veya Süper Yönetici değiştirebilir.
router.put('/:id', authenticateToken, requireHomeAccess(['owner', 'service_user']), async (req, res) => {
  try {
    const { name, room, type, shutter_duration_sec, channel, channel_index } = req.body;

    // Donanım ve Motor Koruma Kuralı
    const isService = req.user.role === 'service_user' || 
                      req.user.role === 'super_user' || 
                      req.homeAccess.role === 'service_user';

    if (!isService) {
      if (shutter_duration_sec !== undefined || channel !== undefined || channel_index !== undefined) {
        return errorResponse(
          res,
          'Donanım ve motor koruması: Klemens eşlemesi ve panjur motor kalibrasyonu KESİNLİKLE yalnızca Yetkili Servis Sorumlusu tarafından değiştirilebilir.',
          403
        );
      }
    }

    const updated = await endpointService.updateEndpoint(req.params.home_id, req.params.id, {
      name,
      room,
      type,
      shutter_duration_sec,
    });
    return successResponse(res, updated, 'Kontrol noktası güncellendi.');
  } catch (err) {
    return errorResponse(res, err.message, err.statusCode || 500);
  }
});

// POST /api/homes/:home_id/endpoints/:id/control (Lamba Ac/Kapa, Panjur % Surus)
router.post('/:id/control', authenticateToken, requireHomeAccess(['owner', 'resident', 'service_user', 'guest']), async (req, res) => {
  try {
    const result = await endpointService.controlEndpoint(req.params.home_id, req.params.id, req.body);
    return successResponse(res, result, 'Komut iletildi.');
  } catch (err) {
    return errorResponse(res, err.message, err.statusCode || 500);
  }
});

module.exports = router;

