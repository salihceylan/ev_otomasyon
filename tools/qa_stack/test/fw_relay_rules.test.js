// Firmware InterlockGuard + relayrules:: saf karar kurallari (src/RelayRules.h) JS portunun UYUMLULUK testi: firmware'in kendi Unity testlerinin
// (ev_otomasyon_servis_yazilimi/waveshare_s3_demo/test/test_relay_rules/test_main.cpp) 27 testinin BIREBIR portu.
import test from 'node:test';
import assert from 'node:assert/strict';
import {
  InterlockGuard, Result, ResyncKind, planTcaResync, extNeedsOffWrite, shutterRelayBits, unverifiedRetainedShutterBits,
} from '../sim/fw/interlock_guard.js';

const R = (i) => 1n << BigInt(i);

test('fw_relay_rules: panjur olmayan ciftler kisitsiz', () => {
  const g = new InterlockGuard();
  assert.equal(g.check(R(0) | R(1), 0), Result.OK);
  g.commit(R(0) | R(1), 0);
  assert.equal(g.check(R(0), 10), Result.OK);
});

test('fw_relay_rules: iki yon ayni anda acik reddedilir', () => {
  const g = new InterlockGuard();
  g.setShutterPairs(0x01);
  assert.equal(g.check(R(0) | R(1), 0), Result.BOTH_ON);
  assert.equal(g.check(R(0), 0), Result.OK);
  assert.equal(g.check(R(1), 0), Result.OK);
  assert.equal(g.check(R(0) | R(4) | R(5), 0), Result.OK);
});

test('fw_relay_rules: her cift bagimsiz denetlenir', () => {
  const g = new InterlockGuard();
  g.setShutterPairs(0x01 | 0x02);
  assert.equal(g.check(R(2) | R(3), 0), Result.BOTH_ON);
  assert.equal(g.check(R(1) | R(2), 0), Result.OK);
});

test('fw_relay_rules: tek yazimda dogrudan yon degisimi reddedilir', () => {
  const g = new InterlockGuard();
  g.setShutterPairs(0x01);
  g.commit(R(0), 1000);
  assert.equal(g.check(R(1), 1001), Result.DIRECT_REVERSAL);
  assert.equal(g.check(0n, 1001), Result.OK);
  assert.equal(g.check(R(0), 1001), Result.OK);
});

test('fw_relay_rules: olu zaman kapanmadan sonra suruculce uygulanir', () => {
  const g = new InterlockGuard();
  g.setShutterPairs(0x01);
  g.commit(R(0), 1000);
  g.commit(0n, 2000);
  assert.equal(g.check(R(1), 2100), Result.DEAD_TIME);
  assert.equal(g.check(R(0), 2499), Result.DEAD_TIME);
  assert.equal(g.check(R(1), 2500), Result.OK);
  assert.equal(g.check(0n, 2100), Result.OK);
});

test('fw_relay_rules: olu zaman millis() tasmasindan sag cikar', () => {
  const g = new InterlockGuard();
  g.setShutterPairs(0x01);
  g.commit(R(1), 0xFFFFFF00);
  g.commit(0n, 0xFFFFFF00);
  assert.equal(g.check(R(0), 0x00000010), Result.DEAD_TIME);
  assert.equal(g.check(R(0), 0x000000F3), Result.DEAD_TIME);
  assert.equal(g.check(R(0), 0x000000F4), Result.OK);
});

test('fw_relay_rules: kapanma millis()==0 aninda olsa da olu zaman uygulanir', () => {
  const g = new InterlockGuard();
  g.setShutterPairs(0x01);
  g.commit(R(0), 0);
  g.commit(0n, 0);
  assert.equal(g.check(R(1), 100), Result.DEAD_TIME);
  assert.equal(g.check(R(1), 500), Result.OK);
});

test('fw_relay_rules: ilk enerjilemede olu zaman yok', () => {
  const g = new InterlockGuard();
  g.setShutterPairs(0x01);
  assert.equal(g.check(R(0), 0), Result.OK);
});

test('fw_relay_rules: ek modul ciftleri ayni kurali kullanir', () => {
  const g = new InterlockGuard();
  g.setShutterPairs(1 << 4);
  assert.equal(g.check(R(8) | R(9), 0), Result.BOTH_ON);
  g.commit(R(8), 100);
  assert.equal(g.check(R(9), 200), Result.DIRECT_REVERSAL);
  g.commit(0n, 300);
  assert.equal(g.check(R(9), 400), Result.DEAD_TIME);
  assert.equal(g.check(R(9), 800), Result.OK);
});

