#pragma once
// ============================================================================
// events/EventOutbox.h - "ev/{t}/event" olay tamponu: sabit yapılı yuvalar, eid üretimi, yeniden deneme planı, ack ile silme,
// taşma önceliği ve JSON üretimi. SAF MANTIK (mutex YOK; görevler arası sarmalayıcı events/EventOutboxRtos.h) [B16].
//
// Tasarım §3.4:
//  * eid = "<bn>-<n>": bn her açılışta esp_random() ile üretilen 32 bit nonce (8 hex), n açılış başına 1'den artan sayaç
//    (en çok 5 hane; 99999'dan sonra 1). Fabrika sıfırlaması / flash silme / pano değişimi sonrası da eid'ler çakışmaz [Y4][B4].
//  * PubSubClient yalnız QoS 0 yayınlar: teslim UYGULAMA DÜZEYİNDE onayla sağlanır. Onay gelmezse 5, 10, 20, 40 sn sonra,
//    ardından 60 sn'de bir yeniden denenir. Abonelikten sonraki ilk 1500 ms'de gelen komutlar yok sayıldığı için outbox bu
//    pencere bitmeden boşaltılmaz [D4].
//  * Taşma (16 olay): önce en eski actuator_changed, sonra en eski *_cleared, sonra alarm dışı en eski olay atılır;
//    alarm_raised ve valve_fault atılmaz, yalnız hepsi alarmsa en eski alarmın üstüne yazılır. Kilitli durum state'te durduğu
//    için hiçbiri bilgi kaybı değildir.
//  * Yeniden başlatmada tampon kaybolur (RAM); kilitli bölge NVS'ten geri gelir ve state üzerinden uzlaştırılır.
//  * LAN olay halkası (GET /api/events?after=<eid>, §3.5 [B16]): her push'un kopyası ayrı bir 32'lik halkada da tutulur (onaylanmış olanlar
//    dahil; ack/taşma outbox'ı etkiler, halkayı etkilemez). İnternetsiz uygulama alarm geçmişini buradan okur (K5).
//  * Faz 2 (F2.B.7): intrusion_alarm alarm sınıfıdır (atılmaz), intrusion_cleared *_cleared sınıfı, arm_changed en düşük öncelik
//    (actuator_changed ile aynı). Kapı/pencere kenarları olay kutusuna YAZILMAZ (F2-5).
// ============================================================================
#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include "sensors/SensorTypes.h"

