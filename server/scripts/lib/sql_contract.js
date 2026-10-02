'use strict';

// ==============================================================================
// Sema-sozlesme denetimi: kodun kullandigi tablo/sutunlar <-> migration'lar (WP-C, C9)
// ==============================================================================
//
// Neden: Kopru `devices.last_ack_id` yazarken bunu yaratan migration yoktu -> her canli state
// 42703 ile geri alinir, saglikli pano "cevrimdisi" supurulur. PostgreSQL olmadan bu tur
// "kod <-> sema" kaymalari ancak canlida fark ediliyordu. Bu modul:
//
//   loadMigrationSchema(dir)   migration dosyalarindaki CREATE TABLE / ALTER TABLE ADD COLUMN'dan
//                              tablo -> sutun kumesi cikarir (DO bloklari ve EXECUTE format metni dahil).
//   extractSqlLiterals(src)    JS kaynagindaki SQL metinlerini (tirnakli/sablon, `+` ile birlestirilmis)
//                              cikarir; ${...} dinamik parcalar `__EXPR__` olur.
//   analyzeSql(sql, schema)    tek bir SQL ifadesindeki tablo/sutun basvurularini cozer ve semada
//                              OLMAYANLARI bildirir.
//   verifyLiveSchema(db, refs) calisan bir PostgreSQL'in information_schema'sina karsi dogrular.
//
// SINIRLAR (dürüst not): Bu bir SQL ayristirici DEGILDIR; sezgisel bir tarayicidir. Takma ad ve
// nitelikli basvurulari (a.sutun), INSERT/ON CONFLICT sutun listelerini, UPDATE ... SET sol taraflarini
// ve tek-tablolu ifadelerdeki yalin sutun adlarini denetler. Dinamik olusturulan SQL'in calisan
// halini yakalamak icin sql_capture.js kullanilir. Gercek PostgreSQL'e karsi dogrulama icin
// `node scripts/check_schema_contract.js --live`.

const fs = require('fs');
const path = require('path');

