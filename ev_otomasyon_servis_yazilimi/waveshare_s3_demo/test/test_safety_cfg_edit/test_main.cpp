// SafetyCfgEdit (src/safety/SafetyCfgEdit.h) + SafetyCfgJson (src/safety/SafetyCfgJson.h) birim testleri. SAF MANTIK.
// Kapsam (spec 4.1-4.2, karar 7.2b-7, WP-F4/F5): tek ogeli yama (sensor/eylemci ekle-degistir-sil, politika, bolge adi, isik secenegi), silinen
// eylemciden sonraki konum bitlerinin kaydirilmasi, yeni eylemcide anlik role seviyesinin benimsenmesi (yapilandirma vanayi kendiliginden
// ACMAZ), LAN'dan gevsetme yasagi (isLoosening: politika kapatma, silme, tur/akiskan/kip/bolge daraltma, NC->NO, onay suresi uzatma...),
// yapilandirma JSON'u (kacis), cfg_dump parcalari (<= 3,5 KB; her oge tam olarak bir kez).
#include <unity.h>
#include <stdint.h>
#include <string.h>
#include "SystemConfig.h"
#include "safety/SafetyConfig.h"
#include "safety/SafetyCfgEdit.h"
#include "safety/SafetyCfgJson.h"

using namespace safety;

void setUp(void) {}
void tearDown(void) {}

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

static ActuatorConfig valve(uint8_t relay, Medium m, CloseMode mode = CloseMode::DEENERGIZE_TO_CLOSE, uint8_t zones = 0x01) {
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
  c.sens[0] = sensor(3, SensorKind::WATER, 1);
  c.nSens = 1;
  c.act[0] = valve(5, Medium::WATER);
  c.act[1] = siren(6);
  c.act[2] = valve(7, Medium::WATER, CloseMode::ENERGIZE_TO_CLOSE);
  c.nAct = 3;
  c.rev = 4;
  return c;
}

static CfgEdit edit(EditOp op) {
  CfgEdit e;
  editInit(e);
  e.op = op;
  return e;
}

static void test_set_sensor_add_and_replace(void) {
  const SafetyConfig c = base();
  static SafetyConfig o;
  int8_t rm = 0;
  CfgEdit e = edit(EditOp::SET_SENSOR);
  e.sens = sensor(4, SensorKind::GAS, 1, 1);
  TEST_ASSERT_EQUAL_UINT8((uint8_t)CfgErr::OK, (uint8_t)applyEdit(c, e, o, rm));
  TEST_ASSERT_EQUAL_UINT8(2, o.nSens);
  TEST_ASSERT_EQUAL_UINT8(4, o.sens[1].index);
  TEST_ASSERT_EQUAL(-1, rm);
  e.sens = sensor(3, SensorKind::WATER, 2);                   // ayni (kaynak, no): yerinde degistirilir
  TEST_ASSERT_EQUAL_UINT8((uint8_t)CfgErr::OK, (uint8_t)applyEdit(c, e, o, rm));
  TEST_ASSERT_EQUAL_UINT8(1, o.nSens);
  TEST_ASSERT_EQUAL_UINT8(2, o.sens[0].zone);
  TEST_ASSERT_EQUAL_UINT32(4, o.rev);                          // rev'i yonetici artirir
}

static void test_del_sensor_and_actuator_shift(void) {
  const SafetyConfig c = base();
  static SafetyConfig o;
  int8_t rm = 0;
  CfgEdit e = edit(EditOp::DEL_ACTUATOR);
  e.actIndex = 1;
  TEST_ASSERT_EQUAL_UINT8((uint8_t)CfgErr::OK, (uint8_t)applyEdit(c, e, o, rm));
  TEST_ASSERT_EQUAL(1, rm);
  TEST_ASSERT_EQUAL_UINT8(2, o.nAct);
  TEST_ASSERT_EQUAL_UINT8(7, o.act[1].relay);
  e.actIndex = 3;
  TEST_ASSERT_EQUAL_UINT8((uint8_t)CfgErr::NOT_FOUND, (uint8_t)applyEdit(c, e, o, rm));
  e = edit(EditOp::DEL_SENSOR);
  e.sens.src = (uint8_t)SensorSrc::DI;
  e.sens.index = 3;
  TEST_ASSERT_EQUAL_UINT8((uint8_t)CfgErr::OK, (uint8_t)applyEdit(c, e, o, rm));
  TEST_ASSERT_EQUAL_UINT8(0, o.nSens);
  e.sens.index = 9;
  TEST_ASSERT_EQUAL_UINT8((uint8_t)CfgErr::NOT_FOUND, (uint8_t)applyEdit(c, e, o, rm));
  TEST_ASSERT_EQUAL_HEX16(0x0003, removeBit16(0x0005, 1));     // a1,a3 -> a1,a2
  TEST_ASSERT_EQUAL_HEX16(0x0001, removeBit16(0x0003, 1));
}

