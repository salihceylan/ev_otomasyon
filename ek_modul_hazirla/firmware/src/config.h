#ifndef CONFIG_H
#define CONFIG_H

#include <Arduino.h>

// ==============================================================================
// EK MODÜL ÇALIŞMA MODU:
// 1 -> PIN TARAMA VE TEŞHİS MODU (Röle ve RS485 pinlerini interaktif bulma)
// 0 -> EK MODÜL ÜRETİM MODU (RS485 Modbus RTU Slave - Cihaz 1)
// ==============================================================================
#ifndef RUN_MODE_SCANNER
#define RUN_MODE_SCANNER 1
#endif

// ==============================================================================
// CİHAZ PARAMETRELERİ (Slave ID, Baudrate)
// ==============================================================================
#ifndef DEVICE_ID
#define DEVICE_ID 1
#endif

#ifndef RS485_BAUDRATE
#define RS485_BAUDRATE 9600
#endif

// ==============================================================================
// RÖLE ÇIKIŞ PİNLERİ (ULN2803 Girişleri - 8 Röle)
// ==============================================================================
// Not: Konya Diafon kartında pinler tespit edildikçe bu dizi güncellenir.
// Olası standart pin dizilimi:
static const uint8_t RELAY_PINS[8] = {
    25, 26, 27, 14, 12, 13, 32, 33
};

#define RELAY_ACTIVE_LEVEL HIGH

// ==============================================================================
// RS485 PİNLERİ (Hardware Serial 2)
// ==============================================================================
#ifndef RS485_TX_PIN
#define RS485_TX_PIN 17
#endif

#ifndef RS485_RX_PIN
#define RS485_RX_PIN 16
#endif

#ifndef RS485_DE_RE_PIN
#define RS485_DE_RE_PIN -1 // -1: Otomatik donanımsal yönlendirme varsa; değilse GPIO (örn: 4)
#endif

// ==============================================================================
// DİJİTAL GİRİŞ PİNLERİ (74HC165 Shift Register - IN1..IN8)
// ==============================================================================
#ifndef HC165_DATA_PIN
#define HC165_DATA_PIN 19
#endif

#ifndef HC165_CLOCK_PIN
#define HC165_CLOCK_PIN 18
#endif

#ifndef HC165_LATCH_PIN
#define HC165_LATCH_PIN 5
#endif

#endif // CONFIG_H

