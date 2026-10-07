// ValveGuard (src/safety/ValveGuard.h) birim testleri. SAF MANTIK.
// Kapsam (spec 5.1.5 [Y-8][B7], WP-F3): guvenli tutma maskeleri (yalniz KAPALI komutlu vanalar; iki roleli vanada AC rolesi 0; guvenli
// kipte kilit maskesi), yerel 8 rolenin DONANIM okumasina gore duzeltme plani (DEENERGIZE_TO_CLOSE acik kaldiysa KAPAT, ENERGIZE_TO_CLOSE
// enerjisizse KUR; panjur cifti bitleri asla KURULMAZ; dayatilmayan bitlere dokunulmaz), ek modulde yalniz loop acliginda (1000 ms tur
// sayaci ilerlemedi) ve en cok 1 sn'de bir yazim; millis() tasmasi.
#include <unity.h>
#include <stdint.h>
#include <string.h>
#include "actuators/ActuatorTypes.h"
#include "actuators/ActuatorMap.h"
#include "safety/ValveGuard.h"

using namespace safety;

void setUp(void) {}
void tearDown(void) {}

static ActuatorConfig valve(uint8_t relay, CloseMode m, Medium med = Medium::WATER) {
  ActuatorConfig a;
  memset(&a, 0, sizeof(a));
  a.relay = relay;
  a.kind = (uint8_t)ActKind::VALVE;
  a.close_mode = (uint8_t)m;
  a.medium = (uint8_t)med;
  a.zone_mask = 0x01;
  return a;
}

static ActuatorConfig siren(uint8_t relay) {
  ActuatorConfig a;
  memset(&a, 0, sizeof(a));
  a.relay = relay;
  a.kind = (uint8_t)ActKind::SIREN;
  a.zone_mask = 0x01;
  a.run_limit_s = 180;
  return a;
}

static ActuatorConfig pulse(uint8_t closeRelay, uint8_t openRelay) {
  ActuatorConfig a = valve(closeRelay, CloseMode::PULSE_TWO_RELAY);
  a.relay2 = openRelay;
  a.run_limit_s = 15;
  return a;
}

static uint64_t bit(uint8_t relay1) { return 1ULL << (relay1 - 1); }

static void test_hold_masks_only_closed_valves(void) {
  const ActuatorConfig a[5] = {valve(1, CloseMode::ENERGIZE_TO_CLOSE), valve(2, CloseMode::DEENERGIZE_TO_CLOSE),
                               valve(3, CloseMode::ENERGIZE_TO_CLOSE), siren(4), valve(12, CloseMode::ENERGIZE_TO_CLOSE)};
  uint64_t as = 0, lv = 0;
  // vana 0, 1 ve 4 KAPALI komutlu; vana 2 acik; siren hicbir zaman tutulmaz
  safeHoldMasks(a, 5, (uint16_t)0x13, 0, 0, as, lv);
  TEST_ASSERT_EQUAL_HEX64(bit(1) | bit(2) | bit(12), as);
  TEST_ASSERT_EQUAL_HEX64(bit(1) | bit(12), lv);              // E2C: kapali = enerjili; D2C: kapali = enerjisiz
  safeHoldMasks(a, 5, 0, 0, 0, as, lv);
  TEST_ASSERT_EQUAL_HEX64(0, as);
  TEST_ASSERT_EQUAL_HEX64(0, lv);
}

static void test_hold_masks_pulse_valve_keeps_open_relay_off(void) {
  const ActuatorConfig a[1] = {pulse(5, 6)};
  uint64_t as = 0, lv = 0;
  safeHoldMasks(a, 1, 0x01, 0, 0, as, lv);
  TEST_ASSERT_EQUAL_HEX64(bit(6), as);                         // AC rolesi 0'a tutulur; KAPAT rolesinin darbesine dokunulmaz
  TEST_ASSERT_EQUAL_HEX64(0, lv);
}

static void test_hold_masks_merge_latch_masks(void) {
  // guvenli kip: kilit kaydindaki maske yapilandirmadan bagimsiz EZER (eylemci tablosu bos olsa da)
  uint64_t as = 0, lv = 0;
  safeHoldMasks(nullptr, 0, 0, bit(3) | bit(4), bit(3), as, lv);
  TEST_ASSERT_EQUAL_HEX64(bit(3) | bit(4), as);
  TEST_ASSERT_EQUAL_HEX64(bit(3), lv);
  const ActuatorConfig a[1] = {valve(3, CloseMode::DEENERGIZE_TO_CLOSE)};
  safeHoldMasks(a, 1, 0x01, bit(3), bit(3), as, lv);          // kilit seviyesi kazanir
  TEST_ASSERT_EQUAL_HEX64(bit(3), as);
  TEST_ASSERT_EQUAL_HEX64(bit(3), lv);
}

