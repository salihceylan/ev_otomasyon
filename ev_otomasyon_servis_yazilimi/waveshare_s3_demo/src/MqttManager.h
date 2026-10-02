#pragma once

#include <Arduino.h>
#include <WiFiClientSecure.h>
#include <PubSubClient.h>
#include <ArduinoJson.h>
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>
#include <freertos/semphr.h>
#include "NetTime.h"

// ============================================================================
// MqttManager - Bulut (EMQX) MQTTS istemcisi (docs/CONTRACTS.md Bolum 2).
//
//  * Sertifika dogrulamasi ACIK: CaCerts.h'deki ISRG kok sertifikalari (setInsecure YOK) ve
//    saat senkronu (SNTP) olmadan TLS baglantisi denenmez.
//  * Kimlik (sunucu/kullanici/parola) derlemeye gomulu degildir; ConfigManager'dan (POST
//    /api/mqtt/config ile yazilir) okunur. Kimlik yoksa MQTT baslamaz, cihaz yerelde calisir.
//  * Konular: ev/{t}/state, ev/{t}/status (yayin) ; ev/{t}/cmd, ev/{t}/sys (abonelik).
//    {t} = kullanici adindan "d_" oneki atilmis ev konu kimligi.
//  * onMessage YALNIZCA dogrular ve postDeviceCommand() ile kuyruga yazar (Core 1 uygular).
//  * Gorev Core 0'dadir (rolenin/panjurun gerçek zamanli dongusunu bloklamaz).
// ============================================================================
class MqttManager {
public:
  static MqttManager& instance();

  void begin();
  bool isConnected();
  void triggerPublish();

  // /api/mqtt/config sonrasi: kimlik/sunucu degisti, yeni degerlerle yeniden baglan.
  void reconfigure();
  // MQTT kimligi var mi ve etkin mi (baglanmayi deneyebilir mi)?
  bool isConfigured();
  // Planli yeniden baslatma oncesi cagrilir (SmartAutomation on-yeniden-baslatma kancasi):
  // "offline" durumunu yayinlar ve baglantiyi temiz kapatir (LWT yalnizca ani kopmada tetiklenir).
  void prepareForRestart();

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
  static void preRestartHook();
  void taskLoop();
  void applyConfig();
  bool tryConnect();
  void dropConnection(const char* why, bool sendDisconnect);
  void scheduleRetry(bool longWait);
  void publishIfDue(uint32_t now);
  bool publishState();
  bool publishStatus(const char* text);
  void onMessage(char* topic, byte* payload, unsigned int length);
  void handleCommand(const uint8_t* payload, unsigned int length);
  void handleSys(uint8_t* payload, unsigned int length);
  bool leafCertificateValid();
  void watchStateChanges(uint32_t now);
  bool rememberId(const char* id);
  bool seenId(const char* id) const;

  WiFiClientSecure _secureClient;
  PubSubClient _mqttClient;
  TaskHandle_t _taskHandle;
  SemaphoreHandle_t _mutex;

  // ---- Bayraklar (Core 0 <-> Core 1) ----
  volatile bool _connected;
  volatile bool _needPublish;            // baska gorevlerin kurdugu yayin istegi (zaman damgasi TASIMAZ)
  volatile bool _reconfigPending;
  volatile bool _shutdownRequested;
  volatile bool _shutdownDone;
  volatile bool _halted;                 // planli yeniden baslatma: yeniden baglanma yok

  // ---- Zamanlayicilar (N6: "son olay + bekleme" ciftleri, NetTime.h; yalniz MQTT gorevi degistirir, her tur yoklanir) ----
  NetUtil::PublishPacer _pace;           // 250 ms birlestirme, 30 sn kalp atisi, hata sonrasi ustel bekleme
  NetUtil::ReconnectBackoff _reconnect;  // yeniden baglanma 5 -> 300 sn (+-%20 jitter)
  NetUtil::Wait _ignore;                 // cmd/sys aboneliginden sonraki 1500 ms "retained yok say" penceresi
  NetUtil::Wait _noTimeLog;              // "saat senkronu yok" log siniri (30 sn)
  NetUtil::Wait _watermark;              // yigin izleme logu (5 dk)
  NetUtil::Wait _sigCheck;               // durum gozcusu: 100 ms'de bir

  uint32_t _seq;
  bool _noCredLogged;

  // ---- Yapilandirma kopyasi (gorev baglami; getter'lar _mutex ile okur) ----
  bool _haveCreds;
  bool _enabled;
  char _server[64];
  uint16_t _port;
  char _user[48];
  char _pass[64];
  char _topicId[48];
  char _topicStatus[72];
  char _topicState[72];
  char _topicCmd[72];
  char _topicSys[72];
  char _clientId[32];
  char _uid[24];

  // ---- Durum degisikligi gozcusu: en son YAYINLANAN durumun imzasi ----
  // Anlik goruntu imzasi yayinlanandan farkliysa (kilit, role, DI, panjur hareketi, last_id...) bir yayin
  // tetiklenir; tetikleyici kimin cagirdigindan bagimsiz oldugundan retained "state" 30 sn bayat kalmaz.
  // Panjur KONUMU (pos) imzaya girmez: hareket sirasinda saniyede onlarca degisim yayin firtinasi olmasin.
  struct StateSignature {
    uint64_t relayMask;
    uint64_t diMask;
    bool childLock;
    uint8_t totalRelays;
    uint8_t totalDIs;
    uint8_t shutter[20];      // moving | dir<<1 | waiting<<3 | configured<<4
    uint8_t shutterTarget[20];
    char lastId[25];
  };
  StateSignature _publishedSig;
  bool _publishedSigValid;

  // ---- Komut kimligi (id) tekilleştirme: son 8 ----
  char _recentIds[8][25];
  uint8_t _recentHead;
};
