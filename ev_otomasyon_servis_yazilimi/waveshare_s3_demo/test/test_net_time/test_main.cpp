// ============================================================================
// NetTime (src/NetTime.h) birim testleri:  pio test -e native -f test_net_time
//
// N6 / CONTRACTS 3c ZAMAN KURALI: millis() 24,86 gunde 2^31'i, 49,7 gunde 2^32'yi asar. Saklanmis "hedef zaman" +
// isaretli karsilastirma, hedef eski kalinca zamanlayiciyi DONDURUR. Bu testler ag katmaninin her zamanlayicisini
// (MQTT yeniden baglanma/abonelik penceresi/yayin pacer'i, yerel API kimlik kilitleri, AP pencereleri, STA/aday
// Wi-Fi, tarama kapisi) sarma sinirlarinda (0, 2^31, 2^32 civari) ve 24,86 / 49,7 gunluk sessizliklerde dener;
// eski deseni (legacyDue) ayni senaryoda DONDURDUGUNU gosterir, yeni mantik donmaz.
// AP penceresi, eski algoritmanin 64 bit zamanli referans modeliyle rastgele senaryolarda KARSILASTIRILIR.
// ============================================================================
#include <unity.h>
#include <stdint.h>
#include "NetTime.h"

using namespace NetUtil;

void setUp(void) {}
void tearDown(void) {}

