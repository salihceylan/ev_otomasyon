// SafetyConfig (src/safety/SafetyConfig.h) birim testleri. SAF MANTIK.
// Kapsam (spec 2.4, 2.7, 4.1, 4.3, 5.1.6, 5.5): fabrika varsayilanlari, validate(system, safety) sinirlari ve capraz kurallar
// (panjura/darbeye cevrilen eylemci, kanal sayisi dususu, medium eksik, siren run_limit_s=0, gaz/duman NO baglanti, sensor DI'si
// duvar butonu), kilitli bolgeye dokunan degisiklik reddi, blob gidis-donusu + CRC32, bozuk CRC, kilit kaydi, cokme dongusu,
// acilis kipi karari (cfg_corrupt / latch_orphan / crash_loop).
#include <unity.h>
#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include "SystemConfig.h"
#include "safety/SafetyConfig.h"

using namespace safety;

void setUp(void) {}
void tearDown(void) {}

static SystemConfig sys8() {
  SystemConfig s;
  memset(&s, 0, sizeof(s));
  s.ext_module_enabled = false;
  return s;
}

static SensorConfig sensor(uint8_t di, SensorKind k, uint8_t zone, uint8_t nc) {
  SensorConfig c;
  memset(&c, 0, sizeof(c));
  c.src = (uint8_t)SensorSrc::DI;
  c.index = di;
  c.kind = (uint8_t)k;
  c.zone = zone;
  c.active_open = nc;
  c.flags = defaultFlags((uint8_t)k);
  c.confirm_ms = defaultConfirmMs((uint8_t)k);
  return c;
}

static ActuatorConfig valve(uint8_t relay, Medium m, uint8_t zones = 0x01) {
  ActuatorConfig a;
  memset(&a, 0, sizeof(a));
  a.relay = relay;
  a.kind = (uint8_t)ActKind::VALVE;
  a.close_mode = (uint8_t)CloseMode::DEENERGIZE_TO_CLOSE;
  a.medium = (uint8_t)m;
  a.zone_mask = zones;
  a.fb_timeout_s = 60;
  return a;
}

static ActuatorConfig siren(uint8_t relay, uint16_t lim = 180) {
  ActuatorConfig a;
  memset(&a, 0, sizeof(a));
  a.relay = relay;
  a.kind = (uint8_t)ActKind::SIREN;
  a.zone_mask = 0x01;
  a.run_limit_s = lim;
  return a;
}

static SafetyConfig base() {
  SafetyConfig c;
  c.setDefaults();
  c.sens[0] = sensor(3, SensorKind::WATER, 1, 0);
  c.nSens = 1;
  c.act[0] = valve(5, Medium::WATER);
  c.act[1] = siren(6);
  c.nAct = 2;
  return c;
}

void test_sizes(void) {
  TEST_ASSERT_EQUAL_UINT32(16, sizeof(Policy));
  TEST_ASSERT_EQUAL_UINT32(16, sizeof(ZoneConfig));
  TEST_ASSERT_EQUAL_UINT32(4, sizeof(LightOpt));
  TEST_ASSERT_EQUAL_UINT32(32, sizeof(LatchZone));
  TEST_ASSERT_EQUAL_UINT32(32, sizeof(LatchMasks));
  TEST_ASSERT_EQUAL_UINT32(164, sizeof(LatchRecord));
  TEST_ASSERT_EQUAL_UINT32(8, sizeof(CrashLog));
}

void test_factory_defaults(void) {
  SafetyConfig c;
  c.setDefaults();
  TEST_ASSERT_EQUAL_UINT8(1, c.pol.policy_on);              // K5: varsayilan ACIK
  TEST_ASSERT_EQUAL_UINT32(10000, c.pol.dry_hold_ms);
  TEST_ASSERT_EQUAL_STRING("Ev", c.zones[0].name);           // tek bolge "Ev"
  TEST_ASSERT_EQUAL_UINT8(0, c.nSens);                       // sensor/eylemci tablosu BOS
  TEST_ASSERT_EQUAL_UINT8(0, c.nAct);
  TEST_ASSERT_TRUE(c.empty());
  SystemConfig s = sys8();
  TEST_ASSERT_EQUAL_UINT8((uint8_t)CfgErr::OK, (uint8_t)validate(s, c));   // bos yapilandirma her zaman gecer
}

