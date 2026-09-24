#include "SmartAutomation.h"
#include "WS_Relay.h"
#include "WS_DIN.h"
#include "WS_GPIO.h"
#include <HardwareSerial.h>
#include "MqttManager.h"

SmartAutomation& SmartAutomation::instance() {
  static SmartAutomation instance;
  return instance;
}

SmartAutomation::SmartAutomation() : _rs485LogCount(0), _lastExtModulePoll(0), _lastExtCoilPoll(0), _extModuleResponding(false) {
  for (int i = 0; i < MAX_TOTAL_RELAYS; i++) {
    _relayStates[i] = false;
    _impulseEndTime[i] = 0;
  }
  for (int i = 0; i < MAX_TOTAL_DIS; i++) {
    _diStates[i] = false;
    _diLastPressTime[i] = 0;
  }
  for (int i = 0; i < MAX_TOTAL_RELAYS / 2; i++) {
    _shutters[i].is_moving = false;
    _shutters[i].direction = 0;
    _shutters[i].last_direction = 0;
    _shutters[i].start_time = 0;
    _shutters[i].duration_ms = 20000;
    _shutters[i].pending_direction = 0;
    _shutters[i].dead_time_start = 0;
    _shutters[i].current_position = 0;
    _shutters[i].target_position = 255;
    _shutters[i].start_position = 0;
  }
  _childLockEnabled = false;
}

void SmartAutomation::setChildLock(bool enabled) {
  _childLockEnabled = enabled;
  Preferences prefs;
  if (prefs.begin("ahbu_auto", false)) {
    prefs.putBool("child_lock", enabled);
    prefs.end();
  }
  printf("[ÇOCUK KİLİDİ] Durum güncellendi: %s\r\n", enabled ? "AKTİF (Duvardaki Anahtarlar Kilitli)" : "PASİF (Normal)");
  Buzzer_Open_Time(enabled ? 200 : 100, 0);
}

void SmartAutomation::loadShutterPositions() {
  Preferences prefs;
  prefs.begin("ahbu_pos", true);
  for (int i = 0; i < MAX_TOTAL_RELAYS / 2; i++) {
    char key[16];
    snprintf(key, sizeof(key), "sh_pos_%d", i);
    _shutters[i].current_position = prefs.getUChar(key, 0);
    _shutters[i].start_position = _shutters[i].current_position;
    _shutters[i].target_position = 255;
  }
  prefs.end();
  printf("SmartAutomation: Panjur pozisyonlari NVS'den yuklendi.\r\n");
}

void SmartAutomation::saveShutterPosition(uint8_t pairIndex) {
  if (pairIndex >= (MAX_TOTAL_RELAYS / 2)) return;
  Preferences prefs;
  prefs.begin("ahbu_pos", false);
  char key[16];
  snprintf(key, sizeof(key), "sh_pos_%d", pairIndex);
  prefs.putUChar(key, _shutters[pairIndex].current_position);
  prefs.end();
}

void SmartAutomation::begin() {
  // Giriş pinlerini PULLUP ile hazırla (Yerel 8 DI)
  const uint8_t diPins[8] = {
    DIN_PIN_CH1, DIN_PIN_CH2, DIN_PIN_CH3, DIN_PIN_CH4,
    DIN_PIN_CH5, DIN_PIN_CH6, DIN_PIN_CH7, DIN_PIN_CH8
  };
  for (int i = 0; i < 8; i++) {
    pinMode(diPins[i], INPUT_PULLUP);
    _diStates[i] = (digitalRead(diPins[i]) == LOW);
  }

  // RS485 Seri Portunu Başlat
  rs485Begin(ConfigManager::instance().config.rs485_baud);

  // Panjur pozisyonlarını NVS'den yükle (Panjurlar KESİNLİKLE hareket ettirilmez)
  loadShutterPositions();

  // ADIM 15: Power-On State (Elektrik Kesintisi Güvenliği):
  // Gece elektrik kesilip geri geldiğinde (Power Restore), lambaların varsayılan durumu KESİNLİKLE KAPALI (OFF) kalır.
  // Panjurlar hareket etmez (is_moving = false, direction = 0).
  uint8_t totalR = ConfigManager::instance().config.totalRelays();
  for (int i = 0; i < totalR; i++) {
    applyPhysicalRelay(i, false);
  }
  for (int p = 0; p < MAX_TOTAL_RELAYS / 2; p++) {
    _shutters[p].is_moving = false;
    _shutters[p].direction = 0;
    _shutters[p].pending_direction = 0;
  }

  // ADIM 17: Çocuk Kilidi NVS'den yükle
  Preferences childPrefs;
  if (childPrefs.begin("ahbu_auto", true)) {
    _childLockEnabled = childPrefs.getBool("child_lock", false);
    childPrefs.end();
  }
  if (_childLockEnabled) {
    printf("SmartAutomation: [ÇOCUK KİLİDİ AKTİF] Duvardaki anahtarlar kilitli baslatildi.\r\n");
  }

  printf("SmartAutomation: [POWER-ON RESTORE] Tum lambalar KESINLIKLE KAPALI (OFF), panjurlar hareketsiz baslatildi (Toplam Röle: %d, DI: %d).\r\n",
         totalR, ConfigManager::instance().config.totalDIs());
}

void SmartAutomation::applyPhysicalRelay(uint8_t relayIndex, bool state) {
  if (relayIndex >= MAX_TOTAL_RELAYS) return;

  if (state) {
    // HARD INTERLOCK KORUMASI:
    // Eğer bu röle bir panjur çiftine aitse, eşinin (diğer yön) KESİNLİKLE kapalı olduğunu garanti et.
    uint8_t peerIndex = (relayIndex % 2 == 0) ? (relayIndex + 1) : (relayIndex - 1);
    if (peerIndex < MAX_TOTAL_RELAYS) {
      auto& cfgThis = ConfigManager::instance().config.relays[relayIndex];
      auto& cfgPeer = ConfigManager::instance().config.relays[peerIndex];
      bool isShutterPair = (cfgThis.type == RELAY_TYPE_SHUTTER_UP && cfgPeer.type == RELAY_TYPE_SHUTTER_DOWN) ||
                           (cfgThis.type == RELAY_TYPE_SHUTTER_DOWN && cfgPeer.type == RELAY_TYPE_SHUTTER_UP);
      if (isShutterPair && _relayStates[peerIndex]) {
        printf("[HARD INTERLOCK] HATA: Role %d acilirken zit yon Role %d acikti! Diger yon aninda kapatildi.\r\n",
               relayIndex + 1, peerIndex + 1);
        _relayStates[peerIndex] = false;
        if (peerIndex < 8) {
          Relay_CHx(peerIndex + 1, false);
        }
      }
    }
  }

  _relayStates[relayIndex] = state;

  if (relayIndex < 8) {
    // 0..7: Yerel Waveshare Röleleri (TCA9554)
    Relay_CHx(relayIndex + 1, state);
  } else {
    // 8..39: Harici RS485 Genişletme Modülü Röleleri
    auto& cfg = ConfigManager::instance().config;
    if (cfg.ext_module_enabled) {
      uint8_t extCh = (relayIndex - 8) + 1; // 1-tabanlı kanal
      rs485ControlExtRelay(cfg.ext_module_address, extCh, state ? 1 : 0);
    }
  }

  // MQTT durum raporu güncellemesini tetikle
  MqttManager::instance().triggerPublish();
}

