// NetTime.h'nin (firmware, src/NetTime.h) JavaScript portu: ag katmaninin (WiFiManager, MqttManager, WebPortal) ZAMANLAYICILARI.
//
// ZAMAN KURALI (CONTRACTS 3c, N6): burada HEDEF ZAMAN SAKLANMAZ. Her zamanlayici "son olay (start) + bekleme (span)" ciftidir ve
// karsilastirma YALNIZ isaretsiz gecen sureyle yapilir: u32(now - start) >= span. Kurulu bir zamanlayici sahibi gorevce her tur
// service() ile yoklanir, sure dolunca ANINDA sonlanir (armed=false). Tum aritmetik 32 bit isaretsizdir (millis() 49,7 gunde sarar).
//
// C++ cikis parametreleri (uint32_t& retryAfterSec, bool& cachedFlag) JS'de donus nesnesidir. Davranis firmware ile birebirdir;
// dogrulama: test/fw_net_time.test.js (firmware test/test_net_time/test_main.cpp portu).

export const u32 = (x) => x >>> 0;

// ---------------------------------------------------------------------------------------------------------------
// Wait: "son olay + bekleme" cifti
// ---------------------------------------------------------------------------------------------------------------
export class Wait {
  constructor() {
    this.start = 0;
    this.span = 0;
    this.armed = false;
  }

  arm(now, spanMs) {
    this.start = u32(now);
    this.span = u32(spanMs);
    this.armed = true;
  }

  disarm() { this.armed = false; }

  isArmed() { return this.armed; }

  /** Kurulduktan beri gecen sure (kurulu degilse 0). */
  passed(now) { return this.armed ? u32(now - this.start) : 0; }

  /** Sure doldu mu? KURULU OLMAYAN zamanlayici "dolmus" sayilir (hic baslamamis bekleme: hemen devam). */
  elapsed(now) { return !this.armed || u32(now - this.start) >= this.span; }

  /** Kalan sure (ms); kurulu degilse veya dolduysa 0. */
  remaining(now) {
    if (!this.armed) return 0;
    const p = u32(now - this.start);
    return p >= this.span ? 0 : this.span - p;
  }

  /** Tur basina bir kez cagrilir: sure dolduysa zamanlayiciyi SONLANDIRIR; yalniz o cagrida true doner. */
  service(now) {
    if (this.armed && u32(now - this.start) >= this.span) {
      this.armed = false;
      return true;
    }
    return false;
  }

  /** Sure suruyor mu? (kurulu ve dolmamis). Dolmus ise zamanlayiciyi sonlandirir (service ile ayni kilitleme). */
  running(now) {
    if (!this.armed) return false;
    if (u32(now - this.start) >= this.span) {
      this.armed = false;
      return false;
    }
    return true;
  }
}

/** +-%20 jitter (rnd: herhangi bir rastgele sayi, uint32). */
export function jitterMs(baseMs, rnd) {
  const span = Math.floor(baseMs / 5);
  return baseMs - span + (u32(rnd) % (2 * span + 1));
}

// ---------------------------------------------------------------------------------------------------------------
// ReconnectBackoff: MQTT yeniden baglanma (5 -> 300 sn, +-%20 jitter). QA hizli zamanlamasi icin sabitler ve jitter secenekle degisir
// (varsayilanlar = firmware).
// ---------------------------------------------------------------------------------------------------------------
export class ReconnectBackoff {
  static MIN_MS = 5000;
  static MAX_MS = 300000;
  static AUTH_REJECT_MS = 300000;   // CONNACK 4/5: kimlik/yetki reddi
  static LONG_MIN_MS = 60000;       // sertifika dogrulama hatasi: en az bu kadar bekle

  constructor({ minMs = ReconnectBackoff.MIN_MS, maxMs = ReconnectBackoff.MAX_MS, authRejectMs = ReconnectBackoff.AUTH_REJECT_MS, longMinMs = ReconnectBackoff.LONG_MIN_MS, jitter = true } = {}) {
    this.minMs = minMs;
    this.maxMs = maxMs;
    this.authRejectMs = authRejectMs;
    this.longMinMs = longMinMs;
    this.jitter = jitter;
    this.backoffMs = minMs;
    this.wait = new Wait();
  }

