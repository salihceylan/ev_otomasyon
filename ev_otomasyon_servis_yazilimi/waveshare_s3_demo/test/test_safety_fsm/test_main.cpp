// SafetyCore (src/safety/SafetyFsm.h) birim testleri: SensorHub + ActuatorCore + EventOutbox ile birlikte, sahte SensorSource.
// SAF MANTIK; saat parametre. Kapsam spec 5.1.1-5.1.6 ve 5.5 "SafetyFsm" listesi.
#include <unity.h>
#include <stdint.h>
#include <string.h>
#include "safety/SafetyFsm.h"
#include "safety/SafetyCfgEdit.h"

using namespace safety;

void setUp(void) {}
void tearDown(void) {}

// Sahte kaynak: DI no (1..40) / kopru yuvasi (1..16) basina seviye + ok.
struct FakeSource : public SensorSource {
  bool level[41];
  bool okv[41];
  FakeSource() { for (int i = 0; i < 41; i++) { level[i] = false; okv[i] = true; } }
  SensorSample sample(const SensorConfig& c, uint32_t) override {
    SensorSample s;
    s.level = (c.index <= 40) ? level[c.index] : false;
    s.ok = (c.index <= 40) ? okv[c.index] : false;
    return s;
  }
};

static SensorConfig sensor(uint8_t di, SensorKind k, uint8_t zone, uint8_t nc = 0) {
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

static ActuatorConfig valve(uint8_t relay, Medium m, uint8_t zones = 0x01, CloseMode mode = CloseMode::DEENERGIZE_TO_CLOSE) {
  ActuatorConfig a;
  memset(&a, 0, sizeof(a));
  a.relay = relay;
  a.kind = (uint8_t)ActKind::VALVE;
  a.close_mode = (uint8_t)mode;
  a.medium = (uint8_t)m;
  a.zone_mask = zones;
  a.fb_closed_active = 1;
  a.fb_timeout_s = 60;
  return a;
}

static ActuatorConfig sw(uint8_t relay, ActKind k, uint8_t zones = 0x01, uint16_t lim = 180) {
  ActuatorConfig a;
  memset(&a, 0, sizeof(a));
  a.relay = relay;
  a.kind = (uint8_t)k;
  a.zone_mask = zones;
  a.run_limit_s = lim;
  return a;
}

// Tezgah: yapilandirma + cekirdekler + 10 ms adimli sanal saat.
struct Bench {
  SafetyConfig cfg;
  SensorHub hub;
  ActuatorCore act;
  EventOutbox out;
  FakeSource di;
  FakeSource br;
  SafetyCore core;
  uint32_t t;
  LatchRecord latch;
  bool haveLatch;
  uint16_t posOpen, posKnown;
  SafeReason mode;

  Bench() : t(1000), haveLatch(false), posOpen(0), posKnown(0), mode(SafeReason::NONE) {
    cfg.setDefaults();
    latchClear(latch);
  }
  void start(uint32_t t0 = 1000) {
    t = t0;
    out.begin(0x9f3a11c0u);
    act.configure(cfg.act, cfg.nAct, posOpen, posKnown, t);
    hub.configure(cfg.sens, cfg.nSens, t);
    core.begin(&cfg, &hub, &act, &out, haveLatch ? &latch : nullptr, mode, t);
    step(0);
  }
  void step(uint32_t ms = 10) {
    t += ms;
    core.tick(t, 0, &di, &br);
  }
  void run(uint32_t ms) { for (uint32_t d = 0; d < ms; d += 10) step(10); }
  bool relay(uint8_t r) { uint64_t a, l; core.outputMasks(a, l); return (l >> (r - 1)) & 1ULL; }
  bool asserted(uint8_t r) { uint64_t a, l; core.outputMasks(a, l); return (a >> (r - 1)) & 1ULL; }
  // "Elektrik gitti/geldi": kilit kaydi + act_pos ile yeni cekirdekler.
  void powerCycle() {
    core.buildLatch(latch);
    haveLatch = true;
    posOpen = act.posOpenBits();
    posKnown = act.posKnownBits();
    SensorHub h2;
    hub = h2;
    ActuatorCore a2;
    act = a2;
    SafetyCore c2;
    core = c2;
    start(t + 5000);
  }
  // Calisirken yapilandirma yamasi (SafetyManager::applyConfigOnLoop esdegeri): cfg cagiranca degistirilmis, eski kopya verilir.
  void reconfigure(const SafetyConfig& oldCfg, uint64_t curLevels = 0) {
    int8_t map[MAX_ACTUATORS];
    actuatorIdentityMap(oldCfg, cfg, map);
    uint16_t open = 0, known = 0;
    remapActPos(oldCfg, act.posOpenBits(), act.posKnownBits(), cfg, curLevels, open, known);
    hub.configure(cfg.sens, cfg.nSens, t);
    act.reconfigure(cfg.act, cfg.nAct, open, known, map, t);
    core.reconfigured(VIA_CLI, t, map);
  }
  int lastEventOf(EvType ty) {
    int best = -1;
    for (int i = 0; i < EventOutbox::CAP; i++) if (out.at(i) && out.at(i)->type == (uint8_t)ty) best = i;
    return best;
  }
};

// Su vanasi (D2C, role 5), siren (role 6), su sensoru DI 3, bolge 1.
static void waterSetup(Bench& b) {
  b.cfg.sens[0] = sensor(3, SensorKind::WATER, 1);
  b.cfg.nSens = 1;
  b.cfg.act[0] = valve(5, Medium::WATER);
  b.cfg.act[1] = sw(6, ActKind::SIREN);
  b.cfg.nAct = 2;
}

void test_unconfigured_core_is_idle(void) {
  Bench b;
  b.start();
  b.run(5000);
  uint64_t a, l;
  b.core.outputMasks(a, l);
  TEST_ASSERT_EQUAL_UINT64(0, a);
  TEST_ASSERT_EQUAL_UINT64(0, l);
  TEST_ASSERT_FALSE(b.core.buzzer());
  TEST_ASSERT_FALSE(b.core.active());
  TEST_ASSERT_EQUAL_UINT8(0, b.out.count());
}

void test_test_on_unconfigured_board_finishes(void) {
  // Eylemcisiz bolgede TEST: cekirdek TEST surerken etkin kalir ve 5 sn sonra NORMAL'e doner (takili kalmaz).
  Bench b;
  b.start();
  TEST_ASSERT_EQUAL_UINT8((uint8_t)Rej::OK, (uint8_t)b.core.test(1, b.t));
  TEST_ASSERT_TRUE(b.core.active());
  b.run(5100);
  TEST_ASSERT_EQUAL_UINT8((uint8_t)ZoneSt::NORMAL, (uint8_t)b.core.zoneState(1));
  TEST_ASSERT_FALSE(b.core.active());
}

void test_short_wet_signal_no_alarm(void) {
  Bench b;
  waterSetup(b);
  b.start();
  b.run(200);
  TEST_ASSERT_TRUE(b.relay(5));                      // bilinmeyen konum = acik kabul (D2C enerjili)
  b.di.level[3] = true;
  b.run(500);
  b.di.level[3] = false;
  b.run(5000);
  TEST_ASSERT_EQUAL_UINT8((uint8_t)ZoneSt::NORMAL, (uint8_t)b.core.zoneState(1));
  TEST_ASSERT_TRUE(b.relay(5));
}

void test_drip_reaches_alarm(void) {
  Bench b;
  waterSetup(b);
  b.start();
  for (int k = 0; k < 8; k++) {
    b.di.level[3] = true;
    b.run(300);
    b.di.level[3] = false;
    b.run(200);
  }
  TEST_ASSERT_EQUAL_UINT8((uint8_t)ZoneSt::LATCHED, (uint8_t)b.core.zoneState(1));
}

void test_confirmed_wet_latches_closes_valve_and_sounds(void) {
  Bench b;
  waterSetup(b);
  b.start();
  b.di.level[3] = true;
  b.run(1100);
  TEST_ASSERT_EQUAL_UINT8((uint8_t)ZoneSt::LATCHED, (uint8_t)b.core.zoneState(1));
  TEST_ASSERT_FALSE(b.relay(5));                     // D2C: kapali = enerjisiz
  TEST_ASSERT_TRUE(b.asserted(5));
  TEST_ASSERT_TRUE(b.relay(6));                      // siren
  TEST_ASSERT_TRUE(b.core.buzzer());
  int s = b.lastEventOf(EvType::ALARM_RAISED);
  TEST_ASSERT_TRUE(s >= 0);
  char eid[EID_LEN];
  b.out.eidOf(s, eid);
  TEST_ASSERT_EQUAL_STRING(eid, b.core.zone(1).aid);
  TEST_ASSERT_EQUAL_UINT16(0x0001, b.out.at(s)->actClose);
  TEST_ASSERT_EQUAL_UINT16(0x0002, b.out.at(s)->actOn);
  TEST_ASSERT_EQUAL_UINT8(1, b.out.at(s)->nsrcs);
  TEST_ASSERT_EQUAL_UINT8(3, b.out.at(s)->srcs[0]);
  TEST_ASSERT_TRUE(b.core.takeLatchDirty());
  LatchRecord r;
  b.core.buildLatch(r);
  TEST_ASSERT_TRUE(latchValid(r));
  TEST_ASSERT_EQUAL_UINT8(1, r.z[0].st);
  TEST_ASSERT_EQUAL_UINT64(1ULL << 4, latchAssert64(r));
  TEST_ASSERT_EQUAL_UINT64(0, latchLevel64(r));
  TEST_ASSERT_EQUAL_UINT16(0x0001, b.act.posKnownBits());
  TEST_ASSERT_EQUAL_UINT16(0x0000, b.act.posOpenBits());   // guvenlik kapatmasi act_pos'u KAPALI yazar [K-1]
}

void test_ack_while_wet_only_silences(void) {
  Bench b;
  waterSetup(b);
  b.start();
  b.di.level[3] = true;
  b.run(1100);
  TEST_ASSERT_EQUAL_UINT8((uint8_t)Rej::OK, (uint8_t)b.core.ack(1, b.core.zone(1).aid, Origin::REMOTE, false, b.t));
  b.step();
  TEST_ASSERT_TRUE(b.core.zone(1).silenced);
  TEST_ASSERT_FALSE(b.relay(6));
  TEST_ASSERT_FALSE(b.core.buzzer());
  TEST_ASSERT_FALSE(b.relay(5));                     // vana kapali kalir
  TEST_ASSERT_TRUE(b.lastEventOf(EvType::ALARM_SILENCED) >= 0);
  // CONTRACTS 2.6: susturma olayi bolgenin alarm kimligini (aid = alarm_raised'in eid'si) tasir
  TEST_ASSERT_TRUE(b.core.zone(1).aid[0] != '\0');
  TEST_ASSERT_EQUAL_STRING(b.core.zone(1).aid, b.out.at(b.lastEventOf(EvType::ALARM_SILENCED))->aid);
  TEST_ASSERT_EQUAL_STRING("", b.out.at(b.lastEventOf(EvType::ALARM_RAISED))->aid);
  b.run(30000);                                      // hala islak: kilit surer
  TEST_ASSERT_EQUAL_UINT8((uint8_t)ZoneSt::LATCHED, (uint8_t)b.core.zoneState(1));
}

void test_acked_and_dry_clears_but_valve_stays_closed(void) {
  Bench b;
  waterSetup(b);
  b.start();
  b.di.level[3] = true;
  b.run(1100);
  char raisedAid[EID_LEN];
  memcpy(raisedAid, b.core.zone(1).aid, EID_LEN);
  b.core.ack(1, nullptr, Origin::LOCAL_DI, false, b.t);
  b.di.level[3] = false;
  b.run(9000);
  TEST_ASSERT_EQUAL_UINT8((uint8_t)ZoneSt::LATCHED, (uint8_t)b.core.zoneState(1));   // pencere bosalmasi + 10 sn
  b.run(5000);
  TEST_ASSERT_EQUAL_UINT8((uint8_t)ZoneSt::NORMAL, (uint8_t)b.core.zoneState(1));
  TEST_ASSERT_FALSE(b.relay(5));                     // vana KAPALI kalir; acmak ayri komut
  TEST_ASSERT_FALSE(b.relay(6));
  TEST_ASSERT_TRUE(b.lastEventOf(EvType::ALARM_CLEARED) >= 0);
  TEST_ASSERT_EQUAL_STRING(raisedAid, b.out.at(b.lastEventOf(EvType::ALARM_CLEARED))->aid);   // kalkan alarmin aid'si
  // kilit kalktiktan sonra elektrik kesintisi: vana yine kapali [K-1]
  b.powerCycle();
  b.run(100);
  TEST_ASSERT_FALSE(b.relay(5));
  TEST_ASSERT_EQUAL_UINT64(0, bootLevelMask(b.cfg.act, b.cfg.nAct, 0, b.posOpen, b.posKnown) & (1ULL << 4));
  // ardindan kullanici acar
  TEST_ASSERT_EQUAL_UINT8((uint8_t)Rej::OK, (uint8_t)b.core.actuatorSet(0, false, Origin::REMOTE, b.t));
  b.step();
  TEST_ASSERT_TRUE(b.relay(5));
}

void test_dry_first_then_ack_clears_immediately(void) {
  Bench b;
  waterSetup(b);
  b.start();
  b.di.level[3] = true;
  b.run(1100);
  b.di.level[3] = false;
  b.run(20000);
  TEST_ASSERT_EQUAL_UINT8((uint8_t)ZoneSt::LATCHED, (uint8_t)b.core.zoneState(1));   // onaysiz kalkmaz
  TEST_ASSERT_TRUE(b.relay(6));                      // siren hala calar (180 sn sinir)
  b.core.ack(1, nullptr, Origin::REMOTE, false, b.t);
  b.step();
  TEST_ASSERT_EQUAL_UINT8((uint8_t)ZoneSt::NORMAL, (uint8_t)b.core.zoneState(1));
}

void test_not_ok_sensor_blocks_clear_and_open(void) {
  Bench b;
  waterSetup(b);
  b.start();
  b.di.level[3] = true;
  b.run(1100);
  b.core.ack(1, nullptr, Origin::REMOTE, false, b.t);
  b.di.level[3] = false;
  b.di.okv[3] = false;                               // sensor bilinmeyen [Y-3]
  b.run(30000);
  TEST_ASSERT_EQUAL_UINT8((uint8_t)ZoneSt::LATCHED, (uint8_t)b.core.zoneState(1));
  TEST_ASSERT_EQUAL_UINT8((uint8_t)Rej::ZONE_LATCHED, (uint8_t)b.core.actuatorSet(0, false, Origin::REMOTE, b.t));
  TEST_ASSERT_TRUE(b.lastEventOf(EvType::SENSOR_FAULT) >= 0);
  b.di.okv[3] = true;
  b.run(11000);
  TEST_ASSERT_EQUAL_UINT8((uint8_t)ZoneSt::NORMAL, (uint8_t)b.core.zoneState(1));
  TEST_ASSERT_TRUE(b.lastEventOf(EvType::SENSOR_FAULT_CLEARED) >= 0);
  b.di.okv[3] = false;                               // NORMAL'de de ok=false iken acma yok
  b.run(100);
  TEST_ASSERT_EQUAL_UINT8((uint8_t)Rej::ZONE_LATCHED, (uint8_t)b.core.actuatorSet(0, false, Origin::REMOTE, b.t));
}

void test_kind_to_medium_mapping(void) {
  Bench b;
  b.cfg.sens[0] = sensor(3, SensorKind::WATER, 1);
  b.cfg.sens[1] = sensor(4, SensorKind::SMOKE, 1, 1);
  b.cfg.nSens = 2;
  b.cfg.act[0] = valve(5, Medium::WATER);
  b.cfg.act[1] = valve(6, Medium::GAS);
  b.cfg.act[2] = sw(7, ActKind::SIREN);
  b.cfg.act[3] = sw(8, ActKind::FAN);
  b.cfg.nAct = 4;
  b.di.level[4] = true;                              // NC duman: kontak kapali = normal
  b.start();
  b.run(200);
  TEST_ASSERT_EQUAL_UINT8((uint8_t)Rej::OK, (uint8_t)b.core.actuatorSet(3, false, Origin::REMOTE, b.t));   // fan acik (kullanici)
  b.step();
  TEST_ASSERT_TRUE(b.relay(8));
  b.di.level[4] = false;                             // duman
  b.run(500);
  TEST_ASSERT_EQUAL_UINT8((uint8_t)ZoneSt::LATCHED, (uint8_t)b.core.zoneState(1));
  TEST_ASSERT_TRUE(b.relay(5));                      // su vanasi ACIK kalir (yangin suyu) [K-3]
  TEST_ASSERT_TRUE(b.act.closedCmd(1));              // gaz vanasi zaten her acilista kapali [K-4]
  TEST_ASSERT_FALSE(b.relay(6));                     // D2C gaz vanasi kapali = enerjisiz
  TEST_ASSERT_TRUE(b.relay(7));                      // siren
  TEST_ASSERT_FALSE(b.relay(8));                     // dumanda fan KAPATILIR [Y-1]
  TEST_ASSERT_EQUAL_UINT8((uint8_t)Rej::ZONE_LATCHED, (uint8_t)b.core.actuatorSet(3, false, Origin::REMOTE, b.t));
  // su: yalniz su vanasi
  Bench w;
  w.cfg = b.cfg;
  w.posOpen = 0x0003;
  w.posKnown = 0x0003;
  w.di.level[4] = true;
  w.start();
  w.di.level[3] = true;
  w.run(1100);
  TEST_ASSERT_FALSE(w.relay(5));                     // su vanasi kapandi
  TEST_ASSERT_EQUAL_UINT16(0x0001, w.out.at(w.lastEventOf(EvType::ALARM_RAISED))->actClose);   // gaz vanasina dokunulmadi
}

void test_gas_rules(void) {
  Bench b;
  b.cfg.sens[0] = sensor(3, SensorKind::GAS, 1, 1);
  b.cfg.sens[1] = sensor(4, SensorKind::GAS_RESET, 1);
  b.cfg.nSens = 2;
  b.cfg.act[0] = valve(5, Medium::GAS, 0x01, CloseMode::ENERGIZE_TO_CLOSE);
  b.cfg.act[1] = sw(6, ActKind::FAN);
  b.cfg.act[2] = sw(7, ActKind::FAN);
  b.cfg.act[2].aflags = AF_FAN_EXPROOF;
  b.cfg.nAct = 3;
  b.di.level[3] = true;                              // NC gaz: normal
  b.posOpen = 0x0001;
  b.posKnown = 0x0001;
  b.start();
  b.run(100);
  TEST_ASSERT_TRUE(b.relay(5));                      // act_pos "acik" olsa da gaz vanasi acilista KAPALI (E2C: enerjili)
  TEST_ASSERT_EQUAL_UINT8((uint8_t)Rej::GAS_LOCAL_ONLY, (uint8_t)b.core.actuatorSet(0, false, Origin::REMOTE, b.t));
  b.di.level[4] = true;                              // GAS_RESET DI: yerinde acma
  b.run(100);
  TEST_ASSERT_FALSE(b.relay(5));
  b.di.level[4] = false;
  b.run(100);
  // TEST: gaz vanasi test sonunda kapali KALIR
  TEST_ASSERT_EQUAL_UINT8((uint8_t)Rej::OK, (uint8_t)b.core.test(1, b.t));
  b.run(6000);
  TEST_ASSERT_EQUAL_UINT8((uint8_t)ZoneSt::NORMAL, (uint8_t)b.core.zoneState(1));
  TEST_ASSERT_TRUE(b.relay(5));
  TEST_ASSERT_EQUAL_UINT16(0x0000, b.act.posOpenBits());
  // gaz alarmi: yalniz ATEX onayli fan acilir
  b.di.level[3] = false;
  b.run(400);
  TEST_ASSERT_EQUAL_UINT8((uint8_t)ZoneSt::LATCHED, (uint8_t)b.core.zoneState(1));
  TEST_ASSERT_FALSE(b.relay(6));
  TEST_ASSERT_TRUE(b.relay(7));
  TEST_ASSERT_EQUAL_UINT8((uint8_t)Rej::ZONE_LATCHED, (uint8_t)b.core.actuatorSet(1, false, Origin::REMOTE, b.t));
}

void test_gas_sensor_wire_break_closes_gas_valve(void) {
  Bench b;
  b.cfg.sens[0] = sensor(3, SensorKind::GAS, 1, 1);
  b.cfg.nSens = 1;
  b.cfg.act[0] = valve(5, Medium::GAS);
  b.cfg.nAct = 1;
  b.di.level[3] = true;
  b.start();
  b.run(100);
  b.di.okv[3] = false;                               // modul/kablo arizasi: gaz icin "arizada kapat"
  b.run(50);
  TEST_ASSERT_EQUAL_UINT8((uint8_t)ZoneSt::LATCHED, (uint8_t)b.core.zoneState(1));
}

void test_stale_aid_ack_rejected(void) {
  Bench b;
  waterSetup(b);
  b.start();
  b.di.level[3] = true;
  b.run(1100);
  TEST_ASSERT_EQUAL_UINT8((uint8_t)Rej::STALE_ACK, (uint8_t)b.core.ack(1, "9f3a11c0-99", Origin::REMOTE, false, b.t));
  b.step();
  TEST_ASSERT_FALSE(b.core.zone(1).silenced);
  TEST_ASSERT_TRUE(b.relay(6));
  TEST_ASSERT_EQUAL_UINT8((uint8_t)Rej::OK, (uint8_t)b.core.ack(2, "x", Origin::REMOTE, false, b.t));   // NORMAL bolge: etkisiz, idempotent
}

void test_policy_off_blocks_new_alarms_but_keeps_latch(void) {
  Bench b;
  waterSetup(b);
  b.cfg.sens[1] = sensor(4, SensorKind::WATER, 2);
  b.cfg.nSens = 2;
  b.start();
  b.di.level[3] = true;
  b.run(1100);
  b.core.setPolicy(false, VIA_CLI, b.t);
  TEST_ASSERT_TRUE(b.lastEventOf(EvType::POLICY_CHANGED) >= 0);
  b.run(100);
  TEST_ASSERT_EQUAL_UINT8((uint8_t)ZoneSt::LATCHED, (uint8_t)b.core.zoneState(1));   // mevcut kilit kalkmaz [O-10]
  b.di.level[4] = true;
  b.run(2000);
  TEST_ASSERT_EQUAL_UINT8((uint8_t)ZoneSt::NORMAL, (uint8_t)b.core.zoneState(2));    // yeni alarm yok
  TEST_ASSERT_FALSE(b.relay(5));
}

void test_feedback_timeout_fault_and_recovery(void) {
  Bench b;
  waterSetup(b);
  b.cfg.act[0].fb_di = 7;
  b.cfg.act[0].fb_timeout_s = 5;
  b.posOpen = 1;
  b.posKnown = 1;
  b.start();
  b.di.level[7] = false;                             // geri bildirim: kapali degil
  b.di.level[3] = true;
  b.run(1100);
  b.core.ack(1, nullptr, Origin::REMOTE, false, b.t);
  b.run(100);
  TEST_ASSERT_FALSE(b.relay(6));                     // susturuldu
  b.run(5000);
  TEST_ASSERT_EQUAL_UINT8((uint8_t)ZoneSt::FAULT, (uint8_t)b.core.zoneState(1));
  TEST_ASSERT_TRUE(b.relay(6));                      // susturulmus olsa bile siren yeniden [5.1.1]
  TEST_ASSERT_TRUE(b.lastEventOf(EvType::VALVE_FAULT) >= 0);
  TEST_ASSERT_FALSE(b.relay(5));                     // KAPAT surmeye devam
  b.di.level[7] = true;                              // vana kapandi
  b.run(100);
  TEST_ASSERT_EQUAL_UINT8((uint8_t)ZoneSt::LATCHED, (uint8_t)b.core.zoneState(1));
  TEST_ASSERT_TRUE(b.lastEventOf(EvType::VALVE_FAULT_CLEARED) >= 0);
}

void test_test_cycle_and_restore(void) {
  Bench b;
  waterSetup(b);
  b.cfg.act[0].fb_di = 7;
  b.cfg.act[0].fb_timeout_s = 10;
  b.posOpen = 1;
  b.posKnown = 1;
  b.start();
  b.run(100);
  TEST_ASSERT_TRUE(b.relay(5));                      // acik
  TEST_ASSERT_EQUAL_UINT8((uint8_t)Rej::OK, (uint8_t)b.core.test(1, b.t));
  b.step();
  TEST_ASSERT_EQUAL_UINT8((uint8_t)ZoneSt::TEST, (uint8_t)b.core.zoneState(1));
  TEST_ASSERT_FALSE(b.relay(5));
  TEST_ASSERT_TRUE(b.relay(6));                      // siren 3 sn
  b.run(2000);
  b.di.level[7] = true;                              // 2 sn'de kapandi
  b.run(100);
  TEST_ASSERT_EQUAL_UINT8((uint8_t)ZoneSt::NORMAL, (uint8_t)b.core.zoneState(1));
  TEST_ASSERT_TRUE(b.relay(5));                      // onceki konuma (acik) dondu
  int s = b.lastEventOf(EvType::TEST_RESULT);
  TEST_ASSERT_TRUE(s >= 0);
  TEST_ASSERT_EQUAL_UINT8(1, b.out.at(s)->flag);
  TEST_ASSERT_EQUAL_UINT8(1, b.out.at(s)->sub);                 // geri bildirim olculdu: fb_ms yazilir
  TEST_ASSERT_TRUE(b.out.at(s)->val >= 2000 && b.out.at(s)->val < 2200);
  b.di.level[7] = false;
  b.run(3000);
  TEST_ASSERT_FALSE(b.relay(6));                     // siren 3 sn sonra susar
  TEST_ASSERT_EQUAL_UINT8((uint8_t)Rej::BAD_STATE, (uint8_t)b.core.test(5, b.t));   // bolge 1..4
}

void test_test_without_feedback_times_out_ok(void) {
  Bench b;
  waterSetup(b);
  b.posOpen = 1;
  b.posKnown = 1;
  b.start();
  b.core.test(1, b.t);
  b.run(4900);
  TEST_ASSERT_EQUAL_UINT8((uint8_t)ZoneSt::TEST, (uint8_t)b.core.zoneState(1));
  b.run(200);
  TEST_ASSERT_EQUAL_UINT8((uint8_t)ZoneSt::NORMAL, (uint8_t)b.core.zoneState(1));
  TEST_ASSERT_TRUE(b.relay(5));
}

void test_real_wet_during_test_latches(void) {
  Bench b;
  waterSetup(b);
  b.posOpen = 1;
  b.posKnown = 1;
  b.start();
  b.core.test(1, b.t);
  b.di.level[3] = true;
  b.run(1200);
  TEST_ASSERT_EQUAL_UINT8((uint8_t)ZoneSt::LATCHED, (uint8_t)b.core.zoneState(1));
  b.run(10000);
  TEST_ASSERT_FALSE(b.relay(5));                     // test bitisi vanayi ACMAZ (gercek alarm oncelikli)
  TEST_ASSERT_EQUAL_UINT8((uint8_t)Rej::ZONE_LATCHED, (uint8_t)b.core.test(1, b.t));
}

void test_multi_zone_valve_open_permission(void) {
  Bench b;
  b.cfg.sens[0] = sensor(3, SensorKind::WATER, 1);
  b.cfg.sens[1] = sensor(4, SensorKind::WATER, 2);
  b.cfg.nSens = 2;
  b.cfg.act[0] = valve(5, Medium::WATER, 0x03);       // ana vana: bolge 1 ve 2
  b.cfg.nAct = 1;
  b.start();
  b.di.level[4] = true;
  b.run(1100);
  TEST_ASSERT_FALSE(b.relay(5));
  b.di.level[4] = false;
  b.core.ack(2, nullptr, Origin::REMOTE, false, b.t);
  b.run(5000);
  TEST_ASSERT_EQUAL_UINT8((uint8_t)Rej::ZONE_LATCHED, (uint8_t)b.core.actuatorSet(0, false, Origin::REMOTE, b.t));
  b.run(10000);
  TEST_ASSERT_EQUAL_UINT8((uint8_t)ZoneSt::NORMAL, (uint8_t)b.core.zoneState(2));
  TEST_ASSERT_EQUAL_UINT8((uint8_t)Rej::OK, (uint8_t)b.core.actuatorSet(0, false, Origin::REMOTE, b.t));
  TEST_ASSERT_EQUAL_UINT8((uint8_t)Rej::UNKNOWN_ACTUATOR, (uint8_t)b.core.actuatorSet(5, false, Origin::REMOTE, b.t));
}

void test_millis_rollover(void) {
  Bench b;
  waterSetup(b);
  b.start(0xFFFFF000u);
  b.di.level[3] = true;
  b.run(1100);
  TEST_ASSERT_EQUAL_UINT8((uint8_t)ZoneSt::LATCHED, (uint8_t)b.core.zoneState(1));
  b.core.ack(1, nullptr, Origin::REMOTE, false, b.t);
  b.di.level[3] = false;
  b.run(15000);
  TEST_ASSERT_EQUAL_UINT8((uint8_t)ZoneSt::NORMAL, (uint8_t)b.core.zoneState(1));
}

void test_latch_survives_power_cycle_with_same_aid(void) {
  Bench b;
  waterSetup(b);
  b.cfg.act[0].close_mode = (uint8_t)CloseMode::ENERGIZE_TO_CLOSE;
  b.start();
  b.di.level[3] = true;
  b.run(1100);
  char aid[EID_LEN];
  strcpy(aid, b.core.zone(1).aid);
  b.powerCycle();
  TEST_ASSERT_EQUAL_UINT8((uint8_t)ZoneSt::LATCHED, (uint8_t)b.core.zoneState(1));
  TEST_ASSERT_EQUAL_STRING(aid, b.core.zone(1).aid);
  TEST_ASSERT_TRUE(b.relay(5));                      // E2C: kapali = enerjili
  TEST_ASSERT_TRUE(b.relay(6));                      // susturulmamis kilitte siren yeniden baslar
  TEST_ASSERT_EQUAL_UINT8(0, b.out.countOf(EvType::ALARM_RAISED));   // yeni alarm olayi yok (ayni alarm)
}

void test_safe_mode_applies_latch_mask_and_rejects_open(void) {
  Bench b;
  b.haveLatch = true;
  latchClear(b.latch);
  b.latch.z[0].st = 1;
  strcpy(b.latch.z[0].aid, "11111111-4");
  latchSetMasks(b.latch, 1ULL << 4, 1ULL << 4);       // role 5 enerjili (E2C kapali)
  latchSeal(b.latch);
  b.mode = SafeReason::LATCH_ORPHAN;                 // fabrika sifirlamasi: eylemci tablosu bos
  b.start();
  b.run(100);
  TEST_ASSERT_TRUE(b.core.safeMode());
  TEST_ASSERT_TRUE(b.asserted(5));
  TEST_ASSERT_TRUE(b.relay(5));
  TEST_ASSERT_TRUE(b.lastEventOf(EvType::SAFE_MODE) >= 0);
  TEST_ASSERT_EQUAL_UINT8((uint8_t)Rej::SAFE_MODE, (uint8_t)b.core.ack(1, nullptr, Origin::LOCAL_DI, true, b.t));
  b.core.setConfigUsable(true);
  TEST_ASSERT_EQUAL_UINT8((uint8_t)Rej::SAFE_MODE, (uint8_t)b.core.ack(1, nullptr, Origin::REMOTE, true, b.t));   // uzaktan cikis yok (7.2b-10)
  TEST_ASSERT_EQUAL_UINT8((uint8_t)Rej::OK, (uint8_t)b.core.ack(1, nullptr, Origin::LOCAL_DI, true, b.t));
  b.step();
  TEST_ASSERT_FALSE(b.core.safeMode());
}

void test_safe_mode_rejects_valve_open(void) {
  Bench b;
  waterSetup(b);
  b.mode = SafeReason::CFG_CORRUPT;
  b.posOpen = 0;
  b.posKnown = 1;
  b.start();
  TEST_ASSERT_EQUAL_UINT8((uint8_t)Rej::SAFE_MODE, (uint8_t)b.core.actuatorSet(0, false, Origin::REMOTE, b.t));
  TEST_ASSERT_EQUAL_UINT8((uint8_t)Rej::OK, (uint8_t)b.core.actuatorSet(0, true, Origin::REMOTE, b.t));     // kapatma serbest
  TEST_ASSERT_EQUAL_UINT8((uint8_t)Rej::SAFE_MODE, (uint8_t)b.core.test(1, b.t));
}

void test_crash_loop_safe_mode_exits_after_30_min(void) {
  Bench b;
  waterSetup(b);
  b.mode = SafeReason::CRASH_LOOP;
  b.start();
  TEST_ASSERT_TRUE(b.core.safeMode());
  for (uint32_t k = 0; k < 1799; k++) b.step(1000);
  TEST_ASSERT_TRUE(b.core.safeMode());
  b.step(1000);
  b.step(10);
  TEST_ASSERT_FALSE(b.core.safeMode());
}

void test_local_control_roles(void) {
  Bench b;
  waterSetup(b);
  b.cfg.sens[1] = sensor(4, SensorKind::ALARM_ACK, 0);
  b.cfg.sens[2] = sensor(5, SensorKind::VALVE_CLOSE, 1);
  b.cfg.nSens = 3;
  b.posOpen = 1;
  b.posKnown = 1;
  b.start();
  b.run(100);
  TEST_ASSERT_TRUE(b.relay(5));
  b.di.level[5] = true;                              // yerel "vanayi kapat" dugmesi
  b.run(50);
  TEST_ASSERT_FALSE(b.relay(5));
  b.di.level[5] = false;
  b.di.level[3] = true;
  b.run(1100);
  b.di.level[4] = true;                              // yerel alarm onay dugmesi (bulut ve anahtar yok) [B15]
  b.run(50);
  TEST_ASSERT_TRUE(b.core.zone(1).silenced);
  b.di.level[4] = false;
  b.di.level[3] = false;
  b.run(15000);
  TEST_ASSERT_EQUAL_UINT8((uint8_t)ZoneSt::NORMAL, (uint8_t)b.core.zoneState(1));
}

void test_safe_mode_exit_by_ack_button_hold(void) {
  Bench b;
  waterSetup(b);
  b.cfg.sens[1] = sensor(4, SensorKind::ALARM_ACK, 0);
  b.cfg.nSens = 2;
  b.haveLatch = true;
  latchClear(b.latch);
  b.latch.z[0].st = 1;
  latchSetMasks(b.latch, 1ULL << 4, 0);
  latchSeal(b.latch);
  b.mode = SafeReason::CFG_CORRUPT;
  b.start();
  b.core.setConfigUsable(true);
  b.di.level[4] = true;
  b.run(4000);
  TEST_ASSERT_TRUE(b.core.safeMode());
  b.run(1100);                                       // 5 sn basili
  TEST_ASSERT_FALSE(b.core.safeMode());
  TEST_ASSERT_FALSE(b.relay(5));                     // vana kapali kalir
}

void test_siren_run_limit_in_alarm(void) {
  Bench b;
  waterSetup(b);
  b.cfg.act[1].run_limit_s = 10;
  b.start();
  b.di.level[3] = true;
  b.run(1100);
  TEST_ASSERT_TRUE(b.relay(6));
  b.run(10100);
  TEST_ASSERT_FALSE(b.relay(6));                     // sinir doldu; kilit surer
  TEST_ASSERT_EQUAL_UINT8((uint8_t)ZoneSt::LATCHED, (uint8_t)b.core.zoneState(1));
  TEST_ASSERT_TRUE(b.core.buzzer());                 // kart buzzer'i onaya dek calar
}

void test_pulse_valve_closes_in_alarm_without_opening(void) {
  Bench b;
  b.cfg.sens[0] = sensor(3, SensorKind::WATER, 1);
  b.cfg.nSens = 1;
  b.cfg.act[0] = valve(5, Medium::WATER, 0x01, CloseMode::PULSE_TWO_RELAY);
  b.cfg.act[0].relay2 = 6;
  b.cfg.act[0].run_limit_s = 15;
  b.cfg.nAct = 1;
  b.start();
  b.di.level[3] = true;
  b.run(1100);
  TEST_ASSERT_TRUE(b.relay(5));                      // kapat darbesi
  TEST_ASSERT_FALSE(b.relay(6));
  for (int k = 0; k < 2000; k++) { b.step(); TEST_ASSERT_FALSE(b.relay(5) && b.relay(6)); TEST_ASSERT_FALSE(b.relay(6)); }
  TEST_ASSERT_FALSE(b.relay(5));                     // darbe bitti
  LatchRecord r;
  b.core.buildLatch(r);
  TEST_ASSERT_EQUAL_UINT64(1ULL << 5, latchAssert64(r));   // AC rolesi kilit boyunca 0'a dayatilir
  TEST_ASSERT_EQUAL_UINT64(0, latchLevel64(r));
}

void test_raw_safe_command_reports_close(void) {
  Bench b;
  waterSetup(b);
  b.posOpen = 1;
  b.posKnown = 1;
  b.start();
  b.run(50);
  TEST_ASSERT_EQUAL_UINT8((uint8_t)RawDecision::SAFE, (uint8_t)b.core.rawRelay(5, false, Origin::LOCAL_DI, b.t));   // D2C: 0 = kapat
  b.step();
  TEST_ASSERT_FALSE(b.relay(5));
  TEST_ASSERT_EQUAL_UINT8((uint8_t)RawDecision::REJECT, (uint8_t)b.core.rawRelay(5, true, Origin::REMOTE, b.t));
  TEST_ASSERT_FALSE(b.relay(5));
  TEST_ASSERT_EQUAL_UINT8((uint8_t)RawDecision::SAFE, (uint8_t)b.core.rawRelay(6, false, Origin::REMOTE, b.t));      // sireni sustur
  TEST_ASSERT_EQUAL_UINT8((uint8_t)RawDecision::NOT_ACTUATOR, (uint8_t)b.core.rawRelay(7, true, Origin::REMOTE, b.t)); // eylemci degil
  TEST_ASSERT_TRUE(b.lastEventOf(EvType::ACTUATOR_CHANGED) >= 0);
}

// ---- Inceleme turu (entegrasyon) duzeltmeleri ----

// E2E-2: kilitli (susturulmus) su alarmi surerken gaz: YENI alarm olayi (yeni aid) uretilir; sunucu push'u ve yerel olay halkasi bunu gorur.
void test_new_hazard_in_latched_zone_raises_new_alarm(void) {
  Bench b;
  b.cfg.sens[0] = sensor(3, SensorKind::WATER, 1);
  b.cfg.sens[1] = sensor(4, SensorKind::GAS, 1);
  b.cfg.nSens = 2;
  b.cfg.act[0] = valve(5, Medium::WATER);
  b.cfg.act[1] = valve(7, Medium::GAS);
  b.cfg.act[2] = sw(6, ActKind::SIREN);
  b.cfg.nAct = 3;
  b.posOpen = 0x0003;
  b.posKnown = 0x0003;
  b.start();
  b.di.level[3] = true;
  b.run(3100);
  TEST_ASSERT_EQUAL_UINT8((uint8_t)ZoneSt::LATCHED, (uint8_t)b.core.zoneState(1));
  char aid1[EID_LEN];
  strcpy(aid1, b.core.zone(1).aid);
  TEST_ASSERT_EQUAL_UINT8((uint8_t)Rej::OK, (uint8_t)b.core.ack(1, aid1, Origin::REMOTE, false, b.t));
  b.step();
  TEST_ASSERT_TRUE(b.core.zone(1).silenced);
  const uint8_t raised0 = b.out.countOf(EvType::ALARM_RAISED);
  b.di.level[4] = true;
  b.run(1500);
  TEST_ASSERT_EQUAL_UINT8(raised0 + 1, b.out.countOf(EvType::ALARM_RAISED));
  const int s = b.lastEventOf(EvType::ALARM_RAISED);
  char eid[EID_LEN];
  b.out.eidOf(s, eid);
  TEST_ASSERT_EQUAL_STRING(eid, b.core.zone(1).aid);           // bolgenin alarm kimligi yeni olay
  TEST_ASSERT_TRUE(strcmp(aid1, b.core.zone(1).aid) != 0);
  TEST_ASSERT_EQUAL_UINT8(HZ_WATER | HZ_GAS, b.out.at(s)->kinds);
  TEST_ASSERT_EQUAL_UINT16(0x0002, b.out.at(s)->actClose);      // yalniz yeni turun vanasi
  TEST_ASSERT_TRUE(b.out.at(s)->nsrcs >= 1);
  TEST_ASSERT_FALSE(b.core.zone(1).silenced);
  TEST_ASSERT_TRUE(b.relay(6));                                 // siren yeniden
  TEST_ASSERT_FALSE(b.relay(7));                                // gaz vanasi kapali (D2C)
  TEST_ASSERT_EQUAL_UINT8((uint8_t)Rej::STALE_ACK, (uint8_t)b.core.ack(1, aid1, Origin::REMOTE, false, b.t));   // eski kimlik bayat
}

// EM-2 (acilis varyanti): FAULT bolge yeniden baslatmada FAULT kalir; geri bildirim KAPALI gorulmeden bolge NORMAL'e donmez.
void test_fault_survives_power_cycle_until_feedback_closes(void) {
  Bench b;
  waterSetup(b);
  b.cfg.act[0].fb_di = 7;
  b.cfg.act[0].fb_timeout_s = 5;
  b.posOpen = 1;
  b.posKnown = 1;
  b.start();
  b.di.level[3] = true;
  b.run(1100);
  b.run(5000);
  TEST_ASSERT_EQUAL_UINT8((uint8_t)ZoneSt::FAULT, (uint8_t)b.core.zoneState(1));
  b.di.level[3] = false;
  b.core.ack(1, nullptr, Origin::REMOTE, false, b.t);
  b.powerCycle();
  TEST_ASSERT_EQUAL_UINT8((uint8_t)ZoneSt::FAULT, (uint8_t)b.core.zoneState(1));
  b.run(15000);                                                 // kuru + onayli, ama vana hala acik gorunuyor
  TEST_ASSERT_NOT_EQUAL((uint8_t)ZoneSt::NORMAL, (uint8_t)b.core.zoneState(1));
  TEST_ASSERT_EQUAL_UINT8(0, b.out.countOf(EvType::VALVE_FAULT_CLEARED));
  b.di.level[7] = true;                                         // vana kapandi
  b.run(200);
  TEST_ASSERT_TRUE(b.out.countOf(EvType::VALVE_FAULT_CLEARED) >= 1);
  b.run(11000);
  TEST_ASSERT_EQUAL_UINT8((uint8_t)ZoneSt::NORMAL, (uint8_t)b.core.zoneState(1));
}

// EM-2 (calisirken yama): ilgisiz yama (bolge adi) FAULT'u, geri bildirim zamanlayicisini ve siren butcesini korur.
void test_reconfigure_keeps_fault_siren_budget_and_suppress(void) {
  Bench b;
  waterSetup(b);
  b.cfg.act[0].fb_di = 7;
  b.cfg.act[0].fb_timeout_s = 5;
  b.cfg.act[1].run_limit_s = 20;
  b.cfg.act[2] = sw(8, ActKind::GENERIC, 0x02, 0);              // bolge 2 (kilit disi) genel cikis: kullanici acti
  b.cfg.nAct = 3;
  b.posOpen = 1;
  b.posKnown = 1;
  b.start();
  TEST_ASSERT_EQUAL_UINT8((uint8_t)Rej::OK, (uint8_t)b.core.actuatorSet(2, false, Origin::REMOTE, b.t));
  b.di.level[3] = true;
  b.run(1100);
  b.run(5000);
  TEST_ASSERT_EQUAL_UINT8((uint8_t)ZoneSt::FAULT, (uint8_t)b.core.zoneState(1));
  b.run(10000);                                                 // ~16 sn calma
  const uint32_t budget = b.act.sirenRunMs(1);
  TEST_ASSERT_TRUE(budget >= 15000);
  const uint8_t cleared0 = b.out.countOf(EvType::VALVE_FAULT_CLEARED);
  SafetyConfig old = b.cfg;
  strcpy(b.cfg.zones[0].name, "Mutfak");
  b.reconfigure(old);
  b.run(15000);
  TEST_ASSERT_EQUAL_UINT8((uint8_t)ZoneSt::FAULT, (uint8_t)b.core.zoneState(1));
  TEST_ASSERT_EQUAL_UINT8(cleared0, b.out.countOf(EvType::VALVE_FAULT_CLEARED));
  TEST_ASSERT_TRUE(b.act.fbFault(0));
  TEST_ASSERT_FALSE(b.relay(6));                                // butce (20 sn) yamada sifirlanmadi: siren sustu
  TEST_ASSERT_TRUE(b.act.sirenRunMs(1) >= 20000);
  TEST_ASSERT_TRUE(b.relay(8));                                 // elle acik cikis yamada kapanmadi
}

// EM-3: iki roleli vana kilitliyken yeniden baslatma: kapali komutlu vanaya acilista bir KAPAT darbesi daha verilir.
void test_pulse_valve_repulses_close_after_power_cycle(void) {
  Bench b;
  b.cfg.sens[0] = sensor(3, SensorKind::WATER, 1);
  b.cfg.nSens = 1;
  b.cfg.act[0] = valve(5, Medium::WATER, 0x01, CloseMode::PULSE_TWO_RELAY);
  b.cfg.act[0].relay2 = 6;
  b.cfg.act[0].run_limit_s = 15;
  b.cfg.nAct = 1;
  b.start();
  b.di.level[3] = true;
  b.run(1100);
  TEST_ASSERT_TRUE(b.relay(5));                                 // kapat darbesi basladi
  b.run(2000);
  b.powerCycle();                                               // darbe yarida kesildi
  b.run(20);
  TEST_ASSERT_TRUE(b.relay(5));                                 // acilista KAPAT darbesi yeniden
  TEST_ASSERT_FALSE(b.relay(6));
}

void test_closed_gas_pulse_valve_repulses_on_boot(void) {
  Bench b;
  b.cfg.act[0] = valve(5, Medium::GAS, 0x01, CloseMode::PULSE_TWO_RELAY);
  b.cfg.act[0].relay2 = 6;
  b.cfg.act[0].run_limit_s = 10;
  b.cfg.nAct = 1;
  b.posOpen = 1;                                                // GAS_RESET ile acilmisti
  b.posKnown = 1;
  b.start();
  b.run(20);
  TEST_ASSERT_TRUE(b.relay(5));                                 // gaz vanasi her acilista KAPALI [K-4]: darbe
  TEST_ASSERT_FALSE(b.relay(6));
}

// EM-3 (calisirken yama): darbe surerken gelen ilgisiz yama darbeyi kesmez.
void test_reconfigure_keeps_pulse_in_progress(void) {
  Bench b;
  b.cfg.sens[0] = sensor(3, SensorKind::WATER, 1);
  b.cfg.nSens = 1;
  b.cfg.act[0] = valve(5, Medium::WATER, 0x01, CloseMode::PULSE_TWO_RELAY);
  b.cfg.act[0].relay2 = 6;
  b.cfg.act[0].run_limit_s = 15;
  b.cfg.nAct = 1;
  b.start();
  b.di.level[3] = true;
  b.run(1100);
  TEST_ASSERT_TRUE(b.relay(5));
  SafetyConfig old = b.cfg;
  strcpy(b.cfg.zones[1].name, "Banyo");
  b.reconfigure(old);
  b.run(20);
  TEST_ASSERT_TRUE(b.relay(5));                                 // darbe suruyor
  b.run(15000);
  TEST_ASSERT_FALSE(b.relay(5));                                // darbe suresi doldu (uzamadi)
}

// Yan etki: GAS_RESET ile acilmis gaz vanasi ilgisiz bir yamada kendiliginden kapanmaz.
void test_reconfigure_keeps_gas_valve_opened_by_reset(void) {
  Bench b;
  b.cfg.sens[0] = sensor(3, SensorKind::GAS, 1, 1);
  b.cfg.sens[1] = sensor(4, SensorKind::GAS_RESET, 1);
  b.cfg.nSens = 2;
  b.cfg.act[0] = valve(5, Medium::GAS, 0x01, CloseMode::ENERGIZE_TO_CLOSE);
  b.cfg.nAct = 1;
  b.di.level[3] = true;
  b.start();
  b.run(100);
  b.di.level[4] = true;
  b.run(100);
  b.di.level[4] = false;
  b.run(100);
  TEST_ASSERT_FALSE(b.relay(5));                                // acik (E2C enerjisiz)
  SafetyConfig old = b.cfg;
  strcpy(b.cfg.zones[0].name, "Mutfak");
  b.reconfigure(old);
  b.run(100);
  TEST_ASSERT_FALSE(b.relay(5));
}

// EM-4: test sirasinda kullanicinin kapattigi vana test bitince geri ACILMAZ; acma izni yoksa (sensor arizali) da acilmaz.
void test_test_restore_respects_user_close_and_permission(void) {
  Bench b;
  waterSetup(b);
  b.posOpen = 1;
  b.posKnown = 1;
  b.start();
  b.run(100);
  TEST_ASSERT_TRUE(b.relay(5));
  TEST_ASSERT_EQUAL_UINT8((uint8_t)Rej::OK, (uint8_t)b.core.test(1, b.t));
  b.run(1000);
  TEST_ASSERT_EQUAL_UINT8((uint8_t)Rej::OK, (uint8_t)b.core.actuatorSet(0, true, Origin::REMOTE, b.t));   // kullanici kapatti
  b.run(5000);
  TEST_ASSERT_EQUAL_UINT8((uint8_t)ZoneSt::NORMAL, (uint8_t)b.core.zoneState(1));
  TEST_ASSERT_FALSE(b.relay(5));                                // kapali kaldi
  // ikinci tur: acik vana, test sirasinda sensor arizali -> test sonu ACMA izni yok
  TEST_ASSERT_EQUAL_UINT8((uint8_t)Rej::OK, (uint8_t)b.core.actuatorSet(0, false, Origin::REMOTE, b.t));
  b.run(100);
  TEST_ASSERT_TRUE(b.relay(5));
  TEST_ASSERT_EQUAL_UINT8((uint8_t)Rej::OK, (uint8_t)b.core.test(1, b.t));
  b.run(500);
  b.di.okv[3] = false;
  b.run(5000);
  TEST_ASSERT_EQUAL_UINT8((uint8_t)ZoneSt::NORMAL, (uint8_t)b.core.zoneState(1));
  TEST_ASSERT_FALSE(b.relay(5));
}

// EM-5: yapilandirma kullanilamiyor (eylemci tablosu bos), kilit yok: kalici acilis guvenli maskesi guvenli kipte dayatilir.
void test_safe_mode_imposes_boot_safe_mask_without_actuators(void) {
  Bench b;
  b.mode = SafeReason::CFG_CORRUPT;
  b.start();
  b.core.imposeBootMask((1ULL << 4) | (1ULL << 6), 1ULL << 4);   // role 5 E2C gaz (enerjili), role 7 D2C (enerjisiz)
  b.run(50);
  TEST_ASSERT_TRUE(b.asserted(5));
  TEST_ASSERT_TRUE(b.relay(5));
  TEST_ASSERT_TRUE(b.asserted(7));
  TEST_ASSERT_FALSE(b.relay(7));
  TEST_ASSERT_EQUAL_UINT64(0, b.core.latchRecordAssert());      // kilit kaydi yok: cikis kullanilabilirligi icin maske sayilmaz
  Bench n;                                                      // guvenli kip degilse maske dayatilmaz
  n.start();
  n.core.imposeBootMask(1ULL << 4, 1ULL << 4);
  n.run(50);
  TEST_ASSERT_FALSE(n.asserted(5));
}

// pano-1 (i): yalniz sensorlu kurulum (NC gaz sensoru, eylemci yok) alarmla kilitliyken elektrik kesildi. Acilis karari (SafetyManager::begin
// ile ayni girdiler) NORMAL kiptir: bolge ayni aid ile LATCHED geri yuklenir; onay + kuruluk (dry_hold) bolgeyi temizler. Eskiden
// latch_orphan guvenli kipinde kalirdi ve eylemcisiz yapilandirmayla cikis yolu yoktu.
void test_sensor_only_latch_power_cycle_restores_normal_and_clears(void) {
  Bench b;
  b.cfg.sens[0] = sensor(3, SensorKind::GAS, 1, 1);
  b.cfg.nSens = 1;
  b.di.level[3] = true;                              // NC gaz: kontak kapali = normal
  b.start();
  b.run(100);
  b.di.level[3] = false;                             // kontak acildi: gaz
  b.run(1100);
  TEST_ASSERT_EQUAL_UINT8((uint8_t)ZoneSt::LATCHED, (uint8_t)b.core.zoneState(1));
  char aid[EID_LEN];
  strcpy(aid, b.core.zone(1).aid);
  b.di.level[3] = true;                              // gaz gitti
  static LatchRecord rec;
  b.core.buildLatch(rec);
  TEST_ASSERT_EQUAL_UINT64(0, latchAssert64(rec));   // kilit hicbir role istemiyor
  CrashLog crash;
  crashClear(crash);
  b.mode = decideBootMode(true, true, &rec, b.cfg, crash);
  TEST_ASSERT_EQUAL_UINT8((uint8_t)SafeReason::NONE, (uint8_t)b.mode);
  b.powerCycle();
  TEST_ASSERT_FALSE(b.core.safeMode());
  TEST_ASSERT_EQUAL_UINT8((uint8_t)ZoneSt::LATCHED, (uint8_t)b.core.zoneState(1));
  TEST_ASSERT_EQUAL_STRING(aid, b.core.zone(1).aid);
  TEST_ASSERT_EQUAL_UINT8((uint8_t)Rej::OK, (uint8_t)b.core.ack(1, nullptr, Origin::LOCAL_DI, false, b.t));
  b.run(DRY_HOLD_DEFAULT_MS + 2000);
  TEST_ASSERT_EQUAL_UINT8((uint8_t)ZoneSt::NORMAL, (uint8_t)b.core.zoneState(1));
  TEST_ASSERT_TRUE(b.lastEventOf(EvType::ALARM_CLEARED) >= 0);
}

// pano-1 (ii): cfg_corrupt guvenli kipinde eylemcisiz (yalniz sensorlu) gecerli yapilandirma uygulanir (SafetyManager::applyConfigOnLoop:
// reconfigured + setConfigUsable(latchCovered(kilit kaydi, eylemci roleleri))). Kilit kaydi role istemiyorsa yerinde ACK FORCE guvenli
// kipten cikarir; kilit kaydi tabloda olmayan roleyi istiyorsa cikis kapali kalir (iii).
void test_safe_mode_exit_after_actuatorless_config_applied(void) {
  Bench b;
  b.haveLatch = true;
  latchClear(b.latch);
  b.latch.z[0].st = 1;                               // kilitli bolge, role maskesi bos (yalniz sensorlu kurulumun kaydi)
  latchSeal(b.latch);
  b.mode = SafeReason::CFG_CORRUPT;
  b.start();
  TEST_ASSERT_TRUE(b.core.safeMode());
  TEST_ASSERT_EQUAL_UINT8((uint8_t)Rej::SAFE_MODE, (uint8_t)b.core.ack(0, nullptr, Origin::LOCAL_DI, true, b.t));   // henuz kullanilamaz
  const SafetyConfig old = b.cfg;
  b.cfg.sens[0] = sensor(3, SensorKind::GAS, 1, 1);
  b.cfg.nSens = 1;
  b.di.level[3] = true;
  b.reconfigure(old);
  b.core.setConfigUsable(latchCovered(b.core.latchRecordAssert(), b.act.relayMask()));
  TEST_ASSERT_EQUAL_UINT8((uint8_t)Rej::SAFE_MODE, (uint8_t)b.core.ack(0, nullptr, Origin::REMOTE, true, b.t));    // uzaktan cikis yok
  TEST_ASSERT_EQUAL_UINT8((uint8_t)Rej::OK, (uint8_t)b.core.ack(0, nullptr, Origin::LOCAL_DI, true, b.t));
  b.step();
  TEST_ASSERT_FALSE(b.core.safeMode());
  // (iii) kilit kaydi role 5'i istiyor, eylemcisiz tablo kapsamiyor: cikis kullanilamaz
  Bench o;
  o.haveLatch = true;
  latchClear(o.latch);
  o.latch.z[0].st = 1;
  latchSetMasks(o.latch, 1ULL << 4, 0);
  latchSeal(o.latch);
  o.mode = SafeReason::CFG_CORRUPT;
  o.start();
  const SafetyConfig old2 = o.cfg;
  o.cfg.sens[0] = sensor(3, SensorKind::GAS, 1, 1);
  o.cfg.nSens = 1;
  o.reconfigure(old2);
  TEST_ASSERT_FALSE(latchCovered(o.core.latchRecordAssert(), o.act.relayMask()));
  o.core.setConfigUsable(latchCovered(o.core.latchRecordAssert(), o.act.relayMask()));
  TEST_ASSERT_EQUAL_UINT8((uint8_t)Rej::SAFE_MODE, (uint8_t)o.core.ack(0, nullptr, Origin::LOCAL_DI, true, o.t));
  TEST_ASSERT_TRUE(o.core.safeMode());
}

int main(int, char**) {
  UNITY_BEGIN();
  RUN_TEST(test_unconfigured_core_is_idle);
  RUN_TEST(test_test_on_unconfigured_board_finishes);
  RUN_TEST(test_short_wet_signal_no_alarm);
  RUN_TEST(test_drip_reaches_alarm);
  RUN_TEST(test_confirmed_wet_latches_closes_valve_and_sounds);
  RUN_TEST(test_ack_while_wet_only_silences);
  RUN_TEST(test_acked_and_dry_clears_but_valve_stays_closed);
  RUN_TEST(test_dry_first_then_ack_clears_immediately);
  RUN_TEST(test_not_ok_sensor_blocks_clear_and_open);
  RUN_TEST(test_kind_to_medium_mapping);
  RUN_TEST(test_gas_rules);
  RUN_TEST(test_gas_sensor_wire_break_closes_gas_valve);
  RUN_TEST(test_stale_aid_ack_rejected);
  RUN_TEST(test_policy_off_blocks_new_alarms_but_keeps_latch);
  RUN_TEST(test_feedback_timeout_fault_and_recovery);
  RUN_TEST(test_test_cycle_and_restore);
  RUN_TEST(test_test_without_feedback_times_out_ok);
  RUN_TEST(test_real_wet_during_test_latches);
  RUN_TEST(test_multi_zone_valve_open_permission);
  RUN_TEST(test_millis_rollover);
  RUN_TEST(test_latch_survives_power_cycle_with_same_aid);
  RUN_TEST(test_safe_mode_applies_latch_mask_and_rejects_open);
  RUN_TEST(test_safe_mode_rejects_valve_open);
  RUN_TEST(test_crash_loop_safe_mode_exits_after_30_min);
  RUN_TEST(test_local_control_roles);
  RUN_TEST(test_safe_mode_exit_by_ack_button_hold);
  RUN_TEST(test_siren_run_limit_in_alarm);
  RUN_TEST(test_pulse_valve_closes_in_alarm_without_opening);
  RUN_TEST(test_raw_safe_command_reports_close);
  RUN_TEST(test_new_hazard_in_latched_zone_raises_new_alarm);
  RUN_TEST(test_fault_survives_power_cycle_until_feedback_closes);
  RUN_TEST(test_reconfigure_keeps_fault_siren_budget_and_suppress);
  RUN_TEST(test_pulse_valve_repulses_close_after_power_cycle);
  RUN_TEST(test_closed_gas_pulse_valve_repulses_on_boot);
  RUN_TEST(test_reconfigure_keeps_pulse_in_progress);
  RUN_TEST(test_reconfigure_keeps_gas_valve_opened_by_reset);
  RUN_TEST(test_test_restore_respects_user_close_and_permission);
  RUN_TEST(test_safe_mode_imposes_boot_safe_mask_without_actuators);
  RUN_TEST(test_sensor_only_latch_power_cycle_restores_normal_and_clears);
  RUN_TEST(test_safe_mode_exit_after_actuatorless_config_applied);
  return UNITY_END();
}
