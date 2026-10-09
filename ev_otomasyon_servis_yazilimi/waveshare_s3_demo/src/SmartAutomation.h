#pragma once
// ============================================================================
// SmartAutomation - röle / panjur / DI / RS485 harici modül yöneticisi (Core 1).
//
// MİMARİ (docs/CONTRACTS.md §4):
//  * Röle ve panjur durumunu YALNIZCA SmartAutomation::loop() (Core 1, Arduino loopTask) değiştirir.
//    MQTT (Core 0), Web, CLI ve zamanlayıcılar komutu postDeviceCommand() ile kuyruğa yazar.
//    DI (duvar butonu) olayları aynı yürütücüye (executeCommand) satır içi girer ve ASLA kuyruk
//    doluluğu yüzünden kaybolmaz.
//  * Panjur durum makinesi saf ShutterFsm sınıfıdır (src/ShutterFsm.h, PC'de test edilir);
//    burada yalnızca ince bir sarmalayıcıdır: komutları FSM'e iletir, FSM çıkışını (outMask)
//    röle sürücüsüne uygular, sürücü geri bildirimini (röle KAPALI teyidi) FSM'e verir.
//  * Fiziksel çıkış katmanı: yerel 8 röle TCA9554 gölge kayıt + InterlockGuard (WS_TCA9554PWR),
//    harici RS485 röleleri tek mutex'li rs485Transaction() hattı + aynı InterlockGuard kuralı.
//    "Eşi KAPALI doğrulanmadan panjur rölesi AÇILMAZ."
//  * Bağımsız motor süre aşımı emniyeti: ayrı görev, ana döngü kilitlense bile panjur rölesini keser.
//  * Durum okuma: getSnapshot()/getShutterSnapshot() mutex altında KOPYA döndürür (iş parçacığı güvenli).
// ============================================================================
#include <Arduino.h>
#include <freertos/FreeRTOS.h>
#include <freertos/queue.h>
#include <freertos/semphr.h>
#include <freertos/task.h>
#include "ConfigManager.h"
#include "DeviceCommand.h"
#include "ShutterFsm.h"
#include "RelayRules.h"
#include "DiGate.h"

struct ShutterState {
  bool is_moving;
  uint8_t direction;         // 1: Up, 2: Down, 0: Stopped
  uint8_t last_direction;    // 1: Up, 2: Down
  uint32_t start_time;
  uint32_t duration_ms;
  uint8_t pending_direction; // 0: None, 1: Pending Up, 2: Pending Down (Dead-time bekleme)
  uint32_t dead_time_start;  // ms timestamp: yön kesilme anı
  uint8_t current_position;  // 0-100 (%) (0: Tam Kapalı, 100: Tam Açık)
  uint8_t target_position;   // 0-100 (%) (255: Hedefsiz tam hareket)
  uint8_t start_position;    // Hareket başlangıcındaki anlık pozisyon (%)
};

static constexpr uint32_t SHUTTER_DEAD_TIME_MS = ShutterFsm::MIN_DEAD_TIME_MS; // Endüstriyel 500 ms ölü zaman emniyeti
static constexpr uint32_t SHUTTER_OVERRUN_MS = 2000;  // ADIM 15: %0 veya %100 uç noktalarında mekanik limit oturması ve self-healing için +2 sn (2000 ms) ilave süre

// ---------------------------------------------------------------------------------------------
// Durum anlık görüntüsü (FW-net MqttManager/WebPortal için, iş parçacığı güvenli)
// SmartAutomation::loop() (Core 1) her değişimde mutex altında günceller; okuyucular mutex altında
// KOPYA alır. Okuyucu hiçbir zaman SmartAutomation'ın canlı alanlarına dokunmaz.
// Röle/panjur/DI numaraları burada 0 tabanlıdır (dizi indeksi); JSON'a yazarken +1 ekleyin.
// ---------------------------------------------------------------------------------------------
struct ShutterSnapshot {
  uint8_t pos;       // 0..100 (0 = tam kapalı, 100 = tam açık)
  bool moving;       // röle enerjili mi
  uint8_t dir;       // 0 durdu, 1 yukarı, 2 aşağı  (state JSON "dir")
  uint8_t target;    // 0..100 veya 255 = hedef yok (state JSON "target")
  bool waiting;      // ters yön için ölü zaman bekleniyor (röleler kapalı, hareket kuyrukta)
  uint8_t pendingDir;// bekleyen yön: 0 yok, 1 yukarı, 2 aşağı
  uint8_t lastDir;   // son hareket yönü: 0 hiç, 1 yukarı, 2 aşağı
  bool configured;   // bu röle çifti geçerli bir panjur çifti mi (UP+DOWN tipli)
};

