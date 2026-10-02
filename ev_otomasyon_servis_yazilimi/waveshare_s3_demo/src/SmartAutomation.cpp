#include "SmartAutomation.h"
#include "WS_Relay.h"
#include "WS_DIN.h"      // yalnızca DIN_PIN_CHx pin tanımları (WS_DIN.cpp derlemede YOK)
#include "WS_GPIO.h"
#include "MqttManager.h"
#include "ModbusRtu.h"
#include <HardwareSerial.h>
#include <Preferences.h>
#include <esp_task_wdt.h>
#include <esp_system.h>

// ===============================================================================================
// SABİTLER
// ===============================================================================================
static constexpr uint8_t  CMD_QUEUE_LEN      = 24;      // komut kuyruğu uzunluğu
// DI debounce (60 ms) TEK yerde tanımlıdır: digate::DiGate::DEBOUNCE_MS (src/DiGate.h). Yerel ve ek modül
// girişleri aynı kapıdan (handleDiEdge) geçer; burada ikinci bir kopya YOKTUR.
static constexpr uint32_t GUARD_MARGIN_MS    = 1500;   // bağımsız motor emniyeti: planlanan süre + marj
static constexpr uint32_t POS_SAVE_DELAY_MS  = 8000;    // hareket bittikten sonra NVS yazımı gecikmesi (5-10 sn)
static constexpr uint8_t  POS_SAVE_MIN_DELTA = 2;       // |Δ| >= %2
static constexpr uint32_t TCA_VERIFY_PERIOD_MS = 2000;
#define NVS_KEY_CHILD_LOCK "child_lock"

// ===============================================================================================
// KOMUT KUYRUĞU (docs/CONTRACTS.md §4)
// Kuyruk begin()'de oluşur. postDeviceCommand() her görevden çağrılabilir; kuyruğu YALNIZCA
// SmartAutomation::loop() (Core 1) boşaltır.
//
// SIRA (FIFO): komutlar GELİŞ SIRASIYLA yürütülür. (Eski taslak DURDURMA'yı kuyruğun BAŞINA yazıyordu: aynı turda
// gelen "YUKARI, sonra DURDUR" çifti "DURDUR, sonra YUKARI"ya dönüşür ve kullanıcının son niyeti olan DURDURMA
// çiğnenirdi. Kuyruk 24 derinliktedir ve tur başına 12 komut boşalır: sıradaki bir DURDURMA en çok ~1 tur gecikir.)
// Kuyruk DOLU iken gelen DURDURMA yine de ASLA kaybolmaz: acil durdurma bayrağı kurulur, loop() bu turda bütün
// panjurları durdurur ve kuyruktaki (DURDURMA'dan ÖNCE gelmiş) komutlar boşaldıktan sonra bir kez daha durdurur.
// ===============================================================================================
static QueueHandle_t s_cmdQueue = nullptr;
static volatile bool s_emergencyStopAll = false;
static volatile uint32_t s_cmdDropped = 0;

bool postDeviceCommand(const DeviceCommand& cmd) {
  QueueHandle_t q = s_cmdQueue;
  if (q == nullptr) return false;   // begin() henüz çağrılmadı

  DeviceCommand c = cmd;
  c.id[sizeof(c.id) - 1] = '\0';    // dışarıdan gelen kimlik her zaman sonlandırılmış olsun

  const bool isStop = (c.type == CmdType::SHUTTER_STOP || c.type == CmdType::ALL_SHUTTERS_STOP);
  if (xQueueSend(q, &c, 0) == pdTRUE) return true;

  s_cmdDropped = s_cmdDropped + 1;
  if (isStop) {
    // Durdurma ASLA kaybolmaz: kuyruk dolu olsa bile loop() bir sonraki turda tüm panjurları durdurur.
    s_emergencyStopAll = true;
  }
  return false;
}

// ===============================================================================================
// BAĞIMSIZ MOTOR SÜRE AŞIMI EMNİYETİ (F5)
// Ana döngü (loopTask) bir şeyde takılırsa (HTTP istemcisi bekleme, NVS yazımı, RS485...) panjur
// rölesi planlanan süreden sonra da enerjili kalırdı. Ayrı bir görev (Core 0, öncelik 3) 50 ms'de bir
// "kurulu" panjurların süresini kontrol eder; planlanan süre + 1,5 sn aşılırsa röleleri KENDİ BAŞINA keser.
// Paylaşılan veri küçük bir yapıdır ve spinlock ile korunur. Ana döngü açılışta/durmada kurar/bozar.
// ===============================================================================================
struct GuardSlot {
  uint32_t start;
  uint32_t maxRun;
  bool armed;
  bool tripped;
};
static GuardSlot s_guard[MAX_TOTAL_RELAYS / 2];
static portMUX_TYPE s_guardMux = portMUX_INITIALIZER_UNLOCKED;

void SmartAutomation::armGuard(uint8_t p, uint32_t startMs, uint32_t maxRunMs) {
  if (p >= MAX_PAIRS) return;
  portENTER_CRITICAL(&s_guardMux);
  s_guard[p].start = startMs;
  s_guard[p].maxRun = maxRunMs;
  s_guard[p].armed = true;
  portEXIT_CRITICAL(&s_guardMux);
}

void SmartAutomation::disarmGuard(uint8_t p) {
  if (p >= MAX_PAIRS) return;
  portENTER_CRITICAL(&s_guardMux);
  s_guard[p].armed = false;
  portEXIT_CRITICAL(&s_guardMux);
}

void SmartAutomation::guardTask(void* arg) {
  SmartAutomation* self = static_cast<SmartAutomation*>(arg);
  esp_task_wdt_add(NULL);
  for (;;) {
    esp_task_wdt_reset();
    const uint32_t now = millis();
    for (uint8_t p = 0; p < MAX_PAIRS; p++) {
      bool armed;
      uint32_t st, mx;
      portENTER_CRITICAL(&s_guardMux);
      armed = s_guard[p].armed;
      st = s_guard[p].start;
      mx = s_guard[p].maxRun;
      portEXIT_CRITICAL(&s_guardMux);
      if (!armed) continue;
      if ((uint32_t)(now - st) <= mx) continue;

      // SÜRE AŞILDI: ana döngü bu panjuru durdurmadı. Röleleri KES.
      printf("[EMNIYET] Panjur %u motor sure asimi (%u ms > %u ms)! Roleler zorla kapatiliyor.\r\n",
             (unsigned)(p + 1), (unsigned)(now - st), (unsigned)mx);
      if (p < 4) {
        TCA_ClearBits((uint8_t)(0x03 << (2 * p)));          // yerel röleler: gölge & ~çift
      } else {
        // Harici modül: her iki yönü KAPAT (doğrulamalı yazım). Hat meşgulse bir sonraki turda tekrar denenir.
        uint8_t slave = ConfigManager::instance().config.ext_module_address;
        uint8_t ch = (uint8_t)((p - 4) * 2 + 1 + 0);         // ek modül kanalı (1 tabanlı): röle 8+2(p-4) -> kanal 2(p-4)+1
        bool a = self->extWriteCoil(slave, ch, modbus::COIL_OFF, 150, nullptr);
        bool b = self->extWriteCoil(slave, (uint8_t)(ch + 1), modbus::COIL_OFF, 150, nullptr);
        if (!(a && b)) { vTaskDelay(pdMS_TO_TICKS(50)); continue; }   // armed kalır: yeniden dene
      }
      portENTER_CRITICAL(&s_guardMux);
      s_guard[p].armed = false;
      s_guard[p].tripped = true;
      portEXIT_CRITICAL(&s_guardMux);
    }
    vTaskDelay(pdMS_TO_TICKS(50));
  }
}

// ===============================================================================================
// OLUŞTURUCU
// ===============================================================================================
SmartAutomation& SmartAutomation::instance() {
  static SmartAutomation instance;
  return instance;
}

SmartAutomation::SmartAutomation()
    : _posDirty(false), _lastMotionMs(0), _extDiInit(false), _extEnabledPrev(false), _lastLocalPairMask(0xFF),
      _childLockEnabled(false), _seenResetCount(0), _localRetryLast(0), _localRetryGap(0), _localFails(0),
      _extRetryLast(0), _extRetryGap(0), _extWriteFails(0),
      _lastTcaVerify(0), _stateChanged(false), _lastMovePublish(0), _bootAt(0), _bootHoldActive(false), _restartPending(false),
      _restartAt(0), _loopTask(nullptr), _guardHandle(nullptr),
      _started(false), _snapMutex(nullptr), _rs485Mutex(nullptr), _logMutex(nullptr), _scanMutex(nullptr),
      _rs485LogCount(0), _rs485Baud(9600), _lastExtCoilPoll(0), _extPollLast(0), _extPollGap(0), _extFails(0),
      _extModuleResponding(false), _rawExtAllOff(false), _scanState(ScanState::IDLE), _scanArg(0), _scanDoneAt(0) {
  memset(&_snap, 0, sizeof(_snap));
  // _scanResult String içerir: memset YOK, alanlar tek tek (String'ler varsayılan boş)
  _scanResult.found = false;
  _scanResult.slaveId = 0;
  _scanResult.baud = 0;
  _scanResult.relayStatus = 0;
  _lastId[0] = '\0';
  for (int i = 0; i < MAX_PAIRS; i++) {
    _pairValid[i] = false;
    _posSaved[i] = 0;
    _snap.shutters[i].target = 255;
  }
  for (int i = 0; i < MAX_TOTAL_RELAYS; i++) {
    _want[i] = false;
    _hw[i] = false;
    _hwKnown[i] = (i < 8);        // yerel röleler açılışta bilinir (TCA gölgesi); harici röleler teyit bekler
    _impulseActive[i] = false;
    _impulseStart[i] = 0;
    _impulseDur[i] = 0;
    _adoptNextPoll[i] = false;
  }
  for (int i = 0; i < MAX_TOTAL_DIS; i++) {
    _diGate.init((uint8_t)i, false, 0);
    _diActTarget[i] = 0;
  }
}

