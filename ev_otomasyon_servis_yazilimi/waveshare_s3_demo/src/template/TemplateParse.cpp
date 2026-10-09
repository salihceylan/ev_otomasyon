// template/TemplateParse.cpp - ahbu-template/1 ayrıştırıcı + doğrulayıcı (bkz. TemplateParse.h). SAF MANTIK.
#include "template/TemplateParse.h"
#include "safety/SafetyCfgApi.h"
#include "Utf8Util.h"
#include <stdio.h>
#include <string.h>

namespace tpl {

namespace {

bool fail(TplError& e, const char* code, const char* path) {
  e.code = code;
  snprintf(e.path, sizeof(e.path), "%s", path ? path : "");
  sanitizePath(e.path);
  return false;
}

bool failIdx(TplError& e, const char* code, const char* fmt, unsigned i) {
  e.code = code;
  snprintf(e.path, sizeof(e.path), fmt, i);
  sanitizePath(e.path);
  return false;
}

bool failIdx2(TplError& e, const char* code, const char* fmt, unsigned i, const char* field) {
  e.code = code;
  snprintf(e.path, sizeof(e.path), fmt, i, field);
  sanitizePath(e.path);
  return false;
}

// Nesnede yalnız izinli anahtarlar var mı? Değilse ilk yabancı anahtar 'bad'e yazılır.
bool onlyKeys(JsonObject o, const char* const* keys, size_t n, const char*& bad) {
  for (JsonPair kv : o) {
    bool ok = false;
    for (size_t i = 0; i < n && !ok; i++) ok = strcmp(kv.key().c_str(), keys[i]) == 0;
    if (!ok) {
      bad = kv.key().c_str();
      return false;
    }
  }
  return true;
}

const char* strOf(JsonVariant v) { return v.is<const char*>() ? v.as<const char*>() : nullptr; }

// minB..maxB bayt, geçerli UTF-8, kontrol karakteri yok.
bool textOk(const char* s, size_t minB, size_t maxB) {
  if (!s) return false;
  const size_t n = strlen(s);
  return n >= minB && n <= maxB && NetUtil::isCleanUtf8(s, n);
}

// İsteğe bağlı metin alanı: yoksa geçerli; varsa string ve sınır içinde.
bool optText(JsonObject o, const char* k, size_t maxB) {
  if (!o.containsKey(k)) return true;
  return textOk(strOf(o[k]), 0, maxB);
}

bool intIn(JsonVariant v, int32_t lo, int32_t hi, int32_t& out) {
  if (!v.is<int32_t>()) return false;
  out = v.as<int32_t>();
  return out >= lo && out <= hi;
}

uint8_t relayTypeOf(const char* s) {
  if (!s) return 0xFF;
  if (!strcmp(s, "light")) return RELAY_TYPE_LIGHT;
  if (!strcmp(s, "shutter_up")) return RELAY_TYPE_SHUTTER_UP;
  if (!strcmp(s, "shutter_down")) return RELAY_TYPE_SHUTTER_DOWN;
  if (!strcmp(s, "impulse")) return RELAY_TYPE_IMPULSE;
  return 0xFF;
}

uint8_t diModeOf(const char* s) {
  if (!s) return 0xFF;
  if (!strcmp(s, "toggle")) return DI_MODE_TOGGLE;
  if (!strcmp(s, "momentary")) return DI_MODE_MOMENTARY;
  if (!strcmp(s, "shutter_step")) return DI_MODE_SHUTTER_STEP;
  if (!strcmp(s, "shutter_up")) return DI_MODE_SHUTTER_UP;
  if (!strcmp(s, "shutter_down")) return DI_MODE_SHUTTER_DOWN;
  return 0xFF;
}

bool isHex(char c) { return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'); }

// ---- meta ----
bool parseMeta(JsonVariant v, TplCandidate& out, TplError& e) {
  if (!v.is<JsonObject>()) return fail(e, "bad_field", "meta");
  JsonObject m = v.as<JsonObject>();
  static const char* const K[] = {"template_id", "version", "name", "flat_type", "site_id"};
  const char* bad = nullptr;
  if (!onlyKeys(m, K, 5, bad)) {
    char p[TPL_PATH_LEN];
    snprintf(p, sizeof(p), "meta.%s", bad);
    return fail(e, "bad_field", p);
  }
  for (const char* k : K) {
    if (!m.containsKey(k)) {
      char p[TPL_PATH_LEN];
      snprintf(p, sizeof(p), "meta.%s", k);
      return fail(e, "bad_field", p);
    }
  }
  const char* id = strOf(m["template_id"]);
  if (!isLowerUuid(id)) return fail(e, "invalid_template_id", "meta.template_id");
  int32_t ver = 0;
  if (!intIn(m["version"], 1, INT32_MAX, ver)) return fail(e, "invalid_version", "meta.version");
  if (!textOk(strOf(m["name"]), 1, 48)) return fail(e, "invalid_name", "meta.name");
  if (!textOk(strOf(m["flat_type"]), 1, 16)) return fail(e, "invalid_flat_type", "meta.flat_type");
  if (!m["site_id"].isNull() && !isLowerUuid(strOf(m["site_id"]))) return fail(e, "invalid_site_id", "meta.site_id");
  memcpy(out.templateId, id, TPL_ID_LEN);
  out.templateId[TPL_ID_LEN] = '\0';
  out.version = (uint32_t)ver;
  NetUtil::copyUtf8Truncated(out.label, sizeof(out.label), strOf(m["name"]));   // label yoksa device_name
  return true;
}

// ---- ext_module ----
bool parseExt(JsonVariant v, SystemConfig& sys, uint8_t& n, TplError& e) {
  if (!v.is<JsonObject>()) return fail(e, "bad_field", "ext_module");
  JsonObject x = v.as<JsonObject>();
  static const char* const K[] = {"enabled", "channels", "address"};
  const char* bad = nullptr;
  if (!onlyKeys(x, K, 3, bad)) {
    char p[TPL_PATH_LEN];
    snprintf(p, sizeof(p), "ext_module.%s", bad);
    return fail(e, "bad_field", p);
  }
  if (!x["enabled"].is<bool>()) return fail(e, "bad_field", "ext_module.enabled");
  const bool en = x["enabled"].as<bool>();
  int32_t ch = 0, addr = 0;
  if (!intIn(x["channels"], 0, 255, ch) || !isValidExtChannelCount((uint8_t)ch) || (en ? ch == 0 : ch != 0)) {
    return fail(e, "invalid_ext_channels", "ext_module.channels");
  }
  if (!intIn(x["address"], 1, 247, addr)) return fail(e, "invalid_ext_address", "ext_module.address");
  sys.ext_module_enabled = en;
  sys.ext_module_channels = (uint8_t)ch;
  sys.ext_module_address = (uint8_t)addr;
  n = (uint8_t)(8 + (en ? ch : 0));
  return true;
}

// ---- relays ----
bool parseRelays(JsonVariant v, SystemConfig& sys, uint8_t n, TplError& e) {
  if (!v.is<JsonArray>() || v.as<JsonArray>().size() != n) return fail(e, "relay_count", "relays");
  JsonArray a = v.as<JsonArray>();
  // 1) sayı/sıra
  for (unsigned i = 0; i < n; i++) {
    JsonVariant it = a[i];
    int32_t ch = 0;
    if (!it.is<JsonObject>() || !intIn(it["ch"], 1, MAX_TOTAL_RELAYS, ch) || ch != (int32_t)(i + 1)) {
      return failIdx(e, "relay_count", "relays[%u].ch", i);
    }
  }
  // 2) her öğe
  static const char* const K[] = {"ch", "name", "room", "type", "runtime_s", "pulse_ms", "load"};
  for (unsigned i = 0; i < n; i++) {
    JsonObject r = a[i].as<JsonObject>();
    const char* bad = nullptr;
    if (!onlyKeys(r, K, 7, bad)) return failIdx2(e, "bad_field", "relays[%u].%s", i, bad);
    const char* name = strOf(r["name"]);
    if (!textOk(name, 1, 31)) return failIdx(e, "invalid_name", "relays[%u].name", i);
    if (!optText(r, "room", 31)) return failIdx(e, "invalid_room", "relays[%u].room", i);
    if (!optText(r, "load", 48)) return failIdx(e, "invalid_load", "relays[%u].load", i);
    const uint8_t type = relayTypeOf(strOf(r["type"]));
    if (type == 0xFF) return failIdx(e, "invalid_type", "relays[%u].type", i);
    const bool shutter = type == RELAY_TYPE_SHUTTER_UP || type == RELAY_TYPE_SHUTTER_DOWN;
    const bool impulse = type == RELAY_TYPE_IMPULSE;
    int32_t rt = 0, pm = 0;
    if (shutter) {
      if (!intIn(r["runtime_s"], SHUTTER_RUNTIME_MIN_SEC, SHUTTER_RUNTIME_MAX_SEC, rt)) return failIdx(e, "invalid_runtime", "relays[%u].runtime_s", i);
    } else if (r.containsKey("runtime_s")) {
      return failIdx(e, "invalid_runtime", "relays[%u].runtime_s", i);
    }
    if (impulse) {
      if (!intIn(r["pulse_ms"], 100, IMPULSE_MS_MAX, pm)) return failIdx(e, "invalid_runtime", "relays[%u].pulse_ms", i);
    } else if (r.containsKey("pulse_ms")) {
      return failIdx(e, "invalid_runtime", "relays[%u].pulse_ms", i);
    }
    RelayConfig& rc = sys.relays[i];
    memset(rc.name, 0, sizeof(rc.name));
    memcpy(rc.name, name, strlen(name));
    rc.type = type;
    rc.runtime_sec = (uint16_t)(shutter ? rt : (impulse ? pm : 0));
  }
  // 3) panjur çiftleri (2p-1, 2p) = (yukarı, aşağı)
  for (unsigned p = 0; p < n / 2u; p++) {
    const uint8_t t1 = sys.relays[2 * p].type, t2 = sys.relays[2 * p + 1].type;
    const bool pair = t1 == RELAY_TYPE_SHUTTER_UP && t2 == RELAY_TYPE_SHUTTER_DOWN;
    const bool any = t1 == RELAY_TYPE_SHUTTER_UP || t1 == RELAY_TYPE_SHUTTER_DOWN || t2 == RELAY_TYPE_SHUTTER_UP ||
                     t2 == RELAY_TYPE_SHUTTER_DOWN;
    if (any && !pair) return failIdx(e, "invalid_shutter_pair", "relays[%u].type", 2 * p);
  }
  // 4) çift süreleri eşit
  for (unsigned p = 0; p < n / 2u; p++) {
    if (sys.relays[2 * p].type != RELAY_TYPE_SHUTTER_UP) continue;
    if (sys.relays[2 * p].runtime_sec != sys.relays[2 * p + 1].runtime_sec) {
      return failIdx(e, "invalid_runtime", "relays[%u].runtime_s", 2 * p + 1);
    }
  }
  return true;
}

// ---- dis ----
bool parseDis(JsonVariant v, SystemConfig& sys, uint8_t n, TplError& e) {
  if (!v.is<JsonArray>() || v.as<JsonArray>().size() != n) return fail(e, "di_count", "dis");
  JsonArray a = v.as<JsonArray>();
  for (unsigned i = 0; i < n; i++) {
    JsonVariant it = a[i];
    int32_t ch = 0;
    if (!it.is<JsonObject>() || !intIn(it["ch"], 1, MAX_TOTAL_DIS, ch) || ch != (int32_t)(i + 1)) {
      return failIdx(e, "di_count", "dis[%u].ch", i);
    }
  }
  static const char* const K[] = {"ch", "name", "target_relay", "mode", "wiring"};
  for (unsigned i = 0; i < n; i++) {
    JsonObject d = a[i].as<JsonObject>();
    const char* bad = nullptr;
    if (!onlyKeys(d, K, 5, bad)) return failIdx2(e, "bad_field", "dis[%u].%s", i, bad);
    const char* name = strOf(d["name"]);
    if (!textOk(name, 1, 31)) return failIdx(e, "invalid_name", "dis[%u].name", i);
    if (!optText(d, "wiring", 48)) return failIdx(e, "invalid_wiring", "dis[%u].wiring", i);
    int32_t target = 0;
    if (!intIn(d["target_relay"], 0, n, target)) return failIdx(e, "invalid_target_relay", "dis[%u].target_relay", i);
    const uint8_t mode = diModeOf(strOf(d["mode"]));
    if (mode == 0xFF) return failIdx(e, "invalid_mode", "dis[%u].mode", i);
    const bool shutterMode = mode == DI_MODE_SHUTTER_STEP || mode == DI_MODE_SHUTTER_UP || mode == DI_MODE_SHUTTER_DOWN;
    // Panjur kipleri bir panjur çiftinin YUKARI rölesini hedefler (çiftler yukarıda doğrulandı: YUKARI => geçerli çift).
    if (shutterMode && (target < 1 || sys.relays[target - 1].type != RELAY_TYPE_SHUTTER_UP)) {
      return failIdx(e, "invalid_target_relay", "dis[%u].target_relay", i);
    }
    DIConfig& dc = sys.dis[i];
    memset(dc.name, 0, sizeof(dc.name));
    memcpy(dc.name, name, strlen(name));
    dc.target_relay = (uint8_t)target;
    dc.mode = mode;
  }
  return true;
}

// ---- safety ----
bool parseSafety(JsonVariant v, const SystemConfig& sys, uint8_t n, safety::SafetyConfig& c, TplError& e) {
  using namespace safety;
  if (!v.is<JsonObject>()) return fail(e, "bad_field", "safety");
  JsonObject s = v.as<JsonObject>();
  static const char* const K[] = {"policy", "intrusion", "zones", "sensors", "actuators", "lights"};
  const char* bad = nullptr;
  if (!onlyKeys(s, K, 6, bad)) {
    char p[TPL_PATH_LEN];
    snprintf(p, sizeof(p), "safety.%s", bad);
    return fail(e, "bad_field", p);
  }
  c.setDefaults();
  memset(c.zones, 0, sizeof(c.zones));   // bölgeler yalnız şablondan

  // policy
  if (!s["policy"].is<JsonObject>()) return fail(e, "bad_field", "safety.policy");
  {
    JsonObject p = s["policy"].as<JsonObject>();
    static const char* const PK[] = {"on", "dry_hold_ms"};
    if (!onlyKeys(p, PK, 2, bad) || !p["on"].is<bool>() || !p["dry_hold_ms"].is<int32_t>()) return fail(e, "bad_field", "safety.policy");
    const int32_t dh = p["dry_hold_ms"].as<int32_t>();
    if (dh < (int32_t)DRY_HOLD_MIN_MS || dh > (int32_t)DRY_HOLD_MAX_MS) return fail(e, "dry_hold", "safety.policy.dry_hold_ms");
    c.pol.policy_on = p["on"].as<bool>() ? 1 : 0;
    c.pol.dry_hold_ms = (uint32_t)dh;
  }
  // intrusion (isteğe bağlı)
  if (s.containsKey("intrusion")) {
    if (!s["intrusion"].is<JsonObject>()) return fail(e, "bad_field", "safety.intrusion");
    JsonObject in = s["intrusion"].as<JsonObject>();
    static const char* const IK[] = {"exit_s", "entry_s"};
    if (!onlyKeys(in, IK, 2, bad)) return fail(e, "bad_field", "safety.intrusion");
    int32_t x = 0;
    if (in.containsKey("exit_s")) {
      if (!intIn(in["exit_s"], 0, 255, x)) return fail(e, "bad_value", "safety.intrusion.exit_s");
      c.pol.exit_s = (uint8_t)x;
    }
    if (in.containsKey("entry_s")) {
      if (!intIn(in["entry_s"], 0, 255, x)) return fail(e, "bad_value", "safety.intrusion.entry_s");
      c.pol.entry_s = (uint8_t)x;
    }
  }
  // zones: 1..4 öğe, id benzersiz, bölge 1 her zaman var
  uint8_t zoneMask = 0;
  {
    if (!s["zones"].is<JsonArray>()) return fail(e, "bad_zone", "safety.zones");
    JsonArray za = s["zones"].as<JsonArray>();
    if (za.size() < 1 || za.size() > MAX_ZONES) return fail(e, "bad_zone", "safety.zones");
    static const char* const ZK[] = {"id", "name"};
    unsigned i = 0;
    for (JsonVariant zv : za) {
      if (!zv.is<JsonObject>()) return failIdx(e, "bad_field", "safety.zones[%u]", i);
      JsonObject z = zv.as<JsonObject>();
      if (!onlyKeys(z, ZK, 2, bad)) return failIdx2(e, "bad_field", "safety.zones[%u].%s", i, bad);
      int32_t id = 0;
      if (!intIn(z["id"], 1, MAX_ZONES, id) || (zoneMask & (1u << (id - 1)))) return failIdx(e, "bad_zone", "safety.zones[%u].id", i);
      const char* name = strOf(z["name"]);
      if (!textOk(name, 1, ZONE_NAME_LEN - 1)) return failIdx(e, "bad_name", "safety.zones[%u].name", i);
      zoneMask = (uint8_t)(zoneMask | (1u << (id - 1)));
      memcpy(c.zones[id - 1].name, name, strlen(name));
      i++;
    }
    if (!(zoneMask & 0x01)) return fail(e, "bad_zone", "safety.zones");
  }
  // sensors
  if (s.containsKey("sensors")) {
    if (!s["sensors"].is<JsonArray>()) return fail(e, "bad_field", "safety.sensors");
    JsonArray sa = s["sensors"].as<JsonArray>();
    if (sa.size() > MAX_SENSORS) return fail(e, "count", "safety.sensors");
    unsigned i = 0;
    for (JsonVariant sv : sa) {
      if (!sv.is<JsonObject>()) return failIdx(e, "bad_field", "safety.sensors[%u]", i);
      SensorConfig& sc = c.sens[c.nSens];
      const char* r = parseSensorItem(sv.as<JsonObject>(), sc);
      if (r) return failIdx(e, r, "safety.sensors[%u]", i);
      // Şablon kuralı: tehlike/hırsız sensörünün bölgesi tanımlı olmalı; kumanda rolü 0 ya da tanımlı bölge.
      const bool control = isControlRole(sc.kind);
      const bool zoneOk = (control && sc.zone == 0) || (sc.zone >= 1 && sc.zone <= MAX_ZONES && (zoneMask & (1u << (sc.zone - 1))));
      if (!zoneOk) return failIdx(e, "sensor_zone", "safety.sensors[%u].zone", i);
      c.nSens++;
      i++;
    }
  }
  // Sensör aşaması firmware doğrulaması (eylemcisiz): README sırası sensörler -> eylemciler.
  {
    const uint8_t nAct = c.nAct;
    c.nAct = 0;
    const CfgErr ve = validate(sys, c, true);   // şablon yazım yoludur (v1.3.2: köprü sensörü sensor_bridge_unsupported)
    c.nAct = nAct;
    if (ve != CfgErr::OK) return fail(e, cfgErrText(ve), "safety.sensors");
  }
  // actuators
  if (s.containsKey("actuators")) {
    if (!s["actuators"].is<JsonArray>()) return fail(e, "bad_field", "safety.actuators");
    JsonArray aa = s["actuators"].as<JsonArray>();
    if (aa.size() > MAX_ACTUATORS) return fail(e, "count", "safety.actuators");
    unsigned i = 0;
    for (JsonVariant av : aa) {
      if (!av.is<JsonObject>()) return failIdx(e, "bad_field", "safety.actuators[%u]", i);
      ActuatorConfig& ac = c.act[c.nAct];
      uint8_t idx = 0xFF;
      const char* r = parseActuatorItem(av.as<JsonObject>(), ac, idx, false);
      if (r) return failIdx(e, r, "safety.actuators[%u]", i);
      if (ac.zone_mask & ~zoneMask) return failIdx(e, "act_zone", "safety.actuators[%u].zones", i);
      c.nAct++;
      i++;
    }
  }
  {
    const CfgErr ve = validate(sys, c, true);
    if (ve != CfgErr::OK) return fail(e, cfgErrText(ve), "safety.actuators");
  }
  // lights: en çok N; röle 1..N, lamba tipi, benzersiz
  if (s.containsKey("lights")) {
    if (!s["lights"].is<JsonArray>()) return fail(e, "bad_field", "safety.lights");
    JsonArray la = s["lights"].as<JsonArray>();
    if (la.size() > n) return fail(e, "count", "safety.lights");
    uint64_t seen = 0;
    unsigned i = 0;
    for (JsonVariant lv : la) {
      if (!lv.is<JsonObject>()) return failIdx(e, "bad_field", "safety.lights[%u]", i);
      uint8_t relay = 0;
      LightOpt lo;
      memset(&lo, 0, sizeof(lo));
      const char* r = parseLightItem(lv.as<JsonObject>(), relay, lo);
      if (r) return failIdx(e, r, "safety.lights[%u]", i);
      const uint64_t b = 1ULL << (relay - 1);
      if (relay > n || sys.relays[relay - 1].type != RELAY_TYPE_LIGHT || (seen & b)) {
        return failIdx(e, "invalid_light", "safety.lights[%u].relay", i);
      }
      seen |= b;
      c.light[relay - 1] = lo;
      i++;
    }
  }
  return true;
}

}  // namespace

void sanitizePath(char* p) {
  if (!p) return;
  for (; *p; p++) {
    const char c = *p;
    const bool ok = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_' || c == '.' || c == '[' ||
                    c == ']';
    if (!ok) *p = '?';
  }
}

bool isLowerUuid(const char* s) {
  if (!s || strlen(s) != TPL_ID_LEN) return false;
  for (unsigned i = 0; i < TPL_ID_LEN; i++) {
    const bool dash = i == 8 || i == 13 || i == 18 || i == 23;
    if (dash ? s[i] != '-' : !isHex(s[i])) return false;
  }
  return true;
}

bool parseTemplate(JsonObject t, const SystemConfig& base, TplCandidate& out, TplError& e) {
  e.code = nullptr;
  e.path[0] = '\0';
  memset(&out, 0, sizeof(out));
  out.sys = base;
  if (t.isNull()) return fail(e, "bad_field", "template");
  const char* schema = strOf(t["schema"]);
  if (!schema || strcmp(schema, TPL_SCHEMA) != 0) return fail(e, "schema", "schema");
  static const char* const K[] = {"schema", "meta", "ext_module", "relays", "dis", "safety"};
  const char* bad = nullptr;
  if (!onlyKeys(t, K, 6, bad)) return fail(e, "bad_field", bad);
  for (const char* k : K) {
    if (!t.containsKey(k)) return fail(e, "bad_field", k);
  }
  if (!parseMeta(t["meta"], out, e)) return false;
  uint8_t n = 8;
  if (!parseExt(t["ext_module"], out.sys, n, e)) return false;
  if (!parseRelays(t["relays"], out.sys, n, e)) return false;
  if (!parseDis(t["dis"], out.sys, n, e)) return false;
  if (!parseSafety(t["safety"], out.sys, n, out.safety, e)) return false;
  // device_name = label (zarfta) ya da meta.name'in ilk 31 baytı; parseEnvelope label'ı ayrıca yazar.
  sysconfig_detail::copyStr(out.sys.device_name, out.label);
  out.sys.validate();   // aralık dışı alan kalmadı; yalnız NUL sonlandırma / kimlik alanlarının taban denetimi
  return true;
}

bool parseEnvelope(JsonObject root, const SystemConfig& base, TplCandidate& out, TplError& e) {
  e.code = nullptr;
  e.path[0] = '\0';
  if (root.isNull()) return fail(e, "bad_field", "");
  static const char* const K[] = {"template", "label"};
  const char* bad = nullptr;
  if (!onlyKeys(root, K, 2, bad)) return fail(e, "bad_field", bad);
  if (!root["template"].is<JsonObject>()) return fail(e, "bad_field", "template");
  if (!parseTemplate(root["template"].as<JsonObject>(), base, out, e)) return false;
  if (root.containsKey("label")) {
    const char* label = strOf(root["label"]);
    if (!textOk(label, 0, TPL_LABEL_MAX)) return fail(e, "invalid_label", "label");
    if (label[0] != '\0') {
      sysconfig_detail::copyStr(out.label, label);
      sysconfig_detail::copyStr(out.sys.device_name, label);
    }
  }
  return true;
}

}  // namespace tpl
