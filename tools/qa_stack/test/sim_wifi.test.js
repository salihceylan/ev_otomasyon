// Cihaz simulatorunun Wi-Fi yoneticisi = firmware WiFiManager portu (SANAL SAAT, gercek zamanlayici/HTTP yok): AP kipi (acik kurulum AP'si vs WPA2 kurtarma
// AP'si, isRecoveryApSecured), AP penceresi (3 dk / 10 dk / 15 dk / 30 dk, STA 30 sn kararli kapanis), aday kimlik durum makinesi
// (idle -> connecting -> success | failed, 25 sn zaman asimi, neden kodlari 2/15/202/204 sifre + 201 ag yok), AP istemcisi varken STA denemesi yapilmaz.
// Kaynak: src/WiFiManager.cpp + src/NetTime.h (ApPolicy / StaMachine / CandidateFlow) -- sim/fw/wifi_manager.js + sim/fw/net_time.js.
import test from 'node:test';
import assert from 'node:assert/strict';
import { ConfigManager, NvsImage } from '../sim/fw/config_manager.js';
import { WifiManager, WifiWorld, ConnectState, ConnectRequest, WIFI_REASON } from '../sim/fw/wifi_manager.js';

const MIN = 60000;
const KEY = 'abcdefgh12345';
const AP_PASS = 'ap-pass-1234';
const HOME = { ssid: 'TestHome', pass: 'home-pass-123' };

/** Sanal saatli tek Wi-Fi yoneticisi. step 100 ms (simulatorun Wi-Fi tick'i). */
function makeBoard({ provisioned = true, apPass = AP_PASS, sta = null, t0 = 1000, timing = {}, nvs = new NvsImage(null) } = {}) {
  const cm = new ConfigManager(nvs);
  cm.begin();
  if (provisioned) {
    cm.setLocalKey(KEY);
    if (apPass) cm.setApPass(apPass);
  }
  if (sta) {
    cm.config.wifi_ssid = sta.ssid;
    cm.config.wifi_pass = sta.pass;
    cm.config.wifi_sta_enabled = true;
  }
  cm.save();
  const world = new WifiWorld({ homeSsid: HOME.ssid, homePass: HOME.pass });
  const events = [];
  const wifi = new WifiManager({
    config: cm, world, mac: '02:A5:00:0A:00:01', staIp: '192.168.1.40',
    hooks: { event: (type, f) => events.push({ type, ...f }) },
    timing: { connectMs: 1500, scanMs: 1500, sntpMs: 800, ...timing },
  });
  wifi.begin();
  const b = {
    t: t0, cm, world, wifi, events, nvs,
    step(ms = 100) { this.t = (this.t + ms) >>> 0; this.wifi.tick(this.t); },
    run(ms, stepMs = 100) { for (let d = 0; d < ms; d += stepMs) this.step(Math.min(stepMs, ms - d)); return this; },
    runUntil(pred, maxMs = 120000, stepMs = 100) {
      for (let d = 0; d < maxMs; d += stepMs) { if (pred()) return true; this.step(stepMs); }
      return pred();
    },
    ofType(type) { return this.events.filter((e) => e.type === type); },
    status() { return this.wifi.getConnectStatus(); },
  };
  return b;
}

// ====================================================================== AP kipi: acik kurulum AP'si vs WPA2 kurtarma AP'si
test('AP kipi: provizyonsuz cihaz ACIK kurulum AP\'si acar (WPA2 DEGIL); isRecoveryApSecured false; AP SSID = AHBU-<MAC son 6>', () => {
  const b = makeBoard({ provisioned: false });
  assert.equal(b.wifi.isRecoveryApActive(), false, 'tick atilmadan AP yok');
  b.run(200);
  assert.equal(b.wifi.isRecoveryApActive(), true, 'STA tanimsiz: pencere hemen acilir');
  assert.equal(b.wifi.isRecoveryApSecured(), false, 'acik kurulum AP\'si: WPA2 degil');
  assert.equal(b.wifi.getRecoveryApSSID(), 'AHBU-0A0001');
  assert.deepEqual([b.wifi.apIp(), b.wifi.apMask()], ['192.168.4.1', '255.255.255.0']);
  const started = b.ofType('wifi_ap_started');
  assert.deepEqual([started.length, started[0].open, started[0].wpa2], [1, true, false]);
});