static void test_set_actuator_new_replace_full(void) {
  const SafetyConfig c = base();
  static SafetyConfig o;
  int8_t rm = 0;
  CfgEdit e = edit(EditOp::SET_ACTUATOR);
  e.act = siren(8);
  e.actIndex = 0xFF;
  TEST_ASSERT_EQUAL_UINT8((uint8_t)CfgErr::OK, (uint8_t)applyEdit(c, e, o, rm));
  TEST_ASSERT_EQUAL_UINT8(4, o.nAct);
  e.actIndex = 0;
  e.act = valve(5, Medium::GAS);
  TEST_ASSERT_EQUAL_UINT8((uint8_t)CfgErr::OK, (uint8_t)applyEdit(c, e, o, rm));
  TEST_ASSERT_EQUAL_UINT8((uint8_t)Medium::GAS, o.act[0].medium);
  e.actIndex = 5;
  TEST_ASSERT_EQUAL_UINT8((uint8_t)CfgErr::NOT_FOUND, (uint8_t)applyEdit(c, e, o, rm));
  static SafetyConfig full;
  full = c;
  full.nAct = MAX_ACTUATORS;
  e.actIndex = 0xFF;
  TEST_ASSERT_EQUAL_UINT8((uint8_t)CfgErr::FULL, (uint8_t)applyEdit(full, e, o, rm));
}

static void test_policy_zone_light(void) {
  const SafetyConfig c = base();
  static SafetyConfig o;
  int8_t rm = 0;
  CfgEdit e = edit(EditOp::SET_POLICY);
  e.hasPolicyOn = 1;
  e.policyOn = 0;
  TEST_ASSERT_EQUAL_UINT8((uint8_t)CfgErr::OK, (uint8_t)applyEdit(c, e, o, rm));
  TEST_ASSERT_EQUAL_UINT8(0, o.pol.policy_on);
  TEST_ASSERT_EQUAL_UINT32(DRY_HOLD_DEFAULT_MS, o.pol.dry_hold_ms);
  e = edit(EditOp::SET_ZONE);
  e.zoneId = 2;
  strcpy(e.zoneName, "Mutfak");
  TEST_ASSERT_EQUAL_UINT8((uint8_t)CfgErr::OK, (uint8_t)applyEdit(c, e, o, rm));
  TEST_ASSERT_EQUAL_STRING("Mutfak", o.zones[1].name);
  e.zoneId = 5;
  TEST_ASSERT_EQUAL_UINT8((uint8_t)CfgErr::BAD_EDIT, (uint8_t)applyEdit(c, e, o, rm));
  e = edit(EditOp::SET_LIGHT);
  e.lightRelay = 2;
  e.light.dimmable = 1;
  e.light.dimmer_src = 1;
  e.light.dimmer_addr = 2;
  e.light.dimmer_ch = 3;
  TEST_ASSERT_EQUAL_UINT8((uint8_t)CfgErr::OK, (uint8_t)applyEdit(c, e, o, rm));
  TEST_ASSERT_EQUAL_UINT8(3, o.light[1].dimmer_ch);
}

static void test_loosening_rules(void) {
  const SafetyConfig a = base();
  static SafetyConfig b;
  b = a;
  TEST_ASSERT_FALSE(isLoosening(a, b));
  // ekleme sikilastirmadir
  b.sens[1] = sensor(4, SensorKind::WATER, 1);
  b.nSens = 2;
  b.act[3] = siren(8);
  b.nAct = 4;
  TEST_ASSERT_FALSE(isLoosening(a, b));
  b = a; b.pol.policy_on = 0;                                    TEST_ASSERT_TRUE(isLoosening(a, b));
  b = a; b.pol.dry_hold_ms = 5000;                               TEST_ASSERT_TRUE(isLoosening(a, b));
  b = a; b.pol.dry_hold_ms = 20000;                              TEST_ASSERT_FALSE(isLoosening(a, b));
  b = a; b.nSens = 0;                                            TEST_ASSERT_TRUE(isLoosening(a, b));
  b = a; b.sens[0].kind = (uint8_t)SensorKind::DOOR;             TEST_ASSERT_TRUE(isLoosening(a, b));
  b = a; b.sens[0].zone = 2;                                     TEST_ASSERT_TRUE(isLoosening(a, b));
  b = a; b.sens[0].flags = 0;                                    TEST_ASSERT_TRUE(isLoosening(a, b));
  b = a; b.sens[0].confirm_ms = 2000;                            TEST_ASSERT_TRUE(isLoosening(a, b));
  b = a; b.sens[0].confirm_ms = 500;                             TEST_ASSERT_FALSE(isLoosening(a, b));
  b = a; b.sens[0].active_open = 1;                              TEST_ASSERT_FALSE(isLoosening(a, b));   // NO -> NC sikilastirma
  b = a; strcpy(b.sens[0].name, "yeni ad");                      TEST_ASSERT_FALSE(isLoosening(a, b));
  b = a; b.nAct = 2;                                             TEST_ASSERT_TRUE(isLoosening(a, b));    // silme
  b = a; b.act[0].medium = (uint8_t)Medium::GAS;                 TEST_ASSERT_TRUE(isLoosening(a, b));
  b = a; b.act[0].close_mode = (uint8_t)CloseMode::ENERGIZE_TO_CLOSE; TEST_ASSERT_TRUE(isLoosening(a, b));
  b = a; b.act[0].relay = 8;                                     TEST_ASSERT_TRUE(isLoosening(a, b));
  b = a; b.act[0].zone_mask = 0x03;                              TEST_ASSERT_FALSE(isLoosening(a, b));   // bolge eklemek
  b = a; b.act[2].zone_mask = 0x02;                              TEST_ASSERT_TRUE(isLoosening(a, b));    // bolge 1 cikti
  b = a; b.act[1].run_limit_s = 60;                              TEST_ASSERT_TRUE(isLoosening(a, b));
  b = a; b.act[1].kind = (uint8_t)ActKind::GENERIC;              TEST_ASSERT_TRUE(isLoosening(a, b));
  b = a; b.act[0].fb_di = 4;                                     TEST_ASSERT_FALSE(isLoosening(a, b));   // geri bildirim eklemek
  static SafetyConfig f;
  f = a; f.act[0].fb_di = 4;
  b = f; b.act[0].fb_di = 0;                                     TEST_ASSERT_TRUE(isLoosening(f, b));    // geri bildirim kaldirmak
  b = a; b.act[0].aflags = AF_FAN_EXPROOF;                       TEST_ASSERT_TRUE(isLoosening(a, b));
  b = a; strcpy(b.zones[0].name, "Daire");                       TEST_ASSERT_FALSE(isLoosening(a, b));
  // kontrol rolu silmek gevsetme degildir
  f = a;
  f.sens[1] = sensor(8, SensorKind::ALARM_ACK, 0);
  f.nSens = 2;
  b = a;
  TEST_ASSERT_FALSE(isLoosening(f, b));
}

