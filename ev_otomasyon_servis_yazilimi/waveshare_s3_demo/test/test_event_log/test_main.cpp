// EventOutbox LAN olay halkasi (src/events/EventOutbox.h; GET /api/events?after=<eid>, spec 3.5 [B16]) birim testleri. SAF MANTIK.
// Kapsam: son 32 olayin kopyasi (onaylanmislar dahil, outbox'tan bagimsiz), en eskiden yeniye sira, "after" eid'inden sonrakiler,
// bilinmeyen/baska acilisin eid'i -> bastan, taşmada en eskiler duser, JSON outbox yayini ile ayni bicim.
#include <unity.h>
#include <stdint.h>
#include <string.h>
#include "events/EventOutbox.h"

using namespace safety;

void setUp(void) {}
void tearDown(void) {}

static Event ev(EvType t, uint8_t zone = 1) {
  Event e;
  memset(&e, 0, sizeof(e));
  e.type = (uint8_t)t;
  e.zone = zone;
  e.atUp = 10;
  return e;
}

static void test_log_keeps_acked_events(void) {
  EventOutbox o;
  o.begin(0x9f3a11c0u);
  char eid[EID_LEN];
  o.push(ev(EvType::ALARM_RAISED), eid);
  TEST_ASSERT_EQUAL_STRING("9f3a11c0-1", eid);
  TEST_ASSERT_TRUE(o.ack(eid));
  TEST_ASSERT_EQUAL_UINT8(0, o.count());
  TEST_ASSERT_EQUAL_UINT8(1, o.logCount());
  char buf[EVENT_JSON_MAX];
  const size_t n = o.logJson(0, "AHBU-S3-0A0010", 7, buf, sizeof(buf));
  TEST_ASSERT_TRUE(n > 0);
  TEST_ASSERT_NOT_NULL(strstr(buf, "\"eid\":\"9f3a11c0-1\""));
  TEST_ASSERT_NOT_NULL(strstr(buf, "\"type\":\"alarm_raised\""));
}

static void test_log_after_and_unknown_eid(void) {
  EventOutbox o;
  o.begin(0x01020304u);
  char eid[EID_LEN];
  for (int i = 0; i < 5; i++) o.push(ev(EvType::ACTUATOR_CHANGED), eid);
  TEST_ASSERT_EQUAL_UINT8(0, o.logAfter(nullptr));
  TEST_ASSERT_EQUAL_UINT8(0, o.logAfter(""));
  TEST_ASSERT_EQUAL_UINT8(3, o.logAfter("01020304-3"));      // 4. ve 5. olay
  TEST_ASSERT_EQUAL_UINT8(5, o.logAfter("01020304-5"));      // yeni olay yok
  TEST_ASSERT_EQUAL_UINT8(0, o.logAfter("deadbeef-3"));      // baska acilis/pano: bastan
  TEST_ASSERT_EQUAL_UINT8(0, o.logAfter("01020304-99"));     // bilinmeyen: bastan
  char buf[EVENT_JSON_MAX];
  o.logJson(3, "u", 1, buf, sizeof(buf));
  TEST_ASSERT_NOT_NULL(strstr(buf, "\"eid\":\"01020304-4\""));
}

static void test_log_ring_drops_oldest(void) {
  EventOutbox o;
  o.begin(0xAABBCCDDu);
  char eid[EID_LEN];
  for (int i = 0; i < 40; i++) {
    o.push(ev(EvType::SENSOR_FAULT), eid);
    o.ack(eid);
  }
  TEST_ASSERT_EQUAL_UINT8(EventOutbox::LOG_CAP, o.logCount());
  char buf[EVENT_JSON_MAX];
  o.logJson(0, "u", 1, buf, sizeof(buf));
  TEST_ASSERT_NOT_NULL(strstr(buf, "\"eid\":\"aabbccdd-9\""));   // 1..8 dustu
  o.logJson(EventOutbox::LOG_CAP - 1, "u", 1, buf, sizeof(buf));
  TEST_ASSERT_NOT_NULL(strstr(buf, "\"eid\":\"aabbccdd-40\""));
  TEST_ASSERT_EQUAL_UINT8(0, (uint8_t)o.logJson(EventOutbox::LOG_CAP, "u", 1, buf, sizeof(buf)));
  TEST_ASSERT_EQUAL_UINT8(EventOutbox::LOG_CAP, o.logAfter("aabbccdd-40"));
  TEST_ASSERT_EQUAL_UINT8(0, o.logAfter("aabbccdd-3"));         // halkadan dusmus: bastan
}

static void test_log_json_matches_outbox_json(void) {
  EventOutbox o;
  o.begin(0x11111111u);
  char eid[EID_LEN];
  Event e = ev(EvType::TEST_RESULT, 2);
  e.flag = 1;
  e.val = 420;
  o.push(e, eid);
  char a[EVENT_JSON_MAX], b[EVENT_JSON_MAX];
  int slot = -1;
  for (int i = 0; i < EventOutbox::CAP; i++) if (o.at(i)) slot = i;
  TEST_ASSERT_TRUE(o.toJson(slot, "U", 3, a, sizeof(a)) > 0);
  TEST_ASSERT_TRUE(o.logJson(0, "U", 3, b, sizeof(b)) > 0);
  TEST_ASSERT_EQUAL_STRING(a, b);
}

int main(int, char**) {
  UNITY_BEGIN();
  RUN_TEST(test_log_keeps_acked_events);
  RUN_TEST(test_log_after_and_unknown_eid);
  RUN_TEST(test_log_ring_drops_oldest);
  RUN_TEST(test_log_json_matches_outbox_json);
  return UNITY_END();
}
