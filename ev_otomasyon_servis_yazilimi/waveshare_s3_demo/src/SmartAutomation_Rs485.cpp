// ============================================================================
// SmartAutomation - RS485 / Modbus RTU harici röle modülü katmanı (F4)
//
//  * TEK giriş noktası: rs485Exchange()/rs485Transaction() — _rs485Mutex ALTINDA. (Eski kod mutex'i hiç
//    oluşturmuyordu; MQTT/Web/CLI/ana döngü aynı Serial1'e aynı anda yazabiliyordu.)
//  * Her yanıt CRC16 + bağımlı adres + işlev kodu + yankı/uzunluk doğrulamasından geçmeden BAŞARI sayılmaz
//    (saf mantık: src/ModbusRtu.h, PC'de test edilir). Alıcı tampon her zaman sıfırlanır (başlatılmamış bayt yok).
//  * Yanıtsız slave için üstel geri çekilme; _extModuleResponding gerçek durumu yansıtır.
//  * checkRs485Incoming() toplam süre/bayt sınırlıdır (bloklamaz).
//  * Ham komut API'leri panjur kanallarını ve channel=0 toplu AÇMAYI reddeder; tarama BLOKLAMAZ (ayrı görev).
// ============================================================================
#include "SmartAutomation.h"
#include "safety/SafetyManager.h"
#include "ModbusRtu.h"
#include "WS_GPIO.h"
#include <HardwareSerial.h>
#include <esp_task_wdt.h>

static const char* statusText(modbus::Status s) {
  switch (s) {
    case modbus::OK: return "OK";
    case modbus::ERR_NO_DATA: return "yanit yok";
    case modbus::ERR_SHORT: return "yanit cok kisa";
    case modbus::ERR_CRC: return "CRC hatasi";
    case modbus::ERR_SLAVE: return "baska slave";
    case modbus::ERR_FUNC: return "beklenmeyen islev";
    case modbus::ERR_EXCEPTION: return "slave exception";
    case modbus::ERR_LENGTH: return "uzunluk uyusmuyor";
    case modbus::ERR_ECHO: return "yanki uyusmuyor";
    default: return "?";
  }
}

static String hexString(const uint8_t* b, size_t n) {
  String s;
  s.reserve(n * 3 + 1);
  for (size_t i = 0; i < n; i++) {
    char t[4];
    snprintf(t, sizeof(t), "%02X ", b[i]);
    s += t;
  }
  return s;
}

static bool isAllowedBaud(uint32_t b) {
  return b == 4800 || b == 9600 || b == 19200 || b == 38400 || b == 57600 || b == 115200;
}

// ------------------------------------------------------------------------------------------------
// Düşük seviye: Serial1 (RX=GPIO18, TX=GPIO17)
// ------------------------------------------------------------------------------------------------
void SmartAutomation::applyRs485Pins(uint32_t baud) {
  Serial1.end();
  Serial1.begin(baud, SERIAL_8N1, 18, 17);   // RX: GPIO18, TX: GPIO17
}

void SmartAutomation::rs485Begin(uint32_t baud) {
  if (!isAllowedBaud(baud)) {
    printf("[RS485] Gecersiz baud (%u) reddedildi.\r\n", (unsigned)baud);
    return;
  }
  if (_rs485Mutex == nullptr) _rs485Mutex = xSemaphoreCreateMutex();
  if (xSemaphoreTake(_rs485Mutex, pdMS_TO_TICKS(500)) != pdTRUE) {
    printf("[RS485] Baud degistirilemedi: hat mesgul.\r\n");
    return;
  }
  applyRs485Pins(baud);
  _rs485Baud = baud;
  xSemaphoreGive(_rs485Mutex);
  addRs485Log("[Sistem] RS485 baslatildi (" + String(baud) + " baud, 8N1)");
  Serial.printf("[RS485] Baslatildi: %u baud (RX=18, TX=17)\r\n", (unsigned)baud);
}

// Mutex ZATEN alınmış olmalıdır. İstek çıkar, yanıtı bayt-arası zaman aşımıyla toplar.
bool SmartAutomation::rs485ExchangeLocked(const uint8_t* tx, size_t txLen, uint8_t* rx, size_t maxRx, size_t& rxLen,
                                          size_t expectedLen, uint32_t timeoutMs) {
  rxLen = 0;
  if (rx != nullptr && maxRx > 0) memset(rx, 0, maxRx);      // başlatılmamış tampon yok
  if (tx == nullptr || txLen == 0) return false;

  while (Serial1.available()) Serial1.read();                // eski/artık baytları at
  Serial1.write(tx, txLen);
  Serial1.flush();

  const uint32_t baud = _rs485Baud ? _rs485Baud : 9600;
  const uint32_t interByteMs = 38500UL / baud + 2;           // ~3,5 karakter süresi + pay
  const uint32_t t0 = millis();
  uint32_t lastRx = t0;
  bool any = false;

  for (;;) {
    while (Serial1.available() && rx != nullptr && rxLen < maxRx) {
      rx[rxLen++] = (uint8_t)Serial1.read();
      lastRx = millis();
      any = true;
    }
    if (rx == nullptr || rxLen >= maxRx) break;
    if (any) {
      if (expectedLen != 0 && rxLen >= expectedLen) break;
      if (rxLen >= 5 && (rx[1] & 0x80)) break;                // exception yanıtı 5 bayttır
      if ((uint32_t)(millis() - lastRx) >= interByteMs) break;
    } else if ((uint32_t)(millis() - t0) >= timeoutMs) {
      break;
    }
    vTaskDelay(1);
  }
  while (Serial1.available()) Serial1.read();                // fazlalığı temizle
  return rxLen > 0;
}

