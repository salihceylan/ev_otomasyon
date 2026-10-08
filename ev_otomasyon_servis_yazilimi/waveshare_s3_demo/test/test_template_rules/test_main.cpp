// ============================================================================
// template/TemplateRules (src/template/TemplateRules.h) birim testleri:  pio test -e native -f test_template_rules
//
// Uygulama kararının önceliği (kilit, kurulu alarm, panjur, çapraz doğrulama, NVS; LAN ve seri AYNI karar: K-Ş4 LAN gevşetme kuralı
// kullanıcı kararıyla kaldırıldı, 2026-10-08), başarısız uygulamada güvenlik bölümünün geri alma biçimi, HTTP eşlemesi ve NVS girdi bütçesi
// (en kötü durum sayıları yazdırılır).
// ============================================================================
#include <unity.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "template/TemplateRules.h"

using namespace tpl;
using namespace safety;

void setUp(void) {}
void tearDown(void) {}

namespace {

SensorConfig water(uint8_t di, uint8_t zone = 1) {
  SensorConfig s;
  memset(&s, 0, sizeof(s));
  s.src = (uint8_t)SensorSrc::DI;
  s.index = di;
  s.kind = (uint8_t)SensorKind::WATER;
  s.zone = zone;
  s.flags = defaultFlags(s.kind);
  s.confirm_ms = defaultConfirmMs(s.kind);
  return s;
}

ActuatorConfig valve(uint8_t relay) {
  ActuatorConfig a;
  memset(&a, 0, sizeof(a));
  a.relay = relay;
  a.kind = (uint8_t)ActKind::VALVE;
  a.medium = (uint8_t)Medium::WATER;
  a.zone_mask = 1;
  a.fb_closed_active = 1;
  a.fb_timeout_s = 60;
  return a;
}

SafetyConfig withValve() {
  SafetyConfig c;
  c.setDefaults();
  c.sens[0] = water(7);
  c.nSens = 1;
  c.act[0] = valve(8);
  c.nAct = 1;
  return c;
}


SystemConfig sys8() {
  SystemConfig s;
  memset(&s, 0, sizeof(s));
  sysconfig_detail::copyStr(s.device_name, "AHBU Akilli Ev Kontrol");
  s.ext_module_address = 1;
  s.rs485_baud = 9600;
  for (int i = 0; i < MAX_TOTAL_RELAYS; i++) snprintf(s.relays[i].name, sizeof(s.relays[i].name), "Role %d", i + 1);
  for (int i = 0; i < MAX_TOTAL_DIS; i++) snprintf(s.dis[i].name, sizeof(s.dis[i].name), "Giris %d", i + 1);
  return s;
}

ApplyIn okIn() {
  ApplyIn in;
  in.latched = false;
  in.armed = false;
  in.shutterMoving = false;
  in.sysErr = CfgErr::OK;
  in.nvsRoom = true;
  return in;
}

}  // namespace

SafetyState factoryState() {
  SafetyState st;
  st.stored = false;
  st.usable = true;
  st.safeMode = false;
  st.txnInterrupted = false;
  return st;
}

SafetyState storedState() {
  SafetyState st = factoryState();
  st.stored = true;
  return st;
}

void test_safety_rollback_kind() {
  TEST_ASSERT_TRUE(safetyRollbackKind(storedState()) == SafetyRollback::REWRITE_OLD);
  TEST_ASSERT_TRUE(safetyRollbackKind(factoryState()) == SafetyRollback::ERASE);       // fabrika durumu korunur
  SafetyState st = storedState();
  st.usable = false;                                                                    // cfg_corrupt: geçersiz kalır
  TEST_ASSERT_TRUE(safetyRollbackKind(st) == SafetyRollback::MARK_CORRUPT);
  st = factoryState();
  st.txnInterrupted = true;
  TEST_ASSERT_TRUE(safetyRollbackKind(st) == SafetyRollback::MARK_CORRUPT);
  st = storedState();
  st.safeMode = true;                                                                   // ör. crash_loop: yapılandırma sağlam -> eskisi
  TEST_ASSERT_TRUE(safetyRollbackKind(st) == SafetyRollback::REWRITE_OLD);
}

// LAN ve seri yol AYNI karar: geçerli her şablon; yalnız durum denetimleri (kilit, kurulu alarm, panjur, çapraz doğrulama, NVS).
void test_decide_apply_precedence_only_state_checks() {
  TEST_ASSERT_TRUE(decideApply(okIn()) == ApplyResult::OK);
  ApplyIn in = okIn();
  in.nvsRoom = false;
  TEST_ASSERT_TRUE(decideApply(in) == ApplyResult::STORAGE);
  in.sysErr = CfgErr::ACT_RELAY_SHUTTER;
  TEST_ASSERT_TRUE(decideApply(in) == ApplyResult::CFG_INVALID);
  in.shutterMoving = true;
  TEST_ASSERT_TRUE(decideApply(in) == ApplyResult::BUSY);
  in.armed = true;
  TEST_ASSERT_TRUE(decideApply(in) == ApplyResult::ARMED);
  in.latched = true;
  TEST_ASSERT_TRUE(decideApply(in) == ApplyResult::LATCHED);
}

void test_http_mapping_matches_readme() {
  TEST_ASSERT_EQUAL_INT(409, httpOf(ApplyResult::LATCHED).status);
  TEST_ASSERT_EQUAL_STRING("zone_latched", httpOf(ApplyResult::LATCHED).code);
  TEST_ASSERT_EQUAL_STRING("armed", httpOf(ApplyResult::ARMED).code);
  TEST_ASSERT_EQUAL_STRING("busy", httpOf(ApplyResult::BUSY).code);
  TEST_ASSERT_EQUAL_INT(409, httpOf(ApplyResult::BUSY).status);
  TEST_ASSERT_EQUAL_INT(507, httpOf(ApplyResult::STORAGE).status);
  TEST_ASSERT_EQUAL_STRING("storage", httpOf(ApplyResult::STORAGE).code);
  TEST_ASSERT_EQUAL_INT(400, httpOf(ApplyResult::INVALID).status);
  TEST_ASSERT_EQUAL_INT(503, httpOf(ApplyResult::INTERNAL).status);
}

