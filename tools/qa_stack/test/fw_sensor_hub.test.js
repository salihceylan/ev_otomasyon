// Firmware SensorHub/DiSensor/BridgeSensor (src/sensors/*.h) JS portunun UYUMLULUK testi: firmware'in kendi Unity testlerinin
// (ev_otomasyon_servis_yazilimi/waveshare_s3_demo/test/test_sensor_hub/test_main.cpp) BIREBIR portu.
import test from 'node:test';
import assert from 'node:assert/strict';
import {
  SensorHub, DiSensor, BridgeSensor, SensorKind, SensorSrc, HZ_WATER, HZ_GAS, HZ_SMOKE, SF_FAULT_CLOSE, SF_REACT, defaultFlags,
  defaultConfirmMs, confirmWindowMs, hazardOf, isControlRole, sensorIdText, makeSensorConfig,
} from '../sim/fw/sensor_hub.js';
import { DiGate, Edge, Mode, Action } from '../sim/fw/di_gate.js';

const u32 = (x) => x >>> 0;
const mk = (src, index, kind, zone, activeOpen) => makeSensorConfig({
  src, index, kind, zone, active_open: activeOpen, flags: defaultFlags(kind), confirm_ms: defaultConfirmMs(kind),
});
function drive(h, slot, level, ok, t, ms, step = 10) {
  for (let d = 0; d < ms; d += step) { t = u32(t + step); h.update(slot, level, ok, t); h.finish(t); }
  return t;
}
const hub = (cfgs, now = 0) => { const h = new SensorHub(); h.configure(cfgs, cfgs.length, now); return h; };

test('fw_sensor_hub: tur varsayilanlari', () => {
  assert.equal(defaultConfirmMs(SensorKind.WATER), 1000);
  assert.equal(defaultConfirmMs(SensorKind.GAS), 300);
  assert.equal(defaultConfirmMs(SensorKind.SMOKE), 300);
  assert.equal(defaultConfirmMs(SensorKind.DOOR), 0);
  assert.equal(confirmWindowMs(SensorKind.WATER), 3000);
  assert.equal(confirmWindowMs(SensorKind.GAS), 1000);
  assert.equal(hazardOf(SensorKind.WATER), HZ_WATER);
  assert.equal(hazardOf(SensorKind.GAS), HZ_GAS);
  assert.equal(hazardOf(SensorKind.SMOKE), HZ_SMOKE);
  assert.equal(hazardOf(SensorKind.DOOR), 0);
  assert.ok(isControlRole(SensorKind.ALARM_ACK) && isControlRole(SensorKind.GAS_RESET) && !isControlRole(SensorKind.WATER));
  assert.equal(defaultFlags(SensorKind.WATER) & SF_FAULT_CLOSE, 0);
  assert.equal(defaultFlags(SensorKind.GAS) & SF_FAULT_CLOSE, SF_FAULT_CLOSE);
  assert.equal(defaultFlags(SensorKind.SMOKE) & SF_FAULT_CLOSE, 0);
  assert.equal(defaultFlags(SensorKind.WATER) & SF_REACT, SF_REACT);
});

test('fw_sensor_hub: NC kontak seviyeyi cevirir', () => {
  const h = hub([mk(0, 1, SensorKind.DOOR, 1, 0), mk(0, 2, SensorKind.DOOR, 1, 1)]);
  h.update(0, true, true, 10); h.update(1, true, true, 10); h.finish(10);
  assert.equal(h.active(0), true);
  assert.equal(h.active(1), false);
  h.update(0, false, true, 20); h.update(1, false, true, 20); h.finish(20);
  assert.equal(h.active(0), false);
  assert.equal(h.active(1), true);
});

test('fw_sensor_hub: kisa sicrama onaylanmaz; kesintisiz islak confirm_ms sonra onaylanir', () => {
  let h = hub([mk(0, 3, SensorKind.WATER, 1, 0)]);
  let t = drive(h, 0, true, true, 0, 300);
  t = drive(h, 0, false, true, t, 4000);
  assert.equal(h.active(0), false);
  assert.equal(h.zoneWet(1), 0);
  h = hub([mk(0, 3, SensorKind.WATER, 1, 0)]);
  t = drive(h, 0, true, true, 0, 900);
  assert.equal(h.active(0), false);
  t = drive(h, 0, true, true, t, 200);
  assert.equal(h.active(0), true);
  assert.equal(h.zoneWet(1), HZ_WATER);
  assert.equal(h.zoneWet(2), 0);
});

