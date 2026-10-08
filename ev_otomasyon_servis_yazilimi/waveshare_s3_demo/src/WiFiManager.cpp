#include "WiFiManager.h"
#include "ConfigManager.h"
#include "NetUtil.h"
#include "NetLink.h"
#include "EthLink.h"
#include <esp_wifi.h>
#include <esp_system.h>
#include <esp_timer.h>
#include <Preferences.h>
#include <string.h>
#include <time.h>

// ZAMAN KURALI (N6, CONTRACTS 3c): bu dosyada saklanmis "hedef zaman" + isaretli karsilastirma YOKTUR. Tum zamanlayicilar
// NetTime.h'deki "son olay + bekleme" ciftleridir (NetUtil::Wait) ve yalnizca wifi_task'ta degistirilir; her tur
// yoklanir (sure dolunca sonlanir). Diger gorevler istek bayragi (volatile bool) birakir.

namespace {

// Gorev dongusu ve zaman asimlari
const uint32_t TASK_TICK_MS = 250;
const uint32_t WATERMARK_LOG_MS = 600000;           // yigin izleme logu: 10 dk
const uint32_t AP_FAIL_LOG_MS = 30000;              // "AP baslatilamadi" log siniri

class MutexGuard {
public:
  MutexGuard(SemaphoreHandle_t m, uint32_t timeoutMs) : _m(m), _ok(false) {
    if (_m) _ok = (xSemaphoreTake(_m, pdMS_TO_TICKS(timeoutMs)) == pdTRUE);
  }
  ~MutexGuard() {
    if (_ok) xSemaphoreGive(_m);
  }
  bool ok() const { return _ok; }

private:
  SemaphoreHandle_t _m;
  bool _ok;
  MutexGuard(const MutexGuard&);
  MutexGuard& operator=(const MutexGuard&);
};

}  // namespace

WiFiManager::WiFiManager()
    : _mutex(nullptr),
      _connected(false),
      _localIP(),
      _gatewayIP(),
      _rssi(-100),
      _ssid(""),
      _pass(""),
      _reconnectCount(0),
      _connectTimestamp(0),
      _connectedAtUs(0),
      _connectSeq(0),
      _lastDisconnectReason(0),
      _evtDisconnected(false),
      _sntpPending(false),
      _reqReconnect(false),
      _reqStaReset(false),
      _reqServiceOpen(false),
      _reqServiceMs(0),
      _reqApStop(false),
      _reqApRestart(false),
      _sta(),
      _cand(),
      _candActive(false),
      _candStartReq(false),
      _candCancelReq(false),
      _candSsid(""),
      _candPass(""),
      _candSeq(0),
      _candState(ConnectState::IDLE),
      _candReason(0),
      _ap(),
      _apActive(false),
      _apSecured(false),
      _apFailLog(),
      _watermark(),
      _taskHandle(nullptr) {}

// ============================================================================
// Baslatma
// ============================================================================
void WiFiManager::begin() {
  if (_taskHandle != nullptr) return;   // ikinci kez baslatilmaz
  if (_mutex == nullptr) _mutex = xSemaphoreCreateMutex();

  printf("[WiFiManager] Wi-Fi Yoneticisi baslatiliyor (Core 0)...\r\n");

  // Surucu kendi kopyasini flash'a yazmasin: kimlik yalnizca ConfigManager (NVS) icinde tutulur.
  // Surucunun kendi yeniden baglanmasi kapali: tek WiFi.begin() sahibi bu sinif.
  WiFi.persistent(false);
  WiFi.setAutoReconnect(false);
  {
    char host[24];
    uint8_t mac[6];
    esp_read_mac(mac, ESP_MAC_WIFI_STA);
    snprintf(host, sizeof(host), "AHBU-%02X%02X%02X", mac[3], mac[4], mac[5]);
    WiFi.setHostname(host);
  }
  // main.cpp'nin erken actigi bir AP varsa (eski firmware davranisi) kapanir; AP'yi yalnizca bu sinif yonetir.
  WiFi.mode(WIFI_STA);
  esp_wifi_set_storage(WIFI_STORAGE_RAM);
  WiFi.softAPdisconnect(true);
  scrubLegacyWifiOnce();

  // NVS'ten kaydedilmis STA kimligi (ConfigLock icinde kopyalanir; _mutex ConfigLock disinda alinir)
  String savedSsid, savedPass;
  {
    ConfigManager::ConfigLock lk(ConfigManager::instance());
    const SystemConfig& cfg = ConfigManager::instance().config;
    if (cfg.wifi_sta_enabled && cfg.wifi_ssid[0] != '\0') {
      savedSsid = String(cfg.wifi_ssid);
      savedPass = String(cfg.wifi_pass);
    }
  }
  {
    MutexGuard g(_mutex, 200);
    _ssid = savedSsid;
    _pass = savedPass;
  }
  if (savedSsid.length() > 0) {
    printf("[WiFiManager] Kayitli STA SSID: '%s'\r\n", savedSsid.c_str());
  } else {
    printf("[WiFiManager] Kayitli STA Wi-Fi yok; kurulum AP penceresi acilacak.\r\n");
  }
  // (3 dk kesinti sayaci, ilk wifi_task turunda ApPolicy tarafindan baslatilir: acilista kesinti varsayilir.)

  WiFi.onEvent([this](WiFiEvent_t event, WiFiEventInfo_t info) { this->onWiFiEvent(event, info); });

  // 8 KB yigin: aday kimlik dogrulaninca ConfigManager::save() (NVS yazimi) bu gorevden cagrilir.
  xTaskCreatePinnedToCore(wifiTask, "wifi_task", 8192, this, 1, &_taskHandle, 0 /* Core 0 */);
}