  service(now) { this.wait.service(now); }

  due(now) { return this.wait.elapsed(now); }

  /** Yapilandirma degisti / baglanti kuruldu. */
  reset() {
    this.backoffMs = this.minMs;
    this.wait.disarm();
  }

  /** Basarisiz denemeden sonra: bekleme kur, bir sonraki beklemeyi ikiye katla (tavan maxMs). */
  schedule(now, longWait, rnd) {
    let base = this.backoffMs;
    if (longWait && base < this.longMinMs) base = this.longMinMs;
    this.wait.arm(now, this.jitter ? jitterMs(base, rnd) : base);
    this.backoffMs = base * 2 > this.maxMs ? this.maxMs : base * 2;
  }

  scheduleAuthRejected(now, rnd) {
    this.backoffMs = this.authRejectMs;
    this.schedule(now, false, rnd);
  }

  /** Sabit bekleme (ornegin saat senkronu bekleniyor); ustel sayaca dokunmaz. */
  waitFixed(now, ms) { this.wait.arm(now, ms); }
}

// ---------------------------------------------------------------------------------------------------------------
// PublishPacer: durum yayini zamanlamasi (250 ms birlestirme, 30 sn kalp atisi, hata sonrasi ustel bekleme).
// Tetikleme bayragi baska gorevlerce kurulur; zaman damgasi GORMEZ: gorev bayragi ilk GOZLEDIGINDE birlestirme penceresini baslatir.
// ---------------------------------------------------------------------------------------------------------------
export class PublishPacer {
  static COALESCE_MS = 250;
  static HEARTBEAT_MS = 30000;
  static RETRY_MAX_MS = 30000;

  constructor() {
    this.pending = false;     // yayin bekliyor (tetik gozlendi veya hata sonrasi yeniden deneme)
    this.failCount = 0;
    this.coalesce = new Wait();
    this.retry = new Wait();
    this.heartbeat = new Wait();
  }

  service(now) {
    this.coalesce.service(now);
    this.retry.service(now);
    this.heartbeat.service(now);
  }

  /** Yayin zamani geldi mi? trigger: baska gorevlerin kurdugu bayrak. (Cagri durumu ilerletir: ilk gozlemde pencere baslar.) */
  due(now, trigger) {
    if (trigger && !this.pending) {
      this.pending = true;
      this.coalesce.arm(now, PublishPacer.COALESCE_MS);
    }
    if (!this.retry.elapsed(now)) return false;
    return this.pending ? this.coalesce.elapsed(now) : this.heartbeat.elapsed(now);
  }

  isPending() { return this.pending; }

  /** Yayin BASLARKEN (anlik goruntuden once): bekleyen istek tuketildi. */
  beginSend() {
    this.pending = false;
    this.coalesce.disarm();
  }

  sent(now) {
    this.failCount = 0;
    this.retry.disarm();
    this.heartbeat.arm(now, PublishPacer.HEARTBEAT_MS);
  }

  /** Hata: 1,2,4,8,16,30,30... sn bekle; istek korunur. Donus: bekleme (ms). */
  failed(now) {
    if (this.failCount < 250) this.failCount++;
    const shift = this.failCount > 6 ? 5 : this.failCount - 1;
    let wait = 1000 * (1 << shift);
    if (wait > PublishPacer.RETRY_MAX_MS) wait = PublishPacer.RETRY_MAX_MS;
    this.retry.arm(now, wait);
    this.pending = true;
    this.coalesce.disarm();
    return wait;
  }

  /** Baglanti (yeniden) kuruldu: ilk tam durumu gecikmeden yayinla. */
  connected() {
    this.failCount = 0;
    this.retry.disarm();
    this.heartbeat.disarm();
    this.pending = true;
    this.coalesce.disarm();
  }
}

