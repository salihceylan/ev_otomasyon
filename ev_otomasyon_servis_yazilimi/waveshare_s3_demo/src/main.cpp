#include <Arduino.h>
#include <WiFi.h>
#include "WS_GPIO.h"
#include "I2C_Driver.h"
#include "WS_RTC.h"
#include "WS_Relay.h"
#include "ConfigManager.h"
#include "SmartAutomation.h"
#include "WebPortal.h"
#include "WiFiManager.h"
#include "MqttManager.h"

void setup() {
  Serial.begin(115200);
  delay(500);
  printf("\r\n========================================\r\n");
  printf("  AHBU Akilli Ev & Bina Otomasyonu (ESP32-S3)\r\n");
  printf("========================================\r\n");

  // Donanım Başlatma
  printf("[BOOT] GPIO_Init basliyor...\r\n");
  GPIO_Init();   // RGB LED & Buzzer
  printf("[BOOT] I2C_Init basliyor...\r\n");
  I2C_Init();    // TCA9554 & PCF85063 I2C Bus
  printf("[BOOT] RTC_Init basliyor...\r\n");
  RTC_Init();    // Donanımsal Saat
  printf("[BOOT] Relay_Init basliyor...\r\n");
  Relay_Init();  // 8 Röle Sürücüsü (TCA9554)
  printf("[BOOT] ConfigManager basliyor...\r\n");

  // Konfigürasyon Yöneticisi (NVS Hafıza)
  ConfigManager::instance().begin();
  printf("[BOOT] ConfigManager tamam.\r\n");

  // Test SSID'si kalmışsa temizle
  auto& cfg = ConfigManager::instance().config;
  if (strcmp(cfg.wifi_ssid, "TestSSID") == 0) {
    memset(cfg.wifi_ssid, 0, sizeof(cfg.wifi_ssid));
    memset(cfg.wifi_pass, 0, sizeof(cfg.wifi_pass));
    cfg.wifi_sta_enabled = false;
    ConfigManager::instance().save();
  }

  printf("[BOOT] SmartAutomation basliyor...\r\n");
  // Akıllı Otomasyon Yöneticisi (Interlock, Panjur, Butonlar, RS485)
  SmartAutomation::instance().begin();
  printf("[BOOT] SmartAutomation tamam.\r\n");

  // Wi-Fi: SoftAP ve DHCP sunucusunu başlat
  WiFi.disconnect(true);
  delay(100);
  IPAddress local_ip(192, 168, 4, 1);
  IPAddress gateway(192, 168, 4, 1);
  IPAddress subnet(255, 255, 255, 0);
  WiFi.softAPConfig(local_ip, gateway, subnet);
  WiFi.mode(WIFI_AP_STA);
  WiFi.softAP("ESP32-S3-POE-ETH-8DI-8RO", "waveshare", 1);
  IPAddress apIP = WiFi.softAPIP();
  printf("[WiFi] SoftAP Baslatildi: SSID=ESP32-S3-POE-ETH-8DI-8RO | IP: %s\r\n", apIP.toString().c_str());

  // Endüstriyel Asenkron Wi-Fi Yöneticisi (Core 0 / Exponential Backoff)
  WiFiManager::instance().begin();

  // Web Sunucusunu Başlat
  WebPortal::instance().begin();

  // Güvenli MQTTS Yöneticisi (Port 8884 / TLS 1.3 / Core 0)
  MqttManager::instance().begin();

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
      bool sta = WiFiManager::instance().isConnected();
      bool mq = MqttManager::instance().isConnected();
      Serial.printf("[STATUS] Cihaz: %s (MAC: %s)\r\n", cfg.device_name, WiFiManager::instance().getMacAddress().c_str());
      Serial.printf("  - IP (STA): %s (Bagli: %s, Sinyal: %d dBm, Calisma: %u sn, Deneme: %u)\r\n",
                    sta ? WiFiManager::instance().getLocalIP().toString().c_str() : "Yok",
                    sta ? "EVET" : "HAYIR",
                    WiFiManager::instance().getRSSI(),
                    WiFiManager::instance().getUptimeSeconds(),
                    WiFiManager::instance().getReconnectCount());
      Serial.printf("  - IP (AP): %s\r\n", WiFi.softAPIP().toString().c_str());
      Serial.printf("  - MQTTS (Port %d): %s (Broker: %s, Daire: %s)\r\n",
                    MqttManager::instance().getPort(),
                    mq ? "BAGLI (TLS 1.3 / Online)" : "BAGLANTI BEKLENIYOR",
                    MqttManager::instance().getServer().c_str(),
                    MqttManager::instance().getUsername().c_str());
      Serial.printf("  - MQTTS Konulari: [Status: %s | State: %s | Cmd: %s]\r\n",
                    MqttManager::instance().getStatusTopic().c_str(),
                    MqttManager::instance().getStateTopic().c_str(),
                    MqttManager::instance().getCmdTopic().c_str());
      Serial.printf("  - Ek Modul: %s (Kanal: %d, Adres: %d)\r\n", cfg.ext_module_enabled ? "AKTIF" : "PASIF", cfg.ext_module_channels, cfg.ext_module_address);
      Serial.printf("  - Toplam Role: %d, Toplam DI: %d\r\n", cfg.totalRelays(), cfg.totalDIs());
      Serial.printf("  - Yerel Roleler (8RO): [");
      for (int i = 0; i < 8; i++) {
        Serial.printf("R%d:%s%s", i + 1, SmartAutomation::instance().getRelayState(i) ? "1" : "0", i < 7 ? " " : "");
      }
      Serial.printf("]\r\n");
      Serial.printf("  - Yerel Girisler (8DI): [");
      for (int i = 0; i < 8; i++) {
        Serial.printf("D%d:%s%s", i + 1, SmartAutomation::instance().getDIState(i) ? "1" : "0", i < 7 ? " " : "");
      }
      Serial.printf("]\r\n");
      Serial.printf("  - Panjurlar (4 Cift): [");
      for (int p = 0; p < 4; p++) {
        ShutterState st = SmartAutomation::instance().getShutterState(p);
        const char* dirStr = "DURDU";
        if (st.pending_direction == 1) dirStr = "DEAD-TIME (YUKARI BEKLENIYOR)";
        else if (st.pending_direction == 2) dirStr = "DEAD-TIME (ASAGI BEKLENIYOR)";
        else if (st.is_moving && st.direction == 1) dirStr = "YUKARI HAREKET";
        else if (st.is_moving && st.direction == 2) dirStr = "ASAGI HAREKET";
        Serial.printf("P%d:%%%d [%s]%s", p + 1, st.current_position, dirStr, p < 3 ? " | " : "");
      }
      Serial.printf("]\r\n");
    } else if (cmd.equalsIgnoreCase("MQTT") || cmd.equalsIgnoreCase("mqtt")) {
      bool mq = MqttManager::instance().isConnected();
      Serial.printf("[MQTTS DURUMU]\r\n");
      Serial.printf("  - Durum: %s\r\n", mq ? "BAGLI (TLS 1.3 / Online)" : "BAGLI DEGIL / Yeniden Baglaniliyor");
      Serial.printf("  - Sunucu: %s:%d\r\n", MqttManager::instance().getServer().c_str(), MqttManager::instance().getPort());
      Serial.printf("  - Daire / Kullanici: %s\r\n", MqttManager::instance().getUsername().c_str());
      Serial.printf("  - Durum Konusu (LWT): %s\r\n", MqttManager::instance().getStatusTopic().c_str());
      Serial.printf("  - Canli Rapor Konusu: %s\r\n", MqttManager::instance().getStateTopic().c_str());
      Serial.printf("  - Komut Dinleme Konusu: %s\r\n", MqttManager::instance().getCmdTopic().c_str());
    } else if (cmd.startsWith("MQTT PUB") || cmd.startsWith("mqtt pub")) {
      MqttManager::instance().triggerPublish();
      Serial.printf("[CLI-SONUC] MQTTS Durum Raporu Yayinlama Tetiklendi.\r\n");
    } else if (cmd.startsWith("RELAY") || cmd.startsWith("relay")) {
      String sub = cmd.substring(5);
      sub.trim();
      if (sub.equalsIgnoreCase("ALL ON")) {
        for (int i = 0; i < 8; i++) SmartAutomation::instance().setRelayState(i, true);
        Serial.printf("[CLI-SONUC] Tum 8 Yerel Role Acildi (ON).\r\n");
      } else if (sub.equalsIgnoreCase("ALL OFF")) {
        for (int i = 0; i < 8; i++) SmartAutomation::instance().setRelayState(i, false);
        Serial.printf("[CLI-SONUC] Tum 8 Yerel Role Kapatildi (OFF).\r\n");
      } else {
        int rNum = sub.toInt();
        if (rNum >= 1 && rNum <= 8) {
          uint8_t rIdx = rNum - 1;
          if (sub.indexOf("ON") > 0 || sub.indexOf("on") > 0) {
            SmartAutomation::instance().setRelayState(rIdx, true);
          } else if (sub.indexOf("OFF") > 0 || sub.indexOf("off") > 0) {
            SmartAutomation::instance().setRelayState(rIdx, false);
          } else {
            SmartAutomation::instance().toggleRelay(rIdx);
          }
          Serial.printf("[CLI-SONUC] Yerel Role %d -> %s\r\n", rNum, SmartAutomation::instance().getRelayState(rIdx) ? "ACIK (ON)" : "KAPALI (OFF)");
        } else {
          Serial.printf("[CLI-HATA] Kullanim: RELAY <1-8> [ON|OFF|TOGGLE] veya RELAY ALL [ON|OFF]\r\n");
        }
      }
    } else if (cmd.startsWith("SHUTTER") || cmd.startsWith("shutter")) {
      String sub = cmd.substring(7);
      sub.trim();
      if (sub.equalsIgnoreCase("ALL UP")) {
        SmartAutomation::instance().allShuttersUp();
        Serial.printf("[CLI-SONUC] Tum Panjurlar YUKARI calistirildi.\r\n");
      } else if (sub.equalsIgnoreCase("ALL DOWN")) {
        SmartAutomation::instance().allShuttersDown();
        Serial.printf("[CLI-SONUC] Tum Panjurlar ASAGI calistirildi.\r\n");
      } else if (sub.equalsIgnoreCase("ALL STOP")) {
        SmartAutomation::instance().allShuttersStop();
        Serial.printf("[CLI-SONUC] Tum Panjurlar DURDURULDU.\r\n");
      } else {
        int pNum = sub.toInt();
        if (pNum >= 1 && pNum <= 4) {
          uint8_t pIdx = pNum - 1;
          if (sub.indexOf("POS") > 0 || sub.indexOf("pos") > 0) {
            int posIdx = sub.indexOf("POS");
            if (posIdx < 0) posIdx = sub.indexOf("pos");
            int val = sub.substring(posIdx + 3).toInt();
            SmartAutomation::instance().setShutterPosition(pIdx, (uint8_t)val);
            Serial.printf("[CLI-SONUC] Panjur %d -> Hedef Pozisyon: %%%d olarak ayarlandi.\r\n", pNum, val);
          } else if (sub.indexOf("UP") > 0 || sub.indexOf("up") > 0) {
            SmartAutomation::instance().shutterUp(pIdx);
          } else if (sub.indexOf("DOWN") > 0 || sub.indexOf("down") > 0) {
            SmartAutomation::instance().shutterDown(pIdx);
          } else if (sub.indexOf("STOP") > 0 || sub.indexOf("stop") > 0) {
            SmartAutomation::instance().shutterStop(pIdx);
          } else if (sub.indexOf("STEP") > 0 || sub.indexOf("step") > 0) {
            SmartAutomation::instance().shutterStep(pIdx);
          } else {
            Serial.printf("[CLI-HATA] Kullanim: SHUTTER <1-4> [UP|DOWN|STOP|STEP|POS <0-100>] veya SHUTTER ALL [UP|DOWN|STOP]\r\n");
          }
        } else {
          Serial.printf("[CLI-HATA] Kullanim: SHUTTER <1-4> [UP|DOWN|STOP|STEP|POS <0-100>] veya SHUTTER ALL [UP|DOWN|STOP]\r\n");
        }
      }
    } else if (cmd.equalsIgnoreCase("DI") || cmd.equalsIgnoreCase("di") || cmd.equalsIgnoreCase("INPUTS")) {
      Serial.printf("[DI DURUMLARI (DGND ile Kuru Kontak)]\r\n");
      for (int i = 0; i < 8; i++) {
        bool st = SmartAutomation::instance().getDIState(i);
        Serial.printf("  - DI-%d (GPIO %d): %s (Kontak %s)\r\n", 
                      i + 1, (i <= 7 ? (i + 4) : 0),
                      st ? "AKTIF (LOW)" : "PASIF (HIGH)",
                      st ? "KAPALI / BIRLESIK" : "ACIK / SERBEST");
      }
    } else if (cmd.equalsIgnoreCase("CFG") || cmd.equalsIgnoreCase("CONFIG")) {
      auto& cfg = ConfigManager::instance().config;
      Serial.printf("[YAPILANDIRMA BILGISI]\r\n");
      for (int i = 0; i < 8; i++) {
        Serial.printf("  - Role %d: '%s' (Tip: %d, Sure: %d sn)\r\n", 
                      i + 1, cfg.relays[i].name, cfg.relays[i].type, cfg.relays[i].runtime_sec);
      }
      for (int i = 0; i < 8; i++) {
        Serial.printf("  - DI %d: '%s' -> Hedef Role: %d (Mod: %d)\r\n",
                      i + 1, cfg.dis[i].name, cfg.dis[i].target_relay, cfg.dis[i].mode);
      }
    } else if (cmd.equalsIgnoreCase("SET_SHUTTER_DI") || cmd.equalsIgnoreCase("DEFAULT_DI")) {
      auto& cfg = ConfigManager::instance().config;
      strncpy(cfg.dis[0].name, "Salon Panjur Butonu", sizeof(cfg.dis[0].name) - 1);
      cfg.dis[0].target_relay = 1;
      cfg.dis[0].mode = DI_MODE_SHUTTER_STEP; // 2

      strncpy(cfg.dis[1].name, "Giris 2 (Bosta / Serbest)", sizeof(cfg.dis[1].name) - 1);
      cfg.dis[1].target_relay = 0;
      cfg.dis[1].mode = DI_MODE_TOGGLE;       // 0

      strncpy(cfg.dis[2].name, "Oda Panjur Butonu", sizeof(cfg.dis[2].name) - 1);
      cfg.dis[2].target_relay = 3;
      cfg.dis[2].mode = DI_MODE_SHUTTER_STEP; // 2

      strncpy(cfg.dis[3].name, "Giris 4 (Bosta / Serbest)", sizeof(cfg.dis[3].name) - 1);
      cfg.dis[3].target_relay = 0;
      cfg.dis[3].mode = DI_MODE_TOGGLE;       // 0

      ConfigManager::instance().save();
      Serial.printf("[CLI-SONUC] Panjur DI ayarlari (2 Kablolu Tek Buton: DI1->P1, DI2->Bosta) NVS'ye kaydedildi!\r\n");
    } else if (cmd.startsWith("SET_DI ") || cmd.startsWith("set_di ")) {
      int di = 0, target = 0, mode = 0;
      if (sscanf(cmd.c_str() + 7, "%d %d %d", &di, &target, &mode) == 3) {
        if (di >= 1 && di <= 8) {
          auto& cfg = ConfigManager::instance().config;
          cfg.dis[di - 1].target_relay = target;
          cfg.dis[di - 1].mode = mode;
          ConfigManager::instance().save();
          Serial.printf("[CLI-SONUC] DI %d -> Hedef: Role %d, Mod: %d NVS'ye kaydedildi!\r\n", di, target, mode);
        }
      }
    } else if (cmd.equalsIgnoreCase("WIFI CLEAR") || cmd.equalsIgnoreCase("wifi clear")) {
      auto& cfg = ConfigManager::instance().config;
      memset(cfg.wifi_ssid, 0, sizeof(cfg.wifi_ssid));
      memset(cfg.wifi_pass, 0, sizeof(cfg.wifi_pass));
      cfg.wifi_sta_enabled = false;
      ConfigManager::instance().save();
      WiFiManager::instance().setCredentials("", "");
      WiFi.disconnect(false, false);
      WiFi.mode(WIFI_AP_STA);
      Serial.printf("[CLI-SONUC] Wi-Fi STA Bilgileri Temizlendi. Yalnizca AP modu aktif.\r\n");
    } else if (cmd.startsWith("WIFI ") || cmd.startsWith("wifi ")) {
      // WIFI <ssid> <pass>
      int p1 = cmd.indexOf(' ');
      int p2 = cmd.indexOf(' ', p1 + 1);
      if (p2 > 0) {
        String newSsid = cmd.substring(p1 + 1, p2);
        String newPass = cmd.substring(p2 + 1);
        auto& cfg = ConfigManager::instance().config;
        strncpy(cfg.wifi_ssid, newSsid.c_str(), sizeof(cfg.wifi_ssid) - 1);
        strncpy(cfg.wifi_pass, newPass.c_str(), sizeof(cfg.wifi_pass) - 1);
        cfg.wifi_sta_enabled = true;
        ConfigManager::instance().save();
        WiFiManager::instance().setCredentials(newSsid.c_str(), newPass.c_str());
        Serial.printf("[CLI-SONUC] Yeni Wi-Fi Bilgileri NVS'ye Kaydedildi: SSID='%s'\r\n", newSsid.c_str());
      } else {
        Serial.printf("[CLI-HATA] Kullanim: WIFI <ssid> <parola> veya WIFI CLEAR\r\n");
      }
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