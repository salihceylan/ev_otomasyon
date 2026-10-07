// WP-F2: SmartAutomation guvenlik kancalarinin (sim/fw/automation.js portu) davranisi: sensor -> cekirdek -> role ayni turda;
// ham komut yon kurali; acilista kilit maskesi (Relay_Init); fabrika sifirlamasindan kilidin sag cikmasi (guvenli kip);
// planli yeniden baslatmada guvenli bitin korunmasi; toplu "lambalari kapat"tan muafiyet; duvar butonu -> ACTUATOR_SET;
// sensor DI'sinin duvar butonu kararina girmemesi.
import test from 'node:test';
import assert from 'node:assert/strict';
import { Rig, CmdType, CmdSource, makeCommand, NvsImage, makeExt } from './_rig.js';
import { DIMode, RelayType } from '../sim/fw/sysconfig.js';
import { SafetyStore, SafetyCmdType } from '../sim/fw/safety_manager.js';
import { defaultSafetyConfig, SAFETY_SCHEMA_VER, validateSystemChange, CfgErr } from '../sim/fw/safety_config.js';
import { SensorKind, SensorSrc, defaultFlags, defaultConfirmMs, makeSensorConfig } from '../sim/fw/sensor_hub.js';
import { ActKind, CloseMode, Medium, makeActuatorConfig } from '../sim/fw/actuator_map.js';
import { ZoneSt } from '../sim/fw/safety_fsm.js';
import { EditOp, editInit } from '../sim/fw/safety_cfg_edit.js';
import { VIA_CLI, VIA_LAN } from '../sim/fw/event_outbox.js';

function boardConfig(cm) {
  const c = cm.config;
  for (let i = 0; i < 8; i++) { c.relays[i].type = RelayType.LIGHT; c.dis[i].target_relay = 0; c.dis[i].mode = DIMode.TOGGLE; }
  c.dis[0].target_relay = 5;                 // DI 1: duvar butonu -> role 5 (vana)
  c.dis[1].target_relay = 7;                 // DI 2: duvar butonu -> role 7 (lamba)
  c.validate();
  cm.save();
}

function safetyNvs(mode = CloseMode.ENERGIZE_TO_CLOSE) {
  const nvs = new NvsImage(null);
  const cfg = defaultSafetyConfig();
  cfg.sens = [makeSensorConfig({ src: SensorSrc.DI, index: 3, kind: SensorKind.WATER, zone: 1, flags: defaultFlags(SensorKind.WATER), confirm_ms: defaultConfirmMs(SensorKind.WATER) })];
  cfg.nSens = 1;
  cfg.act = [
    makeActuatorConfig({ relay: 5, kind: ActKind.VALVE, close_mode: mode, medium: Medium.WATER, zone_mask: 1, fb_timeout_s: 60 }),
    makeActuatorConfig({ relay: 6, kind: ActKind.SIREN, zone_mask: 1, run_limit_s: 180 }),
  ];
  cfg.nAct = 2;
  SafetyStore.saveConfig(nvs, cfg);
  return nvs;
}

const rig = (nvs) => new Rig({ nvs, ext: makeExt(0), configure: boardConfig, automation: { safetyNonce: 0xabc } });
const zone1 = (r) => r.a.safety.core.zoneState(1);

test('sim_safety_hooks: islak sensor -> vana ayni dongude kapanir, siren calar; buzzer alarm kipi komut biplerini yutar', () => {
  const r = rig(safetyNvs());
  assert.equal(r.a.safety.active(), true);
  assert.equal(r.relay(5), false);           // E2C, konum bilinmiyor = acik kabul (enerjisiz)
  r.a.setRawDi(2, true);
  r.run(1300);
  assert.equal(zone1(r), ZoneSt.LATCHED);
  assert.equal(r.relay(5), true);            // E2C: kapali = enerjili
  assert.equal(r.relay(6), true);
  assert.equal(r.a.buzzerAlarm, true);
  const before = r.beeps.length;
  r.cmd(CmdType.RELAY_SET, 7, 1);
  r.run(50);
  assert.equal(r.relay(7), true);
  assert.equal(r.beeps.length, before, 'alarm kipinde komut bipi yok');
  assert.deepEqual(r.violations, []);
});

