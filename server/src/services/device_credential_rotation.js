'use strict';

// ==============================================================================
// AHBU Akilli Ev - Cihaz MQTT kimliginin dondurulmesi (karar 17A, 2026-10-09)
// ==============================================================================
//
// Evin cihaz kimligini (d_{t}) gorebilen / alabilen kisi (owner, servis personeli, servis oturumu: role_matrix
// device_credential; yerel anahtari bilen resident: bootstrap ile) erisimi bitince kimligi kopyalamis olabilir.
// Erisim bitince (cagiranin ISLEMI icinde rotate, COMMIT SONRASI afterCommit):
//   - evin cihaz kimligi GECERSIZ kilinir (expires_at = NOW(); EMQX kimlik sorgusu ve qa_stack suresi dolmus satiri
//     reddeder). Satir silinmez: "dondurme bekliyor" isareti olarak uzlastiriciya (device_reconciler) set_local_key'i
//     YENI kimlikle baglanan panoya kadar ertelemesini soyler.
//   - COMMIT sonrasi ayni kullanici adinin TUM acik baglantilari atilir (pano + kimligi kopyalayan).
//   - Pano art arda "not authorized" (CONNACK 4/5) alinca bootstrap ile yeni kimlik alir (firmware >= 1.3.0,
//     CONTRACTS 3f; device_bootstrap_service -> issueDeviceCredential gecersiz satiri siler, yenisini yazar).
// Atlanir (loglanir, denetim 'device_credential_rotation_skipped'): firmware < 1.3.0 ya da bilinmiyor (bootstrap yok:
//   pano kalici cevrimdisi kalirdi), evde birden fazla pano (ortak d_{t}; dondurme panolari birbirini atardi).
//
// Tetikleyiciler: owner/resident cikarilmasi ('member_removed'), evden ayrilma ('member_left'), devir kabulu
// ('home_transfer'), Home Admin atamasinin uyelik silmesi ('admin_assigned'), kalan evin owner/resident'inin hesap
// silmesi ('member_deleted'), servis oturumu bitisi ('service_session_ended'; service_token_service supurucusu).
//
// Parola / ozet loglanmaz ve denetim kaydina yazilmaz.

const MIN_FW = Object.freeze([1, 3, 0]);
const AUDIT_SQL =
  `INSERT INTO device_audit_logs (event, device_uuid, home_id, actor_user_id, actor_role, ip_address, details)
   VALUES ($1, $2, $3, $4, $5, $6, $7)`;
const SQL = Object.freeze({
  devices: 'SELECT id, device_uuid, firmware_version FROM devices WHERE home_id = $1 ORDER BY id',
  // Evin BITMIS servis oturumlari bu karar icin islenmis sayilir (supurucu ayni oturum icin ikinci kez dondurmez).
  markSessions:
    'UPDATE service_sessions SET device_cred_rotated_at = NOW() WHERE home_id = $1 AND device_cred_rotated_at IS NULL ' +
    'AND (revoked_at IS NOT NULL OR expires_at <= NOW())',
  invalidate:
    "UPDATE mqtt_credentials SET expires_at = NOW() WHERE home_id = $1 AND kind = 'device' " +
    'AND (expires_at IS NULL OR expires_at > NOW()) RETURNING username',
});

function shortId(value) {
  const s = String(value || '');
  return s.length > 8 ? s.slice(0, 8) : s;
}

/** Firmware surumu ("1.3.0" / "v1.3.0" / "1.3.0-rc1") en az 1.3.0 mi? Bilinmeyen / bozuk surum: false. */
function fwAtLeast(version, min = MIN_FW) {
  const m = /^v?(\d+)\.(\d+)\.(\d+)/i.exec(String(version === null || version === undefined ? '' : version).trim());
  if (!m) return false;
  const v = [Number(m[1]), Number(m[2]), Number(m[3])];
  for (let i = 0; i < 3; i += 1) {
    if (v[i] !== min[i]) return v[i] > min[i];
  }
  return true;
}

/** Firmware'in MQTT istemci kimligi (MqttManager.cpp: "ESP32S3_" + WIFI_STA MAC, buyuk harf, ayracsiz). */
function deviceClientId(macAddress) {
  const hex = String(macAddress === null || macAddress === undefined ? '' : macAddress).toUpperCase().replace(/[^0-9A-F]/g, '');
  return hex.length === 12 ? `ESP32S3_${hex}` : null;
}

