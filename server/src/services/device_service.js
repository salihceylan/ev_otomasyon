'use strict';

// ==============================================================================
// AHBU Akilli Ev - Cihaz servisi (WP-B, denetim 2026-10-01)
//
// Sozlesme: docs/CONTRACTS.md §1 (REST), §2 (MQTT), §3 (yerel anahtar).
//
// Bu surumde kapatilan bulgular:
//   IDOR-komut, claim-yarisi, legacy-claim, sabit-parola-hesap, OTP-bypass, emergency-reset-PIN,
//   devirde-veri-temizlenmiyor, replaceBoard, mqttBridge.publish-yok, rollback-yok.
//
// Temel ilkeler:
//   * Komutlar YALNIZCA sunucudan (REST) gider; `ev/{t}/cmd` konusuna yalnizca backend yayin yapar.
//     Yayin hatasi YUTULMAZ (502 BROKER_UNAVAILABLE); cihaz cevrimdisiysa 409 DEVICE_OFFLINE.
//   * Sahiplenme / pano degisimi / acil sifirlama TEK transaction'dir (db.withTransaction);
//     envanter satiri FOR UPDATE ile kilitlenir; PIN deneme sayaci SQL icinde ATOMIK artar.
//     Basarisiz PIN/OTP denemesinin sayaci, hata firlatilmadan ONCE commit edilir
//     ("commit-then-throw"): aksi halde ROLLBACK sayaci geri alir ve kaba kuvvet korumasi isleyemez.
//   * Gizli degerler (PIN, OTP, parola, local key, kimlik) log'a ve denetim kaydina YAZILMAZ.
//   * Duz metin PIN hicbir kolonda saklanmaz (devices.setup_pin kullanilmaz).
//   * home_id YALNIZCA dogrulanmis uyelikten (req.homeAccess) gelir; govde/sorgu degeri esas alinmaz.
// ==============================================================================

const crypto = require('crypto');
const { generateNumericPin, isUuid } = require('../utils/helpers');
const { canonicalPhone } = require('../utils/phone');
const { httpError } = require('../utils/http_errors');
const { can } = require('../utils/role_matrix');
const { validateCommand, capabilityForCommand, isSafeTarget, KINDS } = require('../utils/command_schema');
const { endpointRowsFromTemplate } = require('../utils/template_schema');
// Yalniz saf yardimci (yer tutucu e-posta: telefon-OTP / Apple gizli / silinmis hesap); modul db yuklemez.
const { isPlaceholderEmail } = require('./account_deletion_service');

/**
 * tarama-sunucu-cihaz-site-3 (sozlesme C8): telefonla bulunan musterinin hesabinda gercek e-posta yoksa (telefon-OTP yer
 * tutucusu) personelin sahiplenme onay kodu gonderilemez; acik hata (OTP uretilmez). Musteri kendi uygulamasindan sahiplenir.
 */
function assertCustomerHasEmail(user) {
  if (user && isPlaceholderEmail(user.email)) {
    throw httpError(
      400,
      'Bu müşteri uygulamaya telefonla giriş yapıyor; hesabında e-posta olmadığı için onay kodu gönderilemez. Müşteri panoyu kendi uygulamasından etiketteki karekodla sahiplenmeli.',
      'VALIDATION',
      { reason: 'CUSTOMER_EMAIL_REQUIRED' }
    );
  }
}
const { localKeyFingerprint } = require('../utils/local_key_fp');

// --- Sabitler ---------------------------------------------------------------
const PIN_MAX_ATTEMPTS = 5;
const PIN_LOCK_MINUTES = 15;
const OTP_MAX_ATTEMPTS = 5;
const OTP_TTL_SECONDS = 15 * 60;
const OTP_RESEND_COOLDOWN_SECONDS = 60;
const OTP_ATTEMPT_WINDOW_MINUTES = 15;
const STAFF_INSTALL_WINDOW_HOURS = 72; // servis personelinin sahiplendigi evde kurulum penceresi
const BURNED_PIN = 'CLAIMED_BURNED_PIN'; // yakilmis PIN: hicbir ozet bu degere esit olamaz
// Acil sifirlama (stoga donus): yeni yerel anahtar sunucuda GECERLI ama panoya iletilemedi ('failed'); anahtar yanitta bir
// kez doner. Panoya bulut yolu kalmadi: gercek kurtarma yolu seri konsol RESETKEY + FACTORYINIT (istemci yonergesiyle ayni).
const LOCAL_KEY_FAILED_WARNING =
  'Yeni yerel anahtar panoya iletilemedi; anahtar yalnız bu yanıtta gösterilir. Panoya seri konsoldan RESETKEY ve ' +
  'ardından FACTORYINIT ile (fabrika aracı) yazılabilir.';
const RESET_REASON_MIN_LENGTH = 15;
const MAX_TEXT_LENGTH = 500;
const DEFAULT_HOME_NAME = 'Evim';
const DEFAULT_MODEL = 'ESP32-S3-POE-ETH-8DI-8RO';
const REQUIRED_COMMISSIONING_CHECKS = Object.freeze(['relays', 'buttons', 'shutters', 'network', 'cloud']);
// Toplu "isiklari kapat" komutlari (firmware'de esanlamli): evde priz varsa "Hepsini Kapat" kurali uygulanir (DAIRE-01).
const LIGHTS_OFF_GROUP_COMMANDS = Object.freeze(['all_lights_off', 'all_off']);
// Guvenlik komutlari (WP-S4, tasarim §5.2.4): uid ZORUNLU, hedef denetimi + hedef uid'nin onay/ret yankisi beklenir.
const SAFETY_KINDS = Object.freeze(['actuator', 'alarm_ack', 'alarm_test', 'safety_arm']);
const SAFETY_ACK_TIMEOUT_MS = 10 * 1000;
// Firmware ret kodlari (state.last_rej.code, tasarim §3.2) -> kullaniciya gosterilecek metin (§5.3.3)
const REJECTION_TEXT = Object.freeze({
  zone_latched: 'Alarm sürerken vana açılamaz. Önce sensörün kuruduğundan emin olup alarmı onaylayın.',
  zone_test: 'Bölge testi sürüyor; test bitince yeniden deneyin.',
  actuator_relay: 'Bu kanal bir güvenlik cihazına bağlı; lamba gibi açılamaz.',
  unknown_actuator: 'Pano bu eylemciyi tanımıyor; yapılandırmayı kontrol edin.',
  bad_state: 'Bu cihaz için geçersiz hedef durum.',
  unsupported: 'Pano yazılımı bu komutu desteklemiyor.',
  cfg_conflict: 'Panodaki yapılandırma değişmiş; güncel durumu yükleyip yeniden deneyin.',
  cfg_invalid: 'Yapılandırma geçersiz.',
  gas_local_only: 'Gaz vanası güvenlik gereği yalnız yerinde, panodaki düğmeyle açılır.',
  stale_ack: 'Bu arada yeni bir alarm oluştu; lütfen güncel alarmı inceleyip yeniden onaylayın.',
  safe_mode: 'Pano güvenli kipte; vanalar açılamaz. Kurulumcunuza başvurun.',
  bad_cmd: 'Pano komutu geçersiz buldu.',
  busy: 'Pano meşgul; birkaç saniye sonra yeniden deneyin.',
  not_ready: 'Alarm kurulamadı: açık kapı ya da pencere var.', // F2.B.7 kurma reddi
});

const DEVICE_UUID_PATTERN = /^AHBU-[A-Z0-9-]{3,32}$/;
const EMAIL_PATTERN = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const SIX_DIGITS = /^\d{6}$/;
const TIME_HHMM = /^([01]\d|2[0-3]):[0-5]\d$/;

// Karar 18: evde guvenlik yapilandirmasi var mi? Bulut kopyasi device_configs 'safety' govdesinde sensor ya da eylemci
// (vana / siren). Yalniz bolge ADI tanimli govde sayilmaz (pano degisimindeki safety_restore kurali ile ayni, C4).
const HAS_SAFETY_CONFIG_SQL =
  `SELECT EXISTS (
     SELECT 1 FROM devices d
       JOIN device_configs c ON c.device_id = d.id AND c.module = 'safety'
      WHERE d.home_id = $1
        AND (COALESCE(c.body -> 'sensors', '[]'::jsonb) NOT IN ('[]'::jsonb, 'null'::jsonb)
          OR COALESCE(c.body -> 'actuators', '[]'::jsonb) NOT IN ('[]'::jsonb, 'null'::jsonb))
   ) AS has_safety_config`;

// --- Saf yardimcilar -----------------------------------------------------------

function normalizeDeviceUuid(value) {
  if (typeof value !== 'string') return null;
  const v = value.trim().toUpperCase();
  return DEVICE_UUID_PATTERN.test(v) ? v : null;
}

/** Musteri kimligi: e-posta (kucuk harf) veya telefon (yalniz rakam ve basta +). */
function normalizeIdentifier(raw) {
  if (typeof raw !== 'string') return null;
  const s = raw.trim();
  if (!s || s.length > 255) return null;
  if (s.includes('@')) {
    const email = s.toLowerCase();
    return EMAIL_PATTERN.test(email) ? { type: 'email', value: email } : null;
  }
  const phone = s.replace(/[\s().-]/g, '');
  // karar 11: TR cep numarasi kanonik "+905XXXXXXXXX" (kullanici kaydi ve 042 ile ayni bicim)
  return /^\+?\d{7,15}$/.test(phone) ? { type: 'phone', value: canonicalPhone(phone) } : null;
}

function digitsOf(value) {
  return String(value || '').replace(/\D/g, '');
}

function maskEmail(email) {
  const s = String(email || '');
  const at = s.indexOf('@');
  if (at < 1) return '***';
  const domain = s.slice(at + 1);
  const dot = domain.lastIndexOf('.');
  return `${s[0]}***@${domain[0] || ''}***${dot > 0 ? domain.slice(dot) : ''}`;
}

/** Model adindan ("...-8DI-8RO") varsayilan role (kanal) sayisi; bulunamazsa 8. endpoints CHECK: 1..40. */
function channelCountForModel(model) {
  const m = /(\d{1,2})\s*RO\b/i.exec(String(model || ''));
  const n = m ? parseInt(m[1], 10) : 8;
  return Math.min(Math.max(Number.isFinite(n) ? n : 8, 1), 40);
}

function secondsUntil(date, now) {
  return Math.max(1, Math.ceil((new Date(date).getTime() - now.getTime()) / 1000));
}

function textOrNull(value, maxLength) {
  if (value === undefined || value === null) return null;
  if (typeof value !== 'string') return undefined; // gecersiz tip
  const t = value.trim();
  if (t.length === 0) return null;
  return t.length > maxLength ? undefined : t;
}

function isDebugOtpAllowed(env) {
  return env.ALLOW_DEBUG_OTP === 'true' && env.NODE_ENV !== 'production';
}

// Varsayilan kanal yerlesimi: firmware v1.3.2 fabrika varsayilaniyla ayni (SystemConfig.h applyFactoryRelayDefaults).
// Sahip karari (2026-10-09): hicbir rolenin sabit gorevi yok -> 1-8 "Röle N", 9+ "Ek Modül Röle N"; hepsi lamba, oda Genel.
// Panjur yalniz servisin sablonundan / panonun gercek yerlesiminden gelir. TEK INSERT ... SELECT generate_series.
const SEED_ENDPOINTS_SQL = `
  INSERT INTO endpoints (home_id, device_id, channel_index, name, type, room, shutter_pair_index, shutter_duration_sec)
  SELECT $1::uuid, $2::uuid, g.n,
         CASE WHEN g.n <= 8 THEN 'Röle ' || g.n ELSE 'Ek Modül Röle ' || (g.n - 8) END,
         'light', 'Genel', NULL::int, NULL::int
    FROM generate_series(1, $3::int) AS g(n)
  ON CONFLICT (device_id, channel_index) DO NOTHING`;

class DeviceService {
  /**
   * @param {object} [deps] test icin: { db, mqttBridge, mqttCredentials, pin, secretBox, mailer,
   *                        authService, cleanupHome, bcrypt, inviteCustomer, now, env }
   */
  constructor(deps = {}) {
    this._deps = deps;
  }

  // --- bagimliliklar (tembel; modul yuklenirken db.js / DATABASE_URL gerektirmez) ---
  get db() {
    return this._deps.db || require('../db');
  }
  get bridge() {
    return this._deps.mqttBridge || require('../mqtt_bridge');
  }
  get credentials() {
    return this._deps.mqttCredentials || require('./mqtt_credential_service');
  }
  get pin() {
    return this._deps.pin || require('../utils/pin');
  }
  get secretBox() {
    return this._deps.secretBox || require('../utils/secret_box');
  }
  get mailer() {
    return this._deps.mailer || require('../utils/mailer');
  }
  get bcrypt() {
    return this._deps.bcrypt || require('bcryptjs');
  }
  /** auth_service (uyelik-1: dogrulanmamis on-hesap etkisizlestirme; davet). Tembel: test enjekte eder. */
  get auth() {
    return this._deps.authService || require('./auth_service');
  }
  get env() {
    return this._deps.env || process.env;
  }
  /**
   * Gece huzur v2 (WP-H): ayar GET + "Hepsini kapat" ayri modulde; yardimcilar ENJEKTE edilir.
   * Tembel: this.db getter'i db.js'i (DATABASE_URL ister) ancak ilk kullanimda yukler.
   */
  get peace() {
    if (this._deps.peace) return this._deps.peace;
    if (!this._peace) {
      const { createPeaceService } = require('./peace_service');
      this._peace = createPeaceService({
        db: this.db,
        publishCommand: (topicId, payload) => this._publishCommand(topicId, payload),
        newCommandId: () => this._newCommandId(),
        audit: (q, args) => this._audit(q, args),
        httpError,
        now: () => this._now(),
      });
    }
    return this._peace;
  }
  _now() {
    return this._deps.now ? this._deps.now() : new Date();
  }
  _cleanupHome(tx, homeId, options) {
    const fn = this._deps.cleanupHome || require('./home_cleanup').cleanupHome;
    return fn(tx, homeId, options);
  }

  // ===========================================================================
  // Ortak yardimcilar
  // ===========================================================================

  async _pinMatches(plain, stored) {
    const result = await this.pin.verifyPin(plain, stored);
    return result === true || Boolean(result && result.valid === true);
  }

  _bridgeConnected() {
    const bridge = this.bridge;
    return typeof bridge.isConnected === 'function' ? Boolean(bridge.isConnected()) : false;
  }

  /** Komut yayini: hata YUTULMAZ, 502 BROKER_UNAVAILABLE olarak yuzeye cikar. */
  async _publishCommand(topicId, payload) {
    if (!this._bridgeConnected()) {
      throw httpError(502, 'MQTT broker bağlantısı yok; komut iletilemedi.', 'BROKER_UNAVAILABLE');
    }
    try {
      await this.bridge.publishCommand(topicId, payload);
    } catch (err) {
      console.error('[DEVICE] Komut yayinlanamadi:', err && err.message);
      throw httpError(502, 'Komut MQTT broker üzerinden iletilemedi.', 'BROKER_UNAVAILABLE');
    }
  }

  /** Yonetim konusu (ev/{t}/sys): koprunun publishSys'i (yuk loglanmaz); eski kopru icin publishToTopic yedegi. */
  async _publishSys(topicId, obj) {
    const bridge = this.bridge;
    if (typeof bridge.publishSys === 'function') return bridge.publishSys(topicId, obj);
    return bridge.publishToTopic(`ev/${topicId}/sys`, obj);
  }

  /** Bu ev icin yeni bekleyen niyet yazildi: kopru uzlastiricisi sonraki canli state'te kontrol etsin. En iyi caba. */
  _requestReconcile(topicId) {
    try {
      const bridge = this.bridge;
      if (bridge && typeof bridge.requestReconcile === 'function') bridge.requestReconcile(topicId);
    } catch (_) {
      /* en iyi caba: uzlastirici yine en gec sonraki cevrimici donemde kontrol eder */
    }
  }

  _newCommandId() {
    // 12 karakter [A-Za-z0-9_-]: firmware `id` kurali ^[A-Za-z0-9._:-]{1,24}$ ile uyumlu (UUID degil, kisa rastgele).
    return crypto.randomBytes(9).toString('base64url');
  }

  /**
   * Istemciye (servis sihirbazi / uygulama) donen cihaz MQTT kimligi - TEK SEFERLIK parola icerir.
   * `mqtt_server` / `mqtt_port`: servis sihirbazinin firmware'e yazdigi `POST /api/mqtt/config {server, port, user, pass}`
   * alanlari. `mqtt_server` DNS ADIDIR (MQTT_PUBLIC_HOST): firmware TLS sertifikasini ana makine adiyla dogrular (IP olmaz).
   * `host` / `port` geriye donuk uyumluluk icin ayni degerlerle korunur.
   */
  _publicDeviceCredential(credential) {
    return {
      host: credential.host,
      port: credential.port,
      mqtt_server: credential.host,
      mqtt_port: credential.port,
      username: credential.username,
      password: credential.password,
      client_id: credential.client_id,
      topic_id: credential.topic_id,
    };
  }

  async _audit(q, { event, deviceUuid = null, homeId = null, actor = null, details = null }) {
    await q(
      `INSERT INTO device_audit_logs (event, device_uuid, home_id, actor_user_id, actor_role, ip_address, details)
       VALUES ($1, $2, $3, $4, $5, $6, $7)`,
      [
        event,
        deviceUuid,
        homeId,
        (actor && actor.userId) || null,
        (actor && (actor.globalRole || actor.access)) || null,
        (actor && actor.ip) || null,
        details ? JSON.stringify(details) : null,
      ]
    );
  }

  /**
   * Envanter satirinda (FOR UPDATE ile KILITLI) kurulum PIN'ini dogrular.
   * Yanlis PIN'de sayac SQL icinde atomik artar; 5. hatada 15 dk kilit. Hata FIRLATILMAZ,
   * { ok:false, error } doner: cagiran transaction'i COMMIT edip hatayi sonra atar.
   */
  async _checkInventoryPin(tx, inv, plainPin) {
    const now = this._now();

    if (inv.locked_until && new Date(inv.locked_until).getTime() > now.getTime()) {
      const retryAfter = secondsUntil(inv.locked_until, now);
      return {
        ok: false,
        error: httpError(
          423,
          `Çok fazla hatalı PIN denemesi yapıldı. Cihaz kilitli; ${Math.ceil(retryAfter / 60)} dakika sonra tekrar deneyin.`,
          'PIN_LOCKED',
          { retry_after: retryAfter }
        ),
      };
    }

    if (await this._pinMatches(plainPin, inv.pin_hash)) {
      return { ok: true };
    }

    const upd = await tx.query(
      `UPDATE device_inventory
          SET failed_attempts = COALESCE(failed_attempts, 0) + 1,
              locked_until = CASE WHEN COALESCE(failed_attempts, 0) + 1 >= $2
                                  THEN NOW() + ($3 * INTERVAL '1 minute')
                                  ELSE locked_until END
        WHERE id = $1
        RETURNING failed_attempts, locked_until`,
      [inv.id, PIN_MAX_ATTEMPTS, PIN_LOCK_MINUTES]
    );
    const row = upd.rows[0] || {};
    const attempts = Number(row.failed_attempts) || 0;

    if (row.locked_until && new Date(row.locked_until).getTime() > now.getTime()) {
      const retryAfter = secondsUntil(row.locked_until, now);
      return {
        ok: false,
        error: httpError(
          423,
          `${PIN_MAX_ATTEMPTS} kez hatalı PIN girildi. Cihaz güvenlik nedeniyle ${PIN_LOCK_MINUTES} dakika kilitlendi.`,
          'PIN_LOCKED',
          { retry_after: retryAfter }
        ),
      };
    }

    const remaining = Math.max(0, PIN_MAX_ATTEMPTS - attempts);
    return {
      ok: false,
      error: httpError(
        403,
        `Geçersiz kurulum PIN kodu. Kalan deneme hakkı: ${remaining}`,
        'FORBIDDEN',
        { remaining_attempts: remaining }
      ),
    };
  }

