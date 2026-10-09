// Firmware SafetyConfig (src/safety/SafetyConfig.h) JS portunun UYUMLULUK testi: firmware'in kendi Unity testlerinin
// (ev_otomasyon_servis_yazilimi/waveshare_s3_demo/test/test_safety_config/test_main.cpp) BIREBIR portu.
import test from 'node:test';
import assert from 'node:assert/strict';
import {
  defaultSafetyConfig, isEmptyConfig, validate, CfgErr, cfgErrText, touchesLockedZones, crc32, packBlob, unpackBlobCount, encodeSensor,
  encodeActuator, configCrc, latchClear, latchSeal, latchValid, latchAny, latchZoneMask, latchAssert64, latchLevel64, latchSetMasks,
  encodeLatch, crashClear, crashOnBoot, crashLoop, crashStableTick, CRASH_STABLE_MS, SafeReason, decideBootMode, safeReasonText,
  nvsBlobEntries, configNvsEntries, NVS_SAFETY_RESERVE_ENTRIES, NVS_GC_PAGE_ENTRIES, nvsRoomForConfig, bootMaskForSystem, validateSystemChange,
  encodePolicy, DRY_HOLD_DEFAULT_MS, latchCovered,
} from '../sim/fw/safety_config.js';
import { SF_REACT, SF_ENTRY, SF_AWAY_ONLY } from '../sim/fw/sensor_hub.js';
import { SensorKind, SensorSrc, defaultFlags, defaultConfirmMs, makeSensorConfig } from '../sim/fw/sensor_hub.js';
import { ActKind, CloseMode, Medium, makeActuatorConfig } from '../sim/fw/actuator_map.js';
import { SystemConfig, RelayType } from '../sim/fw/sysconfig.js';

function sys8() {
  const s = new SystemConfig();
  s.ext_module_enabled = false;
  s.ext_module_channels = 0;
  for (const r of s.relays) r.type = RelayType.LIGHT;
  for (const d of s.dis) d.target_relay = 0;
  return s;
}
const sensor = (di, kind, zone, nc) => makeSensorConfig({ src: SensorSrc.DI, index: di, kind, zone, active_open: nc, flags: defaultFlags(kind), confirm_ms: defaultConfirmMs(kind) });
const valve = (relay, medium, zones = 0x01) => makeActuatorConfig({ relay, kind: ActKind.VALVE, close_mode: CloseMode.DEENERGIZE_TO_CLOSE, medium, zone_mask: zones, fb_timeout_s: 60 });
const siren = (relay, lim = 180) => makeActuatorConfig({ relay, kind: ActKind.SIREN, zone_mask: 0x01, run_limit_s: lim });
function base() {
  const c = defaultSafetyConfig();
  c.sens = [sensor(3, SensorKind.WATER, 1, 0)];
  c.nSens = 1;
  c.act = [valve(5, Medium.WATER), siren(6)];
  c.nAct = 2;
  return c;
}
const V = (s, c) => validate(s, c);

test('fw_safety_config: yapi boyutlari (kodlama) ve fabrika varsayilanlari', () => {
  assert.equal(encodeSensor(makeSensorConfig()).length, 28);
  assert.equal(encodeActuator(makeActuatorConfig()).length, 36);
  assert.equal(encodeLatch(latchClear()).length, 164);
  const c = defaultSafetyConfig();
  assert.equal(c.pol.policy_on, 1);
  assert.equal(c.pol.dry_hold_ms, 10000);
  assert.equal(c.zones[0].name, 'Ev');
  assert.equal(c.nSens, 0);
  assert.equal(c.nAct, 0);
  assert.equal(isEmptyConfig(c), true);
  assert.equal(V(sys8(), c), CfgErr.OK);
  assert.equal(V(sys8(), base()), CfgErr.OK);
});

