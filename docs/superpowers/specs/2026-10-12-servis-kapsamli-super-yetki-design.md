# Servis sorumlusu: kendi kapsamında süper yetki (tasarım)

Tarih: 2026-10-12 · Durum: **sahip onaylı; sunucu kısmı uygulandı (§10)**; araç ve uygulama bekliyor · Sahip kararları: aşağıdaki §1.

## 1. Hedef ve sahip kararları

- **Kök yönetici** (`super_user`, ör. salihceylan@gmail.com): bütün sistem; bütün servis sorumluları, müşteriler, kartlar.
- **Servis sorumlusu** (`service_user`): **kendi kapsamında** süper kullanıcı gibi; başka servisin kapsamını görmez, dokunamaz.
- Kararlar (2026-10-12):
  1. Müşteri / ev / cihaz **onu kuran servise** aittir (sihirbazla müşteriye bağlayan). Kök istediğinde başka servise aktarır.
  2. Servis, fabrika aracında **kendi stoğuna** kart kaydeder (kayıt, etiket, firmware); kayıt ettiği kart onun stoğudur.
  3. Müşteri uygulamada **"Servisiniz: …"** bilgisini görür, **kaldıramaz** (servis değişikliğini yalnız kök yapar).
  4. Eski kayıtlar: kayıtlardan **kuran servis** bulunur ve atanır; bulunamayanlar kökte kalır.

## 2. Kapsam (kiracılık) tanımı

| Varlık | Sahip alanı (yeni) | Nasıl atanır |
|---|---|---|
| Ev (daire) | `homes.service_owner_id` | Servis sahiplendirince (claim) ya da acil sıfırlamayla devrettiğinde o servis; kök aktarabilir. `NULL` = kök. |
| Kart (envanter) | `device_inventory.service_owner_id` | Servis fabrika aracında kaydedince o servis; kök kaydedince `NULL` (kök stoğu). Servis kartı kurunca kart evin servisine geçer. |
| Müşteri (kullanıcı) | (alan yok; türetilir) | Servisin evlerinden birinde üyesi olan ya da servisin açtığı (`users.created_by_user_id`) son kullanıcı. |
| Site / şablon | `sites.service_owner_id` | Siteyi açan servis. "Genel" şablonlar kökündür: servisler okur ve kullanır, değiştiremez. |

Kurma kuralı: servis yalnız **kendi stoğundaki** ya da **kök stoğundaki** (`NULL`) kartı kurabilir; başka servisin stoğundaki kart `403`.

## 3. Servisin kendi kapsamında yapabildikleri (= süper)

- **Evler:** süresiz tam erişim (görme, kontrol, toplu komut, kurallar, çocuk kilidi, kalibrasyon, devreye alma, pano değişimi,
  güvenlik ayarları ve testleri), üye yönetimi, Home Admin atama, acil sıfırlama (stoğa alma / devir), Sistem Doktoru.
  72 saatlik kurulum penceresi kendi evlerinde **aranmaz**.
- **Envanter:** kendi kartlarını listeleme/arama, kayıt (fabrika aracı), askıya alma/aktif etme, etiket yenileme, PIN kilidini
  kaldırma, stoktaki kartı envanterden silme, firmware yükleme (araç, yerel).
- **Müşteriler:** listeleme, dondurma/açma, parola sıfırlama e-postası, not; kalıcı silme yalnız bütün üyelikleri kendi
  evlerindeyse.
- **Siteler/şablonlar:** kendi sitelerinde tam yetki (daire, kart bağlama, şablon, karta yazma).

## 4. Yalnız kökte kalanlar (yetki yükseltme ve kiracılar arası sızıntıyı önlemek için)

- Servis hesabı açma/silme/dondurma, rol değiştirme (servis kimseyi `super_user`/`service_user` yapamaz, kendi rolünü değiştiremez).
- Kapsamlar arası **aktarım** (ev, kart, site başka servise) ve sahipsiz (kök) evlerin yönetimi.
- Başka servisin verisi; kök hesapları; servis özeti (`/admin/service-summary`); yasal metinler ve küresel ayarlar.
- Değişmeyen güvenlik kararları: hırsız alarmı kurma/çözme hiçbir servis rolünde yok (F2-3); gaz vanası açma hiçbir rolde yok (K-4).

## 5. Yetkilendirme mekanizması (sunucu esastır)

- Yeni yardımcı `server/src/utils/tenant_scope.js`: `isRoot(actor)`, `homeScope(q, actor, homeId)` → `'root'|'tenant'|null`,
  `inventoryScope(actor, inv)`, `userInScope(q, actor, userId)`, `siteScope(actor, site)`.
