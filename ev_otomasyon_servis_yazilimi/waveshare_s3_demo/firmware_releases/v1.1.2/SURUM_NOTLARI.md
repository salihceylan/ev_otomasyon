# AHBU Akıllı Ev - ESP32-S3 firmware v1.1.2 (sürüm notları)

> **DONANIMDA DOĞRULANMADI.** Bu imaj yalnızca dosya düzeyinde doğrulandı (başlık, bölüm tablosu, SHA-256 özetleri, dizgi
> taraması, fabrika aracının imaj doğrulayıcısı) ve değişen kod donanımsız testlerle sınandı (QA simülatörü, fabrika aracı,
> gerçek `ConfigManager.cpp`'nin PC'de derlenmiş hâli). Hiçbir karta yazılıp çalıştırılmadı. Toplu üretimden önce TEK bir test
> kartında şunları deneyin: Flash, **USB-seri `FACTORYINIT` provizyonu**, **`RESETKEY` + yeniden `FACTORYINIT`**, Wi-Fi yedek
> provizyonu (`factory/init`), anahtar değiştirme (`rekey`), web sayfası, röle ve panjur denemesi (aşağıdaki liste).

## Dosyalar

| Dosya | Boyut (bayt) | Amaç |
| --- | --- | --- |
| `firmware_combined_0x0.bin` | 1251888 | **Karta yazılacak ana imaj** (0x0 adresine). Bootloader + bölüm tablosu + boot_app0 + uygulama birleşik. |
| `app_0x10000_v1.1.2.bin` | 1186352 | Yalnızca uygulama (yedek; v1.1.2'de OTA alıcısı YOKTUR). Gerekirse esptool ile 0x10000'a yazılır; **0x0'a yazmayın**. |
| `SHA256SUMS.txt` | - | `sha256sum -c SHA256SUMS.txt` ile doğrulayın. |

SHA-256 (ana imaj): `fc28f46ab0698c6bb6e3f1fd5ed83b82aaf00c475c5b5340899bd0d39c47551b`
SHA-256 (yalnız uygulama): `636ee5c4f39151d36af4de663ae1561b7adb3effae10a81563b2644846625b3f`

## v1.1.1'den farklar (bu sürümde)

> **Birleşik sürüm.** v1.1.2 iki ayrı çalışmanın TEK imajıdır: (1) provizyon yolu düzeltmeleri (aşağıdaki SERVIS-03/04/06
> maddeleri) ve (2) gömülü web sayfası metin düzeltmeleri. Daha önce ayrı ayrı üretilen iki "v1.1.2" adayı (SHA `9941…` ve
> `8a86…`) KULLANILMAZ ve hiçbir karta yazılmadı; geçerli imaj bu notlardaki SHA-256'lara sahip olandır.

- **Web sayfası metinleri (`WebPortalPage.h`; görünüm, JS mantığı, id/sınıf adları değişmedi):**
  - Kurulum modu (AP) bilgi kutusu: "... Diğer ayarlar için cihaz anahtarını girin (anahtar etikette ve uygulamada gösterilmez;
    kurulum sırasında fabrika/servis aracı verir)."
  - Anahtar giriş kutusu ipucu: "Anahtar etikette ve uygulamada gösterilmez; kurulum sırasında fabrika/servis aracı verir.
    Anahtarınız yoksa servis yetkilisine başvurun."
  - Provizyon formuna yeni uyarı: "**Sunucuya kayıtlı (etiketli) panolarda bu formu kullanmayın:** kurulumu fabrika aracı (USB)
    ya da uygulamanın kurulum sihirbazı yapar; burada belirlenen anahtarı sunucu bilmez."

Yalnızca **provizyon yolu** (yerel anahtarın ilk yazımı, değiştirilmesi, seri `RESETKEY` metni) ve sürüm numarası değişti.
Wi-Fi/MQTT/panjur/röle emniyet davranışı, AP kaynaklı anahtarsız Wi-Fi servis akışı (`docs/CONTRACTS.md` 3d) ve gömülü web
arayüzünün görünümü **aynıdır**; bootloader, bölüm tablosu ve boot_app0 v1.1.1 ile **bayt bayt aynıdır** (birleşik imajın
0x0000-0xFFFF bölgesi eşit).