namespace safety {

enum : uint8_t { EID_LEN = 15 };            // "ffffffff-99999" + NUL
enum : uint16_t { EVENT_JSON_MAX = 768 };
enum : uint32_t { EID_N_MAX = 99999UL };

enum class EvType : uint8_t {
  NONE = 0,
  ALARM_RAISED = 1, VALVE_FAULT = 2, VALVE_FAULT_CLEARED = 3, ALARM_SILENCED = 4, ALARM_CLEARED = 5, TEST_RESULT = 6,
  SENSOR_FAULT = 7, SENSOR_FAULT_CLEARED = 8, ACTUATOR_FAULT = 9, SAFE_MODE = 10, NVS_FAIL = 11, POLICY_CHANGED = 12,
  ACTUATOR_CHANGED = 13, CFG_CONFLICT = 14,
  INTRUSION_ALARM = 15, INTRUSION_CLEARED = 16, ARM_CHANGED = 17
};

inline const char* evTypeText(uint8_t t) {
  switch ((EvType)t) {
    case EvType::ALARM_RAISED: return "alarm_raised";
    case EvType::VALVE_FAULT: return "valve_fault";
    case EvType::VALVE_FAULT_CLEARED: return "valve_fault_cleared";
    case EvType::ALARM_SILENCED: return "alarm_silenced";
    case EvType::ALARM_CLEARED: return "alarm_cleared";
    case EvType::TEST_RESULT: return "test_result";
    case EvType::SENSOR_FAULT: return "sensor_fault";
    case EvType::SENSOR_FAULT_CLEARED: return "sensor_fault_cleared";
    case EvType::ACTUATOR_FAULT: return "actuator_fault";
    case EvType::SAFE_MODE: return "safe_mode";
    case EvType::NVS_FAIL: return "nvs_fail";
    case EvType::POLICY_CHANGED: return "policy_changed";
    case EvType::ACTUATOR_CHANGED: return "actuator_changed";
    case EvType::CFG_CONFLICT: return "cfg_conflict";
    case EvType::INTRUSION_ALARM: return "intrusion_alarm";
    case EvType::INTRUSION_CLEARED: return "intrusion_cleared";
    case EvType::ARM_CHANGED: return "arm_changed";
    default: return "";
  }
}

// policy_changed / intrusion_cleared / arm_changed "via" (Event.sub). VIA_DI (ARM_KEY girişi) ve VIA_BOOT (açılışta geri yüklenen kip)
// yalnız hırsız olaylarındadır.
enum : uint8_t { VIA_CLI = 0, VIA_LAN = 1, VIA_CLOUD = 2, VIA_LOCAL_WEB = 3, VIA_DI = 4, VIA_BOOT = 5 };
// nvs_fail "key" (Event.sub)
enum : uint8_t { NVSK_LATCH = 1, NVSK_ACT_POS = 2, NVSK_CFG = 3, NVSK_SIREN = 4, NVSK_CRASH = 5, NVSK_ARM = 6 };

struct Event {              // sabit yapılı yuva [Y6]
  uint8_t type;             // EvType
  uint8_t zone;             // 1..4 (0 = bölgesiz)
  uint8_t kinds;            // HZ_* (alarm türü)
  uint8_t nsrcs;
  uint8_t srcs[8];          // sensorIdCode
  uint16_t actClose;        // eylemci bitleri (bit i = a<i+1>): "close"
  uint16_t actOpen;         // "open"
  uint16_t actOn;           // "on"
  uint16_t actOff;          // "off"
  uint32_t atUp;            // olay anı, açılıştan beri sn
  uint32_t atEpoch;         // time_ok ise epoch sn, değilse 0 ("at" yazılmaz)
  uint16_t val;             // test_result fb_ms
  uint8_t flag;             // test_result ok / policy_changed açık mı / arm_changed kip (ArmMode: 0 off, 1 away, 2 home)
  uint8_t sub;              // safe_mode nedeni / policy via / nvs_fail anahtarı / test_result: 1 = geri bildirim ölçüldü
  uint32_t rev;             // cfg_conflict
  uint32_t crc;
  char aid[EID_LEN];        // alarm kimliği (alarmı açan olayın eid'si): valve_fault, valve_fault_cleared, alarm_silenced,
                            // alarm_cleared ("" = yazılmaz; alarm_raised'da aid olayın kendi eid'sidir) [CONTRACTS §2.6]
};

namespace ev_detail {
// Sınırlı JSON yazıcı: taşmada ok=false olur ve hiçbir şey sınır dışına yazılmaz.
struct Writer {
  char* buf;
  size_t cap;
  size_t len;
  bool ok;
  Writer(char* b, size_t c) : buf(b), cap(c), len(0), ok(c > 0) { if (c) b[0] = '\0'; }
  void raw(const char* s) {
    size_t n = strlen(s);
    if (!ok || len + n + 1 > cap) { ok = false; return; }
    memcpy(buf + len, s, n);
    len += n;
    buf[len] = '\0';
  }
  void u32(uint32_t v) {
    char t[11];
    int i = 10;
    t[i] = '\0';
    do { t[--i] = (char)('0' + v % 10); v /= 10; } while (v);
    raw(t + i);
  }
  void hex8(uint32_t v) {
    char t[9];
    for (int i = 7; i >= 0; i--) { uint8_t d = (uint8_t)(v & 0xF); t[i] = (char)(d < 10 ? '0' + d : 'a' + d - 10); v >>= 4; }
    t[8] = '\0';
    raw(t);
  }
  void str(const char* key, const char* val) { raw(",\""); raw(key); raw("\":\""); raw(val); raw("\""); }
  void num(const char* key, uint32_t v) { raw(",\""); raw(key); raw("\":"); u32(v); }
};

inline const char* kindText(uint8_t kinds) {
  if (kinds & HZ_GAS) return "gas";
  if (kinds & HZ_SMOKE) return "smoke";
  if (kinds & HZ_WATER) return "water";
  return nullptr;
}
inline const char* reasonText(uint8_t r) {
  switch (r) { case 1: return "cfg_corrupt"; case 2: return "latch_orphan"; case 3: return "crash_loop"; default: return ""; }
}
inline const char* viaText(uint8_t v) {
  switch (v) {
    case VIA_LAN: return "lan"; case VIA_CLOUD: return "cloud"; case VIA_LOCAL_WEB: return "local_web";
    case VIA_DI: return "di"; case VIA_BOOT: return "boot"; default: return "cli";
  }
}
inline const char* armModeTextOf(uint8_t m) { return m == 1 ? "away" : (m == 2 ? "home" : "off"); }
inline const char* nvsKeyText(uint8_t k) {
  switch (k) {
    case NVSK_LATCH: return "latch"; case NVSK_ACT_POS: return "act_pos"; case NVSK_CFG: return "cfg";
    case NVSK_SIREN: return "siren_s"; case NVSK_CRASH: return "crash"; case NVSK_ARM: return "arm"; default: return "";
  }
}
inline bool isAlarmClass(uint8_t t) {
  return t == (uint8_t)EvType::ALARM_RAISED || t == (uint8_t)EvType::VALVE_FAULT || t == (uint8_t)EvType::INTRUSION_ALARM;
}
inline bool isCleared(uint8_t t) {
  return t == (uint8_t)EvType::ALARM_CLEARED || t == (uint8_t)EvType::VALVE_FAULT_CLEARED || t == (uint8_t)EvType::SENSOR_FAULT_CLEARED ||
         t == (uint8_t)EvType::INTRUSION_CLEARED;
}
inline bool isLowest(uint8_t t) { return t == (uint8_t)EvType::ACTUATOR_CHANGED || t == (uint8_t)EvType::ARM_CHANGED; }
}  // namespace ev_detail

inline void formatEid(uint32_t bn, uint32_t n, char* out) {
  ev_detail::Writer w(out, EID_LEN);
  w.hex8(bn);
  w.raw("-");
  w.u32(n);
}

class EventOutbox {
public:
  enum : uint8_t { CAP = 16, LOG_CAP = 32 };
  enum : uint32_t { RECONNECT_WINDOW_MS = 1500 };