// Eski firmware surumleri (ve main.cpp'nin onceki AP kodu) Wi-Fi ayarlarini (ornegin sabit AP parolasi)
// surucunun NVS ad alaninda sakladi. Yeni surumde ilk acilista bir kez silinir.
void WiFiManager::scrubLegacyWifiOnce() {
  Preferences p;
  if (!p.begin("ahbu_net", false)) return;
  if (!p.getBool("wf_scrub1", false)) {
    esp_err_t e = esp_wifi_restore();
    printf("[WiFiManager] Eski surucu Wi-Fi ayarlari temizlendi (esp_wifi_restore: %d).\r\n", (int)e);
    p.putBool("wf_scrub1", true);
    WiFi.mode(WIFI_STA);
    esp_wifi_set_storage(WIFI_STORAGE_RAM);
  }
  p.end();
}

// ============================================================================
// Olaylar (arduino_events gorevi baglami: kisa tutulur)
// ============================================================================
void WiFiManager::onConnected() {
  const IPAddress ip = WiFi.localIP();
  const IPAddress gw = WiFi.gatewayIP();
  const int8_t rssi = (int8_t)WiFi.RSSI();
  const uint32_t now = millis();
  const int64_t nowUs = esp_timer_get_time();
  {
    MutexGuard g(_mutex, 100);
    if (g.ok()) {
      _connected = true;
      _localIP = ip;
      _gatewayIP = gw;
      _rssi = rssi;
      _connectTimestamp = now;
      _connectedAtUs = nowUs;
      _connectSeq = _connectSeq + 1;
      _lastDisconnectReason = 0;   // yeni basarili baglanti: eski hata nedeni gecersiz
    }
  }
  _sntpPending = true;
}

void WiFiManager::onDisconnected(uint8_t reason) {
  MutexGuard g(_mutex, 100);
  if (g.ok()) {
    _connected = false;
    _localIP = IPAddress(0, 0, 0, 0);
    if (reason != 0) _lastDisconnectReason = reason;
  }
}

void WiFiManager::onWiFiEvent(WiFiEvent_t event, WiFiEventInfo_t info) {
  switch (event) {
    case ARDUINO_EVENT_WIFI_STA_START:
      printf("[WiFi Event] STA arayuzu baslatildi.\r\n");
      break;

    case ARDUINO_EVENT_WIFI_STA_CONNECTED:
      printf("[WiFi Event] Erisim noktasina baglandi (kanal %d), IP bekleniyor.\r\n",
             info.wifi_sta_connected.channel);
      break;

    case ARDUINO_EVENT_WIFI_STA_GOT_IP:
      onConnected();
      NetLink::captureDns(netlink::NetIf::WIFI);   // DHCP'nin az once yazdigi genel DNS = Wi-Fi'nin DNS'i (R1-4)
      printf("[WiFi Event] IP alindi: %s | Gateway: %s | Sinyal: %d dBm\r\n",
             WiFi.localIP().toString().c_str(), WiFi.gatewayIP().toString().c_str(), WiFi.RSSI());
      break;

    case ARDUINO_EVENT_WIFI_STA_LOST_IP:
      onDisconnected(0);
      printf("[WiFi Event] IP kaybedildi.\r\n");
      break;

    case ARDUINO_EVENT_WIFI_STA_DISCONNECTED: {
      uint8_t reason = info.wifi_sta_disconnected.reason;
      if (reason == 0) reason = 1;   // 0 "hata yok" ile karismasin (WIFI_REASON_UNSPECIFIED)
      onDisconnected(reason);
      _evtDisconnected = true;
      printf("[WiFi Event] Baglanti koptu/kurulamadi. Neden kodu: %d\r\n", reason);
      break;
    }

    case ARDUINO_EVENT_WIFI_AP_STACONNECTED:
      printf("[WiFi Event] AP'ye bir istemci baglandi.\r\n");
      break;

    case ARDUINO_EVENT_WIFI_AP_STADISCONNECTED:
      printf("[WiFi Event] AP'den bir istemci ayrildi.\r\n");
      break;

    default:
      break;
  }
}