- **NVS yazma hatası artık `503 {"error":"storage"}` (SERVIS-03):** `POST /api/factory/init` ve `POST /api/auth/rekey`'de biçim
  denetimi geçip yerel anahtar/AP parolası kalıcı belleğe (NVS) yazılamazsa cihaz `503 {"error":"storage"}` döner
  (`docs/CONTRACTS.md` 3b). Önceden `factory/init` bu durumda `400 invalid_key` / `400 invalid_ap_pass` dönüyordu ve fabrika
  aracı yanlış ipucu veriyordu ("araç ile firmware sürümlerinin uyumlu olduğundan emin olun"); `rekey` ise sözleşmede olmayan
  `500 storage_error` dönüyordu. Biçim hataları **bugünkü 400 kodlarını korur** (`invalid_key`, `invalid_ap_pass`). Fabrika
  aracının (değişmedi) mevcut `503 storage` dalı artık gerçekten çalışır: "Cihaz anahtarı kalıcı belleğe yazamadı (storage)" +
  "Kartı yeniden başlatıp tekrar deneyin; sürerse 'Hafızayı Sil (Erase Flash)' ile firmware'i yeniden yükleyin." Gömülü web
  sayfası `storage` kodunu `storage_error` ile aynı mevcut metinle gösterir ("Ayarlar cihaz hafızasına yazılamadı."; yeni metin
  yok). Diğer uçların `500 storage_error` yanıtı (ayar kaydı, `wifi/disconnect`, `rs485/baud`, `system/reset`) değişmedi.
- **Atomik ilk provizyon, seri ve HTTP yolu arasında yarış yok (SERVIS-04):** yeni `ConfigManager::provisionIfEmpty(key, pass)`:
  TEK `ConfigLock` altında "yerel anahtar boş mu" denetimi + biçim denetimi + **önce `ap_pass`, sonra `local_key`** yazımı;
  `local_key` yazılamazsa `ap_pass` önceki değerine geri alınır (yarım provizyon kalmaz; cihaz provizyonsuz kalır, yeniden
  denenebilir). Seri `FACTORYINIT` ve HTTP `POST /api/factory/init` AYNI yöntemi kullanır. HTTP işleyicisindeki baştaki denetim
  yalnız hızlı ret olarak kaldı; kesin denetim gövde ayrıştırıldıktan sonra yazmayla aynı kilit altında yapılır: gövde
  ayrıştırılırken seri `FACTORYINIT` anahtarı yazarsa HTTP isteği `403 {"error":"already_provisioned"}` alır ve yeni anahtar
  **ezilmez** (önceden ezebiliyordu; araç kaydı "doğrulandı" sayarken karttaki anahtar başkasının olabilirdi).
  Seri yanıtlar değişmedi: `OK factory_init` | `ERR already_provisioned` | `ERR invalid_local_key` | `ERR invalid_ap_pass` |
  `ERR persist_failed`. HTTP yolunda iki küçük davranış farkı: yazım sırası artık seri yolla aynı (önce `ap_pass`); karakter
  aralığı dışı (`0x20-0x7E` dışı) `ap_pass` artık hiçbir şey yazılmadan `400 invalid_ap_pass` alır (önceden anahtar önce yazılıp
  sonra siliniyordu).
