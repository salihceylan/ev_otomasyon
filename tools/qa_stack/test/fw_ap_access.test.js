// Firmware ApAccess (src/ApAccess.h) JS portunun UYUMLULUK testi: firmware'in kendi Unity testlerinin
// (ev_otomasyon_servis_yazilimi/waveshare_s3_demo/test/test_ap_access/test_main.cpp) 15 testinin BIREBIR portu.
//
// Wi-Fi servis akisi icin AP KAYNAKLI yetkilendirme karari (CONTRACTS 3d): teknisyen musteride panonun kurtarma agindayken internet YOKTUR;
// GET /api/wifi/scan, POST /api/wifi/connect ve GET /api/wifi/status icin gecerli X-Device-Key YA DA (istemci SoftAP arayuzunde + AP su an WPA2
// + gecerli ap_pass + provizyonlu) yeterlidir. Bu testler: karar fonksiyonunun TUM 32 girdi birlesimini (elle yazilmis tablo + bagimsiz ozellik
// denetimi), "istemci SoftAP arayuzunde mi" alt ag kararini (STA alt agi cakismasi, sifir/gecersiz adresler, bayt sirasi), AP kaynakli anahtarsiz
// connect icin global hiz sinirini (dakikada 6, Retry-After, kayan pencere, sarma tabanlari, 60 gunluk sessizlik) dogrular.
import test from 'node:test';
import assert from 'node:assert/strict';
import {
  allowed, apOrigin, clientOnSoftAp, ConnectLimiter, sameSubnet, subnetsOverlap, via, VIA_AP, VIA_DENIED, VIA_KEY, ipToU32, u32ToIp,
} from '../sim/fw/ap_access.js';

const u32 = (x) => x >>> 0;

// IPAddress -> uint32_t gosterimi (ilk sekizli en dusuk bayt) ve ters (ag sirasi) gosterim: sonuc ikisinde de ayni olmali.
const ipLE = (a, b, c, d) => u32(a | (b << 8) | (c << 16) | (d << 24));
const ipBE = (a, b, c, d) => u32((a << 24) | (b << 16) | (c << 8) | d);

// ---------------------------------------------------------------------------------------------------------------
// 1) Karar tablosu: (clientOnAp, apIsWpa2, hasApPass, provisioned, hasValidKey) -> izin / nasil
// ---------------------------------------------------------------------------------------------------------------
//   onAp  wpa2  apPw  prov  key   izin   nasil
const kTable = [
  // ---- provizyonsuz cihaz (local_key yok): HICBIR yol acik degil. "Gecerli anahtar" bu durumda var olamaz; imkansiz birlesim (key=1) de
  //      REDDEDILIR (kapali basarisizlik). Acik kurulum AP'sinde yalniz factory/init + kisitli status. ----
  [false, false, false, false, false, false, VIA_DENIED],
  [false, false, false, false, true, false, VIA_DENIED],
  [false, false, true, false, false, false, VIA_DENIED],
  [false, false, true, false, true, false, VIA_DENIED],
  [false, true, false, false, false, false, VIA_DENIED],
  [false, true, false, false, true, false, VIA_DENIED],
  [false, true, true, false, false, false, VIA_DENIED],
  [false, true, true, false, true, false, VIA_DENIED],
  [true, false, false, false, false, false, VIA_DENIED],   // acik kurulum AP'sindeki istemci (provizyonsuz)
  [true, false, false, false, true, false, VIA_DENIED],
  [true, false, true, false, false, false, VIA_DENIED],
  [true, false, true, false, true, false, VIA_DENIED],
  [true, true, false, false, false, false, VIA_DENIED],
  [true, true, false, false, true, false, VIA_DENIED],
  [true, true, true, false, false, false, VIA_DENIED],     // WPA2 + ap_pass + AP istemcisi ama provizyonsuz: RET
  [true, true, true, false, true, false, VIA_DENIED],
  // ---- provizyonlu + GECERLI ANAHTAR: her kosulda IZIN (anahtarla) ----
  [false, false, false, true, true, true, VIA_KEY],
  [false, false, true, true, true, true, VIA_KEY],
  [false, true, false, true, true, true, VIA_KEY],
  [false, true, true, true, true, true, VIA_KEY],          // LAN istemcisi + anahtar
  [true, false, false, true, true, true, VIA_KEY],
  [true, false, true, true, true, true, VIA_KEY],          // ACIK AP'deki istemci + anahtar
  [true, true, false, true, true, true, VIA_KEY],
  [true, true, true, true, true, true, VIA_KEY],           // AP istemcisi + anahtar: anahtarli sayilir (hiz siniri yok)
  // ---- provizyonlu + ANAHTARSIZ: yalnizca (AP istemcisi && AP WPA2 && ap_pass) IZIN ----
  [false, false, false, true, false, false, VIA_DENIED],   // AP disi + anahtarsiz = RET
  [false, false, true, true, false, false, VIA_DENIED],
  [false, true, false, true, false, false, VIA_DENIED],
  [false, true, true, true, false, false, VIA_DENIED],     // WPA2 AP acik ama istemci AP'de degil (LAN) = RET
  [true, false, false, true, false, false, VIA_DENIED],
  [true, false, true, true, false, false, VIA_DENIED],     // ACIK AP + anahtarsiz = RET (provizyon penceresi)
  [true, true, false, true, false, false, VIA_DENIED],     // WPA2 ama gecerli ap_pass yok = RET
  [true, true, true, true, false, true, VIA_AP],           // WPA2 AP + provizyonlu + AP istemcisi + anahtarsiz = IZIN
];

