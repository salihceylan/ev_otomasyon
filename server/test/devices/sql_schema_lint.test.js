'use strict';

// Statik SQL denetimi: WP-B kaynaklarindaki her SQL, migration dosyalarindan cikarilan SEMAYA gore dogrulanir
// (olmayan tablo / sutun, INSERT sutun listesi, UPDATE ... SET hedefleri, ON CONFLICT, RETURNING).
// Sahte veritabani (FakeDb) SQL'i calistirmadigi icin sutun adi hatalari testlerde yakalanmazdi
// (eski kodda endpoints.state / is_active / shutter_position bu sinifta bir hataydi).

const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..', '..');
const SOURCES = [
  'src/services/device_service.js',
  'src/services/endpoint_service.js',
  'src/services/mqtt_credential_service.js',
  'src/services/home_cleanup.js',
];

// ------------------------------------------------------------------------------------------------
// 1) Sema: migration dosyalarindan tablo -> sutun kumesi
// ------------------------------------------------------------------------------------------------
function splitTopLevel(text, sep = ',') {
  const parts = [];
  let depth = 0;
  let cur = '';
  let inStr = false;
  for (let i = 0; i < text.length; i++) {
    const ch = text[i];
    if (ch === "'") inStr = !inStr;
    if (!inStr) {
      if (ch === '(') depth++;
      else if (ch === ')') depth--;
      else if (ch === sep && depth === 0) {
        parts.push(cur);
        cur = '';
        continue;
      }
    }
    cur += ch;
  }
  if (cur.trim()) parts.push(cur);
  return parts;
}