void test_valid_base_config(void) {
  SystemConfig s = sys8();
  SafetyConfig c = base();
  TEST_ASSERT_EQUAL_UINT8((uint8_t)CfgErr::OK, (uint8_t)validate(s, c));
}

void test_actuator_on_shutter_or_impulse_relay_rejected(void) {
  SystemConfig s = sys8();
  SafetyConfig c = base();
  s.relays[4].type = RELAY_TYPE_SHUTTER_DOWN;
  TEST_ASSERT_EQUAL_UINT8((uint8_t)CfgErr::ACT_RELAY_SHUTTER, (uint8_t)validate(s, c));
  s.relays[4].type = RELAY_TYPE_IMPULSE;
  TEST_ASSERT_EQUAL_UINT8((uint8_t)CfgErr::ACT_RELAY_IMPULSE, (uint8_t)validate(s, c));
}

void test_channel_count_drop_rejected(void) {
  SystemConfig s = sys8();
  s.ext_module_enabled = true;
  s.ext_module_channels = 8;
  SafetyConfig c = base();
  c.act[0].relay = 12;                                        // ek modul rolesi
  c.sens[0].index = 14;                                       // ek modul DI'si
  TEST_ASSERT_EQUAL_UINT8((uint8_t)CfgErr::OK, (uint8_t)validate(s, c));
  s.ext_module_enabled = false;                               // ek modul kapatilirsa eylemci/sensor disarida kalir [B3]
  CfgErr e = validate(s, c);
  TEST_ASSERT_TRUE(e == CfgErr::ACT_RELAY_RANGE || e == CfgErr::SENSOR_DI_RANGE);
  c.act[0].relay = 5;
  TEST_ASSERT_EQUAL_UINT8((uint8_t)CfgErr::SENSOR_DI_RANGE, (uint8_t)validate(s, c));
}

void test_valve_requires_medium(void) {
  SystemConfig s = sys8();
  SafetyConfig c = base();
  c.act[0].medium = (uint8_t)Medium::NONE;
  TEST_ASSERT_EQUAL_UINT8((uint8_t)CfgErr::VALVE_MEDIUM, (uint8_t)validate(s, c));
}

void test_siren_run_limit_range(void) {
  SystemConfig s = sys8();
  SafetyConfig c = base();
  c.act[1].run_limit_s = 0;                                   // 0 reddedilir [D-2]
  TEST_ASSERT_EQUAL_UINT8((uint8_t)CfgErr::SIREN_RUN_LIMIT, (uint8_t)validate(s, c));
  c.act[1].run_limit_s = 9;
  TEST_ASSERT_EQUAL_UINT8((uint8_t)CfgErr::SIREN_RUN_LIMIT, (uint8_t)validate(s, c));
  c.act[1].run_limit_s = 1801;
  TEST_ASSERT_EQUAL_UINT8((uint8_t)CfgErr::SIREN_RUN_LIMIT, (uint8_t)validate(s, c));
  c.act[1].run_limit_s = 10;
  TEST_ASSERT_EQUAL_UINT8((uint8_t)CfgErr::OK, (uint8_t)validate(s, c));
}

void test_gas_and_smoke_must_be_nc(void) {
  SystemConfig s = sys8();
  SafetyConfig c = base();
  c.sens[1] = sensor(4, SensorKind::GAS, 1, 0);
  c.nSens = 2;
  TEST_ASSERT_EQUAL_UINT8((uint8_t)CfgErr::GAS_SMOKE_NOT_NC, (uint8_t)validate(s, c));
  c.sens[1] = sensor(4, SensorKind::SMOKE, 1, 0);
  TEST_ASSERT_EQUAL_UINT8((uint8_t)CfgErr::GAS_SMOKE_NOT_NC, (uint8_t)validate(s, c));
  c.sens[1].active_open = 1;
  TEST_ASSERT_EQUAL_UINT8((uint8_t)CfgErr::OK, (uint8_t)validate(s, c));
}