  /** Envanter durumuna gore sahiplenmeye/degisime uygun mu; degilse hata firlatir. */
  _assertInventoryClaimable(inv) {
    if (inv.status === 'REVOKED') {
      throw httpError(403, 'Bu cihaz arıza veya iade gerekçesiyle iptal edilmiştir. Yetkili servisle iletişime geçin.', 'FORBIDDEN');
    }
    if (inv.status === 'SUSPENDED') {
      throw httpError(403, 'Bu cihaz yönetici tarafından askıya alınmıştır. Kurulum yapılamaz.', 'FORBIDDEN');
    }
    if (inv.status === 'CLAIMED') {
      throw httpError(409, 'Bu cihaz zaten bir daireye tanımlanmıştır. Tekrar sahiplenilemez.', 'CONFLICT');
    }
  }

  /** Yerel anahtar: envanterde (fabrika) varsa AYNEN kullanilir, yoksa uretilip sifrelenir. */
  _resolveLocalKeyEnc(inv) {
    if (inv && inv.local_key_enc) return { enc: inv.local_key_enc, generated: false };
    const key = this.secretBox.generateLocalKey();
    return { enc: this.secretBox.encrypt(key), generated: true };
  }

  /**
   * MAC cakismasi: ayni MAC baska bir cihaz kaydinda (farkli UUID) varsa
   *  - kaydi yetim ise (evi yok) MAC'i arsivlenir (cakisma giderilir),
   *  - bir daireye bagliysa 409 (veri tutarsizligi; sessizce calinmaz).
   */
  async _resolveMacConflict(tx, mac, deviceUuid) {
    const res = await tx.query(
      `SELECT id, home_id, is_claimed FROM devices WHERE mac_address = $1 AND device_uuid <> $2 FOR UPDATE`,
      [mac, deviceUuid]
    );
    for (const row of res.rows) {
      if (row.home_id || row.is_claimed) {
        throw httpError(
          409,
          'Bu cihazın MAC adresi başka bir kayıtla çakışıyor. Yetkili servisle iletişime geçin.',
          'CONFLICT'
        );
      }
      await tx.query(
        `UPDATE devices
            SET mac_address = left(mac_address, 17) || '-DUP-' || left(id::text, 8),
                updated_at = CURRENT_TIMESTAMP
          WHERE id = $1`,
        [row.id]
      );
    }
  }

  async _seedEndpoints(tx, homeId, deviceId, model) {
    // Eski bir daireye bagli kalmis (yetim) kanal satirlari varsa once temizle.
    await tx.query('DELETE FROM endpoints WHERE device_id = $1 AND home_id <> $2', [deviceId, homeId]);
    const res = await tx.query(SEED_ENDPOINTS_SQL, [homeId, deviceId, channelCountForModel(model)]);
    return res.rowCount || 0;
  }

  /**
   * Claim (K-S8, migration 035): kart silinmemis bir sitedeki daireye bagliysa daire + kartin SON BASARILI sablon
   * yaziminin surum govdesi. Daire satiri kilitlenir (ayni karti iki claim'in siralanmasi zaten envanter kilidinde).
   * @returns {Promise<null | {flat_id, block, number, status, site_name, template_id, version, template_body}>}
   */
  async _loadFlatSeed(tx, deviceUuid) {
    // Migration 035 uygulanmadan yeniden baslatilan surumde claim BOZULMAZ: tablo yoksa daire baglantisi yok sayilir.
    if (!(await this._hasSchema035(tx))) return null;
    const res = await tx.query(
      `SELECT f.id AS flat_id, f.block, f.number, f.status, s.name AS site_name,
              w.template_id, w.version, v.body AS template_body
         FROM site_flats f JOIN sites s ON s.id = f.site_id AND s.deleted_at IS NULL
         LEFT JOIN LATERAL (
           SELECT tw.template_id, tw.version
             FROM template_writes tw
            WHERE tw.device_uuid = f.device_uuid AND tw.result = 'ok'
            ORDER BY tw.created_at DESC, tw.id DESC
            LIMIT 1
         ) w ON TRUE
         LEFT JOIN install_template_versions v ON v.template_id = w.template_id AND v.version = w.version
        WHERE f.device_uuid = $1
        FOR UPDATE OF f`,
      [deviceUuid]
    );
    return res.rows[0] || null;
  }

  /**
   * Migration 035 nesneleri (site_flats, template_writes, install_template_versions, devices.template_*) var mi?
   * Islem icinde 42P01/42703 hatasi islemi bozacagi icin hata yakalamak yerine katalog sorgulanir. Olumlu sonuc
   * onbelleklenir (migration geri alinmaz); olumsuz sonuc her cagrida yeniden denenir (yeniden baslatmadan once
   * uygulanan migration hemen etkin olur).
   */
  async _hasSchema035(tx) {
    if (this._schema035 === true) return true;
    const res = await tx.query(
      `SELECT (to_regclass('site_flats') IS NOT NULL
               AND to_regclass('template_writes') IS NOT NULL
               AND to_regclass('install_template_versions') IS NOT NULL
               AND EXISTS (SELECT column_name FROM information_schema.columns
                            WHERE table_schema = current_schema() AND table_name = 'devices'
                              AND column_name = 'template_version')) AS schema_035`
    );
    const ok = Boolean(res.rows[0] && res.rows[0].schema_035);
    if (ok) this._schema035 = true;
    return ok;
  }

  /**
   * guvenlik-1: evden AYRILAN panonun acik (cleared/lost olmayan) alarm kayitlarini kapatir: status 'lost',
   * cleared_by 'detached', onay istegi temizlenir. Pano degisimi ve stoga donus (acil sifirlama UNCLAIMED) kullanir.
   */
  async _detachDeviceAlarms(tx, deviceId) {
    await tx.query(
      `UPDATE alarms SET status = 'lost', cleared_at = CURRENT_TIMESTAMP, cleared_by = 'detached',
              ack_requested_at = NULL, ack_requested_by = NULL, ack_requested_sid = NULL, updated_at = CURRENT_TIMESTAMP
        WHERE device_id = $1 AND status NOT IN ('cleared', 'lost')`,
      [deviceId]
    );
  }

  /** Panonun bildirdigi yuklu sablon kaydini (devices.template_*) temizler; 035 yoksa sessizce atlanir. */
  async _clearDeviceTemplate(tx, deviceId) {
    if (!(await this._hasSchema035(tx))) return;
    await tx.query(
      'UPDATE devices SET template_id = NULL, template_version = NULL, template_reported_at = NULL WHERE id = $1',
      [deviceId]
    );
  }

  /** Uc noktalari sablon govdesinden tohumlar; govde kullanilamazsa null (cagiran sabit tohuma duser). */
  async _seedEndpointsFromTemplate(tx, homeId, deviceId, body) {
    const rows = endpointRowsFromTemplate(body);
    if (!rows) return null;
    await tx.query('DELETE FROM endpoints WHERE device_id = $1 AND home_id <> $2', [deviceId, homeId]);
    const res = await tx.query(
      `INSERT INTO endpoints (device_id, home_id, channel_index, name, type, room, shutter_pair_index, shutter_duration_sec,
                              actuator_type, dimmable, dimmer_source)
       SELECT $1::uuid, $2::uuid, x.channel_index, x.name, x.type, x.room, x.shutter_pair_index, x.shutter_duration_sec,
              x.actuator_type, COALESCE(x.dimmable, FALSE), x.dimmer_source
         FROM jsonb_to_recordset($3::jsonb) AS x(channel_index int, name text, type text, room text, shutter_pair_index int,
                                                shutter_duration_sec int, actuator_type text, dimmable boolean, dimmer_source text)
       ON CONFLICT (device_id, channel_index) DO NOTHING`,
      [deviceId, homeId, JSON.stringify(rows)]
    );
    return res.rowCount || 0;
  }

  async _createHome(tx, name) {
    for (let attempt = 0; attempt < 5; attempt++) {
      const topicId = this.credentials.generateTopicId();
      const res = await tx.query(
        `INSERT INTO homes (name, mqtt_username) VALUES ($1, $2)
         ON CONFLICT (mqtt_username) DO NOTHING
         RETURNING id, name, mqtt_username`,
        [name, topicId]
      );
      if (res.rows.length > 0) return res.rows[0];
    }
    throw httpError(500, 'Daire oluşturulamadı. Lütfen tekrar deneyin.', 'INTERNAL');
  }

  /** Musteri hesabi icin davet (hesap kurulum) gonderimi: en iyi cabada, claim'i ASLA bozmaz. */
  async _inviteCustomer({ userId, email, fullName }) {
    if (typeof this._deps.inviteCustomer === 'function') {
      try {
        const r = await this._deps.inviteCustomer({ userId, email, fullName });
        return { sent: Boolean(r && r.sent !== false) };
      } catch (_) {
        return { sent: false, reason: 'INVITE_FAILED' };
      }
    }
    let auth = null;
    try {
      auth = this._deps.authService || require('./auth_service');
    } catch (_) {
      return { sent: false, reason: 'NO_INVITE_API' };
    }
    try {
      if (typeof auth.createAccountSetupInvite === 'function') {
        const r = await auth.createAccountSetupInvite({ userId, email, fullName });
        return { sent: Boolean(r && r.sent !== false) };
      }
      if (typeof auth.requestPasswordReset === 'function') {
        await auth.requestPasswordReset(email);
        return { sent: true, via: 'password_reset' };
      }
    } catch (_) {
      return { sent: false, reason: 'INVITE_FAILED' };
    }
    return { sent: false, reason: 'NO_INVITE_API' };
  }

  // ===========================================================================
  // B4: Sahiplenme OTP'si (yalnizca staff/super)
  // ===========================================================================

  /**
   * Servis personeli icin musteriye 6 haneli onay kodu (OTP) gonderir.
   * - Yalnizca staff (service_user) / super_user; servis (PIN) oturumu OLAMAZ.
   * - Ayni (cihaz, hedef) icin yeniden istek 60 sn beklemeli; deneme sayaci yeniden istekle SIFIRLANMAZ
   *   (sayac 15 dk'lik pencerede tutulur).
   * - E-posta gonderimi basarisizsa hata yuzeye cikar (sahte basari yok) ve kod gecersiz kilinir.
   * - Tablo DDL'i yoktur (migration 017/021).
   */
  async requestClaimOtp({ actor, deviceUuid, targetOwnerIdentifier }) {
    if (!actor || !actor.userId || !['service_user', 'super_user'].includes(actor.globalRole)) {
      throw httpError(403, 'Bu işlem yalnızca yetkili servis personeli içindir.', 'FORBIDDEN');
    }
    const uuid = normalizeDeviceUuid(deviceUuid);
    if (!uuid) throw httpError(400, 'Geçersiz cihaz kimliği (device_uuid).', 'VALIDATION');
    const target = normalizeIdentifier(targetOwnerIdentifier);
    if (!target) throw httpError(400, 'Geçerli bir müşteri e-posta adresi veya telefon numarası girin.', 'VALIDATION');

    const db = this.db;

    // 1) Cihaz envanterde mi, durumu uygun mu?
    const invRes = await db.query('SELECT id, status FROM device_inventory WHERE device_uuid = $1', [uuid]);
    if (invRes.rows.length === 0) throw httpError(404, 'Bu cihaz envanterde kayıtlı değil.', 'NOT_FOUND');
    this._assertInventoryClaimable(invRes.rows[0]);

    // 2) Aktor + hedef: kendi adina kurulum yapilamaz; kodun gidecegi e-posta adresi belirlenir.
    const actorRes = await db.query('SELECT id, email, phone FROM users WHERE id = $1', [actor.userId]);
    const actorRow = actorRes.rows[0];
    if (!actorRow) throw httpError(403, 'Hesap bulunamadı.', 'FORBIDDEN');

    let recipient = null;
    let targetUser = null;
    if (target.type === 'email') {
      recipient = target.value;
      const ur = await db.query('SELECT id FROM users WHERE LOWER(email) = $1', [target.value]);
      targetUser = ur.rows[0] || null;
    } else {
      const ur = await db.query(
        `SELECT id, email FROM users WHERE regexp_replace(COALESCE(phone, ''), '[^0-9+]', '', 'g') = $1`,
        [target.value]
      );
      targetUser = ur.rows[0] || null;
      if (!targetUser || !targetUser.email) {
        throw httpError(
          400,
          'Bu telefon numarasına bağlı bir hesap yok. Kod e-posta ile gönderilir; müşterinin e-posta adresini girin.',
          'VALIDATION'
        );
      }
      assertCustomerHasEmail(targetUser);
      recipient = String(targetUser.email).toLowerCase();
    }

    const sameEmail = actorRow.email && String(actorRow.email).toLowerCase() === recipient;
    const samePhone =
      target.type === 'phone' && actorRow.phone && digitsOf(actorRow.phone) === digitsOf(target.value);
    if ((targetUser && targetUser.id === actorRow.id) || sameEmail || samePhone) {
      throw httpError(403, 'Servis personeli kendi adına cihaz kuramaz. Cihaz müşteriye tanımlanmalıdır.', 'FORBIDDEN');
    }

    // 3) Kod uret, ozetini sakla. Yeniden istek: bekleme + deneme sayaci KORUNUR.
    const code = String(crypto.randomInt(0, 1000000)).padStart(6, '0');
    const otpHash = await this.pin.hashPin(code);
    const expiresAt = new Date(this._now().getTime() + OTP_TTL_SECONDS * 1000);
    const identifier = target.type === 'email' ? target.value : recipient;

    const up = await db.query(
      `INSERT INTO device_claim_otps (device_uuid, target_identifier, otp_hash, expires_at, attempts, window_started_at, requested_by)
       VALUES ($1, $2, $3, $4, 0, NOW(), $5)
       ON CONFLICT (device_uuid, target_identifier) DO UPDATE SET
         otp_hash = EXCLUDED.otp_hash,
         expires_at = EXCLUDED.expires_at,
         requested_by = EXCLUDED.requested_by,
         created_at = NOW(),
         attempts = CASE WHEN device_claim_otps.window_started_at < NOW() - ($6 * INTERVAL '1 minute')
                         THEN 0 ELSE device_claim_otps.attempts END,
         window_started_at = CASE WHEN device_claim_otps.window_started_at < NOW() - ($6 * INTERVAL '1 minute')
                                  THEN NOW() ELSE device_claim_otps.window_started_at END
       WHERE device_claim_otps.created_at < NOW() - ($7 * INTERVAL '1 second')
       RETURNING attempts, window_started_at`,
      [uuid, identifier, otpHash, expiresAt, actor.userId, OTP_ATTEMPT_WINDOW_MINUTES, OTP_RESEND_COOLDOWN_SECONDS]
    );

    if (up.rows.length === 0) {
      // Bekleme suresi dolmadi.
      const w = await db.query(
        `SELECT GREATEST(1, CEIL($3 - EXTRACT(EPOCH FROM (NOW() - created_at))))::int AS wait_seconds
           FROM device_claim_otps WHERE device_uuid = $1 AND target_identifier = $2`,
        [uuid, identifier, OTP_RESEND_COOLDOWN_SECONDS]
      );
      const wait = (w.rows[0] && Number(w.rows[0].wait_seconds)) || OTP_RESEND_COOLDOWN_SECONDS;
      throw httpError(429, `Yeni kod istemek için ${wait} saniye bekleyin.`, 'RATE_LIMITED', { retry_after: wait });
    }

    const attempts = Number(up.rows[0].attempts) || 0;
    if (attempts >= OTP_MAX_ATTEMPTS) {
      const windowEnd = new Date(up.rows[0].window_started_at).getTime() + OTP_ATTEMPT_WINDOW_MINUTES * 60 * 1000;
      const wait = Math.max(1, Math.ceil((windowEnd - this._now().getTime()) / 1000));
      throw httpError(
        429,
        'Bu cihaz ve müşteri için çok fazla hatalı kod denemesi yapıldı. Lütfen daha sonra tekrar deneyin.',
        'RATE_LIMITED',
        { retry_after: wait }
      );
    }

    // 4) Gonderim sonucu YUZEYE cikar (SMTP yok / hata = hata). Kod hicbir yerde loglanmaz.
    let sendResult = null;
    try {
      sendResult = await this.mailer.sendClaimOtpEmail({ to: recipient, deviceUuid: uuid, code });
    } catch (_) {
      sendResult = { sent: false, reason: 'SEND_FAILED' };
    }

    const debugAllowed = isDebugOtpAllowed(this.env);
    if (!sendResult || sendResult.sent !== true) {
      if (!debugAllowed) {
        // Teslim edilmeyen kodu gecersiz kil ve beklemeyi kaldir (deneme sayaci korunur).
        await db.query(
          `UPDATE device_claim_otps
              SET expires_at = NOW(), created_at = NOW() - INTERVAL '1 day'
            WHERE device_uuid = $1 AND target_identifier = $2 AND otp_hash = $3`,
          [uuid, identifier, otpHash]
        );
        if (sendResult && sendResult.reason === 'INVALID_RECIPIENT') {
          throw httpError(400, 'Geçersiz e-posta adresi.', 'VALIDATION');
        }
        throw httpError(
          502,
          'Doğrulama e-postası gönderilemedi. Lütfen daha sonra tekrar deneyin.',
          'MAIL_UNAVAILABLE'
        );
      }
    }

    await this._audit((t, p) => db.query(t, p), {
      event: 'claim_otp_requested',
      deviceUuid: uuid,
      actor,
      details: { target_type: target.type },
    });

    const result = {
      message: `Doğrulama kodu ${maskEmail(recipient)} adresine gönderildi.`,
      expires_in: OTP_TTL_SECONDS,
      resend_after: OTP_RESEND_COOLDOWN_SECONDS,
    };
    if (debugAllowed) result.debug_code = code; // yalnizca gelistirmede (ALLOW_DEBUG_OTP=true, uretimde ASLA)
    return result;
  }

  // ===========================================================================
  // B3: Sahiplenme (claim) - TEK transaction
  // ===========================================================================