/** 0 = hepsi dogru; aksi halde (satir numarasi, 1 tabanli) */
function tableFirstBadRow() {
  for (let i = 0; i < 32; i++) {
    const [onAp, wpa2, apPass, prov, key, expectAllowed, expectVia] = kTable[i];
    const a = allowed(onAp, wpa2, apPass, prov, key);
    const v = via(onAp, wpa2, apPass, prov, key);
    if (a !== expectAllowed || v !== expectVia) return i + 1;
  }
  return 0;
}

/** Tablo gercekten 32 FARKLI birlesimi kapsiyor mu? 0 = evet; aksi halde ilk tekrar eden satir (1 tabanli) */
function tableFirstDuplicateRow() {
  const seen = new Array(32).fill(false);
  for (let i = 0; i < 32; i++) {
    const [onAp, wpa2, apPass, prov, key] = kTable[i];
    const code = (onAp ? 16 : 0) | (wpa2 ? 8 : 0) | (apPass ? 4 : 0) | (prov ? 2 : 0) | (key ? 1 : 0);
    if (seen[code]) return i + 1;
    seen[code] = true;
  }
  return 0;
}

/** Tablodan BAGIMSIZ ozellik denetimi: 5 bitin tum birlesimleri icin kural ifadeleri (farkli yapida yazilmistir). */
function propertiesFirstViolation() {
  for (let m = 0; m < 32; m++) {
    const onAp = (m & 16) !== 0; const wpa2 = (m & 8) !== 0; const apPass = (m & 4) !== 0; const prov = (m & 2) !== 0; const key = (m & 1) !== 0;
    const a = allowed(onAp, wpa2, apPass, prov, key);
    const v = via(onAp, wpa2, apPass, prov, key);
    // P1: provizyonsuz -> hicbir sey acik degil
    if (!prov && (a || v !== VIA_DENIED)) return 100 + m;
    // P2: provizyonlu + gecerli anahtar -> her kosulda izin ve "anahtarla"
    if (prov && key && (!a || v !== VIA_KEY)) return 200 + m;
    // P3: provizyonlu + anahtarsiz -> izin ancak ve ancak AP istemcisi && WPA2 && ap_pass
    if (prov && !key) {
      const expect = onAp && wpa2 && apPass;
      if (a !== expect) return 300 + m;
      if (a && v !== VIA_AP) return 400 + m;
      if (!a && v !== VIA_DENIED) return 500 + m;
    }
    // P4: allowed() ile via() daima tutarli
    if (a !== (v !== VIA_DENIED)) return 600 + m;
    // P5: AP kaynakli yolun yardimcisi: apOrigin yalnizca dort kosulun HEPSIYLE true
    const ao = apOrigin(onAp, wpa2, apPass, prov);
    if (ao !== (onAp && wpa2 && apPass && prov)) return 700 + m;
  }
  return 0;
}

