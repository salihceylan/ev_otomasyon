#include <Arduino.h>
#include <WiFi.h>
#include "WS_GPIO.h"
#include "I2C_Driver.h"
#include "WS_RTC.h"
#include "WS_Relay.h"
#include "ConfigManager.h"
#include "SmartAutomation.h"
#include "WebPortal.h"

void setup() {
  Serial.begin(115200);
  delay(500);
  printf("\r\n========================================\r\n");
  printf("  AHBU Akilli Ev & Bina Otomasyonu (ESP32-S3)\r\n");
  printf("========================================\r\n");

  // Donanım Başlatma
  GPIO_Init();   // RGB LED & Buzzer
  I2C_Init();    // TCA9554 & PCF85063 I2C Bus
  RTC_Init();    // Donanımsal Saat
  Relay_Init();  // 8 Röle Sürücüsü (TCA9554)

  // Konfigürasyon Yöneticisi (NVS Hafıza)
  ConfigManager::instance().begin();

  // Akıllı Otomasyon Yöneticisi (Interlock, Panjur, Butonlar, RS485)
  SmartAutomation::instance().begin();

  // Wi-Fi Başlatma: Önce STA modunda temiz tarama yap
  WiFi.disconnect(true);
  delay(100);
  WiFi.mode(WIFI_STA);
  printf("[WiFi] Acilista cevredeki aglar taraniyor...\r\n");
  int n = WiFi.scanNetworks(false, false, false, 200);
  printf("[WiFi] Ilk tarama bitti: %d ag bulundu.\r\n", n);
  if (n > 0) {
    for (int i = 0; i < n && i < 15; i++) {
      printf("  -> [%d] %s (%d dBm)\r\n", i + 1, WiFi.SSID(i).c_str(), WiFi.RSSI(i));
    }
  }
  WebPortal::instance().storeScanResults(n);
  WiFi.scanDelete();

  // Şimdi SoftAP ve DHCP sunucusunu başlat
  IPAddress local_ip(192, 168, 4, 1);
  IPAddress gateway(192, 168, 4, 1);
  IPAddress subnet(255, 255, 255, 0);
  WiFi.softAPConfig(local_ip, gateway, subnet);

  auto& cfg = ConfigManager::instance().config;
  WiFi.mode(WIFI_AP_STA);
  WiFi.softAP("ESP32-S3-POE-ETH-8DI-8RO", "waveshare", 1);

  if (cfg.wifi_sta_enabled && strlen(cfg.wifi_ssid) > 0) {
    printf("Ev Wi-Fi Agina Baglaniliyor: %s ...\r\n", cfg.wifi_ssid);
    WiFi.begin(cfg.wifi_ssid, cfg.wifi_pass);
  }
  
  IPAddress apIP = WiFi.softAPIP();
  printf("Wi-Fi AP Baslatildi: SSID: ESP32-S3-POE-ETH-8DI-8RO (Kanal 1) | IP: %s\r\n", apIP.toString().c_str());

  // Web Sunucusunu Başlat
  WebPortal::instance().begin();

  // Durum LED'ini yeşil yak (Başarılı açılış)
  RGB_Open_Time(0, 60, 0, 1000, 0);
  Buzzer_Open_Time(100, 0);

  printf("Sistem hazir! Web arayuzune erisim: http://%s\r\n", apIP.toString().c_str());
}