  /**
   * Karekod / elle girilen UID + PIN ile panoyu bir daireye sahiplendirir.
   *
   * Kurallar:
   *  - Envanter satiri FOR UPDATE; yalnizca envanterdeki cihazlar (eski `devices` yolu SILINDI).
   *  - Yanlis PIN: atomik sayac + 5. hatada 15 dk kilit (423 PIN_LOCKED).
   *  - target_owner: yalnizca staff/super; musteri OTP'si HER ZAMAN zorunlu; servis personeli kendi adina
   *    kuramaz. Musteri hesabi yoksa rastgele KULLANILAMAZ parola + account_status='pending_invite' ile
   *    acilir (sabit parola YOK) ve davet gonderilir.
   *  - Normal kullanici: home_id HIC alinmaz; ev sunucuda belirlenir (kendi bos evi veya yeni ev).
   *  - Yeni ev konu kimligi 'h_' + 16 hex; kanallar tek INSERT ... generate_series.
   *  - Cihaz kimligi (d_{t}) uretilir ve TEK SEFERLIK yanitla doner; local_key uretilip sifreli saklanir.
   */
  async claimDevice({ actor, deviceUuid, setupPin, homeName, targetOwnerIdentifier, otpCode }) {
    if (!actor || !actor.userId) {
      throw httpError(403, 'Bu işlem için kullanıcı hesabı gereklidir.', 'FORBIDDEN');
    }
    if (!['user', 'service_user', 'super_user'].includes(actor.globalRole)) {
      throw httpError(403, 'Bu işlem için yetkiniz bulunmamaktadır.', 'FORBIDDEN');
    }
    const isStaff = actor.globalRole === 'service_user' || actor.globalRole === 'super_user';

    // --- Girdi dogrulama (sayaclara dokunmadan) ---
    const uuid = normalizeDeviceUuid(deviceUuid);
    if (!uuid) throw httpError(400, 'Geçersiz cihaz kimliği (device_uuid).', 'VALIDATION');

    const pinText = typeof setupPin === 'string' || typeof setupPin === 'number' ? String(setupPin).trim() : '';
    if (!SIX_DIGITS.test(pinText)) throw httpError(400, 'Kurulum PIN kodu 6 haneli rakam olmalı.', 'VALIDATION');

    const name = textOrNull(homeName, 100);
    if (name === undefined) throw httpError(400, 'Daire adı en fazla 100 karakterlik bir metin olmalı.', 'VALIDATION');

    let target = null;
    if (targetOwnerIdentifier !== undefined && targetOwnerIdentifier !== null && targetOwnerIdentifier !== '') {
      target = normalizeIdentifier(targetOwnerIdentifier);
      if (!target) throw httpError(400, 'Geçerli bir müşteri e-posta adresi veya telefon numarası girin.', 'VALIDATION');
    }

    if (target && !isStaff) {
      throw httpError(403, 'Müşteri adına kurulum yalnızca yetkili servis personeli tarafından yapılabilir.', 'FORBIDDEN');
    }
    if (actor.globalRole === 'service_user' && !target) {
      throw httpError(
        400,
        'Servis personeli kendi adına cihaz sahiplenemez. Müşteri e-posta/telefon bilgisini (target_owner) girin.',
        'VALIDATION'
      );
    }

    let otp = null;
    if (target) {
      otp = typeof otpCode === 'string' || typeof otpCode === 'number' ? String(otpCode).trim() : '';
      if (!SIX_DIGITS.test(otp)) {
        throw httpError(400, 'Müşteriye gönderilen 6 haneli doğrulama kodu zorunludur.', 'VALIDATION');
      }
    }

    // Yeni hesap gerekirse rastgele, KULLANILAMAZ parolanin ozeti islem DISINDA hesaplanir (kilit suresi kisa kalsin).
    const unusablePasswordHash = target
      ? await this.bcrypt.hash(crypto.randomBytes(32).toString('hex'), 12)
      : null;

    const outcome = await this.db.withTransaction(async (tx) => {
      // 0) Aktor (guncel kayit): aktif olmali
      const actorRes = await tx.query(
        'SELECT id, email, phone, role, is_active FROM users WHERE id = $1',
        [actor.userId]
      );
      const actorRow = actorRes.rows[0];
      if (!actorRow || actorRow.is_active === false) {
        throw httpError(403, 'Hesabınız aktif değil.', 'FORBIDDEN');
      }

      // 1) Envanter satirini KILITLE (esdeger iki claim sirayla calisir)
      const invRes = await tx.query(
        `SELECT id, device_uuid, mac_address, pin_hash, model, status, failed_attempts, locked_until, local_key_enc
           FROM device_inventory
          WHERE device_uuid = $1
          FOR UPDATE`,
        [uuid]
      );
      if (invRes.rows.length === 0) {
        throw httpError(404, 'Bu cihaz envanterde kayıtlı değil.', 'NOT_FOUND');
      }
      const inv = invRes.rows[0];

      // 1b) Yaniti kaybolan claim'in tekrari (bireysel-3): kart zaten ISTEYENIN sahibi oldugu evdeyse acik 409
      //     (reason ALREADY_YOURS + ev). Yalniz evin sahibine; yeni kimlik URETILMEZ, PIN sayacina dokunulmaz.
      if (inv.status === 'CLAIMED' && !target) {
        const mine = await tx.query(
          `SELECT d.home_id, h.name
             FROM devices d
             JOIN homes h ON h.id = d.home_id
             JOIN home_users hu ON hu.home_id = d.home_id AND hu.user_id = $2 AND hu.role = 'owner'
            WHERE d.device_uuid = $1`,
          [uuid, actor.userId]
        );
        if (mine.rows[0]) {
          throw httpError(409, 'Bu cihaz zaten sizin dairenize tanımlı.', 'CONFLICT', {
            reason: 'ALREADY_YOURS',
            data: { home_id: mine.rows[0].home_id, home_name: mine.rows[0].name },
          });
        }
      }

      // 2) Durum (CLAIMED / REVOKED / SUSPENDED sayaclara dokunmadan reddedilir)
      this._assertInventoryClaimable(inv);

      // 3) PIN (kilit + atomik sayac). Basarisizlikta sayac commit edilip hata sonra atilir.
      const pinCheck = await this._checkInventoryPin(tx, inv, pinText);
      if (!pinCheck.ok) return { ok: false, error: pinCheck.error };

      // 3b) Site dairesi (K-S8, migration 035): kart bir daireye bagliysa ev adi "<site> <blok>-<no>" ve uc nokta tohumu
      //     karta son basariyla yazilan sablon surumunden. Bagli degilse davranis AYNEN.
      const flatSeed = await this._loadFlatSeed(tx, uuid);
      const flatHomeName = flatSeed ? `${flatSeed.site_name} ${flatSeed.block}-${flatSeed.number}`.slice(0, 100) : null;

      // 4) Ayni musteri icin eszamanli sahiplenmeleri sirala (bos ev secimi / hesap olusturma yarisi)
      await tx.query('SELECT pg_advisory_xact_lock(hashtext($1))', [
        `claim-owner:${target ? target.value : actor.userId}`,
      ]);

      // 5) Hedef sahip
      let owner = { id: actor.userId, email: actorRow.email };
      let createdAccount = null;
      let pendingCustomer = null; // mevcut (ya da sifirlanan) pending_invite musteri: COMMIT sonrasi davet (uyelik-1)
      let neutralized = null; // dogrulanmamis on-hesap etkisizlestirme sonucu (COMMIT sonrasi finishNeutralize)
      let securityReset = false; // aktif + dogrulanmamis hesap sifirlandi mi

      if (target) {
        // 5a) Hedef hesap (var mi?) ve OTP kimligi. OTP her zaman e-posta adresine gider:
        //     telefonla verilen hedefte kimlik, hesabin e-postasidir (requestClaimOtp ile ayni kural).
        let customer = null;
        let identifier;
        if (target.type === 'email') {
          identifier = target.value;
          const ur = await tx.query(
            'SELECT id, email, full_name, is_active, role, email_verified, account_status FROM users WHERE LOWER(email) = $1',
            [identifier]
          );
          customer = ur.rows[0] || null;
        } else {
          const ur = await tx.query(
            `SELECT id, email, full_name, is_active, role, email_verified, account_status FROM users
              WHERE regexp_replace(COALESCE(phone, ''), '[^0-9+]', '', 'g') = $1`,
            [target.value]
          );
          customer = ur.rows[0] || null;
          if (!customer || !customer.email) {
            throw httpError(400, 'Bu telefon numarasına bağlı hesap yok. Müşterinin e-posta adresini girin.', 'VALIDATION');
          }
          assertCustomerHasEmail(customer);
          identifier = String(customer.email).toLowerCase();
        }
        if (customer && customer.id === actorRow.id) {
          throw httpError(403, 'Servis personeli kendi adına cihaz sahibi olamaz. Cihaz müşteriye tanımlanmalıdır.', 'FORBIDDEN');
        }
        if (customer && customer.is_active === false) {
          throw httpError(409, 'Müşteri hesabı aktif değil. Yetkili servisle iletişime geçin.', 'CONFLICT');
        }
        if (customer && customer.role === 'service_user') {
          throw httpError(403, 'Servis personeli hesabı cihaz sahibi olamaz. Cihaz müşteri hesabına tanımlanmalıdır.', 'FORBIDDEN');
        }

        // 5b) Musteri OTP'si: dogrula + tuket (atomik sayac, commit-then-throw)
        const otpRes = await tx.query(
          `SELECT id, otp_hash, attempts, expires_at, window_started_at
             FROM device_claim_otps
            WHERE device_uuid = $1 AND target_identifier = $2
            FOR UPDATE`,
          [uuid, identifier]
        );
        const otpRow = otpRes.rows[0];
        const now = this._now();
        if (!otpRow || new Date(otpRow.expires_at).getTime() <= now.getTime()) {
          throw httpError(400, 'Geçerli bir doğrulama kodu bulunamadı veya süresi doldu. Yeni kod isteyin.', 'VALIDATION');
        }
        if (Number(otpRow.attempts) >= OTP_MAX_ATTEMPTS) {
          const windowEnd =
            new Date(otpRow.window_started_at).getTime() + OTP_ATTEMPT_WINDOW_MINUTES * 60 * 1000;
          return {
            ok: false,
            error: httpError(
              429,
              'Çok fazla hatalı doğrulama kodu denemesi yapıldı. Lütfen daha sonra tekrar deneyin.',
              'RATE_LIMITED',
              { retry_after: Math.max(1, Math.ceil((windowEnd - now.getTime()) / 1000)) }
            ),
          };
        }
        if (!(await this._pinMatches(otp, otpRow.otp_hash))) {
          const upd = await tx.query(
            'UPDATE device_claim_otps SET attempts = attempts + 1 WHERE id = $1 RETURNING attempts',
            [otpRow.id]
          );
          const remaining = Math.max(0, OTP_MAX_ATTEMPTS - (Number(upd.rows[0] && upd.rows[0].attempts) || 0));
          return {
            ok: false,
            error: httpError(400, `Hatalı doğrulama kodu. Kalan deneme hakkı: ${remaining}`, 'VALIDATION', {
              remaining_attempts: remaining,
            }),
          };
        }
        await tx.query('DELETE FROM device_claim_otps WHERE id = $1', [otpRow.id]);

        // 5b2) On-hesap ele gecirme savunmasi (uyelik-1): DOGRULANMAMIS mevcut hesap (baskasi musterinin e-postasiyla
        //      onceden kaydolmus olabilir) owner yapilmadan ONCE ve AYNI tx'te etkisizlestirilir: parola kullanilamaz,
        //      tum oturumlar + MQTT kimlikleri iptal, aktifse pending_invite. Musteri davetle kendi parolasini belirler.
        if (customer && customer.email_verified === false) {
          const wasActive = customer.account_status === 'active';
          neutralized = await this.auth.neutralizeUnverifiedAccount(customer.id, {
            tx,
            reason: 'staff_claim_unverified',
            unusableHash: unusablePasswordHash,
          });
          if (neutralized && neutralized.neutralized) {
            securityReset = wasActive;
            if (wasActive) customer = { ...customer, account_status: 'pending_invite' };
          }
        }
        if (customer && customer.account_status === 'pending_invite') {
          pendingCustomer = { id: customer.id, email: customer.email, full_name: customer.full_name };
        }

        // 5c) Musteri hesabi yoksa KULLANILAMAZ rastgele parola + pending_invite ile ac (sabit parola YOK)
        if (!customer) {
          const local = identifier.split('@')[0] || 'Ev Sahibi';
          const fullName = (local.charAt(0).toUpperCase() + local.slice(1)).slice(0, 100) || 'Ev Sahibi';
          const ins = await tx.query(
            `INSERT INTO users (full_name, email, password_hash, role, is_active, account_status, created_by_user_id)
             VALUES ($1, $2, $3, 'user', TRUE, 'pending_invite', $4)
             ON CONFLICT (email) DO NOTHING
             RETURNING id, email, full_name, is_active, role`,
            [fullName, identifier, unusablePasswordHash, actorRow.id]
          );
          if (ins.rows.length > 0) {
            customer = ins.rows[0];
            createdAccount = customer;
          } else {
            const again = await tx.query('SELECT id, email, full_name, is_active, role FROM users WHERE email = $1', [identifier]);
            customer = again.rows[0];
            if (!customer) throw httpError(409, 'Müşteri hesabı oluşturulamadı. Lütfen tekrar deneyin.', 'CONFLICT');
          }
        }
        owner = { id: customer.id, email: customer.email };
      }

      // 6) Cihaz kaydi baska bir daireye bagliysa CALINMAZ
      const existingDev = await tx.query(
        'SELECT id, home_id, is_claimed FROM devices WHERE device_uuid = $1 FOR UPDATE',
        [uuid]
      );
      if (existingDev.rows[0] && existingDev.rows[0].home_id && existingDev.rows[0].is_claimed) {
        throw httpError(409, 'Cihaz başka bir daireye bağlı görünüyor. Yetkili servisle iletişime geçin.', 'CONFLICT');
      }

      // 7) Hedef daire: sahibin cihazsiz evi varsa o, yoksa YENI ev (rastgele konu kimligi)
      let home;
      const emptyHome = await tx.query(
        `SELECT h.id, h.name, h.mqtt_username
           FROM homes h
           JOIN home_users hu ON hu.home_id = h.id AND hu.user_id = $1 AND hu.role = 'owner'
          WHERE NOT EXISTS (SELECT 1 FROM devices d WHERE d.home_id = h.id)
          ORDER BY h.created_at ASC
          LIMIT 1
          FOR UPDATE OF h`,
        [owner.id]
      );
      if (emptyHome.rows.length > 0) {
        home = emptyHome.rows[0];
        if (flatHomeName && home.name !== flatHomeName) {
          const renamed = await tx.query('UPDATE homes SET name = $2 WHERE id = $1 RETURNING id, name, mqtt_username', [home.id, flatHomeName]);
          home = renamed.rows[0] || home;
        }
      } else {
        home = await this._createHome(tx, flatHomeName || name || DEFAULT_HOME_NAME);
        await tx.query(
          `INSERT INTO home_users (home_id, user_id, role) VALUES ($1, $2, 'owner')`,
          [home.id, owner.id]
        );
      }

      // Servis personeli: kurulumu tamamlayabilmesi icin SURELI servis uyeligi (super_user'a gerekmez)
      let technicianAccessUntil = null;
      if (actor.globalRole === 'service_user') {
        const m = await tx.query(
          `INSERT INTO home_users (home_id, user_id, role, installer_expires_at)
           VALUES ($1, $2, 'service_user', NOW() + ($3 * INTERVAL '1 hour'))
           ON CONFLICT (home_id, user_id) DO UPDATE
              SET installer_expires_at = EXCLUDED.installer_expires_at
            WHERE home_users.role = 'service_user'
           RETURNING installer_expires_at`,
          [home.id, actorRow.id, STAFF_INSTALL_WINDOW_HOURS]
        );
        technicianAccessUntil = m.rows[0] ? m.rows[0].installer_expires_at : null;
      }

      // 8) Cihaz (devices) kaydi: MAC cakismasi giderilir; duz metin PIN yazilmaz; yerel anahtar sifreli.
      //    Bekleyen yerel anahtara (local_key_pending_enc, SERVIS-01) DOKUNULMAZ: burada yazilan envanter anahtari
      //    panodaki GERCEK anahtardir (kurulum LAN'dan bununla yapilir); bekleyen anahtar pano buluta baglaninca
      //    uzlastiriciyla iletilir ve takas edilir.
      await this._resolveMacConflict(tx, inv.mac_address, uuid);
      const localKey = this._resolveLocalKeyEnc(inv);
      const devRes = await tx.query(
        `INSERT INTO devices (home_id, device_uuid, mac_address, is_claimed, claimed_at, claimed_by, model,
                              is_online, is_commissioned, commissioning_status, device_status, local_key_enc)
         VALUES ($1, $2, $3, TRUE, CURRENT_TIMESTAMP, $4, $5, FALSE, FALSE, 'PENDING_INSTALLATION', 'ACTIVE', $6)
         ON CONFLICT (device_uuid) DO UPDATE SET
           home_id = EXCLUDED.home_id,
           mac_address = EXCLUDED.mac_address,
           is_claimed = TRUE,
           claimed_at = CURRENT_TIMESTAMP,
           claimed_by = EXCLUDED.claimed_by,
           model = EXCLUDED.model,
           is_online = FALSE,
           is_commissioned = FALSE,
           commissioned_at = NULL,
           commissioned_by = NULL,
           commissioning_status = 'PENDING_INSTALLATION',
           commissioning_notes = NULL,
           device_status = 'ACTIVE',
           local_key_enc = EXCLUDED.local_key_enc,
           setup_pin = NULL,
           reported_layout = NULL,
           reported_layout_at = NULL,
           updated_at = CURRENT_TIMESTAMP
         RETURNING id, home_id, device_uuid, model`,
        [home.id, uuid, inv.mac_address, owner.id, inv.model || DEFAULT_MODEL, localKey.enc]
      );
      const device = devRes.rows[0];

      // 9) Kanallar: daireye yazilmis sablon varsa ondan (K-S8), yoksa tek INSERT ... SELECT generate_series (model kanal sayisi)
      const seededFromTemplate =
        flatSeed && flatSeed.template_body
          ? (await this._seedEndpointsFromTemplate(tx, home.id, device.id, flatSeed.template_body)) !== null
          : false;
      if (!seededFromTemplate) await this._seedEndpoints(tx, home.id, device.id, device.model);
      // Daire kuruldu (teslim edilmis daire geri cekilmez)
      if (flatSeed) {
        await tx.query(
          "UPDATE site_flats SET status = 'installed', updated_at = CURRENT_TIMESTAMP WHERE id = $1 AND status IN ('planned', 'written')",
          [flatSeed.flat_id]
        );
      }

      // 10) Envanter: CLAIMED + PIN YAKILDI (duz metin PIN zaten saklanmaz) + yerel anahtar
      await tx.query(
        `UPDATE device_inventory
            SET status = 'CLAIMED',
                claimed_home_id = $1,
                claimed_by_user_id = $2,
                claimed_at = CURRENT_TIMESTAMP,
                failed_attempts = 0,
                locked_until = NULL,
                pin_hash = $3,
                local_key_enc = COALESCE(local_key_enc, $4)
          WHERE id = $5`,
        [home.id, owner.id, BURNED_PIN, localKey.enc, inv.id]
      );

      // 11) Cihaz MQTT kimligi (d_{t}) - TEK SEFERLIK
      const credential = await this.credentials.issueDeviceCredential({
        homeId: home.id,
        deviceId: device.id,
        topicId: home.mqtt_username,
        tx,
      });

      // 12) Denetim kaydi (sir icermez)
      await this._audit((t, p) => tx.query(t, p), {
        event: 'device_claimed',
        deviceUuid: uuid,
        homeId: home.id,
        actor,
        details: {
          on_behalf_of_customer: Boolean(target),
          customer_account_created: Boolean(createdAccount),
          customer_account_reset: securityReset,
          local_key_generated: localKey.generated,
          ...(flatSeed
            ? { site_flat_id: flatSeed.flat_id, template_id: seededFromTemplate ? flatSeed.template_id : null, template_version: seededFromTemplate ? flatSeed.version : null }
            : {}),
        },
      });

      return {
        ok: true,
        home,
        device,
        credential,
        createdAccount,
        pendingCustomer,
        neutralized,
        securityReset,
        technicianAccessUntil,
      };
    });

    if (!outcome.ok) throw outcome.error;

    // --- Commit SONRASI yan etkiler (hicbiri claim'i bozmaz) ---
    const warnings = [];
    if (outcome.neutralized && outcome.neutralized.neutralized && outcome.pendingCustomer) {
      // On-hesap etkisizlestirme: kimlik onbellegi, push belirteci, acik MQTT baglantilari (en iyi caba)
      await this.auth.finishNeutralize(outcome.pendingCustomer.id, outcome.neutralized, { reason: 'staff_claim_unverified' });
    }
    if (outcome.credential.previous_usernames && outcome.credential.previous_usernames.length > 0) {
      const kick = await this.credentials.kickUsernames(outcome.credential.previous_usernames);
      if (kick && kick.failed > 0) warnings.push('Eski cihaz bağlantısı atılamadı.');
    }

    let customerAccount;
    const inviteFailedWarning =
      'Müşteri hesabı oluşturuldu ancak davet gönderilemedi; müşteri uygulamada "Şifremi unuttum" ile hesabını etkinleştirebilir.';
    if (outcome.createdAccount) {
      const invite = await this._inviteCustomer({
        userId: outcome.createdAccount.id,
        email: outcome.createdAccount.email,
        fullName: outcome.createdAccount.full_name,
      });
      customerAccount = { created: true, status: 'pending_invite', invite_sent: invite.sent === true, security_reset: false };
      if (!invite.sent) warnings.push(inviteFailedWarning);
    } else if (outcome.pendingCustomer) {
      // Mevcut pending_invite (ya da guvenlik icin sifirlanan) musteri hesabi: davet YENIDEN gider (uyelik-1)
      const invite = await this._inviteCustomer({
        userId: outcome.pendingCustomer.id,
        email: outcome.pendingCustomer.email,
        fullName: outcome.pendingCustomer.full_name,
      });
      customerAccount = {
        created: false,
        status: 'pending_invite',
        invite_sent: invite.sent === true,
        security_reset: outcome.securityReset === true,
      };
      if (!invite.sent) warnings.push(inviteFailedWarning);
      else if (outcome.securityReset) {
        warnings.push('Müşterinin doğrulanmamış mevcut hesabı güvenlik için sıfırlandı; şifre belirleme e-postası gönderildi.');
      }
    }

    const data = {
      home_id: outcome.home.id,
      home_name: outcome.home.name,
      device_uuid: outcome.device.device_uuid,
      // TEK SEFERLIK: parola bir daha gosterilmez (yeniden uretmek icin ayri uc vardir).
      device_credential: this._publicDeviceCredential(outcome.credential),
    };
    if (customerAccount) data.customer_account = customerAccount;
    if (outcome.technicianAccessUntil) {
      data.technician_access_expires_at = new Date(outcome.technicianAccessUntil).toISOString();
    }
    if (warnings.length > 0) data.warnings = warnings;
    return data;
  }

