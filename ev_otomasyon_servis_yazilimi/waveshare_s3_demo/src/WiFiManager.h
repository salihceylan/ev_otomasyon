#pragma once

#include <Arduino.h>
#include <WiFi.h>
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>
#include <freertos/semphr.h>
#include "NetTime.h"

// Firmware surumu (state JSON "fw", GET /api/status, MQTT durumu "fw"). platformio.ini'de -DFW_VERSION=\"x.y.z\" ile
// gecersiz kilinabilir. 1.1.1: yalniz gomulu web arayuzu degisti (WebPortalPage.h: yeni gorunum + kalici cihaz anahtari);
// Wi-Fi/MQTT/guvenlik davranisi 1.1.0 ile aynidir. 1.1.2: provizyon yolu -- factory/init + rekey NVS yazma hatasinda
// 503 "storage", atomik ConfigManager::provisionIfEmpty (seri FACTORYINIT ile ortak; TOCTOU yok), RESETKEY metni;
// gomulu web sayfasi metinleri (anahtar ipucu, provizyon formu uyarisi) duzeltildi. 1.2.0: guvenlik katmani (su baskini + vana;
// SafetyManager, ValveGuard), state v:3 (v:2 ust kumesi), ev/{t}/event + event_ack, zorunlu uid, sys cfg_get/cfg_patch (1024 bayt),
// yerel guvenlik uclari (/api/actuator, /api/alarm/*, /api/events, /api/safety/config), kilitliyken reboot/reset force ister.
// 1.2.1 (Faz 2): kapi/pencere/hareket hirsiz alarmi (kip off/home/away, cikis/giris gecikmesi, ARM_KEY, caps "intrusion", state safety.arm,
// intrusion_alarm/intrusion_cleared/arm_changed olaylari, POST /api/arm, CLI ARM), siren VEYA'si (ayri butce), ContactBus; sys cfg_patch
// basarisinda last_id yankisi ve "cfg_storage" ret kodu.
#ifndef FW_VERSION
#define FW_VERSION "1.2.1"
#endif

// ============================================================================
// WiFiManager - STA baglantisi, kurtarma/kurulum AP'si ve SNTP (docs/CONTRACTS.md Bolum 3).
//
// - Tek WiFi.begin() sahibi bu siniftir (WebPortal dogrudan WiFi.begin cagirmaz).
// - Kimlik bilgisi (SSID/parola) yalnizca baglanti DOGRULANINCA (GOT_IP) NVS'e islenir.
// - AP: SSID "AHBU-<MAC son 6>", parola cihaza ozel "ap_pass" (NVS). Sabit/varsayilan parola YOKTUR.
//   * STA bagliyken AP kapalidir. Baglanti 3 dk kesilirse (veya hic STA tanimli degilse) 10 dk'lik bir
//     kurtarma penceresi acilir; STA 30 sn kararli baglanirsa pencere erken kapanir.
//   * Provizyonsuz cihaz (local_key yok) bu pencerede ACIK (parolasiz) AP yayinlar; yalnizca
//     POST /api/factory/init ve kisitli /api/status calisir. Provizyonlu ama ap_pass'i olmayan cihaz
//     asla AP acmaz.
// - Cekirdek: Core 0 (wifi_task). Disaridan her cagri is parcacigi guvenlidir.
// - ZAMAN KURALI (N6, CONTRACTS 3c): tum zamanlayicilar NetTime.h'deki "son olay + bekleme" ciftleridir ve yalnizca
//   wifi_task'ta degistirilir; diger gorevler istek bayragi (volatile bool) birakir. Saklanmis hedef zaman YOKTUR.
// ============================================================================
class WiFiManager {
public:
    // Zamanlama sabitleri (ms): tek kaynak NetTime.h. arduino-esp32 C++11 ile derlenir: static constexpr uye yerine
    // enum kullanilir (ODR-use sorunu ve tanim gerektirmez).
    enum : uint32_t {
        RECOVERY_TRIGGER_MS = NetUtil::ApPolicy::RECOVERY_TRIGGER_MS,   // 3 dk kesinti -> kurtarma AP penceresi
        SERVICE_AP_WINDOW_MS = NetUtil::ApPolicy::WINDOW_MS,            // AP penceresi: 10 dk
        AP_REOPEN_MS = NetUtil::ApPolicy::REOPEN_MS,                    // pencere bitince, kesinti suruyorsa yeniden acmadan once bekleme
        AP_MAX_EXTEND_MS = NetUtil::ApPolicy::MAX_EXTEND_MS,            // istemci bagliyken pencere en fazla 30 dk uzar
        STA_STABLE_MS = NetUtil::ApPolicy::STABLE_MS,                   // STA bu kadar kararli olunca kurtarma AP'si kapanir
        MIN_BACKOFF_MS = NetUtil::StaMachine::MIN_BACKOFF_MS,
        MAX_BACKOFF_MS = NetUtil::StaMachine::MAX_BACKOFF_MS
    };

