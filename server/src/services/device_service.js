// ==============================================================================
// AHBU Akıllı Ev & Bina Otomasyonu - Cihaz Servisi (Faz 4.2 & Faz 6.3)
// ==============================================================================

const crypto = require('crypto');
const db = require('../db');
const mqttBridge = require('../mqtt_bridge');
const authService = require('./auth_service');

class DeviceService {
  /**
   * SHA-256 PIN hash yardımcı fonksiyonu
   */
  hashPin(pin) {
    return crypto.createHash('sha256').update(String(pin).trim()).digest('hex');
  }

  /**
   * FAZ 6.3: Cihaz Sahiplenme Doğrulama Motoru (Sıfır-Güven & PIN Yakma)
   */
  async claimDevice({ userId, userRole, homeId, homeName, deviceUuid, setupPin, targetOwnerIdentifier }) {
    if (!deviceUuid || !setupPin) {
      const err = new Error('Cihaz UUID (deviceUuid / uid) ve 6 haneli Kurulum PIN (setupPin / pin) zorunludur.');
      err.statusCode = 400;
      throw err;
    }

    if (targetOwnerIdentifier) {
      let role = userRole;
      if (!role && userId) {
        const callerRes = await db.query('SELECT role FROM users WHERE id = $1', [userId]);
        if (callerRes.rows.length > 0) role = callerRes.rows[0].role;
      }
      if (role !== 'service_user') {
        const err = new Error('Başkası / Ev Sahibi adına cihaz sahiplendirme işlemi yalnızca Yetkili Servis Sorumlusu (service_user) tarafından yapılabilir.');
        err.statusCode = 403;
        throw err;
      }
    }

    const cleanUuid = String(deviceUuid).trim().toUpperCase();
    const cleanPin = String(setupPin).trim();

    // 1. Cihazı envanter tablosunda (device_inventory) ara
    const invRes = await db.query(
      `SELECT id, device_uuid, mac_address, pin_hash, model, status, failed_attempts, locked_until, claimed_home_id
       FROM device_inventory 
       WHERE device_uuid = $1`,
      [cleanUuid]
    );

    // Eğer envanterde yoksa legacy devices tablosunda ara (geriye dönük uyumluluk)
    let invRecord = invRes.rows.length > 0 ? invRes.rows[0] : null;

    if (!invRecord) {
      // Legacy devices tablosu kontrolü
      const legacyRes = await db.query(
        'SELECT * FROM devices WHERE device_uuid = $1',
        [cleanUuid]
      );
      if (legacyRes.rows.length === 0) {
        const err = new Error(`Bu cihaz envanterde kayıtlı değil (${cleanUuid}). Kaçak veya sahte donanım.`);
        err.statusCode = 404;
        throw err;
      }
    }

    // 2. Envanter tablosunda varsa Sıfır-Güven kontrollerini uygula
    if (invRecord) {
      // 2.1. İptal / Askıya alınmış cihaz kontrolü
      if (invRecord.status === 'REVOKED') {
        const err = new Error('Bu cihaz arıza veya iade gerekçesiyle iptal edilmiştir. Lütfen yetkili servis ile iletişime geçin.');
        err.statusCode = 403;
        throw err;
      }
      if (invRecord.status === 'SUSPENDED') {
        const err = new Error('Bu cihaz süper yönetici tarafından askıya alınmıştır. Kurulum ve sahiplenme yapılamaz.');
        err.statusCode = 403;
        throw err;
      }

      // 2.2. Zaten sahiplenilmiş mi?
      if (invRecord.status === 'CLAIMED') {
        const err = new Error('Bu cihaz zaten bir daireye tanımlanmış ve sahiplenilmiştir. Tekrar sahiplenilemez.');
        err.statusCode = 409;
        throw err;
      }

      // 2.3. Brute-Force Kilit Kontrolü (15 dk kilit)
      if (invRecord.locked_until && new Date(invRecord.locked_until) > new Date()) {
        const remainingMinutes = Math.ceil((new Date(invRecord.locked_until) - new Date()) / 60000);
        const err = new Error(`Çok fazla hatalı PIN denemesi yapıldı. Cihaz kilitlendi, lütfen ${remainingMinutes} dakika sonra tekrar deneyin.`);
        err.statusCode = 429;
        throw err;
      }

      // 2.4. PIN Doğrulaması (SHA-256)
      const inputPinHash = this.hashPin(cleanPin);
      if (inputPinHash !== invRecord.pin_hash) {
        const newFailed = (invRecord.failed_attempts || 0) + 1;
        let lockQuery = 'UPDATE device_inventory SET failed_attempts = $1 WHERE id = $2';
        let lockParams = [newFailed, invRecord.id];

        if (newFailed >= 5) {
          lockQuery = "UPDATE device_inventory SET failed_attempts = $1, locked_until = NOW() + INTERVAL '15 minutes' WHERE id = $2";
        }

        await db.query(lockQuery, lockParams);

        const remainingAttempts = Math.max(0, 5 - newFailed);
        const err = new Error(
          newFailed >= 5
            ? '5 kez hatalı PIN girildi! Cihaz güvenlik nedeniyle 15 dakika kilitlendi.'
            : `Geçersiz Kurulum PIN kodu! Kalan deneme hakkı: ${remainingAttempts}`
        );
        err.statusCode = 403;
        throw err;
      }
    }

    // ADIM 11: Yetkili Servis Sorumlusu Devreye Alma (Provisioning) Kontrolü
    let effectiveOwnerId = userId;
    let isTechnicianProvisioning = false;

    if (targetOwnerIdentifier) {
      isTechnicianProvisioning = true;
      const cleanTarget = String(targetOwnerIdentifier).trim().toLowerCase();
      let targetUserRes = await db.query(
        'SELECT id, email, full_name, phone FROM users WHERE LOWER(email) = $1 OR phone = $2',
        [cleanTarget, targetOwnerIdentifier.trim()]
      );

      if (targetUserRes.rows.length === 0) {
        const bcrypt = require('bcryptjs');
        const defaultHash = await bcrypt.hash('Ahbu2026!Ev', 10);
        const namePart = cleanTarget.includes('@') ? cleanTarget.split('@')[0] : 'Ev Sahibi';
        const isEmail = cleanTarget.includes('@');
        targetUserRes = await db.query(
          `INSERT INTO users (full_name, email, password_hash, phone, is_active)
           VALUES ($1, $2, $3, $4, TRUE)
           RETURNING id, email, full_name`,
          [
            namePart.charAt(0).toUpperCase() + namePart.slice(1),
            isEmail ? cleanTarget : `user_${Math.floor(1000 + Math.random() * 9000)}@ahbu.com`,
            defaultHash,
            !isEmail ? targetOwnerIdentifier.trim() : null,
          ]
        );
      }
      effectiveOwnerId = targetUserRes.rows[0].id;
    }

    // 3. Hedef Dairenin (Home) Belirlenmesi veya Otomatik Oluşturulması
    let targetHomeId = homeId;

    if (!targetHomeId) {
      // Müşterinin mevcut evi var mı?
      const userHomes = await db.query(
        `SELECT h.id, h.name FROM homes h 
         JOIN home_users hu ON h.id = hu.home_id 
         WHERE hu.user_id = $1 AND hu.role = 'owner' LIMIT 1`,
        [effectiveOwnerId]
      );

      if (userHomes.rows.length > 0) {
        targetHomeId = userHomes.rows[0].id;
      } else {
        // Otomatik yeni ev oluştur
        const chosenName = homeName ? String(homeName).trim() : 'Evim';
        const mqttUser = `home_${Math.floor(1000 + Math.random() * 9000)}`;
        const newHomeRes = await db.query(
          `INSERT INTO homes (name, address, mqtt_username) VALUES ($1, 'Otomatik Kayıt', $2) RETURNING id, name, mqtt_username`,
          [chosenName, mqttUser]
        );
        targetHomeId = newHomeRes.rows[0].id;

        // Müşteriyi bu eve 'owner' olarak ata
        await db.query(
          `INSERT INTO home_users (home_id, user_id, role) VALUES ($1, $2, 'owner')`,
          [targetHomeId, effectiveOwnerId]
        );
      }
    } else if (!isTechnicianProvisioning) {
      // Belirtilen ev için kullanıcının yetkisini doğrula
      const memberCheck = await db.query(
        'SELECT role FROM home_users WHERE home_id = $1 AND user_id = $2',
        [targetHomeId, userId]
      );

      if (memberCheck.rows.length === 0 || memberCheck.rows[0].role !== 'owner') {
        const err = new Error('Cihaz sahiplenme işlemini yalnızca daire sahibi (owner) yapabilir.');
        err.statusCode = 403;
        throw err;
      }
    }

    // 4. Cihazı Envanter Tablosunda CLAIMED Yap ve PIN'İ KALICI OLARAK YAK (İmha Et)
    if (invRecord) {
      await db.query(
        `UPDATE device_inventory 
         SET status = 'CLAIMED', 
             claimed_home_id = $1, 
             claimed_by_user_id = $2, 
             claimed_at = CURRENT_TIMESTAMP,
             failed_attempts = 0,
             locked_until = NULL,
             pin_hash = 'CLAIMED_BURNED_PIN' -- PIN YAKILDI, TEKRAR KULLANILAMAZ
         WHERE id = $3`,
        [targetHomeId, effectiveOwnerId, invRecord.id]
      );
    }

    // 5. Cihazı devices tablosunda oluştur / güncelle
    const upsertDeviceRes = await db.query(
      `INSERT INTO devices (
        home_id, device_uuid, mac_address, setup_pin, is_claimed, claimed_at, claimed_by, model, is_online,
        is_commissioned, commissioned_at, commissioned_by, commissioning_status
      ) VALUES ($1, $2, $3, 'CLAIMED', TRUE, CURRENT_TIMESTAMP, $4, $5, TRUE, $6, CURRENT_TIMESTAMP, $7, $8)
      ON CONFLICT (device_uuid) DO UPDATE 
      SET home_id = EXCLUDED.home_id,
          is_claimed = TRUE,
          claimed_at = CURRENT_TIMESTAMP,
          claimed_by = EXCLUDED.claimed_by,
          setup_pin = 'CLAIMED',
          is_commissioned = EXCLUDED.is_commissioned,
          commissioned_at = EXCLUDED.commissioned_at,
          commissioned_by = EXCLUDED.commissioned_by,
          commissioning_status = EXCLUDED.commissioning_status,
          updated_at = CURRENT_TIMESTAMP
      RETURNING id, home_id, device_uuid, mac_address, model, firmware_version, is_claimed, claimed_at, is_commissioned, commissioning_status`,
      [
        targetHomeId,
        cleanUuid,
        invRecord ? invRecord.mac_address : 'E8:F6:0A:DD:87:54',
        effectiveOwnerId,
        invRecord ? invRecord.model : 'ESP32-S3-POE-ETH-8DI-8RO',
        isTechnicianProvisioning,
        isTechnicianProvisioning ? userId : null,
        isTechnicianProvisioning ? 'APPROVED_WORKING' : 'PENDING_INSTALLATION',
      ]
    );

    const claimedDevice = upsertDeviceRes.rows[0];

    // 6. Cihaza ait varsayılan 16 kanalı (endpoints) otomatik tanımla
    const epCount = await db.query('SELECT COUNT(*) FROM endpoints WHERE device_id = $1', [claimedDevice.id]);
    if (parseInt(epCount.rows[0].count, 10) === 0) {
      for (let ch = 1; ch <= 16; ch++) {
        const isShutter = ch === 1 || ch === 2;
        const type = isShutter ? 'shutter' : 'light';
        const pair = isShutter ? 1 : null;
        const name = isShutter ? (ch === 1 ? 'Salon Panjur Yukarı' : 'Salon Panjur Aşağı') : `Röle Kanalı ${ch}`;
        const room = isShutter ? 'Salon' : 'Genel';

        await db.query(
          `INSERT INTO endpoints (home_id, device_id, channel_index, name, type, room, shutter_pair_index, shutter_duration_sec)
           VALUES ($1, $2, $3, $4, $5, $6, $7, 20)
           ON CONFLICT (device_id, channel_index) DO NOTHING`,
          [targetHomeId, claimedDevice.id, ch, name, type, room, pair]
        );
      }
    }

    // 7. Güncel daire ve kanal bilgilerini çek
    const homeInfo = await db.query('SELECT id, name, mqtt_username FROM homes WHERE id = $1', [targetHomeId]);
    const endpoints = await db.query('SELECT * FROM endpoints WHERE device_id = $1 ORDER BY channel_index ASC', [claimedDevice.id]);

    return {
      home: homeInfo.rows[0],
      device: claimedDevice,
      endpoints: endpoints.rows,
    };
  }

