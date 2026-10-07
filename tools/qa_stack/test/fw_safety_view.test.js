// Firmware SafetyView (src/safety/SafetyView.h) JS portunun UYUMLULUK testi: firmware'in kendi Unity testlerinin
// (ev_otomasyon_servis_yazilimi/waveshare_s3_demo/test/test_safety_view/test_main.cpp) BIREBIR portu.
import test from 'node:test';
import assert from 'node:assert/strict';
import { SafetyCore, ZoneSt, Rej } from '../sim/fw/safety_fsm.js';
import { SensorHub, SensorKind, SensorSrc, defaultFlags, defaultConfirmMs, makeSensorConfig } from '../sim/fw/sensor_hub.js';
import { ActuatorCore, ActKind, CloseMode, Medium, makeActuatorConfig } from '../sim/fw/actuator_map.js';
import { EventOutbox } from '../sim/fw/event_outbox.js';
import { defaultSafetyConfig, configCrc, SafeReason } from '../sim/fw/safety_config.js';
import { buildView, writeStateExtras, viewSignature, relayActText } from '../sim/fw/safety_view.js';
import { IntrusionCore, ArmMode, ArmSt } from '../sim/fw/intrusion_fsm.js';
import { VIA_LAN } from '../sim/fw/event_outbox.js';

const u32 = (x) => x >>> 0;
const hex8 = (v) => (v >>> 0).toString(16).padStart(8, '0');

class FakeSource {
  constructor() { this.level = new Array(41).fill(false); this.okv = new Array(41).fill(true); }
  sample(c) { return c.index <= 40 ? { level: this.level[c.index], ok: this.okv[c.index] } : { level: false, ok: false }; }
}

class Bench {
  constructor() { this.cfg = defaultSafetyConfig(); this.di = new FakeSource(); this.br = new FakeSource(); this.t = 1000; }
  water() {
    this.cfg.sens = [makeSensorConfig({ src: SensorSrc.DI, index: 3, kind: SensorKind.WATER, zone: 1, flags: defaultFlags(SensorKind.WATER), confirm_ms: defaultConfirmMs(SensorKind.WATER), name: 'Banyo' })];
    this.cfg.nSens = 1;
    this.cfg.act = [
      makeActuatorConfig({ relay: 5, kind: ActKind.VALVE, close_mode: CloseMode.DEENERGIZE_TO_CLOSE, medium: Medium.WATER, zone_mask: 1, fb_timeout_s: 60, name: 'Ana Vana' }),
      makeActuatorConfig({ relay: 6, kind: ActKind.SIREN, zone_mask: 1, run_limit_s: 180 }),
    ];
    this.cfg.nAct = 2;
    this.cfg.rev = 3;
  }
  start(mode = SafeReason.NONE) {
    this.hub = new SensorHub();
    this.act = new ActuatorCore();
    this.out = new EventOutbox();
    this.core = new SafetyCore();
    this.out.begin(0x9f3a11c0);
    this.act.configure(this.cfg.act, this.cfg.nAct, 0, 0, this.t);
    this.hub.configure(this.cfg.sens, this.cfg.nSens, this.t);
    this.core.begin(this.cfg, this.hub, this.act, this.out, null, mode, this.t);
    this.step(0);
  }
  step(ms = 10) { this.t = u32(this.t + ms); this.core.tick(this.t, 1791273000, this.di, this.br); }
  run(ms) { for (let d = 0; d < ms; d += 10) this.step(10); }
  view() { return buildView(this.cfg, this.hub, this.act, this.core, this.t); }
}

const meta = (timeOk = true) => ({ boot: 57, bn: 0x9f3a11c0, timeOk, epoch: timeOk ? 1791273600 : 0, rejId: '', rej: Rej.OK });

test('fw_safety_view: yapilandirilmamis panoda yalniz caps/boot/bn/time_ok/epoch', () => {
  const b = new Bench();
  b.start();
  const v = b.view();
  assert.equal(v.configured, 0);
  assert.equal(writeStateExtras(v, meta(false)), ',"caps":["safety","actuator","event","cfg","intrusion"],"boot":57,"bn":"9f3a11c0","time_ok":false,"epoch":0');
  assert.equal(relayActText(v, 5), null);
});

test('fw_safety_view: yapilandirilmis panoda adsiz sensor/eylemci satirlari, cfg rev/crc, role act', () => {
  const b = new Bench();
  b.water();
  b.start();
  const v = b.view();
  assert.equal(v.configured, 1);
  assert.equal(v.rev, 3);
  assert.equal(v.crc, configCrc(b.cfg));
  const s = writeStateExtras(v, meta());
  assert.ok(s.includes(',"time_ok":true,"epoch":1791273600'));
  assert.ok(s.includes(`,"cfg":{"safety":{"rev":3,"crc":"${hex8(configCrc(b.cfg))}"}}`));
  assert.ok(s.includes(',"sensors":[{"id":"d3","src":"di","kind":"water","zone":1,"active":false,"ok":true}]'));
  assert.ok(s.includes(',"actuators":[{"id":"a1","relay":5,"kind":"valve","medium":"water","zones":[1],"pos":"unknown","fb":null,"fault":false},'
    + '{"id":"a2","relay":6,"kind":"siren","zones":[1],"on":false,"fault":false}]'));
  assert.ok(s.includes(',"safety":{"policy":"on","mode":"normal","zones":[]}'));
  assert.ok(!s.includes('Banyo') && !s.includes('Ana Vana') && !s.includes('last_rej'));
  assert.equal(relayActText(v, 5), 'valve');
  assert.equal(relayActText(v, 6), 'siren');
  assert.equal(relayActText(v, 7), null);
  assert.doesNotThrow(() => JSON.parse(`{"v":3${s}}`));
});

