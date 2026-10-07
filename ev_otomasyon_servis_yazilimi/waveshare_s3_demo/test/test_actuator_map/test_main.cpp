// ActuatorMap / ActuatorCore (src/actuators/*.h) birim testleri. SAF MANTIK.
// Kapsam (spec 2.4, 5.1.6, 5.5, karar 7.2b-2/6): close_mode x mantiksal durum, acilis maskesi (kilitli/kilitsiz x iki kip x son
// konum x su/gaz), kilit maskesinin yapilandirmasiz uygulanmasi, panjur cifti suzgeci, ham komutun yon kurali, geri bildirim
// zaman asimi, siren sure butcesi, IKI ROLELI vana interlock'u (iki role asla birlikte enerjili degil, olu zaman).
#include <unity.h>
#include <stdint.h>
#include <string.h>
#include "actuators/ActuatorTypes.h"
#include "actuators/ActuatorMap.h"

using namespace safety;

void setUp(void) {}
void tearDown(void) {}

static ActuatorConfig valve(uint8_t relay, CloseMode m, Medium med, uint8_t zones = 0x01, uint8_t fbDi = 0) {
  ActuatorConfig a;
  memset(&a, 0, sizeof(a));
  a.relay = relay;
  a.kind = (uint8_t)ActKind::VALVE;
  a.close_mode = (uint8_t)m;
  a.medium = (uint8_t)med;
  a.zone_mask = zones;
  a.fb_di = fbDi;
  a.fb_closed_active = 1;
  a.fb_timeout_s = 60;
  return a;
}

static ActuatorConfig sw(uint8_t relay, ActKind k, uint8_t zones = 0x01, uint16_t runLimit = 180) {
  ActuatorConfig a;
  memset(&a, 0, sizeof(a));
  a.relay = relay;
  a.kind = (uint8_t)k;
  a.zone_mask = zones;
  a.run_limit_s = runLimit;
  return a;
}

static ActuatorConfig pulseValve(uint8_t closeRelay, uint8_t openRelay, uint16_t pulseS = 15) {
  ActuatorConfig a = valve(closeRelay, CloseMode::PULSE_TWO_RELAY, Medium::WATER);
  a.relay2 = openRelay;
  a.run_limit_s = pulseS;
  return a;
}

void test_struct_size(void) {
  TEST_ASSERT_EQUAL_UINT32(36, sizeof(ActuatorConfig));
}

void test_relay_level_for_close_mode(void) {
  ActuatorConfig e = valve(5, CloseMode::ENERGIZE_TO_CLOSE, Medium::WATER);
  ActuatorConfig d = valve(5, CloseMode::DEENERGIZE_TO_CLOSE, Medium::WATER);
  TEST_ASSERT_TRUE(relayLevelFor(e, true));
  TEST_ASSERT_FALSE(relayLevelFor(e, false));
  TEST_ASSERT_FALSE(relayLevelFor(d, true));
  TEST_ASSERT_TRUE(relayLevelFor(d, false));
  TEST_ASSERT_EQUAL_UINT8(HZ_WATER, mediumHazard((uint8_t)Medium::WATER));
  TEST_ASSERT_EQUAL_UINT8(HZ_GAS, mediumHazard((uint8_t)Medium::GAS));
  TEST_ASSERT_EQUAL_UINT8(0, mediumHazard((uint8_t)Medium::NONE));
}

void test_relay_bits_include_second_relay_of_pulse_valve(void) {
  ActuatorConfig p = pulseValve(3, 4);
  TEST_ASSERT_EQUAL_UINT64((1ULL << 2) | (1ULL << 3), relayBits(p));
  ActuatorConfig s = sw(40, ActKind::SIREN);
  TEST_ASSERT_EQUAL_UINT64(1ULL << 39, relayBits(s));
}