bool SmartAutomation::rs485Exchange(const uint8_t* tx, size_t txLen, uint8_t* rx, size_t maxRx, size_t& rxLen,
                                    size_t expectedLen, uint32_t timeoutMs, uint32_t lockWaitMs) {
  rxLen = 0;
  if (rx != nullptr && maxRx > 0) memset(rx, 0, maxRx);
  if (_rs485Mutex == nullptr) return false;
  if (xSemaphoreTake(_rs485Mutex, pdMS_TO_TICKS(lockWaitMs)) != pdTRUE) return false;   // hat meşgul
  bool ok = rs485ExchangeLocked(tx, txLen, rx, maxRx, rxLen, expectedLen, timeoutMs);
  xSemaphoreGive(_rs485Mutex);
  return ok;
}

// TEK genel giriş noktası (eski imza korunur)
bool SmartAutomation::rs485Transaction(const uint8_t *txBuf, size_t txLen, uint8_t *rxBuf, size_t maxRxLen, size_t &rxLen, uint32_t timeoutMs) {
  return rs485Exchange(txBuf, txLen, rxBuf, maxRxLen, rxLen, 0, timeoutMs, 40);
}

// ------------------------------------------------------------------------------------------------
// Doğrulamalı Modbus işlemleri
// ------------------------------------------------------------------------------------------------
// 0x05: tek coil yaz (channel1 = 1..32, 0 = hepsi / adres 0x00FF). Yanıt istekle BİREBİR eşleşmeli.
bool SmartAutomation::extWriteCoil(uint8_t slaveId, uint8_t channel1, uint16_t value, uint32_t lockWaitMs, String* respHex,
                                   uint8_t attempts, uint32_t timeoutMs) {
  uint8_t req[8];
  const uint16_t addr = (channel1 == 0) ? 0x00FF : (uint16_t)(channel1 - 1);
  modbus::buildWriteCoil(req, slaveId, addr, value);

  uint8_t rx[16];
  size_t rxLen = 0;
  modbus::Status st = modbus::ERR_NO_DATA;
  uint8_t exc = 0;
  if (attempts < 1) attempts = 1;
  for (uint8_t attempt = 0; attempt < attempts; attempt++) {
    rs485Exchange(req, 8, rx, sizeof(rx), rxLen, 8, timeoutMs, lockWaitMs);
    st = modbus::checkWriteCoilEcho(req, 8, rx, rxLen, &exc);
    if (st == modbus::OK) break;
  }

  if (respHex) *respHex = hexString(rx, rxLen);
  if (st == modbus::OK) {
    _extModuleResponding = true;
    return true;
  }
  addRs485Log(String("[EXT ROLE HATA] Slave ") + String(slaveId) + " CH" + String(channel1) + " -> " + statusText(st) +
              (rxLen ? String(" (") + hexString(rx, rxLen) + ")" : String("")));
  return false;
}

// 0x01 / 0x02: count bit oku (count <= 32). bits[0..byteCount-1]'e kopyalanır (LSB-first).
bool SmartAutomation::extReadBits(uint8_t slaveId, uint8_t func, uint8_t count, uint8_t* bits, uint8_t& byteCount) {
  byteCount = 0;
  if (count == 0 || count > 32) return false;
  uint8_t req[8];
  modbus::buildReadBits(req, slaveId, func, 0, count);

  uint8_t rx[16];
  size_t rxLen = 0;
  rs485Exchange(req, 8, rx, sizeof(rx), rxLen, modbus::expectedResponseLen(func, count), 60, 20);

  const uint8_t* data = nullptr;
  uint8_t bc = 0;
  modbus::Status st = modbus::checkReadBits(slaveId, func, count, rx, rxLen, &data, &bc);
  if (st != modbus::OK) return false;
  for (uint8_t i = 0; i < bc && i < 4; i++) bits[i] = data[i];
  byteCount = bc;
  return true;
}

// Panjur rölesi AÇILMADAN hemen önce (SmartAutomation::stepExtOutputs): "eş KAPALI" bilgisi yalnızca önceki KAPAT
// yazımının YANKISINA dayanıyorsa yanlış olabilir (modül yankıyı verip komutu uygulamamış, ya da başka bir Modbus
// master coil'i açmış olabilir). İki yön birden enerjilenirse motor sargısı zarar görür; bu yüzden gerçek coil durumu
// okunur. Eş AÇIK bulunursa durum güncellenir (stepExtOutputs bir sonraki turda KAPAT gönderir) ve AÇMA yapılmaz.
SmartAutomation::ExtReadback SmartAutomation::extReadbackBeforeEnergize(uint8_t slaveId, uint8_t relayIdx) {
  const uint8_t peer = (uint8_t)(relayIdx ^ 1);
  const uint8_t ch = (uint8_t)(relayIdx - 8 + 1);        // 1 tabanlı modül kanalı
  const uint8_t peerCh = (uint8_t)(peer - 8 + 1);
  const uint8_t count = (ch > peerCh) ? ch : peerCh;
  uint8_t bits[4] = {0, 0, 0, 0};
  uint8_t bc = 0;
  if (!extReadBits(slaveId, modbus::FC_READ_COILS, count, bits, bc)) return RB_READ_FAILED;

  const bool peerOn = modbus::getBit(bits, bc, (uint8_t)(peerCh - 1));
  const bool selfOn = modbus::getBit(bits, bc, (uint8_t)(ch - 1));
  if (peerOn) {
    printf("[EXT INTERLOCK] Role %u eşi (Role %u) modülde AÇIK bulundu -> AÇMA yapilmadi, eş kapatilacak.\r\n",
           (unsigned)(relayIdx + 1), (unsigned)(peer + 1));
    _hw[peer] = true;
    _hwKnown[peer] = true;
    _extGuard.commit(InterlockGuard::withRelay(_extGuard.hw(), peer, true), millis());
    markChanged();
    return RB_PEER_ON;
  }
  if (selfOn) {
    // Kendi rölesi zaten AÇIK, oysa "KAPALI" sanılıyordu: önceki KAPAT uygulanmamış demektir ve motor süre planımızın
    // DIŞINDA çalışıyor olabilir. "Çalışıyor say ve devam et" YAPILMAZ: hareket iptal edilir, röle kapatılır.
    printf("[EXT INTERLOCK] Role %u modulde zaten ACIK bulundu (beklenmedik) -> hareket iptal, kapatilacak.\r\n", (unsigned)(relayIdx + 1));
    _hw[relayIdx] = true;
    _hwKnown[relayIdx] = true;
    _extGuard.commit(InterlockGuard::withRelay(_extGuard.hw(), relayIdx, true), millis());
    markChanged();
    return RB_ALREADY_ON;
  }
  return RB_PEER_OFF;
}

