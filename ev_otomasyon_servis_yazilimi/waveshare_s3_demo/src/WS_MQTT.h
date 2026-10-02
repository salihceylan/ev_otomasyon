#pragma once
// ============================================================================
// WS_MQTT.h - Waveshare demo MQTT (mqtt.waveshare.cloud) istemcisi DEVRE DISI (denetim duzeltmesi N1/N4).
//
// Eski demo sabit bir bulut kimligine ("MQTT_ID", yayin/abone konulari) acik (TLS'siz) baglanirdi.
// Uygulamada hic kullanilmaz: bulut baglantisini MqttManager (TLS + dogrulanmis sertifika + cihaza
// ozel kimlik) yonetir. Bu dosyada yalnizca (kullanilmayan) Bluetooth demosunun basliklari icin
// gereken include'lar kalmistir. Sabit kimlik/konu YOKTUR.
// ============================================================================
#include <ArduinoJson.h>
#include <Arduino.h>
#include <PubSubClient.h>
#include <WiFi.h>
#include <WiFiClientSecure.h>
#include "WS_GPIO.h"
#include "WS_Relay.h"
#include "WS_WIFI.h"

void MQTT_Init(void);   // islevsiz (no-op)