test('AP kipi: provizyonlu + gecerli ap_pass -> WPA2 kurtarma AP\'si (isRecoveryApSecured true); AP kapaninca false', () => {
  const b = makeBoard({ provisioned: true });
  b.run(200);
  assert.equal(b.wifi.isRecoveryApActive(), true);
  assert.equal(b.wifi.isRecoveryApSecured(), true);
  assert.equal(b.ofType('wifi_ap_started')[0].wpa2, true);
  // stopRecoveryAP: istek bayragi, bir sonraki tick'te kapanir; "WPA2" iddiasi AP kapanirken kalmaz
  b.wifi.stopRecoveryAP();
  assert.equal(b.wifi.isRecoveryApSecured(), true, 'istek bayragi: kapanis wifi_task turunda');
  b.run(100);
  assert.equal(b.wifi.isRecoveryApActive(), false);
  assert.equal(b.wifi.isRecoveryApSecured(), false);
  assert.equal(b.wifi.apIp(), '0.0.0.0');
  // closeAll: yeniden acma 15 dk beklemeli (STA tanimsiz olsa bile)
  b.run(14 * MIN);
  assert.equal(b.wifi.isRecoveryApActive(), false, 'closeAll sonrasi 15 dk yeniden acilmaz');
  b.run(1.2 * MIN);
  assert.equal(b.wifi.isRecoveryApActive(), true, '15 dk sonra kesinti suruyor: yeniden acilir');
});

test('AP kipi: provizyonlu ama ap_pass YOK -> AP HICBIR ZAMAN acilmaz (izin yok); ap_pass gelince acilir', () => {
  const b = makeBoard({ provisioned: true, apPass: '' });
  b.run(30 * MIN);
  assert.equal(b.wifi.isRecoveryApActive(), false);
  assert.equal(b.ofType('wifi_ap_started').length, 0);
  b.cm.setApPass(AP_PASS);
  b.run(200);
  assert.equal(b.wifi.isRecoveryApActive(), true, 'izin gelince (kesinti suruyor) pencere acilir');
  assert.equal(b.wifi.isRecoveryApSecured(), true);
});

test('factory/init sirasi: acik AP ~1,5 sn daha acik kalir (WPA2 DEGIL), sonra WPA2 + ap_pass ile TEK kez yeniden baslar', () => {
  const b = makeBoard({ provisioned: false });
  b.run(500);
  assert.deepEqual([b.wifi.isRecoveryApActive(), b.wifi.isRecoveryApSecured()], [true, false]);
  // POST /api/factory/init
  b.cm.setLocalKey(KEY);
  b.cm.setApPass(AP_PASS);
  b.wifi.applyApConfigChange();
  b.run(1000);
  assert.deepEqual([b.wifi.isRecoveryApActive(), b.wifi.isRecoveryApSecured()], [true, false], 'provizyonlu AMA AP henuz WPA2 degil: AP yolu bu pencerede KAPALI olmali');
  assert.equal(b.ofType('wifi_ap_started').length, 1);
  b.run(1000);   // 1,5 sn doldu
  assert.deepEqual([b.wifi.isRecoveryApActive(), b.wifi.isRecoveryApSecured()], [true, true]);
  const started = b.ofType('wifi_ap_started');
  assert.deepEqual(started.map((e) => e.wpa2), [false, true], 'yeniden baslatma: once acik, sonra WPA2');
  assert.equal(b.ofType('wifi_ap_stopped').length, 1);
  b.run(5000);
  assert.equal(b.ofType('wifi_ap_started').length, 2, 'yeniden baslatma TEK kez');
});

test('ap_pass degisimi (restart istegi) STA bagliyken kapali AP\'yi ACMAZ', () => {
  const b = makeBoard({ provisioned: true, sta: HOME });
  b.run(15000);
  assert.equal(b.wifi.isConnected(), true);
  assert.equal(b.wifi.isRecoveryApActive(), false);
  b.wifi.applyApConfigChange();
  b.run(5000);
  assert.equal(b.wifi.isRecoveryApActive(), false, 'STA bagli: AP kapali, restart istegi AP acmaz');
  assert.equal(b.ofType('wifi_ap_started').length, 0);
});

