// ============================================================================
// ShutterFsm birim testleri (PlatformIO native + Unity):  pio test -e native -f test_shutter_fsm
//
// Test altindaki sinif saf mantiktir (src/ShutterFsm.h): saat `now_ms` olarak, sürücü ise
// asagidaki `Sim` sinifiyla (role maskesini hemen uygular, hatti dogrular) enjekte edilir.
//
// `Sim` her uygulamada DEGISMEZ KURALLARI sayar (violations):
//   * maske 0x03 olamaz (YUKARI+ASAGI ayni anda)
//   * YUKARI<->ASAGI dogrudan geçis olamaz (arada KAPALI olmali)
//   * bir KAPANMADAN sonra yeniden enerjileme en az 500 ms sonra olmali
// ============================================================================
#include <unity.h>
#include <stdint.h>
#include "ShutterFsm.h"

void setUp(void) {}
void tearDown(void) {}

namespace {

struct Sim {
  ShutterFsm f;
  uint32_t now;
  uint8_t hw;            // sürücüye FIILEN uygulanan maske
  bool haveOff;          // hw'nin enerjiliden 0'a düştüğü an kayıtlı mı
  uint32_t offAt;
  int violations;
  bool confirmOff;       // sürücü "KAPALI" teyidi veriyor mu
  uint32_t energizeCount;

  explicit Sim(uint32_t t0 = 0)
      : now(t0), hw(0), haveOff(false), offAt(0), violations(0), confirmOff(true), energizeCount(0) {
    f.setTiming(20000, 20000, 500, 2000);
  }

  // FSM çıktısını sürücüye uygula ve değişmezleri denetle.
  void apply() {
    uint8_t m = f.outMask();
    if (m == 3) violations++;
    if (m != hw) {
      if (hw != 0 && m != 0) violations++;                              // arada KAPALI olmadan yön değişimi
      if (hw != 0 && m == 0) { haveOff = true; offAt = now; }
      if (hw == 0 && m != 0) {
        if (haveOff && (uint32_t)(now - offAt) < 500) violations++;     // ölü zaman < 500 ms
        energizeCount++;
      }
      hw = m;
    }
  }

  void tick(uint32_t t) {
    now = t;
    f.tick(now, confirmOff ? (hw == 0) : false);
    apply();
  }
  void up()            { f.cmdUp(now);   apply(); }
  void down()          { f.cmdDown(now); apply(); }
  void stop()          { f.cmdStop(now); apply(); }
  void step()          { f.cmdStep(now); apply(); }
  void pos(uint8_t p)  { f.cmdPosition(now, p); apply(); }
  // t anına git, oradan komut ver (komuttan önce bir tick = gerçek döngü davranışı)
  void at(uint32_t t) { tick(t); }
  // Saat t0'dan t1'e kadar 10 ms'lik adımlarla ilerlet
  void run(uint32_t t1) {
    while ((uint32_t)(t1 - now) != 0 && (uint32_t)(t1 - now) < 0x80000000u) {
      uint32_t d = (uint32_t)(t1 - now);
      tick(now + (d > 10 ? 10 : d));
    }
  }
};

}  // namespace

// ---------------------------------------------------------------- temel davranış
void test_initial_state_is_idle(void) {
  Sim s(1000);
  TEST_ASSERT_EQUAL_UINT8(0, s.f.outMask());
  TEST_ASSERT_FALSE(s.f.isMoving());
  TEST_ASSERT_FALSE(s.f.isWaiting());
  TEST_ASSERT_EQUAL_UINT8(0, s.f.position(1000));
  TEST_ASSERT_EQUAL_UINT8(255, s.f.target());
}

void test_full_up_runs_full_time_plus_overrun(void) {
  Sim s(1000);
  s.up();
  TEST_ASSERT_EQUAL_UINT8(1, s.hw);
  TEST_ASSERT_EQUAL_UINT32(22000, s.f.durationMs());   // 20 sn + 2 sn overrun
  TEST_ASSERT_EQUAL_UINT8(100, s.f.target());
  s.run(1000 + 20000);
  TEST_ASSERT_EQUAL_UINT8(100, s.f.position(s.now));    // 20. sn'de konum %100
  TEST_ASSERT_TRUE(s.f.isMoving());                     // ama limit oturması için hâlâ enerjili
  s.run(1000 + 21999);
  TEST_ASSERT_TRUE(s.f.isMoving());
  s.run(1000 + 22000);
  TEST_ASSERT_FALSE(s.f.isMoving());
  TEST_ASSERT_EQUAL_UINT8(0, s.hw);
  TEST_ASSERT_EQUAL_UINT8(100, s.f.position(s.now));
  uint8_t ev = s.f.takeEvents();
  TEST_ASSERT_TRUE((ev & ShutterFsm::EV_COMPLETED) != 0);
  TEST_ASSERT_EQUAL_INT(0, s.violations);
}

