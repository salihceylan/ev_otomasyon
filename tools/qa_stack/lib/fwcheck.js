// Firmware kaynak SURUKLENMESI denetimi: simulator (sim/fw/*, sim/local_api.js) belirli firmware kaynak dosyalarindan PORTLANMISTIR.
// Bu dosya, portlanirken okunan her kaynagin SHA-256 ozetini (sim/fw/SOURCES.json; satir sonu normallestirilmis) tutar; `node run.js fwcheck`
// suanki dosyalari karsilastirir ve degisen dosyalari listeler (degisti = simulatoru yeniden esitle: ilgili modul + test/fw_*.test.js).
// `--update` ozetleri yeniler. test/fwcheck.test.js ozetlerin guncel oldugunu `npm test` icinde de denetler.
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { REPO_ROOT, ROOT } from './paths.js';

export const FIRMWARE_DIR = path.join(REPO_ROOT, 'ev_otomasyon_servis_yazilimi', 'waveshare_s3_demo');
export const MANIFEST = path.join(ROOT, 'sim', 'fw', 'SOURCES.json');

/** Her kaynak -> hangi simulator modulunu besledigi */
export const SOURCES = {
  'src/ShutterFsm.h': 'sim/fw/shutter_fsm.js',
  'src/DiGate.h': 'sim/fw/di_gate.js',
  'src/RelayRules.h': 'sim/fw/interlock_guard.js',
  'src/SystemConfig.h': 'sim/fw/sysconfig.js',
  'src/NetUtil.h': 'sim/fw/netutil.js',
  'src/NetTime.h': 'sim/fw/net_time.js (+ wifi_manager.js, mqtt_manager.js, local_api.js zamanlayicilari)',
  'src/ApAccess.h': 'sim/fw/ap_access.js (+ sim/local_api.js authorizeApOrKeyed)',
  'src/ConfigManager.cpp': 'sim/fw/config_manager.js',
  'src/ConfigManager.h': 'sim/fw/config_manager.js',
  'src/SmartAutomation.cpp': 'sim/fw/automation.js',
  'src/SmartAutomation.h': 'sim/fw/automation.js',
  'src/SmartAutomation_Rs485.cpp': 'sim/fw/automation.js (ek modul modeli)',
  'src/WS_TCA9554PWR.cpp': 'sim/fw/automation.js (TcaDriver)',
  'src/DeviceCommand.h': 'sim/fw/automation.js (komut tipleri)',
  'src/ModbusRtu.h': 'sim/fw/modbus.js',
  'src/MqttManager.cpp': 'sim/fw/mqtt_manager.js + sim/command_schema.js',
  'src/MqttManager.h': 'sim/fw/mqtt_manager.js',
  'src/WebPortal.cpp': 'sim/local_api.js',
  'src/WebPortal.h': 'sim/local_api.js',
  'src/WiFiManager.cpp': 'sim/fw/wifi_manager.js',
  'src/WiFiManager.h': 'sim/fw/wifi_manager.js',
  'test/test_shutter_fsm/test_main.cpp': 'test/fw_shutter_fsm.test.js',
  'test/test_di_gate/test_main.cpp': 'test/fw_di_gate.test.js',
  'test/test_relay_rules/test_main.cpp': 'test/fw_relay_rules.test.js',
  'test/test_system_config/test_main.cpp': 'test/fw_system_config.test.js',
  'test/test_modbus_rtu/test_main.cpp': 'test/fw_modbus.test.js',
  'test/test_ap_access/test_main.cpp': 'test/fw_ap_access.test.js',
  'test/test_net_time/test_main.cpp': 'test/fw_net_time.test.js',
  // Guvenlik katmani (WP-F1): saf cekirdekler ve Unity testleri
  'src/sensors/SensorTypes.h': 'sim/fw/sensor_hub.js',
  'src/sensors/SensorHub.h': 'sim/fw/sensor_hub.js',
  'src/sensors/DiSensor.h': 'sim/fw/sensor_hub.js (DiSensor)',
  'src/sensors/BridgeSensor.h': 'sim/fw/sensor_hub.js (BridgeSensor)',
  'src/actuators/ActuatorTypes.h': 'sim/fw/actuator_map.js',
  'src/actuators/ActuatorMap.h': 'sim/fw/actuator_map.js',
  'src/safety/SafetyConfig.h': 'sim/fw/safety_config.js',
  'src/safety/SafetyFsm.h': 'sim/fw/safety_fsm.js',
  'src/events/EventOutbox.h': 'sim/fw/event_outbox.js',
  'test/test_sensor_hub/test_main.cpp': 'test/fw_sensor_hub.test.js',
  'test/test_actuator_map/test_main.cpp': 'test/fw_actuator_map.test.js',
  'test/test_safety_config/test_main.cpp': 'test/fw_safety_config.test.js',
  'test/test_safety_fsm/test_main.cpp': 'test/fw_safety_fsm.test.js',
  'test/test_event_outbox/test_main.cpp': 'test/fw_event_outbox.test.js',
  // Guvenlik katmani (WP-F2): baglayicilar ve SmartAutomation kancalarinin donanim uclari
  'src/safety/SafetyManager.h': 'sim/fw/safety_manager.js',
  'src/safety/SafetyManager.cpp': 'sim/fw/safety_manager.js',
  'src/safety/SafetyStore.h': 'sim/fw/safety_manager.js (SafetyStore, NvsImage safety/latch)',
  'src/safety/SafetyStore.cpp': 'sim/fw/safety_manager.js (SafetyStore, NvsImage safety/latch)',
  'src/events/EventOutboxRtos.h': 'sim/fw/safety_manager.js (simulator tek is parcacigi: kilitsiz EventOutbox)',
  'src/WS_Relay.cpp': 'sim/fw/automation.js (TcaDriver.init: Relay_Init kilit maskesi)',
  'src/WS_GPIO.cpp': 'sim/fw/automation.js (beep: Buzzer_SetAlarm alarm kipi)',
  // Guvenlik katmani (WP-F3): bagimsiz emniyet (ValveGuard) ve TCA guvenli bit yardimcilari
  'src/safety/ValveGuard.h': 'sim/fw/valve_guard.js',
  'src/WS_TCA9554PWR.h': 'sim/fw/automation.js (TcaDriver.readOutputHw/setSafeBits)',
  'test/test_valve_guard/test_main.cpp': 'test/fw_valve_guard.test.js',
  // Guvenlik katmani (WP-F4/F5): durum gorunumu (state v:3), yapilandirma yamasi/JSON'u, LAN olay halkasi, ayristirici
  'src/safety/SafetyView.h': 'sim/fw/safety_view.js',
  'src/safety/SafetyCfgEdit.h': 'sim/fw/safety_cfg_edit.js',
  'src/safety/SafetyCfgJson.h': 'sim/fw/safety_cfg_edit.js (JSON / cfg_dump)',
  'src/safety/SafetyCfgApi.h': 'sim/fw/safety_cfg_api.js',
  'src/safety/SafetyCfgApi.cpp': 'sim/fw/safety_cfg_api.js',
  'test/test_safety_view/test_main.cpp': 'test/fw_safety_view.test.js',
  'test/test_safety_cfg_edit/test_main.cpp': 'test/fw_safety_cfg_edit.test.js',
  'test/test_event_log/test_main.cpp': 'test/fw_event_log.test.js',
};

