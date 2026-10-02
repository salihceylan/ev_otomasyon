#include "WS_TCA9554PWR.h"
#include "RelayRules.h"
#include <Arduino.h>
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>

// ------------------------------------------------------------------------------------------------
// Durum (hepsi I2C özyinelemeli kilidi altında okunur/yazılır)
// ------------------------------------------------------------------------------------------------
static uint8_t s_outShadow = 0x00;          // çıkış yazmacının RAM gölgesi (son BAŞARILI yazım)
static uint8_t s_cfgShadow = 0x00;          // yön yazmacı gölgesi (0 = hepsi çıkış)
static InterlockGuard s_guard;              // panjur çifti emniyet kuralları (RelayRules.h)
static uint32_t s_writeFailures = 0;
static uint8_t s_droppedMask = 0;          // eşitlemede "gölgede AÇIK, donanımda KAPALI" bulunan bitler (TCA_TakeDroppedMask ile alınır)

// ------------------------------------------------------------------------------------------------
// Yazmaç erişimi (dönüş kontrollü)
// ------------------------------------------------------------------------------------------------
bool TCA_ReadReg(uint8_t reg, uint8_t *out)
{
  return I2C_Read(TCA9554_ADDRESS, reg, out, 1) == ESP_OK;
}

bool TCA_WriteReg(uint8_t reg, uint8_t data)
{
  return I2C_Write(TCA9554_ADDRESS, reg, &data, 1) == ESP_OK;
}

uint8_t Read_REG(uint8_t REG)                             // (eski) hatada 0 döner ve hata basar
{
  uint8_t v = 0;
  if (!TCA_ReadReg(REG, &v)) {
    printf("Data Transfer Failure !!!\r\n");
    return 0;
  }
  return v;
}

uint8_t Write_REG(uint8_t REG, uint8_t Data)              // (eski sözleşme) 0 = başarı
{
  if (!TCA_WriteReg(REG, Data)) {
    printf("Data write failure!!!\r\n");
    return (uint8_t)-1;
  }
  return 0;
}

// ------------------------------------------------------------------------------------------------
// Çıkış sürücüsü
// ------------------------------------------------------------------------------------------------
void TCA_SetShutterPairs(uint8_t pairMask)
{
  if (!I2C_Lock(50)) return;
  s_guard.setShutterPairs(pairMask & 0x0F);   // yerel röleler 0..7 = en çok 4 çift
  I2C_Unlock();
}

uint8_t TCA_OutputShadow(void)
{
  I2C_Lock(20);
  uint8_t v = s_outShadow;
  I2C_Unlock();
  return v;
}

uint32_t TCA_WriteFailureCount(void)
{
  return s_writeFailures;
}

// ------------------------------------------------------------------------------------------------
// Gölge / FİZİKSEL çıkış eşitleme (çip sıfırlanması, röle düşmesi, beklenmeyen AÇIK röle)
// ------------------------------------------------------------------------------------------------
// Yazmaç okuması / yazımı: en çok `attempts` (3) deneme, aralarında kısa bekleme (I2C kilidi ALINMIŞ olmalı). Geçici bir NACK, yazım
// ön denetimini "denetimsiz" bırakmasın (ön denetim okunamazsa doğrulanamayan panjur bitleri yazımdan çıkarılır; bkz. TCA_WriteOutputsEx).
static bool tcaReadRegRetry(uint8_t reg, uint8_t* out, int attempts)
{
  for (int attempt = 0; attempt < attempts; attempt++) {
    if (TCA_ReadReg(reg, out)) return true;
    if (attempt + 1 < attempts) vTaskDelay(pdMS_TO_TICKS(2));      // kısa bekleme, hat toparlansın
  }
  return false;
}

static bool tcaWriteRegRetry(uint8_t reg, uint8_t value)
{
  for (int attempt = 0; attempt < 3; attempt++) {
    if (TCA_WriteReg(reg, value)) return true;
    if (attempt < 2) vTaskDelay(pdMS_TO_TICKS(2));      // kısa bekleme, hat toparlansın
  }
  return false;
}

