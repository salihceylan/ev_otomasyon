#include "WiFiManager.h"
#include "ConfigManager.h"

WiFiManager::WiFiManager()
    : _mutex(nullptr)
    , _connected(false)
    , _localIP()
    , _gatewayIP()
    , _rssi(-100)
    , _ssid("")
    , _pass("")
    , _reconnectCount(0)
    , _connectTimestamp(0)
    , _disconnectedSince(0)
    , _recoveryApActive(false)
    , _recoveryApSsid("")
    , _backoffSeconds(MIN_BACKOFF_SEC)
    , _taskHandle(nullptr)
    , _shouldReconnect(false)
{
}

void WiFiManager::begin() {
    if (_mutex == nullptr) {
        _mutex = xSemaphoreCreateMutex();
    }
    printf("[WiFiManager] Endustriyel Wi-Fi Yoneticisi Baslatiliyor (Core 0)...\r\n");

    // NVS'den kaydedilmiş Wi-Fi bilgilerini oku
    auto& cfg = ConfigManager::instance().config;
    if (cfg.wifi_sta_enabled && strlen(cfg.wifi_ssid) > 0) {
        _ssid = String(cfg.wifi_ssid);
        _pass = String(cfg.wifi_pass);
        _disconnectedSince = millis(); // Açılışta STA bağlantısı için 3 dakikalık sayaç başlar
        printf("[WiFiManager] NVS'den okunan SSID: '%s'\r\n", _ssid.c_str());
    } else {
        printf("[WiFiManager] NVS'de tanimli STA Wi-Fi bulunamadi, yalnizca AP modu aktif.\r\n");
    }

    // Wi-Fi olay dinleyicisi (ESP-IDF event loop)
    WiFi.onEvent([this](WiFiEvent_t event, WiFiEventInfo_t info) {
        this->onWiFiEvent(event, info);
    });

    // Core 0'da calisacak baglanti yonetim gorevi
    xTaskCreatePinnedToCore(
        wifiTask,
        "wifi_task",
        4096,
        this,
        1,
        &_taskHandle,
        0 // Core 0
    );
}

void WiFiManager::setCredentials(const char* ssid, const char* pass) {
    if (_mutex && xSemaphoreTake(_mutex, pdMS_TO_TICKS(100)) == pdTRUE) {
        _ssid = String(ssid);
        _pass = String(pass);
        _shouldReconnect = true;
        _backoffSeconds = MIN_BACKOFF_SEC;
        xSemaphoreGive(_mutex);
    }
}

void WiFiManager::triggerReconnect() {
    _shouldReconnect = true;
}

void WiFiManager::onWiFiEvent(WiFiEvent_t event, WiFiEventInfo_t info) {
    switch (event) {
        case ARDUINO_EVENT_WIFI_STA_START:
            printf("[WiFi Event] STA Arayuzu Baslatildi.\r\n");
            break;

        case ARDUINO_EVENT_WIFI_STA_CONNECTED:
            printf("[WiFi Event] Erisim Noktasina Baglandi: BSSID: %02X:%02X:%02X:%02X:%02X:%02X | Kanal: %d\r\n",
                   info.wifi_sta_connected.bssid[0], info.wifi_sta_connected.bssid[1],
                   info.wifi_sta_connected.bssid[2], info.wifi_sta_connected.bssid[3],
                   info.wifi_sta_connected.bssid[4], info.wifi_sta_connected.bssid[5],
                   info.wifi_sta_connected.channel);
            break;

        case ARDUINO_EVENT_WIFI_STA_GOT_IP:
            if (_mutex && xSemaphoreTake(_mutex, pdMS_TO_TICKS(100)) == pdTRUE) {
                _connected = true;
                _disconnectedSince = 0;
                _localIP = WiFi.localIP();
                _gatewayIP = WiFi.gatewayIP();
                _rssi = WiFi.RSSI();
                _connectTimestamp = millis();
                _backoffSeconds = MIN_BACKOFF_SEC; // Başarılı bağlantıda backoff sıfırlanır
                xSemaphoreGive(_mutex);
            }
            if (_recoveryApActive) {
                stopRecoveryAP();
            }
            printf("[WiFi Event] IP Alindi: %s | Gateway: %s | Sinyal: %d dBm\r\n",
                   WiFi.localIP().toString().c_str(),
                   WiFi.gatewayIP().toString().c_str(),
                   WiFi.RSSI());
            break;

        case ARDUINO_EVENT_WIFI_STA_DISCONNECTED:
            if (_mutex && xSemaphoreTake(_mutex, pdMS_TO_TICKS(100)) == pdTRUE) {
                _connected = false;
                if (_disconnectedSince == 0) {
                    _disconnectedSince = millis();
                }
                _localIP = IPAddress(0, 0, 0, 0);
                xSemaphoreGive(_mutex);
            }
            printf("[WiFi Event] Baglanti Koptu! Neden Kodu: %d. Yeniden baglanma dongusu devrede.\r\n",
                   info.wifi_sta_disconnected.reason);
            break;

        default:
            break;
    }
}

