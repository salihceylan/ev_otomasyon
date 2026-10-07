// Firmware ActuatorMap/ActuatorCore (src/actuators/*.h) JS portunun UYUMLULUK testi: firmware'in kendi Unity testlerinin
// (ev_otomasyon_servis_yazilimi/waveshare_s3_demo/test/test_actuator_map/test_main.cpp) BIREBIR portu.
import test from 'node:test';
import assert from 'node:assert/strict';
import {
  ActKind, CloseMode, Medium, ValvePos, RawDecision, ActuatorCore, makeActuatorConfig, relayLevelFor, mediumHazard, relayBits,
  bootLevelMask, applyLatchMask, filterSafeBits, rawCommand, bootSafeMasks,
} from '../sim/fw/actuator_map.js';
import { HZ_WATER, HZ_GAS } from '../sim/fw/sensor_hub.js';

const valve = (relay, mode, medium, zones = 0x01, fbDi = 0) => makeActuatorConfig({
  relay, kind: ActKind.VALVE, close_mode: mode, medium, zone_mask: zones, fb_di: fbDi, fb_closed_active: 1, fb_timeout_s: 60,
});
const sw = (relay, kind, zones = 0x01, runLimit = 180) => makeActuatorConfig({ relay, kind, zone_mask: zones, run_limit_s: runLimit });
const pulseValve = (c, o, s = 15) => ({ ...valve(c, CloseMode.PULSE_TWO_RELAY, Medium.WATER), relay2: o, run_limit_s: s });
const core = (a, open = 0, known = 0, now = 0) => { const c = new ActuatorCore(); c.configure(a, a.length, open, known, now); return c; };
const E2C = CloseMode.ENERGIZE_TO_CLOSE;
const D2C = CloseMode.DEENERGIZE_TO_CLOSE;

test('fw_actuator_map: close_mode x mantiksal durum; akiskan tehlike sinifi; iki roleli vananin role bitleri', () => {
  const e = valve(5, E2C, Medium.WATER);
  const d = valve(5, D2C, Medium.WATER);
  assert.equal(relayLevelFor(e, true), true);
  assert.equal(relayLevelFor(e, false), false);
  assert.equal(relayLevelFor(d, true), false);
  assert.equal(relayLevelFor(d, false), true);
  assert.equal(mediumHazard(Medium.WATER), HZ_WATER);
  assert.equal(mediumHazard(Medium.GAS), HZ_GAS);
  assert.equal(mediumHazard(Medium.NONE), 0);
  assert.equal(relayBits(pulseValve(3, 4)), (1n << 2n) | (1n << 3n));
  assert.equal(relayBits(sw(40, ActKind.SIREN)), 1n << 39n);
});

test('fw_actuator_map: acilis maskesi tablosu; kilit maskesi yapilandirmasiz uygulanir; panjur cifti suzgeci', () => {
  const a = [valve(1, E2C, Medium.WATER), valve(2, D2C, Medium.WATER), valve(3, E2C, Medium.GAS), valve(4, D2C, Medium.GAS), sw(5, ActKind.SIREN), pulseValve(6, 7)];
  assert.equal(bootLevelMask(a, 6, 0, 0, 0), (1n << 1n) | (1n << 2n));
  assert.equal(bootLevelMask(a, 6, 0, 0, 0x3F), (1n << 0n) | (1n << 2n));
  assert.equal(bootLevelMask(a, 6, 0, 0x3F, 0x3F), (1n << 1n) | (1n << 2n));
  assert.equal(bootLevelMask(a, 6, 0x01, 0x3F, 0x3F), (1n << 0n) | (1n << 2n));
  assert.equal(bootLevelMask(a, 6, 0x02, 0x3F, 0x3F), (1n << 1n) | (1n << 2n));
  const boot = bootLevelMask(null, 0, 0x01, 0, 0);
  assert.equal(boot, 0n);
  assert.equal(applyLatchMask(boot, (1n << 4n) | (1n << 9n), 1n << 4n), 1n << 4n);
  assert.equal(applyLatchMask((1n << 4n) | (1n << 1n), 1n << 4n, 0n), 1n << 1n);
  assert.equal(filterSafeBits(0xFF, 0x05), 0xCC);
  assert.equal(filterSafeBits(0x03, 0x01), 0x00);
  assert.equal(filterSafeBits(0x10, 0x00), 0x10);
});

