// Firmware DiGate (src/DiGate.h) JS portunun UYUMLULUK testi: firmware'in kendi Unity testlerinin
// (ev_otomasyon_servis_yazilimi/waveshare_s3_demo/test/test_di_gate/test_main.cpp) 23 testinin BIREBIR portu.
import test from 'node:test';
import assert from 'node:assert/strict';
import { DiGate, Mode, Action, Edge } from '../sim/fw/di_gate.js';

const u32 = (x) => x >>> 0;

/** Kararli bir kenar uretene kadar ornekler (t nesnesi referansla ilerler). */
function settle(g, idx, level, tt) {
  let e = g.sample(idx, level, tt.t);
  for (let k = 0; k < 20 && e === Edge.NONE; k++) {
    tt.t = u32(tt.t + 10);
    e = g.sample(idx, level, tt.t);
  }
  return e;
}

// ---------------------------------------------------------------- basma: kilit acik
test('fw_di_gate: kilit acikken basis eylemleri', () => {
  const g = new DiGate();
  let d = g.decide(0, Edge.PRESS, Mode.TOGGLE, false, false);
  assert.equal(d.action, Action.RELAY_TOGGLE);
  assert.equal(d.dropped, false);
  assert.equal(g.acted(0), true);

  d = g.decide(1, Edge.PRESS, Mode.MOMENTARY, false, false);
  assert.equal(d.action, Action.RELAY_ON);
  d = g.decide(2, Edge.PRESS, Mode.SHUTTER_STEP, false, false);
  assert.equal(d.action, Action.SHUTTER_STEP);
  d = g.decide(3, Edge.PRESS, Mode.SHUTTER_UP, false, false);
  assert.equal(d.action, Action.SHUTTER_UP);
  d = g.decide(3, Edge.PRESS, Mode.SHUTTER_UP, false, true);
  assert.equal(d.action, Action.SHUTTER_STOP);
  d = g.decide(4, Edge.PRESS, Mode.SHUTTER_DOWN, false, false);
  assert.equal(d.action, Action.SHUTTER_DOWN);
  d = g.decide(4, Edge.PRESS, Mode.SHUTTER_DOWN, false, true);
  assert.equal(d.action, Action.SHUTTER_STOP);
});

test('fw_di_gate: bilinmeyen mod hicbir sey yapmaz ve acted olmaz', () => {
  const g = new DiGate();
  const d = g.decide(0, Edge.PRESS, 9, false, false);
  assert.equal(d.action, Action.NONE);
  assert.equal(g.acted(0), false);
});

// ---------------------------------------------------------------- basma: kilitli
test('fw_di_gate: kilitli basis bosta her modda dusurulur ve acted olmaz', () => {
  const g = new DiGate();
  for (let mode = 0; mode <= Mode.SHUTTER_DOWN; mode++) {
    const d = g.decide(5, Edge.PRESS, mode, true, false);
    assert.equal(d.action, Action.NONE);
    assert.equal(d.dropped, true);
    assert.equal(g.acted(5), false);
  }
});

test('fw_di_gate: kilitliyken duvar anahtari hareketli panjuru DURDURABILIR', () => {
  const g = new DiGate();
  let d = g.decide(2, Edge.PRESS, Mode.SHUTTER_STEP, true, true);
  assert.equal(d.action, Action.SHUTTER_STOP);
  assert.equal(d.dropped, false);
  d = g.decide(3, Edge.PRESS, Mode.SHUTTER_UP, true, true);
  assert.equal(d.action, Action.SHUTTER_STOP);
  d = g.decide(4, Edge.PRESS, Mode.SHUTTER_DOWN, true, true);
  assert.equal(d.action, Action.SHUTTER_STOP);
});

test('fw_di_gate: kilitli panjur dugmeleri hareketi asla BASLATMAZ', () => {
  const g = new DiGate();
  assert.equal(g.decide(2, Edge.PRESS, Mode.SHUTTER_STEP, true, false).action, Action.NONE);
  assert.equal(g.decide(3, Edge.PRESS, Mode.SHUTTER_UP, true, false).action, Action.NONE);
  assert.equal(g.decide(4, Edge.PRESS, Mode.SHUTTER_DOWN, true, false).action, Action.NONE);
});

test('fw_di_gate: kilitli toggle/momentary, panjur aktif olsa da engelli', () => {
  const g = new DiGate();
  let d = g.decide(0, Edge.PRESS, Mode.TOGGLE, true, true);
  assert.equal(d.action, Action.NONE);
  assert.equal(d.dropped, true);
  d = g.decide(1, Edge.PRESS, Mode.MOMENTARY, true, true);
  assert.equal(d.action, Action.NONE);
  assert.equal(d.dropped, true);
});

