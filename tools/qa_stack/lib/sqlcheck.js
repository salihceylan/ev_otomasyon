// Statik SQL denetimi (GERCEK PostgreSQL'e karsi): server/src ve server/scripts altindaki JS dosyalarini acorn ile
// ayristirir, `.query(...)` cagrilarinin SQL metinlerini cikarir ve her biri icin `PREPARE` calistirir.
//
// PREPARE yalnizca AYRISTIRIR + ANALIZ EDER (calistirmaz, yan etki yok); node-pg `pool.query(text, params)` da parametre
// tipi belirtmeden Parse eder, yani burada alinan hatalar (42703 eksik sutun, 42P01 eksik tablo, 42P10 ON CONFLICT
// belirtimi, 42P18 belirsiz parametre tipi, 0A000 `FOR UPDATE` + dis birlestirme, 42883 islev yok, 42804 tip uyusmazligi ...)
// calisma zamaninda da AYNEN olusur. Mock'lu testler bu sinifi yakalayamaz.
//
// Sinir: yalnizca STATIK cozulebilen metinler denetlenir (duz metin / sabit sablon / ayni dosyadaki sabit `const`'lar).
// `${...}` ile calisma zamaninda kurulan sorgular "dinamik" diye listelenir (denetlenmez). Veri kaynakli hatalar
// (kisit ihlali, gecersiz uuid metni vb.) kapsam disidir.
import fs from 'node:fs';
import path from 'node:path';
import * as acorn from 'acorn';
import pg from 'pg';
import { SERVER_DIR } from './paths.js';

const SKIP_DIRS = new Set(['node_modules', 'test', 'tests', '.git']);

export function collectJsFiles(dir) {
  const out = [];
  const walk = (d) => {
    for (const e of fs.readdirSync(d, { withFileTypes: true })) {
      if (e.isDirectory()) {
        if (!SKIP_DIRS.has(e.name)) walk(path.join(d, e.name));
      } else if (/\.js$/.test(e.name)) {
        out.push(path.join(d, e.name));
      }
    }
  };
  walk(dir);
  return out.sort();
}

function walk(node, visit) {
  if (!node || typeof node.type !== 'string') return;
  visit(node);
  for (const key of Object.keys(node)) {
    if (key === 'type' || key === 'loc' || key === 'start' || key === 'end') continue;
    const v = node[key];
    if (Array.isArray(v)) v.forEach((c) => walk(c, visit));
    else if (v && typeof v.type === 'string') walk(v, visit);
  }
}

/** Duz metin / sabit sablon / '+' birlesimi / ayni dosyadaki sabit const'lar -> metin. */
function evalStatic(node, consts) {
  if (!node) return { ok: false, reason: 'bos' };
  switch (node.type) {
    case 'Literal':
      return typeof node.value === 'string' ? { ok: true, value: node.value } : { ok: false, reason: 'metin degil' };
    case 'TemplateLiteral': {
      let out = '';
      for (let i = 0; i < node.quasis.length; i++) {
        out += node.quasis[i].value.cooked ?? node.quasis[i].value.raw;
        if (i < node.expressions.length) {
          const r = evalStatic(node.expressions[i], consts);
          if (!r.ok) return { ok: false, reason: `\${...} cozulemedi (${r.reason})` };
          out += r.value;
        }
      }
      return { ok: true, value: out };
    }
    case 'BinaryExpression': {
      if (node.operator !== '+') return { ok: false, reason: `operator ${node.operator}` };
      const a = evalStatic(node.left, consts);
      if (!a.ok) return a;
      const b = evalStatic(node.right, consts);
      if (!b.ok) return b;
      return { ok: true, value: a.value + b.value };
    }
    case 'Identifier':
      return consts.has(node.name) ? { ok: true, value: consts.get(node.name) } : { ok: false, reason: `degisken ${node.name}` };
    default:
      return { ok: false, reason: node.type };
  }
}

