// EventOutbox (src/events/EventOutbox.h) birim testleri. SAF MANTIK.
// Kapsam (spec 3.4, 5.5): eid bicimi <bn>-<n>, yeniden deneme plani (5/10/20/40 sn, sonra 60 sn), yeniden baglanma penceresi
// (1500 ms) [D4], ack ile silme, coklu eid, tasmada atilma onceligi, en kotu durum yuk boyutu, JSON bicimi.
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
  return e;
}

void test_eid_format_and_counter(void) {
  EventOutbox o;
  o.begin(0x9f3a11c0u);
  char eid[EID_LEN];
  TEST_ASSERT_TRUE(o.push(ev(EvType::ALARM_RAISED), eid));
  TEST_ASSERT_EQUAL_STRING("9f3a11c0-1", eid);
  TEST_ASSERT_TRUE(o.push(ev(EvType::ALARM_CLEARED), eid));
  TEST_ASSERT_EQUAL_STRING("9f3a11c0-2", eid);
  o.begin(0x0000000Au);
  TEST_ASSERT_TRUE(o.push(ev(EvType::ALARM_RAISED), eid));
  TEST_ASSERT_EQUAL_STRING("0000000a-1", eid);           // her acilista yeni nonce, sayac 1'den
  TEST_ASSERT_EQUAL_UINT8(1, o.count());                  // RAM tamponu acilista bosalir
}

void test_counter_wraps_to_five_digits(void) {
  EventOutbox o;
  o.begin(1);
  o.setNextN(99999);
  char eid[EID_LEN];
  o.push(ev(EvType::ACTUATOR_CHANGED), eid);
  TEST_ASSERT_EQUAL_STRING("00000001-99999", eid);
  o.push(ev(EvType::ACTUATOR_CHANGED), eid);
  TEST_ASSERT_EQUAL_STRING("00000001-1", eid);
  TEST_ASSERT_TRUE(strlen("ffffffff-99999") < EID_LEN);
}

void test_retry_schedule(void) {
  EventOutbox o;
  o.begin(1);
  char eid[EID_LEN];
  o.push(ev(EvType::ALARM_RAISED), eid);
  const uint32_t conn = 0;
  uint32_t t = 2000;
  int s = o.nextDue(t, conn);
  TEST_ASSERT_EQUAL_INT(0, s);
  const uint32_t gaps[] = {5000, 10000, 20000, 40000, 60000, 60000, 60000};
  for (unsigned k = 0; k < sizeof(gaps) / sizeof(gaps[0]); k++) {
    o.markSent(s, t);
    TEST_ASSERT_EQUAL_INT(-1, o.nextDue(t + gaps[k] - 1, conn));
    t += gaps[k];
    s = o.nextDue(t, conn);
    TEST_ASSERT_EQUAL_INT(0, s);
  }
}

void test_reconnect_window_blocks_drain(void) {
  EventOutbox o;
  o.begin(1);
  char eid[EID_LEN];
  o.push(ev(EvType::ALARM_RAISED), eid);
  TEST_ASSERT_EQUAL_INT(-1, o.nextDue(10000 + 1499, 10000));   // aboneligin ilk 1500 ms'i: komutlar (ack) yok sayiliyor [D4]
  TEST_ASSERT_EQUAL_INT(0, o.nextDue(10000 + 1500, 10000));
  // millis tasmasinda da dogru
  TEST_ASSERT_EQUAL_INT(-1, o.nextDue(0x00000100u, 0xFFFFFF00u));
  TEST_ASSERT_EQUAL_INT(0, o.nextDue(0x00000600u + 1000, 0xFFFFFF00u));
}