test('fw_safety_config: panjur/darbe rolesi, kanal sayisi dususu, akiskan, siren siniri, gaz/duman NC', () => {
  let s = sys8();
  let c = base();
  s.relays[4].type = RelayType.SHUTTER_DOWN;
  assert.equal(V(s, c), CfgErr.ACT_RELAY_SHUTTER);
  s.relays[4].type = RelayType.IMPULSE;
  assert.equal(V(s, c), CfgErr.ACT_RELAY_IMPULSE);
  s = sys8();
  s.ext_module_enabled = true;
  s.ext_module_channels = 8;
  c = base();
  c.act[0].relay = 12;
  c.sens[0].index = 14;
  assert.equal(V(s, c), CfgErr.OK);
  s.ext_module_enabled = false;
  assert.ok([CfgErr.ACT_RELAY_RANGE, CfgErr.SENSOR_DI_RANGE].includes(V(s, c)));
  c.act[0].relay = 5;
  assert.equal(V(s, c), CfgErr.SENSOR_DI_RANGE);
  s = sys8();
  c = base();
  c.act[0].medium = Medium.NONE;
  assert.equal(V(s, c), CfgErr.VALVE_MEDIUM);
  c = base();
  for (const [lim, want] of [[0, CfgErr.SIREN_RUN_LIMIT], [9, CfgErr.SIREN_RUN_LIMIT], [1801, CfgErr.SIREN_RUN_LIMIT], [10, CfgErr.OK]]) {
    c.act[1].run_limit_s = lim;
    assert.equal(V(s, c), want, `run_limit_s=${lim}`);
  }
  c = base();
  c.sens[1] = sensor(4, SensorKind.GAS, 1, 0);
  c.nSens = 2;
  assert.equal(V(s, c), CfgErr.GAS_SMOKE_NOT_NC);
  c.sens[1] = sensor(4, SensorKind.SMOKE, 1, 0);
  assert.equal(V(s, c), CfgErr.GAS_SMOKE_NOT_NC);
  c.sens[1].active_open = 1;
  assert.equal(V(s, c), CfgErr.OK);
});

test('fw_safety_config: sensor DI duvar butonu olamaz; tekrarlar; geri bildirim DI kurallari', () => {
  let s = sys8();
  let c = base();
  s.dis[2].target_relay = 1;
  assert.equal(V(s, c), CfgErr.SENSOR_DI_IS_BUTTON);
  s = sys8();
  c = base();
  c.act[1].relay = 5;
  assert.equal(V(s, c), CfgErr.ACT_RELAY_DUP);
  c = base();
  c.sens[1] = sensor(3, SensorKind.WATER, 2, 0);
  c.nSens = 2;
  assert.equal(V(s, c), CfgErr.SENSOR_DUP);
  c = base();
  c.act[0].fb_di = 3;
  assert.equal(V(s, c), CfgErr.FB_DI_CONFLICT);
  c.act[0].fb_di = 9;
  assert.equal(V(s, c), CfgErr.FB_DI_RANGE);
  c.act[0].fb_di = 4;
  s.dis[3].target_relay = 2;
  assert.equal(V(s, c), CfgErr.FB_DI_CONFLICT);
  s.dis[3].target_relay = 0;
  c.act[0].fb_timeout_s = 1;
  assert.equal(V(s, c), CfgErr.FB_TIMEOUT_RANGE);
  c.act[0].fb_timeout_s = 5;
  assert.equal(V(s, c), CfgErr.OK);
});