// ---------------------------------------------------------------- birakma: ASLA yutulmaz
test('fw_di_gate: islenmis momentary basisin birakmasi roleyi KAPATIR', () => {
  const g = new DiGate();
  g.decide(1, Edge.PRESS, Mode.MOMENTARY, false, false);
  const d = g.decide(1, Edge.RELEASE, Mode.MOMENTARY, false, false);
  assert.equal(d.action, Action.RELAY_OFF);
  assert.equal(g.acted(1), false);
});

test('fw_di_gate: basili tutarken kilit acilirsa birakma yine KAPAT uretir', () => {
  const g = new DiGate();
  const press = g.decide(1, Edge.PRESS, Mode.MOMENTARY, false, false);
  assert.equal(press.action, Action.RELAY_ON);
  const rel = g.decide(1, Edge.RELEASE, Mode.MOMENTARY, true, false);
  assert.equal(rel.action, Action.RELAY_OFF);
});

test('fw_di_gate: kilitle dusen basista kilit kalkarsa birakma bayat KAPAT uretmez', () => {
  const g = new DiGate();
  const press = g.decide(1, Edge.PRESS, Mode.MOMENTARY, true, false);
  assert.equal(press.dropped, true);
  const rel = g.decide(1, Edge.RELEASE, Mode.MOMENTARY, false, false);
  assert.equal(rel.action, Action.NONE);
});

test('fw_di_gate: basissiz birakma hicbir sey yapmaz', () => {
  const g = new DiGate();
  assert.equal(g.decide(7, Edge.RELEASE, Mode.MOMENTARY, false, false).action, Action.NONE);
  assert.equal(g.decide(7, Edge.RELEASE, Mode.MOMENTARY, true, false).action, Action.NONE);
});

test('fw_di_gate: momentary olmayan modlarda birakma yok sayilir', () => {
  const g = new DiGate();
  g.decide(0, Edge.PRESS, Mode.TOGGLE, false, false);
  assert.equal(g.decide(0, Edge.RELEASE, Mode.TOGGLE, false, false).action, Action.NONE);
  g.decide(2, Edge.PRESS, Mode.SHUTTER_STEP, false, false);
  assert.equal(g.decide(2, Edge.RELEASE, Mode.SHUTTER_STEP, false, false).action, Action.NONE);
  g.decide(3, Edge.PRESS, Mode.SHUTTER_UP, false, false);
  assert.equal(g.decide(3, Edge.RELEASE, Mode.SHUTTER_UP, true, false).action, Action.NONE);
  g.decide(4, Edge.PRESS, Mode.SHUTTER_DOWN, false, false);
  assert.equal(g.decide(4, Edge.RELEASE, Mode.SHUTTER_DOWN, false, false).action, Action.NONE);
});

test('fw_di_gate: basili tutarken yapilandirma degisse de basis anindaki mod gecerli', () => {
  const g = new DiGate();
  g.decide(1, Edge.PRESS, Mode.MOMENTARY, false, false);
  const rel = g.decide(1, Edge.RELEASE, Mode.TOGGLE, false, false);
  assert.equal(rel.action, Action.RELAY_OFF);
});

test('fw_di_gate: kilitli DUR basisinin birakma eylemi yok', () => {
  const g = new DiGate();
  g.decide(3, Edge.PRESS, Mode.SHUTTER_UP, true, true);
  assert.equal(g.decide(3, Edge.RELEASE, Mode.SHUTTER_UP, true, false).action, Action.NONE);
});

test('fw_di_gate: acted maskesi bagimsiz girisleri izler', () => {
  const g = new DiGate();
  g.decide(0, Edge.PRESS, Mode.TOGGLE, false, false);
  g.decide(9, Edge.PRESS, Mode.MOMENTARY, false, false);
  g.decide(3, Edge.PRESS, Mode.TOGGLE, true, false);
  assert.equal(g.acted(0), true);
  assert.equal(g.acted(9), true);
  assert.equal(g.acted(3), false);
  assert.equal(g.actedMask(), (1n << 0n) | (1n << 9n));
  g.decide(9, Edge.RELEASE, Mode.MOMENTARY, false, false);
  assert.equal(g.actedMask(), 1n << 0n);
});

// ---------------------------------------------------------------- 60 ms kararlilik suzgeci
test('fw_di_gate: baslangic seviyesi kenar uretmez', () => {
  const g = new DiGate();
  g.init(0, true, 1000);
  assert.equal(g.sample(0, true, 1000), Edge.NONE);
  assert.equal(g.sample(0, true, 5000), Edge.NONE);
  assert.equal(g.stable(0), true);
});

test('fw_di_gate: suzgec siniri 59/60/61 ms', () => {
  const g = new DiGate();
  g.init(0, false, 0);
  assert.equal(g.sample(0, true, 1000), Edge.NONE);
  assert.equal(g.sample(0, true, 1059), Edge.NONE);
  assert.equal(g.stable(0), false);
  assert.equal(g.sample(0, true, 1060), Edge.PRESS);
  assert.equal(g.stable(0), true);

  const h = new DiGate();
  h.init(0, false, 0);
  h.sample(0, true, 2000);
  assert.equal(h.sample(0, true, 2061), Edge.PRESS);
});