  // ===========================================================================
  // B5: Acil sifirlama
  // ===========================================================================

  /**
   * Ulasilamayan kiraci / acil servis sifirlamasi.
   *  - Yetki: super, staff (YALNIZ uyesi oldugu evlerde). Servis (PIN) oturumu, owner, resident, misafir HAYIR.
   *  - Gerekce >= 15 karakter + confirm_uid (cihaz UUID'sinin yazarak teyidi) + denetim kaydi (IP dahil).
   *  - Servis personeli kendisini yeni sahip yapamaz.
   *  - Tek transaction; her seferinde YENI rastgele PIN (yanitta tek sefer) ve YENI yerel anahtar;
   *    devices.setup_pin kullanilmaz.
   *  - Yerel anahtar (SERVIS-01, pano-5, inceleme):
   *    DEVIR (REASSIGNED, pano ayni evde kalir): panodaki GERCEK anahtar gecerli kalir, yeni anahtar BEKLEYEN yazilir
   *    (devices.local_key_pending_enc); uzlastirici pano canli oldugunda iletir ve dogrular. Yanit 'pending' (anahtar yok).
   *    STOGA DONUS (UNCLAIMED) / ev ya da cihaz kaydi yok: yeni anahtar HEMEN gecerli (cihaz + envanter; bekleyen ve
   *    onceki anahtar yok) ve yanitta bir kez doner (pano yenilenirken RESETKEY + FACTORYINIT). Tek panolu evde commit
   *    sonrasi, cihaz kimligi atilmadan ONCE set_local_key yayinlanir (en iyi caba): 'published' | 'failed' (+ uyari) |
   *    'skipped_offline' (pano cevrimdisi / kopru kopuk) | 'skipped' (ev/cihaz yok ya da cok panolu ev).
   *  - Temizlik: endpoints, scheduled_rules, davetler, servis PIN/oturumlari (cleanupHome), uyelikler,
   *    MQTT kimlikleri; retained state/status bos yayinla temizlenir.
   *  - Commit sonrasi yan etki hatalari YUTULMAZ: yanitta `warnings` olarak doner.
   */
  async emergencyReset({ actor, deviceUuid, confirmUid, reason, newOwnerIdentifier }) {
    if (!actor || !actor.userId || !['service_user', 'super_user'].includes(actor.globalRole)) {
      throw httpError(403, 'Acil sıfırlama yalnızca yetkili servis personeli veya süper yönetici içindir.', 'FORBIDDEN');
    }
    const isSuper = actor.globalRole === 'super_user';

    const uuid = normalizeDeviceUuid(deviceUuid);
    if (!uuid) throw httpError(400, 'Geçersiz cihaz kimliği (device_uuid).', 'VALIDATION');
    const confirm = typeof confirmUid === 'string' ? confirmUid.trim().toUpperCase() : '';
    if (confirm !== uuid) {
      throw httpError(400, 'Teyit için cihaz kimliğini (UUID) aynen yazın.', 'VALIDATION');
    }
    const reasonText = typeof reason === 'string' ? reason.trim() : '';
    if (reasonText.length < RESET_REASON_MIN_LENGTH) {
      throw httpError(400, `Gerekçe en az ${RESET_REASON_MIN_LENGTH} karakter olmalı.`, 'VALIDATION');
    }
    if (reasonText.length > MAX_TEXT_LENGTH) {
      throw httpError(400, `Gerekçe en fazla ${MAX_TEXT_LENGTH} karakter olabilir.`, 'VALIDATION');
    }
    let newOwner = null;
    if (newOwnerIdentifier !== undefined && newOwnerIdentifier !== null && newOwnerIdentifier !== '') {
      newOwner = normalizeIdentifier(newOwnerIdentifier);
      if (!newOwner) throw httpError(400, 'Geçerli bir yeni sahip e-posta adresi veya telefon numarası girin.', 'VALIDATION');
    }
    // Yeni sahip dogrulanmamis on-hesapsa etkisizlestirilir (uyelik-1): yavas bcrypt ozeti islem DISINDA hesaplanir.
    const unusableHash = newOwner ? await this.bcrypt.hash(crypto.randomBytes(32).toString('hex'), 12) : null;

    const outcome = await this.db.withTransaction(async (tx) => {
      // 1) Cihaz + envanter satirlarini KILITLE
      const invRes = await tx.query(
        `SELECT id, device_uuid, status, claimed_home_id, claimed_by_user_id, model, mac_address, local_key_enc
           FROM device_inventory WHERE device_uuid = $1 FOR UPDATE`,
        [uuid]
      );
      if (invRes.rows.length === 0) {
        throw httpError(404, 'Cihaz envanterde kayıtlı değil.', 'NOT_FOUND');
      }
      const inv = invRes.rows[0];
      const devRes = await tx.query(
        `SELECT id, home_id, is_claimed, is_online, model, local_key_enc FROM devices WHERE device_uuid = $1 FOR UPDATE`,
        [uuid]
      );
      const dev = devRes.rows[0] || null;

      const homeId = (dev && dev.home_id) || inv.claimed_home_id || null;

      // 2a) Iptal edilmis / askiya alinmis cihazi YALNIZCA super yonetici stoga alabilir
      //     (servis personeli yonetimin verdigi iptal/askiya alma kararini sifirlamayla geri alamaz).
      if (!isSuper && (inv.status === 'REVOKED' || inv.status === 'SUSPENDED')) {
        throw httpError(403, 'Bu cihaz iptal edilmiş veya askıya alınmış; yalnızca süper yönetici sıfırlayabilir.', 'FORBIDDEN');
      }

      // 2) Yetki: staff yalnizca uyesi oldugu evde (super her yerde)
      if (!isSuper) {
        let allowed = false;
        if (homeId) {
          const mem = await tx.query(
            `SELECT role FROM home_users
              WHERE home_id = $1 AND user_id = $2
                AND (installer_expires_at IS NULL OR installer_expires_at > NOW())`,
            [homeId, actor.userId]
          );
          allowed = mem.rows.length > 0 && mem.rows[0].role === 'service_user';
        }
        if (!allowed) {
          throw httpError(403, 'Bu cihazın dairesinde servis yetkiniz yok. Süper yönetici ile iletişime geçin.', 'FORBIDDEN');
        }
      }

      // 3) Yeni sahip (varsa): mevcut, aktif ve servis personelinin kendisi DEGIL
      let newOwnerRow = null;
      let neutralized = null; // dogrulanmamis on-hesap etkisizlestirme (uyelik-1)
      let ownerSecurityReset = false;
      if (newOwner) {
        const actorRes = await tx.query('SELECT id, email, phone FROM users WHERE id = $1', [actor.userId]);
        const actorRow = actorRes.rows[0];
        const ur =
          newOwner.type === 'email'
            ? await tx.query(
                'SELECT id, email, phone, full_name, is_active, role, email_verified, account_status FROM users WHERE LOWER(email) = $1',
                [newOwner.value]
              )
            : await tx.query(
                `SELECT id, email, phone, full_name, is_active, role, email_verified, account_status FROM users
                  WHERE regexp_replace(COALESCE(phone, ''), '[^0-9+]', '', 'g') = $1`,
                [newOwner.value]
              );
        newOwnerRow = ur.rows[0] || null;
        if (!newOwnerRow) throw httpError(404, 'Yeni sahip olarak belirtilen kullanıcı sistemde kayıtlı değil.', 'NOT_FOUND');
        // Kayitta telefon DOGRULANMAZ: telefonla bulunan, gercek e-postali hesap baskasinin olabilir (uyelik-1).
        // Yer tutucu e-postali (telefon-OTP ile acilmis) hesap telefonla kabul edilir.
        if (newOwner.type === 'phone' && !isPlaceholderEmail(newOwnerRow.email)) {
          throw httpError(400, 'Bu numara e-postalı bir hesaba kayıtlı; atama için hesabın e-posta adresini girin.', 'VALIDATION');
        }
        if (newOwnerRow.is_active === false) {
          throw httpError(409, 'Yeni sahip hesabı aktif değil.', 'CONFLICT');
        }
        if (actorRow && (newOwnerRow.id === actorRow.id)) {
          throw httpError(403, 'Servis personeli kendisini yeni sahip yapamaz.', 'FORBIDDEN');
        }
        if (newOwnerRow.role === 'service_user') {
          throw httpError(403, 'Servis personeli hesabı cihaz sahibi olamaz.', 'FORBIDDEN');
        }
        if (!homeId) {
          throw httpError(409, 'Cihaz bir daireye bağlı değil; yeni sahip atanamaz. Önce cihazı sıfırlayıp yeniden sahiplendirin.', 'CONFLICT');
        }
        // On-hesap ele gecirme savunmasi (uyelik-1): dogrulanmamis hesap owner yapilmadan ONCE ayni tx'te etkisizlesir.
        // Yalniz E-POSTAYLA bulunan hedef: telefonla bulunan (yer tutucu e-postali, telefon-OTP ile acilmis) hesap sifirlanmaz.
        if (newOwner.type === 'email' && newOwnerRow.email_verified === false) {
          const wasActive = newOwnerRow.account_status === 'active';
          neutralized = await this.auth.neutralizeUnverifiedAccount(newOwnerRow.id, {
            tx,
            reason: 'emergency_reset_unverified',
            unusableHash,
          });
          if (neutralized && neutralized.neutralized) ownerSecurityReset = wasActive;
        }
      }

      const deviceWasOnline = Boolean(dev && dev.is_online);
      // Devirde cocuk kilidi komutu commit sonrasi gonderilemeyecekse niyet yolu (adim 7, M1-03)
      const childLockDeferred = Boolean(newOwnerRow && homeId && dev && !(deviceWasOnline && this._bridgeConnected()));

      // 4) Ev bilgisi (konu kimligi: MQTT temizligi icin)
      let topicId = null;
      let oldUserIds = [];
      let homeDeviceCount = 0; // stoga donuste set_local_key yalniz tek panolu evde (ev konusu tum panolara gider)
      if (homeId) {
        // Kilit sirasi (cok panolu ev): evin TUM cihaz satirlari id sirasiyla, ev kilidinden ve temizlikten ONCE.
        // Yerlesim esitleme / kopru durum yolu devices -> endpoints -> scheduled_rules / homes sirasini kullanir; ters
        // sira (once ev verisi, sonra kardes panonun cihaz satiri) kilitlenme (40P01) uretirdi.
        const homeDevs = await tx.query('SELECT id FROM devices WHERE home_id = $1 ORDER BY id FOR UPDATE', [homeId]);
        homeDeviceCount = ((homeDevs && homeDevs.rows) || []).length;
        const homeRes = await tx.query('SELECT id, mqtt_username FROM homes WHERE id = $1 FOR UPDATE', [homeId]);
        topicId = homeRes.rows[0] ? homeRes.rows[0].mqtt_username : null;

        // 5) Uyeler: eskileri cikar
        const members = await tx.query('SELECT user_id FROM home_users WHERE home_id = $1', [homeId]);
        oldUserIds = members.rows.map((r) => r.user_id);
        await tx.query('DELETE FROM home_users WHERE home_id = $1', [homeId]);

        // 6) Eve ait veriler (kurallar, davetler, servis PIN/oturumlari, kanallar...)
        await this._cleanupHome(tx, homeId, { keepEndpoints: false });

        // 7) Evin kullanici ayarlari varsayilana. Cocuk kilidi (durum + niyet) da sifirlanir:
        //    devredilen pano yeni sahibe KILITLI gitmemeli (panoya komut commit sonrasi yayinlanir).
        //    Devirde komut SIMDI gonderilemiyorsa (pano cevrimdisi ya da kopru kopuk; M1-03) durum sifirlanmaz: "kilit
        //    kapali" NIYETI yazilir ve panonun son bildirdigi durum korunur. Uzlastirici (device_reconciler) niyeti
        //    cihazin BILDIRDIGI durumla karsilastirir; durum burada FALSE'a cekilseydi niyet hemen "karsilandi" sayilip
        //    silinirdi. Pano baglanip kilitli bildirirse set_child_lock false gonderilir. Stoga donuste ev bagi
        //    kalmadigi icin niyet anlamsizdir: eski davranis (durum sifirlanir, uyari).
        if (childLockDeferred) {
          await tx.query(
            `UPDATE homes
                SET child_lock_requested = $2, child_lock_requested_at = CURRENT_TIMESTAMP, child_lock_requested_by = $3,
                    peace_notification_enabled = TRUE, peace_notification_time = '23:30'
              WHERE id = $1`,
            [homeId, false, null]
          );
        } else {
          await tx.query(
            `UPDATE homes
                SET child_lock_enabled = FALSE, child_lock_requested = NULL, child_lock_requested_at = NULL,
                    child_lock_requested_by = NULL, peace_notification_enabled = TRUE, peace_notification_time = '23:30'
              WHERE id = $1`,
            [homeId]
          );
          await tx.query('UPDATE devices SET child_lock_enabled = FALSE WHERE home_id = $1', [homeId]);
        }
      }

      // 8) Yeni yerel anahtar (her seferinde). Iki plan (pano-5; PUBACK panonun anahtari aldigini kanitlamaz):
      //    'pending' : YALNIZ yeni sahibe devir (REASSIGNED) + ev/konu + cihaz kaydi: pano ayni evde kalir. Panodaki GERCEK
      //                anahtar gecerli kalir (devices + envanter degismez; servis sihirbazi LAN'dan bununla baglanabilir),
      //                yeni anahtar BEKLEYEN yazilir; uzlastirici pano canli oldugunda iletir ve (firmware 1.3.1)
      //                state'teki lk_fp ile dogrulayinca takas eder (device_reconciler).
      //    'direct'  : stoga donus (UNCLAIMED) ya da ev/konu / cihaz kaydi yok: yeni anahtar HEMEN gecerli (cihaz +
      //                envanter), bekleyen NULL, yanitta bir kez doner. Stoga donuste ev bagi kalmaz: bekleyen anahtar
      //                hic iletilemezdi (uzlastirici evin konusuyla calisir) ve ESKI anahtar envanterde kalip sonraki
      //                musterinin claim'ine gecerdi (eski sahip yeni dairenin cihaz kimligini bootstrap ile alabilirdi).
      //                Onceki anahtar saklanmaz.
      const newLocalKey = this.secretBox.generateLocalKey();
      const newLocalKeyEnc = this.secretBox.encrypt(newLocalKey);
      const keyPlan = newOwnerRow && topicId && dev ? 'pending' : 'direct';
      const holdKey = keyPlan === 'pending';
      const deviceKeyEnc = holdKey ? dev.local_key_enc || null : newLocalKeyEnc; // devices.local_key_enc
      const inventoryKeyEnc = holdKey ? inv.local_key_enc || null : newLocalKeyEnc; // device_inventory.local_key_enc
      const pendingKeyEnc = holdKey ? newLocalKeyEnc : null; // devices.local_key_pending_enc (yeni anahtar gecerliyse NULL)

      // 9) MQTT kimlikleri: uygulama kimlikleri DB'den silinir (kick commit sonrasi).
      //    Yeni sahibe devirde cihaz kimligi asagida YENILENIR; stoga donuste cihaz kimligi de silinir.
      let revokedUsernames = [];
      if (homeId) {
        const revoked = await this.credentials.revokeHomeAccess({
          homeId,
          includeDevice: !newOwnerRow,
          tx,
        });
        revokedUsernames = revoked.usernames || [];
      }

      let action;
      let setupPin = null;
      let deviceCredential = null;

      if (newOwnerRow && homeId) {
        // --- YENI SAHIBE DEVIR ---
        action = 'REASSIGNED';
        await tx.query(`INSERT INTO home_users (home_id, user_id, role) VALUES ($1, $2, 'owner')`, [
          homeId,
          newOwnerRow.id,
        ]);
        // Servis personeli yeni sahip icin kurulumu (cihaz kimligini yazma, kanal ayari, devreye alma) bitirebilsin
        // diye SURELI servis uyeligi alir (claim ile ayni kural; super_user'a gerekmez).
        if (actor.globalRole === 'service_user') {
          await tx.query(
            `INSERT INTO home_users (home_id, user_id, role, installer_expires_at)
             VALUES ($1, $2, 'service_user', NOW() + ($3 * INTERVAL '1 hour'))`,
            [homeId, actor.userId, STAFF_INSTALL_WINDOW_HOURS]
          );
        }
        await tx.query(
          `UPDATE device_inventory
              SET status = 'CLAIMED',
                  claimed_home_id = $1,
                  claimed_by_user_id = $2,
                  claimed_at = CURRENT_TIMESTAMP,
                  failed_attempts = 0,
                  locked_until = NULL,
                  pin_hash = $3,
                  local_key_enc = $4
            WHERE id = $5`,
          [homeId, newOwnerRow.id, BURNED_PIN, inventoryKeyEnc, inv.id]
        );
        if (dev) {
          await tx.query(
            `UPDATE devices
                SET home_id = $1, is_claimed = TRUE, claimed_by = $2, claimed_at = CURRENT_TIMESTAMP,
                    is_online = FALSE, is_commissioned = FALSE, commissioned_at = NULL, commissioned_by = NULL,
                    commissioning_status = 'PENDING_INSTALLATION', commissioning_notes = NULL,
                    device_status = 'ACTIVE', local_key_enc = $3, setup_pin = NULL,
                    child_lock_enabled = CASE WHEN $6::boolean THEN child_lock_enabled ELSE FALSE END,
                    local_key_pending_enc = $5::text,
                    local_key_pending_at = CASE WHEN $5::text IS NULL THEN NULL ELSE CURRENT_TIMESTAMP END,
                    reported_layout = NULL, reported_layout_at = NULL, updated_at = CURRENT_TIMESTAMP
              WHERE id = $4`,
            [homeId, newOwnerRow.id, deviceKeyEnc, dev.id, pendingKeyEnc, childLockDeferred]
          );
          await this._clearDeviceTemplate(tx, dev.id); // yuklu sablon kaydi: pano yeniden bildirene kadar bilinmez
          await this._seedEndpoints(tx, homeId, dev.id, dev.model || inv.model);
          deviceCredential = await this.credentials.issueDeviceCredential({
            homeId,
            deviceId: dev.id,
            topicId,
            tx,
          });
        }
      } else {
        // --- STOGA DONUS (sahipsiz) ---
        action = 'UNCLAIMED';
        setupPin = generateNumericPin(6); // crypto.randomInt; sabit/varsayilan PIN YOK
        const pinHash = await this.pin.hashPin(setupPin);
        await tx.query(
          `UPDATE device_inventory
              SET status = 'IN_STOCK',
                  claimed_home_id = NULL,
                  claimed_by_user_id = NULL,
                  claimed_at = NULL,
                  failed_attempts = 0,
                  locked_until = NULL,
                  pin_hash = $1,
                  local_key_enc = $2
            WHERE id = $3`,
          [pinHash, inventoryKeyEnc, inv.id]
        );
        if (dev) {
          await tx.query(
            `UPDATE devices
                SET home_id = NULL, is_claimed = FALSE, claimed_by = NULL, claimed_at = NULL,
                    is_online = FALSE, is_commissioned = FALSE, commissioned_at = NULL, commissioned_by = NULL,
                    commissioning_status = 'PENDING_INSTALLATION', commissioning_notes = NULL,
                    device_status = 'ACTIVE', local_key_enc = $1, setup_pin = NULL, child_lock_enabled = FALSE,
                    local_key_pending_enc = $3::text,
                    local_key_pending_at = CASE WHEN $3::text IS NULL THEN NULL ELSE CURRENT_TIMESTAMP END,
                    reported_layout = NULL, reported_layout_at = NULL, updated_at = CURRENT_TIMESTAMP
              WHERE id = $2`,
            [deviceKeyEnc, dev.id, pendingKeyEnc]
          );
          await this._clearDeviceTemplate(tx, dev.id);
          // guvenlik-1: stoga donen panonun acik alarmlari kapanir (evden ayrildi; baska eve sahiplenince yeni satir acilir)
          await this._detachDeviceAlarms(tx, dev.id);
          // Cihaz bagli oldugu tum kanal satirlarindan arindirilir (yeni sahiplenmede yeniden uretilir).
          await tx.query('DELETE FROM endpoints WHERE device_id = $1', [dev.id]);
        }
      }

      // 9z) Karar 14: sahiplik donemi - sifirlamadan onceki ailenin kapanmis alarm gecmisi gosterilmez (acik alarmlar kalir)
      if (homeId) await tx.query('UPDATE homes SET ownership_epoch = NOW() WHERE id = $1', [homeId]);

      // 10) Denetim kayitlari (IP dahil)
      await tx.query(
        `INSERT INTO emergency_reset_logs
           (device_uuid, home_id, installer_user_id, reason, new_owner_identifier, previous_owner_ids,
            ip_address, actor_role, action)
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)`,
        [
          uuid,
          homeId,
          actor.userId,
          reasonText,
          newOwner ? newOwner.value : null,
          JSON.stringify(oldUserIds),
          actor.ip || null,
          actor.globalRole,
          action,
        ]
      );
      await this._audit((t, p) => tx.query(t, p), {
        event: 'emergency_reset',
        deviceUuid: uuid,
        homeId,
        actor,
        details: { action, affected_users: oldUserIds.length },
      });

      return {
        action,
        homeId,
        topicId,
        setupPin,
        newLocalKey,
        newLocalKeyEnc,
        keyPlan,
        newOwnerRow,
        deviceCredential,
        affectedUsers: oldUserIds.length,
        revokedUsernames: Array.from(
          new Set([
            ...revokedUsernames,
            ...((deviceCredential && deviceCredential.previous_usernames) || []),
          ])
        ),
        deviceWasOnline,
        childLockDeferred,
        deviceId: dev ? dev.id : null,
        homeDeviceCount,
        neutralized,
        ownerSecurityReset,
      };
    });

    // (D6) Satirlar ayni cihaz + ayni ev icin yeniden tohumlandi: yerlesim esitleme onbellegi (ayni imza) tohum
    // sablonunu RECHECK suresince birakmasin. Yalniz COMMIT sonrasi; en iyi caba (kopru metodu yoksa / patlarsa
    // sifirlama yine basarili: onbellek en gec RECHECK suresinde kendiliginden yenilenir).
    if (outcome.action === 'REASSIGNED' && outcome.deviceId) {
      try {
        const bridge = this.bridge;
        if (bridge && typeof bridge.invalidateLayout === 'function') bridge.invalidateLayout(outcome.deviceId);
      } catch (_) {
        /* en iyi caba: onbellek hatasi sifirlamayi bozmaz */
      }
    }

    // --- Commit SONRASI yan etkiler: hatalar yutulmaz, `warnings` olarak doner ---
    const warnings = [];
    const notices = []; // bilgi notlari (kismi basarisizlik DEGIL: partial yapmaz)
    let localKeyPublish = 'skipped';
    let childLockReset = 'skipped';

    // Yeni sahibin dogrulanmamis on-hesabi etkisizlestirildi (uyelik-1): onbellek/push/MQTT + sifre belirleme daveti
    if (outcome.neutralized && outcome.neutralized.neutralized && outcome.newOwnerRow) {
      const o = outcome.newOwnerRow;
      await this.auth.finishNeutralize(o.id, outcome.neutralized, { reason: 'emergency_reset_unverified' });
      const invite = await this._inviteCustomer({ userId: o.id, email: o.email, fullName: o.full_name });
      if (!invite.sent) {
        warnings.push(
          'Yeni sahibin hesabı güvenlik için sıfırlandı ancak şifre belirleme e-postası gönderilemedi; kullanıcı uygulamada "Şifremi unuttum" ile hesabını etkinleştirebilir.'
        );
      } else if (outcome.ownerSecurityReset) {
        notices.push('Yeni sahibin doğrulanmamış mevcut hesabı güvenlik için sıfırlandı; şifre belirleme e-postası gönderildi.');
      }
    }

    if (outcome.topicId) {
      // (a0) Cocuk kilidini sifirla (devredilen pano yeni sahibe kilitli gitmesin). Cihaz hala ESKI kimlikle bagliyken.
      //      Gonderilemezse uyari NEDENE gore (kopru kopuk / pano cevrimdisi; M1-03). Devirde transaction "kilit kapali"
      //      NIYETINI yazdi (childLockDeferred): uzlastirici pano buluta baglaninca set_child_lock false gonderir.
      if (!outcome.childLockDeferred && outcome.deviceWasOnline && this._bridgeConnected()) {
        try {
          await this._publishCommand(outcome.topicId, { cmd: 'set_child_lock', enabled: false, id: this._newCommandId() });
          childLockReset = 'published';
        } catch (_) {
          childLockReset = 'failed';
          warnings.push('Çocuk kilidi sıfırlama komutu panoya iletilemedi; pano yerelde kilitli kalmış olabilir.');
        }
      } else {
        childLockReset = 'skipped_offline';
        const cause = outcome.deviceWasOnline ? 'Bulut bağlantısı yok' : 'Pano çevrimdışı';
        const tail = outcome.childLockDeferred
          ? 'Kilit, pano bağlandığında otomatik kaldırılacak.'
          : 'Pano yerelde kilitli kalmış olabilir.';
        warnings.push(`${cause}; çocuk kilidi sıfırlama komutu gönderilemedi. ${tail}`);
      }

      // (a) Yerel anahtar (pano-5): 'pending' (devir) planda transaction bekleyen anahtari yazdi; uzlastirici bu ev icin
      //     yeniden kurulur (pano canliysa sonraki state'te iletir). Uyari YOK (S-1): bekleyen anahtar hata degildir.
      //     Stoga donus (inceleme): yeni anahtar sunucuda ZATEN gecerli; pano hala ESKI cihaz kimligiyle bagliyken (asagidaki
      //     kick'ten ONCE) set_local_key ile iletilir (en iyi caba; anahtar yanitta da doner). Ev konusu evdeki TUM
      //     panolara gider: cok panolu evde yayinlanmaz (kardes panonun anahtari sunucudan habersiz degisirdi).
      if (outcome.keyPlan === 'pending') {
        localKeyPublish = 'pending';
        this._requestReconcile(outcome.topicId);
      } else if (outcome.action === 'UNCLAIMED' && outcome.deviceId) {
        if (outcome.homeDeviceCount !== 1) {
          localKeyPublish = 'skipped';
        } else if (!(outcome.deviceWasOnline && this._bridgeConnected())) {
          localKeyPublish = 'skipped_offline';
        } else {
          try {
            await this._publishSys(outcome.topicId, {
              cmd: 'set_local_key',
              local_key: outcome.newLocalKey, // alan adi `local_key` (CONTRACTS §3b); kopru sys yukunu loglamaz
              id: this._newCommandId(),
            });
            localKeyPublish = 'published';
          } catch (_) {
            localKeyPublish = 'failed';
            warnings.push(LOCAL_KEY_FAILED_WARNING);
          }
        }
      }

      // (b) Eski uygulama/cihaz baglantilarini at
      try {
        const kick = await this.credentials.kickUsernames(outcome.revokedUsernames);
        if (kick && kick.failed > 0) {
          warnings.push(`${kick.failed} MQTT bağlantısı atılamadı; kimlikler silindi, açık bağlantılar yeniden doğrulamada düşer.`);
        } else if (kick && kick.skipped) {
          warnings.push('EMQX yönetim API ayarı yok; açık MQTT bağlantıları atılamadı (kimlikler silindi).');
        }
      } catch (_) {
        warnings.push('MQTT bağlantıları atılamadı; kimlikler silindi.');
      }

      // (c) Eski ailenin retained state/status mesajlarini temizle
      try {
        await this.bridge.clearRetained(outcome.topicId);
      } catch (_) {
        warnings.push('Retained MQTT mesajları temizlenemedi; eski durum bilgisi broker\'da kalabilir.');
      }
    }

    const data = {
      action: outcome.action,
      device_uuid: uuid,
      home_id: outcome.homeId,
      affected_users_count: outcome.affectedUsers,
      local_key_publish: localKeyPublish,
      child_lock_reset: childLockReset,
    };
    if (outcome.action === 'UNCLAIMED') {
      data.setup_pin = outcome.setupPin; // TEK SEFERLIK: yeni etiket / sonraki sahiplenme icin
      data.message =
        'Cihaz stoğa alındı. Yeni kurulum PIN kodu yalnızca şimdi gösterilir; güvenli bir yere not edin.';
    } else {
      data.new_owner = { id: outcome.newOwnerRow.id, full_name: outcome.newOwnerRow.full_name };
      if (outcome.deviceCredential) {
        data.device_credential = this._publicDeviceCredential(outcome.deviceCredential);
      }
      data.message =
        'Cihaz yeni sahibe devredildi. Eski ailenin tüm erişimleri kaldırıldı; cihaz kimliği yenilendi.';
    }
    // Yerel anahtar yanitta bir kez doner: 'direct' planda (stoga donus ya da ev/cihaz kaydi yok) anahtar sunucuda hemen
    // gecerlidir; pano yenilenirken seri konsoldan RESETKEY + FACTORYINIT ile yazilabilsin (yayin PUBACK'i panonun
    // aldigini kanitlamaz). 'pending' (devir) iken DONMEZ: panonun mevcut anahtari gecerlidir, yenisi uzlastiriciyla.
    if (outcome.keyPlan === 'direct') {
      data.local_key = outcome.newLocalKey;
    }
    if (warnings.length > 0 || notices.length > 0) data.warnings = [...notices, ...warnings];
    if (warnings.length > 0) data.partial = true;
    return data;
  }

