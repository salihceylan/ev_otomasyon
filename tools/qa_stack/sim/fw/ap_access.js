// ApAccess.h'nin (firmware, src/ApAccess.h) JavaScript portu: Wi-Fi servis akisi icin AP KAYNAKLI yetkilendirme karari (CONTRACTS 3d).
//
// GUVENLIK MODELI: cihaza ozel WPA2 AP parolasini (ap_pass) bilmek = fiziksel erisim. Teknisyen musterinin evinde panonun kurtarma
// agindayken INTERNET YOKTUR; yerel anahtari sunucudan alamaz. Bu yuzden YALNIZCA su uc uc -- GET /api/wifi/scan, POST /api/wifi/connect,
// GET /api/wifi/status -- X-Device-Key YERINE su uc kosulun HEPSIYLE de acilir:
//   (a) istemci SoftAP arayuzundedir (uzak IP softAP alt agindadir; STA alt agiyla CAKISMIYOR: belirsizlikte reddedilir),
//   (b) AP su an GERCEKTEN WPA2 korumalidir (acik kurulum AP'sinde bu yol KAPALI) ve cihazin gecerli ap_pass'i vardir,
//   (c) cihaz provizyonludur (local_key tanimli).
// Digerleri (role, cocuk kilidi, config, rs485, reboot/reset, mqtt/config, rekey, disconnect ...) yalniz gecerli X-Device-Key ile acilir.
//
// IPv4 adresleri firmware'deki "IPAddress -> uint32_t" gosteriminde verilir (ilk sekizli en dusuk bayt); maske AYNI gosterimde oldugu
// surece bayt sirasi onemsizdir (yalniz bit duzeyinde AND/esitlik). Hiz sinirlayici NetTime.h Wait ciftleridir (hedef zaman saklanmaz).
//
// Dogrulama: test/fw_ap_access.test.js (firmware test/test_ap_access/test_main.cpp'nin 15 Unity testinin birebir portu).
import { Wait, u32 } from './net_time.js';

/** "a.b.c.d" -> uint32 (ilk sekizli en dusuk bayt: arduino-esp32 IPAddress::operator uint32_t). Gecersiz metin -> 0. */
export function ipToU32(s) {
  const m = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(String(s ?? ''));
  if (!m) return 0;
  const p = m.slice(1).map(Number);
  if (p.some((x) => x > 255)) return 0;
  return u32(p[0] | (p[1] << 8) | (p[2] << 16) | (p[3] << 24));
}

/** uint32 (ilk sekizli en dusuk bayt) -> "a.b.c.d" */
export function u32ToIp(v) {
  const x = u32(v);
  return `${x & 255}.${(x >>> 8) & 255}.${(x >>> 16) & 255}.${(x >>> 24) & 255}`;
}

/** Ayni alt agda mi? (mask == 0 gecersiz: hicbir adres "ayni alt ag" sayilmaz.) */
export function sameSubnet(a, b, mask) {
  const m = u32(mask);
  return m !== 0 && u32(a & m) === u32(b & m);
}

/** Iki IPv4 alt agi kesisiyor mu? (maskeler bitisik varsayilir: AND = kisa on ek.) Her iki alt ag da tanimli olmali. */
export function subnetsOverlap(ipA, maskA, ipB, maskB) {
  if (u32(maskA) === 0 || u32(maskB) === 0) return false;
  const common = u32(maskA & maskB);
  return u32(ipA & common) === u32(ipB & common);
}

/**
 * (a) Istemci SoftAP arayuzunde mi?
 *  * AP yayinda olmali ve adres/maske gecerli olmali.
 *  * Uzak IP cihazin kendi AP adresi degil, AP alt agi icinde olmali.
 *  * STA bagliysa (staIp != 0) ve STA alt agi AP alt agiyla KESISIYORSA (or. ev modemi de 192.168.4.0/24) ag konumu AP/LAN ayirt ettirmez:
 *    istemci AP istemcisi SAYILMAZ (kapali basarisizlik). STA maskesi bilinmiyorsa (tutarsiz durum) STA adresinin AP alt aginda olmasi da
 *    ayni sonucu verir.
 *  * v1.3.0 (Ethernet; ApAccess.h 8 parametreli bicim): Ethernet bagliyken (ethIp != 0) Ethernet alt agi AP alt agiyla kesisiyorsa da istemci AP
 *    istemcisi SAYILMAZ (STA kuralinin aynisi). ethIp verilmezse (0) sonuc eskisiyle birebir aynidir.
 */
