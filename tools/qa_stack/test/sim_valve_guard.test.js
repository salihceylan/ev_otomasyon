// WP-F3: ValveGuard (bagimsiz emniyet, spec 5.1.5 [Y-8][B7]) -- sim/fw/automation.js portu. Guard gorevi (Core 0, 50 ms) loop'tan bagimsiz
// calisir: yerel 8 role DONANIMDAN okunur; cip sifirlanmasinda enerjiyle kapanan (E2C) vana 2 sn'lik TCA_Verify beklenmeden yeniden kurulur,
// acik kalan D2C vana kapatilir; panjur cifti bitleri asla kurulmaz; ek modulde yalniz loop acliginda ve en cok 1 sn'de bir yazilir;
// yapilandirilmamis panoda guard hicbir sey yapmaz; planli yeniden baslatmada kapatma yazimina karismaz.
import test from 'node:test';
import assert from 'node:assert/strict';
import { Rig, CmdType, NvsImage, makeExt } from './_rig.js';
import { DIMode, RelayType } from '../sim/fw/sysconfig.js';
import { SafetyStore, SafetyCmdType } from '../sim/fw/safety_manager.js';
import { defaultSafetyConfig } from '../sim/fw/safety_config.js';
import { SensorKind, SensorSrc, defaultFlags, defaultConfirmMs, makeSensorConfig } from '../sim/fw/sensor_hub.js';
import { ActKind, CloseMode, Medium, makeActuatorConfig } from '../sim/fw/actuator_map.js';
import { ZoneSt } from '../sim/fw/safety_fsm.js';

function boardConfig(cm, { ext = 0 } = {}) {
  const c = cm.config;
  for (let i = 0; i < 8; i++) { c.relays[i].type = RelayType.LIGHT; c.dis[i].target_relay = 0; c.dis[i].mode = DIMode.TOGGLE; }
  c.relays[0].type = RelayType.SHUTTER_UP;   // panjur cifti 1 (role 1-2): guard bu bitleri ASLA kurmaz
  c.relays[1].type = RelayType.SHUTTER_DOWN;
  if (ext) {
    c.ext_module_enabled = true;
    c.ext_module_channels = ext;
    for (let i = 8; i < 8 + ext; i++) c.relays[i].type = RelayType.LIGHT;
  }
  c.validate();
  cm.save();
}

function safetyNvs({ relay = 5, mode = CloseMode.ENERGIZE_TO_CLOSE } = {}) {
  const nvs = new NvsImage(null);
  const cfg = defaultSafetyConfig();
  cfg.sens = [makeSensorConfig({ src: SensorSrc.DI, index: 3, kind: SensorKind.WATER, zone: 1, flags: defaultFlags(SensorKind.WATER), confirm_ms: defaultConfirmMs(SensorKind.WATER) })];
  cfg.nSens = 1;
  cfg.act = [makeActuatorConfig({ relay, kind: ActKind.VALVE, close_mode: mode, medium: Medium.WATER, zone_mask: 1, fb_timeout_s: 60 })];
  cfg.nAct = 1;
  SafetyStore.saveConfig(nvs, cfg);
  return nvs;
}

const rig = (nvs, ext = 0) => new Rig({ nvs, ext: makeExt(ext), configure: (cm) => boardConfig(cm, { ext }), automation: { safetyNonce: 0x1234 } });
const guardEvents = (r, action) => r.events.filter((e) => e.type === 'valve_guard' && (!action || e.action === action));

test('ValveGuard: cip sifirlanmasinda (TCA latch dustu) E2C vana 2 sn verify beklenmeden ~50 ms icinde yeniden kurulur; panjur biti kurulmaz', () => {
  const r = rig(safetyNvs());
  r.a.setRawDi(2, true);
  r.run(1300);
  assert.equal(r.a.safety.core.zoneState(1), ZoneSt.LATCHED);
  assert.equal(r.a.tca.latch & 0x10, 0x10);
  r.a.lastTcaVerify = r.t;                    // periyodik dogrulama (2 sn) bu pencerede calismasin: duzeltme guard'dan gelmeli
  r.a.tca.qaForceLatchOn(0x01);               // panjur yukari rolesi de "acik" gorunsun (kurmamali, yalniz dokunmamali)
  r.a.tca.qaChipReset();
  assert.equal(r.a.tca.latch & 0x10, 0);
  r.run(60);
  assert.equal(r.a.tca.latch & 0x10, 0x10, 'guard vanayi yeniden enerjiledi');
  assert.equal(r.a.tca.latch & 0x03, 0, 'panjur cifti biti kurulmadi');
  assert.ok(guardEvents(r, 'set').length >= 1);
  assert.deepEqual(r.violations, []);
});

