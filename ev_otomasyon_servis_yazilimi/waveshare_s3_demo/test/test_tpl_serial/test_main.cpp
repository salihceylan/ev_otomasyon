// ============================================================================
// template/TplSerial (src/template/TplSerial.h) birim testleri:  pio test -e native -f test_tpl_serial
//
// Seri TPL çerçevelemesi (README "Seri protokol", K-Ş5): BEGIN argümanları, parçalı base64 (4 karakter sınırına hizasız parçalar dahil),
// CRC-32 IEEE (zlib.crc32 bilinen değerleri), boyut / taşma / bozuk base64 / dolgudan sonra veri, 30 sn zaman aşımı (bir kez bildirilir,
// millis() sarma tabanları), aktarım yokken DATA/COMMIT.
// ============================================================================
#include <unity.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <string>
#include "template/TplSerial.h"

using namespace tpl;

void setUp(void) {}
void tearDown(void) {}

namespace {

std::string b64(const uint8_t* p, size_t n) {
  static const char* T = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  std::string o;
  for (size_t i = 0; i < n; i += 3) {
    const uint32_t a = p[i], b = i + 1 < n ? p[i + 1] : 0, c = i + 2 < n ? p[i + 2] : 0;
    const uint32_t v = (a << 16) | (b << 8) | c;
    o += T[(v >> 18) & 63];
    o += T[(v >> 12) & 63];
    o += i + 1 < n ? T[(v >> 6) & 63] : '=';
    o += i + 2 < n ? T[v & 63] : '=';
  }
  return o;
}

struct Session {
  TplRx rx;
  uint8_t* mem;
  Session() : mem(nullptr) {}
  ~Session() { free(rx.takeBuffer()); }
  void begin(uint32_t size, uint32_t crc, uint32_t now) {
    free(rx.takeBuffer());
    rx.begin(size, crc, (uint8_t*)malloc(size), now);
  }
};

// Bütün gövdeyi chunk karakterlik DATA satırlarıyla gönderir; ilk hatayı döndürür.
RxErr sendAll(Session& s, const std::string& enc, size_t chunk, uint32_t now) {
  for (size_t i = 0; i < enc.size(); i += chunk) {
    const RxErr e = s.rx.data(enc.substr(i, chunk).c_str(), now);
    if (e != RxErr::OK) return e;
  }
  return RxErr::OK;
}

std::string body(size_t n) {
  std::string s;
  uint32_t x = 12345;
  for (size_t i = 0; i < n; i++) {
    x = x * 1103515245u + 12345u;
    s += (char)(x >> 16);
  }
  return s;
}

}  // namespace

void test_crc32_matches_zlib_known_values() {
  TEST_ASSERT_EQUAL_HEX32(0xCBF43926u, safety::crc32("123456789", 9));   // zlib.crc32(b"123456789")
  TEST_ASSERT_EQUAL_HEX32(0x00000000u, safety::crc32("", 0));
}

void test_begin_argument_rules() {
  uint32_t size = 0, crc = 0;
  TEST_ASSERT_TRUE(parseBeginArgs("1", "0000abcd", size, crc) == RxErr::OK);
  TEST_ASSERT_EQUAL_UINT(1, size);
  TEST_ASSERT_EQUAL_HEX32(0xABCDu, crc);
  TEST_ASSERT_TRUE(parseBeginArgs("24576", "CBF43926", size, crc) == RxErr::OK);
  TEST_ASSERT_EQUAL_HEX32(0xCBF43926u, crc);
  TEST_ASSERT_TRUE(parseBeginArgs("24577", "cbf43926", size, crc) == RxErr::BAD_SIZE);
  TEST_ASSERT_TRUE(parseBeginArgs("0", "cbf43926", size, crc) == RxErr::BAD_SIZE);
  TEST_ASSERT_TRUE(parseBeginArgs("012", "cbf43926", size, crc) == RxErr::BAD_SIZE);
  TEST_ASSERT_TRUE(parseBeginArgs("12a", "cbf43926", size, crc) == RxErr::BAD_SIZE);
  TEST_ASSERT_TRUE(parseBeginArgs("", "cbf43926", size, crc) == RxErr::BAD_SIZE);
  TEST_ASSERT_TRUE(parseBeginArgs("99999999999", "cbf43926", size, crc) == RxErr::BAD_SIZE);
  TEST_ASSERT_TRUE(parseBeginArgs("10", "cbf4392", size, crc) == RxErr::BAD_CRC);
  TEST_ASSERT_TRUE(parseBeginArgs("10", "cbf43926a", size, crc) == RxErr::BAD_CRC);
  TEST_ASSERT_TRUE(parseBeginArgs("10", "cbf4392g", size, crc) == RxErr::BAD_CRC);
  TEST_ASSERT_TRUE(parseBeginArgs("10", "", size, crc) == RxErr::BAD_CRC);
}

