// Firmware NetTime (src/NetTime.h) JS portunun UYUMLULUK testi: firmware'in kendi Unity testlerinin
// (ev_otomasyon_servis_yazilimi/waveshare_s3_demo/test/test_net_time/test_main.cpp) 27 testinin BIREBIR portu.
//
// N6 / CONTRACTS 3c ZAMAN KURALI: millis() 24,86 gunde 2^31'i, 49,7 gunde 2^32'yi asar. Saklanmis "hedef zaman" + isaretli karsilastirma, hedef eski
// kalinca zamanlayiciyi DONDURUR. Bu testler ag katmaninin her zamanlayicisini (MQTT yeniden baglanma/abonelik penceresi/yayin pacer'i, yerel API kimlik
// kilitleri, AP pencereleri, STA/aday Wi-Fi, tarama kapisi) sarma sinirlarinda (0, 2^31, 2^32 civari) ve 24,86 / 49,7 gunluk sessizliklerde dener; eski
// deseni (legacyDue) ayni senaryoda DONDURDUGUNU gosterir, yeni mantik donmaz. AP penceresi, eski algoritmanin 64 bit zamanli referans modeliyle rastgele
// senaryolarda KARSILASTIRILIR. (C++ `CHECK(kod, kosul)` -> check(); `return kod` -> Fail istisnasi; run() sifir/kodu dondurur.)
import test from 'node:test';
import assert from 'node:assert/strict';
import {
  Wait, jitterMs, ReconnectBackoff, PublishPacer, AuthLimiter, ApPolicy, StaMachine, StaState, StaAction, CandidateFlow, CandPhase, CandAction,
  ScanGate, ScanDriver, ScanPoll, ScanDecision, u32,
} from '../sim/fw/net_time.js';

class Fail extends Error { constructor(code) { super(`kontrol ${code}`); this.code = code; } }
const check = (code, cond) => { if (!cond) throw new Fail(code); };
/** @returns {number} 0 = tamam; aksi halde basarisiz kontrol kodu */
const run = (fn, ...args) => {
  try { fn(...args); return 0; } catch (e) { if (e instanceof Fail) return e.code; throw e; }
};

const MINUTE = 60 * 1000;
const DAY = 86400000;

// Zaman tabanlari: 0, 2^30, 2^31 ve 2^32 sinirlarinin hemen oncesi/sonrasi
const kBases = [0, 5000, 0x40000000, 0x7FFFFF00, 0x7FFFFFF0, 0x80000000, 0x80000010, 0xFFFFF000, 0xFFFFFFF0, 0xFFFFFFFF];
// Uzun taramalar icin daha az taban (ilki sarmaya en yakin)
const kLongBases = [0, 0x7FFFF000, 0xFFFF0000];
// Sessizlik sureleri: 10 sn, 1 gun, 24,86 gunun (2^31 ms) hemen altinda/ustunde, 30 gun, 49,7 gunun (2^32 ms) hemen altinda/ustunde, 60 gun
const kIdle = [10 * 1000, 1 * DAY, 0x80000000 - 100, 0x80000000 + 100, 24 * DAY + 20 * 3600 * 1000, 25 * DAY, 30 * DAY, 0x100000000 - 100, 0x100000000 + 100,
  0x100000000 + 5000, 0x100000000 + 20 * 60 * 1000, 60 * DAY];
// "Sessizlik" dongulerinde yoklama adimi (testin amaci, sinirlarin cok altinda kaldigi surece zamanlayicinin donmadigini gostermektir)
const kIdleStep = 60000;

// Eski (N6 oncesi) desen: hedef zaman sakla + isaretli karsilastir. YALNIZ "bu desen donar" gosterimi icin.
const legacyDue = (now, target) => target === 0 || ((u32(now) - u32(target)) | 0) >= 0;

let gRng = 1;
const rnd = () => {
  gRng = (Math.imul(gRng, 1664525) + 1013904223) >>> 0;
  return gRng >>> 8;
};

// ---------------------------------------------------------------------------------------------------------------
// Wait
// ---------------------------------------------------------------------------------------------------------------
function waitBoundaries(b) {
  const w = new Wait();
  check(1, w.elapsed(b));   // kurulu degil -> dolmus
  check(2, !w.isArmed() && w.remaining(b) === 0 && w.passed(b) === 0);
  w.arm(b, 5000);
  check(3, !w.elapsed(b));
  check(4, !w.elapsed(u32(b + 4999)));
  check(5, w.elapsed(u32(b + 5000)));
  check(6, w.remaining(b) === 5000);
  check(7, w.remaining(u32(b + 4999)) === 1);
  check(8, w.remaining(u32(b + 5000)) === 0);
  check(9, w.passed(u32(b + 1234)) === 1234);
  check(10, !w.service(u32(b + 4999)));
  check(11, w.isArmed());
  check(12, w.running(u32(b + 4999)));
  check(13, w.service(u32(b + 5000)));
  check(14, !w.isArmed());
  check(15, !w.service(u32(b + 5001)));
  check(16, w.elapsed(u32(b + 5001)));   // sonlanmis -> dolmus
  w.arm(b, 100);
  check(17, w.running(u32(b + 99)));
  check(18, !w.running(u32(b + 100)));
  check(19, !w.isArmed());
  w.arm(b, 0);
  check(20, w.elapsed(b));
}

/** Tek zamanlayici, tur basina yoklanir: tam bir kez dolar, sonra hep "dolmus" kalir (sarma/49,7 gun: yeniden dogmaz). */
function waitSweep(base, span, tick, totalMs) {
  const w = new Wait();
  w.arm(base, span);
  let fired = 0;
  let firedAt = 0;
  for (let t = 0; t <= totalMs; t += tick) {
    const now = u32(base + t);
    if (w.service(now)) {
      fired++;
      firedAt = t;
    }
    if (t >= span + tick && w.isArmed()) throw new Fail(1);
    if (t >= span && !w.elapsed(now)) throw new Fail(2);
  }
  check(3, fired === 1);
  check(4, firedAt >= span && firedAt < span + tick);
}

function jitterBounds() {
  const bases = [0, 7, 5000, 10000, 60000, 300000];
  for (const base of bases) {
    const span = Math.floor(base / 5);
    const rs = [0, 1, 2, span, 2 * span - (span ? 1 : 0), 2 * span, 2 * span + 1, 0x7FFFFFFF, 0xFFFFFFFF];
    for (const r of rs) {
      const j = jitterMs(base, r);
      check(1, j >= base - span && j <= base + span);
    }
    check(2, jitterMs(base, 0) === base - span);
    check(3, jitterMs(base, 2 * span) === base + span);
  }
}