test('fw_relay_rules: en yuksek cift indeksi', () => {
  const g = new InterlockGuard();
  g.setShutterPairs(1 << 19);
  assert.equal(g.check(R(38) | R(39), 0), Result.BOTH_ON);
});

test('fw_relay_rules: commit durumu izler ve withRelay yardimcisi', () => {
  const g = new InterlockGuard();
  g.setShutterPairs(0x01);
  let m = InterlockGuard.withRelay(0n, 0, true);
  assert.equal(m, R(0));
  g.commit(m, 10);
  assert.equal(g.hw(), R(0));
  m = InterlockGuard.withRelay(m, 0, false);
  assert.equal(m, 0n);
});

test('fw_relay_rules: noteOff, inanilan gecis olmasa da olu zamani yeniden damgalar', () => {
  const g = new InterlockGuard();
  g.setShutterPairs(0x01);
  g.commit(0n, 1000);                               // inanc: zaten KAPALI -> gecis yok, kapanma ani kaydedilmez
  assert.equal(g.check(R(0), 1100), Result.OK);     // (bilinen kapanma yok: bekleme yok)
  g.noteOff(1, 2000);                               // cift 0'in ASAGI rolesi icin onayli KAPAT
  assert.equal(g.check(R(0), 2100), Result.DEAD_TIME);
  assert.equal(g.check(R(1), 2499), Result.DEAD_TIME);
  assert.equal(g.check(R(0), 2500), Result.OK);
  g.noteOff(0, 2400);                               // ikinci onayli KAPAT beklemeyi tekrar baslatir
  assert.equal(g.check(R(1), 2800), Result.DEAD_TIME);
  assert.equal(g.check(R(1), 2900), Result.OK);
});

test('fw_relay_rules: noteOff millis() tasmasina dayanikli; panjur olmayan cifti ve aralik disini yok sayar', () => {
  const g = new InterlockGuard();
  g.setShutterPairs(0x01);
  g.noteOff(0, 0xFFFFFFF0);
  assert.equal(g.check(R(0), 0x00000100), Result.DEAD_TIME);   // 0x110 = 272 ms
  assert.equal(g.check(R(0), 0x00000200), Result.OK);          // 0x210 = 528 ms
  g.noteOff(4, 5000);                                          // cift 2 panjur degil: kural uygulanmaz
  assert.equal(g.check(R(4), 5001), Result.OK);
  g.noteOff(39, 7);
  g.noteOff(40, 7);                                            // aralik disi: sessizce yok sayilir
});

// ---------------------------------------------------------------- TCA golge/fiziksel esitleme (saf karar)
// Cip sifirlanmasi / dusen role ile periyodik dogrulama arasinda golge "ACIK", donanim "KAPALI" der: yazimdan once donanim okunur,
// golge donanima esitlenir ve dusen bitler YENIDEN CEKILMEZ (aksi halde olu zamansiz yeniden enerjilenirdi).
test('fw_relay_rules: tca resync -- eslesik durumda is yapmaz', () => {
  const p = planTcaResync(0x05, 0x00, 0x05, 0x00);
  assert.equal(p.kind, ResyncKind.IN_SYNC);
  assert.equal(p.newShadow, 0x05);
  assert.equal(p.dropped, 0x00);
  assert.equal(p.writeOut, false);
  assert.equal(p.restoreConfig, false);
});

test('fw_relay_rules: tca resync -- dusen role yeniden cekilmez', () => {
  // golge: role 1 ve 3 ACIK (0x05); donanim: role 3 dusmus (0x01) -> golge donanima cekilir, yazim GEREKMEZ
  const p = planTcaResync(0x01, 0x00, 0x05, 0x00);
  assert.equal(p.kind, ResyncKind.DROPPED);
  assert.equal(p.newShadow, 0x01);
  assert.equal(p.dropped, 0x04);
  assert.equal(p.writeOut, false);
  assert.equal(p.restoreConfig, false);
});

test('fw_relay_rules: tca resync -- beklenmeyen ACIK role kapatilir', () => {
  // golge 0x01; donanim 0x41 (role 7 kendiliginden cekmis, golgede KAPALI: tehlikeli) -> kapatilir, dusen yok
  const p = planTcaResync(0x41, 0x00, 0x01, 0x00);
  assert.equal(p.kind, ResyncKind.FIX_EXTRA);
  assert.equal(p.newShadow, 0x01);
  assert.equal(p.dropped, 0x00);
  assert.equal(p.writeOut, true);
});

test('fw_relay_rules: tca resync -- dusen + fazla bit birlikte: dusen ASLA yeniden cekilmez', () => {
  // golge 0x05; donanim 0x41: role 3 dusmus + role 7 fazla. Yazilacak deger 0x01 (golge VE donanim)
  const p = planTcaResync(0x41, 0x00, 0x05, 0x00);
  assert.equal(p.kind, ResyncKind.DROPPED);
  assert.equal(p.newShadow, 0x01);
  assert.equal(p.dropped, 0x04);
  assert.equal(p.writeOut, true);
});