// Tüm ek röleleri kapat (adres 0x00FF = hepsi): açılış/yeniden başlatma/acil durum.
bool SmartAutomation::extAllOff() {
  const uint8_t slave = ConfigManager::instance().config.ext_module_address;
  return extWriteCoil(slave, 0, modbus::COIL_OFF, 150, nullptr);
}

// ------------------------------------------------------------------------------------------------
// Ek modül yoklaması (ana döngüden, tur başına en çok BİR işlem)
//   * ~120 ms'de bir girişler (0x02), 1,5 sn'de bir coil durumları (0x01)
//   * Yanıtsız slave: üstel geri çekilme (120 ms -> en çok 5 sn); 3 ardışık hatada "yanıt vermiyor"
// ------------------------------------------------------------------------------------------------
void SmartAutomation::pollExtModule(uint32_t now) {
  auto& cfg = ConfigManager::instance().config;
  if (!cfg.ext_module_enabled) return;
  if (_scanState == ScanState::RUNNING) return;             // tarama hattı tutuyor
  if ((uint32_t)(now - _extPollLast) < _extPollGap) return;  // "son yoklama + bekleme" (24,86 gün aşımına dayanıklı)

  const uint8_t slave = cfg.ext_module_address;
  uint8_t extCh = cfg.ext_module_channels;                  // validate(): {2,4,8,12,16,24,32}
  if (extCh == 0) extCh = 8;
  if (extCh > 32) extCh = 32;

  const bool doCoils = ((uint32_t)(now - _lastExtCoilPoll) >= 1500) || (_lastExtCoilPoll == 0);
  uint8_t bits[4] = {0, 0, 0, 0};
  uint8_t bc = 0;
  const bool ok = extReadBits(slave, doCoils ? modbus::FC_READ_COILS : modbus::FC_READ_DISCRETE_INPUTS, extCh, bits, bc);

  if (!ok) {
    _extFails = (_extFails < 250) ? (uint8_t)(_extFails + 1) : _extFails;
    if (_extFails >= 3 && _extModuleResponding) {
      _extModuleResponding = false;
      printf("[RS485] Ek modul YANIT VERMIYOR (%u ardisik hata) -> geri cekilmeli yoklama.\r\n", (unsigned)_extFails);
      // Durumlar artık bilinmiyor: yeniden doğrulanana dek panjur başlatılmaz, KAPAT komutları yeniden gönderilir.
      for (int i = 8; i < MAX_TOTAL_RELAYS; i++) _hwKnown[i] = false;
      markChanged();
    }
    uint8_t sh = (_extFails > 6) ? 6 : _extFails;
    uint32_t backoff = 120UL << sh;
    if (backoff > 5000UL) backoff = 5000UL;
    _extPollLast = millis();                                // geri çekilme başarısız yoklamanın BİTİŞİNDEN sayılır
    _extPollGap = backoff;
    return;
  }

  if (!_extModuleResponding) {
    _extModuleResponding = true;
    printf("[RS485] Ek modul yanit veriyor.\r\n");
    markChanged();
  }
  _extFails = 0;
  _extPollLast = millis();
  _extPollGap = 120;

  if (doCoils) {
    _lastExtCoilPoll = now ? now : 1;
    uint64_t actual = 0;
    bool changed = false;
    for (uint8_t k = 0; k < extCh; k++) {
      const uint8_t rIdx = (uint8_t)(8 + k);
      if (rIdx >= MAX_TOTAL_RELAYS) break;
      const bool state = modbus::getBit(bits, bc, k);
      if (state) actual |= (1ULL << rIdx);
      if (_hw[rIdx] != state || !_hwKnown[rIdx]) changed = true;
      _hw[rIdx] = state;
      _hwKnown[rIdx] = true;
      if (_adoptNextPoll[rIdx]) {            // ham TOGGLE sonrası fiziksel durumu benimse
        _want[rIdx] = state;
        _adoptNextPoll[rIdx] = false;
      }
    }
    // Sürücü seviyesi kural durumunu GERÇEK donanıma eşitle (bayat bitleri temizler)
    if (actual != _extGuard.hw()) _extGuard.commit(actual, millis());     // GERÇEK an (bkz. stepExtOutputs saat kuralı)
    if (changed) markChanged();
    return;
  }

  // Girişler: ilk başarılı okumada kenar üretmeden başlat
  if (!_extDiInit) {
    _extDiInit = true;
    for (uint8_t k = 0; k < extCh; k++) {
      const uint8_t dIdx = (uint8_t)(8 + k);
      if (dIdx >= MAX_TOTAL_DIS) break;
      _diGate.init(dIdx, modbus::getBit(bits, bc, k), now);
    }
    return;
  }
  for (uint8_t k = 0; k < extCh; k++) {
    const uint8_t dIdx = (uint8_t)(8 + k);
    if (dIdx >= MAX_TOTAL_DIS) break;
    handleDiEdge(dIdx, modbus::getBit(bits, bc, k), now);   // yerel DI ile AYNI kapı (çocuk kilidi dahil)
  }
}