- `requireHomeAccess`: kullanıcı `service_user` ve `homes.service_owner_id = kullanıcı` ise ev erişimi **kapsamlı süper**
  olarak verilir (`role` izin listesinde `super_user` varsa `super_user`, yoksa `service_user`; `is_super: true`,
  `is_tenant_admin: true`; süre sınırı yok). Böylece ev bazlı bütün uçlar tek yerden açılır.
- Küresel süper denetimi olan servisler kapsam yardımcısına geçer: `device_service` (claim, acil sıfırlama, pano değişimi),
  `inventory_service` + `inventory_routes` + `admin_api_key_middleware` (servis kartları; liste filtreli), `service_panel_service`
  (aboneler = `service_owner_id`), `admin_user_service` (müşteriler), `site_template_service`, `transfer_service`,
  `invitation_service`, `account_deletion_service`, `mqtt_routes` (servis uygulama kimliğinde süre sonu yok).
- Kök-yalnız uçlar `requireRoot` ile korunur; denetim kayıtları (`device_audit_logs` vb.) aktörü ve kapsamı yazar.

## 6. Veri modeli (migration 045)

- `homes`, `device_inventory`, `sites`: `service_owner_id UUID NULL REFERENCES users(id) ON DELETE SET NULL` + dizin.
  Servis hesabı silinirse kapsamı köke düşer (`NULL`).
- Geri doldurma (tek seferlik, migration içinde):
  - Ev: rolü `service_user` olan en eski `home_users` üyesinin kullanıcısı (kullanıcının küresel rolü hâlâ `service_user`);
    yoksa `device_inventory.claimed_by_user_id` servis ise o; yoksa `NULL`.
  - Kart: kurulu kart → evinin servisi; stoktaki kart → `NULL` (bugüne kadar kartları yalnız kök kaydetti).
  - Site: `created_by` servis ise o; yoksa `NULL`.
- Geri alma: yeni kolonlar `NULL`'a çekilir ya da kod önceki sürüme döner (kolonlar zararsız kalır).

## 7. İstemci ve araç

- **Uygulama:** servis paneli ve envanter ekranı servis için süperle aynı düğmeleri gösterir (veri sunucuda filtreli); 72 saat
  notları kalkar; kök-yalnız öğeler (servis hesapları yönetimi, aktarım) servise gizlenir. Ev sahibi ve sakinlerde ev bilgisi
  kartında **"Servisiniz: <ad> · <telefon>"** (salt okunur).
- **Fabrika aracı:** servis girişiyle kayıt/etiket/firmware/askıya alma/silme düğmeleri açılır; envanter tablosu yalnız kendi
  kartlarını gösterir (sunucu süzer).

## 8. Uygulama sırası ve doğrulama

