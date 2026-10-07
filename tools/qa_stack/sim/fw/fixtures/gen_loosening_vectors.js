// Gevsetme (isLoosening) ORTAK TEST VEKTORLERI ureticisi (Faz 2 tasarimi F2.D.4).
//
// Faz 2 incelemesi (G-1): her vektor ayrica `gas_release` (isGasRelease: bulut yolu uygulayamaz, gas_local_only) ve
// `intrusion_loosening` (isIntrusionLoosening: kurulu kipte bulut yolu uygulayamaz, armed) beklenen sonuclarini tasir.
// Firmware `SafetyCfgEdit.h` isLoosening'in JS portu (../safety_cfg_edit.js) her vektorun beklenen sonucunu URETIR; sunucunun
// JSON portu (server/src/utils/safety_cfg_loosen.js) ayni dosyayi OKUYUP ayni sonucu vermek zorundadir (server/test/safety/
// safety_cfg_loosen.test.js). Yapilandirmalar panonun GET /api/safety/config / cfg_dump JSON bicimindedir (writeConfigJson).
//
// Kullanim:  node sim/fw/fixtures/gen_loosening_vectors.js          -> loosening_vectors.json'u yeniden yazar
//            buildVectors()                                           -> testler (test/fw_loosening_vectors.test.js) dosyayla karsilastirir
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { SensorKind, SensorSrc, SF_REACT, SF_TAMPER, SF_AWAY_ONLY, SF_ENTRY, defaultFlags, defaultConfirmMs, makeSensorConfig } from '../sensor_hub.js';
import { ActKind, CloseMode, Medium, AF_FAN_EXPROOF, makeActuatorConfig } from '../actuator_map.js';
import { defaultSafetyConfig } from '../safety_config.js';
import { isLoosening, isGasRelease, isIntrusionLoosening, diUseMask, writeConfigJson } from '../safety_cfg_edit.js';

const clone = (o) => JSON.parse(JSON.stringify(o));
const sensor = (di, kind, zone, nc = 0) =>
  makeSensorConfig({ src: SensorSrc.DI, index: di, kind, zone, active_open: nc, flags: defaultFlags(kind), confirm_ms: defaultConfirmMs(kind) });
const act = (o) => makeActuatorConfig({ fb_closed_active: 1, fb_timeout_s: 60, ...o });

function base() {
  const c = defaultSafetyConfig();
  c.sens = [
    sensor(3, SensorKind.WATER, 1),
    sensor(4, SensorKind.GAS, 2, 1),
    sensor(8, SensorKind.GAS_RESET, 2),
    sensor(9, SensorKind.DOOR, 1),
    makeSensorConfig({ src: SensorSrc.BRIDGE, index: 2, kind: SensorKind.SMOKE, zone: 3, active_open: 1, flags: defaultFlags(SensorKind.SMOKE), confirm_ms: 300 }),
  ];
  c.nSens = c.sens.length;
  c.act = [
    act({ relay: 5, kind: ActKind.VALVE, close_mode: CloseMode.DEENERGIZE_TO_CLOSE, medium: Medium.WATER, zone_mask: 1, fb_di: 6 }),
    act({ relay: 7, kind: ActKind.SIREN, zone_mask: 0b111, run_limit_s: 180 }),
    act({ relay: 9, kind: ActKind.VALVE, close_mode: CloseMode.ENERGIZE_TO_CLOSE, medium: Medium.GAS, zone_mask: 2 }),
    act({ relay: 11, kind: ActKind.FAN, zone_mask: 2 }),
    act({ relay: 13, relay2: 14, kind: ActKind.VALVE, close_mode: CloseMode.PULSE_TWO_RELAY, medium: Medium.WATER, zone_mask: 1, run_limit_s: 15 }),
  ];
  c.nAct = c.act.length;
  c.rev = 7;
  return c;
}

