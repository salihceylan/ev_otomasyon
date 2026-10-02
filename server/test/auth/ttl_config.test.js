'use strict';

// A16: Sure (TTL) override'lari yalnizca uretim disinda gecerlidir; uretimde sessizce yok sayilir.
// Override sureyi asla varsayilandan uzun yapamaz. TOKEN_EXPIRED / INVALID_TOKEN ayrimi kisa
// surelerle de dogru calisir.

const test = require('node:test');
const assert = require('node:assert');
const express = require('express');
const request = require('supertest');
const jwt = require('jsonwebtoken');
const { setTestEnv, installFakeDb, uuid } = require('./_helpers');

setTestEnv();
const fakeDb = installFakeDb();
const cfg = require('../../src/middlewares/jwt_config');
const auth = require('../../src/middlewares/auth_middleware');

const OVERRIDES = ['ACCESS_TOKEN_TTL_SEC', 'SERVICE_SESSION_TTL_SEC', 'REFRESH_TOKEN_TTL_SEC', 'OTP_TTL_SEC'];

function withEnv(vars, fn) {
  const saved = {};
  for (const k of Object.keys(vars)) saved[k] = process.env[k];
  const restore = () => {
    for (const [k, v] of Object.entries(saved)) {
      if (v === undefined) delete process.env[k];
      else process.env[k] = v;
    }
  };
  for (const [k, v] of Object.entries(vars)) {
    if (v === undefined) delete process.env[k];
    else process.env[k] = String(v);
  }
  let out;
  try {
    out = fn();
  } catch (err) {
    restore();
    throw err;
  }
  if (out && typeof out.then === 'function') {
    return out.finally(restore);
  }
  restore();
  return out;
}

function ttlOf(token) {
  const p = jwt.decode(token);
  return p.exp - p.iat;
}

test('A16: varsayilanlar (override yok)', () => {
  withEnv({ NODE_ENV: 'development', ACCESS_TOKEN_TTL_SEC: undefined, SERVICE_SESSION_TTL_SEC: undefined, REFRESH_TOKEN_TTL_SEC: undefined, OTP_TTL_SEC: undefined }, () => {
    assert.strictEqual(cfg.getAccessTokenTtlSec(), 900);
    assert.strictEqual(cfg.getServiceSessionTtlSec(), 7200);
    assert.strictEqual(cfg.getRefreshTokenTtlSec(), 30 * 24 * 3600);
    assert.strictEqual(cfg.getPhoneOtpTtlSec(), 300);
    assert.strictEqual(cfg.getResetCodeTtlSec(), 900);
  });
});

test('A16: uretim disinda override uygulanir (token exp-iat dahil)', () => {
  withEnv({ NODE_ENV: 'development', ACCESS_TOKEN_TTL_SEC: '60', SERVICE_SESSION_TTL_SEC: '120', REFRESH_TOKEN_TTL_SEC: '300', OTP_TTL_SEC: '30' }, () => {
    assert.strictEqual(cfg.getAccessTokenTtlSec(), 60);
    assert.strictEqual(cfg.getServiceSessionTtlSec(), 120);
    assert.strictEqual(cfg.getRefreshTokenTtlSec(), 300);
    assert.strictEqual(cfg.getPhoneOtpTtlSec(), 30);
    assert.strictEqual(cfg.getResetCodeTtlSec(), 30);
    assert.strictEqual(ttlOf(cfg.signAccessToken({ id: uuid(), role: 'user', token_version: 1 })), 60);
    assert.strictEqual(ttlOf(cfg.signServiceSessionToken({ sid: uuid(), home_id: uuid() })), 120);
  });
});

test('A16: NODE_ENV=production iken override SESSIZCE yok sayilir', () => {
  withEnv({ NODE_ENV: 'production', ACCESS_TOKEN_TTL_SEC: '60', SERVICE_SESSION_TTL_SEC: '120', REFRESH_TOKEN_TTL_SEC: '300', OTP_TTL_SEC: '30' }, () => {
    assert.strictEqual(cfg.isProduction(), true);
    assert.strictEqual(cfg.getAccessTokenTtlSec(), 900);
    assert.strictEqual(cfg.getServiceSessionTtlSec(), 7200);
    assert.strictEqual(cfg.getRefreshTokenTtlSec(), 30 * 24 * 3600);
    assert.strictEqual(cfg.getPhoneOtpTtlSec(), 300);
    assert.strictEqual(cfg.getResetCodeTtlSec(), 900);
    assert.strictEqual(ttlOf(cfg.signAccessToken({ id: uuid(), role: 'user', token_version: 1 })), 900);
    assert.strictEqual(ttlOf(cfg.signServiceSessionToken({ sid: uuid(), home_id: uuid() })), 7200);
  });
});

