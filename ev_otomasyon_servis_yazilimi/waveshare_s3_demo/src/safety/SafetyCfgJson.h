#pragma once
// ============================================================================
// safety/SafetyCfgJson.h - Güvenlik yapılandırmasının JSON biçimi: GET /api/safety/config (LAN) ve bulut "cfg_dump" (spec §4.2, §3.4). SAF.
//
//  * Adlar yalnız burada (yapılandırmada) bulunur; state'e yazılmaz [B12]. Adlar JSON kaçışıyla yazılır (", \ ve kontrol karakterleri).
//  * Öğe alanları yama (cfg_patch / POST /api/safety/config "set") alanlarıyla aynıdır: istemci okuduğu öğeyi değiştirip geri gönderebilir.
//  * Faz 2 (F2.B.7): "intrusion":{"exit_s","entry_s"} policy'den hemen sonra (cfg_dump'ta 1. parça); saklanan ham değer (0 = varsayılan).
//  * cfg_dump outbox DIŞINDADIR (onaysız, geçici arabellek): ev/{t}/event konusunda type:"cfg_dump" zarfıyla, her parça <= 3,5 KB
//    (DUMP_PART_CAP) olacak biçimde part/parts ile bölünür [Y6][B11]. Kaybolan parça sunucunun cfg_get'i yinelemesiyle telafi edilir.
// ============================================================================
#include <stdint.h>
#include <string.h>
#include "safety/SafetyConfig.h"
#include "events/EventOutbox.h"

