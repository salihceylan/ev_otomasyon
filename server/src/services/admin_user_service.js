'use strict';

const bcrypt = require('bcryptjs');
const db = require('../db');

class AdminUserService {
  /**
   * Kullanıcıları filtreleme ve sayfalama ile listeler
   */
  async listUsers({ role, search, is_active, limit = 50, offset = 0, currentUser }) {
    const conditions = [];
    const params = [];
    let paramIdx = 1;

    // Rol filtresi
    if (role && role !== 'all') {
      conditions.push(`u.role = $${paramIdx++}`);
      params.push(role);
    }

    // Aktiflik filtresi
    if (is_active !== undefined && is_active !== null && is_active !== '') {
      conditions.push(`u.is_active = $${paramIdx++}`);
      params.push(is_active === 'true' || is_active === true);
    }

    // Arama filtresi (ad, soyad, e-posta, telefon)
    if (search && search.trim()) {
      const q = `%${search.trim().toLowerCase()}%`;
      conditions.push(`(LOWER(u.full_name) LIKE $${paramIdx} OR LOWER(u.email) LIKE $${paramIdx} OR u.phone LIKE $${paramIdx})`);
      params.push(q);
      paramIdx++;
    }

    // Eğer çağıran kullanıcı service_user ise, super_user'ları liste dışı tutabilir veya sadece servis ekibini görebilir
    if (currentUser && currentUser.role === 'service_user') {
      conditions.push(`u.role IN ('service_user', 'user')`);
    }

    const whereClause = conditions.length > 0 ? `WHERE ${conditions.join(' AND ')}` : '';

    const countQuery = `SELECT COUNT(*) as total FROM users u ${whereClause}`;
    const countRes = await db.query(countQuery, params);
    const total = parseInt(countRes.rows[0].total, 10);

    const listQuery = `
      SELECT 
        u.id,
        u.email,
        u.full_name,
        u.phone,
        u.role,
        u.is_active,
        u.created_at,
        u.updated_at,
        u.admin_notes,
        creator.email as created_by_email,
        creator.full_name as created_by_name,
        (
          SELECT COUNT(*) FROM home_users hu WHERE hu.user_id = u.id
        ) as home_count,
        (
          SELECT COUNT(*) FROM commissioning_logs cl WHERE cl.technician_id = u.id
        ) as commissioning_count
      FROM users u
      LEFT JOIN users creator ON u.created_by_user_id = creator.id
      ${whereClause}
      ORDER BY 
        CASE 
          WHEN u.role = 'super_user' THEN 1
          WHEN u.role = 'service_user' THEN 2
          ELSE 3
        END,
        u.created_at DESC
      LIMIT $${paramIdx++} OFFSET $${paramIdx++}
    `;

    params.push(limit, offset);
    const listRes = await db.query(listQuery, params);

    return {
      total,
      limit,
      offset,
      users: listRes.rows,
    };
  }

  /**
   * Tek bir kullanıcı detayını getirir
   */
  async getUserById(userId) {
    const res = await db.query(
      `SELECT 
        u.id,
        u.email,
        u.full_name,
        u.phone,
        u.role,
        u.is_active,
        u.created_at,
        u.updated_at,
        u.admin_notes,
        creator.email as created_by_email,
        creator.full_name as created_by_name
       FROM users u
       LEFT JOIN users creator ON u.created_by_user_id = creator.id
       WHERE u.id = $1`,
      [userId]
    );

    if (res.rows.length === 0) {
      const err = new Error('Kullanıcı bulunamadı');
      err.statusCode = 404;
      throw err;
    }

    const user = res.rows[0];

    // Kullanıcının daireleri
    const homesRes = await db.query(
      `SELECT h.id, h.name, h.address, hu.role, hu.created_at
       FROM homes h
       JOIN home_users hu ON h.id = hu.home_id
       WHERE hu.user_id = $1`,
      [userId]
    );

    // Eğer servis sorumlusu ise son devreye alma (commissioning) kayıtları
    let commissioningLogs = [];
    if (user.role === 'service_user') {
      const logsRes = await db.query(
        `SELECT cl.id, cl.home_id, h.name as home_name, cl.tests_passed, cl.notes, cl.created_at
         FROM commissioning_logs cl
         LEFT JOIN homes h ON cl.home_id = h.id
         WHERE cl.technician_id = $1
         ORDER BY cl.created_at DESC
         LIMIT 20`,
        [userId]
      );
      commissioningLogs = logsRes.rows;
    }

    return {
      user,
      homes: homesRes.rows,
      commissioning_logs: commissioningLogs,
    };
  }