bool SmartAutomation::getRelayState(uint8_t relayIndex) {
  if (relayIndex >= MAX_TOTAL_RELAYS) return false;
  return _relayStates[relayIndex];
}

void SmartAutomation::setRelayState(uint8_t relayIndex, bool state) {
  if (relayIndex >= 8) return;
  uint8_t totalR = ConfigManager::instance().config.totalRelays();
  if (relayIndex >= totalR) return;

  auto& cfg = ConfigManager::instance().config.relays[relayIndex];

  // Panjur kontrolü ise interlock kurallarını işlet
  if (cfg.type == RELAY_TYPE_SHUTTER_UP || cfg.type == RELAY_TYPE_SHUTTER_DOWN) {
    uint8_t pairIdx = relayIndex / 2;
    if (state) {
      if (cfg.type == RELAY_TYPE_SHUTTER_UP) shutterUp(pairIdx);
      else shutterDown(pairIdx);
    } else {
      shutterStop(pairIdx);
    }
    return;
  }

  // Darbe (Impulse) kontrolü
  if (cfg.type == RELAY_TYPE_IMPULSE) {
    if (state) {
      applyPhysicalRelay(relayIndex, true);
      uint16_t dur = cfg.runtime_sec > 0 ? cfg.runtime_sec : 1000;
      _impulseEndTime[relayIndex] = millis() + dur;
      Buzzer_Open_Time(100, 0);
    } else {
      applyPhysicalRelay(relayIndex, false);
      _impulseEndTime[relayIndex] = 0;
    }
    return;
  }

  // Normal Lamba Aç / Kapa
  applyPhysicalRelay(relayIndex, state);
  Buzzer_Open_Time(80, 0);
}

void SmartAutomation::toggleRelay(uint8_t relayIndex) {
  if (relayIndex >= 8) return;
  uint8_t totalR = ConfigManager::instance().config.totalRelays();
  if (relayIndex >= totalR) return;
  auto& cfg = ConfigManager::instance().config.relays[relayIndex];

  if (cfg.type == RELAY_TYPE_SHUTTER_UP || cfg.type == RELAY_TYPE_SHUTTER_DOWN) {
    uint8_t pairIdx = relayIndex / 2;
    if (_shutters[pairIdx].is_moving) {
      shutterStop(pairIdx);
    } else {
      if (cfg.type == RELAY_TYPE_SHUTTER_UP) shutterUp(pairIdx);
      else shutterDown(pairIdx);
    }
    return;
  }

  setRelayState(relayIndex, !_relayStates[relayIndex]);
}

void SmartAutomation::updateShutterPosition(uint8_t pairIndex) {
  if (pairIndex >= (MAX_TOTAL_RELAYS / 2)) return;
  if (!_shutters[pairIndex].is_moving) return;

  uint8_t rUp = pairIndex * 2;
  uint8_t rDown = rUp + 1;
  uint32_t now = millis();
  uint32_t elapsed = now - _shutters[pairIndex].start_time;

  if (_shutters[pairIndex].direction == 1) {
    // YUKARI (Açılıyor: 0 -> 100)
    uint32_t tUp = ConfigManager::instance().config.relays[rUp].runtime_sec * 1000UL;
    if (tUp == 0) tUp = 20000;

    uint32_t deltaPct = (elapsed * 100UL) / tUp;
    int newPos = (int)_shutters[pairIndex].start_position + (int)deltaPct;
    if (newPos > 100) newPos = 100;
    _shutters[pairIndex].current_position = (uint8_t)newPos;
  } else if (_shutters[pairIndex].direction == 2) {
    // AŞAĞI (Kapanıyor: 100 -> 0)
    uint32_t tDown = ConfigManager::instance().config.relays[rDown].runtime_sec * 1000UL;
    if (tDown == 0) tDown = 20000;

    uint32_t deltaPct = (elapsed * 100UL) / tDown;
    int newPos = (int)_shutters[pairIndex].start_position - (int)deltaPct;
    if (newPos < 0) newPos = 0;
    _shutters[pairIndex].current_position = (uint8_t)newPos;
  }
}

uint8_t SmartAutomation::getShutterPosition(uint8_t pairIndex) {
  if (pairIndex >= (MAX_TOTAL_RELAYS / 2)) return 0;
  updateShutterPosition(pairIndex);
  return _shutters[pairIndex].current_position;
}

