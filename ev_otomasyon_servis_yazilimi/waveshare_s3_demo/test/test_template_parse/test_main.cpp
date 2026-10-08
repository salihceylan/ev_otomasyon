// ============================================================================
// template/TemplateParse (src/template/TemplateParse.*) birim testleri:  pio test -e native -f test_template_parse
//
// Ortak örnek dosyalar (docs/contracts/template/fixtures/, sunucu ve servis yazılımı da AYNI dosyaları kullanır):
//   * ok_*.json  -> geçerli; aday ana yapılandırma + güvenlik yapılandırması beklenen içerikte,
//   * bad_*.json -> {"expect": kod, "template": {...}}; doğrulayıcı TAM bu kodu döndürmeli.
// Ayrıca uygulama zarfı (label, device_name kesme), taban yapılandırmanın korunması ve README dışı kenar durumlar.
// Klasör: TPL_FIXTURES ortam değişkeni ya da bu dosyanın konumundan ../../../../docs/contracts/template/fixtures.
// Not: ArduinoJson (lib_deps) ve SafetyCfgApi.cpp / TemplateParse.cpp bu derleme birimine dahil edilir (test_build_src = no).
// ============================================================================
#include <unity.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <string>
#include <vector>
#include <ArduinoJson.h>
#include "safety/SafetyCfgApi.cpp"
#include "template/TemplateParse.cpp"
#ifdef _WIN32
#include <io.h>
#else
#include <dirent.h>
#endif

using namespace tpl;

void setUp(void) {}
void tearDown(void) {}

namespace {

std::string fixtureDir() {
  const char* env = getenv("TPL_FIXTURES");
  if (env && *env) {
    std::string d(env);
    if (d.back() != '/' && d.back() != '\\') d += '/';
    return d;
  }
  std::string f(__FILE__);
  const size_t cut = f.find_last_of("/\\");
  return f.substr(0, cut + 1) + "../../../../docs/contracts/template/fixtures/";
}

std::vector<std::string> listFixtures() {
  std::vector<std::string> out;
  const std::string dir = fixtureDir();
#ifdef _WIN32
  _finddata_t fd;
  intptr_t h = _findfirst((dir + "*.json").c_str(), &fd);
  if (h != -1) {
    do out.push_back(fd.name); while (_findnext(h, &fd) == 0);
    _findclose(h);
  }
#else
  DIR* d = opendir(dir.c_str());
  if (d) {
    while (dirent* e = readdir(d)) {
      const std::string n(e->d_name);
      if (n.size() > 5 && n.compare(n.size() - 5, 5, ".json") == 0) out.push_back(n);
    }
    closedir(d);
  }
#endif
  return out;
}

std::string readFile(const std::string& path) {
  std::string s;
  FILE* f = fopen(path.c_str(), "rb");
  if (!f) return s;
  char buf[4096];
  size_t n;
  while ((n = fread(buf, 1, sizeof(buf), f)) > 0) {
    for (size_t i = 0; i < n; i++) if (buf[i] != '\r') s += buf[i];   // CRLF/LF bağımsız (dizge değiştirme testleri)
  }
  fclose(f);
  return s;
}

// Fabrika varsayılanına yakın taban (kimlik/Wi-Fi alanları korunmalı).
SystemConfig baseConfig() {
  SystemConfig c;
  memset(&c, 0, sizeof(c));
  sysconfig_detail::copyStr(c.device_name, "Eski Ad");
  sysconfig_detail::copyStr(c.wifi_ssid, "EvAgi");
  sysconfig_detail::copyStr(c.wifi_pass, "parola123");
  c.wifi_sta_enabled = true;
  c.rs485_baud = 19200;
  c.ext_module_address = 1;
  c.mqtt_enabled = true;
  sysconfig_detail::copyStr(c.mqtt_server, "evotomasyon.example");
  c.mqtt_port = 8884;
  sysconfig_detail::copyStr(c.local_key, "anahtar-123");
  sysconfig_detail::copyStr(c.ap_pass, "appass-123");
  for (int i = 0; i < MAX_TOTAL_RELAYS; i++) {
    snprintf(c.relays[i].name, sizeof(c.relays[i].name), "Role %d", i + 1);
    c.relays[i].type = RELAY_TYPE_LIGHT;
  }
  for (int i = 0; i < MAX_TOTAL_DIS; i++) {
    snprintf(c.dis[i].name, sizeof(c.dis[i].name), "Giris %d", i + 1);
    c.dis[i].target_relay = (uint8_t)((i % 8) + 1);
  }
  c.validate();
  return c;
}

struct Parsed {
  bool ok;
  TplError err;
  TplCandidate* cand;
  Parsed() : ok(false), cand((TplCandidate*)malloc(sizeof(TplCandidate))) { err.code = nullptr; err.path[0] = 0; }
  ~Parsed() { free(cand); }
};

// Şablon nesnesini (ya da zarfı) ayrıştırır.
void parseText(const std::string& text, bool envelope, Parsed& p, const char* expectKeyInBad = nullptr) {
  DynamicJsonDocument doc(text.size() * 3 + 2048);
  DeserializationError de = deserializeJson(doc, text.c_str());
  TEST_ASSERT_TRUE_MESSAGE(!de, "JSON ayrıştırılamadı");
  JsonObject root = doc.as<JsonObject>();
  if (expectKeyInBad) root = root[expectKeyInBad].as<JsonObject>();
  const SystemConfig base = baseConfig();
  p.ok = envelope ? parseEnvelope(root, base, *p.cand, p.err) : parseTemplate(root, base, *p.cand, p.err);
}

std::string okTemplate(const char* name) { return readFile(fixtureDir() + name); }

// ok_1p1 metnine küçük bir değişiklik uygular (basit dizge değiştirme; örnek dosya biçimi gen_fixtures.py ile sabittir).
std::string mutated(const char* from, const char* to) {
  std::string s = okTemplate("ok_1p1.json");
  const size_t at = s.find(from);
  if (at == std::string::npos) {
    static char m[200];
    snprintf(m, sizeof(m), "değiştirilecek metin örnekte yok: %s", from);
    TEST_FAIL_MESSAGE(m);
  }
  s.replace(at, strlen(from), to);
  return s;
}

}  // namespace

