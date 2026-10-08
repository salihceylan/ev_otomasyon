'use strict';

// Faz 1 / IP-1.1: migration 035 (site, daire, sablon, surum, yazim kaydi, devices.template_*) - STATIK sozlesme (PG'siz).
// Gercek PostgreSQL ile iki kez calistirma ve degismezlik: migration_035_pg.test.js.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const DIR = path.join(__dirname, '..', '..', 'migrations');
const FILE = '035_sites_templates.sql';
const SQL = fs.readFileSync(path.join(DIR, FILE), 'utf8');
const body = SQL.replace(/--[^\n]*/g, '');

test('035: siralama 034\'ten sonra; transaction komutu yok (calistirici sarar)', () => {
  const files = fs.readdirSync(DIR).filter((f) => /^\d{3}.*\.sql$/.test(f)).sort();
  assert.ok(files.includes('034_peace_skipped_hazard.sql'));
  assert.ok(files.indexOf(FILE) > files.indexOf('034_peace_skipped_hazard.sql'));
  assert.doesNotMatch(body, /^\s*(BEGIN|COMMIT|ROLLBACK)\s*;/im);
});

test('035: idempotent ifadeler (IF NOT EXISTS / DROP IF EXISTS / OR REPLACE)', () => {
  for (const m of body.matchAll(/CREATE\s+(UNIQUE\s+)?(TABLE|INDEX)\s+(\S+)/gi)) {
    assert.match(m[3], /^IF$/i, `${m[0]} IF NOT EXISTS olmali`);
  }
  for (const m of body.matchAll(/ADD COLUMN\s+(\S+)/gi)) assert.equal(m[1].toUpperCase(), 'IF', m[0]);
  assert.match(body, /CREATE OR REPLACE FUNCTION install_template_versions_immutable/);
  assert.match(body, /DROP TRIGGER IF EXISTS trg_install_template_versions_immutable ON install_template_versions;\s*CREATE TRIGGER trg_install_template_versions_immutable\s+BEFORE UPDATE OR DELETE ON install_template_versions/);
  assert.match(body, /DROP CONSTRAINT IF EXISTS devices_template_version_check;/);
  // Yeni NULL kolonlarda NOT VALID + VALIDATE gereksiz: duz ADD CONSTRAINT.
  assert.match(body, /ADD CONSTRAINT devices_template_version_check\s+CHECK \(template_version IS NULL OR template_version >= 1\);/);
  assert.doesNotMatch(body, /NOT VALID/);
  // Kilit beklemesi sinirli: ilk ifade SET LOCAL lock_timeout = '5s' (devices ALTER'i canli trafikte uzun beklemesin).
  assert.match(body.trim(), /^SET LOCAL lock_timeout = '5s';/);
});

test('035: tablolar ve sozlesme kumeleri (CONTRACTS §3e)', () => {
  for (const t of ['sites', 'install_templates', 'install_template_versions', 'site_flats', 'template_writes']) {
    assert.match(body, new RegExp(`CREATE TABLE IF NOT EXISTS ${t} \\(`), t);
  }
  assert.match(body, /status IN \('planned', 'written', 'installed', 'handed_over'\)/);
  assert.match(body, /via IN \('usb', 'eth', 'lan'\)/);
  assert.match(body, /result IN \('ok', 'error'\)/);
  for (const c of ['name', 'address', 'city', 'district', 'contact_name', 'contact_phone', 'contact_email', 'block_count', 'flat_count', 'notes', 'deleted_at']) {
    assert.match(body, new RegExp(`\\n\\s+${c}\\s`), `sites.${c}`);
  }
  assert.match(body, /ADD COLUMN IF NOT EXISTS template_id UUID;/);
  assert.match(body, /ADD COLUMN IF NOT EXISTS template_version INT;/);
});

test('035: veri degistiren ifade yok (INSERT/UPDATE/DELETE FROM yok)', () => {
  const noFn = body.replace(/\$\$[\s\S]*?\$\$/g, '');
  assert.doesNotMatch(noFn, /\bINSERT INTO\b|\bUPDATE\s+\w+\s+SET\b|\bDELETE FROM\b/i);
});

test('035: sema yukleyicisi yeni tablo/kolonlari goruyor (check_schema_contract)', () => {
  const { loadSchema } = require('../../scripts/check_schema_contract');
  const schema = loadSchema();
  for (const [t, cols] of Object.entries({
    sites: ['id', 'name', 'deleted_at', 'flat_count'],
    site_flats: ['site_id', 'block', 'number', 'device_uuid', 'status'],
    install_templates: ['site_id', 'current_version', 'deleted_at'],
    install_template_versions: ['template_id', 'version', 'body', 'sha256'],
    template_writes: ['device_uuid', 'via', 'result', 'error_code', 'written_by'],
    devices: ['template_id', 'template_version', 'template_reported_at'],
  })) {
    assert.ok(schema.has(t), t);
    for (const c of cols) assert.ok(schema.get(t).has(c), `${t}.${c}`);
  }
});

test('035 bicim: yalniz ASCII, satir sonu LF, dosya LF ile biter', () => {
  assert.equal(/[^\x00-\x7f]/.test(SQL), false, 'ASCII');
  assert.equal(SQL.includes('\r'), false, 'LF');
  assert.ok(SQL.endsWith('\n'));
});
