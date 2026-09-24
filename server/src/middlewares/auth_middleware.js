const jwt = require('jsonwebtoken');
const db = require('../db');
const { errorResponse } = require('../utils/helpers');

async function authenticateToken(req, res, next) {
  const authHeader = req.headers['authorization'];
  const token = authHeader && authHeader.split(' ')[1]; // Bearer <TOKEN>

  if (!token) {
    return errorResponse(res, 'Yetkilendirme belirteci (token) saglanmadi.', 401);
  }

  try {
    const decoded = jwt.verify(token, process.env.JWT_SECRET);
    req.user = decoded; // { id, email, full_name, role, home_id, etc. }
    next();
  } catch (err) {
    if (err.name === 'TokenExpiredError') {
      return errorResponse(res, 'Oturum sureniz doldu, lutfen tekrar giris yapin.', 401);
    }
    return errorResponse(res, 'Gecersiz yetkilendirme belirteci.', 403);
  }
}

function requireHomeAccess(allowedRoles = ['owner', 'resident', 'guest', 'installer']) {
  return async (req, res, next) => {
    try {
      const homeId = req.params.home_id || req.body.home_id || req.query.home_id;

      if (!homeId) {
        return errorResponse(res, 'Daire (home_id) parametresi belirtilmelidir.', 400);
      }

      // Kullanicinin bu evdeki rolunu sorgula
      const result = await db.query(
        `SELECT role, installer_expires_at, valid_from, valid_until 
         FROM home_users 
         WHERE home_id = $1 AND user_id = $2`,
        [homeId, req.user.id]
      );

      if (result.rows.length === 0) {
        return errorResponse(res, 'Bu daireye erisim yetkiniz bulunmamaktadir.', 403);
      }

      const membership = result.rows[0];

      // Kurulumcu / Teknisyen ise sure kontrolu yap (Adim 4.3)
      if (membership.role === 'installer') {
        if (!membership.installer_expires_at || new Date(membership.installer_expires_at) < new Date()) {
          return errorResponse(res, 'Teknisyen servis yetkinizin 2 saatlik suresi dolmustur. Ev sahibinden yeni servis PIN\'i talep edin.', 403);
        }
      }

      // ADIM 12: Misafir / Temizlikçi ise geçerlilik süresi ve saat aralığı kontrolü yap
      if (membership.role === 'guest') {
        const now = new Date();
        if (membership.valid_until && new Date(membership.valid_until) < now) {
          return errorResponse(res, 'Misafir erisim sureniz sona ermistir. Ev sahibinden yeni erisim talep ediniz.', 403, 'GUEST_EXPIRED');
        }
        if (membership.valid_from && new Date(membership.valid_from) > now) {
          return errorResponse(res, 'Misafir erisim sureniz henuz baslamamistir.', 403, 'GUEST_NOT_STARTED');
        }
      }

      if (!allowedRoles.includes(membership.role)) {
        return errorResponse(res, 'Bu islem icin yetkiniz yetersizdir.', 403);
      }

      req.homeAccess = {
        home_id: homeId,
        role: membership.role,
      };

      next();
    } catch (err) {
      console.error('[AUTH-MIDDLEWARE-ERROR]', err);
      return errorResponse(res, 'Yetki dogrulama sirasinda sunucu hatasi olustu.', 500);
    }
  };
}

module.exports = {
  authenticateToken,
  requireHomeAccess,
};

