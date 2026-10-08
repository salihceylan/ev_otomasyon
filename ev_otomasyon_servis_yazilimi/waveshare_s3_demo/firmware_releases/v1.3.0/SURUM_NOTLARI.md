# AHBU Akıllı Ev - ESP32-S3 firmware v1.3.0 (sürüm notları)

> **DONANIMDA DENENMEDİ.** Bu imaj hiçbir karta yazılmadı ve hiçbir kartta açılmadı; Ethernet (W5500) hiç kabloyla denenmedi.
> Dosya düzeyinde doğrulandı (esptool `image_info`: checksum + validation hash geçerli; 0x0000-0xFFFF bölgesi v1.2.1 ile bayt bayt
> aynı; 0x10000 sonrası = uygulama imajı; imajda "1.3.0" var, "1.2.1" yok) ve saf mantık donanımsız testlerle sınandı (firmware'in kendi
> Unity testleri MSVC ile: 23 takım / 396 test, yeni 4 takım: `test_template_parse` (ortak 31 örnek dosya), `test_template_rules`,
> `test_tpl_serial`, `test_net_link`). Toplu üretimden ve sahaya çıkmadan önce aşağıdaki "İlk kartta denenecekler" listesinin tamamı tek
> bir test kartında yapılmalıdır. `version_info.json` bu paketle GÜNCELLENMEDİ (yayın kararı ayrıca verilir).

Plan: `docs/superpowers/plans/2026-10-08-site-sablon-kurulum.md` Faz 2 (İP-2.1..2.7). Sözleşme: `docs/contracts/template/README.md`,
`docs/CONTRACTS.md` §3e.

## Dosyalar

| Dosya | Boyut (bayt) | Amaç |
| --- | --- | --- |
| `firmware_combined_0x0.bin` | 1382368 | **Karta yazılacak ana imaj** (0x0 adresine). Bootloader + bölüm tablosu + boot_app0 + uygulama birleşik. |
| `app_0x10000_v1.3.0.bin` | 1317168 | Yalnızca uygulama (yedek; OTA alıcısı YOKTUR). Gerekirse esptool ile 0x10000'a yazılır; **0x0'a yazmayın**. |
| `SHA256SUMS.txt` | - | `sha256sum -c SHA256SUMS.txt` ile doğrulayın. |

SHA-256 (ana imaj): `b0a13c989560d1fec8bed5f96cb8ccea6927362141ac04805b31314583a50f72`
SHA-256 (yalnız uygulama): `1a2a4df9937b5d8266fe5b4118e3d2bdd5d43d737f62c65959d3a8feb7754e64`
ELF SHA-256: `232f151d1c53fdfc1d2cf042c57a7134952cedb0388a0c5a9b330b297caaea15`

Derleme: PlatformIO espressif32@7.1.3 (Arduino-ESP32 2.0.17 / IDF 4.4, çekirdek DEĞİŞMEDİ), esptool 4.11.0 `merge_bin`
(`--flash_mode dio --flash_freq 80m --flash_size 16MB`, 0x0 bootloader / 0x8000 bölüm tablosu / 0xe000 boot_app0 / 0x10000 uygulama).
Boyut: Flash 1256049 -> 1316805 bayt (+60756, %41,9 / 3 MB), statik RAM 68624 -> 69256 bayt (+632).

## Kullanıcı kararı: Ethernet kısıtlamaları kaldırıldı (2026-10-08; paket yeniden üretildi, önceki 1.3.0 özetleri `97c21d15…` / `c1a42e2d…`
## ve `3ce05170…` / `9b62c948…` GEÇERSİZ)