// Inceleme turu (entegrasyon) EM-6/EM-7: LAN'dan yeni ex-proof fan satiri ve mevcut DI satirini GAS_RESET'e cevirmek GEVSETMEDIR.
static void test_loosening_review_rules(void) {
  const SafetyConfig a = base();
  static SafetyConfig b, f;
  ActuatorConfig fan;
  memset(&fan, 0, sizeof(fan));
  fan.relay = 9;
  fan.kind = (uint8_t)ActKind::FAN;
  fan.zone_mask = 0x01;
  b = a; b.act[b.nAct] = fan; b.nAct++;                          TEST_ASSERT_FALSE(isLoosening(a, b));   // siradan fan eklemek
  b = a; b.act[b.nAct] = fan; b.act[b.nAct].aflags = AF_FAN_EXPROOF; b.nAct++;
  TEST_ASSERT_TRUE(isLoosening(a, b));                                                                   // yeni ex-proof fan [EM-7]
  f = a; f.sens[1] = sensor(9, SensorKind::DOOR, 1); f.nSens = 2;
  b = f; b.sens[1].kind = (uint8_t)SensorKind::GAS_RESET;        TEST_ASSERT_TRUE(isLoosening(f, b));    // kapi kontagi -> GAS_RESET [EM-6]
  f = a; f.sens[1] = sensor(9, SensorKind::VALVE_CLOSE, 1); f.nSens = 2;
  b = f; b.sens[1].kind = (uint8_t)SensorKind::GAS_RESET;        TEST_ASSERT_TRUE(isLoosening(f, b));
  f = a; f.sens[1] = sensor(9, SensorKind::GAS_RESET, 1); f.nSens = 2;
  b = f; b.sens[1].zone = 0;                                     TEST_ASSERT_TRUE(isLoosening(f, b));    // GAS_RESET kapsamini degistirmek
  b = a; b.sens[1] = sensor(9, SensorKind::GAS_RESET, 1); b.nSens = 2;
  TEST_ASSERT_FALSE(isLoosening(a, b));                                                                  // bos DI'ye yeni GAS_RESET (sihirbaz)
}

