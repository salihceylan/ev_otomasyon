// ============================================================================
// BootstrapCore (src/BootstrapCore.h) birim testleri:  pio test -e native -f test_bootstrap
//
// CONTRACTS §3f: imza girdisi "ahbu-bootstrap/1|uid|ts|nonce", gövde JSON'u, tetik koşulları (provizyon, ağ, saat, etkin, kimlik yok ya da
// art arda 3 "not authorized"), bekleme süreleri (202 10 dk, 401 60 dk, 429/ağ/bozuk 30 dk; millis() sarma tabanları), durum metinleri ve
// 200 yanıtının sıkı ayrıştırılması.
// ============================================================================
#include <unity.h>
#include <stdint.h>
#include <string.h>
#include <ArduinoJson.h>
#include "BootstrapCore.h"

using namespace boot;

void setUp(void) {}
void tearDown(void) {}

namespace {
In ready() {
  In in;
  in.enabled = true;
  in.provisioned = true;
  in.netUp = true;
  in.timeSynced = true;
  in.haveCreds = false;
  in.authRejects = 0;
  return in;
}
}  // namespace

void test_sign_string_and_body_format() {
  char s[128];
  TEST_ASSERT_TRUE(signString(s, sizeof(s), "AHBU-S3-DD8754", 1791460000u, "00112233445566778899aabbccddeeff"));
  TEST_ASSERT_EQUAL_STRING("ahbu-bootstrap/1|AHBU-S3-DD8754|1791460000|00112233445566778899aabbccddeeff", s);
  TEST_ASSERT_FALSE(signString(s, 20, "AHBU-S3-DD8754", 1u, "00"));
  char b[256];
  TEST_ASSERT_TRUE(buildBody(b, sizeof(b), "AHBU-S3-DD8754", 1791460000u, "ab", "1.3.0", "cd"));
  TEST_ASSERT_EQUAL_STRING("{\"device_uuid\":\"AHBU-S3-DD8754\",\"ts\":1791460000,\"nonce\":\"ab\",\"fw\":\"1.3.0\",\"sig\":\"cd\"}", b);
  DynamicJsonDocument d(512);
  TEST_ASSERT_TRUE(!deserializeJson(d, b));
  TEST_ASSERT_EQUAL_UINT(1791460000u, d["ts"].as<uint32_t>());
  const uint8_t raw[3] = {0x00, 0xAB, 0xFF};
  char h[7];
  toHex(raw, 3, h);
  TEST_ASSERT_EQUAL_STRING("00abff", h);
}

void test_trigger_conditions() {
  Fsm f;
  TEST_ASSERT_TRUE(f.due(0, ready()));
  In in = ready();
  in.provisioned = false;
  TEST_ASSERT_FALSE(f.due(0, in));            // provizyonsuz pano bootstrap yapamaz
  in = ready();
  in.netUp = false;
  TEST_ASSERT_FALSE(f.due(0, in));
  in = ready();
  in.timeSynced = false;
  TEST_ASSERT_FALSE(f.due(0, in));
  in = ready();
  in.enabled = false;
  TEST_ASSERT_FALSE(f.due(0, in));
  in = ready();
  in.haveCreds = true;
  TEST_ASSERT_FALSE(f.due(0, in));            // kimlik var, broker kabul ediyor
  in.authRejects = 2;
  TEST_ASSERT_FALSE(f.due(0, in));
  in.authRejects = 3;
  TEST_ASSERT_TRUE(f.due(0, in));             // art arda 3 "not authorized"
}

void test_backoff_per_result_and_status_text() {
  const uint32_t bases[] = {0u, 0x7FFFFFF0u, 0xFFFFFFF0u};
  for (uint32_t t0 : bases) {
    struct Case { Result r; uint32_t wait; const char* st; } cases[] = {
        {Result::PENDING, 600000u, "waiting_claim"}, {Result::DENIED, 3600000u, "denied"},
        {Result::RATE_LIMITED, 1800000u, "error"}, {Result::NET_ERROR, 1800000u, "error"},
        {Result::BAD_RESPONSE, 1800000u, "error"}};
    for (const Case& c : cases) {
      Fsm f;
      TEST_ASSERT_EQUAL_STRING("idle", statusText(f.status));
      f.onResult(t0, c.r);
      TEST_ASSERT_EQUAL_STRING(c.st, statusText(f.status));
      TEST_ASSERT_FALSE(f.due(t0 + c.wait - 1u, ready()));
      TEST_ASSERT_TRUE(f.due(t0 + c.wait, ready()));
      TEST_ASSERT_TRUE(c.wait <= (uint32_t)WAIT_MAX_MS);
    }
  }
  Fsm ok;
  ok.onResult(5, Result::OK);
  TEST_ASSERT_EQUAL_STRING("ok", statusText(ok.status));
  In in = ready();
  in.haveCreds = true;
  TEST_ASSERT_FALSE(ok.due(6, in));           // kimlik alındı: tetik yok
  in.authRejects = 3;
  TEST_ASSERT_TRUE(ok.due(6, in));            // sonradan broker reddederse hemen yeniden
}

void test_idle_fsm_polled_for_49_days_never_stalls() {
  Fsm f;
  f.onResult(0, Result::PENDING);
  for (uint64_t t = 0; t < 0x100000000ULL; t += 60000ULL) f.service((uint32_t)t);
  TEST_ASSERT_TRUE(f.due(0xFFFFFFFFu, ready()));
}

