'use strict';

// WP-S4 - Guvenlik rotalari (tasarim §5.2.4) + safety_service:
//   GET  /homes/:homeId/alarms?state=open|all&before=&limit=          view (tum roller)
//   POST /homes/:homeId/alarms/:alarmId/ack                           safety_ack (misafir YOK)
//   POST /homes/:homeId/devices/:deviceId/actuators/:actuatorId {to}  kapatma herkes; acma misafire kapali (serviste)
//   POST /homes/:homeId/devices/:deviceId/alarm-test {zone}           safety_test (owner/servis/super)
// Rota katmani: authenticateToken + requireHomeAccess(rol listesi) + yetenek kapisi; home_id YALNIZ uyelikten.
// Servis: onay komutunda aid ALARM SATIRINDAN gelir [Y-9]; cevrimdisi panoda onay istegi kaydedilir ve 409 doner.

const test = require('node:test');
const assert = require('node:assert/strict');
const express = require('express');
const request = require('supertest');

const { createFakeAuth, createRecorder, listRoutes, injectModule, HOME_A, USER } = require('../devices/_routes_env');

// Modul yuklenirken varsayilan router kurulur: gercek kimlik ara katmani (db.js) yerine sahtesi (diger rota testleri gibi)
injectModule('middlewares/auth_middleware.js', createFakeAuth({ members: [] }));
const { createRouter } = require('../../src/routes/safety_routes');
const { SafetyService } = require('../../src/services/safety_service');

const ORDER = ['super', 'staff', 'session', 'owner', 'resident', 'guest'];
const ROLE = { super: 'super_user', staff: 'service_user', session: 'service_session', owner: 'owner', resident: 'resident', guest: 'guest' };
const FUTURE = new Date(Date.now() + 3600 * 1000).toISOString();
const ACTORS = {
  super: USER({ id: 'u-super', role: 'super_user' }),
  staff: USER({ id: 'u-staff', role: 'service_user' }),
  session: JSON.stringify({ id: null, role: 'service_session', is_service_session: true, home_id: HOME_A, sid: 'sid-1' }),
  owner: USER({ id: 'u-owner' }),
  resident: USER({ id: 'u-res' }),
  guest: USER({ id: 'u-guest' }),
};

function build(over = {}) {
  const registry = { members: [
    { home_id: HOME_A, user_id: 'u-owner', role: 'owner' },
    { home_id: HOME_A, user_id: 'u-res', role: 'resident' },
    { home_id: HOME_A, user_id: 'u-guest', role: 'guest', valid_until: FUTURE },
    { home_id: HOME_A, user_id: 'u-staff', role: 'service_user' },
  ] };
  const auth = createFakeAuth(registry);
  const safetyService = createRecorder(['listAlarms', 'ackAlarm', 'controlActuator', 'testZone', 'getSafetyConfig', 'armDevice', 'patchSafetyConfig', 'cancelSafetyConfigPending'], {
    listAlarms: { items: [], next_before: null },
    ackAlarm: { delivered: true, applied: true },
    controlActuator: { delivered: true, applied: true },
    testZone: { delivered: true, applied: null },
    getSafetyConfig: { device_uuid: 'AHBU-S3-1A2B3C', rev: 3, crc: '0000000a', sensors: [], actuators: [] },
    armDevice: { delivered: true, applied: true, command_id: 'arm1' },
    patchSafetyConfig: { applied: true, rev: 4, crc: '0000000b', command_id: 'cp1' },
    cancelSafetyConfigPending: { dropped: 0 },
    ...over,
  });
  const router = createRouter({ auth, rateLimit: () => (_q, _r, next) => next(), safetyService });
  const app = express();
  app.use(express.json());
  app.use('/api/v1/homes', router);
  return { app, router, safetyService };
}

