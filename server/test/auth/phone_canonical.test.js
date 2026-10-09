'use strict';

// Karar 11 (2026-10-09): telefonun kanonik bicimi. TR cep numaralari E.164 "+905XXXXXXXXX"; 05XXXXXXXXX, 905XXXXXXXXX,
// +905XXXXXXXXX, 5XXXXXXXXX (bosluk/tire/parantez serbest) ayni kanonik degere eslenir. TR disi "+..." numara oldugu gibi
// kalir. Kimlik eslestirme (giris, OTP, devir, sahiplenme, Home Admin atama) ayni yardimciyi kullanir.
// Migration 042 (mevcut telefonlari kanonik bicime cevirir, cakisanlari atlar): statik sozlesme burada, gercek PG
// davranisi owner_decisions_pg.test.js'te.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const { canonicalPhone } = require('../../src/utils/phone');
const auth = require('../../src/services/auth_service');
const { normalizeIdentifier } = require('../../src/services/device_service').helpers;

const CANON = '+905321234567';

test('canonicalPhone: TR cep bicimleri tek kanonik degere; TR disi + numara ve diger bicimler korunur', () => {
  for (const v of ['05321234567', '905321234567', '+905321234567', '5321234567', '00905321234567']) {
    assert.equal(canonicalPhone(v), CANON, v);
  }
  assert.equal(canonicalPhone('+4915112345678'), '+4915112345678', 'TR disi');
  assert.equal(canonicalPhone('+15551234567'), '+15551234567');
  assert.equal(canonicalPhone('02121234567'), '02121234567', 'sabit hat: dokunulmaz');
  assert.equal(canonicalPhone('4321234567'), '4321234567', '5 ile baslamayan 10 hane');
});

test('auth.normalizePhone ve parseIdentifier kanonik bicim doner (ayraclar temizlenir)', () => {
  for (const v of ['0532 123 45 67', '(0532) 123-45-67', '90 532 123 45 67', '+90 532 123 45 67', '532.123.45.67']) {
    assert.equal(auth.normalizePhone(v), CANON, v);
    assert.deepEqual(auth.parseIdentifier(v), { kind: 'phone', value: CANON }, v);
  }
  assert.equal(auth.normalizePhone('+4915112345678'), '+4915112345678');
  assert.equal(auth.normalizePhone('12345'), null, 'cok kisa');
  assert.equal(auth.normalizePhone(''), null);
});

test('device_service.normalizeIdentifier (devir / sahiplenme / acil sifirlama hedefi) kanonik telefon', () => {
  for (const v of ['05321234567', '905321234567', '+905321234567', '5321234567', '0532-123-45-67']) {
    assert.deepEqual(normalizeIdentifier(v), { type: 'phone', value: CANON }, v);
  }
  assert.deepEqual(normalizeIdentifier('+4915112345678'), { type: 'phone', value: '+4915112345678' });
  assert.deepEqual(normalizeIdentifier('Musteri@Example.TEST'), { type: 'email', value: 'musteri@example.test' });
});

test('migration 042: 041 den sonra; ASCII + LF; baslik; lock_timeout; transaction komutu yok; cakisma atlanir', () => {
  const DIR = path.join(__dirname, '..', '..', 'migrations');
  const FILE = '042_phone_canonical.sql';
  const files = fs.readdirSync(DIR).filter((f) => /^\d{3}.*\.sql$/.test(f)).sort();
  assert.ok(files.includes(FILE), FILE);
  assert.ok(files.indexOf(FILE) > files.indexOf('041_users_phone_verified.sql'));
  assert.equal(files.filter((f) => f.startsWith('042')).length, 1);
  const SQL = fs.readFileSync(path.join(DIR, FILE), 'utf8');
  const body = SQL.replace(/--[^\n]*/g, '');
  assert.equal(/[^\x00-\x7f]/.test(SQL), false, 'ASCII');
  assert.equal(SQL.includes('\r'), false, 'LF');
  assert.match(SQL, /^-- =+\n-- Migration 042/m);
  assert.match(body, /SET LOCAL lock_timeout = '5s';/);
  assert.doesNotMatch(body, /^\s*(BEGIN|COMMIT|ROLLBACK)\s*;/im);
  assert.doesNotMatch(body, /\bDELETE FROM\b|\bDROP\b/i);
  assert.match(body, /UPDATE users\b/);
  assert.match(SQL, /cakis/i, 'cakisan satirlarin atlandigi yorumla belgelenir');
});
