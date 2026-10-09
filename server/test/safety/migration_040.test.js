'use strict';

// Migration 040 (alarm onay istegini yapan servis oturumu, sko-1 / sozlesme C11) - STATIK sozlesme (PG'siz).
// Gercek PG: alarm_service_pg.test.js (kolon + temizleme + teslim oncesi yetki denetimi).
//   - 039'dan sonra, 041'den once; ASCII + LF; baslik yorumu; lock_timeout; transaction komutu yok; veri degistirmez
//   - alarms.ack_requested_sid UUID NULL; YABANCI ANAHTAR YOK (oturum satiri silinse de kimlik kalir: istek "revoked" duser,
//     ON DELETE SET NULL eski-satir kuralina dusurup onayi iletebilirdi)
//   - sema-sozlesme denetcisi kolonu goruyor

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const DIR = path.join(__dirname, '..', '..', 'migrations');
const FILE = '040_alarm_ack_requester.sql';

test('040: 039 dan sonra; ASCII + LF; baslik; lock_timeout; transaction komutu yok; veri degistirmez', () => {
  const files = fs.readdirSync(DIR).filter((f) => /^\d{3}.*\.sql$/.test(f)).sort();
  assert.ok(files.includes(FILE), FILE);
  assert.ok(files.indexOf(FILE) > files.indexOf('039_legal_acceptances.sql'));
  assert.equal(files.filter((f) => f.startsWith('040')).length, 1, '040 tek dosya');
  const SQL = fs.readFileSync(path.join(DIR, FILE), 'utf8');
  const body = SQL.replace(/--[^\n]*/g, '');
  assert.equal(/[^\x00-\x7f]/.test(SQL), false, 'ASCII');
  assert.equal(SQL.includes('\r'), false, 'LF');
  assert.match(SQL, /^-- =+\n-- Migration 040/m, 'baslik yorumu');
  assert.match(body, /SET LOCAL lock_timeout = '5s';/);
  assert.doesNotMatch(body, /^\s*(BEGIN|COMMIT|ROLLBACK)\s*;/im);
  assert.doesNotMatch(body, /\bINSERT INTO\b|\bUPDATE\s+\w+\s+SET\b|\bDELETE FROM\b|\bDROP\b/i);
  assert.match(body, /ALTER TABLE alarms ADD COLUMN IF NOT EXISTS ack_requested_sid UUID NULL;/);
  assert.doesNotMatch(body, /REFERENCES/i, 'yabanci anahtar yok');
});

test('040: sema yukleyicisi kolonu goruyor; kod kolonu kullaniyor', () => {
  const { loadSchema } = require('../../scripts/check_schema_contract');
  assert.ok(loadSchema().get('alarms').has('ack_requested_sid'));
  const { SQL } = require('../../src/services/alarm_service');
  // ack_requested_* temizleyen her ifade sid'i de temizler
  for (const k of ['insertRaised', 'loseOtherHomes', 'setLost', 'dropAckRequest', 'takeAckRequest']) {
    assert.match(SQL[k], /ack_requested_sid = NULL/, k);
  }
  assert.match(SQL.openAlarms, /ack_requested_sid/);
});