// ---------------------------------------------------------------------------------------------------------------
void test_fixture_directory_has_all_shared_examples() {
  const std::vector<std::string> files = listFixtures();
  TEST_ASSERT_GREATER_OR_EQUAL(31, (int)files.size());
  int ok = 0, bad = 0;
  for (const std::string& f : files) {
    if (f.rfind("ok_", 0) == 0) ok++;
    if (f.rfind("bad_", 0) == 0) bad++;
  }
  TEST_ASSERT_GREATER_OR_EQUAL(4, ok);
  TEST_ASSERT_GREATER_OR_EQUAL(27, bad);
}

void test_every_ok_fixture_is_valid() {
  int n = 0;
  for (const std::string& f : listFixtures()) {
    if (f.rfind("ok_", 0) != 0) continue;
    Parsed p;
    parseText(readFile(fixtureDir() + f), false, p);
    if (!p.ok) {
      char m[160];
      snprintf(m, sizeof(m), "%s geçersiz sayıldı: %s @ %s", f.c_str(), p.err.code ? p.err.code : "?", p.err.path);
      TEST_FAIL_MESSAGE(m);
    }
    n++;
  }
  TEST_ASSERT_GREATER_OR_EQUAL(4, n);
}

void test_every_bad_fixture_returns_exact_expected_code() {
  int n = 0;
  for (const std::string& f : listFixtures()) {
    if (f.rfind("bad_", 0) != 0) continue;
    const std::string text = readFile(fixtureDir() + f);
    DynamicJsonDocument meta(text.size() * 3 + 2048);
    TEST_ASSERT_TRUE(!deserializeJson(meta, text.c_str()));
    const std::string expect = meta["expect"].as<const char*>();
    Parsed p;
    parseText(text, false, p, "template");
    char m[200];
    snprintf(m, sizeof(m), "%s: beklenen %s, gelen %s @ %s", f.c_str(), expect.c_str(), p.ok ? "GECERLI" : p.err.code, p.err.path);
    TEST_ASSERT_TRUE_MESSAGE(!p.ok && p.err.code && expect == p.err.code, m);
    n++;
  }
  TEST_ASSERT_GREATER_OR_EQUAL(27, n);
}

