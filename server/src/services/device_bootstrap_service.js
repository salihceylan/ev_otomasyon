'use strict';

// ==============================================================================
// AHBU Akilli Ev - Panonun bulut kimligini kendisi almasi (bootstrap)                    [CONTRACTS bolum 3f]
// ==============================================================================
//
// POST /devices/bootstrap (JWT YOK). Pano yerel anahtariyla imzali istekle kendini kanitlar:
//   sig = hex(HMAC-SHA256(local_key, "ahbu-bootstrap/1|" + device_uuid + "|" + ts + "|" + nonce))
//
// Sonuc ({http, body}; govdeler sozlesmedeki gibi HAM, {success,data} zarfi YOK):
//   200 {status:"ok", mqtt:{host,port,username,password}}  sahiplenilmis (bir eve bagli) kart: cihaz MQTT kimligi yeniden
//       uretilir (mqtt-credential ucuyla ayni mantik: MqttCredentialService.issueDeviceCredential + eski baglantiyi atma)
//   202 {status:"pending"}                                  imza dogru ama kart sahiplenilmemis
//   401 DENIED_BODY                                         bilinmeyen kart / bozuk govde / imza yanlis / |now-ts| > 300 /
//                                                           nonce tekrari / askida-iptal kart (NEDEN SOYLENMEZ: tek govde)
//   (429: rota katmani; 5xx: veritabani hatasi vb. - 401'e cevrilmez)
//
// Anahtar adaylari: devices.local_key_enc, device_inventory.local_key_enc, devices.local_key_pending_enc. Tum adaylar
// sabit zamanli karsilastirilir. YALNIZ bekleyen anahtar tuttuysa (pano yeni anahtari almis ama uzlastirici takasi
// yazamamis) bekleyen anahtar asil anahtar yapilir: device_reconciler ile AYNI CAS takasi + envanter + `local_key_rotated`
// denetimi (via:"bootstrap").
//
// Tekrar oynatma: (kart, nonce) device_bootstrap_nonces tablosunda (migration 036; surec yeniden baslasa ve coklu surecte
// de gecerli). Kayit imza dogrulandiktan SONRA ayni islemde yazilir; 600 sn'den eski kayitlar her istekte silinir.
// Kilit sirasi claim / acil sifirlama ile ayni: envanter satiri -> cihaz satiri.
// Gizli degerler (anahtar, parola, imza) gunluge ve denetim kaydina YAZILMAZ.

const crypto = require('crypto');

const SIG_PREFIX = 'ahbu-bootstrap/1';
const MAX_SKEW_S = 300;
const NONCE_TTL_S = 600;
const DEVICE_UUID_RE = /^AHBU-[A-Z0-9-]{3,32}$/;
const HEX32_RE = /^[0-9a-f]{32}$/;
const HEX64_RE = /^[0-9a-f]{64}$/;
const FW_RE = /^[0-9A-Za-z][0-9A-Za-z._+-]{0,31}$/;
const DENIED_BODY = Object.freeze({ success: false, code: 'BOOTSTRAP_DENIED', message: 'Cihaz kimliği doğrulanamadı.' });
const DUMMY_KEY = crypto.randomBytes(32).toString('hex'); // bilinmeyen kartta da ayni miktarda HMAC isi

function bootstrapMessage(uuid, ts, nonce) {
  return `${SIG_PREFIX}|${uuid}|${ts}|${nonce}`;
}

function signBootstrap(localKey, uuid, ts, nonce) {
  return crypto.createHmac('sha256', String(localKey)).update(bootstrapMessage(uuid, ts, nonce), 'utf8').digest('hex');
}

/** Sabit zamanli hex karsilastirma (uzunluk farkinda false). */
function sigMatches(given, expected) {
  if (typeof given !== 'string' || typeof expected !== 'string') return false;
  const a = Buffer.from(given.toLowerCase(), 'utf8');
  const b = Buffer.from(expected.toLowerCase(), 'utf8');
  if (a.length !== b.length) return false;
  return crypto.timingSafeEqual(a, b);
}