// ===============================================================================================
// NVS: panjur konumları (debounce'lu, tek yazım) ve çocuk kilidi
// ===============================================================================================
void SmartAutomation::loadShutterPositions() {
  Preferences prefs;
  bool haveBlob = false;
  uint8_t buf[MAX_PAIRS];
  memset(buf, 0, sizeof(buf));

  if (prefs.begin(NVS_NS_POS, false)) {            // okuma-yazma: ilk açılışta "NOT_FOUND" hata logu yok
    if (prefs.isKey("pos") && prefs.getBytesLength("pos") == MAX_PAIRS) {
      haveBlob = (prefs.getBytes("pos", buf, MAX_PAIRS) == MAX_PAIRS);
    } else if (prefs.isKey("sh_pos_0")) {
      // Eski sürüm (her çift için ayrı anahtar) -> göç: ilk debounce'lu yazımda tek bloğa yazılır.
      // (Taze cihazda eski anahtar yoktur: gereksiz ilk-açılış yazımı YAPILMAZ; blok ilk hareketten sonra yazılır.)
      for (int i = 0; i < MAX_PAIRS; i++) {
        char key[16];
        snprintf(key, sizeof(key), "sh_pos_%d", i);
        buf[i] = prefs.getUChar(key, 0);
      }
      _posDirty = true;
    }
    prefs.end();
  }
  for (int i = 0; i < MAX_PAIRS; i++) {
    if (buf[i] > 100) buf[i] = 0;
    _fsm[i].setPosition(buf[i]);
    _posSaved[i] = haveBlob ? buf[i] : 0xFF;   // göçte ilk yazımı zorla
  }
  printf("SmartAutomation: Panjur pozisyonlari NVS'den yuklendi.\r\n");
}

// Tüm çiftler TEK yazımda; yalnızca hareket bittikten POS_SAVE_DELAY_MS sonra ve |Δ| >= %2 ise.
void SmartAutomation::persistPositions(uint32_t now, bool force) {
  if (!_posDirty && !force) return;

  for (int p = 0; p < MAX_PAIRS; p++) {
    if (_fsm[p].isMoving() || _fsm[p].isWaiting()) {
      _lastMotionMs = now;       // hareket sürüyor: yazma, bitişi bekle
      if (!force) return;
    }
  }
  if (!force && (uint32_t)(now - _lastMotionMs) < POS_SAVE_DELAY_MS) return;

  uint8_t cur[MAX_PAIRS];
  bool need = false;
  for (int p = 0; p < MAX_PAIRS; p++) {
    cur[p] = _fsm[p].position(now);
    int d = (int)cur[p] - (int)_posSaved[p];
    if (_posSaved[p] == 0xFF) need = true;
    else if (d >= POS_SAVE_MIN_DELTA || d <= -POS_SAVE_MIN_DELTA) need = true;
    else if ((cur[p] == 0 || cur[p] == 100) && cur[p] != _posSaved[p]) need = true;   // uç noktaya oturma
  }
  if (!need) { _posDirty = false; return; }

  Preferences prefs;
  bool ok = false;
  if (prefs.begin(NVS_NS_POS, false)) {
    ok = (prefs.putBytes("pos", cur, MAX_PAIRS) == MAX_PAIRS);
    prefs.end();
  }
  if (ok) {
    memcpy(_posSaved, cur, MAX_PAIRS);
    _posDirty = false;
  } else {
    printf("[NVS] UYARI: panjur konumlari yazilamadi, daha sonra tekrar denenecek.\r\n");
    _lastMotionMs = now;         // bir 8 sn daha bekle
  }
}

// Çocuk kilidi: YALNIZCA executeCommand(SET_CHILD_LOCK) çağırır (Core 1). Değişim yoksa NVS'e yazılmaz,
// bip/log yok (flash aşınması). Yazma sonucu kontrol edilir: başarısızsa kilit RAM'de etkin kalır ama
// yeniden başlatmada kaybolacağı açıkça loglanır. Değişimde state yayını ANINDA tetiklenir
// (retained child_lock 30 sn bayat kalmasın).
void SmartAutomation::applyChildLock(bool enabled) {
  if (_childLockEnabled == enabled) return;
  _childLockEnabled = enabled;

  bool persisted = false;
  {
    Preferences prefs;
    if (prefs.begin(NVS_NS_AUTO, false)) {
      persisted = (prefs.putBool(NVS_KEY_CHILD_LOCK, enabled) == sizeof(uint8_t));
      prefs.end();
    }
  }
  if (!persisted) {
    printf("[NVS] HATA: cocuk kilidi NVS'e yazilamadi! Kilit simdilik etkin ama YENIDEN BASLATMADA KAYBOLUR.\r\n");
  }
  printf("[ÇOCUK KİLİDİ] Durum guncellendi: %s\r\n", enabled ? "AKTİF (Duvardaki Anahtarlar Kilitli)" : "PASİF (Normal)");
  Buzzer_Open_Time(enabled ? 200 : 100, 0);
  markChanged();       // loop() sonunda MqttManager::triggerPublish() -> retained state hemen güncellenir
}

// ===============================================================================================
// BAŞLATMA
// ===============================================================================================
void SmartAutomation::begin() {
  if (_started) return;
  _started = true;
  _loopTask = xTaskGetCurrentTaskHandle();

  _snapMutex = xSemaphoreCreateMutex();
  _logMutex = xSemaphoreCreateMutex();
  _scanMutex = xSemaphoreCreateMutex();
  _rs485Mutex = xSemaphoreCreateMutex();            // (eski kod bu mutex'i HİÇ oluşturmuyordu)
  s_cmdQueue = xQueueCreate(CMD_QUEUE_LEN, sizeof(DeviceCommand));
  if (!_snapMutex || !_logMutex || !_scanMutex || !_rs485Mutex || !s_cmdQueue) {
    printf("[KOMUT] HATA: komut kuyrugu/mutex olusturulamadi (bellek yetersiz)!\r\n");
  }

  auto& cfg = ConfigManager::instance().config;
  const uint32_t now = millis();

  // Giriş pinlerini PULLUP ile hazırla (Yerel 8 DI). Açılışta mevcut seviye "kararlı" kabul edilir (kenar üretmez).
  const uint8_t diPins[8] = {
    DIN_PIN_CH1, DIN_PIN_CH2, DIN_PIN_CH3, DIN_PIN_CH4,
    DIN_PIN_CH5, DIN_PIN_CH6, DIN_PIN_CH7, DIN_PIN_CH8
  };
  for (int i = 0; i < 8; i++) {
    pinMode(diPins[i], INPUT_PULLUP);
    _diGate.init((uint8_t)i, digitalRead(diPins[i]) == LOW, now);
  }

  // ADIM 17: Çocuk Kilidi NVS'den yükle
  {
    // Okuma-yazma açılış: ad alanı yoksa (ilk açılış) oluşturulur, "nvs_open failed: NOT_FOUND" hata logu basılmaz.
    // Gerçek bir NVS hatası ise (begin() false) GÖRÜNÜR loglanır; kilit o durumda "açık değil" varsayılır.
    Preferences childPrefs;
    if (childPrefs.begin(NVS_NS_AUTO, false)) {
      _childLockEnabled = childPrefs.getBool(NVS_KEY_CHILD_LOCK, false);
      childPrefs.end();
    } else {
      printf("[NVS] HATA: '%s' acilamadi, cocuk kilidi okunamadi (kilitsiz varsayildi).\r\n", NVS_NS_AUTO);
    }
  }
  if (_childLockEnabled) {
    printf("SmartAutomation: [ÇOCUK KİLİDİ AKTİF] Duvardaki anahtarlar kilitli baslatildi.\r\n");
  }

  // Panjur konumları NVS'den (Panjurlar KESİNLİKLE hareket ettirilmez)
  loadShutterPositions();

  // Panjur çiftleri / süreler / sürücü interlock maskeleri
  _extEnabledPrev = cfg.ext_module_enabled;
  syncConfig(now);

  // RS485 Seri Portunu Başlat (ek modül olmasa da CLI/servis tarama için hazır)
  rs485Begin(cfg.rs485_baud);

  // ADIM 15: Power-On State (Elektrik Kesintisi Güvenliği):
  // Gece elektrik kesilip geri geldiğinde lambaların varsayılan durumu KESİNLİKLE KAPALI (OFF) kalır.
  // Panjurlar hareket etmez. Yerel çıkışlar Relay_Init() ile zaten kapatıldı; burada tekrar doğrulanır.
  const uint8_t totalR = cfg.totalRelays();
  for (int i = 0; i < MAX_TOTAL_RELAYS; i++) _want[i] = false;
  if (TCA_WriteOutputs(0x00)) syncLocalHw(0x00);
  else printf("[HATA] Yerel rolelerin kapatilmasi dogrulanamadi!\r\n");

  if (cfg.ext_module_enabled && totalR > 8) {
    // Ek modül rölelerinin durumu BİLİNMİYOR: "açık olabilir" kabul edilir, KAPAT yazımı + coil okuması ile teyit edilir.
    for (int i = 8; i < totalR; i++) { _hw[i] = true; _hwKnown[i] = false; }
    _extGuard.forceHw(~0ULL << 8);
    if (extAllOff()) {
      for (int i = 8; i < totalR; i++) { _hw[i] = false; _hwKnown[i] = true; }
      _extGuard.commit(0, now);
    }
  }
  _lastTcaVerify = now;
  // Açılıştan sonra ilk 500 ms komut/DI işlenmez: TCA9554 çıkış latch'i ESP32 yeniden başlamasında önceki
  // durumu korur (motor dönüyor olabilir); sürücü ölü zamanı (500 ms) bu pencerede dolar, ilk komut asla
  // "sahte hata"ya (alarm) takılmaz. Pencere BİR KEZ kapanır (bayrak): "hedef zamanı" saklanıp (int32_t) farkıyla
  // karşılaştırılsaydı, 24,86 gün çalışma süresinden sonra ana döngü günlerce donardı (bkz. SmartAutomation.h ZAMAN KURALI).
  _bootAt = now;
  _bootHoldActive = true;
  markChanged();

  // Bağımsız emniyet görevi (Core 0, öncelik 3) + yazılımlı yeniden başlatmada röleleri kapatan kanca
  // Yığın 6 KB: printf/String/RS485 işlemleri bu görevde de koşabilir (cihazda ölçülemedi; STATUS yüksek su işaretini gösterir).
  xTaskCreatePinnedToCore(guardTask, "ShutterGuard", 6144, this, 3, &_guardHandle, 0);
  esp_register_shutdown_handler(shutdownHandler);

  printf("SmartAutomation: [POWER-ON RESTORE] Tum lambalar KESINLIKLE KAPALI (OFF), panjurlar hareketsiz baslatildi (Toplam Röle: %d, DI: %d).\r\n",
         totalR, cfg.totalDIs());
}

