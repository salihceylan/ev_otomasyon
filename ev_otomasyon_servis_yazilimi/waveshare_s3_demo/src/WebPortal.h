#pragma once
#include <Arduino.h>
#include <WebServer.h>
#include <ArduinoJson.h>
#include <vector>
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>
#include "DeviceCommand.h"
#include "NetTime.h"

struct ScannedAp {
  String ssid;
  int32_t rssi;
  bool enc;
};

// ============================================================================
// WebPortal - Yerel HTTP API ve gomulu web arayuzu (docs/CONTRACTS.md Bolum 3).
//
//  * Kimlik: "X-Device-Key" (sabit zamanli karsilastirma; IP basina 5 hatali deneme -> 60 sn 423).
//    Anahtarsiz yalnizca GET / (sayfa) ve GET /api/status (KISITLI ozet) calisir -- ISTISNA: Wi-Fi servis akisi
//    (GET /api/wifi/scan, POST /api/wifi/connect, GET /api/wifi/status) icin AP KAYNAKLI yetki (CONTRACTS 3d, ApAccess.h):
//    gecerli X-Device-Key YA DA (istemci SoftAP arayuzunde + AP su an WPA2 + gecerli ap_pass + cihaz provizyonlu).
//    Teknisyen musteride panonun kurtarma agindayken internet yoktur; anahtari sunucudan alamaz. Digerleri HEP anahtarli.
//  * Provizyonsuz cihaz (local_key yok): POST /api/factory/init ve kisitli status; digerleri 403.
//  * CORS basligi YOKTUR; JSON govdeli POST'larda Content-Type: application/json zorunludur;
//    Host ve Origin dogrulanir (DNS-rebinding / capraz kaynak istek savunmasi).
//  * Role/panjur komutlari postDeviceCommand() ile kuyruga yazilir (Core 1 uygular).
//  * AG GIRIS/CIKISI AYRI GOREVDE ("WebTask": Core 1, ONCELIK 0): yavas/kotu niyetli bir HTTP istemcisi
//    (kutuphane istegi ayristirirken yield() dongusunde bekler, bayt bayt sizdirma suresiz surer) artik
//    loopTask'i (duvar anahtari, panjur, cocuk kilidi, TWDT) bloklayamaz ve IDLE0'i aclikta birakip
//    TWDT yeniden baslatmasi (panic) tetikleyemez: gorev loopTask'tan DUSUK oncelikli ve IDLE1 ile
//    zaman paylasimlidir. loopTask'tan cagrilan WebPortal::loop() soketlere DOKUNMAZ; yalnizca "yalniz
//    loop gorevinden" cagrilabilen servis islerini (ham RS485 role, yapilandirma uygulama) kisa surede yurutur.
// ============================================================================
class WebPortal {
public:
  static WebPortal& instance();
  void begin();
  // loopTask (Core 1) baglami: SOKET ISLEMEZ. Web gorevinin postaladigi loop-affine servis cagrilarini
  // (SmartAutomation::rs485ControlExtRelay yalniz loop gorevinden cagrilabilir) yurutur; bos turda ~mikrosaniye.
  void loop();
  void storeScanResults(int n);

private:
  WebPortal();

  // PUBLIC: anahtarsiz. KEYED: yalniz gecerli X-Device-Key. FACTORY: provizyonsuz cihazda factory/init.
  // AP_OR_KEYED: gecerli X-Device-Key YA DA AP kaynakli yetki (ApAccess::via) -- yalniz wifi/scan|connect|status.
  enum class Access : uint8_t { PUBLIC, KEYED, FACTORY, AP_OR_KEYED };
  typedef void (WebPortal::*Handler)();

  WebServer _server;
  TaskHandle_t _taskHandle;
  std::vector<ScannedAp> _cachedNetworks;

  // Wi-Fi tarama kapisi: hiz siniri (10 sn), onbellek omru (120 sn), takilmis tarama (15 sn) -- NetTime.h, web gorevinde
  // her tur yoklanir (N6: saklanmis hedef zaman yok)
  NetUtil::ScanGate _scan;

  // Bu istek anahtarsiz AP kaynakli yolla mi yetkilendirildi? (dispatch her istekte sifirlar; yalniz web gorevi)
  // -> POST /api/wifi/connect icin global hiz siniri (dakikada 6) yalniz bu durumda uygulanir.
  bool _viaApOrigin;

  void route(const char* uri, HTTPMethod method, Handler handler, Access access);
  void dispatch(Handler handler, Access access);
  void setupRoutes();
  static void webTask(void* parameter);

  // Ortak yardimcilar
  bool guardRequest();
  enum class KeyCheck : uint8_t { UNPROVISIONED, LOCKED, MISSING, WRONG, VALID };
  KeyCheck checkKey(bool enforceLockAndCount, uint32_t& retryAfterSec);   // yanit GONDERMEZ
  bool authorize();
  bool authorizeApOrKeyed();
  bool remoteOnSoftAp();
  void sendSecurityHeaders();
  void sendJson(int code, const String& body);
  void sendError(int code, const char* error);
  void sendOk();
  void sendQueued();
  bool readJsonBody(String& body);
  bool parseJsonObject(const String& body, DynamicJsonDocument& doc);
  bool postOrFail(const DeviceCommand& cmd);
  void sendFullStatus();
  void sendRestrictedStatus(bool provisioned);

  // Uclar
  void handleRoot();
  void handleNotFound();
  void handleApiStatus();
  void handleApiRelay();
  void handleApiAll();
  void handleApiChildLockGet();
  void handleApiChildLockPost();
  void handleApiConfigGet();
  void handleApiConfigSave();
  void handleApiWifiScan();
  void handleApiWifiConnect();
  void handleApiWifiStatus();
  void handleApiWifiDisconnect();
  void handleApiRs485Send();
  void handleApiRs485Logs();
  void handleApiRs485Clear();
  void handleApiRs485Baud();
  void handleApiRs485ScanStart();
  void handleApiRs485ScanResult();
  void handleApiRs485Relay();
  void handleApiReboot();
  void handleApiReset();
  void handleApiFactoryInit();
  void handleApiRekey();
  void handleApiAuthCheck();
  void handleApiMqttConfig();
  // Guvenlik katmani (spec 3.5, WP-F5)
  void handleApiActuator();
  void handleApiAlarmAck();
  void handleApiAlarmTest();
  void handleApiEvents();
  void handleApiSafetyConfigGet();
  void handleApiSafetyConfigPost();
  void postAndWait(DeviceCommand& c);     // kuyruk + en cok 1 sn last_id/last_rej yoklamasi -> {ok, id, rej?}
  bool latchBlocksRestart();               // kilit varken force=1 yoksa 409 gonderir

  static void preRestartHook();
};