// ---------------------------------------------------------------------------------------------------------------
// 2) Istemci SoftAP arayuzunde mi
// ---------------------------------------------------------------------------------------------------------------
/** ip: ipLE veya ipBE; sonuc iki gosterimde de ayni olmali. 0 = tamam; aksi halde basarisiz kontrol kodu. */
function subnetFirstFailure(ip) {
  const apIp = ip(192, 168, 4, 1);
  const m24 = ip(255, 255, 255, 0);
  const none = 0;
  const T = (code, cond) => (cond ? 0 : code);
  const checks = [
    // --- tipik: STA bagli degil, telefon AP'de ---
    [1, clientOnSoftAp(true, ip(192, 168, 4, 2), apIp, m24, none, none)],
    [2, clientOnSoftAp(true, ip(192, 168, 4, 254), apIp, m24, none, none)],
    [3, clientOnSoftAp(true, ip(192, 168, 4, 100), apIp, m24, none, none)],
    // --- AP alt agi disi: ev LAN'i, baska ozel aglar, genel adresler ---
    [4, !clientOnSoftAp(true, ip(192, 168, 1, 50), apIp, m24, none, none)],
    [5, !clientOnSoftAp(true, ip(192, 168, 5, 2), apIp, m24, none, none)],
    [6, !clientOnSoftAp(true, ip(192, 168, 3, 2), apIp, m24, none, none)],
    [7, !clientOnSoftAp(true, ip(10, 0, 0, 5), apIp, m24, none, none)],
    [8, !clientOnSoftAp(true, ip(8, 8, 8, 8), apIp, m24, none, none)],
    [9, !clientOnSoftAp(true, ip(127, 0, 0, 1), apIp, m24, none, none)],
    [10, !clientOnSoftAp(true, ip(192, 168, 4 + 128, 2), apIp, m24, none, none)],
    // --- AP yayinda degil ---
    [11, !clientOnSoftAp(false, ip(192, 168, 4, 2), apIp, m24, none, none)],
    // --- gecersiz/sifir adresler ---
    [12, !clientOnSoftAp(true, 0, apIp, m24, none, none)],                              // uzak IP bilinmiyor (IPv6 vb.)
    [34, !clientOnSoftAp(true, 0, ip(0, 0, 0, 1), m24, none, none)],                    // "bilinmeyen" 0.0.0.0, AP alt agina dusse bile istemci sayilmaz
    [13, !clientOnSoftAp(true, ip(192, 168, 4, 2), 0, m24, none, none)],                // AP adresi yok
    [14, !clientOnSoftAp(true, ip(192, 168, 4, 2), apIp, 0, none, none)],               // maske yok
    [15, !clientOnSoftAp(true, apIp, apIp, m24, none, none)],                           // cihazin kendi adresi
    // --- STA bagli, alt aglar AYRI: AP istemcisi kabul, LAN istemcisi ret ---
    [16, clientOnSoftAp(true, ip(192, 168, 4, 2), apIp, m24, ip(192, 168, 1, 50), m24)],
    [17, !clientOnSoftAp(true, ip(192, 168, 1, 20), apIp, m24, ip(192, 168, 1, 50), m24)],
    [18, clientOnSoftAp(true, ip(192, 168, 4, 2), apIp, m24, ip(10, 20, 30, 40), ip(255, 0, 0, 0))],
    [19, clientOnSoftAp(true, ip(192, 168, 4, 2), apIp, m24, ip(192, 168, 5, 9), m24)],          // komsu /24, cakismaz
    // --- STA alt agi AP alt agiyla CAKISIYOR: ag konumu ayirt ettirmez -> RET (kapali basarisizlik) ---
    [20, !clientOnSoftAp(true, ip(192, 168, 4, 2), apIp, m24, ip(192, 168, 4, 77), m24)],        // modem de 192.168.4.0/24
    [21, !clientOnSoftAp(true, ip(192, 168, 4, 2), apIp, m24, ip(192, 168, 4, 1), m24)],         // ayni adres
    [22, !clientOnSoftAp(true, ip(192, 168, 4, 2), apIp, m24, ip(192, 168, 7, 7), ip(255, 255, 0, 0))],    // STA /16, AP /24'u kapsar
    [23, !clientOnSoftAp(true, ip(192, 168, 4, 2), apIp, m24, ip(192, 168, 4, 130), ip(255, 255, 255, 128))], // STA /25, AP /24 icinde
    [24, !clientOnSoftAp(true, ip(192, 168, 4, 2), apIp, m24, ip(192, 168, 4, 77), ip(255, 255, 255, 0))],
    [25, !clientOnSoftAp(true, ip(192, 168, 4, 2), apIp, m24, ip(192, 0, 0, 9), ip(255, 0, 0, 0))],        // STA /8
    // --- STA IP var ama maske bilinmiyor (tutarsiz durum): IP AP alt agindaysa RET, degilse kabul ---
    [26, !clientOnSoftAp(true, ip(192, 168, 4, 2), apIp, m24, ip(192, 168, 4, 77), 0)],
    [27, clientOnSoftAp(true, ip(192, 168, 4, 2), apIp, m24, ip(192, 168, 1, 77), 0)],
    // --- bolum yardimcilari ---
    [28, sameSubnet(ip(10, 1, 2, 3), ip(10, 1, 2, 200), m24)],
    [29, !sameSubnet(ip(10, 1, 2, 3), ip(10, 1, 3, 3), m24)],
    [30, !sameSubnet(ip(10, 1, 2, 3), ip(10, 1, 2, 3), 0)],
    [31, subnetsOverlap(ip(10, 0, 0, 1), ip(255, 0, 0, 0), ip(10, 5, 5, 5), m24)],
    [32, !subnetsOverlap(ip(10, 0, 0, 1), ip(255, 0, 0, 0), ip(11, 5, 5, 5), m24)],
    [33, !subnetsOverlap(ip(10, 0, 0, 1), 0, ip(10, 5, 5, 5), m24)],
  ];
  for (const [code, cond] of checks) if (T(code, cond) !== 0) return code;
  return 0;
}

