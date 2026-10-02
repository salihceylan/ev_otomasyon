'use strict';

// ==============================================================================
// AHBU Akilli Ev - Cihaz envanteri (WP-A: A11)
// ==============================================================================
//
// Yetki (CONTRACTS §1.4):
//   Envanter olustur / sil / durum : super_user (olustur: ayrica gecerli ADMIN_API_KEY)
//   Envanter listele / tekil sorgu : super_user (tumu), service_user (YALNIZCA kendi stogu:
//                                    sahiplendirdigi veya servis uyesi oldugu evlerdeki cihazlar)
// Durum gecisleri (TRANSITIONS): CLAIMED dogrudan atanamaz (yalnizca sahiplenme akisi);
//   herhangi bir durumdan IN_STOCK'a donus yalnizca super_user ve yalnizca cihaz hicbir daireye
//   bagli DEGILSE (bagliysa acil sifirlama kullanilmalidir - cleanup oradadir).
//   CLAIMED/INSTALLED veya bir daireye bagli cihaz SILINEMEZ.
// Gizli degerler: kurulum PIN'i yalnizca HMAC ozeti (utils/pin.js); local_key AES-256-GCM ile
//   sifreli (utils/secret_box.js, WP-B). Duz local_key ve PIN'li QR baglantisi YALNIZCA
//   olusturma yanitinda BIR KEZ doner.

const db = require('../db');
const { HttpError, generateNumericPin } = require('../utils/helpers');
const { hashPin } = require('../utils/pin');
const { toBoundedInt, MAX_OFFSET } = require('../utils/ints');

const UUID_RE = /^AHBU-[A-Z0-9-]{3,32}$/;
const STATUSES = Object.freeze(['IN_STOCK', 'INSTALLED', 'CLAIMED', 'REVOKED', 'SUSPENDED']);
const TRANSITIONS = Object.freeze({
  IN_STOCK: ['SUSPENDED', 'REVOKED'],
  SUSPENDED: ['IN_STOCK', 'REVOKED', 'CLAIMED'],
  REVOKED: ['IN_STOCK'],
  CLAIMED: ['IN_STOCK', 'SUSPENDED', 'REVOKED'],
  INSTALLED: ['IN_STOCK', 'SUSPENDED', 'REVOKED'],
});
const MAX_PAGE_SIZE = 100;
const DEFAULT_PAGE_SIZE = 50;
const DEFAULT_PUBLIC_URL = 'https://evotomasyon.gudeteknoloji.com.tr';

let secretBoxOverride;
function getSecretBox() {
  if (secretBoxOverride !== undefined) return secretBoxOverride;
  try {
    return require('../utils/secret_box');
  } catch (err) {
    if (err && err.code === 'MODULE_NOT_FOUND' && /secret_box/.test(String(err.message))) return null;
    throw err;
  }
}

function publicUrl() {
  return String(process.env.APP_PUBLIC_URL || DEFAULT_PUBLIC_URL).replace(/\/+$/, '');
}

function normalizeUuid(value) {
  if (typeof value !== 'string') return null;
  const s = value.trim().toUpperCase();
  return UUID_RE.test(s) ? s : null;
}

function normalizeMac(value) {
  if (typeof value !== 'string') return null;
  const hex = value.trim().toUpperCase().replace(/[^0-9A-F]/g, '');
  if (hex.length !== 12) return null;
  return hex.match(/.{2}/g).join(':');
}

function cleanLabel(value, fallback) {
  if (value === undefined || value === null || value === '') return fallback;
  const s = String(value).trim();
  if (!/^[A-Za-z0-9 ._\-/]{1,64}$/.test(s)) {
    throw new HttpError(400, 'Model / parti numarası yalnızca harf, rakam ve . _ - / içerebilir (en fazla 64).', 'VALIDATION');
  }
  return s;
}

function serialOf(row) {
  if (row && row.serial_no !== undefined && row.serial_no !== null) {
    const n = Number.parseInt(row.serial_no, 10);
    return Number.isFinite(n) ? n : row.serial_no;
  }
  return row ? row.serial_no : null;
}

/** Servis personelinin kapsami: sahiplendirdigi veya servis uyesi oldugu evlerdeki cihazlar. */
function scopeClause(actor, params) {
  if (!actor || actor.type !== 'service_user') return '';
  params.push(actor.userId);
  const p = `$${params.length}`;
  return ` AND (di.claimed_by_user_id = ${p}
            OR di.claimed_home_id IN (SELECT home_id FROM home_users WHERE user_id = ${p} AND role = 'service_user'))`;
}