struct AutomationSnapshot {
  uint32_t seq;                 // her durum değişiminde artar (state JSON "seq" için kullanılabilir)
  bool childLock;               // state JSON "child_lock"
  char lastId[25];              // son işlenen komutun "id"si ("" = yok) -> state JSON "last_id"
  uint8_t totalRelays;          // yapılandırmadaki toplam röle (8 + ek modül)
  uint8_t totalPairs;           // totalRelays / 2 (panjur çifti üst sınırı; çiftin panjur olup olmadığına bakmaz)
  uint8_t totalDIs;
  bool extModuleResponding;     // RS485 ek modül yanıt veriyor mu (ek modül yoksa false)
  uint64_t relayMask;           // bit i = röle i+1 AÇIK (i = 0..39) — sürücüde DOĞRULANMIŞ durum
  uint64_t diMask;              // bit i = DI i+1 aktif
  ShutterSnapshot shutters[MAX_TOTAL_RELAYS / 2];

  bool relay(uint8_t relayIndex) const { return relayIndex < 64 && ((relayMask >> relayIndex) & 1ULL); }
  bool di(uint8_t diIndex) const { return diIndex < 64 && ((diMask >> diIndex) & 1ULL); }
};

class SmartAutomation {
public:
  static SmartAutomation& instance();
  void begin();
  void loop();

  // ====== OKUMA (iş parçacığı güvenli, herhangi bir görevden) ======
  // Tutarlı tam kopya. false => mutex alınamadı (out değişmez).
  bool getSnapshot(AutomationSnapshot& out) const;
  bool getShutterSnapshot(uint8_t pairIndex, ShutterSnapshot& out) const;   // pairIndex 0 tabanlı
  uint64_t getRelayMask() const;                                            // bit i = röle i+1
  bool getRelaySnapshot(uint8_t relayIndex) const;                          // relayIndex 0 tabanlı

  // Eski adlar (uyumluluk): anlık görüntüden okur; canlı duruma DOKUNMAZ.
  bool getRelayState(uint8_t relayIndex) const;                             // 0 tabanlı
  ShutterState getShutterState(uint8_t pairIndex) const;                    // 0 tabanlı
  uint8_t getShutterPosition(uint8_t pairIndex) const;
  bool getDIState(uint8_t diIndex) const;
  // CANLI bayrak (mutex/anlık görüntü zaman aşımında "false" = fail-open raporu YOK).
  bool isChildLockEnabled() const { return _childLockEnabled; }

  // ====== KOMUT ======
  // Röle/panjur DURUMUNU YALNIZCA loop() değiştirir. Dışarıdan her giriş yolu postDeviceCommand()
  // (DeviceCommand.h) ile kuyruğa yazar. Aşağıdaki eski çağrılar UYUMLULUK katmanıdır: loop görevinden
  // (WebPortal/CLI) çağrılırlarsa AYNI yürütücüde satır içi işlenir (eski eşzamanlı davranış korunur),
  // başka görevden çağrılırlarsa kuyruğa yazılır. Numaralar 0 tabanlıdır (eski API).
  // YENİ KOD postDeviceCommand() kullanmalıdır.
  void setRelayState(uint8_t relayIndex, bool state);
  void toggleRelay(uint8_t relayIndex);
  void shutterUp(uint8_t pairIndex);
  void shutterDown(uint8_t pairIndex);
  void shutterStop(uint8_t pairIndex);
  void shutterStep(uint8_t pairIndex);
  void setShutterPosition(uint8_t pairIndex, uint8_t targetPercent);
  void allLightsOff();
  void allShuttersDown();
  void allShuttersUp();
  void allShuttersStop();
  // NOT: setChildLock() KALDIRILDI. Çocuk kilidi YALNIZCA komut kuyruğundan (CmdType::SET_CHILD_LOCK,
  // postDeviceCommand) uygulanır; uygulama Core 1 loop() içinde (applyChildLock) yapılır.