// Olaylar kacirilsa bile durum WiFi.status() ile duzeltilir.
void WiFiManager::reconcileStatus() {
  const bool real = (WiFi.status() == WL_CONNECTED) && (WiFi.localIP() != IPAddress(0, 0, 0, 0));
  bool known;
  {
    MutexGuard g(_mutex, 100);
    known = _connected;
  }
  if (real && !known) {
    onConnected();
  } else if (!real && known) {
    onDisconnected(0);
  } else if (real) {
    MutexGuard g(_mutex, 20);
    if (g.ok()) _rssi = (int8_t)WiFi.RSSI();
  }
}

// ============================================================================
// Gorev
// ============================================================================
void WiFiManager::wifiTask(void* parameter) {
  WiFiManager* self = static_cast<WiFiManager*>(parameter);
  for (;;) {
    self->tick();
    vTaskDelay(pdMS_TO_TICKS(TASK_TICK_MS));
  }
}

void WiFiManager::tick() {
  const uint32_t now = millis();
  reconcileStatus();
  stepCandidate(now);
  stepSta(now);

  // Ethernet: olay kacmissa (baglanti var, adres yok) IP durumu esp_netif'ten tamamlanir (v1.3.0).
  EthLink::service();
  // DNS: etkin arayuz degistiyse ya da bir arayuz yeni kira aldiysa genel DNS etkin arayuzunkine cekilir (R1-4).
  NetLink::serviceDns(isConnected());

  // SNTP: herhangi bir arayuzde (Wi-Fi GOT_IP ya da Ethernet DHCP) adres alindiktan sonra bir kez baslatilir (periyodik yenilemeyi lwIP
  // SNTP kendisi yapar). Karar NetLinkCore::sntpDue (Ethernet yokken bugunku "Wi-Fi bagli" kosuluyla ayni).
  if (netlink::sntpDue(_sntpPending, isConnected(), NetLink::ethUp())) {
    _sntpPending = false;
    configTime(3 * 3600, 0, "pool.ntp.org", "time.google.com", "time.cloudflare.com");
    printf("[WiFiManager] SNTP zaman senkronizasyonu baslatildi.\r\n");
  }

  stepAp(now);

  _apFailLog.service(now);
  // Yigin izleme (saha dogrulamasi icin): 10 dakikada bir
  if (_watermark.elapsed(now)) {
    printf("[WiFiManager] Yigin: en az %u bayt bos kaldi (toplam 8192)\r\n", (unsigned)uxTaskGetStackHighWaterMark(nullptr));
    _watermark.arm(now, WATERMARK_LOG_MS);
  }
}

void WiFiManager::beginSta(const String& ssid, const String& pass) {
  _evtDisconnected = false;
  {
    MutexGuard g(_mutex, 100);
    _reconnectCount++;
    _lastDisconnectReason = 0;   // yeni deneme basladi
  }
  printf("[WiFiManager] STA baglantisi kuruluyor... SSID: '%s' (deneme: %u)\r\n", ssid.c_str(),
         (unsigned)getReconnectCount());
  WiFi.begin(ssid.c_str(), pass.length() > 0 ? pass.c_str() : nullptr);
}

