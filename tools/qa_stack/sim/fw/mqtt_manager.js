// MqttManager.cpp (firmware) JavaScript portu: bulut MQTT istemcisi (CONTRACTS §2). Duz TCP (QA brokeri TLS'siz).
//
//  * Kimlik/sunucu ConfigManager'dan okunur; kimlik yoksa MQTT baslamaz (cihaz yerelde calisir).
//  * Konular: ev/{t}/state, ev/{t}/status (yayin); ev/{t}/cmd, ev/{t}/sys (abonelik, QoS 1). {t} = kullanici adindan "d_" oneki atilmis kimlik.
//  * LWT: status {"status":"offline","uid":...} (QoS 1, retained); temiz oturum. Baglaninca: abonelikler -> 1500 ms "yok say" penceresi ->
//    status {"status":"online","uid":...} -> ilk tam durum. v1.3.1 (guvenlik-6): status yuku gercek JSON + uid (eskiden duz "online"/"offline").
//  * v1.3.1 (pano-5): provizyonluyken state'te "lk_fp" (local_key_fp.js); sys set_local_key uygulaninca yeni izli state gecikmeden; provizyonsuz
//    panoda set_local_key yok sayilir (pano-7).
//  * Durum yayini: QoS 0 + retained; degisimde ~250 ms birlestirmeyle, en az 30 sn'de bir; hareket surerken ~1 sn'de bir (SmartAutomation tetikler).
//  * onMessage YALNIZCA dogrular ve Automation.post() ile kuyruga yazar.
//  * Yeniden baglanma: ustel geri cekilme (varsayilan QA hizli, `firmwareTiming` = gercek 5 sn..5 dk +-%20 jitter).
//
// ZAMAN KURALI (CONTRACTS 3c, N6): saklanmis hedef zaman YOK. Zamanlayicilar NetTime.h'nin "son olay + bekleme" ciftleridir (sim/fw/net_time.js:
// Wait / ReconnectBackoff / PublishPacer), yalniz MQTT gorevinde (step) degistirilir ve HER turda yoklanir. Baska gorevler yalniz bayrak kurar:
// triggerPublish() zaman damgasi TASIMAZ -- birlestirme penceresini gorev, bayragi ilk GOZLEDIGI turda baslatir (en fazla bir tick = 50 ms gecikme).
// Yayin hatasinda istek korunur ve 1-2-4-8-16-30 sn ustel bekleme uygulanir (PublishPacer).
//
// Saat disaridan verilir: step(now) 50 ms'de bir cagrilir (gorev dongusu). Ag G/C mqtt.js ile asenkrondur.
import mqtt from 'mqtt';
import { isPrintableAsciiNoSpace, sanitizeInto } from './netutil.js';
import { LOCAL_KEY_MIN_LEN, LOCAL_KEY_MAX_LEN } from './sysconfig.js';
import { validateCommand, MAX_PAYLOAD_BYTES, isValidCommandId } from '../command_schema.js';
import { writeStateExtras, relayActText } from './safety_view.js';

/** ev/{t}/status yuku (firmware statusPayload; guvenlik-6): {"status":"online|offline","uid":"<UID>"} -- bayt bayt ayni dizi. */
export const statusPayload = (status, uid) => JSON.stringify({ status, uid });
import { Rej } from './safety_fsm.js';
import { parseCfgEdit } from './safety_cfg_api.js';
import { CfgResult } from './safety_manager.js';
import { planDump, writeDumpPart, DUMP_PART_CAP } from './safety_cfg_edit.js';
import { VIA_CLOUD } from './event_outbox.js';
import { CmdSource } from './automation.js';
import { PublishPacer, ReconnectBackoff, Wait } from './net_time.js';

export const TASK_TICK_MS = 50;
export const HEARTBEAT_MS = PublishPacer.HEARTBEAT_MS;
export const COALESCE_MS = PublishPacer.COALESCE_MS;
export const IGNORE_WINDOW_MS = 1500;
export const MAX_SYS_PAYLOAD_BYTES = 1024;   // sys (cfg_patch) ayri sinir [D2][B11]; cmd 512'de kalir
export const NO_TIME_RETRY_MS = 2000;
export const PUBLISH_RETRY_MAX_MS = PublishPacer.RETRY_MAX_MS;
const SIG_CHECK_MS = 100;   // durum gozcusu: 100 ms'de bir

/** uint32 rastgele (firmware esp_random()) */
const rndU32 = () => Math.floor(Math.random() * 0x100000000) >>> 0;

/** Zamanlama on ayarlari: QA (hizli yeniden baglanma) / firmware (gercek) */
export const QA_TIMING = Object.freeze({ backoffMinMs: 2000, backoffMaxMs: 10000, authFailWaitMs: 10000, tlsFailMinWaitMs: 10000, jitter: false, ignoreWindowMs: IGNORE_WINDOW_MS });
export const FIRMWARE_TIMING = Object.freeze({ backoffMinMs: 5000, backoffMaxMs: 300000, authFailWaitMs: 300000, tlsFailMinWaitMs: 60000, jitter: true, ignoreWindowMs: IGNORE_WINDOW_MS });

