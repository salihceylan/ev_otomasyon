#pragma once
// ============================================================================
// ApAccess.h - Wi-Fi servis akışı için AP KAYNAKLI yetkilendirme kararı (WebPortal).
// SAF MANTIK: yalnız <stdint.h> + NetTime.h; Arduino/WiFi/FreeRTOS yok -> PC'de (pio test -e native) ve wasm32
// simülasyonunda (test/test_ap_access) çalışır. WebPortal.cpp yalnızca girdileri toplar ve bu kararı uygular.
//
// GÜVENLİK MODELİ (docs/CONTRACTS.md 3d): cihaza özel WPA2 AP parolasını (ap_pass) bilmek = fiziksel erişim.
// Teknisyen müşterinin evinde panonun kurtarma ağındayken İNTERNET YOKTUR; yerel anahtarı (local_key) sunucudan
// alamaz. Bu yüzden YALNIZCA şu üç uç, X-Device-Key YERİNE şu üç koşulun HEPSİ ile de açılır:
//   GET /api/wifi/scan, POST /api/wifi/connect, GET /api/wifi/status
//   (a) istemci SoftAP arayüzündedir: uzak IP, softAP alt ağındadır (L2 komşusu: TCP el sıkışması AP arayüzünden
//       döner, uzaktan/sahte kaynak adresiyle tamamlanamaz) ve STA alt ağıyla ÇAKIŞMIYOR (belirsizlikte reddedilir),
//   (b) AP şu an GERÇEKTEN WPA2 korumalıdır (açık kurulum AP'sinde bu yol KAPALI) ve cihazın geçerli ap_pass'i vardır,
//   (c) cihaz provizyonludur (local_key tanımlı).
// Bunun dışındaki HER uç (röle, çocuk kilidi, config, rs485, reboot/reset, mqtt/config, rekey, disconnect...) yalnızca
// geçerli X-Device-Key ile açılır. Host allow-list, Origin==Host, CORS-yok ve Content-Type kuralları AYNEN geçerlidir.
//
// ZAMAN KURALI (CONTRACTS 3c): hız sınırlayıcı "son olay + bekleme" çiftleridir (NetUtil::Wait); web görevi her turda
// service() çağırır. Saklanmış hedef zaman + işaretli karşılaştırma YOKTUR.
// ============================================================================
#include <stdint.h>
#include "NetTime.h"

