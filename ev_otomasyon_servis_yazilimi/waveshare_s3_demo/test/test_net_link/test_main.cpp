// ============================================================================
// NetLinkCore (src/NetLinkCore.h) birim testleri:  pio test -e native -f test_net_link
//
// v1.3.0 İP-2.1 (K-Ş1): "ağ var mı / IP / arayüz" kararı Wi-Fi + Ethernet için tek yerden verilir. Bu testler
//   * Ethernet YOKKEN (kablo takılı değil / W5500 yanıt vermedi) her kararın bugünkü Wi-Fi-only davranışla aynı olduğunu,
//   * Ethernet olay geçişlerini (link, DHCP, kablo çekme, sıra dışı olaylar),
//   * etkin arayüz önceliğini (Wi-Fi > Ethernet), MQTT kapısı, SNTP tetiği ve kurtarma AP politikası girdisini,
//   * ApAccess'in Ethernet alt ağı çakışma kuralını doğrular.
// ============================================================================
#include <unity.h>
#include <stdint.h>
#include <string.h>
#include "NetLinkCore.h"
#include "ApAccess.h"
#include "NetTime.h"

using namespace netlink;

void setUp(void) {}
void tearDown(void) {}

namespace {
uint32_t ip(uint8_t a, uint8_t b, uint8_t c, uint8_t d) {
  return (uint32_t)a | ((uint32_t)b << 8) | ((uint32_t)c << 16) | ((uint32_t)d << 24);
}
const uint32_t MASK24 = 0x00FFFFFFu;   // 255.255.255.0 (IPAddress gösterimi)
}  // namespace

void test_without_ethernet_every_decision_equals_wifi_only_behavior() {
  const EthState none;   // sürücü yok / hiç olay gelmedi
  TEST_ASSERT_FALSE(ethUp(none));
  const uint32_t sta = ip(192, 168, 1, 20), ap = ip(192, 168, 4, 1);
  for (int w = 0; w < 2; w++) {
    const bool wifi = w == 1;
    TEST_ASSERT_EQUAL(wifi, netUp(wifi, ethUp(none)));
    TEST_ASSERT_EQUAL(wifi, mqttNetOk(wifi, ethUp(none)));
    TEST_ASSERT_FALSE(apPolicyEthUp(ethUp(none), true));
    TEST_ASSERT_FALSE(apPolicyEthUp(ethUp(none), false));
    TEST_ASSERT_EQUAL(wifi, sntpDue(true, wifi, ethUp(none)));
    TEST_ASSERT_FALSE(sntpDue(false, wifi, ethUp(none)));
    // tam durum: eski kural "staConnected ? staIp : apIp"
    TEST_ASSERT_EQUAL_UINT(wifi ? sta : ap, statusIp(wifi, sta, ethUp(none), 0, ap));
    // MQTT state: eski kural WiFiManager::getLocalIP() (bağlı değilken 0.0.0.0)
    TEST_ASSERT_EQUAL_UINT(wifi ? sta : 0u, stateIp(wifi, wifi ? sta : 0u, ethUp(none), 0));
    TEST_ASSERT_EQUAL_STRING(wifi ? "wifi" : "none", netIfName(activeIf(wifi, ethUp(none))));
  }
}

