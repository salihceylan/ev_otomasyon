'use strict';

// SERVIS-01 - STATIK migration testi (032_local_key_pending.sql). Gercek veritabani YOK (gercek PostgreSQL
// davranisi: local_key_pending_pg.test.js): idempotent ifadeler, BEGIN/COMMIT yoklugu, iki kolon (tip + aciklama),
// bekleyen anahtari yalniz SAHIPSIZ kayitta dogrudan anahtar degisiminde temizleyen tetikleyici, kapsam siniri,
// siralama ve kod <-> sema baglantisi.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const SERVER = path.join(__dirname, '..', '..');
const DIR = path.join(SERVER, 'migrations');
const FILE = '032_local_key_pending.sql';
const PREV = '031_endpoint_layout_sync.sql';
const raw = fs.readFileSync(path.join(DIR, FILE), 'utf8');

/**
 * Yorumlari atar ve ifadelere boler: tek tirnakli dizeleri ('' kacisi dahil) ve $$ ... $$ govdelerini TANIR
 * (fonksiyon govdesindeki `;` ifadeyi bolmez).
 */
function parseSql(sql) {
  const statements = [];
  let current = '';
  let i = 0;
  while (i < sql.length) {
    const c = sql[i];
    if (c === '-' && sql[i + 1] === '-') {
      const end = sql.indexOf('\n', i);
      i = end === -1 ? sql.length : end;
      continue;
    }
    if (c === '$' && sql[i + 1] === '$') {
      const end = sql.indexOf('$$', i + 2);
      assert.ok(end > 0, 'kapanmamis $$ govdesi');
      current += sql.slice(i, end + 2);
      i = end + 2;
      continue;
    }
    if (c === "'") {
      let j = i + 1;
      for (;;) {
        const k = sql.indexOf("'", j);
        assert.ok(k > 0, 'kapanmamis dize');
        if (sql[k + 1] === "'") {
          j = k + 2;
          continue;
        }
        current += sql.slice(i, k + 1);
        i = k + 1;
        break;
      }
      continue;
    }
    if (c === ';') {
      statements.push(current);
      current = '';
      i += 1;
      continue;
    }
    current += c;
    i += 1;
  }
  statements.push(current);
  return statements.map((s) => s.replace(/\s+/g, ' ').trim()).filter(Boolean);
}

const statements = parseSql(raw);
const COLUMNS = ['local_key_pending_enc', 'local_key_pending_at'];

test('numara: 032 yalnizca bu dosyada; 031\'den hemen sonra; calistirici surum 32 olarak listeler', () => {
  const names = fs.readdirSync(DIR).filter((n) => /\.sql$/.test(n));
  assert.deepEqual(names.filter((n) => n.startsWith('032')), [FILE]);
  const sorted = names.slice().sort();
  assert.equal(sorted.indexOf(FILE), sorted.indexOf(PREV) + 1, '031 ile 032 arasinda baska dosya yok');
  const { listMigrationFiles, versionOf, planMigrations } = require('../../scripts/migrate');
  assert.equal(versionOf(FILE), 32);
  const files = listMigrationFiles(DIR);
  const upTo031 = files.filter((f) => f.version <= 31).map((f) => f.name);
  const plan = planMigrations(files, new Map(upTo031.map((n) => [n, { checksum: null, baseline: false }])));
  assert.deepEqual(plan.pending.map((f) => f.name), [FILE]);
  assert.deepEqual(plan.outOfOrder, []);
});

test('baslik: IDEMPOTENT ve BEGIN/COMMIT YOK notu, kapsam/bagimlilik/rolling deploy; govdede islem kontrolu yok', () => {
  const lines = raw.split('\n');
  assert.match(lines[1], /^-- Migration 032: .*\(SERVIS-01\)$/);
  const head = lines.slice(0, 8).join('\n');
  assert.match(head, /IDEMPOTENT/);
  assert.match(head, /BEGIN\/COMMIT YOKTUR/);
  assert.ok(head.includes(`psql -1 -v ON_ERROR_STOP=1 -f ${FILE}`));
  const header = raw.slice(0, raw.indexOf('ALTER TABLE'));
  assert.match(header, /^-- Kapsam$/m);
  assert.match(header, /^-- Bagimlilik/m);
  assert.match(header, /^-- Rolling deploy:/m);
  const { findTransactionControl, hasNoTransactionDirective, stripTransactionWrapper } = require('../../scripts/migrate');
  assert.deepEqual(findTransactionControl(raw), []);
  assert.equal(hasNoTransactionDirective(raw), false, 'tek transaction icinde calisir');
  assert.equal(stripTransactionWrapper(raw).stripped, false);
});