void test_sensor_di_cannot_be_wall_button(void) {
  SystemConfig s = sys8();
  SafetyConfig c = base();
  s.dis[2].target_relay = 1;                                  // DI 3 duvar butonu
  TEST_ASSERT_EQUAL_UINT8((uint8_t)CfgErr::SENSOR_DI_IS_BUTTON, (uint8_t)validate(s, c));
}

void test_relay_and_sensor_duplicates(void) {
  SystemConfig s = sys8();
  SafetyConfig c = base();
  c.act[1].relay = 5;
  TEST_ASSERT_EQUAL_UINT8((uint8_t)CfgErr::ACT_RELAY_DUP, (uint8_t)validate(s, c));
  c = base();
  c.sens[1] = sensor(3, SensorKind::WATER, 2, 0);
  c.nSens = 2;
  TEST_ASSERT_EQUAL_UINT8((uint8_t)CfgErr::SENSOR_DUP, (uint8_t)validate(s, c));
}

void test_feedback_di_rules(void) {
  SystemConfig s = sys8();
  SafetyConfig c = base();
  c.act[0].fb_di = 3;                                         // sensorle ayni DI
  TEST_ASSERT_EQUAL_UINT8((uint8_t)CfgErr::FB_DI_CONFLICT, (uint8_t)validate(s, c));
  c.act[0].fb_di = 9;                                         // yalniz 8 DI var
  TEST_ASSERT_EQUAL_UINT8((uint8_t)CfgErr::FB_DI_RANGE, (uint8_t)validate(s, c));
  c.act[0].fb_di = 4;
  s.dis[3].target_relay = 2;                                  // duvar butonu
  TEST_ASSERT_EQUAL_UINT8((uint8_t)CfgErr::FB_DI_CONFLICT, (uint8_t)validate(s, c));
  s.dis[3].target_relay = 0;
  c.act[0].fb_timeout_s = 1;
  TEST_ASSERT_EQUAL_UINT8((uint8_t)CfgErr::FB_TIMEOUT_RANGE, (uint8_t)validate(s, c));
  c.act[0].fb_timeout_s = 5;
  TEST_ASSERT_EQUAL_UINT8((uint8_t)CfgErr::OK, (uint8_t)validate(s, c));
}

void test_pulse_valve_rules(void) {
  SystemConfig s = sys8();
  SafetyConfig c = base();
  c.act[0].close_mode = (uint8_t)CloseMode::PULSE_TWO_RELAY;
  c.act[0].relay2 = 0;
  TEST_ASSERT_EQUAL_UINT8((uint8_t)CfgErr::PULSE_RELAY2, (uint8_t)validate(s, c));
  c.act[0].relay2 = 5;
  TEST_ASSERT_EQUAL_UINT8((uint8_t)CfgErr::PULSE_RELAY2, (uint8_t)validate(s, c));
  c.act[0].relay2 = 6;                                        // sirenin rolesi
  TEST_ASSERT_EQUAL_UINT8((uint8_t)CfgErr::ACT_RELAY_DUP, (uint8_t)validate(s, c));
  c.act[0].relay2 = 7;
  TEST_ASSERT_EQUAL_UINT8((uint8_t)CfgErr::OK, (uint8_t)validate(s, c));
  s.relays[6].type = RELAY_TYPE_SHUTTER_UP;
  TEST_ASSERT_EQUAL_UINT8((uint8_t)CfgErr::ACT_RELAY_SHUTTER, (uint8_t)validate(s, c));
  s.relays[6].type = RELAY_TYPE_LIGHT;
  c.act[0].run_limit_s = 121;
  TEST_ASSERT_EQUAL_UINT8((uint8_t)CfgErr::PULSE_TIME, (uint8_t)validate(s, c));
}

