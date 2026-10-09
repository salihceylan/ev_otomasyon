#pragma once
// ============================================================================
// BootstrapCore.h - Panonun bulut (MQTT) kimliğini kendisi alması: SAF MANTIK (ArduinoJson + NetTime.h; Arduino/TLS/NVS yok) ->
// PC'de test/test_bootstrap ile sınanır. Bağlayıcı: MqttManager (MqttTask; HTTPS + HMAC + NVS yazımı). Sözleşme: docs/CONTRACTS.md §3f.
//
//  * İstek: POST https://<mqtt_server>/api/v1/devices/bootstrap
//      {"device_uuid","ts","nonce","fw","sig"}; sig = hex(HMAC-SHA256(local_key, "ahbu-bootstrap/1|" + uid + "|" + ts + "|" + nonce)),
//      nonce = 16 rastgele bayt (32 hex), ts = UNIX saniye.
//  * Tetik: provizyonlu + ağ (Wi-Fi ya da Ethernet) + saat senkron + MQTT etkin + (MQTT kimliği yok YA DA broker art arda 3 kez
//    "not authorized" (CONNACK 5)) + bekleme süresi dolmuş.
//  * Bekleme: 202 -> 10 dk, 401 -> 60 dk, 429 / ağ / bozuk yanıt -> 30 dk (en çok 60 dk). 200 -> kimlik yazılır, bekleme yok.
//  * Durum metni: idle | waiting_claim | ok | denied | error (tam /api/status "bootstrap", seri STATUS "Bootstrap:").
// ZAMAN KURALI (CONTRACTS §3c): bekleme "başlangıç + süre" çiftidir (NetUtil::Wait) ve sahip görev her tur service() ile yoklar.
// ============================================================================
#include <ArduinoJson.h>
#include "MqttHostPolicy.h"
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "NetTime.h"

namespace boot {

static const char* const SIGN_PREFIX = "ahbu-bootstrap/1|";

enum class Status : uint8_t { IDLE = 0, WAITING_CLAIM, OK, DENIED, ERROR };
enum class Result : uint8_t { OK = 0, PENDING, DENIED, RATE_LIMITED, NET_ERROR, BAD_RESPONSE };

enum : uint32_t {
  WAIT_PENDING_MS = 600000UL,    // 202: kart henüz sahiplenilmemiş
  WAIT_DENIED_MS = 3600000UL,    // 401
  WAIT_ERROR_MS = 1800000UL,     // 429 / ağ / bozuk yanıt
  WAIT_MAX_MS = 3600000UL,
  AUTH_REJECT_TRIGGER = 3        // art arda "not authorized"
};

inline const char* statusText(Status s) {
  switch (s) {
    case Status::WAITING_CLAIM: return "waiting_claim";
    case Status::OK: return "ok";
    case Status::DENIED: return "denied";
    case Status::ERROR: return "error";
    default: return "idle";
  }
}

inline uint32_t waitFor(Result r) {
  switch (r) {
    case Result::OK: return 0;
    case Result::PENDING: return WAIT_PENDING_MS;
    case Result::DENIED: return WAIT_DENIED_MS;
    default: return WAIT_ERROR_MS;
  }
}

struct In {
  bool enabled;          // MQTT yapılandırmada etkin
  bool provisioned;      // local_key var
  bool netUp;            // Wi-Fi ya da Ethernet
  bool timeSynced;
  bool haveCreds;        // NVS'te MQTT kimliği var
  uint8_t authRejects;   // art arda CONNACK 5 sayısı
  In() : enabled(false), provisioned(false), netUp(false), timeSynced(false), haveCreds(false), authRejects(0) {}
};

struct Fsm {
  Status status;
  NetUtil::Wait wait;
  Fsm() : status(Status::IDLE) {}

  // Her tur (MqttTask): dolan bekleme sonlanır (49,7 günlük sarmada eski damga "taze" görünmez).
  void service(uint32_t now) { wait.service(now); }

  bool needed(const In& in) const {
    return in.enabled && in.provisioned && in.netUp && in.timeSynced && (!in.haveCreds || in.authRejects >= AUTH_REJECT_TRIGGER);
  }

  bool due(uint32_t now, const In& in) {
    service(now);
    return !wait.isArmed() && needed(in);
  }

