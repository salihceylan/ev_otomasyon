#include <Arduino.h>
#include <WiFi.h>
#include <esp_task_wdt.h>
#include <esp_system.h>
#include "WS_GPIO.h"
#include "I2C_Driver.h"
#include "WS_PCF85063.h"
#include "WS_Relay.h"
#include "ConfigManager.h"
#include "SmartAutomation.h"
#include "DeviceCommand.h"
#include "WebPortal.h"
#include "WiFiManager.h"
#include "MqttManager.h"
#include "CliParse.h"

// Görev gözetleyici (TWDT) zaman aşımı: loopTask ve ilgili görevler bu sürede beslenmezse cihaz
// kendini YENİDEN BAŞLATIR (EVOTOMASYON_TASKS: "hiçbir görev kilitlenmeyecek").
static const uint32_t TWDT_TIMEOUT_SEC = 10;

static const char* resetReasonText(esp_reset_reason_t r) {
  switch (r) {
    case ESP_RST_POWERON:   return "POWERON (guc verildi)";
    case ESP_RST_EXT:       return "EXT (harici reset)";
    case ESP_RST_SW:        return "SW (yazilimli yeniden baslatma)";
    case ESP_RST_PANIC:     return "PANIC (istisna/cokme)";
    case ESP_RST_INT_WDT:   return "INT_WDT (kesme gozetleyicisi)";
    case ESP_RST_TASK_WDT:  return "TASK_WDT (gorev gozetleyicisi)";
    case ESP_RST_WDT:       return "WDT (diger gozetleyici)";
    case ESP_RST_DEEPSLEEP: return "DEEPSLEEP";
    case ESP_RST_BROWNOUT:  return "BROWNOUT (dusuk voltaj)";
    case ESP_RST_SDIO:      return "SDIO";
    default:                return "BILINMIYOR";
  }
}

void setup() {
  // F7: Relay_Init() setup()'ın İLK işi. TCA9554'ün çıkış latch'i ESP32 yeniden başlamasında önceki
  // durumu korur; bu yüzden bu noktadan önce hiçbir bekleme/çıktı/başlatma yapılmaz. (I2C hattı röle
  // sürücüsünün ön koşuludur.) Eski sıra: Serial + delay(500) + GPIO + I2C + RTC + Relay => ~700 ms.
  I2C_Init();
  Relay_Init();     // röleleri KAPATIR (gölge kayıt + 3 deneme)

  Serial.begin(115200);
  printf("\r\n========================================\r\n");
  printf("  AHBU Akilli Ev & Bina Otomasyonu (ESP32-S3)\r\n");
  printf("========================================\r\n");
  printf("[BOOT] Reset nedeni: %s\r\n", resetReasonText(esp_reset_reason()));

  // TWDT: 10 sn, zaman aşımında yeniden başlat (panic=true). IDLE0 görevi sdkconfig'te zaten abone
  // (CONFIG_ESP_TASK_WDT_CHECK_IDLE_TASK_CPU0): Core 0'da öncelik >= 1 olan HİÇBİR görev, 10 sn boyunca CPU'yu
  // bırakmadan (vTaskDelay/engellenen bekleme olmadan) çalışmamalıdır. Bu dosya setinin Core 0 görevleri
  // (ShutterGuard 50 ms, RelayFailTask 50 ms, rs485_scan <= ~250 ms'lik adımlar, RTC 1 Hz, RGB/Buzzer 50 ms)
  // her turda vTaskDelay ile CPU'yu bırakır. loopTask aşağıda setup() sonunda abone edilir, diğer görevler
  // (ShutterGuard, rs485_scan) kendini abone eder; ağ görevleri kendi abonelik sorumluluğundadır.
  esp_err_t wdt = esp_task_wdt_init(TWDT_TIMEOUT_SEC, true);
  if (wdt != ESP_OK) printf("[BOOT] UYARI: TWDT baslatilamadi (%d)\r\n", (int)wdt);

  // Donanım Başlatma
  printf("[BOOT] GPIO_Init basliyor...\r\n");
  GPIO_Init();       // RGB LED & Buzzer
  printf("[BOOT] RTC (PCF85063) basliyor...\r\n");
  PCF85063_Init();   // Donanımsal Saat (1 Hz okuma, I2C kilidi altında)

  // Konfigürasyon Yöneticisi (NVS Hafıza)
  printf("[BOOT] ConfigManager basliyor...\r\n");
  ConfigManager::instance().begin();
  printf("[BOOT] ConfigManager tamam.\r\n");

  printf("[BOOT] SmartAutomation basliyor...\r\n");
  // Akıllı Otomasyon Yöneticisi (komut kuyruğu, interlock, panjur FSM, butonlar, RS485)
  SmartAutomation::instance().begin();
  printf("[BOOT] SmartAutomation tamam.\r\n");

  // Wi-Fi/AP yaşam döngüsü (STA, kurtarma AP'si, AP parolası = ap_pass) tamamen WiFiManager'ındır.
  // (Eski kod burada sabit "waveshare" parolalı AP açıyordu; kaldırıldı.)
  WiFiManager::instance().begin();

  // Web Sunucusunu Başlat
  WebPortal::instance().begin();

  // Güvenli MQTTS Yöneticisi (Port 8884 / TLS / Core 0). Kimlik yoksa MQTT başlamaz.
  MqttManager::instance().begin();

  // loopTask'ı TWDT'ye abone et (bundan sonra her loop() turunda beslenir)
  esp_task_wdt_add(NULL);

  // Durum LED'ini yeşil yak (Başarılı açılış)
  RGB_Open_Time(0, 60, 0, 1000, 0);
  Buzzer_Open_Time(100, 0);

  printf("Sistem hazir!\r\n");
}