namespace safety {

enum : uint16_t { DUMP_PART_CAP = 3500, DUMP_ENVELOPE_RESERVE = 260, CFG_ITEM_MAX = 400 };
enum : uint8_t { DUMP_MAX_PARTS = 12 };

struct DumpPart {
  uint8_t s0, s1;   // sensör aralığı [s0, s1)
  uint8_t a0, a1;   // eylemci aralığı [a0, a1)
  uint8_t head;     // politika + bölgeler + ışık seçenekleri bu parçada
};

namespace cfgjson_detail {
inline void escStr(ev_detail::Writer& w, const char* s, size_t cap) {
  static const char HEXDIG[] = "0123456789abcdef";
  w.raw("\"");
  for (size_t i = 0; i < cap && s[i]; i++) {
    const uint8_t c = (uint8_t)s[i];
    char t[7];
    if (c == '"' || c == '\\') {
      t[0] = '\\';
      t[1] = (char)c;
      t[2] = '\0';
    } else if (c < 0x20) {
      t[0] = '\\';
      t[1] = 'u';
      t[2] = '0';
      t[3] = '0';
      t[4] = HEXDIG[c >> 4];
      t[5] = HEXDIG[c & 0x0F];
      t[6] = '\0';
    } else {
      t[0] = (char)c;
      t[1] = '\0';
    }
    w.raw(t);
  }
  w.raw("\"");
}
inline const char* closeModeText(uint8_t m) {
  if (m == (uint8_t)CloseMode::DEENERGIZE_TO_CLOSE) return "deenergize";
  if (m == (uint8_t)CloseMode::PULSE_TWO_RELAY) return "pulse";
  return "energize";
}
inline const char* kindText(uint8_t k) {
  switch (k) {
    case (uint8_t)SensorKind::WATER: return "water";
    case (uint8_t)SensorKind::GAS: return "gas";
    case (uint8_t)SensorKind::SMOKE: return "smoke";
    case (uint8_t)SensorKind::DOOR: return "door";
    case (uint8_t)SensorKind::WINDOW: return "window";
    case (uint8_t)SensorKind::MOTION: return "motion";
    case (uint8_t)SensorKind::GENERIC: return "generic";
    case (uint8_t)SensorKind::ALARM_ACK: return "alarm_ack";
    case (uint8_t)SensorKind::VALVE_CLOSE: return "valve_close";
    case (uint8_t)SensorKind::GAS_RESET: return "gas_reset";
    case (uint8_t)SensorKind::ARM_KEY: return "arm_key";
    default: return "unknown";
  }
}
inline const char* mediumTxt(uint8_t m) {
  if (m == (uint8_t)Medium::WATER) return "water";
  if (m == (uint8_t)Medium::GAS) return "gas";
  return "none";
}
}  // namespace cfgjson_detail

inline void writeSensorCfg(ev_detail::Writer& w, const SensorConfig& s) {
  char id[5];
  sensorIdText(sensorIdCode(s), id);
  w.raw("{\"id\":\"");
  w.raw(id);
  w.raw("\"");
  w.str("kind", cfgjson_detail::kindText(s.kind));
  w.num("zone", s.zone);
  w.num("active_open", s.active_open ? 1 : 0);
  w.num("flags", s.flags);
  w.num("confirm_ms", s.confirm_ms);
  w.raw(",\"name\":");
  cfgjson_detail::escStr(w, s.name, NAME_LEN);
  w.raw("}");
}

inline void writeActuatorCfg(ev_detail::Writer& w, const ActuatorConfig& a, uint8_t idx) {
  w.raw("{\"id\":\"a");
  w.u32((uint32_t)idx + 1);
  w.raw("\"");
  w.num("relay", a.relay);
  if (isPulseValve(a)) w.num("relay2", a.relay2);
  w.str("kind", actKindText(a.kind));
  w.str("close_mode", cfgjson_detail::closeModeText(a.close_mode));
  w.str("medium", cfgjson_detail::mediumTxt(a.medium));
  w.raw(",\"zones\":[");
  bool first = true;
  for (uint8_t z = 0; z < MAX_ZONES; z++) {
    if (!(a.zone_mask & (1u << z))) continue;
    if (!first) w.raw(",");
    first = false;
    w.u32((uint32_t)z + 1);
  }
  w.raw("]");
  w.num("fb_di", a.fb_di);
  w.num("fb_closed_active", a.fb_closed_active ? 1 : 0);
  w.num("fb_timeout_s", a.fb_timeout_s);
  w.num("run_limit_s", a.run_limit_s);
  w.raw((a.aflags & AF_FAN_EXPROOF) ? ",\"exproof\":true" : ",\"exproof\":false");
  w.raw(",\"name\":");
  cfgjson_detail::escStr(w, a.name, NAME_LEN);
  w.raw("}");
}

// "policy", "intrusion", "zones" ve "lights" anahtarları (virgülle başlar).
inline void writeCfgHead(ev_detail::Writer& w, const SafetyConfig& c) {
  w.raw(",\"policy\":{\"on\":");
  w.raw(c.pol.policy_on ? "true" : "false");
  w.num("dry_hold_ms", c.pol.dry_hold_ms);
  w.raw("},\"intrusion\":{\"exit_s\":");
  w.u32(c.pol.exit_s);
  w.num("entry_s", c.pol.entry_s);
  w.raw("},\"zones\":[");
  for (uint8_t z = 0; z < MAX_ZONES; z++) {
    w.raw(z ? ",{\"id\":" : "{\"id\":");
    w.u32((uint32_t)z + 1);
    w.raw(",\"name\":");
    cfgjson_detail::escStr(w, c.zones[z].name, ZONE_NAME_LEN);
    w.raw("}");
  }
  w.raw("],\"lights\":[");
  bool first = true;
  for (uint8_t r = 0; r < MAX_RELAYS; r++) {
    const LightOpt& l = c.light[r];
    if (!l.dimmable && !l.dimmer_src && !l.dimmer_addr && !l.dimmer_ch) continue;
    w.raw(first ? "{\"relay\":" : ",{\"relay\":");
    first = false;
    w.u32((uint32_t)r + 1);
    w.num("dimmable", l.dimmable);
    w.num("src", l.dimmer_src);
    w.num("addr", l.dimmer_addr);
    w.num("ch", l.dimmer_ch);
    w.raw("}");
  }
  w.raw("]");
}

// GET /api/safety/config gövdesi (tek nesne).
inline void writeConfigJson(const SafetyConfig& c, ev_detail::Writer& w) {
  w.raw("{\"rev\":");
  w.u32(c.rev);
  w.raw(",\"crc\":\"");
  w.hex8(configCrc(c));
  w.raw("\"");
  writeCfgHead(w, c);
  w.raw(",\"sensors\":[");
  for (uint8_t i = 0; i < c.nSens && i < MAX_SENSORS; i++) {
    if (i) w.raw(",");
    writeSensorCfg(w, c.sens[i]);
  }
  w.raw("],\"actuators\":[");
  for (uint8_t i = 0; i < c.nAct && i < MAX_ACTUATORS; i++) {
    if (i) w.raw(",");
    writeActuatorCfg(w, c.act[i], i);
  }
  w.raw("]}");
}

// cfg_dump parça planı. scratch: ölçüm arabelleği (en az cap bayt; yığında 3,5 KB tutulmaz). Dönüş: parça sayısı (sığmazsa 0).
inline uint8_t planDump(const SafetyConfig& c, uint16_t cap, DumpPart* parts, uint8_t maxParts, char* scratch, size_t scratchCap) {
  char tmp[CFG_ITEM_MAX];
  size_t headLen = 0;
  {
    ev_detail::Writer w(scratch, scratchCap);
    writeCfgHead(w, c);
    if (!w.ok) return 0;
    headLen = w.len;
  }
  uint8_t n = 0;
  uint8_t s = 0, a = 0;
  while (n < maxParts) {
    DumpPart& p = parts[n];
    p.head = (n == 0) ? 1 : 0;
    p.s0 = p.s1 = s;
    p.a0 = p.a1 = a;
    size_t used = DUMP_ENVELOPE_RESERVE + (p.head ? headLen : 0);
    if (used > cap) return 0;
    bool progress = p.head != 0;
    while (s < c.nSens) {
      ev_detail::Writer w(tmp, sizeof(tmp));
      writeSensorCfg(w, c.sens[s]);
      if (!w.ok) return 0;
      if (used + w.len + 1 > cap) break;
      used += w.len + 1;
      s++;
      p.s1 = s;
      progress = true;
    }
    if (s >= c.nSens) {
      while (a < c.nAct) {
        ev_detail::Writer w(tmp, sizeof(tmp));
        writeActuatorCfg(w, c.act[a], a);
        if (!w.ok) return 0;
        if (used + w.len + 1 > cap) break;
        used += w.len + 1;
        a++;
        p.a1 = a;
        progress = true;
      }
    }
    n++;
    if (s >= c.nSens && a >= c.nAct) return n;
    if (!progress) return 0;
  }
  return 0;
}

inline size_t writeDumpPart(const SafetyConfig& c, const DumpPart& p, uint8_t part, uint8_t parts, const char* uid, char* buf, size_t cap) {
  ev_detail::Writer w(buf, cap);
  w.raw("{\"v\":1");
  w.str("uid", uid ? uid : "");
  w.raw(",\"type\":\"cfg_dump\",\"module\":\"safety\"");
  w.num("rev", c.rev);
  w.raw(",\"crc\":\"");
  w.hex8(configCrc(c));
  w.raw("\"");
  w.num("part", part);
  w.num("parts", parts);
  if (p.head) writeCfgHead(w, c);
  w.raw(",\"sensors\":[");
  for (uint8_t i = p.s0; i < p.s1 && i < MAX_SENSORS; i++) {
    if (i != p.s0) w.raw(",");
    writeSensorCfg(w, c.sens[i]);
  }
  w.raw("],\"actuators\":[");
  for (uint8_t i = p.a0; i < p.a1 && i < MAX_ACTUATORS; i++) {
    if (i != p.a0) w.raw(",");
    writeActuatorCfg(w, c.act[i], i);
  }
  w.raw("]}");
  return w.ok ? w.len : 0;
}

}  // namespace safety