test('sim_safety_hooks: ham komut yon kurali (acma reddedilir, kapatma kabul); toplu lamba kapatma eylemciye dokunmaz', () => {
  const r = rig(safetyNvs(CloseMode.DEENERGIZE_TO_CLOSE));
  r.run(100);
  assert.equal(r.relay(5), true);            // D2C acik = enerjili (bilinmiyor = acik)
  r.cmd(CmdType.ALL_LIGHTS_OFF);
  r.cmd(CmdType.RELAY_SET, 7, 1);
  r.run(50);
  assert.equal(r.relay(5), true, 'vana lamba degildir');
  r.cmd(CmdType.RELAY_SET, 5, 0, 'kapat');   // D2C: 0 = KAPAT (guvenli yon)
  r.run(50);
  assert.equal(r.relay(5), false);
  assert.equal(r.snap.lastId, 'kapat');
  r.cmd(CmdType.RELAY_SET, 5, 1, 'ac');      // ham ACMA: reddedilir
  r.run(50);
  assert.equal(r.relay(5), false);
  assert.ok(r.events.some((e) => e.type === 'cmd_rejected' && e.reason === 'actuator_relay'));
  assert.equal(r.a.safety.lastReject().code, 'actuator_relay');
  r.cmd(SafetyCmdType.ACTUATOR_SET, 1, 1, 'ac2');   // ACTUATOR_SET ile acma: izin denetimi gecer (bolge normal, sensor kuru)
  r.run(50);
  assert.equal(r.relay(5), true);
});

test('sim_safety_hooks: kilitliyken elektrik kesintisi: Relay_Init kilit maskesiyle baslar, vana hic acilmaz', () => {
  const nvs = safetyNvs();
  const r = rig(nvs);
  r.a.setRawDi(2, true);
  r.run(1300);
  assert.equal(r.relay(5), true);
  const aid = r.a.safety.core.zone(1).aid;
  r.a.setRawDi(2, false);
  r.coldBoot();
  assert.equal(r.a.tca.latch & 0x10, 0x10, 'Relay_Init ilk yazimda guvenli bit (role 5) enerjili');
  r.run(600);
  assert.equal(zone1(r), ZoneSt.LATCHED);
  assert.equal(r.a.safety.core.zone(1).aid, aid);
  assert.equal(r.relay(5), true);
});

test('sim_safety_hooks: kilitliyken fabrika sifirlamasi: kilit sag cikar, guvenli kip (latch_orphan), ham acma reddedilir', () => {
  const nvs = safetyNvs();
  const r = rig(nvs);
  r.a.setRawDi(2, true);
  r.run(1300);
  r.a.setRawDi(2, false);
  r.cm.resetToDefaults();
  assert.equal(nvs.get('safety'), null, 'guvenlik yapilandirmasi silindi');
  assert.ok(nvs.get('latch').latch, 'kilit kaydi kaldi');
  r.coldBoot();
  r.run(600);
  assert.equal(r.a.safety.core.safeMode(), true);
  assert.equal(r.a.safety.mode, 'latch_orphan');
  assert.equal(r.relay(5), true, 'kilit maskesi yapilandirmasiz uygulanir');
  r.cmd(CmdType.RELAY_SET, 5, 0);
  r.run(50);
  assert.equal(r.relay(5), true);
});

