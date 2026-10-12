'use strict';

// ==============================================================================
// AHBU Akilli Ev - Kapsamlar arasi AKTARIM (yalniz KOK; servis sorumlusu kapsami, migration 045)
// ==============================================================================
//
// Tasarim: docs/superpowers/specs/2026-10-12-servis-kapsamli-super-yetki-design.md §4. Bu servisin HER yontemi yalniz
// kok yonetici (super_user) icin rota katmaninda (requireRoot / allowStaff:false) kapilidir; servis katmaninda da aktor
// kok olmali (derinlemesine savunma). Servis sorumlusu hicbir kaydi baska bir servise ya da koke AKTARAMAZ.
//
//   transferHome      evin servisi (homes.service_owner_id) + evdeki kartlar + servis uyelikleri
//   transferInventory stoktaki kartin sahibi (device_inventory.service_owner_id); kurulu kart evini izler (409)
//   transferSite      sitenin servisi (sites.service_owner_id)
//
// `service_user_id`: hedef servis hesabinin kimligi (rolu service_user, aktif) ya da null (= kok kapsami). Alan
// ZORUNLUDUR (undefined -> 400): yanlislikla koke dusurmeyi onler.
//
// Ev aktariminda eski servisin evdeki uyeligi ve uygulama MQTT kimlikleri iptal edilir (cihaz kimligi + yerel anahtar
// dondurulur: eski servis personeli bunlari okumus olabilir); yeni servis suresiz servis uyeligi alir.

const { HttpError, isUuid } = require('../utils/helpers');
const tenant = require('../utils/tenant_scope');

const AUDIT_SQL =
  `INSERT INTO device_audit_logs (event, device_uuid, home_id, actor_user_id, actor_role, ip_address, details)
   VALUES ($1, $2, $3, $4, $5, $6, $7)`;

function forbidden() {
  return new HttpError(403, 'Kapsamlar arası aktarım yalnızca kök yöneticiye aittir.', 'FORBIDDEN');
}

/** Aktor KOK olmali: gercek bir super_user hesabi (API anahtari, servis sorumlusu ve dahili cagri KABUL EDILMEZ). */
function assertRootActor(actor) {
  if (!actor || !actor.userId) throw forbidden();
  const r = actor.role || actor.globalRole || actor.type;
  if (r !== 'super_user') throw forbidden();
}

class ServiceScopeService {
  /** @param {{db?:object, mqtt?:object, localKeyRotation?:object, deviceCredRotation?:object}} [deps] test / DI */
  constructor(deps = {}) {
    this._deps = deps;
  }

  get db() {
    return this._deps.db || require('../db');
  }

  get mqtt() {
    return this._deps.mqtt || require('./mqtt_credential_service');
  }

  get localKeyRotation() {
    return this._deps.localKeyRotation || require('./local_key_rotation');
  }

  get deviceCredRotation() {
    return this._deps.deviceCredRotation || require('./device_credential_rotation');
  }

  /**
   * Hedef servis: undefined -> 400; null -> null (kok); aksi halde aktif service_user hesabi {id, email, full_name}.
   */
  async _resolveTarget(q, serviceUserId) {
    if (serviceUserId === undefined) {
      throw new HttpError(400, 'service_user_id zorunludur (kök kapsamına almak için null gönderin).', 'VALIDATION');
    }
    if (serviceUserId === null || serviceUserId === '') return null;
    if (typeof serviceUserId !== 'string' || !isUuid(serviceUserId)) {
      throw new HttpError(400, 'Geçersiz servis sorumlusu kimliği (service_user_id).', 'VALIDATION');
    }
    const r = await q('SELECT id, email, full_name, role, is_active, account_status FROM users WHERE id = $1', [serviceUserId.toLowerCase()]);
    const u = r.rows[0];
    if (!u || u.role !== 'service_user') throw new HttpError(404, 'Servis sorumlusu hesabı bulunamadı.', 'NOT_FOUND');
    if (u.is_active === false || (u.account_status && u.account_status !== 'active')) {
      throw new HttpError(409, 'Servis sorumlusu hesabı aktif değil.', 'CONFLICT');
    }
    return { id: u.id, email: u.email, full_name: u.full_name };
  }

  async _audit(q, { event, deviceUuid = null, homeId = null, actor, details }) {
    await q(AUDIT_SQL, [event, deviceUuid, homeId, actor.userId, 'super_user', actor.ip || null, JSON.stringify(details)]);
  }