void SmartAutomation::shutterUp(uint8_t pairIndex) {
  if (pairIndex >= (MAX_TOTAL_RELAYS / 2)) return;
  uint8_t rUp = pairIndex * 2;
  uint8_t rDown = rUp + 1;
  uint32_t now = millis();

  // 1. ZIT YÖN KONTROLÜ (Panjur şu anda AŞAĞI hareket ediyorsa):
  if (_shutters[pairIndex].direction == 2) {
    applyPhysicalRelay(rDown, false);
    updateShutterPosition(pairIndex);
    _shutters[pairIndex].is_moving = false;
    _shutters[pairIndex].direction = 0;
    _shutters[pairIndex].pending_direction = 1; // 1: YUKARI beklemede
    _shutters[pairIndex].dead_time_start = now;
    printf("[PANJUR %d INTERLOCK] ASAGI kesildi! 500ms OLU ZAMAN (Dead-Time) baslatildi -> YUKARI kuyrukta.\r\n", pairIndex + 1);
    Buzzer_Open_Time(50, 0);
    return;
  }

  // 2. ÖLÜ ZAMAN KONTROLÜ (Motor durmuş fakat son hareketten bu yana 500 ms geçmediyse):
  if (_shutters[pairIndex].dead_time_start > 0 && (now - _shutters[pairIndex].dead_time_start < SHUTTER_DEAD_TIME_MS)) {
    applyPhysicalRelay(rDown, false);
    _shutters[pairIndex].pending_direction = 1;
    printf("[PANJUR %d DEAD-TIME] Son hareketten sonra %u ms gecti (<500ms), YUKARI bekletiliyor.\r\n", 
           pairIndex + 1, (unsigned int)(now - _shutters[pairIndex].dead_time_start));
    return;
  }

  // 3. Emniyetli durum: Ölü zaman doldu veya motor hareketsizdi.
  applyPhysicalRelay(rDown, false);
  applyPhysicalRelay(rUp, true);

  uint16_t runtimeSec = ConfigManager::instance().config.relays[rUp].runtime_sec;
  if (runtimeSec == 0) runtimeSec = 20;

  _shutters[pairIndex].is_moving = true;
  _shutters[pairIndex].direction = 1;
  _shutters[pairIndex].last_direction = 1;
  _shutters[pairIndex].pending_direction = 0;
  _shutters[pairIndex].start_time = millis();

  if (_shutters[pairIndex].target_position == 255) {
    _shutters[pairIndex].target_position = 100;
    _shutters[pairIndex].start_position = _shutters[pairIndex].current_position;
    // ADIM 15: Tam açılmada mekanik limit switch oturması ve self-healing için +2 sn (2000 ms) ilave süre
    _shutters[pairIndex].duration_ms = runtimeSec * 1000UL + SHUTTER_OVERRUN_MS;
  }

  Buzzer_Open_Time(150, 0);
  printf("[PANJUR %d] YUKARI baslatildi (Role %d ON, Sure: %u ms [Overrun +2s], Hedef: %%%d)\r\n", 
         pairIndex + 1, rUp + 1, (unsigned int)_shutters[pairIndex].duration_ms, _shutters[pairIndex].target_position);
}

void SmartAutomation::shutterDown(uint8_t pairIndex) {
  if (pairIndex >= (MAX_TOTAL_RELAYS / 2)) return;
  uint8_t rUp = pairIndex * 2;
  uint8_t rDown = rUp + 1;
  uint32_t now = millis();

  // 1. ZIT YÖN KONTROLÜ (Panjur şu anda YUKARI hareket ediyorsa):
  if (_shutters[pairIndex].direction == 1) {
    applyPhysicalRelay(rUp, false);
    updateShutterPosition(pairIndex);
    _shutters[pairIndex].is_moving = false;
    _shutters[pairIndex].direction = 0;
    _shutters[pairIndex].pending_direction = 2; // 2: ASAGI beklemede
    _shutters[pairIndex].dead_time_start = now;
    printf("[PANJUR %d INTERLOCK] YUKARI kesildi! 500ms OLU ZAMAN (Dead-Time) baslatildi -> ASAGI kuyrukta.\r\n", pairIndex + 1);
    Buzzer_Open_Time(50, 0);
    return;
  }

  // 2. ÖLÜ ZAMAN KONTROLÜ (Motor durmuş fakat son hareketten bu yana 500 ms geçmediyse):
  if (_shutters[pairIndex].dead_time_start > 0 && (now - _shutters[pairIndex].dead_time_start < SHUTTER_DEAD_TIME_MS)) {
    applyPhysicalRelay(rUp, false);
    _shutters[pairIndex].pending_direction = 2;
    printf("[PANJUR %d DEAD-TIME] Son hareketten sonra %u ms gecti (<500ms), ASAGI bekletiliyor.\r\n", 
           pairIndex + 1, (unsigned int)(now - _shutters[pairIndex].dead_time_start));
    return;
  }

  // 3. Emniyetli durum: Ölü zaman doldu veya motor hareketsizdi.
  applyPhysicalRelay(rUp, false);
  applyPhysicalRelay(rDown, true);

  uint16_t runtimeSec = ConfigManager::instance().config.relays[rDown].runtime_sec;
  if (runtimeSec == 0) runtimeSec = 20;

  _shutters[pairIndex].is_moving = true;
  _shutters[pairIndex].direction = 2;
  _shutters[pairIndex].last_direction = 2;
  _shutters[pairIndex].pending_direction = 0;
  _shutters[pairIndex].start_time = millis();

  if (_shutters[pairIndex].target_position == 255) {
    _shutters[pairIndex].target_position = 0;
    _shutters[pairIndex].start_position = _shutters[pairIndex].current_position;
    // ADIM 15: Tam kapanmada mekanik taban oturması ve self-healing için +2 sn (2000 ms) ilave süre
    _shutters[pairIndex].duration_ms = runtimeSec * 1000UL + SHUTTER_OVERRUN_MS;
  }

  Buzzer_Open_Time(150, 0);
  printf("[PANJUR %d] ASAGI baslatildi (Role %d ON, Sure: %u ms [Overrun +2s], Hedef: %%%d)\r\n", 
         pairIndex + 1, rDown + 1, (unsigned int)_shutters[pairIndex].duration_ms, _shutters[pairIndex].target_position);
}

void SmartAutomation::shutterStop(uint8_t pairIndex) {
  if (pairIndex >= (MAX_TOTAL_RELAYS / 2)) return;
  uint8_t rUp = pairIndex * 2;
  uint8_t rDown = rUp + 1;
  uint32_t now = millis();

  bool wasMoving = _shutters[pairIndex].is_moving || (_shutters[pairIndex].direction != 0) || (_shutters[pairIndex].pending_direction != 0);

  // İki röleyi de hemen kapat
  applyPhysicalRelay(rUp, false);
  applyPhysicalRelay(rDown, false);

  if (wasMoving) {
    _shutters[pairIndex].dead_time_start = now;
    updateShutterPosition(pairIndex);
    if (_shutters[pairIndex].target_position != 255) {
      uint32_t elapsed = now - _shutters[pairIndex].start_time;
      // ADIM 15 Self-Healing: Eğer tam açılma/kapanma süresine ulaşıldıysa veya süre dolduysa hedef pozisyonu kesin eşitle
      if (elapsed >= _shutters[pairIndex].duration_ms ||
          (elapsed >= (_shutters[pairIndex].duration_ms > SHUTTER_OVERRUN_MS ? (_shutters[pairIndex].duration_ms - SHUTTER_OVERRUN_MS) : _shutters[pairIndex].duration_ms) &&
           (_shutters[pairIndex].target_position == 100 || _shutters[pairIndex].target_position == 0))) {
        _shutters[pairIndex].current_position = _shutters[pairIndex].target_position;
      }
    }
    saveShutterPosition(pairIndex);
  }

  _shutters[pairIndex].is_moving = false;
  _shutters[pairIndex].direction = 0;
  _shutters[pairIndex].pending_direction = 0;
  _shutters[pairIndex].target_position = 255;
  _shutters[pairIndex].start_time = 0;

  Buzzer_Open_Time(80, 0);
  printf("[PANJUR %d] DURDURULDU (Role %d & %d OFF, Son Pozisyon: %%%d)\r\n", 
         pairIndex + 1, rUp + 1, rDown + 1, _shutters[pairIndex].current_position);
}