test('sim_safety_hooks: planli yeniden baslatma (emergencyAllOff) kilitli vananin guvenli bitini korur, lambalari kapatir', () => {
  const r = rig(safetyNvs());
  r.cmd(CmdType.RELAY_SET, 7, 1);
  r.a.setRawDi(2, true);
  r.run(1300);
  assert.equal(r.relay(7), true);
  r.a.requestRestart(200, r.t);
  r.run(400);
  assert.equal(r.restarts, 1);
  assert.equal(r.a.tca.outputShadow() & 0x10, 0x10, 'E2C vana enerjili kaldi');
  assert.equal(r.a.tca.outputShadow() & 0x40, 0, 'lamba kapandi');
});

test('sim_safety_hooks: duvar butonu eylemci rolesine esliyse ACTUATOR_SET; sensor DI duvar butonu kararina girmez', () => {
  const r = rig(safetyNvs(CloseMode.DEENERGIZE_TO_CLOSE));
  r.run(100);
  assert.equal(r.relay(5), true);
  r.press(1);                                // TOGGLE: acik -> kapat
  assert.equal(r.relay(5), false);
  r.press(1);                                // kapali -> ac (izin var)
  assert.equal(r.relay(5), true);
  assert.ok(r.events.some((e) => e.type === 'di_press' && e.actuator === 1));
  const n = r.eventsOf('di_press').length;
  r.press(3, 150);                           // DI 3 = su sensoru: duvar butonu olayi yok
  assert.equal(r.eventsOf('di_press').length, n);
  // kilitliyken duvar butonu vanayi ACAMAZ
  r.a.setRawDi(2, true);
  r.run(1300);
  assert.equal(r.relay(5), false);
  r.press(1);
  assert.equal(r.relay(5), false);
  assert.equal(r.a.safety.lastReject().code, 'zone_latched');
});

// ---- Inceleme turu (entegrasyon) ----

test('sim_safety_hooks: kilitsiz KAPALI E2C vana yeniden baslatma ve acilista enerjili kalir (EM-1)', () => {
  const nvs = safetyNvs();
  const r = rig(nvs);
  r.run(100);
  assert.equal(r.relay(5), false);           // E2C, bilinmiyor = acik
  r.cmd(SafetyCmdType.ACTUATOR_SET, 1, 0, 'kapat');
  r.run(100);
  assert.equal(r.relay(5), true);            // kullanici kapatti (kilit yok)
  assert.equal(r.a.safety.shutdownKeepLocal() & 0x10, 0x10);
  r.a.requestRestart(200, r.t);
  r.run(400);
  assert.equal(r.restarts, 1);
  assert.equal(r.a.tca.outputShadow() & 0x10, 0x10, 'planli yeniden baslatmada kapali vana enerjili kaldi');
  r.coldBoot();
  assert.equal(r.a.tca.latch & 0x10, 0x10, 'Relay_Init ilk yazimda acilis guvenli maskesiyle (kilit yok)');
  r.run(600);
  assert.equal(r.relay(5), true);
});

test('sim_safety_hooks: yapilandirma bozulursa son gecerli acilis guvenli maskesi guvenli kipte dayatilir (EM-5)', () => {
  const nvs = safetyNvs();
  const r = rig(nvs);
  r.cmd(SafetyCmdType.ACTUATOR_SET, 1, 0, 'kapat');
  r.run(100);
  assert.equal(r.relay(5), true);
  const sc = nvs.get('safety');
  nvs.put('safety', { ...sc, crc: (sc.crc ^ 1) >>> 0 });   // CRC bozuldu
  r.coldBoot();
  r.run(600);
  assert.equal(r.a.safety.mode, 'cfg_corrupt');
  assert.equal(r.relay(5), true, 'kilit kaydi yokken de kapali vana kapali kalir');
  r.cmd(CmdType.RELAY_SET, 5, 0, 'ac');
  r.run(50);
  assert.equal(r.relay(5), true, 'ham acma reddedilir');
  assert.ok(nvs.get('latch').safe_msk, 'bozuk yapilandirma maskeyi silmez');
});