  EventOutbox() : bn_(0), nextN_(1), ord_(0), overwrites_(0), logHead_(0), logCount_(0) {
    memset(slot_, 0, sizeof(slot_));
    memset(log_, 0, sizeof(log_));
  }

  // Açılışta: yeni nonce, sayaç 1, tampon boş.
  void begin(uint32_t bootNonce) {
    bn_ = bootNonce;
    nextN_ = 1;
    ord_ = 0;
    overwrites_ = 0;
    memset(slot_, 0, sizeof(slot_));
    memset(log_, 0, sizeof(log_));
    logHead_ = 0;
    logCount_ = 0;
  }
  uint32_t bootNonce() const { return bn_; }
  void setNextN(uint32_t n) { nextN_ = (n == 0 || n > EID_N_MAX) ? 1 : n; }

  // Olayı tampona koyar; eid'i eidOut'a (EID_LEN) yazar. Her zaman yer bulunur (taşma önceliği).
  bool push(const Event& e, char* eidOut) {
    int s = freeSlot();
    if (s < 0) s = victim();
    Slot& sl = slot_[s];
    sl.used = true;
    sl.ev = e;
    sl.n = nextN_;
    sl.ord = ++ord_;
    sl.sends = 0;
    sl.lastSent = 0;
    log_[logHead_].ev = e;
    log_[logHead_].n = sl.n;
    logHead_ = (uint8_t)((logHead_ + 1) % LOG_CAP);
    if (logCount_ < LOG_CAP) logCount_++;
    nextN_ = (nextN_ >= EID_N_MAX) ? 1 : nextN_ + 1;
    if (eidOut) formatEid(bn_, sl.n, eidOut);
    return true;
  }

  // ---- LAN olay halkası (i = 0 en eski) ----
  uint8_t logCount() const { return logCount_; }
  // after eid'inden SONRAKİ ilk kaydın sırası; eid yoksa/bulunamazsa (başka açılış, halkadan düşmüş) 0 (baştan).
  uint8_t logAfter(const char* afterEid) const {
    if (!afterEid || !afterEid[0]) return 0;
    char tmp[EID_LEN];
    for (uint8_t i = 0; i < logCount_; i++) {
      formatEid(bn_, logEntry(i).n, tmp);
      if (strcmp(tmp, afterEid) == 0) return (uint8_t)(i + 1);
    }
    return 0;
  }
  size_t logJson(uint8_t i, const char* uid, uint32_t bootCount, char* buf, size_t cap) const {
    if (i >= logCount_) {
      if (buf && cap) buf[0] = '\0';
      return 0;
    }
    return eventJson(logEntry(i).ev, logEntry(i).n, uid, bootCount, buf, cap);
  }

