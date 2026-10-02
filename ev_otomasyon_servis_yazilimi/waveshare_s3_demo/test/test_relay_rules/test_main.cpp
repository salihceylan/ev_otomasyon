// ============================================================================
// InterlockGuard (src/RelayRules.h) birim testleri:  pio test -e native -f test_relay_rules
// Surucu seviyesi emniyet: panjur ciftinde iki yon ayni anda enerjilenemez, dogrudan yon degisimi
// yapilamaz, bir kapanmadan sonra 500 ms dolmadan yeniden enerjilenemez.
// ============================================================================
#include <unity.h>
#include <stdint.h>
#include "RelayRules.h"

void setUp(void) {}
void tearDown(void) {}

// Maske yardimcilari: bit i = role i (0 tabanli)
static uint64_t R(int i) { return 1ULL << i; }

void test_non_shutter_pairs_are_unconstrained(void) {
  InterlockGuard g;                       // hic panjur cifti tanimli degil
  TEST_ASSERT_EQUAL_UINT8(InterlockGuard::OK, g.check(R(0) | R(1), 0));
  g.commit(R(0) | R(1), 0);
  TEST_ASSERT_EQUAL_UINT8(InterlockGuard::OK, g.check(R(0), 10));
}

void test_both_directions_on_is_rejected(void) {
  InterlockGuard g;
  g.setShutterPairs(0x01);                // cift 0 = role 0/1
  TEST_ASSERT_EQUAL_UINT8(InterlockGuard::BOTH_ON, g.check(R(0) | R(1), 0));
  TEST_ASSERT_EQUAL_UINT8(InterlockGuard::OK, g.check(R(0), 0));
  TEST_ASSERT_EQUAL_UINT8(InterlockGuard::OK, g.check(R(1), 0));
  // baska bit'ler (aydinlatma) panjur ciftini etkilemez
  TEST_ASSERT_EQUAL_UINT8(InterlockGuard::OK, g.check(R(0) | R(4) | R(5), 0));
}

void test_each_pair_independently_checked(void) {
  InterlockGuard g;
  g.setShutterPairs(0x01 | 0x02);         // cift 0 ve 1 (role 0-3)
  TEST_ASSERT_EQUAL_UINT8(InterlockGuard::BOTH_ON, g.check(R(2) | R(3), 0));
  TEST_ASSERT_EQUAL_UINT8(InterlockGuard::OK, g.check(R(1) | R(2), 0));   // 1 (cift0 asagi) ve 2 (cift1 yukari): farkli ciftler
}

void test_direct_reversal_in_single_write_is_rejected(void) {
  InterlockGuard g;
  g.setShutterPairs(0x01);
  g.commit(R(0), 1000);                   // YUKARI enerjili
  TEST_ASSERT_EQUAL_UINT8(InterlockGuard::DIRECT_REVERSAL, g.check(R(1), 1001));   // tek yazimda YUKARI->ASAGI
  TEST_ASSERT_EQUAL_UINT8(InterlockGuard::OK, g.check(0, 1001));                   // kapatmak her zaman serbest
  TEST_ASSERT_EQUAL_UINT8(InterlockGuard::OK, g.check(R(0), 1001));                // ayni yon yeniden yazimi serbest
}

void test_dead_time_is_enforced_by_driver_after_off(void) {
  InterlockGuard g;
  g.setShutterPairs(0x01);
  g.commit(R(0), 1000);
  g.commit(0, 2000);                      // 2000'de KAPANDI
  TEST_ASSERT_EQUAL_UINT8(InterlockGuard::DEAD_TIME, g.check(R(1), 2100));
  TEST_ASSERT_EQUAL_UINT8(InterlockGuard::DEAD_TIME, g.check(R(0), 2499));         // ayni yon bile 500 ms dolmadan olmaz
  TEST_ASSERT_EQUAL_UINT8(InterlockGuard::OK, g.check(R(1), 2500));
  TEST_ASSERT_EQUAL_UINT8(InterlockGuard::OK, g.check(0, 2100));                   // kapatma serbest
}

void test_dead_time_survives_millis_rollover(void) {
  InterlockGuard g;
  g.setShutterPairs(0x01);
  g.commit(R(1), 0xFFFFFF00u);
  g.commit(0, 0xFFFFFF00u);               // KAPANMA tasmaya 256 ms kala
  TEST_ASSERT_EQUAL_UINT8(InterlockGuard::DEAD_TIME, g.check(R(0), 0x00000010u));  // 272 ms
  TEST_ASSERT_EQUAL_UINT8(InterlockGuard::DEAD_TIME, g.check(R(0), 0x000000F3u));  // 499 ms
  TEST_ASSERT_EQUAL_UINT8(InterlockGuard::OK, g.check(R(0), 0x000000F4u));         // 500 ms
}

