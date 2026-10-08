'use strict';

// ==============================================================================
// AHBU Akilli Ev - Site, daire, kurulum sablonu ve karta yazim kaydi servisi (Faz 1 / IP-1.3, IP-1.4)
// ==============================================================================
//
// Sozlesme: docs/CONTRACTS.md §3e; sablon bicimi docs/contracts/template/README.md; plan K-S4, K-S6, K-S7.
// Yetki route katmanindadir (requireServiceManager: service_user + super_user; servis PIN oturumu HARIC).
//
// Kurallar
//   * Site ve sablon silme YUMUSAKTIR (deleted_at). Dairesine kart bagli site silinemez (409 SITE_HAS_DEVICES).
//   * Sablon surumleri DEGISMEZ (migration 035 tetikleyicisi). Her kayit meta.version = onceki + 1 olan yeni surum;
//     meta.template_id / version / site_id SUNUCUDA doldurulur (istemcinin degerleri yok sayilir). Ayni govde
//     (kanonik JSON SHA-256'si) yeniden kaydedilirse surum ARTMAZ, mevcut surum doner.
//   * Gecersiz sablon: 422 TEMPLATE_INVALID {error: "<sablon kodu>", path}.
//   * Yerel anahtar okumasi (Ethernet yazimi): her okuma device_audit_logs'a yazilir; denetim kaydi yazilamazsa anahtar
//     VERILMEZ (fail-closed). Anahtar loglanmaz / denetim ayrintisina yazilmaz.

const crypto = require('crypto');
const { httpError } = require('../utils/http_errors');
const { validateTemplate, bodySha256, withMeta, UUID_RE } = require('../utils/template_schema');

const FLAT_STATUSES = Object.freeze(['planned', 'written', 'installed', 'handed_over']);
const WRITE_VIAS = Object.freeze(['usb', 'eth', 'lan']);
const WRITE_RESULTS = Object.freeze(['ok', 'error']);
const MAX_BULK_FLATS = 500;
const DEVICE_UUID_RE = /^AHBU-[A-Z0-9-]{3,32}$/;
const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const PHONE_RE = /^\+?[0-9 ()-]{3,32}$/;
const ERROR_CODE_RE = /^[a-z0-9_.:-]{1,48}$/i;
const PLACEHOLDER_ID = '00000000-0000-4000-8000-000000000000';

const SITE_COLUMNS = `s.id, s.name, s.address, s.city, s.district, s.contact_name, s.contact_phone, s.contact_email,
  s.block_count, s.flat_count, s.notes, s.created_at, s.updated_at`;
const TEMPLATE_COLUMNS = 't.id, t.site_id, t.name, t.flat_type, t.current_version, t.updated_at, t.created_by';

const has = (o, k) => o !== null && typeof o === 'object' && Object.prototype.hasOwnProperty.call(o, k);
const isObj = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);

function bad(message) {
  return httpError(400, message, 'VALIDATION');
}

function uuidOrThrow(value, label) {
  const v = typeof value === 'string' ? value.trim().toLowerCase() : '';
  if (!UUID_RE.test(v)) throw bad(`Geçersiz ${label} kimliği.`);
  return v;
}

function normalizeDeviceUuid(value) {
  if (typeof value !== 'string') return null;
  const v = value.trim().toUpperCase();
  return DEVICE_UUID_RE.test(v) ? v : null;
}

/** Metin alani: undefined (yok), null (temizle) ya da kirpilmis dize; denetim karakteri ve sinir disi -> 400. */
function textField(input, key, label, { max, required = false, re = null }) {
  if (!has(input, key)) {
    if (required) throw bad(`${label} zorunludur.`);
    return undefined;
  }
  const raw = input[key];
  if (raw === null || raw === '') {
    if (required) throw bad(`${label} zorunludur.`);
    return null;
  }
  if (typeof raw !== 'string') throw bad(`${label} metin olmalıdır.`);
  const v = raw.trim();
  if (required && v === '') throw bad(`${label} zorunludur.`);
  if (/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/.test(v)) throw bad(`${label} geçersiz karakter içeriyor.`);
  if (v.length > max) throw bad(`${label} en çok ${max} karakter olabilir.`);
  if (v !== '' && re && !re.test(v)) throw bad(`${label} geçersiz.`);
  return v === '' ? null : v;
}

function intField(input, key, label, lo, hi) {
  if (!has(input, key)) return undefined;
  const raw = input[key];
  if (raw === null || raw === '') return null;
  const n = typeof raw === 'string' && /^\d+$/.test(raw.trim()) ? Number(raw.trim()) : raw;
  if (!Number.isInteger(n) || n < lo || n > hi) throw bad(`${label} ${lo}..${hi} arasında tamsayı olmalıdır.`);
  return n;
}