const CASES = [
  ['alarm listesi', 'get', `/api/v1/homes/${HOME_A}/alarms?state=all`, null, ORDER, 'listAlarms'],
  ['alarm onayi', 'post', `/api/v1/homes/${HOME_A}/alarms/12/ack`, {}, ['super', 'staff', 'session', 'owner', 'resident'], 'ackAlarm'],
  ['eylemci', 'post', `/api/v1/homes/${HOME_A}/devices/dev-1/actuators/a1`, { to: 'closed' }, ORDER, 'controlActuator'],
  ['bolge testi', 'post', `/api/v1/homes/${HOME_A}/devices/dev-1/alarm-test`, { zone: 1 }, ['super', 'staff', 'session', 'owner'], 'testZone'],
  ['yapilandirma kopyasi', 'get', `/api/v1/homes/${HOME_A}/devices/dev-1/safety-config`, null, ORDER, 'getSafetyConfig'],
  // Faz 2 F2.B.6: kurma/cozme YALNIZ owner + resident (servis rolleri ve misafir YOK)
  ['alarm kipi', 'post', `/api/v1/homes/${HOME_A}/devices/dev-1/arm`, { mode: 'away' }, ['owner', 'resident'], 'armDevice'],
  // Faz 2 F2.D.4: buluttan yapilandirma yazimi safety_config (super/staff/session/owner)
  ['yapilandirma yamasi', 'post', `/api/v1/homes/${HOME_A}/devices/dev-1/safety-config`, { base_rev: 3, set: { zone: { id: 1, name: 'Mutfak' } } }, ['super', 'staff', 'session', 'owner'], 'patchSafetyConfig'],
  ['bekleyen kuyrugu iptal', 'delete', `/api/v1/homes/${HOME_A}/devices/dev-1/safety-config/pending`, null, ['super', 'staff', 'session', 'owner'], 'cancelSafetyConfigPending'],
];

test('yapisal: her uc authenticateToken ile baslar, requireHomeAccess rol listesi yetki matrisiyle ayni', () => {
  const { router } = build();
  const routes = listRoutes(router, '/homes');
  assert.deepEqual(routes.map((r) => `${r.method} ${r.path}`).sort(), [
    'GET /homes/:homeId/alarms',
    'POST /homes/:homeId/alarms/:alarmId/ack',
    'POST /homes/:homeId/devices/:deviceId/actuators/:actuatorId',
    'POST /homes/:homeId/devices/:deviceId/alarm-test',
    'GET /homes/:homeId/devices/:deviceId/safety-config',
    'POST /homes/:homeId/devices/:deviceId/arm',
    'POST /homes/:homeId/devices/:deviceId/safety-config',
    'DELETE /homes/:homeId/devices/:deviceId/safety-config/pending',
  ].sort());
  const roles = (p) => new Set(routes.find((r) => r.path === p).handlers.find((h) => h.__tag === 'homeAccess').__roles);
  for (const r of routes) assert.equal(r.handlers[0].__tag, 'authenticateToken');
  assert.deepEqual([...roles('/homes/:homeId/alarms/:alarmId/ack')].sort(), ['owner', 'resident', 'service_session', 'service_user', 'super_user']);
  assert.deepEqual([...roles('/homes/:homeId/devices/:deviceId/alarm-test')].sort(), ['owner', 'service_session', 'service_user', 'super_user']);
  assert.equal(roles('/homes/:homeId/devices/:deviceId/actuators/:actuatorId').size, 6, 'kapatma misafir dahil herkese (acma serviste denetlenir)');
  const rolesOf = (m, p) => new Set(routes.find((r) => r.method === m && r.path === p).handlers.find((h) => h.__tag === 'homeAccess').__roles);
  assert.deepEqual([...rolesOf('POST', '/homes/:homeId/devices/:deviceId/arm')].sort(), ['owner', 'resident']);
  assert.deepEqual([...rolesOf('POST', '/homes/:homeId/devices/:deviceId/safety-config')].sort(), ['owner', 'service_session', 'service_user', 'super_user']);
  assert.deepEqual([...rolesOf('DELETE', '/homes/:homeId/devices/:deviceId/safety-config/pending')].sort(), ['owner', 'service_session', 'service_user', 'super_user']);
  assert.equal(rolesOf('GET', '/homes/:homeId/devices/:deviceId/safety-config').size, 6);
});

test('rol x uc matrisi: izinli rol servise ulasir, digerleri 403; servis home_id\'yi uyelikten alir', async () => {
  for (const [label, method, url, body, allowed, fn] of CASES) {
    for (const actor of ORDER) {
      const { app, safetyService } = build();
      let r = request(app)[method](url).set('x-test-user', ACTORS[actor]);
      if (body) r = r.send(body);
      const res = await r;
      if (allowed.includes(actor)) {
        assert.equal(res.status, 200, `${label} / ${actor}: ${res.status} ${JSON.stringify(res.body)}`);
        const call = safetyService.calls.find((c) => c.name === fn);
        assert.ok(call, `${label} / ${actor}: servis cagrilmadi`);
        assert.equal(call.args.homeId, HOME_A);
        assert.equal(call.args.actor.access, ROLE[actor]);
      } else {
        assert.equal(res.status, 403, `${label} / ${actor}`);
        assert.equal(safetyService.calls.length, 0);
      }
    }
  }
  const { app } = build();
  assert.equal((await request(app).get(`/api/v1/homes/${HOME_A}/alarms`)).status, 401);
});

