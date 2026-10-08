#pragma once
// ============================================================================
// LocalKeyFp.h - Yerel anahtar parmak izi "lk_fp" (sözleşme 1 / pano-5). SAF MANTIK: yalnız <stdint.h>/<string.h>; HMAC işlevi çağırandan
// gelir (cihazda mbedtls_md_hmac: ConfigManager::localKeyFp; PC'de teste özgü başvuru uygulaması: test/test_lk_fp).
//
//   lk_fp = HMAC-SHA256(anahtar = local_key ASCII baytları, ileti = "ahbu-lk-fp/1|" + büyük harfli UID) çıktısının küçük harf hex
//           gösteriminin ilk 8 karakteri (= MAC'in ilk 4 baytı). UID = durumdaki "device" alanı (ör. AHBU-S3-DD8754).
//   * Amaç: istemci (uygulama/araç) panodaki anahtarın sunucudaki anahtarla AYNI olduğunu anahtarı görmeden karşılaştırır (Ethernet'te
//     auth/check her zaman 200 döndüğünden anahtar doğrulaması bununla yapılır). Parmak izi 32 bitlik bir HMAC özetidir; anahtarı vermez.
//   * Yayın: provizyonluyken tam GET /api/status ve MQTT state "lk_fp"; provizyonsuzken alan YOK; kısıtlı (anahtarsız) durumda ASLA yok.
//     Seri STATUS: "  - Anahtar izi: <8 hex|yok>". Anahtarın kendisi hiçbir yere yazılmaz/loglanmaz.
//   * Ortak test vektörleri (sunucu, simülatör, araç): ("ABCDEFGH23456789", "AHBU-S3-DD8754") -> "c7076562";
//     ("k3yTEST-9999", "AHBU-S3-0A1B2C") -> "9814f286".
// ============================================================================
#include <stddef.h>
#include <stdint.h>
#include <string.h>

namespace lkfp {

static const char MSG_PREFIX[] = "ahbu-lk-fp/1|";
enum : size_t {
  FP_HEX = 8,                                    // iz uzunluğu (hex karakter)
  FP_BUF = 9,                                    // + NUL
  UID_MAX = 32,
  MSG_MAX = sizeof(MSG_PREFIX) - 1 + UID_MAX     // NUL hariç
};

// İleti: "ahbu-lk-fp/1|" + büyük harfli UID (önek küçük harf kalır). Dönüş: ileti uzunluğu (NUL hariç); UID yok/boş/UID_MAX'tan uzunsa
// ya da tampon sığmıyorsa 0 (yarım ileti yazılmaz).
inline size_t buildMessage(char* out, size_t cap, const char* uid) {
  if (!out || !uid) return 0;
  const size_t pl = sizeof(MSG_PREFIX) - 1;
  size_t ul = 0;
  while (ul <= UID_MAX && uid[ul] != '\0') ul++;
  if (ul == 0 || ul > UID_MAX || pl + ul + 1 > cap) return 0;
  memcpy(out, MSG_PREFIX, pl);
  for (size_t i = 0; i < ul; i++) {
    const char c = uid[i];
    out[pl + i] = (c >= 'a' && c <= 'z') ? (char)(c - 'a' + 'A') : c;
  }
  out[pl + ul] = '\0';
  return pl + ul;
}

// MAC'in ilk 4 baytı -> 8 küçük harf hex + NUL (out en az FP_BUF bayt).
inline void toHex8(const uint8_t* mac, char* out) {
  static const char hx[] = "0123456789abcdef";
  for (size_t i = 0; i < 4; i++) {
    out[2 * i] = hx[mac[i] >> 4];
    out[2 * i + 1] = hx[mac[i] & 0x0F];
  }
  out[FP_HEX] = '\0';
}

// Geçerli iz: tam 8 küçük harf hex (sunucu kuralı /^[0-9a-f]{8}$/ ile aynı).
inline bool valid(const char* fp) {
  if (!fp) return false;
  for (size_t i = 0; i < FP_HEX; i++) {
    const char c = fp[i];
    if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) return false;
  }
  return fp[FP_HEX] == '\0';
}

// İz hesabı. hmac(anahtar, anahtarUz, ileti, iletiUz, mac[32]) -> bool. Anahtar yok/boş (provizyonsuz), UID geçersiz ya da HMAC hatası:
// false ve out boş (çöp/yarım iz yazılmaz). Ara MAC yığında sıfırlanır; anahtarın kopyasını tutmak çağıranın işidir (sıfırlar).
template <typename Hmac>
inline bool compute(const char* key, const char* uid, char* out, Hmac hmac) {
  if (!out) return false;
  out[0] = '\0';
  if (!key || key[0] == '\0') return false;
  char msg[MSG_MAX + 1];
  const size_t ml = buildMessage(msg, sizeof(msg), uid);
  if (ml == 0) return false;
  uint8_t mac[32];
  memset(mac, 0, sizeof(mac));
  const bool ok = hmac((const uint8_t*)key, strlen(key), (const uint8_t*)msg, ml, mac);
  if (ok) toHex8(mac, out);
  memset(mac, 0, sizeof(mac));
  return ok;
}

}  // namespace lkfp
