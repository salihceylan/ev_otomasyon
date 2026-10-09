// ============================================================================
// SystemConfig (src/SystemConfig.h) birim testleri:  pio test -e native -f test_system_config
// validate() aralik kurallari, uint8_t tasmasi, yerel anahtar/AP parolasi kurallari, varsayilan kimlik YOK.
// ============================================================================
#include <unity.h>
#include <stdint.h>
#include <string.h>
#include <stdio.h>
#include "SystemConfig.h"

void setUp(void) {}
void tearDown(void) {}

static SystemConfig g_cfg;

// Gecerli bir temel yapilandirma (varsayilan degerlere esdeger): validate() hicbir sey degistirmemeli.
static void makeValid(SystemConfig& c) {
  memset(&c, 0, sizeof(c));
  strncpy(c.device_name, "AHBU Test", sizeof(c.device_name) - 1);
  c.rs485_baud = 9600;
  c.ext_module_address = 1;
  c.mqtt_enabled = true;
  strncpy(c.mqtt_server, "broker.example", sizeof(c.mqtt_server) - 1);
  c.mqtt_port = 8884;
  for (int i = 0; i < MAX_TOTAL_RELAYS; i++) {
    strncpy(c.relays[i].name, "Role", sizeof(c.relays[i].name) - 1);
    c.relays[i].type = RELAY_TYPE_LIGHT;
    c.relays[i].runtime_sec = 0;
  }
  c.relays[0].type = RELAY_TYPE_SHUTTER_UP;   c.relays[0].runtime_sec = 20;
  c.relays[1].type = RELAY_TYPE_SHUTTER_DOWN; c.relays[1].runtime_sec = 20;
  for (int i = 0; i < MAX_TOTAL_DIS; i++) {
    strncpy(c.dis[i].name, "DI", sizeof(c.dis[i].name) - 1);
    c.dis[i].target_relay = (uint8_t)((i % 8) + 1);
    c.dis[i].mode = DI_MODE_TOGGLE;
  }
}

// ---------------------------------------------------------------- tamamlayici sayilar
void test_total_relays_basic_and_no_uint8_overflow(void) {
  makeValid(g_cfg);
  TEST_ASSERT_EQUAL_UINT8(8, g_cfg.totalRelays());
  TEST_ASSERT_EQUAL_UINT8(8, g_cfg.totalDIs());
  g_cfg.ext_module_enabled = true;
  g_cfg.ext_module_channels = 8;
  TEST_ASSERT_EQUAL_UINT8(16, g_cfg.totalRelays());
  g_cfg.ext_module_channels = 32;
  TEST_ASSERT_EQUAL_UINT8(40, g_cfg.totalRelays());
  // Eski kod: uint8_t t = 8 + channels  =>  8 + 250 = 258 -> 2 (8'in ALTINA tasar!)
  g_cfg.ext_module_channels = 250;
  TEST_ASSERT_EQUAL_UINT8(40, g_cfg.totalRelays());
  TEST_ASSERT_EQUAL_UINT8(40, g_cfg.totalDIs());
  g_cfg.ext_module_channels = 255;
  TEST_ASSERT_EQUAL_UINT8(40, g_cfg.totalRelays());
}

void test_valid_default_like_config_is_untouched(void) {
  makeValid(g_cfg);
  TEST_ASSERT_TRUE(g_cfg.validate());
  TEST_ASSERT_EQUAL_UINT8(RELAY_TYPE_SHUTTER_UP, g_cfg.relays[0].type);
  TEST_ASSERT_EQUAL_UINT16(20, g_cfg.relays[0].runtime_sec);
  TEST_ASSERT_EQUAL_UINT8(3, g_cfg.dis[2].target_relay);
}

// ---------------------------------------------------------------- ek modul
void test_ext_channel_whitelist(void) {
  const uint8_t valid[] = {0, 2, 4, 8, 12, 16, 24, 32};
  for (unsigned i = 0; i < sizeof(valid); i++) TEST_ASSERT_TRUE(isValidExtChannelCount(valid[i]));
  const uint8_t invalid[] = {1, 3, 5, 6, 7, 9, 10, 11, 13, 20, 31, 33, 40, 64, 100, 250, 255};
  for (unsigned i = 0; i < sizeof(invalid); i++) TEST_ASSERT_FALSE(isValidExtChannelCount(invalid[i]));
}

