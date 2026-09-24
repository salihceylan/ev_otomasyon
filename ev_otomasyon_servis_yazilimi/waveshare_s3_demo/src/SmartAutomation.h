#pragma once
#include <Arduino.h>
#include "ConfigManager.h"

struct ShutterState {
  bool is_moving;
  uint8_t direction;         // 1: Up, 2: Down, 0: Stopped
  uint8_t last_direction;    // 1: Up, 2: Down
  uint32_t start_time;
  uint32_t duration_ms;
  uint8_t pending_direction; // 0: None, 1: Pending Up, 2: Pending Down (Dead-time bekleme)
  uint32_t dead_time_start;  // ms timestamp: yön kesilme anı
  uint8_t current_position;  // 0-100 (%) (0: Tam Kapalı, 100: Tam Açık)
  uint8_t target_position;   // 0-100 (%) (255: Hedefsiz tam hareket)
  uint8_t start_position;    // Hareket başlangıcındaki anlık pozisyon (%)
};

static constexpr uint32_t SHUTTER_DEAD_TIME_MS = 500; // Endüstriyel 500 ms ölü zaman emniyeti
static constexpr uint32_t SHUTTER_OVERRUN_MS = 2000;  // ADIM 15: %0 veya %100 uç noktalarında mekanik limit oturması ve self-healing için +2 sn (2000 ms) ilave süre

class SmartAutomation {
public:
  static SmartAutomation& instance();
  void begin();
  void loop();

  // Röle Kontrolleri
  bool getRelayState(uint8_t relayIndex); // 0-7
  void setRelayState(uint8_t relayIndex, bool state);
  void toggleRelay(uint8_t relayIndex);

  // Panjur Kontrolleri (pairIndex: 0 => Röle 1-2, 1 => Röle 3-4, 2 => Röle 5-6, 3 => Röle 7-8)
  void shutterUp(uint8_t pairIndex);
  void shutterDown(uint8_t pairIndex);
  void shutterStop(uint8_t pairIndex);
  void shutterStep(uint8_t pairIndex);
  ShutterState getShutterState(uint8_t pairIndex);

  // Panjur Pozisyon Yönetimi (%0 - %100)
  void setShutterPosition(uint8_t pairIndex, uint8_t targetPercent);
  uint8_t getShutterPosition(uint8_t pairIndex);

  // Toplu Eylemler
  void allLightsOff();
  void allShuttersDown();
  void allShuttersUp();
  void allShuttersStop();

  // Giriş (DI) Durumları (0-7: true=Tetiklendi/Kapalı kontak, false=Açık)
  bool getDIState(uint8_t diIndex);

  // ADIM 17: Yazılımsal Çocuk Kilidi (Fiziksel Duvar Anahtarlarını Kilitler)
  void setChildLock(bool enabled);
  bool isChildLockEnabled() const { return _childLockEnabled; }

  // RS485 Haberleşme & Harici Modül Yönetimi
  struct Rs485ScanResult {
    bool found;
    uint8_t slaveId;
    uint32_t baud;
    uint8_t relayStatus; // Coils byte
    String rawHex;
    String info;
  };

  void rs485Begin(uint32_t baud);
  bool rs485Send(const String& data, bool isHex);
  String rs485GetLogs();
  void rs485ClearLogs();
  Rs485ScanResult rs485ScanModule(uint32_t specificBaud = 0);
  bool rs485ControlExtRelay(uint8_t slaveId, uint8_t channel, uint8_t action, String* responseHex = nullptr);

  bool isExtModuleResponding() const { return _extModuleResponding; }
  bool rs485Transaction(const uint8_t *txBuf, size_t txLen, uint8_t *rxBuf, size_t maxRxLen, size_t &rxLen, uint32_t timeoutMs = 120);

private:
  SmartAutomation();
  bool _relayStates[MAX_TOTAL_RELAYS];
  bool _diStates[MAX_TOTAL_DIS];
  bool _childLockEnabled;
  uint32_t _diLastPressTime[MAX_TOTAL_DIS];
  uint32_t _impulseEndTime[MAX_TOTAL_RELAYS];
  ShutterState _shutters[MAX_TOTAL_RELAYS / 2];

  // RS485 FreeRTOS Mutex & Dairesel Log Tamponu
  SemaphoreHandle_t _rs485Mutex;
  static const int RS485_LOG_MAX = 25;
  String _rs485Logs[RS485_LOG_MAX];
  int _rs485LogCount;

  void addRs485Log(const String& line);
  void checkShutterTimers();
  void checkImpulseTimers();
  void checkDigitalInputs();
  void checkRs485Incoming();
  void pollExtModule();
  void applyPhysicalRelay(uint8_t relayIndex, bool state);

  void updateShutterPosition(uint8_t pairIndex);
  void saveShutterPosition(uint8_t pairIndex);
  void loadShutterPositions();

  uint32_t _lastExtModulePoll;
  uint32_t _lastExtCoilPoll;
  bool _extModuleResponding;
};


