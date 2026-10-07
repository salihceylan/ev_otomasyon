'use strict';

// WP-S4 - Komut hatti: guvenlik komutlari ve hedef denetimi (tasarim §5.2.4, kararlar §7.2b-4/8):
//   1. Eylemci uc noktasina duz `relay` komutu -> 409 ACTUATOR_USE_SAFETY_COMMAND (lamba gibi surulemez).
//   2. Gaz vanasina `open` -> 409 GAS_LOCAL_ONLY (hicbir rol; yalniz yerinde).
//   3. Vana `open`: pano mode=normal, vananin bolgeleri normal ve bolgedeki ayni akiskanli sensorler ok && !active
//      degilse 409 ZONE_ALARM_ACTIVE (savunma katmani; asil yetki firmware'de).
//   4. caps 'safety' icermiyorsa 409 FIRMWARE_UNSUPPORTED.
//   Rol: misafir KAPATIR ama acamaz/onaylayamaz/test edemez. uid hedef cihazla eslesmeli.
//   Onay: yalniz hedef uid'nin last_id yankisi (applied); last_rej -> 409 DEVICE_REJECTED (+ reason, Turkce metin).

const test = require('node:test');
const assert = require('node:assert/strict');

const { DeviceService } = require('../../src/services/device_service');

const HOME = '11111111-1111-4111-8111-111111111111';
const DEV_ID = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const UID = 'AHBU-S3-1A2B3C';

function safetyState(over = {}) {
  return {
    v: 1, present: true, policy: 'on', mode: 'normal',
    zones: [{ id: 1, st: 'normal', aid: null }, { id: 2, st: 'normal', aid: null }],
    actuators: [
      { id: 'a1', relay: 5, kind: 'valve', medium: 'water', zones: [1], pos: 'closed', on: null, fb: null, fault: false },
      { id: 'a2', relay: 6, kind: 'siren', medium: null, zones: [1], pos: null, on: false, fb: null, fault: false },
      { id: 'a3', relay: 7, kind: 'valve', medium: 'gas', zones: [2], pos: 'closed', on: null, fb: null, fault: false },
    ],
    sensors: [{ id: 'd3', src: 'di', kind: 'water', zone: 1, active: false, ok: true }],
    ...over,
  };
}

function setup({ caps = ['safety', 'actuator', 'event', 'cfg'], state = safetyState(), online = true, endpointRow = null, outcome = { ok: true }, findCaps } = {}) {
  const calls = [];
  const db = {
    async query(text, params) {
      calls.push({ text, params });
      if (/FROM devices d\s+JOIN homes h ON h.id = d.home_id/.test(text)) {
        return { rows: [{ id: DEV_ID, device_uuid: UID, is_online: online, topic_id: 'h_topic', ...(findCaps !== undefined ? { caps: findCaps } : {}) }] };
      }
      if (/SELECT caps, safety_state FROM devices WHERE id = \$1/.test(text)) {
        return { rows: [{ caps, safety_state: state }] };
      }
      if (/SELECT type, actuator_type FROM endpoints WHERE device_id = \$1 AND channel_index = \$2/.test(text)) {
        return { rows: endpointRow ? [endpointRow] : [] };
      }
      return { rows: [] };
    },
    async withTransaction(fn) {
      return fn({ query: (t, p) => db.query(t, p) });
    },
  };
  const published = [];
  const waits = [];
  const bridge = {
    isConnected: () => true,
    async publishCommand(topicId, cmd) {
      published.push({ topicId, cmd });
      return {};
    },
    expectOutcome(topicId, id, ms, opts) {
      waits.push({ topicId, id, ms, opts });
      return Promise.resolve(outcome);
    },
    cancelAck() {},
  };
  const svc = new DeviceService({ db, mqttBridge: bridge });
  const send = (access, command) => svc.sendCommand({ actor: { userId: 'u1', access }, homeId: HOME, deviceRef: DEV_ID, command });
  return { svc, send, published, waits, calls };
}

async function rejects(p, status, code) {
  await assert.rejects(p, (err) => {
    assert.equal(err.status || err.statusCode, status, `${err.code}: ${err.message}`);
    if (code) assert.equal(err.code, code);
    return true;
  });
}

