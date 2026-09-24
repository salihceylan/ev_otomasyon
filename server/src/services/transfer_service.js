// ==============================================================================
// AHBU Akıllı Ev & Bina Otomasyonu - Daire Devir Servisi (ADIM 13)
// ==============================================================================

const crypto = require('crypto');
const db = require('../db');
const authService = require('./auth_service');

class TransferService {
  /**
   * 1. Ev Sahibi Tarafından Daire Devir Sürecini Başlatma
   */
  static async initiateTransfer({ homeId, fromUserId, targetIdentifier }) {
    if (!homeId || !fromUserId) {
      const err = new Error('Ev ID ve Kullanıcı ID zorunludur');
      err.status = 400;
      throw err;
    }

    // Yetki kontrolü: İsteyen kullanıcı evin sahibi (owner) mi?
    const ownerCheck = await db.query(
      `SELECT role FROM home_users WHERE home_id = $1 AND user_id = $2`,
      [homeId, fromUserId]
    );

    if (ownerCheck.rows.length === 0 || ownerCheck.rows[0].role !== 'owner') {
      const err = new Error('Daire devir işlemini yalnızca mevcut ev sahibi (owner) başlatabilir');
      err.status = 403;
      throw err;
    }

    const cleanTarget = targetIdentifier ? targetIdentifier.trim().toLowerCase() : null;

    // Varsa önceki bekleyen transferi iptal et
    await db.query(
      `UPDATE home_transfers 
       SET status = 'CANCELLED' 
       WHERE home_id = $1 AND status = 'PENDING'`,
      [homeId]
    );

    // 48 saat geçerli 6 haneli transfer kodu üret (Örn: AHBU-TR-482910)
    const randomNum = crypto.randomInt(100000, 999999);
    const transferCode = `AHBU-TR-${randomNum}`;
    const expiresAt = new Date(Date.now() + 48 * 60 * 60 * 1000); // 48 saat

    const insertRes = await db.query(
      `INSERT INTO home_transfers (home_id, from_user_id, target_identifier, transfer_code, status, expires_at)
       VALUES ($1, $2, $3, $4, 'PENDING', $5)
       RETURNING id, home_id, target_identifier, transfer_code, status, expires_at, created_at`,
      [homeId, fromUserId, cleanTarget, transferCode, expiresAt]
    );

    const row = insertRes.rows[0];

    return {
      success: true,
      transfer: {
        id: row.id,
        homeId: row.home_id,
        transferCode: row.transfer_code,
        targetIdentifier: row.target_identifier,
        status: row.status,
        expiresAt: row.expires_at,
        qrPayload: `AHBU-TRANSFER:${row.transfer_code}`,
      },
    };
  }

