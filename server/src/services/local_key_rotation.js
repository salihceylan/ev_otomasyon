'use strict';

// ==============================================================================
// AHBU Akilli Ev - Yerel anahtar rotasyonu (pano-6)
// ==============================================================================
//
// Erisimi biten kisi panonun yerel anahtarini bilir (LAN dogrudan modu icin okumustur). Erisim bitince anahtar
// BEKLEYEN yolla dondurulur (pano-5 altyapisi; firmware degisikligi YOK):
//   - yeni anahtar devices.local_key_pending_enc'e yazilir; gecerli anahtar pano yeni anahtari alana kadar degismez
//   - kopru uzlastiricisi pano canli oldugunda `set_local_key` iletir ve (firmware 1.3.1) state'teki lk_fp ile
//     dogrulayinca takas eder (device_reconciler); uygulama LAN'da 401 alinca mevcut tazelemeyle yeni anahtari alir
//   - YALNIZ tek panolu ev: cok panolu evde set_local_key ortak ev konusuyla TUM panolara gider (atlanir, bir kez loglanir)
//
// Tetikleyiciler (cagiranin ISLEMI icinde scheduleRotation, COMMIT SONRASI afterCommit -> uzlastirici):
//   devir kabulu ('home_transfer'), owner/resident cikarilmasi ('member_removed'), assign-admin'in uyelik silmesi
//   ('admin_assigned'), kalan evin owner/resident'inin hesap silmesi ('member_deleted'), anahtari okumus servis
//   oturumunun bitisi ('service_session_ended'; service_token_service.sweepEndedSessions). Acil sifirlama kendi
//   anahtarini zaten dondurur.
//
// Anahtar / sifreli deger loglanmaz ve denetim kaydina yazilmaz.

const ROTATION_AUDIT_SQL =
  `INSERT INTO device_audit_logs (event, device_uuid, home_id, actor_user_id, actor_role, ip_address, details)
   VALUES ($1, $2, $3, $4, $5, $6, $7)`;
const MAX_LOGGED_HOMES = 1000;

function shortId(value) {
  const s = String(value || '');
  return s.length > 8 ? s.slice(0, 8) : s;
}

class LocalKeyRotation {
  /** @param {{db?, secretBox?, logger?, requestReconcile?:Function}} [deps] test / DI */
  constructor(deps = {}) {
    this._deps = deps;
    this._loggedMulti = new Set();
  }

  /** Test / DI: bagimliliklari degistirir (verilmeyenler varsayilana doner). */
  setDeps(deps = {}) {
    this._deps = deps;
    this._loggedMulti.clear();
  }

  get db() {
    return this._deps.db || require('../db');
  }

  get secretBox() {
    return this._deps.secretBox || require('../utils/secret_box');
  }

  get logger() {
    return this._deps.logger || console;
  }

  /**
   * Cagiranin islemi icinde bekleyen anahtar yazar (kilit: evin cihaz satirlari id sirasiyla FOR UPDATE).
   * @param {string} homeId
   * @param {{tx?:{query:Function}, reason:string}} opts
   * @returns {Promise<{scheduled:true, topicId:string|null, deviceUuid:string} | {scheduled:false, reason:string}>}
   */
  async scheduleRotation(homeId, { tx = null, reason = 'unspecified' } = {}) {
    const q = tx ? (t, p) => tx.query(t, p) : (t, p) => this.db.query(t, p);
    if (!homeId) return { scheduled: false, reason: 'no_device' };
    const res = await q('SELECT id, device_uuid, local_key_pending_enc FROM devices WHERE home_id = $1 ORDER BY id FOR UPDATE', [homeId]);
    const rows = (res && res.rows) || [];
    if (rows.length === 0) return { scheduled: false, reason: 'no_device' };
    if (rows.length > 1) {
      const key = String(homeId);
      if (!this._loggedMulti.has(key)) {
        if (this._loggedMulti.size >= MAX_LOGGED_HOMES) this._loggedMulti.clear();
        this._loggedMulti.add(key);
        this.logger.warn(
          `[ANAHTAR] Cok panolu evde yerel anahtar rotasyonu atlandi (ev=${shortId(homeId)}, pano=${rows.length}, neden=${reason}); ` +
            'set_local_key ev konusuyla tum panolara gider.'
        );
      }
      return { scheduled: false, reason: 'multi_board' };
    }
    const dev = rows[0];
    if (dev.local_key_pending_enc) return { scheduled: false, reason: 'already_pending' };

    let pendingEnc;
    try {
      pendingEnc = this.secretBox.encrypt(this.secretBox.generateLocalKey());
    } catch (_) {
      // Yapilandirma hatasi (LOCAL_KEY_SECRET): asil islem (uye cikarma vb.) bozulmaz; rotasyon yapilamadi loglanir.
      this.logger.error(`[ANAHTAR] Yerel anahtar rotasyonu icin anahtar uretilemedi (ev=${shortId(homeId)}, neden=${reason})`);
      return { scheduled: false, reason: 'key_error' };
    }
    const up = await q(
      'UPDATE devices SET local_key_pending_enc = $2, local_key_pending_at = NOW() WHERE id = $1 AND local_key_pending_enc IS NULL',
      [dev.id, pendingEnc]
    );
    if (!up || !up.rowCount) return { scheduled: false, reason: 'already_pending' };
    await q(ROTATION_AUDIT_SQL, ['local_key_rotation_scheduled', dev.device_uuid, homeId, null, 'system', null, JSON.stringify({ reason })]);
    const home = await q('SELECT mqtt_username FROM homes WHERE id = $1', [homeId]);
    const topicId = home && home.rows && home.rows[0] ? home.rows[0].mqtt_username || null : null;
    return { scheduled: true, topicId, deviceUuid: dev.device_uuid };
  }

  /** COMMIT SONRASI: planlanan rotasyon(lar) icin evin konusunda uzlastirici istenir. En iyi caba, ASLA firlatmaz. */
  afterCommit(result) {
    const list = Array.isArray(result) ? result : [result];
    for (const r of list) {
      if (r && r.scheduled && r.topicId) this._requestReconcile(r.topicId);
    }
  }

  _requestReconcile(topicId) {
    try {
      if (typeof this._deps.requestReconcile === 'function') {
        this._deps.requestReconcile(topicId);
        return;
      }
      const bridge = require('../mqtt_bridge');
      if (bridge && typeof bridge.requestReconcile === 'function') bridge.requestReconcile(topicId);
    } catch (_) {
      /* en iyi caba: uzlastirici en gec panonun sonraki cevrimici doneminde kontrol eder */
    }
  }
}

module.exports = new LocalKeyRotation();
module.exports.LocalKeyRotation = LocalKeyRotation;
