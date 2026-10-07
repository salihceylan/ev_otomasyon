// Firmware SafetyCore (src/safety/SafetyFsm.h) JS portunun UYUMLULUK testi: firmware'in kendi Unity testlerinin
// (ev_otomasyon_servis_yazilimi/waveshare_s3_demo/test/test_safety_fsm/test_main.cpp) BIREBIR portu.
import test from 'node:test';
import assert from 'node:assert/strict';
import { SafetyCore, ZoneSt, Rej, Origin } from '../sim/fw/safety_fsm.js';
import { SensorHub, SensorKind, SensorSrc, defaultFlags, defaultConfirmMs, makeSensorConfig, HZ_WATER, HZ_GAS } from '../sim/fw/sensor_hub.js';
import { actuatorIdentityMap, remapActPos } from '../sim/fw/safety_cfg_edit.js';
import { ActuatorCore, ActKind, CloseMode, Medium, AF_FAN_EXPROOF, RawDecision, makeActuatorConfig, bootLevelMask } from '../sim/fw/actuator_map.js';
import { EventOutbox, EvType, VIA_CLI } from '../sim/fw/event_outbox.js';
import { defaultSafetyConfig, latchClear, latchSeal, latchSetMasks, latchValid, latchAssert64, latchLevel64, SafeReason } from '../sim/fw/safety_config.js';

const u32 = (x) => x >>> 0;

class FakeSource {
  constructor() { this.level = new Array(41).fill(false); this.okv = new Array(41).fill(true); }
  sample(c) { return c.index <= 40 ? { level: this.level[c.index], ok: this.okv[c.index] } : { level: false, ok: false }; }
}
const sensor = (di, kind, zone, nc = 0) => makeSensorConfig({ src: SensorSrc.DI, index: di, kind, zone, active_open: nc, flags: defaultFlags(kind), confirm_ms: defaultConfirmMs(kind) });
const valve = (relay, medium, zones = 0x01, mode = CloseMode.DEENERGIZE_TO_CLOSE) => makeActuatorConfig({ relay, kind: ActKind.VALVE, close_mode: mode, medium, zone_mask: zones, fb_closed_active: 1, fb_timeout_s: 60 });
const sw = (relay, kind, zones = 0x01, lim = 180) => makeActuatorConfig({ relay, kind, zone_mask: zones, run_limit_s: lim });

class Bench {
  constructor() {
    this.cfg = defaultSafetyConfig();
    this.di = new FakeSource();
    this.br = new FakeSource();
    this.t = 1000;
    this.latch = latchClear();
    this.haveLatch = false;
    this.posOpen = 0;
    this.posKnown = 0;
    this.mode = SafeReason.NONE;
  }
  setSens(list) { this.cfg.sens = list; this.cfg.nSens = list.length; }
  setAct(list) { this.cfg.act = list; this.cfg.nAct = list.length; }
  start(t0 = 1000) {
    this.t = u32(t0);
    this.hub = new SensorHub();
    this.act = new ActuatorCore();
    this.out = new EventOutbox();
    this.core = new SafetyCore();
    this.out.begin(0x9f3a11c0);
    this.act.configure(this.cfg.act, this.cfg.nAct, this.posOpen, this.posKnown, this.t);
    this.hub.configure(this.cfg.sens, this.cfg.nSens, this.t);
    this.core.begin(this.cfg, this.hub, this.act, this.out, this.haveLatch ? this.latch : null, this.mode, this.t);
    this.step(0);
    return this;
  }
  step(ms = 10) { this.t = u32(this.t + ms); this.core.tick(this.t, 0, this.di, this.br); }
  run(ms) { for (let d = 0; d < ms; d += 10) this.step(10); }
  relay(r) { return ((this.core.outputMasks().level >> BigInt(r - 1)) & 1n) === 1n; }
  asserted(r) { return ((this.core.outputMasks().assert >> BigInt(r - 1)) & 1n) === 1n; }
  powerCycle() {
    this.latch = this.core.buildLatch();
    this.haveLatch = true;
    this.posOpen = this.act.posOpenBits();
    this.posKnown = this.act.posKnownBits();
    this.start(this.t + 5000);
  }
  /** Calisirken yama (SafetyManager.applyConfigOnLoop esdegeri): cfg cagiranca degistirildi, eski kopya verilir. */
  reconfigure(oldCfg, curLevels = 0n) {
    const map = actuatorIdentityMap(oldCfg, this.cfg);
    const pos = remapActPos(oldCfg, this.act.posOpenBits(), this.act.posKnownBits(), this.cfg, curLevels);
    this.hub.configure(this.cfg.sens, this.cfg.nSens, this.t);
    this.act.reconfigure(this.cfg.act, this.cfg.nAct, pos.open, pos.known, map, this.t);
    this.core.reconfigured(VIA_CLI, this.t, map);
  }
  lastEventOf(type) {
    let best = -1;
    for (let i = 0; i < EventOutbox.CAP; i++) if (this.out.at(i) && this.out.at(i).type === type) best = i;
    return best;
  }
}
const waterSetup = (b) => { b.setSens([sensor(3, SensorKind.WATER, 1)]); b.setAct([valve(5, Medium.WATER), sw(6, ActKind.SIREN)]); };
const water = () => { const b = new Bench(); waterSetup(b); return b; };