namespace ApAccess {

// IPv4 adresleri "IPAddress -> uint32_t" gösteriminde verilir (ilk sekizli en düşük bayt; arduino-esp32'de
// s_addr ile aynı). Maske AYNI gösterimde olduğu sürece sıra önemsizdir: yalnız bit düzeyinde AND/eşitlik yapılır
// (test: bayt sırası ters gösterimde de aynı sonuç).

// Aynı alt ağda mı? (mask == 0 geçersiz: hiçbir adres "aynı alt ağ" sayılmaz.)
inline bool sameSubnet(uint32_t a, uint32_t b, uint32_t mask) {
  return mask != 0u && (a & mask) == (b & mask);
}

// İki IPv4 alt ağı kesişiyor mu? (maskeler bitişik varsayılır: AND = kısa ön ek.) Her iki alt ağ da tanımlı olmalıdır.
inline bool subnetsOverlap(uint32_t ipA, uint32_t maskA, uint32_t ipB, uint32_t maskB) {
  if (maskA == 0u || maskB == 0u) return false;
  const uint32_t common = maskA & maskB;
  return (ipA & common) == (ipB & common);
}

// (a) İstemci SoftAP arayüzünde mi?
//  * AP yayında olmalı ve adres/maske geçerli olmalı.
//  * Uzak IP cihazın kendi AP adresi değil, AP alt ağında olmalı.
//  * STA bağlıysa (staIp != 0) ve STA alt ağı AP alt ağıyla KESİŞİYORSA (ör. ev modemi de 192.168.4.0/24)
//    ağ konumu AP/LAN ayırt ettirmez: istemci AP istemcisi SAYILMAZ (kapalı başarısızlık). STA maskesi bilinmiyorsa
//    (tutarsız durum) STA adresinin AP alt ağında olması da aynı sonucu verir.
inline bool clientOnSoftAp(bool apActive, uint32_t remoteIp, uint32_t apIp, uint32_t apMask, uint32_t staIp,
                           uint32_t staMask) {
  if (!apActive) return false;
  if (remoteIp == 0u || apIp == 0u || apMask == 0u) return false;
  if (remoteIp == apIp) return false;
  if (!sameSubnet(remoteIp, apIp, apMask)) return false;
  if (staIp != 0u) {
    const bool overlap = (staMask != 0u) ? subnetsOverlap(staIp, staMask, apIp, apMask) : sameSubnet(staIp, apIp, apMask);
    if (overlap) return false;
  }
  return true;
}

// v1.3.0 (Ethernet, K-Ş1): Ethernet bağlıyken (ethIp != 0) Ethernet alt ağı AP alt ağıyla kesişiyorsa da (LAN 192.168.4.0/24) istemcinin
// AP'de olduğu ağ konumundan anlaşılamaz -> AP istemcisi SAYILMAZ (STA kuralının aynısı; kapalı başarısızlık). Ethernet yoksa (ethIp = 0)
// sonuç clientOnSoftAp ile birebir aynıdır.
inline bool clientOnSoftAp(bool apActive, uint32_t remoteIp, uint32_t apIp, uint32_t apMask, uint32_t staIp, uint32_t staMask,
                           uint32_t ethIp, uint32_t ethMask) {
  if (!clientOnSoftAp(apActive, remoteIp, apIp, apMask, staIp, staMask)) return false;
  if (ethIp != 0u) {
    const bool overlap = (ethMask != 0u) ? subnetsOverlap(ethIp, ethMask, apIp, apMask) : sameSubnet(ethIp, apIp, apMask);
    if (overlap) return false;
  }
  return true;
}

// AP kaynaklı (anahtarsız) yol: (a) ve (b) ve (c) HEPSİ. Provizyonsuz cihazda hiçbir koşulda açık değildir.
inline bool apOrigin(bool clientOnAp, bool apIsWpa2, bool hasApPass, bool provisioned) {
  return provisioned && hasApPass && apIsWpa2 && clientOnAp;
}

// Erişimin NASIL verildiği (hız sınırı yalnız anahtarsız AP yoluna uygulanır).
enum Via : uint8_t { VIA_DENIED = 0, VIA_KEY = 1, VIA_AP = 2 };

// Karar: geçerli X-Device-Key HER koşulda (provizyonlu cihazda) izin verir; yoksa AP kaynaklı yol.
// Provizyonsuz cihazda (local_key yok) geçerli anahtar zaten var olamaz; imkânsız girdi birleşimi de REDDEDİLİR
// (kapalı başarısızlık): hasValidKey=true ama provisioned=false -> VIA_DENIED.
inline Via via(bool clientOnAp, bool apIsWpa2, bool hasApPass, bool provisioned, bool hasValidKey) {
  if (!provisioned) return VIA_DENIED;
  if (hasValidKey) return VIA_KEY;
  if (apOrigin(clientOnAp, apIsWpa2, hasApPass, provisioned)) return VIA_AP;
  return VIA_DENIED;
}

// AP_OR_KEYED uçları için izin kararı (CONTRACTS 3d).
inline bool allowed(bool clientOnAp, bool apIsWpa2, bool hasApPass, bool provisioned, bool hasValidKey) {
  return via(clientOnAp, apIsWpa2, hasApPass, provisioned, hasValidKey) != VIA_DENIED;
}

// ---------------------------------------------------------------------------------------------------------------
// ConnectLimiter: AP kaynaklı ANAHTARSIZ POST /api/wifi/connect için GLOBAL hız sınırı (kayan pencere):
// herhangi bir 60 sn içinde en çok 6 istek. Her kabul edilen istek 60 sn'lik bir yuva tutar (NetUtil::Wait);
// yuvalar dolunca ret ve Retry-After = en erken boşalacak yuvanın kalan süresi (sn, yukarı yuvarlanır, >= 1).
// Anahtarlı (geçerli X-Device-Key) istekler bu sınırlayıcıya GİRMEZ. Yalnız web görevinden kullanılır.
// ---------------------------------------------------------------------------------------------------------------
struct ConnectLimiter {
  enum : uint32_t { MAX_PER_WINDOW = 6, WINDOW_MS = 60000 };

  NetUtil::Wait slots[MAX_PER_WINDOW];

  // Her tur: süresi dolan yuvalar sonlanır (49,7 günlük sarmada eski damga "taze" görünmez).
  void service(uint32_t now) {
    for (uint32_t i = 0; i < MAX_PER_WINDOW; i++) slots[i].service(now);
  }

  // true: izin (bir yuva tüketildi). false: sınır dolu; retryAfterSec >= 1.
  bool tryAcquire(uint32_t now, uint32_t& retryAfterSec) {
    service(now);
    for (uint32_t i = 0; i < MAX_PER_WINDOW; i++) {
      if (!slots[i].armed) {
        slots[i].arm(now, WINDOW_MS);
        return true;
      }
    }
    uint32_t soonest = WINDOW_MS;
    for (uint32_t i = 0; i < MAX_PER_WINDOW; i++) {
      const uint32_t r = slots[i].remaining(now);
      if (r < soonest) soonest = r;
    }
    retryAfterSec = (soonest + 999u) / 1000u;
    if (retryAfterSec == 0u) retryAfterSec = 1u;
    return false;
  }

  // Şu an tüketilmiş (60 sn içinde kabul edilmiş) istek sayısı.
  uint32_t used() const {
    uint32_t n = 0;
    for (uint32_t i = 0; i < MAX_PER_WINDOW; i++) {
      if (slots[i].armed) n++;
    }
    return n;
  }
};

}  // namespace ApAccess