void test_boot_mask_table(void) {
  // 0: E2C su, 1: D2C su, 2: E2C gaz, 3: D2C gaz, 4: siren, 5: iki roleli su vanasi (6/7)
  ActuatorConfig a[6] = {
    valve(1, CloseMode::ENERGIZE_TO_CLOSE, Medium::WATER),
    valve(2, CloseMode::DEENERGIZE_TO_CLOSE, Medium::WATER),
    valve(3, CloseMode::ENERGIZE_TO_CLOSE, Medium::GAS),
    valve(4, CloseMode::DEENERGIZE_TO_CLOSE, Medium::GAS),
    sw(5, ActKind::SIREN),
    pulseValve(6, 7),
  };
  // kilitsiz, konum kaydi yok: su vanalari "bilinmiyor" = ACIK kabul (7.2b-6); gaz HER ZAMAN kapali (K-4)
  uint64_t m = bootLevelMask(a, 6, 0, 0x0000, 0x0000);
  TEST_ASSERT_EQUAL_UINT64((1ULL << 1) | (1ULL << 2), m);      // D2C su acik (enerjili), E2C gaz kapali (enerjili)
  // kilitsiz, kayit: hepsi kapali -> E2C su kapali (enerjili), D2C su kapali (enerjisiz)
  m = bootLevelMask(a, 6, 0, 0x0000, 0x003F);
  TEST_ASSERT_EQUAL_UINT64((1ULL << 0) | (1ULL << 2), m);
  // kilitsiz, kayit: hepsi acik -> gaz yine kapali (act_pos gaz icin okunmaz)
  m = bootLevelMask(a, 6, 0, 0x003F, 0x003F);
  TEST_ASSERT_EQUAL_UINT64((1ULL << 1) | (1ULL << 2), m);
  // bolge 1 kilitli: kayit acik olsa bile su vanalari kapali
  m = bootLevelMask(a, 6, 0x01, 0x003F, 0x003F);
  TEST_ASSERT_EQUAL_UINT64((1ULL << 0) | (1ULL << 2), m);
  // kilit baska bolgede: etkisiz
  m = bootLevelMask(a, 6, 0x02, 0x003F, 0x003F);
  TEST_ASSERT_EQUAL_UINT64((1ULL << 1) | (1ULL << 2), m);
}

void test_latch_mask_applies_without_config(void) {
  // Yapilandirma bos (fabrika sifirlamasi / bozuk CRC): kilit kaydindaki maske tek basina uygulanir [Y-4]
  uint64_t boot = bootLevelMask(nullptr, 0, 0x01, 0, 0);
  TEST_ASSERT_EQUAL_UINT64(0, boot);
  uint64_t m = applyLatchMask(boot, /*assert*/ (1ULL << 4) | (1ULL << 9), /*level*/ (1ULL << 4));
  TEST_ASSERT_EQUAL_UINT64(1ULL << 4, m);
  // kilit maskesi yapilandirmanin istedigini EZER (role 5 acik istense de kilit 0 diyorsa 0)
  m = applyLatchMask((1ULL << 4) | (1ULL << 1), (1ULL << 4), 0);
  TEST_ASSERT_EQUAL_UINT64(1ULL << 1, m);
}

void test_filter_safe_bits_rejects_shutter_pairs(void) {
  // cift 0 (role 1-2) ve cift 2 (role 5-6) panjur: o bitler ASLA guvenlik yolundan kurulmaz
  TEST_ASSERT_EQUAL_HEX8(0xCC, filterSafeBits(0xFF, 0x05));
  TEST_ASSERT_EQUAL_HEX8(0x00, filterSafeBits(0x03, 0x01));
  TEST_ASSERT_EQUAL_HEX8(0x10, filterSafeBits(0x10, 0x00));
}

