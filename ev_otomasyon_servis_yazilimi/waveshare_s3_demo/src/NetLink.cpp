// NetLink.cpp - Wi-Fi + Ethernet birleşik bağlantı durumu (bkz. NetLink.h). Karar NetLinkCore.h'de.
#include "NetLink.h"
#include "WiFiManager.h"
#include <string.h>
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>
#include <esp_netif.h>
#include <lwip/dns.h>
#include <lwip/ip_addr.h>
#include <stdio.h>

namespace {
portMUX_TYPE s_mux = portMUX_INITIALIZER_UNLOCKED;
netlink::EthState s_eth;   // yalnız s_mux altında
netlink::DnsInfo s_dnsWifi, s_dnsEth;   // yalnız s_mux altında
volatile bool s_dnsDirty = false;
netlink::NetIf s_dnsApplied = netlink::NetIf::NONE;   // yalnız wifi_task

uint32_t dnsServer(uint8_t i) {
  const ip_addr_t* a = dns_getserver(i);
  if (!a || !IP_IS_V4(a)) return 0;
  return ip_2_ip4(a)->addr;
}

void setDns(esp_netif_dns_type_t type, uint32_t addr) {
  if (addr == 0) return;
  esp_netif_t* nif = esp_netif_get_handle_from_ifkey("WIFI_STA_DEF");
  if (!nif) nif = esp_netif_get_handle_from_ifkey("ETH_DEF");
  if (!nif) return;
  esp_netif_dns_info_t info;
  memset(&info, 0, sizeof(info));
  info.ip.type = ESP_IPADDR_TYPE_V4;
  info.ip.u_addr.ip4.addr = addr;
  esp_netif_set_dns_info(nif, type, &info);   // istemci arayüzünde lwIP genel DNS'ini yazar
}
}  // namespace

void NetLink::captureDns(netlink::NetIf which) {
  netlink::DnsInfo d;
  d.main = dnsServer(0);
  d.backup = dnsServer(1);
  taskENTER_CRITICAL(&s_mux);
  if (which == netlink::NetIf::WIFI) s_dnsWifi = d;
  else if (which == netlink::NetIf::ETH) s_dnsEth = d;
  taskEXIT_CRITICAL(&s_mux);
  s_dnsDirty = true;
}

void NetLink::serviceDns(bool wifiUp) {
  const netlink::NetIf active = netlink::activeIf(wifiUp, ethUp());
  taskENTER_CRITICAL(&s_mux);
  const netlink::DnsInfo d = (active == netlink::NetIf::WIFI) ? s_dnsWifi : s_dnsEth;
  taskEXIT_CRITICAL(&s_mux);
  const bool dirty = s_dnsDirty;
  if (!netlink::dnsShouldApply(s_dnsApplied, active, dirty, d)) {
    if (active == netlink::NetIf::NONE) s_dnsApplied = netlink::NetIf::NONE;
    return;
  }
  s_dnsDirty = false;
  setDns(ESP_NETIF_DNS_MAIN, d.main);
  setDns(ESP_NETIF_DNS_BACKUP, d.backup);
  if (active != s_dnsApplied) {
    char a[16];
    netlink::ipToStr(d.main, a, sizeof(a));
    printf("[AG] Etkin arayuz %s, DNS %s\r\n", netlink::netIfName(active), a);
  }
  s_dnsApplied = active;
}

void NetLink::ethEvent(netlink::EthEvent ev, uint32_t ip, uint32_t mask, uint32_t gw) {
  taskENTER_CRITICAL(&s_mux);
  netlink::ethApply(s_eth, ev, ip, mask, gw);
  taskEXIT_CRITICAL(&s_mux);
}

netlink::EthState NetLink::eth() {
  taskENTER_CRITICAL(&s_mux);
  const netlink::EthState c = s_eth;
  taskEXIT_CRITICAL(&s_mux);
  return c;
}

bool NetLink::ethUp() { return netlink::ethUp(eth()); }

NetLink::Snapshot NetLink::snapshot() {
  Snapshot s;
  WiFiManager& wm = WiFiManager::instance();
  s.wifiUp = wm.isConnected();
  s.wifiIp = s.wifiUp ? (uint32_t)wm.getLocalIP() : 0u;
  const netlink::EthState e = eth();
  s.ethUp = netlink::ethUp(e);
  s.ethIp = s.ethUp ? e.ip : 0u;
  s.ethMask = s.ethUp ? e.mask : 0u;
  s.ethPresent = e.present;
  s.ethLink = e.link;
  s.active = netlink::activeIf(s.wifiUp, s.ethUp);
  return s;
}

bool NetLink::up() { return netlink::netUp(WiFiManager::instance().isConnected(), ethUp()); }