// ---------------------------------------------------------------------------------------------------------------
// AuthLimiter: yerel API kimlik hatasi sinirlayici (IP basina 5 hata -> 60 sn kilit; 5 dk hatasizlikta unutulur;
// tum kaynaklardan 60 sn'de 20 hata -> 60 sn genel kilit). Yalniz web gorevinden kullanilir.
// ---------------------------------------------------------------------------------------------------------------
export class AuthLimiter {
  static SLOTS = 4;
  static MAX_FAILS = 5;
  static LOCK_MS = 60000;
  static FORGET_MS = 300000;
  static GLOBAL_MAX_FAILS = 20;
  static GLOBAL_WINDOW_MS = 60000;
  static GLOBAL_LOCK_MS = 60000;

  constructor() {
    this.slots = Array.from({ length: AuthLimiter.SLOTS }, () => ({ ip: 0, fails: 0, lock: new Wait(), forget: new Wait() }));
    this.gWindow = new Wait();
    this.gFails = 0;
    this.gLock = new Wait();
  }

  static #norm(ip) { return ip ? u32(ip) : 1; }

  /** Her tur: dolan kilit/unutma/pencere sayaclarini sonlandirir; bos kalan yuvalari serbest birakir. */
  service(now) {
    for (const s of this.slots) {
      if (s.ip === 0) continue;
      s.lock.service(now);
      if (s.forget.service(now)) s.fails = 0;
      if (!s.lock.armed && !s.forget.armed) {
        s.ip = 0;
        s.fails = 0;
      }
    }
    if (this.gWindow.service(now)) this.gFails = 0;
    this.gLock.service(now);
  }

  /** Kilitliyse en az 1 (sn) doner, degilse 0 (en uzun kalan kilit: IP'ye ozel veya genel). */
  locked(ip, now) {
    let rem = this.gLock.remaining(now);
    const s = this.#find(ip);
    if (s) {
      const r = s.lock.remaining(now);
      if (r > rem) rem = r;
    }
    if (rem === 0) return 0;
    return Math.floor((rem + 999) / 1000);
  }

  /** Hatali anahtar. */
  failure(ip, now) {
    const k = AuthLimiter.#norm(ip);
    let s = this.#findMutable(k);
    if (!s) s = this.#allocate(k, now);
    if (s.forget.elapsed(now)) s.fails = 0;   // 5 dk hatasizlik (service zaten sifirlar; yoklanmamis ise de guvenli)
    s.forget.arm(now, AuthLimiter.FORGET_MS);
    if (++s.fails >= AuthLimiter.MAX_FAILS) {
      s.lock.arm(now, AuthLimiter.LOCK_MS);
      s.fails = 0;
    }
    if (this.gWindow.elapsed(now)) {
      this.gWindow.arm(now, AuthLimiter.GLOBAL_WINDOW_MS);
      this.gFails = 0;
    }
    if (++this.gFails >= AuthLimiter.GLOBAL_MAX_FAILS) {
      this.gLock.arm(now, AuthLimiter.GLOBAL_LOCK_MS);
      this.gFails = 0;
    }
  }

  /** Dogru anahtar. */
  success(ip) {
    const s = this.#findMutable(AuthLimiter.#norm(ip));
    if (s) {
      s.fails = 0;
      s.lock.disarm();
    }
  }

  /** QA: tum yuvalar ve genel sayaclar temizlenir (UNPROVISION gibi durum sifirlama). */
  clear() {
    for (const s of this.slots) { s.ip = 0; s.fails = 0; s.lock.disarm(); s.forget.disarm(); }
    this.gWindow.disarm();
    this.gFails = 0;
    this.gLock.disarm();
  }

  #find(ip) {
    const k = AuthLimiter.#norm(ip);
    return this.slots.find((s) => s.ip === k) || null;
  }

  #findMutable(k) { return this.slots.find((s) => s.ip === k) || null; }

  /** Bos yuva yoksa en eski (son hatasi en uzak) yuva kurban edilir. */
  #allocate(k, now) {
    let victim = this.slots.findIndex((s) => s.ip === 0);
    if (victim < 0) {
      victim = 0;
      for (let i = 1; i < this.slots.length; i++) {
        if (this.slots[i].forget.passed(now) > this.slots[victim].forget.passed(now)) victim = i;
      }
    }
    const s = this.slots[victim];
    s.ip = k;
    s.fails = 0;
    s.lock.disarm();
    s.forget.disarm();
    return s;
  }
}

