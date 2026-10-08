#pragma once
// ============================================================================
// NetTime.h - Ag katmaninin (WiFiManager, MqttManager, WebPortal) ZAMANLAYICILARI.
// SAF MANTIK: yalniz <stdint.h>; Arduino/FreeRTOS yok -> PC'de (pio test -e native, wasm32 sim) calisir.
//
// ZAMAN KURALI (docs/CONTRACTS.md 3c, N6): millis() 24,86 gunde 2^31'i, 49,7 gunde 2^32'yi asar. "Gelecekteki hedef
// zaman" saklayip isaretli karsilastirmayla ((int32_t)(now - hedef) >= 0) yoklamak, hedef ESKI kalirsa (uzun suredir
// tazelenmeyen sayac) hedefi "hala gelecekte" sanip zamanlayiciyi 24,86 gun DONDURUR. Bu dosyada HEDEF ZAMAN SAKLANMAZ:
//   * Her zamanlayici "son olay (start) + bekleme (span)" ciftidir; karsilastirma YALNIZ isaretsiz gecen sure iledir:
//     (uint32_t)(now - start) >= span.
//   * Kurulu (armed) bir zamanlayici sahibi gorevce HER TUR service() ile yoklanir: sure dolunca ANINDA sonlandirilir
//     (armed=false) ve "dolmus" durumu zamana bagli olmayan bir bayraga doner. 49,7 gunluk sarma bu yuzden eski bir
//     damgayi yeniden "taze" gosteremez. Tick <= 250 ms << 2^31 oldugundan yoklama araligi sinirin cok altindadir.
//   * "now", ilgili zaman damgasi alindiktan SONRA okunmus olmalidir (isaretsiz fark yalniz geriye bakar).
//   * Sahip gorev disindan zamanlayici DEGISTIRILMEZ; diger gorevler istek bayragi birakir (volatile bool).
// ============================================================================
#include <stdint.h>

namespace NetUtil {

// ---------------------------------------------------------------------------------------------------------------
// Wait: "son olay + bekleme" cifti.
// ---------------------------------------------------------------------------------------------------------------
struct Wait {
  uint32_t start;
  uint32_t span;
  bool armed;

  Wait() : start(0), span(0), armed(false) {}

  void arm(uint32_t now, uint32_t spanMs) {
    start = now;
    span = spanMs;
    armed = true;
  }
  void disarm() { armed = false; }
  bool isArmed() const { return armed; }

  // Kurulduktan beri gecen sure (kurulu degilse 0).
  uint32_t passed(uint32_t now) const { return armed ? (uint32_t)(now - start) : 0u; }

  // Sure doldu mu? KURULU OLMAYAN zamanlayici "dolmus" sayilir (hic baslamamis bekleme: hemen devam).
  bool elapsed(uint32_t now) const { return !armed || (uint32_t)(now - start) >= span; }

  // Kalan sure (ms); kurulu degilse veya dolduysa 0.
  uint32_t remaining(uint32_t now) const {
    if (!armed) return 0u;
    const uint32_t p = (uint32_t)(now - start);
    return p >= span ? 0u : span - p;
  }

  // Tur basina bir kez cagrilir: sure dolduysa zamanlayiciyi SONLANDIRIR; yalniz o cagrida true doner.
  bool service(uint32_t now) {
    if (armed && (uint32_t)(now - start) >= span) {
      armed = false;
      return true;
    }
    return false;
  }

  // Sure suruyor mu? (kurulu ve dolmamis). Dolmus ise zamanlayiciyi sonlandirir (service ile ayni kilitleme).
  bool running(uint32_t now) {
    if (!armed) return false;
    if ((uint32_t)(now - start) >= span) {
      armed = false;
      return false;
    }
    return true;
  }
};

// +-%20 jitter (rnd: herhangi bir rastgele sayi).
inline uint32_t jitterMs(uint32_t baseMs, uint32_t rnd) {
  const uint32_t span = baseMs / 5u;
  return baseMs - span + (rnd % (2u * span + 1u));
}

// ---------------------------------------------------------------------------------------------------------------
// ReconnectBackoff: MQTT yeniden baglanma (5 -> 300 sn, +-%20 jitter).
// ---------------------------------------------------------------------------------------------------------------
struct ReconnectBackoff {
  enum : uint32_t {
    MIN_MS = 5000,
    MAX_MS = 300000,
    AUTH_REJECT_MS = 300000,   // CONNACK 4/5: kimlik/yetki reddi
    LONG_MIN_MS = 60000        // sertifika dogrulama hatasi: en az bu kadar bekle
  };