test('fw_sensor_hub: damla deseni birikimle onaylanir; pencere eski etkinligi unutur; gaz hizli onay', () => {
  let h = hub([mk(0, 3, SensorKind.WATER, 1, 0)]);
  let t = 0;
  let seen = false;
  for (let k = 0; k < 8 && !seen; k++) {
    t = drive(h, 0, true, true, t, 300); seen ||= h.active(0);
    t = drive(h, 0, false, true, t, 200); seen ||= h.active(0);
  }
  assert.ok(seen && t <= 3000);
  h = hub([mk(0, 3, SensorKind.WATER, 1, 0)]);
  t = drive(h, 0, true, true, 0, 600);
  t = drive(h, 0, false, true, t, 5000);
  t = drive(h, 0, true, true, t, 600);
  assert.equal(h.active(0), false);
  h = hub([mk(0, 1, SensorKind.GAS, 1, 1)]);
  t = drive(h, 0, false, true, 0, 250);
  assert.equal(h.active(0), false);
  t = drive(h, 0, false, true, t, 100);
  assert.equal(h.active(0), true);
  assert.equal(h.zoneWet(1), HZ_GAS);
});

test('fw_sensor_hub: ok=false ne islak ne kuru; kuruluk kesintisiz ok && pasif ister; onay penceresi bosalmadan kuru sayilmaz', () => {
  let h = hub([mk(0, 3, SensorKind.WATER, 1, 0)]);
  let t = drive(h, 0, true, false, 0, 3000);
  assert.equal(h.active(0), false);
  assert.equal(h.zoneWet(1), 0);
  assert.equal(h.zoneFault(1), HZ_WATER);
  assert.equal(h.zoneDryMs(1, t), 0);
  t = drive(h, 0, false, false, t, 20000);
  assert.equal(h.zoneDryMs(1, t), 0);
  h = hub([mk(0, 3, SensorKind.WATER, 1, 0)]);
  t = drive(h, 0, false, true, 0, 5000);
  assert.ok(h.zoneDryMs(1, t) >= 4900);
  t = drive(h, 0, true, true, t, 20);
  t = drive(h, 0, false, true, t, 100);
  assert.ok(h.zoneDryMs(1, t) < 200);
  t = drive(h, 0, false, false, t, 20);
  t = drive(h, 0, false, true, t, 100);
  assert.ok(h.zoneDryMs(1, t) < 200);
  h = hub([mk(0, 3, SensorKind.WATER, 1, 0)]);
  t = drive(h, 0, true, true, 0, 2000);
  assert.equal(h.active(0), true);
  t = drive(h, 0, false, true, t, 100);
  assert.equal(h.active(0), true);
  assert.equal(h.zoneDryMs(1, t), 0);
  t = drive(h, 0, false, true, t, 4000);
  assert.equal(h.active(0), false);
  assert.ok(h.zoneDryMs(1, t) > 0);
});

test('fw_sensor_hub: ariza kenarlari bir kez; acilistaki bilinmeyen hal ariza degil', () => {
  let h = hub([mk(0, 3, SensorKind.WATER, 1, 0)]);
  let t = drive(h, 0, false, true, 0, 100);
  assert.equal(h.takeFaultEdges(), 0n);
  t = drive(h, 0, false, false, t, 100);
  assert.equal(h.takeFaultEdges(), 1n);
  assert.equal(h.takeFaultEdges(), 0n);
  t = drive(h, 0, false, true, t, 100);
  assert.equal(h.takeFaultClearedEdges(), 1n);
  assert.equal(h.takeFaultClearedEdges(), 0n);
  h = hub([mk(0, 9, SensorKind.WATER, 1, 1)]);
  t = drive(h, 0, false, false, 0, 500);
  assert.equal(h.takeFaultEdges(), 0n);
  assert.equal(h.active(0), false);
  t = drive(h, 0, true, true, t, 100);
  assert.equal(h.takeFaultClearedEdges(), 0n);
});

