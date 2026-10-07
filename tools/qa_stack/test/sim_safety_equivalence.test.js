// WP-F2 KABUL OLCUTU (spec 2.9 [B8]): guvenlik katmani yapilandirilmamis panoda lamba/panjur davranisini DEGISTIRMEZ.
// Ayni kayitli komut + DI + ham RS485 + cocuk kilidi + yeniden baslatma dizisi iki panoda kosturulur:
//   (A) guvenlik katmani KURULU, guvenlik yapilandirmasi bos (fabrika varsayilani ya da NVS'te bos yapilandirma),
//   (B) guvenlik katmani HIC YOK (Automation {safety:false}: kancalarin hicbiri calismaz).
// Her 10 ms adimda want/hw/hwKnown, TCA golgesi, ek modul coil'leri, anlik goruntu, bipler ve olaylar BIT BIT ayni olmali.
import test from 'node:test';
import assert from 'node:assert/strict';
import { Rig, CmdType, CmdSource, makeCommand, NvsImage, makeExt } from './_rig.js';
import { DIMode, RelayType } from '../sim/fw/sysconfig.js';
import { buildWriteCoil, hexString, COIL_ON, COIL_OFF, COIL_TOGGLE } from '../sim/fw/modbus.js';
import { SafetyStore } from '../sim/fw/safety_manager.js';
import { defaultSafetyConfig } from '../sim/fw/safety_config.js';
import { writeStateExtras } from '../sim/fw/safety_view.js';

const u32 = (x) => x >>> 0;

/** Deterministik LCG (kayitli dizi her kosuda aynidir). */
function lcg(seed) {
  let s = u32(seed);
  return () => { s = u32(Math.imul(s, 1664525) + 1013904223); return s / 0x100000000; };
}

function configure(cm) {
  const c = cm.config;
  c.ext_module_enabled = true;
  c.ext_module_channels = 8;
  c.ext_module_address = 1;
  c.relays[0].type = RelayType.SHUTTER_UP; c.relays[0].runtime_sec = 3;
  c.relays[1].type = RelayType.SHUTTER_DOWN; c.relays[1].runtime_sec = 3;
  c.relays[2].type = RelayType.IMPULSE; c.relays[2].runtime_sec = 700;
  for (let i = 3; i < 8; i++) c.relays[i].type = RelayType.LIGHT;
  c.relays[8].type = RelayType.SHUTTER_UP; c.relays[8].runtime_sec = 2;
  c.relays[9].type = RelayType.SHUTTER_DOWN; c.relays[9].runtime_sec = 2;
  for (let i = 10; i < 16; i++) c.relays[i].type = RelayType.LIGHT;
  const di = (n, target, mode) => { c.dis[n - 1].target_relay = target; c.dis[n - 1].mode = mode; };
  di(1, 5, DIMode.TOGGLE);
  di(2, 6, DIMode.MOMENTARY);
  di(3, 1, DIMode.SHUTTER_STEP);
  di(4, 1, DIMode.SHUTTER_UP);
  di(5, 2, DIMode.SHUTTER_DOWN);
  di(6, 3, DIMode.TOGGLE);
  di(9, 11, DIMode.TOGGLE);
  di(10, 9, DIMode.SHUTTER_STEP);
  di(11, 12, DIMode.MOMENTARY);
  c.validate();
}

function makePair(nvsA) {
  const opts = { ext: makeExt(8), configure, skipBootHold: false };
  const a = new Rig({ ...opts, nvs: nvsA, automation: { safetyNonce: 0x12345678 } });
  const b = new Rig({ ...opts, ext: makeExt(8), automation: { safety: false } });
  return [a, b];
}

function trace(r) {
  const a = r.a;
  return JSON.stringify({
    t: r.t, want: a.want, hw: a.hw, known: a.hwKnown, imp: a.impulseActive, shadow: a.tca.outputShadow(), latch: a.tca.latch,
    coils: r.ext.coils, snap: a.getSnapshot(), lastId: a.lastId, q: a.queue.length, halted: !!r.halted,
  });
}

const CMDS = [
  () => [CmdType.RELAY_SET, 1 + Math.floor(rnd() * 17), rnd() < 0.5 ? 1 : 0],
  () => [CmdType.RELAY_TOGGLE, 1 + Math.floor(rnd() * 17), 0],
  () => [CmdType.SHUTTER_UP, 1 + Math.floor(rnd() * 9), 0],
  () => [CmdType.SHUTTER_DOWN, 1 + Math.floor(rnd() * 9), 0],
  () => [CmdType.SHUTTER_STOP, 1 + Math.floor(rnd() * 9), 0],
  () => [CmdType.SHUTTER_STEP, 1 + Math.floor(rnd() * 9), 0],
  () => [CmdType.SHUTTER_POS, 1 + Math.floor(rnd() * 9), Math.floor(rnd() * 110)],
  () => [CmdType.ALL_LIGHTS_OFF, 0, 0],
  () => [CmdType.ALL_SHUTTERS_UP, 0, 0],
  () => [CmdType.ALL_SHUTTERS_DOWN, 0, 0],
  () => [CmdType.ALL_SHUTTERS_STOP, 0, 0],
  () => [CmdType.SET_CHILD_LOCK, 0, rnd() < 0.3 ? 1 : 0],
  () => [CmdType.SET_RUNTIME, 1 + Math.floor(rnd() * 6), Math.floor(rnd() * 5)],
];
let rnd = lcg(1);