  async getDevicesByHome(homeId) {
    const res = await db.query(
      `SELECT id, home_id, device_uuid, mac_address, model, firmware_version, ip_address, is_online, last_seen_at
       FROM devices
       WHERE home_id = $1`,
      [homeId]
    );
    return res.rows;
  }

  async sendCommand(homeId, deviceId, command) {
    const homeRes = await db.query(
      `SELECT h.mqtt_username, d.mac_address 
       FROM homes h
       JOIN devices d ON h.id = d.home_id
       WHERE h.id = $1 AND d.id = $2`,
      [homeId, deviceId]
    );

    if (homeRes.rows.length === 0) {
      const err = new Error('Cihaz belirtilen daireye ait değil');
      err.statusCode = 404;
      throw err;
    }

    const { mqtt_username } = homeRes.rows[0];
    return await mqttBridge.publishCommand(mqtt_username, command);
  }

  /**
   * ADIM 13: Ulaşılamayan Kiracı / Acil Servis Sıfırlaması (Service User Emergency Reset)
   * Yetkili Servis Sorumlusu veya Süper Yönetici tarafından çağrılır.
   */
  async emergencyReset({ serviceUserId, installerUserId, deviceUuid, reason, newOwnerIdentifier }) {
    const executingUserId = serviceUserId || installerUserId;
    if (!deviceUuid || !reason) {
      const err = new Error('Cihaz UUID (deviceUuid) ve sıfırlama gerekçesi (reason) zorunludur.');
      err.statusCode = 400;
      throw err;
    }

    const cleanUuid = String(deviceUuid).trim().toUpperCase();

    // 1. Cihazı bul (devices ve device_inventory tablolarından)
    const devRes = await db.query(
      `SELECT d.id, d.home_id, d.device_uuid, d.is_claimed, d.claimed_by, h.name as home_name
       FROM devices d
       LEFT JOIN homes h ON h.id = d.home_id
       WHERE d.device_uuid = $1`,
      [cleanUuid]
    );

    const invRes = await db.query(
      `SELECT id, device_uuid, status, claimed_home_id, claimed_by_user_id
       FROM device_inventory
       WHERE device_uuid = $1`,
      [cleanUuid]
    );

    if (devRes.rows.length === 0 && invRes.rows.length === 0) {
      const err = new Error('Cihaz bulunamadı');
      err.statusCode = 404;
      throw err;
    }

    const device = devRes.rows.length > 0 ? devRes.rows[0] : null;
    const invRecord = invRes.rows.length > 0 ? invRes.rows[0] : null;
    const homeId = (device && device.home_id) || (invRecord && invRecord.claimed_home_id);

    let oldUserIds = [];
    let newUserId = null;
    let newOwnerUser = null;

    if (newOwnerIdentifier) {
      const cleanIdent = String(newOwnerIdentifier).trim().toLowerCase();
      const userRes = await db.query(
        `SELECT id, email, phone, full_name FROM users WHERE LOWER(email) = $1 OR phone = $1`,
        [cleanIdent]
      );
      if (userRes.rows.length === 0) {
        const err = new Error(`Yeni sahip olarak belirtilen "${newOwnerIdentifier}" kullanıcısı sistemde kayıtlı değil.`);
        err.statusCode = 404;
        throw err;
      }
      newOwnerUser = userRes.rows[0];
      newUserId = newOwnerUser.id;
    }

    await db.query('BEGIN');
    try {
      if (homeId) {
        // Eski kullanıcıların ID'lerini topla (oturumlarını iptal etmek için)
        const oldUsersRes = await db.query(
          `SELECT user_id FROM home_users WHERE home_id = $1`,
          [homeId]
        );
        oldUserIds = oldUsersRes.rows.map(r => r.user_id);

        // Eski ailenin tüm üyelerini sil
        await db.query(`DELETE FROM home_users WHERE home_id = $1`, [homeId]);
        // Varsa bekleyen davetiyeleri ve transferleri sil
        await db.query(`DELETE FROM home_invitations WHERE home_id = $1`, [homeId]);
        await db.query(
          `UPDATE home_transfers SET status = 'CANCELLED' WHERE home_id = $1 AND status = 'PENDING'`,
          [homeId]
        );

        if (newUserId) {
          // Yeni sahibini ekle
          await db.query(
            `INSERT INTO home_users (home_id, user_id, role) VALUES ($1, $2, 'owner')`,
            [homeId, newUserId]
          );
        }
      }

      const defaultPinHash = 'ba3253876aed6bc22d4a6ff53d8406c6ad864195ed144ab5c87621b6c233b548'; // '123456'

      if (invRecord) {
        if (newUserId && homeId) {
          await db.query(
            `UPDATE device_inventory
             SET status = 'CLAIMED',
                 claimed_home_id = $1,
                 claimed_by_user_id = $2,
                 claimed_at = CURRENT_TIMESTAMP,
                 failed_attempts = 0,
                 locked_until = NULL
             WHERE id = $3`,
            [homeId, newUserId, invRecord.id]
          );
        } else {
          await db.query(
            `UPDATE device_inventory
             SET status = 'IN_STOCK',
                 claimed_home_id = NULL,
                 claimed_by_user_id = NULL,
                 claimed_at = NULL,
                 failed_attempts = 0,
                 locked_until = NULL,
                 pin_hash = $1
             WHERE id = $2`,
            [defaultPinHash, invRecord.id]
          );
        }
      }

      if (device) {
        if (newUserId && homeId) {
          await db.query(
            `UPDATE devices
             SET claimed_by = $1,
                 is_claimed = TRUE,
                 claimed_at = CURRENT_TIMESTAMP,
                 updated_at = CURRENT_TIMESTAMP
             WHERE id = $2`,
            [newUserId, device.id]
          );
        } else {
          await db.query(
            `UPDATE devices
             SET is_claimed = FALSE,
                 claimed_by = NULL,
                 claimed_at = NULL,
                 setup_pin = '123456',
                 home_id = NULL,
                 updated_at = CURRENT_TIMESTAMP
             WHERE id = $1`,
            [device.id]
          );
        }
      }

      // Log kaydı oluştur
      await db.query(
        `INSERT INTO emergency_reset_logs (
           device_uuid, home_id, installer_user_id, reason, new_owner_identifier, previous_owner_ids
         ) VALUES ($1, $2, $3, $4, $5, $6)`,
        [
          cleanUuid,
          homeId || null,
          executingUserId,
          reason,
          newOwnerIdentifier || null,
          JSON.stringify(oldUserIds),
        ]
      );

      await db.query('COMMIT');

      // Eski kullanıcı oturumlarını sonlandır
      for (const oldUid of oldUserIds) {
        try {
          await authService.revokeAllUserSessions(oldUid);
        } catch (_) {}
      }

      return {
        success: true,
        message: newUserId
          ? `Cihaz (${cleanUuid}) acil durum prosedürüyle ${newOwnerUser.full_name} kullanıcısına devredildi. Eski ailenin tüm oturumları sonlandırıldı.`
          : `Cihaz (${cleanUuid}) başarıyla fabrika/stok durumuna sıfırlandı. PIN varsayılan (123456) değerine alındı ve eski ailenin yetkileri azledildi.`,
        action: newUserId ? 'REASSIGNED' : 'UNCLAIMED',
        deviceUuid: cleanUuid,
        homeId: homeId || null,
        affectedUsersCount: oldUserIds.length,
      };
    } catch (e) {
      await db.query('ROLLBACK');
      throw e;
    }
  }

