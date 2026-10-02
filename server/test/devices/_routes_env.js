'use strict';

// ==============================================================================
// Route testleri icin ortam: A paketinin middleware sozlesmesini (authenticateToken, requireHomeAccess,
// req.homeAccess) taklit eden SAHTE kimlik dogrulama + kayit tutan SAHTE servisler.
// Modullar require.cache'e enjekte edilir; uretimdeki varsayilan (module-level) route baglantisi test edilir.
// ==============================================================================

const path = require('path');
const express = require('express');

const ALL_ROLES = ['owner', 'resident', 'guest', 'service_user', 'service_session', 'super_user'];

function resolveSrc(rel) {
  return require.resolve(path.join(__dirname, '..', '..', 'src', rel));
}

function injectModule(rel, exports) {
  const filename = resolveSrc(rel);
  require.cache[filename] = { id: filename, filename, loaded: true, exports, children: [], paths: [] };
  return filename;
}

function dropFromCache(rel) {
  const filename = resolveSrc(rel);
  delete require.cache[filename];
}

/**
 * A'nin middleware sozlesmesi (auth_middleware.js basligi):
 *   authenticateToken -> req.user; requireHomeAccess(roles) -> req.homeAccess = { home_id, role, is_super, is_service_session, valid_until }
 *   - roles yalnizca bilinen 6 rol dizgisi icerebilir (aksi TypeError)
 *   - super_user YALNIZCA listede aciksa uyeliksiz gecer
 *   - servis oturumu yalnizca kendi home_id'si ve listede 'service_session' varsa
 *   - misafir: valid_until gecerli olmali (yoksa/gecmisse 403 GUEST_EXPIRED)
 *   - home_id kaynaklari: params.homeId|home_id, body.home_id|homeId, query.home_id|homeId (uyusmazsa 400)
 */
function createFakeAuth(registry) {
  const known = new Set(ALL_ROLES);

  function authenticateToken(req, res, next) {
    const raw = req.headers['x-test-user'];
    if (!raw) return res.status(401).json({ success: false, message: 'token yok', code: 'INVALID_TOKEN' });
    try {
      req.user = JSON.parse(raw);
    } catch (_) {
      return res.status(401).json({ success: false, message: 'bozuk', code: 'INVALID_TOKEN' });
    }
    return next();
  }

  function pickHomeId(req) {
    const vals = [];
    const push = (v) => {
      if (v !== undefined && v !== null && v !== '') vals.push(String(v).trim());
    };
    if (req.params) { push(req.params.homeId); push(req.params.home_id); }
    if (req.body && typeof req.body === 'object') { push(req.body.home_id); push(req.body.homeId); }
    if (req.query) { push(req.query.home_id); push(req.query.homeId); }
    if (vals.length === 0) return { value: null };
    return { value: vals[0], conflict: vals.some((v) => v.toLowerCase() !== vals[0].toLowerCase()) };
  }

  function requireHomeAccess(allowedRoles) {
    if (!Array.isArray(allowedRoles) || allowedRoles.length === 0) throw new TypeError('rol dizisi zorunlu');
    const unknown = allowedRoles.filter((r) => !known.has(r));
    if (unknown.length) throw new TypeError(`bilinmeyen rol: ${unknown.join(',')}`);
    const allowed = new Set(allowedRoles);

    const deny = (res, status, code, message = 'yetki yok') => res.status(status).json({ success: false, message, code });

    function homeAccess(req, res, next) {
      const picked = pickHomeId(req);
      if (!picked.value) return deny(res, 400, 'VALIDATION', 'home_id zorunlu');
      if (picked.conflict) return deny(res, 400, 'VALIDATION', 'home_id uyusmuyor');
      const homeId = picked.value.toLowerCase();

      if (req.user.is_service_session || req.user.role === 'service_session') {
        if (!allowed.has('service_session')) return deny(res, 403, 'FORBIDDEN');
        if (String(req.user.home_id || '').toLowerCase() !== homeId) return deny(res, 403, 'FORBIDDEN');
        req.homeAccess = { home_id: homeId, role: 'service_session', is_super: false, is_service_session: true, valid_until: req.user.session_expires_at || null };
        return next();
      }
      if (req.user.role === 'super_user' && allowed.has('super_user')) {
        req.homeAccess = { home_id: homeId, role: 'super_user', is_super: true, is_service_session: false, valid_until: null };
        return next();
      }
      const m = registry.members.find((x) => x.home_id === homeId && x.user_id === req.user.id);
      if (!m) return deny(res, 403, 'FORBIDDEN');
      if (m.role === 'guest') {
        const until = m.valid_until ? new Date(m.valid_until).getTime() : null;
        if (until === null || until < Date.now()) return deny(res, 403, 'GUEST_EXPIRED');
      }
      if (m.role === 'service_user' && !['service_user', 'super_user'].includes(req.user.role)) return deny(res, 403, 'FORBIDDEN');
      if (!allowed.has(m.role)) return deny(res, 403, 'FORBIDDEN');
      req.homeAccess = { home_id: homeId, role: m.role, is_super: false, is_service_session: false, valid_until: m.role === 'guest' ? m.valid_until : null };
      return next();
    }
    homeAccess.__roles = [...allowedRoles];
    homeAccess.__tag = 'homeAccess';
    return homeAccess;
  }

  authenticateToken.__tag = 'authenticateToken';
  return { authenticateToken, requireHomeAccess };
}