// Inceleme turu 2 FW2-2: iki adimli yol. (1) kapi kontagi satirini silmek tek basina gevsetme degildir; (2) ayni DI'ye YENI GAS_RESET
// eklemek, o DI daha once herhangi bir satirda kullanildiysa (kalici DI kullanim gecmisi, diUseMask) gevsetmedir. GAS_RESET'in bolgesini
// sil + yeniden ekle ile degistirmek de ayni kurala takilir. Hic kullanilmamis DI'ye yeni GAS_RESET (sihirbaz) serbest kalir.
static void test_loosening_gas_reset_on_used_di(void) {
  const SafetyConfig a = base();
  static SafetyConfig f, b, c;
  f = a; f.sens[1] = sensor(9, SensorKind::DOOR, 1); f.nSens = 2;
  const uint64_t hist = diUseMask(f);
  TEST_ASSERT_TRUE((hist & (1ULL << 8)) != 0);                   // DI9
  TEST_ASSERT_TRUE((hist & (1ULL << 2)) != 0);                   // DI3 (su sensoru)
  b = f; b.nSens = 1; memset(&b.sens[1], 0, sizeof(SensorConfig));
  TEST_ASSERT_FALSE(isLoosening(f, b, hist));                    // adim 1: kapi satirini silmek
  c = b; c.sens[1] = sensor(9, SensorKind::GAS_RESET, 1); c.nSens = 2;
  TEST_ASSERT_TRUE(isLoosening(b, c, hist));                     // adim 2: ayni DI'ye yeni GAS_RESET
  TEST_ASSERT_FALSE(isLoosening(b, c, 0));                       // gecmis yoksa (hic kullanilmamis DI) serbest
  c = b; c.sens[1] = sensor(10, SensorKind::GAS_RESET, 1); c.nSens = 2;
  TEST_ASSERT_FALSE(isLoosening(b, c, hist));                    // baska, kullanilmamis DI serbest
  c = b; c.sens[1] = sensor(9, SensorKind::DOOR, 1); c.nSens = 2;
  TEST_ASSERT_FALSE(isLoosening(b, c, hist));                    // kullanilmis DI'ye GAS_RESET disi satir serbest
  // GAS_RESET bolgesi: sil + farkli bolgeyle yeniden ekle
  f = a; f.sens[1] = sensor(9, SensorKind::GAS_RESET, 1); f.nSens = 2;
  const uint64_t h2 = diUseMask(f);
  b = f; b.nSens = 1; memset(&b.sens[1], 0, sizeof(SensorConfig));
  TEST_ASSERT_FALSE(isLoosening(f, b, h2));                      // GAS_RESET silmek sikilastirmadir
  c = b; c.sens[1] = sensor(9, SensorKind::GAS_RESET, 0); c.nSens = 2;
  TEST_ASSERT_TRUE(isLoosening(b, c, h2));
  // geri bildirim girisi de gecmise girer; koprulu sensor DI gecmisine girmez
  f = a; f.act[0].fb_di = 11;
  f.sens[1] = sensor(4, SensorKind::WATER, 1); f.sens[1].src = (uint8_t)SensorSrc::BRIDGE; f.nSens = 2;
  const uint64_t h3 = diUseMask(f);
  TEST_ASSERT_TRUE((h3 & (1ULL << 10)) != 0);
  TEST_ASSERT_TRUE((h3 & (1ULL << 3)) == 0);
}

// Calisirken yama: eylemci kimligi (role(ler), tur, kip, akiskan) eski tablodaki indekse eslenir; yeni/degisen satir -1.
static void test_actuator_identity_map(void) {
  const SafetyConfig oldC = base();                               // a1 D2C su (5), a2 siren (6), a3 E2C su (7)
  static SafetyConfig n;
  n = oldC;
  n.act[0] = oldC.act[2];
  n.act[1] = oldC.act[0];
  n.act[1].zone_mask = 0x03;                                      // bolge eklemek kimligi bozmaz
  n.act[2] = valve(8, Medium::WATER);
  n.nAct = 3;
  int8_t map[MAX_ACTUATORS];
  actuatorIdentityMap(oldC, n, map);
  TEST_ASSERT_EQUAL_INT(2, map[0]);
  TEST_ASSERT_EQUAL_INT(0, map[1]);
  TEST_ASSERT_EQUAL_INT(-1, map[2]);
  for (uint8_t i = 3; i < MAX_ACTUATORS; i++) TEST_ASSERT_EQUAL_INT(-1, map[i]);
  n = oldC;
  n.act[0].medium = (uint8_t)Medium::GAS;                         // akiskan degisti: yeni eylemci
  actuatorIdentityMap(oldC, n, map);
  TEST_ASSERT_EQUAL_INT(-1, map[0]);
  TEST_ASSERT_EQUAL_INT(1, map[1]);
}

static void test_act_pos_remap_and_adopt(void) {
  const SafetyConfig oldC = base();                               // a1 D2C su (5), a2 siren (6), a3 E2C su (7)
  static SafetyConfig n;
  n = oldC;
  // a2 silindi, yeni a3 = D2C su vana role 8 (eklendi)
  n.act[1] = oldC.act[2];
  n.act[2] = valve(8, Medium::WATER);
  n.nAct = 3;
  uint16_t open = 0, known = 0;
  // eski: a1 bilinen/acik, a3 bilinen/kapali. Anlik roleler: 8 enerjili (D2C: acik)
  const uint64_t levels = 1ULL << 7;
  remapActPos(oldC, 0x0001, 0x0005, n, levels, open, known);
  TEST_ASSERT_EQUAL_HEX16(0x0007, known);
  TEST_ASSERT_EQUAL_HEX16(0x0005, open);                         // a1 acik, a2 (eski a3) kapali, a3 yeni: role enerjili -> acik (benimsendi)
  remapActPos(oldC, 0x0001, 0x0005, n, 0, open, known);
  TEST_ASSERT_EQUAL_HEX16(0x0001, open);                         // role enerjisiz: D2C yeni vana kapali benimsenir
}

static bool contains(const char* s, const char* sub) { return strstr(s, sub) != nullptr; }