const RELAY_TYPE_NAME = ['light', 'shutter_up', 'shutter_down', 'impulse'];
const relayTypeName = (t) => RELAY_TYPE_NAME[t] || 'light';

const isValidTopicId = (t) => typeof t === 'string' && /^[A-Za-z0-9_-]{1,40}$/.test(t);

export class MqttManager {
  /**
   * @param {object} o
   * @param {import('./config_manager.js').ConfigManager} o.config
   * @param {import('./wifi_manager.js').WifiManager} o.wifi
   * @param {import('./automation.js').Automation} o.automation
   * @param {{now:()=>number}} o.clock             cihaz millis() (uint32)
   * @param {()=>number} o.uptimeSec
   * @param {string} o.mac                          "AA:BB:CC:DD:EE:FF"
   * @param {string} o.fw
   * @param {(cmd:object)=>boolean} o.post          komut kuyruguna yaz (postDeviceCommand; QA yavas/dusur hook'u dahil)
   * @param {{event?:Function, mapHost?:(h:string)=>string}} [o.hooks]
   * @param {object} [o.timing]
   */
  constructor({ config, wifi, automation, clock, uptimeSec, mac, fw, post, hooks = {}, timing = QA_TIMING }) {
    this.cm = config;
    this.wifi = wifi;
    this.automation = automation;
    this.clock = clock;
    this.uptimeSec = uptimeSec;
    this.mac = mac;
    this.fw = fw;
    this.post = post;
    this.hooks = hooks;
    this.timing = { ...QA_TIMING, ...timing };
    this.event = (t, f) => this.hooks.event?.(t, f);
    this.mapHost = hooks.mapHost || ((h) => h);

    this.uid = wifi.getDeviceUid();
    this.client = null;
    this.connected = false;        // CONNACK alindi ve abonelikler gonderildi
    this.connecting = false;
    this.attemptFailureHandled = false;
    this.needPublish = false;      // baska gorevlerin kurdugu yayin istegi (zaman damgasi TASIMAZ)
    this.reconfigPending = false;
    this.halted = false;
    this.qaHold = false;           // QA: forceOffline/crash
    this.seq = 0;
    // ---- Zamanlayicilar (NetTime.h: "son olay + bekleme" ciftleri; yalniz step() degistirir, her tur yoklanir)
    this.pace = new PublishPacer();          // 250 ms birlestirme, 30 sn kalp atisi, hata sonrasi ustel bekleme
    this.reconnect = new ReconnectBackoff({  // yeniden baglanma (QA hizli / firmware 5 -> 300 sn +-%20 jitter)
      minMs: this.timing.backoffMinMs,
      maxMs: this.timing.backoffMaxMs,
      authRejectMs: this.timing.authFailWaitMs,
      longMinMs: this.timing.tlsFailMinWaitMs,
      jitter: !!this.timing.jitter,
    });
    this.ignore = new Wait();                // cmd/sys aboneliginden sonraki 1500 ms "retained yok say" penceresi
    this.sigCheck = new Wait();              // durum gozcusu: 100 ms'de bir
    this.lastError = '';
    this.authFailed = false;

    this.haveCreds = false;
    this.enabled = true;
    this.server = '';
    this.port = 0;
    this.user = '';
    this.pass = '';
    this.topicId = '';
    this.topicStatus = '';
    this.topicState = '';
    this.topicCmd = '';
    this.topicSys = '';
    this.topicEvent = '';
    this.connectedAt = 0;
    this.qaDropAcks = 0;   // QA: sonraki N event_ack yok sayilir
    this.clientId = `ESP32S3_${mac.replace(/:/g, '').toUpperCase()}`;

    this.publishedSig = '';
    this.publishedSigValid = false;
    this.recentIds = new Array(8).fill('');
    this.acceptId = '';      // sys cfg_patch kabul yankisi (WP-C1): otomasyonun last_id'si degismedikce state.last_id
    this.acceptBase = '';
    this.recentHead = 0;
    this.subscribed = { cmd: null, sys: null };   // SUBACK sonucu (QA gorunurlugu; firmware SUBACK'e bakmaz)
  }

  begin() {
    this.applyConfig();
    this.event('mqtt_begin', { credentials: this.haveCreds });
  }

