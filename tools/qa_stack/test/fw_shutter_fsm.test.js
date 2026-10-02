// Firmware ShutterFsm (src/ShutterFsm.h) JS portunun UYUMLULUK testi: firmware'in kendi Unity testlerinin
// (ev_otomasyon_servis_yazilimi/waveshare_s3_demo/test/test_shutter_fsm/test_main.cpp) 33 testinin BIREBIR portu.
// Amac: simulatorun panjur davranisi gercek firmware mantigiyla ayni beklenen degerleri uretiyor.
import test from 'node:test';
import assert from 'node:assert/strict';
import { ShutterFsm, Ev, NO_TARGET } from '../sim/fw/shutter_fsm.js';

const u32 = (x) => x >>> 0;

/** Firmware testindeki `Sim`: FSM ciktisini suruculere uygular, DEGISMEZ KURALLARI sayar. */
class Sim {
  constructor(t0 = 0) {
    this.f = new ShutterFsm();
    this.now = u32(t0);
    this.hw = 0;
    this.haveOff = false;
    this.offAt = 0;
    this.violations = 0;
    this.confirmOff = true;
    this.energizeCount = 0;
    this.f.setTiming(20000, 20000, 500, 2000);
  }

  apply() {
    const m = this.f.outMask();
    if (m === 3) this.violations++;
    if (m !== this.hw) {
      if (this.hw !== 0 && m !== 0) this.violations++;                         // arada KAPALI olmadan yon degisimi
      if (this.hw !== 0 && m === 0) { this.haveOff = true; this.offAt = this.now; }
      if (this.hw === 0 && m !== 0) {
        if (this.haveOff && u32(this.now - this.offAt) < 500) this.violations++; // olu zaman < 500 ms
        this.energizeCount++;
      }
      this.hw = m;
    }
  }

  tick(t) {
    this.now = u32(t);
    this.f.tick(this.now, this.confirmOff ? this.hw === 0 : false);
    this.apply();
  }

  up() { this.f.cmdUp(this.now); this.apply(); }
  down() { this.f.cmdDown(this.now); this.apply(); }
  stop() { this.f.cmdStop(this.now); this.apply(); }
  step() { this.f.cmdStep(this.now); this.apply(); }
  pos(p) { this.f.cmdPosition(this.now, p); this.apply(); }
  at(t) { this.tick(t); }

  run(t1) {
    t1 = u32(t1);
    while (u32(t1 - this.now) !== 0 && u32(t1 - this.now) < 0x80000000) {
      const d = u32(t1 - this.now);
      this.tick(this.now + (d > 10 ? 10 : d));
    }
  }
}

// ---------------------------------------------------------------- temel davranis
test('fw_shutter_fsm: baslangic durumu bosta', () => {
  const s = new Sim(1000);
  assert.equal(s.f.outMask(), 0);
  assert.equal(s.f.isMoving(), false);
  assert.equal(s.f.isWaiting(), false);
  assert.equal(s.f.position(1000), 0);
  assert.equal(s.f.target(), 255);
  assert.equal(NO_TARGET, 255);
});

test('fw_shutter_fsm: tam yukari = tam sure + overrun', () => {
  const s = new Sim(1000);
  s.up();
  assert.equal(s.hw, 1);
  assert.equal(s.f.durationMs(), 22000);
  assert.equal(s.f.target(), 100);
  s.run(1000 + 20000);
  assert.equal(s.f.position(s.now), 100);
  assert.equal(s.f.isMoving(), true);
  s.run(1000 + 21999);
  assert.equal(s.f.isMoving(), true);
  s.run(1000 + 22000);
  assert.equal(s.f.isMoving(), false);
  assert.equal(s.hw, 0);
  assert.equal(s.f.position(s.now), 100);
  const ev = s.f.takeEvents();
  assert.ok((ev & Ev.COMPLETED) !== 0);
  assert.equal(s.violations, 0);
});

test('fw_shutter_fsm: tam asagi 0a iner', () => {
  const s = new Sim(0);
  s.f.setPosition(100);
  s.down();
  assert.equal(s.hw, 2);
  s.run(10000);
  assert.equal(s.f.position(s.now), 50);
  s.run(22000);
  assert.equal(s.f.isMoving(), false);
  assert.equal(s.f.position(s.now), 0);
  assert.equal(s.violations, 0);
});

