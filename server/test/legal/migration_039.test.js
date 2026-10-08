'use strict';

// Migration 039 (yasal metin kabulleri) - STATIK sozlesme (PG'siz). Gercek PG: legal_pg.test.js (tam zincir) ve
// legal_pre039_pg.test.js (038'de kalmis veritabaninda yeni kodun dayanikliligi).
//   - 038'den sonra; ASCII + LF; baslik yorumu; lock_timeout; transaction komutu yok; yalniz idempotent DDL
//   - users.terms_version INTEGER NULL, users.terms_accepted_at TIMESTAMPTZ NULL
//   - legal_acceptances(id BIGSERIAL PK, user_id UUID FK users ON DELETE CASCADE, document CHECK terms|privacy,
//     version CHECK > 0, accepted_at DEFAULT now(), ip_address, user_agent) + (user_id, document, accepted_at DESC)
//   - sema-sozlesme denetcisi (scripts/check_schema_contract) yeni tablo/kolonlari goruyor; 039 gizlenirse kodun
//     kullanimi YAKALANIYOR (olumsuz kontrol)

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const DIR = path.join(__dirname, '..', '..', 'migrations');
const FILE = '039_legal_acceptances.sql';
const SQL = fs.readFileSync(path.join(DIR, FILE), 'utf8');
const body = SQL.replace(/--[^\n]*/g, '');

test('039: 038 den sonra; ASCII + LF; baslik; lock_timeout; transaction komutu yok; veri degistirmez', () => {
  const files = fs.readdirSync(DIR).filter((f) => /^\d{3}.*\.sql$/.test(f)).sort();
  assert.ok(files.indexOf(FILE) > files.indexOf('038_replace_board_repairs.sql'));
  assert.equal(files.filter((f) => f.startsWith('039')).length, 1, '039 tek dosya');
  assert.equal(/[^\x00-\x7f]/.test(SQL), false, 'ASCII');
  assert.equal(SQL.includes('\r'), false, 'LF');
  assert.match(SQL, /^-- =+\n-- Migration 039/m, 'baslik yorumu');
  assert.match(body, /SET LOCAL lock_timeout = '5s';/);
  assert.doesNotMatch(body, /^\s*(BEGIN|COMMIT|ROLLBACK)\s*;/im);
  assert.doesNotMatch(body, /\bINSERT INTO\b|\bUPDATE\s+\w+\s+SET\b|\bDELETE FROM\b|\bDROP\b/i);
});

test('039: users kolonlari ve legal_acceptances tablosu idempotent ve sozlesmedeki tanimla', () => {
  assert.match(body, /ALTER TABLE users ADD COLUMN IF NOT EXISTS terms_version INTEGER;/);
  assert.match(body, /ALTER TABLE users ADD COLUMN IF NOT EXISTS terms_accepted_at TIMESTAMPTZ;/);
  const m = /CREATE TABLE IF NOT EXISTS legal_acceptances \(([\s\S]*?)\n\);/.exec(body);
  assert.ok(m, 'CREATE TABLE IF NOT EXISTS legal_acceptances');
  const cols = m[1].split('\n').map((l) => l.trim().replace(/,$/, '').replace(/\s+/g, ' ')).filter(Boolean);
  assert.deepEqual(cols, [
    'id BIGSERIAL PRIMARY KEY',
    'user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE',
    "document TEXT NOT NULL CHECK (document IN ('terms', 'privacy'))",
    'version INTEGER NOT NULL CHECK (version > 0)',
    'accepted_at TIMESTAMPTZ NOT NULL DEFAULT now()',
    'ip_address TEXT NULL',
    'user_agent TEXT NULL',
  ]);
  assert.match(body, /CREATE INDEX IF NOT EXISTS idx_legal_acceptances_user_doc\s+ON legal_acceptances \(user_id, document, accepted_at DESC\);/);
});

test('039: sema yukleyicisi yeni tablo ve kolonlari goruyor', () => {
  const { loadSchema } = require('../../scripts/check_schema_contract');
  const schema = loadSchema();
  for (const c of ['terms_version', 'terms_accepted_at']) assert.ok(schema.get('users').has(c), c);
  const t = schema.get('legal_acceptances');
  assert.ok(t, 'legal_acceptances');
  for (const c of ['id', 'user_id', 'document', 'version', 'accepted_at', 'ip_address', 'user_agent']) assert.ok(t.has(c), c);
});

test('OLUMSUZ KONTROL: 039 gizlenirse kodun legal_acceptances ve users.terms_* kullanimi YAKALANIR', async () => {
  const contract = require('../../scripts/lib/sql_contract');
  const { check, RUNTIME_TABLES } = require('../../scripts/check_schema_contract');
  const fsApi = {
    readdirSync: (dir, opts) => fs.readdirSync(dir, opts).filter((e) => (typeof e === 'string' ? e : e.name) !== FILE),
    readFileSync: fs.readFileSync,
  };
  const schema = contract.loadMigrationSchema(DIR, fsApi);
  for (const [t, cols] of Object.entries(RUNTIME_TABLES)) schema.set(t, new Set(cols));
  assert.equal(schema.has('legal_acceptances'), false, 'on kosul: 039 gizli');

  const r = await check({ schema, includeCapture: false });
  const all = [...r.strict, ...r.advisory];
  assert.ok(all.some((v) => v.kind === 'unknown-table' && v.table === 'legal_acceptances'), 'tablo yakalanir');
  assert.ok(all.some((v) => v.table === 'users' && v.column === 'terms_version'), 'users.terms_version yakalanir');
  assert.ok(all.every((v) => /legal|auth_service/.test(v.where)), `yalniz yasal metin kodu: ${all.map((v) => v.where).join(', ')}`);
});