/**
 * Bilincli PORTLANMAYAN firmware kaynaklari (izlenmez; nedenleri docs/QA_STACK.md 5.1):
 *  * src/WebPortalPage.h -- gomulu tarayici arayuzu (INDEX_HTML). Simulator `GET /` icin kisa bir bilgi sayfasi doner; gercek sayfayi SERVIS ETMEZ.
 *    Sayfanin API sozlesmesi (anahtarsiz /api/status + /api/wifi/status yoklamasi) simulatorun HTTP uclariyla dogrulanir (test/sim_http.test.js).
 */
export const NOT_PORTED = Object.freeze(['src/WebPortalPage.h']);

/**
 * Kaynak ozeti (SHA-256): CRLF -> LF normallestirilerek hesaplanir. Ana agac core.autocrlf=true ile calisir; ayni kaynak bir checkout'ta
 * CRLF, digerinde LF olabilir ve bu fark firmware degisikligi SAYILMAZ. Dosya yoksa null.
 */
export function sourceHash(file) {
  let buf;
  try { buf = fs.readFileSync(file); } catch (_) { return null; }
  return crypto.createHash('sha256').update(Buffer.from(buf.toString('latin1').replace(/\r\n/g, '\n'), 'latin1')).digest('hex');
}

export function currentHashes() {
  return Object.fromEntries(Object.keys(SOURCES).map((rel) => [rel, sourceHash(path.join(FIRMWARE_DIR, rel))]));
}

export function writeManifest() {
  const body = { note: 'Simulatorun portlandigi firmware kaynaklarinin SHA-256 ozetleri. Degisirse `node run.js fwcheck`.', recorded_at: new Date().toISOString(), firmware_dir: 'ev_otomasyon_servis_yazilimi/waveshare_s3_demo', files: currentHashes(), fw_version: readFwVersion() };
  fs.writeFileSync(MANIFEST, `${JSON.stringify(body, null, 2)}\n`);
  return body;
}

export function readFwVersion() {
  try {
    const m = /#define FW_VERSION "([^"]+)"/.exec(fs.readFileSync(path.join(FIRMWARE_DIR, 'src', 'WiFiManager.h'), 'utf8'));
    return m ? m[1] : null;
  } catch (_) { return null; }
}

/** @returns {{ok:boolean, changed:{file:string, feeds:string, state:'degisti'|'yok'|'yeni'}[], recorded_at?:string}} */
export function checkDrift() {
  let manifest = null;
  try { manifest = JSON.parse(fs.readFileSync(MANIFEST, 'utf8')); } catch (_) { /* yok */ }
  const now = currentHashes();
  const changed = [];
  for (const [rel, feeds] of Object.entries(SOURCES)) {
    const old = manifest && manifest.files ? manifest.files[rel] : undefined;
    if (now[rel] === null) changed.push({ file: rel, feeds, state: 'yok' });
    else if (old === undefined) changed.push({ file: rel, feeds, state: 'yeni' });
    else if (old !== now[rel]) changed.push({ file: rel, feeds, state: 'degisti' });
  }
  return { ok: changed.length === 0, changed, recorded_at: manifest && manifest.recorded_at, fw_version: manifest && manifest.fw_version };
}