test('fw_actuator_map: ham komutun yon kurali', () => {
  const a = [valve(1, E2C, Medium.WATER), valve(2, D2C, Medium.WATER), sw(3, ActKind.SIREN), sw(4, ActKind.FAN), pulseValve(5, 6)];
  assert.deepEqual(rawCommand(a, 5, 1, true), { d: RawDecision.SAFE, act: 0 });
  assert.equal(rawCommand(a, 5, 1, false).d, RawDecision.REJECT);
  assert.equal(rawCommand(a, 5, 2, false).d, RawDecision.SAFE);
  assert.equal(rawCommand(a, 5, 2, true).d, RawDecision.REJECT);
  assert.equal(rawCommand(a, 5, 3, false).d, RawDecision.SAFE);
  assert.equal(rawCommand(a, 5, 3, true).d, RawDecision.REJECT);
  assert.equal(rawCommand(a, 5, 4, true).d, RawDecision.REJECT);
  assert.deepEqual(rawCommand(a, 5, 5, true), { d: RawDecision.SAFE, act: 4 });
  assert.equal(rawCommand(a, 5, 6, true).d, RawDecision.REJECT);
  assert.equal(rawCommand(a, 5, 6, false).d, RawDecision.NOOP);
  assert.equal(rawCommand(a, 5, 5, false).d, RawDecision.REJECT);
  assert.deepEqual(rawCommand(a, 5, 7, true), { d: RawDecision.NOT_ACTUATOR, act: -1 });
  assert.equal(rawCommand(null, 0, 1, true).d, RawDecision.NOT_ACTUATOR);
});

test('fw_actuator_map: cekirdek vana seviyeleri, konum bitleri, kayitli konumun geri yuklenmesi', () => {
  const c = core([valve(5, E2C, Medium.WATER), valve(6, D2C, Medium.WATER)]);
  assert.equal(c.relayMask(), (1n << 4n) | (1n << 5n));
  assert.equal(c.pos(0), ValvePos.UNKNOWN);
  assert.equal(c.levelOf(5), false);
  assert.equal(c.levelOf(6), true);
  assert.equal(c.takePosDirty(), false);
  c.commandValve(0, true, 100);
  c.commandValve(1, true, 100);
  c.tick(100);
  assert.equal(c.levelOf(5), true);
  assert.equal(c.levelOf(6), false);
  assert.equal(c.pos(0), ValvePos.CMD_CLOSED);
  assert.equal(c.posKnownBits(), 0x3);
  assert.equal(c.posOpenBits(), 0);
  assert.equal(c.takePosDirty(), true);
  assert.equal(c.takePosDirty(), false);
  c.commandValve(0, false, 200);
  assert.equal(c.posOpenBits(), 0x1);
  assert.equal(c.pos(0), ValvePos.CMD_OPEN);
  assert.equal(c.levelMask() & (1n << 4n), 0n);
  assert.equal(c.levelMask() & (1n << 5n), 0n);
  assert.equal(c.levelOf(7), false);
  const r = core([valve(5, D2C, Medium.WATER)], 0, 1);
  assert.equal(r.pos(0), ValvePos.CMD_CLOSED);
  assert.equal(r.levelOf(5), false);
  const g = core([valve(5, D2C, Medium.GAS)], 1, 1);
  assert.equal(g.closedCmd(0), true);
  assert.equal(g.levelOf(5), false);
});