void test_full_down_runs_to_zero(void) {
  Sim s(0);
  s.f.setPosition(100);
  s.down();
  TEST_ASSERT_EQUAL_UINT8(2, s.hw);
  s.run(10000);
  TEST_ASSERT_EQUAL_UINT8(50, s.f.position(s.now));
  s.run(22000);
  TEST_ASSERT_FALSE(s.f.isMoving());
  TEST_ASSERT_EQUAL_UINT8(0, s.f.position(s.now));
  TEST_ASSERT_EQUAL_INT(0, s.violations);
}

// ---------------------------------------------------------------- ters yönde ölü zaman
void test_reverse_direction_applies_500ms_dead_time(void) {
  Sim s(1000);
  s.up();                              // t=1000 YUKARI enerjili
  TEST_ASSERT_EQUAL_UINT8(1, s.hw);
  s.run(6000);                         // 5 sn sonra konum %25
  TEST_ASSERT_EQUAL_UINT8(25, s.f.position(6000));
  s.down();                            // ters komut: YUKARI hemen kesilmeli
  TEST_ASSERT_EQUAL_UINT8(0, s.hw);
  TEST_ASSERT_TRUE(s.f.isWaiting());
  s.tick(6000);
  s.tick(6250);
  s.tick(6499);
  TEST_ASSERT_EQUAL_UINT8(0, s.hw);    // ölü zaman: hâlâ hiçbir röle enerjili değil
  s.tick(6500);
  TEST_ASSERT_EQUAL_UINT8(2, s.hw);    // tam 500 ms sonra AŞAĞI
  TEST_ASSERT_EQUAL_INT(0, s.violations);
}

void test_command_within_dead_time_after_stop_is_deferred(void) {
  Sim s(0);
  s.up();
  s.run(1000);
  s.stop();                            // t=1000 dur
  TEST_ASSERT_EQUAL_UINT8(0, s.hw);
  s.tick(1000);
  s.at(1100);
  s.up();                              // 100 ms sonra aynı yön: ölü zaman dolmadı -> kuyruğa
  TEST_ASSERT_EQUAL_UINT8(0, s.hw);
  TEST_ASSERT_TRUE(s.f.isWaiting());
  s.run(1499);
  TEST_ASSERT_EQUAL_UINT8(0, s.hw);
  s.run(1500);
  TEST_ASSERT_EQUAL_UINT8(1, s.hw);
  TEST_ASSERT_EQUAL_INT(0, s.violations);
}

void test_dead_time_never_below_500ms_even_if_configured_lower(void) {
  Sim s(0);
  s.f.setTiming(20000, 20000, 100, 2000);   // 100 ms istendi
  TEST_ASSERT_EQUAL_UINT32(500, s.f.deadMs());
}

void test_no_energize_without_off_confirmation(void) {
  Sim s(0);
  s.up();
  s.run(2000);
  s.confirmOff = false;                // sürücü KAPALI teyidi VERMİYOR (ör. RS485 yanıtsız)
  s.down();
  uint32_t t = s.now;
  for (uint32_t k = 0; k < 5000; k += 10) s.tick(t + k);   // 5 sn boyunca teyit yok
  TEST_ASSERT_EQUAL_UINT8(0, s.hw);                        // ASLA enerjilenmez
  TEST_ASSERT_TRUE(s.f.isWaiting());
  s.confirmOff = true;                 // teyit geldi
  uint32_t t1 = s.now + 10;
  s.tick(t1);
  s.tick(t1 + 499);
  TEST_ASSERT_EQUAL_UINT8(0, s.hw);    // ölü zaman teyitten itibaren sayılır
  s.tick(t1 + 500);
  TEST_ASSERT_EQUAL_UINT8(2, s.hw);
  TEST_ASSERT_EQUAL_INT(0, s.violations);
}

