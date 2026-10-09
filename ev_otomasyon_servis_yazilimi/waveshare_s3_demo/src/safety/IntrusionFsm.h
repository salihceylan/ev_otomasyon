#pragma once
// ============================================================================
// safety/IntrusionFsm.h - Hırsız alarmı çekirdeği (IntrusionCore): kip (off/home/away), durum (idle/exit/entry/alarm), çıkış/giriş
// gecikmeleri, hazırlık denetimi, swinger sınırı, ARM_KEY anahtarlı kontak, kip/alarm belleği kaydı. SAF MANTIK; saat parametre.
//
// Tasarım: docs/superpowers/specs/2026-10-06-guvenlik-iklim-senaryo-mimarisi-design.md "Faz 2 tasarımı" F2.B (plan 2.5), kararlar F2-2..F2-5.
//  * Tehlike katmanından (SafetyCore: su/gaz/duman) AYRIDIR: vana sürmez, bölge kilidi üretmez, politika (policy:off) onu kapatmaz. Ortak
//    tek kaynak siren ve buzzer'dır: sirenReq()/takeSirenKick() SafetyCore::setIntrusionSiren'e verilir (VEYA, ayrı bütçe); hırsız alarmı ev
//    genelidir (bütün sirenler, F2-2).
//  * Sensör sınıfı (SensorConfig.flags): SF_REACT'li door/window/motion alarm sistemine dahildir; SF_ENTRY giriş yolu (gecikmeli), SF_AWAY_ONLY
//    yalnız "away" kipinde etkin; diğerleri anlık. ok=false sensör ALARM ÜRETMEZ ama kurmayı engeller ("hazır değil").
//  * Kurma hazırlığı: kurulacak kipte etkin, giriş yolu OLMAYAN her sensör ok && !aktif; giriş yolu sensörü açıkken kurulabilir (çıkış).
//    Çıkış süresinde giriş yolu yok sayılır; süre dolduğunda giriş yolu hâlâ açıksa "çıkış hatası": giriş gecikmesi başlar.
//  * Seviye tabanlı (kaçırılmış kenar yok); alarm durumunda yeni tetik YÜKSELEN kenarla sayılır: srcs'e eklenir, sensörün kurulum dönemindeki
//    tetik sayısı < 3 ise (EN 50131-1 swinger yaklaşımı) durmuş siren yeniden çalar.
//  * Kalıcılık (ArmRecord, NVS "ahbu_latch/arm", 20 B): yalnız kip değişiminde, giriş gecikmesi başlangıcında ve alarm geçişinde yazılır
//    (takeDirty); fabrika sıfırlaması silmez (F2-4). Açılışta kip geri yüklenir, durum idle (çıkış gecikmesi YOK); alarm belleği varsa aynı
//    aid ile "alarm" ve siren ÇALMAZ (ActuatorCore'un hırsız bütçesi tükenmiş başlar); yeni tetik çaldırır. Giriş gecikmesi sürerken enerji
//    kesildiyse (kayıt ARM_REC_ENTRY) gecikme baştan başlar ve süre dolunca alarm verilir (Faz 2 incelemesi RV-E2).
//  * Güvenli kip (cfg_corrupt / latch_orphan; setUsable(false)): kip korunur, alarm üretilmez, kurma safe_mode ile reddedilir, çözme serbest.
//  * until_up: gecikmenin bittiği uptime saniyesi (millis/1000, yukarı yuvarlanmış; sabit değer: görünüm imzası her saniye değişmez).
// Zaman karşılaştırmaları (uint32_t)(now - t) biçimindedir (millis() taşmasına dayanıklı).
// ============================================================================
#include "safety/SafetyFsm.h"

