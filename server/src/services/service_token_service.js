'use strict';

// ==============================================================================
// AHBU Akilli Ev - Servis PIN'i ve servis oturumu (WP-A: A6, CONTRACTS §1.3)
// ==============================================================================
//
//  - PIN'i ev sahibi BIR EV icin uretir (POST /homes/:homeId/service-token, yalnizca owner).
//    Yeni PIN, o evin onceki kullanilmamis PIN'lerini iptal eder.
//  - PIN 6 hane, crypto.randomInt; DB'de YALNIZCA HMAC(PIN_PEPPER) ozeti (utils/pin.js);
//    TEK KULLANIMLIK (atomik UPDATE ... WHERE used_at IS NULL AND expires_at > NOW() RETURNING);
//    2 saat gecerli.
//  - Giris (POST /auth/service-login) `service_sessions` satiri olusturur ve tek-ev kapsamli
//    token doner: { access_token, expires_in, scope:'home_service', home:{id,name} } - refresh YOK.
//    Kullanici satiri OLUSTURULMAZ, global rol VERILMEZ.
//  - Ev devri / acil sifirlama: revokeHomeServiceAccess(homeId, tx?) PIN'leri ve oturumlari iptal eder.
//  - pano-6: yerel anahtari OKUMUS (local_key_read_at) oturum bitince (iptal / sure) evin yerel anahtari bekleyen yolla
//    dondurulur: sweepEndedSessions (sunucuda 5 dk'da bir + iptal ucu / kendi cikisi sonrasi o ev icin hemen).

const db = require('../db');
const { HttpError, generateNumericPin, isUuid } = require('../utils/helpers');
const { hashPin } = require('../utils/pin');
const jwtConfig = require('../middlewares/jwt_config');
const { invalidateServiceSessionCache } = require('../middlewares/auth_middleware');

const PIN_TTL_SEC = 2 * 60 * 60;
const PIN_GENERATION_ATTEMPTS = 8;
const SWEEP_INTERVAL_MS = 5 * 60 * 1000; // pano-6: biten servis oturumlari icin anahtar rotasyonu turu

// pano-6: anahtari okumus ve bitmis (iptal / suresi dolmus) ama rotasyonu yapilmamis oturumlar
const ENDED_READ_SESSIONS_COND =
  'local_key_read_at IS NOT NULL AND key_rotated_at IS NULL AND (revoked_at IS NOT NULL OR expires_at <= NOW())';
// Karar 17A (migration 043): biten HER servis oturumu (oturum cihaz MQTT kimligini alabilir) icin cihaz kimligi bir kez
// dondurulur; device_credential_rotation.rotate evin bitmis oturumlarini isaretler.
const ENDED_CRED_SESSIONS_COND = 'device_cred_rotated_at IS NULL AND (revoked_at IS NOT NULL OR expires_at <= NOW())';

function normalizeTechnicianName(value) {
  if (typeof value !== 'string') return 'Yetkili Servis';
  // eslint-disable-next-line no-control-regex
  const s = value.replace(/[\u0000-\u001f\u007f]/g, ' ').replace(/\s+/g, ' ').trim();
  return s.length >= 2 ? s.slice(0, 100) : 'Yetkili Servis';
}

class ServiceTokenService {
  constructor() {
    // undefined: varsayilan mqtt_credential_service modulu; null: bilincli devre disi (test)
    this._mqttCredentials = undefined;
    this._localKeyRotation = undefined; // undefined: varsayilan local_key_rotation modulu (pano-6)
    this._deviceCredRotation = undefined; // undefined: varsayilan device_credential_rotation modulu (karar 17A)
    this._sweepTimer = null;
    this._sweepRunning = false;
  }

  /** Test / DI: yerel anahtar rotasyonu servisi (pano-6; scheduleRotation + afterCommit). */
  setLocalKeyRotation(svc) {
    this._localKeyRotation = svc;
  }

  _rotation() {
    if (this._localKeyRotation !== undefined) return this._localKeyRotation;
    return require('./local_key_rotation');
  }