// Donanımı okuyup gölgeyi + InterlockGuard'ı ona eşitler (I2C kilidi ALINMIŞ olmalı). Karar saf mantıktır
// (relayrules::planTcaResync, test/test_relay_rules). Düşen bitler s_droppedMask'e eklenir (üst katman
// TCA_TakeDroppedMask() ile alıp etkilenen panjurları durdurur) ve *droppedNow'a yazılır. Düşen röleler BU YOLLA
// YENİDEN ÇEKİLMEZ. İKİ AŞAMA: (1) okunan FİZİKSEL durum hemen gölgeye ve InterlockGuard'a işlenir (düşenlerin kapanma anı
// şimdi damgalanır: 500 ms ölü zaman o andan başlar; fazla açık bir röle "enerjili" bilinir, böylece düzeltme yazımı başarısız
// olsa bile ters yön / ölü zaman koruması gerçeğe göre çalışır), (2) fazla açık röleler kapatılır / yön yazmacı geri yüklenir; fazla
// açık PANJUR rölesinin AÇIK->KAPALI geçişi bu ikinci aşamada damgalanır (ölü zaman o kapanmadan başlar).
// *readFailed: donanım 3 denemede de OKUNAMADI (durum bilinmiyor): çağıran doğrulanamayan panjur bitlerini yazımdan çıkarır.
// adoptOnly (KAPATMA yazımı mask == 0 öncesi): yalnız 1. aşama (tek okuma denemesi, düzeltme yazımı YOK). Hemen ardından gelen KAPATMA yazımı
// zaten her çıkışı kapatır; 1. aşama, o yazımın fiziksel olarak AÇIK bulunan (firmware'in bilmediği) panjur rölelerini de kapattığını
// InterlockGuard'a bildirir (kapanma damgası: ölü zaman o andan başlar). Hiçbir şey engellenmez, bekletilmez (hat takılırsa en çok 1 okuma).
static TcaVerifyResult tcaResyncLocked(uint8_t* droppedNow, bool* readFailed, bool adoptOnly)
{
  if (droppedNow) *droppedNow = 0;
  if (readFailed) *readFailed = false;
  uint8_t outHw = 0, cfgHw = 0;
  const int readAttempts = adoptOnly ? 1 : 3;
  if (!tcaReadRegRetry(TCA9554_OUTPUT_REG, &outHw, readAttempts) || !tcaReadRegRetry(TCA9554_CONFIG_REG, &cfgHw, readAttempts)) {
    if (readFailed) *readFailed = true;
    return TCA_VERIFY_ERROR;
  }

  const relayrules::TcaResyncPlan plan = relayrules::planTcaResync(outHw, cfgHw, s_outShadow, s_cfgShadow);
  if (plan.kind == relayrules::TcaResyncPlan::IN_SYNC) return TCA_VERIFY_OK;

  // Aşama 1: fiziksel gerçeği HEMEN işle (aşağıdaki düzeltme yazımları başarısız olsa bile bilgi kaybolmaz).
  if (plan.dropped != 0) {
    printf("[TCA] UYARI: role(ler) dusmus (hw=0x%02X golge=0x%02X dusen=0x%02X) -> golge donanima cekildi, yeniden CEKILMEZ.\r\n",
           outHw, s_outShadow, plan.dropped);
    s_droppedMask = (uint8_t)(s_droppedMask | plan.dropped);
    if (droppedNow) *droppedNow = plan.dropped;
  }
  const uint32_t tAdopt = millis();
  if (plan.kind == relayrules::TcaResyncPlan::CHIP_RESET) {
    // Çip sıfırlanınca HER röle (firmware'in AÇIK olduğunu bilmediği, kendiliğinden çekmiş olanlar dahil) bilinmeyen bir anda (<= şimdi) düştü:
    // koruma yalnız "AÇIK sanılan" çiftleri damgalayabilir; kalan çiftlerin ölü zamanı en kötü ihtimalle (şimdi) kabul edilir.
    for (uint8_t relay = 0; relay < 8; relay = (uint8_t)(relay + 2)) s_guard.noteOff(relay, tAdopt);
  }
  s_guard.commit(plan.physical, tAdopt);      // düşen bitlerin AÇIK->KAPALI geçişi ŞİMDİ damgalanır (ölü zaman yeniden başlar)
  s_outShadow = plan.physical;
  if (adoptOnly) return (plan.kind == relayrules::TcaResyncPlan::FIX_EXTRA) ? TCA_VERIFY_FIXED : TCA_VERIFY_RESET;

  // Aşama 2: düzeltme yazımları
  if (plan.restoreConfig) {
    // Çip sıfırlanmış (brown-out): çıkışlar girişe dönmüş olabilir. SIRA ÖNEMLİ: önce çıkış yazmacına
    // GÜVENLİ (hepsi KAPALI) değer, sonra yön; böylece pinler çıkış olurken röleler çekmez.
    printf("[TCA] UYARI: yon yazmaci sifirlanmis (0x%02X) -> guvenli yeniden baslatma.\r\n", cfgHw);
    if (!tcaWriteRegRetry(TCA9554_OUTPUT_REG, 0x00) || !tcaWriteRegRetry(TCA9554_CONFIG_REG, s_cfgShadow)) return TCA_VERIFY_ERROR;
  } else if (plan.writeOut) {
    printf("[TCA] UYARI: beklenmeyen ACIK rolenin kapatilmasi (hw=0x%02X golge=0x%02X)\r\n", outHw, plan.newShadow);
    if (!tcaWriteRegRetry(TCA9554_OUTPUT_REG, plan.newShadow)) return TCA_VERIFY_ERROR;
  }
  s_guard.commit(plan.newShadow, millis());   // fazla açık rölenin AÇIK->KAPALI geçişi ŞİMDİ damgalanır (ölü zaman o andan başlar)
  s_outShadow = plan.newShadow;
  return (plan.kind == relayrules::TcaResyncPlan::FIX_EXTRA) ? TCA_VERIFY_FIXED : TCA_VERIFY_RESET;
}

