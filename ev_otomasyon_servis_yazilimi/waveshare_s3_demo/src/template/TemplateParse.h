#pragma once
// ============================================================================
// template/TemplateParse.h - Kurulum şablonu (ahbu-template/1) ayrıştırıcı + doğrulayıcı. SAF MANTIK (ArduinoJson + saf başlıklar;
// Arduino/FreeRTOS/NVS YOK) -> PC'de (pio test -e native, test/test_template_parse) ortak örnek dosyalarla sınanır.
//
// Sözleşme: docs/contracts/template/README.md (tek kaynak; sunucu ve servis yazılımı aynı kuralları uygular, firmware son sözü söyler).
// Plan: docs/superpowers/plans/2026-10-08-site-sablon-kurulum.md K-Ş2, K-Ş3, İP-2.3.
//  * Uygulama zarfı {"template":{...},"label":"..."} -> aday ana yapılandırma (SystemConfig) + aday güvenlik yapılandırması (SafetyConfig).
//  * Doğrulama sırası README "Doğrulama sırası" ile birebir: schema -> kök alanlar -> meta -> ext_module -> relays (sayı/sıra -> öğe ->
//    panjur çiftleri -> çift süreleri) -> dis (sayı/sıra -> öğe) -> safety (policy -> intrusion -> zones -> sensors -> actuators -> lights).
//    İlk hata döner (kod + yol).
//  * Güvenlik öğeleri (sensör / eylemci / ışık) tek öğeli yamayla AYNI kodla okunur (safety/SafetyCfgApi.h parse*Item); ardından
//    firmware'in kendi çapraz doğrulaması (safety::validate) çalışır. Şablon düzeyindeki ek kurallar burada: sensör/eylemci bölgesi
//    `zones` içinde tanımlı olmalı, panjur çifti süreleri eşit, panjur DI kipleri çiftin YUKARI rölesini hedefler, ek modül kapalıyken
//    kanal 0, ışık seçeneği yalnız lamba tipi röleye (benzersiz).
//  * Kartta saklanmayan alanlar (room, load, wiring, meta.name/flat_type/site_id) yalnız doğrulanır.
//  * Cihaza bağlı denetimler (kilitli bölge, kurulu alarm, panjur hareketi, açılış güvenli maskesi -> validateSystemChange, LAN gevşetme
//    yasağı, NVS payı) burada DEĞİL, uygulama adımındadır (template/TemplateApply).
// ============================================================================
#include <ArduinoJson.h>
#include <stdint.h>
#include <stddef.h>
#include "SystemConfig.h"
#include "safety/SafetyConfig.h"

namespace tpl {

enum : uint32_t {
  TPL_MAX_BYTES = 24576,       // gövde üst sınırı (HTTP ve seri TPL aynı)
  TPL_ID_LEN = 36,             // UUID, küçük harf
  TPL_LABEL_MAX = 31,          // label / device_name (bayt, UTF-8)
  TPL_PATH_LEN = 48
};

static const char* const TPL_SCHEMA = "ahbu-template/1";

struct TplError {
  const char* code;            // makine okunur kod (README; nullptr = hata yok)
  char path[TPL_PATH_LEN];     // ör. "relays[3].runtime_s" (boş olabilir)
};

struct TplCandidate {
  char templateId[TPL_ID_LEN + 1];
  uint32_t version;
  char label[TPL_LABEL_MAX + 1];   // etkin ad = device_name: zarftaki label, boşsa meta.name'in ilk 31 baytı (UTF-8 güvenli)
  SystemConfig sys;                // taban (canlı kopya) + şablonun ext_module / relays / dis / device_name alanları
  safety::SafetyConfig safety;     // fabrika varsayılanı + şablonun güvenlik bölümü (rev uygulamada atanır)
};

// root: uygulama zarfı. base: canlı ana yapılandırmanın kopyası (Wi-Fi / MQTT / kimlik / baud KORUNUR).
// true: out geçerli (aday, safety::validate geçti). false: err.code (+ path) dolu, out tanımsız.
bool parseEnvelope(JsonObject root, const SystemConfig& base, TplCandidate& out, TplError& err);

// Yalnız şablon nesnesi (örnek dosya testleri; label yok -> device_name = meta.name).
bool parseTemplate(JsonObject t, const SystemConfig& base, TplCandidate& out, TplError& err);

// Yardımcılar (testli)
bool isLowerUuid(const char* s);

}  // namespace tpl