test('fw_sensor_hub: SF_FAULT_CLOSE arizayi islak sayar (gaz), su saymaz; hic okunamayan gaz 30 sn sonra', () => {
  const c = mk(0, 1, SensorKind.GAS, 1, 1);
  let h = hub([c]);
  let t = drive(h, 0, true, true, 0, 100);
  assert.equal(h.zoneWet(1), 0);
  t = drive(h, 0, true, false, t, 50);
  assert.equal(h.zoneWet(1), HZ_GAS);
  const h2 = hub([mk(0, 2, SensorKind.WATER, 1, 0)]);
  t = drive(h2, 0, false, true, 0, 100);
  t = drive(h2, 0, false, false, t, 50);
  assert.equal(h2.zoneWet(1), 0);
  assert.equal(h2.zoneFault(1), HZ_WATER);
  h = hub([c]);
  t = drive(h, 0, false, false, 0, 29000, 100);
  assert.equal(h.zoneWet(1), 0);
  t = drive(h, 0, false, false, t, 1100, 100);
  assert.equal(h.zoneWet(1), HZ_GAS);
});

test('fw_sensor_hub: tepki bayragi kapali sensor bolgeyi islatmaz; bolge kaynak listesi', () => {
  const c = mk(0, 3, SensorKind.WATER, 1, 0);
  c.flags = 0;
  const h = hub([c]);
  drive(h, 0, true, true, 0, 2000);
  assert.equal(h.active(0), true);
  assert.equal(h.zoneWet(1), 0);
  const h3 = hub([mk(0, 3, SensorKind.WATER, 1, 0), mk(1, 2, SensorKind.WATER, 1, 0), mk(0, 5, SensorKind.WATER, 2, 0)]);
  let t = 0;
  for (let k = 0; k < 150; k++) { t += 10; h3.update(0, true, true, t); h3.update(1, true, true, t); h3.update(2, false, true, t); h3.finish(t); }
  const ids = h3.zoneSources(1, HZ_WATER, 8);
  assert.deepEqual(ids, [3, 0x80 | 2]);
  assert.equal(sensorIdText(ids[1]), 'b2');
  assert.equal(sensorIdText(40), 'd40');
});

test('fw_sensor_hub: kontrol rolu kenari ve basili tutma; acilista basili kenar degil', () => {
  let h = hub([mk(0, 6, SensorKind.ALARM_ACK, 0, 0)]);
  let t = drive(h, 0, false, true, 0, 100);
  assert.equal(h.takeControlPresses(), 0n);
  t += 10; h.update(0, true, true, t); h.finish(t);
  assert.equal(h.takeControlPresses(), 1n);
  t = drive(h, 0, true, true, t, 5000);
  assert.equal(h.takeControlPresses(), 0n);
  assert.ok(h.heldMs(0, t) >= 5000);
  assert.equal(h.zoneWet(0), 0);
  t = drive(h, 0, false, true, t, 50);
  assert.equal(h.heldMs(0, t), 0);
  h = hub([mk(0, 6, SensorKind.VALVE_CLOSE, 0, 0)]);
  h.update(0, true, true, 10); h.finish(10);
  assert.equal(h.takeControlPresses(), 0n);
});

test('fw_sensor_hub: millis tasmasi; sensorsuz bolge yapilandirmadan beri kuru', () => {
  const h = new SensorHub();
  h.configure([mk(0, 3, SensorKind.WATER, 1, 0)], 1, 0xFFFFF000);
  let t = drive(h, 0, true, true, 0xFFFFF000, 1200);
  assert.equal(h.active(0), true);
  t = drive(h, 0, false, true, t, 15000);
  assert.equal(h.active(0), false);
  assert.ok(h.zoneDryMs(1, t) >= 10000);
  const h2 = hub([mk(0, 1, SensorKind.DOOR, 2, 0)], 1000);
  h2.update(0, true, true, 3000); h2.finish(3000);
  assert.equal(h2.zoneDryMs(2, 3000), 2000);
  assert.equal(h2.zoneDryMs(1, 3000), 2000);
});