void test_invalid_ext_channels_are_repaired(void) {
  makeValid(g_cfg);
  g_cfg.ext_module_enabled = true;
  g_cfg.ext_module_channels = 250;
  TEST_ASSERT_FALSE(g_cfg.validate());
  TEST_ASSERT_EQUAL_UINT8(8, g_cfg.ext_module_channels);       // etkin => varsayilan 8

  makeValid(g_cfg);
  g_cfg.ext_module_enabled = false;
  g_cfg.ext_module_channels = 7;
  TEST_ASSERT_FALSE(g_cfg.validate());
  TEST_ASSERT_EQUAL_UINT8(0, g_cfg.ext_module_channels);       // pasif => 0
}

void test_enabled_with_zero_channels_defaults_to_8(void) {
  makeValid(g_cfg);
  g_cfg.ext_module_enabled = true;
  g_cfg.ext_module_channels = 0;
  TEST_ASSERT_FALSE(g_cfg.validate());
  TEST_ASSERT_EQUAL_UINT8(8, g_cfg.ext_module_channels);
  TEST_ASSERT_EQUAL_UINT8(16, g_cfg.totalRelays());
}

void test_ext_address_range(void) {
  const uint8_t bad[] = {0, 248, 255};
  for (unsigned i = 0; i < sizeof(bad); i++) {
    makeValid(g_cfg);
    g_cfg.ext_module_address = bad[i];
    TEST_ASSERT_FALSE(g_cfg.validate());
    TEST_ASSERT_EQUAL_UINT8(1, g_cfg.ext_module_address);
  }
  const uint8_t good[] = {1, 2, 100, 247};
  for (unsigned i = 0; i < sizeof(good); i++) {
    makeValid(g_cfg);
    g_cfg.ext_module_address = good[i];
    TEST_ASSERT_TRUE(g_cfg.validate());
    TEST_ASSERT_EQUAL_UINT8(good[i], g_cfg.ext_module_address);
  }
}

// ---------------------------------------------------------------- roleler
void test_relay_type_range(void) {
  makeValid(g_cfg);
  g_cfg.relays[4].type = 4;                   // gecersiz
  g_cfg.relays[5].type = 200;
  TEST_ASSERT_FALSE(g_cfg.validate());
  TEST_ASSERT_EQUAL_UINT8(RELAY_TYPE_LIGHT, g_cfg.relays[4].type);
  TEST_ASSERT_EQUAL_UINT8(RELAY_TYPE_LIGHT, g_cfg.relays[5].type);
}

void test_shutter_runtime_range_1_to_300(void) {
  const uint16_t bad[] = {0, 301, 1000, 65535};
  for (unsigned i = 0; i < sizeof(bad) / sizeof(bad[0]); i++) {
    makeValid(g_cfg);
    g_cfg.relays[0].runtime_sec = bad[i];
    TEST_ASSERT_FALSE(g_cfg.validate());
    TEST_ASSERT_EQUAL_UINT16(SHUTTER_RUNTIME_DEFAULT_SEC, g_cfg.relays[0].runtime_sec);
  }
  const uint16_t good[] = {1, 20, 300};
  for (unsigned i = 0; i < sizeof(good) / sizeof(good[0]); i++) {
    makeValid(g_cfg);
    g_cfg.relays[1].runtime_sec = good[i];
    TEST_ASSERT_TRUE(g_cfg.validate());
    TEST_ASSERT_EQUAL_UINT16(good[i], g_cfg.relays[1].runtime_sec);
  }
}

