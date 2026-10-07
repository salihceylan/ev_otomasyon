// ESP32-S3 ev otomasyonu panosunun Node simulatoru (CONTRACTS §2 MQTT + §3 yerel HTTP API).
//
// Bu bir FIRMWARE DEGILDIR ama firmware KAYNAGININ birebir portlari uzerine kuruludur:
//   sim/fw/shutter_fsm.js, di_gate.js, interlock_guard.js, sysconfig.js, netutil.js, net_time.js, ap_access.js -> firmware'in kendi Unity testleriyle dogrulanir (test/fw_*.test.js)
//   sim/fw/automation.js (SmartAutomation), config_manager.js, wifi_manager.js, mqtt_manager.js, sim/local_api.js (WebPortal) -> kaynak izlenerek yazilmis modeller
// Neyi kanitlar/kanitlamaz: docs/QA_STACK.md.
//
// Bu dosya: bilesenlerin (ConfigManager + Automation + WifiManager + MqttManager + WebPortal) bir arada calistigi "pano" ve QA kontrol ucu.
// Gercek zamanli dongu: tickMs (10 ms) aralikla Automation.loop() (Core 1), 100 ms'de WifiManager.tick, 50 ms'de MqttManager.step (Core 0);
// WebPortal housekeeping (kimlik kilitleri / hiz sinirlari / tarama sayaclari) her tikte (firmware: WebTask her tur).
import crypto from 'node:crypto';
import path from 'node:path';
import { performance } from 'node:perf_hooks';
import { pathToFileURL } from 'node:url';
import { HOME_WIFI_SSID } from '../lib/config.js';
import { isValidApPass, isValidLocalKey } from './command_schema.js';
import { createLocalApiServer, PortalState } from './local_api.js';
import { Automation, CmdSource, RS485_BAUDS } from './fw/automation.js';
import { ConfigManager, NvsImage, ProvisionResult } from './fw/config_manager.js';
import { MqttManager, QA_TIMING, FIRMWARE_TIMING } from './fw/mqtt_manager.js';
import { WifiManager, WifiWorld, AUTH_FAIL_REASONS, AP_IP, FW_VERSION_DEFAULT } from './fw/wifi_manager.js';
import { MAX_TOTAL_RELAYS, MAX_TOTAL_DIS, RelayType, DIMode } from './fw/sysconfig.js';
import { clientOnSoftAp, ipToU32, u32ToIp } from './fw/ap_access.js';
import { PhysicalObserver } from './fw/observer.js';
import { parseSensorId, parseActuatorId } from './fw/safety_cfg_api.js';
import { SensorSrc } from './fw/sensor_hub.js';
import { relayLevelFor } from './fw/actuator_map.js';

export const UID_RE = /^AHBU-[A-Z0-9-]{3,32}$/;
export const S3_UID_RE = /^AHBU-S3-[0-9A-F]{6}$/;
export const RELAY_TYPE = RelayType;
export const DI_MODE = DIMode;
export const MAX_TOTAL = MAX_TOTAL_RELAYS;
export const VALID_EXT_CHANNELS = [0, 2, 4, 8, 12, 16, 24, 32];

const u32 = (x) => x >>> 0;
const sha1 = (s) => crypto.createHash('sha1').update(s).digest();

/** AHBU-S3-<6 hex> UID'sinden MAC turetir (firmware: UID = MAC'in son 3 bayti); diger UID'ler icin sha1 tabanli yerel yonetimli MAC. */
export function macFromUid(uid) {
  const m = S3_UID_RE.exec(uid);
  if (m) {
    const h = m[0].slice(-6);
    return `02:A5:00:${h.slice(0, 2)}:${h.slice(2, 4)}:${h.slice(4, 6)}`;
  }
  const h = sha1(uid);
  h[0] = (h[0] & 0xfe) | 0x02;
  return [...h.subarray(0, 6)].map((b) => b.toString(16).padStart(2, '0').toUpperCase()).join(':');
}

const DEFAULTS = {
  relays: 8,
  httpHost: '127.0.0.1',
  httpPort: 0,
  mqtt: null,
  mqttHostMap: { '10.0.2.2': '127.0.0.1', localhost: '127.0.0.1' },
  localKey: '',
  apPass: '',
  timeScale: 1,
  deviceName: null,
  fw: FW_VERSION_DEFAULT,
  homeWifi: { ssid: HOME_WIFI_SSID, pass: '' },
  wifiConnected: false,
  stateFile: null,
  resetState: false,
  strict: false,
  tickMs: 10,
  bootMs: 800,
  rebootMs: 1500,
  bootHoldMs: 500,
  firmwareTiming: false,
  mqttTiming: null,
  wifiTiming: null,
  millisOffset: 0,
  log: null,
  clock: null,
  // QA: HTTP istemcisinin ag konumu modeli (gercek soket adresinden cikarilamaz: hepsi 127.0.0.1). 'ap' = istemci cihazin SoftAP'inde (192.168.4.x),
  // 'lan' = ev aginda. Varsayilan: ev agina bagli baslayan cihaz icin 'lan', degilse 'ap' (STA yokken cihaza tek yol SoftAP'dir).
  clientNet: null,
  staIp: null,   // QA: STA adresi (varsayilan 192.168.1.<30..129>); 192.168.4.x vermek "ev modemi de 192.168.4.0/24" cakismasini sinar
};

export const CLIENT_NET_MODES = Object.freeze(['ap', 'lan']);
/** QA NVS yazma arizasi enjekte edilebilen kimlik anahtarlari (firmware ConfigManager: "lk" = local_key, "ap_pw" = ap_pass). */
export const NVS_FAILABLE_KEYS = Object.freeze(['ap_pw', 'lk']);
const CLIENT_AP_IP = '192.168.4.2';   // SoftAP DHCP'sinin ilk istemci adresi

const isoNow = () => new Date().toISOString();