test('fw_safety_view: kilitli bolge satiri; imza alarmda degisir, yalniz zaman ilerleyince degismez', () => {
  const b = new Bench();
  b.water();
  b.start();
  const v0 = b.view();
  b.di.level[3] = true;
  b.run(1500);
  assert.equal(b.core.zoneState(1), ZoneSt.LATCHED);
  const v1 = b.view();
  assert.notEqual(viewSignature(v0), viewSignature(v1));
  const s = writeStateExtras(v1, meta());
  assert.ok(s.includes(`"zones":[{"id":1,"st":"latched","kind":"water","aid":"${b.core.zone(1).aid}","since":1791273000,"since_up":0,"silenced":false,"srcs":["d3"]}]`));
  assert.ok(s.includes('"pos":"cmd_closed"'));
  assert.ok(s.includes('"active":true,"ok":true'));
  assert.ok(s.includes('"on":true'));
  b.run(5000);
  const v2 = b.view();
  assert.ok(v2.zones[0].sinceUp >= 5);
  assert.equal(viewSignature(v2), viewSignature(v1));
});

test('fw_safety_view: guvenli kip nedeni ve last_rej (id yoksa yalniz code)', () => {
  const b = new Bench();
  b.water();
  b.start(SafeReason.CFG_CORRUPT);
  const v = b.view();
  const m = { ...meta(), rejId: 'c820', rej: Rej.SAFE_MODE };
  let s = writeStateExtras(v, m);
  assert.ok(s.includes('"mode":"safe","reason":"cfg_corrupt"'));
  assert.ok(s.includes(',"last_rej":{"id":"c820","code":"safe_mode"}'));
  s = writeStateExtras(v, { ...m, rejId: '', rej: Rej.BUSY });
  assert.ok(s.includes(',"last_rej":{"code":"busy"}'));
});

test('fw_safety_view: kontrol rolu satiri (ham basili seviye)', () => {
  const b = new Bench();
  b.water();
  b.cfg.sens.push(makeSensorConfig({ src: SensorSrc.DI, index: 4, kind: SensorKind.ALARM_ACK, zone: 0 }));
  b.cfg.nSens = 2;
  b.start();
  b.di.level[4] = true;
  b.run(100);
  const s = writeStateExtras(b.view(), meta());
  assert.ok(s.includes('{"id":"d4","src":"di","kind":"alarm_ack","zone":0,"active":true,"ok":true}'));
});

// Faz 2 (F2.B.7; Unity test_arm_object): arm yalniz hirsiz sensoru varsa; until_up sabit (imza degismez); alarmda aid + srcs; guvenli kipte ok=false.
test('fw_safety_view: safety.arm nesnesi', () => {
  const b = new Bench();
  b.water();
  b.start();
  const i0 = new IntrusionCore();
  i0.begin(b.cfg, b.hub, b.out, null, b.t);
  assert.ok(!writeStateExtras(buildView(b.cfg, b.hub, b.act, b.core, b.t, i0), meta()).includes('"arm"'));
  const c = new Bench();
  c.water();
  c.cfg.sens.push(makeSensorConfig({ src: SensorSrc.DI, index: 7, kind: SensorKind.DOOR, zone: 1, active_open: 1, flags: defaultFlags(SensorKind.DOOR) }));
  c.cfg.nSens = 2;
  c.cfg.pol.exit_s = 20;
  c.di.level[7] = true;
  c.start();
  const intr = new IntrusionCore();
  intr.begin(c.cfg, c.hub, c.out, null, c.t);
  c.run(100);
  intr.tick(c.t, 0);
  let v = buildView(c.cfg, c.hub, c.act, c.core, c.t, intr);
  assert.ok(writeStateExtras(v, meta()).includes(',"arm":{"mode":"off","st":"idle","ok":true}}'));
  const sig0 = viewSignature(v);
  assert.equal(intr.command(ArmMode.AWAY, VIA_LAN, c.t), Rej.OK);
  v = buildView(c.cfg, c.hub, c.act, c.core, c.t, intr);
  assert.ok(writeStateExtras(v, meta()).includes(`,"arm":{"mode":"away","st":"exit","ok":true,"until_up":${Math.floor((c.t + 20000 + 999) / 1000)}}}`));
  const sig1 = viewSignature(v);
  assert.notEqual(sig0, sig1);
  c.run(3000);
  intr.tick(c.t, 0);
  assert.equal(viewSignature(buildView(c.cfg, c.hub, c.act, c.core, c.t, intr)), sig1);
  c.di.level[7] = false;
  for (let k = 0; k < 600; k++) { c.step(100); intr.tick(c.t, 0); }
  assert.equal(intr.st(), ArmSt.ALARM);
  v = buildView(c.cfg, c.hub, c.act, c.core, c.t, intr);
  assert.ok(writeStateExtras(v, meta()).includes(`,"arm":{"mode":"away","st":"alarm","ok":true,"aid":"${intr.aid()}","srcs":["d7"]}}`));
  intr.setUsable(false);
  assert.ok(writeStateExtras(buildView(c.cfg, c.hub, c.act, c.core, c.t, intr), meta()).includes('"st":"alarm","ok":false,'));
});