test('fw_safety_config: iki roleli vana kurallari ve diger sinirlar', () => {
  const s = sys8();
  let c = base();
  c.act[0].close_mode = CloseMode.PULSE_TWO_RELAY;
  c.act[0].relay2 = 0;
  assert.equal(V(s, c), CfgErr.PULSE_RELAY2);
  c.act[0].relay2 = 5;
  assert.equal(V(s, c), CfgErr.PULSE_RELAY2);
  c.act[0].relay2 = 6;
  assert.equal(V(s, c), CfgErr.ACT_RELAY_DUP);
  c.act[0].relay2 = 7;
  assert.equal(V(s, c), CfgErr.OK);
  s.relays[6].type = RelayType.SHUTTER_UP;
  assert.equal(V(s, c), CfgErr.ACT_RELAY_SHUTTER);
  s.relays[6].type = RelayType.LIGHT;
  c.act[0].run_limit_s = 121;
  assert.equal(V(s, c), CfgErr.PULSE_TIME);
  c = base(); c.pol.dry_hold_ms = 999; assert.equal(V(s, c), CfgErr.DRY_HOLD);
  c = base(); c.sens[0].zone = 5; assert.equal(V(s, c), CfgErr.SENSOR_ZONE);
  c = base(); c.sens[0].confirm_ms = 50; assert.equal(V(s, c), CfgErr.CONFIRM_RANGE);
  c = base(); c.act[0].zone_mask = 0; assert.equal(V(s, c), CfgErr.ACT_ZONE);
  c = base(); c.sens[0].kind = 9; assert.equal(V(s, c), CfgErr.SENSOR_KIND);
  c = base(); c.sens[0].name = 'a'.repeat(20); assert.equal(V(s, c), CfgErr.NAME);
  c = base(); c.nSens = 57; assert.equal(V(s, c), CfgErr.COUNT);
  c = base();
  c.sens[1] = sensor(4, SensorKind.ALARM_ACK, 0, 0);
  c.nSens = 2;
  assert.equal(V(s, c), CfgErr.OK);
  c.sens[1].src = SensorSrc.BRIDGE;
  c.sens[1].index = 2;
  assert.equal(V(s, c), CfgErr.SENSOR_SRC);
  assert.equal(cfgErrText(CfgErr.SENSOR_SRC), 'sensor_src');
});

test('fw_safety_config: kilitli bolgeye dokunan degisiklik reddi', () => {
  const a = base();
  let b = base();
  assert.equal(touchesLockedZones(a, b, 0x01), false);
  b.act[0].medium = Medium.GAS;
  assert.equal(touchesLockedZones(a, b, 0x01), true);
  assert.equal(touchesLockedZones(a, b, 0x02), false);
  b = base(); b.nAct = 1; b.act = b.act.slice(0, 1);
  assert.equal(touchesLockedZones(a, b, 0x01), true);
  b = base(); b.sens[0].zone = 2;
  assert.equal(touchesLockedZones(a, b, 0x01), true);
  assert.equal(touchesLockedZones(a, b, 0x02), true);
  b = base(); b.pol.policy_on = 0;
  assert.equal(touchesLockedZones(a, b, 0x01), false);
  b = base(); b.sens[1] = sensor(4, SensorKind.WATER, 2, 0); b.nSens = 2;
  assert.equal(touchesLockedZones(a, b, 0x01), false);
});

test('fw_safety_config: CRC32 bilinen vektor; blob gidis-donusu ve bozulma; yapilandirma CRC icerigi izler', () => {
  assert.equal(crc32('123456789'), 0xCBF43926);
  assert.equal(crc32(''), 0);
  const c = base();
  const blob = packBlob(c.sens.slice(0, c.nSens), encodeSensor);
  assert.equal(blob.length, 32);
  assert.equal(unpackBlobCount(blob, 28, 56), 1);
  blob[5] ^= 0x10;
  assert.equal(unpackBlobCount(blob, 28, 56), -1);
  assert.equal(unpackBlobCount(blob.subarray(0, 31), 28, 56), -1);
  const empty = packBlob([], encodeSensor);
  assert.equal(empty.length, 4);
  assert.equal(unpackBlobCount(empty, 28, 56), 0);
  const a = base();
  let b = base();
  assert.equal(configCrc(a), configCrc(b));
  b.sens[0].confirm_ms = 1200;
  assert.notEqual(configCrc(a), configCrc(b));
  b = base();
  b.sens[5] = makeSensorConfig({ kind: 7 });
  assert.equal(configCrc(a), configCrc(b));
  b.rev = 99;
  assert.equal(configCrc(a), configCrc(b));
});

