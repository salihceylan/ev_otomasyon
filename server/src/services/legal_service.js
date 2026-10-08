'use strict';

// ==============================================================================
// AHBU Akilli Ev - Yasal metinler: belge yukleyici + kabul kaydi (migration 039)
// ==============================================================================
//
// Belgeler server/legal/<slug>.md (bicim: utils/legal_markdown). YALNIZ bilinen iki belge okunur:
//   terms   -> kullanici-sozlesmesi.md  Kullanici Sozlesmesi ve Son Kullanici Lisans Kosullari; onay ISTER
//   privacy -> gizlilik-politikasi.md   Gizlilik Politikasi ve KVKK Aydinlatma Metni; onay ISTEMEZ (KVKK: aydinlatma
//              bilgilendirmedir, rizaya baglanmaz). On bilgide id / slug dosyayla ya da requires_acceptance bu kuralla
//              uyusmazsa belge REDDEDILIR.
// Dizindeki baska dosyalar okunmaz. Dizin kurucu secenegiyle verilir (testler kendi belgelerini kullanir; ortam
// degiskeni YOK). Belgeler ilk kullanimda bir kez yuklenir (server.start() acilista load() cagirir ki sorunlar hemen
// loglansin); degisiklik yeniden baslatmayla (dagitim) yururluge girer.
// Eksik / bos dizin ya da gecersiz belge sunucuyu DURDURMAZ ve ASLA firlatmaz: o belge yokmus gibi davranilir (liste bos,
// sayfa 404, legal.needs_acceptance false). Log yalniz dosya adi + neden icerir (belge govdesi LOGA YAZILMAZ).
// Bloklar (GET /legal/:id) ve HTML sayfa ayni govdeden uretilir; govde basliga esit bir "# " ile basliyorsa o ilk blok
// ikisinde de dusurulur (baslik on bilgiden ayrica gosterilir, iki kez gorunmesin).
//
// Kabul (POST /legal/accept ve kayitta accept_terms_version): legal_acceptances satiri ile users.terms_version /
// terms_accepted_at AYNI transaction'da yazilir (recordAcceptance tx ister; terms_accepted_at = satirin accepted_at'i,
// ikisi de transaction'in now() degeri). Ayni kullanici + belgenin SON kabulu ayni surumse yeni satir YAZILMAZ
// (idempotent; mevcut kabul doner). Guncel olmayan surum 409 LEGAL_VERSION_MISMATCH (+ data.current_version).
// Kullanici satiri FOR UPDATE ile kilitlenir: ayni kullanicinin eszamanli iki kabulu cift satir uretmez.

const fs = require('fs');
const path = require('path');
const { HttpError, isUuid } = require('../utils/helpers');
const {
  LegalDocumentError,
  parseLegalDocument,
  findUnsupportedSyntax,
  withoutTitleHeading,
  renderDocumentPage,
  renderNotFoundPage,
} = require('../utils/legal_markdown');

const DEFAULT_LEGAL_DIR = path.join(__dirname, '..', '..', 'legal');
const KNOWN_DOCUMENTS = Object.freeze([
  Object.freeze({ id: 'terms', slug: 'kullanici-sozlesmesi', requiresAcceptance: true }),
  Object.freeze({ id: 'privacy', slug: 'gizlilik-politikasi', requiresAcceptance: false }),
]);
// needs_acceptance personelde hic true olmaz (global rol).
const STAFF_ROLES = new Set(['super_user', 'service_user']);
const MAX_VERSION = 2147483647; // INTEGER
const USER_AGENT_MAX = 255;
const IP_MAX = 64;
const NOT_FOUND_HTML = renderNotFoundPage();
const MISMATCH_MESSAGE = 'Kullanıcı Sözleşmesi güncellendi. Lütfen güncel metni okuyup yeniden onaylayın.';

function legalError(status, message, code, extra) {
  const err = new HttpError(status, message, code);
  if (extra) err.extra = extra; // error_handler 4xx govdesine ekler
  return err;
}