void test_raw_command_direction_rule(void) {
  ActuatorConfig a[5] = {
    valve(1, CloseMode::ENERGIZE_TO_CLOSE, Medium::WATER),
    valve(2, CloseMode::DEENERGIZE_TO_CLOSE, Medium::WATER),
    sw(3, ActKind::SIREN),
    sw(4, ActKind::FAN),
    pulseValve(5, 6),
  };
  RawResult r = rawCommand(a, 5, 1, true);     // E2C: enerji = KAPAT -> guvenli yon
  TEST_ASSERT_EQUAL_UINT8((uint8_t)RawDecision::SAFE, (uint8_t)r.d);
  TEST_ASSERT_EQUAL_INT(0, r.act);
  TEST_ASSERT_EQUAL_UINT8((uint8_t)RawDecision::REJECT, (uint8_t)rawCommand(a, 5, 1, false).d);
  TEST_ASSERT_EQUAL_UINT8((uint8_t)RawDecision::SAFE, (uint8_t)rawCommand(a, 5, 2, false).d);
  TEST_ASSERT_EQUAL_UINT8((uint8_t)RawDecision::REJECT, (uint8_t)rawCommand(a, 5, 2, true).d);
  TEST_ASSERT_EQUAL_UINT8((uint8_t)RawDecision::SAFE, (uint8_t)rawCommand(a, 5, 3, false).d);   // sireni sustur
  TEST_ASSERT_EQUAL_UINT8((uint8_t)RawDecision::REJECT, (uint8_t)rawCommand(a, 5, 3, true).d);
  TEST_ASSERT_EQUAL_UINT8((uint8_t)RawDecision::REJECT, (uint8_t)rawCommand(a, 5, 4, true).d);
  r = rawCommand(a, 5, 5, true);               // iki roleli: kapat rolesi enerji = KAPAT istegi
  TEST_ASSERT_EQUAL_UINT8((uint8_t)RawDecision::SAFE, (uint8_t)r.d);
  TEST_ASSERT_EQUAL_INT(4, r.act);
  TEST_ASSERT_EQUAL_UINT8((uint8_t)RawDecision::REJECT, (uint8_t)rawCommand(a, 5, 6, true).d);
  TEST_ASSERT_EQUAL_UINT8((uint8_t)RawDecision::NOOP, (uint8_t)rawCommand(a, 5, 6, false).d);
  TEST_ASSERT_EQUAL_UINT8((uint8_t)RawDecision::REJECT, (uint8_t)rawCommand(a, 5, 5, false).d);
  r = rawCommand(a, 5, 7, true);
  TEST_ASSERT_EQUAL_UINT8((uint8_t)RawDecision::NOT_ACTUATOR, (uint8_t)r.d);
  TEST_ASSERT_EQUAL_INT(-1, r.act);
  // eylemci yokken (bugunku saha) hicbir role eylemci degildir
  TEST_ASSERT_EQUAL_UINT8((uint8_t)RawDecision::NOT_ACTUATOR, (uint8_t)rawCommand(nullptr, 0, 1, true).d);
}