void test_dead_time_when_off_happened_at_millis_zero(void) {
  InterlockGuard g;
  g.setShutterPairs(0x01);
  g.commit(R(0), 0);
  g.commit(0, 0);                         // millis()==0 aninda kapandi (eski "t>0" bayragi bunu yok sayardi)
  TEST_ASSERT_EQUAL_UINT8(InterlockGuard::DEAD_TIME, g.check(R(1), 100));
  TEST_ASSERT_EQUAL_UINT8(InterlockGuard::OK, g.check(R(1), 500));
}

void test_first_energize_has_no_dead_time(void) {
  InterlockGuard g;
  g.setShutterPairs(0x01);
  TEST_ASSERT_EQUAL_UINT8(InterlockGuard::OK, g.check(R(0), 0));
}

void test_ext_module_pairs_use_same_rule(void) {
  InterlockGuard g;
  g.setShutterPairs(1UL << 4);            // cift 4 = role 8/9 (ek modul 1-2. kanal)
  TEST_ASSERT_EQUAL_UINT8(InterlockGuard::BOTH_ON, g.check(R(8) | R(9), 0));
  g.commit(R(8), 100);
  TEST_ASSERT_EQUAL_UINT8(InterlockGuard::DIRECT_REVERSAL, g.check(R(9), 200));
  g.commit(0, 300);
  TEST_ASSERT_EQUAL_UINT8(InterlockGuard::DEAD_TIME, g.check(R(9), 400));
  TEST_ASSERT_EQUAL_UINT8(InterlockGuard::OK, g.check(R(9), 800));
}

void test_highest_pair_index(void) {
  InterlockGuard g;
  g.setShutterPairs(1UL << 19);           // cift 19 = role 38/39 (en son)
  TEST_ASSERT_EQUAL_UINT8(InterlockGuard::BOTH_ON, g.check(R(38) | R(39), 0));
}

void test_commit_tracks_state_and_with_relay_helper(void) {
  InterlockGuard g;
  g.setShutterPairs(0x01);
  uint64_t m = InterlockGuard::withRelay(0, 0, true);
  TEST_ASSERT_TRUE(m == R(0));
  g.commit(m, 10);
  TEST_ASSERT_TRUE(g.hw() == R(0));
  m = InterlockGuard::withRelay(m, 0, false);
  TEST_ASSERT_TRUE(m == 0);
}

// noteOff(): inanilan durum zaten KAPALI olsa bile (yanki yalani / kaybolan KAPAT / baska master) onayli her KAPAT
// ciftin "son kapanma anini" yeniler: 500 ms olu zaman GERCEK kapanmadan sayilir.
void test_note_off_restamps_dead_time_even_without_believed_transition(void) {
  InterlockGuard g;
  g.setShutterPairs(0x01);
  g.commit(0, 1000);                                                    // inanc: zaten KAPALI -> gecis yok, kapanma anı kaydedilmez
  TEST_ASSERT_EQUAL_UINT8(InterlockGuard::OK, g.check(R(0), 1100));     // (bilinen kapanma yok: bekleme yok)
  g.noteOff(1, 2000);                                                   // cift 0'in AŞAĞI rolesi icin onayli KAPAT
  TEST_ASSERT_EQUAL_UINT8(InterlockGuard::DEAD_TIME, g.check(R(0), 2100));
  TEST_ASSERT_EQUAL_UINT8(InterlockGuard::DEAD_TIME, g.check(R(1), 2499));
  TEST_ASSERT_EQUAL_UINT8(InterlockGuard::OK, g.check(R(0), 2500));
  // yeniden damga: ikinci onayli KAPAT beklemeyi tekrar baslatir
  g.noteOff(0, 2400);
  TEST_ASSERT_EQUAL_UINT8(InterlockGuard::DEAD_TIME, g.check(R(1), 2800));
  TEST_ASSERT_EQUAL_UINT8(InterlockGuard::OK, g.check(R(1), 2900));
}

