// SensorHub / DiSensor / BridgeSensor (src/sensors/*.h) birim testleri. SAF MANTIK: Arduino/FreeRTOS yok, saat parametre.
// Kapsam (spec 2.5, 2.6, 5.5): NC cevirme, pencereli onay (damla), tek kisa sicrama, ok=false semantigi, kuruluk sayaci,
// kopru kalp atisi, ek DI ilk okumadan once ok=false, kontrol rolleri (kenar + basili tutma), MOMENTARY artigi temizligi.
#include <unity.h>
#include <stdint.h>
#include <string.h>
#include "sensors/SensorTypes.h"
#include "sensors/SensorHub.h"
#include "sensors/DiSensor.h"
#include "sensors/BridgeSensor.h"

using namespace safety;

void setUp(void) {}
void tearDown(void) {}

static SensorConfig mk(uint8_t src, uint8_t index, SensorKind kind, uint8_t zone, uint8_t activeOpen) {
  SensorConfig c;
  memset(&c, 0, sizeof(c));
  c.src = src;
  c.index = index;
  c.kind = (uint8_t)kind;
  c.zone = zone;
  c.active_open = activeOpen;
  c.flags = defaultFlags((uint8_t)kind);
  c.confirm_ms = defaultConfirmMs((uint8_t)kind);
  return c;
}

// Tek sensorlu hub'i `ms` boyunca `step` adimlarla ayni ham seviyeyle surer.
static uint32_t drive(SensorHub& h, uint8_t slot, bool level, bool ok, uint32_t t, uint32_t ms, uint32_t step = 10) {
  for (uint32_t d = 0; d < ms; d += step) {
    t += step;
    h.update(slot, level, ok, t);
    h.finish(t);
  }
  return t;
}

void test_struct_sizes_are_fixed(void) {
  TEST_ASSERT_EQUAL_UINT32(28, sizeof(SensorConfig));
}

void test_kind_defaults(void) {
  TEST_ASSERT_EQUAL_UINT16(1000, defaultConfirmMs((uint8_t)SensorKind::WATER));
  TEST_ASSERT_EQUAL_UINT16(300, defaultConfirmMs((uint8_t)SensorKind::GAS));
  TEST_ASSERT_EQUAL_UINT16(300, defaultConfirmMs((uint8_t)SensorKind::SMOKE));
  TEST_ASSERT_EQUAL_UINT16(0, defaultConfirmMs((uint8_t)SensorKind::DOOR));
  TEST_ASSERT_EQUAL_UINT16(3000, confirmWindowMs((uint8_t)SensorKind::WATER));
  TEST_ASSERT_EQUAL_UINT16(1000, confirmWindowMs((uint8_t)SensorKind::GAS));
  TEST_ASSERT_EQUAL_UINT8(HZ_WATER, hazardOf((uint8_t)SensorKind::WATER));
  TEST_ASSERT_EQUAL_UINT8(HZ_GAS, hazardOf((uint8_t)SensorKind::GAS));
  TEST_ASSERT_EQUAL_UINT8(HZ_SMOKE, hazardOf((uint8_t)SensorKind::SMOKE));
  TEST_ASSERT_EQUAL_UINT8(0, hazardOf((uint8_t)SensorKind::DOOR));
  TEST_ASSERT_TRUE(isControlRole((uint8_t)SensorKind::ALARM_ACK));
  TEST_ASSERT_TRUE(isControlRole((uint8_t)SensorKind::GAS_RESET));
  TEST_ASSERT_FALSE(isControlRole((uint8_t)SensorKind::WATER));
  // varsayilan "arizada kapat": su 0, gaz 1, duman 0 (spec 2.5)
  TEST_ASSERT_EQUAL_UINT8(0, defaultFlags((uint8_t)SensorKind::WATER) & SF_FAULT_CLOSE);
  TEST_ASSERT_EQUAL_UINT8(SF_FAULT_CLOSE, defaultFlags((uint8_t)SensorKind::GAS) & SF_FAULT_CLOSE);
  TEST_ASSERT_EQUAL_UINT8(0, defaultFlags((uint8_t)SensorKind::SMOKE) & SF_FAULT_CLOSE);
  TEST_ASSERT_EQUAL_UINT8(SF_REACT, defaultFlags((uint8_t)SensorKind::WATER) & SF_REACT);
}

