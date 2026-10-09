// SystemConfig.h'nin (firmware, src/SystemConfig.h) BIREBIR JavaScript portu: yapilandirma veri yapilari ve DOGRULAMA.
// Sabit boyutlu char[] alanlari ilk NUL'a kadar JS string'i olarak modellenir; kapasite sinirlari UTF-8 BAYT olarak
// uygulanir (terminate/copyStr = en fazla N-1 bayt).
//
// Dogrulama: test/fw_system_config.test.js, firmware'in Unity testlerinin (test/test_system_config) BIREBIR portudur.
import { cBytes, cCopy, cStrLen } from './netutil.js';

export const RelayType = Object.freeze({ LIGHT: 0, SHUTTER_UP: 1, SHUTTER_DOWN: 2, IMPULSE: 3 });
export const DIMode = Object.freeze({ TOGGLE: 0, MOMENTARY: 1, SHUTTER_STEP: 2, SHUTTER_UP: 3, SHUTTER_DOWN: 4 });

export const MAX_TOTAL_RELAYS = 40;
export const MAX_TOTAL_DIS = 40;
export const LOCAL_KEY_MIN_LEN = 8;
export const LOCAL_KEY_MAX_LEN = 32;
export const AP_PASS_MIN_LEN = 8;
export const AP_PASS_MAX_LEN = 32;
export const SHUTTER_RUNTIME_MIN_SEC = 1;
export const SHUTTER_RUNTIME_MAX_SEC = 300;
export const SHUTTER_RUNTIME_DEFAULT_SEC = 20;
export const IMPULSE_MS_MAX = 60000;
export const IMPULSE_MS_DEFAULT = 1000;
export const DEFAULT_MQTT_SERVER = 'evotomasyon.gudeteknoloji.com.tr';
export const DEFAULT_MQTT_PORT = 8884;

// alan kapasiteleri (char[N])
export const CAP = Object.freeze({
  device_name: 32, wifi_ssid: 64, wifi_pass: 64, mqtt_server: 64, mqtt_user: 48, mqtt_pass: 64,
  local_key: LOCAL_KEY_MAX_LEN + 1, ap_pass: AP_PASS_MAX_LEN + 1, relay_name: 32, di_name: 32,
});

const VALID_EXT = new Set([0, 2, 4, 8, 12, 16, 24, 32]);

/** Gecerli ek modul kanal sayilari: {0,2,4,8,12,16,24,32} */
export const isValidExtChannelCount = (channels) => VALID_EXT.has(channels);

/** n bayt uzunlugunda (NUL haric) ve [lo, hi] araliginda yazdirilabilir ASCII mi? */
export function isAsciiRange(s, minLen, maxLen, lo, hi) {
  if (s === null || s === undefined) return false;
  const b = cBytes(s);
  const n = Math.min(b.length, maxLen + 1);
  if (n < minLen || n > maxLen) return false;
  for (let i = 0; i < n; i++) if (b[i] < lo || b[i] > hi) return false;
  return true;
}

export class SystemConfig {
  constructor() {
    // memset(0): bos metin, sifir sayilar
    this.device_name = '';
    this.wifi_ssid = '';
    this.wifi_pass = '';
    this.wifi_sta_enabled = false;
    this.rs485_baud = 0;
    this.ext_module_enabled = false;
    this.ext_module_channels = 0;
    this.ext_module_address = 0;
    this.mqtt_enabled = false;
    this.mqtt_server = '';
    this.mqtt_port = 0;
    this.mqtt_user = '';
    this.mqtt_pass = '';
    this.local_key = '';
    this.ap_pass = '';
    this.relays = Array.from({ length: MAX_TOTAL_RELAYS }, () => ({ name: '', type: 0, runtime_sec: 0 }));
    this.dis = Array.from({ length: MAX_TOTAL_DIS }, () => ({ name: '', target_relay: 0, mode: 0 }));
  }

  /** Derin kopya (kalici durum / dis gorunum icin). */
  clone() {
    const c = new SystemConfig();
    for (const k of Object.keys(this)) {
      if (k === 'relays') c.relays = this.relays.map((r) => ({ ...r }));
      else if (k === 'dis') c.dis = this.dis.map((d) => ({ ...d }));
      else c[k] = this[k];
    }
    return c;
  }

