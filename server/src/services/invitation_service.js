const crypto = require('crypto');
const db = require('../db');

class InvitationService {
  /**
   * Ev sahibi için aile davet kodu veya süreli misafir kodu üretir.
   * @param {string} homeId
   * @param {string} userId - İsteyen kullanıcının ID'si (owner olmalı)
   * @param {string} role - 'member' | 'guest'
   * @param {object} options - { durationHours, validFrom, validUntil, guestName }
   */
  static async createInvitation(homeId, userId, role = 'member', options = {}) {
    // 1. Yetki kontrolü: İsteyen kullanıcı evin sahibi (owner) mi?
    const ownerCheck = await db.query(
      `SELECT role FROM home_users WHERE home_id = $1 AND user_id = $2`,
      [homeId, userId]
    );

    if (ownerCheck.rows.length === 0 || ownerCheck.rows[0].role !== 'owner') {
      const err = new Error('Yalnızca ev sahibi aile ve misafir davet kodu oluşturabilir');
      err.status = 403;
      throw err;
    }

    let guestValidFrom = null;
    let guestValidUntil = null;
    let expiresAt;
    let inviteCode;

    if (role === 'guest') {
      // Süreli Misafir / Temizlikçi Modu
      const now = new Date();
      guestValidFrom = options.validFrom ? new Date(options.validFrom) : now;

      if (options.validUntil) {
        guestValidUntil = new Date(options.validUntil);
      } else {
        const hours = options.durationHours ? parseInt(options.durationHours, 10) : 8;
        guestValidUntil = new Date(guestValidFrom.getTime() + hours * 60 * 60 * 1000);
      }

      // Davet kodunun süresi misafirliğin bitiş zamanı ile sınırlıdır (en az 1 saat, en çok 48 saat)
      expiresAt = guestValidUntil;
      const randomNum = crypto.randomInt(100000, 999999);
      inviteCode = `AHBU-G-${randomNum}`;
    } else {
      // Kalıcı Aile Üyesi
      const randomNum = crypto.randomInt(100000, 999999);
      inviteCode = `AHBU-${randomNum}`;
      expiresAt = new Date(Date.now() + 24 * 60 * 60 * 1000); // 24 saat geçerli
    }

    const guestName = options.guestName ? options.guestName.trim() : null;

    // 2. Veritabanına kaydet
    const insertRes = await db.query(
      `INSERT INTO home_invitations (home_id, created_by, invite_code, role, expires_at, guest_valid_from, guest_valid_until, guest_name)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
       RETURNING id, home_id, invite_code, role, expires_at, guest_valid_from, guest_valid_until, guest_name, created_at`,
      [homeId, userId, inviteCode, role, expiresAt, guestValidFrom, guestValidUntil, guestName]
    );

    const row = insertRes.rows[0];
    const qrPayload = `AHBU-INVITE:${inviteCode}`;

    return {
      success: true,
      invitation: {
        id: row.id,
        homeId: row.home_id,
        inviteCode: row.invite_code,
        role: row.role,
        guestName: row.guest_name,
        guestValidFrom: row.guest_valid_from,
        guestValidUntil: row.guest_valid_until,
        expiresAt: row.expires_at,
        qrPayload,
      },
    };
  }

