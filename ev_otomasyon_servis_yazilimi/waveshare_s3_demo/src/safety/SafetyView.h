#pragma once
// ============================================================================
// safety/SafetyView.h - Güvenlik katmanının durum görünümü ve state v:3 eki (spec §3.1-3.2, CONTRACTS §2.6). SAF MANTIK.
//
//  * SafetyView: SafetyManager'ın loopTask'ta ürettiği, görevler arası KOPYALANAN sabit yapı (adsız: sensör/eylemci/bölge adları
//    state'e yazılmaz [B12]; cfg_dump ve GET /api/safety/config ile gelir).
//  * writeStateExtras(): MqttManager::publishState ve WebPortal tam durumu (GET /api/status) için JSON eki. Ek, mevcut v:2
//    nesnesinin SONUNA eklenir (her anahtar virgülle başlar). Yapılandırılmamış panoda yalnız caps, boot, bn, time_ok, epoch yazılır
//    [B14]; cfg/sensors/actuators/safety anahtarları yalnız güvenlik katmanı etkinse (sensör/eylemci/kilit/güvenli kip) yazılır.
//  * viewSignature(): yayın tetiği (MqttManager StateSignature). Yalnız zamanla değişen alanlar (since_up) imzaya GİRMEZ.
//  * Faz 2 (F2.B.7): caps'e "intrusion"; safety.arm {mode, st, ok, until_up?, aid?, srcs?} yalnız hırsız sensörü varsa (ya da kip kuruluysa).
//    until_up sabit bir değerdir (gecikmenin bittiği uptime saniyesi): geri sayım imzayı değiştirmez.
// ============================================================================
#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include "safety/SafetyFsm.h"
#include "safety/IntrusionFsm.h"
#include "events/EventOutbox.h"