void test_core_valve_levels_and_position_bits(void) {
  ActuatorConfig a[2] = {valve(5, CloseMode::ENERGIZE_TO_CLOSE, Medium::WATER), valve(6, CloseMode::DEENERGIZE_TO_CLOSE, Medium::WATER)};
  ActuatorCore c;
  c.configure(a, 2, 0, 0, 0);
  TEST_ASSERT_EQUAL_UINT64((1ULL << 4) | (1ULL << 5), c.relayMask());
  TEST_ASSERT_EQUAL_UINT8((uint8_t)ValvePos::UNKNOWN, (uint8_t)c.pos(0));
  TEST_ASSERT_FALSE(c.levelOf(5));             // bilinmiyor = acik kabul: E2C enerjisiz
  TEST_ASSERT_TRUE(c.levelOf(6));              // D2C enerjili
  TEST_ASSERT_FALSE(c.takePosDirty());
  c.commandValve(0, true, 100);
  c.commandValve(1, true, 100);
  c.tick(100);
  TEST_ASSERT_TRUE(c.levelOf(5));
  TEST_ASSERT_FALSE(c.levelOf(6));
  TEST_ASSERT_EQUAL_UINT8((uint8_t)ValvePos::CMD_CLOSED, (uint8_t)c.pos(0));
  TEST_ASSERT_EQUAL_UINT16(0x0003, c.posKnownBits());
  TEST_ASSERT_EQUAL_UINT16(0x0000, c.posOpenBits());
  TEST_ASSERT_TRUE(c.takePosDirty());
  TEST_ASSERT_FALSE(c.takePosDirty());
  c.commandValve(0, false, 200);
  TEST_ASSERT_EQUAL_UINT16(0x0001, c.posOpenBits());
  TEST_ASSERT_EQUAL_UINT8((uint8_t)ValvePos::CMD_OPEN, (uint8_t)c.pos(0));
  TEST_ASSERT_EQUAL_UINT64(0, c.levelMask() & (1ULL << 4));      // E2C acik = enerjisiz
  TEST_ASSERT_EQUAL_UINT64(0, c.levelMask() & (1ULL << 5));      // D2C hala kapali = enerjisiz

  TEST_ASSERT_FALSE(c.levelOf(7));             // eylemci olmayan role
}

void test_core_restores_saved_position(void) {
  ActuatorConfig a = valve(5, CloseMode::DEENERGIZE_TO_CLOSE, Medium::WATER);
  ActuatorCore c;
  c.configure(&a, 1, /*open*/ 0x0000, /*known*/ 0x0001, 0);   // kayit: kapali
  TEST_ASSERT_EQUAL_UINT8((uint8_t)ValvePos::CMD_CLOSED, (uint8_t)c.pos(0));
  TEST_ASSERT_FALSE(c.levelOf(5));
  ActuatorConfig g = valve(5, CloseMode::DEENERGIZE_TO_CLOSE, Medium::GAS);
  c.configure(&g, 1, 0x0001, 0x0001, 0);                       // gaz: kayit "acik" olsa da kapali [K-4]
  TEST_ASSERT_TRUE(c.closedCmd(0));
  TEST_ASSERT_FALSE(c.levelOf(5));
}

void test_core_feedback_timeout_and_recovery(void) {
  ActuatorConfig a = valve(5, CloseMode::ENERGIZE_TO_CLOSE, Medium::WATER, 0x01, /*fb_di*/ 3);
  a.fb_timeout_s = 5;
  ActuatorCore c;
  c.configure(&a, 1, 0x0001, 0x0001, 0);
  TEST_ASSERT_EQUAL_UINT64(1ULL << 2, c.fbDiMask());
  c.setFeedback(0, false);                      // kontak acik = vana kapali DEGIL (fb_closed_active=1)
  c.tick(0);
  TEST_ASSERT_EQUAL_UINT8((uint8_t)ValvePos::OPEN, (uint8_t)c.pos(0));
  c.commandValve(0, true, 1000);
  c.tick(1000);
  TEST_ASSERT_EQUAL_UINT8((uint8_t)ValvePos::CLOSING, (uint8_t)c.pos(0));
  c.tick(5999);
  TEST_ASSERT_FALSE(c.fbFault(0));
  c.tick(6000);
  TEST_ASSERT_TRUE(c.fbFault(0));
  c.setFeedback(0, true);
  c.tick(7000);
  TEST_ASSERT_FALSE(c.fbFault(0));
  TEST_ASSERT_EQUAL_UINT8((uint8_t)ValvePos::CLOSED, (uint8_t)c.pos(0));
  TEST_ASSERT_EQUAL_UINT32(6000, c.fbMs(0));
  c.commandValve(0, false, 8000);
  c.tick(8000);
  TEST_ASSERT_EQUAL_UINT8((uint8_t)ValvePos::OPENING, (uint8_t)c.pos(0));
  TEST_ASSERT_FALSE(c.fbFault(0));             // acarken "kapanmadi" arizasi yok
}