// ---------------------------------------------------------------------------------------------------------------
// ApPolicy: kurtarma/kurulum/servis AP penceresi (WiFiManager). Girdi: STA durumu ve yetki; cikti: AP'nin istenen durumu.
// 3 dk kesinti -> 10 dk pencere (istemci varsa 2 dk'lik adimlarla, en fazla 30 dk); kapaninca kesinti suruyorsa 15 dk sonra yeniden;
// STA 30 sn kararli -> pencere erken kapanir; servis AP'si (CLI) ayri sureli pencere.
// ---------------------------------------------------------------------------------------------------------------
export class ApPolicy {
  static RECOVERY_TRIGGER_MS = 180000;   // STA kesintisi bu kadar surerse pencere acilir
  static WINDOW_MS = 600000;             // pencere suresi: 10 dk
  static REOPEN_MS = 900000;             // pencere bitince kesinti suruyorsa yeniden acmadan once bekleme: 15 dk
  static MAX_EXTEND_MS = 1800000;        // istemci bagliyken pencere en fazla 30 dk uzar
  static EXTEND_STEP_MS = 120000;        // uzatma adimi: 2 dk
  static STABLE_MS = 30000;              // STA bu kadar kararli olunca pencere erken kapanir
  static RESTART_DELAY_MS = 1500;        // ap_pass degisince yeniden baslatma gecikmesi

  /**
   * ethUp (v1.3.0): Ethernet bagli VE cihaz provizyonlu (net_link.js apPolicyEthUp). Provizyonsuz kartta HER ZAMAN false; false iken davranis
   * v1.2.1 ile birebir aynidir.
   * @returns {{allowed:boolean, connected:boolean, ethUp:boolean, staConfigured:boolean, apActive:boolean, clients:number}}
   */
  static makeIn() { return { allowed: false, connected: false, ethUp: false, staConfigured: false, apActive: false, clients: 0 }; }