// ============================================================================
// Seri CLI (115200). Röle/panjur komutları YALNIZCA postDeviceCommand() ile kuyruğa yazılır.
// Satır tamamlanana kadar BEKLENMEZ (eski readStringUntil() 1 sn'ye kadar döngüyü bloklayabiliyordu).
// ============================================================================
static bool eq(const String& a, const char* b) { return a.equalsIgnoreCase(b); }

// Boşlukla ayrılmış n. kelime (0 tabanlı); yoksa boş dizgi
static String cliWord(const String& s, int n) {
  int idx = 0;
  int i = 0;
  const int len = s.length();
  while (i < len) {
    while (i < len && s[i] == ' ') i++;
    if (i >= len) break;
    int start = i;
    while (i < len && s[i] != ' ') i++;
    if (idx == n) return s.substring(start, i);
    idx++;
  }
  return String("");
}

// n. kelimeden satır sonuna kadar (parola gibi boşluk içerebilen alanlar için)
static String restFrom(const String& s, int n) {
  int idx = 0;
  int i = 0;
  const int len = s.length();
  while (i < len) {
    while (i < len && s[i] == ' ') i++;
    if (i >= len) break;
    if (idx == n) return s.substring(i);
    while (i < len && s[i] != ' ') i++;
    idx++;
  }
  return String("");
}

static void cliPrintStatus() {
  auto& cfg = ConfigManager::instance().config;
  auto& sa = SmartAutomation::instance();
  AutomationSnapshot snap;
  bool haveSnap = sa.getSnapshot(snap);
  bool sta = WiFiManager::instance().isConnected();
  bool mq = MqttManager::instance().isConnected();

  Serial.printf("[STATUS] Cihaz: %s (MAC: %s)\r\n", cfg.device_name, WiFiManager::instance().getMacAddress().c_str());
  Serial.printf("  - IP (STA): %s (Bagli: %s, Sinyal: %d dBm, Calisma: %u sn, Deneme: %u)\r\n",
                sta ? WiFiManager::instance().getLocalIP().toString().c_str() : "Yok",
                sta ? "EVET" : "HAYIR",
                WiFiManager::instance().getRSSI(),
                (unsigned)WiFiManager::instance().getUptimeSeconds(),
                (unsigned)WiFiManager::instance().getReconnectCount());
  Serial.printf("  - Kurtarma/servis AP: %s (SSID: %s, IP: %s) | Ac/kapat: AP ON | AP OFF\r\n",
                WiFiManager::instance().isRecoveryApActive() ? "ACIK" : "KAPALI",
                WiFiManager::instance().getRecoveryApSSID().c_str(), WiFi.softAPIP().toString().c_str());
  Serial.printf("  - MQTTS (%s:%u): %s | Kimlik: %s\r\n",
                cfg.mqtt_server, (unsigned)cfg.mqtt_port,
                mq ? "BAGLI" : "BAGLANTI YOK",
                cfg.hasMqttCredentials() ? "tanimli" : "YOK (provizyon gerekli)");
  Serial.printf("  - Yerel anahtar (local_key): %s\r\n", cfg.hasLocalKey() ? "tanimli" : "YOK (provizyonsuz cihaz)");
  Serial.printf("  - Ek Modul: %s (Kanal: %d, Adres: %d, Yanit: %s)\r\n",
                cfg.ext_module_enabled ? "AKTIF" : "PASIF", cfg.ext_module_channels, cfg.ext_module_address,
                sa.isExtModuleResponding() ? "EVET" : "HAYIR");
  Serial.printf("  - Toplam Role: %d, Toplam DI: %d\r\n", cfg.totalRelays(), cfg.totalDIs());
  Serial.printf("  - Yigin (hic kullanilmayan en az bayt): loopTask=%u, ShutterGuard=%u\r\n",
                (unsigned)uxTaskGetStackHighWaterMark(NULL), (unsigned)sa.guardStackFreeBytes());
  Serial.printf("  - child_lock: %s\r\n", sa.isChildLockEnabled() ? "ON (duvar anahtarlari KILITLI; hareket halindeki panjur duvardan durdurulabilir)" : "OFF");

  Serial.printf("  - Yerel Roleler (8RO): [");
  for (int i = 0; i < 8; i++) {
    Serial.printf("R%d:%s%s", i + 1, (haveSnap && snap.relay(i)) ? "1" : "0", i < 7 ? " " : "");
  }
  Serial.printf("]\r\n");
  Serial.printf("  - Yerel Girisler (8DI): [");
  for (int i = 0; i < 8; i++) {
    Serial.printf("D%d:%s%s", i + 1, (haveSnap && snap.di(i)) ? "1" : "0", i < 7 ? " " : "");
  }
  Serial.printf("]\r\n");
  Serial.printf("  - Panjurlar: [");
  const int pairs = cfg.totalRelays() / 2;
  bool first = true;
  for (int p = 0; p < pairs && p < MAX_TOTAL_RELAYS / 2; p++) {
    if (!haveSnap || !snap.shutters[p].configured) continue;
    const ShutterSnapshot& st = snap.shutters[p];
    const char* dirStr = "DURDU";
    if (st.waiting) dirStr = (st.pendingDir == 1) ? "DEAD-TIME (YUKARI BEKLENIYOR)" : "DEAD-TIME (ASAGI BEKLENIYOR)";
    else if (st.moving && st.dir == 1) dirStr = "YUKARI HAREKET";
    else if (st.moving && st.dir == 2) dirStr = "ASAGI HAREKET";
    Serial.printf("%sP%d:%%%d [%s]", first ? "" : " | ", p + 1, st.pos, dirStr);
    first = false;
  }
  Serial.printf("]\r\n");
}

