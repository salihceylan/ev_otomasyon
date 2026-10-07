// WiFiManager.cpp (firmware) JavaScript modeli: STA baglantisi, aday kimlik (POST /api/wifi/connect), kurtarma/kurulum AP penceresi, SNTP.
//
// Gercek radyo yoktur: "dunya" (WifiWorld) hangi aglarin var oldugunu ve parolalarini bilir; baglanma denemesi `connectMs` sonra sonuclanir
// (basari: GOT_IP; basarisizlik: neden kodu 201 ag yok / 202 (2/15/204) yanlis parola / 200 sinyal kaybi). Durum makineleri firmware ile ayni
// kaynaktan portludur: STA = NetUtil::StaMachine, aday akisi = CandidateFlow (0,5 sn -> eski baglantiyi birak 0,4 sn -> baglan, 25 sn zaman
// asimi -> COMMIT | FAILED), AP penceresi = ApPolicy (3 dk kesinti -> 10 dk pencere, istemci varsa 2 dk'lik adimlarla en fazla 30 dk, STA 30 sn
// kararli -> erken kapanis) -- hepsi sim/fw/net_time.js (NetTime.h portu). Kimligin YALNIZCA dogrulaninca NVS'e islenmesi firmware ile aynidir.
//
// ZAMAN KURALI (CONTRACTS 3c): saklanmis hedef zaman YOK; her zamanlayici "son olay + bekleme" cifti (Wait) ve her tur yoklanir. Diger gorevler
// (WebPortal, MqttManager) yalniz ISTEK BAYRAGI birakir; zamanlayicilari yalniz tick() (wifi_task) degistirir.
//
// Yeni (FW-net / WP-W1, CONTRACTS 3d): isRecoveryApSecured() -- AP su an GERCEKTEN WPA2 mi (startAp parolayla -> true, stopAp -> false; acik
// kurulum AP'sinde false). WebPortal'in AP kaynakli yetkisi "AP su an WPA2" kosulunu buradan okur (yapilandirmadan degil, fiilen yayindaki kipten).
// AP'ye bagli istemci sayisi (WiFi.softAPgetStationNum) QA'dan modellenir (apClients): ApPolicy pencere uzatmasi ve "AP istemcisi varken STA
// denemesi yapilmaz" kurali bunu kullanir.
//
// Saat disaridan verilir (tick(now)); gercek zamanlayici yoktur.
import { sanitizeUtf8, cStrLen } from './netutil.js';
import { AP_PASS_MIN_LEN } from './sysconfig.js';
import {
  ApPolicy, CandidateFlow, CandPhase, CandAction, StaMachine, StaState, StaAction, Wait, u32,
} from './net_time.js';

export const TASK_TICK_MS = 250;
export const ATTEMPT_TIMEOUT_MS = StaMachine.ATTEMPT_TIMEOUT_MS;
export const CANDIDATE_TIMEOUT_MS = CandidateFlow.TIMEOUT_MS;
export const CANDIDATE_START_DELAY_MS = CandidateFlow.START_DELAY_MS;
export const CANDIDATE_DISCONNECT_WAIT_MS = CandidateFlow.DISCONNECT_WAIT_MS;
export const AP_EXTEND_STEP_MS = ApPolicy.EXTEND_STEP_MS;
export const AP_RESTART_DELAY_MS = ApPolicy.RESTART_DELAY_MS;
export const RECOVERY_TRIGGER_MS = ApPolicy.RECOVERY_TRIGGER_MS;
export const SERVICE_AP_WINDOW_MS = ApPolicy.WINDOW_MS;
export const AP_REOPEN_MS = ApPolicy.REOPEN_MS;
export const AP_MAX_EXTEND_MS = ApPolicy.MAX_EXTEND_MS;
export const STA_STABLE_MS = ApPolicy.STABLE_MS;
export const MIN_BACKOFF_MS = StaMachine.MIN_BACKOFF_MS;
export const MAX_BACKOFF_MS = StaMachine.MAX_BACKOFF_MS;
// firmware WiFiManager.h FW_VERSION (test/sim_device.test.js "surum:" testi esitligi denetler)
export const FW_VERSION_DEFAULT = '1.2.0';