    static WiFiManager& instance() {
        static WiFiManager inst;
        return inst;
    }

    void begin();

    // ---------------- STA kimligi ----------------
    // Dogrudan atama (seri CLI / geri uyumluluk): cagiran NVS kaydini kendisi yapmis olmalidir.
    // Bos ssid = kimligi RAM'den temizle ve baglantiyi kes.
    void setCredentials(const char* ssid, const char* pass);

    // Aday kimlik (POST /api/wifi/connect): SSID 1..32 bayt, parola 0 veya 8..63 bayt.
    // Kimlik RAM'de tutulur; HTTP yaniti cikabilsin diye ~0.5 sn sonra baglanilir; GOT_IP olunca NVS'e
    // islenir, zaman asimi/hata olursa eski kimlige donulur.
    enum class ConnectRequest : uint8_t { ACCEPTED = 0, INVALID_SSID, INVALID_PASS, BUSY };
    ConnectRequest requestConnect(const char* ssid, const char* pass);

    enum class ConnectState : uint8_t { IDLE = 0, CONNECTING, SUCCESS, FAILED };
    struct ConnectStatus {
        ConnectState state;   // son aday denemesinin durumu
        uint8_t reason;       // FAILED ise son kopma nedeni (wifi_err_reason_t), 0 = bilinmiyor/zaman asimi
    };
    ConnectStatus getConnectStatus();

    // Kayitli STA kimligini (RAM + NVS) siler, baglantiyi keser, otomatik baglanmayi durdurur.
    bool clearCredentials();

    // Manuel yeniden baglanma (geri cekilme sayacini sifirlar)
    void triggerReconnect();

    // ---------------- Durum (Core 0 ve Core 1'den cagrilabilir) ----------------
    bool isConnected();
    bool isConnecting();
    IPAddress getLocalIP();
    IPAddress getGatewayIP();
    int8_t getRSSI();
    String getSSID();
    String getMacAddress();
    uint32_t getReconnectCount();
    uint32_t getUptimeSeconds();
    uint32_t getLastConnectTime();   // son GOT_IP'nin millis() damgasi (yalniz bilgi; karsilastirilmaz)
    // Son STA kopma nedeni (wifi_err_reason_t). 0 = hata yok / yeni deneme basladi.
    // Servis uygulamasi yanlis sifre (2, 15, 202, 204) ve ag bulunamadi (201) ayrimi icin kullanir.
    uint8_t getLastDisconnectReason();
    // SNTP ile saat ayarlandi mi? (TLS baglantisi saat senkronu olmadan denenmez.)
    bool isTimeSynced();
    // Cihaz kimligi: "AHBU-S3-<MAC son 6 hex, buyuk harf>" (fabrika aracindaki UID ile ayni kural).
    String getDeviceUid();

