#pragma once
// ============================================================================
// safety/SafetyFsm.h - Güvenlik çekirdeği (SafetyCore): bölge durum makinesi (NORMAL / LATCHED / FAULT / TEST), kilit,
// kuruluk sayacı, sensör sağlığı, tür -> akışkan eşlemesi, açma izni, güvenli kip. SAF MANTIK; saat parametre.
//
// Tasarım §5.1.1-5.1.6 (su/vana), §6 (gaz/duman aynı kalıp, K3), §2.3 (yön kuralı), §4.1 (politika kapalı kilidi kaldırmaz).
// Akış (her loopTask turunda, SafetyManager::tick içinden):
//   kaynaklar (DiSensor/BridgeSensor) -> SensorHub (onay, ok, kuruluk) -> bölge FSM -> ActuatorCore (istenen seviye)
//   -> outputMasks() -> SmartAutomation::applySafetyOutput (_want), fiziksel yazım stepOutputs'ta (tek yazıcı).
// Kararlar:
//  * Islak (onaylı) -> LATCHED: bölgedeki, sensör türünün AKIŞKANINA uyan vanalar KAPAT (duman: vana yok) [K-3]; sirenler AÇ;
//    gazda yalnız ex-proof fan AÇ, dumanda fan KAPAT [Y-1]; kart buzzer'ı alarm kipine girer.
//  * ACK ıslakken yalnız susturur (vana kapalı kalır); ACK + kesintisiz kuruluk >= dry_hold -> NORMAL; vana KAPALI KALIR,
//    açmak ayrı bir kullanıcı komutudur. ok=false sensör kuruluk sayacını durdurur [Y-3].
//  * Geri bildirimli vana fb_timeout içinde kapanmazsa FAULT (siren susturulmuş olsa bile yeniden çalar); kapanınca LATCHED.
//  * TEST: bölge vanaları KAPAT + siren 3 sn; geri bildirim ya da zaman aşımı (geri bildirimsiz 5 sn) -> NORMAL; su vanaları
//    önceki konuma döner, gaz vanası KAPALI kalır [K-4]; test sırasında gerçek ıslaklık -> LATCHED.
//  * Açma izni: güvenli kip değil, vananın bütün bölgeleri NORMAL, o bölgelerde vananın akışkanına uyan BÜTÜN sensörler
//    ok && boşta. Gaz vanası yalnız GAS_RESET DI'sinden açılır (gas_local_only). Kapatma HER ZAMAN serbest.
//  * Güvenli kip (cfg_corrupt / latch_orphan / crash_loop): kilit kaydındaki maske her turda yapılandırmadan bağımsız
//    dayatılır; bütün açma komutları safe_mode; çıkış yalnız YEREL yoldan (karar 7.2b-10). Yapılandırma kullanılamıyorsa kalıcı
//    açılış güvenli maskesi de (imposeBootMask) aynı şekilde dayatılır (inceleme turu EM-5).
// İnceleme turu (entegrasyon) kararları:
//  * Kilitli bölgeye YENİ tehlike türü eklenirse yeni alarm olayı (yeni aid) üretilir [E2E-2]; eski aid bayatlar.
//  * FAULT kilit kaydında FAULT olarak saklanır ve geri yüklenir; bölgeye uyan geri bildirimli vanalar KAPALI görülmeden ne FAULT kalkar
//    ne bölge NORMAL'e döner (açılış ya da yapılandırma yaması geri bildirim zamanlayıcısını sıfırlasa bile) [EM-2].
//  * Açılışta KAPALI komutlu iki röleli vanalara bir KAPAT darbesi daha verilir (yarıda kalmış darbe, gaz vanası K-4) [EM-3].
//  * Test sonu geri açma: kullanıcı test sırasında kapattıysa açılmaz; açma izni (openPermission) yoksa açılmaz [EM-4].
// Faz 2 (F2.B.4): siren rölesi iki istek kaynağının VEYA'sıdır: tehlike (bu çekirdek) ve hırsız alarmı (IntrusionCore; setIntrusionSiren).
// Her kaynak kendi run_limit_s bütçesini tutar (ActuatorCore). Tehlike ACK'i yalnız tehlike isteğini, çözme yalnız hırsız isteğini kaldırır;
// kullanıcının sireni kapatması ikisini de o alarm dönemi için bastırır. ARM_KEY kumanda rolü vana sürmez (IntrusionCore'a aittir).
// ============================================================================
#include "safety/SafetyConfig.h"
#include "sensors/SensorHub.h"
#include "actuators/ActuatorMap.h"
#include "events/EventOutbox.h"