void test_roundtrip_for_many_sizes_and_unaligned_chunks() {
  const size_t sizes[] = {1, 2, 3, 4, 5, 149, 150, 151, 1000, 24576};
  const size_t chunks[] = {150, 148, 1, 7, 4};
  for (size_t si = 0; si < sizeof(sizes) / sizeof(sizes[0]); si++) {
    const std::string b = body(sizes[si]);
    const std::string enc = b64((const uint8_t*)b.data(), b.size());
    const uint32_t crc = safety::crc32(b.data(), b.size());
    for (size_t ci = 0; ci < sizeof(chunks) / sizeof(chunks[0]); ci++) {
      Session s;
      s.begin((uint32_t)b.size(), crc, 1000);
      TEST_ASSERT_TRUE(sendAll(s, enc, chunks[ci], 1000) == RxErr::OK);
      TEST_ASSERT_EQUAL_UINT(b.size(), s.rx.got);
      TEST_ASSERT_TRUE(s.rx.commit(1000) == RxErr::OK);
      TEST_ASSERT_EQUAL_MEMORY(b.data(), s.rx.buf, b.size());
    }
  }
}

void test_crc_mismatch_size_short_and_overflow() {
  const std::string b = body(100);
  const std::string enc = b64((const uint8_t*)b.data(), b.size());
  const uint32_t crc = safety::crc32(b.data(), b.size());
  {
    Session s;
    s.begin(100, crc ^ 1u, 0);
    TEST_ASSERT_TRUE(sendAll(s, enc, 150, 0) == RxErr::OK);
    TEST_ASSERT_TRUE(s.rx.commit(0) == RxErr::BAD_CRC);
    TEST_ASSERT_FALSE(s.rx.active);
    TEST_ASSERT_TRUE(s.rx.commit(0) == RxErr::NO_BEGIN);   // aktarım silindi
  }
  {
    Session s;   // eksik veri
    s.begin(100, crc, 0);
    TEST_ASSERT_TRUE(sendAll(s, enc.substr(0, 128), 150, 0) == RxErr::OK);
    TEST_ASSERT_TRUE(s.rx.commit(0) == RxErr::BAD_SIZE);
  }
  {
    Session s;   // beyan edilenden fazla veri
    s.begin(90, crc, 0);
    TEST_ASSERT_TRUE(sendAll(s, enc, 150, 0) == RxErr::OVERRUN);
    TEST_ASSERT_FALSE(s.rx.active);
    TEST_ASSERT_TRUE(s.rx.data("QUJD", 0) == RxErr::NO_BEGIN);
  }
  {
    Session s;   // dörtlü yarım kaldı
    s.begin(100, crc, 0);
    TEST_ASSERT_TRUE(sendAll(s, enc.substr(0, enc.size() - 1), 150, 0) == RxErr::OK);
    TEST_ASSERT_TRUE(s.rx.commit(0) == RxErr::BAD_B64);
  }
}