/** 409 LEGAL_VERSION_MISMATCH; current: guncel surum (sozlesme yuklu degilse null). */
function versionMismatch(current) {
  return legalError(409, MISMATCH_MESSAGE, 'LEGAL_VERSION_MISMATCH', { data: { current_version: current } });
}

/**
 * Istemcinin gonderdigi surum: pozitif tamsayi ya da rakam dizgesi ("2"). `optional` ise bos (undefined/null/'')
 * null doner; aksi her deger 400 VALIDATION.
 */
function parseVersionInput(value, { optional = false } = {}) {
  if (value === undefined || value === null || value === '') {
    if (optional) return null;
    throw legalError(400, 'Belge sürümü zorunludur.', 'VALIDATION');
  }
  let n = NaN;
  if (typeof value === 'number') n = value;
  else if (typeof value === 'string' && /^\s*\d{1,10}\s*$/.test(value)) n = Number(value.trim());
  if (!Number.isInteger(n) || n < 1 || n > MAX_VERSION) throw legalError(400, 'Belge sürümü geçersiz.', 'VALIDATION');
  return n;
}

function positiveIntOrNull(value) {
  let n = NaN;
  if (typeof value === 'number') n = value;
  else if (typeof value === 'string' && /^\d{1,10}$/.test(value)) n = Number(value);
  return Number.isInteger(n) && n >= 1 && n <= MAX_VERSION ? n : null;
}

/**
 * publicUser.legal. needs_acceptance yalniz: sozlesme yuklu + status final + global rol personel degil + (kabul yok
 * ya da eski surum). Taslak sozlesmede, personelde ve sozlesme yokken asla true degil.
 * @param {{role?:string, terms_version?:number|null}|null} user
 * @param {{version:number, status:string}|null} terms  LegalService.getTermsState()
 */
function legalUserState(user, terms) {
  const accepted = positiveIntOrNull(user ? user.terms_version : null);
  const loaded = Boolean(terms) && Number.isInteger(terms.version);
  const current = loaded ? terms.version : null;
  const status = loaded ? terms.status : null;
  const staff = STAFF_ROLES.has(String((user && user.role) || 'user'));
  return {
    terms_accepted_version: accepted,
    terms_current_version: current,
    terms_status: status,
    needs_acceptance: loaded && status === 'final' && !staff && (accepted === null || accepted < current),
  };
}

function cleanUserAgent(value) {
  if (typeof value !== 'string') return null;
  // eslint-disable-next-line no-control-regex
  const s = value.replace(/[\u0000-\u001f\u007f]/g, ' ').trim();
  return s ? Array.from(s).slice(0, USER_AGENT_MAX).join('') : null; // kod noktasi basina kesim (vekil cifti bolunmez)
}

function cleanIp(value) {
  return typeof value === 'string' && value ? value.slice(0, IP_MAX) : null;
}

function assertKnown(meta, known) {
  if (meta.id !== known.id || meta.slug !== known.slug) {
    throw new LegalDocumentError(`id / slug dosyayla uyusmuyor (beklenen ${known.id} / ${known.slug})`);
  }
  if (meta.requires_acceptance !== known.requiresAcceptance) {
    throw new LegalDocumentError(
      known.requiresAcceptance
        ? 'kullanici sozlesmesi onay istemeli (requires_acceptance: true)'
        : 'KVKK aydinlatma metni onaya baglanamaz (requires_acceptance: false olmali)'
    );
  }
}

function publicMeta(meta) {
  return {
    id: meta.id,
    slug: meta.slug,
    title: meta.title,
    version: meta.version,
    effective_date: meta.effective_date,
    status: meta.status,
    requires_acceptance: meta.requires_acceptance,
    url: `/yasal/${meta.slug}`,
  };
}

class LegalService {
  /**
   * @param {{dir?:string, db?:{withTransaction:Function}, logger?:{warn:Function, error:Function}}} [opts]
   *   db yalniz accept() icindir (verilmezse src/db tembel yuklenir).
   */
  constructor({ dir = DEFAULT_LEGAL_DIR, db = null, logger = console } = {}) {
    this.dir = dir;
    this._db = db;
    this._logger = logger || console;
    this._docs = null; // Map<id, {meta, blocks, html}>
  }