void test_misc_bounds(void) {
  SystemConfig s = sys8();
  SafetyConfig c = base();
  c.pol.dry_hold_ms = 999;
  TEST_ASSERT_EQUAL_UINT8((uint8_t)CfgErr::DRY_HOLD, (uint8_t)validate(s, c));
  c = base();
  c.sens[0].zone = 5;
  TEST_ASSERT_EQUAL_UINT8((uint8_t)CfgErr::SENSOR_ZONE, (uint8_t)validate(s, c));
  c = base();
  c.sens[0].confirm_ms = 50;
  TEST_ASSERT_EQUAL_UINT8((uint8_t)CfgErr::CONFIRM_RANGE, (uint8_t)validate(s, c));
  c = base();
  c.act[0].zone_mask = 0;
  TEST_ASSERT_EQUAL_UINT8((uint8_t)CfgErr::ACT_ZONE, (uint8_t)validate(s, c));
  c = base();
  c.sens[0].kind = 9;
  TEST_ASSERT_EQUAL_UINT8((uint8_t)CfgErr::SENSOR_KIND, (uint8_t)validate(s, c));
  c = base();
  memset(c.sens[0].name, 'a', sizeof(c.sens[0].name));       // NUL yok
  TEST_ASSERT_EQUAL_UINT8((uint8_t)CfgErr::NAME, (uint8_t)validate(s, c));
  c = base();
  c.nSens = 57;
  TEST_ASSERT_EQUAL_UINT8((uint8_t)CfgErr::COUNT, (uint8_t)validate(s, c));
  c = base();
  c.sens[1] = sensor(4, SensorKind::ALARM_ACK, 0, 0);        // kontrol rolu: bolge 0 = tum bolgeler
  c.nSens = 2;
  TEST_ASSERT_EQUAL_UINT8((uint8_t)CfgErr::OK, (uint8_t)validate(s, c));
  c.sens[1].src = (uint8_t)SensorSrc::BRIDGE;                 // kontrol rolu yalniz yerel DI
  c.sens[1].index = 2;
  TEST_ASSERT_EQUAL_UINT8((uint8_t)CfgErr::SENSOR_SRC, (uint8_t)validate(s, c));
}

void test_locked_zone_changes_rejected(void) {
  SafetyConfig a = base();
  SafetyConfig b = base();
  TEST_ASSERT_FALSE(touchesLockedZones(a, b, 0x01));
  b.act[0].medium = (uint8_t)Medium::GAS;                     // kilitli bolgedeki vananin akiskani degisti
  TEST_ASSERT_TRUE(touchesLockedZones(a, b, 0x01));
  TEST_ASSERT_FALSE(touchesLockedZones(a, b, 0x02));          // kilit baska bolgede
  b = base();
  b.nAct = 1;                                                 // siren silindi
  TEST_ASSERT_TRUE(touchesLockedZones(a, b, 0x01));
  b = base();
  b.sens[0].zone = 2;                                         // sensor baska bolgeye
  TEST_ASSERT_TRUE(touchesLockedZones(a, b, 0x01));
  TEST_ASSERT_TRUE(touchesLockedZones(a, b, 0x02));
  b = base();
  b.pol.policy_on = 0;                                        // politika kapatma kabul edilir (kilidi kaldirmaz) [O-10]
  TEST_ASSERT_FALSE(touchesLockedZones(a, b, 0x01));
  b = base();
  b.sens[1] = sensor(4, SensorKind::WATER, 2, 0);             // kilitsiz bolgeye ekleme serbest
  b.nSens = 2;
  TEST_ASSERT_FALSE(touchesLockedZones(a, b, 0x01));
}

void test_crc32_known_vector(void) {
  TEST_ASSERT_EQUAL_HEX32(0xCBF43926u, crc32("123456789", 9));
  TEST_ASSERT_EQUAL_HEX32(0x00000000u, crc32("", 0));
}

void test_blob_round_trip_and_corruption(void) {
  SafetyConfig c = base();
  uint8_t buf[MAX_SENSORS * sizeof(SensorConfig) + 4];
  size_t len = packBlob(c.sens, c.nSens, sizeof(SensorConfig), buf, sizeof(buf));
  TEST_ASSERT_EQUAL_UINT32(28 + 4, len);                      // yalniz dolu yuvalar [B9]
  SensorConfig out[MAX_SENSORS];
  TEST_ASSERT_EQUAL_INT(1, unpackBlob(buf, len, sizeof(SensorConfig), out, MAX_SENSORS));
  TEST_ASSERT_EQUAL_MEMORY(&c.sens[0], &out[0], sizeof(SensorConfig));
  buf[5] ^= 0x10;                                             // tek bit bozulmasi
  TEST_ASSERT_EQUAL_INT(-1, unpackBlob(buf, len, sizeof(SensorConfig), out, MAX_SENSORS));
  TEST_ASSERT_EQUAL_INT(-1, unpackBlob(buf, len - 1, sizeof(SensorConfig), out, MAX_SENSORS));
  TEST_ASSERT_EQUAL_UINT32(0, packBlob(c.sens, c.nSens, sizeof(SensorConfig), buf, 10));   // sigmiyor
  // bos tablo: yalniz CRC
  len = packBlob(c.sens, 0, sizeof(SensorConfig), buf, sizeof(buf));
  TEST_ASSERT_EQUAL_UINT32(4, len);
  TEST_ASSERT_EQUAL_INT(0, unpackBlob(buf, len, sizeof(SensorConfig), out, MAX_SENSORS));
}