void test_invalid_base64_and_data_after_padding() {
  Session s;
  s.begin(10, 0, 0);
  TEST_ASSERT_TRUE(s.rx.data("QU*D", 0) == RxErr::BAD_B64);
  TEST_ASSERT_FALSE(s.rx.active);
  s.begin(10, 0, 0);
  TEST_ASSERT_TRUE(s.rx.data("QQ==QUJD", 0) == RxErr::BAD_B64);   // dolgudan sonra veri
  s.begin(10, 0, 0);
  TEST_ASSERT_TRUE(s.rx.data("Q===", 0) == RxErr::BAD_B64);       // dolgu 2. karakter olamaz
  s.begin(10, 0, 0);
  TEST_ASSERT_TRUE(s.rx.data("QU=D", 0) == RxErr::BAD_B64);       // dolgudan sonra veri (aynı dörtlü)
  s.begin(10, 0, 0);
  TEST_ASSERT_TRUE(s.rx.data(std::string(151, 'A').c_str(), 0) == RxErr::BAD_B64);   // 150 karakter sınırı
  s.begin(10, 0, 0);
  TEST_ASSERT_TRUE(s.rx.data("", 0) == RxErr::BAD_B64);
}

void test_data_and_commit_without_begin() {
  TplRx rx;
  TEST_ASSERT_TRUE(rx.data("QUJD", 0) == RxErr::NO_BEGIN);
  TEST_ASSERT_TRUE(rx.commit(0) == RxErr::NO_BEGIN);
  rx.abort();
  TEST_ASSERT_TRUE(rx.commit(0) == RxErr::NO_BEGIN);
}

void test_timeout_after_30s_reported_once_on_next_command() {
  const uint32_t bases[] = {0u, 1000u, 0x7FFFFFF0u, 0xFFFFFFF0u};
  for (uint32_t t0 : bases) {
    Session s;
    s.begin(3, safety::crc32("abc", 3), t0);
    TEST_ASSERT_FALSE(s.rx.poll(t0 + 29999u));
    TEST_ASSERT_TRUE(s.rx.data("YW", t0 + 29999u) == RxErr::OK);
    TEST_ASSERT_TRUE(s.rx.poll(t0 + 30000u));                // süre doldu: aktarım sonlandı
    free(s.rx.takeBuffer());
    TEST_ASSERT_FALSE(s.rx.poll(t0 + 90000u));
    TEST_ASSERT_TRUE(s.rx.data("Jj", t0 + 30001u) == RxErr::TIMED_OUT);
    TEST_ASSERT_TRUE(s.rx.commit(t0 + 30002u) == RxErr::NO_BEGIN);   // bir kez bildirilir
  }
  // ABORT zaman aşımı bildirimini de temizler; yeni BEGIN temiz başlar
  Session s;
  s.begin(3, safety::crc32("abc", 3), 5);
  TEST_ASSERT_TRUE(s.rx.poll(5u + 30000u));
  s.rx.abort();
  TEST_ASSERT_TRUE(s.rx.commit(0) == RxErr::NO_BEGIN);
  s.begin(3, safety::crc32("abc", 3), 50000);
  TEST_ASSERT_TRUE(s.rx.data("YWJj", 50001) == RxErr::OK);
  TEST_ASSERT_TRUE(s.rx.commit(50002) == RxErr::OK);
  // 49,7 gün kesintisiz yoklanan boşta durum hiçbir zaman zaman aşımı üretmez
  TplRx idle;
  for (uint64_t t = 0; t < 0x100000000ULL; t += 3600000ULL) TEST_ASSERT_FALSE(idle.poll((uint32_t)t));
}

int main(int, char**) {
  UNITY_BEGIN();
  RUN_TEST(test_crc32_matches_zlib_known_values);
  RUN_TEST(test_begin_argument_rules);
  RUN_TEST(test_roundtrip_for_many_sizes_and_unaligned_chunks);
  RUN_TEST(test_crc_mismatch_size_short_and_overflow);
  RUN_TEST(test_invalid_base64_and_data_after_padding);
  RUN_TEST(test_data_and_commit_without_begin);
  RUN_TEST(test_timeout_after_30s_reported_once_on_next_command);
  return UNITY_END();
}