/** Site govdesi -> kolon degerleri (yalniz verilen alanlar). */
function parseSiteInput(input, { partial }) {
  const b = isObj(input) ? input : {};
  const out = {
    name: textField(b, 'name', 'Site adı', { max: 100, required: !partial }),
    address: textField(b, 'address', 'Adres', { max: 300 }),
    city: textField(b, 'city', 'İl', { max: 60 }),
    district: textField(b, 'district', 'İlçe', { max: 60 }),
    contact_name: textField(b, 'contact_name', 'Sorumlu adı', { max: 100 }),
    contact_phone: textField(b, 'contact_phone', 'Sorumlu telefonu', { max: 32, re: PHONE_RE }),
    contact_email: textField(b, 'contact_email', 'Sorumlu e-postası', { max: 254, re: EMAIL_RE }),
    block_count: intField(b, 'block_count', 'Blok sayısı', 0, 1000),
    flat_count: intField(b, 'flat_count', 'Daire sayısı', 0, 100000),
    notes: textField(b, 'notes', 'Not', { max: 2000 }),
  };
  if (partial && has(b, 'name') && out.name === null) throw bad('Site adı zorunludur.');
  for (const k of Object.keys(out)) if (out[k] === undefined) delete out[k];
  if (partial && Object.keys(out).length === 0) throw bad('Güncellenecek alan yok.');
  if (out.contact_email) out.contact_email = out.contact_email.toLowerCase();
  return out;
}

function blockOrNumber(value, label) {
  const v = typeof value === 'number' && Number.isInteger(value) ? String(value) : typeof value === 'string' ? value.trim() : '';
  if (!v || v.length > 16 || /[\u0000-\u001f\u007f]/.test(v)) throw bad(`${label} 1..16 karakter olmalıdır.`);
  return v;
}

function flatTypeOf(value) {
  if (value === undefined) return undefined;
  if (value === null || value === '') return null;
  if (typeof value !== 'string' || value.trim().length > 16 || /[\u0000-\u001f\u007f]/.test(value)) {
    throw bad('Daire tipi en çok 16 karakter olmalıdır.');
  }
  return value.trim() || null;
}

function siteRow(r) {
  const out = {
    id: r.id,
    name: r.name,
    address: r.address,
    city: r.city,
    district: r.district,
    contact_name: r.contact_name,
    contact_phone: r.contact_phone,
    contact_email: r.contact_email,
    block_count: r.block_count,
    flat_count: r.flat_count,
    notes: r.notes,
    created_at: r.created_at,
    updated_at: r.updated_at,
  };
  if (r.planned !== undefined) {
    out.flat_stats = {
      planned: Number(r.planned) || 0,
      written: Number(r.written) || 0,
      installed: Number(r.installed) || 0,
      handed_over: Number(r.handed_over) || 0,
    };
  }
  return out;
}

function flatRow(r) {
  return {
    id: r.id,
    site_id: r.site_id,
    block: r.block,
    number: r.number,
    flat_type: r.flat_type,
    template_id: r.template_id,
    device_uuid: r.device_uuid,
    status: r.status,
    last_write: r.lw_template_id
      ? { template_id: r.lw_template_id, version: r.lw_version, via: r.lw_via, at: r.lw_at }
      : null,
  };
}

function templateRow(r) {
  return {
    id: r.id,
    site_id: r.site_id,
    name: r.name,
    flat_type: r.flat_type,
    current_version: r.current_version,
    updated_at: r.updated_at,
    created_by: r.created_by,
  };
}

function templateInvalid(result) {
  return httpError(422, `Şablon geçersiz (${result.error}${result.path ? `: ${result.path}` : ''}).`, 'TEMPLATE_INVALID', {
    error: result.error,
    path: result.path,
  });
}

const FLAT_SELECT = `SELECT f.id, f.site_id, f.block, f.number, f.flat_type, f.template_id, f.device_uuid, f.status,
        lw.template_id AS lw_template_id, lw.version AS lw_version, lw.via AS lw_via, lw.created_at AS lw_at
   FROM site_flats f
   LEFT JOIN LATERAL (
     SELECT w.template_id, w.version, w.via, w.created_at
       FROM template_writes w
      WHERE w.flat_id = f.id
      ORDER BY w.created_at DESC, w.id DESC
      LIMIT 1
   ) lw ON TRUE`;

class SiteTemplateService {
  /** @param {{db?:object, secretBox?:object}} [deps] */
  constructor(deps = {}) {
    this._deps = deps;
  }

  get db() {
    return this._deps.db || require('../db');
  }

  get secretBox() {
    return this._deps.secretBox || require('../utils/secret_box');
  }

  // ===========================================================================
  // Siteler
  // ===========================================================================

