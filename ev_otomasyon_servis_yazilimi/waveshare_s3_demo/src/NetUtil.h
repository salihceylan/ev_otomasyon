#pragma once
// ============================================================================
// NetUtil.h - Ag/web katmani (WiFiManager, MqttManager, WebPortal) ortak yardimcilari.
// Yalnizca satir ici (inline) fonksiyonlar: ayri .cpp yok, build_src_filter'dan etkilenmez.
// ============================================================================
#include <Arduino.h>
#include <stdint.h>
#include <string.h>
#include <time.h>
#include "Utf8Util.h"

namespace NetUtil {

// Sistem saati makul bir degere (Kasim 2023 sonrasi) ayarlandiysa true.
// SNTP senkronundan once time() ~0 doner; TLS sertifika gecerlilik denetimi buna baglidir.
static constexpr time_t MIN_VALID_EPOCH = 1700000000;
inline bool isTimeSynced() { return time(nullptr) > MIN_VALID_EPOCH; }

// ZAMAN KURALI (N6, CONTRACTS 3c): burada (ve ag katmaninin hicbir yerinde) "hedef zaman gecti mi" isaretli
// karsilastirmasi YOKTUR: saklanmis hedef eski kalirsa millis() 24,86 gun sonra onu "hala gelecekte" sanir ve
// zamanlayici donar. Tum zamanlayicilar NetTime.h'deki "son olay + bekleme" ciftleridir (NetUtil::Wait).

// Sabit zamanli karsilastirma: ilk farkta cikmaz, uzunluk farkini da sonuca katar.
// Gizli degerler (yerel anahtar) icin kullanilir; "nullptr" bos dizge sayilir.
inline bool constantTimeEquals(const char* a, const char* b) {
  if (!a) a = "";
  if (!b) b = "";
  const size_t la = strlen(a);
  const size_t lb = strlen(b);
  const size_t n = (la > lb) ? la : lb;
  uint8_t diff = (uint8_t)((la != lb) ? 1 : 0);
  for (size_t i = 0; i < n; i++) {
    const uint8_t ca = (i < la) ? (uint8_t)a[i] : 0;
    const uint8_t cb = (i < lb) ? (uint8_t)b[i] : 0;
    diff |= (uint8_t)(ca ^ cb);
  }
  return diff == 0;
}

// utf8SeqLen / isCleanUtf8 / copyUtf8Truncated: Utf8Util.h (saf; PC testlerinde de derlenir).

// JSON'a basilacak dis kaynakli metni (SSID, kanal adi) guvenli hale getirir:
//  - gecersiz UTF-8 baytlari U+FFFD (EF BF BD) ile degistirilir,
//  - C0 kontrol karakterleri ve DEL bosluga cevrilir (JSON ayristiricilari ham kontrol karakterini reddeder).
inline String sanitizeUtf8(const char* s, size_t maxBytes = 256) {
  String out;
  if (!s) return out;
  size_t len = 0;
  while (len < maxBytes && s[len]) len++;
  out.reserve(len + 8);
  const uint8_t* p = (const uint8_t*)s;
  size_t i = 0;
  while (i < len) {
    const uint8_t c = p[i];
    if (c < 0x20 || c == 0x7F) {
      out += ' ';
      i++;
      continue;
    }
    const int n = utf8SeqLen(p + i, len - i);
    if (n == 0) {
      out += "\xEF\xBF\xBD";
      i++;
      continue;
    }
    for (int k = 0; k < n; k++) out += (char)p[i + k];
    i += (size_t)n;
  }
  return out;
}

// sanitizeUtf8'in sabit boyutlu hedef icin (heap'siz) surumu: gecersiz bayt -> '?', kontrol karakteri -> ' ',
// UTF-8 karakterini ortadan kesmez, NUL sonlandirmayi garanti eder.
inline void sanitizeInto(char* dst, size_t cap, const char* src) {
  if (!dst || cap == 0) return;
  size_t o = 0;
  if (src) {
    const uint8_t* p = (const uint8_t*)src;
    size_t len = 0;
    while (len < 256 && p[len]) len++;
    size_t i = 0;
    while (i < len) {
      const uint8_t c = p[i];
      if (c < 0x20 || c == 0x7F) {
        if (o + 1 >= cap) break;
        dst[o++] = ' ';
        i++;
        continue;
      }
      const int n = utf8SeqLen(p + i, len - i);
      if (n == 0) {
        if (o + 1 >= cap) break;
        dst[o++] = '?';
        i++;
        continue;
      }
      if (o + (size_t)n + 1 > cap) break;   // karakter sigmiyor: kesme noktasi karakter siniri
      for (int k = 0; k < n; k++) dst[o++] = (char)p[i + k];
      i += (size_t)n;
    }
  }
  dst[o] = '\0';
}

// Yalnizca [+-]?[0-9]{1,9} biciminde tamsayi. toInt() bos/gecersiz girdiyi sessizce 0 yapar;
// burada gecersiz girdi reddedilir.
inline bool parseIntStrict(const char* s, long& out) {
  if (!s || !*s) return false;
  size_t i = 0;
  bool neg = false;
  if (s[0] == '-') { neg = true; i = 1; }
  size_t digits = 0;
  long v = 0;
  for (; s[i]; i++) {
    if (s[i] < '0' || s[i] > '9') return false;
    v = v * 10 + (s[i] - '0');
    if (++digits > 9) return false;
  }
  if (digits == 0) return false;
  out = neg ? -v : v;
  return true;
}
inline bool parseIntStrict(const String& s, long& out) { return parseIntStrict(s.c_str(), out); }

// Gunler (civil date) -> Unix epoch (UTC). Howard Hinnant'in days_from_civil algoritmasi.
inline int64_t epochFromUtc(int year, int month, int day, int hour, int minute, int second) {
  int y = year - (month <= 2 ? 1 : 0);
  const int64_t era = (y >= 0 ? y : y - 399) / 400;
  const int64_t yoe = y - era * 400;
  const int mp = (month + 9) % 12;  // Mart = 0 ... Subat = 11
  const int64_t doy = (153 * mp + 2) / 5 + day - 1;
  const int64_t doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
  const int64_t days = era * 146097 + doe - 719468;
  return days * 86400 + (int64_t)hour * 3600 + (int64_t)minute * 60 + second;
}

// Yerel anahtar / AP parolasi icin izinli karakterler: bosluksuz yazdirilabilir ASCII (0x21..0x7E).
inline bool isPrintableAsciiNoSpace(const char* s, size_t len) {
  for (size_t i = 0; i < len; i++) {
    const uint8_t c = (uint8_t)s[i];
    if (c < 0x21 || c > 0x7E) return false;
  }
  return true;
}

}  // namespace NetUtil