  // Yayın zamanı gelmiş en eski olay; yoksa -1. connectedAt: aboneliğin tamamlandığı an (bağlı değilse çağırmayın).
  int nextDue(uint32_t now_ms, uint32_t connectedAt) const {
    if ((uint32_t)(now_ms - connectedAt) < RECONNECT_WINDOW_MS) return -1;
    int best = -1;
    for (int i = 0; i < CAP; i++) {
      const Slot& s = slot_[i];
      if (!s.used) continue;
      if (s.sends > 0 && (uint32_t)(now_ms - s.lastSent) < backoffMs(s.sends)) continue;
      if (best < 0 || (int32_t)(s.ord - slot_[best].ord) < 0) best = i;
    }
    return best;
  }

  void markSent(int slot, uint32_t now_ms) {
    if (slot < 0 || slot >= CAP || !slot_[slot].used) return;
    if (slot_[slot].sends < 255) slot_[slot].sends++;
    slot_[slot].lastSent = now_ms;
  }

  // event_ack: eşleşen eid'i siler. Başka nonce'un (başka pano/açılış) eid'i eşleşmez.
  bool ack(const char* eid) {
    if (!eid) return false;
    char tmp[EID_LEN];
    for (int i = 0; i < CAP; i++) {
      if (!slot_[i].used) continue;
      formatEid(bn_, slot_[i].n, tmp);
      if (strcmp(tmp, eid) == 0) {
        slot_[i].used = false;
        return true;
      }
    }
    return false;
  }
  uint8_t ackMany(const char* const* eids, uint8_t n) {
    uint8_t k = 0;
    for (uint8_t i = 0; i < n; i++) if (ack(eids[i])) k++;
    return k;
  }

  uint8_t count() const {
    uint8_t k = 0;
    for (int i = 0; i < CAP; i++) if (slot_[i].used) k++;
    return k;
  }
  uint8_t countOf(EvType t) const {
    uint8_t k = 0;
    for (int i = 0; i < CAP; i++) if (slot_[i].used && slot_[i].ev.type == (uint8_t)t) k++;
    return k;
  }
  uint32_t overwrites() const { return overwrites_; }
  const Event* at(int slot) const { return (slot >= 0 && slot < CAP && slot_[slot].used) ? &slot_[slot].ev : nullptr; }
  void eidOf(int slot, char* out) const {
    if (slot < 0 || slot >= CAP || !slot_[slot].used) { out[0] = '\0'; return; }
    formatEid(bn_, slot_[slot].n, out);
  }