// ------------------------------------------------------------------------------------------------
// Bağlı olmayan/ilgisiz trafik izleme (terminal günlüğü): TOPLAM süre ≤ 5 ms ve ≤ 64 bayt, bloklamaz
// ------------------------------------------------------------------------------------------------
void SmartAutomation::checkRs485Incoming() {
  if (_rs485Mutex == nullptr || _scanState == ScanState::RUNNING) return;
  if (!Serial1.available()) return;
  if (xSemaphoreTake(_rs485Mutex, 0) != pdTRUE) return;      // başka işlem hattı kullanıyor

  const uint32_t t0 = millis();
  uint8_t buf[64];
  size_t n = 0;
  while (n < sizeof(buf) && (uint32_t)(millis() - t0) < 5) {
    if (!Serial1.available()) break;
    buf[n++] = (uint8_t)Serial1.read();
  }
  xSemaphoreGive(_rs485Mutex);

  if (n > 0) {
    String ascii;
    for (size_t i = 0; i < n; i++) ascii += (buf[i] >= 32 && buf[i] <= 126) ? (char)buf[i] : '.';
    addRs485Log("[RX] HEX: " + hexString(buf, n) + "| ASCII: " + ascii);
  }
}

// ------------------------------------------------------------------------------------------------
// Günlük (dairesel tampon) — çok görevli erişim güvenli
// ------------------------------------------------------------------------------------------------
void SmartAutomation::addRs485Log(const String& line) {
  if (_logMutex == nullptr || xSemaphoreTake(_logMutex, pdMS_TO_TICKS(20)) != pdTRUE) return;   // günlük kaybı, hat kaybı değil

  char timeBuf[16];
  uint32_t sec = millis() / 1000;
  snprintf(timeBuf, sizeof(timeBuf), "[%02u:%02u:%02u] ", (unsigned)((sec / 3600) % 24), (unsigned)((sec / 60) % 60), (unsigned)(sec % 60));

  if (_rs485LogCount < RS485_LOG_MAX) {
    _rs485Logs[_rs485LogCount++] = String(timeBuf) + line;
  } else {
    for (int i = 1; i < RS485_LOG_MAX; i++) _rs485Logs[i - 1] = _rs485Logs[i];
    _rs485Logs[RS485_LOG_MAX - 1] = String(timeBuf) + line;
  }
  xSemaphoreGive(_logMutex);
}

String SmartAutomation::rs485GetLogs() {
  String out;
  if (_logMutex == nullptr || xSemaphoreTake(_logMutex, pdMS_TO_TICKS(50)) != pdTRUE) return out;
  for (int i = 0; i < _rs485LogCount; i++) out += _rs485Logs[i] + "\n";
  xSemaphoreGive(_logMutex);
  return out;
}

void SmartAutomation::rs485ClearLogs() {
  if (_logMutex == nullptr || xSemaphoreTake(_logMutex, pdMS_TO_TICKS(50)) != pdTRUE) return;
  _rs485LogCount = 0;
  xSemaphoreGive(_logMutex);
}

// ------------------------------------------------------------------------------------------------
// Ham gönderim (servis terminali / CLI "SEND")
// ------------------------------------------------------------------------------------------------
// Röle kontrol kanalı panjur çifti mi? (ek modül kanalı 1 tabanlı)
static bool extChannelIsShutter(uint8_t channel1) {
  auto& cfg = ConfigManager::instance().config;
  uint8_t rIdx = (uint8_t)(8 + channel1 - 1);
  if (channel1 == 0 || rIdx >= MAX_TOTAL_RELAYS) return false;
  uint8_t t = cfg.relays[rIdx].type;
  return t == RELAY_TYPE_SHUTTER_UP || t == RELAY_TYPE_SHUTTER_DOWN;
}

