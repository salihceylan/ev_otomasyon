// Firmware ContactBus (src/sensors/ContactBus.h) JS portunun UYUMLULUK testi: firmware'in kendi Unity testlerinin
// (ev_otomasyon_servis_yazilimi/waveshare_s3_demo/test/test_contact_bus/test_main.cpp) BIREBIR portu (Faz 2 F2.B.5).
import test from 'node:test';
import assert from 'node:assert/strict';
import { ContactBus, feedContacts } from '../sim/fw/contact_bus.js';
import { SensorHub, SensorKind, SensorSrc, SF_REACT, makeSensorConfig } from '../sim/fw/sensor_hub.js';

test('fw_contact_bus: ilk gozlem kenar degil; ayni seviye kenar degil; degisim kenar', () => {
  const bus = new ContactBus();
  const c = bus.cursor();
  bus.observe(0, SensorKind.DOOR, 1, true, true, 100);
  assert.equal(bus.read(c), null);
  assert.equal(bus.known(0), true);
  assert.equal(bus.isOpen(0), true);
  bus.observe(0, SensorKind.DOOR, 1, true, true, 200);
  assert.equal(bus.read(c), null);
  bus.observe(0, SensorKind.DOOR, 1, true, false, 300);
  assert.deepEqual(bus.read(c), { slot: 0, kind: SensorKind.DOOR, zone: 1, open: 0, at_ms: 300 });
  assert.equal(bus.read(c), null);
});

test('fw_contact_bus: yalniz kapi ve pencere kenarlari', () => {
  const bus = new ContactBus();
  const c = bus.cursor();
  [SensorKind.MOTION, SensorKind.WATER, SensorKind.GAS, SensorKind.ARM_KEY, SensorKind.GENERIC].forEach((k, i) => {
    bus.observe(i, k, 1, true, false, 10);
    bus.observe(i, k, 1, true, true, 20);
  });
  assert.equal(bus.read(c), null);
  bus.observe(9, SensorKind.WINDOW, 3, true, false, 10);
  bus.observe(9, SensorKind.WINDOW, 3, true, true, 20);
  const e = bus.read(c);
  assert.equal(e.open, 1);
  assert.equal(e.zone, 3);
});

test('fw_contact_bus: ok=false bilinmeyen, kenar yok; yeniden ilk gozlem kenar degil', () => {
  const bus = new ContactBus();
  const c = bus.cursor();
  bus.observe(2, SensorKind.WINDOW, 1, true, false, 10);
  bus.observe(2, SensorKind.WINDOW, 1, false, true, 20);
  assert.equal(bus.known(2), false);
  assert.equal(bus.read(c), null);
  bus.observe(2, SensorKind.WINDOW, 1, true, true, 30);
  assert.equal(bus.read(c), null);
  assert.equal(bus.isOpen(2), true);
});

test('fw_contact_bus: halka tasmasi en eskiyi dusurur', () => {
  const bus = new ContactBus();
  const slow = bus.cursor();
  bus.observe(0, SensorKind.DOOR, 1, true, false, 0);
  for (let k = 1; k <= 20; k++) bus.observe(0, SensorKind.DOOR, 1, true, (k & 1) !== 0, k * 10);
  const got = [];
  for (let e = bus.read(slow); e; e = bus.read(slow)) got.push(e.at_ms);
  assert.equal(got.length, ContactBus.CAP);
  assert.equal(got[0], 50);
  assert.equal(bus.dropped(), 4);
});

test('fw_contact_bus: okuyucular bagimsiz', () => {
  const bus = new ContactBus();
  const a = bus.cursor();
  bus.observe(1, SensorKind.WINDOW, 2, true, false, 0);
  bus.observe(1, SensorKind.WINDOW, 2, true, true, 10);
  const b = bus.cursor();
  bus.observe(1, SensorKind.WINDOW, 2, true, false, 20);
  assert.equal(bus.read(a).at_ms, 10);
  assert.equal(bus.read(a).at_ms, 20);
  assert.equal(bus.read(a), null);
  assert.equal(bus.read(b).at_ms, 20);
  assert.equal(bus.read(b), null);
});

test('fw_contact_bus: zoneWindowOpenFor (kapi sayilmaz, millis tasmasi)', () => {
  const bus = new ContactBus();
  bus.observe(4, SensorKind.WINDOW, 2, true, false, 0);
  bus.observe(5, SensorKind.DOOR, 2, true, true, 0);
  assert.equal(bus.zoneWindowOpenFor(2, 100000, 60000), false);
  bus.observe(4, SensorKind.WINDOW, 2, true, true, 1000);
  assert.equal(bus.zoneWindowOpenFor(2, 60999, 60000), false);
  assert.equal(bus.zoneWindowOpenFor(2, 61000, 60000), true);
  assert.equal(bus.zoneWindowOpenFor(1, 61000, 60000), false);
  bus.observe(4, SensorKind.WINDOW, 2, true, false, 62000);
  assert.equal(bus.zoneWindowOpenFor(2, 200000, 60000), false);
  bus.observe(4, SensorKind.WINDOW, 2, true, true, 0xFFFFF000);
  assert.equal(bus.zoneWindowOpenFor(2, (0xFFFFF000 + 60000) >>> 0, 60000), true);
});

test('fw_contact_bus: reset seviyeleri unutur', () => {
  const bus = new ContactBus();
  const c = bus.cursor();
  bus.observe(0, SensorKind.DOOR, 1, true, false, 0);
  bus.reset();
  assert.equal(bus.known(0), false);
  bus.observe(0, SensorKind.DOOR, 1, true, true, 10);
  assert.equal(bus.read(c), null);
});

test('fw_contact_bus: SensorHub beslemesi', () => {
  const s = [
    makeSensorConfig({ src: SensorSrc.DI, index: 1, kind: SensorKind.DOOR, zone: 1, active_open: 1, flags: SF_REACT }),
    makeSensorConfig({ src: SensorSrc.DI, index: 2, kind: SensorKind.WATER, zone: 1, flags: SF_REACT, confirm_ms: 1000 }),
    makeSensorConfig({ src: SensorSrc.DI, index: 3, kind: SensorKind.WINDOW, zone: 2, active_open: 1, flags: SF_REACT }),
  ];
  const hub = new SensorHub();
  hub.configure(s, 3, 0);
  const bus = new ContactBus();
  const c = bus.cursor();
  hub.update(0, true, true, 10); hub.update(1, false, true, 10); hub.update(2, true, true, 10); hub.finish(10);
  feedContacts(hub, bus, 10);
  hub.update(0, false, true, 20); hub.update(1, true, true, 20); hub.update(2, true, true, 20); hub.finish(20);
  feedContacts(hub, bus, 20);
  const e = bus.read(c);
  assert.equal(e.slot, 0);
  assert.equal(e.open, 1);
  assert.equal(bus.read(c), null);
});