namespace {

#define CHECK(code, cond) \
  do {                    \
    if (!(cond)) return (code); \
  } while (0)

const uint32_t MINUTE = 60u * 1000u;
const uint64_t DAY = 86400000ull;

// Zaman tabanlari: 0, 2^30, 2^31 ve 2^32 sinirlarinin hemen oncesi/sonrasi
const uint32_t kBases[] = {0u,          5000u,       0x40000000u, 0x7FFFFF00u, 0x7FFFFFF0u,
                           0x80000000u, 0x80000010u, 0xFFFFF000u, 0xFFFFFFF0u, 0xFFFFFFFFu};
const int kNumBases = (int)(sizeof(kBases) / sizeof(kBases[0]));
// Uzun taramalar icin daha az taban (ilki sarmaya en yakin)
const uint32_t kLongBases[] = {0u, 0x7FFFF000u, 0xFFFF0000u};
const int kNumLongBases = (int)(sizeof(kLongBases) / sizeof(kLongBases[0]));

// Sessizlik sureleri: 10 sn, 1 gun, 24,86 gunun (2^31 ms) hemen altinda/ustunde, 30 gun, 49,7 gunun (2^32 ms) hemen
// altinda/ustunde (eski damga sarmalanip yeniden "taze" gorunebilecek pencere), 60 gun
const uint64_t kIdle[] = {10ull * 1000ull,
                          1ull * DAY,
                          0x80000000ull - 100ull,
                          0x80000000ull + 100ull,
                          24ull * DAY + 20ull * 3600ull * 1000ull,
                          25ull * DAY,
                          30ull * DAY,
                          0x100000000ull - 100ull,
                          0x100000000ull + 100ull,
                          0x100000000ull + 5000ull,
                          0x100000000ull + 20ull * 60ull * 1000ull,
                          60ull * DAY};
const int kNumIdle = (int)(sizeof(kIdle) / sizeof(kIdle[0]));
// "Sessizlik" dongulerinde yoklama adimi: gorev dongusunun tick'i (<= 250 ms) yerine 60 sn kullanilir (testin amaci, sinirlarin
// (2^31 - bekleme) cok altinda kaldigi surece zamanlayicinin donmadigini gostermektir; hizli kosmasi icin kaba adim).
const uint32_t kIdleStep = 60000u;

// Eski (N6 oncesi) desen: hedef zaman sakla + isaretli karsilastir. YALNIZ "bu desen donar" gosterimi icin.
bool legacyDue(uint32_t now, uint32_t target) { return target == 0 || (int32_t)(now - target) >= 0; }

uint32_t g_rng = 1;
uint32_t rnd() {
  g_rng = g_rng * 1664525u + 1013904223u;
  return g_rng >> 8;
}

// ---------------------------------------------------------------------------------------------------------------
// Wait
// ---------------------------------------------------------------------------------------------------------------
int waitBoundaries(uint32_t b) {
  Wait w;
  CHECK(1, w.elapsed(b));   // kurulu degil -> dolmus
  CHECK(2, !w.isArmed() && w.remaining(b) == 0u && w.passed(b) == 0u);
  w.arm(b, 5000);
  CHECK(3, !w.elapsed(b));
  CHECK(4, !w.elapsed(b + 4999u));
  CHECK(5, w.elapsed(b + 5000u));
  CHECK(6, w.remaining(b) == 5000u);
  CHECK(7, w.remaining(b + 4999u) == 1u);
  CHECK(8, w.remaining(b + 5000u) == 0u);
  CHECK(9, w.passed(b + 1234u) == 1234u);
  CHECK(10, !w.service(b + 4999u));
  CHECK(11, w.isArmed());
  CHECK(12, w.running(b + 4999u));
  CHECK(13, w.service(b + 5000u));
  CHECK(14, !w.isArmed());
  CHECK(15, !w.service(b + 5001u));
  CHECK(16, w.elapsed(b + 5001u));   // sonlanmis -> dolmus
  w.arm(b, 100);
  CHECK(17, w.running(b + 99u));
  CHECK(18, !w.running(b + 100u));
  CHECK(19, !w.isArmed());
  w.arm(b, 0);
  CHECK(20, w.elapsed(b));
  return 0;
}

// Tek zamanlayici, tur basina yoklanir: tam bir kez dolar, sonra hep "dolmus" kalir (sarma/49,7 gun: yeniden dogmaz).
int waitSweep(uint32_t base, uint32_t span, uint32_t tick, uint64_t totalMs) {
  Wait w;
  w.arm(base, span);
  int fired = 0;
  uint64_t firedAt = 0;
  for (uint64_t t = 0; t <= totalMs; t += tick) {
    const uint32_t now = (uint32_t)(base + t);
    if (w.service(now)) {
      fired++;
      firedAt = t;
    }
    if (t >= (uint64_t)span + tick && w.isArmed()) return 1;
    if (t >= span && !w.elapsed(now)) return 2;
  }
  if (fired != 1) return 3;
  if (firedAt < span || firedAt >= (uint64_t)span + tick) return 4;
  return 0;
}

int jitterBounds() {
  const uint32_t bases[] = {0u, 7u, 5000u, 10000u, 60000u, 300000u};
  for (unsigned i = 0; i < sizeof(bases) / sizeof(bases[0]); i++) {
    const uint32_t base = bases[i];
    const uint32_t span = base / 5u;
    const uint32_t rs[] = {0u, 1u, 2u, span, 2u * span - (span ? 1u : 0u), 2u * span, 2u * span + 1u, 0x7FFFFFFFu, 0xFFFFFFFFu};
    for (unsigned k = 0; k < sizeof(rs) / sizeof(rs[0]); k++) {
      const uint32_t j = jitterMs(base, rs[k]);
      CHECK(1, j >= base - span && j <= base + span);
    }
    CHECK(2, jitterMs(base, 0u) == base - span);
    CHECK(3, jitterMs(base, 2u * span) == base + span);
  }
  return 0;
}

// ---------------------------------------------------------------------------------------------------------------
// ReconnectBackoff (MQTT yeniden baglanma)
// ---------------------------------------------------------------------------------------------------------------
int backoffSequence(uint32_t base) {
  ReconnectBackoff b;
  uint32_t now = base;
  CHECK(1, b.due(now));   // hic planlanmamis: hemen
  const uint32_t expectBase[] = {5000, 10000, 20000, 40000, 80000, 160000, 300000, 300000};
  for (int i = 0; i < 8; i++) {
    b.schedule(now, false, 0xFFFFFFFFu);
    const uint32_t w = jitterMs(expectBase[i], 0xFFFFFFFFu);
    CHECK(10 + i, b.wait.span == w);
    CHECK(20 + i, !b.due(now + w - 1u));
    CHECK(30 + i, b.due(now + w));
    now += w;
  }
  b.reset();
  CHECK(40, b.due(now) && b.backoffMs == 5000u);
  b.schedule(now, true, 0u);   // sertifika dogrulama hatasi: taban 60 sn
  CHECK(41, b.wait.span == jitterMs(60000u, 0u));
  CHECK(42, b.backoffMs == 120000u);
  b.reset();
  b.scheduleAuthRejected(now, 0u);   // CONNACK 4/5: 300 sn
  CHECK(43, b.wait.span == jitterMs(300000u, 0u));
  CHECK(44, b.backoffMs == 300000u);
  b.reset();
  b.waitFixed(now, 2000u);           // saat senkronu bekleme: ustel sayaca dokunmaz
  CHECK(45, b.wait.span == 2000u && b.backoffMs == 5000u);
  CHECK(46, !b.due(now + 1999u) && b.due(now + 2000u));
  return 0;
}

// Wi-Fi uzun sure yok (gorev yalniz zamanlayicilari yoklar): geri geldiginde ilk deneme HEMEN yapilmali.
int reconnectNotFrozenAfterOutage(uint32_t base, uint64_t outageMs) {
  ReconnectBackoff b;
  b.schedule(base, false, 123u);   // son kopusta kurulan bekleme
  for (uint64_t t = 0; t < outageMs; t += kIdleStep) b.service((uint32_t)(base + t));
  CHECK(1, b.due((uint32_t)(base + outageMs)));
  // ayni senaryoda eski desen (hedef = base + bekleme): 24,86 gun sonrasinda DONAR
  const uint32_t legacyTarget = base + jitterMs(5000u, 123u);
  if (outageMs >= 0x80000000ull + 20000ull && outageMs < 0xFFFFFFFFull - 20000ull) {
    CHECK(2, !legacyDue((uint32_t)(base + outageMs), legacyTarget));
  }
  return 0;
}

// ---------------------------------------------------------------------------------------------------------------
// Abonelik sonrasi "ilk 1500 ms yok say" penceresi (MqttManager::onMessage)
// ---------------------------------------------------------------------------------------------------------------
int ignoreWindow(uint32_t base, uint64_t idleMs) {
  Wait v;
  v.arm(base, 1500u);
  CHECK(1, v.running(base));
  CHECK(2, v.running(base + 1499u));    // 1499 ms: yok sayilir
  CHECK(3, !v.running(base + 1500u));   // 1500 ms: islenir
  CHECK(4, !v.running(base + 1501u));   // kalici kapali
  // uzun sessizlik: gorev dongusu pencereyi yoklar, mesaj YOK; ilk komut yine ISLENMELI
  Wait u;
  u.arm(base, 1500u);
  for (uint64_t t = 0; t < idleMs; t += kIdleStep) u.service((uint32_t)(base + t));
  CHECK(5, !u.running((uint32_t)(base + idleMs)));
  // eski desen: ayni sessizlikte pencere "hala acik" sanilir -> TUM komutlar yok sayilirdi
  const uint32_t legacyUntil = base + 1500u;
  if (idleMs >= 0x80000000ull + 2000ull && idleMs < 0xFFFFFFFFull - 2000ull) {
    CHECK(6, !legacyDue((uint32_t)(base + idleMs), legacyUntil));
  }
  return 0;
}

// ---------------------------------------------------------------------------------------------------------------
// PublishPacer
// ---------------------------------------------------------------------------------------------------------------
int pacerCoalesceHeartbeat(uint32_t b) {
  PublishPacer p;
  p.connected();                         // baglanti kuruldu: ilk yayin gecikmeden
  CHECK(1, p.due(b, false));
  p.beginSend();
  p.sent(b);
  CHECK(2, !p.due(b + 100u, false));      // kalp atisi 30 sn
  CHECK(3, !p.due(b + 29999u, false));
  CHECK(4, p.due(b + 30000u, false));
  // tetik: 250 ms birlestirme, ikinci tetik pencereyi UZATMAZ
  p.beginSend();
  p.sent(b + 30000u);
  const uint32_t t0 = b + 40000u;
  CHECK(5, !p.due(t0, true));
  CHECK(6, !p.due(t0 + 100u, true));      // ikinci tetik
  CHECK(7, !p.due(t0 + 249u, true));
  CHECK(8, p.due(t0 + 250u, true));
  p.beginSend();
  p.sent(t0 + 250u);
  CHECK(9, !p.due(t0 + 251u, false));     // bayrak yok, kalp atisi yok
  CHECK(10, p.due(t0 + 250u + 30000u, false));
  return 0;
}

int pacerFailureBackoff(uint32_t b) {
  PublishPacer p;
  p.connected();
  uint32_t now = b;
  const uint32_t expect[] = {1000, 2000, 4000, 8000, 16000, 30000, 30000, 30000};
  for (int i = 0; i < 8; i++) {
    CHECK(1 + i, p.due(now, false));      // gonderilmeli
    p.beginSend();
    const uint32_t w = p.failed(now);
    CHECK(10 + i, w == expect[i]);
    CHECK(20 + i, p.isPending());         // istek korunur
    CHECK(30 + i, !p.due(now + w - 1u, false));
    CHECK(40 + i, p.due(now + w, false));
    now += w;
  }
  p.beginSend();
  p.sent(now);                            // basari: sayac sifirlanir
  p.beginSend();
  CHECK(50, p.failed(now) == 1000u);
  return 0;
}

// Baglanti yokken tetik bayragi aylarca "kurulu" kalir; yeniden baglaninca ilk yayin HEMEN yapilmali.
int pacerAfterLongDisconnect(uint32_t base, uint64_t idleMs) {
  PublishPacer p;
  p.connected();
  p.beginSend();
  p.sent(base);
  for (uint64_t t = 0; t < idleMs; t += kIdleStep) p.service((uint32_t)(base + t));   // koptu: yalniz yoklanir
  const uint32_t back = (uint32_t)(base + idleMs);
  p.connected();
  CHECK(1, p.due(back, true));
  p.beginSend();
  p.sent(back);
  CHECK(2, !p.due(back + 1000u, false));
  CHECK(3, p.due(back + 30000u, false));
  return 0;
}

// Bagli kalinan sureler boyunca kalp atisi tam zamaninda ve her 30 sn'de bir
int pacerHeartbeatSweep(uint32_t base, uint64_t totalMs) {
  PublishPacer p;
  p.connected();
  uint32_t now = base;
  uint64_t sent = 0;
  uint64_t lastSent = 0;
  p.beginSend();
  p.sent(now);
  for (uint64_t t = 5000; t <= totalMs; t += 5000) {
    now = (uint32_t)(base + t);
    p.service(now);
    if (p.due(now, false)) {
      if (t - lastSent != 30000ull) return 1;
      p.beginSend();
      p.sent(now);
      lastSent = t;
      sent++;
    }
  }
  if (sent != totalMs / 30000ull) return 2;
  return 0;
}

// ---------------------------------------------------------------------------------------------------------------
// AuthLimiter
// ---------------------------------------------------------------------------------------------------------------
int authLockBasics(uint32_t b) {
  AuthLimiter a;
  uint32_t ra = 0;
  const uint32_t ip = 0xC0A80164u;
  for (int i = 0; i < 4; i++) {
    a.failure(ip, b + (uint32_t)i * 1000u);
    CHECK(1 + i, !a.locked(ip, b + (uint32_t)i * 1000u, ra));
  }
  a.failure(ip, b + 4000u);   // 5. hata
  CHECK(10, a.locked(ip, b + 4000u, ra) && ra == 60u);
  CHECK(11, a.locked(ip, b + 4000u + 59999u, ra) && ra == 1u);
  CHECK(12, !a.locked(ip, b + 4000u + 60000u, ra));
  CHECK(13, !a.locked(0xC0A80165u, b + 4001u, ra));          // baska IP etkilenmez
  // dogru anahtar sayaci sifirlar
  AuthLimiter c;
  for (int i = 0; i < 4; i++) c.failure(ip, b);
  c.success(ip);
  c.failure(ip, b + 10u);
  CHECK(14, !c.locked(ip, b + 10u, ra));
  // 5 dk hatasizlik: sayac unutulur
  AuthLimiter d;
  uint32_t now = b;
  for (int i = 0; i < 4; i++) d.failure(ip, now);
  for (uint32_t t = 0; t <= 300000u; t += 250u) d.service(now + t);
  now += 300000u;
  d.failure(ip, now);                                         // sayac 1'den baslar
  CHECK(15, !d.locked(ip, now, ra));
  for (int i = 0; i < 3; i++) d.failure(ip, now);
  CHECK(16, !d.locked(ip, now, ra));                          // 4 hata
  d.failure(ip, now);
  CHECK(17, d.locked(ip, now, ra));                           // 5. hata
  // ip == 0 bilinmeyen kaynak: ortak yuva
  AuthLimiter e;
  for (int i = 0; i < 5; i++) e.failure(0u, b);
  CHECK(18, e.locked(0u, b, ra));
  return 0;
}

int authGlobalLock(uint32_t b) {
  AuthLimiter a;
  uint32_t ra = 0;
  // 20 farkli kaynaktan 60 sn icinde 20 hata -> genel kilit (yuvalar yeniden kullanilir)
  for (uint32_t i = 0; i < 20; i++) {
    const uint32_t now = b + i * 1000u;
    a.failure(0x0A000000u + i + 1u, now);
    a.service(now);
    if (i < 19) CHECK(1, !a.locked(0x0A0000FFu, now, ra));
  }
  CHECK(2, a.locked(0x0A0000FFu, b + 19000u, ra) && ra == 60u);    // hic hata yapmamis istemci de kilitli
  CHECK(3, a.locked(0x0A0000FFu, b + 19000u + 59999u, ra) && ra == 1u);
  CHECK(4, !a.locked(0x0A0000FFu, b + 19000u + 60000u, ra));
  // 60 sn penceresi dolarsa sayac sifirlanir: 19 hata + bekle + 19 hata kilitlemez
  AuthLimiter c;
  uint32_t now = b;
  for (uint32_t i = 0; i < 19; i++) c.failure(0x0B000000u + i + 1u, now);
  for (uint32_t t = 0; t <= 61000u; t += 250u) c.service(now + t);
  now += 61000u;
  for (uint32_t i = 0; i < 19; i++) c.failure(0x0B100000u + i + 1u, now);
  CHECK(5, !c.locked(0x0B0000FFu, now, ra));
  return 0;
}

int authSlotEviction(uint32_t b) {
  AuthLimiter a;
  uint32_t ra = 0;
  // 4 yuva: her kaynak 3 hata (toplam 12 < genel sinir 20, hicbiri kilitli degil)
  for (uint32_t i = 0; i < 4; i++) {
    for (int k = 0; k < 3; k++) a.failure(100u + i, b + i * 1000u);
    a.service(b + i * 1000u);
  }
  a.failure(200u, b + 5000u);   // 5. kaynak: en eski yuva (ip 100) kurban
  // ip 101, 102, 103 sayaclarini korur (3 hata): iki hata daha -> kilit
  a.failure(102u, b + 5001u);
  CHECK(1, !a.locked(102u, b + 5001u, ra));
  a.failure(102u, b + 5002u);
  CHECK(2, a.locked(102u, b + 5002u, ra));
  a.failure(103u, b + 5003u);
  a.failure(103u, b + 5004u);
  CHECK(3, a.locked(103u, b + 5004u, ra));
  // ip 100 yeniden gelir: sayaci sifirdan baslar (1 hata, kilit yok); bu da en eski yuvayi (101) kurban eder
  a.failure(100u, b + 5005u);
  CHECK(4, !a.locked(100u, b + 5005u, ra));
  CHECK(5, a.locked(102u, b + 5005u, ra));   // kilitli yuvalar korunur
  // 101 kurban edildi: sayaci sifirdan baslar (kilit icin 5 hata gerekir)
  a.failure(101u, b + 5006u);
  CHECK(6, !a.locked(101u, b + 5006u, ra));
  return 0;
}

// Bir kez kilitlenen istemci aylarca sessiz kalir: kilit sonsuza dek "devam ediyor" gorunmemeli (423 hatasi).
int authLockNotStuckAfterIdle(uint32_t base, uint64_t idleMs) {
  AuthLimiter a;
  uint32_t ra = 0;
  const uint32_t ip = 0xC0A80101u;
  const bool stillLocked = idleMs < 60000ull;   // 60 sn'den kisa sessizlikte kilit dogal olarak suruyor
  for (int i = 0; i < 5; i++) a.failure(ip, base);
  CHECK(1, a.locked(ip, base, ra));
  for (uint64_t t = 0; t < idleMs; t += kIdleStep) a.service((uint32_t)(base + t));
  const uint32_t back = (uint32_t)(base + idleMs);
  CHECK(2, a.locked(ip, back, ra) == stillLocked);
  if (!stillLocked) {
    a.failure(ip, back);
    CHECK(3, !a.locked(ip, back, ra));      // sayac yeniden 1'den
  }
  // eski desen: kilit bitisi = base + 60 sn saklanir; 24,86 gun sonrasi "hala kilitli" sanilirdi
  const uint32_t legacyUntil = base + 60000u;
  if (idleMs >= 0x80000000ull + 70000ull && idleMs < 0xFFFFFFFFull - 70000ull) {
    CHECK(4, !legacyDue((uint32_t)(base + idleMs), legacyUntil));
  }
  // genel kilit icin ayni senaryo
  AuthLimiter g;
  for (uint32_t i = 0; i < 20; i++) g.failure(0x0C000000u + i + 1u, base);
  CHECK(5, g.locked(0x0C0000FFu, base, ra));
  for (uint64_t t = 0; t < idleMs; t += kIdleStep) g.service((uint32_t)(base + t));
  CHECK(6, g.locked(0x0C0000FFu, back, ra) == stillLocked);
  return 0;
}

// ---------------------------------------------------------------------------------------------------------------
// ApPolicy: dogrudan senaryolar
// ---------------------------------------------------------------------------------------------------------------
struct ApSim {
  ApPolicy p;
  ApPolicy::In in;
  uint32_t now;
  uint32_t tick;
  bool apActive;
  ApSim(uint32_t base, uint32_t tickMs) : now(base), tick(tickMs), apActive(false) {
    in.allowed = true;
    in.connected = false;
    in.staConfigured = true;
    in.apActive = false;
    in.clients = 0;
  }
  // Bir tur: AP durumunu girdiye yansitir, politikayi calistirir, istenen eylemi uygular.
  ApPolicy::Out step() {
    in.apActive = apActive;
    if (!apActive) in.clients = 0;
    const ApPolicy::Out o = p.update(now, in);
    if (o.startAp) apActive = true;
    if (o.stopAp) apActive = false;
    now += tick;
    return o;
  }
  void run(uint64_t ms) {
    for (uint64_t t = 0; t < ms; t += tick) step();
  }
};

int apDirect(uint32_t b) {
  // 3 dk kesinti -> pencere; 10 dk sonra kapanir; 15 dk bekler; tekrar acilir
  ApSim s(b, 250);
  s.in.connected = false;
  uint32_t openedAt = 0;
  bool opened = false;
  uint32_t endedAt = 0;
  bool ended = false;
  uint32_t reopenedAt = 0;
  bool reopened = false;
  const uint32_t start = s.now;
  for (uint64_t t = 0; t < 40ull * 60ull * 1000ull; t += 250) {
    const uint32_t at = s.now;
    const ApPolicy::Out o = s.step();
    if (o.opened) {
      if (!opened) {
        opened = true;
        openedAt = at;
      } else if (!reopened) {
        reopened = true;
        reopenedAt = at;
      }
    }
    if (o.ended && !ended) {
      ended = true;
      endedAt = at;
    }
  }
  CHECK(1, opened && (uint32_t)(openedAt - start) >= 180000u && (uint32_t)(openedAt - start) < 180000u + 500u);
  CHECK(2, ended && (uint32_t)(endedAt - openedAt) >= 600000u && (uint32_t)(endedAt - openedAt) < 600000u + 500u);
  CHECK(3, reopened && (uint32_t)(reopenedAt - endedAt) >= 900000u && (uint32_t)(reopenedAt - endedAt) < 900000u + 500u);

  // istemci bagliyken 2 dk'lik adimlarla uzar, 30 dk'da biter
  ApSim c(b, 250);
  c.in.connected = false;
  uint32_t o1 = 0;
  bool got = false;
  uint32_t last = 0;
  int extended = 0;
  const uint32_t st = c.now;
  for (uint64_t t = 0; t < 45ull * 60ull * 1000ull; t += 250) {
    const uint32_t at = c.now;
    if (c.apActive) c.in.clients = 1;
    const ApPolicy::Out o = c.step();
    if (o.opened && !got) {
      got = true;
      o1 = at;
    }
    if (o.extended) extended++;
    if (o.ended) last = at;
  }
  CHECK(10, got && (uint32_t)(o1 - st) >= 180000u);
  CHECK(11, extended == 10);                                 // 10 dk + 10 x 2 dk = 30 dk
  CHECK(12, last != 0 && (uint32_t)(last - o1) >= 1800000u && (uint32_t)(last - o1) < 1800000u + 500u);

  // STA 30 sn kararli: pencere erken kapanir, yeniden acma bekleme sayaci iptal edilir
  ApSim d(b, 250);
  d.in.connected = false;
  d.run(190ull * 1000ull);
  CHECK(20, d.apActive);
  d.in.connected = true;
  uint32_t closedAt = 0;
  const uint32_t conAt = d.now;
  for (uint64_t t = 0; t < 60ull * 1000ull; t += 250) {
    const uint32_t at = d.now;
    const ApPolicy::Out o = d.step();
    if (o.closedStable && !closedAt) closedAt = at;
  }
  CHECK(21, closedAt != 0 && (uint32_t)(closedAt - conAt) >= 30000u && (uint32_t)(closedAt - conAt) < 30500u);
  CHECK(22, !d.apActive);
  // yeniden kesinti: 3 dk sonra HEMEN acilir (reopen bekleme sayaci iptal edildi)
  d.in.connected = false;
  d.run(185ull * 1000ull);
  CHECK(23, d.apActive);

  // servis AP penceresi (CLI "AP ON"): 10 dk
  ApSim e(b, 250);
  e.in.connected = true;
  e.run(1000);
  e.p.openService(e.now, 600000u);
  e.step();
  CHECK(30, e.apActive);
  uint32_t expiredAt = 0;
  const uint32_t sv = e.now;
  for (uint64_t t = 0; t < 11ull * 60ull * 1000ull; t += 250) {
    const uint32_t at = e.now;
    const ApPolicy::Out o = e.step();
    if (o.serviceExpired && !expiredAt) expiredAt = at;
  }
  CHECK(31, expiredAt != 0 && (uint32_t)(expiredAt - sv) >= 599000u && (uint32_t)(expiredAt - sv) < 600500u);
  CHECK(32, !e.apActive);
  // "AP OFF"
  e.p.openService(e.now, 600000u);
  e.step();
  CHECK(33, e.apActive);
  e.p.closeAll(e.now);
  e.step();
  CHECK(34, !e.apActive);

  // izin yok (provizyonlu, ap_pass yok): hic acilmaz
  ApSim f(b, 250);
  f.in.allowed = false;
  f.in.connected = false;
  f.run(30ull * 60ull * 1000ull);
  CHECK(40, !f.apActive);
  f.in.allowed = true;
  f.run(1000);
  CHECK(41, f.apActive);   // izin gelince (kesinti suruyor) pencere acilir

  // STA tanimsiz: AP hemen acilir
  ApSim g(b, 250);
  g.in.connected = false;
  g.in.staConfigured = false;
  g.run(1000);
  CHECK(50, g.apActive);

  // ap_pass degisimi: acik AP 1,5 sn sonra TEK kez yeniden baslar
  ApSim h(b, 250);
  h.in.connected = false;
  h.in.staConfigured = false;
  h.run(2000);
  CHECK(60, h.apActive);
  h.p.requestRestart(h.now);
  int restarts = 0;
  uint32_t rAt = 0;
  const uint32_t rq = h.now;
  for (uint64_t t = 0; t < 10ull * 1000ull; t += 250) {
    const uint32_t at = h.now;
    const ApPolicy::Out o = h.step();
    if (o.restartAp) {
      restarts++;
      rAt = at;
    }
  }
  CHECK(61, restarts == 1 && (uint32_t)(rAt - rq) >= 1500u && (uint32_t)(rAt - rq) < 1500u + 500u);
  return 0;
}

// Eski mantiginin yalniz "yeniden acma bekleme" parcasi (saklanmis hedef + isaretli karsilastirma).
struct LegacyReopen {
  uint32_t nextOpenAt;
  LegacyReopen() : nextOpenAt(0) {}
  bool canOpen(uint32_t now) const { return legacyDue(now, nextOpenAt); }
  void windowEnded(uint32_t now) { nextOpenAt = now + 900000u; }
};

// Pencere bir kez doldu (yeniden acma beklemesi kuruldu), STA haftalarca bagli kaldi, sonra kesinti: AP ACILMALI.
int apOpensAfterLongConnectedPeriod(uint32_t base, uint64_t connectedMs) {
  ApSim s(base, 1000);
  s.in.connected = false;
  uint64_t rel = 0;   // 64 bit goreli zaman (beklenen degerleri sarmadan hesaplamak icin)
  uint64_t endedAt = 0;
  bool ended = false;
  for (; rel < 15ull * 60ull * 1000ull; rel += 1000) {
    const ApPolicy::Out o = s.step();   // pencere 3. dk'da acilir, 13. dk'da dolar: reopen beklemesi kurulur
    if (o.ended && !ended) {
      ended = true;
      endedAt = rel;
    }
  }
  CHECK(1, !s.apActive && ended);
  LegacyReopen legacy;
  legacy.windowEnded(s.now);               // eski mantik ayni anda ayni hedefi saklardi
  s.in.connected = true;
  s.tick = kIdleStep;                      // STA haftalarca bagli; gorev dongusu (kaba adimla) yoklar
  for (uint64_t t = 0; t < connectedMs; t += kIdleStep, rel += kIdleStep) s.step();
  s.tick = 1000;
  s.in.connected = false;                  // kesinti basliyor
  const uint64_t outageStart = rel;
  bool opened = false;
  bool desiredAtOpen = false;
  uint64_t openedAt = 0;
  for (uint64_t t = 0; t < 40ull * 60ull * 1000ull; t += 1000, rel += 1000) {
    const ApPolicy::Out o = s.step();
    if (o.opened && !opened) {
      opened = true;
      openedAt = rel;
      desiredAtOpen = o.desired && o.startAp;
    }
  }
  // beklenen: kesintiden 3 dk sonra; ama onceki pencerenin 15 dk'lik yeniden acma beklemesi bitmediyse o bitince
  uint64_t expectOpen = outageStart + 180000ull;
  if (endedAt + 900000ull > expectOpen) expectOpen = endedAt + 900000ull;
  CHECK(2, opened && openedAt >= expectOpen && openedAt < expectOpen + 2000ull);
  CHECK(3, desiredAtOpen);
  if (connectedMs >= 0x80000000ull + 3600000ull && connectedMs < 0xFFFFFFFFull - 3600000ull) {
    CHECK(4, !legacy.canOpen(s.now));   // eski mantik: kurtarma AP'si ASLA acilmazdi (hedef "hala gelecekte")
  }
  return 0;
}

// 60 gun SUREKLI kesinti (24,86 ve 49,7 gun sinirlari gecilir): pencere 25 dk'lik periyotla (3 dk tetik, 10 dk acik,
// 15 dk bekleme) hic aksamadan acilip kapanmali; her acilis tam 1500 sn arayla olmali.
int apContinuousOutage(uint32_t base, uint64_t totalMs, uint32_t tick) {
  ApSim s(base, tick);
  s.in.connected = false;
  uint64_t rel = 0;
  uint64_t lastOpen = 0;
  uint64_t opens = 0;
  for (; rel < totalMs; rel += tick) {
    const ApPolicy::Out o = s.step();
    if (o.opened) {
      if (opens == 0) {
        if (rel != 180000ull) return 1;
      } else if (rel - lastOpen != 1500000ull) {
        return 2;
      }
      lastOpen = rel;
      opens++;
    }
  }
  const uint64_t expected = (totalMs - 1ull - 180000ull) / 1500000ull + 1ull;
  if (opens != expected) return 3;
  return 0;
}

// ---------------------------------------------------------------------------------------------------------------
// ApPolicy: eski algoritmanin 64 bit (sarmasiz) referans modeliyle rastgele senaryolarda KARSILASTIRMA
// ---------------------------------------------------------------------------------------------------------------
struct RefAp {
  bool windowOpen;
  uint64_t windowStart, windowEnd, nextOpenAt;
  bool nextOpenSet;
  uint64_t serviceUntil;
  bool serviceSet;
  bool restartPending;
  uint64_t restartAt;
  bool primed, prevConnected, discValid, stableValid;
  uint64_t discSince, stableSince;