namespace safety {

enum class ArmMode : uint8_t { OFF = 0, AWAY = 1, HOME = 2 };   // DeviceCommand SAFETY_ARM value ve MQTT ayrıştırıcısıyla aynı kodlama
enum class ArmSt : uint8_t { IDLE = 0, EXIT = 1, ENTRY = 2, ALARM = 3 };
enum class BuzPattern : uint8_t { OFF = 0, EXIT = 1, ENTRY = 2, ALARM = 3 };   // öncelik: tehlike alarmı > ALARM > ENTRY > EXIT
// ArmRecord.alarm: 0 yok, ARM_REC_ALARM alarm belleği (aid geçerli), ARM_REC_ENTRY giriş gecikmesi sürüyordu (Faz 2 incelemesi RV-E2).
enum : uint8_t { SWINGER_MAX = 3, ARM_REC_VER = 1, ARM_REC_ALARM = 1, ARM_REC_ENTRY = 2 };

inline const char* armModeText(ArmMode m) { return m == ArmMode::AWAY ? "away" : (m == ArmMode::HOME ? "home" : "off"); }
inline const char* armStText(ArmSt s) {
  switch (s) {
    case ArmSt::EXIT: return "exit";
    case ArmSt::ENTRY: return "entry";
    case ArmSt::ALARM: return "alarm";
    default: return "idle";
  }
}

struct ArmRecord {          // 20 B, NVS "ahbu_latch/arm" (CRC yok; sürüm baytı)
  uint8_t ver;              // ARM_REC_VER
  uint8_t mode;             // ArmMode
  uint8_t alarm;            // ARM_REC_ALARM: alarm belleği (aid geçerli); ARM_REC_ENTRY: giriş gecikmesi sürüyordu (aid'de kaynak kodları)
  char aid[EID_LEN];        // ALARM: intrusion_alarm olayının eid'si; ENTRY: giriş yolu sensör kodları (sensorIdCode, en çok 8, sayısı rsv[0])
  uint8_t rsv[2];           // rsv[0]: ENTRY kaydında kaynak kodu sayısı
};
static_assert(sizeof(ArmRecord) == 20, "ArmRecord 20 bayt olmali");
static_assert(EID_LEN >= 8, "ENTRY kaydi 8 kaynak kodu tasir");

// Sensör m kipinde hırsız alarmına dahil mi?
inline bool armedIn(const SensorConfig& c, ArmMode m) {
  if (m == ArmMode::OFF || !isIntrusionKind(c.kind) || !(c.flags & SF_REACT)) return false;
  return m == ArmMode::AWAY || !(c.flags & SF_AWAY_ONLY);
}
inline bool hasIntrusionSensors(const SensorConfig* s, uint8_t n) {
  for (uint8_t i = 0; i < n; i++) if (isIntrusionKind(s[i].kind) && (s[i].flags & SF_REACT)) return true;
  return false;
}

class IntrusionCore {
public:
  IntrusionCore() : cfg_(nullptr), hub_(nullptr), out_(nullptr) { clearRt(); }

  // hub çağıran tarafından configure() edilmiş olmalıdır. rec: NVS'teki kip/alarm belleği (yoksa nullptr).
  void begin(const SafetyConfig* cfg, const SensorHub* hub, EventOutbox* out, const ArmRecord* rec, uint32_t now_ms) {
    cfg_ = cfg;
    hub_ = hub;
    out_ = out;
    clearRt();
    bootAt_ = now_ms;
    if (rec && rec->ver == ARM_REC_VER && rec->mode <= (uint8_t)ArmMode::HOME) {
      mode_ = (ArmMode)rec->mode;
      if (rec->alarm == ARM_REC_ALARM && mode_ != ArmMode::OFF) {
        st_ = ArmSt::ALARM;
        memcpy(aid_, rec->aid, EID_LEN);
        aid_[EID_LEN - 1] = '\0';
        restored_ = true;
      } else if (rec->alarm == ARM_REC_ENTRY && mode_ != ArmMode::OFF) {
        // Giriş gecikmesi sürerken enerji kesildi (RV-E2): gecikme baştan başlar; süre dolunca kaydedilen giriş yolu sensörleri kaynak
        // olur (kapı bu arada kapatılmış olabilir). Çözme alarmı önler.
        st_ = ArmSt::ENTRY;
        const uint8_t n = rec->rsv[0] < 8 ? rec->rsv[0] : 8;
        for (uint8_t k = 0; k < n; k++) if (rec->aid[k]) addId(pend_, nPend_, (uint8_t)rec->aid[k]);
        startDelay(entryDelayS(cfg_->pol), now_ms);
      }
    }
    if (mode_ != ArmMode::OFF) {
      Event e = blank(EvType::ARM_CHANGED, 0, now_ms);
      e.flag = (uint8_t)mode_;
      e.sub = VIA_BOOT;
      emit(e, nullptr);
    }
  }