// ====================================================================== AP penceresi (ApPolicy)
test('AP penceresi: STA kaydi var ama ag yok -> 3 dk sonra WPA2 pencere acilir; 10 dk sonra kapanir; 15 dk bekler; yeniden acilir', () => {
  const b = makeBoard({ provisioned: true, sta: HOME });
  b.world.up = false;
  b.run(2.9 * MIN);
  assert.equal(b.wifi.isRecoveryApActive(), false, '3 dk dolmadi');
  b.run(0.2 * MIN);
  assert.equal(b.wifi.isRecoveryApActive(), true, '3 dk kesinti: pencere acilir');
  assert.equal(b.wifi.isRecoveryApSecured(), true);
  const opened = b.t;
  b.run(9.9 * MIN);
  assert.equal(b.wifi.isRecoveryApActive(), true, '10 dk dolmadi');
  b.run(0.2 * MIN);
  assert.equal(b.wifi.isRecoveryApActive(), false, '10 dk pencere bitti (istemci yok)');
  assert.equal(b.ofType('wifi_ap_window_ended').length, 1);
  const closedAt = b.t;
  b.run(14.5 * MIN);
  assert.equal(b.wifi.isRecoveryApActive(), false, 'yeniden acma beklemesi 15 dk');
  b.run(1 * MIN);
  assert.equal(b.wifi.isRecoveryApActive(), true);
  assert.ok(((b.t - opened) >>> 0) > 25 * MIN - 5000 && closedAt > opened);
});

test('AP penceresi: istemci (istasyon) bagliyken 2 dk adimlarla uzar, en fazla 30 dk; sonra kapanir', () => {
  const b = makeBoard({ provisioned: true, sta: HOME });
  b.world.up = false;
  b.wifi.apClientsOverride = 1;
  b.run(3.1 * MIN);
  assert.equal(b.wifi.isRecoveryApActive(), true);
  const openedAt = b.t;
  b.run(29 * MIN);
  assert.equal(b.wifi.isRecoveryApActive(), true, 'istemci var: 30 dk boyunca acik');
  assert.ok(b.ofType('wifi_ap_window_extended').length >= 9);
  b.run(1.3 * MIN);
  assert.equal(b.wifi.isRecoveryApActive(), false, '30 dk tavan: istemci olsa da kapanir');
  assert.ok(((b.t - openedAt) >>> 0) >= 30 * MIN);
});

test('AP penceresi: STA 30 sn kararli baglaninca pencere erken kapanir; kesinti yeniden suruyorsa 3 dk sonra HEMEN acilir', () => {
  const b = makeBoard({ provisioned: true, sta: HOME });
  b.world.up = false;
  b.run(3.2 * MIN);
  assert.equal(b.wifi.isRecoveryApActive(), true);
  b.world.up = true;                      // ag geri geldi: STA 2-60 sn geri cekilmeyle yeniden dener
  assert.equal(b.runUntil(() => b.wifi.isConnected(), 90000), true, 'STA yeniden baglandi');
  b.run(29000);
  assert.equal(b.wifi.isRecoveryApActive(), true, 'STA 30 sn kararli degil');
  b.run(2500);
  assert.equal(b.wifi.isRecoveryApActive(), false, '30 sn kararli: pencere kapandi');
  assert.equal(b.ofType('wifi_ap_window_closed_stable').length, 1);
  b.world.up = false;                     // yeniden kesinti
  b.run(3.1 * MIN);
  assert.equal(b.wifi.isRecoveryApActive(), true, 'reopen beklemesi iptal edildi: 3 dk sonra hemen acilir');
});

test('servis AP penceresi (CLI "AP ON"): STA bagliyken de 10 dk acar; dolunca kapanir; ap_pass yoksa (provizyonlu) acilmaz', () => {
  const b = makeBoard({ provisioned: true, sta: HOME });
  b.run(20000);
  assert.equal(b.wifi.isRecoveryApActive(), false);
  b.wifi.openServiceAp(0);
  b.run(300);
  assert.equal(b.wifi.isRecoveryApActive(), true);
  b.run(9.9 * MIN);
  assert.equal(b.wifi.isRecoveryApActive(), true);
  b.run(0.3 * MIN);
  assert.equal(b.wifi.isRecoveryApActive(), false);
  assert.equal(b.ofType('wifi_service_ap_expired').length, 1);

  const c = makeBoard({ provisioned: true, apPass: '', sta: HOME });
  c.run(20000);
  c.wifi.openServiceAp(0);
  c.run(1000);
  assert.equal(c.wifi.isRecoveryApActive(), false, 'ap_pass yok: servis AP\'si da acilmaz');
});

