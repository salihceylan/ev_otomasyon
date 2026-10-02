#pragma once
// ============================================================================
// ModbusRtu.h - Modbus RTU cerceve olusturma/dogrulama. SAF MANTIK (yalnizca <stdint.h>/<stddef.h>).
//
// SmartAutomation'in RS485 katmani bu yardimcilari kullanir; test/test_modbus_rtu bunlari
// PC'de dogrular. Amac: "yanit geldi" demek yetmez; CRC16, bagimli adres, islev kodu, yanki (echo)
// ve uzunluk dogrulanmadan hicbir cevap BASARI sayilmaz (EVOTOMASYON_TASKS: RS485 half-duplex).
// ============================================================================
#include <stdint.h>
#include <stddef.h>

namespace modbus {

enum : uint8_t {
  FC_READ_COILS = 0x01,
  FC_READ_DISCRETE_INPUTS = 0x02,
  FC_READ_HOLDING = 0x03,
  FC_WRITE_SINGLE_COIL = 0x05
};

// Waveshare modullerinde "toggle" degeri (standart disi): 0x5500
enum : uint16_t { COIL_ON = 0xFF00, COIL_OFF = 0x0000, COIL_TOGGLE = 0x5500 };

enum Status : uint8_t {
  OK = 0,
  ERR_NO_DATA,      // hic bayt gelmedi (zaman asimi)
  ERR_SHORT,        // en kisa gecerli cerceveden kisa
  ERR_CRC,
  ERR_SLAVE,        // baska bir cihazin yaniti
  ERR_FUNC,         // beklenmeyen islev kodu
  ERR_EXCEPTION,    // slave "exception" yaniti verdi (islev|0x80)
  ERR_LENGTH,       // bayt sayisi/toplam uzunluk uyusmuyor
  ERR_ECHO          // 0x05 yaniti istegin birebir kopyasi degil
};

// CRC-16/MODBUS (poly 0xA001 yansitilmis, baslangic 0xFFFF). Cerceveye DUSUK bayt once eklenir.
inline uint16_t crc16(const uint8_t* buf, size_t len) {
  uint16_t crc = 0xFFFF;
  for (size_t pos = 0; pos < len; pos++) {
    crc ^= (uint16_t)buf[pos];
    for (int i = 8; i != 0; i--) {
      if (crc & 0x0001) {
        crc >>= 1;
        crc ^= 0xA001;
      } else {
        crc >>= 1;
      }
    }
  }
  return crc;
}

// frame[0..len-1] verisinin sonuna CRC (lo, hi) ekler. frame en az len+2 bayt olmalidir.
inline void appendCrc(uint8_t* frame, size_t len) {
  uint16_t c = crc16(frame, len);
  frame[len] = (uint8_t)(c & 0xFF);
  frame[len + 1] = (uint8_t)((c >> 8) & 0xFF);
}

// 8 baytlik "bit oku" istegi: islev 0x01 (coil) veya 0x02 (ayrik giris)
inline void buildReadBits(uint8_t out[8], uint8_t slave, uint8_t func, uint16_t start, uint16_t count) {
  out[0] = slave;
  out[1] = func;
  out[2] = (uint8_t)(start >> 8);
  out[3] = (uint8_t)(start & 0xFF);
  out[4] = (uint8_t)(count >> 8);
  out[5] = (uint8_t)(count & 0xFF);
  appendCrc(out, 6);
}

// 8 baytlik "tek coil yaz" (0x05). value: COIL_ON / COIL_OFF / COIL_TOGGLE
inline void buildWriteCoil(uint8_t out[8], uint8_t slave, uint16_t coilAddr, uint16_t value) {
  out[0] = slave;
  out[1] = FC_WRITE_SINGLE_COIL;
  out[2] = (uint8_t)(coilAddr >> 8);
  out[3] = (uint8_t)(coilAddr & 0xFF);
  out[4] = (uint8_t)(value >> 8);
  out[5] = (uint8_t)(value & 0xFF);
  appendCrc(out, 6);
}

// Bir istegin BEKLENEN yanit uzunlugu (exception yaniti 5 bayt oldugu icin bu ust sinirdir).
inline size_t expectedResponseLen(uint8_t func, uint16_t count) {
  if (func == FC_WRITE_SINGLE_COIL) return 8;
  if (func == FC_READ_COILS || func == FC_READ_DISCRETE_INPUTS) return 5 + (size_t)((count + 7) / 8);
  return 0;
}

// Cerceve CRC'si dogru mu? (en az 4 bayt: adres, islev, crc lo/hi)
inline bool frameCrcOk(const uint8_t* rx, size_t len) {
  if (len < 4) return false;
  uint16_t calc = crc16(rx, len - 2);
  uint16_t got = (uint16_t)rx[len - 2] | ((uint16_t)rx[len - 1] << 8);
  return calc == got;
}

// 0x05 yaniti: istekle BIREBIR ayni 8 bayt olmali (yanki). exception yaniti ayrica ayristirilir.
inline Status checkWriteCoilEcho(const uint8_t* req, size_t reqLen, const uint8_t* rx, size_t rxLen,
                                 uint8_t* exceptionCode = nullptr) {
  if (rxLen == 0) return ERR_NO_DATA;
  if (rxLen < 5) return ERR_SHORT;
  if (!frameCrcOk(rx, rxLen)) return ERR_CRC;
  if (reqLen < 2) return ERR_FUNC;
  if (rx[0] != req[0]) return ERR_SLAVE;
  if (rx[1] == (uint8_t)(req[1] | 0x80)) {
    if (exceptionCode && rxLen >= 3) *exceptionCode = rx[2];
    return ERR_EXCEPTION;
  }
  if (rx[1] != req[1]) return ERR_FUNC;
  if (rxLen != reqLen) return ERR_LENGTH;
  for (size_t i = 0; i < reqLen; i++) {
    if (rx[i] != req[i]) return ERR_ECHO;
  }
  return OK;
}

// 0x01/0x02 yaniti: [slave, func, bayt_sayisi, veri..., crcLo, crcHi].
// bayt_sayisi == ceil(count/8) ve toplam uzunluk == 5 + bayt_sayisi olmali.
inline Status checkReadBits(uint8_t slave, uint8_t func, uint16_t count, const uint8_t* rx, size_t rxLen,
                            const uint8_t** data, uint8_t* byteCount, uint8_t* exceptionCode = nullptr) {
  if (rxLen == 0) return ERR_NO_DATA;
  if (rxLen < 5) return ERR_SHORT;
  if (!frameCrcOk(rx, rxLen)) return ERR_CRC;
  if (rx[0] != slave) return ERR_SLAVE;
  if (rx[1] == (uint8_t)(func | 0x80)) {
    if (exceptionCode) *exceptionCode = rx[2];
    return ERR_EXCEPTION;
  }
  if (rx[1] != func) return ERR_FUNC;
  uint8_t bc = rx[2];
  size_t want = (size_t)((count + 7) / 8);
  if (bc != want) return ERR_LENGTH;
  if (rxLen != 5 + (size_t)bc) return ERR_LENGTH;
  if (data) *data = &rx[3];
  if (byteCount) *byteCount = bc;
  return OK;
}

// veri[0..byteCount-1] icinde bit numarasi (0 tabanli, LSB-first). Aralik disi => false.
inline bool getBit(const uint8_t* data, uint8_t byteCount, uint16_t bit) {
  size_t idx = bit / 8;
  if (idx >= byteCount) return false;
  return ((data[idx] >> (bit % 8)) & 0x01) != 0;
}

}  // namespace modbus
