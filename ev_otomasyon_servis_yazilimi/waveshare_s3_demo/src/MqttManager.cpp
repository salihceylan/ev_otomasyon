#include "MqttManager.h"
#include "ConfigManager.h"
#include "SmartAutomation.h"
#include "DeviceCommand.h"
#include "WiFiManager.h"
#include "NetUtil.h"
#include "CaCerts.h"
#include <esp_timer.h>
#include <esp_system.h>
#include <mbedtls/x509_crt.h>
#include <mbedtls/x509.h>
#include <string.h>
#include <stdlib.h>

namespace {

// ---- Zamanlama / boyut sabitleri -------------------------------------------------------------
// ZAMAN KURALI (N6, CONTRACTS 3c): bu dosyada saklanmis "hedef zaman" + isaretli karsilastirma YOKTUR. Zamanlayicilar
// NetTime.h'deki "son olay + bekleme" ciftleridir (NetUtil::Wait/ReconnectBackoff/PublishPacer), yalniz MQTT gorevinde
// degistirilir ve gorev dongusunun HER turunda yoklanir (sure dolunca sonlanir). Baska gorevler yalniz bayrak kurar.
// "now" her zaman zaman damgasi alindiktan SONRA okunur (millis() cagrisi kullanim yerinde).
const uint32_t TASK_TICK_MS = 50;
const uint32_t IGNORE_WINDOW_MS = 1500;       // abonelikten sonra gelen mesajlari yok say
const uint32_t NO_TIME_RETRY_MS = 2000;       // saat senkronu bekleniyor
const uint32_t NO_TIME_LOG_MS = 30000;
const size_t MAX_CMD_PAYLOAD = 512;
const uint32_t MQTT_TASK_STACK = 12288;       // TLS el sikismasi + JSON icin (once 8192)
const uint16_t MQTT_BASE_BUFFER = 1024;
const size_t MAX_STATE_BYTES = 30000;
const uint32_t WATERMARK_LOG_MS = 300000;

// Bayrak bitleri (komut dogrulama)
const uint8_t F_RELAY = 1;
const uint8_t F_SHUTTER = 2;
const uint8_t F_CMD = 4;
const uint8_t F_STATE = 8;
const uint8_t F_POS = 16;
const uint8_t F_ENABLED = 32;
const uint8_t F_SEC = 64;
const uint8_t F_ID = 128;

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

const char* relayTypeName(uint8_t type) {
  switch (type) {
    case RELAY_TYPE_SHUTTER_UP: return "shutter_up";
    case RELAY_TYPE_SHUTTER_DOWN: return "shutter_down";
    case RELAY_TYPE_IMPULSE: return "impulse";
    default: return "light";
  }
}

// Komut kimligi: 1..24 karakter, [A-Za-z0-9._:-]
bool validCommandId(const char* id) {
  if (!id) return false;
  const size_t n = strlen(id);
  if (n < 1 || n > 24) return false;
  for (size_t i = 0; i < n; i++) {
    const char c = id[i];
    const bool ok = (c >= '0' && c <= '9') || (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || c == '.' ||
                    c == '_' || c == ':' || c == '-';
    if (!ok) return false;
  }
  return true;
}

// Konu kimligi: 1..40 karakter, [A-Za-z0-9_-]
bool validTopicId(const char* t) {
  if (!t) return false;
  const size_t n = strlen(t);
  if (n < 1 || n > 40) return false;
  for (size_t i = 0; i < n; i++) {
    const char c = t[i];
    const bool ok = (c >= '0' && c <= '9') || (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || c == '_' || c == '-';
    if (!ok) return false;
  }
  return true;
}

// CONTRACTS Bolum 2.3: komut yuku dogrulamasi. Basariliysa nullptr, degilse reddetme nedeni.
// Bilinmeyen alan/komut, tip uyusmazligi, aralik disi deger => komut UYGULANMAZ (sessiz varsayilan yok).
const char* parseCommand(JsonObject obj, uint8_t totalRelays, DeviceCommand& out) {
  uint8_t flags = 0;
  for (JsonPair kv : obj) {
    const char* k = kv.key().c_str();
    if (!strcmp(k, "relay")) flags |= F_RELAY;
    else if (!strcmp(k, "shutter")) flags |= F_SHUTTER;
    else if (!strcmp(k, "cmd")) flags |= F_CMD;
    else if (!strcmp(k, "state")) flags |= F_STATE;
    else if (!strcmp(k, "pos")) flags |= F_POS;
    else if (!strcmp(k, "enabled")) flags |= F_ENABLED;
    else if (!strcmp(k, "sec")) flags |= F_SEC;
    else if (!strcmp(k, "id")) flags |= F_ID;
    else return "bilinmeyen alan";
  }

  const uint8_t totalPairs = totalRelays / 2;
  const uint8_t body = flags & (uint8_t)~F_ID;   // id yalnizca isteğe bagli eslik eder

  // Tip dogrulamalari: mevcut her alan beklenen JSON tipinde olmali
  if ((flags & F_RELAY) && !obj["relay"].is<int>()) return "relay tamsayi olmali";
  if ((flags & F_SHUTTER) && !obj["shutter"].is<int>()) return "shutter tamsayi olmali";
  if ((flags & F_POS) && !obj["pos"].is<int>()) return "pos tamsayi olmali";
  if ((flags & F_SEC) && !obj["sec"].is<int>()) return "sec tamsayi olmali";
  if ((flags & F_STATE) && !obj["state"].is<bool>()) return "state boolean olmali";
  if ((flags & F_ENABLED) && !obj["enabled"].is<bool>()) return "enabled boolean olmali";
  if ((flags & F_CMD) && !obj["cmd"].is<const char*>()) return "cmd metin olmali";

  int relay = 0, shutter = 0, pos = 0, sec = 0;
  if (flags & F_RELAY) relay = obj["relay"].as<int>();
  if (flags & F_SHUTTER) shutter = obj["shutter"].as<int>();
  if (flags & F_POS) pos = obj["pos"].as<int>();
  if (flags & F_SEC) sec = obj["sec"].as<int>();

  out = makeCommand(CmdType::ALL_LIGHTS_OFF, CmdSource::MQTT);

  if (flags & F_CMD) {
    const char* c = obj["cmd"].as<const char*>();
    if (c == nullptr) return "cmd metin olmali";

    if (!strcmp(c, "toggle")) {
      if (body != (F_CMD | F_RELAY)) return "toggle yalnizca relay ile";
      if (relay < 1 || relay > totalRelays) return "relay araligi";
      out = makeCommand(CmdType::RELAY_TOGGLE, CmdSource::MQTT, (uint8_t)relay, 0);
    } else if (!strcmp(c, "up") || !strcmp(c, "down") || !strcmp(c, "stop") || !strcmp(c, "step")) {
      if (body != (F_CMD | F_SHUTTER)) return "panjur komutu yalnizca shutter ile";
      if (shutter < 1 || shutter > totalPairs) return "shutter araligi";
      CmdType t = CmdType::SHUTTER_STOP;
      if (!strcmp(c, "up")) t = CmdType::SHUTTER_UP;
      else if (!strcmp(c, "down")) t = CmdType::SHUTTER_DOWN;
      else if (!strcmp(c, "step")) t = CmdType::SHUTTER_STEP;
      out = makeCommand(t, CmdSource::MQTT, (uint8_t)shutter, 0);
    } else if (!strcmp(c, "all_lights_off") || !strcmp(c, "all_off")) {
      if (body != F_CMD) return "toplu komut baska alan almaz";
      out = makeCommand(CmdType::ALL_LIGHTS_OFF, CmdSource::MQTT);
    } else if (!strcmp(c, "all_shutters_up")) {
      if (body != F_CMD) return "toplu komut baska alan almaz";
      out = makeCommand(CmdType::ALL_SHUTTERS_UP, CmdSource::MQTT);
    } else if (!strcmp(c, "all_shutters_down")) {
      if (body != F_CMD) return "toplu komut baska alan almaz";
      out = makeCommand(CmdType::ALL_SHUTTERS_DOWN, CmdSource::MQTT);
    } else if (!strcmp(c, "all_shutters_stop")) {
      if (body != F_CMD) return "toplu komut baska alan almaz";
      out = makeCommand(CmdType::ALL_SHUTTERS_STOP, CmdSource::MQTT);
    } else if (!strcmp(c, "set_child_lock")) {
      // Eksik/bozuk "enabled" ASLA "false" sayilmaz (fail-open yok)
      if (body != (F_CMD | F_ENABLED)) return "set_child_lock enabled(boolean) ister";
      out = makeCommand(CmdType::SET_CHILD_LOCK, CmdSource::MQTT, 0, obj["enabled"].as<bool>() ? 1 : 0);
    } else if (!strcmp(c, "set_runtime")) {
      if (body != (F_CMD | F_SHUTTER | F_SEC)) return "set_runtime shutter ve sec ister";
      if (shutter < 1 || shutter > totalPairs) return "shutter araligi";
      if (sec < SHUTTER_RUNTIME_MIN_SEC || sec > SHUTTER_RUNTIME_MAX_SEC) return "sec araligi (1..300)";
      out = makeCommand(CmdType::SET_RUNTIME, CmdSource::MQTT, (uint8_t)shutter, sec);
    } else {
      return "bilinmeyen komut";
    }
  } else if (body == (F_RELAY | F_STATE)) {
    if (relay < 1 || relay > totalRelays) return "relay araligi";
    out = makeCommand(CmdType::RELAY_SET, CmdSource::MQTT, (uint8_t)relay, obj["state"].as<bool>() ? 1 : 0);
  } else if (body == (F_SHUTTER | F_POS)) {
    // pos once aralik denetiminden gecer; uint8_t'e kesme (256 -> 0) yoktur
    if (shutter < 1 || shutter > totalPairs) return "shutter araligi";
    if (pos < 0 || pos > 100) return "pos araligi (0..100)";
    out = makeCommand(CmdType::SHUTTER_POS, CmdSource::MQTT, (uint8_t)shutter, pos);
  } else {
    return "gecersiz komut bicimi";
  }

  if (flags & F_ID) {
    if (!obj["id"].is<const char*>()) return "id metin olmali";
    const char* id = obj["id"].as<const char*>();
    if (!validCommandId(id)) return "id gecersiz (1..24, [A-Za-z0-9._:-])";
    strncpy(out.id, id, sizeof(out.id) - 1);
    out.id[sizeof(out.id) - 1] = '\0';
  }
  return nullptr;
}

}  // namespace

// ============================================================================
// Yasam dongusu
// ============================================================================
MqttManager& MqttManager::instance() {
  static MqttManager inst;
  return inst;
}

MqttManager::MqttManager()
    : _taskHandle(nullptr),
      _mutex(nullptr),
      _connected(false),
      _needPublish(false),
      _reconfigPending(false),
      _shutdownRequested(false),
      _shutdownDone(false),
      _halted(false),
      _pace(),
      _reconnect(),
      _ignore(),
      _noTimeLog(),
      _watermark(),
      _sigCheck(),
      _seq(0),
      _noCredLogged(false),
      _haveCreds(false),
      _enabled(true),
      _port(8884),
      _publishedSigValid(false),
      _recentHead(0) {
  _server[0] = _user[0] = _pass[0] = _topicId[0] = '\0';
  _topicStatus[0] = _topicState[0] = _topicCmd[0] = _topicSys[0] = '\0';
  _clientId[0] = _uid[0] = '\0';
  memset(_recentIds, 0, sizeof(_recentIds));
  memset(&_publishedSig, 0, sizeof(_publishedSig));
}

void MqttManager::begin() {
  if (_taskHandle != nullptr) return;
  if (_mutex == nullptr) _mutex = xSemaphoreCreateMutex();

  const String uid = WiFiManager::instance().getDeviceUid();
  strncpy(_uid, uid.c_str(), sizeof(_uid) - 1);
  _uid[sizeof(_uid) - 1] = '\0';

  applyConfig();

  // TLS: sunucu sertifikasi ISRG koklerine karsi DOGRULANIR (setInsecure() kullanilmaz).
  _secureClient.setCACert(LETS_ENCRYPT_ROOT_CA_PEM);
  _secureClient.setHandshakeTimeout(12);   // saniye (arduino-esp32 saniye cinsinden bekler)
  _secureClient.setTimeout(8);             // saniye

  _mqttClient.setClient(_secureClient);
  _mqttClient.setBufferSize(MQTT_BASE_BUFFER);   // durum yayini icin gerektiginde buyutulur
  _mqttClient.setKeepAlive(30);
  // saniye. PubSubClient CONNACK/paket beklemesini CPU'yu birakmadan (busy-wait) yapar; Core 0'da IDLE0 TWDT'ye
  // abone (10 sn, panic) oldugundan en kotu bekleme bu degerle sinirlidir: 5 sn < 10 sn.
  _mqttClient.setSocketTimeout(5);
  _mqttClient.setCallback([](char* topic, byte* payload, unsigned int length) {
    MqttManager::instance().onMessage(topic, payload, length);
  });

  if (!SmartAutomation::registerPreRestartHook(&MqttManager::preRestartHook)) {
    printf("[MQTTS] UYARI: yeniden baslatma kancasi kaydedilemedi (offline durumu LWT'ye kalir).\r\n");
  }

  // MQTTS gorevini Core 0'a sabitle (Role/Panjur motorunu asla bloklamaz)
  xTaskCreatePinnedToCore(mqttTask, "MqttTask", MQTT_TASK_STACK, this, 1, &_taskHandle, 0);

  printf("[MQTTS] Guvenli MQTT yoneticisi baslatildi (Core 0, yigin %u bayt, kimlik: %s).\r\n",
         (unsigned)MQTT_TASK_STACK, _haveCreds ? "VAR" : "YOK (yalnizca yerel calisma)");
}

void MqttManager::mqttTask(void* parameter) {
  static_cast<MqttManager*>(parameter)->taskLoop();
}

void MqttManager::preRestartHook() {
  MqttManager::instance().prepareForRestart();
}

// ============================================================================
// Yapilandirma
// ============================================================================
void MqttManager::applyConfig() {
  char server[sizeof(_server)];
  char user[sizeof(_user)];
  char pass[sizeof(_pass)];
  uint16_t port;
  bool enabled, have;
  {
    ConfigManager::ConfigLock lk(ConfigManager::instance());
    const SystemConfig& cfg = ConfigManager::instance().config;
    enabled = cfg.mqtt_enabled;
    port = cfg.mqtt_port;
    have = cfg.hasMqttCredentials();
    memcpy(server, cfg.mqtt_server, sizeof(server));
    memcpy(user, cfg.mqtt_user, sizeof(user));
    memcpy(pass, cfg.mqtt_pass, sizeof(pass));
  }
  server[sizeof(server) - 1] = '\0';
  user[sizeof(user) - 1] = '\0';
  pass[sizeof(pass) - 1] = '\0';

  // Konu kimligi: cihaz kullanici adi "d_{t}" -> t ; eski paylasimli kimlik ("home_*") oldugu gibi
  const char* tid = user;
  if (strncmp(user, "d_", 2) == 0) tid = user + 2;
  if (have && !validTopicId(tid)) {
    printf("[MQTTS] HATA: kullanici adindan gecerli konu kimligi cikarilamadi; MQTT baslatilmayacak.\r\n");
    have = false;
  }

  uint8_t mac[6];
  esp_read_mac(mac, ESP_MAC_WIFI_STA);

  {
    MutexGuard g(_mutex, 200);
    memcpy(_server, server, sizeof(_server));
    _port = port;
    memcpy(_user, user, sizeof(_user));
    memcpy(_pass, pass, sizeof(_pass));
    strncpy(_topicId, tid, sizeof(_topicId) - 1);
    _topicId[sizeof(_topicId) - 1] = '\0';
    if (have) {
      snprintf(_topicStatus, sizeof(_topicStatus), "ev/%s/status", _topicId);
      snprintf(_topicState, sizeof(_topicState), "ev/%s/state", _topicId);
      snprintf(_topicCmd, sizeof(_topicCmd), "ev/%s/cmd", _topicId);
      snprintf(_topicSys, sizeof(_topicSys), "ev/%s/sys", _topicId);
    } else {
      _topicStatus[0] = _topicState[0] = _topicCmd[0] = _topicSys[0] = '\0';
    }
    snprintf(_clientId, sizeof(_clientId), "ESP32S3_%02X%02X%02X%02X%02X%02X", mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);
    _haveCreds = have;
    _enabled = enabled;
  }
  memset(pass, 0, sizeof(pass));

  _mqttClient.setServer(_server, _port);   // alan sinif uyesidir: PubSubClient isaretciyi saklar, gecerli kalir
}

void MqttManager::reconfigure() {
  _reconfigPending = true;
}

bool MqttManager::isConfigured() {
  MutexGuard g(_mutex, 50);
  return g.ok() && _haveCreds && _enabled;
}

// ============================================================================
// Disaridan okunan basit alanlar
// ============================================================================
bool MqttManager::isConnected() {
  MutexGuard g(_mutex, 10);
  if (g.ok()) return _connected;
  return _connected;
}

// Her gorevden cagrilabilir: yalniz bayrak kurar (zaman damgasi tasimaz). Birlestirme penceresini MQTT gorevi, bayragi
// ilk GOZLEDIGI turda baslatir (en fazla bir tick = 50 ms gecikme).
void MqttManager::triggerPublish() {
  _needPublish = true;
}

String MqttManager::getServer() {
  MutexGuard g(_mutex, 50);
  return String(_server);
}

uint16_t MqttManager::getPort() {
  return _port;
}

String MqttManager::getUsername() {
  MutexGuard g(_mutex, 50);
  return String(_user);
}

String MqttManager::getStatusTopic() {
  MutexGuard g(_mutex, 50);
  return String(_topicStatus);
}

String MqttManager::getStateTopic() {
  MutexGuard g(_mutex, 50);
  return String(_topicState);
}

String MqttManager::getCmdTopic() {
  MutexGuard g(_mutex, 50);
  return String(_topicCmd);
}

// ============================================================================
// Gorev dongusu
// ============================================================================
void MqttManager::scheduleRetry(bool longWait) {
  _reconnect.schedule(millis(), longWait, esp_random());
}

void MqttManager::dropConnection(const char* why, bool sendDisconnect) {
  if (sendDisconnect && _mqttClient.connected()) {
    _mqttClient.disconnect();
  }
  _secureClient.stop();
  bool was;
  {
    MutexGuard g(_mutex, 50);
    was = _connected;
    _connected = false;
  }
  if (was) printf("[MQTTS] Baglanti kapatildi: %s\r\n", why);
}

void MqttManager::taskLoop() {
  for (;;) {
    // Zamanlayicilar HER turda (kimlik/Wi-Fi/baglanti durumu ne olursa olsun) yoklanir: sure dolunca sonlanir.
    // Boylece haftalarca suren Wi-Fi/MQTT sessizliginde bayat bir zamanlayici kalmaz (N6).
    {
      const uint32_t t = millis();
      _reconnect.service(t);
      _pace.service(t);
      _ignore.service(t);
      _noTimeLog.service(t);
      _sigCheck.service(t);
      // Yigin izleme (TLS el sikismasi yigin tuketir): arada ve sorun varsa logla
      if (_watermark.elapsed(t)) {
        const UBaseType_t freeStack = uxTaskGetStackHighWaterMark(nullptr);
        printf("[MQTTS] Yigin: en az %u bayt bos kaldi (toplam %u), bos heap: %u\r\n", (unsigned)freeStack,
               (unsigned)MQTT_TASK_STACK, (unsigned)ESP.getFreeHeap());
        if (freeStack < 2048) printf("[MQTTS] UYARI: MQTT gorev yigini kritik seviyede!\r\n");
        _watermark.arm(t, WATERMARK_LOG_MS);
      }
    }

    // Planli yeniden baslatma: "offline" yayinla, baglantiyi temiz kapat, bir daha baglanma
    if (_shutdownRequested) {
      if (_connected && _mqttClient.connected()) {
        publishStatus("offline");
      }
      dropConnection("planli yeniden baslatma", true);
      _halted = true;
      _shutdownRequested = false;
      _shutdownDone = true;
    }
    if (_halted) {
      vTaskDelay(pdMS_TO_TICKS(100));
      continue;
    }

    if (_reconfigPending) {
      _reconfigPending = false;
      dropConnection("yapilandirma degisti", true);
      applyConfig();
      _reconnect.reset();
      _noCredLogged = false;
      printf("[MQTTS] Yapilandirma yenilendi (kimlik: %s).\r\n", _haveCreds ? "VAR" : "YOK");
    }

    if (!_haveCreds || !_enabled) {
      if (!_noCredLogged) {
        printf("[MQTTS] MQTT kimligi yok veya devre disi: bulut baglantisi baslatilmadi, cihaz yerelde calisir.\r\n");
        _noCredLogged = true;
      }
      if (_connected) dropConnection("MQTT devre disi", true);
      vTaskDelay(pdMS_TO_TICKS(200));
      continue;
    }

    const bool wifiOk = WiFiManager::instance().isConnected();
    if (!wifiOk) {
      // Wi-Fi koptu: yarim kalmis TLS soketi kapatilir (eski baglanti "bagli" gorunmesin)
      if (_connected || _secureClient.connected()) {
        dropConnection("Wi-Fi koptu", false);
        scheduleRetry(false);
      }
      vTaskDelay(pdMS_TO_TICKS(TASK_TICK_MS));
      continue;
    }

    if (!_mqttClient.connected()) {
      if (_connected) {
        dropConnection("broker baglantisi koptu", false);
        printf("[MQTTS] Broker baglantisi koptu! (durum kodu: %d)\r\n", _mqttClient.state());
        scheduleRetry(false);
      }
      if (_reconnect.due(millis())) {
        tryConnect();
      }
    } else {
      // Gelen mesajlari onMessage'a verir; PubSubClient::loop() cagri basina tek paket isler, bu yuzden
      // ard arda gelen komut yiginlari 50 ms'lik turlara yayilmasin diye bekleyen veri bitene kadar
      // (en fazla 8 paket) dongu yapilir.
      for (uint8_t i = 0; i < 8; i++) {
        _mqttClient.loop();
        if (!_mqttClient.connected() || _secureClient.available() <= 0) break;
      }
      if (_mqttClient.connected()) {
        watchStateChanges(millis());
        publishIfDue(millis());
      }
    }

    vTaskDelay(pdMS_TO_TICKS(TASK_TICK_MS));
  }
}

// ============================================================================
// Baglanti
// ============================================================================
bool MqttManager::leafCertificateValid() {
  // arduino-esp32 cekirdegi CONFIG_MBEDTLS_HAVE_TIME_DATE kapali derlenmistir: mbedTLS sertifikanin
  // gecerlilik tarihlerini kendisi denetlemez. Zincir ve ana makine adi dogrulanmistir; tarih burada.
  const mbedtls_x509_crt* crt = _secureClient.getPeerCertificate();
  if (crt == nullptr) {
    printf("[MQTTS] UYARI: sunucu sertifikasi gecerlilik tarihi denetlenemedi (sertifika bilgisi yok).\r\n");
    return true;
  }
  const int64_t nowT = (int64_t)time(nullptr);
  const int64_t from = NetUtil::epochFromUtc(crt->valid_from.year, crt->valid_from.mon, crt->valid_from.day,
                                             crt->valid_from.hour, crt->valid_from.min, crt->valid_from.sec);
  const int64_t to = NetUtil::epochFromUtc(crt->valid_to.year, crt->valid_to.mon, crt->valid_to.day,
                                           crt->valid_to.hour, crt->valid_to.min, crt->valid_to.sec);
  const int64_t skew = 86400;   // 1 gun saat sapmasi payi
  if (nowT + skew < from) {
    printf("[MQTTS] Sunucu sertifikasi henuz gecerli degil (cihaz saati/sertifika uyumsuz).\r\n");
    return false;
  }
  if (nowT - skew > to) {
    printf("[MQTTS] Sunucu sertifikasinin suresi dolmus; kimlik bilgisi GONDERILMEDI.\r\n");
    return false;
  }
  return true;
}

bool MqttManager::tryConnect() {
  // Saat senkronu yoksa TLS denenmez (sertifika tarihi denetimi anlamsiz olur)
  if (!NetUtil::isTimeSynced()) {
    const uint32_t t = millis();
    if (_noTimeLog.elapsed(t)) {
      printf("[MQTTS] Saat senkronu yok; TLS baglantisi ertelendi (SNTP bekleniyor).\r\n");
      _noTimeLog.arm(t, NO_TIME_LOG_MS);
    }
    _reconnect.waitFixed(t, NO_TIME_RETRY_MS);
    return false;
  }

  printf("[MQTTS] %s:%u baglaniliyor (kullanici: %s, istemci: %s, bos heap: %u)...\r\n", _server, (unsigned)_port, _user,
         _clientId, (unsigned)ESP.getFreeHeap());

  // 1) TLS: zincir + ana makine adi dogrulamasi (CA = ISRG kokleri)
  _secureClient.stop();
  if (!_secureClient.connect(_server, _port)) {
    char errBuf[96] = {0};
    const int code = _secureClient.lastError(errBuf, sizeof(errBuf));
    if (code == MBEDTLS_ERR_X509_CERT_VERIFY_FAILED) {
      printf("[MQTTS] TLS sertifika DOGRULAMA hatasi (zincir/ana makine adi). Baglanilmayacak. (kod %d)\r\n", code);
      scheduleRetry(true);
    } else if (code != 0) {
      printf("[MQTTS] TLS baglantisi basarisiz (kod %d: %s)\r\n", code, errBuf);
      scheduleRetry(false);
    } else {
      printf("[MQTTS] Sunucuya TCP/DNS baglantisi kurulamadi.\r\n");
      scheduleRetry(false);
    }
    _secureClient.stop();
    return false;
  }

  // 2) Yaprak sertifikanin gecerlilik tarihi (kimlik bilgisi gonderilmeden ONCE)
  if (!leafCertificateValid()) {
    _secureClient.stop();
    scheduleRetry(true);
    return false;
  }

  // 3) MQTT CONNECT (kimlik burada gider). LWT: elektrik/ag kesilince broker "offline" yayinlar.
  const bool ok = _mqttClient.connect(_clientId, _user, _pass, _topicStatus,
                                      1,       // LWT QoS 1
                                      true,    // retain
                                      "offline",
                                      true);   // clean session: bayat komutlar yeniden uygulanmaz
  if (!ok) {
    const int st = _mqttClient.state();
    _secureClient.stop();
    if (st == 4 || st == 5) {
      printf("[MQTTS] Broker kimligi/yetkiyi REDDETTI (CONNACK %d). Uzun bekleme.\r\n", st);
      _reconnect.scheduleAuthRejected(millis(), esp_random());
    } else {
      printf("[MQTTS] MQTT baglantisi basarisiz (durum kodu: %d)\r\n", st);
      scheduleRetry(false);
    }
    return false;
  }

  // 4) Abonelikler (cmd + sys) ve ilk 1500 ms'lik "yok say" penceresi
  const bool subCmd = _mqttClient.subscribe(_topicCmd, 1);
  const bool subSys = _mqttClient.subscribe(_topicSys, 1);
  if (!subCmd || !subSys) {
    printf("[MQTTS] Abonelik istegi gonderilemedi; baglanti yenilenecek.\r\n");
    _mqttClient.disconnect();
    _secureClient.stop();
    scheduleRetry(false);
    return false;
  }
  _ignore.arm(millis(), IGNORE_WINDOW_MS);   // "retained yok say" penceresi (her tur yoklanir: sessizlikte bayat kalmaz)

  {
    MutexGuard g(_mutex, 50);
    _connected = true;
  }
  _reconnect.reset();
  memset(_recentIds, 0, sizeof(_recentIds));
  _recentHead = 0;

  printf("[MQTTS] Baglanti BASARILI (TLS, dogrulanmis). Komut kanali: %s\r\n", _topicCmd);

  // Cevrimici durumu (retain) + ilk tam durum raporu
  publishStatus("online");
  _pace.connected();   // ilk tam durum raporu gecikmeden
  return true;
}

bool MqttManager::publishStatus(const char* text) {
  if (!_mqttClient.connected()) return false;
  // PubSubClient yalnizca QoS 0 yayinlar (LWT QoS 1 CONNECT'te gonderilir)
  return _mqttClient.publish(_topicStatus, text, true);
}

void MqttManager::prepareForRestart() {
  if (_taskHandle == nullptr || _halted) return;
  _shutdownDone = false;
  _shutdownRequested = true;
  const uint32_t start = millis();
  while (!_shutdownDone && (uint32_t)(millis() - start) < 250) {
    vTaskDelay(pdMS_TO_TICKS(5));
  }
}

// ============================================================================
// Durum yayini (CONTRACTS 2.4)
// ============================================================================

namespace {
// Anlik goruntunun "yayinlanmasi gereken degisiklik" imzasi (panjur konumu haric).
template <typename Sig>
void makeSignature(const AutomationSnapshot& s, Sig& out) {
  memset(&out, 0, sizeof(out));
  out.relayMask = s.relayMask;
  out.diMask = s.diMask;
  out.childLock = s.childLock;
  out.totalRelays = s.totalRelays;
  out.totalDIs = s.totalDIs;
  for (uint8_t p = 0; p < 20 && p < (MAX_TOTAL_RELAYS / 2); p++) {
    out.shutter[p] = (uint8_t)((s.shutters[p].moving ? 1 : 0) | ((s.shutters[p].dir & 3) << 1) |
                               (s.shutters[p].waiting ? 8 : 0) | (s.shutters[p].configured ? 16 : 0));
    out.shutterTarget[p] = s.shutters[p].target;
  }
  strncpy(out.lastId, s.lastId, sizeof(out.lastId) - 1);
}

}  // namespace

// Anlik goruntu en son yayinlanan imzadan farkliysa (cocuk kilidi, role, DI, panjur hareketi, last_id...)
// yayin tetiklenir. Boylece degisikligi kimin yaptigindan (web, CLI, duvar anahtari, zamanlayici, MQTT)
// ve FW-core'un triggerPublish() cagirip cagirmadigindan bagimsiz olarak retained durum bayat kalmaz;
// Flutter'in 2.5 sn'lik dogrulamasi uygulanmis bir degisikligi geri almaz. 100 ms'de bir bakilir.
void MqttManager::watchStateChanges(uint32_t now) {
  if (!_publishedSigValid || _needPublish || _pace.isPending()) return;
  if (!_sigCheck.elapsed(now)) return;
  _sigCheck.arm(now, 100);
  AutomationSnapshot snap;
  if (!SmartAutomation::instance().getSnapshot(snap)) return;
  StateSignature cur;
  makeSignature(snap, cur);
  if (memcmp(&cur, &_publishedSig, sizeof(cur)) != 0) triggerPublish();
}

// Yayin zamani: tetik bayragi gozlenince 250 ms birlestirme; yayin yoksa 30 sn kalp atisi; hata sonrasi ustel bekleme
// (NetUtil::PublishPacer). Hicbir yerde saklanmis hedef zaman yok.
void MqttManager::publishIfDue(uint32_t now) {
  if (_pace.due(now, _needPublish)) publishState();
}

namespace {
struct RelayView {
  char name[MAX_TOTAL_RELAYS][32];
  uint8_t type[MAX_TOTAL_RELAYS];
};
}  // namespace

bool MqttManager::publishState() {
  // Bayrak ve bekleyen istek, anlik goruntuden ONCE temizlenir: goruntu alinirken gelen yeni tetikleme kaybolmaz.
  _needPublish = false;
  _pace.beginSend();

  auto fail = [&](const char* why) -> bool {
    // istek korunur (pacer: bekleyen); 1,2,4,8,16,30 sn bekleme
    const uint32_t wait = _pace.failed(millis());
    printf("[MQTTS] Durum raporu yayinlanamadi: %s (sonraki deneme %u ms sonra)\r\n", why, (unsigned)wait);
    return false;
  };

  AutomationSnapshot snap;
  if (!SmartAutomation::instance().getSnapshot(snap)) return fail("anlik goruntu alinamadi");

  RelayView* view = (RelayView*)malloc(sizeof(RelayView));
  if (!view) return fail("bellek (goruntu)");

  const uint8_t nR = (snap.totalRelays > MAX_TOTAL_RELAYS) ? (uint8_t)MAX_TOTAL_RELAYS : snap.totalRelays;
  const uint8_t nD = (snap.totalDIs > MAX_TOTAL_DIS) ? (uint8_t)MAX_TOTAL_DIS : snap.totalDIs;
  {
    ConfigManager::ConfigLock lk(ConfigManager::instance());
    const SystemConfig& cfg = ConfigManager::instance().config;
    for (uint8_t i = 0; i < nR; i++) {
      NetUtil::sanitizeInto(view->name[i], sizeof(view->name[i]), cfg.relays[i].name);
      view->type[i] = cfg.relays[i].type;
    }
  }

  // Yalnizca gercekten panjur olarak tanimli ciftler raporlanir ("hayalet panjur" yok).
  // "configured": FW-core'un kendi gecerlilik kurali (UP+DOWN tipli cift).
  uint8_t pairs[MAX_TOTAL_RELAYS / 2];
  uint8_t nS = 0;
  const uint8_t maxPairs = nR / 2;
  for (uint8_t p = 0; p < maxPairs; p++) {
    if (snap.shutters[p].configured) pairs[nS++] = p;
  }

  // ArduinoJson havuzu: oge sayisindan hesaplanir (adlar kopyalanmaz: gecici goruntuye isaret eder)
  const size_t cap = JSON_OBJECT_SIZE(12) + JSON_ARRAY_SIZE(nR) + (size_t)nR * JSON_OBJECT_SIZE(4) +
                     JSON_ARRAY_SIZE(nS) + (size_t)nS * JSON_OBJECT_SIZE(5) + JSON_ARRAY_SIZE(nD) +
                     (size_t)nD * JSON_OBJECT_SIZE(2) + 64;
  DynamicJsonDocument doc(cap);
  if (doc.capacity() == 0) {
    free(view);
    return fail("bellek (JSON havuzu)");
  }

  const IPAddress ipa = WiFiManager::instance().getLocalIP();
  char ip[16];
  snprintf(ip, sizeof(ip), "%u.%u.%u.%u", ipa[0], ipa[1], ipa[2], ipa[3]);

  const uint32_t seq = ++_seq;
  doc["v"] = 2;
  doc["uid"] = (const char*)_uid;
  doc["fw"] = FW_VERSION;
  doc["seq"] = seq;
  doc["uptime"] = (uint32_t)(esp_timer_get_time() / 1000000ULL);
  doc["ip"] = (const char*)ip;
  doc["child_lock"] = snap.childLock;
  // Bos "last_id" gonderilmez (backend [A-Za-z0-9_.:-]{1,24} bekler; bos deger "atlandi" sayilir)
  if (snap.lastId[0] != '\0') doc["last_id"] = (const char*)snap.lastId;

  JsonArray rArr = doc.createNestedArray("relays");
  for (uint8_t i = 0; i < nR; i++) {
    JsonObject r = rArr.createNestedObject();
    r["id"] = i + 1;   // 1 tabanli
    r["name"] = (const char*)view->name[i];
    r["type"] = relayTypeName(view->type[i]);
    r["state"] = snap.relay(i);
  }

  JsonArray sArr = doc.createNestedArray("shutters");
  for (uint8_t k = 0; k < nS; k++) {
    const uint8_t p = pairs[k];
    const ShutterSnapshot& sh = snap.shutters[p];
    JsonObject s = sArr.createNestedObject();
    s["pair"] = p + 1;   // 1 tabanli
    s["pos"] = sh.pos;
    s["moving"] = sh.moving;
    s["dir"] = sh.dir;
    s["target"] = sh.target;
  }

  JsonArray dArr = doc.createNestedArray("dis");
  for (uint8_t i = 0; i < nD; i++) {
    JsonObject d = dArr.createNestedObject();
    d["id"] = i + 1;
    d["state"] = snap.di(i);
  }

  if (doc.overflowed()) {
    free(view);
    printf("[MQTTS] HATA: ArduinoJson havuzu tasti (kapasite %u, role %u, panjur %u, DI %u); yayin YAPILMADI.\r\n",
           (unsigned)cap, (unsigned)nR, (unsigned)nS, (unsigned)nD);
    return fail("JSON havuzu tasti");
  }

  const size_t len = measureJson(doc);
  if (len == 0 || len > MAX_STATE_BYTES) {
    free(view);
    return fail("yuk boyutu gecersiz");
  }
  const size_t need = MQTT_MAX_HEADER_SIZE + 2 + strlen(_topicState) + len;
  if (_mqttClient.getBufferSize() < need) {
    if (!_mqttClient.setBufferSize((uint16_t)need)) {
      free(view);
      return fail("MQTT arabellegi buyutulemedi");
    }
  }

  char* out = (char*)malloc(len + 1);
  if (!out) {
    free(view);
    return fail("bellek (yuk)");
  }
  serializeJson(doc, out, len + 1);
  free(view);   // adlara isaret eden dizgeler serilestirildi

  const bool ok = _mqttClient.publish(_topicState, (const uint8_t*)out, (unsigned int)len, true);   // retain
  free(out);
  if (!ok) return fail("yayin basarisiz");

  _pace.sent(millis());
  makeSignature(snap, _publishedSig);   // "en son yayinlanan" durum: gozcu bununla karsilastirir
  _publishedSigValid = true;
  if ((seq % 20) == 1) {
    printf("[MQTTS] Durum raporu yayinlandi (seq %u, %u bayt)\r\n", (unsigned)seq, (unsigned)len);
  }
  return true;
}

// ============================================================================
// Gelen mesajlar
// ============================================================================
bool MqttManager::seenId(const char* id) const {
  for (uint8_t i = 0; i < 8; i++) {
    if (_recentIds[i][0] != '\0' && strcmp(_recentIds[i], id) == 0) return true;
  }
  return false;
}

bool MqttManager::rememberId(const char* id) {
  strncpy(_recentIds[_recentHead], id, sizeof(_recentIds[0]) - 1);
  _recentIds[_recentHead][sizeof(_recentIds[0]) - 1] = '\0';
  _recentHead = (uint8_t)((_recentHead + 1) % 8);
  return true;
}

void MqttManager::onMessage(char* topic, byte* payload, unsigned int length) {
  const bool isCmd = (strcmp(topic, _topicCmd) == 0);
  const bool isSys = (strcmp(topic, _topicSys) == 0);
  if (!isCmd && !isSys) return;

  // Abonelikten sonraki ilk 1500 ms: yeniden uygulanmis (retained) mesaja karsi savunma. Pencere gorev dongusunde her
  // tur yoklandigi icin haftalarca komutsuz kalinsa bile ilk gercek komut ISLENIR (N6; eski hedef-zaman karsilastirmasi
  // 24,86 gun sonra pencereyi "hala acik" sanip TUM komutlari yok sayardi).
  if (_ignore.running(millis())) {
    printf("[MQTTS] Abonelik penceresinde (ilk %u ms) gelen mesaj yok sayildi.\r\n", (unsigned)IGNORE_WINDOW_MS);
    if (isSys && length > 0) memset(payload, 0, length);
    return;
  }

  if (length == 0 || length > MAX_CMD_PAYLOAD) {
    printf("[MQTTS] Gecersiz yuk boyutu (%u bayt); yok sayildi.\r\n", length);
    return;
  }

  if (isSys) {
    handleSys(payload, length);   // anahtar iceren yuk: loglanmaz, isi bitince sifirlanir
  } else {
    handleCommand(payload, length);
  }
}

void MqttManager::handleCommand(const uint8_t* payload, unsigned int length) {
  StaticJsonDocument<768> doc;
  const DeserializationError err = deserializeJson(doc, (const char*)payload, length);
  if (err) {
    printf("[MQTTS] Komut JSON hatasi: %s\r\n", err.c_str());
    return;
  }
  if (!doc.is<JsonObject>()) {
    printf("[MQTTS] Komut reddedildi: kok nesne olmali.\r\n");
    return;
  }

  uint8_t totalRelays;
  {
    ConfigManager::ConfigLock lk(ConfigManager::instance());
    totalRelays = ConfigManager::instance().config.totalRelays();
  }

  DeviceCommand cmd;
  const char* reason = parseCommand(doc.as<JsonObject>(), totalRelays, cmd);
  if (reason != nullptr) {
    printf("[MQTTS] Komut reddedildi: %s\r\n", reason);
    return;
  }

  if (cmd.id[0] != '\0' && seenId(cmd.id)) {
    printf("[MQTTS] Tekrar eden komut kimligi yok sayildi (id: %s).\r\n", cmd.id);
    return;
  }

  if (!postDeviceCommand(cmd)) {
    // Kuyruk dolu: sessizce yutulmaz; id kaydedilmez (istemci ayni komutu yeniden deneyebilir)
    printf("[MQTTS] UYARI: komut kuyrugu dolu, komut dusuruldu (tip %d).\r\n", (int)cmd.type);
    return;
  }
  if (cmd.id[0] != '\0') rememberId(cmd.id);
  printf("[MQTTS] Komut kuyruga alindi (tip %d, indeks %u, deger %ld)\r\n", (int)cmd.type, (unsigned)cmd.index,
         (long)cmd.value);
  triggerPublish();   // sonucu (ve last_id'yi) bildirmek icin
}

void MqttManager::handleSys(uint8_t* payload, unsigned int length) {
  StaticJsonDocument<384> doc;
  const DeserializationError err = deserializeJson(doc, (const char*)payload, length);
  memset(payload, 0, length);   // anahtar PubSubClient arabelleginde kalmasin
  if (err || !doc.is<JsonObject>()) {
    printf("[MQTTS] sys yuku gecersiz.\r\n");
    return;
  }

  // Yalnizca {"cmd":"set_local_key","local_key":"..."} (+ istege bagli "id").
  // Anahtar alani backend'in kullandigi "local_key"dir; "key" ayni anlamda takma ad olarak kabul edilir.
  const char* cmd = nullptr;
  const char* key = nullptr;
  for (JsonPair kv : doc.as<JsonObject>()) {
    const char* k = kv.key().c_str();
    if (!strcmp(k, "cmd")) {
      if (!kv.value().is<const char*>()) {
        printf("[MQTTS] sys reddedildi: cmd metin olmali.\r\n");
        return;
      }
      cmd = kv.value().as<const char*>();
    } else if (!strcmp(k, "local_key") || !strcmp(k, "key")) {
      if (key != nullptr || !kv.value().is<const char*>()) {   // yinelenen/yanlis tipli anahtar alani
        printf("[MQTTS] sys reddedildi: anahtar alani metin olmali ve tek olmali.\r\n");
        return;
      }
      key = kv.value().as<const char*>();
    } else if (!strcmp(k, "id")) {
      // izinli, kullanilmaz
    } else {
      printf("[MQTTS] sys reddedildi: bilinmeyen alan.\r\n");
      return;
    }
  }
  if (cmd == nullptr || strcmp(cmd, "set_local_key") != 0) {
    printf("[MQTTS] sys reddedildi: bilinmeyen komut.\r\n");
    return;
  }
  const size_t klen = key ? strlen(key) : 0;
  if (key == nullptr || klen < LOCAL_KEY_MIN_LEN || klen > LOCAL_KEY_MAX_LEN || !NetUtil::isPrintableAsciiNoSpace(key, klen)) {
    printf("[MQTTS] sys reddedildi: gecersiz anahtar bicimi.\r\n");
    return;
  }

  if (ConfigManager::instance().setLocalKey(key)) {
    printf("[MQTTS] Yerel anahtar guncellendi (sys/set_local_key).\r\n");
    WiFiManager::instance().applyApConfigChange();   // provizyon durumu degisti: AP ilkesi yeniden degerlendirilir
  } else {
    printf("[MQTTS] HATA: yerel anahtar kaydedilemedi.\r\n");
  }
}
