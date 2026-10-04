'use strict';

// utils/http_errors.js + routes/route_helpers.js: hata esleme (CONTRACTS §1.1)

const test = require('node:test');
const assert = require('node:assert');

const { HttpError } = require('../../src/utils/helpers');
const { httpError, toErrorResponse, summarizeError } = require('../../src/utils/http_errors');
const { sendError, handle, requireGlobalRoles, requireCapability, actorOf } = require('../../src/routes/route_helpers');

function fakeRes() {
  const res = {
    statusCode: 200,
    headers: {},
    body: undefined,
    setHeader(k, v) {
      this.headers[k] = v;
    },
    status(c) {
      this.statusCode = c;
      return this;
    },
    json(b) {
      this.body = b;
      return this;
    },
  };
  return res;
}

test('HttpError: mesaj, kod ve durum aynen yansir', () => {
  const r = toErrorResponse(httpError(409, 'Cihaz cevrimdisi.', 'DEVICE_OFFLINE', { device_online: false }));
  assert.strictEqual(r.status, 409);
  assert.deepStrictEqual(r.body, {
    success: false,
    message: 'Cihaz cevrimdisi.',
    code: 'DEVICE_OFFLINE',
    device_online: false,
  });
});

test('HttpError: kod verilmezse duruma gore varsayilan kod uretilir', () => {
  const expected = { 400: 'VALIDATION', 403: 'FORBIDDEN', 404: 'NOT_FOUND', 409: 'CONFLICT', 423: 'PIN_LOCKED', 429: 'RATE_LIMITED', 502: 'BROKER_UNAVAILABLE' };
  for (const [status, code] of Object.entries(expected)) {
    assert.strictEqual(toErrorResponse(httpError(Number(status), 'x')).body.code, code);
  }
});

test('retry_after: govdeye ve Retry-After basligina yansir', () => {
  const res = fakeRes();
  sendError(res, httpError(423, 'Kilitli', 'PIN_LOCKED', { retry_after: 600 }));
  assert.strictEqual(res.statusCode, 423);
  assert.strictEqual(res.body.code, 'PIN_LOCKED');
  assert.strictEqual(res.body.retry_after, 600);
  assert.strictEqual(res.headers['Retry-After'], '600');
});

test('ek alanlar beyaz liste ile sinirli (ic bilgi sizmaz)', () => {
  const r = toErrorResponse(httpError(400, 'x', 'VALIDATION', { remaining_attempts: 2, secret: 'gizli', stack: 'x' }));
  assert.strictEqual(r.body.remaining_attempts, 2);
  assert.ok(!('secret' in r.body));
  assert.ok(!('stack' in r.body));
});

test('reason: makine-okur 409 ayirici govdeye yansir (fx2 S-4: NOT_APPLIED / TYPE_CHANGED)', () => {
  for (const reason of ['NOT_APPLIED', 'TYPE_CHANGED']) {
    const r = toErrorResponse(httpError(409, 'x', 'CONFLICT', { reason }));
    assert.deepStrictEqual(r.body, { success: false, message: 'x', code: 'CONFLICT', reason });
  }
});

test('5xx: ham ic mesaj (SQL, kisit adi) istemciye DONMEZ, loga yazilir', () => {
  const raw = new Error('duplicate key value violates unique constraint "uq_users_email_lower" DETAIL: Key (email)=(a@b.com)');
  raw.code = '23505';
  const r = toErrorResponse(raw);
  assert.strictEqual(r.status, 500);
  assert.strictEqual(r.body.code, 'INTERNAL');
  assert.ok(!/uq_users_email_lower|a@b\.com|duplicate/.test(JSON.stringify(r.body)));
  assert.strictEqual(r.shouldLog, true);
});

test('bilincli 5xx HttpError (502 BROKER_UNAVAILABLE) mesaji korunur', () => {
  const r = toErrorResponse(httpError(502, 'Komut broker uzerinden iletilemedi.', 'BROKER_UNAVAILABLE'));
  assert.strictEqual(r.status, 502);
  assert.strictEqual(r.body.message, 'Komut broker uzerinden iletilemedi.');
  assert.strictEqual(r.shouldLog, true);
});

test('eski bicim (statusCode=4xx) hata mesaji korunur; 5xx ise sizdirilmaz', () => {
  const e4 = new Error('Kontrol noktasi bulunamadi');
  e4.statusCode = 404;
  assert.strictEqual(toErrorResponse(e4).status, 404);
  assert.strictEqual(toErrorResponse(e4).body.message, 'Kontrol noktasi bulunamadi');

  const e5 = new Error('ic ayrinti');
  e5.statusCode = 503;
  const r5 = toErrorResponse(e5);
  assert.strictEqual(r5.status, 500);
  assert.ok(!/ic ayrinti/.test(JSON.stringify(r5.body)));
});

