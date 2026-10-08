#pragma once
// ============================================================================
// template/TemplateStore.h - Karta yazılmış kurulum şablonu kaydı: NVS "ahbu_tpl" (id, ver, label) + RAM kopyası. BAĞLAYICI.
// v1.3.0 İP-2.4 / İP-2.5 (K-Ş3): durum ve MQTT state "tpl":{"id","ver"} (yalnız şablon varsa), GET /api/template, seri TPL STATUS.
//  * Yazım sırası: "ver" = 0 (geçersiz işaret) -> "id" -> "label" -> "ver" = gerçek sürüm -> commit. Yarıda kalan yazım bir sonraki açılışta
//    "şablon yok" okunur (yarım kayıt kullanılmaz).
//  * RAM kopyası yalnız uygulama başarıyla canlıya geçince güncellenir (setRam); okuyucular kritik bölge altında KOPYA alır.
//  * Fabrika sıfırlaması (ConfigManager::resetToDefaults) ad alanını siler.
//  * İşlem işareti "txn" (u8, inceleme R1-2): şablon uygulaması NVS'e İLK olarak txn=1 yazar, en son siler. Açılışta txn varsa uygulama
//    yarıda kalmıştır (elektrik kesintisi / geri alma da başarısız): güvenlik yapılandırması kullanılmaz (cfg_corrupt güvenli kipi),
//    durumda bildirilir ve yalnız seri TPL ile yeniden uygulanınca temizlenir (LAN kuralı bu durumda yasaktır, R1-3).
// ============================================================================
#include <stdint.h>
#include "template/TemplateRules.h"

namespace tpl {

class TemplateStore {
public:
  static void begin();                                   // setup(): NVS'ten okur (ConfigManager::begin sonrası)
  static void get(TplRecord& out);                       // RAM kopyası (yoksa present=false)
  static bool appliedUptime(uint32_t& sec);              // bu açılışta uygulandıysa uygulama anındaki çalışma süresi (sn)
  static bool save(const TplRecord& r);                  // NVS (present=false -> erase)
  static bool erase();                                   // yalnız kayıt anahtarları (ver/id/label); "txn"e dokunmaz
  static bool txnBegin();                                // NVS txn=1 (commit)
  static bool txnEnd();                                  // NVS txn silinir; RAM "yarım işlem" bayrağı temizlenir
  static bool txnInterrupted();                          // açılışta txn vardı ve henüz başarılı uygulama olmadı
  static void setRam(const TplRecord& r, uint32_t appliedUptimeS);
};

}  // namespace tpl
