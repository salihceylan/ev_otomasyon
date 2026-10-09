#pragma once
// ============================================================================
// IdfIpcWrap.h - IdfIpcWrap.cpp'nin tanilama arayuzu (cihaz tarafi). Karar kurali ve gerekce: IpcPolicy.h (saf mantik).
// ============================================================================
#include <stdint.h>

namespace idfipc {

// IPC gorevine (ipc0/ipc1) gitmeden arayanin kendi yiginda kosulan esp_ipc_call_blocking cagrilarinin acilistan beri sayisi.
// Sarmalayici baglanmamissa (platformio.ini'de `-Wl,--wrap=esp_ipc_call_blocking` eksik) hic artmaz: EthLink bunu acilis logunda uyarir.
uint32_t inlineCalls();

}  // namespace idfipc
