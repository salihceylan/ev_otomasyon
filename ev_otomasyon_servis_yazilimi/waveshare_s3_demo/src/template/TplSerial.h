#pragma once
// ============================================================================
// template/TplSerial.h - Seri (USB) şablon aktarımı "TPL" çerçevelemesi. SAF MANTIK (yalnız <stdint.h>/<string.h> + CRC32);
// Arduino/FreeRTOS YOK -> PC'de (test/test_tpl_serial) sınanır. Bağlayıcı: main.cpp (seri CLI, loopTask).
//
// Sözleşme (docs/contracts/template/README.md "Seri protokol", plan K-Ş5):
//   TPL BEGIN <bayt> <crc32-hex8>   -> OK tpl_begin
//   TPL DATA <base64, <=150 karakter> -> OK tpl_data <alınan_bayt>       (satır [CLI] Komut alindi ile YANKILANMAZ)
//   TPL COMMIT                      -> OK tpl_applied <template_id> <version> | ERR <kod> [path]
//   TPL ABORT                       -> OK tpl_abort
//   TPL STATUS                      -> TPL <template_id|-> <version> <label>
// Gövde = uygulama zarfının UTF-8 JSON baytları, en çok 24576 bayt; CRC-32 IEEE (zlib.crc32 ile aynı; safety::crc32).
// BEGIN'den sonra 30 sn içinde COMMIT yoksa aktarım silinir; bir sonraki DATA/COMMIT "ERR tpl_timeout" alır.
// Hata kodları: tpl_no_begin, tpl_size, tpl_crc, tpl_overflow, tpl_timeout, tpl_b64 (geçersiz base64 / 150 karakter üstü; README'de
// yok, firmware ek kodu) + uygulama kodları. Bozuk aktarım (taşma, base64, boyut, CRC) SİLİNİR; araç baştan BEGIN ile başlar.
// Base64 parçaları 4 karakter sınırına hizalı olmak zorunda değildir (artan 1..3 karakter sonraki DATA ile birleşir).
// ZAMAN KURALI (CONTRACTS §3c): zaman aşımı "başlangıç + bekleme" çiftidir ve sahip görev (loopTask) poll()'u HER TUR çağırır;
// süre dolunca aktarım ANINDA sonlanır (saklanmış hedef zaman + işaretli karşılaştırma yok).
// ============================================================================
#include <stdint.h>
#include <string.h>
#include "safety/SafetyConfig.h"   // safety::crc32Update (IEEE, yansıtılmış)

namespace tpl {

enum : uint32_t { TPL_SERIAL_MAX = 24576, TPL_TIMEOUT_MS = 30000, TPL_DATA_MAX_CHARS = 150 };

enum class RxErr : uint8_t { OK = 0, NO_BEGIN, BAD_SIZE, BAD_CRC, OVERRUN, TIMED_OUT, BAD_B64 };

inline const char* rxErrText(RxErr e) {
  switch (e) {
    case RxErr::NO_BEGIN: return "tpl_no_begin";
    case RxErr::BAD_SIZE: return "tpl_size";
    case RxErr::BAD_CRC: return "tpl_crc";
    case RxErr::OVERRUN: return "tpl_overflow";
    case RxErr::TIMED_OUT: return "tpl_timeout";
    case RxErr::BAD_B64: return "tpl_b64";
    default: return "ok";
  }
}

inline int b64Val(char c) {
  if (c >= 'A' && c <= 'Z') return c - 'A';
  if (c >= 'a' && c <= 'z') return c - 'a' + 26;
  if (c >= '0' && c <= '9') return c - '0' + 52;
  if (c == '+') return 62;
  if (c == '/') return 63;
  return -1;
}

// BEGIN argümanları: <bayt> 1..24576 ondalık (baştaki sıfır yok), <crc32> tam 8 onaltılık hane (büyük/küçük harf).
inline RxErr parseBeginArgs(const char* sizeStr, const char* crcStr, uint32_t& size, uint32_t& crc) {
  if (!sizeStr || !*sizeStr || sizeStr[0] == '0') return RxErr::BAD_SIZE;
  uint32_t v = 0;
  for (const char* p = sizeStr; *p; p++) {
    if (*p < '0' || *p > '9' || v > TPL_SERIAL_MAX) return RxErr::BAD_SIZE;
    v = v * 10u + (uint32_t)(*p - '0');
  }
  if (v < 1 || v > TPL_SERIAL_MAX) return RxErr::BAD_SIZE;
  if (!crcStr || strlen(crcStr) != 8) return RxErr::BAD_CRC;
  uint32_t c = 0;
  for (int i = 0; i < 8; i++) {
    const char ch = crcStr[i];
    uint32_t d;
    if (ch >= '0' && ch <= '9') d = (uint32_t)(ch - '0');
    else if (ch >= 'a' && ch <= 'f') d = (uint32_t)(ch - 'a' + 10);
    else if (ch >= 'A' && ch <= 'F') d = (uint32_t)(ch - 'A' + 10);
    else return RxErr::BAD_CRC;
    c = (c << 4) | d;
  }
  size = v;
  crc = c;
  return RxErr::OK;
}

// Aktarım durumu. Arabellek bağlayıcıdan gelir (BEGIN'de <bayt> kadar ayrılır); takeBuffer() ile geri alınıp serbest bırakılır.
struct TplRx {
  uint8_t* buf;
  uint32_t size;
  uint32_t got;
  uint32_t crc;
  uint32_t startMs;
  uint8_t quad[4];
  uint8_t qn;
  bool active;
  bool ended;      // dolgu ('=') görüldü: başka veri gelemez
  bool timedOut;   // zaman aşımı oldu; bir sonraki DATA/COMMIT tpl_timeout alır

