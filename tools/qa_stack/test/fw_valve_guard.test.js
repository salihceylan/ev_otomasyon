// Firmware ValveGuard (src/safety/ValveGuard.h) JS portunun UYUMLULUK testi: firmware'in kendi Unity testlerinin
// (ev_otomasyon_servis_yazilimi/waveshare_s3_demo/test/test_valve_guard/test_main.cpp) BIREBIR portu.
import test from 'node:test';
import assert from 'node:assert/strict';
import { ActKind, CloseMode, Medium, makeActuatorConfig } from '../sim/fw/actuator_map.js';
import { safeHoldMasks, planLocalGuard, extGuardBits, ExtGuardPacer } from '../sim/fw/valve_guard.js';

const valve = (relay, mode, medium = Medium.WATER) => makeActuatorConfig({ relay, kind: ActKind.VALVE, close_mode: mode, medium, zone_mask: 1 });
const siren = (relay) => makeActuatorConfig({ relay, kind: ActKind.SIREN, zone_mask: 1, run_limit_s: 180 });
const pulse = (c, o) => ({ ...valve(c, CloseMode.PULSE_TWO_RELAY), relay2: o, run_limit_s: 15 });
const bit = (r) => 1n << BigInt(r - 1);
const E2C = CloseMode.ENERGIZE_TO_CLOSE;
const D2C = CloseMode.DEENERGIZE_TO_CLOSE;

test('fw_valve_guard: tutma maskeleri yalniz KAPALI komutlu vanalar; iki roleli vanada AC rolesi 0; kilit maskesi kazanir', () => {
  const a = [valve(1, E2C), valve(2, D2C), valve(3, E2C), siren(4), valve(12, E2C)];
  let m = safeHoldMasks(a, 5, 0x13, 0n, 0n);
  assert.equal(m.assert, bit(1) | bit(2) | bit(12));
  assert.equal(m.level, bit(1) | bit(12));
  m = safeHoldMasks(a, 5, 0, 0n, 0n);
  assert.equal(m.assert, 0n);
  assert.equal(m.level, 0n);
  m = safeHoldMasks([pulse(5, 6)], 1, 0x01, 0n, 0n);
  assert.equal(m.assert, bit(6));
  assert.equal(m.level, 0n);
  m = safeHoldMasks(null, 0, 0, bit(3) | bit(4), bit(3));
  assert.equal(m.assert, bit(3) | bit(4));
  assert.equal(m.level, bit(3));
  m = safeHoldMasks([valve(3, D2C)], 1, 0x01, bit(3), bit(3));
  assert.equal(m.assert, bit(3));
  assert.equal(m.level, bit(3));
});

test('fw_valve_guard: yerel plan donanim okumasina gore iki yonde duzeltir; dayatilmayan/ek modul bitine dokunmaz; panjur cifti kurulmaz', () => {
  const as = bit(1) | bit(2);
  const lv = bit(1);
  assert.deepEqual(planLocalGuard(as, lv, 0x00, 0), { clearBits: 0, setBits: 0x01 });
  assert.deepEqual(planLocalGuard(as, lv, 0x03, 0), { clearBits: 0x02, setBits: 0 });
  assert.deepEqual(planLocalGuard(as, lv, 0x01, 0), { clearBits: 0, setBits: 0 });
  assert.deepEqual(planLocalGuard(bit(5), bit(5), 0xEF, 0), { clearBits: 0, setBits: 0x10 });
  assert.deepEqual(planLocalGuard(0n, 0n, 0xFF, 0), { clearBits: 0, setBits: 0 });
  assert.deepEqual(planLocalGuard(bit(9) | bit(40), bit(9) | bit(40), 0x00, 0), { clearBits: 0, setBits: 0 });
  assert.equal(planLocalGuard(bit(1) | bit(3), bit(1) | bit(3), 0x00, 0x01).setBits, 0x04);
  assert.equal(planLocalGuard(bit(1), 0n, 0x01, 0x01).clearBits, 0x01);
});

test('fw_valve_guard: ek modul yazimi yalniz loop acliginda (1000 ms) ve en cok 1 sn de bir; millis tasmasi', () => {
  const pc = new ExtGuardPacer();
  let t = 1000;
  pc.beat(1, t);
  for (let i = 0; i < 40; i++) { t += 50; pc.beat(2 + i, t); assert.equal(pc.due(t), false); }
  const lastBeat = 41;
  t += 999; pc.beat(lastBeat, t); assert.equal(pc.due(t), false);
  t += 1; pc.beat(lastBeat, t); assert.equal(pc.due(t), true);
  pc.wrote(t);
  t += 500; pc.beat(lastBeat, t); assert.equal(pc.due(t), false);
  t += 500; pc.beat(lastBeat, t); assert.equal(pc.due(t), true);
  pc.wrote(t);
  t += 10; pc.beat(lastBeat + 1, t); assert.equal(pc.due(t), false);
  t += 2000; pc.beat(lastBeat + 1, t); assert.equal(pc.due(t), true);

  const p2 = new ExtGuardPacer();
  t = 0xFFFFFE00;
  p2.beat(7, t);
  t = (t + 999) >>> 0; p2.beat(7, t); assert.equal(p2.due(t), false);
  t = (t + 1) >>> 0; p2.beat(7, t); assert.equal(p2.due(t), true);
  p2.wrote(t);
  t = (t + 999) >>> 0; assert.equal(p2.due(t), false);
  t = (t + 1) >>> 0; assert.equal(p2.due(t), true);
});

test('fw_valve_guard: ek modul bitleri ac/kapat olarak ayrilir', () => {
  assert.deepEqual(extGuardBits(bit(1) | bit(9) | bit(10) | bit(40), bit(9) | bit(1)), { on: 0x00000001, off: 0x80000002 });
});
