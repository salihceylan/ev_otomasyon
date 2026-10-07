// Firmware EventOutbox (src/events/EventOutbox.h) JS portunun UYUMLULUK testi: firmware'in kendi Unity testlerinin
// (ev_otomasyon_servis_yazilimi/waveshare_s3_demo/test/test_event_outbox/test_main.cpp) BIREBIR portu.
import test from 'node:test';
import assert from 'node:assert/strict';
import { EventOutbox, EvType, makeEvent, EID_LEN } from '../sim/fw/event_outbox.js';
import { HZ_WATER, HZ_GAS, HZ_SMOKE } from '../sim/fw/sensor_hub.js';

const ev = (type, zone = 1) => makeEvent({ type, zone });

test('fw_event_outbox: eid bicimi ve sayac; 5 haneye sarma', () => {
  const o = new EventOutbox();
  o.begin(0x9f3a11c0);
  assert.equal(o.push(ev(EvType.ALARM_RAISED)), '9f3a11c0-1');
  assert.equal(o.push(ev(EvType.ALARM_CLEARED)), '9f3a11c0-2');
  o.begin(0x0000000A);
  assert.equal(o.push(ev(EvType.ALARM_RAISED)), '0000000a-1');
  assert.equal(o.count(), 1);
  o.begin(1);
  o.setNextN(99999);
  assert.equal(o.push(ev(EvType.ACTUATOR_CHANGED)), '00000001-99999');
  assert.equal(o.push(ev(EvType.ACTUATOR_CHANGED)), '00000001-1');
  assert.ok('ffffffff-99999'.length < EID_LEN);
});

test('fw_event_outbox: yeniden deneme plani ve yeniden baglanma penceresi', () => {
  const o = new EventOutbox();
  o.begin(1);
  o.push(ev(EvType.ALARM_RAISED));
  let t = 2000;
  let s = o.nextDue(t, 0);
  assert.equal(s, 0);
  for (const gap of [5000, 10000, 20000, 40000, 60000, 60000, 60000]) {
    o.markSent(s, t);
    assert.equal(o.nextDue(t + gap - 1, 0), -1);
    t += gap;
    s = o.nextDue(t, 0);
    assert.equal(s, 0);
  }
  const p = new EventOutbox();
  p.begin(1);
  p.push(ev(EvType.ALARM_RAISED));
  assert.equal(p.nextDue(10000 + 1499, 10000), -1);
  assert.equal(p.nextDue(10000 + 1500, 10000), 0);
  assert.equal(p.nextDue(0x00000100, 0xFFFFFF00), -1);
  assert.equal(p.nextDue(0x00000600 + 1000, 0xFFFFFF00), 0);
});

test('fw_event_outbox: ack siler, coklu ack; en eski once', () => {
  const o = new EventOutbox();
  o.begin(0xabcdef01);
  const e1 = o.push(ev(EvType.ALARM_RAISED));
  const e2 = o.push(ev(EvType.SENSOR_FAULT));
  const e3 = o.push(ev(EvType.ALARM_CLEARED));
  assert.equal(o.count(), 3);
  assert.equal(o.ack(e2), true);
  assert.equal(o.ack(e2), false);
  assert.equal(o.ack('abcdef01-99'), false);
  assert.equal(o.ack('12345678-1'), false);
  assert.equal(o.count(), 2);
  assert.equal(o.ackMany([e1, e3, 'x']), 2);
  assert.equal(o.count(), 0);
  assert.equal(o.nextDue(100000, 0), -1);
  const p = new EventOutbox();
  p.begin(1);
  p.push(ev(EvType.ALARM_RAISED));
  p.push(ev(EvType.ACTUATOR_CHANGED));
  const a = p.nextDue(5000, 0);
  p.markSent(a, 5000);
  const b = p.nextDue(5000, 0);
  assert.notEqual(a, b);
  assert.equal(p.at(a).type, EvType.ALARM_RAISED);
  assert.equal(p.at(b).type, EvType.ACTUATOR_CHANGED);
});

test('fw_event_outbox: tasmada atilma onceligi', () => {
  const o = new EventOutbox();
  o.begin(1);
  const firstAlarm = o.push(ev(EvType.ALARM_RAISED));
  o.push(ev(EvType.ACTUATOR_CHANGED));
  o.push(ev(EvType.ALARM_CLEARED));
  o.push(ev(EvType.VALVE_FAULT_CLEARED));
  o.push(ev(EvType.SENSOR_FAULT));
  for (let i = 0; i < 11; i++) o.push(ev(EvType.ALARM_RAISED));
  assert.equal(o.count(), 16);
  assert.equal(o.countOf(EvType.ACTUATOR_CHANGED), 1);
  o.push(ev(EvType.VALVE_FAULT));
  assert.equal(o.countOf(EvType.ACTUATOR_CHANGED), 0);
  o.push(ev(EvType.VALVE_FAULT));
  assert.equal(o.countOf(EvType.ALARM_CLEARED), 0);
  assert.equal(o.countOf(EvType.VALVE_FAULT_CLEARED), 1);
  o.push(ev(EvType.VALVE_FAULT));
  assert.equal(o.countOf(EvType.VALVE_FAULT_CLEARED), 0);
  o.push(ev(EvType.VALVE_FAULT));
  assert.equal(o.countOf(EvType.SENSOR_FAULT), 0);
  assert.equal(o.ack(firstAlarm), true);
  o.push(ev(EvType.ALARM_RAISED));
  assert.equal(o.count(), 16);
  o.push(ev(EvType.ALARM_RAISED));
  assert.equal(o.count(), 16);
  assert.equal(o.overwrites(), 1);
});