export function clientOnSoftAp(apActive, remoteIp, apIp, apMask, staIp, staMask, ethIp = 0, ethMask = 0) {
  if (!apActive) return false;
  if (u32(remoteIp) === 0 || u32(apIp) === 0 || u32(apMask) === 0) return false;
  if (u32(remoteIp) === u32(apIp)) return false;
  if (!sameSubnet(remoteIp, apIp, apMask)) return false;
  if (u32(staIp) !== 0) {
    const overlap = u32(staMask) !== 0 ? subnetsOverlap(staIp, staMask, apIp, apMask) : sameSubnet(staIp, apIp, apMask);
    if (overlap) return false;
  }
  if (u32(ethIp) !== 0) {
    const overlap = u32(ethMask) !== 0 ? subnetsOverlap(ethIp, ethMask, apIp, apMask) : sameSubnet(ethIp, apIp, apMask);
    if (overlap) return false;
  }
  return true;
}

/** AP kaynakli (anahtarsiz) yol: (a) ve (b) ve (c) HEPSI. Provizyonsuz cihazda hicbir kosulda acik degildir. */
export function apOrigin(clientOnAp, apIsWpa2, hasApPass, provisioned) {
  return !!(provisioned && hasApPass && apIsWpa2 && clientOnAp);
}

/** Erisimin NASIL verildigi (hiz siniri yalniz anahtarsiz AP yoluna uygulanir). */
export const VIA_DENIED = 0;
export const VIA_KEY = 1;
export const VIA_AP = 2;
export const Via = Object.freeze({ DENIED: VIA_DENIED, KEY: VIA_KEY, AP: VIA_AP });

/**
 * Karar: gecerli X-Device-Key HER kosulda (provizyonlu cihazda) izin verir; yoksa AP kaynakli yol.
 * Provizyonsuz cihazda (local_key yok) gecerli anahtar zaten var olamaz; imkansiz girdi birlesimi de REDDEDILIR
 * (kapali basarisizlik): hasValidKey=true ama provisioned=false -> VIA_DENIED.
 */
export function via(clientOnAp, apIsWpa2, hasApPass, provisioned, hasValidKey) {
  if (!provisioned) return VIA_DENIED;
  if (hasValidKey) return VIA_KEY;
  if (apOrigin(clientOnAp, apIsWpa2, hasApPass, provisioned)) return VIA_AP;
  return VIA_DENIED;
}

/** AP_OR_KEYED uclari icin izin karari (CONTRACTS 3d). */
export function allowed(clientOnAp, apIsWpa2, hasApPass, provisioned, hasValidKey) {
  return via(clientOnAp, apIsWpa2, hasApPass, provisioned, hasValidKey) !== VIA_DENIED;
}

// ---------------------------------------------------------------------------------------------------------------
// ConnectLimiter: AP kaynakli ANAHTARSIZ POST /api/wifi/connect icin GLOBAL hiz siniri (kayan pencere): herhangi bir 60 sn icinde en
// cok 6 istek. Her kabul edilen istek 60 sn'lik bir yuva tutar (Wait); yuvalar dolunca ret ve Retry-After = en erken bosalacak yuvanin
// kalan suresi (sn, yukari yuvarlanir, >= 1). Anahtarli (gecerli X-Device-Key) istekler bu sinirlayiciya GIRMEZ.
// ---------------------------------------------------------------------------------------------------------------
export class ConnectLimiter {
  static MAX_PER_WINDOW = 6;
  static WINDOW_MS = 60000;

  constructor() {
    this.slots = Array.from({ length: ConnectLimiter.MAX_PER_WINDOW }, () => new Wait());
  }

  /** Her tur: suresi dolan yuvalar sonlanir (49,7 gunluk sarmada eski damga "taze" gorunmez). */
  service(now) {
    for (const s of this.slots) s.service(now);
  }

  /** @returns {{ok:boolean, retryAfterSec:number}} ok: izin (bir yuva tuketildi). ok=false: sinir dolu; retryAfterSec >= 1. */
  tryAcquire(now) {
    this.service(now);
    for (const s of this.slots) {
      if (!s.armed) {
        s.arm(now, ConnectLimiter.WINDOW_MS);
        return { ok: true, retryAfterSec: 0 };
      }
    }
    let soonest = ConnectLimiter.WINDOW_MS;
    for (const s of this.slots) {
      const r = s.remaining(now);
      if (r < soonest) soonest = r;
    }
    let retryAfterSec = Math.floor((soonest + 999) / 1000);
    if (retryAfterSec === 0) retryAfterSec = 1;
    return { ok: false, retryAfterSec };
  }

  /** Su an tuketilmis (60 sn icinde kabul edilmis) istek sayisi. */
  used() {
    let n = 0;
    for (const s of this.slots) if (s.armed) n++;
    return n;
  }

  /** QA: tum yuvalar bosaltilir. */
  clear() {
    for (const s of this.slots) s.disarm();
  }
}