namespace safety {

enum class ZoneSt : uint8_t { NORMAL = 0, LATCHED = 1, FAULT = 2, TEST = 3 };

inline const char* zoneStText(ZoneSt s) {
  switch (s) {
    case ZoneSt::LATCHED: return "latched";
    case ZoneSt::FAULT: return "fault";
    case ZoneSt::TEST: return "test";
    default: return "normal";
  }
}

// Ret kodları (state.last_rej.code, LAN yanıtı "rej"); §3.2.
enum class Rej : uint8_t {
  OK = 0, ZONE_LATCHED, ZONE_TEST, ACTUATOR_RELAY, UNKNOWN_ACTUATOR, BAD_STATE, UNSUPPORTED, CFG_CONFLICT, CFG_INVALID,
  GAS_LOCAL_ONLY, STALE_ACK, SAFE_MODE, BAD_CMD, BUSY,
  NOT_READY,      // hırsız alarmı kurulamadı: hazır olmayan (açık ya da okunamayan) sensör var (F2.B.7)
  CFG_STORAGE,    // yapılandırma NVS payı yetmedi (WP-C1; eskiden "busy")
  ARMED           // hırsız alarmı kurulu: bulut yaması alarmı zayıflatırdı (Faz 2 incelemesi G-1b)
};

inline const char* rejText(Rej r) {
  switch (r) {
    case Rej::OK: return "";
    case Rej::ZONE_LATCHED: return "zone_latched";
    case Rej::ZONE_TEST: return "zone_test";
    case Rej::ACTUATOR_RELAY: return "actuator_relay";
    case Rej::UNKNOWN_ACTUATOR: return "unknown_actuator";
    case Rej::BAD_STATE: return "bad_state";
    case Rej::UNSUPPORTED: return "unsupported";
    case Rej::CFG_CONFLICT: return "cfg_conflict";
    case Rej::CFG_INVALID: return "cfg_invalid";
    case Rej::GAS_LOCAL_ONLY: return "gas_local_only";
    case Rej::STALE_ACK: return "stale_ack";
    case Rej::SAFE_MODE: return "safe_mode";
    case Rej::BAD_CMD: return "bad_cmd";
    case Rej::BUSY: return "busy";
    case Rej::NOT_READY: return "not_ready";
    case Rej::CFG_STORAGE: return "cfg_storage";
    case Rej::ARMED: return "armed";
  }
  return "";
}

// Komutun geldiği yol: güvenli kipten çıkış ve gaz vanası açma yalnız yerel yollardan.
enum class Origin : uint8_t {
  REMOTE = 0,     // MQTT / LAN API / senaryo
  LOCAL_DI = 1,   // duvar butonu, güvenlik DI rolleri, seri CLI (fiziksel erişim)
  GAS_RESET = 2,  // GAS_RESET DI'si (yerinde gaz vanası açma)
  SAFETY = 3      // çekirdeğin kendisi
};

enum : uint32_t { TEST_SIREN_MS = 3000, TEST_NOFB_MS = 5000, SAFE_ACK_HOLD_MS = 5000 };

// Hırsız siren tetiği (IntrusionCore -> setIntrusionSiren): yeni alarm bütçeyi her durumda sıfırlar; yeniden tetik (swinger sınırı içinde)
// yalnız bütçesi bitmiş (durmuş) sireni yeniden çaldırır.
enum class SirenKick : uint8_t { NONE = 0, FRESH = 1, RETRIGGER = 2 };

struct ZoneRt {
  ZoneSt st;
  uint8_t kinds;            // kilit türü (HZ_*)
  bool silenced;
  bool acked;
  char aid[EID_LEN];        // alarmı açan olayın eid'si
  uint32_t sinceMs;         // kilit anı (millis)
  uint32_t sinceEpoch;      // time_ok ise
  uint8_t srcs[8];
  uint8_t nsrcs;
  uint32_t testAt;
  uint16_t testValves;      // testte kapatılan vanalar (eylemci bitleri)
  uint16_t testPrevOpen;    // ... ve testten önce açık olanlar
};

class SafetyCore {
public:
  SafetyCore()
      : cfg_(nullptr), hub_(nullptr), act_(nullptr), out_(nullptr), mode_(SafeReason::NONE), bootAt_(0), epoch_(0),
        policyOn_(true), cfgUsable_(false), latchDirty_(false), intrReq_(false), latchAssert_(0), latchLevel_(0), latchRecAssert_(0) {
    memset(zone_, 0, sizeof(zone_));
    memset(manualOn_, 0, sizeof(manualOn_));
    memset(userSuppress_, 0, sizeof(userSuppress_));
    memset(intrSuppress_, 0, sizeof(intrSuppress_));
    memset(holdFired_, 0, sizeof(holdFired_));
  }

  // hub ve act çağıran tarafından configure() edilmiş olmalıdır (act: act_pos ile). latch: geçerli kilit kaydı ya da nullptr.
  void begin(const SafetyConfig* cfg, SensorHub* hub, ActuatorCore* act, EventOutbox* out, const LatchRecord* latch,
             SafeReason mode, uint32_t now_ms) {
    cfg_ = cfg;
    hub_ = hub;
    act_ = act;
    out_ = out;
    mode_ = mode;
    bootAt_ = now_ms;
    epoch_ = 0;
    policyOn_ = cfg_ ? cfg_->pol.policy_on != 0 : true;
    cfgUsable_ = false;
    latchDirty_ = false;
    latchAssert_ = latchLevel_ = latchRecAssert_ = 0;
    intrReq_ = false;
    memset(zone_, 0, sizeof(zone_));
    memset(manualOn_, 0, sizeof(manualOn_));
    memset(userSuppress_, 0, sizeof(userSuppress_));
    memset(intrSuppress_, 0, sizeof(intrSuppress_));
    memset(holdFired_, 0, sizeof(holdFired_));
    if (latch && latchValid(*latch) && latchAny(*latch)) {
      for (uint8_t z = 1; z <= MAX_ZONES; z++) {
        const LatchZone& lz = latch->z[z - 1];
        if (lz.st == 0) continue;
        ZoneRt& Z = zone_[z];
        Z.st = (lz.st == (uint8_t)ZoneSt::FAULT) ? ZoneSt::FAULT : ZoneSt::LATCHED;   // FAULT, geri bildirim KAPALI görülene dek sürer [EM-2]
        Z.kinds = lz.kinds ? lz.kinds : (uint8_t)HZ_ALL;   // türü bilinmeyen kilit: en tutucu (bütün vanalar)
        Z.silenced = lz.silenced != 0;
        Z.acked = lz.acked != 0;
        memcpy(Z.aid, lz.aid, sizeof(Z.aid));
        Z.aid[EID_LEN - 1] = '\0';
        Z.sinceMs = now_ms;
        Z.sinceEpoch = lz.sinceEpoch;
        Z.nsrcs = lz.nsrcs > 8 ? 8 : lz.nsrcs;
        memcpy(Z.srcs, lz.srcs, sizeof(Z.srcs));
      }
      latchAssert_ = latchAssert64(*latch);
      latchLevel_ = latchLevel64(*latch);
    }
    latchRecAssert_ = latchAssert_;
    // İki röleli vananın konumu darbeyle kurulur, seviyesi yoktur: KAPALI komutlu vanaya açılışta bir KAPAT darbesi daha verilir
    // (yeniden başlatma darbeyi yarıda kesmiş olabilir; gaz vanası her açılışta kapalıdır [K-4]) [EM-3].
    for (uint8_t i = 0; act_ && i < act_->count(); i++) {
      if (isPulseValve(*act_->config(i)) && act_->closedCmd(i)) act_->commandValve(i, true, now_ms);
    }
    if (mode_ != SafeReason::NONE) {
      Event e = blank(EvType::SAFE_MODE, 0, now_ms);
      e.sub = (uint8_t)mode_;
      emit(e, nullptr);
    }
    enforceLatchedValves(now_ms);
  }