// "writeMask": tek yazımda 8 rölenin tamamı. Çok görevli kullanıma güvenlidir.
TcaWriteResult TCA_WriteOutputsEx(uint8_t mask)
{
  if (!I2C_Lock(80)) {
    s_writeFailures++;
    printf("[TCA] I2C kilidi alinamadi, yazim yapilmadi (maske 0x%02X)\r\n", mask);
    return TCA_WRITE_LOCK_TIMEOUT;
  }

  // ÖN DENETİM: bir röleyi AÇIK bırakacak/açacak her yazımdan önce donanım okunur. Çip sıfırlanması / röle düşmesi ile
  // periyodik TCA_Verify (2 sn) arasında gölge "AÇIK", donanım "KAPALI" der; 8 bitlik yazım düşen rölenin bitini (panjur
  // dahil) ölü zamansız yeniden çekerdi (fiziksel kapanma anı bilinmez). Gölge donanıma eşitlenir, düşen bitler bu yazımdan
  // ÇIKARILIR, InterlockGuard'a kapanma anı bildirilir.
  // Donanım 3 denemede de OKUNAMAZSA (durum bilinmiyor): gölgede zaten AÇIK olan PANJUR röleleri doğrulanamaz; yeniden çekmek
  // ölü zamanı çiğneyebilir. DOĞRULANAMAYAN ENERJİ YOK: bu bitler yazımdan çıkarılır (röle kapanır) ve YAZIM BAŞARILI olursa
  // "düşmüş" sayılır (üst katman panjuru durdurur). Yazım başarısızsa hiçbir şey değişmez (röle zaten olduğu gibi kalır).
  // Yeni enerjilenecek bitler ve lambalar etkilenmez.
  // KAPATMA yazımları (mask == 0) HİÇBİR koşulda engellenmez/bekletilmez; yalnız öncesinde fiziksel durum (tek okuma denemesi) InterlockGuard'a
  // işlenir: yazım, firmware'in bilmediği AÇIK bir panjur rölesini de kapatır ve o kapanmanın ölü zamanı damgalanmalıdır (aksi halde hemen
  // ardından gelen ters yön komutu motor dönerken enerjilenirdi).
  uint8_t unverified = 0;
  uint8_t dropped = 0;
  bool readFailed = false;
  if (mask != 0) {
    (void)tcaResyncLocked(&dropped, &readFailed, false);
    mask = (uint8_t)(mask & ~dropped);
    if (readFailed) {
      unverified = relayrules::unverifiedRetainedShutterBits(mask, s_outShadow, s_guard.shutterPairs());
      mask = (uint8_t)(mask & ~unverified);
    }
  } else {
    (void)tcaResyncLocked(&dropped, &readFailed, true);
  }

  const uint32_t now = millis();    // ön denetimden SONRA: ön denetim damgaları millis() ile atar (daha eski now olsaydı uint32 farkı taşardı)

  // Sürücü seviyesi emniyet: panjur çiftinde iki yön / doğrudan yön değişimi / <500 ms yeniden enerjileme
  InterlockGuard::Result r = s_guard.check(mask, now);
  if (r != InterlockGuard::OK) {
    I2C_Unlock();
    if (r == InterlockGuard::DEAD_TIME) return TCA_WRITE_DEAD_TIME;   // beklenen durum: sessizce bekletilir
    s_writeFailures++;
    printf("[TCA INTERLOCK] Yazim REDDEDILDI: maske 0x%02X (%s)\r\n", mask, InterlockGuard::resultText(r));
    return (r == InterlockGuard::BOTH_ON) ? TCA_WRITE_BOTH_ON : TCA_WRITE_REVERSAL;
  }

  bool ok = false;
  for (int attempt = 0; attempt < 3 && !ok; attempt++) {
    ok = TCA_WriteReg(TCA9554_OUTPUT_REG, mask);
    if (!ok && attempt < 2) vTaskDelay(pdMS_TO_TICKS(2));      // kısa bekleme, hat toparlansın
  }

  if (ok) {
    s_guard.commit(mask, millis());   // durum YALNIZCA başarıdan sonra güncellenir; damga yazımdan SONRAKİ gerçek an (yeniden denemeler ms sürer)
    s_outShadow = mask;
    if (unverified != 0) {
      s_droppedMask = (uint8_t)(s_droppedMask | unverified);
      printf("[TCA] UYARI: donanim okunamadi -> dogrulanamayan panjur role(ler) (0x%02X) yazimdan cikarildi (KAPATILDI), panjur durdurulacak.\r\n",
             (unsigned)unverified);
    }
  } else {
    s_writeFailures++;
    printf("[TCA] Cikis yazimi 3 denemede BASARISIZ (maske 0x%02X)\r\n", mask);
  }
  I2C_Unlock();
  return ok ? TCA_WRITE_OK : TCA_WRITE_I2C_FAIL;
}