test('fw_relay_rules: tca resync -- cip sifirlanmasi her seyi dusurur ve yon yazmacini geri yukler', () => {
  const p = planTcaResync(0xFF, 0xFF, 0x15, 0x00);
  assert.equal(p.kind, ResyncKind.CHIP_RESET);
  assert.equal(p.newShadow, 0x00);
  assert.equal(p.dropped, 0x15);
  assert.equal(p.writeOut, true);
  assert.equal(p.restoreConfig, true);
  const q = planTcaResync(0xFF, 0xFF, 0x00, 0x00);                // bostayken sifirlanma: dusen yok ama yon yine geri yuklenir
  assert.equal(q.kind, ResyncKind.CHIP_RESET);
  assert.equal(q.dropped, 0x00);
  assert.equal(q.restoreConfig, true);
});

test('fw_relay_rules: tca resync -- cikislar tutsa bile yon yazmaci farki cip sifirlanmasidir', () => {
  const p = planTcaResync(0x05, 0x01, 0x05, 0x00);
  assert.equal(p.kind, ResyncKind.CHIP_RESET);
  assert.equal(p.dropped, 0x05);
});

test('fw_relay_rules: tca resync sonrasi guard.commit dusen cift icin olu zamani yeniden baslatir', () => {
  const g = new InterlockGuard();
  g.setShutterPairs(0x02);                                        // cift 1 = role 2/3
  g.commit(R(2), 100);                                            // role 2 (cift 1 YUKARI) ACIK saniliyor
  const p = planTcaResync(0x00, 0x00, 0x04, 0x00);                // donanimda dusmus
  assert.equal(p.dropped, 0x04);
  g.commit(p.newShadow, 5000);                                    // esitleme ani = fiziksel kapanma ani olarak damgalanir
  assert.equal(g.check(R(2), 5100), Result.DEAD_TIME);            // yeniden cekme: olu zaman
  assert.equal(g.check(R(3), 5499), Result.DEAD_TIME);
  assert.equal(g.check(R(2), 5500), Result.OK);
});

test('fw_relay_rules: tca resync -- physical: okunan deger (cip sifirlanmasi disinda); sifirlanmada pinler girise doner = 0', () => {
  assert.equal(planTcaResync(0x41, 0x00, 0x01, 0x00).physical, 0x41);   // fazla acik bit dahil okunan deger
  assert.equal(planTcaResync(0x01, 0x00, 0x05, 0x00).physical, 0x01);   // dusen bit fiziksel olarak KAPALI
  assert.equal(planTcaResync(0x05, 0x00, 0x05, 0x00).physical, 0x05);   // senkron
  assert.equal(planTcaResync(0xFF, 0xFF, 0x15, 0x00).physical, 0x00);   // cip sifirlanmasi: hicbir role enerjili degil
});

test('fw_relay_rules: tca resync iki asamali commit -- fiziksel olarak fazla ACIK panjur rolesi kapatilinca olu zaman O kapanmadan baslar', () => {
  const g = new InterlockGuard();
  g.setShutterPairs(0x01);
  g.commit(0n, 100);
  const p = planTcaResync(0x01, 0x00, 0x00, 0x00);                // YUKARI rolesi fiziksel ACIK (firmware bilmiyor)
  assert.equal(p.kind, ResyncKind.FIX_EXTRA);
  assert.equal(p.physical, 0x01);
  assert.equal(p.newShadow, 0x00);
  // (a) yalniz newShadow islenseydi: "KAPALIydi, KAPALI kaldi" -> kapanma damgasi YOK; hemen ters yon / yeniden enerjileme serbest olurdu
  const naive = new InterlockGuard();
  naive.setShutterPairs(0x01);
  naive.commit(0n, 100);
  naive.commit(BigInt(p.newShadow), 1010);
  assert.equal(naive.check(R(1), 1015), Result.OK);
  // (b) iki asamali: once fiziksel gercek (ACIK), sonra kapatma -> ACIK->KAPALI gecisi 1010'da damgalanir
  g.commit(BigInt(p.physical), 1000);
  assert.equal(g.check(R(1), 1001), Result.DIRECT_REVERSAL);      // duzeltme yazimi yapilamadiysa ters yon gercege gore reddedilir
  g.commit(BigInt(p.newShadow), 1010);
  assert.equal(g.check(R(1), 1015), Result.DEAD_TIME);
  assert.equal(g.check(R(0), 1509), Result.DEAD_TIME);
  assert.equal(g.check(R(0), 1510), Result.OK);
});