bool SmartAutomation::rs485Send(const String& data, bool isHex) {
  _rawSafetyRej = false;
  if (data.isEmpty()) return false;

  uint8_t frame[64];
  size_t len = 0;

  if (isHex) {
    String clean;
    for (size_t i = 0; i < data.length(); i++) {
      char c = data[i];
      if (isxdigit((unsigned char)c)) clean += c;
    }
    if (clean.length() == 0 || clean.length() % 2 != 0) {
      addRs485Log("[Hata] Gecersiz HEX verisi: Uzunluk cift olmalidir!");
      return false;
    }
    len = clean.length() / 2;
    if (len > sizeof(frame)) {
      addRs485Log("[Hata] HEX verisi cok uzun (en cok 64 bayt).");
      return false;
    }
    for (size_t i = 0; i < len; i++) {
      char byteStr[3] = {clean[i * 2], clean[i * 2 + 1], '\0'};
      frame[i] = (uint8_t)strtol(byteStr, NULL, 16);
    }

    // GÜVENLİK: ham çerçeve interlock'u atlayamaz. Yalnızca OKUMA işlevleri ve panjur olmayan kanala 0x05.
    if (len < 4) {
      addRs485Log("[RED] Cerceve cok kisa.");
      return false;
    }
    const uint8_t fn = frame[1];
    if (fn == modbus::FC_READ_COILS || fn == modbus::FC_READ_DISCRETE_INPUTS || fn == modbus::FC_READ_HOLDING || fn == 0x04) {
      // serbest (salt okuma)
    } else if (fn == modbus::FC_WRITE_SINGLE_COIL && len == 8) {
      const uint16_t addr = (uint16_t)((frame[2] << 8) | frame[3]);
      const uint16_t val = (uint16_t)((frame[4] << 8) | frame[5]);
      const bool energize = (val != modbus::COIL_OFF);
      if (addr == 0x00FF && energize) {
        addRs485Log("[RED] Toplu ACMA (adres 0x00FF) ham gonderimde yasak: panjur interlock'u atlanir.");
        return false;
      }
      if (addr != 0x00FF && energize && addr < 32 && extChannelIsShutter((uint8_t)(addr + 1))) {
        addRs485Log("[RED] Panjur kanalina ham ACMA yasak (interlock/olu zaman ShutterFsm'dedir).");
        return false;
      }
      // Güvenlik eylemcisi kanalı (spec §2.3 madde 4 [B2][Y-6]): yalnız güvenli yöne giden yazım; toplu yazım ve TOGGLE
      // ek modülde eylemci varken reddedilir. Eylemci yoksa hiç tutmaz.
      auto& sm = safety::SafetyManager::instance();
      if (sm.hasExtActuator()) {
        const bool toggle = (val == modbus::COIL_TOGGLE);
        if (addr == 0x00FF || toggle ||
            (addr < 32 && sm.rawRelayCheck((uint8_t)(8 + addr + 1), energize) == safety::RawDecision::REJECT)) {
          addRs485Log("[RED] Guvenlik eylemcisi kanalina acma/toplu/TOGGLE ham yazim yasak (actuator_relay).");
          _rawSafetyRej = true;
          return false;
        }
      }
    } else {
      addRs485Log("[RED] Bu Modbus islevi ham gonderimde yasak (yalniz 0x01-0x04 okuma ve tek coil 0x05).");
      return false;
    }
  } else {
    // ASCII: yalnızca yazdırılabilir karakter + CR/LF. (Geçerli bir Modbus yazma çerçevesi 0x00/0xFF bayt
    // gerektirir; bunlar ASCII'de oluşamaz.)
    len = data.length();
    if (len > sizeof(frame)) len = sizeof(frame);
    for (size_t i = 0; i < len; i++) {
      uint8_t c = (uint8_t)data[i];
      if (!((c >= 0x20 && c <= 0x7E) || c == '\r' || c == '\n')) {
        addRs485Log("[RED] ASCII gonderimde kontrol/ASCII-disi karakter yasak.");
        return false;
      }
      frame[i] = c;
    }
  }

  uint8_t rx[64];
  size_t rxLen = 0;
  const bool got = rs485Exchange(frame, len, rx, sizeof(rx), rxLen, 0, 150, 200);
  if (isHex) {
    addRs485Log("[TX HEX] " + hexString(frame, len));
    Serial.printf("[RS485-TX] HEX: %s\r\n", hexString(frame, len).c_str());
  } else {
    addRs485Log("[TX ASCII] " + data);
    Serial.printf("[RS485-TX] ASCII: %s\r\n", data.c_str());
  }
  if (got) {
    addRs485Log("[RX] HEX: " + hexString(rx, rxLen));
    Serial.printf("[RS485-RX] HEX: %s\r\n", hexString(rx, rxLen).c_str());
  }
  // Ham tek-coil yazımı (0x05) yapılandırılmış ek modüle gittiyse UYGULAMA durumuna da yansıtılır (aşağıda).
  if (isHex && got && len == 8 && frame[1] == modbus::FC_WRITE_SINGLE_COIL) mirrorRawCoilWrite(frame, rx, rxLen);
  return true;
}

// ------------------------------------------------------------------------------------------------
// Ham tek-coil yazımının (0x05, /api/rs485/send ve CLI "SEND") UYGULAMA durumuna yansıtılması.
// Eskiden ham yazım "istenen durum" (want) ile ilgisizdi: coil yoklaması (<= ~1,5 sn) rolenin istenen durumuna geri döndürür
// (ham AÇ geri kapanır, ham KAPAT'ı panjur FSM'i geri açardı). Artık yapılandırılmış ek modüle yapılan, YANKISI DOĞRULANMIŞ
// ham yazım, "CH n" komutuyla aynı sonucu verir: ON/OFF -> RELAY_SET, TOGGLE (0x5500) -> RELAY_TOGGLE. Panjur kanalına AÇ/TOGGLE
// zaten reddedilmiştir; panjur kanalına KAPAT -> RELAY_SET 0 = panjuru DURDURUR (FSM de durur, röle yeniden açılmaz).
// rs485Send() başka görevden (WebTask) çağrılabildiği için durum doğrudan DEĞİŞTİRİLMEZ: komut kuyruğuna yazılır.
// Toplu KAPAT (adres 0x00FF) _rawExtAllOff bayrağıyla loop()'ta işlenir (kuyruk 24 komuttur, 32 röleye yetmez).
// Başka slave'e / modül kapalıyken yapılan ham yazım uygulama durumunu ETKİLEMEZ.
// ------------------------------------------------------------------------------------------------
void SmartAutomation::mirrorRawCoilWrite(const uint8_t* req, const uint8_t* rx, size_t rxLen) {
  auto& cfg = ConfigManager::instance().config;
  if (!cfg.ext_module_enabled || req[0] != cfg.ext_module_address) return;
  uint8_t exc = 0;
  if (modbus::checkWriteCoilEcho(req, 8, rx, rxLen, &exc) != modbus::OK) return;     // yankı doğrulanmadan yansıtılmaz
  const uint16_t addr = (uint16_t)((req[2] << 8) | req[3]);
  const uint16_t val = (uint16_t)((req[4] << 8) | req[5]);
  if (addr == 0x00FF) {
    if (val == modbus::COIL_OFF) _rawExtAllOff = true;                                // (toplu AÇ zaten reddedilmiştir)
    return;
  }
  if (addr >= 32) return;
  const uint8_t relayIdx = (uint8_t)(8 + addr);
  if (relayIdx >= cfg.totalRelays()) return;
  const uint8_t cmdIndex = (uint8_t)(relayIdx + 1);                                   // komutlarda 1 tabanlı
  bool posted = true;
  if (val == modbus::COIL_ON) posted = postDeviceCommand(makeCommand(CmdType::RELAY_SET, CmdSource::WEB, cmdIndex, 1));
  else if (val == modbus::COIL_OFF) posted = postDeviceCommand(makeCommand(CmdType::RELAY_SET, CmdSource::WEB, cmdIndex, 0));
  else if (val == modbus::COIL_TOGGLE) posted = postDeviceCommand(makeCommand(CmdType::RELAY_TOGGLE, CmdSource::WEB, cmdIndex));
  if (!posted) addRs485Log("[UYARI] Ham yazim modulde uygulandi ama uygulama durumuna yansitilamadi (komut kuyrugu dolu): coil yoklamasi geri dondurebilir.");
}

