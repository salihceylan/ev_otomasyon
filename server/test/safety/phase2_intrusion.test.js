'use strict';

// Faz 2 / WP-I4 (tasarim F2.B.6-B.8): hirsiz alarmi kipi - sunucu.
//   - Olay dogrulama: intrusion_alarm / intrusion_cleared / arm_changed (KATI alan listesi; bilinmeyen alan reddi).
//   - state ozeti: safety.arm {mode, st, ok, aid?, srcs?} (until_up SAKLANMAZ).
//   - Alarm servisi: intrusion_alarm -> alarms kind='intrusion' + tek push; intrusion_cleared -> cleared/mezar tasi;
//     arm_changed -> yalniz denetim kaydi. Bolge uzlastirmasi hirsiz satirina DOKUNMAZ; ayri arm uzlastirmasi.
//   - Komut: {cmd:'safety_arm', mode, uid, id?}; yetenek safety_arm = owner + resident; caps 'intrusion' yoksa 409
//     FIRMWARE_UNSUPPORTED; hirsiz alarmina onay 409 ALARM_USE_DISARM.

const test = require('node:test');
const assert = require('node:assert/strict');

const { validateEventPayload, parseStateSafety } = require('../../src/utils/safety_payload');
const { createAlarmService, SQL, helpers } = require('../../src/services/alarm_service');
const { validateCommand, capabilityForCommand } = require('../../src/utils/command_schema');
const { can, rolesFor } = require('../../src/utils/role_matrix');
const { DeviceService } = require('../../src/services/device_service');
const { SafetyService } = require('../../src/services/safety_service');

const UID = 'AHBU-S3-1A2B3C';
const HOME = '11111111-1111-4111-8111-111111111111';
const DEV = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const ENV = { v: 1, uid: UID, bn: '9f3a11c0', boot: 57, n: 7, at_up: 3000 };

// ------------------------------------------------------------------------------
// Olay dogrulama
// ------------------------------------------------------------------------------
test('intrusion_alarm: gecerli -> kind intrusion, bolge, kaynaklar, aid = eid', () => {
  const r = validateEventPayload({ ...ENV, eid: '9f3a11c0-7', type: 'intrusion_alarm', zone: 2, kind: 'intrusion', srcs: ['d5', 'b2'], at: 1791273000 });
  assert.equal(r.ok, true, r.reason);
  assert.equal(r.value.unknown, false);
  assert.equal(r.value.kind, 'intrusion');
  assert.equal(r.value.zone, 2);
  assert.deepEqual(r.value.srcs, ['d5', 'b2']);
  assert.equal(r.value.aid, '9f3a11c0-7');
});

test('intrusion_alarm: bolge zorunlu, kind yalniz intrusion, bilinmeyen alan reddedilir', () => {
  const base = { ...ENV, eid: '9f3a11c0-7', type: 'intrusion_alarm', zone: 1, kind: 'intrusion', srcs: ['d5'] };
  assert.equal(validateEventPayload({ ...base, zone: undefined }).ok, false);
  assert.equal(validateEventPayload({ ...base, kind: 'water' }).ok, false);
  assert.equal(validateEventPayload({ ...base, kind: undefined }).ok, false);
  assert.equal(validateEventPayload({ ...base, aid: '9f3a11c0-1' }).ok, false, 'aid yazilmaz (alarm kimligi eid)');
  assert.equal(validateEventPayload({ ...base, actions: [] }).ok, false);
  assert.equal(validateEventPayload({ ...base, extra: 1 }).ok, false);
  // mevcut turler eskisi gibi esnek (geri uyum)
  assert.equal(validateEventPayload({ ...ENV, eid: '9f3a11c0-8', type: 'alarm_raised', zone: 1, kind: 'water', extra: 1 }).ok, true);
});