void test_impulse_duration_range(void) {
  makeValid(g_cfg);
  g_cfg.relays[6].type = RELAY_TYPE_IMPULSE;
  g_cfg.relays[6].runtime_sec = 0;
  TEST_ASSERT_FALSE(g_cfg.validate());
  TEST_ASSERT_EQUAL_UINT16(IMPULSE_MS_DEFAULT, g_cfg.relays[6].runtime_sec);

  makeValid(g_cfg);
  g_cfg.relays[6].type = RELAY_TYPE_IMPULSE;
  g_cfg.relays[6].runtime_sec = 65535;
  TEST_ASSERT_FALSE(g_cfg.validate());
  TEST_ASSERT_EQUAL_UINT16(IMPULSE_MS_MAX, g_cfg.relays[6].runtime_sec);

  makeValid(g_cfg);
  g_cfg.relays[6].type = RELAY_TYPE_IMPULSE;
  g_cfg.relays[6].runtime_sec = 500;
  TEST_ASSERT_TRUE(g_cfg.validate());
  TEST_ASSERT_EQUAL_UINT16(500, g_cfg.relays[6].runtime_sec);
}

void test_light_relay_runtime_is_left_alone(void) {
  makeValid(g_cfg);
  g_cfg.relays[4].runtime_sec = 12345;       // lambada anlamsiz ama zararsiz: dokunulmaz
  TEST_ASSERT_TRUE(g_cfg.validate());
  TEST_ASSERT_EQUAL_UINT16(12345, g_cfg.relays[4].runtime_sec);
}

// ---------------------------------------------------------------- DI
void test_di_mode_and_target_range(void) {
  makeValid(g_cfg);
  g_cfg.dis[3].mode = 5;
  g_cfg.dis[4].target_relay = 9;             // ek modul kapali: en cok 8
  TEST_ASSERT_FALSE(g_cfg.validate());
  TEST_ASSERT_EQUAL_UINT8(DI_MODE_TOGGLE, g_cfg.dis[3].mode);
  TEST_ASSERT_EQUAL_UINT8(0, g_cfg.dis[4].target_relay);

  makeValid(g_cfg);
  g_cfg.dis[0].target_relay = 8;             // sinirda gecerli
  TEST_ASSERT_TRUE(g_cfg.validate());
  TEST_ASSERT_EQUAL_UINT8(8, g_cfg.dis[0].target_relay);

  makeValid(g_cfg);
  g_cfg.ext_module_enabled = true;
  g_cfg.ext_module_channels = 8;             // toplam 16 role
  g_cfg.dis[0].target_relay = 16;
  g_cfg.dis[1].target_relay = 17;
  TEST_ASSERT_FALSE(g_cfg.validate());
  TEST_ASSERT_EQUAL_UINT8(16, g_cfg.dis[0].target_relay);
  TEST_ASSERT_EQUAL_UINT8(0, g_cfg.dis[1].target_relay);
}

// ---------------------------------------------------------------- Wi-Fi / baud / MQTT
void test_wifi_credentials_rules(void) {
  makeValid(g_cfg);
  strncpy(g_cfg.wifi_ssid, "EvAgim", sizeof(g_cfg.wifi_ssid) - 1);
  strncpy(g_cfg.wifi_pass, "12345678", sizeof(g_cfg.wifi_pass) - 1);
  g_cfg.wifi_sta_enabled = true;
  TEST_ASSERT_TRUE(g_cfg.validate());

  makeValid(g_cfg);                           // 7 karakterlik parola WPA icin gecersiz
  strncpy(g_cfg.wifi_ssid, "EvAgim", sizeof(g_cfg.wifi_ssid) - 1);
  strncpy(g_cfg.wifi_pass, "1234567", sizeof(g_cfg.wifi_pass) - 1);
  g_cfg.wifi_sta_enabled = true;
  TEST_ASSERT_FALSE(g_cfg.validate());
  TEST_ASSERT_EQUAL_UINT8(0, g_cfg.wifi_ssid[0]);
  TEST_ASSERT_FALSE(g_cfg.wifi_sta_enabled);

  makeValid(g_cfg);                           // acik ag: parola bos gecerli
  strncpy(g_cfg.wifi_ssid, "Misafir", sizeof(g_cfg.wifi_ssid) - 1);
  g_cfg.wifi_sta_enabled = true;
  TEST_ASSERT_TRUE(g_cfg.validate());

  makeValid(g_cfg);                           // 33 bayt SSID gecersiz
  memset(g_cfg.wifi_ssid, 'A', 33);
  g_cfg.wifi_sta_enabled = true;
  TEST_ASSERT_FALSE(g_cfg.validate());
  TEST_ASSERT_EQUAL_UINT8(0, g_cfg.wifi_ssid[0]);

  makeValid(g_cfg);                           // etkin ama SSID bos
  g_cfg.wifi_sta_enabled = true;
  TEST_ASSERT_FALSE(g_cfg.validate());
  TEST_ASSERT_FALSE(g_cfg.wifi_sta_enabled);
}

