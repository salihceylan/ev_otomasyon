// safety/SafetyStore.cpp - NVS kalıcılığı (bkz. SafetyStore.h). Ham ESP-IDF nvs API'si kullanılır: salt okuma açılışında ad
// alanı yoksa hata logu basılmaz (Preferences::begin(ns, true) "NOT_FOUND" log_e basardı).
#include "safety/SafetyStore.h"
#include <nvs.h>
#include <nvs_flash.h>
#include <stdlib.h>
#include <stdio.h>

namespace safety {

namespace {

const char* const K_VER = "ver";
const char* const K_REV = "rev";
const char* const K_POL = "pol";
const char* const K_ZONES = "zones";
const char* const K_SENS = "sens";
const char* const K_ACT = "act";
const char* const K_LIGHT = "light";
const char* const K_LATCH = "latch";
const char* const K_ACTPOS = "act_pos";
const char* const K_BOOTC = "bootc";
const char* const K_CRASH = "crash";
const char* const K_SIREN = "siren_s";
const char* const K_SAFEMSK = "safe_msk";
const char* const K_DIHIST = "di_hist";

struct Handle {
  nvs_handle_t h;
  bool ok;
  Handle(const char* ns, nvs_open_mode_t mode) : h(0), ok(nvs_open(ns, mode, &h) == ESP_OK) {}
  ~Handle() { if (ok) nvs_close(h); }
};

// Blob okuma: boyut sorgulanır, geçici arabelleğe okunur, öğeler + CRC doğrulanır. -1: yok, -2: bozuk, >= 0: öğe sayısı.
int readItems(nvs_handle_t h, const char* key, size_t itemSize, void* items, uint8_t maxN) {
  size_t len = 0;
  esp_err_t e = nvs_get_blob(h, key, nullptr, &len);
  if (e == ESP_ERR_NVS_NOT_FOUND) return -1;
  if (e != ESP_OK || len == 0 || len > (size_t)maxN * itemSize + 4) return -2;
  uint8_t* buf = (uint8_t*)malloc(len);
  if (!buf) return -2;
  int n = -2;
  if (nvs_get_blob(h, key, buf, &len) == ESP_OK) {
    n = unpackBlob(buf, len, itemSize, items, maxN);
    if (n < 0) n = -2;
  }
  free(buf);
  return n;
}

bool writeItems(nvs_handle_t h, const char* key, const void* items, uint8_t n, size_t itemSize) {
  const size_t cap = (size_t)n * itemSize + 4;
  uint8_t* buf = (uint8_t*)malloc(cap);
  if (!buf) return false;
  const size_t len = packBlob(items, n, itemSize, buf, cap);
  const bool ok = len > 0 && nvs_set_blob(h, key, buf, len) == ESP_OK;
  free(buf);
  return ok;
}

}  // namespace

bool SafetyStore::readBootLatchLocal(uint8_t& localLevel) {
  localLevel = 0;
  // Arduino çekirdeği setup()'tan önce nvs_flash_init() çağırır; ikinci çağrı ESP_OK döner (zararsız). Yine de çekirdekten
  // bağımsız olmak için burada da çağrılır: bölüm başlatılamazsa kayıt okunmaz ve bugünkü davranış (hepsi KAPALI) sürer.
  if (nvs_flash_init() != ESP_OK) return false;
  LatchRecord r;
  if (loadLatch(r) && latchAny(r)) localLevel = (uint8_t)(r.m.localLevel & r.m.localAssert);
  uint64_t sa = 0, sl = 0;
  if (loadSafeMask(sa, sl)) localLevel = (uint8_t)(localLevel | (uint8_t)(sl & sa & 0xFF));   // kilit kaydının dayatmadığı bitler
  return localLevel != 0;
}

void SafetyStore::loadConfig(SafetyConfig& c, bool& present, bool& crcOk) {
  c.setDefaults();
  present = false;
  crcOk = true;
  Handle hd(NVS_NS_SAFETY, NVS_READONLY);
  if (!hd.ok) return;                                      // ad alanı yok: fabrika varsayılanı
  uint8_t ver = 0;
  if (nvs_get_u8(hd.h, K_VER, &ver) != ESP_OK) return;
  present = true;
  if (ver != SAFETY_SCHEMA_VER) { crcOk = false; c.setDefaults(); return; }
  nvs_get_u32(hd.h, K_REV, &c.rev);
  // Doğrudan hedefe okunur; herhangi bir blob bozuksa YARIM yapılandırma kullanılmaz: fabrika varsayılanına dönülür
  // (güvenli kip kararı çağıranda, decideBootMode). Geçici kopya tutulmaz (~2,5 KB RAM).
  int n;
  if ((n = readItems(hd.h, K_POL, sizeof(Policy), &c.pol, 1)) != 1) crcOk = false;
  if (crcOk && (n = readItems(hd.h, K_ZONES, sizeof(ZoneConfig), c.zones, MAX_ZONES)) != MAX_ZONES) crcOk = false;
  if (crcOk) {
    n = readItems(hd.h, K_SENS, sizeof(SensorConfig), c.sens, MAX_SENSORS);
    if (n == -2) crcOk = false; else c.nSens = (uint8_t)(n < 0 ? 0 : n);
  }
  if (crcOk) {
    n = readItems(hd.h, K_ACT, sizeof(ActuatorConfig), c.act, MAX_ACTUATORS);
    if (n == -2) crcOk = false; else c.nAct = (uint8_t)(n < 0 ? 0 : n);
  }
  if (crcOk && readItems(hd.h, K_LIGHT, sizeof(LightOpt), c.light, MAX_RELAYS) == -2) crcOk = false;
  if (!crcOk) c.setDefaults();
}

bool SafetyStore::saveConfig(const SafetyConfig& c, bool* touched, bool checkRoom) {
  if (touched) *touched = false;
  nvs_stats_t st;
  if (checkRoom && nvs_get_stats(nullptr, &st) == ESP_OK && !nvsRoomForConfig((uint32_t)st.free_entries, c)) {
    printf("[GUVENLIK] NVS bos girdi yetersiz (%u bos): yapilandirma yazilmadi.\r\n", (unsigned)st.free_entries);
    return false;                                          // kilit kaydı payı korunur [RV-3]
  }
  Handle hd(NVS_NS_SAFETY, NVS_READWRITE);
  if (!hd.ok) return false;
  if (touched) *touched = true;
  bool ok = nvs_set_u8(hd.h, K_VER, 0) == ESP_OK;          // geçersiz işaret: yarıda kalırsa açılışta cfg_corrupt [RV-4]
  ok = ok && writeItems(hd.h, K_POL, &c.pol, 1, sizeof(Policy));
  ok = ok && writeItems(hd.h, K_ZONES, c.zones, MAX_ZONES, sizeof(ZoneConfig));
  ok = ok && writeItems(hd.h, K_SENS, c.sens, c.nSens, sizeof(SensorConfig));
  ok = ok && writeItems(hd.h, K_ACT, c.act, c.nAct, sizeof(ActuatorConfig));
  ok = ok && writeItems(hd.h, K_LIGHT, c.light, MAX_RELAYS, sizeof(LightOpt));
  ok = ok && nvs_set_u32(hd.h, K_REV, c.rev) == ESP_OK;
  ok = ok && nvs_set_u8(hd.h, K_VER, SAFETY_SCHEMA_VER) == ESP_OK;
  return ok && nvs_commit(hd.h) == ESP_OK;
}

bool SafetyStore::loadLatch(LatchRecord& r) {
  latchClear(r);
  Handle hd(NVS_NS_LATCH, NVS_READONLY);
  if (!hd.ok) return false;
  LatchRecord t;
  size_t len = sizeof(t);
  if (nvs_get_blob(hd.h, K_LATCH, &t, &len) != ESP_OK || len != sizeof(t) || !latchValid(t)) return false;
  r = t;
  return true;
}

bool SafetyStore::saveLatch(const LatchRecord& r) {
  Handle hd(NVS_NS_LATCH, NVS_READWRITE);
  if (!hd.ok) return false;
  return nvs_set_blob(hd.h, K_LATCH, &r, sizeof(r)) == ESP_OK && nvs_commit(hd.h) == ESP_OK;
}

bool SafetyStore::reserveLatch() {
  {
    Handle hd(NVS_NS_LATCH, NVS_READONLY);
    size_t len = 0;
    if (hd.ok && nvs_get_blob(hd.h, K_LATCH, nullptr, &len) == ESP_OK) return true;
  }
  LatchRecord r;
  latchClear(r);
  return saveLatch(r);
}

bool SafetyStore::loadSafeMask(uint64_t& assertMask, uint64_t& levelMask) {
  assertMask = levelMask = 0;
  Handle hd(NVS_NS_LATCH, NVS_READONLY);
  uint64_t v[2] = {0, 0};
  size_t len = sizeof(v);
  if (!hd.ok || nvs_get_blob(hd.h, K_SAFEMSK, v, &len) != ESP_OK || len != sizeof(v)) return false;
  assertMask = v[0];
  levelMask = v[1] & v[0];
  return true;
}

bool SafetyStore::saveSafeMask(uint64_t assertMask, uint64_t levelMask) {
  Handle hd(NVS_NS_LATCH, NVS_READWRITE);
  if (!hd.ok) return false;
  const uint64_t v[2] = {assertMask, levelMask & assertMask};
  return nvs_set_blob(hd.h, K_SAFEMSK, v, sizeof(v)) == ESP_OK && nvs_commit(hd.h) == ESP_OK;
}

bool SafetyStore::loadDiHist(uint64_t& mask) {
  mask = 0;
  Handle hd(NVS_NS_LATCH, NVS_READONLY);
  uint64_t v = 0;
  if (!hd.ok || nvs_get_u64(hd.h, K_DIHIST, &v) != ESP_OK) return false;
  mask = v;
  return true;
}

bool SafetyStore::saveDiHist(uint64_t mask) {
  Handle hd(NVS_NS_LATCH, NVS_READWRITE);
  if (!hd.ok) return false;
  return nvs_set_u64(hd.h, K_DIHIST, mask) == ESP_OK && nvs_commit(hd.h) == ESP_OK;
}

void SafetyStore::loadActPos(uint16_t& openBits, uint16_t& knownBits) {
  openBits = knownBits = 0;
  Handle hd(NVS_NS_LATCH, NVS_READONLY);
  uint32_t v = 0;
  if (!hd.ok || nvs_get_u32(hd.h, K_ACTPOS, &v) != ESP_OK) return;
  openBits = (uint16_t)(v & 0xFFFF);
  knownBits = (uint16_t)(v >> 16);
}

bool SafetyStore::saveActPos(uint16_t openBits, uint16_t knownBits) {
  Handle hd(NVS_NS_LATCH, NVS_READWRITE);
  if (!hd.ok) return false;
  const uint32_t v = (uint32_t)openBits | ((uint32_t)knownBits << 16);
  return nvs_set_u32(hd.h, K_ACTPOS, v) == ESP_OK && nvs_commit(hd.h) == ESP_OK;
}

uint32_t SafetyStore::bumpBootCount() {
  Handle hd(NVS_NS_LATCH, NVS_READWRITE);
  uint32_t v = 0;
  if (!hd.ok) return 0;
  nvs_get_u32(hd.h, K_BOOTC, &v);
  v++;
  if (nvs_set_u32(hd.h, K_BOOTC, v) == ESP_OK) nvs_commit(hd.h);
  return v;
}

void SafetyStore::loadCrash(CrashLog& c) {
  crashClear(c);
  Handle hd(NVS_NS_LATCH, NVS_READONLY);
  CrashLog t;
  size_t len = sizeof(t);
  if (hd.ok && nvs_get_blob(hd.h, K_CRASH, &t, &len) == ESP_OK && len == sizeof(t)) c = t;
  c.stableWritten = 0;
}

bool SafetyStore::saveCrash(const CrashLog& c) {
  Handle hd(NVS_NS_LATCH, NVS_READWRITE);
  if (!hd.ok) return false;
  CrashLog t = c;
  t.stableWritten = 0;
  return nvs_set_blob(hd.h, K_CRASH, &t, sizeof(t)) == ESP_OK && nvs_commit(hd.h) == ESP_OK;
}

uint16_t SafetyStore::loadSirenS() {
  Handle hd(NVS_NS_LATCH, NVS_READONLY);
  uint16_t v = 0;
  if (hd.ok) nvs_get_u16(hd.h, K_SIREN, &v);
  return v;
}

bool SafetyStore::saveSirenS(uint16_t s) {
  Handle hd(NVS_NS_LATCH, NVS_READWRITE);
  if (!hd.ok) return false;
  return nvs_set_u16(hd.h, K_SIREN, s) == ESP_OK && nvs_commit(hd.h) == ESP_OK;
}

}  // namespace safety