// ---------------------------------------------------------------------------------------------------------------
// 3) ConnectLimiter: dakikada en cok 6 (kayan pencere), Retry-After, sarma, uzun sessizlik
// ---------------------------------------------------------------------------------------------------------------
const kBases = [0, 5000, 0x40000000, 0x7FFFFFF0, 0x80000000, 0xFFFFF000, 0xFFFFFFF0];

/** 0 = tamam; aksi halde basarisiz kontrol kodu */
function limiterBurstAndSlidingWindow(base) {
  const lim = new ConnectLimiter();
  let r;
  // t=0: 6 istek hemen kabul (ayni anda)
  for (let i = 0; i < 6; i++) {
    if (!lim.tryAcquire(u32(base)).ok) return 1;
  }
  if (lim.used() !== 6) return 2;
  // 7. istek: ret, Retry-After = 60
  r = lim.tryAcquire(u32(base));
  if (r.ok) return 3;
  if (r.retryAfterSec !== 60) return 4;
  // 1 sn sonra: ret, Retry-After = 59
  r = lim.tryAcquire(u32(base + 1000));
  if (r.ok) return 5;
  if (r.retryAfterSec !== 59) return 6;
  // reddedilen denemeler yuva TUKETMEZ ve pencereyi UZATMAZ
  if (lim.used() !== 6) return 7;
  r = lim.tryAcquire(u32(base + 59999));
  if (r.ok) return 8;
  if (r.retryAfterSec !== 1) return 9;
  // tam 60 sn sonra tum yuvalar bosalir: 6 yeni istek
  for (let i = 0; i < 6; i++) {
    if (!lim.tryAcquire(u32(base + 60000)).ok) return 10;
  }
  if (lim.tryAcquire(u32(base + 60000)).ok) return 11;

  // Kayan pencere: 10 sn arayla 6 istek; ilk yuva 60. sn'de bosalir, YALNIZ bir yeni istek kabul edilir
  const s = new ConnectLimiter();
  for (let i = 0; i < 6; i++) {
    if (!s.tryAcquire(u32(base + i * 10000)).ok) return 20;   // t = 0,10,20,30,40,50
  }
  r = s.tryAcquire(u32(base + 55000));
  if (r.ok) return 21;
  if (r.retryAfterSec !== 5) return 22;                       // en erken bosalacak yuva t=0'dan: 60 - 55 = 5
  if (!s.tryAcquire(u32(base + 60000)).ok) return 23;         // t=0 yuvasi doldu
  r = s.tryAcquire(u32(base + 60000));
  if (r.ok) return 24;
  if (r.retryAfterSec !== 10) return 25;                      // siradaki: t=10'un yuvasi, 70. sn
  if (s.tryAcquire(u32(base + 69999)).ok) return 26;
  if (!s.tryAcquire(u32(base + 70000)).ok) return 27;
  if (s.tryAcquire(u32(base + 70000)).ok) return 28;
  return 0;
}