  /**
   * ADIM 16: Sistem Doktoru (Self-Diagnostic)
   * 3 Katmanlı Teşhis: [Bulut], [Ev Modemi/İnternet], [Pano Gücü]
   */
  async getSystemDiagnostic({ userId, userRole, homeId }) {
    const UUID_REGEX = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

    let role = userRole;
    if (!role && userId) {
      const uRes = await db.query('SELECT role FROM users WHERE id = $1', [userId]);
      if (uRes.rows.length > 0) role = uRes.rows[0].role;
    }
    const isGlobalStaff = role === 'super_user' || role === 'service_user';

    // Eğer homeId verilmemiş, '0' veya geçersizse:
    let resolvedHomeId = null;
    if (homeId && homeId !== '0' && homeId !== 0 && UUID_REGEX.test(String(homeId))) {
      resolvedHomeId = homeId;
    } else {
      // Kullanıcının kayıtlı bir evi var mı kontrol et
      const fallbackRes = await db.query(
        `SELECT home_id FROM home_users WHERE user_id = $1 ORDER BY created_at ASC LIMIT 1`,
        [userId]
      );
      if (fallbackRes.rows.length > 0) {
        resolvedHomeId = fallbackRes.rows[0].home_id;
      }
    }

    // 1. Daire Yetki Kontrolü
    if (resolvedHomeId) {
      if (!isGlobalStaff) {
        const permRes = await db.query(
          `SELECT role FROM home_users WHERE home_id = $1 AND user_id = $2`,
          [resolvedHomeId, userId]
        );
        if (permRes.rows.length === 0) {
          const err = new Error('Bu evin teşhis bilgilerini görüntüleme yetkiniz yok.');
          err.statusCode = 403;
          throw err;
        }
      }
    } else {
      // Dairesi yok ve global personel de değilse 404
      if (!isGlobalStaff) {
        const err = new Error('Aktif bir ev/daire kaydı bulunamadı.');
        err.statusCode = 404;
        throw err;
      }
    }

    // 2. Bulut Altyapı Kontrolü (DB Latency & MQTT Bridge)
    const startTime = Date.now();
    let dbOk = false;
    try {
      await db.query('SELECT 1');
      dbOk = true;
    } catch (_) {}
    const cloudLatencyMs = Date.now() - startTime;
    const mqttOk = mqttBridge.isConnected();
    const cloudStatus = (dbOk && mqttOk) ? 'OK' : 'DEGRADED';

    // Dairesiz genel sistem teşhisi (Süper Yönetici veya genel personel durumu)
    if (!resolvedHomeId) {
      return {
        cloud: {
          status: cloudStatus,
          latency_ms: cloudLatencyMs,
          db_connected: dbOk,
          mqtt_bridge_connected: mqttOk,
        },
        home_network: {
          status: 'SKIPPED',
          device_ip: null,
          last_seen_at: null,
          seconds_since_last_seen: null,
        },
        hardware_power: {
          status: 'SKIPPED',
          is_online: false,
        },
        endpoint_count: 0,
        diagnosis_title: cloudStatus === 'OK' ? 'Sistem Altyapısı Sağlıklı' : 'Altyapı Kesintisi / Bozulma',
        diagnosis_summary: cloudStatus === 'OK'
          ? 'PostgreSQL veritabanı ve EMQX MQTT köprüsü aktif ve canlı çalışıyor.'
          : 'Veritabanı veya MQTT köprüsünde gecikme ya da bağlantı kesintisi tespit edildi.',
        diagnosis_level: cloudStatus === 'OK' ? 'ok' : 'error',
        action_recommendation: cloudStatus === 'OK' ? null : 'PM2 ve sunucu servislerini kontrol edin.',
      };
    }

    homeId = resolvedHomeId;

    // 3. Daireye Bağlı Pano Bilgisi
    const devRes = await db.query(
      `SELECT d.id, d.device_uuid, d.mac_address, d.model, d.firmware_version,
              d.ip_address, d.last_seen_at, d.is_online, h.name as home_name
       FROM devices d
       JOIN homes h ON h.id = d.home_id
       WHERE d.home_id = $1
       ORDER BY d.last_seen_at DESC NULLS LAST
       LIMIT 1`,
      [homeId]
    );

    const endpointRes = await db.query(
      `SELECT count(*) as count FROM endpoints WHERE home_id = $1`,
      [homeId]
    );
    const endpointCount = parseInt(endpointRes.rows[0]?.count || '0', 10);

    if (devRes.rows.length === 0) {
      return {
        cloud: {
          status: cloudStatus,
          latency_ms: cloudLatencyMs,
          db_connected: dbOk,
          mqtt_bridge_connected: mqttOk,
        },
        home_network: {
          status: 'UNCLAIMED',
          device_ip: null,
          last_seen_at: null,
          seconds_since_last_seen: null,
        },
        hardware_power: {
          status: 'UNCLAIMED',
          is_online: false,
        },
        endpoint_count: endpointCount,
        diagnosis_title: 'Daireye Henüz Pano Bağlanmamış',
        diagnosis_summary: 'Bu daireye henüz bir otomasyon panosu tanımlanmamış. Yeni pano kurulumu için karekod taratın.',
        diagnosis_level: 'warning',
        action_recommendation: 'Ana ekrandaki "Cihaz Ekle (Karekod Tara)" seçeneğini kullanarak panonuzu dairenize tanıtın.',
      };
    }

    const device = devRes.rows[0];
    const now = Date.now();
    const lastSeenMs = device.last_seen_at ? new Date(device.last_seen_at).getTime() : 0;
    const secondsSinceLastSeen = lastSeenMs > 0 ? Math.floor((now - lastSeenMs) / 1000) : null;

    let networkStatus = 'OFFLINE';
    let powerStatus = 'SUSPECTED_OFFLINE_OR_POWER_OUTAGE';
    let diagnosisLevel = 'error'; // ok, warning, error
    let diagnosisTitle = 'Pano Çevrimdışı';
    let diagnosisSummary = '';
    let actionRecommendation = '';

    if (secondsSinceLastSeen !== null && secondsSinceLastSeen <= 120) {
      networkStatus = 'OK';
      powerStatus = 'OK';
      diagnosisLevel = 'ok';
      diagnosisTitle = 'Tüm Sistemler Sağlıklı ve Çevrimiçi';
      diagnosisSummary = 'Bulut sunucu, ev modemi ve pano donanımı kesintisiz haberleşiyor. Herhangi bir arıza bulunamadı.';
      actionRecommendation = null;
    } else if (secondsSinceLastSeen !== null && secondsSinceLastSeen <= 300) {
      networkStatus = 'WARNING';
      powerStatus = 'OK';
      diagnosisLevel = 'warning';
      diagnosisTitle = 'Zayıf veya Gecikmeli Wi-Fi Bağlantısı';
      diagnosisSummary = `Pano en son ${secondsSinceLastSeen} saniye önce görüldü. İnternet paketlerinde gecikme yaşanıyor olabilir.`;
      actionRecommendation = 'Modem ile panonun sinyal kalitesini kontrol edin veya modemi yeniden başlatın.';
    } else {
      networkStatus = 'OFFLINE';
      powerStatus = 'SUSPECTED_OFFLINE_OR_POWER_OUTAGE';
      diagnosisLevel = 'error';
      diagnosisTitle = 'Pano Çevrimdışı (Ev İnterneti veya Güç Kesik)';
      diagnosisSummary = `Pano ${secondsSinceLastSeen ? Math.round(secondsSinceLastSeen / 60) + ' dakikadır' : 'uzun süredir'} bulut sunucuya sinyal gönderemiyor.`;
      actionRecommendation = 
        '1. Pano sigortasının açık olduğundan ve adaptör üzerindeki LED ışığının yandığından emin olun.\n' +
        '2. Evdeki Wi-Fi modeminizi kontrol edin (İnternet ışıkları normal mi).\n' +
        '3. Modem adı veya şifresi değiştiyse "Wi-Fi Kurtarma Sihirbazı" ile yeni şifreyi panoya yükleyin.';
    }

    return {
      cloud: {
        status: cloudStatus,
        latency_ms: cloudLatencyMs,
        db_connected: dbOk,
        mqtt_bridge_connected: mqttOk,
      },
      home_network: {
        status: networkStatus,
        device_ip: device.ip_address,
        last_seen_at: device.last_seen_at,
        seconds_since_last_seen: secondsSinceLastSeen,
      },
      hardware_power: {
        status: powerStatus,
        is_online: device.is_online || (secondsSinceLastSeen !== null && secondsSinceLastSeen <= 120),
        device_uuid: device.device_uuid,
        mac_address: device.mac_address,
        model: device.model,
        firmware_version: device.firmware_version,
      },
      endpoint_count: endpointCount,
      diagnosis_title: diagnosisTitle,
      diagnosis_summary: diagnosisSummary,
      diagnosis_level: diagnosisLevel,
      action_recommendation: actionRecommendation,
    };
  }