// ---------------------------------------------------------------------------------------------------------------
// ReconnectBackoff (MQTT yeniden baglanma)
// ---------------------------------------------------------------------------------------------------------------
function backoffSequence(base) {
  const b = new ReconnectBackoff();
  let now = base;
  check(1, b.due(now));   // hic planlanmamis: hemen
  const expectBase = [5000, 10000, 20000, 40000, 80000, 160000, 300000, 300000];
  for (let i = 0; i < 8; i++) {
    b.schedule(now, false, 0xFFFFFFFF);
    const w = jitterMs(expectBase[i], 0xFFFFFFFF);
    check(10 + i, b.wait.span === w);
    check(20 + i, !b.due(u32(now + w - 1)));
    check(30 + i, b.due(u32(now + w)));
    now = u32(now + w);
  }
  b.reset();
  check(40, b.due(now) && b.backoffMs === 5000);
  b.schedule(now, true, 0);   // sertifika dogrulama hatasi: taban 60 sn
  check(41, b.wait.span === jitterMs(60000, 0));
  check(42, b.backoffMs === 120000);
  b.reset();
  b.scheduleAuthRejected(now, 0);   // CONNACK 4/5: 300 sn
  check(43, b.wait.span === jitterMs(300000, 0));
  check(44, b.backoffMs === 300000);
  b.reset();
  b.waitFixed(now, 2000);           // saat senkronu bekleme: ustel sayaca dokunmaz
  check(45, b.wait.span === 2000 && b.backoffMs === 5000);
  check(46, !b.due(u32(now + 1999)) && b.due(u32(now + 2000)));
}

/** Wi-Fi uzun sure yok (gorev yalniz zamanlayicilari yoklar): geri geldiginde ilk deneme HEMEN yapilmali. */
function reconnectNotFrozenAfterOutage(base, outageMs) {
  const b = new ReconnectBackoff();
  b.schedule(base, false, 123);   // son kopusta kurulan bekleme
  for (let t = 0; t < outageMs; t += kIdleStep) b.service(u32(base + t));
  check(1, b.due(u32(base + outageMs)));
  // ayni senaryoda eski desen (hedef = base + bekleme): 24,86 gun sonrasinda DONAR
  const legacyTarget = u32(base + jitterMs(5000, 123));
  if (outageMs >= 0x80000000 + 20000 && outageMs < 0xFFFFFFFF - 20000) {
    check(2, !legacyDue(u32(base + outageMs), legacyTarget));
  }
}

// ---------------------------------------------------------------------------------------------------------------
// Abonelik sonrasi "ilk 1500 ms yok say" penceresi (MqttManager::onMessage)
// ---------------------------------------------------------------------------------------------------------------
function ignoreWindow(base, idleMs) {
  const v = new Wait();
  v.arm(base, 1500);
  check(1, v.running(base));
  check(2, v.running(u32(base + 1499)));    // 1499 ms: yok sayilir
  check(3, !v.running(u32(base + 1500)));   // 1500 ms: islenir
  check(4, !v.running(u32(base + 1501)));   // kalici kapali
  // uzun sessizlik: gorev dongusu pencereyi yoklar, mesaj YOK; ilk komut yine ISLENMELI
  const u = new Wait();
  u.arm(base, 1500);
  for (let t = 0; t < idleMs; t += kIdleStep) u.service(u32(base + t));
  check(5, !u.running(u32(base + idleMs)));
  // eski desen: ayni sessizlikte pencere "hala acik" sanilir -> TUM komutlar yok sayilirdi
  const legacyUntil = u32(base + 1500);
  if (idleMs >= 0x80000000 + 2000 && idleMs < 0xFFFFFFFF - 2000) {
    check(6, !legacyDue(u32(base + idleMs), legacyUntil));
  }
}

// ---------------------------------------------------------------------------------------------------------------
// PublishPacer
// ---------------------------------------------------------------------------------------------------------------
function pacerCoalesceHeartbeat(b) {
  const p = new PublishPacer();
  p.connected();                              // baglanti kuruldu: ilk yayin gecikmeden
  check(1, p.due(b, false));
  p.beginSend();
  p.sent(b);
  check(2, !p.due(u32(b + 100), false));      // kalp atisi 30 sn
  check(3, !p.due(u32(b + 29999), false));
  check(4, p.due(u32(b + 30000), false));
  // tetik: 250 ms birlestirme, ikinci tetik pencereyi UZATMAZ
  p.beginSend();
  p.sent(u32(b + 30000));
  const t0 = u32(b + 40000);
  check(5, !p.due(t0, true));
  check(6, !p.due(u32(t0 + 100), true));      // ikinci tetik
  check(7, !p.due(u32(t0 + 249), true));
  check(8, p.due(u32(t0 + 250), true));
  p.beginSend();
  p.sent(u32(t0 + 250));
  check(9, !p.due(u32(t0 + 251), false));     // bayrak yok, kalp atisi yok
  check(10, p.due(u32(t0 + 250 + 30000), false));
}

function pacerFailureBackoff(b) {
  const p = new PublishPacer();
  p.connected();
  let now = b;
  const expect = [1000, 2000, 4000, 8000, 16000, 30000, 30000, 30000];
  for (let i = 0; i < 8; i++) {
    check(1 + i, p.due(now, false));      // gonderilmeli
    p.beginSend();
    const w = p.failed(now);
    check(10 + i, w === expect[i]);
    check(20 + i, p.isPending());         // istek korunur
    check(30 + i, !p.due(u32(now + w - 1), false));
    check(40 + i, p.due(u32(now + w), false));
    now = u32(now + w);
  }
  p.beginSend();
  p.sent(now);                            // basari: sayac sifirlanir
  p.beginSend();
  check(50, p.failed(now) === 1000);
}

/** Baglanti yokken tetik bayragi aylarca "kurulu" kalir; yeniden baglaninca ilk yayin HEMEN yapilmali. */
function pacerAfterLongDisconnect(base, idleMs) {
  const p = new PublishPacer();
  p.connected();
  p.beginSend();
  p.sent(base);
  for (let t = 0; t < idleMs; t += kIdleStep) p.service(u32(base + t));   // koptu: yalniz yoklanir
  const back = u32(base + idleMs);
  p.connected();
  check(1, p.due(back, true));
  p.beginSend();
  p.sent(back);
  check(2, !p.due(u32(back + 1000), false));
  check(3, p.due(u32(back + 30000), false));
}

/** Bagli kalinan sureler boyunca kalp atisi tam zamaninda ve her 30 sn'de bir */
function pacerHeartbeatSweep(base, totalMs) {
  const p = new PublishPacer();
  p.connected();
  let sent = 0;
  let lastSent = 0;
  p.beginSend();
  p.sent(base);
  for (let t = 5000; t <= totalMs; t += 5000) {
    const now = u32(base + t);
    p.service(now);
    if (p.due(now, false)) {
      check(1, t - lastSent === 30000);
      p.beginSend();
      p.sent(now);
      lastSent = t;
      sent++;
    }
  }
  check(2, sent === Math.floor(totalMs / 30000));
}