  // ===========================================================================
  // B6: Pano degisimi
  // ===========================================================================

  /**
   * Arizali panonun yerine yeni pano. Tek transaction. Yetki (owner/staff/servis oturumu/super) route'ta
   * requireHomeAccess + matris ile dogrulanir; `homeId` YALNIZCA dogrulanmis uyelikten gelir.
   *  - PIN: claim ile ayni atomik sayac + kilit; SUSPENDED/CLAIMED/REVOKED reddedilir.
   *  - Eski pano: `old_device_uuid` verilirse o; verilmezse dairede TAM BIR pano varsa o,
   *    birden fazlaysa 400 (sessiz "ilk pano" yedegi YOK).
   *  - UNIQUE(device_id, channel_index) cakismasi: yeni cihazin eski kanal satirlari once silinir.
   *  - Eski cihaz kimligi iptal edilir, yeni cihaz kimligi uretilir (tek sefer).
   */
  async replaceBoard({ actor, homeId, oldDeviceUuid, newDeviceUuid, setupPin, reason }) {
    if (!can('replace_board', actor && actor.access)) {
      throw httpError(403, 'Pano değişimi yalnızca ev sahibi veya yetkili servis tarafından yapılabilir.', 'FORBIDDEN');
    }
    if (!isUuid(homeId)) throw httpError(400, 'Geçersiz daire kimliği (home_id).', 'VALIDATION');

    const newUuid = normalizeDeviceUuid(newDeviceUuid);
    if (!newUuid) throw httpError(400, 'Geçersiz yeni cihaz kimliği (new_device_uuid).', 'VALIDATION');
    let oldUuid = null;
    if (oldDeviceUuid !== undefined && oldDeviceUuid !== null && oldDeviceUuid !== '') {
      oldUuid = normalizeDeviceUuid(oldDeviceUuid);
      if (!oldUuid) throw httpError(400, 'Geçersiz eski cihaz kimliği (old_device_uuid).', 'VALIDATION');
      if (oldUuid === newUuid) throw httpError(400, 'Eski ve yeni pano aynı olamaz.', 'VALIDATION');
    }
    const pinText = typeof setupPin === 'string' || typeof setupPin === 'number' ? String(setupPin).trim() : '';
    if (!SIX_DIGITS.test(pinText)) throw httpError(400, 'Kurulum PIN kodu 6 haneli rakam olmalı.', 'VALIDATION');
    const reasonText = textOrNull(reason, MAX_TEXT_LENGTH);
    if (reasonText === undefined) throw httpError(400, `Gerekçe en fazla ${MAX_TEXT_LENGTH} karakter olmalı.`, 'VALIDATION');

    const outcome = await this.db.withTransaction(async (tx) => {
      // 1) Yeni panonun envanter satiri KILITLI
      const invRes = await tx.query(
        `SELECT id, device_uuid, mac_address, pin_hash, model, status, failed_attempts, locked_until, local_key_enc
           FROM device_inventory WHERE device_uuid = $1 FOR UPDATE`,
        [newUuid]
      );
      if (invRes.rows.length === 0) {
        throw httpError(404, 'Yeni pano envanterde kayıtlı değil. Fabrika etiketini kontrol edin.', 'NOT_FOUND');
      }
      const newInv = invRes.rows[0];
      this._assertInventoryClaimable(newInv);

      // 2) PIN (claim ile ayni sayac; commit-then-throw)
      const pinCheck = await this._checkInventoryPin(tx, newInv, pinText);
      if (!pinCheck.ok) return { ok: false, error: pinCheck.error };

      // 3) Ev (tek, dogrulanmis home_id)
      const homeRes = await tx.query(
        'SELECT id, name, mqtt_username, child_lock_enabled FROM homes WHERE id = $1 FOR UPDATE',
        [homeId]
      );
      if (homeRes.rows.length === 0) throw httpError(404, 'Daire bulunamadı.', 'NOT_FOUND');
      const home = homeRes.rows[0];

      // 3b) Karar 18: guvenlik yapilandirmasi (sensor / vana / bolge) olan evde pano degisimini yalniz yetkili servis
      //     (personel, servis oturumu, super) yapar; ev sahibinin kendi degisimi 403 (islem geri alinir, PIN harcanmaz).
      if (actor && actor.access === 'owner' && !['service_user', 'super_user'].includes(actor.globalRole)) {
        const sc = await tx.query(HAS_SAFETY_CONFIG_SQL, [homeId]);
        if (sc && sc.rows && sc.rows[0] && sc.rows[0].has_safety_config === true) {
          throw httpError(403, 'Güvenlik ayarları olan evde pano değişimini yetkili servis yapmalıdır.', 'REPLACE_REQUIRES_SERVICE');
        }
      }

      // 4) Eski pano: sessiz "ilk pano" (LIMIT 1) yedegi YOK
      let oldDevice;
      if (oldUuid) {
        const r = await tx.query(
          `SELECT id, device_uuid, mac_address, claimed_by, child_lock_enabled FROM devices
            WHERE device_uuid = $1 AND home_id = $2 FOR UPDATE`,
          [oldUuid, homeId]
        );
        oldDevice = r.rows[0];
        if (!oldDevice) throw httpError(404, 'Belirtilen eski pano bu daireye bağlı değil.', 'NOT_FOUND');
      } else {
        const r = await tx.query(
          `SELECT id, device_uuid, mac_address, claimed_by, child_lock_enabled FROM devices
            WHERE home_id = $1 ORDER BY created_at ASC FOR UPDATE`,
          [homeId]
        );
        if (r.rows.length === 0) throw httpError(404, 'Bu daireye bağlı değiştirilecek bir pano bulunamadı.', 'NOT_FOUND');
        if (r.rows.length > 1) {
          throw httpError(400, 'Dairede birden fazla pano var. Değiştirilecek panoyu old_device_uuid ile belirtin.', 'VALIDATION');
        }
        oldDevice = r.rows[0];
      }

      // 5) Yeni cihaz baska bir daireye bagliysa CALINMAZ; MAC cakismasi giderilir
      const existingNew = await tx.query(
        'SELECT id, home_id, is_claimed FROM devices WHERE device_uuid = $1 FOR UPDATE',
        [newUuid]
      );
      if (existingNew.rows[0] && existingNew.rows[0].home_id && existingNew.rows[0].is_claimed &&
          existingNew.rows[0].home_id !== homeId) {
        throw httpError(409, 'Yeni pano başka bir daireye bağlı görünüyor. Yetkili servisle iletişime geçin.', 'CONFLICT');
      }
      // 5b) atolye-8 (inceleme): yeni kart BASKA bir site dairesine bagliysa sessizce o daireden alinmaz: super olmayan
      //     (owner / servis personeli / servis oturumu) 409 DEVICE_LINKED_TO_FLAT (envanter silme, etiket yenileme ve
      //     stoga alma ile ayni kural: once daireden ayrilmali). super_user gecersiz kilarsa bag adim 11c'de kaldirilir.
      //     Kilitsiz okuma yeterli: daireye kart baglama (linkFlatDevice) once kartin envanter satirini kilitler; o satir
      //     adim 1'den beri bu islemde kilitli (arada baska daireye baglanamaz).
      const schema035 = await this._hasSchema035(tx);
      let otherFlatCount = 0;
      if (schema035) {
        const other = await tx.query('SELECT id, status FROM site_flats WHERE device_uuid = $1', [newUuid]);
        otherFlatCount = ((other && other.rows) || []).length;
        if (otherFlatCount > 0 && !(actor && actor.globalRole === 'super_user')) {
          throw httpError(409, 'Kart bir daireye bağlı; önce daireden ayırın.', 'DEVICE_LINKED_TO_FLAT');
        }
      }
      await this._resolveMacConflict(tx, newInv.mac_address, newUuid);

      // 6) Eski panonun kanal yedegi (snapshot)
      const eps = await tx.query(
        `SELECT channel_index, name, type, room, shutter_pair_index, shutter_duration_sec, current_state, current_position
           FROM endpoints WHERE home_id = $1 AND device_id = $2 ORDER BY channel_index ASC`,
        [homeId, oldDevice.id]
      );
      const snapshot = {
        replaced_at: this._now().toISOString(),
        old_device_uuid: oldDevice.device_uuid,
        new_device_uuid: newUuid,
        endpoints: eps.rows,
      };
      // Panjur sureleri yeni panoya cihaz CEVRIMICI olunca set_runtime ile uygulanir (plan §5d-3; kopru uzlastiricisi
      // services/device_reconciler.js). Cihaz state'inde sure olmadigindan "bekliyor" isareti yeni cihazin
      // config_snapshot'ina yazilir (mevcut kolon): runtime_sync='pending' + home_id (baska eve tasinirsa gecersiz) +
      // replaced_at (yeni degisimde yeniden kurulur). Uzlastirici uygulayinca 'synced' yapar. Gunluk kaydi (asagida)
      // `snapshot`'i degismeden alir.
      const runtimes = eps.rows
        .filter((e) => e.type === 'shutter' && e.channel_index % 2 === 1 && e.shutter_duration_sec)
        .map((e) => ({ shutter: e.shutter_pair_index, sec: e.shutter_duration_sec }));
      const deviceSnapshot = runtimes.length > 0 ? { ...snapshot, home_id: homeId, runtime_sync: 'pending' } : snapshot;

      // 7) Daire sahibi (yeni cihazin claimed_by'i): eski cihazinki, yoksa evin sahibi
      let ownerId = oldDevice.claimed_by || null;
      if (!ownerId) {
        const o = await tx.query(
          `SELECT user_id FROM home_users WHERE home_id = $1 AND role = 'owner' ORDER BY created_at ASC LIMIT 1`,
          [homeId]
        );
        ownerId = o.rows[0] ? o.rows[0].user_id : null;
      }

      // 8) Yeni cihaz kaydi (duz metin PIN YOK; yerel anahtar sifreli). Bekleyen yerel anahtara (local_key_pending_enc,
      //    SERVIS-01) DOKUNULMAZ: envanter anahtari yeni panodaki GERCEK anahtardir; yeni panonun onceki bir acil
      //    sifirlamadan kalan bekleyen anahtari varsa pano buluta baglaninca uzlastiriciyla iletilir.
      const localKey = this._resolveLocalKeyEnc(newInv);
      const upsert = await tx.query(
        `INSERT INTO devices (home_id, device_uuid, mac_address, is_claimed, claimed_at, claimed_by, model,
                              is_online, is_commissioned, commissioning_status, device_status, config_snapshot, local_key_enc)
         VALUES ($1, $2, $3, TRUE, CURRENT_TIMESTAMP, $4, $5, FALSE, FALSE, 'PENDING_INSTALLATION', 'ACTIVE', $6, $7)
         ON CONFLICT (device_uuid) DO UPDATE SET
           home_id = EXCLUDED.home_id,
           mac_address = EXCLUDED.mac_address,
           is_claimed = TRUE,
           claimed_at = CURRENT_TIMESTAMP,
           claimed_by = EXCLUDED.claimed_by,
           model = EXCLUDED.model,
           is_online = FALSE,
           is_commissioned = FALSE,
           commissioned_at = NULL,
           commissioned_by = NULL,
           commissioning_status = 'PENDING_INSTALLATION',
           commissioning_notes = NULL,
           device_status = 'ACTIVE',
           config_snapshot = EXCLUDED.config_snapshot,
           local_key_enc = EXCLUDED.local_key_enc,
           setup_pin = NULL,
           reported_layout = NULL,
           reported_layout_at = NULL,
           updated_at = CURRENT_TIMESTAMP
         RETURNING id`,
        [homeId, newUuid, newInv.mac_address, ownerId, newInv.model || DEFAULT_MODEL, JSON.stringify(deviceSnapshot), localKey.enc]
      );
      const newDeviceId = upsert.rows[0].id;

      // 8b) tarama-sunucu-cihaz-site-1 (sozlesme C4): guvenlik yapilandirmasi (sensorler, vanalar, bolgeler) yeni panoya
      //     AKTARILMAZ (kopya eski cihaz kimliginde kalir; buluttan geri yukleme yok). Eski panonun kopyasinda en az bir
      //     sensor/eylemci varsa ya da tasinacak bir uc nokta eylemciyse (actuator_type) yanit bunu acikca soyler.
      const safetyRes = await tx.query(
        `SELECT (EXISTS (SELECT 1 FROM device_configs c
                          WHERE c.device_id = $1 AND c.module = 'safety'
                            AND ((jsonb_typeof(c.body -> 'sensors') = 'array' AND jsonb_array_length(c.body -> 'sensors') > 0)
                              OR (jsonb_typeof(c.body -> 'actuators') = 'array' AND jsonb_array_length(c.body -> 'actuators') > 0)))
                 OR EXISTS (SELECT 1 FROM endpoints e
                             WHERE e.device_id = $1 AND e.home_id = $2 AND e.actuator_type IS NOT NULL)) AS safety_restore_required`,
        [oldDevice.id, homeId]
      );
      const safetyRestore = safetyRes.rows[0] && safetyRes.rows[0].safety_restore_required === true ? 'required' : 'not_required';

      // 9) Eski cihazi devreden cikar
      await tx.query(
        `UPDATE devices
            SET home_id = NULL, is_claimed = FALSE, claimed_by = NULL, is_online = FALSE,
                device_status = 'REPLACED_DAMAGED', updated_at = CURRENT_TIMESTAMP
          WHERE id = $1`,
        [oldDevice.id]
      );
      await this._clearDeviceTemplate(tx, oldDevice.id);
      // 9b) guvenlik-1: ayrilan panonun ACIK alarm kayitlari kapanir ('lost' / 'detached'). Aksi halde kapanmaz,
      //     onaylanamaz ve evdeki gaz bastirmasi (kurallar / gece hatirlatmasi) kalici olurdu.
      await this._detachDeviceAlarms(tx, oldDevice.id);

      // 10) Envanter: yeni CLAIMED (PIN yakildi), eski REVOKED
      await tx.query(
        `UPDATE device_inventory
            SET status = 'CLAIMED', claimed_home_id = $1, claimed_by_user_id = $2, claimed_at = CURRENT_TIMESTAMP,
                failed_attempts = 0, locked_until = NULL, pin_hash = $3, local_key_enc = COALESCE(local_key_enc, $4)
          WHERE id = $5`,
        [homeId, ownerId, BURNED_PIN, localKey.enc, newInv.id]
      );
      await tx.query(
        `UPDATE device_inventory SET status = 'REVOKED', claimed_home_id = NULL WHERE device_uuid = $1`,
        [oldDevice.device_uuid]
      );

      // 11) Kanallar: UNIQUE(device_id, channel_index) cakismasi COZULUR -> once yeni cihazin eski satirlari silinir
      await tx.query('DELETE FROM endpoints WHERE device_id = $1', [newDeviceId]);
      const moved = await tx.query(
        `UPDATE endpoints SET device_id = $1, updated_at = CURRENT_TIMESTAMP
          WHERE device_id = $2 AND home_id = $3`,
        [newDeviceId, oldDevice.id, homeId]
      );
      // 11b) kullanim-4: zamanli kurallar yeni cihaza tasinir (eski cihaza bagli kural zamanlayicida hic calismazdi)
      const rulesMoved = await tx.query(
        `UPDATE scheduled_rules SET device_id = $1, updated_at = CURRENT_TIMESTAMP
          WHERE home_id = $2 AND device_id = $3
          RETURNING id`,
        [newDeviceId, homeId, oldDevice.id]
      );
      // 11c) atolye-8: site dairesinin kart baglantisi yeni karta tasinir (migration 035 yoksa atlanir).
      //      super_user'in gecersiz kildigi baska daire bagi (5b) kaldirilir ve o daire 'planned'a doner (bir kart tek
      //      daireye bagli olur; kartsiz written / installed / handed_over daire kalmaz).
      //      atolye-7: degistirilen dairenin 'written' durumu KARTA baglidir: yeni kartin bu dairenin sablonuyla basarili
      //      yazimi yoksa 'planned' olur (yeni kartta baska dairenin sablonu yazili olabilir). installed / handed_over korunur.
      let unlinkedFlats = 0;
      if (schema035) {
        if (otherFlatCount > 0) {
          const unlinked = await tx.query(
            "UPDATE site_flats SET device_uuid = NULL, status = 'planned', updated_at = NOW() WHERE device_uuid = $1",
            [newUuid]
          );
          unlinkedFlats = (unlinked && unlinked.rowCount) || 0;
        }
        const movedFlats = await tx.query(
          'UPDATE site_flats SET device_uuid = $1, updated_at = NOW() WHERE device_uuid = $2 RETURNING id, status, template_id',
          [newUuid, oldDevice.device_uuid]
        );
        for (const f of (movedFlats && movedFlats.rows) || []) {
          if (f.status !== 'written') continue;
          const okw = f.template_id
            ? await tx.query(
                "SELECT id FROM template_writes WHERE device_uuid = $1 AND template_id = $2 AND result = 'ok' LIMIT 1",
                [newUuid, f.template_id]
              )
            : { rows: [] };
          if (!okw.rows || okw.rows.length === 0) {
            await tx.query(
              "UPDATE site_flats SET status = 'planned', updated_at = NOW() WHERE id = $1 AND status = 'written'",
              [f.id]
            );
          }
        }
      }

      // 12) MQTT: cihaz kimligi yenilenir (eski pano ayni kullanici adiyla artik baglanamaz)
      const credential = await this.credentials.issueDeviceCredential({
        homeId,
        deviceId: newDeviceId,
        topicId: home.mqtt_username,
        tx,
      });

      // 13) Gunluk + denetim
      await tx.query(
        `INSERT INTO device_replacement_logs
           (home_id, old_device_uuid, new_device_uuid, replaced_by_user_id, replaced_by_label, service_session_id,
            ip_address, endpoints_migrated_count, config_snapshot, reason)
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)`,
        [
          homeId,
          oldDevice.device_uuid,
          newUuid,
          actor.userId || null,
          actor.label || null,
          actor.sessionId || null,
          actor.ip || null,
          moved.rowCount || 0,
          JSON.stringify(snapshot),
          reasonText || 'Pano değişimi',
        ]
      );
      // 14) Cocuk kilidi: yeni pano varsayilan olarak KILITSIZDIR. Eski panonun/evin bildirdigi kilit durumu
      //     yeni panoya yeniden uygulanmak uzere NIYET olarak kaydedilir (pano cevrimici olunca uygulanir;
      //     kopru uzlastirmasi + asagidaki yanit alani). Cihaz bayragi (gercek durum) DEGISTIRILMEZ.
      const priorLocked = home.child_lock_enabled === true || oldDevice.child_lock_enabled === true;
      if (priorLocked) {
        await tx.query(
          `UPDATE homes
              SET child_lock_requested = TRUE, child_lock_requested_at = CURRENT_TIMESTAMP, child_lock_requested_by = $2
            WHERE id = $1`,
          [homeId, actor.userId || null]
        );
      }

      await this._audit((t, p) => tx.query(t, p), {
        event: 'board_replaced',
        deviceUuid: newUuid,
        homeId,
        actor,
        details: {
          old_device_uuid: oldDevice.device_uuid,
          endpoints_migrated: moved.rowCount || 0,
          rules_migrated: (rulesMoved.rows || []).length,
          child_lock_carried: priorLocked,
          safety_restore: safetyRestore,
        },
      });

      return {
        ok: true,
        safetyRestore,
        priorLocked,
        oldDeviceUuid: oldDevice.device_uuid,
        migrated: moved.rowCount || 0,
        credential,
        runtimes,
        unlinkedFlats,
      };
    });

    if (!outcome.ok) throw outcome.error;

    const warnings = [];
    if (outcome.safetyRestore === 'required') {
      // sozlesme C4: eski uygulama bu uyariyi warnings listesinden zaten gosterir (ilk sirada)
      warnings.push(
        'Eski panonun güvenlik ayarları (sensörler, vanalar, bölgeler) yeni panoya aktarılmadı. Servis bu ayarları yeniden yazana kadar su/gaz koruması ÇALIŞMAZ. Yetkili servisi çağırın.'
      );
    }
    if (outcome.unlinkedFlats > 0) {
      warnings.push('Yeni kart başka bir daireye bağlıydı; o bağ kaldırıldı ve o daire "Planlandı" durumuna alındı.');
    }
    try {
      const kick = await this.credentials.kickUsernames(outcome.credential.previous_usernames);
      if (kick && kick.failed > 0) warnings.push('Eski pano bağlantısı atılamadı; kimlik yenilendi.');
      else if (kick && kick.skipped && outcome.credential.previous_usernames.length > 0) {
        warnings.push('EMQX yönetim API ayarı yok; eski pano bağlantısı atılamadı (kimlik yenilendi).');
      }
    } catch (_) {
      warnings.push('Eski pano bağlantısı atılamadı; kimlik yenilendi.');
    }

    const data = {
      message: 'Pano değişimi tamamlandı. Kanal adları, kurallar ve panjur süreleri yeni panoya taşındı.',
      old_device_uuid: outcome.oldDeviceUuid,
      new_device_uuid: newUuid,
      migrated_endpoints_count: outcome.migrated,
      home_id: homeId,
      device_credential: this._publicDeviceCredential(outcome.credential),
      // sync_full_config firmware sozlugunde YOKTUR; panjur sureleri cihaz cevrimici olunca set_runtime ile uygulanir.
      shutter_runtimes: outcome.runtimes,
      runtime_sync: 'pending_device_online',
      // Yeni pano henuz cevrimdisi (kimlik yazilmadi): kilit, pano cevrimici olunca yeniden uygulanir.
      child_lock: {
        enabled: outcome.priorLocked,
        sync: outcome.priorLocked ? 'pending_device_online' : 'not_required',
      },
      // sozlesme C4: 'required' -> servis guvenlik ayarlarini yeni panoya yeniden yazmali (su/gaz korumasi o zamana dek yok)
      safety_restore: outcome.safetyRestore,
    };
    if (warnings.length > 0) data.warnings = warnings;
    return data;
  }