// ---- Otomatik STA baglanma (ustel geri cekilme; mantik NetUtil::StaMachine) ----------------------------------
void WiFiManager::stepSta(uint32_t now) {
  // Diger gorevlerin istekleri (zamanlayicilari yalniz bu gorev degistirir)
  if (_reqStaReset) {
    _reqStaReset = false;
    _sta.reset();
  }
  if (_reqReconnect) {
    _reqReconnect = false;
    _sta.reconnectNow();
  }
  if (_candActive) {   // aday deneme sirasinda otomatik yol durur (zamanlayicilar yine yoklanir)
    _sta.service(now);
    return;
  }

  String ssid, pass;
  bool connected;
  {
    MutexGuard g(_mutex, 100);
    ssid = _ssid;
    pass = _pass;
    connected = _connected;
  }
  // Kurulum AP'sine bir istemci bagliyken otomatik deneme yapilmaz (tarama AP'yi bozar).
  const bool apBlocks = _apActive && WiFi.softAPgetStationNum() > 0;

  const NetUtil::StaMachine::Action a = _sta.update(now, connected, ssid.length() > 0, _evtDisconnected, apBlocks);
  if (a == NetUtil::StaMachine::TIMEOUT) {
    // Basarisiz: surucunun tarama/kanal degisimiyle AP'yi bozmamasi icin STA'yi sustur
    WiFi.disconnect(false, false);
    printf("[WiFiManager] Baglanti kurulamadi (neden: %u). %u sn sonra tekrar denenecek.\r\n",
           (unsigned)_lastDisconnectReason, (unsigned)(_sta.retry.span / 1000));
  } else if (a == NetUtil::StaMachine::BEGIN) {
    beginSta(ssid, pass);
  }
}

// ---- Aday kimlik (POST /api/wifi/connect) -------------------------------------
WiFiManager::ConnectRequest WiFiManager::requestConnect(const char* ssid, const char* pass) {
  if (ssid == nullptr) return ConnectRequest::INVALID_SSID;
  const size_t sl = strlen(ssid);
  if (sl < 1 || sl > 32) return ConnectRequest::INVALID_SSID;
  const size_t pl = pass ? strlen(pass) : 0;
  if (pl != 0 && (pl < 8 || pl > 63)) return ConnectRequest::INVALID_PASS;

  MutexGuard g(_mutex, 200);
  if (!g.ok()) return ConnectRequest::BUSY;
  if (_candActive) return ConnectRequest::BUSY;

  _candSsid = String(ssid);
  _candPass = String(pass ? pass : "");
  _candState = ConnectState::CONNECTING;
  _candReason = 0;
  _candActive = true;      // wifi_task akisi ~0.5 sn sonra (HTTP yaniti cikabilsin diye) baslatir
  _candStartReq = true;
  return ConnectRequest::ACCEPTED;
}

WiFiManager::ConnectStatus WiFiManager::getConnectStatus() {
  ConnectStatus st;
  st.state = ConnectState::IDLE;
  st.reason = 0;
  MutexGuard g(_mutex, 50);
  if (g.ok()) {
    st.state = _candState;
    st.reason = _candReason;
  }
  return st;
}

void WiFiManager::commitCandidate() {
  String s, p;
  {
    MutexGuard g(_mutex, 200);
    s = _candSsid;
    p = _candPass;
    _ssid = s;
    _pass = p;
    _candActive = false;
    _candState = ConnectState::SUCCESS;
    _candReason = 0;
    _candSsid = "";
    _candPass = "";
  }
  _sta.markConnected();
  printf("[WiFiManager] Aday Wi-Fi dogrulandi (SSID: '%s'); NVS'e kaydediliyor.\r\n", s.c_str());

  // NVS'e yalnizca baglanti dogrulaninca islenir (_mutex tutulmaz: kilit sirasi ConfigLock -> _mutex yok)
  bool ok;
  {
    ConfigManager::ConfigLock lk(ConfigManager::instance());
    SystemConfig& cfg = ConfigManager::instance().config;
    strncpy(cfg.wifi_ssid, s.c_str(), sizeof(cfg.wifi_ssid) - 1);
    cfg.wifi_ssid[sizeof(cfg.wifi_ssid) - 1] = '\0';
    strncpy(cfg.wifi_pass, p.c_str(), sizeof(cfg.wifi_pass) - 1);
    cfg.wifi_pass[sizeof(cfg.wifi_pass) - 1] = '\0';
    cfg.wifi_sta_enabled = true;
    ok = ConfigManager::instance().save();
  }
  if (!ok) printf("[WiFiManager] UYARI: Wi-Fi kimligi NVS'e yazilamadi (yalnizca RAM'de).\r\n");
}

