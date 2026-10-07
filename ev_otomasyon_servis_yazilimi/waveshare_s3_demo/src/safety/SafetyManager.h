#pragma once
// ============================================================================
// safety/SafetyManager.h - Güvenlik katmanının bağlayıcısı (loopTask, Core 1). BAĞLAYICI: karar SafetyCore'dadır (saf).
//
// Tasarım §2.2-2.3, §4.1-4.2, §5.1.6:
//  * begin(): NVS'ten yapılandırma + kilit kaydı + act_pos + açılış sayacı + çökme kaydı; açılış nonce'u (bn = esp_random());
//    güvenli kip kararı (decideBootMode); çekirdekler kurulur. SmartAutomation::begin içinde, açılış çıkış bloğundan ÖNCE çağrılır.
//  * tick(): SmartAutomation::loop() içinde checkDigitalInputs ile stepOutputs arasında; karar aynı turda sürücüye ulaşır.
//    Çıktı maskeleri SmartAutomation::applySafetyOutput ile _want'a HER TURDA yeniden dayatılır (kuyruk kullanılmaz).
//  * persist(): çıktılar uygulandıktan SONRA (kilit kaydı eylemi beklemez, §5.1.6 madde 9): kilit / act_pos / siren_s /
//    çökme kaydı yazımları; yazılamazsa nvs_fail olayı.
//  * Durum görünümü (SafetyView, WP-F4): loopTask her turda üretir; içerik değiştiyse ya da 1 sn geçtiyse kendi mutex'i altında
//    yayınlanır. MqttTask/WebTask yalnız KOPYA alır (copyView) ve JSON'u kilit DIŞINDA üretir [B13].
//  * Yapılandırma yazımı (submitEdit, WP-F4/F5): herhangi bir görevden; tek yazıcı kilidi altında yama -> validate(system, safety) ->
//    kilitli bölge kuralı -> (LAN ise) gevşetme yasağı -> rev++ -> NVS -> loopTask'ta uygulama (serviceConfig). Uygulama kilitli bölgeye
//    değdiği anlaşılırsa NVS eski yapılandırmaya geri alınır.
//  * Yapılandırılmamış panoda (sensör ve eylemci yok, kilit yok, güvenli kip yok) active() false: bütün kancalar O(1) çıkar,
//    maskeler 0'dır ve lamba/panjur yolu bit bit bugünkü gibidir (§2.9).
//  * Faz 2 (F2.B): hırsız alarmı çekirdeği (IntrusionCore) SafetyCore'dan SONRA aynı turda; siren isteği SafetyCore::setIntrusionSiren ile
//    VEYA'lanır, buzzer deseni Buzzer_SetPattern ile (tehlike alarmı önceliklidir). Kip/alarm belleği NVS "ahbu_latch/arm". Kapı/pencere
//    kenarları ContactBus'a (iklim/senaryo tüketicileri için; olay kutusuna yazılmaz).
// Görevler arası: yapılandırma kopyası SafetyCfgLock (mutex) arkasındadır; yazıcı yalnız loopTask. shutdownKeep*(), scanBlocked() ve
// latchedMask() herhangi bir bağlamdan okunabilir (volatile, 32 bit ve altı).
// ============================================================================
#include <Arduino.h>
#include <freertos/FreeRTOS.h>
#include <freertos/queue.h>
#include <freertos/semphr.h>
#include "DeviceCommand.h"
#include "DiGate.h"
#include "safety/SafetyConfig.h"
#include "safety/SafetyFsm.h"
#include "safety/IntrusionFsm.h"
#include "sensors/ContactBus.h"
#include "safety/SafetyView.h"
#include "safety/SafetyCfgEdit.h"
#include "sensors/SensorHub.h"
#include "sensors/DiSensor.h"
#include "sensors/BridgeSensor.h"
#include "actuators/ActuatorMap.h"
#include "events/EventOutboxRtos.h"

namespace safety {

// ACTUATOR_SET komutunun value kodlaması (DeviceCommand.value): 0 güvenli yön / 1 açma (yerel yollar: DI, CLI), MQTT/LAN "to" alanı türü
// de taşır: vana closed/open = 0x10/0x11, anahtar off/on = 0x20/0x21 (tür uyuşmazsa bad_state).
enum : int32_t { ACT_TO_CLOSED = 0x10, ACT_TO_OPEN = 0x11, ACT_TO_OFF = 0x20, ACT_TO_ON = 0x21 };

// GAS_LOCAL: bulut yaması gaz vanasını uzaktan açılabilir kılardı (isGasRelease); ARMED: kurulu kipte bulut yaması hırsız alarmını
// zayıflatırdı (isIntrusionLoosening). İkisi yalnız VIA_CLOUD'da (Faz 2 incelemesi G-1).
enum class CfgResult : uint8_t { OK = 0, CONFLICT, INVALID, LATCHED, LOOSEN, STORAGE, BUSY, GAS_LOCAL, ARMED };

struct CfgOutcome {
  CfgResult r;
  CfgErr err;        // INVALID ise ayrıntı
  uint32_t rev;      // sonuçtaki (ya da güncel) rev
  uint32_t crc;
};

class SafetyManager {
public:
  static SafetyManager& instance();