static void test_config_json_escapes_and_fields(void) {
  static SafetyConfig c;
  c = base();
  strcpy(c.sens[0].name, "Banyo \"zemin\"\\");
  strcpy(c.act[0].name, "Ana Vana");
  static char buf[6000];
  ev_detail::Writer w(buf, sizeof(buf));
  writeConfigJson(c, w);
  TEST_ASSERT_TRUE(w.ok);
  TEST_ASSERT_TRUE(contains(buf, "\"rev\":4"));
  TEST_ASSERT_TRUE(contains(buf, "\"policy\":{\"on\":true,\"dry_hold_ms\":10000}"));
  TEST_ASSERT_TRUE(contains(buf, "{\"id\":1,\"name\":\"Ev\"}"));
  TEST_ASSERT_TRUE(contains(buf, "{\"id\":\"d3\",\"kind\":\"water\",\"zone\":1,\"active_open\":0,\"flags\":1,\"confirm_ms\":1000,\"name\":\"Banyo \\\"zemin\\\"\\\\\"}"));
  TEST_ASSERT_TRUE(contains(buf, "{\"id\":\"a1\",\"relay\":5,\"kind\":\"valve\",\"close_mode\":\"deenergize\",\"medium\":\"water\",\"zones\":[1],"
                                 "\"fb_di\":0,\"fb_closed_active\":1,\"fb_timeout_s\":60,\"run_limit_s\":0,\"exproof\":false,\"name\":\"Ana Vana\"}"));
  TEST_ASSERT_TRUE(contains(buf, "\"lights\":[]"));
  char crcTxt[40];
  ev_detail::Writer cw(crcTxt, sizeof(crcTxt));
  cw.raw("\"crc\":\"");
  cw.hex8(configCrc(c));
  TEST_ASSERT_TRUE(contains(buf, crcTxt));
  // kontrol karakteri \u00XX ile kacirilir
  c.act[1].name[0] = 0x01;
  c.act[1].name[1] = '\0';
  ev_detail::Writer w2(buf, sizeof(buf));
  writeConfigJson(c, w2);
  TEST_ASSERT_TRUE(contains(buf, "\"name\":\"\\u0001\""));
}

static void test_dump_parts_cover_all_items_within_cap(void) {
  static SafetyConfig c;
  c.setDefaults();
  for (uint8_t i = 0; i < MAX_SENSORS; i++) {
    c.sens[i] = sensor((uint8_t)(i % 40 + 1), SensorKind::WATER, 1);
    c.sens[i].src = (i < 40) ? (uint8_t)SensorSrc::DI : (uint8_t)SensorSrc::BRIDGE;
    if (i >= 40) c.sens[i].index = (uint8_t)(i - 39);
    memset(c.sens[i].name, 'x', NAME_LEN - 1);
    c.sens[i].name[NAME_LEN - 1] = '\0';
  }
  c.nSens = MAX_SENSORS;
  for (uint8_t i = 0; i < MAX_ACTUATORS; i++) {
    c.act[i] = valve((uint8_t)(i + 1), Medium::WATER);
    memset(c.act[i].name, 'y', NAME_LEN - 1);
    c.act[i].name[NAME_LEN - 1] = '\0';
  }
  c.nAct = MAX_ACTUATORS;
  for (uint8_t r = 0; r < MAX_RELAYS; r++) c.light[r].dimmable = 1;
  DumpPart parts[DUMP_MAX_PARTS];
  static char scratch[DUMP_PART_CAP + 1];
  const uint8_t n = planDump(c, DUMP_PART_CAP, parts, DUMP_MAX_PARTS, scratch, sizeof(scratch));
  TEST_ASSERT_TRUE(n >= 3);
  uint8_t sensSeen = 0, actSeen = 0;
  static char buf[DUMP_PART_CAP + 1];
  for (uint8_t k = 0; k < n; k++) {
    const size_t len = writeDumpPart(c, parts[k], k + 1, n, "AHBU-S3-0A0010", buf, sizeof(buf));
    TEST_ASSERT_TRUE(len > 0);
    TEST_ASSERT_LESS_OR_EQUAL(DUMP_PART_CAP, len);
    TEST_ASSERT_TRUE(contains(buf, "\"type\":\"cfg_dump\""));
    TEST_ASSERT_TRUE(contains(buf, "\"module\":\"safety\""));
    TEST_ASSERT_EQUAL_UINT8(k == 0 ? 1 : 0, contains(buf, "\"policy\":") ? 1 : 0);
    sensSeen = (uint8_t)(sensSeen + (parts[k].s1 - parts[k].s0));
    actSeen = (uint8_t)(actSeen + (parts[k].a1 - parts[k].a0));
  }
  TEST_ASSERT_EQUAL_UINT8(MAX_SENSORS, sensSeen);
  TEST_ASSERT_EQUAL_UINT8(MAX_ACTUATORS, actSeen);
  // bos yapilandirma tek parca
  static SafetyConfig e;
  e.setDefaults();
  TEST_ASSERT_EQUAL_UINT8(1, planDump(e, DUMP_PART_CAP, parts, DUMP_MAX_PARTS, scratch, sizeof(scratch)));
}

