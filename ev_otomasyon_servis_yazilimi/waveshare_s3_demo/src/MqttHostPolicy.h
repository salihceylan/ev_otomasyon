#pragma once
// ============================================================================
// MqttHostPolicy.h - Bulut (MQTT) sunucu adı kilidi. SAF MANTIK (yalnızca <string.h>/<stddef.h> + SystemConfig.h).
//
// Sahip kararı (2026-10-09): ağ üzerinden gelen bir istek panoyu YABANCI bir brokere taşıyamaz. POST /api/mqtt/config
// (yerel anahtarla ya da anahtarsız kablolu Ethernet'ten) ve bootstrap yanıtı yalnızca DERLEMEYE GÖMÜLÜ izin listesindeki
// bir sunucuyu kabul eder:
//   * DEFAULT_MQTT_SERVER (SystemConfig.h) HER ZAMAN listededir;
//   * ek adlar derleme bayrağıyla verilir: -DAHBU_MQTT_HOST_ALLOW="h1,h2" (virgülle ayrılır, boşluklar kırpılır,
//     boş öğeler yok sayılır). Karşılaştırma büyük/küçük harf duyarsız ve TAM eşleşmedir (önek/sonek kabul edilmez).
// Listede olmayan ad: HTTP 400 {"error":"host_not_allowed"}; bootstrap yanıtı BAD_RESPONSE. Boş ya da verilmemiş "server"
// alanı mevcut sunucuyu korur (port/kullanıcı/parola değişimi serbesttir).
// Seri CLI / fabrika yolu (fiziksel erişim) ConfigManager::setMqttCredentials'ı doğrudan çağırabilir; bu kilide tabi DEĞİLDİR.
// MQTT sistem komutları sunucu adı taşımaz.
// ============================================================================
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include "SystemConfig.h"

#ifndef AHBU_MQTT_HOST_ALLOW
#define AHBU_MQTT_HOST_ALLOW ""
#endif

namespace mqtthost {

// Ana makine adı sözdizimi: harf/rakam/'.'/'-', 1..63, '.' ya da '-' ile başlamaz/bitmez.
inline bool validSyntax(const char* s) {
  if (!s) return false;
  const size_t n = strlen(s);
  if (n < 1 || n > 63) return false;
  if (s[0] == '.' || s[0] == '-' || s[n - 1] == '.' || s[n - 1] == '-') return false;
  for (size_t i = 0; i < n; i++) {
    const char c = s[i];
    const bool ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '.' || c == '-';
    if (!ok) return false;
  }
  return true;
}

inline char lowerAscii(char c) { return (c >= 'A' && c <= 'Z') ? (char)(c - 'A' + 'a') : c; }

// a[0..n) == b (büyük/küçük harf duyarsız, tam uzunluk)
inline bool eqNoCase(const char* a, size_t n, const char* b) {
  if (strlen(b) != n) return false;
  for (size_t i = 0; i < n; i++) {
    if (lowerAscii(a[i]) != lowerAscii(b[i])) return false;
  }
  return true;
}

// host, def ya da extra listesindeki (virgülle ayrılmış) bir ada TAM eşit mi? Sözdizimi bozuk ad hiçbir zaman kabul edilmez.
inline bool allowedIn(const char* host, const char* def, const char* extra) {
  if (!validSyntax(host)) return false;
  if (def && def[0] && eqNoCase(def, strlen(def), host)) return true;
  if (!extra) return false;
  const char* p = extra;
  while (*p) {
    const char* e = p;
    while (*e && *e != ',') e++;
    const char* a = p;
    const char* b = e;
    while (a < b && (*a == ' ' || *a == '\t')) a++;
    while (b > a && (b[-1] == ' ' || b[-1] == '\t')) b--;
    if (b > a && eqNoCase(a, (size_t)(b - a), host)) return true;
    p = *e ? e + 1 : e;
  }
  return false;
}

// Derleme izin listesi: DEFAULT_MQTT_SERVER + AHBU_MQTT_HOST_ALLOW
inline bool allowed(const char* host) { return allowedIn(host, DEFAULT_MQTT_SERVER, AHBU_MQTT_HOST_ALLOW); }

enum class Check : uint8_t {
  KEEP,         // host boş/verilmemiş: mevcut sunucu korunur
  SET,          // izin listesinde: yazılabilir
  INVALID,      // sözdizimi bozuk -> 400 invalid_value
  NOT_ALLOWED,  // sözdizimi geçerli ama listede değil -> 400 host_not_allowed
};

// POST /api/mqtt/config "server" alanı
inline Check checkRequested(const char* host) {
  if (!host || host[0] == '\0') return Check::KEEP;
  if (!validSyntax(host)) return Check::INVALID;
  return allowed(host) ? Check::SET : Check::NOT_ALLOWED;
}

}  // namespace mqtthost