  applyConfig() {
    const c = this.cm.config;
    this.enabled = c.mqtt_enabled;
    this.port = c.mqtt_port;
    let have = c.hasMqttCredentials();
    this.server = c.mqtt_server;
    this.user = c.mqtt_user;
    this.pass = c.mqtt_pass;
    const tid = this.user.startsWith('d_') ? this.user.slice(2) : this.user;
    if (have && !isValidTopicId(tid)) have = false;
    this.topicId = tid;
    if (have) {
      this.topicStatus = `ev/${tid}/status`;
      this.topicState = `ev/${tid}/state`;
      this.topicCmd = `ev/${tid}/cmd`;
      this.topicSys = `ev/${tid}/sys`;
      this.topicEvent = `ev/${tid}/event`;
    } else {
      this.topicStatus = this.topicState = this.topicCmd = this.topicSys = this.topicEvent = '';
    }
    this.haveCreds = have;
  }

  reconfigure() { this.reconfigPending = true; }

  isConfigured() { return this.haveCreds && this.enabled; }

  isConnected() { return this.connected && !!this.client; }

  /**
   * Her gorevden cagrilabilir: yalniz bayrak kurar (zaman damgasi tasimaz; `_now` yalnizca eski cagrilarla uyum icindir). Birlestirme penceresini
   * MQTT gorevi, bayragi ilk GOZLEDIGI turda baslatir (en fazla bir tick = 50 ms gecikme).
   */
  triggerPublish(_now) {
    this.needPublish = true;
  }

