#pragma once

#include <Arduino.h>
#include <WiFi.h>
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>
#include <freertos/semphr.h>

class WiFiManager {
public:
    static WiFiManager& instance() {
        static WiFiManager inst;
        return inst;
    }

    void begin();
    void setCredentials(const char* ssid, const char* pass);

    // Thread-safe durum sorgulama fonksiyonları (Core 0 ve Core 1'den çağrılabilir)
    bool isConnected();
    IPAddress getLocalIP();
    IPAddress getGatewayIP();
    int8_t getRSSI();
    String getSSID();
    String getMacAddress();
    uint32_t getReconnectCount();
    uint32_t getUptimeSeconds();
    uint32_t getLastConnectTime();

    // ADIM 14: Smart AP Fallback (Kurtarma Modu)
    bool isRecoveryApActive();
    String getRecoveryApSSID();
    void startRecoveryAP();
    void stopRecoveryAP();

    // Manuel yeniden bağlanma tetikleyici
    void triggerReconnect();

private:
    WiFiManager();
    ~WiFiManager() = default;
    WiFiManager(const WiFiManager&) = delete;
    WiFiManager& operator=(const WiFiManager&) = delete;

    static void wifiTask(void* parameter);
    void onWiFiEvent(WiFiEvent_t event, WiFiEventInfo_t info);

    // Durum değişkenleri (Mutex ile korunur)
    SemaphoreHandle_t _mutex;
    bool _connected;
    IPAddress _localIP;
    IPAddress _gatewayIP;
    int8_t _rssi;
    String _ssid;
    String _pass;
    uint32_t _reconnectCount;
    uint32_t _connectTimestamp;

    // ADIM 14: 3 dakika bağlanamazsa Smart AP Fallback
    uint32_t _disconnectedSince;
    bool _recoveryApActive;
    String _recoveryApSsid;
    static constexpr uint32_t RECOVERY_TRIGGER_MS = 180000; // 3 dakika kesinti
    
    // Exponential backoff
    uint32_t _backoffSeconds;
    static constexpr uint32_t MIN_BACKOFF_SEC = 2;
    static constexpr uint32_t MAX_BACKOFF_SEC = 60;
    
    TaskHandle_t _taskHandle;
    volatile bool _shouldReconnect;
};