test('fw_safety_config: kilit kaydi muhuru ve maskeleri', () => {
  const r = latchClear();
  assert.equal(latchAny(r), false);
  assert.equal(latchValid(r), true);
  r.z[0].st = 1;
  r.z[0].aid = '9f3a11c0-3';
  r.m.localAssert = 0x10;
  r.m.localLevel = 0x10;
  r.m.extAssert = 0x4;
  r.m.extLevel = 0;
  latchSeal(r);
  assert.equal(latchValid(r), true);
  assert.equal(latchAny(r), true);
  assert.equal(latchZoneMask(r), 0x01);
  assert.equal(latchAssert64(r), (1n << 4n) | (1n << 10n));
  assert.equal(latchLevel64(r), 1n << 4n);
  r.z[0].kinds = 3;
  assert.equal(latchValid(r), false);
  const q = latchClear();
  latchSetMasks(q, (1n << 4n) | (1n << 10n), 1n << 4n);
  assert.equal(q.m.localAssert, 0x10);
  assert.equal(q.m.extAssert, 0x4);
});

test('fw_safety_config: cokme dongusu sayaci', () => {
  const c = crashClear();
  crashOnBoot(c, false);
  assert.equal(crashLoop(c), false);
  crashOnBoot(c, true);
  crashOnBoot(c, true);
  assert.equal(crashLoop(c), false);
  crashOnBoot(c, true);
  assert.equal(crashLoop(c), true);
  assert.equal(crashStableTick(c, CRASH_STABLE_MS - 1), false);
  assert.equal(crashStableTick(c, CRASH_STABLE_MS), true);
  assert.equal(crashLoop(c), false);
  assert.equal(crashStableTick(c, CRASH_STABLE_MS + 5), false);
  for (let i = 0; i < 300; i++) crashOnBoot(c, true);
  assert.equal(c.count, 255);
});

test('fw_safety_config: acilis kipi karari', () => {
  const cfg = base();
  const crash = crashClear();
  let latch = latchClear();
  assert.equal(decideBootMode(true, true, latch, cfg, crash), SafeReason.NONE);
  assert.equal(decideBootMode(true, false, latch, cfg, crash), SafeReason.CFG_CORRUPT);
  assert.equal(decideBootMode(false, false, latch, cfg, crash), SafeReason.NONE);
  latch.z[0].st = 1;
  latchSetMasks(latch, 1n << 4n, 0n);
  latchSeal(latch);
  assert.equal(decideBootMode(true, true, latch, cfg, crash), SafeReason.NONE);
  assert.equal(decideBootMode(false, false, latch, defaultSafetyConfig(), crash), SafeReason.LATCH_ORPHAN);
  latchSetMasks(latch, 1n << 7n, 0n);
  latchSeal(latch);
  assert.equal(decideBootMode(true, true, latch, cfg, crash), SafeReason.LATCH_ORPHAN);
  latch = latchClear();
  for (let i = 0; i < 3; i++) crashOnBoot(crash, true);
  assert.equal(decideBootMode(true, true, latch, cfg, crash), SafeReason.CRASH_LOOP);
  assert.equal(safeReasonText(SafeReason.CRASH_LOOP), 'crash_loop');
  assert.equal(safeReasonText(SafeReason.LATCH_ORPHAN), 'latch_orphan');
  assert.equal(safeReasonText(SafeReason.CFG_CORRUPT), 'cfg_corrupt');
});

// pano-1 (Unity: test_boot_mode_sensor_only_latch_is_normal): yalniz sensorlu kurulumun (eylemci yok) kilidi hicbir role istemiyor -> acilis
// NORMAL kip; kilit tabloda olmayan roleyi istiyorsa LATCH_ORPHAN kalir.
test('fw_safety_config: role istemeyen kilit (yalniz sensorlu kurulum) acilista normal kip; gercek uyusmazlik latch_orphan (pano-1)', () => {
  const cfg = defaultSafetyConfig();
  cfg.sens = [sensor(3, SensorKind.GAS, 1, 1)];
  cfg.nSens = 1;
  const crash = crashClear();
  const latch = latchClear();
  latch.z[0].st = 1;
  latchSeal(latch);
  assert.equal(latchAssert64(latch), 0n);
  assert.equal(decideBootMode(true, true, latch, cfg, crash), SafeReason.NONE);
  assert.equal(decideBootMode(false, false, latch, defaultSafetyConfig(), crash), SafeReason.NONE);
  latchSetMasks(latch, 1n << 4n, 0n);
  latchSeal(latch);
  assert.equal(decideBootMode(true, true, latch, cfg, crash), SafeReason.LATCH_ORPHAN);
  assert.equal(latchCovered(0n, 0n), true);
  assert.equal(latchCovered(1n << 4n, (1n << 4n) | (1n << 5n)), true);
  assert.equal(latchCovered(1n << 4n, 0n), false);
  assert.equal(latchCovered((1n << 4n) | (1n << 20n), 1n << 4n), false);
});