export class DeviceSimulator {
  /** @param {Partial<typeof DEFAULTS> & {uid:string}} options */
  constructor(options = {}) {
    const o = { ...DEFAULTS, ...options };
    if (!UID_RE.test(String(o.uid || ''))) throw new Error(`gecersiz UID (^AHBU-[A-Z0-9-]{3,32}$): ${o.uid}`);
    if (![8, 16].includes(Number(o.relays))) throw new Error('--relays 8 veya 16 olmali');
    if (o.localKey && !isValidLocalKey(o.localKey)) throw new Error('--local-key 8..32 yazdirilabilir ASCII (bosluksuz) olmali');
    this.opts = o;
    this.uid = o.uid;
    this.fw_version = o.fw;
    this.clock = o.clock || { now: () => performance.now() };
    this.timeScale = Number(o.timeScale) > 0 ? Number(o.timeScale) : 1;
    this.logFn = o.log || (() => {});
    this.mac = macFromUid(this.uid);
    this.uidOverride = S3_UID_RE.test(this.uid) ? '' : this.uid;
    this.staIp = o.staIp || `192.168.1.${30 + ([...this.uid].reduce((a, c) => a + c.charCodeAt(0), 0) % 100)}`;
    if (!ipToU32(this.staIp)) throw new Error(`gecersiz staIp: ${o.staIp}`);
    const cn = o.clientNet || (o.wifiConnected ? 'lan' : 'ap');
    if (!CLIENT_NET_MODES.includes(cn)) throw new Error(`clientNet ap|lan olmali: ${o.clientNet}`);
    /** HTTP istemcisinin ag konumu modeli (bkz. DEFAULTS.clientNet). remoteIp: acik IP gecersiz kilma; apClients: SoftAP istasyon sayisi gecersiz kilma (null = tureti) */
    this.clientNet = { mode: cn, remoteIp: null, apClients: null };

    this.eventSeq = 0;
    this.events = [];
    this.violations = [];
    this.fatal = null;
    this.counters = { mqtt_cmd_queued: 0, mqtt_cmd_rejected: 0, mqtt_cmd_ignored: 0, http_cmd: 0, di_edges: 0, http_locked: 0 };

    // ---- kalici ("NVS") imaj
    this.nvs = new NvsImage(o.stateFile, { log: (t, f) => this.event(t, f) });
    if (o.resetState) this.nvs.eraseAll();

    // ---- fiziksel donanim (yeniden baslatmalarda korunur)
    this.rawDi = new Array(MAX_TOTAL_DIS).fill(false);
    const extChannels = Number(o.relays) > 8 ? Number(o.relays) - 8 : 0;
    this.ext = { present: extChannels > 0, address: 1, baud: 9600, channels: extChannels, coils: new Array(32).fill(false), rawDi: new Array(32).fill(false), failWrites: false };
    this.world = new WifiWorld({ homeSsid: o.homeWifi.ssid || HOME_WIFI_SSID, homePass: o.homeWifi.pass || '' });

    // ---- calisma zamani
    this.fw = null;               // {cm, automation, wifi, mqtt, portal}
    this.booting = true;
    this.stopped = true;
    this.bootClockAt = this.clock.now();
    this.restored = false;
    this.slow = { delayMs: 0, drop: false };
    this.httpServer = null;
    this.ticker = null;
    this.timers = new Set();
    this.lastWifiTick = -Infinity;
    this.lastMqttStep = -Infinity;
    this.observer = new PhysicalObserver();
    // guvenlik katmani QA modelleri (yeniden baslatmalarda korunur: fiziksel dunya)
    this.bridgeFeed = new Map();   // kopru yuvasi -> aktif (raporlar 5 sn'de bir yinelenir)
    this.lastBridgeReport = 0;
    this.valveFb = new Map();      // eylemci -> geri bildirim modeli
  }

  // =========================================================================== yardimcilar
  /** Cihaz millis() (acilista 0; `millisOffset` ile taşma testi icin ileri alinabilir). */
  millis() { return u32(Math.floor(this.clock.now() - this.bootClockAt) + this.opts.millisOffset); }

  uptimeSec() { return Math.floor((this.clock.now() - this.bootClockAt) / 1000); }

  get httpPort() {
    return this.httpServer && this.httpServer.listening ? this.httpServer.address().port : this.opts.httpPort;
  }

  get topicId() { return this.fw ? this.fw.mqtt.topicId : ''; }

  get childLock() { return this.fw ? this.fw.automation.childLockEnabled : false; }

  get mqttCfg() { return this.fw && this.fw.cm.config.hasMqttCredentials() ? { server: this.fw.cm.config.mqtt_server, port: this.fw.cm.config.mqtt_port, user: this.fw.cm.config.mqtt_user } : null; }

  get wifi() { return this.fw ? { connected: this.fw.wifi.isConnected(), connecting: this.fw.wifi.isConnecting(), ssid: this.fw.wifi.getSSID(), ip: this.fw.wifi.getLocalIP() } : { connected: false, connecting: false, ssid: '', ip: '' }; }

  get mqttState() { return this.fw ? this.fw.mqtt.qaState(this.millis()).state : 'disconnected'; }

  get mqttConnected() { return !!this.fw && this.fw.mqtt.isConnected(); }

  isProvisioned() { return this.fw ? this.fw.cm.hasLocalKey() : this.nvs.get('cfg') !== null && typeof this.nvs.get('cfg').lk === 'string' && this.nvs.get('cfg').lk !== ''; }

  totalRelays() { return this.fw ? this.fw.cm.config.totalRelays() : 8; }

  totalPairs() { return Math.floor(this.totalRelays() / 2); }

  event(type, fields = {}) {
    const entry = { n: ++this.eventSeq, t: isoNow(), type, ...fields };
    this.events.push(entry);
    if (this.events.length > 500) this.events.splice(0, this.events.length - 500);
    this.logFn(`sim_${type}`, { uid: this.uid, ...fields });
    return entry;
  }

  eventsSince(since = 0, limit = 200) {
    return this.events.filter((e) => e.n > since).slice(0, limit);
  }

