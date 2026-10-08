#pragma once
// ============================================================================
// template/TemplateApply.h - Kurulum şablonunun kartta uygulanması (v1.3.0 İP-2.4, K-Ş3; inceleme R1-2/R1-6). BAĞLAYICI: kararlar
// template/TemplateParse (biçim/şablon kuralları) ve template/TemplateRules'tadır (saf, testli).
//
// İki giriş, tek uygulayıcı: LAN POST /api/template/apply (WebPortal; KEYED) ve seri "TPL COMMIT" (main.cpp). İkisi de gövdeyi
// startApply() ile ayrı bir işçi görevine ("tpl_apply", Core 1, öncelik 0, TWDT'ye kayıtlı DEĞİL) verir; loopTask yalnız canlı takası
// yapar (serviceLoop, kısa; NVS yazımı ve JSON ayrıştırması loopTask'ta YAPILMAZ).
//
// İşçi (güvenlik yazıcı kilidi writeMux_ tüm iş boyunca tutulur):
//   1) Ayrıştırma + doğrulama (taban = canlı ana yapılandırma kopyası).
//   2) ConfigLock altında: aday = CANLI yapılandırma + şablonun ad/ek modül/röle/DI alanları; karar (TemplateRules::decideApply):
//      kilitli bölge 409 zone_latched, kurulu alarm 409 armed, panjur hareketi 409 busy, validateSystemChange 409 cfg_invalid,
//      NVS payı 507 storage. LAN ve seri AYNI kural (K-Ş4 LAN gevşetme yasağı kullanıcı kararıyla kaldırıldı, 2026-10-08): güvenli
//      kipte / yarım işlemde de uygulanır; başarılı uygulama "txn" işaretini siler (her iki yol da kurtarır).
//   3) Aynı ConfigLock altında NVS İŞLEMİ: "ahbu_tpl/txn"=1 İLK -> güvenlik yapılandırması tamamı (rev+1, "ver" işaretli) -> ana
//      yapılandırmanın değişen anahtarları (saveCandidate; canlı RAM'e dokunmaz) -> ahbu_tpl kaydı. Canlı RAM bu aşamada DEĞİŞMEZ.
//   4) ConfigLock bırakılır, canlı takas loopTask'a postalanır (ana + güvenlik aynı turda; loopTask kilit/panjuru yeniden denetler).
//      Takas 1,5 sn içinde alınmaz ya da reddedilirse NVS geri alınır (aşağıda).
//   5) Başarıda ConfigLock altında ana yapılandırma NVS'e CANLI değerden yeniden eşitlenir (aradaki başka bir save() eski değerleri
//      yazdıysa düzelir) ve "txn" EN SON silinir.
// Geri alma (2-4 arası hata): ahbu_tpl eski kayda, ana yapılandırma eski değerlere, güvenlik bölümü TemplateRules::safetyRollbackKind'e göre
// (eskisi / ad alanı silinir / "ver" geçersiz). Hepsi başarılıysa "txn" silinir; değilse kalır.
// GARANTİ SINIRI: geri alma da başarısız olursa ya da elektrik 3)-5) arasında kesilirse NVS karışık olabilir; bu durumda "txn" işareti
// kalır -> sonraki açılışta güvenlik yapılandırması KULLANILMAZ (cfg_corrupt güvenli kipi, röleler güvenli maskede), durum "tpl_incomplete"
// bildirir ve kart şablon yeniden uygulanarak (seri TPL ya da LAN) kurtarılır. "Hiçbir şey değişmez" yalnız geri almanın başarılı olduğu durum
// içindir.
// ============================================================================
#include <stddef.h>
#include <stdint.h>
#include "template/TemplateParse.h"
#include "template/TemplateRules.h"

namespace tpl {

struct ApplyOutcome {
  ApplyResult r;
  char code[32];           // makine kodu (README / cfgErrText)
  char path[TPL_PATH_LEN]; // INVALID için alan yolu (sanitizePath'ten geçmiş)
  char detail[24];         // CFG_INVALID: cfgErrText
  uint32_t rev;            // OK: yeni güvenlik rev'i
};

// Gövdeyi (uygulama zarfı JSON) ayrıştırıp doğrular; taban = canlı ana yapılandırmanın kopyası. loopTask DIŞINDA çağrılır.
bool parseBody(const char* json, size_t len, TplCandidate& cand, ApplyOutcome& out);

// Gövdenin sahipliği alınır (malloc'lu; her durumda serbest bırakılır). false: başka bir uygulama sürüyor ya da görev açılamadı.
// viaLan=false (seri): sonuç işçi tarafından seri porta "OK tpl_applied <id> <ver>" / "ERR <kod> [path]" olarak basılır.
bool startApply(char* body, size_t len, bool viaLan);

// LAN: işçinin bitmesini en çok timeoutMs bekler. true: bitti (out/id/ver geçerli). false: hâlâ sürüyor (istemciye 202 pending).
bool waitApply(uint32_t timeoutMs, ApplyOutcome& out, char* id, size_t idCap, uint32_t& ver);

bool applyRunning();

// loopTask her tur: bekleyen canlı takası uygular (kısa; NVS yok).
void serviceLoop();

}  // namespace tpl