test('intrusion_cleared: aid zorunlu, via kumesi; arm_changed: mode kumesi; bilinmeyen alan reddi', () => {
  const c = validateEventPayload({ ...ENV, eid: '9f3a11c0-9', type: 'intrusion_cleared', aid: '9f3a11c0-7', via: 'cloud' });
  assert.equal(c.ok, true, c.reason);
  assert.equal(c.value.aid, '9f3a11c0-7');
  assert.equal(c.value.via, 'cloud');
  assert.equal(validateEventPayload({ ...ENV, eid: '9f3a11c0-9', type: 'intrusion_cleared', via: 'cloud' }).ok, false);
  assert.equal(validateEventPayload({ ...ENV, eid: '9f3a11c0-9', type: 'intrusion_cleared', aid: '9f3a11c0-7', via: 'boot' }).ok, false);
  assert.equal(validateEventPayload({ ...ENV, eid: '9f3a11c0-9', type: 'intrusion_cleared', aid: '9f3a11c0-7', via: 'lan', zone: 1 }).ok, false);

  const a = validateEventPayload({ ...ENV, eid: '9f3a11c0-10', type: 'arm_changed', mode: 'away', via: 'di' });
  assert.equal(a.ok, true, a.reason);
  assert.equal(a.value.mode, 'away');
  assert.equal(a.value.via, 'di');
  assert.equal(validateEventPayload({ ...ENV, eid: '9f3a11c0-10', type: 'arm_changed', mode: 'night', via: 'di' }).ok, false);
  assert.equal(validateEventPayload({ ...ENV, eid: '9f3a11c0-10', type: 'arm_changed', mode: 'off', via: 'boot' }).ok, true);
  assert.equal(validateEventPayload({ ...ENV, eid: '9f3a11c0-10', type: 'arm_changed', mode: 'off', via: 'boot', srcs: [] }).ok, false);
});

// ------------------------------------------------------------------------------
// state ozeti
// ------------------------------------------------------------------------------
test('parseStateSafety: safety.arm ozeti (mode/st/ok/aid/srcs), until_up saklanmaz; caps intrusion', () => {
  const r = parseStateSafety({
    v: 3, caps: ['safety', 'actuator', 'event', 'cfg', 'intrusion'],
    safety: { policy: 'on', mode: 'normal', zones: [], arm: { mode: 'away', st: 'alarm', ok: true, aid: '9F3A11C0-7', srcs: ['d5', 'x', 'b2'], until_up: 99 } },
  });
  assert.ok(r.caps.includes('intrusion'));
  assert.deepEqual(r.summary.arm, { mode: 'away', st: 'alarm', ok: true, aid: '9f3a11c0-7', srcs: ['d5', 'b2'] });
  const exit = parseStateSafety({ v: 3, caps: ['safety'], safety: { mode: 'normal', arm: { mode: 'home', st: 'exit', ok: true, until_up: 500 } } });
  assert.deepEqual(exit.summary.arm, { mode: 'home', st: 'exit', ok: true, aid: null, srcs: [] });
  const none = parseStateSafety({ v: 3, caps: ['safety'], safety: { mode: 'normal' } });
  assert.equal(none.summary.arm, null);
  const bad = parseStateSafety({ v: 3, caps: ['safety'], safety: { mode: 'normal', arm: 'x' } });
  assert.equal(bad.summary.arm, null);
  assert.ok(bad.skipped > 0);
  const odd = parseStateSafety({ v: 3, caps: ['safety'], safety: { mode: 'normal', arm: { mode: 'night', st: 'boom', ok: 1 } } });
  assert.deepEqual(odd.summary.arm, { mode: 'unknown', st: 'unknown', ok: false, aid: null, srcs: [] });
});

// ------------------------------------------------------------------------------
// Alarm servisi: olaylar
// ------------------------------------------------------------------------------
function scriptedDb(handlers) {
  const calls = [];
  const run = async (text, params) => {
    calls.push({ text, params });
    for (const h of handlers) if (h.match.test(text)) return h.reply(params, text);
    return { rows: [], rowCount: 0 };
  };
  return { calls, query: run, withTransaction: async (fn) => fn({ query: run }) };
}

function svcWith(db, push = null) {
  return createAlarmService({ db, publishCommand: async () => {}, getPush: () => push, logger: { log() {}, warn() {}, error() {} }, ackWindowMs: 0, sleep: async () => {} });
}