  // ====== SİSTEM ======
  // Planlı yeniden başlatma: önce tüm panjurlar durdurulur ve röleler kapatılır, konumlar kaydedilir,
  // kayıtlı ön-yeniden-başlatma kancaları (ör. MQTT "offline" yayını) çağrılır, sonra ESP.restart().
  // delayMs: HTTP yanıtının gönderilebilmesi için bekleme (delay() KULLANILMAZ, sonraki turlarda yapılır).
  // Panjurlar ÇAĞRI ANINDA durdurulur; bekleme süresince yeni hareket komutları reddedilir.
  void requestRestart(uint32_t delayMs = 400);
  bool isRestartPending() const { return _restartPending; }
  // Kanca en çok 4 adet; çağrı Core 1 loop() bağlamında yapılır ve kısa sürmelidir (<~300 ms).
  static bool registerPreRestartHook(void (*fn)());

  // ====== RS485 / Harici Modül ======
  struct Rs485ScanResult {
    bool found;
    uint8_t slaveId;
    uint32_t baud;
    uint8_t relayStatus; // Coils byte
    String rawHex;
    String info;
  };
  enum class ScanState : uint8_t { IDLE = 0, RUNNING = 1, DONE = 2 };

  void rs485Begin(uint32_t baud);
  // Ham gönderim (servis/terminal): yalnızca OKUMA işlevleri ve panjur olmayan kanallara tek coil yazımı
  // kabul edilir; ASCII modunda yalnızca yazdırılabilir karakterler (Modbus yazma çerçevesi oluşamaz).
  // Yapılandırılmış ek modüle yapılan, YANKISI DOĞRULANAN tek-coil yazımı (0x05) uygulama durumuna da yansır (aksi halde coil
  // yoklaması <= ~1,5 sn'de rolenin istenen durumuna geri döndürürdü): ON/OFF -> RELAY_SET, TOGGLE (0x5500) -> RELAY_TOGGLE
  // (komut kuyruğundan; bu çağrı başka görevden gelebilir), toplu KAPAT (0x00FF) -> bayrak. Panjur kanalına KAPAT panjuru DURDURUR.
  // Başka slave'e / modül kapalıyken / yankısız (susmuş modül) yapılan ham yazım uygulama durumunu ETKİLEMEZ.
  bool rs485Send(const String& data, bool isHex);
  // Son rs485Send() guvenlik eylemcisi kurali (actuator_relay) yuzunden mi reddedildi? (cagiran gorev; WebPortal 409 icin)
  bool rawSendSafetyRejected() const { return _rawSafetyRej; }
  String rs485GetLogs();
  void rs485ClearLogs();

  // BLOKLAMAYAN tarama: ayrı görevde çalışır. WebPortal: POST -> rs485StartScan() ve 202 döner,
  // GET -> rs485ScanState()/rs485ScanResult() ile yoklanır.
  bool rs485StartScan(uint32_t specificBaud = 0);   // false: zaten çalışıyor
  ScanState rs485ScanState() const { return _scanState; }
  Rs485ScanResult rs485ScanResult();                // son tarama sonucu (kopya)
  // UYUMLULUK: eski çağrı. loop görevinden (CLI/eski WebPortal) çağrılırsa ASLA BLOKLAMAZ: taramayı arka
  // planda başlatır ve en son sonucu (yoksa "tarama sürüyor") döndürür. BAŞKA bir görevden çağrılırsa
  // (örn. WebPortal'ın kendi tarama görevi) o görevde SENKRON çalışır ve sonucu döndürür. Ana döngü
  // (panjur zamanlayıcıları, butonlar) her iki durumda da taramadan etkilenmez.
  Rs485ScanResult rs485ScanModule(uint32_t specificBaud = 0);

  // HAM ek modül röle komutu (servis/CLI). Panjur kanallarını ve channel=0 toplu AÇMAYI reddeder
  // (kapatma her zaman serbest). Yalnızca loop görevinden çağrılabilir.
  bool rs485ControlExtRelay(uint8_t slaveId, uint8_t channel, uint8_t action, String* responseHex = nullptr);

  bool isExtModuleResponding() const { return _extModuleResponding; }

