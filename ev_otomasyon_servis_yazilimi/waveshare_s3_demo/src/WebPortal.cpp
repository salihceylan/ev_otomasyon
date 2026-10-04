#include "WebPortal.h"
#include "WebPortalPage.h"
#include "ConfigManager.h"
#include "SmartAutomation.h"
#include "DeviceCommand.h"
#include "MqttManager.h"
#include "WiFiManager.h"
#include "NetUtil.h"
#include "ApAccess.h"
#include <WiFi.h>
#include <ArduinoJson.h>
#include <esp_timer.h>
#include <string.h>
#include <stdlib.h>
#include <algorithm>

namespace {

// ---- Sinirlar ---------------------------------------------------------------------------------
// ZAMAN KURALI (N6, CONTRACTS 3c): bu dosyada saklanmis "hedef zaman" + isaretli karsilastirma YOKTUR. Kimlik kilitleri
// (NetUtil::AuthLimiter), tarama kapisi (NetUtil::ScanGate) ve AP kaynakli anahtarsiz connect hiz siniri
// (ApAccess::ConnectLimiter) NetTime.h'deki "son olay + bekleme" ciftleridir; web gorevinin her turunda yoklanir
// (housekeeping), sure dolunca sonlanir.
const size_t MAX_BODY_BYTES = 24576;
const size_t MAX_SCAN_RESULTS = 20;
const uint32_t RESTART_DELAY_MS = 600;
const uint32_t WATERMARK_LOG_MS = 600000;

const char CSP_HEADER[] =
    "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:; "
    "connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'";

// ---- Kimlik hatasi sinirlayici (IP basina 5 hata -> 60 sn kilit; genel 20 hata/60 sn) -- yalniz web gorevi ---------
NetUtil::AuthLimiter g_auth;

// ---- AP kaynakli ANAHTARSIZ POST /api/wifi/connect icin GLOBAL hiz siniri (60 sn'de en cok 6; ApAccess.h) -- yalniz web gorevi ---
// Anahtarli (gecerli X-Device-Key) istekler bu sinira girmez. Her turda service() ile yoklanir (ZAMAN KURALI).
ApAccess::ConnectLimiter g_apConnect;

volatile bool g_wifiRestorePending = false;

// ---- JSON alan erisimi (tip dogrulamali) ------------------------------------------------------
enum FieldState : uint8_t { FIELD_OK, FIELD_MISSING, FIELD_BAD };

FieldState fieldString(JsonObject o, const char* key, const char*& out) {
  if (!o.containsKey(key)) return FIELD_MISSING;
  JsonVariant v = o[key];
  if (!v.is<const char*>()) return FIELD_BAD;   // null / sayi / nesne => strncpy(nullptr) cokmesi yok
  out = v.as<const char*>();
  return out ? FIELD_OK : FIELD_BAD;
}
FieldState fieldBool(JsonObject o, const char* key, bool& out) {
  if (!o.containsKey(key)) return FIELD_MISSING;
  JsonVariant v = o[key];
  if (!v.is<bool>()) return FIELD_BAD;
  out = v.as<bool>();
  return FIELD_OK;
}
FieldState fieldInt(JsonObject o, const char* key, int& out) {
  if (!o.containsKey(key)) return FIELD_MISSING;
  JsonVariant v = o[key];
  if (!v.is<int>()) return FIELD_BAD;
  out = v.as<int>();
  return FIELD_OK;
}

size_t jsonCapacityFor(size_t bodyLen) {
  size_t c = bodyLen * 3 + 512;
  if (c < 1024) c = 1024;
  if (c > 40960) c = 40960;
  return c;
}

// ---- Host / Origin ---------------------------------------------------------------------------
bool isDigits(const String& s) {
  if (s.length() == 0) return false;
  for (size_t i = 0; i < s.length(); i++) {
    if (s[i] < '0' || s[i] > '9') return false;
  }
  return true;
}

bool isIpv4Literal(const String& s) {
  int parts = 0;
  size_t start = 0;
  while (true) {
    int dot = s.indexOf('.', start);
    String part = (dot < 0) ? s.substring(start) : s.substring(start, dot);
    if (!isDigits(part) || part.length() > 3 || part.toInt() > 255) return false;
    parts++;
    if (dot < 0) break;
    start = (size_t)dot + 1;
  }
  return parts == 4;
}

// Izinli Host: IPv4 sabiti, "localhost" veya "*.local" (mDNS). Diger her ad (DNS-rebinding) reddedilir.
bool isAllowedHost(const String& hostHeader) {
  String h = hostHeader;
  h.trim();
  h.toLowerCase();
  if (h.length() == 0 || h.length() > 80) return false;
  String name = h;
  const int colon = h.lastIndexOf(':');
  if (colon >= 0) {
    name = h.substring(0, colon);
    String port = h.substring(colon + 1);
    if (!isDigits(port) || port.length() > 5) return false;
  }
  if (name == "localhost") return true;
  if (isIpv4Literal(name)) return true;
  if (name.length() > 6 && name.endsWith(".local")) {
    for (size_t i = 0; i < name.length(); i++) {
      const char c = name[i];
      const bool ok = (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-' || c == '.';
      if (!ok) return false;
    }
    return true;
  }
  return false;
}

String stripDefaultPort(String hostPort) {
  hostPort.trim();
  hostPort.toLowerCase();
  if (hostPort.endsWith(":80")) hostPort.remove(hostPort.length() - 3);
  return hostPort;
}

// Origin (varsa) sayfanin kendi kaynagi olmali: http://<Host>
bool originMatchesHost(const String& origin, const String& host) {
  String o = origin;
  o.trim();
  o.toLowerCase();
  if (!o.startsWith("http://")) return false;
  return stripDefaultPort(o.substring(7)) == stripDefaultPort(host);
}

// ---- Yapilandirma goruntusu (kilit altinda kopya; JSON'a basilacak metinler temizlenmis) ------
struct CfgView {
  char deviceName[32];
  char wifiSsid[64];
  bool extEnabled;
  uint8_t extChannels;
  uint8_t extAddress;
  uint32_t rs485Baud;
  bool staEnabled;
  char relayName[MAX_TOTAL_RELAYS][32];
  uint8_t relayType[MAX_TOTAL_RELAYS];
  uint16_t relayRuntime[MAX_TOTAL_RELAYS];
  char diName[MAX_TOTAL_DIS][32];
  uint8_t diTarget[MAX_TOTAL_DIS];
  uint8_t diMode[MAX_TOTAL_DIS];
  uint8_t totalRelays;
  uint8_t totalDIs;
  bool provisioned;
  bool mqttConfigured;
};

CfgView* takeCfgView() {
  CfgView* v = (CfgView*)malloc(sizeof(CfgView));
  if (!v) return nullptr;
  ConfigManager::ConfigLock lk(ConfigManager::instance());
  const SystemConfig& c = ConfigManager::instance().config;
  NetUtil::sanitizeInto(v->deviceName, sizeof(v->deviceName), c.device_name);
  NetUtil::sanitizeInto(v->wifiSsid, sizeof(v->wifiSsid), c.wifi_ssid);
  v->extEnabled = c.ext_module_enabled;
  v->extChannels = c.ext_module_channels;
  v->extAddress = c.ext_module_address;
  v->rs485Baud = c.rs485_baud;
  v->staEnabled = c.wifi_sta_enabled;
  v->totalRelays = c.totalRelays();
  v->totalDIs = c.totalDIs();
  v->provisioned = c.hasLocalKey();
  v->mqttConfigured = c.hasMqttCredentials() && c.mqtt_enabled;
  for (int i = 0; i < MAX_TOTAL_RELAYS; i++) {
    NetUtil::sanitizeInto(v->relayName[i], sizeof(v->relayName[i]), c.relays[i].name);
    v->relayType[i] = c.relays[i].type;
    v->relayRuntime[i] = c.relays[i].runtime_sec;
  }
  for (int i = 0; i < MAX_TOTAL_DIS; i++) {
    NetUtil::sanitizeInto(v->diName[i], sizeof(v->diName[i]), c.dis[i].name);
    v->diTarget[i] = c.dis[i].target_relay;
    v->diMode[i] = c.dis[i].mode;
  }
  return v;
}

// ---- Yapilandirma kaydi dogrulamasi ------------------------------------------------------------
// root'u c (gecici kopya) icine uygular; hata varsa err'e makine kodu yazar. Hicbir alan sessizce
// varsayilana dusmez: tip/aralik hatasi => reddedilir.
bool parseConfigInto(JsonObject root, SystemConfig& c, const char*& err) {
  const char* s = nullptr;
  bool b = false;
  int n = 0;

  FieldState fs = fieldString(root, "device_name", s);
  if (fs == FIELD_BAD) { err = "invalid_device_name"; return false; }
  if (fs == FIELD_OK) {
    const size_t len = strlen(s);
    if (len == 0 || !NetUtil::isCleanUtf8(s, len)) { err = "invalid_device_name"; return false; }
    NetUtil::copyUtf8Truncated(c.device_name, sizeof(c.device_name), s);
  }

  fs = fieldBool(root, "ext_module_enabled", b);
  if (fs == FIELD_BAD) { err = "invalid_value"; return false; }
  if (fs == FIELD_OK) c.ext_module_enabled = b;

  fs = fieldInt(root, "ext_module_channels", n);
  if (fs == FIELD_BAD) { err = "invalid_ext_channels"; return false; }
  if (fs == FIELD_OK) {
    if (n < 0 || n > 255 || !isValidExtChannelCount((uint8_t)n)) { err = "invalid_ext_channels"; return false; }
    c.ext_module_channels = (uint8_t)n;
  }
  // Etkin ama kanal sayisi 0: varsayilan 8 (cihaz da ayni normalizasyonu yapar)
  if (c.ext_module_enabled && c.ext_module_channels == 0) c.ext_module_channels = 8;

  fs = fieldInt(root, "ext_module_address", n);
  if (fs == FIELD_BAD) { err = "invalid_ext_address"; return false; }
  if (fs == FIELD_OK) {
    if (n < 1 || n > 247) { err = "invalid_ext_address"; return false; }
    c.ext_module_address = (uint8_t)n;
  }

  // ---- Roleler ----
  if (root.containsKey("relays")) {
    if (!root["relays"].is<JsonArray>()) { err = "invalid_value"; return false; }
    JsonArray ra = root["relays"].as<JsonArray>();
    if (ra.size() > MAX_TOTAL_RELAYS) { err = "too_large"; return false; }
    for (size_t i = 0; i < ra.size(); i++) {
      JsonObject r = ra[i];
      if (r.isNull()) { err = "invalid_value"; return false; }
      RelayConfig& rc = c.relays[i];

      fs = fieldString(r, "name", s);
      if (fs == FIELD_BAD) { err = "invalid_name"; return false; }
      if (fs == FIELD_OK) {
        if (!NetUtil::isCleanUtf8(s, strlen(s))) { err = "invalid_name"; return false; }
        NetUtil::copyUtf8Truncated(rc.name, sizeof(rc.name), s);
      }

      int type = rc.type;
      fs = fieldInt(r, "type", n);
      if (fs == FIELD_BAD || (fs == FIELD_OK && (n < 0 || n > RELAY_TYPE_IMPULSE))) { err = "invalid_type"; return false; }
      if (fs == FIELD_OK) type = n;

      int runtime = rc.runtime_sec;
      fs = fieldInt(r, "runtime_sec", n);
      if (fs == FIELD_BAD || (fs == FIELD_OK && (n < 0 || n > 65535))) { err = "invalid_runtime"; return false; }
      if (fs == FIELD_OK) runtime = n;

      if (type == RELAY_TYPE_SHUTTER_UP || type == RELAY_TYPE_SHUTTER_DOWN) {
        if (runtime < SHUTTER_RUNTIME_MIN_SEC || runtime > SHUTTER_RUNTIME_MAX_SEC) { err = "invalid_runtime"; return false; }
      } else if (type == RELAY_TYPE_IMPULSE) {
        if (runtime == 0) runtime = IMPULSE_MS_DEFAULT;
        if (runtime > IMPULSE_MS_MAX) { err = "invalid_runtime"; return false; }
      } else {
        runtime = 0;   // lamba: sure anlamsiz
      }
      rc.type = (uint8_t)type;
      rc.runtime_sec = (uint16_t)runtime;
    }

    // Panjur rolelerinin (Yukari/Asagi) eslesmesi: yetim panjur rolesi kabul edilmez
    const uint8_t activeR = c.totalRelays();
    for (uint8_t p = 0; p < activeR / 2; p++) {
      const uint8_t t1 = c.relays[2 * p].type;
      const uint8_t t2 = c.relays[2 * p + 1].type;
      const bool up1 = (t1 == RELAY_TYPE_SHUTTER_UP);
      const bool down2 = (t2 == RELAY_TYPE_SHUTTER_DOWN);
      if (up1 != down2) { err = "invalid_shutter_pair"; return false; }
      if (t1 == RELAY_TYPE_SHUTTER_DOWN || t2 == RELAY_TYPE_SHUTTER_UP) { err = "invalid_shutter_pair"; return false; }
    }
  }

  const uint8_t totalR = c.totalRelays();
  const uint8_t totalD = c.totalDIs();

  // ---- Girisler ----
  if (root.containsKey("dis")) {
    if (!root["dis"].is<JsonArray>()) { err = "invalid_value"; return false; }
    JsonArray da = root["dis"].as<JsonArray>();
    if (da.size() > MAX_TOTAL_DIS) { err = "too_large"; return false; }
    for (size_t i = 0; i < da.size(); i++) {
      JsonObject d = da[i];
      if (d.isNull()) { err = "invalid_value"; return false; }
      DIConfig& dc = c.dis[i];

      fs = fieldString(d, "name", s);
      if (fs == FIELD_BAD) { err = "invalid_name"; return false; }
      if (fs == FIELD_OK) {
        if (!NetUtil::isCleanUtf8(s, strlen(s))) { err = "invalid_name"; return false; }
        NetUtil::copyUtf8Truncated(dc.name, sizeof(dc.name), s);
      }

      fs = fieldInt(d, "target_relay", n);
      const int limit = (i < totalD) ? totalR : MAX_TOTAL_RELAYS;
      if (fs == FIELD_BAD || (fs == FIELD_OK && (n < 0 || n > limit))) { err = "invalid_target_relay"; return false; }
      if (fs == FIELD_OK) dc.target_relay = (uint8_t)n;

      fs = fieldInt(d, "mode", n);
      if (fs == FIELD_BAD || (fs == FIELD_OK && (n < 0 || n > DI_MODE_SHUTTER_DOWN))) { err = "invalid_mode"; return false; }
      if (fs == FIELD_OK) dc.mode = (uint8_t)n;
    }
  }
  // Ek modul kapatilir/kuculurse artik var olmayan role hedefleri (istekte acikca gelmeyenler) devre disi
  // birakilir; kullanicinin kendi eylemi bu yuzden reddedilmez.
  for (uint8_t i = 0; i < MAX_TOTAL_DIS; i++) {
    const int limit = (i < totalD) ? totalR : MAX_TOTAL_RELAYS;
    if (c.dis[i].target_relay > limit) c.dis[i].target_relay = 0;
  }
  return true;
}

// Panjur hareketini/guvenligini etkileyen bir alan degisiyor mu? (tip, sure, ek modul)
// Yalnizca ad degisiklikleri hareket sirasinda da kabul edilir.
bool shutterRelevantChange(const SystemConfig& a, const SystemConfig& b) {
  if (a.ext_module_enabled != b.ext_module_enabled || a.ext_module_channels != b.ext_module_channels ||
      a.ext_module_address != b.ext_module_address) {
    return true;
  }
  for (int i = 0; i < MAX_TOTAL_RELAYS; i++) {
    if (a.relays[i].type != b.relays[i].type || a.relays[i].runtime_sec != b.relays[i].runtime_sec) return true;
  }
  return false;
}

// Host adi: harf/rakam/'.'/'-', 1..63, '.' veya '-' ile baslamaz/bitmez
bool validMqttHost(const char* s) {
  if (!s) return false;
  const size_t n = strlen(s);
  if (n < 1 || n > 63) return false;
  if (s[0] == '.' || s[0] == '-' || s[n - 1] == '.' || s[n - 1] == '-') return false;
  for (size_t i = 0; i < n; i++) {
    const char c = s[i];
    const bool ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '.' || c == '-';
    if (!ok) return false;
  }
  return true;
}

const char* connectStateName(WiFiManager::ConnectState s) {
  switch (s) {
    case WiFiManager::ConnectState::CONNECTING: return "connecting";
    case WiFiManager::ConnectState::SUCCESS: return "success";
    case WiFiManager::ConnectState::FAILED: return "failed";
    default: return "idle";
  }
}

}  // namespace

// ============================================================================
// Yasam dongusu
// ============================================================================
WebPortal& WebPortal::instance() {
  static WebPortal inst;
  return inst;
}

WebPortal::WebPortal() : _server(80), _taskHandle(nullptr), _scan(), _viaApOrigin(false) {}

void WebPortal::begin() {
  if (_taskHandle != nullptr) return;
  // Yalnizca dogrulama icin gereken basliklar toplanir (Host ayrica hostHeader() ile gelir)
  static const char* kHeaders[] = {"X-Device-Key", "Content-Type", "Origin"};
  _server.collectHeaders(kHeaders, 3);
  setupRoutes();
  _server.begin();
  if (!SmartAutomation::registerPreRestartHook(&WebPortal::preRestartHook)) {
    printf("WebPortal: UYARI: yeniden baslatma kancasi kaydedilemedi.\r\n");
  }
  // HTTP islemleri loopTask'ta DEGIL, ayri bir gorevde yurur. WebServer kutuphanesi istegi AYRISTIRIRKEN
  // (readStringUntil -> Stream::timedRead) her bayt icin ayri zaman asimiyla yield() dongusunde bekler: bayt bayt
  // sizan bir istemci bu beklemeyi sinirsiz uzatir ve beklerken CPU'yu daha dusuk oncelikli gorevlere vermez.
  //  * Core 0'da bu, IDLE0'i aclikta birakirdi; sdkconfig'te IDLE0 TWDT'ye abonedir (CHECK_IDLE_TASK_CPU0) ve
  //    panic=true oldugundan 10 sn sonra cihaz YENIDEN BASLARDI (kimlik dogrulamasi gerektirmeden).
  //  * Core 1'de IDLE1 TWDT'ye abone DEGIL; ayrica gorev ONCELIK 0'dadir (bosta gorevi ile ayni): loopTask
  //    (oncelik 1) uyandigi anda onu keser, TWDT'si ve duvar anahtari/panjur isleme gecikmez.
  // Bu gorev TWDT'ye KAYITLI DEGILDIR; en kotu durumda yalniz web arayuzu/LAN API bir istemci sizdirirken yanit vermez.
  xTaskCreatePinnedToCore(webTask, "WebTask", 10240, this, tskIDLE_PRIORITY, &_taskHandle, 1);
  printf("WebPortal: Web sunucusu 80 portunda baslatildi (ayri gorev, Core 1, oncelik 0; kimlik dogrulamali).\r\n");
}

void WebPortal::webTask(void* parameter) {
  WebPortal* self = static_cast<WebPortal*>(parameter);
  NetUtil::Wait watermark;
  for (;;) {
    self->_server.handleClient();   // bos turda kutuphane 1 ms bekler
    vTaskDelay(pdMS_TO_TICKS(2));
    // Housekeeping (N6): dolan kimlik kilitleri / tarama sayaclari HER turda sonlandirilir. Bir istemci aylarca
    // sessiz kalsa da kilit/hiz siniri "hala suruyor" gorunmez (423 / "scanning" donmez).
    const uint32_t now = millis();
    g_auth.service(now);
    g_apConnect.service(now);
    self->_scan.service(now);
    if (watermark.elapsed(now)) {
      printf("WebPortal: Yigin: en az %u bayt bos kaldi (toplam 10240)\r\n", (unsigned)uxTaskGetStackHighWaterMark(nullptr));
      watermark.arm(now, WATERMARK_LOG_MS);
    }
  }
}

// ---- loop-affine isler (loopTask <-> WebTask posta kutusu) ------------------------------------------------
// FW-core kurali: role/panjur/YAPILANDIRMA durumunu tek baglam (loopTask) degistirir; SmartAutomation
// ConfigManager::config'i KILITSIZ okur ve rs485ControlExtRelay yalniz loopTask'tan cagrilabilir. HTTP islemleri
// ise ayri bir gorevde (WebTask) yurudugunden, canli yapilandirmayi degistiren/ham RS485 komutu veren adimlar
// BURAYA postalanir ve WebPortal::loop() icinde (loopTask) yurutulur. Yavas NVS yazimi (save) web gorevinde kalir.
// Durumlar: 0 bos, 1 bekliyor, 2 calisiyor, 3 bitti.
namespace {

enum LoopJobType : uint8_t {
  JOB_NONE = 0,
  JOB_RS485_RELAY,      // SmartAutomation::rs485ControlExtRelay (yalniz loopTask)
  JOB_CONFIG_APPLY,     // dogrulanmis yapilandirmayi canliya uygula
  JOB_RS485_BAUD,       // cfg.rs485_baud + rs485Begin
  JOB_FACTORY_RESET     // ConfigManager::resetToDefaults
};
enum LoopJobResult : uint8_t { JR_OK = 0, JR_FAILED = 1, JR_BUSY_SHUTTER = 2 };
enum JobStatus : uint8_t { JS_DONE, JS_BUSY, JS_NOT_STARTED, JS_STILL_RUNNING };

struct LoopJob {
  volatile uint8_t state;
  uint8_t type;
  uint8_t slaveId;
  uint8_t channel;
  uint8_t action;
  uint32_t baud;
  SystemConfig* cfg;      // JOB_CONFIG_APPLY: gecici kopya. Is KABUL edilince sahiplik loopTask'a gecer (orada free edilir)
  volatile uint8_t result;
  char response[96];
};
LoopJob g_job;            // statik depolama: sifir baslatilir (state = 0)

// ---- loopTask tarafi ----
bool shutterBusyNow() {
  AutomationSnapshot snap;
  if (!SmartAutomation::instance().getSnapshot(snap)) return true;   // belirsizse mesgul say
  for (uint8_t p = 0; p < snap.totalPairs && p < (MAX_TOTAL_RELAYS / 2); p++) {
    if (snap.shutters[p].moving || snap.shutters[p].waiting) return true;
  }
  return false;
}

// tmp: web gorevinde dogrulanmis kopya. Panjur hareket halindeyken sure/tip/ek modul degisimi reddedilir
// (yalnizca ad degisikligi kabul); aksi halde bu endpoint'in sahip oldugu alan gruplari canliya yazilir.
// tmp burada free edilir.
uint8_t applyConfigOnLoop(SystemConfig* tmp) {
  uint8_t r = JR_OK;
  {
    ConfigManager::ConfigLock lk(ConfigManager::instance());
    SystemConfig& live = ConfigManager::instance().config;
    if (shutterBusyNow() && shutterRelevantChange(live, *tmp)) {
      r = JR_BUSY_SHUTTER;
    } else {
      // Kimlik/Wi-Fi/MQTT alanlarina dokunulmaz
      memcpy(live.device_name, tmp->device_name, sizeof(live.device_name));
      live.ext_module_enabled = tmp->ext_module_enabled;
      live.ext_module_channels = tmp->ext_module_channels;
      live.ext_module_address = tmp->ext_module_address;
      memcpy(live.relays, tmp->relays, sizeof(live.relays));
      memcpy(live.dis, tmp->dis, sizeof(live.dis));
      live.validate();
    }
  }
  free(tmp);
  return r;
}

// ---- web gorevi tarafi ----
// JS_DONE: result/response gecerli. JS_BUSY / JS_NOT_STARTED: is kabul EDILMEDI (cfg sahipligi cagirandadir).
// JS_STILL_RUNNING: loopTask isi aldi ama beklenen surede bitirmedi (cfg'yi o free eder; sonuc bilinmiyor).
JobStatus runLoopJob(uint8_t type, uint8_t slaveId, uint8_t channel, uint8_t action, uint32_t baud,
                     SystemConfig* cfg, uint8_t& result, String* response) {
  if (g_job.state == 3) g_job.state = 0;   // onceki (zaman asimina ugramis) isin artigi
  if (g_job.state != 0) return JS_BUSY;
  g_job.type = type;
  g_job.slaveId = slaveId;
  g_job.channel = channel;
  g_job.action = action;
  g_job.baud = baud;
  g_job.cfg = cfg;
  g_job.result = JR_FAILED;
  g_job.response[0] = '\0';
  __sync_synchronize();
  g_job.state = 1;

  const uint32_t t0 = millis();
  while (g_job.state != 3) {
    const uint32_t waited = (uint32_t)(millis() - t0);
    if (g_job.state == 1 && waited > 1500) {
      // loopTask 1.5 sn icinde almadi: vazgec (yarisa karsi CAS)
      if (__sync_bool_compare_and_swap(&g_job.state, (uint8_t)1, (uint8_t)0)) return JS_NOT_STARTED;
    }
    if (waited > 6000) return JS_STILL_RUNNING;
    vTaskDelay(pdMS_TO_TICKS(5));
  }
  result = g_job.result;
  if (response) *response = String(g_job.response);
  g_job.state = 0;
  return JS_DONE;
}

}  // namespace

// loopTask baglami (WebPortal::loop). SOKETE DOKUNMAZ; bos turda ~mikrosaniye.
void WebPortal::loop() {
  if (g_job.state != 1) return;
  if (!__sync_bool_compare_and_swap(&g_job.state, (uint8_t)1, (uint8_t)2)) return;   // web gorevi vazgecti

  uint8_t result = JR_FAILED;
  switch (g_job.type) {
    case JOB_RS485_RELAY: {
      String resp;
      const bool ok = SmartAutomation::instance().rs485ControlExtRelay(g_job.slaveId, g_job.channel, g_job.action, &resp);
      strncpy(g_job.response, resp.c_str(), sizeof(g_job.response) - 1);
      g_job.response[sizeof(g_job.response) - 1] = '\0';
      result = ok ? JR_OK : JR_FAILED;
      break;
    }
    case JOB_CONFIG_APPLY: {
      SystemConfig* tmp = g_job.cfg;
      g_job.cfg = nullptr;
      result = tmp ? applyConfigOnLoop(tmp) : (uint8_t)JR_FAILED;
      break;
    }
    case JOB_RS485_BAUD: {
      {
        ConfigManager::ConfigLock lk(ConfigManager::instance());
        ConfigManager::instance().config.rs485_baud = g_job.baud;
      }
      SmartAutomation::instance().rs485Begin(g_job.baud);
      result = JR_OK;
      break;
    }
    case JOB_FACTORY_RESET:
      result = ConfigManager::instance().resetToDefaults() ? JR_OK : JR_FAILED;
      break;
    default:
      break;
  }
  g_job.result = result;
  __sync_synchronize();
  g_job.state = 3;
}

// Fabrika sifirlama sonrasi (yanit gittikten sonra, yeniden baslatmadan hemen once)
void WebPortal::preRestartHook() {
  if (g_wifiRestorePending) {
    g_wifiRestorePending = false;
    // Kancalar kayit sirasiyla calisir (WebPortal, MqttManager'dan once kaydolur): Wi-Fi koparilmadan ONCE MQTT
    // "offline" durumunu yayinlamali ve baglantiyi temiz kapatmali. prepareForRestart() tekrar cagrilirsa zararsizdir.
    MqttManager::instance().prepareForRestart();
    WiFiManager::instance().factoryResetWifi();
  }
}

// ============================================================================
// Yonlendirme ve ortak kontroller
// ============================================================================
void WebPortal::route(const char* uri, HTTPMethod method, Handler handler, Access access) {
  _server.on(uri, method, [this, handler, access]() { this->dispatch(handler, access); });
}

void WebPortal::dispatch(Handler handler, Access access) {
  if (!guardRequest()) return;
  _viaApOrigin = false;   // her istekte sifirlanir; yalniz authorizeApOrKeyed() anahtarsiz AP yolunda kurar
  if (access == Access::KEYED && !authorize()) return;
  if (access == Access::AP_OR_KEYED && !authorizeApOrKeyed()) return;
  (this->*handler)();
}

void WebPortal::setupRoutes() {
  // CORS basligi ve OPTIONS yaniti YOKTUR: tarayicinin on-kontrolu (preflight) basarisiz olur.
  route("/", HTTP_GET, &WebPortal::handleRoot, Access::PUBLIC);

  route("/api/status", HTTP_GET, &WebPortal::handleApiStatus, Access::PUBLIC);
  route("/api/factory/init", HTTP_POST, &WebPortal::handleApiFactoryInit, Access::FACTORY);

  route("/api/auth/check", HTTP_GET, &WebPortal::handleApiAuthCheck, Access::KEYED);
  route("/api/auth/check", HTTP_POST, &WebPortal::handleApiAuthCheck, Access::KEYED);
  route("/api/auth/rekey", HTTP_POST, &WebPortal::handleApiRekey, Access::KEYED);
  route("/api/mqtt/config", HTTP_POST, &WebPortal::handleApiMqttConfig, Access::KEYED);

  route("/api/relay", HTTP_POST, &WebPortal::handleApiRelay, Access::KEYED);
  route("/api/all", HTTP_POST, &WebPortal::handleApiAll, Access::KEYED);
  route("/api/child-lock", HTTP_GET, &WebPortal::handleApiChildLockGet, Access::KEYED);
  route("/api/child-lock", HTTP_POST, &WebPortal::handleApiChildLockPost, Access::KEYED);

  route("/api/config", HTTP_GET, &WebPortal::handleApiConfigGet, Access::KEYED);
  route("/api/config", HTTP_POST, &WebPortal::handleApiConfigSave, Access::KEYED);

  // Wi-Fi servis akisi: gecerli X-Device-Key YA DA AP kaynakli yetki (CONTRACTS 3d). Yalniz bu UC uc; digerleri KEYED.
  route("/api/wifi/scan", HTTP_GET, &WebPortal::handleApiWifiScan, Access::AP_OR_KEYED);
  route("/api/wifi/connect", HTTP_POST, &WebPortal::handleApiWifiConnect, Access::AP_OR_KEYED);
  route("/api/wifi/status", HTTP_GET, &WebPortal::handleApiWifiStatus, Access::AP_OR_KEYED);
  route("/api/wifi/disconnect", HTTP_POST, &WebPortal::handleApiWifiDisconnect, Access::KEYED);

  route("/api/rs485/send", HTTP_POST, &WebPortal::handleApiRs485Send, Access::KEYED);
  route("/api/rs485/logs", HTTP_GET, &WebPortal::handleApiRs485Logs, Access::KEYED);
  route("/api/rs485/clear", HTTP_POST, &WebPortal::handleApiRs485Clear, Access::KEYED);
  route("/api/rs485/baud", HTTP_POST, &WebPortal::handleApiRs485Baud, Access::KEYED);
  route("/api/rs485/scan", HTTP_POST, &WebPortal::handleApiRs485ScanStart, Access::KEYED);
  route("/api/rs485/scan", HTTP_GET, &WebPortal::handleApiRs485ScanResult, Access::KEYED);
  route("/api/rs485/relay", HTTP_POST, &WebPortal::handleApiRs485Relay, Access::KEYED);

  route("/api/system/reboot", HTTP_POST, &WebPortal::handleApiReboot, Access::KEYED);
  route("/api/system/reset", HTTP_POST, &WebPortal::handleApiReset, Access::KEYED);

  _server.onNotFound([this]() { this->handleNotFound(); });
}

void WebPortal::sendSecurityHeaders() {
  _server.sendHeader("X-Content-Type-Options", "nosniff");
  _server.sendHeader("X-Frame-Options", "DENY");
  _server.sendHeader("Referrer-Policy", "no-referrer");
  _server.sendHeader("Cache-Control", "no-store");
}

void WebPortal::sendJson(int code, const String& body) {
  sendSecurityHeaders();
  _server.send(code, "application/json", body);
}

void WebPortal::sendError(int code, const char* error) {
  String b;
  b.reserve(40);
  b += "{\"error\":\"";
  b += error;
  b += "\"}";
  sendJson(code, b);
}

void WebPortal::sendOk() {
  sendJson(200, "{\"status\":\"ok\"}");
}

void WebPortal::sendQueued() {
  sendJson(200, "{\"status\":\"queued\"}");
}

// Host/Origin dogrulamasi (DNS-rebinding ve capraz kaynak istek savunmasi)
bool WebPortal::guardRequest() {
  const String host = _server.hostHeader();
  if (host.length() > 0 && !isAllowedHost(host)) {
    sendError(400, "bad_host");
    return false;
  }
  const String origin = _server.header("Origin");
  if (origin.length() > 0 && !originMatchesHost(origin, host)) {
    sendError(403, "bad_origin");
    return false;
  }
  return true;
}

// X-Device-Key denetimi (yanit GONDERMEZ). enforceLockAndCount=true: IP kilidi (423) yoklanir, dogru anahtar sayaci
// sifirlar, YANLIS anahtar hata sayacina islenir (5 hata -> 60 sn kilit). false (AP kaynakli yol): kilit ve sayac islemez
// (yalniz "gecerli anahtar sunuldu mu" sorulur; sonuc erisimi zaten AP yetkisi belirlediginden bir sizinti/oracle olusmaz).
WebPortal::KeyCheck WebPortal::checkKey(bool enforceLockAndCount, uint32_t& retryAfterSec) {
  ConfigManager& cm = ConfigManager::instance();
  char localKey[LOCAL_KEY_MAX_LEN + 1];
  bool provisioned;
  {
    ConfigManager::ConfigLock lk(cm);
    provisioned = cm.config.hasLocalKey();
    memcpy(localKey, cm.config.local_key, sizeof(localKey));
    localKey[sizeof(localKey) - 1] = '\0';
  }
  if (!provisioned) {
    memset(localKey, 0, sizeof(localKey));
    return KeyCheck::UNPROVISIONED;
  }

  const uint32_t now = millis();
  const uint32_t ip = (uint32_t)_server.client().remoteIP();
  g_auth.service(now);   // (bu istek handleClient icindeyken tur yoklamasi atlanmis olabilir)

  // Kilit: IP basina veya genel (kalan sure = bekleme - gecen sure; saklanmis hedef yok)
  if (enforceLockAndCount && g_auth.locked(ip, now, retryAfterSec)) {
    memset(localKey, 0, sizeof(localKey));
    return KeyCheck::LOCKED;
  }

  const String presented = _server.header("X-Device-Key");
  if (presented.length() == 0) {
    memset(localKey, 0, sizeof(localKey));
    return KeyCheck::MISSING;   // anahtarsiz istek hatali deneme sayilmaz
  }

  const bool ok = NetUtil::constantTimeEquals(presented.c_str(), localKey);
  memset(localKey, 0, sizeof(localKey));
  if (ok) {
    if (enforceLockAndCount) g_auth.success(ip);
    return KeyCheck::VALID;
  }

  // Hatali anahtar
  if (enforceLockAndCount) {
    g_auth.failure(ip, now);
    uint32_t lockSec = 0;
    if (g_auth.locked(ip, now, lockSec)) {
      printf("[WEB] Hatali anahtar denemesi: erisim %u sn kilitlendi.\r\n", (unsigned)lockSec);
    }
  }
  return KeyCheck::WRONG;
}

// X-Device-Key dogrulamasi (KEYED uclar). true = yetkili; false = yanit zaten gonderildi.
bool WebPortal::authorize() {
  uint32_t sec = 0;
  switch (checkKey(true, sec)) {
    case KeyCheck::VALID:
      return true;
    case KeyCheck::UNPROVISIONED:
      sendError(403, "unprovisioned");
      return false;
    case KeyCheck::LOCKED: {
      _server.sendHeader("Retry-After", String(sec));
      String b = "{\"error\":\"locked\",\"retry_after\":";
      b += String(sec);
      b += "}";
      sendJson(423, b);
      return false;
    }
    case KeyCheck::MISSING:
    case KeyCheck::WRONG:
    default:
      sendError(401, "unauthorized");
      return false;
  }
}

// (a) Istemci SoftAP arayuzunde mi? Karar ApAccess::clientOnSoftAp'tadir (saf, testli); burada yalniz girdiler toplanir.
// Uzak IP = baglanti kuran istemcinin adresi (TCP el sikismasi tamamlandigi icin sahte kaynak adresi olamaz); AP alt agi =
// WiFi.softAPIP()/softAPSubnetMask(); STA alt agi cakisirsa (ev modemi de 192.168.4.0/24 ise) istemci AP sayilmaz.
bool WebPortal::remoteOnSoftAp() {
  const uint32_t remote = (uint32_t)_server.client().remoteIP();
  return ApAccess::clientOnSoftAp(WiFiManager::instance().isRecoveryApActive(), remote, (uint32_t)WiFi.softAPIP(),
                                  (uint32_t)WiFi.softAPSubnetMask(), (uint32_t)WiFi.localIP(),
                                  (uint32_t)WiFi.subnetMask());
}

// AP_OR_KEYED uclar (wifi scan/connect/status): gecerli X-Device-Key YA DA AP kaynakli yetki (ApAccess, CONTRACTS 3d):
//   (a) istemci SoftAP arayuzunde, (b) AP su an WPA2 + gecerli ap_pass var, (c) cihaz provizyonlu.
// AP kaynakli yol acik degilse (AP disi, ACIK kurulum AP'si, ap_pass yok) istek KEYED gibi islenir (401/403/423).
// AP kaynakli yolda anahtar gerekmez: gecerli anahtar sunulduysa "anahtarli" sayilir (hiz siniri yok), aksi halde
// (yok/yanlis) anahtarsiz AP yolu (_viaApOrigin; connect icin hiz siniri) -- yanlis anahtar bu yolda hata sayacina islenmez.
bool WebPortal::authorizeApOrKeyed() {
  bool provisioned;
  bool hasApPass;
  {
    ConfigManager::ConfigLock lk(ConfigManager::instance());
    const SystemConfig& c = ConfigManager::instance().config;
    provisioned = c.hasLocalKey();
    hasApPass = strlen(c.ap_pass) >= AP_PASS_MIN_LEN;
  }
  if (!provisioned) {   // provizyonsuz (ACIK kurulum AP'si dahil): yalniz factory/init + kisitli status
    sendError(403, "unprovisioned");
    return false;
  }

  const bool onAp = remoteOnSoftAp();
  const bool wpa2 = WiFiManager::instance().isRecoveryApSecured();
  if (!ApAccess::apOrigin(onAp, wpa2, hasApPass, provisioned)) return authorize();

  uint32_t unused = 0;
  const bool keyOk = (checkKey(false, unused) == KeyCheck::VALID);
  _viaApOrigin = (ApAccess::via(onAp, wpa2, hasApPass, provisioned, keyOk) == ApAccess::VIA_AP);
  return true;
}

// JSON istegi on kosullari: Content-Type application/json, govde var ve sinirli boyutta
bool WebPortal::readJsonBody(String& body) {
  String ct = _server.header("Content-Type");
  ct.toLowerCase();
  if (!ct.startsWith("application/json")) {
    sendError(415, "unsupported_media_type");
    return false;
  }
  if (!_server.hasArg("plain")) {
    sendError(400, "empty_body");
    return false;
  }
  body = _server.arg("plain");
  if (body.length() == 0) {
    sendError(400, "empty_body");
    return false;
  }
  if (body.length() > MAX_BODY_BYTES) {
    sendError(413, "too_large");
    return false;
  }
  return true;
}

// Govdeyi ayristirir; kok nesne degilse veya bozuksa 400 gonderir (fail-open YOK).
bool WebPortal::parseJsonObject(const String& body, DynamicJsonDocument& doc) {
  if (doc.capacity() == 0) {
    sendError(503, "busy");
    return false;
  }
  const DeserializationError e = deserializeJson(doc, body);
  if (e == DeserializationError::NoMemory) {
    sendError(413, "too_large");
    return false;
  }
  if (e || !doc.is<JsonObject>()) {
    sendError(400, "invalid_json");
    return false;
  }
  return true;
}

// Komutu kuyruga yazar; kuyruk doluysa sessizce yutmaz: loglar ve 503 doner.
bool WebPortal::postOrFail(const DeviceCommand& cmd) {
  if (!postDeviceCommand(cmd)) {
    printf("[WEB] UYARI: komut kuyrugu dolu, komut dusuruldu (tip %d).\r\n", (int)cmd.type);
    sendError(503, "queue_full");
    return false;
  }
  // Sonuc (child_lock, last_id, rol/panjur durumu) bulutta bayat kalmasin: durum yayini ~250 ms icinde
  MqttManager::instance().triggerPublish();
  return true;
}

// ============================================================================
// Sayfa ve bulunamayan yollar
// ============================================================================
void WebPortal::handleRoot() {
  sendSecurityHeaders();
  _server.sendHeader("Content-Security-Policy", CSP_HEADER);
  _server.send_P(200, "text/html; charset=utf-8", INDEX_HTML);
}

void WebPortal::handleNotFound() {
  // CORS/OPTIONS yok: bilinmeyen her yol (OPTIONS dahil) 404
  sendSecurityHeaders();
  if (_server.uri().startsWith("/api/")) {
    sendJson(404, "{\"error\":\"not_found\"}");
  } else {
    _server.send(404, "text/plain", "Not Found");
  }
}

// ============================================================================
// Durum
// ============================================================================
void WebPortal::handleApiStatus() {
  ConfigManager& cm = ConfigManager::instance();
  const bool provisioned = cm.hasLocalKey();
  // Anahtar basligi gonderilmediyse KISITLI ozet; gonderildiyse dogrulanip tam durum
  if (provisioned && _server.hasHeader("X-Device-Key")) {
    if (!authorize()) return;
    sendFullStatus();
    return;
  }
  sendRestrictedStatus(provisioned);
}

void WebPortal::sendRestrictedStatus(bool provisioned) {
  char name[32];
  {
    ConfigManager::ConfigLock lk(ConfigManager::instance());
    NetUtil::sanitizeInto(name, sizeof(name), ConfigManager::instance().config.device_name);
  }
  const String uid = WiFiManager::instance().getDeviceUid();
  DynamicJsonDocument doc(384);
  doc["device"] = uid;
  doc["name"] = (const char*)name;
  doc["fw"] = FW_VERSION;
  doc["provisioned"] = provisioned;
  doc["wifi_connected"] = WiFiManager::instance().isConnected();
  String out;
  serializeJson(doc, out);
  sendJson(200, out);
}

void WebPortal::sendFullStatus() {
  AutomationSnapshot snap;
  if (!SmartAutomation::instance().getSnapshot(snap)) {
    sendError(503, "busy");
    return;
  }
  CfgView* v = takeCfgView();
  if (!v) {
    sendError(503, "busy");
    return;
  }

  WiFiManager& wm = WiFiManager::instance();
  const bool staConnected = wm.isConnected();
  const IPAddress staIp = wm.getLocalIP();
  const IPAddress apIp = WiFi.softAPIP();
  char staIpStr[16], apIpStr[16], ipStr[16];
  snprintf(staIpStr, sizeof(staIpStr), "%u.%u.%u.%u", staIp[0], staIp[1], staIp[2], staIp[3]);
  snprintf(apIpStr, sizeof(apIpStr), "%u.%u.%u.%u", apIp[0], apIp[1], apIp[2], apIp[3]);
  snprintf(ipStr, sizeof(ipStr), "%s", staConnected ? staIpStr : apIpStr);
  const String staSsidRaw = staConnected ? wm.getSSID() : (v->staEnabled ? String(v->wifiSsid) : String(""));
  const String staSsid = NetUtil::sanitizeUtf8(staSsidRaw.c_str(), 32);
  const String uid = wm.getDeviceUid();
  const String apSsid = wm.getRecoveryApSSID();
  const WiFiManager::ConnectStatus cs = wm.getConnectStatus();

  const uint8_t nR = (snap.totalRelays > MAX_TOTAL_RELAYS) ? (uint8_t)MAX_TOTAL_RELAYS : snap.totalRelays;
  const uint8_t nP = nR / 2;
  const uint8_t nD = (snap.totalDIs > MAX_TOTAL_DIS) ? (uint8_t)MAX_TOTAL_DIS : snap.totalDIs;

  const size_t cap = JSON_OBJECT_SIZE(40) + JSON_ARRAY_SIZE(nR) + (size_t)nR * JSON_OBJECT_SIZE(4) +
                     JSON_ARRAY_SIZE(nP) + (size_t)nP * JSON_OBJECT_SIZE(8) + JSON_ARRAY_SIZE(nD) +
                     (size_t)nD * JSON_OBJECT_SIZE(3) + 512;
  DynamicJsonDocument doc(cap);
  if (doc.capacity() == 0) {
    free(v);
    sendError(503, "busy");
    return;
  }

  doc["device"] = uid;
  doc["name"] = (const char*)v->deviceName;
  doc["device_name"] = (const char*)v->deviceName;
  doc["fw"] = FW_VERSION;
  doc["provisioned"] = true;
  doc["ip"] = (const char*)ipStr;
  doc["wifi_rssi"] = staConnected ? WiFi.RSSI() : 0;
  doc["uptime_sec"] = (uint32_t)(esp_timer_get_time() / 1000000ULL);
  doc["wifi_connected"] = staConnected;
  doc["wifi_sta_ssid"] = staSsid;
  doc["wifi_sta_ip"] = staConnected ? (const char*)staIpStr : "";
  doc["wifi_sta_rssi"] = staConnected ? WiFi.RSSI() : 0;
  doc["wifi_ap_active"] = wm.isRecoveryApActive();
  doc["wifi_ap_ip"] = (const char*)apIpStr;
  doc["wifi_ap_ssid"] = apSsid;
  doc["wifi_last_reason"] = wm.getLastDisconnectReason();
  doc["wifi_connect_state"] = connectStateName(cs.state);
  doc["wifi_connect_reason"] = cs.reason;
  doc["time_synced"] = wm.isTimeSynced();
  doc["mqtt_configured"] = v->mqttConfigured;
  doc["mqtt_connected"] = MqttManager::instance().isConnected();
  doc["ext_module_enabled"] = v->extEnabled;
  doc["ext_module_channels"] = v->extChannels;
  doc["ext_module_address"] = v->extAddress;
  doc["ext_module_responding"] = snap.extModuleResponding;
  doc["total_relays"] = v->totalRelays;
  doc["total_dis"] = v->totalDIs;
  doc["child_lock"] = snap.childLock;
  doc["last_id"] = (const char*)snap.lastId;

  JsonArray rArr = doc.createNestedArray("relays");
  for (uint8_t i = 0; i < nR; i++) {
    JsonObject r = rArr.createNestedObject();
    r["id"] = i + 1;
    r["name"] = (const char*)v->relayName[i];
    r["type"] = v->relayType[i];
    r["state"] = snap.relay(i);
  }

  JsonArray sArr = doc.createNestedArray("shutters");
  for (uint8_t p = 0; p < nP; p++) {
    const ShutterSnapshot& sh = snap.shutters[p];
    JsonObject s = sArr.createNestedObject();
    s["pair"] = p + 1;   // 1 tabanli
    s["is_shutter"] = sh.configured;   // FW-core: gecerli (UP+DOWN) panjur cifti
    s["is_moving"] = sh.moving;
    s["moving"] = sh.moving;
    s["dir"] = sh.dir;
    s["pos"] = sh.pos;
    s["target"] = sh.target;
  }

  JsonArray dArr = doc.createNestedArray("dis");
  for (uint8_t i = 0; i < nD; i++) {
    JsonObject d = dArr.createNestedObject();
    d["id"] = i + 1;
    d["name"] = (const char*)v->diName[i];
    d["state"] = snap.di(i);
  }

  if (doc.overflowed()) {
    free(v);
    printf("[WEB] HATA: durum JSON havuzu tasti (kapasite %u).\r\n", (unsigned)cap);
    sendError(500, "internal");
    return;
  }
  const size_t len = measureJson(doc);
  String out;
  out.reserve(len + 1);
  serializeJson(doc, out);
  free(v);   // adlara isaret eden dizgeler serilestirildi
  sendJson(200, out);
}

// ============================================================================
// Role / panjur komutlari (1 tabanli; hepsi postDeviceCommand kuyruguna)
// ============================================================================
void WebPortal::handleApiRelay() {
  uint8_t totalR;
  {
    ConfigManager::ConfigLock lk(ConfigManager::instance());
    totalR = ConfigManager::instance().config.totalRelays();
  }
  const uint8_t totalPairs = totalR / 2;

  const bool hasPair = _server.hasArg("pair");
  const bool hasCh = _server.hasArg("ch");
  if (hasPair == hasCh) {   // ikisi birden veya hicbiri
    sendError(400, "invalid_command");
    return;
  }

  if (hasPair) {
    long pair = 0;
    if (!NetUtil::parseIntStrict(_server.arg("pair"), pair) || pair < 1 || pair > totalPairs) {
      sendError(400, "invalid_pair");   // 1 tabanli
      return;
    }
    const String cmd = _server.arg("cmd");
    DeviceCommand c;
    if (cmd == "up") c = makeCommand(CmdType::SHUTTER_UP, CmdSource::WEB, (uint8_t)pair);
    else if (cmd == "down") c = makeCommand(CmdType::SHUTTER_DOWN, CmdSource::WEB, (uint8_t)pair);
    else if (cmd == "stop") c = makeCommand(CmdType::SHUTTER_STOP, CmdSource::WEB, (uint8_t)pair);
    else if (cmd == "step") c = makeCommand(CmdType::SHUTTER_STEP, CmdSource::WEB, (uint8_t)pair);
    else if (cmd == "pos") {
      long val = 0;
      // val zorunlu ve 0..100 (toInt() ile sessiz 0 yok)
      if (!_server.hasArg("val") || !NetUtil::parseIntStrict(_server.arg("val"), val) || val < 0 || val > 100) {
        sendError(400, "invalid_value");
        return;
      }
      c = makeCommand(CmdType::SHUTTER_POS, CmdSource::WEB, (uint8_t)pair, (int32_t)val);
    } else {
      sendError(400, "unknown_command");
      return;
    }
    if (postOrFail(c)) sendQueued();
    return;
  }

  long ch = 0;
  if (!NetUtil::parseIntStrict(_server.arg("ch"), ch) || ch < 1 || ch > totalR) {
    sendError(400, "invalid_channel");
    return;
  }
  const bool hasCmd = _server.hasArg("cmd");
  const bool hasState = _server.hasArg("state");
  if (hasCmd == hasState) {   // tam olarak biri
    sendError(400, "invalid_command");
    return;
  }
  DeviceCommand c;
  if (hasCmd) {
    if (_server.arg("cmd") != "toggle") {
      sendError(400, "unknown_command");
      return;
    }
    c = makeCommand(CmdType::RELAY_TOGGLE, CmdSource::WEB, (uint8_t)ch);
  } else {
    const String st = _server.arg("state");
    if (st != "0" && st != "1") {
      sendError(400, "invalid_value");
      return;
    }
    c = makeCommand(CmdType::RELAY_SET, CmdSource::WEB, (uint8_t)ch, st == "1" ? 1 : 0);
  }
  if (postOrFail(c)) sendQueued();
}

void WebPortal::handleApiAll() {
  const String cmd = _server.arg("cmd");
  CmdType t;
  if (cmd == "lightsoff") t = CmdType::ALL_LIGHTS_OFF;
  else if (cmd == "shuttersdown") t = CmdType::ALL_SHUTTERS_DOWN;
  else if (cmd == "shuttersup") t = CmdType::ALL_SHUTTERS_UP;
  else if (cmd == "shuttersstop") t = CmdType::ALL_SHUTTERS_STOP;
  else {
    sendError(400, _server.hasArg("cmd") ? "unknown_command" : "invalid_command");   // bilinmeyen komut 200 degil
    return;
  }
  if (postOrFail(makeCommand(t, CmdSource::WEB))) sendQueued();
}

void WebPortal::handleApiChildLockGet() {
  // isChildLockEnabled() anlik goruntu mutex'i alinamazsa sessizce "false" doner (kilitliyken "acik"
  // raporlamak = fail-open raporlama); burada goruntu alinamazsa 503 doneriz.
  AutomationSnapshot snap;
  if (!SmartAutomation::instance().getSnapshot(snap)) {
    sendError(503, "busy");
    return;
  }
  sendJson(200, snap.childLock ? "{\"child_lock\":true}" : "{\"child_lock\":false}");
}

// POST {"enabled":bool} -- DAR sozlesme: govde bir nesne olmali, YALNIZCA "enabled" anahtari ve JSON boolean
// degeri kabul edilir. Ayristirma hatasi, eksik/yinelenen/bilinmeyen anahtar, bool olmayan deger ("true"
// metni, sayi, null) => 400 ve durum DEGISMEZ (eski "doc[enabled] | doc[child_lock] | false" bozuk govdede
// kilidi sessizce KAPATIYORDU). Uygulama yalnizca postDeviceCommand(SET_CHILD_LOCK) ile; yanit {"status":"queued"}.
void WebPortal::handleApiChildLockPost() {
  String body;
  if (!readJsonBody(body)) return;
  DynamicJsonDocument doc(jsonCapacityFor(body.length()));
  if (!parseJsonObject(body, doc)) return;
  JsonObject root = doc.as<JsonObject>();

  size_t members = 0;
  for (JsonPair kv : root) {
    (void)kv;
    members++;
  }
  bool enabled = false;
  if (members != 1 || fieldBool(root, "enabled", enabled) != FIELD_OK) {
    sendError(400, "invalid_value");
    return;
  }
  if (!postOrFail(makeCommand(CmdType::SET_CHILD_LOCK, CmdSource::WEB, 0, enabled ? 1 : 0))) return;
  sendQueued();
}

// ============================================================================
// Yapilandirma
// ============================================================================
void WebPortal::handleApiConfigGet() {
  CfgView* v = takeCfgView();
  if (!v) {
    sendError(503, "busy");
    return;
  }
  const size_t cap = JSON_OBJECT_SIZE(12) + JSON_ARRAY_SIZE(MAX_TOTAL_RELAYS) +
                     (size_t)MAX_TOTAL_RELAYS * JSON_OBJECT_SIZE(4) + JSON_ARRAY_SIZE(MAX_TOTAL_DIS) +
                     (size_t)MAX_TOTAL_DIS * JSON_OBJECT_SIZE(4) + 256;
  DynamicJsonDocument doc(cap);
  if (doc.capacity() == 0) {
    free(v);
    sendError(503, "busy");
    return;
  }

  doc["device_name"] = (const char*)v->deviceName;
  doc["wifi_ssid"] = (const char*)v->wifiSsid;
  doc["wifi_sta_enabled"] = v->staEnabled;
  doc["rs485_baud"] = v->rs485Baud;
  doc["ext_module_enabled"] = v->extEnabled;
  doc["ext_module_channels"] = v->extChannels;
  doc["ext_module_address"] = v->extAddress;
  doc["total_relays"] = v->totalRelays;
  doc["total_dis"] = v->totalDIs;

  JsonArray rArr = doc.createNestedArray("relays");
  for (int i = 0; i < MAX_TOTAL_RELAYS; i++) {
    JsonObject r = rArr.createNestedObject();
    r["id"] = i + 1;
    r["name"] = (const char*)v->relayName[i];
    r["type"] = v->relayType[i];
    r["runtime_sec"] = v->relayRuntime[i];
  }
  JsonArray dArr = doc.createNestedArray("dis");
  for (int i = 0; i < MAX_TOTAL_DIS; i++) {
    JsonObject d = dArr.createNestedObject();
    d["id"] = i + 1;
    d["name"] = (const char*)v->diName[i];
    d["target_relay"] = v->diTarget[i];
    d["mode"] = v->diMode[i];
  }

  if (doc.overflowed()) {
    free(v);
    printf("[WEB] HATA: yapilandirma JSON havuzu tasti (kapasite %u).\r\n", (unsigned)cap);
    sendError(500, "internal");
    return;
  }
  const size_t len = measureJson(doc);
  String out;
  out.reserve(len + 1);
  serializeJson(doc, out);
  free(v);
  sendJson(200, out);
}

void WebPortal::handleApiConfigSave() {
  String body;
  if (!readJsonBody(body)) return;
  DynamicJsonDocument doc(jsonCapacityFor(body.length()));
  if (!parseJsonObject(body, doc)) return;
  JsonObject root = doc.as<JsonObject>();

  // Dogrulama gecici bir kopya uzerinde yapilir; basarisiz istek canli yapilandirmayi bozmaz.
  SystemConfig* tmp = (SystemConfig*)malloc(sizeof(SystemConfig));
  if (!tmp) {
    sendError(503, "busy");
    return;
  }
  {
    ConfigManager::ConfigLock lk(ConfigManager::instance());
    memcpy(tmp, &ConfigManager::instance().config, sizeof(SystemConfig));
  }
  const char* err = nullptr;
  if (!parseConfigInto(root, *tmp, err)) {
    free(tmp);
    sendError(err && strcmp(err, "too_large") == 0 ? 413 : 400, err ? err : "invalid_value");
    return;
  }

  // Canli yapilandirmaya yazma adimi loopTask'ta yapilir (SmartAutomation config'i kilitsiz okur; tek baglam kurali).
  // Orada panjur hareket halindeyse sure/tip/ek modul degisimi reddedilir (yalnizca ad degisikligi kabul).
  // tmp sahipligi isle birlikte loopTask'a gecer (orada free edilir).
  uint8_t jr = JR_FAILED;
  const JobStatus js = runLoopJob(JOB_CONFIG_APPLY, 0, 0, 0, 0, tmp, jr, nullptr);
  if (js == JS_BUSY || js == JS_NOT_STARTED) {   // is kabul edilmedi: tmp bizde
    free(tmp);
    sendError(503, "busy");
    return;
  }
  if (js == JS_STILL_RUNNING) {                  // loopTask isi aldi ama bitiremedi (tmp'yi o free eder)
    sendError(503, "busy");
    return;
  }
  if (jr == JR_BUSY_SHUTTER) {
    sendError(409, "busy");
    return;
  }
  if (jr != JR_OK) {
    sendError(500, "internal");
    return;
  }

  // Yavas NVS yazimi web gorevinde (ConfigManager::save kendi kilidini alir)
  if (!ConfigManager::instance().save()) {
    printf("[WEB] HATA: yapilandirma NVS'e yazilamadi.\r\n");
    sendError(500, "storage_error");
    return;
  }
  printf("[WEB] Yapilandirma kaydedildi.\r\n");
  sendOk();
}

// ============================================================================
// Wi-Fi
// ============================================================================
void WebPortal::storeScanResults(int n) {
  _cachedNetworks.clear();
  if (n <= 0) return;
  for (int i = 0; i < n; i++) {
    const String raw = WiFi.SSID(i);
    if (raw.length() == 0) continue;
    // SSID geçerli UTF-8'e zorlanir (bozuk bayt -> U+FFFD): JSON ayristiricilari bozuk UTF-8'i reddeder
    const String ssid = NetUtil::sanitizeUtf8(raw.c_str(), 32);
    const int32_t rssi = WiFi.RSSI(i);
    bool dup = false;
    for (size_t k = 0; k < _cachedNetworks.size(); k++) {
      if (_cachedNetworks[k].ssid == ssid) {
        if (rssi > _cachedNetworks[k].rssi) _cachedNetworks[k].rssi = rssi;   // ayni ad: en guclusu
        dup = true;
        break;
      }
    }
    if (dup) continue;
    ScannedAp ap;
    ap.ssid = ssid;
    ap.rssi = rssi;
    ap.enc = (WiFi.encryptionType(i) != WIFI_AUTH_OPEN);
    _cachedNetworks.push_back(ap);
  }
  std::sort(_cachedNetworks.begin(), _cachedNetworks.end(),
            [](const ScannedAp& a, const ScannedAp& b) { return a.rssi > b.rssi; });
  if (_cachedNetworks.size() > MAX_SCAN_RESULTS) _cachedNetworks.resize(MAX_SCAN_RESULTS);
}

// Tarama zamanlamasi (hiz siniri >= 10 sn, onbellek omru 120 sn, takilmis tarama 15 sn) NetUtil::ScanGate'tedir.
void WebPortal::handleApiWifiScan() {
  const uint32_t now = millis();
  const bool refresh = _server.hasArg("refresh");
  _scan.service(now);

  // Surmekte olan tarama
  if (_scan.inProgress) {
    const int16_t st = WiFi.scanComplete();
    const NetUtil::ScanGate::DriverState drv = (st >= 0) ? NetUtil::ScanGate::DRV_DONE
                                               : (st == WIFI_SCAN_FAILED ? NetUtil::ScanGate::DRV_FAILED
                                                                         : NetUtil::ScanGate::DRV_RUNNING);
    const NetUtil::ScanGate::Poll pr = _scan.poll(now, drv);
    if (pr == NetUtil::ScanGate::POLL_DONE) {
      storeScanResults(st);
      WiFi.scanDelete();
      _scan.cacheStored(now);
    } else if (pr == NetUtil::ScanGate::POLL_FAILED) {
      WiFi.scanDelete();   // takilmis/basarisiz tarama sonsuza dek "scanning" dondurmez
    } else {
      sendJson(200, "{\"status\":\"scanning\"}");
      return;
    }
  }

  // Onbellek bayatladiysa (veya refresh isteniyorsa) yeni tarama; en sik 10 sn'de bir
  bool cached = false;
  const NetUtil::ScanGate::Decision dec =
      _scan.decide(now, refresh, WiFiManager::instance().isConnecting(), !_cachedNetworks.empty(), cached);
  if (dec == NetUtil::ScanGate::DECIDE_START) {
    WiFi.scanDelete();
    WiFi.scanNetworks(true, false, false, 300);
    sendJson(200, "{\"status\":\"scanning\"}");
    return;
  }
  if (dec == NetUtil::ScanGate::DECIDE_SCANNING) {   // hiz siniri bitince tarama baslayacak
    sendJson(200, "{\"status\":\"scanning\"}");
    return;
  }

  DynamicJsonDocument doc(4096);
  doc["status"] = "done";
  doc["cached"] = cached;
  JsonArray arr = doc.createNestedArray("networks");
  for (size_t i = 0; i < _cachedNetworks.size(); i++) {
    JsonObject net = arr.createNestedObject();
    net["ssid"] = _cachedNetworks[i].ssid;
    net["rssi"] = _cachedNetworks[i].rssi;
    net["enc"] = _cachedNetworks[i].enc;
  }
  if (doc.overflowed()) {
    sendError(500, "internal");
    return;
  }
  String out;
  serializeJson(doc, out);
  sendJson(200, out);
}

void WebPortal::handleApiWifiConnect() {
  // AP kaynakli ANAHTARSIZ yol: global hiz siniri (herhangi bir 60 sn'de en cok 6 istek; Retry-After). Gecerli
  // X-Device-Key ile gelen istekler sinira girmez. Her istek sayilir (gecersiz govdeli de): kotuye kullanim siniri.
  if (_viaApOrigin) {
    uint32_t retrySec = 1;
    if (!g_apConnect.tryAcquire(millis(), retrySec)) {
      printf("[WEB] AP kaynakli anahtarsiz Wi-Fi baglanma istegi hiz siniri nedeniyle reddedildi (%u sn).\r\n", (unsigned)retrySec);
      _server.sendHeader("Retry-After", String(retrySec));
      String b = "{\"error\":\"rate_limited\",\"retry_after\":";
      b += String(retrySec);
      b += "}";
      sendJson(429, b);
      return;
    }
  }
  if (_viaApOrigin) printf("[WEB] Wi-Fi baglanma istegi: AP kaynakli (anahtarsiz) yol.\r\n");   // denetim izi (SSID/parola yazilmaz)
  String body;
  if (!readJsonBody(body)) return;
  DynamicJsonDocument doc(jsonCapacityFor(body.length()));
  if (!parseJsonObject(body, doc)) return;
  JsonObject root = doc.as<JsonObject>();

  const char* ssid = nullptr;
  if (fieldString(root, "ssid", ssid) != FIELD_OK) {
    sendError(400, "invalid_ssid");
    return;
  }
  const char* pass = "";
  if (root.containsKey("pass") && !root["pass"].isNull()) {
    if (fieldString(root, "pass", pass) != FIELD_OK) {
      sendError(400, "invalid_password");
      return;
    }
  }
  const size_t sl = strlen(ssid);
  const size_t pl = strlen(pass);
  if (sl < 1 || sl > 32) {
    sendError(400, "invalid_ssid");
    return;
  }
  if (pl != 0 && (pl < 8 || pl > 63)) {
    sendError(400, "invalid_password");
    return;
  }

  const WiFiManager::ConnectRequest r = WiFiManager::instance().requestConnect(ssid, pass);
  if (r == WiFiManager::ConnectRequest::INVALID_SSID) {
    sendError(400, "invalid_ssid");
  } else if (r == WiFiManager::ConnectRequest::INVALID_PASS) {
    sendError(400, "invalid_password");
  } else if (r == WiFiManager::ConnectRequest::BUSY) {
    sendError(409, "busy");
  } else {
    // Yanit simdi gider; WiFiManager ~0.5 sn sonra baglanir ve yalnizca dogrulaninca NVS'e kaydeder.
    sendJson(200, "{\"status\":\"connecting\"}");
  }
}

// GET /api/wifi/status -- Wi-Fi servis akisi icin DAR durum (AP_OR_KEYED): baglanti denemesinin sonucu ve STA/AP ozeti.
// Basari yalniz wifi_connect_state == "success" (POST /api/wifi/connect 200 "connecting" baglandi demek DEGILDIR).
void WebPortal::handleApiWifiStatus() {
  WiFiManager& wm = WiFiManager::instance();
  const bool connected = wm.isConnected();
  const WiFiManager::ConnectStatus cs = wm.getConnectStatus();
  const IPAddress staIp = wm.getLocalIP();
  char ipStr[16];
  snprintf(ipStr, sizeof(ipStr), "%u.%u.%u.%u", staIp[0], staIp[1], staIp[2], staIp[3]);
  const String ssidRaw = connected ? wm.getSSID() : String("");
  const String ssid = NetUtil::sanitizeUtf8(ssidRaw.c_str(), 32);

  DynamicJsonDocument doc(384);
  if (doc.capacity() == 0) {
    sendError(503, "busy");
    return;
  }
  doc["wifi_connect_state"] = connectStateName(cs.state);
  doc["wifi_connect_reason"] = cs.reason;
  doc["wifi_connected"] = connected;
  doc["wifi_sta_ssid"] = ssid;
  doc["wifi_sta_ip"] = connected ? (const char*)ipStr : "";
  doc["wifi_rssi"] = connected ? (int)WiFi.RSSI() : 0;
  doc["ap_active"] = wm.isRecoveryApActive();
  if (doc.overflowed()) {
    sendError(500, "internal");
    return;
  }
  String out;
  serializeJson(doc, out);
  sendJson(200, out);
}

void WebPortal::handleApiWifiDisconnect() {
  // WiFiManager kimligi (RAM) + NVS birlikte temizlenir: gorev eski kimlikle yeniden baglanmaz
  const bool ok = WiFiManager::instance().clearCredentials();
  if (!ok) {
    sendError(500, "storage_error");
    return;
  }
  sendOk();
}

// ============================================================================
// RS485 (yalnizca anahtarli)
// ============================================================================
void WebPortal::handleApiRs485Send() {
  String body;
  if (!readJsonBody(body)) return;
  DynamicJsonDocument doc(jsonCapacityFor(body.length()));
  if (!parseJsonObject(body, doc)) return;
  JsonObject root = doc.as<JsonObject>();

  const char* data = nullptr;
  if (fieldString(root, "data", data) != FIELD_OK || strlen(data) == 0 || strlen(data) > 256) {
    sendError(400, "invalid_value");
    return;
  }
  bool isHex = false;
  const FieldState hs = fieldBool(root, "isHex", isHex);
  if (hs == FIELD_BAD) {
    sendError(400, "invalid_value");
    return;
  }
  const bool ok = SmartAutomation::instance().rs485Send(String(data), isHex);
  if (!ok) {
    sendError(502, "send_failed");
    return;
  }
  sendOk();
}

void WebPortal::handleApiRs485Logs() {
  sendSecurityHeaders();
  _server.send(200, "text/plain; charset=utf-8", SmartAutomation::instance().rs485GetLogs());
}

void WebPortal::handleApiRs485Clear() {
  SmartAutomation::instance().rs485ClearLogs();
  sendOk();
}

void WebPortal::handleApiRs485Baud() {
  String body;
  if (!readJsonBody(body)) return;
  DynamicJsonDocument doc(jsonCapacityFor(body.length()));
  if (!parseJsonObject(body, doc)) return;
  JsonObject root = doc.as<JsonObject>();

  int baud = 0;
  if (fieldInt(root, "baud", baud) != FIELD_OK) {
    sendError(400, "invalid_baud");
    return;
  }
  if (baud != 9600 && baud != 19200 && baud != 38400 && baud != 115200) {   // beyaz liste
    sendError(400, "invalid_baud");
    return;
  }
  // cfg.rs485_baud'u SmartAutomation okur ve rs485Begin UART'i yeniden kurar: mutasyon loopTask'ta yapilir.
  uint8_t jr = JR_FAILED;
  const JobStatus js = runLoopJob(JOB_RS485_BAUD, 0, 0, 0, (uint32_t)baud, nullptr, jr, nullptr);
  if (js != JS_DONE || jr != JR_OK) {
    sendError(503, "busy");
    return;
  }
  if (!ConfigManager::instance().save()) {
    sendError(500, "storage_error");
    return;
  }
  sendOk();
}

// Tarama saniyeler surer: HTTP istegi ve ana dongu bloklanmaz. SmartAutomation taramayi ayri bir gorevde
// calistirir (POST -> rs485StartScan() + 202; GET -> rs485ScanState()/rs485ScanResult() ile yoklama).
void WebPortal::handleApiRs485ScanStart() {
  SmartAutomation& sa = SmartAutomation::instance();
  if (sa.rs485ScanState() == SmartAutomation::ScanState::RUNNING) {
    sendJson(202, "{\"status\":\"scanning\"}");
    return;
  }
  if (!sa.rs485StartScan()) {
    // FW-core: ek modul panjuru hareket halindeyken tarama baslatilmaz (hat tarama suresince tutulur); baska neden
    // (gorev olusturulamadi) cok nadirdir. Hata kodu ayni ("busy"); nedeni "message" duz metniyle bildirilir.
    sendJson(503, "{\"error\":\"busy\",\"message\":\"ek modul panjuru hareket ediyor; tarama baslatilamadi\"}");
    return;
  }
  sendJson(202, "{\"status\":\"scanning\"}");
}

void WebPortal::handleApiRs485ScanResult() {
  SmartAutomation& sa = SmartAutomation::instance();
  const SmartAutomation::ScanState st = sa.rs485ScanState();
  if (st == SmartAutomation::ScanState::IDLE) {
    sendJson(200, "{\"status\":\"idle\"}");
    return;
  }
  if (st == SmartAutomation::ScanState::RUNNING) {
    sendJson(202, "{\"status\":\"scanning\"}");
    return;
  }
  const SmartAutomation::Rs485ScanResult res = sa.rs485ScanResult();
  DynamicJsonDocument doc(768);
  doc["status"] = "done";
  doc["found"] = res.found;
  doc["slaveId"] = res.slaveId;
  doc["baud"] = res.baud;
  doc["relayStatus"] = res.relayStatus;
  doc["rawHex"] = NetUtil::sanitizeUtf8(res.rawHex.c_str(), 200);
  doc["info"] = NetUtil::sanitizeUtf8(res.info.c_str(), 200);
  String out;
  serializeJson(doc, out);
  sendJson(200, out);
}

void WebPortal::handleApiRs485Relay() {
  String body;
  if (!readJsonBody(body)) return;
  DynamicJsonDocument doc(jsonCapacityFor(body.length()));
  if (!parseJsonObject(body, doc)) return;
  JsonObject root = doc.as<JsonObject>();

  int sid = 1, ch = 1, action = 2;   // action: 1 ACIK, 0 KAPALI, 2 DEGISTIR
  FieldState fs = fieldInt(root, "slaveId", sid);
  if (fs == FIELD_BAD || (fs == FIELD_OK && (sid < 1 || sid > 247))) { sendError(400, "invalid_value"); return; }
  fs = fieldInt(root, "channel", ch);
  if (fs == FIELD_BAD || (fs == FIELD_OK && (ch < 0 || ch > 32))) { sendError(400, "invalid_channel"); return; }
  fs = fieldInt(root, "action", action);
  if (fs == FIELD_BAD || (fs == FIELD_OK && (action < 0 || action > 2))) { sendError(400, "invalid_value"); return; }

  // Toplu ACMA (channel=0) ve panjur kanallari ham komutla surulmez (interlock atlanmasin)
  if (ch == 0 && action != 0) {
    sendError(400, "invalid_channel");
    return;
  }
  if (ch > 0) {
    ConfigManager::ConfigLock lk(ConfigManager::instance());
    const SystemConfig& c = ConfigManager::instance().config;
    const int relayIdx = 8 + (ch - 1);   // harici modul kanali -> birlesik role indeksi
    if (c.ext_module_enabled && sid == c.ext_module_address && relayIdx < MAX_TOTAL_RELAYS) {
      const uint8_t t = c.relays[relayIdx].type;
      if (t == RELAY_TYPE_SHUTTER_UP || t == RELAY_TYPE_SHUTTER_DOWN) {
        sendError(400, "shutter_channel");
        return;
      }
    }
  }

  // rs485ControlExtRelay yalniz loopTask'tan cagrilabilir: istek loopTask'a postalanir (WebPortal::loop)
  uint8_t jr = JR_FAILED;
  String resp;
  if (runLoopJob(JOB_RS485_RELAY, (uint8_t)sid, (uint8_t)ch, (uint8_t)action, 0, nullptr, jr, &resp) != JS_DONE) {
    sendError(503, "busy");
    return;
  }
  const bool ok = (jr == JR_OK);
  DynamicJsonDocument out(384);
  out["success"] = ok;
  out["responseHex"] = NetUtil::sanitizeUtf8(resp.c_str(), 160);
  if (!ok) out["error"] = "no_response";
  String o;
  serializeJson(out, o);
  sendJson(ok ? 200 : 502, o);
}

// ============================================================================
// Sistem
// ============================================================================
void WebPortal::handleApiReboot() {
  // Yanit once gider; panjurlar durdurulur, MQTT "offline" yayinlanir ve ESP.restart() sonraki turlarda yapilir
  sendJson(200, "{\"status\":\"rebooting\"}");
  SmartAutomation::instance().requestRestart(RESTART_DELAY_MS);
}

void WebPortal::handleApiReset() {
  // Uygulama ayarlari + Wi-Fi sifirlanir; yerel anahtar, AP parolasi ve bulut kimligi KORUNUR
  // (uzaktan "sifirla" cihazi sahipsiz birakmaz; fiziksel RESETKEY ayrica vardir).
  // Yapilandirma silinmeden once hareket eden panjurlar durdurulur (kuyruk doluysa FW-core acil durdurma bayragini
  // kurar); loopTask'in komutu bosaltmasi icin kisa bir sure taninir.
  postDeviceCommand(makeCommand(CmdType::ALL_SHUTTERS_STOP, CmdSource::WEB));
  vTaskDelay(pdMS_TO_TICKS(40));

  // resetToDefaults tum yapilandirmayi yeniden yazar: loopTask'ta calisir (SmartAutomation config'i kilitsiz okur).
  uint8_t jr = JR_FAILED;
  if (runLoopJob(JOB_FACTORY_RESET, 0, 0, 0, 0, nullptr, jr, nullptr) != JS_DONE) {
    sendError(503, "busy");
    return;
  }
  if (jr != JR_OK) {
    sendError(500, "storage_error");
    return;
  }
  g_wifiRestorePending = true;   // surucu Wi-Fi ayarlari yeniden baslatmadan hemen once silinir
  sendJson(200, "{\"status\":\"reset_ok\"}");
  SmartAutomation::instance().requestRestart(RESTART_DELAY_MS + 200);
}

// ============================================================================
// Kimlik / provizyon
// ============================================================================
void WebPortal::handleApiAuthCheck() {
  sendOk();   // buraya yalnizca anahtar dogrulanmis istekler gelir
}

// Provizyonsuz cihazin ilk kurulumu (fabrika araci / servis). local_key bosken calisir.
// Bastaki denetim yalniz HIZLI RET'tir (govde okunmadan). KESIN denetim, yazmayla AYNI kilit altinda
// ConfigManager::provisionIfEmpty icindedir (seri FACTORYINIT de ayni yontemi kullanir): govde ayristirilirken loopTask
// seri FACTORYINIT ile anahtari yazarsa bu istek 403 already_provisioned alir, yeni anahtar EZILMEZ (TOCTOU yok).
void WebPortal::handleApiFactoryInit() {
  ConfigManager& cm = ConfigManager::instance();
  if (cm.hasLocalKey()) {
    sendError(403, "already_provisioned");
    return;
  }
  String body;
  if (!readJsonBody(body)) return;
  DynamicJsonDocument doc(jsonCapacityFor(body.length()));
  if (!parseJsonObject(body, doc)) return;
  JsonObject root = doc.as<JsonObject>();

  const char* key = nullptr;
  const char* ap = nullptr;
  if (fieldString(root, "local_key", key) != FIELD_OK) { sendError(400, "invalid_key"); return; }
  if (fieldString(root, "ap_pass", ap) != FIELD_OK) { sendError(400, "invalid_ap_pass"); return; }
  const size_t kl = strlen(key);
  const size_t al = strlen(ap);
  if (kl < LOCAL_KEY_MIN_LEN || kl > LOCAL_KEY_MAX_LEN || !NetUtil::isPrintableAsciiNoSpace(key, kl)) {
    sendError(400, "invalid_key");
    return;
  }
  if (al < AP_PASS_MIN_LEN || al > AP_PASS_MAX_LEN) {
    sendError(400, "invalid_ap_pass");
    return;
  }

  // Bicim hatalari 400 (ap_pass karakter araligi 0x20..0x7E provisionIfEmpty'de denetlenir); bicim gecip NVS'e
  // yazilamazsa 503 storage (CONTRACTS §3b): cihaz provizyonsuz kalir, yarim provizyon kalmaz (provisionIfEmpty geri alir).
  switch (cm.provisionIfEmpty(key, ap)) {
    case ConfigManager::PROVISION_OK:
      break;
    case ConfigManager::PROVISION_ALREADY:
      sendError(403, "already_provisioned");
      return;
    case ConfigManager::PROVISION_INVALID_KEY:
      sendError(400, "invalid_key");
      return;
    case ConfigManager::PROVISION_INVALID_AP_PASS:
      sendError(400, "invalid_ap_pass");
      return;
    default:
      sendError(503, "storage");
      return;
  }
  printf("[WEB] Cihaz provizyonlandi (yerel anahtar ve AP parolasi yazildi).\r\n");
  WiFiManager::instance().applyApConfigChange();   // acik kurulum AP'si WPA2 + ap_pass ile yeniden baslar
  sendOk();
}

// Yerel anahtari mevcut anahtarla degistirir
void WebPortal::handleApiRekey() {
  String body;
  if (!readJsonBody(body)) return;
  DynamicJsonDocument doc(jsonCapacityFor(body.length()));
  if (!parseJsonObject(body, doc)) return;
  JsonObject root = doc.as<JsonObject>();

  const char* key = nullptr;
  FieldState fs = fieldString(root, "local_key", key);
  if (fs == FIELD_MISSING) fs = fieldString(root, "new_key", key);
  if (fs != FIELD_OK) { sendError(400, "invalid_key"); return; }
  const size_t kl = strlen(key);
  if (kl < LOCAL_KEY_MIN_LEN || kl > LOCAL_KEY_MAX_LEN || !NetUtil::isPrintableAsciiNoSpace(key, kl)) {
    sendError(400, "invalid_key");
    return;
  }
  // Bicim yukarida dogrulandi (SystemConfig::setLocalKey ile ayni kural): false yalniz NVS kalicilastirma hatasidir ->
  // 503 storage (CONTRACTS §3b). RAM geri alinir: eski anahtar gecerli kalir.
  if (!ConfigManager::instance().setLocalKey(key)) {
    sendError(503, "storage");
    return;
  }
  printf("[WEB] Yerel anahtar degistirildi.\r\n");
  sendOk();
}

// Bulut (MQTT) kimligi: sunucu, kullanici ve parola cihaza yazilir; MQTT yeni kimlikle yeniden baglanir
void WebPortal::handleApiMqttConfig() {
  String body;
  if (!readJsonBody(body)) return;
  DynamicJsonDocument doc(jsonCapacityFor(body.length()));
  if (!parseJsonObject(body, doc)) return;
  JsonObject root = doc.as<JsonObject>();

  const char* server = nullptr;
  const char* user = nullptr;
  const char* pass = nullptr;
  int port = 0;
  if (fieldString(root, "server", server) != FIELD_OK || !validMqttHost(server)) { sendError(400, "invalid_value"); return; }
  if (fieldInt(root, "port", port) != FIELD_OK || port < 1 || port > 65535) { sendError(400, "invalid_value"); return; }
  if (fieldString(root, "user", user) != FIELD_OK || strlen(user) < 1) { sendError(400, "invalid_value"); return; }
  if (fieldString(root, "pass", pass) != FIELD_OK || strlen(pass) < 1) { sendError(400, "invalid_value"); return; }

  // Alan uzunluklari ConfigManager'da doğrulanir (kullanici <= 47, parola <= 63); kirpma yok, reddedilir
  if (!ConfigManager::instance().setMqttCredentials(server, (uint16_t)port, user, pass)) {
    sendError(400, "invalid_value");
    return;
  }
  printf("[WEB] MQTT kimligi guncellendi (sunucu: %s:%d); bulut baglantisi yenileniyor.\r\n", server, port);
  MqttManager::instance().reconfigure();
  sendOk();
}