static void cliHelp() {
  Serial.printf("[CLI] Komutlar: STATUS, MQTT, MQTT PUB, RELAY <n> [ON|OFF|TOGGLE], RELAY ALL ON|OFF,\r\n");
  Serial.printf("      SHUTTER <n> UP|DOWN|STOP|STEP|POS <0-100>, SHUTTER ALL UP|DOWN|STOP, DI, CFG,\r\n");
  Serial.printf("      SET_DI <di> <hedef_role> <mod>, DEFAULT_DI, WIFI <ssid> <parola>, WIFI CLEAR,\r\n");
  Serial.printf("      EXTMOD <0|1> [kanal], SCAN, SCAN RESULT, CH <n> [ON|OFF|TOGGLE], SEND <hex>,\r\n");
  Serial.printf("      BAUD <baud>, CHILDLOCK [ON|OFF|STATUS], AP [ON|OFF|STATUS] (servis AP'si, 10 dk),\r\n");
  Serial.printf("      FACTORYINIT <local_key> <ap_pass> (yalniz PROVIZYONSUZ cihazda), RESETKEY (yerel anahtari siler), REBOOT\r\n");
}

// Gizli içerikli String'i bellekte sıfırla (yığın artığı kalmasın; Arduino String'i serbest bırakınca sıfırlamaz).
static void scrubString(String& s) {
  for (unsigned i = 0; i < s.length(); i++) s.setCharAt(i, '\0');
}

// Derleyicinin "ölü yazma" diye atlayamayacağı sıfırlama (gizli değer içeren yığın tamponları için).
static void secureZero(void* p, size_t n) {
  volatile uint8_t* v = (volatile uint8_t*)p;
  while (n--) *v++ = 0;
}

// ConfigManager::provisionIfEmpty sonucu -> seri FACTORYINIT yanıtı (fabrika aracı bu metinleri ayrıştırır; CONTRACTS §3c).
static const char* factoryInitReply(ConfigManager::ProvisionResult r) {
  switch (r) {
    case ConfigManager::PROVISION_OK:              return "OK factory_init";
    case ConfigManager::PROVISION_ALREADY:         return "ERR already_provisioned";
    case ConfigManager::PROVISION_INVALID_KEY:     return "ERR invalid_local_key";
    case ConfigManager::PROVISION_INVALID_AP_PASS: return "ERR invalid_ap_pass";
    default:                                       return "ERR persist_failed";   // NVS: cihaz provizyonsuz kalır
  }
}