void SmartAutomation::setShutterPosition(uint8_t pairIndex, uint8_t targetPercent) {
  if (pairIndex >= (MAX_TOTAL_RELAYS / 2)) return;
  if (targetPercent > 100) targetPercent = 100;

  updateShutterPosition(pairIndex);
  uint8_t curPos = _shutters[pairIndex].current_position;

  if (curPos == targetPercent) {
    if (_shutters[pairIndex].is_moving) {
      shutterStop(pairIndex);
    }
    printf("[PANJUR %d] Zaten hedef pozisyonda (%%%d).\r\n", pairIndex + 1, targetPercent);
    return;
  }

  uint8_t rUp = pairIndex * 2;
  uint8_t rDown = rUp + 1;
  uint32_t tUp = ConfigManager::instance().config.relays[rUp].runtime_sec * 1000UL;
  if (tUp == 0) tUp = 20000;
  uint32_t tDown = ConfigManager::instance().config.relays[rDown].runtime_sec * 1000UL;
  if (tDown == 0) tDown = 20000;

  if (targetPercent > curPos) {
    // YUKARI HAREKET GEREKLİ (Açılma)
    uint8_t diff = targetPercent - curPos;
    uint32_t duration = (diff * tUp) / 100UL;

    if (targetPercent == 100) {
      // ADIM 15: Tam açılmada mekanik limit switch oturması ve self-healing için +2 sn ilave süre
      duration = tUp + SHUTTER_OVERRUN_MS;
    }

    _shutters[pairIndex].target_position = targetPercent;
    _shutters[pairIndex].start_position = curPos;

    printf("[PANJUR %d] Pozisyon Komutu: %%%d -> Hedef: %%%d (Yon: YUKARI, Sure: %u ms%s)\r\n",
           pairIndex + 1, curPos, targetPercent, (unsigned int)duration,
           (targetPercent == 100) ? " [+2s Overrun]" : "");

    _shutters[pairIndex].duration_ms = duration;
    shutterUp(pairIndex);
    _shutters[pairIndex].duration_ms = duration;
    _shutters[pairIndex].target_position = targetPercent;
    _shutters[pairIndex].start_position = curPos;
  } else {
    // AŞAĞI HAREKET GEREKLİ (Kapanma)
    uint8_t diff = curPos - targetPercent;
    uint32_t duration = (diff * tDown) / 100UL;

    if (targetPercent == 0) {
      // ADIM 15: Tam kapanmada mekanik taban oturması ve self-healing için +2 sn ilave süre
      duration = tDown + SHUTTER_OVERRUN_MS;
    }

    _shutters[pairIndex].target_position = targetPercent;
    _shutters[pairIndex].start_position = curPos;

    printf("[PANJUR %d] Pozisyon Komutu: %%%d -> Hedef: %%%d (Yon: ASAGI, Sure: %u ms%s)\r\n",
           pairIndex + 1, curPos, targetPercent, (unsigned int)duration,
           (targetPercent == 0) ? " [+2s Overrun]" : "");

    _shutters[pairIndex].duration_ms = duration;
    shutterDown(pairIndex);
    _shutters[pairIndex].duration_ms = duration;
    _shutters[pairIndex].target_position = targetPercent;
    _shutters[pairIndex].start_position = curPos;
  }
}

void SmartAutomation::shutterStep(uint8_t pairIndex) {
  if (pairIndex >= (MAX_TOTAL_RELAYS / 2)) return;

  // Eğer panjur hareket ediyorsa veya dead-time beklemesinde ise: DURDUR
  if (_shutters[pairIndex].is_moving || _shutters[pairIndex].pending_direction != 0) {
    printf("[PANJUR %d] SHUTTER_STEP: Hareket/Bekleme var -> DURDURULDU\r\n", pairIndex + 1);
    _shutters[pairIndex].pending_direction = 0; // Kuyruklanmış hareketi de iptal et
    shutterStop(pairIndex);
    return;
  }

  // Panjur duruyorsa: son harekete göre TERSİNDE hareket başlat (Döngüsel: Aç→Dur→Kapat→Dur→Aç...)
  // last_direction: 0=Hiç hareket etmedi (başlangıç), 1=Son hareket YUKARI, 2=Son hareket ASAGI
  if (_shutters[pairIndex].last_direction == 1) {
    // Son hareket YUKARI (Açılma) idi → Şimdi ASAGI (Kapatma) başlat
    printf("[PANJUR %d] SHUTTER_STEP: Son yon YUKARI -> ASAGI baslatiliyor\r\n", pairIndex + 1);
    shutterDown(pairIndex);
  } else {
    // Son hareket ASAGI (Kapatma) idi veya hiç hareket etmedi → YUKARI (Açılma) başlat
    printf("[PANJUR %d] SHUTTER_STEP: Son yon ASAGI/Baslangic -> YUKARI baslatiliyor\r\n", pairIndex + 1);
    shutterUp(pairIndex);
  }
}

ShutterState SmartAutomation::getShutterState(uint8_t pairIndex) {
  if (pairIndex >= (MAX_TOTAL_RELAYS / 2)) {
    ShutterState empty = {false, 0, 0, 0, 0, 0, 0, 0, 255, 0};
    return empty;
  }
  updateShutterPosition(pairIndex);
  return _shutters[pairIndex];
}

void SmartAutomation::allLightsOff() {
  uint8_t totalR = ConfigManager::instance().config.totalRelays();
  for (int i = 0; i < totalR; i++) {
    auto& cfg = ConfigManager::instance().config.relays[i];
    if (cfg.type == RELAY_TYPE_LIGHT) {
      applyPhysicalRelay(i, false);
    }
  }
  Buzzer_Open_Time(300, 0);
  printf("Tum lambalar kapatildi.\r\n");
}