void test_note_off_is_millis_rollover_safe_and_ignores_non_shutter_pairs(void) {
  InterlockGuard g;
  g.setShutterPairs(0x01);                                              // yalnizca cift 0 panjur
  g.noteOff(0, 0xFFFFFFF0u);
  TEST_ASSERT_EQUAL_UINT8(InterlockGuard::DEAD_TIME, g.check(R(0), 0x00000100u));   // 0x110 = 272 ms
  TEST_ASSERT_EQUAL_UINT8(InterlockGuard::OK, g.check(R(0), 0x00000200u));          // 0x210 = 528 ms
  g.noteOff(4, 5000);                                                   // cift 2 panjur degil: kural uygulanmaz
  TEST_ASSERT_EQUAL_UINT8(InterlockGuard::OK, g.check(R(4), 5001));
  g.noteOff(39, 7);                                                     // en yuksek cift: tasma/dizin hatasi yok
  g.noteOff(40, 7);                                                     // aralik disi: sessizce yok sayilir
}

// ---------------------------------------------------------------- TCA gölge/fiziksel eşitleme (saf karar)
// Çip sıfırlanması / düşen röle ile periyodik doğrulama arasında gölge "AÇIK", donanım "KAPALI" der: yazımdan önce donanım okunur,
// gölge donanıma eşitlenir ve düşen bitler YENİDEN ÇEKİLMEZ (aksi halde ölü zamansız yeniden enerjilenirdi).
using relayrules::TcaResyncPlan;

void test_tca_resync_in_sync_does_nothing(void) {
  TcaResyncPlan p = relayrules::planTcaResync(0x05, 0x00, 0x05, 0x00);
  TEST_ASSERT_EQUAL_UINT8(TcaResyncPlan::IN_SYNC, p.kind);
  TEST_ASSERT_EQUAL_UINT8(0x05, p.newShadow);
  TEST_ASSERT_EQUAL_UINT8(0x00, p.dropped);
  TEST_ASSERT_FALSE(p.writeOut);
  TEST_ASSERT_FALSE(p.restoreConfig);
}

void test_tca_resync_dropped_relay_is_not_reasserted(void) {
  // gölge: röle 1 ve 3 AÇIK (0x05); donanım: röle 3 düşmüş (0x01) -> gölge donanıma çekilir, yazım GEREKMEZ
  TcaResyncPlan p = relayrules::planTcaResync(0x01, 0x00, 0x05, 0x00);
  TEST_ASSERT_EQUAL_UINT8(TcaResyncPlan::DROPPED, p.kind);
  TEST_ASSERT_EQUAL_UINT8(0x01, p.newShadow);
  TEST_ASSERT_EQUAL_UINT8(0x04, p.dropped);
  TEST_ASSERT_FALSE(p.writeOut);
  TEST_ASSERT_FALSE(p.restoreConfig);
}

void test_tca_resync_unexpected_on_relay_is_switched_off(void) {
  // gölge 0x01; donanım 0x41 (röle 7 kendiliğinden çekmiş, gölgede KAPALI: tehlikeli) -> kapatılır, düşen yok
  TcaResyncPlan p = relayrules::planTcaResync(0x41, 0x00, 0x01, 0x00);
  TEST_ASSERT_EQUAL_UINT8(TcaResyncPlan::FIX_EXTRA, p.kind);
  TEST_ASSERT_EQUAL_UINT8(0x01, p.newShadow);
  TEST_ASSERT_EQUAL_UINT8(0x00, p.dropped);
  TEST_ASSERT_TRUE(p.writeOut);
}

void test_tca_resync_dropped_and_extra_together_never_reasserts_dropped(void) {
  // gölge 0x05; donanım 0x41: röle 3 düşmüş + röle 7 fazla. Yazılacak değer 0x01 (gölge VE donanım): düşen röle 3 yeniden çekilmez.
  TcaResyncPlan p = relayrules::planTcaResync(0x41, 0x00, 0x05, 0x00);
  TEST_ASSERT_EQUAL_UINT8(TcaResyncPlan::DROPPED, p.kind);
  TEST_ASSERT_EQUAL_UINT8(0x01, p.newShadow);
  TEST_ASSERT_EQUAL_UINT8(0x04, p.dropped);
  TEST_ASSERT_TRUE(p.writeOut);
}