/** SoftAP ag bilgisi (firmware startAp: 192.168.4.1/24) */
export const AP_IP = '192.168.4.1';
export const AP_MASK = '255.255.255.0';
export const STA_MASK = '255.255.255.0';

// wifi_err_reason_t alt kumesi
export const WIFI_REASON = Object.freeze({
  UNSPECIFIED: 1, AUTH_EXPIRE: 2, ASSOC_LEAVE: 8, HANDSHAKE_TIMEOUT_4WAY: 15, BEACON_TIMEOUT: 200, NO_AP_FOUND: 201, AUTH_FAIL: 202, HANDSHAKE_TIMEOUT: 204,
});
/** Yanlis parola nedenleri (servis uygulamasi 2, 15, 202, 204'u "sifre" sayar) */
export const AUTH_FAIL_REASONS = Object.freeze([2, 15, 202, 204]);

export const ConnectState = Object.freeze({ IDLE: 0, CONNECTING: 1, SUCCESS: 2, FAILED: 3 });
export const ConnectRequest = Object.freeze({ ACCEPTED: 0, INVALID_SSID: 1, INVALID_PASS: 2, BUSY: 3 });

/** Sahte radyo ortami. SSID'ler ham bayt dizisi (Buffer) olabilir (gecersiz UTF-8 testi). */
export class WifiWorld {
  /**
   * @param {{homeSsid:string, homePass:string, extraNetworks?:Array}} o
   */
  constructor({ homeSsid, homePass = '', extraNetworks = null }) {
    this.homeSsid = homeSsid;
    this.homePass = homePass;
    this.up = true;                       // QA: false = ev agi kapali (yonlendirici arizasi)
    this.silent = false;                  // QA: true = baglanma denemeleri HIC sonuclanmaz (15 sn STA / 25 sn aday zaman asimi sinanir)
    this.authFailReason = WIFI_REASON.AUTH_FAIL;   // QA: yanlis parolada rapor edilen neden (2 | 15 | 202 | 204)
    this.extra = extraNetworks || [
      { ssid: 'Komşu_WiFi_2.4G', rssi: -71, enc: true },
      { ssid: 'Misafir Ağı (Açık)', rssi: -63, enc: false },
      { ssid: Buffer.concat([Buffer.from('Bozuk'), Buffer.from([0xFF, 0xFE]), Buffer.from('Ag')]), rssi: -77, enc: true },
      { ssid: 'Kafe "Dolu";Test', rssi: -80, enc: true },
      { ssid: 'A'.repeat(32), rssi: -85, enc: true },
    ];
  }

  /** Taranabilir aglar (ham). Ev agi yalniz dunya acikken gorunur. */
  scanList() {
    const list = [];
    if (this.up) list.push({ ssid: this.homeSsid, rssi: -48, enc: !!this.homePass, home: true });
    for (const n of this.extra) list.push({ ...n });
    return list;
  }

  static #key(s) { return Buffer.isBuffer(s) ? s.toString('latin1') : Buffer.from(String(s), 'utf8').toString('latin1'); }