  async listSites() {
    const res = await this.db.query(
      `SELECT ${SITE_COLUMNS},
              COUNT(f.id) FILTER (WHERE f.status = 'planned') AS planned,
              COUNT(f.id) FILTER (WHERE f.status = 'written') AS written,
              COUNT(f.id) FILTER (WHERE f.status = 'installed') AS installed,
              COUNT(f.id) FILTER (WHERE f.status = 'handed_over') AS handed_over
         FROM sites s
         LEFT JOIN site_flats f ON f.site_id = s.id
        WHERE s.deleted_at IS NULL
        GROUP BY s.id
        ORDER BY s.name ASC, s.created_at ASC`
    );
    return res.rows.map(siteRow);
  }

  async createSite(actor, input) {
    const v = parseSiteInput(input, { partial: false });
    const cols = Object.keys(v);
    const params = cols.map((c) => v[c]);
    params.push((actor && actor.userId) || null);
    const res = await this.db.query(
      `INSERT INTO sites (${cols.join(', ')}, created_by)
       VALUES (${cols.map((_, i) => `$${i + 1}`).join(', ')}, $${params.length})
       RETURNING id, name, address, city, district, contact_name, contact_phone, contact_email, block_count, flat_count,
                 notes, created_at, updated_at`,
      params
    );
    return siteRow(res.rows[0]);
  }

  async getSite(siteId) {
    const id = uuidOrThrow(siteId, 'site');
    const res = await this.db.query(`SELECT ${SITE_COLUMNS} FROM sites s WHERE s.id = $1 AND s.deleted_at IS NULL`, [id]);
    if (res.rows.length === 0) throw httpError(404, 'Site bulunamadı.', 'NOT_FOUND');
    return siteRow(res.rows[0]);
  }

  async updateSite(siteId, input) {
    const id = uuidOrThrow(siteId, 'site');
    const v = parseSiteInput(input, { partial: true });
    const cols = Object.keys(v);
    const params = [id, ...cols.map((c) => v[c])];
    const res = await this.db.query(
      `UPDATE sites
          SET ${cols.map((c, i) => `${c} = $${i + 2}`).join(', ')}, updated_at = CURRENT_TIMESTAMP
        WHERE id = $1 AND deleted_at IS NULL
        RETURNING id, name, address, city, district, contact_name, contact_phone, contact_email, block_count, flat_count,
                  notes, created_at, updated_at`,
      params
    );
    if (res.rows.length === 0) throw httpError(404, 'Site bulunamadı.', 'NOT_FOUND');
    return siteRow(res.rows[0]);
  }

  async deleteSite(siteId) {
    const id = uuidOrThrow(siteId, 'site');
    return this.db.withTransaction(async (tx) => {
      const cur = await tx.query('SELECT id FROM sites WHERE id = $1 AND deleted_at IS NULL FOR UPDATE', [id]);
      if (cur.rows.length === 0) throw httpError(404, 'Site bulunamadı.', 'NOT_FOUND');
      const linked = await tx.query(
        'SELECT COUNT(*)::int AS n FROM site_flats WHERE site_id = $1 AND device_uuid IS NOT NULL',
        [id]
      );
      if (Number(linked.rows[0] && linked.rows[0].n) > 0) {
        throw httpError(409, 'Dairelerine kart bağlı site silinemez. Önce kart bağlantılarını kaldırın.', 'SITE_HAS_DEVICES');
      }
      await tx.query('UPDATE sites SET deleted_at = CURRENT_TIMESTAMP, updated_at = CURRENT_TIMESTAMP WHERE id = $1', [id]);
      return { id, deleted: true };
    });
  }

  /** lock: false | 'share' (FOR SHARE: silmeyi bekletir) | true (FOR UPDATE) */
  async _assertSite(q, siteId, { lock = false } = {}) {
    const clause = lock === 'share' ? ' FOR SHARE' : lock ? ' FOR UPDATE' : '';
    const res = await q(`SELECT id, name FROM sites WHERE id = $1 AND deleted_at IS NULL${clause}`, [siteId]);
    if (res.rows.length === 0) throw httpError(404, 'Site bulunamadı.', 'NOT_FOUND');
    return res.rows[0];
  }

  /** Daireye atanacak sablon: silinmemis ve (genel ya da ayni sitenin) olmali. FOR SHARE: es zamanli silme bekler. */
  async _assertTemplateForSite(q, templateId, siteId) {
    const res = await q('SELECT id, site_id FROM install_templates WHERE id = $1 AND deleted_at IS NULL FOR SHARE', [templateId]);
    const t = res.rows[0];
    if (!t) throw httpError(404, 'Şablon bulunamadı.', 'NOT_FOUND');
    if (t.site_id && t.site_id !== siteId) throw bad('Şablon başka bir siteye ait.');
    return t;
  }

  // ===========================================================================
  // Daireler
  // ===========================================================================

  async listFlats(siteId) {
    const id = uuidOrThrow(siteId, 'site');
    const q = (t, p) => this.db.query(t, p);
    await this._assertSite(q, id);
    const res = await this.db.query(`${FLAT_SELECT} WHERE f.site_id = $1 ORDER BY f.block ASC, length(f.number) ASC, f.number ASC`, [id]);
    return res.rows.map(flatRow);
  }

