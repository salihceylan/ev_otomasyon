const bcrypt = require('bcryptjs');
const jwt = require('jsonwebtoken');
const crypto = require('crypto');
const db = require('../db');

class AuthService {
  /**
   * Refresh token için SHA-256 hash üretir
   */
  _hashToken(token) {
    return crypto.createHash('sha256').update(token).digest('hex');
  }

  /**
   * Access Token (15 dk) ve Refresh Token (365 gün) üretip DB'ye kaydeder
   */
  async generateTokens(user) {
    const jwtSecret = process.env.JWT_SECRET || 'ahbu_default_secret_key_2026';
    const refreshSecret = process.env.JWT_REFRESH_SECRET || jwtSecret;

    // 15 Dakikalık Access Token
    const accessToken = jwt.sign(
      {
        id: user.id,
        email: user.email,
        full_name: user.full_name,
        phone: user.phone || null,
      },
      jwtSecret,
      { expiresIn: '15m' }
    );

    // 1 Yıllık (365 Gün) Refresh Token
    const refreshToken = jwt.sign(
      {
        id: user.id,
        type: 'refresh',
      },
      refreshSecret,
      { expiresIn: '365d' }
    );

    const tokenHash = this._hashToken(refreshToken);
    const expiresAt = new Date(Date.now() + 365 * 24 * 60 * 60 * 1000);

    // Veritabanına kaydet
    await db.query(
      `INSERT INTO refresh_tokens (user_id, token_hash, expires_at)
       VALUES ($1, $2, $3)`,
      [user.id, tokenHash, expiresAt]
    );

    return {
      access_token: accessToken,
      refresh_token: refreshToken,
      token: accessToken, // Geriye dönük uyumluluk
      expires_in: 900, // 15 dk (saniye cinsinden)
    };
  }

  /**
   * E-posta veya Telefon + Şifre ile Kullanıcı Girişi
   */
  async login(identifier, password) {
    const cleanIdentifier = (identifier || '').trim().toLowerCase();
    const res = await db.query(
      `SELECT * FROM users 
       WHERE (LOWER(email) = $1 OR phone = $2) AND is_active = TRUE`,
      [cleanIdentifier, identifier.trim()]
    );

    if (res.rows.length === 0) {
      throw new Error('Gecersiz e-posta / telefon veya sifre');
    }

    const user = res.rows[0];
    const isMatch = await bcrypt.compare(password, user.password_hash);
    if (!isMatch) {
      throw new Error('Gecersiz e-posta / telefon veya sifre');
    }

    const tokens = await this.generateTokens(user);

    // Kullanıcının yetkili olduğu evleri getir
    const homesRes = await db.query(
      `SELECT h.id, h.name, h.address, h.mqtt_username, hu.role, hu.installer_expires_at, hu.valid_from, hu.valid_until
       FROM homes h
       JOIN home_users hu ON h.id = hu.home_id
       WHERE hu.user_id = $1`,
      [user.id]
    );

    const now = new Date();
    const homes = homesRes.rows.map(h => ({
      ...h,
      is_expired: h.role === 'guest' && h.valid_until && new Date(h.valid_until) < now,
    }));

    return {
      ...tokens,
      user: {
        id: user.id,
        email: user.email,
        full_name: user.full_name,
        phone: user.phone,
      },
      homes: homes,
    };
  }