  /**
   * 2. Yeni Kullanıcı Tarafından Devir Kodunu Kabul Etme ve Daireyi Devralma
   */
  static async acceptTransfer({ transferCode, newUserId }) {
    if (!transferCode || !newUserId) {
      const err = new Error('Devir kodu ve Kullanıcı kimliği zorunludur');
      err.status = 400;
      throw err;
    }

    let cleanCode = String(transferCode).trim().toUpperCase();
    if (cleanCode.startsWith('AHBU-TRANSFER:')) {
      cleanCode = cleanCode.replace('AHBU-TRANSFER:', '').trim();
    }

    // 1. Transfer kaydını sorgula
    const transferRes = await db.query(
      `SELECT t.*, h.name as home_name, h.address as home_address
       FROM home_transfers t
       JOIN homes h ON h.id = t.home_id
       WHERE t.transfer_code = $1`,
      [cleanCode]
    );

    if (transferRes.rows.length === 0) {
      const err = new Error('Geçersiz veya bulunamayan daire devir kodu');
      err.status = 404;
      throw err;
    }

    const transfer = transferRes.rows[0];

    if (transfer.status !== 'PENDING') {
      const err = new Error(`Bu devir işlemi daha önce ${transfer.status === 'COMPLETED' ? 'tamamlanmış' : 'iptal edilmiş'}`);
      err.status = 410;
      throw err;
    }

    const now = new Date();
    if (new Date(transfer.expires_at) < now) {
      await db.query(`UPDATE home_transfers SET status = 'EXPIRED' WHERE id = $1`, [transfer.id]);
      const err = new Error('Bu daire devir kodunun 48 saatlik geçerlilik süresi dolmuştur');
      err.status = 410;
      throw err;
    }

    // 2. Yeni kullanıcının bilgilerini sorgula ve hedef kontrolü yap
    const newUserRes = await db.query(
      `SELECT id, email, phone, full_name FROM users WHERE id = $1`,
      [newUserId]
    );

    if (newUserRes.rows.length === 0) {
      const err = new Error('Yeni kullanıcı profili bulunamadı');
      err.status = 404;
      throw err;
    }

    const newUser = newUserRes.rows[0];

    if (transfer.target_identifier) {
      const target = transfer.target_identifier.toLowerCase();
      const userEmail = (newUser.email || '').toLowerCase();
      const userPhone = (newUser.phone || '').trim();

      if (target !== userEmail && target !== userPhone) {
        const err = new Error(`Bu daire devir kodu yalnızca "${transfer.target_identifier}" kullanıcısı için geçerlidir.`);
        err.status = 403;
        throw err;
      }
    }

    if (transfer.from_user_id === newUserId) {
      const err = new Error('Kendi dairenizi kendinize devredemezsiniz');
      err.status = 400;
      throw err;
    }

    // 3. TRANSACTION: Eski Ailenin Kalıcı Azli & Yeni Malik Ataması
    await db.query('BEGIN');
    try {
      // 3.1. Eski kullanıcıların ID'lerini topla (oturumlarını zorla iptal etmek için)
      const oldUsersRes = await db.query(
        `SELECT user_id FROM home_users WHERE home_id = $1`,
        [transfer.home_id]
      );
      const oldUserIds = oldUsersRes.rows.map(r => r.user_id);

      // 3.2. Eski ailenin tüm üyelerini evden sil
      await db.query(
        `DELETE FROM home_users WHERE home_id = $1`,
        [transfer.home_id]
      );

      // 3.3. Eski bekleyen tüm davetiyeleri kalıcı olarak sil
      await db.query(
        `DELETE FROM home_invitations WHERE home_id = $1`,
        [transfer.home_id]
      );

      // 3.4. Yeni kullanıcıyı evin TEK YETKİLİ 'owner'ı olarak ata
      await db.query(
        `INSERT INTO home_users (home_id, user_id, role)
         VALUES ($1, $2, 'owner')`,
        [transfer.home_id, newUserId]
      );

      // 3.5. Transfer kaydını COMPLETED olarak işaretle
      await db.query(
        `UPDATE home_transfers
         SET status = 'COMPLETED', accepted_by = $1, accepted_at = CURRENT_TIMESTAMP
         WHERE id = $2`,
        [newUserId, transfer.id]
      );

      // 3.6. Cihaz envanterinde sahipliği güncelle
      await db.query(
        `UPDATE device_inventory
         SET claimed_by_user_id = $1
         WHERE claimed_home_id = $2`,
        [newUserId, transfer.home_id]
      );

      await db.query(
        `UPDATE devices
         SET claimed_by = $1
         WHERE home_id = $2`,
        [newUserId, transfer.home_id]
      );

      await db.query('COMMIT');

      // 3.7. Eski ailenin tüm açık oturumlarını zorla kapat (Transaction dışı sessizce)
      for (const oldUid of oldUserIds) {
        try {
          await authService.revokeAllUserSessions(oldUid);
        } catch (_) {}
      }

      return {
        success: true,
        message: `Tebrikler! "${transfer.home_name}" dairesinin mülkiyeti başarıyla size devredildi. Eski sakinlerin tüm erişim yetkileri kalıcı olarak kaldırıldı.`,
        home: {
          id: transfer.home_id,
          name: transfer.home_name,
          address: transfer.home_address,
          role: 'owner',
        },
      };
    } catch (e) {
      await db.query('ROLLBACK');
      throw e;
    }
  }

  /**
   * 3. Devir Durumunu Sorgulama
   */
  static async getTransferStatus(homeId, userId) {
    const ownerCheck = await db.query(
      `SELECT role FROM home_users WHERE home_id = $1 AND user_id = $2`,
      [homeId, userId]
    );

    if (ownerCheck.rows.length === 0 || ownerCheck.rows[0].role !== 'owner') {
      const err = new Error('Yalnızca ev sahibi devir durumunu görüntüleyebilir');
      err.status = 403;
      throw err;
    }

    const res = await db.query(
      `SELECT id, home_id, target_identifier, transfer_code, status, expires_at, created_at
       FROM home_transfers
       WHERE home_id = $1 AND status = 'PENDING'
       ORDER BY created_at DESC LIMIT 1`,
      [homeId]
    );

    return {
      success: true,
      pendingTransfer: res.rows.length > 0 ? res.rows[0] : null,
    };
  }

  /**
   * 4. Devir İşlemini İptal Etme
   */
  static async cancelTransfer(homeId, userId) {
    const ownerCheck = await db.query(
      `SELECT role FROM home_users WHERE home_id = $1 AND user_id = $2`,
      [homeId, userId]
    );

    if (ownerCheck.rows.length === 0 || ownerCheck.rows[0].role !== 'owner') {
      const err = new Error('Yalnızca ev sahibi devir işlemini iptal edebilir');
      err.status = 403;
      throw err;
    }

    await db.query(
      `UPDATE home_transfers 
       SET status = 'CANCELLED' 
       WHERE home_id = $1 AND status = 'PENDING'`,
      [homeId]
    );

    return {
      success: true,
      message: 'Daire devir işlemi iptal edildi.',
    };
  }
}

module.exports = TransferService;

