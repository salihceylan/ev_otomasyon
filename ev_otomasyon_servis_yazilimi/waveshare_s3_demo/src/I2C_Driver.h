#pragma once
#include <Wire.h>
#include <esp_err.h>

#define I2C_SCL_PIN       41
#define I2C_SDA_PIN       42

void I2C_Init(void);

// Çok görevli erişim: TCA9554 röle çıkışı (Core 1) ile PCF85063 RTC (Core 0) AYNI hattı paylaşır.
// Wire'ın beginTransmission/write/endTransmission dizisi atomik değildir; çok adımlı işlemler
// (oku-değiştir-yaz, gölge kayıt güncelleme) I2C_Lock()/I2C_Unlock() ile sarılmalıdır.
// Kilit ÖZYİNELEMELİDİR (aynı görev iç içe alabilir). I2C_Init() öncesi çağrılırsa kilitsiz geçer.
bool I2C_Lock(uint32_t timeoutMs = 50);
void I2C_Unlock(void);

// Dönüş: ESP_OK (= 0) başarı; aksi halde hata kodu. (Eski sözleşme "0 = başarı"dır; tür artık bool DEĞİL —
// eski kod `-1`'i bool'a çevirip BAŞARISIZLIĞI "true" döndürüyordu.)
esp_err_t I2C_Read(uint8_t Driver_addr, uint8_t Reg_addr, uint8_t *Reg_data, uint32_t Length);
esp_err_t I2C_Write(uint8_t Driver_addr, uint8_t Reg_addr, const uint8_t *Reg_data, uint32_t Length);