void test_nc_contact_inverts_level(void) {
  SensorConfig c[2] = {mk(0, 1, SensorKind::DOOR, 1, 0), mk(0, 2, SensorKind::DOOR, 1, 1)};
  SensorHub h;
  h.configure(c, 2, 0);
  h.update(0, true, true, 10);    // NO: kontak kapali = aktif
  h.update(1, true, true, 10);    // NC: kontak kapali = PASIF
  h.finish(10);
  TEST_ASSERT_TRUE(h.active(0));
  TEST_ASSERT_FALSE(h.active(1));
  h.update(0, false, true, 20);
  h.update(1, false, true, 20);   // NC: kontak acildi = AKTIF (kablo koptu da ayni)
  h.finish(20);
  TEST_ASSERT_FALSE(h.active(0));
  TEST_ASSERT_TRUE(h.active(1));
}

void test_short_splash_does_not_confirm(void) {
  SensorConfig c = mk(0, 3, SensorKind::WATER, 1, 0);
  SensorHub h;
  h.configure(&c, 1, 0);
  uint32_t t = drive(h, 0, true, true, 0, 300);     // tek 300 ms sicrama (temizlik bezi)
  t = drive(h, 0, false, true, t, 4000);
  TEST_ASSERT_FALSE(h.active(0));
  TEST_ASSERT_EQUAL_UINT8(0, h.zoneWet(1));
}

void test_continuous_wet_confirms_after_confirm_ms(void) {
  SensorConfig c = mk(0, 3, SensorKind::WATER, 1, 0);
  SensorHub h;
  h.configure(&c, 1, 0);
  uint32_t t = drive(h, 0, true, true, 0, 900);
  TEST_ASSERT_FALSE(h.active(0));
  t = drive(h, 0, true, true, t, 200);
  TEST_ASSERT_TRUE(h.active(0));
  TEST_ASSERT_EQUAL_UINT8(HZ_WATER, h.zoneWet(1));
  TEST_ASSERT_EQUAL_UINT8(0, h.zoneWet(2));
}

void test_drip_pattern_confirms_by_accumulation(void) {
  SensorConfig c = mk(0, 3, SensorKind::WATER, 1, 0);
  SensorHub h;
  h.configure(&c, 1, 0);
  uint32_t t = 0;
  bool seen = false;
  for (int k = 0; k < 8 && !seen; k++) {       // 300 ms aktif / 200 ms pasif
    t = drive(h, 0, true, true, t, 300);
    seen = seen || h.active(0);
    t = drive(h, 0, false, true, t, 200);
    seen = seen || h.active(0);
  }
  TEST_ASSERT_TRUE(seen);
  TEST_ASSERT_TRUE(t <= 3000);                  // pencere (3 sn) icinde onay
}

void test_window_forgets_old_activity(void) {
  SensorConfig c = mk(0, 3, SensorKind::WATER, 1, 0);
  SensorHub h;
  h.configure(&c, 1, 0);
  uint32_t t = drive(h, 0, true, true, 0, 600);   // 600 ms
  t = drive(h, 0, false, true, t, 5000);           // pencere disina tasindi
  t = drive(h, 0, true, true, t, 600);             // yeni 600 ms: toplam pencere icinde 600 < 1000
  TEST_ASSERT_FALSE(h.active(0));
}