void test_ack_removes_and_multi_ack(void) {
  EventOutbox o;
  o.begin(0xabcdef01u);
  char e1[EID_LEN], e2[EID_LEN], e3[EID_LEN];
  o.push(ev(EvType::ALARM_RAISED), e1);
  o.push(ev(EvType::SENSOR_FAULT), e2);
  o.push(ev(EvType::ALARM_CLEARED), e3);
  TEST_ASSERT_EQUAL_UINT8(3, o.count());
  TEST_ASSERT_TRUE(o.ack(e2));
  TEST_ASSERT_FALSE(o.ack(e2));                                // ikinci ack etkisiz
  TEST_ASSERT_FALSE(o.ack("abcdef01-99"));                     // bilinmeyen
  TEST_ASSERT_FALSE(o.ack("12345678-1"));                      // baska panonun/acilisin eid'i
  TEST_ASSERT_EQUAL_UINT8(2, o.count());
  const char* list[3] = {e1, e3, "x"};
  TEST_ASSERT_EQUAL_UINT8(2, o.ackMany(list, 3));
  TEST_ASSERT_EQUAL_UINT8(0, o.count());
  TEST_ASSERT_EQUAL_INT(-1, o.nextDue(100000, 0));
}

void test_oldest_due_first(void) {
  EventOutbox o;
  o.begin(1);
  char eid[EID_LEN];
  o.push(ev(EvType::ALARM_RAISED), eid);
  o.push(ev(EvType::ACTUATOR_CHANGED), eid);
  int a = o.nextDue(5000, 0);
  o.markSent(a, 5000);
  int b = o.nextDue(5000, 0);
  TEST_ASSERT_NOT_EQUAL(a, b);
  TEST_ASSERT_EQUAL_UINT8((uint8_t)EvType::ALARM_RAISED, o.at(a)->type);
  TEST_ASSERT_EQUAL_UINT8((uint8_t)EvType::ACTUATOR_CHANGED, o.at(b)->type);
}

void test_overflow_drop_priority(void) {
  EventOutbox o;
  o.begin(1);
  char eid[EID_LEN];
  // 1 actuator_changed + 2 *_cleared + 1 sensor_fault + 12 alarm_raised = 16 (dolu)
  o.push(ev(EvType::ALARM_RAISED), eid);
  char firstAlarm[EID_LEN];
  strcpy(firstAlarm, eid);
  o.push(ev(EvType::ACTUATOR_CHANGED), eid);
  o.push(ev(EvType::ALARM_CLEARED), eid);
  o.push(ev(EvType::VALVE_FAULT_CLEARED), eid);
  o.push(ev(EvType::SENSOR_FAULT), eid);
  for (int i = 0; i < 11; i++) o.push(ev(EvType::ALARM_RAISED), eid);
  TEST_ASSERT_EQUAL_UINT8(16, o.count());
  TEST_ASSERT_EQUAL_UINT8(1, o.countOf(EvType::ACTUATOR_CHANGED));
  o.push(ev(EvType::VALVE_FAULT), eid);                       // once en eski actuator_changed atilir
  TEST_ASSERT_EQUAL_UINT8(0, o.countOf(EvType::ACTUATOR_CHANGED));
  o.push(ev(EvType::VALVE_FAULT), eid);                       // sonra en eski *_cleared (alarm_cleared)
  TEST_ASSERT_EQUAL_UINT8(0, o.countOf(EvType::ALARM_CLEARED));
  TEST_ASSERT_EQUAL_UINT8(1, o.countOf(EvType::VALVE_FAULT_CLEARED));
  o.push(ev(EvType::VALVE_FAULT), eid);
  TEST_ASSERT_EQUAL_UINT8(0, o.countOf(EvType::VALVE_FAULT_CLEARED));
  o.push(ev(EvType::VALVE_FAULT), eid);                       // sonra alarm disi (sensor_fault)
  TEST_ASSERT_EQUAL_UINT8(0, o.countOf(EvType::SENSOR_FAULT));
  TEST_ASSERT_TRUE(o.ack(firstAlarm));                         // en eski alarm hala duruyor
  o.push(ev(EvType::ALARM_RAISED), eid);                       // bosluk acildi
  TEST_ASSERT_EQUAL_UINT8(16, o.count());
  o.push(ev(EvType::ALARM_RAISED), eid);                       // yalniz alarm kaldi: en eski alarmin USTUNE yazilir
  TEST_ASSERT_EQUAL_UINT8(16, o.count());
  TEST_ASSERT_EQUAL_UINT32(1, o.overwrites());
}