bool TCA_WriteOutputs(uint8_t mask)
{
  return TCA_WriteOutputsEx(mask) == TCA_WRITE_OK;
}

// Acil kapatma: gölgedeki bitlerden clearMask'i düşür. Yalnızca KAPATMA olduğu için interlock'a takılmaz.
bool TCA_ClearBits(uint8_t clearMask)
{
  if (!I2C_Lock(80)) return false;
  uint8_t next = (uint8_t)(s_outShadow & ~clearMask);
  bool ok = TCA_WriteOutputs(next);
  I2C_Unlock();
  return ok;
}

// Periyodik doğrulama (SmartAutomation::loop, 2 sn) ve yazım ön denetimiyle AYNI eşitleme (tcaResyncLocked).
TcaVerifyResult TCA_Verify(void)
{
  if (!I2C_Lock(50)) return TCA_VERIFY_ERROR;
  const TcaVerifyResult result = tcaResyncLocked(nullptr, nullptr, false);
  I2C_Unlock();
  return result;
}

// Eşitleme sırasında "gölgede AÇIK sanılıp fiziksel olarak KAPALI bulunan" bitlerin (çip sıfırlanması / düşen röle) birikmiş
// maskesini döndürür ve sıfırlar. Üst katman bu bitlere ait panjurları DURDURUR (konum takibi geçersiz).
uint8_t TCA_TakeDroppedMask(void)
{
  if (!I2C_Lock(20)) return 0;      // kilit alınamazsa maske korunur, sonraki çağrıda alınır
  const uint8_t d = s_droppedMask;
  s_droppedMask = 0;
  I2C_Unlock();
  return d;
}

/********************************************************** Set EXIO mode **********************************************************/
void Mode_EXIO(uint8_t Pin,uint8_t State)                 // Pin yönünü değiştirir (State: 0= çıkış, 1= giriş). Yön gölgesi güncellenir.
{
  if (Pin < 1 || Pin > 8) return;
  if (!I2C_Lock(50)) return;
  uint8_t next = s_cfgShadow;
  if (State) next |= (uint8_t)(0x01 << (Pin - 1));
  else       next &= (uint8_t)~(0x01 << (Pin - 1));
  if (TCA_WriteReg(TCA9554_CONFIG_REG, next)) s_cfgShadow = next;
  else printf("I/O Configuration Failure !!!\r\n");
  I2C_Unlock();
}

