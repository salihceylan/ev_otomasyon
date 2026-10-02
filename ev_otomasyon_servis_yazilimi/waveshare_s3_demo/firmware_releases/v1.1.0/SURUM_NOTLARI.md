# AHBU Akıllı Ev - ESP32-S3 firmware v1.1.0 (sürüm notları)

> **DONANIMDA DOĞRULANMADI.** Bu imaj yalnızca dosya düzeyinde doğrulandı (başlık, bölüm tablosu, SHA-256 özetleri,
> dizgi taraması, fabrika aracının imaj doğrulayıcısı, birim testleri). Hiçbir karta yazılıp çalıştırılmadı.
> Toplu üretimden önce TEK bir test kartında şunları deneyin: Flash, FACTORYINIT provizyonu, Wi-Fi servis akışı,
> röle ve panjur denemesi.

## Dosyalar

| Dosya | Boyut (bayt) | Amaç |
| --- | --- | --- |
| `firmware_combined_0x0.bin` | 1240752 | **Karta yazılacak ana imaj** (0x0 adresine). Bootloader + bölüm tablosu + boot_app0 + uygulama birleşik. |
| `app_0x10000_v1.1.0.bin` | 1175216 | Yalnızca uygulama (yedek; v1.1.0'da OTA alıcısı YOKTUR). Gerekirse esptool ile 0x10000'a yazılır; **0x0'a yazmayın**. |
| `SHA256SUMS.txt` | - | `sha256sum -c SHA256SUMS.txt` ile doğrulayın. |

SHA-256 (ana imaj): `d1b5cb97a84b746b48282ad5ff37a04e18e9207dfe2969334aff617d9777ebd6`
SHA-256 (yalnız uygulama): `08e372be0b6ee9f461103d2e48f3273e49b6c05f391a85b4bd0115c6e28339cf`

## Bu sürümde neler var (v1.0.x'te YOK)

- USB-seri fabrika provizyonu: `FACTORYINIT <local_key> <ap_pass>` (yalnız provizyonsuz kartta) ve `RESETKEY`
  (fiziksel erişimle yerel anahtarı siler). Bkz. `docs/CONTRACTS.md` 3c.
- Cihaza özel WPA2 kurulum/kurtarma AP parolası (`ap_pass`, kartın NVS'inde).
- AP kaynaklı, anahtarsız Wi-Fi servis akışı (`docs/CONTRACTS.md` 3d) ve yeni gömülü tarayıcı arayüzü.
- Panjur / röle emniyet düzeltmeleri.
- TLS sertifika doğrulaması (ISRG kökleri); `setInsecure()` kullanılmaz.
- `millis()` taşma düzeltmeleri (24,86 / 49,7 gün).
- Demo Wi-Fi/MQTT/seri yolları derlemeden çıkarıldı; imajda sabit SSID, parola veya bulut kimliği yoktur.

## Nasıl flash'lanır

Fabrika aracı (`ev_otomasyon_sistemi.py`): "Bizim Geliştirdiğimiz Yazılım" seçili iken dosya yolu
`firmware_releases/v1.1.0/firmware_combined_0x0.bin` olarak gelir (`version_info.json` bunu gösterir) -> kartı USB ile
bağlayın -> **FİRMWARE'İ KARTA YÜKLE (FLASH)**. Kart AYNI araç oturumunda sunucu envanterine
kaydedildiyse (SUNUCU ENVANTERİNE KAYDET) flash bitince USB-seri `FACTORYINIT` provizyonu otomatik başlar; USB kabloyu
çıkarmayın. Kart önceki bir oturumda kaydedildiyse otomatik başlamaz (yerel anahtar sunucudan yalnızca bir kez gelir ve
bellekte tutulur): kartı yeniden kaydedin/etiketi yeniden üretin (rehber §E).

> Not: v1.1.0 bootloader'ı v1.0.1'inkinden farklıdır (PlatformIO/IDF 4.4.7 bootloader'ı; v1.0.0 ile aynı). İlk test
> kartında açılış (seri çıktı) DOĞRULANMALI; donanımda denenmedi.

Elle (aracın kullandığı komutun aynısı):

```text
esptool --chip esp32s3 --port COMx --baud 460800 write_flash 0x0 firmware_combined_0x0.bin
```

Not: imaj 0x0'dan itibaren NVS alanını (0x9000-0xDFFF) da kapsar; yazma sonrası kart provizyonsuzdur (FACTORYINIT gerekir).

## Birleşik imajın yapısı ve kaynağı

Adresler elle yazılmadı; PlatformIO'nun gerçek yükleme düzeninden (`pio run -t envdump`: `FLASH_EXTRA_IMAGES`,
`ESP32_APP_OFFSET`) ve v1.0.0/v1.0.1 imajlarının yapısından türetildi.

| Adres | Parça | Kaynak |
| --- | --- | --- |
| 0x0 | `bootloader.bin` (14032 bayt) | PlatformIO derlemesi (`bootloader_dio_80m.elf`) |
| 0x8000 | `partitions.bin` (3072 bayt) | `app3M_fat9M_16MB.csv`'den PlatformIO üretti |
| 0xE000 | `boot_app0.bin` (8192 bayt) | `framework-arduinoespressif32/tools/partitions/boot_app0.bin` |
| 0x10000 | `firmware.bin` (1175216 bayt) | PlatformIO derlemesi (uygulama) |

- Bölüm tablosu: nvs 0x9000/20 KB, otadata 0xE000/8 KB, app0 0x10000/3 MB, app1 0x310000/3 MB, ffat 0x610000/10112 KB,
  coredump 0xFF0000/64 KB.
- Flash parametreleri bootloader başlığına işlendi: **DIO, 80 MHz, 16 MB** (başlık `02 4F`; v1.0.0 ve v1.0.1 ile aynı).
  Araç `write_flash 0x0`'ı ek parametresiz çalıştırır ve esptool 4.11 başlığı olduğu gibi (keep) yazar.
- Birleştirme komutu (esptool 4.11.0; başlık değişince bootloader SHA-256 özetini yeniden hesaplar):

```text
esptool.py --chip esp32s3 merge_bin -o firmware_combined_0x0.bin --flash_mode dio --flash_freq 80m --flash_size 16MB \
  0x0 bootloader.bin 0x8000 partitions.bin 0xe000 boot_app0.bin 0x10000 firmware.bin
```

- v1.0.0/v1.0.1 imajlarından farkı: 0xE000'de `boot_app0.bin` vardır (otadata başlangıçta ota_0'ı seçer; eski imajlarda
  orası 0xFF/boştu). Bootloader PlatformIO'nundur (v1.0.0 ile bayt bayt aynıdır; v1.0.1 satıcı bootloader'ını kullanıyordu).