  RefAp()
      : windowOpen(false), windowStart(0), windowEnd(0), nextOpenAt(0), nextOpenSet(false), serviceUntil(0), serviceSet(false),
        restartPending(false), restartAt(0), primed(false), prevConnected(false), discValid(false), stableValid(false),
        discSince(0), stableSince(0) {}

  void openService(uint64_t now, uint32_t ms) {
    serviceUntil = now + (ms ? ms : 1u);
    serviceSet = true;
  }
  void closeAll(uint64_t now) {
    serviceSet = false;
    windowOpen = false;
    nextOpenAt = now + 900000ull;
    nextOpenSet = true;
  }
  void requestRestart(uint64_t now) {
    restartPending = true;
    restartAt = now + 1500ull;
  }

  ApPolicy::Out update(uint64_t now, const ApPolicy::In& in) {
    ApPolicy::Out o;
    if (!primed || in.connected != prevConnected) {
      primed = true;
      prevConnected = in.connected;
      if (in.connected) {
        discValid = false;
        stableValid = true;
        stableSince = now;
      } else {
        stableValid = false;
        discValid = true;
        discSince = now;
      }
    }
    const bool serviceOpen = serviceSet && now < serviceUntil;
    if (serviceSet && !serviceOpen) {
      serviceSet = false;
      o.serviceExpired = true;
    }
    const uint64_t discFor = (!in.connected && discValid) ? now - discSince : 0;
    const bool trigger = !in.staConfigured || discFor >= 180000ull;
    if (!windowOpen) {
      if (in.allowed && trigger && (!nextOpenSet || now >= nextOpenAt)) {
        windowOpen = true;
        windowStart = now;
        windowEnd = now + 600000ull;
        o.opened = true;
      }
    } else {
      if (in.connected && in.staConfigured && stableValid && now - stableSince >= 30000ull) {
        windowOpen = false;
        nextOpenSet = false;
        o.closedStable = true;
      } else if (now >= windowEnd) {
        if (in.clients > 0 && now - windowStart < 1800000ull) {
          windowEnd = now + 120000ull;
          o.extended = true;
        } else {
          windowOpen = false;
          nextOpenAt = now + 900000ull;
          nextOpenSet = true;
          o.ended = true;
        }
      }
    }
    o.desired = in.allowed && ((serviceSet && now < serviceUntil) || windowOpen);
    if (o.desired && !in.apActive) {
      o.startAp = true;
      restartPending = false;
    } else if (!o.desired && in.apActive) {
      o.stopAp = true;
      restartPending = false;
    } else if (o.desired && in.apActive && restartPending && now >= restartAt) {
      o.restartAp = true;
      restartPending = false;
    } else if (!in.apActive) {
      restartPending = false;
    }
    return o;
  }
};

struct Coverage {
  int opened, ended, extended, closedStable, serviceExpired, restarts, started, stopped;
  Coverage() : opened(0), ended(0), extended(0), closedStable(0), serviceExpired(0), restarts(0), started(0), stopped(0) {}
};

// Ayni girdi/istek dizisini hem ApPolicy'ye (32 bit, sarmali) hem referansa (64 bit) verir; her turda cikti ESIT olmali.
int apDifferential(uint32_t base, uint32_t seed, uint32_t tick, uint64_t totalMs, Coverage& cov) {
  g_rng = seed;
  ApPolicy p;
  RefAp r;
  ApPolicy::In in;
  in.allowed = true;
  in.connected = (rnd() & 1u) != 0;
  in.staConfigured = true;
  in.apActive = false;
  in.clients = 0;
  bool apActive = false;
  uint64_t now64 = base;
  for (uint64_t t = 0; t < totalMs; t += tick) {
    const uint32_t x = rnd();
    if (x % 700u == 0u) in.connected = !in.connected;
    if (x % 900u == 1u) in.clients = in.clients ? 0 : (uint8_t)(1 + (x >> 5) % 3u);
    if (x % 12000u == 2u) in.allowed = !in.allowed;
    if (x % 3000u == 3u) {
      const uint32_t ms = 1000u + (rnd() % (20u * 60u * 1000u));
      p.openService((uint32_t)now64, ms);
      r.openService(now64, ms);
    }
    if (x % 5000u == 4u) {
      p.closeAll((uint32_t)now64);
      r.closeAll(now64);
    }
    if (x % 2500u == 5u) {
      p.requestRestart((uint32_t)now64);
      r.requestRestart(now64);
    }
    if (x % 60000u == 6u) in.staConfigured = !in.staConfigured;
    in.apActive = apActive;
    if (!apActive) in.clients = 0;
    const ApPolicy::Out a = p.update((uint32_t)now64, in);
    const ApPolicy::Out b = r.update(now64, in);
    if (a.desired != b.desired) return 1;
    if (a.startAp != b.startAp) return 2;
    if (a.stopAp != b.stopAp) return 3;
    if (a.restartAp != b.restartAp) return 4;
    if (a.opened != b.opened) return 5;
    if (a.extended != b.extended) return 6;
    if (a.ended != b.ended) return 7;
    if (a.closedStable != b.closedStable) return 8;
    if (a.serviceExpired != b.serviceExpired) return 9;
    if (a.opened) cov.opened++;
    if (a.ended) cov.ended++;
    if (a.extended) cov.extended++;
    if (a.closedStable) cov.closedStable++;
    if (a.serviceExpired) cov.serviceExpired++;
    if (a.restartAp) cov.restarts++;
    if (a.startAp) cov.started++;
    if (a.stopAp) cov.stopped++;
    if (a.startAp) apActive = true;
    if (a.stopAp) apActive = false;
    now64 += tick;
  }
  return 0;
}

// ---------------------------------------------------------------------------------------------------------------
// StaMachine
// ---------------------------------------------------------------------------------------------------------------
int staDirect(uint32_t b) {
  StaMachine m;
  uint32_t now = b;
  // kimlik yok: IDLE
  CHECK(1, m.update(now, false, false, false, false) == StaMachine::NONE && m.state == StaMachine::IDLE);
  // kimlik var: hemen dene
  CHECK(2, m.update(now, false, true, false, false) == StaMachine::BEGIN && m.state == StaMachine::CONNECTING);
  // 15 sn zaman asimi -> 2 sn bekle
  CHECK(3, m.update(now + 14999u, false, true, false, false) == StaMachine::NONE);
  CHECK(4, m.update(now + 15000u, false, true, false, false) == StaMachine::TIMEOUT && m.state == StaMachine::BACKOFF);
  CHECK(5, m.retry.span == 2000u && m.backoffMs == 4000u);
  now += 15000u;
  CHECK(6, m.update(now + 1999u, false, true, false, false) == StaMachine::NONE);
  CHECK(7, m.update(now + 2000u, false, true, false, false) == StaMachine::BEGIN);
  // kopma olayi: hemen TIMEOUT, bekleme 4, 8, ... 60 sn tavan
  const uint32_t expect[] = {4000, 8000, 16000, 32000, 60000, 60000};
  now += 2000u;
  for (int i = 0; i < 6; i++) {
    CHECK(10 + i, m.update(now + 100u, false, true, true, false) == StaMachine::TIMEOUT);
    CHECK(20 + i, m.retry.span == expect[i]);
    now += 100u;
    CHECK(30 + i, m.update(now + expect[i] - 1u, false, true, false, false) == StaMachine::NONE);
    now += expect[i];
    CHECK(40 + i, m.update(now, false, true, false, false) == StaMachine::BEGIN);
  }
  // baglandi: sayac sifirlanir
  CHECK(50, m.update(now + 500u, true, true, false, false) == StaMachine::NONE && m.state == StaMachine::CONNECTED);
  CHECK(51, m.backoffMs == 2000u);
  // baglanti kopar: 2 sn sonra yeniden dene
  now += 500u;
  CHECK(52, m.update(now + 10000u, false, true, false, false) == StaMachine::NONE && m.state == StaMachine::BACKOFF);
  now += 10000u;
  CHECK(53, m.update(now + 1999u, false, true, false, false) == StaMachine::NONE);
  CHECK(54, m.update(now + 2000u, false, true, false, false) == StaMachine::BEGIN);
  // AP'ye istemci bagliyken deneme yapilmaz; istemci gidince hemen
  StaMachine k;
  now = b;
  CHECK(60, k.update(now, false, true, false, true) == StaMachine::NONE);
  CHECK(61, k.update(now + 600000u, false, true, false, true) == StaMachine::NONE);
  CHECK(62, k.update(now + 600001u, false, true, false, false) == StaMachine::BEGIN);
  // elle yeniden baglan: bekleme iptal
  StaMachine q;
  now = b;
  q.update(now, false, true, false, false);                                // BEGIN
  q.update(now + 1u, false, true, true, false);                            // TIMEOUT -> BACKOFF 2 sn
  CHECK(70, q.update(now + 100u, false, true, false, false) == StaMachine::NONE);
  q.reconnectNow();
  CHECK(71, q.update(now + 101u, false, true, false, false) == StaMachine::BEGIN);
  q.reset();
  CHECK(72, q.state == StaMachine::IDLE && q.backoffMs == 2000u);
  // aday basarisiz: eski kimlik varsa 1,5 sn sonra, yoksa IDLE
  q.candidateFailed(now, true);
  CHECK(73, q.state == StaMachine::BACKOFF && q.retry.span == 1500u);
  q.candidateFailed(now, false);
  CHECK(74, q.state == StaMachine::IDLE);
  return 0;
}

// AP istemcisi aylarca bagli kalir (deneme yapilmaz), sonra ayrilir: baglanma denemesi HEMEN baslamali.
int staNotFrozenAfterApClientBlock(uint32_t base, uint64_t blockedMs) {
  StaMachine m;
  m.update(base, false, true, false, false);          // BEGIN
  m.update(base + 1u, false, true, true, false);      // TIMEOUT: bekleme kuruldu (2 sn)
  for (uint64_t t = 1000; t <= blockedMs; t += kIdleStep) {
    if (m.update((uint32_t)(base + t), false, true, false, true) != StaMachine::NONE) return 1;
  }
  const uint32_t back = (uint32_t)(base + blockedMs);
  CHECK(2, m.update(back, false, true, false, false) == StaMachine::BEGIN);
  // eski desen: hedef = base + 2 sn saklanir
  if (blockedMs >= 0x80000000ull + 5000ull && blockedMs < 0xFFFFFFFFull - 5000ull) {
    CHECK(3, !legacyDue(back, base + 1u + 2000u));
  }
  return 0;
}

// ---------------------------------------------------------------------------------------------------------------
// CandidateFlow
// ---------------------------------------------------------------------------------------------------------------
int candidateDirect(uint32_t b) {
  CandidateFlow f;
  uint32_t now = b;
  CHECK(1, f.update(now, false, false) == CandidateFlow::NOTHING);
  f.start(now);
  CHECK(2, f.update(now + 499u, false, false) == CandidateFlow::NOTHING);
  CHECK(3, f.update(now + 500u, false, false) == CandidateFlow::DO_DISCONNECT);
  now += 500u;
  CHECK(4, f.update(now + 399u, false, false) == CandidateFlow::NOTHING);
  CHECK(5, f.update(now + 400u, false, false) == CandidateFlow::DO_BEGIN);
  now += 400u;
  CHECK(6, f.update(now + 24999u, false, false) == CandidateFlow::NOTHING);
  CHECK(7, f.update(now + 25000u, false, false) == CandidateFlow::FAILED);
  CHECK(8, f.phase == CandidateFlow::NONE);
  // basari
  f.start(now);
  f.update(now + 500u, false, false);
  f.update(now + 900u, false, false);
  CHECK(10, f.update(now + 5000u, true, false) == CandidateFlow::COMMIT);
  // kopma olayi: hemen basarisiz
  f.start(now);
  f.update(now + 500u, false, false);
  f.update(now + 900u, false, false);
  CHECK(11, f.update(now + 1000u, false, true) == CandidateFlow::FAILED);
  // iptal
  f.start(now);
  f.cancel();
  CHECK(12, f.update(now + 100000u, false, false) == CandidateFlow::NOTHING);
  return 0;
}

// Akis haftalarca bosta kalir; sonra yeni aday istegi: asamalar zamaninda ilerlemeli.
int candidateAfterIdle(uint32_t base, uint64_t idleMs) {
  CandidateFlow f;
  f.start(base);
  f.update(base + 500u, false, false);
  f.update(base + 900u, false, false);
  CHECK(1, f.update(base + 25900u, false, false) == CandidateFlow::FAILED);   // onceki akis sonlandi
  for (uint64_t t = 0; t < idleMs; t += kIdleStep) f.update((uint32_t)(base + 30000u + t), false, false);
  const uint32_t n = (uint32_t)(base + 30000u + idleMs);
  f.start(n);
  CHECK(2, f.update(n + 499u, false, false) == CandidateFlow::NOTHING);
  CHECK(3, f.update(n + 500u, false, false) == CandidateFlow::DO_DISCONNECT);
  CHECK(4, f.update(n + 900u, false, false) == CandidateFlow::DO_BEGIN);
  CHECK(5, f.update(n + 901u, true, false) == CandidateFlow::COMMIT);
  return 0;
}

// ---------------------------------------------------------------------------------------------------------------
// ScanGate
// ---------------------------------------------------------------------------------------------------------------
int scanDirect(uint32_t b) {
  ScanGate g;
  bool cached = true;
  uint32_t now = b;
  // ilk istek: tarama baslar
  CHECK(1, g.decide(now, false, false, false, cached) == ScanGate::DECIDE_START && !cached);
  CHECK(2, g.inProgress);
  CHECK(3, g.poll(now + 1000u, ScanGate::DRV_RUNNING) == ScanGate::POLL_RUNNING);
  CHECK(4, g.poll(now + 3000u, ScanGate::DRV_DONE) == ScanGate::POLL_DONE);
  g.cacheStored(now + 3000u);
  CHECK(5, g.poll(now + 3001u, ScanGate::DRV_RUNNING) == ScanGate::POLL_IDLE);
  // onbellek taze: sonuc onbellekten
  CHECK(6, g.decide(now + 4000u, false, false, true, cached) == ScanGate::DECIDE_RESULT && cached);
  // refresh ama 10 sn dolmadi: hiz siniri -> onbellekten
  CHECK(7, g.decide(now + 9999u, true, false, true, cached) == ScanGate::DECIDE_RESULT && cached);
  // refresh, 10 sn doldu: yeni tarama
  CHECK(8, g.decide(now + 10000u, true, false, true, cached) == ScanGate::DECIDE_START);
  g.poll(now + 12000u, ScanGate::DRV_DONE);
  g.cacheStored(now + 12000u);
  // 120 sn omur: 119999 -> taze, 120000 -> eski
  CHECK(9, g.decide(now + 12000u + 119999u, false, false, true, cached) == ScanGate::DECIDE_RESULT);
  CHECK(10, g.decide(now + 12000u + 120000u, false, false, true, cached) == ScanGate::DECIDE_START);
  // takilan tarama: 15 sn sonra basarisiz sayilir
  CHECK(11, g.poll(now + 12000u + 120000u + 14999u, ScanGate::DRV_RUNNING) == ScanGate::POLL_RUNNING);
  CHECK(12, g.poll(now + 12000u + 120000u + 15000u, ScanGate::DRV_RUNNING) == ScanGate::POLL_FAILED);
  CHECK(13, !g.inProgress);
  // bagli degilken (baglaniyor) tarama baslamaz; onbellek yoksa "done, bos" doner
  ScanGate h;
  CHECK(14, h.decide(now, false, true, false, cached) == ScanGate::DECIDE_RESULT && !cached);
  // hiz siniri sirasinda onbellek yoksa "scanning" (sinir bitince baslayacak)
  ScanGate k;
  CHECK(15, k.decide(now, false, false, false, cached) == ScanGate::DECIDE_START);
  k.poll(now + 100u, ScanGate::DRV_FAILED);
  CHECK(16, k.decide(now + 5000u, false, false, false, cached) == ScanGate::DECIDE_SCANNING);
  CHECK(17, k.decide(now + 10000u, false, false, false, cached) == ScanGate::DECIDE_START);
  return 0;
}

// Tarama haftalarca "suruyor" gorunur (istemci birakti), sonra yeni istek: takilma zaman asimi ve onbellek omru calismali.
int scanAfterIdle(uint32_t base, uint64_t idleMs) {
  ScanGate g;
  bool cached = false;
  g.decide(base, false, false, false, cached);                     // START (timeout 15 sn, rate 10 sn)
  for (uint64_t t = 0; t < idleMs; t += kIdleStep) g.service((uint32_t)(base + t));
  const uint32_t back = (uint32_t)(base + idleMs);
  const bool stuckCleared = idleMs >= (uint64_t)ScanGate::TIMEOUT_MS;
  CHECK(1, g.poll(back, ScanGate::DRV_RUNNING) == (stuckCleared ? ScanGate::POLL_FAILED : ScanGate::POLL_RUNNING));
  if (stuckCleared) {
    CHECK(2, g.decide(back, false, false, false, cached) == ScanGate::DECIDE_START);   // hiz siniri sonsuza dek surmez
  }
  // onbellek: bir kez saklandi; omru (120 sn) dolunca haftalar sonra "taze" SAYILMAMALI
  ScanGate c;
  c.cacheStored(base);
  for (uint64_t t = 0; t < idleMs; t += kIdleStep) c.service((uint32_t)(base + t));
  const bool cacheStale = idleMs >= (uint64_t)ScanGate::CACHE_TTL_MS;
  CHECK(3, c.decide(back, false, false, true, cached) == (cacheStale ? ScanGate::DECIDE_START : ScanGate::DECIDE_RESULT));
  // eski desen: hiz siniri hedefi (base + 10 sn) saklanir; 24,86 gun sonra "hala sinirda" sanilirdi
  if (idleMs >= 0x80000000ull + 20000ull && idleMs < 0xFFFFFFFFull - 20000ull) {
    CHECK(4, !legacyDue(back, base + 10000u));
  }
  return 0;
}

}  // namespace

