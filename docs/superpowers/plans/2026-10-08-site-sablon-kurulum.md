# Site + Kurulum Şablonu + Ethernet — İş Planı

> Durum: **ONAYLANDI** (2026-10-08, kullanıcı: "şimdi plana başlayabilirsin onaylıyorum"; ek istek: bitince kullanım
> kitapçığı → İP-5.5). Onaydan sonra fazlar sırayla uygulanır; her iş paketi (İP) kendi testleriyle
> kapanır, tamamlanan maddeler `[x]` ile işaretlenir.

**Amaç:** Toplu (site) kurulumlarda servis sorumlusunun sahadaki işini en aza indirmek. Ofiste site ve daire tipi
şablonları oluşturulur; atölyede firmware USB'den, şablon USB **veya** Ethernet'ten karta yazılır; kartla birlikte
kablolama şeması (PDF) sahaya gider; pano sahada internetsiz çalışır; kullanıcı QR ile ekleyince ayarlar panodan gelir.
Tek daire kurulumlarında servis sorumlusu aynı şablonları sihirbazda kullanır. Mevcut servis akışı aynen kalır.

**Kullanıcı kararları (2026-10-08):**
- Ethernet (W5500) açılsın; şablon hem Ethernet'ten hem USB'den yüklenebilsin.
- Şablonlar sunucuda saklansın; **şablon sürümü** tutulsun (hangi karta hangi sürüm yazıldı).
- Site / şablon ekleme-düzenleme-silme-yükleme: **servis sorumlusu (`service_user`) ve süper kullanıcı**.
- Servis yazılımında **site** oluşturulur: ad, adres, sorumlu kişi, telefon, daire sayısı vb.; şablonlar site seçilerek oluşturulur.
- Tek daire kurulumlarında servis sorumlusu aynı şablonları kullanabilir.
- Her şablon için saha ekibine **giriş/çıkış bağlantı şeması PDF**'i üretilir; kartla birlikte gönderilir.

---

## Mevcut durum (kod incelemesi, 2026-10-08)

| Alan | Bugün | Sonuç |
|---|---|---|
| Firmware ağ | Arduino-ESP32 **2.0.17** (IDF 4.4). `ETH` sınıfı W5500 bilmiyor; ama IDF'te `esp_eth_mac_new_w5500` var ve `CONFIG_ETH_SPI_ETHERNET_W5500=y`. Demo `WS_ETH` derlemeden çıkarılmış (F8: Çin saat dilimi + NTP sonsuz döngü). | Ethernet IDF sürücüsüyle, çekirdek DEĞİŞMEDEN eklenir. |
| Wi-Fi varsayımları | MQTT kapısı (`MqttManager.cpp:594`), SNTP tetiği (`WiFiManager.cpp:170,262`), kurtarma AP politikası (`:588`), durum `ip` alanları yalnız Wi-Fi'ye bakıyor. | "Ağ var mı?" tek bir yerden (Wi-Fi **veya** Ethernet) cevaplanmalı. |
| Kart yapılandırması | `ahbu_cfg`: röle adı/tipi/süresi (40), DI adı/hedef/kip (40), ek modül. `POST /api/config` (KEYED, 24 KB). Panjur çifti örtük (2p-1/2p). Güvenlik (`ahbu_safety`) yalnız **tek öğelik yama**; LAN'dan gevşetme yasak. Dimmer güvenlik yapılandırmasında (`light[]`). | Şablon = ana yapılandırma + güvenlik yapılandırması **birlikte, tek seferde** yazılmalı → yeni toplu uygulama. |
| Seri CLI | Satır en çok 159 karakter, JSON yok. `FACTORYINIT` yalnız provizyonsuzken. | Şablon için parçalı (çerçeveli) seri protokol gerekir. |
| NVS | 20 KB, `nvsRoomForConfig` kontrolü var. | Şablon kimliği/sürümü için küçük ayrı ad alanı; bütçe ölçülecek. |
| Sunucu | Site/daire/şablon kavramı **yok**. Rol: `super_user`, `service_user`; `requireServiceManager` hazır. Son migration **034**. Claim'de uç noktalar sabit `SEED_ENDPOINTS_SQL` ile tohumlanıyor, sonra WP-L panodan eşitliyor. | Migration 035 + yeni rotalar; claim tohumu şablondan. |
| Servis yazılımı | Tkinter, 3 sekme; giriş **yalnız `super_user`**; PDF kütüphanesi yok (PIL var); testler `unittest` (~358). | `service_user` girişi açılır; Site ve Şablon sekmeleri; PDF PIL ile. |
| Uygulama | Sihirbaz röle adı/tipi YAZMIYOR (yalnız okuyor); `saveConfig` çağrılmıyor. Şablon yok. | Sihirbaza "Şablon uygula" eklenir. |