  // ====== GÜVENLİK KATMANI (spec §2.3 madde 2) ======
  // SafetyManager kararını KUYRUKSUZ uygular: _want[relayIdx] = level (0 tabanlı). executeCommand'ı KULLANMAZ: restart ve
  // açılış-bekleme kapılarından muaftır, bip üretmez. Fiziksel yazımı yine stepOutputs yapar (tek yazıcı). Yalnız loop görevi.
  void applySafetyOutput(uint8_t relayIdx, bool level);
  // İstenen röle seviyeleri (bit = röle-1). Yalnız loop görevi (CLI'nin satır içi yapılandırma yaması yeni vananın konumunu benimser).
  uint64_t wantMask() const;
  // Tanılama (seri CLI "STATUS"): bağımsız emniyet görevinin yığınında hiç kullanılmayan en az bayt sayısı (0 = görev yok).
  // Cihazda ilk yazımdan sonra kontrol edilmeli: < 1024 bayt ise yığın büyütülmelidir.
  uint32_t guardStackFreeBytes() const;
  // TEK RS485 giriş noktası: mutex altında (başlatılmamış tampon yok, rxLen her zaman ayarlanır).
  bool rs485Transaction(const uint8_t *txBuf, size_t txLen, uint8_t *rxBuf, size_t maxRxLen, size_t &rxLen, uint32_t timeoutMs = 120);

private:
  SmartAutomation();

  enum : uint8_t { MAX_PAIRS = MAX_TOTAL_RELAYS / 2 };

  // ---- komut hattı ----
  bool submit(const DeviceCommand& cmd);                       // eski çağrıların ortak yolu
  void drainCommands(uint32_t now);
  bool executeCommand(const DeviceCommand& cmd, uint32_t now); // TEK mutasyon noktası (yalnızca loop görevi)
  bool pairConfigured(uint8_t pairIndex) const;
  void applyChildLock(bool enabled);                           // yalnızca executeCommand (Core 1)

  // ---- panjur sarmalayıcı ----
  void syncConfig(uint32_t now);
  void tickShutters(uint32_t now);
  void processShutterEvents(uint32_t now);
  bool pairHwOff(uint8_t pairIndex) const;
  void serviceGuardTrips(uint32_t now);
  void armGuard(uint8_t pairIndex, uint32_t startMs, uint32_t maxRunMs);
  void disarmGuard(uint8_t pairIndex);
  static void guardTask(void* arg);
  void guardSafeOutputs(uint32_t now);   // ValveGuard adımı (guard görevi, spec §5.1.5)
  static void shutdownHandler();
  void persistPositions(uint32_t now, bool force);
  void loadShutterPositions();

  // ---- darbe röleleri ----
  void startImpulse(uint8_t relayIndex, uint32_t now);
  void tickImpulses(uint32_t now);

  // ---- giriş (DI) ----
  void checkDigitalInputs(uint32_t now);
  // TEK kapı: yerel 8 GPIO (checkDigitalInputs) ve RS485 ek modül girişleri (pollExtModule) BURADAN geçer.
  // Süzgeç + çocuk kilidi + "basış işlendi" biti DiGate.h'dadır (saf mantık, test/test_di_gate).
  void handleDiEdge(uint8_t diIndex, bool closed, uint32_t now);
  void runDiDecision(uint8_t diIndex, const digate::Decision& dec, uint32_t now);

  // ---- fiziksel çıkış katmanı ----
  void stepOutputs(uint32_t now);
  void stepLocalOutputs(uint32_t now);
  void stepExtOutputs(uint32_t now);
  void syncLocalHw(uint8_t mask);
  // Sürücü eşitlemede (çip sıfırlanması / düşen röle) bildirilen düşen bitlere ait hareketli panjurları durdurur, bilinen durumu eşitler.
  void handleLocalDrops(uint32_t now);
  void markChanged();
  void emergencyAllOff();
  void safetyTick(uint32_t now);           // SafetyManager::tick + çıktıların her turda yeniden dayatılması (O(1) boşta)
  void safetyServiceConfig(uint32_t now);  // çalışırken güvenlik yapılandırması değişimi + maske kopyaları (O(1) boşta)
  void extOffExcept(uint32_t keepExt);     // ek modül: korunacak güvenli bitler dışındakileri KAPAT (en iyi çaba)
  void performRestart();

