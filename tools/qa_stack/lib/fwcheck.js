// Firmware kaynak SURUKLENMESI denetimi: simulator (sim/fw/*, sim/local_api.js) belirli firmware kaynak dosyalarindan PORTLANMISTIR.
// Bu dosya, portlanirken okunan her kaynagin SHA-256 ozetini (sim/fw/SOURCES.json) tutar; `node run.js fwcheck` suanki dosyalari
// karsilastirir ve degisen dosyalari listeler (degisti = simulatoru yeniden esitle: ilgili modul + test/fw_*.test.js). `--update` ozetleri yeniler.
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
};

/**
 * Bilincli PORTLANMAYAN firmware kaynaklari (izlenmez; nedenleri docs/QA_STACK.md 5.1):
 *  * src/WebPortalPage.h -- gomulu tarayici arayuzu (INDEX_HTML). Simulator `GET /` icin kisa bir bilgi sayfasi doner; gercek sayfayi SERVIS ETMEZ.
 *    Sayfanin API sozlesmesi (anahtarsiz /api/status + /api/wifi/status yoklamasi) simulatorun HTTP uclariyla dogrulanir (test/sim_http.test.js).
 */
export const NOT_PORTED = Object.freeze(['src/WebPortalPage.h']);

const sha = (file) => {
  try { return crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex'); } catch (_) { return null; }
};

export function currentHashes() {
  return Object.fromEntries(Object.keys(SOURCES).map((rel) => [rel, sha(path.join(FIRMWARE_DIR, rel))]));
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
