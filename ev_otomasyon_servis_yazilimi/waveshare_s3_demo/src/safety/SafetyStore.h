#pragma once
// ============================================================================
// safety/SafetyStore.h - Güvenlik katmanının NVS kalıcılığı. BAĞLAYICI (ESP-IDF nvs API'si; karar içermez).
//
// Tasarım §2.7 [Y-5][Y4][B4][B9]:
//  * "ahbu_safety" (NVS_NS_SAFETY): ver (u8), rev (u32), pol/zones/sens/act/light blob'ları (öğeler + CRC32; yalnız dolu yuvalar).
//    Fabrika sıfırlaması (ConfigManager::resetToDefaults) bu ad alanını siler.
//  * "ahbu_latch" (NVS_NS_LATCH): latch (LatchRecord, 164 B, kendi CRC'si), act_pos (u32: düşük 16 bit açık, yüksek 16 bit
//    bilinen), safe_msk (2 x u64: açılış güvenli maskesi, bootSafeMasks; inceleme turu EM-1/EM-5), di_hist (u64: kalıcı DI kullanım
//    geçmişi, diUseMask; inceleme turu 2 FW2-2), bootc (u32), crash (CrashLog), siren_s (u16), arm (ArmRecord, 20 B: hırsız kipi ve alarm
//    belleği; Faz 2 F2.B.1, F2-4). Fabrika sıfırlaması bu ad alanını SİLMEZ (kurulu ev sıfırlamayla çözülmez).
//  * readBootLatchLocal(): Relay_Init'ten ÖNCE, ConfigManager'dan bağımsız çağrılır: latch blob'unun yerel güvenli seviyesi VE açılış
//    güvenli maskesinin yerel seviyesi (KAPALI komutlu E2C vanalar, bütün E2C gaz vanaları) ilk yazımda korunur.
//  * saveConfig(): önce "ver" geçersiz işaretlenir, blob'lar ve rev yazılır, "ver" en son geçerli yazılır: yarıda kalan yazım bir sonraki
//    açılışta karışık (her blob'u kendi CRC'siyle geçerli) yapılandırma değil cfg_corrupt güvenli kipi olur (inceleme turu RV-4). Boş girdi
//    payı yetmiyorsa (nvsRoomForConfig) hiçbir şey yazılmaz (RV-3).
//  * Kilit kaydı ilk açılışta boş olarak yazılır (yer ayırma): NVS dolarsa önce yapılandırma yazımı başarısız olur, kilit değil
//    (WP-F0 ölçümü, spec "Uygulama notları (EKIP FW)").
// Bütün çağrılar loopTask'tan (ya da setup()'tan) yapılır; WP-F5'teki web yazımı kendi kilidini getirir.
// ============================================================================
#include <stdint.h>
#include "safety/SafetyConfig.h"
#include "safety/IntrusionFsm.h"

namespace safety {

class SafetyStore {
public:
  // true: geçerli (CRC'si doğru) ve en az bir bölgesi kilitli kayıt var; localLevel = yerel güvenli seviye maskesi.
  static bool readBootLatchLocal(uint8_t& localLevel);

  // present: NVS'te güvenlik yapılandırması var mı; crcOk: bütün blob'lar sağlam mı. Bozuk ya da yoksa c = fabrika varsayılanı.
  static void loadConfig(SafetyConfig& c, bool& present, bool& crcOk);
  // touched: false dönüşte NVS'e bir şey yazıldı mı (çağıran eski yapılandırmayı geri yazar).
  // checkRoom=false: boş girdi payı denetlenmez (yalnız başarısız yazımdan sonra ESKİ yapılandırmanın geri yazımı; inceleme turu 2 FW2-3).
  static bool saveConfig(const SafetyConfig& c, bool* touched = nullptr, bool checkRoom = true);
  // v1.3.0 şablon geri alması (TemplateRules::safetyRollbackKind): ad alanını tamamen siler (kart "hiç yazılmamış" durumuna döner) ya da
  // yalnız "ver" işaretini geçersiz yapar (sonraki açılış cfg_corrupt güvenli kipi; karışık/boş tablo "geçerli" sayılmaz).
  static bool eraseConfig();
  static bool markCorrupt();

  static bool loadLatch(LatchRecord& r);          // false: yok ya da bozuk (r boş kayıt olur)
  static bool saveLatch(const LatchRecord& r);
  static bool reserveLatch();                     // kayıt yoksa boş kayıt yazar
  static bool loadArm(ArmRecord& r);              // false: yok ya da tanınmayan sürüm (r boş)
  static bool saveArm(const ArmRecord& r);
  static bool reserveArm();                       // kayıt yoksa "off" kaydı yazar (NVS payı: kilit kaydıyla birlikte ayrılır)

  static bool loadSafeMask(uint64_t& assertMask, uint64_t& levelMask);   // false: yok
  static bool saveSafeMask(uint64_t assertMask, uint64_t levelMask);
  static bool loadDiHist(uint64_t& mask);                      // false: yok (mask = 0)
  static bool saveDiHist(uint64_t mask);
  static void loadActPos(uint16_t& openBits, uint16_t& knownBits);
  static bool saveActPos(uint16_t openBits, uint16_t knownBits);

  static uint32_t bumpBootCount();                // açılış sayacını +1 yazar, yeni değeri döner (yazılamazsa okunanı)
  static void loadCrash(CrashLog& c);
  static bool saveCrash(const CrashLog& c);
  static uint16_t loadSirenS();
  static bool saveSirenS(uint16_t s);
};

}  // namespace safety