/** Kayit tutan sahte servis: her metot { name, args } kaydeder ve canned deger doner (veya firlatir). */
function createRecorder(methodNames, canned = {}) {
  const calls = [];
  const svc = { calls, failWith: {} };
  for (const name of methodNames) {
    svc[name] = async (args) => {
      calls.push({ name, args });
      if (svc.failWith[name]) throw svc.failWith[name];
      return typeof canned[name] === 'function' ? canned[name](args) : canned[name] !== undefined ? canned[name] : { ok: true };
    };
  }
  return svc;
}

const DEVICE_METHODS = [
  'requestClaimOtp', 'claimDevice', 'emergencyReset', 'replaceBoard', 'sendCommand', 'setChildLock', 'getChildLock',
  'getPeaceNotificationSettings', 'updatePeaceNotificationSettings', 'closeAllOpenLights', 'getSystemDiagnostic',
  'listDevices', 'getLocalKey', 'reissueDeviceCredential', 'commissionHome', 'getCommissioningStatus',
];

/**
 * Sahte baglantilari enjekte eder ve route modullerini YENIDEN yukler.
 * @returns {{ app, registry, deviceService, endpointService, mqttCredentials, auth, routers }}
 */
function buildRouteEnv({ canned = {}, rateLimitModule } = {}) {
  const registry = { members: [] };
  const auth = createFakeAuth(registry);
  const deviceService = createRecorder(DEVICE_METHODS, {
    claimDevice: { home_id: 'h', home_name: 'Ev', device_uuid: 'AHBU-S3-0001', device_credential: { password: 'x'.repeat(24) } },
    requestClaimOtp: { message: 'Dogrulama kodu gonderildi.', expires_in: 900, resend_after: 60 },
    emergencyReset: { action: 'UNCLAIMED', message: 'Cihaz stoga alindi.', setup_pin: '123456' },
    replaceBoard: { message: 'Pano degisimi tamamlandi.', device_credential: { password: 'x'.repeat(24) } },
    setChildLock: { message: 'Cocuk kilidi aktif.', child_lock_enabled: true },
    updatePeaceNotificationSettings: { message: 'Ayarlar guncellendi.', settings: {} },
    closeAllOpenLights: { message: 'Kapatildi.', closed_count: 0 },
    listDevices: [],
    getLocalKey: { local_key: 'AnahtarAnahtar123' },
    reissueDeviceCredential: { password: 'y'.repeat(24) },
    commissionHome: { tests_passed: true, commissioned: true },
    ...canned.device,
  });
  const endpointService = createRecorder(['getEndpointsByHome', 'updateEndpoint', 'controlEndpoint'], {
    getEndpointsByHome: [],
    updateEndpoint: { id: 'e1' },
    controlEndpoint: { delivered: true, device_online: true, command_id: 'c1' },
    ...canned.endpoint,
  });
  const mqttCredentials = createRecorder(['issueUserCredential'], {
    issueUserCredential: (args) => ({
      host: 'broker.test.invalid', port: 8884, username: 'a_t_1', password: 'p'.repeat(24), client_id: 'a_t_1',
      expires_at: '2026-10-02T00:00:00.000Z', topic_id: 't', evicted_usernames: ['gizli-ic-alan'], _args: args,
    }),
    ...canned.mqtt,
  });

  injectModule('middlewares/auth_middleware.js', auth);
  injectModule('services/device_service.js', deviceService);
  injectModule('services/endpoint_service.js', endpointService);
  injectModule('services/mqtt_credential_service.js', mqttCredentials);
  if (rateLimitModule) injectModule('middlewares/rate_limit.js', rateLimitModule);
  for (const r of ['device_routes', 'home_device_routes', 'endpoint_routes', 'mqtt_routes', 'route_helpers']) {
    dropFromCache(`routes/${r}.js`);
  }

  const routers = {
    device: require(resolveSrc('routes/device_routes.js')),
    homeDevice: require(resolveSrc('routes/home_device_routes.js')),
    endpoint: require(resolveSrc('routes/endpoint_routes.js')),
    mqtt: require(resolveSrc('routes/mqtt_routes.js')),
  };

  const app = express();
  app.use(express.json());
  app.use('/api/v1/devices', routers.device);
  app.use('/api/v1/homes/:home_id/endpoints', routers.endpoint);
  app.use('/api/v1/homes', routers.homeDevice);
  app.use('/api/v1/homes', routers.mqtt);
  app.use((req, res) => res.status(404).json({ success: false, message: 'yok', code: 'NOT_FOUND' }));

  return { app, registry, deviceService, endpointService, mqttCredentials, auth, routers };
}

/** Express router yigininden (method, path, handlers[]) listesi cikarir. */
function listRoutes(router, prefix = '') {
  const out = [];
  for (const layer of router.stack) {
    if (layer.route) {
      const methods = Object.keys(layer.route.methods).filter((m) => layer.route.methods[m]);
      for (const method of methods) {
        out.push({ method: method.toUpperCase(), path: `${prefix}${layer.route.path}`, handlers: layer.route.stack.map((s) => s.handle) });
      }
    }
  }
  return out;
}

const HOME_A = '11111111-1111-4111-8111-111111111111';
const HOME_B = '22222222-2222-4222-8222-222222222222';
const USER = (overrides = {}) => JSON.stringify({ id: 'u-1', role: 'user', email: 'u1@example.test', ...overrides });

module.exports = {
  ALL_ROLES,
  buildRouteEnv,
  createFakeAuth,
  createRecorder,
  listRoutes,
  injectModule,
  resolveSrc,
  HOME_A,
  HOME_B,
  USER,
};