void test_baud_whitelist(void) {
  makeValid(g_cfg);
  g_cfg.rs485_baud = 12345;
  TEST_ASSERT_FALSE(g_cfg.validate());
  TEST_ASSERT_EQUAL_UINT32(9600, g_cfg.rs485_baud);
  const uint32_t good[] = {4800, 9600, 19200, 38400, 57600, 115200};
  for (unsigned i = 0; i < 6; i++) {
    makeValid(g_cfg);
    g_cfg.rs485_baud = good[i];
    TEST_ASSERT_TRUE(g_cfg.validate());
    TEST_ASSERT_EQUAL_UINT32(good[i], g_cfg.rs485_baud);
  }
}

void test_mqtt_defaults_have_no_credentials(void) {
  memset(&g_cfg, 0, sizeof(g_cfg));           // sifirlanmis (ConfigManager::applyDefaults ile ayni baslangic)
  strncpy(g_cfg.device_name, "x", sizeof(g_cfg.device_name) - 1);
  g_cfg.rs485_baud = 9600;
  g_cfg.ext_module_address = 1;
  TEST_ASSERT_FALSE(g_cfg.validate());        // bos sunucu/port onarilir
  TEST_ASSERT_EQUAL_UINT16(DEFAULT_MQTT_PORT, g_cfg.mqtt_port);
  TEST_ASSERT_TRUE(g_cfg.mqtt_server[0] != 0);
  // Kimlik ASLA kendiliginden dolmaz
  TEST_ASSERT_EQUAL_UINT8(0, g_cfg.mqtt_user[0]);
  TEST_ASSERT_EQUAL_UINT8(0, g_cfg.mqtt_pass[0]);
  TEST_ASSERT_FALSE(g_cfg.hasMqttCredentials());
  TEST_ASSERT_FALSE(g_cfg.hasLocalKey());
}

void test_has_mqtt_credentials_needs_all_three(void) {
  makeValid(g_cfg);
  TEST_ASSERT_FALSE(g_cfg.hasMqttCredentials());
  strncpy(g_cfg.mqtt_user, "d_h_0123456789abcdef", sizeof(g_cfg.mqtt_user) - 1);
  TEST_ASSERT_FALSE(g_cfg.hasMqttCredentials());           // parola yok
  strncpy(g_cfg.mqtt_pass, "x", sizeof(g_cfg.mqtt_pass) - 1);
  TEST_ASSERT_TRUE(g_cfg.hasMqttCredentials());
  g_cfg.mqtt_server[0] = 0;
  TEST_ASSERT_FALSE(g_cfg.hasMqttCredentials());           // sunucu yok
}