  totalRelays() {
    if (!this.ext_module_enabled) return 8;
    const t = 8 + this.ext_module_channels;     // uint8 tasmasi (8+250=2) olmasin
    return t > MAX_TOTAL_RELAYS ? MAX_TOTAL_RELAYS : t;
  }

  totalDIs() {
    if (!this.ext_module_enabled) return 8;
    const t = 8 + this.ext_module_channels;
    return t > MAX_TOTAL_DIS ? MAX_TOTAL_DIS : t;
  }

  hasLocalKey() { return cStrLen(this.local_key) > 0; }

  hasMqttCredentials() {
    return cStrLen(this.mqtt_server) > 0 && cStrLen(this.mqtt_user) > 0 && cStrLen(this.mqtt_pass) > 0;
  }

  /** 8..32 karakter, yalnizca yazdirilabilir ASCII (0x21..0x7E, bosluk yok). Gecersizse false ve degisiklik YOK. */
  setLocalKey(key) {
    if (!isAsciiRange(key, LOCAL_KEY_MIN_LEN, LOCAL_KEY_MAX_LEN, 0x21, 0x7E)) return false;
    this.local_key = cCopy(key, CAP.local_key);
    return true;
  }

  /** 8..32 karakter, 0x20..0x7E. Gecersizse false ve degisiklik YOK. */
  setApPass(pass) {
    if (!isAsciiRange(pass, AP_PASS_MIN_LEN, AP_PASS_MAX_LEN, 0x20, 0x7E)) return false;
    this.ap_pass = cCopy(pass, CAP.ap_pass);
    return true;
  }