  /**
   * pano-6: yerel anahtari okumus servis oturumu bittiyse (iptal / suresi doldu) evin anahtari bekleyen yolla dondurulur.
   * Her ev AYRI islemde: rotasyon + o evin bu kosuldaki oturumlarina key_rotated_at (cok panolu evde rotasyon yapilmaz
   * ama oturum yine isaretlenir: sonsuz tekrar yok). COMMIT sonrasi uzlastirici. Bir evin hatasi digerlerini durdurmaz.
   * @param {{homeId?:string}} [opts]  homeId: yalniz o ev (iptal ucu / servis oturumunun kendi cikisi)
   * @returns {Promise<{homes:number, scheduled:number}>}
   */
  async sweepEndedSessions({ homeId = null } = {}) {
    // Karar 17A: ONCE cihaz MQTT kimligi dondurulur (eski oturum atilir); yerel anahtar rotasyonunun set_local_key'i
    // uzlastiricida yeni kimlik gelene kadar bekler. Hata (043'suz veritabani vb.) yerel anahtar turunu durdurmaz.
    const credOut = await this._sweepDeviceCredentials(homeId);
    const res = homeId
      ? await db.query(`SELECT DISTINCT home_id FROM service_sessions WHERE ${ENDED_READ_SESSIONS_COND} AND home_id = $1`, [homeId])
      : await db.query(`SELECT DISTINCT home_id FROM service_sessions WHERE ${ENDED_READ_SESSIONS_COND}`);
    const homes = ((res && res.rows) || []).map((r) => r.home_id).filter(Boolean);
    const rotation = this._rotation();
    let scheduled = 0;
    for (const h of homes) {
      try {
        const rot = await db.withTransaction(async (tx) => {
          const r = rotation ? await rotation.scheduleRotation(h, { tx, reason: 'service_session_ended' }) : null;
          await tx.query(`UPDATE service_sessions SET key_rotated_at = NOW() WHERE home_id = $1 AND ${ENDED_READ_SESSIONS_COND}`, [h]);
          return r;
        });
        if (rot && rot.scheduled) {
          scheduled += 1;
          rotation.afterCommit(rot);
        }
      } catch (err) {
        console.warn(`[SERVIS] Servis oturumu anahtar rotasyonu yapilamadi (ev=${String(h).slice(0, 8)}): ${err && err.code ? err.code : 'hata'}`);
      }
    }
    if (credOut.rotated > 0) {
      console.log(`[SERVIS] Biten servis oturumlari: ${credOut.rotated} evde cihaz MQTT kimligi donduruldu.`);
    }
    return { homes: homes.length, scheduled };
  }

  /** Test / DI: cihaz MQTT kimligi dondurma servisi (karar 17A; rotate + afterCommit). undefined = varsayilan modul. */
  setDeviceCredRotation(svc) {
    this._deviceCredRotation = svc;
  }

  _credRotation() {
    if (this._deviceCredRotation !== undefined) return this._deviceCredRotation;
    return require('./device_credential_rotation');
  }

  /** Karar 17A: bitmis ve islenmemis servis oturumu olan her ev icin AYRI islemde cihaz kimligi dondurmesi. */
  async _sweepDeviceCredentials(homeId) {
    const out = { homes: 0, rotated: 0 };
    const svc = this._credRotation();
    if (!svc || typeof svc.rotate !== 'function') return out;
    let homes = [];
    try {
      const res = homeId
        ? await db.query(`SELECT DISTINCT home_id FROM service_sessions WHERE ${ENDED_CRED_SESSIONS_COND} AND home_id = $1`, [homeId])
        : await db.query(`SELECT DISTINCT home_id FROM service_sessions WHERE ${ENDED_CRED_SESSIONS_COND}`);
      homes = ((res && res.rows) || []).map((r) => r.home_id).filter(Boolean);
    } catch (err) {
      console.warn(`[SERVIS] Servis oturumu cihaz kimligi supurmesi basarisiz: ${err && err.code ? err.code : 'hata'}`);
      return out;
    }
    out.homes = homes.length;
    for (const h of homes) {
      try {
        const r = await db.withTransaction((tx) => svc.rotate(h, { tx, reason: 'service_session_ended' }));
        if (r && r.rotated) {
          out.rotated += 1;
          await svc.afterCommit(r);
        }
      } catch (err) {
        console.warn(`[SERVIS] Servis oturumu cihaz kimligi dondurulemedi (ev=${String(h).slice(0, 8)}): ${err && err.code ? err.code : 'hata'}`);
      }
    }
    return out;
  }