test('fw_safety_fsm: yapilandirilmamis cekirdek bostadir', () => {
  const b = new Bench().start();
  b.run(5000);
  assert.deepEqual(b.core.outputMasks(), { assert: 0n, level: 0n });
  assert.equal(b.core.buzzer(), false);
  assert.equal(b.core.active(), false);
  assert.equal(b.out.count(), 0);
});

test('fw_safety_fsm: eylemcisiz bolgede TEST takili kalmaz (cekirdek TEST surerken etkin)', () => {
  const b = new Bench().start();
  assert.equal(b.core.test(1, b.t), Rej.OK);
  assert.equal(b.core.active(), true);
  b.run(5100);
  assert.equal(b.core.zoneState(1), ZoneSt.NORMAL);
  assert.equal(b.core.active(), false);
});

test('fw_safety_fsm: kisa islak sinyal alarm uretmez; damla alarma ulasir', () => {
  let b = water().start();
  b.run(200);
  assert.equal(b.relay(5), true);
  b.di.level[3] = true; b.run(500); b.di.level[3] = false; b.run(5000);
  assert.equal(b.core.zoneState(1), ZoneSt.NORMAL);
  assert.equal(b.relay(5), true);
  b = water().start();
  for (let k = 0; k < 8; k++) { b.di.level[3] = true; b.run(300); b.di.level[3] = false; b.run(200); }
  assert.equal(b.core.zoneState(1), ZoneSt.LATCHED);
});

test('fw_safety_fsm: onayli islak kilitler, vanayi kapatir, siren calar; kilit kaydi maskeleri', () => {
  const b = water().start();
  b.di.level[3] = true;
  b.run(1100);
  assert.equal(b.core.zoneState(1), ZoneSt.LATCHED);
  assert.equal(b.relay(5), false);
  assert.equal(b.asserted(5), true);
  assert.equal(b.relay(6), true);
  assert.equal(b.core.buzzer(), true);
  const s = b.lastEventOf(EvType.ALARM_RAISED);
  assert.ok(s >= 0);
  assert.equal(b.core.zone(1).aid, b.out.eidOf(s));
  assert.equal(b.out.at(s).actClose, 1);
  assert.equal(b.out.at(s).actOn, 2);
  assert.equal(b.out.at(s).nsrcs, 1);
  assert.equal(b.out.at(s).srcs[0], 3);
  assert.equal(b.core.takeLatchDirty(), true);
  const r = b.core.buildLatch();
  assert.equal(latchValid(r), true);
  assert.equal(r.z[0].st, 1);
  assert.equal(latchAssert64(r), 1n << 4n);
  assert.equal(latchLevel64(r), 0n);
  assert.equal(b.act.posKnownBits(), 1);
  assert.equal(b.act.posOpenBits(), 0);
});

test('fw_safety_fsm: islakken ACK yalniz susturur; ACK + kuruluk kilidi kaldirir, vana kapali kalir; kesinti sonrasi da kapali', () => {
  let b = water().start();
  b.di.level[3] = true;
  b.run(1100);
  assert.equal(b.core.ack(1, b.core.zone(1).aid, Origin.REMOTE, false, b.t), Rej.OK);
  b.step();
  assert.equal(b.core.zone(1).silenced, true);
  assert.equal(b.relay(6), false);
  assert.equal(b.core.buzzer(), false);
  assert.equal(b.relay(5), false);
  assert.ok(b.lastEventOf(EvType.ALARM_SILENCED) >= 0);
  assert.ok(b.core.zone(1).aid.length > 0);
  assert.equal(b.out.at(b.lastEventOf(EvType.ALARM_SILENCED)).aid, b.core.zone(1).aid);
  assert.equal(b.out.at(b.lastEventOf(EvType.ALARM_RAISED)).aid, '');
  b.run(30000);
  assert.equal(b.core.zoneState(1), ZoneSt.LATCHED);
  b = water().start();
  b.di.level[3] = true;
  b.run(1100);
  const raisedAid = b.core.zone(1).aid;
  b.core.ack(1, null, Origin.LOCAL_DI, false, b.t);
  b.di.level[3] = false;
  b.run(9000);
  assert.equal(b.core.zoneState(1), ZoneSt.LATCHED);
  b.run(5000);
  assert.equal(b.core.zoneState(1), ZoneSt.NORMAL);
  assert.equal(b.relay(5), false);
  assert.equal(b.relay(6), false);
  assert.ok(b.lastEventOf(EvType.ALARM_CLEARED) >= 0);
  assert.equal(b.out.at(b.lastEventOf(EvType.ALARM_CLEARED)).aid, raisedAid);
  b.powerCycle();
  b.run(100);
  assert.equal(b.relay(5), false);
  assert.equal(bootLevelMask(b.cfg.act, b.cfg.nAct, 0, b.posOpen, b.posKnown) & (1n << 4n), 0n);
  assert.equal(b.core.actuatorSet(0, false, Origin.REMOTE, b.t), Rej.OK);
  b.step();
  assert.equal(b.relay(5), true);
});