test('fw_di_gate: ayni kenar tekrarlanmaz', () => {
  const g = new DiGate();
  g.init(0, false, 0);
  g.sample(0, true, 100);
  assert.equal(g.sample(0, true, 160), Edge.PRESS);
  assert.equal(g.sample(0, true, 200), Edge.NONE);
  assert.equal(g.sample(0, true, 10000), Edge.NONE);
});

test('fw_di_gate: kontak sekmesi reddedilir', () => {
  const g = new DiGate();
  g.init(0, false, 0);
  let t = 1000;
  const bounce = [true, false, true, false, true, false, true, true];
  let presses = 0;
  for (let i = 0; i < 8; i++) {
    if (g.sample(0, bounce[i], t) === Edge.PRESS) presses++;
    t += 10;
  }
  assert.equal(presses, 0);
  for (let i = 0; i < 10; i++) {
    if (g.sample(0, true, t) === Edge.PRESS) presses++;
    t += 10;
  }
  assert.equal(presses, 1);
});

test('fw_di_gate: basiliyken kisa parazit birakma sayilmaz', () => {
  const g = new DiGate();
  g.init(0, false, 0);
  const tt = { t: 100 };
  assert.equal(settle(g, 0, true, tt), Edge.PRESS);
  tt.t += 100;
  assert.equal(g.sample(0, false, tt.t), Edge.NONE);
  tt.t += 20;
  assert.equal(g.sample(0, true, tt.t), Edge.NONE);
  tt.t += 100;
  assert.equal(g.sample(0, true, tt.t), Edge.NONE);
  assert.equal(g.stable(0), true);
  tt.t += 100;
  assert.equal(settle(g, 0, false, tt), Edge.RELEASE);
});

test('fw_di_gate: suzgec millis() tasmasina dayanikli', () => {
  const g = new DiGate();
  const t0 = 0xFFFFFFF0;
  g.init(0, false, t0);
  g.sample(0, true, u32(t0 + 5));
  assert.equal(g.sample(0, true, u32(t0 + 10)), Edge.NONE);
  assert.equal(g.sample(0, true, u32(t0 + 40)), Edge.NONE);
  assert.equal(g.sample(0, true, u32(t0 + 64)), Edge.NONE);
  assert.equal(g.sample(0, true, u32(t0 + 65)), Edge.PRESS);
});

// ---------------------------------------------------------------- ek modul (ext) girisleri AYNI kapi
test('fw_di_gate: ek modul girisleri ayni kapiyi ve kilidi kullanir', () => {
  const g = new DiGate();
  const extIdx = 8 + 3;
  g.init(extIdx, false, 0);
  assert.equal(g.sample(extIdx, true, 1000), Edge.NONE);
  assert.equal(g.sample(extIdx, false, 1120), Edge.NONE);
  assert.equal(g.sample(extIdx, true, 1240), Edge.NONE);
  const e = g.sample(extIdx, true, 1360);
  assert.equal(e, Edge.PRESS);
  const d = g.decide(extIdx, e, Mode.TOGGLE, true, false);
  assert.equal(d.action, Action.NONE);
  assert.equal(d.dropped, true);
});

test('fw_di_gate: en yuksek giris indeksi ve aralik disi', () => {
  const g = new DiGate();
  g.init(39, false, 0);
  g.sample(39, true, 100);
  assert.equal(g.sample(39, true, 160), Edge.PRESS);
  g.init(40, true, 0);
  assert.equal(g.sample(40, true, 1000), Edge.NONE);
  assert.equal(g.decide(40, Edge.PRESS, Mode.TOGGLE, false, false).action, Action.NONE);
  assert.equal(g.stable(40), false);
});

// ---------------------------------------------------------------- uctan uca
test('fw_di_gate: uctan uca basis-kilit-birakma-kilit kalkma akisi', () => {
  const g = new DiGate();
  g.init(1, false, 0);
  const tt = { t: 1000 };
  let locked = false;

  let e = settle(g, 1, true, tt);
  let d = g.decide(1, e, Mode.MOMENTARY, locked, false);
  assert.equal(d.action, Action.RELAY_ON);

  locked = true;
  tt.t += 500;

  e = settle(g, 1, false, tt);
  d = g.decide(1, e, Mode.MOMENTARY, locked, false);
  assert.equal(d.action, Action.RELAY_OFF);

  tt.t += 500;
  e = settle(g, 1, true, tt);
  d = g.decide(1, e, Mode.MOMENTARY, locked, false);
  assert.equal(d.action, Action.NONE);
  assert.equal(d.dropped, true);

  locked = false;
  tt.t += 500;
  e = settle(g, 1, false, tt);
  d = g.decide(1, e, Mode.MOMENTARY, locked, false);
  assert.equal(d.action, Action.NONE);
});