void test_gas_confirms_fast(void) {
  SensorConfig c = mk(0, 1, SensorKind::GAS, 1, 1);   // NC zorunlu
  SensorHub h;
  h.configure(&c, 1, 0);
  uint32_t t = drive(h, 0, false, true, 0, 250);      // NC: kontak acik = aktif
  TEST_ASSERT_FALSE(h.active(0));
  t = drive(h, 0, false, true, t, 100);
  TEST_ASSERT_TRUE(h.active(0));
  TEST_ASSERT_EQUAL_UINT8(HZ_GAS, h.zoneWet(1));
}

void test_not_ok_sensor_is_neither_wet_nor_dry(void) {
  SensorConfig c = mk(0, 3, SensorKind::WATER, 1, 0);
  SensorHub h;
  h.configure(&c, 1, 0);
  uint32_t t = drive(h, 0, true, false, 0, 3000);    // ok=false iken ham seviye aktif
  TEST_ASSERT_FALSE(h.active(0));
  TEST_ASSERT_EQUAL_UINT8(0, h.zoneWet(1));
  TEST_ASSERT_EQUAL_UINT8(HZ_WATER, h.zoneFault(1));
  TEST_ASSERT_EQUAL_UINT32(0, h.zoneDryMs(1, t));    // kuruluk sayaci ilerlemez
  t = drive(h, 0, false, false, t, 20000);
  TEST_ASSERT_EQUAL_UINT32(0, h.zoneDryMs(1, t));
}

void test_dry_counter_needs_uninterrupted_ok_and_inactive(void) {
  SensorConfig c = mk(0, 3, SensorKind::WATER, 1, 0);
  SensorHub h;
  h.configure(&c, 1, 0);
  uint32_t t = drive(h, 0, false, true, 0, 5000);
  TEST_ASSERT_TRUE(h.zoneDryMs(1, t) >= 4900);
  t = drive(h, 0, true, true, t, 20);                // tek aktif okuma sayaci sifirlar
  t = drive(h, 0, false, true, t, 100);
  TEST_ASSERT_TRUE(h.zoneDryMs(1, t) < 200);
  t = drive(h, 0, false, false, t, 20);              // ok=false da sifirlar
  t = drive(h, 0, false, true, t, 100);
  TEST_ASSERT_TRUE(h.zoneDryMs(1, t) < 200);
}

void test_dry_counter_waits_until_confirmation_window_drains(void) {
  SensorConfig c = mk(0, 3, SensorKind::WATER, 1, 0);
  SensorHub h;
  h.configure(&c, 1, 0);
  uint32_t t = drive(h, 0, true, true, 0, 2000);
  TEST_ASSERT_TRUE(h.active(0));
  t = drive(h, 0, false, true, t, 100);
  // ham seviye pasif ama onay penceresi hala dolu: "ok && !active" degil, kuruluk sayilmaz
  TEST_ASSERT_TRUE(h.active(0));
  TEST_ASSERT_EQUAL_UINT32(0, h.zoneDryMs(1, t));
  t = drive(h, 0, false, true, t, 4000);
  TEST_ASSERT_FALSE(h.active(0));
  TEST_ASSERT_TRUE(h.zoneDryMs(1, t) > 0);
}

void test_fault_edges_reported_once(void) {
  SensorConfig c = mk(0, 3, SensorKind::WATER, 1, 0);
  SensorHub h;
  h.configure(&c, 1, 0);
  uint32_t t = drive(h, 0, false, true, 0, 100);
  TEST_ASSERT_EQUAL_UINT64(0, h.takeFaultEdges());
  t = drive(h, 0, false, false, t, 100);
  TEST_ASSERT_EQUAL_UINT64(1, h.takeFaultEdges());
  TEST_ASSERT_EQUAL_UINT64(0, h.takeFaultEdges());
  t = drive(h, 0, false, true, t, 100);
  TEST_ASSERT_EQUAL_UINT64(1, h.takeFaultClearedEdges());
  TEST_ASSERT_EQUAL_UINT64(0, h.takeFaultClearedEdges());
}