// ---------------------------------------------------------------- konum / yön değişimi (eski hata)
void test_position_is_continuous_across_direction_change(void) {
  // Eski kodda yön değişiminde start_position/duration/target eski kalıyor ve konum ters uca (%100)
  // sabitleniyordu. Burada konum yarıda kalan noktadan devam etmeli.
  Sim s(0);
  s.up();
  s.run(10000);                        // %50
  s.down();                            // ters: %50'de dur
  s.tick(10000);
  TEST_ASSERT_EQUAL_UINT8(50, s.f.position(10000));
  s.run(10500);                        // AŞAĞI başladı
  TEST_ASSERT_EQUAL_UINT8(2, s.hw);
  s.run(15500);                        // 5 sn aşağı => %25
  TEST_ASSERT_EQUAL_UINT8(25, s.f.position(15500));
  s.up();                              // tekrar ters
  s.tick(15500);
  TEST_ASSERT_EQUAL_UINT8(25, s.f.position(15500));
  s.run(16000);                        // YUKARI başladı
  s.run(21000);                        // 5 sn yukarı => %50
  TEST_ASSERT_EQUAL_UINT8(50, s.f.position(21000));
  TEST_ASSERT_EQUAL_INT(0, s.violations);
}

void test_position_commit_resets_start_for_new_move(void) {
  Sim s(0);
  s.up();
  s.run(4000);                         // %20
  s.stop();
  s.run(5000);                         // ölü zaman bitti
  s.up();                              // yeni tam hareket: start_pos = 20 olmalı, 100'den değil
  s.run(5000 + 10000);                 // 10 sn => +50 => %70
  TEST_ASSERT_EQUAL_UINT8(70, s.f.position(s.now));
}

void test_position_never_leaves_0_100(void) {
  Sim s(0);
  s.f.setPosition(5);
  s.down();
  s.run(30000);
  TEST_ASSERT_EQUAL_UINT8(0, s.f.position(s.now));
  Sim t(0);
  t.f.setPosition(95);
  t.up();
  t.run(30000);
  TEST_ASSERT_EQUAL_UINT8(100, t.f.position(t.now));
}

// ---------------------------------------------------------------- orantılı süre
void test_position_command_duration_is_proportional(void) {
  Sim s(0);
  s.f.setTiming(20000, 10000, 500, 2000);
  s.pos(50);                           // 0 -> 50: yukarı, 10 sn, uç değil => overrun YOK
  TEST_ASSERT_EQUAL_UINT8(1, s.hw);
  TEST_ASSERT_EQUAL_UINT32(10000, s.f.durationMs());
  TEST_ASSERT_EQUAL_UINT8(50, s.f.target());
  s.run(9999);
  TEST_ASSERT_TRUE(s.f.isMoving());
  s.run(10000);
  TEST_ASSERT_FALSE(s.f.isMoving());
  TEST_ASSERT_EQUAL_UINT8(50, s.f.position(s.now));   // hedefe eşitlenir

  Sim a(0);
  a.f.setTiming(20000, 10000, 500, 2000);
  a.f.setPosition(90);
  a.pos(100);                          // 90 -> 100: %10*20 sn + 2 sn overrun
  TEST_ASSERT_EQUAL_UINT32(4000, a.f.durationMs());

  Sim b(0);
  b.f.setTiming(20000, 10000, 500, 2000);
  b.f.setPosition(30);
  b.pos(0);                            // 30 -> 0: %30*10 sn + 2 sn
  TEST_ASSERT_EQUAL_UINT8(2, b.hw);
  TEST_ASSERT_EQUAL_UINT32(5000, b.f.durationMs());

  Sim c(0);
  c.f.setTiming(20000, 10000, 500, 2000);
  c.f.setPosition(90);
  c.pos(40);                           // 90 -> 40: %50*10 sn, overrun yok
  TEST_ASSERT_EQUAL_UINT32(5000, c.f.durationMs());
}

void test_position_command_already_at_target_does_nothing(void) {
  Sim s(0);
  s.f.setPosition(40);
  s.pos(40);
  TEST_ASSERT_EQUAL_UINT8(0, s.hw);
  TEST_ASSERT_FALSE(s.f.isMoving());
  TEST_ASSERT_EQUAL_UINT32(0, s.energizeCount);
}

void test_position_command_target_reached_while_moving_stops(void) {
  Sim s(0);
  s.up();
  s.run(10000);                        // şu an %50
  s.pos(50);                           // zaten hedefte -> dur
  TEST_ASSERT_EQUAL_UINT8(0, s.hw);
  TEST_ASSERT_EQUAL_UINT8(50, s.f.position(s.now));
}

void test_tiny_position_move_has_minimum_run_time(void) {
  Sim s(0);
  s.f.setTiming(1000, 1000, 500, 0);
  s.f.setPosition(50);
  s.pos(51);                           // 1% * 1 sn = 10 ms: röleyi 10 ms çektirmek anlamsız
  TEST_ASSERT_EQUAL_UINT32(100, s.f.durationMs());
}