  // ---- RS485 (SmartAutomation_Rs485.cpp) ----
  bool rs485Exchange(const uint8_t* tx, size_t txLen, uint8_t* rx, size_t maxRx, size_t& rxLen,
                     size_t expectedLen, uint32_t timeoutMs, uint32_t lockWaitMs);
  bool rs485ExchangeLocked(const uint8_t* tx, size_t txLen, uint8_t* rx, size_t maxRx, size_t& rxLen,
                           size_t expectedLen, uint32_t timeoutMs);
  bool extWriteCoil(uint8_t slaveId, uint8_t channel1, uint16_t value, uint32_t lockWaitMs, String* respHex,
                    uint8_t attempts = 2, uint32_t timeoutMs = 120);
  bool extReadBits(uint8_t slaveId, uint8_t func, uint8_t count, uint8_t* bits, uint8_t& byteCount);
  // Panjur rölesi AÇILMADAN hemen önce modülün GERÇEK coil durumunu okur (yazma yankısı yanlış olabilir / başka bir
  // master coil'i açmış olabilir). Dönüş: PEER_OFF (güvenli), PEER_ON (eş AÇIK bulundu: durum güncellendi),
  // ALREADY_ON (bu röle "KAPALI" sanılırken AÇIK bulundu: beklenmedik; durum güncellendi), READ_FAILED.
  // PEER_ON ve ALREADY_ON'da hareket İPTAL edilir; açık röle bir sonraki turda KAPATILIR.
  enum ExtReadback : uint8_t { RB_PEER_OFF = 0, RB_PEER_ON = 1, RB_ALREADY_ON = 2, RB_READ_FAILED = 3 };
  ExtReadback extReadbackBeforeEnergize(uint8_t slaveId, uint8_t relayIdx);
  bool extAllOff();
  // Ham tek-coil yazımının (0x05, rs485Send) UYGULAMA durumuna yansıtılması: yapılandırılmış ek modüle yapılan geçerli yazım
  // (yankısı doğrulanmış) komut kuyruğuna RELAY_SET / RELAY_TOGGLE olarak yazılır; toplu KAPAT bayrağı loop()'ta işlenir.
  // rs485Send() başka görevden (WebTask) çağrılabildiği için durum DOĞRUDAN değiştirilmez.
  void mirrorRawCoilWrite(const uint8_t* req, const uint8_t* rx, size_t rxLen);
  void applyRawExtAllOff(uint32_t now);
  void pollExtModule(uint32_t now);
  void checkRs485Incoming();
  void addRs485Log(const String& line);
  static void scanTask(void* arg);
  bool tryEnterScan();                 // RUNNING durumuna atomik geçiş (zaten çalışıyorsa ya da ek modül panjuru hareket ediyorsa false)
  bool extShutterBusy() const;         // ek modül panjur çiftlerinden biri hareket ediyor/bekliyor mu (anlık görüntüden)
  void runScanBody(uint32_t specificBaud);   // taramayı BU görevde yürütür; sonunda DONE
  static void applyRs485Pins(uint32_t baud);

  // ================== durum (YALNIZCA loop görevi yazar) ==================
  ShutterFsm _fsm[MAX_PAIRS];
  bool _pairValid[MAX_PAIRS];
  uint8_t _posSaved[MAX_PAIRS];
  bool _posDirty;
  uint32_t _lastMotionMs;

  bool _want[MAX_TOTAL_RELAYS];        // istenen röle durumu (hafif komutlar + FSM çıkışı)
  bool _hw[MAX_TOTAL_RELAYS];          // sürücüde bilinen/doğrulanmış durum
  bool _hwKnown[MAX_TOTAL_RELAYS];     // durum teyitli mi (harici röleler için)
  bool _impulseActive[MAX_TOTAL_RELAYS];
  uint32_t _impulseStart[MAX_TOTAL_RELAYS];
  uint32_t _impulseDur[MAX_TOTAL_RELAYS];
  bool _adoptNextPoll[MAX_TOTAL_RELAYS]; // ham toggle sonrası bir sonraki coil okumasında durumu benimse