test('fw_safety_fsm: once kuru sonra ACK hemen kaldirir; ok=false kaldirmayi ve acmayi engeller', () => {
  let b = water().start();
  b.di.level[3] = true; b.run(1100); b.di.level[3] = false; b.run(20000);
  assert.equal(b.core.zoneState(1), ZoneSt.LATCHED);
  assert.equal(b.relay(6), true);
  b.core.ack(1, null, Origin.REMOTE, false, b.t);
  b.step();
  assert.equal(b.core.zoneState(1), ZoneSt.NORMAL);
  b = water().start();
  b.di.level[3] = true; b.run(1100);
  b.core.ack(1, null, Origin.REMOTE, false, b.t);
  b.di.level[3] = false; b.di.okv[3] = false; b.run(30000);
  assert.equal(b.core.zoneState(1), ZoneSt.LATCHED);
  assert.equal(b.core.actuatorSet(0, false, Origin.REMOTE, b.t), Rej.ZONE_LATCHED);
  assert.ok(b.lastEventOf(EvType.SENSOR_FAULT) >= 0);
  b.di.okv[3] = true; b.run(11000);
  assert.equal(b.core.zoneState(1), ZoneSt.NORMAL);
  assert.ok(b.lastEventOf(EvType.SENSOR_FAULT_CLEARED) >= 0);
  b.di.okv[3] = false; b.run(100);
  assert.equal(b.core.actuatorSet(0, false, Origin.REMOTE, b.t), Rej.ZONE_LATCHED);
});

test('fw_safety_fsm: tur -> akiskan eslemesi (duman vana kapatmaz, fan kapatilir; su yalniz su vanasi)', () => {
  const b = new Bench();
  b.setSens([sensor(3, SensorKind.WATER, 1), sensor(4, SensorKind.SMOKE, 1, 1)]);
  b.setAct([valve(5, Medium.WATER), valve(6, Medium.GAS), sw(7, ActKind.SIREN), sw(8, ActKind.FAN)]);
  b.di.level[4] = true;
  b.start();
  b.run(200);
  assert.equal(b.core.actuatorSet(3, false, Origin.REMOTE, b.t), Rej.OK);
  b.step();
  assert.equal(b.relay(8), true);
  b.di.level[4] = false;
  b.run(500);
  assert.equal(b.core.zoneState(1), ZoneSt.LATCHED);
  assert.equal(b.relay(5), true);
  assert.equal(b.act.closedCmd(1), true);
  assert.equal(b.relay(6), false);
  assert.equal(b.relay(7), true);
  assert.equal(b.relay(8), false);
  assert.equal(b.core.actuatorSet(3, false, Origin.REMOTE, b.t), Rej.ZONE_LATCHED);
  const w = new Bench();
  w.setSens(b.cfg.sens);
  w.setAct(b.cfg.act);
  w.posOpen = 3; w.posKnown = 3;
  w.di.level[4] = true;
  w.start();
  w.di.level[3] = true;
  w.run(1100);
  assert.equal(w.relay(5), false);
  assert.equal(w.out.at(w.lastEventOf(EvType.ALARM_RAISED)).actClose, 1);
});