  // Çalışırken yapılandırma değişti (SafetyManager::applyConfigOnLoop, WP-F5): eylemci başına geçici durum (elle açık anahtar, kullanıcı
  // susturması) fromOld eşlemesiyle (actuatorIdentityMap; nullptr = hiçbiri) yeni indekslere taşınır, eşlenmeyenler sıfırlanır; basılı tutma
  // sıfırlanır; politika yeni yapılandırmadan alınır (değiştiyse policy_changed, via ile). Bölge durumları, aid'ler ve kilit KORUNUR; kilitli
  // bölgedeki vanalar aynı turda yeniden kapalı tutulur. Test bölgesindeki vana bitleri de eşlemeyle taşınır.
  void reconfigured(uint8_t via, uint32_t now_ms, const int8_t* fromOld = nullptr) {
    bool man[MAX_ACTUATORS], sup[MAX_ACTUATORS], isup[MAX_ACTUATORS];
    memcpy(man, manualOn_, sizeof(man));
    memcpy(sup, userSuppress_, sizeof(sup));
    memcpy(isup, intrSuppress_, sizeof(isup));
    memset(manualOn_, 0, sizeof(manualOn_));
    memset(userSuppress_, 0, sizeof(userSuppress_));
    memset(intrSuppress_, 0, sizeof(intrSuppress_));
    for (uint8_t z = 1; z <= MAX_ZONES; z++) {
      ZoneRt& Z = zone_[z];
      const uint16_t tv = Z.testValves, tp = Z.testPrevOpen;
      Z.testValves = Z.testPrevOpen = 0;
      for (uint8_t j = 0; fromOld && j < MAX_ACTUATORS; j++) {
        const int8_t i = fromOld[j];
        if (i < 0 || i >= (int8_t)MAX_ACTUATORS) continue;
        if (tv & (1u << i)) Z.testValves |= (uint16_t)(1u << j);
        if (tp & (1u << i)) Z.testPrevOpen |= (uint16_t)(1u << j);
      }
    }
    for (uint8_t j = 0; fromOld && j < MAX_ACTUATORS; j++) {
      const int8_t i = fromOld[j];
      if (i < 0 || i >= (int8_t)MAX_ACTUATORS) continue;
      manualOn_[j] = man[i];
      userSuppress_[j] = sup[i];
      intrSuppress_[j] = isup[i];
    }
    memset(holdFired_, 0, sizeof(holdFired_));
    if (cfg_) setPolicy(cfg_->pol.policy_on != 0, via, now_ms);
    enforceLatchedValves(now_ms);
  }

  // Yapılandırma yeniden yüklenip validate geçince ve eylemci röleleri kilit maskesini kapsayınca SafetyManager bildirir.
  void setConfigUsable(bool v) { cfgUsable_ = v; }

  // Hırsız alarmının siren isteği (F2.B.4; IntrusionCore her turda). req kalkınca kullanıcı bastırması da kalkar (alarm dönemi bitti).
  // FRESH: bütün sirenlerin hırsız bütçesi sıfırlanır; RETRIGGER: yalnız bütçesi bitmiş (durmuş) siren yeniden çalar. Çıkış aynı turda sürülür.
  void setIntrusionSiren(bool req, SirenKick kick, uint32_t now_ms) {
    if (!act_) return;
    if (!req) memset(intrSuppress_, 0, sizeof(intrSuppress_));
    for (uint8_t i = 0; i < act_->count(); i++) {
      if (act_->config(i)->kind != (uint8_t)ActKind::SIREN) continue;
      if (kick == SirenKick::FRESH || (kick == SirenKick::RETRIGGER && act_->intrusionLimited(i))) act_->restartIntrusion(i);
    }
    intrReq_ = req;
    driveSwitches(now_ms);
  }
  bool intrusionSirenRequested() const { return intrReq_; }

  void tick(uint32_t now_ms, uint32_t epoch, SensorSource* di, SensorSource* bridge) {
    epoch_ = epoch;
    if (!cfg_ || !hub_ || !act_) return;
    if (!active()) return;                       // sensör/eylemci/kilit yok: O(1) (lamba/panjur yolu etkilenmez)
    // 1) sensörler
    for (uint8_t i = 0; i < hub_->count(); i++) {
      const SensorConfig& c = *hub_->config(i);
      SensorSource* src = (c.src == (uint8_t)SensorSrc::BRIDGE) ? bridge : di;
      SensorSample s;
      s.level = false;
      s.ok = false;
      if (src) s = src->sample(c, now_ms);
      hub_->update(i, s.level, s.ok, now_ms);
    }
    hub_->finish(now_ms);
    // 2) vana geri bildirimleri
    for (uint8_t i = 0; i < act_->count(); i++) {
      const ActuatorConfig& a = *act_->config(i);
      if (a.fb_di == 0 || !di) continue;
      SensorConfig fc;
      memset(&fc, 0, sizeof(fc));
      fc.src = (uint8_t)SensorSrc::DI;
      fc.index = a.fb_di;
      SensorSample s = di->sample(fc, now_ms);
      if (s.ok) act_->setFeedback(i, s.level);
    }
    act_->tick(now_ms);                          // geri bildirim süresi / arıza bu turun örneğiyle (FSM'den önce)
    // 3) sensör arıza olayları
    sensorFaultEvents(now_ms);
    // 4) yerel kumanda rolleri
    controlRoles(now_ms);
    // 5) bölge FSM
    for (uint8_t z = 1; z <= MAX_ZONES; z++) stepZone(z, now_ms);
    // 6) güvenli kip (crash_loop) çıkışı: 30 dk kesintisiz çalışma
    if (mode_ == SafeReason::CRASH_LOOP && (uint32_t)(now_ms - bootAt_) >= CRASH_EXIT_MS) {
      mode_ = SafeReason::NONE;
      latchAssert_ = latchLevel_ = 0;
      latchDirty_ = true;
    }
    // 7) çıkışlar (her turda yeniden dayatma)
    enforceLatchedValves(now_ms);
    driveSwitches(now_ms);
    act_->tick(now_ms);
  }