Kullanıcı, riskler anlatıldıktan sonra açıkça karar verdi:
- **`POST /api/factory/init` Ethernet'ten de kabul edilir** (v1.2.1 davranışı: kaynak arayüz denetimi yok; kurulum AP'sinden aynen).
  `403 factory_ap_only` KALDIRILDI. **Risk:** provizyonsuz bir kart Ethernet'e takılıysa aynı LAN'daki herhangi biri onu sahiplenebilir;
  atölyede flash'tan hemen sonra provizyon (seri `FACTORYINIT` tercih) yapılmalıdır. Provizyonsuz kartta Ethernet bağlıyken kurulum AP'si
  yine açılır (R1-1'in bu kısmı korundu).
- **K-Ş4 LAN gevşetme kuralı KALDIRILDI:** `POST /api/template/apply` geçerli her şablonu uygular (güvenlik tablosunu gevşetse de, başka
  şablon / eski sürüm olsa da), güvenli kipte ve yarım işlemde de; başarılı LAN uygulaması da `txn` işaretini siler (seri ile aynı).
  `403 local_loosen_forbidden` bu uçta artık üretilmez. Kalan durum denetimleri: `409 zone_latched`, `409 armed`, `409 busy` (panjur
  hareketi), `503 busy` (başka uygulama sürüyor), `409 cfg_invalid`, `507 storage`, `400` doğrulama. **Risk:** yerel anahtarı bilen biri
  LAN'dan güvenlik tablosunu (gaz/su vanası, sensörler) tamamen değiştirebilir/boşaltabilir.
- `POST /api/system/reset` DEĞİŞMEDİ (kullanıcı kararı).
- Kaldırılan kod: `TemplateRules` `isFactoryState`, `LanRule`/`lanRule`, `ApplyResult::LOOSEN` ve testleri. `SafetyState` + `SafetyManager::
  cfgStored()/cfgUsable()` yalnız başarısız uygulamanın güvenlik geri alma biçimi (`safetyRollbackKind`) için kaldı.

## İnceleme turu 1 düzeltmeleri

- **R1-1** (kısmen geri alındı, yukarıya bakın): provizyonsuz kartta Ethernet bağlı olsa da kurulum AP'si açılır (AP politikası
  Ethernet'i yalnız provizyonlu kartta "bağlı" sayar). `factory_ap_only` kısıtı kullanıcı kararıyla kaldırıldı.
- **R1-2 işlem işareti:** uygulama NVS'e İLK `ahbu_tpl/txn=1` yazar, sonra güvenlik -> ana yapılandırma -> şablon kaydı, en son `txn`'i
  siler. Açılışta `txn` varsa uygulama yarıda kalmıştır: güvenlik yapılandırması kullanılmaz (cfg_corrupt güvenli kipi, röleler güvenli
  maskede), tam durumda `"tpl_incomplete":true`, `GET /api/template`'te `"incomplete":true`, seri STATUS `Sablon:` satırı sonunda
  `YARIM (guvenli kip; seri TPL ile yeniden yazin)`. Şablon yeniden uygulanınca (seri TPL ya da LAN) temizlenir.
- **R1-3** (LAN kuralı kullanıcı kararıyla kaldırıldı): başarısız uygulamada güvenlik bölümü — hiç yazılmamışsa silinir,
  kullanılamıyorsa / yarım işlemdeyse "ver" geçersiz bırakılır, aksi eskisi yazılır.
- **R1-4 DNS:** her arayüzün DHCP DNS'i kira anında saklanır; etkin arayüz değişince ya da başka arayüz kira alınca genel lwIP DNS'i
  etkin arayüzünkine çekilir.
- **R1-5 MQTT:** bağlantı kurulduğu arayüz saklanır; etkin arayüz değişirse bağlantı bırakılıp hemen yeniden kurulur.
- **R1-6 loopTask'ta NVS/JSON yok:** ayrıştırma + NVS işlemi ayrı işçi görevde (`tpl_apply`, Core 1, öncelik 0); loopTask yalnız canlı
  takası yapar (ana + güvenlik aynı turda; kilit/panjur yeniden denetlenir). Takas reddedilirse NVS geri alınır. Başarıda ana
  yapılandırma NVS'i canlıdan yeniden eşitlenir, `txn` en son silinir. Seri `TPL COMMIT` yanıtı (`OK tpl_applied` / `ERR`) işçi bitince
  basılır; o sürede yeni COMMIT `ERR busy`.
- **R1-7** hata yolu (`path`) seri satıra / JSON'a basılmadan önce `[A-Za-z0-9_.[]]` dışı her bayt `?` yapılır.
- **R1-8** HTTP uygulaması 10 sn içinde bitmezse `202 {"pending":true}` (uygulama sürer; istemci `GET /api/template` ile doğrular);
  başka uygulama sürerken `503 busy`.
- **R1-9** LAN kuralıyla birlikte kalktı (sürüm denetimi yok).

## v1.2.1'den farklar

**Ethernet kablosu takılı değilse ve karta şablon yazılmadıysa davranış v1.2.1 ile aynıdır** (bütün karar mantığı Wi-Fi-only durumda
eskisiyle aynı sonucu verir: `test_net_link`). Mevcut durum alanları ve seri `STATUS` satırları değişmedi; yalnız yeni alan/satır eklendi.

- **Ethernet (W5500, K-Ş1).** IDF 4.4 `esp_eth` sürücüsü (çekirdek değişmeden): SPI2, CS 16 / INT 12 / RST 39 / SCK 15 / MISO 14 / MOSI 13,
  20 MHz; DHCP istemcisi; MAC = `esp_read_mac(ESP_MAC_ETH)` (W5500'ün kendi MAC'i yok). Başlatma ayrı tek seferlik görevde (`eth_init`,
  Core 0) yürür, açılışı bloklamaz; W5500 yanıt vermezse `[ETH] W5500 yanit vermedi: Ethernet YOK (Wi-Fi ile devam).` basılır ve kart
  Wi-Fi ile aynen çalışır. Seri günlükte `[ETH] Baslatma ... (<ms>, bos yigin <bayt>)` satırı sahada süre/yığın ölçümü içindir.
  Eski demo `WS_ETH` (Çin saat dilimi NTP + sonsuz bekleme) SİLİNDİ, geri gelmedi. UID Wi-Fi MAC'inden kalır.
- **NetLink (tek "ağ var mı" kaynağı).** MQTT bağlantı kapısı, SNTP tetiği, kurtarma AP politikası ve durum `ip` alanları Wi-Fi VEYA
  Ethernet'e bakar. Etkin arayüz: Wi-Fi bağlıysa `wifi`, değilse Ethernet bağlıysa `eth`, değilse `none`. **Ethernet bağlıyken kurtarma
  AP'si kendiliğinden açılmaz** (servis AP'si `AP ON` ile yine açılır). AP kaynaklı anahtarsız Wi-Fi yolu (§3d), Ethernet alt ağı AP alt
  ağıyla çakışıyorsa kapanır (STA kuralının aynısı).
