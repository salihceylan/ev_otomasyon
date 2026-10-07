// ConfigManager.cpp'nin (firmware) JavaScript portu: kalici ("NVS") yapilandirma + kimlik/provizyon alanlari.
//
// NVS: tek JSON dosyasi ("imaj"); uc ad alani firmware'deki gibi bagimsiz yazilir:
//   ahbu_cfg  -> yapilandirma + kimlik/provizyon alanlari + "cfg_init"
//   ahbu_auto -> cocuk kilidi
//   ahbu_pos  -> panjur konumlari (20 bayt)
// Dosya yoksa/bos ise "bos flash" gibi davranir (varsayilanlar). Yazma atomiktir (tmp + rename).
// QA: `failKeys` NVS yazma arizasi enjeksiyonudur (bozuk/dolu NVS bolumu; firmware Preferences::putString/remove basarisiz):
// kimlik yardimcilari (setLocalKey/setApPass/clearLocalKey/provisionIfEmpty) bu anahtarlari TEK TEK yazar ve ariza gorur.
import fs from 'node:fs';
import path from 'node:path';
import {
  SystemConfig, RelayType, DIMode, MAX_TOTAL_RELAYS, MAX_TOTAL_DIS, DEFAULT_MQTT_SERVER, DEFAULT_MQTT_PORT,
  SHUTTER_RUNTIME_DEFAULT_SEC, CAP, isAsciiRange, LOCAL_KEY_MIN_LEN, LOCAL_KEY_MAX_LEN, AP_PASS_MIN_LEN, AP_PASS_MAX_LEN,
} from './sysconfig.js';
import { cCopy } from './netutil.js';

/**
 * ConfigManager::ProvisionResult (firmware) karsiligi; degerler HTTP hata kodlariyla ayni adlidir.
 * Esleme: HTTP factory/init -> 200 | 403 already_provisioned | 400 invalid_key | 400 invalid_ap_pass | 503 storage;
 *         seri FACTORYINIT  -> OK factory_init | ERR already_provisioned | ERR invalid_local_key | ERR invalid_ap_pass | ERR persist_failed.
 */
export const ProvisionResult = Object.freeze({
  OK: 'ok', ALREADY: 'already_provisioned', INVALID_KEY: 'invalid_key', INVALID_AP_PASS: 'invalid_ap_pass', STORAGE: 'storage',
});

export class NvsImage {
  /** @param {string|null} file  null = yalnizca bellek */
  constructor(file = null, { log = () => {} } = {}) {
    this.file = file;
    this.log = log;
    // safety (NVS_NS_SAFETY) fabrika sifirlamasinda silinir; latch (NVS_NS_LATCH) SILINMEZ (guvenlik katmani, spec 2.7 [Y-5]).
    this.data = { v: 2, cfg: null, auto: null, pos: null, safety: null, latch: null };
    this.writes = 0;
    /** QA: yazmasi/silmesi BASARISIZ olacak NVS anahtarlari (ornek 'lk', 'ap_pw'); donanim durumu: yeniden acilista korunur. */
    this.failKeys = new Set();
    if (file) this.#read();
  }