void WiFiManager::wifiTask(void* parameter) {
    WiFiManager* self = static_cast<WiFiManager*>(parameter);

    while (true) {
        String currentSsid = "";
        String currentPass = "";
        bool isConn = false;

        if (self->_mutex && xSemaphoreTake(self->_mutex, pdMS_TO_TICKS(100)) == pdTRUE) {
            currentSsid = self->_ssid;
            currentPass = self->_pass;
            isConn = self->_connected;
            xSemaphoreGive(self->_mutex);
        }

        // Eğer SSID tanımlı ve bağlı değilsek (veya manuel yeniden bağlanma istendiyse)
        if (!currentSsid.isEmpty() && (!isConn || self->_shouldReconnect)) {
            self->_shouldReconnect = false;

            if (self->_mutex && xSemaphoreTake(self->_mutex, pdMS_TO_TICKS(100)) == pdTRUE) {
                self->_reconnectCount++;
                xSemaphoreGive(self->_mutex);
            }

            printf("[WiFiManager] STA Baglantisi Kuruluyor... SSID: '%s' (Deneme: %u, Bekleme: %u sn)\r\n",
                   currentSsid.c_str(), self->_reconnectCount, self->_backoffSeconds);

            WiFi.begin(currentSsid.c_str(), currentPass.c_str());

            // Non-blocking bağlantı bekleme (her 250ms kontrol, max 10 saniye)
            uint32_t waitStart = millis();
            while (WiFi.status() != WL_CONNECTED && (millis() - waitStart < 10000)) {
                vTaskDelay(pdMS_TO_TICKS(250));
            }

            if (WiFi.status() == WL_CONNECTED) {
                printf("[WiFiManager] Baglanti Basarili! IP: %s\r\n", WiFi.localIP().toString().c_str());
                // SNTP (NTP) Zaman Senkronizasyonu (Türkiye UTC+3)
                configTime(3 * 3600, 0, "pool.ntp.org", "time.google.com");
                printf("[WiFiManager] SNTP Zaman Senkronizasyonu Baslatildi (UTC+3)\r\n");
            } else {
                printf("[WiFiManager] Baglanti Saglanamadi! %u saniye sonra tekrar denenecek (Exponential Backoff).\r\n",
                       self->_backoffSeconds);

                // KRİTİK: Bağlantı başarısız olduğunda STA taramasını ve kanal değişimini durdur!
                // Böylece SoftAP (Hotspot) kesintisiz ve temiz yayınına devam eder!
                WiFi.disconnect(false, false);
                WiFi.mode(WIFI_AP_STA);

                // Exponential Backoff: Süreyi 2 katına çıkar (max 60 saniye)
                vTaskDelay(pdMS_TO_TICKS(self->_backoffSeconds * 1000));
                self->_backoffSeconds = min(self->_backoffSeconds * 2, MAX_BACKOFF_SEC);
                continue;
            }
        }

        // ADIM 14: Wi-Fi kesintisi 3 dakikayı aştığında Smart AP Fallback (Kurtarma Modu) başlat
        if (WiFi.status() != WL_CONNECTED && self->_disconnectedSince > 0) {
            uint32_t elapsed = millis() - self->_disconnectedSince;
            if (elapsed >= RECOVERY_TRIGGER_MS && !self->_recoveryApActive) {
                self->startRecoveryAP();
            }
        }

        // Bağlıyken sinyal gücünü periyodik güncelle (her 5 saniyede bir)
        if (WiFi.status() == WL_CONNECTED) {
            if (self->_mutex && xSemaphoreTake(self->_mutex, pdMS_TO_TICKS(100)) == pdTRUE) {
                self->_rssi = WiFi.RSSI();
                xSemaphoreGive(self->_mutex);
            }
        }

        vTaskDelay(pdMS_TO_TICKS(5000));
    }
}