  _log(level, text) {
    try {
      const fn = this._logger[level] || this._logger.log;
      if (typeof fn === 'function') fn.call(this._logger, text);
    } catch (_) {
      /* log hatasi yuklemeyi bozmaz */
    }
  }

  /** Belgeleri (yeniden) okur. ASLA firlatmaz. */
  load() {
    const docs = new Map();
    let dirOk = false;
    try {
      dirOk = fs.statSync(this.dir).isDirectory();
    } catch (_) {
      dirOk = false;
    }
    if (!dirOk) {
      this._log('warn', `[LEGAL] Yasal metin dizini yok (${this.dir}); belgeler yayimlanmiyor.`);
      this._docs = docs;
      return this;
    }
    const missing = [];
    for (const known of KNOWN_DOCUMENTS) {
      const file = `${known.slug}.md`;
      let text;
      try {
        text = fs.readFileSync(path.join(this.dir, file), 'utf8');
      } catch (err) {
        if (err && err.code === 'ENOENT') missing.push(file);
        else this._log('error', `[LEGAL] ${file} okunamadi (${(err && err.code) || 'hata'}); belge yayimlanmiyor.`);
        continue;
      }
      try {
        const parsed = parseLegalDocument(text);
        assertKnown(parsed.meta, known);
        const issues = findUnsupportedSyntax(parsed.body);
        if (issues.length > 0) {
          const lines = issues.slice(0, 5).map((x) => x.line + parsed.bodyLine - 1).join(', ');
          this._log('warn', `[LEGAL] ${file}: desteklenmeyen sozdizimi (satir ${lines}); duz metin olarak gosterilir.`);
        }
        // API bloklari HTML sayfayla ayni: basliga esit ilk "# " dusurulur (uygulama basligi ayrica gosterir).
        const blocks = withoutTitleHeading(parsed.blocks, parsed.meta.title);
        docs.set(known.id, { meta: publicMeta(parsed.meta), blocks, html: renderDocumentPage(parsed) });
      } catch (err) {
        const reason = err instanceof LegalDocumentError ? err.message : 'beklenmeyen ayristirma hatasi';
        this._log('error', `[LEGAL] ${file} gecersiz: ${reason}; belge yayimlanmiyor.`);
      }
    }
    if (missing.length > 0) this._log('warn', `[LEGAL] Yasal metin dosyasi yok: ${missing.join(', ')}.`);
    this._docs = docs;
    return this;
  }

  _all() {
    if (!this._docs) this.load();
    return this._docs;
  }

  /** id (terms|privacy) ya da slug ile yuklu belge; yoksa null. */
  _find(key) {
    if (typeof key !== 'string' || !key) return null;
    const known = KNOWN_DOCUMENTS.find((k) => k.id === key || k.slug === key);
    return known ? this._all().get(known.id) || null : null;
  }

  /** GET /legal: yuklu belgeler (sira terms, privacy). */
  listDocuments() {
    const docs = this._all();
    return KNOWN_DOCUMENTS.filter((k) => docs.has(k.id)).map((k) => ({ ...docs.get(k.id).meta }));
  }

  /** GET /legal/:id: meta + blocks (kopya); yoksa null. */
  getDocument(key) {
    const doc = this._find(key);
    return doc ? { ...doc.meta, blocks: doc.blocks.map((b) => ({ ...b })) } : null;
  }

  /** GET /yasal/:slug: yalniz slug ile; yoksa 404 sayfasi. */
  getPage(slug) {
    const known = KNOWN_DOCUMENTS.find((k) => k.slug === slug);
    const doc = known ? this._all().get(known.id) : null;
    return doc ? { status: 200, html: doc.html } : { status: 404, html: NOT_FOUND_HTML };
  }

  /** publicUser.legal icin: {version, status} ya da sozlesme yuklu degilse null. */
  getTermsState() {
    const doc = this._all().get('terms');
    return doc ? { version: doc.meta.version, status: doc.meta.status } : null;
  }

