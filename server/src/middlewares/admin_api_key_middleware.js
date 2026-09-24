// ==============================================================================
// AHBU Akıllı Ev & Bina Otomasyonu - Admin / Fabrika API Key Middleware (Faz 6.2)
// ==============================================================================

const jwt = require('jsonwebtoken');
const bcrypt = require('bcryptjs');
const db = require('../db');

const ADMIN_API_KEY = process.env.INVENTORY_ADMIN_API_KEY || 'GudeAdminInventoryKey2026_SecretProvisioning';

async function requireAdminApiKey(req, res, next) {
  try {
    const apiKey = req.headers['x-admin-api-key'] || req.headers['x-api-key'];

    if (apiKey) {
      // 1. Sabit Admin API Key veya Master Sunucu Şifreleri Kontrolü
      if (
        apiKey === ADMIN_API_KEY ||
        apiKey === `${ADMIN_API_KEY}!` ||
        apiKey === 'Fingon08.' ||
        apiKey === 'GudeAdmin2026!'
      ) {
        return next();
      }

      // 2. Veritabanındaki aktif Süper Kullanıcıların şifreleri ile Bcrypt karşılaştırması
      try {
        const suResult = await db.query(
          "SELECT id, email, password_hash, role FROM users WHERE role = 'super_user' AND is_active = TRUE"
        );
        for (const su of suResult.rows) {
          if (su.password_hash && (await bcrypt.compare(apiKey, su.password_hash))) {
            req.user = su;
            return next();
          }
        }
      } catch (dbErr) {
        console.error('Super user password verification error:', dbErr.message);
      }
    }

    // 3. Alternatif olarak Super User veya Service User JWT belirteci kabul et
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
        // Token geçersizse 401'e düşsün
      }
    }

    return res.status(401).json({
      success: false,
      message: 'Yetkisiz erişim: Geçerli Sunucu Şifresi veya Admin yetkilendirmesi gereklidir.',
    });
  } catch (err) {
    return next(err);
  }
}

module.exports = requireAdminApiKey;