  // ---- komutlar (dönüş: ret kodu) ----
  // zone 0 = bütün bölgeler. aid: uzaktan onayda bölgenin güncel aid'si (yerelde nullptr). force: güvenli kipten çıkış.
  Rej ack(uint8_t zone, const char* aid, Origin origin, bool force, uint32_t now_ms) {
    if (zone > MAX_ZONES) return Rej::BAD_STATE;
    if (mode_ != SafeReason::NONE && force) {
      if (origin != Origin::LOCAL_DI || mode_ == SafeReason::CRASH_LOOP || !cfgUsable_) return Rej::SAFE_MODE;
      exitSafeMode(now_ms);
      return Rej::OK;
    }
    if (zone != 0 && aid && zone_[zone].st != ZoneSt::NORMAL && zone_[zone].st != ZoneSt::TEST &&
        strcmp(aid, zone_[zone].aid) != 0) {
      return Rej::STALE_ACK;
    }
    for (uint8_t z = 1; z <= MAX_ZONES; z++) {
      if (zone != 0 && z != zone) continue;
      ZoneRt& Z = zone_[z];
      if (Z.st != ZoneSt::LATCHED && Z.st != ZoneSt::FAULT) continue;
      Z.acked = true;
      latchDirty_ = true;
      if (canClear(z, now_ms)) {
        clearZone(z, now_ms);
      } else if (!Z.silenced) {
        Z.silenced = true;
        Event e = blank(EvType::ALARM_SILENCED, z, now_ms);
        e.kinds = Z.kinds;
        setAid(e, Z);
        emit(e, nullptr);
      }
    }
    return Rej::OK;
  }

  Rej test(uint8_t zone, uint32_t now_ms) {
    if (zone < 1 || zone > MAX_ZONES) return Rej::BAD_STATE;
    if (mode_ != SafeReason::NONE) return Rej::SAFE_MODE;
    ZoneRt& Z = zone_[zone];
    if (Z.st == ZoneSt::TEST) return Rej::ZONE_TEST;
    if (Z.st != ZoneSt::NORMAL) return Rej::ZONE_LATCHED;
    Z.st = ZoneSt::TEST;
    Z.testAt = now_ms;
    Z.testValves = 0;
    Z.testPrevOpen = 0;
    for (uint8_t i = 0; i < act_->count(); i++) {
      const ActuatorConfig& a = *act_->config(i);
      if (!isValve(a) || !(a.zone_mask & zbit(zone))) continue;
      Z.testValves |= (uint16_t)(1u << i);
      if (!act_->closedCmd(i)) Z.testPrevOpen |= (uint16_t)(1u << i);
      act_->commandValve(i, true, now_ms);
    }
    return Rej::OK;
  }

  // safe=true: vana KAPAT / anahtar KAPAT (her zaman serbest). safe=false: vana AÇ / anahtar AÇ (izin denetimi).
  Rej actuatorSet(uint8_t i, bool safe, Origin origin, uint32_t now_ms) {
    if (!act_ || i >= act_->count()) return Rej::UNKNOWN_ACTUATOR;
    const ActuatorConfig& a = *act_->config(i);
    const uint16_t bit = (uint16_t)(1u << i);
    Event e = blank(EvType::ACTUATOR_CHANGED, 0, now_ms);
    if (isValve(a)) {
      if (safe) {
        const bool changed = !act_->closedCmd(i);
        for (uint8_t z = 1; z <= MAX_ZONES; z++) zone_[z].testPrevOpen &= (uint16_t)~bit;   // kullanıcı kapattı: test sonu açılmaz [EM-4]
        act_->commandValve(i, true, now_ms);
        if (changed) { e.actClose = bit; emit(e, nullptr); }
        return Rej::OK;
      }
      if (mode_ != SafeReason::NONE) return Rej::SAFE_MODE;
      if (isGasValve(a) && origin != Origin::GAS_RESET) return Rej::GAS_LOCAL_ONLY;
      const Rej r = openPermission(a);
      if (r != Rej::OK) return r;
      const bool changed = act_->closedCmd(i) || !act_->known(i);
      act_->commandValve(i, false, now_ms);
      if (changed) { e.actOpen = bit; emit(e, nullptr); }
      return Rej::OK;
    }
    if (safe) {
      const bool was = manualOn_[i] || act_->on(i) || act_->intrusionOn(i);
      manualOn_[i] = false;
      if (autoOn(i, now_ms)) userSuppress_[i] = true;
      if (intrReq_ && a.kind == (uint8_t)ActKind::SIREN) intrSuppress_[i] = true;   // hırsız isteği de bu alarm dönemi için bastırılır
      if (was) { e.actOff = bit; emit(e, nullptr); }
      return Rej::OK;
    }
    if (a.kind == (uint8_t)ActKind::FAN) {
      for (uint8_t z = 1; z <= MAX_ZONES; z++) {
        if (!(a.zone_mask & zbit(z)) || !latched(z)) continue;
        if ((zone_[z].kinds & HZ_SMOKE) || ((zone_[z].kinds & HZ_GAS) && !(a.aflags & AF_FAN_EXPROOF))) return Rej::ZONE_LATCHED;
      }
    }
    if (!manualOn_[i]) { e.actOn = bit; emit(e, nullptr); }
    manualOn_[i] = true;
    userSuppress_[i] = false;
    return Rej::OK;
  }