/** @returns {null | {uuid, ts, nonce, sig}} */
function parseBootstrapBody(body) {
  if (!body || typeof body !== 'object' || Array.isArray(body)) return null;
  const uuid = typeof body.device_uuid === 'string' ? body.device_uuid.trim().toUpperCase() : '';
  if (!DEVICE_UUID_RE.test(uuid)) return null;
  const ts = body.ts;
  if (typeof ts !== 'number' || !Number.isInteger(ts) || ts < 0 || ts > 0xffffffff) return null;
  const nonce = typeof body.nonce === 'string' ? body.nonce.toLowerCase() : '';
  if (!HEX32_RE.test(nonce)) return null;
  const sig = typeof body.sig === 'string' ? body.sig.toLowerCase() : '';
  if (!HEX64_RE.test(sig)) return null;
  if (body.fw !== undefined && body.fw !== null && (typeof body.fw !== 'string' || !FW_RE.test(body.fw))) return null;
  return { uuid, ts, nonce, sig };
}

class DeviceBootstrapService {
  /** @param {{db?, credentials?, secretBox?, logger?, now?}} [deps] */
  constructor(deps = {}) {
    this._deps = deps;
  }

  get db() {
    return this._deps.db || require('../db');
  }

  get credentials() {
    return this._deps.credentials || require('./mqtt_credential_service');
  }

  get secretBox() {
    return this._deps.secretBox || require('../utils/secret_box');
  }

  get logger() {
    return this._deps.logger || console;
  }

  _nowMs() {
    return typeof this._deps.now === 'function' ? Number(this._deps.now()) : Date.now();
  }

  _decrypt(enc) {
    if (!enc) return null;
    try {
      return this.secretBox.decrypt(enc);
    } catch (_) {
      return null; // bozuk / eski anahtarla sifrelenmis kayit: aday degil (ayrinti gunluge yazilmaz)
    }
  }