  uint32_t backoffMs;
  Wait wait;

  ReconnectBackoff() : backoffMs(MIN_MS) {}

  void service(uint32_t now) { wait.service(now); }
  bool due(uint32_t now) const { return wait.elapsed(now); }
  // Yapilandirma degisti / baglanti kuruldu.
  void reset() {
    backoffMs = MIN_MS;
    wait.disarm();
  }
  // Basarisiz denemeden sonra: bekleme kur, bir sonraki beklemeyi ikiye katla (tavan MAX_MS).
  void schedule(uint32_t now, bool longWait, uint32_t rnd) {
    uint32_t base = backoffMs;
    if (longWait && base < (uint32_t)LONG_MIN_MS) base = (uint32_t)LONG_MIN_MS;
    wait.arm(now, jitterMs(base, rnd));
    backoffMs = (base * 2u > (uint32_t)MAX_MS) ? (uint32_t)MAX_MS : base * 2u;
  }
  void scheduleAuthRejected(uint32_t now, uint32_t rnd) {
    backoffMs = AUTH_REJECT_MS;
    schedule(now, false, rnd);
  }
  // Sabit bekleme (ornegin saat senkronu bekleniyor); ustel sayaca dokunmaz.
  void waitFixed(uint32_t now, uint32_t ms) { wait.arm(now, ms); }
};

// ---------------------------------------------------------------------------------------------------------------
// PublishPacer: durum yayini zamanlamasi (250 ms birlestirme, 30 sn kalp atisi, hata sonrasi ustel bekleme).
// Tetikleme bayragi (volatile bool) baska gorevlerce kurulur; zaman damgasi GORMEZ: gorev bayragi ilk
// GOZLEDIGINDE birlestirme penceresini baslatir (en fazla bir tick = 50 ms gecikme; gorevler arasi zaman damgasi yok).
// ---------------------------------------------------------------------------------------------------------------
struct PublishPacer {
  enum : uint32_t { COALESCE_MS = 250, HEARTBEAT_MS = 30000, RETRY_MAX_MS = 30000 };

  bool pending;       // yayin bekliyor (tetik gozlendi veya hata sonrasi yeniden deneme)
  uint8_t failCount;
  Wait coalesce;      // gozlemden COALESCE_MS
  Wait retry;         // hata sonrasi bekleme
  Wait heartbeat;     // son basarili yayindan HEARTBEAT_MS

  PublishPacer() : pending(false), failCount(0) {}

  void service(uint32_t now) {
    coalesce.service(now);
    retry.service(now);
    heartbeat.service(now);
  }

  // Yayin zamani geldi mi? trigger: baska gorevlerin kurdugu bayrak. (Cagri durumu ilerletir: ilk gozlemde pencere baslar.)
  bool due(uint32_t now, bool trigger) {
    if (trigger && !pending) {
      pending = true;
      coalesce.arm(now, COALESCE_MS);
    }
    if (!retry.elapsed(now)) return false;
    return pending ? coalesce.elapsed(now) : heartbeat.elapsed(now);
  }
  bool isPending() const { return pending; }