test('govde/sorgu esleme: to (ya da state metni), zone, state/before/limit servis argumanlarina gecer', async () => {
  const { app, safetyService } = build();
  await request(app).post(`/api/v1/homes/${HOME_A}/devices/AHBU-S3-1A2B3C/actuators/a2`).set('x-test-user', ACTORS.owner).send({ state: 'off' });
  await request(app).post(`/api/v1/homes/${HOME_A}/devices/dev-1/alarm-test`).set('x-test-user', ACTORS.owner).send({ zone: 2 });
  await request(app).get(`/api/v1/homes/${HOME_A}/alarms?state=open&before=40&limit=10`).set('x-test-user', ACTORS.guest);
  const [act, tz, list] = safetyService.calls;
  assert.deepEqual([act.args.deviceRef, act.args.actuatorId, act.args.to], ['AHBU-S3-1A2B3C', 'a2', 'off']);
  assert.equal(tz.args.zone, 2);
  assert.deepEqual([list.args.state, list.args.before, list.args.limit], ['open', '40', 10]);
});

// ------------------------------------------------------------------------------
// safety_service
// ------------------------------------------------------------------------------
function svcSetup({ alarm = null, sendResult = { delivered: true, applied: true }, sendError = null, configRow = null } = {}) {
  const sent = [];
  const requested = [];
  const acked = [];
  const deviceService = {
    async sendCommand(args) {
      sent.push(args);
      if (sendError) throw sendError;
      return sendResult;
    },
    async _findHomeDevice(homeId, ref) {
      return { id: 'dev-1', device_uuid: 'AHBU-S3-1A2B3C', is_online: true, topic_id: 't', ref };
    },
  };
  const alarms = {
    async getAlarm() { return alarm; },
    async requestAck(a) { requested.push(a); return true; },
    async markAcked(a) { acked.push(a); },
    async listAlarms(a) { return { items: [], next_before: null, args: a }; },
    async getConfig({ deviceId }) {
      return deviceId === 'dev-1' && configRow ? configRow : null;
    },
  };
  const svc = new SafetyService({ deviceService, alarmService: alarms });
  return { svc, sent, requested, acked };
}

const OPEN_ALARM = { id: '12', home_id: HOME_A, device_id: 'dev-1', device_uuid: 'AHBU-S3-1A2B3C', aid: '9f3a11c0-3', zone: 1, status: 'latched', is_online: true };

test('ackAlarm: aid ve bolge ALARM SATIRINDAN; uid cihazdan; uygulandiysa acked_by yazilir', async () => {
  const s = svcSetup({ alarm: OPEN_ALARM });
  const r = await s.svc.ackAlarm({ actor: { userId: 'u-owner', access: 'owner' }, homeId: HOME_A, alarmId: '12' });
  assert.equal(r.alarm_id, 12);
  assert.deepEqual(s.sent[0].command, { cmd: 'alarm_ack', zone: 1, aid: '9f3a11c0-3', uid: 'AHBU-S3-1A2B3C' });
  assert.equal(s.sent[0].deviceRef, 'dev-1');
  assert.deepEqual(s.acked, [{ alarmId: '12', userId: 'u-owner' }]);
});

test('ackAlarm: misafir 403; kapali alarm 409 ALARM_NOT_OPEN; bilinmeyen 404; gecersiz kimlik 400', async () => {
  const s = svcSetup({ alarm: OPEN_ALARM });
  await assert.rejects(s.svc.ackAlarm({ actor: { access: 'guest' }, homeId: HOME_A, alarmId: '12' }), (e) => e.status === 403);
  const c = svcSetup({ alarm: { ...OPEN_ALARM, status: 'cleared' } });
  await assert.rejects(c.svc.ackAlarm({ actor: { access: 'owner' }, homeId: HOME_A, alarmId: '12' }), (e) => e.status === 409 && e.code === 'ALARM_NOT_OPEN');
  const n = svcSetup({ alarm: null });
  await assert.rejects(n.svc.ackAlarm({ actor: { access: 'owner' }, homeId: HOME_A, alarmId: '12' }), (e) => e.status === 404);
  await assert.rejects(n.svc.ackAlarm({ actor: { access: 'owner' }, homeId: HOME_A, alarmId: 'x' }), (e) => e.status === 400);
});