  async bulkCreateFlats(siteId, input) {
    const id = uuidOrThrow(siteId, 'site');
    const b = isObj(input) ? input : {};
    const block = blockOrNumber(b.block, 'Blok');
    const from = intField(b, 'from', 'Başlangıç numarası', 1, 99999);
    const to = intField(b, 'to', 'Bitiş numarası', 1, 99999);
    if (from === undefined || from === null || to === undefined || to === null) throw bad('Başlangıç ve bitiş numarası zorunludur.');
    if (to < from) throw bad('Bitiş numarası başlangıçtan küçük olamaz.');
    if (to - from + 1 > MAX_BULK_FLATS) throw bad(`Tek seferde en çok ${MAX_BULK_FLATS} daire oluşturulabilir.`);
    const flatType = flatTypeOf(b.flat_type);
    const templateId = b.template_id === undefined || b.template_id === null || b.template_id === '' ? null : uuidOrThrow(b.template_id, 'şablon');

    return this.db.withTransaction(async (tx) => {
      const q = (t, p) => tx.query(t, p);
      await this._assertSite(q, id, { lock: true });
      if (templateId) await this._assertTemplateForSite(q, templateId, id);
      const ins = await tx.query(
        `INSERT INTO site_flats (site_id, block, number, flat_type, template_id)
         SELECT $1::uuid, $2::varchar, g.n::text, $5::varchar, $6::uuid
           FROM generate_series($3::int, $4::int) AS g(n)
         ON CONFLICT (site_id, block, number) DO NOTHING
         RETURNING id, site_id, block, number, flat_type, template_id, device_uuid, status`,
        [id, block, from, to, flatType === undefined ? null : flatType, templateId]
      );
      return { created: ins.rows.map(flatRow), skipped: to - from + 1 - ins.rows.length };
    });
  }

  /**
   * Kilit sirasi (tum yollar ayni): envanter -> site (FOR SHARE) -> sablon (FOR SHARE) -> daire (FOR UPDATE).
   * Site FOR SHARE: deleteSite (FOR UPDATE) ile yarista "silinmis site + karta bagli daire" olusmaz.
   */
  async _lockFlat(tx, siteId, flatId) {
    await this._assertSite((t, p) => tx.query(t, p), siteId, { lock: 'share' });
    const res = await tx.query(
      'SELECT id, site_id, block, number, flat_type, template_id, device_uuid, status FROM site_flats WHERE id = $1 AND site_id = $2 FOR UPDATE',
      [flatId, siteId]
    );
    if (res.rows.length === 0) throw httpError(404, 'Daire bulunamadı.', 'NOT_FOUND');
    return res.rows[0];
  }

  async _flatById(q, flatId) {
    const res = await q(`${FLAT_SELECT} WHERE f.id = $1`, [flatId]);
    return flatRow(res.rows[0]);
  }

  async updateFlat(siteId, flatId, input) {
    const sid = uuidOrThrow(siteId, 'site');
    const fid = uuidOrThrow(flatId, 'daire');
    const b = isObj(input) ? input : {};
    const sets = {};
    if (has(b, 'flat_type')) sets.flat_type = flatTypeOf(b.flat_type);
    if (has(b, 'template_id')) {
      sets.template_id = b.template_id === null || b.template_id === '' ? null : uuidOrThrow(b.template_id, 'şablon');
    }
    if (has(b, 'status')) {
      if (!FLAT_STATUSES.includes(b.status)) throw bad('Daire durumu planned | written | installed | handed_over olmalıdır.');
      sets.status = b.status;
    }
    if (has(b, 'block')) sets.block = blockOrNumber(b.block, 'Blok');
    if (has(b, 'number')) sets.number = blockOrNumber(b.number, 'Daire numarası');
    const cols = Object.keys(sets);
    if (cols.length === 0) throw bad('Güncellenecek alan yok.');

    return this.db.withTransaction(async (tx) => {
      await this._assertSite((t, p) => tx.query(t, p), sid, { lock: 'share' });
      if (sets.template_id) await this._assertTemplateForSite((t, p) => tx.query(t, p), sets.template_id, sid);
      await this._lockFlat(tx, sid, fid);
      try {
        await tx.query(
          `UPDATE site_flats SET ${cols.map((c, i) => `${c} = $${i + 2}`).join(', ')}, updated_at = CURRENT_TIMESTAMP WHERE id = $1`,
          [fid, ...cols.map((c) => sets[c])]
        );
      } catch (err) {
        if (err && err.code === '23505') throw httpError(409, 'Bu blokta aynı numaralı daire zaten var.', 'CONFLICT');
        throw err;
      }
      return this._flatById((t, p) => tx.query(t, p), fid);
    });
  }