/** Bir dosyadaki sorgu cagrilarini cikarir: [{file, line, sql|null, dynamic}] */
export function extractStatements(file, source) {
  let ast;
  try {
    ast = acorn.parse(source, { ecmaVersion: 'latest', sourceType: 'script', allowReturnOutsideFunction: true, allowHashBang: true, locations: true });
  } catch (e) {
    return [{ file, line: e.loc ? e.loc.line : 0, sql: null, dynamic: `ayristirilamadi: ${e.message}`, parseError: true }];
  }
  // sabit metin const'lari (bildirim sirasindan bagimsiz: birkac tur)
  const decls = [];
  walk(ast, (n) => {
    if (n.type === 'VariableDeclarator' && n.id.type === 'Identifier' && n.init) decls.push(n);
  });
  const consts = new Map();
  for (let pass = 0; pass < 4; pass++) {
    let changed = false;
    for (const d of decls) {
      if (consts.has(d.id.name)) continue;
      const r = evalStatic(d.init, consts);
      if (r.ok) { consts.set(d.id.name, r.value); changed = true; }
    }
    if (!changed) break;
  }

  const out = [];
  walk(ast, (n) => {
    if (n.type !== 'CallExpression') return;
    const c = n.callee;
    const name = c.type === 'MemberExpression' && !c.computed && c.property.type === 'Identifier' ? c.property.name : c.type === 'Identifier' ? c.name : null;
    if (name !== 'query' || n.arguments.length === 0) return;
    const first = n.arguments[0];
    const r = evalStatic(first, consts);
    const line = first.loc ? first.loc.start.line : n.loc.start.line;
    if (r.ok) {
      // PG sorgusuna benzemeyen metinler (ornegin baska bir .query API'si) elenir
      if (!/^\s*(\(|--|\/\*)?\s*(with|select|insert|update|delete|merge|values|begin|commit|rollback|create|alter|drop|set|lock|truncate|savepoint|release|show|listen|notify|do|call)\b/i.test(r.value)) return;
      out.push({ file, line, sql: r.value, dynamic: null });
    } else if (first.type === 'TemplateLiteral' || first.type === 'Literal' || first.type === 'BinaryExpression') {
      out.push({ file, line, sql: null, dynamic: r.reason });
    }
    // Identifier / cagri ile gelen sorgu metinleri (degisken) dinamik sayilir
    else if (first.type === 'Identifier') {
      out.push({ file, line, sql: null, dynamic: r.reason });
    }
  });
  return out;
}

const PREPARABLE = /^\s*(?:\(\s*)*(with|select|insert|update|delete|merge|values)\b/i;

/**
 * @param {string} connectionString
 * @param {{file:string,line:number,sql:string|null,dynamic:string|null}[]} statements
 */
export async function checkAgainstDb(connectionString, statements) {
  const client = new pg.Client({ connectionString });
  client.on('error', () => {});
  await client.connect();
  const results = [];
  try {
    for (const st of statements) {
      if (!st.sql) { results.push({ ...st, status: 'dynamic' }); continue; }
      if (!PREPARABLE.test(st.sql)) { results.push({ ...st, status: 'skipped', note: 'DML degil (PREPARE kapsami disi)' }); continue; }
      try {
        await client.query('BEGIN');
        await client.query(`PREPARE qa_sqlcheck AS ${st.sql}`);
        await client.query('DEALLOCATE qa_sqlcheck'); // PREPARE oturum duzeyindedir (ROLLBACK geri almaz)
        results.push({ ...st, status: 'ok' });
      } catch (err) {
        const multi = /cannot insert multiple commands/i.test(err.message);
        results.push({
          ...st,
          status: multi ? 'skipped' : 'error',
          note: multi ? 'birden fazla ifade' : undefined,
          code: err.code,
          message: err.message,
          position: err.position ? Number(err.position) : undefined,
          snippet: err.position ? st.sql.slice(Math.max(0, Number(err.position) - 1), Number(err.position) + 70).replace(/\s+/g, ' ') : undefined,
        });
      } finally {
        await client.query('ROLLBACK').catch(() => {});
      }
    }
  } finally {
    await client.end().catch(() => {});
  }
  return results;
}

/** Tum server/src + server/scripts dosyalarini denetler. */
export async function runSqlCheck({ connectionString, serverDir = SERVER_DIR, dirs = ['src', 'scripts'] }) {
  const statements = [];
  for (const d of dirs) {
    const base = path.join(serverDir, d);
    if (!fs.existsSync(base)) continue;
    for (const f of collectJsFiles(base)) {
      const rel = path.relative(serverDir, f).replace(/\\/g, '/');
      statements.push(...extractStatements(rel, fs.readFileSync(f, 'utf8')));
    }
  }
  const results = await checkAgainstDb(connectionString, statements);
  const summary = {
    total: results.length,
    ok: results.filter((r) => r.status === 'ok').length,
    errors: results.filter((r) => r.status === 'error').length,
    dynamic: results.filter((r) => r.status === 'dynamic').length,
    skipped: results.filter((r) => r.status === 'skipped').length,
  };
  return { summary, results };
}