void test_pending_position_is_recomputed_from_stopped_position(void) {
  Sim s(0);
  s.f.setTiming(20000, 10000, 500, 2000);
  s.pos(80);                           // 0 -> 80 yukarı (16 sn)
  s.run(8000);                         // %40
  s.pos(20);                           // ters yön, hedef %20
  s.tick(8000);
  TEST_ASSERT_EQUAL_UINT8(0, s.hw);
  s.run(8500);
  TEST_ASSERT_EQUAL_UINT8(2, s.hw);
  TEST_ASSERT_EQUAL_UINT32(2000, s.f.durationMs());   // 40 -> 20: %20 * 10 sn
  s.run(10500);
  TEST_ASSERT_FALSE(s.f.isMoving());
  TEST_ASSERT_EQUAL_UINT8(20, s.f.position(s.now));
  TEST_ASSERT_EQUAL_INT(0, s.violations);
}

// ---------------------------------------------------------------- aynı yön tekrarı / yeniden hedefleme
void test_same_direction_repeat_does_not_restart_timing(void) {
  Sim s(1000);
  s.up();
  s.f.takeEvents();
  s.run(5000);
  s.up();                              // aynı yönde tekrar komut
  TEST_ASSERT_EQUAL_UINT32(1000, s.f.startMs());       // başlangıç ANI bozulmadı
  TEST_ASSERT_EQUAL_UINT32(22000, s.f.durationMs());
  TEST_ASSERT_EQUAL_UINT8(0, s.f.takeEvents() & ShutterFsm::EV_STARTED);
  TEST_ASSERT_EQUAL_UINT8(1, s.hw);
  s.run(1000 + 22000);
  TEST_ASSERT_FALSE(s.f.isMoving());                   // süre uzamadı
  TEST_ASSERT_EQUAL_UINT32(1, s.energizeCount);
}

void test_same_direction_position_retarget_keeps_progress_and_relay(void) {
  Sim s(0);
  s.up();                              // tam yukarı (22 sn)
  s.run(5000);                         // %25
  s.f.takeEvents();
  s.pos(60);                           // aynı yön, farklı hedef: röle DEĞİŞMEZ
  TEST_ASSERT_EQUAL_UINT8(1, s.hw);
  TEST_ASSERT_TRUE((s.f.takeEvents() & ShutterFsm::EV_RETARGET) != 0);
  TEST_ASSERT_EQUAL_UINT8(60, s.f.target());
  TEST_ASSERT_EQUAL_UINT32(7000, s.f.durationMs());    // 25 -> 60: %35 * 20 sn
  s.run(5000 + 6999);
  TEST_ASSERT_TRUE(s.f.isMoving());
  s.run(5000 + 7000);
  TEST_ASSERT_FALSE(s.f.isMoving());
  TEST_ASSERT_EQUAL_UINT8(60, s.f.position(s.now));
  TEST_ASSERT_EQUAL_UINT32(1, s.energizeCount);
}

// Ayni yonde art arda hedef degisimi start_ms_'i yeniden damgalar; KESINTISIZ toplam calisma yine de "tam yol +
// oturma payi"ni (22 sn) asamaz (eski davranis: %50'den "YUKARI" -> yeni 22 sn => toplam 32 sn).
void test_retarget_chain_cannot_exceed_full_travel_plus_overrun(void) {
  Sim s(0);
  s.pos(60);                           // 0 -> 60: 12 sn (uc nokta degil, oturma payi yok)
  s.run(10000);                        // %50
  s.f.takeEvents();
  s.up();                              // ayni yonde TAM hareket: yeniden damgalanir, dur = 22 sn (dogal bitis 32. sn)
  TEST_ASSERT_EQUAL_UINT32(10000, s.f.startMs());
  TEST_ASSERT_EQUAL_UINT32(22000, s.f.durationMs());
  TEST_ASSERT_EQUAL_UINT32(0, s.f.runStartMs());       // enerjilenme ani DEGISMEZ
  s.run(21990);
  TEST_ASSERT_TRUE(s.f.isMoving());
  s.run(22000);                        // role bu yonde 22 sn calisti: KESILIR
  TEST_ASSERT_FALSE(s.f.isMoving());
  TEST_ASSERT_EQUAL_UINT8(0, s.hw);
  TEST_ASSERT_EQUAL_UINT8(100, s.f.position(s.now));
  TEST_ASSERT_EQUAL_UINT32(1, s.energizeCount);
  TEST_ASSERT_EQUAL_INT(0, s.violations);
}