  /**
   * Yeni kullanıcı oluşturur (Süper Kullanıcı, Servis Sorumlusu, Daire Kullanıcısı)
   */
  async createUser({ full_name, email, password, phone, role = 'user', admin_notes, currentUser }) {
    if (!full_name || !email || !password) {
      const err = new Error('Ad Soyad, E-posta ve Şifre alanları zorunludur.');
      err.statusCode = 400;
      throw err;
    }

    const cleanEmail = String(email).trim().toLowerCase();
    const cleanPhone = phone ? String(phone).trim() : null;
    const cleanRole = String(role).trim().toLowerCase();

    const validRoles = ['super_user', 'service_user', 'user'];
    if (!validRoles.includes(cleanRole)) {
      const err = new Error(`Geçersiz rol. İzin verilen roller: ${validRoles.join(', ')}`);
      err.statusCode = 400;
      throw err;
    }

    // Yetki Kontrolleri:
    // Sadece super_user başka bir super_user veya service_user tanımlayabilir!
    if (cleanRole === 'super_user' || cleanRole === 'service_user') {
      if (!currentUser || currentUser.role !== 'super_user') {
        const err = new Error('Süper Kullanıcı veya Servis Sorumlusu tanımlama yetkisi yalnızca Süper Yöneticilere aittir.');
        err.statusCode = 403;
        throw err;
      }
    }

    // service_user sadece regular user (daire kullanıcısı) tanımlayabilir
    if (currentUser && currentUser.role === 'service_user') {
      if (cleanRole !== 'user') {
        const err = new Error('Servis Sorumluları yalnızca standart daire kullanıcısı tanımlayabilir.');
        err.statusCode = 403;
        throw err;
      }
    }

    // E-posta benzersizlik kontrolü
    const existing = await db.query('SELECT id FROM users WHERE LOWER(email) = $1', [cleanEmail]);
    if (existing.rows.length > 0) {
      const err = new Error('Bu e-posta adresi sistemde zaten kayıtlıdır.');
      err.statusCode = 409;
      throw err;
    }

    // Şifre uzunluk kontrolü
    if (String(password).length < 6) {
      const err = new Error('Şifre en az 6 karakter olmalıdır.');
      err.statusCode = 400;
      throw err;
    }

    const salt = await bcrypt.genSalt(10);
    const passwordHash = await bcrypt.hash(password, salt);

    const insertRes = await db.query(
      `INSERT INTO users (
        full_name,
        email,
        password_hash,
        phone,
        role,
        is_active,
        created_by_user_id,
        admin_notes
      ) VALUES ($1, $2, $3, $4, $5, TRUE, $6, $7)
      RETURNING id, email, full_name, phone, role, is_active, created_at, admin_notes`,
      [
        full_name.trim(),
        cleanEmail,
        passwordHash,
        cleanPhone,
        cleanRole,
        currentUser ? currentUser.id : null,
        admin_notes ? admin_notes.trim() : null,
      ]
    );

    return insertRes.rows[0];
  }

  /**
   * Kullanıcı bilgilerini günceller
   */
  async updateUser(userId, { full_name, phone, role, password, is_active, admin_notes, currentUser }) {
    // Mevcut kullanıcıyı çek
    const existingRes = await db.query('SELECT * FROM users WHERE id = $1', [userId]);
    if (existingRes.rows.length === 0) {
      const err = new Error('Güncellenecek kullanıcı bulunamadı.');
      err.statusCode = 404;
      throw err;
    }

    const targetUser = existingRes.rows[0];

    // Yetki Hiyerarşisi Kontrolleri:
    // Hedef kullanıcı super_user ise, yalnızca başka bir super_user müdahale edebilir
    if (targetUser.role === 'super_user') {
      if (!currentUser || currentUser.role !== 'super_user') {
        const err = new Error('Süper Kullanıcı hesaplarını yalnızca Süper Yöneticiler düzenleyebilir.');
        err.statusCode = 403;
        throw err;
      }
    }

    // Hedef kullanıcı service_user ise, service_user rolündeki biri onu düzenleyemez
    if (targetUser.role === 'service_user' && currentUser && currentUser.role === 'service_user') {
      if (currentUser.id !== targetUser.id) {
        const err = new Error('Servis Sorumluları başka bir Servis Sorumlusunun hesabını düzenleyemez.');
        err.statusCode = 403;
        throw err;
      }
    }

    // Rol değişikliği kontrolü
    if (role && role !== targetUser.role) {
      const validRoles = ['super_user', 'service_user', 'user'];
      if (!validRoles.includes(role)) {
        const err = new Error(`Geçersiz rol: ${role}`);
        err.statusCode = 400;
        throw err;
      }

      // Sadece super_user birini super_user veya service_user yapabilir
      if ((role === 'super_user' || role === 'service_user') && (!currentUser || currentUser.role !== 'super_user')) {
        const err = new Error('Süper Kullanıcı veya Servis Sorumlusu rolü atama yetkisi yalnızca Süper Yöneticilere aittir.');
        err.statusCode = 403;
        throw err;
      }
    }

    const updates = [];
    const params = [];
    let paramIdx = 1;

    if (full_name !== undefined) {
      updates.push(`full_name = $${paramIdx++}`);
      params.push(String(full_name).trim());
    }

    if (phone !== undefined) {
      updates.push(`phone = $${paramIdx++}`);
      params.push(phone ? String(phone).trim() : null);
    }

    if (role !== undefined) {
      updates.push(`role = $${paramIdx++}`);
      params.push(role);
    }

    if (is_active !== undefined) {
      updates.push(`is_active = $${paramIdx++}`);
      params.push(Boolean(is_active));
    }

    if (admin_notes !== undefined) {
      updates.push(`admin_notes = $${paramIdx++}`);
      params.push(admin_notes ? String(admin_notes).trim() : null);
    }

    if (password !== undefined && String(password).trim().length > 0) {
      if (String(password).length < 6) {
        const err = new Error('Şifre en az 6 karakter olmalıdır.');
        err.statusCode = 400;
        throw err;
      }
      const salt = await bcrypt.genSalt(10);
      const passwordHash = await bcrypt.hash(password, salt);
      updates.push(`password_hash = $${paramIdx++}`);
      params.push(passwordHash);
    }

    updates.push(`updated_at = CURRENT_TIMESTAMP`);

    params.push(userId);
    const updateQuery = `
      UPDATE users 
      SET ${updates.join(', ')}
      WHERE id = $${paramIdx}
      RETURNING id, email, full_name, phone, role, is_active, created_at, updated_at, admin_notes
    `;

    const updateRes = await db.query(updateQuery, params);
    return updateRes.rows[0];
  }

