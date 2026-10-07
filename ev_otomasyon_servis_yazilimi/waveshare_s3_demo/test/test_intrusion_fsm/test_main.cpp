// IntrusionCore (src/safety/IntrusionFsm.h) birim testleri: kapı/pencere/hareket alarm kipi (Faz 2 tasarımı F2.B, plan 2.5).
// SAF MANTIK; SensorHub + EventOutbox + sahte DI kaynağı; saat parametre. Siren VEYA'sı (SafetyCore + ActuatorCore) ayrıca sınanır.
#include <unity.h>
#include <stdint.h>
#include <string.h>
#include "safety/IntrusionFsm.h"

using namespace safety;

void setUp(void) {}
void tearDown(void) {}

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

// NC kontak (kapı/pencere: kontak açılınca aktif). Bayraklar türün varsayılanı.
static SensorConfig contact(uint8_t di, SensorKind k, uint8_t zone, uint8_t nc = 1) {
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

static ActuatorConfig siren(uint8_t relay, uint8_t zones = 0x01, uint16_t lim = 30) {
  ActuatorConfig a;
  memset(&a, 0, sizeof(a));
  a.relay = relay;
  a.kind = (uint8_t)ActKind::SIREN;
  a.zone_mask = zones;
  a.run_limit_s = lim;
  return a;
}

// Tezgah: kapı d1 (giriş yolu), pencere d2 (anlık), hareket d3 (yalnız dışarıda), siren rölesi 6 (bölge 2: hırsız alarmı ev genelidir).
struct Bench {
  SafetyConfig cfg;
  SensorHub hub;
  ActuatorCore act;
  EventOutbox out;
  FakeSource di;
  FakeSource br;
  SafetyCore core;
  IntrusionCore intr;
  uint32_t t;
  ArmRecord rec;
  bool haveRec;

  Bench() : t(1000), haveRec(false) {
    cfg.setDefaults();
    memset(&rec, 0, sizeof(rec));
  }
  void std3() {
    cfg.sens[0] = contact(1, SensorKind::DOOR, 1);
    cfg.sens[1] = contact(2, SensorKind::WINDOW, 1);
    cfg.sens[2] = contact(3, SensorKind::MOTION, 2, 0);
    cfg.nSens = 3;
    cfg.act[0] = siren(6, 0x02);
    cfg.nAct = 1;
    cfg.pol.exit_s = 10;
    cfg.pol.entry_s = 5;
  }
  void start(uint32_t t0 = 1000) {
    t = t0;
    out.begin(0x0badf00du);
    act.configure(cfg.act, cfg.nAct, 0, 0, t);
    hub.configure(cfg.sens, cfg.nSens, t);
    core.begin(&cfg, &hub, &act, &out, nullptr, SafeReason::NONE, t);
    intr.begin(&cfg, &hub, &out, haveRec ? &rec : nullptr, t);
    step(0);
  }
  void step(uint32_t ms = 10) {
    t += ms;
    core.tick(t, 0, &di, &br);
    intr.tick(t, 0);
    core.setIntrusionSiren(intr.sirenReq(), intr.takeSirenKick(), t);
  }
  void run(uint32_t ms) { for (uint32_t d = 0; d < ms; d += 10) step(10); }
  bool relay(uint8_t r) { uint64_t a, l; core.outputMasks(a, l); return (l >> (r - 1)) & 1ULL; }
  // NC kontak: açık = level false
  void open(uint8_t di_, bool o) { di.level[di_] = !o; }
  int countOf(EvType ty) { return out.countOf(ty); }
  int lastOf(EvType ty) {
    int best = -1;
    for (int i = 0; i < EventOutbox::CAP; i++) if (out.at(i) && out.at(i)->type == (uint8_t)ty) best = i;
    return best;
  }
  // SafetyManager::handleCommand esdegeri: komuttan hemen sonra siren istegi ayni turda cekirdege verilir.
  Rej arm(ArmMode m, uint8_t via = VIA_CLOUD) {
    const Rej r = intr.command(m, via, t);
    core.setIntrusionSiren(intr.sirenReq(), intr.takeSirenKick(), t);
    return r;
  }
  void powerCycle() {
    intr.record(rec);
    haveRec = true;
    SensorHub h2; hub = h2;
    ActuatorCore a2; act = a2;
    SafetyCore c2; core = c2;
    IntrusionCore i2; intr = i2;
    start(t + 5000);
  }
};

// Kapalı kontaklarla başlat (NC: level true = kapalı).
static void closedAll(Bench& b) { for (int i = 1; i <= 3; i++) b.di.level[i] = true; b.di.level[3] = false; }

void test_flags_defaults_and_bits(void) {
  TEST_ASSERT_EQUAL_HEX8(0x08, SF_ENTRY);
  TEST_ASSERT_EQUAL_HEX8(0x10, SF_AWAY_ONLY);
  TEST_ASSERT_EQUAL_HEX8(SF_REACT | SF_ENTRY, defaultFlags((uint8_t)SensorKind::DOOR));
  TEST_ASSERT_EQUAL_HEX8(SF_REACT, defaultFlags((uint8_t)SensorKind::WINDOW));
  TEST_ASSERT_EQUAL_HEX8(SF_REACT | SF_AWAY_ONLY, defaultFlags((uint8_t)SensorKind::MOTION));
  TEST_ASSERT_EQUAL_HEX8(SF_REACT | SF_FAULT_CLOSE, defaultFlags((uint8_t)SensorKind::GAS));
  TEST_ASSERT_EQUAL_HEX8(SF_REACT, defaultFlags((uint8_t)SensorKind::WATER));
  TEST_ASSERT_TRUE(isControlRole((uint8_t)SensorKind::ARM_KEY));
  TEST_ASSERT_EQUAL_UINT8(19, (uint8_t)SensorKind::ARM_KEY);
  Policy p;
  memset(&p, 0, sizeof(p));
  TEST_ASSERT_EQUAL_UINT8(45, exitDelayS(p));
  TEST_ASSERT_EQUAL_UINT8(30, entryDelayS(p));
  p.exit_s = 1;
  p.entry_s = 255;
  TEST_ASSERT_EQUAL_UINT8(1, exitDelayS(p));
  TEST_ASSERT_EQUAL_UINT8(255, entryDelayS(p));
  TEST_ASSERT_EQUAL_INT(20, (int)sizeof(ArmRecord));
  TEST_ASSERT_EQUAL_STRING("cfg_storage", rejText(Rej::CFG_STORAGE));   // WP-C1: NVS payi yetmedi (eskiden busy)
  TEST_ASSERT_EQUAL_STRING("armed", rejText(Rej::ARMED));               // Faz 2 incelemesi G-1b: kurulu kipte bulut yamasi reddi
}

void test_unconfigured_is_off_and_absent(void) {
  Bench b;
  b.start();
  b.run(1000);
  TEST_ASSERT_FALSE(b.intr.present());
  TEST_ASSERT_EQUAL(ArmMode::OFF, b.intr.mode());
  TEST_ASSERT_EQUAL(0, b.out.count());
  TEST_ASSERT_FALSE(b.intr.takeDirty());
}

void test_arm_not_ready_when_instant_open(void) {
  Bench b;
  b.std3();
  closedAll(b);
  b.open(2, true);                         // pencere açık
  b.start();
  b.run(200);
  TEST_ASSERT_TRUE(b.intr.present());
  TEST_ASSERT_EQUAL(Rej::NOT_READY, b.arm(ArmMode::HOME));
  TEST_ASSERT_EQUAL_STRING("not_ready", rejText(Rej::NOT_READY));
  TEST_ASSERT_EQUAL(ArmMode::OFF, b.intr.mode());
  TEST_ASSERT_EQUAL(0, b.countOf(EvType::ARM_CHANGED));
  b.open(2, false);
  b.run(50);
  TEST_ASSERT_EQUAL(Rej::OK, b.arm(ArmMode::HOME));
  TEST_ASSERT_EQUAL(ArmMode::HOME, b.intr.mode());
  TEST_ASSERT_EQUAL(ArmSt::EXIT, b.intr.st());
  TEST_ASSERT_EQUAL(1, b.countOf(EvType::ARM_CHANGED));
  TEST_ASSERT_TRUE(b.intr.takeDirty());
}

void test_not_ok_sensor_blocks_arm_and_never_alarms(void) {
  Bench b;
  b.std3();
  closedAll(b);
  b.di.okv[2] = false;                     // pencere okunamıyor
  b.start();
  b.run(200);
  TEST_ASSERT_EQUAL(Rej::NOT_READY, b.arm(ArmMode::AWAY));
  b.di.okv[2] = true;
  b.run(50);
  TEST_ASSERT_EQUAL(Rej::OK, b.arm(ArmMode::AWAY));
  b.run(10000 + 100);
  TEST_ASSERT_EQUAL(ArmSt::IDLE, b.intr.st());
  b.di.okv[2] = false;                     // kurulu kipte ok=false: alarm yok (NC kopukluğu sensor_fault yolundan)
  b.run(2000);
  TEST_ASSERT_EQUAL(ArmSt::IDLE, b.intr.st());
  TEST_ASSERT_EQUAL(0, b.countOf(EvType::INTRUSION_ALARM));
}

void test_exit_error_door_open_goes_to_entry(void) {
  Bench b;
  b.std3();
  closedAll(b);
  b.open(1, true);                         // kapı açıkken kurulabilir (giriş yolu)
  b.start();
  b.run(100);
  TEST_ASSERT_EQUAL(Rej::OK, b.arm(ArmMode::AWAY));
  TEST_ASSERT_EQUAL(BuzPattern::EXIT, b.intr.buzzer());
  b.run(10000 + 20);                       // çıkış süresi doldu, kapı hâlâ açık
  TEST_ASSERT_EQUAL(ArmSt::ENTRY, b.intr.st());
  TEST_ASSERT_EQUAL(BuzPattern::ENTRY, b.intr.buzzer());
  b.run(5000 + 20);
  TEST_ASSERT_EQUAL(ArmSt::ALARM, b.intr.st());
  TEST_ASSERT_EQUAL(1, b.countOf(EvType::INTRUSION_ALARM));
}

void test_exit_delay_then_idle_and_instant_alarm(void) {
  Bench b;
  b.std3();
  closedAll(b);
  b.start();
  b.run(100);
  TEST_ASSERT_EQUAL(Rej::OK, b.arm(ArmMode::AWAY));
  b.open(1, true);                         // kullanıcı kapıdan çıkıyor (çıkış süresinde giriş yolu yok sayılır)
  b.run(3000);
  b.open(1, false);
  b.run(3000);
  TEST_ASSERT_EQUAL(ArmSt::EXIT, b.intr.st());
  b.run(4100);
  TEST_ASSERT_EQUAL(ArmSt::IDLE, b.intr.st());
  TEST_ASSERT_EQUAL(BuzPattern::OFF, b.intr.buzzer());
  TEST_ASSERT_FALSE(b.relay(6));
  b.open(2, true);                         // pencere: anlık alarm
  b.step();
  b.step();
  TEST_ASSERT_EQUAL(ArmSt::ALARM, b.intr.st());
  TEST_ASSERT_TRUE(b.relay(6));            // siren (bölge 2'de olsa bile: ev geneli)
  TEST_ASSERT_EQUAL(BuzPattern::ALARM, b.intr.buzzer());
  const int s = b.lastOf(EvType::INTRUSION_ALARM);
  TEST_ASSERT_TRUE(s >= 0);
  const Event* e = b.out.at(s);
  TEST_ASSERT_EQUAL_UINT8(1, e->zone);
  TEST_ASSERT_EQUAL_UINT8(1, e->nsrcs);
  TEST_ASSERT_EQUAL_UINT8(2, e->srcs[0]);
  char eid[EID_LEN];
  b.out.eidOf(s, eid);
  TEST_ASSERT_EQUAL_STRING(eid, b.intr.aid());
  char json[EVENT_JSON_MAX];
  TEST_ASSERT_TRUE(b.out.toJson(s, "AHBU-S3-000001", 7, json, sizeof(json)) > 0);
  TEST_ASSERT_NOT_NULL(strstr(json, "\"type\":\"intrusion_alarm\""));
  TEST_ASSERT_NOT_NULL(strstr(json, "\"kind\":\"intrusion\""));
  TEST_ASSERT_NOT_NULL(strstr(json, "\"srcs\":[\"d2\"]"));
  TEST_ASSERT_NULL(strstr(json, "\"aid\""));
}

void test_instant_during_exit_alarms(void) {
  Bench b;
  b.std3();
  closedAll(b);
  b.start();
  b.run(100);
  TEST_ASSERT_EQUAL(Rej::OK, b.arm(ArmMode::HOME));
  b.run(1000);
  b.open(2, true);
  b.step();
  TEST_ASSERT_EQUAL(ArmSt::ALARM, b.intr.st());
}

void test_entry_delay_disarm_prevents_alarm(void) {
  Bench b;
  b.std3();
  closedAll(b);
  b.start();
  b.run(100);
  b.arm(ArmMode::AWAY);
  b.run(10100);
  b.open(1, true);                         // eve giriş
  b.step();
  TEST_ASSERT_EQUAL(ArmSt::ENTRY, b.intr.st());
  const uint32_t until = b.intr.untilUp();
  b.run(2000);
  TEST_ASSERT_EQUAL_UINT32(until, b.intr.untilUp());   // sabit değer (görünüm imzası her saniye değişmez)
  TEST_ASSERT_EQUAL(Rej::OK, b.arm(ArmMode::OFF, VIA_LAN));
  TEST_ASSERT_EQUAL(ArmMode::OFF, b.intr.mode());
  TEST_ASSERT_EQUAL(ArmSt::IDLE, b.intr.st());
  b.run(6000);
  TEST_ASSERT_EQUAL(0, b.countOf(EvType::INTRUSION_ALARM));
  TEST_ASSERT_EQUAL(0, b.countOf(EvType::INTRUSION_CLEARED));
  TEST_ASSERT_EQUAL(2, b.countOf(EvType::ARM_CHANGED));
  TEST_ASSERT_FALSE(b.relay(6));
}

void test_entry_timeout_alarms_and_disarm_clears(void) {
  Bench b;
  b.std3();
  closedAll(b);
  b.start();
  b.run(100);
  b.arm(ArmMode::AWAY);
  b.run(10100);
  b.open(1, true);
  b.step();
  b.open(1, false);                        // kapı kapandı ama çözülmedi
  b.run(5100);
  TEST_ASSERT_EQUAL(ArmSt::ALARM, b.intr.st());
  TEST_ASSERT_EQUAL_UINT8(1, b.intr.nsrcs());
  TEST_ASSERT_EQUAL_UINT8(1, b.intr.srcs()[0]);
  TEST_ASSERT_TRUE(b.relay(6));
  char aid[EID_LEN];
  strcpy(aid, b.intr.aid());
  TEST_ASSERT_EQUAL(Rej::OK, b.arm(ArmMode::OFF, VIA_CLOUD));
  TEST_ASSERT_FALSE(b.relay(6));
  const int s = b.lastOf(EvType::INTRUSION_CLEARED);
  TEST_ASSERT_TRUE(s >= 0);
  TEST_ASSERT_EQUAL_STRING(aid, b.out.at(s)->aid);
  char json[EVENT_JSON_MAX];
  TEST_ASSERT_TRUE(b.out.toJson(s, "U", 1, json, sizeof(json)) > 0);
  TEST_ASSERT_NOT_NULL(strstr(json, "\"via\":\"cloud\""));
  TEST_ASSERT_NOT_NULL(strstr(json, "\"aid\":\""));
  const int a = b.lastOf(EvType::ARM_CHANGED);
  TEST_ASSERT_TRUE(b.out.toJson(a, "U", 1, json, sizeof(json)) > 0);
  TEST_ASSERT_NOT_NULL(strstr(json, "\"mode\":\"off\""));
  TEST_ASSERT_EQUAL_STRING("", b.intr.aid());
}

void test_home_mode_ignores_motion(void) {
  Bench b;
  b.std3();
  closedAll(b);
  b.di.level[3] = true;                    // hareket aktif (NO): evde kipte etkisiz, kurulabilir
  b.start();
  b.run(100);
  TEST_ASSERT_EQUAL(Rej::OK, b.arm(ArmMode::HOME));
  b.run(10100);
  b.di.level[3] = false;
  b.run(100);
  b.di.level[3] = true;
  b.run(100);
  TEST_ASSERT_EQUAL(ArmSt::IDLE, b.intr.st());
  // dışarıda kipte hareket anlık ve kurmayı engeller
  TEST_ASSERT_EQUAL(Rej::NOT_READY, b.arm(ArmMode::AWAY));
  TEST_ASSERT_EQUAL(ArmMode::HOME, b.intr.mode());
  b.di.level[3] = false;
  b.run(50);
  TEST_ASSERT_EQUAL(Rej::OK, b.arm(ArmMode::AWAY));   // kip değişimi: yeni çıkış gecikmesi
  TEST_ASSERT_EQUAL(ArmSt::EXIT, b.intr.st());
  b.run(10100);
  b.di.level[3] = true;
  b.step();
  TEST_ASSERT_EQUAL(ArmSt::ALARM, b.intr.st());
}

void test_swinger_limit_three_restarts(void) {
  Bench b;
  b.std3();
  b.cfg.act[0].run_limit_s = 10;
  closedAll(b);
  b.start();
  b.run(100);
  b.arm(ArmMode::HOME);
  b.run(10100);
  b.open(2, true);
  b.step();
  TEST_ASSERT_TRUE(b.relay(6));
  int restarts = 0;
  for (int k = 0; k < 5; k++) {
    b.run(10100);                          // siren bütçesi bitti
    TEST_ASSERT_FALSE(b.relay(6));
    b.open(2, false);
    b.run(100);
    b.open(2, true);                       // aynı pencere yeniden
    b.step();
    if (b.relay(6)) restarts++;
  }
  TEST_ASSERT_EQUAL(2, restarts);          // ilk tetik + 2 yeniden = 3
  TEST_ASSERT_EQUAL(1, b.countOf(EvType::INTRUSION_ALARM));
  b.open(1, true);                         // başka sensör: srcs'e eklenir, kendi hakkıyla yeniden çalar
  b.step();
  TEST_ASSERT_TRUE(b.relay(6));
  TEST_ASSERT_EQUAL_UINT8(2, b.intr.nsrcs());
}

void test_millis_rollover(void) {
  Bench b;
  b.std3();
  closedAll(b);
  b.start(0xFFFFF000u);
  b.run(100);
  b.arm(ArmMode::AWAY);
  b.run(9000);
  TEST_ASSERT_EQUAL(ArmSt::EXIT, b.intr.st());
  b.run(1200);
  TEST_ASSERT_EQUAL(ArmSt::IDLE, b.intr.st());
  b.open(1, true);
  b.step();
  b.run(4900);
  TEST_ASSERT_EQUAL(ArmSt::ENTRY, b.intr.st());
  b.run(200);
  TEST_ASSERT_EQUAL(ArmSt::ALARM, b.intr.st());
}

void test_boot_restores_mode_without_exit_delay(void) {
  Bench b;
  b.std3();
  closedAll(b);
  b.start();
  b.run(100);
  b.arm(ArmMode::AWAY);
  b.run(10100);
  b.powerCycle();
  TEST_ASSERT_EQUAL(ArmMode::AWAY, b.intr.mode());
  TEST_ASSERT_EQUAL(ArmSt::IDLE, b.intr.st());
  const int a = b.lastOf(EvType::ARM_CHANGED);
  TEST_ASSERT_TRUE(a >= 0);
  char json[EVENT_JSON_MAX];
  TEST_ASSERT_TRUE(b.out.toJson(a, "U", 1, json, sizeof(json)) > 0);
  TEST_ASSERT_NOT_NULL(strstr(json, "\"via\":\"boot\""));
  TEST_ASSERT_NOT_NULL(strstr(json, "\"mode\":\"away\""));
  b.open(2, true);
  b.step();
  TEST_ASSERT_EQUAL(ArmSt::ALARM, b.intr.st());   // kurulu kip korunur: anlık sensör hemen alarm
}

void test_boot_restores_alarm_silently(void) {
  Bench b;
  b.std3();
  closedAll(b);
  b.start();
  b.run(100);
  b.arm(ArmMode::HOME);
  b.run(10100);
  b.open(2, true);
  b.step();
  TEST_ASSERT_TRUE(b.relay(6));
  char aid[EID_LEN];
  strcpy(aid, b.intr.aid());
  b.open(2, false);
  b.powerCycle();
  TEST_ASSERT_EQUAL(ArmSt::ALARM, b.intr.st());
  TEST_ASSERT_EQUAL_STRING(aid, b.intr.aid());
  b.run(500);
  TEST_ASSERT_FALSE(b.relay(6));           // bellekteki alarm sirensiz geri gelir (bütçe tükenmiş sayılır)
  TEST_ASSERT_EQUAL(0, b.countOf(EvType::INTRUSION_ALARM));
  b.open(1, true);                         // yeni tetik: siren yeniden
  b.step();
  TEST_ASSERT_TRUE(b.relay(6));
  TEST_ASSERT_EQUAL(Rej::OK, b.arm(ArmMode::OFF, VIA_CLI));
  TEST_ASSERT_EQUAL(1, b.countOf(EvType::INTRUSION_CLEARED));
}

void test_arm_rejections(void) {
  Bench b;
  b.std3();
  closedAll(b);
  b.start();
  b.run(100);
  TEST_ASSERT_EQUAL(Rej::OK, b.arm(ArmMode::OFF));         // çözülüyken çözme: işlem yok, olay yok
  TEST_ASSERT_EQUAL(0, b.countOf(EvType::ARM_CHANGED));
  b.arm(ArmMode::HOME);
  TEST_ASSERT_EQUAL(Rej::OK, b.arm(ArmMode::HOME));        // aynı kip: işlem yok
  TEST_ASSERT_EQUAL(1, b.countOf(EvType::ARM_CHANGED));
  b.run(10100);
  b.open(2, true);
  b.step();
  TEST_ASSERT_EQUAL(Rej::BAD_STATE, b.arm(ArmMode::AWAY)); // alarmdayken önce çözülmeli
  // sensörsüz pano: kurulacak bir şey yok
  Bench c;
  c.start();
  TEST_ASSERT_EQUAL(Rej::BAD_STATE, c.arm(ArmMode::AWAY));
  // güvenli kip (tablo kullanılamaz): kurma reddi, çözme serbest, alarm yok
  Bench d;
  d.std3();
  closedAll(d);
  d.start();
  d.run(100);
  d.arm(ArmMode::HOME);
  d.intr.setUsable(false);
  TEST_ASSERT_FALSE(d.intr.usable());
  d.open(2, true);
  d.run(15000);
  TEST_ASSERT_EQUAL(0, d.countOf(EvType::INTRUSION_ALARM));
  TEST_ASSERT_EQUAL(Rej::SAFE_MODE, d.arm(ArmMode::AWAY));
  TEST_ASSERT_EQUAL(Rej::OK, d.arm(ArmMode::OFF));
}

void test_arm_key_edges(void) {
  Bench b;
  b.std3();
  closedAll(b);
  SensorConfig k;
  memset(&k, 0, sizeof(k));
  k.src = (uint8_t)SensorSrc::DI;
  k.index = 7;
  k.kind = (uint8_t)SensorKind::ARM_KEY;
  b.cfg.sens[3] = k;
  b.cfg.nSens = 4;
  ActuatorConfig v;                        // su vanası: ARM_KEY kenarı onu KAPATMAMALI (VALVE_CLOSE değildir)
  memset(&v, 0, sizeof(v));
  v.relay = 5;
  v.kind = (uint8_t)ActKind::VALVE;
  v.close_mode = (uint8_t)CloseMode::DEENERGIZE_TO_CLOSE;
  v.medium = (uint8_t)Medium::WATER;
  v.zone_mask = 0x0F;
  b.cfg.act[1] = v;
  b.cfg.nAct = 2;
  b.di.level[7] = true;                    // açılışta anahtar zaten aktif: kenar değil
  b.start();
  b.run(200);
  TEST_ASSERT_EQUAL(ArmMode::OFF, b.intr.mode());
  b.di.level[7] = false;                   // aktif -> pasif: çözme (zaten çözülü)
  b.run(100);
  b.open(2, true);                         // pencere açık: anahtar kurmayı denerse hata bip'i
  b.run(50);
  b.di.level[7] = true;
  b.run(100);
  TEST_ASSERT_EQUAL(ArmMode::OFF, b.intr.mode());
  TEST_ASSERT_TRUE(b.intr.takeKeyError());
  TEST_ASSERT_FALSE(b.intr.takeKeyError());
  b.di.level[7] = false;
  b.open(2, false);
  b.run(100);
  b.di.level[7] = true;                    // kenar: dışarıda kip
  b.run(50);
  TEST_ASSERT_EQUAL(ArmMode::AWAY, b.intr.mode());
  const int a = b.lastOf(EvType::ARM_CHANGED);
  char json[EVENT_JSON_MAX];
  TEST_ASSERT_TRUE(b.out.toJson(a, "U", 1, json, sizeof(json)) > 0);
  TEST_ASSERT_NOT_NULL(strstr(json, "\"via\":\"di\""));
  b.di.level[7] = false;                   // çöz
  b.run(50);
  TEST_ASSERT_EQUAL(ArmMode::OFF, b.intr.mode());
  // ARM_KEY bir vana kumandası DEĞİLDİR (SafetyCore kontrol rolleri onu atlar)
  TEST_ASSERT_EQUAL(0, b.countOf(EvType::ACTUATOR_CHANGED));
}

void test_siren_or_hazard_ack_and_disarm_independent(void) {
  Bench b;
  b.std3();
  b.cfg.sens[3] = contact(4, SensorKind::WATER, 2, 0);
  b.cfg.nSens = 4;
  closedAll(b);
  b.start();
  b.run(100);
  b.arm(ArmMode::HOME);
  b.run(10100);
  b.di.level[4] = true;                    // su alarmı bölge 2 (siren bölgesi)
  b.run(1500);
  TEST_ASSERT_TRUE(b.relay(6));
  b.open(2, true);                         // hırsız alarmı da
  b.step();
  TEST_ASSERT_EQUAL(ArmSt::ALARM, b.intr.st());
  TEST_ASSERT_EQUAL(Rej::OK, b.core.ack(0, nullptr, Origin::REMOTE, false, b.t));   // tehlike ACK: hırsız sireni sürer
  b.step();
  TEST_ASSERT_TRUE(b.relay(6));
  b.arm(ArmMode::OFF);                     // çözme: tehlike susturulmuş, siren durur
  b.step();
  TEST_ASSERT_FALSE(b.relay(6));
  // ters sıra: çözme tehlike sirenini susturmaz
  Bench c;
  c.std3();
  c.cfg.sens[3] = contact(4, SensorKind::WATER, 2, 0);
  c.cfg.nSens = 4;
  closedAll(c);
  c.start();
  c.run(100);
  c.arm(ArmMode::HOME);
  c.run(10100);
  c.open(2, true);
  c.step();
  c.di.level[4] = true;
  c.run(1500);
  c.arm(ArmMode::OFF);
  c.step();
  TEST_ASSERT_TRUE(c.relay(6));
  // kullanıcının sireni kapatması iki isteği de bastırır
  Bench d;
  d.std3();
  closedAll(d);
  d.start();
  d.run(100);
  d.arm(ArmMode::HOME);
  d.run(10100);
  d.open(2, true);
  d.step();
  TEST_ASSERT_TRUE(d.relay(6));
  TEST_ASSERT_EQUAL(Rej::OK, d.core.actuatorSet(0, true, Origin::REMOTE, d.t));
  d.step();
  TEST_ASSERT_FALSE(d.relay(6));
  d.open(1, true);                         // yeni tetik bastırmayı kaldırmaz (o alarm dönemi)
  d.step();
  TEST_ASSERT_FALSE(d.relay(6));
}

void test_intrusion_budget_separate_from_hazard(void) {
  Bench b;
  b.std3();
  b.cfg.act[0].run_limit_s = 10;
  b.cfg.sens[3] = contact(4, SensorKind::WATER, 2, 0);
  b.cfg.nSens = 4;
  closedAll(b);
  b.start();
  b.run(100);
  b.di.level[4] = true;                    // tehlike sireni bütçesini bitirir
  b.run(12000);
  TEST_ASSERT_FALSE(b.relay(6));
  b.arm(ArmMode::HOME);
  b.run(10100);
  b.open(2, true);                         // hırsız sireni kendi bütçesiyle çalar
  b.step();
  TEST_ASSERT_TRUE(b.relay(6));
  b.run(10100);
  TEST_ASSERT_FALSE(b.relay(6));
}

void test_view_until_up_and_record(void) {
  Bench b;
  b.std3();
  closedAll(b);
  b.start(5000);
  b.run(100);
  b.arm(ArmMode::AWAY);
  TEST_ASSERT_EQUAL_UINT32((5100 + 10000 + 999) / 1000, b.intr.untilUp());
  ArmRecord r;
  b.intr.record(r);
  TEST_ASSERT_EQUAL_UINT8(ARM_REC_VER, r.ver);
  TEST_ASSERT_EQUAL_UINT8((uint8_t)ArmMode::AWAY, r.mode);
  TEST_ASSERT_EQUAL_UINT8(0, r.alarm);
}

// Faz 2 incelemesi RV-E2: giris gecikmesi surerken enerji kesilirse olay kaybolmaz. Kayit "giris" (alarm = ARM_REC_ENTRY) ve giris yolu
// sensorleriyle yazilir; acilista giris gecikmesi BASTAN baslar (kapi kapatilmis olsa da), sure dolunca alarm (kaynak: kapi), siren calar.
void test_boot_restores_entry_delay(void) {
  Bench b;
  b.std3();
  closedAll(b);
  b.start();
  b.run(100);
  TEST_ASSERT_EQUAL(Rej::OK, b.arm(ArmMode::AWAY));
  b.run(10100);
  TEST_ASSERT_EQUAL(ArmSt::IDLE, b.intr.st());
  b.intr.takeDirty();
  b.open(1, true);                         // kapi (giris yolu)
  b.run(200);
  TEST_ASSERT_EQUAL(ArmSt::ENTRY, b.intr.st());
  TEST_ASSERT_TRUE(b.intr.takeDirty());     // giris gecikmesi baslangici kalici yazilir
  b.open(1, false);                        // kapi kapandi, enerji kesildi
  b.run(1000);
  ArmRecord r;
  b.intr.record(r);
  TEST_ASSERT_EQUAL_UINT8((uint8_t)ArmMode::AWAY, r.mode);
  TEST_ASSERT_EQUAL_UINT8(ARM_REC_ENTRY, r.alarm);
  TEST_ASSERT_EQUAL_UINT8(1, r.rsv[0]);
  TEST_ASSERT_EQUAL_UINT8(sensorIdCode(b.cfg.sens[0]), (uint8_t)r.aid[0]);
  b.powerCycle();
  TEST_ASSERT_EQUAL(ArmMode::AWAY, b.intr.mode());
  TEST_ASSERT_EQUAL(ArmSt::ENTRY, b.intr.st());
  TEST_ASSERT_EQUAL(BuzPattern::ENTRY, b.intr.buzzer());
  TEST_ASSERT_TRUE(b.intr.untilUp() > 0);
  TEST_ASSERT_EQUAL_STRING("", b.intr.aid());
  b.run(4900);
  TEST_ASSERT_EQUAL(ArmSt::ENTRY, b.intr.st());
  b.run(200);
  TEST_ASSERT_EQUAL(ArmSt::ALARM, b.intr.st());
  TEST_ASSERT_EQUAL(1, b.countOf(EvType::INTRUSION_ALARM));
  TEST_ASSERT_EQUAL_UINT8(1, b.intr.nsrcs());
  TEST_ASSERT_EQUAL_UINT8(sensorIdCode(b.cfg.sens[0]), b.intr.srcs()[0]);
  b.run(100);
  TEST_ASSERT_TRUE(b.relay(6));
}

// RV-E2: acilista geri gelen giris gecikmesinde cozme alarmi onler; cozulunce kayit temizlenir. Bozuk kayit (bilinmeyen alarm degeri) kipi
// geri yukler ama durum uydurmaz.
void test_boot_entry_disarm_and_bad_record(void) {
  Bench b;
  b.std3();
  closedAll(b);
  b.start();
  b.run(100);
  b.arm(ArmMode::AWAY);
  b.run(10100);
  b.open(1, true);
  b.run(200);
  b.open(1, false);
  b.powerCycle();
  TEST_ASSERT_EQUAL(ArmSt::ENTRY, b.intr.st());
  TEST_ASSERT_EQUAL(Rej::OK, b.arm(ArmMode::OFF, VIA_LAN));
  b.run(6000);
  TEST_ASSERT_EQUAL(ArmMode::OFF, b.intr.mode());
  TEST_ASSERT_EQUAL(0, b.countOf(EvType::INTRUSION_ALARM));
  ArmRecord r;
  b.intr.record(r);
  TEST_ASSERT_EQUAL_UINT8(0, r.alarm);
  // bilinmeyen alarm degeri: kip geri gelir, durum bekci (idle)
  Bench c;
  c.std3();
  closedAll(c);
  memset(&c.rec, 0, sizeof(c.rec));
  c.rec.ver = ARM_REC_VER;
  c.rec.mode = (uint8_t)ArmMode::HOME;
  c.rec.alarm = 7;
  c.haveRec = true;
  c.start();
  TEST_ASSERT_EQUAL(ArmMode::HOME, c.intr.mode());
  TEST_ASSERT_EQUAL(ArmSt::IDLE, c.intr.st());
  // giris kaydinda sensor sayisi sinirin uzerinde: en cok 8 kod okunur, cokme yok
  Bench d;
  d.std3();
  closedAll(d);
  memset(&d.rec, 0, sizeof(d.rec));
  d.rec.ver = ARM_REC_VER;
  d.rec.mode = (uint8_t)ArmMode::AWAY;
  d.rec.alarm = ARM_REC_ENTRY;
  d.rec.rsv[0] = 200;
  d.rec.aid[0] = 1;
  d.haveRec = true;
  d.start();
  TEST_ASSERT_EQUAL(ArmSt::ENTRY, d.intr.st());
  d.run(5100);
  TEST_ASSERT_EQUAL(ArmSt::ALARM, d.intr.st());
}

int main(int, char**) {
  UNITY_BEGIN();
  RUN_TEST(test_flags_defaults_and_bits);
  RUN_TEST(test_unconfigured_is_off_and_absent);
  RUN_TEST(test_arm_not_ready_when_instant_open);
  RUN_TEST(test_not_ok_sensor_blocks_arm_and_never_alarms);
  RUN_TEST(test_exit_error_door_open_goes_to_entry);
  RUN_TEST(test_exit_delay_then_idle_and_instant_alarm);
  RUN_TEST(test_instant_during_exit_alarms);
  RUN_TEST(test_entry_delay_disarm_prevents_alarm);
  RUN_TEST(test_entry_timeout_alarms_and_disarm_clears);
  RUN_TEST(test_home_mode_ignores_motion);
  RUN_TEST(test_swinger_limit_three_restarts);
  RUN_TEST(test_millis_rollover);
  RUN_TEST(test_boot_restores_mode_without_exit_delay);
  RUN_TEST(test_boot_restores_alarm_silently);
  RUN_TEST(test_arm_rejections);
  RUN_TEST(test_arm_key_edges);
  RUN_TEST(test_siren_or_hazard_ack_and_disarm_independent);
  RUN_TEST(test_intrusion_budget_separate_from_hazard);
  RUN_TEST(test_view_until_up_and_record);
  RUN_TEST(test_boot_restores_entry_delay);
  RUN_TEST(test_boot_entry_disarm_and_bad_record);
  return UNITY_END();
}