class InventoryService {
  /** Test icin secret_box enjeksiyonu (null = yok). undefined ile sifirlanir. */
  setSecretBox(box) {
    secretBoxOverride = box;
  }

  normalizeMac(mac) {
    return normalizeMac(mac);
  }

  /**
   * Fabrika: yeni panoyu envantere kaydeder (IN_STOCK). local_key uretilir, sifreli saklanir
   * ve yanitta BIR KEZ doner. PIN yalnizca ozetiyle saklanir.
   */
  async registerDevice({ device_uuid, mac_address, pin, model, batch_no } = {}) {
    const cleanUuid = normalizeUuid(device_uuid);
    if (!cleanUuid) throw new HttpError(400, 'Geçersiz cihaz kimliği (AHBU-... biçimi beklenir).', 'VALIDATION');
    const cleanMac = normalizeMac(mac_address);
    if (!cleanMac) throw new HttpError(400, 'Geçersiz MAC adresi.', 'VALIDATION');
    const cleanPin = typeof pin === 'string' || typeof pin === 'number' ? String(pin).trim() : '';
    if (!/^\d{6}$/.test(cleanPin)) throw new HttpError(400, 'Kurulum PIN kodu tam olarak 6 haneli rakam olmalıdır.', 'VALIDATION');
    const cleanModel = cleanLabel(model, 'ESP32-S3-POE-ETH-8DI-8RO');
    const cleanBatch = cleanLabel(batch_no, 'BATCH-2026-01');

    const box = getSecretBox();
    if (!box || typeof box.isConfigured !== 'function' || !box.isConfigured()) {
      const err = new HttpError(503, 'Cihaz anahtarı üretilemiyor (sunucu yapılandırması eksik).', 'SERVICE_UNAVAILABLE');
      err.expose = true;
      throw err;
    }
    const localKey = box.generateLocalKey();
    const localKeyEnc = box.encrypt(localKey);

    const existing = await db.query(
      'SELECT device_uuid, mac_address FROM device_inventory WHERE device_uuid = $1 OR mac_address = $2',
      [cleanUuid, cleanMac]
    );
    if (existing.rows.length > 0) {
      const field = existing.rows[0].device_uuid === cleanUuid ? 'cihaz kimliği' : 'MAC adresi';
      throw new HttpError(409, `Bu ${field} envanterde zaten kayıtlı.`, 'CONFLICT');
    }

    let record;
    try {
      const ins = await db.query(
        `INSERT INTO device_inventory (device_uuid, mac_address, pin_hash, local_key_enc, model, batch_no, status)
         VALUES ($1, $2, $3, $4, $5, $6, 'IN_STOCK')
         RETURNING id, serial_no, device_uuid, mac_address, model, batch_no, status, created_at`,
        [cleanUuid, cleanMac, hashPin(cleanPin), localKeyEnc, cleanModel, cleanBatch]
      );
      record = ins.rows[0];
    } catch (err) {
      if (err && err.code === '23505') throw new HttpError(409, 'Bu cihaz envanterde zaten kayıtlı.', 'CONFLICT');
      throw err;
    }
    if (record) record.serial_no = serialOf(record);

    return {
      device: record,
      local_key: localKey,
      qr_claim_url: `${publicUrl()}/claim?uid=${encodeURIComponent(cleanUuid)}&pin=${cleanPin}`,
    };
  }