void test_initially_unknown_sensor_does_not_report_fault_edge(void) {
  // Acilista ok=false (ilk okuma yok) bir ariza "gecisi" degildir; ilk ok=true sonra kopma gecistir.
  SensorConfig c = mk(0, 9, SensorKind::WATER, 1, 1);
  SensorHub h;
  h.configure(&c, 1, 0);
  uint32_t t = drive(h, 0, false, false, 0, 500);
  TEST_ASSERT_EQUAL_UINT64(0, h.takeFaultEdges());
  TEST_ASSERT_FALSE(h.active(0));                    // NC + kontak acik + ok=false: SAHTE ALARM YOK
  t = drive(h, 0, true, true, t, 100);
  TEST_ASSERT_EQUAL_UINT64(0, h.takeFaultClearedEdges());
}

void test_fault_close_flag_counts_fault_as_wet(void) {
  SensorConfig c = mk(0, 1, SensorKind::GAS, 1, 1);   // gaz: varsayilan "arizada kapat"
  SensorHub h;
  h.configure(&c, 1, 0);
  uint32_t t = drive(h, 0, true, true, 0, 100);
  TEST_ASSERT_EQUAL_UINT8(0, h.zoneWet(1));
  t = drive(h, 0, true, false, t, 50);               // once ok, sonra ariza
  TEST_ASSERT_EQUAL_UINT8(HZ_GAS, h.zoneWet(1));
  SensorConfig w = mk(0, 2, SensorKind::WATER, 1, 0);  // su: arizada kapatmaz
  SensorHub h2;
  h2.configure(&w, 1, 0);
  t = drive(h2, 0, false, true, 0, 100);
  t = drive(h2, 0, false, false, t, 50);
  TEST_ASSERT_EQUAL_UINT8(0, h2.zoneWet(1));
  TEST_ASSERT_EQUAL_UINT8(HZ_WATER, h2.zoneFault(1));
  // Hic okunamayan gaz sensoru: acilis sonrasi 30 sn tolerans, sonra ariza = islak (modul hic yanit vermiyor)
  SensorHub h3;
  h3.configure(&c, 1, 0);
  t = drive(h3, 0, false, false, 0, 29000, 100);
  TEST_ASSERT_EQUAL_UINT8(0, h3.zoneWet(1));
  t = drive(h3, 0, false, false, t, 1100, 100);
  TEST_ASSERT_EQUAL_UINT8(HZ_GAS, h3.zoneWet(1));
}

void test_react_flag_off_never_wets_zone(void) {
  SensorConfig c = mk(0, 3, SensorKind::WATER, 1, 0);
  c.flags = 0;
  SensorHub h;
  h.configure(&c, 1, 0);
  drive(h, 0, true, true, 0, 2000);
  TEST_ASSERT_TRUE(h.active(0));
  TEST_ASSERT_EQUAL_UINT8(0, h.zoneWet(1));
}

void test_zone_sources_list_wet_sensors(void) {
  SensorConfig c[3] = {mk(0, 3, SensorKind::WATER, 1, 0), mk(1, 2, SensorKind::WATER, 1, 0), mk(0, 5, SensorKind::WATER, 2, 0)};
  SensorHub h;
  h.configure(c, 3, 0);
  uint32_t t = 0;
  for (int k = 0; k < 150; k++) {
    t += 10;
    h.update(0, true, true, t);
    h.update(1, true, true, t);
    h.update(2, false, true, t);
    h.finish(t);
  }
  uint8_t ids[8];
  uint8_t n = h.zoneSources(1, HZ_WATER, ids, 8);
  TEST_ASSERT_EQUAL_UINT8(2, n);
  TEST_ASSERT_EQUAL_UINT8(3, ids[0]);                // DI 3 -> "d3"
  TEST_ASSERT_EQUAL_UINT8(0x80 | 2, ids[1]);         // kopru yuvasi 2 -> "b2"
  char s[5];
  sensorIdText(ids[1], s);
  TEST_ASSERT_EQUAL_STRING("b2", s);
  sensorIdText(40, s);
  TEST_ASSERT_EQUAL_STRING("d40", s);
}

