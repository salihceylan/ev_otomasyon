'use strict';

// ==============================================================================
// MQTT kimlik servisi (CONTRACTS §2.2) - paylasilan sabit parolanin yerine:
//
//   Cihaz kimligi    d_{t}              cihaz basina RASTGELE parola; pub ev/{t}/state, ev/{t}/status;
//                                       sub ev/{t}/cmd, ev/{t}/sys
//   Uygulama kimligi a_{t}_{rastgele}   kullanici OTURUMU basina, SURELI; YALNIZCA sub ev/{t}/state, ev/{t}/status
//
//   t = homes.mqtt_username = rastgele, tahmin edilemeyen konu kimligi ('h_' + 16 hex)
//
// Parolalar veritabaninda yalnizca BCRYPT ozeti olarak tutulur (mqtt_credentials, migration 020).
// Parola yalnizca olusturuldugu cagrida (tek sefer) dondurulur; log'a YAZILMAZ.
//
// Disa acik (WP-A bu imzalari cagirir; DEGISTIRMEYIN):
//   revokeUserAccess({ homeId, userId })   uye cikarma / misafir bitisi / hesap silme
//   revokeHomeAccess({ homeId })           daire devri / acil sifirlama
//   revokeAllUserAccess({ userId })        oturumlarin toplu iptali (logout-all, parola degisimi/sifirlama,
//                                          dondurma, rol degisimi) / yonetici kalici silmesi: TUM evler
//
// `tx` verilirse DB islemleri cagiranin transaction'inda yapilir ve ag cagrisi olan "kick"
// (EMQX REST ile baglanti atma) YAPILMAZ: sonuctaki `usernames` ile commit SONRASI
// `kickUsernames(usernames)` cagrilmalidir. `tx` verilmezse servis kendi transaction'ini acar
// ve kick'i kendisi yapar.
// ==============================================================================

const crypto = require('crypto');
const { HttpError } = require('../utils/helpers');

const BCRYPT_COST = 10; // makine kimligi, yuksek entropili rastgele parola: baglanti basina maliyet dusuk tutulur
const USER_CREDENTIAL_MAX_TTL_MS = 12 * 60 * 60 * 1000; // CONTRACTS §1.5: min(12 saat, misafir bitisi)
const MAX_ACTIVE_USER_CREDENTIALS = 10; // kullanici (veya servis oturumu) + ev basina etkin uygulama kimligi ust siniri
const PASSWORD_ALPHABET = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
const PASSWORD_LENGTH = 24; // firmware mqtt_pass[32]: <= 31 karakter. 24 x log2(62) ~ 143 bit
const KICK_TIMEOUT_MS = 4000;
const CLEANUP_INTERVAL_MS = 60 * 1000;

// Konu kimligi ACL konu metnine girer: MQTT joker karakterleri (+ # /) ve $ icermemeli.
const TOPIC_ID_PATTERN = /^[A-Za-z0-9_]{1,64}$/;

function randomPassword(length = PASSWORD_LENGTH) {
  let out = '';
  for (let i = 0; i < length; i++) {
    out += PASSWORD_ALPHABET[crypto.randomInt(0, PASSWORD_ALPHABET.length)];
  }
  return out;
}

/** Yeni ev konu kimligi: 'h_' + 16 onaltilik karakter (64 bit, tahmin edilemez). */
function generateTopicId() {
  return `h_${crypto.randomBytes(8).toString('hex')}`;
}

function isValidTopicId(value) {
  return typeof value === 'string' && TOPIC_ID_PATTERN.test(value);
}

const IPV4_PATTERN = /^\d{1,3}(?:\.\d{1,3}){3}$/;

/** MQTT_PUBLIC_HOST bir IP adresi mi? (firmware TLS sertifikasini ana makine ADIYLA dogrular: IP olmaz) */
function looksLikeIpAddress(host) {
  const h = String(host || '').trim().replace(/^\[|\]$/g, '');
  return IPV4_PATTERN.test(h) || (h.includes(':') && /^[0-9a-fA-F:.]+$/.test(h));
}

class MqttCredentialService {
  /**
   * @param {object} [deps]  test icin: { db, bcrypt, fetch, env, logger, now }
   */
  constructor(deps = {}) {
    this._deps = deps;
    this._cleanupTimer = null;
    this._ipHostWarned = false;
  }