uint32_t SmartAutomation::guardStackFreeBytes() const {
  return _guardHandle ? (uint32_t)uxTaskGetStackHighWaterMark(_guardHandle) : 0;
}

// esp_restart()/ESP.restart() ÇAĞRISI NEREDEN GELİRSE GELSİN (Web, MQTT, CLI, OTA) röleleri önce kapatır.
void SmartAutomation::shutdownHandler() {
  TCA_WriteOutputs(0x00);   // yalnızca KAPATMA: interlock'a takılmaz
}

// ===============================================================================================
// ORTAK KÜÇÜK İŞLER
// ===============================================================================================
bool SmartAutomation::pairConfigured(uint8_t p) const {
  auto& cfg = ConfigManager::instance().config;
  if (p >= cfg.totalRelays() / 2 || p >= MAX_PAIRS) return false;
  return cfg.relays[2 * p].type == RELAY_TYPE_SHUTTER_UP && cfg.relays[2 * p + 1].type == RELAY_TYPE_SHUTTER_DOWN;
}

void SmartAutomation::markChanged() {
  _stateChanged = true;
}

// Yapılandırma ile çalışma durumunu eşitler (her turda ucuz): çift geçerliliği, süreler, sürücü maskeleri.
// HAREKET SIRASINDA süre/yapılandırma değişimi uygulanmaz (FSM.setTiming reddeder); çift geçersizleşirse DURDURULUR.
void SmartAutomation::syncConfig(uint32_t now) {
  auto& cfg = ConfigManager::instance().config;

  // Fabrika sıfırlama (ConfigManager::resetToDefaults) NVS'teki çocuk kilidi ad alanını sildi: RAM bayrağı da
  // sıfırlanır (aksi halde yeniden başlatmaya dek RAM'de "kilitli", NVS'te "kilitsiz" tutarsızlığı kalırdı).
  const uint32_t rc = ConfigManager::instance().resetCount();
  if (rc != _seenResetCount) {
    _seenResetCount = rc;
    if (_childLockEnabled) {
      _childLockEnabled = false;
      printf("[ÇOCUK KİLİDİ] Fabrika sifirlama: kilit kaldirildi (RAM).\r\n");
      markChanged();
    }
  }

  // Ek modül açıldı/kapandı: ek röleler "bilinmiyor"a döner ve KAPALI olması doğrulanana dek yeniden yazılır.
  if (cfg.ext_module_enabled != _extEnabledPrev) {
    const bool wasEnabled = _extEnabledPrev;
    _extEnabledPrev = cfg.ext_module_enabled;
    if (wasEnabled && !cfg.ext_module_enabled) {
      // Ek modül yapılandırmadan kapatıldı ama fiziksel olarak bağlı olabilir: röleleri KAPAT (en iyi çaba).
      for (uint8_t p = 4; p < MAX_PAIRS; p++) {
        if (_fsm[p].isMoving() || _fsm[p].isWaiting()) _fsm[p].forceStop(now);
        disarmGuard(p);
      }
      extAllOff();
    }
    for (int i = 8; i < MAX_TOTAL_RELAYS; i++) {
      _want[i] = false;
      _hw[i] = cfg.ext_module_enabled;      // "açık olabilir": KAPAT komutu gönderilecek
      _hwKnown[i] = false;
      _impulseActive[i] = false;
      _adoptNextPoll[i] = false;
    }
    _extGuard.forceHw(cfg.ext_module_enabled ? (~0ULL << 8) : 0ULL);
    _extFails = 0;
    _extPollLast = now;
    _extPollGap = 0;
    _extRetryGap = 0;
    _extDiInit = false;
    _extModuleResponding = false;
  }

  uint32_t pairMaskExt = 0;
  uint8_t pairMaskLocal = 0;
  for (uint8_t p = 0; p < MAX_PAIRS; p++) {
    const bool valid = pairConfigured(p);
    if (valid != _pairValid[p]) {
      if (!valid && (_fsm[p].isMoving() || _fsm[p].isWaiting())) {
        printf("[PANJUR %u] Yapilandirma degisti, cift artik gecerli degil -> DURDURULDU.\r\n", (unsigned)(p + 1));
        _fsm[p].forceStop(now);
      }
      _pairValid[p] = valid;
    }
    if (valid) {
      if (p < 4) pairMaskLocal |= (uint8_t)(1u << p);
      else pairMaskExt |= (1UL << p);
      if (!_fsm[p].isMoving() && !_fsm[p].isWaiting()) {
        uint32_t upMs = (uint32_t)cfg.relays[2 * p].runtime_sec * 1000UL;
        uint32_t downMs = (uint32_t)cfg.relays[2 * p + 1].runtime_sec * 1000UL;
        _fsm[p].setTiming(upMs, downMs, SHUTTER_DEAD_TIME_MS, SHUTTER_OVERRUN_MS);
      }
    }
  }
  if (pairMaskLocal != _lastLocalPairMask) {
    _lastLocalPairMask = pairMaskLocal;
    TCA_SetShutterPairs(pairMaskLocal);
  }
  _extGuard.setShutterPairs(pairMaskExt);
}

// Sürücüde bu çiftin İKİ rölesi de KAPALI olarak doğrulandı mı?
bool SmartAutomation::pairHwOff(uint8_t p) const {
  return !_hw[2 * p] && !_hw[2 * p + 1] && _hwKnown[2 * p] && _hwKnown[2 * p + 1];
}

// ===============================================================================================
// KOMUT YÜRÜTME (TEK mutasyon noktası; yalnızca loop görevinde)
// ===============================================================================================
void SmartAutomation::drainCommands(uint32_t now) {
  // Kuyruk doluyken gelen (yazılamayan) DURDURMA: önce hemen durdur, kuyruktakiler (DURDURMA'dan ÖNCE gelmiş
  // olanlar) yürütüldükten sonra bir kez daha durdur. Kuyruk bu turda tümüyle boşalmadıysa bayrak korunur.
  bool stopAfter = false;
  if (s_emergencyStopAll) {
    s_emergencyStopAll = false;
    stopAfter = true;
    printf("[KOMUT] Kuyruk doluyken durdurma istendi -> tum panjurlar durduruluyor.\r\n");
    executeCommand(makeCommand(CmdType::ALL_SHUTTERS_STOP, CmdSource::MQTT), now);
  }

  QueueHandle_t q = s_cmdQueue;
  if (q == nullptr) return;

  // Sınırlı sürede boşalt: bir turda en çok 12 komut ve ~15 ms (döngüyü aç bırakmamak için).
  const uint32_t t0 = millis();
  DeviceCommand cmd;
  bool emptied = false;
  for (int n = 0; n < 12 && (uint32_t)(millis() - t0) < 15; n++) {
    if (xQueueReceive(q, &cmd, 0) != pdTRUE) { emptied = true; break; }
    executeCommand(cmd, now);
  }
  if (stopAfter) {
    if (!emptied) s_emergencyStopAll = true;        // kalan eski komutlar sonraki turda; durdurma yinelenir
    executeCommand(makeCommand(CmdType::ALL_SHUTTERS_STOP, CmdSource::MQTT), now);
  }
}