class DeviceCredentialRotation {
  /** @param {{db?, logger?, credentials?:{kickUsernames:Function}}} [deps] test / DI */
  constructor(deps = {}) {
    this._deps = deps;
  }

  setDeps(deps = {}) {
    this._deps = deps;
  }

  get db() {
    return this._deps.db || require('../db');
  }

  get logger() {
    return this._deps.logger || console;
  }

  get credentials() {
    return this._deps.credentials || require('./mqtt_credential_service');
  }

  /**
   * Cagiranin islemi icinde evin cihaz kimligini gecersiz kilar. Hata FIRLATMAZ (loglar, {rotated:false}); gercek
   * PostgreSQL'de basarisiz ifade islemi zaten bozar ve asil islem geri alinir.
   * @returns {Promise<{rotated:true, usernames:string[], deviceUuid:string, reason:string} | {rotated:false, reason:string}>}
   */
  async rotate(homeId, { tx = null, reason = 'unspecified' } = {}) {
    if (!homeId) return { rotated: false, reason: 'no_device' };
    const q = tx ? (t, p) => tx.query(t, p) : (t, p) => this.db.query(t, p);
    try {
      await q(SQL.markSessions, [homeId]);
      const res = await q(SQL.devices, [homeId]);
      const rows = (res && res.rows) || [];
      if (rows.length === 0) return { rotated: false, reason: 'no_device' };
      if (rows.length > 1) {
        this.logger.warn(
          `[CIHAZ-KIMLIK] Cihaz MQTT kimligi dondurmesi atlandi (ev=${shortId(homeId)}, neden=${reason}, atlama=multi_board, pano=${rows.length})`
        );
        return { rotated: false, reason: 'multi_board' };
      }
      const dev = rows[0];
      if (!fwAtLeast(dev.firmware_version)) {
        const fw = dev.firmware_version ? String(dev.firmware_version).slice(0, 32) : null;
        this.logger.warn(
          `[CIHAZ-KIMLIK] Cihaz MQTT kimligi dondurmesi atlandi (ev=${shortId(homeId)}, neden=${reason}, atlama=old_firmware, fw=${fw || 'bilinmiyor'})`
        );
        await q(AUDIT_SQL, [
          'device_credential_rotation_skipped', dev.device_uuid, homeId, null, 'system', null,
          JSON.stringify({ reason, skip: 'old_firmware', fw }),
        ]);
        return { rotated: false, reason: 'old_firmware' };
      }
      const inv = await q(SQL.invalidate, [homeId]);
      const usernames = ((inv && inv.rows) || []).map((r) => r.username);
      if (usernames.length === 0) return { rotated: false, reason: 'no_credential' };
      await q(AUDIT_SQL, ['device_credential_rotated', dev.device_uuid, homeId, null, 'system', null, JSON.stringify({ reason })]);
      return { rotated: true, usernames, deviceUuid: dev.device_uuid, reason };
    } catch (err) {
      this.logger.error(
        `[CIHAZ-KIMLIK] Cihaz MQTT kimligi dondurulemedi (ev=${shortId(homeId)}, neden=${reason}): ${err && err.code ? err.code : 'hata'}`
      );
      return { rotated: false, reason: 'error' };
    }
  }

  /** COMMIT SONRASI: dondurulen kimligin acik baglantilari atilir. En iyi caba, ASLA firlatmaz. */
  async afterCommit(result) {
    const list = Array.isArray(result) ? result : [result];
    const usernames = [];
    for (const r of list) {
      if (r && r.rotated && Array.isArray(r.usernames)) usernames.push(...r.usernames);
    }
    if (usernames.length === 0) return null;
    try {
      return await this.credentials.kickUsernames(usernames);
    } catch (_) {
      this.logger.warn('[CIHAZ-KIMLIK] Dondurulen cihaz kimliginin baglantisi atilamadi (kimlik yine gecersiz).');
      return null;
    }
  }
}

module.exports = new DeviceCredentialRotation();
module.exports.DeviceCredentialRotation = DeviceCredentialRotation;
module.exports.fwAtLeast = fwAtLeast;
module.exports.deviceClientId = deviceClientId;
module.exports.SQL = SQL;
module.exports.MIN_FW = MIN_FW;
