// ==============================================================================
// AHBU Akıllı Ev & Bina Otomasyonu - Admin / Fabrika API Key Middleware (Faz 6.2)
// ==============================================================================

const jwt = require('jsonwebtoken');
const ADMIN_API_KEY = process.env.INVENTORY_ADMIN_API_KEY || 'GudeAdminInventoryKey2026_SecretProvisioning';

function requireAdminApiKey(req, res, next) {
  const apiKey = req.headers['x-admin-api-key'] || req.headers['x-api-key'];

  if (apiKey && (apiKey === ADMIN_API_KEY || apiKey === `${ADMIN_API_KEY}!`)) {
    return next();
  }

  // Alternatif olarak Super User veya Service User JWT belirteci kabul et
  const authHeader = req.headers['authorization'];
  const token = authHeader && authHeader.split(' ')[1];
  if (token) {
    try {
      const decoded = jwt.verify(token, process.env.JWT_SECRET);
      if (decoded.role === 'super_user' || decoded.role === 'service_user') {
        req.user = decoded;
        return next();
      }
    } catch (_) {
      // Token geçersizse aşağıdaki 401 yanıtına düşsün
    }
  }

  return res.status(401).json({
    success: false,
    message: 'Yetkisiz erişim: Geçerli Admin API anahtarı (X-Admin-Api-Key) veya Süper/Servis Kullanıcı oturumu gereklidir.',
  });
}

module.exports = requireAdminApiKey;

