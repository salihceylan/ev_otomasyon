// SafetyView (src/safety/SafetyView.h) birim testleri: state v:3 ekinin (spec 3.1-3.2, CONTRACTS 2.6) saf uretimi. SAF MANTIK.
// Kapsam: yapilandirilmamis panoda yalniz caps/boot/bn/time_ok/epoch [B14]; modul dizileri yalniz yapilandirilmissa; adsiz sensor/eylemci/bolge
// satirlari [B12]; kilitli bolge (aid, since, since_up, srcs); guvenli kip nedeni; last_rej; role satirina `act`; yayin imzasi alarmda degisir,
// yalniz zamanla degisen alanlarda (since_up, epoch) degismez [B14]; tasmada kesik JSON uretilmez.
#include <unity.h>
#include <stdint.h>
#include <string.h>
#include "safety/SafetyFsm.h"
#include "safety/SafetyView.h"

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

struct Bench {
  SafetyConfig cfg;
  SensorHub hub;
  ActuatorCore act;
  EventOutbox out;
  FakeSource di;
  FakeSource br;
  SafetyCore core;
  uint32_t t;
  Bench() : t(1000) { cfg.setDefaults(); }
  void water() {
    SensorConfig& s = cfg.sens[0];
    memset(&s, 0, sizeof(s));
    s.src = (uint8_t)SensorSrc::DI;
    s.index = 3;
    s.kind = (uint8_t)SensorKind::WATER;
    s.zone = 1;
    s.flags = defaultFlags(s.kind);
    s.confirm_ms = defaultConfirmMs(s.kind);
    memcpy(s.name, "Banyo", 6);
    cfg.nSens = 1;
    ActuatorConfig& v = cfg.act[0];
    memset(&v, 0, sizeof(v));
    v.relay = 5;
    v.kind = (uint8_t)ActKind::VALVE;
    v.close_mode = (uint8_t)CloseMode::DEENERGIZE_TO_CLOSE;
    v.medium = (uint8_t)Medium::WATER;
    v.zone_mask = 0x01;
    v.fb_timeout_s = 60;
    memcpy(v.name, "Ana Vana", 9);
    ActuatorConfig& sr = cfg.act[1];
    memset(&sr, 0, sizeof(sr));
    sr.relay = 6;
    sr.kind = (uint8_t)ActKind::SIREN;
    sr.zone_mask = 0x01;
    sr.run_limit_s = 180;
    cfg.nAct = 2;
    cfg.rev = 3;
  }
  void start(SafeReason mode = SafeReason::NONE) {
    out.begin(0x9f3a11c0u);
    act.configure(cfg.act, cfg.nAct, 0, 0, t);
    hub.configure(cfg.sens, cfg.nSens, t);
    core.begin(&cfg, &hub, &act, &out, nullptr, mode, t);
    step(0);
  }
  void step(uint32_t ms = 10) {
    t += ms;
    core.tick(t, 1791273000u, &di, &br);
  }
  void run(uint32_t ms) { for (uint32_t d = 0; d < ms; d += 10) step(10); }
};

static StateMeta meta(bool timeOk = true) {
  StateMeta m;
  memset(&m, 0, sizeof(m));
  m.boot = 57;
  m.bn = 0x9f3a11c0u;
  m.timeOk = timeOk;
  m.epoch = timeOk ? 1791273600u : 0;
  return m;
}

static const char* render(const SafetyView& v, const StateMeta& m, char* buf, size_t cap) {
  ev_detail::Writer w(buf, cap);
  writeStateExtras(v, m, w);
  return w.ok ? buf : "<TASTI>";
}

static void test_unconfigured_board_only_meta_keys(void) {
  Bench b;
  b.start();
  static SafetyView v;
  buildView(b.cfg, b.hub, b.act, b.core, b.t, v);
  TEST_ASSERT_EQUAL_UINT8(0, v.configured);
  char buf[512];
  TEST_ASSERT_EQUAL_STRING(",\"caps\":[\"safety\",\"actuator\",\"event\",\"cfg\"],\"boot\":57,\"bn\":\"9f3a11c0\",\"time_ok\":false,\"epoch\":0",
                           render(v, meta(false), buf, sizeof(buf)));
  TEST_ASSERT_TRUE(relayActText(v, 5) == nullptr);
}

static void test_configured_normal_rows_without_names(void) {
  Bench b;
  b.water();
  b.start();
  static SafetyView v;
  buildView(b.cfg, b.hub, b.act, b.core, b.t, v);
  TEST_ASSERT_EQUAL_UINT8(1, v.configured);
  TEST_ASSERT_EQUAL_UINT32(3, v.rev);
  TEST_ASSERT_EQUAL_HEX32(configCrc(b.cfg), v.crc);
  char buf[2048];
  const char* s = render(v, meta(), buf, sizeof(buf));
  char crcTxt[80];
  ev_detail::Writer cw(crcTxt, sizeof(crcTxt));
  cw.raw(",\"cfg\":{\"safety\":{\"rev\":3,\"crc\":\"");
  cw.hex8(configCrc(b.cfg));
  cw.raw("\"}}");
  TEST_ASSERT_NOT_NULL(strstr(s, ",\"time_ok\":true,\"epoch\":1791273600"));
  TEST_ASSERT_NOT_NULL(strstr(s, crcTxt));
  TEST_ASSERT_NOT_NULL(strstr(s, ",\"sensors\":[{\"id\":\"d3\",\"src\":\"di\",\"kind\":\"water\",\"zone\":1,\"active\":false,\"ok\":true}]"));
  TEST_ASSERT_NOT_NULL(strstr(s, ",\"actuators\":[{\"id\":\"a1\",\"relay\":5,\"kind\":\"valve\",\"medium\":\"water\",\"zones\":[1],"
                                 "\"pos\":\"unknown\",\"fb\":null,\"fault\":false},"
                                 "{\"id\":\"a2\",\"relay\":6,\"kind\":\"siren\",\"zones\":[1],\"on\":false,\"fault\":false}]"));
  TEST_ASSERT_NOT_NULL(strstr(s, ",\"safety\":{\"policy\":\"on\",\"mode\":\"normal\",\"zones\":[]}"));
  TEST_ASSERT_NULL(strstr(s, "Banyo"));        // adlar state'te yok [B12]
  TEST_ASSERT_NULL(strstr(s, "Ana Vana"));
  TEST_ASSERT_NULL(strstr(s, "last_rej"));
  TEST_ASSERT_EQUAL_STRING("valve", relayActText(v, 5));
  TEST_ASSERT_EQUAL_STRING("siren", relayActText(v, 6));
  TEST_ASSERT_TRUE(relayActText(v, 7) == nullptr);
}