  // =========================================================================== firmware bilesenleri (acilis)
  /** Ilk acilista (bos NVS) komut satiri degerleri "fabrika provizyonu" gibi islenir. */
  #applyFactoryOptions(cm) {
    const o = this.opts;
    const c = cm.config;
    if (o.deviceName) c.device_name = String(o.deviceName).slice(0, 31);
    if (Number(o.relays) > 8) {
      c.ext_module_enabled = true;
      c.ext_module_channels = Number(o.relays) - 8;
      c.ext_module_address = 1;
    }
    if (o.localKey) {
      cm.setLocalKey(o.localKey);
      cm.setApPass(isValidApPass(o.apPass) ? o.apPass : crypto.randomBytes(9).toString('base64url'));
    }
    if (o.mqtt && o.mqtt.host && o.mqtt.user && o.mqtt.pass) {
      cm.setMqttCredentials(o.mqtt.host, Number(o.mqtt.port) || 1883, o.mqtt.user, o.mqtt.pass);
    }
    if (o.wifiConnected) {
      c.wifi_ssid = o.homeWifi.ssid || HOME_WIFI_SSID;
      c.wifi_pass = o.homeWifi.pass || '';
      c.wifi_sta_enabled = true;
    }
    cm.save();
  }

  #buildFirmware() {
    const first = this.nvs.get('cfg') === null;
    const cm = new ConfigManager(this.nvs, { log: (t, f) => this.event(t, f) });
    cm.begin();
    if (first) this.#applyFactoryOptions(cm);
    this.restored = !first;

    const hooks = { event: (t, f) => this.event(t, f) };
    const automation = new Automation({
      config: cm,
      nvs: this.nvs,
      ext: this.ext,
      timeScale: this.timeScale,
      bootHoldMs: this.opts.bootHoldMs,
      // firmware NetUtil::isTimeSynced() ? time(nullptr) : 0 (alarm "since")
      epoch: () => (this.fw && this.fw.wifi.isTimeSynced() ? Math.floor(Date.now() / 1000) : 0),
      hooks: {
        event: hooks.event,
        beep: (ms, reason) => { this.counters.beeps = (this.counters.beeps || 0) + 1; this.lastBeep = { ms, reason, t: isoNow() }; },
        changed: () => this.fw && this.fw.mqtt.triggerPublish(this.millis()),
        preRestart: () => this.#preRestart(),
        restart: () => this.#onRestart(),
      },
    });
    automation.rawDi = this.rawDi;
    const wifi = new WifiManager({
      config: cm,
      world: this.world,
      mac: this.mac,
      staIp: this.staIp,
      hooks,
      timing: this.opts.wifiTiming || {},
      uidOverride: this.uidOverride,
    });
    const mqttTiming = { ...(this.opts.firmwareTiming ? FIRMWARE_TIMING : QA_TIMING), ...(this.opts.mqttTiming || {}) };
    const mqtt = new MqttManager({
      config: cm,
      wifi,
      automation,
      clock: { now: () => this.millis() },
      uptimeSec: () => this.uptimeSec(),
      mac: this.mac,
      fw: this.fw_version,
      post: (cmd) => this.postCommand(cmd),
      hooks: {
        ...hooks,
        mapHost: (h) => this.opts.mqttHostMap[h] || h,
        counter: (name) => { this.counters[name] = (this.counters[name] || 0) + 1; },
      },
      timing: mqttTiming,
    });
    this.fw = { cm, automation, wifi, mqtt, portal: new PortalState() };
    this.#syncClientNet();
    const now = this.millis();
    automation.begin(now);
    wifi.begin();
    mqtt.begin();
    this.observer.boot(u32(now + this.opts.bootHoldMs - 500));   // acilis penceresi kisaltildiysa gozlemci olu zamani da ayni payla baslar
    this.lastWifiTick = -Infinity;
    this.lastMqttStep = -Infinity;
    this.event('booted', { kind: this.bootKind || 'cold', relays: cm.config.totalRelays(), provisioned: cm.hasLocalKey(), restored: this.restored, uid: wifi.getDeviceUid() });
  }

  /** Yeniden acilis: bilesenler yok edilir, bootMs sonra NVS'ten yeniden olusturulur (HTTP bu surede yanitsiz). */
  #scheduleColdBoot(bootMs, kind) {
    this.booting = true;
    this.fw = null;
    this.bootKind = kind;
    const t = setTimeout(() => {
      this.timers.delete(t);
      if (this.stopped) return;
      this.bootClockAt = this.clock.now();
      this.#buildFirmware();
      this.booting = false;
    }, bootMs);
    this.timers.add(t);
  }

  #preRestart() {
    const fw = this.fw;
    if (!fw) return;
    // Kancalar kayit sirasiyla: MQTT "offline" yayinlanir ve baglanti temiz kapanir; sonra (sifirlamada) Wi-Fi surucu ayarlari silinir
    fw.mqtt.prepareForRestart().catch(() => {});
    if (fw.portal.wifiRestorePending) {
      fw.portal.wifiRestorePending = false;
      fw.wifi.factoryResetWifi();
    }
  }

  #onRestart() {
    this.event('reboot', { boot_ms: this.opts.rebootMs });
    this.#scheduleColdBoot(this.opts.rebootMs, 'soft');
  }

  // =========================================================================== yasam dongusu
  async start() {
    if (!this.stopped) return this;
    this.stopped = false;
    this.bootClockAt = this.clock.now();
    this.httpServer = createLocalApiServer(this);
    await new Promise((resolve, reject) => {
      this.httpServer.once('error', reject);
      this.httpServer.listen(this.opts.httpPort, this.opts.httpHost, () => {
        this.httpServer.off('error', reject);
        resolve();
      });
    });
    this.#buildFirmware();
    this.booting = false;
    this.ticker = setInterval(() => this.#tickSafe(), this.opts.tickMs);
    this.event('started', { http_port: this.httpPort, provisioned: this.isProvisioned(), relays: this.totalRelays(), restored: this.restored });
    return this;
  }

  async stop({ graceful = true } = {}) {
    if (this.stopped) return;
    this.stopped = true;
    clearInterval(this.ticker);
    for (const t of this.timers) clearTimeout(t);
    this.timers.clear();
    const fw = this.fw;
    this.fw = null;
    if (fw) {
      try { fw.automation.persistPositions(this.millis(), true); } catch (_) { /* yok say */ }
      if (graceful) await fw.mqtt.prepareForRestart().catch(() => {});
      else fw.mqtt.qaForceOffline();
    }
    if (this.httpServer) {
      await new Promise((resolve) => {
        this.httpServer.close(() => resolve());
        this.httpServer.closeAllConnections?.();
      });
    }
    this.event('stopped', {});
  }

  #tickSafe() {
    try {
      this.tick();
    } catch (err) {
      this.event('tick_error', { error: err.message, stack: String(err.stack || '').split('\n').slice(0, 3).join(' | ') });
      if (this.opts.strict) this.fatal = err;
    }
  }

  /** Test icin dis tetikleme de yapilabilir. */
  tick() {
    const fw = this.fw;
    if (!fw || this.booting) return;
    const now = this.millis();
    this.#serviceValveFb(now);
    if (this.bridgeFeed.size && u32(now - this.lastBridgeReport) >= 5000) for (const slot of this.bridgeFeed.keys()) this.#bridgeReport(slot);
    fw.automation.loop(now);
    if (this.fw !== fw) return;   // loop icinde yeniden baslatma istendi
    this.#observe(now);
    if (u32(now - this.lastWifiTick) >= 100 || this.lastWifiTick === -Infinity) { this.lastWifiTick = now; fw.wifi.tick(now); }
    if (u32(now - this.lastMqttStep) >= 50 || this.lastMqttStep === -Infinity) { this.lastMqttStep = now; fw.mqtt.step(now); }
    fw.portal.housekeeping(now);   // WebTask: dolan kimlik kilitleri / hiz sinirlari / tarama sayaclari sonlandirilir (N6)
  }

  /** Bagimsiz "fiziksel" gozlemci (fw/observer.js): panjur ciftinde iki yon / dogrudan yon degisimi / <500 ms olu zaman. */
  #observe(now) {
    const fw = this.fw;
    const mask = PhysicalObserver.physicalMask(fw.automation, this.ext, fw.cm.config.ext_module_enabled);
    for (const v of this.observer.observe(now, mask, fw.automation.pairValid)) this.#violation(v.code, v);
  }

  #violation(code, detail) {
    const v = { ...detail, code };
    this.violations.push(v);
    this.event('violation', v);
    if (this.opts.strict) this.fatal = new Error(`interlock ihlali: ${code}`);
  }

  // =========================================================================== komut hatti (postDeviceCommand + QA yavas/dusur kancasi)
  /** Role/panjur komutlarinin TEK giris kapisi (HTTP, MQTT, QA). @returns {boolean} kuyruga yazildi mi */
  postCommand(cmd) {
    const fw = this.fw;
    if (!fw) return false;
    if (cmd.source === CmdSource.WEB) this.counters.http_cmd++;
    if (this.slow.drop) {
      this.event('cmd_dropped_by_qa', { source: cmd.source, cmd: cmd.type });
      return true;
    }
    if (this.slow.delayMs > 0) {
      const t = setTimeout(() => {
        this.timers.delete(t);
        if (this.fw === fw) fw.automation.post(cmd);
      }, this.slow.delayMs);
      this.timers.add(t);
      this.event('cmd_delayed', { source: cmd.source, cmd: cmd.type, delay_ms: this.slow.delayMs });
      return true;
    }
    return fw.automation.post(cmd);
  }

  // =========================================================================== duvar butonlari (DI)
  /** Kuru kontak: closed=true basma, false birakma. Isleme (60 ms suzgec dahil) firmware dongusunde olur. */
  setDi(n, closed) {
    const fw = this.fw;
    if (!fw || this.booting) throw new Error('cihaz kapali/aciliyor');
    if (!Number.isInteger(n) || n < 1 || n > fw.cm.config.totalDIs()) throw new RangeError(`DI numarasi gecersiz: ${n}`);
    if (n <= 8) {
      if (this.rawDi[n - 1] === !!closed) return { changed: false };
      this.rawDi[n - 1] = !!closed;
    } else {
      if (!this.ext.present) throw new RangeError(`ek modul yok: DI ${n}`);
      if (this.ext.rawDi[n - 9] === !!closed) return { changed: false };
      this.ext.rawDi[n - 9] = !!closed;
    }
    this.counters.di_edges++;
    return { changed: true };
  }

  /** Basip birakir (holdMs sonra). Birakma zamanlayicisi stop()'ta temizlenir. */
  pressDi(n, holdMs) {
    const hold = Math.max(n > 8 ? 300 : 100, Number.isFinite(holdMs) ? holdMs : (n > 8 ? 400 : 150));
    const r = this.setDi(n, true);
    const t = setTimeout(() => {
      this.timers.delete(t);
      try { this.setDi(n, false); } catch (_) { /* yok say */ }
    }, hold);
    this.timers.add(t);
    return r;
  }

  // =========================================================================== QA kontrolleri
  /** MQTT baglantisini ANORMAL keser (soket yok edilir) -> broker LWT 'offline' yayinlar. online'a kadar kapali kalir. */
  forceOffline() {
    this.event('qa_offline', {});
    this.fw?.mqtt.qaForceOffline();
  }

  forceOnline() {
    this.event('qa_online', {});
    this.fw?.mqtt.qaForceOnline();
  }

  /** Sessiz kayip: temiz DISCONNECT (broker LWT YAYINLAMAZ) ve 'offline' de yayinlanmaz -> retained 'online' bayat kalir. */
  crash() {
    this.event('qa_crash', {});
    this.fw?.mqtt.qaCrash();
  }

  /** Guc kesintisi + yeniden acilis: soket yok olur (LWT), roleler OFF, panjurlar durur; konumlar yalniz NVS'e yazildigi kadar korunur. */
  powerCycle() {
    this.event('qa_power_cycle', { boot_ms: this.opts.bootMs });
    const fw = this.fw;
    if (fw) fw.mqtt.qaForceOffline();
    this.ext.coils.fill(false);
    this.#scheduleColdBoot(this.opts.bootMs, 'power');
  }

  /** Planli yeniden baslatma (POST /api/system/reboot ile ayni yol). */
  softReboot() {
    const fw = this.fw;
    if (!fw) return;
    fw.automation.requestRestart(0, this.millis());
  }

  /** QA: tamamen fabrika durumu (NVS silinir: kimlik, Wi-Fi, MQTT dahil) ve komut satiri yapilandirmasina donus. */
  factoryReset() {
    this.event('qa_factory_reset', {});
    const fw = this.fw;
    if (fw) fw.mqtt.qaForceOffline();
    this.nvs.eraseAll();
    this.ext.coils.fill(false);
    this.#scheduleColdBoot(this.opts.bootMs, 'factory');
  }

  /** QA: yalniz yerel anahtari siler (seri CLI RESETKEY gibi) -> cihaz provizyonsuz olur. */
  unprovision() {
    const fw = this.fw;
    if (!fw) return;
    fw.cm.clearLocalKey();
    fw.portal.auth.clear();
    fw.portal.apConnect.clear();
    fw.wifi.applyApConfigChange();   // provizyon durumu degisti: acik AP ilkesi yeniden degerlendirilir (firmware CLI RESETKEY'in AP ilkesine etkisi)
    this.event('qa_unprovisioned', {});
  }

  /** QA: provizyonsuzsa factory/init gibi yazar (ayni atomik cm.provisionIfEmpty); provizyonluysa yerel anahtari degistirir (rekey gibi). */
  qaProvision(localKey, apPass) {
    const fw = this.fw;
    if (!fw) return { ok: false, status: 503, error: 'booting' };
    if (!isValidLocalKey(localKey)) return { ok: false, status: 400, error: 'invalid_key' };
    if (fw.cm.hasLocalKey()) {
      if (!fw.cm.setLocalKey(localKey)) return { ok: false, status: 503, error: 'storage' };
      this.event('rekeyed', {});
      return { ok: true, rekeyed: true };
    }
    const ap = isValidApPass(apPass) ? apPass : `ap-${localKey}-pass`.slice(0, 32);
    const r = fw.cm.provisionIfEmpty(localKey, ap);
    if (r !== ProvisionResult.OK) return { ok: false, status: r === ProvisionResult.STORAGE ? 503 : 400, error: r };
    fw.wifi.applyApConfigChange();
    this.event('provisioned', {});
    return { ok: true };
  }

  setSlow({ delay_ms: delayMs = 0, drop = false } = {}) {
    this.slow = { delayMs: Math.max(0, Math.min(60000, Number(delayMs) || 0)), drop: !!drop };
    this.event('qa_slow', { delay_ms: this.slow.delayMs, drop: this.slow.drop });
    return this.slow;
  }

  /**
   * QA: sahte ev Wi-Fi dunyasi: `up` ev aginin acik/kapali olmasi (yonlendirici arizasi); `silent` baglanma denemeleri HIC sonuclanmaz (15 sn STA /
   * 25 sn aday zaman asimi: eski kimlige donus sinanir); `auth_fail_reason` yanlis parolada rapor edilen neden (2 | 15 | 202 | 204).
   */
  setWifiWorld({ up, silent, auth_fail_reason: authFailReason } = {}) {
    if (authFailReason !== undefined && !AUTH_FAIL_REASONS.includes(authFailReason)) throw new RangeError(`auth_fail_reason ${AUTH_FAIL_REASONS.join('|')} olmali`);
    if (silent !== undefined && typeof silent !== 'boolean') throw new RangeError('silent boolean olmali');
    if (typeof up === 'boolean') {
      this.world.up = up;
      this.event('qa_wifi_world', { up });
      if (!up && this.fw) this.fw.wifi.tick(this.millis());
    }
    if (typeof silent === 'boolean') {
      this.world.silent = silent;
      this.event('qa_wifi_world', { silent });
    }
    if (authFailReason !== undefined) {
      this.world.authFailReason = authFailReason;
      this.event('qa_wifi_world', { auth_fail_reason: authFailReason });
    }
    return { up: this.world.up, silent: this.world.silent, auth_fail_reason: this.world.authFailReason };
  }

  // =========================================================================== istemci ag konumu (WP-W1: AP kaynakli yetki)
  /**
   * HTTP istemcisinin cihaza gore "uzak IP"si (firmware: WiFiServer client().remoteIP()). Gercek soket adresi hep 127.0.0.1 oldugundan AG KONUMU
   * modellenir: 'ap' -> SoftAP DHCP istemcisi (192.168.4.2); 'lan' -> STA alt agindaki baska bir konak (STA ile ayni /24, .20). `remote_ip` ile gecersiz kilinabilir.
   */
  clientRemoteIp() {
    const cn = this.clientNet;
    if (cn.remoteIp) return cn.remoteIp;
    if (cn.mode === 'ap') return CLIENT_AP_IP;
    // ilk sekizli en dusuk bayttir (IPAddress -> uint32_t): SON sekizli en yuksek bayt
    const sta = ipToU32(this.staIp);
    const last = (sta >>> 24) & 255;
    return u32ToIp(((sta & 0x00FFFFFF) | ((last === 20 ? 21 : 20) << 24)) >>> 0);
  }

  #syncClientNet() {
    const fw = this.fw;
    if (!fw) return;
    fw.wifi.apClientHint = this.clientNet.mode === 'ap';
    fw.wifi.apClientsOverride = this.clientNet.apClients;
  }

  /**
   * QA: servis AP penceresini (seri CLI "AP ON" / "AP OFF") acar/kapatir. open=true: WPA2 servis AP'si `window_ms` (varsayilan 10 dk) acilir -- YALNIZ gecerli
   * ap_pass varsa veya cihaz provizyonsuzsa (firmware kurali); open=false: AP kapanir ve kurtarma pencereleri iptal olur (15 dk yeniden acma beklemesi).
   * Istek wifi_task'a birakilir (bir sonraki Wi-Fi tick'inde uygulanir). Uzun QA oturumlarinda sona eren AP penceresini yeniden acmak icindir.
   */
  setServiceAp({ open, window_ms: windowMs } = {}) {
    const fw = this.fw;
    if (!fw) throw new RangeError('cihaz aciliyor');
    if (typeof open !== 'boolean') throw new RangeError('open boolean olmali');
    if (open) {
      const ms = windowMs === undefined ? 600000 : windowMs;
      if (!Number.isInteger(ms) || ms < 1000 || ms > 3600000) throw new RangeError('window_ms 1000..3600000 tamsayi olmali');
      fw.wifi.openServiceAp(this.millis(), ms);
    } else {
      fw.wifi.stopRecoveryAP();
    }
    this.event('qa_service_ap', { open, window_ms: open ? (windowMs ?? 600000) : null });
    return { requested: open ? 'open' : 'close', active: fw.wifi.isRecoveryApActive(), secured: fw.wifi.isRecoveryApSecured(), ssid: fw.wifi.getRecoveryApSSID() };
  }

  /** QA: istemci ag konumu (mode: 'ap' | 'lan'), istege bagli acik uzak IP ve SoftAP istasyon sayisi (ap_clients; null = moddan tureti). */
  setClientNet({ mode, remote_ip: remoteIp, ap_clients: apClients } = {}) {
    const cn = this.clientNet;
    if (mode !== undefined) {
      if (!CLIENT_NET_MODES.includes(mode)) throw new RangeError('mode: ap | lan');
      cn.mode = mode;
      cn.remoteIp = null;   // mod degisince acik IP gecersiz kilma sifirlanir
    }
    if (remoteIp !== undefined) {
      if (remoteIp !== null && !ipToU32(remoteIp)) throw new RangeError('remote_ip gecerli IPv4 olmali');
      cn.remoteIp = remoteIp;
    }
    if (apClients !== undefined) {
      // firmware startAp: WiFi.softAP(..., kanal 1, gizli degil, max_connection = 3)
      if (apClients !== null && (!Number.isInteger(apClients) || apClients < 0 || apClients > 3)) throw new RangeError('ap_clients 0..3 veya null olmali');
      cn.apClients = apClients;
    }
    this.#syncClientNet();
    this.event('qa_client_net', { mode: cn.mode, remote_ip: this.clientRemoteIp(), ap_clients: cn.apClients });
    return this.qaClientNet();
  }

  /** QA: istemci ag konumunun ozeti + firmware kararinin girdileri (anahtar degeri YOK). */
  qaClientNet() {
    const fw = this.fw;
    const cn = this.clientNet;
    const wifi = fw ? fw.wifi : null;
    const remote = this.clientRemoteIp();
    return {
      mode: cn.mode,
      remote_ip: remote,
      remote_ip_override: cn.remoteIp,
      ap_clients_override: cn.apClients,
      on_softap: wifi ? clientOnSoftAp(wifi.isRecoveryApActive(), ipToU32(remote), ipToU32(wifi.apIp()), ipToU32(wifi.apMask()), ipToU32(wifi.getLocalIP()), ipToU32(wifi.staMask())) : false,
      ap_ip: AP_IP,
      sta_ip: this.staIp,
    };
  }

  /**
   * QA: role surucusu (I2C) ve ek modul yazma arizasi enjeksiyonu. `i2c`: hat tamamen olu (boolean); `ext_module`: ek modul susar (boolean);
   * `tca_fail_reads` / `tca_fail_writes`: bir sonraki N TCA9554 yazmac okuma/yazma erisimi gecici basarisiz olur (tamsayi >= 0; firmware'in
   * "3 deneme" yeniden deneme mantigini sinar: 1-2 hata tolere edilir, 3 hata "okunamadi/yazilamadi" olur).
   * `nvs_fail_keys`: yazmasi/silmesi basarisiz olacak NVS kimlik anahtarlari (dizi; yalniz 'lk' | 'ap_pw'; [] arizayi kaldirir). Bozuk/dolu NVS
   * modeli: factory/init ve rekey 503 {"error":"storage"} doner (SERVIS-03). Ariza yeniden acilista da surer (donanim durumu).
   */
  setHwFail({ i2c, ext_module, tca_fail_reads: failReads, tca_fail_writes: failWrites, nvs_fail_keys: nvsFailKeys } = {}) {
    for (const [k, v] of [['tca_fail_reads', failReads], ['tca_fail_writes', failWrites]]) {
      if (v !== undefined && (!Number.isInteger(v) || v < 0 || v > 1000)) throw new RangeError(`${k} 0..1000 tamsayi olmali`);
    }
    if (nvsFailKeys !== undefined && (!Array.isArray(nvsFailKeys) || !nvsFailKeys.every((k) => NVS_FAILABLE_KEYS.includes(k)))) {
      throw new RangeError(`nvs_fail_keys dizi olmali (${NVS_FAILABLE_KEYS.join(' | ')})`);
    }
    if (typeof i2c === 'boolean' && this.fw) this.fw.automation.tca.i2cFail = i2c;
    if (typeof ext_module === 'boolean') this.ext.failWrites = ext_module;
    if (failReads !== undefined && this.fw) this.fw.automation.tca.failReads = failReads;
    if (failWrites !== undefined && this.fw) this.fw.automation.tca.failWrites = failWrites;
    if (nvsFailKeys !== undefined) this.nvs.failKeys = new Set(nvsFailKeys);
    const out = this.#hwFail();
    this.event('qa_hw_fail', out);
    return out;
  }

  #hwFail() {
    const t = this.fw ? this.fw.automation.tca : null;
    return {
      i2c: t ? t.i2cFail : null, ext_module: this.ext.failWrites, tca_fail_reads: t ? t.failReads : null, tca_fail_writes: t ? t.failWrites : null,
      nvs_fail_keys: [...this.nvs.failKeys].sort(),
    };
  }

  /** QA: ek modul donanimini degistirir (var/yok, Modbus adresi, baud, kanal sayisi). Gecersiz deger RangeError. */
  setExt({ present, address, baud, channels } = {}) {
    const x = this.ext;
    if (typeof present === 'boolean') x.present = present;
    if (address !== undefined) {
      if (!Number.isInteger(address) || address < 1 || address > 247) throw new RangeError('gecersiz modbus adresi (1..247)');
      x.address = address;
    }
    if (baud !== undefined) {
      if (!RS485_BAUDS.includes(baud)) throw new RangeError(`gecersiz baud (${RS485_BAUDS.join(', ')})`);
      x.baud = baud;
    }
    if (channels !== undefined) {
      if (!Number.isInteger(channels) || channels < 1 || channels > 32) throw new RangeError('gecersiz kanal sayisi (1..32)');
      x.channels = channels;
    }
    this.event('qa_ext', { present: x.present, address: x.address, baud: x.baud, channels: x.channels });
    return { present: x.present, address: x.address, baud: x.baud, channels: x.channels };
  }

  /** QA: yerel role cipi (TCA9554) arizasi: chip_reset (brown-out), stuck_on (role kendiliginden ceker), drop (role duser). relay: 1..8 */
  tcaFault({ action, relay } = {}) {
    const fw = this.fw;
    if (!fw) throw new RangeError('cihaz aciliyor');
    const t = fw.automation.tca;
    const bit = () => {
      if (!Number.isInteger(relay) || relay < 1 || relay > 8) throw new RangeError('relay 1..8 olmali');
      return 1 << (relay - 1);
    };
    if (action === 'chip_reset') t.qaChipReset();
    else if (action === 'stuck_on') t.qaForceLatchOn(bit());
    else if (action === 'drop') t.qaDropLatch(bit());
    else throw new RangeError('action: chip_reset | stuck_on | drop');
    this.event('qa_tca_fault', { action, relay });
    return { latch: t.latch, shadow: t.shadow };
  }

  // =========================================================================== guvenlik katmani: hata enjeksiyonu (spec 5.4, WP-Q1; firmware'de YOK)
  #sensorCfg(id) {
    const fw = this.fw;
    if (!fw || !fw.automation.safetyOn) throw new Error('guvenlik katmani yok');
    const sid = parseSensorId(String(id));
    if (!sid) throw new RangeError(`sensor kimligi gecersiz: ${id}`);
    const c = fw.automation.safety.copyConfig();
    const s = c.sens.slice(0, c.nSens).find((x) => x.src === sid.src && x.index === sid.index);
    return { sid, cfg: s || null };
  }

  /** Sensoru islak/kuru yapar (DI: NC sensorde kontak ACILIR; kopru: rapor). Kopru raporu her 5 sn tekrarlanir (bridgeSilence durdurur). */
  setSensor(id, wet) {
    const { sid, cfg } = this.#sensorCfg(id);
    if (sid.src === SensorSrc.DI) {
      const nc = cfg ? cfg.active_open === 1 : false;
      return this.setDi(sid.index, nc ? !wet : !!wet);
    }
    this.bridgeFeed.set(sid.index, !!wet);
    this.#bridgeReport(sid.index);
    return { changed: true };
  }

  /** Kapi/pencere kontagi (Faz 2 F2.B.11): open=true kontak ACILIR (NC sensorde DI kontagi acik). setSensor'un hirsiz sensoru adi. */
  setContact(id, open) { return this.setSensor(id, open); }

  #bridgeReport(slot) {
    const fw = this.fw;
    if (!fw || !this.bridgeFeed.has(slot)) return;
    fw.automation.safety.postBridgeReport({ slot, active: this.bridgeFeed.get(slot), ok: true, at_ms: this.millis() });
    this.lastBridgeReport = this.millis();
  }

  /** Kopru yuvasinin raporlarini keser (kalp atisi asilinca sensor ok=false olur). */
  bridgeSilence(slot) { this.bridgeFeed.delete(slot); this.event('qa_bridge_silence', { slot }); }

  /** Damla: onMs islak / offMs kuru, n kez. @returns {Promise<void>} */
  pulseSensor(id, onMs, offMs, n) {
    return new Promise((resolve) => {
      let k = 0;
      const step = (wet) => {
        if (this.stopped) { resolve(); return; }
        try { this.setSensor(id, wet); } catch (_) { /* aciliyor */ }
        if (!wet && ++k >= n) { resolve(); return; }
        const t = setTimeout(() => { this.timers.delete(t); step(!wet); }, (wet ? onMs : offMs));
        this.timers.add(t);
      };
      step(true);
    });
  }

  /**
   * Vana geri bildirim DI'si modeli: 'follow' = vana role seviyesini delayMs sonra izler (kapali konumda kontak "kapali" bildirir),
   * 'stuck_open' = hep "acik" bildirir, 'none' = modeli kaldirir (DI degismez).
   */
  setValveFeedback(actId, mode, delayMs = 0) {
    const fw = this.fw;
    if (!fw || !fw.automation.safetyOn) throw new Error('guvenlik katmani yok');
    const i = parseActuatorId(String(actId));
    const c = fw.automation.safety.copyConfig();
    if (i === null || i >= c.nAct || !c.act[i].fb_di) throw new RangeError(`geri bildirimli vana degil: ${actId}`);
    if (!['follow', 'stuck_open', 'none'].includes(mode)) throw new RangeError('mode: follow | stuck_open | none');
    if (mode === 'none') this.valveFb.delete(i);
    else this.valveFb.set(i, { mode, delayMs, closed: null, since: this.millis() });
    this.event('qa_valve_fb', { actuator: i + 1, mode, delay_ms: delayMs });
    return { actuator: i + 1, mode };
  }

  #serviceValveFb(now) {
    const fw = this.fw;
    if (!fw || !fw.automation.safetyOn || this.valveFb.size === 0) return;
    const c = fw.automation.safety.copyConfig();
    const snap = fw.automation.getSnapshot();
    for (const [i, m] of this.valveFb) {
      const a = c.act[i];
      if (!a) continue;
      const closedNow = m.mode === 'stuck_open' ? false : (!!snap.relays[a.relay - 1] === relayLevelFor(a, true));
      if (m.closed !== closedNow) { m.closed = closedNow; m.since = now; }
      if (u32(now - m.since) < m.delayMs) continue;
      const contact = a.fb_closed_active ? closedNow : !closedNow;
      try { this.setDi(a.fb_di, contact); } catch (_) { /* yok say */ }
    }
  }

  /** Guvenlik yapilandirmasinin NVS kaydini bozar (CRC) ve guc keser: acilista guvenli kip (cfg_corrupt). */
  corruptSafetyCfg() {
    const s = this.nvs.get('safety');
    if (s) this.nvs.put('safety', { ...s, crc: (s.crc ^ 0x5a5a5a5a) >>> 0 });
    this.event('qa_safety_cfg_corrupted', {});
    this.powerCycle();
  }

  /** Ek modul ms boyunca yanit vermez (RS485 kablosu cekildi). */
  extModuleDown(ms) {
    this.setHwFail({ ext_module: true });
    const t = setTimeout(() => { this.timers.delete(t); this.setHwFail({ ext_module: false }); }, ms);
    this.timers.add(t);
  }

  /** Sonraki n event_ack komutu cihazda yok sayilir (onay kaybi). */
  dropEventAcks(n) { if (this.fw) this.fw.mqtt.qaDropAcks = n; this.event('qa_drop_event_acks', { n }); }

  /** Broker baglantisi ms boyunca kesilir (LWT), sonra yeniden baglanir. */
  brokerDown(ms) {
    this.forceOffline();
    const t = setTimeout(() => { this.timers.delete(t); this.forceOnline(); }, ms);
    this.timers.add(t);
  }

  /** Elektrik gitti/geldi (NVS korunur). */
  reboot() { this.powerCycle(); }

  /** Yazilimsal yeniden baslatma (shutdown kancasi dahil). */
  softRestart() { this.softReboot(); }

  /** /__sim/safety govdesi: {sensor, wet} | {pulse:{id,on_ms,off_ms,n}} | {valve_fb:{actuator,mode,delay_ms}} | {corrupt_cfg:true} |
   *  {ext_down_ms} | {drop_acks} | {broker_down_ms} | {bridge_silence} */
  qaSafety(b = {}) {
    if (b.sensor !== undefined) return this.setSensor(b.sensor, !!b.wet);
    if (b.pulse) { this.pulseSensor(b.pulse.id, b.pulse.on_ms, b.pulse.off_ms, b.pulse.n); return { ok: true }; }
    if (b.valve_fb) return this.setValveFeedback(b.valve_fb.actuator, b.valve_fb.mode, b.valve_fb.delay_ms || 0);
    if (b.corrupt_cfg) { this.corruptSafetyCfg(); return { ok: true }; }
    if (b.ext_down_ms !== undefined) { this.extModuleDown(b.ext_down_ms); return { ok: true }; }
    if (b.drop_acks !== undefined) { this.dropEventAcks(b.drop_acks); return { ok: true }; }
    if (b.broker_down_ms !== undefined) { this.brokerDown(b.broker_down_ms); return { ok: true }; }
    if (b.bridge_silence !== undefined) { this.bridgeSilence(b.bridge_silence); return { ok: true }; }
    throw new RangeError('bilinmeyen guvenlik enjeksiyonu');
  }

  /** QA: guvenlik katmaninin ozeti (gorunum + olay kutusu). */
  qaSafetyState() {
    const fw = this.fw;
    if (!fw || !fw.automation.safetyOn) return null;
    const s = fw.automation.safety;
    return { view: s.copyView(), mode: s.mode, latched_mask: s.latchedMask, outbox: s.outbox.list().map((x) => ({ eid: x.eid, type: x.ev.type })), last_rej: s.lastReject() };
  }

  /** /__sim/state: ic durumun tamami (anahtar degerleri YOK). */
  qaState() {
    const now = this.millis();
    const fw = this.fw;
    if (!fw) return { uid: this.uid, mac: this.mac, booting: true, violations: this.violations.slice(-20), violation_count: this.violations.length, counters: { ...this.counters } };
    const a = fw.automation;
    const cfg = fw.cm.config;
    const snap = a.getSnapshot();
    const total = cfg.totalRelays();
    const lock = fw.portal.authSummary(now);
    const cs = fw.wifi.getConnectStatus();
    return {
      uid: this.uid,
      device_uid: fw.wifi.getDeviceUid(),
      mac: this.mac,
      provisioned: fw.cm.hasLocalKey(),
      booting: this.booting,
      uptime_sec: this.uptimeSec(),
      time_scale: this.timeScale,
      relays: Array.from({ length: total }, (_, i) => ({ id: i + 1, name: cfg.relays[i].name, type: cfg.relays[i].type, state: !!snap.relays[i], runtime_sec: cfg.relays[i].runtime_sec })),
      shutters: Array.from({ length: Math.floor(total / 2) }, (_, p) => a.internalShutter(p, now)).filter((s) => s.configured),
      di: snap.dis.slice(0, cfg.totalDIs()),
      di_raw: this.rawDi.slice(0, Math.min(8, cfg.totalDIs())),
      child_lock: snap.childLock,
      mqtt: fw.mqtt.qaState(now),
      wifi: {
        connected: fw.wifi.isConnected(),
        connecting: fw.wifi.isConnecting(),
        ssid: fw.wifi.getSSID(),
        ip: fw.wifi.getLocalIP(),
        rssi: fw.wifi.getRSSI(),
        last_reason: fw.wifi.getLastDisconnectReason(),
        connect_state: ['idle', 'connecting', 'success', 'failed'][cs.state],
        connect_reason: cs.reason,
        ap_active: fw.wifi.isRecoveryApActive(),
        ap_secured: fw.wifi.isRecoveryApSecured(),   // AP su an FIILEN WPA2 mi (acik kurulum AP'sinde false)
        ap_clients: fw.wifi.apStationCount(),
        ap_ssid: fw.wifi.getRecoveryApSSID(),
        creds_saved: cfg.wifi_sta_enabled && cfg.wifi_ssid !== '',
        time_synced: fw.wifi.isTimeSynced(),
        world_up: this.world.up,
        world_silent: this.world.silent,
      },
      client_net: this.qaClientNet(),
      http_lock: lock,
      http_ap_connect: { used: fw.portal.apConnect.used(), max: 6, window_ms: 60000 },
      ext: {
        present: this.ext.present, address: this.ext.address, baud: this.ext.baud, channels: this.ext.channels, enabled: cfg.ext_module_enabled,
        responding: snap.extModuleResponding, fail_writes: this.ext.failWrites, uart_baud: a.rs485Baud, scan: a.rs485ScanState(),
        coils: this.ext.coils.slice(0, Math.min(32, this.ext.channels)),
      },
      hw_fail: this.#hwFail(),
      tca: { latch: a.tca.latch, shadow: a.tca.shadow },
      slow: this.slow,
      violations: this.violations.slice(-20),
      violation_count: this.violations.length,
      seq: fw.mqtt.seq,
      last_id: snap.lastId,
      recent_ids: fw.mqtt.qaState(now).recent_ids,
      counters: { ...this.counters },
      last_beep: this.lastBeep || null,
      command_queue: a.queue.length,
      fatal: this.fatal ? this.fatal.message : null,
    };
  }
}