void SmartAutomation::allShuttersDown() {
  uint8_t totalPairs = ConfigManager::instance().config.totalRelays() / 2;
  for (int p = 0; p < totalPairs; p++) {
    auto& c1 = ConfigManager::instance().config.relays[p * 2];
    auto& c2 = ConfigManager::instance().config.relays[p * 2 + 1];
    if (c1.type == RELAY_TYPE_SHUTTER_UP || c2.type == RELAY_TYPE_SHUTTER_DOWN) {
      shutterDown(p);
    }
  }
}

void SmartAutomation::allShuttersUp() {
  uint8_t totalPairs = ConfigManager::instance().config.totalRelays() / 2;
  for (int p = 0; p < totalPairs; p++) {
    auto& c1 = ConfigManager::instance().config.relays[p * 2];
    auto& c2 = ConfigManager::instance().config.relays[p * 2 + 1];
    if (c1.type == RELAY_TYPE_SHUTTER_UP || c2.type == RELAY_TYPE_SHUTTER_DOWN) {
      shutterUp(p);
    }
  }
}

void SmartAutomation::allShuttersStop() {
  uint8_t totalPairs = ConfigManager::instance().config.totalRelays() / 2;
  for (int p = 0; p < totalPairs; p++) {
    shutterStop(p);
  }
}

bool SmartAutomation::getDIState(uint8_t diIndex) {
  if (diIndex >= MAX_TOTAL_DIS) return false;
  return _diStates[diIndex];
}

void SmartAutomation::loop() {
  checkShutterTimers();
  checkImpulseTimers();
  checkDigitalInputs();
  pollExtModule();
  checkRs485Incoming();
}

void SmartAutomation::checkShutterTimers() {
  uint32_t now = millis();
  uint8_t totalPairs = ConfigManager::instance().config.totalRelays() / 2;

  for (int p = 0; p < totalPairs; p++) {
    // 1. Ölü Zaman (Dead-Time) Süresi Dolan Bekleyen Yön Aktivasyonu
    if (_shutters[p].pending_direction != 0) {
      if (now - _shutters[p].dead_time_start >= SHUTTER_DEAD_TIME_MS) {
        uint8_t targetDir = _shutters[p].pending_direction;
        _shutters[p].pending_direction = 0; // Kuyruktan çıkar
        printf("[PANJUR %d DEAD-TIME DOLDU] %u ms beklendi -> Yon %s simdi devreye aliniyor.\r\n",
               p + 1, (unsigned int)(now - _shutters[p].dead_time_start),
               (targetDir == 1) ? "YUKARI" : "ASAGI");
        if (targetDir == 1) {
          shutterUp(p);
        } else if (targetDir == 2) {
          shutterDown(p);
        }
      }
    }

    // 2. Çalışma Süresi (Runtime Duration) Kontrolü
    if (_shutters[p].is_moving) {
      updateShutterPosition(p);
      if (now - _shutters[p].start_time >= _shutters[p].duration_ms) {
        printf("[PANJUR %d SURE DOLDU] Calisma suresi (%u ms) tamamlandi -> Hedef pozisyona ulasildi.\r\n",
               p + 1, (unsigned int)_shutters[p].duration_ms);
        shutterStop(p);
      }
    }
  }
}

void SmartAutomation::checkImpulseTimers() {
  uint32_t now = millis();
  uint8_t totalR = ConfigManager::instance().config.totalRelays();
  for (int i = 0; i < totalR; i++) {
    if (_impulseEndTime[i] > 0 && now >= _impulseEndTime[i]) {
      applyPhysicalRelay(i, false);
      _impulseEndTime[i] = 0;
      printf("Röle %d (Darbe): Sure doldu, kapatildi.\r\n", i + 1);
    }
  }
}

void SmartAutomation::checkDigitalInputs() {
  const uint8_t diPins[8] = {
    DIN_PIN_CH1, DIN_PIN_CH2, DIN_PIN_CH3, DIN_PIN_CH4,
    DIN_PIN_CH5, DIN_PIN_CH6, DIN_PIN_CH7, DIN_PIN_CH8
  };
  uint32_t now = millis();
  uint8_t totalR = ConfigManager::instance().config.totalRelays();

  for (int i = 0; i < 8; i++) {
    bool isClosed = (digitalRead(diPins[i]) == LOW); // LOW = Kuru kontak DGND ile birleşti
    if (isClosed != _diStates[i]) {
      // 150ms Debounce filtresi (yaylı mekanik butonlar için spurious trigger önlemi)
      if (now - _diLastPressTime[i] > 150) {
        _diStates[i] = isClosed;
        _diLastPressTime[i] = now;

        auto& diCfg = ConfigManager::instance().config.dis[i];
        uint8_t targetRelay = diCfg.target_relay; // 1..totalR (0=pasif)

        if (targetRelay >= 1 && targetRelay <= totalR) {
          uint8_t rIdx = targetRelay - 1;

          // ADIM 17: Çocuk Kilidi Koruması (Duvardaki butonlar kilitliyse eylemi engelle)
          if (_childLockEnabled) {
            printf("[ÇOCUK KİLİDİ AKTİF] DI-%d kontak verdi ancak fiziksel anahtarlar kilitli! Röle tetiklenmedi.\r\n", i + 1);
            continue;
          }

          if (isClosed) { // Butona basılma anı (Falling edge)
            printf("[DI-%d] Kuru Kontak Tetiklendi (DGND) -> Hedef Role-%d (Mod: %d)\r\n",
                   i + 1, targetRelay, diCfg.mode);
            if (diCfg.mode == DI_MODE_TOGGLE) {
              toggleRelay(rIdx);
            } else if (diCfg.mode == DI_MODE_MOMENTARY) {
              setRelayState(rIdx, true);
            } else if (diCfg.mode == DI_MODE_SHUTTER_STEP) {
              uint8_t pairIdx = rIdx / 2;
              shutterStep(pairIdx);
            } else if (diCfg.mode == DI_MODE_SHUTTER_UP) {
              uint8_t pairIdx = rIdx / 2;
              if (_shutters[pairIdx].is_moving || _shutters[pairIdx].pending_direction != 0) {
                shutterStop(pairIdx);
              } else {
                shutterUp(pairIdx);
              }
            } else if (diCfg.mode == DI_MODE_SHUTTER_DOWN) {
              uint8_t pairIdx = rIdx / 2;
              if (_shutters[pairIdx].is_moving || _shutters[pairIdx].pending_direction != 0) {
                shutterStop(pairIdx);
              } else {
                shutterDown(pairIdx);
              }
            }
          } else { // Butonun bırakılma anı (Rising edge)
            if (diCfg.mode == DI_MODE_MOMENTARY) {
              printf("[DI-%d] Buton Birakildi -> Hedef Role-%d KAPATILDI\r\n", i + 1, targetRelay);
              setRelayState(rIdx, false);
            }
          }
        }
      }
    }
  }
}

