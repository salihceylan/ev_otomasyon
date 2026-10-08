#pragma once
// ============================================================================
// Utf8Util.h - UTF-8 dogrulama / guvenli kesme yardimcilari. SAF MANTIK (yalniz <stdint.h>/<stddef.h>/<string.h>).
//
// NetUtil.h (Arduino'ya bagli) bu basligi icerir; adlar ayni ad alanindadir (NetUtil::isCleanUtf8 ...), cagiranlar
// degismez. Saf parcalar burada durur ki guvenlik/sablon ayristiricilari (safety/SafetyCfgApi.cpp, template/) PC'de
// (pio test -e native) derlenebilsin (v1.3.0, IP-2.3).
// ============================================================================
#include <stdint.h>
#include <stddef.h>
#include <string.h>

namespace NetUtil {

// Bir UTF-8 dizisinin (RFC 3629) bas baytindan beklenen toplam uzunlugu; gecersizse 0.
// Ikinci bayt aralik kisitlari (overlong / vekil / > U+10FFFF) burada ele alinir.
inline int utf8SeqLen(const uint8_t* p, size_t remaining) {
  const uint8_t c = p[0];
  if (c < 0x80) return 1;
  if (c >= 0xC2 && c <= 0xDF) {
    if (remaining < 2 || (p[1] & 0xC0) != 0x80) return 0;
    return 2;
  }
  if (c >= 0xE0 && c <= 0xEF) {
    if (remaining < 3 || (p[1] & 0xC0) != 0x80 || (p[2] & 0xC0) != 0x80) return 0;
    if (c == 0xE0 && p[1] < 0xA0) return 0;   // overlong
    if (c == 0xED && p[1] > 0x9F) return 0;   // UTF-16 vekil cifti
    return 3;
  }
  if (c >= 0xF0 && c <= 0xF4) {
    if (remaining < 4 || (p[1] & 0xC0) != 0x80 || (p[2] & 0xC0) != 0x80 || (p[3] & 0xC0) != 0x80) return 0;
    if (c == 0xF0 && p[1] < 0x90) return 0;   // overlong
    if (c == 0xF4 && p[1] > 0x8F) return 0;   // > U+10FFFF
    return 4;
  }
  return 0;
}

// Dizge gecerli UTF-8 mi ve (allowControl=false iken) kontrol karakteri iceriyor mu?
inline bool isCleanUtf8(const char* s, size_t len, bool allowControl = false) {
  const uint8_t* p = (const uint8_t*)s;
  size_t i = 0;
  while (i < len) {
    const uint8_t c = p[i];
    if (!allowControl && (c < 0x20 || c == 0x7F)) return false;
    const int n = utf8SeqLen(p + i, len - i);
    if (n == 0) return false;
    i += (size_t)n;
  }
  return true;
}

// src'yi dst[cap]'e kopyalar; UTF-8 karakterini ortadan kesmez, NUL sonlandirmayi garanti eder.
inline void copyUtf8Truncated(char* dst, size_t cap, const char* src) {
  if (!dst || cap == 0) return;
  size_t n = src ? strlen(src) : 0;
  if (n > cap - 1) n = cap - 1;
  // Kesme noktasi bir karakterin ortasina denk geliyorsa geri cekil.
  if (src && n > 0 && n < strlen(src)) {
    while (n > 0 && (((uint8_t)src[n]) & 0xC0) == 0x80) n--;
  }
  if (src && n > 0) memcpy(dst, src, n);
  dst[n] = '\0';
}

}  // namespace NetUtil