  // Yayın JSON'u (§3.4). Dönüş: uzunluk; sığmazsa ya da yuva boşsa 0.
  size_t toJson(int slot, const char* uid, uint32_t bootCount, char* buf, size_t cap) const {
    if (slot < 0 || slot >= CAP || !slot_[slot].used || !buf || cap == 0) return 0;
    return eventJson(slot_[slot].ev, slot_[slot].n, uid, bootCount, buf, cap);
  }

private:
  size_t eventJson(const Event& e, uint32_t n, const char* uid, uint32_t bootCount, char* buf, size_t cap) const {
    using namespace ev_detail;
    if (!buf || cap == 0) return 0;
    Writer w(buf, cap);
    char eid[EID_LEN];
    formatEid(bn_, n, eid);
    w.raw("{\"v\":1");
    w.str("uid", uid ? uid : "");
    w.str("eid", eid);
    w.raw(",\"bn\":\"");
    w.hex8(bn_);
    w.raw("\"");
    w.num("boot", bootCount);
    w.num("n", n);
    w.str("type", evTypeText(e.type));
    if (e.zone) w.num("zone", e.zone);
    const char* k = (e.type == (uint8_t)EvType::INTRUSION_ALARM) ? "intrusion" : kindText(e.kinds);
    if (k) w.str("kind", k);
    if (e.aid[0]) {
      char aid[EID_LEN];
      memcpy(aid, e.aid, EID_LEN);
      aid[EID_LEN - 1] = '\0';
      w.str("aid", aid);
    }
    if (e.nsrcs) {
      w.raw(",\"srcs\":[");
      for (uint8_t i = 0; i < e.nsrcs && i < 8; i++) {
        char id[5];
        sensorIdText(e.srcs[i], id);
        if (i) w.raw(",");
        w.raw("\"");
        w.raw(id);
        w.raw("\"");
      }
      w.raw("]");
    }
    switch ((EvType)e.type) {
      case EvType::TEST_RESULT:
        w.raw(e.flag ? ",\"ok\":true" : ",\"ok\":false");
        if (e.sub) w.num("fb_ms", e.val);   // yalnız geri bildirimle ölçüldüyse (yoksa "gözle doğrulayın")
        break;
      case EvType::SAFE_MODE: w.str("reason", reasonText(e.sub)); break;
      case EvType::CFG_CONFLICT:
        w.num("rev", e.rev);
        w.raw(",\"crc\":\"");
        w.hex8(e.crc);
        w.raw("\"");
        break;
      case EvType::POLICY_CHANGED:
        w.str("policy", e.flag ? "on" : "off");
        w.str("via", viaText(e.sub));
        break;
      case EvType::NVS_FAIL: w.str("key", nvsKeyText(e.sub)); break;
      case EvType::INTRUSION_CLEARED: w.str("via", viaText(e.sub)); break;
      case EvType::ARM_CHANGED:
        w.str("mode", armModeTextOf(e.flag));
        w.str("via", viaText(e.sub));
        break;
      default: break;
    }
    if (e.atEpoch) w.num("at", e.atEpoch);
    w.num("at_up", e.atUp);
    const uint16_t any = (uint16_t)(e.actClose | e.actOpen | e.actOn | e.actOff);
    if (any) {
      w.raw(",\"actions\":[");
      bool first = true;
      static const char* const DO[4] = {"close", "open", "on", "off"};
      for (uint8_t i = 0; i < MAX_ACTUATORS; i++) {
        const uint16_t b = (uint16_t)(1u << i);
        const uint16_t m[4] = {e.actClose, e.actOpen, e.actOn, e.actOff};
        for (uint8_t d = 0; d < 4; d++) {
          if (!(m[d] & b)) continue;
          w.raw(first ? "{\"a\":\"a" : ",{\"a\":\"a");
          first = false;
          w.u32((uint32_t)i + 1);
          w.raw("\",\"do\":\"");
          w.raw(DO[d]);
          w.raw("\"}");
        }
      }
      w.raw("]");
    }
    w.raw("}");
    return w.ok ? w.len : 0;
  }

  struct Slot {
    Event ev;
    uint32_t n;
    uint32_t ord;           // ekleme sırası ("en eski" kararı)
    uint32_t lastSent;
    uint8_t sends;
    bool used;
  };

  static uint32_t backoffMs(uint8_t sends) {
    switch (sends) { case 1: return 5000; case 2: return 10000; case 3: return 20000; case 4: return 40000; default: return 60000; }
  }
  int freeSlot() const {
    for (int i = 0; i < CAP; i++) if (!slot_[i].used) return i;
    return -1;
  }
  int oldestWhere(int cls) const {   // 0: actuator_changed/arm_changed, 1: *_cleared, 2: alarm dışı, 3: hepsi
    int best = -1;
    for (int i = 0; i < CAP; i++) {
      const uint8_t t = slot_[i].ev.type;
      bool match;
      if (cls == 0) match = ev_detail::isLowest(t);
      else if (cls == 1) match = ev_detail::isCleared(t);
      else if (cls == 2) match = !ev_detail::isAlarmClass(t);
      else match = true;
      if (!match) continue;
      if (best < 0 || (int32_t)(slot_[i].ord - slot_[best].ord) < 0) best = i;
    }
    return best;
  }
  int victim() {
    for (int cls = 0; cls < 3; cls++) {
      int v = oldestWhere(cls);
      if (v >= 0) return v;
    }
    overwrites_++;
    return oldestWhere(3);
  }

  uint32_t bn_;
  uint32_t nextN_;
  uint32_t ord_;
  uint32_t overwrites_;
  Slot slot_[CAP];
  struct LogEntry {
    Event ev;
    uint32_t n;
  };
  const LogEntry& logEntry(uint8_t i) const { return log_[(uint8_t)((logHead_ + LOG_CAP - logCount_ + i) % LOG_CAP)]; }
  LogEntry log_[LOG_CAP];
  uint8_t logHead_;
  uint8_t logCount_;
};

}  // namespace safety