test('fw_safety_fsm: gaz kurallari (yerinde acma, test sonrasi kapali, ATEX fan); kablo kopmasi gaz vanasini kapatir', () => {
  const b = new Bench();
  b.setSens([sensor(3, SensorKind.GAS, 1, 1), sensor(4, SensorKind.GAS_RESET, 1)]);
  b.setAct([valve(5, Medium.GAS, 0x01, CloseMode.ENERGIZE_TO_CLOSE), sw(6, ActKind.FAN), { ...sw(7, ActKind.FAN), aflags: AF_FAN_EXPROOF }]);
  b.di.level[3] = true;
  b.posOpen = 1; b.posKnown = 1;
  b.start();
  b.run(100);
  assert.equal(b.relay(5), true);
  assert.equal(b.core.actuatorSet(0, false, Origin.REMOTE, b.t), Rej.GAS_LOCAL_ONLY);
  b.di.level[4] = true; b.run(100);
  assert.equal(b.relay(5), false);
  b.di.level[4] = false; b.run(100);
  assert.equal(b.core.test(1, b.t), Rej.OK);
  b.run(6000);
  assert.equal(b.core.zoneState(1), ZoneSt.NORMAL);
  assert.equal(b.relay(5), true);
  assert.equal(b.act.posOpenBits(), 0);
  b.di.level[3] = false;
  b.run(400);
  assert.equal(b.core.zoneState(1), ZoneSt.LATCHED);
  assert.equal(b.relay(6), false);
  assert.equal(b.relay(7), true);
  assert.equal(b.core.actuatorSet(1, false, Origin.REMOTE, b.t), Rej.ZONE_LATCHED);
  const g = new Bench();
  g.setSens([sensor(3, SensorKind.GAS, 1, 1)]);
  g.setAct([valve(5, Medium.GAS)]);
  g.di.level[3] = true;
  g.start();
  g.run(100);
  g.di.okv[3] = false;
  g.run(50);
  assert.equal(g.core.zoneState(1), ZoneSt.LATCHED);
});

test('fw_safety_fsm: bayat aid ile ACK reddedilir; politika kapali yeni alarmi engeller, kilidi kaldirmaz', () => {
  let b = water().start();
  b.di.level[3] = true; b.run(1100);
  assert.equal(b.core.ack(1, '9f3a11c0-99', Origin.REMOTE, false, b.t), Rej.STALE_ACK);
  b.step();
  assert.equal(b.core.zone(1).silenced, false);
  assert.equal(b.relay(6), true);
  assert.equal(b.core.ack(2, 'x', Origin.REMOTE, false, b.t), Rej.OK);
  b = water();
  b.setSens([sensor(3, SensorKind.WATER, 1), sensor(4, SensorKind.WATER, 2)]);
  b.start();
  b.di.level[3] = true; b.run(1100);
  b.core.setPolicy(false, VIA_CLI, b.t);
  assert.ok(b.lastEventOf(EvType.POLICY_CHANGED) >= 0);
  b.run(100);
  assert.equal(b.core.zoneState(1), ZoneSt.LATCHED);
  b.di.level[4] = true; b.run(2000);
  assert.equal(b.core.zoneState(2), ZoneSt.NORMAL);
  assert.equal(b.relay(5), false);
});

test('fw_safety_fsm: geri bildirim zaman asimi FAULT; siren yeniden; kapaninca LATCHED', () => {
  const b = water();
  b.cfg.act[0].fb_di = 7;
  b.cfg.act[0].fb_timeout_s = 5;
  b.posOpen = 1; b.posKnown = 1;
  b.start();
  b.di.level[7] = false;
  b.di.level[3] = true;
  b.run(1100);
  b.core.ack(1, null, Origin.REMOTE, false, b.t);
  b.run(100);
  assert.equal(b.relay(6), false);
  b.run(5000);
  assert.equal(b.core.zoneState(1), ZoneSt.FAULT);
  assert.equal(b.relay(6), true);
  assert.ok(b.lastEventOf(EvType.VALVE_FAULT) >= 0);
  assert.equal(b.relay(5), false);
  b.di.level[7] = true;
  b.run(100);
  assert.equal(b.core.zoneState(1), ZoneSt.LATCHED);
  assert.ok(b.lastEventOf(EvType.VALVE_FAULT_CLEARED) >= 0);
});

