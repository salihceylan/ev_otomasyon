'use strict';

// ==============================================================================
// Uctan uca entegrasyon ortami: A paketinin GERCEK auth_middleware + JWT + pin.js + mailer + rate_limit'i ile
// B paketinin route / servis / MQTT-kimlik katmani. Yalnizca PostgreSQL (FakeDb) ve broker (FakeBridge) sahtedir.
// A'nin modulleri yuklenemezse `skipIfUnavailable(t)` testi ATLAR (paralel gelistirme).
//
// require.cache enjeksiyonu surece ozeldir: her test dosyasi (ayri surec) bu fonksiyonu BIR kez cagirir.
// ==============================================================================

const crypto = require('crypto');
const express = require('express');
const request = require('supertest');

const { createWorld, createClock, setTestEnv, createFakeBridge } = require('./_world');
const { injectModule, resolveSrc } = require('./_routes_env');

function createIntegration() {
  console.warn = () => {}; // EMQX_API_* tanimsiz uyarilarini sustur

  // --- ortam (gercek sirlar YOK; her kosumda rastgele) ---
  setTestEnv();
  process.env.JWT_SECRET = crypto.randomBytes(32).toString('hex');
  process.env.JWT_ISSUER = 'test-issuer';
  process.env.DATABASE_URL = 'postgres://test:test@127.0.0.1:1/test'; // db.js sahte; yine de dolu olsun

  const world = createWorld({ clock: createClock(new Date().toISOString()) });
  const { state } = world;
  const bridge = createFakeBridge([]);
  const invites = [];
  const sessions = new Map();

  // to_regclass / information_schema: yalnizca endpoints tablosu ev temizligi icin var sayilir
  world.db.on('SELECT to_regclass($1)', ({ params }) => [{ t: String(params[0]) === 'public.endpoints' ? 'public.endpoints' : null }]);
  world.db.on('FROM information_schema.columns', ({ params }) => (params[0] === 'endpoints' && params[1] === 'home_id' ? [{ '?column?': 1 }] : []));
  world.db.on('DELETE FROM endpoints WHERE home_id = $1', (ctx) => {
    const gone = state.endpoints.filter((e) => e.home_id === ctx.params[0]);
    for (const e of gone) state.endpoints.splice(state.endpoints.indexOf(e), 1);
    ctx.undo(() => state.endpoints.push(...gone));
    return { rows: [], rowCount: gone.length };
  });

  const env = {
    world, state, bridge, invites, sessions, helpers: world.helpers,
    app: null, mw: null, jwtConfig: null, mailer: null, pin: null, loadError: null,
  };

  try {
    injectModule('db.js', { query: (t, p) => world.db.query(t, p), withTransaction: (fn) => world.db.withTransaction(fn), pool: {} });
    injectModule('mqtt_bridge.js', bridge);
    injectModule('services/auth_service.js', { requestPasswordReset: async (email) => { invites.push(email); } });

    env.mw = require(resolveSrc('middlewares/auth_middleware.js'));
    env.jwtConfig = require(resolveSrc('middlewares/jwt_config.js'));
    env.mailer = require(resolveSrc('utils/mailer.js'));
    env.pin = require(resolveSrc('utils/pin.js'));
    require(resolveSrc('middlewares/rate_limit.js'));

    const app = express();
    app.use(express.json());
    app.use('/api/v1/devices', require(resolveSrc('routes/device_routes.js')));
    app.use('/api/v1/homes/:home_id/endpoints', require(resolveSrc('routes/endpoint_routes.js')));
    app.use('/api/v1/homes', require(resolveSrc('routes/home_device_routes.js')));
    app.use('/api/v1/homes', require(resolveSrc('routes/mqtt_routes.js')));
    env.app = app;

    env.mw.configureAuthMiddleware({
      cacheTtlMs: 0,
      loadUser: async (id) => state.users.find((u) => u.id === id) || null,
      loadServiceSession: async (sid) => sessions.get(sid) || null,
    });
  } catch (err) {
    env.loadError = err;
  }

  env.tokenOf = (user) =>
    env.jwtConfig
      ? env.jwtConfig.signAccessToken({ id: user.id, role: user.role, token_version: user.token_version === undefined ? 1 : user.token_version })
      : null;

  env.sessionToken = (homeId, { expiresInMs = 3600 * 1000, name = 'Veli Usta' } = {}) => {
    const sid = crypto.randomUUID();
    sessions.set(sid, { id: sid, home_id: homeId, technician_name: name, expires_at: new Date(Date.now() + expiresInMs), revoked_at: null });
    return env.jwtConfig.signServiceSessionToken({ sid, home_id: homeId, expiresInSec: Math.floor(expiresInMs / 1000) });
  };

  env.api = (method, url, token, body) => {
    let r = request(env.app)[method](url);
    if (token) r = r.set('Authorization', `Bearer ${token}`);
    if (body !== undefined && method !== 'get') r = r.send(body);
    return r;
  };

  env.skipIfUnavailable = (t) => {
    if (env.loadError || !env.app || !env.pin) {
      t.skip(`A paketi modulleri yuklenemedi: ${env.loadError ? env.loadError.message : 'bilinmiyor'}`);
      return true;
    }
    return false;
  };

  env.teardown = () => {
    if (env.mw) env.mw.resetAuthMiddlewareConfig();
  };

  return env;
}

module.exports = { createIntegration };