// =============================================================================== komut satiri
// node sim/device_sim.js --uid AHBU-S3-0A0001 --relays 8 --http-port 8081 --mqtt-host 127.0.0.1 --mqtt-port 1883 \
//     --mqtt-user d_h_xxx --mqtt-pass '***' --local-key '***' --time-scale 10
export const CLI_OPTIONS = {
  uid: { type: 'string' },
  relays: { type: 'string' },
  'http-port': { type: 'string' },
  'http-host': { type: 'string' },
  'mqtt-host': { type: 'string' },
  'mqtt-port': { type: 'string' },
  'mqtt-user': { type: 'string' },
  'mqtt-pass': { type: 'string' },
  'local-key': { type: 'string' },
  'ap-pass': { type: 'string' },
  'time-scale': { type: 'string' },
  'device-name': { type: 'string' },
  fw: { type: 'string' },
  'home-wifi-ssid': { type: 'string' },
  'home-wifi-pass': { type: 'string' },
  'wifi-connected': { type: 'boolean' },
  'state-file': { type: 'string' },
  'reset-state': { type: 'boolean' },
  'firmware-timing': { type: 'boolean' },
  'millis-offset': { type: 'string' },
  'client-net': { type: 'string' },
  'sta-ip': { type: 'string' },
  'tick-ms': { type: 'string' },
  'boot-ms': { type: 'string' },
  'boot-hold-ms': { type: 'string' },
  'log-file': { type: 'string' },
  strict: { type: 'boolean' },
  help: { type: 'boolean', short: 'h' },
};