void test_ok_3p1_candidate_content_matches_template() {
  Parsed p;
  parseText(okTemplate("ok_3p1_vana_dimmer.json"), false, p);
  TEST_ASSERT_TRUE(p.ok);
  const TplCandidate& c = *p.cand;
  TEST_ASSERT_EQUAL_STRING("3f2a9c1e-5b7d-4e8f-9a01-23456789abcd", c.templateId);
  TEST_ASSERT_EQUAL_UINT(4, c.version);
  TEST_ASSERT_EQUAL_STRING("B Tipi 3+1", c.label);
  TEST_ASSERT_EQUAL_STRING("B Tipi 3+1", c.sys.device_name);
  TEST_ASSERT_FALSE(c.sys.ext_module_enabled);
  TEST_ASSERT_EQUAL_UINT(8, c.sys.totalRelays());
  TEST_ASSERT_EQUAL_UINT(RELAY_TYPE_SHUTTER_UP, c.sys.relays[2].type);
  TEST_ASSERT_EQUAL_UINT(30, c.sys.relays[2].runtime_sec);
  TEST_ASSERT_EQUAL_UINT(30, c.sys.relays[3].runtime_sec);
  TEST_ASSERT_EQUAL_UINT(RELAY_TYPE_LIGHT, c.sys.relays[7].type);
  TEST_ASSERT_EQUAL_UINT(0, c.sys.relays[7].runtime_sec);
  TEST_ASSERT_EQUAL_STRING("Su Vanası", c.sys.relays[7].name);
  TEST_ASSERT_EQUAL_UINT(DI_MODE_SHUTTER_STEP, c.sys.dis[1].mode);
  TEST_ASSERT_EQUAL_UINT(3, c.sys.dis[1].target_relay);
  TEST_ASSERT_EQUAL_UINT(0, c.sys.dis[6].target_relay);
  // güvenlik
  TEST_ASSERT_EQUAL_UINT(1, c.safety.pol.policy_on);
  TEST_ASSERT_EQUAL_UINT(10000, c.safety.pol.dry_hold_ms);
  TEST_ASSERT_EQUAL_STRING("Ev", c.safety.zones[0].name);
  TEST_ASSERT_EQUAL_STRING("", c.safety.zones[1].name);
  TEST_ASSERT_EQUAL_UINT(2, c.safety.nSens);
  TEST_ASSERT_EQUAL_UINT(7, c.safety.sens[0].index);
  TEST_ASSERT_EQUAL_UINT((uint8_t)safety::SensorKind::WATER, c.safety.sens[0].kind);
  TEST_ASSERT_EQUAL_UINT(safety::defaultConfirmMs((uint8_t)safety::SensorKind::WATER), c.safety.sens[0].confirm_ms);
  TEST_ASSERT_EQUAL_UINT(1, c.safety.nAct);
  TEST_ASSERT_EQUAL_UINT(8, c.safety.act[0].relay);
  TEST_ASSERT_EQUAL_UINT((uint8_t)safety::ActKind::VALVE, c.safety.act[0].kind);
  TEST_ASSERT_EQUAL_UINT((uint8_t)safety::CloseMode::ENERGIZE_TO_CLOSE, c.safety.act[0].close_mode);
  TEST_ASSERT_EQUAL_UINT(0x01, c.safety.act[0].zone_mask);
  TEST_ASSERT_EQUAL_UINT(1, c.safety.light[4].dimmable);
  TEST_ASSERT_EQUAL_UINT(2, c.safety.light[4].dimmer_addr);
  TEST_ASSERT_EQUAL_UINT(0, c.safety.light[5].dimmable);
  TEST_ASSERT_TRUE(safety::validate(c.sys, c.safety) == safety::CfgErr::OK);
}

void test_ok_ext16_sets_extension_module_and_sixteen_channels() {
  Parsed p;
  parseText(okTemplate("ok_dubleks_ekmodul16.json"), false, p);
  TEST_ASSERT_TRUE(p.ok);
  const TplCandidate& c = *p.cand;
  TEST_ASSERT_TRUE(c.sys.ext_module_enabled);
  TEST_ASSERT_EQUAL_UINT(8, c.sys.ext_module_channels);
  TEST_ASSERT_EQUAL_UINT(16, c.sys.totalRelays());
  TEST_ASSERT_EQUAL_UINT(16, c.sys.totalDIs());
  TEST_ASSERT_EQUAL_UINT(2, c.safety.nAct);
  TEST_ASSERT_EQUAL_UINT(16, c.safety.act[0].relay);
  TEST_ASSERT_EQUAL_UINT((uint8_t)safety::Medium::GAS, c.safety.act[0].medium);
  TEST_ASSERT_EQUAL_UINT((uint8_t)safety::ActKind::SIREN, c.safety.act[1].kind);
  TEST_ASSERT_EQUAL_UINT(0x03, c.safety.act[1].zone_mask);
  TEST_ASSERT_EQUAL_STRING("Üst Kat", c.safety.zones[1].name);
}