test('fw_safety_fsm: TEST dongusu (geri bildirimli ve geri bildirimsiz), onceki konuma donus; test sirasinda gercek islak kilitler', () => {
  let b = water();
  b.cfg.act[0].fb_di = 7;
  b.cfg.act[0].fb_timeout_s = 10;
  b.posOpen = 1; b.posKnown = 1;
  b.start();
  b.run(100);
  assert.equal(b.relay(5), true);
  assert.equal(b.core.test(1, b.t), Rej.OK);
  b.step();
  assert.equal(b.core.zoneState(1), ZoneSt.TEST);
  assert.equal(b.relay(5), false);
  assert.equal(b.relay(6), true);
  b.run(2000);
  b.di.level[7] = true;
  b.run(100);
  assert.equal(b.core.zoneState(1), ZoneSt.NORMAL);
  assert.equal(b.relay(5), true);
  const s = b.lastEventOf(EvType.TEST_RESULT);
  assert.ok(s >= 0);
  assert.equal(b.out.at(s).flag, 1);
  assert.equal(b.out.at(s).sub, 1);
  assert.ok(b.out.at(s).val >= 2000 && b.out.at(s).val < 2200);
  b.di.level[7] = false;
  b.run(3000);
  assert.equal(b.relay(6), false);
  assert.equal(b.core.test(5, b.t), Rej.BAD_STATE);
  b = water();
  b.posOpen = 1; b.posKnown = 1;
  b.start();
  b.core.test(1, b.t);
  b.run(4900);
  assert.equal(b.core.zoneState(1), ZoneSt.TEST);
  b.run(200);
  assert.equal(b.core.zoneState(1), ZoneSt.NORMAL);
  assert.equal(b.relay(5), true);
  b = water();
  b.posOpen = 1; b.posKnown = 1;
  b.start();
  b.core.test(1, b.t);
  b.di.level[3] = true;
  b.run(1200);
  assert.equal(b.core.zoneState(1), ZoneSt.LATCHED);
  b.run(10000);
  assert.equal(b.relay(5), false);
  assert.equal(b.core.test(1, b.t), Rej.ZONE_LATCHED);
});

test('fw_safety_fsm: cok bolgeli vananin acma izni; millis tasmasi', () => {
  let b = new Bench();
  b.setSens([sensor(3, SensorKind.WATER, 1), sensor(4, SensorKind.WATER, 2)]);
  b.setAct([valve(5, Medium.WATER, 0x03)]);
  b.start();
  b.di.level[4] = true; b.run(1100);
  assert.equal(b.relay(5), false);
  b.di.level[4] = false;
  b.core.ack(2, null, Origin.REMOTE, false, b.t);
  b.run(5000);
  assert.equal(b.core.actuatorSet(0, false, Origin.REMOTE, b.t), Rej.ZONE_LATCHED);
  b.run(10000);
  assert.equal(b.core.zoneState(2), ZoneSt.NORMAL);
  assert.equal(b.core.actuatorSet(0, false, Origin.REMOTE, b.t), Rej.OK);
  assert.equal(b.core.actuatorSet(5, false, Origin.REMOTE, b.t), Rej.UNKNOWN_ACTUATOR);
  b = water().start(0xFFFFF000);
  b.di.level[3] = true; b.run(1100);
  assert.equal(b.core.zoneState(1), ZoneSt.LATCHED);
  b.core.ack(1, null, Origin.REMOTE, false, b.t);
  b.di.level[3] = false; b.run(15000);
  assert.equal(b.core.zoneState(1), ZoneSt.NORMAL);
});

test('fw_safety_fsm: kilit kesintiden ayni aid ile sag cikar', () => {
  const b = water();
  b.cfg.act[0].close_mode = CloseMode.ENERGIZE_TO_CLOSE;
  b.start();
  b.di.level[3] = true; b.run(1100);
  const aid = b.core.zone(1).aid;
  b.powerCycle();
  assert.equal(b.core.zoneState(1), ZoneSt.LATCHED);
  assert.equal(b.core.zone(1).aid, aid);
  assert.equal(b.relay(5), true);
  assert.equal(b.relay(6), true);
  assert.equal(b.out.countOf(EvType.ALARM_RAISED), 0);
});

test('fw_safety_fsm: guvenli kip kilit maskesini uygular, acmayi reddeder; yalniz yerel cikis; crash_loop 30 dk', () => {
  let b = new Bench();
  b.haveLatch = true;
  b.latch = latchClear();
  b.latch.z[0].st = 1;
  b.latch.z[0].aid = '11111111-4';
  latchSetMasks(b.latch, 1n << 4n, 1n << 4n);
  latchSeal(b.latch);
  b.mode = SafeReason.LATCH_ORPHAN;
  b.start();
  b.run(100);
  assert.equal(b.core.safeMode(), true);
  assert.equal(b.asserted(5), true);
  assert.equal(b.relay(5), true);
  assert.ok(b.lastEventOf(EvType.SAFE_MODE) >= 0);
  assert.equal(b.core.ack(1, null, Origin.LOCAL_DI, true, b.t), Rej.SAFE_MODE);
  b.core.setConfigUsable(true);
  assert.equal(b.core.ack(1, null, Origin.REMOTE, true, b.t), Rej.SAFE_MODE);
  assert.equal(b.core.ack(1, null, Origin.LOCAL_DI, true, b.t), Rej.OK);
  b.step();
  assert.equal(b.core.safeMode(), false);
  b = water();
  b.mode = SafeReason.CFG_CORRUPT;
  b.posOpen = 0; b.posKnown = 1;
  b.start();
  assert.equal(b.core.actuatorSet(0, false, Origin.REMOTE, b.t), Rej.SAFE_MODE);
  assert.equal(b.core.actuatorSet(0, true, Origin.REMOTE, b.t), Rej.OK);
  assert.equal(b.core.test(1, b.t), Rej.SAFE_MODE);
  b = water();
  b.mode = SafeReason.CRASH_LOOP;
  b.start();
  assert.equal(b.core.safeMode(), true);
  for (let k = 0; k < 1799; k++) b.step(1000);
  assert.equal(b.core.safeMode(), true);
  b.step(1000);
  b.step(10);
  assert.equal(b.core.safeMode(), false);
});