  /** Kayitta accept_terms_version: guncel sozlesme surumu olmali; degilse (ya da sozlesme yoksa) 409. */
  assertCurrentTermsVersion(version) {
    const terms = this.getTermsState();
    if (!terms || terms.version !== version) throw versionMismatch(terms ? terms.version : null);
    return terms;
  }

  /**
   * POST /legal/accept. Bilinmeyen / onay istemeyen belge ya da bozuk surum 400; guncel olmayan surum 409.
   * @returns {Promise<{document:string, version:number, accepted_at:Date}>}
   */
  async accept({ userId, document, version, ip, userAgent } = {}) {
    const doc = typeof document === 'string' ? this._find(document.trim()) : null;
    if (!doc) throw legalError(400, 'Yasal belge bulunamadı.', 'VALIDATION');
    if (!doc.meta.requires_acceptance) {
      throw legalError(400, 'Bu metin bilgilendirme amaçlıdır; onay gerektirmez.', 'VALIDATION');
    }
    const v = parseVersionInput(version);
    if (v !== doc.meta.version) throw versionMismatch(doc.meta.version);
    // Kullanici satiri olmayan kimlik (ornegin servis oturumu: id null) veritabanina gitmez (UUID donusum hatasi 500 olmasin).
    if (!isUuid(String(userId || ''))) throw legalError(404, 'Kullanıcı bulunamadı.', 'NOT_FOUND');
    const db = this._db || require('../db');
    return db.withTransaction(async (tx) => {
      const u = await tx.query('SELECT id FROM users WHERE id = $1 FOR UPDATE', [userId]);
      if (!u.rows || u.rows.length === 0) throw legalError(404, 'Kullanıcı bulunamadı.', 'NOT_FOUND');
      return this.recordAcceptance(tx, { userId, document: doc.meta.id, version: v, ip, userAgent });
    });
  }

  /**
   * Kabul kaydi (cagiranin transaction'inda; kayit akisi hesapla ayni tx'te cagirir). Son kabul ayni surumse yazmaz.
   * @param {{query:Function}} tx
   * @param {{userId:string, document:'terms'|'privacy', version:number, ip?:string, userAgent?:string}} params
   */
  async recordAcceptance(tx, { userId, document, version, ip, userAgent }) {
    if (!tx || typeof tx.query !== 'function') throw new TypeError('recordAcceptance: tx zorunludur.');
    const last = await tx.query(
      `SELECT version, accepted_at FROM legal_acceptances
        WHERE user_id = $1 AND document = $2
        ORDER BY accepted_at DESC, id DESC
        LIMIT 1`,
      [userId, document]
    );
    const prev = last.rows && last.rows[0];
    if (prev && Number(prev.version) === version) return { document, version, accepted_at: prev.accepted_at };
    const ins = await tx.query(
      `INSERT INTO legal_acceptances (user_id, document, version, ip_address, user_agent)
       VALUES ($1, $2, $3, $4, $5)
       RETURNING id, accepted_at`,
      [userId, document, version, cleanIp(ip), cleanUserAgent(userAgent)]
    );
    if (document === 'terms') {
      await tx.query('UPDATE users SET terms_version = $2, terms_accepted_at = now() WHERE id = $1', [userId, version]);
    }
    return { document, version, accepted_at: ins.rows[0].accepted_at };
  }
}

function createLegalService(opts) {
  return new LegalService(opts);
}

let defaultService = null;
/** server.js disinda (createApp kullanmayan cagiranlar) auth_service'in kullandigi ornek: server/legal. */
function getDefaultLegalService() {
  if (!defaultService) defaultService = new LegalService();
  return defaultService;
}

module.exports = {
  LegalService,
  createLegalService,
  getDefaultLegalService,
  legalUserState,
  parseVersionInput,
  versionMismatch,
  KNOWN_DOCUMENTS,
  DEFAULT_LEGAL_DIR,
  STAFF_ROLES,
};