// ---------------------------------------------------------------------------------------------------------------
// AuthLimiter (locked(): kilitliyse Retry-After sn (>= 1), degilse 0)
// ---------------------------------------------------------------------------------------------------------------
function authLockBasics(b) {
  const a = new AuthLimiter();
  const ip = 0xC0A80164;
  for (let i = 0; i < 4; i++) {
    a.failure(ip, u32(b + i * 1000));
    check(1 + i, a.locked(ip, u32(b + i * 1000)) === 0);
  }
  a.failure(ip, u32(b + 4000));   // 5. hata
  check(10, a.locked(ip, u32(b + 4000)) === 60);
  check(11, a.locked(ip, u32(b + 4000 + 59999)) === 1);
  check(12, a.locked(ip, u32(b + 4000 + 60000)) === 0);
  check(13, a.locked(0xC0A80165, u32(b + 4001)) === 0);          // baska IP etkilenmez
  // dogru anahtar sayaci sifirlar
  const c = new AuthLimiter();
  for (let i = 0; i < 4; i++) c.failure(ip, b);
  c.success(ip);
  c.failure(ip, u32(b + 10));
  check(14, c.locked(ip, u32(b + 10)) === 0);
  // 5 dk hatasizlik: sayac unutulur
  const d = new AuthLimiter();
  let now = b;
  for (let i = 0; i < 4; i++) d.failure(ip, now);
  for (let t = 0; t <= 300000; t += 250) d.service(u32(now + t));
  now = u32(now + 300000);
  d.failure(ip, now);                                         // sayac 1'den baslar
  check(15, d.locked(ip, now) === 0);
  for (let i = 0; i < 3; i++) d.failure(ip, now);
  check(16, d.locked(ip, now) === 0);                          // 4 hata
  d.failure(ip, now);
  check(17, d.locked(ip, now) !== 0);                          // 5. hata
  // ip == 0 bilinmeyen kaynak: ortak yuva
  const e = new AuthLimiter();
  for (let i = 0; i < 5; i++) e.failure(0, b);
  check(18, e.locked(0, b) !== 0);
}

function authGlobalLock(b) {
  const a = new AuthLimiter();
  // 20 farkli kaynaktan 60 sn icinde 20 hata -> genel kilit (yuvalar yeniden kullanilir)
  for (let i = 0; i < 20; i++) {
    const now = u32(b + i * 1000);
    a.failure(0x0A000000 + i + 1, now);
    a.service(now);
    if (i < 19) check(1, a.locked(0x0A0000FF, now) === 0);
  }
  check(2, a.locked(0x0A0000FF, u32(b + 19000)) === 60);    // hic hata yapmamis istemci de kilitli
  check(3, a.locked(0x0A0000FF, u32(b + 19000 + 59999)) === 1);
  check(4, a.locked(0x0A0000FF, u32(b + 19000 + 60000)) === 0);
  // 60 sn penceresi dolarsa sayac sifirlanir: 19 hata + bekle + 19 hata kilitlemez
  const c = new AuthLimiter();
  let now = b;
  for (let i = 0; i < 19; i++) c.failure(0x0B000000 + i + 1, now);
  for (let t = 0; t <= 61000; t += 250) c.service(u32(now + t));
  now = u32(now + 61000);
  for (let i = 0; i < 19; i++) c.failure(0x0B100000 + i + 1, now);
  check(5, c.locked(0x0B0000FF, now) === 0);
}

function authSlotEviction(b) {
  const a = new AuthLimiter();
  // 4 yuva: her kaynak 3 hata (toplam 12 < genel sinir 20, hicbiri kilitli degil)
  for (let i = 0; i < 4; i++) {
    for (let k = 0; k < 3; k++) a.failure(100 + i, u32(b + i * 1000));
    a.service(u32(b + i * 1000));
  }
  a.failure(200, u32(b + 5000));   // 5. kaynak: en eski yuva (ip 100) kurban
  // ip 101, 102, 103 sayaclarini korur (3 hata): iki hata daha -> kilit
  a.failure(102, u32(b + 5001));
  check(1, a.locked(102, u32(b + 5001)) === 0);
  a.failure(102, u32(b + 5002));
  check(2, a.locked(102, u32(b + 5002)) !== 0);
  a.failure(103, u32(b + 5003));
  a.failure(103, u32(b + 5004));
  check(3, a.locked(103, u32(b + 5004)) !== 0);
  // ip 100 yeniden gelir: sayaci sifirdan baslar (1 hata, kilit yok); bu da en eski yuvayi (101) kurban eder
  a.failure(100, u32(b + 5005));
  check(4, a.locked(100, u32(b + 5005)) === 0);
  check(5, a.locked(102, u32(b + 5005)) !== 0);   // kilitli yuvalar korunur
  // 101 kurban edildi: sayaci sifirdan baslar (kilit icin 5 hata gerekir)
  a.failure(101, u32(b + 5006));
  check(6, a.locked(101, u32(b + 5006)) === 0);
}

/** Bir kez kilitlenen istemci aylarca sessiz kalir: kilit sonsuza dek "devam ediyor" gorunmemeli (423 hatasi). */
function authLockNotStuckAfterIdle(base, idleMs) {
  const a = new AuthLimiter();
  const ip = 0xC0A80101;
  const stillLocked = idleMs < 60000;   // 60 sn'den kisa sessizlikte kilit dogal olarak suruyor
  for (let i = 0; i < 5; i++) a.failure(ip, base);
  check(1, a.locked(ip, base) !== 0);
  for (let t = 0; t < idleMs; t += kIdleStep) a.service(u32(base + t));
  const back = u32(base + idleMs);
  check(2, (a.locked(ip, back) !== 0) === stillLocked);
  if (!stillLocked) {
    a.failure(ip, back);
    check(3, a.locked(ip, back) === 0);      // sayac yeniden 1'den
  }
  // eski desen: kilit bitisi = base + 60 sn saklanir; 24,86 gun sonrasi "hala kilitli" sanilirdi
  const legacyUntil = u32(base + 60000);
  if (idleMs >= 0x80000000 + 70000 && idleMs < 0xFFFFFFFF - 70000) {
    check(4, !legacyDue(u32(base + idleMs), legacyUntil));
  }
  // genel kilit icin ayni senaryo
  const g = new AuthLimiter();
  for (let i = 0; i < 20; i++) g.failure(0x0C000000 + i + 1, base);
  check(5, g.locked(0x0C0000FF, base) !== 0);
  for (let t = 0; t < idleMs; t += kIdleStep) g.service(u32(base + t));
  check(6, (g.locked(0x0C0000FF, back) !== 0) === stillLocked);
}

// ---------------------------------------------------------------------------------------------------------------
// ApPolicy: dogrudan senaryolar
// ---------------------------------------------------------------------------------------------------------------
class ApSim {
  constructor(base, tickMs) {
    this.p = new ApPolicy();
    this.inp = ApPolicy.makeIn();
    this.inp.allowed = true;
    this.inp.connected = false;
    this.inp.staConfigured = true;
    this.now = u32(base);
    this.tick = tickMs;
    this.apActive = false;
  }

  /** Bir tur: AP durumunu girdiye yansitir, politikayi calistirir, istenen eylemi uygular. */
  step() {
    this.inp.apActive = this.apActive;
    if (!this.apActive) this.inp.clients = 0;
    const o = this.p.update(this.now, this.inp);
    if (o.startAp) this.apActive = true;
    if (o.stopAp) this.apActive = false;
    this.now = u32(this.now + this.tick);
    return o;
  }