// ================================================================ Testler ================================================================
void test_wait_boundaries_at_every_time_base(void) {
  for (int i = 0; i < kNumBases; i++) TEST_ASSERT_EQUAL_INT(0, waitBoundaries(kBases[i]));
}

void test_wait_polled_every_tick_fires_once_and_never_refires_over_60_days(void) {
  for (int i = 0; i < kNumLongBases; i++) {
    TEST_ASSERT_EQUAL_INT(0, waitSweep(kLongBases[i], 15u * MINUTE, 5000u, 60ull * DAY));
    TEST_ASSERT_EQUAL_INT(0, waitSweep(kLongBases[i], 1500u, 50u, 2ull * 3600ull * 1000ull));
  }
}

void test_legacy_signed_target_pattern_freezes_between_24_86_and_49_7_days(void) {
  const uint32_t t0 = 12345u;
  const uint32_t target = t0 + 5000u;
  TEST_ASSERT_FALSE(legacyDue(t0, target));
  TEST_ASSERT_TRUE(legacyDue(t0 + 5000u, target));
  TEST_ASSERT_TRUE(legacyDue(t0 + 0x7FFFFFFFu, target));                  // 24,86 gune kadar dogru
  TEST_ASSERT_FALSE(legacyDue(t0 + 0x80000000u + 6000u, target));         // 24,86 gun: DONMUS ("hala gelecekte")
  TEST_ASSERT_FALSE(legacyDue(t0 + 0xC0000000u, target));                 // ~37 gun: donmus
  TEST_ASSERT_FALSE(legacyDue(target - 1u, target));                      // 49,7 gunden 1 ms once: hala donmus
  TEST_ASSERT_TRUE(legacyDue(target + 10u, target));                      // 49,7 gun + 10 ms: sarma, "duzelir"
  // ayni sessizlikte yoklanan Wait donmaz
  TEST_ASSERT_EQUAL_INT(0, waitSweep(t0, 5000u, 1000u, 30ull * DAY));
}