  async deleteFlat(siteId, flatId) {
    const sid = uuidOrThrow(siteId, 'site');
    const fid = uuidOrThrow(flatId, 'daire');
    return this.db.withTransaction(async (tx) => {
      const flat = await this._lockFlat(tx, sid, fid);
      if (flat.device_uuid) {
        throw httpError(409, 'Karta bağlı daire silinemez. Önce kart bağlantısını kaldırın.', 'CONFLICT');
      }
      await tx.query('DELETE FROM site_flats WHERE id = $1', [fid]);
      return { id: fid, deleted: true };
    });
  }

  /** PUT /sites/:siteId/flats/:flatId/device  {device_uuid} | {device_uuid:null} */
  async linkFlatDevice(siteId, flatId, deviceUuid) {
    const sid = uuidOrThrow(siteId, 'site');
    const fid = uuidOrThrow(flatId, 'daire');
    let uuid = null;
    if (deviceUuid !== null && deviceUuid !== undefined && deviceUuid !== '') {
      uuid = normalizeDeviceUuid(deviceUuid);
      if (!uuid) throw bad('Geçersiz cihaz kimliği (device_uuid).');
    } else if (deviceUuid === undefined) {
      throw bad('device_uuid alanı zorunludur (ayırmak için null gönderin).');
    }

    return this.db.withTransaction(async (tx) => {
      // Kilit sirasi claim ile ayni: once envanter satiri, sonra site/daire.
      if (uuid) {
        const inv = await tx.query('SELECT device_uuid, status FROM device_inventory WHERE device_uuid = $1 FOR UPDATE', [uuid]);
        if (inv.rows.length === 0) throw httpError(404, 'Bu cihaz envanterde kayıtlı değil.', 'NOT_FOUND');
        const status = inv.rows[0].status;
        if (status !== 'IN_STOCK') {
          throw httpError(409, `Yalnızca stoktaki (IN_STOCK) kart daireye bağlanabilir (mevcut durum: ${status}).`, 'DEVICE_NOT_IN_STOCK');
        }
      }
      await this._lockFlat(tx, sid, fid);
      if (uuid) {
        const other = await tx.query('SELECT id FROM site_flats WHERE device_uuid = $1 AND id <> $2', [uuid, fid]);
        if (other.rows.length > 0) throw httpError(409, 'Bu kart başka bir daireye bağlı.', 'DEVICE_ALREADY_LINKED');
      }
      try {
        await tx.query('UPDATE site_flats SET device_uuid = $2, updated_at = CURRENT_TIMESTAMP WHERE id = $1', [fid, uuid]);
      } catch (err) {
        if (err && err.code === '23505') throw httpError(409, 'Bu kart başka bir daireye bağlı.', 'DEVICE_ALREADY_LINKED');
        throw err;
      }
      return this._flatById((t, p) => tx.query(t, p), fid);
    });
  }

  // ===========================================================================
  // Sablonlar
  // ===========================================================================

  async listTemplates({ siteId, includeGlobal } = {}) {
    const params = [];
    let where = 't.deleted_at IS NULL';
    if (siteId !== undefined && siteId !== null && siteId !== '') {
      params.push(uuidOrThrow(siteId, 'site'));
      where += includeGlobal ? ' AND (t.site_id = $1 OR t.site_id IS NULL)' : ' AND t.site_id = $1';
    }
    const res = await this.db.query(
      `SELECT ${TEMPLATE_COLUMNS} FROM install_templates t WHERE ${where} ORDER BY t.site_id NULLS FIRST, t.name ASC, t.created_at ASC`,
      params
    );
    return res.rows.map(templateRow);
  }

  /** POST /templates {site_id, body} -> sablon + surum 1 */
  async createTemplate(actor, input) {
    const b = isObj(input) ? input : {};
    const siteId = b.site_id === undefined || b.site_id === null || b.site_id === '' ? null : uuidOrThrow(b.site_id, 'site');
    if (!isObj(b.body)) throw bad('Şablon gövdesi (body) zorunludur.');
    const id = crypto.randomUUID();
    const body = withMeta(b.body, { templateId: id, version: 1, siteId });
    const check = validateTemplate(body);
    if (!check.ok) throw templateInvalid(check);
    const sha = bodySha256(body);
    const userId = (actor && actor.userId) || null;

    return this.db.withTransaction(async (tx) => {
      if (siteId) await this._assertSite((t, p) => tx.query(t, p), siteId);
      const ins = await tx.query(
        `INSERT INTO install_templates (id, site_id, name, flat_type, current_version, created_by, updated_by)
         VALUES ($1, $2, $3, $4, 1, $5, $5)
         RETURNING id, site_id, name, flat_type, current_version, updated_at, created_by`,
        [id, siteId, body.meta.name, body.meta.flat_type, userId]
      );
      await tx.query(
        'INSERT INTO install_template_versions (template_id, version, body, sha256, created_by) VALUES ($1, 1, $2::jsonb, $3, $4)',
        [id, JSON.stringify(body), sha, userId]
      );
      return { ...templateRow(ins.rows[0]), body, created: true };
    });
  }

