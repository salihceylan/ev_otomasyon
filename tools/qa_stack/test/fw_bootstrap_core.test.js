// BootstrapCore.h (firmware) JS portu: test/test_bootstrap ile ayni kurallar (tetik, bekleme, imza girdisi, govde, siki 200 ayristirma)
// + sahip karari (2026-10-09) sunucu kilidi: yanittaki host izin listesinde olmali.
import test from 'node:test';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import * as B from '../sim/fw/bootstrap_core.js';

const ready = (o = {}) => ({ enabled: true, provisioned: true, netUp: true, timeSynced: true, haveCreds: false, authRejects: 0, ...o });
const okBody = (host = 'evotomasyon.gudeteknoloji.com.tr', extra = {}) =>
  JSON.stringify({ status: 'ok', mqtt: { host, port: 8884, username: 'd_h_0123456789abcdef', password: 'p@ss w0rd!', ...extra } });

test('tetik: provizyon + ag + saat + etkin + (kimlik yok YA DA art arda 3 CONNACK 4/5)', () => {
  const f = new B.BootFsm();
  assert.equal(f.due(0, ready()), true);
  for (const k of ['enabled', 'provisioned', 'netUp', 'timeSynced']) assert.equal(f.due(0, ready({ [k]: false })), false, k);
  assert.equal(f.due(0, ready({ haveCreds: true, authRejects: 2 })), false);
  assert.equal(f.due(0, ready({ haveCreds: true, authRejects: 3 })), true);
});

test('bekleme: 202 10 dk, 401 60 dk, 429/ag/bozuk 30 dk, 200 yok; durum metinleri; millis() sarmasi', () => {
  const cases = [[B.Result.PENDING, B.WAIT_PENDING_MS, 'waiting_claim'], [B.Result.DENIED, B.WAIT_DENIED_MS, 'denied'],
    [B.Result.RATE_LIMITED, B.WAIT_ERROR_MS, 'error'], [B.Result.NET_ERROR, B.WAIT_ERROR_MS, 'error'], [B.Result.BAD_RESPONSE, B.WAIT_ERROR_MS, 'error']];
  for (const [r, w, st] of cases) {
    const f = new B.BootFsm();
    const t0 = 0xFFFFFF00;   // sarma oncesi
    f.onResult(t0, r);
    assert.equal(f.status, st);
    assert.equal(f.due((t0 + w - 1) >>> 0, ready()), false, r);
    assert.equal(f.due((t0 + w) >>> 0, ready()), true, r);
  }
  const f = new B.BootFsm();
  f.onResult(5, B.Result.OK);
  assert.equal(f.status, 'ok');
  assert.equal(f.due(5, ready()), true, '200 sonrasi bekleme yok');
});

test('imza girdisi ve govde: firmware bicimi; HMAC-SHA256(local_key) hex', () => {
  assert.equal(B.signString('AHBU-S3-0A0001', 1700000000, 'ab'.repeat(16)), `ahbu-bootstrap/1|AHBU-S3-0A0001|1700000000|${'ab'.repeat(16)}`);
  const sig = B.sign('yerel-anahtar-01', 'AHBU-S3-0A0001', 1700000000, 'ab'.repeat(16));
  assert.equal(sig, crypto.createHmac('sha256', 'yerel-anahtar-01').update(`ahbu-bootstrap/1|AHBU-S3-0A0001|1700000000|${'ab'.repeat(16)}`).digest('hex'));
  assert.deepEqual(JSON.parse(B.buildBody('AHBU-S3-0A0001', 1700000000, 'ab'.repeat(16), '1.3.2', sig)),
    { device_uuid: 'AHBU-S3-0A0001', ts: 1700000000, nonce: 'ab'.repeat(16), fw: '1.3.2', sig });
});

test('yanit ayristirma: kodlar, siki 200 govdesi; host izin listesinde olmali (sunucu kilidi)', () => {
  assert.equal(B.parseResponse(-1, '').result, B.Result.NET_ERROR);
  assert.equal(B.parseResponse(202, '{"status":"pending"}').result, B.Result.PENDING);
  assert.equal(B.parseResponse(401, '{}').result, B.Result.DENIED);
  assert.equal(B.parseResponse(429, '').result, B.Result.RATE_LIMITED);
  assert.equal(B.parseResponse(500, 'x').result, B.Result.BAD_RESPONSE);
  const ok = B.parseResponse(200, okBody());
  assert.deepEqual(ok, { result: B.Result.OK, creds: { host: 'evotomasyon.gudeteknoloji.com.tr', port: 8884, user: 'd_h_0123456789abcdef', pass: 'p@ss w0rd!' } });
  for (const b of [okBody('a b'), okBody('-a.b'), okBody('evotomasyon.gudeteknoloji.com.tr', { port: 0 }), okBody(undefined, { port: '8884' }),
    okBody(undefined, { username: 'u s' }), okBody(undefined, { username: '' }), okBody(undefined, { password: '' }),
    okBody(undefined, { username: 'u'.repeat(48) }), '{"status":"ok"}', 'not json', JSON.stringify({ status: 'pending', mqtt: {} })]) {
    assert.equal(B.parseResponse(200, b).result, B.Result.BAD_RESPONSE, b);
  }
  // sunucu kilidi: yabanci broker reddedilir; izin listesindeki test sunucusu ve buyuk harfli varsayilan kabul edilir
  assert.equal(B.parseResponse(200, okBody('evil.example')).result, B.Result.BAD_RESPONSE);
  assert.equal(B.parseResponse(200, okBody('10.0.2.2')).result, B.Result.BAD_RESPONSE, 'liste bos: yalniz varsayilan');
  assert.equal(B.parseResponse(200, okBody('10.0.2.2'), '10.0.2.2,127.0.0.1').result, B.Result.OK);
  assert.equal(B.parseResponse(200, okBody('EVOTOMASYON.gudeteknoloji.com.tr')).result, B.Result.OK);
});
