#pragma once
// ============================================================================
// WS_ETH.h - Waveshare demo Ethernet (W5500) / NTP kodu DEVRE DISI (denetim duzeltmesi N2/N4).
//
// Eski demo Ethernet baglaninca "NTPClient" ile Cin saat dilimine (UTC+8) gore RTC'yi ayarlardi ve
// saat gelene kadar sonsuz dongude beklerdi. Uygulamada hic kullanilmaz (cihaz Wi-Fi ile calisir;
// saat WiFiManager'daki SNTP ile ayarlanir). W5500 Ethernet ileride ayri bir modul olarak eklenecektir.
// ============================================================================
#include <ETH.h>
#include <SPI.h>

#include "WS_PCF85063.h"
#include "WS_GPIO.h"
#include "WS_RTC.h"

// W5500 pinleri (ileride Ethernet etkinlestirilirse kullanilacak)
#ifndef ETH_PHY_TYPE
  #define ETH_PHY_TYPE ETH_PHY_W5500
  #define ETH_PHY_ADDR 1
  #define ETH_PHY_CS   16
  #define ETH_PHY_IRQ  12
  #define ETH_PHY_RST  39
#endif

#define ETH_SPI_SCK  15
#define ETH_SPI_MISO 14
#define ETH_SPI_MOSI 13

void ETH_Init(void);             // islevsiz (no-op)
void Acquisition_time(void);     // islevsiz (no-op)