// ---------------------------------------------------------------- ters yonde olu zaman
test('fw_shutter_fsm: ters yon 500 ms olu zaman uygular', () => {
  const s = new Sim(1000);
  s.up();
  assert.equal(s.hw, 1);
  s.run(6000);
  assert.equal(s.f.position(6000), 25);
  s.down();
  assert.equal(s.hw, 0);
  assert.equal(s.f.isWaiting(), true);
  s.tick(6000);
  s.tick(6250);
  s.tick(6499);
  assert.equal(s.hw, 0);
  s.tick(6500);
  assert.equal(s.hw, 2);
  assert.equal(s.violations, 0);
});

test('fw_shutter_fsm: durus sonrasi olu zaman icindeki komut ertelenir', () => {
  const s = new Sim(0);
  s.up();
  s.run(1000);
  s.stop();
  assert.equal(s.hw, 0);
  s.tick(1000);
  s.at(1100);
  s.up();
  assert.equal(s.hw, 0);
  assert.equal(s.f.isWaiting(), true);
  s.run(1499);
  assert.equal(s.hw, 0);
  s.run(1500);
  assert.equal(s.hw, 1);
  assert.equal(s.violations, 0);
});

test('fw_shutter_fsm: olu zaman asla 500 ms altina inmez', () => {
  const s = new Sim(0);
  s.f.setTiming(20000, 20000, 100, 2000);
  assert.equal(s.f.deadMs(), 500);
});

test('fw_shutter_fsm: KAPALI teyidi olmadan enerjilenmez', () => {
  const s = new Sim(0);
  s.up();
  s.run(2000);
  s.confirmOff = false;
  s.down();
  const t = s.now;
  for (let k = 0; k < 5000; k += 10) s.tick(t + k);
  assert.equal(s.hw, 0);
  assert.equal(s.f.isWaiting(), true);
  s.confirmOff = true;
  const t1 = s.now + 10;
  s.tick(t1);
  s.tick(t1 + 499);
  assert.equal(s.hw, 0);
  s.tick(t1 + 500);
  assert.equal(s.hw, 2);
  assert.equal(s.violations, 0);
});

// ---------------------------------------------------------------- konum / yon degisimi
test('fw_shutter_fsm: konum yon degisiminde surekli', () => {
  const s = new Sim(0);
  s.up();
  s.run(10000);
  s.down();
  s.tick(10000);
  assert.equal(s.f.position(10000), 50);
  s.run(10500);
  assert.equal(s.hw, 2);
  s.run(15500);
  assert.equal(s.f.position(15500), 25);
  s.up();
  s.tick(15500);
  assert.equal(s.f.position(15500), 25);
  s.run(16000);
  s.run(21000);
  assert.equal(s.f.position(21000), 50);
  assert.equal(s.violations, 0);
});

test('fw_shutter_fsm: konum kaydi yeni hareketin baslangicini sifirlar', () => {
  const s = new Sim(0);
  s.up();
  s.run(4000);
  s.stop();
  s.run(5000);
  s.up();
  s.run(5000 + 10000);
  assert.equal(s.f.position(s.now), 70);
});

test('fw_shutter_fsm: konum 0..100 disina cikmaz', () => {
  const s = new Sim(0);
  s.f.setPosition(5);
  s.down();
  s.run(30000);
  assert.equal(s.f.position(s.now), 0);
  const t = new Sim(0);
  t.f.setPosition(95);
  t.up();
  t.run(30000);
  assert.equal(t.f.position(t.now), 100);
});

// ---------------------------------------------------------------- orantili sure
test('fw_shutter_fsm: konum komutunun suresi orantili', () => {
  const s = new Sim(0);
  s.f.setTiming(20000, 10000, 500, 2000);
  s.pos(50);
  assert.equal(s.hw, 1);
  assert.equal(s.f.durationMs(), 10000);
  assert.equal(s.f.target(), 50);
  s.run(9999);
  assert.equal(s.f.isMoving(), true);
  s.run(10000);
  assert.equal(s.f.isMoving(), false);
  assert.equal(s.f.position(s.now), 50);

  const a = new Sim(0);
  a.f.setTiming(20000, 10000, 500, 2000);
  a.f.setPosition(90);
  a.pos(100);
  assert.equal(a.f.durationMs(), 4000);

  const b = new Sim(0);
  b.f.setTiming(20000, 10000, 500, 2000);
  b.f.setPosition(30);
  b.pos(0);
  assert.equal(b.hw, 2);
  assert.equal(b.f.durationMs(), 5000);

  const c = new Sim(0);
  c.f.setTiming(20000, 10000, 500, 2000);
  c.f.setPosition(90);
  c.pos(40);
  assert.equal(c.f.durationMs(), 5000);
});

