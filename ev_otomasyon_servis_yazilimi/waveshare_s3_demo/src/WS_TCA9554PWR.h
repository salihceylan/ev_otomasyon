#pragma once

#include <stdio.h>
#include "I2C_Driver.h"

/****************************************************** The macro defines the TCA9554PWR information ******************************************************/

#define TCA9554_ADDRESS         0x20                      // TCA9554PWR I2C address
#define TCA9554_INPUT_REG       0x00                      // Input register,input level
#define TCA9554_OUTPUT_REG      0x01                      // Output register, high and low level output
#define TCA9554_Polarity_REG    0x02                      // The Polarity Inversion register (register 2) allows polarity inversion of pins defined as inputs by the Configuration register.
#define TCA9554_CONFIG_REG      0x03                      // Configuration register, mode configuration


#define Low   0
#define High  1
#define EXIO_PIN1   1
#define EXIO_PIN2   2
#define EXIO_PIN3   3
#define EXIO_PIN4   4
#define EXIO_PIN5   5
#define EXIO_PIN6   6
#define EXIO_PIN7   7
#define EXIO_PIN8   8

// ================================================================================================
// RÖLE ÇIKIŞ SÜRÜCÜSÜ (8 yerel röle = TCA9554 çıkışları)
//
//  * Çıkış yazmacının RAM GÖLGE KAYDI tutulur: donanımdan "oku-değiştir-yaz" YOKTUR. Okuma hatası
//    (eski kod hatada 0xFF/bayat bayt döndürüp başka röleleri bozabiliyordu) çıkışı etkileyemez.
//  * Her yazım I2C özyinelemeli kilidi altında, 3 denemeyle yapılır ve gölge/InterlockGuard durumu
//    YALNIZCA başarılı yazımdan sonra güncellenir.
//  * TCA_WriteOutputs() panjur çiftlerinde (TCA_SetShutterPairs ile bildirilen) iki yönün aynı anda
//    enerjilenmesini, tek yazımda doğrudan yön değişimini ve kapanmadan sonra 500 ms içinde yeniden
//    enerjilenmeyi REDDEDER (src/RelayRules.h). Bu, ShutterFsm'den BAĞIMSIZ son savunma hattıdır.
//  * Bir röleyi AÇIK bırakacak/açacak her yazımdan ÖNCE donanım okunur (ön denetim; 3 okuma denemesi): çip sıfırlanması ya da
//    düşen röle nedeniyle gölge ile fiziksel çıkış ayrışmışsa gölge donanıma eşitlenir, düşen bitler o yazımla YENİDEN ÇEKİLMEZ
//    ve InterlockGuard'a kapanma anı bildirilir (500 ms ölü zaman o andan). Düşen bitler TCA_TakeDroppedMask() ile alınır.
//    Fiziksel olarak fazla AÇIK bulunan bir panjur rölesi kapatılınca ölü zaman o kapanmadan başlar. Donanım hiç OKUNAMAZSA
//    gölgede zaten AÇIK olan panjur röleleri doğrulanamaz: yazımdan çıkarılır (KAPATILIR) ve yazım başarılıysa "düşmüş" sayılır
//    (DOĞRULANAMAYAN ENERJİ YOK; yeni enerjilenecek bitler ve lambalar etkilenmez).
//  * Röle durumunu yalnızca SmartAutomation (ve acil durum olarak emniyet görevi) değiştirmelidir.
// ================================================================================================