bool SmartAutomation::executeCommand(const DeviceCommand& cmd, uint32_t now) {
  auto& cfg = ConfigManager::instance().config;
  const uint8_t totalR = cfg.totalRelays();
  const uint8_t totalPairs = totalR / 2;

  const bool isStop = (cmd.type == CmdType::SHUTTER_STOP || cmd.type == CmdType::ALL_SHUTTERS_STOP);
  if (_restartPending && !isStop) {
    printf("[KOMUT] Yeniden baslatma bekleniyor, komut reddedildi.\r\n");
    return false;
  }

  // Dış dünyada tüm numaralar 1 tabanlıdır; burada 0 tabanlı dizi indeksine çevrilir.
  const uint8_t idx = (cmd.index > 0) ? (uint8_t)(cmd.index - 1) : 0xFF;
  bool ok = true;

  switch (cmd.type) {
    case CmdType::RELAY_SET:
    case CmdType::RELAY_TOGGLE: {
      if (idx >= totalR) {
        printf("[KOMUT] gecersiz role: %u\r\n", (unsigned)cmd.index);
        ok = false;
        break;
      }
      const uint8_t rtype = cfg.relays[idx].type;
      // Açık komut, ham TOGGLE sonrası bekleyen "fiziksel durumu benimse" isteğini GEÇERSİZ kılar: kullanıcının son isteği kazanır
      // (aksi halde modül susup geri geldiğinde coil yoklaması fiziksel AÇIK durumu istenen durum diye benimser, KAPAT komutu kaybolurdu).
      _adoptNextPoll[idx] = false;
      if (rtype == RELAY_TYPE_SHUTTER_UP || rtype == RELAY_TYPE_SHUTTER_DOWN) {
        // Panjur rölesi: ham röle aç/kapa YOK; ShutterFsm (interlock + ölü zaman) üzerinden gider.
        const uint8_t p = idx / 2;
        if (!pairConfigured(p)) {
          printf("[KOMUT] Role %u panjur tipli ama cift gecerli degil (UP+DOWN eslesmesi yok) -> reddedildi.\r\n", (unsigned)cmd.index);
          ok = false;
          break;
        }
        const bool isUp = (rtype == RELAY_TYPE_SHUTTER_UP);
        bool on;
        if (cmd.type == CmdType::RELAY_SET) on = (cmd.value != 0);
        else on = !(_fsm[p].isMoving() || _fsm[p].isWaiting());
        if (on && p >= 4 && _scanState == ScanState::RUNNING) {   // tarama hattı tutarken ek modül panjuru başlatılmaz
          printf("[KOMUT] RS485 taramasi suruyor: ek modul panjuru komutu reddedildi.\r\n");
          ok = false;
          break;
        }
        if (on) { if (isUp) _fsm[p].cmdUp(now); else _fsm[p].cmdDown(now); }
        else _fsm[p].cmdStop(now);
      } else if (rtype == RELAY_TYPE_IMPULSE) {
        bool on = (cmd.type == CmdType::RELAY_SET) ? (cmd.value != 0) : !_impulseActive[idx];
        if (on) {
          startImpulse(idx, now);
          Buzzer_Open_Time(100, 0);
        } else {
          _impulseActive[idx] = false;
          _want[idx] = false;
        }
      } else {
        bool on = (cmd.type == CmdType::RELAY_SET) ? (cmd.value != 0) : !_want[idx];
        _want[idx] = on;
        Buzzer_Open_Time(80, 0);
      }
      break;
    }

    case CmdType::SHUTTER_UP:
    case CmdType::SHUTTER_DOWN:
    case CmdType::SHUTTER_STOP:
    case CmdType::SHUTTER_STEP:
    case CmdType::SHUTTER_POS: {
      if (idx >= totalPairs || !pairConfigured(idx)) {
        printf("[KOMUT] gecersiz veya panjur olmayan cift: %u\r\n", (unsigned)cmd.index);
        ok = false;
        break;
      }
      // Tarama hattı (RS485 mutex'i) tutarken ek modüle KAPAT gönderilemez: hareket başlatılmaz (DURDURMA serbest).
      if (idx >= 4 && cmd.type != CmdType::SHUTTER_STOP && _scanState == ScanState::RUNNING) {
        printf("[KOMUT] RS485 taramasi suruyor: ek modul panjuru komutu reddedildi.\r\n");
        ok = false;
        break;
      }
      if (cmd.type == CmdType::SHUTTER_UP) _fsm[idx].cmdUp(now);
      else if (cmd.type == CmdType::SHUTTER_DOWN) _fsm[idx].cmdDown(now);
      else if (cmd.type == CmdType::SHUTTER_STOP) _fsm[idx].cmdStop(now);
      else if (cmd.type == CmdType::SHUTTER_STEP) _fsm[idx].cmdStep(now);
      else {
        if (cmd.value < 0 || cmd.value > 100) {
          printf("[KOMUT] SHUTTER_POS gecersiz deger: %ld\r\n", (long)cmd.value);
          ok = false;
          break;
        }
        _fsm[idx].cmdPosition(now, (uint8_t)cmd.value);
      }
      break;
    }

    case CmdType::ALL_LIGHTS_OFF: {
      for (uint8_t i = 0; i < totalR; i++) {
        if (cfg.relays[i].type == RELAY_TYPE_LIGHT) { _want[i] = false; _adoptNextPoll[i] = false; }   // açık komut bekleyen benimsemeyi geçersiz kılar
      }
      Buzzer_Open_Time(300, 0);
      printf("Tum lambalar kapatildi.\r\n");
      break;
    }

    case CmdType::ALL_SHUTTERS_UP:
    case CmdType::ALL_SHUTTERS_DOWN:
    case CmdType::ALL_SHUTTERS_STOP: {
      // Yalnızca GEÇERLİ panjur çiftleri (eski kod "||" koşuluyla lamba çiftlerini de panjur sanıyordu)
      for (uint8_t p = 0; p < totalPairs; p++) {
        if (!_pairValid[p]) continue;
        if (p >= 4 && cmd.type != CmdType::ALL_SHUTTERS_STOP && _scanState == ScanState::RUNNING) continue;   // tarama sürüyor
        if (cmd.type == CmdType::ALL_SHUTTERS_UP) _fsm[p].cmdUp(now);
        else if (cmd.type == CmdType::ALL_SHUTTERS_DOWN) _fsm[p].cmdDown(now);
        else _fsm[p].cmdStop(now);
      }
      break;
    }

    case CmdType::SET_CHILD_LOCK:
      applyChildLock(cmd.value != 0);
      break;

    case CmdType::SET_RUNTIME: {
      // 1..300 sn; NVS'e yazılır (nadir); hareket sırasında REDDEDİLİR
      if (idx >= totalPairs || !pairConfigured(idx) || cmd.value < SHUTTER_RUNTIME_MIN_SEC || cmd.value > SHUTTER_RUNTIME_MAX_SEC) {
        printf("[KOMUT] SET_RUNTIME gecersiz (panjur=%u, sn=%ld)\r\n", (unsigned)cmd.index, (long)cmd.value);
        ok = false;
        break;
      }
      if (_fsm[idx].isMoving() || _fsm[idx].isWaiting()) {
        printf("[KOMUT] SET_RUNTIME reddedildi: panjur %u hareket halinde.\r\n", (unsigned)cmd.index);
        ok = false;
        break;
      }
      const uint8_t rUp = idx * 2;
      const uint8_t rDown = rUp + 1;
      cfg.relays[rUp].runtime_sec = (uint16_t)cmd.value;
      cfg.relays[rDown].runtime_sec = (uint16_t)cmd.value;
      ConfigManager::instance().saveRelayRuntime(rUp);
      ConfigManager::instance().saveRelayRuntime(rDown);
      _fsm[idx].setTiming((uint32_t)cmd.value * 1000UL, (uint32_t)cmd.value * 1000UL, SHUTTER_DEAD_TIME_MS, SHUTTER_OVERRUN_MS);
      printf("[PANJUR %u] Calisma suresi %ld sn olarak kaydedildi.\r\n", (unsigned)cmd.index, (long)cmd.value);
      break;
    }

    default:
      printf("[KOMUT] bilinmeyen komut tipi: %u\r\n", (unsigned)cmd.type);
      ok = false;
      break;
  }

  if (ok) {
    if (cmd.id[0] != '\0') {
      strncpy(_lastId, cmd.id, sizeof(_lastId) - 1);
      _lastId[sizeof(_lastId) - 1] = '\0';
    }
    markChanged();
  }
  return ok;
}

// Eski (doğrudan) çağrıların ortak yolu: loop görevinden çağrılırsa satır içi (eşzamanlı) yürütülür.
bool SmartAutomation::submit(const DeviceCommand& cmd) {
  if (_loopTask != nullptr && xTaskGetCurrentTaskHandle() == _loopTask) {
    const uint32_t now = millis();
    bool ok = executeCommand(cmd, now);
    stepOutputs(now);
    processShutterEvents(now);
    return ok;
  }
  return postDeviceCommand(cmd);
}

