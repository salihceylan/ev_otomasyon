// safety/SafetyManager.cpp - Güvenlik katmanı bağlayıcısı (bkz. SafetyManager.h). Karar içermez; SafetyCore'u çağırır.
#include "safety/SafetyManager.h"
#include "safety/SafetyStore.h"
#include "safety/ValveGuard.h"
#include "ConfigManager.h"
#include <esp_system.h>

namespace safety {

// shutdownHandler / emergencyAllOff için: kilit kaydındaki güvenli seviyeler (yalnız KORUNACAK bitler; kapatma yönü).
static volatile uint8_t s_keepLocal = 0;
static volatile uint32_t s_keepExt = 0;

SafetyManager& SafetyManager::instance() {
  static SafetyManager m;
  return m;
}

SafetyManager::SafetyManager()
    : di_(nullptr), cfgMux_(nullptr), rejMux_(nullptr), viewMux_(nullptr), writeMux_(nullptr), sensorQ_(nullptr), actuatorMask_(0),
      sensorDiMask_(0), bootLevel_(0), safeMaskA_(0), safeMaskL_(0), relayGuard_(0), diHist_(0), diHistDirty_(false), bootAt_(0), bootCount_(0), bn_(0), lastSirenSave_(0), lastViewAt_(0), epoch_(0), viewSig_(0),
      rejSeq_(0), masksGen_(0), sirenSaved_(0), active_(false), localReady_(false), extOk_(false), extActuator_(false),
      posSaveForced_(false), cfgUsable_(false), scanBlocked_(false), safeMode_(false), latchedMask_(0), pendingState_(0), pendingOk_(0), pendingVia_(0),
      pendingCfg_(nullptr), lastRej_(Rej::OK) {
  cfg_.setDefaults();
  crashClear(crash_);
  lastRejId_[0] = '\0';
  memset(&view_, 0, sizeof(view_));
  memset(&scratch_, 0, sizeof(scratch_));
}

uint8_t SafetyManager::shutdownKeepLocal() { return s_keepLocal; }
uint32_t SafetyManager::shutdownKeepExt() { return s_keepExt; }

Origin SafetyManager::originOf(CmdSource s) {
  switch (s) {
    case CmdSource::DI:
    case CmdSource::CLI: return Origin::LOCAL_DI;     // duvar butonu / seri konsol: fiziksel erişim
    case CmdSource::SAFETY: return Origin::SAFETY;
    default: return Origin::REMOTE;                    // MQTT, LAN/Web, senaryo (RULE)
  }
}

void SafetyManager::begin(const digate::DiGate* gate, uint32_t now_ms) {
  if (!cfgMux_) cfgMux_ = xSemaphoreCreateMutex();
  if (!rejMux_) rejMux_ = xSemaphoreCreateMutex();
  if (!viewMux_) viewMux_ = xSemaphoreCreateMutex();
  if (!writeMux_) writeMux_ = xSemaphoreCreateMutex();
  if (!sensorQ_) sensorQ_ = xQueueCreate(16, sizeof(SensorReport));
  di_ = DiSensor(gate);
  bootAt_ = now_ms;

  bool present = false, crcOk = true;
  SafetyStore::loadConfig(cfg_, present, crcOk);
  static LatchRecord latch;                            // 164 B; yalnız açılışta
  const bool haveLatch = SafetyStore::loadLatch(latch);
  SafetyStore::reserveLatch();
  uint16_t posOpen = 0, posKnown = 0;
  SafetyStore::loadActPos(posOpen, posKnown);
  SafetyStore::loadSafeMask(safeMaskA_, safeMaskL_);
  SafetyStore::loadDiHist(diHist_);
  bootCount_ = SafetyStore::bumpBootCount();
  SafetyStore::loadCrash(crash_);
  const esp_reset_reason_t rr = esp_reset_reason();
  const bool unexpected = rr == ESP_RST_PANIC || rr == ESP_RST_INT_WDT || rr == ESP_RST_TASK_WDT || rr == ESP_RST_WDT ||
                          rr == ESP_RST_BROWNOUT;
  crashOnBoot(crash_, unexpected);
  if (unexpected) SafetyStore::saveCrash(crash_);
  bn_ = esp_random();

  // Ana yapılandırmayla çapraz doğrulama [B3]: uyuşmayan güvenlik yapılandırması KULLANILMAZ (güvenli kip, kilit maskesi).
  const CfgErr ve = validate(ConfigManager::instance().config, cfg_);
  const bool usable = crcOk && ve == CfgErr::OK;
  const SafeReason mode = decideBootMode(present, usable, haveLatch ? &latch : nullptr, cfg_, crash_);
  if (!usable) {
    if (ve != CfgErr::OK) printf("[GUVENLIK] Yapilandirma ana yapilandirmayla uyusmuyor (%s): tablolar kullanilmiyor.\r\n", cfgErrText(ve));
    cfg_.nSens = 0;
    cfg_.nAct = 0;
  }

  hub_.configure(cfg_.sens, cfg_.nSens, now_ms);
  act_.configure(cfg_.act, cfg_.nAct, posOpen, posKnown, now_ms);
  outbox_.begin(bn_);
  {
    EventOutboxRtos::Guard g(outbox_, portMAX_DELAY);
    core_.begin(&cfg_, &hub_, &act_, &outbox_.box(), haveLatch ? &latch : nullptr, mode, now_ms);
    if (present && crcOk && ve != CfgErr::OK) {
      Event e;
      memset(&e, 0, sizeof(e));
      e.type = (uint8_t)EvType::ACTUATOR_FAULT;
      char eid[EID_LEN];
      outbox_.box().push(e, eid);
    }
    // Yapılandırma kullanılamıyor: son geçerli yapılandırmanın açılış güvenli maskesi (kapalı vanalar + gaz vanaları) güvenli kipte
    // dayatılır; ana yapılandırmada panjur/darbe rölesi olan ya da var olmayan röleye dokunulmaz [EM-5].
    if (!usable) {
      ConfigManager::ConfigLock lk(ConfigManager::instance());
      const uint64_t a = bootMaskForSystem(ConfigManager::instance().config, safeMaskA_);
      core_.imposeBootMask(a, safeMaskL_ & a);
      // Ana yapılandırmada artık panjur/darbe ya da var olmayan röle olan bitler kalıcı maskeden de düşülür: Relay_Init bir sonraki
      // açılışta onları enerjilemez (yalnız bit SİLER; inceleme turu 2 FW2-1).
      if (a != safeMaskA_ && SafetyStore::saveSafeMask(a, safeMaskL_ & a)) {
        safeMaskA_ = a;
        safeMaskL_ &= a;
      }
    }
  }
  cfgUsable_ = usable;
  if (usable) mergeDiHist(diUseMask(cfg_));
  // Kilit sürüyorsa siren birikimi yeniden başlatmada sıfırlanmaz [O-8].
  if (haveLatch && latchAny(latch)) {
    const uint16_t s = SafetyStore::loadSirenS();
    sirenSaved_ = s;
    for (uint8_t i = 0; i < act_.count(); i++) {
      if (act_.config(i)->kind == (uint8_t)ActKind::SIREN) act_.setSirenRunMs(i, (uint32_t)s * 1000UL);
    }
  }

  uint64_t la = haveLatch ? latchAssert64(latch) : 0;
  uint64_t ll = haveLatch ? latchLevel64(latch) : 0;
  if (core_.safeMode()) core_.latchMasks(la, ll);           // güvenli kipte kilit + açılış güvenli maskesi
  recomputeMasks();
  bootLevel_ = applyLatchMask(::safety::bootLevelMask(cfg_.act, cfg_.nAct, haveLatch ? latchZoneMask(latch) : 0, posOpen, posKnown), la, ll);
  refreshKeep();
  persistSafeMask(now_ms);                                  // yapılandırma değiştiyse/silindiyse maske eşitlenir (Relay_Init bir sonraki açılışta)
  refreshView(now_ms, true);
  if (active_) {
    printf("[GUVENLIK] %u sensor, %u eylemci, kilit=0x%X, kip=%s, acilis=%lu, bn=%08lx\r\n", (unsigned)cfg_.nSens,
           (unsigned)cfg_.nAct, (unsigned)core_.latchedZoneMask(), mode == SafeReason::NONE ? "normal" : safeReasonText(mode),
           (unsigned long)bootCount_, (unsigned long)bn_);
  }
}

// Maskeler ve türetilmiş bayraklar (açılışta ve çalışırken yapılandırma değişince). Güvenli kipte kilit maskesindeki röleler de
// eylemci sayılır (ham komut yön kuralı ve toplu kapatmadan muafiyet).
void SafetyManager::recomputeMasks() {
  uint64_t la = 0, ll = 0;
  core_.latchMasks(la, ll);
  actuatorMask_ = act_.relayMask() | la;
  publishGuard();
  sensorDiMask_ = DiSensor::diMaskOf(cfg_.sens, cfg_.nSens) | act_.fbDiMask();
  extActuator_ = ((actuatorMask_ >> 8) != 0) || ((sensorDiMask_ >> 8) != 0);
  active_ = core_.active();
  latchedMask_ = core_.latchedZoneMask();
  safeMode_ = core_.safeMode();
  scanBlocked_ = extActuator_ || latchedMask_ != 0;
  masksGen_ = masksGen_ + 1;
}

// Kapanış/yeniden başlatmada korunacak güvenli seviye bitleri (shutdownHandler, emergencyAllOff): ValveGuard'ın tuttuğu KAPALI komutlu
// vanaların enerjili seviyeleri + güvenli kipte kilit/açılış maskesi. Yalnız kapatma yönü: çağıran gölgede zaten açık olan biti korur [EM-1].
void SafetyManager::refreshKeep() {
  uint64_t as = 0, lv = 0;
  holdMasks(as, lv);
  const uint64_t keep = lv & as;
  s_keepLocal = (uint8_t)(keep & 0xFF);
  s_keepExt = (uint32_t)((keep >> 8) & 0xFFFFFFFFu);
}

void SafetyManager::persistSafeMask(uint32_t now_ms) {
  if (!cfgUsable_) return;                                  // cfg_corrupt: son geçerli maske korunur [EM-5]
  uint16_t closed = 0;
  for (uint8_t i = 0; i < act_.count(); i++) if (act_.closedCmd(i)) closed = (uint16_t)(closed | (1u << i));
  uint64_t a = 0, l = 0;
  bootSafeMasks(cfg_.act, act_.count(), closed, a, l);
  if (a == safeMaskA_ && l == safeMaskL_) return;
  if (SafetyStore::saveSafeMask(a, l)) {
    safeMaskA_ = a;
    safeMaskL_ = l;
    publishGuard();
  } else {
    emitNvsFail(NVSK_ACT_POS, now_ms);                       // konum kalıcılığının parçası (sunucu anahtar listesi değişmez)
  }
}

// Ana yapılandırma doğrulamasının (web görevi / seri CLI) okuduğu koruma maskesi: NVS'teki açılış güvenli maskesi (Relay_Init bunu ana
// yapılandırmadan ÖNCE uygular; yazımı başarısız kaldıysa bayat bitleri de dahil) ve çekirdeğin kilit maskesi (güvenli kipte dayatılan
// açılış maskesi + kilit kaydı) [inceleme turu 2 FW2-1].
void SafetyManager::publishGuard() {
  uint64_t la = 0, ll = 0;
  core_.latchMasks(la, ll);
  const uint64_t g = safeMaskA_ | la;
  if (!cfgMux_ || xSemaphoreTake(cfgMux_, portMAX_DELAY) != pdTRUE) return;
  relayGuard_ = g;
  xSemaphoreGive(cfgMux_);
}

// Kalıcı DI kullanım geçmişi (isLoosening, FW2-2): yalnız büyür. Yazılamazsa RAM'deki değer yine büyür (bu oturumda kural işler) ve bir
// sonraki uygulamada yeniden denenir; açılışta uygulanan yapılandırmanın DI'leri de yeniden birleştirilir.
void SafetyManager::mergeDiHist(uint64_t used) {
  const uint64_t n = diHist_ | used;
  if (n != diHist_) {
    if (!cfgMux_ || xSemaphoreTake(cfgMux_, portMAX_DELAY) != pdTRUE) return;
    diHist_ = n;
    xSemaphoreGive(cfgMux_);
    diHistDirty_ = true;
  }
  if (diHistDirty_ && SafetyStore::saveDiHist(n)) diHistDirty_ = false;
}

void SafetyManager::refreshView(uint32_t now_ms, bool force) {
  buildView(cfg_, hub_, act_, core_, now_ms, scratch_);
  const uint32_t sig = viewSignature(scratch_);
  if (!force && sig == viewSig_ && (uint32_t)(now_ms - lastViewAt_) < 1000UL) return;
  if (!viewMux_ || xSemaphoreTake(viewMux_, pdMS_TO_TICKS(5)) != pdTRUE) return;   // bir sonraki turda yeniden denenir
  memcpy(&view_, &scratch_, sizeof(view_));
  xSemaphoreGive(viewMux_);
  viewSig_ = sig;
  lastViewAt_ = now_ms;
}

bool SafetyManager::copyView(SafetyView& out) {
  if (!viewMux_ || xSemaphoreTake(viewMux_, pdMS_TO_TICKS(20)) != pdTRUE) return false;
  memcpy(&out, &view_, sizeof(out));
  xSemaphoreGive(viewMux_);
  return true;
}

void SafetyManager::stateMeta(StateMeta& m) {
  memset(&m, 0, sizeof(m));
  m.boot = bootCount_;
  m.bn = bn_;
  Rej r = Rej::OK;
  lastReject(m.rejId, sizeof(m.rejId), r);
  m.rej = (uint8_t)r;
}

void SafetyManager::tick(uint32_t now_ms, uint32_t epoch) {
  if (!active_) return;
  epoch_ = epoch;
  SensorReport r;
  while (sensorQ_ && xQueueReceive(sensorQ_, &r, 0) == pdTRUE) bridge_.report(r);
  di_.setLocalReady(localReady_);
  di_.setExtOk(extOk_);
  {
    // Kilit altında ağ/bekleme YOK (MqttTask da yalnız kopyalar): sınırlı süre, öncelik kalıtımlı mutex.
    EventOutboxRtos::Guard g(outbox_, portMAX_DELAY);
    core_.tick(now_ms, epoch, &di_, &bridge_);
  }
  active_ = core_.active();
  latchedMask_ = core_.latchedZoneMask();
  safeMode_ = core_.safeMode();
  scanBlocked_ = extActuator_ || latchedMask_ != 0;
  refreshView(now_ms, false);
}

void SafetyManager::holdMasks(uint64_t& assertMask, uint64_t& levelMask) const {
  uint16_t closed = 0;
  for (uint8_t i = 0; i < act_.count(); i++) if (act_.closedCmd(i)) closed = (uint16_t)(closed | (1u << i));
  uint64_t la = 0, ll = 0;
  core_.latchMasks(la, ll);
  safeHoldMasks(cfg_.act, act_.count(), closed, la, ll, assertMask, levelMask);
}

void SafetyManager::emitNvsFail(uint8_t key, uint32_t now_ms) {
  printf("[GUVENLIK] UYARI: NVS yazimi basarisiz (anahtar %u).\r\n", (unsigned)key);
  Event e;
  memset(&e, 0, sizeof(e));
  e.type = (uint8_t)EvType::NVS_FAIL;
  e.sub = key;
  e.atUp = (uint32_t)(now_ms - bootAt_) / 1000UL;
  EventOutboxRtos::Guard g(outbox_, portMAX_DELAY);
  char eid[EID_LEN];
  outbox_.box().push(e, eid);
}

void SafetyManager::emitCfgConflict(uint32_t rev, uint32_t crc) {
  Event e;
  memset(&e, 0, sizeof(e));
  e.type = (uint8_t)EvType::CFG_CONFLICT;
  e.rev = rev;
  e.crc = crc;
  e.atUp = (uint32_t)(millis() - bootAt_) / 1000UL;
  EventOutboxRtos::Guard g(outbox_, pdMS_TO_TICKS(200));
  if (!g.ok()) return;
  char eid[EID_LEN];
  outbox_.box().push(e, eid);
}

void SafetyManager::persist(uint32_t now_ms) {
  if (!active_) return;
  if (core_.takeLatchDirty()) {
    static LatchRecord rec;
    core_.buildLatch(rec);
    if (!SafetyStore::saveLatch(rec)) emitNvsFail(NVSK_LATCH, now_ms);
    if (!latchAny(rec) && sirenSaved_ != 0) {
      if (SafetyStore::saveSirenS(0)) sirenSaved_ = 0;
    }
  }
  refreshKeep();                                            // her tur: kapanış kancası güncel kapalı vanaları korur [EM-1]
  const bool posDirty = act_.takePosDirty() || posSaveForced_;
  posSaveForced_ = false;
  if (posDirty && !SafetyStore::saveActPos(act_.posOpenBits(), act_.posKnownBits())) emitNvsFail(NVSK_ACT_POS, now_ms);
  if (posDirty) persistSafeMask(now_ms);
  // Siren birikimi: kilit sürerken 30 sn'de bir (yıpranma) [O-8].
  if (core_.latchedZoneMask() != 0 && (uint32_t)(now_ms - lastSirenSave_) >= 30000UL) {
    lastSirenSave_ = now_ms;
    uint32_t maxMs = 0;
    for (uint8_t i = 0; i < act_.count(); i++) if (act_.sirenRunMs(i) > maxMs) maxMs = act_.sirenRunMs(i);
    const uint32_t s32 = maxMs / 1000UL;
    const uint16_t s = (uint16_t)(s32 > 0xFFFF ? 0xFFFF : s32);
    if (s != sirenSaved_) {
      if (SafetyStore::saveSirenS(s)) sirenSaved_ = s;
      else emitNvsFail(NVSK_SIREN, now_ms);
    }
  }
  if (crashStableTick(crash_, (uint32_t)(now_ms - bootAt_)) && !SafetyStore::saveCrash(crash_)) emitNvsFail(NVSK_CRASH, now_ms);
}

RawDecision SafetyManager::rawRelay(uint8_t relay1, bool level, CmdSource src, uint32_t now_ms) {
  RawDecision d;
  {
    EventOutboxRtos::Guard g(outbox_, portMAX_DELAY);
    d = core_.rawRelay(relay1, level, originOf(src), now_ms);
  }
  if (d == RawDecision::NOT_ACTUATOR && (actuatorMask_ & relayBit(relay1))) {
    // Güvenli kipte yalnız kilit maskesinde olan röle: kilit seviyesinden başka yöne izin yok.
    uint64_t a = 0, l = 0;
    core_.outputMasks(a, l);
    d = (level == ((l & relayBit(relay1)) != 0)) ? RawDecision::NOOP : RawDecision::REJECT;
  }
  active_ = core_.active();
  return d;
}

RawDecision SafetyManager::rawRelayCheck(uint8_t relay1, bool level) {
  if (!cfgMux_ || xSemaphoreTake(cfgMux_, pdMS_TO_TICKS(50)) != pdTRUE) return RawDecision::REJECT;   // emin değilse reddet
  RawDecision d = rawCommand(cfg_.act, cfg_.nAct, relay1, level).d;
  xSemaphoreGive(cfgMux_);
  if (d == RawDecision::NOT_ACTUATOR && (actuatorMask_ & relayBit(relay1))) d = RawDecision::REJECT;
  return d;
}

bool SafetyManager::isActuatorRelay(uint8_t relay1) {
  if (relayBit(relay1) == 0) return false;
  if (!cfgMux_ || xSemaphoreTake(cfgMux_, pdMS_TO_TICKS(50)) != pdTRUE) return false;
  const bool a = rawCommand(cfg_.act, cfg_.nAct, relay1, false).act >= 0;
  xSemaphoreGive(cfgMux_);
  return a || (actuatorMask_ & relayBit(relay1)) != 0;
}

int8_t SafetyManager::actuatorOfRelay(uint8_t relay1) const {
  return rawCommand(cfg_.act, cfg_.nAct, relay1, false).act;
}

bool SafetyManager::actuatorEngaged(uint8_t act) const {
  if (act >= act_.count()) return false;
  if (isValve(*act_.config(act))) return !act_.closedCmd(act);
  return act_.on(act);
}

Rej SafetyManager::handleCommand(const DeviceCommand& cmd, uint32_t now_ms) {
  const Origin o = originOf(cmd.source);
  Rej r = Rej::UNSUPPORTED;
  {
    EventOutboxRtos::Guard g(outbox_, portMAX_DELAY);
    switch (cmd.type) {
      case CmdType::ACTUATOR_SET: {
        if (cmd.index < 1 || cmd.index > act_.count()) {
          r = Rej::UNKNOWN_ACTUATOR;
          break;
        }
        const uint8_t i = (uint8_t)(cmd.index - 1);
        bool safe;
        if (cmd.value & 0x30) {                        // MQTT/LAN "to": tür denetimli
          const bool wantValve = (cmd.value & 0x30) == 0x10;
          if (wantValve != isValve(*act_.config(i))) {
            r = Rej::BAD_STATE;
            break;
          }
          safe = (cmd.value & 0x01) == 0;
        } else {
          safe = cmd.value == 0;
        }
        r = core_.actuatorSet(i, safe, o, now_ms);
        break;
      }
      case CmdType::ALARM_ACK:
        r = core_.ack(cmd.index, cmd.aid[0] ? cmd.aid : nullptr, o, cmd.value != 0, now_ms);
        break;
      case CmdType::ALARM_TEST:
        r = core_.test(cmd.index, now_ms);
        break;
      default:
        r = Rej::UNSUPPORTED;
        break;
    }
  }
  active_ = core_.active();
  latchedMask_ = core_.latchedZoneMask();
  safeMode_ = core_.safeMode();
  if (r != Rej::OK) noteReject(cmd.id, r);
  return r;
}

void SafetyManager::noteReject(const char* id, Rej r) {
  if (!rejMux_ || xSemaphoreTake(rejMux_, pdMS_TO_TICKS(20)) != pdTRUE) return;
  strncpy(lastRejId_, id ? id : "", sizeof(lastRejId_) - 1);
  lastRejId_[sizeof(lastRejId_) - 1] = '\0';
  lastRej_ = r;
  rejSeq_ = rejSeq_ + 1;
  xSemaphoreGive(rejMux_);
}

void SafetyManager::lastReject(char* id, size_t idCap, Rej& r) {
  r = Rej::OK;
  if (idCap) id[0] = '\0';
  if (!rejMux_ || xSemaphoreTake(rejMux_, pdMS_TO_TICKS(20)) != pdTRUE) return;
  if (idCap) { strncpy(id, lastRejId_, idCap - 1); id[idCap - 1] = '\0'; }
  r = lastRej_;
  xSemaphoreGive(rejMux_);
}

bool SafetyManager::postBridgeReport(const SensorReport& r) {
  return sensorQ_ && xQueueSend(sensorQ_, &r, 0) == pdTRUE;
}

bool SafetyManager::copyConfig(SafetyConfig& out, uint64_t* relayGuard, uint64_t* diHist) {
  if (!cfgMux_ || xSemaphoreTake(cfgMux_, pdMS_TO_TICKS(50)) != pdTRUE) return false;
  out = cfg_;
  if (relayGuard) *relayGuard = relayGuard_;
  if (diHist) *diHist = diHist_;
  xSemaphoreGive(cfgMux_);
  return true;
}

// ---------------------------------------------------------------------------------------------
// Yapılandırma yazımı (WP-F4/F5, spec §4.1-4.2)
// ---------------------------------------------------------------------------------------------
CfgOutcome SafetyManager::finishEdit(const CfgOutcome& o, SafetyConfig* a, SafetyConfig* b) {
  free(a);
  free(b);
  xSemaphoreGive(writeMux_);
  return o;
}

CfgOutcome SafetyManager::submitEdit(const CfgEdit& e, bool hasBase, uint32_t baseRev, uint8_t via, bool inLoop, uint64_t curLevels) {
  CfgOutcome o;
  o.r = CfgResult::BUSY;
  o.err = CfgErr::OK;
  o.rev = 0;
  o.crc = 0;
  if (!writeMux_ || xSemaphoreTake(writeMux_, pdMS_TO_TICKS(2000)) != pdTRUE) return o;
  // İki kopya (~2,5 KB x 2) yığında ve kalıcı RAM'de tutulmaz: iş süresince öbekten (writeMux_ altında tek yazıcı).
  SafetyConfig* curP = (SafetyConfig*)malloc(sizeof(SafetyConfig));
  SafetyConfig* nextP = (SafetyConfig*)malloc(sizeof(SafetyConfig));
  uint64_t diHist = 0;
  if (!curP || !nextP || !copyConfig(*curP, nullptr, &diHist)) {
    free(curP);
    free(nextP);
    xSemaphoreGive(writeMux_);
    return o;
  }
  SafetyConfig& cur = *curP;
  SafetyConfig& next = *nextP;
  o.rev = cur.rev;
  o.crc = configCrc(cur);
  if (hasBase && baseRev != cur.rev) {                 // iyimser eşzamanlılık: pano kazanır (§4.2)
    o.r = CfgResult::CONFLICT;
    if (via == VIA_CLOUD) emitCfgConflict(cur.rev, o.crc);
    return finishEdit(o, curP, nextP);
  }
  int8_t removed = -1;
  CfgErr err = applyEdit(cur, e, next, removed);
  if (err == CfgErr::OK) {
    ConfigManager::ConfigLock lk(ConfigManager::instance());
    err = validate(ConfigManager::instance().config, next);
  }
  if (err != CfgErr::OK) {
    o.r = CfgResult::INVALID;
    o.err = err;
    return finishEdit(o, curP, nextP);
  }
  if (touchesLockedZones(cur, next, latchedMask_)) {   // alarm sırasında kilitli bölgeye dokunan değişiklik reddedilir [O-10]
    o.r = CfgResult::LATCHED;
    return finishEdit(o, curP, nextP);
  }
  if ((via == VIA_LAN || via == VIA_LOCAL_WEB) && isLoosening(cur, next, diHist)) {   // karar 7.2b-7; DI geçmişi [FW2-2]
    o.r = CfgResult::LOOSEN;
    return finishEdit(o, curP, nextP);
  }
  next.rev = cur.rev + 1;
  bool touched = false;
  if (!SafetyStore::saveConfig(next, &touched)) {
    emitNvsFail(NVSK_CFG, millis());
    if (touched) SafetyStore::saveConfig(cur, nullptr, false);   // yarım yazım: eski yapılandırma PAY DENETİMSİZ geri yazılır [FW2-3]; olmazsa "ver" geçersiz kalır
                                                           // ve açılış cfg_corrupt güvenli kipine düşer (karışık tablo kullanılmaz) [RV-4]
    o.r = CfgResult::STORAGE;
    return finishEdit(o, curP, nextP);
  }
  bool applied = false;
  if (inLoop) {
    applied = applyConfigOnLoop(next, via, curLevels, millis());
  } else {
    pendingCfg_ = &next;
    pendingVia_ = via;
    pendingOk_ = 0;
    __sync_synchronize();
    pendingState_ = 1;
    const uint32_t t0 = millis();
    while (pendingState_ != 2) {
      if (pendingState_ == 1 && (uint32_t)(millis() - t0) > 1500UL) {
        if (__sync_bool_compare_and_swap(&pendingState_, (uint8_t)1, (uint8_t)0)) break;   // loopTask almadı
      }
      vTaskDelay(pdMS_TO_TICKS(5));
    }
    applied = pendingState_ == 2 && pendingOk_ != 0;
    pendingState_ = 0;
    pendingCfg_ = nullptr;
  }
  if (!applied) {
    SafetyStore::saveConfig(cur, nullptr, false);      // uygulanamadı: NVS eski yapılandırmaya döner (pay denetimsiz) [FW2-3]
    o.r = latchedMask_ ? CfgResult::LATCHED : CfgResult::BUSY;
    return finishEdit(o, curP, nextP);
  }
  o.r = CfgResult::OK;
  o.rev = next.rev;
  o.crc = configCrc(next);
  return finishEdit(o, curP, nextP);
}

void SafetyManager::serviceConfig(uint32_t now_ms, uint64_t curLevels) {
  if (pendingState_ != 1) return;
  if (!__sync_bool_compare_and_swap(&pendingState_, (uint8_t)1, (uint8_t)3)) return;   // yazıcı vazgeçti
  const bool ok = pendingCfg_ && applyConfigOnLoop(*pendingCfg_, pendingVia_, curLevels, now_ms);
  pendingOk_ = ok ? 1 : 0;
  __sync_synchronize();
  pendingState_ = 2;
}

// loopTask: yeni yapılandırma RAM'e alınır, çekirdekler yeniden kurulur; bölge durumları, kilit ve aid'ler korunur. Eylemcilerin çalışma
// durumu (konum, geri bildirim arızası/zamanlayıcısı, darbe, siren bütçesi, elle açık, kullanıcı susturması) kimliğe göre taşınır; yeni su
// vanasında o anki röle seviyesi benimsenir (yapılandırma vanayı kendiliğinden açıp kapatmaz, sireni yeniden çaldırmaz) [EM-2/EM-3].
bool SafetyManager::applyConfigOnLoop(const SafetyConfig& next, uint8_t via, uint64_t curLevels, uint32_t now_ms) {
  if (touchesLockedZones(cfg_, next, core_.latchedZoneMask())) return false;
  uint16_t open = 0, known = 0;
  remapActPos(cfg_, act_.posOpenBits(), act_.posKnownBits(), next, curLevels, open, known);
  int8_t fromOld[MAX_ACTUATORS];
  actuatorIdentityMap(cfg_, next, fromOld);
  if (!cfgMux_ || xSemaphoreTake(cfgMux_, pdMS_TO_TICKS(200)) != pdTRUE) return false;
  cfg_ = next;
  xSemaphoreGive(cfgMux_);
  {
    EventOutboxRtos::Guard g(outbox_, portMAX_DELAY);
    hub_.configure(cfg_.sens, cfg_.nSens, now_ms);
    act_.reconfigure(cfg_.act, cfg_.nAct, open, known, fromOld, now_ms);
    core_.reconfigured(via, now_ms, fromOld);
    if (core_.safeMode()) {
      // Çıkış kullanılabilirliği yalnız kilit kaydının maskesiyle: açılış güvenli maskesindeki silinmiş vana çıkışı kilitlemez [EM-5].
      core_.setConfigUsable(cfg_.nAct > 0 && (core_.latchRecordAssert() & ~act_.relayMask()) == 0);
    }
  }
  cfgUsable_ = true;                                        // validate geçmiş yapılandırma: açılış güvenli maskesi yeniden yazılabilir
  mergeDiHist(diUseMask(cfg_));                             // DI kullanım geçmişi [FW2-2]
  posSaveForced_ = true;
  recomputeMasks();
  refreshKeep();
  persistSafeMask(now_ms);
  refreshView(now_ms, true);
  printf("[GUVENLIK] Yapilandirma uygulandi (rev %lu): %u sensor, %u eylemci.\r\n", (unsigned long)cfg_.rev, (unsigned)cfg_.nSens,
         (unsigned)cfg_.nAct);
  return true;
}

}  // namespace safety