// Aday akisi (mantik NetUtil::CandidateFlow): 0,5 sn -> eski baglantiyi birak (0,4 sn) -> baglan (25 sn) -> dogrula/geri don.
void WiFiManager::stepCandidate(uint32_t now) {
  if (_candCancelReq) {
    _candCancelReq = false;
    _cand.cancel();
  }
  if (_candStartReq) {
    _candStartReq = false;
    _cand.start(now);
  }
  if (_cand.phase == NetUtil::CandidateFlow::NONE) return;

  // Yalnizca bu denemeden SONRA alinan IP gecerlidir (zaman damgasi degil GOT_IP sayaci): eski baglantinin kalintisi
  // adayi "dogrulanmis" saydirmaz.
  bool connectedSince;
  {
    MutexGuard g(_mutex, 100);
    connectedSince = _connected && (_connectSeq != _candSeq);
  }

  const NetUtil::CandidateFlow::Action a = _cand.update(now, connectedSince, _evtDisconnected);
  switch (a) {
    case NetUtil::CandidateFlow::DO_DISCONNECT:
      // Eski baglantiyi birak; kopma olaylari sonsun
      WiFi.disconnect(false, false);
      _sta.candidateStarted();
      break;

    case NetUtil::CandidateFlow::DO_BEGIN: {
      String s, p;
      {
        MutexGuard g(_mutex, 200);
        s = _candSsid;
        p = _candPass;
      }
      _candSeq = _connectSeq;
      beginSta(s, p);
      break;
    }

    case NetUtil::CandidateFlow::COMMIT:
      commitCandidate();
      break;

    case NetUtil::CandidateFlow::FAILED: {
      const uint8_t reason = _lastDisconnectReason;
      WiFi.disconnect(false, false);
      bool hadOld;
      {
        MutexGuard g(_mutex, 200);
        _candActive = false;
        _candState = ConnectState::FAILED;
        _candReason = reason;
        _candSsid = "";
        _candPass = "";
        hadOld = (_ssid.length() > 0);
      }
      printf("[WiFiManager] Aday Wi-Fi baglantisi BASARISIZ (neden: %u); %s.\r\n", (unsigned)reason,
             hadOld ? "eski kimlige donuluyor" : "kayitli kimlik yok");
      _sta.candidateFailed(now, hadOld);
      break;
    }

    default:
      break;
  }
}

// ---- Kimlik temizleme / dogrudan atama -------------------------------------------
bool WiFiManager::clearCredentials() {
  bool ok;
  {
    ConfigManager::ConfigLock lk(ConfigManager::instance());
    SystemConfig& cfg = ConfigManager::instance().config;
    cfg.wifi_ssid[0] = '\0';
    memset(cfg.wifi_pass, 0, sizeof(cfg.wifi_pass));
    cfg.wifi_sta_enabled = false;
    ok = ConfigManager::instance().save();
  }
  {
    MutexGuard g(_mutex, 200);
    _ssid = "";
    _pass = "";
    _candActive = false;
    _candState = ConnectState::IDLE;
    _candReason = 0;
    _candSsid = "";
    _candPass = "";
  }
  _candCancelReq = true;   // wifi_task: aday akisini ve otomatik denemeyi sifirlar
  _reqStaReset = true;
  WiFi.disconnect(false, false);
  printf("[WiFiManager] STA kimligi temizlendi.\r\n");
  return ok;
}

void WiFiManager::setCredentials(const char* ssid, const char* pass) {
  {
    MutexGuard g(_mutex, 200);
    _ssid = String(ssid ? ssid : "");
    _pass = String(pass ? pass : "");
    _lastDisconnectReason = 0;   // yeni kimlik: eski hata nedeni gecersiz
    _candActive = false;
    _candSsid = "";
    _candPass = "";
  }
  _candCancelReq = true;
  _reqStaReset = true;             // geri cekilme sifirlanir, hemen denenir
  WiFi.disconnect(false, false);   // yeni kimlikle yeniden baglansin (veya bos ise bagli kalmasin)
}

void WiFiManager::triggerReconnect() {
  _reqReconnect = true;
}

// ============================================================================
// AP yonetimi
// ============================================================================
String WiFiManager::apSsid() {
  uint8_t mac[6];
  esp_read_mac(mac, ESP_MAC_WIFI_STA);
  char b[20];
  snprintf(b, sizeof(b), "AHBU-%02X%02X%02X", mac[3], mac[4], mac[5]);   // 11 karakter (< 32 bayt)
  return String(b);
}