  /**
   * Yeni Kullanıcı Kaydı (Register)
   */
  async register({ full_name, email, password, phone }) {
    if (!full_name || !email || !password) {
      throw new Error('Ad soyad, e-posta ve sifre alanlari zorunludur');
    }

    const cleanEmail = email.trim().toLowerCase();
    const cleanPhone = phone ? phone.trim() : null;

    // E-posta benzersizlik kontrolü
    const existingEmail = await db.query('SELECT id FROM users WHERE LOWER(email) = $1', [cleanEmail]);
    if (existingEmail.rows.length > 0) {
      throw new Error('Bu e-posta adresi zaten kayitlidir');
    }

    // Telefon benzersizlik kontrolü (eğer girilmişse)
    if (cleanPhone) {
      const existingPhone = await db.query('SELECT id FROM users WHERE phone = $1', [cleanPhone]);
      if (existingPhone.rows.length > 0) {
        throw new Error('Bu telefon numarasi zaten kayitlidir');
      }
    }

    // Şifre hash'leme
    const salt = await bcrypt.genSalt(10);
    const passwordHash = await bcrypt.hash(password, salt);

    // Kullanıcıyı oluştur
    const insertRes = await db.query(
      `INSERT INTO users (full_name, email, password_hash, phone, is_active)
       VALUES ($1, $2, $3, $4, TRUE)
       RETURNING id, full_name, email, phone, created_at`,
      [full_name.trim(), cleanEmail, passwordHash, cleanPhone]
    );

    const newUser = insertRes.rows[0];
    const tokens = await this.generateTokens(newUser);

    return {
      ...tokens,
      user: {
        id: newUser.id,
        email: newUser.email,
        full_name: newUser.full_name,
        phone: newUser.phone,
      },
      homes: [],
    };
  }

  /**
   * Refresh Token ile Yeni Access Token Üretme (Sessiz Oturum Tazeleme)
   */
  async refreshToken(refreshToken) {
    if (!refreshToken) {
      throw new Error('Refresh token zorunludur');
    }

    const jwtSecret = process.env.JWT_SECRET || 'ahbu_default_secret_key_2026';
    const refreshSecret = process.env.JWT_REFRESH_SECRET || jwtSecret;

    let payload;
    try {
      payload = jwt.verify(refreshToken, refreshSecret);
    } catch (e) {
      throw new Error('Gecersiz veya suresi dolmus refresh token');
    }

    const tokenHash = this._hashToken(refreshToken);

    // Token veritabanında aktif mi?
    const dbRes = await db.query(
      `SELECT rt.*, u.email, u.full_name, u.phone, u.is_active
       FROM refresh_tokens rt
       JOIN users u ON rt.user_id = u.id
       WHERE rt.token_hash = $1 
         AND rt.revoked_at IS NULL 
         AND rt.expires_at > NOW() 
         AND u.is_active = TRUE`,
      [tokenHash]
    );

    if (dbRes.rows.length === 0) {
      throw new Error('Gecersiz veya iptal edilmis oturum');
    }

    const user = dbRes.rows[0];

    // Yeni 15 dakikalık Access Token
    const newAccessToken = jwt.sign(
      {
        id: user.user_id,
        email: user.email,
        full_name: user.full_name,
        phone: user.phone || null,
      },
      jwtSecret,
      { expiresIn: '15m' }
    );

    return {
      access_token: newAccessToken,
      token: newAccessToken,
      refresh_token: refreshToken,
      expires_in: 900,
    };
  }

  /**
   * Tek Bir Refresh Token'ı İptal Et (Logout)
   */
  async revokeToken(refreshToken) {
    if (!refreshToken) return;
    const tokenHash = this._hashToken(refreshToken);
    await db.query(
      'UPDATE refresh_tokens SET revoked_at = NOW() WHERE token_hash = $1',
      [tokenHash]
    );
  }

  /**
   * Kullanıcının Tüm Aktif Oturumlarını Sonlandır (Daire Devri & Acil İptal)
   */
  async revokeAllUserSessions(userId) {
    await db.query(
      'UPDATE refresh_tokens SET revoked_at = NOW() WHERE user_id = $1 AND revoked_at IS NULL',
      [userId]
    );
  }