  /**
   * @param {{body:any, ip?:string|null}} args
   * @returns {Promise<{http:number, body:object}>}
   */
  async bootstrap({ body, ip = null }) {
    const denied = { http: 401, body: DENIED_BODY };
    const req = parseBootstrapBody(body);
    if (!req) return denied;
    const nowMs = this._nowMs();
    if (Math.abs(Math.floor(nowMs / 1000) - req.ts) > MAX_SKEW_S) return denied;

    const outcome = await this.db.withTransaction(async (tx) => {
      const invRes = await tx.query(
        'SELECT id, status, local_key_enc FROM device_inventory WHERE device_uuid = $1 FOR UPDATE',
        [req.uuid]
      );
      const devRes = await tx.query(
        `SELECT id, home_id, is_claimed, local_key_enc, local_key_pending_enc
           FROM devices WHERE device_uuid = $1 FOR UPDATE`,
        [req.uuid]
      );
      const inv = invRes.rows[0] || null;
      const dev = devRes.rows[0] || null;

      // Sabit zamanli dogrulama: tum adaylar hesaplanir (bilinmeyen kartta sahte anahtarla ayni is).
      const candidates = [
        { enc: dev && dev.local_key_enc, pending: false },
        { enc: inv && inv.local_key_enc, pending: false },
        { enc: dev && dev.local_key_pending_enc, pending: true },
      ];
      let currentOk = false;
      let pendingOk = false;
      for (const c of candidates) {
        const key = this._decrypt(c.enc);
        const ok = sigMatches(req.sig, signBootstrap(key === null ? DUMMY_KEY : key, req.uuid, req.ts, req.nonce)) && key !== null;
        if (ok && c.pending) pendingOk = true;
        else if (ok) currentOk = true;
      }
      if (!inv && !dev) return { denied: true };
      if (inv && (inv.status === 'SUSPENDED' || inv.status === 'REVOKED')) return { denied: true };
      if (!currentOk && !pendingOk) return { denied: true };

      // Tekrar oynatma: dogrulanmis istegin (kart, nonce) ikilisi; eski kayitlar temizlenir.
      const now = new Date(nowMs);
      await tx.query('DELETE FROM device_bootstrap_nonces WHERE device_uuid = $1 AND created_at < $2', [
        req.uuid,
        new Date(nowMs - NONCE_TTL_S * 1000),
      ]);
      const ins = await tx.query(
        `INSERT INTO device_bootstrap_nonces (device_uuid, nonce, created_at) VALUES ($1, $2, $3)
         ON CONFLICT (device_uuid, nonce) DO NOTHING`,
        [req.uuid, req.nonce, now]
      );
      if (!ins || !ins.rowCount) return { denied: true };

      // Yalniz bekleyen anahtar tuttu: asil anahtar yap (uzlastirici ile ayni CAS takasi; envanter ayni degere).
      let promoted = false;
      if (pendingOk && !currentOk && dev) {
        const sw = await tx.query(
          `UPDATE devices
              SET local_key_enc = local_key_pending_enc, local_key_pending_enc = NULL, local_key_pending_at = NULL
            WHERE id = $1 AND local_key_pending_enc = $2`,
          [dev.id, dev.local_key_pending_enc]
        );
        if (sw && sw.rowCount) {
          await tx.query('UPDATE device_inventory SET local_key_enc = $2, updated_at = CURRENT_TIMESTAMP WHERE device_uuid = $1', [
            req.uuid,
            dev.local_key_pending_enc,
          ]);
          await tx.query(
            `INSERT INTO device_audit_logs (event, device_uuid, home_id, actor_user_id, actor_role, ip_address, details)
             VALUES ('local_key_rotated', $1, $2, NULL, 'system', NULL, $3::jsonb)`,
            [req.uuid, dev.home_id || null, JSON.stringify({ via: 'bootstrap' })]
          );
          promoted = true;
        }
      }

      const claimed = Boolean(dev && dev.home_id);
      let credential = null;
      if (claimed) {
        credential = await this.credentials.issueDeviceCredential({ homeId: dev.home_id, deviceId: dev.id, tx });
      }
      await tx.query(
        `INSERT INTO device_audit_logs (event, device_uuid, home_id, actor_user_id, actor_role, ip_address, details)
         VALUES ('device_bootstrap', $1, $2, NULL, 'device', $3, $4::jsonb)`,
        [
          req.uuid,
          claimed ? dev.home_id : null,
          ip || null,
          JSON.stringify({ result: claimed ? 'ok' : 'pending', pending_key_promoted: promoted, fw: typeof body.fw === 'string' ? body.fw : null }),
        ]
      );
      return { denied: false, claimed, credential };
    });

    if (outcome.denied) return denied;
    if (!outcome.claimed) return { http: 202, body: { status: 'pending' } };

    // COMMIT sonrasi: eski cihaz baglantisi (ayni kullanici adi) atilir; hata yaniti bozmaz.
    try {
      if (outcome.credential.previous_usernames && outcome.credential.previous_usernames.length > 0) {
        await this.credentials.kickUsernames(outcome.credential.previous_usernames);
      }
    } catch (_) {
      this.logger.warn(`[BOOTSTRAP] Eski cihaz baglantisi atilamadi [${req.uuid}]`);
    }
    const c = outcome.credential;
    return { http: 200, body: { status: 'ok', mqtt: { host: c.host, port: c.port, username: c.username, password: c.password } } };
  }
}

module.exports = new DeviceBootstrapService();
module.exports.DeviceBootstrapService = DeviceBootstrapService;
module.exports.DENIED_BODY = DENIED_BODY;
module.exports.bootstrapMessage = bootstrapMessage;
module.exports.signBootstrap = signBootstrap;
module.exports.sigMatches = sigMatches;
module.exports.parseBootstrapBody = parseBootstrapBody;
module.exports.MAX_SKEW_S = MAX_SKEW_S;