test('1. eylemci uc noktasina duz relay komutu 409 ACTUATOR_USE_SAFETY_COMMAND; eylemci olmayan kanal eskisi gibi', async () => {
  const a = setup({ endpointRow: { type: 'light', actuator_type: 'valve' } });
  await rejects(a.send('owner', { relay: 5, state: false }), 409, 'ACTUATOR_USE_SAFETY_COMMAND');
  await rejects(a.send('owner', { relay: 5, cmd: 'toggle' }), 409, 'ACTUATOR_USE_SAFETY_COMMAND');
  assert.equal(a.published.length, 0);
  const b = setup({ endpointRow: { type: 'light', actuator_type: null } });
  const r = await b.send('guest', { relay: 6, state: true });
  assert.equal(r.delivered, true);
  assert.deepEqual(Object.keys(b.published[0].cmd).sort(), ['id', 'relay', 'state']);
  assert.equal(b.waits.length, 0, 'eski komut onay BEKLEMEZ (davranis aynen)');
  const c = setup({ endpointRow: { type: 'shutter', actuator_type: null } });
  await rejects(c.send('owner', { relay: 1, state: true }), 400, 'VALIDATION');
});

test('misafir: vanayi KAPATIR (uid ile, hedef uid yankisi beklenir) ama acamaz / onaylayamaz / test edemez', async () => {
  const s = setup();
  const r = await s.send('guest', { actuator: 'a1', to: 'closed', uid: UID });
  assert.equal(r.delivered, true);
  assert.equal(r.applied, true);
  assert.equal(s.published[0].cmd.uid, UID);
  assert.equal(s.published[0].cmd.actuator, 'a1');
  assert.equal(s.waits[0].opts.uid, UID);
  assert.equal(s.waits[0].id, s.published[0].cmd.id);
  await rejects(s.send('guest', { actuator: 'a1', to: 'open', uid: UID }), 403, 'FORBIDDEN');
  await rejects(s.send('guest', { actuator: 'a2', to: 'on', uid: UID }), 403, 'FORBIDDEN');
  await rejects(s.send('guest', { cmd: 'alarm_ack', zone: 1, aid: '9f3a11c0-3', uid: UID }), 403, 'FORBIDDEN');
  await rejects(s.send('resident', { cmd: 'alarm_test', zone: 1, uid: UID }), 403, 'FORBIDDEN');
  assert.equal((await s.send('resident', { cmd: 'alarm_ack', zone: 1, aid: '9f3a11c0-3', uid: UID })).delivered, true);
  assert.equal((await s.send('owner', { cmd: 'alarm_test', zone: 1, uid: UID })).delivered, true);
});

test('2. gaz vanasi buluttan ACILMAZ (owner/super dahil) -> 409 GAS_LOCAL_ONLY; kapatma serbest', async () => {
  const s = setup();
  for (const role of ['owner', 'super_user', 'service_user']) {
    await rejects(s.send(role, { actuator: 'a3', to: 'open', uid: UID }), 409, 'GAS_LOCAL_ONLY');
  }
  assert.equal(s.published.length, 0);
  assert.equal((await s.send('guest', { actuator: 'a3', to: 'closed', uid: UID })).delivered, true);
});

test('3. su vanasi acma: bolge alarmda / mode safe / sensor islak ya da ok degil -> 409 ZONE_ALARM_ACTIVE; hepsi normalse yayin', async () => {
  const latched = setup({ state: safetyState({ zones: [{ id: 1, st: 'latched', aid: '9f3a11c0-3' }] }) });
  await rejects(latched.send('owner', { actuator: 'a1', to: 'open', uid: UID }), 409, 'ZONE_ALARM_ACTIVE');
  const safe = setup({ state: safetyState({ mode: 'safe' }) });
  await rejects(safe.send('owner', { actuator: 'a1', to: 'open', uid: UID }), 409, 'ZONE_ALARM_ACTIVE');
  const wet = setup({ state: safetyState({ sensors: [{ id: 'd3', src: 'di', kind: 'water', zone: 1, active: true, ok: true }] }) });
  await rejects(wet.send('owner', { actuator: 'a1', to: 'open', uid: UID }), 409, 'ZONE_ALARM_ACTIVE');
  const bad = setup({ state: safetyState({ sensors: [{ id: 'd3', src: 'di', kind: 'water', zone: 1, active: false, ok: false }] }) });
  await rejects(bad.send('owner', { actuator: 'a1', to: 'open', uid: UID }), 409, 'ZONE_ALARM_ACTIVE');
  const ok = setup();
  const r = await ok.send('resident', { actuator: 'a1', to: 'open', uid: UID });
  assert.equal(r.applied, true);
  assert.equal(ok.published[0].cmd.to, 'open');
  // kapatma alarm surerken de serbest
  assert.equal((await latched.send('guest', { actuator: 'a1', to: 'closed', uid: UID })).delivered, true);
});

