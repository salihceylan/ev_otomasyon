'use strict';

// ==============================================================================
// AHBU Akilli Ev - Yasal metin bicimi (server/legal/<slug>.md): ayristirici + HTML sayfa (SAF; dosya/ag G/C yok)
// ==============================================================================
//
// Belge = on bilgi (iki "---" satiri arasinda `anahtar: deger`) + govde. Anahtarlarin hepsi zorunludur:
//   id (terms|privacy), slug ([a-z0-9-]), title, version (pozitif tamsayi), effective_date (YYYY-AA-GG),
//   status (draft|final), requires_acceptance (true|false). Deger tek/cift tirnakla sarilabilir; "#" ile baslayan
//   satir yorumdur. UTF-8; BOM ve CRLF hosgoruyle okunur (sozlesme LF ister). Hata: LegalDocumentError (ileti belge
//   ICERIGINI tasimaz; loglanabilir).
//
// Govde alt kumesi (uygulama ayni blok modelini cizer: {type, text, n?}):
//   "# " "## " "### "            -> {type:'h1'|'h2'|'h3', text}
//   bos satirla ayrilan paragraf  -> {type:'p', text}  (paragraf icindeki satirlar tek boslukla birlesir)
//   "- " madde                    -> {type:'li', text}
//   "N. " numarali madde          -> {type:'oli', text, n}   (numara korunur)
//   satir ici yalniz **kalin**: metinde AYNEN kalir; HTML'de <strong>
// Markdown/CommonMark uyumu: isaretsiz satir onceki maddenin devamidir (tembel devam); numarali satir bir paragrafi ya
// da "- " maddesini yalniz "1." ile keser ("...Kanun'un\n11. maddesi" paragraf devamidir), ardisik numarali maddeler
// her numarayla kardestir. Desteklenmeyen sozdizimi (HTML, tablo, baglanti, gorsel, kod, ic ice liste, ####) duz metin
// olarak kalir; findUnsupportedSyntax belge yazarina satir numarasiyla bildirir.
//
// HTML sayfa: tum metin kacirilir (& < > " '), yalniz **..** -> <strong>. Stil TEK <style> blogundadir ve PAGE_CSP onu
// SHA-256 ozetiyle izinler (betik yok, 'unsafe-inline' yok, satir ici style ozniteligi yok).

const crypto = require('crypto');

const DOCUMENT_IDS = Object.freeze(['terms', 'privacy']);
const STATUSES = Object.freeze(['draft', 'final']);
const REQUIRED_KEYS = Object.freeze(['id', 'slug', 'title', 'version', 'effective_date', 'status', 'requires_acceptance']);
const SLUG_RE = /^[a-z0-9]+(?:-[a-z0-9]+)*$/;
const VERSION_RE = /^[1-9]\d{0,8}$/;
const DATE_RE = /^(\d{4})-(\d{2})-(\d{2})$/;
const MAX_SLUG = 64;
const MAX_TITLE = 200;