test('fw_sensor_hub: DiSensor yerel ok ilk okumadan sonra; ek DI modul sagligina bagli; maske + MOMENTARY temizligi', () => {
  let g = new DiGate();
  let d = new DiSensor(g);
  const c = mk(0, 3, SensorKind.WATER, 1, 1);
  assert.equal(d.sample(c, 0).ok, false);
  d.setLocalReady(true);
  g.init(2, true, 0);
  assert.deepEqual(d.sample(c, 0), { level: true, ok: true });
  g = new DiGate();
  d = new DiSensor(g);
  d.setLocalReady(true);
  const e = mk(0, 9, SensorKind.WATER, 1, 1);
  assert.equal(d.sample(e, 0).ok, false);
  d.setExtOk(true);
  assert.equal(d.sample(e, 0).ok, true);
  d.setExtOk(false);
  assert.equal(d.sample(e, 0).ok, false);
  assert.equal(d.sample(mk(0, 41, SensorKind.WATER, 1, 0), 0).ok, false);
  g = new DiGate();
  let dec = g.decide(4, Edge.PRESS, Mode.MOMENTARY, false, false);
  assert.equal(dec.action, Action.RELAY_ON);
  assert.equal(g.acted(4), true);
  const mask = DiSensor.diMaskOf([mk(0, 5, SensorKind.WATER, 1, 0), mk(1, 1, SensorKind.WATER, 1, 0)], 2);
  assert.equal(mask, 1n << 4n);
  DiSensor.releaseMomentary(g, mask, 0);
  assert.equal(g.acted(4), false);
  dec = g.decide(4, Edge.RELEASE, Mode.MOMENTARY, false, false);
  assert.equal(dec.action, Action.NONE);
});

// pano-4 (Unity: test_di_sensor_new_ext_channels_unknown_until_first_read): kanal sayisi artinca yeni ek kanallar ilk taze okumaya kadar
// "okunamadi" (NC gaz sahte alarm uretmez); mevcut kanallar etkilenmez; setExtReady cagrilmazsa eski davranis.
test('fw_sensor_hub: DiSensor yeni ek kanal ilk okumaya kadar bilinmiyor; mevcut kanal ve varsayilan davranis degismez (pano-4)', () => {
  const g = new DiGate();
  const d = new DiSensor(g);
  d.setLocalReady(true);
  d.setExtOk(true);
  d.setExtReady(8);
  const cs = [mk(0, 9, SensorKind.GAS, 1, 1), mk(0, 17, SensorKind.GAS, 1, 1)];
  g.init(8, true, 0);
  assert.equal(d.sample(cs[0], 0).ok, true);
  assert.equal(d.sample(cs[1], 0).ok, false);
  const h = new SensorHub();
  h.configure(cs, 2, 0);
  let t = 0;
  for (; t < 2000; t += 10) {
    for (let i = 0; i < 2; i++) { const s = d.sample(cs[i], t); h.update(i, s.level, s.ok, t); }
    h.finish(t);
  }
  assert.equal(h.zoneWet(1), 0);
  assert.equal(h.ok(0), true);
  g.init(16, true, t);
  d.setExtReady(16);
  assert.equal(d.sample(cs[1], t).ok, true);
  assert.equal(d.sample(cs[1], t).level, true);
  for (const e = t + 2000; t < e; t += 10) {
    for (let i = 0; i < 2; i++) { const s = d.sample(cs[i], t); h.update(i, s.level, s.ok, t); }
    h.finish(t);
  }
  assert.equal(h.zoneWet(1), 0);
  assert.equal(h.ok(1), true);
  const d2 = new DiSensor(g);
  d2.setExtOk(true);
  assert.equal(d2.sample(cs[1], 0).ok, true);
});

