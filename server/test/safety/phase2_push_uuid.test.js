'use strict';

// Faz 2 / WP-N1 (F2.C.8): guvenlik push'unun `data`'sina panonun uid'si (`device_uuid`). Uygulama kritik alarm kartini
// pano uid'siyle anahtarladigi icin gerekir. Gecersiz bicim ATILIR (alan hic yazilmaz); `v` "1" kalir (ek alan).

const test = require('node:test');
const assert = require('node:assert/strict');

const { buildMessage } = require('../../src/services/push_service');
const { createAlarmService, SQL } = require('../../src/services/alarm_service');

const HOME = '11111111-2222-4333-8444-555555555555';
const DEV = '22222222-3333-4444-8555-666666666666';
const UID = 'AHBU-S3-1A2B3C';
const TOKEN = 'tok-aaaaaaaaaaaaaaaaaaaaa';

function msg(kind, data) {
  return buildMessage({ token: TOKEN, title: 'T', body: 'B', kind, data, nowMs: 0 }).message;
}

test('buildMessage: safety_alarm ve safety_info data.device_uuid tasir (buyuk harf pano uid)', () => {
  const a = msg('safety_alarm', { home_id: HOME, device_id: DEV, device_uuid: UID, alarm_id: 1, zone: 1, kind: 'gas', status: 'latched' });
  assert.equal(a.data.device_uuid, UID);
  assert.equal(a.data.v, '1');
  const i = msg('safety_info', { home_id: HOME, device_id: DEV, device_uuid: UID, alarm_id: 1, reason: 'cfg_pending_dropped' });
  assert.equal(i.data.device_uuid, UID);
  assert.equal(i.data.reason, 'cfg_pending_dropped');
  // kucuk harf gelirse buyuk harfe cevrilir (uygulama ^[A-Z0-9-]{1,32}$ bekler)
  assert.equal(msg('safety_alarm', { device_uuid: 'ahbu-s3-1a2b3c' }).data.device_uuid, UID);
});

test('buildMessage: gecersiz/eksik device_uuid ATILIR (anahtar yok); diger alanlar aynen', () => {
  for (const bad of [undefined, null, '', 'AHBU S3', 'AHBU_S3_1', 'A'.repeat(33), 42, { x: 1 }]) {
    const a = msg('safety_alarm', { home_id: HOME, device_id: DEV, device_uuid: bad, alarm_id: 1, zone: 1, kind: 'water', status: 'latched' });
    assert.equal(Object.prototype.hasOwnProperty.call(a.data, 'device_uuid'), false, String(bad));
    assert.deepEqual(a.data, { type: 'safety_alarm', v: '1', home_id: HOME, device_id: DEV, alarm_id: '1', zone: '1', kind: 'water', status: 'latched' });
  }
});

function harness(claimRow) {
  const calls = [];
  const db = {
    query: async (text, params) => {
      calls.push({ text, params });
      if (/SET push_status = 'claimed'/.test(text)) return { rows: [claimRow], rowCount: 1 };
      return { rows: [], rowCount: 1 };
    },
    withTransaction: async (fn) => fn({ query: db.query }),
  };
  const sent = [];
  const push = {
    isConfigured: () => true,
    recipientsForHome: async () => [{ id: 'p1', token: TOKEN }],
    sendNotice: async (args) => {
      sent.push(args);
      return { sent: 1 };
    },
  };
  const svc = createAlarmService({ db, publishCommand: async () => {}, getPush: () => push, logger: { log() {}, warn() {}, error() {} }, sleep: async () => {} });
  return { svc, sent, calls };
}

test('pushAlarm: talep satiri device_uuid dondurur (ek sorgu yok) ve push data.device_uuid olur', async () => {
  assert.match(SQL.claimPush, /RETURNING id, home_id, device_id, zone, kind, status, \(SELECT d\.device_uuid FROM devices d WHERE d\.id = alarms\.device_id\) AS device_uuid/);
  const h = harness({ id: 5, home_id: HOME, device_id: DEV, zone: 1, kind: 'gas', status: 'latched', device_uuid: UID });
  assert.equal(await h.svc.pushAlarm(5), 'sent');
  assert.equal(h.sent[0].data.device_uuid, UID);
});

test('pushInfo: cagiranin bildigi pano uid\'si data.device_uuid olur (ek sorgu yok)', async () => {
  const h = harness({});
  await h.svc.pushInfo({ homeId: HOME, deviceId: DEV, deviceUuid: UID, alarmId: 3, reason: 'alarm_lost' });
  assert.equal(h.sent[0].data.device_uuid, UID);
  assert.equal(h.calls.length, 0);
});

test('handleEvent policy_changed -> bilgi push\'u olayin uid\'siyle (device_uuid)', async () => {
  const h = harness({});
  h.svc._deps.db = h.svc.db = {
    query: async () => ({ rows: [{ eid: 'x' }], rowCount: 1 }),
    withTransaction: async (fn) => fn({ query: async () => ({ rows: [{ eid: 'x' }], rowCount: 1 }) }),
  };
  await h.svc.handleEvent({
    topicId: 'h_t', homeId: HOME, deviceId: DEV, uid: UID,
    event: { eid: '9f3a11c0-4', type: 'policy_changed', policy: 'off', via: 'cli' },
  });
  await h.svc.idle();
  assert.equal(h.sent.length, 1);
  assert.equal(h.sent[0].kind, 'safety_info');
  assert.equal(h.sent[0].data.device_uuid, UID);
});
