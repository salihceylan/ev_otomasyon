// ============================================================================
// LocalKeyFp (src/LocalKeyFp.h) birim testleri:  pio test -e native -f test_lk_fp
//
// pano-5 / sözleşme 1 (lk_fp): HMAC-SHA256(anahtar = local_key ASCII, ileti = "ahbu-lk-fp/1|" + büyük harfli UID) çıktısının küçük harf hex
// gösteriminin ilk 8 karakteri. Cihazda HMAC mbedtls_md_hmac'tir (ConfigManager::localKeyFp); PC'de mbedtls yok: aynı bileşim
// (lkfp::compute) burada TESTE ÖZGÜ başvuru SHA-256/HMAC'iyle (FIPS 180-4, RFC 2104) sınanır. Başvuru uygulamasının kendisi önce bilinen
// vektörlerle (SHA-256("abc"), RFC 4231 durum 2) doğrulanır; ardından sözleşmenin ortak test vektörleri (sunucu, simülatör ve araç testleriyle
// aynı) beklenir.
// ============================================================================
#include <unity.h>
#include <stdint.h>
#include <string.h>
#include "LocalKeyFp.h"

void setUp(void) {}
void tearDown(void) {}

namespace {

// ---- Teste özgü başvuru SHA-256 / HMAC-SHA256 (firmware'e girmez) -----------------------------------------------------------------
struct RefSha256 {
  uint32_t h[8];
  uint8_t buf[64];
  uint64_t len;
  size_t n;
  static uint32_t rotr(uint32_t x, int r) { return (x >> r) | (x << (32 - r)); }
  void init() {
    static const uint32_t iv[8] = {0x6a09e667u, 0xbb67ae85u, 0x3c6ef372u, 0xa54ff53au, 0x510e527fu, 0x9b05688cu, 0x1f83d9abu, 0x5be0cd19u};
    memcpy(h, iv, sizeof(h));
    len = 0;
    n = 0;
  }
  void block(const uint8_t* p) {
    static const uint32_t k[64] = {
        0x428a2f98u, 0x71374491u, 0xb5c0fbcfu, 0xe9b5dba5u, 0x3956c25bu, 0x59f111f1u, 0x923f82a4u, 0xab1c5ed5u,
        0xd807aa98u, 0x12835b01u, 0x243185beu, 0x550c7dc3u, 0x72be5d74u, 0x80deb1feu, 0x9bdc06a7u, 0xc19bf174u,
        0xe49b69c1u, 0xefbe4786u, 0x0fc19dc6u, 0x240ca1ccu, 0x2de92c6fu, 0x4a7484aau, 0x5cb0a9dcu, 0x76f988dau,
        0x983e5152u, 0xa831c66du, 0xb00327c8u, 0xbf597fc7u, 0xc6e00bf3u, 0xd5a79147u, 0x06ca6351u, 0x14292967u,
        0x27b70a85u, 0x2e1b2138u, 0x4d2c6dfcu, 0x53380d13u, 0x650a7354u, 0x766a0abbu, 0x81c2c92eu, 0x92722c85u,
        0xa2bfe8a1u, 0xa81a664bu, 0xc24b8b70u, 0xc76c51a3u, 0xd192e819u, 0xd6990624u, 0xf40e3585u, 0x106aa070u,
        0x19a4c116u, 0x1e376c08u, 0x2748774cu, 0x34b0bcb5u, 0x391c0cb3u, 0x4ed8aa4au, 0x5b9cca4fu, 0x682e6ff3u,
        0x748f82eeu, 0x78a5636fu, 0x84c87814u, 0x8cc70208u, 0x90befffau, 0xa4506cebu, 0xbef9a3f7u, 0xc67178f2u};
    uint32_t w[64];
    for (int i = 0; i < 16; i++) {
      w[i] = ((uint32_t)p[4 * i] << 24) | ((uint32_t)p[4 * i + 1] << 16) | ((uint32_t)p[4 * i + 2] << 8) | (uint32_t)p[4 * i + 3];
    }
    for (int i = 16; i < 64; i++) {
      const uint32_t s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
      const uint32_t s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
      w[i] = w[i - 16] + s0 + w[i - 7] + s1;
    }
    uint32_t a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7];
    for (int i = 0; i < 64; i++) {
      const uint32_t S1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
      const uint32_t ch = (e & f) ^ (~e & g);
      const uint32_t t1 = hh + S1 + ch + k[i] + w[i];
      const uint32_t S0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
      const uint32_t mj = (a & b) ^ (a & c) ^ (b & c);
      const uint32_t t2 = S0 + mj;
      hh = g;
      g = f;
      f = e;
      e = d + t1;
      d = c;
      c = b;
      b = a;
      a = t1 + t2;
    }
    h[0] += a; h[1] += b; h[2] += c; h[3] += d; h[4] += e; h[5] += f; h[6] += g; h[7] += hh;
  }
  void update(const uint8_t* p, size_t l) {
    len += l;
    while (l) {
      size_t t = 64 - n;
      if (t > l) t = l;
      memcpy(buf + n, p, t);
      n += t;
      p += t;
      l -= t;
      if (n == 64) {
        block(buf);
        n = 0;
      }
    }
  }
  void final(uint8_t out[32]) {
    const uint64_t bits = len * 8;
    const uint8_t pad = 0x80, z = 0;
    update(&pad, 1);
    while (n != 56) update(&z, 1);
    uint8_t lb[8];
    for (int i = 0; i < 8; i++) lb[i] = (uint8_t)(bits >> (56 - 8 * i));
    update(lb, 8);
    for (int i = 0; i < 8; i++) {
      out[4 * i] = (uint8_t)(h[i] >> 24);
      out[4 * i + 1] = (uint8_t)(h[i] >> 16);
      out[4 * i + 2] = (uint8_t)(h[i] >> 8);
      out[4 * i + 3] = (uint8_t)h[i];
    }
  }
};