void SmartAutomation::setRelayState(uint8_t i, bool s) { submit(makeCommand(CmdType::RELAY_SET, CmdSource::WEB, (uint8_t)(i + 1), s ? 1 : 0)); }
void SmartAutomation::toggleRelay(uint8_t i)            { submit(makeCommand(CmdType::RELAY_TOGGLE, CmdSource::WEB, (uint8_t)(i + 1))); }
void SmartAutomation::shutterUp(uint8_t p)              { submit(makeCommand(CmdType::SHUTTER_UP, CmdSource::WEB, (uint8_t)(p + 1))); }
void SmartAutomation::shutterDown(uint8_t p)            { submit(makeCommand(CmdType::SHUTTER_DOWN, CmdSource::WEB, (uint8_t)(p + 1))); }
void SmartAutomation::shutterStop(uint8_t p)            { submit(makeCommand(CmdType::SHUTTER_STOP, CmdSource::WEB, (uint8_t)(p + 1))); }
void SmartAutomation::shutterStep(uint8_t p)            { submit(makeCommand(CmdType::SHUTTER_STEP, CmdSource::WEB, (uint8_t)(p + 1))); }
void SmartAutomation::setShutterPosition(uint8_t p, uint8_t pct) { submit(makeCommand(CmdType::SHUTTER_POS, CmdSource::WEB, (uint8_t)(p + 1), pct)); }
void SmartAutomation::allLightsOff()                    { submit(makeCommand(CmdType::ALL_LIGHTS_OFF, CmdSource::WEB)); }
void SmartAutomation::allShuttersDown()                 { submit(makeCommand(CmdType::ALL_SHUTTERS_DOWN, CmdSource::WEB)); }
void SmartAutomation::allShuttersUp()                   { submit(makeCommand(CmdType::ALL_SHUTTERS_UP, CmdSource::WEB)); }
void SmartAutomation::allShuttersStop()                 { submit(makeCommand(CmdType::ALL_SHUTTERS_STOP, CmdSource::WEB)); }

// ===============================================================================================
// PANJUR SARMALAYICI: FSM tik'i, olaylar, emniyet görevi geri bildirimi
// ===============================================================================================
void SmartAutomation::tickShutters(uint32_t now) {
  const uint8_t totalPairs = ConfigManager::instance().config.totalRelays() / 2;
  for (uint8_t p = 0; p < totalPairs && p < MAX_PAIRS; p++) {
    if (!_pairValid[p]) continue;
    _fsm[p].tick(now, pairHwOff(p));
  }
}

void SmartAutomation::processShutterEvents(uint32_t now) {
  for (uint8_t p = 0; p < MAX_PAIRS; p++) {
    const uint8_t ev = _fsm[p].takeEvents();
    if (ev == 0) continue;

    if ((ev & ShutterFsm::EV_STARTED) && _fsm[p].isMoving()) {
      printf("[PANJUR %u] %s baslatildi (Role %u ON, Sure: %u ms, Hedef: %%%u)\r\n",
             (unsigned)(p + 1), _fsm[p].dir() == ShutterFsm::DIR_UP ? "YUKARI" : "ASAGI",
             (unsigned)(2 * p + (_fsm[p].dir() == ShutterFsm::DIR_UP ? 1 : 2)),
             (unsigned)_fsm[p].durationMs(), (unsigned)_fsm[p].target());
      Buzzer_Open_Time(150, 0);
    }
    if (ev & ShutterFsm::EV_RETARGET) {
      printf("[PANJUR %u] Ayni yonde yeni hedef: %%%u (Sure: %u ms)\r\n", (unsigned)(p + 1),
             (unsigned)_fsm[p].target(), (unsigned)_fsm[p].durationMs());
    }
    if (ev & ShutterFsm::EV_DEAD_BEGIN) {
      if (_fsm[p].isWaiting()) {
        printf("[PANJUR %u INTERLOCK] Hareket kesildi! 500ms OLU ZAMAN (Dead-Time) -> %s kuyrukta.\r\n",
               (unsigned)(p + 1), _fsm[p].pendingDir() == ShutterFsm::DIR_UP ? "YUKARI" : "ASAGI");
      }
    }
    if (ev & ShutterFsm::EV_COMPLETED) {
      printf("[PANJUR %u SURE DOLDU] Hedef pozisyona ulasildi (%%%u).\r\n", (unsigned)(p + 1), (unsigned)_fsm[p].position(now));
    }
    if (ev & ShutterFsm::EV_START_FAILED) {
      printf("[PANJUR %u] HATA: role surucusu enerjilemeyi basaramadi, hareket IPTAL.\r\n", (unsigned)(p + 1));
      Relay_SignalFailure();
    }
    if ((ev & ShutterFsm::EV_STOPPED) && !(ev & ShutterFsm::EV_COMPLETED)) {
      printf("[PANJUR %u] DURDURULDU (Role %u & %u OFF, Son Pozisyon: %%%u)\r\n",
             (unsigned)(p + 1), (unsigned)(2 * p + 1), (unsigned)(2 * p + 2), (unsigned)_fsm[p].position(now));
      Buzzer_Open_Time(80, 0);
    }
    if (ev & ShutterFsm::EV_STOPPED) {
      _posDirty = true;
      _lastMotionMs = now;
    }

    // Bağımsız emniyet görevi için süre kurma/bozma: durum tabanlı (olay sırasından bağımsız). Süre, bu yönde
    // ENERJİLENDİĞİ andan sayılır: yeniden hedefleme (start_ms_ yeniden damgası) emniyet süresini UZATMAZ; üst sınır
    // "tam yol + oturma payı" (ShutterFsm::runCapMs).
    if (_fsm[p].isMoving()) {
      uint32_t planned = (uint32_t)(_fsm[p].startMs() - _fsm[p].runStartMs()) + _fsm[p].durationMs();
      if (planned > _fsm[p].runCapMs()) planned = _fsm[p].runCapMs();
      armGuard(p, _fsm[p].runStartMs(), planned + GUARD_MARGIN_MS);
    } else {
      disarmGuard(p);
    }
    markChanged();
  }
}

// Emniyet görevi bir panjuru zorla kestiyse FSM'i güvenli duruma getir.
void SmartAutomation::serviceGuardTrips(uint32_t now) {
  for (uint8_t p = 0; p < MAX_PAIRS; p++) {
    bool tripped;
    portENTER_CRITICAL(&s_guardMux);
    tripped = s_guard[p].tripped;
    s_guard[p].tripped = false;
    portEXIT_CRITICAL(&s_guardMux);
    if (!tripped) continue;

    printf("[EMNIYET] Panjur %u: emniyet gorevi roleleri kesti -> durum makinesi DURDURULUYOR.\r\n", (unsigned)(p + 1));
    _fsm[p].forceStop(now);
    _want[2 * p] = false;
    _want[2 * p + 1] = false;
    if (p < 4) {
      syncLocalHw(TCA_OutputShadow());
    } else {
      _hwKnown[2 * p] = false;          // harici röle durumu yeniden doğrulanacak (KAPAT yeniden gönderilir)
      _hwKnown[2 * p + 1] = false;
    }
    Relay_SignalFailure();
    markChanged();
  }
}

// ===============================================================================================
// DARBE (IMPULSE) RÖLELERİ  — süre karşılaştırması now - start >= dur (taşmaya dayanıklı)
// ===============================================================================================
void SmartAutomation::startImpulse(uint8_t i, uint32_t now) {
  uint16_t dur = ConfigManager::instance().config.relays[i].runtime_sec;   // ms
  if (dur == 0) dur = IMPULSE_MS_DEFAULT;
  _want[i] = true;
  _impulseActive[i] = true;
  _impulseStart[i] = now;
  _impulseDur[i] = dur;
}

void SmartAutomation::tickImpulses(uint32_t now) {
  const uint8_t totalR = ConfigManager::instance().config.totalRelays();
  for (uint8_t i = 0; i < totalR; i++) {
    if (_impulseActive[i] && (uint32_t)(now - _impulseStart[i]) >= _impulseDur[i]) {
      _impulseActive[i] = false;
      _want[i] = false;
      printf("Röle %u (Darbe): Sure doldu, kapatildi.\r\n", (unsigned)(i + 1));
    }
  }
}

// ===============================================================================================
// GİRİŞLER (DI): yerel 8 GPIO + RS485 ek modül girişleri. 60 ms kararlılık süzgeci.
// ===============================================================================================
void SmartAutomation::checkDigitalInputs(uint32_t now) {
  const uint8_t diPins[8] = {
    DIN_PIN_CH1, DIN_PIN_CH2, DIN_PIN_CH3, DIN_PIN_CH4,
    DIN_PIN_CH5, DIN_PIN_CH6, DIN_PIN_CH7, DIN_PIN_CH8
  };
  for (uint8_t i = 0; i < 8; i++) {
    handleDiEdge(i, digitalRead(diPins[i]) == LOW, now);   // LOW = kuru kontak DGND ile birleşti
  }
}

static_assert((int)digate::MODE_TOGGLE == (int)DI_MODE_TOGGLE && (int)digate::MODE_MOMENTARY == (int)DI_MODE_MOMENTARY &&
              (int)digate::MODE_SHUTTER_STEP == (int)DI_MODE_SHUTTER_STEP && (int)digate::MODE_SHUTTER_UP == (int)DI_MODE_SHUTTER_UP &&
              (int)digate::MODE_SHUTTER_DOWN == (int)DI_MODE_SHUTTER_DOWN, "DiGate.h mod degerleri ConfigManager.h DIMode ile ayni olmali");