void test_config_crc_tracks_content(void) {
  SafetyConfig a = base();
  SafetyConfig b = base();
  TEST_ASSERT_EQUAL_HEX32(configCrc(a), configCrc(b));
  b.sens[0].confirm_ms = 1200;
  TEST_ASSERT_NOT_EQUAL(configCrc(a), configCrc(b));
  b = base();
  b.sens[5].kind = 7;                                         // kullanilmayan yuva CRC'ye girmez
  TEST_ASSERT_EQUAL_HEX32(configCrc(a), configCrc(b));
  b.rev = 99;                                                 // rev ayri ilan edilir, CRC'ye girmez
  TEST_ASSERT_EQUAL_HEX32(configCrc(a), configCrc(b));
}

void test_latch_record_seal_and_masks(void) {
  LatchRecord r;
  latchClear(r);
  TEST_ASSERT_FALSE(latchAny(r));
  TEST_ASSERT_TRUE(latchValid(r));
  r.z[0].st = 1;
  strcpy(r.z[0].aid, "9f3a11c0-3");
  r.m.localAssert = 0x10;
  r.m.localLevel = 0x10;
  r.m.extAssert = 0x00000004u;                                // role 11
  r.m.extLevel = 0;
  latchSeal(r);
  TEST_ASSERT_TRUE(latchValid(r));
  TEST_ASSERT_TRUE(latchAny(r));
  TEST_ASSERT_EQUAL_UINT8(0x01, latchZoneMask(r));
  TEST_ASSERT_EQUAL_UINT64((1ULL << 4) | (1ULL << 10), latchAssert64(r));
  TEST_ASSERT_EQUAL_UINT64(1ULL << 4, latchLevel64(r));
  r.z[0].kinds = 3;                                           // muhurden sonra degisiklik -> gecersiz
  TEST_ASSERT_FALSE(latchValid(r));
  LatchRecord q;
  latchClear(q);
  latchSetMasks(q, (1ULL << 4) | (1ULL << 10), 1ULL << 4);
  TEST_ASSERT_EQUAL_UINT8(0x10, q.m.localAssert);
  TEST_ASSERT_EQUAL_UINT32(0x4u, q.m.extAssert);
}

void test_crash_loop_counter(void) {
  CrashLog c;
  crashClear(c);
  crashOnBoot(c, false);                                      // planli yeniden baslatma sayilmaz
  TEST_ASSERT_FALSE(crashLoop(c));
  crashOnBoot(c, true);
  crashOnBoot(c, true);
  TEST_ASSERT_FALSE(crashLoop(c));
  crashOnBoot(c, true);
  TEST_ASSERT_TRUE(crashLoop(c));                             // 3 beklenmeyen sifirlama (arada 10 dk kararli calisma yok)
  TEST_ASSERT_FALSE(crashStableTick(c, CRASH_STABLE_MS - 1));
  TEST_ASSERT_TRUE(crashStableTick(c, CRASH_STABLE_MS));      // 10 dk kararli: sayac sifirlanir (yazilacak)
  TEST_ASSERT_FALSE(crashLoop(c));
  TEST_ASSERT_FALSE(crashStableTick(c, CRASH_STABLE_MS + 5));// ikinci kez yazim yok
  for (int i = 0; i < 300; i++) crashOnBoot(c, true);
  TEST_ASSERT_EQUAL_UINT8(255, c.count);                      // doyar, tasmaz
}