  /** @returns {{ok:boolean, reason:number, rssi:number}} */
  attempt(ssid, pass) {
    const key = WifiWorld.#key(ssid);
    const net = this.scanList().find((n) => WifiWorld.#key(n.ssid) === key);
    if (!net) return { ok: false, reason: WIFI_REASON.NO_AP_FOUND, rssi: 0 };
    if (!net.enc) return { ok: pass === '', reason: pass === '' ? 0 : this.authFailReason, rssi: net.rssi };
    if (net.home && this.homePass && pass === this.homePass) return { ok: true, reason: 0, rssi: net.rssi };
    return { ok: false, reason: this.authFailReason, rssi: 0 };
  }
}

export class WifiManager {
  /**
   * @param {object} o
   * @param {import('./config_manager.js').ConfigManager} o.config
   * @param {WifiWorld} o.world
   * @param {string} o.mac       "AA:BB:CC:DD:EE:FF"
   * @param {string} o.staIp
   * @param {{event?:Function}} [o.hooks]
   * @param {{connectMs?:number, scanMs?:number, sntpMs?:number}} [o.timing]
   * @param {string} [o.uidOverride]  QA: firmware UID bicimi (AHBU-S3-<MAC6>) disinda bir UID bildir
   */
  constructor({ config, world, mac, staIp, hooks = {}, timing = {}, uidOverride = '' }) {
    this.cm = config;
    this.uidOverride = uidOverride;
    this.world = world;
    this.mac = mac;
    this.staIpAddr = staIp;
    this.hooks = hooks;
    this.event = (t, f) => this.hooks.event?.(t, f);
    this.timing = { connectMs: 1500, scanMs: 1500, sntpMs: 800, ...timing };

    // ---- Durum (firmware: _mutex ile korunan alanlar)
    this.connected = false;
    this.localIp = '0.0.0.0';
    this.rssi = -100;
    this.ssid = '';                 // kayitli (NVS ile tutarli) STA kimligi
    this.pass = '';
    this.reconnectCount = 0;
    this.connectTimestamp = 0;      // yalniz bilgi
    this.connectSeq = 0;            // her GOT_IP'de artar: "bu denemeden SONRA baglandi mi" sayacla sorulur
    this.lastDisconnectReason = 0;
    this.evtDisconnected = false;
    this.sntpPending = false;
    this.sntp = new Wait();         // QA: SNTP senkronunun sanal gecikmesi
    this.timeSynced = false;

    // ---- Diger gorevlerden gelen istekler (zamanlayicilari YALNIZ tick() degistirir)
    this.reqReconnect = false;
    this.reqStaReset = false;
    this.reqServiceOpen = false;
    this.reqServiceMs = 0;
    this.reqApStop = false;
    this.reqApRestart = false;

    // ---- Otomatik STA baglanma (StaMachine) ve aday kimlik (CandidateFlow)
    this.sta = new StaMachine();
    this.cand = new CandidateFlow();
    this.candActive = false;        // istek kabul edildi ... akis bitti (BUSY ve isConnecting icin)
    this.candStartReq = false;
    this.candCancelReq = false;
    this.candSsid = '';
    this.candPass = '';
    this.candSeq = 0;               // aday denemesi basladiginda connectSeq
    this.candState = ConnectState.IDLE;
    this.candReason = 0;

    // ---- AP (ApPolicy)
    this.ap = new ApPolicy();
    this.apActive = false;
    this.apSecured = false;         // yayindaki AP WPA2 (parolali) mi
    this.apClientsOverride = null;  // QA: WiFi.softAPgetStationNum() (null = istemci aginin kipinden turet: 'ap' kipinde 1)
    this.apClientHint = false;      // DeviceSimulator: HTTP istemcisi SoftAP'de modelleniyor -> 1 istasyon

    this.radio = null;              // bekleyen baglanma denemesi {wait, ssid, pass}
    this.scan = { running: false, wait: new Wait(), results: null };
  }

  begin() {
    const cfg = this.cm.config;
    if (cfg.wifi_sta_enabled && cStrLen(cfg.wifi_ssid) > 0) { this.ssid = cfg.wifi_ssid; this.pass = cfg.wifi_pass; }
    // (3 dk kesinti sayaci ilk tick'te ApPolicy tarafindan baslatilir: acilista kesinti varsayilir.)
    this.event('wifi_begin', { saved_ssid: this.ssid || null });
  }

  // ------------------------------------------------------------------ kimlik / durum
  getDeviceUid() {
    if (this.uidOverride) return this.uidOverride;
    const m = this.mac.replace(/:/g, '').toUpperCase();
    return `AHBU-S3-${m.slice(-6)}`;
  }