void test_tca_resync_chip_reset_drops_everything_and_restores_config(void) {
  // yön yazmacı 0xFF (hepsi giriş): gölgede AÇIK sanılan TÜM bitler düştü; önce çıkış 0x00, sonra yön geri yüklenir
  TcaResyncPlan p = relayrules::planTcaResync(0xFF, 0xFF, 0x15, 0x00);
  TEST_ASSERT_EQUAL_UINT8(TcaResyncPlan::CHIP_RESET, p.kind);
  TEST_ASSERT_EQUAL_UINT8(0x00, p.newShadow);
  TEST_ASSERT_EQUAL_UINT8(0x15, p.dropped);
  TEST_ASSERT_TRUE(p.writeOut);
  TEST_ASSERT_TRUE(p.restoreConfig);
  // boştayken sıfırlanma: düşen yok ama yön yine geri yüklenir
  TcaResyncPlan q = relayrules::planTcaResync(0xFF, 0xFF, 0x00, 0x00);
  TEST_ASSERT_EQUAL_UINT8(TcaResyncPlan::CHIP_RESET, q.kind);
  TEST_ASSERT_EQUAL_UINT8(0x00, q.dropped);
  TEST_ASSERT_TRUE(q.restoreConfig);
}

void test_tca_resync_config_mismatch_wins_even_if_outputs_match(void) {
  TcaResyncPlan p = relayrules::planTcaResync(0x05, 0x01, 0x05, 0x00);
  TEST_ASSERT_EQUAL_UINT8(TcaResyncPlan::CHIP_RESET, p.kind);
  TEST_ASSERT_EQUAL_UINT8(0x05, p.dropped);
}

void test_tca_resync_followed_by_guard_commit_restarts_dead_time_for_dropped_pair(void) {
  InterlockGuard g;
  g.setShutterPairs(0x02);                                   // cift 1 = röle 2/3
  g.commit(R(2), 100);                                       // röle 2 (cift 1 YUKARI) AÇIK sanılıyor
  TcaResyncPlan p = relayrules::planTcaResync(0x00, 0x00, 0x04, 0x00);   // donanımda düşmüş
  TEST_ASSERT_EQUAL_UINT8(0x04, p.dropped);
  g.commit(p.newShadow, 5000);                               // eşitleme anı = fiziksel kapanma anı olarak damgalanır
  TEST_ASSERT_EQUAL_UINT8(InterlockGuard::DEAD_TIME, g.check(R(2), 5100));   // yeniden çekme: ölü zaman
  TEST_ASSERT_EQUAL_UINT8(InterlockGuard::DEAD_TIME, g.check(R(3), 5499));
  TEST_ASSERT_EQUAL_UINT8(InterlockGuard::OK, g.check(R(2), 5500));
}

void test_tca_resync_physical_is_the_read_value_except_after_chip_reset(void) {
  TEST_ASSERT_EQUAL_UINT8(0x41, relayrules::planTcaResync(0x41, 0x00, 0x01, 0x00).physical);   // fazla açık bit dahil okunan değer
  TEST_ASSERT_EQUAL_UINT8(0x01, relayrules::planTcaResync(0x01, 0x00, 0x05, 0x00).physical);   // düşen bit fiziksel olarak KAPALI
  TEST_ASSERT_EQUAL_UINT8(0x05, relayrules::planTcaResync(0x05, 0x00, 0x05, 0x00).physical);   // senkron
  TEST_ASSERT_EQUAL_UINT8(0x00, relayrules::planTcaResync(0xFF, 0xFF, 0x15, 0x00).physical);   // çip sıfırlanması: pinler girişe döndü, hiçbir röle enerjili değil
}

void test_tca_resync_two_step_commit_stamps_dead_time_for_unexpected_on_shutter_relay(void) {
  // koruma: çift 0 (röle 0 YUKARI / 1 AŞAĞI) KAPALI sanılıyor; donanımda YUKARI rölesi fiziksel AÇIK (firmware bilmiyor)
  InterlockGuard g;
  g.setShutterPairs(0x01);
  g.commit(0x00, 100);
  TcaResyncPlan p = relayrules::planTcaResync(0x01, 0x00, 0x00, 0x00);
  TEST_ASSERT_EQUAL_UINT8(TcaResyncPlan::FIX_EXTRA, p.kind);
  TEST_ASSERT_EQUAL_UINT8(0x01, p.physical);
  TEST_ASSERT_EQUAL_UINT8(0x00, p.newShadow);

  // (a) yalnız newShadow işlenseydi: "KAPALIydı, KAPALI kaldı" -> kapanma damgası YOK; hemen ters yön/yeniden enerjileme serbest olurdu
  InterlockGuard naive = g;
  naive.commit(p.newShadow, 1010);
  TEST_ASSERT_EQUAL_UINT8(InterlockGuard::OK, naive.check(R(1), 1015));

  // (b) iki aşamalı: önce fiziksel gerçek (AÇIK), sonra kapatma -> AÇIK->KAPALI geçişi 1010'da damgalanır
  g.commit(p.physical, 1000);
  TEST_ASSERT_EQUAL_UINT8(InterlockGuard::DIRECT_REVERSAL, g.check(R(1), 1001));   // düzeltme yazımı yapılamadıysa ters yön gerçeğe göre reddedilir
  g.commit(p.newShadow, 1010);
  TEST_ASSERT_EQUAL_UINT8(InterlockGuard::DEAD_TIME, g.check(R(1), 1015));
  TEST_ASSERT_EQUAL_UINT8(InterlockGuard::DEAD_TIME, g.check(R(0), 1509));
  TEST_ASSERT_EQUAL_UINT8(InterlockGuard::OK, g.check(R(0), 1510));
}

