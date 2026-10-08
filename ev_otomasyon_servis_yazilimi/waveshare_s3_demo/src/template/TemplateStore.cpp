// template/TemplateStore.cpp - NVS "ahbu_tpl" + RAM kopyası (bkz. TemplateStore.h). Ham ESP-IDF nvs API'si (SafetyStore ile aynı desen).
#include "template/TemplateStore.h"
#include "template/TemplateParse.h"
#include "SystemConfig.h"
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>
#include <nvs.h>
#include <stdio.h>
#include <string.h>

namespace tpl {

namespace {

const char* const K_VER = "ver";
const char* const K_ID = "id";
const char* const K_LABEL = "label";
const char* const K_TXN = "txn";
volatile bool s_txn = false;   // açılışta txn işareti vardı (yarım işlem)

portMUX_TYPE s_mux = portMUX_INITIALIZER_UNLOCKED;
TplRecord s_rec;            // s_mux altında
bool s_appliedValid = false;
uint32_t s_appliedUptime = 0;

struct Handle {
  nvs_handle_t h;
  bool ok;
  Handle(const char* ns, nvs_open_mode_t mode) : h(0), ok(nvs_open(ns, mode, &h) == ESP_OK) {}
  ~Handle() { if (ok) nvs_close(h); }
};

bool load(TplRecord& r) {
  tplRecordClear(r);
  Handle hd(NVS_NS_TPL, NVS_READONLY);
  if (!hd.ok) return false;
  uint32_t ver = 0;
  if (nvs_get_u32(hd.h, K_VER, &ver) != ESP_OK || ver == 0) return false;
  size_t len = sizeof(r.id);
  if (nvs_get_str(hd.h, K_ID, r.id, &len) != ESP_OK || !isLowerUuid(r.id)) {
    tplRecordClear(r);
    return false;
  }
  len = sizeof(r.label);
  if (nvs_get_str(hd.h, K_LABEL, r.label, &len) != ESP_OK) r.label[0] = '\0';
  r.label[sizeof(r.label) - 1] = '\0';
  r.ver = ver;
  r.present = true;
  return true;
}

}  // namespace

void TemplateStore::begin() {
  TplRecord r;
  load(r);
  {
    Handle hd(NVS_NS_TPL, NVS_READONLY);
    uint8_t t = 0;
    s_txn = hd.ok && nvs_get_u8(hd.h, K_TXN, &t) == ESP_OK && t != 0;
  }
  if (s_txn) printf("[SABLON] UYARI: yarim kalmis sablon uygulamasi (txn); seri TPL ile yeniden yazilmali.\r\n");
  taskENTER_CRITICAL(&s_mux);
  s_rec = r;
  s_appliedValid = false;
  taskEXIT_CRITICAL(&s_mux);
  if (r.present) printf("[SABLON] Yuklu sablon: %s v%lu (%s)\r\n", r.id, (unsigned long)r.ver, r.label);
}

void TemplateStore::get(TplRecord& out) {
  taskENTER_CRITICAL(&s_mux);
  out = s_rec;
  taskEXIT_CRITICAL(&s_mux);
}

bool TemplateStore::appliedUptime(uint32_t& sec) {
  taskENTER_CRITICAL(&s_mux);
  const bool v = s_appliedValid;
  sec = s_appliedUptime;
  taskEXIT_CRITICAL(&s_mux);
  return v;
}

bool TemplateStore::save(const TplRecord& r) {
  if (!r.present) return erase();
  Handle hd(NVS_NS_TPL, NVS_READWRITE);
  if (!hd.ok) return false;
  bool ok = nvs_set_u32(hd.h, K_VER, 0) == ESP_OK;   // geçersiz işaret: yarım yazım "şablon yok" okunur
  ok = ok && nvs_set_str(hd.h, K_ID, r.id) == ESP_OK;
  ok = ok && nvs_set_str(hd.h, K_LABEL, r.label) == ESP_OK;
  ok = ok && nvs_set_u32(hd.h, K_VER, r.ver) == ESP_OK;
  return ok && nvs_commit(hd.h) == ESP_OK;
}

bool TemplateStore::erase() {
  Handle hd(NVS_NS_TPL, NVS_READWRITE);
  if (!hd.ok) return false;
  bool ok = true;
  for (const char* k : {K_VER, K_ID, K_LABEL}) {
    const esp_err_t e = nvs_erase_key(hd.h, k);
    if (e != ESP_OK && e != ESP_ERR_NVS_NOT_FOUND) ok = false;
  }
  return ok && nvs_commit(hd.h) == ESP_OK;
}

bool TemplateStore::txnBegin() {
  Handle hd(NVS_NS_TPL, NVS_READWRITE);
  if (!hd.ok) return false;
  return nvs_set_u8(hd.h, K_TXN, 1) == ESP_OK && nvs_commit(hd.h) == ESP_OK;
}

bool TemplateStore::txnEnd() {
  Handle hd(NVS_NS_TPL, NVS_READWRITE);
  if (!hd.ok) return false;
  const esp_err_t e = nvs_erase_key(hd.h, K_TXN);
  const bool ok = (e == ESP_OK || e == ESP_ERR_NVS_NOT_FOUND) && nvs_commit(hd.h) == ESP_OK;
  if (ok) s_txn = false;
  return ok;
}

bool TemplateStore::txnInterrupted() { return s_txn; }

void TemplateStore::setRam(const TplRecord& r, uint32_t appliedUptimeS) {
  taskENTER_CRITICAL(&s_mux);
  s_rec = r;
  s_appliedValid = r.present;
  s_appliedUptime = appliedUptimeS;
  taskEXIT_CRITICAL(&s_mux);
}

}  // namespace tpl
