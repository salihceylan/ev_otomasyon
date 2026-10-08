#include "MqttManager.h"
#include "ConfigManager.h"
#include "SmartAutomation.h"
#include "DeviceCommand.h"
#include "WiFiManager.h"
#include "NetUtil.h"
#include "CaCerts.h"
#include "NetLink.h"
#include "template/TemplateStore.h"
#include "safety/SafetyManager.h"
#include "safety/SafetyCfgApi.h"
#include "safety/SafetyCfgJson.h"
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
const size_t MAX_SYS_PAYLOAD = 1024;          // sys (cfg_patch) ayri sinir [D2][B11]; cmd 512'de kalir
const size_t STATE_EXTRA_MAX = 8192;          // state v:3 eki (tam dolu: 56 sensor + 16 eylemci + 4 bolge ~7 KB) [B12]
const uint32_t MQTT_TASK_STACK = 12288;       // TLS el sikismasi + JSON icin (once 8192)
const uint16_t MQTT_BASE_BUFFER = 1280;       // gelen sys yuku (1024) + konu + baslik sigmali (PubSubClient fazlasini dusurur)
const size_t MAX_STATE_BYTES = 30000;
const uint32_t WATERMARK_LOG_MS = 300000;

// Bayrak bitleri (komut dogrulama). v1.2.0: 17 alan (8 eski + 9 yeni) -> uint32_t (spec 3.3 uint16_t diyordu; 17 bit sigmaz).
const uint32_t F_RELAY = 1;
const uint32_t F_SHUTTER = 2;
const uint32_t F_CMD = 4;
const uint32_t F_STATE = 8;
const uint32_t F_POS = 16;
const uint32_t F_ENABLED = 32;
const uint32_t F_SEC = 64;
const uint32_t F_ID = 128;
const uint32_t F_ACTUATOR = 1u << 8;
const uint32_t F_TO = 1u << 9;
const uint32_t F_ZONE = 1u << 10;
const uint32_t F_AID = 1u << 11;
const uint32_t F_MODE = 1u << 12;
const uint32_t F_C10 = 1u << 13;
const uint32_t F_SCENE = 1u << 14;
const uint32_t F_EIDS = 1u << 15;
const uint32_t F_UID = 1u << 16;

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

// CONTRACTS Bolum 2.3 + 2.6: komut yuku dogrulamasi. Basariliysa nullptr, degilse reddetme nedeni.
// Bilinmeyen alan/komut, tip uyusmazligi, aralik disi deger => komut UYGULANMAZ (sessiz varsayilan yok).
// Guvenlik komutlari (actuator, alarm_ack, alarm_test, safety_arm, climate_target, scene_run, event_ack) "uid" ZORUNLU ister (ev konusu
// evdeki butun panolara gider; eylemci/bolge numaralari pano basinadir) [Y5][Y-9]. Duz v:2 komutlarinda uid istege baglidir.
// uid eslesmesi (baska panonun komutu sessizce yok sayilir) cagiranda, ayristirmadan ONCE denetlenir.
struct ParsedCmd {
  DeviceCommand cmd;
  bool eventAck;                            // event_ack: kuyruga yazilmaz, MqttTask outbox'tan siler
  uint8_t nEids;
  char eids[8][safety::EID_LEN];
};

bool validEidText(const char* s) {
  if (!s) return false;
  const size_t n = strlen(s);
  if (n < 3 || n >= safety::EID_LEN) return false;
  for (size_t i = 0; i < n; i++) {
    const char c = s[i];
    if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || c == '-')) return false;
  }
  return true;
}