void test_wait_elapsed_is_correct_without_polling_up_to_49_7_days(void) {
  // service() unutulsa bile isaretsiz gecen sure 49,7 gune kadar dogrudur (saklanmis hedef + isaretli karsilastirma DEGIL)
  const uint64_t idles[] = {5000ull, 1ull * DAY, 0x80000000ull - 1ull, 0x80000000ull, 0x80000000ull + 1ull, 30ull * DAY,
                            0x100000000ull - 20000ull};
  for (int i = 0; i < kNumLongBases; i++) {
    for (unsigned k = 0; k < sizeof(idles) / sizeof(idles[0]); k++) {
      Wait w;
      w.arm(kLongBases[i], 5000u);
      const uint32_t back = (uint32_t)(kLongBases[i] + idles[k]);
      TEST_ASSERT_TRUE(w.elapsed(back));
      TEST_ASSERT_EQUAL_UINT32(0u, w.remaining(back));
      TEST_ASSERT_FALSE(w.running(back));
    }
  }
}

void test_jitter_stays_within_plus_minus_20_percent(void) { TEST_ASSERT_EQUAL_INT(0, jitterBounds()); }

void test_reconnect_backoff_sequence_5_to_300_s_and_special_waits(void) {
  for (int i = 0; i < kNumBases; i++) TEST_ASSERT_EQUAL_INT(0, backoffSequence(kBases[i]));
}