void test_base_identity_wifi_mqtt_fields_are_preserved() {
  Parsed p;
  parseText(okTemplate("ok_1p1.json"), false, p);
  TEST_ASSERT_TRUE(p.ok);
  const SystemConfig& s = p.cand->sys;
  TEST_ASSERT_EQUAL_STRING("EvAgi", s.wifi_ssid);
  TEST_ASSERT_EQUAL_STRING("parola123", s.wifi_pass);
  TEST_ASSERT_TRUE(s.wifi_sta_enabled);
  TEST_ASSERT_EQUAL_UINT(19200, s.rs485_baud);
  TEST_ASSERT_EQUAL_STRING("anahtar-123", s.local_key);
  TEST_ASSERT_EQUAL_STRING("appass-123", s.ap_pass);
  TEST_ASSERT_EQUAL_STRING("evotomasyon.example", s.mqtt_server);
}

void test_envelope_label_becomes_device_name() {
  Parsed p;
  parseText(std::string("{\"label\":\"Güneş Sitesi A-12\",\"template\":") + okTemplate("ok_1p1.json") + "}", true, p);
  TEST_ASSERT_TRUE(p.ok);
  TEST_ASSERT_EQUAL_STRING("Güneş Sitesi A-12", p.cand->label);
  TEST_ASSERT_EQUAL_STRING("Güneş Sitesi A-12", p.cand->sys.device_name);
}

void test_envelope_empty_label_uses_meta_name() {
  Parsed p;
  parseText(std::string("{\"label\":\"\",\"template\":") + okTemplate("ok_1p1.json") + "}", true, p);
  TEST_ASSERT_TRUE(p.ok);
  TEST_ASSERT_EQUAL_STRING("A Tipi 1+1", p.cand->sys.device_name);
}

void test_envelope_label_too_long_or_bad_field_rejected() {
  Parsed a;
  parseText(std::string("{\"label\":\"") + std::string(32, 'x') + "\",\"template\":" + okTemplate("ok_1p1.json") + "}", true, a);
  TEST_ASSERT_FALSE(a.ok);
  TEST_ASSERT_EQUAL_STRING("invalid_label", a.err.code);
  Parsed b;
  parseText(std::string("{\"fazla\":1,\"template\":") + okTemplate("ok_1p1.json") + "}", true, b);
  TEST_ASSERT_FALSE(b.ok);
  TEST_ASSERT_EQUAL_STRING("bad_field", b.err.code);
  Parsed c;
  parseText("{\"label\":\"x\"}", true, c);
  TEST_ASSERT_FALSE(c.ok);
  TEST_ASSERT_EQUAL_STRING("bad_field", c.err.code);
  TEST_ASSERT_EQUAL_STRING("template", c.err.path);
}

void test_long_meta_name_is_truncated_utf8_safe_to_31_bytes() {
  // 16 x "Ç" = 32 bayt (name 1..48 bayt geçerli); device_name 31 bayta karakter ortası kesilmeden: 15 x "Ç" = 30 bayt.
  std::string nm;
  for (int i = 0; i < 16; i++) nm += "Ç";
  Parsed p;
  parseText(mutated("\"A Tipi 1+1\"", (std::string("\"") + nm + "\"").c_str()), false, p);
  TEST_ASSERT_TRUE(p.ok);
  TEST_ASSERT_EQUAL_UINT(30, strlen(p.cand->sys.device_name));
  TEST_ASSERT_TRUE(NetUtil::isCleanUtf8(p.cand->sys.device_name, strlen(p.cand->sys.device_name)));
}

