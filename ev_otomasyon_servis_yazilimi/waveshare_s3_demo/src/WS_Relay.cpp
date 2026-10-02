#include "WS_Relay.h"

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
  TCA9554PWR_Init(0x00, 0x00);

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