  // Yayin BASLARKEN (anlik goruntuden once): bekleyen istek tuketildi.
  void beginSend() {
    pending = false;
    coalesce.disarm();
  }
  void sent(uint32_t now) {
    failCount = 0;
    retry.disarm();
    heartbeat.arm(now, HEARTBEAT_MS);
  }
  // Hata: 1,2,4,8,16,30,30... sn bekle; istek korunur. Donus: bekleme (ms).
  uint32_t failed(uint32_t now) {
    if (failCount < 250) failCount++;
    const uint8_t shift = (failCount > 6) ? 5 : (uint8_t)(failCount - 1);
    uint32_t wait = 1000u << shift;
    if (wait > (uint32_t)RETRY_MAX_MS) wait = (uint32_t)RETRY_MAX_MS;
    retry.arm(now, wait);
    pending = true;
    coalesce.disarm();
    return wait;
  }
  // Baglanti (yeniden) kuruldu: ilk tam durumu gecikmeden yayinla.
  void connected() {
    failCount = 0;
    retry.disarm();
    heartbeat.disarm();
    pending = true;
    coalesce.disarm();
  }
};

// ---------------------------------------------------------------------------------------------------------------
// AuthLimiter: yerel API kimlik hatasi sinirlayici (IP basina 5 hata -> 60 sn kilit; 5 dk hatasizlikta unutulur;
// tum kaynaklardan 60 sn'de 20 hata -> 60 sn genel kilit). Yalniz web gorevinden kullanilir.
// ---------------------------------------------------------------------------------------------------------------
struct AuthLimiter {
  enum : uint32_t {
    SLOTS = 4,
    MAX_FAILS = 5,
    LOCK_MS = 60000,
    FORGET_MS = 300000,
    GLOBAL_MAX_FAILS = 20,
    GLOBAL_WINDOW_MS = 60000,
    GLOBAL_LOCK_MS = 60000
  };

  struct Slot {
    uint32_t ip;     // 0 = bos
    uint8_t fails;
    Wait lock;
    Wait forget;
    Slot() : ip(0), fails(0) {}
  };

  Slot slots[SLOTS];
  Wait gWindow;
  uint8_t gFails;
  Wait gLock;

  AuthLimiter() : gFails(0) {}

  // Her tur: dolan kilit/unutma/pencere sayaclarini sonlandirir; bos kalan yuvalari serbest birakir.
  void service(uint32_t now) {
    for (uint32_t i = 0; i < SLOTS; i++) {
      Slot& s = slots[i];
      if (s.ip == 0) continue;
      s.lock.service(now);
      if (s.forget.service(now)) s.fails = 0;
      if (!s.lock.armed && !s.forget.armed) {
        s.ip = 0;
        s.fails = 0;
      }
    }
    if (gWindow.service(now)) gFails = 0;
    gLock.service(now);
  }

  // Kilitliyse true; retryAfterSec en az 1 (en uzun kalan kilit: IP'ye ozel veya genel).
  bool locked(uint32_t ip, uint32_t now, uint32_t& retryAfterSec) const {
    uint32_t rem = gLock.remaining(now);
    const Slot* s = find(ip);
    if (s) {
      const uint32_t r = s->lock.remaining(now);
      if (r > rem) rem = r;
    }
    if (rem == 0) return false;
    retryAfterSec = (rem + 999u) / 1000u;
    return true;
  }

  // Hatali anahtar.
  void failure(uint32_t ip, uint32_t now) {
    const uint32_t k = norm(ip);
    Slot* s = findMutable(k);
    if (!s) s = allocate(k, now);
    if (s->forget.elapsed(now)) s->fails = 0;   // 5 dk hatasizlik (service zaten sifirlar; yoklanmamis ise de guvenli)
    s->forget.arm(now, FORGET_MS);
    if (++s->fails >= MAX_FAILS) {
      s->lock.arm(now, LOCK_MS);
      s->fails = 0;
    }
    if (gWindow.elapsed(now)) {
      gWindow.arm(now, GLOBAL_WINDOW_MS);
      gFails = 0;
    }
    if (++gFails >= GLOBAL_MAX_FAILS) {
      gLock.arm(now, GLOBAL_LOCK_MS);
      gFails = 0;
    }
  }

  // Dogru anahtar.
  void success(uint32_t ip) {
    Slot* s = findMutable(norm(ip));
    if (s) {
      s->fails = 0;
      s->lock.disarm();
    }
  }

private:
  static uint32_t norm(uint32_t ip) { return ip ? ip : 1u; }