static void test_local_plan_corrects_both_directions(void) {
  const uint64_t as = bit(1) | bit(2);
  const uint64_t lv = bit(1);                                  // role 1 enerjili (E2C kapali), role 2 enerjisiz (D2C kapali)
  LocalGuardPlan p = planLocalGuard(as, lv, 0x00, 0);
  TEST_ASSERT_EQUAL_HEX8(0x01, p.setBits);                     // cip sifirlandi: E2C vana enerjisiz -> KUR
  TEST_ASSERT_EQUAL_HEX8(0x00, p.clearBits);
  p = planLocalGuard(as, lv, 0x03, 0);
  TEST_ASSERT_EQUAL_HEX8(0x02, p.clearBits);                   // D2C vana acik kaldi -> KAPAT
  TEST_ASSERT_EQUAL_HEX8(0x00, p.setBits);
  p = planLocalGuard(as, lv, 0x01, 0);
  TEST_ASSERT_EQUAL_HEX8(0x00, p.clearBits);                   // tutarli: hicbir sey yapilmaz
  TEST_ASSERT_EQUAL_HEX8(0x00, p.setBits);
}

static void test_local_plan_never_touches_unasserted_bits(void) {
  // dayatilmayan roleler (lamba/panjur) donanimda ne olursa olsun degismez
  LocalGuardPlan p = planLocalGuard(bit(5), bit(5), 0xEF, 0);
  TEST_ASSERT_EQUAL_HEX8(0x10, p.setBits);
  TEST_ASSERT_EQUAL_HEX8(0x00, p.clearBits);
  p = planLocalGuard(0, 0, 0xFF, 0);
  TEST_ASSERT_EQUAL_HEX8(0x00, p.setBits | p.clearBits);
  // ek modul bitleri yerel plana girmez
  p = planLocalGuard(bit(9) | bit(40), bit(9) | bit(40), 0x00, 0);
  TEST_ASSERT_EQUAL_HEX8(0x00, p.setBits | p.clearBits);
}

static void test_local_plan_rejects_shutter_pairs(void) {
  // TCA_SetSafeBits panjur cifti bitlerini ASLA kurmaz (interlock bozulamaz); kapatma serbesttir
  LocalGuardPlan p = planLocalGuard(bit(1) | bit(3), bit(1) | bit(3), 0x00, 0x01);
  TEST_ASSERT_EQUAL_HEX8(0x04, p.setBits);
  p = planLocalGuard(bit(1), 0, 0x01, 0x01);
  TEST_ASSERT_EQUAL_HEX8(0x01, p.clearBits);
}

static void test_ext_pacer_writes_only_when_loop_starves(void) {
  ExtGuardPacer pc;
  uint32_t t = 1000;
  pc.beat(1, t);
  for (int i = 0; i < 40; i++) {                               // loop her 50 ms'de tur sayacini artiriyor: yazim yok
    t += 50;
    pc.beat((uint32_t)(2 + i), t);
    TEST_ASSERT_FALSE(pc.due(t));
  }
  const uint32_t lastBeat = 41;
  t += 999;
  pc.beat(lastBeat, t);
  TEST_ASSERT_FALSE(pc.due(t));                                // 999 ms aclik: henuz degil
  t += 1;
  pc.beat(lastBeat, t);
  TEST_ASSERT_TRUE(pc.due(t));                                 // 1000 ms: yaz
  pc.wrote(t);
  t += 500;
  pc.beat(lastBeat, t);
  TEST_ASSERT_FALSE(pc.due(t));                                // hiz siniri: en cok 1 sn'de bir
  t += 500;
  pc.beat(lastBeat, t);
  TEST_ASSERT_TRUE(pc.due(t));
  pc.wrote(t);
  t += 10;
  pc.beat(lastBeat + 1, t);                                    // loop geri geldi
  TEST_ASSERT_FALSE(pc.due(t));
  t += 2000;
  pc.beat(lastBeat + 1, t);                                    // yeniden aclik: 2 sn sonra yaz (son yazim da > 1 sn once)
  TEST_ASSERT_TRUE(pc.due(t));
}

static void test_ext_pacer_millis_rollover(void) {
  ExtGuardPacer pc;
  uint32_t t = 0xFFFFFE00u;
  pc.beat(7, t);
  t += 999;                                                    // tasma siniri gecildi
  pc.beat(7, t);
  TEST_ASSERT_FALSE(pc.due(t));
  t += 1;
  pc.beat(7, t);
  TEST_ASSERT_TRUE(pc.due(t));
  pc.wrote(t);
  t += 999;
  TEST_ASSERT_FALSE(pc.due(t));
  t += 1;
  TEST_ASSERT_TRUE(pc.due(t));
}

static void test_ext_write_split(void) {
  uint32_t on = 0, off = 0;
  extGuardBits(bit(1) | bit(9) | bit(10) | bit(40), bit(9) | bit(1), on, off);
  TEST_ASSERT_EQUAL_HEX32(0x00000001u, on);                    // role 9 -> ek kanal 1
  TEST_ASSERT_EQUAL_HEX32(0x80000002u, off);                   // role 10 ve 40
}

int main(int, char**) {
  UNITY_BEGIN();
  RUN_TEST(test_hold_masks_only_closed_valves);
  RUN_TEST(test_hold_masks_pulse_valve_keeps_open_relay_off);
  RUN_TEST(test_hold_masks_merge_latch_masks);
  RUN_TEST(test_local_plan_corrects_both_directions);
  RUN_TEST(test_local_plan_never_touches_unasserted_bits);
  RUN_TEST(test_local_plan_rejects_shutter_pairs);
  RUN_TEST(test_ext_pacer_writes_only_when_loop_starves);
  RUN_TEST(test_ext_pacer_millis_rollover);
  RUN_TEST(test_ext_write_split);
  return UNITY_END();
}