void test_reconnect_not_frozen_after_wifi_outage_of_any_length(void) {
  for (int i = 0; i < kNumLongBases; i++) {
    for (int k = 0; k < kNumIdle; k++) TEST_ASSERT_EQUAL_INT(0, reconnectNotFrozenAfterOutage(kLongBases[i], kIdle[k]));
  }
}

void test_subscription_ignore_window_1500_ms_and_no_stale_window_after_long_quiet(void) {
  for (int i = 0; i < kNumLongBases; i++) {
    for (int k = 0; k < kNumIdle; k++) TEST_ASSERT_EQUAL_INT(0, ignoreWindow(kLongBases[i], kIdle[k]));
  }
  for (int i = 0; i < kNumBases; i++) TEST_ASSERT_EQUAL_INT(0, ignoreWindow(kBases[i], 3000ull));
}

void test_publish_pacer_coalesce_250ms_and_heartbeat_30s(void) {
  for (int i = 0; i < kNumBases; i++) TEST_ASSERT_EQUAL_INT(0, pacerCoalesceHeartbeat(kBases[i]));
}

void test_publish_pacer_failure_backoff_1_2_4_8_16_30_s(void) {
  for (int i = 0; i < kNumBases; i++) TEST_ASSERT_EQUAL_INT(0, pacerFailureBackoff(kBases[i]));
}

