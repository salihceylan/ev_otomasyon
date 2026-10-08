#pragma once
// ============================================================================
// NetLinkCore.h - "Ağ var mı / IP / arayüz" kararının SAF MANTIĞI (Wi-Fi STA + Ethernet W5500). Yalnız <stdint.h>;
// Arduino/FreeRTOS/IDF YOK -> PC'de (pio test -e native, test/test_net_link) sınanır. Bağlayıcı: NetLink.h/.cpp + EthLink.cpp.
//
// Plan K-Ş1 / İP-2.1 (docs/superpowers/plans/2026-10-08-site-sablon-kurulum.md), CONTRACTS §3e:
//  * MQTT kapısı, SNTP tetiği, kurtarma AP politikası ve durum "ip" alanları TEK yerden (Wi-Fi VEYA Ethernet) beslenir.
//  * Etkin arayüz: Wi-Fi bağlıysa "wifi" (IDF varsayılan rota önceliği: STA 100 > ETH 50), değilse Ethernet bağlıysa "eth", değilse "none".
//  * Ethernet "bağlı" = bağlantı (kablo/PHY link) VAR ve DHCP adresi alınmış. Kablo çekilince (LINK_DOWN) adres geçersiz sayılır.
//  * Ethernet hiç yoksa (kart W5500'süz / kablo takılı değil) bütün kararlar bugünkü Wi-Fi-only davranışla BİREBİR aynıdır
//    (testte sabitlenmiştir): ip = STA bağlıysa STA IP'si değilse AP IP'si (tam durum) / 0.0.0.0 (MQTT state).
//  * UID her zaman Wi-Fi MAC'inden (bu katman UID üretmez).
// IPv4 adresleri arduino-esp32 IPAddress -> uint32_t gösterimindedir (ilk sekizli en düşük bayt; esp_ip4_addr_t.addr ile aynı).
// ============================================================================
#include <stdint.h>

namespace netlink {

enum class NetIf : uint8_t { NONE = 0, WIFI = 1, ETH = 2 };

inline const char* netIfName(NetIf i) {
  switch (i) {
    case NetIf::WIFI: return "wifi";
    case NetIf::ETH: return "eth";
    default: return "none";
  }
}

// Ethernet sürücü olayları (ETH_EVENT_* ve IP_EVENT_ETH_*). Bağlayıcı IDF olaylarını buna çevirir.
enum class EthEvent : uint8_t { START, STOP, LINK_UP, LINK_DOWN, GOT_IP, LOST_IP };

struct EthState {
  bool present;     // sürücü kuruldu (W5500 yanıt verdi)
  bool started;
  bool link;        // PHY bağlantısı (kablo + karşı uç)
  bool hasIp;
  uint32_t ip;
  uint32_t mask;
  uint32_t gw;
  EthState() : present(false), started(false), link(false), hasIp(false), ip(0), mask(0), gw(0) {}
};

inline void ethClearIp(EthState& s) {
  s.hasIp = false;
  s.ip = s.mask = s.gw = 0;
}

// Olay -> durum geçişi. GOT_IP yalnız bağlantı varken anlamlıdır ama sıra (IP olayı link olayından önce işlenirse) bozulmasın diye
// adres saklanır; "bağlı" kararı ethUp()'tadır (link && hasIp && ip != 0).
inline void ethApply(EthState& s, EthEvent ev, uint32_t ip = 0, uint32_t mask = 0, uint32_t gw = 0) {
  switch (ev) {
    case EthEvent::START:
      s.present = true;
      s.started = true;
      break;
    case EthEvent::STOP:
      s.started = false;
      s.link = false;
      ethClearIp(s);
      break;
    case EthEvent::LINK_UP:
      s.link = true;
      break;
    case EthEvent::LINK_DOWN:
      s.link = false;
      ethClearIp(s);          // kablo çekildi: eski adres "bağlı" saydırmaz (DHCP yeniden bağlanınca GOT_IP gelir)
      break;
    case EthEvent::GOT_IP:
      if (ip == 0) {
        ethClearIp(s);
      } else {
        s.hasIp = true;
        s.ip = ip;
        s.mask = mask;
        s.gw = gw;
      }
      break;
    case EthEvent::LOST_IP:
      ethClearIp(s);
      break;
  }
}

inline bool ethUp(const EthState& s) { return s.started && s.link && s.hasIp && s.ip != 0; }

// Etkin arayüz (Wi-Fi öncelikli; IDF varsayılan rotasıyla aynı).
inline NetIf activeIf(bool wifiUp, bool ethIsUp) {
  if (wifiUp) return NetIf::WIFI;
  if (ethIsUp) return NetIf::ETH;
  return NetIf::NONE;
}

inline bool netUp(bool wifiUp, bool ethIsUp) { return wifiUp || ethIsUp; }

// Tam /api/status "ip": etkin arayüzün IP'si; ağ yoksa AP IP'si (bugünkü davranış: STA yoksa softAP IP'si).
inline uint32_t statusIp(bool wifiUp, uint32_t wifiIp, bool ethIsUp, uint32_t ethIp, uint32_t apIp) {
  switch (activeIf(wifiUp, ethIsUp)) {
    case NetIf::WIFI: return wifiIp;
    case NetIf::ETH: return ethIp;
    default: return apIp;
  }
}

// MQTT state "ip": etkin arayüzün IP'si; ağ yoksa 0.0.0.0 (bugün: STA IP'si, bağlı değilken 0).
inline uint32_t stateIp(bool wifiUp, uint32_t wifiIp, bool ethIsUp, uint32_t ethIp) {
  switch (activeIf(wifiUp, ethIsUp)) {
    case NetIf::WIFI: return wifiIp;
    case NetIf::ETH: return ethIp;
    default: return 0;
  }
}

// Kurtarma AP politikası girdisi "connected" (NetUtil::ApPolicy::In::connected): Ethernet bağlıyken de "bağlı" sayılır ->
// kurtarma penceresi açılmaz / kararlı bağlantıda kapanır (K-Ş1). Servis AP penceresi (AP ON) bundan bağımsızdır.
inline bool apPolicyConnected(bool wifiUp, bool ethIsUp) { return wifiUp || ethIsUp; }

// SNTP: herhangi bir arayüz adres aldığında istek bırakılır (pending); ağ varken bir kez başlatılır.
inline bool sntpDue(bool pending, bool wifiUp, bool ethIsUp) { return pending && netUp(wifiUp, ethIsUp); }

// MQTT görev kapısı: ağ yoksa bağlantı denenmez, yarım TLS soketi kapatılır.
inline bool mqttNetOk(bool wifiUp, bool ethIsUp) { return netUp(wifiUp, ethIsUp); }

// "a.b.c.d" (IPAddress gösterimi: ilk sekizli en düşük bayt). buf en az 16 bayt.
inline void ipToStr(uint32_t ip, char* buf, unsigned cap) {
  if (!buf || cap < 16) return;
  const uint8_t o[4] = {(uint8_t)(ip & 0xFF), (uint8_t)((ip >> 8) & 0xFF), (uint8_t)((ip >> 16) & 0xFF), (uint8_t)(ip >> 24)};
  unsigned n = 0;
  for (int k = 0; k < 4; k++) {
    uint8_t v = o[k];
    char t[3];
    int m = 0;
    do { t[m++] = (char)('0' + v % 10); v = (uint8_t)(v / 10); } while (v && m < 3);
    while (m) buf[n++] = t[--m];
    if (k < 3) buf[n++] = '.';
  }
  buf[n] = '\0';
}

}  // namespace netlink
