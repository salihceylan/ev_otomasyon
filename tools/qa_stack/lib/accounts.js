// .runtime/accounts.json: QA hesaplari, PIN'ler, UID'ler (repoya YAZILMAZ). Q1'de cihaz bolumu uretilir;
// kullanici/ev/servis PIN bolumleri tohumlama (seed.js) ile eklenir.
import fs from 'node:fs';
import { HOME_WIFI_SSID, PORTS } from './config.js';
import { randomPin6, randomToken, readJson, writeJsonAtomic } from './util.js';
import { macFromUid } from '../sim/device_sim.js';

/**
 * Cihaz plani. Port sirasi PORTS.sims ile eslesir (8081, 8082, 8083).
 *  new1   : IN_STOCK, provizyonsuz simulator (8081) -> servis kurulum sihirbazi / cihaz AP simulasyonu
 *  home1  : sahip 1'in evine ait hazir cihaz (8082) -> LAN (dogrudan) mod, MQTT
 *  stock2 : IN_STOCK, 16 role, provizyonsuz simulator (8083; yalniz `up --devices 3`) -> ikinci kurulum / pano degisimi
 *  own2   : sahip 2'nin cihazi (simulatoru YOK) -> IDOR denemeleri
 */
export const DEVICE_PLAN = [
  { key: 'new1', uid: 'AHBU-S3-0A0001', relays: 8, sim: true, portIndex: 0, final: 'IN_STOCK', provisioned: false, purpose: 'Envanterde (IN_STOCK), provizyonsuz simulator: servis kurulum sihirbazi' },
  { key: 'home1', uid: 'AHBU-S3-0A0002', relays: 8, sim: true, portIndex: 1, final: 'CLAIMED', provisioned: true, purpose: 'Sahip 1 evinde hazir cihaz: LAN (dogrudan) mod + MQTT' },
  { key: 'stock2', uid: 'AHBU-S3-0A0003', relays: 16, sim: true, portIndex: 2, final: 'IN_STOCK', provisioned: false, purpose: 'Envanterde (IN_STOCK), 16 role provizyonsuz simulator (up --devices 3)' },
  { key: 'own2', uid: 'AHBU-S3-0A0004', relays: 8, sim: false, portIndex: null, final: 'CLAIMED', provisioned: true, purpose: 'Sahip 2 evinde (simulatoru yok): IDOR denemeleri' },
];

export function readAccounts(rt) {
  return readJson(rt.accountsFile, null);
}

export function writeAccounts(rt, data) {
  writeJsonAtomic(rt.accountsFile, data, { mode: 0o600 });
}

/** writeJsonAtomic ile ayni bicim ( JSON 2 bosluk + son satir sonu ): karsilastirma ve yazim ayni metni kullanir. */
export const serializeAccounts = (data) => `${JSON.stringify(data, null, 2)}\n`;

/**
 * Icerik degismediyse dosyaya DOKUNMAZ (mtime de ayni kalir): tekrarlanan `up`/`seed` accounts.json'u
 * degistirmemelidir. @returns {boolean} yazildiysa true
 */
export function writeAccountsIfChanged(rt, data) {
  let current = null;
  try { current = fs.readFileSync(rt.accountsFile, 'utf8'); } catch (_) { /* dosya yok: yazilacak */ }
  if (current === serializeAccounts(data)) return false;
  writeAccounts(rt, data);
  return true;
}

/** Mevcut dosyayi korur; eksik cihaz/Wi-Fi alanlarini uretir. */
export function ensureDeviceAccounts(rt, { devices = 2 } = {}) {
  const acc = readAccounts(rt) || {};
  acc.generated_at ||= new Date().toISOString();
  acc.note = 'QA verisi: repoya YAZILMAZ (tools/qa_stack/.runtime gitignore\'ludur). Parolalar yalnizca yerel makinede gecerlidir.';
  acc.wifi ||= { ssid: HOME_WIFI_SSID, password: randomToken(12) };
  acc.devices ||= {};
  const simKeys = DEVICE_PLAN.filter((d) => d.sim).slice(0, devices).map((d) => d.key);
  for (const d of DEVICE_PLAN) {
    const cur = acc.devices[d.key] || {};
    const hasSim = simKeys.includes(d.key);
    acc.devices[d.key] = {
      uid: d.uid,
      mac: macFromUid(d.uid),
      setup_pin: cur.setup_pin || randomPin6(),
      relays: d.relays,
      expected_final_status: d.final,
      purpose: d.purpose,
      has_simulator: hasSim,
      http_port: hasSim ? PORTS.sims[d.portIndex] : null,
      emulator_url: hasSim ? `http://10.0.2.2:${PORTS.sims[d.portIndex]}` : null,
      local_url: hasSim ? `http://127.0.0.1:${PORTS.sims[d.portIndex]}` : null,
      // yalniz hazir cihaz simulatoru "provizyonlu" baslar; anahtar tohumlamada sunucununkiyle degistirilir
      ...(d.key === 'home1' ? { bootstrap_local_key: cur.bootstrap_local_key || randomToken(16) } : {}),
      ...(cur.local_key ? { local_key: cur.local_key } : {}),
    };
  }
  acc.users ||= {};
  writeAccountsIfChanged(rt, acc);
  return acc;
}
