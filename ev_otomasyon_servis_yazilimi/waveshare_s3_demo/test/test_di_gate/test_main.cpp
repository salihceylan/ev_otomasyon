// ============================================================================
// DiGate (src/DiGate.h) birim testleri:  pio test -e native -f test_di_gate
//
// Kapsam: 60 ms kararlilik suzgeci (59/60/61 ms sinirlari, millis() tasmasi), cocuk kilidi YALNIZ BASMAYI
// engeller, birakma ASLA yutulmaz, kilitliyken hareket halindeki panjur DURDURULABILIR, "basis islendi mi"
// (acted) biti, kilit basili tutarken degisince bayat KAPAT uretilmemesi, ek modul (ext) girisleri.
// ============================================================================
#include <unity.h>
#include <stdint.h>
#include "DiGate.h"

using namespace digate;

void setUp(void) {}
void tearDown(void) {}

// Tam bir basma/birakma akisini surmek icin kucuk yardimci: kararli bir kenar uretene kadar ornekler.
static Edge settle(DiGate& g, uint8_t idx, bool level, uint32_t& t) {
  Edge e = g.sample(idx, level, t);          // degisimi kaydet
  for (int k = 0; k < 20 && e == EDGE_NONE; k++) {
    t += 10;
    e = g.sample(idx, level, t);
  }
  return e;
}

// ---------------------------------------------------------------- basma: kilit acik
void test_press_actions_when_unlocked(void) {
  DiGate g;
  Decision d = g.decide(0, EDGE_PRESS, MODE_TOGGLE, false, false);
  TEST_ASSERT_EQUAL_UINT8(RELAY_TOGGLE, d.action);
  TEST_ASSERT_FALSE(d.dropped);
  TEST_ASSERT_TRUE(g.acted(0));

  d = g.decide(1, EDGE_PRESS, MODE_MOMENTARY, false, false);
  TEST_ASSERT_EQUAL_UINT8(RELAY_ON, d.action);
  d = g.decide(2, EDGE_PRESS, MODE_SHUTTER_STEP, false, false);
  TEST_ASSERT_EQUAL_UINT8(SHUTTER_STEP, d.action);
  d = g.decide(3, EDGE_PRESS, MODE_SHUTTER_UP, false, false);
  TEST_ASSERT_EQUAL_UINT8(SHUTTER_UP, d.action);
  d = g.decide(3, EDGE_PRESS, MODE_SHUTTER_UP, false, true);                  // hareket var => dur
  TEST_ASSERT_EQUAL_UINT8(SHUTTER_STOP, d.action);
  d = g.decide(4, EDGE_PRESS, MODE_SHUTTER_DOWN, false, false);
  TEST_ASSERT_EQUAL_UINT8(SHUTTER_DOWN, d.action);
  d = g.decide(4, EDGE_PRESS, MODE_SHUTTER_DOWN, false, true);
  TEST_ASSERT_EQUAL_UINT8(SHUTTER_STOP, d.action);
}

void test_unknown_mode_does_nothing_and_is_not_acted(void) {
  DiGate g;
  Decision d = g.decide(0, EDGE_PRESS, 9, false, false);
  TEST_ASSERT_EQUAL_UINT8(NONE, d.action);
  TEST_ASSERT_FALSE(g.acted(0));
}

// ---------------------------------------------------------------- basma: kilit KAPALI degil (kilitli)
void test_locked_press_is_dropped_and_not_acted_for_every_mode_when_idle(void) {
  DiGate g;
  for (uint8_t mode = 0; mode <= MODE_SHUTTER_DOWN; mode++) {
    Decision d = g.decide(5, EDGE_PRESS, mode, true, false);
    TEST_ASSERT_EQUAL_UINT8(NONE, d.action);        // hareket BASLATMA/role/toggle engelli
    TEST_ASSERT_TRUE(d.dropped);                    // kullaniciya "engellendi" bip'i
    TEST_ASSERT_FALSE(g.acted(5));
  }
}