void test_control_role_press_edge_and_hold(void) {
  SensorConfig c = mk(0, 6, SensorKind::ALARM_ACK, 0, 0);
  SensorHub h;
  h.configure(&c, 1, 0);
  uint32_t t = drive(h, 0, false, true, 0, 100);
  TEST_ASSERT_EQUAL_UINT64(0, h.takeControlPresses());
  t += 10;
  h.update(0, true, true, t);
  h.finish(t);
  TEST_ASSERT_EQUAL_UINT64(1, h.takeControlPresses());
  t = drive(h, 0, true, true, t, 5000);
  TEST_ASSERT_EQUAL_UINT64(0, h.takeControlPresses());   // basili tutma yeni kenar degil
  TEST_ASSERT_TRUE(h.heldMs(0, t) >= 5000);
  TEST_ASSERT_EQUAL_UINT8(0, h.zoneWet(0));              // kontrol rolu bolge islakligina girmez
  t = drive(h, 0, false, true, t, 50);
  TEST_ASSERT_EQUAL_UINT32(0, h.heldMs(0, t));
}

void test_control_role_already_pressed_at_boot_is_not_an_edge(void) {
  SensorConfig c = mk(0, 6, SensorKind::VALVE_CLOSE, 0, 0);
  SensorHub h;
  h.configure(&c, 1, 0);
  h.update(0, true, true, 10);    // ilk okuma zaten basili: kenar degil (DiGate "ilk okuma kenar uretmez" kurali)
  h.finish(10);
  TEST_ASSERT_EQUAL_UINT64(0, h.takeControlPresses());
}

void test_millis_rollover(void) {
  SensorConfig c = mk(0, 3, SensorKind::WATER, 1, 0);
  SensorHub h;
  h.configure(&c, 1, 0xFFFFF000u);
  uint32_t t = drive(h, 0, true, true, 0xFFFFF000u, 1200);
  TEST_ASSERT_TRUE(h.active(0));
  t = drive(h, 0, false, true, t, 15000);
  TEST_ASSERT_FALSE(h.active(0));
  TEST_ASSERT_TRUE(h.zoneDryMs(1, t) >= 10000);
}

void test_zone_without_hazard_sensors_is_dry_since_configure(void) {
  SensorConfig c = mk(0, 1, SensorKind::DOOR, 2, 0);
  SensorHub h;
  h.configure(&c, 1, 1000);
  h.update(0, true, true, 3000);
  h.finish(3000);
  TEST_ASSERT_EQUAL_UINT32(2000, h.zoneDryMs(2, 3000));
  TEST_ASSERT_EQUAL_UINT32(2000, h.zoneDryMs(1, 3000));
}

// ---------------------------------------------------------------------------- DiSensor
void test_di_sensor_local_ok_only_after_first_read(void) {
  digate::DiGate g;
  DiSensor d(&g);
  SensorConfig c = mk(0, 3, SensorKind::WATER, 1, 1);
  SensorSample s = d.sample(c, 0);
  TEST_ASSERT_FALSE(s.ok);                           // ilk DI okuma turu bitmedi
  d.setLocalReady(true);
  g.init(2, true, 0);                                // DI 3 kararli "kapali"
  s = d.sample(c, 0);
  TEST_ASSERT_TRUE(s.ok);
  TEST_ASSERT_TRUE(s.level);
}