  /**
   * Şifre Sıfırlama OTP Üretme (E-posta veya Telefon)
   */
  async forgotPassword(identifier) {
    if (!identifier) {
      throw new Error('E-posta veya telefon numarasi zorunludur');
    }

    const clean = identifier.trim().toLowerCase();
    const userRes = await db.query(
      `SELECT id, email, full_name, phone FROM users 
       WHERE (LOWER(email) = $1 OR phone = $2) AND is_active = TRUE`,
      [clean, identifier.trim()]
    );

    // Güvenlik gereği kullanıcı bulunamasa bile saldırgan bilgi toplamasın diye aynı mesaj verilir
    if (userRes.rows.length === 0) {
      return {
        message: 'Eger kayitli bir hesap varsa, sifre sifirlama kodu iletildi.',
      };
    }

    const user = userRes.rows[0];

    // 6 Haneli Sayısal OTP
    const otpCode = Math.floor(100000 + Math.random() * 900000).toString();
    const expiresAt = new Date(Date.now() + 15 * 60 * 1000); // 15 dakika

    await db.query(
      `INSERT INTO password_reset_tokens (user_id, otp_code, expires_at)
       VALUES ($1, $2, $3)`,
      [user.id, otpCode, expiresAt]
    );

    console.log(`[AUTH-OTP] Kullanıcı ${user.email} (${user.phone}) için OTP Kodu: ${otpCode}`);

    return {
      message: 'Sifre sifirlama kodu basariyla olusturuldu.',
      otp: otpCode, // Test ve istemci kolaylığı için
      user_id: user.id,
    };
  }

  /**
   * OTP Doğrulama ve Yeni Şifre Belirleme
   */
  async resetPassword({ identifier, otp_code, new_password }) {
    if (!identifier || !otp_code || !new_password) {
      throw new Error('E-posta/telefon, dogrulama kodu ve yeni sifre zorunludur');
    }

    if (new_password.length < 6) {
      throw new Error('Yeni sifre en az 6 karakter olmalidir');
    }

    const clean = identifier.trim().toLowerCase();
    const userRes = await db.query(
      `SELECT id FROM users 
       WHERE (LOWER(email) = $1 OR phone = $2) AND is_active = TRUE`,
      [clean, identifier.trim()]
    );

    if (userRes.rows.length === 0) {
      throw new Error('Gecersiz e-posta veya dogrulama kodu');
    }

    const userId = userRes.rows[0].id;

    // En güncel ve geçerli OTP kodunu sorgula
    const otpRes = await db.query(
      `SELECT id FROM password_reset_tokens 
       WHERE user_id = $1 
         AND otp_code = $2 
         AND used = FALSE 
         AND expires_at > NOW()
       ORDER BY created_at DESC 
       LIMIT 1`,
      [userId, otp_code.trim()]
    );

    if (otpRes.rows.length === 0) {
      throw new Error('Gecersiz veya suresi dolmus dogrulama kodu');
    }

    // OTP'yi kullanıldı olarak işaretle
    await db.query('UPDATE password_reset_tokens SET used = TRUE WHERE id = $1', [otpRes.rows[0].id]);

    // Yeni şifreyi hashle ve kaydet
    const salt = await bcrypt.genSalt(10);
    const passwordHash = await bcrypt.hash(new_password, salt);

    await db.query(
      'UPDATE users SET password_hash = $1, updated_at = NOW() WHERE id = $2',
      [passwordHash, userId]
    );

    // Güvenlik gereği kullanıcının eski tüm aktif refresh oturumlarını iptal et
    await this.revokeAllUserSessions(userId);

    return {
      message: 'Sifreniz basariyla sifirlandi. Lutfen yeni sifrenizle giris yapiniz.',
    };
  }

  /**
   * Profil ve Kullanıcının Dairelerini Getir
   */
  async getProfile(userId) {
    const res = await db.query('SELECT id, email, full_name, phone, created_at FROM users WHERE id = $1', [userId]);
    if (res.rows.length === 0) {
      throw new Error('Kullanici bulunamadi');
    }

    const homesRes = await db.query(
      `SELECT h.id, h.name, h.address, h.mqtt_username, hu.role, hu.installer_expires_at, hu.valid_from, hu.valid_until
       FROM homes h
       JOIN home_users hu ON h.id = hu.home_id
       WHERE hu.user_id = $1`,
      [userId]
    );

    const now = new Date();
    const homes = homesRes.rows.map(h => ({
      ...h,
      is_expired: h.role === 'guest' && h.valid_until && new Date(h.valid_until) < now,
    }));

    return {
      user: res.rows[0],
      homes: homes,
    };
  }

