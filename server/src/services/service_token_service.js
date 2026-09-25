const jwt = require('jsonwebtoken');
const db = require('../db');
const { generateNumericPin, generateRandomToken } = require('../utils/helpers');

class ServiceTokenService {
  // FAZ 4 - Adım 4.3: Ev sahibinin 2 saat geçerli teknisyen servis PIN'i üretmesi
  async createServiceToken(ownerUserId, homeId) {
    const pin = generateNumericPin(6);
    const token = generateRandomToken(24);
    const expiresAt = new Date(Date.now() + 2 * 60 * 60 * 1000); // 2 saat geçerli

    const res = await db.query(
      `INSERT INTO service_tokens (home_id, created_by, token, service_pin, expires_at)
       VALUES ($1, $2, $3, $4, $5)
       RETURNING id, home_id, service_pin, token, expires_at`,
      [homeId, ownerUserId, token, pin, expiresAt]
    );

    return {
      service_pin: res.rows[0].service_pin,
      expires_at: res.rows[0].expires_at,
      token: res.rows[0].token,
      message: '2 saat gecerli servis PIN kodu basariyla uretildi. Bu kodu panodaki kurulumcu teknisyene iletebilirsiniz.',
    };
  }

  // Kurulumcu / Teknisyenin PIN ile servis girisi yapmasi
  async loginWithServicePin(servicePin, technicianEmail = 'teknisyen@gudeteknoloji.com.tr', technicianName = 'Saha Montaj Teknisyeni') {
    const tokenRes = await db.query(
      `SELECT st.*, h.name as home_name, h.mqtt_username
       FROM service_tokens st
       JOIN homes h ON st.home_id = h.id
       WHERE st.service_pin = $1 AND st.is_used = FALSE AND st.expires_at > CURRENT_TIMESTAMP`,
      [servicePin]
    );

    if (tokenRes.rows.length === 0) {
      const err = new Error('Gecersiz, kullanilmis veya suresi dolmus servis PIN kodu! Lutfen ev sahibinden yeni kod talep edin.');
      err.statusCode = 403;
      throw err;
    }

    const serviceToken = tokenRes.rows[0];

    // Teknisyen kullanicisi var mi kontrol et, yoksa olustur
    let userRes = await db.query('SELECT * FROM users WHERE email = $1', [technicianEmail]);
    let techUser;
    if (userRes.rows.length === 0) {
      const insRes = await db.query(
        `INSERT INTO users (email, password_hash, full_name, phone)
         VALUES ($1, 'NO_DIRECT_LOGIN', $2, '+905559998877')
         RETURNING *`,
        [technicianEmail, technicianName]
      );
      techUser = insRes.rows[0];
    } else {
      techUser = userRes.rows[0];
    }

    // Home_users tablosuna 'service_user' rolu ve 2 saatlik bitis tarihiyle kaydet / guncelle
    await db.query(
      `INSERT INTO home_users (home_id, user_id, role)
       VALUES ($1, $2, 'service_user')
       ON CONFLICT (home_id, user_id) 
       DO UPDATE SET role = 'service_user'`,
      [serviceToken.home_id, techUser.id]
    );

    // Token'i kullanildi olarak isaretle
    await db.query('UPDATE service_tokens SET is_used = TRUE WHERE id = $1', [serviceToken.id]);

    // 2 saat gecerli servis sorumlusu JWT token'i uret
    const token = jwt.sign(
      {
        id: techUser.id,
        email: techUser.email,
        full_name: techUser.full_name,
        role: 'service_user',
        home_id: serviceToken.home_id,
        expires_at: serviceToken.expires_at,
      },
      process.env.JWT_SECRET,
      { expiresIn: '2h' }
    );

    return {
      token,
      home: {
        id: serviceToken.home_id,
        name: serviceToken.home_name,
        mqtt_username: serviceToken.mqtt_username,
      },
      role: 'service_user',
      expires_at: serviceToken.expires_at,
      message: 'Geçici servis sorumlusu oturumu başlatıldı.',
    };
  }
}

module.exports = new ServiceTokenService();