  /**
   * Evi baska bir servise (ya da koke) aktarir.
   * @returns {{home_id, service_owner_id, previous_service_owner_id, changed, cards_moved, message}}
   */
  async transferHome({ homeId, serviceUserId, actor }) {
    assertRootActor(actor);
    if (typeof homeId !== 'string' || !isUuid(homeId)) throw new HttpError(400, 'Geçersiz daire kimliği (home_id).', 'VALIDATION');
    const hid = homeId.toLowerCase();
    const db = this.db;

    const outcome = await db.withTransaction(async (tx) => {
      const q = (text, params) => tx.query(text, params);
      const homeRes = await q('SELECT id, name, service_owner_id FROM homes WHERE id = $1 FOR UPDATE', [hid]);
      const home = homeRes.rows[0];
      if (!home) throw new HttpError(404, 'Daire bulunamadı.', 'NOT_FOUND');
      const target = await this._resolveTarget(q, serviceUserId);
      const targetId = target ? target.id : null;
      const previous = home.service_owner_id || null;
      if ((previous === null && targetId === null) || (previous && targetId && tenant.sameId(previous, targetId))) {
        return { changed: false, home, previous, targetId, cardsMoved: 0, usernames: [], rotation: null, credRotation: null };
      }

      await q('UPDATE homes SET service_owner_id = $2, updated_at = CURRENT_TIMESTAMP WHERE id = $1', [hid, targetId]);
      const cards = await q('UPDATE device_inventory SET service_owner_id = $2 WHERE claimed_home_id = $1 RETURNING device_uuid', [hid, targetId]);

      // Eski (ve bayat) servis uyelikleri kalkar; yalniz hedef servis suresiz uyelik alir.
      const removed = await q(
        `DELETE FROM home_users
          WHERE home_id = $1 AND role = 'service_user' AND ($2::uuid IS NULL OR user_id <> $2::uuid)
          RETURNING user_id`,
        [hid, targetId]
      );
      const usernames = [];
      for (const m of removed.rows || []) {
        const revoked = await this.mqtt.revokeUserAccess({ homeId: hid, userId: m.user_id, tx });
        if (revoked && Array.isArray(revoked.usernames)) usernames.push(...revoked.usernames);
      }
      if (targetId) {
        await q(
          `INSERT INTO home_users (home_id, user_id, role, installer_expires_at)
           VALUES ($1, $2, 'service_user', NULL)
           ON CONFLICT (home_id, user_id) DO UPDATE SET installer_expires_at = NULL WHERE home_users.role = 'service_user'`,
          [hid, targetId]
        );
      }

      // Eski servis personeli yerel anahtari / cihaz MQTT kimligini okumus olabilir: dondurulur (en iyi caba).
      let rotation = null;
      let credRotation = null;
      if (previous || (removed.rows || []).length > 0) {
        rotation = await this.localKeyRotation.scheduleRotation(hid, { tx, reason: 'service_changed' });
        credRotation = await this.deviceCredRotation.rotate(hid, { tx, reason: 'service_changed' });
      }

      await this._audit(q, {
        event: 'home_service_owner_changed',
        homeId: hid,
        actor,
        details: { from: previous, to: targetId, cards_moved: (cards.rows || []).length },
      });
      return { changed: true, home, previous, targetId, cardsMoved: (cards.rows || []).length, usernames, rotation, credRotation };
    });

    if (outcome.changed) {
      try {
        if (outcome.credRotation) await this.deviceCredRotation.afterCommit(outcome.credRotation);
        if (outcome.rotation) this.localKeyRotation.afterCommit(outcome.rotation);
        if (outcome.usernames.length > 0) await this.mqtt.kickUsernames(outcome.usernames);
      } catch (_) {
        /* en iyi caba: kimlikler zaten iptal / dondurulmustur */
      }
    }
    return {
      home_id: hid,
      service_owner_id: outcome.targetId,
      previous_service_owner_id: outcome.previous,
      changed: outcome.changed,
      cards_moved: outcome.cardsMoved,
      message: outcome.changed
        ? outcome.targetId ? 'Daire yeni servis sorumlusunun kapsamına aktarıldı.' : 'Daire kök yönetici kapsamına alındı.'
        : 'Daire zaten bu kapsamda.',
    };
  }