  #read() {
    try {
      const raw = JSON.parse(fs.readFileSync(this.file, 'utf8'));
      if (raw && typeof raw === 'object') {
        this.data = {
          v: 2, cfg: raw.cfg ?? null, auto: raw.auto ?? null, pos: raw.pos ?? null, safety: raw.safety ?? null, latch: raw.latch ?? null,
        };
      }
    } catch (_) {
      /* dosya yok/bozuk: bos flash */
    }
  }

  #flush() {
    this.writes++;
    if (!this.file) return;
    try {
      fs.mkdirSync(path.dirname(this.file), { recursive: true });
      const tmp = `${this.file}.${process.pid}.tmp`;
      fs.writeFileSync(tmp, JSON.stringify(this.data), { mode: 0o600 });
      fs.renameSync(tmp, this.file);
    } catch (err) {
      this.log('nvs_write_failed', { error: err.message });
    }
  }

  get(ns) { return this.data[ns] === null || this.data[ns] === undefined ? null : JSON.parse(JSON.stringify(this.data[ns])); }

  put(ns, value) { this.data[ns] = JSON.parse(JSON.stringify(value)); this.#flush(); }

  clear(ns) { this.data[ns] = null; this.#flush(); }

  /** TEK anahtar yazar (Preferences::putX). `failKeys`'teki anahtar YAZILMAZ -> false. */
  putKey(ns, key, value) {
    if (this.failKeys.has(key)) { this.log('nvs_write_failed', { key }); return false; }
    this.put(ns, { ...(this.get(ns) || {}), [key]: value });
    return true;
  }

  /** TEK anahtar siler (Preferences::remove). Anahtar yoksa basarili; `failKeys`'teki anahtar SILINMEZ -> false. */
  removeKey(ns, key) {
    const cur = this.get(ns) || {};
    if (!(key in cur)) return true;
    if (this.failKeys.has(key)) { this.log('nvs_write_failed', { key }); return false; }
    delete cur[key];
    this.put(ns, cur);
    return true;
  }

  /** Tum imaji siler (fiziksel "flash erase"). */
  eraseAll() { this.data = { v: 2, cfg: null, auto: null, pos: null }; this.#flush(); }
}

const DEFAULT_RELAY_NAMES = [
  'Salon Panjur (Yukari)', 'Salon Panjur (Asagi)', 'Oda Panjur (Yukari)', 'Oda Panjur (Asagi)',
  'Salon Aydinlatma', 'Mutfak Aydinlatma', 'Koridor Aydinlatma', 'Balkon Aydinlatma',
];

export class ConfigManager {
  /** @param {NvsImage} nvs */
  constructor(nvs, { log = () => {} } = {}) {
    this.nvs = nvs;
    this.log = log;
    this.config = new SystemConfig();
    this.generation = 0;
    this.resetCount = 0;
    this.applyDefaults();
  }

  /** RAM'i varsayilana ceker; NVS'e DOKUNMAZ. Kimlik alanlari bos kalir. (ConfigManager::applyDefaults) */
  applyDefaults() {
    const c = new SystemConfig();
    c.device_name = 'AHBU Akilli Ev Kontrol';
    c.wifi_sta_enabled = false;
    c.rs485_baud = 9600;
    c.ext_module_enabled = false;
    c.ext_module_channels = 0;
    c.ext_module_address = 1;
    c.mqtt_enabled = true;
    c.mqtt_server = cCopy(DEFAULT_MQTT_SERVER, CAP.mqtt_server);
    c.mqtt_port = DEFAULT_MQTT_PORT;

    for (let i = 0; i < MAX_TOTAL_RELAYS; i++) {
      const r = c.relays[i];
      if (i < 8) {
        r.name = DEFAULT_RELAY_NAMES[i];
        if (i === 0 || i === 2) { r.type = RelayType.SHUTTER_UP; r.runtime_sec = SHUTTER_RUNTIME_DEFAULT_SEC; }
        else if (i === 1 || i === 3) { r.type = RelayType.SHUTTER_DOWN; r.runtime_sec = SHUTTER_RUNTIME_DEFAULT_SEC; }
        else { r.type = RelayType.LIGHT; r.runtime_sec = 0; }
      } else {
        r.name = cCopy(`Ek Modül Röle ${i - 7}`, CAP.relay_name);
        r.type = RelayType.LIGHT;
        r.runtime_sec = 0;
      }
    }
    for (let i = 0; i < MAX_TOTAL_DIS; i++) {
      const d = c.dis[i];
      d.name = i < 8 ? `Anahtar / Buton ${i + 1}` : cCopy(`Ek Giriş / Buton ${i - 7}`, CAP.di_name);
      d.target_relay = i + 1;
      d.mode = DIMode.TOGGLE;
    }
    c.dis[0].name = 'Salon Panjur Butonu'; c.dis[0].target_relay = 1; c.dis[0].mode = DIMode.SHUTTER_STEP;
    c.dis[1].name = cCopy('Giriş 2 (Boşta / Serbest)', CAP.di_name); c.dis[1].target_relay = 0; c.dis[1].mode = DIMode.TOGGLE;
    c.dis[2].name = 'Oda Panjur Butonu'; c.dis[2].target_relay = 3; c.dis[2].mode = DIMode.SHUTTER_STEP;
    c.dis[3].name = cCopy('Giriş 4 (Boşta / Serbest)', CAP.di_name); c.dis[3].target_relay = 0; c.dis[3].mode = DIMode.TOGGLE;
    this.config = c;
  }

  /** ConfigManager::begin() + load() */
  begin() {
    this.load();
  }

  load() {
    const stored = this.nvs.get('cfg');
    if (!stored || !stored.cfg_init) {
      // Ilk acilis: varsayilanlari yaz
      this.applyDefaults();
      this.config.validate();
      this.save();
      return;
    }
    this.applyDefaults();
    const c = this.config;
    const s = stored;
    const str = (k) => (typeof s[k] === 'string' ? s[k] : null);
    const num = (k, d) => (typeof s[k] === 'number' ? s[k] : d);
    const bool = (k, d) => (typeof s[k] === 'boolean' ? s[k] : d);
    if (str('dev_name') !== null) c.device_name = s.dev_name;
    if (str('sta_ssid') !== null) c.wifi_ssid = s.sta_ssid;
    if (str('sta_pass') !== null) c.wifi_pass = s.sta_pass;
    c.wifi_sta_enabled = bool('sta_en', false);
    c.rs485_baud = num('rs_baud', 9600);
    c.ext_module_enabled = bool('ext_en', false);
    c.ext_module_channels = num('ext_ch', 0);
    c.ext_module_address = num('ext_addr', 1);
    c.mqtt_enabled = bool('mq_en', true);
    if (str('mq_srv') !== null) c.mqtt_server = s.mq_srv;
    c.mqtt_port = num('mq_port', DEFAULT_MQTT_PORT);
    if (str('mq_usr') !== null) c.mqtt_user = s.mq_usr;
    if (str('mq_pwd') !== null) c.mqtt_pass = s.mq_pwd;
    if (str('lk') !== null) c.local_key = s.lk;
    if (str('ap_pw') !== null) c.ap_pass = s.ap_pw;

    // GOC: eski paylasimli "home_*" MQTT kimligi gecersiz sayilir ve silinir
    let legacyPurged = false;
    if (c.mqtt_user.startsWith('home_')) {
      c.mqtt_user = '';
      c.mqtt_pass = '';
      legacyPurged = true;
    }
    for (let i = 0; i < MAX_TOTAL_RELAYS; i++) {
      if (str(`r_nm_${i}`) !== null) c.relays[i].name = s[`r_nm_${i}`];
      c.relays[i].type = num(`r_tp_${i}`, c.relays[i].type);
      c.relays[i].runtime_sec = num(`r_rt_${i}`, c.relays[i].runtime_sec);
    }
    for (let i = 0; i < MAX_TOTAL_DIS; i++) {
      if (str(`d_nm_${i}`) !== null) c.dis[i].name = s[`d_nm_${i}`];
      c.dis[i].target_relay = num(`d_tr_${i}`, c.dis[i].target_relay);
      c.dis[i].mode = num(`d_md_${i}`, c.dis[i].mode);
    }
    const wasValid = c.validate();
    if (!wasValid || legacyPurged) this.save();
  }

  /** Tum alanlari NVS'e yazar (once validate()). */
  save() {
    const c = this.config;
    c.validate();
    const out = {
      dev_name: c.device_name, sta_ssid: c.wifi_ssid, sta_pass: c.wifi_pass, sta_en: c.wifi_sta_enabled, rs_baud: c.rs485_baud,
      ext_en: c.ext_module_enabled, ext_ch: c.ext_module_channels, ext_addr: c.ext_module_address,
      mq_en: c.mqtt_enabled, mq_srv: c.mqtt_server, mq_port: c.mqtt_port, mq_usr: c.mqtt_user, mq_pwd: c.mqtt_pass,
      lk: c.local_key, ap_pw: c.ap_pass,
    };
    const totalR = c.totalRelays();
    const totalD = c.totalDIs();
    // Firmware yalnizca etkin role/DI aralığini yazar; digerleri onceki degerini korur (NVS'te kalir)
    const prev = this.nvs.get('cfg') || {};
    for (let i = 0; i < MAX_TOTAL_RELAYS; i++) {
      if (i < totalR) {
        out[`r_nm_${i}`] = c.relays[i].name; out[`r_tp_${i}`] = c.relays[i].type; out[`r_rt_${i}`] = c.relays[i].runtime_sec;
      } else {
        for (const k of [`r_nm_${i}`, `r_tp_${i}`, `r_rt_${i}`]) if (k in prev) out[k] = prev[k];
      }
    }
    for (let i = 0; i < MAX_TOTAL_DIS; i++) {
      if (i < totalD) {
        out[`d_nm_${i}`] = c.dis[i].name; out[`d_tr_${i}`] = c.dis[i].target_relay; out[`d_md_${i}`] = c.dis[i].mode;
      } else {
        for (const k of [`d_nm_${i}`, `d_tr_${i}`, `d_md_${i}`]) if (k in prev) out[k] = prev[k];
      }
    }
    out.cfg_init = true;   // EN SON yazilir
    this.nvs.put('cfg', out);
    this.generation++;
    return true;
  }

  /** Kimlik/provizyon alanlari KORUNUR; uygulama anahtarlari + cocuk kilidi + konumlar silinir. */
  resetToDefaults() {
    const k = {
      local_key: this.config.local_key, ap_pass: this.config.ap_pass, mqtt_server: this.config.mqtt_server,
      mqtt_user: this.config.mqtt_user, mqtt_pass: this.config.mqtt_pass, mqtt_port: this.config.mqtt_port,
      mqtt_enabled: this.config.mqtt_enabled,
    };
    this.applyDefaults();
    const c = this.config;
    c.local_key = k.local_key; c.ap_pass = k.ap_pass; c.mqtt_server = k.mqtt_server; c.mqtt_user = k.mqtt_user;
    c.mqtt_pass = k.mqtt_pass; c.mqtt_port = k.mqtt_port; c.mqtt_enabled = k.mqtt_enabled;
    c.validate();
    // eraseAppKeys(): kimlik anahtarlari (mq_*, lk, ap_pw) kalir
    const prev = this.nvs.get('cfg') || {};
    const kept = {};
    for (const key of ['mq_en', 'mq_srv', 'mq_port', 'mq_usr', 'mq_pwd', 'lk', 'ap_pw']) if (key in prev) kept[key] = prev[key];
    this.nvs.put('cfg', kept);
    this.nvs.clear('auto');
    this.nvs.clear('pos');
    if (this.nvs.get('safety')) this.nvs.clear('safety');   // guvenlik yapilandirmasi; kilit kaydi ('latch') bilincli olarak KALIR [Y-5]
    this.save();
    this.resetCount++;
    return true;
  }

  hasLocalKey() { return this.config.hasLocalKey(); }

  hasMqttCredentials() { return this.config.hasMqttCredentials(); }

  #putCfg(patch) {
    const cur = this.nvs.get('cfg') || {};
    this.nvs.put('cfg', { ...cur, ...patch });
  }

  /** RAM + NVS BIRLIKTE degisir ya da hicbiri: bicim gecersizse ya da NVS yazilamazsa false ve RAM eski degerde (firmware ile ayni). */
  setLocalKey(key) {
    const old = this.config.local_key;
    if (!this.config.setLocalKey(key)) return false;
    if (this.nvs.putKey('cfg', 'lk', this.config.local_key)) return true;
    this.config.local_key = old;
    return false;
  }

  setApPass(pass) {
    const old = this.config.ap_pass;
    if (!this.config.setApPass(pass)) return false;
    if (this.nvs.putKey('cfg', 'ap_pw', this.config.ap_pass)) return true;
    this.config.ap_pass = old;
    return false;
  }

  /** Seri RESETKEY: RAM her zaman silinir; NVS'ten silinemezse false (yeniden acilista NVS'teki anahtar doner; firmware ile ayni). */
  clearLocalKey() {
    this.config.local_key = '';
    return this.nvs.removeKey('cfg', 'lk');
  }

  /**
   * ConfigManager::provisionIfEmpty portu: ATOMIK ilk provizyon -- seri FACTORYINIT ve HTTP POST /api/factory/init ORTAK yolu.
   * Firmware'de tek ConfigLock altinda calisir (JS'te cagri bolunmez): local_key varsa ALREADY (once denetlenir, hicbir sey degismez);
   * bicim (local_key 8..32 0x21..0x7E, ap_pass 8..32 0x20..0x7E); ONCE ap_pass SONRA local_key yazilir. local_key yazilamazsa ap_pass
   * onceki degerine geri alinir (yarim provizyon kalmaz; cihaz provizyonsuz kalir, yeniden denenebilir). @returns {string} ProvisionResult
   */
  provisionIfEmpty(key, pass) {
    if (this.config.hasLocalKey()) return ProvisionResult.ALREADY;
    if (!isAsciiRange(key, LOCAL_KEY_MIN_LEN, LOCAL_KEY_MAX_LEN, 0x21, 0x7E)) return ProvisionResult.INVALID_KEY;
    if (!isAsciiRange(pass, AP_PASS_MIN_LEN, AP_PASS_MAX_LEN, 0x20, 0x7E)) return ProvisionResult.INVALID_AP_PASS;
    const oldPass = this.config.ap_pass;
    if (!this.setApPass(pass)) return ProvisionResult.STORAGE;   // RAM geri alindi: hicbir sey degismedi
    if (this.setLocalKey(key)) return ProvisionResult.OK;
    this.#restoreApPass(oldPass);                                // local_key RAM'i setLocalKey'de geri alindi
    return ProvisionResult.STORAGE;
  }

  /** provisionIfEmpty geri alma adimi: RAM NVS'i izler (NVS geri yazilamazsa RAM de yeni degerde kalir). */
  #restoreApPass(old) {
    if (old !== '') { this.setApPass(old); return; }
    if (this.nvs.removeKey('cfg', 'ap_pw')) this.config.ap_pass = '';
  }

  /** POST /api/mqtt/config: alan uzunluklari dogrulanir; kirpma yok, reddedilir. */
  setMqttCredentials(server, port, user, pass) {
    const c = this.config;
    if (!isAsciiRange(server, 1, CAP.mqtt_server - 1, 0x21, 0x7E)) return false;
    if (!Number.isInteger(port) || port <= 0 || port > 65535) return false;
    if (!isAsciiRange(user, 1, CAP.mqtt_user - 1, 0x21, 0x7E)) return false;
    if (!isAsciiRange(pass, 1, CAP.mqtt_pass - 1, 0x20, 0x7E)) return false;
    c.mqtt_server = cCopy(server, CAP.mqtt_server);
    c.mqtt_port = port;
    c.mqtt_user = cCopy(user, CAP.mqtt_user);
    c.mqtt_pass = cCopy(pass, CAP.mqtt_pass);
    this.#putCfg({ mq_srv: c.mqtt_server, mq_port: c.mqtt_port, mq_usr: c.mqtt_user, mq_pwd: c.mqtt_pass });
    return true;
  }

  saveRelayRuntime(relayIndex) {
    if (relayIndex < 0 || relayIndex >= MAX_TOTAL_RELAYS) return false;
    this.#putCfg({ [`r_rt_${relayIndex}`]: this.config.relays[relayIndex].runtime_sec });
    return true;
  }

  validate() { return this.config.validate(); }
}