void test_shutter_relay_bits_follow_pair_mask(void) {
  using relayrules::shutterRelayBits;
  TEST_ASSERT_EQUAL_UINT8(0x00, shutterRelayBits(0x00));
  TEST_ASSERT_EQUAL_UINT8(0x03, shutterRelayBits(0x01));
  TEST_ASSERT_EQUAL_UINT8(0x0C, shutterRelayBits(0x02));
  TEST_ASSERT_EQUAL_UINT8(0x33, shutterRelayBits(0x05));
  TEST_ASSERT_EQUAL_UINT8(0xFF, shutterRelayBits(0x0F));
  TEST_ASSERT_EQUAL_UINT8(0x00, shutterRelayBits(0xF0));    // yerel TCA yalnız 4 çift (8 röle): üst çiftler (harici modül) yok sayılır
}

void test_unverified_retained_shutter_bits_exclude_new_energize_and_lights(void) {
  using relayrules::unverifiedRetainedShutterBits;
  // çift 0 ve 1 panjur (bit 0..3); lamba bitleri 4..7. Gölge: röle 2 (çift 1 YUKARI) + lamba bit 4 AÇIK.
  // Yazılacak: röle 2 (KORUNAN) + röle 0 (YENİ) + lamba bit 4 (korunan) + lamba bit 5 (yeni)
  const uint8_t shadow = 0x14, mask = 0x35;
  TEST_ASSERT_EQUAL_UINT8(0x04, unverifiedRetainedShutterBits(mask, shadow, 0x03));
  // panjur çifti tanımlı değilse hiçbir bit "doğrulanamayan" sayılmaz (lamba/impulse rölesinde ölü zaman kuralı yok)
  TEST_ASSERT_EQUAL_UINT8(0x00, unverifiedRetainedShutterBits(mask, shadow, 0x00));
  // yazım KAPATMA ise (mask == 0) ya da bit gölgede zaten KAPALI ise çıkarılacak bit yok
  TEST_ASSERT_EQUAL_UINT8(0x00, unverifiedRetainedShutterBits(0x00, shadow, 0x03));
  TEST_ASSERT_EQUAL_UINT8(0x00, unverifiedRetainedShutterBits(0x01, 0x00, 0x03));
}

// ---------------------------------------------------------------- Harici modül: KAPAT yazımı gerekir mi
void test_ext_needs_off_write_rules(void) {
  using relayrules::extNeedsOffWrite;
  // açılması İSTENİYOR: asla KAPAT
  TEST_ASSERT_FALSE(extNeedsOffWrite(true, false, true, false));
  TEST_ASSERT_FALSE(extNeedsOffWrite(true, true, true, false));
  TEST_ASSERT_FALSE(extNeedsOffWrite(true, false, false, false));
  // istenmiyor + bilinen KAPALI: gerek yok
  TEST_ASSERT_FALSE(extNeedsOffWrite(false, false, true, false));
  // istenmiyor + bilinen AÇIK: KAPAT
  TEST_ASSERT_TRUE(extNeedsOffWrite(false, true, true, false));
  // istenmiyor + durum BİLİNMİYOR (açık olabilir): KAPAT
  TEST_ASSERT_TRUE(extNeedsOffWrite(false, false, false, false));
  TEST_ASSERT_TRUE(extNeedsOffWrite(false, true, false, false));
}

