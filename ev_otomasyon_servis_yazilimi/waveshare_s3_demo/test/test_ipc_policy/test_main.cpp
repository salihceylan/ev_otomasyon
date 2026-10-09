// ============================================================================
// IpcPolicy (src/IpcPolicy.h) birim testleri:  pio test -e native -f test_ipc_policy
//
// Kok neden (2026-10-09 cokme dokumu): gpio_install_isr_service() -> esp_ipc_call_blocking(ayni cekirdek) isi 1 KB'lik IPC gorev
// yiginda kosturur; 1 ms'lik gorev gecisi esp_intr_alloc -> malloc zincirinin en derin noktasina denk gelince yigin tasar.
// Karar: arayan gorev hedef cekirdege SABITLENMISSE islev arayanin yiginda kosulur; aksi halde IPC (eski davranis).
// ============================================================================
#include <unity.h>
#include <stdint.h>
#include "IpcPolicy.h"

using namespace ipcpolicy;

void setUp(void) {}
void tearDown(void) {}

void test_pinned_to_target_core_runs_inline(void) {
  // eth_init: Core 0'a sabit, gpio_isr_register -> esp_ipc_call_blocking(0, ...)
  TEST_ASSERT_TRUE(runsInline(0, 0, true));
  // Arduino loopTask: Core 1'e sabit, attachInterrupt -> gpio_install_isr_service -> esp_ipc_call_blocking(1, ...)
  TEST_ASSERT_TRUE(runsInline(1, 1, true));
}

void test_other_core_still_uses_ipc(void) {
  // Gercek capraz-cekirdek cagrilar (esp_intr_free baska cekirdekteki kesmeyi serbest birakirken) IPC'de kalir.
  TEST_ASSERT_FALSE(runsInline(1, 0, true));
  TEST_ASSERT_FALSE(runsInline(0, 1, true));
}

void test_unpinned_task_keeps_ipc(void) {
  // Sabitlenmemis gorev denetimle cagri arasinda baska cekirdege kayabilir: kesme yanlis cekirdege kurulurdu -> IPC.
  TEST_ASSERT_EQUAL_INT(0x7FFFFFFF, NO_AFFINITY);   // FreeRTOS tskNO_AFFINITY
  TEST_ASSERT_FALSE(runsInline(0, NO_AFFINITY, true));
  TEST_ASSERT_FALSE(runsInline(1, NO_AFFINITY, true));
}

void test_scheduler_not_running_keeps_real_behaviour(void) {
  // Zamanlayici baslamadan IDF ESP_ERR_INVALID_STATE doner; taslanmis calisma o davranisi degistirmez.
  TEST_ASSERT_FALSE(runsInline(0, 0, false));
  TEST_ASSERT_FALSE(runsInline(1, 1, false));
}

void test_invalid_arguments_fall_through_to_real_call(void) {
  // Gecersiz cekirdek numarasi ya da bozuk ilgi: gercek fonksiyon ESP_ERR_INVALID_ARG ile reddeder.
  TEST_ASSERT_FALSE(runsInline(2, 2, true));
  TEST_ASSERT_FALSE(runsInline(0xFFFFFFFFu, -1, true));
  TEST_ASSERT_FALSE(runsInline(0, -1, true));
  TEST_ASSERT_FALSE(runsInline(1, -2147483647 - 1, true));
}

int main(int, char**) {
  UNITY_BEGIN();
  RUN_TEST(test_pinned_to_target_core_runs_inline);
  RUN_TEST(test_other_core_still_uses_ipc);
  RUN_TEST(test_unpinned_task_keeps_ipc);
  RUN_TEST(test_scheduler_not_running_keeps_real_behaviour);
  RUN_TEST(test_invalid_arguments_fall_through_to_real_call);
  return UNITY_END();
}