  /** Aralik/kapsam dogrulamasi; gecersiz alani guvenli varsayilana ceker. true = zaten gecerliydi. */
  validate() {
    let ok = true;

    // --- Metin alanlari: her zaman NUL sonlandirilmis (en fazla N-1 bayt) ---
    this.device_name = cCopy(this.device_name, CAP.device_name);
    this.wifi_ssid = cCopy(this.wifi_ssid, CAP.wifi_ssid);
    this.wifi_pass = cCopy(this.wifi_pass, CAP.wifi_pass);
    this.mqtt_server = cCopy(this.mqtt_server, CAP.mqtt_server);
    this.mqtt_user = cCopy(this.mqtt_user, CAP.mqtt_user);
    this.mqtt_pass = cCopy(this.mqtt_pass, CAP.mqtt_pass);
    this.local_key = cCopy(this.local_key, CAP.local_key);
    this.ap_pass = cCopy(this.ap_pass, CAP.ap_pass);

    if (cStrLen(this.device_name) === 0) {
      this.device_name = 'AHBU Akilli Ev Kontrol';
      ok = false;
    }

    // --- Wi-Fi: SSID 1..32 bayt, parola 0 veya 8..63 ---
    const ssidLen = cStrLen(this.wifi_ssid);
    const passLen = cStrLen(this.wifi_pass);
    if (ssidLen > 32 || (passLen !== 0 && (passLen < 8 || passLen > 63))) {
      this.wifi_ssid = '';
      this.wifi_pass = '';
      this.wifi_sta_enabled = false;
      ok = false;
    }
    if (this.wifi_sta_enabled && cStrLen(this.wifi_ssid) === 0) {
      this.wifi_sta_enabled = false;
      ok = false;
    }

    // --- RS485 baud: yalnizca bilinen degerler ---
    switch (this.rs485_baud) {
      case 4800: case 9600: case 19200: case 38400: case 57600: case 115200:
        break;
      default:
        this.rs485_baud = 9600;
        ok = false;
        break;
    }

    // --- Ek modul ---
    if (!isValidExtChannelCount(this.ext_module_channels)) {
      this.ext_module_channels = this.ext_module_enabled ? 8 : 0;
      ok = false;
    }
    if (this.ext_module_enabled && this.ext_module_channels === 0) {
      this.ext_module_channels = 8;
      ok = false;
    }
    if (this.ext_module_address < 1 || this.ext_module_address > 247) {
      this.ext_module_address = 1;
      ok = false;
    }

    // --- MQTT ---
    if (this.mqtt_port === 0) {
      this.mqtt_port = DEFAULT_MQTT_PORT;
      ok = false;
    }
    if (cStrLen(this.mqtt_server) === 0) {
      this.mqtt_server = cCopy(DEFAULT_MQTT_SERVER, CAP.mqtt_server);
      ok = false;
    }

    // --- Yerel anahtar / AP parolasi: gecersizse silinir (kismi/bozuk kimlik asla kalmaz) ---
    if (cStrLen(this.local_key) !== 0 && !isAsciiRange(this.local_key, LOCAL_KEY_MIN_LEN, LOCAL_KEY_MAX_LEN, 0x21, 0x7E)) {
      this.local_key = '';
      ok = false;
    }
    if (cStrLen(this.ap_pass) !== 0 && !isAsciiRange(this.ap_pass, AP_PASS_MIN_LEN, AP_PASS_MAX_LEN, 0x20, 0x7E)) {
      this.ap_pass = '';
      ok = false;
    }

    // --- Roleler ---
    for (let i = 0; i < MAX_TOTAL_RELAYS; i++) {
      const r = this.relays[i];
      r.name = cCopy(r.name, CAP.relay_name);
      if (r.type > RelayType.IMPULSE) {
        r.type = RelayType.LIGHT;
        r.runtime_sec = 0;
        ok = false;
      }
      if (r.type === RelayType.SHUTTER_UP || r.type === RelayType.SHUTTER_DOWN) {
        if (r.runtime_sec < SHUTTER_RUNTIME_MIN_SEC || r.runtime_sec > SHUTTER_RUNTIME_MAX_SEC) {
          r.runtime_sec = SHUTTER_RUNTIME_DEFAULT_SEC;
          ok = false;
        }
      } else if (r.type === RelayType.IMPULSE) {
        if (r.runtime_sec === 0) {
          r.runtime_sec = IMPULSE_MS_DEFAULT;
          ok = false;
        } else if (r.runtime_sec > IMPULSE_MS_MAX) {
          r.runtime_sec = IMPULSE_MS_MAX;
          ok = false;
        }
      }
    }

    // --- Dijital girisler ---
    const totalR = this.totalRelays();
    const totalD = this.totalDIs();
    for (let i = 0; i < MAX_TOTAL_DIS; i++) {
      const d = this.dis[i];
      d.name = cCopy(d.name, CAP.di_name);
      if (d.mode > DIMode.SHUTTER_DOWN) {
        d.mode = DIMode.TOGGLE;
        ok = false;
      }
      const limit = i < totalD ? totalR : MAX_TOTAL_RELAYS;
      if (d.target_relay > limit) {
        d.target_relay = 0;
        ok = false;
      }
    }
    return ok;
  }
}

// ---------------------------------------------------------------------------------------------
// SystemConfig.h applyFactoryRelayDefaults / applyFactoryDiDefaults. Sahip karari (2026-10-09): HICBIR rolenin sabit rolu YOK.
// Yerel roleler "Röle N" genel ac-kapa (sure 0), ek modul roleleri "Ek Modül Röle N"; DI n -> role n TOGGLE. Panjur yalniz sablondan.
export function applyFactoryRelayDefaults(c) {
  for (let i = 0; i < MAX_TOTAL_RELAYS; i++) {
    const r = c.relays[i];
    r.name = cCopy(i < 8 ? `Röle ${i + 1}` : `Ek Modül Röle ${i - 7}`, CAP.relay_name);
    r.type = RelayType.LIGHT;
    r.runtime_sec = 0;
  }
}

/** DI'lar [first, last) araliginda fabrika varsayilanina doner (aralik disindakilere dokunulmaz). */
export function applyFactoryDiDefaults(c, first = 0, last = MAX_TOTAL_DIS) {
  for (let i = Math.max(0, first); i < Math.min(last, MAX_TOTAL_DIS); i++) {
    const d = c.dis[i];
    d.name = cCopy(i < 8 ? `Anahtar / Buton ${i + 1}` : `Ek Giriş / Buton ${i - 7}`, CAP.di_name);
    d.target_relay = i + 1;
    d.mode = DIMode.TOGGLE;
  }
}
