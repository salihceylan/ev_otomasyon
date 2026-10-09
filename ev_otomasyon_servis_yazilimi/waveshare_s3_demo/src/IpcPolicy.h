#pragma once
// ============================================================================
// IpcPolicy.h - esp_ipc_call_blocking "ayni cekirdek" karari. SAF MANTIK (yalnizca <stdint.h>); baglayici: IdfIpcWrap.cpp.
//
// KOK NEDEN (2026-10-09, cokme dokumu `Backtrace: 0xfffffffe:0x8037f3ec |<-CORRUPTED`, EXCCAUSE 0x42 = cift istisna):
//   eth_init gorevi (Core 0, oncelik 1) EthLink.cpp:71'de gpio_install_isr_service(0) cagirir. IDF 4.4.7 bunu
//   gpio_isr_register (gpio.c:541) -> esp_ipc_call_blocking(<arayan cekirdek>, gpio_isr_register_on_core_static) ile AYNI cekirdegin
//   IPC gorevine (ipc0) atlatir. ipc0'in yigini CONFIG_ESP_IPC_TASK_STACK_SIZE=1024 bayttir (Arduino-ESP32 2.0.17 hazir kutuphanesi,
//   sdkconfig satir 1099; yeniden derlenemez) ve CONFIG_ESP_IPC_USES_CALLERS_PRIORITY=y yuzunden ipc0 ARAYANIN onceligini (1) alir,
//   yani wifi_task ile esit oncelikli kalir ve her 1 ms'de (CONFIG_FREERTOS_HZ=1000) zaman dilimi gecisine ugrar.
//   gpio_isr_register_on_core_static -> esp_intr_alloc -> esp_intr_alloc_intrstatus -> malloc -> multi_heap_malloc zinciri ipc0 yiginda
//   ~720 bayt derinlige iner (1008 baytin ustundeki 320 bayt FPU/PIE kayit alanidir; kesilen noktada SP = yigin tabani + 288, vPortExitCritical'in
//   cagirdigi ROM yardimcisi). Kesme/gorev gecisi bu noktaya denk gelirse: 192 baytlik kesme cercevesi yigina itilir (96 bayt kalir),
//   _frxt_int_exit SP'yi pxTopOfStack'e alip vTaskSwitchContext'i (giris 48 + xPortEnterCriticalTimeout 64 + pencere dokumleri) ipc0'in
//   KENDI yiginda cagirir -> yigin sonu izleme noktasi (CONFIG_FREERTOS_WATCHPOINT_END_OF_STACK) / canary denetimi tetiklenir, panik
//   isleyicisi tukenmis yiginda kosamaz -> cift istisna. Bekleyen bir kesme (ornegin bellek kilidi bekleyen kritik bolge boyunca) tam
//   kritik bolgeden cikista, yani bu en derin noktada teslim edilir; Core 1'deki loopTask ayni anda bellek kilidini yogun kullandigindan
//   (WebPortal::begin) olasilik yuksektir. Cokme eth_init'in IPC'si ile Wi-Fi baslatmasi ayni ana denk gelince olur (acilis zamanlamasina
//   bagli, bu yuzden "bazen").
//
// DUZELTME: arayan gorev hedef cekirdege SABITLENMISSE (xTaskGetAffinity == cpu_id) islev IPC gorevine gitmeden arayanin kendi
//   yiginda kosulur (IDF'nin CONFIG_FREERTOS_UNICORE dali da boyle yapar). Sabitlenmemis gorev denetimle cagri arasinda baska
//   cekirdege kayabilir (kesme yanlis cekirdege kurulurdu): o ve her capraz-cekirdek cagri eskisi gibi IPC kullanir.
//   Zamanlayici calismiyorsa gercek fonksiyon ESP_ERR_INVALID_STATE doner; o davranis korunur.
// Sarmalayici: platformio.ini `-Wl,--wrap=esp_ipc_call_blocking` + src/IdfIpcWrap.cpp. Test: test/test_ipc_policy.
// ============================================================================
#include <stdint.h>

namespace ipcpolicy {

constexpr int NO_AFFINITY = 0x7FFFFFFF;   // FreeRTOS tskNO_AFFINITY (xTaskGetAffinity sabitlenmemis gorevde bunu doner)
constexpr uint32_t CORES = 2;             // ESP32-S3 (portNUM_PROCESSORS)

// true: islev IPC gorevine gitmeden cagiranin yiginda kosulabilir.
//   cpuId: IPC hedef cekirdegi; taskAffinity: arayan gorevin xTaskGetAffinity() degeri; schedulerRunning: zamanlayici calisiyor mu.
inline bool runsInline(uint32_t cpuId, int taskAffinity, bool schedulerRunning) {
  if (!schedulerRunning) return false;
  if (cpuId >= CORES) return false;
  if (taskAffinity < 0 || taskAffinity >= (int)CORES) return false;   // NO_AFFINITY ve bozuk degerler
  return (uint32_t)taskAffinity == cpuId;
}

}  // namespace ipcpolicy