test('fw_actuator_map: geri bildirim zaman asimi ve donus', () => {
  const a = { ...valve(5, E2C, Medium.WATER, 0x01, 3), fb_timeout_s: 5 };
  const c = core([a], 1, 1);
  assert.equal(c.fbDiMask(), 1n << 2n);
  c.setFeedback(0, false);
  c.tick(0);
  assert.equal(c.pos(0), ValvePos.OPEN);
  c.commandValve(0, true, 1000);
  c.tick(1000);
  assert.equal(c.pos(0), ValvePos.CLOSING);
  c.tick(5999);
  assert.equal(c.fbFault(0), false);
  c.tick(6000);
  assert.equal(c.fbFault(0), true);
  c.setFeedback(0, true);
  c.tick(7000);
  assert.equal(c.fbFault(0), false);
  assert.equal(c.pos(0), ValvePos.CLOSED);
  assert.equal(c.fbMs(0), 6000);
  c.commandValve(0, false, 8000);
  c.tick(8000);
  assert.equal(c.pos(0), ValvePos.OPENING);
  assert.equal(c.fbFault(0), false);
});

test('fw_actuator_map: siren sure butcesi; fan/generic siniri yok', () => {
  const c = core([sw(7, ActKind.SIREN, 0x01, 10)]);
  c.commandSwitch(0, true, 0);
  for (let t = 0; t <= 9990; t += 10) c.tick(t);
  assert.equal(c.levelOf(7), true);
  for (let t = 10000; t <= 10100; t += 10) c.tick(t);
  assert.equal(c.levelOf(7), false);
  assert.equal(c.on(0), true);
  assert.ok(c.sirenRunMs(0) >= 10000);
  c.resetSirenBudget(0);
  c.tick(10110);
  assert.equal(c.levelOf(7), true);
  c.setSirenRunMs(0, 9999);
  c.tick(10120);
  c.tick(10130);
  assert.equal(c.levelOf(7), false);
  const f = core([sw(3, ActKind.FAN), sw(4, ActKind.GENERIC)]);
  f.commandSwitch(0, true, 0);
  f.commandSwitch(1, true, 0);
  f.tick(100000000);
  assert.equal(f.levelOf(3), true);
  assert.equal(f.levelOf(4), true);
  f.commandSwitch(0, false, 0);
  assert.equal(f.levelOf(3), false);
});

function checkInterlock(c, from, to, st) {
  for (let t = from; t <= to; t += 10) {
    c.tick(t);
    const cl = c.levelOf(3);
    const op = c.levelOf(4);
    assert.ok(!(cl && op), `iki role birlikte enerjili (t=${t})`);
    if (cl || op) {
      if (st.anyOn && st.lastWasClose !== cl) assert.ok(t - st.bothOffSince >= 500, `olu zaman < 500 ms (t=${t})`);
      st.lastWasClose = cl;
      st.anyOn = true;
      st.lastOn = t;
    } else if (st.lastOn + 10 === t) {
      st.bothOffSince = t;
    }
  }
}

test('fw_actuator_map: iki roleli vana interlock ve olu zaman (7.2b-2)', () => {
  const c = core([pulseValve(3, 4, 15)]);
  const st = { lastOn: 0, bothOffSince: 0, lastWasClose: false, anyOn: false };
  assert.equal(c.levelOf(3), false);
  assert.equal(c.levelOf(4), false);
  c.commandValve(0, true, 0);
  c.tick(0);
  assert.equal(c.levelOf(3), true);
  assert.equal(c.pos(0), ValvePos.CLOSING);
  checkInterlock(c, 10, 4990, st);
  c.commandValve(0, false, 5000);
  checkInterlock(c, 5000, 5490, st);
  assert.equal(c.levelOf(3), false);
  assert.equal(c.levelOf(4), false);
  checkInterlock(c, 5500, 20990, st);
  assert.equal(c.levelOf(4), false);
  assert.equal(c.pos(0), ValvePos.CMD_OPEN);
  c.commandValve(0, true, 21000);
  checkInterlock(c, 21000, 37000, st);
  assert.equal(c.pos(0), ValvePos.CMD_CLOSED);
});

