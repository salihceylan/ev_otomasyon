// Firmware IntrusionCore (src/safety/IntrusionFsm.h) JS portunun UYUMLULUK testi: firmware'in kendi Unity testlerinin
// (ev_otomasyon_servis_yazilimi/waveshare_s3_demo/test/test_intrusion_fsm/test_main.cpp) BIREBIR portu (Faz 2 F2.B, plan 2.5).
import test from 'node:test';
import assert from 'node:assert/strict';
import { SafetyCore, Rej, Origin, rejText } from '../sim/fw/safety_fsm.js';
import {
  SensorHub, SensorKind, SensorSrc, SF_REACT, SF_ENTRY, SF_AWAY_ONLY, SF_FAULT_CLOSE, defaultFlags, defaultConfirmMs, makeSensorConfig, isControlRole,
  sensorIdCode,
} from '../sim/fw/sensor_hub.js';
import { ActuatorCore, ActKind, CloseMode, Medium, makeActuatorConfig } from '../sim/fw/actuator_map.js';
import { EventOutbox, EvType, VIA_CLOUD, VIA_LAN, VIA_CLI } from '../sim/fw/event_outbox.js';
import { defaultSafetyConfig, SafeReason } from '../sim/fw/safety_config.js';
import {
  IntrusionCore, ArmMode, ArmSt, BuzPattern, ARM_REC_VER, ARM_REC_ENTRY, exitDelayS, entryDelayS, makeArmRecord,
} from '../sim/fw/intrusion_fsm.js';

const u32 = (x) => x >>> 0;

class FakeSource {
  constructor() { this.level = new Array(41).fill(false); this.okv = new Array(41).fill(true); }
  sample(c) { return c.index <= 40 ? { level: this.level[c.index], ok: this.okv[c.index] } : { level: false, ok: false }; }
}
const contact = (di, kind, zone, nc = 1) => makeSensorConfig({ src: SensorSrc.DI, index: di, kind, zone, active_open: nc, flags: defaultFlags(kind), confirm_ms: defaultConfirmMs(kind) });
const siren = (relay, zones = 0x01, lim = 30) => makeActuatorConfig({ relay, kind: ActKind.SIREN, zone_mask: zones, run_limit_s: lim });

class Bench {
  constructor() {
    this.cfg = defaultSafetyConfig();
    this.di = new FakeSource();
    this.br = new FakeSource();
    this.t = 1000;
    this.rec = null;
  }
  std3() {
    this.cfg.sens = [contact(1, SensorKind.DOOR, 1), contact(2, SensorKind.WINDOW, 1), contact(3, SensorKind.MOTION, 2, 0)];
    this.cfg.nSens = 3;
    this.cfg.act = [siren(6, 0x02)];
    this.cfg.nAct = 1;
    this.cfg.pol.exit_s = 10;
    this.cfg.pol.entry_s = 5;
    return this;
  }
  start(t0 = 1000) {
    this.t = u32(t0);
    this.hub = new SensorHub();
    this.act = new ActuatorCore();
    this.out = new EventOutbox();
    this.core = new SafetyCore();
    this.intr = new IntrusionCore();
    this.out.begin(0x0badf00d);
    this.act.configure(this.cfg.act, this.cfg.nAct, 0, 0, this.t);
    this.hub.configure(this.cfg.sens, this.cfg.nSens, this.t);
    this.core.begin(this.cfg, this.hub, this.act, this.out, null, SafeReason.NONE, this.t);
    this.intr.begin(this.cfg, this.hub, this.out, this.rec, this.t);
    this.step(0);
    return this;
  }
  step(ms = 10) {
    this.t = u32(this.t + ms);
    this.core.tick(this.t, 0, this.di, this.br);
    this.intr.tick(this.t, 0);
    this.core.setIntrusionSiren(this.intr.sirenReq(), this.intr.takeSirenKick(), this.t);
  }
  run(ms) { for (let d = 0; d < ms; d += 10) this.step(10); }
  relay(r) { return ((this.core.outputMasks().level >> BigInt(r - 1)) & 1n) === 1n; }
  open(d, o) { this.di.level[d] = !o; }
  countOf(t) { return this.out.countOf(t); }
  lastOf(t) { let best = -1; for (let i = 0; i < EventOutbox.CAP; i++) if (this.out.at(i) && this.out.at(i).type === t) best = i; return best; }
  arm(m, via = VIA_CLOUD) {
    const r = this.intr.command(m, via, this.t);
    this.core.setIntrusionSiren(this.intr.sirenReq(), this.intr.takeSirenKick(), this.t);
    return r;
  }
  powerCycle() { this.rec = this.intr.record(); this.start(this.t + 5000); }
}
const closedAll = (b) => { b.di.level[1] = true; b.di.level[2] = true; b.di.level[3] = false; };
const json = (b, slot) => b.out.toJson(slot, 'U', 1);