- Uygulama imajının kendi başlığında flash boyutu 8 MB yazar (PlatformIO `upload.flash_size` kart tanımından gelir);
  v1.0.0/v1.0.1 ile aynı davranıştır.

## Derleme bilgisi

- Derleme tarihi: 2026-10-02 (yerel saat 02:03, UTC+03). `FW_VERSION` = `1.1.0` (`WiFiManager.h` varsayılanı; imajda `fw` = 1.1.0).
- Araçlar: PlatformIO Core 6.2.0; platform espressif32 7.1.3; framework-arduinoespressif32 4.20017.260907 (Arduino-ESP32 2.0.17,
  ESP-IDF v4.4.7); toolchain-xtensa-esp32s3 gcc 8.4.0 (esp-2021r2-patch5); esptool 4.11.0; Python 3.11.9.
- Kütüphaneler: ArduinoJson 6.21.6, PubSubClient 2.8.0, NTPClient 3.2.1.
- Derleme: `pio run -e esp32-s3-waveshare` (temiz dizin). RAM %17,0 (55616 / 327680 bayt); Flash %37,3
  (1174857 / 3145728 bayt, 3 MB uygulama bölümü). Derleyici uyarısı: 0. İki bağımsız temiz derleme aynı SHA-256'yı verdi.
- ELF SHA-256 (uygulamaya gömülü): `23eb38d5b8a35448c4116a8b5248014e7f140660c99c71eb6e26362efd5eb466`.
- Kaynak: git HEAD `8cf17c0` + commit edilmemiş değişiklikler. Kaynak parmak izi (`platformio.ini` + `src/**`, 56 dosya,
  `sha256  yol` satırlarının SHA-256'sı): `431a15c2e16d87f841f1bd7f7b1feae6672bd56786dd4c345fe2179e2062388e`.

## Eski imajlar

`v1.0.0` ve `v1.0.1` klasöründeki imajlar **KULLANILMAZ** (silinmedi; nedenleri o klasörlerdeki `KULLANILMAZ.txt`'de).
Bu imajlarla yüklenen kart yeni sistemle çalışmaz: `FACTORYINIT` yoktur, kart USB üzerinden provizyonlanamaz.