// Kullanıcı kararı (2026-10-08): kablolu Ethernet'ten gelen istek anahtarsız ve provizyonsuz yetkilidir. Ölçüt: bağlantının
// panodaki yerel ucu Ethernet IP'si mi (Wi-Fi STA / SoftAP'ten gelenler etkilenmez).
void test_request_arrived_via_ethernet_only_when_local_ip_is_the_eth_ip() {
  const EthState none;
  TEST_ASSERT_FALSE(requestViaEth(none, ip(192, 168, 1, 57)));
  TEST_ASSERT_FALSE(requestViaEth(none, 0));
  EthState s;
  ethApply(s, EthEvent::START);
  ethApply(s, EthEvent::LINK_UP);
  s.hasIp = true; s.ip = ip(192, 168, 10, 57); s.mask = ip(255, 255, 255, 0);
  TEST_ASSERT_TRUE(requestViaEth(s, ip(192, 168, 10, 57)));    // istek Ethernet arayüzüne geldi
  TEST_ASSERT_FALSE(requestViaEth(s, ip(192, 168, 1, 20)));    // Wi-Fi STA IP'sine geldi
  TEST_ASSERT_FALSE(requestViaEth(s, ip(192, 168, 4, 1)));     // SoftAP'e geldi
  TEST_ASSERT_FALSE(requestViaEth(s, 0));
  ethApply(s, EthEvent::LINK_DOWN);                              // kablo çekildi: artık Ethernet yolu yok
  TEST_ASSERT_FALSE(requestViaEth(s, ip(192, 168, 10, 57)));
}

void test_cable_not_plugged_driver_started_is_not_up() {
  EthState s;
  ethApply(s, EthEvent::START);
  TEST_ASSERT_TRUE(s.present);
  TEST_ASSERT_FALSE(ethUp(s));
  TEST_ASSERT_FALSE(netUp(false, ethUp(s)));
  TEST_ASSERT_EQUAL_UINT(ip(192, 168, 4, 1), statusIp(false, 0, ethUp(s), s.ip, ip(192, 168, 4, 1)));
}

void test_link_then_dhcp_brings_ethernet_up_and_cable_pull_takes_it_down() {
  EthState s;
  ethApply(s, EthEvent::START);
  ethApply(s, EthEvent::LINK_UP);
  TEST_ASSERT_FALSE(ethUp(s));                 // DHCP henüz yok
  ethApply(s, EthEvent::GOT_IP, ip(10, 0, 0, 7), MASK24, ip(10, 0, 0, 1));
  TEST_ASSERT_TRUE(ethUp(s));
  TEST_ASSERT_TRUE(netUp(false, ethUp(s)));
  TEST_ASSERT_TRUE(apPolicyEthUp(ethUp(s), true));    // provizyonlu + Ethernet bağlı: kurtarma AP'si açılmaz
  TEST_ASSERT_FALSE(apPolicyEthUp(ethUp(s), false));  // provizyonsuz: kurulum AP'si Ethernet varken de açılır
  TEST_ASSERT_TRUE(mqttNetOk(false, ethUp(s)));
  TEST_ASSERT_TRUE(sntpDue(true, false, ethUp(s)));
  TEST_ASSERT_EQUAL_UINT(ip(10, 0, 0, 7), statusIp(false, 0, ethUp(s), s.ip, ip(192, 168, 4, 1)));
  TEST_ASSERT_EQUAL_UINT(ip(10, 0, 0, 7), stateIp(false, 0, ethUp(s), s.ip));
  TEST_ASSERT_EQUAL_STRING("eth", netIfName(activeIf(false, ethUp(s))));
  // kablo çekildi
  ethApply(s, EthEvent::LINK_DOWN);
  TEST_ASSERT_FALSE(ethUp(s));
  TEST_ASSERT_EQUAL_UINT(0, s.ip);
  TEST_ASSERT_FALSE(apPolicyEthUp(ethUp(s), true));
  // yeniden takıldı: link tek başına yetmez, yeni DHCP adresi gerekir
  ethApply(s, EthEvent::LINK_UP);
  TEST_ASSERT_FALSE(ethUp(s));
  ethApply(s, EthEvent::GOT_IP, ip(10, 0, 0, 8), MASK24, ip(10, 0, 0, 1));
  TEST_ASSERT_TRUE(ethUp(s));
  ethApply(s, EthEvent::LOST_IP);
  TEST_ASSERT_FALSE(ethUp(s));
  ethApply(s, EthEvent::GOT_IP, ip(10, 0, 0, 8), MASK24, 0);
  ethApply(s, EthEvent::STOP);
  TEST_ASSERT_FALSE(ethUp(s));
  TEST_ASSERT_FALSE(s.link);
}