  /** pano-6: periyodik supurme (5 dk, unref: sureci acik tutmaz). Ikinci cagri yeni zamanlayici kurmaz. */
  startSweeper({ intervalMs = SWEEP_INTERVAL_MS } = {}) {
    if (this._sweepTimer) return;
    this._sweepTimer = setInterval(() => {
      this._sweepTick().catch(() => {});
    }, intervalMs);
    if (this._sweepTimer && typeof this._sweepTimer.unref === 'function') this._sweepTimer.unref();
  }

  stopSweeper() {
    if (!this._sweepTimer) return;
    clearInterval(this._sweepTimer);
    this._sweepTimer = null;
  }

  async _sweepTick() {
    if (this._sweepRunning) return; // onceki tur surerken ust uste binmez
    this._sweepRunning = true;
    try {
      await this.sweepEndedSessions();
    } catch (err) {
      // 037 uygulanmadiysa (42703) ya da DB gecici hatasi: sonraki turda yeniden denenir
      console.warn(`[SERVIS] Servis oturumu supurmesi basarisiz: ${err && err.code ? err.code : 'hata'}`);
    } finally {
      this._sweepRunning = false;
    }
  }

  /** Test / DI: servis oturumu MQTT kimliklerini silen servis (`revokeServiceSessionAccess`). */
  setMqttCredentialService(svc) {
    this._mqttCredentials = svc;
  }

  _mqtt() {
    if (this._mqttCredentials !== undefined) return this._mqttCredentials;
    try {
      return require('./mqtt_credential_service');
    } catch (err) {
      if (err && err.code === 'MODULE_NOT_FOUND' && /mqtt_credential_service/.test(String(err.message))) return null;
      throw err;
    }
  }

  /**
   * Ev sahibinin 2 saat gecerli servis PIN'i uretmesi. PIN yalnizca bu yanitta (bir kez) doner.
   */
  async createServiceToken(ownerUserId, homeId) {
    if (!isUuid(String(ownerUserId || '')) || !isUuid(String(homeId || ''))) {
      throw new HttpError(400, 'Geçersiz istek.', 'VALIDATION');
    }

    return db.withTransaction(async (tx) => {
      // hesap-uyelik-7: yetki (owner) INSERT ile AYNI islemde uyelik satiri FOR SHARE ile yeniden dogrulanir: es zamanli
      // devir kabulu bu kilidi bekler ve servis erisimi temizligini PIN commit edildikten sonra yapar; sahiplik ara
      // katmandan sonra gittiyse 403 ve PIN uretilmez (yeni sahibin evinde eski sahibin PIN'i kalmaz).
      const m = await tx.query('SELECT role FROM home_users WHERE home_id = $1 AND user_id = $2 FOR SHARE', [homeId, ownerUserId]);
      if (!m.rows[0] || m.rows[0].role !== 'owner') throw new HttpError(403, 'Bu işlem için yetkiniz yok.', 'FORBIDDEN');
      // Suresi dolmus kullanilmamis PIN'ler kapatilir (aktif-PIN tekillik indeksini bosaltir).
      await tx.query(
        `UPDATE service_tokens SET revoked_at = NOW()
          WHERE revoked_at IS NULL AND used_at IS NULL AND expires_at <= NOW()`
      );
      // Yeni PIN, bu evin onceki kullanilmamis PIN'lerini iptal eder.
      await tx.query(
        `UPDATE service_tokens SET revoked_at = NOW()
          WHERE home_id = $1 AND revoked_at IS NULL AND used_at IS NULL`,
        [homeId]
      );

      for (let attempt = 0; attempt < PIN_GENERATION_ATTEMPTS; attempt++) {
        const pin = generateNumericPin(6);
        const pinHash = hashPin(pin);
        // Baska bir evin aktif PIN'iyle cakisma (10^6 alan): yeniden uret.
        const clash = await tx.query(
          `SELECT 1 FROM service_tokens
            WHERE pin_hash = $1 AND used_at IS NULL AND revoked_at IS NULL AND expires_at > NOW()
            LIMIT 1`,
          [pinHash]
        );
        if (clash.rows.length > 0) continue;

        const ins = await tx.query(
          `INSERT INTO service_tokens (home_id, created_by, pin_hash, expires_at, is_used)
           VALUES ($1, $2, $3, NOW() + make_interval(secs => $4::int), FALSE)
           RETURNING id, expires_at`,
          [homeId, ownerUserId, pinHash, PIN_TTL_SEC]
        );
        const row = ins.rows[0] || {};
        return {
          id: row.id,
          service_pin: pin,
          expires_at: row.expires_at,
          expires_in: PIN_TTL_SEC,
          message: '2 saat geçerli, tek kullanımlık servis PIN kodu üretildi. Kodu yalnızca yetkili servis sorumlusuna iletin.',
        };
      }
      const err = new HttpError(503, 'Servis PIN kodu şu anda üretilemedi. Lütfen tekrar deneyin.', 'SERVICE_UNAVAILABLE');
      err.expose = true;
      throw err;
    });
  }

