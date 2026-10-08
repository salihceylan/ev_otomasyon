#pragma once
// ============================================================================
// SystemConfig.h - Yapılandırma veri yapıları ve DOĞRULAMA kuralları. SAF MANTIK
// (yalnızca <stdint.h>/<stddef.h>/<string.h>; Arduino/FreeRTOS/NVS'e bağımlı DEĞİL).
//
// ConfigManager.h bunu include eder; alan/tip adları değişmemiştir. test/test_system_config
// validate()/setLocalKey()/totalRelays() kurallarını PC'de doğrular.
// ============================================================================
#include <stdint.h>
#include <stddef.h>
#include <string.h>

enum RelayType {
  RELAY_TYPE_LIGHT = 0,       // Normal lamba / aç-kapa cihaz
  RELAY_TYPE_SHUTTER_UP = 1,  // Panjur Yukarı (Interlock partner ile eşleşir)
  RELAY_TYPE_SHUTTER_DOWN = 2,// Panjur Aşağı (Interlock partner ile eşleşir)
  RELAY_TYPE_IMPULSE = 3      // Darbe rölesi (Belirli süre çekip bırakır, örn: kilit/otomatik)
};

enum DIMode {
  DI_MODE_TOGGLE = 0,         // Her basışta röle durumunu tersine çevir
  DI_MODE_MOMENTARY = 1,      // Butona basılıyken açık, bırakınca kapalı
  DI_MODE_SHUTTER_STEP = 2,   // Panjur butonu: Basınca hareket ettir/durdur (Tek buton döngü)
  DI_MODE_SHUTTER_UP = 3,     // Panjur Yukarı: Basınca Aç, basınca Durdur
  DI_MODE_SHUTTER_DOWN = 4    // Panjur Aşağı: Basınca Kapat, basınca Durdur
};

struct RelayConfig {
  char name[32];
  uint8_t type;               // RelayType
  uint16_t runtime_sec;       // Panjur için hareket süresi (sn, 1..300) veya darbe süresi (ms, 1..60000)
};

struct DIConfig {
  char name[32];
  uint8_t target_relay;       // 1-based röle numarası (0 = devre dışı)
  uint8_t mode;               // DIMode
};

#define MAX_TOTAL_RELAYS 40
#define MAX_TOTAL_DIS    40

// NVS ad alanları (ConfigManager.resetToDefaults() hepsini siler; SmartAutomation kullanır)
#define NVS_NS_CFG   "ahbu_cfg"    // yapılandırma + kimlik/provizyon alanları
#define NVS_NS_AUTO  "ahbu_auto"   // çocuk kilidi
#define NVS_NS_POS   "ahbu_pos"    // panjur konumları
// Güvenlik katmanı (spec §2.7) [Y-5]: "ahbu_safety" yapılandırmadır ve fabrika sıfırlamasında SİLİNİR;
// "ahbu_latch" (kilit kaydı, act_pos, açılış sayacı, çökme kaydı, siren birikimi) fabrika sıfırlamasında SİLİNMEZ.
#define NVS_NS_SAFETY "ahbu_safety"
#define NVS_NS_LATCH  "ahbu_latch"
// v1.3.0 (K-Ş3): karta yazılmış kurulum şablonunun kimliği / sürümü / daire etiketi. Yapılandırmadır: fabrika sıfırlamasında SİLİNİR.
#define NVS_NS_TPL    "ahbu_tpl"

// Yerel erişim anahtarı / AP parolası sınırları (docs/CONTRACTS.md §3)
#define LOCAL_KEY_MIN_LEN   8
#define LOCAL_KEY_MAX_LEN   32
#define AP_PASS_MIN_LEN     8
#define AP_PASS_MAX_LEN     32

// Panjur süre sınırları (CONTRACTS §2.3 set_runtime: 1..300 sn)
#define SHUTTER_RUNTIME_MIN_SEC   1
#define SHUTTER_RUNTIME_MAX_SEC   300
#define SHUTTER_RUNTIME_DEFAULT_SEC 20
#define IMPULSE_MS_MAX            60000
#define IMPULSE_MS_DEFAULT        1000

// Sunucu adı gizli değildir; kimlik (kullanıcı/parola) ise DERLEMEYE GÖMÜLMEZ (CONTRACTS §3).
#define DEFAULT_MQTT_SERVER "evotomasyon.gudeteknoloji.com.tr"
#define DEFAULT_MQTT_PORT   8884

// Geçerli ek modül kanal sayıları: {0,2,4,8,12,16,24,32}
inline bool isValidExtChannelCount(uint8_t channels) {
  switch (channels) {
    case 0: case 2: case 4: case 8: case 12: case 16: case 24: case 32:
      return true;
    default:
      return false;
  }
}