  const Slot* find(uint32_t ip) const {
    const uint32_t k = norm(ip);
    for (uint32_t i = 0; i < SLOTS; i++) {
      if (slots[i].ip == k) return &slots[i];
    }
    return 0;
  }
  Slot* findMutable(uint32_t k) {
    for (uint32_t i = 0; i < SLOTS; i++) {
      if (slots[i].ip == k) return &slots[i];
    }
    return 0;
  }
  // Bos yuva yoksa en eski (son hatasi en uzak) yuva kurban edilir.
  Slot* allocate(uint32_t k, uint32_t now) {
    uint32_t victim = 0;
    bool found = false;
    for (uint32_t i = 0; i < SLOTS; i++) {
      if (slots[i].ip == 0) {
        victim = i;
        found = true;
        break;
      }
    }
    if (!found) {
      for (uint32_t i = 1; i < SLOTS; i++) {
        if (slots[i].forget.passed(now) > slots[victim].forget.passed(now)) victim = i;
      }
    }
    Slot& s = slots[victim];
    s.ip = k;
    s.fails = 0;
    s.lock.disarm();
    s.forget.disarm();
    return &s;
  }
};

// ---------------------------------------------------------------------------------------------------------------
// ApPolicy: kurtarma/kurulum/servis AP penceresi (WiFiManager). Girdi: STA durumu ve yetki; cikti: AP'nin istenen
// durumu. 3 dk kesinti -> 10 dk pencere (istemci varsa 2 dk'lik adimlarla, en fazla 30 dk); kapaninca kesinti
// suruyorsa 15 dk sonra yeniden; STA 30 sn kararli -> pencere erken kapanir; servis AP'si (CLI) ayri sureli pencere.
// ---------------------------------------------------------------------------------------------------------------
struct ApPolicy {
  enum : uint32_t {
    RECOVERY_TRIGGER_MS = 180000,   // STA kesintisi bu kadar surerse pencere acilir
    WINDOW_MS = 600000,             // pencere suresi: 10 dk
    REOPEN_MS = 900000,             // pencere bitince kesinti suruyorsa yeniden acmadan once bekleme: 15 dk
    MAX_EXTEND_MS = 1800000,        // istemci bagliyken pencere en fazla 30 dk uzar
    EXTEND_STEP_MS = 120000,        // uzatma adimi: 2 dk
    STABLE_MS = 30000,              // STA bu kadar kararli olunca pencere erken kapanir
    RESTART_DELAY_MS = 1500         // ap_pass degisince yeniden baslatma gecikmesi
  };

  struct In {
    bool allowed;        // AP acilabilir mi (provizyonsuz VEYA gecerli ap_pass)
    bool connected;      // STA bagli (IP var)
    bool ethUp;          // v1.3.0: Ethernet bagli VE cihaz provizyonlu (NetLinkCore::apPolicyEthUp). Provizyonsuz kartta HER ZAMAN false:
                         // kurulum AP'si kablo takiliyken de acilir. false iken davranis v1.2.1 ile birebir aynidir.
    bool staConfigured;  // kayitli STA kimligi var
    bool apActive;       // AP su an yayinda
    uint8_t clients;     // AP'ye bagli istemci sayisi
    In() : allowed(false), connected(false), ethUp(false), staConfigured(false), apActive(false), clients(0) {}
  };

  struct Out {
    bool desired;        // AP yayinda OLMALI
    bool startAp;
    bool stopAp;
    bool restartAp;
    bool opened;         // olay: pencere acildi
    bool extended;       // olay: istemci var, pencere uzatildi
    bool ended;          // olay: pencere sure doldu
    bool closedStable;   // olay: STA kararli, pencere erken kapandi
    bool serviceExpired; // olay: servis AP penceresi doldu
    Out()
        : desired(false), startAp(false), stopAp(false), restartAp(false), opened(false), extended(false), ended(false),
          closedStable(false), serviceExpired(false) {}
  };

  bool windowOpen;
  bool trigger;          // kesinti tetigi (3 dk) tutuldu
  bool stableOk;         // STA 30 sn kararli
  bool restartPending;
  bool primed;
  bool prevConnected;
  Wait window;           // mevcut pencere dilimi (10 dk; uzatmada 2 dk)
  Wait cap;              // en fazla uzama siniri (30 dk, pencere acilisindan)
  Wait reopen;           // pencere bittikten sonra yeniden acma beklemesi
  Wait service;          // servis AP penceresi
  Wait restart;          // ap_pass degisikligi sonrasi yeniden baslatma gecikmesi
  Wait disc;             // STA kesintisi sayaci
  Wait stable;           // STA kararlilik sayaci