// ---- Inceleme turu (entegrasyon) (Unity: test_safety_config) ----
test('fw_safety_config: NVS bos girdi butcesi (RV-3)', () => {
  assert.equal(nvsBlobEntries(20), 3);
  assert.equal(nvsBlobEntries(164), 8);
  const c = defaultSafetyConfig();
  const e0 = configNvsEntries(c);
  assert.equal(e0, 3 + 3 + 5 + 3 + 3 + 8);
  const b = base();
  assert.ok(configNvsEntries(b) > e0);
  const need = configNvsEntries(b) + NVS_SAFETY_RESERVE_ENTRIES + NVS_GC_PAGE_ENTRIES;
  assert.equal(nvsRoomForConfig(need, b), true);
  assert.equal(nvsRoomForConfig(need - 1, b), false);
});

// ---- Inceleme turu 2 (Unity: test_safety_config) ----
test('fw_safety_config: NVS payi cop toplama sayfasini (126 girdi) dusar (FW2-3)', () => {
  assert.equal(NVS_GC_PAGE_ENTRIES, 126);
  const c = base();
  const cfgE = configNvsEntries(c);
  assert.equal(nvsRoomForConfig(cfgE + NVS_SAFETY_RESERVE_ENTRIES, c), false);
  assert.equal(nvsRoomForConfig(cfgE + NVS_SAFETY_RESERVE_ENTRIES + 125, c), false);
  assert.equal(nvsRoomForConfig(cfgE + NVS_SAFETY_RESERVE_ENTRIES + 126, c), true);
});

test('fw_safety_config: ana yapilandirma degisimi acilis/kilit maskesindeki roleyi panjur/darbe yapamaz (FW2-1)', () => {
  const empty = defaultSafetyConfig();
  let s = sys8();
  const guard = (1n << 2n) | (1n << 4n);
  assert.equal(validateSystemChange(s, empty, guard), CfgErr.OK);
  s.relays[2].type = RelayType.IMPULSE;
  assert.equal(validate(s, empty), CfgErr.OK);
  assert.equal(validateSystemChange(s, empty, guard), CfgErr.ACT_RELAY_IMPULSE);
  s = sys8();
  s.relays[4].type = RelayType.SHUTTER_UP;
  s.relays[5].type = RelayType.SHUTTER_DOWN;
  assert.equal(validateSystemChange(s, empty, guard), CfgErr.ACT_RELAY_SHUTTER);
  s = sys8();
  s.relays[0].type = RelayType.IMPULSE;
  s.relays[6].type = RelayType.SHUTTER_UP;
  s.relays[7].type = RelayType.SHUTTER_DOWN;
  assert.equal(validateSystemChange(s, empty, guard), CfgErr.OK);
  assert.equal(validateSystemChange(s, empty, 1n), CfgErr.ACT_RELAY_IMPULSE);
  const c = base();
  s = sys8();
  s.relays[4].type = RelayType.IMPULSE;
  assert.equal(validateSystemChange(s, c, 0n), validate(s, c));
  assert.notEqual(validateSystemChange(s, c, 0n), CfgErr.OK);
});

test('fw_safety_config: acilis maskesi panjur/darbe ve olmayan roleye dokunmaz (EM-5)', () => {
  const s = sys8();
  s.relays[0].type = RelayType.SHUTTER_UP;
  s.relays[1].type = RelayType.SHUTTER_DOWN;
  s.relays[2].type = RelayType.IMPULSE;
  assert.equal(bootMaskForSystem(s, 0xFFn | (1n << 20n)), 0xF8n);
});