  /**
   * ADIM 16: Felaket Kurtarma (Disaster Recovery) - Tek Tıkla Pano Değişimi
   * Arızalanan/yanan panonun yerine takılan yeni boş karta dairenin tüm
   * oda isimlerini, röle konfigürasyonunu ve panjur sürelerini 5 saniyede aktarır.
   */
  async replaceBoard({ userId, homeId, oldDeviceUuid, newDeviceUuid, setupPin, reason }) {
    const UUID_REGEX = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

    if (!homeId || homeId === '0' || homeId === 0 || !UUID_REGEX.test(String(homeId))) {
      const fallbackRes = await db.query(
        `SELECT home_id FROM home_users WHERE user_id = $1 ORDER BY created_at ASC LIMIT 1`,
        [userId]
      );
      if (fallbackRes.rows.length > 0) {
        homeId = fallbackRes.rows[0].home_id;
      }
    }

    if (!homeId || !newDeviceUuid || !setupPin) {
      const err = new Error('homeId, yeni cihaz UUID (newDeviceUuid) ve Kurulum PIN (setupPin) zorunludur.');
      err.statusCode = 400;
      throw err;
    }

    const cleanNewUuid = String(newDeviceUuid).trim().toUpperCase();
    const cleanOldUuid = oldDeviceUuid ? String(oldDeviceUuid).trim().toUpperCase() : null;
    const cleanPin = String(setupPin).trim();

    // 1. Yetki Kontrolü: Ev Sahibi (owner) veya Yetkili Servis (service_user) yapabilir (super_user'dan alındı)
    const globalUserRes = await db.query(`SELECT role FROM users WHERE id = $1`, [userId]);
    const isGlobalStaff = globalUserRes.rows.length > 0 && globalUserRes.rows[0].role === 'service_user';

    if (!isGlobalStaff) {
      const userRoleRes = await db.query(
        `SELECT role FROM home_users WHERE home_id = $1 AND user_id = $2`,
        [homeId, userId]
      );
      if (userRoleRes.rows.length === 0 || !['owner', 'service_user'].includes(userRoleRes.rows[0].role)) {
        const err = new Error('Bu felaket kurtarma işlemini yalnızca Ev Sahibi veya Yetkili Servis Sorumlusu yürütebilir.');
        err.statusCode = 403;
        throw err;
      }
    }

    // 2. Yeni cihazı envanterde doğrula
    const invRes = await db.query(
      `SELECT id, device_uuid, mac_address, pin_hash, status 
       FROM device_inventory 
       WHERE device_uuid = $1`,
      [cleanNewUuid]
    );
    if (invRes.rows.length === 0) {
      const err = new Error(`Yeni pano envanterde kayıtlı değil (${cleanNewUuid}). Lütfen fabrika barkodunu kontrol edin.`);
      err.statusCode = 404;
      throw err;
    }
    const newInv = invRes.rows[0];

    if (newInv.status === 'REVOKED') {
      const err = new Error('Bu yeni pano arıza veya iade gerekçesiyle iptal edilmiştir.');
      err.statusCode = 403;
      throw err;
    }
    if (newInv.status === 'CLAIMED') {
      const err = new Error('Bu pano zaten başka bir daireye tanımlanmış. Lütfen sıfır/stokta bir kart kullanın.');
      err.statusCode = 409;
      throw err;
    }

    // PIN kontrolü
    const inputPinHash = this.hashPin(cleanPin);
    if (inputPinHash !== newInv.pin_hash) {
      const err = new Error('Yeni panonun Kurulum PIN kodu hatalı!');
      err.statusCode = 403;
      throw err;
    }

    // 3. Mevcut (eski) cihazı bul
    let oldDevice = null;
    if (cleanOldUuid) {
      const oldDevRes = await db.query(
        `SELECT id, device_uuid, mac_address, home_id FROM devices WHERE device_uuid = $1 AND home_id = $2`,
        [cleanOldUuid, homeId]
      );
      if (oldDevRes.rows.length > 0) oldDevice = oldDevRes.rows[0];
    }
    if (!oldDevice) {
      const curDevRes = await db.query(
        `SELECT id, device_uuid, mac_address, home_id FROM devices WHERE home_id = $1 LIMIT 1`,
        [homeId]
      );
      if (curDevRes.rows.length > 0) oldDevice = curDevRes.rows[0];
    }

    if (!oldDevice) {
      const err = new Error('Bu daireye bağlı değiştirilecek eski bir pano bulunamadı.');
      err.statusCode = 404;
      throw err;
    }

    // 4. Mevcut uç noktaların (endpoints) yedeğini al
    const endpointsRes = await db.query(
      `SELECT channel_index, name, type, room, shutter_pair_index, shutter_duration_sec, current_state, current_position
       FROM endpoints
       WHERE home_id = $1 AND device_id = $2
       ORDER BY channel_index ASC`,
      [homeId, oldDevice.id]
    );
    const oldEndpoints = endpointsRes.rows;

    // Snapshot hazırla
    const snapshot = {
      replaced_at: new Date().toISOString(),
      old_device_uuid: oldDevice.device_uuid,
      new_device_uuid: cleanNewUuid,
      reason: reason || 'Fiziksel hasar / Pano değişimi',
      endpoints: oldEndpoints,
    };

    // 5. Transaction ile atomik transfer
    await db.query('BEGIN');
    try {
      // 5.1. Yeni cihazı devices tablosuna ekle veya güncelle
      let newDeviceId;
      const existNewDev = await db.query(
        `SELECT id FROM devices WHERE device_uuid = $1`,
        [cleanNewUuid]
      );

      if (existNewDev.rows.length > 0) {
        newDeviceId = existNewDev.rows[0].id;
        await db.query(
          `UPDATE devices
           SET home_id = $1,
               is_claimed = TRUE,
               claimed_by = $2,
               claimed_at = CURRENT_TIMESTAMP,
               device_status = 'ACTIVE',
               config_snapshot = $3,
               updated_at = CURRENT_TIMESTAMP
           WHERE id = $4`,
          [homeId, userId, JSON.stringify(snapshot), newDeviceId]
        );
      } else {
        const insDev = await db.query(
          `INSERT INTO devices (
             home_id, device_uuid, mac_address, setup_pin, is_claimed,
             claimed_at, claimed_by, device_status, config_snapshot
           ) VALUES ($1, $2, $3, $4, TRUE, CURRENT_TIMESTAMP, $5, 'ACTIVE', $6)
           RETURNING id`,
          [
            homeId,
            cleanNewUuid,
            newInv.mac_address,
            cleanPin,
            userId,
            JSON.stringify(snapshot),
          ]
        );
        newDeviceId = insDev.rows[0].id;
      }

      // 5.2. Eski cihazı devreden çıkar
      await db.query(
        `UPDATE devices
         SET home_id = NULL,
             is_claimed = FALSE,
             device_status = 'REPLACED_DAMAGED',
             updated_at = CURRENT_TIMESTAMP
         WHERE id = $1`,
        [oldDevice.id]
      );

      // 5.3. Envanter durumlarını güncelle
      await db.query(
        `UPDATE device_inventory
         SET status = 'CLAIMED',
             claimed_home_id = $1,
             claimed_by_user_id = $2,
             claimed_at = CURRENT_TIMESTAMP
         WHERE id = $3`,
        [homeId, userId, newInv.id]
      );

      await db.query(
        `UPDATE device_inventory
         SET status = 'REVOKED'
         WHERE device_uuid = $1`,
        [oldDevice.device_uuid]
      );

      // 5.4. Tüm endpoints kayıtlarını yeni karta bağla
      await db.query(
        `UPDATE endpoints
         SET device_id = $1,
             updated_at = CURRENT_TIMESTAMP
         WHERE device_id = $2 AND home_id = $3`,
        [newDeviceId, oldDevice.id, homeId]
      );

      // 5.5. Değişim günlüğüne kaydet
      await db.query(
        `INSERT INTO device_replacement_logs (
           home_id, old_device_uuid, new_device_uuid, replaced_by_user_id,
           endpoints_migrated_count, config_snapshot, reason
         ) VALUES ($1, $2, $3, $4, $5, $6, $7)`,
        [
          homeId,
          oldDevice.device_uuid,
          cleanNewUuid,
          userId,
          oldEndpoints.length,
          JSON.stringify(snapshot),
          reason || 'Fiziksel hasar / Pano değişimi',
        ]
      );

      await db.query('COMMIT');

      // 5.6. MQTT üzerinden yeni panoya konfigürasyonu anında gönder
      try {
        const homeRes = await db.query('SELECT mqtt_username FROM homes WHERE id = $1', [homeId]);
        if (homeRes.rows.length > 0) {
          const mqttUser = homeRes.rows[0].mqtt_username;
          const configSyncPayload = {
            cmd: 'sync_full_config',
            device_uuid: cleanNewUuid,
            migrated_from: oldDevice.device_uuid,
            total_relays: oldEndpoints.length,
            relays: oldEndpoints.map(ep => ({
              channel: ep.channel_index,
              name: ep.name,
              type: ep.type,
              room: ep.room,
              shutter_duration_sec: ep.shutter_duration_sec,
            })),
          };
          mqttBridge.publish(`ahbu/${mqttUser}/config/set`, JSON.stringify(configSyncPayload));
        }
      } catch (mqErr) {
        console.warn('MQTT config set yayını hatası (pano bağlanınca çekecek):', mqErr.message);
      }

      return {
        success: true,
        message: `Pano değişimi başarıyla tamamlandı! Eski panonun (${oldDevice.device_uuid}) tüm konfigürasyonu ve ${oldEndpoints.length} röle/oda tanımı yeni panoya (${cleanNewUuid}) aktarıldı.`,
        oldDeviceUuid: oldDevice.device_uuid,
        newDeviceUuid: cleanNewUuid,
        migratedEndpointsCount: oldEndpoints.length,
        homeId,
      };
    } catch (e) {
      await db.query('ROLLBACK');
      throw e;
    }
  }