---

## Mimari kararlar (gerekçeli; onayla kesinleşir)

**K-Ş1 — Ethernet, çekirdek değiştirmeden.** W5500, IDF 4.4 sürücüsüyle (`esp_eth_mac_new_w5500` + `esp_netif`
yapıştırması) açılır. Arduino çekirdek 3.x'e geçiş **yapılmaz**: TLS/MQTT/zaman kodunun tamamını etkiler, risk çok büyük.
Yeni `NetLink` katmanı "ağ var mı / IP / arayüz" sorusunu Wi-Fi + Ethernet için tek yerden yanıtlar; MQTT kapısı, SNTP,
kurtarma AP'si ve durum alanları buna geçer. Ethernet bağlıyken kurtarma AP'si açılmaz. Cihaz kimliği (UID) **Wi-Fi MAC'te kalır**
(mevcut kartlar ve etiketler bozulmaz). Durum yanıtlarına yalnız **yeni** alanlar eklenir (`eth_connected`, `eth_ip`,
`net_if`); seri `STATUS` mevcut satırları değişmez, yeni satır eklenir (fabrika aracı ayrıştırması korunur).
Ethernet kablosu takılı değilse davranış bugünküyle birebir aynıdır.

**K-Ş2 — Tek şablon biçimi, üç uygulayıcı.** Şablon JSON'u (`ahbu-template/1`) tek kaynakta tanımlanır:
`docs/contracts/template/` altında şema açıklaması + ortak örnek dosyalar (geçerli/geçersiz). Sunucu, firmware ve servis
yazılımı testleri **aynı örnek dosyaları** kullanır; biçim kayması testte yakalanır. İçerik: meta (şablon kimliği,
sürüm, ad, daire tipi, site), ek modül, röleler (kanal, ad, oda, tip, süre), girişler (ad, hedef, kip / güvenlik rolü),
güvenlik (eylemciler, sensörler, bölgeler, politika, dimmer).

**K-Ş3 — Kartta atomik "şablon uygula".** Firmware ana yapılandırmayı ve güvenlik yapılandırmasını birlikte doğrular
(`validateSystemChange` dahil) ve tek iş olarak yazar; herhangi biri geçersizse **hiçbir şey değişmez**. Şablon kimliği,
sürümü ve daire etiketi yeni küçük NVS ad alanına (`ahbu_tpl`) yazılır; durum/state yükünde `tpl {id, ver}` bildirilir.
Böylece bulut ve uygulama hangi şablonun yüklü olduğunu panodan görür.

**K-Ş4 — Güvenlik kuralı korunur.** ⚠ *2026-10-08 kullanıcı kararıyla DEĞİŞTİ:* Ethernet kısıtlamaları kaldırıldı —
provizyon (`factory/init`) Ethernet'ten de yapılır, LAN'dan her geçerli şablon yazılır (gevşetme kuralı yok), servis
yazılımı her envanter kartının (müşteri kartı dahil) anahtarını sunucudan alabilir (denetim kaydı + oran sınırı kalır),
IP↔UID ön denetimi kaldırıldı. Ağdan fabrika sıfırlamasına dokunulmadı. Aşağıdaki özgün metin tarihçe içindir.
- **USB (seri):** Fiziksel erişim yetki sayılır (bugünkü `FACTORYINIT`/`SAFETY` gibi). Her durumda uygulanır;
  provizyon gerekmez; güvenlik tablosunu tamamen değiştirebilir.
- **Ethernet (LAN):** Yerel anahtar (`X-Device-Key`) gerekir. "LAN'dan gevşetme yasak" kuralı (7.2b-7) delinmez:
  kartta güvenlik yapılandırması fabrika durumundaysa **ya da** aynı şablonun yeni sürümü yalnız sıkılaştırıyorsa uygulanır;
  aksi halde `403 local_loosen_forbidden` döner ve araç "USB ile yazın" der. Atölyede kartlar fabrika durumunda olduğu
  için pratikte Ethernet her zaman çalışır.
- Ethernet yazımı için yerel anahtarı servis yazılımı sunucudan alır (yetkili hesap, denetim kaydıyla); anahtar ekranda
  ve günlükte gösterilmez.