  getRecoveryApSSID() { return `AHBU-${this.mac.replace(/:/g, '').toUpperCase().slice(-6)}`; }

  isConnected() { return this.connected; }

  isConnecting() { return this.sta.state === StaState.CONNECTING || this.candActive; }

  getLocalIP() { return this.connected ? this.localIp : '0.0.0.0'; }

  getRSSI() { return this.connected ? this.rssi : -100; }

  getSSID() { return this.ssid; }

  getLastDisconnectReason() { return this.lastDisconnectReason; }

  isTimeSynced() { return this.timeSynced; }

  isRecoveryApActive() { return this.apActive; }

  /** AP su an GERCEKTEN WPA2 (parolali) mi? startAp()'ta parola ile baslarsa true, stopAp()'ta false (acik kurulum AP'sinde false). */
  isRecoveryApSecured() { return this.apActive && this.apSecured; }

  /** WiFi.softAPIP(): AP yayindayken 192.168.4.1, degilse 0.0.0.0 */
  apIp() { return this.apActive ? AP_IP : '0.0.0.0'; }

  /** WiFi.softAPSubnetMask() */
  apMask() { return this.apActive ? AP_MASK : '0.0.0.0'; }

  /** WiFi.subnetMask() (STA bagli degilse 0.0.0.0) */
  staMask() { return this.connected ? STA_MASK : '0.0.0.0'; }

  /** WiFi.softAPgetStationNum() */
  apStationCount() {
    if (!this.apActive) return 0;
    if (this.apClientsOverride !== null) return this.apClientsOverride;
    return this.apClientHint ? 1 : 0;
  }

  getConnectStatus() { return { state: this.candState, reason: this.candReason }; }

  // ------------------------------------------------------------------ olaylar (sanal surucu)
  #onConnected(now, rssi) {
    this.connected = true;
    this.localIp = this.staIpAddr;
    this.rssi = rssi;
    this.connectTimestamp = now || 1;
    this.connectSeq = u32(this.connectSeq + 1);
    this.lastDisconnectReason = 0;   // yeni basarili baglanti: eski hata nedeni gecersiz
    this.sntpPending = true;
    this.sntp.arm(now, this.timing.sntpMs);
    this.event('wifi_connected', { ssid: this.#currentSsid(), ip: this.localIp });
  }

  #currentSsid() { return this.candActive && this.cand.phase === CandPhase.CONNECTING ? this.candSsid : this.ssid; }

  /** ARDUINO_EVENT_WIFI_STA_DISCONNECTED */
  #onDisconnected(reason) {
    const was = this.connected;
    this.connected = false;
    this.localIp = '0.0.0.0';
    if (reason !== 0) this.lastDisconnectReason = reason;
    this.evtDisconnected = true;
    if (was) this.event('wifi_disconnected', { reason });
  }

  /** WiFi.disconnect(false, false): bagliyken STA_DISCONNECTED (ASSOC_LEAVE) olayi uretir; bekleyen deneme iptal edilir. */
  #driverDisconnect() {
    this.radio = null;
    if (this.connected) this.#onDisconnected(WIFI_REASON.ASSOC_LEAVE);
  }

