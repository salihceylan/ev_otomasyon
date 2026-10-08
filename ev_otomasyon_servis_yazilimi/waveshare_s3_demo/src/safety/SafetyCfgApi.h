#pragma once
// ============================================================================
// safety/SafetyCfgApi.h - Güvenlik yapılandırması yamasının JSON ayrıştırıcısı (ArduinoJson). BAĞLAYICI: karar içermez; CfgEdit üretir.
//
// Ortak biçim (LAN POST /api/safety/config ve bulut sys cfg_patch, spec §4.1-4.2; CONTRACTS §2.6):
//   {"base_rev":12, "set":{"sensor":{"id":"d3","kind":"water","zone":1,"active_open":0,"flags":1,"confirm_ms":1000,"name":"Banyo"}}}
//   {"base_rev":12, "set":{"actuator":{"id":"a1","relay":5,"kind":"valve","close_mode":"deenergize","medium":"water","zones":[1], ...}}}
//   {"base_rev":12, "set":{"policy":{"on":true,"dry_hold_ms":10000}}} | {"set":{"zone":{"id":2,"name":"Mutfak"}}}
//   {"set":{"light":{"relay":3,"dimmable":1,"src":1,"addr":2,"ch":1}}} | {"del":{"sensor":"d3"}} | {"del":{"actuator":"a2"}}
//   {"set":{"intrusion":{"exit_s":45,"entry_s":30}}} (Faz 2 F2.B.7: 0..255, 0 = varsayılan; en az biri). Sensör "flags" 0..0x1F (bit3 entry,
//   bit4 away_only; v1.2.0 sınırı 0x07); "kind":"arm_key" yalnız panodaki DI'den (anahtarlı kontak).
// "set" ve "del" içinde TEK öğe vardır. Bilinmeyen alan / tip uyuşmazlığı / aralık dışı değer: yama UYGULANMAZ (sessiz varsayılan yok).
// İsteğe bağlı alanların varsayılanları: sensör flags/confirm_ms türün varsayılanı; eylemci close_mode "energize", fb_closed_active 1,
// fb_timeout_s 60, run_limit_s siren 180 / iki röleli vana 15. "id" verilmeyen eylemci yeni satırdır (sona eklenir).
// sysEnvelope: sys zarfının cmd/module/uid/id alanları kök nesnede bulunabilir (çağıran ayrıca denetler).
// ============================================================================
#include <ArduinoJson.h>
#include "safety/SafetyCfgEdit.h"

namespace safety {

bool parseSensorId(const char* s, uint8_t& src, uint8_t& index);   // "d1".."d40" | "b1".."b16"
bool parseActuatorId(const char* s, uint8_t& idx0);                // "a1".."a16" -> 0..15

// Dönüş: nullptr (başarılı) ya da makine okunur neden ("bad_field", "bad_value", ...).
const char* parseCfgEdit(JsonObject root, CfgEdit& e, bool& hasBase, uint32_t& baseRev, bool sysEnvelope);

// Ortak öğe ayrıştırıcıları (v1.3.0 İP-2.3): tek öğeli yama (parseCfgEdit) ve kurulum şablonu (template/TemplateParse) AYNI kodla
// sensör / eylemci / ışık nesnesi okur; çıktı önce sıfırlanır, varsayılanlar yukarıdaki gibidir. Dönüş: nullptr ya da neden.
// allowId=false: eylemci nesnesinde "id" alanı yasaktır (şablonda sıra = a1..; "bad_field"). actIndex: "id" yoksa 0xFF.
const char* parseSensorItem(JsonObject o, SensorConfig& sens);
const char* parseActuatorItem(JsonObject o, ActuatorConfig& act, uint8_t& actIndex, bool allowId);
const char* parseLightItem(JsonObject o, uint8_t& relay, LightOpt& light);

}  // namespace safety