void test_core_siren_run_limit_and_budget(void) {
  ActuatorConfig s = sw(7, ActKind::SIREN, 0x01, 10);
  ActuatorCore c;
  c.configure(&s, 1, 0, 0, 0);
  c.commandSwitch(0, true, 0);
  for (uint32_t t = 0; t <= 9990; t += 10) c.tick(t);
  TEST_ASSERT_TRUE(c.levelOf(7));
  for (uint32_t t = 10000; t <= 10100; t += 10) c.tick(t);
  TEST_ASSERT_FALSE(c.levelOf(7));              // run_limit_s = 10 sn doldu
  TEST_ASSERT_TRUE(c.on(0));                    // istek suruyor, cikis sinirlandi
  TEST_ASSERT_TRUE(c.sirenRunMs(0) >= 10000);
  c.resetSirenBudget(0);
  c.tick(10110);
  TEST_ASSERT_TRUE(c.levelOf(7));
  c.setSirenRunMs(0, 9999);                     // NVS'ten gelen birikim (yeniden baslatma sayaci sifirlamaz) [O-8]
  c.tick(10120);
  c.tick(10130);
  TEST_ASSERT_FALSE(c.levelOf(7));
}

void test_core_fan_and_generic_switch(void) {
  ActuatorConfig a[2] = {sw(3, ActKind::FAN), sw(4, ActKind::GENERIC)};
  ActuatorCore c;
  c.configure(a, 2, 0, 0, 0);
  c.commandSwitch(0, true, 0);
  c.commandSwitch(1, true, 0);
  c.tick(100000000);
  TEST_ASSERT_TRUE(c.levelOf(3));               // fan/generic icin sure siniri yok
  TEST_ASSERT_TRUE(c.levelOf(4));
  c.commandSwitch(0, false, 0);
  TEST_ASSERT_FALSE(c.levelOf(3));
}

// Iki roleli vana: her 10 ms'de iki role asla birlikte enerjili olmamali; yon degisiminde >= 500 ms ikisi de kapali.
static void checkInterlock(ActuatorCore& c, uint32_t from, uint32_t to, uint8_t closeR, uint8_t openR,
                           uint32_t& lastOn, bool& lastWasClose, bool& anyOn, uint32_t& bothOffSince) {
  for (uint32_t t = from; t <= to; t += 10) {
    c.tick(t);
    bool cl = c.levelOf(closeR), op = c.levelOf(openR);
    TEST_ASSERT_FALSE(cl && op);
    if (cl || op) {
      if (anyOn && lastWasClose != cl) TEST_ASSERT_TRUE((uint32_t)(t - bothOffSince) >= 500);
      lastWasClose = cl;
      anyOn = true;
      lastOn = t;
    } else if (lastOn + 10 == t) {
      bothOffSince = t;
    }
  }
}

void test_pulse_valve_interlock_and_dead_time(void) {
  ActuatorConfig p = pulseValve(3, 4, 15);
  ActuatorCore c;
  c.configure(&p, 1, 0, 0, 0);
  uint32_t lastOn = 0, bothOff = 0;
  bool lastClose = false, anyOn = false;
  TEST_ASSERT_FALSE(c.levelOf(3));
  TEST_ASSERT_FALSE(c.levelOf(4));
  c.commandValve(0, true, 0);
  c.tick(0);
  TEST_ASSERT_TRUE(c.levelOf(3));
  TEST_ASSERT_EQUAL_UINT8((uint8_t)ValvePos::CLOSING, (uint8_t)c.pos(0));
  checkInterlock(c, 10, 4990, 3, 4, lastOn, lastClose, anyOn, bothOff);
  c.commandValve(0, false, 5000);               // kapatirken AC: once olu zaman
  checkInterlock(c, 5000, 5490, 3, 4, lastOn, lastClose, anyOn, bothOff);
  TEST_ASSERT_FALSE(c.levelOf(3));
  TEST_ASSERT_FALSE(c.levelOf(4));
  checkInterlock(c, 5500, 20990, 3, 4, lastOn, lastClose, anyOn, bothOff);
  TEST_ASSERT_FALSE(c.levelOf(4));              // 15 sn darbe bitti
  TEST_ASSERT_EQUAL_UINT8((uint8_t)ValvePos::CMD_OPEN, (uint8_t)c.pos(0));
  c.commandValve(0, true, 21000);
  checkInterlock(c, 21000, 37000, 3, 4, lastOn, lastClose, anyOn, bothOff);
  TEST_ASSERT_EQUAL_UINT8((uint8_t)ValvePos::CMD_CLOSED, (uint8_t)c.pos(0));
}