  /** WiFi.begin(): firmware beginSta() */
  #beginSta(ssid, pass, now) {
    this.evtDisconnected = false;
    this.reconnectCount++;
    this.lastDisconnectReason = 0;   // yeni deneme basladi
    const wait = new Wait();
    wait.arm(now, this.timing.connectMs);
    this.radio = { wait, ssid, pass };
  }

  /** QA: ev agi / radyo baglantisi ani kopar (yonlendirici kapandi). */
  qaLinkLost() {
    this.radio = null;
    if (this.connected) this.#onDisconnected(WIFI_REASON.BEACON_TIMEOUT);
  }

  #stepRadio(now) {
    if (!this.radio || this.world.silent) return;
    if (!this.radio.wait.service(now)) return;
    const { ssid, pass } = this.radio;
    this.radio = null;
    const r = this.world.attempt(ssid, pass);
    if (r.ok) this.#onConnected(now, r.rssi);
    else this.#onDisconnected(r.reason || WIFI_REASON.UNSPECIFIED);
  }

  // ------------------------------------------------------------------ gorev (wifi_task)
  tick(now) {
    // bagli iken ev agi kapanirsa baglanti kopar
    if (this.connected && !this.world.up && this.#connectedToHome()) this.qaLinkLost();
    this.#stepRadio(now);
    this.#stepCandidate(now);
    this.#stepSta(now);

    // SNTP: GOT_IP sonrasi bir kez baslatilir (sanal gecikme sntpMs)
    if (this.sntpPending && this.connected && this.sntp.service(now)) {
      this.sntpPending = false;
      this.timeSynced = true;
      this.event('wifi_sntp_synced', {});
    }

    this.#stepAp(now);
  }

  #connectedToHome() { return this.ssid === this.world.homeSsid; }

  // ---- Otomatik STA baglanma (ustel geri cekilme; mantik StaMachine) ----
  #stepSta(now) {
    // Diger gorevlerin istekleri (zamanlayicilari yalniz bu gorev degistirir)
    if (this.reqStaReset) {
      this.reqStaReset = false;
      this.sta.reset();
    }
    if (this.reqReconnect) {
      this.reqReconnect = false;
      this.sta.reconnectNow();
    }
    if (this.candActive) {   // aday deneme sirasinda otomatik yol durur (zamanlayicilar yine yoklanir)
      this.sta.service(now);
      return;
    }
    const { ssid, pass, connected } = this;
    // Kurulum AP'sine bir istemci bagliyken otomatik deneme yapilmaz (tarama AP'yi bozar).
    const apBlocks = this.apActive && this.apStationCount() > 0;
    const a = this.sta.update(now, connected, cStrLen(ssid) > 0, this.evtDisconnected, apBlocks);
    if (a === StaAction.TIMEOUT) {
      // Basarisiz: surucunun tarama/kanal degisimiyle AP'yi bozmamasi icin STA'yi sustur
      this.#driverDisconnect();
      this.event('wifi_sta_attempt_failed', { reason: this.lastDisconnectReason, retry_in_ms: this.sta.retry.span });
    } else if (a === StaAction.BEGIN) {
      this.#beginSta(ssid, pass, now);
    }
  }

  // ------------------------------------------------------------------ aday kimlik (POST /api/wifi/connect)
  /** SSID 1..32 bayt, parola 0 veya 8..63 bayt. Kimlik RAM'de tutulur; ~0,5 sn sonra baglanilir; GOT_IP olunca NVS'e islenir. */
  requestConnect(ssid, pass) {
    if (ssid === null || ssid === undefined) return ConnectRequest.INVALID_SSID;
    const sl = Buffer.byteLength(ssid, 'utf8');
    if (sl < 1 || sl > 32) return ConnectRequest.INVALID_SSID;
    const pl = pass ? Buffer.byteLength(pass, 'utf8') : 0;
    if (pl !== 0 && (pl < 8 || pl > 63)) return ConnectRequest.INVALID_PASS;
    if (this.candActive) return ConnectRequest.BUSY;
    this.candSsid = ssid;
    this.candPass = pass || '';
    this.candState = ConnectState.CONNECTING;   // kabulden hemen sonra durum "connecting" (eski success kalintisi gorunmez)
    this.candReason = 0;
    this.candActive = true;      // tick() akisi ~0,5 sn sonra (HTTP yaniti cikabilsin diye) baslatir
    this.candStartReq = true;
    this.event('wifi_connect_requested', { ssid });
    return ConnectRequest.ACCEPTED;
  }

  #commitCandidate() {
    const s = this.candSsid;
    const p = this.candPass;
    this.ssid = s;
    this.pass = p;
    this.candActive = false;
    this.candState = ConnectState.SUCCESS;
    this.candReason = 0;
    this.candSsid = '';
    this.candPass = '';
    this.sta.markConnected();
    // NVS'e YALNIZCA baglanti dogrulaninca islenir
    const cfg = this.cm.config;
    cfg.wifi_ssid = s;
    cfg.wifi_pass = p;
    cfg.wifi_sta_enabled = true;
    this.cm.save();
    this.event('wifi_candidate_committed', { ssid: s });
  }

  /** Aday akisi (mantik CandidateFlow): 0,5 sn -> eski baglantiyi birak (0,4 sn) -> baglan (25 sn) -> dogrula/geri don. */
  #stepCandidate(now) {
    if (this.candCancelReq) {
      this.candCancelReq = false;
      this.cand.cancel();
    }
    if (this.candStartReq) {
      this.candStartReq = false;
      this.cand.start(now);
    }
    if (this.cand.phase === CandPhase.NONE) return;

    // Yalnizca bu denemeden SONRA alinan IP gecerlidir (zaman damgasi degil GOT_IP sayaci): eski baglantinin kalintisi adayi "dogrulanmis" saydirmaz.
    const connectedSince = this.connected && this.connectSeq !== this.candSeq;
    const a = this.cand.update(now, connectedSince, this.evtDisconnected);
    switch (a) {
      case CandAction.DO_DISCONNECT:
        // Eski baglantiyi birak; kopma olaylari sonsun
        this.#driverDisconnect();
        this.sta.candidateStarted();
        break;
      case CandAction.DO_BEGIN:
        this.candSeq = this.connectSeq;
        this.#beginSta(this.candSsid, this.candPass, now);
        break;
      case CandAction.COMMIT:
        this.#commitCandidate();
        break;
      case CandAction.FAILED: {
        const reason = this.lastDisconnectReason;
        this.#driverDisconnect();
        const hadOld = cStrLen(this.ssid) > 0;
        this.candActive = false;
        this.candState = ConnectState.FAILED;
        this.candReason = reason;
        this.event('wifi_candidate_failed', { ssid: this.candSsid, reason, old_credentials: hadOld });
        this.candSsid = '';
        this.candPass = '';
        this.sta.candidateFailed(now, hadOld);
        break;
      }
      default:
        break;
    }
  }

  /** Kayitli STA kimligini (RAM + NVS) siler, baglantiyi keser, otomatik baglanmayi durdurur. */
  clearCredentials() {
    const cfg = this.cm.config;
    cfg.wifi_ssid = '';
    cfg.wifi_pass = '';
    cfg.wifi_sta_enabled = false;
    const ok = this.cm.save();
    this.ssid = '';
    this.pass = '';
    this.candActive = false;
    this.candState = ConnectState.IDLE;
    this.candReason = 0;
    this.candSsid = '';
    this.candPass = '';
    this.candCancelReq = true;   // tick(): aday akisini ve otomatik denemeyi sifirlar
    this.reqStaReset = true;
    this.#driverDisconnect();
    this.event('wifi_credentials_cleared', {});
    return ok;
  }

  /** Manuel yeniden baglanma (geri cekilme sayacini sifirlar) */
  triggerReconnect() { this.reqReconnect = true; }

  // ------------------------------------------------------------------ tarama (WiFi.scanNetworks / scanComplete)
  scanStart(now) {
    this.scan = { running: true, wait: new Wait(), results: null };
    this.scan.wait.arm(now, this.timing.scanMs);
  }

  /** WiFi.scanComplete(): -1 = suruyor, -2 = basarisiz/baslamadi, >=0 = sonuc sayisi */
  scanComplete(now) {
    if (this.scan.results) return this.scan.results.length;
    if (!this.scan.running) return -2;
    if (!this.scan.wait.elapsed(now)) return -1;
    this.scan.running = false;
    this.scan.results = this.world.scanList();
    return this.scan.results.length;
  }

  scanResults() { return this.scan.results || []; }

  scanDelete() { this.scan = { running: false, wait: new Wait(), results: null }; }

  // ------------------------------------------------------------------ AP (kurtarma / kurulum / servis)
  #startAp(openNetwork) {
    this.apSecured = !openNetwork;   // WPA2 yalnizca parolayla baslatildiysa (AP-kaynakli yetki: ApAccess)
    this.apActive = true;
    this.event('wifi_ap_started', { ssid: this.getRecoveryApSSID(), open: openNetwork, wpa2: !openNetwork });
  }

  #stopAp() {
    this.apSecured = false;   // once: AP kapanirken "WPA2" iddiasi kalmasin
    this.apActive = false;
    this.event('wifi_ap_stopped', {});
  }

  /** AP penceresi (mantik ApPolicy): bu islev yalniz girdileri toplar ve istenen eylemi uygular. */
  #stepAp(now) {
    // Diger gorevlerin istekleri
    if (this.reqServiceOpen) {
      this.reqServiceOpen = false;
      this.ap.openService(now, this.reqServiceMs);
      this.event('wifi_service_ap_requested', { window_ms: this.reqServiceMs });
    }
    if (this.reqApStop) {
      this.reqApStop = false;
      this.ap.closeAll(now);
    }
    if (this.reqApRestart) {
      this.reqApRestart = false;
      this.ap.requestRestart(now);
    }

    const cfg = this.cm.config;
    const provisioned = cfg.hasLocalKey();
    const passOk = cStrLen(cfg.ap_pass) >= AP_PASS_MIN_LEN;
    // Provizyonlu cihaz yalnizca gecerli ap_pass ile AP acar; provizyonsuz cihaz acik AP acar.
    const openNetwork = !provisioned;

    const inp = ApPolicy.makeIn();
    inp.allowed = !provisioned || passOk;
    inp.connected = this.connected;
    inp.staConfigured = cStrLen(this.ssid) > 0;
    inp.apActive = this.apActive;
    inp.clients = this.apStationCount();

    const out = this.ap.update(now, inp);
    if (out.serviceExpired) this.event('wifi_service_ap_expired', {});
    if (out.opened) this.event('wifi_ap_window_opened', { window_min: ApPolicy.WINDOW_MS / 60000 });
    if (out.extended) this.event('wifi_ap_window_extended', {});
    if (out.closedStable) this.event('wifi_ap_window_closed_stable', {});
    if (out.ended) this.event('wifi_ap_window_ended', {});

    if (out.startAp) {
      this.#startAp(openNetwork);
    } else if (out.stopAp) {
      this.#stopAp();
    } else if (out.restartAp) {
      this.#stopAp();
      this.#startAp(openNetwork);
    }
  }

  /** Servis modu: AP'yi sureli (varsayilan 10 dk) acar. Yalnizca AP parolasi gecerliyse veya cihaz provizyonsuzsa acilir. Istek tick()'e birakilir. */
  openServiceAp(_now, windowMs = SERVICE_AP_WINDOW_MS) {
    this.reqServiceMs = windowMs;
    this.reqServiceOpen = true;
  }

  /** AP'yi kapatir, pencereleri iptal eder (bir sonraki tick'te). */
  stopRecoveryAP() { this.reqApStop = true; }

  /** ap_pass veya provizyon durumu degisti: acik AP varsa yeni parolayla yeniden baslatilir (HTTP yaniti cikabilsin diye ~1,5 sn gecikmeli). */
  applyApConfigChange() { this.reqApRestart = true; }

  /** Fabrika sifirlama: surucunun kendi sakladigi Wi-Fi ayarlari ve RAM durumu. */
  factoryResetWifi() {
    this.reqApStop = true;   // (yeniden baslatmaya kadar tick calisirsa) AP'yi yeniden acmasin
    if (this.apActive) this.#stopAp();
    this.#driverDisconnect();
  }

  /** JSON'a basilacak SSID: gecersiz UTF-8 -> U+FFFD, en fazla 32 bayt. */
  static sanitizeSsid(raw) { return sanitizeUtf8(raw, 32); }
}
