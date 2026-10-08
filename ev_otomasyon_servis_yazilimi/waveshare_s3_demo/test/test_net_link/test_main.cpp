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
    TEST_ASSERT_EQUAL(wifi, apPolicyConnected(wifi, ethUp(none), true));
    TEST_ASSERT_EQUAL(wifi, apPolicyConnected(wifi, ethUp(none), false));
    TEST_ASSERT_EQUAL(wifi, sntpDue(true, wifi, ethUp(none)));
    TEST_ASSERT_FALSE(sntpDue(false, wifi, ethUp(none)));
    // tam durum: eski kural "staConnected ? staIp : apIp"
    TEST_ASSERT_EQUAL_UINT(wifi ? sta : ap, statusIp(wifi, sta, ethUp(none), 0, ap));
    // MQTT state: eski kural WiFiManager::getLocalIP() (bağlı değilken 0.0.0.0)
    TEST_ASSERT_EQUAL_UINT(wifi ? sta : 0u, stateIp(wifi, wifi ? sta : 0u, ethUp(none), 0));
    TEST_ASSERT_EQUAL_STRING(wifi ? "wifi" : "none", netIfName(activeIf(wifi, ethUp(none))));
  }
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
  TEST_ASSERT_TRUE(apPolicyConnected(false, ethUp(s), true));    // provizyonlu + Ethernet bağlı: kurtarma AP'si açılmaz
  TEST_ASSERT_FALSE(apPolicyConnected(false, ethUp(s), false));  // provizyonsuz: kurulum AP'si Ethernet varken de açılır (R1-1)
  TEST_ASSERT_TRUE(mqttNetOk(false, ethUp(s)));
  TEST_ASSERT_TRUE(sntpDue(true, false, ethUp(s)));
  TEST_ASSERT_EQUAL_UINT(ip(10, 0, 0, 7), statusIp(false, 0, ethUp(s), s.ip, ip(192, 168, 4, 1)));
  TEST_ASSERT_EQUAL_UINT(ip(10, 0, 0, 7), stateIp(false, 0, ethUp(s), s.ip));
  TEST_ASSERT_EQUAL_STRING("eth", netIfName(activeIf(false, ethUp(s))));
  // kablo çekildi
  ethApply(s, EthEvent::LINK_DOWN);
  TEST_ASSERT_FALSE(ethUp(s));
  TEST_ASSERT_EQUAL_UINT(0, s.ip);
  TEST_ASSERT_FALSE(apPolicyConnected(false, ethUp(s), true));
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

int main(int, char**) {
  UNITY_BEGIN();
  RUN_TEST(test_without_ethernet_every_decision_equals_wifi_only_behavior);
  RUN_TEST(test_cable_not_plugged_driver_started_is_not_up);
  RUN_TEST(test_link_then_dhcp_brings_ethernet_up_and_cable_pull_takes_it_down);
  RUN_TEST(test_out_of_order_ip_before_link_and_zero_ip);
  RUN_TEST(test_wifi_has_priority_when_both_are_up);
  RUN_TEST(test_ip_to_string);
  RUN_TEST(test_ap_access_ethernet_subnet_overlap_closes_ap_origin);
  RUN_TEST(test_mqtt_reconnects_when_active_interface_changes);
  RUN_TEST(test_dns_applied_on_switch_or_new_lease_only_when_known);
  return UNITY_END();
}
