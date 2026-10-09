'use strict';

// Migration 041 (users.phone_verified, hesap-uyelik-3 / sozlesme C9) - STATIK sozlesme (PG'siz). Gercek PG: uyelik_pg.test.js.
//   - 040'tan sonra; ASCII + LF; baslik yorumu; lock_timeout; transaction komutu yok
//   - users.phone_verified BOOLEAN NOT NULL DEFAULT FALSE; OTP yer tutucu hesaplar (phone_<no>@ahbu.local) TRUE'ya doldurulur
//     (idempotent: yalniz FALSE olanlar); baska veri degismez
//   - sema-sozlesme denetcisi kolonu goruyor

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const DIR = path.join(__dirname, '..', '..', 'migrations');
const FILE = '041_users_phone_verified.sql';

test('041: 040 tan sonra; ASCII + LF; baslik; lock_timeout; transaction komutu yok; yalniz yer tutucu doldurma', () => {
  const files = fs.readdirSync(DIR).filter((f) => /^\d{3}.*\.sql$/.test(f)).sort();
  assert.ok(files.includes(FILE), FILE);
  assert.ok(files.indexOf(FILE) > files.indexOf('040_alarm_ack_requester.sql'), 'sko-1 (040) once');
  assert.equal(files.filter((f) => f.startsWith('041')).length, 1, '041 tek dosya');
  const SQL = fs.readFileSync(path.join(DIR, FILE), 'utf8');
  const body = SQL.replace(/--[^\n]*/g, '');
  assert.equal(/[^\x00-\x7f]/.test(SQL), false, 'ASCII');
  assert.equal(SQL.includes('\r'), false, 'LF');
  assert.match(SQL, /^-- =+\n-- Migration 041/m, 'baslik yorumu');
  assert.match(body, /SET LOCAL lock_timeout = '5s';/);
  assert.doesNotMatch(body, /^\s*(BEGIN|COMMIT|ROLLBACK)\s*;/im);
  assert.doesNotMatch(body, /\bINSERT INTO\b|\bDELETE FROM\b|\bDROP\b/i);
  assert.match(body, /ALTER TABLE users ADD COLUMN IF NOT EXISTS phone_verified BOOLEAN NOT NULL DEFAULT FALSE;/);
  const updates = body.match(/\bUPDATE\s+\w+\s+SET\b[\s\S]*?;/gi) || [];
  assert.equal(updates.length, 1, 'tek doldurma');
  assert.match(updates[0].replace(/\s+/g, ' '), /^UPDATE users SET phone_verified = TRUE WHERE phone_verified = FALSE AND phone IS NOT NULL AND phone <> '' AND email ~\* '\^phone_\[0-9\]\+@ahbu\[\.\]local\$';$/);
});

test('041: sema yukleyicisi kolonu goruyor', () => {
  const { loadSchema } = require('../../scripts/check_schema_contract');
  assert.ok(loadSchema().get('users').has('phone_verified'));
});