test('fw_shutter_fsm: konum komutu zaten hedefteyse bir sey yapmaz', () => {
  const s = new Sim(0);
  s.f.setPosition(40);
  s.pos(40);
  assert.equal(s.hw, 0);
  assert.equal(s.f.isMoving(), false);
  assert.equal(s.energizeCount, 0);
});

test('fw_shutter_fsm: hareket sirasinda hedefe esit konum komutu durdurur', () => {
  const s = new Sim(0);
  s.up();
  s.run(10000);
  s.pos(50);
  assert.equal(s.hw, 0);
  assert.equal(s.f.position(s.now), 50);
});

test('fw_shutter_fsm: cok kucuk konum hareketi asgari calisma suresine sahip', () => {
  const s = new Sim(0);
  s.f.setTiming(1000, 1000, 500, 0);
  s.f.setPosition(50);
  s.pos(51);
  assert.equal(s.f.durationMs(), 100);
});

test('fw_shutter_fsm: bekleyen konum, durmus konumdan yeniden hesaplanir', () => {
  const s = new Sim(0);
  s.f.setTiming(20000, 10000, 500, 2000);
  s.pos(80);
  s.run(8000);
  s.pos(20);
  s.tick(8000);
  assert.equal(s.hw, 0);
  s.run(8500);
  assert.equal(s.hw, 2);
  assert.equal(s.f.durationMs(), 2000);
  s.run(10500);
  assert.equal(s.f.isMoving(), false);
  assert.equal(s.f.position(s.now), 20);
  assert.equal(s.violations, 0);
});

// ---------------------------------------------------------------- ayni yon tekrari / yeniden hedefleme
test('fw_shutter_fsm: ayni yon tekrari zamanlamayi yeniden baslatmaz', () => {
  const s = new Sim(1000);
  s.up();
  s.f.takeEvents();
  s.run(5000);
  s.up();
  assert.equal(s.f.startMs(), 1000);
  assert.equal(s.f.durationMs(), 22000);
  assert.equal(s.f.takeEvents() & Ev.STARTED, 0);
  assert.equal(s.hw, 1);
  s.run(1000 + 22000);
  assert.equal(s.f.isMoving(), false);
  assert.equal(s.energizeCount, 1);
});

test('fw_shutter_fsm: ayni yonde konum yeniden hedefleme ilerlemeyi ve roleyi korur', () => {
  const s = new Sim(0);
  s.up();
  s.run(5000);
  s.f.takeEvents();
  s.pos(60);
  assert.equal(s.hw, 1);
  assert.ok((s.f.takeEvents() & Ev.RETARGET) !== 0);
  assert.equal(s.f.target(), 60);
  assert.equal(s.f.durationMs(), 7000);
  s.run(5000 + 6999);
  assert.equal(s.f.isMoving(), true);
  s.run(5000 + 7000);
  assert.equal(s.f.isMoving(), false);
  assert.equal(s.f.position(s.now), 60);
  assert.equal(s.energizeCount, 1);
});

// ---------------------------------------------------------------- kesintisiz calisma siniri (runCap)
test('fw_shutter_fsm: art arda yeniden hedefleme "tam yol + oturma payi"ni asamaz', () => {
  const s = new Sim(0);
  s.pos(60);                           // 0 -> 60: 12 sn (uc nokta degil, oturma payi yok)
  s.run(10000);                        // %50
  s.f.takeEvents();
  s.up();                              // ayni yonde TAM hareket: yeniden damgalanir, dur = 22 sn (dogal bitis 32. sn)
  assert.equal(s.f.startMs(), 10000);
  assert.equal(s.f.durationMs(), 22000);
  assert.equal(s.f.runStartMs(), 0);   // enerjilenme ani DEGISMEZ
  s.run(21990);
  assert.equal(s.f.isMoving(), true);
  s.run(22000);                        // role bu yonde 22 sn calisti: KESILIR
  assert.equal(s.f.isMoving(), false);
  assert.equal(s.hw, 0);
  assert.equal(s.f.position(s.now), 100);
  assert.equal(s.energizeCount, 1);
  assert.equal(s.violations, 0);
});