// Faz 2 (F2.B.3/B.7): hirsiz ayarlari. Gecikmeler Policy'de (exit_s/entry_s; 0 = varsayilan), yama "set.intrusion"; kapi/pencere/hareket
// ayarlari LAN'dan serbest; ARM_KEY icin DI gecmisi kurali (kullanilmis DI'ye yeni arm_key ya da mevcut satiri arm_key'e cevirmek gevsetme).
static void test_intrusion_edit_and_loosening(void) {
  const SafetyConfig c = base();
  static SafetyConfig o;
  int8_t rm = 0;
  CfgEdit e = edit(EditOp::SET_INTRUSION);
  TEST_ASSERT_EQUAL(CfgErr::BAD_EDIT, applyEdit(c, e, o, rm));     // en az bir alan
  e.hasExit = 1;
  e.exitS = 60;
  TEST_ASSERT_EQUAL(CfgErr::OK, applyEdit(c, e, o, rm));
  TEST_ASSERT_EQUAL_UINT8(60, o.pol.exit_s);
  TEST_ASSERT_EQUAL_UINT8(0, o.pol.entry_s);
  TEST_ASSERT_FALSE(isLoosening(c, o));                              // gecikme degisimi LAN'dan serbest
  e.hasEntry = 1;
  e.entryS = 1;
  TEST_ASSERT_EQUAL(CfgErr::OK, applyEdit(c, e, o, rm));
  TEST_ASSERT_EQUAL_UINT8(1, o.pol.entry_s);
  TEST_ASSERT_FALSE(isLoosening(c, o));
  TEST_ASSERT_TRUE(configCrc(c) != configCrc(o));                     // gecikmeler CRC'ye girer (Policy blob'u)
  // kapi sensoru ekleme/silme/bayrak degisimi serbest
  SafetyConfig a = c;
  a.sens[1] = sensor(9, SensorKind::DOOR, 1, 1);
  a.nSens = 2;
  SafetyConfig b = a;
  b.sens[1].flags = SF_REACT;                                        // giris yolu kaldirildi
  TEST_ASSERT_FALSE(isLoosening(a, b));
  b.nSens = 1;                                                       // kapi silindi
  TEST_ASSERT_FALSE(isLoosening(a, b));
  // ARM_KEY: hic kullanilmamis girise yeni satir serbest
  SafetyConfig k = c;
  k.sens[1] = sensor(12, SensorKind::ARM_KEY, 0);
  k.nSens = 2;
  TEST_ASSERT_FALSE(isLoosening(c, k, 0));
  // ... DI gecmisinde olan girise yeni arm_key gevsetme (kapi kontagini silip ayni girise anahtar eklemek)
  TEST_ASSERT_TRUE(isLoosening(c, k, 1ULL << 11));
  // mevcut kapi satirini arm_key'e cevirmek gevsetme
  SafetyConfig d = a;
  SafetyConfig d2 = a;
  d2.sens[1] = sensor(9, SensorKind::ARM_KEY, 0);
  TEST_ASSERT_TRUE(isLoosening(d, d2, 0));
  // mevcut arm_key satiri aynen kalirsa gevsetme yok; silinmesi gevsetme degil
  TEST_ASSERT_FALSE(isLoosening(k, k, 1ULL << 11));
  TEST_ASSERT_FALSE(isLoosening(k, c, 1ULL << 11));
  // diUseMask arm_key girisini de kapsar
  TEST_ASSERT_TRUE((diUseMask(k) & (1ULL << 11)) != 0);
}

static void test_intrusion_json_fields(void) {
  static SafetyConfig c;
  c = base();
  c.pol.exit_s = 60;
  c.sens[1] = sensor(9, SensorKind::DOOR, 1, 1);
  c.sens[2] = sensor(10, SensorKind::ARM_KEY, 0);
  c.nSens = 3;
  static char buf[6000];
  ev_detail::Writer w(buf, sizeof(buf));
  writeConfigJson(c, w);
  TEST_ASSERT_TRUE(w.ok);
  TEST_ASSERT_TRUE(contains(buf, "\"policy\":{\"on\":true,\"dry_hold_ms\":10000},\"intrusion\":{\"exit_s\":60,\"entry_s\":0},\"zones\":["));
  TEST_ASSERT_TRUE(contains(buf, "{\"id\":\"d9\",\"kind\":\"door\",\"zone\":1,\"active_open\":1,\"flags\":9,"));
  TEST_ASSERT_TRUE(contains(buf, "{\"id\":\"d10\",\"kind\":\"arm_key\",\"zone\":0,"));
  // cfg_dump: hirsiz ayarlari 1. parcada (policy ile)
  DumpPart parts[DUMP_MAX_PARTS];
  static char scratch[DUMP_PART_CAP + 1];
  const uint8_t n = planDump(c, DUMP_PART_CAP, parts, DUMP_MAX_PARTS, scratch, sizeof(scratch));
  TEST_ASSERT_EQUAL_UINT8(1, n);
  static char part[DUMP_PART_CAP + 1];
  TEST_ASSERT_TRUE(writeDumpPart(c, parts[0], 1, 1, "U", part, sizeof(part)) > 0);
  TEST_ASSERT_TRUE(contains(part, "\"intrusion\":{\"exit_s\":60,\"entry_s\":0}"));
}