/** Her tur service() ile 60 gun: yuvalar sonlanir, sarma "taze" gostermez, sinirlayici donmaz */
function limiterPolledSixtyDays(base) {
  const lim = new ConnectLimiter();
  let t = 0;
  const end = 60 * 86400000;
  let cycles = 0;
  while (t < end) {
    const now = u32(base + t);   // 32 bit sarar
    lim.service(now);
    // 6 kabul, 7. ret
    for (let i = 0; i < 6; i++) {
      if (!lim.tryAcquire(now).ok) return 1;
    }
    const r = lim.tryAcquire(now);
    if (r.ok) return 2;
    if (r.retryAfterSec !== 60) return 3;
    // Sessizlik: 60 sn adimlarla yoklanir (kaba adim; sinirlar 2^31 ms'in cok altinda)
    const next = t + 5 * 3600 * 1000 + 60000;   // yaklasik 5 saat sonra yeniden istek
    while (t < next && t < end) {
      t += 60000;
      lim.service(u32(base + t));
    }
    if (lim.used() !== 0) return 4;   // sessizlikte tum yuvalar sonlandi
    cycles++;
  }
  if (!(cycles > 100)) return 5;
  return 0;
}

/** YOKLAMA YOK (service hic cagrilmaz): tryAcquire kendi icinde yoklar; 49,7 gunden kisa sessizlikte dogru calisir */
function limiterWithoutPollingAfterLongQuiet(base) {
  const quiet = [61000, 3600 * 1000, 24 * 86400000 + 20 * 3600000, 25 * 86400000, 30 * 86400000, 0x100000000 - 1000];
  for (const q of quiet) {
    const lim = new ConnectLimiter();
    for (let i = 0; i < 6; i++) {
      if (!lim.tryAcquire(u32(base)).ok) return 1;
    }
    if (lim.tryAcquire(u32(base + 1000)).ok) return 2;
    const later = u32(base + q);   // 32 bit sarma dahil
    if (!lim.tryAcquire(later).ok) return 3;   // sessizlikten sonra yeniden izin
    if (lim.used() !== 1) return 4;
  }
  return 0;
}

// ---------------------------------------------------------------------------------------------------------------
// Test fonksiyonlari (firmware ile ayni 15 test, ayni sira)
// ---------------------------------------------------------------------------------------------------------------
test('fw_ap_access: 1) karar tablosu: 32 birlesimin TAMAMI elle yazilmis', () => {
  assert.equal(tableFirstDuplicateRow(), 0, 'tablo 32 farkli birlesimi kapsiyor');
  assert.equal(tableFirstBadRow(), 0);
});

test('fw_ap_access: 2) karar ozellikleri her girdi birlesiminde gecerli', () => {
  assert.equal(propertiesFirstViolation(), 0);
});

test('fw_ap_access: 3) AP disi (LAN/internet) + anahtarsiz: her AP/provizyon durumunda RET', () => {
  for (let m = 0; m < 8; m++) {
    const wpa2 = (m & 4) !== 0; const apPass = (m & 2) !== 0; const prov = (m & 1) !== 0;
    assert.equal(allowed(false, wpa2, apPass, prov, false), false);
    assert.equal(via(false, wpa2, apPass, prov, false), VIA_DENIED);
  }
});

test('fw_ap_access: 4) ACIK kurulum AP\'si + anahtarsiz: provizyonlu olsa bile RET (factory/init sonrasi ~1,5 sn dahil)', () => {
  assert.equal(allowed(true, false, true, true, false), false);
  assert.equal(allowed(true, false, false, true, false), false);
  assert.equal(allowed(true, false, false, false, false), false);
  // factory/init ile provizyonlanmis ama AP henuz WPA2'ye donmemis (~1,5 sn): hala RET
  assert.equal(allowed(true, false, true, true, false), false);
});

test('fw_ap_access: 5) WPA2 AP + provizyonlu + AP istemcisi + anahtarsiz: IZIN (VIA_AP)', () => {
  assert.equal(allowed(true, true, true, true, false), true);
  assert.equal(via(true, true, true, true, false), VIA_AP);
});

test('fw_ap_access: 6) WPA2 AP ama gecerli ap_pass yok: RET', () => {
  assert.equal(allowed(true, true, false, true, false), false);
});