test('fw_safety_fsm: yerel kumanda rolleri; ALARM_ACK 5 sn basili tutma guvenli kipten cikarir', () => {
  let b = water();
  b.setSens([sensor(3, SensorKind.WATER, 1), sensor(4, SensorKind.ALARM_ACK, 0), sensor(5, SensorKind.VALVE_CLOSE, 1)]);
  b.posOpen = 1; b.posKnown = 1;
  b.start();
  b.run(100);
  assert.equal(b.relay(5), true);
  b.di.level[5] = true; b.run(50);
  assert.equal(b.relay(5), false);
  b.di.level[5] = false;
  b.di.level[3] = true; b.run(1100);
  b.di.level[4] = true; b.run(50);
  assert.equal(b.core.zone(1).silenced, true);
  b.di.level[4] = false; b.di.level[3] = false; b.run(15000);
  assert.equal(b.core.zoneState(1), ZoneSt.NORMAL);
  b = water();
  b.setSens([sensor(3, SensorKind.WATER, 1), sensor(4, SensorKind.ALARM_ACK, 0)]);
  b.haveLatch = true;
  b.latch = latchClear();
  b.latch.z[0].st = 1;
  latchSetMasks(b.latch, 1n << 4n, 0n);
  latchSeal(b.latch);
  b.mode = SafeReason.CFG_CORRUPT;
  b.start();
  b.core.setConfigUsable(true);
  b.di.level[4] = true;
  b.run(4000);
  assert.equal(b.core.safeMode(), true);
  b.run(1100);
  assert.equal(b.core.safeMode(), false);
  assert.equal(b.relay(5), false);
});

test('fw_safety_fsm: alarmda siren sure siniri; iki roleli vana alarmda kapatir, AC rolesi hic enerjilenmez', () => {
  let b = water();
  b.cfg.act[1].run_limit_s = 10;
  b.start();
  b.di.level[3] = true; b.run(1100);
  assert.equal(b.relay(6), true);
  b.run(10100);
  assert.equal(b.relay(6), false);
  assert.equal(b.core.zoneState(1), ZoneSt.LATCHED);
  assert.equal(b.core.buzzer(), true);
  b = new Bench();
  b.setSens([sensor(3, SensorKind.WATER, 1)]);
  b.setAct([{ ...valve(5, Medium.WATER, 0x01, CloseMode.PULSE_TWO_RELAY), relay2: 6, run_limit_s: 15 }]);
  b.start();
  b.di.level[3] = true; b.run(1100);
  assert.equal(b.relay(5), true);
  assert.equal(b.relay(6), false);
  for (let k = 0; k < 2000; k++) { b.step(); assert.ok(!(b.relay(5) && b.relay(6))); assert.equal(b.relay(6), false); }
  assert.equal(b.relay(5), false);
  const r = b.core.buildLatch();
  assert.equal(latchAssert64(r), 1n << 5n);
  assert.equal(latchLevel64(r), 0n);
});

test('fw_safety_fsm: ham guvenli yon komutu kapatma olarak bildirilir', () => {
  const b = water();
  b.posOpen = 1; b.posKnown = 1;
  b.start();
  b.run(50);
  assert.equal(b.core.rawRelay(5, false, Origin.LOCAL_DI, b.t), RawDecision.SAFE);
  b.step();
  assert.equal(b.relay(5), false);
  assert.equal(b.core.rawRelay(5, true, Origin.REMOTE, b.t), RawDecision.REJECT);
  assert.equal(b.relay(5), false);
  assert.equal(b.core.rawRelay(6, false, Origin.REMOTE, b.t), RawDecision.SAFE);
  assert.equal(b.core.rawRelay(7, true, Origin.REMOTE, b.t), RawDecision.NOT_ACTUATOR);
  assert.ok(b.lastEventOf(EvType.ACTUATOR_CHANGED) >= 0);
});