void test_response_parsing() {
  Creds c;
  TEST_ASSERT_TRUE(parseResponse(-1, nullptr, c) == Result::NET_ERROR);
  TEST_ASSERT_TRUE(parseResponse(202, "{\"status\":\"pending\"}", c) == Result::PENDING);
  TEST_ASSERT_TRUE(parseResponse(401, "{\"code\":\"BOOTSTRAP_DENIED\"}", c) == Result::DENIED);
  TEST_ASSERT_TRUE(parseResponse(429, "", c) == Result::RATE_LIMITED);
  TEST_ASSERT_TRUE(parseResponse(500, "x", c) == Result::BAD_RESPONSE);
  const char* ok =
      "{\"status\":\"ok\",\"mqtt\":{\"host\":\"evotomasyon.gudeteknoloji.com.tr\",\"port\":8884,\"username\":\"d_h_0123456789abcdef\","
      "\"password\":\"p@ss w0rd!\"}}";
  TEST_ASSERT_TRUE(parseResponse(200, ok, c) == Result::OK);
  TEST_ASSERT_EQUAL_STRING("evotomasyon.gudeteknoloji.com.tr", c.host);
  TEST_ASSERT_EQUAL_UINT(8884, c.port);
  TEST_ASSERT_EQUAL_STRING("d_h_0123456789abcdef", c.user);
  TEST_ASSERT_EQUAL_STRING("p@ss w0rd!", c.pass);
  const char* bad[] = {
      "{\"status\":\"pending\",\"mqtt\":{\"host\":\"a.b\",\"port\":1,\"username\":\"u\",\"password\":\"p\"}}",
      "{\"status\":\"ok\"}",
      "{\"status\":\"ok\",\"mqtt\":{\"host\":\"a b\",\"port\":1,\"username\":\"u\",\"password\":\"p\"}}",
      "{\"status\":\"ok\",\"mqtt\":{\"host\":\"-a.b\",\"port\":1,\"username\":\"u\",\"password\":\"p\"}}",
      "{\"status\":\"ok\",\"mqtt\":{\"host\":\"a.b\",\"port\":0,\"username\":\"u\",\"password\":\"p\"}}",
      "{\"status\":\"ok\",\"mqtt\":{\"host\":\"a.b\",\"port\":70000,\"username\":\"u\",\"password\":\"p\"}}",
      "{\"status\":\"ok\",\"mqtt\":{\"host\":\"a.b\",\"port\":\"8884\",\"username\":\"u\",\"password\":\"p\"}}",
      "{\"status\":\"ok\",\"mqtt\":{\"host\":\"a.b\",\"port\":1,\"username\":\"u s\",\"password\":\"p\"}}",
      "{\"status\":\"ok\",\"mqtt\":{\"host\":\"a.b\",\"port\":1,\"username\":\"\",\"password\":\"p\"}}",
      "{\"status\":\"ok\",\"mqtt\":{\"host\":\"a.b\",\"port\":1,\"username\":\"u\",\"password\":\"\"}}",
      "{\"status\":\"ok\",\"mqtt\":{\"host\":\"a.b\",\"port\":1,\"username\":\"u\"}}",
      "not json",
  };
  for (const char* b : bad) TEST_ASSERT_TRUE_MESSAGE(parseResponse(200, b, c) == Result::BAD_RESPONSE, b);
  char longUser[80];
  memset(longUser, 'u', 48);
  longUser[48] = 0;   // 48 > 47
  char body[256];
  snprintf(body, sizeof(body), "{\"status\":\"ok\",\"mqtt\":{\"host\":\"a.b\",\"port\":1,\"username\":\"%s\",\"password\":\"p\"}}", longUser);
  TEST_ASSERT_TRUE(parseResponse(200, body, c) == Result::BAD_RESPONSE);
}

// Sahip karari (2026-10-09): bootstrap yaniti da panoyu yabanci bir sunucuya YONLENDIREMEZ. Sozdizimi gecerli ama derleme izin listesinde
// (DEFAULT_MQTT_SERVER + AHBU_MQTT_HOST_ALLOW) olmayan host BAD_RESPONSE; varsayilan sunucu (buyuk/kucuk harf duyarsiz) kabul edilir.
void test_response_host_must_be_allowlisted(void) {
  Creds c;
  const char* foreign[] = {
      "{\"status\":\"ok\",\"mqtt\":{\"host\":\"evil.example\",\"port\":8884,\"username\":\"u\",\"password\":\"p\"}}",
      "{\"status\":\"ok\",\"mqtt\":{\"host\":\"evotomasyon.gudeteknoloji.com.tr.evil.example\",\"port\":8884,\"username\":\"u\","
      "\"password\":\"p\"}}",
  };
  for (const char* b : foreign) {
    TEST_ASSERT_TRUE_MESSAGE(parseResponse(200, b, c) == Result::BAD_RESPONSE, b);
    TEST_ASSERT_EQUAL_UINT8(0, (uint8_t)c.host[0]);   // kimlik doldurulmaz
  }
  const char* upper = "{\"status\":\"ok\",\"mqtt\":{\"host\":\"EVOTOMASYON.gudeteknoloji.com.tr\",\"port\":8884,\"username\":\"u\",\"password\":\"p\"}}";
  TEST_ASSERT_TRUE(parseResponse(200, upper, c) == Result::OK);
}

int main(int, char**) {
  UNITY_BEGIN();
  RUN_TEST(test_sign_string_and_body_format);
  RUN_TEST(test_trigger_conditions);
  RUN_TEST(test_backoff_per_result_and_status_text);
  RUN_TEST(test_idle_fsm_polled_for_49_days_never_stalls);
  RUN_TEST(test_response_parsing);
  RUN_TEST(test_response_host_must_be_allowlisted);
  return UNITY_END();
}