void test_alternating_retargets_cannot_run_motor_indefinitely(void) {
  Sim s(0);
  s.up();                              // tam yukari (22 sn)
  for (int k = 1; k <= 6; k++) {       // her 3 sn'de yeniden damga: POS 99 (tek sayi), tam YUKARI (cift sayi)
    s.run(3000u * (uint32_t)k);
    TEST_ASSERT_TRUE(s.f.isMoving());
    if (k % 2 == 1) s.pos(99); else s.up();
  }
  // Son komut t=18 sn'de TAM YUKARI: dogal bitis 40. sn olurdu; kesintisiz calisma siniri 22. sn'de keser.
  TEST_ASSERT_EQUAL_UINT32(18000, s.f.startMs());
  s.run(21990);
  TEST_ASSERT_TRUE(s.f.isMoving());
  s.run(22000);                        // enerjilenmeden 22 sn sonra durur (yeniden damgalanan 40. sn'yi BEKLEMEZ)
  TEST_ASSERT_FALSE(s.f.isMoving());
  s.run(60000);
  TEST_ASSERT_FALSE(s.f.isMoving());
  TEST_ASSERT_EQUAL_UINT32(1, s.energizeCount);
  TEST_ASSERT_EQUAL_UINT8(100, s.f.position(s.now));
  TEST_ASSERT_EQUAL_INT(0, s.violations);
}

// Rolenin FIILEN enerjili kaldigi sure (Sim: hw != 0 olan araliklarin toplami)
void test_alternating_retargets_physical_on_time_is_bounded(void) {
  Sim s(0);
  s.up();
  uint32_t onSince = 0, maxOn = 0;
  bool wasOn = true;
  for (int k = 1; k <= 6; k++) {
    s.run(3000u * (uint32_t)k);
    if (k % 2 == 1) s.pos(99); else s.up();
  }
  while (s.now < 60000) {
    s.tick(s.now + 10);
    const bool on = (s.hw != 0);
    if (on && !wasOn) onSince = s.now;
    if (!on && wasOn) { const uint32_t d = s.now - onSince; if (d > maxOn) maxOn = d; }
    wasOn = on;
  }
  TEST_ASSERT_TRUE(maxOn <= 22000u + 20u);
}

void test_run_cap_after_reversal_counts_from_new_energize(void) {
  Sim s(0);
  s.up();
  s.run(6000);
  s.down();                            // ters: onceki hareket kesilir, 500 ms bekleme, yeni yon baslar
  s.run(6000 + 600);
  TEST_ASSERT_TRUE(s.f.isMoving());
  TEST_ASSERT_EQUAL_UINT8(2, s.f.dir());
  const uint32_t runStart = s.f.runStartMs();
  TEST_ASSERT_TRUE(runStart >= 6500u && runStart <= 6700u);   // YENI yonun enerjilenme ani (eski degil)
  TEST_ASSERT_EQUAL_UINT32(22000, s.f.runCapMs());
  s.run(runStart + 21990);
  TEST_ASSERT_TRUE(s.f.isMoving() || s.f.position(s.now) == 0);
  s.run(runStart + 22010);
  TEST_ASSERT_FALSE(s.f.isMoving());
  TEST_ASSERT_EQUAL_INT(0, s.violations);
}

// ---------------------------------------------------------------- millis() taşması
void test_millis_rollover_during_move(void) {
  uint32_t t0 = 0xFFFFFFFFu - 5000u;   // taşmaya 5 sn kala
  Sim s(t0);
  s.f.setTiming(10000, 10000, 500, 2000);
  s.up();                              // 12 sn sürer, taşmayı aşar
  s.run((uint32_t)(t0 + 6000u));       // taşma sonrası (~1 sn)
  TEST_ASSERT_TRUE(s.f.isMoving());
  TEST_ASSERT_EQUAL_UINT8(60, s.f.position(s.now));
  s.run((uint32_t)(t0 + 11999u));
  TEST_ASSERT_TRUE(s.f.isMoving());
  s.run((uint32_t)(t0 + 12000u));
  TEST_ASSERT_FALSE(s.f.isMoving());
  TEST_ASSERT_EQUAL_UINT8(100, s.f.position(s.now));
  TEST_ASSERT_EQUAL_INT(0, s.violations);
}

void test_millis_rollover_during_dead_time(void) {
  uint32_t t0 = 0xFFFFFFFFu - 200u;    // ölü zaman taşmanın üzerinden geçiyor
  Sim s(t0);
  s.up();
  s.run(t0 + 50u);
  s.down();                            // ters komut: tick'te ölü zaman başlar
  s.tick(t0 + 50u);
  s.tick((uint32_t)(t0 + 499u + 50u));
  TEST_ASSERT_EQUAL_UINT8(0, s.hw);
  s.tick((uint32_t)(t0 + 500u + 50u));
  TEST_ASSERT_EQUAL_UINT8(2, s.hw);
  TEST_ASSERT_EQUAL_INT(0, s.violations);
}