  void begin(const digate::DiGate* gate, uint32_t now_ms);
  bool active() const { return active_; }

  // ---- SmartAutomation kancaları (loopTask) ----
  uint64_t actuatorMask() const { return actuatorMask_; }     // eylemci röleleri (bit = röle-1)
  uint64_t sensorDiMask() const { return sensorDiMask_; }     // sensör + kontrol rolü + geri bildirim DI'leri (bit = DI-1)
  uint64_t bootLevelMask() const { return bootLevel_; }       // açılış seviyeleri (yapılandırma + kilit maskesi)
  uint32_t masksGen() const { return masksGen_; }             // maskeler (çalışırken yapılandırma değişimi) değişince artar
  void setDiHealth(bool localReady, bool extOk) { localReady_ = localReady; extOk_ = extOk; }
  void tick(uint32_t now_ms, uint32_t epoch = 0);
  void outputs(uint64_t& assertMask, uint64_t& levelMask) const { core_.outputMasks(assertMask, levelMask); }
  bool buzzer() const { return core_.buzzer(); }
  // ValveGuard (spec §5.1.5): KAPALI komutlu vanaların güvenli seviyeleri + güvenli kipte kilit maskesi (loopTask).
  void holdMasks(uint64_t& assertMask, uint64_t& levelMask) const;
  void persist(uint32_t now_ms);
  bool configPending() const { return pendingState_ == 1; }
  // Bekleyen yapılandırma işini uygular (yalnız loopTask). curLevels: o anki istenen röle seviyeleri (bit = röle-1).
  void serviceConfig(uint32_t now_ms, uint64_t curLevels);

  // Ham röle komutu yön kuralı (loopTask; durum değiştirir: SAFE ise "kullanıcı kapattı").
  RawDecision rawRelay(uint8_t relay1, bool level, CmdSource src, uint32_t now_ms);
  int8_t actuatorOfRelay(uint8_t relay1) const;
  bool actuatorEngaged(uint8_t act) const;                     // vana açık / anahtar açık
  Rej handleCommand(const DeviceCommand& cmd, uint32_t now_ms);
  void noteReject(const char* id, Rej r);
  bool latched() const { return core_.latchedZoneMask() != 0; }
  const ContactBus& contacts() const { return contacts_; }     // iklim/senaryo tüketicileri (loopTask)