test('A16: override hicbir ortamda varsayilandan UZUN olamaz; gecersiz deger yok sayilir; alt sinir 10 sn', () => {
  for (const env of ['production', 'development', 'test', undefined]) {
    withEnv({ NODE_ENV: env, ACCESS_TOKEN_TTL_SEC: '999999', SERVICE_SESSION_TTL_SEC: '999999', REFRESH_TOKEN_TTL_SEC: '999999999', OTP_TTL_SEC: '99999' }, () => {
      assert.ok(cfg.getAccessTokenTtlSec() <= 900);
      assert.ok(cfg.getServiceSessionTtlSec() <= 7200);
      assert.ok(cfg.getRefreshTokenTtlSec() <= 30 * 24 * 3600);
      assert.ok(cfg.getPhoneOtpTtlSec() <= 300);
      assert.ok(cfg.getResetCodeTtlSec() <= 900);
    });
  }
  // Uretimde asla varsayilandan kisa da olmaz (override tamamen etkisiz).
  withEnv({ NODE_ENV: 'production', ACCESS_TOKEN_TTL_SEC: '1', SERVICE_SESSION_TTL_SEC: '1' }, () => {
    assert.strictEqual(cfg.getAccessTokenTtlSec(), 900);
    assert.strictEqual(cfg.getServiceSessionTtlSec(), 7200);
  });
  for (const bad of ['0', '-5', 'abc', '1e3', '12.5', ' ']) {
    withEnv({ NODE_ENV: 'development', ACCESS_TOKEN_TTL_SEC: bad }, () => {
      assert.strictEqual(cfg.getAccessTokenTtlSec(), 900, `deger=${JSON.stringify(bad)}`);
    });
  }
  withEnv({ NODE_ENV: 'development', ACCESS_TOKEN_TTL_SEC: '3' }, () => {
    assert.strictEqual(cfg.getAccessTokenTtlSec(), cfg.MIN_TTL_OVERRIDE_SEC);
  });
});

test('A16: kisa TTL ile TOKEN_EXPIRED / INVALID_TOKEN / SERVICE_SESSION_EXPIRED ayrimi', async () => {
  const user = { id: uuid(), email: 'q@test.invalid', full_name: 'q', role: 'user', is_active: true, account_status: 'active', token_version: 1 };
  const HOME = uuid();
  const SID = uuid();
  let nowMs = Date.now();
  auth.configureAuthMiddleware({
    cacheTtlMs: 0,
    now: () => nowMs,
    loadUser: async (id) => (id === user.id ? { ...user } : null),
    loadServiceSession: async (sid) => (sid === SID ? { id: SID, home_id: HOME, technician_name: 't', expires_at: new Date(nowMs + 3600_000), revoked_at: null } : null),
  });
  fakeDb.on(/FROM home_users/, () => [{ role: 'owner', valid_from: null, valid_until: null, installer_expires_at: null }]);

  const app = express();
  app.get('/api/v1/homes', auth.authenticateToken, (req, res) => res.json({ ok: true }));
  app.get('/api/v1/homes/:homeId/x', auth.authenticateToken, auth.requireHomeAccess(['owner', 'service_session']), (req, res) => res.json({ ok: true }));

  await withEnv({ NODE_ENV: 'development', ACCESS_TOKEN_TTL_SEC: '60', SERVICE_SESSION_TTL_SEC: '60' }, async () => {
    const tok = cfg.signAccessToken(user);
    const svc = cfg.signServiceSessionToken({ sid: SID, home_id: HOME });

    assert.strictEqual((await request(app).get('/api/v1/homes').set('Authorization', `Bearer ${tok}`)).status, 200);
    assert.strictEqual((await request(app).get(`/api/v1/homes/${HOME}/x`).set('Authorization', `Bearer ${svc}`)).status, 200);

    nowMs += (60 + cfg.CLOCK_TOLERANCE_SEC + 2) * 1000; // sure doldu

    const expired = await request(app).get('/api/v1/homes').set('Authorization', `Bearer ${tok}`);
    assert.strictEqual(expired.status, 401);
    assert.strictEqual(expired.body.code, 'TOKEN_EXPIRED');

    const svcExpired = await request(app).get(`/api/v1/homes/${HOME}/x`).set('Authorization', `Bearer ${svc}`);
    assert.strictEqual(svcExpired.status, 401);
    assert.strictEqual(svcExpired.body.code, 'SERVICE_SESSION_EXPIRED');

    // Suresi dolmus OLSA BILE imzasi bozuk token INVALID_TOKEN'dir (yenileme denenmez).
    const tampered = tok.slice(0, -3) + (tok.slice(-3) === 'AAA' ? 'BBB' : 'AAA');
    const inv = await request(app).get('/api/v1/homes').set('Authorization', `Bearer ${tampered}`);
    assert.strictEqual(inv.status, 401);
    assert.strictEqual(inv.body.code, 'INVALID_TOKEN');
  });
  auth.resetAuthMiddlewareConfig();
});

test('A16: override ortam degiskenleri listesi belgelenmis adlarla eslesir', () => {
  // Bu adlar CONTRACTS §6'ya eklenecek (koordinator). Ad degisirse bu test kirilir.
  for (const name of OVERRIDES) {
    assert.ok(require('fs').readFileSync(require.resolve('../../src/middlewares/jwt_config'), 'utf8').includes(name), name);
  }
});