**K-Ş5 — Seri protokol.** `TPL BEGIN <bayt> <crc32>` → `TPL DATA <base64 parça>` satırları (≤150 karakter) →
`TPL COMMIT`; yanıtlar `OK tpl_*` / `ERR <kod>`. CRC uyuşmazsa uygulanmaz. `TPL ABORT` ve zaman aşımı yarım aktarımı
siler. Komut gövdesi günlüğe yansıtılmaz.

**K-Ş6 — Sürümler değişmez.** Şablon her kaydedildiğinde yeni sürüm satırı oluşur (eski sürüm asla değişmez). Silme
"yumuşak"tır: şablon listeden kalkar, sürümleri ve hangi karta yazıldığı kaydı kalır. Her karta yazım
`template_writes` tablosuna (kart, şablon, sürüm, daire, yol: usb/eth, kim, ne zaman, sonuç) işlenir.

**K-Ş7 — Yetki.** Site/şablon CRUD ve yazım kaydı: `service_user` + `super_user` (`requireServiceManager`;
servis PIN oturumu **hariç**). Servis sorumlusu tüm siteleri görür (site sayısı az; kapsam kısıtlaması gerekirse
ileride `site_staff` eklenir). Ev sahipleri şablon göremez.

**K-Ş8 — Claim ile bağ.** Envanter kartı bir daireye bağlanabilir. Kart claim edilince ev adı daireden gelir
("Güneş Sitesi A-12"), uç noktalar sabit tohum yerine **karta yazılmış şablon sürümünden** tohumlanır; sonrasında WP-L
eşitlemesi bugünkü gibi panoyu esas alır (şablon ile pano çelişirse pano kazanır).

**K-Ş9 — PDF, yeni bağımlılıksız.** Şema PIL ile A4/300 DPI çizilip PDF olarak kaydedilir (PIL'in PDF yazıcısı zaten
var; kurulum/paketleme değişmez). İçerik: site/daire tipi/şablon sürümü başlığı, karta bakan klemens düzeni, her röle
çıkışı → bağlanacak yük, her DI → anahtar/sensör (NO/NC), ek modül adresi/kanalları, dimmer yerleşimi (K4 yönergesi),
güvenlik cihazları ve uyarılar, panjur çiftlerinin yön notu, QR (şablon kimliği+sürüm). Türkçe yazı tipi mevcut
`_load_font` ile.

**K-Ş10 — Tek daire kurulumu.** Sihirbaz (uygulama) panoya bağlandıktan sonra "Şablon uygula (isteğe bağlı)"
sorar; seçilen şablon LAN'dan (K-Ş4 kuralıyla) yazılır; röle/panjur/giriş adımları şablon değerleriyle dolu gelir,
yalnız test kalır. Şablon seçmeyen servis sorumlusu bugünkü akışı aynen sürdürür.

---

## Fazlar ve iş paketleri

