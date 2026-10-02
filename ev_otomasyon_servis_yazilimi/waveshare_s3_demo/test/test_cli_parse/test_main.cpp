// ============================================================================
// CliParse (src/CliParse.h) birim testleri:  pio test -e native -f test_cli_parse
// FACTORYINIT <local_key> <ap_pass> ayrıştırma + doğrulama (saf mantık).
// ============================================================================
#include <unity.h>
#include <stdint.h>
#include <string.h>
#include "CliParse.h"

using namespace cliparse;

void setUp(void) {}
void tearDown(void) {}

namespace {

struct Out {
  char key[LOCAL_KEY_MAX_LEN + 1];
  char pass[AP_PASS_MAX_LEN + 1];
  Out() { memset(key, 0x5A, sizeof(key)); memset(pass, 0x5A, sizeof(pass)); }   // "dokunulmadı" gözcüsü
  bool untouched() const {
    for (size_t i = 0; i < sizeof(key); i++) if (key[i] != 0x5A) return false;
    for (size_t i = 0; i < sizeof(pass); i++) if (pass[i] != 0x5A) return false;
    return true;
  }
};

FactoryInitStatus run(const char* line, bool provisioned, Out& o) {
  return parseFactoryInit(line, provisioned, o.key, sizeof(o.key), o.pass, sizeof(o.pass));
}

// n karakterlik c dizgisi
static void fill(char* dst, size_t n, char c) { memset(dst, c, n); dst[n] = '\0'; }

// "FACTORYINIT <key> <pass>" satiri kur (snprintf/strcat'siz: yalniz memcpy/strlen)
static void mk(char* out, const char* key, const char* pass) {
  const char* head = "FACTORYINIT ";
  size_t n = 0;
  memcpy(out + n, head, strlen(head)); n += strlen(head);
  memcpy(out + n, key, strlen(key)); n += strlen(key);
  out[n++] = ' ';
  memcpy(out + n, pass, strlen(pass)); n += strlen(pass);
  out[n] = '\0';
}

}  // namespace

void test_valid_line_is_parsed(void) {
  Out o;
  TEST_ASSERT_EQUAL_INT(FI_OK, run("FACTORYINIT abcd1234 parola12", false, o));
  TEST_ASSERT_EQUAL_STRING("abcd1234", o.key);
  TEST_ASSERT_EQUAL_STRING("parola12", o.pass);
}

void test_ap_pass_may_contain_spaces_and_takes_rest_of_line(void) {
  Out o;
  TEST_ASSERT_EQUAL_INT(FI_OK, run("FACTORYINIT abcd1234 ev kurulum parolasi 1", false, o));
  TEST_ASSERT_EQUAL_STRING("abcd1234", o.key);
  TEST_ASSERT_EQUAL_STRING("ev kurulum parolasi 1", o.pass);
}

void test_extra_separators_and_trailing_whitespace_are_tolerated(void) {
  Out o;
  TEST_ASSERT_EQUAL_INT(FI_OK, run("   FACTORYINIT    abcd1234     parola12  \r\n", false, o));
  TEST_ASSERT_EQUAL_STRING("abcd1234", o.key);
  TEST_ASSERT_EQUAL_STRING("parola12", o.pass);          // sondaki boşluk/CR/LF pass'e girmez
}

void test_already_provisioned_wins_and_changes_nothing(void) {
  Out o;
  TEST_ASSERT_EQUAL_INT(FI_ERR_ALREADY_PROVISIONED, run("FACTORYINIT abcd1234 parola12", true, o));
  TEST_ASSERT_TRUE(o.untouched());
  // geçersiz argümanlı satır da (önce provizyon denetimi) already_provisioned döner
  TEST_ASSERT_EQUAL_INT(FI_ERR_ALREADY_PROVISIONED, run("FACTORYINIT x y", true, o));
  TEST_ASSERT_EQUAL_INT(FI_ERR_ALREADY_PROVISIONED, run("FACTORYINIT", true, o));
  TEST_ASSERT_TRUE(o.untouched());
}

void test_local_key_length_boundaries(void) {
  Out o;
  char key[40];
  fill(key, 7, 'k');
  char line[160];
  mk(line, key, "parola12");
  TEST_ASSERT_EQUAL_INT(FI_ERR_INVALID_LOCAL_KEY, run(line, false, o));
  fill(key, 8, 'k');
  mk(line, key, "parola12");
  TEST_ASSERT_EQUAL_INT(FI_OK, run(line, false, o));
  TEST_ASSERT_EQUAL_UINT32(8, (uint32_t)strlen(o.key));
  Out o2;
  fill(key, 32, 'k');
  mk(line, key, "parola12");
  TEST_ASSERT_EQUAL_INT(FI_OK, run(line, false, o2));
  TEST_ASSERT_EQUAL_UINT32(32, (uint32_t)strlen(o2.key));
  Out o3;
  fill(key, 33, 'k');
  mk(line, key, "parola12");
  TEST_ASSERT_EQUAL_INT(FI_ERR_INVALID_LOCAL_KEY, run(line, false, o3));
  TEST_ASSERT_TRUE(o3.untouched());
}