  /**
   * ADIM 17: Yazılımsal Çocuk Kilidi (Fiziksel Duvar Anahtarlarını Kilitler)
   */
  async setChildLock(homeId, enabled) {
    await db.query(
      `UPDATE homes SET child_lock_enabled = $1 WHERE id = $2`,
      [enabled, homeId]
    );

    await db.query(
      `UPDATE devices SET child_lock_enabled = $1 WHERE home_id = $2`,
      [enabled, homeId]
    );

    // MQTT üzerinden panoya bildir
    try {
      const homeRes = await db.query('SELECT mqtt_username FROM homes WHERE id = $1', [homeId]);
      if (homeRes.rows.length > 0) {
        const mqttUser = homeRes.rows[0].mqtt_username;
        const payload = JSON.stringify({
          cmd: 'set_child_lock',
          enabled: !!enabled,
          timestamp: Date.now(),
        });
        mqttBridge.publish(`ahbu/${mqttUser}/command`, payload);
      }
    } catch (mqErr) {
      console.warn('MQTT child lock yayını hatası:', mqErr.message);
    }

    return {
      success: true,
      home_id: homeId,
      child_lock_enabled: !!enabled,
      message: enabled
        ? 'Çocuk kilidi aktif! Duvardaki fiziksel anahtarlar kilitlendi, sadece telefon üzerinden kontrol edilebilir.'
        : 'Çocuk kilidi devre dışı. Duvardaki fiziksel anahtarlar normal çalışıyor.',
    };
  }