  async getTemplate(templateId) {
    const id = uuidOrThrow(templateId, 'şablon');
    const res = await this.db.query(
      `SELECT ${TEMPLATE_COLUMNS}, v.body
         FROM install_templates t
         JOIN install_template_versions v ON v.template_id = t.id AND v.version = t.current_version
        WHERE t.id = $1 AND t.deleted_at IS NULL`,
      [id]
    );
    if (res.rows.length === 0) throw httpError(404, 'Şablon bulunamadı.', 'NOT_FOUND');
    return { ...templateRow(res.rows[0]), body: res.rows[0].body };
  }

  /** PUT /templates/:id {body} -> yeni surum (ayni govde ise mevcut surum, created:false) */
  async updateTemplate(actor, templateId, input) {
    const id = uuidOrThrow(templateId, 'şablon');
    const b = isObj(input) ? input : {};
    if (!isObj(b.body)) throw bad('Şablon gövdesi (body) zorunludur.');
    const userId = (actor && actor.userId) || null;

    return this.db.withTransaction(async (tx) => {
      // Yalniz sablon satiri kilitlenir; surum AYRI sorguyla okunur. (JOIN + FOR UPDATE OF t: bekleyen islem kilidi
      // alinca t yeniden degerlendirilir ama birlesen surum satiri yenilenmez -> es zamanli kayitta yanlis 404.)
      const cur = await tx.query(
        'SELECT id, site_id, current_version FROM install_templates WHERE id = $1 AND deleted_at IS NULL FOR UPDATE',
        [id]
      );
      const t = cur.rows[0];
      if (!t) throw httpError(404, 'Şablon bulunamadı.', 'NOT_FOUND');
      const curVersion = Number(t.current_version);
      const verRes = await tx.query(
        'SELECT sha256, body FROM install_template_versions WHERE template_id = $1 AND version = $2',
        [id, curVersion]
      );
      if (verRes.rows.length === 0) throw httpError(404, 'Şablon sürümü bulunamadı.', 'NOT_FOUND');
      t.sha256 = verRes.rows[0].sha256;
      t.body = verRes.rows[0].body;
      const same = withMeta(b.body, { templateId: id, version: curVersion, siteId: t.site_id });
      if (bodySha256(same) === String(t.sha256).trim()) {
        const row = await tx.query(`SELECT ${TEMPLATE_COLUMNS} FROM install_templates t WHERE t.id = $1`, [id]);
        return { ...templateRow(row.rows[0]), body: t.body, created: false };
      }
      const next = curVersion + 1;
      const body = withMeta(b.body, { templateId: id, version: next, siteId: t.site_id });
      const check = validateTemplate(body);
      if (!check.ok) throw templateInvalid(check);
      await tx.query(
        'INSERT INTO install_template_versions (template_id, version, body, sha256, created_by) VALUES ($1, $2, $3::jsonb, $4, $5)',
        [id, next, JSON.stringify(body), bodySha256(body), userId]
      );
      const upd = await tx.query(
        `UPDATE install_templates
            SET current_version = $2, name = $3, flat_type = $4, updated_by = $5, updated_at = CURRENT_TIMESTAMP
          WHERE id = $1
          RETURNING id, site_id, name, flat_type, current_version, updated_at, created_by`,
        [id, next, body.meta.name, body.meta.flat_type, userId]
      );
      return { ...templateRow(upd.rows[0]), body, created: true };
    });
  }

  /** Yumusak silme; ayni islemde bu sablonu kullanan daireler ayrilir (template_id NULL; silme engellenmez). */
  async deleteTemplate(templateId) {
    const id = uuidOrThrow(templateId, 'şablon');
    return this.db.withTransaction(async (tx) => {
      const res = await tx.query(
        'UPDATE install_templates SET deleted_at = CURRENT_TIMESTAMP, updated_at = CURRENT_TIMESTAMP WHERE id = $1 AND deleted_at IS NULL RETURNING id',
        [id]
      );
      if (res.rows.length === 0) throw httpError(404, 'Şablon bulunamadı.', 'NOT_FOUND');
      const unlinked = await tx.query(
        'UPDATE site_flats SET template_id = NULL, updated_at = CURRENT_TIMESTAMP WHERE template_id = $1',
        [id]
      );
      return { id, deleted: true, flats_unlinked: unlinked.rowCount || 0 };
    });
  }

  async _assertTemplateExists(id) {
    const res = await this.db.query('SELECT id FROM install_templates WHERE id = $1', [id]);
    if (res.rows.length === 0) throw httpError(404, 'Şablon bulunamadı.', 'NOT_FOUND');
  }

  /** Surum listesi (yumusak silinmis sablonda da okunur: yazim kayitlari icin). */
  async listVersions(templateId) {
    const id = uuidOrThrow(templateId, 'şablon');
    await this._assertTemplateExists(id);
    const res = await this.db.query(
      'SELECT version, sha256, created_at, created_by FROM install_template_versions WHERE template_id = $1 ORDER BY version DESC',
      [id]
    );
    return res.rows.map((r) => ({ version: r.version, sha256: String(r.sha256).trim(), created_at: r.created_at, created_by: r.created_by }));
  }