void test_local_key_character_set(void) {
  Out o;
  // 0x21..0x7E serbest: '!' ve '~' sınırları dahil
  TEST_ASSERT_EQUAL_INT(FI_OK, run("FACTORYINIT !~abcd12 parola12", false, o));
  TEST_ASSERT_EQUAL_STRING("!~abcd12", o.key);
  // DEL (0x7F), kontrol karakteri, >= 0x80 geçersiz
  Out a;
  TEST_ASSERT_EQUAL_INT(FI_ERR_INVALID_LOCAL_KEY, run("FACTORYINIT abcd123\x7f parola12", false, a));
  TEST_ASSERT_EQUAL_INT(FI_ERR_INVALID_LOCAL_KEY, run("FACTORYINIT abcd123\x01 parola12", false, a));
  TEST_ASSERT_EQUAL_INT(FI_ERR_INVALID_LOCAL_KEY, run("FACTORYINIT abcd123\t parola12", false, a));   // TAB ayraç değil, geçersiz karakter
  TEST_ASSERT_EQUAL_INT(FI_ERR_INVALID_LOCAL_KEY, run("FACTORYINIT abcd123\xc3\xa7 parola12", false, a));   // UTF-8 "ç"
  TEST_ASSERT_TRUE(a.untouched());
}

void test_ap_pass_length_boundaries(void) {
  Out o;
  char pass[40];
  char line[160];
  fill(pass, 7, 'p');
  mk(line, "abcd1234", pass);
  TEST_ASSERT_EQUAL_INT(FI_ERR_INVALID_AP_PASS, run(line, false, o));
  TEST_ASSERT_TRUE(o.untouched());
  fill(pass, 8, 'p');
  mk(line, "abcd1234", pass);
  TEST_ASSERT_EQUAL_INT(FI_OK, run(line, false, o));
  TEST_ASSERT_EQUAL_UINT32(8, (uint32_t)strlen(o.pass));
  Out o2;
  fill(pass, 32, 'p');
  mk(line, "abcd1234", pass);
  TEST_ASSERT_EQUAL_INT(FI_OK, run(line, false, o2));
  TEST_ASSERT_EQUAL_UINT32(32, (uint32_t)strlen(o2.pass));
  Out o3;
  fill(pass, 33, 'p');
  mk(line, "abcd1234", pass);
  TEST_ASSERT_EQUAL_INT(FI_ERR_INVALID_AP_PASS, run(line, false, o3));
  TEST_ASSERT_TRUE(o3.untouched());
}

void test_ap_pass_character_set(void) {
  Out o;
  TEST_ASSERT_EQUAL_INT(FI_OK, run("FACTORYINIT abcd1234 ~ !\"#$%&'()", false, o));   // 0x20..0x7E (boşluk dahil)
  Out a;
  TEST_ASSERT_EQUAL_INT(FI_ERR_INVALID_AP_PASS, run("FACTORYINIT abcd1234 parola1\x7f", false, a));
  TEST_ASSERT_EQUAL_INT(FI_ERR_INVALID_AP_PASS, run("FACTORYINIT abcd1234 pa\tr ola12", false, a));   // iç TAB
  TEST_ASSERT_EQUAL_INT(FI_ERR_INVALID_AP_PASS, run("FACTORYINIT abcd1234 parola\xc3\xa7", false, a));
  TEST_ASSERT_TRUE(a.untouched());
}

void test_missing_arguments(void) {
  Out o;
  TEST_ASSERT_EQUAL_INT(FI_ERR_INVALID_LOCAL_KEY, run("FACTORYINIT", false, o));            // hiç argüman
  TEST_ASSERT_EQUAL_INT(FI_ERR_INVALID_LOCAL_KEY, run("FACTORYINIT   ", false, o));
  TEST_ASSERT_EQUAL_INT(FI_ERR_INVALID_AP_PASS, run("FACTORYINIT abcd1234", false, o));     // yalnız local_key
  TEST_ASSERT_EQUAL_INT(FI_ERR_INVALID_AP_PASS, run("FACTORYINIT abcd1234    ", false, o));
  TEST_ASSERT_EQUAL_INT(FI_ERR_INVALID_LOCAL_KEY, run("", false, o));
  TEST_ASSERT_TRUE(o.untouched());
}

void test_oversized_line_is_rejected_without_overflow(void) {
  Out o;
  static char big[900];
  memset(big, 'x', sizeof(big) - 1);
  big[sizeof(big) - 1] = '\0';
  memcpy(big, "FACTORYINIT ", 12);
  TEST_ASSERT_EQUAL_INT(FI_ERR_INVALID_LOCAL_KEY, run(big, false, o));
  TEST_ASSERT_TRUE(o.untouched());
  // 160 karakterlik CLI satırı sınırında: key geçerli, pass çok uzun
  char line[200];
  mk(line, "abcd1234", "");
  size_t n = strlen(line);
  memset(line + n, 'p', 100);
  line[n + 100] = '\0';
  TEST_ASSERT_EQUAL_INT(FI_ERR_INVALID_AP_PASS, run(line, false, o));
  TEST_ASSERT_TRUE(o.untouched());
}

