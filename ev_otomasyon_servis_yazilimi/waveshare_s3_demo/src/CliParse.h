#pragma once
// ============================================================================
// CliParse.h - Seri CLI ayrıştırma/doğrulama yardımcıları. SAF MANTIK (Arduino/FreeRTOS/NVS'e BAĞIMLI DEĞİL;
// yalnızca SystemConfig.h'nin saf sabit/doğrulayıcıları). PC'de test edilir: test/test_cli_parse.
//
// FACTORYINIT <local_key> <ap_pass>   (USB-seri fabrika provizyonu; docs/CONTRACTS.md §3)
//   * YALNIZCA cihaz provizyonsuzken (local_key yok) çalışır; provizyonluysa ERR already_provisioned ve hiçbir şey
//     değişmez. (Bu denetim ayrıştırmadan ÖNCE yapılır: geçersiz argümanlı satır da "already_provisioned" döner.)
//   * local_key : 8..32 karakter, yazdırılabilir ASCII 0x21..0x7E (boşluk YOK)  -> ilk sözcük
//   * ap_pass   : 8..32 karakter, yazdırılabilir ASCII 0x20..0x7E (WPA2 uyumlu) -> satırın GERİ KALANI (boşluk içerebilir)
//   * Satırın sonundaki boşluk/TAB/CR/LF yok sayılır. Hata durumunda çıktı tamponlarına DOKUNULMAZ.
//   * Satırdaki gizli değerler çağıran tarafından ASLA yankılanmaz/loglanmaz (bkz. main.cpp).
// ============================================================================
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include "SystemConfig.h"

namespace cliparse {

enum FactoryInitStatus : uint8_t {
  FI_OK = 0,
  FI_ERR_ALREADY_PROVISIONED,
  FI_ERR_INVALID_LOCAL_KEY,
  FI_ERR_INVALID_AP_PASS
};

// Seri yanıtta "ERR <metin>" olarak yazılır (fabrika aracı bu metinleri ayrıştırır).
inline const char* factoryInitErrorText(FactoryInitStatus s) {
  switch (s) {
    case FI_ERR_ALREADY_PROVISIONED: return "already_provisioned";
    case FI_ERR_INVALID_LOCAL_KEY:   return "invalid_local_key";
    case FI_ERR_INVALID_AP_PASS:     return "invalid_ap_pass";
    default:                         return "";
  }
}

namespace detail {
inline bool isSpace(char c) { return c == ' '; }
inline bool isTrailingWs(char c) { return c == ' ' || c == '\t' || c == '\r' || c == '\n'; }
}  // namespace detail

// line: komut sözcüğünü DAHİL eden NUL sonlu satır ("FACTORYINIT <local_key> <ap_pass...>").
// provisioned: cihazda zaten local_key var mı?
// keyOut/passOut: yalnızca FI_OK'ta yazılır (NUL sonlu); kapasite >= LOCAL_KEY_MAX_LEN+1 / AP_PASS_MAX_LEN+1 olmalı.
inline FactoryInitStatus parseFactoryInit(const char* line, bool provisioned, char* keyOut, size_t keyCap, char* passOut,
                                          size_t passCap) {
  if (provisioned) return FI_ERR_ALREADY_PROVISIONED;
  if (line == NULL || keyOut == NULL || passOut == NULL || keyCap < (size_t)LOCAL_KEY_MAX_LEN + 1 ||
      passCap < (size_t)AP_PASS_MAX_LEN + 1) {
    return FI_ERR_INVALID_LOCAL_KEY;
  }

  // Satır sonundaki boşlukları at (uzunluk sınırı: aşırı uzun satır geçersizdir, taşma yok)
  size_t len = strnlen(line, 512);
  if (len >= 512) return FI_ERR_INVALID_LOCAL_KEY;
  while (len > 0 && detail::isTrailingWs(line[len - 1])) len--;

  size_t i = 0;
  while (i < len && detail::isSpace(line[i])) i++;      // baştaki boşluklar
  while (i < len && !detail::isSpace(line[i])) i++;     // komut sözcüğü (FACTORYINIT)
  while (i < len && detail::isSpace(line[i])) i++;      // ayraç

  const size_t keyStart = i;
  while (i < len && !detail::isSpace(line[i])) i++;     // local_key sözcüğü
  const size_t keyLen = i - keyStart;
  while (i < len && detail::isSpace(line[i])) i++;      // ayraç
  const size_t passStart = i;
  const size_t passLen = len - passStart;               // satırın geri kalanı (boşluk içerebilir)

  // local_key: 8..32, 0x21..0x7E
  if (keyLen < (size_t)LOCAL_KEY_MIN_LEN || keyLen > (size_t)LOCAL_KEY_MAX_LEN) return FI_ERR_INVALID_LOCAL_KEY;
  for (size_t k = 0; k < keyLen; k++) {
    const uint8_t c = (uint8_t)line[keyStart + k];
    if (c < 0x21 || c > 0x7E) return FI_ERR_INVALID_LOCAL_KEY;
  }
  // ap_pass: 8..32, 0x20..0x7E
  if (passLen < (size_t)AP_PASS_MIN_LEN || passLen > (size_t)AP_PASS_MAX_LEN) return FI_ERR_INVALID_AP_PASS;
  for (size_t k = 0; k < passLen; k++) {
    const uint8_t c = (uint8_t)line[passStart + k];
    if (c < 0x20 || c > 0x7E) return FI_ERR_INVALID_AP_PASS;
  }

  memcpy(keyOut, line + keyStart, keyLen);
  keyOut[keyLen] = '\0';
  memcpy(passOut, line + passStart, passLen);
  passOut[passLen] = '\0';
  return FI_OK;
}

// Seri DEFAULT_DI / SET_SHUTTER_DI: varsayılan panjur DI düzeni (2 kablolu tek buton): DI1 -> P1 (röle 1) STEP, DI2 boşta, DI3 -> P2 (röle 3)
// STEP, DI4 boşta; DI 5.. dokunulmaz. main.cpp bunu ÖNCE aday kopyaya uygular ve güvenlik çapraz denetiminden (validateSystemChange) geçerse
// kaydeder (pano-9): sensör DI'sini duvar butonu yapan değişiklik kaydedilmez (aksi halde sonraki açılışta cfg_corrupt güvenli kipi).
inline void applyDefaultShutterDis(SystemConfig& c) {
  using sysconfig_detail::copyStr;
  copyStr(c.dis[0].name, "Salon Panjur Butonu");
  c.dis[0].target_relay = 1;
  c.dis[0].mode = DI_MODE_SHUTTER_STEP;
  copyStr(c.dis[1].name, "Giris 2 (Bosta / Serbest)");
  c.dis[1].target_relay = 0;
  c.dis[1].mode = DI_MODE_TOGGLE;
  copyStr(c.dis[2].name, "Oda Panjur Butonu");
  c.dis[2].target_relay = 3;
  c.dis[2].mode = DI_MODE_SHUTTER_STEP;
  copyStr(c.dis[3].name, "Giris 4 (Bosta / Serbest)");
  c.dis[3].target_relay = 0;
  c.dis[3].mode = DI_MODE_TOGGLE;
}

}  // namespace cliparse