const char* parseCommand(JsonObject obj, uint8_t totalRelays, ParsedCmd& out) {
  uint32_t flags = 0;
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
    else if (!strcmp(k, "actuator")) flags |= F_ACTUATOR;
    else if (!strcmp(k, "to")) flags |= F_TO;
    else if (!strcmp(k, "zone")) flags |= F_ZONE;
    else if (!strcmp(k, "aid")) flags |= F_AID;
    else if (!strcmp(k, "mode")) flags |= F_MODE;
    else if (!strcmp(k, "c10")) flags |= F_C10;
    else if (!strcmp(k, "scene")) flags |= F_SCENE;
    else if (!strcmp(k, "eids")) flags |= F_EIDS;
    else if (!strcmp(k, "uid")) flags |= F_UID;
    else return "bilinmeyen alan";
  }

  const uint8_t totalPairs = totalRelays / 2;
  const uint32_t body = flags & ~(F_ID | F_UID);   // id ve uid yalnizca istege bagli eslik eder

  // Tip dogrulamalari: mevcut her alan beklenen JSON tipinde olmali
  if ((flags & F_RELAY) && !obj["relay"].is<int>()) return "relay tamsayi olmali";
  if ((flags & F_SHUTTER) && !obj["shutter"].is<int>()) return "shutter tamsayi olmali";
  if ((flags & F_POS) && !obj["pos"].is<int>()) return "pos tamsayi olmali";
  if ((flags & F_SEC) && !obj["sec"].is<int>()) return "sec tamsayi olmali";
  if ((flags & F_STATE) && !obj["state"].is<bool>()) return "state boolean olmali";
  if ((flags & F_ENABLED) && !obj["enabled"].is<bool>()) return "enabled boolean olmali";
  if ((flags & F_CMD) && !obj["cmd"].is<const char*>()) return "cmd metin olmali";
  if ((flags & F_ACTUATOR) && !obj["actuator"].is<const char*>()) return "actuator metin olmali";
  if ((flags & F_TO) && !obj["to"].is<const char*>()) return "to metin olmali";
  if ((flags & F_ZONE) && !obj["zone"].is<int>()) return "zone tamsayi olmali";
  if ((flags & F_AID) && !obj["aid"].is<const char*>()) return "aid metin olmali";
  if ((flags & F_MODE) && !obj["mode"].is<const char*>()) return "mode metin olmali";
  if ((flags & F_C10) && !obj["c10"].is<int>()) return "c10 tamsayi olmali";
  if ((flags & F_SCENE) && !obj["scene"].is<int>()) return "scene tamsayi olmali";
  if ((flags & F_EIDS) && !obj["eids"].is<JsonArray>()) return "eids dizi olmali";
  if ((flags & F_UID) && !obj["uid"].is<const char*>()) return "uid metin olmali";

  int relay = 0, shutter = 0, pos = 0, sec = 0, zone = 0;
  if (flags & F_RELAY) relay = obj["relay"].as<int>();
  if (flags & F_SHUTTER) shutter = obj["shutter"].as<int>();
  if (flags & F_POS) pos = obj["pos"].as<int>();
  if (flags & F_SEC) sec = obj["sec"].as<int>();
  if (flags & F_ZONE) zone = obj["zone"].as<int>();

  DeviceCommand& c = out.cmd;
  c = makeCommand(CmdType::ALL_LIGHTS_OFF, CmdSource::MQTT);
  out.eventAck = false;
  out.nEids = 0;
  bool needsUid = false;

  if (flags & F_ACTUATOR) {
    // Eylemci komutu: {"actuator":"a1","to":"closed"|"open"|"on"|"off","uid":...}
    if (body != (F_ACTUATOR | F_TO)) return "actuator yalnizca to ile";
    uint8_t a0 = 0;
    if (!safety::parseActuatorId(obj["actuator"].as<const char*>(), a0)) return "actuator araligi (a1..a16)";
    const char* to = obj["to"].as<const char*>();
    int32_t v;
    if (!strcmp(to, "closed")) v = safety::ACT_TO_CLOSED;
    else if (!strcmp(to, "open")) v = safety::ACT_TO_OPEN;
    else if (!strcmp(to, "off")) v = safety::ACT_TO_OFF;
    else if (!strcmp(to, "on")) v = safety::ACT_TO_ON;
    else return "to gecersiz (closed|open|on|off)";
    c = makeCommand(CmdType::ACTUATOR_SET, CmdSource::MQTT, (uint8_t)(a0 + 1), v);
    needsUid = true;
  } else if (flags & F_CMD) {
    const char* cs = obj["cmd"].as<const char*>();
    if (cs == nullptr) return "cmd metin olmali";

    if (!strcmp(cs, "toggle")) {
      if (body != (F_CMD | F_RELAY)) return "toggle yalnizca relay ile";
      if (relay < 1 || relay > totalRelays) return "relay araligi";
      c = makeCommand(CmdType::RELAY_TOGGLE, CmdSource::MQTT, (uint8_t)relay, 0);
    } else if (!strcmp(cs, "up") || !strcmp(cs, "down") || !strcmp(cs, "stop") || !strcmp(cs, "step")) {
      if (body != (F_CMD | F_SHUTTER)) return "panjur komutu yalnizca shutter ile";
      if (shutter < 1 || shutter > totalPairs) return "shutter araligi";
      CmdType t = CmdType::SHUTTER_STOP;
      if (!strcmp(cs, "up")) t = CmdType::SHUTTER_UP;
      else if (!strcmp(cs, "down")) t = CmdType::SHUTTER_DOWN;
      else if (!strcmp(cs, "step")) t = CmdType::SHUTTER_STEP;
      c = makeCommand(t, CmdSource::MQTT, (uint8_t)shutter, 0);
    } else if (!strcmp(cs, "all_lights_off") || !strcmp(cs, "all_off")) {
      if (body != F_CMD) return "toplu komut baska alan almaz";
      c = makeCommand(CmdType::ALL_LIGHTS_OFF, CmdSource::MQTT);
    } else if (!strcmp(cs, "all_shutters_up")) {
      if (body != F_CMD) return "toplu komut baska alan almaz";
      c = makeCommand(CmdType::ALL_SHUTTERS_UP, CmdSource::MQTT);
    } else if (!strcmp(cs, "all_shutters_down")) {
      if (body != F_CMD) return "toplu komut baska alan almaz";
      c = makeCommand(CmdType::ALL_SHUTTERS_DOWN, CmdSource::MQTT);
    } else if (!strcmp(cs, "all_shutters_stop")) {
      if (body != F_CMD) return "toplu komut baska alan almaz";
      c = makeCommand(CmdType::ALL_SHUTTERS_STOP, CmdSource::MQTT);
    } else if (!strcmp(cs, "set_child_lock")) {
      // Eksik/bozuk "enabled" ASLA "false" sayilmaz (fail-open yok)
      if (body != (F_CMD | F_ENABLED)) return "set_child_lock enabled(boolean) ister";
      c = makeCommand(CmdType::SET_CHILD_LOCK, CmdSource::MQTT, 0, obj["enabled"].as<bool>() ? 1 : 0);
    } else if (!strcmp(cs, "set_runtime")) {
      if (body != (F_CMD | F_SHUTTER | F_SEC)) return "set_runtime shutter ve sec ister";
      if (shutter < 1 || shutter > totalPairs) return "shutter araligi";
      if (sec < SHUTTER_RUNTIME_MIN_SEC || sec > SHUTTER_RUNTIME_MAX_SEC) return "sec araligi (1..300)";
      c = makeCommand(CmdType::SET_RUNTIME, CmdSource::MQTT, (uint8_t)shutter, sec);
    } else if (!strcmp(cs, "alarm_ack")) {
      // Onay + susturma; aid bolgenin guncel alarm kimligiyle eslesmezse stale_ack [Y-9]. Uzaktan guvenli kipten cikis YOK (force yok).
      if (body != (F_CMD | F_ZONE) && body != (F_CMD | F_ZONE | F_AID)) return "alarm_ack zone (ve aid) ister";
      if (zone < 0 || zone > safety::MAX_ZONES) return "zone araligi (0..4)";
      c = makeCommand(CmdType::ALARM_ACK, CmdSource::MQTT, (uint8_t)zone, 0);
      if (flags & F_AID) {
        const char* aid = obj["aid"].as<const char*>();
        if (!validEidText(aid)) return "aid gecersiz";
        strncpy(c.aid, aid, sizeof(c.aid) - 1);
        c.aid[sizeof(c.aid) - 1] = '\0';
      }
      needsUid = true;
    } else if (!strcmp(cs, "alarm_test")) {
      if (body != (F_CMD | F_ZONE)) return "alarm_test yalnizca zone ile";
      if (zone < 1 || zone > safety::MAX_ZONES) return "zone araligi (1..4)";
      c = makeCommand(CmdType::ALARM_TEST, CmdSource::MQTT, (uint8_t)zone, 0);
      needsUid = true;
    } else if (!strcmp(cs, "safety_arm")) {
      if (body != (F_CMD | F_MODE)) return "safety_arm yalnizca mode ile";
      const char* m = obj["mode"].as<const char*>();
      int32_t v;
      if (!strcmp(m, "away")) v = 1;
      else if (!strcmp(m, "home")) v = 2;
      else if (!strcmp(m, "off")) v = 0;
      else return "mode gecersiz (away|home|off)";
      c = makeCommand(CmdType::SAFETY_ARM, CmdSource::MQTT, 0, v);
      needsUid = true;
    } else if (!strcmp(cs, "climate_target")) {
      if (body != (F_CMD | F_ZONE | F_C10)) return "climate_target zone ve c10 ister";
      const int c10 = obj["c10"].as<int>();
      if (zone < 1 || zone > safety::MAX_ZONES) return "zone araligi (1..4)";
      if (c10 < 50 || c10 > 350) return "c10 araligi (50..350)";
      c = makeCommand(CmdType::CLIMATE_TARGET, CmdSource::MQTT, (uint8_t)zone, c10);
      needsUid = true;
    } else if (!strcmp(cs, "scene_run")) {
      if (body != (F_CMD | F_SCENE)) return "scene_run yalnizca scene ile";
      const int sc = obj["scene"].as<int>();
      if (sc < 1 || sc > 32) return "scene araligi (1..32)";
      c = makeCommand(CmdType::SCENE_RUN, CmdSource::MQTT, (uint8_t)sc, 0);
      needsUid = true;
    } else if (!strcmp(cs, "event_ack")) {
      if (body != (F_CMD | F_EIDS)) return "event_ack yalnizca eids ile";
      JsonArray a = obj["eids"].as<JsonArray>();
      if (a.size() < 1 || a.size() > 8) return "eids 1..8 oge";
      for (JsonVariant x : a) {
        if (!x.is<const char*>() || !validEidText(x.as<const char*>())) return "eid gecersiz";
        strncpy(out.eids[out.nEids], x.as<const char*>(), safety::EID_LEN - 1);
        out.eids[out.nEids][safety::EID_LEN - 1] = '\0';
        out.nEids++;
      }
      out.eventAck = true;
      needsUid = true;
    } else {
      return "bilinmeyen komut";
    }
  } else if (body == (F_RELAY | F_STATE)) {
    if (relay < 1 || relay > totalRelays) return "relay araligi";
    c = makeCommand(CmdType::RELAY_SET, CmdSource::MQTT, (uint8_t)relay, obj["state"].as<bool>() ? 1 : 0);
  } else if (body == (F_SHUTTER | F_POS)) {
    // pos once aralik denetiminden gecer; uint8_t'e kesme (256 -> 0) yoktur
    if (shutter < 1 || shutter > totalPairs) return "shutter araligi";
    if (pos < 0 || pos > 100) return "pos araligi (0..100)";
    c = makeCommand(CmdType::SHUTTER_POS, CmdSource::MQTT, (uint8_t)shutter, pos);
  } else {
    return "gecersiz komut bicimi";
  }

  if (needsUid && !(flags & F_UID)) return "uid zorunlu";

  if (flags & F_ID) {
    if (!obj["id"].is<const char*>()) return "id metin olmali";
    const char* id = obj["id"].as<const char*>();
    if (!validCommandId(id)) return "id gecersiz (1..24, [A-Za-z0-9._:-])";
    strncpy(c.id, id, sizeof(c.id) - 1);
    c.id[sizeof(c.id) - 1] = '\0';
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
      _connectedAt(0),
      _haveCreds(false),
      _enabled(true),
      _port(8884),
      _publishedSigValid(false),
      _recentHead(0) {
  _server[0] = _user[0] = _pass[0] = _topicId[0] = '\0';
  _topicStatus[0] = _topicState[0] = _topicCmd[0] = _topicSys[0] = _topicEvent[0] = '\0';
  _clientId[0] = _uid[0] = '\0';
  memset(_recentIds, 0, sizeof(_recentIds));
  _acceptId[0] = _acceptBase[0] = '\0';
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
      snprintf(_topicEvent, sizeof(_topicEvent), "ev/%s/event", _topicId);
    } else {
      _topicStatus[0] = _topicState[0] = _topicCmd[0] = _topicSys[0] = _topicEvent[0] = '\0';
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

    // v1.3.0 (K-Ş1): ag = Wi-Fi VEYA Ethernet (NetLinkCore::mqttNetOk; Ethernet yokken eskisiyle ayni).
    const bool netOk = netlink::mqttNetOk(WiFiManager::instance().isConnected(), NetLink::ethUp());
    if (!netOk) {
      // Ag koptu: yarim kalmis TLS soketi kapatilir (eski baglanti "bagli" gorunmesin)
      if (_connected || _secureClient.connected()) {
        dropConnection("Wi-Fi koptu", false);
        scheduleRetry(false);
      }
      vTaskDelay(pdMS_TO_TICKS(TASK_TICK_MS));
      continue;
    }

    // v1.3.0 (inceleme R1-5): baglanti kuruldugu andaki etkin arayuz saklanir; etkin arayuz degisirse (Ethernet <-> Wi-Fi) TLS soketi
    // eski arayuzde kalmasin diye baglanti birakilip hemen yeniden kurulur (NetLinkCore::mqttIfChanged).
    {
      static netlink::NetIf s_via = netlink::NetIf::NONE;   // yalniz MQTT gorevi
      const netlink::NetIf active = netlink::activeIf(WiFiManager::instance().isConnected(), NetLink::ethUp());
      if (!_mqttClient.connected()) {
        s_via = netlink::NetIf::NONE;
      } else if (s_via == netlink::NetIf::NONE) {
        s_via = active;
      } else if (netlink::mqttIfChanged(s_via, active)) {
        printf("[MQTTS] Etkin ag arayuzu degisti (%s -> %s): yeniden baglaniliyor.\r\n", netlink::netIfName(s_via),
               netlink::netIfName(active));
        dropConnection("ag arayuzu degisti", false);
        s_via = netlink::NetIf::NONE;
        _reconnect.reset();
      }
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
        publishEventsIfDue(millis());   // ev/{t}/event: uygulama duzeyinde onayli teslim (spec 3.4)
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
  _connectedAt = millis();                   // olay tamponu bu pencere bitmeden bosaltilmaz [D4]

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
  // Guvenlik katmani (spec 3.2 "Yayin tetigi"): gorunum imzasi (since_up haric), ret sayaci, saat durumu. Eklenmeseydi alarm
  // 30 sn'lik kalp atisina kadar yayinlanmazdi.
  auto& sm = safety::SafetyManager::instance();
  out.safetySig = sm.viewSig();
  out.rejSeq = sm.rejSeq();
  out.timeOk = NetUtil::isTimeSynced();
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
  overlayAcceptedId(snap);
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
  overlayAcceptedId(snap);

  // Guvenlik gorunumu (kopya; JSON kilit DISINDA uretilir [B13]) ve v:3 eki. Imza ONCE alinir: kopya sirasinda degisirse bir sonraki
  // gozcu turu yeniden yayinlar.
  auto& sm = safety::SafetyManager::instance();
  const uint32_t sigAtCopy = sm.viewSig();
  const uint32_t rejAtCopy = sm.rejSeq();
  safety::SafetyView* sv = (safety::SafetyView*)malloc(sizeof(safety::SafetyView));
  if (!sv) return fail("bellek (guvenlik gorunumu)");
  if (!sm.copyView(*sv)) {
    free(sv);
    return fail("guvenlik gorunumu alinamadi");
  }
  safety::StateMeta meta;
  sm.stateMeta(meta);
  meta.timeOk = NetUtil::isTimeSynced() ? 1 : 0;
  meta.epoch = meta.timeOk ? (uint32_t)time(nullptr) : 0;
  char* extra = (char*)malloc(STATE_EXTRA_MAX);
  if (!extra) {
    free(sv);
    return fail("bellek (durum eki)");
  }
  safety::ev_detail::Writer xw(extra, STATE_EXTRA_MAX);
  safety::writeStateExtras(*sv, meta, xw);
  if (!xw.ok) {
    free(sv);
    free(extra);
    return fail("durum eki sigmadi");
  }
  const size_t extraLen = xw.len;
  const char* acts[MAX_TOTAL_RELAYS];
  for (uint8_t i = 0; i < MAX_TOTAL_RELAYS; i++) acts[i] = safety::relayActText(*sv, (uint8_t)(i + 1));
  free(sv);

  RelayView* view = (RelayView*)malloc(sizeof(RelayView));
  if (!view) {
    free(extra);
    return fail("bellek (goruntu)");
  }

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
  const size_t cap = JSON_OBJECT_SIZE(16) + JSON_OBJECT_SIZE(2) + JSON_ARRAY_SIZE(nR) + (size_t)nR * JSON_OBJECT_SIZE(5) +
                     JSON_ARRAY_SIZE(nS) + (size_t)nS * JSON_OBJECT_SIZE(5) + JSON_ARRAY_SIZE(nD) +
                     (size_t)nD * JSON_OBJECT_SIZE(2) + 64;
  DynamicJsonDocument doc(cap);
  if (doc.capacity() == 0) {
    free(view);
    free(extra);
    return fail("bellek (JSON havuzu)");
  }

  // "ip" = etkin arayuzun IP'si (Wi-Fi > Ethernet; ag yoksa 0.0.0.0) -- Ethernet yokken eskisiyle ayni (NetLinkCore::stateIp).
  const NetLink::Snapshot ns = NetLink::snapshot();
  char ip[16], ethIp[16];
  netlink::ipToStr(netlink::stateIp(ns.wifiUp, ns.wifiIp, ns.ethUp, ns.ethIp), ip, sizeof(ip));
  netlink::ipToStr(ns.ethIp, ethIp, sizeof(ethIp));
  tpl::TplRecord tplRec;
  tpl::TemplateStore::get(tplRec);

  const uint32_t seq = ++_seq;
  doc["v"] = 3;   // v:2'nin kati ust kumesi (spec 3.1); ek alanlar asagida nesnenin sonuna eklenir
  doc["uid"] = (const char*)_uid;
  doc["fw"] = FW_VERSION;
  doc["seq"] = seq;
  doc["uptime"] = (uint32_t)(esp_timer_get_time() / 1000000ULL);
  doc["ip"] = (const char*)ip;
  doc["child_lock"] = snap.childLock;
  // Bos "last_id" gonderilmez (backend [A-Za-z0-9_.:-]{1,24} bekler; bos deger "atlandi" sayilir)
  if (snap.lastId[0] != '\0') doc["last_id"] = (const char*)snap.lastId;
  // v1.3.0 (CONTRACTS 3e): yeni alanlar; "tpl" yalniz sablon yukluyse.
  doc["eth_connected"] = ns.ethUp;
  doc["eth_ip"] = (const char*)ethIp;
  doc["net_if"] = netlink::netIfName(ns.active);
  if (tplRec.present) {
    JsonObject t = doc.createNestedObject("tpl");
    t["id"] = (const char*)tplRec.id;
    t["ver"] = tplRec.ver;
  }

  JsonArray rArr = doc.createNestedArray("relays");
  for (uint8_t i = 0; i < nR; i++) {
    JsonObject r = rArr.createNestedObject();
    r["id"] = i + 1;   // 1 tabanli
    r["name"] = (const char*)view->name[i];
    r["type"] = relayTypeName(view->type[i]);
    r["state"] = snap.relay(i);
    if (acts[i]) r["act"] = acts[i];   // yalniz eylemci rolelerinde (type ayni kalir) [K1]
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
    free(extra);
    printf("[MQTTS] HATA: ArduinoJson havuzu tasti (kapasite %u, role %u, panjur %u, DI %u); yayin YAPILMADI.\r\n",
           (unsigned)cap, (unsigned)nR, (unsigned)nS, (unsigned)nD);
    return fail("JSON havuzu tasti");
  }

  const size_t baseLen = measureJson(doc);
  const size_t len = baseLen + extraLen;
  if (baseLen < 2 || len > MAX_STATE_BYTES) {
    free(view);
    free(extra);
    return fail("yuk boyutu gecersiz");
  }
  const size_t need = MQTT_MAX_HEADER_SIZE + 2 + strlen(_topicState) + len;
  if (_mqttClient.getBufferSize() < need) {
    if (!_mqttClient.setBufferSize((uint16_t)need)) {
      free(view);
      free(extra);
      return fail("MQTT arabellegi buyutulemedi");
    }
  }

  char* out = (char*)malloc(len + 1);
  if (!out) {
    free(view);
    free(extra);
    return fail("bellek (yuk)");
  }
  serializeJson(doc, out, baseLen + 1);
  free(view);   // adlara isaret eden dizgeler serilestirildi
  // v:3 eki kapanis '}' ONCESINE eklenir: { ...v:2 alanlari... ,"caps":[...] ... }
  memcpy(out + baseLen - 1, extra, extraLen);
  out[len - 1] = '}';
  out[len] = '\0';
  free(extra);

  const bool ok = _mqttClient.publish(_topicState, (const uint8_t*)out, (unsigned int)len, true);   // retain
  free(out);
  if (!ok) return fail("yayin basarisiz");

  _pace.sent(millis());
  makeSignature(snap, _publishedSig);   // "en son yayinlanan" durum: gozcu bununla karsilastirir
  _publishedSig.safetySig = sigAtCopy;  // yayinlanan gorunumun imzasi (kopyadan sonra degistiyse gozcu yeniden yayinlar)
  _publishedSig.rejSeq = rejAtCopy;
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

  if (length == 0 || length > (isSys ? MAX_SYS_PAYLOAD : MAX_CMD_PAYLOAD)) {
    printf("[MQTTS] Gecersiz yuk boyutu (%u bayt); yok sayildi.\r\n", length);
    if (isSys) memset(payload, 0, length);
    return;
  }

  if (isSys) {
    handleSys(payload, length);   // anahtar iceren yuk: loglanmaz, isi bitince sifirlanir
  } else {
    handleCommand(payload, length);
  }
}

// Komut reddi: kimligi (id) cozulebilen ve bu panoya ait (uid yok ya da eslesen) komut icin state.last_rej yazilir [O10]; istemci 30 sn
// beklemeden reddi gorur. uid uyusmazligi bilincli olarak SESSIZDIR (baska panonun komutu, spec 3.3).
void MqttManager::rejectCmd(const char* id, uint8_t rej) {
  safety::SafetyManager::instance().noteReject(id, (safety::Rej)rej);
  triggerPublish();
}

// sys cfg_patch kabulu (WP-C1, Faz 2 F2.D.6): rejectCmd'nin karsiligi. Yama loopTask komut kuyruguna girmedigi icin otomasyonun last_id'si
// degismez; bu yuzden kabul edilen id MQTT gorevinde tutulur ve otomasyonun son kimligi (kabul anindaki deger) degismedikce state.last_id
// olarak yazilir. Otomasyon daha yeni bir komut isleyince onun kimligi gecerli olur. Gecersiz/bos id: yalniz yayin tetigi.
void MqttManager::acceptCmd(const char* id) {
  if (id && id[0]) {
    AutomationSnapshot snap;
    if (SmartAutomation::instance().getSnapshot(snap)) {
      strncpy(_acceptBase, snap.lastId, sizeof(_acceptBase) - 1);
      _acceptBase[sizeof(_acceptBase) - 1] = '\0';
      strncpy(_acceptId, id, sizeof(_acceptId) - 1);
      _acceptId[sizeof(_acceptId) - 1] = '\0';
    }
  }
  triggerPublish();
}

void MqttManager::overlayAcceptedId(AutomationSnapshot& snap) {
  if (_acceptId[0] == '\0') return;
  if (strcmp(snap.lastId, _acceptBase) != 0) {   // otomasyon yeni bir komut isledi: kabul yankisi biter
    _acceptId[0] = _acceptBase[0] = '\0';
    return;
  }
  strncpy(snap.lastId, _acceptId, sizeof(snap.lastId) - 1);
  snap.lastId[sizeof(snap.lastId) - 1] = '\0';
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
  JsonObject root = doc.as<JsonObject>();

  // uid: ev konusu evdeki butun panolara gider; baska panonun komutu SESSIZCE yok sayilir (last_rej yazilmaz) [Y5].
  if (root.containsKey("uid")) {
    const char* u = root["uid"].is<const char*>() ? root["uid"].as<const char*>() : nullptr;
    if (!u || strcmp(u, _uid) != 0) return;
  }
  const char* rejId = (root["id"].is<const char*>() && validCommandId(root["id"].as<const char*>())) ? root["id"].as<const char*>() : "";

  uint8_t totalRelays;
  {
    ConfigManager::ConfigLock lk(ConfigManager::instance());
    totalRelays = ConfigManager::instance().config.totalRelays();
  }

  static ParsedCmd p;   // yalniz MqttTask (yigin degil)
  const char* reason = parseCommand(root, totalRelays, p);
  if (reason != nullptr) {
    printf("[MQTTS] Komut reddedildi: %s\r\n", reason);
    rejectCmd(rejId, (uint8_t)safety::Rej::BAD_CMD);
    return;
  }
  DeviceCommand& cmd = p.cmd;

  // uid'siz düz röle komutu (v:2 sözleşmesi) evdeki BÜTÜN panolara gider: röle numarası başka panonun lambasıyken bu panonun eylemci
  // rölesine (siren/vana) düşebilir. Eylemci rölesine gelen uid'siz düz komut SESSİZCE yok sayılır (kapatma yönü bile: çalan sireni
  // susturmasın); sunucu güvenlik destekli panoya düz röle komutunu uid ile gönderir (inceleme turu RV-2).
  if ((cmd.type == CmdType::RELAY_SET || cmd.type == CmdType::RELAY_TOGGLE) && !root.containsKey("uid") &&
      safety::SafetyManager::instance().isActuatorRelay(cmd.index)) {
    printf("[MQTTS] uid'siz role komutu eylemci rolesine (CH%u) geldi: yok sayildi.\r\n", (unsigned)cmd.index);
    return;
  }

  if (p.eventAck) {
    // Olay onayi (YALNIZ backend): eslesen eid'ler tampondan silinir; baska nonce'un (pano/acilis) eid'i eslesmez.
    auto& ob = safety::SafetyManager::instance().outbox();
    uint8_t k = 0;
    for (uint8_t i = 0; i < p.nEids; i++) if (ob.ack(p.eids[i])) k++;
    printf("[MQTTS] event_ack: %u/%u olay onaylandi.\r\n", (unsigned)k, (unsigned)p.nEids);
    return;
  }

  if (cmd.id[0] != '\0' && seenId(cmd.id)) {
    printf("[MQTTS] Tekrar eden komut kimligi yok sayildi (id: %s).\r\n", cmd.id);
    return;
  }

  if (!postDeviceCommand(cmd)) {
    // Kuyruk dolu: sessizce yutulmaz; id kaydedilmez (istemci ayni komutu yeniden deneyebilir)
    printf("[MQTTS] UYARI: komut kuyrugu dolu, komut dusuruldu (tip %d).\r\n", (int)cmd.type);
    rejectCmd(rejId, (uint8_t)safety::Rej::BUSY);
    return;
  }
  if (cmd.id[0] != '\0') rememberId(cmd.id);
  printf("[MQTTS] Komut kuyruga alindi (tip %d, indeks %u, deger %ld)\r\n", (int)cmd.type, (unsigned)cmd.index,
         (long)cmd.value);
  triggerPublish();   // sonucu (ve last_id'yi) bildirmek icin
}

// Yalnizca {"cmd":"set_local_key","local_key":"..."} (+ istege bagli "id"). Anahtar alani backend'in kullandigi "local_key"dir; "key" ayni
// anlamda takma ad olarak kabul edilir. (v1.1.x davranisi aynen.)
void MqttManager::handleSetLocalKey(JsonObject root) {
  const char* key = nullptr;
  for (JsonPair kv : root) {
    const char* k = kv.key().c_str();
    if (!strcmp(k, "cmd")) {
      // denetlendi
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

// sys konusu (yalniz backend yayinlar, CONTRACTS 2.2 ACL): {"cmd":"set_local_key"|"cfg_get"|"cfg_patch", ...}. Sinir 1024 bayt [D2][B11].
// cfg_*: "module":"safety" ve "uid" ZORUNLU (uid eslesmezse sessizce yok sayilir).
void MqttManager::handleSys(uint8_t* payload, unsigned int length) {
  DynamicJsonDocument doc(2048);
  const DeserializationError err = deserializeJson(doc, (const char*)payload, length);
  memset(payload, 0, length);   // anahtar PubSubClient arabelleginde kalmasin
  if (err || !doc.is<JsonObject>()) {
    printf("[MQTTS] sys yuku gecersiz.\r\n");
    return;
  }
  JsonObject root = doc.as<JsonObject>();
  if (!root["cmd"].is<const char*>()) {
    printf("[MQTTS] sys reddedildi: cmd metin olmali.\r\n");
    return;
  }
  const char* cmd = root["cmd"].as<const char*>();
  if (!strcmp(cmd, "set_local_key")) {
    handleSetLocalKey(root);
    return;
  }
  if (strcmp(cmd, "cfg_get") != 0 && strcmp(cmd, "cfg_patch") != 0) {
    printf("[MQTTS] sys reddedildi: bilinmeyen komut.\r\n");
    return;
  }
  const char* uid = root["uid"].is<const char*>() ? root["uid"].as<const char*>() : nullptr;
  if (!uid) {
    printf("[MQTTS] sys reddedildi: uid zorunlu.\r\n");
    return;
  }
  if (strcmp(uid, _uid) != 0) return;                  // baska panonun yamasi: sessiz
  if (!root["module"].is<const char*>() || strcmp(root["module"].as<const char*>(), "safety") != 0) {
    printf("[MQTTS] sys reddedildi: module \"safety\" olmali.\r\n");
    return;
  }
  const char* rejId = (root["id"].is<const char*>() && validCommandId(root["id"].as<const char*>())) ? root["id"].as<const char*>() : "";

  if (!strcmp(cmd, "cfg_get")) {
    for (JsonPair kv : root) {
      const char* k = kv.key().c_str();
      if (strcmp(k, "cmd") && strcmp(k, "module") && strcmp(k, "uid") && strcmp(k, "id")) {
        printf("[MQTTS] sys reddedildi: bilinmeyen alan.\r\n");
        return;
      }
    }
    publishCfgDump();
    return;
  }

  static safety::CfgEdit edit;
  bool hasBase = false;
  uint32_t baseRev = 0;
  const char* why = safety::parseCfgEdit(root, edit, hasBase, baseRev, true);
  if (why) {
    printf("[MQTTS] cfg_patch reddedildi: %s\r\n", why);
    rejectCmd(rejId, (uint8_t)safety::Rej::CFG_INVALID);
    return;
  }
  // Bulut yolu gevsetebilir (owner/servis yetkisi sunucuda denetlenir, karar 7.2b-7); cakismada pano kazanir (cfg_conflict olayi).
  // Gaz vanasini acilabilir kilan yama (gas_local_only) ve kurulu kipte hirsiz alarmini zayiflatan yama (armed) reddedilir (G-1).
  const safety::CfgOutcome o = safety::SafetyManager::instance().submitEdit(edit, hasBase, baseRev, safety::VIA_CLOUD);
  switch (o.r) {
    case safety::CfgResult::OK:
      printf("[MQTTS] cfg_patch uygulandi (rev %lu).\r\n", (unsigned long)o.rev);
      acceptCmd(rejId);                                 // state.last_id = id (sunucunun expectOutcome'u; WP-C1)
      break;
    case safety::CfgResult::CONFLICT:
      printf("[MQTTS] cfg_patch: base_rev %lu != rev %lu (cfg_conflict).\r\n", (unsigned long)baseRev, (unsigned long)o.rev);
      rejectCmd(rejId, (uint8_t)safety::Rej::CFG_CONFLICT);
      break;
    case safety::CfgResult::LATCHED:
      rejectCmd(rejId, (uint8_t)safety::Rej::ZONE_LATCHED);
      break;
    case safety::CfgResult::INVALID:
      printf("[MQTTS] cfg_patch gecersiz: %s\r\n", safety::cfgErrText(o.err));
      rejectCmd(rejId, (uint8_t)safety::Rej::CFG_INVALID);
      break;
    case safety::CfgResult::STORAGE:                   // NVS payi yetmedi (inceleme RV-3): eskiden "busy" (WP-C1)
      rejectCmd(rejId, (uint8_t)safety::Rej::CFG_STORAGE);
      break;
    case safety::CfgResult::GAS_LOCAL:                 // gaz vanasini uzaktan acilabilir kilardi (Faz 2 incelemesi G-1a)
      printf("[MQTTS] cfg_patch reddedildi: gaz vanasi yalniz yerinde degistirilebilir.\r\n");
      rejectCmd(rejId, (uint8_t)safety::Rej::GAS_LOCAL_ONLY);
      break;
    case safety::CfgResult::ARMED:                     // kurulu kipte hirsiz alarmini zayiflatirdi (G-1b)
      printf("[MQTTS] cfg_patch reddedildi: alarm kurulu.\r\n");
      rejectCmd(rejId, (uint8_t)safety::Rej::ARMED);
      break;
    default:
      rejectCmd(rejId, (uint8_t)safety::Rej::BUSY);
      break;
  }
}

// ============================================================================
// ev/{t}/event (spec 3.4): uygulama duzeyinde onayli teslim. Her 50 ms'de en cok bir olay; onay (event_ack) gelmezse 5/10/20/40/60 sn
// sonra yeniden denenir. Abonelikten sonraki ilk 1500 ms'de bosaltilmaz [D4]. Kilit altinda yalniz JSON kopyalanir; yayin kilit DISINDA.
// ============================================================================
void MqttManager::publishEventsIfDue(uint32_t now) {
  if (_topicEvent[0] == '\0') return;
  auto& sm = safety::SafetyManager::instance();
  auto& ob = sm.outbox();
  static char buf[safety::EVENT_JSON_MAX];
  size_t len = 0;
  {
    safety::EventOutboxRtos::Guard g(ob, pdMS_TO_TICKS(10));
    if (!g.ok()) return;
    const int slot = ob.box().nextDue(now, _connectedAt);
    if (slot < 0) return;
    len = ob.box().toJson(slot, _uid, sm.bootCount(), buf, sizeof(buf));
    if (len == 0) {
      char eid[safety::EID_LEN];
      ob.box().eidOf(slot, eid);
      ob.box().ack(eid);                               // sigmayan olay sonsuza dek yinelenmesin (state uzlastirmasi telafi eder)
      printf("[MQTTS] UYARI: olay JSON'u sigmadi, atildi (%s).\r\n", eid);
      return;
    }
    ob.box().markSent(slot, now);
  }
  const size_t need = MQTT_MAX_HEADER_SIZE + 2 + strlen(_topicEvent) + len;
  if (_mqttClient.getBufferSize() < need && !_mqttClient.setBufferSize((uint16_t)need)) return;
  if (!_mqttClient.publish(_topicEvent, (const uint8_t*)buf, (unsigned int)len, false)) {   // retain YOK
    printf("[MQTTS] Olay yayinlanamadi (yeniden denenecek).\r\n");
  }
}

// cfg_dump (spec 4.2 [Y6][B11]): outbox DISINDA, onaysiz, ev/{t}/event konusunda type:"cfg_dump" zarfiyla, her parca <= 3,5 KB.
// Kaybolan parca sunucunun cfg_get'i yinelemesiyle telafi edilir.
void MqttManager::publishCfgDump() {
  if (_topicEvent[0] == '\0') return;
  safety::SafetyConfig* cp = (safety::SafetyConfig*)malloc(sizeof(safety::SafetyConfig));   // ~2,5 KB yalniz dokum suresince
  char* buf = (char*)malloc(safety::DUMP_PART_CAP + 1);
  if (!cp || !buf || !safety::SafetyManager::instance().copyConfig(*cp)) {
    free(cp);
    free(buf);
    printf("[MQTTS] cfg_dump: bellek yok.\r\n");
    return;
  }
  const safety::SafetyConfig& c = *cp;
  safety::DumpPart parts[safety::DUMP_MAX_PARTS];
  const uint8_t n = safety::planDump(c, safety::DUMP_PART_CAP, parts, safety::DUMP_MAX_PARTS, buf, safety::DUMP_PART_CAP + 1);
  if (n == 0) {
    free(buf);
    free(cp);
    printf("[MQTTS] cfg_dump: parca plani olusturulamadi.\r\n");
    return;
  }
  for (uint8_t k = 0; k < n; k++) {
    const size_t len = safety::writeDumpPart(c, parts[k], (uint8_t)(k + 1), n, _uid, buf, safety::DUMP_PART_CAP + 1);
    if (len == 0) break;
    const size_t need = MQTT_MAX_HEADER_SIZE + 2 + strlen(_topicEvent) + len;
    if (_mqttClient.getBufferSize() < need && !_mqttClient.setBufferSize((uint16_t)need)) break;
    if (!_mqttClient.publish(_topicEvent, (const uint8_t*)buf, (unsigned int)len, false)) break;
  }
  printf("[MQTTS] cfg_dump yayinlandi (%u parca, rev %lu).\r\n", (unsigned)n, (unsigned long)c.rev);
  free(buf);
  free(cp);
}