void test_null_and_small_buffers_are_rejected(void) {
  char k[LOCAL_KEY_MAX_LEN + 1], p[AP_PASS_MAX_LEN + 1];
  TEST_ASSERT_EQUAL_INT(FI_ERR_INVALID_LOCAL_KEY, parseFactoryInit(NULL, false, k, sizeof(k), p, sizeof(p)));
  TEST_ASSERT_EQUAL_INT(FI_ERR_INVALID_LOCAL_KEY, parseFactoryInit("FACTORYINIT abcd1234 parola12", false, k, 8, p, sizeof(p)));
  TEST_ASSERT_EQUAL_INT(FI_ERR_INVALID_LOCAL_KEY, parseFactoryInit("FACTORYINIT abcd1234 parola12", false, k, sizeof(k), p, 8));
  TEST_ASSERT_EQUAL_INT(FI_ERR_INVALID_LOCAL_KEY, parseFactoryInit("FACTORYINIT abcd1234 parola12", false, NULL, sizeof(k), p, sizeof(p)));
}

void test_output_is_nul_terminated_at_exact_capacity(void) {
  char k[LOCAL_KEY_MAX_LEN + 1], p[AP_PASS_MAX_LEN + 1];
  memset(k, 0x77, sizeof(k)); memset(p, 0x77, sizeof(p));
  char line[200];
  char key32[33], pass32[33];
  fill(key32, 32, 'K'); fill(pass32, 32, 'P');
  mk(line, key32, pass32);
  TEST_ASSERT_EQUAL_INT(FI_OK, parseFactoryInit(line, false, k, sizeof(k), p, sizeof(p)));
  TEST_ASSERT_EQUAL_UINT8(0, (uint8_t)k[32]);
  TEST_ASSERT_EQUAL_UINT8(0, (uint8_t)p[32]);
  TEST_ASSERT_EQUAL_STRING(key32, k);
  TEST_ASSERT_EQUAL_STRING(pass32, p);
}

void test_error_texts_match_the_serial_protocol(void) {
  TEST_ASSERT_EQUAL_STRING("already_provisioned", factoryInitErrorText(FI_ERR_ALREADY_PROVISIONED));
  TEST_ASSERT_EQUAL_STRING("invalid_local_key", factoryInitErrorText(FI_ERR_INVALID_LOCAL_KEY));
  TEST_ASSERT_EQUAL_STRING("invalid_ap_pass", factoryInitErrorText(FI_ERR_INVALID_AP_PASS));
}

void test_parsed_values_satisfy_system_config_setters(void) {
  // Ayrıştırıcının kabul ettiği her değer SystemConfig::setLocalKey/setApPass tarafından da kabul edilmeli
  // (CLI'da "OK" denip kalıcılaştırmada reddedilme olmasın).
  SystemConfig cfg;
  memset(&cfg, 0, sizeof(cfg));
  Out o;
  TEST_ASSERT_EQUAL_INT(FI_OK, run("FACTORYINIT !~Aa0-9_x ~ !\"#$%&'()", false, o));
  TEST_ASSERT_TRUE(cfg.setLocalKey(o.key));
  TEST_ASSERT_TRUE(cfg.setApPass(o.pass));
  Out e;
  fill(e.key, 32, '~'); fill(e.pass, 32, ' ');   // boşluk-yalnız pass: ayrıştırıcı reddetmeli (satır sonu kırpılır)
  char line[200];
  mk(line, e.key, e.pass);
  Out r;
  TEST_ASSERT_EQUAL_INT(FI_ERR_INVALID_AP_PASS, run(line, false, r));
}

int main(int, char**) {
  UNITY_BEGIN();
  RUN_TEST(test_valid_line_is_parsed);
  RUN_TEST(test_ap_pass_may_contain_spaces_and_takes_rest_of_line);
  RUN_TEST(test_extra_separators_and_trailing_whitespace_are_tolerated);
  RUN_TEST(test_already_provisioned_wins_and_changes_nothing);
  RUN_TEST(test_local_key_length_boundaries);
  RUN_TEST(test_local_key_character_set);
  RUN_TEST(test_ap_pass_length_boundaries);
  RUN_TEST(test_ap_pass_character_set);
  RUN_TEST(test_missing_arguments);
  RUN_TEST(test_oversized_line_is_rejected_without_overflow);
  RUN_TEST(test_null_and_small_buffers_are_rejected);
  RUN_TEST(test_output_is_nul_terminated_at_exact_capacity);
  RUN_TEST(test_error_texts_match_the_serial_protocol);
  RUN_TEST(test_parsed_values_satisfy_system_config_setters);
  return UNITY_END();
}