  // ===========================================================================
  // B8: Cihaz listesi, yerel anahtar, kimlik yeniden uretimi
  // ===========================================================================

  /** GET /homes/:homeId/devices -> [{ device_uuid, name, online, last_seen_at, firmware }] */
  async listDevices({ homeId, includeNetwork = false }) {
    const res = await this.db.query(
      `SELECT d.id, d.device_uuid, COALESCE(NULLIF(d.name, ''), d.model, d.device_uuid) AS name, d.model,
              COALESCE(d.is_online, FALSE) AS online, d.last_seen_at, d.firmware_version AS firmware, d.ip_address
         FROM devices d
        WHERE d.home_id = $1
        ORDER BY d.created_at ASC`,
      [homeId]
    );
    return res.rows.map((r) => {
      const item = {
        id: r.id,
        device_uuid: r.device_uuid,
        name: r.name,
        model: r.model,
        online: r.online === true,
        last_seen_at: r.last_seen_at ? new Date(r.last_seen_at).toISOString() : null,
        firmware: r.firmware || null,
      };
      if (includeNetwork) item.ip_address = r.ip_address || null;
      return item;
    });
  }

  /** GET /homes/:homeId/devices/:uuid/local-key (LAN dogrudan mod). Her okuma denetim kaydina yazilir. */
  async getLocalKey({ actor, homeId, deviceUuid }) {
    if (!can('local_key', actor && actor.access)) {
      throw httpError(403, 'Yerel anahtar bu rol için görünür değildir.', 'FORBIDDEN');
    }
    const uuid = normalizeDeviceUuid(deviceUuid);
    if (!uuid) throw httpError(400, 'Geçersiz cihaz kimliği.', 'VALIDATION');

    const res = await this.db.query(
      'SELECT device_uuid, local_key_enc FROM devices WHERE home_id = $1 AND device_uuid = $2',
      [homeId, uuid]
    );
    if (res.rows.length === 0) throw httpError(404, 'Cihaz bu daireye ait değil veya bulunamadı.', 'NOT_FOUND');
    if (!res.rows[0].local_key_enc) {
      throw httpError(404, 'Bu cihaz için yerel anahtar tanımlı değil.', 'NOT_FOUND');
    }

    const localKey = this.secretBox.decrypt(res.rows[0].local_key_enc);
    // Denetim kaydi yazilamazsa anahtar VERILMEZ (fail-closed).
    await this._audit((t, p) => this.db.query(t, p), {
      event: 'local_key_read',
      deviceUuid: uuid,
      homeId,
      actor,
    });
    // pano-6: servis (PIN) oturumu anahtari okudu -> oturum bitince supurucu evin anahtarini dondurur. Isaret
    // yazilamazsa anahtar VERILMEZ (fail-closed; denetimle ayni).
    if (actor && actor.isServiceSession && actor.sessionId) {
      await this.db.query('UPDATE service_sessions SET local_key_read_at = NOW() WHERE id = $1', [actor.sessionId]);
    }
    // pano-5: istemci panonun durumdaki lk_fp'siyle karsilastirir (HMAC hesaplamaz); ayni formul.
    return { local_key: localKey, local_key_fp: localKeyFingerprint(localKey, res.rows[0].device_uuid || uuid) };
  }

  /**
   * Cihaz MQTT kimligini yeniden uretir (tek seferlik yanit; eski parola gecersiz olur ve baglanti atilir).
   * Kurulum sihirbazi yarida kaldiginda / kimlik kaybolunca kullanilir.
   */
  async reissueDeviceCredential({ actor, homeId, deviceUuid }) {
    if (!can('device_credential', actor && actor.access)) {
      throw httpError(403, 'Bu işlem için yetkiniz yetersizdir.', 'FORBIDDEN');
    }
    const uuid = normalizeDeviceUuid(deviceUuid);
    if (!uuid) throw httpError(400, 'Geçersiz cihaz kimliği.', 'VALIDATION');

    const result = await this.db.withTransaction(async (tx) => {
      const dev = await tx.query(
        'SELECT id FROM devices WHERE home_id = $1 AND device_uuid = $2 FOR UPDATE',
        [homeId, uuid]
      );
      if (dev.rows.length === 0) throw httpError(404, 'Cihaz bu daireye ait değil veya bulunamadı.', 'NOT_FOUND');
      const credential = await this.credentials.issueDeviceCredential({
        homeId,
        deviceId: dev.rows[0].id,
        tx,
      });
      await this._audit((t, p) => tx.query(t, p), {
        event: 'device_credential_reissued',
        deviceUuid: uuid,
        homeId,
        actor,
      });
      return credential;
    });

    const warnings = [];
    try {
      const kick = await this.credentials.kickUsernames(result.previous_usernames);
      if (kick && kick.failed > 0) warnings.push('Eski cihaz bağlantısı atılamadı.');
    } catch (_) {
      warnings.push('Eski cihaz bağlantısı atılamadı.');
    }
    const data = this._publicDeviceCredential(result);
    if (warnings.length > 0) data.warnings = warnings;
    return data;
  }

  // ===========================================================================
  // B1/B2: Komut hatti (YALNIZCA sunucu uzerinden)
  // ===========================================================================