void refSha256(const uint8_t* m, size_t l, uint8_t out[32]) {
  RefSha256 s;
  s.init();
  s.update(m, l);
  s.final(out);
}

// RFC 2104 (anahtar <= 64 bayt: yerel anahtar 8..32).
bool refHmac(const uint8_t* key, size_t kl, const uint8_t* msg, size_t ml, uint8_t* out) {
  if (kl > 64) return false;
  uint8_t k0[64];
  memset(k0, 0, sizeof(k0));
  memcpy(k0, key, kl);
  uint8_t pad[64];
  uint8_t inner[32];
  RefSha256 s;
  for (int i = 0; i < 64; i++) pad[i] = (uint8_t)(k0[i] ^ 0x36);
  s.init();
  s.update(pad, 64);
  s.update(msg, ml);
  s.final(inner);
  for (int i = 0; i < 64; i++) pad[i] = (uint8_t)(k0[i] ^ 0x5c);
  s.init();
  s.update(pad, 64);
  s.update(inner, 32);
  s.final(out);
  return true;
}

void hex(const uint8_t* p, size_t n, char* out) {
  static const char hx[] = "0123456789abcdef";
  for (size_t i = 0; i < n; i++) {
    out[2 * i] = hx[p[i] >> 4];
    out[2 * i + 1] = hx[p[i] & 0x0F];
  }
  out[2 * n] = '\0';
}

bool failingHmac(const uint8_t*, size_t, const uint8_t*, size_t, uint8_t* out) {
  memset(out, 0xAB, 32);
  return false;
}

}  // namespace

void test_reference_sha256_and_hmac_match_known_vectors(void) {
  uint8_t d[32];
  char t[65];
  refSha256((const uint8_t*)"abc", 3, d);
  hex(d, 32, t);
  TEST_ASSERT_EQUAL_STRING("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", t);
  const char* m = "what do ya want for nothing?";
  TEST_ASSERT_TRUE(refHmac((const uint8_t*)"Jefe", 4, (const uint8_t*)m, strlen(m), d));
  hex(d, 32, t);
  TEST_ASSERT_EQUAL_STRING("5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843", t);   // RFC 4231 durum 2
}

void test_message_is_prefix_plus_uppercased_uid(void) {
  char m[lkfp::MSG_MAX + 1];
  TEST_ASSERT_EQUAL_UINT32(27, (uint32_t)lkfp::buildMessage(m, sizeof(m), "AHBU-S3-DD8754"));
  TEST_ASSERT_EQUAL_STRING("ahbu-lk-fp/1|AHBU-S3-DD8754", m);
  TEST_ASSERT_EQUAL_UINT32(27, (uint32_t)lkfp::buildMessage(m, sizeof(m), "ahbu-s3-0a1b2c"));
  TEST_ASSERT_EQUAL_STRING("ahbu-lk-fp/1|AHBU-S3-0A1B2C", m);   // yalnız UID büyütülür; önek küçük harf kalır
  // boş / çok uzun UID ya da sığmayan tampon: 0, yarım ileti yok
  TEST_ASSERT_EQUAL_UINT32(0, (uint32_t)lkfp::buildMessage(m, sizeof(m), ""));
  TEST_ASSERT_EQUAL_UINT32(0, (uint32_t)lkfp::buildMessage(m, sizeof(m), nullptr));
  char longUid[lkfp::UID_MAX + 2];
  memset(longUid, 'A', sizeof(longUid) - 1);
  longUid[sizeof(longUid) - 1] = '\0';
  TEST_ASSERT_EQUAL_UINT32(0, (uint32_t)lkfp::buildMessage(m, sizeof(m), longUid));
  char small[27];
  TEST_ASSERT_EQUAL_UINT32(0, (uint32_t)lkfp::buildMessage(small, sizeof(small), "AHBU-S3-DD8754"));
  char exact[28];
  TEST_ASSERT_EQUAL_UINT32(27, (uint32_t)lkfp::buildMessage(exact, sizeof(exact), "AHBU-S3-DD8754"));
}