// ======================= RS485 İLETİŞİM & HARİCİ MODÜL =======================
static uint16_t calculateModbusCRC(const uint8_t *buf, int len) {
  uint16_t crc = 0xFFFF;
  for (int pos = 0; pos < len; pos++) {
    crc ^= (uint16_t)buf[pos];
    for (int i = 8; i != 0; i--) {
      if ((crc & 0x0001) != 0) {
        crc >>= 1;
        crc ^= 0xA001;
      } else {
        crc >>= 1;
      }
    }
  }
  return crc;
}

static bool rs485SendRawAndReceive(const uint8_t *txBuf, size_t txLen, uint8_t *rxBuf, size_t maxRxLen, size_t &rxLen, uint32_t timeoutMs = 150) {
  while (Serial1.available()) Serial1.read(); // Tamponu temizle

  Serial1.write(txBuf, txLen);
  Serial1.flush();

  rxLen = 0;
  uint32_t start = millis();
  while (millis() - start < timeoutMs) {
    if (Serial1.available()) {
      delay(20); // Geriye kalan baytların hatta oturması için bekle
      while (Serial1.available() && rxLen < maxRxLen) {
        rxBuf[rxLen++] = Serial1.read();
      }
      break;
    }
    vTaskDelay(pdMS_TO_TICKS(2));
  }
  return (rxLen > 0);
}

void SmartAutomation::rs485Begin(uint32_t baud) {
  Serial1.begin(baud, SERIAL_8N1, 18, 17); // RX: GPIO18, TX: GPIO17
  addRs485Log("[Sistem] RS485 baslatildi (" + String(baud) + " baud, 8N1)");
  Serial.printf("[RS485] Baslatildi: %d baud (RX=18, TX=17)\r\n", baud);
}

bool SmartAutomation::rs485Send(const String& data, bool isHex) {
  if (data.isEmpty()) return false;

  if (isHex) {
    String cleanData = "";
    for (size_t i = 0; i < data.length(); i++) {
      char c = data[i];
      if (isxdigit(c)) cleanData += c;
    }
    if (cleanData.length() % 2 != 0) {
      addRs485Log("[Hata] Gecersiz HEX verisi: Uzunluk cift olmalidir!");
      return false;
    }
    size_t byteLen = cleanData.length() / 2;
    uint8_t* bytes = (uint8_t*)malloc(byteLen);
    for (size_t i = 0; i < byteLen; i++) {
      char byteStr[3] = {cleanData[i * 2], cleanData[i * 2 + 1], '\0'};
      bytes[i] = (uint8_t)strtol(byteStr, NULL, 16);
    }
    Serial1.write(bytes, byteLen);
    Serial1.flush();
    free(bytes);
    addRs485Log("[TX HEX] " + data);
    Serial.printf("[RS485-TX] HEX: %s\r\n", data.c_str());
  } else {
    Serial1.print(data);
    Serial1.flush();
    addRs485Log("[TX ASCII] " + data);
    Serial.printf("[RS485-TX] ASCII: %s\r\n", data.c_str());
  }
  return true;
}

void SmartAutomation::checkRs485Incoming() {
  if (Serial1.available()) {
    String asciiStr = "";
    String hexStr = "";
    uint32_t startWait = millis();

    while (millis() - startWait < 30) {
      while (Serial1.available()) {
        uint8_t b = Serial1.read();
        if (b >= 32 && b <= 126) asciiStr += (char)b;
        else asciiStr += '.';

        char hexBuf[4];
        snprintf(hexBuf, sizeof(hexBuf), "%02X ", b);
        hexStr += hexBuf;
        startWait = millis();
      }
    }

    if (hexStr.length() > 0) {
      addRs485Log("[RX] HEX: " + hexStr + " | ASCII: " + asciiStr);
      Serial.printf("[RS485-RX] HEX: %s | ASCII: %s\r\n", hexStr.c_str(), asciiStr.c_str());
    }
  }
}

void SmartAutomation::addRs485Log(const String& line) {
  char timeBuf[16];
  uint32_t sec = millis() / 1000;
  snprintf(timeBuf, sizeof(timeBuf), "[%02d:%02d:%02d] ", (sec / 3600) % 24, (sec / 60) % 60, sec % 60);

  if (_rs485LogCount < RS485_LOG_MAX) {
    _rs485Logs[_rs485LogCount++] = String(timeBuf) + line;
  } else {
    for (int i = 1; i < RS485_LOG_MAX; i++) {
      _rs485Logs[i - 1] = _rs485Logs[i];
    }
    _rs485Logs[RS485_LOG_MAX - 1] = String(timeBuf) + line;
  }
}

String SmartAutomation::rs485GetLogs() {
  String out = "";
  for (int i = 0; i < _rs485LogCount; i++) {
    out += _rs485Logs[i] + "\n";
  }
  return out;
}

void SmartAutomation::rs485ClearLogs() {
  _rs485LogCount = 0;
}