test('fabrika sifirlama (factoryResetWifi): AP kapanir ve yeniden acilmaz (15 dk); STA koparilir', () => {
  const b = makeBoard({ provisioned: true });
  b.run(300);
  assert.equal(b.wifi.isRecoveryApActive(), true);
  b.wifi.factoryResetWifi();
  assert.equal(b.wifi.isRecoveryApActive(), false, 'AP aninda kapanir');
  assert.equal(b.wifi.isRecoveryApSecured(), false);
  b.run(5000);
  assert.equal(b.wifi.isRecoveryApActive(), false, 'reqApStop: yeniden baslatmaya kadar AP acilmaz');
});

// ====================================================================== aday kimlik durum makinesi
test('aday kimlik: kabulden hemen sonra "connecting"; ~0,5 sn + 0,4 sn sonra baglanir; dogrulaninca NVS\'e yazilir; durum YALNIZ success ile basari', () => {
  const b = makeBoard({ provisioned: true });
  b.run(300);
  assert.deepEqual(b.status(), { state: ConnectState.IDLE, reason: 0 });
  assert.equal(b.wifi.requestConnect(HOME.ssid, HOME.pass), ConnectRequest.ACCEPTED);
  assert.deepEqual(b.status(), { state: ConnectState.CONNECTING, reason: 0 }, 'kabulden hemen sonra connecting');
  assert.equal(b.wifi.isConnecting(), true);
  assert.equal(b.wifi.requestConnect(HOME.ssid, HOME.pass), ConnectRequest.BUSY, 'deneme surerken ikinci istek BUSY');
  b.run(2000);
  assert.equal(b.status().state, ConnectState.CONNECTING, 'gercek baglanma ~0,5 + 0,4 + 1,5 sn sonra (henuz success degil)');
  assert.equal(b.cm.config.wifi_ssid, '', 'NVS\'e DOGRULANMADAN yazilmaz');
  assert.equal(b.runUntil(() => b.status().state === ConnectState.SUCCESS, 10000), true);
  assert.deepEqual(b.status(), { state: ConnectState.SUCCESS, reason: 0 });
  assert.equal(b.cm.config.wifi_ssid, HOME.ssid, 'dogrulaninca NVS\'e islendi');
  assert.equal(b.cm.config.wifi_sta_enabled, true);
  assert.equal(b.wifi.isConnected(), true);
  assert.equal(b.wifi.getSSID(), HOME.ssid);
  assert.equal(b.wifi.isConnecting(), false);
  // yeni istek kabul edilince eski success kalintisi gorunmez
  assert.equal(b.wifi.requestConnect(HOME.ssid, HOME.pass), ConnectRequest.ACCEPTED);
  assert.equal(b.status().state, ConnectState.CONNECTING);
});

test('aday kimlik: dogrulama (SSID 1..32 bayt, parola 0 veya 8..63 bayt) kabulde reddedilir ve durum degismez', () => {
  const b = makeBoard({ provisioned: true });
  for (const [ssid, pass, code] of [['', '', ConnectRequest.INVALID_SSID], [null, '', ConnectRequest.INVALID_SSID], ['a'.repeat(33), '', ConnectRequest.INVALID_SSID],
    ['ç'.repeat(17), '', ConnectRequest.INVALID_SSID], ['ok', 'kisa', ConnectRequest.INVALID_PASS], ['ok', 'x'.repeat(64), ConnectRequest.INVALID_PASS]]) {
    assert.equal(b.wifi.requestConnect(ssid, pass), code, `${ssid}/${pass}`);
  }
  assert.deepEqual(b.status(), { state: ConnectState.IDLE, reason: 0 });
  assert.equal(b.wifi.requestConnect('ç'.repeat(16), 'x'.repeat(63)), ConnectRequest.ACCEPTED, '32 bayt SSID / 63 bayt parola sinirda gecerli');
});