export const CLI_HELP = `AHBU cihaz simulatoru (QA) - firmware DEGILDIR (kaynak portlari: docs/QA_STACK.md)
  --uid AHBU-...            cihaz UID (zorunlu). AHBU-S3-<6 hex> = firmware UID bicimi (MAC buradan turetilir)
  --relays 8|16             role sayisi (16 = ek modul, RS485 modeli)  [8]
  --http-port N             yerel HTTP API portu (0 = rastgele)         [0]
  --mqtt-host H --mqtt-port P --mqtt-user U --mqtt-pass S
                            bulut kimligi (yoksa POST /api/mqtt/config ile alinir)
  --local-key K             X-Device-Key (8..32 karakter). YOKSA PROVIZYONSUZ MOD
  --time-scale N            panjur yol/overrun sureleri N kat hizli (olu zaman 500 ms sabit) [1]
  --home-wifi-ssid S --home-wifi-pass P   sahte ev Wi-Fi agi (baglanma dogrulamasi)
  --wifi-connected          ev agina bagli basla (ilk acilis)
  --state-file F            kalici "NVS" dosyasi; --reset-state onu siler
  --firmware-timing         MQTT yeniden baglanma gercek firmware degerleriyle (5 sn..5 dk, jitter); varsayilan hizli (2..10 sn)
  --millis-offset N         millis() sayacini N ms ileri baslatir (49,7 gun tasma testi)
  --client-net ap|lan       HTTP istemcisinin ag konumu modeli (AP kaynakli Wi-Fi servis yetkisi icin): ap = cihazin SoftAP'inde, lan = ev aginda.
                            Varsayilan: --wifi-connected ise lan, degilse ap (ayrica /__sim/client-net)
  --sta-ip A.B.C.D          STA adresi (varsayilan 192.168.1.30..129); 192.168.4.x = "ev modemi de 192.168.4.0/24" cakisma senaryosu
  --tick-ms N               ana dongu adimi [10]    --boot-ms N  guc kesintisi sonrasi acilis suresi [800]
  --boot-hold-ms N          acilis sonrasi komut islenmeyen pencere (firmware 500) [500]
  --log-file F              olay logu
  --strict                  interlock ihlalinde fatal isaretle
QA kontrol ucu (yalniz 127.0.0.1): /__sim/state, /__sim/log, /__sim/di/{n}/press|down|up, /__sim/offline|online|crash|power-cycle|slow|wifi|client-net|ap|hw-fail|ext|tca|provision|unprovision|factory-reset
`;