  /**
   * POST /devices/:id/command. `deviceRef`: cihaz kaydinin UUID'si (devices.id) veya device_uuid.
   * Sira: sema dogrulama -> rol matrisi -> cihaz bu evde mi -> cevrimdisi mi (409) -> yayin (hata yutulmaz).
   * Doner: { delivered, device_online, command_id }. `delivered` = broker'a QoS1 ile iletildi
   * (cihazin uygulamasi `state` mesajiyla dogrulanir).
   */
  async sendCommand({ actor, homeId, deviceRef, command }) {
    const validated = validateCommand(command);
    if (!validated.ok) throw httpError(400, validated.error, 'VALIDATION');

    // Yetenek: eylemcide YONE gore (kapat/sustur herkese, ac/calistir misafire kapali); eski turler AYNEN.
    const capability = capabilityForCommand(validated);
    if (!can(capability, actor && actor.access)) {
      throw httpError(403, 'Bu komut için yetkiniz yetersizdir.', 'FORBIDDEN');
    }
    if (!isUuid(homeId)) throw httpError(400, 'Geçersiz daire kimliği (home_id).', 'VALIDATION');

    const ref = typeof deviceRef === 'string' ? deviceRef.trim() : '';
    if (!ref) throw httpError(400, 'Cihaz kimliği zorunludur.', 'VALIDATION');
    const asUuid = normalizeDeviceUuid(ref);
    if (!isUuid(ref) && !asUuid) throw httpError(400, 'Geçersiz cihaz kimliği.', 'VALIDATION');

    const device = await this._findHomeDevice(homeId, isUuid(ref) ? { id: ref } : { uuid: asUuid });

    // Cocuk kilidi: ozel rota ile AYNI uygulama (dogrulama, dagitim, serilestirme, denetim, no-op).
    // Hedef cihaz bu evde dogrulandi (IDOR); kilit ev geneli oldugu icin cevrimdisi kontrolu evde yapilir.
    if (validated.kind === KINDS.CHILD_LOCK) {
      return this._applyChildLock({
        actor,
        homeId,
        enabled: validated.command.enabled,
        commandId: validated.command.id || null,
        via: 'command_route',
      });
    }

    const safety = SAFETY_KINDS.includes(validated.kind);
    if (safety && String(device.device_uuid || '').toUpperCase() !== validated.command.uid) {
      // Komut ev konusuna gider; uid baska panoyu gosteriyorsa o pano uygular: hedef cihazla ESLESMELI.
      throw httpError(400, 'Komuttaki pano kimliği (uid) hedef cihazla eşleşmiyor.', 'VALIDATION');
    }

    await this._assertCommandTarget(device.id, validated, actor);

    if (!device.is_online) {
      throw httpError(409, 'Cihaz çevrimdışı; komut iletilmedi.', 'DEVICE_OFFLINE', { device_online: false });
    }

    if (safety) return this._sendSafetyCommand(device, validated);

    // Toplu "isiklari kapat" (DAIRE-01): firmware'de priz tipi yok; all_lights_off / all_off uygulamada 'plug' (priz)
    // diye isaretlenen roleleri de kapatirdi. Evde priz varsa "Hepsini Kapat" ile AYNI kural (peace_service): yalniz
    // ACIK isik roleleri tek tek kapatilir; yanit ayni bicim (+ command_ids). Priz yoksa davranis AYNEN (tek toplu komut).
    if (validated.kind === KINDS.GROUP && LIGHTS_OFF_GROUP_COMMANDS.includes(validated.command.cmd)) {
      const kept = await this.peace.closeLightsKeepingPlugs({ homeId, topicId: device.topic_id });
      if (kept) {
        const ids = kept.commandIds;
        const out = { delivered: true, device_online: true, command_id: ids.length > 0 ? ids[0] : null, command_ids: ids };
        if (ids.length === 0 && kept.skippedLights === 0) out.no_change = true; // acik lamba yoktu: komut gonderilmedi
        if (kept.skippedLights > 0) out.skipped_count = kept.skippedLights;
        return out;
      }
    }

    const commandId = validated.command.id || this._newCommandId();
    const payload = { ...validated.command, id: commandId };
    // Duz role komutu ev konusuna gider (evdeki BUTUN panolar alir): guvenlik destekli panoya (caps 'safety', firmware 1.2+)
    // hedef uid'si eklenir; baska panonun ayni numarali eylemci rolesine (siren/vana) dusmez. v:2 firmware bilinmeyen alani
    // reddettigi icin eski panoya eklenmez (inceleme RV-2; firmware ayrica uid'siz komutu eylemci rolesinde yok sayar).
    if (validated.kind === KINDS.RELAY && Array.isArray(device.caps) && device.caps.includes('safety') && device.device_uuid) {
      payload.uid = String(device.device_uuid).toUpperCase();
    }
    await this._publishCommand(device.topic_id, payload);
    return { delivered: true, device_online: true, command_id: commandId };
  }

  async _findHomeDevice(homeId, { id = null, uuid = null }) {
    const res = await this.db.query(
      `SELECT d.id, d.device_uuid, COALESCE(d.is_online, FALSE) AS is_online, h.mqtt_username AS topic_id, d.caps
         FROM devices d
         JOIN homes h ON h.id = d.home_id
        WHERE d.home_id = $1 AND ((d.id::text = $2) OR (d.device_uuid = $3))`,
      [homeId, id, uuid]
    );
    if (res.rows.length === 0) {
      throw httpError(404, 'Cihaz bu daireye ait değil veya bulunamadı.', 'NOT_FOUND');
    }
    return res.rows[0];
  }

  /**
   * Hedef denetimi (derinlemesine savunma; asil yetki firmware'dedir):
   *  - Panjur kanallari role komutuyla surulemez (cift yon riskine karsi).
   *  - Eylemci kanalina (endpoints.actuator_type dolu) duz role komutu -> 409 ACTUATOR_USE_SAFETY_COMMAND [WP-S4 1].
   *  - Guvenlik komutlari: caps 'safety' yoksa 409 FIRMWARE_UNSUPPORTED [O1]; gaz vanasina open -> 409 GAS_LOCAL_ONLY
   *    [K-4]; vana open: mode normal, vananin bolgeleri normal, bolgedeki ayni akiskanli sensorler ok && !active
   *    olmali, degilse 409 ZONE_ALARM_ACTIVE [Y-3]. Bolge testi yalniz normal bolgede.
   *    (caps denetimi once yapilir: caps yoksa ozet de yoktur; tasarimdaki sira 4. maddeydi - uygulama notu.)
   */
  async _assertCommandTarget(deviceId, validated, actor = null) {
    if (validated.kind === KINDS.RELAY) {
      const res = await this.db.query(
        'SELECT type, actuator_type FROM endpoints WHERE device_id = $1 AND channel_index = $2',
        [deviceId, validated.command.relay]
      );
      const row = res.rows[0];
      if (row && row.type === 'shutter') {
        throw httpError(400, 'Panjur kanalları röle komutuyla sürülemez; panjur komutu kullanın.', 'VALIDATION');
      }
      if (row && row.actuator_type !== undefined && row.actuator_type !== null) {
        throw httpError(409, 'Bu kanal bir güvenlik cihazına bağlı; lamba gibi açılamaz. Güvenlik komutunu kullanın.', 'ACTUATOR_USE_SAFETY_COMMAND');
      }
      return;
    }
    if (!SAFETY_KINDS.includes(validated.kind)) return;

    const res = await this.db.query('SELECT caps, safety_state FROM devices WHERE id = $1', [deviceId]);
    const row = res.rows[0] || {};
    const caps = Array.isArray(row.caps) ? row.caps : null;
    if (!caps || !caps.includes('safety')) {
      throw httpError(409, 'Bu pano yazılımı güvenlik modülünü desteklemiyor; pano yazılımını güncelleyin.', 'FIRMWARE_UNSUPPORTED');
    }
    if (validated.kind === KINDS.SAFETY_ARM) {
      // Faz 2 F2.B.7: hirsiz alarmi kipi yalniz caps 'intrusion' ilan eden firmware'de (v1.2.1+). Durum denetimi firmware'de
      // (hazir degilse not_ready); sunucu ek on kosul uygulamaz (cozme her zaman denenebilir).
      if (!caps.includes('intrusion')) {
        throw httpError(409, "Bu pano yazılımı alarm kipini desteklemiyor; v1.2.1'e güncelleyin.", 'FIRMWARE_UNSUPPORTED');
      }
      return;
    }
    const st = row.safety_state && typeof row.safety_state === 'object' ? row.safety_state : {};
    const zones = Array.isArray(st.zones) ? st.zones : [];
    const zoneNormal = (id) => {
      const z = zones.find((x) => x && x.id === id);
      return !z || z.st === 'normal'; // bildirilmeyen bolge: firmware karar verir
    };

    if (validated.kind === KINDS.ALARM_TEST) {
      if (st.mode !== 'normal' || !zoneNormal(validated.command.zone)) {
        throw httpError(409, 'Bölgede alarm ya da test sürüyor; test başlatılamadı.', 'ZONE_ALARM_ACTIVE');
      }
      return;
    }
    if (validated.kind !== KINDS.ACTUATOR) return;

    const actuators = Array.isArray(st.actuators) ? st.actuators : [];
    const act = actuators.find((a) => a && a.id === validated.command.actuator);
    if (!act) throw httpError(404, 'Eylemci bulunamadı.', 'NOT_FOUND');
    const to = validated.command.to;
    const isValve = act.kind === 'valve';
    if (isValve !== (to === 'open' || to === 'closed')) {
      throw httpError(400, isValve ? 'Vana için hedef "open" ya da "closed" olmalı.' : 'Bu cihaz için hedef "on" ya da "off" olmalı.', 'VALIDATION');
    }
    // guvenlik-7: gaz alarmi (bolge latched/fault, kind gas) surerken havalandirma fanini durdurmak gazi biriktirir:
    // yalniz alarm onaylama yetkisi olanlar (safety_ack: ev sahibi/sakin/servis) kapatabilir; misafir kapatamaz.
    if (act.kind === 'fan' && to === 'off') {
      const actZones = Array.isArray(act.zones) ? act.zones : [];
      const gasActive = zones.some(
        (z) => z && actZones.includes(z.id) && (z.st === 'latched' || z.st === 'fault') && z.kind === 'gas'
      );
      if (gasActive && !can('safety_ack', actor && actor.access)) {
        throw httpError(403, 'Gaz alarmı sürerken havalandırmayı yalnız ev sahibi/üyeleri durdurabilir.', 'FORBIDDEN');
      }
    }
    if (isSafeTarget(to)) return; // kapatma / susturma her zaman serbest (gaz alarmindaki fan haric, yukarida)
    if (isValve && act.medium === 'gas') {
      throw httpError(409, 'Gaz vanası güvenlik gereği yalnız yerinde, panodaki düğmeyle açılır.', 'GAS_LOCAL_ONLY');
    }
    if (isValve) {
      const actZones = Array.isArray(act.zones) ? act.zones : [];
      const sensors = Array.isArray(st.sensors) ? st.sensors : [];
      const wetOrUnknown = sensors.some(
        (s) => s && actZones.includes(s.zone) && s.kind === act.medium && !(s.ok === true && s.active !== true)
      );
      if (st.mode !== 'normal' || !actZones.every(zoneNormal) || wetOrUnknown) {
        throw httpError(409, 'Alarm sürerken vana açılamaz. Önce sensörün kuruduğundan emin olup alarmı onaylayın.', 'ZONE_ALARM_ACTIVE');
      }
    }
  }

  /**
   * Guvenlik komutu yayini: onay bekleyicisi YAYINDAN ONCE kurulur ve YALNIZ hedef panonun (uid) yankisini kabul eder
   * [Y5]. last_id -> applied:true; last_rej -> 409 DEVICE_REJECTED (reason = firmware kodu); zaman asimi -> applied:null.
   */
  async _sendSafetyCommand(device, validated) {
    const commandId = validated.command.id || this._newCommandId();
    const payload = { ...validated.command, id: commandId };
    const bridge = this.bridge;
    const canWait = typeof bridge.expectOutcome === 'function';
    const waiter = canWait ? bridge.expectOutcome(device.topic_id, commandId, SAFETY_ACK_TIMEOUT_MS, { uid: validated.command.uid }) : null;
    try {
      await this._publishCommand(device.topic_id, payload);
    } catch (err) {
      if (canWait && typeof bridge.cancelAck === 'function') bridge.cancelAck(device.topic_id, commandId);
      throw err;
    }
    const outcome = waiter ? await waiter : null;
    if (outcome && outcome.rejected) {
      const code = String(outcome.rejected);
      throw httpError(409, REJECTION_TEXT[code] || 'Pano komutu reddetti.', 'DEVICE_REJECTED', { reason: code });
    }
    return {
      delivered: true,
      device_online: true,
      command_id: commandId,
      applied: outcome && outcome.ok === true ? true : null,
    };
  }

  // ===========================================================================
  // ADIM 17: Cocuk kilidi, gece huzur bildirimi
  // ===========================================================================

  /** Evin cihazlarini ve cevrimici olanlarin sayisini doner. */
  async _homeDeviceStates(homeId) {
    const res = await this.db.query(
      `SELECT d.id, COALESCE(d.is_online, FALSE) AS is_online FROM devices d WHERE d.home_id = $1`,
      [homeId]
    );
    return { total: res.rows.length, online: res.rows.filter((r) => r.is_online === true).length };
  }

  async _homeTopicId(homeId) {
    const res = await this.db.query('SELECT mqtt_username FROM homes WHERE id = $1', [homeId]);
    if (res.rows.length === 0) throw httpError(404, 'Daire bulunamadı.', 'NOT_FOUND');
    return res.rows[0].mqtt_username;
  }

  /**
   * Cocuk kilidi (B12) - TEK uygulama: hem `POST /devices/child-lock` hem de genel
   * `POST /devices/:id/command {cmd:'set_child_lock'}` yolu buradan gecer (ayni dogrulama, ayni yetki,
   * ayni dagitim, ayni denetim kaydi, ayni seri hale getirme).
   *
   * Ilkeler:
   *  - Broker PUBACK, cihaza UYGULANDI demek DEGILDIR (is_online 120 sn bayat olabilir, pano clean-session).
   *    Bu yuzden istenen deger DURUM olarak yazilmaz ve "kilitlendi" denmez; gercek deger cihazin
   *    `state.child_lock` bildiriminden gelir (kopru devices + homes.child_lock_enabled'i esitler).
   *    Yalnizca NIYET (homes.child_lock_requested*) kaydedilir.
   *  - Ev basina seri hale getirilir (pg_advisory_xact_lock): esdeger iki gecis ters sirada yayinlanip
   *    commit edilemez. Kilit sirasi kopruyle (devices -> homes) cakismaz: burada yalnizca advisory kilit.
   *  - Niyet + denetim kaydi YAYINDAN ONCE yazilir; yayin basarisizsa transaction geri alinir (kayit kalmaz).
   *  - Cevrimici tum panolar zaten istenen degeri bildiriyorsa NO-OP (her gecis panoda NVS yazar ve bip calar).
   *    Karsit yonde bekleyen bir niyet varsa (henuz yansimamis istek) no-op YAPILMAZ.
   *  - Hepsi cevrimdisiysa 409 DEVICE_OFFLINE; kismen cevrimdisiysa komut yayinlanir ve
   *    `offline_devices` listelenir.
   * Doner: { home_id, requested, delivered, device_online, command_id, offline_devices[], no_change? }
   *   delivered = istek karsilandi (komut broker'a iletildi VEYA durum zaten istenen degerde).
   */
  async _applyChildLock({ actor, homeId, enabled, commandId = null, via = 'child_lock_route' }) {
    const check = { cmd: 'set_child_lock', enabled };
    if (commandId) check.id = commandId;
    const validated = validateCommand(check);
    if (!validated.ok) throw httpError(400, validated.error, 'VALIDATION');
    if (!can('child_lock', actor && actor.access)) {
      throw httpError(403, 'Çocuk kilidini değiştirme yetkiniz yok.', 'FORBIDDEN');
    }
    if (!isUuid(homeId)) throw httpError(400, 'Geçersiz daire kimliği (home_id).', 'VALIDATION');

    return this.db.withTransaction(async (tx) => {
      await tx.query('SELECT pg_advisory_xact_lock(hashtext($1))', [`child-lock:${homeId}`]);

      const homeRes = await tx.query(
        'SELECT id, mqtt_username, child_lock_enabled, child_lock_requested FROM homes WHERE id = $1',
        [homeId]
      );
      if (homeRes.rows.length === 0) throw httpError(404, 'Daire bulunamadı.', 'NOT_FOUND');
      const home = homeRes.rows[0];

      const devRes = await tx.query(
        `SELECT d.id, d.device_uuid, COALESCE(d.is_online, FALSE) AS is_online, d.child_lock_enabled
           FROM devices d
          WHERE d.home_id = $1
          ORDER BY d.created_at ASC`,
        [homeId]
      );
      if (devRes.rows.length === 0) throw httpError(404, 'Daireye bağlı pano bulunamadı.', 'NOT_FOUND');
      const online = devRes.rows.filter((d) => d.is_online === true);
      const offlineDevices = devRes.rows.filter((d) => d.is_online !== true).map((d) => d.device_uuid);
      if (online.length === 0) {
        throw httpError(409, 'Pano çevrimdışı; çocuk kilidi komutu iletilemedi.', 'DEVICE_OFFLINE', {
          device_online: false,
          offline_devices: offlineDevices,
        });
      }

      // NO-OP: cevrimici tum panolar zaten istenen degeri bildiriyor ve karsit yonde bekleyen niyet yok.
      const intent = home.child_lock_requested;
      const opposingIntent = intent !== null && intent !== undefined && intent !== enabled;
      if (!opposingIntent && online.every((d) => d.child_lock_enabled === enabled)) {
        return {
          home_id: homeId,
          requested: enabled,
          delivered: true,
          no_change: true,
          device_online: true,
          command_id: null,
          offline_devices: offlineDevices,
        };
      }

      const outId = validated.command.id || this._newCommandId();

      // Niyet + denetim: YAYINDAN ONCE (yayin basarisizsa transaction geri alinir, kayit kalmaz).
      await tx.query(
        `UPDATE homes
            SET child_lock_requested = $2, child_lock_requested_at = CURRENT_TIMESTAMP, child_lock_requested_by = $3
          WHERE id = $1`,
        [homeId, enabled, actor.userId || null]
      );
      await this._audit((t, p) => tx.query(t, p), {
        event: 'child_lock_set',
        homeId,
        actor,
        details: {
          enabled,
          command_id: outId,
          via,
          devices_online: online.length,
          devices_offline: offlineDevices.length,
        },
      });

      await this._publishCommand(home.mqtt_username, { cmd: 'set_child_lock', enabled, id: outId });

      return {
        home_id: homeId,
        requested: enabled,
        delivered: true,
        device_online: true,
        command_id: outId,
        offline_devices: offlineDevices,
      };
    });
  }

  /** POST /devices/child-lock: ince sarmalayici; asil is `_applyChildLock`. */
  async setChildLock({ actor, homeId, enabled }) {
    return this._applyChildLock({ actor, homeId, enabled, via: 'child_lock_route' });
  }

  /**
   * GET /devices/child-lock/:home_id. `child_lock_enabled` = homes sutunu (kopru, cihaz bildirimlerinden
   * bool_and ile esitler). Ek: cihaz bazli bildirilen durum, bekleyen niyet ve tutarlilik bayragi.
   */
  async getChildLock({ homeId }) {
    const res = await this.db.query(
      'SELECT child_lock_enabled, child_lock_requested, child_lock_requested_at FROM homes WHERE id = $1',
      [homeId]
    );
    if (res.rows.length === 0) throw httpError(404, 'Daire bulunamadı.', 'NOT_FOUND');
    const home = res.rows[0];
    const enabled = home.child_lock_enabled === true;

    const devRes = await this.db.query(
      `SELECT d.device_uuid, COALESCE(d.is_online, FALSE) AS online, d.child_lock_enabled
         FROM devices d
        WHERE d.home_id = $1
        ORDER BY d.created_at ASC`,
      [homeId]
    );
    const devices = devRes.rows.map((d) => ({
      device_uuid: d.device_uuid,
      online: d.online === true,
      child_lock_enabled: d.child_lock_enabled === true,
    }));
    return {
      home_id: homeId,
      child_lock_enabled: enabled,
      requested: home.child_lock_requested === null || home.child_lock_requested === undefined ? null : home.child_lock_requested === true,
      requested_at: home.child_lock_requested_at ? new Date(home.child_lock_requested_at).toISOString() : null,
      devices,
      in_sync: devices.filter((d) => d.online).every((d) => d.child_lock_enabled === enabled),
    };
  }

  /** v2 (WP-H): canli anlik goruntu, panjur, saat dilimi, son bildirim. Ayrintisi peace_service.js'te. */
  async getPeaceNotificationSettings({ homeId }) {
    return this.peace.getSettings({ homeId });
  }