void Mode_EXIOS(uint8_t PinState)                         // Tüm pinlerin yönü (0= çıkış)
{
  if (!I2C_Lock(50)) return;
  if (TCA_WriteReg(TCA9554_CONFIG_REG, PinState)) s_cfgShadow = PinState;
  else printf("I/O Configuration Failure !!!\r\n");
  I2C_Unlock();
}

/********************************************************** Read EXIO status **********************************************************/
uint8_t Read_EXIO(uint8_t Pin)                            // Giriş seviyesi
{
  if (Pin < 1 || Pin > 8) return 0;
  uint8_t inputBits = 0;
  if (!TCA_ReadReg(TCA9554_INPUT_REG, &inputBits)) return 0;
  return (inputBits >> (Pin - 1)) & 0x01;
}

uint8_t Read_EXIOS(uint8_t REG)                           // OUTPUT yazmacı için RAM gölgesi döner (donanıma güvenilmez)
{
  if (REG == TCA9554_OUTPUT_REG) return TCA_OutputShadow();
  uint8_t v = 0;
  if (!TCA_ReadReg(REG, &v)) return 0;
  return v;
}

/********************************************************** Set the EXIO output status **********************************************************/
bool Set_EXIO(uint8_t Pin,uint8_t State)                  // Diğer pinleri bozmadan tek pini ayarla (gölge kayıt üzerinden)
{
  if (State > 1 || Pin < 1 || Pin > 8) {
    printf("Parameter error, please enter the correct parameter!\r\n");
    return false;
  }
  if (!I2C_Lock(80)) return false;
  uint8_t bit = (uint8_t)(0x01 << (Pin - 1));
  uint8_t next = State ? (uint8_t)(s_outShadow | bit) : (uint8_t)(s_outShadow & ~bit);
  bool ok = TCA_WriteOutputs(next);
  I2C_Unlock();
  if (!ok) printf("Failed to set GPIO!!!\r\n");
  return ok;
}

bool Set_EXIOS(uint8_t PinState)
{
  bool ok = TCA_WriteOutputs(PinState);
  if (!ok) printf("Failed to set GPIO!!!\r\n");
  return ok;
}

/********************************************************** Flip EXIO state **********************************************************/
bool Set_Toggle(uint8_t Pin)
{
  if (Pin < 1 || Pin > 8) return false;
  if (!I2C_Lock(80)) return false;
  uint8_t bit = (uint8_t)(0x01 << (Pin - 1));
  bool ok = TCA_WriteOutputs((uint8_t)(s_outShadow ^ bit));
  I2C_Unlock();
  if (!ok) printf("Failed to Toggle GPIO!!!\r\n");
  return ok;
}

/********************************************************* TCA9554PWR Initializes the device ***********************************************************/
void TCA9554PWR_Init(uint8_t PinMode, uint8_t PinState)
{
  if (!I2C_Lock(100)) {
    printf("[TCA] Baslatma: I2C kilidi alinamadi!\r\n");
    return;
  }

  // SIRA: önce çıkış yazmacı (varsayılan hepsi KAPALI), sonra yön. ESP32 yeniden başladığında TCA9554'ün
  // çıkış latch'i önceki durumu KORUR; ilk iş KAPATMAKTIR.
  bool okOut = false;
  for (int i = 0; i < 3 && !okOut; i++) {
    okOut = TCA_WriteReg(TCA9554_OUTPUT_REG, PinState);
    if (!okOut) vTaskDelay(pdMS_TO_TICKS(2));
  }
  bool okCfg = false;
  for (int i = 0; i < 3 && !okCfg; i++) {
    okCfg = TCA_WriteReg(TCA9554_CONFIG_REG, PinMode);
    if (!okCfg) vTaskDelay(pdMS_TO_TICKS(2));
  }

  if (okOut) {
    // Önceki (bilinmeyen) donanım durumunu "her çift enerjiliydi" say: açılıştan sonraki ilk
    // enerjileme bile 500 ms ölü zamana tabi olur (yeniden başlama anında motor hâlâ dönüyor olabilir).
    s_guard.forceHw(~0ULL);
    s_guard.commit(PinState, millis());
    s_outShadow = PinState;
  }
  if (okCfg) s_cfgShadow = PinMode;

  printf("[TCA] Baslatildi: cikis=0x%02X (%s), yon=0x%02X (%s)\r\n",
         PinState, okOut ? "OK" : "HATA", PinMode, okCfg ? "OK" : "HATA");
  I2C_Unlock();
}