  /**
   * Listeleme (sayfali). actor: req.inventoryActor.
   */
  async listInventory({ status, batch_no, search, limit, offset } = {}, actor = { type: 'super_user' }) {
    const params = [];
    let where = ' WHERE 1=1';

    if (status !== undefined && status !== null && String(status).trim() !== '' && String(status).toUpperCase() !== 'ALL') {
      const s = String(status).trim().toUpperCase();
      if (!STATUSES.includes(s)) throw new HttpError(400, 'Geçersiz durum filtresi.', 'VALIDATION');
      params.push(s);
      where += ` AND di.status = $${params.length}`;
    }
    if (batch_no !== undefined && batch_no !== null && String(batch_no).trim() !== '') {
      params.push(String(batch_no).trim().slice(0, 64));
      where += ` AND di.batch_no = $${params.length}`;
    }
    if (typeof search === 'string' && search.trim()) {
      const escaped = search.trim().toLowerCase().slice(0, 64).replace(/[\\%_]/g, (c) => `\\${c}`);
      params.push(`%${escaped}%`);
      const p = `$${params.length}`;
      where += ` AND (LOWER(di.device_uuid) LIKE ${p} OR LOWER(di.mac_address) LIKE ${p}
                 OR LOWER(COALESCE(di.model, '')) LIKE ${p} OR CAST(di.serial_no AS TEXT) LIKE ${p}
                 OR LOWER(COALESCE(h.name, '')) LIKE ${p})`;
    }
    where += scopeClause(actor, params);

    const pageSize = toBoundedInt(limit, { min: 1, max: MAX_PAGE_SIZE, fallback: DEFAULT_PAGE_SIZE, zeroIsFallback: true });
    const pageOffset = toBoundedInt(offset, { min: 0, max: MAX_OFFSET, fallback: 0 });

    const base = `FROM device_inventory di
      LEFT JOIN homes h ON di.claimed_home_id = h.id
      LEFT JOIN users u ON di.claimed_by_user_id = u.id`;

    const countRes = await db.query(`SELECT COUNT(*)::int AS total ${base}${where}`, params);
    const listParams = params.slice();
    listParams.push(pageSize, pageOffset);
    const listRes = await db.query(
      `SELECT di.id, di.serial_no, di.device_uuid, di.mac_address, di.model, di.batch_no, di.status,
              di.failed_attempts, di.locked_until, di.claimed_at, di.created_at, di.updated_at,
              h.name AS claimed_home_name, u.email AS claimed_user_email
         ${base}${where}
        ORDER BY di.serial_no DESC NULLS LAST, di.created_at DESC
        LIMIT $${listParams.length - 1} OFFSET $${listParams.length}`,
      listParams
    );

    const statsParams = [];
    const statsWhere = ` WHERE 1=1${scopeClause(actor, statsParams)}`;
    const statsRes = await db.query(
      `SELECT COUNT(*)::int AS total,
              COUNT(*) FILTER (WHERE di.status = 'IN_STOCK')::int AS in_stock,
              COUNT(*) FILTER (WHERE di.status IN ('CLAIMED', 'INSTALLED'))::int AS claimed,
              COUNT(*) FILTER (WHERE di.status = 'SUSPENDED')::int AS suspended,
              COUNT(*) FILTER (WHERE di.status = 'REVOKED')::int AS revoked
         FROM device_inventory di${statsWhere}`,
      statsParams
    );
    const stats = statsRes.rows[0] || {};

    const items = listRes.rows.map((row) => ({
      ...row,
      serial_no: serialOf(row),
      // PIN'siz baglanti (PIN yalnizca fiziksel etikette).
      qr_claim_url: `${publicUrl()}/claim?uid=${encodeURIComponent(row.device_uuid)}`,
    }));

    return {
      total: Number(countRes.rows[0] ? countRes.rows[0].total : 0),
      count: items.length,
      limit: pageSize,
      offset: pageOffset,
      stats: {
        total: Number(stats.total || 0),
        in_stock: Number(stats.in_stock || 0),
        claimed: Number(stats.claimed || 0),
        suspended: Number(stats.suspended || 0),
        revoked: Number(stats.revoked || 0),
      },
      items,
    };
  }

  async getByUuid(device_uuid, actor = { type: 'super_user' }) {
    const cleanUuid = normalizeUuid(device_uuid);
    if (!cleanUuid) throw new HttpError(400, 'Geçersiz cihaz kimliği.', 'VALIDATION');
    const params = [cleanUuid];
    const r = await db.query(
      `SELECT di.id, di.serial_no, di.device_uuid, di.mac_address, di.model, di.batch_no, di.status,
              di.failed_attempts, di.locked_until, di.claimed_at, di.created_at, di.updated_at
         FROM device_inventory di
        WHERE di.device_uuid = $1${scopeClause(actor, params)}`,
      params
    );
    // Kapsam disi cihazin varligi da sizdirilmaz.
    if (r.rows.length === 0) throw new HttpError(404, 'Cihaz bulunamadı.', 'NOT_FOUND');
    const row = r.rows[0];
    row.serial_no = serialOf(row);
    return row;
  }