1. Sunucu: migration 045 + `tenant_scope` + ara katman + servisler + testler (kiracılar arası erişim olumsuz testleri zorunlu:
   A servisi B'nin evini/kartını/müşterisini göremez, değiştiremez) → yedekli dağıtım.
2. Fabrika aracı: düğmeler + testler.
3. Uygulama: yetenekler, panel/envanter, "Servisiniz" kartı + testler.
4. Belgeler, kontrol listesi, deneme listeleri.

## 9. Riskler

- **Gizlilik:** servis, müşterisinin evini süresiz görür ve kontrol eder (sahip kararı). Müşteri bunu "Servisiniz" kartında görür.
- **Hesap ele geçirme:** bir servis hesabı ele geçirilirse o servisin bütün müşterileri etkilenir. Öneri: servis hesaplarına
  iki adımlı doğrulama (ayrı iş).
- **Geri doldurma hatası:** yanlış servise atanan ev başka servise görünür. Önlem: geri doldurma raporu (ev başına seçilen
  servis) dağıtımdan önce çıkarılır ve köke gösterilir (`server/scripts/service_scope_backfill_preview.sql`).

## 10. Sunucu uygulaması (2026-10-12) - kararlar ve ayrıntılar

Uygulanan: migration `server/migrations/045_service_scope.sql`, `server/src/utils/tenant_scope.js`, `requireRoot`,
`service_scope_service.js` (aktarım), kapsam geçişi yapılan servisler/rotalar ve testler (kiracılar arası olumsuz + olumlu).

**Mekanizma notları**
- `requireHomeAccess`: kiracı için üyelik satırı aranmaz; evin servisi **başka** servisse o servisin kalan eski üyeliği
  GEÇERSİZdir. Sahipsiz (kök) evde eski uyelik kuralı aynen (72 saat dahil) geçerli kalır, ancak servis paneli, Home Admin
  atama ve kapsam gerektiren yönetim uçları sahipsiz evde servise kapalıdır.
- Servis, evin üyeliğini **kalıcı** tutar (`home_users.role='service_user'`, `installer_expires_at NULL`): ev listesi, zamanlı
  kural sahipliği ve MQTT kimliği üyelik satırını okur. Üyelik şu yollarda korunur/yeniden açılır: claim, acil sıfırlama devri,
  daire devri kabulü (`transfer_service`), Home Admin ataması (kök yaptığında bile), kök aktarımı. Evin servis üyeliğini
  **yalnız kök** çıkarabilir (müşteri/servis kendini çıkaramaz; `members/me` ile ayrılma 409).
- Claim/devir atamaları: servis sihirbazla sahiplendirince ya da acil sıfırlamayla devredince (sahipsiz ev ya da kendi evi)
  evin servisi olur; `super_user` yaptığında ev servisi **değişmez**. Müşterinin başka servise ait boş evi devralınmaz (yeni ev
  açılır). Müşteri kendi uygulamasından servis kartını sahiplenirse ev ve kart **kök** kapsamına düşer (evin servisi yok).
- Kart kurulunca `device_inventory.service_owner_id` = evin servisi (claim, pano değişimi, devir). Stoğa dönen kart, evin
  servisinin stoğunda kalır.
- Servis ve hesap silme: evin (süresiz) servis üyeliği ev sahibinin hesap silmesini/kalıcı silinmesini engellemez (cihazsız ev
  silinir; cihazlı ev yine `SOLE_OWNER`).

**Yeni uçlar (hepsi yalnız kök, JWT `super_user`; servis 403)**
- `PATCH /api/v1/admin/homes/:homeId/service-owner` gövde `{service_user_id: "<uuid>" | null}` (alan ZORUNLU)
- `PATCH /api/v1/admin/inventory/:uuid/service-owner` gövde aynı (kurulu kart 409; evi aktarın)
- `PATCH /api/v1/admin/sites/:siteId/service-owner` gövde aynı
- Eski yollar aynen; `/api` öneki de çalışır. Aktarımda eski servisin uyeliği, uygulama MQTT kimlikleri iptal edilir; tek panolu
  evde cihaz MQTT kimliği ve yerel anahtar dondurulur (eski personel okumuş olabilir).

**Yanıtlara eklenen alanlar (yalnız ekleme)**
- `GET /homes`, `/auth/me`, giriş/yenileme: her evde `service: {name, phone} | null` (e-posta yok).
- Claim yanıtı: `service_owner_id`, `technician_access_unlimited: true` (servis sahiplendirdiğinde); `technician_access_expires_at`
  servis için artık dönmez. Acil sıfırlama yanıtı: `service_owner_id`.
- `GET /admin/inventory`: öğelerde `service_owner_id`, `service_owner_email`; servis için kendi kartlarında `claimed_home_id`.
- `GET /service/subscribers`: `service_owner_id`, `service_owner_name`. `GET /admin/users`: `created_by_user_id`.

**Sınıflandırma (özet)**
- (a) kök-yalnız: servis hesabı açma/rol/parola/dondurma, aktarım uçları, `/admin/service-summary`, zorla Home Admin atama,
  REVOKED durumu, sahipsiz kayıt yönetimi, veri bütünlüğü geçersiz kılmaları (site: durum geri alma, IN_STOCK olmayan kartı
  daireye bağlama, kurulmuş dairenin kartını değiştirme; pano değişiminde başka daireye bağlı kartı söküp alma; iptal/askıdaki
  kartı acil sıfırlamayla stoğa alma), genel şablonları değiştirme.
- (b) kapsamlı süper: `requireHomeAccess` rol kümeleri, claim, acil sıfırlama, pano değişimi, envanter (kendi kartları), müşteriler,
  siteler/daireler/şablonlar (kendi sitesi), servis paneli, üye yönetimi, MQTT kimliği, zamanlı kurallar.
- (c) değişmez: `safety_arm` (servis rolü yok), gaz vanası açma, servis PIN oturumu, daire devri/servis PIN'i (ev sahibi-yalnız),
  hesap silme (personel kendi hesabını silemez), personel ev sahibi olamaz.

**Bilinen açıklar / ertelenenler**
- Servis hesabı ele geçirme riski (§9) için iki adımlı doğrulama ayrı iş.
- Servis, fabrika aracında kayıt sırasında başka kapsamdaki bir kartın varlığını 409 "zaten kayıtlı" yanıtından (UUID/MAC çakışması)
  sezebilir; kartın sahibi/içeriği görünmez.
- Kapsamlı servisin site durumu geri alma gibi veri bütünlüğü geçersiz kılmalarını yapabilmesi sahip kararı bekler (şimdilik kök).
