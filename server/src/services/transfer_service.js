'use strict';

// ==============================================================================
// AHBU Akilli Ev - Daire devri (WP-A: A10)
// ==============================================================================
//
//  - Baslatma yalnizca ev sahibi (route: requireHomeAccess(['owner'])). Hedef kimlik (e-posta /
//    telefon) ZORUNLU ve normalize edilir; kabul eden hesabin kimligi hedefle eslesmelidir.
//  - Kod: "AHBU-TR-" + 16 karakter (crypto.randomInt), DB'de YALNIZCA SHA-256 ozeti; 48 saat.
//  - Kabul: GERCEK transaction; devir satiri FOR UPDATE + atomik
//    `UPDATE ... WHERE status='PENDING' AND expires_at > NOW() RETURNING`.
//  - Hata mesajlari geneldir (hedef e-posta/telefon SIZDIRILMAZ).
//  - Yalnizca BU EVLE ilgili erisim iptal edilir: uyelikler, bu evin uygulama MQTT kimlikleri,
//    servis PIN'leri/oturumlari, davetler, zamanli kurallar (homeCleanupHook). Kullanicilarin
//    baska evlerdeki oturumlari DUSMEZ (refresh token'lara dokunulmaz).
//  - pano-6: eski sakinler panonun yerel anahtarini bilir; anahtar ayni islemde BEKLEYEN yolla dondurulur (yalniz tek
//    panolu ev; local_key_rotation) ve COMMIT sonrasi uzlastirici istenir.

const db = require('../db');
const { HttpError, generateCode, sha256Hex, isUuid } = require('../utils/helpers');
const { parseIdentifier, normalizeEmail, normalizePhone } = require('./auth_service');
const serviceTokenService = require('./service_token_service');
const { invalidateServiceSessionCache } = require('../middlewares/auth_middleware');

const CODE_PREFIX = 'AHBU-TR-';
const QR_PREFIX = 'AHBU-TRANSFER:';
const CODE_LENGTH = 16;
const TRANSFER_TTL_MS = 48 * 60 * 60 * 1000;

const GENERIC_INVALID = 'Geçersiz veya süresi dolmuş devir kodu.';
// ev_uyelik-2: devri kabul eden hesabin global rolu (baslatmada denetlenmez: hesap turu sizardi)
const STAFF_ROLES = Object.freeze(['service_user', 'super_user']);
const STAFF_TARGET_MESSAGE = 'Servis personeli ve yönetici hesapları daire sahibi olamaz. Devri bir müşteri hesabına yapın.';

let overrides = {};

function optionalModule(name) {
  if (Object.prototype.hasOwnProperty.call(overrides, name)) return overrides[name];
  try {
    return require(`./${name}`);
  } catch (err) {
    if (err && err.code === 'MODULE_NOT_FOUND' && String(err.message).includes(name)) return null;
    throw err;
  }
}

/** WP-B/WP-C ev temizligi: home_cleanup.cleanupHome(tx, homeId, opts). Yoksa no-op. */
async function homeCleanupHook(tx, homeId) {
  const mod = optionalModule('home_cleanup');
  if (mod && typeof mod.cleanupHome === 'function') {
    return mod.cleanupHome(tx, homeId, { keepEndpoints: true, cancelPendingTransfers: false });
  }
  // Yedek (modul yoksa): davetleri sil.
  await tx.query('DELETE FROM home_invitations WHERE home_id = $1', [homeId]);
  return { cleaned: { home_invitations: -1 }, skipped: ['home_cleanup'] };
}

function normalizeTransferCode(input) {
  if (typeof input !== 'string' && typeof input !== 'number') return null;
  let s = String(input).trim().toUpperCase().replace(/\s+/g, '');
  if (s.startsWith(QR_PREFIX)) s = s.slice(QR_PREFIX.length);
  if (!s.startsWith(CODE_PREFIX)) s = CODE_PREFIX + s;
  return new RegExp(`^AHBU-TR-[A-Z0-9]{${CODE_LENGTH}}$`).test(s) ? s : null;
}

function hashTransferCode(code) {
  return sha256Hex(code);
}

function identityMatches(target, user) {
  const t = parseIdentifier(target);
  if (!t) return false;
  if (t.kind === 'email') return normalizeEmail(user.email || '') === t.value;
  return normalizePhone(user.phone || '') === t.value;
}

class TransferService {
  /** Test icin bagimlilik enjeksiyonu: { home_cleanup, mqtt_credential_service } (null = yok). */
  static setDependencies(deps = {}) {
    overrides = { ...deps };
  }