void test_locked_wall_switch_can_still_stop_a_moving_shutter(void) {
  // URUN KARARI: telefonla baslatilmis panjur kilitliyken duvardan DURDURULABILIR (sikisma riski).
  DiGate g;
  Decision d = g.decide(2, EDGE_PRESS, MODE_SHUTTER_STEP, true, true);
  TEST_ASSERT_EQUAL_UINT8(SHUTTER_STOP, d.action);
  TEST_ASSERT_FALSE(d.dropped);
  d = g.decide(3, EDGE_PRESS, MODE_SHUTTER_UP, true, true);
  TEST_ASSERT_EQUAL_UINT8(SHUTTER_STOP, d.action);
  d = g.decide(4, EDGE_PRESS, MODE_SHUTTER_DOWN, true, true);
  TEST_ASSERT_EQUAL_UINT8(SHUTTER_STOP, d.action);
}

void test_locked_shutter_buttons_never_start_motion(void) {
  DiGate g;
  TEST_ASSERT_EQUAL_UINT8(NONE, g.decide(2, EDGE_PRESS, MODE_SHUTTER_STEP, true, false).action);
  TEST_ASSERT_EQUAL_UINT8(NONE, g.decide(3, EDGE_PRESS, MODE_SHUTTER_UP, true, false).action);
  TEST_ASSERT_EQUAL_UINT8(NONE, g.decide(4, EDGE_PRESS, MODE_SHUTTER_DOWN, true, false).action);
}

void test_locked_toggle_and_momentary_stay_blocked_even_if_a_shutter_is_active(void) {
  DiGate g;
  Decision d = g.decide(0, EDGE_PRESS, MODE_TOGGLE, true, true);
  TEST_ASSERT_EQUAL_UINT8(NONE, d.action);
  TEST_ASSERT_TRUE(d.dropped);
  d = g.decide(1, EDGE_PRESS, MODE_MOMENTARY, true, true);
  TEST_ASSERT_EQUAL_UINT8(NONE, d.action);
  TEST_ASSERT_TRUE(d.dropped);
}

// ---------------------------------------------------------------- birakma: ASLA yutulmaz
void test_release_of_accepted_momentary_press_turns_relay_off(void) {
  DiGate g;
  g.decide(1, EDGE_PRESS, MODE_MOMENTARY, false, false);
  Decision d = g.decide(1, EDGE_RELEASE, MODE_MOMENTARY, false, false);
  TEST_ASSERT_EQUAL_UINT8(RELAY_OFF, d.action);
  TEST_ASSERT_FALSE(g.acted(1));                    // bit temizlendi
}

void test_lock_enabled_while_held_release_still_turns_off(void) {
  // Basma kilit ACIKKEN islendi (role ACILDI); basili tutarken kilit devreye girdi.
  DiGate g;
  Decision press = g.decide(1, EDGE_PRESS, MODE_MOMENTARY, false, false);
  TEST_ASSERT_EQUAL_UINT8(RELAY_ON, press.action);
  // Birakma: kilit artik ACIK ama KAPAT uretilmeli (eski kod yutup roleyi sonsuza dek acik birakiyordu)
  Decision rel = g.decide(1, EDGE_RELEASE, MODE_MOMENTARY, true, false);
  TEST_ASSERT_EQUAL_UINT8(RELAY_OFF, rel.action);
}

void test_press_dropped_by_lock_then_unlock_while_held_release_does_nothing(void) {
  // Kilitliyken basma reddedildi; basili tutarken kilit KALKTI; birakma bayat KAPAT uretmemeli
  // (uygulamadan acilmis bir lambayi sondurmesin).
  DiGate g;
  Decision press = g.decide(1, EDGE_PRESS, MODE_MOMENTARY, true, false);
  TEST_ASSERT_TRUE(press.dropped);
  Decision rel = g.decide(1, EDGE_RELEASE, MODE_MOMENTARY, false, false);
  TEST_ASSERT_EQUAL_UINT8(NONE, rel.action);
}

void test_release_without_any_press_does_nothing(void) {
  DiGate g;
  TEST_ASSERT_EQUAL_UINT8(NONE, g.decide(7, EDGE_RELEASE, MODE_MOMENTARY, false, false).action);
  TEST_ASSERT_EQUAL_UINT8(NONE, g.decide(7, EDGE_RELEASE, MODE_MOMENTARY, true, false).action);
}