  // --- bagimliliklar (tembel: modul yuklenirken db.js/DATABASE_URL gerektirmez) ---
  get db() {
    return this._deps.db || require('../db');
  }
  get bcrypt() {
    return this._deps.bcrypt || require('bcryptjs');
  }
  get env() {
    return this._deps.env || process.env;
  }
  get logger() {
    return this._deps.logger || console;
  }
  _now() {
    return this._deps.now ? this._deps.now() : new Date();
  }
  _fetch(url, init) {
    const impl = this._deps.fetch || globalThis.fetch;
    if (typeof impl !== 'function') throw new Error('fetch kullanilamiyor');
    return impl(url, { ...init, signal: AbortSignal.timeout(KICK_TIMEOUT_MS) });
  }
  /** tx varsa onun, yoksa havuzun sorgu fonksiyonu. */
  _query(tx) {
    return tx ? (text, params) => tx.query(text, params) : (text, params) => this.db.query(text, params);
  }

  generateTopicId() {
    return generateTopicId();
  }

  isValidTopicId(value) {
    return isValidTopicId(value);
  }

  generatePassword() {
    return randomPassword();
  }

  /** Istemciye bildirilecek genel broker adresi (CONTRACTS §6: MQTT_PUBLIC_HOST/PORT). */
  getBrokerInfo() {
    const host = this.env.MQTT_PUBLIC_HOST;
    const port = Number(this.env.MQTT_PUBLIC_PORT);
    if (!host || !Number.isInteger(port) || port < 1 || port > 65535) {
      this.logger.error('[MQTT-CRED] MQTT_PUBLIC_HOST / MQTT_PUBLIC_PORT tanimli degil veya gecersiz.');
      throw new HttpError(500, 'Sunucu yapılandırma hatası.', 'INTERNAL');
    }
    if (looksLikeIpAddress(host) && !this._ipHostWarned) {
      // Yalnizca uyari (yerel/QA ortami IP kullanabilir); uretimde cihazlar TLS'i ana makine adiyla dogrular.
      this._ipHostWarned = true;
      this.logger.warn(
        '[MQTT-CRED] MQTT_PUBLIC_HOST bir IP adresi; firmware TLS sertifikasini ana makine adiyla dogrular. Uretimde DNS adi kullanin.'
      );
    }
    return { host: String(host), port };
  }

  async _topicIdOf(q, homeId, given) {
    const topic = given || (await this._lookupTopicId(q, homeId));
    if (!isValidTopicId(topic)) {
      this.logger.error('[MQTT-CRED] Gecersiz ev konu kimligi bicimi; kimlik uretilmedi.');
      throw new HttpError(500, 'Sunucu yapılandırma hatası.', 'INTERNAL');
    }
    return topic;
  }

  async _lookupTopicId(q, homeId) {
    const res = await q('SELECT mqtt_username FROM homes WHERE id = $1', [homeId]);
    if (!res.rows || res.rows.length === 0) {
      throw new HttpError(404, 'Daire bulunamadı.', 'NOT_FOUND');
    }
    return res.rows[0].mqtt_username;
  }

  // ===========================================================================
  // Kimlik uretimi
  // ===========================================================================