  // Ham röle komutu (RELAY_SET/TOGGLE, CLI, LAN, ham RS485) için yön kuralı [O4]: SAFE ise "kullanıcı kapattı" uygulanır.
  RawDecision rawRelay(uint8_t relay1, bool level, Origin origin, uint32_t now_ms) {
    if (!cfg_) return RawDecision::NOT_ACTUATOR;
    const RawResult r = rawCommand(cfg_->act, act_ ? act_->count() : 0, relay1, level);
    if (r.d == RawDecision::SAFE) actuatorSet((uint8_t)r.act, true, origin, now_ms);
    return r.d;
  }

  void setPolicy(bool on, uint8_t via, uint32_t now_ms) {
    if (on == policyOn_) return;
    policyOn_ = on;
    Event e = blank(EvType::POLICY_CHANGED, 0, now_ms);
    e.flag = on ? 1 : 0;
    e.sub = via;
    emit(e, nullptr);
  }

  // ---- çıktılar ----
  // assertMask: güvenlik katmanının sahip olduğu röleler; levelMask: istenen seviyeler. Güvenli kipte kilit maskesi
  // yapılandırmadan bağımsız EZER [Y-4].
  void outputMasks(uint64_t& assertMask, uint64_t& levelMask) const {
    const uint64_t la = (mode_ != SafeReason::NONE) ? latchAssert_ : 0;
    const uint64_t base = act_ ? act_->levelMask() : 0;
    assertMask = (act_ ? act_->relayMask() : 0) | la;
    levelMask = applyLatchMask(base, la, latchLevel_) & assertMask;
  }

  // Yapılandırma kullanılamıyor (güvenli kip): kalıcı açılış güvenli maskesi (bootSafeMasks; NVS "safe_msk") kilit maskesinin
  // dayatmadığı rollere eklenir; seviyede kilit kaydı kazanır. Güvenli kip değilse etkisiz. Çıkış kullanılabilirliğine (setConfigUsable)
  // yalnız kilit kaydının maskesi (latchRecordAssert) girer: silinmiş bir vananın rolesi güvenli kipten çıkışı kilitlemez [EM-5].
  void imposeBootMask(uint64_t assertMask, uint64_t levelMask) {
    if (mode_ == SafeReason::NONE) return;
    const uint64_t add = assertMask & ~latchAssert_;
    latchAssert_ |= add;
    latchLevel_ = (latchLevel_ & ~add) | (levelMask & add);
  }
  uint64_t latchRecordAssert() const { return latchRecAssert_; }

  // Güvenli kipte dayatılan kilit maskesi (ValveGuard'ın tutma maskesine eklenir); güvenli kip değilse 0.
  void latchMasks(uint64_t& assertMask, uint64_t& levelMask) const {
    assertMask = (mode_ != SafeReason::NONE) ? latchAssert_ : 0;
    levelMask = latchLevel_ & assertMask;
  }

  bool buzzer() const {
    for (uint8_t z = 1; z <= MAX_ZONES; z++) if (latched(z) && !zone_[z].silenced) return true;
    return false;
  }

  // Kilit kaydı: bölgeler + kilitli vanaların güvenli seviyeleri (güvenli kipte eski maske de korunur).
  void buildLatch(LatchRecord& r) const {
    memset(&r, 0, sizeof(r));
    uint64_t as = 0, lv = 0;
    for (uint8_t z = 1; z <= MAX_ZONES; z++) {
      const ZoneRt& Z = zone_[z];
      if (!latched(z)) continue;
      LatchZone& lz = r.z[z - 1];
      lz.st = (uint8_t)Z.st;
      lz.kinds = Z.kinds;
      lz.silenced = Z.silenced ? 1 : 0;
      lz.acked = Z.acked ? 1 : 0;
      memcpy(lz.aid, Z.aid, sizeof(lz.aid));
      lz.nsrcs = Z.nsrcs;
      lz.sinceEpoch = Z.sinceEpoch;
      memcpy(lz.srcs, Z.srcs, sizeof(lz.srcs));
      for (uint8_t i = 0; act_ && i < act_->count(); i++) {
        const ActuatorConfig& a = *act_->config(i);
        if (!valveMatches(a, z, Z.kinds)) continue;
        if (isPulseValve(a)) {
          as |= relayBit(a.relay2);       // AÇ rölesi kilit boyunca 0
        } else {
          as |= relayBit(a.relay);
          if (relayLevelFor(a, true)) lv |= relayBit(a.relay);
        }
      }
    }
    if (mode_ != SafeReason::NONE) {
      lv = (lv & ~latchAssert_) | (latchLevel_ & latchAssert_);
      as |= latchAssert_;
    }
    latchSetMasks(r, as, lv);
    latchSeal(r);
  }
  bool takeLatchDirty() { bool d = latchDirty_; latchDirty_ = false; return d; }
  void markLatchDirty() { latchDirty_ = true; }   // NVS yazımı başarısız: kilit kaydı yeniden denenecek (fw-tarama-5)

