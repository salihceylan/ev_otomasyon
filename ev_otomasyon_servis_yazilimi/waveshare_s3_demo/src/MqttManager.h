#pragma once

#include <Arduino.h>
#include <WiFiClientSecure.h>
#include <PubSubClient.h>
#include <ArduinoJson.h>
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>
#include <freertos/semphr.h>

class MqttManager {
public:
  static MqttManager& instance();

  void begin();
  bool isConnected();
  void triggerPublish();

  // CLI ve Telemetri Bilgileri
  String getServer();
  uint16_t getPort();
  String getUsername();
  String getStatusTopic();
  String getStateTopic();
  String getCmdTopic();

private:
  MqttManager();
  ~MqttManager() = default;
  MqttManager(const MqttManager&) = delete;
  MqttManager& operator=(const MqttManager&) = delete;

  static void mqttTask(void* parameter);
  void connectToBroker();
  void onMessage(char* topic, byte* payload, unsigned int length);
  void publishStateInternal();

  WiFiClientSecure _secureClient;
  PubSubClient _mqttClient;
  TaskHandle_t _taskHandle;
  SemaphoreHandle_t _mutex;

  bool _connected;
  uint32_t _lastPublish;
  uint32_t _lastConnectAttempt;
  volatile bool _needPublish;

  String _topicStatus;
  String _topicState;
  String _topicCmd;
  String _clientId;
};