test('fw_shutter_fsm: dönüsümlü yeniden hedefleme motoru sonsuza dek calistiramaz', () => {
  const s = new Sim(0);
  s.up();
  for (let k = 1; k <= 6; k++) {
    s.run(3000 * k);
    assert.equal(s.f.isMoving(), true);
    if (k % 2 === 1) s.pos(99); else s.up();
  }
  assert.equal(s.f.startMs(), 18000);
  s.run(21990);
  assert.equal(s.f.isMoving(), true);
  s.run(22000);                        // enerjilenmeden 22 sn sonra durur (yeniden damgalanan 40. sn'yi BEKLEMEZ)
  assert.equal(s.f.isMoving(), false);
  s.run(60000);
  assert.equal(s.f.isMoving(), false);
  assert.equal(s.energizeCount, 1);
  assert.equal(s.f.position(s.now), 100);
  assert.equal(s.violations, 0);
});

test('fw_shutter_fsm: dönüsümlü yeniden hedeflemede fiziksel acik kalma suresi sinirli', () => {
  const s = new Sim(0);
  s.up();
  let onSince = 0;
  let maxOn = 0;
  let wasOn = true;
  for (let k = 1; k <= 6; k++) {
    s.run(3000 * k);
    if (k % 2 === 1) s.pos(99); else s.up();
  }
  while (s.now < 60000) {
    s.tick(s.now + 10);
    const on = s.hw !== 0;
    if (on && !wasOn) onSince = s.now;
    if (!on && wasOn) { const d = s.now - onSince; if (d > maxOn) maxOn = d; }
    wasOn = on;
  }
  assert.ok(maxOn <= 22000 + 20, `max acik kalma ${maxOn}`);
});

test('fw_shutter_fsm: ters yon sonrasi runCap YENI enerjilenme anindan sayilir', () => {
  const s = new Sim(0);
  s.up();
  s.run(6000);
  s.down();                            // ters: onceki hareket kesilir, 500 ms bekleme, yeni yon baslar
  s.run(6000 + 600);
  assert.equal(s.f.isMoving(), true);
  assert.equal(s.f.dir(), 2);
  const runStart = s.f.runStartMs();
  assert.ok(runStart >= 6500 && runStart <= 6700, `runStart ${runStart}`);   // YENI yonun enerjilenme ani (eski degil)
  assert.equal(s.f.runCapMs(), 22000);
  s.run(runStart + 21990);
  assert.ok(s.f.isMoving() || s.f.position(s.now) === 0);
  s.run(runStart + 22010);
  assert.equal(s.f.isMoving(), false);
  assert.equal(s.violations, 0);
});

// ---------------------------------------------------------------- millis() tasmasi
test('fw_shutter_fsm: millis() tasmasi hareket sirasinda', () => {
  const t0 = u32(0xFFFFFFFF - 5000);
  const s = new Sim(t0);
  s.f.setTiming(10000, 10000, 500, 2000);
  s.up();
  s.run(t0 + 6000);
  assert.equal(s.f.isMoving(), true);
  assert.equal(s.f.position(s.now), 60);
  s.run(t0 + 11999);
  assert.equal(s.f.isMoving(), true);
  s.run(t0 + 12000);
  assert.equal(s.f.isMoving(), false);
  assert.equal(s.f.position(s.now), 100);
  assert.equal(s.violations, 0);
});

test('fw_shutter_fsm: millis() tasmasi olu zaman sirasinda', () => {
  const t0 = u32(0xFFFFFFFF - 200);
  const s = new Sim(t0);
  s.up();
  s.run(t0 + 50);
  s.down();
  s.tick(t0 + 50);
  s.tick(t0 + 499 + 50);
  assert.equal(s.hw, 0);
  s.tick(t0 + 500 + 50);
  assert.equal(s.hw, 2);
  assert.equal(s.violations, 0);
});