  TplRx() : buf(nullptr), size(0), got(0), crc(0), startMs(0), qn(0), active(false), ended(false), timedOut(false) {
    memset(quad, 0, sizeof(quad));
  }

  // Bırakılan arabellek (çağıran serbest bırakır); durum sıfırlanır.
  uint8_t* takeBuffer() {
    uint8_t* b = buf;
    buf = nullptr;
    active = false;
    size = got = crc = 0;
    qn = 0;
    ended = false;
    return b;
  }

  // Önceki aktarım (varsa) çağıran tarafından takeBuffer() ile alınmış olmalıdır. buffer en az size bayt.
  void begin(uint32_t sz, uint32_t crc32v, uint8_t* buffer, uint32_t now) {
    buf = buffer;
    size = sz;
    crc = crc32v;
    got = 0;
    qn = 0;
    ended = false;
    timedOut = false;
    active = true;
    startMs = now;
  }

  // Her tur: 30 sn dolduysa true (aktarım sonlandı; çağıran takeBuffer() ile arabelleği serbest bırakır).
  bool poll(uint32_t now) {
    if (!active) return false;
    if ((uint32_t)(now - startMs) < TPL_TIMEOUT_MS) return false;
    active = false;
    timedOut = true;
    return true;
  }

  // Durum hatası (aktarım yok / zaman aşımı). Zaman aşımı bir kez bildirilir.
  RxErr stateErr() {
    if (timedOut) {
      timedOut = false;
      return RxErr::TIMED_OUT;
    }
    return RxErr::NO_BEGIN;
  }

  // DATA: base64 parçası. Hata döndüğünde (NO_BEGIN/TIMEOUT dışında) aktarım iptal edilmiştir (active=false; arabellek takeBuffer ile).
  RxErr data(const char* b64, uint32_t now) {
    (void)now;
    if (!active) return stateErr();
    const size_t n = b64 ? strlen(b64) : 0;
    if (n == 0 || n > TPL_DATA_MAX_CHARS) { active = false; return RxErr::BAD_B64; }
    for (size_t i = 0; i < n; i++) {
      const char c = b64[i];
      if (ended) { active = false; return RxErr::BAD_B64; }
      if (c == '=') {
        // dolgu yalnız dörtlünün 3. ya da 4. karakteri olabilir
        if (qn < 2) { active = false; return RxErr::BAD_B64; }
        quad[qn++] = 0xFF;   // işaret
        if (qn == 4) {
          if (!flushQuad()) return RxErr::OVERRUN;
          ended = true;
        }
        continue;
      }
      const int v = b64Val(c);
      if (v < 0 || (qn > 0 && quad[qn - 1] == 0xFF)) { active = false; return RxErr::BAD_B64; }   // dolgudan sonra veri olmaz
      quad[qn++] = (uint8_t)v;
      if (qn == 4 && !flushQuad()) return RxErr::OVERRUN;
    }
    return RxErr::OK;
  }

  // COMMIT: OK ise buf[0..size) tam gövdedir (aktarım kapanır; çağıran gövdeyi kullanıp takeBuffer() ile serbest bırakır).
  RxErr commit(uint32_t now) {
    (void)now;
    if (!active) return stateErr();
    active = false;
    if (qn != 0) return RxErr::BAD_B64;
    if (got != size) return RxErr::BAD_SIZE;
    if (safety::crc32(buf, size) != crc) return RxErr::BAD_CRC;
    return RxErr::OK;
  }

  void abort() {
    active = false;
    timedOut = false;
  }

 private:
  bool flushQuad() {
    const bool p3 = quad[2] == 0xFF, p4 = quad[3] == 0xFF;
    const uint8_t v2 = p3 ? 0 : quad[2], v3 = p4 ? 0 : quad[3];
    const uint8_t out[3] = {(uint8_t)((quad[0] << 2) | (quad[1] >> 4)), (uint8_t)(((quad[1] & 0x0F) << 4) | (v2 >> 2)),
                            (uint8_t)(((v2 & 0x03) << 6) | v3)};
    const uint32_t k = p3 ? 1u : (p4 ? 2u : 3u);
    qn = 0;
    if (got + k > size) {
      active = false;
      return false;
    }
    memcpy(buf + got, out, k);
    got += k;
    return true;
  }
};

}  // namespace tpl
