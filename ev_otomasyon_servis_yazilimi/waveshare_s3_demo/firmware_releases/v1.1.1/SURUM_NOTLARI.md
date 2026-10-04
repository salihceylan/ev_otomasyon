# AHBU Akıllı Ev - ESP32-S3 firmware v1.1.1 (sürüm notları)

> **DONANIMDA VE TARAYICIDA DOĞRULANMADI.** Bu imaj yalnızca dosya düzeyinde doğrulandı (başlık, bölüm tablosu, SHA-256
> özetleri, dizgi taraması, fabrika aracının imaj doğrulayıcısı) ve gömülü web sayfası tarayıcısız (statik) denetlendi.
> Hiçbir karta yazılıp çalıştırılmadı; sayfanın görünümü hiçbir tarayıcıda/telefonda görülmedi. Toplu üretimden önce TEK bir
> test kartında şunları deneyin: Flash, FACTORYINIT provizyonu, **telefon tarayıcısında web sayfası (görünüm, giriş
> hatırlama, Çıkış)**, Wi-Fi servis akışı, röle ve panjur denemesi.

## Dosyalar

| Dosya | Boyut (bayt) | Amaç |
| --- | --- | --- |
| `firmware_combined_0x0.bin` | 1251056 | **Karta yazılacak ana imaj** (0x0 adresine). Bootloader + bölüm tablosu + boot_app0 + uygulama birleşik. |
| `app_0x10000_v1.1.1.bin` | 1185520 | Yalnızca uygulama (yedek; v1.1.1'de OTA alıcısı YOKTUR). Gerekirse esptool ile 0x10000'a yazılır; **0x0'a yazmayın**. |
| `SHA256SUMS.txt` | - | `sha256sum -c SHA256SUMS.txt` ile doğrulayın. |

SHA-256 (ana imaj): `a9f6a2919325fd5b368298a8d91d0dc2cef351af39c4b6bb08c654d3fad287c6`
SHA-256 (yalnız uygulama): `65c9c0f3026c712053a894676ce95583096247cbc67bbd5f2f23f823f433d28b`

## v1.1.0'dan farklar (bu sürümde)

Yalnızca gömülü web arayüzü (`src/WebPortalPage.h`) ve sürüm numarası değişti. Wi-Fi/MQTT/panjur/röle emniyet davranışı, API
sözleşmesi ve AP kaynaklı anahtarsız Wi-Fi servis akışı (`docs/CONTRACTS.md` 3d) **aynıdır**; bootloader, bölüm tablosu ve
boot_app0 v1.1.0 ile **bayt bayt aynıdır** (birleşik imajın 0x0000-0xFFFF bölgesi eşit).

- **Yeni görünüm ("Neon Glass", uygulamayla aynı dil):** koyu lacivert zemin (#0B1120 -> #0E1830 gradyan), cam kart yüzeyleri
  (yarı saydam + ince kenar + hafif parıltı), yuvarlak hap düğmeler (birincil: sky -> cyan gradyan), parlayan yuvarlak durum
  noktaları (orb), vurgu aileleri (sky/cyan/emerald/amber/rose/violet), belirgin yazı hiyerarşisi. Telefon (360 px) öncelikli;
  düğme/sekme/liste satırı/girdi dokunma hedefleri >= 44 px (anahtarda görsel 34 px, dokunma alanı 46 px); girdi yazı tipi
  16 px (iPhone'da odakta yakınlaşma olmaz).
- **Açık tema:** telefonun sistem teması açıksa (`prefers-color-scheme: light`) açık tema, koyuysa koyu tema kullanılır.
  Metin/zemin kontrastı >= 4.5:1, kontrol/kenar >= 3:1 (koyu + açık temada 232 çift hesaplandı; en düşük 4.65:1 ve 3.44:1).
- **Erişilebilirlik:** `prefers-reduced-motion` tüm animasyonları kapatır; klavye odak halkaları görünür (`:focus-visible`);
  sekmeler ve anahtarlar gerçek düğmedir (klavye ile kullanılır; `role="tab"` / `role="switch"` + `aria-selected` / `aria-checked`);
  durum yoklaması içerik değişmediyse kartları yeniden çizmez (odak ve animasyon kesilmez).
- **Kalıcı giriş ("bir kere girin, artık otomatik girsin"):** cihaz anahtarı artık `localStorage`'da (`ahbu_key`) saklanır;
  sayfa her açıldığında kayıtlı anahtar `GET /api/auth/check` ile doğrulanır ve otomatik giriş yapılır. v1.1.0'ın oturum
  (`sessionStorage`) anahtarı varsa ilk açılışta `localStorage`'a taşınır. Yalnızca cihazın KABUL ETTİĞİ anahtar yazılır
  (yanlış girilen yazılmaz). Cihaz kayıtlı anahtarı reddederse (`401`: anahtar değişti / cihaz sıfırlandı) kayıtlı anahtar
  HEMEN silinir ve anahtar kutusu açılır ("Kayıtlı anahtar artık geçerli değil..."); yanlış anahtar yoklamayla tekrar
  tekrar gönderilmediğinden cihazda IP kilidi (5 hata -> 60 sn, `423`) tetiklenmez. `localStorage` kullanılamazsa (gizli
  mod vb.) `sessionStorage`, o da yoksa yalnız bellek kullanılır (anahtar o oturumda hatırlanır).
- **"Çıkış" düğmesi (başlıkta):** bu tarayıcıdaki kayıtlı anahtarı (localStorage + sessionStorage + bellek) siler ve sayfayı
  yeniler. AP kaynaklı anahtarsız kurulum modunda gizlidir. Başka sekmede çıkış yapılırsa açık sekme de yenilenir.
- **Yeni görünür metinler (diğer tüm Türkçe etiketler aynen kaldı):** başlıkta `Çıkış` düğmesi (ipucu: "Bu tarayıcıda kayıtlı
  cihaz anahtarını unut"); anahtar kutusunda "Giriş bu tarayıcıda hatırlanır; ortak bir telefondaysanız işiniz bitince üstteki
  “Çıkış” düğmesine basın."; kayıtlı anahtar reddedilince "Kayıtlı anahtar artık geçerli değil (değiştirilmiş veya cihaz
  sıfırlanmış olabilir). Yeni anahtarı girin.". Ek olarak yalnız ekran okuyucu etiketleri (`aria-label`) eklendi.
- **Sürüm:** `FW_VERSION` 1.1.0 -> **1.1.1** (`WiFiManager.h`; durum JSON'unda `fw`, `GET /api/status`, MQTT durumu).
- **Boyut:** uygulama imajı +10304 bayt (1175216 -> 1185520); gömülü sayfa 115011 -> 125324 bayt; RAM aynı (55616 bayt).

## Güvenlik notu (kalıcı cihaz anahtarı)

- Anahtar tarayıcıda **düz metin** saklanır (sayfa düz HTTP ile sunulur; ağ dinleyicisi `X-Device-Key` başlığını zaten görür,
  saklama bu riski artırmaz ama anahtarın telefonda kalma süresini uzatır). **Ortak kullanılan bir telefon/tablette işiniz
  bitince başlıktaki "Çıkış"a basın**; anahtar o zaman silinir. Telefonu devretmeden önce de "Çıkış" yeterlidir.
- Depo, tarayıcı kaynak yalıtımıyla yalnız bu sayfanın kaynağına (`http://<pano IP>`) özgüdür. Kaynak IP'ye bağlıdır:
  pano IP'si değişirse (DHCP) tarayıcı anahtarı bir kez daha sorar; tüm panoların kurulum ağı aynı adreste (`192.168.4.1`)
  olduğundan başka panonun kurulum ağına bağlanınca kayıtlı anahtar o panoda geçersiz sayılır (tek hata sayılır, silinir; AP
  kaynaklı Wi-Fi kurulum akışı anahtarsız olduğundan etkilenmez). Aynı IP'yi kullanan başka bir ağdaki cihaz sayfası aynı
  kaynak sayılır (uzak ihtimal): ortak/paylaşılan telefonlarda "Çıkış" bu yüzden de önemlidir.
- Sayfadaki TÜM dış kaynaklı metin (SSID, kanal/giriş/cihaz adı, IP) `esc()` ile kaçırılır ya da `textContent` ile basılır;
  yeni kod da bu kurala uyar. İçerik güvenlik ilkesi (CSP) aynı kaldı: dış kaynak yok.
- iOS Safari, siteyle 7 gün etkileşim olmazsa betikle yazılan depoyu silebilir (ITP): bu durumda anahtar bir kez daha
  sorulur. Tarayıcı ayarlarından "site verilerini sil" de anahtarı siler.

## Nasıl flash'lanır

Fabrika aracı (`ev_otomasyon_sistemi.py`): "Bizim Geliştirdiğimiz Yazılım" seçili iken dosya yolu
`firmware_releases/v1.1.1/firmware_combined_0x0.bin` olarak gelir (`version_info.json` bunu gösterir) -> kartı USB ile
bağlayın -> **FİRMWARE'İ KARTA YÜKLE (FLASH)**. Kart AYNI araç oturumunda sunucu envanterine kaydedildiyse (SUNUCU
ENVANTERİNE KAYDET) flash bitince USB-seri `FACTORYINIT` provizyonu otomatik başlar; USB kabloyu çıkarmayın. Kart önceki bir
oturumda kaydedildiyse otomatik başlamaz (yerel anahtar sunucudan yalnızca bir kez gelir ve bellekte tutulur): kartı yeniden
kaydedin/etiketi yeniden üretin (rehber §E).

Elle (aracın kullandığı komutun aynısı):

```text
esptool --chip esp32s3 --port COMx --baud 460800 write_flash 0x0 firmware_combined_0x0.bin
```

Not: imaj 0x0'dan itibaren NVS alanını (0x9000-0xDFFF) da kapsar; yazma sonrası kart provizyonsuzdur (FACTORYINIT gerekir).

Sahadaki, ZATEN provizyonlu bir v1.1.0 kartın yalnızca arayüzünü yenilemek ve anahtar/Wi-Fi/kimlik kayıtlarını KORUMAK için
(bölüm tablosu ve bootloader aynı olduğundan; **donanımda denenmedi**) yalnız uygulama imajı 0x10000'a yazılır:

```text
esptool --chip esp32s3 --port COMx --baud 460800 write_flash 0x10000 app_0x10000_v1.1.1.bin
```

## İlk kartta denenecekler (web sayfası dahil)

1. Flash (ana imaj) -> açılış seri çıktısı (bootloader v1.1.0 ile aynı) -> `FACTORYINIT` provizyonu -> `fw` değeri **1.1.1** olmalı
   (Sistem sekmesi "Yazılım Sürümü" ve `GET /api/status`).
2. **Telefon tarayıcısı, kurulum ağı (`http://192.168.4.1`):** AP kaynaklı anahtarsız mod (üstte "Kurulum modu (AP)" bandı, Wi-Fi
   sekmesi çalışır, **"Çıkış" düğmesi görünmez**). Koyu ve açık temada (telefonun sistem temasını değiştirerek) okunaklılık, 360 px'te
   taşma/kesilme, dokunma kolaylığı, ağ listesinde uzun SSID, karekod düğmesi ve bağlan akışı (16.6 ile birlikte).
3. **Telefon tarayıcısı, LAN (`http://<pano IP>`):** anahtarı BİR KEZ girin -> sayfayı yenileyin, sekmeyi ve tarayıcıyı kapatıp
   yeniden açın: anahtar sorulmamalı, başlıkta "Çıkış" görünmeli. "Çıkış" -> anahtar sorulmalı; yeniden girince yine hatırlanmalı.
   Gizli sekmede anahtar yalnız o oturumda hatırlanır (sekme kapanınca silinir).
4. **Eski anahtar:** anahtarı Sistem sekmesinden (ya da uygulamadan) değiştirip eski anahtarı hatırlayan telefonda sayfayı açın:
   "Kayıtlı anahtar artık geçerli değil..." + anahtar kutusu çıkmalı; cihazda kilit (`423`) OLUŞMAMALI (tek hata).
5. Kontrol sekmesi: röle kartı anahtarı/darbe düğmesi, panjur AÇ/DURDUR/KAPAT düğmeleri, hareket sırasında turkuaz orb, dijital
   girişler; Kanal Ayarları (Çift 1-4, ek modül açık/kapalı), RS485 terminal, Sistem sekmesi.
6. Sayfa yükleme süresi (sayfa 125 KB; v1.1.0'dan +10 KB) ve genel röle/panjur denemesi.

## Birleşik imajın yapısı ve kaynağı

Adresler ve tarif v1.1.0 ile aynıdır (PlatformIO'nun gerçek yükleme düzeni: `FLASH_EXTRA_IMAGES`, `ESP32_APP_OFFSET`).

| Adres | Parça | Kaynak |
| --- | --- | --- |
| 0x0 | `bootloader.bin` (14032 bayt) | PlatformIO derlemesi (`bootloader_dio_80m.elf`) |
| 0x8000 | `partitions.bin` (3072 bayt) | `app3M_fat9M_16MB.csv`'den PlatformIO üretti |
| 0xE000 | `boot_app0.bin` (8192 bayt) | `framework-arduinoespressif32/tools/partitions/boot_app0.bin` |
| 0x10000 | `firmware.bin` (1185520 bayt) | PlatformIO derlemesi (uygulama) |

- Birleştirme komutu (esptool 4.11.0; v1.1.0'dakiyle aynı):

```text
esptool.py --chip esp32s3 merge_bin -o firmware_combined_0x0.bin --flash_mode dio --flash_freq 80m --flash_size 16MB \
  0x0 bootloader.bin 0x8000 partitions.bin 0xe000 boot_app0.bin 0x10000 firmware.bin
```

- Bölüm tablosu (değişmedi): nvs 0x9000/20 KB, otadata 0xE000/8 KB, app0 0x10000/3 MB, app1 0x310000/3 MB, ffat 0x610000/10112 KB,
  coredump 0xFF0000/64 KB. Flash parametreleri bootloader başlığında: **DIO, 80 MHz, 16 MB** (başlık `02 4F`).

## Doğrulama (donanımsız)

- **Tarif doğrulaması:** v1.1.0'ın kaynağı (değiştirilmemiş ağaç; kaynak parmak izi v1.1.0 notlarındakiyle aynı) bu makinede yeniden
  derlendi: uygulama imajı (`08e372be...`) v1.1.0 yayınıyla BAYT BAYT aynı çıktı, ELF özeti (`23eb38d5...`) v1.1.0 notlarında
  kayıtlı özetle aynı; aynı tarifle birleştirilen imaj da `firmware_combined_0x0.bin` v1.1.0 (`d1b5cb97...`) ile BAYT BAYT aynı.
  Yani araç zinciri ve birleştirme tarifi aynıdır.
- **Bölge eşitliği:** v1.1.1 birleşik imajının 0x0000-0xFFFF bölgesi (bootloader + bölüm tablosu + boot_app0 + boş NVS) v1.1.0
  ile bayt bayt aynıdır (bölge SHA-256: `9d1afa71aced81c6b5a475e4c987c235c4ad9606acf2e6113440efc31f0da3cd`); 0x10000 sonrası
  `app_0x10000_v1.1.1.bin` ile birebir aynıdır.
- **Uygulama imajı:** ilk bayt `0xE9`, 5 bölüt, çip kimliği ESP32-S3 (`0x0009`), XOR sağlaması ve SHA-256 eki geçerli; başlık
  alanları (mod/boyut/frekans/çip) v1.1.0 ile aynı. Bölüm tablosu MD5 girdisi geçerli; uygulama app0'ın %37,7'sini kullanır.
- **Fabrika aracı:** `inspect_firmware_file` yeni imaj için uyarısız geçti; `FACTORYINIT` imzası bulundu (USB-seri provizyon var).
- **Dizgi taraması (ikili):** `ahbu_key`, `localStorage`, `btnLogout`, `Neon Glass` imajda var; `FACTORYINIT` ve `RESETKEY` hâlâ var;
  `1.1.1` var, `1.1.0` yok; dış kaynak (CDN/font/img/@import) yok.
- **Web sayfası (tarayıcısız statik denetim):** HTML ayrıştırıcıyla etiketler dengeli, tekrar eden `id` yok; `node --check` söz
  dizimi temiz; v1.1.0'daki hiçbir `id`/sınıf/`data-*`/`querySelector` adı kaybolmadı (yalnız `btnLogout` eklendi); giriş/depo/AP
  akışları için 22 mantık testi (sahte DOM + depolama + cihaz modeli) geçti; CSS denetimi temiz (yasak/yeni özellik yok:
  `color-mix`, `:has`, `inset`, container query, `clamp/min/max` kullanılmadı); kontrast tablosu 232 çiftte 0 başarısız.
- **Birim testleri:** `pio test -e native` bu makinede çalıştırılamaz (C++ derleyicisi `gcc` yok; 8/8 `ERRORED`, değişiklikten önce
  ve sonra aynı). Bu testler `WiFiManager.h`/`WebPortalPage.h` içermez.

## Derleme bilgisi

- Derleme tarihi: 2026-10-04 (yerel saat 00:42, UTC+03). `FW_VERSION` = `1.1.1` (`WiFiManager.h` varsayılanı; imajda `fw` = 1.1.1).
- Araçlar (v1.1.0 ile aynı): PlatformIO Core 6.2.0; platform espressif32 7.1.3; framework-arduinoespressif32 4.20017.260907
  (Arduino-ESP32 2.0.17, ESP-IDF v4.4.7); toolchain-xtensa-esp32s3 gcc 8.4.0 (esp-2021r2-patch5); esptool 4.11.0; Python 3.11.9.
- Kütüphaneler: ArduinoJson 6.21.6, PubSubClient 2.8.0, NTPClient 3.2.1.
- Derleme: `pio run -e esp32-s3-waveshare` (temiz dizin). RAM %17,0 (55616 / 327680 bayt); Flash %37,7 (1185161 / 3145728 bayt,
  3 MB uygulama bölümü). Derleyici uyarısı: 0. İki bağımsız temiz derleme aynı SHA-256'yı verdi.
- ELF SHA-256 (uygulamaya gömülü): `bc44d5dd16f1c43c8effa170c698491ea85906c19cc6a50343a15e38cf36050e`.
- Kaynak: git HEAD `ce8af65` + commit edilmemiş değişiklikler. Kaynak parmak izi (`platformio.ini` + `src/**`, 56 dosya,
  `sha256  yol` satırlarının SHA-256'sı): `ac26de7463705f82a43f99114d4be2bf759d959ee6e9101550e36fa9acd84011`.

## Eski imajlar

`v1.0.0` ve `v1.0.1` klasöründeki imajlar **KULLANILMAZ** (silinmedi; nedenleri o klasörlerdeki `KULLANILMAZ.txt`'de). `v1.1.0`
klasörü silinmedi (karşılaştırma/geri dönüş için; bootloader ve bölüm tablosu v1.1.1 ile aynı olduğundan v1.1.0 uygulama imajı
0x10000'a geri yazılabilir). Güncel imaj **v1.1.1**'dir (`version_info.json`).