void test_boot_mode_decision(void) {
  SafetyConfig cfg = base();
  CrashLog crash;
  crashClear(crash);
  LatchRecord latch;
  latchClear(latch);
  TEST_ASSERT_EQUAL_UINT8((uint8_t)SafeReason::NONE, (uint8_t)decideBootMode(true, true, &latch, cfg, crash));
  TEST_ASSERT_EQUAL_UINT8((uint8_t)SafeReason::CFG_CORRUPT, (uint8_t)decideBootMode(true, false, &latch, cfg, crash));
  TEST_ASSERT_EQUAL_UINT8((uint8_t)SafeReason::NONE, (uint8_t)decideBootMode(false, false, &latch, cfg, crash));   // hic yapilandirma yok = fabrika
  latch.z[0].st = 1;
  latchSetMasks(latch, 1ULL << 4, 0);
  latchSeal(latch);
  TEST_ASSERT_EQUAL_UINT8((uint8_t)SafeReason::NONE, (uint8_t)decideBootMode(true, true, &latch, cfg, crash));
  SafetyConfig empty;
  empty.setDefaults();                                        // fabrika sifirlamasi sonrasi: kilit var, eylemci yok
  TEST_ASSERT_EQUAL_UINT8((uint8_t)SafeReason::LATCH_ORPHAN, (uint8_t)decideBootMode(false, false, &latch, empty, crash));
  latchSetMasks(latch, 1ULL << 7, 0);                         // kilitteki role (8) eylemci tablosunda yok
  latchSeal(latch);
  TEST_ASSERT_EQUAL_UINT8((uint8_t)SafeReason::LATCH_ORPHAN, (uint8_t)decideBootMode(true, true, &latch, cfg, crash));
  latchClear(latch);
  for (int i = 0; i < 3; i++) crashOnBoot(crash, true);
  TEST_ASSERT_EQUAL_UINT8((uint8_t)SafeReason::CRASH_LOOP, (uint8_t)decideBootMode(true, true, &latch, cfg, crash));
  TEST_ASSERT_EQUAL_STRING("crash_loop", safeReasonText(SafeReason::CRASH_LOOP));
  TEST_ASSERT_EQUAL_STRING("latch_orphan", safeReasonText(SafeReason::LATCH_ORPHAN));
  TEST_ASSERT_EQUAL_STRING("cfg_corrupt", safeReasonText(SafeReason::CFG_CORRUPT));
}

// Inceleme turu (entegrasyon) RV-3: yapilandirma yazimi, kilit kaydi/act_pos/guvenli maske guncellemeleri icin ayrilan bos girdi payini
// (NVS_SAFETY_RESERVE_ENTRIES) yiyemez. Girdi tahmini: blob = indeks + veri basligi + 32 B'lik veri girdileri.
void test_nvs_entry_budget(void) {
  TEST_ASSERT_EQUAL_UINT16(3, nvsBlobEntries(20));
  TEST_ASSERT_EQUAL_UINT16(8, nvsBlobEntries(sizeof(LatchRecord)));
  SafetyConfig c;
  c.setDefaults();
  const uint16_t e0 = configNvsEntries(c);
  // ver x2 + rev + pol(20 B) + bolgeler(68 B) + bos sensor(4 B) + bos eylemci(4 B) + isik(164 B)
  TEST_ASSERT_EQUAL_UINT16(3 + 3 + 5 + 3 + 3 + 8, e0);
  c = base();
  TEST_ASSERT_TRUE(configNvsEntries(c) > e0);
  const uint16_t need = configNvsEntries(c) + NVS_SAFETY_RESERVE_ENTRIES + NVS_GC_PAGE_ENTRIES;
  TEST_ASSERT_TRUE(nvsRoomForConfig(need, c));
  TEST_ASSERT_FALSE(nvsRoomForConfig(need - 1, c));
}

