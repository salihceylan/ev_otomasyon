// IdfIpcWrap.cpp - esp_ipc_call_blocking sarmalayicisi (baglayici `-Wl,--wrap=esp_ipc_call_blocking`, platformio.ini).
//
// Neden: gpio_install_isr_service() -> gpio_isr_register() isini 1 KB'lik IPC gorevinde (ipc0/ipc1) kosturur; esp_intr_alloc -> malloc zinciri
// bu yigini neredeyse doldurur ve gorev gecisi derin noktaya denk gelince yigin tasar (acilista tekrarlayan PANIC). Kok neden, kanit ve
// karar kurali IpcPolicy.h'dedir (saf mantik, test/test_ipc_policy). Bu dosya yalnizca kurali uygular:
//   * arayan gorev hedef cekirdege sabitlenmisse -> islev arayanin yiginda dogrudan kosulur (IPC gorevi hic devreye girmez);
//   * aksi halde (capraz cekirdek, sabitlenmemis gorev, zamanlayici kapali) -> gercek esp_ipc_call_blocking, davranis degismez.
// Etkilenen cagri noktalari (firmware.elf'te dogrulandi): gpio_isr_register (ayni cekirdek -> dogrudan) ve esp_intr_free (her zaman
// capraz cekirdek -> gercek IPC). esp_ipc_call (flash islemleri) sarmalanmaz.
#include "IdfIpcWrap.h"
#include "IpcPolicy.h"
#include <esp_ipc.h>
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>

namespace {
volatile uint32_t s_inlineCalls = 0;   // yalnizca tanilama; kacan artis zararsizdir
}

uint32_t idfipc::inlineCalls() { return s_inlineCalls; }

extern "C" {

esp_err_t __real_esp_ipc_call_blocking(uint32_t cpu_id, esp_ipc_func_t func, void* arg);

esp_err_t __wrap_esp_ipc_call_blocking(uint32_t cpu_id, esp_ipc_func_t func, void* arg) {
  const bool running = (xTaskGetSchedulerState() == taskSCHEDULER_RUNNING);
  // Zamanlayici baslamadan xTaskGetAffinity(nullptr) gecerli bir gorev bulamaz: yalnizca calisirken sorulur.
  const int affinity = running ? (int)xTaskGetAffinity(nullptr) : ipcpolicy::NO_AFFINITY;
  if (func != nullptr && ipcpolicy::runsInline(cpu_id, affinity, running)) {
    s_inlineCalls = s_inlineCalls + 1;
    func(arg);
    return ESP_OK;
  }
  return __real_esp_ipc_call_blocking(cpu_id, func, arg);
}

}  // extern "C"