  /**
   * Kullanıcıyı siler veya pasife alır
   */
  async deleteUser(userId, { currentUser, hardDelete = false }) {
    // Kendini silemez
    if (currentUser && currentUser.id === userId) {
      const err = new Error('Kendi hesabınızı bu menüden silemezsiniz.');
      err.statusCode = 400;
      throw err;
    }

    const existingRes = await db.query('SELECT * FROM users WHERE id = $1', [userId]);
    if (existingRes.rows.length === 0) {
      const err = new Error('Silinecek kullanıcı bulunamadı.');
      err.statusCode = 404;
      throw err;
    }

    const targetUser = existingRes.rows[0];

    // Yetki kontrolü
    if (targetUser.role === 'super_user') {
      if (!currentUser || currentUser.role !== 'super_user') {
        const err = new Error('Süper Kullanıcı hesaplarını yalnızca başka bir Süper Yönetici silebilir.');
        err.statusCode = 403;
        throw err;
      }
    }

    if (targetUser.role === 'service_user' && (!currentUser || currentUser.role !== 'super_user')) {
      const err = new Error('Servis Sorumlularını yalnızca Süper Yöneticiler silebilir.');
      err.statusCode = 403;
      throw err;
    }

    if (hardDelete) {
      await db.query('DELETE FROM users WHERE id = $1', [userId]);
      return { success: true, message: `Kullanıcı (${targetUser.email}) veritabanından kalıcı olarak silindi.` };
    } else {
      // Soft-delete (pasife al)
      await db.query('UPDATE users SET is_active = FALSE, updated_at = CURRENT_TIMESTAMP WHERE id = $1', [userId]);
      return { success: true, message: `Kullanıcı (${targetUser.email}) pasife alındı ve oturumu donduruldu.` };
    }
  }

  /**
   * Süper Yönetici için genel sistem ve servis özet istatistiklerini getirir
   */
  async getServiceSummary() {
    const countsRes = await db.query(`
      SELECT 
        COUNT(*) FILTER (WHERE role = 'super_user') as total_super_users,
        COUNT(*) FILTER (WHERE role = 'service_user') as total_service_users,
        COUNT(*) FILTER (WHERE role = 'user') as total_regular_users,
        COUNT(*) as total_users
      FROM users
    `);

    const homesRes = await db.query(`SELECT COUNT(*) as total_homes FROM homes`);
    
    const devicesRes = await db.query(`
      SELECT 
        COUNT(*) as total_devices,
        COUNT(*) FILTER (WHERE is_claimed = TRUE) as claimed_devices,
        COUNT(*) FILTER (WHERE is_commissioned = TRUE) as commissioned_devices,
        COUNT(*) FILTER (WHERE is_commissioned = FALSE AND is_claimed = TRUE) as pending_commissioning
      FROM devices
    `);

    return {
      users: {
        total_users: parseInt(countsRes.rows[0].total_users, 10),
        super_users: parseInt(countsRes.rows[0].total_super_users, 10),
        service_users: parseInt(countsRes.rows[0].total_service_users, 10),
        regular_users: parseInt(countsRes.rows[0].total_regular_users, 10),
      },
      homes: {
        total_homes: parseInt(homesRes.rows[0].total_homes, 10),
      },
      devices: {
        total_devices: parseInt(devicesRes.rows[0].total_devices, 10),
        claimed_devices: parseInt(devicesRes.rows[0].claimed_devices, 10),
        commissioned_devices: parseInt(devicesRes.rows[0].commissioned_devices, 10),
        pending_commissioning: parseInt(devicesRes.rows[0].pending_commissioning, 10),
      },
    };
  }
}

module.exports = new AdminUserService();