// ---------------------------------------------------------------- dead_time_start == 0 (eski hata)
void test_dead_time_when_stop_happens_at_millis_zero(void) {
  // Eski kod "dead_time_start > 0" bayrağıyla ölü zamanı yok sayıyordu: millis()==0 anında durduktan
  // sonra gelen komut ölü zamansız hemen enerjilenirdi.
  Sim s(0);
  s.up();
  s.stop();                            // tam t=0'da dur
  s.tick(0);
  s.at(100);
  s.down();
  TEST_ASSERT_EQUAL_UINT8(0, s.hw);
  s.tick(100);
  s.run(499);
  TEST_ASSERT_EQUAL_UINT8(0, s.hw);
  s.run(500);
  TEST_ASSERT_EQUAL_UINT8(2, s.hw);
  TEST_ASSERT_EQUAL_INT(0, s.violations);
}

void test_dead_time_when_stop_happens_exactly_at_rollover(void) {
  uint32_t t0 = (uint32_t)(0u - 1024u);   // 1024 ms sonra tam 0'a düşer
  Sim s(t0);
  s.up();
  s.run(0u);                              // taşma: now == 0
  TEST_ASSERT_EQUAL_UINT32(0, s.now);
  s.stop();
  s.tick(0);
  s.at(100);
  s.up();
  TEST_ASSERT_EQUAL_UINT8(0, s.hw);
  s.run(499);
  TEST_ASSERT_EQUAL_UINT8(0, s.hw);
  s.run(500);
  TEST_ASSERT_EQUAL_UINT8(1, s.hw);
  TEST_ASSERT_EQUAL_INT(0, s.violations);
}

// ---------------------------------------------------------------- aynı anda iki komut
void test_simultaneous_up_then_down_never_energizes_both(void) {
  Sim s(5000);
  s.f.cmdUp(5000);
  s.f.cmdDown(5000);                   // aynı ms'de iki komut; sürücü yalnızca SONUCU görür
  s.apply();
  TEST_ASSERT_EQUAL_UINT8(0, s.hw);    // YUKARI hiç enerjilenmedi
  TEST_ASSERT_EQUAL_UINT8(2, s.f.pendingDir());
  s.tick(5000);
  s.tick(5499);
  TEST_ASSERT_EQUAL_UINT8(0, s.hw);
  s.tick(5500);
  TEST_ASSERT_EQUAL_UINT8(2, s.hw);
  TEST_ASSERT_EQUAL_INT(0, s.violations);
}

void test_simultaneous_down_then_up_last_command_wins(void) {
  Sim s(5000);
  s.f.cmdDown(5000);
  s.f.cmdUp(5000);
  s.apply();
  TEST_ASSERT_EQUAL_UINT8(0, s.hw);
  TEST_ASSERT_EQUAL_UINT8(1, s.f.pendingDir());
  s.tick(5000);
  s.tick(5500);
  TEST_ASSERT_EQUAL_UINT8(1, s.hw);
  TEST_ASSERT_EQUAL_INT(0, s.violations);
}

void test_simultaneous_up_down_up_in_one_tick(void) {
  Sim s(0);
  s.f.cmdUp(0);
  s.f.cmdDown(0);
  s.f.cmdUp(0);
  s.f.cmdDown(0);
  s.f.cmdStep(0);                      // bekleme var => dur
  s.apply();
  TEST_ASSERT_EQUAL_UINT8(0, s.hw);
  TEST_ASSERT_FALSE(s.f.isWaiting());
  s.run(3000);
  TEST_ASSERT_EQUAL_UINT8(0, s.hw);    // hiçbir şey enerjilenmedi
  TEST_ASSERT_EQUAL_UINT32(0, s.energizeCount);
}

// ---------------------------------------------------------------- stop / step / yapılandırma
void test_stop_cancels_pending_direction(void) {
  Sim s(0);
  s.up();
  s.run(1000);
  s.down();                            // ters: bekleme
  TEST_ASSERT_TRUE(s.f.isWaiting());
  s.at(1100);
  s.stop();                            // beklemeyi iptal et
  TEST_ASSERT_FALSE(s.f.isWaiting());
  s.run(3000);
  TEST_ASSERT_EQUAL_UINT8(0, s.hw);
  TEST_ASSERT_EQUAL_UINT8(5, s.f.position(s.now));   // 1 sn * %5/sn
}

void test_stop_when_idle_is_harmless(void) {
  Sim s(0);
  s.stop();
  TEST_ASSERT_EQUAL_UINT8(0, s.hw);
  TEST_ASSERT_EQUAL_UINT8(0, s.f.takeEvents() & ShutterFsm::EV_STOPPED);
}