void test_meta_rules() {
  Parsed a;
  parseText(mutated("3f2a9c1e-5b7d-4e8f-9a01-23456789abcd", "3F2A9C1E-5B7D-4E8F-9A01-23456789ABCD"), false, a);
  TEST_ASSERT_EQUAL_STRING("invalid_template_id", a.err.code);
  Parsed b;
  parseText(mutated("\"version\": 1", "\"version\": 0"), false, b);
  TEST_ASSERT_EQUAL_STRING("invalid_version", b.err.code);
  Parsed c;
  parseText(mutated("\"flat_type\": \"1+1\"", "\"flat_type\": \"\""), false, c);
  TEST_ASSERT_EQUAL_STRING("invalid_flat_type", c.err.code);
  Parsed d;
  parseText(mutated("\"site_id\": \"8c1d2e3f-4a5b-4c6d-8e7f-0123456789ab\"", "\"site_id\": null"), false, d);
  TEST_ASSERT_TRUE(d.ok);
  Parsed e;
  parseText(mutated("\"site_id\": \"8c1d2e3f-4a5b-4c6d-8e7f-0123456789ab\"", "\"site_id\": 5"), false, e);
  TEST_ASSERT_EQUAL_STRING("invalid_site_id", e.err.code);
}

void test_shutter_dis_mode_must_target_up_relay_and_light_dimmer_rules() {
  // panjur kipi boşta (0) hedef -> invalid_target_relay
  Parsed a;
  parseText(mutated("\"target_relay\": 1,\n      \"mode\": \"shutter_step\"", "\"target_relay\": 0,\n      \"mode\": \"shutter_step\""), false, a);
  TEST_ASSERT_EQUAL_STRING("invalid_target_relay", a.err.code);
  // ışık seçeneği panjur rölesine -> invalid_light
  Parsed b;
  parseText(mutated("\"lights\": []", "\"lights\": [{\"relay\": 1, \"dimmable\": 1, \"src\": 1, \"addr\": 2, \"ch\": 1}]"), false, b);
  TEST_ASSERT_EQUAL_STRING("invalid_light", b.err.code);
  // aynı röle iki kez -> invalid_light
  Parsed c;
  parseText(mutated("\"lights\": []", "\"lights\": [{\"relay\": 3, \"dimmable\": 1}, {\"relay\": 3, \"dimmable\": 0}]"), false, c);
  TEST_ASSERT_EQUAL_STRING("invalid_light", c.err.code);
  // eylemci "id" alanı şablonda yasak
  Parsed d;
  parseText(mutated("\"actuators\": []", "\"actuators\": [{\"id\": \"a1\", \"relay\": 8, \"kind\": \"siren\", \"zones\": [1]}]"), false, d);
  TEST_ASSERT_EQUAL_STRING("bad_field", d.err.code);
  // tanımsız bölgeye eylemci -> act_zone
  Parsed e;
  parseText(mutated("\"actuators\": []", "\"actuators\": [{\"relay\": 8, \"kind\": \"siren\", \"zones\": [2]}]"), false, e);
  TEST_ASSERT_EQUAL_STRING("act_zone", e.err.code);
  // bölge 1 eksik -> bad_zone
  Parsed f;
  parseText(mutated("\"id\": 1,\n        \"name\": \"Ev\"", "\"id\": 2,\n        \"name\": \"Ev\""), false, f);
  TEST_ASSERT_EQUAL_STRING("bad_zone", f.err.code);
}