for (const reason of [2, 15, 202, 204]) {
  test(`aday kimlik: yanlis parola -> failed, neden ${reason} (sifre kodu); kayitli kimlik yoksa baglanmaz`, () => {
    const b = makeBoard({ provisioned: true });
    b.world.authFailReason = reason;
    b.wifi.requestConnect(HOME.ssid, 'yanlis-parola-1');
    assert.equal(b.runUntil(() => b.status().state === ConnectState.FAILED, 15000), true);
    assert.deepEqual(b.status(), { state: ConnectState.FAILED, reason });
    assert.equal(b.cm.config.wifi_ssid, '', 'basarisiz aday NVS\'e yazilmaz');
    b.run(20000);
    assert.equal(b.wifi.isConnected(), false);
    assert.equal(b.wifi.isConnecting(), false, 'kayitli kimlik yok: otomatik deneme yok');
  });
}

test('aday kimlik: ag yok -> failed, neden 201; acik ag parolasiz baglanir; acik aga parola verilirse reddedilir', () => {
  const b = makeBoard({ provisioned: true });
  b.wifi.requestConnect('Olmayan-Ag', '');
  assert.equal(b.runUntil(() => b.status().state === ConnectState.FAILED, 15000), true);
  assert.equal(b.status().reason, WIFI_REASON.NO_AP_FOUND);
  b.wifi.requestConnect('Misafir Ağı (Açık)', '');
  assert.equal(b.runUntil(() => b.status().state === ConnectState.SUCCESS, 15000), true);
  assert.equal(b.cm.config.wifi_ssid, 'Misafir Ağı (Açık)');
});

test('aday kimlik: 25 sn zaman asimi -> failed, neden 0 (zaman asimi/bilinmiyor); ESKI KIMLIGE donulur (1,5 sn sonra otomatik yol)', () => {
  const b = makeBoard({ provisioned: true, sta: HOME });
  assert.equal(b.runUntil(() => b.wifi.isConnected(), 10000), true, 'eski kimlikle bagli');
  b.world.silent = true;                       // yeni agin AP'si hic yanit vermez
  b.wifi.requestConnect('Komşu_WiFi_2.4G', 'komsu-parola-1');
  b.run(1000);
  assert.equal(b.wifi.isConnected(), false, 'eski baglanti birakildi (aday denemesi baslarken)');
  b.run(23000);
  assert.equal(b.status().state, ConnectState.CONNECTING, '25 sn dolmadi (0,5 + 0,4 sn sonrasindan sayilir)');
  b.run(3000);
  assert.deepEqual(b.status(), { state: ConnectState.FAILED, reason: 0 });
  assert.equal(b.ofType('wifi_candidate_failed').at(-1).old_credentials, true);
  assert.equal(b.cm.config.wifi_ssid, HOME.ssid, 'NVS eski kimlikte kaldi');
  b.world.silent = false;                      // radyo geri geldi
  assert.equal(b.runUntil(() => b.wifi.isConnected(), 10000), true, 'eski kimlige donuldu');
  assert.equal(b.wifi.getSSID(), HOME.ssid);
});

test('aday kimlik: bagliyken aday yanlis parolayla basarisiz olursa eski kimlige donus; otomatik STA denemeleri aday sirasinda durur', () => {
  const b = makeBoard({ provisioned: true, sta: HOME });
  assert.equal(b.runUntil(() => b.wifi.isConnected(), 10000), true);
  const attempts = b.wifi.reconnectCount;
  b.wifi.requestConnect(HOME.ssid, 'yanlis-parola-9');
  assert.equal(b.runUntil(() => b.status().state === ConnectState.FAILED, 15000), true);
  assert.equal(b.status().reason, 202);
  assert.equal(b.wifi.reconnectCount, attempts + 1, 'aday denemesi tek WiFi.begin');
  assert.equal(b.runUntil(() => b.wifi.isConnected(), 15000), true, 'eski kimlige donuldu');
  assert.equal(b.cm.config.wifi_ssid, HOME.ssid);
});

test('clearCredentials (POST /api/wifi/disconnect): RAM + NVS silinir, baglanti kesilir, otomatik deneme durur; aday akisi iptal olur', () => {
  const b = makeBoard({ provisioned: true, sta: HOME });
  assert.equal(b.runUntil(() => b.wifi.isConnected(), 10000), true);
  assert.equal(b.wifi.clearCredentials(), true);
  assert.deepEqual([b.cm.config.wifi_ssid, b.cm.config.wifi_sta_enabled, b.wifi.getSSID()], ['', false, '']);
  assert.equal(b.wifi.isConnected(), false);
  b.run(20000);
  assert.equal(b.wifi.isConnected(), false, 'kimlik yok: yeniden baglanmaz');
  // adayi sirasinda silinirse akis iptal
  b.wifi.requestConnect(HOME.ssid, HOME.pass);
  b.run(300);
  b.wifi.clearCredentials();
  b.run(10000);
  assert.equal(b.wifi.isConnected(), false);
  assert.equal(b.wifi.isConnecting(), false);
  assert.deepEqual(b.status(), { state: ConnectState.IDLE, reason: 0 });
});