// Ham toplu KAPAT (0x00FF) modülde uygulandı: ek panjurlar durdurulur, ek röleler istenmeyen olarak işaretlenir, durumları
// yeniden doğrulanır (KAPAT yeniden gönderilir / coil okunur). Aksi halde coil yoklaması istenen (AÇIK) lambaları geri açardı.
void SmartAutomation::applyRawExtAllOff(uint32_t now) {
  if (!_rawExtAllOff) return;
  _rawExtAllOff = false;
  auto& cfg = ConfigManager::instance().config;
  if (!cfg.ext_module_enabled) return;
  const uint8_t totalR = cfg.totalRelays();
  for (uint8_t p = 4; p < MAX_PAIRS; p++) {
    if (_fsm[p].isMoving() || _fsm[p].isWaiting()) _fsm[p].forceStop(now);
  }
  for (uint8_t i = 8; i < totalR; i++) {
    _want[i] = false;
    _impulseActive[i] = false;
    _adoptNextPoll[i] = false;
    _hwKnown[i] = false;
  }
  markChanged();
}

// ------------------------------------------------------------------------------------------------
// Ham ek modül röle komutu (servis/CLI). action: 1 AÇ, 0 KAPAT, 2 TOGGLE (Waveshare 0x5500)
// Yalnızca loop görevinden. Panjur kanallarını ve channel=0 toplu AÇMAYI reddeder (kapatma serbest).
// ------------------------------------------------------------------------------------------------
bool SmartAutomation::rs485ControlExtRelay(uint8_t slaveId, uint8_t channel, uint8_t action, String* responseHex) {
  if (responseHex) *responseHex = "";
  if (_loopTask != nullptr && xTaskGetCurrentTaskHandle() != _loopTask) {
    addRs485Log("[RED] Ham ek modul komutu yalnizca loop gorevinden yapilabilir.");
    return false;
  }
  if (action > 2) {
    addRs485Log("[RED] Gecersiz eylem (0=KAPAT, 1=AC, 2=TOGGLE).");
    return false;
  }
  if (channel > 32) {
    addRs485Log("[RED] Gecersiz kanal (0=hepsi, 1..32).");
    return false;
  }
  const bool energizes = (action != 0);
  if (channel == 0 && energizes) {
    addRs485Log("[RED] Toplu ACMA (channel=0) yasak: panjur interlock'u atlanir.");
    return false;
  }
  if (energizes && extChannelIsShutter(channel)) {
    addRs485Log("[RED] Panjur kanalina ham ACMA/TOGGLE yasak (ShutterFsm uzerinden kullanin).");
    return false;
  }
  // Güvenlik eylemcisi kanalı (spec §2.3 madde 4 [B2]): toplu yazım ve TOGGLE reddedilir; tek kanalda yalnız güvenli yön
  // (çekirdeğe "kullanıcı kapattı" bildirilir). Ek modülde eylemci yoksa hiç tutmaz.
  {
    auto& sm = safety::SafetyManager::instance();
    if (sm.hasExtActuator() && slaveId == ConfigManager::instance().config.ext_module_address) {
      const uint8_t relay1 = (uint8_t)(8 + channel);
      const bool isAct = channel != 0 && sm.actuatorOfRelay(relay1) >= 0;
      if (channel == 0 || (isAct && action == 2) ||
          (isAct && sm.rawRelay(relay1, action == 1, CmdSource::CLI, millis()) == safety::RawDecision::REJECT)) {
        addRs485Log("[RED] Guvenlik eylemcisi kanalina acma/toplu/TOGGLE ham komut yasak (actuator_relay).");
        return false;
      }
    }
  }
  if (_scanState == ScanState::RUNNING) {
    addRs485Log("[RED] RS485 taramasi suruyor.");
    return false;
  }

  const uint16_t value = (action == 1) ? modbus::COIL_ON : (action == 0 ? modbus::COIL_OFF : modbus::COIL_TOGGLE);
  const bool ok = extWriteCoil(slaveId, channel, value, 200, responseHex);
  if (ok) {
    addRs485Log(String("[EXT ROLE] Slave ") + String(slaveId) + " CH" + String(channel) + " Eylem:" + String(action) + " -> OK");
    // Yapılandırılmış modülün durumunu istenen duruma eşitle (başka slave'e ham yazım uygulama durumunu etkilemez)
    auto& cfg = ConfigManager::instance().config;
    if (slaveId == cfg.ext_module_address && cfg.ext_module_enabled) {
      auto touch = [&](uint8_t rIdx) {
        if (rIdx >= MAX_TOTAL_RELAYS || rIdx >= cfg.totalRelays()) return;
        if (action == 2) {                    // toggle: sonuç bilinmez -> bir sonraki coil okumasında benimse
          _hwKnown[rIdx] = false;
          _adoptNextPoll[rIdx] = true;
          _lastExtCoilPoll = 0;               // coil okumasını öne çek
        } else {
          _want[rIdx] = (action == 1);
          _hw[rIdx] = (action == 1);
          _hwKnown[rIdx] = true;
          _extGuard.commit(InterlockGuard::withRelay(_extGuard.hw(), rIdx, action == 1), millis());
          if (action == 0) {
            _extGuard.noteOff(rIdx, millis());   // onaylı KAPAT: ölü zaman bu andan sayılır (inanç yanlış olsa bile)
            // Ham KAPAT bir panjur kanalını söndürdüyse durum makinesi de durdurulur; aksi halde çıkış katmanı
            // FSM "hareket ediyor" diye rölenin YENİDEN AÇILMASINI isterdi (operatörün durdurma niyeti çiğnenirdi).
            const uint8_t p = rIdx / 2;
            if (p < MAX_PAIRS && _pairValid[p] && (_fsm[p].isMoving() || _fsm[p].isWaiting())) _fsm[p].forceStop(millis());
          }
        }
      };
      if (channel == 0) { for (uint8_t i = 8; i < cfg.totalRelays(); i++) touch(i); }
      else touch((uint8_t)(8 + channel - 1));
      markChanged();
    }
  }
  return ok;
}