test('fw_intrusion: bayraklar, varsayilanlar, gecikmeler, ArmRecord, ret metinleri', () => {
  assert.equal(SF_ENTRY, 0x08);
  assert.equal(SF_AWAY_ONLY, 0x10);
  assert.equal(defaultFlags(SensorKind.DOOR), SF_REACT | SF_ENTRY);
  assert.equal(defaultFlags(SensorKind.WINDOW), SF_REACT);
  assert.equal(defaultFlags(SensorKind.MOTION), SF_REACT | SF_AWAY_ONLY);
  assert.equal(defaultFlags(SensorKind.GAS), SF_REACT | SF_FAULT_CLOSE);
  assert.equal(defaultFlags(SensorKind.WATER), SF_REACT);
  assert.equal(isControlRole(SensorKind.ARM_KEY), true);
  assert.equal(SensorKind.ARM_KEY, 19);
  assert.equal(exitDelayS({ exit_s: 0 }), 45);
  assert.equal(entryDelayS({ entry_s: 0 }), 30);
  assert.equal(exitDelayS({ exit_s: 1 }), 1);
  assert.equal(entryDelayS({ entry_s: 255 }), 255);
  assert.equal(rejText(Rej.NOT_READY), 'not_ready');
  assert.equal(rejText(Rej.CFG_STORAGE), 'cfg_storage');
  assert.equal(rejText(Rej.ARMED), 'armed');
});

test('fw_intrusion: yapilandirilmamis pano kip off, arm yok, olay yok', () => {
  const b = new Bench().start();
  b.run(1000);
  assert.equal(b.intr.present(), false);
  assert.equal(b.intr.mode(), ArmMode.OFF);
  assert.equal(b.out.count(), 0);
  assert.equal(b.intr.takeDirty(), false);
});

test('fw_intrusion: anlik sensor acikken not_ready; kapaninca kurulur (exit, arm_changed, kayit kirli)', () => {
  const b = new Bench().std3();
  closedAll(b);
  b.open(2, true);
  b.start();
  b.run(200);
  assert.equal(b.intr.present(), true);
  assert.equal(b.arm(ArmMode.HOME), Rej.NOT_READY);
  assert.equal(b.intr.mode(), ArmMode.OFF);
  assert.equal(b.countOf(EvType.ARM_CHANGED), 0);
  b.open(2, false);
  b.run(50);
  assert.equal(b.arm(ArmMode.HOME), Rej.OK);
  assert.equal(b.intr.mode(), ArmMode.HOME);
  assert.equal(b.intr.st(), ArmSt.EXIT);
  assert.equal(b.countOf(EvType.ARM_CHANGED), 1);
  assert.equal(b.intr.takeDirty(), true);
});

test('fw_intrusion: ok=false sensor kurmayi engeller, kurulu kipte alarm uretmez', () => {
  const b = new Bench().std3();
  closedAll(b);
  b.di.okv[2] = false;
  b.start();
  b.run(200);
  assert.equal(b.arm(ArmMode.AWAY), Rej.NOT_READY);
  b.di.okv[2] = true;
  b.run(50);
  assert.equal(b.arm(ArmMode.AWAY), Rej.OK);
  b.run(10100);
  assert.equal(b.intr.st(), ArmSt.IDLE);
  b.di.okv[2] = false;
  b.run(2000);
  assert.equal(b.intr.st(), ArmSt.IDLE);
  assert.equal(b.countOf(EvType.INTRUSION_ALARM), 0);
});

test('fw_intrusion: kapi acikken kurulur; cikis suresi dolunca kapi hala acik -> giris -> alarm', () => {
  const b = new Bench().std3();
  closedAll(b);
  b.open(1, true);
  b.start();
  b.run(100);
  assert.equal(b.arm(ArmMode.AWAY), Rej.OK);
  assert.equal(b.intr.buzzer(), BuzPattern.EXIT);
  b.run(10020);
  assert.equal(b.intr.st(), ArmSt.ENTRY);
  assert.equal(b.intr.buzzer(), BuzPattern.ENTRY);
  b.run(5020);
  assert.equal(b.intr.st(), ArmSt.ALARM);
  assert.equal(b.countOf(EvType.INTRUSION_ALARM), 1);
});