void test_nvs_entries_unchanged_config_costs_nothing_and_new_channels_count_fully() {
  const SystemConfig a = sys8();
  TEST_ASSERT_EQUAL_UINT(0, sysConfigNvsEntries(a, a));
  SystemConfig b = a;
  sysconfig_detail::copyStr(b.relays[0].name, "Salon Panjur Yukarı");   // 20 bayt -> 1 + 1
  b.relays[0].type = RELAY_TYPE_SHUTTER_UP;
  TEST_ASSERT_EQUAL_UINT(3, sysConfigNvsEntries(a, b));
  SystemConfig c = a;
  c.ext_module_enabled = true;
  c.ext_module_channels = 8;                   // 8 yeni kanal: her biri 3 anahtar (ad 2 + tip 1 + süre 1 = 4) x2 (röle + DI)
  TEST_ASSERT_EQUAL_UINT(2 + 8 * 4 * 2, sysConfigNvsEntries(a, c));
  TEST_ASSERT_EQUAL_UINT(1 + 1 + 3 + 2, tplNvsEntries("A-12"));   // txn + ver + id + label
  TEST_ASSERT_EQUAL_UINT(1 + 1 + 3 + 2, tplNvsEntries("1234567890123456789012345678901"));   // 31 bayt + NUL = 32 -> 1 veri girdisi
}

void test_nvs_budget_numbers_for_report() {
  // En kötü durum: 40 kanal (ek modül 32), bütün ad 31 bayt ve hepsi değişiyor, güvenlik tablosu tam dolu, label 31 bayt.
  SystemConfig a = sys8();
  SystemConfig full = a;
  full.ext_module_enabled = true;
  full.ext_module_channels = 32;
  sysconfig_detail::copyStr(full.device_name, "1234567890123456789012345678901");
  for (int i = 0; i < MAX_TOTAL_RELAYS; i++) {
    memset(full.relays[i].name, 'R', 31);
    full.relays[i].name[31] = 0;
    full.relays[i].type = RELAY_TYPE_LIGHT;
    memset(full.dis[i].name, 'D', 31);
    full.dis[i].name[31] = 0;
    full.dis[i].target_relay = 0;
    full.dis[i].mode = DI_MODE_MOMENTARY;
  }
  SafetyConfig big;
  big.setDefaults();
  big.nSens = MAX_SENSORS;
  big.nAct = MAX_ACTUATORS;
  const uint16_t sysE = sysConfigNvsEntries(a, full);
  const uint16_t tplE = tplNvsEntries("1234567890123456789012345678901");
  const uint32_t needWorst = templateNvsNeed(big, sysE, tplE);
  // Tipik: ok_3p1 benzeri (8 kanal, 2 sensör, 1 eylemci), fabrika adlarından şablon adlarına.
  SafetyConfig typ = withValve();
  typ.sens[1] = water(8);
  typ.nSens = 2;
  SystemConfig t = a;
  for (int i = 0; i < 8; i++) {
    snprintf(t.relays[i].name, sizeof(t.relays[i].name), "Yatak Odası Panjur %d", i);
    snprintf(t.dis[i].name, sizeof(t.dis[i].name), "Salon Anahtar %d", i);
    t.relays[i].type = (uint8_t)(i < 4 ? (i % 2 ? RELAY_TYPE_SHUTTER_DOWN : RELAY_TYPE_SHUTTER_UP) : RELAY_TYPE_LIGHT);
    t.relays[i].runtime_sec = i < 4 ? 25 : 0;
    t.dis[i].target_relay = (uint8_t)(i + 1);
  }
  const uint16_t sysT = sysConfigNvsEntries(a, t);
  const uint32_t needTyp = templateNvsNeed(typ, sysT, tplNvsEntries("Güneş Sitesi A-12"));
  printf("[NVS] guvenlik tam=%u girdi, tipik=%u | ana yapilandirma en kotu=%u, tipik=%u | ahbu_tpl en cok=%u | toplam gereken (pay+GC dahil): en kotu=%u, tipik=%u | bolum=630 girdi (5 sayfa x 126)\n",
         (unsigned)configNvsEntries(big), (unsigned)configNvsEntries(typ), (unsigned)sysE, (unsigned)sysT, (unsigned)tplE,
         (unsigned)needWorst, (unsigned)needTyp);
  TEST_ASSERT_EQUAL_UINT(300, sysE);   // ad 2 + tip 1 + süre 1 (32 yeni kanal x 2 tam; ilk 8 kanalda yalnız değişenler) + ad + ek modül
  TEST_ASSERT_TRUE(nvsRoomForTemplate(needWorst, big, sysE, tplE));
  TEST_ASSERT_FALSE(nvsRoomForTemplate(needWorst - 1, big, sysE, tplE));
}

int main(int, char**) {
  UNITY_BEGIN();
  RUN_TEST(test_safety_rollback_kind);
  RUN_TEST(test_decide_apply_precedence_only_state_checks);
  RUN_TEST(test_http_mapping_matches_readme);
  RUN_TEST(test_nvs_entries_unchanged_config_costs_nothing_and_new_channels_count_fully);
  RUN_TEST(test_nvs_budget_numbers_for_report);
  return UNITY_END();
}