  /**
   * Aile ferdi veya misafir davet kodunu girerek (veya QR okutarak) eve katılır.
   */
  static async joinHomeWithCode(inviteCode, userId) {
    let cleanCode = (inviteCode || '').trim().toUpperCase();
    if (cleanCode.startsWith('AHBU-INVITE:')) {
      cleanCode = cleanCode.replace('AHBU-INVITE:', '').trim();
    }

    if (!cleanCode) {
      const err = new Error('Geçerli bir davet kodu giriniz');
      err.status = 400;
      throw err;
    }

    // 1. Davet kodunu sorgula
    const invRes = await db.query(
      `SELECT i.*, h.name as home_name, h.address as home_address
       FROM home_invitations i
       JOIN homes h ON h.id = i.home_id
       WHERE i.invite_code = $1`,
      [cleanCode]
    );

    if (invRes.rows.length === 0) {
      const err = new Error('Geçersiz veya bulunamayan davet kodu');
      err.status = 404;
      throw err;
    }

    const invitation = invRes.rows[0];

    // 2. Kullanılmışlık ve süre kontrolü
    if (invitation.is_used) {
      const err = new Error('Bu davet kodu daha önce kullanılmış');
      err.status = 410;
      throw err;
    }

    const now = new Date();
    if (new Date(invitation.expires_at) < now) {
      const err = new Error('Bu davet kodunun geçerlilik süresi dolmuş');
      err.status = 410;
      throw err;
    }

    if (invitation.role === 'guest' && invitation.guest_valid_until && new Date(invitation.guest_valid_until) < now) {
      const err = new Error('Bu misafir erişiminin süresi sona ermiş');
      err.status = 410;
      throw err;
    }

    // 3. Kullanıcı zaten bu eve kayıtlı mı?
    const userHomeCheck = await db.query(
      `SELECT role, valid_until FROM home_users WHERE home_id = $1 AND user_id = $2`,
      [invitation.home_id, userId]
    );

    if (userHomeCheck.rows.length > 0) {
      const existing = userHomeCheck.rows[0];
      // Eğer eski bir misafirse ve yeni bir davetle geliyorsa süresini yenileyelim
      if (existing.role === 'guest' && invitation.role === 'guest') {
        await db.query(
          `UPDATE home_users
           SET valid_from = $1, valid_until = $2
           WHERE home_id = $3 AND user_id = $4`,
          [invitation.guest_valid_from, invitation.guest_valid_until, invitation.home_id, userId]
        );
        await db.query(
          `UPDATE home_invitations
           SET is_used = TRUE, used_by = $1, used_at = CURRENT_TIMESTAMP
           WHERE id = $2`,
          [userId, invitation.id]
        );
        return {
          success: true,
          message: `"${invitation.home_name}" evindeki misafir süreniz başarıyla yenilendi.`,
          home: {
            id: invitation.home_id,
            name: invitation.home_name,
            address: invitation.home_address,
            role: 'guest',
            validUntil: invitation.guest_valid_until,
          },
        };
      }

      return {
        success: true,
        alreadyMember: true,
        message: 'Zaten bu evin bir üyesisiniz',
        home: {
          id: invitation.home_id,
          name: invitation.home_name,
          address: invitation.home_address,
          role: existing.role,
        },
      };
    }

    // 4. Kullanıcıyı eve ekle ve daveti kapat
    await db.query('BEGIN');
    try {
      await db.query(
        `INSERT INTO home_users (home_id, user_id, role, valid_from, valid_until)
         VALUES ($1, $2, $3, $4, $5)`,
        [
          invitation.home_id,
          userId,
          invitation.role || 'member',
          invitation.guest_valid_from,
          invitation.guest_valid_until,
        ]
      );

      await db.query(
        `UPDATE home_invitations
         SET is_used = TRUE, used_by = $1, used_at = CURRENT_TIMESTAMP
         WHERE id = $2`,
        [userId, invitation.id]
      );

      await db.query('COMMIT');
    } catch (e) {
      await db.query('ROLLBACK');
      throw e;
    }

    const isGuest = invitation.role === 'guest';
    return {
      success: true,
      message: isGuest
        ? `"${invitation.home_name}" evine süreli misafir olarak katıldınız.`
        : `Tebrikler! "${invitation.home_name}" evine aile bireyi olarak katıldınız.`,
      home: {
        id: invitation.home_id,
        name: invitation.home_name,
        address: invitation.home_address,
        role: invitation.role || 'member',
        validUntil: invitation.guest_valid_until,
      },
    };
  }

  /**
   * Evin tüm üyelerini ve süreli misafirlerini listeler.
   */
  static async getHomeMembers(homeId, userId) {
    // İsteyen kullanıcı bu evde mi?
    const userCheck = await db.query(
      `SELECT role FROM home_users WHERE home_id = $1 AND user_id = $2`,
      [homeId, userId]
    );

    if (userCheck.rows.length === 0) {
      const err = new Error('Bu evin üyelerini görüntüleme yetkiniz yok');
      err.status = 403;
      throw err;
    }

    const membersRes = await db.query(
      `SELECT hu.user_id, hu.role, hu.valid_from, hu.valid_until, hu.created_at,
              u.full_name, u.email, u.phone
       FROM home_users hu
       JOIN users u ON u.id = hu.user_id
       WHERE hu.home_id = $1
       ORDER BY CASE hu.role WHEN 'owner' THEN 1 WHEN 'member' THEN 2 WHEN 'guest' THEN 3 ELSE 4 END, hu.created_at ASC`,
      [homeId]
    );

    const now = new Date();
    const members = membersRes.rows.map(row => {
      const isExpired = row.role === 'guest' && row.valid_until && new Date(row.valid_until) < now;
      return {
        userId: row.user_id,
        fullName: row.full_name,
        email: row.email,
        phone: row.phone,
        role: row.role,
        validFrom: row.valid_from,
        validUntil: row.valid_until,
        isExpired: isExpired,
        joinedAt: row.created_at,
      };
    });

    return {
      success: true,
      members,
    };
  }

  /**
   * Ev sahibi bir üyeyi veya misafiri evden çıkarır.
   */
  static async removeHomeMember(homeId, requesterId, targetUserId) {
    // 1. Yetki kontrolü: İsteyen kullanıcı owner mı?
    const ownerCheck = await db.query(
      `SELECT role FROM home_users WHERE home_id = $1 AND user_id = $2`,
      [homeId, requesterId]
    );

    if (ownerCheck.rows.length === 0 || ownerCheck.rows[0].role !== 'owner') {
      const err = new Error('Yalnızca ev sahibi üyeleri ve misafirleri evden çıkarabilir');
      err.status = 403;
      throw err;
    }

    if (requesterId === targetUserId) {
      const err = new Error('Ev sahibi kendi kendini evden çıkaramaz');
      err.status = 400;
      throw err;
    }

    const deleteRes = await db.query(
      `DELETE FROM home_users WHERE home_id = $1 AND user_id = $2 RETURNING id`,
      [homeId, targetUserId]
    );

    if (deleteRes.rows.length === 0) {
      const err = new Error('Kullanıcı bu evde bulunamadı');
      err.status = 404;
      throw err;
    }

    return {
      success: true,
      message: 'Kullanıcı evden başarıyla çıkarıldı ve yetkisi iptal edildi.',
    };
  }
}

module.exports = InvitationService;