test('fw_intrusion: cikis gecikmesi -> idle; anlik pencere alarmi, siren ev geneli, olay JSON', () => {
  const b = new Bench().std3();
  closedAll(b);
  b.start();
  b.run(100);
  assert.equal(b.arm(ArmMode.AWAY), Rej.OK);
  b.open(1, true); b.run(3000); b.open(1, false); b.run(3000);
  assert.equal(b.intr.st(), ArmSt.EXIT);
  b.run(4100);
  assert.equal(b.intr.st(), ArmSt.IDLE);
  assert.equal(b.intr.buzzer(), BuzPattern.OFF);
  assert.equal(b.relay(6), false);
  b.open(2, true); b.step(); b.step();
  assert.equal(b.intr.st(), ArmSt.ALARM);
  assert.equal(b.relay(6), true);
  assert.equal(b.intr.buzzer(), BuzPattern.ALARM);
  const s = b.lastOf(EvType.INTRUSION_ALARM);
  const e = b.out.at(s);
  assert.equal(e.zone, 1);
  assert.equal(e.nsrcs, 1);
  assert.equal(e.srcs[0], 2);
  assert.equal(b.intr.aid(), b.out.eidOf(s));
  const j = b.out.toJson(s, 'AHBU-S3-000001', 7);
  assert.ok(j.includes('"type":"intrusion_alarm"'));
  assert.ok(j.includes('"kind":"intrusion"'));
  assert.ok(j.includes('"srcs":["d2"]'));
  assert.ok(!j.includes('"aid"'));
});

test('fw_intrusion: cikis suresinde anlik sensor alarm', () => {
  const b = new Bench().std3();
  closedAll(b);
  b.start();
  b.run(100);
  assert.equal(b.arm(ArmMode.HOME), Rej.OK);
  b.run(1000);
  b.open(2, true); b.step();
  assert.equal(b.intr.st(), ArmSt.ALARM);
});

test('fw_intrusion: giris suresinde cozme alarm uretmez; until_up sabit', () => {
  const b = new Bench().std3();
  closedAll(b);
  b.start();
  b.run(100);
  b.arm(ArmMode.AWAY);
  b.run(10100);
  b.open(1, true); b.step();
  assert.equal(b.intr.st(), ArmSt.ENTRY);
  const until = b.intr.untilUp();
  b.run(2000);
  assert.equal(b.intr.untilUp(), until);
  assert.equal(b.arm(ArmMode.OFF, VIA_LAN), Rej.OK);
  assert.equal(b.intr.mode(), ArmMode.OFF);
  assert.equal(b.intr.st(), ArmSt.IDLE);
  b.run(6000);
  assert.equal(b.countOf(EvType.INTRUSION_ALARM), 0);
  assert.equal(b.countOf(EvType.INTRUSION_CLEARED), 0);
  assert.equal(b.countOf(EvType.ARM_CHANGED), 2);
  assert.equal(b.relay(6), false);
});

test('fw_intrusion: giris suresi dolunca alarm; cozme intrusion_cleared (aid, via) + arm_changed off', () => {
  const b = new Bench().std3();
  closedAll(b);
  b.start();
  b.run(100);
  b.arm(ArmMode.AWAY);
  b.run(10100);
  b.open(1, true); b.step(); b.open(1, false);
  b.run(5100);
  assert.equal(b.intr.st(), ArmSt.ALARM);
  assert.deepEqual(b.intr.srcs(), [1]);
  assert.equal(b.relay(6), true);
  const aid = b.intr.aid();
  assert.equal(b.arm(ArmMode.OFF, VIA_CLOUD), Rej.OK);
  assert.equal(b.relay(6), false);
  const s = b.lastOf(EvType.INTRUSION_CLEARED);
  assert.equal(b.out.at(s).aid, aid);
  const j = json(b, s);
  assert.ok(j.includes('"via":"cloud"'));
  assert.ok(j.includes('"aid":"'));
  assert.ok(json(b, b.lastOf(EvType.ARM_CHANGED)).includes('"mode":"off"'));
  assert.equal(b.intr.aid(), '');
});