  /**
   * Cihaz kimligi (d_{t}). Evin mevcut cihaz kimligi VARSA DEGISTIRILIR (rotasyon): eski parola
   * gecersiz olur. Parola yalnizca bu cagrinin donusunde bulunur.
   * @returns {{host,port,username,password,client_id,topic_id,previous_usernames:string[]}}
   */
  async issueDeviceCredential({ homeId, deviceId = null, topicId = null, tx = null }) {
    if (!homeId) throw new TypeError('issueDeviceCredential: homeId zorunludur.');

    if (!tx) {
      const result = await this.db.withTransaction((t) =>
        this.issueDeviceCredential({ homeId, deviceId, topicId, tx: t })
      );
      // Eski cihaz baglantisi (ayni kullanici adi) commit'ten SONRA atilir.
      result.kick = await this.kickUsernames(result.previous_usernames);
      return result;
    }

    const q = this._query(tx);
    // Ayni ev icin es zamanli rotasyonlari SIRALA: kilit olmadan iki islem de eski satiri siler, sonra ikisi de ayni
    // kullanici adini (UNIQUE) eklemeye calisir ve biri 23505 ile duser (gercek PostgreSQL'de gozlendi).
    // Kilit islem sonunda (commit/rollback) birakilir; cagiranin transaction'inda da ayni sirayla alinir.
    await q('SELECT pg_advisory_xact_lock(hashtext($1))', [`mqtt-device-cred:${homeId}`]);
    const topic = await this._topicIdOf(q, homeId, topicId);
    const broker = this.getBrokerInfo();
    const username = `d_${topic}`;
    const password = randomPassword();
    const passwordHash = await this.bcrypt.hash(password, BCRYPT_COST);

    const removed = await q(
      `DELETE FROM mqtt_credentials WHERE home_id = $1 AND kind = 'device' RETURNING username`,
      [homeId]
    );

    const inserted = await q(
      `INSERT INTO mqtt_credentials (username, password_hash, is_superuser, kind, home_id, device_id, client_id, expires_at)
       VALUES ($1, $2, FALSE, 'device', $3, $4, $5, NULL)
       RETURNING id`,
      [username, passwordHash, homeId, deviceId, username]
    );
    const credentialId = inserted.rows[0].id;

    await q(
      `INSERT INTO mqtt_acl (credential_id, username, permission, action, topic)
       VALUES ($1, $2, 'allow', 'publish',   $3),
              ($1, $2, 'allow', 'publish',   $4),
              ($1, $2, 'allow', 'subscribe', $5),
              ($1, $2, 'allow', 'subscribe', $6),
              ($1, $2, 'allow', 'publish',   $7)`,
      [
        credentialId,
        username,
        `ev/${topic}/state`,
        `ev/${topic}/status`,
        `ev/${topic}/cmd`,
        `ev/${topic}/sys`,
        // Guvenlik olaylari (WP-S1, migration 033): pano -> bulut, retain=false; uygulama kimlikleri ABONE OLMAZ.
        `ev/${topic}/event`,
      ]
    );

    return {
      host: broker.host,
      port: broker.port,
      username,
      password,
      client_id: username,
      topic_id: topic,
      previous_usernames: (removed.rows || []).map((r) => r.username),
    };
  }

  /**
   * Uygulama kimligi (a_{t}_{rastgele}): SALT-OKUNUR (yalniz state/status aboneligi), SURELI.
   * `validUntil` (misafir bitisi / servis oturumu bitisi) varsa sure = min(12 saat, validUntil);
   * zaten gecmisse 403 GUEST_EXPIRED. Uyelik/rol/misafir penceresi route'ta requireHomeAccess ile dogrulanir.
   * @returns {{host,port,username,password,client_id,expires_at,topic_id,evicted_usernames:string[]}}
   */
  async issueUserCredential({ homeId, userId = null, validUntil = null, topicId = null, tx = null }) {
    if (!homeId) throw new TypeError('issueUserCredential: homeId zorunludur.');

    if (!tx) {
      const result = await this.db.withTransaction((t) =>
        this.issueUserCredential({ homeId, userId, validUntil, topicId, tx: t })
      );
      result.kick = await this.kickUsernames(result.evicted_usernames);
      return result;
    }

    const q = this._query(tx);
    const now = this._now();
    let expiresAtMs = now.getTime() + USER_CREDENTIAL_MAX_TTL_MS;
    if (validUntil !== null && validUntil !== undefined) {
      const limit = new Date(validUntil).getTime();
      if (!Number.isFinite(limit)) {
        throw new TypeError('issueUserCredential: validUntil gecerli bir tarih olmali.');
      }
      if (limit <= now.getTime()) {
        throw new HttpError(403, 'Erişim süreniz sona ermiş. Ev sahibinden yeni erişim talep ediniz.', 'GUEST_EXPIRED');
      }
      expiresAtMs = Math.min(expiresAtMs, limit);
    }
    const expiresAt = new Date(expiresAtMs);

    const topic = await this._topicIdOf(q, homeId, topicId);
    const broker = this.getBrokerInfo();
    const username = `a_${topic}_${crypto.randomBytes(5).toString('hex')}`;
    const password = randomPassword();
    const passwordHash = await this.bcrypt.hash(password, BCRYPT_COST);

    // Etkin kimlik sayisini sinirla: en yeni (MAX-1) tanesi kalir, fazlasi silinir (+ baglanti atilir).
    const evicted = await q(
      `DELETE FROM mqtt_credentials
        WHERE id IN (
          SELECT id FROM mqtt_credentials
           WHERE home_id = $1 AND kind = 'app' AND user_id IS NOT DISTINCT FROM $2::uuid
           ORDER BY created_at DESC
           OFFSET $3
        )
        RETURNING username`,
      [homeId, userId, MAX_ACTIVE_USER_CREDENTIALS - 1]
    );

    const inserted = await q(
      `INSERT INTO mqtt_credentials (username, password_hash, is_superuser, kind, home_id, user_id, client_id, expires_at)
       VALUES ($1, $2, FALSE, 'app', $3, $4, $5, $6)
       RETURNING id`,
      [username, passwordHash, homeId, userId, username, expiresAt]
    );
    const credentialId = inserted.rows[0].id;

    // YALNIZCA abonelik. Uygulama kimligine hicbir 'publish' satiri yazilmaz (komutlar REST'ten gider).
    await q(
      `INSERT INTO mqtt_acl (credential_id, username, permission, action, topic)
       VALUES ($1, $2, 'allow', 'subscribe', $3),
              ($1, $2, 'allow', 'subscribe', $4)`,
      [credentialId, username, `ev/${topic}/state`, `ev/${topic}/status`]
    );

    return {
      host: broker.host,
      port: broker.port,
      username,
      password,
      client_id: username,
      expires_at: expiresAt.toISOString(),
      topic_id: topic,
      evicted_usernames: (evicted.rows || []).map((r) => r.username),
    };
  }

