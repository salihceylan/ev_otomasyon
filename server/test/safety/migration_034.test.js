'use strict';

// Faz 2 / WP-G1: migration 034 (peace_notification_logs.status += 'skipped_hazard') - statik sozlesme (PG'siz).
// Gercek PostgreSQL ile iki kez calistirma: migration_034_pg.test.js.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const DIR = path.join(__dirname, '..', '..', 'migrations');
const SQL = fs.readFileSync(path.join(DIR, '034_peace_skipped_hazard.sql'), 'utf8');
const strip = (s) => s.replace(/--[^\n]*/g, '');

test('034: transaction komutu yok (calistirici sarar), NOT VALID + VALIDATE deseni, DROP IF EXISTS (idempotent)', () => {
  const body = strip(SQL);
  assert.doesNotMatch(body, /\b(BEGIN|COMMIT|ROLLBACK)\b/i);
  assert.match(body, /DROP CONSTRAINT IF EXISTS peace_logs_status_check/);
  assert.match(body, /NOT VALID;\s*ALTER TABLE peace_notification_logs VALIDATE CONSTRAINT peace_logs_status_check;/);
});

test('034: 030 durumlarinin HEPSI korunur + skipped_hazard; her deger VARCHAR(20)\'ye sigar', () => {
  const list = (s) => s.match(/CHECK \(status IN \(([^)]*)\)\)/)[1].split(',').map((x) => x.trim().replace(/'/g, ''));
  const before = list(fs.readFileSync(path.join(DIR, '030_peace_reminder.sql'), 'utf8'));
  const after = list(SQL);
  for (const s of before) assert.ok(after.includes(s), s);
  assert.deepEqual(after.filter((s) => !before.includes(s)), ['skipped_hazard']);
  for (const s of after) assert.ok(s.length <= 20, s);
});