// Sürücü API'si (SmartAutomation kullanır)
void TCA_SetShutterPairs(uint8_t pairMask);                // bit p = (röle 2p, 2p+1) çifti panjur (p = 0..3)
enum TcaWriteResult : uint8_t {
  TCA_WRITE_OK = 0,
  TCA_WRITE_I2C_FAIL,        // 3 denemede de yazılamadı (donanım/hat hatası)
  TCA_WRITE_LOCK_TIMEOUT,    // I2C kilidi alınamadı
  TCA_WRITE_BOTH_ON,         // REDDEDİLDİ: panjur çiftinde iki yön aynı anda
  TCA_WRITE_REVERSAL,        // REDDEDİLDİ: tek yazımda doğrudan yön değişimi
  TCA_WRITE_DEAD_TIME        // REDDEDİLDİ: kapanmadan sonra <500 ms (hata DEĞİL, bekle)
};
TcaWriteResult TCA_WriteOutputsEx(uint8_t mask);           // "writeMask" (sonuç ayrıntılı)
bool TCA_WriteOutputs(uint8_t mask);                       // TCA_WriteOutputsEx(mask) == TCA_WRITE_OK; bit i = röle i+1 AÇIK
uint8_t TCA_OutputShadow(void);                            // son başarılı yazılan çıkış maskesi
bool TCA_ClearBits(uint8_t clearMask);                     // acil kapatma: gölge & ~clearMask (kapatma her zaman serbest)
// Bağımsız emniyet (ValveGuard, spec §5.1.5 [Y-8], WP-F3): çıkış yazmacının DONANIM değeri (gölge değil). I2C kilidi 80 ms içinde
// alınamazsa ya da okunamazsa false (guard o turu atlar).
bool TCA_ReadOutputHw(uint8_t* out);
// Bağımsız emniyet: güvenli (enerjili) seviyesi 1 olan vana bitlerini KURAR. Panjur çifti bitleri (TCA_SetShutterPairs) REDDEDİLİR, böylece
// interlock bozulamaz. Önce donanım okunup gölge eşitlenir (çip sıfırlanmasında düşen güvenli bit yeniden kurulur); diğer bitler fiziksel
// durumlarında kalır. Kilit alınamazsa / okuma ya da yazım başarısızsa false.
bool TCA_SetSafeBits(uint8_t mask);
uint8_t TCA_ShutterPairMask(void);                         // bit p = (röle 2p, 2p+1) panjur çifti
uint32_t TCA_WriteFailureCount(void);

enum TcaVerifyResult : uint8_t {
  TCA_VERIFY_OK = 0,        // donanım gölgeyle aynı
  TCA_VERIFY_FIXED = 1,     // donanımda gölgede olmayan açık bit vardı: kapatıldı
  TCA_VERIFY_RESET = 2,     // çip sıfırlanmış/bitler düşmüş: gölge donanıma çekildi (üst katman panjurları durdurmalı)
  TCA_VERIFY_ERROR = 3      // okunamadı
};
TcaVerifyResult TCA_Verify(void);                          // periyodik doğrulama (çıkış latch + yön yazmacı)
// Eşitlemede "gölgede AÇIK sanılıp fiziksel olarak KAPALI bulunan" (çip sıfırlanması / düşen röle) bitlerin birikmiş maskesini alır ve sıfırlar.
// TCA_Verify() VE bir röleyi açık bırakacak her TCA_WriteOutputsEx() yazımı (ön denetim) bu maskeyi besler; düşen röleler
// bu yollarla YENİDEN ÇEKİLMEZ. Üst katman, bu bitlerin panjurlarını durdurmalıdır (konum takibi geçersiz).
// Donanım okunamadığı için yazımdan çıkarılıp KAPATILAN (doğrulanamayan) panjur röleleri de bu maskeye eklenir.
uint8_t TCA_TakeDroppedMask(void);

/*****************************************************  Operation register REG   ****************************************************/
bool TCA_ReadReg(uint8_t reg, uint8_t *out);               // dönüş kontrollü okuma
bool TCA_WriteReg(uint8_t reg, uint8_t data);              // dönüş kontrollü yazma
uint8_t Read_REG(uint8_t REG);                             // (eski) hata halinde 0 döner; yeni kodda TCA_ReadReg kullanın
uint8_t Write_REG(uint8_t REG,uint8_t Data);               // (eski) 0 = başarı
/********************************************************** Set EXIO mode **********************************************************/
void Mode_EXIO(uint8_t Pin,uint8_t State);                                          // Set the mode of the TCA9554PWR Pin. State: 0= Output mode 1= input mode
void Mode_EXIOS(uint8_t PinState);                                                  // Set the mode of the 7 pins from the TCA9554PWR with PinState
/********************************************************** Read EXIO status **********************************************************/
uint8_t Read_EXIO(uint8_t Pin);                                                     // Read the level of the TCA9554PWR Pin
uint8_t Read_EXIOS(uint8_t REG);                                                    // Read the level of all pins (REG: TCA9554_INPUT_REG / TCA9554_OUTPUT_REG)
/********************************************************** Set the EXIO output status **********************************************************/
bool Set_EXIO(uint8_t Pin,uint8_t State);                                           // Sets the level state of the Pin (gölge kayıt üzerinden)
bool Set_EXIOS(uint8_t PinState);                                                   // Set all pins to the PinState state (TCA_WriteOutputs)
/********************************************************** Flip EXIO state **********************************************************/
bool Set_Toggle(uint8_t Pin);                                                       // Flip the level of the TCA9554PWR Pin (gölge kayıt üzerinden)
/********************************************************* TCA9554PWR Initializes the device ***********************************************************/
void TCA9554PWR_Init(uint8_t PinMode = 0x00, uint8_t PinState = 0x00);              // Önce çıkış yazmacı (PinState), sonra yön (PinMode); 0= çıkış