  /**
   * Stoktaki kartin sahibini degistirir. Kurulu (daireye bagli) kart evinin servisini izler: 409.
   */
  async transferInventory({ deviceUuid, serviceUserId, actor }) {
    assertRootActor(actor);
    const uuid = typeof deviceUuid === 'string' ? deviceUuid.trim().toUpperCase() : '';
    if (!/^AHBU-[A-Z0-9-]{3,32}$/.test(uuid)) throw new HttpError(400, 'Geçersiz cihaz kimliği.', 'VALIDATION');
    const db = this.db;

    const outcome = await db.withTransaction(async (tx) => {
      const q = (text, params) => tx.query(text, params);
      const cur = await q(
        `SELECT di.id, di.status, di.claimed_home_id, di.service_owner_id,
                (SELECT COUNT(*)::int FROM devices d WHERE d.device_uuid = di.device_uuid AND d.home_id IS NOT NULL) AS attached
           FROM device_inventory di
          WHERE di.device_uuid = $1
          FOR UPDATE OF di`,
        [uuid]
      );
      const row = cur.rows[0];
      if (!row) throw new HttpError(404, 'Cihaz bulunamadı.', 'NOT_FOUND');
      const target = await this._resolveTarget(q, serviceUserId);
      const targetId = target ? target.id : null;
      const previous = row.service_owner_id || null;
      if ((previous === null && targetId === null) || (previous && targetId && tenant.sameId(previous, targetId))) {
        return { changed: false, previous, targetId };
      }
      if (row.claimed_home_id || Number(row.attached || 0) > 0 || row.status === 'CLAIMED' || row.status === 'INSTALLED') {
        throw new HttpError(409, 'Kurulu kartın sahibi evinin servisidir; kartı değil daireyi aktarın.', 'CONFLICT');
      }
      await q('UPDATE device_inventory SET service_owner_id = $2, updated_at = CURRENT_TIMESTAMP WHERE id = $1', [row.id, targetId]);
      await this._audit(q, { event: 'inventory_service_owner_changed', deviceUuid: uuid, actor, details: { from: previous, to: targetId } });
      return { changed: true, previous, targetId };
    });

    return {
      device_uuid: uuid,
      service_owner_id: outcome.targetId,
      previous_service_owner_id: outcome.previous,
      changed: outcome.changed,
      message: outcome.changed
        ? outcome.targetId ? 'Kart yeni servis sorumlusunun stoğuna aktarıldı.' : 'Kart kök stoğuna alındı.'
        : 'Kart zaten bu stokta.',
    };
  }

  /** Siteyi baska bir servise (ya da koke) aktarir. */
  async transferSite({ siteId, serviceUserId, actor }) {
    assertRootActor(actor);
    if (typeof siteId !== 'string' || !isUuid(siteId)) throw new HttpError(400, 'Geçersiz site kimliği.', 'VALIDATION');
    const sid = siteId.toLowerCase();
    const db = this.db;

    const outcome = await db.withTransaction(async (tx) => {
      const q = (text, params) => tx.query(text, params);
      const cur = await q('SELECT id, name, service_owner_id FROM sites WHERE id = $1 AND deleted_at IS NULL FOR UPDATE', [sid]);
      const site = cur.rows[0];
      if (!site) throw new HttpError(404, 'Site bulunamadı.', 'NOT_FOUND');
      const target = await this._resolveTarget(q, serviceUserId);
      const targetId = target ? target.id : null;
      const previous = site.service_owner_id || null;
      if ((previous === null && targetId === null) || (previous && targetId && tenant.sameId(previous, targetId))) {
        return { changed: false, previous, targetId };
      }
      await q('UPDATE sites SET service_owner_id = $2, updated_at = CURRENT_TIMESTAMP WHERE id = $1', [sid, targetId]);
      await this._audit(q, { event: 'site_service_owner_changed', actor, details: { site_id: sid, from: previous, to: targetId } });
      return { changed: true, previous, targetId };
    });

    return {
      site_id: sid,
      service_owner_id: outcome.targetId,
      previous_service_owner_id: outcome.previous,
      changed: outcome.changed,
      message: outcome.changed
        ? outcome.targetId ? 'Site yeni servis sorumlusunun kapsamına aktarıldı.' : 'Site kök yönetici kapsamına alındı.'
        : 'Site zaten bu kapsamda.',
    };
  }
}

module.exports = new ServiceScopeService();
module.exports.ServiceScopeService = ServiceScopeService;