const HEADING_RE = /^(#{1,3})\s+(\S.*)$/;
const BULLET_RE = /^-\s+(\S.*)$/;
const ORDERED_RE = /^(\d{1,9})\.\s+(\S.*)$/;

class LegalDocumentError extends Error {
  constructor(message) {
    super(message);
    this.name = 'LegalDocumentError';
  }
}

function normalizeNewlines(text) {
  return String(text).replace(/^﻿/, '').replace(/\r\n?/g, '\n');
}

function collapse(text) {
  return String(text).replace(/\s+/g, ' ').trim();
}

function unquote(value) {
  const v = value.trim();
  if (v.length >= 2 && ((v[0] === '"' && v[v.length - 1] === '"') || (v[0] === "'" && v[v.length - 1] === "'"))) {
    return v.slice(1, -1);
  }
  return v;
}

function isCalendarDate(text) {
  const m = DATE_RE.exec(text);
  if (!m) return false;
  const [y, mo, d] = [Number(m[1]), Number(m[2]), Number(m[3])];
  const dt = new Date(Date.UTC(y, mo - 1, d));
  return dt.getUTCFullYear() === y && dt.getUTCMonth() === mo - 1 && dt.getUTCDate() === d;
}

/** @returns {{metaLines:string[], body:string, bodyLine:number}} bodyLine: govdenin dosyadaki ilk satiri (1 tabanli) */
function splitDocument(text) {
  const lines = normalizeNewlines(text).split('\n');
  if (lines[0].trim() !== '---') throw new LegalDocumentError('on bilgi ("---") ile baslamiyor');
  let end = -1;
  for (let i = 1; i < lines.length; i += 1) {
    if (lines[i].trim() === '---') {
      end = i;
      break;
    }
  }
  if (end < 0) throw new LegalDocumentError('on bilgi kapanmiyor (ikinci "---" yok)');
  return { metaLines: lines.slice(1, end), body: lines.slice(end + 1).join('\n'), bodyLine: end + 2 };
}

function parseFrontMatter(metaLines) {
  const raw = Object.create(null);
  for (const line of metaLines) {
    const t = line.trim();
    if (!t || t.startsWith('#')) continue;
    const m = /^([A-Za-z_][A-Za-z0-9_]*)\s*:(.*)$/.exec(t);
    if (!m) throw new LegalDocumentError('on bilgide "anahtar: deger" bicimine uymayan satir');
    if (m[1] in raw) throw new LegalDocumentError(`on bilgide yinelenen anahtar: ${m[1]}`);
    raw[m[1]] = unquote(m[2]);
  }
  for (const key of REQUIRED_KEYS) {
    if (!(key in raw)) throw new LegalDocumentError(`on bilgide eksik anahtar: ${key}`);
  }
  if (!DOCUMENT_IDS.includes(raw.id)) throw new LegalDocumentError('id gecersiz (terms | privacy)');
  if (!SLUG_RE.test(raw.slug) || raw.slug.length > MAX_SLUG) throw new LegalDocumentError('slug gecersiz ([a-z0-9-])');
  // eslint-disable-next-line no-control-regex
  const title = collapse(raw.title.replace(/[\u0000-\u001f\u007f]/g, ' '));
  if (!title || title.length > MAX_TITLE) throw new LegalDocumentError(`title bos ya da ${MAX_TITLE} karakterden uzun`);
  if (!VERSION_RE.test(raw.version)) throw new LegalDocumentError('version pozitif tamsayi olmali');
  if (!isCalendarDate(raw.effective_date)) throw new LegalDocumentError('effective_date gecerli bir YYYY-AA-GG tarihi olmali');
  const status = raw.status.toLowerCase();
  if (!STATUSES.includes(status)) throw new LegalDocumentError('status draft | final olmali');
  const requires = raw.requires_acceptance.toLowerCase();
  if (requires !== 'true' && requires !== 'false') throw new LegalDocumentError('requires_acceptance true | false olmali');
  return {
    id: raw.id,
    slug: raw.slug,
    title,
    version: Number(raw.version),
    effective_date: raw.effective_date,
    status,
    requires_acceptance: requires === 'true',
  };
}

/**
 * Govdeyi blok modeline cevirir (yukaridaki alt kume). Bos isaretler ("#", "-") duz metindir.
 * @returns {Array<{type:string, text:string, n?:number}>}
 */
function parseLegalBody(body) {
  const blocks = [];
  let para = null; // surmekte olan paragrafin satirlari
  let item = null; // son madde (tembel devam hedefi)
  const flush = () => {
    if (para) blocks.push({ type: 'p', text: collapse(para.join(' ')) });
    para = null;
  };
  for (const raw of normalizeNewlines(body).split('\n')) {
    const line = raw.trim();
    if (!line) {
      flush();
      item = null;
      continue;
    }
    let m = HEADING_RE.exec(line);
    if (m) {
      flush();
      item = null;
      blocks.push({ type: `h${m[1].length}`, text: collapse(m[2]) });
      continue;
    }
    m = BULLET_RE.exec(line);
    if (m) {
      flush();
      item = { type: 'li', text: collapse(m[1]) };
      blocks.push(item);
      continue;
    }
    m = ORDERED_RE.exec(line);
    // Paragrafi ya da "- " maddesini yalniz 1 keser; bos satir / baslik / numarali madde sonrasinda her numara baslatir.
    if (m && (Number(m[1]) === 1 || (!para && (!item || item.type === 'oli')))) {
      flush();
      item = { type: 'oli', text: collapse(m[2]), n: Number(m[1]) };
      blocks.push(item);
      continue;
    }
    if (item) {
      item.text = collapse(`${item.text} ${line}`);
      continue;
    }
    (para || (para = [])).push(line);
  }
  flush();
  return blocks;
}

/**
 * @returns {{meta:object, blocks:Array, body:string, bodyLine:number}}
 * @throws {LegalDocumentError}
 */
function parseLegalDocument(text) {
  const { metaLines, body, bodyLine } = splitDocument(text);
  const meta = parseFrontMatter(metaLines);
  const blocks = parseLegalBody(body);
  if (blocks.length === 0) throw new LegalDocumentError('govde bos');
  return { meta, blocks, body, bodyLine };
}

// ------------------------------------------------------------------------------
// Belge yazari icin uygunluk denetimi (yukleyici uyari loglar; gercek belgelerin testi bos liste bekler)
// ------------------------------------------------------------------------------
const UNSUPPORTED_LINE_RULES = Object.freeze([
  [/^\s*(?:```|~~~)/, 'kod blogu desteklenmez'],
  [/^\s*\|/, 'tablo desteklenmez'],
  [/^\s*>/, 'alinti desteklenmez'],
  [/^\s*#{4,}/, 'yalniz #, ##, ### basliklari desteklenir'],
  [/^\s*#{1,3}[^#\s]/, 'baslik isaretinden sonra bosluk olmali'],
  [/^\s*[*+]\s/, 'madde isareti yalniz "- " olabilir'],
  [/^\s+(?:-|\d+\.)\s/, 'ic ice (girintili) liste desteklenmez'],
  [/<\/?[A-Za-z][A-Za-z0-9-]*(?:\s[^>]*)?\/?>|<!--/, 'HTML desteklenmez'],
  [/!\[/, 'gorsel desteklenmez'],
  [/\]\(/, 'baglanti desteklenmez'],
]);

/**
 * Govdedeki desteklenmeyen sozdizimi (satir basina en cok bir kural) ve kapanmamis ** (paragraf / madde basina).
 * @returns {Array<{line:number, reason:string}>} line: govdenin 1 tabanli satiri
 */
function findUnsupportedSyntax(body) {
  const issues = [];
  let group = null; // { line, count }: paragraf/madde basina ** sayaci
  const endGroup = () => {
    if (group && group.count % 2 === 1) issues.push({ line: group.line, reason: 'kapanmamis ** (kalin)' });
    group = null;
  };
  normalizeNewlines(body).split('\n').forEach((raw, i) => {
    const lineNo = i + 1;
    const rule = UNSUPPORTED_LINE_RULES.find(([re]) => re.test(raw));
    if (rule) issues.push({ line: lineNo, reason: rule[1] });
    const t = raw.trim();
    if (!t) {
      endGroup();
      return;
    }
    const heading = /^#{1,3}\s/.test(t);
    if (!group || heading || /^-\s/.test(t) || /^\d{1,9}\.\s/.test(t)) {
      endGroup();
      group = { line: lineNo, count: 0 };
    }
    group.count += (t.match(/\*\*/g) || []).length;
    if (heading) endGroup(); // baslik tek satirdir
  });
  endGroup();
  return issues.sort((a, b) => a.line - b.line);
}

// ------------------------------------------------------------------------------
// HTML
// ------------------------------------------------------------------------------
const PAGE_CSS = [
  ':root{color-scheme:light dark}',
  'body{margin:0;background:#f4f6f8;color:#1b2430;font:16px/1.6 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif}',
  'main{max-width:46rem;margin:0 auto;padding:1.5rem 1rem 3rem}',
  'article{background:#fff;border-radius:12px;box-shadow:0 1px 4px rgba(0,0,0,.08);padding:1.25rem 1.5rem}',
  'h1{font-size:1.45rem;line-height:1.3;margin:.25rem 0 .5rem}',
  'h2{font-size:1.2rem;margin:1.75rem 0 .5rem}',
  'h3{font-size:1.05rem;margin:1.25rem 0 .4rem}',
  'p,li{margin:.5rem 0;overflow-wrap:anywhere}',
  '.meta{color:#56616f;font-size:.9rem}',
  '.taslak{border:2px solid #b45309;background:#fff7ed;color:#7c2d12;border-radius:8px;padding:.75rem 1rem}',
  '@media (prefers-color-scheme:dark){body{background:#0f141a;color:#e6e9ee}article{background:#171d25;box-shadow:none}' +
    '.meta{color:#a9b2bd}.taslak{background:#2a1a0c;color:#fdba74;border-color:#f59e0b}}',
].join('');

const PAGE_CSP =
  `default-src 'none'; style-src 'sha256-${crypto.createHash('sha256').update(PAGE_CSS, 'utf8').digest('base64')}'; ` +
  "base-uri 'none'; form-action 'none'; frame-ancestors 'none'";

function escapeHtml(text) {
  return String(text)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

/** Kacirilmis metin; yalniz kapanan **..** ciftleri <strong> olur, kapanmayan ** duz metindir, bos kalin atlanir. */
function renderInlineHtml(text) {
  const parts = String(text).split('**');
  const closed = parts.length % 2 === 1 ? parts.length : parts.length - 1;
  let out = '';
  for (let i = 0; i < closed; i += 1) {
    if (i % 2 === 0) out += escapeHtml(parts[i]);
    else if (parts[i]) out += `<strong>${escapeHtml(parts[i])}</strong>`;
  }
  if (closed < parts.length) out += escapeHtml(`**${parts[parts.length - 1]}`);
  return out;
}

/** "2026-10-08" -> "08.10.2026" */
function formatTrDate(iso) {
  const m = DATE_RE.exec(String(iso));
  return m ? `${m[3]}.${m[2]}.${m[1]}` : String(iso);
}

function plainText(text) {
  return collapse(String(text).split('**').join('')).toLocaleLowerCase('tr');
}

/**
 * Govde basliga esit bir "# " ile basliyorsa (Markdown aliskanligi) o ilk blok dusurulur: baslik on bilgiden ayrica
 * gosterilir (HTML sayfa ve uygulama), iki kez gorunmesin. Karsilastirma buyuk/kucuk harf, bosluk ve ** farkini
 * onemsemez; yalniz ILK blok ve yalniz h1. Girdi dizisi degistirilmez.
 */
function withoutTitleHeading(blocks, title) {
  if (blocks.length > 0 && blocks[0].type === 'h1' && plainText(blocks[0].text) === plainText(title)) return blocks.slice(1);
  return blocks;
}

function renderBlocksHtml(blocks) {
  let out = '';
  let open = null; // 'ul' | 'ol'
  const close = () => {
    if (open) out += `</${open}>\n`;
    open = null;
  };
  for (const b of blocks) {
    const list = b.type === 'li' ? 'ul' : b.type === 'oli' ? 'ol' : null;
    if (list !== open) {
      close();
      if (list) out += `<${list}>`;
      open = list;
    }
    if (b.type === 'li') out += `<li>${renderInlineHtml(b.text)}</li>`;
    else if (b.type === 'oli') out += `<li value="${Number(b.n)}">${renderInlineHtml(b.text)}</li>`;
    else if (b.type === 'p') out += `<p>${renderInlineHtml(b.text)}</p>\n`;
    else if (b.type === 'h1' || b.type === 'h2' || b.type === 'h3') out += `<${b.type}>${renderInlineHtml(b.text)}</${b.type}>\n`;
  }
  close();
  return out;
}

function pageShell(title, inner) {
  return (
    '<!doctype html>\n<html lang="tr">\n<head>\n<meta charset="utf-8">\n' +
    '<meta name="viewport" content="width=device-width, initial-scale=1">\n' +
    '<meta name="referrer" content="no-referrer">\n' +
    `<title>${escapeHtml(title)}</title>\n<style>${PAGE_CSS}</style>\n</head>\n` +
    `<body>\n<main>\n${inner}</main>\n</body>\n</html>\n`
  );
}

/**
 * Belgenin herkese acik HTML sayfasi: baslik, "Surum N · Yururluk: GG.AA.YYYY", taslakta TASLAK bandi, govde.
 * Govde basliga esit bir "# " ile basliyorsa o satir tekrarlanmaz (withoutTitleHeading).
 * @param {{meta:object, blocks:Array}} doc
 */
function renderDocumentPage({ meta, blocks }) {
  const body = withoutTitleHeading(blocks, meta.title);
  const banner = meta.status === 'draft'
    ? '<p class="taslak" role="note"><strong>TASLAK</strong> Bu metin taslaktır; henüz yürürlükte değildir ve değişebilir.</p>\n'
    : '';
  const inner =
    `<article>\n<h1>${escapeHtml(meta.title)}</h1>\n` +
    `<p class="meta">Sürüm ${Number(meta.version)} · Yürürlük: ${escapeHtml(formatTrDate(meta.effective_date))}</p>\n` +
    `${banner}${renderBlocksHtml(body)}</article>\n`;
  return pageShell(meta.title, inner);
}

function renderNotFoundPage() {
  return pageShell(
    'Belge bulunamadı',
    '<article>\n<h1>Belge bulunamadı</h1>\n' +
      '<p>İstenen yasal metin bulunamadı. Bağlantıyı denetleyin; güncel metinlere uygulamadaki Ayarlar bölümünden ' +
      '(Yasal Metinler) de ulaşabilirsiniz.</p>\n</article>\n'
  );
}

module.exports = {
  LegalDocumentError,
  DOCUMENT_IDS,
  STATUSES,
  PAGE_CSS,
  PAGE_CSP,
  parseLegalDocument,
  parseLegalBody,
  findUnsupportedSyntax,
  withoutTitleHeading,
  escapeHtml,
  renderInlineHtml,
  formatTrDate,
  renderDocumentPage,
  renderNotFoundPage,
};