void test_pulse_valve_quick_reverse_after_idle_waits_dead_time(void) {
  ActuatorConfig p = pulseValve(3, 4, 1);
  ActuatorCore c;
  c.configure(&p, 1, 0, 0, 0);
  c.commandValve(0, true, 0);
  c.tick(0);
  c.tick(1000);                                  // 1 sn darbe bitti
  TEST_ASSERT_FALSE(c.levelOf(3));
  c.commandValve(0, false, 1100);                // 100 ms sonra ters yon: 500 ms dolmadan enerji YOK
  c.tick(1100);
  TEST_ASSERT_FALSE(c.levelOf(4));
  c.tick(1499);
  TEST_ASSERT_FALSE(c.levelOf(4));
  c.tick(1500);
  TEST_ASSERT_TRUE(c.levelOf(4));
}

void test_pulse_valve_same_direction_does_not_extend(void) {
  ActuatorConfig p = pulseValve(3, 4, 2);
  ActuatorCore c;
  c.configure(&p, 1, 0, 0, 0);
  c.commandValve(0, true, 0);
  c.tick(0);
  c.commandValve(0, true, 1500);                 // ayni yon tekrar: darbe uzamaz
  c.tick(2000);
  TEST_ASSERT_FALSE(c.levelOf(3));
}

void test_pulse_valve_millis_rollover(void) {
  ActuatorConfig p = pulseValve(3, 4, 15);
  ActuatorCore c;
  const uint32_t t0 = 0xFFFFF000u;
  c.configure(&p, 1, 0, 0, t0);
  c.commandValve(0, true, t0);
  c.tick(t0);
  c.tick(t0 + 14999);
  TEST_ASSERT_TRUE(c.levelOf(3));
  c.tick(t0 + 15000);
  TEST_ASSERT_FALSE(c.levelOf(3));
}

// Inceleme turu (entegrasyon) EM-1/EM-5: kalici acilis guvenli maskesi = KAPALI komutlu vanalar + butun gaz vanalari (K-4).
// E2C: role 1, D2C: role 0 (dayatilir), iki roleli: AC rolesi 0. Siren/fan/generic yok.
void test_boot_safe_masks(void) {
  ActuatorConfig a[6];
  a[0] = valve(1, CloseMode::ENERGIZE_TO_CLOSE, Medium::WATER);    // kapali
  a[1] = valve(2, CloseMode::ENERGIZE_TO_CLOSE, Medium::WATER);    // acik
  a[2] = valve(3, CloseMode::ENERGIZE_TO_CLOSE, Medium::GAS);      // acik (GAS_RESET) ama gaz: acilista kapali
  a[3] = valve(4, CloseMode::DEENERGIZE_TO_CLOSE, Medium::WATER);  // kapali
  a[4] = pulseValve(5, 6);                                        // kapali
  a[5] = sw(7, ActKind::SIREN);
  uint64_t as = 0, lv = 0;
  bootSafeMasks(a, 6, 0x0019 | 0x0020, as, lv);
  TEST_ASSERT_EQUAL_HEX64((1ULL << 0) | (1ULL << 2) | (1ULL << 3) | (1ULL << 5), as);
  TEST_ASSERT_EQUAL_HEX64((1ULL << 0) | (1ULL << 2), lv);
  bootSafeMasks(a, 0, 0xFFFF, as, lv);
  TEST_ASSERT_EQUAL_HEX64(0, as);
  TEST_ASSERT_EQUAL_HEX64(0, lv);
}