  /** Durum degisikligi (yalnizca super_user). */
  async updateStatus(device_uuid, new_status) {
    const cleanUuid = normalizeUuid(device_uuid);
    if (!cleanUuid) throw new HttpError(400, 'Geçersiz cihaz kimliği.', 'VALIDATION');
    const target = typeof new_status === 'string' ? new_status.trim().toUpperCase() : '';
    if (!STATUSES.includes(target)) throw new HttpError(400, 'Geçersiz durum.', 'VALIDATION');

    return db.withTransaction(async (tx) => {
      const cur = await tx.query(
        `SELECT di.id, di.status, di.claimed_home_id,
                (SELECT COUNT(*)::int FROM devices d WHERE d.device_uuid = di.device_uuid AND d.home_id IS NOT NULL) AS attached
           FROM device_inventory di
          WHERE di.device_uuid = $1
          FOR UPDATE OF di`,
        [cleanUuid]
      );
      if (cur.rows.length === 0) throw new HttpError(404, 'Cihaz bulunamadı.', 'NOT_FOUND');
      const row = cur.rows[0];
      if (row.status === target) {
        throw new HttpError(409, 'Cihaz zaten bu durumda.', 'CONFLICT');
      }
      const allowed = TRANSITIONS[row.status] || [];
      if (!allowed.includes(target)) {
        throw new HttpError(409, `Bu durum geçişine izin verilmiyor (${row.status} -> ${target}).`, 'CONFLICT');
      }
      const attached = Boolean(row.claimed_home_id) || Number(row.attached || 0) > 0;
      if (target === 'IN_STOCK' && attached) {
        throw new HttpError(409, 'Cihaz hâlâ bir daireye bağlı. Stoğa almak için acil sıfırlama kullanın.', 'CONFLICT');
      }
      if (target === 'CLAIMED' && !row.claimed_home_id) {
        throw new HttpError(409, 'Daireye bağlı olmayan cihaz sahiplenilmiş duruma alınamaz.', 'CONFLICT');
      }

      const upd = await tx.query(
        `UPDATE device_inventory
            SET status = $1::varchar,
                failed_attempts = CASE WHEN $1::varchar = 'IN_STOCK' THEN 0 ELSE failed_attempts END,
                locked_until = CASE WHEN $1::varchar = 'IN_STOCK' THEN NULL ELSE locked_until END,
                updated_at = CURRENT_TIMESTAMP
          WHERE id = $2
          RETURNING id, serial_no, device_uuid, mac_address, model, batch_no, status, created_at, updated_at`,
        [target, row.id]
      );
      const out = upd.rows[0];
      if (out) out.serial_no = serialOf(out);
      return out;
    });
  }