// ---- Inceleme turu (entegrasyon) duzeltmeleri (Unity: test_safety_fsm, ayni adlar) ----

test('fw_safety_fsm: kilitli bolgede yeni tehlike turu yeni alarm olayi uretir (E2E-2)', () => {
  const b = new Bench();
  b.setSens([sensor(3, SensorKind.WATER, 1), sensor(4, SensorKind.GAS, 1)]);
  b.setAct([valve(5, Medium.WATER), valve(7, Medium.GAS), sw(6, ActKind.SIREN)]);
  b.posOpen = 0x0003; b.posKnown = 0x0003;
  b.start();
  b.di.level[3] = true; b.run(3100);
  assert.equal(b.core.zoneState(1), ZoneSt.LATCHED);
  const aid1 = b.core.zone(1).aid;
  assert.equal(b.core.ack(1, aid1, Origin.REMOTE, false, b.t), Rej.OK);
  b.step();
  assert.equal(b.core.zone(1).silenced, true);
  const raised0 = b.out.countOf(EvType.ALARM_RAISED);
  b.di.level[4] = true; b.run(1500);
  assert.equal(b.out.countOf(EvType.ALARM_RAISED), raised0 + 1);
  const s = b.lastEventOf(EvType.ALARM_RAISED);
  assert.equal(b.out.eidOf(s), b.core.zone(1).aid);
  assert.notEqual(aid1, b.core.zone(1).aid);
  assert.equal(b.out.at(s).kinds, HZ_WATER | HZ_GAS);
  assert.equal(b.out.at(s).actClose, 0x0002);
  assert.ok(b.out.at(s).nsrcs >= 1);
  assert.equal(b.core.zone(1).silenced, false);
  assert.equal(b.relay(6), true);
  assert.equal(b.relay(7), false);
  assert.equal(b.core.ack(1, aid1, Origin.REMOTE, false, b.t), Rej.STALE_ACK);
});

test('fw_safety_fsm: FAULT yeniden baslatmada korunur, geri bildirim kapali gorulmeden kalkmaz (EM-2)', () => {
  const b = water();
  b.cfg.act[0].fb_di = 7; b.cfg.act[0].fb_timeout_s = 5;
  b.posOpen = 1; b.posKnown = 1;
  b.start();
  b.di.level[3] = true; b.run(1100); b.run(5000);
  assert.equal(b.core.zoneState(1), ZoneSt.FAULT);
  b.di.level[3] = false;
  b.core.ack(1, null, Origin.REMOTE, false, b.t);
  b.powerCycle();
  assert.equal(b.core.zoneState(1), ZoneSt.FAULT);
  b.run(15000);
  assert.notEqual(b.core.zoneState(1), ZoneSt.NORMAL);
  assert.equal(b.out.countOf(EvType.VALVE_FAULT_CLEARED), 0);
  b.di.level[7] = true; b.run(200);
  assert.ok(b.out.countOf(EvType.VALVE_FAULT_CLEARED) >= 1);
  b.run(11000);
  assert.equal(b.core.zoneState(1), ZoneSt.NORMAL);
});

test('fw_safety_fsm: ilgisiz yama FAULT, siren butcesi ve elle acik cikisi korur (EM-2)', () => {
  const b = water();
  b.cfg.act[0].fb_di = 7; b.cfg.act[0].fb_timeout_s = 5;
  b.cfg.act[1].run_limit_s = 20;
  b.setAct([b.cfg.act[0], b.cfg.act[1], sw(8, ActKind.GENERIC, 0x02, 0)]);
  b.posOpen = 1; b.posKnown = 1;
  b.start();
  assert.equal(b.core.actuatorSet(2, false, Origin.REMOTE, b.t), Rej.OK);
  b.di.level[3] = true; b.run(1100); b.run(5000);
  assert.equal(b.core.zoneState(1), ZoneSt.FAULT);
  b.run(10000);
  assert.ok(b.act.sirenRunMs(1) >= 15000);
  const cleared0 = b.out.countOf(EvType.VALVE_FAULT_CLEARED);
  const old = structuredClone(b.cfg);
  b.cfg.zones[0].name = 'Mutfak';
  b.reconfigure(old);
  b.run(15000);
  assert.equal(b.core.zoneState(1), ZoneSt.FAULT);
  assert.equal(b.out.countOf(EvType.VALVE_FAULT_CLEARED), cleared0);
  assert.equal(b.act.fbFault(0), true);
  assert.equal(b.relay(6), false);
  assert.ok(b.act.sirenRunMs(1) >= 20000);
  assert.equal(b.relay(8), true);
});