test('fw_actuator_map: bosta iken hizli ters yon olu zaman bekler; ayni yon darbeyi uzatmaz; millis tasmasi', () => {
  let c = core([pulseValve(3, 4, 1)]);
  c.commandValve(0, true, 0);
  c.tick(0);
  c.tick(1000);
  assert.equal(c.levelOf(3), false);
  c.commandValve(0, false, 1100);
  c.tick(1100);
  assert.equal(c.levelOf(4), false);
  c.tick(1499);
  assert.equal(c.levelOf(4), false);
  c.tick(1500);
  assert.equal(c.levelOf(4), true);
  c = core([pulseValve(3, 4, 2)]);
  c.commandValve(0, true, 0);
  c.tick(0);
  c.commandValve(0, true, 1500);
  c.tick(2000);
  assert.equal(c.levelOf(3), false);
  const t0 = 0xFFFFF000;
  c = core([pulseValve(3, 4, 15)], 0, 0, t0);
  c.commandValve(0, true, t0);
  c.tick(t0);
  c.tick((t0 + 14999) >>> 0);
  assert.equal(c.levelOf(3), true);
  c.tick((t0 + 15000) >>> 0);
  assert.equal(c.levelOf(3), false);
});

// ---- Inceleme turu (entegrasyon) (Unity: test_actuator_map) ----
test('fw_actuator_map: kalici acilis guvenli maskesi (EM-1/EM-5)', () => {
  const a = [
    valve(1, CloseMode.ENERGIZE_TO_CLOSE, Medium.WATER),
    valve(2, CloseMode.ENERGIZE_TO_CLOSE, Medium.WATER),
    valve(3, CloseMode.ENERGIZE_TO_CLOSE, Medium.GAS),
    valve(4, CloseMode.DEENERGIZE_TO_CLOSE, Medium.WATER),
    pulseValve(5, 6),
    sw(7, ActKind.SIREN),
  ];
  let m = bootSafeMasks(a, 6, 0x0019 | 0x0020);
  assert.equal(m.assert, (1n << 0n) | (1n << 2n) | (1n << 3n) | (1n << 5n));
  assert.equal(m.level, (1n << 0n) | (1n << 2n));
  m = bootSafeMasks(a, 0, 0xFFFF);
  assert.deepEqual(m, { assert: 0n, level: 0n });
});

test('fw_actuator_map: reconfigure eslenen eylemcinin calisma durumunu tasir', () => {
  const a = [
    { ...valve(5, CloseMode.DEENERGIZE_TO_CLOSE, Medium.WATER, 0x01, 7), fb_timeout_s: 5 },
    sw(6, ActKind.SIREN, 0x01, 100),
    valve(8, CloseMode.ENERGIZE_TO_CLOSE, Medium.GAS),
  ];
  const c = new ActuatorCore();
  c.configure(a, 3, 0x0001, 0x0001, 1000);
  c.commandValve(0, true, 1000);
  c.setFeedback(0, false);
  c.commandSwitch(1, true, 1000);
  c.commandValve(2, false, 1000);
  for (let t = 1000; t <= 7000; t += 100) c.tick(t);
  assert.equal(c.fbFault(0), true);
  const run = c.sirenRunMs(1);
  assert.ok(run >= 6000);
  const b = [a[2], a[0], a[1]];
  const map = [2, 0, 1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1];
  c.reconfigure(b, 3, 0x0001, 0x0003, map, 7000);
  assert.equal(c.closedCmd(0), false);
  assert.equal(c.closedCmd(1), true);
  assert.equal(c.fbFault(1), true);
  assert.equal(c.sirenRunMs(2), run);
  c.reconfigure(b, 3, 0, 0, new Array(16).fill(-1), 7000);
  assert.equal(c.closedCmd(0), true);
  assert.equal(c.fbFault(1), false);
  assert.equal(c.sirenRunMs(2), 0);
});