void test_di_sensor_ext_ok_requires_module(void) {
  digate::DiGate g;
  DiSensor d(&g);
  d.setLocalReady(true);
  SensorConfig c = mk(0, 9, SensorKind::WATER, 1, 1);   // DI 9 = ek modul girisi
  TEST_ASSERT_FALSE(d.sample(c, 0).ok);
  d.setExtOk(true);
  TEST_ASSERT_TRUE(d.sample(c, 0).ok);
  d.setExtOk(false);                                    // modul yanit vermiyor / tarama suruyor
  TEST_ASSERT_FALSE(d.sample(c, 0).ok);
  SensorConfig bad = mk(0, 41, SensorKind::WATER, 1, 0);
  TEST_ASSERT_FALSE(d.sample(bad, 0).ok);
}

void test_di_sensor_mask_and_momentary_cleanup(void) {
  // MOMENTARY bir DI sensore cevrilince bekleyen "birakmada KAPAT" artigi temizlenmeli [B17]
  digate::DiGate g;
  digate::Decision dec = g.decide(4, digate::EDGE_PRESS, digate::MODE_MOMENTARY, false, false);
  TEST_ASSERT_EQUAL_UINT8(digate::RELAY_ON, dec.action);
  TEST_ASSERT_TRUE(g.acted(4));
  SensorConfig c[2] = {mk(0, 5, SensorKind::WATER, 1, 0), mk(1, 1, SensorKind::WATER, 1, 0)};
  uint64_t mask = DiSensor::diMaskOf(c, 2);
  TEST_ASSERT_EQUAL_UINT64(1ULL << 4, mask);          // kopru yuvasi DI maskesine girmez
  DiSensor::releaseMomentary(g, mask, 0);
  TEST_ASSERT_FALSE(g.acted(4));
  dec = g.decide(4, digate::EDGE_RELEASE, digate::MODE_MOMENTARY, false, false);
  TEST_ASSERT_EQUAL_UINT8(digate::NONE, dec.action);
}

// pano-4: ek modul kanal sayisi (modul etkinken) arttiginda yeni kanallarin DI kapisi ilk taze okumaya kadar baslatilmamistir (kararli=false:
// NC sensorde "aktif" okunurdu). O kanallardaki sensor "okunamadi" (ok=false, aktif degil) sayilir -> NC gaz/duman sahte alarm uretmez.
// Mevcut kanallar etkilenmez (toplu ext-ok dusurulseydi daha once okunmus gaz sensoru ariza -> SF_FAULT_CLOSE ile sahte gaz alarmi verirdi).
void test_di_sensor_new_ext_channels_unknown_until_first_read(void) {
  digate::DiGate g;
  DiSensor d(&g);
  d.setLocalReady(true);
  d.setExtOk(true);
  d.setExtReady(8);                                     // DI 9..16 okundu; DI 17.. (yeni kanallar) henuz okunmadi
  const SensorConfig cs[2] = {mk(0, 9, SensorKind::GAS, 1, 1), mk(0, 17, SensorKind::GAS, 1, 1)};
  g.init(8, true, 0);                                   // DI 9: NC kontak kapali (normal)
  TEST_ASSERT_TRUE(d.sample(cs[0], 0).ok);
  TEST_ASSERT_FALSE(d.sample(cs[1], 0).ok);            // yeni kanal: bilinmiyor
  SensorHub h;
  h.configure(cs, 2, 0);
  uint32_t t = 0;
  for (; t < 2000; t += 10) {
    for (uint8_t i = 0; i < 2; i++) {
      const SensorSample sm = d.sample(cs[i], t);
      h.update(i, sm.level, sm.ok, t);
    }
    h.finish(t);
  }
  TEST_ASSERT_EQUAL_UINT8(0, h.zoneWet(1));            // sahte gaz alarmi yok (mevcut kanal da ok kaldi)
  TEST_ASSERT_TRUE(h.ok(0));
  g.init(16, true, t);                                  // ilk taze okuma: yeni kanal kenarsiz baslatilir (NC kapali = normal)
  d.setExtReady(16);
  TEST_ASSERT_TRUE(d.sample(cs[1], t).ok);
  TEST_ASSERT_TRUE(d.sample(cs[1], t).level);
  for (uint32_t e = t + 2000; t < e; t += 10) {
    for (uint8_t i = 0; i < 2; i++) {
      const SensorSample sm = d.sample(cs[i], t);
      h.update(i, sm.level, sm.ok, t);
    }
    h.finish(t);
  }
  TEST_ASSERT_EQUAL_UINT8(0, h.zoneWet(1));
  TEST_ASSERT_TRUE(h.ok(1));
  DiSensor d2(&g);                                      // varsayilan (setExtReady yok): yalniz setExtOk karar verir (eski davranis)
  d2.setExtOk(true);
  TEST_ASSERT_TRUE(d2.sample(cs[1], 0).ok);
}