test('fw_intrusion: evde kipte hareket etkisiz; disarida kipte anlik ve kurmayi engeller; kip degisimi yeni cikis', () => {
  const b = new Bench().std3();
  closedAll(b);
  b.di.level[3] = true;
  b.start();
  b.run(100);
  assert.equal(b.arm(ArmMode.HOME), Rej.OK);
  b.run(10100);
  b.di.level[3] = false; b.run(100); b.di.level[3] = true; b.run(100);
  assert.equal(b.intr.st(), ArmSt.IDLE);
  assert.equal(b.arm(ArmMode.AWAY), Rej.NOT_READY);
  assert.equal(b.intr.mode(), ArmMode.HOME);
  b.di.level[3] = false; b.run(50);
  assert.equal(b.arm(ArmMode.AWAY), Rej.OK);
  assert.equal(b.intr.st(), ArmSt.EXIT);
  b.run(10100);
  b.di.level[3] = true; b.step();
  assert.equal(b.intr.st(), ArmSt.ALARM);
});

test('fw_intrusion: swinger siniri (ilk tetik + 2 yeniden); baska sensor kendi hakkiyla', () => {
  const b = new Bench().std3();
  b.cfg.act[0].run_limit_s = 10;
  closedAll(b);
  b.start();
  b.run(100);
  b.arm(ArmMode.HOME);
  b.run(10100);
  b.open(2, true); b.step();
  assert.equal(b.relay(6), true);
  let restarts = 0;
  for (let k = 0; k < 5; k++) {
    b.run(10100);
    assert.equal(b.relay(6), false);
    b.open(2, false); b.run(100); b.open(2, true); b.step();
    if (b.relay(6)) restarts++;
  }
  assert.equal(restarts, 2);
  assert.equal(b.countOf(EvType.INTRUSION_ALARM), 1);
  b.open(1, true); b.step();
  assert.equal(b.relay(6), true);
  assert.equal(b.intr.nsrcs(), 2);
});

test('fw_intrusion: millis tasmasi', () => {
  const b = new Bench().std3();
  closedAll(b);
  b.start(0xFFFFF000);
  b.run(100);
  b.arm(ArmMode.AWAY);
  b.run(9000);
  assert.equal(b.intr.st(), ArmSt.EXIT);
  b.run(1200);
  assert.equal(b.intr.st(), ArmSt.IDLE);
  b.open(1, true); b.step();
  b.run(4900);
  assert.equal(b.intr.st(), ArmSt.ENTRY);
  b.run(200);
  assert.equal(b.intr.st(), ArmSt.ALARM);
});

test('fw_intrusion: acilista kip geri yuklenir (cikis gecikmesi yok, arm_changed via boot)', () => {
  const b = new Bench().std3();
  closedAll(b);
  b.start();
  b.run(100);
  b.arm(ArmMode.AWAY);
  b.run(10100);
  b.powerCycle();
  assert.equal(b.intr.mode(), ArmMode.AWAY);
  assert.equal(b.intr.st(), ArmSt.IDLE);
  const j = json(b, b.lastOf(EvType.ARM_CHANGED));
  assert.ok(j.includes('"via":"boot"'));
  assert.ok(j.includes('"mode":"away"'));
  b.open(2, true); b.step();
  assert.equal(b.intr.st(), ArmSt.ALARM);
});

test('fw_intrusion: acilista bellekteki alarm sirensiz; yeni tetik caldirir; cozme cleared', () => {
  const b = new Bench().std3();
  closedAll(b);
  b.start();
  b.run(100);
  b.arm(ArmMode.HOME);
  b.run(10100);
  b.open(2, true); b.step();
  assert.equal(b.relay(6), true);
  const aid = b.intr.aid();
  b.open(2, false);
  b.powerCycle();
  assert.equal(b.intr.st(), ArmSt.ALARM);
  assert.equal(b.intr.aid(), aid);
  b.run(500);
  assert.equal(b.relay(6), false);
  assert.equal(b.countOf(EvType.INTRUSION_ALARM), 0);
  b.open(1, true); b.step();
  assert.equal(b.relay(6), true);
  assert.equal(b.arm(ArmMode.OFF, VIA_CLI), Rej.OK);
  assert.equal(b.countOf(EvType.INTRUSION_CLEARED), 1);
});