void test_step_picks_direction_by_position(void) {
  Sim a(0);
  a.f.setPosition(100);
  a.step();
  TEST_ASSERT_EQUAL_UINT8(2, a.hw);    // tam açık => aşağı

  Sim b(0);
  b.step();
  TEST_ASSERT_EQUAL_UINT8(1, b.hw);    // tam kapalı => yukarı

  Sim c(0);
  c.f.setPosition(50);
  c.step();                            // arada, son yön yok => yukarı
  TEST_ASSERT_EQUAL_UINT8(1, c.hw);
  c.run(1000);
  c.step();                            // hareket ediyor => DUR
  TEST_ASSERT_EQUAL_UINT8(0, c.hw);
  c.run(2000);
  c.step();                            // arada, son yön YUKARI => şimdi AŞAĞI
  TEST_ASSERT_EQUAL_UINT8(2, c.hw);
  c.run(3000);
  c.step();                            // dur
  c.run(4000);
  c.step();                            // son yön AŞAĞI => YUKARI
  TEST_ASSERT_EQUAL_UINT8(1, c.hw);
  TEST_ASSERT_EQUAL_INT(0, c.violations);
}

void test_step_while_waiting_cancels(void) {
  Sim s(0);
  s.up();
  s.run(1000);
  s.down();
  TEST_ASSERT_TRUE(s.f.isWaiting());
  s.step();
  TEST_ASSERT_FALSE(s.f.isWaiting());
  s.run(3000);
  TEST_ASSERT_EQUAL_UINT8(0, s.hw);
}

void test_timing_change_rejected_while_moving_or_waiting(void) {
  Sim s(0);
  TEST_ASSERT_TRUE(s.f.setTiming(15000, 15000, 500, 2000));   // hareketsiz: kabul
  s.up();
  TEST_ASSERT_FALSE(s.f.setTiming(30000, 30000, 500, 2000));  // hareket halinde: reddedilir
  TEST_ASSERT_EQUAL_UINT32(15000, s.f.upMs());
  s.run(500);
  s.down();                                                   // bekleme
  TEST_ASSERT_FALSE(s.f.setTiming(30000, 30000, 500, 2000));
  s.run(1000);
  s.stop();
  s.run(3000);
  TEST_ASSERT_TRUE(s.f.setTiming(30000, 30000, 500, 2000));   // dinlenmede tekrar kabul
  TEST_ASSERT_EQUAL_UINT32(30000, s.f.upMs());
}

void test_zero_or_huge_travel_time_gets_safe_values(void) {
  Sim s(0);
  s.f.setTiming(0, 0, 500, 2000);
  TEST_ASSERT_EQUAL_UINT32(20000, s.f.upMs());                // 0 => varsayılan 20 sn
  s.f.setTiming(9999999, 400000, 500, 2000);
  TEST_ASSERT_EQUAL_UINT32(300000, s.f.upMs());               // üst sınır 300 sn
  TEST_ASSERT_EQUAL_UINT32(300000, s.f.downMs());
}

void test_energize_failure_aborts_move_and_keeps_position(void) {
  Sim s(0);
  s.f.setPosition(30);
  s.up();
  TEST_ASSERT_EQUAL_UINT8(1, s.f.outMask());
  s.f.onEnergizeFailed(5);                                    // sürücü YUKARI'yı yazamadı
  s.apply();
  TEST_ASSERT_EQUAL_UINT8(0, s.hw);
  TEST_ASSERT_EQUAL_UINT8(30, s.f.position(5));               // konum bozulmadı
  TEST_ASSERT_TRUE((s.f.takeEvents() & ShutterFsm::EV_START_FAILED) != 0);
  s.f.cmdUp(10);                                              // hemen yeniden denenirse ölü zaman var
  s.apply();
  TEST_ASSERT_EQUAL_UINT8(0, s.hw);
}

void test_force_stop_is_immediate_and_saves_position(void) {
  Sim s(0);
  s.up();
  s.run(5000);
  s.f.forceStop(5000);
  s.apply();
  TEST_ASSERT_EQUAL_UINT8(0, s.hw);
  TEST_ASSERT_EQUAL_UINT8(25, s.f.position(5000));
}

// ---------------------------------------------------------------- yapısal değişmez: rastgele komut fırtınası
static uint32_t g_rng = 0xC0FFEEu;
static uint32_t rnd(void) {
  g_rng = g_rng * 1664525u + 1013904223u;
  return g_rng >> 8;
}