// ---------------------------------------------------------------------------- BridgeSensor
void test_bridge_heartbeat(void) {
  BridgeSensor b;
  SensorConfig c = mk(1, 2, SensorKind::WATER, 1, 0);
  TEST_ASSERT_FALSE(b.sample(c, 0).ok);               // hic rapor yok
  SensorReport r;
  r.slot = 2; r.active = true; r.ok = true; r.at_ms = 1000;
  b.report(r);
  SensorSample s = b.sample(c, 1000 + 899999);
  TEST_ASSERT_TRUE(s.ok);
  TEST_ASSERT_TRUE(s.level);
  TEST_ASSERT_FALSE(b.sample(c, 1000 + 900001).ok);  // 15 dk kalp atisi asildi
  b.setHeartbeat(2, 60000);
  r.at_ms = 5000; r.active = false;
  b.report(r);
  TEST_ASSERT_TRUE(b.sample(c, 64000).ok);
  TEST_ASSERT_FALSE(b.sample(c, 65001).ok);
  r.slot = 17;                                        // aralik disi yuva yok sayilir
  b.report(r);
  r.slot = 3; r.ok = false; r.at_ms = 70000;          // hub kendi "ok=false" bildirimi
  b.report(r);
  SensorConfig c3 = mk(1, 3, SensorKind::WATER, 1, 0);
  TEST_ASSERT_FALSE(b.sample(c3, 70000).ok);
}

int main(int, char**) {
  UNITY_BEGIN();
  RUN_TEST(test_struct_sizes_are_fixed);
  RUN_TEST(test_kind_defaults);
  RUN_TEST(test_nc_contact_inverts_level);
  RUN_TEST(test_short_splash_does_not_confirm);
  RUN_TEST(test_continuous_wet_confirms_after_confirm_ms);
  RUN_TEST(test_drip_pattern_confirms_by_accumulation);
  RUN_TEST(test_window_forgets_old_activity);
  RUN_TEST(test_gas_confirms_fast);
  RUN_TEST(test_not_ok_sensor_is_neither_wet_nor_dry);
  RUN_TEST(test_dry_counter_needs_uninterrupted_ok_and_inactive);
  RUN_TEST(test_dry_counter_waits_until_confirmation_window_drains);
  RUN_TEST(test_fault_edges_reported_once);
  RUN_TEST(test_initially_unknown_sensor_does_not_report_fault_edge);
  RUN_TEST(test_fault_close_flag_counts_fault_as_wet);
  RUN_TEST(test_react_flag_off_never_wets_zone);
  RUN_TEST(test_zone_sources_list_wet_sensors);
  RUN_TEST(test_control_role_press_edge_and_hold);
  RUN_TEST(test_control_role_already_pressed_at_boot_is_not_an_edge);
  RUN_TEST(test_millis_rollover);
  RUN_TEST(test_zone_without_hazard_sensors_is_dry_since_configure);
  RUN_TEST(test_di_sensor_local_ok_only_after_first_read);
  RUN_TEST(test_di_sensor_ext_ok_requires_module);
  RUN_TEST(test_di_sensor_mask_and_momentary_cleanup);
  RUN_TEST(test_di_sensor_new_ext_channels_unknown_until_first_read);
  RUN_TEST(test_bridge_heartbeat);
  return UNITY_END();
}