test('fw_intrusion: retler (cozuluyken cozme, ayni kip, alarmdayken kurma, sensorsuz, guvenli kip)', () => {
  const b = new Bench().std3();
  closedAll(b);
  b.start();
  b.run(100);
  assert.equal(b.arm(ArmMode.OFF), Rej.OK);
  assert.equal(b.countOf(EvType.ARM_CHANGED), 0);
  b.arm(ArmMode.HOME);
  assert.equal(b.arm(ArmMode.HOME), Rej.OK);
  assert.equal(b.countOf(EvType.ARM_CHANGED), 1);
  b.run(10100);
  b.open(2, true); b.step();
  assert.equal(b.arm(ArmMode.AWAY), Rej.BAD_STATE);
  const c = new Bench().start();
  assert.equal(c.arm(ArmMode.AWAY), Rej.BAD_STATE);
  const d = new Bench().std3();
  closedAll(d);
  d.start();
  d.run(100);
  d.arm(ArmMode.HOME);
  d.intr.setUsable(false);
  assert.equal(d.intr.usable(), false);
  d.open(2, true);
  d.run(15000);
  assert.equal(d.countOf(EvType.INTRUSION_ALARM), 0);
  assert.equal(d.arm(ArmMode.AWAY), Rej.SAFE_MODE);
  assert.equal(d.arm(ArmMode.OFF), Rej.OK);
});

test('fw_intrusion: ARM_KEY kenarlari (ilk okuma kenar degil, hazir degilse hata bip i, via di); vana surmez', () => {
  const b = new Bench().std3();
  closedAll(b);
  b.cfg.sens.push(makeSensorConfig({ src: SensorSrc.DI, index: 7, kind: SensorKind.ARM_KEY, zone: 0 }));
  b.cfg.nSens = 4;
  b.cfg.act.push(makeActuatorConfig({ relay: 5, kind: ActKind.VALVE, close_mode: CloseMode.DEENERGIZE_TO_CLOSE, medium: Medium.WATER, zone_mask: 0x0F }));
  b.cfg.nAct = 2;
  b.di.level[7] = true;
  b.start();
  b.run(200);
  assert.equal(b.intr.mode(), ArmMode.OFF);
  b.di.level[7] = false; b.run(100);
  b.open(2, true); b.run(50);
  b.di.level[7] = true; b.run(100);
  assert.equal(b.intr.mode(), ArmMode.OFF);
  assert.equal(b.intr.takeKeyError(), true);
  assert.equal(b.intr.takeKeyError(), false);
  b.di.level[7] = false; b.open(2, false); b.run(100);
  b.di.level[7] = true; b.run(50);
  assert.equal(b.intr.mode(), ArmMode.AWAY);
  assert.ok(json(b, b.lastOf(EvType.ARM_CHANGED)).includes('"via":"di"'));
  b.di.level[7] = false; b.run(50);
  assert.equal(b.intr.mode(), ArmMode.OFF);
  assert.equal(b.countOf(EvType.ACTUATOR_CHANGED), 0);
});

test('fw_intrusion: siren VEYA: tehlike ACK hirsiz sirenini, cozme tehlike sirenini susturmaz; kullanici kapatmasi ikisini de bastirir', () => {
  const withWater = () => {
    const b = new Bench().std3();
    b.cfg.sens.push(contact(4, SensorKind.WATER, 2, 0));
    b.cfg.nSens = 4;
    closedAll(b);
    return b.start();
  };
  const b = withWater();
  b.run(100);
  b.arm(ArmMode.HOME);
  b.run(10100);
  b.di.level[4] = true; b.run(1500);
  assert.equal(b.relay(6), true);
  b.open(2, true); b.step();
  assert.equal(b.intr.st(), ArmSt.ALARM);
  assert.equal(b.core.ack(0, null, Origin.REMOTE, false, b.t), Rej.OK);
  b.step();
  assert.equal(b.relay(6), true);
  b.arm(ArmMode.OFF); b.step();
  assert.equal(b.relay(6), false);
  const c = withWater();
  c.run(100);
  c.arm(ArmMode.HOME);
  c.run(10100);
  c.open(2, true); c.step();
  c.di.level[4] = true; c.run(1500);
  c.arm(ArmMode.OFF); c.step();
  assert.equal(c.relay(6), true);
  const d = new Bench().std3();
  closedAll(d);
  d.start();
  d.run(100);
  d.arm(ArmMode.HOME);
  d.run(10100);
  d.open(2, true); d.step();
  assert.equal(d.relay(6), true);
  assert.equal(d.core.actuatorSet(0, true, Origin.REMOTE, d.t), Rej.OK);
  d.step();
  assert.equal(d.relay(6), false);
  d.open(1, true); d.step();
  assert.equal(d.relay(6), false);
});

