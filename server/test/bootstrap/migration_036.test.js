'use strict';

// CONTRACTS §3f: migration 036 (device_bootstrap_nonces) - STATIK sozlesme (PG'siz). Gercek PG: bootstrap_service_pg.test.js.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const DIR = path.join(__dirname, '..', '..', 'migrations');
const FILE = '036_device_bootstrap_nonces.sql';
const SQL = fs.readFileSync(path.join(DIR, FILE), 'utf8');
const body = SQL.replace(/--[^\n]*/g, '');

test('036: 035\'ten sonra; transaction komutu yok; idempotent', () => {
  const files = fs.readdirSync(DIR).filter((f) => /^\d{3}.*\.sql$/.test(f)).sort();
  assert.ok(files.indexOf(FILE) > files.indexOf('035_sites_templates.sql'));
  assert.doesNotMatch(body, /^\s*(BEGIN|COMMIT|ROLLBACK)\s*;/im);
  assert.match(body, /CREATE TABLE IF NOT EXISTS device_bootstrap_nonces \(/);
  assert.match(body, /PRIMARY KEY \(device_uuid, nonce\)/);
  assert.match(body, /CREATE INDEX IF NOT EXISTS idx_device_bootstrap_nonces_created/);
  assert.doesNotMatch(body, /\bINSERT INTO\b|\bUPDATE\s+\w+\s+SET\b|\bDELETE FROM\b/i);
});

test('036 bicim: ASCII, LF, sema yukleyicisi tabloyu goruyor', () => {
  assert.equal(/[^\x00-\x7f]/.test(SQL), false);
  assert.equal(SQL.includes('\r'), false);
  const { loadSchema } = require('../../scripts/check_schema_contract');
  const t = loadSchema().get('device_bootstrap_nonces');
  assert.ok(t);
  for (const c of ['device_uuid', 'nonce', 'created_at']) assert.ok(t.has(c), c);
});