test('fw_ap_access: 7) provizyonsuz cihaz her seyi (imkansiz anahtar birlesimi dahil) reddeder', () => {
  for (let m = 0; m < 8; m++) {
    const onAp = (m & 4) !== 0; const wpa2 = (m & 2) !== 0; const apPass = (m & 1) !== 0;
    assert.equal(allowed(onAp, wpa2, apPass, false, false), false);
    assert.equal(allowed(onAp, wpa2, apPass, false, true), false, 'imkansiz birlesim: kapali basarisizlik');
  }
});

test('fw_ap_access: 8) provizyonluyken gecerli anahtar her kosulda izin verir (VIA_KEY)', () => {
  for (let m = 0; m < 8; m++) {
    const onAp = (m & 4) !== 0; const wpa2 = (m & 2) !== 0; const apPass = (m & 1) !== 0;
    assert.equal(allowed(onAp, wpa2, apPass, true, true), true);
    assert.equal(via(onAp, wpa2, apPass, true, true), VIA_KEY);
  }
});

test('fw_ap_access: 9) AP\'deki gecerli anahtar "anahtarli" sayilir, AP kaynakli degil (hiz siniri uygulanmaz)', () => {
  assert.equal(via(true, true, true, true, true), VIA_KEY);
  assert.equal(via(true, true, true, true, false), VIA_AP);
});

test('fw_ap_access: 10) istemci SoftAP alt agi kurallari (little-endian gosterim)', () => {
  assert.equal(subnetFirstFailure(ipLE), 0);
});

test('fw_ap_access: 11) istemci SoftAP alt agi kurallari bayt sirasindan bagimsiz', () => {
  assert.equal(subnetFirstFailure(ipBE), 0);
});

test('fw_ap_access: 12) ConnectLimiter dakikada 6, kayan pencere ve Retry-After', () => {
  for (const b of kBases) assert.equal(limiterBurstAndSlidingWindow(b), 0, `taban ${b.toString(16)}`);
});

test('fw_ap_access: 13) ConnectLimiter 60 gun yoklamayla donmaz (sarma tabanlari)', () => {
  assert.equal(limiterPolledSixtyDays(0), 0);
  assert.equal(limiterPolledSixtyDays(0x7FFFF000), 0);
  assert.equal(limiterPolledSixtyDays(0xFFFF0000), 0);
});

test('fw_ap_access: 14) ConnectLimiter uzun sessizlikten sonra yoklamasiz da calisir', () => {
  for (const b of kBases) assert.equal(limiterWithoutPollingAfterLongQuiet(b), 0, `taban ${b.toString(16)}`);
});

test('fw_ap_access: 15) anahtarli istekler AP connect butcesini tuketmez (yalniz VIA_AP yolu sinirlayiciya girer)', () => {
  // WebPortal akisi: yalniz VIA_AP yolu sinirlayiciya girer; anahtarli istekler girmez.
  const lim = new ConnectLimiter();
  let apAccepted = 0; let apDenied = 0; let keyed = 0; let lastRa = 0;
  for (let i = 0; i < 40; i++) {
    const sendKey = i % 2 === 0;   // yarisi gecerli anahtarli
    const v = via(true, true, true, true, sendKey);
    if (v === VIA_KEY) {
      keyed++;
    } else if (v === VIA_AP) {
      const r = lim.tryAcquire(1000 + i);
      if (r.ok) apAccepted++;
      else { apDenied++; lastRa = r.retryAfterSec; }
    }
  }
  assert.equal(keyed, 20, 'anahtarli 20 istek sinirsiz');
  assert.equal(apAccepted, 6, 'anahtarsiz AP yolu: 60 sn icinde en cok 6');
  assert.equal(apDenied, 14);
  assert.ok(lastRa >= 1 && lastRa <= 60);
});

// ---------------------------------------------------------------------------------------------------------------
// JS portuna ozgu yardimcilar (firmware'de karsiligi yok): IPv4 <-> uint32
// ---------------------------------------------------------------------------------------------------------------
test('ap_access JS yardimcilari: ipToU32/u32ToIp gidis-donus; gecersiz metin 0', () => {
  assert.equal(ipToU32('192.168.4.1'), ipLE(192, 168, 4, 1));
  assert.equal(u32ToIp(ipLE(192, 168, 4, 77)), '192.168.4.77');
  assert.equal(u32ToIp(ipToU32('255.255.255.0')), '255.255.255.0');
  for (const bad of ['', 'abc', '1.2.3', '1.2.3.4.5', '256.1.1.1', null, undefined]) assert.equal(ipToU32(bad), 0, String(bad));
});