// TEK KAPI: yerel ve ek modül girişleri buraya HAM örnek olarak gelir. DiGate (saf mantık) önce 60 ms
// kararlılık süzgecinden geçirir; kabul edilen her kenar için çocuk kilidi + "basış işlendi" kararını verir.
void SmartAutomation::handleDiEdge(uint8_t idx, bool closed, uint32_t now) {
  if (idx >= MAX_TOTAL_DIS) return;
  const digate::Edge e = _diGate.sample(idx, closed, now);
  if (e == digate::EDGE_NONE) return;

  auto& cfg = ConfigManager::instance().config;
  const DIConfig& d = cfg.dis[idx];
  markChanged();                                         // DI durumu değişti: state.dis[] hemen yayınlansın

  // Hedef panjur hareket ediyor/bekliyor mu? (kilitliyken duvardan DURDURMA kararı için)
  bool shutterActive = false;
  if (d.target_relay >= 1 && d.target_relay <= cfg.totalRelays()) {
    const uint8_t p = (uint8_t)((d.target_relay - 1) / 2);
    shutterActive = (p < MAX_PAIRS) && (_fsm[p].isMoving() || _fsm[p].isWaiting());
  }
  const digate::Decision dec = _diGate.decide(idx, e, d.mode, _childLockEnabled, shutterActive);
  runDiDecision(idx, dec, now);
}

void SmartAutomation::runDiDecision(uint8_t idx, const digate::Decision& dec, uint32_t now) {
  auto& cfg = ConfigManager::instance().config;
  const DIConfig& d = cfg.dis[idx];
  const bool pressed = (dec.edge == digate::EDGE_PRESS);

  if (pressed && dec.dropped) {
    // Çocuk kilidi bu basışı engelledi: kullanıcıya KISA TEK BİP (sessiz "bozuk anahtar" izlenimi olmasın).
    printf("[ÇOCUK KİLİDİ AKTİF] DI-%u kontak verdi ancak fiziksel anahtarlar kilitli! Role tetiklenmedi.\r\n", (unsigned)(idx + 1));
    Buzzer_Open_Time(60, 0);
    return;
  }

  // Hedef röle: basışta yapılandırmadan; BIRAKMADA basış anındaki hedef (yapılandırma arada değişse de aynı röle kapanır)
  uint8_t target = d.target_relay;                       // 1..totalR (0 = pasif)
  if (pressed) _diActTarget[idx] = target;
  else target = _diActTarget[idx];
  if (target < 1 || target > cfg.totalRelays()) return;
  const uint8_t pair1 = (uint8_t)((target - 1) / 2 + 1); // 1 tabanlı panjur çifti

  switch (dec.action) {
    case digate::RELAY_TOGGLE:  executeCommand(makeCommand(CmdType::RELAY_TOGGLE, CmdSource::DI, target), now); break;
    case digate::RELAY_ON:      executeCommand(makeCommand(CmdType::RELAY_SET, CmdSource::DI, target, 1), now); break;
    case digate::RELAY_OFF:     executeCommand(makeCommand(CmdType::RELAY_SET, CmdSource::DI, target, 0), now); break;
    case digate::SHUTTER_STEP:  executeCommand(makeCommand(CmdType::SHUTTER_STEP, CmdSource::DI, pair1), now); break;
    case digate::SHUTTER_UP:    executeCommand(makeCommand(CmdType::SHUTTER_UP, CmdSource::DI, pair1), now); break;
    case digate::SHUTTER_DOWN:  executeCommand(makeCommand(CmdType::SHUTTER_DOWN, CmdSource::DI, pair1), now); break;
    case digate::SHUTTER_STOP:  executeCommand(makeCommand(CmdType::SHUTTER_STOP, CmdSource::DI, pair1), now); break;
    default: return;
  }
  if (pressed) {
    printf("[DI-%u] Kuru Kontak Tetiklendi (DGND) -> Hedef Role-%u (Mod: %u)\r\n", (unsigned)(idx + 1), (unsigned)target, (unsigned)d.mode);
  } else {
    printf("[DI-%u] Buton Birakildi -> Hedef Role-%u KAPATILDI\r\n", (unsigned)(idx + 1), (unsigned)target);
  }
}

// ===============================================================================================
// FİZİKSEL ÇIKIŞ KATMANI
// ===============================================================================================
void SmartAutomation::syncLocalHw(uint8_t mask) {
  bool changed = false;
  for (uint8_t i = 0; i < 8; i++) {
    bool v = (mask >> i) & 1;
    if (_hw[i] != v) changed = true;
    _hw[i] = v;
    _hwKnown[i] = true;
  }
  if (changed) markChanged();
}

void SmartAutomation::stepOutputs(uint32_t now) {
  auto& cfg = ConfigManager::instance().config;
  const uint8_t totalR = cfg.totalRelays();

  // 1) İstenen durum: geçerli panjur çiftlerinde FSM çıkışı; panjur tipli ama eşi olmayan (yetim) röleler HER ZAMAN kapalı.
  for (uint8_t i = 0; i < totalR; i++) {
    const uint8_t t = cfg.relays[i].type;
    if (t == RELAY_TYPE_SHUTTER_UP || t == RELAY_TYPE_SHUTTER_DOWN) {
      const uint8_t p = i / 2;
      if (_pairValid[p]) {
        const uint8_t m = _fsm[p].outMask();       // 0, 1 (YUKARI) veya 2 (AŞAĞI): ASLA 3
        _want[i] = (i % 2 == 0) ? ((m & ShutterFsm::OUT_UP) != 0) : ((m & ShutterFsm::OUT_DOWN) != 0);
      } else {
        _want[i] = false;
      }
    }
  }

  stepLocalOutputs(now);
  stepExtOutputs(now);
}

// Sürücü eşitlemede (çip sıfırlanması / düşen röle; periyodik TCA_Verify ya da yazım ön denetimi) "gölgede AÇIK sanılıp fiziksel olarak
// KAPALI bulunan" röleler bildirdiyse: bu bitlere ait HAREKET EDEN panjurlar durdurulur (konum takibi geçersiz) ve bilinen durum
// donanımla eşitlenir. Düşen röleler sürücüde YENİDEN ÇEKİLMEZ; lamba gibi istenen röleler normal akışla (want) yeniden yazılır.
void SmartAutomation::handleLocalDrops(uint32_t now) {
  const uint8_t dropped = TCA_TakeDroppedMask();
  if (dropped == 0) return;
  for (uint8_t p = 0; p < 4; p++) {
    if (((dropped >> (2 * p)) & 3) == 0) continue;
    if (_pairValid[p] && (_fsm[p].isMoving() || _fsm[p].isWaiting())) _fsm[p].forceStop(now);
  }
  printf("[TCA] Role(ler) dustu/sifirlandi (maske 0x%02X) -> etkilenen yerel panjurlar DURDURULDU.\r\n", (unsigned)dropped);
  syncLocalHw(TCA_OutputShadow());
  markChanged();
}

void SmartAutomation::stepLocalOutputs(uint32_t now) {
  uint8_t wantLocal = 0;
  for (uint8_t i = 0; i < 8; i++) if (_want[i]) wantLocal |= (uint8_t)(1u << i);

  const uint8_t shadow = TCA_OutputShadow();
  if (wantLocal == shadow) {
    _localFails = 0;
    _localRetryGap = 0;
    return;
  }
  if ((uint32_t)(now - _localRetryLast) < _localRetryGap) return;   // başarısız/ertelenmiş yazımdan sonra kısa bekleme

  const TcaWriteResult wr = TCA_WriteOutputsEx(wantLocal);
  handleLocalDrops(now);          // yazım ön denetimi gölgeyi donanıma eşitlediyse etkilenen panjurlar durdurulur
  if (wr == TCA_WRITE_OK) {
    _localFails = 0;
    _localRetryGap = 0;
    syncLocalHw(TCA_OutputShadow());   // gerçekte yazılan (düşen bitler çıkarılmış olabilir; onlar sonraki turda normal akışla yazılır)
    return;
  }
  if (wr == TCA_WRITE_DEAD_TIME) {                 // sürücü ölü zamanı henüz dolmadı: hata DEĞİL, kısa süre bekle
    _localRetryLast = now;
    _localRetryGap = 20;
    return;
  }

  // YAZIM BAŞARISIZ (I2C hatası ya da sürücü interlock'u reddetti).
  _localFails++;
  _localRetryLast = now;
  _localRetryGap = 100;
  Relay_SignalFailure();
  // GÜVENLİ DURUM: yalnızca KAPATMA bitlerini uygula; hiçbir şey yeni açılmasın. (Ön denetim gölgeyi değiştirmiş olabilir: taze oku.)
  const uint8_t shadowNow = TCA_OutputShadow();
  const uint8_t safe = (uint8_t)(shadowNow & wantLocal);
  if (safe != shadowNow) TCA_WriteOutputs(safe);
  handleLocalDrops(now);
  const uint8_t after = TCA_OutputShadow();
  // Enerjilenmesi istenip uygulanamayan panjurları iptal et (konum bozulmasın)
  for (uint8_t p = 0; p < 4; p++) {
    const uint8_t wantBits = (wantLocal >> (2 * p)) & 3;
    const uint8_t hwBits = (after >> (2 * p)) & 3;
    if (_pairValid[p] && _fsm[p].isMoving() && wantBits != 0 && hwBits == 0) {
      _fsm[p].onEnergizeFailed(now);
    }
  }
  syncLocalHw(after);
}