/** Kayitli dizi: her eylem ayni anda iki panoya uygulanir. */
function scenario(seed, steps) {
  rnd = lcg(seed);
  const plan = [];
  for (let k = 0; k < steps; k++) {
    const gap = 20 + Math.floor(rnd() * 400);
    const x = rnd();
    if (x < 0.45) {
      const [type, index, value] = CMDS[Math.floor(rnd() * CMDS.length)]();
      plan.push({ gap, kind: 'cmd', type, index, value, id: rnd() < 0.5 ? `c${k}` : '', src: rnd() < 0.5 ? CmdSource.MQTT : CmdSource.WEB });
    } else if (x < 0.75) {
      const di = [1, 2, 3, 4, 5, 6, 7, 9, 10, 11, 12][Math.floor(rnd() * 11)];
      plan.push({ gap, kind: 'press', di, hold: 30 + Math.floor(rnd() * 300) });
    } else if (x < 0.85) {
      plan.push({ gap, kind: 'ch', ch: Math.floor(rnd() * 9), action: Math.floor(rnd() * 3) });
    } else if (x < 0.95) {
      const addr = rnd() < 0.1 ? 0x00FF : Math.floor(rnd() * 8);
      const val = [COIL_ON, COIL_OFF, COIL_TOGGLE][Math.floor(rnd() * 3)];
      plan.push({ gap, kind: 'raw', hex: hexString(buildWriteCoil(1, addr, val)) });
    } else {
      plan.push({ gap, kind: 'run', ms: 500 + Math.floor(rnd() * 3000) });
    }
  }
  return plan;
}

function apply(r, s) {
  switch (s.kind) {
    case 'cmd': r.cmd(s.type, s.index, s.value, s.id, s.src); break;
    case 'press':
      if (s.di <= 8) r.a.setRawDi(s.di - 1, true); else r.ext.rawDi[s.di - 9] = true;
      return s.hold;
    case 'ch': r.a.rs485ControlExtRelay(1, s.ch, s.action, r.t); break;
    case 'raw': r.a.rs485Send(s.hex, true, r.t); break;
    case 'run': return s.ms;
    default: break;
  }
  return 0;
}
function release(r, s) {
  if (s.kind !== 'press') return;
  if (s.di <= 8) r.a.setRawDi(s.di - 1, false); else r.ext.rawDi[s.di - 9] = false;
}

function runLockstep(a, b, plan) {
  let checked = 0;
  const step = (ms) => {
    for (let d = 0; d < ms; d += 10) {
      a.step(10);
      b.step(10);
      const ta = trace(a);
      const tb = trace(b);
      if (ta !== tb) assert.fail(`iz ayristi t=${a.t}\nA=${ta}\nB=${tb}`);
      checked++;
    }
  };
  step(600);                                                     // acilis bekleme penceresi dahil
  for (const s of plan) {
    step(s.gap);
    const hold = Math.max(apply(a, s), apply(b, s));
    if (hold) step(hold);
    release(a, s);
    release(b, s);
  }
  step(5000);
  return checked;
}

test('sim_safety_equivalence: fabrika varsayilani (guvenlik yapilandirmasi yok) == katman yok; iz bit bit ayni', () => {
  const [a, b] = makePair(new NvsImage(null));
  const n = runLockstep(a, b, scenario(20261006, 260));
  assert.ok(n > 5000, `adim sayisi ${n}`);
  assert.deepEqual(a.beeps, b.beeps);
  assert.deepEqual(a.events, b.events);
  assert.deepEqual(a.violations, []);
  assert.equal(a.a.safety.active(), false);
  assert.equal(a.a.actuatorMask, 0n);
  assert.equal(a.a.sensorDiMask, 0n);
});

test('sim_safety_equivalence: NVS\'te bos guvenlik yapilandirmasi (sensor/eylemci yok) == katman yok; cocuk kilidi + yeniden baslatma dahil', () => {
  const nvs = new NvsImage(null);
  SafetyStore.saveConfig(nvs, defaultSafetyConfig());
  const [a, b] = makePair(nvs);
  const plan = scenario(424242, 200);
  plan.push({ gap: 100, kind: 'cmd', type: CmdType.SET_CHILD_LOCK, index: 0, value: 1, id: 'lk', src: CmdSource.MQTT });
  plan.push({ gap: 100, kind: 'press', di: 1, hold: 200 });
  plan.push({ gap: 100, kind: 'press', di: 3, hold: 200 });
  plan.push({ gap: 300, kind: 'cmd', type: CmdType.SET_CHILD_LOCK, index: 0, value: 0, id: 'ul', src: CmdSource.MQTT });
  runLockstep(a, b, plan);
  // planli yeniden baslatma (emergencyAllOff + hook) ve ayni NVS ile soguk acilis
  a.a.requestRestart(300, a.t);
  b.a.requestRestart(300, b.t);
  for (let k = 0; k < 60; k++) {
    a.step(10);
    b.step(10);
    assert.equal(trace(a), trace(b));
  }
  assert.equal(a.restarts, 1);
  assert.equal(b.restarts, 1);
  assert.deepEqual(a.beeps, b.beeps);
  assert.deepEqual(a.events, b.events);
});

