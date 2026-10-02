// ============================================================================
// ApAccess (src/ApAccess.h) birim testleri:  pio test -e native -f test_ap_access
//
// Wi-Fi servis akışı için AP KAYNAKLI yetkilendirme kararı (CONTRACTS 3d): teknisyen müşteride panonun kurtarma
// ağındayken internet YOKTUR; GET /api/wifi/scan, POST /api/wifi/connect ve GET /api/wifi/status için geçerli
// X-Device-Key YA DA (istemci SoftAP arayüzünde + AP şu an WPA2 + geçerli ap_pass + provizyonlu) yeterlidir.
// Bu testler:
//   * karar fonksiyonunun TÜM 32 girdi birleşimini (elle yazılmış tablo + bağımsız özellik denetimi),
//   * "istemci SoftAP arayüzünde mi" alt ağ kararını (STA alt ağı çakışması, sıfır/geçersiz adresler, bayt sırası),
//   * AP kaynaklı anahtarsız connect için global hız sınırını (dakikada 6, Retry-After, kayan pencere, sarma tabanları,
//     60 günlük sessizlik) doğrular.
// ============================================================================
#include <unity.h>
#include <stdint.h>
#include "ApAccess.h"

using namespace ApAccess;

void setUp(void) {}
void tearDown(void) {}