// Ortak öğe ayrıştırıcılarına bölünen tek öğeli yama ayrıştırıcısı (parseCfgEdit) aynı sonucu vermeli (regresyon).
void test_patch_parser_still_parses_items_after_refactor() {
  using namespace safety;
  auto run = [](const char* json, CfgEdit& e) -> const char* {
    DynamicJsonDocument d(2048);
    TEST_ASSERT_TRUE(!deserializeJson(d, json));
    bool hasBase = false;
    uint32_t baseRev = 0;
    return parseCfgEdit(d.as<JsonObject>(), e, hasBase, baseRev, false);
  };
  CfgEdit e;
  TEST_ASSERT_NULL(run("{\"base_rev\":3,\"set\":{\"sensor\":{\"id\":\"d3\",\"kind\":\"gas\",\"zone\":2,\"active_open\":1,\"name\":\"Mutfak\"}}}", e));
  TEST_ASSERT_TRUE(e.op == EditOp::SET_SENSOR);
  TEST_ASSERT_EQUAL_UINT(3, e.sens.index);
  TEST_ASSERT_EQUAL_UINT((uint8_t)SensorKind::GAS, e.sens.kind);
  TEST_ASSERT_EQUAL_UINT(2, e.sens.zone);
  TEST_ASSERT_EQUAL_UINT(1, e.sens.active_open);
  TEST_ASSERT_EQUAL_UINT(defaultFlags((uint8_t)SensorKind::GAS), e.sens.flags);
  TEST_ASSERT_EQUAL_STRING("Mutfak", e.sens.name);
  TEST_ASSERT_NULL(run("{\"set\":{\"actuator\":{\"id\":\"a2\",\"relay\":5,\"kind\":\"siren\",\"zones\":[1,3]}}}", e));
  TEST_ASSERT_TRUE(e.op == EditOp::SET_ACTUATOR);
  TEST_ASSERT_EQUAL_UINT(1, e.actIndex);
  TEST_ASSERT_EQUAL_UINT(0x05, e.act.zone_mask);
  TEST_ASSERT_EQUAL_UINT(SIREN_RUN_DEFAULT_S, e.act.run_limit_s);
  TEST_ASSERT_NULL(run("{\"set\":{\"actuator\":{\"relay\":6,\"kind\":\"valve\",\"medium\":\"water\",\"zones\":[1]}}}", e));
  TEST_ASSERT_EQUAL_UINT(0xFF, e.actIndex);
  TEST_ASSERT_EQUAL_UINT(1, e.act.fb_closed_active);
  TEST_ASSERT_EQUAL_UINT(FB_TIMEOUT_DEFAULT_S, e.act.fb_timeout_s);
  TEST_ASSERT_NULL(run("{\"set\":{\"light\":{\"relay\":3,\"dimmable\":true,\"src\":1,\"addr\":2,\"ch\":4}}}", e));
  TEST_ASSERT_TRUE(e.op == EditOp::SET_LIGHT);
  TEST_ASSERT_EQUAL_UINT(3, e.lightRelay);
  TEST_ASSERT_EQUAL_UINT(4, e.light.dimmer_ch);
  TEST_ASSERT_EQUAL_STRING("bad_field", run("{\"set\":{\"sensor\":{\"id\":\"d3\",\"kind\":\"gas\",\"zone\":1,\"x\":1}}}", e));
  TEST_ASSERT_EQUAL_STRING("bad_kind", run("{\"set\":{\"actuator\":{\"relay\":6,\"kind\":\"lamp\"}}}", e));
  TEST_ASSERT_EQUAL_STRING("bad_relay", run("{\"set\":{\"light\":{\"relay\":41}}}", e));
}

// Hata yolu seri satıra / JSON'a basılmadan önce temizlenir (R1-7): istemciden gelen alan adı satır sonu / tırnak / UTF-8 taşıyamaz.
void test_error_path_is_sanitized() {
  Parsed p;
  parseText(mutated("\"name\": \"Salon Panjur Butonu\"", "\"name\": \"Salon Panjur Butonu\", \"k\\\"ö\\nx\": 1"), false, p);
  TEST_ASSERT_FALSE(p.ok);
  TEST_ASSERT_EQUAL_STRING("bad_field", p.err.code);
  TEST_ASSERT_EQUAL_STRING("dis[0].k????x", p.err.path);   // tırnak, "ö" (2 bayt) ve satır sonu -> "?"
  char s[] = "relays[3].runtime_s";
  sanitizePath(s);
  TEST_ASSERT_EQUAL_STRING("relays[3].runtime_s", s);
  char t[] = "a b\r\x7f{}";
  sanitizePath(t);
  TEST_ASSERT_EQUAL_STRING("a?b????", t);
}

int main(int, char**) {
  UNITY_BEGIN();
  RUN_TEST(test_fixture_directory_has_all_shared_examples);
  RUN_TEST(test_every_ok_fixture_is_valid);
  RUN_TEST(test_every_bad_fixture_returns_exact_expected_code);
  RUN_TEST(test_ok_3p1_candidate_content_matches_template);
  RUN_TEST(test_ok_ext16_sets_extension_module_and_sixteen_channels);
  RUN_TEST(test_base_identity_wifi_mqtt_fields_are_preserved);
  RUN_TEST(test_envelope_label_becomes_device_name);
  RUN_TEST(test_envelope_empty_label_uses_meta_name);
  RUN_TEST(test_envelope_label_too_long_or_bad_field_rejected);
  RUN_TEST(test_long_meta_name_is_truncated_utf8_safe_to_31_bytes);
  RUN_TEST(test_meta_rules);
  RUN_TEST(test_shutter_dis_mode_must_target_up_relay_and_light_dimmer_rules);
  RUN_TEST(test_patch_parser_still_parses_items_after_refactor);
  RUN_TEST(test_error_path_is_sanitized);
  return UNITY_END();
}