// Calisirken yama: eslenen eylemcinin calisma durumu (konum, geri bildirim zamanlayicisi/arizasi, darbe, siren butcesi) tasinir.
void test_core_reconfigure_adopts_runtime(void) {
  ActuatorConfig a[3];
  a[0] = valve(5, CloseMode::DEENERGIZE_TO_CLOSE, Medium::WATER, 0x01, 7);
  a[0].fb_timeout_s = 5;
  a[1] = sw(6, ActKind::SIREN, 0x01, 100);
  a[2] = valve(8, CloseMode::ENERGIZE_TO_CLOSE, Medium::GAS);
  ActuatorCore c;
  c.configure(a, 3, 0x0001, 0x0001, 1000);
  c.commandValve(0, true, 1000);
  c.setFeedback(0, false);
  c.commandSwitch(1, true, 1000);
  c.commandValve(2, false, 1000);                                 // gaz vanasi acildi (GAS_RESET)
  for (uint32_t t = 1000; t <= 7000; t += 100) c.tick(t);
  TEST_ASSERT_TRUE(c.fbFault(0));
  const uint32_t run = c.sirenRunMs(1);
  TEST_ASSERT_TRUE(run >= 6000);
  ActuatorConfig b[3];
  b[0] = a[2];
  b[1] = a[0];
  b[2] = a[1];
  const int8_t map[MAX_ACTUATORS] = {2, 0, 1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1};
  c.reconfigure(b, 3, 0x0001, 0x0003, map, 7000);
  TEST_ASSERT_FALSE(c.closedCmd(0));                              // gaz vanasi acik kaldi
  TEST_ASSERT_TRUE(c.closedCmd(1));
  TEST_ASSERT_TRUE(c.fbFault(1));                                 // ariza korundu (zamanlayici sifirlanmadi)
  TEST_ASSERT_EQUAL_UINT32(run, c.sirenRunMs(2));
  const int8_t none[MAX_ACTUATORS] = {-1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1};
  c.reconfigure(b, 3, 0x0000, 0x0000, none, 7000);                // eslenmeyen: configure ile ayni (gaz kapali, ariza yok)
  TEST_ASSERT_TRUE(c.closedCmd(0));
  TEST_ASSERT_FALSE(c.fbFault(1));
  TEST_ASSERT_EQUAL_UINT32(0, c.sirenRunMs(2));
}

int main(int, char**) {
  UNITY_BEGIN();
  RUN_TEST(test_struct_size);
  RUN_TEST(test_relay_level_for_close_mode);
  RUN_TEST(test_relay_bits_include_second_relay_of_pulse_valve);
  RUN_TEST(test_boot_mask_table);
  RUN_TEST(test_latch_mask_applies_without_config);
  RUN_TEST(test_filter_safe_bits_rejects_shutter_pairs);
  RUN_TEST(test_raw_command_direction_rule);
  RUN_TEST(test_core_valve_levels_and_position_bits);
  RUN_TEST(test_core_restores_saved_position);
  RUN_TEST(test_core_feedback_timeout_and_recovery);
  RUN_TEST(test_core_siren_run_limit_and_budget);
  RUN_TEST(test_core_fan_and_generic_switch);
  RUN_TEST(test_pulse_valve_interlock_and_dead_time);
  RUN_TEST(test_pulse_valve_quick_reverse_after_idle_waits_dead_time);
  RUN_TEST(test_pulse_valve_same_direction_does_not_extend);
  RUN_TEST(test_pulse_valve_millis_rollover);
  RUN_TEST(test_boot_safe_masks);
  RUN_TEST(test_core_reconfigure_adopts_runtime);
  return UNITY_END();
}
