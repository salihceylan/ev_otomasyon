#pragma once
#include <Arduino.h>
#include "ConfigManager.h"

struct ShutterState {
  bool is_moving;
  uint8_t direction; // 1: Up, 2: Down, 0: Stopped
  uint8_t last_direction; // 1: Up, 2: Down
  uint32_t start_time;
  uint32_t duration_ms;
};

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

  // Toplu Eylemler
  void allLightsOff();
  void allShuttersDown();
  void allShuttersUp();
  void allShuttersStop();

  // Giriş (DI) Durumları (0-7: true=Tetiklendi/Kapalı kontak, false=Açık)
  bool getDIState(uint8_t diIndex);

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

private:
  SmartAutomation();
  bool _relayStates[MAX_TOTAL_RELAYS];
  bool _diStates[MAX_TOTAL_DIS];
  uint32_t _diLastPressTime[MAX_TOTAL_DIS];
  uint32_t _impulseEndTime[MAX_TOTAL_RELAYS];
  ShutterState _shutters[MAX_TOTAL_RELAYS / 2];

  // RS485 Dairesel Log Tamponu
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

  uint32_t _lastExtModulePoll;
  uint32_t _lastExtCoilPoll;
  bool _extModuleResponding;
};

