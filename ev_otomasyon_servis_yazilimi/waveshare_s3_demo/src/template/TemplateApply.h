#pragma once
// ============================================================================
// template/TemplateApply.h - Kurulum şablonunun kartta ATOMİK uygulanması (v1.3.0 İP-2.4, K-Ş3/K-Ş4). BAĞLAYICI: kararlar
// template/TemplateParse (biçim/şablon kuralları) ve template/TemplateRules'tadır (saf, testli).
//
// İki giriş, tek uygulayıcı:
//  * LAN: POST /api/template/apply (WebPortal; KEYED). Ayrıştırma web görevinde, uygulama loopTask'ta (JOB_TEMPLATE_APPLY).
//  * USB: seri "TPL COMMIT" (main.cpp; zaten loopTask). Fiziksel erişim: gevşetme yasağı uygulanmaz, provizyon gerekmez.
//
// applyOnLoop (YALNIZ loopTask; ConfigLock + güvenlik yazıcı kilidi tüm iş boyunca tutulur):
//   1) Aday ana yapılandırma = CANLI yapılandırma + şablonun ad/ek modül/röle/DI alanları (kimlik/Wi-Fi/MQTT o anki değerinde kalır).
//   2) Karar (TemplateRules::decideApply): kilitli bölge 409 zone_latched, kurulu alarm 409 armed, panjur hareketi 409 busy,
//      validateSystemChange (açılış güvenli maskesi) 409 cfg_invalid, LAN gevşetme 403 local_loosen_forbidden, NVS payı 507 storage.
//   3) NVS: güvenlik yapılandırması TAMAMI (rev+1; "ver" işaretli yazım) -> ana yapılandırma (değişen anahtarlar) -> ahbu_tpl.
//      Herhangi biri başarısızsa yazılanlar ESKİ değerlerine geri yazılır (güvenlik: pay denetimsiz, ana: saveCandidate(eski),
//      ahbu_tpl: eski kayıt / silme) ve 507 storage döner. Canlı RAM'e bu aşamada HİÇ dokunulmaz.
//   4) Canlı: ana yapılandırma RAM'e, ardından güvenlik yapılandırması (SafetyManager::applyReplacedOnLoop) aynı loopTask turunda.
//      Güvenlik canlıya alınamazsa ana yapılandırma RAM'i geri yüklenir ve NVS 3) gibi geri alınır.
//   "Hiçbir şey değişmez" garantisi: başarısız uygulamada canlı durum hiç değişmemiş, NVS eski değerlerine dönmüş olur. İstisna: geri yazım
//   da başarısız olursa (NVS arızası) güvenlik bölümünün "ver" işareti geçersiz kalır -> sonraki açılış cfg_corrupt güvenli kipi (karışık
//   tablo kullanılmaz; mevcut RV-4 kuralı) ve ahbu_tpl "şablon yok" okunur. Elektrik kesintisi 3)'ün ortasına denk gelirse aynı sonuç.
// ============================================================================
#include <stddef.h>
#include <stdint.h>
#include "template/TemplateParse.h"
#include "template/TemplateRules.h"

namespace tpl {

struct ApplyOutcome {
  ApplyResult r;
  char code[32];           // makine kodu (README / cfgErrText)
  char path[TPL_PATH_LEN]; // INVALID için alan yolu
  char detail[24];         // CFG_INVALID: cfgErrText
  uint32_t rev;            // OK: yeni güvenlik rev'i
};

// Gövdeyi (uygulama zarfı JSON) ayrıştırıp doğrular; taban = canlı ana yapılandırmanın kopyası. Herhangi bir görevden.
// false: out.r = INVALID (code/path) ya da INTERNAL (bellek).
bool parseBody(const char* json, size_t len, TplCandidate& cand, ApplyOutcome& out);

// YALNIZ loopTask. viaLan: true = LAN (K-Ş4 gevşetme kuralı), false = seri (fiziksel erişim).
ApplyOutcome applyOnLoop(const TplCandidate& cand, bool viaLan);

}  // namespace tpl
