#pragma once

#define Extension_Enable      1                   // Whether to extend the connection to external devices     1:Expansion device Modbus RTU Relay     0:No extend
#define RS485_CAN_Enable      1                   // This item is configured according to product selection   1:Select RS485                          0:Select CAN
#define RTC_Event_Enable      1                   // Whether to enable RTC events  (Bluetooth)                1:Enable                                0:Disable

// ----------------------------------------------------------------------------------------------
// SATICI DEMO KIMLIKLERI KALDIRILDI (guvenlik denetimi, F10). Bu dosya eskiden sabit bir Wi-Fi SSID/parolasi ve
// Waveshare bulut cihaz kimligi/konulari iceriyordu. Bu makrolar YALNIZCA derleme disi demo dosyalarinin
// (WS_Bluetooth.h / WS_Serial.h) basliklari kirilmasin diye BOS birakildi. Uretim yazilimi Wi-Fi ve MQTT
// kimligini NVS'ten (ConfigManager) alir; derlemede sabit kimlik YOKTUR.
// ----------------------------------------------------------------------------------------------
#define STASSID       ""
#define STAPSK        ""

#define MQTT_Server   ""
#define MQTT_Port     0
#define MQTT_ID       ""
#define MQTT_Pub      ""
#define MQTT_Sub      ""
