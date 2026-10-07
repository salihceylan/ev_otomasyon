#pragma once
// ============================================================================
// DeviceCommand.h - Cekirdekler arasi komut sozlesmesi (docs/CONTRACTS.md, Bolum 4)
//
// MQTT (Core 0), Web portal, CLI ve zamanlayicilar role/panjur durumunu DOGRUDAN
// DEGISTIRMEZ. Komutu postDeviceCommand() ile kuyruga yazarlar; kuyrugu
// SmartAutomation::loop() (Core 1) bosaltir. Boylece role surucusu ve panjur durum
// makinesine tek baglamdan erisilir ve yukari/asagi rolelerinin ayni anda enerjilenmesi
// (check-then-act yarisi) engellenir.
//
// Tum indeksler dis dunyada 1 tabanlidir (rol 1..N, panjur cifti 1..N/2).
// ============================================================================
#include <Arduino.h>

enum class CmdType : uint8_t {
  RELAY_SET,         // index = rol (1..N),   value = 0/1
  RELAY_TOGGLE,      // index = rol
  SHUTTER_UP,        // index = panjur cifti (1..N/2)
  SHUTTER_DOWN,      // index = panjur cifti
  SHUTTER_STOP,      // index = panjur cifti
  SHUTTER_STEP,      // index = panjur cifti (kademeli: dur/yukari/asagi dongusu)
  SHUTTER_POS,       // index = panjur cifti, value = 0..100
  ALL_LIGHTS_OFF,
  ALL_SHUTTERS_UP,
  ALL_SHUTTERS_DOWN,
  ALL_SHUTTERS_STOP,
  SET_CHILD_LOCK,    // value = 0/1
  SET_RUNTIME,       // index = panjur cifti, value = saniye (1..300)
  // ---- Guvenlik katmani (spec 2.3 madde 1; SafetyManager::handleCommand'a yonlendirilir) ----
  ACTUATOR_SET,      // index = eylemci (1..16), value = 0 guvenli yon (vana KAPAT / anahtar KAPAT), 1 AC; MQTT/LAN "to":
                     //   0x10 closed / 0x11 open (yalniz vana), 0x20 off / 0x21 on (siren/fan/generic) -- tur uyusmazsa bad_state
  ALARM_ACK,         // index = bolge (0 = tumu), value = 1 force (guvenli kipten YEREL cikis), aid = bolgenin aid'si
  ALARM_TEST,        // index = bolge (1..4)
  SAFETY_ARM,        // ilgili module kadar "unsupported"
  CLIMATE_TARGET,    // ilgili module kadar "unsupported"
  SCENE_RUN,         // ilgili module kadar "unsupported"
};

// SAFETY: yalniz SmartAutomation::applySafetyOutput (guvenlik cekirdeginin kendi karari). RULE senaryo/iklim/varlik
// motorlarina kalir ve eylemci rolesine HAM erisim vermez (yalniz ACTUATOR_SET) [Y-7].
enum class CmdSource : uint8_t { MQTT, WEB, CLI, DI, RULE, SAFETY };

struct DeviceCommand {
  CmdType type;
  CmdSource source;
  uint8_t index;     // 1 tabanli; ilgisiz komutlarda 0
  int32_t value;     // komuta gore (bkz. yukaridaki yorumlar)
  char id[25];       // istege bagli komut kimligi ("" = yok); state.last_id olarak yankilanir
  char aid[15];      // ALARM_ACK: onaylanan alarmin kimligi ("<bn>-<n>"; "" = yerel, denetimsiz) [Y-9]
};

// Iş parçacığı güvenli: herhangi bir görevden çağrılabilir. Kuyruk doluysa false döner
// (çağıran bunu hata olarak ele almalı, sessizce yutmamalı).
bool postDeviceCommand(const DeviceCommand& cmd);

// Kısa yardımcı: kimliksiz komut oluşturur.
inline DeviceCommand makeCommand(CmdType type, CmdSource source, uint8_t index = 0, int32_t value = 0) {
  DeviceCommand c;
  c.type = type;
  c.source = source;
  c.index = index;
  c.value = value;
  c.id[0] = '\0';
  c.aid[0] = '\0';
  return c;
}