SmartAutomation::Rs485ScanResult SmartAutomation::rs485ScanModule(uint32_t specificBaud) {
  Rs485ScanResult res;
  res.found = false;
  res.slaveId = 0;
  res.baud = 0;
  res.relayStatus = 0;
  res.rawHex = "";
  res.info = "Hicbir RS485 yaniti alinamadi.";

  uint32_t currentBaud = ConfigManager::instance().config.rs485_baud;
  if (currentBaud == 0) currentBaud = 9600;

  uint32_t baudsToTest[6];
  int numBauds = 0;
  if (specificBaud > 0) {
    baudsToTest[numBauds++] = specificBaud;
  } else {
    baudsToTest[numBauds++] = currentBaud;
    if (currentBaud != 9600) baudsToTest[numBauds++] = 9600;
    baudsToTest[numBauds++] = 38400;
    baudsToTest[numBauds++] = 115200;
    baudsToTest[numBauds++] = 19200;
    baudsToTest[numBauds++] = 4800;
  }

  Serial.printf("\r\n--- [RS485 TARAMA BASLATILIYOR] ---\r\n");
  addRs485Log("[Tarama] Harici 8-kanal röle modülü aranıyor...");

  for (int b = 0; b < numBauds; b++) {
    uint32_t baud = baudsToTest[b];
    Serial.printf("[Tarama] Baud: %d deneniyor...\r\n", baud);
    Serial1.begin(baud, SERIAL_8N1, 18, 17);
    vTaskDelay(pdMS_TO_TICKS(20));

    // Slave Adresleri: 1'den 8'e kadar tara
    for (uint8_t sid = 1; sid <= 8; sid++) {
      vTaskDelay(pdMS_TO_TICKS(10)); // Watchdog rahatlat
      uint8_t rxBuf[32];
      size_t rxLen = 0;

      // 1. MODBUS FONKSİYON 0x01: Read Coils (Röle durumlarını oku)
      uint8_t reqCoils[8] = { sid, 0x01, 0x00, 0x00, 0x00, 0x08, 0x00, 0x00 };
      uint16_t crc = calculateModbusCRC(reqCoils, 6);
      reqCoils[6] = (uint8_t)(crc & 0xFF);
      reqCoils[7] = (uint8_t)((crc >> 8) & 0xFF);

      if (rs485SendRawAndReceive(reqCoils, 8, rxBuf, sizeof(rxBuf), rxLen, 120)) {
        String hexStr = "";
        for (size_t k = 0; k < rxLen; k++) {
          char bStr[4];
          snprintf(bStr, sizeof(bStr), "%02X ", rxBuf[k]);
          hexStr += bStr;
        }

        Serial.printf("  -> [Baud %d] Slave %d (0x01 Read Coils) YANIT: %s\r\n", baud, sid, hexStr.c_str());

        // Yanıt kontrolü: [sid, 0x01, byteCount(1), dataByte, crcLo, crcHi]
        if (rxLen >= 5 && rxBuf[0] == sid && rxBuf[1] == 0x01) {
          uint16_t calcCrc = calculateModbusCRC(rxBuf, rxLen - 2);
          uint16_t respCrc = rxBuf[rxLen - 2] | (rxBuf[rxLen - 1] << 8);
          res.found = true;
          res.slaveId = sid;
          res.baud = baud;
          res.relayStatus = (rxLen >= 4) ? rxBuf[3] : 0;
          res.rawHex = hexStr;
          res.info = (calcCrc == respCrc) ? "Modbus RTU Standard Yanıt (CRC Doğru)" : "Yanıt Alındı (CRC Uyarı)";

          addRs485Log("[BULUNDU] Slave ID: " + String(sid) + " (" + String(baud) + " baud) | Röle Durumu: 0x" + String(res.relayStatus, HEX));
          Serial.printf("  ===> BASARILI! Harici Röle Modulu bulundu: Slave ID: %d, Baud: %d, Durum: 0x%02X\r\n", sid, baud, res.relayStatus);

          // Cihazın baud hızını tespit edilene güncelle
          if (ConfigManager::instance().config.rs485_baud != baud) {
            ConfigManager::instance().config.rs485_baud = baud;
          }
          return res;
        } else if (rxLen > 0) {
          // Ham veri alındı ama format tam eşleşmedi, yine de kaydet
          res.found = true;
          res.slaveId = sid;
          res.baud = baud;
          res.rawHex = hexStr;
          res.info = "Ham Yanıt Alındı: " + hexStr;
        }
      }

      // 2. MODBUS FONKSİYON 0x03: Read Holding Registers
      uint8_t reqRegs[8] = { sid, 0x03, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00 };
      crc = calculateModbusCRC(reqRegs, 6);
      reqRegs[6] = (uint8_t)(crc & 0xFF);
      reqRegs[7] = (uint8_t)((crc >> 8) & 0xFF);

      if (rs485SendRawAndReceive(reqRegs, 8, rxBuf, sizeof(rxBuf), rxLen, 100)) {
        String hexStr = "";
        for (size_t k = 0; k < rxLen; k++) {
          char bStr[4];
          snprintf(bStr, sizeof(bStr), "%02X ", rxBuf[k]);
          hexStr += bStr;
        }
        Serial.printf("  -> [Baud %d] Slave %d (0x03 Read Regs) YANIT: %s\r\n", baud, sid, hexStr.c_str());
        if (rxLen >= 5 && rxBuf[0] == sid && rxBuf[1] == 0x03) {
          res.found = true;
          res.slaveId = sid;
          res.baud = baud;
          res.rawHex = hexStr;
          res.info = "Modbus 0x03 Register Yanıtı";
          addRs485Log("[BULUNDU] Slave ID: " + String(sid) + " (" + String(baud) + " baud, 0x03)");
          return res;
        }
      }
    }
  }

  // Sonuç alınamadıysa geri orijinal baud hızına dön
  Serial1.begin(currentBaud, SERIAL_8N1, 18, 17);
  if (!res.found) {
    addRs485Log("[Tarama] Harici modülden yanıt alınamadı. A/B klemenslerini ve 12V/24V beslemeyi kontrol edin.");
    Serial.printf("[Tarama] Hicbir harici modül yanit vermedi. A/B baglantilarini veya beslemeyi kontrol edin.\r\n");
  }
  Serial.printf("--- [RS485 TARAMA TAMAMLANDI] ---\r\n\r\n");
  return res;
}