// Ardışık başarısız yazım sayısına göre geri çekilme: 100, 200, 400, 800, 1600 ms (en çok 1,6 sn).
static uint32_t extBackoffMs(uint32_t fails) {
  return (fails > 5) ? 1600UL : (50UL << fails);
}

// Harici modül röleleri: önce KAPATMALAR, sonra AÇMALAR (panjur rölesi için eşin KAPALI doğrulanması şart).
// SAAT KURALI: bir RS485 işlemi 10-140 ms sürer. Sürücü ölü zamanı (_extGuard) için damga ve denetim GERÇEK anla
// (millis()) yapılır, tur başı `now` ile DEĞİL: aksi halde aynı turdaki ikinci işlemin kapanması "erken" damgalanır
// (ölü zaman kısalır) ve damga `now`'dan sonraya düşerse uint32 farkı taşıp ölü zaman "doldu" sayılırdı.
void SmartAutomation::stepExtOutputs(uint32_t now) {
  auto& cfg = ConfigManager::instance().config;
  const uint8_t totalR = cfg.totalRelays();
  if (!cfg.ext_module_enabled || totalR <= 8) return;
  if (_scanState == ScanState::RUNNING) return;                 // tarama hattı tutuyor
  if ((uint32_t)(now - _extRetryLast) < _extRetryGap) return;   // geri çekilme (başarısız yazımdan sonra)

  int budget = 2;                                             // tur başına en çok 2 RS485 yazımı
  const uint8_t slave = cfg.ext_module_address;
  // Modül yanıt VERMİYORSA tek deneme + kısa zaman aşımı: ana döngü (panjur zamanlayıcıları, butonlar) en fazla ~50 ms takılır.
  // (Cevap ~12-20 ms'de gelir; 70 ms bolca pay: en kotu tur 2x70 = 140 ms.)
  const uint8_t attempts = _extModuleResponding ? 2 : 1;
  const uint32_t tmo = _extModuleResponding ? 70UL : 50UL;

  // 1. geçiş: KAPATMALAR (güvenli yön: hiçbir kural engellemez)
  for (uint8_t i = 8; i < totalR && budget > 0; i++) {
    // KAPAT gerekir mi? (saf kural: relayrules::extNeedsOffWrite). Ham TOGGLE sonrası benimse-bekleyen röle KAPATILMAZ:
    // aksi halde TOGGLE ile açılan röle benimsenmeden ~10-20 ms içinde geri kapatılırdı.
    if (!relayrules::extNeedsOffWrite(_want[i], _hw[i], _hwKnown[i], _adoptNextPoll[i])) continue;
    budget--;
    const uint8_t ch = (uint8_t)(i - 8 + 1);
    if (extWriteCoil(slave, ch, modbus::COIL_OFF, 20, nullptr, attempts, tmo)) {
      _extWriteFails = 0;
      _extRetryGap = 0;
      _hw[i] = false;
      _hwKnown[i] = true;
      const uint32_t tw = millis();   // GERÇEK an (aşağıdaki saat kuralına bakın)
      _extGuard.commit(InterlockGuard::withRelay(_extGuard.hw(), i, false), tw);
      _extGuard.noteOff(i, tw);       // onaylı KAPAT: ölü zaman GERÇEK kapanmadan sayılır (inanç yanlış olsa bile)
      markChanged();
    } else {
      _hwKnown[i] = false;                                      // belirsiz: tekrar denenecek, eşin açılması engellenir
      _extWriteFails++;
      _extRetryLast = millis();                                 // geri çekilme başarısız işlemin BİTİŞİNDEN sayılır
      _extRetryGap = extBackoffMs(_extWriteFails);
      return;
    }
  }

  // 2. geçiş: AÇMALAR
  for (uint8_t i = 8; i < totalR && budget > 0; i++) {
    if (!_want[i] || _hw[i]) continue;
    const uint8_t p = i / 2;
    const bool isShutterRelay = (cfg.relays[i].type == RELAY_TYPE_SHUTTER_UP || cfg.relays[i].type == RELAY_TYPE_SHUTTER_DOWN);

    // "Eşi KAPALI DOĞRULANMADAN panjur rölesi AÇILMAZ": teyit yoksa hiçbir şey gönderme, bekle.
    if (isShutterRelay && _pairValid[p] && !pairHwOff(p)) continue;

    // Sürücü seviyesi kural (InterlockGuard). Eş doğrulanmış KAPALI ise guard'ın bayat "AÇIK" bitini temizle.
    const uint8_t peer = (uint8_t)(i ^ 1);
    if (isShutterRelay && !_hw[peer] && _hwKnown[peer] && ((_extGuard.hw() >> peer) & 1ULL)) {
      _extGuard.commit(InterlockGuard::withRelay(_extGuard.hw(), peer, false), millis());
    }
    const uint64_t newMask = InterlockGuard::withRelay(_extGuard.hw(), i, true);
    const InterlockGuard::Result r = _extGuard.check(newMask, millis());
    if (r == InterlockGuard::DEAD_TIME) continue;               // bekle (FSM zaten ≥500 ms bekler)
    if (r != InterlockGuard::OK) {
      printf("[EXT INTERLOCK] Role %u acilmasi REDDEDILDI (%s) -> hareket iptal.\r\n", (unsigned)(i + 1), InterlockGuard::resultText(r));
      if (isShutterRelay && _pairValid[p] && _fsm[p].isMoving()) _fsm[p].onEnergizeFailed(now);
      _want[i] = false;
      continue;
    }

    // Panjur: "eş KAPALI" bilgisi yazma yankısına dayanıyor; AÇMADAN hemen önce modülün GERÇEK coil durumu okunur
    // (yankı yanlış olabilir ya da başka bir master coil'i açmış olabilir). Okuma + yazma birlikte 2 işlem bütçesi alır.
    if (isShutterRelay && _pairValid[p]) {
      if (budget < 2) break;                                    // bu turda sığmıyor: sonraki turda
      budget--;
      const ExtReadback rb = extReadbackBeforeEnergize(slave, i);
      if (rb == RB_PEER_ON || rb == RB_ALREADY_ON) {            // eş (ya da kendisi) gerçekte AÇIK: hareket iptal, bir sonraki turda KAPATILIR
        if (_fsm[p].isMoving()) _fsm[p].onEnergizeFailed(now);
        _want[i] = false;
        continue;
      }
      if (rb == RB_READ_FAILED) {                               // modül okunamadı: yazma başarısızlığıyla aynı işlem
        _extWriteFails++;
        _extRetryLast = millis();                                 // geri çekilme başarısız işlemin BİTİŞİNDEN sayılır
        _extRetryGap = extBackoffMs(_extWriteFails);
        if (_fsm[p].isMoving()) _fsm[p].onEnergizeFailed(now);
        _want[i] = false;
        return;
      }
    }

    budget--;
    const uint8_t ch = (uint8_t)(i - 8 + 1);
    if (extWriteCoil(slave, ch, modbus::COIL_ON, 20, nullptr, attempts, tmo)) {
      _extWriteFails = 0;
      _extRetryGap = 0;
      _hw[i] = true;
      _hwKnown[i] = true;
      _extGuard.commit(newMask, millis());
      markChanged();
    } else {
      _extWriteFails++;
      _extRetryLast = millis();                                 // geri çekilme başarısız işlemin BİTİŞİNDEN sayılır
      _extRetryGap = extBackoffMs(_extWriteFails);
      if (isShutterRelay && _pairValid[p]) {
        // Panjur: enerjileme olmadı -> hareketi iptal et (konum bozulmasın), tekrar denemeyiz
        if (_fsm[p].isMoving()) _fsm[p].onEnergizeFailed(now);
        _want[i] = false;
      }
      return;
    }
  }
}

// Hepsini kapat (acil/yeniden başlatma): yerel anında, harici en iyi çabayla.
void SmartAutomation::emergencyAllOff() {
  const uint32_t now = millis();
  for (uint8_t p = 0; p < MAX_PAIRS; p++) {
    if (_fsm[p].isMoving() || _fsm[p].isWaiting()) _fsm[p].forceStop(now);
    disarmGuard(p);
  }
  for (int i = 0; i < MAX_TOTAL_RELAYS; i++) { _want[i] = false; _impulseActive[i] = false; }
  if (TCA_WriteOutputs(0x00)) syncLocalHw(0x00);
  auto& cfg = ConfigManager::instance().config;
  if (cfg.ext_module_enabled && cfg.totalRelays() > 8) extAllOff();
}

// ===============================================================================================
// SİSTEM: planlı yeniden başlatma
// ===============================================================================================
static void (*s_preRestartHooks[4])() = {nullptr, nullptr, nullptr, nullptr};

bool SmartAutomation::registerPreRestartHook(void (*fn)()) {
  if (!fn) return false;
  for (int i = 0; i < 4; i++) {
    if (s_preRestartHooks[i] == fn) return true;
    if (s_preRestartHooks[i] == nullptr) {
      s_preRestartHooks[i] = fn;
      return true;
    }
  }
  return false;
}