  run(ms) { for (let t = 0; t < ms; t += this.tick) this.step(); }
}

function apDirect(b) {
  // 3 dk kesinti -> pencere; 10 dk sonra kapanir; 15 dk bekler; tekrar acilir
  const s = new ApSim(b, 250);
  s.inp.connected = false;
  let openedAt = 0; let opened = false;
  let endedAt = 0; let ended = false;
  let reopenedAt = 0; let reopened = false;
  const start = s.now;
  for (let t = 0; t < 40 * 60 * 1000; t += 250) {
    const at = s.now;
    const o = s.step();
    if (o.opened) {
      if (!opened) { opened = true; openedAt = at; } else if (!reopened) { reopened = true; reopenedAt = at; }
    }
    if (o.ended && !ended) { ended = true; endedAt = at; }
  }
  check(1, opened && u32(openedAt - start) >= 180000 && u32(openedAt - start) < 180000 + 500);
  check(2, ended && u32(endedAt - openedAt) >= 600000 && u32(endedAt - openedAt) < 600000 + 500);
  check(3, reopened && u32(reopenedAt - endedAt) >= 900000 && u32(reopenedAt - endedAt) < 900000 + 500);

  // istemci bagliyken 2 dk'lik adimlarla uzar, 30 dk'da biter
  const c = new ApSim(b, 250);
  c.inp.connected = false;
  let o1 = 0; let got = false; let last = 0; let extended = 0;
  const st = c.now;
  for (let t = 0; t < 45 * 60 * 1000; t += 250) {
    const at = c.now;
    if (c.apActive) c.inp.clients = 1;
    const o = c.step();
    if (o.opened && !got) { got = true; o1 = at; }
    if (o.extended) extended++;
    if (o.ended) last = at;
  }
  check(10, got && u32(o1 - st) >= 180000);
  check(11, extended === 10);                                 // 10 dk + 10 x 2 dk = 30 dk
  check(12, last !== 0 && u32(last - o1) >= 1800000 && u32(last - o1) < 1800000 + 500);

  // STA 30 sn kararli: pencere erken kapanir, yeniden acma bekleme sayaci iptal edilir
  const d = new ApSim(b, 250);
  d.inp.connected = false;
  d.run(190 * 1000);
  check(20, d.apActive);
  d.inp.connected = true;
  let closedAt = 0;
  const conAt = d.now;
  for (let t = 0; t < 60 * 1000; t += 250) {
    const at = d.now;
    const o = d.step();
    if (o.closedStable && !closedAt) closedAt = at;
  }
  check(21, closedAt !== 0 && u32(closedAt - conAt) >= 30000 && u32(closedAt - conAt) < 30500);
  check(22, !d.apActive);
  // yeniden kesinti: 3 dk sonra HEMEN acilir (reopen bekleme sayaci iptal edildi)
  d.inp.connected = false;
  d.run(185 * 1000);
  check(23, d.apActive);

  // servis AP penceresi (CLI "AP ON"): 10 dk
  const e = new ApSim(b, 250);
  e.inp.connected = true;
  e.run(1000);
  e.p.openService(e.now, 600000);
  e.step();
  check(30, e.apActive);
  let expiredAt = 0;
  const sv = e.now;
  for (let t = 0; t < 11 * 60 * 1000; t += 250) {
    const at = e.now;
    const o = e.step();
    if (o.serviceExpired && !expiredAt) expiredAt = at;
  }
  check(31, expiredAt !== 0 && u32(expiredAt - sv) >= 599000 && u32(expiredAt - sv) < 600500);
  check(32, !e.apActive);
  // "AP OFF"
  e.p.openService(e.now, 600000);
  e.step();
  check(33, e.apActive);
  e.p.closeAll(e.now);
  e.step();
  check(34, !e.apActive);

  // izin yok (provizyonlu, ap_pass yok): hic acilmaz
  const f = new ApSim(b, 250);
  f.inp.allowed = false;
  f.inp.connected = false;
  f.run(30 * 60 * 1000);
  check(40, !f.apActive);
  f.inp.allowed = true;
  f.run(1000);
  check(41, f.apActive);   // izin gelince (kesinti suruyor) pencere acilir

  // STA tanimsiz: AP hemen acilir
  const g = new ApSim(b, 250);
  g.inp.connected = false;
  g.inp.staConfigured = false;
  g.run(1000);
  check(50, g.apActive);

  // ap_pass degisimi: acik AP 1,5 sn sonra TEK kez yeniden baslar
  const h = new ApSim(b, 250);
  h.inp.connected = false;
  h.inp.staConfigured = false;
  h.run(2000);
  check(60, h.apActive);
  h.p.requestRestart(h.now);
  let restarts = 0; let rAt = 0;
  const rq = h.now;
  for (let t = 0; t < 10 * 1000; t += 250) {
    const at = h.now;
    const o = h.step();
    if (o.restartAp) { restarts++; rAt = at; }
  }
  check(61, restarts === 1 && u32(rAt - rq) >= 1500 && u32(rAt - rq) < 1500 + 500);
}

/** Eski mantiginin yalniz "yeniden acma bekleme" parcasi (saklanmis hedef + isaretli karsilastirma). */
class LegacyReopen {
  constructor() { this.nextOpenAt = 0; }

  canOpen(now) { return legacyDue(now, this.nextOpenAt); }

  windowEnded(now) { this.nextOpenAt = u32(now + 900000); }
}

/** Pencere bir kez doldu (yeniden acma beklemesi kuruldu), STA haftalarca bagli kaldi, sonra kesinti: AP ACILMALI. */
function apOpensAfterLongConnectedPeriod(base, connectedMs) {
  const s = new ApSim(base, 1000);
  s.inp.connected = false;
  let rel = 0;   // goreli zaman (beklenen degerleri sarmadan hesaplamak icin)
  let endedAt = 0;
  let ended = false;
  for (; rel < 15 * 60 * 1000; rel += 1000) {
    const o = s.step();   // pencere 3. dk'da acilir, 13. dk'da dolar: reopen beklemesi kurulur
    if (o.ended && !ended) { ended = true; endedAt = rel; }
  }
  check(1, !s.apActive && ended);
  const legacy = new LegacyReopen();
  legacy.windowEnded(s.now);               // eski mantik ayni anda ayni hedefi saklardi
  s.inp.connected = true;
  s.tick = kIdleStep;                      // STA haftalarca bagli; gorev dongusu (kaba adimla) yoklar
  for (let t = 0; t < connectedMs; t += kIdleStep, rel += kIdleStep) s.step();
  s.tick = 1000;
  s.inp.connected = false;                 // kesinti basliyor
  const outageStart = rel;
  let opened = false; let desiredAtOpen = false; let openedAt = 0;
  for (let t = 0; t < 40 * 60 * 1000; t += 1000, rel += 1000) {
    const o = s.step();
    if (o.opened && !opened) { opened = true; openedAt = rel; desiredAtOpen = o.desired && o.startAp; }
  }
  // beklenen: kesintiden 3 dk sonra; ama onceki pencerenin 15 dk'lik yeniden acma beklemesi bitmediyse o bitince
  let expectOpen = outageStart + 180000;
  if (endedAt + 900000 > expectOpen) expectOpen = endedAt + 900000;
  check(2, opened && openedAt >= expectOpen && openedAt < expectOpen + 2000);
  check(3, desiredAtOpen);
  if (connectedMs >= 0x80000000 + 3600000 && connectedMs < 0xFFFFFFFF - 3600000) {
    check(4, !legacy.canOpen(s.now));   // eski mantik: kurtarma AP'si ASLA acilmazdi (hedef "hala gelecekte")
  }
}