void test_publish_pacer_first_publish_immediately_after_long_disconnect(void) {
  for (int i = 0; i < kNumLongBases; i++) {
    for (int k = 0; k < kNumIdle; k++) TEST_ASSERT_EQUAL_INT(0, pacerAfterLongDisconnect(kLongBases[i], kIdle[k]));
  }
}

void test_publish_pacer_heartbeat_every_30_s_across_60_days(void) {
  for (int i = 0; i < kNumLongBases; i++) TEST_ASSERT_EQUAL_INT(0, pacerHeartbeatSweep(kLongBases[i], 60ull * DAY));
}

void test_auth_limiter_per_ip_lock_forget_and_success(void) {
  for (int i = 0; i < kNumBases; i++) TEST_ASSERT_EQUAL_INT(0, authLockBasics(kBases[i]));
}

void test_auth_limiter_global_lock_20_failures_in_60_s(void) {
  for (int i = 0; i < kNumBases; i++) TEST_ASSERT_EQUAL_INT(0, authGlobalLock(kBases[i]));
}

void test_auth_limiter_slot_eviction_drops_oldest(void) {
  for (int i = 0; i < kNumBases; i++) TEST_ASSERT_EQUAL_INT(0, authSlotEviction(kBases[i]));
}

void test_auth_lock_does_not_stick_after_long_quiet_423(void) {
  for (int i = 0; i < kNumLongBases; i++) {
    for (int k = 0; k < kNumIdle; k++) TEST_ASSERT_EQUAL_INT(0, authLockNotStuckAfterIdle(kLongBases[i], kIdle[k]));
  }
}