// Inceleme turu 2 FW2-3: IDF 4.4 nvs_stats_t.free_entries cop toplama icin bos tutulan sayfayi (126 girdi) da sayar; o sayfa yazima
// kullanilamaz. Pay hesabi bu sayfayi dusmezse "yer var" denir, yazim yarida kalir ve geri yazim da ayni denetime takilip ver=0 birakir.
void test_nvs_budget_excludes_gc_page(void) {
  TEST_ASSERT_EQUAL_UINT16(126, NVS_GC_PAGE_ENTRIES);
  SafetyConfig c = base();
  const uint32_t cfgE = configNvsEntries(c);
  TEST_ASSERT_FALSE(nvsRoomForConfig(cfgE + NVS_SAFETY_RESERVE_ENTRIES, c));
  TEST_ASSERT_FALSE(nvsRoomForConfig(cfgE + NVS_SAFETY_RESERVE_ENTRIES + 125, c));
  TEST_ASSERT_TRUE(nvsRoomForConfig(cfgE + NVS_SAFETY_RESERVE_ENTRIES + 126, c));
}

// Inceleme turu 2 FW2-1: ana yapilandirma degisimi, guvenlik yapilandirmasi bos (cfg_corrupt guvenli kipi) olsa bile acilis guvenli
// maskesindeki / kilit maskesindeki roleyi panjur ya da darbe rolesine CEVIREMEZ: Relay_Init bu maskeyi ana yapilandirma yuklenmeden
// once uygular (darbe rolesi kesintisiz enerjili kalirdi).
void test_system_change_respects_relay_guard(void) {
  static SafetyConfig empty;
  empty.setDefaults();
  SystemConfig s = sys8();
  const uint64_t guard = (1ULL << 2) | (1ULL << 4);              // role 3 ve 5
  TEST_ASSERT_EQUAL_UINT8((uint8_t)CfgErr::OK, (uint8_t)validateSystemChange(s, empty, guard));
  s.relays[2].type = RELAY_TYPE_IMPULSE;
  TEST_ASSERT_EQUAL_UINT8((uint8_t)CfgErr::OK, (uint8_t)validate(s, empty));   // eski yol: bos tabloya karsi gecerdi
  TEST_ASSERT_EQUAL_UINT8((uint8_t)CfgErr::ACT_RELAY_IMPULSE, (uint8_t)validateSystemChange(s, empty, guard));
  s = sys8();
  s.relays[4].type = RELAY_TYPE_SHUTTER_UP;
  s.relays[5].type = RELAY_TYPE_SHUTTER_DOWN;
  TEST_ASSERT_EQUAL_UINT8((uint8_t)CfgErr::ACT_RELAY_SHUTTER, (uint8_t)validateSystemChange(s, empty, guard));
  // maskede olmayan role serbest; maske bossa bugunku davranis
  s = sys8();
  s.relays[0].type = RELAY_TYPE_IMPULSE;
  s.relays[6].type = RELAY_TYPE_SHUTTER_UP;
  s.relays[7].type = RELAY_TYPE_SHUTTER_DOWN;
  TEST_ASSERT_EQUAL_UINT8((uint8_t)CfgErr::OK, (uint8_t)validateSystemChange(s, empty, guard));
  TEST_ASSERT_EQUAL_UINT8((uint8_t)CfgErr::ACT_RELAY_IMPULSE, (uint8_t)validateSystemChange(s, empty, 1ULL));
  // guvenlik tablosunun kendi hatasi once doner
  SafetyConfig c = base();
  s = sys8();
  s.relays[4].type = RELAY_TYPE_IMPULSE;                          // vana rolesi (5)
  TEST_ASSERT_EQUAL_UINT8((uint8_t)validate(s, c), (uint8_t)validateSystemChange(s, c, 0));
  TEST_ASSERT_TRUE(validateSystemChange(s, c, 0) != CfgErr::OK);
}

// Inceleme turu EM-5: guvenli kipte dayatilan acilis maskesi panjur/darbe rolesine ve var olmayan roleye dokunmaz.
void test_boot_mask_for_system_filters_shutter_and_missing(void) {
  SystemConfig s = sys8();
  s.relays[0].type = RELAY_TYPE_SHUTTER_UP;
  s.relays[1].type = RELAY_TYPE_SHUTTER_DOWN;
  s.relays[2].type = RELAY_TYPE_IMPULSE;
  const uint64_t all = 0xFFULL | (1ULL << 20);
  TEST_ASSERT_EQUAL_HEX64(0xF8ULL, bootMaskForSystem(s, all));
}