  // ===========================================================================
  // Iptal (WP-A bunlari cagirir)
  // ===========================================================================

  /**
   * Bir kullanicinin BU evdeki uygulama kimliklerini siler ve baglantilarini atar.
   * (Kullanicinin baska evlerdeki kimlikleri etkilenmez.)
   * @returns {{revoked:number, usernames:string[], kick?:object}}
   */
  async revokeUserAccess({ homeId, userId, tx = null }) {
    if (!homeId || !userId) throw new TypeError('revokeUserAccess: homeId ve userId zorunludur.');
    const q = this._query(tx);
    const res = await q(
      `DELETE FROM mqtt_credentials WHERE home_id = $1 AND user_id = $2 AND kind = 'app' RETURNING username`,
      [homeId, userId]
    );
    return this._finishRevoke(res.rows, tx);
  }

  /**
   * Bir kullanicinin TUM evlerdeki uygulama kimliklerini siler ve baglantilarini atar (paylasilan yardimci:
   * auth_service.revokeAllUserSessions ve admin_user_service). Uyeligi sonradan kalkmis evde kalan kimlik de gider.
   * Cihaz kimligine ve servis (PIN) oturumu kimliklerine (user_id bos) dokunulmaz.
   * @returns {{revoked:number, usernames:string[], kick?:object}}
   */
  async revokeAllUserAccess({ userId, tx = null }) {
    if (!userId) throw new TypeError('revokeAllUserAccess: userId zorunludur.');
    const q = this._query(tx);
    const res = await q(`DELETE FROM mqtt_credentials WHERE user_id = $1 AND kind = 'app' RETURNING username`, [userId]);
    return this._finishRevoke(res.rows, tx);
  }

  /**
   * Evin TUM uygulama kimliklerini siler (daire devri, acil sifirlama, pano degisimi).
   * `includeDevice: true` ise cihaz kimligi de silinir (cihaz stoga donerken).
   * @returns {{revoked:number, usernames:string[], kick?:object}}
   */
  async revokeHomeAccess({ homeId, includeDevice = false, tx = null }) {
    if (!homeId) throw new TypeError('revokeHomeAccess: homeId zorunludur.');
    const q = this._query(tx);
    const res = includeDevice
      ? await q(`DELETE FROM mqtt_credentials WHERE home_id = $1 AND kind IN ('app', 'device') RETURNING username`, [homeId])
      : await q(`DELETE FROM mqtt_credentials WHERE home_id = $1 AND kind = 'app' RETURNING username`, [homeId]);
    return this._finishRevoke(res.rows, tx);
  }

  /** Evin cihaz kimligini siler (cihaz kimligi yenilenmeden iptal edilecekse). */
  async revokeDeviceCredential({ homeId, deviceId = null, tx = null }) {
    if (!homeId) throw new TypeError('revokeDeviceCredential: homeId zorunludur.');
    const q = this._query(tx);
    const res = deviceId
      ? await q(
          `DELETE FROM mqtt_credentials WHERE home_id = $1 AND kind = 'device' AND device_id = $2 RETURNING username`,
          [homeId, deviceId]
        )
      : await q(`DELETE FROM mqtt_credentials WHERE home_id = $1 AND kind = 'device' RETURNING username`, [homeId]);
    return this._finishRevoke(res.rows, tx);
  }

  async _finishRevoke(rows, tx) {
    const usernames = (rows || []).map((r) => r.username);
    const result = { revoked: usernames.length, usernames };
    if (!tx) {
      result.kick = await this.kickUsernames(usernames);
    }
    return result;
  }