// Faz 2 incelemesi G-1a (RV-E1): gaz vanasi hicbir uzak yoldan acilamaz (karar 7.2b-8). Bulut yamasi (owner/servis gevsetebilir) yine de
// mevcut gaz vanasinin kimligini (role, tur, kip, akiskan) degistiremez ya da onu silemez: vana "gaz" olmaktan cikinca uzaktan acilabilirdi.
// GAS_RESET'i kapi kontagina cevirmek (EM-6) ve DI gecmisindeki girise yeni GAS_RESET de ayni siniftir. Bolge/geri bildirim degisimi vanayi
// ACMAZ (gevsetmedir ama bu sinifa girmez). Su vanasini gaza cevirmek sikilastirmadir.
static void test_gas_release_rules(void) {
  static SafetyConfig a;
  a = base();
  a.act[3] = valve(9, Medium::GAS, CloseMode::ENERGIZE_TO_CLOSE, 0x02);
  a.nAct = 4;
  a.sens[1] = sensor(4, SensorKind::GAS, 2, 1);
  a.sens[2] = sensor(8, SensorKind::GAS_RESET, 2);
  a.sens[3] = sensor(10, SensorKind::DOOR, 1, 1);
  a.nSens = 4;
  static SafetyConfig b;
  b = a;
  TEST_ASSERT_FALSE(isGasRelease(a, b));
  b.act[3].medium = (uint8_t)Medium::WATER;                          // gaz -> su: uzaktan acilabilir olurdu
  TEST_ASSERT_TRUE(isGasRelease(a, b));
  b = a;
  b.nAct = 3;                                                       // gaz vanasi silindi: role duz role olur
  memset(&b.act[3], 0, sizeof(ActuatorConfig));
  TEST_ASSERT_TRUE(isGasRelease(a, b));
  b = a;
  b.act[3].relay = 11;                                              // role degisti: eski role serbest kalir
  TEST_ASSERT_TRUE(isGasRelease(a, b));
  b = a;
  b.act[3].close_mode = (uint8_t)CloseMode::DEENERGIZE_TO_CLOSE;     // kip ters: "kapali" komutu acar
  TEST_ASSERT_TRUE(isGasRelease(a, b));
  b = a;
  b.act[3].kind = (uint8_t)ActKind::GENERIC;
  TEST_ASSERT_TRUE(isGasRelease(a, b));
  b = a;                                                            // onundeki eylemci silinip gaz vanasi kaydi: kimlik ayni, bu sinif degil
  for (uint8_t j = 0; j + 1 < b.nAct; j++) b.act[j] = b.act[j + 1];
  b.nAct--;
  TEST_ASSERT_FALSE(isGasRelease(a, b));
  b = a;
  b.act[3].zone_mask = 0x01;                                        // bolge degisimi vanayi acmaz (gevsetme ama bu sinif degil)
  TEST_ASSERT_FALSE(isGasRelease(a, b));
  TEST_ASSERT_TRUE(isLoosening(a, b));
  b = a;
  b.act[0].medium = (uint8_t)Medium::GAS;                           // su vanasini gaza cevirmek sikilastirma
  TEST_ASSERT_FALSE(isGasRelease(a, b));
  b = a;
  b.sens[3].kind = (uint8_t)SensorKind::GAS_RESET;                  // kapi kontagi gaz acma dugmesi olur (EM-6)
  b.sens[3].zone = 2;
  TEST_ASSERT_TRUE(isGasRelease(a, b));
  b = a;
  b.sens[2].zone = 1;                                               // gas_reset baska bolgeyi acar
  TEST_ASSERT_TRUE(isGasRelease(a, b));
  b = a;
  b.sens[4] = sensor(20, SensorKind::GAS_RESET, 2);                  // hic kullanilmamis girise yeni gaz acma dugmesi (sihirbaz): serbest
  b.nSens = 5;
  TEST_ASSERT_FALSE(isGasRelease(a, b, 0));
  TEST_ASSERT_TRUE(isGasRelease(a, b, 1ULL << 19));                  // DI gecmisinde: kapi kontagi sil + ekle iki adimi
  b = a;                                                            // gaz sensoru silmek vanayi ACMAZ (gevsetme ama bu sinif degil)
  b.sens[1] = b.sens[3];
  b.nSens = 3;
  TEST_ASSERT_FALSE(isGasRelease(a, b));
}