test('sim_safety_hooks: yapilandirma yazimi yarida kalirsa eski yapilandirma geri yazilir (RV-4)', () => {
  const nvs = safetyNvs();
  const r = rig(nvs);
  r.run(50);
  const rev0 = nvs.get('safety').cfg.rev;
  nvs.failKeys = new Set(['safety_mid']);
  const e = { ...editInit(), op: EditOp.SET_ZONE, zoneId: 1, zoneName: 'Mutfak' };
  const o = r.a.safety.submitEdit(e, false, 0, VIA_CLI, r.cm.config, { inLoop: true, curLevels: 0n, nowMs: r.t });
  assert.equal(o.r, 'storage');
  assert.equal(nvs.get('safety').ver, SAFETY_SCHEMA_VER, 'eski yapilandirma geri yazildi (gecerli)');
  assert.equal(nvs.get('safety').cfg.rev, rev0);
  assert.equal(nvs.get('safety').cfg.zones[0].name, defaultSafetyConfig().zones[0].name);
  const o2 = r.a.safety.submitEdit(e, false, 0, VIA_CLI, r.cm.config, { inLoop: true, curLevels: 0n, nowMs: r.t });
  assert.equal(o2.r, 'ok');
  assert.equal(nvs.get('safety').cfg.rev, rev0 + 1);
});

// ---- Inceleme turu 2 ----

test('sim_safety_hooks: cfg_corrupt guvenli kipinde acilis maskesindeki role darbe/panjur yapilamaz; eskiden kalan bit maskeden dusulur (FW2-1)', () => {
  const nvs = safetyNvs();
  const r = rig(nvs);
  r.cmd(SafetyCmdType.ACTUATOR_SET, 1, 0, 'kapat');
  r.run(100);
  assert.equal(r.relay(5), true);
  const sc = nvs.get('safety');
  nvs.put('safety', { ...sc, crc: (sc.crc ^ 1) >>> 0 });   // CRC bozuldu
  r.coldBoot();
  r.run(600);
  assert.equal(r.a.safety.mode, 'cfg_corrupt');
  assert.equal(r.a.safety.copyConfig().nAct, 0, 'guvenli kipte tablo bos');
  const guard = r.a.safety.relayGuard();
  assert.equal(guard & 0x10n, 0x10n, 'koruma maskesi role 5 i icerir');
  const next = r.cm.config.clone();
  next.relays[4].type = RelayType.IMPULSE;
  assert.equal(validateSystemChange(next, r.a.safety.copyConfig(), guard), CfgErr.ACT_RELAY_IMPULSE, '/api/config ve CLI yolu reddeder');
  // Eski surumden/dogrulamasiz yoldan kalmis durum: ana yapilandirmada role 5 artik darbe rolesi. Acilista bit kalici maskeden dusulur,
  // bir sonraki Relay_Init onu enerjilemez.
  r.cm.config.relays[4].type = RelayType.IMPULSE;
  r.cm.save();
  r.coldBoot();
  r.run(600);
  assert.equal(BigInt(nvs.get('latch').safe_msk.assert) & 0x10n, 0n, 'kalici maskeden dusuldu');
  r.coldBoot();
  assert.equal(r.a.tca.latch & 0x10, 0, 'Relay_Init darbe rolesini enerjilemez');
});