namespace sysconfig_detail {

// n bayt uzunluğunda (NUL hariç) ve [lo, hi] aralığında yazdırılabilir ASCII mi?
inline bool isAsciiRange(const char* s, size_t minLen, size_t maxLen, uint8_t lo, uint8_t hi) {
  if (!s) return false;
  size_t n = strnlen(s, maxLen + 1);
  if (n < minLen || n > maxLen) return false;
  for (size_t i = 0; i < n; i++) {
    uint8_t c = (uint8_t)s[i];
    if (c < lo || c > hi) return false;
  }
  return true;
}

// Ham arabelleği her zaman NUL ile sonlandırır (strncpy(dst, src, size-1) bunu garanti etmez).
template <size_t N>
inline void terminate(char (&buf)[N]) { buf[N - 1] = '\0'; }

template <size_t N>
inline void copyStr(char (&dst)[N], const char* src) {
  memset(dst, 0, N);
  if (src) strncpy(dst, src, N - 1);
}

}  // namespace sysconfig_detail

struct SystemConfig {
  char device_name[32];
  char wifi_ssid[64];
  char wifi_pass[64];
  bool wifi_sta_enabled;
  uint32_t rs485_baud;

  // Harici Genişletme Modülü (RS485)
  bool ext_module_enabled;       // Ek modül var mı?
  uint8_t ext_module_channels;   // Kaç kanallı? (0, 2, 4, 8, 12, 16, 24, 32)
  uint8_t ext_module_address;    // Modbus Slave Adresi (1..247, varsayılan 1)

  // Güvenli MQTTS (Port 8884). DERLEME İÇİNDE VARSAYILAN KİMLİK YOKTUR:
  // mqtt_user/mqtt_pass boş gelir ve POST /api/mqtt/config (veya servis aracı) ile yazılır.
  // Kimlik yoksa MQTT başlamaz, cihaz yerelde çalışır (CONTRACTS §3).
  bool mqtt_enabled;
  char mqtt_server[64];
  uint16_t mqtt_port;
  char mqtt_user[48];            // ör. "d_h_<16 hex>" (cihaz kimliği)
  char mqtt_pass[64];            // cihaz başına rastgele parola

  // Yerel HTTP API kimliği (CONTRACTS §3). BOŞ = provizyonsuz cihaz.
  char local_key[LOCAL_KEY_MAX_LEN + 1];   // X-Device-Key (8..32 karakter)
  char ap_pass[AP_PASS_MAX_LEN + 1];       // cihaza özel kurtarma/kurulum AP parolası (8..32)

  RelayConfig relays[MAX_TOTAL_RELAYS];
  DIConfig dis[MAX_TOTAL_DIS];

  uint8_t totalRelays() const {
    if (!ext_module_enabled) return 8;
    uint16_t t = 8u + ext_module_channels;     // uint8_t taşması (8+250=2) olmasın
    return (t > MAX_TOTAL_RELAYS) ? (uint8_t)MAX_TOTAL_RELAYS : (uint8_t)t;
  }

  uint8_t totalDIs() const {
    if (!ext_module_enabled) return 8;
    uint16_t t = 8u + ext_module_channels;
    return (t > MAX_TOTAL_DIS) ? (uint8_t)MAX_TOTAL_DIS : (uint8_t)t;
  }

  // ---- FW-net için yardımcılar (yalnızca RAM; kalıcılık için ConfigManager::save()) ----
  bool hasLocalKey() const { return local_key[0] != '\0'; }
  bool hasMqttCredentials() const {
    return mqtt_server[0] != '\0' && mqtt_user[0] != '\0' && mqtt_pass[0] != '\0';
  }

  // 8..32 karakter, yalnızca yazdırılabilir ASCII (0x21..0x7E, boşluk yok). Geçersizse false ve değişiklik YOK.
  bool setLocalKey(const char* key) {
    // Boşluk ve kontrol karakteri yok (HTTP başlık değeri olarak güvenle taşınır).
    if (!sysconfig_detail::isAsciiRange(key, LOCAL_KEY_MIN_LEN, LOCAL_KEY_MAX_LEN, 0x21, 0x7E)) return false;
    sysconfig_detail::copyStr(local_key, key);
    return true;
  }

  // 8..32 karakter, 0x20..0x7E. Geçersizse false ve değişiklik YOK.
  bool setApPass(const char* pass) {
    if (!sysconfig_detail::isAsciiRange(pass, AP_PASS_MIN_LEN, AP_PASS_MAX_LEN, 0x20, 0x7E)) return false;
    sysconfig_detail::copyStr(ap_pass, pass);
    return true;
  }