test('fw_sensor_hub: BridgeSensor kalp atisi', () => {
  const b = new BridgeSensor();
  const c = mk(SensorSrc.BRIDGE, 2, SensorKind.WATER, 1, 0);
  assert.equal(b.sample(c, 0).ok, false);
  b.report({ slot: 2, active: true, ok: true, at_ms: 1000 });
  assert.deepEqual(b.sample(c, 1000 + 899999), { level: true, ok: true });
  assert.equal(b.sample(c, 1000 + 900001).ok, false);
  b.setHeartbeat(2, 60000);
  b.report({ slot: 2, active: false, ok: true, at_ms: 5000 });
  assert.equal(b.sample(c, 64000).ok, true);
  assert.equal(b.sample(c, 65001).ok, false);
  b.report({ slot: 17, active: true, ok: true, at_ms: 1 });
  b.report({ slot: 3, active: false, ok: false, at_ms: 70000 });
  assert.equal(b.sample(mk(SensorSrc.BRIDGE, 3, SensorKind.WATER, 1, 0), 70000).ok, false);
});

// fw-tarama-3 (Unity: test_confirm_window_grows_for_long_confirm, test_long_confirm_stays_confirmed_while_active): confirm_ms tur
// penceresinden uzunsa pencere buyur (max(tur penceresi, ceil(confirm_ms*8/7) 8'in katina)); kucuk degerlerde zamanlama birebir ayni.
function msUntilConfirmed(kind, confirmMs, maxMs) {
  const c = mk(SensorSrc.DI, 1, kind, 1, hazardOf(kind) === HZ_WATER ? 0 : 1);
  c.confirm_ms = confirmMs;
  const h = hub([c]);
  const level = !c.active_open;
  let t = 100;
  h.update(0, level, true, t); h.finish(t);
  for (let d = 10; d <= maxMs; d += 10) {
    t += 10;
    h.update(0, level, true, t); h.finish(t);
    if (h.active(0)) return d;
  }
  return 0;
}

test('fw_sensor_hub: uzun onay suresi surekli aktiflikte onaylanir; varsayilan zamanlama degismez (fw-tarama-3)', () => {
  const gas = msUntilConfirmed(SensorKind.GAS, 1500, 10000);
  assert.ok(gas >= 1500 && gas <= 1800, `gaz 1500 ms: ~1,5-1,8 sn icinde onay (gelen ${gas})`);
  const water = msUntilConfirmed(SensorKind.WATER, 5000, 12000);
  assert.ok(water >= 5000 && water <= 6000, `su 5000 ms: 5-6 sn icinde onay (gelen ${water})`);
  assert.equal(msUntilConfirmed(SensorKind.WATER, 10000, 15000), 10000);
  assert.equal(msUntilConfirmed(SensorKind.WATER, 1000, 5000), 1000, 'regresyon: su varsayilani');
  assert.equal(msUntilConfirmed(SensorKind.GAS, 300, 5000), 300, 'regresyon: gaz varsayilani');
  // pencerenin 7/8'inden buyuk deger onayli KALIR (eskiden gaz 950 ms her kova basinda dusup kalkiyordu)
  const c = mk(SensorSrc.DI, 1, SensorKind.GAS, 1, 1);
  c.confirm_ms = 950;
  const h = hub([c]);
  let t = drive(h, 0, false, true, 0, 1200);
  assert.equal(h.active(0), true);
  for (let d = 0; d < 3000; d += 10) {
    t += 10;
    h.update(0, false, true, t); h.finish(t);
    assert.equal(h.active(0), true, `surekli aktifken onay dusmemeli (t=${t})`);
  }
});

test('fw_sensor_hub: onay penceresi hesabi (windowMs, fw-tarama-3)', () => {
  assert.equal(SensorHub.windowMs(SensorKind.GAS, 300), 1000);
  assert.equal(SensorHub.windowMs(SensorKind.GAS, 875), 1000);
  assert.equal(SensorHub.windowMs(SensorKind.GAS, 876), 1008);
  assert.equal(SensorHub.windowMs(SensorKind.GAS, 1500), 1720);
  assert.equal(SensorHub.windowMs(SensorKind.WATER, 1000), 3000);
  assert.equal(SensorHub.windowMs(SensorKind.WATER, 5000), 5720);
  assert.equal(SensorHub.windowMs(SensorKind.WATER, 10000), 11432);
  assert.equal(SensorHub.windowMs(SensorKind.DOOR, 500), 0);
});
