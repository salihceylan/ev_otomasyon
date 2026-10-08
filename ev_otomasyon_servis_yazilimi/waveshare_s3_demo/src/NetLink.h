#pragma once
// ============================================================================
// NetLink.h - "Ağ var mı / IP / arayüz" sorusunun TEK cevap noktası (Wi-Fi STA + Ethernet W5500). BAĞLAYICI: karar NetLinkCore.h'dedir
// (saf, test/test_net_link). v1.3.0 İP-2.1 (K-Ş1, CONTRACTS §3e).
//
// Tüketiciler: MqttManager (bağlantı kapısı + state "ip"/"eth_*"/"net_if"), WiFiManager (SNTP tetiği, kurtarma AP politikası),
// WebPortal (tam durum "ip"/"eth_*"/"net_if"), seri STATUS ("Ethernet:" satırı).
//  * Ethernet durumu EthLink'in olay işleyicilerinden (sys_evt görevi) ethEvent() ile güncellenir; okuyucular kritik bölge altında KOPYA alır.
//  * Wi-Fi durumu WiFiManager'dandır (bu sınıf saklamaz). Ethernet yokken bütün cevaplar bugünkü Wi-Fi-only davranışla aynıdır.
//  * Cihaz kimliği (UID) Wi-Fi MAC'inden kalır (WiFiManager::getDeviceUid); Ethernet MAC'i yalnız W5500'e yazılır.
// ============================================================================
#include <stdint.h>
#include "NetLinkCore.h"

class NetLink {
public:
  struct Snapshot {
    bool wifiUp;
    uint32_t wifiIp;
    bool ethUp;
    uint32_t ethIp;
    uint32_t ethMask;
    bool ethPresent;     // W5500 sürücüsü kuruldu
    bool ethLink;        // kablo/PHY bağlantısı
    netlink::NetIf active;
  };

  // EthLink olay işleyicisi (herhangi bir görev).
  static void ethEvent(netlink::EthEvent ev, uint32_t ip = 0, uint32_t mask = 0, uint32_t gw = 0);
  static netlink::EthState eth();          // kopya
  static bool ethUp();                     // Ethernet bağlı + DHCP adresi var
  static Snapshot snapshot();              // Wi-Fi (WiFiManager) + Ethernet birlikte
  static bool up();                        // Wi-Fi VEYA Ethernet

  // DNS (inceleme R1-4): lwIP DNS'i geneldir; son kira alan arayüz ezer. GOT_IP olayında (DHCP'nin DNS'i yazdığı an) o arayüzün DNS'i
  // saklanır; wifi_task her tur serviceDns() ile etkin arayüzün DNS'ini (değiştiyse / yeni kira geldiyse) yeniden yazar.
  static void captureDns(netlink::NetIf which);
  static void serviceDns(bool wifiUp);
};