static void test_latched_zone_row_and_signature(void) {
  Bench b;
  b.water();
  b.start();
  static SafetyView v0, v1, v2;
  buildView(b.cfg, b.hub, b.act, b.core, b.t, v0);
  b.di.level[3] = true;
  b.run(1500);
  TEST_ASSERT_EQUAL_UINT8((uint8_t)ZoneSt::LATCHED, (uint8_t)b.core.zoneState(1));
  buildView(b.cfg, b.hub, b.act, b.core, b.t, v1);
  TEST_ASSERT_TRUE(viewSignature(v0) != viewSignature(v1));
  char buf[2048];
  const char* s = render(v1, meta(), buf, sizeof(buf));
  char zone[200];
  ev_detail::Writer zw(zone, sizeof(zone));
  zw.raw("\"zones\":[{\"id\":1,\"st\":\"latched\",\"kind\":\"water\",\"aid\":\"");
  zw.raw(b.core.zone(1).aid);
  zw.raw("\",\"since\":1791273000,\"since_up\":0,\"silenced\":false,\"srcs\":[\"d3\"]}]");
  TEST_ASSERT_NOT_NULL(strstr(s, zone));
  TEST_ASSERT_NOT_NULL(strstr(s, "\"pos\":\"cmd_closed\""));
  TEST_ASSERT_NOT_NULL(strstr(s, "\"active\":true,\"ok\":true"));
  TEST_ASSERT_NOT_NULL(strstr(s, "\"on\":true"));
  // yalniz zaman ilerledi: since_up degisir ama imza degismez
  b.run(5000);
  buildView(b.cfg, b.hub, b.act, b.core, b.t, v2);
  TEST_ASSERT_TRUE(v2.zones[0].sinceUp >= 5);
  TEST_ASSERT_EQUAL_HEX32(viewSignature(v1), viewSignature(v2));
}

static void test_safe_mode_reason_and_last_rej(void) {
  Bench b;
  b.water();
  b.start(SafeReason::CFG_CORRUPT);
  static SafetyView v;
  buildView(b.cfg, b.hub, b.act, b.core, b.t, v);
  StateMeta m = meta();
  strcpy(m.rejId, "c820");
  m.rej = (uint8_t)Rej::SAFE_MODE;
  char buf[2048];
  const char* s = render(v, m, buf, sizeof(buf));
  TEST_ASSERT_NOT_NULL(strstr(s, "\"mode\":\"safe\",\"reason\":\"cfg_corrupt\""));
  TEST_ASSERT_NOT_NULL(strstr(s, ",\"last_rej\":{\"id\":\"c820\",\"code\":\"safe_mode\"}"));
  m.rejId[0] = '\0';
  m.rej = (uint8_t)Rej::BUSY;
  s = render(v, m, buf, sizeof(buf));
  TEST_ASSERT_NOT_NULL(strstr(s, ",\"last_rej\":{\"code\":\"busy\"}"));
}

static void test_overflow_never_emits_partial_json(void) {
  Bench b;
  b.water();
  b.start();
  static SafetyView v;
  buildView(b.cfg, b.hub, b.act, b.core, b.t, v);
  char small[64];
  ev_detail::Writer w(small, sizeof(small));
  writeStateExtras(v, meta(), w);
  TEST_ASSERT_FALSE(w.ok);
}

static void test_control_role_rows(void) {
  Bench b;
  b.water();
  SensorConfig& c = b.cfg.sens[1];
  memset(&c, 0, sizeof(c));
  c.src = (uint8_t)SensorSrc::DI;
  c.index = 4;
  c.kind = (uint8_t)SensorKind::ALARM_ACK;
  c.zone = 0;
  b.cfg.nSens = 2;
  b.start();
  b.di.level[4] = true;
  b.run(100);
  static SafetyView v;
  buildView(b.cfg, b.hub, b.act, b.core, b.t, v);
  char buf[2048];
  const char* s = render(v, meta(), buf, sizeof(buf));
  TEST_ASSERT_NOT_NULL(strstr(s, "{\"id\":\"d4\",\"src\":\"di\",\"kind\":\"alarm_ack\",\"zone\":0,\"active\":true,\"ok\":true}"));
}

int main(int, char**) {
  UNITY_BEGIN();
  RUN_TEST(test_unconfigured_board_only_meta_keys);
  RUN_TEST(test_configured_normal_rows_without_names);
  RUN_TEST(test_latched_zone_row_and_signature);
  RUN_TEST(test_safe_mode_reason_and_last_rej);
  RUN_TEST(test_overflow_never_emits_partial_json);
  RUN_TEST(test_control_role_rows);
  return UNITY_END();
}