  // Yapılandırma değişti (hub yeniden kuruldu): kenar belleği ve tetik sayaçları sıfırlanır; kip, durum, aid ve srcs korunur.
  void reconfigured(uint32_t /*now_ms*/) {
    memset(prev_, 0, sizeof(prev_));
    memset(seen_, 0, sizeof(seen_));
    memset(trig_, 0, sizeof(trig_));
    memset(keyPrev_, 0, sizeof(keyPrev_));
    memset(keySeen_, 0, sizeof(keySeen_));
    nPend_ = 0;
  }

  void setUsable(bool v) { usable_ = v; }
  bool usable() const { return usable_; }

  // Kurma/çözme (MQTT safety_arm, LAN /api/arm, CLI ARM, ARM_KEY). via: VIA_* (olay "via").
  Rej command(ArmMode m, uint8_t via, uint32_t now_ms) {
    if (m == ArmMode::OFF) {
      if (mode_ == ArmMode::OFF && st_ != ArmSt::ALARM) return Rej::OK;
      disarm(via, now_ms);
      return Rej::OK;
    }
    if (m > ArmMode::HOME) return Rej::BAD_STATE;
    if (!usable_) return Rej::SAFE_MODE;
    if (st_ == ArmSt::ALARM) return Rej::BAD_STATE;            // önce çözülmeli
    if (m == mode_) return Rej::OK;                            // aynı kip: işlem yok
    if (!anyArmed(m)) return Rej::BAD_STATE;                   // bu kipte izlenecek sensör yok
    if (!ready(m)) return Rej::NOT_READY;
    mode_ = m;
    st_ = ArmSt::EXIT;
    startDelay(exitDelayS(cfg_->pol), now_ms);
    memset(trig_, 0, sizeof(trig_));
    nPend_ = 0;
    nsrcs_ = 0;
    aid_[0] = '\0';
    restored_ = false;
    dirty_ = true;
    Event e = blank(EvType::ARM_CHANGED, 0, now_ms);
    e.flag = (uint8_t)m;
    e.sub = via;
    emit(e, nullptr);
    return Rej::OK;
  }

  // Her loopTask turunda, SafetyCore::tick'ten (SensorHub güncellendikten) SONRA.
  void tick(uint32_t now_ms, uint32_t epoch) {
    epoch_ = epoch;
    if (!cfg_ || !hub_) return;
    keyRoles(now_ms);
    if (!usable_ || mode_ == ArmMode::OFF) {
      snapshotLevels();
      return;
    }
    const uint8_t n = hub_->count();
    bool instant = false, entry = false;
    for (uint8_t i = 0; i < n; i++) {
      const SensorConfig& c = *hub_->config(i);
      if (!armedIn(c, mode_)) continue;
      const bool act = hub_->ok(i) && hub_->active(i);
      if (!act) continue;
      if (c.flags & SF_ENTRY) entry = true;
      else instant = true;
    }
    switch (st_) {
      case ArmSt::EXIT:
        if (instant) {
          raise(now_ms, false);
        } else if (elapsed(now_ms)) {
          if (entry) {
            enterEntry(now_ms);
          } else {
            st_ = ArmSt::IDLE;
            untilUp_ = 0;
          }
        }
        break;
      case ArmSt::IDLE:
        if (instant) {
          raise(now_ms, false);
        } else if (entry) {
          enterEntry(now_ms);
        }
        break;
      case ArmSt::ENTRY:
        collectPending(true);
        if (instant) raise(now_ms, false);
        else if (elapsed(now_ms)) raise(now_ms, true);
        break;
      case ArmSt::ALARM:
        retrigger();
        break;
    }
    snapshotLevels();
  }