/** 60 gun SUREKLI kesinti: pencere 25 dk'lik periyotla (3 dk tetik, 10 dk acik, 15 dk bekleme) hic aksamadan acilip kapanmali. */
function apContinuousOutage(base, totalMs, tick) {
  const s = new ApSim(base, tick);
  s.inp.connected = false;
  let lastOpen = 0;
  let opens = 0;
  for (let rel = 0; rel < totalMs; rel += tick) {
    const o = s.step();
    if (o.opened) {
      if (opens === 0) check(1, rel === 180000);
      else check(2, rel - lastOpen === 1500000);
      lastOpen = rel;
      opens++;
    }
  }
  const expected = Math.floor((totalMs - 1 - 180000) / 1500000) + 1;
  check(3, opens === expected);
}

// ---------------------------------------------------------------------------------------------------------------
// ApPolicy: eski algoritmanin 64 bit (sarmasiz) referans modeliyle rastgele senaryolarda KARSILASTIRMA
// ---------------------------------------------------------------------------------------------------------------
class RefAp {
  constructor() {
    this.windowOpen = false; this.windowStart = 0; this.windowEnd = 0; this.nextOpenAt = 0; this.nextOpenSet = false;
    this.serviceUntil = 0; this.serviceSet = false; this.restartPending = false; this.restartAt = 0;
    this.primed = false; this.prevConnected = false; this.discValid = false; this.stableValid = false; this.discSince = 0; this.stableSince = 0;
  }

  openService(now, ms) { this.serviceUntil = now + (ms || 1); this.serviceSet = true; }

  closeAll(now) { this.serviceSet = false; this.windowOpen = false; this.nextOpenAt = now + 900000; this.nextOpenSet = true; }

  requestRestart(now) { this.restartPending = true; this.restartAt = now + 1500; }

  update(now, inp) {
    const o = { desired: false, startAp: false, stopAp: false, restartAp: false, opened: false, extended: false, ended: false, closedStable: false, serviceExpired: false };
    if (!this.primed || inp.connected !== this.prevConnected) {
      this.primed = true;
      this.prevConnected = inp.connected;
      if (inp.connected) {
        this.discValid = false;
        this.stableValid = true;
        this.stableSince = now;
      } else {
        this.stableValid = false;
        this.discValid = true;
        this.discSince = now;
      }
    }
    const serviceOpen = this.serviceSet && now < this.serviceUntil;
    if (this.serviceSet && !serviceOpen) {
      this.serviceSet = false;
      o.serviceExpired = true;
    }
    const discFor = (!inp.connected && this.discValid) ? now - this.discSince : 0;
    const trigger = !inp.staConfigured || discFor >= 180000;
    if (!this.windowOpen) {
      if (inp.allowed && trigger && (!this.nextOpenSet || now >= this.nextOpenAt)) {
        this.windowOpen = true;
        this.windowStart = now;
        this.windowEnd = now + 600000;
        o.opened = true;
      }
    } else if (inp.connected && inp.staConfigured && this.stableValid && now - this.stableSince >= 30000) {
      this.windowOpen = false;
      this.nextOpenSet = false;
      o.closedStable = true;
    } else if (now >= this.windowEnd) {
      if (inp.clients > 0 && now - this.windowStart < 1800000) {
        this.windowEnd = now + 120000;
        o.extended = true;
      } else {
        this.windowOpen = false;
        this.nextOpenAt = now + 900000;
        this.nextOpenSet = true;
        o.ended = true;
      }
    }
    o.desired = inp.allowed && ((this.serviceSet && now < this.serviceUntil) || this.windowOpen);
    if (o.desired && !inp.apActive) {
      o.startAp = true;
      this.restartPending = false;
    } else if (!o.desired && inp.apActive) {
      o.stopAp = true;
      this.restartPending = false;
    } else if (o.desired && inp.apActive && this.restartPending && now >= this.restartAt) {
      o.restartAp = true;
      this.restartPending = false;
    } else if (!inp.apActive) {
      this.restartPending = false;
    }
    return o;
  }
}

const newCoverage = () => ({ opened: 0, ended: 0, extended: 0, closedStable: 0, serviceExpired: 0, restarts: 0, started: 0, stopped: 0 });

