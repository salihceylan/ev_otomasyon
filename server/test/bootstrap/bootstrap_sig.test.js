'use strict';

// CONTRACTS §3f: imza bicimi ve govde ayristirma (saf yardimcilar).

const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');

const { bootstrapMessage, signBootstrap, parseBootstrapBody, sigMatches } = require('../../src/services/device_bootstrap_service');

test('imza = hex(HMAC-SHA256(local_key, "ahbu-bootstrap/1|uuid|ts|nonce"))', () => {
  assert.equal(bootstrapMessage('AHBU-S3-DD8754', 1791460000, 'ab'.repeat(16)), `ahbu-bootstrap/1|AHBU-S3-DD8754|1791460000|${'ab'.repeat(16)}`);
  const expected = crypto.createHmac('sha256', 'GizliAnahtar').update(`ahbu-bootstrap/1|AHBU-S3-DD8754|1791460000|${'ab'.repeat(16)}`).digest('hex');
  assert.equal(signBootstrap('GizliAnahtar', 'AHBU-S3-DD8754', 1791460000, 'ab'.repeat(16)), expected);
});

test('sigMatches: sabit zamanli karsilastirma; buyuk harfli hex kabul; bozuk uzunluk false', () => {
  const sig = signBootstrap('k1', 'AHBU-S3-0001', 1, 'cd'.repeat(16));
  assert.equal(sigMatches(sig, sig), true);
  assert.equal(sigMatches(sig.toUpperCase(), sig), true);
  assert.equal(sigMatches('0'.repeat(64), sig), false);
  assert.equal(sigMatches('abc', sig), false);
});

test('parseBootstrapBody: gecerli govde normallesir; her bozuk alan null', () => {
  const ok = parseBootstrapBody({ device_uuid: 'ahbu-s3-dd8754', ts: 1791460000, nonce: 'AB'.repeat(16), fw: '1.3.0', sig: 'F'.repeat(64) });
  assert.deepEqual(ok, { uuid: 'AHBU-S3-DD8754', ts: 1791460000, nonce: 'ab'.repeat(16), sig: 'f'.repeat(64) });
  const base = { device_uuid: 'AHBU-S3-DD8754', ts: 1791460000, nonce: 'ab'.repeat(16), sig: 'f'.repeat(64) };
  for (const bad of [
    null, [], 'x', { ...base, device_uuid: 'BASKA-1' }, { ...base, ts: '1791460000' }, { ...base, ts: 1.5 }, { ...base, ts: -1 },
    { ...base, nonce: 'ab'.repeat(15) }, { ...base, nonce: 'zz'.repeat(16) }, { ...base, sig: 'f'.repeat(63) }, { ...base, fw: 5 },
  ]) {
    assert.equal(parseBootstrapBody(bad), null, JSON.stringify(bad));
  }
});