void SmartAutomation::requestRestart(uint32_t delayMs) {
  if (_restartPending) return;
  _restartAt = millis() + delayMs;
  _restartPending = true;
  // Hareket eden panjurlar HEMEN durdurulur (çağrı anında kuyruğa değil, acil bayrağına); yeni hareket komutları reddedilir.
  s_emergencyStopAll = true;
  printf("[SISTEM] Planli yeniden baslatma istendi (%u ms sonra).\r\n", (unsigned)delayMs);
}

void SmartAutomation::performRestart() {
  emergencyAllOff();
  persistPositions(millis(), true);
  for (int i = 0; i < 4; i++) if (s_preRestartHooks[i]) s_preRestartHooks[i]();
  printf("[SISTEM] Roleler kapatildi, konumlar kaydedildi -> yeniden baslatiliyor.\r\n");
  Serial.flush();
  ESP.restart();     // esp_restart() -> shutdownHandler() röleleri bir kez daha kapatır
}

// ===============================================================================================
// ANA DÖNGÜ (Core 1 / loopTask)
// ===============================================================================================
void SmartAutomation::loop() {
  const uint32_t now = millis();

  if (_bootHoldActive) {                          // açılış bekleme penceresi (bkz. begin()); bir kez kapanır
    if ((uint32_t)(now - _bootAt) < 500UL) {
      publishSnapshot(now);
      return;
    }
    _bootHoldActive = false;
  }

  // Planlı yeniden başlatma süresi doldu mu? (delay() YOK; sonraki turda uygulanır)
  if (_restartPending) {
    if (s_emergencyStopAll) {
      s_emergencyStopAll = false;
      for (uint8_t p = 0; p < MAX_PAIRS; p++) if (_pairValid[p]) _fsm[p].cmdStop(now);
    }
    stepOutputs(now);
    processShutterEvents(now);
    if ((int32_t)(now - _restartAt) >= 0) performRestart();
    publishSnapshot(now);
    return;
  }

  serviceGuardTrips(now);                 // emniyet görevi bir şeyi kestiyse FSM'i güvenli duruma getir
  syncConfig(now);                        // yapılandırma değişimi (geçerlilik/süre/interlock maskeleri)
  tickShutters(now);                      // FSM: süre dolumu, ölü zaman, bekleyen yön (sürücü teyidiyle)
  drainCommands(now);                     // kuyruk (MQTT/Web/CLI)
  applyRawExtAllOff(now);                 // ham toplu KAPAT (0x00FF) yansıtma isteği
  tickImpulses(now);
  checkDigitalInputs(now);                // yerel DI (ek modül DI'ları pollExtModule içinde örneklenir)
  stepOutputs(now);                       // FSM çıkışını + istenen durumu sürücüye uygula (tek yer)
  processShutterEvents(now);              // loglar, buzzer, emniyet görevi kurma/bozma, konum kirli bayrağı
  pollExtModule(now);                     // RS485 ek modül girişleri/coil okuması (sınırlı sürede)
  checkRs485Incoming();

  // Yerel çıkış yazmacı doğrulaması (çip sıfırlanması / düşen röle / beklenmeyen bit): 2 sn'de bir. Röle açık bırakacak her yazım
  // ayrıca ön denetimle aynı eşitlemeyi yapar (WS_TCA9554PWR.cpp); burada bekleyen yazım olmasa da hata en geç 2 sn'de görülür.
  if ((uint32_t)(now - _lastTcaVerify) >= TCA_VERIFY_PERIOD_MS) {
    _lastTcaVerify = now;
    const TcaVerifyResult v = TCA_Verify();
    if (v == TCA_VERIFY_RESET) {
      printf("[TCA] Cikis latch'i beklenmedik sekilde degismis -> etkilenen yerel panjurlar DURDURULUYOR.\r\n");
    }
    handleLocalDrops(now);
    if (v == TCA_VERIFY_RESET || v == TCA_VERIFY_FIXED) syncLocalHw(TCA_OutputShadow());
  }

  persistPositions(now, false);           // hareket bittikten ~8 sn sonra, tek yazım

  // Hareket sürerken konum ~1 sn'de bir yayınlanır (uygulamada ilerleme çubuğu); durağanken yayın yok.
  bool anyMoving = false;
  for (uint8_t p = 0; p < MAX_PAIRS; p++) if (_fsm[p].isMoving()) { anyMoving = true; break; }
  if (anyMoving && (uint32_t)(now - _lastMovePublish) >= 1000) {
    _lastMovePublish = now;
    markChanged();
  }

  publishSnapshot(now);
  if (_stateChanged) {
    _stateChanged = false;
    MqttManager::instance().triggerPublish();
  }
}

// ===============================================================================================
// ANLIK GÖRÜNTÜ (iş parçacığı güvenli okuma)
// ===============================================================================================
void SmartAutomation::publishSnapshot(uint32_t now) {
  if (_snapMutex == nullptr) return;
  auto& cfg = ConfigManager::instance().config;
  AutomationSnapshot next;
  memset(&next, 0, sizeof(next));
  next.totalRelays = cfg.totalRelays();
  next.totalPairs = next.totalRelays / 2;
  next.totalDIs = cfg.totalDIs();
  next.childLock = _childLockEnabled;
  next.extModuleResponding = cfg.ext_module_enabled && _extModuleResponding;
  strncpy(next.lastId, _lastId, sizeof(next.lastId) - 1);

  for (int i = 0; i < MAX_TOTAL_RELAYS; i++) if (_hw[i]) next.relayMask |= (1ULL << i);
  for (int i = 0; i < MAX_TOTAL_DIS; i++) if (_diGate.stable((uint8_t)i)) next.diMask |= (1ULL << i);
  for (int p = 0; p < MAX_PAIRS; p++) {
    ShutterSnapshot& s = next.shutters[p];
    s.pos = _fsm[p].position(now);
    s.moving = _fsm[p].isMoving();
    s.dir = _fsm[p].dir();
    s.target = _fsm[p].target();
    s.waiting = _fsm[p].isWaiting();
    s.pendingDir = _fsm[p].pendingDir();
    s.lastDir = _fsm[p].lastDir();
    s.configured = _pairValid[p];
  }

  if (xSemaphoreTake(_snapMutex, pdMS_TO_TICKS(5)) != pdTRUE) return;   // bir sonraki turda yeniden denenir
  next.seq = _snap.seq;
  const bool changed = memcmp(&_snap.relayMask, &next.relayMask, sizeof(next) - offsetof(AutomationSnapshot, relayMask)) != 0 ||
                       _snap.childLock != next.childLock || strcmp(_snap.lastId, next.lastId) != 0 ||
                       _snap.totalRelays != next.totalRelays || _snap.totalDIs != next.totalDIs ||
                       _snap.extModuleResponding != next.extModuleResponding;
  if (changed) next.seq = _snap.seq + 1;
  _snap = next;
  xSemaphoreGive(_snapMutex);
}

bool SmartAutomation::getSnapshot(AutomationSnapshot& out) const {
  if (_snapMutex == nullptr) return false;
  if (xSemaphoreTake(_snapMutex, pdMS_TO_TICKS(20)) != pdTRUE) return false;
  out = _snap;
  xSemaphoreGive(_snapMutex);
  return true;
}

bool SmartAutomation::getShutterSnapshot(uint8_t pairIndex, ShutterSnapshot& out) const {
  if (pairIndex >= MAX_PAIRS) return false;
  if (_snapMutex == nullptr) return false;
  if (xSemaphoreTake(_snapMutex, pdMS_TO_TICKS(20)) != pdTRUE) return false;
  out = _snap.shutters[pairIndex];
  xSemaphoreGive(_snapMutex);
  return true;
}

uint64_t SmartAutomation::getRelayMask() const {
  AutomationSnapshot s;
  if (!getSnapshot(s)) return 0;
  return s.relayMask;
}

bool SmartAutomation::getRelaySnapshot(uint8_t relayIndex) const {
  if (relayIndex >= MAX_TOTAL_RELAYS) return false;
  return (getRelayMask() >> relayIndex) & 1ULL;
}

bool SmartAutomation::getRelayState(uint8_t relayIndex) const {
  return getRelaySnapshot(relayIndex);
}

uint8_t SmartAutomation::getShutterPosition(uint8_t pairIndex) const {
  ShutterSnapshot s;
  if (!getShutterSnapshot(pairIndex, s)) return 0;
  return s.pos;
}

ShutterState SmartAutomation::getShutterState(uint8_t pairIndex) const {
  ShutterState st = {false, 0, 0, 0, 0, 0, 0, 0, 255, 0};
  ShutterSnapshot s;
  if (!getShutterSnapshot(pairIndex, s)) return st;
  st.is_moving = s.moving;
  st.direction = s.dir;
  st.last_direction = s.lastDir;
  st.pending_direction = s.pendingDir;
  st.current_position = s.pos;
  st.target_position = s.target;
  st.start_position = s.pos;
  return st;
}

bool SmartAutomation::getDIState(uint8_t diIndex) const {
  if (diIndex >= MAX_TOTAL_DIS) return false;
  AutomationSnapshot s;
  if (!getSnapshot(s)) return false;
  return s.di(diIndex);
}