  // ---- çıktılar ----
  bool sirenReq() const { return st_ == ArmSt::ALARM && mode_ != ArmMode::OFF; }
  SirenKick takeSirenKick() { const SirenKick k = kick_; kick_ = SirenKick::NONE; return k; }
  BuzPattern buzzer() const {
    if (st_ == ArmSt::ALARM) return restored_ ? BuzPattern::OFF : BuzPattern::ALARM;
    if (st_ == ArmSt::ENTRY) return BuzPattern::ENTRY;
    if (st_ == ArmSt::EXIT) return BuzPattern::EXIT;
    return BuzPattern::OFF;
  }
  bool takeKeyError() { const bool k = keyError_; keyError_ = false; return k; }
  bool takeDirty() { const bool d = dirty_; dirty_ = false; return d; }
  void markDirty() { dirty_ = true; }        // NVS yazımı başarısız: kayıt yeniden denenecek (fw-tarama-5)
  void record(ArmRecord& r) const {
    memset(&r, 0, sizeof(r));
    r.ver = ARM_REC_VER;
    r.mode = (uint8_t)mode_;
    if (st_ == ArmSt::ALARM && aid_[0]) {
      r.alarm = ARM_REC_ALARM;
      memcpy(r.aid, aid_, EID_LEN);
    } else if (st_ == ArmSt::ENTRY && mode_ != ArmMode::OFF) {
      r.alarm = ARM_REC_ENTRY;
      const uint8_t n = nPend_ < 8 ? nPend_ : 8;
      for (uint8_t k = 0; k < n; k++) r.aid[k] = (char)pend_[k];
      r.rsv[0] = n;
    }
  }

  // ---- görünüm ----
  // state.safety.arm yazılır mı: SF_REACT'li kapı/pencere/hareket sensörü var ya da kip kurulu (güvenli kipte tablo yokken de kip görünür).
  bool present() const {
    return (cfg_ && hasIntrusionSensors(cfg_->sens, cfg_->nSens)) || mode_ != ArmMode::OFF || st_ == ArmSt::ALARM;
  }
  ArmMode mode() const { return mode_; }
  ArmSt st() const { return st_; }
  uint32_t untilUp() const { return (st_ == ArmSt::EXIT || st_ == ArmSt::ENTRY) ? untilUp_ : 0; }
  const char* aid() const { return aid_; }
  uint8_t nsrcs() const { return nsrcs_; }
  const uint8_t* srcs() const { return srcs_; }

private:
  void clearRt() {
    mode_ = ArmMode::OFF;
    st_ = ArmSt::IDLE;
    usable_ = true;
    restored_ = false;
    dirty_ = false;
    keyError_ = false;
    kick_ = SirenKick::NONE;
    bootAt_ = 0;
    epoch_ = 0;
    startMs_ = 0;
    spanMs_ = 0;
    untilUp_ = 0;
    nsrcs_ = 0;
    nPend_ = 0;
    memset(aid_, 0, sizeof(aid_));
    memset(srcs_, 0, sizeof(srcs_));
    memset(pend_, 0, sizeof(pend_));
    memset(prev_, 0, sizeof(prev_));
    memset(seen_, 0, sizeof(seen_));
    memset(trig_, 0, sizeof(trig_));
    memset(keyPrev_, 0, sizeof(keyPrev_));
    memset(keySeen_, 0, sizeof(keySeen_));
  }

  Event blank(EvType t, uint8_t zone, uint32_t now_ms) const {
    Event e;
    memset(&e, 0, sizeof(e));
    e.type = (uint8_t)t;
    e.zone = zone;
    e.atUp = (uint32_t)(now_ms - bootAt_) / 1000UL;
    e.atEpoch = epoch_;
    return e;
  }
  void emit(const Event& e, char* eidOut) {
    char tmp[EID_LEN];
    if (out_) out_->push(e, eidOut ? eidOut : tmp);
    else if (eidOut) eidOut[0] = '\0';
  }