namespace safety {

struct SensorView {
  uint8_t code;      // sensorIdCode (d<n> / b<n>)
  uint8_t kind;      // SensorKind
  uint8_t zone;
  uint8_t active;    // onaylı (NC çevrilmiş) seviye; kontrol rollerinde ham basılı seviye
  uint8_t ok;
};

struct ActuatorView {
  uint8_t relay;
  uint8_t relay2;    // iki röleli vana: AÇ rölesi (0 = yok)
  uint8_t kind;      // ActKind
  uint8_t medium;
  uint8_t zoneMask;
  uint8_t pos;       // ValvePos (yalnız vana)
  uint8_t on;        // siren/fan/generic gerçek çıkış
  uint8_t fb;        // 0 = geri bildirim yok/görülmedi (null), 1 = açık, 2 = kapalı
  uint8_t fault;
};

struct ZoneView {
  uint8_t id;
  uint8_t st;        // ZoneSt
  uint8_t kinds;
  uint8_t silenced;
  uint8_t nsrcs;
  uint8_t srcs[8];
  char aid[EID_LEN];
  uint32_t sinceEpoch;
  uint32_t sinceUp;  // imzaya girmez
};

struct ArmView {
  uint8_t present;     // state.safety.arm yazılır
  uint8_t mode;        // ArmMode
  uint8_t st;          // ArmSt
  uint8_t ok;          // 0: güvenli kipte sensör tablosu yok (hırsız katmanı etkisiz)
  uint8_t nsrcs;
  uint8_t srcs[8];
  char aid[EID_LEN];
  uint32_t untilUp;    // yalnız exit/entry (sabit; imzaya girer)
};

struct SafetyView {
  uint8_t configured;  // güvenlik katmanı etkin: modül dizileri yazılır
  uint8_t policyOn;
  uint8_t mode;        // SafeReason
  uint8_t nSens;
  uint8_t nAct;
  uint8_t nZones;      // yalnız NORMAL olmayan bölgeler
  uint32_t rev;
  uint32_t crc;
  SensorView sens[MAX_SENSORS];
  ActuatorView act[MAX_ACTUATORS];
  ZoneView zones[MAX_ZONES];
  ArmView arm;         // zones'tan SONRA (imza: zones'un since_up'ı hariç tutulur)
};

// MqttTask/WebTask'ın eklediği, güvenlik görünümünden bağımsız alanlar.
struct StateMeta {
  uint32_t boot;       // ahbu_latch/bootc
  uint32_t bn;         // açılış nonce'u
  uint8_t timeOk;
  uint32_t epoch;
  char rejId[25];      // last_rej.id ("" = yazılmaz)
  uint8_t rej;         // Rej (OK = last_rej yok)
};

inline const char* sensorKindText(uint8_t kind) {
  switch (kind) {
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

inline const char* mediumText(uint8_t m) {
  if (m == (uint8_t)Medium::WATER) return "water";
  if (m == (uint8_t)Medium::GAS) return "gas";
  return "none";
}

// loopTask: çekirdeklerden görünüm. now_ms: since_up için. intr: hırsız çekirdeği (yoksa nullptr: arm yazılmaz).
inline void buildView(const SafetyConfig& cfg, const SensorHub& hub, const ActuatorCore& act, const SafetyCore& core, uint32_t now_ms,
                      SafetyView& v, const IntrusionCore* intr = nullptr) {
  memset(&v, 0, sizeof(v));
  v.configured = core.active() ? 1 : 0;
  v.policyOn = core.policyOn() ? 1 : 0;
  v.mode = (uint8_t)core.safeReason();
  v.rev = cfg.rev;
  v.crc = configCrc(cfg);
  v.nSens = hub.count();
  for (uint8_t i = 0; i < v.nSens; i++) {
    const SensorConfig& c = *hub.config(i);
    SensorView& s = v.sens[i];
    s.code = sensorIdCode(c);
    s.kind = c.kind;
    s.zone = c.zone;
    s.ok = hub.ok(i) ? 1 : 0;
    s.active = (isControlRole(c.kind) ? hub.rawActive(i) : hub.active(i)) ? 1 : 0;
  }
  v.nAct = act.count();
  for (uint8_t i = 0; i < v.nAct; i++) {
    const ActuatorConfig& c = *act.config(i);
    ActuatorView& a = v.act[i];
    a.relay = c.relay;
    a.relay2 = isPulseValve(c) ? c.relay2 : 0;
    a.kind = c.kind;
    a.medium = c.medium;
    a.zoneMask = c.zone_mask;
    if (isValve(c)) {
      a.pos = (uint8_t)act.pos(i);
      a.fb = (act.hasFb(i) && act.fbSeen(i)) ? (act.fbClosed(i) ? 2 : 1) : 0;
      a.fault = act.fbFault(i) ? 1 : 0;
    } else {
      a.on = act.output(i) ? 1 : 0;
    }
  }
  for (uint8_t z = 1; z <= MAX_ZONES; z++) {
    if (core.zoneState(z) == ZoneSt::NORMAL) continue;
    const ZoneRt& r = core.zone(z);
    ZoneView& o = v.zones[v.nZones++];
    o.id = z;
    o.st = (uint8_t)r.st;
    o.kinds = r.kinds;
    o.silenced = r.silenced ? 1 : 0;
    o.nsrcs = r.nsrcs > 8 ? 8 : r.nsrcs;
    memcpy(o.srcs, r.srcs, sizeof(o.srcs));
    memcpy(o.aid, r.aid, sizeof(o.aid));
    o.aid[EID_LEN - 1] = '\0';
    o.sinceEpoch = r.sinceEpoch;
    o.sinceUp = core.sinceUpS(z, now_ms);
  }
  if (intr && intr->present()) {
    ArmView& a = v.arm;
    a.present = 1;
    a.mode = (uint8_t)intr->mode();
    a.st = (uint8_t)intr->st();
    a.ok = intr->usable() ? 1 : 0;
    a.untilUp = intr->untilUp();
    if (intr->st() == ArmSt::ALARM) {
      a.nsrcs = intr->nsrcs() > 8 ? 8 : intr->nsrcs();
      memcpy(a.srcs, intr->srcs(), a.nsrcs);
      memcpy(a.aid, intr->aid(), EID_LEN);
      a.aid[EID_LEN - 1] = '\0';
    }
  }
}

// Yayın imzası (CRC32): since_up hariç bütün görünüm.
inline uint32_t viewSignature(const SafetyView& v) {
  uint32_t c = crc32Update(0, &v, offsetof(SafetyView, zones));
  for (uint8_t i = 0; i < v.nZones && i < MAX_ZONES; i++) c = crc32Update(c, &v.zones[i], offsetof(ZoneView, sinceUp));
  if (v.arm.present) c = crc32Update(c, &v.arm, sizeof(v.arm));
  return c;
}

// Röle satırındaki "act" alanı (spec §3.1 kural 6): eylemci rölesiyse türü, değilse nullptr.
inline const char* relayActText(const SafetyView& v, uint8_t relay1) {
  for (uint8_t i = 0; i < v.nAct && i < MAX_ACTUATORS; i++) {
    if (v.act[i].relay == relay1 || (v.act[i].relay2 != 0 && v.act[i].relay2 == relay1)) return actKindText(v.act[i].kind);
  }
  return nullptr;
}

namespace view_detail {
inline void boolKey(ev_detail::Writer& w, const char* key, bool b) {
  w.raw(",\"");
  w.raw(key);
  w.raw(b ? "\":true" : "\":false");
}
inline void zonesArray(ev_detail::Writer& w, uint8_t mask) {
  w.raw(",\"zones\":[");
  bool first = true;
  for (uint8_t z = 0; z < MAX_ZONES; z++) {
    if (!(mask & (1u << z))) continue;
    if (!first) w.raw(",");
    first = false;
    w.u32((uint32_t)z + 1);
  }
  w.raw("]");
}
}  // namespace view_detail

// State v:3 eki (her anahtar virgülle başlar). w.ok false ise çağıran eki KULLANMAMALIDIR (kesik JSON yok).
inline void writeStateExtras(const SafetyView& v, const StateMeta& m, ev_detail::Writer& w) {
  using namespace view_detail;
  w.raw(",\"caps\":[\"safety\",\"actuator\",\"event\",\"cfg\",\"intrusion\"]");
  w.num("boot", m.boot);
  w.raw(",\"bn\":\"");
  w.hex8(m.bn);
  w.raw("\"");
  boolKey(w, "time_ok", m.timeOk != 0);
  w.num("epoch", m.timeOk ? m.epoch : 0);
  if (m.rej != (uint8_t)Rej::OK) {
    w.raw(",\"last_rej\":{");
    if (m.rejId[0]) {
      w.raw("\"id\":\"");
      w.raw(m.rejId);
      w.raw("\",");
    }
    w.raw("\"code\":\"");
    w.raw(rejText((Rej)m.rej));
    w.raw("\"}");
  }
  if (!v.configured) return;
  w.raw(",\"cfg\":{\"safety\":{\"rev\":");
  w.u32(v.rev);
  w.raw(",\"crc\":\"");
  w.hex8(v.crc);
  w.raw("\"}}");

  w.raw(",\"sensors\":[");
  for (uint8_t i = 0; i < v.nSens && i < MAX_SENSORS; i++) {
    const SensorView& s = v.sens[i];
    char id[5];
    sensorIdText(s.code, id);
    w.raw(i ? ",{\"id\":\"" : "{\"id\":\"");
    w.raw(id);
    w.raw((s.code & 0x80) ? "\",\"src\":\"bridge\"" : "\",\"src\":\"di\"");
    w.str("kind", sensorKindText(s.kind));
    w.num("zone", s.zone);
    boolKey(w, "active", s.active != 0);
    boolKey(w, "ok", s.ok != 0);
    w.raw("}");
  }
  w.raw("]");

  w.raw(",\"actuators\":[");
  for (uint8_t i = 0; i < v.nAct && i < MAX_ACTUATORS; i++) {
    const ActuatorView& a = v.act[i];
    w.raw(i ? ",{\"id\":\"a" : "{\"id\":\"a");
    w.u32((uint32_t)i + 1);
    w.raw("\"");
    w.num("relay", a.relay);
    if (a.relay2) w.num("relay2", a.relay2);
    w.str("kind", actKindText(a.kind));
    if (a.kind == (uint8_t)ActKind::VALVE) {
      w.str("medium", mediumText(a.medium));
      zonesArray(w, a.zoneMask);
      w.str("pos", valvePosText((ValvePos)a.pos));
      w.raw(a.fb == 0 ? ",\"fb\":null" : (a.fb == 2 ? ",\"fb\":true" : ",\"fb\":false"));
    } else {
      zonesArray(w, a.zoneMask);
      boolKey(w, "on", a.on != 0);
    }
    boolKey(w, "fault", a.fault != 0);
    w.raw("}");
  }
  w.raw("]");

  w.raw(",\"safety\":{\"policy\":\"");
  w.raw(v.policyOn ? "on" : "off");
  w.raw("\",\"mode\":\"");
  if (v.mode != (uint8_t)SafeReason::NONE) {
    w.raw("safe\",\"reason\":\"");
    w.raw(safeReasonText((SafeReason)v.mode));
  } else {
    w.raw("normal");
  }
  w.raw("\",\"zones\":[");
  for (uint8_t i = 0; i < v.nZones && i < MAX_ZONES; i++) {
    const ZoneView& z = v.zones[i];
    w.raw(i ? ",{\"id\":" : "{\"id\":");
    w.u32(z.id);
    w.str("st", zoneStText((ZoneSt)z.st));
    const char* k = ev_detail::kindText(z.kinds);
    if (k) w.str("kind", k);
    if (z.aid[0]) w.str("aid", z.aid);
    if (z.sinceEpoch) w.num("since", z.sinceEpoch);
    w.num("since_up", z.sinceUp);
    boolKey(w, "silenced", z.silenced != 0);
    w.raw(",\"srcs\":[");
    for (uint8_t k2 = 0; k2 < z.nsrcs && k2 < 8; k2++) {
      char id[5];
      sensorIdText(z.srcs[k2], id);
      w.raw(k2 ? ",\"" : "\"");
      w.raw(id);
      w.raw("\"");
    }
    w.raw("]}");
  }
  w.raw("]");
  if (v.arm.present) {
    const ArmView& a = v.arm;
    w.raw(",\"arm\":{\"mode\":\"");
    w.raw(armModeText((ArmMode)a.mode));
    w.raw("\",\"st\":\"");
    w.raw(armStText((ArmSt)a.st));
    w.raw("\"");
    boolKey(w, "ok", a.ok != 0);
    if (a.st == (uint8_t)ArmSt::EXIT || a.st == (uint8_t)ArmSt::ENTRY) w.num("until_up", a.untilUp);
    if (a.st == (uint8_t)ArmSt::ALARM) {
      if (a.aid[0]) w.str("aid", a.aid);
      w.raw(",\"srcs\":[");
      for (uint8_t k = 0; k < a.nsrcs && k < 8; k++) {
        char id[5];
        sensorIdText(a.srcs[k], id);
        w.raw(k ? ",\"" : "\"");
        w.raw(id);
        w.raw("\"");
      }
      w.raw("]");
    }
    w.raw("}");
  }
  w.raw("}");
}

}  // namespace safety