test('fw_event_outbox: JSON alarm_raised birebir; turlere ozel alanlar; en kotu durum boyutu', () => {
  const o = new EventOutbox();
  o.begin(0x9f3a11c0);
  o.setNextN(3);
  o.push(makeEvent({ type: EvType.ALARM_RAISED, zone: 1, kinds: HZ_WATER, nsrcs: 1, srcs: [3], atUp: 3000, atEpoch: 1791273000, actClose: 1, actOn: 2 }));
  assert.equal(o.toJson(0, 'AHBU-S3-0011', 57),
    '{"v":1,"uid":"AHBU-S3-0011","eid":"9f3a11c0-3","bn":"9f3a11c0","boot":57,"n":3,"type":"alarm_raised","zone":1,"kind":"water",'
    + '"srcs":["d3"],"at":1791273000,"at_up":3000,"actions":[{"a":"a1","do":"close"},{"a":"a2","do":"on"}]}');
  const p = new EventOutbox();
  p.begin(1);
  p.push(makeEvent({ type: EvType.TEST_RESULT, zone: 2, flag: 1, sub: 1, val: 4200, atUp: 10 }));
  let j = p.toJson(0, 'U', 1);
  assert.ok(j.includes('"type":"test_result","zone":2,"ok":true,"fb_ms":4200'));
  assert.ok(!j.includes('"at":'));
  p.push(makeEvent({ type: EvType.SAFE_MODE, sub: 2 }));
  assert.ok(p.toJson(1, 'U', 1).includes('"type":"safe_mode","reason":"latch_orphan"'));
  p.push(makeEvent({ type: EvType.CFG_CONFLICT, rev: 12, crc: 0x9a3c11f0 }));
  assert.ok(p.toJson(2, 'U', 1).includes('"type":"cfg_conflict","rev":12,"crc":"9a3c11f0"'));
  p.push(makeEvent({ type: EvType.POLICY_CHANGED, flag: 0, sub: 1 }));
  j = p.toJson(3, 'U', 1);
  assert.ok(j.includes('"type":"policy_changed","policy":"off","via":"lan"'));
  assert.equal(p.toJson(3, 'U', 1, 20), '');
  assert.equal(p.toJson(9, 'U', 1), '');
  const w = new EventOutbox();
  w.begin(0xffffffff);
  w.setNextN(99999);
  w.push(makeEvent({ type: EvType.ALARM_RAISED, zone: 4, kinds: HZ_GAS | HZ_WATER | HZ_SMOKE, nsrcs: 8, srcs: [0, 1, 2, 3, 4, 5, 6, 7].map((i) => 0x80 | (9 + i)), atUp: 0xFFFFFFFF, atEpoch: 0xFFFFFFFF, actClose: 0xFFFF, aid: 'ffffffff-99999' }));
  const n = w.toJson(0, 'AHBU-S3-0123456789AB', 0xFFFFFFFF).length;
  assert.ok(n > 0 && n < 768 && n <= 700, `en kotu durum ${n} B`);
});

test('fw_event_outbox: alarm olaylari aid tasir; geri bildirimsiz test_result fb_ms yazmaz (CONTRACTS 2.6)', () => {
  const o = new EventOutbox();
  o.begin(0x0badf00d);
  o.push(makeEvent({ type: EvType.ALARM_CLEARED, zone: 3, kinds: HZ_WATER, aid: '9f3a11c0-3' }));
  assert.ok(o.toJson(0, 'U', 1).includes('"type":"alarm_cleared","zone":3,"kind":"water","aid":"9f3a11c0-3","at_up":0}'));
  o.push(makeEvent({ type: EvType.ALARM_RAISED, zone: 1 }));
  assert.ok(!o.toJson(1, 'U', 1).includes('"aid"'));
  o.push(makeEvent({ type: EvType.TEST_RESULT, zone: 2, flag: 1 }));
  const j = o.toJson(2, 'U', 1);
  assert.ok(j.includes('"type":"test_result","zone":2,"ok":true,"at_up":0'));
  assert.ok(!j.includes('fb_ms'));
});