  digate::DiGate _diGate;                 // 60 ms süzgeç + çocuk kilidi + acted maskesi (saf mantık: DiGate.h)
  uint8_t _diActTarget[MAX_TOTAL_DIS];    // MOMENTARY: basış anındaki hedef röle (bırakmada AYNI röle kapatılır)
  bool _extDiInit;
  bool _extEnabledPrev;
  uint8_t _extChPrev;                     // syncConfig'in en son işlediği ek modül kanal sayısı (pano-4: etkinken değişim)
  uint64_t _extOffPending;                // fw-tarama-4: kanal sayısı azalınca kapsam dışına düşen, KAPAT yazılacak ek röleler (bit i = röle i+1)
  uint8_t _extOffFails;                   // ... ardışık başarısız KAPAT yazımı (EXT_OFF_MAX_FAILS'te küme bırakılır)
  uint8_t _extDiReadyCh;                  // ilk taze okumayla (kenarsız) başlatılmış ek DI kanalı sayısı (DiSensor::setExtReady)
  uint8_t _lastLocalPairMask;
  volatile bool _childLockEnabled;       // canlı bayrak (yalnız Core 1 yazar, her çekirdek okuyabilir)
  uint32_t _seenResetCount;               // ConfigManager::resetCount() ile fabrika sıfırlamayı fark etmek için
  // Güvenlik katmanı maskeleri (SafetyManager::begin'den). Yapılandırılmamış panoda 0: bütün kancalar tutmaz (spec §2.9).
  uint64_t _actuatorMask;                 // bit i = röle i+1 eylemci (yön kuralı, toplu kapatmadan muafiyet)
  uint64_t _sensorDiMask;                 // bit i = DI i+1 sensör/kontrol rolü/geri bildirim (duvar butonu kararına girmez)
  bool _localDiRead;                      // yerel DI'ler en az bir tur okundu (DiSensor "ok")
  uint32_t _safetyMasksGen;               // SafetyManager::masksGen() kopyası (maskeler yenilendi mi)

  // ZAMAN KURALI (millis() 24,86 günde 2^31'i, 49,7 günde 2^32'yi aşar): "gelecekteki hedef" biçimindeki
  // (int32_t)(now - hedef) < 0 karşılaştırması, hedef 24,86 günden eskiyse YANLIŞ sonuç verir (ana döngü / röle yazımı
  // günlerce donar). Bu yüzden burada "son olay + bekleme süresi" çiftleri ve (uint32_t)(now - son) < bekleme
  // kullanılır; bekleme 0 = engel yok (ilk değer). Tek istisna _restartAt: yalnızca _restartPending iken
  // (bekleme süresi içinde) okunur ve başka görevden yazılır (bkz. loop()).
  uint32_t _localRetryLast;            // yerel çıkış yazımı başarısız/ertelendi: son deneme anı
  uint32_t _localRetryGap;             // ... ve bir sonraki denemeden önce beklenecek süre (0 = beklemesiz)
  uint32_t _localFails;
  uint32_t _extRetryLast;              // harici modül yazımı başarısız: son deneme anı
  uint32_t _extRetryGap;               // ... ve geri çekilme süresi (0 = beklemesiz)
  uint32_t _extWriteFails;
  uint32_t _lastTcaVerify;
  InterlockGuard _extGuard;            // harici panjur çiftleri için sürücü seviyesi kural

  bool _stateChanged;
  uint32_t _lastMovePublish;
  uint32_t _bootAt;                    // begin() anı
  bool _bootHoldActive;                // açılış bekleme penceresi (500 ms) sürüyor mu; BİR KEZ kapanır
  char _lastId[25];
  volatile bool _restartPending;
  uint32_t _restartAt;
  TaskHandle_t _loopTask;
  TaskHandle_t _guardHandle;
  bool _started;

  // ---- komut/anlık görüntü ----
  mutable SemaphoreHandle_t _snapMutex;
  AutomationSnapshot _snap;
  void publishSnapshot(uint32_t now);

  // ---- RS485 durumu ----
  SemaphoreHandle_t _rs485Mutex;
  SemaphoreHandle_t _logMutex;
  mutable SemaphoreHandle_t _scanMutex;
  static const int RS485_LOG_MAX = 25;
  String _rs485Logs[RS485_LOG_MAX];
  int _rs485LogCount;
  uint32_t _rs485Baud;
  uint32_t _lastExtCoilPoll;
  uint32_t _extPollLast;               // son yoklama anı
  uint32_t _extPollGap;                // bir sonraki yoklamaya dek bekleme (120 ms ... 5 sn geri çekilme; 0 = hemen)
  uint8_t _extFails;
  volatile bool _extModuleResponding;
  volatile bool _rawExtAllOff;           // ham toplu KAPAT (0x00FF) yansıtma isteği (herhangi bir görev yazar, loop() tüketir)
  bool _rawSafetyRej;                     // son rs485Send guvenlik reddi (cagiran gorev yazar/okur)
  volatile ScanState _scanState;
  uint32_t _scanArg;
  uint32_t _scanDoneAt;
  Rs485ScanResult _scanResult;
};