// Faz 2 (F2.B.1; Unity test_intrusion_policy_layout_and_roles): gecikmeler Policy bayt 8-9; fabrika blob'u v1.2.0 ile ayni; ARM_KEY yalniz DI.
test('fw_safety_config: hirsiz gecikme baytlari ve ARM_KEY rolu', () => {
  const c = defaultSafetyConfig();
  assert.equal(c.pol.exit_s, 0);
  assert.equal(c.pol.entry_s, 0);
  const raw = Buffer.alloc(16);
  raw[0] = 1;
  raw.writeUInt32LE(DRY_HOLD_DEFAULT_MS, 4);
  assert.deepEqual(encodePolicy(c.pol), raw);
  const p = encodePolicy({ ...c.pol, exit_s: 255, entry_s: 1 });
  assert.equal(p[8], 255);
  assert.equal(p[9], 1);
  const s = sys8();
  const k = base();
  k.sens.push(sensor(4, SensorKind.ARM_KEY, 0, 1), { ...sensor(7, SensorKind.DOOR, 2, 1), flags: SF_REACT | SF_ENTRY | SF_AWAY_ONLY });
  k.nSens = 3;
  k.pol.exit_s = 255;
  k.pol.entry_s = 1;
  assert.equal(validate(s, k), CfgErr.OK);
  // Faz 2 incelemesi RV-E3: anahtarli kontak yalniz NC (kablo kesilince kurulu okunur, alarm cozulmez)
  k.sens[1] = { ...k.sens[1], active_open: 0 };
  assert.equal(validate(s, k), CfgErr.ARM_KEY_NOT_NC);
  assert.equal(cfgErrText(CfgErr.ARM_KEY_NOT_NC), 'arm_key_not_nc');
  k.sens[1] = { ...k.sens[1], active_open: 1, src: SensorSrc.BRIDGE, index: 2 };
  assert.equal(validate(s, k), CfgErr.SENSOR_SRC);
});

// v1.3.2 (CONTRACTS C1, fw-tarama-1; Unity: test_bridge_sensor_rejected_on_write_paths_only): hub surucusu yok; yazim yollari (forWrite) kopru
// sensorunu reddeder, acilistaki kayitli yapilandirma gecerli kalir. Sira: koprude kumanda rolu sensor_src, aksi halde aralik/dup'tan ONCE.
test('fw_safety_config: kopru sensoru yalniz yazim yollarinda sensor_bridge_unsupported (C1)', () => {
  const s = sys8();
  let c = base();
  c.sens[1] = { ...sensor(4, SensorKind.WATER, 1, 0), src: SensorSrc.BRIDGE, index: 1 };
  c.nSens = 2;
  assert.equal(validate(s, c), CfgErr.OK, 'acilis: kayitli yapilandirma kullanilabilir');
  assert.equal(validate(s, c, false), CfgErr.OK);
  assert.equal(validate(s, c, true), CfgErr.SENSOR_BRIDGE_UNSUPPORTED);
  assert.equal(cfgErrText(CfgErr.SENSOR_BRIDGE_UNSUPPORTED), 'sensor_bridge_unsupported');
  c.sens[1].index = 0;
  assert.equal(validate(s, c, true), CfgErr.SENSOR_BRIDGE_UNSUPPORTED, 'aralik disi yuva: once desteklenmiyor');
  assert.equal(validate(s, c, false), CfgErr.SENSOR_BRIDGE_RANGE);
  c.sens[1] = { ...sensor(4, SensorKind.ALARM_ACK, 0, 0), src: SensorSrc.BRIDGE, index: 2 };
  assert.equal(validate(s, c, true), CfgErr.SENSOR_SRC, 'koprude kumanda rolu: sensor_src (degismez)');
  assert.equal(validate(s, c, false), CfgErr.SENSOR_SRC);
  c = base();
  assert.equal(validate(s, c, true), CfgErr.OK, 'DI yolu degismez');
  c.sens[1] = { ...sensor(4, SensorKind.GAS, 1, 1), src: SensorSrc.BRIDGE, index: 3 };
  c.nSens = 2;
  assert.equal(validateSystemChange(s, c, 0n), CfgErr.OK, 'ana yapilandirma degisimi kayitli kopru sensorunu yazmaz');
  assert.equal(validateSystemChange(s, c, 0n, true), CfgErr.SENSOR_BRIDGE_UNSUPPORTED);
});