  async updatePeaceNotificationSettings({ actor, homeId, enabled, notificationTime }) {
    if (!can('child_lock', actor && actor.access)) {
      throw httpError(403, 'Huzur bildirimi ayarını değiştirme yetkiniz yok.', 'FORBIDDEN');
    }
    if (enabled !== undefined && typeof enabled !== 'boolean') {
      throw httpError(400, '"enabled" alanı true veya false olmalı.', 'VALIDATION');
    }
    if (notificationTime !== undefined && (typeof notificationTime !== 'string' || !TIME_HHMM.test(notificationTime))) {
      throw httpError(400, 'Bildirim saati SS:DD (24 saat) biçiminde olmalı. Örnek: 23:30', 'VALIDATION');
    }
    if (enabled === undefined && notificationTime === undefined) {
      throw httpError(400, 'Güncellenecek alan yok ("enabled" veya "notification_time").', 'VALIDATION');
    }

    const res = await this.db.query(
      `UPDATE homes
          SET peace_notification_enabled = COALESCE($1, peace_notification_enabled),
              peace_notification_time = COALESCE($2, peace_notification_time)
        WHERE id = $3
        RETURNING id, peace_notification_enabled, peace_notification_time`,
      [enabled === undefined ? null : enabled, notificationTime === undefined ? null : notificationTime, homeId]
    );
    if (res.rows.length === 0) throw httpError(404, 'Daire bulunamadı.', 'NOT_FOUND');
    return { message: 'Gece huzur bildirimi ayarları güncellendi.', settings: res.rows[0] };
  }

  /**
   * "Hepsini kapat" v2 (WP-H): yalniz CANLI cihaz verisine gore komut uretir (priz varsa tek tek role, panjur asagi),
   * bildirim kaydini cozer, DB'ye iyimser yazmaz. Yetki burada denetlenir; mantik peace_service.js'tedir.
   */
  async closeAllOpenLights({ actor, homeId, noticeId, includeShutters }) {
    if (!can('group', actor && actor.access)) {
      throw httpError(403, 'Toplu komut için yetkiniz yok.', 'FORBIDDEN');
    }
    return this.peace.closeAll({ actor, homeId, noticeId, includeShutters });
  }

  // ===========================================================================
  // ADIM 16: Sistem doktoru (TUM cihazlar)
  // ===========================================================================

  /**
   * sko-6 (sozlesme C15): bulut-MQTT koprusu bagli degil ya da yeni baglandi (kalp atislari henuz gelmedi, 120 sn
   * dolmadi): panonun last_seen'i ilerlemez; eski last_seen evin elektrik/internet arizasi KANITI degildir.
   */
  _cloudLinkSuspect(nowMs) {
    if (!this._bridgeConnected()) return true;
    const since = this.bridge && Number.isFinite(this.bridge.connectedSince) ? this.bridge.connectedSince : null;
    return since !== null && nowMs - since < 120 * 1000;
  }

  _classifyDevice(device, nowMs, { linkSuspect = false } = {}) {
    const lastSeenMs = device.last_seen_at ? new Date(device.last_seen_at).getTime() : 0;
    const seconds = lastSeenMs > 0 ? Math.max(0, Math.floor((nowMs - lastSeenMs) / 1000)) : null;

    // bireysel-12: pano buluta HIC baglanmamis (kurulum tamamlanmamis): ariza/guc kesintisi DEGIL, ayri durum.
    if (!device.last_seen_at) {
      return {
        seconds: null, network_status: 'NEVER_SEEN', power_status: 'UNKNOWN', level: 'warning',
        title: 'Pano Henüz Buluta Hiç Bağlanmadı',
        summary: 'Pano bulut sunucuya henüz hiç bağlanmadı; kurulumun internet bağlantısı adımı tamamlanmamış olabilir.',
        action:
          '1. Panoya Ethernet kablosu takılı olduğundan ya da Wi-Fi kurulumunun yapıldığından emin olun.\n' +
          '2. Pano internete çıktıktan sonra bulut bağlantısı 10 dk\'ya kadar sürebilir; bu süre kadar bekleyin.\n' +
          '3. Buluta bağlanmak için pano yazılımı v1.3.0 veya üstü gerekir.\n' +
          '4. Panonun ilk hazırlığı (provizyon) yapılmamışsa yetkili servisle iletişime geçin.',
      };
    }

    if (seconds !== null && seconds <= 120) {
      return {
        seconds, network_status: 'OK', power_status: 'OK', level: 'ok',
        title: 'Tüm Sistemler Sağlıklı ve Çevrimiçi',
        summary: 'Bulut sunucu, ev modemi ve pano donanımı kesintisiz haberleşiyor. Herhangi bir arıza bulunamadı.',
        action: null,
      };
    }
    if (linkSuspect) {
      // C15: sorun bulut tarafinda olabilir; Wi-Fi kurtarma / sigorta onerilmez (kullanici gereksiz ayar degistirmesin)
      return {
        seconds, network_status: 'UNKNOWN', power_status: 'UNKNOWN', level: 'warning',
        title: 'Bulut Bağlantısında Geçici Sorun',
        summary: 'Sunucumuzun cihazlarla bağlantısında geçici bir sorun var; panonuz büyük olasılıkla çalışıyor. Birkaç dakika sonra yeniden deneyin.',
        action: null,
      };
    }
    if (seconds !== null && seconds <= 300) {
      return {
        seconds, network_status: 'WARNING', power_status: 'OK', level: 'warning',
        title: 'Zayıf veya Gecikmeli Wi-Fi Bağlantısı',
        summary: `Pano en son ${seconds} saniye önce görüldü. İnternet paketlerinde gecikme yaşanıyor olabilir.`,
        action: 'Modem ile panonun sinyal kalitesini kontrol edin veya modemi yeniden başlatın.',
      };
    }
    return {
      seconds, network_status: 'OFFLINE', power_status: 'SUSPECTED_OFFLINE_OR_POWER_OUTAGE', level: 'error',
      title: 'Pano Çevrimdışı (Ev İnterneti veya Güç Kesik)',
      summary: `Pano ${seconds ? `${Math.round(seconds / 60)} dakikadır` : 'uzun süredir'} bulut sunucuya sinyal gönderemiyor.`,
      action:
        '1. Pano sigortasının açık olduğundan ve adaptör üzerindeki LED ışığının yandığından emin olun.\n' +
        '2. Evdeki Wi-Fi modeminizi kontrol edin (İnternet ışıkları normal mi).\n' +
        '3. Modem adı veya şifresi değiştiyse "Wi-Fi Kurtarma Sihirbazı" ile yeni şifreyi panoya yükleyin.',
    };
  }

  /**
   * 3 katmanli teshis (bulut / ev agi / pano gucu). Dairedeki TUM cihazlar degerlendirilir;
   * ust duzey alanlar en son gorulen (birincil) cihazi ve en kotu genel seviyeyi yansitir.
   */
  async getSystemDiagnostic({ homeId }) {
    const homeRes = await this.db.query('SELECT id FROM homes WHERE id = $1', [homeId]);
    if (homeRes.rows.length === 0) throw httpError(404, 'Daire bulunamadı.', 'NOT_FOUND');

    const started = Date.now();
    let dbOk = false;
    try {
      await this.db.query('SELECT 1');
      dbOk = true;
    } catch (_) {
      dbOk = false;
    }
    const latency = Date.now() - started;
    const mqttOk = this._bridgeConnected();
    const cloud = {
      status: dbOk && mqttOk ? 'OK' : 'DEGRADED',
      latency_ms: latency,
      db_connected: dbOk,
      mqtt_bridge_connected: mqttOk,
    };

    const devRes = await this.db.query(
      `SELECT d.id, d.device_uuid, d.name, d.model, d.firmware_version, d.ip_address, d.last_seen_at,
              COALESCE(d.is_online, FALSE) AS is_online
         FROM devices d
        WHERE d.home_id = $1
        ORDER BY d.last_seen_at DESC NULLS LAST`,
      [homeId]
    );
    const epRes = await this.db.query('SELECT count(*) AS count FROM endpoints WHERE home_id = $1', [homeId]);
    const endpointCount = parseInt((epRes.rows[0] && epRes.rows[0].count) || '0', 10);

    if (devRes.rows.length === 0) {
      return {
        cloud,
        home_network: { status: 'UNCLAIMED', device_ip: null, last_seen_at: null, seconds_since_last_seen: null },
        hardware_power: { status: 'UNCLAIMED', is_online: false },
        devices: [],
        endpoint_count: endpointCount,
        diagnosis_title: 'Daireye Henüz Pano Bağlanmamış',
        diagnosis_summary: 'Bu daireye henüz bir otomasyon panosu tanımlanmamış. Yeni pano kurulumu için karekod taratın.',
        diagnosis_level: 'warning',
        action_recommendation: 'Ana ekrandaki "Cihaz Ekle (Karekod Tara)" seçeneğini kullanarak panonuzu dairenize tanıtın.',
      };
    }

    const nowMs = this._now().getTime();
    const rank = { ok: 0, warning: 1, error: 2 };
    const linkSuspect = this._cloudLinkSuspect(nowMs);
    const perDevice = devRes.rows.map((d) => {
      const c = this._classifyDevice(d, nowMs, { linkSuspect });
      return { row: d, c };
    });
    // C15: durumu bilinmeyen (bulut kesintisi) pano varken genel tablo bulut metnidir ve 'error'a yukseltilmez
    const unknownCloud = perDevice.find((p) => p.c.network_status === 'UNKNOWN') || null;
    const primary = perDevice[0];
    // Genel seviye: hepsi saglikliysa ok; HICBIRI haberlesmiyorsa (yakin zamanda gorulmemis) error - yalniz hic
    // baglanmamis (NEVER_SEEN) panolardan olusuyorsa warning (kurulum eksik, ariza degil; bireysel-12); aksi halde warning.
    const levels = perDevice.map((p) => p.c.level);
    const communicating = perDevice.filter((p) => p.c.network_status === 'OK' || p.c.network_status === 'WARNING').length;
    let overall = 'warning';
    if (levels.every((l) => l === 'ok')) overall = 'ok';
    else if (!unknownCloud && communicating === 0 && perDevice.some((p) => p.c.network_status !== 'NEVER_SEEN')) overall = 'error';
    const worst = perDevice.reduce((a, b) => (rank[b.c.level] > rank[a.c.level] ? b : a), primary);
    const headline = unknownCloud
      ? { title: unknownCloud.c.title, summary: unknownCloud.c.summary, action: null }
      : perDevice.length > 1 && overall === 'warning' && communicating > 0
      ? {
          title: 'Bazı Panolar Çevrimdışı',
          summary: `${perDevice.length} panodan ${communicating} tanesi haberleşiyor.`,
          action: worst.c.action,
        }
      : { title: worst.c.title, summary: worst.c.summary, action: worst.c.action };

    return {
      cloud,
      home_network: {
        status: primary.c.network_status,
        device_ip: primary.row.ip_address,
        last_seen_at: primary.row.last_seen_at,
        seconds_since_last_seen: primary.c.seconds,
      },
      hardware_power: {
        status: primary.c.power_status,
        is_online: primary.row.is_online === true || (primary.c.seconds !== null && primary.c.seconds <= 120),
        device_uuid: primary.row.device_uuid,
        model: primary.row.model,
        firmware_version: primary.row.firmware_version,
      },
      devices: perDevice.map((p) => ({
        device_uuid: p.row.device_uuid,
        name: p.row.name || p.row.model || p.row.device_uuid,
        online: p.row.is_online === true,
        level: p.c.level,
        network_status: p.c.network_status,
        power_status: p.c.power_status,
        last_seen_at: p.row.last_seen_at,
        seconds_since_last_seen: p.c.seconds,
        firmware_version: p.row.firmware_version,
      })),
      endpoint_count: endpointCount,
      diagnosis_title: headline.title,
      diagnosis_summary: headline.summary,
      diagnosis_level: overall,
      action_recommendation: headline.action,
    };
  }

  // ===========================================================================
  // B9: Devreye alma (commissioning)
  // ===========================================================================

  /**
   * POST /homes/:homeId/commissioning. `tests_passed` SUNUCUDA hesaplanir: zorunlu 5 kontrolun
   * (relays, buttons, shutters, network, cloud) HEPSI `ok === true` ise. Istemcinin `tests_passed`
   * degeri YOK SAYILIR. Kontrol sonuclari commissioning_checks tablosunda ayri kaydedilir.
   * Varsayilan "tumu test edildi" notu YOKTUR.
   */
  async commissionHome({ actor, homeId, deviceUuid, checks, notes }) {
    if (!can('commission', actor && actor.access)) {
      throw httpError(403, 'Devreye alma yalnızca yetkili servis tarafından yapılabilir.', 'FORBIDDEN');
    }
    const uuid = normalizeDeviceUuid(deviceUuid);
    if (!uuid) throw httpError(400, 'Geçersiz cihaz kimliği (device_uuid).', 'VALIDATION');

    if (checks === null || typeof checks !== 'object' || Array.isArray(checks)) {
      throw httpError(400, '"checks" alanı 5 zorunlu kontrolü içeren bir nesne olmalı.', 'VALIDATION');
    }
    const unknown = Object.keys(checks).filter((k) => !REQUIRED_COMMISSIONING_CHECKS.includes(k));
    if (unknown.length > 0) {
      throw httpError(400, 'Bilinmeyen kontrol adı: ' + String(unknown[0]).replace(/[^A-Za-z0-9_-]/g, '?').slice(0, 32), 'VALIDATION');
    }
    const names = [];
    const oks = [];
    const details = [];
    for (const name of REQUIRED_COMMISSIONING_CHECKS) {
      const c = checks[name];
      if (c === null || c === undefined || typeof c !== 'object' || Array.isArray(c)) {
        throw httpError(400, `Zorunlu kontrol eksik: ${name}`, 'VALIDATION');
      }
      if (typeof c.ok !== 'boolean') {
        throw httpError(400, `"${name}.ok" alanı true veya false olmalı.`, 'VALIDATION');
      }
      const detail = textOrNull(c.detail, MAX_TEXT_LENGTH);
      if (detail === undefined) {
        throw httpError(400, `"${name}.detail" en fazla ${MAX_TEXT_LENGTH} karakterlik bir metin olmalı.`, 'VALIDATION');
      }
      names.push(name);
      oks.push(c.ok);
      details.push(detail);
    }
    const noteText = textOrNull(notes, 1000);
    if (noteText === undefined) throw httpError(400, 'Notlar en fazla 1000 karakterlik bir metin olmalı.', 'VALIDATION');

    const testsPassed = oks.every((v) => v === true);

    const result = await this.db.withTransaction(async (tx) => {
      const dev = await tx.query(
        'SELECT id, device_uuid FROM devices WHERE home_id = $1 AND device_uuid = $2 FOR UPDATE',
        [homeId, uuid]
      );
      if (dev.rows.length === 0) throw httpError(404, 'Cihaz bu daireye ait değil veya bulunamadı.', 'NOT_FOUND');
      const device = dev.rows[0];

      const log = await tx.query(
        `INSERT INTO commissioning_logs
           (home_id, device_id, device_uuid, technician_id, technician_label, service_session_id, tests_passed, notes)
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
         RETURNING id, created_at`,
        [homeId, device.id, uuid, actor.userId || null, actor.label || null, actor.sessionId || null, testsPassed, noteText]
      );

      await tx.query(
        `INSERT INTO commissioning_checks (commissioning_log_id, check_name, ok, detail)
         SELECT $1::uuid, t.check_name, t.ok, t.detail
           FROM unnest($2::text[], $3::boolean[], $4::text[]) AS t(check_name, ok, detail)`,
        [log.rows[0].id, names, oks, details]
      );

      let upd;
      if (testsPassed) {
        upd = await tx.query(
          `UPDATE devices
              SET is_commissioned = TRUE, commissioned_at = CURRENT_TIMESTAMP, commissioned_by = $1,
                  commissioning_status = 'APPROVED_WORKING', commissioning_notes = $2
            WHERE id = $3
            RETURNING commissioned_at`,
          [actor.userId || null, noteText, device.id]
        );
      } else {
        upd = await tx.query(
          `UPDATE devices
              SET is_commissioned = FALSE, commissioned_at = NULL, commissioned_by = NULL,
                  commissioning_status = 'TESTS_FAILED', commissioning_notes = $1
            WHERE id = $2
            RETURNING commissioned_at`,
          [noteText, device.id]
        );
      }

      // servis_kurulum-10: basarili devreye alma karta bagli site dairesini teslim eder (planned/written/installed ->
      // handed_over). Basarisiz devreye alma GERI CEKMEZ. Migration 035 yoksa atlanir.
      if (testsPassed && (await this._hasSchema035(tx))) {
        await tx.query(
          `UPDATE site_flats SET status = 'handed_over', updated_at = CURRENT_TIMESTAMP
            WHERE device_uuid = $1 AND status IN ('planned', 'written', 'installed')`,
          [uuid]
        );
      }

      await this._audit((t, p) => tx.query(t, p), {
        event: 'commissioning',
        deviceUuid: uuid,
        homeId,
        actor,
        details: { tests_passed: testsPassed },
      });

      return {
        log_id: log.rows[0].id,
        created_at: log.rows[0].created_at,
        commissioned_at: upd.rows[0] ? upd.rows[0].commissioned_at : null,
      };
    });

    const checksOut = {};
    names.forEach((n, i) => {
      checksOut[n] = { ok: oks[i], detail: details[i] };
    });
    return {
      commissioned: testsPassed,
      tests_passed: testsPassed,
      status: testsPassed ? 'APPROVED_WORKING' : 'TESTS_FAILED',
      device_uuid: uuid,
      checks: checksOut,
      log_id: result.log_id,
      commissioned_at: result.commissioned_at ? new Date(result.commissioned_at).toISOString() : null,
    };
  }

  /** GET /homes/:homeId/commissioning-status: dairedeki TUM cihazlar (eski alanlar birincil cihazdan). */
  async getCommissioningStatus({ homeId }) {
    const res = await this.db.query(
      `SELECT d.device_uuid, d.is_commissioned, d.commissioned_at, d.commissioning_status, d.commissioning_notes,
              u.full_name AS technician_name
         FROM devices d
         LEFT JOIN users u ON u.id = d.commissioned_by
        WHERE d.home_id = $1
        ORDER BY d.created_at ASC`,
      [homeId]
    );
    if (res.rows.length === 0) return { is_commissioned: false, status: 'NO_DEVICE', devices: [] };

    const devices = res.rows.map((r) => ({
      device_uuid: r.device_uuid,
      is_commissioned: r.is_commissioned === true,
      commissioned_at: r.commissioned_at ? new Date(r.commissioned_at).toISOString() : null,
      commissioning_status: r.commissioning_status,
      commissioning_notes: r.commissioning_notes,
      technician_name: r.technician_name || null,
    }));
    const first = devices[0];
    return {
      is_commissioned: devices.every((d) => d.is_commissioned),
      commissioned_at: first.commissioned_at,
      commissioning_status: first.commissioning_status,
      commissioning_notes: first.commissioning_notes,
      technician_name: first.technician_name,
      devices,
    };
  }
}

const instance = new DeviceService();

module.exports = instance;
module.exports.DeviceService = DeviceService;
module.exports.SQL = Object.freeze({ HAS_SAFETY_CONFIG: HAS_SAFETY_CONFIG_SQL });
module.exports.helpers = Object.freeze({
  normalizeDeviceUuid,
  normalizeIdentifier,
  channelCountForModel,
  maskEmail,
});
module.exports.constants = Object.freeze({
  PIN_MAX_ATTEMPTS,
  PIN_LOCK_MINUTES,
  OTP_MAX_ATTEMPTS,
  OTP_TTL_SECONDS,
  OTP_RESEND_COOLDOWN_SECONDS,
  STAFF_INSTALL_WINDOW_HOURS,
  BURNED_PIN,
  RESET_REASON_MIN_LENGTH,
  REQUIRED_COMMISSIONING_CHECKS,
});