// ------------------------------------------------------------------------------
// Migration semasi
// ------------------------------------------------------------------------------
function stripSqlComments(sql) {
  return String(sql).replace(/\/\*[\s\S]*?\*\//g, '').replace(/--[^\n]*/g, '');
}

function splitTopLevel(body, sep = ',') {
  const parts = [];
  let depth = 0;
  let cur = '';
  for (const c of body) {
    if (c === '(') depth++;
    if (c === ')') depth--;
    if (c === sep && depth === 0) {
      parts.push(cur);
      cur = '';
    } else {
      cur += c;
    }
  }
  if (cur.trim()) parts.push(cur);
  return parts;
}

/**
 * @param {string} dir  migrations dizini (yalniz UST DUZEY *.sql; dev_seeds haric)
 * @returns {Map<string, Set<string>>} tablo -> sutunlar
 */
function loadMigrationSchema(dir, fsApi = fs) {
  const tables = new Map();
  const add = (t, c) => {
    if (!tables.has(t)) tables.set(t, new Set());
    tables.get(t).add(c);
  };
  const names = fsApi
    .readdirSync(dir, { withFileTypes: true })
    .filter((e) => e.isFile() && /\.sql$/i.test(e.name))
    .map((e) => e.name)
    .sort();

  for (const name of names) {
    const sql = stripSqlComments(fsApi.readFileSync(path.join(dir, name), 'utf8'));

    const re = /CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?(?:public\.)?([a-z_][a-z0-9_]*)\s*\(/gi;
    let m;
    while ((m = re.exec(sql)) !== null) {
      const table = m[1].toLowerCase();
      let depth = 1;
      let i = re.lastIndex;
      const start = i;
      while (i < sql.length && depth > 0) {
        if (sql[i] === '(') depth++;
        else if (sql[i] === ')') depth--;
        i++;
      }
      for (const part of splitTopLevel(sql.slice(start, i - 1))) {
        const t = part.trim();
        if (!t || /^(CONSTRAINT|PRIMARY|UNIQUE|CHECK|FOREIGN|EXCLUDE|LIKE)\b/i.test(t)) continue;
        const col = /^"?([a-z_][a-z0-9_]*)"?/i.exec(t);
        if (col) add(table, col[1].toLowerCase());
      }
    }

    const alter = /ALTER\s+TABLE\s+(?:ONLY\s+)?(?:IF\s+EXISTS\s+)?(?:public\.)?([a-z_][a-z0-9_]*)\s+([\s\S]*?);/gi;
    while ((m = alter.exec(sql)) !== null) {
      for (const c of m[2].matchAll(/ADD\s+COLUMN\s+(?:IF\s+NOT\s+EXISTS\s+)?"?([a-z_][a-z0-9_]*)"?/gi)) {
        add(m[1].toLowerCase(), c[1].toLowerCase());
      }
    }
  }
  return tables;
}

// ------------------------------------------------------------------------------
// JS kaynagindan SQL metni cikarimi
// ------------------------------------------------------------------------------
const EXPR = '__EXPR__';

/**
 * Basit bir sozcuk cozumleyici: yorumlari, regex sabitlerini atlar; '...', "..." ve `...` metinlerini
 * dondurur; `a' + 'b` seklinde dogrudan `+` ile birlestirilenleri TEK metin yapar.
 * @returns {Array<{text:string, line:number, dynamic:boolean}>}
 */
function extractSqlLiterals(src) {
  const out = [];
  const n = src.length;
  let i = 0;
  let line = 1;
  let prevSig = ''; // son anlamli (bosluk/yorum olmayan) karakter - regex sabiti tespiti icin

  function skipWsAndComments(from) {
    let j = from;
    let l = 0;
    for (;;) {
      const c = src[j];
      if (c === '\n') {
        l++;
        j++;
      } else if (c === ' ' || c === '\t' || c === '\r') {
        j++;
      } else if (c === '/' && src[j + 1] === '/') {
        while (j < n && src[j] !== '\n') j++;
      } else if (c === '/' && src[j + 1] === '*') {
        j += 2;
        while (j < n && !(src[j] === '*' && src[j + 1] === '/')) {
          if (src[j] === '\n') l++;
          j++;
        }
        j += 2;
      } else {
        break;
      }
    }
    return { j, l };
  }

  // Tirnakli metni okur; { text, end, newlines, dynamic }
  function readQuoted(start) {
    const q = src[start];
    let j = start + 1;
    let text = '';
    let newlines = 0;
    while (j < n && src[j] !== q) {
      if (src[j] === '\\') {
        text += src[j + 1] === 'n' ? '\n' : src[j + 1];
        j += 2;
        continue;
      }
      if (src[j] === '\n') newlines++;
      text += src[j];
      j++;
    }
    return { text, end: j + 1, newlines, dynamic: false };
  }

  // Sablon metni okur: ${...} ifadeleri atlanir ve __EXPR__ olur (ic ice sablon/metin/parantez dahil)
  function readTemplate(start) {
    let j = start + 1;
    let text = '';
    let newlines = 0;
    let dynamic = false;
    while (j < n && src[j] !== '`') {
      if (src[j] === '\\') {
        text += src[j + 1];
        j += 2;
        continue;
      }
      if (src[j] === '$' && src[j + 1] === '{') {
        dynamic = true;
        text += EXPR;
        j += 2;
        let depth = 1;
        while (j < n && depth > 0) {
          const c = src[j];
          if (c === '{') depth++;
          else if (c === '}') depth--;
          else if (c === '\n') newlines++;
          else if (c === "'" || c === '"') {
            const r = readQuoted(j);
            newlines += r.newlines;
            j = r.end;
            continue;
          } else if (c === '`') {
            const r = readTemplate(j);
            newlines += r.newlines;
            j = r.end;
            continue;
          }
          j++;
        }
        continue;
      }
      if (src[j] === '\n') newlines++;
      text += src[j];
      j++;
    }
    return { text, end: j + 1, newlines, dynamic };
  }

  const REGEX_PREV = new Set(['(', ',', '=', ':', '[', '!', '&', '|', '?', '{', '}', ';', '+', '-', '*', '%', '<', '>', '~', '^', '']);

  while (i < n) {
    const c = src[i];
    const d = src[i + 1];
    if (c === '\n') {
      line++;
      i++;
      continue;
    }
    if (c === ' ' || c === '\t' || c === '\r') {
      i++;
      continue;
    }
    if (c === '/' && d === '/') {
      while (i < n && src[i] !== '\n') i++;
      continue;
    }
    if (c === '/' && d === '*') {
      i += 2;
      while (i < n && !(src[i] === '*' && src[i + 1] === '/')) {
        if (src[i] === '\n') line++;
        i++;
      }
      i += 2;
      continue;
    }
    if (c === '/' && REGEX_PREV.has(prevSig)) {
      // regex sabiti: kapanis '/' (sinif [...] icindekiler haric) -- bayraklara kadar atla
      i++;
      let inClass = false;
      while (i < n && src[i] !== '\n') {
        if (src[i] === '\\') {
          i += 2;
          continue;
        }
        if (src[i] === '[') inClass = true;
        else if (src[i] === ']') inClass = false;
        else if (src[i] === '/' && !inClass) {
          i++;
          break;
        }
        i++;
      }
      while (i < n && /[a-z]/i.test(src[i])) i++;
      prevSig = ')';
      continue;
    }
    if (c === "'" || c === '"' || c === '`') {
      const startLine = line;
      let r = c === '`' ? readTemplate(i) : readQuoted(i);
      let text = r.text;
      let dynamic = r.dynamic;
      line += r.newlines;
      i = r.end;
      // `+` ile birlestirilmis ardil metinleri tek SQL say
      for (;;) {
        const w = skipWsAndComments(i);
        if (src[w.j] === '+') {
          const w2 = skipWsAndComments(w.j + 1);
          const q = src[w2.j];
          if (q === "'" || q === '"' || q === '`') {
            line += w.l + w2.l;
            r = q === '`' ? readTemplate(w2.j) : readQuoted(w2.j);
            text += r.text;
            dynamic = dynamic || r.dynamic;
            line += r.newlines;
            i = r.end;
            continue;
          }
        }
        break;
      }
      out.push({ text, line: startLine, dynamic });
      prevSig = ')';
      continue;
    }
    prevSig = c;
    i++;
  }
  return out;
}

const SQL_START = /^\s*(WITH\b[\s\S]*?\b(?:SELECT|INSERT|UPDATE|DELETE)\b|SELECT\b|INSERT\s+INTO\b|UPDATE\s+[A-Za-z_]|DELETE\s+FROM\b)/;

/** Metin bir SQL ifadesi gibi mi? (buyuk harfli anahtar sozcuk + yapi) */
function looksLikeSql(text) {
  if (!SQL_START.test(text)) return false;
  return /\b(FROM|INTO|SET|VALUES|WHERE|RETURNING)\b/.test(text);
}

// ------------------------------------------------------------------------------
// SQL cozumleme
// ------------------------------------------------------------------------------
const KEYWORDS = new Set(
  (
    'SELECT FROM WHERE AND OR NOT NULL IS TRUE FALSE IN AS ON JOIN LEFT RIGHT INNER OUTER FULL CROSS SET VALUES INSERT INTO ' +
    'UPDATE DELETE RETURNING LIMIT OFFSET ORDER BY GROUP HAVING DISTINCT CASE WHEN THEN ELSE END EXISTS ANY ALL UNION ' +
    'DEFAULT CONFLICT DO NOTHING ASC DESC FOR SHARE NOWAIT SKIP LOCKED WITH RECURSIVE LATERAL USING ONLY NATURAL ' +
    'CURRENT_TIMESTAMP CURRENT_DATE CURRENT_TIME LIKE ILIKE BETWEEN SIMILAR ESCAPE INTERVAL EXCLUDED TABLE OVER PARTITION ' +
    'ROWS RANGE UNBOUNDED PRECEDING FOLLOWING CURRENT ROW ARRAY NULLS FIRST LAST FILTER WITHIN VARIADIC AT TIME ZONE ' +
    'YEAR MONTH DAY HOUR MINUTE SECOND EPOCH EXCEPT INTERSECT FETCH NEXT ONLY CONSTRAINT UPDATE BEGIN COMMIT DISTINCT_FROM FOR_LOCK'
  ).split(/\s+/)
);

const FN_NO_ALIAS_AFTER = new Set(['SET', 'WHERE', 'ON', 'LEFT', 'RIGHT', 'INNER', 'OUTER', 'CROSS', 'FULL', 'JOIN', 'USING', 'VALUES', 'SELECT', 'RETURNING', 'GROUP', 'ORDER', 'LIMIT', 'OFFSET', 'HAVING', 'UNION', 'EXCEPT', 'INTERSECT', 'FOR', 'WINDOW', 'NATURAL', 'FROM', 'AS', 'AND', 'OR', 'NOT', 'DO', 'WITH', 'LATERAL', 'NOTHING', 'DEFAULT', 'ELSE', 'THEN', 'WHEN', 'END']);

/** Yorum, metin sabitleri, $n ve __EXPR__ temizligi. */
function normalizeSql(sql) {
  let s = stripSqlComments(sql);
  // '...' sabitleri ('' kacisli) -> ''
  s = s.replace(/'(?:[^']|'')*'/g, "''");
  s = s.replace(/\$\d+/g, '?');
  s = s.replace(/public\./gi, '');
  s = s.replace(/\s+/g, ' ').trim();
  // `IS DISTINCT FROM`, `EXTRACT(x FROM y)`, `FOR UPDATE OF t` tablo kaynagi DEGILDIR
  s = s.replace(/\bDISTINCT\s+FROM\b/gi, 'DISTINCT_FROM');
  s = s.replace(/\b(EXTRACT|TRIM|SUBSTRING|OVERLAY|POSITION)\s*\(([^()]*?)\bFROM\b/gi, '$1($2,');
  s = s.replace(/\bFOR\s+(?:NO\s+KEY\s+)?(?:UPDATE|SHARE)(?:\s+OF\s+[a-z_][a-z0-9_]*(?:\s*,\s*[a-z_][a-z0-9_]*)*)?/gi, 'FOR_LOCK');
  return s;
}

function matchParen(s, openIdx) {
  let depth = 0;
  for (let i = openIdx; i < s.length; i++) {
    if (s[i] === '(') depth++;
    else if (s[i] === ')') {
      depth--;
      if (depth === 0) return i;
    }
  }
  return -1;
}

/**
 * Tek bir SQL ifadesini cozer.
 * @returns {{ refs: Array<{table:string,column:string,via:string}>, unknownTables: string[],
 *            unknownColumns: Array<{table:string,column:string,via:string}>, skipped: boolean, reason?: string }}
 */
function analyzeSql(sql, schema) {
  const result = { refs: [], unknownTables: [], unknownColumns: [], skipped: false };
  const dynamic = sql.includes(EXPR);
  let s = normalizeSql(sql.replace(new RegExp(EXPR, 'g'), '?'));

  // Katalog sorgulari (information_schema / pg_*) sema denetimi disi
  if (/\b(information_schema|pg_catalog|pg_class|pg_constraint|pg_attribute|pg_tables|pg_roles|pg_advisory|to_regclass)\b/i.test(s)) {
    return { ...result, skipped: true, reason: 'katalog sorgusu' };
  }

  // CTE adlari
  const cte = new Set();
  for (const m of s.matchAll(/(?:\bWITH(?:\s+RECURSIVE)?|,)\s+([a-z_][a-z0-9_]*)\s+AS\s*\(/gi)) cte.add(m[1].toLowerCase());

  // Tablolar ve takma adlar
  const aliasToTable = new Map();
  const realTables = [];
  const derived = new Set(); // takma adi turetilmis (alt sorgu / VALUES / fonksiyon) olanlar
  const tableRe = /\b(?:(?:FROM|JOIN|UPDATE|USING)\s+(?:ONLY\s+)?(?!\(|SELECT\b|LATERAL\b|VALUES\b)([a-z_][a-z0-9_]*)(?![a-z0-9_])(?!\s*\()|INTO\s+([a-z_][a-z0-9_]*)(?![a-z0-9_]))(?:\s+(?:AS\s+)?([a-z_][a-z0-9_]*)(?![a-z0-9_(]))?/gi;
  let tm;
  while ((tm = tableRe.exec(s)) !== null) {
    const table = (tm[1] || tm[2]).toLowerCase();
    let alias = tm[3] ? tm[3].toLowerCase() : null;
    if (alias && FN_NO_ALIAS_AFTER.has(alias.toUpperCase())) alias = null;
    if (/^(?:SET|WHERE)$/i.test(table)) continue;
    if (cte.has(table)) {
      if (alias) derived.add(alias);
      derived.add(table);
      continue;
    }
    if (!schema.has(table)) {
      if (!result.unknownTables.includes(table)) result.unknownTables.push(table);
      if (alias) derived.add(alias);
      continue;
    }
    realTables.push(table);
    aliasToTable.set(table, table);
    if (alias) aliasToTable.set(alias, table);
  }

  // Turetilmis tablolar: FROM ( ... ) alias[(cols)]  ve  FROM fonksiyon(...) alias[(cols)]
  for (const m of s.matchAll(/\b(?:FROM|JOIN)\s+(?:LATERAL\s+)?(\(|[a-z_][a-z0-9_]*\s*\()/gi)) {
    const open = m.index + m[0].length - 1;
    const close = matchParen(s, open);
    if (close < 0) continue;
    const after = /^\s*(?:AS\s+)?([a-z_][a-z0-9_]*)/i.exec(s.slice(close + 1));
    if (after && !FN_NO_ALIAS_AFTER.has(after[1].toUpperCase())) derived.add(after[1].toLowerCase());
  }

  const target = realTables.length > 0 ? realTables[0] : null;
  const checkCol = (table, column, via) => {
    if (!schema.has(table)) return;
    result.refs.push({ table, column, via });
    if (!schema.get(table).has(column)) result.unknownColumns.push({ table, column, via });
  };

  // INSERT INTO t (c1, c2)
  const ins = /\bINSERT\s+INTO\s+([a-z_][a-z0-9_]*)\s*\(([^)]*)\)/i.exec(s);
  if (ins && schema.has(ins[1].toLowerCase())) {
    for (const c of ins[2].split(',')) {
      const col = c.trim().toLowerCase();
      if (col && /^[a-z_][a-z0-9_]*$/.test(col)) checkCol(ins[1].toLowerCase(), col, 'insert');
    }
  }
  // ON CONFLICT (c1, c2)
  const insertTable = ins && schema.has(ins[1].toLowerCase()) ? ins[1].toLowerCase() : target;
  for (const m of s.matchAll(/\bON\s+CONFLICT\s*\(([^)]*)\)/gi)) {
    for (const c of m[1].split(',')) {
      const col = c.trim().toLowerCase();
      if (col && insertTable && /^[a-z_][a-z0-9_]*$/.test(col)) checkCol(insertTable, col, 'on-conflict');
    }
  }

  // UPDATE t [alias] SET a = ..., b = ...   ve   DO UPDATE SET ...
  const setRegions = [];
  const upd = /\bUPDATE\s+(?:ONLY\s+)?([a-z_][a-z0-9_]*)(?:\s+(?:AS\s+)?(?!SET\b)[a-z_][a-z0-9_]*)?\s+SET\s+/i.exec(s);
  if (upd) setRegions.push({ table: upd[1].toLowerCase(), from: upd.index + upd[0].length });
  for (const m of s.matchAll(/\bDO\s+UPDATE\s+SET\s+/gi)) {
    if (insertTable) setRegions.push({ table: insertTable, from: m.index + m[0].length });
  }
  for (const region of setRegions) {
    if (!schema.has(region.table)) continue;
    let depth = 0;
    let end = s.length;
    for (let i = region.from; i < s.length; i++) {
      const c = s[i];
      if (c === '(') depth++;
      else if (c === ')') {
        if (depth === 0) {
          end = i;
          break;
        }
        depth--;
      } else if (depth === 0) {
        const rest = s.slice(i);
        if (/^(?:FROM|WHERE|RETURNING)\b/i.test(rest) && /[\s)]/.test(s[i - 1] || ' ')) {
          end = i;
          break;
        }
      }
    }
    for (const part of splitTopLevel(s.slice(region.from, end))) {
      const lhs = /^\s*([a-z_][a-z0-9_]*)\s*=/i.exec(part);
      if (lhs) checkCol(region.table, lhs[1].toLowerCase(), 'set');
    }
  }

  // Nitelikli basvurular: alias.sutun / tablo.sutun / EXCLUDED.sutun
  for (const m of s.matchAll(/(?<![a-z0-9_.$?])([a-z_][a-z0-9_]*)\.([a-z_][a-z0-9_]*|\*)(?![a-z0-9_(])/gi)) {
    const qual = m[1].toLowerCase();
    const col = m[2].toLowerCase();
    if (col === '*') continue;
    if (derived.has(qual)) continue;
    let table = aliasToTable.get(qual);
    if (!table && qual === 'excluded') table = insertTable;
    if (!table && schema.has(qual)) table = qual;
    if (!table) continue;
    checkCol(table, col, 'qualified');
  }

  // Yalin sutun adlari: yalnizca TEK gercek tablolu, turetilmis/CTE icermeyen ifadelerde
  if (!dynamic && realTables.length === 1 && derived.size === 0 && cte.size === 0 && schema.has(realTables[0])) {
    const cols = schema.get(realTables[0]);
    let body = s
      .replace(/::\s*[a-z_][a-z0-9_]*(?:\s*\[\s*\])?(?:\s*\(\s*\d+(?:\s*,\s*\d+)?\s*\))?/gi, ' ') // tip donusumleri
      .replace(/\bAS\s+[a-z_][a-z0-9_]*/gi, ' ') // sonuc takma adlari
      .replace(/[a-z_][a-z0-9_]*\.[a-z_*][a-z0-9_]*/gi, ' ') // nitelikli (yukarida denetlendi)
      .replace(/\b(?:INTERVAL)\s+\?/gi, ' ')
      .replace(/\b[a-z_][a-z0-9_]*\s*=>/gi, ' ') // adlandirilmis fonksiyon argumanlari (make_interval(secs => ?))
      .replace(/\b[a-z_][a-z0-9_]*\s*\(/gi, '('); // fonksiyon adlari
    // INSERT/UPDATE basliklari ve tablo adi
    body = body
      .replace(/\bINSERT\s+INTO\s+[a-z_][a-z0-9_]*\s*\([^)]*\)/gi, ' ')
      .replace(/\bON\s+CONFLICT\s*\([^)]*\)/gi, ' ');
    for (const m of body.matchAll(/(?<![a-z0-9_.$?])([a-z_][a-z0-9_]*)(?![a-z0-9_.(])/gi)) {
      const word = m[1].toLowerCase();
      if (KEYWORDS.has(word.toUpperCase())) continue;
      if (word === realTables[0] || aliasToTable.get(word) === realTables[0]) continue;
      if (cols.has(word)) {
        result.refs.push({ table: realTables[0], column: word, via: 'bare' });
        continue;
      }
      result.unknownColumns.push({ table: realTables[0], column: word, via: 'bare' });
    }
  }

  // tekrarlari ele
  const seen = new Set();
  result.refs = result.refs.filter((r) => {
    const k = `${r.table}.${r.column}`;
    if (seen.has(k)) return false;
    seen.add(k);
    return true;
  });
  const seenU = new Set();
  result.unknownColumns = result.unknownColumns.filter((r) => {
    const k = `${r.table}.${r.column}`;
    if (seenU.has(k)) return false;
    seenU.add(k);
    return true;
  });
  return result;
}

/**
 * Bir ifade kumesini denetler.
 * @param {Array<{sql:string, where?:string}>} statements
 * @returns {{violations:Array, refs:Map<string,Set<string>>, analyzed:number, skipped:number}}
 */
function checkStatements(statements, schema) {
  const violations = [];
  const refs = new Map();
  let analyzed = 0;
  let skipped = 0;
  for (const st of statements) {
    const r = analyzeSql(st.sql, schema);
    if (r.skipped) {
      skipped++;
      continue;
    }
    analyzed++;
    for (const ref of r.refs) {
      if (!refs.has(ref.table)) refs.set(ref.table, new Set());
      refs.get(ref.table).add(ref.column);
    }
    for (const t of r.unknownTables) violations.push({ kind: 'unknown-table', table: t, where: st.where, sql: st.sql.slice(0, 140) });
    for (const c of r.unknownColumns) violations.push({ kind: 'unknown-column', table: c.table, column: c.column, via: c.via, where: st.where, sql: st.sql.slice(0, 140) });
  }
  return { violations, refs, analyzed, skipped };
}

/** Bir dizindeki .js dosyalarindan (alt dizinler dahil) SQL ifadelerini toplar. */
function collectStaticStatements(rootDir, { fsApi = fs, ignore = [] } = {}) {
  const statements = [];
  const walk = (dir) => {
    for (const e of fsApi.readdirSync(dir, { withFileTypes: true })) {
      const full = path.join(dir, e.name);
      if (e.isDirectory()) {
        if (e.name === 'node_modules' || e.name.startsWith('.')) continue;
        walk(full);
      } else if (e.name.endsWith('.js') && !ignore.some((p) => full.includes(p))) {
        const src = fsApi.readFileSync(full, 'utf8');
        for (const lit of extractSqlLiterals(src)) {
          if (looksLikeSql(lit.text)) statements.push({ sql: lit.text, where: `${path.relative(rootDir, full)}:${lit.line}`, dynamic: lit.dynamic });
        }
      }
    }
  };
  walk(rootDir);
  return statements;
}

/**
 * Calisan PostgreSQL'e karsi dogrulama: refs'teki her (tablo, sutun) information_schema.columns'ta olmali.
 * @param {{query:Function}} db
 * @param {Map<string,Set<string>>} refs
 * @returns {Promise<Array<{table:string,column:string|null,problem:string}>>}
 */
async function verifyLiveSchema(db, refs) {
  const tables = [...refs.keys()];
  if (tables.length === 0) return [];
  const res = await db.query(
    "SELECT table_name, column_name FROM information_schema.columns WHERE table_schema = 'public' AND table_name = ANY($1::text[])",
    [tables]
  );
  const live = new Map();
  for (const row of res.rows) {
    if (!live.has(row.table_name)) live.set(row.table_name, new Set());
    live.get(row.table_name).add(row.column_name);
  }
  const problems = [];
  for (const [table, cols] of refs) {
    if (!live.has(table)) {
      problems.push({ table, column: null, problem: 'tablo yok' });
      continue;
    }
    for (const c of cols) if (!live.get(table).has(c)) problems.push({ table, column: c, problem: 'sutun yok' });
  }
  return problems;
}

module.exports = {
  loadMigrationSchema,
  extractSqlLiterals,
  looksLikeSql,
  normalizeSql,
  analyzeSql,
  checkStatements,
  collectStaticStatements,
  verifyLiveSchema,
  stripSqlComments,
  EXPR,
};
