// ContactBus (src/sensors/ContactBus.h) birim testleri: kapı/pencere kenarlarının çok tüketicili halkası (Faz 2 tasarımı F2.B.5).
#include <unity.h>
#include <stdint.h>
#include <string.h>
#include "sensors/ContactBus.h"

using namespace safety;

void setUp(void) {}
void tearDown(void) {}

void test_first_observation_is_not_an_edge(void) {
  ContactBus bus;
  ContactBus::Cursor c = bus.cursor();
  bus.observe(0, (uint8_t)SensorKind::DOOR, 1, true, true, 100);
  ContactEdge e;
  TEST_ASSERT_FALSE(bus.read(c, e));
  TEST_ASSERT_TRUE(bus.known(0));
  TEST_ASSERT_TRUE(bus.isOpen(0));
  bus.observe(0, (uint8_t)SensorKind::DOOR, 1, true, true, 200);   // aynı seviye: kenar yok
  TEST_ASSERT_FALSE(bus.read(c, e));
  bus.observe(0, (uint8_t)SensorKind::DOOR, 1, true, false, 300);
  TEST_ASSERT_TRUE(bus.read(c, e));
  TEST_ASSERT_EQUAL_UINT8(0, e.slot);
  TEST_ASSERT_EQUAL_UINT8((uint8_t)SensorKind::DOOR, e.kind);
  TEST_ASSERT_EQUAL_UINT8(1, e.zone);
  TEST_ASSERT_EQUAL_UINT8(0, e.open);
  TEST_ASSERT_EQUAL_UINT32(300, e.at_ms);
  TEST_ASSERT_FALSE(bus.read(c, e));
}

void test_only_door_and_window_edges(void) {
  ContactBus bus;
  ContactBus::Cursor c = bus.cursor();
  const uint8_t kinds[] = {(uint8_t)SensorKind::MOTION, (uint8_t)SensorKind::WATER, (uint8_t)SensorKind::GAS,
                           (uint8_t)SensorKind::ARM_KEY, (uint8_t)SensorKind::GENERIC};
  for (uint8_t i = 0; i < sizeof(kinds); i++) {
    bus.observe(i, kinds[i], 1, true, false, 10);
    bus.observe(i, kinds[i], 1, true, true, 20);
  }
  ContactEdge e;
  TEST_ASSERT_FALSE(bus.read(c, e));
  bus.observe(9, (uint8_t)SensorKind::WINDOW, 3, true, false, 10);
  bus.observe(9, (uint8_t)SensorKind::WINDOW, 3, true, true, 20);
  TEST_ASSERT_TRUE(bus.read(c, e));
  TEST_ASSERT_EQUAL_UINT8(1, e.open);
  TEST_ASSERT_EQUAL_UINT8(3, e.zone);
}

void test_not_ok_is_unknown_without_edge(void) {
  ContactBus bus;
  ContactBus::Cursor c = bus.cursor();
  bus.observe(2, (uint8_t)SensorKind::WINDOW, 1, true, false, 10);
  bus.observe(2, (uint8_t)SensorKind::WINDOW, 1, false, true, 20);   // okunamıyor: bilinmeyen
  TEST_ASSERT_FALSE(bus.known(2));
  ContactEdge e;
  TEST_ASSERT_FALSE(bus.read(c, e));
  bus.observe(2, (uint8_t)SensorKind::WINDOW, 1, true, true, 30);    // yeniden ilk gözlem: kenar değil
  TEST_ASSERT_FALSE(bus.read(c, e));
  TEST_ASSERT_TRUE(bus.isOpen(2));
}

void test_ring_overflow_drops_oldest(void) {
  ContactBus bus;
  ContactBus::Cursor slow = bus.cursor();
  bus.observe(0, (uint8_t)SensorKind::DOOR, 1, true, false, 0);
  for (uint32_t k = 1; k <= 20; k++) bus.observe(0, (uint8_t)SensorKind::DOOR, 1, true, (k & 1) != 0, k * 10);
  ContactEdge e;
  uint32_t n = 0, first = 0;
  while (bus.read(slow, e)) {
    if (n == 0) first = e.at_ms;
    n++;
  }
  TEST_ASSERT_EQUAL_UINT32(ContactBus::CAP, n);
  TEST_ASSERT_EQUAL_UINT32(50, first);            // 20 kenardan en eski 4'ü düştü (10..40)
  TEST_ASSERT_EQUAL_UINT32(4, bus.dropped());
}