  static #makeOut() {
    return { desired: false, startAp: false, stopAp: false, restartAp: false, opened: false, extended: false, ended: false, closedStable: false, serviceExpired: false };
  }

  constructor() {
    this.windowOpen = false;
    this.trigger = false;          // kesinti tetigi (3 dk) tutuldu
    this.stableOk = false;         // STA 30 sn kararli
    this.restartPending = false;
    this.primed = false;
    this.prevConnected = false;
    this.window = new Wait();      // mevcut pencere dilimi (10 dk; uzatmada 2 dk)
    this.cap = new Wait();         // en fazla uzama siniri (30 dk, pencere acilisindan)
    this.reopen = new Wait();      // pencere bittikten sonra yeniden acma beklemesi
    this.service = new Wait();     // servis AP penceresi
    this.restart = new Wait();     // ap_pass degisikligi sonrasi yeniden baslatma gecikmesi
    this.disc = new Wait();        // STA kesintisi sayaci
    this.stable = new Wait();      // STA kararlilik sayaci
  }

  /** Servis modu: AP'yi sureli acar (windowMs = 0 ise 1 ms: hemen dolar). */
  openService(now, windowMs) { this.service.arm(now, windowMs ? windowMs : 1); }

  /** AP'yi hemen kapat: servis ve kurtarma pencereleri iptal; kesinti suruyorsa REOPEN_MS sonra yeniden acilabilir. */
  closeAll(now) {
    this.service.disarm();
    this.#closeWindow();
    this.reopen.arm(now, ApPolicy.REOPEN_MS);
  }

  /** ap_pass / provizyon durumu degisti: acik AP RESTART_DELAY_MS sonra yeni ilkeyle yeniden baslar. */
  requestRestart(now) {
    this.restartPending = true;
    this.restart.arm(now, ApPolicy.RESTART_DELAY_MS);
  }

  update(now, inp) {
    const out = ApPolicy.#makeOut();

    // 1) zamanlayicilari yokla (dolanlar sonlanir; sarma/eskime olusmaz)
    if (this.service.service(now)) out.serviceExpired = true;
    this.cap.service(now);
    this.reopen.service(now);
    this.restart.service(now);

    // 2) Ag baglanti kenarlari: kesinti sayaci (3 dk) ve kararlilik sayaci (30 sn). "Ag" = STA bagli VEYA (Ethernet bagli ve provizyonlu).
    const netConnected = !!inp.connected || !!inp.ethUp;
    if (!this.primed || netConnected !== this.prevConnected) {
      this.primed = true;
      this.prevConnected = netConnected;
      if (netConnected) {
        this.disc.disarm();
        this.trigger = false;
        this.stable.arm(now, ApPolicy.STABLE_MS);
        this.stableOk = false;
      } else {
        this.stable.disarm();
        this.stableOk = false;
        this.disc.arm(now, ApPolicy.RECOVERY_TRIGGER_MS);
        this.trigger = false;
      }
    }
    if (this.disc.service(now)) this.trigger = true;
    if (this.stable.service(now)) this.stableOk = true;

    // 3) pencere. Kayitli STA yoksa pencere acilir -- AMA provizyonlu kart Ethernet'le bagliyken degil (v1.3.0 duzeltmesi: aksi halde AP'yi
    // 10 dk acik / 15 dk kapali sonsuza dek dongulerdi).
    const trig = (!inp.staConfigured && !inp.ethUp) || this.trigger;
    if (!this.windowOpen) {
      if (inp.allowed && trig && this.reopen.elapsed(now)) {
        this.windowOpen = true;
        this.window.arm(now, ApPolicy.WINDOW_MS);
        this.cap.arm(now, ApPolicy.MAX_EXTEND_MS);
        out.opened = true;
      }
    } else if (netConnected && (inp.staConfigured || inp.ethUp) && this.stableOk) {
      this.#closeWindow();          // histerezis: ag (STA ya da provizyonlu kartta Ethernet) 30 sn kararli
      this.reopen.disarm();
      out.closedStable = true;
    } else if (this.window.service(now)) {
      if (inp.clients > 0 && this.cap.isArmed()) {
        this.window.arm(now, ApPolicy.EXTEND_STEP_MS);   // kullanici islem yapiyor: pencere uzar
        out.extended = true;
      } else {
        this.#closeWindow();
        this.reopen.arm(now, ApPolicy.REOPEN_MS);
        out.ended = true;
      }
    }

    // 4) AP'nin istenen durumu
    out.desired = inp.allowed && (this.service.isArmed() || this.windowOpen);
    if (out.desired && !inp.apActive) {
      out.startAp = true;
      this.#clearRestart();
    } else if (!out.desired && inp.apActive) {
      out.stopAp = true;
      this.#clearRestart();
    } else if (out.desired && inp.apActive && this.restartPending && this.restart.elapsed(now)) {
      out.restartAp = true;
      this.#clearRestart();
    } else if (!inp.apActive) {
      this.#clearRestart();
    }
    return out;
  }

  #closeWindow() {
    this.windowOpen = false;
    this.window.disarm();
    this.cap.disarm();
  }

  #clearRestart() {
    this.restartPending = false;
    this.restart.disarm();
  }
}

// ---------------------------------------------------------------------------------------------------------------
// StaMachine: otomatik STA baglanma (15 sn deneme zaman asimi, 2 -> 60 sn ustel geri cekilme).
// ---------------------------------------------------------------------------------------------------------------
export const StaState = Object.freeze({ IDLE: 0, CONNECTING: 1, CONNECTED: 2, BACKOFF: 3 });
export const StaAction = Object.freeze({ NONE: 0, BEGIN: 1, TIMEOUT: 2 });

export class StaMachine {
  static ATTEMPT_TIMEOUT_MS = 15000;
  static MIN_BACKOFF_MS = 2000;
  static MAX_BACKOFF_MS = 60000;
  static CANDIDATE_RETRY_MS = 1500;

  constructor() {
    this.state = StaState.IDLE;
    this.backoffMs = StaMachine.MIN_BACKOFF_MS;
    this.attempt = new Wait();   // baglanma denemesi zaman asimi
    this.retry = new Wait();     // bir sonraki deneme icin bekleme
  }

