'use strict';

// WP-L - STATIK migration testi (031_endpoint_layout_sync.sql). Gercek veritabani YOK:
// dosya okunur; idempotent ifadeler, BEGIN/COMMIT yoklugu, iki kolonun adi/tipi, kapsam siniri
// (yalniz `devices`; endpoints/homes'a dokunmaz, veri degistirmez), siralama (030'dan sonra, son dosya)
// ve kod <-> sema baglantisi (sema yukleyicisi, taban bicimi) denetlenir.
// Tasarim: docs/superpowers/specs/2026-10-03-uc-nokta-yerlesim-esitleme-design.md (bolum 7).

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const SERVER = path.join(__dirname, '..', '..');
const DIR = path.join(SERVER, 'migrations');
const FILE = '031_endpoint_layout_sync.sql';
const PREV = '030_peace_reminder.sql';
const raw = fs.readFileSync(path.join(DIR, FILE), 'utf8');

/**
 * Yorumlari atar ve ifadelere boler. Tek tirnakli dizeleri TANIR: COMMENT metni icinde `;` var
 * (duz `split(';')` ifadeyi ortadan bolerdi). Dize icindeki '' kacisi desteklenir.
 * @returns {{ code:string, statements:string[] }}
 */
function parseSql(sql) {
  let code = '';
  const statements = [];
  let current = '';
  let inString = false;
  for (let i = 0; i < sql.length; i += 1) {
    const c = sql[i];
    if (inString) {
      current += c;
      code += c;
      if (c === "'") {
        if (sql[i + 1] === "'") {
          current += "'";
          code += "'";
          i += 1;
        } else {
          inString = false;
        }
      }
      continue;
    }
    if (c === '-' && sql[i + 1] === '-') {
      const end = sql.indexOf('\n', i);
      i = (end === -1 ? sql.length : end) - 1;
      continue;
    }
    code += c;
    if (c === "'") inString = true;
    if (c === ';') {
      statements.push(current);
      current = '';
      continue;
    }
    current += c;
  }
  assert.equal(inString, false, 'kapanmamis dize');
  statements.push(current);
  return { code, statements: statements.map((s) => s.replace(/\s+/g, ' ').trim()).filter(Boolean) };
}

const { code, statements } = parseSql(raw);

const COLUMNS = ['reported_layout', 'reported_layout_at'];

test('numara: 031 yalnizca bu dosyada; 030\'dan sonra ve duz metin siralamasinda SON dosya', () => {
  const names = fs.readdirSync(DIR).filter((n) => /\.sql$/.test(n));
  assert.deepEqual(names.filter((n) => n.startsWith('031')), [FILE]);
  assert.ok(names.includes(PREV), 'onkosul 030 mevcut');
  const sorted = names.slice().sort();
  assert.ok(sorted.indexOf(FILE) > sorted.indexOf(PREV));
  assert.equal(sorted.indexOf(FILE), sorted.indexOf(PREV) + 1, '030 ile 031 arasinda baska dosya yok');
});

test('calistirici: listMigrationFiles 031\'i surum 31 olarak, 030\'dan hemen sonra listeler; 31 numarasi tek', () => {
  const { listMigrationFiles, versionOf } = require('../../scripts/migrate');
  assert.equal(versionOf(FILE), 31);
  const files = listMigrationFiles(DIR);
  const names = files.map((f) => f.name);
  assert.equal(names.indexOf(FILE), names.indexOf(PREV) + 1);
  assert.equal(files.filter((f) => f.version === 31).length, 1);
  // bos bir veritabaninda 030 uygulanmisken yalniz 031 bekler ve sira disi sayilmaz
  const { planMigrations } = require('../../scripts/migrate');
  const applied = new Map(names.filter((n) => n !== FILE).map((n) => [n, { checksum: null, baseline: false }]));
  const plan = planMigrations(files, applied);
  assert.deepEqual(plan.pending.map((f) => f.name), [FILE]);
  assert.deepEqual(plan.outOfOrder, []);
});