/** parseArgs ciktisini DeviceSimulator seceneklerine cevirir. */
export function optionsFromCli(values) {
  const num = (v, name) => {
    if (v === undefined) return undefined;
    const n = Number(v);
    if (!Number.isFinite(n)) throw new Error(`--${name} sayi olmali`);
    return n;
  };
  const o = { uid: values.uid };
  if (values.relays !== undefined) o.relays = num(values.relays, 'relays');
  if (values['http-port'] !== undefined) o.httpPort = num(values['http-port'], 'http-port');
  if (values['http-host']) o.httpHost = values['http-host'];
  if (values['mqtt-host']) {
    o.mqtt = { host: values['mqtt-host'], port: num(values['mqtt-port'], 'mqtt-port') ?? 1883, user: values['mqtt-user'], pass: values['mqtt-pass'] };
  }
  if (values['local-key']) o.localKey = values['local-key'];
  if (values['ap-pass']) o.apPass = values['ap-pass'];
  if (values['time-scale'] !== undefined) o.timeScale = num(values['time-scale'], 'time-scale');
  if (values['device-name']) o.deviceName = values['device-name'];
  if (values.fw) o.fw = values.fw;
  if (values['home-wifi-ssid'] || values['home-wifi-pass']) {
    o.homeWifi = { ssid: values['home-wifi-ssid'] || HOME_WIFI_SSID, pass: values['home-wifi-pass'] || '' };
  }
  if (values['wifi-connected']) o.wifiConnected = true;
  if (values['state-file']) o.stateFile = values['state-file'];
  if (values['reset-state']) o.resetState = true;
  if (values['firmware-timing']) o.firmwareTiming = true;
  if (values['millis-offset'] !== undefined) o.millisOffset = num(values['millis-offset'], 'millis-offset');
  if (values['client-net'] !== undefined) o.clientNet = values['client-net'];
  if (values['sta-ip'] !== undefined) o.staIp = values['sta-ip'];
  if (values['tick-ms'] !== undefined) o.tickMs = num(values['tick-ms'], 'tick-ms');
  if (values['boot-ms'] !== undefined) o.bootMs = num(values['boot-ms'], 'boot-ms');
  if (values['boot-hold-ms'] !== undefined) o.bootHoldMs = num(values['boot-hold-ms'], 'boot-hold-ms');
  if (values.strict) o.strict = true;
  return o;
}

