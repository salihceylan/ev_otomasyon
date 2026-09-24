#include "MqttManager.h"
#include "ConfigManager.h"
#include "SmartAutomation.h"
#include "WiFiManager.h"

MqttManager& MqttManager::instance() {
  static MqttManager inst;
  return inst;
}

MqttManager::MqttManager()
    : _taskHandle(nullptr),
      _mutex(nullptr),
      _connected(false),
      _lastPublish(0),
      _lastConnectAttempt(0),
      _needPublish(false) {}

void MqttManager::begin() {
  _mutex = xSemaphoreCreateMutex();

  auto& cfg = ConfigManager::instance().config;

  // TLS 1.3 / SSL Güvenlik Yapılandırması
  _secureClient.setInsecure(); // Let's Encrypt sertifikasını doğrula (90 günlük yenilemelerde gömülü flash sertifika eskimesi yaşanmaz)
  _secureClient.setTimeout(5); // 5 saniye ağ zaman aşımı

  String userStr = cfg.mqtt_user;
  userStr.trim();
  if (userStr.isEmpty()) userStr = "home_101";

  _topicStatus = "ev/" + userStr + "/status";
  _topicState = "ev/" + userStr + "/state";
  _topicCmd = "ev/" + userStr + "/cmd";

  String macClean = WiFiManager::instance().getMacAddress();
  macClean.replace(":", "");
  _clientId = "ESP32S3_" + macClean;

  _mqttClient.setClient(_secureClient);
  _mqttClient.setServer(cfg.mqtt_server, cfg.mqtt_port);
  _mqttClient.setBufferSize(2048);
  _mqttClient.setKeepAlive(30);

  _mqttClient.setCallback([](char* topic, byte* payload, unsigned int length) {
    MqttManager::instance().onMessage(topic, payload, length);
  });

  // MQTTS görevini Core 0'a sabitle (Röle/Panjur motorunu asla bloklamaz)
  xTaskCreatePinnedToCore(mqttTask, "MqttTask", 8192, this, 1, &_taskHandle, 0);

  printf("[MQTTS] Guvenli MQTT Yoneticisi Baslatildi (Core 0, Hedef: %s:%d, Daire: %s)\r\n",
         cfg.mqtt_server, cfg.mqtt_port, userStr.c_str());
}

bool MqttManager::isConnected() {
  if (_mutex && xSemaphoreTake(_mutex, pdMS_TO_TICKS(10)) == pdTRUE) {
    bool st = _connected;
    xSemaphoreGive(_mutex);
    return st;
  }
  return _connected;
}

void MqttManager::triggerPublish() {
  _needPublish = true;
}

String MqttManager::getServer() {
  return String(ConfigManager::instance().config.mqtt_server);
}

uint16_t MqttManager::getPort() {
  return ConfigManager::instance().config.mqtt_port;
}

String MqttManager::getUsername() {
  return String(ConfigManager::instance().config.mqtt_user);
}

String MqttManager::getStatusTopic() {
  return _topicStatus;
}

String MqttManager::getStateTopic() {
  return _topicState;
}

String MqttManager::getCmdTopic() {
  return _topicCmd;
}

void MqttManager::mqttTask(void* parameter) {
  MqttManager* self = static_cast<MqttManager*>(parameter);

  for (;;) {
    bool wifiOk = WiFiManager::instance().isConnected();

    if (wifiOk && ConfigManager::instance().config.mqtt_enabled) {
      if (!self->_mqttClient.connected()) {
        if (self->_connected) {
          if (self->_mutex && xSemaphoreTake(self->_mutex, pdMS_TO_TICKS(50)) == pdTRUE) {
            self->_connected = false;
            xSemaphoreGive(self->_mutex);
          }
          printf("[MQTTS] Broker baglantisi koptu!\r\n");
        }

        uint32_t now = millis();
        if (now - self->_lastConnectAttempt >= 5000) {
          self->_lastConnectAttempt = now;
          self->connectToBroker();
        }
      } else {
        self->_mqttClient.loop();

        uint32_t now = millis();
        if (self->_needPublish || (now - self->_lastPublish >= 30000)) {
          self->publishStateInternal();
        }
      }
    } else {
      if (self->_connected) {
        if (self->_mutex && xSemaphoreTake(self->_mutex, pdMS_TO_TICKS(50)) == pdTRUE) {
          self->_connected = false;
          xSemaphoreGive(self->_mutex);
        }
      }
    }

    vTaskDelay(pdMS_TO_TICKS(50));
  }
}

void MqttManager::connectToBroker() {
  auto& cfg = ConfigManager::instance().config;

  printf("[MQTTS] %s:%d baglaniliyor (Kullanici: %s, Client: %s)...\r\n",
         cfg.mqtt_server, cfg.mqtt_port, cfg.mqtt_user, _clientId.c_str());

  // LWT (Last Will and Testament): Broker elektrik kesintisi veya kopma anında bu mesajı yayınlar
  bool ok = _mqttClient.connect(
      _clientId.c_str(),
      cfg.mqtt_user,
      cfg.mqtt_pass,
      _topicStatus.c_str(),
      1,     // QoS 1
      true,  // Retain
      "offline");

  if (ok) {
    if (_mutex && xSemaphoreTake(_mutex, pdMS_TO_TICKS(50)) == pdTRUE) {
      _connected = true;
      xSemaphoreGive(_mutex);
    }

    printf("[MQTTS] Baglanti BASARILI (TLS 1.3 / Port %d)!\r\n", cfg.mqtt_port);

    // Çevrimiçi durumunu retain olarak yayınla
    _mqttClient.publish(_topicStatus.c_str(), "online", true);

    // Komut konusuna abone ol
    _mqttClient.subscribe(_topicCmd.c_str(), 1);
    printf("[MQTTS] Komut kanali dinleniyor: %s\r\n", _topicCmd.c_str());

    // İlk tam durum raporunu yayınla
    publishStateInternal();
  } else {
    printf("[MQTTS] Baglanti basarisiz! Hata Kodu: %d\r\n", _mqttClient.state());
  }
}