  ApPolicy() : windowOpen(false), trigger(false), stableOk(false), restartPending(false), primed(false), prevConnected(false) {}

  // Servis modu: AP'yi sureli acar (windowMs = 0 ise 1 ms: hemen dolar).
  void openService(uint32_t now, uint32_t windowMs) { service.arm(now, windowMs ? windowMs : 1u); }
  // AP'yi hemen kapat: servis ve kurtarma pencereleri iptal; kesinti suruyorsa REOPEN_MS sonra yeniden acilabilir.
  void closeAll(uint32_t now) {
    service.disarm();
    closeWindow();
    reopen.arm(now, REOPEN_MS);
  }
  // ap_pass / provizyon durumu degisti: acik AP RESTART_DELAY_MS sonra yeni ilkeyle yeniden baslar.
  void requestRestart(uint32_t now) {
    restartPending = true;
    restart.arm(now, RESTART_DELAY_MS);
  }

  Out update(uint32_t now, const In& in) {
    Out out;

    // 1) zamanlayicilari yokla (dolanlar sonlanir; sarma/eskime olusmaz)
    if (service.service(now)) out.serviceExpired = true;
    cap.service(now);
    reopen.service(now);
    restart.service(now);

    // 2) Ag baglanti kenarlari: kesinti sayaci (3 dk) ve kararlilik sayaci (30 sn). "Ag" = STA bagli VEYA (Ethernet bagli ve provizyonlu).
    const bool netConnected = in.connected || in.ethUp;
    if (!primed || netConnected != prevConnected) {
      primed = true;
      prevConnected = netConnected;
      if (netConnected) {
        disc.disarm();
        trigger = false;
        stable.arm(now, STABLE_MS);
        stableOk = false;
      } else {
        stable.disarm();
        stableOk = false;
        disc.arm(now, RECOVERY_TRIGGER_MS);
        trigger = false;
      }
    }
    if (disc.service(now)) trigger = true;
    if (stable.service(now)) stableOk = true;

    // 3) pencere. Kayitli STA yoksa pencere acilir -- AMA provizyonlu kart Ethernet'le bagliyken degil (aksi halde Ethernet'li kart
    // AP'yi 10 dk acik / 15 dk kapali sonsuza dek dongulerdi; v1.3.0 duzeltmesi).
    const bool trig = (!in.staConfigured && !in.ethUp) || trigger;
    if (!windowOpen) {
      if (in.allowed && trig && reopen.elapsed(now)) {
        windowOpen = true;
        window.arm(now, WINDOW_MS);
        cap.arm(now, MAX_EXTEND_MS);
        out.opened = true;
      }
    } else {
      if (netConnected && (in.staConfigured || in.ethUp) && stableOk) {
        closeWindow();          // histerezis: ag (STA ya da provizyonlu kartta Ethernet) 30 sn kararli
        reopen.disarm();
        out.closedStable = true;
      } else if (window.service(now)) {
        if (in.clients > 0 && cap.isArmed()) {
          window.arm(now, EXTEND_STEP_MS);   // kullanici islem yapiyor: pencere uzar
          out.extended = true;
        } else {
          closeWindow();
          reopen.arm(now, REOPEN_MS);
          out.ended = true;
        }
      }
    }

    // 4) AP'nin istenen durumu
    out.desired = in.allowed && (service.isArmed() || windowOpen);
    if (out.desired && !in.apActive) {
      out.startAp = true;
      clearRestart();
    } else if (!out.desired && in.apActive) {
      out.stopAp = true;
      clearRestart();
    } else if (out.desired && in.apActive && restartPending && restart.elapsed(now)) {
      out.restartAp = true;
      clearRestart();
    } else if (!in.apActive) {
      clearRestart();
    }
    return out;
  }

private:
  void closeWindow() {
    windowOpen = false;
    window.disarm();
    cap.disarm();
  }
  void clearRestart() {
    restartPending = false;
    restart.disarm();
  }
};

// ---------------------------------------------------------------------------------------------------------------
// StaMachine: otomatik STA baglanma (15 sn deneme zaman asimi, 2 -> 60 sn ustel geri cekilme).
// ---------------------------------------------------------------------------------------------------------------
struct StaMachine {
  enum State : uint8_t { IDLE, CONNECTING, CONNECTED, BACKOFF };
  enum Action : uint8_t { NONE, BEGIN, TIMEOUT };
  enum : uint32_t { ATTEMPT_TIMEOUT_MS = 15000, MIN_BACKOFF_MS = 2000, MAX_BACKOFF_MS = 60000, CANDIDATE_RETRY_MS = 1500 };