/** Ayni girdi/istek dizisini hem ApPolicy'ye (32 bit, sarmali) hem referansa (64 bit) verir; her turda cikti ESIT olmali. */
function apDifferential(base, seed, tick, totalMs, cov) {
  gRng = seed >>> 0;
  const p = new ApPolicy();
  const r = new RefAp();
  const inp = ApPolicy.makeIn();
  inp.allowed = true;
  inp.connected = (rnd() & 1) !== 0;
  inp.staConfigured = true;
  let apActive = false;
  let now64 = base;
  const KEYS = ['desired', 'startAp', 'stopAp', 'restartAp', 'opened', 'extended', 'ended', 'closedStable', 'serviceExpired'];
  for (let t = 0; t < totalMs; t += tick) {
    const x = rnd();
    if (x % 700 === 0) inp.connected = !inp.connected;
    if (x % 900 === 1) inp.clients = inp.clients ? 0 : (1 + (x >>> 5) % 3);
    if (x % 12000 === 2) inp.allowed = !inp.allowed;
    if (x % 3000 === 3) {
      const ms = 1000 + (rnd() % (20 * 60 * 1000));
      p.openService(u32(now64), ms);
      r.openService(now64, ms);
    }
    if (x % 5000 === 4) {
      p.closeAll(u32(now64));
      r.closeAll(now64);
    }
    if (x % 2500 === 5) {
      p.requestRestart(u32(now64));
      r.requestRestart(now64);
    }
    if (x % 60000 === 6) inp.staConfigured = !inp.staConfigured;
    inp.apActive = apActive;
    if (!apActive) inp.clients = 0;
    const a = p.update(u32(now64), inp);
    const b = r.update(now64, inp);
    for (let k = 0; k < KEYS.length; k++) if (a[KEYS[k]] !== b[KEYS[k]]) throw new Fail(1 + k);
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
}

// ---------------------------------------------------------------------------------------------------------------
// StaMachine
// ---------------------------------------------------------------------------------------------------------------
function staDirect(b) {
  const m = new StaMachine();
  let now = b;
  // kimlik yok: IDLE
  check(1, m.update(now, false, false, false, false) === StaAction.NONE && m.state === StaState.IDLE);
  // kimlik var: hemen dene
  check(2, m.update(now, false, true, false, false) === StaAction.BEGIN && m.state === StaState.CONNECTING);
  // 15 sn zaman asimi -> 2 sn bekle
  check(3, m.update(u32(now + 14999), false, true, false, false) === StaAction.NONE);
  check(4, m.update(u32(now + 15000), false, true, false, false) === StaAction.TIMEOUT && m.state === StaState.BACKOFF);
  check(5, m.retry.span === 2000 && m.backoffMs === 4000);
  now = u32(now + 15000);
  check(6, m.update(u32(now + 1999), false, true, false, false) === StaAction.NONE);
  check(7, m.update(u32(now + 2000), false, true, false, false) === StaAction.BEGIN);
  // kopma olayi: hemen TIMEOUT, bekleme 4, 8, ... 60 sn tavan
  const expect = [4000, 8000, 16000, 32000, 60000, 60000];
  now = u32(now + 2000);
  for (let i = 0; i < 6; i++) {
    check(10 + i, m.update(u32(now + 100), false, true, true, false) === StaAction.TIMEOUT);
    check(20 + i, m.retry.span === expect[i]);
    now = u32(now + 100);
    check(30 + i, m.update(u32(now + expect[i] - 1), false, true, false, false) === StaAction.NONE);
    now = u32(now + expect[i]);
    check(40 + i, m.update(now, false, true, false, false) === StaAction.BEGIN);
  }
  // baglandi: sayac sifirlanir
  check(50, m.update(u32(now + 500), true, true, false, false) === StaAction.NONE && m.state === StaState.CONNECTED);
  check(51, m.backoffMs === 2000);
  // baglanti kopar: 2 sn sonra yeniden dene
  now = u32(now + 500);
  check(52, m.update(u32(now + 10000), false, true, false, false) === StaAction.NONE && m.state === StaState.BACKOFF);
  now = u32(now + 10000);
  check(53, m.update(u32(now + 1999), false, true, false, false) === StaAction.NONE);
  check(54, m.update(u32(now + 2000), false, true, false, false) === StaAction.BEGIN);
  // AP'ye istemci bagliyken deneme yapilmaz; istemci gidince hemen
  const k = new StaMachine();
  now = b;
  check(60, k.update(now, false, true, false, true) === StaAction.NONE);
  check(61, k.update(u32(now + 600000), false, true, false, true) === StaAction.NONE);
  check(62, k.update(u32(now + 600001), false, true, false, false) === StaAction.BEGIN);
  // elle yeniden baglan: bekleme iptal
  const q = new StaMachine();
  now = b;
  q.update(now, false, true, false, false);                                // BEGIN
  q.update(u32(now + 1), false, true, true, false);                        // TIMEOUT -> BACKOFF 2 sn
  check(70, q.update(u32(now + 100), false, true, false, false) === StaAction.NONE);
  q.reconnectNow();
  check(71, q.update(u32(now + 101), false, true, false, false) === StaAction.BEGIN);
  q.reset();
  check(72, q.state === StaState.IDLE && q.backoffMs === 2000);
  // aday basarisiz: eski kimlik varsa 1,5 sn sonra, yoksa IDLE
  q.candidateFailed(now, true);
  check(73, q.state === StaState.BACKOFF && q.retry.span === 1500);
  q.candidateFailed(now, false);
  check(74, q.state === StaState.IDLE);
}

/** AP istemcisi aylarca bagli kalir (deneme yapilmaz), sonra ayrilir: baglanma denemesi HEMEN baslamali. */
function staNotFrozenAfterApClientBlock(base, blockedMs) {
  const m = new StaMachine();
  m.update(base, false, true, false, false);            // BEGIN
  m.update(u32(base + 1), false, true, true, false);    // TIMEOUT: bekleme kuruldu (2 sn)
  for (let t = 1000; t <= blockedMs; t += kIdleStep) {
    check(1, m.update(u32(base + t), false, true, false, true) === StaAction.NONE);
  }
  const back = u32(base + blockedMs);
  check(2, m.update(back, false, true, false, false) === StaAction.BEGIN);
  // eski desen: hedef = base + 2 sn saklanir
  if (blockedMs >= 0x80000000 + 5000 && blockedMs < 0xFFFFFFFF - 5000) {
    check(3, !legacyDue(back, u32(base + 1 + 2000)));
  }
}

// ---------------------------------------------------------------------------------------------------------------
// CandidateFlow
// ---------------------------------------------------------------------------------------------------------------
function candidateDirect(b) {
  const f = new CandidateFlow();
  let now = b;
  check(1, f.update(now, false, false) === CandAction.NOTHING);
  f.start(now);
  check(2, f.update(u32(now + 499), false, false) === CandAction.NOTHING);
  check(3, f.update(u32(now + 500), false, false) === CandAction.DO_DISCONNECT);
  now = u32(now + 500);
  check(4, f.update(u32(now + 399), false, false) === CandAction.NOTHING);
  check(5, f.update(u32(now + 400), false, false) === CandAction.DO_BEGIN);
  now = u32(now + 400);
  check(6, f.update(u32(now + 24999), false, false) === CandAction.NOTHING);
  check(7, f.update(u32(now + 25000), false, false) === CandAction.FAILED);
  check(8, f.phase === CandPhase.NONE);
  // basari
  f.start(now);
  f.update(u32(now + 500), false, false);
  f.update(u32(now + 900), false, false);
  check(10, f.update(u32(now + 5000), true, false) === CandAction.COMMIT);
  // kopma olayi: hemen basarisiz
  f.start(now);
  f.update(u32(now + 500), false, false);
  f.update(u32(now + 900), false, false);
  check(11, f.update(u32(now + 1000), false, true) === CandAction.FAILED);
  // iptal
  f.start(now);
  f.cancel();
  check(12, f.update(u32(now + 100000), false, false) === CandAction.NOTHING);
}

/** Akis haftalarca bosta kalir; sonra yeni aday istegi: asamalar zamaninda ilerlemeli. */
function candidateAfterIdle(base, idleMs) {
  const f = new CandidateFlow();
  f.start(base);
  f.update(u32(base + 500), false, false);
  f.update(u32(base + 900), false, false);
  check(1, f.update(u32(base + 25900), false, false) === CandAction.FAILED);   // onceki akis sonlandi
  for (let t = 0; t < idleMs; t += kIdleStep) f.update(u32(base + 30000 + t), false, false);
  const n = u32(base + 30000 + idleMs);
  f.start(n);
  check(2, f.update(u32(n + 499), false, false) === CandAction.NOTHING);
  check(3, f.update(u32(n + 500), false, false) === CandAction.DO_DISCONNECT);
  check(4, f.update(u32(n + 900), false, false) === CandAction.DO_BEGIN);
  check(5, f.update(u32(n + 901), true, false) === CandAction.COMMIT);
}

// ---------------------------------------------------------------------------------------------------------------
// ScanGate (decide(): {decision, cached})
// ---------------------------------------------------------------------------------------------------------------
function scanDirect(b) {
  const g = new ScanGate();
  const now = b;
  let d;
  // ilk istek: tarama baslar
  d = g.decide(now, false, false, false);
  check(1, d.decision === ScanDecision.START && !d.cached);
  check(2, g.inProgress);
  check(3, g.poll(u32(now + 1000), ScanDriver.RUNNING) === ScanPoll.RUNNING);
  check(4, g.poll(u32(now + 3000), ScanDriver.DONE) === ScanPoll.DONE);
  g.cacheStored(u32(now + 3000));
  check(5, g.poll(u32(now + 3001), ScanDriver.RUNNING) === ScanPoll.IDLE);
  // onbellek taze: sonuc onbellekten
  d = g.decide(u32(now + 4000), false, false, true);
  check(6, d.decision === ScanDecision.RESULT && d.cached);
  // refresh ama 10 sn dolmadi: hiz siniri -> onbellekten
  d = g.decide(u32(now + 9999), true, false, true);
  check(7, d.decision === ScanDecision.RESULT && d.cached);
  // refresh, 10 sn doldu: yeni tarama
  d = g.decide(u32(now + 10000), true, false, true);
  check(8, d.decision === ScanDecision.START);
  g.poll(u32(now + 12000), ScanDriver.DONE);
  g.cacheStored(u32(now + 12000));
  // 120 sn omur: 119999 -> taze, 120000 -> eski
  check(9, g.decide(u32(now + 12000 + 119999), false, false, true).decision === ScanDecision.RESULT);
  check(10, g.decide(u32(now + 12000 + 120000), false, false, true).decision === ScanDecision.START);
  // takilan tarama: 15 sn sonra basarisiz sayilir
  check(11, g.poll(u32(now + 12000 + 120000 + 14999), ScanDriver.RUNNING) === ScanPoll.RUNNING);
  check(12, g.poll(u32(now + 12000 + 120000 + 15000), ScanDriver.RUNNING) === ScanPoll.FAILED);
  check(13, !g.inProgress);
  // bagli degilken (baglaniyor) tarama baslamaz; onbellek yoksa "done, bos" doner
  const h = new ScanGate();
  d = h.decide(now, false, true, false);
  check(14, d.decision === ScanDecision.RESULT && !d.cached);
  // hiz siniri sirasinda onbellek yoksa "scanning" (sinir bitince baslayacak)
  const k = new ScanGate();
  check(15, k.decide(now, false, false, false).decision === ScanDecision.START);
  k.poll(u32(now + 100), ScanDriver.FAILED);
  check(16, k.decide(u32(now + 5000), false, false, false).decision === ScanDecision.SCANNING);
  check(17, k.decide(u32(now + 10000), false, false, false).decision === ScanDecision.START);
}

/** Tarama haftalarca "suruyor" gorunur (istemci birakti), sonra yeni istek: takilma zaman asimi ve onbellek omru calismali. */
function scanAfterIdle(base, idleMs) {
  const g = new ScanGate();
  g.decide(base, false, false, false);                     // START (timeout 15 sn, rate 10 sn)
  for (let t = 0; t < idleMs; t += kIdleStep) g.service(u32(base + t));
  const back = u32(base + idleMs);
  const stuckCleared = idleMs >= ScanGate.TIMEOUT_MS;
  check(1, g.poll(back, ScanDriver.RUNNING) === (stuckCleared ? ScanPoll.FAILED : ScanPoll.RUNNING));
  if (stuckCleared) {
    check(2, g.decide(back, false, false, false).decision === ScanDecision.START);   // hiz siniri sonsuza dek surmez
  }
  // onbellek: bir kez saklandi; omru (120 sn) dolunca haftalar sonra "taze" SAYILMAMALI
  const c = new ScanGate();
  c.cacheStored(base);
  for (let t = 0; t < idleMs; t += kIdleStep) c.service(u32(base + t));
  const cacheStale = idleMs >= ScanGate.CACHE_TTL_MS;
  check(3, c.decide(back, false, false, true).decision === (cacheStale ? ScanDecision.START : ScanDecision.RESULT));
  // eski desen: hiz siniri hedefi (base + 10 sn) saklanir; 24,86 gun sonra "hala sinirda" sanilirdi
  if (idleMs >= 0x80000000 + 20000 && idleMs < 0xFFFFFFFF - 20000) {
    check(4, !legacyDue(back, u32(base + 10000)));
  }
}

// ================================================================ Testler (firmware ile ayni 27 test, ayni sira) ================================================================
test('fw_net_time: Wait siniri her zaman tabaninda dogru', () => {
  for (const b of kBases) assert.equal(run(waitBoundaries, b), 0, `taban ${b.toString(16)}`);
});

test('fw_net_time: her turda yoklanan Wait bir kez dolar ve 60 gunde de yeniden dogmaz', () => {
  for (const b of kLongBases) {
    assert.equal(run(waitSweep, b, 15 * MINUTE, 5000, 60 * DAY), 0, `taban ${b.toString(16)}`);
    assert.equal(run(waitSweep, b, 1500, 50, 2 * 3600 * 1000), 0);
  }
});

test('fw_net_time: eski isaretli hedef deseni 24,86 ile 49,7 gun arasinda DONAR (yeni Wait donmaz)', () => {
  const t0 = 12345;
  const target = t0 + 5000;
  assert.equal(legacyDue(t0, target), false);
  assert.equal(legacyDue(t0 + 5000, target), true);
  assert.equal(legacyDue(u32(t0 + 0x7FFFFFFF), target), true);                 // 24,86 gune kadar dogru
  assert.equal(legacyDue(u32(t0 + 0x80000000 + 6000), target), false);         // 24,86 gun: DONMUS ("hala gelecekte")
  assert.equal(legacyDue(u32(t0 + 0xC0000000), target), false);                // ~37 gun: donmus
  assert.equal(legacyDue(u32(target - 1), target), false);                     // 49,7 gunden 1 ms once: hala donmus
  assert.equal(legacyDue(u32(target + 10), target), true);                     // 49,7 gun + 10 ms: sarma, "duzelir"
  // ayni sessizlikte yoklanan Wait donmaz
  assert.equal(run(waitSweep, t0, 5000, 1000, 30 * DAY), 0);
});

test('fw_net_time: yoklanmasa bile gecen sure 49,7 gune kadar dogrudur (hedef saklanmaz)', () => {
  const idles = [5000, 1 * DAY, 0x80000000 - 1, 0x80000000, 0x80000000 + 1, 30 * DAY, 0x100000000 - 20000];
  for (const base of kLongBases) {
    for (const idle of idles) {
      const w = new Wait();
      w.arm(base, 5000);
      const back = u32(base + idle);
      assert.equal(w.elapsed(back), true);
      assert.equal(w.remaining(back), 0);
      assert.equal(w.running(back), false);
    }
  }
});

test('fw_net_time: jitter +-%20 icinde kalir', () => { assert.equal(run(jitterBounds), 0); });

test('fw_net_time: yeniden baglanma 5 -> 300 sn ve ozel beklemeler', () => {
  for (const b of kBases) assert.equal(run(backoffSequence, b), 0, `taban ${b.toString(16)}`);
});

test('fw_net_time: Wi-Fi kesintisi ne kadar surerse sursun yeniden baglanma donmaz', () => {
  for (const b of kLongBases) for (const idle of kIdle) assert.equal(run(reconnectNotFrozenAfterOutage, b, idle), 0, `${b.toString(16)} ${idle}`);
});

test('fw_net_time: abonelik 1500 ms yok sayma penceresi; uzun sessizlikte bayat pencere kalmaz', () => {
  for (const b of kLongBases) for (const idle of kIdle) assert.equal(run(ignoreWindow, b, idle), 0, `${b.toString(16)} ${idle}`);
  for (const b of kBases) assert.equal(run(ignoreWindow, b, 3000), 0);
});

test('fw_net_time: PublishPacer 250 ms birlestirme ve 30 sn kalp atisi', () => {
  for (const b of kBases) assert.equal(run(pacerCoalesceHeartbeat, b), 0, `taban ${b.toString(16)}`);
});

test('fw_net_time: PublishPacer hata sonrasi 1-2-4-8-16-30 sn ustel bekleme', () => {
  for (const b of kBases) assert.equal(run(pacerFailureBackoff, b), 0, `taban ${b.toString(16)}`);
});

test('fw_net_time: PublishPacer uzun kesintiden sonra ilk yayin HEMEN', () => {
  for (const b of kLongBases) for (const idle of kIdle) assert.equal(run(pacerAfterLongDisconnect, b, idle), 0, `${b.toString(16)} ${idle}`);
});

test('fw_net_time: PublishPacer kalp atisi 60 gun boyunca her 30 sn', () => {
  for (const b of kLongBases) assert.equal(run(pacerHeartbeatSweep, b, 60 * DAY), 0, `taban ${b.toString(16)}`);
});

test('fw_net_time: AuthLimiter IP basina kilit, unutma ve basari sifirlamasi', () => {
  for (const b of kBases) assert.equal(run(authLockBasics, b), 0, `taban ${b.toString(16)}`);
});

test('fw_net_time: AuthLimiter 60 sn icinde 20 hata -> genel kilit', () => {
  for (const b of kBases) assert.equal(run(authGlobalLock, b), 0, `taban ${b.toString(16)}`);
});

test('fw_net_time: AuthLimiter dolu yuvada en eski kurban edilir', () => {
  for (const b of kBases) assert.equal(run(authSlotEviction, b), 0, `taban ${b.toString(16)}`);
});

test('fw_net_time: uzun sessizlikten sonra 423 kilidi yapismaz', () => {
  for (const b of kLongBases) for (const idle of kIdle) assert.equal(run(authLockNotStuckAfterIdle, b, idle), 0, `${b.toString(16)} ${idle}`);
});

test('fw_net_time: AP pencere sureleri 10/30/15 dk ve STA kararli kapanis', () => {
  for (const b of kBases) assert.equal(run(apDirect, b), 0, `taban ${b.toString(16)}`);
});

test('fw_net_time: onceki pencereden sonra haftalarca bagli kalinsa da AP kesintide acilir', () => {
  for (const b of kLongBases) for (const idle of kIdle) assert.equal(run(apOpensAfterLongConnectedPeriod, b, idle), 0, `${b.toString(16)} ${idle}`);
});

test('fw_net_time: 60 gun sureklu kesintide AP penceresi aksamadan 25 dk periyotla doner', () => {
  for (const b of kLongBases) assert.equal(run(apContinuousOutage, b, 60 * DAY, 5000), 0, `taban ${b.toString(16)}`);
  assert.equal(run(apContinuousOutage, 0x7FFFFFF0, 3 * 3600 * 1000, 1000), 0);
  assert.equal(run(apContinuousOutage, 0xFFFFFFF0, 3 * 3600 * 1000, 1000), 0);
});

test('fw_net_time: ApPolicy 64 bit referans modeliyle sarma sinirinda ayni (rastgele senaryolar)', () => {
  const cov = newCoverage();
  const bases = [0, 0x7FFFF000, 0x7FFFFFF0, 0xFFFF0000, 0xFFFFFFF0, 0x80000000];
  for (let i = 0; i < bases.length; i++) {
    for (let seed = 1; seed <= 40; seed++) {
      assert.equal(run(apDifferential, bases[i], seed * 7919 + i, 250, 3 * 3600 * 1000, cov), 0, `taban ${bases[i].toString(16)} tohum ${seed}`);
    }
  }
  // senaryolar bos kalmamali: her olay turu gorulmus olmali
  assert.ok(cov.opened > 100, `opened ${cov.opened}`);
  assert.ok(cov.ended > 50, `ended ${cov.ended}`);
  assert.ok(cov.extended > 20, `extended ${cov.extended}`);
  assert.ok(cov.closedStable > 20, `closedStable ${cov.closedStable}`);
  assert.ok(cov.serviceExpired > 20, `serviceExpired ${cov.serviceExpired}`);
  assert.ok(cov.restarts > 20, `restarts ${cov.restarts}`);
  assert.ok(cov.started > 100, `started ${cov.started}`);
  assert.ok(cov.stopped > 100, `stopped ${cov.stopped}`);
});

test('fw_net_time: ApPolicy 60 gun boyunca 5 sn adimla referansla ayni', () => {
  const cov = newCoverage();
  for (let i = 0; i < kLongBases.length; i++) {
    assert.equal(run(apDifferential, kLongBases[i], 424242 + i, 5000, 60 * DAY, cov), 0, `taban ${kLongBases[i].toString(16)}`);
  }
  assert.ok(cov.opened > 100, `opened ${cov.opened}`);
  assert.ok(cov.ended > 20, `ended ${cov.ended}`);
});

test('fw_net_time: StaMachine deneme zaman asimi, ustel geri cekilme ve AP istemcisi engeli', () => {
  for (const b of kBases) assert.equal(run(staDirect, b), 0, `taban ${b.toString(16)}`);
});

test('fw_net_time: AP istemcisi aylarca baglanti engellese de STA denemesi donmaz', () => {
  for (const b of kLongBases) for (const idle of kIdle) assert.equal(run(staNotFrozenAfterApClientBlock, b, idle), 0, `${b.toString(16)} ${idle}`);
});

test('fw_net_time: CandidateFlow asamalari 500 ms / 400 ms / 25 sn', () => {
  for (const b of kBases) assert.equal(run(candidateDirect, b), 0, `taban ${b.toString(16)}`);
});

test('fw_net_time: CandidateFlow uzun bosluktan sonra da calisir', () => {
  for (const b of kLongBases) for (const idle of kIdle) assert.equal(run(candidateAfterIdle, b, idle), 0, `${b.toString(16)} ${idle}`);
});

test('fw_net_time: ScanGate hiz siniri, onbellek omru ve takilan tarama', () => {
  for (const b of kBases) assert.equal(run(scanDirect, b), 0, `taban ${b.toString(16)}`);
});

test('fw_net_time: ScanGate uzun sessizlikten sonra donmaz', () => {
  for (const b of kLongBases) for (const idle of kIdle) assert.equal(run(scanAfterIdle, b, idle), 0, `${b.toString(16)} ${idle}`);
});