- **Yeni durum alanları** (tam `GET /api/status` ve MQTT state): `eth_connected` (bool), `eth_ip` ("0.0.0.0" bağlı değilken), `net_if`
  (`wifi|eth|none`), `tpl` `{"id","ver"}` (yalnız şablon yüklüyse). `ip` = etkin arayüzün IP'si (ağ yoksa tam durumda AP IP'si, state'te
  0.0.0.0 — eskisi gibi).
- **Kurulum şablonu (`ahbu-template/1`, K-Ş2..K-Ş5).** Ana yapılandırma (ad, ek modül, röle ad/tip/süre, DI ad/hedef/kip) + güvenlik
  yapılandırması (politika, hırsız gecikmeleri, bölgeler, sensörler, eylemciler, dimmer seçenekleri) TEK iş olarak doğrulanır ve yazılır.
  - `POST /api/template/apply` (KEYED, gövde en çok 24 KB) `{"template":{...},"label":"..."}` -> `200 {"ok":true,"template_id","version","rev"}`.
    Hatalar: `400 {"error":<şablon kodu>,"path":...}`, `409 zone_latched|armed|busy|cfg_invalid(+detail)`,
    `413 too_large`, `507 storage`, `503 busy`, `202 {"pending":true}` (10 sn'de bitmedi, sürüyor), bozuk JSON `400 invalid_json`
    (`403 local_loosen_forbidden` artık YOK).
  - `GET /api/template` (KEYED) -> `{"template_id":"…"|null,"version":N|0,"label":"…","applied_at_uptime_s":N|null}`.
  - LAN ve seri AYNI kural (K-Ş4 LAN gevşetme yasağı kullanıcı kararıyla kaldırıldı): geçerli her şablon uygulanır.
  - Seri `TPL BEGIN <bayt> <crc32> | TPL DATA <base64> | TPL COMMIT | TPL ABORT | TPL STATUS` (fiziksel erişim: provizyon gerekmez,
    kilit/kurulu alarm/panjur hareketi reddedilir). En çok 24576 bayt, CRC-32 IEEE, 30 sn zaman aşımı, `TPL DATA`
    satırları yankılanmaz. Yanıtlar `OK tpl_begin` / `OK tpl_data <n>` / `OK tpl_applied <id> <ver>` / `OK tpl_abort` /
    `TPL <id|-> <ver> <label>` / `ERR <kod> [path]`.
  - Atomiklik (R1-2/R1-6): ayrıştırma + NVS işlemi işçi görevde; NVS sırası `txn=1` -> güvenlik tamamı (rev+1) -> ana yapılandırmanın
    değişen anahtarları -> `ahbu_tpl` kaydı; canlı RAM bu aşamada değişmez. Sonra ana + güvenlik yapılandırması aynı loopTask turunda
    canlıya alınır, `txn` en son silinir. Herhangi bir adım başarısızsa yazılanlar geri alınır (`507 storage` / ret kodu). Geri alma da
    başarısız olursa ya da elektrik bu aralıkta kesilirse `txn` kalır -> sonraki açılış güvenli kip + `tpl_incomplete`; seri TPL ile kurtarılır.
  - `device_name` = `label`, boşsa `meta.name`'in ilk 31 baytı (UTF-8 karakteri bölünmez).
  - NVS ad alanı `ahbu_tpl` (`txn` u8, `ver` u32, `id`, `label`); fabrika sıfırlaması siler.
- **Seri STATUS:** en sona iki yeni satır: `  - Ethernet: <bagli|yok> <ip|->` ve `  - Sablon: <id|-> v<ver>`. Eski satırlar aynen.
- **İç yeniden düzenleme (davranış değişmez):** `safety/SafetyCfgApi` sensör/eylemci/ışık öğe ayrıştırıcıları yama ve şablon için ortak
  (`parse*Item`); UTF-8 yardımcıları saf `Utf8Util.h`'ye taşındı; `ConfigManager::saveCandidate` (canlı RAM'e dokunmadan NVS yazımı).