    // ---------------- AP (kurtarma / kurulum / servis) ----------------
    bool isRecoveryApActive();
    // AP su an GERCEKTEN WPA2 (parolali) mi? startAp()'ta parola ile baslarsa true, stopAp()'ta false (acik kurulum AP'sinde
    // false). WebPortal'in AP kaynakli yetkisi (ApAccess, CONTRACTS 3d) "AP su an WPA2 korumali" kosulunu buradan okur:
    // yapilandirmadan (ap_pass var mi) DEGIL, fiilen yayinlanan AP kipinden.
    bool isRecoveryApSecured();
    String getRecoveryApSSID();         // "AHBU-<MAC son 6>" (AP kapaliyken de ayni deger)
    // Servis modu: AP'yi sureli (varsayilan 10 dk) acar. Yalnizca AP parolasi gecerliyse veya cihaz
    // provizyonsuzsa acilir. Istek wifi_task'a birakilir (en gec ~250 ms sonra uygulanir).
    void openServiceAp(uint32_t windowMs = SERVICE_AP_WINDOW_MS);
    void startRecoveryAP() { openServiceAp(); }   // geri uyumluluk
    void stopRecoveryAP();                         // AP'yi kapatir, pencereleri iptal eder (en gec ~250 ms sonra)
    // ap_pass veya provizyon durumu degisti: acik AP varsa yeni parolayla yeniden baslatilir
    // (HTTP yaniti cikabilsin diye ~1.5 sn gecikmeli).
    void applyApConfigChange();

    // Fabrika sifirlama: surucunun kendi sakladigi Wi-Fi ayarlari (esp_wifi_restore) ve RAM durumu.
    void factoryResetWifi();

private:
    WiFiManager();
    ~WiFiManager() = default;
    WiFiManager(const WiFiManager&) = delete;
    WiFiManager& operator=(const WiFiManager&) = delete;

    static void wifiTask(void* parameter);
    void tick();
    void onWiFiEvent(WiFiEvent_t event, WiFiEventInfo_t info);

    void onConnected();
    void onDisconnected(uint8_t reason);
    void reconcileStatus();
    void stepCandidate(uint32_t now);
    void stepSta(uint32_t now);
    void stepAp(uint32_t now);
    void startAp(bool openNetwork, const char* pass, uint32_t now);
    void stopAp();
    void beginSta(const String& ssid, const String& pass);
    void commitCandidate();
    void scrubLegacyWifiOnce();
    String apSsid();

    // ---- Durum (Mutex ile korunur) ----
    SemaphoreHandle_t _mutex;
    bool _connected;
    IPAddress _localIP;
    IPAddress _gatewayIP;
    int8_t _rssi;
    String _ssid;          // kayitli (NVS ile tutarli) STA kimligi
    String _pass;
    uint32_t _reconnectCount;
    uint32_t _connectTimestamp;          // son GOT_IP'nin millis() damgasi (yalniz bilgi; hicbir yerde karsilastirilmaz)
    int64_t _connectedAtUs;              // son GOT_IP'nin esp_timer damgasi (64 bit: uptime hesabi tasmaz)
    volatile uint32_t _connectSeq;       // her GOT_IP'de artar: "bu denemeden SONRA baglandi mi" sayacla sorulur
    volatile uint8_t _lastDisconnectReason;

    // Olay bayraklari (olay isleyicisi -> gorev)
    volatile bool _evtDisconnected;      // son baglanma denemesinden sonra STA_DISCONNECTED geldi
    volatile bool _sntpPending;

    // Diger gorevlerden gelen istekler (wifi_task tuketir; zamanlayicilari YALNIZ wifi_task degistirir)
    volatile bool _reqReconnect;
    volatile bool _reqStaReset;
    volatile bool _reqServiceOpen;
    volatile uint32_t _reqServiceMs;
    volatile bool _reqApStop;
    volatile bool _reqApRestart;

    // Otomatik STA baglanma (yalniz wifi_task)
    NetUtil::StaMachine _sta;

    // Aday kimlik (requestConnect)
    NetUtil::CandidateFlow _cand;
    volatile bool _candActive;           // istek kabul edildi ... akis bitti (BUSY ve isConnecting icin)
    volatile bool _candStartReq;
    volatile bool _candCancelReq;
    String _candSsid;
    String _candPass;
    uint32_t _candSeq;                   // aday denemesi basladiginda _connectSeq
    ConnectState _candState;
    uint8_t _candReason;

    // AP
    NetUtil::ApPolicy _ap;
    volatile bool _apActive;
    volatile bool _apSecured;            // yayindaki AP WPA2 (parolali) mi; yalniz wifi_task yazar, web gorevi okur
    NetUtil::Wait _apFailLog;            // "AP baslatilamadi" log siniri (30 sn)
    NetUtil::Wait _watermark;            // yigin izleme logu (10 dk)

    TaskHandle_t _taskHandle;
};