  State state;
  uint32_t backoffMs;
  Wait attempt;   // baglanma denemesi zaman asimi
  Wait retry;     // bir sonraki deneme icin bekleme

  StaMachine() : state(IDLE), backoffMs(MIN_BACKOFF_MS) {}

  void service(uint32_t now) {
    attempt.service(now);
    retry.service(now);
  }

  // connected: STA bagli; ssidSet: kayitli kimlik var; evtDisc: son denemeden sonra kopma olayi geldi;
  // apBlocks: kurulum AP'sine istemci bagli (tarama AP'yi bozmasin diye deneme yapilmaz).
  Action update(uint32_t now, bool connected, bool ssidSet, bool evtDisc, bool apBlocks) {
    service(now);
    if (connected) {
      state = CONNECTED;
      backoffMs = MIN_BACKOFF_MS;
      return NONE;
    }
    if (!ssidSet) {
      state = IDLE;
      return NONE;
    }
    if (state == CONNECTED) {   // baglanti az once koptu: kisa beklemeyle yeniden dene
      state = BACKOFF;
      retry.arm(now, MIN_BACKOFF_MS);
      return NONE;
    }
    if (state == CONNECTING) {
      if (evtDisc || attempt.elapsed(now)) {
        state = BACKOFF;
        retry.arm(now, backoffMs);
        backoffMs = (backoffMs * 2u > (uint32_t)MAX_BACKOFF_MS) ? (uint32_t)MAX_BACKOFF_MS : backoffMs * 2u;
        return TIMEOUT;
      }
      return NONE;
    }
    // IDLE / BACKOFF: bekleme doldu mu?
    if (!retry.elapsed(now)) return NONE;
    if (apBlocks) return NONE;
    state = CONNECTING;
    attempt.arm(now, ATTEMPT_TIMEOUT_MS);
    return BEGIN;
  }

  // Yeni kimlik / elle yeniden baglanma: geri cekilmeyi sifirla, hemen dene.
  void reset() {
    state = IDLE;
    backoffMs = MIN_BACKOFF_MS;
    attempt.disarm();
    retry.disarm();
  }
  void reconnectNow() {
    backoffMs = MIN_BACKOFF_MS;
    retry.disarm();
    if (state == BACKOFF) state = IDLE;
  }
  // Aday akisi (WiFiManager::requestConnect) otomatik yolu devraldi / birakti.
  void candidateStarted() {
    state = IDLE;
    attempt.disarm();
  }
  void markConnected() {
    state = CONNECTED;
    backoffMs = MIN_BACKOFF_MS;
  }
  void candidateFailed(uint32_t now, bool hadOldCredentials) {
    state = hadOldCredentials ? BACKOFF : IDLE;
    retry.arm(now, CANDIDATE_RETRY_MS);
    backoffMs = MIN_BACKOFF_MS;
  }
};

// ---------------------------------------------------------------------------------------------------------------
// CandidateFlow: POST /api/wifi/connect aday kimlik akisi: 0,5 sn (HTTP yaniti) -> eski baglantiyi birak 0,4 sn ->
// baglan (25 sn zaman asimi) -> dogrulandi (COMMIT) veya basarisiz (FAILED, eski kimlige donus).
// ---------------------------------------------------------------------------------------------------------------
struct CandidateFlow {
  enum Phase : uint8_t { NONE, WAIT, DISCONNECTING, CONNECTING };
  enum Action : uint8_t { NOTHING, DO_DISCONNECT, DO_BEGIN, COMMIT, FAILED };
  enum : uint32_t { START_DELAY_MS = 500, DISCONNECT_WAIT_MS = 400, TIMEOUT_MS = 25000 };