- **`RESETKEY` seri çıktısı (SERVIS-06):** `[CLI-SONUC] Yerel anahtar SILINDI. Cihaz artik PROVIZYONSUZ (FACTORYINIT <local_key>
  <ap_pass> ya da /api/factory/init). AP gerekirse: AP ON` (silinemezse `SILINEMEDI`). Önceden "yalnizca /api/factory/init"
  diyerek tercih edilen USB yolunu yok sayıyordu. Fabrika aracının aradığı `Yerel anahtar SILINDI|SILINEMEDI` alt dizgisi
  **aynen** duruyor (araç değişmedi; araç testleri artık bu satırı doğrudan `main.cpp`'den okuyup denetliyor).
- **Sürüm:** `FW_VERSION` 1.1.1 -> **1.1.2** (`WiFiManager.h`; durum JSON'unda `fw`, `GET /api/status`, MQTT durumu).
- **Boyut:** uygulama imajı +832 bayt (1185520 -> 1186352; web metinleri dahil). Aşağıdaki ayrıntı yalnız provizyon değişikliğine aittir: uygulama imajı +544 bayt (1185520 -> 1186064); gömülü sayfa 125325 -> 125380 bayt (+55, NUL dahil; yalnız `storage`
  hata metni eşlemesi); RAM aynı (55616 bayt).
- **İkili fark yalnız bu değişikliklerde (sembol karşılaştırması):** v1.1.1 kaynağının aynı araç zinciriyle yeniden derlenmiş
  ELF'ine göre: yeni `ConfigManager::provisionIfEmpty` (206 bayt) ve `ConfigManager::restoreApPass` (83 bayt); büyüyen
  `WebPortal::handleApiFactoryInit` (+12), `handleCliLine` (+20), `INDEX_HTML` (+55); aynı derleme birimlerindeki kod yerleşimi
  kayması `ConfigManager::save` (+2) ve bir ArduinoJson şablon örneği (+2). Diğer 7600+ sembol aynı boyutta.

## Güvenlik notu

- Seri `FACTORYINIT` sırasında açık kurulum AP'si hâlâ yayındadır (WPA2'ye geçiş `OK`'tan ~1,5 sn sonra). v1.1.2'de bu
  pencerede menzildeki birinin `factory/init` isteği fabrikada yazılan anahtarı EZEMEZ (403). Provizyonsuz kart ise hâlâ
  herkese açıktır (`docs/CONTRACTS.md` 3b "Risk"): **flash sonrası HEMEN provizyon** kuralı aynen geçerli.

## Nasıl flash'lanır

Fabrika aracı (`ev_otomasyon_sistemi.py`): "Bizim Geliştirdiğimiz Yazılım" seçili iken dosya yolu
`firmware_releases/v1.1.2/firmware_combined_0x0.bin` olarak gelir (`version_info.json` bunu gösterir) -> kartı USB ile
bağlayın -> **FİRMWARE'İ KARTA YÜKLE (FLASH)**. Kart AYNI araç oturumunda sunucu envanterine kaydedildiyse (SUNUCU
ENVANTERİNE KAYDET) flash bitince USB-seri `FACTORYINIT` provizyonu otomatik başlar; USB kabloyu çıkarmayın. Kart önceki bir
oturumda kaydedildiyse otomatik başlamaz (yerel anahtar sunucudan yalnızca bir kez gelir ve bellekte tutulur): kartı yeniden
kaydedin/etiketi yeniden üretin (rehber §E).

Elle (aracın kullandığı komutun aynısı):

```text
esptool --chip esp32s3 --port COMx --baud 460800 write_flash 0x0 firmware_combined_0x0.bin
```

Not: imaj 0x0'dan itibaren NVS alanını (0x9000-0xDFFF) da kapsar; yazma sonrası kart provizyonsuzdur (FACTORYINIT gerekir).

Sahadaki, ZATEN provizyonlu bir v1.1.0/v1.1.1 kartın yalnızca uygulamasını yenilemek ve anahtar/Wi-Fi/kimlik kayıtlarını
KORUMAK için (bölüm tablosu ve bootloader aynı olduğundan; **donanımda denenmedi**) yalnız uygulama imajı 0x10000'a yazılır:

```text
esptool --chip esp32s3 --port COMx --baud 460800 write_flash 0x10000 app_0x10000_v1.1.2.bin
```

## İlk kartta denenecekler

1. Flash (ana imaj) -> açılış seri çıktısı (bootloader v1.1.1 ile aynı) -> fabrika aracıyla USB-seri `FACTORYINIT` provizyonu
   (`OK factory_init`) -> `fw` değeri **1.1.2** olmalı (Sistem sekmesi "Yazılım Sürümü" ve `GET /api/status`).
2. Seri terminalde (115200 baud) `STATUS` -> `Yerel anahtar (local_key): tanimli`; `RESETKEY` -> yanıtta yeni metin
   (`... PROVIZYONSUZ (FACTORYINIT <local_key> <ap_pass> ya da /api/factory/init) ...`). Provizyonlu karta araçla yeniden USB
   provizyonu -> "Kartta Eski Anahtar Var" sorusuna Evet (araç `RESETKEY` gönderir): araç sıfırlamayı tanımalı ve `FACTORYINIT`
   yeniden `OK` olmalı.
3. Provizyonsuz kartta yedek yol: bilgisayarı açık kurulum ağına (`AHBU-XXXXXX`) bağlayıp aracın "Wi-Fi ile Provizyonla
   (güvensiz yedek yol)" düğmesi -> başarılı; kart provizyonluyken aynı istek "Cihaz zaten provizyonlu" hatası vermeli.
4. Anahtar değiştirme: web sayfası Sistem sekmesi "Anahtarı Değiştir" (ya da uygulama) -> başarılı; eski anahtar artık `401`.
5. v1.1.1 notlarındaki web sayfası (telefon, koyu/açık tema, "Çıkış"), röle/panjur ve dijital giriş denemeleri (değişmedi; kısa
   genel deneme yeterli).

NVS yazma hatası (`503 storage` / `ERR persist_failed`) ve seri + HTTP eşzamanlı provizyon yarışı gerçek kartta kolayca
üretilemez; bu yollar aşağıdaki donanımsız testlerle doğrulandı.

## Birleşik imajın yapısı ve kaynağı

Adresler ve tarif v1.1.1 ile aynıdır (PlatformIO'nun gerçek yükleme düzeni: `FLASH_EXTRA_IMAGES`, `ESP32_APP_OFFSET`).

| Adres | Parça | Kaynak |
| --- | --- | --- |
| 0x0 | `bootloader.bin` (14032 bayt) | PlatformIO derlemesi (`bootloader_dio_80m.elf`) |
| 0x8000 | `partitions.bin` (3072 bayt) | `app3M_fat9M_16MB.csv`'den PlatformIO üretti |
| 0xE000 | `boot_app0.bin` (8192 bayt) | `framework-arduinoespressif32/tools/partitions/boot_app0.bin` |
| 0x10000 | `firmware.bin` (1186352 bayt) | PlatformIO derlemesi (uygulama) |

- Birleştirme komutu (esptool 4.11.0; v1.1.1'dekiyle aynı):

```text
esptool.py --chip esp32s3 merge_bin -o firmware_combined_0x0.bin --flash_mode dio --flash_freq 80m --flash_size 16MB \
  0x0 bootloader.bin 0x8000 partitions.bin 0xe000 boot_app0.bin 0x10000 firmware.bin
```

- Bölüm tablosu (değişmedi): nvs 0x9000/20 KB, otadata 0xE000/8 KB, app0 0x10000/3 MB, app1 0x310000/3 MB, ffat 0x610000/10112 KB,
  coredump 0xFF0000/64 KB. Flash parametreleri bootloader başlığında: **DIO, 80 MHz, 16 MB** (başlık `02 4F`).

## Doğrulama (donanımsız)

- **Tarif doğrulaması:** değiştirilmemiş v1.1.1 kaynağı (git `daffee9`; satır sonu normalleştirilmiş kaynak parmak izi v1.1.1
  çalışma kopyasınınkiyle aynı, aşağıda) bu makinede aynı araç zinciriyle yeniden derlendi: uygulama imajı yayınlanan
  `app_0x10000_v1.1.1.bin` ile yalnız gömülü ELF özeti (`esp_app_desc_t.app_elf_sha256`, 0xB0-0xCF) ve imaj sonundaki sağlama +
  SHA-256 eki (son 33 bayt) dışında BAYT BAYT aynı (1185520 baytın 64'ü farklı; fark, derleme dizininin hata ayıklama
  bilgisine girmesinden). Yayınlanan v1.1.1 uygulaması bu derlemenin bootloader/bölüm tablosu + boot_app0 ile aynı komutla
  birleştirilince v1.1.1 birleşik imajı (`a9f6a291...`) BAYT BAYT elde edildi. Yani araç zinciri ve birleştirme tarifi aynıdır.
- **Bölge eşitliği:** v1.1.2 birleşik imajının 0x0000-0xFFFF bölgesi (bootloader + bölüm tablosu + boot_app0 + boş NVS) v1.1.1
  ile bayt bayt aynıdır (bölge SHA-256: `9d1afa71aced81c6b5a475e4c987c235c4ad9606acf2e6113440efc31f0da3cd`; üç parça ayrı ayrı
  da aynı); 0x10000 sonrası `app_0x10000_v1.1.2.bin` ile birebir aynıdır.
- **Uygulama imajı:** `esptool image_info`: ilk bayt `0xE9`, 5 bölüt, çip kimliği ESP32-S3 (`0x0009`), giriş noktası
  `0x4037769c` (v1.1.1 ile aynı), XOR sağlaması ve SHA-256 eki geçerli; başlığın ilk 24 baytı v1.1.1 ile aynı. Gömülü ELF
  özeti, derlemenin `firmware.elf` dosyasının SHA-256'sıyla aynı. Uygulama app0'ın %37,7'sini kullanır.
- **Fabrika aracı:** `version_info.json` -> v1.1.2; `inspect_firmware_file` yeni imaj için uyarısız geçti; `FACTORYINIT` imzası
  bulundu (USB-seri provizyon var).
- **Dizgi taraması (ikili):** yeni `RESETKEY` metni (`PROVIZYONSUZ (FACTORYINIT <local_key> <ap_pass> ya da /api/factory/init)`)
  var, eski `yalnizca /api/factory/init` yok; `FACTORYINIT`, `RESETKEY`, `OK factory_init`, `ERR persist_failed` var; `1.1.2`
  var, `1.1.1` ve `1.1.0` yok; `ahbu_key`, `Neon Glass` var; dış kaynak yok (yalnız `http://192.168.4.1` ve `http://<pano ...`
  metinleri).
- **Testler:**
  - QA simülatörü (`tools/qa_stack`, `npm test`): 430/430 geçti. Yeni: NVS yazma arızası enjeksiyonu (`/__sim/hw-fail`
    `nvs_fail_keys`) ile `factory/init` ve `rekey` -> `503 storage`; gövde ayrıştırılırken seri `FACTORYINIT` -> `403`, anahtar
    ezilmez; `provisionIfEmpty` portu (sıra, geri alma, biçim); sürüm eşitliği; firmware kaynak parmak izi (`fwcheck`); web
    sayfası hata kodu eşlemesi. Kırmızı kanıt: değişiklikten önce aynı testler `400 invalid_key`, `500 storage_error` ve
    `200` (seri anahtar ezildi) ile düştü.
  - Fabrika aracı (`python -m unittest discover -s tests`): 358/358 geçti. Yeni: `RESETKEY` satırı `main.cpp`'den okunup aracın
    ayrıştırıcısıyla ve sahte firmware ile eşleştiriliyor; firmware'in tüm `FACTORYINIT` yanıtları aracın tanıdığı kodlar.
  - Uçtan uca (yalnız 127.0.0.1): fabrika aracının `DeviceClient`'i <-> simülatör, NVS arızası: `ProvisionError` kodu `storage`
    ve "Erase Flash" ipucu; arıza kalkınca `factory_init` başarılı, `verify` doğru.
  - Gerçek `src/ConfigManager.cpp` PC'de MSVC ile (sahte `Preferences`/FreeRTOS, gerçek iş parçacıkları): 7 test, 53 denetim
    geçti (sıra `ap_pw` -> `lk`; geri alma; biçim; NVS açılamaması; seri kilidi tutarken gelen HTTP provizyonu bekler ve
    `PROVISION_ALREADY` alır). Aynı yarış testi v1.1.1'in HTTP sırasıyla (`setLocalKey` + `setApPass`) koşturulunca seri
    anahtar ezildi (4 denetim düştü).
  - Firmware Unity testleri (`test/test_*`): `pio test -e native` bu makinede çalışmaz (C++ derleyicisi `gcc` yok; 8/8
    `ERRORED`, v1.1.1'deki gibi). Aynı testler MSVC ile derlenip çalıştırıldı: 8 paket, 179 test, 0 hata (bu testler değişen
    dosyaları kapsamaz).

## Derleme bilgisi

- Derleme tarihi: 2026-10-04 (yerel saat 12:04, UTC+03). `FW_VERSION` = `1.1.2` (`WiFiManager.h` varsayılanı; imajda `fw` = 1.1.2).
- Araçlar (v1.1.1 ile aynı): PlatformIO Core 6.2.0; platform espressif32 7.1.3; framework-arduinoespressif32 4.20017.260907
  (Arduino-ESP32 2.0.17, ESP-IDF v4.4.7); toolchain-xtensa-esp32s3 gcc 8.4.0 (esp-2021r2-patch5); esptool 4.11.0; Python 3.11.9.
  PlatformIO çekirdek dizini v1.1.1'deki gibi `G:\.platformio`.
- Kütüphaneler: ArduinoJson 6.21.6, PubSubClient 2.8.0, NTPClient 3.2.1 (v1.1.1 derlemesindeki kopyalar; indirme yapılmadı).
- Derleme: `pio run -e esp32-s3-waveshare` (temiz dizin). RAM %17,0 (55616 / 327680 bayt); Flash %37,7 (1185981 / 3145728 bayt,
  3 MB uygulama bölümü). Derleyici uyarısı: 0. İki bağımsız temiz derleme (`.pio/build` silinerek, aynı dizin) aynı SHA-256'yı
  verdi (uygulama ve ELF).
- Uygulama imajı derleme DİZİNİNE bağlıdır: aynı kaynak başka dizinde derlenirse yalnız gömülü ELF özeti (0xB0-0xCF) ile
  sağlama + SHA-256 eki (son 33 bayt) değişir (yukarıdaki tarif doğrulaması). Bu derlemede proje dizini, Windows yol uzunluğu
  sınırı (LongPathsEnabled=0) nedeniyle 8.3 kısa yolla verildi.
- ELF SHA-256 (uygulamaya gömülü): `4490e7f2216e76adaa136c79bbf69e208a5b3f60f40ad9a5dc6e529a803bb11b`.
- Kaynak: git `daffee9` + SERVIS-03/04/06 değişiklikleri (akis-fx-f1 dalı) + web sayfası metin düzeltmeleri (birleşik derleme 2026-10-04 ~14:30, `subst P:` kısa yolu; tek temiz derleme, uyarı 0). Kaynak parmak izi (`platformio.ini` + `src/**`, 56
  dosya, git'teki LF biçimiyle, `sha256  yol` satırlarının SHA-256'sı):
  `18dd00c846c0c5ca53de2f4e1bc996955e0fd3dbe5910653686fe09cb1520b50`. Not: v1.1.1 notlarındaki parmak izi
  (`ac26de74...`) ana ağacın çalışma kopyası üzerinden alınmıştı (bazı dosyalar CRLF); aynı kaynağın LF parmak izi
  `988f9a3cdd6b4c4f8f74e1d71568c68dafaebac642c695d876044bc2ed5955dc` ve git `daffee9` ile aynıdır.

## Eski imajlar

`v1.0.0` ve `v1.0.1` klasöründeki imajlar **KULLANILMAZ** (silinmedi; nedenleri o klasörlerdeki `KULLANILMAZ.txt`'de). `v1.1.0`
ve `v1.1.1` klasörleri silinmedi (karşılaştırma/geri dönüş için; bootloader ve bölüm tablosu v1.1.2 ile aynı olduğundan eski
uygulama imajı 0x10000'a geri yazılabilir). Güncel imaj **v1.1.2**'dir (`version_info.json`).