### Faz 0 — Sözleşme
- [x] **İP-0.1** `docs/contracts/template/README.md`: `ahbu-template/1` alan alan tanım, sınırlar (40 röle/40 DI, ad
  ≤31 bayt UTF-8, süre aralıkları, panjur çifti kuralı, güvenlik alanları firmware'deki `SafetyConfig` ile birebir).
- [x] **İP-0.2** Örnek dosyalar: `ok_1+1.json`, `ok_2+1.json`, `ok_3+1_vana_dimmer.json`, `ok_ekmodul_16.json`,
  `bad_*.json` (bozuk panjur çifti, eylemci röle panjur, sınır dışı süre, bilinmeyen alan…), her birinin beklenen hata kodu.
- [x] **İP-0.3** `docs/CONTRACTS.md` güncellemesi: yeni REST uçları, `POST /api/template/apply`, `GET /api/template`,
  seri `TPL *`, durum/state `tpl`, `eth_*` alanları.

### Faz 1 — Sunucu (`server/`, migration 035)
- [x] **İP-1.1** Migration `035_sites_templates.sql`:
  - `sites` (ad, adres, il/ilçe, sorumlu adı, sorumlu telefonu, e-posta, blok sayısı, daire sayısı, not, oluşturan, zaman damgaları, `deleted_at`)
  - `site_flats` (site, blok, daire no, daire tipi, atanan şablon, bağlı kart `device_uuid` boş olabilir, durum: planlandı/yazıldı/kuruldu/teslim)
  - `install_templates` (site — boşsa "genel/standart" şablon —, ad, daire tipi, güncel sürüm, `deleted_at`)
  - `install_template_versions` (şablon, sürüm no, gövde JSONB, gövde SHA-256, oluşturan, zaman; **güncelleme/silme yok**)
  - `template_writes` (kart, şablon, sürüm, daire, yol usb/eth, yazan, zaman, sonuç, hata kodu)
  - İdempotent, `NOT VALID`+`VALIDATE` deseni; statik test + gerçek PG testi (55432).
- [x] **İP-1.2** `utils/template_schema.js`: K-Ş2 doğrulayıcısı (saf fonksiyon) — Faz 0 örnekleriyle test.
- [x] **İP-1.3** Rotalar (`createRouter(deps)` deseni, `requireServiceManager`):
  - `/api/v1/sites` CRUD + `/sites/:id/flats` (toplu daire üretimi: "A blok 1-24")
  - `/api/v1/templates` CRUD (site filtresi, "genel" şablonlar)
  - `/templates/:id/versions` (liste) + `/templates/:id/versions/:v` (gövde)
  - `POST /api/v1/template-writes` (yazım kaydı)
  - `PUT /sites/:id/flats/:flatId/device` (kartı daireye bağla; envanter durumu kontrolü)
- [x] **İP-1.4** Ethernet yazımı için yerel anahtar: envanter kartı için yetkili okuma ucu (super + service_user,
  denetim kaydı, oran sınırı). Mevcut bir uç varsa o kullanılır.
- [x] **İP-1.5** Claim entegrasyonu (K-Ş8): kart bir daireye bağlıysa ev adı daireden, uç nokta tohumu karta yazılmış
  şablon sürümünden; değilse bugünkü davranış. State `tpl` alanı `devices` tablosunda saklanır.
- [x] **İP-1.6** Testler (`node:test`): yetki matrisi (owner/guest/servis PIN → 403), sürüm değişmezliği, yumuşak silme,
  doğrulama, claim tohumu; `check_schema_contract` yeşil.

### Faz 2 — Firmware v1.3.0
- [x] **İP-2.1** `NetLink` katmanı: Wi-Fi + Ethernet birleşik bağlantı durumu; MQTT kapısı, SNTP tetiği, kurtarma AP
  politikası, durum `ip` alanları buna geçer. Wi-Fi-only davranış birim testlerle sabitlenir (yerel `pio test` / saf mantık testi).
- [x] **İP-2.2** W5500 sürücüsü (IDF 4.4 `esp_eth` + `esp_netif`, pinler `WS_ETH.h`'tekiler: CS16 IRQ12 RST39 SCK15
  MISO14 MOSI13). Demo NTP/RTC kodu **geri gelmez**. Kablo yokken açılış süresi ve bellek ölçülür.
- [x] **İP-2.3** Şablon ayrıştırma + doğrulama (`TemplateApply`): ana yapılandırma + güvenlik birlikte; saf mantık
  Faz 0 örnekleriyle test edilir.
- [x] **İP-2.4** Atomik uygulama: güvenlik için toplu değiştir (`SafetyManager` yeni yolu; LATCHED/ARMED iken red),
  ana yapılandırma kaydı, `ahbu_tpl` (id, sürüm, daire etiketi). Panjur hareket halindeyse `409 busy`. NVS bütçesi ölçülür.
- [x] **İP-2.5** `POST /api/template/apply` (KEYED, K-Ş4 LAN kuralı) + `GET /api/template`; durum ve MQTT state'e `tpl`.
- [x] **İP-2.6** Seri `TPL BEGIN/DATA/COMMIT/ABORT/STATUS` (K-Ş5), zaman aşımı, CRC; gövde günlüğe yazılmaz.
- [x] **İP-2.7** `pio run` yeşil; sürüm notu "DONANIMDA DENENMEDİ" bandıyla; birleşik imaj + SHA256.

### Faz 3 — Servis yazılımı (`ev_otomasyon_servis_yazilimi/`)
- [x] **İP-3.1** Giriş: `service_user` da girebilsin (bugün yalnız `super_user`). Envanter kaydı/durum/silme yetkileri
  sunucudaki gibi kalır (servis sorumlusu fabrika kaydı yapamaz; yalnız süper kullanıcı).
- [x] **İP-3.2** `🏢 4. Siteler` sekmesi: site ekle/düzenle/sil (ad, adres, il/ilçe, sorumlu, telefon, e-posta, blok
  ve daire sayısı, not); blok/daire listesini toplu üret; daireye daire tipi + şablon ata; ilerleme sütunu
  (planlandı/yazıldı/kuruldu/teslim).
- [x] **İP-3.3** `📐 5. Şablonlar` sekmesi: site seç → şablon ekle/düzenle/sil/çoğalt; röle tablosu (kanal, ad, oda,
  tip: lamba/priz, panjur yukarı/aşağı, darbe, vana, siren, fan), girişler (anahtar/buton, su, gaz, duman, kapı/pencere,
  NO/NC, bölge), ek modül, dimmer sorusu (K4: "parlaklık ayarı yapılacak mı?" → dimmer gerekli + nereye). Kaydetmeden
  önce sunucu doğrulaması; her kayıt yeni sürüm; sürüm geçmişi görünümü.
- [x] **İP-3.4** Karta yaz: daire (ya da yalnız şablon) seç → **USB** (`TPL` seri, mevcut port/arka uç altyapısı) veya
  **Ethernet** (IP gir/ara, yerel anahtar sunucudan) → sonuç `template_writes`'a işlenir → karttan `GET /api/template`
  / `TPL STATUS` ile geri okunup doğrulanır. Firmware yükleme sonrası akış: flash → FACTORYINIT → şablon yaz zinciri.
- [x] **İP-3.5** PDF kablolama şeması (K-Ş9) + etikete daire bilgisi ("A Blok / Daire 12 · 3+1 · Şablon v4").
- [x] **İP-3.6** Testler (`unittest`): sahte sunucu + `FakeFirmwareCli`'ye `TPL` desteği; Ethernet için `LoopbackHttpServer`;
  PDF üretimi (sayfa boyutu, metin varlığı); yetki (service_user girişi); kullanım rehberi + `test_guide_consistency` güncellemesi.

### Faz 4 — Uygulama (Flutter)
- [x] **İP-4.1** Bulut API: şablon listesi/sürümü, yazım kaydı (servis rolleri).
- [x] **İP-4.2** Yerel API: `applyTemplate`, `fetchTemplate`; durum modelinde `tpl`, `eth_*`.
- [x] **İP-4.3** Sihirbaz: bağlantıdan sonra "Şablon uygula (isteğe bağlı)" kartı (K-Ş10); uygulanırsa 7-9. adımlar
  şablon değerleriyle gelir, yalnız test kalır; panonun yüklü şablonu cihaz bilgisinde görünür.
- [x] **İP-4.4** Testler: sihirbaz akışı (şablonlu/şablonsuz), LAN `local_loosen_forbidden` → kullanıcıya açıklama,
  360x640 / 2.0x yazı düzen testi.

### Faz 5 — Dağıtım ve belgeler
- [x] **İP-5.1** Bağımsız kod incelemesi (sunucu+firmware+araç) ve bulguların düzeltilmesi.
- [x] **İP-5.2** Canlı: DB yedeği → migration 035 → ev-api dağıtımı (dizin takası) → duman testi.
- [ ] **İP-5.3** Firmware v1.3.0 yayımı (onayınızla karta yazılır); servis yazılımı kullanım rehberi; CONTRACTS.
- [x] **İP-5.5** Kullanım kitapçığı (PDF + Markdown): servis sorumlusu (site/şablon/karta yazma), atölye (flash +
  şablon USB/Ethernet + etiket + PDF şema), saha ekibi (şemaya göre kablolama + kablolama testi), sorun giderme.
- [ ] **İP-5.4** Sizin denemeniz: Ethernet kablosuyla şablon yazma, USB ile şablon yazma, PDF çıktısı, claim sonrası
  uygulamada adların gelmesi.

### Sonraki aşama (bu planın dışında, ayrıca onaylanır)
Kullanıcının kendi kurulumu: QR → pano Wi-Fi'si → ev interneti → giriş → cihaz ekle → rehberli ilk kontrol →
"çalışmıyor" ise servis talebi. Bu planın şablon/daire/claim altyapısı bunun temelini oluşturur.

---

## Riskler
- **Ethernet donanımda denenmedi.** Sürücü derlenir ve mantık testlenir; gerçek doğrulama ancak kartta kabloyla olur (İP-5.4).
- **NVS 20 KB.** Toplu güvenlik yazımı + şablon meta alanı ölçülerek eklenir; yer yoksa uygulama reddedilir (yarım yazım olmaz).
- **Eski kartlar (v1.2.x).** Şablon yazımı yalnız v1.3.0+'da; araç ve uygulama sürümü görüp açıkça "önce firmware güncelleyin" der.
- **Pano–şablon çelişkisi.** Sahada biri ayarı değiştirirse pano esastır (WP-L); şablon sürümü "yazıldığı andaki" kayıttır.

## Doğrulama ölçütleri (bitmiş sayılması için)
Sunucu `npm test` + PG testleri yeşil; firmware `pio run` yeşil + saf mantık testleri; servis yazılımı `unittest` yeşil;
uygulama `flutter analyze` 0 + `flutter test` yeşil; ortak örnek dosyalar üç tarafta aynı sonucu veriyor; canlı duman testi.