// ------------------------------------------------------------------------------------------------
// BLOKLAMAYAN TARAMA (F4): ayrı görev; ana döngü/panjur zamanlayıcıları taramadan etkilenmez.
// Tarama süresince hat mutex'i görevdedir: ek röle yazımları/yoklama atlanır (mevcut durum korunur).
// ------------------------------------------------------------------------------------------------
// Ek modül panjur çiftlerinden biri hareket ediyor/bekliyor mu? Tarama RS485 hattını (mutex) saniyelerce tutar:
// o sürede KAPAT gönderilemez (hareket eden panjur planlanan süreden sonra da dönerdi). Anlık görüntü iş parçacığı
// güvenlidir; okunamazsa güvenli taraf (meşgul) varsayılır.
bool SmartAutomation::extShutterBusy() const {
  AutomationSnapshot s;
  if (!getSnapshot(s)) return true;
  for (uint8_t p = 4; p < MAX_PAIRS; p++) {
    if (s.shutters[p].moving || s.shutters[p].waiting) return true;
  }
  return false;
}

bool SmartAutomation::tryEnterScan() {
  if (_scanMutex == nullptr || xSemaphoreTake(_scanMutex, pdMS_TO_TICKS(200)) != pdTRUE) return false;
  bool entered = false;
  if (_scanState != ScanState::RUNNING) {
    if (safety::SafetyManager::instance().scanBlocked()) {
      // Tarama sürerken ek modül yazımı/yoklaması durur: kilitli bölge ya da ek modülde eylemci/güvenlik sensörü varken
      // güvenlik kör kalırdı [O-5][B6] (409 safety_active).
      addRs485Log("[RED] Tarama baslatilamadi: guvenlik katmani etkin (kilit ya da ek modulde eylemci/sensor).");
    } else if (extShutterBusy()) {
      addRs485Log("[RED] Tarama baslatilamadi: ek modul panjuru hareket halinde (once durdurun).");
    } else {
      _scanState = ScanState::RUNNING;
      entered = true;
    }
  }
  xSemaphoreGive(_scanMutex);
  return entered;
}

bool SmartAutomation::rs485StartScan(uint32_t specificBaud) {
  if (specificBaud != 0 && !isAllowedBaud(specificBaud)) return false;
  if (!tryEnterScan()) return false;            // zaten çalışıyor
  _scanArg = specificBaud;
  BaseType_t r = xTaskCreatePinnedToCore(scanTask, "rs485_scan", 6144, this, 1, nullptr, 0);
  if (r != pdPASS) {
    _scanState = ScanState::IDLE;
    printf("[RS485] Tarama gorevi olusturulamadi (bellek).\r\n");
    return false;
  }
  return true;
}

void SmartAutomation::scanTask(void* arg) {
  SmartAutomation* self = static_cast<SmartAutomation*>(arg);
  esp_task_wdt_add(NULL);
  self->runScanBody(self->_scanArg);
  esp_task_wdt_delete(NULL);
  vTaskDelete(NULL);
}