test('ackAlarm: pano cevrimdisi -> onay istegi kaydedilir + 409 DEVICE_OFFLINE (ack_queued); komut gonderilmez', async () => {
  const s = svcSetup({ alarm: { ...OPEN_ALARM, is_online: false } });
  await assert.rejects(s.svc.ackAlarm({ actor: { userId: 'u-res', access: 'resident' }, homeId: HOME_A, alarmId: '12' }), (e) => {
    assert.equal(e.status, 409);
    assert.equal(e.code, 'DEVICE_OFFLINE');
    assert.equal(e.extra.ack_queued, true);
    return true;
  });
  assert.deepEqual(s.requested, [{ alarmId: '12', homeId: HOME_A, userId: 'u-res', sessionId: null }]);
  assert.equal(s.sent.length, 0);
  // sko-1: servis (PIN) oturumunun istegi oturum kimligiyle kaydedilir (teslimden once gecerliligi denetlenir)
  const sid = '5e55e55e-0000-4000-8000-000000000001';
  const p = svcSetup({ alarm: { ...OPEN_ALARM, is_online: false } });
  await assert.rejects(p.svc.ackAlarm({ actor: { userId: null, sessionId: sid, access: 'service_session' }, homeId: HOME_A, alarmId: '12' }), (e) => e.status === 409);
  assert.deepEqual(p.requested, [{ alarmId: '12', homeId: HOME_A, userId: null, sessionId: sid }]);
});

test('controlActuator / testZone: komut cihazin uid\'siyle kurulur; gecersiz hedef 400', async () => {
  const s = svcSetup();
  await s.svc.controlActuator({ actor: { access: 'guest' }, homeId: HOME_A, deviceRef: 'dev-1', actuatorId: 'a1', to: 'closed' });
  assert.deepEqual(s.sent[0].command, { actuator: 'a1', to: 'closed', uid: 'AHBU-S3-1A2B3C' });
  await s.svc.testZone({ actor: { access: 'owner' }, homeId: HOME_A, deviceRef: 'dev-1', zone: 1 });
  assert.deepEqual(s.sent[1].command, { cmd: 'alarm_test', zone: 1, uid: 'AHBU-S3-1A2B3C' });
  await assert.rejects(s.svc.controlActuator({ actor: { access: 'owner' }, homeId: HOME_A, deviceRef: 'dev-1', actuatorId: 'a1', to: 5 }), (e) => e.status === 400);
});

test('listAlarms: state yalniz open|all; before tamsayi; limit 1..200', async () => {
  const s = svcSetup();
  const r = await s.svc.listAlarms({ homeId: HOME_A, state: 'all', before: '40', limit: 10 });
  assert.deepEqual(r.args, { homeId: HOME_A, state: 'all', before: '40', limit: 10 });
  await assert.rejects(s.svc.listAlarms({ homeId: HOME_A, state: 'x' }), (e) => e.status === 400);
  await assert.rejects(s.svc.listAlarms({ homeId: HOME_A, state: 'open', before: 'abc' }), (e) => e.status === 400);
  await assert.rejects(s.svc.listAlarms({ homeId: HOME_A, state: 'open', limit: 0 }), (e) => e.status === 400);
});

test('getSafetyConfig: cihaz evde cozulur (UUID ya da device_uuid); kopya yoksa 404 CONFIG_NOT_AVAILABLE; adlar doner', async () => {
  const row = { rev: 4, crc: '0000000b', updated_at: '2026-10-07T00:00:00.000Z', policy: { on: true }, zones: [], lights: [],
    sensors: [{ id: 'd3', name: 'Evye alti' }], actuators: [{ id: 'a1', name: 'Ana vana' }] };
  const s = svcSetup({ configRow: row });
  const r = await s.svc.getSafetyConfig({ homeId: HOME_A, deviceRef: 'ahbu-s3-1a2b3c' });
  assert.equal(r.device_uuid, 'AHBU-S3-1A2B3C');
  assert.equal(r.sensors[0].name, 'Evye alti');
  assert.equal(r.rev, 4);
  const none = svcSetup();
  await assert.rejects(none.svc.getSafetyConfig({ homeId: HOME_A, deviceRef: 'dev-1' }), (e) => e.status === 404 && e.code === 'CONFIG_NOT_AVAILABLE');
  await assert.rejects(none.svc.getSafetyConfig({ homeId: HOME_A, deviceRef: ' ' }), (e) => e.status === 400);
});