test('sim_safety_hooks: LAN dan sil + yeniden ekle ile kullanilmis DI ye GAS_RESET eklenemez; gecmis yeniden baslatmada kalir (FW2-2)', () => {
  const nvs = safetyNvs();
  const r = rig(nvs);
  r.run(50);
  const sens = (di, kind, zone = 1) => makeSensorConfig({ src: SensorSrc.DI, index: di, kind, zone, flags: defaultFlags(kind), confirm_ms: defaultConfirmMs(kind) });
  const submit = (e) => r.a.safety.submitEdit({ ...editInit(), ...e }, false, 0, VIA_LAN, r.cm.config, { inLoop: true, curLevels: 0n, nowMs: r.t }).r;
  assert.equal(submit({ op: EditOp.SET_SENSOR, sens: sens(4, SensorKind.DOOR) }), 'ok');
  assert.equal(submit({ op: EditOp.DEL_SENSOR, sens: sens(4, SensorKind.DOOR) }), 'ok', 'kapi satirini silmek tek basina gevsetme degil');
  assert.equal(submit({ op: EditOp.SET_SENSOR, sens: sens(4, SensorKind.GAS_RESET) }), 'loosen', 'ayni DI ye yeni GAS_RESET');
  r.coldBoot();
  r.run(50);
  assert.equal(submit({ op: EditOp.SET_SENSOR, sens: sens(4, SensorKind.GAS_RESET) }), 'loosen', 'gecmis kalici (ahbu_latch/di_hist)');
  assert.equal(submit({ op: EditOp.SET_SENSOR, sens: sens(5, SensorKind.GAS_RESET) }), 'ok', 'hic kullanilmamis DI ye GAS_RESET (sihirbaz)');
  // GAS_RESET'in bolgesini sil + yeniden ekle ile degistirmek de reddedilir
  assert.equal(submit({ op: EditOp.DEL_SENSOR, sens: sens(5, SensorKind.GAS_RESET) }), 'ok');
  assert.equal(submit({ op: EditOp.SET_SENSOR, sens: sens(5, SensorKind.GAS_RESET, 0) }), 'loosen');
  // seri CLI (fiziksel erisim) gevsetme yasagina tabi degil
  const cli = r.a.safety.submitEdit({ ...editInit(), op: EditOp.SET_SENSOR, sens: sens(4, SensorKind.GAS_RESET) }, false, 0, VIA_CLI, r.cm.config, { inLoop: true, curLevels: 0n, nowMs: r.t });
  assert.equal(cli.r, 'ok');
});

// Faz 2 incelemesi RG-3: hirsiz deseni (cikis/giris bip'i, alarm) surerken komut bipleri FIFO'da birikmez; yutulur (firmware Buzzer_Open_Time,
// tehlike alarm kipindeki gibi). Desen bitince birikmis bip seli calmaz.
test('sim_safety_hooks: hirsiz deseni surerken komut bipleri yutulur (RG-3)', () => {
  const nvs = new NvsImage(null);
  const cfg = defaultSafetyConfig();
  cfg.sens = [makeSensorConfig({ src: SensorSrc.DI, index: 3, kind: SensorKind.DOOR, zone: 1, active_open: 1, flags: defaultFlags(SensorKind.DOOR), confirm_ms: 0 })];
  cfg.nSens = 1;
  cfg.act = [makeActuatorConfig({ relay: 6, kind: ActKind.SIREN, zone_mask: 1, run_limit_s: 30 })];
  cfg.nAct = 1;
  cfg.pol.exit_s = 5;
  SafetyStore.saveConfig(nvs, cfg);
  const r = rig(nvs);
  r.a.setRawDi(2, true);                     // NC kapi kapali
  r.run(300);
  r.a.post(makeCommand(CmdType.SAFETY_ARM, CmdSource.MQTT, 0, 1));
  r.run(100);
  assert.equal(r.a.safety.buzzerPattern(), 1, 'cikis deseni');
  const before = r.beeps.length;
  r.cmd(CmdType.RELAY_SET, 7, 1);
  r.run(50);
  assert.equal(r.relay(7), true);
  assert.equal(r.beeps.length, before, 'cikis deseni surerken komut bipi yok');
  r.run(5200);
  assert.equal(r.a.safety.buzzerPattern(), 0, 'bekci: desen yok');
  r.cmd(CmdType.RELAY_SET, 7, 0);
  r.run(50);
  assert.ok(r.beeps.length > before, 'desen yokken komut bipi calar');
});