void test_json_alarm_raised_exact(void) {
  EventOutbox o;
  o.begin(0x9f3a11c0u);
  o.setNextN(3);
  Event e = ev(EvType::ALARM_RAISED, 1);
  e.kinds = HZ_WATER;
  e.nsrcs = 1;
  e.srcs[0] = 3;
  e.atUp = 3000;
  e.atEpoch = 1791273000u;
  e.actClose = 0x0001;
  e.actOn = 0x0002;
  char eid[EID_LEN];
  o.push(e, eid);
  char buf[EVENT_JSON_MAX];
  size_t n = o.toJson(0, "AHBU-S3-0011", 57, buf, sizeof(buf));
  TEST_ASSERT_TRUE(n > 0);
  TEST_ASSERT_EQUAL_STRING(
      "{\"v\":1,\"uid\":\"AHBU-S3-0011\",\"eid\":\"9f3a11c0-3\",\"bn\":\"9f3a11c0\",\"boot\":57,\"n\":3,"
      "\"type\":\"alarm_raised\",\"zone\":1,\"kind\":\"water\",\"srcs\":[\"d3\"],\"at\":1791273000,\"at_up\":3000,"
      "\"actions\":[{\"a\":\"a1\",\"do\":\"close\"},{\"a\":\"a2\",\"do\":\"on\"}]}",
      buf);
  TEST_ASSERT_EQUAL_UINT32(strlen(buf), n);
}

void test_json_variants(void) {
  EventOutbox o;
  o.begin(1);
  char eid[EID_LEN], buf[EVENT_JSON_MAX];
  Event e = ev(EvType::TEST_RESULT, 2);
  e.flag = 1;
  e.sub = 1;                                                    // geri bildirim olculdu: fb_ms yazilir
  e.val = 4200;
  e.atUp = 10;                                                  // saat yok: "at" yazilmaz
  o.push(e, eid);
  o.toJson(0, "U", 1, buf, sizeof(buf));
  TEST_ASSERT_TRUE(strstr(buf, "\"type\":\"test_result\",\"zone\":2,\"ok\":true,\"fb_ms\":4200") != nullptr);
  TEST_ASSERT_TRUE(strstr(buf, "\"at\":") == nullptr);
  Event s = ev(EvType::SAFE_MODE, 0);
  s.sub = 2;                                                    // latch_orphan
  o.push(s, eid);
  o.toJson(1, "U", 1, buf, sizeof(buf));
  TEST_ASSERT_TRUE(strstr(buf, "\"type\":\"safe_mode\",\"reason\":\"latch_orphan\"") != nullptr);
  Event c = ev(EvType::CFG_CONFLICT, 0);
  c.rev = 12;
  c.crc = 0x9a3c11f0u;
  o.push(c, eid);
  o.toJson(2, "U", 1, buf, sizeof(buf));
  TEST_ASSERT_TRUE(strstr(buf, "\"type\":\"cfg_conflict\",\"rev\":12,\"crc\":\"9a3c11f0\"") != nullptr);
  Event p = ev(EvType::POLICY_CHANGED, 0);
  p.flag = 0;
  p.sub = 1;                                                    // lan
  o.push(p, eid);
  o.toJson(3, "U", 1, buf, sizeof(buf));
  TEST_ASSERT_TRUE(strstr(buf, "\"type\":\"policy_changed\",\"policy\":\"off\",\"via\":\"lan\"") != nullptr);
  TEST_ASSERT_EQUAL_UINT32(0, o.toJson(3, "U", 1, buf, 20));     // sigmiyor: 0, tasma yok
  TEST_ASSERT_EQUAL_UINT32(0, o.toJson(9, "U", 1, buf, sizeof(buf)));
}