void SmartAutomation::pollExtModule() {
  auto& cfg = ConfigManager::instance().config;
  if (!cfg.ext_module_enabled) return;

  uint32_t now = millis();
  // Her 120ms'de bir girişleri tara (polling)
  if (now - _lastExtModulePoll < 120) return;
  _lastExtModulePoll = now;

  uint8_t slaveId = cfg.ext_module_address;
  if (slaveId == 0) slaveId = 1;
  uint8_t extCh = cfg.ext_module_channels;
  if (extCh == 0) extCh = 8;
  if (extCh > 32) extCh = 32;

  // 1. Modbus Function 0x02: Read Discrete Inputs (Harici Modül Girişlerini Oku)
  uint8_t req[8];
  req[0] = slaveId;
  req[1] = 0x02; // Read Discrete Inputs
  req[2] = 0x00; // Start Address Hi
  req[3] = 0x00; // Start Address Lo
  req[4] = 0x00; // Count Hi
  req[5] = extCh; // Count Lo (2..32)

  uint16_t crc = calculateModbusCRC(req, 6);
  req[6] = (uint8_t)(crc & 0xFF);
  req[7] = (uint8_t)((crc >> 8) & 0xFF);

  uint8_t rxBuf[32];
  size_t rxLen = 0;
  bool ok = rs485SendRawAndReceive(req, 8, rxBuf, sizeof(rxBuf), rxLen, 60);

  if (ok && rxLen >= 5 && rxBuf[0] == slaveId && rxBuf[1] == 0x02) {
    _extModuleResponding = true;
    uint8_t byteCount = rxBuf[2];
    uint8_t totalR = cfg.totalRelays();

    for (uint8_t k = 0; k < extCh; k++) {
      uint8_t byteIdx = 3 + (k / 8);
      if (byteIdx >= (3 + byteCount)) break;
      uint8_t bitIdx = k % 8;
      bool isClosed = ((rxBuf[byteIdx] >> bitIdx) & 0x01) == 1;

      uint8_t diIndex = 8 + k;
      if (diIndex < MAX_TOTAL_DIS && isClosed != _diStates[diIndex]) {
        if (now - _diLastPressTime[diIndex] > 150) {
          _diStates[diIndex] = isClosed;
          _diLastPressTime[diIndex] = now;

          auto& diCfg = cfg.dis[diIndex];
          uint8_t targetRelay = diCfg.target_relay;

          if (targetRelay >= 1 && targetRelay <= totalR) {
            uint8_t rIdx = targetRelay - 1;
            if (isClosed) {
              if (diCfg.mode == DI_MODE_TOGGLE) {
                toggleRelay(rIdx);
              } else if (diCfg.mode == DI_MODE_MOMENTARY) {
                setRelayState(rIdx, true);
              } else if (diCfg.mode == DI_MODE_SHUTTER_STEP) {
                shutterStep(rIdx / 2);
              } else if (diCfg.mode == DI_MODE_SHUTTER_UP) {
                uint8_t p = rIdx / 2;
                if (_shutters[p].is_moving || _shutters[p].pending_direction != 0) shutterStop(p);
                else shutterUp(p);
              } else if (diCfg.mode == DI_MODE_SHUTTER_DOWN) {
                uint8_t p = rIdx / 2;
                if (_shutters[p].is_moving || _shutters[p].pending_direction != 0) shutterStop(p);
                else shutterDown(p);
              }
            } else {
              if (diCfg.mode == DI_MODE_MOMENTARY) {
                setRelayState(rIdx, false);
              }
            }
          }
        }
      }
    }
  }

  // 2. Her 1500 ms'de bir röle durumlarını sorgula (Read Coils - 0x01)
  if (now - _lastExtCoilPoll >= 1500) {
    _lastExtCoilPoll = now;
    uint8_t cReq[8];
    cReq[0] = slaveId;
    cReq[1] = 0x01; // Read Coils
    cReq[2] = 0x00; cReq[3] = 0x00;
    cReq[4] = 0x00; cReq[5] = extCh;
    uint16_t cCrc = calculateModbusCRC(cReq, 6);
    cReq[6] = (uint8_t)(cCrc & 0xFF);
    cReq[7] = (uint8_t)((cCrc >> 8) & 0xFF);

    uint8_t cRx[32];
    size_t cRxLen = 0;
    bool cOk = rs485SendRawAndReceive(cReq, 8, cRx, sizeof(cRx), cRxLen, 60);
    if (cOk && cRxLen >= 5 && cRx[0] == slaveId && cRx[1] == 0x01) {
      uint8_t bCount = cRx[2];
      for (uint8_t k = 0; k < extCh; k++) {
        uint8_t bIdx = 3 + (k / 8);
        if (bIdx >= (3 + bCount)) break;
        uint8_t bitIdx = k % 8;
        bool rState = ((cRx[bIdx] >> bitIdx) & 0x01) == 1;
        uint8_t rIndex = 8 + k;
        if (rIndex < MAX_TOTAL_RELAYS) {
          _relayStates[rIndex] = rState;
        }
      }
    }
  }
}

bool SmartAutomation::rs485ControlExtRelay(uint8_t slaveId, uint8_t channel, uint8_t action, String* responseHex) {
  // channel: 1..32 veya 0 (Tümü)
  // action: 1 (ON), 0 (OFF), 2 (TOGGLE - Waveshare 0x5500)
  uint8_t req[8];
  req[0] = slaveId;
  req[1] = 0x05; // Write Single Coil

  if (channel == 0) {
    // Tüm röleler
    req[2] = 0x00;
    req[3] = 0xFF;
    req[4] = (action == 1) ? 0xFF : 0x00;
    req[5] = (action == 1) ? 0xFF : 0x00;
  } else {
    uint16_t coilAddr = channel - 1; // 0..31
    req[2] = (uint8_t)((coilAddr >> 8) & 0xFF);
    req[3] = (uint8_t)(coilAddr & 0xFF);
    if (action == 1) {
      req[4] = 0xFF; req[5] = 0x00; // ON
    } else if (action == 0) {
      req[4] = 0x00; req[5] = 0x00; // OFF
    } else {
      req[4] = 0x55; req[5] = 0x00; // Waveshare TOGGLE
    }
  }

  uint16_t crc = calculateModbusCRC(req, 6);
  req[6] = (uint8_t)(crc & 0xFF);
  req[7] = (uint8_t)((crc >> 8) & 0xFF);

  uint8_t rxBuf[32];
  size_t rxLen = 0;
  bool ok = rs485SendRawAndReceive(req, 8, rxBuf, sizeof(rxBuf), rxLen, 120);

  String respStr = "";
  for (size_t k = 0; k < rxLen; k++) {
    char bStr[4];
    snprintf(bStr, sizeof(bStr), "%02X ", rxBuf[k]);
    respStr += bStr;
  }
  if (responseHex) *responseHex = respStr;

  char txStr[32];
  snprintf(txStr, sizeof(txStr), "%02X %02X %02X %02X %02X %02X %02X %02X",
           req[0], req[1], req[2], req[3], req[4], req[5], req[6], req[7]);

  if (ok && rxLen >= 6) {
    _extModuleResponding = true;
    addRs485Log("[EXT RÖLE] Slave " + String(slaveId) + " CH" + String(channel) + " Eylem:" + String(action) + " -> YANIT: " + respStr);
    Serial.printf("[RS485-EXT] TX: %s -> RX: %s (OK)\r\n", txStr, respStr.c_str());
    return true;
  } else {
    addRs485Log("[EXT RÖLE HATA] Slave " + String(slaveId) + " CH" + String(channel) + " -> Yanıt Yok veya Hatalı (" + respStr + ")");
    Serial.printf("[RS485-EXT] TX: %s -> YANIT YOK!\r\n", txStr);
    return false;
  }
}