  async getVersion(templateId, version) {
    const id = uuidOrThrow(templateId, 'şablon');
    const v = typeof version === 'string' && /^\d{1,10}$/.test(version) ? Number(version) : version;
    if (!Number.isInteger(v) || v < 1 || v > 2147483647) throw bad('Geçersiz sürüm numarası.');
    const res = await this.db.query(
      'SELECT template_id, version, body, sha256, created_at, created_by FROM install_template_versions WHERE template_id = $1 AND version = $2',
      [id, v]
    );
    if (res.rows.length === 0) throw httpError(404, 'Şablon sürümü bulunamadı.', 'NOT_FOUND');
    const r = res.rows[0];
    return { template_id: r.template_id, version: r.version, sha256: String(r.sha256).trim(), created_at: r.created_at, created_by: r.created_by, body: r.body };
  }

  /** POST /templates/validate {body}: meta kimligi/surumu yer tutucuyla doldurulur (sunucu kayitta doldurur). */
  validate(input) {
    const b = isObj(input) ? input : {};
    if (!isObj(b.body)) throw bad('Şablon gövdesi (body) zorunludur.');
    const meta = isObj(b.body.meta) ? b.body.meta : {};
    const siteId = typeof meta.site_id === 'string' && UUID_RE.test(meta.site_id) ? meta.site_id : null;
    const check = validateTemplate(withMeta(b.body, { templateId: PLACEHOLDER_ID, version: 1, siteId }));
    if (!check.ok) throw templateInvalid(check);
    return { ok: true };
  }

  // ===========================================================================
  // Karta yazim kaydi
  // ===========================================================================

  /** POST /template-writes {device_uuid, template_id, version, flat_id?, via, result, error_code?} */
  async recordWrite(actor, input) {
    const b = isObj(input) ? input : {};
    const uuid = normalizeDeviceUuid(b.device_uuid);
    if (!uuid) throw bad('Geçersiz cihaz kimliği (device_uuid).');
    const templateId = uuidOrThrow(b.template_id, 'şablon');
    const version = b.version;
    if (!Number.isInteger(version) || version < 1 || version > 2147483647) throw bad('Geçersiz sürüm numarası.');
    if (!WRITE_VIAS.includes(b.via)) throw bad('Yazım yolu (via) usb | eth | lan olmalıdır.');
    if (!WRITE_RESULTS.includes(b.result)) throw bad('Sonuç (result) ok | error olmalıdır.');
    let errorCode = null;
    if (b.error_code !== undefined && b.error_code !== null && b.error_code !== '') {
      if (typeof b.error_code !== 'string' || !ERROR_CODE_RE.test(b.error_code)) throw bad('Hata kodu (error_code) geçersiz.');
      errorCode = b.error_code;
    }
    const flatId = b.flat_id === undefined || b.flat_id === null || b.flat_id === '' ? null : uuidOrThrow(b.flat_id, 'daire');
    const userId = (actor && actor.userId) || null;

    return this.db.withTransaction(async (tx) => {
      const ver = await tx.query('SELECT 1 FROM install_template_versions WHERE template_id = $1 AND version = $2', [templateId, version]);
      if (ver.rows.length === 0) throw httpError(404, 'Şablon sürümü bulunamadı.', 'NOT_FOUND');
      const inv = await tx.query('SELECT device_uuid FROM device_inventory WHERE device_uuid = $1', [uuid]);
      if (inv.rows.length === 0) throw httpError(404, 'Bu cihaz envanterde kayıtlı değil.', 'NOT_FOUND');
      // Kilit sirasi: site (FOR SHARE) -> sablon (FOR SHARE) -> daire (FOR UPDATE); es zamanli silmeler bekler.
      let flatSiteId = null;
      if (flatId) {
        const fs0 = await tx.query('SELECT site_id FROM site_flats WHERE id = $1', [flatId]);
        if (fs0.rows.length === 0) throw httpError(404, 'Daire bulunamadı.', 'NOT_FOUND');
        flatSiteId = fs0.rows[0].site_id;
        const site = await tx.query('SELECT id FROM sites WHERE id = $1 AND deleted_at IS NULL FOR SHARE', [flatSiteId]);
        if (site.rows.length === 0) throw httpError(409, 'Dairenin sitesi silinmiş; yazım kaydedilemez.', 'SITE_DELETED');
      }
      const tpl = await tx.query('SELECT id, site_id, deleted_at FROM install_templates WHERE id = $1 FOR SHARE', [templateId]);
      if (tpl.rows.length === 0) throw httpError(404, 'Şablon bulunamadı.', 'NOT_FOUND');
      if (tpl.rows[0].deleted_at) throw httpError(409, 'Şablon silinmiş; yazım kaydedilemez.', 'TEMPLATE_DELETED');
      if (flatSiteId && tpl.rows[0].site_id && tpl.rows[0].site_id !== flatSiteId) {
        throw httpError(422, 'Şablon başka bir siteye ait; bu daireye yazım kaydedilemez.', 'TEMPLATE_SITE_MISMATCH');
      }
      let flat = null;
      if (flatId) {
        const f = await tx.query('SELECT id, status, device_uuid FROM site_flats WHERE id = $1 FOR UPDATE', [flatId]);
        flat = f.rows[0];
        if (!flat) throw httpError(404, 'Daire bulunamadı.', 'NOT_FOUND');
        if (flat.device_uuid && flat.device_uuid !== uuid) throw httpError(409, 'Daireye başka bir kart bağlı.', 'CONFLICT');
      }
      const ins = await tx.query(
        `INSERT INTO template_writes (device_uuid, template_id, version, flat_id, via, result, error_code, written_by)
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
         RETURNING id, device_uuid, template_id, version, flat_id, via, result, error_code, written_by, created_at`,
        [uuid, templateId, version, flatId, b.via, b.result, errorCode, userId]
      );
      let flatStatus = flat ? flat.status : null;
      if (flat && b.result === 'ok' && flat.status === 'planned') {
        await tx.query("UPDATE site_flats SET status = 'written', updated_at = CURRENT_TIMESTAMP WHERE id = $1", [flatId]);
        flatStatus = 'written';
      }
      const row = ins.rows[0];
      return { ...row, id: Number(row.id), flat_status: flatStatus };
    });
  }