test('sim_safety_equivalence: yapilandirilmamis panoda guvenlik kancalari bosta (maske 0, kilit kaydi yalniz ayrilir)', () => {
  const nvs = new NvsImage(null);
  const r = new Rig({ nvs, ext: makeExt(8), configure, automation: { safetyNonce: 1 } });
  r.run(2000);
  assert.equal(r.a.safety.active(), false);
  assert.equal(r.a.safety.bootLevelMask(), 0n);
  assert.equal(r.a.safety.shutdownKeepLocal(), 0);
  assert.equal(r.a.safety.scanBlocked(), false);
  assert.equal(r.a.buzzerAlarm, false);
  const latch = nvs.get('latch');
  assert.ok(latch && latch.latch, 'kilit kaydi icin yer ayrildi (F0 onlemi)');
  assert.equal(latch.bootc, 1);
  assert.equal(nvs.get('safety'), null, 'guvenlik yapilandirmasi yazilmadi');
});

// Faz 2 (F2 degismez ilke 2, F2.B.11): hirsiz katmani (IntrusionCore, ContactBus, siren VEYA'si) kapi/pencere/hareket sensoru OLMAYAN
// panoda hicbir sey degistirmez. Su sensoru (DI 8) + vana (role 7) + siren (role 8) yapilandirilmis iki pano: (A) hirsiz katmani KURULU,
// (B) hirsiz katmani HIC YOK (v1.2.0). Ayni kayitli dizi + su alarmlari: want/hw/TCA/coil/anlik goruntu, olay kutusu ve state eki bit bit ayni.
test('sim_safety_equivalence: hirsiz sensoru olmayan (su + vana + siren) panoda hirsiz katmani == katman yok; iz, olaylar ve state eki ayni', () => {
  const hazard = () => {
    const nvs = new NvsImage(null);
    const c = defaultSafetyConfig();
    c.sens = [{ src: 0, index: 8, kind: 1, zone: 1, active_open: 0, flags: 1, confirm_ms: 1000, name: 'Banyo' }];
    c.nSens = 1;
    c.act = [
      { relay: 7, kind: 1, close_mode: 0, fb_di: 0, fb_closed_active: 1, zone_mask: 1, fb_timeout_s: 60, run_limit_s: 0, medium: 1, aflags: 0, name: 'Vana', relay2: 0 },
      { relay: 8, kind: 2, close_mode: 0, fb_di: 0, fb_closed_active: 0, zone_mask: 1, fb_timeout_s: 0, run_limit_s: 20, medium: 0, aflags: 0, name: 'Siren', relay2: 0 },
    ];
    c.nAct = 2;
    c.rev = 3;
    SafetyStore.saveConfig(nvs, c);
    return nvs;
  };
  const cfgHazard = (cm) => { configure(cm); cm.config.dis[7].target_relay = 0; cm.config.validate(); };   // DI 8 sensor (duvar butonu degil)
  const opts = { configure: cfgHazard, skipBootHold: false };
  const a = new Rig({ ...opts, ext: makeExt(8), nvs: hazard(), automation: { safetyNonce: 0x0badf00d } });
  const b = new Rig({ ...opts, ext: makeExt(8), nvs: hazard(), automation: { safetyNonce: 0x0badf00d, intrusion: false } });
  const plan = scenario(77001, 160);
  plan.splice(40, 0, { gap: 50, kind: 'press', di: 8, hold: 1800 });   // su alarmi: vana kapanir, siren calar
  plan.splice(90, 0, { gap: 50, kind: 'press', di: 8, hold: 600 });
  plan.push({ gap: 100, kind: 'press', di: 8, hold: 2500 });
  plan.push({ gap: 100, kind: 'run', ms: 21000 });                    // siren butcesi dolar
  runLockstep(a, b, plan);
  assert.ok(a.a.safety.latched(), 'senaryo kilit uretti');
  const meta = { ...a.a.safety.stateMeta(), timeOk: false, epoch: 0 };
  assert.equal(writeStateExtras(a.a.safety.copyView(), meta), writeStateExtras(b.a.safety.copyView(), { ...b.a.safety.stateMeta(), timeOk: false, epoch: 0 }));
  assert.ok(!writeStateExtras(a.a.safety.copyView(), meta).includes('"arm"'));
  assert.deepEqual(a.a.safety.outbox.list().map((x) => [x.eid, x.ev.type]), b.a.safety.outbox.list().map((x) => [x.eid, x.ev.type]));
  assert.deepEqual(a.beeps, b.beeps);
  assert.deepEqual(a.events, b.events);
  assert.equal(a.a.safety.buzzerPattern(), 0);
});