// ---------------------------------------------------------------- yerel anahtar / AP parolasi
void test_local_key_length_and_charset(void) {
  makeValid(g_cfg);
  TEST_ASSERT_FALSE(g_cfg.setLocalKey(nullptr));
  TEST_ASSERT_FALSE(g_cfg.setLocalKey(""));
  TEST_ASSERT_FALSE(g_cfg.setLocalKey("1234567"));                       // 7: kisa
  TEST_ASSERT_TRUE(g_cfg.setLocalKey("12345678"));                       // 8
  TEST_ASSERT_TRUE(g_cfg.hasLocalKey());
  TEST_ASSERT_TRUE(strcmp(g_cfg.local_key, "12345678") == 0);
  TEST_ASSERT_TRUE(g_cfg.setLocalKey("abcdefghijklmnopqrstuvwxyz012345")); // 32
  TEST_ASSERT_FALSE(g_cfg.setLocalKey("abcdefghijklmnopqrstuvwxyz0123456")); // 33
  TEST_ASSERT_TRUE(strcmp(g_cfg.local_key, "abcdefghijklmnopqrstuvwxyz012345") == 0);   // reddedilen cagri ESKIYI bozmaz
  TEST_ASSERT_FALSE(g_cfg.setLocalKey("abcd efgh"));                     // bosluk yok
  TEST_ASSERT_FALSE(g_cfg.setLocalKey("abcd\tefgh"));                    // kontrol karakteri
  TEST_ASSERT_FALSE(g_cfg.setLocalKey("abcd\x01" "efgh"));
  TEST_ASSERT_FALSE(g_cfg.setLocalKey("abcdefg\xC3\xBC"));               // ASCII disi
  TEST_ASSERT_TRUE(strcmp(g_cfg.local_key, "abcdefghijklmnopqrstuvwxyz012345") == 0);
}

void test_ap_pass_rules(void) {
  makeValid(g_cfg);
  TEST_ASSERT_FALSE(g_cfg.setApPass(nullptr));
  TEST_ASSERT_FALSE(g_cfg.setApPass("short"));
  TEST_ASSERT_TRUE(g_cfg.setApPass("Ev Agi 2026"));                       // bosluk AP parolasinda serbest
  TEST_ASSERT_TRUE(strcmp(g_cfg.ap_pass, "Ev Agi 2026") == 0);
  TEST_ASSERT_FALSE(g_cfg.setApPass("0123456789012345678901234567890123"));   // 34
  TEST_ASSERT_FALSE(g_cfg.setApPass("abcdefg\x07h"));
  TEST_ASSERT_TRUE(strcmp(g_cfg.ap_pass, "Ev Agi 2026") == 0);
}

void test_validate_clears_corrupt_secrets(void) {
  makeValid(g_cfg);
  memcpy(g_cfg.local_key, "abc", 4);                                      // 3 karakter: bozuk
  memcpy(g_cfg.ap_pass, "kisa", 5);
  TEST_ASSERT_FALSE(g_cfg.validate());
  TEST_ASSERT_FALSE(g_cfg.hasLocalKey());                                 // kismi/bozuk kimlik KALMAZ
  TEST_ASSERT_EQUAL_UINT8(0, g_cfg.ap_pass[0]);

  makeValid(g_cfg);
  TEST_ASSERT_TRUE(g_cfg.setLocalKey("GecerliAnahtar123"));
  TEST_ASSERT_TRUE(g_cfg.validate());
  TEST_ASSERT_TRUE(g_cfg.hasLocalKey());                                  // gecerli anahtar korunur
}

void test_unterminated_strings_are_terminated(void) {
  makeValid(g_cfg);
  memset(g_cfg.device_name, 'A', sizeof(g_cfg.device_name));              // NUL yok
  memset(g_cfg.relays[3].name, 'B', sizeof(g_cfg.relays[3].name));
  memset(g_cfg.dis[3].name, 'C', sizeof(g_cfg.dis[3].name));
  g_cfg.validate();
  TEST_ASSERT_EQUAL_UINT8(0, g_cfg.device_name[sizeof(g_cfg.device_name) - 1]);
  TEST_ASSERT_EQUAL_UINT8(0, g_cfg.relays[3].name[sizeof(g_cfg.relays[3].name) - 1]);
  TEST_ASSERT_EQUAL_UINT8(0, g_cfg.dis[3].name[sizeof(g_cfg.dis[3].name) - 1]);
}

