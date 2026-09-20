#pragma once
#include <Arduino.h>
#include <Preferences.h>

enum RelayType {
  RELAY_TYPE_LIGHT = 0,       // Normal lamba / aç-kapa cihaz
  RELAY_TYPE_SHUTTER_UP = 1,  // Panjur Yukarı (Interlock partner ile eşleşir)
  RELAY_TYPE_SHUTTER_DOWN = 2,// Panjur Aşağı (Interlock partner ile eşleşir)
  RELAY_TYPE_IMPULSE = 3      // Darbe rölesi (Belirli süre çekip bırakır, örn: kilit/otomatik)
};

enum DIMode {
  DI_MODE_TOGGLE = 0,         // Her basışta röle durumunu tersine çevir
  DI_MODE_MOMENTARY = 1,      // Butona basılıyken açık, bırakınca kapalı
  DI_MODE_SHUTTER_STEP = 2,   // Panjur butonu: Basınca hareket ettir/durdur (Tek buton döngü)
  DI_MODE_SHUTTER_UP = 3,     // Panjur Yukarı: Basınca Aç, basınca Durdur
  DI_MODE_SHUTTER_DOWN = 4    // Panjur Aşağı: Basınca Kapat, basınca Durdur
};

struct RelayConfig {
  char name[32];
  uint8_t type;               // RelayType
  uint16_t runtime_sec;       // Panjur için hareket süresi (sn) veya darbe süresi (ms)
};

struct DIConfig {
  char name[32];
  uint8_t target_relay;       // 1-8 (0 = devre dışı)
  uint8_t mode;               // DIMode
};

#define MAX_TOTAL_RELAYS 40
#define MAX_TOTAL_DIS    40

struct SystemConfig {
  char device_name[32];
  char wifi_ssid[64];
  char wifi_pass[64];
  bool wifi_sta_enabled;
  uint32_t rs485_baud;

  // Harici Genişletme Modülü (RS485)
  bool ext_module_enabled;       // Ek modül var mı?
  uint8_t ext_module_channels;   // Kaç kanallı? (0, 2, 4, 8, 12, 16, 24, 32)
  uint8_t ext_module_address;    // Modbus Slave Adresi (1..247, varsayılan 1)

  RelayConfig relays[MAX_TOTAL_RELAYS];
  DIConfig dis[MAX_TOTAL_DIS];

  uint8_t totalRelays() const {
    if (!ext_module_enabled) return 8;
    uint8_t t = 8 + ext_module_channels;
    return (t > MAX_TOTAL_RELAYS) ? MAX_TOTAL_RELAYS : t;
  }

  uint8_t totalDIs() const {
    if (!ext_module_enabled) return 8;
    uint8_t t = 8 + ext_module_channels;
    return (t > MAX_TOTAL_DIS) ? MAX_TOTAL_DIS : t;
  }
};

class ConfigManager {
public:
  static ConfigManager& instance();
  void begin();
  void load();
  void save();
  void resetToDefaults();

  SystemConfig config;

private:
  ConfigManager();
  Preferences prefs;
};

