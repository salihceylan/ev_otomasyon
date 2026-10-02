#pragma once

#include "WS_TCA9554PWR.h"
#include <HardwareSerial.h>     // Reference the ESP32 built-in serial port library
#include "WS_GPIO.h"


/*************************************************************  I/O  *************************************************************/
#define Relay_Number_MAX  8
#define GPIO_PIN_CH1      EXIO_PIN1    // CH1 Control GPIO
#define GPIO_PIN_CH2      EXIO_PIN2    // CH2 Control GPIO
#define GPIO_PIN_CH3      EXIO_PIN3    // CH3 Control GPIO
#define GPIO_PIN_CH4      EXIO_PIN4    // CH4 Control GPIO
#define GPIO_PIN_CH5      EXIO_PIN5    // CH5 Control GPIO
#define GPIO_PIN_CH6      EXIO_PIN6    // CH6 Control GPIO
#define GPIO_PIN_CH7      EXIO_PIN7    // CH7 Control GPIO
#define GPIO_PIN_CH8      EXIO_PIN8    // CH8 Control GPIO


#define CH1 '1'                 // CH1 Enabled Instruction              Hex : 0x31
#define CH2 '2'                 // CH2 Enabled Instruction              Hex : 0x32
#define CH3 '3'                 // CH3 Enabled Instruction              Hex : 0x33
#define CH4 '4'                 // CH4 Enabled Instruction              Hex : 0x34
#define CH5 '5'                 // CH5 Enabled Instruction              Hex : 0x35
#define CH6 '6'                 // CH6 Enabled Instruction              Hex : 0x36
#define CH7 '7'                 // CH5 Enabled Instruction              Hex : 0x37
#define CH8 '8'                 // CH6 Enabled Instruction              Hex : 0x38
#define ALL_ON  '9'             // Start all channel instructions       Hex : 0x39
#define ALL_OFF '0'             // Disable all channel instructions     Hex : 0x30

#define DIN_Mode          1
#define RS485_Mode        2     // Used to distinguish data sources
#define Bluetooth_Mode    3
#define WIFI_Mode         4
#define MQTT_Mode         5
#define RTC_Mode          6

typedef enum {
  STATE_Closs = 0,    // Closs Relay
  STATE_Open = 1,     // Open Relay
  STATE_Retain = 2,   // Stay in place
} Status_adjustment;

// ---------------------------------------------------------------------------------------------
// Röle sürücüsü ince katmanı (TCA9554 gölge kayıt + interlock üzerinden; bkz. WS_TCA9554PWR.h).
// UYARI: Röle/panjur DURUMUNU yalnızca SmartAutomation değiştirir (CONTRACTS §4). Bu fonksiyonlar
// uygulama katmanından DOĞRUDAN çağrılmamalıdır; panjur kuralları (ölü zaman, konum) SmartAutomation'dadır.
// Eski demo "Relay_Analysis / Relay_Immediate*" fonksiyonları (DI/RTC/BLE/MQTT demo yolları, interlock'u
// atlıyordu) KALDIRILDI; hiçbir canlı kod çağırmıyordu.
// ---------------------------------------------------------------------------------------------
void Relay_Init(void);                      // setup()'ın İLK işi (I2C_Init'ten hemen sonra): röleleri KAPATIR
void Relay_SignalFailure(void);             // arıza uyarısı (LED/buzzer) tetikler
bool Relay_Closs(uint8_t CHx);
bool Relay_Open(uint8_t CHx);
bool Relay_CHx_Toggle(uint8_t CHx);
bool Relay_CHx(uint8_t CHx, bool State);
bool Relay_CHxs_PinState(uint8_t PinState);