async function cliMain() {
  const { parseArgs } = await import('node:util');
  const { createLogger } = await import('../lib/util.js');
  let parsed;
  try {
    parsed = parseArgs({ options: CLI_OPTIONS, allowPositionals: false });
  } catch (e) {
    console.error(`hata: ${e.message}\n\n${CLI_HELP}`);
    process.exit(2);
  }
  if (parsed.values.help || !parsed.values.uid) {
    console.log(CLI_HELP);
    process.exit(parsed.values.help ? 0 : 2);
  }
  let sim;
  try {
    const opts = optionsFromCli(parsed.values);
    opts.log = createLogger(parsed.values['log-file'] || null, { echo: !parsed.values['log-file'] });
    sim = new DeviceSimulator(opts);
  } catch (e) {
    console.error(`hata: ${e.message}`);
    process.exit(2);
  }
  await sim.start();
  console.log(`[sim] ${sim.uid} http://${sim.opts.httpHost}:${sim.httpPort} relays=${sim.totalRelays()} provisioned=${sim.isProvisioned()} mqtt=${sim.mqttCfg ? 'yapilandirildi' : 'yok'}`);
  let stopping = false;
  const stop = async () => {
    if (stopping) return;
    stopping = true;
    await sim.stop();
    process.exit(0);
  };
  for (const sig of ['SIGINT', 'SIGTERM', 'SIGBREAK']) process.on(sig, stop);
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  cliMain().catch((e) => { console.error(e); process.exit(1); });
}