test('istemci komut kimligi (id) panoya aynen gider; verilmezse komutta id yok (sunucu uretir)', async () => {
  const { app, safetyService } = build();
  await request(app).post(`/api/v1/homes/${HOME_A}/devices/dev-1/actuators/a1`).set('x-test-user', ACTORS.owner).send({ to: 'closed', id: 'c81f' });
  await request(app).post(`/api/v1/homes/${HOME_A}/alarms/12/ack`).set('x-test-user', ACTORS.owner).send({ id: 'k1' });
  await request(app).post(`/api/v1/homes/${HOME_A}/devices/dev-1/alarm-test`).set('x-test-user', ACTORS.owner).send({ zone: 1 });
  const [act, ack, tz] = safetyService.calls;
  assert.equal(act.args.commandId, 'c81f');
  assert.equal(ack.args.commandId, 'k1');
  assert.equal(tz.args.commandId, undefined);
  const s = svcSetup({ alarm: OPEN_ALARM });
  await s.svc.controlActuator({ actor: { access: 'owner' }, homeId: HOME_A, deviceRef: 'dev-1', actuatorId: 'a1', to: 'closed', commandId: 'c81f' });
  assert.deepEqual(s.sent[0].command, { actuator: 'a1', to: 'closed', uid: 'AHBU-S3-1A2B3C', id: 'c81f' });
  await s.svc.ackAlarm({ actor: { userId: 'u-owner', access: 'owner' }, homeId: HOME_A, alarmId: '12', commandId: 'k1' });
  assert.deepEqual(s.sent[1].command, { cmd: 'alarm_ack', zone: 1, aid: '9f3a11c0-3', uid: 'AHBU-S3-1A2B3C', id: 'k1' });
  await s.svc.testZone({ actor: { access: 'owner' }, homeId: HOME_A, deviceRef: 'dev-1', zone: 2, commandId: 'z2' });
  assert.deepEqual(s.sent[2].command, { cmd: 'alarm_test', zone: 2, uid: 'AHBU-S3-1A2B3C', id: 'z2' });
});

test('Faz 2 rotalari: govde servis argumanlarina; yama 200 (applied) / 202 (kuyruk ya da sonuc bekleniyor); kurma id tasir', async () => {
  const { app, safetyService } = build();
  let res = await request(app).post(`/api/v1/homes/${HOME_A}/devices/dev-1/arm`).set('x-test-user', ACTORS.owner).send({ mode: 'off', id: 'a9' });
  assert.equal(res.status, 200);
  const arm = safetyService.calls.find((c) => c.name === 'armDevice');
  assert.deepEqual([arm.args.deviceRef, arm.args.mode, arm.args.commandId], ['dev-1', 'off', 'a9']);
  const body = { base_rev: 3, set: { zone: { id: 1, name: 'Mutfak' } }, id: 'p1' };
  res = await request(app).post(`/api/v1/homes/${HOME_A}/devices/dev-1/safety-config`).set('x-test-user', ACTORS.staff).send(body);
  assert.equal(res.status, 200);
  assert.equal(res.headers['cache-control'], 'no-store');
  const p = safetyService.calls.find((c) => c.name === 'patchSafetyConfig');
  assert.deepEqual(p.args.body, body);
  assert.equal(p.args.deviceRef, 'dev-1');
  for (const out of [{ queued: true, position: 1, expires_at: 'x', command_id: 'q' }, { applied: null, command_id: 'n' }]) {
    const b2 = build({ patchSafetyConfig: out });
    res = await request(b2.app).post(`/api/v1/homes/${HOME_A}/devices/dev-1/safety-config`).set('x-test-user', ACTORS.owner).send(body);
    assert.equal(res.status, 202, JSON.stringify(out));
    assert.deepEqual(res.body.data, out);
  }
  res = await request(app).delete(`/api/v1/homes/${HOME_A}/devices/dev-1/safety-config/pending`).set('x-test-user', ACTORS.owner);
  assert.equal(res.status, 200);
  assert.deepEqual(res.body.data, { dropped: 0 });
});
