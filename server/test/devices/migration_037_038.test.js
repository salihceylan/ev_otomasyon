'use strict';

// pano-5 / pano-6: migration 037 (yerel anahtar tutarliligi) ve kullanim-4 / guvenlik-1: migration 038 (pano degisimi
// onarimlari) - STATIK sozlesme (PG'siz). Gercek PG: migration_038_pg.test.js.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const DIR = path.join(__dirname, '..', '..', 'migrations');
const read = (f) => fs.readFileSync(path.join(DIR, f), 'utf8');
const strip = (s) => s.replace(/--[^\n]*/g, '');

test('037: 036 dan sonra; idempotent ADD COLUMN IF NOT EXISTS; transaction komutu yok; ASCII + LF; lock_timeout', () => {
  const FILE = '037_local_key_consistency.sql';
  const files = fs.readdirSync(DIR).filter((f) => /^\d{3}.*\.sql$/.test(f)).sort();
  assert.ok(files.includes(FILE), `${FILE} yok`);
  assert.ok(files.indexOf(FILE) > files.indexOf('036_device_bootstrap_nonces.sql'));
  const SQL = read(FILE);
  const body = strip(SQL);
  assert.equal(/[^\x00-\x7f]/.test(SQL), false, 'ASCII');
  assert.equal(SQL.includes('\r'), false, 'LF');
  assert.match(SQL, /^-- =+\n-- Migration 037/m, 'baslik yorumu');
  assert.match(body, /SET LOCAL lock_timeout = '5s';/);
  assert.doesNotMatch(body, /^\s*(BEGIN|COMMIT|ROLLBACK)\s*;/im);
  for (const col of ['local_key_fp TEXT', 'local_key_fp_at TIMESTAMPTZ']) {
    assert.match(body, new RegExp(`ALTER TABLE devices ADD COLUMN IF NOT EXISTS ${col}`), col);
  }
  for (const col of ['local_key_read_at TIMESTAMPTZ', 'key_rotated_at TIMESTAMPTZ']) {
    assert.match(body, new RegExp(`ALTER TABLE service_sessions ADD COLUMN IF NOT EXISTS ${col}`), col);
  }
  const { loadSchema } = require('../../scripts/check_schema_contract');
  const schema = loadSchema();
  for (const c of ['local_key_fp', 'local_key_fp_at']) assert.ok(schema.get('devices').has(c), c);
  // inceleme: ONCEKI yerel anahtar saklanmaz (eski anahtari bilen kisi bootstrap ile rotasyonu / acil sifirlamayi geri aldiramaz)
  assert.doesNotMatch(body, /local_key_prev/, 'onceki anahtar kolonu yok');
  for (const c of ['local_key_prev_enc', 'local_key_prev_until']) assert.equal(schema.get('devices').has(c), false, c);
  for (const c of ['local_key_read_at', 'key_rotated_at']) assert.ok(schema.get('service_sessions').has(c), c);
});

test('038: 037 den sonra; kural onarimi en cok 10 tur dongu (degisim zinciri); alarm onarimi; idempotent; ASCII + LF', () => {
  const FILE = '038_replace_board_repairs.sql';
  const files = fs.readdirSync(DIR).filter((f) => /^\d{3}.*\.sql$/.test(f)).sort();
  assert.ok(files.includes(FILE), `${FILE} yok`);
  assert.ok(files.indexOf(FILE) > files.indexOf('037_local_key_consistency.sql'));
  const SQL = read(FILE);
  const body = strip(SQL);
  assert.equal(/[^\x00-\x7f]/.test(SQL), false, 'ASCII');
  assert.equal(SQL.includes('\r'), false, 'LF');
  assert.match(SQL, /^-- =+\n-- Migration 038/m, 'baslik yorumu');
  assert.match(body, /SET LOCAL lock_timeout = '5s';/);
  assert.doesNotMatch(body, /^\s*(BEGIN|COMMIT|ROLLBACK)\s*;/im);
  assert.match(body, /DO \$\$/);
  assert.match(body, /FOR i IN 1\.\.10 LOOP/);
  assert.match(body, /UPDATE scheduled_rules sr\s+SET device_id = nd\.id/);
  assert.match(body, /JOIN device_replacement_logs l ON l\.old_device_uuid = od\.device_uuid/);
  assert.match(body, /od\.home_id IS DISTINCT FROM sr\.home_id/);
  assert.match(body, /EXIT WHEN n = 0;/);
  assert.match(body, /UPDATE alarms a\s+SET status = 'lost'/);
  assert.match(body, /cleared_by = 'detached'/);
  assert.match(body, /d\.home_id IS DISTINCT FROM a\.home_id/);
  assert.match(body, /a\.status NOT IN \('cleared', 'lost'\)/);
});