function stripSqlComments(sql) {
  return sql.replace(/--[^\n]*/g, '').replace(/\/\*[\s\S]*?\*\//g, '');
}

function loadSchema() {
  const dir = path.join(ROOT, 'migrations');
  const files = fs.readdirSync(dir).filter((f) => /^\d+_.*\.sql$/.test(f)).sort();
  const schema = {};
  const CONSTRAINT_WORDS = new Set(['PRIMARY', 'UNIQUE', 'CONSTRAINT', 'CHECK', 'FOREIGN', 'EXCLUDE', 'LIKE']);

  for (const file of files) {
    const sql = stripSqlComments(fs.readFileSync(path.join(dir, file), 'utf8'));

    // CREATE TABLE
    for (const m of sql.matchAll(/CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?(\w+)\s*\(/gi)) {
      const table = m[1].toLowerCase();
      let depth = 1;
      let i = m.index + m[0].length;
      const start = i;
      while (i < sql.length && depth > 0) {
        if (sql[i] === '(') depth++;
        else if (sql[i] === ')') depth--;
        i++;
      }
      const body = sql.slice(start, i - 1);
      schema[table] = schema[table] || new Set();
      for (const part of splitTopLevel(body)) {
        const first = part.trim().split(/\s+/)[0];
        if (first && /^\w+$/.test(first) && !CONSTRAINT_WORDS.has(first.toUpperCase())) {
          schema[table].add(first.toLowerCase());
        }
      }
    }

    // ALTER TABLE ... ADD COLUMN [IF NOT EXISTS] col ...  (virgullu coklu ifadeler dahil)
    for (const m of sql.matchAll(/ALTER\s+TABLE\s+(?:IF\s+EXISTS\s+)?(\w+)\s+([^;]*);/gi)) {
      const table = m[1].toLowerCase();
      for (const part of splitTopLevel(m[2])) {
        const add = /^\s*ADD\s+COLUMN\s+(?:IF\s+NOT\s+EXISTS\s+)?(\w+)/i.exec(part);
        if (add) {
          schema[table] = schema[table] || new Set();
          schema[table].add(add[1].toLowerCase());
        }
      }
    }
  }
  return schema;
}

// ------------------------------------------------------------------------------------------------
// 2) JS kaynagindan dize sabitlerini cikar (yorumlar ve ic ice sablonlar dogru ele alinir)
// ------------------------------------------------------------------------------------------------
function extractStrings(src) {
  const out = [];
  let i = 0;
  const n = src.length;

  function readTemplate() {
    // src[i] === '`'
    i++;
    let text = '';
    let dynamic = false;
    while (i < n) {
      const ch = src[i];
      if (ch === '\\') {
        text += src[i + 1] || '';
        i += 2;
        continue;
      }
      if (ch === '`') {
        i++;
        return { text, dynamic };
      }
      if (ch === '$' && src[i + 1] === '{') {
        dynamic = true;
        let depth = 1;
        i += 2;
        while (i < n && depth > 0) {
          if (src[i] === '`') readTemplate();
          else if (src[i] === '{') { depth++; i++; }
          else if (src[i] === '}') { depth--; i++; }
          else i++;
        }
        text += '${...}';
        continue;
      }
      text += ch;
      i++;
    }
    return { text, dynamic };
  }

  while (i < n) {
    const ch = src[i];
    const next = src[i + 1];
    if (ch === '/' && next === '/') {
      while (i < n && src[i] !== '\n') i++;
    } else if (ch === '/' && next === '*') {
      i += 2;
      while (i < n && !(src[i] === '*' && src[i + 1] === '/')) i++;
      i += 2;
    } else if (ch === "'" || ch === '"') {
      const q = ch;
      i++;
      let text = '';
      while (i < n && src[i] !== q) {
        if (src[i] === '\\') {
          text += src[i + 1] || '';
          i += 2;
          continue;
        }
        if (src[i] === '\n') break;
        text += src[i];
        i++;
      }
      i++;
      out.push({ text, dynamic: false });
    } else if (ch === '`') {
      out.push(readTemplate());
    } else if (ch === '/' && /[=(,:;!&|?{}\[]/.test(src.slice(Math.max(0, i - 3), i).trim().slice(-1) || '(')) {
      // regex literal: atla
      i++;
      while (i < n && src[i] !== '/' && src[i] !== '\n') {
        if (src[i] === '\\') i++;
        i++;
      }
      i++;
    } else {
      i++;
    }
  }
  return out;
}

function isSql(text) {
  return /^\s*(SELECT|INSERT\s+INTO|UPDATE|DELETE\s+FROM|WITH)\b/i.test(text) && /\b(FROM|INTO|SET|VALUES|WHERE)\b/i.test(text);
}

// ------------------------------------------------------------------------------------------------
// 3) SQL analizi
// ------------------------------------------------------------------------------------------------
const RESERVED = new Set([
  'WHERE', 'SET', 'ON', 'JOIN', 'LEFT', 'RIGHT', 'INNER', 'OUTER', 'CROSS', 'FULL', 'FOR', 'ORDER', 'GROUP', 'LIMIT', 'OFFSET',
  'RETURNING', 'USING', 'VALUES', 'SELECT', 'AS', 'AND', 'OR', 'NOT', 'DO', 'NULL', 'UNION', 'HAVING', 'WHEN', 'THEN', 'ELSE',
  'END', 'CASE', 'IN', 'IS', 'LIKE', 'BETWEEN', 'ASC', 'DESC', 'NOWAIT', 'SKIP', 'OF', 'UPDATE', 'FROM', 'INTO',
  'FALSE', 'TRUE', 'DISTINCT',
]);
// Katalog goruntuleri tablo degildir.
const CATALOG_SCHEMAS = new Set(['information_schema', 'pg_catalog']);

function normalizeSql(text) {
  return text
    .replace(/--[^\n]*/g, ' ')
    .replace(/'(?:[^']|'')*'/g, "''") // dize sabitleri
    .replace(/\s+/g, ' ')
    .trim();
}

function analyze(sqlText, schema) {
  const problems = [];
  const sql = normalizeSql(sqlText);

  // tablo + takma ad haritasi
  const aliases = new Map(); // alias(lower) -> table
  const tables = [];
  for (const m of sql.matchAll(/\b(FROM|JOIN|UPDATE|INTO|USING)\s+(\w+)(\s*\()?(?:\s+(?:AS\s+)?(\w+))?/gi)) {
    const kw = m[1].toUpperCase();
    const name = m[2].toLowerCase();
    const isFunc = Boolean(m[3]) && kw !== 'INTO'; // generate_series(...), unnest(...)
    if (isFunc || RESERVED.has(name.toUpperCase()) || CATALOG_SCHEMAS.has(name)) continue;
    tables.push(name);
    if (!schema[name]) {
      problems.push(`olmayan tablo: ${name}`);
      continue;
    }
    aliases.set(name, name);
    const alias = m[4] && !RESERVED.has(m[4].toUpperCase()) && !m[3] ? m[4].toLowerCase() : null;
    if (alias) aliases.set(alias, name);
  }

  const has = (table, col) => schema[table] && schema[table].has(col.toLowerCase());

  // alias.sutun
  for (const m of sql.matchAll(/\b([a-z_]\w*)\.([a-z_]\w*)\b/gi)) {
    const alias = m[1].toLowerCase();
    const col = m[2].toLowerCase();
    if (alias === 'excluded' || alias === 'public' || alias === 'information_schema') continue;
    const table = aliases.get(alias);
    if (!table) continue; // fonksiyon takma adi (g, t), parametre vb.
    if (!has(table, col)) problems.push(`olmayan sutun: ${alias}.${col} (${table})`);
  }

  // INSERT INTO tablo (c1, c2, ...)
  for (const m of sql.matchAll(/\bINSERT\s+INTO\s+(\w+)\s*\(([^)]*)\)/gi)) {
    const table = m[1].toLowerCase();
    if (!schema[table]) continue;
    for (const col of m[2].split(',').map((c) => c.trim().toLowerCase()).filter(Boolean)) {
      if (!has(table, col)) problems.push(`INSERT olmayan sutun: ${table}.${col}`);
    }
  }

  // UPDATE tablo [alias] SET a = ..., b = ... [WHERE|FROM|RETURNING]
  for (const m of sql.matchAll(/\bUPDATE\s+(\w+)(?:\s+(?:AS\s+)?\w+)?\s+SET\s+(.+?)(?=\s+(?:WHERE|FROM|RETURNING)\b|$)/gi)) {
    const table = m[1].toLowerCase();
    if (!schema[table]) continue;
    for (const part of splitTopLevel(m[2])) {
      const col = /^\s*(\w+)\s*=/.exec(part);
      if (col && !has(table, col[1])) problems.push(`UPDATE SET olmayan sutun: ${table}.${col[1]}`);
    }
  }

  // ON CONFLICT (cols)
  const target = /\bINSERT\s+INTO\s+(\w+)/i.exec(sql);
  for (const m of sql.matchAll(/\bON\s+CONFLICT\s*\(([^)]*)\)/gi)) {
    if (!target) continue;
    const table = target[1].toLowerCase();
    for (const col of m[1].split(',').map((c) => c.trim().toLowerCase()).filter(Boolean)) {
      if (schema[table] && !has(table, col)) problems.push(`ON CONFLICT olmayan sutun: ${table}.${col}`);
    }
  }

  // RETURNING cols (INSERT/UPDATE/DELETE hedef tablosu)
  const dml = /\b(?:INSERT\s+INTO|UPDATE|DELETE\s+FROM)\s+(\w+)/i.exec(sql);
  const ret = /\bRETURNING\s+(.+?)$/i.exec(sql);
  if (dml && ret && schema[dml[1].toLowerCase()]) {
    const table = dml[1].toLowerCase();
    for (const part of splitTopLevel(ret[1])) {
      const word = /^\s*(\w+)\s*$/.exec(part);
      if (word && !has(table, word[1])) problems.push(`RETURNING olmayan sutun: ${table}.${word[1]}`);
    }
  }

  // Tek tablolu SELECT: secim listesindeki yalin sutun adlari
  const sel = /^SELECT\s+(.+?)\s+FROM\s+(\w+)(?:\s+(?:AS\s+)?(\w+))?(?=\s|$)/i.exec(sql);
  if (sel && !/\bJOIN\b/i.test(sql) && schema[sel[2].toLowerCase()]) {
    const table = sel[2].toLowerCase();
    for (const part of splitTopLevel(sel[1])) {
      const word = /^\s*(\w+)\s*$/.exec(part);
      if (word && !/^(count|true|false|null|\*)$/i.test(word[1]) && !has(table, word[1])) {
        problems.push(`SELECT olmayan sutun: ${table}.${word[1]}`);
      }
    }
  }

  return { problems, tables };
}

// ------------------------------------------------------------------------------------------------
const schema = loadSchema();

test('sema cikarimi: beklenen tablolar ve WP-B sutunlari mevcut (cikarim dogrulugu)', () => {
  for (const table of [
    'users', 'homes', 'home_users', 'devices', 'endpoints', 'device_inventory', 'device_claim_otps', 'commissioning_logs',
    'commissioning_checks', 'emergency_reset_logs', 'device_replacement_logs', 'peace_notification_logs', 'device_audit_logs',
    'mqtt_credentials', 'mqtt_acl', 'home_invitations', 'home_transfers', 'service_tokens',
  ]) {
    assert.ok(schema[table] && schema[table].size > 0, `sema cikarilamadi: ${table}`);
  }
  // 001 CREATE TABLE
  for (const col of ['id', 'home_id', 'device_uuid', 'mac_address', 'setup_pin', 'is_online', 'last_seen_at']) assert.ok(schema.devices.has(col), `devices.${col}`);
  // ALTER TABLE ... ADD COLUMN (coklu ifade: 006)
  for (const col of ['is_commissioned', 'commissioned_at', 'commissioned_by', 'commissioning_status', 'commissioning_notes']) assert.ok(schema.devices.has(col), `devices.${col}`);
  // 021
  for (const col of ['local_key_enc', 'name']) assert.ok(schema.devices.has(col), `devices.${col}`);
  assert.ok(schema.device_inventory.has('local_key_enc'));
  assert.ok(schema.device_claim_otps.has('window_started_at'));
  // endpoints: gercek sutunlar (eski koddaki state/is_active/shutter_position YOK)
  assert.ok(schema.endpoints.has('current_state') && schema.endpoints.has('current_position'));
  assert.ok(!schema.endpoints.has('state') && !schema.endpoints.has('is_active') && !schema.endpoints.has('shutter_position'));
  // A'nin 018 migration'i (varsa): users.account_status
  assert.ok(schema.users.has('account_status'), 'users.account_status (018) bulunamadi');
});

for (const rel of SOURCES) {
  test(`SQL semaya uyumlu: ${rel}`, () => {
    const src = fs.readFileSync(path.join(ROOT, rel), 'utf8');
    const statements = extractStrings(src).filter((s) => isSql(s.text));
    assert.ok(statements.length > 0, 'SQL cikarilamadi');

    const all = [];
    let dynamicCount = 0;
    for (const s of statements) {
      if (s.dynamic) {
        dynamicCount++;
        continue;
      }
      const { problems } = analyze(s.text, schema);
      if (problems.length) all.push(`${problems.join('; ')}\n    -> ${normalizeSql(s.text).slice(0, 160)}`);
    }
    assert.deepStrictEqual(all, [], `\n${all.join('\n')}`);
    // dinamik (sabit liste) SQL yalnizca home_cleanup.js'te olabilir
    if (rel !== 'src/services/home_cleanup.js') assert.strictEqual(dynamicCount, 0, 'dinamik SQL (sablon degiskeni) olmamali');
  });
}

test('home_cleanup.js: dinamik SQL\'deki tablo adlari SABIT listeden ve ev kapsamli (home_id sutunlu)', () => {
  const src = fs.readFileSync(path.join(ROOT, 'src/services/home_cleanup.js'), 'utf8');
  const names = new Set();
  for (const m of src.matchAll(/(?:deleteByHome|revokeOrDeleteByHome|isHomeScoped|tableExists|columnExists)\(\s*tx,\s*'(\w+)'/g)) names.add(m[1]);
  for (const m of src.matchAll(/record\('(\w+)'/g)) names.add(m[1]);
  assert.ok(names.size >= 7, [...names].join(','));
  for (const name of names) {
    assert.ok(schema[name], `sema'da olmayan tablo: ${name}`);
    assert.ok(schema[name].has('home_id') || name === 'scheduled_rule_runs', `${name}: home_id sutunu yok`);
  }
  // iptal destekleyen tablolar revoked_at sutunuyla (A'nin 018'i)
  assert.ok(schema.service_sessions.has('revoked_at') && schema.service_sessions.has('revoked_reason'));
  assert.ok(schema.service_tokens.has('revoked_at'));
  // dinamik SQL yalnizca bu iki yardimci icinde ve tablo adi parametresi sabit listeden gelir
  const dyn = extractStrings(src).filter((s) => s.dynamic && isSql(s.text));
  for (const s of dyn) assert.match(normalizeSql(s.text), /^(DELETE FROM \$\{\.\.\.\}|UPDATE \$\{\.\.\.\} SET)/);
});

test('linter kendi kendini sinar: bilinen hatali SQL\'leri yakalar (eski koddaki hatalar dahil)', () => {
  const bad = [
    ["SELECT e.id, e.state FROM endpoints e WHERE e.home_id = $1", /olmayan sutun: e\.state/],
    ["SELECT e.id FROM endpoints e WHERE e.is_active = true", /olmayan sutun: e\.is_active/],
    ["SELECT e.shutter_position FROM endpoints e", /olmayan sutun: e\.shutter_position/],
    ["INSERT INTO devices (home_id, cok_olmayan) VALUES ($1, $2)", /INSERT olmayan sutun: devices\.cok_olmayan/],
    ["UPDATE endpoints SET state = 'OFF', is_active = false WHERE home_id = $1", /UPDATE SET olmayan sutun: endpoints\.state/],
    ["SELECT id FROM olmayan_tablo WHERE id = $1", /olmayan tablo: olmayan_tablo/],
    ["INSERT INTO devices (home_id) VALUES ($1) ON CONFLICT (yok_sutun) DO NOTHING", /ON CONFLICT olmayan sutun/],
    ["UPDATE homes SET name = $1 WHERE id = $2 RETURNING id, yok", /RETURNING olmayan sutun: homes\.yok/],
    ["SELECT id, yok_sutun FROM homes WHERE id = $1", /SELECT olmayan sutun: homes\.yok_sutun/],
  ];
  for (const [sql, expected] of bad) {
    const { problems } = analyze(sql, schema);
    assert.ok(problems.some((p) => expected.test(p)), `yakalanamadi: ${sql} -> ${JSON.stringify(problems)}`);
  }
  // dogru SQL temiz
  const good = analyze(
    `SELECT e.id, e.current_state, d.device_uuid FROM endpoints e JOIN devices d ON d.id = e.device_id WHERE e.home_id = $1`,
    schema
  );
  assert.deepStrictEqual(good.problems, []);
});