  void onResult(uint32_t now, Result r) {
    switch (r) {
      case Result::OK: status = Status::OK; break;
      case Result::PENDING: status = Status::WAITING_CLAIM; break;
      case Result::DENIED: status = Status::DENIED; break;
      default: status = Status::ERROR; break;
    }
    uint32_t w = waitFor(r);
    if (w > WAIT_MAX_MS) w = WAIT_MAX_MS;
    if (w) wait.arm(now, w);
    else wait.disarm();
  }
};

// ---- İmza girdisi / gövde ----
inline void toHex(const uint8_t* p, size_t n, char* out) {
  static const char* H = "0123456789abcdef";
  for (size_t i = 0; i < n; i++) {
    out[2 * i] = H[p[i] >> 4];
    out[2 * i + 1] = H[p[i] & 0x0F];
  }
  out[2 * n] = '\0';
}

// "ahbu-bootstrap/1|<uid>|<ts>|<nonce>". false: sığmadı.
inline bool signString(char* out, size_t cap, const char* uid, uint32_t ts, const char* nonceHex) {
  const int n = snprintf(out, cap, "%s%s|%lu|%s", SIGN_PREFIX, uid, (unsigned long)ts, nonceHex);
  return n > 0 && (size_t)n < cap;
}

// Gövde JSON'u (alanlar yalnız [A-Za-z0-9.-] içerir: uid "AHBU-S3-XXXXXX", hex, sürüm). false: sığmadı.
inline bool buildBody(char* out, size_t cap, const char* uid, uint32_t ts, const char* nonceHex, const char* fw, const char* sigHex) {
  const int n = snprintf(out, cap, "{\"device_uuid\":\"%s\",\"ts\":%lu,\"nonce\":\"%s\",\"fw\":\"%s\",\"sig\":\"%s\"}", uid,
                         (unsigned long)ts, nonceHex, fw, sigHex);
  return n > 0 && (size_t)n < cap;
}

// ---- Yanıt ----
struct Creds {
  char host[64];
  uint16_t port;
  char user[48];
  char pass[64];
};

inline bool printableAscii(const char* s, size_t minLen, size_t maxLen, char lo) {
  if (!s) return false;
  const size_t n = strlen(s);
  if (n < minLen || n > maxLen) return false;
  for (size_t i = 0; i < n; i++) {
    if (s[i] < lo || s[i] > 0x7E) return false;
  }
  return true;
}

// Ana makine adı: harf/rakam/'.'/'-', 1..63, '.' ya da '-' ile başlamaz/bitmez (MqttHostPolicy ile aynı kural).
inline bool hostOk(const char* s) { return mqtthost::validSyntax(s); }

// httpCode < 0: ağ/TLS hatası. 200 gövdesi {"status":"ok","mqtt":{"host","port","username","password"}} -> c doldurulur.
inline Result parseResponse(int httpCode, const char* body, Creds& c) {
  memset(&c, 0, sizeof(c));
  if (httpCode < 0) return Result::NET_ERROR;
  if (httpCode == 202) return Result::PENDING;
  if (httpCode == 401) return Result::DENIED;
  if (httpCode == 429) return Result::RATE_LIMITED;
  if (httpCode != 200 || !body) return Result::BAD_RESPONSE;
  StaticJsonDocument<768> doc;
  if (deserializeJson(doc, body) || !doc.is<JsonObject>()) return Result::BAD_RESPONSE;
  const char* st = doc["status"].is<const char*>() ? doc["status"].as<const char*>() : nullptr;
  if (!st || strcmp(st, "ok") != 0 || !doc["mqtt"].is<JsonObject>()) return Result::BAD_RESPONSE;
  JsonObject m = doc["mqtt"].as<JsonObject>();
  const char* host = m["host"].is<const char*>() ? m["host"].as<const char*>() : nullptr;
  const char* user = m["username"].is<const char*>() ? m["username"].as<const char*>() : nullptr;
  const char* pass = m["password"].is<const char*>() ? m["password"].as<const char*>() : nullptr;
  if (!m["port"].is<int32_t>()) return Result::BAD_RESPONSE;
  const int32_t port = m["port"].as<int32_t>();
  // Sahip kararı (2026-10-09): yanıttaki host da derleme izin listesinde olmalı (MqttHostPolicy.h); yabancı broker = BAD_RESPONSE.
  if (!hostOk(host) || !mqtthost::allowed(host) || port < 1 || port > 65535 || !printableAscii(user, 1, sizeof(c.user) - 1, 0x21) ||
      !printableAscii(pass, 1, sizeof(c.pass) - 1, 0x20)) {
    return Result::BAD_RESPONSE;
  }
  memcpy(c.host, host, strlen(host) + 1);
  c.port = (uint16_t)port;
  memcpy(c.user, user, strlen(user) + 1);
  memcpy(c.pass, pass, strlen(pass) + 1);
  return Result::OK;
}

}  // namespace boot