namespace {

#define CHECK(code, cond) \
  do {                    \
    if (!(cond)) return (code); \
  } while (0)

// IPAddress -> uint32_t gösterimi (ilk sekizli en düşük bayt) ve ters (ağ sırası) gösterim: sonuç ikisinde de aynı olmalı.
uint32_t ipLE(uint8_t a, uint8_t b, uint8_t c, uint8_t d) {
  return (uint32_t)a | ((uint32_t)b << 8) | ((uint32_t)c << 16) | ((uint32_t)d << 24);
}
uint32_t ipBE(uint8_t a, uint8_t b, uint8_t c, uint8_t d) {
  return ((uint32_t)a << 24) | ((uint32_t)b << 16) | ((uint32_t)c << 8) | (uint32_t)d;
}

// ---------------------------------------------------------------------------------------------------------------
// 1) Karar tablosu: (clientOnAp, apIsWpa2, hasApPass, provisioned, hasValidKey) -> izin / nasıl
// ---------------------------------------------------------------------------------------------------------------
struct Row {
  bool onAp;
  bool wpa2;
  bool apPass;
  bool prov;
  bool key;
  bool expectAllowed;
  Via expectVia;
};

// 32 birleşimin TAMAMI elle yazılmıştır (sıra: provizyonsuz 16, provizyonlu+anahtar 8, provizyonlu+anahtarsız 8).
//   onAp  wpa2  apPw  prov  key   izin   nasıl
const Row kTable[32] = {
    // ---- provizyonsuz cihaz (local_key yok): HİÇBİR yol açık değil. "Geçerli anahtar" bu durumda var olamaz;
    //      imkânsız birleşim (key=1) de REDDEDİLİR (kapalı başarısızlık). Açık kurulum AP'sinde yalnız factory/init + kısıtlı status. ----
    {false, false, false, false, false, false, VIA_DENIED},
    {false, false, false, false, true, false, VIA_DENIED},
    {false, false, true, false, false, false, VIA_DENIED},
    {false, false, true, false, true, false, VIA_DENIED},
    {false, true, false, false, false, false, VIA_DENIED},
    {false, true, false, false, true, false, VIA_DENIED},
    {false, true, true, false, false, false, VIA_DENIED},
    {false, true, true, false, true, false, VIA_DENIED},
    {true, false, false, false, false, false, VIA_DENIED},   // açık kurulum AP'sindeki istemci (provizyonsuz)
    {true, false, false, false, true, false, VIA_DENIED},
    {true, false, true, false, false, false, VIA_DENIED},
    {true, false, true, false, true, false, VIA_DENIED},
    {true, true, false, false, false, false, VIA_DENIED},
    {true, true, false, false, true, false, VIA_DENIED},
    {true, true, true, false, false, false, VIA_DENIED},     // WPA2 + ap_pass + AP istemcisi ama provizyonsuz: RET
    {true, true, true, false, true, false, VIA_DENIED},
    // ---- provizyonlu + GEÇERLİ ANAHTAR: her koşulda İZİN (anahtarla) ----
    {false, false, false, true, true, true, VIA_KEY},
    {false, false, true, true, true, true, VIA_KEY},
    {false, true, false, true, true, true, VIA_KEY},
    {false, true, true, true, true, true, VIA_KEY},          // LAN istemcisi + anahtar
    {true, false, false, true, true, true, VIA_KEY},
    {true, false, true, true, true, true, VIA_KEY},          // AÇIK AP'deki istemci + anahtar
    {true, true, false, true, true, true, VIA_KEY},
    {true, true, true, true, true, true, VIA_KEY},           // AP istemcisi + anahtar: anahtarlı sayılır (hız sınırı yok)
    // ---- provizyonlu + ANAHTARSIZ: yalnızca (AP istemcisi && AP WPA2 && ap_pass) İZİN ----
    {false, false, false, true, false, false, VIA_DENIED},   // AP dışı + anahtarsız = RET
    {false, false, true, true, false, false, VIA_DENIED},
    {false, true, false, true, false, false, VIA_DENIED},
    {false, true, true, true, false, false, VIA_DENIED},     // WPA2 AP açık ama istemci AP'de değil (LAN) = RET
    {true, false, false, true, false, false, VIA_DENIED},
    {true, false, true, true, false, false, VIA_DENIED},     // AÇIK AP + anahtarsız = RET (provizyon penceresi)
    {true, true, false, true, false, false, VIA_DENIED},     // WPA2 ama geçerli ap_pass yok = RET
    {true, true, true, true, false, true, VIA_AP},           // WPA2 AP + provizyonlu + AP istemcisi + anahtarsız = İZİN
};

// 0 = hepsi doğru; aksi halde (satır numarası, 1 tabanlı)
int tableFirstBadRow(void) {
  for (int i = 0; i < 32; i++) {
    const Row& r = kTable[i];
    const bool a = allowed(r.onAp, r.wpa2, r.apPass, r.prov, r.key);
    const Via v = via(r.onAp, r.wpa2, r.apPass, r.prov, r.key);
    if (a != r.expectAllowed || v != r.expectVia) return i + 1;
  }
  return 0;
}

// Tablo gerçekten 32 FARKLI birleşimi kapsıyor mu? 0 = evet; aksi halde ilk tekrar eden satır (1 tabanlı)
int tableFirstDuplicateRow(void) {
  bool seen[32];
  for (int i = 0; i < 32; i++) seen[i] = false;
  for (int i = 0; i < 32; i++) {
    const Row& r = kTable[i];
    const int code = (r.onAp ? 16 : 0) | (r.wpa2 ? 8 : 0) | (r.apPass ? 4 : 0) | (r.prov ? 2 : 0) | (r.key ? 1 : 0);
    if (seen[code]) return i + 1;
    seen[code] = true;
  }
  return 0;
}

// Tablodan BAĞIMSIZ özellik denetimi: 5 bitin tüm birleşimleri için kural ifadeleri (farklı yapıda yazılmıştır).
int propertiesFirstViolation(void) {
  for (int m = 0; m < 32; m++) {
    const bool onAp = (m & 16) != 0, wpa2 = (m & 8) != 0, apPass = (m & 4) != 0, prov = (m & 2) != 0, key = (m & 1) != 0;
    const bool a = allowed(onAp, wpa2, apPass, prov, key);
    const Via v = via(onAp, wpa2, apPass, prov, key);
    // P1: provizyonsuz -> hiçbir şey açık değil
    if (!prov && (a || v != VIA_DENIED)) return 100 + m;
    // P2: provizyonlu + geçerli anahtar -> her koşulda izin ve "anahtarla"
    if (prov && key && (!a || v != VIA_KEY)) return 200 + m;
    // P3: provizyonlu + anahtarsız -> izin ancak ve ancak AP istemcisi && WPA2 && ap_pass
    if (prov && !key) {
      const bool expect = onAp && wpa2 && apPass;
      if (a != expect) return 300 + m;
      if (a && v != VIA_AP) return 400 + m;
      if (!a && v != VIA_DENIED) return 500 + m;
    }
    // P4: allowed() ile via() daima tutarlı
    if (a != (v != VIA_DENIED)) return 600 + m;
    // P5: AP kaynaklı yolun yardımcısı: apOrigin yalnızca dört koşulun HEPSİYLE true
    const bool ao = apOrigin(onAp, wpa2, apPass, prov);
    if (ao != (onAp && wpa2 && apPass && prov)) return 700 + m;
  }
  return 0;
}

// ---------------------------------------------------------------------------------------------------------------
// 2) İstemci SoftAP arayüzünde mi
// ---------------------------------------------------------------------------------------------------------------
// ipFn: ipLE veya ipBE; sonuç iki gösterimde de aynı olmalı
typedef uint32_t (*IpFn)(uint8_t, uint8_t, uint8_t, uint8_t);

int subnetFirstFailure(IpFn ip) {
  const uint32_t apIp = ip(192, 168, 4, 1);
  const uint32_t m24 = ip(255, 255, 255, 0);
  const uint32_t none = 0u;

  // --- tipik: STA bağlı değil, telefon AP'de ---
  CHECK(1, clientOnSoftAp(true, ip(192, 168, 4, 2), apIp, m24, none, none));
  CHECK(2, clientOnSoftAp(true, ip(192, 168, 4, 254), apIp, m24, none, none));
  CHECK(3, clientOnSoftAp(true, ip(192, 168, 4, 100), apIp, m24, none, none));
  // --- AP alt ağı dışı: ev LAN'ı, başka özel ağlar, genel adresler ---
  CHECK(4, !clientOnSoftAp(true, ip(192, 168, 1, 50), apIp, m24, none, none));
  CHECK(5, !clientOnSoftAp(true, ip(192, 168, 5, 2), apIp, m24, none, none));
  CHECK(6, !clientOnSoftAp(true, ip(192, 168, 3, 2), apIp, m24, none, none));
  CHECK(7, !clientOnSoftAp(true, ip(10, 0, 0, 5), apIp, m24, none, none));
  CHECK(8, !clientOnSoftAp(true, ip(8, 8, 8, 8), apIp, m24, none, none));
  CHECK(9, !clientOnSoftAp(true, ip(127, 0, 0, 1), apIp, m24, none, none));
  CHECK(10, !clientOnSoftAp(true, ip(192, 168, 4 + 128, 2), apIp, m24, none, none));
  // --- AP yayında değil ---
  CHECK(11, !clientOnSoftAp(false, ip(192, 168, 4, 2), apIp, m24, none, none));
  // --- geçersiz/sıfır adresler ---
  CHECK(12, !clientOnSoftAp(true, 0u, apIp, m24, none, none));                              // uzak IP bilinmiyor (IPv6 vb.)
  CHECK(34, !clientOnSoftAp(true, 0u, ip(0, 0, 0, 1), m24, none, none));                     // "bilinmeyen" 0.0.0.0, AP alt ağına düşse bile istemci sayılmaz
  CHECK(13, !clientOnSoftAp(true, ip(192, 168, 4, 2), 0u, m24, none, none));                // AP adresi yok
  CHECK(14, !clientOnSoftAp(true, ip(192, 168, 4, 2), apIp, 0u, none, none));               // maske yok
  CHECK(15, !clientOnSoftAp(true, apIp, apIp, m24, none, none));                            // cihazın kendi adresi
  // --- STA bağlı, alt ağlar AYRI: AP istemcisi kabul, LAN istemcisi ret ---
  const uint32_t staIp = ip(192, 168, 1, 50);
  CHECK(16, clientOnSoftAp(true, ip(192, 168, 4, 2), apIp, m24, staIp, m24));
  CHECK(17, !clientOnSoftAp(true, ip(192, 168, 1, 20), apIp, m24, staIp, m24));
  CHECK(18, clientOnSoftAp(true, ip(192, 168, 4, 2), apIp, m24, ip(10, 20, 30, 40), ip(255, 0, 0, 0)));
  CHECK(19, clientOnSoftAp(true, ip(192, 168, 4, 2), apIp, m24, ip(192, 168, 5, 9), m24));          // komşu /24, çakışmaz
  // --- STA alt ağı AP alt ağıyla ÇAKIŞIYOR: ağ konumu ayırt ettirmez -> RET (kapalı başarısızlık) ---
  CHECK(20, !clientOnSoftAp(true, ip(192, 168, 4, 2), apIp, m24, ip(192, 168, 4, 77), m24));        // modem de 192.168.4.0/24
  CHECK(21, !clientOnSoftAp(true, ip(192, 168, 4, 2), apIp, m24, ip(192, 168, 4, 1), m24));         // aynı adres
  CHECK(22, !clientOnSoftAp(true, ip(192, 168, 4, 2), apIp, m24, ip(192, 168, 7, 7), ip(255, 255, 0, 0)));    // STA /16, AP /24'ü kapsar
  CHECK(23, !clientOnSoftAp(true, ip(192, 168, 4, 2), apIp, m24, ip(192, 168, 4, 130), ip(255, 255, 255, 128))); // STA /25, AP /24 içinde
  CHECK(24, !clientOnSoftAp(true, ip(192, 168, 4, 2), apIp, m24, ip(192, 168, 4, 77), ip(255, 255, 255, 0)));
  CHECK(25, !clientOnSoftAp(true, ip(192, 168, 4, 2), apIp, m24, ip(192, 0, 0, 9), ip(255, 0, 0, 0)));        // STA /8
  // --- STA IP var ama maske bilinmiyor (tutarsız durum): IP AP alt ağındaysa RET, değilse kabul ---
  CHECK(26, !clientOnSoftAp(true, ip(192, 168, 4, 2), apIp, m24, ip(192, 168, 4, 77), 0u));
  CHECK(27, clientOnSoftAp(true, ip(192, 168, 4, 2), apIp, m24, ip(192, 168, 1, 77), 0u));
  // --- bölüm yardımcıları ---
  CHECK(28, sameSubnet(ip(10, 1, 2, 3), ip(10, 1, 2, 200), m24));
  CHECK(29, !sameSubnet(ip(10, 1, 2, 3), ip(10, 1, 3, 3), m24));
  CHECK(30, !sameSubnet(ip(10, 1, 2, 3), ip(10, 1, 2, 3), 0u));
  CHECK(31, subnetsOverlap(ip(10, 0, 0, 1), ip(255, 0, 0, 0), ip(10, 5, 5, 5), m24));
  CHECK(32, !subnetsOverlap(ip(10, 0, 0, 1), ip(255, 0, 0, 0), ip(11, 5, 5, 5), m24));
  CHECK(33, !subnetsOverlap(ip(10, 0, 0, 1), 0u, ip(10, 5, 5, 5), m24));
  return 0;
}

// ---------------------------------------------------------------------------------------------------------------
// 3) ConnectLimiter: dakikada en çok 6 (kayan pencere), Retry-After, sarma, uzun sessizlik
// ---------------------------------------------------------------------------------------------------------------
const uint32_t kBases[] = {0u, 5000u, 0x40000000u, 0x7FFFFFF0u, 0x80000000u, 0xFFFFF000u, 0xFFFFFFF0u};
const int kNumBases = (int)(sizeof(kBases) / sizeof(kBases[0]));

// 0 = tamam; aksi halde başarısız kontrol kodu
int limiterBurstAndSlidingWindow(uint32_t base) {
  ConnectLimiter lim;
  uint32_t ra = 0;
  // t=0: 6 istek hemen kabul (aynı anda)
  for (int i = 0; i < 6; i++) {
    CHECK(1, lim.tryAcquire(base, ra));
  }
  CHECK(2, lim.used() == 6);
  // 7. istek: ret, Retry-After = 60
  ra = 0;
  CHECK(3, !lim.tryAcquire(base, ra));
  CHECK(4, ra == 60);
  // 1 sn sonra: ret, Retry-After = 59
  ra = 0;
  CHECK(5, !lim.tryAcquire(base + 1000u, ra));
  CHECK(6, ra == 59);
  // reddedilen denemeler yuva TÜKETMEZ ve pencereyi UZATMAZ
  CHECK(7, lim.used() == 6);
  ra = 0;
  CHECK(8, !lim.tryAcquire(base + 59999u, ra));
  CHECK(9, ra == 1);
  // tam 60 sn sonra tüm yuvalar boşalır: 6 yeni istek
  for (int i = 0; i < 6; i++) {
    CHECK(10, lim.tryAcquire(base + 60000u, ra));
  }
  CHECK(11, !lim.tryAcquire(base + 60000u, ra));

  // Kayan pencere: 10 sn arayla 6 istek; ilk yuva 60. sn'de boşalır, YALNIZ bir yeni istek kabul edilir
  ConnectLimiter s;
  for (int i = 0; i < 6; i++) {
    CHECK(20, s.tryAcquire(base + (uint32_t)i * 10000u, ra));   // t = 0,10,20,30,40,50
  }
  ra = 0;
  CHECK(21, !s.tryAcquire(base + 55000u, ra));
  CHECK(22, ra == 5);                                           // en erken boşalacak yuva t=0'dan: 60 - 55 = 5
  CHECK(23, s.tryAcquire(base + 60000u, ra));                   // t=0 yuvası doldu
  ra = 0;
  CHECK(24, !s.tryAcquire(base + 60000u, ra));
  CHECK(25, ra == 10);                                          // sıradaki: t=10'un yuvası, 70. sn
  CHECK(26, !s.tryAcquire(base + 69999u, ra));
  CHECK(27, s.tryAcquire(base + 70000u, ra));
  CHECK(28, !s.tryAcquire(base + 70000u, ra));
  return 0;
}

// Her tur service() ile 60 gün: yuvalar sonlanır, sarma "taze" göstermez, sınırlayıcı donmaz
int limiterPolledSixtyDays(uint32_t base) {
  ConnectLimiter lim;
  uint32_t ra = 0;
  uint64_t t = 0;
  const uint64_t end = 60ull * 86400000ull;
  uint32_t cycles = 0;
  while (t < end) {
    const uint32_t now = base + (uint32_t)t;   // 32 bit sarar
    lim.service(now);
    // 6 kabul, 7. ret
    for (int i = 0; i < 6; i++) {
      CHECK(1, lim.tryAcquire(now, ra));
    }
    CHECK(2, !lim.tryAcquire(now, ra));
    CHECK(3, ra == 60);
    // Sessizlik: 60 sn adımlarla yoklanır (kaba adım; sınırlar 2^31 ms'in çok altında)
    const uint64_t next = t + 5ull * 3600ull * 1000ull + 60000ull;   // yaklaşık 5 saat sonra yeniden istek
    while (t < next && t < end) {
      t += 60000u;
      lim.service(base + (uint32_t)t);
    }
    CHECK(4, lim.used() == 0);                  // sessizlikte tüm yuvalar sonlandı
    cycles++;
  }
  CHECK(5, cycles > 100);
  return 0;
}

// YOKLAMA YOK (service hiç çağrılmaz): tryAcquire kendi içinde yoklar; 49,7 günden kısa sessizlikte doğru çalışır
int limiterWithoutPollingAfterLongQuiet(uint32_t base) {
  const uint64_t quiet[] = {61000ull, 3600ull * 1000ull, 24ull * 86400000ull + 20ull * 3600000ull,
                            25ull * 86400000ull, 30ull * 86400000ull, 0x100000000ull - 1000ull};
  for (unsigned k = 0; k < sizeof(quiet) / sizeof(quiet[0]); k++) {
    ConnectLimiter lim;
    uint32_t ra = 0;
    for (int i = 0; i < 6; i++) {
      CHECK(1, lim.tryAcquire(base, ra));
    }
    CHECK(2, !lim.tryAcquire(base + 1000u, ra));
    const uint32_t later = base + (uint32_t)quiet[k];   // 32 bit sarma dahil
    CHECK(3, lim.tryAcquire(later, ra));                 // sessizlikten sonra yeniden izin
    CHECK(4, lim.used() == 1);
  }
  return 0;
}

// ---------------------------------------------------------------------------------------------------------------
// Test fonksiyonları
// ---------------------------------------------------------------------------------------------------------------
void test_decision_table_32_combinations_hand_written(void) {
  TEST_ASSERT_EQUAL_INT(0, tableFirstDuplicateRow());   // tablo 32 farklı birleşimi kapsıyor
  TEST_ASSERT_EQUAL_INT(0, tableFirstBadRow());
}

void test_decision_properties_hold_for_every_input_combination(void) {
  TEST_ASSERT_EQUAL_INT(0, propertiesFirstViolation());
}

void test_non_ap_client_without_key_is_rejected(void) {
  // AP dışı (LAN / internet) + anahtarsız: her AP/provizyon durumunda RET
  for (int m = 0; m < 8; m++) {
    const bool wpa2 = (m & 4) != 0, apPass = (m & 2) != 0, prov = (m & 1) != 0;
    TEST_ASSERT_FALSE(allowed(false, wpa2, apPass, prov, false));
    TEST_ASSERT_EQUAL_INT(VIA_DENIED, via(false, wpa2, apPass, prov, false));
  }
}

void test_open_ap_without_key_is_rejected_even_when_provisioned(void) {
  // provizyon penceresindeki AÇIK kurulum AP'si: anahtarsız yol KAPALI (factory/init + kısıtlı status dışında)
  TEST_ASSERT_FALSE(allowed(true, false, true, true, false));
  TEST_ASSERT_FALSE(allowed(true, false, false, true, false));
  TEST_ASSERT_FALSE(allowed(true, false, false, false, false));
  // factory/init ile provizyonlanmış ama AP henüz WPA2'ye dönmemiş (~1,5 sn): hâlâ RET
  TEST_ASSERT_FALSE(allowed(true, false, true, true, false));
}

void test_wpa2_ap_provisioned_client_without_key_is_allowed(void) {
  TEST_ASSERT_TRUE(allowed(true, true, true, true, false));
  TEST_ASSERT_EQUAL_INT(VIA_AP, via(true, true, true, true, false));
}

void test_wpa2_ap_without_valid_ap_pass_is_rejected(void) {
  TEST_ASSERT_FALSE(allowed(true, true, false, true, false));
}

void test_unprovisioned_device_rejects_everything_including_impossible_key(void) {
  for (int m = 0; m < 8; m++) {
    const bool onAp = (m & 4) != 0, wpa2 = (m & 2) != 0, apPass = (m & 1) != 0;
    TEST_ASSERT_FALSE(allowed(onAp, wpa2, apPass, false, false));
    TEST_ASSERT_FALSE(allowed(onAp, wpa2, apPass, false, true));   // imkânsız birleşim: kapalı başarısızlık
  }
}

void test_valid_key_is_allowed_in_every_condition_when_provisioned(void) {
  for (int m = 0; m < 8; m++) {
    const bool onAp = (m & 4) != 0, wpa2 = (m & 2) != 0, apPass = (m & 1) != 0;
    TEST_ASSERT_TRUE(allowed(onAp, wpa2, apPass, true, true));
    TEST_ASSERT_EQUAL_INT(VIA_KEY, via(onAp, wpa2, apPass, true, true));
  }
}

void test_valid_key_on_ap_counts_as_keyed_not_ap_origin(void) {
  // AP istemcisi geçerli anahtar da sunduysa "anahtarlı" sayılır -> hız sınırı uygulanmaz
  TEST_ASSERT_EQUAL_INT(VIA_KEY, via(true, true, true, true, true));
  TEST_ASSERT_EQUAL_INT(VIA_AP, via(true, true, true, true, false));
}

void test_client_on_softap_subnet_rules_little_endian_representation(void) {
  TEST_ASSERT_EQUAL_INT(0, subnetFirstFailure(ipLE));
}

void test_client_on_softap_subnet_rules_are_byte_order_independent(void) {
  TEST_ASSERT_EQUAL_INT(0, subnetFirstFailure(ipBE));
}

void test_connect_limiter_six_per_minute_sliding_window_and_retry_after(void) {
  for (int b = 0; b < kNumBases; b++) {
    TEST_ASSERT_EQUAL_INT(0, limiterBurstAndSlidingWindow(kBases[b]));
  }
}

void test_connect_limiter_is_not_frozen_over_60_days_polled(void) {
  TEST_ASSERT_EQUAL_INT(0, limiterPolledSixtyDays(0u));
  TEST_ASSERT_EQUAL_INT(0, limiterPolledSixtyDays(0x7FFFF000u));
  TEST_ASSERT_EQUAL_INT(0, limiterPolledSixtyDays(0xFFFF0000u));
}

void test_connect_limiter_works_after_long_quiet_without_polling(void) {
  for (int b = 0; b < kNumBases; b++) {
    TEST_ASSERT_EQUAL_INT(0, limiterWithoutPollingAfterLongQuiet(kBases[b]));
  }
}

void test_keyed_requests_do_not_consume_the_ap_connect_budget(void) {
  // WebPortal akışı: yalnız VIA_AP yolu sınırlayıcıya girer; anahtarlı istekler girmez.
  ConnectLimiter lim;
  uint32_t ra = 0;
  int apAccepted = 0, apDenied = 0, keyed = 0;
  for (int i = 0; i < 40; i++) {
    const bool sendKey = (i % 2 == 0);   // yarısı geçerli anahtarlı
    const Via v = via(true, true, true, true, sendKey);
    if (v == VIA_KEY) {
      keyed++;
    } else if (v == VIA_AP) {
      if (lim.tryAcquire(1000u + (uint32_t)i, ra)) apAccepted++;
      else apDenied++;
    }
  }
  TEST_ASSERT_EQUAL_INT(20, keyed);       // anahtarlı 20 istek sınırsız
  TEST_ASSERT_EQUAL_INT(6, apAccepted);   // anahtarsız AP yolu: 60 sn içinde en çok 6
  TEST_ASSERT_EQUAL_INT(14, apDenied);
  TEST_ASSERT_TRUE(ra >= 1 && ra <= 60);
}

}  // namespace

