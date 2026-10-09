// ============================================================================
// MqttHostPolicy (src/MqttHostPolicy.h) birim testleri:  pio test -e native -f test_mqtt_host_policy
//
// Sahip karari (2026-10-09): POST /api/mqtt/config ve bootstrap yaniti panoyu YALNIZCA derlemeye gomulu izin listesindeki bir
// bulut sunucusuna yonlendirebilir: DEFAULT_MQTT_SERVER + -DAHBU_MQTT_HOST_ALLOW="h1,h2". Bos/verilmemis host = mevcut korunur.
// Bu test, derleme bayragi yolunu dogrulamak icin AHBU_MQTT_HOST_ALLOW'u include'dan ONCE tanimlar.
// ============================================================================
#define AHBU_MQTT_HOST_ALLOW " qa.local , 10.0.2.2,,Broker.Test "
#include <unity.h>
#include <stdint.h>
#include <string.h>
#include "MqttHostPolicy.h"

using namespace mqtthost;

void setUp(void) {}
void tearDown(void) {}

void test_syntax_rule_unchanged(void) {
  TEST_ASSERT_TRUE(validSyntax("a"));
  TEST_ASSERT_TRUE(validSyntax("evotomasyon.gudeteknoloji.com.tr"));
  TEST_ASSERT_TRUE(validSyntax("10.0.2.2"));
  TEST_ASSERT_FALSE(validSyntax(nullptr));
  TEST_ASSERT_FALSE(validSyntax(""));
  TEST_ASSERT_FALSE(validSyntax("bad host"));
  TEST_ASSERT_FALSE(validSyntax("-x.com"));
  TEST_ASSERT_FALSE(validSyntax("x.com."));
  TEST_ASSERT_FALSE(validSyntax("x_y.com"));
  char longHost[70];
  memset(longHost, 'a', 64);
  longHost[64] = 0;
  TEST_ASSERT_FALSE(validSyntax(longHost));
  longHost[63] = 0;
  TEST_ASSERT_TRUE(validSyntax(longHost));
}

void test_default_server_only_when_list_empty(void) {
  TEST_ASSERT_TRUE(allowedIn(DEFAULT_MQTT_SERVER, DEFAULT_MQTT_SERVER, ""));
  TEST_ASSERT_TRUE(allowedIn("EvOtomasyon.GudeTeknoloji.com.TR", DEFAULT_MQTT_SERVER, ""));   // ad buyuk/kucuk harf duyarsiz
  TEST_ASSERT_TRUE(allowedIn(DEFAULT_MQTT_SERVER, DEFAULT_MQTT_SERVER, nullptr));
  const char* foreign[] = {
      "evil.example",
      "evotomasyon.gudeteknoloji.com.tr.evil.example",   // onek saldirisi
      "xevotomasyon.gudeteknoloji.com.tr",               // sonek saldirisi
      "gudeteknoloji.com.tr",
      "evotomasyon.gudeteknoloji.com",
      "10.0.2.2",
  };
  for (const char* h : foreign) TEST_ASSERT_FALSE_MESSAGE(allowedIn(h, DEFAULT_MQTT_SERVER, ""), h);
  TEST_ASSERT_FALSE(allowedIn("bad host", DEFAULT_MQTT_SERVER, "bad host"));   // sozdizimi bozuk ad listede olsa da reddedilir
  TEST_ASSERT_FALSE(allowedIn(nullptr, DEFAULT_MQTT_SERVER, ""));
  TEST_ASSERT_FALSE(allowedIn("", DEFAULT_MQTT_SERVER, ","));
}

void test_extra_list_trimmed_case_insensitive_exact(void) {
  const char* list = "qa.local, 10.0.2.2 ,,  Broker.Test,";
  TEST_ASSERT_TRUE(allowedIn("qa.local", DEFAULT_MQTT_SERVER, list));
  TEST_ASSERT_TRUE(allowedIn("10.0.2.2", DEFAULT_MQTT_SERVER, list));
  TEST_ASSERT_TRUE(allowedIn("broker.test", DEFAULT_MQTT_SERVER, list));
  TEST_ASSERT_TRUE(allowedIn(DEFAULT_MQTT_SERVER, DEFAULT_MQTT_SERVER, list));
  TEST_ASSERT_FALSE(allowedIn("qa.loca", DEFAULT_MQTT_SERVER, list));        // onek
  TEST_ASSERT_FALSE(allowedIn("qa.local.x", DEFAULT_MQTT_SERVER, list));     // fazlasi
  TEST_ASSERT_FALSE(allowedIn("10.0.2.20", DEFAULT_MQTT_SERVER, list));
  TEST_ASSERT_FALSE(allowedIn("10.0.2", DEFAULT_MQTT_SERVER, list));
  TEST_ASSERT_FALSE(allowedIn("evil.example", DEFAULT_MQTT_SERVER, list));
}

void test_build_flag_list_is_used(void) {
  TEST_ASSERT_TRUE(allowed(DEFAULT_MQTT_SERVER));
  TEST_ASSERT_TRUE(allowed("qa.local"));
  TEST_ASSERT_TRUE(allowed("10.0.2.2"));
  TEST_ASSERT_TRUE(allowed("broker.test"));
  TEST_ASSERT_FALSE(allowed("evil.example"));
  TEST_ASSERT_FALSE(allowed("127.0.0.1"));
}

void test_http_request_check(void) {
  // Bos ya da verilmemis host: mevcut sunucu korunur (port/kullanici/parola degisimi serbest)
  TEST_ASSERT_TRUE(checkRequested(nullptr) == Check::KEEP);
  TEST_ASSERT_TRUE(checkRequested("") == Check::KEEP);
  TEST_ASSERT_TRUE(checkRequested(DEFAULT_MQTT_SERVER) == Check::SET);
  TEST_ASSERT_TRUE(checkRequested("QA.LOCAL") == Check::SET);
  TEST_ASSERT_TRUE(checkRequested("bad host") == Check::INVALID);
  TEST_ASSERT_TRUE(checkRequested("-x.com") == Check::INVALID);
  TEST_ASSERT_TRUE(checkRequested("evil.example") == Check::NOT_ALLOWED);
  TEST_ASSERT_TRUE(checkRequested("evotomasyon.gudeteknoloji.com.tr.evil.example") == Check::NOT_ALLOWED);
}

int main(int, char**) {
  UNITY_BEGIN();
  RUN_TEST(test_syntax_rule_unchanged);
  RUN_TEST(test_default_server_only_when_list_empty);
  RUN_TEST(test_extra_list_trimmed_case_insensitive_exact);
  RUN_TEST(test_build_flag_list_is_used);
  RUN_TEST(test_http_request_check);
  return UNITY_END();
}