// ---------------------------------------------------------------- dead_time_start == 0 (eski hata)
test('fw_shutter_fsm: millis()==0 aninda durus sonrasi olu zaman yok sayilmaz', () => {
  const s = new Sim(0);
  s.up();
  s.stop();
  s.tick(0);
  s.at(100);
  s.down();
  assert.equal(s.hw, 0);
  s.tick(100);
  s.run(499);
  assert.equal(s.hw, 0);
  s.run(500);
  assert.equal(s.hw, 2);
  assert.equal(s.violations, 0);
});

test('fw_shutter_fsm: tam tasma aninda durus', () => {
  const t0 = u32(0 - 1024);
  const s = new Sim(t0);
  s.up();
  s.run(0);
  assert.equal(s.now, 0);
  s.stop();
  s.tick(0);
  s.at(100);
  s.up();
  assert.equal(s.hw, 0);
  s.run(499);
  assert.equal(s.hw, 0);
  s.run(500);
  assert.equal(s.hw, 1);
  assert.equal(s.violations, 0);
});

// ---------------------------------------------------------------- ayni anda iki komut
test('fw_shutter_fsm: ayni anda yukari sonra asagi hicbir zaman ikisini enerjilemez', () => {
  const s = new Sim(5000);
  s.f.cmdUp(5000);
  s.f.cmdDown(5000);
  s.apply();
  assert.equal(s.hw, 0);
  assert.equal(s.f.pendingDir(), 2);
  s.tick(5000);
  s.tick(5499);
  assert.equal(s.hw, 0);
  s.tick(5500);
  assert.equal(s.hw, 2);
  assert.equal(s.violations, 0);
});

test('fw_shutter_fsm: ayni anda asagi sonra yukari, son komut kazanir', () => {
  const s = new Sim(5000);
  s.f.cmdDown(5000);
  s.f.cmdUp(5000);
  s.apply();
  assert.equal(s.hw, 0);
  assert.equal(s.f.pendingDir(), 1);
  s.tick(5000);
  s.tick(5500);
  assert.equal(s.hw, 1);
  assert.equal(s.violations, 0);
});

test('fw_shutter_fsm: tek tick icinde yukari-asagi-yukari-asagi-step', () => {
  const s = new Sim(0);
  s.f.cmdUp(0);
  s.f.cmdDown(0);
  s.f.cmdUp(0);
  s.f.cmdDown(0);
  s.f.cmdStep(0);
  s.apply();
  assert.equal(s.hw, 0);
  assert.equal(s.f.isWaiting(), false);
  s.run(3000);
  assert.equal(s.hw, 0);
  assert.equal(s.energizeCount, 0);
});

// ---------------------------------------------------------------- stop / step / yapilandirma
test('fw_shutter_fsm: stop bekleyen yonu iptal eder', () => {
  const s = new Sim(0);
  s.up();
  s.run(1000);
  s.down();
  assert.equal(s.f.isWaiting(), true);
  s.at(1100);
  s.stop();
  assert.equal(s.f.isWaiting(), false);
  s.run(3000);
  assert.equal(s.hw, 0);
  assert.equal(s.f.position(s.now), 5);
});

test('fw_shutter_fsm: bosta stop zararsiz', () => {
  const s = new Sim(0);
  s.stop();
  assert.equal(s.hw, 0);
  assert.equal(s.f.takeEvents() & Ev.STOPPED, 0);
});

test('fw_shutter_fsm: step yonu konuma gore secer', () => {
  const a = new Sim(0);
  a.f.setPosition(100);
  a.step();
  assert.equal(a.hw, 2);

  const b = new Sim(0);
  b.step();
  assert.equal(b.hw, 1);

  const c = new Sim(0);
  c.f.setPosition(50);
  c.step();
  assert.equal(c.hw, 1);
  c.run(1000);
  c.step();
  assert.equal(c.hw, 0);
  c.run(2000);
  c.step();
  assert.equal(c.hw, 2);
  c.run(3000);
  c.step();
  c.run(4000);
  c.step();
  assert.equal(c.hw, 1);
  assert.equal(c.violations, 0);
});