int main(int, char**) {
  UNITY_BEGIN();
  RUN_TEST(test_decision_table_32_combinations_hand_written);
  RUN_TEST(test_decision_properties_hold_for_every_input_combination);
  RUN_TEST(test_non_ap_client_without_key_is_rejected);
  RUN_TEST(test_open_ap_without_key_is_rejected_even_when_provisioned);
  RUN_TEST(test_wpa2_ap_provisioned_client_without_key_is_allowed);
  RUN_TEST(test_wpa2_ap_without_valid_ap_pass_is_rejected);
  RUN_TEST(test_unprovisioned_device_rejects_everything_including_impossible_key);
  RUN_TEST(test_valid_key_is_allowed_in_every_condition_when_provisioned);
  RUN_TEST(test_valid_key_on_ap_counts_as_keyed_not_ap_origin);
  RUN_TEST(test_client_on_softap_subnet_rules_little_endian_representation);
  RUN_TEST(test_client_on_softap_subnet_rules_are_byte_order_independent);
  RUN_TEST(test_connect_limiter_six_per_minute_sliding_window_and_retry_after);
  RUN_TEST(test_connect_limiter_is_not_frozen_over_60_days_polled);
  RUN_TEST(test_connect_limiter_works_after_long_quiet_without_polling);
  RUN_TEST(test_keyed_requests_do_not_consume_the_ap_connect_budget);
  return UNITY_END();
}