  /** 1. Ev sahibi devri baslatir. */
  static async initiateTransfer({ homeId, fromUserId, targetIdentifier }) {
    if (!isUuid(String(homeId || '')) || !isUuid(String(fromUserId || ''))) {
      throw new HttpError(400, 'Geçersiz istek.', 'VALIDATION');
    }
    const target = parseIdentifier(targetIdentifier);
    if (!target) {
      throw new HttpError(400, 'Devir için hedef e-posta adresi veya telefon numarası zorunludur.', 'VALIDATION');
    }

    const meRes = await db.query('SELECT id, email, phone FROM users WHERE id = $1', [fromUserId]);
    const me = meRes.rows[0];
    if (me && identityMatches(target.value, me)) {
      throw new HttpError(400, 'Dairenizi kendinize devredemezsiniz.', 'VALIDATION');
    }

    const code = CODE_PREFIX + generateCode(CODE_LENGTH);
    const expiresAt = new Date(Date.now() + TRANSFER_TTL_MS);

    const row = await db.withTransaction(async (tx) => {
      await tx.query(
        `UPDATE home_transfers SET status = 'CANCELLED'
          WHERE home_id = $1 AND status = 'PENDING'`,
        [homeId]
      );
      const ins = await tx.query(
        `INSERT INTO home_transfers (home_id, from_user_id, target_identifier, transfer_code, code_hash, status, expires_at)
         VALUES ($1, $2, $3, NULL, $4, 'PENDING', $5)
         RETURNING id, home_id, target_identifier, status, expires_at, created_at`,
        [homeId, fromUserId, target.value, hashTransferCode(code), expiresAt]
      );
      return ins.rows[0] || {};
    });

    return {
      id: row.id,
      home_id: row.home_id || homeId,
      transfer_code: code,
      code,
      target_identifier: row.target_identifier || target.value,
      status: row.status || 'PENDING',
      expires_at: row.expires_at || expiresAt,
      qr_payload: `${QR_PREFIX}${code}`,
    };
  }