test('4. caps safety icermiyor / yok -> 409 FIRMWARE_UNSUPPORTED (kapatma dahil: eski firmware komutu tanimaz)', async () => {
  await rejects(setup({ caps: null }).send('owner', { actuator: 'a1', to: 'closed', uid: UID }), 409, 'FIRMWARE_UNSUPPORTED');
  await rejects(setup({ caps: ['event'] }).send('owner', { cmd: 'alarm_test', zone: 1, uid: UID }), 409, 'FIRMWARE_UNSUPPORTED');
});

test('uid hedef cihazla eslesmeli; bilinmeyen eylemci 404; vana/anahtar hedef uyumsuzlugu 400', async () => {
  const s = setup();
  await rejects(s.send('owner', { actuator: 'a1', to: 'closed', uid: 'AHBU-S3-FFFFFF' }), 400, 'VALIDATION');
  await rejects(s.send('owner', { actuator: 'a9', to: 'closed', uid: UID }), 404, 'NOT_FOUND');
  await rejects(s.send('owner', { actuator: 'a1', to: 'on', uid: UID }), 400, 'VALIDATION');
  await rejects(s.send('owner', { actuator: 'a2', to: 'closed', uid: UID }), 400, 'VALIDATION');
  assert.equal(s.published.length, 0);
});

test('ret yankisi -> 409 DEVICE_REJECTED (+ reason, Turkce metin); zaman asimi -> applied null (iletildi, onay gelmedi)', async () => {
  const rej = setup({ outcome: { ok: false, rejected: 'zone_latched' } });
  await assert.rejects(rej.send('guest', { actuator: 'a1', to: 'closed', uid: UID }), (err) => {
    assert.equal(err.status || err.statusCode, 409);
    assert.equal(err.code, 'DEVICE_REJECTED');
    assert.equal(err.extra.reason, 'zone_latched');
    assert.match(err.message, /Alarm sürerken vana açılamaz/);
    return true;
  });
  const slow = setup({ outcome: { ok: false, timeout: true } });
  const r = await slow.send('guest', { actuator: 'a1', to: 'closed', uid: UID });
  assert.equal(r.delivered, true);
  assert.equal(r.applied, null);
});

test('cevrimdisi pano: guvenlik komutu da 409 DEVICE_OFFLINE (vana acma ASLA kuyruga alinmaz)', async () => {
  const s = setup({ online: false });
  await rejects(s.send('owner', { actuator: 'a1', to: 'open', uid: UID }), 409, 'DEVICE_OFFLINE');
  assert.equal(s.published.length, 0);
});

test('RV-2: guvenlik destekli panoya (caps safety) duz role komutu uid ile gider; eski panoya uid eklenmez', async () => {
  const a = setup({ endpointRow: { type: 'light', actuator_type: null }, findCaps: ['safety', 'actuator', 'event', 'cfg'] });
  await a.send('owner', { relay: 6, state: false });
  assert.equal(a.published[0].cmd.uid, UID);
  assert.deepEqual(Object.keys(a.published[0].cmd).sort(), ['id', 'relay', 'state', 'uid']);
  await a.send('owner', { relay: 6, cmd: 'toggle' });
  assert.equal(a.published[1].cmd.uid, UID);
  const b = setup({ endpointRow: { type: 'light', actuator_type: null }, findCaps: null });
  await b.send('owner', { relay: 6, state: true });
  assert.equal(b.published[0].cmd.uid, undefined, 'v:2 firmware bilinmeyen alani reddeder');
  const c = setup({ endpointRow: null, findCaps: ['safety', 'actuator', 'event', 'cfg'] });
  await c.send('owner', { cmd: 'all_off' });
  assert.equal(c.published[0].cmd.uid, undefined, 'ev geneli komut butun panolara gider');
});