// Faz 2 (F2.B.1): hirsiz gecikmeleri Policy'nin ayrilmis baytlarinda (yeni NVS girdisi yok); 16 B duzen ve fabrika CRC'si degismez.
// ARM_KEY yalniz panodaki DI'den (kumanda rolu), bolge 0 = tum ev; kapi/pencere/hareket sensorlerinin hirsiz bitleri gecerli.
void test_intrusion_policy_layout_and_roles(void) {
  TEST_ASSERT_EQUAL_INT(8, (int)offsetof(Policy, exit_s));
  TEST_ASSERT_EQUAL_INT(9, (int)offsetof(Policy, entry_s));
  TEST_ASSERT_EQUAL_INT(16, (int)sizeof(Policy));
  SafetyConfig c;
  c.setDefaults();
  TEST_ASSERT_EQUAL_UINT8(0, c.pol.exit_s);
  TEST_ASSERT_EQUAL_UINT8(0, c.pol.entry_s);
  uint8_t raw[16];
  memset(raw, 0, sizeof(raw));
  raw[0] = 1;
  const uint32_t dh = DRY_HOLD_DEFAULT_MS;
  memcpy(raw + 4, &dh, 4);
  TEST_ASSERT_EQUAL_MEMORY(raw, &c.pol, 16);           // eski (v1.2.0) Policy blob'u ile bayt bayt ayni
  const SystemConfig sys = sys8();
  SafetyConfig k = base();
  k.sens[1] = sensor(4, SensorKind::ARM_KEY, 0, 1);
  k.sens[2] = sensor(7, SensorKind::DOOR, 2, 1);
  k.sens[2].flags = SF_REACT | SF_ENTRY | SF_AWAY_ONLY;
  k.nSens = 3;
  k.pol.exit_s = 255;
  k.pol.entry_s = 1;
  TEST_ASSERT_EQUAL(CfgErr::OK, validate(sys, k));
  // Faz 2 incelemesi RV-E3: anahtarli kontak yalniz NC (active_open=1): kablo kesilince "aktif" (kurulu) okunur, alarm COZULMEZ.
  k.sens[1].active_open = 0;
  TEST_ASSERT_EQUAL(CfgErr::ARM_KEY_NOT_NC, validate(sys, k));
  TEST_ASSERT_EQUAL_STRING("arm_key_not_nc", cfgErrText(CfgErr::ARM_KEY_NOT_NC));
  k.sens[1].active_open = 1;
  k.sens[1].src = (uint8_t)SensorSrc::BRIDGE;          // kumanda rolu kopruden olamaz
  k.sens[1].index = 2;
  TEST_ASSERT_EQUAL(CfgErr::SENSOR_SRC, validate(sys, k));
}

int main(int, char**) {
  UNITY_BEGIN();
  RUN_TEST(test_sizes);
  RUN_TEST(test_factory_defaults);
  RUN_TEST(test_valid_base_config);
  RUN_TEST(test_actuator_on_shutter_or_impulse_relay_rejected);
  RUN_TEST(test_channel_count_drop_rejected);
  RUN_TEST(test_valve_requires_medium);
  RUN_TEST(test_siren_run_limit_range);
  RUN_TEST(test_gas_and_smoke_must_be_nc);
  RUN_TEST(test_sensor_di_cannot_be_wall_button);
  RUN_TEST(test_relay_and_sensor_duplicates);
  RUN_TEST(test_feedback_di_rules);
  RUN_TEST(test_pulse_valve_rules);
  RUN_TEST(test_misc_bounds);
  RUN_TEST(test_locked_zone_changes_rejected);
  RUN_TEST(test_crc32_known_vector);
  RUN_TEST(test_blob_round_trip_and_corruption);
  RUN_TEST(test_config_crc_tracks_content);
  RUN_TEST(test_latch_record_seal_and_masks);
  RUN_TEST(test_crash_loop_counter);
  RUN_TEST(test_boot_mode_decision);
  RUN_TEST(test_nvs_entry_budget);
  RUN_TEST(test_boot_mask_for_system_filters_shutter_and_missing);
  RUN_TEST(test_nvs_budget_excludes_gc_page);
  RUN_TEST(test_system_change_respects_relay_guard);
  RUN_TEST(test_intrusion_policy_layout_and_roles);
  return UNITY_END();
}