  service(now) {
    this.attempt.service(now);
    this.retry.service(now);
  }

  /**
   * connected: STA bagli; ssidSet: kayitli kimlik var; evtDisc: son denemeden sonra kopma olayi geldi;
   * apBlocks: kurulum AP'sine istemci bagli (tarama AP'yi bozmasin diye deneme yapilmaz).
   */
  update(now, connected, ssidSet, evtDisc, apBlocks) {
    this.service(now);
    if (connected) {
      this.state = StaState.CONNECTED;
      this.backoffMs = StaMachine.MIN_BACKOFF_MS;
      return StaAction.NONE;
    }
    if (!ssidSet) {
      this.state = StaState.IDLE;
      return StaAction.NONE;
    }
    if (this.state === StaState.CONNECTED) {   // baglanti az once koptu: kisa beklemeyle yeniden dene
      this.state = StaState.BACKOFF;
      this.retry.arm(now, StaMachine.MIN_BACKOFF_MS);
      return StaAction.NONE;
    }
    if (this.state === StaState.CONNECTING) {
      if (evtDisc || this.attempt.elapsed(now)) {
        this.state = StaState.BACKOFF;
        this.retry.arm(now, this.backoffMs);
        this.backoffMs = this.backoffMs * 2 > StaMachine.MAX_BACKOFF_MS ? StaMachine.MAX_BACKOFF_MS : this.backoffMs * 2;
        return StaAction.TIMEOUT;
      }
      return StaAction.NONE;
    }
    // IDLE / BACKOFF: bekleme doldu mu?
    if (!this.retry.elapsed(now)) return StaAction.NONE;
    if (apBlocks) return StaAction.NONE;
    this.state = StaState.CONNECTING;
    this.attempt.arm(now, StaMachine.ATTEMPT_TIMEOUT_MS);
    return StaAction.BEGIN;
  }

  /** Yeni kimlik / elle yeniden baglanma: geri cekilmeyi sifirla, hemen dene. */
  reset() {
    this.state = StaState.IDLE;
    this.backoffMs = StaMachine.MIN_BACKOFF_MS;
    this.attempt.disarm();
    this.retry.disarm();
  }

  reconnectNow() {
    this.backoffMs = StaMachine.MIN_BACKOFF_MS;
    this.retry.disarm();
    if (this.state === StaState.BACKOFF) this.state = StaState.IDLE;
  }

  /** Aday akisi (WiFiManager::requestConnect) otomatik yolu devraldi / birakti. */
  candidateStarted() {
    this.state = StaState.IDLE;
    this.attempt.disarm();
  }

  markConnected() {
    this.state = StaState.CONNECTED;
    this.backoffMs = StaMachine.MIN_BACKOFF_MS;
  }

  candidateFailed(now, hadOldCredentials) {
    this.state = hadOldCredentials ? StaState.BACKOFF : StaState.IDLE;
    this.retry.arm(now, StaMachine.CANDIDATE_RETRY_MS);
    this.backoffMs = StaMachine.MIN_BACKOFF_MS;
  }
}

// ---------------------------------------------------------------------------------------------------------------
// CandidateFlow: POST /api/wifi/connect aday kimlik akisi: 0,5 sn (HTTP yaniti) -> eski baglantiyi birak 0,4 sn -> baglan (25 sn zaman
// asimi) -> dogrulandi (COMMIT) veya basarisiz (FAILED, eski kimlige donus).
// ---------------------------------------------------------------------------------------------------------------
export const CandPhase = Object.freeze({ NONE: 0, WAIT: 1, DISCONNECTING: 2, CONNECTING: 3 });
export const CandAction = Object.freeze({ NOTHING: 0, DO_DISCONNECT: 1, DO_BEGIN: 2, COMMIT: 3, FAILED: 4 });

export class CandidateFlow {
  static START_DELAY_MS = 500;
  static DISCONNECT_WAIT_MS = 400;
  static TIMEOUT_MS = 25000;

  constructor() {
    this.phase = CandPhase.NONE;
    this.wait = new Wait();
  }

  start(now) {
    this.phase = CandPhase.WAIT;
    this.wait.arm(now, CandidateFlow.START_DELAY_MS);
  }