// CONTRACTS 2.6: alarm olaylari (alarm_raised disinda) bolgenin alarm kimligini "aid" ile tasir (sunucu alarm satirini aid ile
// bulur); test_result geri bildirim yoksa fb_ms YAZMAZ (uygulama "gozle dogrulayin" der).
void test_json_aid_and_test_without_feedback(void) {
  EventOutbox o;
  o.begin(0x0badf00du);
  char eid[EID_LEN], buf[EVENT_JSON_MAX];
  Event c = ev(EvType::ALARM_CLEARED, 3);
  c.kinds = HZ_WATER;
  memcpy(c.aid, "9f3a11c0-3", 11);
  o.push(c, eid);
  o.toJson(0, "U", 1, buf, sizeof(buf));
  TEST_ASSERT_TRUE(strstr(buf, "\"type\":\"alarm_cleared\",\"zone\":3,\"kind\":\"water\",\"aid\":\"9f3a11c0-3\",\"at_up\":0}") != nullptr);
  Event r = ev(EvType::ALARM_RAISED, 1);                        // aid bos: anahtar yazilmaz (aid = olayin eid'si)
  o.push(r, eid);
  o.toJson(1, "U", 1, buf, sizeof(buf));
  TEST_ASSERT_TRUE(strstr(buf, "\"aid\"") == nullptr);
  Event t = ev(EvType::TEST_RESULT, 2);
  t.flag = 1;                                                   // sub = 0: geri bildirimsiz bolge
  o.push(t, eid);
  o.toJson(2, "U", 1, buf, sizeof(buf));
  TEST_ASSERT_TRUE(strstr(buf, "\"type\":\"test_result\",\"zone\":2,\"ok\":true,\"at_up\":0") != nullptr);
  TEST_ASSERT_TRUE(strstr(buf, "fb_ms") == nullptr);
}

void test_json_worst_case_size(void) {
  EventOutbox o;
  o.begin(0xffffffffu);
  o.setNextN(99999);
  Event e = ev(EvType::ALARM_RAISED, 4);
  e.kinds = HZ_GAS | HZ_WATER | HZ_SMOKE;
  e.nsrcs = 8;
  for (int i = 0; i < 8; i++) e.srcs[i] = (uint8_t)(0x80 | (9 + i));
  e.atUp = 0xFFFFFFFFu;
  e.atEpoch = 0xFFFFFFFFu;
  e.actClose = 0xFFFF;
  memcpy(e.aid, "ffffffff-99999", EID_LEN);                     // aid tasiyan turlerin ust siniri da kapsansin
  char eid[EID_LEN], buf[EVENT_JSON_MAX];
  o.push(e, eid);
  size_t n = o.toJson(0, "AHBU-S3-0123456789AB", 0xFFFFFFFFu, buf, sizeof(buf));
  TEST_ASSERT_TRUE(n > 0);
  TEST_ASSERT_TRUE(n < EVENT_JSON_MAX);
  TEST_ASSERT_TRUE(n <= 700);                                   // kopru 4 KB sinirinin cok altinda (bkz. uygulama notlari)
}

int main(int, char**) {
  UNITY_BEGIN();
  RUN_TEST(test_eid_format_and_counter);
  RUN_TEST(test_counter_wraps_to_five_digits);
  RUN_TEST(test_retry_schedule);
  RUN_TEST(test_reconnect_window_blocks_drain);
  RUN_TEST(test_ack_removes_and_multi_ack);
  RUN_TEST(test_oldest_due_first);
  RUN_TEST(test_overflow_drop_priority);
  RUN_TEST(test_json_alarm_raised_exact);
  RUN_TEST(test_json_variants);
  RUN_TEST(test_json_aid_and_test_without_feedback);
  RUN_TEST(test_json_worst_case_size);
  return UNITY_END();
}