void test_release_is_ignored_for_non_momentary_modes(void) {
  DiGate g;
  g.decide(0, EDGE_PRESS, MODE_TOGGLE, false, false);
  TEST_ASSERT_EQUAL_UINT8(NONE, g.decide(0, EDGE_RELEASE, MODE_TOGGLE, false, false).action);
  g.decide(2, EDGE_PRESS, MODE_SHUTTER_STEP, false, false);
  TEST_ASSERT_EQUAL_UINT8(NONE, g.decide(2, EDGE_RELEASE, MODE_SHUTTER_STEP, false, false).action);
  g.decide(3, EDGE_PRESS, MODE_SHUTTER_UP, false, false);
  TEST_ASSERT_EQUAL_UINT8(NONE, g.decide(3, EDGE_RELEASE, MODE_SHUTTER_UP, true, false).action);
  g.decide(4, EDGE_PRESS, MODE_SHUTTER_DOWN, false, false);
  TEST_ASSERT_EQUAL_UINT8(NONE, g.decide(4, EDGE_RELEASE, MODE_SHUTTER_DOWN, false, false).action);
}

void test_release_uses_mode_at_press_time_if_config_changes_while_held(void) {
  // Basma MOMENTARY olarak islendi; basili tutarken yapilandirma TOGGLE'a cevrildi: yine KAPAT uretilmeli.
  DiGate g;
  g.decide(1, EDGE_PRESS, MODE_MOMENTARY, false, false);
  Decision rel = g.decide(1, EDGE_RELEASE, MODE_TOGGLE, false, false);
  TEST_ASSERT_EQUAL_UINT8(RELAY_OFF, rel.action);
}

void test_locked_stop_press_has_no_release_action(void) {
  DiGate g;
  g.decide(3, EDGE_PRESS, MODE_SHUTTER_UP, true, true);                    // kilitli DUR
  TEST_ASSERT_EQUAL_UINT8(NONE, g.decide(3, EDGE_RELEASE, MODE_SHUTTER_UP, true, false).action);
}

void test_acted_mask_tracks_independent_inputs(void) {
  DiGate g;
  g.decide(0, EDGE_PRESS, MODE_TOGGLE, false, false);
  g.decide(9, EDGE_PRESS, MODE_MOMENTARY, false, false);
  g.decide(3, EDGE_PRESS, MODE_TOGGLE, true, false);          // engellendi
  TEST_ASSERT_TRUE(g.acted(0));
  TEST_ASSERT_TRUE(g.acted(9));
  TEST_ASSERT_FALSE(g.acted(3));
  TEST_ASSERT_TRUE(g.actedMask() == ((1ULL << 0) | (1ULL << 9)));
  g.decide(9, EDGE_RELEASE, MODE_MOMENTARY, false, false);
  TEST_ASSERT_TRUE(g.actedMask() == (1ULL << 0));
}

// ---------------------------------------------------------------- 60 ms kararlilik suzgeci
void test_filter_init_produces_no_edge(void) {
  DiGate g;
  g.init(0, true, 1000);                                       // basili baslangic: olay yok
  TEST_ASSERT_EQUAL_UINT8(EDGE_NONE, g.sample(0, true, 1000));
  TEST_ASSERT_EQUAL_UINT8(EDGE_NONE, g.sample(0, true, 5000));
  TEST_ASSERT_TRUE(g.stable(0));
}

void test_filter_boundary_59_60_61_ms(void) {
  DiGate g;
  g.init(0, false, 0);
  TEST_ASSERT_EQUAL_UINT8(EDGE_NONE, g.sample(0, true, 1000));         // degisim anı
  TEST_ASSERT_EQUAL_UINT8(EDGE_NONE, g.sample(0, true, 1059));         // 59 ms: henuz degil
  TEST_ASSERT_FALSE(g.stable(0));
  TEST_ASSERT_EQUAL_UINT8(EDGE_PRESS, g.sample(0, true, 1060));        // 60 ms: kabul
  TEST_ASSERT_TRUE(g.stable(0));

  DiGate h;
  h.init(0, false, 0);
  h.sample(0, true, 2000);
  TEST_ASSERT_EQUAL_UINT8(EDGE_PRESS, h.sample(0, true, 2061));        // 61 ms: kabul
}