void test_out_of_order_ip_before_link_and_zero_ip() {
  EthState s;
  ethApply(s, EthEvent::START);
  ethApply(s, EthEvent::GOT_IP, ip(10, 1, 1, 5), MASK24, 0);
  TEST_ASSERT_FALSE(ethUp(s));                 // link olayı henüz işlenmedi
  ethApply(s, EthEvent::LINK_UP);
  TEST_ASSERT_TRUE(ethUp(s));
  ethApply(s, EthEvent::GOT_IP, 0, 0, 0);      // 0.0.0.0 adresi "bağlı" saydırmaz
  TEST_ASSERT_FALSE(ethUp(s));
  EthState notStarted;
  ethApply(notStarted, EthEvent::LINK_UP);
  ethApply(notStarted, EthEvent::GOT_IP, ip(10, 1, 1, 5), MASK24, 0);
  TEST_ASSERT_FALSE(ethUp(notStarted));        // sürücü başlamadan gelen olay (imkânsız) bağlı saydırmaz
}

void test_wifi_has_priority_when_both_are_up() {
  const uint32_t sta = ip(192, 168, 1, 20), eth = ip(10, 0, 0, 7), ap = ip(192, 168, 4, 1);
  TEST_ASSERT_EQUAL_STRING("wifi", netIfName(activeIf(true, true)));
  TEST_ASSERT_EQUAL_UINT(sta, statusIp(true, sta, true, eth, ap));
  TEST_ASSERT_EQUAL_UINT(sta, stateIp(true, sta, true, eth));
  // Wi-Fi koptu, Ethernet sürüyor: ağ var (MQTT bağlı kalabilir, AP açılmaz)
  TEST_ASSERT_TRUE(netUp(false, true));
  TEST_ASSERT_EQUAL_UINT(eth, statusIp(false, 0, true, eth, ap));
  TEST_ASSERT_EQUAL_STRING("none", netIfName(activeIf(false, false)));
}

void test_ip_to_string() {
  char b[16];
  ipToStr(ip(192, 168, 4, 1), b, sizeof(b));
  TEST_ASSERT_EQUAL_STRING("192.168.4.1", b);
  ipToStr(0, b, sizeof(b));
  TEST_ASSERT_EQUAL_STRING("0.0.0.0", b);
  ipToStr(ip(255, 255, 255, 255), b, sizeof(b));
  TEST_ASSERT_EQUAL_STRING("255.255.255.255", b);
  ipToStr(ip(10, 0, 100, 9), b, sizeof(b));
  TEST_ASSERT_EQUAL_STRING("10.0.100.9", b);
}

void test_ap_access_ethernet_subnet_overlap_closes_ap_origin() {
  const uint32_t apIp = ip(192, 168, 4, 1), client = ip(192, 168, 4, 2);
  // Ethernet yok: eski karar ile aynı
  TEST_ASSERT_TRUE(ApAccess::clientOnSoftAp(true, client, apIp, MASK24, 0, 0, 0, 0));
  TEST_ASSERT_EQUAL(ApAccess::clientOnSoftAp(true, client, apIp, MASK24, 0, 0),
                    ApAccess::clientOnSoftAp(true, client, apIp, MASK24, 0, 0, 0, 0));
  // Ethernet başka alt ağda: AP istemcisi
  TEST_ASSERT_TRUE(ApAccess::clientOnSoftAp(true, client, apIp, MASK24, 0, 0, ip(10, 0, 0, 7), MASK24));
  // Ethernet LAN'ı da 192.168.4.0/24: ayırt edilemez -> AP istemcisi sayılmaz
  TEST_ASSERT_FALSE(ApAccess::clientOnSoftAp(true, client, apIp, MASK24, 0, 0, ip(192, 168, 4, 50), MASK24));
  // geniş Ethernet maskesi (192.168.0.0/16) AP alt ağını kapsıyor
  TEST_ASSERT_FALSE(ApAccess::clientOnSoftAp(true, client, apIp, MASK24, 0, 0, ip(192, 168, 9, 3), 0x0000FFFFu));
  // maske bilinmiyor ama adres AP alt ağında
  TEST_ASSERT_FALSE(ApAccess::clientOnSoftAp(true, client, apIp, MASK24, 0, 0, ip(192, 168, 4, 50), 0));
  // STA kuralı aynen geçerli
  TEST_ASSERT_FALSE(ApAccess::clientOnSoftAp(true, client, apIp, MASK24, ip(192, 168, 4, 9), MASK24, 0, 0));
}