void test_fuzz_interlock_invariants_hold_under_random_commands(void) {
  for (int round = 0; round < 6; round++) {
    // Farklı başlangıç saatleri (taşma dahil) ve süreler
    uint32_t starts[6] = {0u, 1u, 1000u, 0xFFFFF000u, 0xFFFFFFFFu, 0x7FFFFFF0u};
    Sim s(starts[round]);
    s.f.setTiming(1000u + rnd() % 29000u, 1000u + rnd() % 29000u, 500u, 2000u);
    s.f.setPosition((uint8_t)(rnd() % 101u));
    uint32_t t = s.now;
    for (int i = 0; i < 60000; i++) {
      t += rnd() % 700u;                         // 0..699 ms
      s.confirmOff = (rnd() % 17u) != 0;         // bazen sürücü teyidi gecikir
      s.tick(t);
      switch (rnd() % 12u) {
        case 0: s.up(); break;
        case 1: s.down(); break;
        case 2: s.stop(); break;
        case 3: s.step(); break;
        case 4: s.pos((uint8_t)(rnd() % 101u)); break;
        case 5: s.f.forceStop(t); s.apply(); break;
        case 6: {                                // aynı ms'de iki/üç komut
          s.f.cmdUp(t); s.f.cmdDown(t); if (rnd() & 1u) s.f.cmdUp(t); s.apply();
          break;
        }
        case 7: {
          s.f.cmdDown(t); s.f.cmdUp(t); s.apply();
          break;
        }
        case 8: s.f.onEnergizeFailed(t); s.apply(); break;
        default: break;                          // yalnızca zaman ilerlesin
      }
      // Her adımda: çıktı 3 olamaz, konum 0..100
      if (s.f.outMask() == 3) { TEST_FAIL_MESSAGE("outMask == 3 (YUKARI+ASAGI ayni anda)"); return; }
      if (s.f.position(t) > 100) { TEST_FAIL_MESSAGE("konum 100'u asti"); return; }
    }
    TEST_ASSERT_EQUAL_INT(0, s.violations);
  }
}

int main(int, char**) {
  UNITY_BEGIN();
  RUN_TEST(test_initial_state_is_idle);
  RUN_TEST(test_full_up_runs_full_time_plus_overrun);
  RUN_TEST(test_full_down_runs_to_zero);
  RUN_TEST(test_reverse_direction_applies_500ms_dead_time);
  RUN_TEST(test_command_within_dead_time_after_stop_is_deferred);
  RUN_TEST(test_dead_time_never_below_500ms_even_if_configured_lower);
  RUN_TEST(test_no_energize_without_off_confirmation);
  RUN_TEST(test_position_is_continuous_across_direction_change);
  RUN_TEST(test_position_commit_resets_start_for_new_move);
  RUN_TEST(test_position_never_leaves_0_100);
  RUN_TEST(test_position_command_duration_is_proportional);
  RUN_TEST(test_position_command_already_at_target_does_nothing);
  RUN_TEST(test_position_command_target_reached_while_moving_stops);
  RUN_TEST(test_tiny_position_move_has_minimum_run_time);
  RUN_TEST(test_pending_position_is_recomputed_from_stopped_position);
  RUN_TEST(test_same_direction_repeat_does_not_restart_timing);
  RUN_TEST(test_same_direction_position_retarget_keeps_progress_and_relay);
  RUN_TEST(test_retarget_chain_cannot_exceed_full_travel_plus_overrun);
  RUN_TEST(test_alternating_retargets_cannot_run_motor_indefinitely);
  RUN_TEST(test_alternating_retargets_physical_on_time_is_bounded);
  RUN_TEST(test_run_cap_after_reversal_counts_from_new_energize);
  RUN_TEST(test_millis_rollover_during_move);
  RUN_TEST(test_millis_rollover_during_dead_time);
  RUN_TEST(test_dead_time_when_stop_happens_at_millis_zero);
  RUN_TEST(test_dead_time_when_stop_happens_exactly_at_rollover);
  RUN_TEST(test_simultaneous_up_then_down_never_energizes_both);
  RUN_TEST(test_simultaneous_down_then_up_last_command_wins);
  RUN_TEST(test_simultaneous_up_down_up_in_one_tick);
  RUN_TEST(test_stop_cancels_pending_direction);
  RUN_TEST(test_stop_when_idle_is_harmless);
  RUN_TEST(test_step_picks_direction_by_position);
  RUN_TEST(test_step_while_waiting_cancels);
  RUN_TEST(test_timing_change_rejected_while_moving_or_waiting);
  RUN_TEST(test_zero_or_huge_travel_time_gets_safe_values);
  RUN_TEST(test_energize_failure_aborts_move_and_keeps_position);
  RUN_TEST(test_force_stop_is_immediate_and_saves_position);
  RUN_TEST(test_fuzz_interlock_invariants_hold_under_random_commands);
  return UNITY_END();
}