  /**
   * PIN ile servis girisi. Kullanici satiri OLUSTURMAZ; tek-ev kapsamli oturum acar.
   * @returns {{access_token, token, token_type, expires_in, scope, role, home:{id,name}, expires_at}}
   */
  async loginWithServicePin(servicePin, technicianName, { ip } = {}) {
    const pinStr = typeof servicePin === 'string' || typeof servicePin === 'number' ? String(servicePin).trim() : '';
    if (!/^\d{6}$/.test(pinStr)) {
      throw new HttpError(400, 'Servis PIN kodu 6 haneli olmalıdır.', 'VALIDATION');
    }
    const name = normalizeTechnicianName(technicianName);
    const pinHash = hashPin(pinStr);
    const ttl = jwtConfig.getServiceSessionTtlSec();

    const result = await db.withTransaction(async (tx) => {
      // Atomik tek kullanim: ayni PIN ile yarisan iki istekten yalnizca biri satir alir.
      const used = await tx.query(
        `UPDATE service_tokens
            SET used_at = NOW(), is_used = TRUE
          WHERE pin_hash = $1
            AND used_at IS NULL
            AND revoked_at IS NULL
            AND expires_at > NOW()
          RETURNING id, home_id`,
        [pinHash]
      );
      if (used.rows.length === 0) {
        throw new HttpError(401, 'Geçersiz, kullanılmış veya süresi dolmuş servis PIN kodu. Ev sahibinden yeni kod isteyin.', 'INVALID_CREDENTIALS');
      }
      const tokenRow = used.rows[0];

      const homeRes = await tx.query('SELECT id, name FROM homes WHERE id = $1', [tokenRow.home_id]);
      if (homeRes.rows.length === 0) {
        throw new HttpError(401, 'Geçersiz servis PIN kodu.', 'INVALID_CREDENTIALS');
      }

      const sessionRes = await tx.query(
        `INSERT INTO service_sessions (home_id, service_token_id, technician_name, created_ip, expires_at)
         VALUES ($1, $2, $3, $4, NOW() + make_interval(secs => $5::int))
         RETURNING id, home_id, expires_at`,
        [tokenRow.home_id, tokenRow.id, name, ip ? String(ip).slice(0, 64) : null, ttl]
      );
      return { session: sessionRes.rows[0], home: homeRes.rows[0] };
    });

    const homeId = String(result.session.home_id).toLowerCase();
    const accessToken = jwtConfig.signServiceSessionToken({
      sid: result.session.id,
      home_id: homeId,
      expiresInSec: ttl,
    });

    return {
      access_token: accessToken,
      token: accessToken, // geriye donuk uyumluluk
      token_type: 'Bearer',
      expires_in: ttl,
      scope: 'home_service',
      role: 'service_session',
      home: { id: homeId, name: result.home.name },
      expires_at: result.session.expires_at,
    };
  }