## NVS bütçesi (tahmin, `test_template_rules`; sahada ölçülmedi)

Bölüm 20 KB = 5 sayfa x 126 girdi = 630 girdi (1 sayfa çöp toplamaya ayrılı). Şablon uygulaması yazımdan önce
`güvenlik tamamı + ana yapılandırmanın değişen anahtarları + ahbu_tpl + kilit payı (16) + GC sayfası (126)` kadar BOŞ girdi arar:
tipik 8 kanallı şablon (2 sensör, 1 vana) **223**, en kötü durum (40 kanal, bütün adlar 31 bayt, 56 sensör + 16 eylemci) **540** boş girdi.
Yetmezse hiçbir şey yazılmaz (`507 storage` / `ERR storage`). Dolu bir kartta 40 kanallı şablonun reddedilmesi olasıdır.

## Sözleşmeden sapmalar / eklemeler (firmware'in seçtiği kodlar; README'de yok)

- `meta` hataları: `invalid_template_id`, `invalid_version`, `invalid_name`, `invalid_flat_type`, `invalid_site_id`; zarf `invalid_label`;
  `room`/`load`/`wiring` sınır dışı: `invalid_room` / `invalid_load` / `invalid_wiring`; ışık seçeneği lamba dışı/çift röle:
  `invalid_light`; tanımsız bölgeye eylemci: `act_zone`; bölge listesi: `bad_zone` / `bad_name`; tip/alan hataları `bad_field`;
  güvenlik öğelerinin kendi ayrıştırıcı kodları (`bad_id`, `bad_kind`, `bad_value`, `bad_relay`, `bad_name`); sayı sınırları `count`.