void test_ext_needs_off_write_skips_relays_pending_adoption_after_raw_toggle(void) {
  using relayrules::extNeedsOffWrite;
  // ham TOGGLE sonrası: durum bilinmiyor (hwKnown=false), istenen durum henüz benimsenmedi (want=false). Bu geçiş röleyi KAPATIRSA
  // TOGGLE ile açılan röle ~10-20 ms çekip bırakırdı (QA bulgusu): benimse-bekleyen röle KAPATILMAZ.
  TEST_ASSERT_FALSE(extNeedsOffWrite(false, false, false, true));
  TEST_ASSERT_FALSE(extNeedsOffWrite(false, true, false, true));
  // benimse bayrağı yoksa aynı durum KAPAT gerektirir (güvenli taraf)
  TEST_ASSERT_TRUE(extNeedsOffWrite(false, false, false, false));
}

void test_invariant_random_walk(void) {
  // Rastgele maske dizisi: check()==OK olan HER yazim sonrasi hicbir panjur cifti 3 olamaz ve
  // enerjiliden diger yone gecis arada KAPALI olmadan olusamaz.
  uint32_t rng = 7;
  InterlockGuard g;
  g.setShutterPairs(0x0000FFFFu);         // ilk 16 cift
  uint32_t t = 0;
  for (int i = 0; i < 100000; i++) {
    rng = rng * 1664525u + 1013904223u;
    t += (rng >> 24) * 3u;                // 0..765 ms
    rng = rng * 1664525u + 1013904223u;
    uint64_t cand = ((uint64_t)rng << 16) ^ (uint64_t)(rng >> 7);
    cand &= ((1ULL << 32) - 1);
    if (g.check(cand, t) == InterlockGuard::OK) {
      uint64_t prev = g.hw();
      g.commit(cand, t);
      for (int p = 0; p < 16; p++) {
        uint8_t o = (uint8_t)((prev >> (2 * p)) & 3);
        uint8_t n = (uint8_t)((cand >> (2 * p)) & 3);
        if (n == 3) { TEST_FAIL_MESSAGE("n==3 kabul edildi"); return; }
        if (o != 0 && n != 0 && o != n) { TEST_FAIL_MESSAGE("dogrudan yon degisimi kabul edildi"); return; }
      }
    }
  }
}

int main(int, char**) {
  UNITY_BEGIN();
  RUN_TEST(test_non_shutter_pairs_are_unconstrained);
  RUN_TEST(test_both_directions_on_is_rejected);
  RUN_TEST(test_each_pair_independently_checked);
  RUN_TEST(test_direct_reversal_in_single_write_is_rejected);
  RUN_TEST(test_dead_time_is_enforced_by_driver_after_off);
  RUN_TEST(test_dead_time_survives_millis_rollover);
  RUN_TEST(test_dead_time_when_off_happened_at_millis_zero);
  RUN_TEST(test_first_energize_has_no_dead_time);
  RUN_TEST(test_ext_module_pairs_use_same_rule);
  RUN_TEST(test_highest_pair_index);
  RUN_TEST(test_commit_tracks_state_and_with_relay_helper);
  RUN_TEST(test_note_off_restamps_dead_time_even_without_believed_transition);
  RUN_TEST(test_note_off_is_millis_rollover_safe_and_ignores_non_shutter_pairs);
  RUN_TEST(test_tca_resync_in_sync_does_nothing);
  RUN_TEST(test_tca_resync_dropped_relay_is_not_reasserted);
  RUN_TEST(test_tca_resync_unexpected_on_relay_is_switched_off);
  RUN_TEST(test_tca_resync_dropped_and_extra_together_never_reasserts_dropped);
  RUN_TEST(test_tca_resync_chip_reset_drops_everything_and_restores_config);
  RUN_TEST(test_tca_resync_config_mismatch_wins_even_if_outputs_match);
  RUN_TEST(test_tca_resync_followed_by_guard_commit_restarts_dead_time_for_dropped_pair);
  RUN_TEST(test_tca_resync_physical_is_the_read_value_except_after_chip_reset);
  RUN_TEST(test_tca_resync_two_step_commit_stamps_dead_time_for_unexpected_on_shutter_relay);
  RUN_TEST(test_shutter_relay_bits_follow_pair_mask);
  RUN_TEST(test_unverified_retained_shutter_bits_exclude_new_energize_and_lights);
  RUN_TEST(test_ext_needs_off_write_rules);
  RUN_TEST(test_ext_needs_off_write_skips_relays_pending_adoption_after_raw_toggle);
  RUN_TEST(test_invariant_random_walk);
  return UNITY_END();
}