  // ---- durum ----
  // Sensör/eylemci, kilit, test ya da güvenli kip yoksa çekirdek boştadır (tick O(1)).
  bool active() const {
    bool zones = false;
    for (uint8_t z = 1; z <= MAX_ZONES && !zones; z++) zones = zone_[z].st != ZoneSt::NORMAL;
    return (cfg_ && (cfg_->nSens || cfg_->nAct)) || mode_ != SafeReason::NONE || zones;
  }
  bool safeMode() const { return mode_ != SafeReason::NONE; }
  SafeReason safeReason() const { return mode_; }
  bool policyOn() const { return policyOn_; }
  ZoneSt zoneState(uint8_t z) const { return (z >= 1 && z <= MAX_ZONES) ? zone_[z].st : ZoneSt::NORMAL; }
  const ZoneRt& zone(uint8_t z) const { return zone_[(z >= 1 && z <= MAX_ZONES) ? z : 0]; }
  uint8_t latchedZoneMask() const {
    uint8_t m = 0;
    for (uint8_t z = 1; z <= MAX_ZONES; z++) if (latched(z)) m |= zbit(z);
    return m;
  }
  uint32_t sinceUpS(uint8_t z, uint32_t now_ms) const { return (uint32_t)(now_ms - zone_[z].sinceMs) / 1000UL; }

private:
  static uint8_t zbit(uint8_t z) { return (uint8_t)(1u << (z - 1)); }
  bool latched(uint8_t z) const { return zone_[z].st == ZoneSt::LATCHED || zone_[z].st == ZoneSt::FAULT; }
  static bool valveMatches(const ActuatorConfig& a, uint8_t z, uint8_t kinds) {
    return isValve(a) && (a.zone_mask & zbit(z)) && (mediumHazard(a.medium) & kinds);
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
  // Bölgenin güncel alarm kimliğini olaya taşır (sunucu alarm satırını aid ile bulur; CONTRACTS §2.6).
  static void setAid(Event& e, const ZoneRt& Z) {
    memcpy(e.aid, Z.aid, sizeof(e.aid));
    e.aid[EID_LEN - 1] = '\0';
  }
  void emit(const Event& e, char* eidOut) {
    char tmp[EID_LEN];
    if (out_) out_->push(e, eidOut ? eidOut : tmp);
    else if (eidOut) eidOut[0] = '\0';
  }

  Rej openPermission(const ActuatorConfig& a) const {
    const uint8_t hz = mediumHazard(a.medium);
    for (uint8_t z = 1; z <= MAX_ZONES; z++) {
      if (!(a.zone_mask & zbit(z))) continue;
      if (zone_[z].st == ZoneSt::TEST) return Rej::ZONE_TEST;
      if (zone_[z].st != ZoneSt::NORMAL) return Rej::ZONE_LATCHED;
      for (uint8_t s = 0; s < hub_->count(); s++) {
        const SensorConfig& c = *hub_->config(s);
        if (c.zone != z || hazardOf(c.kind) != hz) continue;
        if (!hub_->idle(s)) return Rej::ZONE_LATCHED;
      }
    }
    return Rej::OK;
  }

  bool canClear(uint8_t z, uint32_t now_ms) const {
    const ZoneRt& Z = zone_[z];
    if (mode_ != SafeReason::NONE || Z.st != ZoneSt::LATCHED || !Z.acked) return false;
    if (fbUnconfirmed(z)) return false;            // geri bildirimli vana KAPALI görülmedi [EM-2]
    const uint32_t hold = cfg_->pol.dry_hold_ms ? cfg_->pol.dry_hold_ms : DRY_HOLD_DEFAULT_MS;
    return hub_->zoneDryMs(z, now_ms) >= hold;
  }

  // Bölgenin kilit türüne uyan geri bildirimli vanalardan biri henüz KAPALI görülmedi mi (okunmadı ya da açık)?
  bool fbUnconfirmed(uint8_t z) const {
    for (uint8_t i = 0; i < act_->count(); i++) {
      if (valveMatches(*act_->config(i), z, zone_[z].kinds) && act_->hasFb(i) && !act_->fbClosed(i)) return true;
    }
    return false;
  }

  void raise(uint8_t z, uint8_t kinds, uint32_t now_ms) {
    ZoneRt& Z = zone_[z];
    Z.st = ZoneSt::LATCHED;
    Z.kinds = kinds;
    Z.silenced = false;
    Z.acked = false;
    Z.sinceMs = now_ms;
    Z.sinceEpoch = epoch_;
    Z.nsrcs = hub_->zoneSources(z, kinds, Z.srcs, 8);
    Event e = blank(EvType::ALARM_RAISED, z, now_ms);
    e.kinds = kinds;
    e.nsrcs = Z.nsrcs;
    memcpy(e.srcs, Z.srcs, sizeof(e.srcs));
    applyAlarmActions(z, kinds, now_ms, e);
    latchDirty_ = true;
    emit(e, Z.aid);
  }

  // Kilitli bölgeye yeni tür eklendi ya da ilk kilit: akışkana uyan vanalar KAPAT, sirenler AÇ (bütçe sıfırlanır), fanlar.
  void applyAlarmActions(uint8_t z, uint8_t kinds, uint32_t now_ms, Event& e) {
    for (uint8_t i = 0; i < act_->count(); i++) {
      const ActuatorConfig& a = *act_->config(i);
      if (!(a.zone_mask & zbit(z))) continue;
      const uint16_t bit = (uint16_t)(1u << i);
      if (isValve(a)) {
        if (mediumHazard(a.medium) & kinds) {
          act_->commandValve(i, true, now_ms);
          e.actClose |= bit;
        }
      } else if (a.kind == (uint8_t)ActKind::SIREN) {
        act_->resetSirenBudget(i);
        userSuppress_[i] = false;
        e.actOn |= bit;
      } else if (a.kind == (uint8_t)ActKind::FAN) {
        if (kinds & HZ_SMOKE) e.actOff |= bit;
        else if ((kinds & HZ_GAS) && (a.aflags & AF_FAN_EXPROOF)) e.actOn |= bit;
      }
    }
  }

  void clearZone(uint8_t z, uint32_t now_ms) {
    ZoneRt& Z = zone_[z];
    Event e = blank(EvType::ALARM_CLEARED, z, now_ms);
    e.kinds = Z.kinds;
    setAid(e, Z);
    memset(&Z, 0, sizeof(Z));
    Z.st = ZoneSt::NORMAL;
    latchDirty_ = true;
    emit(e, nullptr);
  }

  void exitSafeMode(uint32_t now_ms) {
    for (uint8_t z = 1; z <= MAX_ZONES; z++) {
      if (!latched(z)) continue;
      for (uint8_t i = 0; i < act_->count(); i++) {
        if (valveMatches(*act_->config(i), z, zone_[z].kinds)) act_->commandValve(i, true, now_ms);   // vana kapalı kalır
      }
      clearZone(z, now_ms);
    }
    for (uint8_t i = 0; i < act_->count(); i++) {      // kilit maskesindeki vanalar da kapalı kalır (maske artık dayatılmaz)
      const ActuatorConfig& a = *act_->config(i);
      if (isValve(a) && (relayBits(a) & latchAssert_)) act_->commandValve(i, true, now_ms);
    }
    mode_ = SafeReason::NONE;
    latchAssert_ = latchLevel_ = 0;
    latchDirty_ = true;
  }

  bool fbFaultInZone(uint8_t z, uint16_t& faulty) const {
    faulty = 0;
    for (uint8_t i = 0; i < act_->count(); i++) {
      if (valveMatches(*act_->config(i), z, zone_[z].kinds) && act_->fbFault(i)) faulty |= (uint16_t)(1u << i);
    }
    return faulty != 0;
  }

  void stepZone(uint8_t z, uint32_t now_ms) {
    ZoneRt& Z = zone_[z];
    const uint8_t wet = policyOn_ ? hub_->zoneWet(z) : 0;
    switch (Z.st) {
      case ZoneSt::NORMAL:
        if (wet) raise(z, wet, now_ms);
        break;
      case ZoneSt::TEST:
        if (wet) {                                 // gerçek alarm öncelikli: vanalar kapalı kalır
          Z.testValves = 0;
          raise(z, wet, now_ms);
        } else {
          stepTest(z, now_ms);
        }
        break;
      case ZoneSt::LATCHED:
      case ZoneSt::FAULT: {
        if (wet & ~Z.kinds) {                      // yeni tehlike türü: eylemleri genişlet, yeniden çal, YENİ alarm olayı [E2E-2]
          const uint8_t add = (uint8_t)(wet & ~Z.kinds);
          Z.kinds |= add;
          Z.silenced = false;
          Z.acked = false;
          joinSources(z);
          Event e = blank(EvType::ALARM_RAISED, z, now_ms);
          e.kinds = Z.kinds;
          e.nsrcs = Z.nsrcs;
          memcpy(e.srcs, Z.srcs, sizeof(e.srcs));
          applyAlarmActions(z, add, now_ms, e);
          latchDirty_ = true;
          emit(e, Z.aid);                          // bölgenin alarm kimliği yeni olay olur; eski aid bayatlar (stale_ack)
        }
        if (wet) joinSources(z);
        uint16_t faulty;
        const bool f = fbFaultInZone(z, faulty);
        if (Z.st == ZoneSt::LATCHED && f) {
          Z.st = ZoneSt::FAULT;
          Z.silenced = false;
          latchDirty_ = true;
          Event e = blank(EvType::VALVE_FAULT, z, now_ms);
          e.kinds = Z.kinds;
          e.actClose = faulty;
          setAid(e, Z);
          emit(e, nullptr);
        } else if (Z.st == ZoneSt::FAULT && !f && !fbUnconfirmed(z)) {
          Z.st = ZoneSt::LATCHED;
          latchDirty_ = true;
          Event e = blank(EvType::VALVE_FAULT_CLEARED, z, now_ms);
          e.kinds = Z.kinds;
          setAid(e, Z);
          emit(e, nullptr);
        }
        if (canClear(z, now_ms)) clearZone(z, now_ms);
        break;
      }
    }
  }

  void joinSources(uint8_t z) {
    ZoneRt& Z = zone_[z];
    uint8_t ids[8];
    const uint8_t n = hub_->zoneSources(z, Z.kinds, ids, 8);
    for (uint8_t k = 0; k < n && Z.nsrcs < 8; k++) {
      bool have = false;
      for (uint8_t j = 0; j < Z.nsrcs && !have; j++) have = Z.srcs[j] == ids[k];
      if (!have) { Z.srcs[Z.nsrcs++] = ids[k]; latchDirty_ = true; }
    }
  }

  void stepTest(uint8_t z, uint32_t now_ms) {
    ZoneRt& Z = zone_[z];
    bool anyFb = false, allClosed = true;
    uint32_t tmo = TEST_NOFB_MS, fbMax = 0;
    for (uint8_t i = 0; i < act_->count(); i++) {
      if (!(Z.testValves & (1u << i)) || !act_->hasFb(i)) continue;
      const ActuatorConfig& a = *act_->config(i);
      const uint32_t t = (uint32_t)(a.fb_timeout_s ? a.fb_timeout_s : FB_TIMEOUT_DEFAULT_S) * 1000UL;
      if (!anyFb || t > tmo) tmo = t;
      anyFb = true;
      if (!act_->fbClosed(i)) allClosed = false;
      else if (act_->fbMs(i) > fbMax) fbMax = act_->fbMs(i);
    }
    const uint32_t el = (uint32_t)(now_ms - Z.testAt);
    const bool done = anyFb ? (allClosed || el >= tmo) : (el >= TEST_NOFB_MS);
    if (!done) return;
    Z.st = ZoneSt::NORMAL;                         // geri açma izni NORMAL bölgeyle değerlendirilir
    for (uint8_t i = 0; i < act_->count(); i++) {
      if (!(Z.testValves & (1u << i))) continue;
      const ActuatorConfig& a = *act_->config(i);
      if (isGasValve(a) || !(Z.testPrevOpen & (1u << i))) continue;   // gaz KAPALI kalır [K-4]
      if (mode_ == SafeReason::NONE && openPermission(a) == Rej::OK) act_->commandValve(i, false, now_ms);   // izin yoksa kapalı kalır [EM-4]
    }
    Event e = blank(EvType::TEST_RESULT, z, now_ms);
    e.flag = (!anyFb || allClosed) ? 1 : 0;
    e.sub = anyFb ? 1 : 0;   // fb_ms yalnız geri bildirimli vanada yazılır
    e.val = (uint16_t)(fbMax > 0xFFFF ? 0xFFFF : fbMax);
    Z.testValves = Z.testPrevOpen = 0;
    emit(e, nullptr);
  }

  void sensorFaultEvents(uint32_t now_ms) {
    const uint64_t f = hub_->takeFaultEdges();
    const uint64_t c = hub_->takeFaultClearedEdges();
    for (uint8_t i = 0; i < hub_->count(); i++) {
      const uint64_t b = 1ULL << i;
      if (!((f | c) & b)) continue;
      const SensorConfig& s = *hub_->config(i);
      Event e = blank((f & b) ? EvType::SENSOR_FAULT : EvType::SENSOR_FAULT_CLEARED, s.zone, now_ms);
      e.kinds = hazardOf(s.kind);
      e.nsrcs = 1;
      e.srcs[0] = sensorIdCode(s);
      emit(e, nullptr);
    }
  }

  void controlRoles(uint32_t now_ms) {
    const uint64_t presses = hub_->takeControlPresses();
    for (uint8_t i = 0; i < hub_->count(); i++) {
      const SensorConfig& s = *hub_->config(i);
      if (!isControlRole(s.kind) || s.kind == (uint8_t)SensorKind::ARM_KEY) continue;   // ARM_KEY: IntrusionCore
      const uint8_t zmask = (s.zone == 0) ? 0x0F : zbit(s.zone);
      if (presses & (1ULL << i)) {
        if (s.kind == (uint8_t)SensorKind::ALARM_ACK) {
          ack(s.zone, nullptr, Origin::LOCAL_DI, false, now_ms);
        } else {
          const bool open = s.kind == (uint8_t)SensorKind::GAS_RESET;
          for (uint8_t a = 0; a < act_->count(); a++) {
            const ActuatorConfig& c = *act_->config(a);
            if (!isValve(c) || !(c.zone_mask & zmask)) continue;
            if (open && !isGasValve(c)) continue;
            actuatorSet(a, !open, open ? Origin::GAS_RESET : Origin::LOCAL_DI, now_ms);
          }
        }
      }
      if (s.kind == (uint8_t)SensorKind::ALARM_ACK) {
        const uint32_t held = hub_->heldMs(i, now_ms);
        if (held == 0) holdFired_[i] = false;
        else if (held >= SAFE_ACK_HOLD_MS && !holdFired_[i]) {
          holdFired_[i] = true;
          if (mode_ != SafeReason::NONE) ack(s.zone, nullptr, Origin::LOCAL_DI, true, now_ms);
        }
      }
    }
  }

  bool autoOn(uint8_t i, uint32_t now_ms) const {
    const ActuatorConfig& a = *act_->config(i);
    for (uint8_t z = 1; z <= MAX_ZONES; z++) {
      if (!(a.zone_mask & zbit(z))) continue;
      const ZoneRt& Z = zone_[z];
      if (a.kind == (uint8_t)ActKind::SIREN) {
        if (latched(z) && !Z.silenced) return true;
        if (Z.st == ZoneSt::TEST && (uint32_t)(now_ms - Z.testAt) < TEST_SIREN_MS) return true;
      } else if (a.kind == (uint8_t)ActKind::FAN) {
        if (latched(z) && !(Z.kinds & HZ_SMOKE) && (Z.kinds & HZ_GAS) && (a.aflags & AF_FAN_EXPROOF)) return true;
      }
    }
    return false;
  }
  bool forceOff(uint8_t i) const {
    const ActuatorConfig& a = *act_->config(i);
    if (a.kind != (uint8_t)ActKind::FAN) return false;
    for (uint8_t z = 1; z <= MAX_ZONES; z++) if ((a.zone_mask & zbit(z)) && latched(z) && (zone_[z].kinds & HZ_SMOKE)) return true;
    return false;
  }

  void driveSwitches(uint32_t now_ms) {
    for (uint8_t i = 0; i < act_->count(); i++) {
      if (isValve(*act_->config(i))) continue;
      const bool au = autoOn(i, now_ms);
      if (!au) userSuppress_[i] = false;
      const bool fo = forceOff(i);
      if (fo) manualOn_[i] = false;
      const bool on = !fo && ((au && !userSuppress_[i]) || manualOn_[i]);
      act_->commandSwitch(i, on, now_ms);
      if (act_->config(i)->kind == (uint8_t)ActKind::SIREN) act_->commandIntrusion(i, intrReq_ && !intrSuppress_[i], now_ms);
    }
  }

  // Kilitli/test bölgelerindeki vanalar her turda KAPALI tutulur (açma zaten reddedilir; burada yalnız güvence).
  void enforceLatchedValves(uint32_t now_ms) {
    if (!act_) return;
    for (uint8_t i = 0; i < act_->count(); i++) {
      const ActuatorConfig& a = *act_->config(i);
      if (!isValve(a) || act_->closedCmd(i)) continue;
      for (uint8_t z = 1; z <= MAX_ZONES; z++) {
        const bool hold = (latched(z) && valveMatches(a, z, zone_[z].kinds)) ||
                          (zone_[z].st == ZoneSt::TEST && (zone_[z].testValves & (1u << i)));
        if (hold) { act_->commandValve(i, true, now_ms); break; }
      }
    }
  }

  const SafetyConfig* cfg_;
  SensorHub* hub_;
  ActuatorCore* act_;
  EventOutbox* out_;
  SafeReason mode_;
  uint32_t bootAt_;
  uint32_t epoch_;
  bool policyOn_;
  bool cfgUsable_;
  bool latchDirty_;
  bool intrReq_;              // hırsız alarmının siren isteği (F2.B.4)
  uint64_t latchAssert_;
  uint64_t latchLevel_;
  uint64_t latchRecAssert_;   // kilit kaydından gelen maske (açılış güvenli maskesi hariç)
  ZoneRt zone_[MAX_ZONES + 1];
  bool manualOn_[MAX_ACTUATORS];
  bool userSuppress_[MAX_ACTUATORS];
  bool intrSuppress_[MAX_ACTUATORS];   // kullanıcı hırsız sirenini kapattı (alarm dönemi boyunca)
  bool holdFired_[MAX_SENSORS];
};

}  // namespace safety