  /**
   * Ortak Auth Yanıtı Oluşturucu (Tokens + User + Homes)
   */
  async _buildUserAuthResponse(user) {
    const tokens = await this.generateTokens(user);

    const homesRes = await db.query(
      `SELECT h.id, h.name, h.address, h.mqtt_username, hu.role, hu.installer_expires_at, hu.valid_from, hu.valid_until
       FROM homes h
       JOIN home_users hu ON h.id = hu.home_id
       WHERE hu.user_id = $1`,
      [user.id]
    );

    const now = new Date();
    const homes = homesRes.rows.map(h => ({
      ...h,
      is_expired: h.role === 'guest' && h.valid_until && new Date(h.valid_until) < now,
    }));

    return {
      ...tokens,
      user: {
        id: user.id,
        email: user.email,
        full_name: user.full_name,
        phone: user.phone,
      },
      homes: homes,
    };
  }

  /**
   * ADIM 18: Google Sign-In Doğrulama ve Giriş
   */
  async loginWithGoogle({ id_token, email, full_name, google_id }) {
    let resolvedEmail = email ? email.trim().toLowerCase() : null;
    let resolvedName = full_name ? full_name.trim() : 'Google Kullanıcısı';
    let resolvedGoogleId = google_id || null;

    // Eğer id_token verilmişse Google tokeninfo endpoint'i ile doğrula
    if (id_token) {
      try {
        const https = require('https');
        const tokenInfo = await new Promise((resolve, reject) => {
          https.get(`https://oauth2.googleapis.com/tokeninfo?id_token=${id_token}`, (res) => {
            let data = '';
            res.on('data', chunk => data += chunk);
            res.on('end', () => {
              try {
                const parsed = JSON.parse(data);
                if (res.statusCode === 200 && parsed.email) {
                  resolve(parsed);
                } else {
                  resolve(null); // Doğrulama hatasında lokal veriyi kullan
                }
              } catch (_) {
                resolve(null);
              }
            });
          }).on('error', () => resolve(null));
        });

        if (tokenInfo) {
          resolvedEmail = tokenInfo.email.toLowerCase();
          resolvedName = tokenInfo.name || resolvedName;
          resolvedGoogleId = tokenInfo.sub || resolvedGoogleId;
        }
      } catch (err) {
        console.warn('[AUTH-GOOGLE] Tokeninfo online kontrol uyarısı:', err.message);
      }
    }

    if (!resolvedEmail && !resolvedGoogleId) {
      throw new Error('Google hesap bilgileri doğrulanamadı');
    }

    // 1. Önce google_id veya email ile mevcut kullanıcıyı ara
    let userRes = await db.query(
      `SELECT * FROM users WHERE (google_id IS NOT NULL AND google_id = $1) OR (LOWER(email) = $2)`,
      [resolvedGoogleId || 'non_existent_sub', resolvedEmail || 'non_existent@email.com']
    );

    let user;
    if (userRes.rows.length > 0) {
      user = userRes.rows[0];
      // google_id henüz kayıtlı değilse güncelle
      if (!user.google_id && resolvedGoogleId) {
        await db.query('UPDATE users SET google_id = $1 WHERE id = $2', [resolvedGoogleId, user.id]);
        user.google_id = resolvedGoogleId;
      }
    } else {
      // 2. Yeni kullanıcı oluştur (şifresiz / rastgele hash)
      const randomPass = crypto.randomBytes(32).toString('hex');
      const salt = await bcrypt.genSalt(10);
      const passwordHash = await bcrypt.hash(randomPass, salt);

      const insertRes = await db.query(
        `INSERT INTO users (full_name, email, google_id, password_hash, is_active)
         VALUES ($1, $2, $3, $4, TRUE)
         RETURNING *`,
        [resolvedName, resolvedEmail, resolvedGoogleId, passwordHash]
      );
      user = insertRes.rows[0];
    }

    return this._buildUserAuthResponse(user);
  }

