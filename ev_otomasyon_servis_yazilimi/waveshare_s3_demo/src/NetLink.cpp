// NetLink.cpp - Wi-Fi + Ethernet birleşik bağlantı durumu (bkz. NetLink.h). Karar NetLinkCore.h'de.
#include "NetLink.h"
#include "WiFiManager.h"
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>

namespace {
portMUX_TYPE s_mux = portMUX_INITIALIZER_UNLOCKED;
netlink::EthState s_eth;   // yalnız s_mux altında
}  // namespace

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