test('ValveGuard: loop takili iken de calisir (bagimsiz gorev); D2C kapali vananin fiziksel olarak acik kalan rolesi kapatilir', () => {
  const r = rig(safetyNvs({ mode: CloseMode.DEENERGIZE_TO_CLOSE }));
  r.run(100);
  assert.equal(r.relay(5), true, 'D2C konum bilinmiyor = acik (enerjili)');
  r.cmd(SafetyCmdType.ACTUATOR_SET, 1, 0);    // kullanici vanayi KAPATTI
  r.run(50);
  assert.equal(r.a.tca.latch & 0x10, 0);
  r.a.qaLoopStalled = true;
  r.a.tca.qaForceLatchOn(0x10);               // role kendiliginden/yanlis yazimla enerjilendi: vana acildi
  r.run(60);
  assert.equal(r.a.tca.latch & 0x10, 0, 'guard KAPATTI');
  assert.ok(guardEvents(r, 'clear').length >= 1);
  r.a.qaLoopStalled = false;
});

test('ValveGuard: ek modul vanasi yalniz loop acliginda (>= 1000 ms) ve en cok 1 sn de bir korlemesine yazilir', () => {
  const r = rig(safetyNvs({ relay: 9 }), 8);
  r.run(300);
  r.a.setRawDi(2, true);
  r.run(1500);
  assert.equal(r.a.safety.core.zoneState(1), ZoneSt.LATCHED);
  assert.equal(r.ext.coils[0], true, 'E2C ek modul vanasi kapali = coil enerjili');
  r.run(3000);
  assert.equal(guardEvents(r, 'ext').length, 0, 'loop calisirken guard ek module yazmaz (loop her turda dayatir)');
  r.a.qaLoopStalled = true;
  r.ext.coils[0] = false;                     // coil dustu (modul sifirlandi), loop takili
  r.run(900);
  assert.equal(r.ext.coils[0], false, 'aclik 1000 ms dolmadan yazim yok');
  assert.ok(r.runUntil(() => r.ext.coils[0] === true, 300), 'aclikta guard guvenli seviyeyi yazdi');
  const n = guardEvents(r, 'ext').length;
  r.ext.coils[0] = false;
  r.run(900);
  assert.equal(guardEvents(r, 'ext').length, n, 'hiz siniri: 1 sn dolmadan ikinci yazim yok');
  assert.ok(r.runUntil(() => guardEvents(r, 'ext').length === n + 1, 200));
  assert.equal(r.ext.coils[0], true);
  r.a.qaLoopStalled = false;
});

test('ValveGuard: yapilandirilmamis panoda guard hicbir sey yapmaz (cip sifirlanmasi bugunku gibi yalniz TCA_Verify ile)', () => {
  const r = new Rig({ nvs: new NvsImage(null), ext: makeExt(0), configure: (cm) => boardConfig(cm), automation: { safetyNonce: 1 } });
  r.cmd(CmdType.RELAY_SET, 5, 1);
  r.run(50);
  r.a.lastTcaVerify = r.t;
  r.a.tca.qaChipReset();
  r.run(500);
  assert.equal(guardEvents(r).length, 0);
  assert.equal(r.a.tca.latch & 0x10, 0, 'lamba guard tarafindan geri cekilmez');
  assert.deepEqual(r.a.safeMasks, { assert: 0n, level: 0n, gen: 0 });
});

test('ValveGuard: planli yeniden baslatmada kapatma yazimina karismaz (korunan bit shutdown maskesinde)', () => {
  const r = rig(safetyNvs());
  r.cmd(CmdType.RELAY_SET, 7, 1);
  r.a.setRawDi(2, true);
  r.run(1300);
  r.a.requestRestart(200, r.t);
  r.run(400);
  assert.equal(r.restarts, 1);
  assert.equal(r.a.guardHold, true);
  assert.equal(r.a.tca.outputShadow() & 0x10, 0x10);
  assert.equal(r.a.tca.outputShadow() & 0x40, 0);
});