void SmartAutomation::runScanBody(uint32_t specificBaud) {
  Rs485ScanResult res;
  res.found = false;
  res.slaveId = 0;
  res.baud = 0;
  res.relayStatus = 0;
  res.rawHex = "";
  res.info = "Hicbir RS485 yaniti alinamadi.";

  const uint32_t originalBaud = _rs485Baud ? _rs485Baud : 9600;
  uint32_t baudsToTest[6];
  int numBauds = 0;
  if (specificBaud > 0) {
    baudsToTest[numBauds++] = specificBaud;
  } else {
    baudsToTest[numBauds++] = originalBaud;
    if (originalBaud != 9600) baudsToTest[numBauds++] = 9600;
    if (originalBaud != 38400) baudsToTest[numBauds++] = 38400;
    if (originalBaud != 115200) baudsToTest[numBauds++] = 115200;
    if (originalBaud != 19200) baudsToTest[numBauds++] = 19200;
    if (originalBaud != 4800) baudsToTest[numBauds++] = 4800;
  }

  // Hattı al (en çok 3 sn bekle; diğer işlemler kısa süreli olduğundan alınır)
  bool locked = false;
  for (int i = 0; i < 30 && !locked; i++) {
    esp_task_wdt_reset();
    locked = (xSemaphoreTake(_rs485Mutex, pdMS_TO_TICKS(100)) == pdTRUE);
  }
  if (!locked) {
    res.info = "RS485 hatti mesgul, tarama yapilamadi.";
  } else {
    Serial.printf("\r\n--- [RS485 TARAMA BASLATILIYOR] ---\r\n");
    addRs485Log("[Tarama] Harici role modulu araniyor...");
    bool found = false;

    for (int b = 0; b < numBauds && !found; b++) {
      const uint32_t baud = baudsToTest[b];
      applyRs485Pins(baud);
      _rs485Baud = baud;
      vTaskDelay(pdMS_TO_TICKS(20));

      for (uint8_t sid = 1; sid <= 8 && !found; sid++) {
        esp_task_wdt_reset();
        vTaskDelay(pdMS_TO_TICKS(10));
        uint8_t req[8];
        uint8_t rx[32];
        size_t rxLen = 0;

        // 1) 0x01 Read Coils (8). Yanıt CRC/adres/işlev/uzunluk doğrulamasından geçmeli.
        modbus::buildReadBits(req, sid, modbus::FC_READ_COILS, 0, 8);
        rs485ExchangeLocked(req, 8, rx, sizeof(rx), rxLen, modbus::expectedResponseLen(modbus::FC_READ_COILS, 8), 120);
        const uint8_t* data = nullptr;
        uint8_t bc = 0;
        modbus::Status st = modbus::checkReadBits(sid, modbus::FC_READ_COILS, 8, rx, rxLen, &data, &bc);
        if (st == modbus::OK) {
          res.found = true;
          res.slaveId = sid;
          res.baud = baud;
          res.relayStatus = (bc >= 1) ? data[0] : 0;
          res.rawHex = hexString(rx, rxLen);
          res.info = "Modbus RTU Standard Yanit (CRC Dogru)";
          addRs485Log("[BULUNDU] Slave ID: " + String(sid) + " (" + String(baud) + " baud) | Role Durumu: 0x" + String(res.relayStatus, HEX));
          Serial.printf("  ===> BASARILI! Harici Role Modulu bulundu: Slave ID: %u, Baud: %u, Durum: 0x%02X\r\n",
                        (unsigned)sid, (unsigned)baud, res.relayStatus);
          found = true;
          break;
        }

        // 2) 0x03 Read Holding Registers (2): CRC + adres + işlev doğrula
        modbus::buildReadBits(req, sid, modbus::FC_READ_HOLDING, 0, 2);
        rs485ExchangeLocked(req, 8, rx, sizeof(rx), rxLen, 0, 100);
        if (rxLen >= 5 && modbus::frameCrcOk(rx, rxLen) && rx[0] == sid && rx[1] == modbus::FC_READ_HOLDING) {
          res.found = true;
          res.slaveId = sid;
          res.baud = baud;
          res.rawHex = hexString(rx, rxLen);
          res.info = "Modbus 0x03 Register Yaniti (CRC Dogru)";
          addRs485Log("[BULUNDU] Slave ID: " + String(sid) + " (" + String(baud) + " baud, 0x03)");
          found = true;
          break;
        }
      }
    }

    if (found) {
      // Cihazın baud hızı tespit edilene güncellenir (kalıcı kayıt çağıranın kararıdır)
      ConfigManager::instance().config.rs485_baud = res.baud;
    } else {
      applyRs485Pins(originalBaud);
      _rs485Baud = originalBaud;
      addRs485Log("[Tarama] Harici modulden yanit alinamadi. A/B klemenslerini ve 12V/24V beslemeyi kontrol edin.");
      Serial.printf("[Tarama] Hicbir harici modul yanit vermedi. A/B baglantilarini veya beslemeyi kontrol edin.\r\n");
    }
    xSemaphoreGive(_rs485Mutex);
    Serial.printf("--- [RS485 TARAMA TAMAMLANDI] ---\r\n\r\n");
  }

  if (_scanMutex && xSemaphoreTake(_scanMutex, pdMS_TO_TICKS(200)) == pdTRUE) {
    _scanResult = res;
    xSemaphoreGive(_scanMutex);
  }
  _scanDoneAt = millis();
  _scanState = ScanState::DONE;
}

SmartAutomation::Rs485ScanResult SmartAutomation::rs485ScanResult() {
  Rs485ScanResult copy;
  copy.found = false;
  copy.slaveId = 0;
  copy.baud = 0;
  copy.relayStatus = 0;
  if (_scanMutex && xSemaphoreTake(_scanMutex, pdMS_TO_TICKS(200)) == pdTRUE) {
    copy = _scanResult;
    xSemaphoreGive(_scanMutex);
  }
  return copy;
}

// UYUMLULUK: eski çağrı. loop görevinden bloklamaz (arka plan görevi); başka görevden SENKRON çalışır.
SmartAutomation::Rs485ScanResult SmartAutomation::rs485ScanModule(uint32_t specificBaud) {
  Rs485ScanResult res;
  res.found = false;
  res.slaveId = 0;
  res.baud = 0;
  res.relayStatus = 0;

  const bool inLoopTask = (_loopTask != nullptr && xTaskGetCurrentTaskHandle() == _loopTask);

  if (inLoopTask) {
    if (_scanState == ScanState::RUNNING) {
      res.info = "RS485 taramasi suruyor; birkac saniye sonra sonucu yeniden sorgulayin.";
      return res;
    }
    if (_scanState == ScanState::DONE && (uint32_t)(millis() - _scanDoneAt) < 30000UL) {
      return rs485ScanResult();      // yakın zamanda tamamlanmış sonuç
    }
    if (rs485StartScan(specificBaud)) {
      res.info = "RS485 taramasi arka planda baslatildi; birkac saniye sonra sonucu yeniden sorgulayin.";
    } else {
      res.info = "RS485 taramasi baslatilamadi (ek modul panjuru hareket halindeyse once durdurun).";
    }
    return res;
  }

  // Çağıran zaten ayrı bir görev: taramayı burada yürüt (ana döngü etkilenmez)
  if (specificBaud != 0 && !isAllowedBaud(specificBaud)) {
    res.info = "Gecersiz baud.";
    return res;
  }
  if (!tryEnterScan()) {
    res.info = "RS485 taramasi baslatilamadi: zaten suruyor ya da ek modul panjuru hareket halinde.";
    return res;
  }
  runScanBody(specificBaud);
  return rs485ScanResult();
}