  /**
   * Suresi dolan uygulama kimliklerini siler ve baglantilarini atar.
   * (Sifre dogrulamasi yalnizca baglanirken yapilir; suresi dolan acik baglanti bu temizlikle kesilir.)
   */
  async cleanupExpired() {
    const res = await this.db.query(
      `DELETE FROM mqtt_credentials
        WHERE kind = 'app' AND expires_at IS NOT NULL AND expires_at <= NOW()
        RETURNING username`
    );
    const usernames = (res.rows || []).map((r) => r.username);
    const kick = await this.kickUsernames(usernames);
    return { deleted: usernames.length, usernames, kick };
  }

  /** Suresi dolanlari periyodik silen zamanlayici (server.js baslatir, kapanista stopCleanup). */
  startCleanup({ intervalMs = CLEANUP_INTERVAL_MS } = {}) {
    if (this._cleanupTimer) return;
    const tick = async () => {
      try {
        await this.cleanupExpired();
      } catch (err) {
        this.logger.error('[MQTT-CRED] Sure dolan kimlik temizligi hatasi:', err && err.message);
      }
    };
    this._cleanupTimer = setInterval(tick, intervalMs);
    if (typeof this._cleanupTimer.unref === 'function') this._cleanupTimer.unref();
  }

  stopCleanup() {
    if (this._cleanupTimer) {
      clearInterval(this._cleanupTimer);
      this._cleanupTimer = null;
    }
  }

  // ===========================================================================
  // EMQX REST: baglanti atma (kick)
  // ===========================================================================

  /**
   * Kullanici adlarina ait acik baglantilari EMQX REST API ile atar (EMQX_API_URL/KEY/SECRET).
   * Yapilandirma yoksa ATLANIR ve uyari loglanir (DB'den silme tek basina yeni baglantiyi engeller;
   * acik baglanti, broker yeniden dogrulayana kadar surebilir).
   * Hata FIRLATMAZ; sonucu doner (cagiran uyari olarak yuzeye cikarir).
   * @returns {{requested:number, kicked:number, failed:number, skipped:boolean, errors:string[]}}
   */
  async kickUsernames(usernames) {
    const unique = [...new Set((usernames || []).filter((u) => typeof u === 'string' && u))];
    const result = { requested: unique.length, kicked: 0, failed: 0, skipped: false, errors: [] };
    if (unique.length === 0) return result;

    const base = this.env.EMQX_API_URL;
    const key = this.env.EMQX_API_KEY;
    const secret = this.env.EMQX_API_SECRET;
    if (!base || !key || !secret) {
      result.skipped = true;
      this.logger.warn('[MQTT-CRED] EMQX_API_URL/KEY/SECRET tanimli degil; baglanti atma (kick) atlandi.');
      return result;
    }

    const root = `${String(base).replace(/\/+$/, '')}/api/v5`;
    const headers = { Authorization: `Basic ${Buffer.from(`${key}:${secret}`).toString('base64')}` };

    for (const username of unique) {
      try {
        const listRes = await this._fetch(
          `${root}/clients?username=${encodeURIComponent(username)}&limit=100`,
          { method: 'GET', headers }
        );
        if (!listRes.ok) {
          result.failed += 1;
          result.errors.push(`Istemci listesi alinamadi (HTTP ${listRes.status}).`);
          continue;
        }
        const body = await listRes.json();
        const clients = body && Array.isArray(body.data) ? body.data : [];
        for (const client of clients) {
          if (!client || typeof client.clientid !== 'string' || !client.clientid) continue;
          const del = await this._fetch(`${root}/clients/${encodeURIComponent(client.clientid)}`, {
            method: 'DELETE',
            headers,
          });
          if (del.ok || del.status === 404) {
            result.kicked += 1;
          } else {
            result.failed += 1;
            result.errors.push(`Baglanti atilamadi (HTTP ${del.status}).`);
          }
        }
      } catch (err) {
        result.failed += 1;
        result.errors.push('Baglanti atma istegi basarisiz (ag hatasi veya zaman asimi).');
      }
    }

    if (result.failed > 0) {
      this.logger.warn(`[MQTT-CRED] Baglanti atma: ${result.failed} hata (${result.kicked} baglanti atildi).`);
    }
    return result;
  }
}

const instance = new MqttCredentialService();

module.exports = instance;
module.exports.MqttCredentialService = MqttCredentialService;
module.exports.looksLikeIpAddress = looksLikeIpAddress;
module.exports.constants = Object.freeze({
  BCRYPT_COST,
  USER_CREDENTIAL_MAX_TTL_MS,
  MAX_ACTIVE_USER_CREDENTIALS,
  PASSWORD_LENGTH,
});