// ====================================================================== otomatik STA ve AP istemcisi
test('otomatik STA: ag yokken 2 -> 4 -> 8 ... 60 sn ustel geri cekilme ile yeniden dener; ag gelince baglanir', () => {
  const b = makeBoard({ provisioned: true, sta: HOME });
  b.world.up = false;
  assert.equal(b.runUntil(() => b.wifi.reconnectCount >= 1, 3000), true, 'acilista hemen dener');
  // 15 sn zaman asimi/201 basarisizlik sonrasi geri cekilme: denemeler arasi aralik buyur
  const marks = [];
  let last = b.wifi.reconnectCount;
  for (let d = 0; d < 6 * MIN && marks.length < 6; d += 100) {
    b.step(100);
    if (b.wifi.reconnectCount !== last) { last = b.wifi.reconnectCount; marks.push(b.t); }
  }
  const gaps = marks.slice(1).map((m, i) => m - marks[i]);
  assert.ok(gaps.length >= 3);
  for (let i = 1; i < gaps.length; i++) assert.ok(gaps[i] >= gaps[i - 1] - 200, `geri cekilme azalmamali: ${gaps.join(',')}`);
  assert.ok(gaps.at(-1) > gaps[0], `bekleme buyudu: ${gaps.join(',')}`);
  b.world.up = true;
  assert.equal(b.runUntil(() => b.wifi.isConnected(), 120000), true);
});

test('AP istemcisi (istasyon) bagliyken otomatik STA denemesi YAPILMAZ (tarama AP\'yi bozmasin); istemci gidince hemen denenir', () => {
  const b = makeBoard({ provisioned: true, sta: HOME });
  b.world.up = false;
  b.run(3.2 * MIN);
  assert.equal(b.wifi.isRecoveryApActive(), true);
  b.wifi.apClientsOverride = 1;
  b.run(1000);
  const before = b.wifi.reconnectCount;
  b.run(5 * MIN);
  assert.equal(b.wifi.reconnectCount, before, 'AP istemcisi bagliyken StaMachine BEGIN uretmez');
  b.wifi.apClientsOverride = 0;
  b.run(500);
  assert.equal(b.wifi.reconnectCount, before + 1, 'istemci gidince bekleme dolmus: hemen dene');
});

test('apStationCount: AP kapaliyken 0; istemci ag konumundan (ipucu) turetilir, QA ile gecersiz kilinir', () => {
  const b = makeBoard({ provisioned: true });
  b.wifi.apClientHint = true;
  assert.equal(b.wifi.apStationCount(), 0, 'AP yayinda degil');
  b.run(300);
  assert.equal(b.wifi.apStationCount(), 1, 'SoftAP\'ta istemci modelleniyor: 1 istasyon');
  b.wifi.apClientsOverride = 3;
  assert.equal(b.wifi.apStationCount(), 3);
  b.wifi.apClientsOverride = null;
  b.wifi.apClientHint = false;
  assert.equal(b.wifi.apStationCount(), 0);
});

// ====================================================================== sarma / uzun calisma
test('millis() 49,7 gun sarmasi: AP penceresi ve aday akisi sarma sinirinda aksamaz', () => {
  for (const t0 of [0xFFFFF000, 0x7FFFFF00, 0xFFFFFFF0]) {
    const b = makeBoard({ provisioned: true, sta: HOME, t0 });
    b.world.up = false;
    b.run(3.2 * MIN);
    assert.equal(b.wifi.isRecoveryApActive(), true, `taban ${t0.toString(16)}: 3 dk sonra pencere`);
    b.world.up = true;
    assert.equal(b.runUntil(() => b.wifi.isConnected(), 90000), true);
    b.wifi.requestConnect(HOME.ssid, HOME.pass);
    assert.equal(b.runUntil(() => b.status().state === ConnectState.SUCCESS, 20000), true, `taban ${t0.toString(16)}: aday akisi`);
  }
});
