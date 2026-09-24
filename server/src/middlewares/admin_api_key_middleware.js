// ==============================================================================
// AHBU Akıllı Ev & Bina Otomasyonu - Admin / Fabrika API Key Middleware (Faz 6.2)
// ==============================================================================

const ADMIN_API_KEY = process.env.INVENTORY_ADMIN_API_KEY || 'GudeAdminInventoryKey2026_SecretProvisioning!';

function requireAdminApiKey(req, res, next) {
  const apiKey = req.headers['x-admin-api-key'] || req.headers['x-api-key'];

  if (!apiKey || apiKey !== ADMIN_API_KEY) {
    return res.status(401).json({
      success: false,
      message: 'Yetkisiz erişim: Geçersiz veya eksik Admin API anahtarı (X-Admin-Api-Key).',
    });
  }

  next();
}

module.exports = requireAdminApiKey;