  /**
   * ADIM 18: Sign in with Apple Doğrulama ve Giriş
   */
  async loginWithApple({ identity_token, user_id, email, full_name }) {
    const resolvedAppleId = user_id;
    let resolvedEmail = email ? email.trim().toLowerCase() : null;
    let resolvedName = full_name ? full_name.trim() : 'Apple Kullanıcısı';

    if (!resolvedAppleId && !resolvedEmail) {
      throw new Error('Apple kullanıcı kimliği (user_id) gereklidir');
    }

    // 1. Önce apple_id veya e-posta ile kullanıcı ara
    let userRes = await db.query(
      `SELECT * FROM users WHERE (apple_id IS NOT NULL AND apple_id = $1) OR ($2::text IS NOT NULL AND LOWER(email) = $2)`,
      [resolvedAppleId || 'non_existent_apple_id', resolvedEmail]
    );

    let user;
    if (userRes.rows.length > 0) {
      user = userRes.rows[0];
      if (!user.apple_id && resolvedAppleId) {
        await db.query('UPDATE users SET apple_id = $1 WHERE id = $2', [resolvedAppleId, user.id]);
        user.apple_id = resolvedAppleId;
      }
    } else {
      // 2. Yeni kullanıcı oluştur
      const randomPass = crypto.randomBytes(32).toString('hex');
      const salt = await bcrypt.genSalt(10);
      const passwordHash = await bcrypt.hash(randomPass, salt);
      const fallbackEmail = resolvedEmail || `apple_${resolvedAppleId.substring(0, 12)}@privaterelay.ahbu.com`;

      const insertRes = await db.query(
        `INSERT INTO users (full_name, email, apple_id, password_hash, is_active)
         VALUES ($1, $2, $3, $4, TRUE)
         RETURNING *`,
        [resolvedName, fallbackEmail, resolvedAppleId, passwordHash]
      );
      user = insertRes.rows[0];
    }

    return this._buildUserAuthResponse(user);
  }

  /**
   * ADIM 18: Telefon Numarasına 6 Haneli OTP Gönderme
   */
  async sendPhoneOtp(phone) {
    if (!phone || phone.trim().length < 10) {
      throw new Error('Geçerli bir telefon numarası giriniz (örn: 05xxxxxxxxx)');
    }

    const cleanPhone = phone.trim().replace(/\s+/g, '');
    const code = Math.floor(100000 + Math.random() * 900000).toString();
    const otpHash = crypto.createHash('sha256').update(code).digest('hex');
    const expiresAt = new Date(Date.now() + 5 * 60 * 1000); // 5 dakika geçerli

    // Eski OTP'leri temizle
    await db.query('DELETE FROM phone_otp_codes WHERE phone = $1', [cleanPhone]);

    // Yeni OTP kaydet
    await db.query(
      `INSERT INTO phone_otp_codes (phone, otp_hash, expires_at)
       VALUES ($1, $2, $3)`,
      [cleanPhone, otpHash, expiresAt]
    );

    console.log(`[OTP-SERVICE] Telefon: ${cleanPhone} | Doğrulama Kodu: ${code}`);

    return {
      success: true,
      message: 'Doğrulama kodu gönderildi',
      expires_in: 300,
      // Geliştirme/test kolaylığı için kod debug logunda gösterilir
      debug_code: process.env.NODE_ENV !== 'production' ? code : undefined,
    };
  }