test('kolonlar: tam iki ADD COLUMN IF NOT EXISTS (local_key_enc ile ayni tip TEXT + TIMESTAMPTZ); DEFAULT/NOT NULL yok', () => {
  const adds = statements.filter((s) => /ADD COLUMN/i.test(s));
  assert.deepEqual(adds, [
    'ALTER TABLE devices ADD COLUMN IF NOT EXISTS local_key_pending_enc TEXT',
    'ALTER TABLE devices ADD COLUMN IF NOT EXISTS local_key_pending_at TIMESTAMPTZ',
  ]);
  // local_key_enc (021) ile ayni tip
  assert.match(fs.readFileSync(path.join(DIR, '021_device_security_hardening.sql'), 'utf8'), /ADD COLUMN IF NOT EXISTS local_key_enc TEXT;/);
});

test('aciklamalar: iki kolon icin COMMENT ON COLUMN (sifreli, anahtar duz metin degil, uzlastirici iletir)', () => {
  const comment = (col) => statements.find((s) => s.startsWith(`COMMENT ON COLUMN devices.${col} IS '`));
  for (const col of COLUMNS) assert.ok(comment(col), `aciklama yok: ${col}`);
  assert.match(comment('local_key_pending_enc'), /SERVIS-01/);
  assert.match(comment('local_key_pending_enc'), /secret_box|sifreli/i);
  assert.match(comment('local_key_pending_enc'), /uzlastirici/i);
});

test('tetikleyici: idempotent (CREATE OR REPLACE FUNCTION + ayni adli DROP TRIGGER IF EXISTS), yalniz local_key_enc guncellemesinde ve SAHIPSIZ kayitta', () => {
  const fn = statements.find((s) => /^CREATE OR REPLACE FUNCTION devices_clear_superseded_pending_key\(\)/i.test(s));
  assert.ok(fn, 'fonksiyon yok');
  assert.match(fn, /RETURNS TRIGGER/i);
  assert.match(fn, /NEW\.local_key_pending_enc := NULL/);
  assert.match(fn, /NEW\.local_key_pending_at := NULL/);
  const dropIdx = statements.findIndex((s) => s === 'DROP TRIGGER IF EXISTS trg_devices_pending_key_superseded ON devices');
  const createIdx = statements.findIndex((s) => /^CREATE TRIGGER trg_devices_pending_key_superseded\b/.test(s));
  assert.ok(dropIdx >= 0 && createIdx > dropIdx, 'DROP TRIGGER IF EXISTS, CREATE TRIGGER\'dan once');
  const trg = statements[createIdx];
  assert.match(trg, /BEFORE UPDATE OF local_key_enc ON devices/);
  assert.match(trg, /FOR EACH ROW/);
  for (const cond of [
    'OLD.local_key_pending_enc IS NOT NULL',
    'NEW.home_id IS NULL',
    'NEW.local_key_enc IS DISTINCT FROM OLD.local_key_enc',
    'NEW.local_key_pending_enc IS NOT DISTINCT FROM OLD.local_key_pending_enc',
  ]) {
    assert.ok(trg.includes(cond), `WHEN kosulu eksik: ${cond}`);
  }
  assert.match(trg, /EXECUTE FUNCTION devices_clear_superseded_pending_key\(\)/);
});

test('kapsam siniri: yalniz devices; veri silen/degistiren ifade YOK; beklenen ifade sayisi', () => {
  for (const s of statements) {
    assert.doesNotMatch(s, /^(DELETE|UPDATE|TRUNCATE|INSERT|GRANT|REVOKE)\b/i, s);
    assert.doesNotMatch(s, /\bDROP (COLUMN|TABLE|INDEX)\b/i, s);
    assert.doesNotMatch(s, /^ALTER TABLE (?!devices\b)/i, s);
  }
  // 2 ADD COLUMN + 2 COMMENT + FUNCTION + DROP TRIGGER + CREATE TRIGGER
  assert.equal(statements.length, 7, statements.join('\n'));
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

test('sema yukleyicisi: kod <-> migration sozlesmesi yeni kolonlari 032\'den okur (032 olmadan YOK)', () => {
  const { loadMigrationSchema } = require('../../scripts/lib/sql_contract');
  const devices = loadMigrationSchema(DIR).get('devices');
  for (const col of COLUMNS) assert.ok(devices.has(col), `devices.${col} semada yok`);
  const fsApi = {
    readdirSync: (dir, opts) => fs.readdirSync(dir, opts).filter((e) => e.name !== FILE),
    readFileSync: (p, enc) => fs.readFileSync(p, enc),
  };
  const without = loadMigrationSchema(DIR, fsApi).get('devices');
  for (const col of COLUMNS) assert.equal(without.has(col), false, `${col} yalniz 032'de tanimli olmali`);
});