void test_multiple_readers_independent(void) {
  ContactBus bus;
  ContactBus::Cursor a = bus.cursor();
  bus.observe(1, (uint8_t)SensorKind::WINDOW, 2, true, false, 0);
  bus.observe(1, (uint8_t)SensorKind::WINDOW, 2, true, true, 10);
  ContactBus::Cursor b = bus.cursor();               // geç gelen okuyucu yalnız sonrakileri görür
  bus.observe(1, (uint8_t)SensorKind::WINDOW, 2, true, false, 20);
  ContactEdge e;
  TEST_ASSERT_TRUE(bus.read(a, e));
  TEST_ASSERT_EQUAL_UINT32(10, e.at_ms);
  TEST_ASSERT_TRUE(bus.read(a, e));
  TEST_ASSERT_EQUAL_UINT32(20, e.at_ms);
  TEST_ASSERT_FALSE(bus.read(a, e));
  TEST_ASSERT_TRUE(bus.read(b, e));
  TEST_ASSERT_EQUAL_UINT32(20, e.at_ms);
  TEST_ASSERT_FALSE(bus.read(b, e));
}

void test_zone_window_open_for(void) {
  ContactBus bus;
  bus.observe(4, (uint8_t)SensorKind::WINDOW, 2, true, false, 0);
  bus.observe(5, (uint8_t)SensorKind::DOOR, 2, true, true, 0);       // kapı sayılmaz
  TEST_ASSERT_FALSE(bus.zoneWindowOpenFor(2, 100000, 60000));
  bus.observe(4, (uint8_t)SensorKind::WINDOW, 2, true, true, 1000);
  TEST_ASSERT_FALSE(bus.zoneWindowOpenFor(2, 60999, 60000));
  TEST_ASSERT_TRUE(bus.zoneWindowOpenFor(2, 61000, 60000));
  TEST_ASSERT_FALSE(bus.zoneWindowOpenFor(1, 61000, 60000));
  bus.observe(4, (uint8_t)SensorKind::WINDOW, 2, true, false, 62000);
  TEST_ASSERT_FALSE(bus.zoneWindowOpenFor(2, 200000, 60000));
  // millis taşması
  bus.observe(4, (uint8_t)SensorKind::WINDOW, 2, true, true, 0xFFFFF000u);
  TEST_ASSERT_TRUE(bus.zoneWindowOpenFor(2, 0xFFFFF000u + 60000u, 60000));
}

void test_reset_forgets_levels(void) {
  ContactBus bus;
  ContactBus::Cursor c = bus.cursor();
  bus.observe(0, (uint8_t)SensorKind::DOOR, 1, true, false, 0);
  bus.reset();
  TEST_ASSERT_FALSE(bus.known(0));
  bus.observe(0, (uint8_t)SensorKind::DOOR, 1, true, true, 10);      // yapılandırma değişimi sonrası ilk gözlem
  ContactEdge e;
  TEST_ASSERT_FALSE(bus.read(c, e));
}

void test_feed_from_hub(void) {
  SensorConfig s[3];
  memset(s, 0, sizeof(s));
  s[0].src = (uint8_t)SensorSrc::DI; s[0].index = 1; s[0].kind = (uint8_t)SensorKind::DOOR; s[0].zone = 1; s[0].active_open = 1;
  s[0].flags = SF_REACT;
  s[1].src = (uint8_t)SensorSrc::DI; s[1].index = 2; s[1].kind = (uint8_t)SensorKind::WATER; s[1].zone = 1;
  s[1].flags = SF_REACT; s[1].confirm_ms = 1000;
  s[2].src = (uint8_t)SensorSrc::DI; s[2].index = 3; s[2].kind = (uint8_t)SensorKind::WINDOW; s[2].zone = 2; s[2].active_open = 1;
  s[2].flags = SF_REACT;
  SensorHub hub;
  hub.configure(s, 3, 0);
  ContactBus bus;
  ContactBus::Cursor c = bus.cursor();
  hub.update(0, true, true, 10);   // NC kapalı = kapalı
  hub.update(1, false, true, 10);
  hub.update(2, true, true, 10);
  hub.finish(10);
  feedContacts(hub, bus, 10);
  hub.update(0, false, true, 20);  // kapı açıldı
  hub.update(1, true, true, 20);
  hub.update(2, true, true, 20);
  hub.finish(20);
  feedContacts(hub, bus, 20);
  ContactEdge e;
  TEST_ASSERT_TRUE(bus.read(c, e));
  TEST_ASSERT_EQUAL_UINT8(0, e.slot);
  TEST_ASSERT_EQUAL_UINT8(1, e.open);
  TEST_ASSERT_FALSE(bus.read(c, e));
}

int main(int, char**) {
  UNITY_BEGIN();
  RUN_TEST(test_first_observation_is_not_an_edge);
  RUN_TEST(test_only_door_and_window_edges);
  RUN_TEST(test_not_ok_is_unknown_without_edge);
  RUN_TEST(test_ring_overflow_drops_oldest);
  RUN_TEST(test_multiple_readers_independent);
  RUN_TEST(test_zone_window_open_for);
  RUN_TEST(test_reset_forgets_levels);
  RUN_TEST(test_feed_from_hub);
  return UNITY_END();
}