  async getChildLock(homeId) {
    const res = await db.query(
      `SELECT child_lock_enabled FROM homes WHERE id = $1`,
      [homeId]
    );
    const enabled = res.rows.length > 0 ? !!res.rows[0].child_lock_enabled : false;
    return {
      home_id: homeId,
      child_lock_enabled: enabled,
    };
  }

  /**
   * ADIM 17: Gece Huzur Bildirimi Ayarları ve Durumu
   */
  async getPeaceNotificationSettings(homeId) {
    const homeRes = await db.query(
      `SELECT id, name, peace_notification_enabled, peace_notification_time
       FROM homes WHERE id = $1`,
      [homeId]
    );

    if (homeRes.rows.length === 0) {
      throw new Error('Daire bulunamadı.');
    }

    const home = homeRes.rows[0];

    // Açık lambaları ve hareketli/açık panjurları say
    const openLightsRes = await db.query(
      `SELECT e.id, e.channel_index, e.name, e.room, e.state
       FROM endpoints e
       JOIN devices d ON e.device_id = d.id
       WHERE d.home_id = $1 AND e.type = 'light' AND (e.state = 'ON' OR e.state = '1' OR e.is_active = true)`,
      [homeId]
    );

    const openShuttersRes = await db.query(
      `SELECT e.id, e.channel_index, e.name, e.room, e.shutter_position
       FROM endpoints e
       JOIN devices d ON e.device_id = d.id
       WHERE d.home_id = $1 AND e.type = 'shutter' AND (e.shutter_position > 0 OR e.state = 'UP')`,
      [homeId]
    );

    const openLights = openLightsRes.rows;
    const openShutters = openShuttersRes.rows;

    let summaryText = 'Tüm lambalar kapalı, eviniz huzur modunda.';
    if (openLights.length > 0) {
      const roomCounts = {};
      openLights.forEach(l => {
        const r = l.room || 'Genel';
        roomCounts[r] = (roomCounts[r] || 0) + 1;
      });
      const roomDetails = Object.entries(roomCounts)
        .map(([r, c]) => `${r}: ${c} lamba`)
        .join(', ');
      summaryText = `Açık lamba tespit edildi (${openLights.length} adet - ${roomDetails}).`;
    }

    return {
      home_id: home.id,
      peace_notification_enabled: home.peace_notification_enabled !== false,
      peace_notification_time: home.peace_notification_time || '23:30',
      open_lights_count: openLights.length,
      open_shutters_count: openShutters.length,
      summary_text: summaryText,
      open_lights: openLights,
    };
  }

