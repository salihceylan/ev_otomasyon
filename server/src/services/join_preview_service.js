'use strict';

// ==============================================================================
// AHBU Akilli Ev - Davet / devir kodu ONIZLEME (WP-B2, sozlesme taramasi bulgusu)
// ==============================================================================
//
// Uc: POST /api/v1/homes/join-preview { code }  (Flutter `previewJoinCode`)
//
// Kodu TUKETMEDEN (hicbir durum degisikligi YOK) neye katilinacagini gosterir: ev adi, sakin sayisi, rol, bitis.
// Kullanici onay ekraninda "yikici" devri (mevcut sakinlerin erisimi kalkar) ayirt edebilsin diye.
//
//  * Kimlik dogrulamali (servis PIN oturumu HARIC); sert hiz siniri (route): kod tahmini/numaralandirma yapilamasin.
//  * Davet kodu (AHBU-XXXXXXXXXX / AHBU-INVITE:...): kodun kendisi kimliktir; ayrinti kodu bilene verilir.
//  * Devir kodu (AHBU-TR-... / AHBU-TRANSFER:...): HEDEFE baglidir -> yalnizca hedef kimlikle eslesen hesap onizleyebilir
//    (aksi 403; devir kabulundeki kuralla ayni). Hedef e-posta/telefon HICBIR yanitta donmez.
//  * Bulunamayan / kullanilmis / suresi dolmus kod AYNI yanittir: 410 GONE (numaralandirma ayrimi yok;
//    istemci 404/405'i "uc yok" sayar, bu yuzden 404 KULLANILMAZ).

const { HttpError, isUuid } = require('../utils/helpers');

const TRANSFER_PREFIXES = Object.freeze(['AHBU-TRANSFER:', 'AHBU-TR-']);
const GONE_MESSAGE = 'Geçersiz veya süresi dolmuş kod.';

function httpError(status, message, code) {
  return new HttpError(status, message, code);
}

class JoinPreviewService {
  /**
   * @param {object} [deps] test icin: { db, invitations, transfers, auth, now }
   */
  constructor(deps = {}) {
    this._deps = deps;
  }

  get db() {
    return this._deps.db || require('../db');
  }
  get invitations() {
    return this._deps.invitations || require('./invitation_service');
  }
  get transfers() {
    return this._deps.transfers || require('./transfer_service');
  }
  get auth() {
    return this._deps.auth || require('./auth_service');
  }
  _now() {
    return this._deps.now ? this._deps.now() : new Date();
  }

  /**
   * @param {{userId:string, code:string}} p
   * @returns {Promise<{kind:'invitation'|'transfer', is_transfer:boolean, home_name:string, resident_count:number,
   *                    role:string, expires_at:any, already_member?:boolean, guest_valid_from?:any, guest_valid_until?:any}>}
   */
  async previewCode({ userId, code } = {}) {
    if (!isUuid(String(userId || ''))) throw httpError(403, 'Bu işlem için yetkiniz yok.', 'FORBIDDEN');
    const raw = typeof code === 'string' || typeof code === 'number' ? String(code).trim() : '';
    if (!raw || raw.length > 64) throw httpError(400, 'Geçerli bir davet veya devir kodu giriniz.', 'VALIDATION');

    const probe = raw.toUpperCase().replace(/\s+/g, '');
    if (TRANSFER_PREFIXES.some((p) => probe.startsWith(p))) return this._previewTransfer(userId, raw);
    return this._previewInvitation(userId, raw);
  }

