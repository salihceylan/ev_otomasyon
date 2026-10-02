#pragma once
// ============================================================================
// WS_WIFI.h - Waveshare demo Wi-Fi/Web kodu DEVRE DISI (denetim duzeltmesi N3/N4).
//
// Eski demo; sabit "STASSID/STAPSK" Wi-Fi kimligiyle STA'ya baglanir ve kimliksiz ikinci bir web
// sunucusu (port 80, /Switch1..8, /AllOn, /AllOff, /RTC_Event ...) acardi. Uygulamada hic kullanilmaz:
// Wi-Fi'yi WiFiManager, web arayuzunu WebPortal yonetir. Bu dosyada yalnizca (kullanilmayan) Bluetooth
// demosunun derlenebilmesi icin gereken semboller kalmistir. Sabit kimlik YOKTUR.
// ============================================================================
#include "stdio.h"
#include <stdint.h>
#include <WiFi.h>
#include "WS_GPIO.h"
#include "WS_Relay.h"
#include "WS_RTC.h"

extern char ipStr[16];           // WS_Bluetooth demosu okur; her zaman "0.0.0.0"
extern bool WIFI_Connection;     // her zaman 0

void WIFI_Init();                // islevsiz (no-op)
void WIFI_Loop();                // islevsiz (no-op)