  /** 2. Hedef kullanici devri kabul eder ve evin TEK sahibi olur. */
  static async acceptTransfer({ transferCode, newUserId }) {
    if (!isUuid(String(newUserId || ''))) throw new HttpError(403, 'Bu işlem için yetkiniz yok.', 'FORBIDDEN');
    const code = normalizeTransferCode(transferCode);
    if (!code) throw new HttpError(400, 'Geçerli bir devir kodu giriniz.', 'VALIDATION');
    const mqtt = optionalModule('mqtt_credential_service');

    const outcome = await db.withTransaction(async (tx) => {
      const tRes = await tx.query(
        `SELECT t.id, t.home_id, t.from_user_id, t.target_identifier, t.status, t.expires_at, t.accepted_by,
                h.name AS home_name, h.address AS home_address
           FROM home_transfers t
           JOIN homes h ON h.id = t.home_id
          WHERE t.code_hash = $1
          FOR UPDATE OF t`,
        [hashTransferCode(code)]
      );
      const transfer = tRes.rows[0];
      // hesap-uyelik-5 (sozlesme C3): yaniti kaybolan kabulun yinelenmesi idempotent basaridir (yalniz devri kabul eden ve
      // hala sahip olan kullanici; yazim / anahtar rotasyonu / MQTT atma YOK). Digerleri icin 410 aynen.
      if (
        transfer &&
        transfer.status === 'COMPLETED' &&
        transfer.accepted_by &&
        String(transfer.accepted_by).toLowerCase() === String(newUserId).toLowerCase()
      ) {
        const own = await tx.query(`SELECT 1 FROM home_users WHERE home_id = $1 AND user_id = $2 AND role = 'owner'`, [
          transfer.home_id,
          newUserId,
        ]);
        if (own.rows.length > 0) return { already: true, transfer };
      }
      if (!transfer || transfer.status !== 'PENDING' || new Date(transfer.expires_at).getTime() <= Date.now()) {
        throw new HttpError(410, GENERIC_INVALID, 'GONE');
      }
      if (transfer.from_user_id === newUserId) {
        throw new HttpError(400, 'Kendi dairenizi kendinize devredemezsiniz.', 'VALIDATION');
      }

      const uRes = await tx.query('SELECT id, email, phone, role FROM users WHERE id = $1', [newUserId]);
      const newUser = uRes.rows[0];
      if (!newUser || !transfer.target_identifier || !identityMatches(transfer.target_identifier, newUser)) {
        // Hedef kimlik SIZDIRILMAZ.
        throw new HttpError(403, 'Bu devir kodu hesabınız için geçerli değil.', 'FORBIDDEN');
      }
      // ev_uyelik-2: personel / yonetici hesabi daire sahibi olamaz (devir PENDING kalir; hicbir yazim yapilmadi).
      if (STAFF_ROLES.includes(newUser.role)) throw new HttpError(403, STAFF_TARGET_MESSAGE, 'FORBIDDEN');

      // Devri baslatan hala ev sahibi mi?
      const ownerRes = await tx.query(
        `SELECT 1 FROM home_users WHERE home_id = $1 AND user_id = $2 AND role = 'owner'`,
        [transfer.home_id, transfer.from_user_id]
      );
      if (ownerRes.rows.length === 0) {
        throw new HttpError(410, GENERIC_INVALID, 'GONE');
      }

      const done = await tx.query(
        `UPDATE home_transfers
            SET status = 'COMPLETED', accepted_by = $1, accepted_at = NOW()
          WHERE id = $2 AND status = 'PENDING' AND expires_at > NOW()
          RETURNING id`,
        [newUserId, transfer.id]
      );
      if (done.rows.length === 0) throw new HttpError(410, GENERIC_INVALID, 'GONE');

      // Eski ailenin bu evdeki uyelikleri kaldirilir; yeni kullanici TEK owner olur.
      await tx.query('DELETE FROM home_users WHERE home_id = $1', [transfer.home_id]);
      await tx.query(
        `INSERT INTO home_users (home_id, user_id, role) VALUES ($1, $2, 'owner')`,
        [transfer.home_id, newUserId]
      );

      // Cihaz/envanter sahipligi
      await tx.query(
        'UPDATE device_inventory SET claimed_by_user_id = $1 WHERE claimed_home_id = $2',
        [newUserId, transfer.home_id]
      );
      await tx.query('UPDATE devices SET claimed_by = $1 WHERE home_id = $2', [newUserId, transfer.home_id]);

      // pano-6: eski aile panonun yerel anahtarini biliyor -> bekleyen yolla dondurulur (tek panolu ev; cihaz satirlari
      // yukarida zaten kilitli)
      const rotationSvc = optionalModule('local_key_rotation');
      const rotation = rotationSvc && typeof rotationSvc.scheduleRotation === 'function'
        ? await rotationSvc.scheduleRotation(transfer.home_id, { tx, reason: 'home_transfer' })
        : null;

      // Yalnizca bu eve ait erisimler: servis PIN/oturum, uygulama MQTT kimlikleri, davet/kural temizligi.
      const service = await serviceTokenService.revokeHomeServiceAccess(transfer.home_id, tx, 'home_transfer');
      // Servis oturumu MQTT kimlikleri (uyelik-6) + evin uygulama kimlikleri: COMMIT sonrasi hepsi atilir.
      let usernames = Array.isArray(service && service.mqtt_usernames) ? service.mqtt_usernames.slice() : [];
      if (mqtt && typeof mqtt.revokeHomeAccess === 'function') {
        const revoked = await mqtt.revokeHomeAccess({ homeId: transfer.home_id, tx });
        usernames = usernames.concat((revoked && revoked.usernames) || []);
      }
      const cleanup = await homeCleanupHook(tx, transfer.home_id);

      return { transfer, usernames, service, cleanup, rotation, rotationSvc };
    });

    if (outcome.already) {
      const a = outcome.transfer;
      return {
        message: `"${a.home_name}" dairesinin sahipliği zaten size devredildi.`,
        home: { id: a.home_id, name: a.home_name, address: a.home_address || null, role: 'owner' },
        already_member: true,
      };
    }

    // Commit SONRASI: ayni surecteki servis oturumu onbellegi ve acik MQTT baglantilari.
    invalidateServiceSessionCache();
    if (outcome.rotationSvc && typeof outcome.rotationSvc.afterCommit === 'function') outcome.rotationSvc.afterCommit(outcome.rotation);
    let kickWarning = null;
    if (mqtt && typeof mqtt.kickUsernames === 'function' && outcome.usernames.length > 0) {
      try {
        const kick = await mqtt.kickUsernames(outcome.usernames);
        if (kick && (kick.skipped || kick.failed > 0)) {
          kickWarning = 'Eski kullanıcıların açık MQTT bağlantıları anında kesilemedi; kimlikleri iptal edildi.';
        }
      } catch (_) {
        kickWarning = 'Eski kullanıcıların açık MQTT bağlantıları anında kesilemedi; kimlikleri iptal edildi.';
      }
    }

    const t = outcome.transfer;
    const result = {
      message: `"${t.home_name}" dairesinin sahipliği size devredildi. Önceki sakinlerin bu evdeki tüm erişimleri kaldırıldı.`,
      home: { id: t.home_id, name: t.home_name, address: t.home_address || null, role: 'owner' },
    };
    if (kickWarning) result.warning = kickWarning;
    return result;
  }

  /** 3. Bekleyen devir (kod GOSTERILMEZ: yalnizca ozeti saklanir). */
  static async getTransferStatus(homeId) {
    const r = await db.query(
      `SELECT id, home_id, target_identifier, status, expires_at, created_at
         FROM home_transfers
        WHERE home_id = $1 AND status = 'PENDING' AND expires_at > NOW()
        ORDER BY created_at DESC
        LIMIT 1`,
      [homeId]
    );
    return { pending_transfer: r.rows[0] || null };
  }

  /** 4. Ev sahibi bekleyen devri iptal eder. */
  static async cancelTransfer(homeId) {
    const r = await db.query(
      `UPDATE home_transfers SET status = 'CANCELLED'
        WHERE home_id = $1 AND status = 'PENDING'
        RETURNING id`,
      [homeId]
    );
    return { message: 'Daire devir işlemi iptal edildi.', cancelled: (r.rows || []).length };
  }
}

module.exports = TransferService;
module.exports.normalizeTransferCode = normalizeTransferCode;
module.exports.hashTransferCode = hashTransferCode;
module.exports.homeCleanupHook = homeCleanupHook;
module.exports.STAFF_TARGET_MESSAGE = STAFF_TARGET_MESSAGE;