  async _previewInvitation(userId, raw) {
    const normalized = this.invitations.normalizeInviteCode(raw);
    if (!normalized) throw httpError(400, 'Geçerli bir davet veya devir kodu giriniz.', 'VALIDATION');

    const res = await this.db.query(
      `SELECT i.id, i.home_id, i.role, i.is_used, i.expires_at, i.guest_valid_from, i.guest_valid_until,
              h.name AS home_name,
              (SELECT COUNT(*)::int FROM home_users m WHERE m.home_id = i.home_id AND m.role IN ('owner', 'resident')) AS resident_count,
              EXISTS (SELECT 1 FROM home_users me WHERE me.home_id = i.home_id AND me.user_id = $2) AS already_member
         FROM home_invitations i
         JOIN homes h ON h.id = i.home_id
        WHERE i.code_hash = $1`,
      [this.invitations.hashInviteCode(normalized), userId]
    );
    const inv = res.rows[0];
    const nowMs = this._now().getTime();
    const role = inv ? this.invitations.normalizeRole(inv.role) : null;
    if (
      !inv ||
      inv.is_used ||
      !role ||
      new Date(inv.expires_at).getTime() <= nowMs ||
      (role === 'guest' && (!inv.guest_valid_until || new Date(inv.guest_valid_until).getTime() <= nowMs))
    ) {
      throw httpError(410, GONE_MESSAGE, 'GONE');
    }
    const out = {
      kind: 'invitation',
      is_transfer: false,
      home_name: inv.home_name,
      resident_count: Number(inv.resident_count) || 0,
      role,
      expires_at: inv.expires_at,
      already_member: Boolean(inv.already_member),
    };
    if (role === 'guest') {
      out.guest_valid_from = inv.guest_valid_from || null;
      out.guest_valid_until = inv.guest_valid_until || null;
    }
    return out;
  }

  async _previewTransfer(userId, raw) {
    const normalized = this.transfers.normalizeTransferCode(raw);
    if (!normalized) throw httpError(400, 'Geçerli bir davet veya devir kodu giriniz.', 'VALIDATION');

    const res = await this.db.query(
      `SELECT t.id, t.home_id, t.from_user_id, t.target_identifier, t.status, t.expires_at,
              h.name AS home_name,
              (SELECT COUNT(*)::int FROM home_users m WHERE m.home_id = t.home_id AND m.role IN ('owner', 'resident')) AS resident_count
         FROM home_transfers t
         JOIN homes h ON h.id = t.home_id
        WHERE t.code_hash = $1`,
      [this.transfers.hashTransferCode(normalized)]
    );
    const tr = res.rows[0];
    if (!tr || tr.status !== 'PENDING' || new Date(tr.expires_at).getTime() <= this._now().getTime()) {
      throw httpError(410, GONE_MESSAGE, 'GONE');
    }
    if (tr.from_user_id === userId) {
      throw httpError(400, 'Kendi dairenizi kendinize devredemezsiniz.', 'VALIDATION');
    }

    // Hedef kimlik eslesmesi (kabul ile ayni kural); hedef SIZDIRILMAZ
    const me = await this.db.query('SELECT id, email, phone, role FROM users WHERE id = $1', [userId]);
    const user = me.rows[0];
    if (!user || !this._identityMatches(tr.target_identifier, user)) {
      throw httpError(403, 'Bu devir kodu hesabınız için geçerli değil.', 'FORBIDDEN');
    }
    // ev_uyelik-2: kabulle ayni kural (personel / yonetici hesabi daire sahibi olamaz)
    if (user.role === 'service_user' || user.role === 'super_user') {
      throw httpError(403, 'Servis personeli ve yönetici hesapları daire sahibi olamaz. Devri bir müşteri hesabına yapın.', 'FORBIDDEN');
    }
    return {
      kind: 'transfer',
      is_transfer: true,
      home_name: tr.home_name,
      resident_count: Number(tr.resident_count) || 0,
      role: 'owner',
      expires_at: tr.expires_at,
    };
  }

  _identityMatches(target, user) {
    const auth = this.auth;
    const t = auth.parseIdentifier(target);
    if (!t) return false;
    if (t.kind === 'email') return auth.normalizeEmail(user.email || '') === t.value;
    return auth.normalizePhone(user.phone || '') === t.value;
  }
}

module.exports = new JoinPreviewService();
module.exports.JoinPreviewService = JoinPreviewService;
module.exports.GONE_MESSAGE = GONE_MESSAGE;
