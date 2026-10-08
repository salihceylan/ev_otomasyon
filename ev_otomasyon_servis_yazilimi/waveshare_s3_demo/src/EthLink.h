#pragma once
// ============================================================================
// EthLink.h - Waveshare ESP32-S3-POE-ETH-8DI-8RO kartındaki W5500 Ethernet (SPI) sürücüsü. v1.3.0 İP-2.2 (K-Ş1).
//
// Arduino-ESP32 2.0.17'nin ETH sınıfı W5500 bilmez; çekirdek DEĞİŞTİRİLMEDEN IDF 4.4 sürücüsü kullanılır (CONFIG_ETH_SPI_ETHERNET_W5500=y):
// spi_bus_initialize(SPI2) -> spi_bus_add_device -> esp_eth_mac_new_w5500 / esp_eth_phy_new_w5500 -> esp_eth_driver_install ->
// MAC (W5500'ün kendi MAC'i yok: esp_read_mac(ESP_MAC_ETH)) -> esp_netif_new(ESP_NETIF_DEFAULT_ETH) + esp_eth_new_netif_glue ->
// esp_eth_start. DHCP istemcisi esp_netif varsayılanıdır. Olaylar (ETH_EVENT, IP_EVENT_ETH_*) NetLink'i günceller.
// Pinler (kart şeması, eski demo WS_ETH.h): CS 16, INT 12, RST 39, SCK 15, MISO 14, MOSI 13.
//  * Başlatma BLOKLAMAZ: tek seferlik ayrı görevde (Core 0, öncelik 1) yürür; W5500 yanıt vermezse / kablo yoksa açılış etkilenmez,
//    tek satır log basılır ve Ethernet "yok" kalır. Kablo yokken uygulama davranışı bugünküyle aynıdır (NetLinkCore testleri).
//  * Eski demo NTP/RTC kodu (Çin saat dilimi, sonsuz bekleme) GERİ GELMEZ; saat SNTP'den (WiFiManager, ağ VEYA Ethernet).
//  * UID değişmez (Wi-Fi MAC). Ethernet MAC'i yalnız W5500'e yazılır.
// DONANIMDA DENENMEDİ (2026-10-08): derlenir; sürücü sırası IDF 4.4 örneği ve çekirdeğin ETH.cpp'si izlenerek yazıldı.
// ============================================================================
#include <stdint.h>

class EthLink {
public:
  static void begin();       // setup(): WiFiManager::begin() sonrasında; ayrı görevi başlatır, hemen döner
  static void service();     // wifi_task her tur: olay kaçtıysa (bağlantı var, adres yok) IP durumunu esp_netif'ten tamamlar
  static bool present();     // sürücü kuruldu (W5500 yanıt verdi)
};

// W5500 pinleri (Waveshare ESP32-S3-POE-ETH-8DI-8RO)
#define ETH_W5500_CS    16
#define ETH_W5500_INT   12
#define ETH_W5500_RST   39
#define ETH_W5500_SCK   15
#define ETH_W5500_MISO  14
#define ETH_W5500_MOSI  13
#define ETH_W5500_SPI_MHZ 20