  // Aralık/kapsam doğrulaması; geçersiz alanı güvenli varsayılana çeker.
  // true = yapılandırma zaten geçerliydi, false = en az bir alan onarıldı.
  bool validate() {
    using namespace sysconfig_detail;
    bool ok = true;

    // --- Metin alanları: her zaman NUL sonlandırılmış ---
    terminate(device_name);
    terminate(wifi_ssid);
    terminate(wifi_pass);
    terminate(mqtt_server);
    terminate(mqtt_user);
    terminate(mqtt_pass);
    terminate(local_key);
    terminate(ap_pass);

    if (device_name[0] == '\0') {
      copyStr(device_name, "AHBU Akilli Ev Kontrol");
      ok = false;
    }

    // --- Wi-Fi: SSID 1..32 bayt, parola 0 veya 8..63 ---
    size_t ssidLen = strlen(wifi_ssid);
    size_t passLen = strlen(wifi_pass);
    if (ssidLen > 32 || (passLen != 0 && (passLen < 8 || passLen > 63))) {
      wifi_ssid[0] = '\0';
      wifi_pass[0] = '\0';
      wifi_sta_enabled = false;
      ok = false;
    }
    if (wifi_sta_enabled && wifi_ssid[0] == '\0') {
      wifi_sta_enabled = false;
      ok = false;
    }

    // --- RS485 baud: yalnızca bilinen değerler ---
    switch (rs485_baud) {
      case 4800: case 9600: case 19200: case 38400: case 57600: case 115200:
        break;
      default:
        rs485_baud = 9600;
        ok = false;
        break;
    }

    // --- Ek modül ---
    if (!isValidExtChannelCount(ext_module_channels)) {
      ext_module_channels = ext_module_enabled ? 8 : 0;
      ok = false;
    }
    if (ext_module_enabled && ext_module_channels == 0) {
      ext_module_channels = 8;   // etkin ama kanal sayısı yok: varsayılan 8 (sunucu da aynı normalizasyonu yapar)
      ok = false;
    }
    if (ext_module_address < 1 || ext_module_address > 247) {
      ext_module_address = 1;
      ok = false;
    }

    // --- MQTT ---
    if (mqtt_port == 0) {
      mqtt_port = DEFAULT_MQTT_PORT;
      ok = false;
    }
    if (mqtt_server[0] == '\0') {
      copyStr(mqtt_server, DEFAULT_MQTT_SERVER);
      ok = false;
    }

    // --- Yerel anahtar / AP parolası: geçersizse silinir (kısmi/bozuk kimlik asla kalmaz) ---
    if (local_key[0] != '\0' &&
        !isAsciiRange(local_key, LOCAL_KEY_MIN_LEN, LOCAL_KEY_MAX_LEN, 0x21, 0x7E)) {
      memset(local_key, 0, sizeof(local_key));
      ok = false;
    }
    if (ap_pass[0] != '\0' &&
        !isAsciiRange(ap_pass, AP_PASS_MIN_LEN, AP_PASS_MAX_LEN, 0x20, 0x7E)) {
      memset(ap_pass, 0, sizeof(ap_pass));
      ok = false;
    }

    // --- Röleler ---
    for (int i = 0; i < MAX_TOTAL_RELAYS; i++) {
      RelayConfig& r = relays[i];
      terminate(r.name);
      if (r.type > RELAY_TYPE_IMPULSE) {
        r.type = RELAY_TYPE_LIGHT;
        r.runtime_sec = 0;
        ok = false;
      }
      if (r.type == RELAY_TYPE_SHUTTER_UP || r.type == RELAY_TYPE_SHUTTER_DOWN) {
        if (r.runtime_sec < SHUTTER_RUNTIME_MIN_SEC || r.runtime_sec > SHUTTER_RUNTIME_MAX_SEC) {
          r.runtime_sec = SHUTTER_RUNTIME_DEFAULT_SEC;
          ok = false;
        }
      } else if (r.type == RELAY_TYPE_IMPULSE) {
        if (r.runtime_sec == 0) {
          r.runtime_sec = IMPULSE_MS_DEFAULT;
          ok = false;
        } else if (r.runtime_sec > IMPULSE_MS_MAX) {
          r.runtime_sec = IMPULSE_MS_MAX;
          ok = false;
        }
      }
    }

    // --- Dijital girişler ---
    const uint8_t totalR = totalRelays();
    const uint8_t totalD = totalDIs();
    for (int i = 0; i < MAX_TOTAL_DIS; i++) {
      DIConfig& d = dis[i];
      terminate(d.name);
      if (d.mode > DI_MODE_SHUTTER_DOWN) {
        d.mode = DI_MODE_TOGGLE;
        ok = false;
      }
      uint8_t limit = (i < totalD) ? totalR : (uint8_t)MAX_TOTAL_RELAYS;
      if (d.target_relay > limit) {
        d.target_relay = 0;   // devre dışı
        ok = false;
      }
    }
    return ok;
  }
};