// Sahip karari (2026-10-09): HICBIR rolenin sabit rolu yok. Fabrika varsayilani: yerel roleler genel ac-kapa "Röle N" (sure 0), ek modul
// roleleri "Ek Modül Röle N"; DI n -> role n TOGGLE. Panjur (komsu role ile eslesme, kilit) YALNIZ servisin yazdigi sablon/yapilandirmadan gelir.
void test_factory_io_defaults_have_no_fixed_role(void) {
  SystemConfig c;
  memset(&c, 0x5A, sizeof(c));
  applyFactoryRelayDefaults(c);
  applyFactoryDiDefaults(c);
  char want[40];
  // Kaynak kodlamasindan bagimsiz bayt denetimi: "Röle 1" = 'R' C3 B6 'l' 'e' ' ' '1' (UTF-8, 7 bayt)
  TEST_ASSERT_EQUAL_INT(7, (int)strlen(c.relays[0].name));
  TEST_ASSERT_EQUAL_HEX8(0xC3, (uint8_t)c.relays[0].name[1]);
  TEST_ASSERT_EQUAL_HEX8(0xB6, (uint8_t)c.relays[0].name[2]);
  for (int i = 0; i < MAX_TOTAL_RELAYS; i++) {
    if (i < 8) snprintf(want, sizeof(want), "Röle %d", i + 1);
    else snprintf(want, sizeof(want), "Ek Modül Röle %d", i - 7);
    TEST_ASSERT_EQUAL_STRING(want, c.relays[i].name);
    TEST_ASSERT_EQUAL_UINT8(RELAY_TYPE_LIGHT, c.relays[i].type);
    TEST_ASSERT_EQUAL_UINT16(0, c.relays[i].runtime_sec);
  }
  for (int i = 0; i < MAX_TOTAL_DIS; i++) {
    if (i < 8) snprintf(want, sizeof(want), "Anahtar / Buton %d", i + 1);
    else snprintf(want, sizeof(want), "Ek Giriş / Buton %d", i - 7);
    TEST_ASSERT_EQUAL_STRING(want, c.dis[i].name);
    TEST_ASSERT_EQUAL_UINT8(i + 1, c.dis[i].target_relay);
    TEST_ASSERT_EQUAL_UINT8(DI_MODE_TOGGLE, c.dis[i].mode);
  }
  // Kismi aralik (seri DEFAULT_DI: DI 1..4): aralik disi DI'lara dokunulmaz
  c.dis[0].mode = DI_MODE_SHUTTER_STEP; c.dis[0].target_relay = 0;
  c.dis[4].mode = DI_MODE_MOMENTARY;    c.dis[4].target_relay = 9;
  applyFactoryDiDefaults(c, 0, 4);
  TEST_ASSERT_EQUAL_UINT8(DI_MODE_TOGGLE, c.dis[0].mode);
  TEST_ASSERT_EQUAL_UINT8(1, c.dis[0].target_relay);
  TEST_ASSERT_EQUAL_UINT8(DI_MODE_MOMENTARY, c.dis[4].mode);
  TEST_ASSERT_EQUAL_UINT8(9, c.dis[4].target_relay);
}

int main(int, char**) {
  UNITY_BEGIN();
  RUN_TEST(test_total_relays_basic_and_no_uint8_overflow);
  RUN_TEST(test_valid_default_like_config_is_untouched);
  RUN_TEST(test_ext_channel_whitelist);
  RUN_TEST(test_invalid_ext_channels_are_repaired);
  RUN_TEST(test_enabled_with_zero_channels_defaults_to_8);
  RUN_TEST(test_ext_address_range);
  RUN_TEST(test_relay_type_range);
  RUN_TEST(test_shutter_runtime_range_1_to_300);
  RUN_TEST(test_impulse_duration_range);
  RUN_TEST(test_light_relay_runtime_is_left_alone);
  RUN_TEST(test_di_mode_and_target_range);
  RUN_TEST(test_wifi_credentials_rules);
  RUN_TEST(test_baud_whitelist);
  RUN_TEST(test_mqtt_defaults_have_no_credentials);
  RUN_TEST(test_has_mqtt_credentials_needs_all_three);
  RUN_TEST(test_local_key_length_and_charset);
  RUN_TEST(test_ap_pass_rules);
  RUN_TEST(test_validate_clears_corrupt_secrets);
  RUN_TEST(test_unterminated_strings_are_terminated);
  RUN_TEST(test_factory_io_defaults_have_no_fixed_role);
  return UNITY_END();
}
