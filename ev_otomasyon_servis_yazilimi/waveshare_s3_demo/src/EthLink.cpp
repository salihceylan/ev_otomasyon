// EthLink.cpp - W5500 Ethernet sürücüsü (IDF 4.4 esp_eth + esp_netif). Bkz. EthLink.h.
#include "EthLink.h"
#include "IdfIpcWrap.h"
#include "NetLink.h"
#include "WiFiManager.h"
#include <Arduino.h>
#include <esp_eth.h>
#include <esp_netif.h>
#include <esp_event.h>
#include <esp_system.h>
#include <driver/spi_master.h>
#include <driver/gpio.h>
#include <string.h>

namespace {

esp_netif_t* s_netif = nullptr;
esp_eth_handle_t s_eth = nullptr;
volatile bool s_present = false;

void onEthEvent(void*, esp_event_base_t, int32_t id, void*) {
  switch (id) {
    case ETHERNET_EVENT_START:
      NetLink::ethEvent(netlink::EthEvent::START);
      printf("[ETH] W5500 basladi (kablo bekleniyor).\r\n");
      break;
    case ETHERNET_EVENT_CONNECTED:
      NetLink::ethEvent(netlink::EthEvent::LINK_UP);
      printf("[ETH] Kablo baglandi; DHCP bekleniyor.\r\n");
      break;
    case ETHERNET_EVENT_DISCONNECTED:
      NetLink::ethEvent(netlink::EthEvent::LINK_DOWN);
      printf("[ETH] Kablo cikti / baglanti koptu.\r\n");
      break;
    case ETHERNET_EVENT_STOP:
      NetLink::ethEvent(netlink::EthEvent::STOP);
      printf("[ETH] Durdu.\r\n");
      break;
    default:
      break;
  }
}

void onIpEvent(void*, esp_event_base_t, int32_t id, void* data) {
  if (id == IP_EVENT_ETH_GOT_IP && data) {
    const ip_event_got_ip_t* e = (const ip_event_got_ip_t*)data;
    NetLink::ethEvent(netlink::EthEvent::GOT_IP, e->ip_info.ip.addr, e->ip_info.netmask.addr, e->ip_info.gw.addr);
    NetLink::captureDns(netlink::NetIf::ETH);   // DHCP'nin az önce yazdığı genel DNS = Ethernet'in DNS'i (R1-4)
    WiFiManager::instance().requestSntp();   // saat: SNTP herhangi bir arayüzden (wifi_task başlatır)
    char ip[16];
    netlink::ipToStr(e->ip_info.ip.addr, ip, sizeof(ip));
    printf("[ETH] IP alindi: %s\r\n", ip);
  } else if (id == IP_EVENT_ETH_LOST_IP) {
    NetLink::ethEvent(netlink::EthEvent::LOST_IP);
    printf("[ETH] IP kaybedildi.\r\n");
  }
}

// Başarısız kurulumda ayrılan kaynakları geri verir (sürücü yarım kalmaz).
void cleanup(esp_eth_mac_t* mac, esp_eth_phy_t* phy, spi_device_handle_t spi, bool busInit) {
  if (mac) mac->del(mac);
  if (phy) phy->del(phy);
  if (spi) spi_bus_remove_device(spi);
  if (busInit) spi_bus_free(SPI2_HOST);
}

bool initDriver() {
  // tcpip yığını ve varsayılan olay döngüsü WiFiManager::begin() ile zaten kurulu; ikinci çağrı zararsız (INVALID_STATE).
  esp_netif_init();
  esp_err_t er = esp_event_loop_create_default();
  if (er != ESP_OK && er != ESP_ERR_INVALID_STATE) return false;
  // gpio_install_isr_service -> esp_ipc_call_blocking: bu gorev Core 0'a sabit oldugundan IdfIpcWrap.cpp isi ipc0'in 1 KB'lik yiginda degil
  // bu gorevin 4 KB'lik yiginda kosturur (aksi halde Wi-Fi baslatmasiyla ayni ana denk gelince ipc0 yigini tasar: acilista PANIC; IpcPolicy.h).
  const uint32_t ipcInlineBefore = idfipc::inlineCalls();
  er = gpio_install_isr_service(0);
  if (er != ESP_OK && er != ESP_ERR_INVALID_STATE) {
    printf("[ETH] gpio_install_isr_service hatasi (%d).\r\n", (int)er);
    return false;
  }
  if (er == ESP_OK) {   // hizmet bu cagriyla kuruldu (INVALID_STATE: baska biri onceden kurmus, IPC hic kullanilmadi)
    if (idfipc::inlineCalls() != ipcInlineBefore) {
      printf("[ETH] GPIO ISR servisi eth_init yiginda kuruldu (ipc0 atlandi).\r\n");
    } else {
      printf("[ETH] UYARI: IPC sarmalayicisi etkin degil (platformio.ini -Wl,--wrap=esp_ipc_call_blocking eksik): acilista PANIC riski.\r\n");
    }
  }

  spi_bus_config_t bus;
  memset(&bus, 0, sizeof(bus));
  bus.miso_io_num = ETH_W5500_MISO;
  bus.mosi_io_num = ETH_W5500_MOSI;
  bus.sclk_io_num = ETH_W5500_SCK;
  bus.quadwp_io_num = -1;
  bus.quadhd_io_num = -1;
  if (spi_bus_initialize(SPI2_HOST, &bus, SPI_DMA_CH_AUTO) != ESP_OK) {
    printf("[ETH] SPI veri yolu baslatilamadi.\r\n");
    return false;
  }
  spi_device_interface_config_t dev;
  memset(&dev, 0, sizeof(dev));
  dev.command_bits = 16;   // W5500 çerçevesi: adres evresi
  dev.address_bits = 8;    // ... denetim evresi
  dev.mode = 0;
  dev.clock_speed_hz = ETH_W5500_SPI_MHZ * 1000 * 1000;
  dev.spics_io_num = ETH_W5500_CS;
  dev.queue_size = 20;
  spi_device_handle_t spi = nullptr;
  if (spi_bus_add_device(SPI2_HOST, &dev, &spi) != ESP_OK) {
    cleanup(nullptr, nullptr, nullptr, true);
    printf("[ETH] SPI aygiti eklenemedi.\r\n");
    return false;
  }

  eth_w5500_config_t w5500 = ETH_W5500_DEFAULT_CONFIG(spi);
  w5500.int_gpio_num = ETH_W5500_INT;
  eth_mac_config_t macCfg = ETH_MAC_DEFAULT_CONFIG();
  macCfg.rx_task_stack_size = 3072;
  eth_phy_config_t phyCfg = ETH_PHY_DEFAULT_CONFIG();
  phyCfg.phy_addr = 1;
  phyCfg.reset_gpio_num = ETH_W5500_RST;
  esp_eth_mac_t* mac = esp_eth_mac_new_w5500(&w5500, &macCfg);
  esp_eth_phy_t* phy = esp_eth_phy_new_w5500(&phyCfg);
  if (!mac || !phy) {
    cleanup(mac, phy, spi, true);
    printf("[ETH] W5500 surucusu olusturulamadi (bellek).\r\n");
    return false;
  }
  esp_eth_config_t cfg = ETH_DEFAULT_CONFIG(mac, phy);
  esp_eth_handle_t h = nullptr;
  if (esp_eth_driver_install(&cfg, &h) != ESP_OK || !h) {
    cleanup(mac, phy, spi, true);
    printf("[ETH] W5500 yanit vermedi: Ethernet YOK (Wi-Fi ile devam).\r\n");
    return false;
  }
  // W5500'ün fabrika MAC'i yoktur: cihaza özgü (yerel yönetimli) Ethernet MAC'i. UID Wi-Fi MAC'inden kalır.
  uint8_t m[6];
  if (esp_read_mac(m, ESP_MAC_ETH) != ESP_OK) {
    esp_read_mac(m, ESP_MAC_WIFI_STA);
    m[0] |= 0x02;
    m[5] ^= 0x55;
  }
  esp_eth_ioctl(h, ETH_CMD_S_MAC_ADDR, m);

  esp_netif_config_t ncfg = ESP_NETIF_DEFAULT_ETH();
  esp_netif_t* netif = esp_netif_new(&ncfg);
  if (!netif) {
    esp_eth_driver_uninstall(h);
    cleanup(mac, phy, spi, true);
    printf("[ETH] esp_netif olusturulamadi.\r\n");
    return false;
  }
  {
    char host[24];
    uint8_t sm[6];
    esp_read_mac(sm, ESP_MAC_WIFI_STA);
    snprintf(host, sizeof(host), "AHBU-%02X%02X%02X", sm[3], sm[4], sm[5]);   // Wi-Fi ile aynı ana makine adı
    esp_netif_set_hostname(netif, host);
  }
  esp_event_handler_register(ETH_EVENT, ESP_EVENT_ANY_ID, &onEthEvent, nullptr);
  esp_event_handler_register(IP_EVENT, IP_EVENT_ETH_GOT_IP, &onIpEvent, nullptr);
  esp_event_handler_register(IP_EVENT, IP_EVENT_ETH_LOST_IP, &onIpEvent, nullptr);
  if (esp_netif_attach(netif, esp_eth_new_netif_glue(h)) != ESP_OK) {
    printf("[ETH] esp_netif_attach basarisiz.\r\n");
    return false;   // sürücü kurulu kalır ama başlatılmaz (Ethernet yok); kaynaklar yeniden başlatmaya dek tutulur
  }
  s_netif = netif;
  s_eth = h;
  if (esp_eth_start(h) != ESP_OK) {
    printf("[ETH] esp_eth_start basarisiz.\r\n");
    return false;
  }
  s_present = true;
  printf("[ETH] W5500 hazir (MAC %02X:%02X:%02X:%02X:%02X:%02X).\r\n", m[0], m[1], m[2], m[3], m[4], m[5]);
  return true;
}

void ethInitTask(void*) {
  const uint32_t t0 = millis();
  const bool ok = initDriver();
  printf("[ETH] Baslatma %s (%u ms, bos yigin %u bayt).\r\n", ok ? "tamam" : "basarisiz/yok", (unsigned)(millis() - t0),
         (unsigned)uxTaskGetStackHighWaterMark(nullptr));
  vTaskDelete(nullptr);
}

}  // namespace

void EthLink::begin() {
  static bool started = false;
  if (started) return;
  started = true;
  if (xTaskCreatePinnedToCore(ethInitTask, "eth_init", 4096, nullptr, 1, nullptr, 0) != pdPASS) {
    printf("[ETH] Baslatma gorevi olusturulamadi: Ethernet YOK.\r\n");
  }
}

void EthLink::service() {
  if (!s_present || !s_netif) return;
  const netlink::EthState e = NetLink::eth();
  if (!e.link || e.hasIp) return;
  esp_netif_ip_info_t info;
  if (esp_netif_get_ip_info(s_netif, &info) == ESP_OK && info.ip.addr != 0) {
    NetLink::ethEvent(netlink::EthEvent::GOT_IP, info.ip.addr, info.netmask.addr, info.gw.addr);
    WiFiManager::instance().requestSntp();
  }
}

bool EthLink::present() { return s_present; }