function pushRecorder() {
  const sent = [];
  return {
    sent,
    isConfigured: () => true,
    recipientsForHome: async () => [{ id: 'p1', token: 'tok-aaaaaaaaaaaaaaaaaaaaa' }],
    sendNotice: async (a) => {
      sent.push(a);
      return { sent: 1 };
    },
  };
}

test('intrusion_alarm -> alarms satiri kind intrusion (origin event) + tek push "Hirsiz alarmi"', async () => {
  const db = scriptedDb([
    { match: /^INSERT INTO device_events/, reply: () => ({ rows: [{ eid: 'x' }], rowCount: 1 }) },
    { match: /^INSERT INTO alarms \(home_id, device_id, aid, zone, kind, status, origin, sources/, reply: () => ({ rows: [{ id: 31 }], rowCount: 1 }) },
    { match: /SET push_status = 'claimed'/, reply: () => ({ rows: [{ id: 31, home_id: HOME, device_id: DEV, zone: 2, kind: 'intrusion', status: 'latched', device_uuid: UID }], rowCount: 1 }) },
  ]);
  const push = pushRecorder();
  const svc = svcWith(db, push);
  const ev = validateEventPayload({ ...ENV, eid: '9f3a11c0-7', type: 'intrusion_alarm', zone: 2, kind: 'intrusion', srcs: ['d5'] }).value;
  const r = await svc.handleEvent({ topicId: 'h_t', homeId: HOME, deviceId: DEV, uid: UID, event: ev });
  await svc.idle();
  assert.equal(r.opened, true);
  const ins = db.calls.find((c) => /^INSERT INTO alarms \(home_id, device_id, aid, zone, kind, status, origin, sources/.test(c.text));
  assert.deepEqual(ins.params.slice(2, 6), ['9f3a11c0-7', 2, 'intrusion', 'event']);
  assert.equal(push.sent.length, 1);
  assert.equal(push.sent[0].title, 'Hırsız alarmı');
  assert.equal(push.sent[0].body, "Ev alarmı tetiklendi (bölge 2). Uygulamadan durumu kontrol edin; tehlikedeyseniz 112'yi arayın.");
  assert.equal(push.sent[0].data.kind, 'intrusion');
  assert.equal(helpers.alarmTitle('intrusion'), 'Hırsız alarmı');
});

test('intrusion_cleared: bilinen aid -> cleared (device_event); bilinmeyen aid -> mezar tasi (kind intrusion), push yok', async () => {
  const known = scriptedDb([
    { match: /^INSERT INTO device_events/, reply: () => ({ rows: [{ eid: 'x' }], rowCount: 1 }) },
    { match: /^SELECT id, aid, status FROM alarms/, reply: () => ({ rows: [{ id: 31, aid: '9f3a11c0-7', status: 'latched' }], rowCount: 1 }) },
  ]);
  const ev = validateEventPayload({ ...ENV, eid: '9f3a11c0-9', type: 'intrusion_cleared', aid: '9f3a11c0-7', via: 'lan' }).value;
  await svcWith(known).handleEvent({ topicId: 'h_t', homeId: HOME, deviceId: DEV, uid: UID, event: ev });
  const cl = known.calls.find((c) => /SET status = 'cleared'/.test(c.text));
  assert.deepEqual(cl.params, [31, 'device_event']);

  const unknown = scriptedDb([{ match: /^INSERT INTO device_events/, reply: () => ({ rows: [{ eid: 'x' }], rowCount: 1 }) }]);
  const push = pushRecorder();
  const s2 = svcWith(unknown, push);
  await s2.handleEvent({ topicId: 'h_t', homeId: HOME, deviceId: DEV, uid: UID, event: ev });
  await s2.idle();
  const tomb = unknown.calls.find((c) => /'tomb'/.test(c.text));
  assert.ok(tomb, 'mezar tasi');
  assert.equal(tomb.params[2], '9f3a11c0-7');
  assert.equal(tomb.params[4], 'intrusion');
  assert.ok(tomb.params[3] >= 1 && tomb.params[3] <= 4, 'bolge CHECK 1..4');
  assert.equal(push.sent.length, 0);
});

test('arm_changed -> yalniz denetim kaydi safety_arm_changed {mode, via}; alarm satiri / push yok', async () => {
  const db = scriptedDb([{ match: /^INSERT INTO device_events/, reply: () => ({ rows: [{ eid: 'x' }], rowCount: 1 }) }]);
  const push = pushRecorder();
  const svc = svcWith(db, push);
  const ev = validateEventPayload({ ...ENV, eid: '9f3a11c0-10', type: 'arm_changed', mode: 'away', via: 'cloud' }).value;
  await svc.handleEvent({ topicId: 'h_t', homeId: HOME, deviceId: DEV, uid: UID, event: ev });
  await svc.idle();
  const audit = db.calls.find((c) => /^INSERT INTO device_audit_logs/.test(c.text));
  assert.equal(audit.params[0], 'safety_arm_changed');
  const details = JSON.parse(audit.params[3]);
  assert.equal(details.mode, 'away');
  assert.equal(details.via, 'cloud');
  assert.equal(db.calls.filter((c) => /alarms/.test(c.text)).length, 0);
  assert.equal(push.sent.length, 0);
});

test('bolge olaylari (aid yok) bolgenin acik HIRSIZ satirini bulmaz (findAlarm kind <> intrusion)', () => {
  assert.match(SQL.findAlarm, /zone = \$3 AND kind <> 'intrusion' AND status NOT IN/);
});

// ------------------------------------------------------------------------------
// Alarm servisi: state uzlastirmasi
// ------------------------------------------------------------------------------
function liveDb(openRows) {
  return scriptedDb([
    { match: /^SELECT id, aid, zone, kind, status, ack_requested_at/, reply: () => ({ rows: openRows, rowCount: openRows.length }) },
    { match: /^INSERT INTO alarms/, reply: () => ({ rows: [{ id: 77 }], rowCount: 1 }) },
    { match: /SET status = 'lost'/, reply: (p) => ({ rows: [{ id: p[0] }], rowCount: 1 }) },
  ]);
}
const INTR_ROW = { id: 41, aid: '9f3a11c0-7', zone: 1, kind: 'intrusion', status: 'latched', ack_requested_at: null };
const CAPS = ['safety', 'actuator', 'event', 'cfg', 'intrusion'];
function summary(arm, extra = {}) {
  return { present: true, mode: 'normal', policy: 'on', cfg: null, zones: [], zones_complete: true, sensors: [{ id: 'd5', kind: 'door', zone: 3, active: true, ok: true }], arm, ...extra };
}
async function live(rows, s, caps = CAPS) {
  const db = liveDb(rows);
  const svc = svcWith(db, pushRecorder());
  const r = await svc.onLiveState({ topicId: 'h_t', homeId: HOME, deviceId: DEV, uid: UID, caps, summary: s, prev: null, hadCaps: true });
  await svc.idle();
  return { db, r };
}

test('KRITIK: bolge uzlastirmasi hirsiz satirini kapatmaz (zones[] tam ve bos olsa da)', async () => {
  const { db } = await live([INTR_ROW], summary({ mode: 'away', st: 'alarm', ok: true, aid: '9f3a11c0-7', srcs: ['d5'] }));
  assert.equal(db.calls.filter((c) => /SET status = 'cleared'|SET status = 'lost'/.test(c.text)).length, 0);
});

test('arm uzlastirmasi: st != alarm -> cleared (device_state); arm yok -> lost; arm.ok=false -> lost; baska aid -> cleared', async () => {
  let { db } = await live([INTR_ROW], summary({ mode: 'off', st: 'idle', ok: true, aid: null, srcs: [] }));
  assert.deepEqual(db.calls.find((c) => /SET status = 'cleared'/.test(c.text)).params, [41, 'device_state']);
  ({ db } = await live([INTR_ROW], summary(null)));
  assert.ok(db.calls.find((c) => /SET status = 'lost'/.test(c.text)), 'arm yok -> lost');
  ({ db } = await live([INTR_ROW], summary({ mode: 'away', st: 'alarm', ok: false, aid: '9f3a11c0-7', srcs: [] })));
  assert.ok(db.calls.find((c) => /SET status = 'lost'/.test(c.text)), 'ok=false -> lost');
  ({ db } = await live([INTR_ROW], summary({ mode: 'away', st: 'alarm', ok: true, aid: '9f3a11c0-9', srcs: ['d5'] })));
  assert.deepEqual(db.calls.find((c) => /SET status = 'cleared'/.test(c.text)).params, [41, 'device_state']);
  ({ db } = await live([INTR_ROW], summary({ mode: 'away', st: 'unknown', ok: true, aid: null, srcs: [] })));
  assert.equal(db.calls.filter((c) => /SET status = 'cleared'|SET status = 'lost'/.test(c.text)).length, 0, 'bilinmeyen durum: dokunma');
});

test('arm uzlastirmasi: olayi kaybolmus alarm state\'ten acilir (origin state, kind intrusion, bolge kaynak sensorunden)', async () => {
  const { db, r } = await live([], summary({ mode: 'away', st: 'alarm', ok: true, aid: '9f3a11c0-7', srcs: ['d5'] }));
  assert.equal(r.opened, 1);
  const ins = db.calls.find((c) => /^INSERT INTO alarms/.test(c.text));
  assert.deepEqual(ins.params.slice(2, 6), ['9f3a11c0-7', 3, 'intrusion', 'state']);
});

test('hirsiz alarmi state\'teyken temiz-pano onbellegi kurulmaz', async () => {
  const db = liveDb([]);
  const svc = svcWith(db, pushRecorder());
  db.query = async (text, params) => {
    db.calls.push({ text, params });
    if (/^INSERT INTO alarms/.test(text)) return { rows: [], rowCount: 0 }; // zaten var (ON CONFLICT)
    return { rows: [], rowCount: 0 };
  };
  const s = summary({ mode: 'away', st: 'alarm', ok: true, aid: '9f3a11c0-7', srcs: ['d5'] });
  await svc.onLiveState({ topicId: 'h_t', homeId: HOME, deviceId: DEV, uid: UID, caps: CAPS, summary: s, hadCaps: true });
  const before = db.calls.length;
  await svc.onLiveState({ topicId: 'h_t', homeId: HOME, deviceId: DEV, uid: UID, caps: CAPS, summary: s, hadCaps: true });
  assert.ok(db.calls.length > before, 'ikinci state yine sorgulanir');
});

// ------------------------------------------------------------------------------
// Komut semasi, rol matrisi
// ------------------------------------------------------------------------------
test('safety_arm komutu: mode away|home|off, uid zorunlu, id istege bagli; yetenek safety_arm', () => {
  const ok = validateCommand({ cmd: 'safety_arm', mode: 'away', uid: 'ahbu-s3-1a2b3c', id: 'c1' });
  assert.equal(ok.ok, true, ok.error);
  assert.deepEqual(ok.command, { cmd: 'safety_arm', mode: 'away', uid: UID, id: 'c1' });
  assert.equal(capabilityForCommand(ok), 'safety_arm');
  assert.equal(validateCommand({ cmd: 'safety_arm', mode: 'night', uid: UID }).ok, false);
  assert.equal(validateCommand({ cmd: 'safety_arm', mode: 'off' }).ok, false);
  assert.equal(validateCommand({ cmd: 'safety_arm', mode: 'off', uid: UID, zone: 1 }).ok, false);
});

test('rol matrisi: safety_arm yalniz owner + resident (misafir ve servis rolleri YOK)', () => {
  assert.deepEqual(rolesFor('safety_arm').sort(), ['owner', 'resident']);
  for (const r of ['super_user', 'service_user', 'service_session', 'guest']) assert.equal(can('safety_arm', r), false, r);
});

// ------------------------------------------------------------------------------
// Servis: kurma / cozme ve onay
// ------------------------------------------------------------------------------
function deviceSvc({ caps = [...CAPS], online = true, outcome = { ok: true } } = {}) {
  const db = {
    async query(text) {
      if (/FROM devices d\s+JOIN homes h ON h.id = d.home_id/.test(text)) {
        return { rows: [{ id: DEV, device_uuid: UID, is_online: online, topic_id: 'h_topic', caps }] };
      }
      if (/SELECT caps, safety_state FROM devices WHERE id = \$1/.test(text)) return { rows: [{ caps, safety_state: { mode: 'normal', zones: [] } }] };
      return { rows: [] };
    },
  };
  const published = [];
  const bridge = {
    isConnected: () => true,
    publishCommand: async (t, cmd) => {
      published.push(cmd);
      return {};
    },
    expectOutcome: () => Promise.resolve(outcome),
    cancelAck() {},
  };
  return { ds: new DeviceService({ db, mqttBridge: bridge }), published };
}

async function rejects(p, status, code) {
  await assert.rejects(p, (err) => {
    assert.equal(err.status || err.statusCode, status, `${err.code}: ${err.message}`);
    if (code) assert.equal(err.code, code);
    return true;
  });
}

test('armDevice: owner/resident kurar (panoya safety_arm + uid + id), misafir/servis 403', async () => {
  const { ds, published } = deviceSvc();
  const safety = new SafetyService({ deviceService: ds, alarmService: {} });
  const r = await safety.armDevice({ actor: { userId: 'u1', access: 'resident' }, homeId: HOME, deviceRef: UID, mode: 'away', commandId: 'arm-1' });
  assert.equal(r.applied, true);
  assert.deepEqual(published[0], { cmd: 'safety_arm', mode: 'away', uid: UID, id: 'arm-1' });
  for (const access of ['guest', 'service_user', 'service_session', 'super_user']) {
    await rejects(safety.armDevice({ actor: { userId: 'u1', access }, homeId: HOME, deviceRef: UID, mode: 'off' }), 403, 'FORBIDDEN');
  }
});

test('armDevice: caps intrusion yok -> 409 FIRMWARE_UNSUPPORTED; cevrimdisi -> 409 DEVICE_OFFLINE (kuyruk yok); not_ready -> DEVICE_REJECTED', async () => {
  const old = deviceSvc({ caps: ['safety', 'actuator', 'event', 'cfg'] });
  await rejects(new SafetyService({ deviceService: old.ds }).armDevice({ actor: { access: 'owner' }, homeId: HOME, deviceRef: UID, mode: 'away' }), 409, 'FIRMWARE_UNSUPPORTED');
  assert.equal(old.published.length, 0);
  const off = deviceSvc({ online: false });
  await rejects(new SafetyService({ deviceService: off.ds }).armDevice({ actor: { access: 'owner' }, homeId: HOME, deviceRef: UID, mode: 'away' }), 409, 'DEVICE_OFFLINE');
  const rej = deviceSvc({ outcome: { ok: false, rejected: 'not_ready' } });
  await assert.rejects(
    new SafetyService({ deviceService: rej.ds }).armDevice({ actor: { access: 'owner' }, homeId: HOME, deviceRef: UID, mode: 'away' }),
    (err) => err.code === 'DEVICE_REJECTED' && err.extra.reason === 'not_ready' && /açık kapı ya da pencere/.test(err.message)
  );
});

test('ackAlarm: hirsiz alarmi onaylanmaz -> 409 ALARM_USE_DISARM (komut yok, cevrimdisi kuyruk yok)', async () => {
  const sent = [];
  const alarms = {
    getAlarm: async () => ({ id: 41, home_id: HOME, device_id: DEV, device_uuid: UID, aid: '9f3a11c0-7', zone: 1, kind: 'intrusion', status: 'latched', is_online: false }),
    requestAck: async () => {
      sent.push('queued');
      return true;
    },
  };
  const safety = new SafetyService({ deviceService: { sendCommand: async () => sent.push('cmd') }, alarmService: alarms });
  await rejects(safety.ackAlarm({ actor: { access: 'owner' }, homeId: HOME, alarmId: '41' }), 409, 'ALARM_USE_DISARM');
  assert.deepEqual(sent, []);
});