  // ===========================================================================
  // Yerel anahtar (Ethernet yazimi, K-S4)
  // ===========================================================================

  /**
   * GET /admin/inventory/:uuid/local-key -> {local_key}. YALNIZ stoktaki (IN_STOCK) ve hicbir eve bagli olmayan kart
   * (atolye yazimi; super_user + service_user). Kurulu kartin anahtari ev kapsamli uctan alinir
   * (GET /homes/:homeId/devices/:uuid/local-key): aksi 409 DEVICE_NOT_IN_STOCK. Her okuma denetim kaydina (envanter
   * durumu dahil) yazilir; kayit yazilamazsa anahtar VERILMEZ (fail-closed).
   */
  async getInventoryLocalKey(actor, deviceUuid) {
    const uuid = normalizeDeviceUuid(deviceUuid);
    if (!uuid) throw bad('Geçersiz cihaz kimliği.');
    const res = await this.db.query(
      `SELECT di.device_uuid, di.status, di.local_key_enc, d.home_id,
              (d.id IS NOT NULL AND (d.home_id IS NOT NULL OR d.is_claimed IS TRUE)) AS attached
         FROM device_inventory di
         LEFT JOIN devices d ON d.device_uuid = di.device_uuid
        WHERE di.device_uuid = $1`,
      [uuid]
    );
    if (res.rows.length === 0) throw httpError(404, 'Bu cihaz envanterde kayıtlı değil.', 'NOT_FOUND');
    const row = res.rows[0];
    if (row.status !== 'IN_STOCK' || row.attached === true) {
      throw httpError(
        409,
        `Kart stokta değil (durum: ${row.status}${row.attached ? ', bir eve bağlı' : ''}). Kurulu kartın yerel anahtarı ev kapsamlı uçtan alınır: GET /homes/:homeId/devices/:uuid/local-key.`,
        'DEVICE_NOT_IN_STOCK'
      );
    }
    if (!row.local_key_enc) throw httpError(404, 'Bu cihaz için yerel anahtar tanımlı değil.', 'NOT_FOUND');
    const box = this.secretBox;
    if (!box || typeof box.isConfigured !== 'function' || !box.isConfigured()) {
      throw httpError(503, 'Yerel anahtar okunamıyor (sunucu yapılandırması eksik).', 'SERVICE_UNAVAILABLE');
    }
    const localKey = box.decrypt(row.local_key_enc);
    await this.db.query(
      `INSERT INTO device_audit_logs (event, device_uuid, home_id, actor_user_id, actor_role, ip_address, details)
       VALUES ($1, $2, $3, $4, $5, $6, $7)`,
      [
        'inventory_local_key_read',
        uuid,
        row.home_id || null,
        (actor && actor.userId) || null,
        (actor && actor.globalRole) || null,
        (actor && actor.ip) || null,
        JSON.stringify({ purpose: 'template_write', inventory_status: row.status }),
      ]
    );
    return { local_key: localKey };
  }
}

module.exports = new SiteTemplateService();
module.exports.SiteTemplateService = SiteTemplateService;
module.exports.parseSiteInput = parseSiteInput;
module.exports.FLAT_STATUSES = FLAT_STATUSES;
module.exports.WRITE_VIAS = WRITE_VIAS;