void test_hex8_is_first_four_bytes_lowercase(void) {
  const uint8_t mac[32] = {0xC7, 0x07, 0x65, 0x62, 0xFF, 0xEE};
  char fp[lkfp::FP_BUF];
  memset(fp, 'x', sizeof(fp));
  lkfp::toHex8(mac, fp);
  TEST_ASSERT_EQUAL_STRING("c7076562", fp);
  TEST_ASSERT_TRUE(lkfp::valid("c7076562"));
  TEST_ASSERT_TRUE(lkfp::valid("0000abcd"));
  TEST_ASSERT_FALSE(lkfp::valid("C7076562"));     // büyük harf geçersiz (sözleşme: /^[0-9a-f]{8}$/)
  TEST_ASSERT_FALSE(lkfp::valid("c707656"));
  TEST_ASSERT_FALSE(lkfp::valid("c70765621"));
  TEST_ASSERT_FALSE(lkfp::valid("c70765g2"));
  TEST_ASSERT_FALSE(lkfp::valid(""));
  TEST_ASSERT_FALSE(lkfp::valid(nullptr));
}

void test_contract_vectors(void) {
  char fp[lkfp::FP_BUF];
  TEST_ASSERT_TRUE(lkfp::compute("ABCDEFGH23456789", "AHBU-S3-DD8754", fp, refHmac));
  TEST_ASSERT_EQUAL_STRING("c7076562", fp);
  TEST_ASSERT_TRUE(lkfp::compute("k3yTEST-9999", "AHBU-S3-0A1B2C", fp, refHmac));
  TEST_ASSERT_EQUAL_STRING("9814f286", fp);
  TEST_ASSERT_TRUE(lkfp::compute("k3yTEST-9999", "ahbu-s3-0a1b2c", fp, refHmac));   // UID küçük harfle gelse de aynı iz
  TEST_ASSERT_EQUAL_STRING("9814f286", fp);
}

void test_no_key_or_failed_hmac_gives_empty_fp(void) {
  char fp[lkfp::FP_BUF];
  memset(fp, 'x', sizeof(fp));
  TEST_ASSERT_FALSE(lkfp::compute("", "AHBU-S3-DD8754", fp, refHmac));     // provizyonsuz: iz yok
  TEST_ASSERT_EQUAL_STRING("", fp);
  memset(fp, 'x', sizeof(fp));
  TEST_ASSERT_FALSE(lkfp::compute(nullptr, "AHBU-S3-DD8754", fp, refHmac));
  TEST_ASSERT_EQUAL_STRING("", fp);
  memset(fp, 'x', sizeof(fp));
  TEST_ASSERT_FALSE(lkfp::compute("ABCDEFGH23456789", "", fp, refHmac));   // UID yok
  TEST_ASSERT_EQUAL_STRING("", fp);
  memset(fp, 'x', sizeof(fp));
  TEST_ASSERT_FALSE(lkfp::compute("ABCDEFGH23456789", "AHBU-S3-DD8754", fp, failingHmac));
  TEST_ASSERT_EQUAL_STRING("", fp);                                          // HMAC hatası: yarım/çöp iz yazılmaz
}

int main(int, char**) {
  UNITY_BEGIN();
  RUN_TEST(test_reference_sha256_and_hmac_match_known_vectors);
  RUN_TEST(test_message_is_prefix_plus_uppercased_uid);
  RUN_TEST(test_hex8_is_first_four_bytes_lowercase);
  RUN_TEST(test_contract_vectors);
  RUN_TEST(test_no_key_or_failed_hmac_gives_empty_fp);
  return UNITY_END();
}
