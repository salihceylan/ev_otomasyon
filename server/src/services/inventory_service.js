// ==============================================================================
// AHBU Akıllı Ev & Bina Otomasyonu - Cihaz Envanter Servisi (Faz 6.2)
// ==============================================================================

const crypto = require('crypto');
const db = require('../db');

class InventoryService {
  /**
   * 6 Haneli Setup PIN'i SHA-256 ile özetler (Kriptografik Güvenlik)
   */
  hashPin(pin) {
    return crypto.createHash('sha256').update(String(pin).trim()).digest('hex');
  }

  /**
   * MAC adresini büyük harfe ve standart formata normalize eder
   */
  normalizeMac(mac) {
    if (!mac) return '';
    return mac.trim().toUpperCase().replace(/[^A-F0-9]/g, '').match(/.{1,2}/g)?.join(':') || mac.trim().toUpperCase();
  }

  /**
   * Fabrika / Atölye: Yeni bir ESP32-S3 panosunu envantere kaydeder (IN_STOCK)
   */
  async registerDevice({ device_uuid, mac_address, pin, model, batch_no }) {
    if (!device_uuid || !mac_address || !pin) {
      const err = new Error('Eksik parametre: device_uuid, mac_address ve pin zorunludur.');
      err.statusCode = 400;
      throw err;
    }

    const cleanPin = String(pin).trim();
    if (!/^\d{6}$/.test(cleanPin)) {
      const err = new Error('Geçersiz PIN: Setup PIN tam olarak 6 haneli rakam olmalıdır.');
      err.statusCode = 400;
      throw err;
    }

    const cleanUuid = String(device_uuid).trim().toUpperCase();
    const cleanMac = this.normalizeMac(mac_address);
    const pinHash = this.hashPin(cleanPin);
    const cleanModel = model ? String(model).trim() : 'ESP32-S3-POE-ETH-8DI-8RO';
    const cleanBatch = batch_no ? String(batch_no).trim() : 'BATCH-2026-01';

    // Mükerrerlik Kontrolü
    const existing = await db.query(
      'SELECT id, device_uuid, mac_address, status FROM device_inventory WHERE device_uuid = $1 OR mac_address = $2',
      [cleanUuid, cleanMac]
    );

    if (existing.rows.length > 0) {
      const row = existing.rows[0];
      const conflictField = row.device_uuid === cleanUuid ? `UUID (${cleanUuid})` : `MAC (${cleanMac})`;
      const err = new Error(`Bu cihaz zaten envanterde kayıtlı: ${conflictField} (Mevcut Durum: ${row.status})`);
      err.statusCode = 409;
      throw err;
    }

    // Envantere Ekleme (IN_STOCK)
    const insertRes = await db.query(
      `INSERT INTO device_inventory (
        device_uuid, mac_address, pin_hash, model, batch_no, status
      ) VALUES ($1, $2, $3, $4, $5, 'IN_STOCK')
      RETURNING id, serial_no, device_uuid, mac_address, model, batch_no, status, created_at`,
      [cleanUuid, cleanMac, pinHash, cleanModel, cleanBatch]
    );

    const record = insertRes.rows[0];

    // Pano kapağı ve kutu etiketi için QR Claim URL üretimi
    const qrClaimUrl = `https://evotomasyon.gudeteknoloji.com.tr/claim?uid=${encodeURIComponent(cleanUuid)}&pin=${cleanPin}`;

    return {
      device: record,
      qr_claim_url: qrClaimUrl,
      setup_pin_preview: cleanPin, // Sadece fabrika etiket basımı anında döndürülür
    };
  }

  /**
   * Envanterdeki cihazları filtreleme ve listeleme
   */
  async listInventory({ status, batch_no, limit = 50, offset = 0 } = {}) {
    let query = `
      SELECT id, serial_no, device_uuid, mac_address, model, batch_no, status, 
             failed_attempts, locked_until, claimed_at, created_at
      FROM device_inventory
      WHERE 1=1
    `;
    const params = [];

    if (status) {
      params.push(status.toUpperCase());
      query += ` AND status = $${params.length}`;
    }

    if (batch_no) {
      params.push(batch_no);
      query += ` AND batch_no = $${params.length}`;
    }

    query += ` ORDER BY serial_no DESC, created_at DESC LIMIT $${params.length + 1} OFFSET $${params.length + 2}`;
    params.push(Math.min(limit, 100), offset);

    const res = await db.query(query, params);
    const countRes = await db.query('SELECT COUNT(*) as total FROM device_inventory');

    return {
      total: parseInt(countRes.rows[0].total, 10),
      count: res.rows.length,
      items: res.rows,
    };
  }

  /**
   * Belirli bir cihazın envanter durumunu getirme
   */
  async getByUuid(device_uuid) {
    const cleanUuid = String(device_uuid).trim().toUpperCase();
    const res = await db.query(
      `SELECT id, serial_no, device_uuid, mac_address, model, batch_no, status, 
              failed_attempts, locked_until, claimed_at, created_at, updated_at
       FROM device_inventory
       WHERE device_uuid = $1`,
      [cleanUuid]
    );

    if (res.rows.length === 0) {
      const err = new Error(`Cihaz bulunamadı: ${cleanUuid}`);
      err.statusCode = 404;
      throw err;
    }

    return res.rows[0];
  }

  /**
   * Cihaz durumunu güncelleme (Askıya Al / Aktif Et / İptal Et)
   */
  async updateStatus(device_uuid, new_status) {
    const cleanUuid = String(device_uuid).trim().toUpperCase();
    const cleanStatus = String(new_status).trim().toUpperCase();
    const allowed = ['IN_STOCK', 'INSTALLED', 'CLAIMED', 'REVOKED', 'SUSPENDED'];
    if (!allowed.includes(cleanStatus)) {
      const err = new Error(`Geçersiz durum: ${cleanStatus}. İzin verilenler: ${allowed.join(', ')}`);
      err.statusCode = 400;
      throw err;
    }

    const res = await db.query(
      `UPDATE device_inventory 
       SET status = $1, updated_at = CURRENT_TIMESTAMP
       WHERE device_uuid = $2
       RETURNING id, serial_no, device_uuid, mac_address, model, batch_no, status, created_at, updated_at`,
      [cleanStatus, cleanUuid]
    );

    if (res.rows.length === 0) {
      const err = new Error(`Cihaz bulunamadı: ${cleanUuid}`);
      err.statusCode = 404;
      throw err;
    }

    return res.rows[0];
  }

  /**
   * Cihazı envanterden ve sistemden silme (Süper Yönetici)
   */
  async deleteDevice(device_uuid) {
    const cleanUuid = String(device_uuid).trim().toUpperCase();

    const checkRes = await db.query(
      'SELECT id, device_uuid, status, claimed_home_id FROM device_inventory WHERE device_uuid = $1',
      [cleanUuid]
    );

    if (checkRes.rows.length === 0) {
      const err = new Error(`Cihaz bulunamadı: ${cleanUuid}`);
      err.statusCode = 404;
      throw err;
    }

    // devices tablosundaki referansı temizle (varsa)
    await db.query('DELETE FROM devices WHERE device_uuid = $1', [cleanUuid]);

    // Envanterden sil
    await db.query('DELETE FROM device_inventory WHERE device_uuid = $1', [cleanUuid]);

    return { success: true, message: `Cihaz (${cleanUuid}) envanterden başarıyla silindi.` };
  }
}

module.exports = new InventoryService();