test('PostgreSQL kilitlenme/serilestirme cakismasi 409 CONFLICT olur', () => {
  for (const code of ['40P01', '40001']) {
    const e = new Error('deadlock detected');
    e.code = code;
    const r = toErrorResponse(e);
    assert.strictEqual(r.status, 409);
    assert.strictEqual(r.body.code, 'CONFLICT');
    assert.ok(!/deadlock/.test(r.body.message));
  }
});

test('pg hata kodu (ornegin 23505) yanit "code" alanina SIZMAZ', () => {
  const e = new Error('x');
  e.code = '23505';
  assert.notStrictEqual(toErrorResponse(e).body.code, '23505');
});

test('handle(): firlatilan hata yutulmaz, sendError ile yanitlanir', async () => {
  const res = fakeRes();
  const origError = console.error;
  console.error = () => {};
  try {
    await handle(async () => {
      throw new Error('beklenmeyen');
    })({}, res);
  } finally {
    console.error = origError;
  }
  assert.strictEqual(res.statusCode, 500);
  assert.strictEqual(res.body.success, false);
  assert.ok(!/beklenmeyen/.test(JSON.stringify(res.body)));

  const res2 = fakeRes();
  await handle(async () => {
    throw httpError(403, 'Yetki yok', 'FORBIDDEN');
  })({}, res2);
  assert.strictEqual(res2.statusCode, 403);
  assert.strictEqual(res2.body.code, 'FORBIDDEN');
});

test('summarizeError sir icermez ve yigini kisaltir', () => {
  const s = summarizeError(new Error('basit hata'));
  assert.match(s, /basit hata/);
  assert.ok(s.length < 600);
});

test('requireGlobalRoles: servis oturumu ve beyaz liste disi roller gecemez', () => {
  const gate = requireGlobalRoles(['service_user', 'super_user'], 'yetki yok');
  const run = (user) => {
    const res = fakeRes();
    let passed = false;
    gate({ user }, res, () => {
      passed = true;
    });
    return { passed, res };
  };
  assert.strictEqual(run({ id: 'u1', role: 'service_user' }).passed, true);
  assert.strictEqual(run({ id: 'u1', role: 'super_user' }).passed, true);
  for (const bad of [
    { id: 'u1', role: 'user' },
    { id: null, role: 'service_session', is_service_session: true },
    { id: 'u1', role: 'service_user', is_service_session: true },
    { id: 'u1', role: 'admin' },
    undefined,
  ]) {
    const r = run(bad);
    assert.strictEqual(r.passed, false);
    assert.strictEqual(r.res.statusCode, 403);
    assert.strictEqual(r.res.body.code, 'FORBIDDEN');
  }
});

test('requireCapability: requireHomeAccess atlansa bile matris ikinci savunma hattidir', () => {
  const gate = requireCapability('calibrate');
  const run = (homeAccess) => {
    const res = fakeRes();
    let passed = false;
    gate({ homeAccess }, res, () => {
      passed = true;
    });
    return { passed, res };
  };
  assert.strictEqual(run({ role: 'owner' }).passed, true);
  assert.strictEqual(run({ role: 'resident' }).passed, false);
  assert.strictEqual(run({ role: 'guest' }).passed, false);
  assert.strictEqual(run(undefined).passed, false);
  assert.strictEqual(run({ role: 'resident' }).res.statusCode, 403);
});

test('actorOf: servis oturumunda userId null, etkin rol matristen gelir', () => {
  const a = actorOf({
    user: { id: null, role: 'service_session', is_service_session: true, sid: 'sid-1', technician_name: 'Ali' },
    homeAccess: { role: 'service_session', is_super: false, is_service_session: true },
    ip: '::ffff:10.0.0.5',
  });
  assert.strictEqual(a.userId, null);
  assert.strictEqual(a.isServiceSession, true);
  assert.strictEqual(a.sessionId, 'sid-1');
  assert.strictEqual(a.label, 'Ali');
  assert.strictEqual(a.access, 'service_session');
  assert.strictEqual(a.ip, '10.0.0.5');

  const b = actorOf({ user: { id: 'u-1', role: 'user', email: 'a@b.co' }, homeAccess: { role: 'guest' }, ip: '1.2.3.4' });
  assert.strictEqual(b.userId, 'u-1');
  assert.strictEqual(b.access, 'guest');
});

test('HttpError sinifi helpers ile ayni (instanceof calisir)', () => {
  assert.ok(httpError(400, 'x') instanceof HttpError);
});
