#include "WS_Relay.h"
#include "safety/SafetyStore.h"

static volatile bool Failure_Flag = false;

void Relay_SignalFailure(void)
{
  Failure_Flag = true;
}

/*************************************************************  Relay I/O  *************************************************************/
bool Relay_Open(uint8_t CHx)
{
  if(!Set_EXIO(CHx, true)){
    printf("Failed to Open CH%d!!!\r\n", CHx);
    Failure_Flag = true;
    return 0;
  }
  return 1;
}
bool Relay_Closs(uint8_t CHx)
{
  if(!Set_EXIO(CHx, false)){
    printf("Failed to Closs CH%d!!!\r\n", CHx);
    Failure_Flag = true;
    return 0;
  }
  return 1;
}
bool Relay_CHx_Toggle(uint8_t CHx)
{
   if(!Set_Toggle(CHx)){
    printf("Failed to Toggle CH%d!!!\r\n", CHx);
    Failure_Flag = true;
    return 0;
  }
  return 1;
}
bool Relay_CHx(uint8_t CHx, bool State)
{
  bool result = 0;
  if(State)
    result = Relay_Open(CHx);
  else
    result = Relay_Closs(CHx);
  if(!result)
    Failure_Flag = true;
  return result;
}
bool Relay_CHxs_PinState(uint8_t PinState)
{
  if(!Set_EXIOS(PinState)){
    printf("Failed to set the relay status!!!\r\n");
    Failure_Flag = true;
    return 0;
  }
  return 1;
}

static void RelayFailTask(void *parameter) {
  while(1){
    if(Failure_Flag)
    {
      Failure_Flag = false;
      printf("Error: Relay control failed!!!\r\n");
      RGB_Open_Time(60,0,0,5000,500);
      Buzzer_Open_Time(5000, 500);
    }
    vTaskDelay(pdMS_TO_TICKS(50));
  }
  vTaskDelete(NULL);
}

void Relay_Init(void)
{
  // Önce röleleri KAPAT (TCA9554 çıkış latch'i ESP32 yeniden başlatmasında önceki durumu korur).
  // İSTİSNA (güvenlik katmanı, spec §5.1.6 madde 1 [K-2][Y-4]): NVS "ahbu_latch"ta geçerli bir kilit kaydı varsa, kilitlendiği anda
  // hesaplanan yerel güvenli seviye (ör. enerjiyle kapanan vana) ilk yazımda KORUNUR; yapılandırmadan bağımsızdır. Kilitsiz bölgede de
  // KAPALI komutlu enerjiyle-kapanan vanalar ve bütün enerjiyle-kapanan gaz vanaları (açılış güvenli maskesi "safe_msk") korunur:
  // Relay_Init ile SmartAutomation::begin arasındaki ~1-2 sn'de vana açılmaz (inceleme turu EM-1, K-4).
  // Kayıt yoksa safeLocal = 0: çağrı bugünküyle aynıdır. (İmza: TCA9554PWR_Init(yön, çıkış).)
  uint8_t safeLocal = 0;
  safety::SafetyStore::readBootLatchLocal(safeLocal);
  TCA9554PWR_Init(0x00, safeLocal);

  static bool taskCreated = false;
  if (!taskCreated) {
    taskCreated = true;
    xTaskCreatePinnedToCore(
      RelayFailTask,
      "RelayFailTask",
      4096,
      NULL,
      3,
      NULL,
      0
    );
  }
}