void test_mqtt_reconnects_when_active_interface_changes() {
  TEST_ASSERT_FALSE(mqttIfChanged(NetIf::NONE, NetIf::WIFI));    // bağlantı yokken değişim yok
  TEST_ASSERT_FALSE(mqttIfChanged(NetIf::WIFI, NetIf::WIFI));
  TEST_ASSERT_TRUE(mqttIfChanged(NetIf::ETH, NetIf::WIFI));      // Ethernet'le bağlıyken Wi-Fi geldi (varsayılan rota Wi-Fi)
  TEST_ASSERT_TRUE(mqttIfChanged(NetIf::WIFI, NetIf::ETH));      // Wi-Fi koptu, Ethernet sürüyor
  TEST_ASSERT_FALSE(mqttIfChanged(NetIf::WIFI, NetIf::NONE));    // ağ tamamen yok: karar mqttNetOk'ta
}

void test_dns_applied_on_switch_or_new_lease_only_when_known() {
  DnsInfo wifiDns, none;
  wifiDns.main = ip(192, 168, 1, 1);
  TEST_ASSERT_TRUE(dnsShouldApply(NetIf::NONE, NetIf::WIFI, false, wifiDns));   // ilk etkin arayüz
  TEST_ASSERT_FALSE(dnsShouldApply(NetIf::WIFI, NetIf::WIFI, false, wifiDns));  // değişiklik yok
  TEST_ASSERT_TRUE(dnsShouldApply(NetIf::WIFI, NetIf::WIFI, true, wifiDns));    // başka arayüz kira aldı: genel DNS'i ezmiş olabilir
  TEST_ASSERT_TRUE(dnsShouldApply(NetIf::ETH, NetIf::WIFI, false, wifiDns));    // arayüz değişti
  TEST_ASSERT_FALSE(dnsShouldApply(NetIf::ETH, NetIf::WIFI, true, none));       // DNS bilinmiyor: dokunma
  TEST_ASSERT_FALSE(dnsShouldApply(NetIf::WIFI, NetIf::NONE, true, wifiDns));   // ağ yok
}

// ---- Kurtarma AP penceresi + Ethernet (NetUtil::ApPolicy, v1.3.0 düzeltmesi) ----
namespace {
struct ApSim {
  NetUtil::ApPolicy p;
  NetUtil::ApPolicy::In in;
  bool apOn;
  uint32_t opens;
  uint32_t onMs;
  ApSim(bool allowed, bool staConfigured) : apOn(false), opens(0), onMs(0) {
    in.allowed = allowed;
    in.staConfigured = staConfigured;
  }
  // [t0, t1) aralığını 250 ms adımla (wifi_task gibi) yürütür.
  void run(uint32_t t0, uint32_t t1) {
    for (uint32_t t = t0; t < t1; t += 250) {
      in.apActive = apOn;
      const NetUtil::ApPolicy::Out o = p.update(t, in);
      if (o.opened) opens++;
      if (o.startAp) apOn = true;
      if (o.stopAp) apOn = false;
      if (apOn) onMs += 250;
    }
  }
};
const uint32_t MIN = 60000;
}  // namespace

void test_provisioned_ethernet_only_board_never_cycles_the_ap() {
  ApSim a(true, false);                  // provizyonlu (ap_pass var), kayıtlı Wi-Fi YOK
  a.in.ethUp = apPolicyEthUp(true, true);
  a.run(0, 180 * MIN);                   // 3 saat
  TEST_ASSERT_EQUAL_UINT(0, a.opens);
  TEST_ASSERT_EQUAL_UINT(0, a.onMs);
  TEST_ASSERT_FALSE(a.apOn);
}