- Seri: geçersiz base64 / 150 karakter üstü DATA `ERR tpl_b64`; bellek yetmezse `ERR busy`.
- HTTP: bozuk JSON `400 invalid_json` (README seri yolda `bad_json`; seri yol `bad_json` döner).
- Cihaz durumuna bağlı ana yapılandırma çelişkisi (açılış güvenli maskesi, `validateSystemChange`): `409 cfg_invalid` + `detail`
  (`/api/config` ile aynı).

## İlk kartta denenecekler (tamamı yapılmadan sahaya çıkmaz)

0. `factory/init` Ethernet'ten ve kurulum AP'sinden 200; provizyonsuz kartta Ethernet takılıyken kurulum AP'si açılıyor.
1. Kablosuz açılış: `[ETH] W5500 basladi` / süre satırı; `STATUS` eski satırlar + `Ethernet: yok -`, `Sablon: - v0`; Wi-Fi, MQTT, AP
   penceresi v1.2.1 gibi.
2. Kablo tak: `[ETH] IP alindi`, `GET /api/status` `eth_connected:true`, `net_if` (Wi-Fi yoksa `eth`), MQTT Ethernet'ten bağlanır
   (TLS + SNTP), Wi-Fi tanımsızken kurtarma AP'si açılmaz; kablo çek/tak, DHCP yenileme, Wi-Fi + Ethernet birlikte.
3. Ethernet'ten `POST /api/template/apply` (fabrika durumundaki kart) -> 200; `GET /api/template`; yeniden başlatma sonrası `tpl` korunur.
4. USB `TPL BEGIN/DATA/COMMIT` (servis aracı) -> `OK tpl_applied`; CRC bozuk, zaman aşımı, ABORT.
5. Kilitli alarm / kurulu hırsız alarmı / hareket eden panjur sırasında uygulama reddi; güvenlik tablosu dolu kartta LAN'dan başka bir
   şablon (gevşeten dahil) kabul; güvenli kipteki / yarım işlemli kart LAN'dan kurtarılıyor.
6. NVS: dolu kartta 16 ve 40 kanallı şablon (`[SABLON] NVS bos girdi yetersiz` satırı / `nvs_get_stats`).
7. Fabrika sıfırlaması (`/api/system/reset`) sonrası `tpl` yok.
8. Uygulama sırasında güç kesme (NVS yazımı ortası): açılışta güvenli kip + `tpl_incomplete`; seri TPL ya da LAN ile yeniden yazınca normal.
9. Ethernet <-> Wi-Fi geçişinde MQTT yeniden bağlanıyor, DNS etkin arayüzünkine dönüyor (`[AG] Etkin arayuz ... DNS ...`).


## Kullanıcı kararı 2: kablolu Ethernet'ten gelen istekler anahtarsız (2026-10-08; paket yeniden üretildi, önceki özet çiftleri
## `c15095c5…` / `676abcae…` dahil hepsi GEÇERSİZ)

Kullanıcı, riskler anlatıldıktan sonra açıkça seçti ("Yalnız Ethernet'te kilitsiz"):
- Bağlantının panodaki yerel ucu **Ethernet IP'si** ise (`netlink::requestViaEth`) tüm yerel API uçları **anahtarsız ve provizyonsuz**
  yetkilidir (KEYED ve AP_OR_KEYED); `GET /api/status` anahtar başlığı varsa doğrulamadan tam durum verir.
- Ethernet'ten gelen `POST /api/safety/config` seri CLI ile eşittir (`VIA_CLI`): güvenlik yapılandırması gevşetmesi serbest.
- Wi-Fi STA ve SoftAP'ten gelen istekler DEĞİŞMEDİ (anahtarlı, kilit/sayaç, LAN gevşetme yasağı).
- **Bilinen sonuç:** pano modeme kabloyla bağlıysa, modem üzerinden gelen her istek (Wi-Fi'deki telefonlar dahil) Ethernet'ten gelmiş
  sayılır; ev ağındaki herkes anahtarsız tam yetkilidir. Kullanıcı bunu kabul etti.
- Test: `test_net_link` +1 (`requestViaEth`); 23 grup / 396 test, 0 hata. 0x0-0xFFFF bölgesi v1.2.1 ile aynı.