static void handleCliLine(String cmd) {
  cmd.trim();
  if (cmd.isEmpty()) return;

  // Parolalı komutlar ASLA yankılanmaz (WIFI <ssid> <parola>). FACTORYINIT <local_key> <ap_pass> için HİÇBİR satır
  // yazılmaz: seri çıktıda yalnızca "OK factory_init" / "ERR <neden>" görünür (fabrika aracı bunu ayrıştırır).
  String first = cliWord(cmd, 0);
  if (eq(first, "FACTORYINIT")) {
    // (yankı yok)
  } else if (eq(first, "WIFI") && !eq(cliWord(cmd, 1), "CLEAR")) {
    Serial.printf("\r\n[CLI] Komut alindi: WIFI <ssid> <gizli>\r\n");
  } else {
    Serial.printf("\r\n[CLI] Komut alindi: %s\r\n", cmd.c_str());
  }

  auto& cfgMgr = ConfigManager::instance();
  auto& cfg = cfgMgr.config;
  auto& sa = SmartAutomation::instance();
  const int totalR = cfg.totalRelays();

  if (eq(first, "HELP") || cmd == "?") {
    cliHelp();
  } else if (eq(first, "STATUS")) {
    cliPrintStatus();
  } else if (eq(first, "MQTT")) {
    if (eq(cliWord(cmd, 1), "PUB")) {
      MqttManager::instance().triggerPublish();
      Serial.printf("[CLI-SONUC] MQTTS Durum Raporu Yayinlama Tetiklendi.\r\n");
    } else {
      bool mq = MqttManager::instance().isConnected();
      Serial.printf("[MQTTS DURUMU]\r\n");
      Serial.printf("  - Durum: %s\r\n", mq ? "BAGLI" : "BAGLI DEGIL / Yeniden Baglaniliyor");
      Serial.printf("  - Sunucu: %s:%u\r\n", cfg.mqtt_server, (unsigned)cfg.mqtt_port);
      Serial.printf("  - Kimlik: %s\r\n", cfg.hasMqttCredentials() ? "tanimli" : "YOK (MQTT baslamaz)");
    }
  } else if (eq(first, "RELAY")) {
    String sub = cliWord(cmd, 1);
    String act = cliWord(cmd, 2);
    if (eq(sub, "ALL")) {
      if (eq(act, "ON")) {
        // Yalnızca AYDINLATMA röleleri (panjur röleleri interlock'tan geçer; toplu AÇMA yok)
        int n = 0;
        for (int i = 0; i < totalR; i++) {
          if (cfg.relays[i].type == RELAY_TYPE_LIGHT) {
            postDeviceCommand(makeCommand(CmdType::RELAY_SET, CmdSource::CLI, (uint8_t)(i + 1), 1));
            n++;
          }
        }
        Serial.printf("[CLI-SONUC] %d aydinlatma rolesi acildi (ON).\r\n", n);
      } else if (eq(act, "OFF")) {
        postDeviceCommand(makeCommand(CmdType::ALL_LIGHTS_OFF, CmdSource::CLI));
        postDeviceCommand(makeCommand(CmdType::ALL_SHUTTERS_STOP, CmdSource::CLI));
        Serial.printf("[CLI-SONUC] Tum aydinlatmalar kapatildi, panjurlar durduruldu.\r\n");
      } else {
        Serial.printf("[CLI-HATA] Kullanim: RELAY <1-%d> [ON|OFF|TOGGLE] veya RELAY ALL [ON|OFF]\r\n", totalR);
      }
    } else {
      int rNum = sub.toInt();
      if (rNum >= 1 && rNum <= totalR) {
        if (eq(act, "ON")) postDeviceCommand(makeCommand(CmdType::RELAY_SET, CmdSource::CLI, (uint8_t)rNum, 1));
        else if (eq(act, "OFF")) postDeviceCommand(makeCommand(CmdType::RELAY_SET, CmdSource::CLI, (uint8_t)rNum, 0));
        else postDeviceCommand(makeCommand(CmdType::RELAY_TOGGLE, CmdSource::CLI, (uint8_t)rNum));
        Serial.printf("[CLI-SONUC] Role %d komutu kuyruga yazildi.\r\n", rNum);
      } else {
        Serial.printf("[CLI-HATA] Kullanim: RELAY <1-%d> [ON|OFF|TOGGLE] veya RELAY ALL [ON|OFF]\r\n", totalR);
      }
    }
  } else if (eq(first, "SHUTTER")) {
    String sub = cliWord(cmd, 1);
    String act = cliWord(cmd, 2);
    if (eq(sub, "ALL")) {
      if (eq(act, "UP")) { postDeviceCommand(makeCommand(CmdType::ALL_SHUTTERS_UP, CmdSource::CLI)); Serial.printf("[CLI-SONUC] Tum Panjurlar YUKARI komutu kuyruga yazildi.\r\n"); }
      else if (eq(act, "DOWN")) { postDeviceCommand(makeCommand(CmdType::ALL_SHUTTERS_DOWN, CmdSource::CLI)); Serial.printf("[CLI-SONUC] Tum Panjurlar ASAGI komutu kuyruga yazildi.\r\n"); }
      else if (eq(act, "STOP")) { postDeviceCommand(makeCommand(CmdType::ALL_SHUTTERS_STOP, CmdSource::CLI)); Serial.printf("[CLI-SONUC] Tum Panjurlar DURDURMA komutu kuyruga yazildi.\r\n"); }
      else Serial.printf("[CLI-HATA] Kullanim: SHUTTER ALL [UP|DOWN|STOP]\r\n");
    } else {
      int pNum = sub.toInt();
      if (pNum >= 1 && pNum <= totalR / 2) {
        uint8_t p = (uint8_t)pNum;
        if (eq(act, "POS")) {
          String v = cliWord(cmd, 3);
          int val = v.toInt();
          if (v.isEmpty() || val < 0 || val > 100) {
            Serial.printf("[CLI-HATA] POS icin 0-100 arasi deger zorunlu.\r\n");
          } else {
            postDeviceCommand(makeCommand(CmdType::SHUTTER_POS, CmdSource::CLI, p, val));
            Serial.printf("[CLI-SONUC] Panjur %d -> Hedef Pozisyon: %%%d komutu kuyruga yazildi.\r\n", pNum, val);
          }
        } else if (eq(act, "UP")) postDeviceCommand(makeCommand(CmdType::SHUTTER_UP, CmdSource::CLI, p));
        else if (eq(act, "DOWN")) postDeviceCommand(makeCommand(CmdType::SHUTTER_DOWN, CmdSource::CLI, p));
        else if (eq(act, "STOP")) postDeviceCommand(makeCommand(CmdType::SHUTTER_STOP, CmdSource::CLI, p));
        else if (eq(act, "STEP")) postDeviceCommand(makeCommand(CmdType::SHUTTER_STEP, CmdSource::CLI, p));
        else Serial.printf("[CLI-HATA] Kullanim: SHUTTER <1-%d> [UP|DOWN|STOP|STEP|POS <0-100>] veya SHUTTER ALL [UP|DOWN|STOP]\r\n", totalR / 2);
      } else {
        Serial.printf("[CLI-HATA] Kullanim: SHUTTER <1-%d> [UP|DOWN|STOP|STEP|POS <0-100>] veya SHUTTER ALL [UP|DOWN|STOP]\r\n", totalR / 2);
      }
    }
  } else if (eq(first, "DI") || eq(first, "INPUTS")) {
    AutomationSnapshot snap;
    bool have = sa.getSnapshot(snap);
    Serial.printf("[DI DURUMLARI (DGND ile Kuru Kontak)]\r\n");
    for (int i = 0; i < 8; i++) {
      bool st = have && snap.di(i);
      Serial.printf("  - DI-%d (GPIO %d): %s (Kontak %s)\r\n", i + 1, i + 4,
                    st ? "AKTIF (LOW)" : "PASIF (HIGH)", st ? "KAPALI / BIRLESIK" : "ACIK / SERBEST");
    }
  } else if (eq(first, "CFG") || eq(first, "CONFIG")) {
    Serial.printf("[YAPILANDIRMA BILGISI]\r\n");
    for (int i = 0; i < 8; i++) {
      Serial.printf("  - Role %d: '%s' (Tip: %d, Sure: %d)\r\n", i + 1, cfg.relays[i].name, cfg.relays[i].type, cfg.relays[i].runtime_sec);
    }
    for (int i = 0; i < 8; i++) {
      Serial.printf("  - DI %d: '%s' -> Hedef Role: %d (Mod: %d)\r\n", i + 1, cfg.dis[i].name, cfg.dis[i].target_relay, cfg.dis[i].mode);
    }
  } else if (eq(first, "SET_SHUTTER_DI") || eq(first, "DEFAULT_DI")) {
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

    bool ok = cfgMgr.save();
    Serial.printf("[CLI-SONUC] Panjur DI ayarlari (2 Kablolu Tek Buton: DI1->P1, DI2->Bosta) %s\r\n", ok ? "NVS'ye kaydedildi!" : "KAYDEDILEMEDI!");
  } else if (eq(first, "SET_DI")) {
    int di = cliWord(cmd, 1).toInt(), target = cliWord(cmd, 2).toInt(), mode = cliWord(cmd, 3).toInt();
    if (di >= 1 && di <= cfg.totalDIs() && target >= 0 && target <= totalR && mode >= 0 && mode <= DI_MODE_SHUTTER_DOWN &&
        !cliWord(cmd, 3).isEmpty()) {
      cfg.dis[di - 1].target_relay = (uint8_t)target;
      cfg.dis[di - 1].mode = (uint8_t)mode;
      bool ok = cfgMgr.save();
      Serial.printf("[CLI-SONUC] DI %d -> Hedef: Role %d, Mod: %d %s\r\n", di, target, mode, ok ? "NVS'ye kaydedildi!" : "KAYDEDILEMEDI!");
    } else {
      Serial.printf("[CLI-HATA] Kullanim: SET_DI <di 1-%d> <hedef_role 0-%d> <mod 0-4>\r\n", cfg.totalDIs(), totalR);
    }
  } else if (eq(first, "WIFI")) {
    if (eq(cliWord(cmd, 1), "CLEAR")) {
      memset(cfg.wifi_ssid, 0, sizeof(cfg.wifi_ssid));
      memset(cfg.wifi_pass, 0, sizeof(cfg.wifi_pass));
      cfg.wifi_sta_enabled = false;
      cfgMgr.save();
      WiFiManager::instance().setCredentials("", "");
      WiFi.disconnect(false, false);
      Serial.printf("[CLI-SONUC] Wi-Fi STA Bilgileri Temizlendi.\r\n");
    } else {
      // WIFI <ssid> <parola...>   (parola boşluk içerebilir; ekrana yazdırılmaz)
      String newSsid = cliWord(cmd, 1);
      String newPass = restFrom(cmd, 2);
      if (newSsid.isEmpty() || newSsid.length() > 32 || (newPass.length() != 0 && (newPass.length() < 8 || newPass.length() > 63))) {
        Serial.printf("[CLI-HATA] Kullanim: WIFI <ssid 1-32 bayt> <parola 8-63 karakter (acik ag icin bos birak)> veya WIFI CLEAR\r\n");
      } else {
        strncpy(cfg.wifi_ssid, newSsid.c_str(), sizeof(cfg.wifi_ssid) - 1);
        cfg.wifi_ssid[sizeof(cfg.wifi_ssid) - 1] = '\0';
        strncpy(cfg.wifi_pass, newPass.c_str(), sizeof(cfg.wifi_pass) - 1);
        cfg.wifi_pass[sizeof(cfg.wifi_pass) - 1] = '\0';
        cfg.wifi_sta_enabled = true;
        bool ok = cfgMgr.save();
        WiFiManager::instance().setCredentials(cfg.wifi_ssid, cfg.wifi_pass);
        Serial.printf("[CLI-SONUC] Yeni Wi-Fi Bilgileri %s: SSID='%s'\r\n", ok ? "NVS'ye Kaydedildi" : "KAYDEDILEMEDI", cfg.wifi_ssid);
      }
      scrubString(newPass);
      scrubString(cmd);
    }
  } else if (eq(first, "EXTMOD")) {
    // EXTMOD 1 8   veya   EXTMOD 0
    String a = cliWord(cmd, 1);
    String c = cliWord(cmd, 2);
    bool en = (a.toInt() == 1);
    int ch = c.isEmpty() ? 8 : c.toInt();
    if (a.isEmpty() || (en && !isValidExtChannelCount((uint8_t)ch)) || ch < 0 || ch > 255) {
      Serial.printf("[CLI-HATA] Kullanim: EXTMOD <0|1> [kanal: 2,4,8,12,16,24,32]\r\n");
    } else {
      cfg.ext_module_enabled = en;
      cfg.ext_module_channels = en ? (uint8_t)ch : cfg.ext_module_channels;
      bool ok = cfgMgr.save();
      Serial.printf("[CLI-SONUC] Ek Modul: %s, Kanal: %d -> Toplam Role: %d, Toplam DI: %d (%s)\r\n",
                    en ? "AKTIF" : "PASIF", cfg.ext_module_channels, cfg.totalRelays(), cfg.totalDIs(),
                    ok ? "NVS'ye Kaydedildi!" : "KAYDEDILEMEDI!");
    }
  } else if (eq(first, "SCAN") || eq(first, "TEST")) {
    if (eq(cliWord(cmd, 1), "RESULT")) {
      auto st = sa.rs485ScanState();
      if (st == SmartAutomation::ScanState::RUNNING) {
        Serial.printf("[CLI-SONUC] Tarama suruyor...\r\n");
      } else if (st == SmartAutomation::ScanState::IDLE) {
        Serial.printf("[CLI-SONUC] Henuz tarama yapilmadi (SCAN ile baslatin).\r\n");
      } else {
        auto res = sa.rs485ScanResult();
        if (res.found) {
          Serial.printf("[CLI-SONUC] BASARILI! Harici Modul Tespit Edildi:\r\n");
          Serial.printf("  - Slave Adresi: %d\r\n", res.slaveId);
          Serial.printf("  - Baud Rate: %u\r\n", (unsigned)res.baud);
          Serial.printf("  - Role Durumlari: 0x%02X\r\n", res.relayStatus);
          Serial.printf("  - Ham Yanit: %s\r\n", res.rawHex.c_str());
          Serial.printf("  - Bilgi: %s\r\n", res.info.c_str());
        } else {
          Serial.printf("[CLI-SONUC] BASARISIZ: %s\r\n", res.info.c_str());
          Serial.printf("  - Lutfen RS485 A+ ve B- klemens baglantisini kontrol edin.\r\n");
          Serial.printf("  - Harici modulun 12V/24V beslemesinin takili oldugundan emin olun.\r\n");
        }
      }
    } else {
      // Bloklamaz: tarama ayrı görevde çalışır (panjur zamanlayıcıları etkilenmez)
      bool started = sa.rs485StartScan();
      Serial.printf("[CLI-SONUC] %s Sonuc icin: SCAN RESULT\r\n", started ? "RS485 taramasi baslatildi." : "Tarama baslatilamadi (zaten suruyor ya da ek modul panjuru hareket halinde).");
    }
  } else if (eq(first, "CH")) {
    int ch = cliWord(cmd, 1).toInt();
    String act = cliWord(cmd, 2);
    if (ch < 1 || ch > 32) {
      Serial.printf("[CLI-HATA] Kullanim: CH <1-32> [ON|OFF|TOGGLE]\r\n");
    } else {
      uint8_t action = 2;                       // varsayılan TOGGLE
      if (eq(act, "ON")) action = 1;
      else if (eq(act, "OFF")) action = 0;
      String resp;
      bool ok = sa.rs485ControlExtRelay(cfg.ext_module_address, (uint8_t)ch, action, &resp);
      Serial.printf("[CLI-SONUC] Role %d (Eylem %d) -> %s (Yanit: %s)\r\n", ch, action, ok ? "BASARILI" : "BASARISIZ/REDDEDILDI", resp.c_str());
    }
  } else if (eq(first, "SEND")) {
    String hexData = restFrom(cmd, 1);
    hexData.trim();
    bool ok = sa.rs485Send(hexData, true);
    Serial.printf("[CLI-SONUC] RS485 gonderim: %s\r\n", ok ? "tamam" : "reddedildi/basarisiz (RS485 terminal gunlugune bakin)");
  } else if (eq(first, "BAUD")) {
    uint32_t b = (uint32_t)cliWord(cmd, 1).toInt();
    if (b == 4800 || b == 9600 || b == 19200 || b == 38400 || b == 57600 || b == 115200) {
      cfg.rs485_baud = b;
      bool ok = cfgMgr.save();
      sa.rs485Begin(b);
      Serial.printf("[CLI-SONUC] Baud %u olarak ayarlandi (%s).\r\n", (unsigned)b, ok ? "kaydedildi" : "KAYDEDILEMEDI");
    } else {
      Serial.printf("[CLI-HATA] Gecerli baud: 4800, 9600, 19200, 38400, 57600, 115200\r\n");
    }
  } else if (eq(first, "CHILDLOCK") || eq(first, "CHILD_LOCK")) {
    // Fiziksel kaçış yolu: telefon/bulut yokken kilit buradan açılabilir (komut kuyruğu -> Core 1).
    String a = cliWord(cmd, 1);
    if (a.isEmpty() || eq(a, "STATUS")) {
      Serial.printf("[CLI-SONUC] child_lock: %s\r\n", sa.isChildLockEnabled() ? "ON" : "OFF");
    } else if (eq(a, "ON") || eq(a, "OFF")) {
      const bool on = eq(a, "ON");
      if (postDeviceCommand(makeCommand(CmdType::SET_CHILD_LOCK, CmdSource::CLI, 0, on ? 1 : 0))) {
        Serial.printf("[CLI-SONUC] Cocuk kilidi %s komutu kuyruga yazildi (durum: CHILDLOCK STATUS).\r\n", on ? "ON" : "OFF");
      } else {
        Serial.printf("[CLI-HATA] Komut kuyrugu dolu veya hazir degil, tekrar deneyin.\r\n");
      }
    } else {
      Serial.printf("[CLI-HATA] Kullanim: CHILDLOCK [ON|OFF|STATUS]\r\n");
    }
  } else if (eq(first, "AP")) {
    // Servis modu (CONTRACTS §3): AP'yi süreli (10 dk) açar/kapatır. Fiziksel (seri) erişim yetkidir.
    // Parola ASLA yazdırılmaz. Provizyonlu cihaz AP'yi yalnızca geçerli ap_pass (>= 8 karakter) varsa açar.
    String a = cliWord(cmd, 1);
    auto& wm = WiFiManager::instance();
    bool apAllowed;
    {
      ConfigManager::ConfigLock lk(cfgMgr);
      apAllowed = !cfg.hasLocalKey() || strlen(cfg.ap_pass) >= AP_PASS_MIN_LEN;
    }
    if (a.isEmpty() || eq(a, "STATUS")) {
      Serial.printf("[CLI-SONUC] AP: %s | SSID: %s | Acilabilir: %s%s\r\n", wm.isRecoveryApActive() ? "ACIK" : "KAPALI",
                    wm.getRecoveryApSSID().c_str(), apAllowed ? "EVET" : "HAYIR",
                    apAllowed ? "" : " (provizyonlu cihazda gecerli ap_pass yok)");
    } else if (eq(a, "ON")) {
      if (!apAllowed) {
        Serial.printf("[CLI-HATA] AP acilmaz: cihaz provizyonlu ama gecerli ap_pass (>= %d karakter) tanimli degil.\r\n", AP_PASS_MIN_LEN);
      } else {
        wm.openServiceAp();      // varsayılan pencere: 10 dk (WiFiManager::SERVICE_AP_WINDOW_MS)
        Serial.printf("[CLI-SONUC] Servis AP'si istendi (%u dk): SSID %s. Durum icin: AP\r\n",
                      (unsigned)(WiFiManager::SERVICE_AP_WINDOW_MS / 60000), wm.getRecoveryApSSID().c_str());
      }
    } else if (eq(a, "OFF")) {
      wm.stopRecoveryAP();
      Serial.printf("[CLI-SONUC] AP kapatildi.\r\n");
    } else {
      Serial.printf("[CLI-HATA] Kullanim: AP [ON|OFF|STATUS]\r\n");
    }
  } else if (eq(first, "FACTORYINIT")) {
    // USB-seri fabrika provizyonu: local_key + ap_pass (CONTRACTS §3). Satır/parametreler ASLA yankılanmaz veya
    // loglanmaz; seri çıktıda yalnızca "OK factory_init" veya "ERR <neden>" görünür. YALNIZCA provizyonsuz cihazda
    // çalışır. Kaba kuvvet için ek kilit gerekmez (fiziksel/USB erişim yetkidir); doğrulama sıkıdır (CliParse.h).
    char key[LOCAL_KEY_MAX_LEN + 1];
    char pass[AP_PASS_MAX_LEN + 1];
    secureZero(key, sizeof(key));
    secureZero(pass, sizeof(pass));
    {
      // Denetim + yazma, ConfigManager::provisionIfEmpty içinde TEK kilit altındadır ve HTTP POST /api/factory/init de
      // AYNI yöntemi kullanır: iki yol yarışamaz (önce yazan kazanır, diğeri already_provisioned alır). Buradaki dış kilit
      // ayrıştırmadaki "provizyonlu mu" okumasını da aynı bölüme alır (özyinelemeli mutex).
      ConfigManager::ConfigLock lk(cfgMgr);
      const cliparse::FactoryInitStatus st =
          cliparse::parseFactoryInit(cmd.c_str(), cfg.hasLocalKey(), key, sizeof(key), pass, sizeof(pass));
      if (st != cliparse::FI_OK) {
        Serial.printf("ERR %s\r\n", cliparse::factoryInitErrorText(st));
      } else {
        // Önce ap_pass, sonra local_key; local_key yazılamazsa ap_pass geri alınır, cihaz PROVİZYONSUZ kalır (yeniden denenebilir).
        const ConfigManager::ProvisionResult pr = cfgMgr.provisionIfEmpty(key, pass);
        if (pr == ConfigManager::PROVISION_OK) WiFiManager::instance().applyApConfigChange();   // AP ilkesi WPA2 + ap_pass'e döner
        Serial.printf("%s\r\n", factoryInitReply(pr));
      }
    }
    secureZero(key, sizeof(key));
    secureZero(pass, sizeof(pass));
    scrubString(cmd);
  } else if (eq(first, "RESETKEY")) {
    // Fiziksel erişimle kurtarma yolu (CONTRACTS §3): yerel anahtarı siler; cihaz "provizyonsuz" olur. Yeniden
    // anahtarlama TERCİHEN aynı seri hattan FACTORYINIT ile yapılır (anahtar kablosuz ağdan geçmez); yedek yol açık
    // kurulum AP'si üzerinden POST /api/factory/init'tir. Fabrika aracı yanıtta "Yerel anahtar SILINDI|SILINEMEDI" arar.
    bool ok = cfgMgr.clearLocalKey();
    if (ok) WiFiManager::instance().applyApConfigChange();   // provizyon durumu değişti: AP ilkesi hemen yeniden değerlendirilir
    Serial.printf("[CLI-SONUC] Yerel anahtar %s. Cihaz artik PROVIZYONSUZ (FACTORYINIT <local_key> <ap_pass> ya da "
                  "/api/factory/init). AP gerekirse: AP ON\r\n",
                  ok ? "SILINDI" : "SILINEMEDI");
  } else if (eq(first, "REBOOT") || eq(first, "RESTART")) {
    Serial.printf("[CLI-SONUC] Panjurlar durdurulup cihaz yeniden baslatiliyor...\r\n");
    sa.requestRestart(300);
  } else {
    Serial.printf("[CLI] Bilinmeyen komut: '%s'. (HELP yazin)\r\n", first.c_str());
  }
}

static void handleSerialCli() {
  static char line[160];
  static size_t len = 0;
  static bool overflow = false;

  // Bloklamadan: yalnızca o an hazır olan baytlar okunur
  int budget = 128;
  while (Serial.available() && budget-- > 0) {
    int c = Serial.read();
    if (c < 0) break;
    if (c == '\n' || c == '\r') {
      if (len > 0 && !overflow) {
        line[len] = '\0';
        handleCliLine(String(line));
      } else if (overflow) {
        Serial.printf("[CLI-HATA] Satir cok uzun (en cok %u karakter).\r\n", (unsigned)(sizeof(line) - 1));
      }
      secureZero(line, sizeof(line));   // gizli içerikli satır (FACTORYINIT/WIFI) RAM'de kalmasın
      len = 0;
      overflow = false;
    } else if (len < sizeof(line) - 1) {
      line[len++] = (char)c;
    } else {
      overflow = true;
    }
  }
}

void loop() {
  esp_task_wdt_reset();                 // TWDT: loopTask her turda beslenir (bir tur en çok birkaç yüz ms sürer)
  handleSerialCli();
  SmartAutomation::instance().loop();
  WebPortal::instance().loop();
  vTaskDelay(pdMS_TO_TICKS(5));
}