void test_filter_same_edge_not_repeated(void) {
  DiGate g;
  g.init(0, false, 0);
  g.sample(0, true, 100);
  TEST_ASSERT_EQUAL_UINT8(EDGE_PRESS, g.sample(0, true, 160));
  TEST_ASSERT_EQUAL_UINT8(EDGE_NONE, g.sample(0, true, 200));
  TEST_ASSERT_EQUAL_UINT8(EDGE_NONE, g.sample(0, true, 10000));
}

void test_filter_rejects_contact_bounce(void) {
  DiGate g;
  g.init(0, false, 0);
  uint32_t t = 1000;
  const bool bounce[8] = {true, false, true, false, true, false, true, true};
  uint8_t presses = 0;
  for (int i = 0; i < 8; i++) {
    if (g.sample(0, bounce[i], t) == EDGE_PRESS) presses++;
    t += 10;
  }
  TEST_ASSERT_EQUAL_UINT8(0, presses);
  for (int i = 0; i < 10; i++) {
    if (g.sample(0, true, t) == EDGE_PRESS) presses++;
    t += 10;
  }
  TEST_ASSERT_EQUAL_UINT8(1, presses);                         // TEK basma
}

void test_filter_short_glitch_while_pressed_is_not_a_release(void) {
  DiGate g;
  g.init(0, false, 0);
  uint32_t t = 100;
  TEST_ASSERT_EQUAL_UINT8(EDGE_PRESS, settle(g, 0, true, t));
  t += 100;
  TEST_ASSERT_EQUAL_UINT8(EDGE_NONE, g.sample(0, false, t));           // 20 ms parazit
  t += 20;
  TEST_ASSERT_EQUAL_UINT8(EDGE_NONE, g.sample(0, true, t));
  t += 100;
  TEST_ASSERT_EQUAL_UINT8(EDGE_NONE, g.sample(0, true, t));
  TEST_ASSERT_TRUE(g.stable(0));
  t += 100;
  TEST_ASSERT_EQUAL_UINT8(EDGE_RELEASE, settle(g, 0, false, t));       // gercek birakma
}

void test_filter_survives_millis_rollover(void) {
  DiGate g;
  uint32_t t0 = 0xFFFFFFF0u;
  g.init(0, false, t0);
  g.sample(0, true, (uint32_t)(t0 + 5u));
  TEST_ASSERT_EQUAL_UINT8(EDGE_NONE, g.sample(0, true, (uint32_t)(t0 + 10u)));     // tasmadan ONCE (0xFFFFFFFA): 5 ms
  TEST_ASSERT_EQUAL_UINT8(EDGE_NONE, g.sample(0, true, (uint32_t)(t0 + 40u)));     // tasma sonrasi
  TEST_ASSERT_EQUAL_UINT8(EDGE_NONE, g.sample(0, true, (uint32_t)(t0 + 64u)));     // 59 ms
  TEST_ASSERT_EQUAL_UINT8(EDGE_PRESS, g.sample(0, true, (uint32_t)(t0 + 65u)));    // 60 ms
}

// ---------------------------------------------------------------- ek modul (ext) girisleri AYNI kapi
void test_extension_module_inputs_use_the_same_gate_and_lock(void) {
  DiGate g;
  const uint8_t extIdx = 8 + 3;                                  // ek modul 4. giris
  g.init(extIdx, false, 0);
  // ~120 ms'de bir ornekleme: tek (sekme) ornek kabul edilmez, art arda iki ayni ornek gerekir
  TEST_ASSERT_EQUAL_UINT8(EDGE_NONE, g.sample(extIdx, true, 1000));
  TEST_ASSERT_EQUAL_UINT8(EDGE_NONE, g.sample(extIdx, false, 1120));       // geri dondu: sekme
  TEST_ASSERT_EQUAL_UINT8(EDGE_NONE, g.sample(extIdx, true, 1240));
  Edge e = g.sample(extIdx, true, 1360);
  TEST_ASSERT_EQUAL_UINT8(EDGE_PRESS, e);
  // Kilitliyken ek modul duvar anahtari da engellenir (eski kod ext DI'lari kilitten muaf tutuyordu)
  Decision d = g.decide(extIdx, e, MODE_TOGGLE, true, false);
  TEST_ASSERT_EQUAL_UINT8(NONE, d.action);
  TEST_ASSERT_TRUE(d.dropped);
}