  /**
   * Evin tum kullanilmamis servis PIN'lerini ve acik servis oturumlarini iptal eder; evin servis oturumu uygulama MQTT
   * kimlikleri (user_id bos) de silinir (uyelik-6: canli izleme kesilir).
   * Devir, acil sifirlama ve ev sahibinin "servis erisimini kapat" islemi kullanir.
   * `tx` VARSA MQTT kimlikleri ayni transaction'da silinir ve baglanti ATILMAZ: cagiran COMMIT SONRASI donen
   * `mqtt_usernames` icin kick yapar. `tx` YOKSA kimlik servisi silip hemen atar.
   * @param {string} homeId
   * @param {{query:Function}} [tx] db.withTransaction islem nesnesi (yoksa havuz)
   * @param {string} [reason]
   * @returns {Promise<{revoked_pins:number, revoked_sessions:number, mqtt_usernames:string[]}>}
   */
  async revokeHomeServiceAccess(homeId, tx = null, reason = 'home_revoked') {
    if (!homeId) throw new TypeError('revokeHomeServiceAccess: homeId zorunludur.');
    const q = tx || db;
    const pins = await q.query(
      `UPDATE service_tokens SET revoked_at = NOW()
        WHERE home_id = $1 AND revoked_at IS NULL AND used_at IS NULL
        RETURNING id`,
      [homeId]
    );
    const sessions = await q.query(
      `UPDATE service_sessions SET revoked_at = NOW(), revoked_reason = $2
        WHERE home_id = $1 AND revoked_at IS NULL
        RETURNING id`,
      [homeId, String(reason).slice(0, 40)]
    );
    for (const row of sessions.rows || []) invalidateServiceSessionCache(row.id);
    let mqttUsernames = [];
    const mqtt = this._mqtt();
    if (mqtt && typeof mqtt.revokeServiceSessionAccess === 'function') {
      const r = await mqtt.revokeServiceSessionAccess({ homeId, tx: tx || null });
      mqttUsernames = r && Array.isArray(r.usernames) ? r.usernames.slice() : [];
    }
    return {
      revoked_pins: (pins.rows || []).length,
      revoked_sessions: (sessions.rows || []).length,
      mqtt_usernames: mqttUsernames,
    };
  }

  /** Ev sahibi icin PIN gecmisi. PIN degeri DONMEZ (yalnizca ozeti saklanir). */
  async listServiceTokens(homeId) {
    const r = await db.query(
      `SELECT st.id, st.expires_at, st.used_at, st.revoked_at, st.created_at,
              COALESCE(st.is_used, FALSE) AS is_used,
              u.full_name AS created_by_name
         FROM service_tokens st
         LEFT JOIN users u ON st.created_by = u.id
        WHERE st.home_id = $1
        ORDER BY st.created_at DESC
        LIMIT 20`,
      [homeId]
    );
    const now = Date.now();
    return r.rows.map((row) => {
      let status = 'active';
      if (row.revoked_at) status = 'revoked';
      else if (row.used_at || row.is_used) status = 'used';
      else if (new Date(row.expires_at).getTime() <= now) status = 'expired';
      return {
        id: row.id,
        status,
        is_used: Boolean(row.used_at || row.is_used),
        expires_at: row.expires_at,
        used_at: row.used_at || null,
        revoked_at: row.revoked_at || null,
        created_at: row.created_at,
        created_by_name: row.created_by_name || null,
      };
    });
  }

  /** Evin acik (iptal edilmemis, suresi dolmamis) servis oturumlari. */
  async listActiveSessions(homeId) {
    const r = await db.query(
      `SELECT id, technician_name, created_at, expires_at
         FROM service_sessions
        WHERE home_id = $1 AND revoked_at IS NULL AND expires_at > NOW()
        ORDER BY created_at DESC`,
      [homeId]
    );
    return r.rows.map((row) => ({
      id: row.id,
      technician_name: row.technician_name,
      created_at: row.created_at,
      expires_at: row.expires_at,
    }));
  }
}

module.exports = new ServiceTokenService();
module.exports.ServiceTokenService = ServiceTokenService;
module.exports.PIN_TTL_SEC = PIN_TTL_SEC;
module.exports.SWEEP_INTERVAL_MS = SWEEP_INTERVAL_MS;