// Faz 2 incelemesi G-1b (R1): hirsiz alarmini zayiflatan degisiklik (kurulu kipte buluttan reddedilir; LAN'da B.3 geregi serbest kalir).
static void test_intrusion_loosening_rules(void) {
  static SafetyConfig a;
  a = base();
  a.sens[1] = sensor(9, SensorKind::DOOR, 1, 1);                     // giris yolu (SF_REACT|SF_ENTRY)
  a.sens[2] = sensor(10, SensorKind::WINDOW, 1, 1);                  // anlik
  a.sens[3] = sensor(11, SensorKind::MOTION, 2, 0);                  // yalniz disarida
  a.nSens = 4;
  a.pol.exit_s = 30;
  a.pol.entry_s = 20;
  static SafetyConfig b;
  b = a;
  TEST_ASSERT_FALSE(isIntrusionLoosening(a, b));
  b.sens[2].flags = 0;                                              // SF_REACT kaldirildi: sensor alarma katilmaz
  TEST_ASSERT_TRUE(isIntrusionLoosening(a, b));
  TEST_ASSERT_FALSE(isLoosening(a, b));                              // LAN tanimi degismez (B.3)
  b = a;
  b.sens[2] = b.sens[3];                                            // pencere silindi
  b.nSens = 3;
  TEST_ASSERT_TRUE(isIntrusionLoosening(a, b));
  b = a;
  b.sens[2].flags |= SF_AWAY_ONLY;                                  // evde kipinde devre disi
  TEST_ASSERT_TRUE(isIntrusionLoosening(a, b));
  b = a;
  b.sens[2].flags |= SF_ENTRY;                                      // anlik -> gecikmeli
  TEST_ASSERT_TRUE(isIntrusionLoosening(a, b));
  b = a;
  b.sens[2].active_open = 0;                                        // NC -> NO: kablo kesilince algilamaz
  TEST_ASSERT_TRUE(isIntrusionLoosening(a, b));
  b = a;
  b.sens[2].confirm_ms = 2000;                                      // onay suresi uzadi
  TEST_ASSERT_TRUE(isIntrusionLoosening(a, b));
  b = a;
  b.sens[2].kind = (uint8_t)SensorKind::WATER;                       // hirsiz sensoru olmaktan cikti
  TEST_ASSERT_TRUE(isIntrusionLoosening(a, b));
  b = a;
  b.pol.entry_s = 60;                                               // giris gecikmesi uzadi
  TEST_ASSERT_TRUE(isIntrusionLoosening(a, b));
  b = a;
  b.pol.entry_s = 0;                                                // 0 = varsayilan 30 > 20: uzama
  TEST_ASSERT_TRUE(isIntrusionLoosening(a, b));
  b = a;
  b.pol.exit_s = 60;                                                // cikis gecikmesi uzadi
  TEST_ASSERT_TRUE(isIntrusionLoosening(a, b));
  // sikilastirma ve notr degisimler serbest
  b = a;
  b.pol.entry_s = 10;
  b.pol.exit_s = 5;
  TEST_ASSERT_FALSE(isIntrusionLoosening(a, b));
  b = a;
  b.sens[1].flags = SF_REACT;                                       // giris yolu -> anlik (sikilastirma)
  b.sens[3].flags = SF_REACT;                                       // hareket evde de etkin
  b.sens[2].confirm_ms = 0;
  TEST_ASSERT_FALSE(isIntrusionLoosening(a, b));
  b = a;
  b.sens[4] = sensor(12, SensorKind::DOOR, 2, 1);                    // yeni sensor
  b.nSens = 5;
  TEST_ASSERT_FALSE(isIntrusionLoosening(a, b));
  b = a;
  b.sens[2].kind = (uint8_t)SensorKind::DOOR;                        // tur degisimi tek basina degil; bayraklar belirler
  TEST_ASSERT_FALSE(isIntrusionLoosening(a, b));
  // SF_REACT'siz (alarm disi) sensorun silinmesi serbest
  static SafetyConfig c;
  c = a;
  c.sens[2].flags = 0;
  b = c;
  b.sens[2] = b.sens[3];
  b.nSens = 3;
  TEST_ASSERT_FALSE(isIntrusionLoosening(c, b));
  // ARM_KEY: DI gecmisindeki girise yeni anahtar ya da mevcut satiri anahtara cevirme (kapiyi kapatmak alarmi cozerdi)
  b = a;
  b.sens[4] = sensor(13, SensorKind::ARM_KEY, 0, 1);
  b.nSens = 5;
  TEST_ASSERT_FALSE(isIntrusionLoosening(a, b, 0));
  TEST_ASSERT_TRUE(isIntrusionLoosening(a, b, 1ULL << 12));
  b = a;
  b.sens[0] = sensor(3, SensorKind::ARM_KEY, 0, 1);                  // su sensoru satiri anahtar oldu
  TEST_ASSERT_TRUE(isIntrusionLoosening(a, b));
}

int main(int, char**) {
  UNITY_BEGIN();
  RUN_TEST(test_set_sensor_add_and_replace);
  RUN_TEST(test_del_sensor_and_actuator_shift);
  RUN_TEST(test_set_actuator_new_replace_full);
  RUN_TEST(test_policy_zone_light);
  RUN_TEST(test_loosening_rules);
  RUN_TEST(test_act_pos_remap_and_adopt);
  RUN_TEST(test_loosening_review_rules);
  RUN_TEST(test_loosening_gas_reset_on_used_di);
  RUN_TEST(test_actuator_identity_map);
  RUN_TEST(test_config_json_escapes_and_fields);
  RUN_TEST(test_dump_parts_cover_all_items_within_cap);
  RUN_TEST(test_intrusion_edit_and_loosening);
  RUN_TEST(test_intrusion_json_fields);
  RUN_TEST(test_gas_release_rules);
  RUN_TEST(test_intrusion_loosening_rules);
  return UNITY_END();
}
