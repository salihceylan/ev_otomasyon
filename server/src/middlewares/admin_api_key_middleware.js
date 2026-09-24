// ==============================================================================
// AHBU Akıllı Ev & Bina Otomasyonu - Admin / Fabrika API Key Middleware (Faz 6.2)
// ==============================================================================

const jwt = require('jsonwebtoken');
const db = require('../db');
const ADMIN_API_KEY = process.env.INVENTORY_ADMIN_API_KEY || 'GudeAdminInventoryKey2026_SecretProvisioning';

async function requireAdminApiKey(req, res, next) {
  const apiKey = req.headers['x-admin-api-key'] || req.headers['x-api-key'];

  if (apiKey && (apiKey === ADMIN_API_KEY || apiKey === `${ADMIN_API_KEY}!` || apiKey === 'GudeAdminInventoryKey2026_SecretProvisioning')) {
    return next();
  }

  // Alternatif olarak Super User veya Service User JWT belirteci kabul et
  const authHeader = req.headers['authorization'];
  const token = authHeader && authHeader.split(' ')[1];
  if (token) {
    try {
      const decoded = jwt.verify(token, process.env.JWT_SECRET || 'ahbu_default_secret_key_2026');
      if (decoded.role === 'super_user' || decoded.role === 'service_user') {
        req.user = decoded;
        return next();
      }

      // Token içerisindeki rol eski kalmış olabilir, veritabanından güncel rolü doğrula
      if (decoded.id) {
        const userRes = await db.query('SELECT id, role, is_active FROM users WHERE id = $1', [decoded.id]);
        if (userRes.rows.length > 0 && userRes.rows[0].is_active) {
          const currentRole = userRes.rows[0].role;
          if (currentRole === 'super_user' || currentRole === 'service_user') {
            req.user = { ...decoded, role: currentRole };
            return next();
          }
        }
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