/** Her vektor: tabandan bir degisiklik (b), istege bagli a degisikligi ve kalici DI gecmisi. */
const CASES = [
  ['ayni yapilandirma', () => {}],
  ['politika kapatma', (b) => { b.pol.policy_on = 0; }],
  ['politika acma (a kapali)', (b) => { b.pol.policy_on = 1; }, (a) => { a.pol.policy_on = 0; }],
  ['kuruluk suresi kisaltma', (b) => { b.pol.dry_hold_ms = 5000; }],
  ['kuruluk suresi uzatma', (b) => { b.pol.dry_hold_ms = 20000; }],
  ['su sensoru silme', (b) => { b.sens.splice(0, 1); b.nSens--; }],
  ['yeni su sensoru ekleme', (b) => { b.sens.push(sensor(12, SensorKind.WATER, 2)); b.nSens++; }],
  ['su sensoru bolge degisimi', (b) => { b.sens[0].zone = 2; }],
  ['su sensoru tur degisimi (duman)', (b) => { b.sens[0].kind = SensorKind.SMOKE; }],
  ['SF_REACT kaldirma', (b) => { b.sens[0].flags &= ~SF_REACT; }],
  ['SF_TAMPER ekleme', (b) => { b.sens[0].flags |= SF_TAMPER; }],
  ['gaz SF_FAULT_CLOSE kaldirma', (b) => { b.sens[1].flags = SF_REACT; }],
  ['onay suresi uzatma', (b) => { b.sens[0].confirm_ms = 2000; }],
  ['onay suresi kisaltma', (b) => { b.sens[0].confirm_ms = 500; }],
  ['gaz NC -> NO', (b) => { b.sens[1].active_open = 0; }],
  ['su NO -> NC', (b) => { b.sens[0].active_open = 1; }],
  ['kopru duman sensoru silme', (b) => { b.sens.splice(4, 1); b.nSens--; }],
  ['kapi sensoru silme (tehlike degil)', (b) => { b.sens.splice(3, 1); b.nSens--; }],
  ['kapi kontagini gas_reset yapma', (b) => { b.sens[3].kind = SensorKind.GAS_RESET; b.sens[3].flags = 0; }],
  ['gas_reset bolge degisimi', (b) => { b.sens[2].zone = 1; }],
  ['hic kullanilmamis DI ye yeni gas_reset', (b) => { b.sens.push(sensor(20, SensorKind.GAS_RESET, 2)); b.nSens++; }],
  ['gecmiste kullanilmis DI ye yeni gas_reset', (b) => { b.sens.push(sensor(21, SensorKind.GAS_RESET, 2)); b.nSens++; }, null, 1n << 20n],
  ['vana geri bildirim DI sine yeni gas_reset (gecmis = mevcut kullanim)', (b) => { b.sens.push(sensor(6, SensorKind.GAS_RESET, 2)); b.nSens++; }, null, 'use'],
  ['su sensoru satirini gas_reset yapma', (b) => { b.sens[0].kind = SensorKind.GAS_RESET; }],
  ['siren silme (kimlik kaymasi)', (b) => { b.act.splice(1, 1); b.nAct--; }],
  ['yeni siren ekleme', (b) => { b.act.push(act({ relay: 15, kind: ActKind.SIREN, zone_mask: 1, run_limit_s: 180 })); b.nAct++; }],
  ['vana rolesi degisimi', (b) => { b.act[0].relay = 6; }],
  ['vana kapanma kipi degisimi', (b) => { b.act[0].close_mode = CloseMode.ENERGIZE_TO_CLOSE; }],
  ['vana akiskani degisimi', (b) => { b.act[0].medium = Medium.GAS; }],
  ['vanadan bolge cikarma', (b) => { b.act[0].zone_mask = 0; }],
  ['vanaya bolge ekleme', (b) => { b.act[0].zone_mask = 0b11; }],
  ['geri bildirimi kaldirma', (b) => { b.act[0].fb_di = 0; }],
  ['geri bildirim zaman asimini uzatma', (b) => { b.act[0].fb_timeout_s = 120; }],
  ['geri bildirim zaman asimini kisaltma', (b) => { b.act[0].fb_timeout_s = 30; }],
  ['geri bildirim polaritesi degisimi', (b) => { b.act[0].fb_closed_active = 0; }],
  ['siren suresini kisaltma', (b) => { b.act[1].run_limit_s = 60; }],
  ['siren suresini uzatma', (b) => { b.act[1].run_limit_s = 600; }],
  ['fani ex-proof isaretleme', (b) => { b.act[3].aflags |= AF_FAN_EXPROOF; }],
  ['fanin ex-proof isaretini kaldirma', (b) => { b.act[3].aflags = 0; }, (a) => { a.act[3].aflags = AF_FAN_EXPROOF; }],
  ['yeni ex-proof fan', (b) => { b.act.push(act({ relay: 16, kind: ActKind.FAN, zone_mask: 2, aflags: AF_FAN_EXPROOF })); b.nAct++; }],
  ['yeni normal fan', (b) => { b.act.push(act({ relay: 16, kind: ActKind.FAN, zone_mask: 2 })); b.nAct++; }],
  ['iki roleli vananin acma rolesi degisimi', (b) => { b.act[4].relay2 = 15; }],
  ['iki roleli vananin darbe suresi', (b) => { b.act[4].run_limit_s = 30; }],
  ['ad degisimi (sensor + eylemci)', (b) => { b.sens[0].name = 'Mutfak'; b.act[0].name = 'Ana vana'; }],
  // Faz 2 (F2.B.3) ARM_KEY: gas_reset'in DI gecmisi kurali; bolge anlamsiz (birlestirme hizalamasi, firmware 1.2.1)
  ['kapi kontagini arm_key yapma', (b) => { b.sens[3].kind = SensorKind.ARM_KEY; b.sens[3].zone = 0; b.sens[3].flags = SF_REACT; }],
  ['hic kullanilmamis DI ye yeni arm_key', (b) => { b.sens.push(sensor(22, SensorKind.ARM_KEY, 0)); b.nSens++; }],
  ['gecmiste kullanilmis DI ye yeni arm_key', (b) => { b.sens.push(sensor(23, SensorKind.ARM_KEY, 0)); b.nSens++; }, null, 1n << 22n],
  ['arm_key bolge degisimi (anlamsiz, gevsetme degil)', (b) => { b.sens[5].zone = 2; }, (a) => { a.sens.push(sensor(24, SensorKind.ARM_KEY, 0)); a.nSens++; }],
  ['arm_key satirini kapi kontagi yapma', (b) => { b.sens[5].kind = SensorKind.DOOR; b.sens[5].zone = 1; }, (a) => { a.sens.push(sensor(24, SensorKind.ARM_KEY, 0)); a.nSens++; }],
  ['kapi giris yolu / yalniz disarida bayraklari', (b) => { b.sens[3].flags = SF_REACT | SF_AWAY_ONLY; }],
  ['hirsiz gecikmelerini degistirme', (b) => { b.pol.exit_s = 10; b.pol.entry_s = 5; }],
  // Faz 2 incelemesi G-1a: gaz vanasini uzaktan acilabilir kilan degisiklikler (bulut yolu da uygulayamaz)
  ['gaz vanasini suya cevirme', (b) => { b.act[2].medium = Medium.WATER; }],
  ['gaz vanasini silme', (b) => { b.act.splice(2, 1); b.nAct--; }],
  ['gaz vanasini generic yapma', (b) => { b.act[2].kind = ActKind.GENERIC; b.act[2].medium = Medium.NONE; }],
  ['gaz vanasi kapanma kipini ters cevirme', (b) => { b.act[2].close_mode = CloseMode.DEENERGIZE_TO_CLOSE; }],
  ['gaz vanasi bolge daraltma (acmaz)', (b) => { b.act[2].zone_mask = 0; }],
  ['onundeki siren silinince gaz vanasi kayar (kimlik ayni)', (b) => { b.act.splice(1, 1); b.nAct--; }],
  ['gaz sensoru silme (vanayi acmaz)', (b) => { b.sens.splice(1, 1); b.nSens--; }],
  // Faz 2 incelemesi G-1b: hirsiz alarmini zayiflatan degisiklikler (kurulu kipte bulut yolu uygulayamaz)
  ['kapi alarm disi (flags 0)', (b) => { b.sens[3].flags = 0; }],
  ['kapi onay suresi uzatma', (b) => { b.sens[3].confirm_ms = 500; }],
  ['kapi hirsiz disi tur (su)', (b) => { b.sens[3].kind = SensorKind.WATER; b.sens[3].flags = SF_REACT; }],
  ['giris gecikmesini uzatma', (b) => { b.pol.entry_s = 90; }],
  ['cikis gecikmesini uzatma', (b) => { b.pol.exit_s = 120; }],
  ['giris gecikmesini kisaltma', (b) => { b.pol.entry_s = 5; }],
  ['pencere NC -> NO', (b) => { b.sens[5].active_open = 0; }, (a) => { a.sens.push(sensor(25, SensorKind.WINDOW, 1, 1)); a.nSens++; }],
  ['pencere anliktan giris yoluna', (b) => { b.sens[5].flags |= SF_ENTRY; }, (a) => { a.sens.push(sensor(25, SensorKind.WINDOW, 1, 1)); a.nSens++; }],
  ['hareket evde de etkin (sikilastirma)', (b) => { b.sens[5].flags = SF_REACT; }, (a) => { a.sens.push(sensor(26, SensorKind.MOTION, 2)); a.nSens++; }],
  ['yeni pencere sensoru', (b) => { b.sens.push(sensor(27, SensorKind.WINDOW, 1, 1)); b.nSens++; }],
];

export function buildVectors() {
  return CASES.map(([name, mutB, mutA = null, hist = 0n]) => {
    const a = base();
    if (mutA) mutA(a);
    const b = clone(a);
    mutB(b);
    const diHist = hist === 'use' ? diUseMask(a) : BigInt(hist);
    return {
      name,
      di_hist: diHist.toString(),
      expected: isLoosening(a, b, diHist),
      gas_release: isGasRelease(a, b, diHist),
      intrusion_loosening: isIntrusionLoosening(a, b, diHist),
      a: JSON.parse(writeConfigJson(a)),
      b: JSON.parse(writeConfigJson(b)),
    };
  });
}

export const FIXTURE = path.join(path.dirname(fileURLToPath(import.meta.url)), 'loosening_vectors.json');

export function renderFixture() {
  return `${JSON.stringify({ note: 'gen_loosening_vectors.js ile uretilir; elle duzenlemeyin', vectors: buildVectors() }, null, 1)}\n`;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  fs.writeFileSync(FIXTURE, renderFixture());
  const v = buildVectors();
  console.log(`${v.length} vektor yazildi (${v.filter((x) => x.expected).length} gevsetme)`);
}
