#pragma once
#include <Arduino.h>
#include <WebServer.h>

struct ScannedAp {
  String ssid;
  int32_t rssi;
  bool enc;
};

class WebPortal {
public:
  static WebPortal& instance();
  void begin();
  void loop();
  void storeScanResults(int n);

private:
  WebPortal();
  WebServer _server;
  std::vector<ScannedAp> _cachedNetworks;

  void setupRoutes();
  void sendCors();
  void handleRoot();
  void handleApiStatus();
  void handleApiRelay();
  void handleApiAll();
  void handleApiConfigGet();
  void handleApiConfigSave();
  void handleApiWifiScan();
  void handleApiWifiConnect();
  void handleApiWifiDisconnect();
  void handleApiRs485Send();
  void handleApiRs485Logs();
  void handleApiRs485Clear();
  void handleApiRs485Baud();
  void handleApiRs485Scan();
  void handleApiRs485Relay();
  void handleApiReboot();
  void handleApiReset();
};

