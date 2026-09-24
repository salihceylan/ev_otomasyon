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

  // Güvenli MQTTS (Port 8884) Varsayılanları
  config.mqtt_enabled = true;
  strncpy(config.mqtt_server, "evotomasyon.gudeteknoloji.com.tr", sizeof(config.mqtt_server) - 1);
  config.mqtt_server[sizeof(config.mqtt_server) - 1] = '\0';
  config.mqtt_port = 8884;
  strncpy(config.mqtt_user, "home_101", sizeof(config.mqtt_user) - 1);
  config.mqtt_user[sizeof(config.mqtt_user) - 1] = '\0';
  strncpy(config.mqtt_pass, "PassHome101!Sec", sizeof(config.mqtt_pass) - 1);
  config.mqtt_pass[sizeof(config.mqtt_pass) - 1] = '\0';

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
  // 1-2: Salon Panjuru (DI 1: Tek Buton Panjur Kontrolü, DI 2: Boşta/Serbest)
  // 3-4: Oda Panjuru (DI 3: Tek Buton Panjur Kontrolü, DI 4: Boşta/Serbest)
  // 5-8: Aydınlatmalar (Normal Toggle)
  for (int i = 0; i < MAX_TOTAL_DIS; i++) {
    if (i < 8) {
      snprintf(config.dis[i].name, sizeof(config.dis[i].name), "Anahtar / Buton %d", i + 1);
    } else {
      snprintf(config.dis[i].name, sizeof(config.dis[i].name), "Ek Giriş / Buton %d", i - 7);
    }
    config.dis[i].target_relay = i + 1;
    config.dis[i].mode = DI_MODE_TOGGLE;
  }

  // Panjur çiftleri için akıllı varsayılanlar:
  strncpy(config.dis[0].name, "Salon Panjur Butonu", sizeof(config.dis[0].name) - 1);
  config.dis[0].target_relay = 1;
  config.dis[0].mode = DI_MODE_SHUTTER_STEP; // Tek buton 2-kablolu panjur

  strncpy(config.dis[1].name, "Giriş 2 (Boşta / Serbest)", sizeof(config.dis[1].name) - 1);
  config.dis[1].target_relay = 0;             // Boşta / serbest
  config.dis[1].mode = DI_MODE_TOGGLE;

  strncpy(config.dis[2].name, "Oda Panjur Butonu", sizeof(config.dis[2].name) - 1);
  config.dis[2].target_relay = 3;
  config.dis[2].mode = DI_MODE_SHUTTER_STEP; // Tek buton 2-kablolu panjur

  strncpy(config.dis[3].name, "Giriş 4 (Boşta / Serbest)", sizeof(config.dis[3].name) - 1);
  config.dis[3].target_relay = 0;             // Boşta / serbest
  config.dis[3].mode = DI_MODE_TOGGLE;
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

  // Güvenli MQTTS Ayarları
  config.mqtt_enabled = prefs.getBool("mq_en", true);
  prefs.getString("mq_srv", config.mqtt_server, sizeof(config.mqtt_server));
  if (config.mqtt_server[0] == '\0') {
    strncpy(config.mqtt_server, "evotomasyon.gudeteknoloji.com.tr", sizeof(config.mqtt_server) - 1);
  }
  config.mqtt_port = prefs.getUShort("mq_port", 8884);
  prefs.getString("mq_usr", config.mqtt_user, sizeof(config.mqtt_user));
  if (config.mqtt_user[0] == '\0') {
    strncpy(config.mqtt_user, "home_101", sizeof(config.mqtt_user) - 1);
  }
  prefs.getString("mq_pwd", config.mqtt_pass, sizeof(config.mqtt_pass));
  if (config.mqtt_pass[0] == '\0') {
    strncpy(config.mqtt_pass, "PassHome101!Sec", sizeof(config.mqtt_pass) - 1);
  }

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

  // Güvenli MQTTS Kaydet
  prefs.putBool("mq_en", config.mqtt_enabled);
  prefs.putString("mq_srv", config.mqtt_server);
  prefs.putUShort("mq_port", config.mqtt_port);
  prefs.putString("mq_usr", config.mqtt_user);
  prefs.putString("mq_pwd", config.mqtt_pass);

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