  async updatePeaceNotificationSettings(homeId, { enabled, notificationTime }) {
    const res = await db.query(
      `UPDATE homes
       SET peace_notification_enabled = COALESCE($1, peace_notification_enabled),
           peace_notification_time = COALESCE($2, peace_notification_time)
       WHERE id = $3
       RETURNING id, peace_notification_enabled, peace_notification_time`,
      [enabled, notificationTime, homeId]
    );

    if (res.rows.length === 0) {
      throw new Error('Daire bulunamadı.');
    }

    return {
      success: true,
      message: 'Gece huzur bildirimi ayarları güncellendi.',
      settings: res.rows[0],
    };
  }

  /**
   * ADIM 17: Tüm Açık Lambaları Tek Tıkla Kapat
   */
  async closeAllOpenLights(homeId, userId) {
    const openLightsRes = await db.query(
      `SELECT e.id, e.device_id, e.channel_index, e.name, e.room
       FROM endpoints e
       JOIN devices d ON e.device_id = d.id
       WHERE d.home_id = $1 AND e.type = 'light' AND (e.state = 'ON' OR e.state = '1' OR e.is_active = true)`,
      [homeId]
    );

    const count = openLightsRes.rows.length;

    // Veritabanında lambaları kapat
    await db.query(
      `UPDATE endpoints
       SET state = 'OFF', is_active = false
       WHERE device_id IN (SELECT id FROM devices WHERE home_id = $1) AND type = 'light'`,
      [homeId]
    );

    // Log kaydı oluştur
    await db.query(
      `INSERT INTO peace_notification_logs (
        home_id, open_lights_count, summary_text, resolved_by_user, resolved_at
       ) VALUES ($1, $2, $3, true, CURRENT_TIMESTAMP)`,
      [homeId, count, `${count} açık lamba tek tıkla kapatıldı.`]
    );

    // MQTT üzerinden panoya bildirim gönder
    try {
      const homeRes = await db.query('SELECT mqtt_username FROM homes WHERE id = $1', [homeId]);
      if (homeRes.rows.length > 0) {
        const mqttUser = homeRes.rows[0].mqtt_username;
        const payload = JSON.stringify({
          cmd: 'all_lights_off',
          channels: openLightsRes.rows.map(l => l.channel_index),
          timestamp: Date.now(),
        });
        mqttBridge.publish(`ahbu/${mqttUser}/command`, payload);
      }
    } catch (mqErr) {
      console.warn('MQTT all_lights_off yayını hatası:', mqErr.message);
    }

    return {
      success: true,
      closed_count: count,
      message: count > 0 
        ? `Huzur modu devrede: Açık olan ${count} lamba tek tıkla kapatıldı.`
        : 'Zaten tüm lambalar kapalıydı.',
    };
  }
}

module.exports = new DeviceService();