  /**
   * ADIM 18: Telefon OTP Kodu Doğrulama ve Giriş Yapma
   */
  async verifyPhoneOtp(phone, code) {
    if (!phone || !code) {
      throw new Error('Telefon numarası ve 6 haneli doğrulama kodu zorunludur');
    }

    const cleanPhone = phone.trim().replace(/\s+/g, '');
    const cleanCode = code.trim();
    const inputHash = crypto.createHash('sha256').update(cleanCode).digest('hex');

    const otpRes = await db.query(
      `SELECT * FROM phone_otp_codes WHERE phone = $1 AND expires_at > NOW()`,
      [cleanPhone]
    );

    if (otpRes.rows.length === 0) {
      throw new Error('Doğrulama kodunun süresi dolmuş veya kod talep edilmemiş');
    }

    const otpRecord = otpRes.rows[0];
    if (otpRecord.attempts >= 5) {
      await db.query('DELETE FROM phone_otp_codes WHERE id = $1', [otpRecord.id]);
      throw new Error('Çok fazla hatalı deneme yapıldı. Lütfen yeni kod talep ediniz.');
    }

    if (otpRecord.otp_hash !== inputHash) {
      await db.query('UPDATE phone_otp_codes SET attempts = attempts + 1 WHERE id = $1', [otpRecord.id]);
      throw new Error('Hatalı doğrulama kodu');
    }

    // Kod doğru, OTP'yi sil
    await db.query('DELETE FROM phone_otp_codes WHERE id = $1', [otpRecord.id]);

    // Kullanıcıyı telefon numarası ile bul veya oluştur
    let userRes = await db.query('SELECT * FROM users WHERE phone = $1', [cleanPhone]);
    let user;

    if (userRes.rows.length > 0) {
      user = userRes.rows[0];
    } else {
      // Yeni şifresiz kullanıcı oluştur
      const randomPass = crypto.randomBytes(32).toString('hex');
      const salt = await bcrypt.genSalt(10);
      const passwordHash = await bcrypt.hash(randomPass, salt);
      const dummyEmail = `phone_${cleanPhone.replace(/[^0-9]/g, '')}@ahbu.local`;

      const insertRes = await db.query(
        `INSERT INTO users (full_name, phone, email, password_hash, is_active)
         VALUES ($1, $2, $3, $4, TRUE)
         RETURNING *`,
        [`Sakin (${cleanPhone.slice(-4)})`, cleanPhone, dummyEmail, passwordHash]
      );
      user = insertRes.rows[0];
    }

    return this._buildUserAuthResponse(user);
  }

  /**
   * ADIM 20: Şifre Sıfırlama Talebi (6 Haneli OTP & Magic Token Üretimi)
   */
  async requestPasswordReset(identifier) {
    if (!identifier || !identifier.trim()) {
      throw new Error('E-posta veya telefon numarası gereklidir');
    }

    const clean = identifier.trim();
    const cleanLower = clean.toLowerCase();

    // Kullanıcıyı e-posta veya telefon ile bul
    const userRes = await db.query(
      `SELECT * FROM users WHERE (LOWER(email) = $1 OR phone = $2) AND is_active = TRUE`,
      [cleanLower, clean]
    );

    // Güvenlik gereği kullanıcı bulunamasa bile aynı mesaj dönebilir (enumeration prevention)
    // Saha konforu için kullanıcı bulunursa sıfırlama kaydı açılır
    let userId = null;
    if (userRes.rows.length > 0) {
      userId = userRes.rows[0].id;
    }

    const code = crypto.randomInt(100000, 999999).toString();
    const codeHash = crypto.createHash('sha256').update(code).digest('hex');
    const magicToken = crypto.randomBytes(32).toString('hex');
    const expiresAt = new Date(Date.now() + 15 * 60 * 1000); // 15 dakika

    await db.query(
      `INSERT INTO password_resets (user_id, identifier, code_hash, token, expires_at)
       VALUES ($1, $2, $3, $4, $5)`,
      [userId, clean, codeHash, magicToken, expiresAt]
    );

    console.log(`[PASSWORD-RESET] Alıcı: ${clean} | 6 Haneli Kod: ${code} | Magic Token: ${magicToken}`);

    return {
      success: true,
      message: 'Şifre kurtarma kodu başarıyla iletildi',
      expires_in: 900,
      debug_code: process.env.NODE_ENV !== 'production' ? code : undefined,
      debug_token: process.env.NODE_ENV !== 'production' ? magicToken : undefined,
    };
  }