test('fw_shutter_fsm: bekleme sirasinda step iptal eder', () => {
  const s = new Sim(0);
  s.up();
  s.run(1000);
  s.down();
  assert.equal(s.f.isWaiting(), true);
  s.step();
  assert.equal(s.f.isWaiting(), false);
  s.run(3000);
  assert.equal(s.hw, 0);
});

test('fw_shutter_fsm: sure degisikligi hareket/bekleme sirasinda reddedilir', () => {
  const s = new Sim(0);
  assert.equal(s.f.setTiming(15000, 15000, 500, 2000), true);
  s.up();
  assert.equal(s.f.setTiming(30000, 30000, 500, 2000), false);
  assert.equal(s.f.upMs(), 15000);
  s.run(500);
  s.down();
  assert.equal(s.f.setTiming(30000, 30000, 500, 2000), false);
  s.run(1000);
  s.stop();
  s.run(3000);
  assert.equal(s.f.setTiming(30000, 30000, 500, 2000), true);
  assert.equal(s.f.upMs(), 30000);
});

test('fw_shutter_fsm: 0 veya dev yol suresi guvenli degerlere cekilir', () => {
  const s = new Sim(0);
  s.f.setTiming(0, 0, 500, 2000);
  assert.equal(s.f.upMs(), 20000);
  s.f.setTiming(9999999, 400000, 500, 2000);
  assert.equal(s.f.upMs(), 300000);
  assert.equal(s.f.downMs(), 300000);
});

test('fw_shutter_fsm: enerjileme hatasi hareketi iptal eder, konumu korur', () => {
  const s = new Sim(0);
  s.f.setPosition(30);
  s.up();
  assert.equal(s.f.outMask(), 1);
  s.f.onEnergizeFailed(5);
  s.apply();
  assert.equal(s.hw, 0);
  assert.equal(s.f.position(5), 30);
  assert.ok((s.f.takeEvents() & Ev.START_FAILED) !== 0);
  s.f.cmdUp(10);
  s.apply();
  assert.equal(s.hw, 0);
});

test('fw_shutter_fsm: forceStop aninda durdurur ve konumu kaydeder', () => {
  const s = new Sim(0);
  s.up();
  s.run(5000);
  s.f.forceStop(5000);
  s.apply();
  assert.equal(s.hw, 0);
  assert.equal(s.f.position(5000), 25);
});

// ---------------------------------------------------------------- yapisal degismez: rastgele komut firtinasi
let g_rng = 0xC0FFEE;
const rnd = () => {
  g_rng = (Math.imul(g_rng, 1664525) + 1013904223) >>> 0;
  return g_rng >>> 8;
};

test('fw_shutter_fsm: rastgele komut firtinasinda emniyet degismezleri korunur (6 tur x 60000 adim)', () => {
  const starts = [0, 1, 1000, 0xFFFFF000, 0xFFFFFFFF, 0x7FFFFFF0];
  for (let round = 0; round < 6; round++) {
    const s = new Sim(starts[round]);
    s.f.setTiming(1000 + (rnd() % 29000), 1000 + (rnd() % 29000), 500, 2000);
    s.f.setPosition(rnd() % 101);
    let t = s.now;
    for (let i = 0; i < 60000; i++) {
      t = u32(t + (rnd() % 700));
      s.confirmOff = rnd() % 17 !== 0;
      s.tick(t);
      switch (rnd() % 12) {
        case 0: s.up(); break;
        case 1: s.down(); break;
        case 2: s.stop(); break;
        case 3: s.step(); break;
        case 4: s.pos(rnd() % 101); break;
        case 5: s.f.forceStop(t); s.apply(); break;
        case 6: s.f.cmdUp(t); s.f.cmdDown(t); if (rnd() & 1) s.f.cmdUp(t); s.apply(); break;
        case 7: s.f.cmdDown(t); s.f.cmdUp(t); s.apply(); break;
        case 8: s.f.onEnergizeFailed(t); s.apply(); break;
        default: break;
      }
      assert.notEqual(s.f.outMask(), 3, 'outMask == 3 (YUKARI+ASAGI ayni anda)');
      assert.ok(s.f.position(t) <= 100, "konum 100'u asti");
    }
    assert.equal(s.violations, 0, `tur ${round}: ihlal sayisi`);
  }
});