void test_ap_window_durations_10_30_15_minutes_and_stable_close(void) {
  for (int i = 0; i < kNumBases; i++) TEST_ASSERT_EQUAL_INT(0, apDirect(kBases[i]));
}

void test_ap_opens_after_weeks_connected_following_an_earlier_window(void) {
  for (int i = 0; i < kNumLongBases; i++) {
    for (int k = 0; k < kNumIdle; k++) TEST_ASSERT_EQUAL_INT(0, apOpensAfterLongConnectedPeriod(kLongBases[i], kIdle[k]));
  }
}

void test_ap_window_cycles_without_a_hitch_during_60_days_of_continuous_outage(void) {
  for (int i = 0; i < kNumLongBases; i++) TEST_ASSERT_EQUAL_INT(0, apContinuousOutage(kLongBases[i], 60ull * DAY, 5000u));
  TEST_ASSERT_EQUAL_INT(0, apContinuousOutage(0x7FFFFFF0u, 3ull * 3600ull * 1000ull, 1000u));
  TEST_ASSERT_EQUAL_INT(0, apContinuousOutage(0xFFFFFFF0u, 3ull * 3600ull * 1000ull, 1000u));
}

void test_ap_policy_matches_64bit_reference_model_across_wrap(void) {
  Coverage cov;
  const uint32_t bases[] = {0u, 0x7FFFF000u, 0x7FFFFFF0u, 0xFFFF0000u, 0xFFFFFFF0u, 0x80000000u};
  for (unsigned i = 0; i < sizeof(bases) / sizeof(bases[0]); i++) {
    for (uint32_t seed = 1; seed <= 40; seed++) {
      TEST_ASSERT_EQUAL_INT(0, apDifferential(bases[i], seed * 7919u + i, 250u, 3ull * 3600ull * 1000ull, cov));
    }
  }
  // senaryolar bos kalmamali: her olay turu gorulmus olmali
  TEST_ASSERT_TRUE(cov.opened > 100);
  TEST_ASSERT_TRUE(cov.ended > 50);
  TEST_ASSERT_TRUE(cov.extended > 20);
  TEST_ASSERT_TRUE(cov.closedStable > 20);
  TEST_ASSERT_TRUE(cov.serviceExpired > 20);
  TEST_ASSERT_TRUE(cov.restarts > 20);
  TEST_ASSERT_TRUE(cov.started > 100);
  TEST_ASSERT_TRUE(cov.stopped > 100);
}

void test_ap_policy_matches_reference_over_60_days_with_5s_ticks(void) {
  Coverage cov;
  for (int i = 0; i < kNumLongBases; i++) {
    TEST_ASSERT_EQUAL_INT(0, apDifferential(kLongBases[i], 424242u + (uint32_t)i, 5000u, 60ull * DAY, cov));
  }
  TEST_ASSERT_TRUE(cov.opened > 100);
  TEST_ASSERT_TRUE(cov.ended > 20);
}

void test_sta_machine_attempts_backoff_and_ap_client_block(void) {
  for (int i = 0; i < kNumBases; i++) TEST_ASSERT_EQUAL_INT(0, staDirect(kBases[i]));
}

void test_sta_machine_not_frozen_after_long_ap_client_block(void) {
  for (int i = 0; i < kNumLongBases; i++) {
    for (int k = 0; k < kNumIdle; k++) TEST_ASSERT_EQUAL_INT(0, staNotFrozenAfterApClientBlock(kLongBases[i], kIdle[k]));
  }
}

void test_candidate_flow_phases_500ms_400ms_25s(void) {
  for (int i = 0; i < kNumBases; i++) TEST_ASSERT_EQUAL_INT(0, candidateDirect(kBases[i]));
}

void test_candidate_flow_works_after_long_idle(void) {
  for (int i = 0; i < kNumLongBases; i++) {
    for (int k = 0; k < kNumIdle; k++) TEST_ASSERT_EQUAL_INT(0, candidateAfterIdle(kLongBases[i], kIdle[k]));
  }
}

void test_scan_gate_rate_limit_ttl_and_stuck_scan(void) {
  for (int i = 0; i < kNumBases; i++) TEST_ASSERT_EQUAL_INT(0, scanDirect(kBases[i]));
}

void test_scan_gate_not_frozen_after_long_quiet(void) {
  for (int i = 0; i < kNumLongBases; i++) {
    for (int k = 0; k < kNumIdle; k++) TEST_ASSERT_EQUAL_INT(0, scanAfterIdle(kLongBases[i], kIdle[k]));
  }
}

int main(int, char**) {
  UNITY_BEGIN();
  RUN_TEST(test_wait_boundaries_at_every_time_base);
  RUN_TEST(test_wait_polled_every_tick_fires_once_and_never_refires_over_60_days);
  RUN_TEST(test_legacy_signed_target_pattern_freezes_between_24_86_and_49_7_days);
  RUN_TEST(test_wait_elapsed_is_correct_without_polling_up_to_49_7_days);
  RUN_TEST(test_jitter_stays_within_plus_minus_20_percent);
  RUN_TEST(test_reconnect_backoff_sequence_5_to_300_s_and_special_waits);
  RUN_TEST(test_reconnect_not_frozen_after_wifi_outage_of_any_length);
  RUN_TEST(test_subscription_ignore_window_1500_ms_and_no_stale_window_after_long_quiet);
  RUN_TEST(test_publish_pacer_coalesce_250ms_and_heartbeat_30s);
  RUN_TEST(test_publish_pacer_failure_backoff_1_2_4_8_16_30_s);
  RUN_TEST(test_publish_pacer_first_publish_immediately_after_long_disconnect);
  RUN_TEST(test_publish_pacer_heartbeat_every_30_s_across_60_days);
  RUN_TEST(test_auth_limiter_per_ip_lock_forget_and_success);
  RUN_TEST(test_auth_limiter_global_lock_20_failures_in_60_s);
  RUN_TEST(test_auth_limiter_slot_eviction_drops_oldest);
  RUN_TEST(test_auth_lock_does_not_stick_after_long_quiet_423);
  RUN_TEST(test_ap_window_durations_10_30_15_minutes_and_stable_close);
  RUN_TEST(test_ap_opens_after_weeks_connected_following_an_earlier_window);
  RUN_TEST(test_ap_window_cycles_without_a_hitch_during_60_days_of_continuous_outage);
  RUN_TEST(test_ap_policy_matches_64bit_reference_model_across_wrap);
  RUN_TEST(test_ap_policy_matches_reference_over_60_days_with_5s_ticks);
  RUN_TEST(test_sta_machine_attempts_backoff_and_ap_client_block);
  RUN_TEST(test_sta_machine_not_frozen_after_long_ap_client_block);
  RUN_TEST(test_candidate_flow_phases_500ms_400ms_25s);
  RUN_TEST(test_candidate_flow_works_after_long_idle);
  RUN_TEST(test_scan_gate_rate_limit_ttl_and_stuck_scan);
  RUN_TEST(test_scan_gate_not_frozen_after_long_quiet);
  return UNITY_END();
}