  /**
   * Etiket yeniden uretimi (yalnizca super_user - route kapisi): kayip/hasarli etiketin yerine YENI kurulum
   * PIN'i + YENI yerel anahtar. Yalnizca IN_STOCK ve hicbir daireye baglanmamis / devreye alinmamis cihaz.
   *  - Eski PIN ozeti uzerine yazilir -> eski etiketteki PIN GECERSIZ olur; PIN deneme sayaci/kilidi sifirlanir.
   *  - Yerel anahtar secret_box ile sifreli saklanir; yetim `devices` satiri (home_id bos) varsa anahtari esitlenir.
   *  - Yanitta PIN ve anahtar BIR KEZ doner (+ PIN'li qr_claim_url); hicbiri loglanmaz / denetim kaydina yazilmaz.
   *  - Denetim: device_audit_logs 'inventory_label_reissued' + device_inventory.label_reissue_count (migration 029).
   *  - Envanter satiri FOR UPDATE ile kilitlenir: es zamanli claim / yeniden uretim siralanir.
   * @param {string} device_uuid
   * @param {{userId?:string, role?:string, ip?:string}} [actor]
   */
  async reissueLabel(device_uuid, actor = {}) {
    const cleanUuid = normalizeUuid(device_uuid);
    if (!cleanUuid) throw new HttpError(400, 'Geçersiz cihaz kimliği.', 'VALIDATION');

    const box = getSecretBox();
    if (!box || typeof box.isConfigured !== 'function' || !box.isConfigured()) {
      const err = new HttpError(503, 'Cihaz anahtarı üretilemiyor (sunucu yapılandırması eksik).', 'SERVICE_UNAVAILABLE');
      err.expose = true;
      throw err;
    }
    const newPin = generateNumericPin(6); // crypto.randomInt
    const pinHash = hashPin(newPin);
    const newKey = box.generateLocalKey();
    const newKeyEnc = box.encrypt(newKey);

    const row = await db.withTransaction(async (tx) => {
      const cur = await tx.query(
        `SELECT di.id, di.status, di.claimed_home_id,
                EXISTS (SELECT 1 FROM devices d
                         WHERE d.device_uuid = di.device_uuid
                           AND (d.home_id IS NOT NULL OR d.is_claimed = TRUE OR d.is_commissioned = TRUE)) AS attached
           FROM device_inventory di
          WHERE di.device_uuid = $1
          FOR UPDATE OF di`,
        [cleanUuid]
      );
      if (cur.rows.length === 0) throw new HttpError(404, 'Cihaz bulunamadı.', 'NOT_FOUND');
      const inv = cur.rows[0];
      if (inv.status !== 'IN_STOCK') {
        throw new HttpError(409, `Yalnızca stoktaki (IN_STOCK) cihazın etiketi yeniden üretilebilir (mevcut durum: ${inv.status}).`, 'CONFLICT');
      }
      if (inv.claimed_home_id || Boolean(inv.attached)) {
        throw new HttpError(409, 'Cihaz bir daireye bağlı veya devreye alınmış; etiketi yeniden üretilemez. Acil sıfırlama kullanın.', 'CONFLICT');
      }

      const upd = await tx.query(
        `UPDATE device_inventory
            SET pin_hash = $1,
                local_key_enc = $2,
                failed_attempts = 0,
                locked_until = NULL,
                label_reissued_at = NOW(),
                label_reissue_count = label_reissue_count + 1,
                updated_at = CURRENT_TIMESTAMP
          WHERE id = $3 AND status = 'IN_STOCK'
          RETURNING id, serial_no, device_uuid, mac_address, model, batch_no, status, label_reissued_at, label_reissue_count`,
        [pinHash, newKeyEnc, inv.id]
      );
      if (upd.rows.length === 0) throw new HttpError(409, 'Cihaz durumu bu sırada değişti. Lütfen tekrar deneyin.', 'CONFLICT');

      // Yetim cihaz kaydi (acil sifirlamadan kalan; home_id bos): sonraki sahiplenmede envanter anahtari esas alinir,
      // yine de iki kayit ayni anahtari tasisin.
      await tx.query(
        'UPDATE devices SET local_key_enc = $1, updated_at = CURRENT_TIMESTAMP WHERE device_uuid = $2 AND home_id IS NULL',
        [newKeyEnc, cleanUuid]
      );

      await tx.query(
        `INSERT INTO device_audit_logs (event, device_uuid, home_id, actor_user_id, actor_role, ip_address, details)
         VALUES ($1, $2, $3, $4, $5, $6, $7)`,
        [
          'inventory_label_reissued',
          cleanUuid,
          null,
          actor.userId || null,
          actor.role || 'super_user',
          actor.ip || null,
          JSON.stringify({ reissue_count: Number(upd.rows[0].label_reissue_count) || 1 }),
        ]
      );
      const out = upd.rows[0];
      out.serial_no = serialOf(out);
      return out;
    });

    return {
      device: row,
      setup_pin: newPin,
      local_key: newKey,
      qr_claim_url: `${publicUrl()}/claim?uid=${encodeURIComponent(cleanUuid)}&pin=${newPin}`,
      message: 'Etiket yeniden üretildi. Eski PIN artık geçersiz; yeni PIN ve yerel anahtar yalnızca şimdi gösterilir.',
    };
  }

  /** Silme (yalnizca super_user). CLAIMED/INSTALLED veya daireye bagli cihaz silinemez. */
  async deleteDevice(device_uuid) {
    const cleanUuid = normalizeUuid(device_uuid);
    if (!cleanUuid) throw new HttpError(400, 'Geçersiz cihaz kimliği.', 'VALIDATION');

    return db.withTransaction(async (tx) => {
      const cur = await tx.query(
        `SELECT di.id, di.status, di.claimed_home_id,
                (SELECT COUNT(*)::int FROM devices d WHERE d.device_uuid = di.device_uuid AND d.home_id IS NOT NULL) AS attached
           FROM device_inventory di
          WHERE di.device_uuid = $1
          FOR UPDATE OF di`,
        [cleanUuid]
      );
      if (cur.rows.length === 0) throw new HttpError(404, 'Cihaz bulunamadı.', 'NOT_FOUND');
      const row = cur.rows[0];
      if (row.status === 'CLAIMED' || row.status === 'INSTALLED') {
        throw new HttpError(409, 'Sahiplenilmiş cihaz silinemez. Önce acil sıfırlama ile stoğa alın.', 'CONFLICT');
      }
      if (row.claimed_home_id || Number(row.attached || 0) > 0) {
        throw new HttpError(409, 'Cihaz hâlâ bir daireye bağlı; silinemez.', 'CONFLICT');
      }
      await tx.query('DELETE FROM devices WHERE device_uuid = $1 AND home_id IS NULL', [cleanUuid]);
      await tx.query('DELETE FROM device_inventory WHERE id = $1', [row.id]);
      return { success: true, message: `Cihaz (${cleanUuid}) envanterden silindi.` };
    });
  }
}

module.exports = new InventoryService();
module.exports.InventoryService = InventoryService;
module.exports.TRANSITIONS = TRANSITIONS;
module.exports.STATUSES = STATUSES;