void WiFiManager::startAp(bool openNetwork, const char* pass, uint32_t now) {
  const String ssid = apSsid();
  const IPAddress localIp(192, 168, 4, 1);
  const IPAddress gateway(192, 168, 4, 1);
  const IPAddress subnet(255, 255, 255, 0);
  WiFi.softAPConfig(localIp, gateway, subnet);
  const bool ok = WiFi.softAP(ssid.c_str(), openNetwork ? nullptr : pass, 1, 0, 3);
  if (ok) {
    _apSecured = !openNetwork;   // WPA2 yalnizca parolayla baslatildiysa (AP-kaynakli yetki: ApAccess)
    _apActive = true;
    if (openNetwork) {
      printf("[WiFiManager] KURULUM AP acildi: '%s' (ACIK: cihaz provizyonsuz) | http://192.168.4.1\r\n",
             ssid.c_str());
    } else {
      printf("[WiFiManager] KURTARMA AP acildi: '%s' (WPA2, parola = cihaza ozel ap_pass) | http://192.168.4.1\r\n",
             ssid.c_str());
    }
  } else {
    // (now: wifi_task turunun zamani; zamanlayici ayni tur icinde de ayni "now" ile yoklanir)
    if (_apFailLog.elapsed(now)) {
      printf("[WiFiManager] HATA: AP baslatilamadi, tekrar denenecek.\r\n");
      _apFailLog.arm(now, AP_FAIL_LOG_MS);
    }
  }
}

void WiFiManager::stopAp() {
  _apSecured = false;   // once: AP kapanirken "WPA2" iddiasi kalmasin
  WiFi.softAPdisconnect(true);
  _apActive = false;
  printf("[WiFiManager] AP kapatildi.\r\n");
}

// AP penceresi (mantik NetUtil::ApPolicy): bu islev yalniz girdileri toplar ve istenen eylemi uygular.
void WiFiManager::stepAp(uint32_t now) {
  // Diger gorevlerin istekleri
  if (_reqServiceOpen) {
    _reqServiceOpen = false;
    const uint32_t ms = _reqServiceMs;
    _ap.openService(now, ms);
    printf("[WiFiManager] Servis AP penceresi istendi (%u sn).\r\n", (unsigned)(ms / 1000));
  }
  if (_reqApStop) {
    _reqApStop = false;
    _ap.closeAll(now);
  }
  if (_reqApRestart) {
    _reqApRestart = false;
    _ap.requestRestart(now);
  }

  // Kimlik/AP parolasi (ConfigLock icinde kopya; _mutex tutulmaz)
  bool provisioned;
  char apPass[AP_PASS_MAX_LEN + 1];
  {
    ConfigManager::ConfigLock lk(ConfigManager::instance());
    const SystemConfig& cfg = ConfigManager::instance().config;
    provisioned = cfg.hasLocalKey();
    memcpy(apPass, cfg.ap_pass, sizeof(apPass));
    apPass[sizeof(apPass) - 1] = '\0';
  }
  const bool passOk = strlen(apPass) >= AP_PASS_MIN_LEN;
  // Provizyonlu cihaz yalnizca gecerli ap_pass ile AP acar; provizyonsuz cihaz acik AP acar.
  const bool openNetwork = !provisioned;

  NetUtil::ApPolicy::In in;
  in.allowed = !provisioned || passOk;
  const bool ethUp = NetLink::ethUp();   // v1.3.0 (K-Ş1): Ethernet bagliyken kurtarma AP'si acilmaz (NetLinkCore::apPolicyConnected)
  {
    MutexGuard g(_mutex, 100);
    in.connected = netlink::apPolicyConnected(_connected, ethUp, provisioned);   // provizyonsuz kartta Ethernet sayilmaz (R1-1)
    in.staConfigured = (_ssid.length() > 0);
  }
  in.apActive = _apActive;
  in.clients = _apActive ? (uint8_t)WiFi.softAPgetStationNum() : (uint8_t)0;

  const NetUtil::ApPolicy::Out out = _ap.update(now, in);
  if (out.serviceExpired) printf("[WiFiManager] Servis AP penceresi doldu.\r\n");
  if (out.opened) {
    printf("[WiFiManager] Kurtarma/kurulum AP penceresi acildi (%u dk).\r\n",
           (unsigned)(NetUtil::ApPolicy::WINDOW_MS / 60000));
  }
  if (out.closedStable) printf("[WiFiManager] STA kararli baglandi; kurtarma AP penceresi kapatiliyor.\r\n");
  if (out.ended) printf("[WiFiManager] AP penceresi bitti.\r\n");

  if (out.startAp) {
    startAp(openNetwork, apPass, now);
  } else if (out.stopAp) {
    stopAp();
  } else if (out.restartAp) {
    stopAp();
    startAp(openNetwork, apPass, now);
  }
  memset(apPass, 0, sizeof(apPass));
}

