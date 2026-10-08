// safety/SafetyCfgApi.cpp - Güvenlik yapılandırması yamasının JSON ayrıştırıcısı (bkz. SafetyCfgApi.h).
#include "safety/SafetyCfgApi.h"
#include "Utf8Util.h"   // NetUtil::isCleanUtf8 (saf: PC testlerinde de derlenir)
#include <string.h>

namespace safety {

namespace {

bool parseNum(const char* s, uint32_t lo, uint32_t hi, uint32_t& out) {
  if (!s || !*s) return false;
  uint32_t v = 0;
  for (const char* p = s; *p; p++) {
    if (*p < '0' || *p > '9' || v > 1000) return false;
    v = v * 10 + (uint32_t)(*p - '0');
  }
  if (s[0] == '0' || v < lo || v > hi) return false;   // baştaki sıfır yok ("d03" geçersiz)
  out = v;
  return true;
}

// Tip doğrulamalı alan erişimi: yoksa MISSING, tip yanlışsa BAD.
enum Fs : uint8_t { FS_OK, FS_MISSING, FS_BAD };

Fs getInt(JsonObject o, const char* k, int32_t& v) {
  if (!o.containsKey(k)) return FS_MISSING;
  JsonVariant x = o[k];
  if (!x.is<int32_t>()) return FS_BAD;
  v = x.as<int32_t>();
  return FS_OK;
}
Fs getBool(JsonObject o, const char* k, bool& v) {
  if (!o.containsKey(k)) return FS_MISSING;
  JsonVariant x = o[k];
  if (!x.is<bool>()) return FS_BAD;
  v = x.as<bool>();
  return FS_OK;
}
Fs getStr(JsonObject o, const char* k, const char*& v) {
  if (!o.containsKey(k)) return FS_MISSING;
  JsonVariant x = o[k];
  if (!x.is<const char*>()) return FS_BAD;
  v = x.as<const char*>();
  return v ? FS_OK : FS_BAD;
}
// 0/1 tamsayı ya da boolean
Fs getFlag(JsonObject o, const char* k, uint8_t& v) {
  bool b = false;
  const Fs fb = getBool(o, k, b);
  if (fb == FS_OK) { v = b ? 1 : 0; return FS_OK; }
  if (fb == FS_MISSING) return FS_MISSING;
  int32_t n = 0;
  if (getInt(o, k, n) != FS_OK || (n != 0 && n != 1)) return FS_BAD;
  v = (uint8_t)n;
  return FS_OK;
}
bool onlyKeys(JsonObject o, const char* const* keys, size_t n) {
  for (JsonPair kv : o) {
    bool ok = false;
    for (size_t i = 0; i < n && !ok; i++) ok = strcmp(kv.key().c_str(), keys[i]) == 0;
    if (!ok) return false;
  }
  return true;
}
bool copyName(const char* s, char* dst, size_t cap) {
  const size_t len = strlen(s);
  if (len >= cap || !NetUtil::isCleanUtf8(s, len)) return false;
  memset(dst, 0, cap);
  memcpy(dst, s, len);
  return true;
}

uint8_t sensorKindOf(const char* s) {
  static const struct { const char* t; SensorKind k; } T[] = {
      {"water", SensorKind::WATER}, {"gas", SensorKind::GAS}, {"smoke", SensorKind::SMOKE}, {"door", SensorKind::DOOR},
      {"window", SensorKind::WINDOW}, {"motion", SensorKind::MOTION}, {"generic", SensorKind::GENERIC},
      {"alarm_ack", SensorKind::ALARM_ACK}, {"valve_close", SensorKind::VALVE_CLOSE}, {"gas_reset", SensorKind::GAS_RESET},
      {"arm_key", SensorKind::ARM_KEY}};
  for (const auto& x : T) if (strcmp(s, x.t) == 0) return (uint8_t)x.k;
  return 0;
}
uint8_t actKindOf(const char* s) {
  if (!strcmp(s, "valve")) return (uint8_t)ActKind::VALVE;
  if (!strcmp(s, "siren")) return (uint8_t)ActKind::SIREN;
  if (!strcmp(s, "fan")) return (uint8_t)ActKind::FAN;
  if (!strcmp(s, "generic")) return (uint8_t)ActKind::GENERIC;
  return 0;
}

const char* parseSensorInto(JsonObject o, SensorConfig& sens) {
  static const char* const K[] = {"id", "kind", "zone", "active_open", "flags", "confirm_ms", "name"};
  if (!onlyKeys(o, K, sizeof(K) / sizeof(K[0]))) return "bad_field";
  const char* id = nullptr;
  const char* kind = nullptr;
  int32_t zone = 0;
  if (getStr(o, "id", id) != FS_OK || !parseSensorId(id, sens.src, sens.index)) return "bad_id";
  if (getStr(o, "kind", kind) != FS_OK || (sens.kind = sensorKindOf(kind)) == 0) return "bad_kind";
  if (getInt(o, "zone", zone) != FS_OK || zone < 0 || zone > MAX_ZONES) return "bad_zone";
  sens.zone = (uint8_t)zone;
  if (getFlag(o, "active_open", sens.active_open) == FS_BAD) return "bad_value";
  int32_t v = 0;
  Fs f = getInt(o, "flags", v);
  if (f == FS_BAD || (f == FS_OK && (v < 0 || v > SF_ALL))) return "bad_value";
  sens.flags = (f == FS_OK) ? (uint8_t)v : defaultFlags(sens.kind);
  f = getInt(o, "confirm_ms", v);
  if (f == FS_BAD || (f == FS_OK && (v < 0 || v > 60000))) return "bad_value";
  sens.confirm_ms = (f == FS_OK) ? (uint16_t)v : defaultConfirmMs(sens.kind);
  const char* name = nullptr;
  f = getStr(o, "name", name);
  if (f == FS_BAD || (f == FS_OK && !copyName(name, sens.name, NAME_LEN))) return "bad_name";
  return nullptr;
}

const char* parseActuatorInto(JsonObject o, ActuatorConfig& a, uint8_t& actIndex, bool allowId) {
  static const char* const K[] = {"id", "relay", "relay2", "kind", "close_mode", "medium", "zones", "fb_di", "fb_closed_active",
                                  "fb_timeout_s", "run_limit_s", "exproof", "name"};
  if (!onlyKeys(o, K, sizeof(K) / sizeof(K[0]))) return "bad_field";
  if (!allowId && o.containsKey("id")) return "bad_field";   // sablon eylemcisi: sira = a1.. ("id" YOK)
  const char* s = nullptr;
  Fs f = getStr(o, "id", s);
  if (f == FS_BAD || (f == FS_OK && !parseActuatorId(s, actIndex))) return "bad_id";
  int32_t v = 0;
  if (getInt(o, "relay", v) != FS_OK || v < 1 || v > MAX_RELAYS) return "bad_relay";
  a.relay = (uint8_t)v;
  if (getStr(o, "kind", s) != FS_OK || (a.kind = actKindOf(s)) == 0) return "bad_kind";
  f = getStr(o, "close_mode", s);
  if (f == FS_BAD) return "bad_value";
  a.close_mode = (uint8_t)CloseMode::ENERGIZE_TO_CLOSE;
  if (f == FS_OK) {
    if (!strcmp(s, "energize")) a.close_mode = (uint8_t)CloseMode::ENERGIZE_TO_CLOSE;
    else if (!strcmp(s, "deenergize")) a.close_mode = (uint8_t)CloseMode::DEENERGIZE_TO_CLOSE;
    else if (!strcmp(s, "pulse")) a.close_mode = (uint8_t)CloseMode::PULSE_TWO_RELAY;
    else return "bad_value";
  }
  f = getStr(o, "medium", s);
  if (f == FS_BAD) return "bad_value";
  if (f == FS_OK) {
    if (!strcmp(s, "water")) a.medium = (uint8_t)Medium::WATER;
    else if (!strcmp(s, "gas")) a.medium = (uint8_t)Medium::GAS;
    else if (!strcmp(s, "none")) a.medium = (uint8_t)Medium::NONE;
    else return "bad_value";
  }
  if (o.containsKey("zones")) {
    if (!o["zones"].is<JsonArray>()) return "bad_zone";
    JsonArray z = o["zones"].as<JsonArray>();
    for (JsonVariant x : z) {
      if (!x.is<int32_t>()) return "bad_zone";
      const int32_t n = x.as<int32_t>();
      if (n < 1 || n > MAX_ZONES) return "bad_zone";
      a.zone_mask = (uint8_t)(a.zone_mask | (1u << (n - 1)));
    }
  }
  f = getInt(o, "relay2", v);
  if (f == FS_BAD || (f == FS_OK && (v < 0 || v > MAX_RELAYS))) return "bad_relay";
  a.relay2 = (f == FS_OK) ? (uint8_t)v : 0;
  f = getInt(o, "fb_di", v);
  if (f == FS_BAD || (f == FS_OK && (v < 0 || v > MAX_DI))) return "bad_value";
  a.fb_di = (f == FS_OK) ? (uint8_t)v : 0;
  a.fb_closed_active = 1;
  if (getFlag(o, "fb_closed_active", a.fb_closed_active) == FS_BAD) return "bad_value";
  f = getInt(o, "fb_timeout_s", v);
  if (f == FS_BAD || (f == FS_OK && (v < 0 || v > 65535))) return "bad_value";
  a.fb_timeout_s = (f == FS_OK) ? (uint16_t)v : (uint16_t)FB_TIMEOUT_DEFAULT_S;
  f = getInt(o, "run_limit_s", v);
  if (f == FS_BAD || (f == FS_OK && (v < 0 || v > 65535))) return "bad_value";
  if (f == FS_OK) a.run_limit_s = (uint16_t)v;
  else if (a.kind == (uint8_t)ActKind::SIREN) a.run_limit_s = SIREN_RUN_DEFAULT_S;
  else if (a.close_mode == (uint8_t)CloseMode::PULSE_TWO_RELAY && a.kind == (uint8_t)ActKind::VALVE) a.run_limit_s = PULSE_DEFAULT_S;
  bool ex = false;
  f = getBool(o, "exproof", ex);
  if (f == FS_BAD) return "bad_value";
  a.aflags = ex ? AF_FAN_EXPROOF : 0;
  const char* name = nullptr;
  f = getStr(o, "name", name);
  if (f == FS_BAD || (f == FS_OK && !copyName(name, a.name, NAME_LEN))) return "bad_name";
  return nullptr;
}

}  // namespace

// ---- Ortak öğe ayrıştırıcıları (yama + şablon; v1.3.0 İP-2.3) ----
const char* parseSensorItem(JsonObject o, SensorConfig& sens) {
  memset(&sens, 0, sizeof(sens));
  return parseSensorInto(o, sens);
}

const char* parseActuatorItem(JsonObject o, ActuatorConfig& act, uint8_t& actIndex, bool allowId) {
  memset(&act, 0, sizeof(act));
  actIndex = 0xFF;
  return parseActuatorInto(o, act, actIndex, allowId);
}

const char* parseLightItem(JsonObject o, uint8_t& relay, LightOpt& light) {
  static const char* const K[] = {"relay", "dimmable", "src", "addr", "ch"};
  if (!onlyKeys(o, K, 5)) return "bad_field";
  int32_t r = 0, src = 0, addr = 0, ch = 0;
  uint8_t dim = 0;
  if (getInt(o, "relay", r) != FS_OK || r < 1 || r > MAX_RELAYS) return "bad_relay";
  if (getFlag(o, "dimmable", dim) == FS_BAD) return "bad_value";
  if (getInt(o, "src", src) == FS_BAD || src < 0 || src > 2) return "bad_value";
  if (getInt(o, "addr", addr) == FS_BAD || addr < 0 || addr > 247) return "bad_value";
  if (getInt(o, "ch", ch) == FS_BAD || ch < 0 || ch > 255) return "bad_value";
  relay = (uint8_t)r;
  light.dimmable = dim;
  light.dimmer_src = (uint8_t)src;
  light.dimmer_addr = (uint8_t)addr;
  light.dimmer_ch = (uint8_t)ch;
  return nullptr;
}

bool parseSensorId(const char* s, uint8_t& src, uint8_t& index) {
  if (!s || (s[0] != 'd' && s[0] != 'b')) return false;
  uint32_t n = 0;
  const bool di = s[0] == 'd';
  if (!parseNum(s + 1, 1, di ? MAX_DI : MAX_BRIDGE, n)) return false;
  src = di ? (uint8_t)SensorSrc::DI : (uint8_t)SensorSrc::BRIDGE;
  index = (uint8_t)n;
  return true;
}

bool parseActuatorId(const char* s, uint8_t& idx0) {
  uint32_t n = 0;
  if (!s || s[0] != 'a' || !parseNum(s + 1, 1, MAX_ACTUATORS, n)) return false;
  idx0 = (uint8_t)(n - 1);
  return true;
}

const char* parseCfgEdit(JsonObject root, CfgEdit& e, bool& hasBase, uint32_t& baseRev, bool sysEnvelope) {
  editInit(e);
  hasBase = false;
  baseRev = 0;
  JsonObject set, del;
  for (JsonPair kv : root) {
    const char* k = kv.key().c_str();
    if (!strcmp(k, "base_rev")) {
      if (!kv.value().is<uint32_t>()) return "bad_base_rev";
      baseRev = kv.value().as<uint32_t>();
      hasBase = true;
    } else if (!strcmp(k, "set")) {
      if (!kv.value().is<JsonObject>()) return "bad_field";
      set = kv.value().as<JsonObject>();
    } else if (!strcmp(k, "del")) {
      if (!kv.value().is<JsonObject>()) return "bad_field";
      del = kv.value().as<JsonObject>();
    } else if (sysEnvelope && (!strcmp(k, "cmd") || !strcmp(k, "module") || !strcmp(k, "uid") || !strcmp(k, "id"))) {
      // sys zarfı: çağıran denetler
    } else {
      return "bad_field";
    }
  }
  if (set.isNull() == del.isNull()) return "bad_field";          // tam olarak biri
  JsonObject body = set.isNull() ? del : set;
  if (body.size() != 1) return "bad_field";                       // tek öğe
  JsonPair item = *body.begin();
  const char* what = item.key().c_str();
  if (!del.isNull()) {
    if (!item.value().is<const char*>()) return "bad_id";
    const char* id = item.value().as<const char*>();
    if (!strcmp(what, "sensor")) {
      if (!parseSensorId(id, e.sens.src, e.sens.index)) return "bad_id";
      e.op = EditOp::DEL_SENSOR;
      return nullptr;
    }
    if (!strcmp(what, "actuator")) {
      if (!parseActuatorId(id, e.actIndex)) return "bad_id";
      e.op = EditOp::DEL_ACTUATOR;
      return nullptr;
    }
    return "bad_field";
  }
  if (!item.value().is<JsonObject>()) return "bad_field";
  JsonObject o = item.value().as<JsonObject>();
  if (!strcmp(what, "sensor")) {
    const char* r = parseSensorInto(o, e.sens);
    if (!r) e.op = EditOp::SET_SENSOR;
    return r;
  }
  if (!strcmp(what, "actuator")) {
    const char* r = parseActuatorInto(o, e.act, e.actIndex, true);
    if (!r) e.op = EditOp::SET_ACTUATOR;
    return r;
  }
  if (!strcmp(what, "policy")) {
    static const char* const K[] = {"on", "dry_hold_ms"};
    if (!onlyKeys(o, K, 2)) return "bad_field";
    bool on = false;
    Fs f = getBool(o, "on", on);
    if (f == FS_BAD) return "bad_value";
    e.hasPolicyOn = f == FS_OK;
    e.policyOn = on ? 1 : 0;
    int32_t v = 0;
    f = getInt(o, "dry_hold_ms", v);
    if (f == FS_BAD || (f == FS_OK && v < 0)) return "bad_value";
    e.hasDryHold = f == FS_OK;
    e.dryHoldMs = (uint32_t)v;
    if (!e.hasPolicyOn && !e.hasDryHold) return "bad_field";
    e.op = EditOp::SET_POLICY;
    return nullptr;
  }
  if (!strcmp(what, "zone")) {
    static const char* const K[] = {"id", "name"};
    if (!onlyKeys(o, K, 2)) return "bad_field";
    int32_t id = 0;
    const char* name = nullptr;
    if (getInt(o, "id", id) != FS_OK || id < 1 || id > MAX_ZONES) return "bad_zone";
    if (getStr(o, "name", name) != FS_OK || !copyName(name, e.zoneName, ZONE_NAME_LEN)) return "bad_name";
    e.zoneId = (uint8_t)id;
    e.op = EditOp::SET_ZONE;
    return nullptr;
  }
  if (!strcmp(what, "intrusion")) {
    static const char* const K[] = {"exit_s", "entry_s"};
    if (!onlyKeys(o, K, 2)) return "bad_field";
    int32_t v = 0;
    Fs f = getInt(o, "exit_s", v);
    if (f == FS_BAD || (f == FS_OK && (v < 0 || v > 255))) return "bad_value";
    e.hasExit = f == FS_OK;
    e.exitS = (uint8_t)(f == FS_OK ? v : 0);
    f = getInt(o, "entry_s", v);
    if (f == FS_BAD || (f == FS_OK && (v < 0 || v > 255))) return "bad_value";
    e.hasEntry = f == FS_OK;
    e.entryS = (uint8_t)(f == FS_OK ? v : 0);
    if (!e.hasExit && !e.hasEntry) return "bad_field";
    e.op = EditOp::SET_INTRUSION;
    return nullptr;
  }
  if (!strcmp(what, "light")) {
    const char* r = parseLightItem(o, e.lightRelay, e.light);
    if (!r) e.op = EditOp::SET_LIGHT;
    return r;
  }
  return "bad_field";
}

}  // namespace safety