  // ---- herhangi bir görev ----
  RawDecision rawRelayCheck(uint8_t relay1, bool level);       // durum değiştirmez (WebTask: ham RS485)
  // MqttTask: uid'siz düz röle komutu bu panonun eylemci rölesine mi geliyor? (ev konusu bütün panolara gider; inceleme turu RV-2).
  // Kilit alınamazsa false (komut bugünkü yoldan loopTask'ın yön kuralına gider).
  bool isActuatorRelay(uint8_t relay1);
  bool hasExtActuator() const { return extActuator_; }
  bool scanBlocked() const { return scanBlocked_; }
  uint8_t latchedMask() const { return latchedMask_; }        // kilitli/arızalı bölgeler (bit z-1)
  bool safeModeActive() const { return safeMode_; }
  // Yeniden başlatma/kapanmada korunacak yerel güvenli bitler: KAPALI komutlu enerjiyle-kapanan vanalar + güvenli kipte kilit/açılış maskesi
  // (inceleme turu EM-1; eskiden yalnız kilit kaydı).
  static uint8_t shutdownKeepLocal();
  static uint32_t shutdownKeepExt();                           // ... ek modül (röle 9..40 -> bit 0..31)
  bool postBridgeReport(const SensorReport& r);                // köprü sürücüsü (s_sensorQ)
  // SafetyCfgLock altında kopya. relayGuard: açılış güvenli maskesi + kilit maskesi (ana yapılandırma doğrulaması, validateSystemChange);
  // diHist: kalıcı DI kullanım geçmişi (isLoosening) [inceleme turu 2 FW2-1/FW2-2].
  bool copyConfig(SafetyConfig& out, uint64_t* relayGuard = nullptr, uint64_t* diHist = nullptr);
  bool copyView(SafetyView& out);                              // durum görünümü kopyası (kilit altında JSON üretilmez)
  uint32_t viewSig() const { return viewSig_; }
  uint32_t rejSeq() const { return rejSeq_; }                  // her ret kaydında artar (yayın tetiği)
  void stateMeta(StateMeta& m);                                // boot, bn, last_rej (saat alanlarını çağıran doldurur)
  // Tek öğeli yapılandırma yaması (§4.1). via: VIA_CLI / VIA_LAN / VIA_CLOUD / VIA_LOCAL_WEB. inLoop: çağıran loopTask (CLI) ise iş
  // satır içi uygulanır (curLevels gerekir); aksi halde loopTask'a postalanır ve en çok ~1,5 sn beklenir.
  CfgOutcome submitEdit(const CfgEdit& e, bool hasBase, uint32_t baseRev, uint8_t via, bool inLoop = false, uint64_t curLevels = 0);
  EventOutboxRtos& outbox() { return outbox_; }
  uint32_t bootCount() const { return bootCount_; }
  uint32_t bootNonce() const { return bn_; }
  void lastReject(char* id, size_t idCap, Rej& r);

private:
  SafetyManager();
  static Origin originOf(CmdSource s);
  static uint8_t viaOf(CmdSource s);
  bool intrusionUsable() const;            // güvenli kipte sensör tablosu kullanılamıyorsa (cfg_corrupt / latch_orphan) false
  void emitNvsFail(uint8_t key, uint32_t now_ms);
  void emitCfgConflict(uint32_t rev, uint32_t crc);
  void recomputeMasks();
  void refreshKeep();             // shutdownKeep* (kapalı vanalar + güvenli kip maskesi)
  void persistSafeMask(uint32_t now_ms);   // açılış güvenli maskesi değiştiyse NVS "safe_msk" (yalnız yapılandırma kullanılabilirken)
  void publishGuard();                     // relayGuard_ = safe_msk | kilit maskesi (cfgMux_ altında; web görevi okur)
  void mergeDiHist(uint64_t used);         // DI kullanım geçmişi yalnız büyür; değiştiyse NVS "di_hist"
  void refreshView(uint32_t now_ms, bool force);
  bool applyConfigOnLoop(const SafetyConfig& next, uint8_t via, uint64_t curLevels, uint32_t now_ms);
  CfgOutcome finishEdit(const CfgOutcome& o, SafetyConfig* a, SafetyConfig* b);   // kopyaları bırakır, yazıcı kilidini verir

  SafetyConfig cfg_;
  SensorHub hub_;
  ActuatorCore act_;
  SafetyCore core_;
  IntrusionCore intr_;
  ContactBus contacts_;
  EventOutboxRtos outbox_;
  BridgeSensor bridge_;
  DiSensor di_;
  CrashLog crash_;
  SafetyView view_;               // yayınlanan görünüm (viewMux_)
  SafetyView scratch_;            // loopTask çalışma kopyası
  SemaphoreHandle_t cfgMux_;      // SafetyCfgLock
  SemaphoreHandle_t rejMux_;
  SemaphoreHandle_t viewMux_;
  SemaphoreHandle_t writeMux_;    // yapılandırma yazıcısı (submitEdit)
  QueueHandle_t sensorQ_;         // s_sensorQ (derinlik 16)
  uint64_t actuatorMask_;
  uint64_t sensorDiMask_;
  uint64_t bootLevel_;
  uint64_t safeMaskA_;            // NVS'teki açılış güvenli maskesi (son yazılan/okunan)
  uint64_t safeMaskL_;
  uint64_t relayGuard_;           // safeMaskA_ | çekirdeğin kilit maskesi (cfgMux_ altında yazılır/okunur) [FW2-1]
  uint64_t diHist_;               // kalıcı DI kullanım geçmişi (NVS "ahbu_latch/di_hist") [FW2-2]
  bool diHistDirty_;              // diHist_ NVS'e henüz yazılamadı
  uint32_t bootAt_;
  uint32_t bootCount_;
  uint32_t bn_;
  uint32_t lastSirenSave_;
  uint32_t lastViewAt_;
  uint32_t epoch_;
  volatile uint32_t viewSig_;
  volatile uint32_t rejSeq_;
  volatile uint32_t masksGen_;
  uint16_t sirenSaved_;
  bool active_;
  bool localReady_;
  bool extOk_;
  bool extActuator_;
  bool posSaveForced_;
  bool cfgUsable_;                // yapılandırma kullanılabilir (cfg_corrupt değil): açılış güvenli maskesi yalnız o zaman yazılır
  volatile bool scanBlocked_;
  volatile bool safeMode_;
  volatile uint8_t latchedMask_;
  // loopTask'a postalanan yapılandırma işi: 0 boş, 1 bekliyor, 3 uygulanıyor, 2 bitti
  volatile uint8_t pendingState_;
  volatile uint8_t pendingOk_;
  uint8_t pendingVia_;
  const SafetyConfig* pendingCfg_;
  char lastRejId_[25];
  Rej lastRej_;
};

}  // namespace safety
