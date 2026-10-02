#include "I2C_Driver.h"
#include <freertos/FreeRTOS.h>
#include <freertos/semphr.h>

// Özyinelemeli kilit: I2C_Init() oluşturur. (Hat ortak: TCA9554 + PCF85063)
static SemaphoreHandle_t s_i2cMutex = nullptr;

void I2C_Init(void) {
  if (s_i2cMutex == nullptr) {
    s_i2cMutex = xSemaphoreCreateRecursiveMutex();
  }
  Wire.begin(I2C_SDA_PIN, I2C_SCL_PIN);
  Wire.setTimeOut(50);   // hat takılırsa en çok 50 ms bekle (varsayılan da 50 ms; açıkça sabitlendi)
}

bool I2C_Lock(uint32_t timeoutMs) {
  if (s_i2cMutex == nullptr) return true;   // henüz başlatılmadı: tek görev varsayımı
  return xSemaphoreTakeRecursive(s_i2cMutex, pdMS_TO_TICKS(timeoutMs)) == pdTRUE;
}

void I2C_Unlock(void) {
  if (s_i2cMutex != nullptr) xSemaphoreGiveRecursive(s_i2cMutex);
}

esp_err_t I2C_Read(uint8_t Driver_addr, uint8_t Reg_addr, uint8_t *Reg_data, uint32_t Length) {
  if (Reg_data == nullptr || Length == 0 || Length > 32) return ESP_ERR_INVALID_ARG;
  if (!I2C_Lock(50)) return ESP_ERR_TIMEOUT;

  esp_err_t result = ESP_OK;
  Wire.beginTransmission(Driver_addr);
  Wire.write(Reg_addr);
  if (Wire.endTransmission(true) != 0) {
    result = ESP_FAIL;
  } else {
    // requestFrom, gerçekten alınan bayt sayısını döndürür: eksikse bayat/0xFF veri KULLANILMAZ.
    uint8_t got = Wire.requestFrom(Driver_addr, (uint8_t)Length);
    if (got != Length) {
      result = ESP_ERR_INVALID_SIZE;
    } else {
      for (uint32_t i = 0; i < Length; i++) {
        int b = Wire.read();
        if (b < 0) { result = ESP_ERR_INVALID_SIZE; break; }
        Reg_data[i] = (uint8_t)b;
      }
    }
  }
  I2C_Unlock();
  if (result != ESP_OK) printf("The I2C transmission fails. - I2C Read (addr 0x%02X reg 0x%02X)\r\n", Driver_addr, Reg_addr);
  return result;
}

esp_err_t I2C_Write(uint8_t Driver_addr, uint8_t Reg_addr, const uint8_t *Reg_data, uint32_t Length) {
  if (Reg_data == nullptr || Length == 0 || Length > 32) return ESP_ERR_INVALID_ARG;
  if (!I2C_Lock(50)) return ESP_ERR_TIMEOUT;

  Wire.beginTransmission(Driver_addr);
  Wire.write(Reg_addr);
  for (uint32_t i = 0; i < Length; i++) {
    Wire.write(Reg_data[i]);
  }
  esp_err_t result = (Wire.endTransmission(true) == 0) ? ESP_OK : ESP_FAIL;
  I2C_Unlock();
  if (result != ESP_OK) printf("The I2C transmission fails. - I2C Write (addr 0x%02X reg 0x%02X)\r\n", Driver_addr, Reg_addr);
  return result;
}