static void handleSerialCli() {
  if (Serial.available()) {
    String cmd = Serial.readStringUntil('\n');
    cmd.trim();
    if (cmd.isEmpty()) return;

    Serial.printf("\r\n[CLI] Komut alindi: %s\r\n", cmd.c_str());

    if (cmd.equalsIgnoreCase("STATUS")) {
      auto& cfg = ConfigManager::instance().config;
      bool sta = (WiFi.status() == WL_CONNECTED);
      Serial.printf("[STATUS] Cihaz: %s\r\n", cfg.device_name);
      Serial.printf("  - IP (STA): %s (Bagli: %s)\r\n", sta ? WiFi.localIP().toString().c_str() : "Yok", sta ? "EVET" : "HAYIR");
      Serial.printf("  - IP (AP): %s\r\n", WiFi.softAPIP().toString().c_str());
      Serial.printf("  - Ek Modul: %s (Kanal: %d, Adres: %d)\r\n", cfg.ext_module_enabled ? "AKTIF" : "PASIF", cfg.ext_module_channels, cfg.ext_module_address);
      Serial.printf("  - Toplam Role: %d, Toplam DI: %d\r\n", cfg.totalRelays(), cfg.totalDIs());
    } else if (cmd.startsWith("EXTMOD ") || cmd.startsWith("extmod ")) {
      // EXTMOD 1 8 veya EXTMOD 0
      int p1 = cmd.indexOf(' ');
      int p2 = cmd.indexOf(' ', p1 + 1);
      bool en = (cmd.substring(p1 + 1, (p2 > 0 ? p2 : cmd.length())).toInt() == 1);
      int ch = (p2 > 0) ? cmd.substring(p2 + 1).toInt() : 8;
      auto& cfg = ConfigManager::instance().config;
      cfg.ext_module_enabled = en;
      cfg.ext_module_channels = ch;
      ConfigManager::instance().save();
      Serial.printf("[CLI-SONUC] Ek Modul: %s, Kanal: %d -> Toplam Role: %d, Toplam DI: %d (NVS'ye Kaydedildi!)\r\n",
                    en ? "AKTIF" : "PASIF", ch, cfg.totalRelays(), cfg.totalDIs());
    } else if (cmd.equalsIgnoreCase("SCAN") || cmd.equalsIgnoreCase("TEST")) {
      auto res = SmartAutomation::instance().rs485ScanModule();
      if (res.found) {
        Serial.printf("[CLI-SONUC] BASARILI! Harici Modul Tespit Edildi:\r\n");
        Serial.printf("  - Slave Adresi: %d\r\n", res.slaveId);
        Serial.printf("  - Baud Rate: %d\r\n", res.baud);
        Serial.printf("  - Role Durumlari: 0x%02X\r\n", res.relayStatus);
        Serial.printf("  - Ham Yanit: %s\r\n", res.rawHex.c_str());
        Serial.printf("  - Bilgi: %s\r\n", res.info.c_str());
      } else {
        Serial.printf("[CLI-SONUC] BASARISIZ: Harici modulden yanit alinamadi!\r\n");
        Serial.printf("  - Lutfen RS485 A+ ve B- klemens baglantisini kontrol edin.\r\n");
        Serial.printf("  - Harici modulun 12V/24V beslemesinin takili oldugundan emin olun.\r\n");
      }
    } else if (cmd.startsWith("CH") || cmd.startsWith("ch")) {
      int ch = cmd.substring(2).toInt();
      if (ch < 1 || ch > 8) ch = 1;
      uint8_t action = 2; // default toggle
      if (cmd.indexOf("ON") > 0 || cmd.indexOf("on") > 0) action = 1;
      else if (cmd.indexOf("OFF") > 0 || cmd.indexOf("off") > 0) action = 0;

      String resp = "";
      bool ok = SmartAutomation::instance().rs485ControlExtRelay(1, ch, action, &resp);
      if (!ok) {
        ok = SmartAutomation::instance().rs485ControlExtRelay(2, ch, action, &resp);
      }
      Serial.printf("[CLI-SONUC] Role %d (Eylem %d) -> %s (Yanit: %s)\r\n", ch, action, ok ? "BASARILI" : "BASARISIZ", resp.c_str());
    } else if (cmd.startsWith("SEND ")) {
      String hexData = cmd.substring(5);
      hexData.trim();
      SmartAutomation::instance().rs485Send(hexData, true);
    } else if (cmd.startsWith("BAUD ")) {
      uint32_t b = cmd.substring(5).toInt();
      if (b > 0) {
        ConfigManager::instance().config.rs485_baud = b;
        SmartAutomation::instance().rs485Begin(b);
        Serial.printf("[CLI-SONUC] Baud %d olarak ayarlandi.\r\n", b);
      }
    } else {
      Serial.printf("[CLI] Bilinmeyen komut: '%s'. (Komutlar: SCAN, TEST, CH 1, CH 1 ON, CH 1 OFF, SEND <hex>, BAUD <baud>)\r\n", cmd.c_str());
    }
  }
}

void loop() {
  handleSerialCli();
  SmartAutomation::instance().loop();
  WebPortal::instance().loop();
  vTaskDelay(pdMS_TO_TICKS(5));
}