void test_highest_input_index_and_out_of_range(void) {
  DiGate g;
  g.init(39, false, 0);
  g.sample(39, true, 100);
  TEST_ASSERT_EQUAL_UINT8(EDGE_PRESS, g.sample(39, true, 160));
  // Aralik disi giris: hicbir sey olmaz, cokme yok
  g.init(40, true, 0);
  TEST_ASSERT_EQUAL_UINT8(EDGE_NONE, g.sample(40, true, 1000));
  TEST_ASSERT_EQUAL_UINT8(NONE, g.decide(40, EDGE_PRESS, MODE_TOGGLE, false, false).action);
  TEST_ASSERT_FALSE(g.stable(40));
}

// ---------------------------------------------------------------- uctan uca akislar (suzgec + kapi)
void test_full_flow_press_lock_release_unlock(void) {
  DiGate g;
  g.init(1, false, 0);
  uint32_t t = 1000;
  bool locked = false;

  // 1) kilit KAPALI: basis islenir (MOMENTARY AC)
  Edge e = settle(g, 1, true, t);
  Decision d = g.decide(1, e, MODE_MOMENTARY, locked, false);
  TEST_ASSERT_EQUAL_UINT8(RELAY_ON, d.action);

  // 2) basili tutarken kilit acilir
  locked = true;
  t += 500;

  // 3) birakma: kilit etkin olsa da KAPAT uretilir
  e = settle(g, 1, false, t);
  d = g.decide(1, e, MODE_MOMENTARY, locked, false);
  TEST_ASSERT_EQUAL_UINT8(RELAY_OFF, d.action);

  // 4) kilitliyken yeni basis engellenir
  t += 500;
  e = settle(g, 1, true, t);
  d = g.decide(1, e, MODE_MOMENTARY, locked, false);
  TEST_ASSERT_EQUAL_UINT8(NONE, d.action);
  TEST_ASSERT_TRUE(d.dropped);

  // 5) kilit basili tutarken kalkar, birakma bayat KAPAT uretmez
  locked = false;
  t += 500;
  e = settle(g, 1, false, t);
  d = g.decide(1, e, MODE_MOMENTARY, locked, false);
  TEST_ASSERT_EQUAL_UINT8(NONE, d.action);
}

int main(int, char**) {
  UNITY_BEGIN();
  RUN_TEST(test_press_actions_when_unlocked);
  RUN_TEST(test_unknown_mode_does_nothing_and_is_not_acted);
  RUN_TEST(test_locked_press_is_dropped_and_not_acted_for_every_mode_when_idle);
  RUN_TEST(test_locked_wall_switch_can_still_stop_a_moving_shutter);
  RUN_TEST(test_locked_shutter_buttons_never_start_motion);
  RUN_TEST(test_locked_toggle_and_momentary_stay_blocked_even_if_a_shutter_is_active);
  RUN_TEST(test_release_of_accepted_momentary_press_turns_relay_off);
  RUN_TEST(test_lock_enabled_while_held_release_still_turns_off);
  RUN_TEST(test_press_dropped_by_lock_then_unlock_while_held_release_does_nothing);
  RUN_TEST(test_release_without_any_press_does_nothing);
  RUN_TEST(test_release_is_ignored_for_non_momentary_modes);
  RUN_TEST(test_release_uses_mode_at_press_time_if_config_changes_while_held);
  RUN_TEST(test_locked_stop_press_has_no_release_action);
  RUN_TEST(test_acted_mask_tracks_independent_inputs);
  RUN_TEST(test_filter_init_produces_no_edge);
  RUN_TEST(test_filter_boundary_59_60_61_ms);
  RUN_TEST(test_filter_same_edge_not_repeated);
  RUN_TEST(test_filter_rejects_contact_bounce);
  RUN_TEST(test_filter_short_glitch_while_pressed_is_not_a_release);
  RUN_TEST(test_filter_survives_millis_rollover);
  RUN_TEST(test_extension_module_inputs_use_the_same_gate_and_lock);
  RUN_TEST(test_highest_input_index_and_out_of_range);
  RUN_TEST(test_full_flow_press_lock_release_unlock);
  return UNITY_END();
}