void MqttManager::publishStateInternal() {
  if (!_mqttClient.connected()) return;

  DynamicJsonDocument doc(2048);
  auto& cfg = ConfigManager::instance().config;
  auto& autoMgr = SmartAutomation::instance();

  doc["device"] = cfg.device_name;
  doc["mac"] = WiFiManager::instance().getMacAddress();
  doc["ip"] = WiFiManager::instance().getLocalIP().toString();
  doc["rssi"] = WiFiManager::instance().getRSSI();
  doc["uptime"] = WiFiManager::instance().getUptimeSeconds();
  doc["child_lock"] = autoMgr.isChildLockEnabled();

  uint8_t totalR = cfg.totalRelays();
  JsonArray rArr = doc.createNestedArray("relays");
  for (int i = 0; i < totalR; i++) {
    JsonObject r = rArr.createNestedObject();
    r["id"] = i + 1;
    r["name"] = cfg.relays[i].name;
    r["type"] = cfg.relays[i].type;
    r["state"] = autoMgr.getRelayState(i);
  }

  uint8_t totalPairs = totalR / 2;
  JsonArray sArr = doc.createNestedArray("shutters");
  for (int p = 0; p < totalPairs; p++) {
    JsonObject s = sArr.createNestedObject();
    ShutterState st = autoMgr.getShutterState(p);
    s["pair"] = p + 1;
    s["pos"] = st.current_position;
    s["moving"] = st.is_moving;
    s["dir"] = st.direction;
    s["target"] = st.target_position;
  }

  uint8_t totalD = cfg.totalDIs();
  JsonArray dArr = doc.createNestedArray("dis");
  for (int i = 0; i < totalD; i++) {
    JsonObject d = dArr.createNestedObject();
    d["id"] = i + 1;
    d["name"] = cfg.dis[i].name;
    d["state"] = autoMgr.getDIState(i);
  }

  String output;
  serializeJson(doc, output);

  bool pubOk = _mqttClient.publish(_topicState.c_str(), output.c_str(), true); // Retain = true
  if (pubOk) {
    _lastPublish = millis();
    _needPublish = false;
    printf("[MQTTS] Durum raporu yayinlandi (%s, %d bayt)\r\n", _topicState.c_str(), output.length());
  } else {
    printf("[MQTTS] Durum raporu yayinlanamadi!\r\n");
  }
}

void MqttManager::onMessage(char* topic, byte* payload, unsigned int length) {
  String msg;
  msg.reserve(length);
  for (unsigned int i = 0; i < length; i++) {
    msg += (char)payload[i];
  }

  printf("[MQTTS] Komut alindi [%s]: %s\r\n", topic, msg.c_str());

  DynamicJsonDocument doc(1024);
  DeserializationError err = deserializeJson(doc, msg);
  if (err) {
    printf("[MQTTS] JSON parse hatasi: %s\r\n", err.c_str());
    return;
  }

  auto& autoMgr = SmartAutomation::instance();

  // 1. Röle Kontrolü
  if (doc.containsKey("relay")) {
    int rNum = doc["relay"];
    if (rNum >= 1 && rNum <= ConfigManager::instance().config.totalRelays()) {
      uint8_t rIdx = rNum - 1;
      if (doc.containsKey("cmd") && doc["cmd"] == "toggle") {
        autoMgr.toggleRelay(rIdx);
      } else if (doc.containsKey("state")) {
        bool st = doc["state"].as<bool>();
        autoMgr.setRelayState(rIdx, st);
      }
      _needPublish = true;
      return;
    }
  }

  // 2. Panjur Kontrolü
  if (doc.containsKey("shutter")) {
    int pNum = doc["shutter"];
    if (pNum >= 1 && pNum <= (ConfigManager::instance().config.totalRelays() / 2)) {
      uint8_t pIdx = pNum - 1;
      if (doc.containsKey("pos")) {
        int pos = doc["pos"];
        autoMgr.setShutterPosition(pIdx, (uint8_t)pos);
      } else if (doc.containsKey("cmd")) {
        String c = doc["cmd"].as<String>();
        if (c == "up") autoMgr.shutterUp(pIdx);
        else if (c == "down") autoMgr.shutterDown(pIdx);
        else if (c == "stop") autoMgr.shutterStop(pIdx);
        else if (c == "step") autoMgr.shutterStep(pIdx);
      }
      _needPublish = true;
      return;
    }
  }

  // 3. Genel Toplu Komutlar
  if (doc.containsKey("cmd")) {
    String c = doc["cmd"].as<String>();
    if (c == "all_off" || c == "all_lights_off") {
      autoMgr.allLightsOff();
    } else if (c == "all_shutters_up") {
      autoMgr.allShuttersUp();
    } else if (c == "all_shutters_down") {
      autoMgr.allShuttersDown();
    } else if (c == "all_shutters_stop") {
      autoMgr.allShuttersStop();
    } else if (c == "set_child_lock") {
      bool enabled = doc["enabled"] | doc["child_lock"] | false;
      autoMgr.setChildLock(enabled);
    }
    _needPublish = true;
    return;
  }
}

