#pragma once
#include <Arduino.h>
#include <Preferences.h>
#include <freertos/FreeRTOS.h>
#include <freertos/semphr.h>

#include "SystemConfig.h"   // RelayType, DIMode, RelayConfig, DIConfig, SystemConfig, sabitler, validate()

class ConfigManager {
public:
  static ConfigManager& instance();
  void begin();
  void load();
  // Tüm alanları NVS'e yazar (önce validate()). false = en az bir yazma başarısız oldu.
  // Değişmeyen anahtarlar NVS'e YAZILMAZ (uygulama katmanında karşılaştırılır; IDF'in özdeş değeri atlayıp atlamadığına
  // güvenilmez): yalnızca değişen değerler flash'a yazılır. Yine de nadir değişiklikte çağırın.
  bool save();
  // Uygulama ayarlarını varsayılana çeker ve NVS'teki uygulama anahtarlarını (ek modül dahil) ile
  // "ahbu_auto"/"ahbu_pos" ad alanlarını SİLER. Kimlik/provizyon alanları (local_key, ap_pass, MQTT
  // sunucu/kimlik) KORUNUR: uzaktan "sıfırla" cihazı sahipsiz bırakmamalı (fiziksel RESETKEY ayrı).
  bool resetToDefaults();

  SystemConfig config;

  // ---- Kimlik/provizyon (FW-net) -------------------------------------------------------------
  bool hasLocalKey() const { return config.hasLocalKey(); }
  bool hasMqttCredentials() const { return config.hasMqttCredentials(); }
  // RAM'e yazar VE NVS'e kalıcılaştırır. Geçersiz giriş => false, hiçbir şey değişmez.
  bool setLocalKey(const char* key);
  bool setApPass(const char* pass);
  // Fiziksel erişimle kurtarma (seri CLI "RESETKEY"): yerel anahtarı siler.
  bool clearLocalKey();
  // MQTT kimliğini yazar (POST /api/mqtt/config). Alan uzunlukları doğrulanır; false = reddedildi.
  bool setMqttCredentials(const char* server, uint16_t port, const char* user, const char* pass);
  // Yalnız bir rölenin süresini kalıcılaştırır (SET_RUNTIME; tüm yapılandırmayı yeniden yazmaz).
  bool saveRelayRuntime(uint8_t relayIndex);

  bool validate() { ConfigLock l(*this); return config.validate(); }

  // Çok görevli erişim: config'i okuyup yazan görevler tutarlılık gerekiyorsa kilit alır (özyinelemeli).
  struct ConfigLock {
    explicit ConfigLock(ConfigManager& m) : _m(m) { _m.lock(); }
    ~ConfigLock() { _m.unlock(); }
    ConfigManager& _m;
  };
  void lock();
  void unlock();

  // save() her çağrıda artar: tüketici (ör. SmartAutomation) yapılandırma değişimini fark edebilir.
  uint32_t generation() const { return _generation; }
  // resetToDefaults() her çağrıldığında artar: SmartAutomation bunu görünce RAM'deki çocuk kilidini de sıfırlar.
  uint32_t resetCount() const { return _resetCount; }
  bool nvsReady() const { return _prefsOk; }

private:
  ConfigManager();
  void applyDefaults();
  bool eraseAppKeys();
  Preferences prefs;
  SemaphoreHandle_t _mutex;
  bool _prefsOk;
  volatile uint32_t _generation;
  volatile uint32_t _resetCount;
};