test('baslik: IDEMPOTENT ve BEGIN/COMMIT YOK notu, kapsam/bagimlilik/rolling deploy; govdede islem kontrolu yok', () => {
  const lines = raw.split('\n');
  assert.match(lines[1], /^-- Migration 031: .*\(WP-L\)$/);
  const head = lines.slice(0, 8).join('\n');
  assert.match(head, /IDEMPOTENT/);
  assert.match(head, /BEGIN\/COMMIT YOKTUR/);
  assert.ok(head.includes(`psql -1 -v ON_ERROR_STOP=1 -f ${FILE}`), 'elle calistirma satiri kendi dosya adini tasir');
  const header = raw.slice(0, raw.indexOf('ALTER TABLE'));
  assert.match(header, /^-- Kapsam$/m);
  assert.match(header, /^-- Bagimlilik/m);
  assert.match(header, /^-- Rolling deploy:/m);
  assert.doesNotMatch(code, /\b(BEGIN|COMMIT|ROLLBACK|START\s+TRANSACTION)\b/i);
  const { findTransactionControl, hasNoTransactionDirective, stripTransactionWrapper } = require('../../scripts/migrate');
  assert.deepEqual(findTransactionControl(raw), []);
  assert.equal(hasNoTransactionDirective(raw), false, 'tek transaction icinde calisir');
  assert.equal(stripTransactionWrapper(raw).stripped, false);
});

test('kolonlar: tam iki ADD COLUMN IF NOT EXISTS; reported_layout JSONB, reported_layout_at TIMESTAMPTZ', () => {
  const adds = statements.filter((s) => /ADD COLUMN/i.test(s));
  assert.deepEqual(adds, [
    'ALTER TABLE devices ADD COLUMN IF NOT EXISTS reported_layout JSONB',
    'ALTER TABLE devices ADD COLUMN IF NOT EXISTS reported_layout_at TIMESTAMPTZ',
  ]);
  for (const s of statements) {
    if (/^ALTER TABLE \S+ ADD COLUMN/i.test(s)) assert.match(s, /ADD COLUMN IF NOT EXISTS/i, s);
  }
});

test('mevcut satirlara dokunmaz: kolonlar NULL olabilir, DEFAULT/NOT NULL/kisit/indeks yok (tablo yeniden yazilmaz)', () => {
  for (const s of statements.filter((x) => /ADD COLUMN/i.test(x))) {
    assert.doesNotMatch(s, /\b(NOT NULL|DEFAULT|REFERENCES|CHECK|UNIQUE)\b/i, s);
  }
  for (const s of statements) {
    assert.doesNotMatch(s, /^CREATE\b/i, s);
    assert.doesNotMatch(s, /\b(ADD CONSTRAINT|DROP CONSTRAINT|ALTER COLUMN|RENAME)\b/i, s);
  }
});

test('kapsam siniri: yalniz devices; endpoints/homes ve diger tablolara dokunmaz; veri silen/degistiren ifade YOK', () => {
  for (const s of statements) {
    assert.doesNotMatch(s, /^ALTER TABLE (IF EXISTS )?(ONLY )?(public\.)?(homes|users|endpoints|home_users|scheduled_rules|device_audit_logs)\b/i, s);
    assert.doesNotMatch(s, /^(DELETE|UPDATE|TRUNCATE|DROP|INSERT|GRANT|REVOKE)\b/i, s);
    assert.doesNotMatch(s, /\bDROP (COLUMN|TABLE|INDEX)\b/i, s);
  }
  const tables = new Set();
  for (const s of statements) {
    const m = /^(?:ALTER TABLE|CREATE TABLE IF NOT EXISTS|COMMENT ON TABLE)\s+(\w+)/i.exec(s) || /^COMMENT ON COLUMN\s+(\w+)\./i.exec(s);
    assert.ok(m, `taninmayan ifade: ${s}`);
    tables.add(m[1].toLowerCase());
  }
  assert.deepEqual([...tables], ['devices']);
  // yalniz ALTER TABLE ... ADD COLUMN ve COMMENT ON COLUMN: 2 + 2 ifade
  assert.equal(statements.length, 4);
});