test('fw_relay_rules: shutterRelayBits panjur cifti maskesinden role bitlerini cikarir (yalniz yerel 4 cift)', () => {
  assert.equal(shutterRelayBits(0x00), 0x00);
  assert.equal(shutterRelayBits(0x01), 0x03);
  assert.equal(shutterRelayBits(0x02), 0x0C);
  assert.equal(shutterRelayBits(0x05), 0x33);
  assert.equal(shutterRelayBits(0x0F), 0xFF);
  assert.equal(shutterRelayBits(0xF0), 0x00);                     // ust ciftler (harici modul) yok sayilir
});

test('fw_relay_rules: unverifiedRetainedShutterBits yalniz KORUNAN panjur bitlerini secer (yeni enerjilenen ve lamba bitleri disarida)', () => {
  // cift 0 ve 1 panjur (bit 0..3); lamba bitleri 4..7. Golge: role 2 (cift 1 YUKARI) + lamba bit 4 ACIK.
  // Yazilacak: role 2 (KORUNAN) + role 0 (YENI) + lamba bit 4 (korunan) + lamba bit 5 (yeni)
  const shadow = 0x14, mask = 0x35;
  assert.equal(unverifiedRetainedShutterBits(mask, shadow, 0x03), 0x04);
  assert.equal(unverifiedRetainedShutterBits(mask, shadow, 0x00), 0x00);   // panjur cifti tanimli degil: dogrulanamayan bit yok
  assert.equal(unverifiedRetainedShutterBits(0x00, shadow, 0x03), 0x00);   // KAPATMA yazimi
  assert.equal(unverifiedRetainedShutterBits(0x01, 0x00, 0x03), 0x00);     // golgede zaten KAPALI
});

// ---------------------------------------------------------------- Harici modul: KAPAT yazimi gerekir mi
test('fw_relay_rules: ext KAPAT yazimi kurallari', () => {
  // acilmasi ISTENIYOR: asla KAPAT
  assert.equal(extNeedsOffWrite(true, false, true, false), false);
  assert.equal(extNeedsOffWrite(true, true, true, false), false);
  assert.equal(extNeedsOffWrite(true, false, false, false), false);
  // istenmiyor + bilinen KAPALI: gerek yok
  assert.equal(extNeedsOffWrite(false, false, true, false), false);
  // istenmiyor + bilinen ACIK: KAPAT
  assert.equal(extNeedsOffWrite(false, true, true, false), true);
  // istenmiyor + durum BILINMIYOR (acik olabilir): KAPAT
  assert.equal(extNeedsOffWrite(false, false, false, false), true);
  assert.equal(extNeedsOffWrite(false, true, false, false), true);
});

test('fw_relay_rules: ext KAPAT yazimi ham TOGGLE sonrasi benimse-bekleyen roleyi atlar', () => {
  // ham TOGGLE sonrasi: durum bilinmiyor (hwKnown=false), istenen durum henuz benimsenmedi (want=false). KAPATIRSA TOGGLE ile acilan role
  // ~10-20 ms cekip birakirdi (QA bulgusu): benimse-bekleyen role KAPATILMAZ
  assert.equal(extNeedsOffWrite(false, false, false, true), false);
  assert.equal(extNeedsOffWrite(false, true, false, true), false);
  assert.equal(extNeedsOffWrite(false, false, false, false), true);   // benimse bayragi yoksa ayni durum KAPAT gerektirir (guvenli taraf)
});

test('fw_relay_rules: rastgele yuruyusle degismez (100000 adim)', () => {
  let rng = 7;
  const next = () => { rng = (Math.imul(rng, 1664525) + 1013904223) >>> 0; return rng; };
  const g = new InterlockGuard();
  g.setShutterPairs(0x0000FFFF);
  let t = 0;
  for (let i = 0; i < 100000; i++) {
    next();
    t = (t + (rng >>> 24) * 3) >>> 0;
    next();
    const cand = ((BigInt(rng) << 16n) ^ BigInt(rng >>> 7)) & 0xFFFFFFFFn;
    if (g.check(cand, t) === Result.OK) {
      const prev = g.hw();
      g.commit(cand, t);
      for (let p = 0; p < 16; p++) {
        const o = Number((prev >> BigInt(2 * p)) & 3n);
        const n = Number((cand >> BigInt(2 * p)) & 3n);
        assert.notEqual(n, 3, 'n==3 kabul edildi');
        assert.ok(!(o !== 0 && n !== 0 && o !== n), 'dogrudan yon degisimi kabul edildi');
      }
    }
  }
});