  void startDelay(uint8_t s, uint32_t now_ms) {
    startMs_ = now_ms;
    spanMs_ = (uint32_t)s * 1000UL;
    untilUp_ = (uint32_t)((uint64_t)(uint32_t)(now_ms + spanMs_) + 999ULL) / 1000UL;
  }
  bool elapsed(uint32_t now_ms) const { return (uint32_t)(now_ms - startMs_) >= spanMs_; }

  // Giriş gecikmesi başlar; durum kalıcı yazılır (enerji kesintisinde olay kaybolmasın, RV-E2).
  void enterEntry(uint32_t now_ms) {
    st_ = ArmSt::ENTRY;
    collectPending(true);
    startDelay(entryDelayS(cfg_->pol), now_ms);
    dirty_ = true;
  }

  bool anyArmed(ArmMode m) const {
    for (uint8_t i = 0; i < hub_->count(); i++) if (armedIn(*hub_->config(i), m)) return true;
    return false;
  }
  bool ready(ArmMode m) const {
    for (uint8_t i = 0; i < hub_->count(); i++) {
      const SensorConfig& c = *hub_->config(i);
      if (!armedIn(c, m)) continue;
      if (!hub_->ok(i)) return false;
      if (!(c.flags & SF_ENTRY) && (hub_->active(i) || hub_->rawActive(i))) return false;
    }
    return true;
  }

  void addId(uint8_t* ids, uint8_t& n, uint8_t code) {
    for (uint8_t j = 0; j < n; j++) if (ids[j] == code) return;
    if (n < 8) ids[n++] = code;
  }
  // Giriş gecikmesini başlatan/süren giriş yolu sensörleri (giriş süresi dolunca alarm kaynağı olurlar).
  void collectPending(bool entryOnly) {
    for (uint8_t i = 0; i < hub_->count(); i++) {
      const SensorConfig& c = *hub_->config(i);
      if (!armedIn(c, mode_) || (entryOnly && !(c.flags & SF_ENTRY))) continue;
      if (hub_->ok(i) && hub_->active(i)) addId(pend_, nPend_, sensorIdCode(c));
    }
  }

  void raise(uint32_t now_ms, bool fromEntry) {
    nsrcs_ = 0;
    uint8_t zone = 0;
    if (!fromEntry) {
      for (uint8_t i = 0; i < hub_->count(); i++) {      // anlık sensörler önce (ilk tetikleyen bölgesi olay bölgesi)
        const SensorConfig& c = *hub_->config(i);
        if (!armedIn(c, mode_) || (c.flags & SF_ENTRY) || !(hub_->ok(i) && hub_->active(i))) continue;
        if (!zone) zone = c.zone;
        addId(srcs_, nsrcs_, sensorIdCode(c));
        if (trig_[i] < 255) trig_[i]++;
      }
    }
    for (uint8_t k = 0; k < nPend_; k++) {
      addId(srcs_, nsrcs_, pend_[k]);
      const int8_t slot = slotOf(pend_[k]);
      if (slot >= 0) {
        if (!zone) zone = hub_->config((uint8_t)slot)->zone;
        if (trig_[slot] < 255) trig_[slot]++;
      }
    }
    nPend_ = 0;
    st_ = ArmSt::ALARM;
    untilUp_ = 0;
    restored_ = false;
    kick_ = SirenKick::FRESH;
    dirty_ = true;
    Event e = blank(EvType::INTRUSION_ALARM, zone, now_ms);
    e.nsrcs = nsrcs_;
    memcpy(e.srcs, srcs_, sizeof(e.srcs));
    emit(e, aid_);
  }

  int8_t slotOf(uint8_t code) const {
    for (uint8_t i = 0; i < hub_->count(); i++) if (sensorIdCode(*hub_->config(i)) == code) return (int8_t)i;
    return -1;
  }

