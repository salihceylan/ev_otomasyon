// Firmware EventOutbox LAN olay halkasi (src/events/EventOutbox.h) JS portunun UYUMLULUK testi: firmware'in kendi Unity testlerinin
// (ev_otomasyon_servis_yazilimi/waveshare_s3_demo/test/test_event_log/test_main.cpp) BIREBIR portu.
import test from 'node:test';
import assert from 'node:assert/strict';
import { EventOutbox, EvType, makeEvent } from '../sim/fw/event_outbox.js';

const ev = (type, zone = 1, o = {}) => makeEvent({ type, zone, atUp: 10, ...o });

test('fw_event_log: onaylanan olay halkada kalir; JSON outbox yayini ile ayni', () => {
  const o = new EventOutbox();
  o.begin(0x9f3a11c0);
  const eid = o.push(ev(EvType.ALARM_RAISED));
  assert.equal(eid, '9f3a11c0-1');
  assert.equal(o.ack(eid), true);
  assert.equal(o.count(), 0);
  assert.equal(o.logCount(), 1);
  const j = o.logJson(0, 'AHBU-S3-0A0010', 7);
  assert.ok(j.includes('"eid":"9f3a11c0-1"') && j.includes('"type":"alarm_raised"'));
  const o2 = new EventOutbox();
  o2.begin(0x11111111);
  o2.push(ev(EvType.TEST_RESULT, 2, { flag: 1, val: 420 }));
  assert.equal(o2.logJson(0, 'U', 3), o2.toJson(o2.list()[0].slot, 'U', 3));
});

test('fw_event_log: after eid sonrasi; bilinmeyen/baska acilis -> bastan; tasmada en eskiler duser', () => {
  const o = new EventOutbox();
  o.begin(0x01020304);
  for (let i = 0; i < 5; i++) o.push(ev(EvType.ACTUATOR_CHANGED));
  assert.equal(o.logAfter(null), 0);
  assert.equal(o.logAfter(''), 0);
  assert.equal(o.logAfter('01020304-3'), 3);
  assert.equal(o.logAfter('01020304-5'), 5);
  assert.equal(o.logAfter('deadbeef-3'), 0);
  assert.equal(o.logAfter('01020304-99'), 0);
  assert.ok(o.logJson(3, 'u', 1).includes('"eid":"01020304-4"'));
  const r = new EventOutbox();
  r.begin(0xAABBCCDD);
  for (let i = 0; i < 40; i++) r.ack(r.push(ev(EvType.SENSOR_FAULT)));
  assert.equal(r.logCount(), EventOutbox.LOG_CAP);
  assert.ok(r.logJson(0, 'u', 1).includes('"eid":"aabbccdd-9"'));
  assert.ok(r.logJson(EventOutbox.LOG_CAP - 1, 'u', 1).includes('"eid":"aabbccdd-40"'));
  assert.equal(r.logJson(EventOutbox.LOG_CAP, 'u', 1), '');
  assert.equal(r.logAfter('aabbccdd-40'), EventOutbox.LOG_CAP);
  assert.equal(r.logAfter('aabbccdd-3'), 0);
});