  /**
   * ADIM 20: Şifre Sıfırlama (OTP Kodu veya Magic Token ile) ve Tüm Oturumları Düşürme
   */
  async resetPassword({ identifier, code, token, new_password }) {
    if (!new_password || new_password.trim().length < 6) {
      throw new Error('Yeni şifre en az 6 karakter olmalıdır');
    }

    let resetRecord = null;

    if (token && token.trim()) {
      // Magic Link Token ile sıfırlama
      const res = await db.query(
        `SELECT * FROM password_resets WHERE token = $1 AND expires_at > NOW() AND used_at IS NULL`,
        [token.trim()]
      );
      if (res.rows.length === 0) {
        throw new Error('Geçersiz veya süresi dolmuş sihirli bağlantı');
      }
      resetRecord = res.rows[0];
    } else if (identifier && code) {
      // 6 Haneli OTP Kodu ile sıfırlama
      const clean = identifier.trim();
      const cleanCode = code.trim();
      const codeHash = crypto.createHash('sha256').update(cleanCode).digest('hex');

      const res = await db.query(
        `SELECT * FROM password_resets 
         WHERE identifier = $1 AND expires_at > NOW() AND used_at IS NULL 
         ORDER BY id DESC LIMIT 1`,
        [clean]
      );

      if (res.rows.length === 0) {
        throw new Error('Geçersiz veya süresi dolmuş kurtarma kodu');
      }

      resetRecord = res.rows[0];

      if (resetRecord.attempts >= 5) {
        await db.query(`UPDATE password_resets SET used_at = NOW() WHERE id = $1`, [resetRecord.id]);
        throw new Error('Çok fazla hatalı kod denemesi yapıldı. Lütfen yeni kod talep ediniz.');
      }

      if (resetRecord.code_hash !== codeHash) {
        await db.query(`UPDATE password_resets SET attempts = attempts + 1 WHERE id = $1`, [resetRecord.id]);
        throw new Error('Hatalı kurtarma kodu');
      }
    } else {
      throw new Error('Kurtarma kodu veya sihirli bağlantı tokenı zorunludur');
    }

    if (!resetRecord.user_id) {
      // Geçersiz kullanıcı için açılan hayalet talep
      await db.query(`UPDATE password_resets SET used_at = NOW() WHERE id = $1`, [resetRecord.id]);
      throw new Error('Bu kimliğe ait aktif bir kullanıcı hesabı bulunamadı');
    }

    // Kodu kullanıldı olarak işaretle
    await db.query(`UPDATE password_resets SET used_at = NOW() WHERE id = $1`, [resetRecord.id]);

    // Yeni şifreyi bcrypt ile hash'le
    const salt = await bcrypt.genSalt(10);
    const newPasswordHash = await bcrypt.hash(new_password.trim(), salt);

    // Kullanıcı şifresini güncelle ve token_version artır (Tüm aktif oturumları anında düşür)
    const updateRes = await db.query(
      `UPDATE users 
       SET password_hash = $1, token_version = COALESCE(token_version, 1) + 1 
       WHERE id = $2 
       RETURNING *`,
      [newPasswordHash, resetRecord.user_id]
    );

    if (updateRes.rows.length === 0) {
      throw new Error('Kullanıcı hesabı bulunamadı');
    }

    // Güvenlik: Eski tüm refresh token kayıtlarını sil
    await db.query(`DELETE FROM refresh_tokens WHERE user_id = $1`, [resetRecord.user_id]);

    const updatedUser = updateRes.rows[0];

    // Yeni taze JWT Access ve Refresh token üretip dön (otomatik giriş konforu)
    return this._buildUserAuthResponse(updatedUser);
  }

  /**
   * ADIM 20: Sihirli Bağlantı (Magic Link) ile Tek Tıkla Giriş
   */
  async magicLogin(token) {
    if (!token || !token.trim()) {
      throw new Error('Sihirli bağlantı tokenı gereklidir');
    }

    const res = await db.query(
      `SELECT * FROM password_resets WHERE token = $1 AND expires_at > NOW() AND used_at IS NULL`,
      [token.trim()]
    );

    if (res.rows.length === 0) {
      throw new Error('Geçersiz veya süresi dolmuş sihirli bağlantı');
    }

    const record = res.rows[0];
    if (!record.user_id) {
      await db.query(`UPDATE password_resets SET used_at = NOW() WHERE id = $1`, [record.id]);
      throw new Error('Bu bağlantıya ait aktif bir kullanıcı bulunamadı');
    }

    await db.query(`UPDATE password_resets SET used_at = NOW() WHERE id = $1`, [record.id]);

    const userRes = await db.query(`SELECT * FROM users WHERE id = $1 AND is_active = TRUE`, [record.user_id]);
    if (userRes.rows.length === 0) {
      throw new Error('Kullanıcı hesabı bulunamadı veya pasif durumda');
    }

    return this._buildUserAuthResponse(userRes.rows[0]);
  }
}

module.exports = new AuthService();