test('fw_intrusion: hirsiz siren butcesi tehlike butcesinden ayri', () => {
  const b = new Bench().std3();
  b.cfg.act[0].run_limit_s = 10;
  b.cfg.sens.push(contact(4, SensorKind.WATER, 2, 0));
  b.cfg.nSens = 4;
  closedAll(b);
  b.start();
  b.run(100);
  b.di.level[4] = true; b.run(12000);
  assert.equal(b.relay(6), false);
  b.arm(ArmMode.HOME);
  b.run(10100);
  b.open(2, true); b.step();
  assert.equal(b.relay(6), true);
  b.run(10100);
  assert.equal(b.relay(6), false);
});

test('fw_intrusion: until_up ve ArmRecord', () => {
  const b = new Bench().std3();
  closedAll(b);
  b.start(5000);
  b.run(100);
  b.arm(ArmMode.AWAY);
  assert.equal(b.intr.untilUp(), Math.floor((5100 + 10000 + 999) / 1000));
  const r = b.intr.record();
  assert.equal(r.ver, ARM_REC_VER);
  assert.equal(r.mode, ArmMode.AWAY);
  assert.equal(r.alarm, 0);
});

// Faz 2 incelemesi RV-E2 (Unity test_boot_restores_entry_delay): giris gecikmesi surerken enerji kesilirse olay kaybolmaz.
test('fw_intrusion: giris gecikmesinde enerji kesildi -> acilista giris gecikmesi bastan, sure dolunca alarm (RV-E2)', () => {
  const b = new Bench().std3().start();
  closedAll(b);
  b.run(100);
  assert.equal(b.arm(ArmMode.AWAY), Rej.OK);
  b.run(10100);
  assert.equal(b.intr.st(), ArmSt.IDLE);
  b.intr.takeDirty();
  b.open(1, true);
  b.run(200);
  assert.equal(b.intr.st(), ArmSt.ENTRY);
  assert.equal(b.intr.takeDirty(), true, 'giris gecikmesi baslangici kalici yazilir');
  b.open(1, false);
  b.run(1000);
  const r = b.intr.record();
  assert.equal(r.mode, ArmMode.AWAY);
  assert.equal(r.alarm, ARM_REC_ENTRY);
  assert.deepEqual(r.pend, [sensorIdCode(b.cfg.sens[0])]);
  b.powerCycle();
  assert.equal(b.intr.mode(), ArmMode.AWAY);
  assert.equal(b.intr.st(), ArmSt.ENTRY);
  assert.equal(b.intr.buzzer(), BuzPattern.ENTRY);
  assert.ok(b.intr.untilUp() > 0);
  assert.equal(b.intr.aid(), '');
  b.run(4900);
  assert.equal(b.intr.st(), ArmSt.ENTRY);
  b.run(200);
  assert.equal(b.intr.st(), ArmSt.ALARM);
  assert.equal(b.countOf(EvType.INTRUSION_ALARM), 1);
  assert.deepEqual(b.intr.srcs(), [sensorIdCode(b.cfg.sens[0])]);
  b.run(100);
  assert.equal(b.relay(6), true);
});

// RV-E2 (Unity test_boot_entry_disarm_and_bad_record)
test('fw_intrusion: acilista geri gelen giris gecikmesi cozulur; bozuk kayit durum uydurmaz (RV-E2)', () => {
  const b = new Bench().std3().start();
  closedAll(b);
  b.run(100);
  b.arm(ArmMode.AWAY);
  b.run(10100);
  b.open(1, true);
  b.run(200);
  b.open(1, false);
  b.powerCycle();
  assert.equal(b.intr.st(), ArmSt.ENTRY);
  assert.equal(b.arm(ArmMode.OFF, VIA_LAN), Rej.OK);
  b.run(6000);
  assert.equal(b.intr.mode(), ArmMode.OFF);
  assert.equal(b.countOf(EvType.INTRUSION_ALARM), 0);
  assert.equal(b.intr.record().alarm, 0);
  const c = new Bench().std3();
  closedAll(c);
  c.rec = makeArmRecord({ mode: ArmMode.HOME, alarm: 7 });
  c.start();
  assert.equal(c.intr.mode(), ArmMode.HOME);
  assert.equal(c.intr.st(), ArmSt.IDLE);
  const d = new Bench().std3();
  closedAll(d);
  d.rec = makeArmRecord({ mode: ArmMode.AWAY, alarm: ARM_REC_ENTRY, pend: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10] });
  d.start();
  assert.equal(d.intr.st(), ArmSt.ENTRY);
  d.run(5100);
  assert.equal(d.intr.st(), ArmSt.ALARM);
});