bool WiFiManager::isConnected() {
    if (_mutex && xSemaphoreTake(_mutex, pdMS_TO_TICKS(20)) == pdTRUE) {
        bool c = _connected;
        xSemaphoreGive(_mutex);
        return c;
    }
    return (WiFi.status() == WL_CONNECTED);
}

IPAddress WiFiManager::getLocalIP() {
    IPAddress ip(0, 0, 0, 0);
    if (_mutex && xSemaphoreTake(_mutex, pdMS_TO_TICKS(20)) == pdTRUE) {
        ip = _localIP;
        xSemaphoreGive(_mutex);
    }
    return ip;
}

IPAddress WiFiManager::getGatewayIP() {
    IPAddress gw(0, 0, 0, 0);
    if (_mutex && xSemaphoreTake(_mutex, pdMS_TO_TICKS(20)) == pdTRUE) {
        gw = _gatewayIP;
        xSemaphoreGive(_mutex);
    }
    return gw;
}

int8_t WiFiManager::getRSSI() {
    int8_t r = -100;
    if (_mutex && xSemaphoreTake(_mutex, pdMS_TO_TICKS(20)) == pdTRUE) {
        r = _rssi;
        xSemaphoreGive(_mutex);
    }
    return r;
}

String WiFiManager::getSSID() {
    String s = "";
    if (_mutex && xSemaphoreTake(_mutex, pdMS_TO_TICKS(20)) == pdTRUE) {
        s = _ssid;
        xSemaphoreGive(_mutex);
    }
    return s;
}

String WiFiManager::getMacAddress() {
    return WiFi.macAddress();
}

uint32_t WiFiManager::getReconnectCount() {
    uint32_t c = 0;
    if (_mutex && xSemaphoreTake(_mutex, pdMS_TO_TICKS(20)) == pdTRUE) {
        c = _reconnectCount;
        xSemaphoreGive(_mutex);
    }
    return c;
}

uint32_t WiFiManager::getUptimeSeconds() {
    if (!isConnected() || _connectTimestamp == 0) return 0;
    return (millis() - _connectTimestamp) / 1000;
}

uint32_t WiFiManager::getLastConnectTime() {
    return _connectTimestamp;
}

// ==============================================================================
// ADIM 14: Wi-Fi Şifre Değişimi Kurtarma Modu (Smart AP Fallback)
// ==============================================================================
void WiFiManager::startRecoveryAP() {
    auto& cfg = ConfigManager::instance().config;
    String idSuffix = "";
    if (strlen(cfg.device_name) > 0 && strcmp(cfg.device_name, "AHBU Pano") != 0 && strcmp(cfg.device_name, "ESP32-S3-POE-ETH-8DI-8RO") != 0) {
        idSuffix = String(cfg.device_name);
    } else {
        String mac = WiFi.macAddress();
        mac.replace(":", "");
        if (mac.length() >= 4) {
            idSuffix = mac.substring(mac.length() - 4);
        } else {
            idSuffix = "Daire";
        }
    }

    _recoveryApSsid = "AHBU-Kurtarma-" + idSuffix;
    _recoveryApActive = true;

    printf("\r\n=======================================================\r\n");
    printf("[WiFiManager] ⚠️ ADIM 14: Wi-Fi Baglantisi 3 Dakika Saglanamadi!\r\n");
    printf("[WiFiManager] 🚀 SMART AP FALLBACK (Kurtarma Modu) Baslatildi: '%s'\r\n", _recoveryApSsid.c_str());
    printf("[WiFiManager] Sifre: 'ahbu1234' | Web Arayuzu: http://192.168.4.1\r\n");
    printf("=======================================================\r\n\r\n");

    IPAddress local_ip(192, 168, 4, 1);
    IPAddress gateway(192, 168, 4, 1);
    IPAddress subnet(255, 255, 255, 0);
    WiFi.softAPConfig(local_ip, gateway, subnet);
    WiFi.mode(WIFI_AP_STA);
    WiFi.softAP(_recoveryApSsid.c_str(), "ahbu1234", 1);
}

void WiFiManager::stopRecoveryAP() {
    _recoveryApActive = false;
    printf("[WiFiManager] ✅ STA Baglantisi Kuruldu, Kurtarma Modu Kapatiliyor.\r\n");
    WiFi.softAP("ESP32-S3-POE-ETH-8DI-8RO", "waveshare", 1);
}

bool WiFiManager::isRecoveryApActive() {
    return _recoveryApActive;
}

String WiFiManager::getRecoveryApSSID() {
    return _recoveryApSsid;
}