test('aciklamalar: iki kolon icin COMMENT ON COLUMN; taban bicimi (v, relays, id/type/name) belgeli', () => {
  const comment = (col) => statements.find((s) => s.startsWith(`COMMENT ON COLUMN devices.${col} IS '`));
  for (const col of COLUMNS) {
    const s = comment(col);
    assert.ok(s, `aciklama yok: ${col}`);
    assert.match(s, /'$/, col);
  }
  const layout = comment('reported_layout');
  assert.match(layout, /WP-L/);
  assert.match(layout, /NULL = /, 'NULL anlami belgeli (bu panoyla hic esitlenmedi)');
  // belgelenen bicim, cekirdegin gercekten yazdigi tabanla ayni anahtarlari tasir
  const { serializeBase } = require('../../src/utils/endpoint_layout');
  const base = serializeBase({ relays: [{ id: 1, type: 'light', name: 'x', state: true }] });
  assert.deepEqual(Object.keys(base), ['v', 'relays']);
  assert.ok(layout.includes(`"v":${base.v}`), 'taban surumu aciklamada');
  for (const key of Object.keys(base.relays[0])) assert.ok(layout.includes(`"${key}"`), `anahtar ${key}`);
  assert.ok(layout.includes('"relays"'));
});

test('bicim: yalniz ASCII, satir sonu LF, gorunmez/kontrol karakteri yok, dosya LF ile biter', () => {
  const bad = [];
  let line = 1;
  for (let i = 0; i < raw.length; i += 1) {
    const cp = raw.charCodeAt(i);
    if (cp === 10) {
      line += 1;
      continue;
    }
    if (cp < 32 || cp > 126) bad.push(`${line}: kod ${cp}`);
  }
  assert.deepEqual(bad, []);
  assert.equal(raw.charCodeAt(raw.length - 1), 10);
});

test('sir/kisisel veri yok: baglanti dizesi, ozet, parola atamasi icermez', () => {
  assert.doesNotMatch(raw, /postgres(?:ql)?:\/\//i);
  assert.doesNotMatch(raw, /\b[0-9a-f]{64}\b/i);
  assert.doesNotMatch(raw, /\$2[aby]\$\d\d\$/);
  assert.doesNotMatch(raw, /\b(password|passwd|secret|token)\s*[:=]/i);
});

test('sema yukleyicisi: kod <-> migration sozlesmesi devices.reported_layout(_at) kolonlarini 031\'den okur', () => {
  const { loadMigrationSchema } = require('../../scripts/lib/sql_contract');
  const devices = loadMigrationSchema(DIR).get('devices');
  assert.ok(devices, 'devices tablosu semada');
  for (const col of COLUMNS) assert.ok(devices.has(col), `devices.${col} semada yok`);

  // olumsuz kontrol: 031 olmadan bu kolonlar semada YOKTUR (baska migration tanimlamiyor)
  const fsApi = {
    readdirSync: (dir, opts) => fs.readdirSync(dir, opts).filter((e) => e.name !== FILE),
    readFileSync: (p, enc) => fs.readFileSync(p, enc),
  };
  const without = loadMigrationSchema(DIR, fsApi).get('devices');
  for (const col of COLUMNS) assert.equal(without.has(col), false, `${col} yalniz 031'de tanimli olmali`);
});

test('servis SQL\'i (varsa) yalniz 031\'in tanimladigi reported_* kolonlarini kullanir', (t) => {
  const file = path.join(SERVER, 'src', 'services', 'endpoint_layout_sync.js');
  if (!fs.existsSync(file)) {
    t.skip('servis henuz yazilmadi (plan Task 3)');
    return;
  }
  const src = fs.readFileSync(file, 'utf8');
  const used = new Set(src.match(/\breported_layout\w*/g) || []);
  assert.ok(used.has('reported_layout'), 'servis tabani okur/yazar');
  for (const c of used) assert.ok(COLUMNS.includes(c), `devices.${c} 031 tarafindan olusturulmuyor`);
});