void WiFiManager::openServiceAp(uint32_t windowMs) {
  _reqServiceMs = windowMs;
  _reqServiceOpen = true;
}

void WiFiManager::stopRecoveryAP() {
  _reqApStop = true;
}

void WiFiManager::applyApConfigChange() {
  _reqApRestart = true;
}

void WiFiManager::factoryResetWifi() {
  _reqApStop = true;   // (yeniden baslatmaya kadar wifi_task calisirsa) AP'yi yeniden acmasin
  if (_apActive) stopAp();
  WiFi.disconnect(false, false);
  const esp_err_t e = esp_wifi_restore();
  printf("[WiFiManager] Fabrika sifirlama: surucu Wi-Fi ayarlari silindi (esp_wifi_restore: %d).\r\n", (int)e);
}

// ============================================================================
// Durum sorgulari
// ============================================================================
bool WiFiManager::isConnected() {
  MutexGuard g(_mutex, 20);
  if (g.ok()) return _connected;
  return (WiFi.status() == WL_CONNECTED);
}

bool WiFiManager::isConnecting() {
  return (_sta.state == NetUtil::StaMachine::CONNECTING) || _candActive;
}

IPAddress WiFiManager::getLocalIP() {
  IPAddress ip(0, 0, 0, 0);
  MutexGuard g(_mutex, 20);
  if (g.ok()) ip = _localIP;
  return ip;
}

IPAddress WiFiManager::getGatewayIP() {
  IPAddress gw(0, 0, 0, 0);
  MutexGuard g(_mutex, 20);
  if (g.ok()) gw = _gatewayIP;
  return gw;
}

int8_t WiFiManager::getRSSI() {
  int8_t r = -100;
  MutexGuard g(_mutex, 20);
  if (g.ok()) r = _rssi;
  return r;
}

String WiFiManager::getSSID() {
  String s = "";
  MutexGuard g(_mutex, 20);
  if (g.ok()) s = _ssid;
  return s;
}

String WiFiManager::getMacAddress() {
  return WiFi.macAddress();
}

uint32_t WiFiManager::getReconnectCount() {
  uint32_t c = 0;
  MutexGuard g(_mutex, 20);
  if (g.ok()) c = _reconnectCount;
  return c;
}

// Baglanti suresi (sn): 64 bit esp_timer damgasiyla (millis() 49,7 gunde tasar; bu hesap tasmaz).
uint32_t WiFiManager::getUptimeSeconds() {
  int64_t atUs;
  bool conn;
  {
    MutexGuard g(_mutex, 20);
    if (!g.ok()) return 0;
    atUs = _connectedAtUs;
    conn = _connected;
  }
  if (!conn || atUs == 0) return 0;
  const int64_t d = esp_timer_get_time() - atUs;
  return d > 0 ? (uint32_t)(d / 1000000LL) : 0u;
}

uint32_t WiFiManager::getLastConnectTime() {
  MutexGuard g(_mutex, 20);
  return g.ok() ? _connectTimestamp : 0;
}

uint8_t WiFiManager::getLastDisconnectReason() {
  return _lastDisconnectReason;
}

bool WiFiManager::isTimeSynced() {
  return NetUtil::isTimeSynced();
}

String WiFiManager::getDeviceUid() {
  uint8_t mac[6];
  esp_read_mac(mac, ESP_MAC_WIFI_STA);
  char b[24];
  snprintf(b, sizeof(b), "AHBU-S3-%02X%02X%02X", mac[3], mac[4], mac[5]);
  return String(b);
}

bool WiFiManager::isRecoveryApActive() {
  return _apActive;
}

bool WiFiManager::isRecoveryApSecured() {
  return _apActive && _apSecured;
}

String WiFiManager::getRecoveryApSSID() {
  return apSsid();
}