  // Alarm sürerken yükselen kenar: srcs'e eklenir; swinger sınırı içindeyse durmuş siren yeniden çalar.
  void retrigger() {
    for (uint8_t i = 0; i < hub_->count(); i++) {
      const SensorConfig& c = *hub_->config(i);
      if (!armedIn(c, mode_)) continue;
      const bool act = hub_->ok(i) && hub_->active(i);
      if (!act || !seen_[i] || prev_[i]) continue;
      addId(srcs_, nsrcs_, sensorIdCode(c));
      if (trig_[i] < SWINGER_MAX) {
        trig_[i]++;
        if (kick_ == SirenKick::NONE) kick_ = SirenKick::RETRIGGER;
        restored_ = false;                                  // bellekten gelen alarmda yeni tetik: siren ve buzzer yeniden
      }
    }
  }

  void snapshotLevels() {
    for (uint8_t i = 0; i < hub_->count() && i < MAX_SENSORS; i++) {
      prev_[i] = hub_->ok(i) && hub_->active(i);
      seen_[i] = hub_->ok(i);
    }
  }

  // ARM_KEY (anahtarlı kontak): pasif->aktif kenarı "away" kurar (hazır değilse kurulmaz, hata bip'i), aktif->pasif çözer. İlk okuma kenar değildir.
  void keyRoles(uint32_t now_ms) {
    for (uint8_t i = 0; i < hub_->count() && i < MAX_SENSORS; i++) {
      const SensorConfig& c = *hub_->config(i);
      if (c.kind != (uint8_t)SensorKind::ARM_KEY) continue;
      if (!hub_->ok(i)) continue;
      const bool lv = hub_->rawActive(i);
      if (keySeen_[i] && lv != keyPrev_[i]) {
        if (lv) {
          if (command(ArmMode::AWAY, VIA_DI, now_ms) != Rej::OK) keyError_ = true;
        } else {
          command(ArmMode::OFF, VIA_DI, now_ms);
        }
      }
      keyPrev_[i] = lv;
      keySeen_[i] = true;
    }
  }

  void disarm(uint8_t via, uint32_t now_ms) {
    if (st_ == ArmSt::ALARM) {
      Event c = blank(EvType::INTRUSION_CLEARED, 0, now_ms);
      memcpy(c.aid, aid_, EID_LEN);
      c.aid[EID_LEN - 1] = '\0';
      c.sub = via;
      emit(c, nullptr);
    }
    mode_ = ArmMode::OFF;
    st_ = ArmSt::IDLE;
    untilUp_ = 0;
    nsrcs_ = 0;
    nPend_ = 0;
    aid_[0] = '\0';
    restored_ = false;
    kick_ = SirenKick::NONE;
    dirty_ = true;
    memset(trig_, 0, sizeof(trig_));
    Event e = blank(EvType::ARM_CHANGED, 0, now_ms);
    e.flag = (uint8_t)ArmMode::OFF;
    e.sub = via;
    emit(e, nullptr);
  }

  const SafetyConfig* cfg_;
  const SensorHub* hub_;
  EventOutbox* out_;
  ArmMode mode_;
  ArmSt st_;
  bool usable_;
  bool restored_;           // alarm açılışta bellekten geldi (siren/buzzer çalmaz, yeni tetiğe kadar)
  bool dirty_;
  bool keyError_;
  SirenKick kick_;
  uint32_t bootAt_;
  uint32_t epoch_;
  uint32_t startMs_;
  uint32_t spanMs_;
  uint32_t untilUp_;
  char aid_[EID_LEN];
  uint8_t srcs_[8];
  uint8_t nsrcs_;
  uint8_t pend_[8];
  uint8_t nPend_;
  bool prev_[MAX_SENSORS];
  bool seen_[MAX_SENSORS];
  uint8_t trig_[MAX_SENSORS];
  bool keyPrev_[MAX_SENSORS];
  bool keySeen_[MAX_SENSORS];
};

}  // namespace safety