  cancel() {
    this.phase = CandPhase.NONE;
    this.wait.disarm();
  }

  /** connectedSinceBegin: DO_BEGIN'den SONRA yeni bir IP alindi (sayac ile; zaman damgasi karsilastirmasi yok). */
  update(now, connectedSinceBegin, evtDisc) {
    this.wait.service(now);
    switch (this.phase) {
      case CandPhase.NONE:
        return CandAction.NOTHING;
      case CandPhase.WAIT:
        if (!this.wait.elapsed(now)) return CandAction.NOTHING;
        this.phase = CandPhase.DISCONNECTING;
        this.wait.arm(now, CandidateFlow.DISCONNECT_WAIT_MS);
        return CandAction.DO_DISCONNECT;
      case CandPhase.DISCONNECTING:
        if (!this.wait.elapsed(now)) return CandAction.NOTHING;
        this.phase = CandPhase.CONNECTING;
        this.wait.arm(now, CandidateFlow.TIMEOUT_MS);
        return CandAction.DO_BEGIN;
      case CandPhase.CONNECTING:
        if (connectedSinceBegin) {
          this.cancel();
          return CandAction.COMMIT;
        }
        if (evtDisc || this.wait.elapsed(now)) {
          this.cancel();
          return CandAction.FAILED;
        }
        return CandAction.NOTHING;
      default:
        return CandAction.NOTHING;
    }
  }
}

// ---------------------------------------------------------------------------------------------------------------
// ScanGate: /api/wifi/scan hiz siniri (>= 10 sn), onbellek omru (120 sn) ve takilmis tarama zaman asimi (15 sn).
// ---------------------------------------------------------------------------------------------------------------
export const ScanDriver = Object.freeze({ RUNNING: 0, DONE: 1, FAILED: 2 });
export const ScanPoll = Object.freeze({ IDLE: 0, RUNNING: 1, DONE: 2, FAILED: 3 });
export const ScanDecision = Object.freeze({ START: 0, SCANNING: 1, RESULT: 2 });

export class ScanGate {
  static MIN_INTERVAL_MS = 10000;
  static CACHE_TTL_MS = 120000;
  static TIMEOUT_MS = 15000;

  constructor() {
    this.inProgress = false;
    this.timeout = new Wait();
    this.rate = new Wait();
    this.ttl = new Wait();
  }

  service(now) {
    this.timeout.service(now);
    this.rate.service(now);
    this.ttl.service(now);
  }

  /** Devam eden tarama varsa durumunu degerlendirir. d: ScanDriver. */
  poll(now, d) {
    if (!this.inProgress) return ScanPoll.IDLE;
    if (d === ScanDriver.DONE) {
      this.inProgress = false;
      this.timeout.disarm();
      return ScanPoll.DONE;
    }
    if (d === ScanDriver.FAILED || this.timeout.elapsed(now)) {
      this.inProgress = false;
      this.timeout.disarm();
      return ScanPoll.FAILED;
    }
    return ScanPoll.RUNNING;
  }

  /** Sonuclar onbellege yazildi. */
  cacheStored(now) { this.ttl.arm(now, ScanGate.CACHE_TTL_MS); }

  /** Yeni tarama gerekli mi? haveCache: onbellekte sonuc var. @returns {{decision:number, cached:boolean}} (cached: liste onbellekten mi sunuluyor) */
  decide(now, refresh, connecting, haveCache) {
    const cacheFresh = haveCache && !this.ttl.elapsed(now);
    const rateLimited = !this.rate.elapsed(now);
    const needScan = refresh || !cacheFresh;
    if (needScan && !connecting) {
      if (!rateLimited) {
        this.inProgress = true;
        this.timeout.arm(now, ScanGate.TIMEOUT_MS);
        this.rate.arm(now, ScanGate.MIN_INTERVAL_MS);
        return { decision: ScanDecision.START, cached: false };
      }
      if (!haveCache) return { decision: ScanDecision.SCANNING, cached: false };   // hiz siniri bitince tarama baslayacak
    }
    return { decision: ScanDecision.RESULT, cached: !needScan || rateLimited };
  }
}
