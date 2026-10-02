// PhysicalObserver: firmware testlerindeki Sim.apply() degismezlerini sistemin emniyet katmanindan bagimsiz denetler.
import test from 'node:test';
import assert from 'node:assert/strict';
import { PhysicalObserver } from '../sim/fw/observer.js';

const valid = new Array(20).fill(false);
valid[0] = true;
valid[1] = true;
const R = (i) => 1n << BigInt(i);

test('observer: temiz gecisler ihlal uretmez (YUKARI -> KAPALI -> 500 ms -> ASAGI)', () => {
  const o = new PhysicalObserver();
  o.boot(0);
  assert.deepEqual(o.observe(1000, R(0), valid), []);
  assert.deepEqual(o.observe(2000, 0n, valid), []);
  assert.deepEqual(o.observe(2500, R(1), valid), []);
  assert.deepEqual(o.violations, []);
  assert.ok(o.transitions >= 3);
});

test('observer: iki yon ayni anda, dogrudan yon degisimi ve olu zaman ihlalleri yakalanir', () => {
  const o = new PhysicalObserver();
  o.boot(0);
  assert.equal(o.observe(1000, R(0) | R(1), valid)[0].code, 'both_on');
  const o2 = new PhysicalObserver();
  o2.boot(0);
  o2.observe(1000, R(0), valid);
  assert.equal(o2.observe(1100, R(1), valid)[0].code, 'direct_reversal');
  const o3 = new PhysicalObserver();
  o3.boot(0);
  o3.observe(1000, R(0), valid);
  o3.observe(2000, 0n, valid);
  const v = o3.observe(2400, R(1), valid);
  assert.equal(v[0].code, 'dead_time');
  assert.equal(v[0].since_ms, 400);
});

test('observer: acilista her cift "az once kapandi" sayilir (ilk enerjileme de 500 ms olu zamana tabi); lamba ciftleri denetlenmez', () => {
  const o = new PhysicalObserver();
  o.boot(10000);
  assert.equal(o.observe(10300, R(0), valid)[0].code, 'dead_time');
  const o2 = new PhysicalObserver();
  o2.boot(10000);
  assert.deepEqual(o2.observe(10600, R(0), valid), []);
  // 3. cift (lamba) iki role birden acik olabilir
  const o3 = new PhysicalObserver();
  o3.boot(0);
  assert.deepEqual(o3.observe(1000, R(4) | R(5), valid), []);
});

test('observer: millis() tasmasinda olu zaman dogru hesaplanir', () => {
  const o = new PhysicalObserver();
  o.boot(0);
  o.observe(0xFFFFFF00, R(0), valid);
  o.observe(0xFFFFFF80, 0n, valid);
  assert.equal(o.observe(0x00000010, R(1), valid)[0].code, 'dead_time');   // 144 ms
  const o2 = new PhysicalObserver();
  o2.boot(0);
  o2.observe(0xFFFFFF00, R(0), valid);
  o2.observe(0xFFFFFF80, 0n, valid);
  assert.deepEqual(o2.observe(0x00000280, R(1), valid), []);                // > 500 ms
});