void test_provisioned_board_with_saved_wifi_down_but_ethernet_up_does_not_trigger() {
  ApSim a(true, true);                   // kayıtlı Wi-Fi var ama bağlanamıyor, Ethernet bağlı
  a.in.connected = false;
  a.in.ethUp = apPolicyEthUp(true, true);
  a.run(0, 120 * MIN);
  TEST_ASSERT_EQUAL_UINT(0, a.opens);
}

void test_without_ethernet_no_saved_wifi_still_opens_and_cycles_as_v121() {
  ApSim a(true, false);
  a.run(0, 60 * MIN);
  TEST_ASSERT_TRUE(a.opens >= 2);        // 10 dk açık / 15 dk kapalı döngüsü (Ethernet yokken değişmedi)
}

void test_unprovisioned_board_opens_setup_ap_with_cable_plugged() {
  ApSim a(true, false);                  // provizyonsuz: allowed (açık kurulum AP'si)
  a.in.ethUp = apPolicyEthUp(true, false);
  TEST_ASSERT_FALSE(a.in.ethUp);
  a.run(0, 1000);
  TEST_ASSERT_TRUE(a.apOn);
  TEST_ASSERT_EQUAL_UINT(1, a.opens);
}

void test_open_window_closes_early_when_ethernet_comes_up_on_provisioned_board() {
  ApSim a(true, false);
  a.run(0, 2000);
  TEST_ASSERT_TRUE(a.apOn);
  a.in.ethUp = apPolicyEthUp(true, true);
  a.run(2000, 2000 + 29000);
  TEST_ASSERT_TRUE(a.apOn);              // 30 sn kararlılık dolmadı
  a.run(31000, 31000 + 2000);
  TEST_ASSERT_FALSE(a.apOn);             // kararlı: pencere erken kapandı
  a.run(33000, 33000 + 90 * MIN);
  TEST_ASSERT_FALSE(a.apOn);             // ve yeniden açılmadı
  // kablo çekildi: kayıtlı Wi-Fi yok -> pencere yeniden açılır
  a.in.ethUp = false;
  const uint32_t t = 33000 + 90 * MIN;
  a.run(t, t + 2000);
  TEST_ASSERT_TRUE(a.apOn);
}

int main(int, char**) {
  UNITY_BEGIN();
  RUN_TEST(test_without_ethernet_every_decision_equals_wifi_only_behavior);
  RUN_TEST(test_request_arrived_via_ethernet_only_when_local_ip_is_the_eth_ip);
  RUN_TEST(test_cable_not_plugged_driver_started_is_not_up);
  RUN_TEST(test_link_then_dhcp_brings_ethernet_up_and_cable_pull_takes_it_down);
  RUN_TEST(test_out_of_order_ip_before_link_and_zero_ip);
  RUN_TEST(test_wifi_has_priority_when_both_are_up);
  RUN_TEST(test_ip_to_string);
  RUN_TEST(test_ap_access_ethernet_subnet_overlap_closes_ap_origin);
  RUN_TEST(test_mqtt_reconnects_when_active_interface_changes);
  RUN_TEST(test_dns_applied_on_switch_or_new_lease_only_when_known);
  RUN_TEST(test_provisioned_ethernet_only_board_never_cycles_the_ap);
  RUN_TEST(test_provisioned_board_with_saved_wifi_down_but_ethernet_up_does_not_trigger);
  RUN_TEST(test_without_ethernet_no_saved_wifi_still_opens_and_cycles_as_v121);
  RUN_TEST(test_unprovisioned_board_opens_setup_ap_with_cable_plugged);
  RUN_TEST(test_open_window_closes_early_when_ethernet_comes_up_on_provisioned_board);
  return UNITY_END();
}