const pulseWater = () => {
  const b = new Bench();
  b.setSens([sensor(3, SensorKind.WATER, 1)]);
  b.setAct([{ ...valve(5, Medium.WATER, 0x01, CloseMode.PULSE_TWO_RELAY), relay2: 6, run_limit_s: 15 }]);
  return b;
};

test('fw_safety_fsm: iki roleli vana kilitliyken yeniden baslatma KAPAT darbesini yeniler (EM-3)', () => {
  const b = pulseWater();
  b.start();
  b.di.level[3] = true; b.run(1100);
  assert.equal(b.relay(5), true);
  b.run(2000);
  b.powerCycle();
  b.run(20);
  assert.equal(b.relay(5), true);
  assert.equal(b.relay(6), false);
});

test('fw_safety_fsm: kapali gaz darbe vanasi acilista darbelenir (K-4, EM-3)', () => {
  const b = new Bench();
  b.setAct([{ ...valve(5, Medium.GAS, 0x01, CloseMode.PULSE_TWO_RELAY), relay2: 6, run_limit_s: 10 }]);
  b.posOpen = 1; b.posKnown = 1;
  b.start();
  b.run(20);
  assert.equal(b.relay(5), true);
  assert.equal(b.relay(6), false);
});

test('fw_safety_fsm: darbe surerken ilgisiz yama darbeyi kesmez (EM-3)', () => {
  const b = pulseWater();
  b.start();
  b.di.level[3] = true; b.run(1100);
  assert.equal(b.relay(5), true);
  const old = structuredClone(b.cfg);
  b.cfg.zones[1].name = 'Banyo';
  b.reconfigure(old);
  b.run(20);
  assert.equal(b.relay(5), true);
  b.run(15000);
  assert.equal(b.relay(5), false);
});

test('fw_safety_fsm: GAS_RESET ile acilmis gaz vanasi ilgisiz yamada kapanmaz', () => {
  const b = new Bench();
  b.setSens([sensor(3, SensorKind.GAS, 1, 1), sensor(4, SensorKind.GAS_RESET, 1)]);
  b.setAct([valve(5, Medium.GAS, 0x01, CloseMode.ENERGIZE_TO_CLOSE)]);
  b.di.level[3] = true;
  b.start();
  b.run(100);
  b.di.level[4] = true; b.run(100);
  b.di.level[4] = false; b.run(100);
  assert.equal(b.relay(5), false);
  const old = structuredClone(b.cfg);
  b.cfg.zones[0].name = 'Mutfak';
  b.reconfigure(old);
  b.run(100);
  assert.equal(b.relay(5), false);
});

test('fw_safety_fsm: test sonu geri acma kullanici kapatmasina ve acma iznine uyar (EM-4)', () => {
  const b = water();
  b.posOpen = 1; b.posKnown = 1;
  b.start();
  b.run(100);
  assert.equal(b.relay(5), true);
  assert.equal(b.core.test(1, b.t), Rej.OK);
  b.run(1000);
  assert.equal(b.core.actuatorSet(0, true, Origin.REMOTE, b.t), Rej.OK);
  b.run(5000);
  assert.equal(b.core.zoneState(1), ZoneSt.NORMAL);
  assert.equal(b.relay(5), false);
  assert.equal(b.core.actuatorSet(0, false, Origin.REMOTE, b.t), Rej.OK);
  b.run(100);
  assert.equal(b.relay(5), true);
  assert.equal(b.core.test(1, b.t), Rej.OK);
  b.run(500);
  b.di.okv[3] = false;
  b.run(5000);
  assert.equal(b.core.zoneState(1), ZoneSt.NORMAL);
  assert.equal(b.relay(5), false);
});

test('fw_safety_fsm: guvenli kipte acilis guvenli maskesi eylemcisiz dayatilir (EM-5)', () => {
  const b = new Bench();
  b.mode = SafeReason.CFG_CORRUPT;
  b.start();
  b.core.imposeBootMask((1n << 4n) | (1n << 6n), 1n << 4n);
  b.run(50);
  assert.equal(b.asserted(5), true);
  assert.equal(b.relay(5), true);
  assert.equal(b.asserted(7), true);
  assert.equal(b.relay(7), false);
  assert.equal(b.core.latchRecordAssert(), 0n);
  const n = new Bench().start();
  n.core.imposeBootMask(1n << 4n, 1n << 4n);
  n.run(50);
  assert.equal(n.asserted(5), false);
});