  Phase phase;
  Wait wait;

  CandidateFlow() : phase(NONE) {}

  void start(uint32_t now) {
    phase = WAIT;
    wait.arm(now, START_DELAY_MS);
  }
  void cancel() {
    phase = NONE;
    wait.disarm();
  }

  // connectedSinceBegin: DO_BEGIN'den SONRA yeni bir IP alindi (sayac ile; zaman damgasi karsilastirmasi yok).
  Action update(uint32_t now, bool connectedSinceBegin, bool evtDisc) {
    wait.service(now);
    switch (phase) {
      case NONE:
        return NOTHING;
      case WAIT:
        if (!wait.elapsed(now)) return NOTHING;
        phase = DISCONNECTING;
        wait.arm(now, DISCONNECT_WAIT_MS);
        return DO_DISCONNECT;
      case DISCONNECTING:
        if (!wait.elapsed(now)) return NOTHING;
        phase = CONNECTING;
        wait.arm(now, TIMEOUT_MS);
        return DO_BEGIN;
      case CONNECTING:
        if (connectedSinceBegin) {
          cancel();
          return COMMIT;
        }
        if (evtDisc || wait.elapsed(now)) {
          cancel();
          return FAILED;
        }
        return NOTHING;
    }
    return NOTHING;
  }
};

// ---------------------------------------------------------------------------------------------------------------
// ScanGate: /api/wifi/scan hiz siniri (>= 10 sn), onbellek omru (120 sn) ve takilmis tarama zaman asimi (15 sn).
// ---------------------------------------------------------------------------------------------------------------
struct ScanGate {
  enum : uint32_t { MIN_INTERVAL_MS = 10000, CACHE_TTL_MS = 120000, TIMEOUT_MS = 15000 };
  enum DriverState : uint8_t { DRV_RUNNING, DRV_DONE, DRV_FAILED };
  enum Poll : uint8_t { POLL_IDLE, POLL_RUNNING, POLL_DONE, POLL_FAILED };
  enum Decision : uint8_t { DECIDE_START, DECIDE_SCANNING, DECIDE_RESULT };

  bool inProgress;
  Wait timeout;
  Wait rate;
  Wait ttl;

  ScanGate() : inProgress(false) {}

  void service(uint32_t now) {
    timeout.service(now);
    rate.service(now);
    ttl.service(now);
  }

  // Devam eden tarama varsa durumunu degerlendirir.
  Poll poll(uint32_t now, DriverState d) {
    if (!inProgress) return POLL_IDLE;
    if (d == DRV_DONE) {
      inProgress = false;
      timeout.disarm();
      return POLL_DONE;
    }
    if (d == DRV_FAILED || timeout.elapsed(now)) {
      inProgress = false;
      timeout.disarm();
      return POLL_FAILED;
    }
    return POLL_RUNNING;
  }

  // Sonuclar onbellege yazildi.
  void cacheStored(uint32_t now) { ttl.arm(now, CACHE_TTL_MS); }

  // Yeni tarama gerekli mi? cachedFlag: sonuc listesi onbellekten mi sunuluyor.
  Decision decide(uint32_t now, bool refresh, bool connecting, bool haveCache, bool& cachedFlag) {
    cachedFlag = false;
    const bool cacheFresh = haveCache && !ttl.elapsed(now);
    const bool rateLimited = !rate.elapsed(now);
    const bool needScan = refresh || !cacheFresh;
    if (needScan && !connecting) {
      if (!rateLimited) {
        inProgress = true;
        timeout.arm(now, TIMEOUT_MS);
        rate.arm(now, MIN_INTERVAL_MS);
        return DECIDE_START;
      }
      if (!haveCache) return DECIDE_SCANNING;   // hiz siniri bitince tarama baslayacak
    }
    cachedFlag = !needScan || rateLimited;
    return DECIDE_RESULT;
  }
};

}  // namespace NetUtil
