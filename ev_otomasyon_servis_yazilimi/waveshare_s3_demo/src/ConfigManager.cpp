#include "ConfigManager.h"
#include <string.h>

ConfigManager& ConfigManager::instance() {
  static ConfigManager mgr;
  return mgr;
}

ConfigManager::ConfigManager() {
  resetToDefaults();
}

void ConfigManager::resetToDefaults() {
  strncpy(config.device_name, "AHBU Akilli Ev Kontrol", sizeof(config.device_name) - 1);
  config.device_name[sizeof(config.device_name) - 1] = '\0';
  config.wifi_ssid[0] = '\0';
  config.wifi_pass[0] = '\0';
  config.wifi_sta_enabled = false;
  config.rs485_baud = 9600;

  // Ek Genişletme Modülü Varsayılanları
  config.ext_module_enabled = false;
  config.ext_module_channels = 0;
  config.ext_module_address = 1;

  // Varsayılan Röle Tanımları:
  // 1-2: Salon Panjuru (Yukarı & Aşağı)
  // 3-4: Yatak Odası Panjuru (Yukarı & Aşağı)
  // 5-8: Aydınlatmalar (Salon, Mutfak, Koridor, Balkon)
  const char* defaultRelayNames[8] = {
    "Salon Panjur (Yukari)",
    "Salon Panjur (Asagi)",
    "Oda Panjur (Yukari)",
    "Oda Panjur (Asagi)",
    "Salon Aydinlatma",
    "Mutfak Aydinlatma",
    "Koridor Aydinlatma",
    "Balkon Aydinlatma"
  };

  for (int i = 0; i < MAX_TOTAL_RELAYS; i++) {
    if (i < 8) {
      strncpy(config.relays[i].name, defaultRelayNames[i], sizeof(config.relays[i].name) - 1);
      config.relays[i].name[sizeof(config.relays[i].name) - 1] = '\0';
      if (i == 0 || i == 2) {
        config.relays[i].type = RELAY_TYPE_SHUTTER_UP;
        config.relays[i].runtime_sec = 20;
      } else if (i == 1 || i == 3) {
        config.relays[i].type = RELAY_TYPE_SHUTTER_DOWN;
        config.relays[i].runtime_sec = 20;
      } else {
        config.relays[i].type = RELAY_TYPE_LIGHT;
        config.relays[i].runtime_sec = 0;
      }
    } else {
      snprintf(config.relays[i].name, sizeof(config.relays[i].name), "Ek Modül Röle %d", i - 7);
      config.relays[i].type = RELAY_TYPE_LIGHT;
      config.relays[i].runtime_sec = 0;
    }
  }

  // Varsayılan Dijital Giriş (DI) Tanımları:
  for (int i = 0; i < MAX_TOTAL_DIS; i++) {
    if (i < 8) {
      snprintf(config.dis[i].name, sizeof(config.dis[i].name), "Anahtar / Buton %d", i + 1);
    } else {
      snprintf(config.dis[i].name, sizeof(config.dis[i].name), "Ek Giriş / Buton %d", i - 7);
    }
    config.dis[i].target_relay = i + 1; // DI1 -> Röle 1, DI2 -> Röle 2...
    config.dis[i].mode = DI_MODE_TOGGLE;
  }
}

void ConfigManager::begin() {
  prefs.begin("ahbu_cfg", false);
  load();
}

void ConfigManager::load() {
  if (!prefs.isKey("cfg_init")) {
    resetToDefaults();
    save();
    return;
  }

  prefs.getString("dev_name", config.device_name, sizeof(config.device_name));
  prefs.getString("sta_ssid", config.wifi_ssid, sizeof(config.wifi_ssid));
  prefs.getString("sta_pass", config.wifi_pass, sizeof(config.wifi_pass));
  config.wifi_sta_enabled = prefs.getBool("sta_en", false);
  config.rs485_baud = prefs.getUInt("rs_baud", 9600);

  config.ext_module_enabled = prefs.getBool("ext_en", false);
  config.ext_module_channels = prefs.getUChar("ext_ch", 0);
  config.ext_module_address = prefs.getUChar("ext_addr", 1);

  for (int i = 0; i < MAX_TOTAL_RELAYS; i++) {
    char key[16];
    snprintf(key, sizeof(key), "r_nm_%d", i);
    if (prefs.isKey(key)) {
      prefs.getString(key, config.relays[i].name, sizeof(config.relays[i].name));
    } else if (i >= 8) {
      snprintf(config.relays[i].name, sizeof(config.relays[i].name), "Ek Modül Röle %d", i - 7);
    }

    snprintf(key, sizeof(key), "r_tp_%d", i);
    config.relays[i].type = prefs.getUChar(key, config.relays[i].type);

    snprintf(key, sizeof(key), "r_rt_%d", i);
    config.relays[i].runtime_sec = prefs.getUShort(key, config.relays[i].runtime_sec);
  }

  for (int i = 0; i < MAX_TOTAL_DIS; i++) {
    char key[16];
    snprintf(key, sizeof(key), "d_nm_%d", i);
    if (prefs.isKey(key)) {
      prefs.getString(key, config.dis[i].name, sizeof(config.dis[i].name));
    } else if (i >= 8) {
      snprintf(config.dis[i].name, sizeof(config.dis[i].name), "Ek Giriş / Buton %d", i - 7);
    }

    snprintf(key, sizeof(key), "d_tr_%d", i);
    config.dis[i].target_relay = prefs.getUChar(key, config.dis[i].target_relay);

    snprintf(key, sizeof(key), "d_md_%d", i);
    config.dis[i].mode = prefs.getUChar(key, config.dis[i].mode);
  }
}

void ConfigManager::save() {
  prefs.putBool("cfg_init", true);
  prefs.putString("dev_name", config.device_name);
  prefs.putString("sta_ssid", config.wifi_ssid);
  prefs.putString("sta_pass", config.wifi_pass);
  prefs.putBool("sta_en", config.wifi_sta_enabled);
  prefs.putUInt("rs_baud", config.rs485_baud);

  prefs.putBool("ext_en", config.ext_module_enabled);
  prefs.putUChar("ext_ch", config.ext_module_channels);
  prefs.putUChar("ext_addr", config.ext_module_address);

  uint8_t totalR = config.totalRelays();
  uint8_t totalD = config.totalDIs();

  for (int i = 0; i < totalR; i++) {
    char key[16];
    snprintf(key, sizeof(key), "r_nm_%d", i);
    prefs.putString(key, config.relays[i].name);

    snprintf(key, sizeof(key), "r_tp_%d", i);
    prefs.putUChar(key, config.relays[i].type);

    snprintf(key, sizeof(key), "r_rt_%d", i);
    prefs.putUShort(key, config.relays[i].runtime_sec);
  }

  for (int i = 0; i < totalD; i++) {
    char key[16];
    snprintf(key, sizeof(key), "d_nm_%d", i);
    prefs.putString(key, config.dis[i].name);

    snprintf(key, sizeof(key), "d_tr_%d", i);
    prefs.putUChar(key, config.dis[i].target_relay);

    snprintf(key, sizeof(key), "d_md_%d", i);
    prefs.putUChar(key, config.dis[i].mode);
  }
}