  // ------------------------------------------------------------------ yeniden baglanma
  #scheduleRetry(now, longWait) {
    this.reconnect.schedule(now, longWait, rndU32());
  }

  /** @param {boolean} sendDisconnect  true = temiz DISCONNECT (LWT YOK); false = soket ani kapanir (LWT) */
  #dropConnection(why, sendDisconnect) {
    const c = this.client;
    const was = this.connected;
    this.client = null;
    this.connected = false;
    this.connecting = false;
    this.subscribed = { cmd: null, sys: null };
    if (c) {
      try {
        if (sendDisconnect && c.connected) c.end(false);
        else if (c.stream) c.stream.destroy();
        else c.end(true);
      } catch (_) { /* yok say */ }
      // kalan zamanlayicilari/dinleyicileri birakma
      setTimeout(() => { try { c.end(true); } catch (_) { /* yok say */ } }, 500).unref?.();
    }
    if (was) this.event('mqtt_dropped', { why, clean: sendDisconnect });
  }

  // ------------------------------------------------------------------ gorev dongusu (50 ms)
  step(now) {
    // Zamanlayicilar HER turda (kimlik/Wi-Fi/baglanti durumu ne olursa olsun) yoklanir: sure dolunca sonlanir (N6).
    this.reconnect.service(now);
    this.pace.service(now);
    this.ignore.service(now);
    this.sigCheck.service(now);

    if (this.halted) return;

    if (this.reconfigPending) {
      this.reconfigPending = false;
      this.#dropConnection('yapilandirma degisti', true);
      this.applyConfig();
      this.reconnect.reset();
      this.authFailed = false;
      this.event('mqtt_reconfigured', { credentials: this.haveCreds });
    }
    if (this.qaHold) return;

    if (!this.haveCreds || !this.enabled) {
      if (this.connected || this.client) this.#dropConnection('MQTT devre disi', true);
      return;
    }
    if (!this.wifi.isConnected()) {
      if (this.connected || this.client) {
        this.#dropConnection('Wi-Fi koptu', false);
        this.#scheduleRetry(now, false);
      }
      return;
    }
    if (!this.client) {
      if (this.reconnect.due(now)) this.#tryConnect(now);
      return;
    }
    if (this.connected) {
      this.#watchStateChanges(now);
      this.#publishIfDue(now);
      this.#publishEventsIfDue(now);   // ev/{t}/event: uygulama duzeyinde onayli teslim (spec 3.4)
    }
  }

  // ------------------------------------------------------------------ baglanti
  #tryConnect(now) {
    // Saat senkronu yoksa TLS denenmez (QA'da da ayni bekleme korunur); ustel sayaca dokunmaz
    if (!this.wifi.isTimeSynced()) {
      this.reconnect.waitFixed(now, NO_TIME_RETRY_MS);
      return false;
    }
    const host = this.mapHost(this.server);
    this.event('mqtt_connecting', { host, port: this.port, user: this.user });
    this.connecting = true;
    this.attemptFailureHandled = false;
    this.authFailed = false;
    const client = mqtt.connect({
      protocol: 'mqtt',
      host,
      port: this.port,
      clientId: this.clientId,
      username: this.user,
      password: this.pass,
      clean: true,
      keepalive: 30,
      protocolVersion: 4,
      reconnectPeriod: 0,
      connectTimeout: 12000,
      resubscribe: false,
      will: { topic: this.topicStatus, payload: statusPayload('offline', this.uid), qos: 1, retain: true },
    });
    this.client = client;

    client.on('connect', () => {
      if (this.client !== client) { try { client.end(true); } catch (_) { /* yok say */ } return; }
      this.#onConnected();
    });
    client.on('message', (topic, payload, packet) => {
      if (this.client !== client) return;
      this.onMessage(topic, payload, !!packet.retain);
    });
    client.on('error', (err) => {
      if (this.client !== client) return;
      this.lastError = err && (err.code !== undefined ? `code ${err.code}: ${err.message}` : err.message);
      if (err && (err.code === 4 || err.code === 5) && !this.connected) this.authFailed = true;
      this.event('mqtt_error', { error: this.lastError });
    });
    client.on('close', () => {
      if (this.client !== client) return;
      const was = this.connected;
      this.client = null;
      this.connected = false;
      this.connecting = false;
      this.subscribed = { cmd: null, sys: null };
      const now2 = this.clock.now();
      if (was) this.event('mqtt_closed', { clean: false });
      if (this.attemptFailureHandled) return;
      this.attemptFailureHandled = true;
      if (this.authFailed) {
        this.event('mqtt_auth_rejected', { code: this.lastError });
        this.reconnect.scheduleAuthRejected(now2, rndU32());   // CONNACK 4/5: kimlik/yetki reddi -> uzun bekleme
      } else {
        this.#scheduleRetry(now2, false);
      }
    });
    return true;
  }

  #onConnected() {
    const client = this.client;
    this.connecting = false;
    // 4) Abonelikler (cmd + sys; ayri SUBSCRIBE paketleri) ve ilk 1500 ms'lik "yok say" penceresi. SUBACK'e BAKILMAZ.
    const sub = (topic, key) => client.subscribe(topic, { qos: 1 }, (err, granted) => {
      const g = Array.isArray(granted) ? granted.find((x) => x.topic === topic) : null;
      const denied = !!err || !g || g.qos === 128;
      this.subscribed[key] = !denied;
      if (denied) this.event('mqtt_subscribe_denied', { topic, error: err ? err.message : 'suback_failure' });
    });
    sub(this.topicCmd, 'cmd');
    sub(this.topicSys, 'sys');
    const now = this.clock.now();
    this.ignore.arm(now, this.timing.ignoreWindowMs);   // "retained yok say" penceresi (her tur yoklanir: sessizlikte bayat kalmaz)
    this.connectedAt = now;   // olay tamponu bu pencere bitmeden bosaltilmaz [D4]

    this.connected = true;
    this.reconnect.reset();
    this.recentIds = new Array(8).fill('');
    this.recentHead = 0;
    this.event('mqtt_connected', {});

    // Cevrimici durumu (retain) + ilk tam durum raporu (gecikmeden)
    this.#publishStatus('online');
    this.pace.connected();
  }

  /** status: 'online' | 'offline' -> {"status":...,"uid":...} (guvenlik-6). */
  #publishStatus(status) {
    if (!this.client || !this.client.connected) return false;
    this.client.publish(this.topicStatus, statusPayload(status, this.uid), { qos: 0, retain: true });
    return true;
  }

  /** Planli yeniden baslatma: "offline" yayinla, baglantiyi temiz kapat, bir daha baglanma. */
  async prepareForRestart() {
    if (this.halted) return;
    const c = this.client;
    this.halted = true;
    if (c && this.connected && c.connected) {
      this.#publishStatus('offline');
      this.client = null;
      this.connected = false;
      await new Promise((resolve) => {
        const t = setTimeout(resolve, 250);
        c.end(false, {}, () => { clearTimeout(t); resolve(); });
      });
      this.event('mqtt_dropped', { why: 'planli yeniden baslatma', clean: true });
    } else {
      this.#dropConnection('planli yeniden baslatma', true);
    }
  }

  // ------------------------------------------------------------------ QA kontrolleri
  /** QA: soket ani yok edilir (LWT) ve online'a kadar baglanilmaz. */
  qaForceOffline() {
    this.qaHold = true;
    this.#dropConnection('qa_offline', false);
  }

  /** QA: temiz DISCONNECT (LWT YOK), "offline" da yayinlanmaz -> retained "online" bayat kalir. */
  qaCrash() {
    this.qaHold = true;
    this.#dropConnection('qa_crash', true);
  }

  qaForceOnline() {
    this.qaHold = false;
    this.reconnect.wait.disarm();
  }

  // ------------------------------------------------------------------ durum yayini (CONTRACTS 2.4)
  #signature(s) {
    return JSON.stringify([
      s.relays.map((b) => (b ? 1 : 0)).join(''), s.dis.map((b) => (b ? 1 : 0)).join(''), s.childLock, s.totalRelays, s.totalDIs,
      s.shutters.map((x) => ((x.moving ? 1 : 0) | ((x.dir & 3) << 1) | (x.waiting ? 8 : 0) | (x.configured ? 16 : 0))),
      s.shutters.map((x) => x.target), s.lastId,
      // guvenlik katmani: gorunum imzasi (since_up haric), ret sayaci, saat durumu (spec 3.2 "Yayin tetigi")
      this.#safety()?.viewSig() ?? '', this.#safety()?.rejSeq ?? 0, this.wifi.isTimeSynced(),
      this.cm.keyGeneration(),   // pano-5: anahtar degisti -> yeni lk_fp hemen yayinlanir
    ]);
  }

  /**
   * Anlik goruntu en son yayinlanan imzadan farkliysa (cocuk kilidi, role, DI, panjur hareketi, last_id...) yayin tetiklenir; degisikligi kimin
   * yaptigindan bagimsiz retained durum bayat kalmaz. 100 ms'de bir bakilir.
   */
  #watchStateChanges(now) {
    if (!this.publishedSigValid || this.needPublish || this.pace.isPending()) return;
    if (!this.sigCheck.elapsed(now)) return;
    this.sigCheck.arm(now, SIG_CHECK_MS);
    if (this.#signature(this.#snap()) !== this.publishedSig) this.triggerPublish(now);
  }

  /** Yayin zamani: tetik bayragi gozlenince 250 ms birlestirme; yayin yoksa 30 sn kalp atisi; hata sonrasi ustel bekleme (PublishPacer). */
  #publishIfDue(now) {
    if (this.pace.due(now, this.needPublish)) this.publishState(now);
  }

  #safety() { return this.automation.safetyOn ? this.automation.safety : null; }

  /** v:3 eki (firmware writeStateExtras ile ayni bayt dizisi) ve role "act" alanlari. */
  #stateExtras() {
    const sm = this.#safety();
    const v = sm?.copyView() ?? { configured: 0, act: [] };
    const m = sm ? sm.stateMeta() : { boot: 0, bn: 0, rejId: '', rej: Rej.OK };
    const timeOk = this.wifi.isTimeSynced();
    return { view: v, text: writeStateExtras(v, { ...m, timeOk, epoch: timeOk ? Math.floor(Date.now() / 1000) : 0 }) };
  }

  /** MQTT `state` yuku (v:3 = v:2'nin kati ust kumesi). Yalniz gercekten panjur olarak tanimli ciftler raporlanir ("hayalet panjur" yok). */
  buildState() {
    const snap = this.#snap();
    const c = this.cm.config;
    const nR = Math.min(snap.totalRelays, 40);
    const nD = Math.min(snap.totalDIs, 40);
    const ex = this.#stateExtras();
    const doc = {
      v: 3,
      uid: this.uid,
      fw: this.fw,
      seq: this.seq,
      uptime: this.uptimeSec(),
      ip: this.wifi.getLocalIP(),
      child_lock: snap.childLock,
    };
    if (snap.lastId !== '') doc.last_id = snap.lastId;   // bos last_id gonderilmez
    const fp = this.cm.localKeyFp(this.uid);
    if (fp) doc.lk_fp = fp;   // v1.3.1 (pano-5, sozlesme 1): yalniz provizyonluyken
    doc.relays = Array.from({ length: nR }, (_, i) => {
      const r = { id: i + 1, name: sanitizeInto(32, c.relays[i].name), type: relayTypeName(c.relays[i].type), state: !!snap.relays[i] };
      const act = relayActText(ex.view, i + 1);
      if (act) r.act = act;   // yalniz eylemci rolelerinde (type ayni kalir) [K1]
      return r;
    });
    const shutters = [];
    for (let p = 0; p < Math.floor(nR / 2); p++) {
      const sh = snap.shutters[p];
      if (sh.configured) shutters.push({ pair: p + 1, pos: sh.pos, moving: sh.moving, dir: sh.dir, target: sh.target });
    }
    doc.shutters = shutters;
    doc.dis = Array.from({ length: nD }, (_, i) => ({ id: i + 1, state: !!snap.dis[i] }));
    return Object.assign(doc, JSON.parse(`{${ex.text.slice(1)}}`));   // firmware: ek, nesnenin sonuna eklenir
  }

  publishState(now) {
    // Bayrak ve bekleyen istek, anlik goruntuden ONCE temizlenir: goruntu alinirken gelen yeni tetikleme kaybolmaz.
    this.needPublish = false;
    this.pace.beginSend();
    // Hata: istek korunur (pacer: bekleyen); 1,2,4,8,16,30 sn bekleme
    const fail = (why) => {
      const wait = this.pace.failed(now);
      this.event('mqtt_publish_deferred', { why, retry_in_ms: wait });
      return false;
    };
    if (!this.client || !this.client.connected) return fail('baglanti yok');
    const snap = this.automation.getSnapshot();
    const seq = ++this.seq;
    const doc = this.buildState();
    doc.seq = seq;
    const payload = JSON.stringify(doc);
    this.client.publish(this.topicState, payload, { qos: 0, retain: true }, (err) => {
      if (err) {
        this.event('mqtt_publish_failed', { error: err.message });
        this.pace.failed(this.clock.now());   // asenkron yazma hatasi: ayni ustel bekleme, istek korunur
      }
    });
    this.pace.sent(now);
    this.publishedSig = this.#signature(snap);   // "en son yayinlanan" durum: gozcu bununla karsilastirir
    this.publishedSigValid = true;
    return true;
  }

  // ------------------------------------------------------------------ gelen mesajlar
  #seenId(id) { return this.recentIds.includes(id) && id !== ''; }

  #rememberId(id) {
    this.recentIds[this.recentHead] = id;
    this.recentHead = (this.recentHead + 1) % 8;
  }

  /** @returns {{kind:string, ...}} QA/test icin sonuc ozeti */
  onMessage(topic, payload, retain = false) {
    const isCmd = topic === this.topicCmd;
    const isSys = topic === this.topicSys;
    if (!isCmd && !isSys) return { kind: 'unexpected_topic' };
    const now = this.clock.now();

    // Abonelikten sonraki ilk 1500 ms: yeniden uygulanmis (retained) mesaja karsi savunma (cmd VE sys). Pencere gorev dongusunde her tur
    // yoklandigi icin haftalarca komutsuz kalinsa bile ilk gercek komut ISLENIR (N6).
    if (this.ignore.running(now)) {
      this.event('cmd_ignored', { reason: 'startup_window', retain, topic: isSys ? 'sys' : 'cmd' });
      this.hooks.counter?.('mqtt_cmd_ignored');
      return { kind: 'ignored_window' };
    }
    const len = payload.length;
    if (len === 0 || len > (isSys ? MAX_SYS_PAYLOAD_BYTES : MAX_PAYLOAD_BYTES)) {
      this.event('cmd_ignored', { reason: 'bad_payload_size', bytes: len });
      return { kind: 'bad_size' };
    }
    return isSys ? this.#handleSys(payload) : this.#handleCommand(payload, now);
  }

  #handleCommand(payload, now) {
    let obj;
    try { obj = JSON.parse(Buffer.from(payload).toString('utf8')); } catch (_) {
      this.event('cmd_rejected', { source: 'mqtt', reason: 'JSON hatasi' });
      this.hooks.counter?.('mqtt_cmd_rejected');
      return { kind: 'bad_json' };
    }
    // uid: ev konusu evdeki butun panolara gider; baska panonun komutu SESSIZCE yok sayilir (last_rej yazilmaz) [Y5]
    if (obj && typeof obj === 'object' && !Array.isArray(obj) && Object.prototype.hasOwnProperty.call(obj, 'uid') && obj.uid !== this.uid) {
      this.event('cmd_ignored', { reason: 'other_uid' });
      return { kind: 'other_uid' };
    }
    const rejId = obj && typeof obj.id === 'string' && isValidCommandId(obj.id) ? obj.id : '';
    const v = validateCommand(obj, { totalRelays: this.cm.config.totalRelays() });
    if (!v.ok) {
      this.event('cmd_rejected', { source: 'mqtt', reason: v.reason, bytes: payload.length });
      this.hooks.counter?.('mqtt_cmd_rejected');
      this.#rejectCmd(rejId, Rej.BAD_CMD, now);
      return { kind: 'rejected', reason: v.reason };
    }
    if (v.eventAck) {
      if (this.qaDropAcks > 0) { this.qaDropAcks--; this.event('event_ack_dropped_by_qa', {}); return { kind: 'event_ack_dropped' }; }
      const sm = this.#safety();
      const n = sm ? sm.outbox.ackMany(v.eids) : 0;
      this.event('event_ack', { acked: n, of: v.eids.length });
      return { kind: 'event_ack', acked: n };
    }
    const cmd = { ...v.cmd, source: CmdSource.MQTT };
    // RV-2: uid'siz duz role komutu (butun panolara gider) bu panonun eylemci rolesine gelirse SESSIZCE yok sayilir.
    const hasUid = obj && typeof obj === 'object' && Object.prototype.hasOwnProperty.call(obj, 'uid');
    const sm0 = this.#safety();
    if ((cmd.type === 'RELAY_SET' || cmd.type === 'RELAY_TOGGLE') && !hasUid && sm0 && sm0.isActuatorRelay(cmd.index)) {
      this.event('cmd_ignored', { reason: 'actuator_relay_without_uid', relay: cmd.index });
      return { kind: 'actuator_relay_without_uid' };
    }
    if (cmd.id && this.#seenId(cmd.id)) {
      this.event('cmd_ignored', { reason: 'duplicate_id', id: cmd.id });
      this.hooks.counter?.('mqtt_cmd_ignored');
      return { kind: 'duplicate' };
    }
    if (!this.post(cmd)) {
      this.event('cmd_dropped_queue_full', { cmd: cmd.type });
      this.#rejectCmd(rejId, Rej.BUSY, now);
      return { kind: 'queue_full' };   // id kaydedilmez: istemci yeniden deneyebilir
    }
    if (cmd.id) this.#rememberId(cmd.id);
    this.hooks.counter?.('mqtt_cmd_queued');
    this.triggerPublish(now);
    return { kind: 'queued', cmd };
  }

  /** Komut reddi: id'si cozulebilen ve bu panoya ait komut icin state.last_rej (firmware MqttManager::rejectCmd) [O10]. */
  #rejectCmd(id, rej, now) {
    const sm = this.#safety();
    if (sm) sm.noteReject(id, rej);
    this.triggerPublish(now);
  }

  /** sys cfg_patch kabulu (firmware MqttManager::acceptCmd, WP-C1): kabul edilen id, otomasyonun son kimligi degismedikce last_id olur. */
  #acceptCmd(id, now) {
    if (id) { this.acceptBase = this.automation.getSnapshot().lastId; this.acceptId = id; }
    this.triggerPublish(now);
  }

  /** Anlik goruntu + kabul yankisi (firmware overlayAcceptedId). */
  #snap() {
    const s = this.automation.getSnapshot();
    if (!this.acceptId) return s;
    if (s.lastId !== this.acceptBase) { this.acceptId = ''; this.acceptBase = ''; return s; }
    return { ...s, lastId: this.acceptId };
  }

  #handleSys(payload) {
    let obj;
    try { obj = JSON.parse(Buffer.from(payload).toString('utf8')); } catch (_) { obj = null; }
    if (!obj || typeof obj !== 'object' || Array.isArray(obj)) {
      this.event('sys_rejected', { reason: 'bad_json' });
      return { kind: 'sys_rejected', reason: 'bad_json' };
    }
    if (typeof obj.cmd !== 'string') { this.event('sys_rejected', { reason: 'cmd_not_string' }); return { kind: 'sys_rejected', reason: 'cmd_not_string' }; }
    if (obj.cmd === 'cfg_get' || obj.cmd === 'cfg_patch') return this.#handleCfgSys(obj);
    let cmd = null;
    let key = null;
    for (const [k, val] of Object.entries(obj)) {
      if (k === 'cmd') {
        if (typeof val !== 'string') { this.event('sys_rejected', { reason: 'cmd_not_string' }); return { kind: 'sys_rejected', reason: 'cmd_not_string' }; }
        cmd = val;
      } else if (k === 'local_key' || k === 'key') {
        if (key !== null || typeof val !== 'string') { this.event('sys_rejected', { reason: 'key_field' }); return { kind: 'sys_rejected', reason: 'key_field' }; }
        key = val;
      } else if (k === 'id') {
        /* izinli, kullanilmaz */
      } else {
        this.event('sys_rejected', { reason: 'unknown_field' });
        return { kind: 'sys_rejected', reason: 'unknown_field' };
      }
    }
    if (cmd === null || cmd !== 'set_local_key') {
      this.event('sys_rejected', { reason: 'unknown_command' });
      return { kind: 'sys_rejected', reason: 'unknown_command' };
    }
    const klen = key === null ? 0 : Buffer.byteLength(key, 'utf8');
    if (key === null || klen < LOCAL_KEY_MIN_LEN || klen > LOCAL_KEY_MAX_LEN || !isPrintableAsciiNoSpace(key)) {
      this.event('sys_rejected', { reason: 'invalid_key' });
      return { kind: 'sys_rejected', reason: 'invalid_key' };
    }
    // pano-7: provizyonsuz panoya buluttan anahtar yazilmaz (AP parolasiz yarim provizyon); ilk anahtar yalniz factory/init / seri FACTORYINIT
    if (!this.cm.hasLocalKey()) {
      this.event('sys_rejected', { reason: 'unprovisioned' });
      return { kind: 'sys_rejected', reason: 'unprovisioned' };
    }
    if (this.cm.setLocalKey(key)) {
      this.event('sys_applied', { cmd: 'set_local_key' });   // anahtar degeri LOGLANMAZ
      this.wifi.applyApConfigChange(this.clock.now());
      this.hooks.localKeyChanged?.();
      this.pace.connected();   // pano-5: yeni lk_fp'li tam durum gecikmeden (firmware _pace.connected())
      return { kind: 'sys_applied' };
    }
    this.event('sys_failed', { reason: 'store' });
    return { kind: 'sys_failed' };
  }

  // ------------------------------------------------------------------ guvenlik: sys cfg_get / cfg_patch (WP-F4)
  /** cfg_*: "module":"safety" ve "uid" ZORUNLU (uid eslesmezse sessiz). Bulut yolu gevsetebilir (yetki sunucuda); cakismada pano kazanir. */
  #handleCfgSys(obj) {
    if (typeof obj.uid !== 'string') { this.event('sys_rejected', { reason: 'uid_required' }); return { kind: 'sys_rejected', reason: 'uid_required' }; }
    if (obj.uid !== this.uid) return { kind: 'other_uid' };
    if (obj.module !== 'safety') { this.event('sys_rejected', { reason: 'module' }); return { kind: 'sys_rejected', reason: 'module' }; }
    const sm = this.#safety();
    if (!sm) return { kind: 'sys_rejected', reason: 'no_safety' };
    const rejId = typeof obj.id === 'string' && isValidCommandId(obj.id) ? obj.id : '';
    const now = this.clock.now();
    if (obj.cmd === 'cfg_get') {
      if (!Object.keys(obj).every((k) => ['cmd', 'module', 'uid', 'id'].includes(k))) { this.event('sys_rejected', { reason: 'unknown_field' }); return { kind: 'sys_rejected', reason: 'unknown_field' }; }
      return { kind: 'cfg_dump', parts: this.#publishCfgDump() };
    }
    const p = parseCfgEdit(obj, true);
    if (p.err) {
      this.event('cfg_patch_rejected', { reason: p.err });
      this.#rejectCmd(rejId, Rej.CFG_INVALID, now);
      return { kind: 'cfg_rejected', reason: p.err };
    }
    const res = sm.submitEdit(p.edit, p.hasBase, p.baseRev, VIA_CLOUD, this.cm.config, { nowMs: now });
    const done = (o) => {
      this.event('cfg_patch', { result: o.r, rev: o.rev });
      if (o.r === CfgResult.OK) this.#acceptCmd(rejId, now);
      else if (o.r === CfgResult.CONFLICT) this.#rejectCmd(rejId, Rej.CFG_CONFLICT, now);
      else if (o.r === CfgResult.LATCHED) this.#rejectCmd(rejId, Rej.ZONE_LATCHED, now);
      else if (o.r === CfgResult.INVALID) this.#rejectCmd(rejId, Rej.CFG_INVALID, now);
      else if (o.r === CfgResult.STORAGE) this.#rejectCmd(rejId, Rej.CFG_STORAGE, now);   // WP-C1: eskiden busy
      else if (o.r === CfgResult.GAS_LOCAL) this.#rejectCmd(rejId, Rej.GAS_LOCAL_ONLY, now);   // Faz 2 incelemesi G-1a
      else if (o.r === CfgResult.ARMED) this.#rejectCmd(rejId, Rej.ARMED, now);              // G-1b
      else this.#rejectCmd(rejId, Rej.BUSY, now);
      return { kind: 'cfg_patch', result: o.r, rev: o.rev, err: o.err };
    };
    return res instanceof Promise ? res.then(done) : done(res);
  }

  /** ev/{t}/event: zamani gelen en eski olay (her 50 ms en cok bir); abonelikten sonraki 1500 ms'de bosaltilmaz [D4]. retain YOK. */
  #publishEventsIfDue(now) {
    const sm = this.#safety();
    if (!sm || !this.topicEvent || !this.client || !this.client.connected) return;
    const box = sm.outbox;
    const slot = box.nextDue(now, this.connectedAt);
    if (slot < 0) return;
    const json = box.toJson(slot, this.uid, sm.bootCount);
    if (!json) { box.ack(box.eidOf(slot)); this.event('event_dropped_too_big', {}); return; }
    box.markSent(slot, now);
    this.client.publish(this.topicEvent, json, { qos: 0, retain: false });
    this.event('event_published', { eid: box.eidOf(slot) });
  }

  /** cfg_dump: outbox DISINDA, onaysiz, her parca <= 3500 bayt (part/parts). @returns {number} parca sayisi */
  #publishCfgDump() {
    const sm = this.#safety();
    if (!sm || !this.topicEvent || !this.client || !this.client.connected) return 0;
    const c = sm.copyConfig();
    const parts = planDump(c, DUMP_PART_CAP);
    parts.forEach((p, k) => this.client.publish(this.topicEvent, writeDumpPart(c, p, k + 1, parts.length, this.uid), { qos: 0, retain: false }));
    this.event('cfg_dump', { parts: parts.length, rev: c.rev });
    return parts.length;
  }

  // ------------------------------------------------------------------ QA ozeti
  qaState(now) {
    return {
      configured: this.isConfigured(),
      server: this.haveCreds ? this.server : null,
      port: this.haveCreds ? this.port : null,
      user: this.haveCreds ? this.user : null,
      topic_id: this.topicId || null,
      state: this.connected ? 'connected' : this.client ? 'connecting' : 'disconnected',
      connected: this.isConnected(),
      cmd_subscribed: this.subscribed.cmd === true,
      sys_subscribed: this.subscribed.sys === true,
      in_startup_window: this.isConnected() ? this.ignore.remaining(now) > 0 : null,
      forced_offline: this.qaHold,
      last_error: this.lastError || null,
      backoff_ms: this.reconnect.backoffMs,
      next_attempt_in_ms: this.reconnect.wait.remaining(now),
      seq: this.seq,
      recent_ids: this.recentIds.filter((x) => x !== ''),
    };
  }
}

