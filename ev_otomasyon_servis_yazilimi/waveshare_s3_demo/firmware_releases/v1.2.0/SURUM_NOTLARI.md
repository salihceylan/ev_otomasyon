# AHBU Akıllı Ev - ESP32-S3 firmware v1.2.0 (sürüm notları)

> **DONANIMDA DOĞRULANMADI.** Bu imaj hiçbir karta yazılmadı ve hiçbir kartta açılmadı. Dosya düzeyinde doğrulandı (başlık,
> bölüm tablosu, SHA-256 özetleri, 0x0000-0xFFFF bölgesinin v1.1.2 ile bayt bayt eşitliği, dizgi taraması, fabrika aracının imaj
> doğrulayıcısı) ve değişen kod donanımsız testlerle sınandı (firmware'in kendi Unity testleri MSVC ile, QA simülatörü, fabrika aracı).
> Gerçek su sensörü, selenoid/motorlu vana, TCA9554 çip sıfırlanması, RS485 ek modül ve NVS doluluğu bu sürümde **ölçülmedi**.
> Toplu üretimden ve sahaya çıkmadan önce aşağıdaki "İlk kartta denenecekler" listesinin tamamı tek bir test kartında yapılmalı.
> Dağıtım sırası: **sunucu (migration 033 + köprü) -> firmware -> uygulama** (tasarım §7.3 WP-R).

## Dosyalar

| Dosya | Boyut (bayt) | Amaç |
| --- | --- | --- |
| `firmware_combined_0x0.bin` | 1313568 | **Karta yazılacak ana imaj** (0x0 adresine). Bootloader + bölüm tablosu + boot_app0 + uygulama birleşik. |
| `app_0x10000_v1.2.0.bin` | 1248032 | Yalnızca uygulama (yedek; v1.2.0'da OTA alıcısı YOKTUR). Gerekirse esptool ile 0x10000'a yazılır; **0x0'a yazmayın**. |
| `SHA256SUMS.txt` | - | `sha256sum -c SHA256SUMS.txt` ile doğrulayın. |

SHA-256 (ana imaj): `dd39a3ef765ea50213ef8585f4a4f695673ef2f2f6f8e78793bb5eb2f7888374`
SHA-256 (yalnız uygulama): `165ccc0dc304cb22d574ea06577b5dd670838f26a1a0c8f8569eb7fd1b00df39`

> **Yeniden üretildi (2026-10-07, sözleşme hizalaması).** İlk v1.2.0 paketinden (ana imaj `b7cf656e…`) farkı yalnız olay JSON'udur
> (CONTRACTS §2.6): `valve_fault`, `valve_fault_cleared`, `alarm_silenced` ve `alarm_cleared` olayları bölgenin alarm kimliğini `aid`
> alanıyla taşır (sunucu alarm satırını bununla bulur); `test_result` olayında `fb_ms` yalnız geri bildirimle ölçüldüyse yazılır
> (geri bildirimsiz bölgede alan yoktur, uygulama "gözle doğrulayın" der). Sürüm numarası değişmedi (v1.2.0 henüz hiçbir karta
> yazılmadı).

> **Yeniden üretildi (2026-10-07, inceleme turu / entegrasyon).** Sözleşme hizalaması paketinden (ana imaj `e691e574…`) farkları
> (ayrıntı: tasarım belgesi "İnceleme turu (entegrasyon)"):
> - Kilitli bölgeye yeni tehlike türü (ör. su alarmı sürerken gaz) artık **yeni `alarm_raised` olayı** üretir (yeni `aid`); önce
>   yalnız state'te görünüyordu, push gitmiyordu.
> - Vana arızası (FAULT) yeniden başlatmada FAULT olarak geri yüklenir; geri bildirimli vana KAPALI görülmeden ne arıza kalkar ne
>   bölge NORMAL'e döner. Çalışırken yapılandırma yaması (ör. bölge adı) eylemcilerin çalışma durumunu (konum, arıza zamanlayıcısı,
>   darbe, siren süre bütçesi, elle açık çıkış, kullanıcı susturması) korur; GAS_RESET ile açılmış gaz vanası yamada kapanmaz.
> - Kilitsiz bölgede de KAPALI komutlu enerjiyle-kapanan vanalar ve bütün enerjiyle-kapanan gaz vanaları planlı yeniden başlatma /
>   kapanış ve açılışta (Relay_Init) enerjili kalır: yeni NVS anahtarı `ahbu_latch/safe_msk` (16 B). Yapılandırma bozulursa
>   (cfg_corrupt) bu son geçerli maske güvenli kipte dayatılır (panjur/darbe rölesine dokunmaz).
> - Kapalı komutlu iki röleli vanaya açılışta bir KAPAT darbesi daha verilir (yarıda kalmış darbe; gaz vanası her açılışta kapalı).
> - Test sonunda vana, kullanıcı test sırasında kapattıysa ya da açma izni yoksa (sensör arızalı/ıslak) geri AÇILMAZ.
> - LAN'dan gevşetme yasağına eklendi: mevcut sensör/rol satırını GAS_RESET'e çevirmek, GAS_RESET'in bölgesini değiştirmek,
>   yeni ex-proof fan satırı.
> - MQTT'de eylemci rölesine gelen `uid`'siz düz röle komutu yok sayılır (başka panonun lambası için gönderilen komut çalan
>   sireni susturmaz). Sunucu güvenlik destekli panoya düz röle komutunu `uid` ile gönderir.
> - Güvenlik yapılandırması yazımı: önce "ver" geçersiz işaretlenir, en son geçerli yazılır (yarıda kalan yazım açılışta
>   cfg_corrupt olur, karışık tablo kullanılmaz); başarısız yazımda eski yapılandırma geri yazılır; NVS boş girdi payı kilit kaydı
>   için ayrılır (yetmezse yazım `storage` ile reddedilir).

> **Yeniden üretildi (2026-10-07, inceleme turu 2).** İnceleme turu paketinden (ana imaj `bf2fd161…`) farkları (ayrıntı: tasarım
> belgesi "İnceleme turu 2"):
> - Açılış güvenli maskesindeki (`safe_msk`) ya da kilit maskesindeki röle, güvenlik tablosu boş olsa bile (cfg_corrupt güvenli kipi)
>   `/api/config` ve seri CLI'dan panjur/darbe rölesine çevrilemez (`409 cfg_invalid`, `act_relay_impulse`/`act_relay_shutter`).
>   Güvenli kipte açılışta ana yapılandırmayla uyuşmayan bitler (panjur/darbe, var olmayan röle) kalıcı maskeden de silinir:
>   Relay_Init darbe rölesini enerjilemez.
> - LAN'dan daha önce kullanılmış bir DI'ye yeni GAS_RESET eklenemez (sil + yeniden ekle yolu): yeni NVS anahtarı
>   `ahbu_latch/di_hist` (u64, fabrika sıfırlaması silmez). Hiç kullanılmamış girişe GAS_RESET (sihirbaz) serbest; seri CLI ve
>   bulut owner/servis yolu değişmedi.
> - NVS boş girdi payı, IDF 4.4'ün `free_entries`'e kattığı çöp toplama sayfasını (126 girdi) düşer; başarısız yazımdan sonra eski
>   yapılandırmanın geri yazımı pay denetimine takılmaz (açılışın gereksiz yere cfg_corrupt olması önlenir).

## v1.1.2'den farklar (bu sürümde)

Tasarım: `docs/superpowers/specs/2026-10-06-guvenlik-iklim-senaryo-mimarisi-design.md` (§2-§5, kararlar §7.2b, uygulama notları
"EKIP FW"). Sözleşme: `docs/CONTRACTS.md` §2.6. **Yapılandırılmamış panoda (güvenlik sensörü/eylemcisi yok: bugünkü bütün saha ve
fabrika varsayılanı) lamba/panjur davranışı bit bit v1.1.2 ile aynıdır** (eşdeğerlik testi: `tools/qa_stack/test/sim_safety_equivalence.test.js`).

- **Güvenlik katmanı (su baskını + vana; WP-F1/F2):** saf çekirdekler (`sensors/`, `actuators/`, `safety/`, `events/`) ve bağlayıcılar
  (`SafetyManager`, `SafetyStore`). Onaylı ıslaklıkta bölgedeki, sensör türünün akışkanına uyan vanalar aynı loopTask turunda kapanır,
  siren çalar, kart buzzer'ı alarm kipine girer; kilit NVS'e (`ahbu_latch`, fabrika sıfırlamasında silinmez) yazılır. Onay + kesintisiz
  kuruluk (`dry_hold`) sonrası kilit kalkar, **vana kapalı kalır** (açmak ayrı komut). Güvenli kip (`cfg_corrupt` / `latch_orphan` /
  `crash_loop`), iki röleli darbe vana, gaz vanası yalnız yerinde açılır, `Relay_Init`/`shutdownHandler`/`emergencyAllOff` kilitli vananın
  güvenli bitini korur.
- **Bağımsız emniyet: ValveGuard (WP-F3):** ShutterGuard görevine (Core 0, 50 ms) ek adım. Kapalı komutlu vanaların güvenli seviyeleri
  loopTask'tan tek yapı olarak (spinlock) yayınlanır; guard yerel 8 rölenin çıkış yazmacını **donanımdan** okur
  (`TCA_ReadOutputHw`): DEENERGIZE_TO_CLOSE vana açık kaldıysa `TCA_ClearBits`, ENERGIZE_TO_CLOSE vana enerjisiz kaldıysa (çip
  sıfırlanması) yeni `TCA_SetSafeBits` (panjur çifti bitlerini asla kurmaz). Ek modülde yalnız loop 1000 ms beslemezse, en çok 1 sn'de bir.
- **MQTT (WP-F4):** state **v:3** (v:2'nin katı üst kümesi; yapılandırılmamış panoda ek anahtarlar yalnız `caps`, `boot`, `bn`,
  `time_ok`, `epoch`); yapılandırılmışsa `cfg.safety{rev,crc}`, `sensors`, `actuators`, `safety` (adsız) ve eylemci rölelerinde `act`;
  `last_rej` (ret kodları: `zone_latched`, `actuator_relay`, `bad_cmd`, `busy`, `stale_ack`, `safe_mode`, ...). Yeni konu
  `ev/{t}/event` (retain yok, uygulama düzeyinde onay: `event_ack`, 5/10/20/40/60 sn yeniden deneme, aboneliğin ilk 1500 ms'sinde
  boşaltılmaz). Yeni komutlar `actuator`/`to`, `alarm_ack` (+`aid`), `alarm_test`, `safety_arm`/`climate_target`/`scene_run`
  (bu sürümde `unsupported`), `event_ack`; bunlarda **`uid` zorunlu**, başka panonun `uid`'si sessizce yok sayılır. sys:
  `cfg_get` -> `cfg_dump` (parçalı, her parça ≤ 3,5 KB), `cfg_patch` (tek öğe, `base_rev` iyimser eşzamanlılık; çakışmada `cfg_conflict`
  olayı), sys yük sınırı 1024 bayt (cmd 512'de kaldı).
- **Yerel HTTP + CLI (WP-F5):** `GET /api/status` ekleri (MQTT state ile aynı alanlar), yeni KEYED uçlar `POST /api/actuator`,
  `POST /api/alarm/ack`, `POST /api/alarm/test` (yanıt `{ok, id, rej?}`, en çok 1 sn), `GET /api/events?after=<eid>` (son 32 olay,
  onaylananlar dahil), `GET|POST /api/safety/config`. LAN'dan yalnız ekleme/sıkılaştırma: politika kapatma, eylemci/tehlike sensörü
  silme ve diğer gevşetmeler `403 local_loosen_forbidden` (karar 7.2b-7; gevşetme seri CLI ya da bulut). `/api/config` güvenlik
  yapılandırmasıyla çapraz doğrulanır (`409 cfg_invalid` / `409 zone_latched`). Kilitli alarm varken `/api/system/reboot` ve
  `/api/system/reset` `409 zone_latched` (geçmek için `?force=1`); ham RS485 ile eylemci kanalını açma ve toplu yazım `409
  actuator_relay`; güvenlik etkinken RS485 taraması `409 safety_active`. CLI: `SAFETY [STATUS]`, `SAFETY TEST <bölge>`,
  `SAFETY ACK [bölge] [FORCE]` (güvenli kipten yerel çıkış), `SAFETY POLICY ON|OFF`, `SAFETY DEL <aN|dN|bN>`, `REBOOT FORCE`;
  `RELAY ALL ON` eylemci rölelerini atlar; `EXTMOD`/`SET_DI` çapraz doğrulanır.
- **Sürüm:** `FW_VERSION` 1.1.2 -> **1.2.0** (`WiFiManager.h`).
- **Boyut:** uygulama imajı +60336 bayt (1186352 -> 1246688). RAM 55616 -> 67472 bayt (+11,6 KB; güvenlik yapılandırması RAM kopyası,
  çekirdekler, görünüm, olay tamponu + LAN olay halkası; olay yuvası `aid` için +16 B x 48). Flash %39,6.
- **Değişmeyenler:** bootloader, bölüm tablosu (NVS 0x5000 dahil) ve boot_app0 v1.1.2 ile **bayt bayt aynıdır** (aşağıda). Wi-Fi/AP
  provizyon akışı, `FACTORYINIT`/`RESETKEY`, gömülü web sayfası (`WebPortalPage.h`) değişmedi; web sayfasında güvenlik ekranı YOKTUR.

## Bilinen sınırlar ve açık işler

- **NVS bütçesi:** en kötü durum hesabı %105,6 (504 kullanılabilir girdi); ≤ %60 eşiği yalnız ad blob'u + NVS 0x8000 birlikte ile
  sağlanır (bölüm tablosu değişikliği seri yükleme ister; bu sürümde yapılmadı). Tipik kurulumda (birkaç sensör/eylemci) sorun
  beklenmez; kilit kaydı ilk açılışta yer ayırır, yazım hataları `nvs_fail` olayı üretir. Yapılandırma yazımı, kilit kaydı ve
  konum/güvenli maske güncellemeleri için 16 boş girdi bırakmazsa reddedilir (`nvsRoomForConfig`; girdi tahmini modeldir; çöp
  toplama sayfasının 126 girdisi `free_entries`'ten düşülür).
  Cihazda `nvs_get_stats` ölçülmeli (inceleme RV-3'ün sayısal kısmı doğrulanmadı).
- **Saat:** alarm `since` alanı yalnız SNTP senkronluysa yazılır (`time_ok`); RTC<->SNTP işi ayrı pakettir.
- **Somut köprü (Zigbee/Thread) sürücüsü yok** (yalnız `BridgeSensor` arayüzü).
- Gerçek `pio test -e native` gcc/clang olan bir makinede ayrıca koşulmalı (bu makinede MSVC ile koşuldu).

## Nasıl flash'lanır

Fabrika aracı (`ev_otomasyon_sistemi.py`): "Bizim Geliştirdiğimiz Yazılım" seçili iken dosya yolu
`firmware_releases/v1.2.0/firmware_combined_0x0.bin` olarak gelir (`version_info.json` bunu gösterir) -> kartı USB ile bağlayın ->
**FİRMWARE'İ KARTA YÜKLE (FLASH)**. Provizyon akışı v1.1.2 ile aynıdır (USB-seri `FACTORYINIT`).

Elle (aracın kullandığı komutun aynısı):

```text
esptool --chip esp32s3 --port COMx --baud 460800 write_flash 0x0 firmware_combined_0x0.bin
```

Not: imaj 0x0'dan itibaren NVS alanını (0x9000-0xDFFF) da kapsar; yazma sonrası kart provizyonsuzdur (FACTORYINIT gerekir) ve
güvenlik yapılandırması/kilit kaydı silinir.

Sahadaki provizyonlu bir v1.1.x kartın yalnız uygulamasını yenilemek (anahtar/Wi-Fi/kimlik ve NVS korunur; **donanımda denenmedi**):

```text
esptool --chip esp32s3 --port COMx --baud 460800 write_flash 0x10000 app_0x10000_v1.2.0.bin
```

## İlk kartta denenecekler

1. Flash (ana imaj) -> açılış seri çıktısı -> `FACTORYINIT` -> `fw` = **1.2.0** (`GET /api/status`, MQTT state `v:3`).
   Yapılandırılmamış kartta: lamba/panjur/duvar butonu/çocuk kilidi/RS485 denemeleri v1.1.2 ile aynı sonuç vermeli; seri `SAFETY`
   "Butun bolgeler NORMAL" ve sensör/eylemci listesi boş.
2. Güvenlik yapılandırması (LAN): `POST /api/safety/config` ile bir su sensörü (`{"set":{"sensor":{"id":"d2","kind":"water","zone":1}}}`),
   bir vana (`{"set":{"actuator":{"relay":5,"kind":"valve","close_mode":"deenergize","medium":"water","zones":[1]}}}`) ve bir siren
   ekleyin (her yamada `base_rev` = önceki yanıttaki `rev`).
3. Gerçek su sensörüyle damla testi; gecikme ölçümü (yerel DI -> yerel röle ve ek DI -> ek röle ayrı ayrı).
4. NC selenoid ile güç kesme: alarm temizlendikten **sonra** güç kesilince vana kapalı açılmalı.
5. Alarm sırasında `REBOOT` (seri: "kilit var, REBOOT FORCE yazın"; HTTP 409) ve `REBOOT FORCE`: ENERGIZE_TO_CLOSE vana yeniden başlatma
   boyunca hiç açılmamalı (osiloskop ya da geri bildirim).
6. Alarm sırasında `POST /api/system/reset?force=1`: vana kapalı kalmalı, kart güvenli kipte (`latch_orphan`) açılmalı; seri
   `SAFETY ACK FORCE` (ya da ALARM_ACK DI'si 5 sn) ile yerel çıkış.
7. ValveGuard: kilitliyken TCA9554 beslemesini kısa kesip (ya da kartı ESD'siz biçimde sıfırlayıp) E2C vananın ~50 ms içinde yeniden
   enerjilendiğini görün (seri `[EMNIYET] ... yeniden KURULUYOR`).
8. Ek modül RS485 kablosu çekilince: ek DI sensörü `ok=false` ve `sensor_fault`; vana açma reddi; RS485 taraması 409.
9. MQTT (sunucu 033 + köprü ile): `ev/{t}/event` alarm_raised -> `event_ack`; broker kesikken alarm ve bağlantı dönünce teslim;
   iki panolu evde `uid`'li komut yalnız hedefte.
10. NVS ölçümü: tam dolu yapılandırmada `nvs_get_stats` (eşik %60).
11. (İnceleme turu) Kilit YOKKEN uygulamadan kapatılan E2C su vanası ve E2C gaz vanası: `REBOOT` ve elektrik kesintisi sonrası
    röle hiç bırakılmamalı (Relay_Init ilk yazımı `safe_msk`); seri günlükte vana açılmaz.
12. (İnceleme turu) Güvenlik yapılandırması bozuk (cfg_corrupt, kilit yok): kapalı vana kapalı kalır, ham `relay` açma reddedilir.
13. (İnceleme turu) İki röleli vana kapalıyken yeniden başlatma: açılışta bir KAPAT darbesi (AÇ rölesi hiç enerjilenmez).
14. (İnceleme turu) İki panolu evde `uid`'siz `{"relay":N,"state":false}`: N'nin siren olduğu panoda siren susmaz.
15. (İnceleme turu) Tam dolu yapılandırmada `nvs_get_stats`: yapılandırma yazımı 16 boş girdi bırakmıyorsa `storage` döner,
    kilit kaydı yazımı başarılı kalır.
16. (İnceleme turu 2) `nvs_get_stats` ile `free_entries`'in boş GC sayfasını sayıp saymadığını ölçün (126 farkı); yapılandırma
    yazımı reddedildiğinde açılışın cfg_corrupt OLMADIĞINI görün.
17. (İnceleme turu 2) cfg_corrupt güvenli kipinde vana rölesini `/api/config` ile darbe rölesine çevirmeyi deneyin: `409 cfg_invalid`.
18. (İnceleme turu 2) LAN'dan kapı kontağı satırını silip aynı girişe `gas_reset` eklemeyi deneyin: `403 local_loosen_forbidden`;
    yeniden başlatmadan sonra da aynı sonuç (`ahbu_latch/di_hist`).

## Birleşik imajın yapısı ve kaynağı

Adresler ve tarif v1.1.2 ile aynıdır.

| Adres | Parça | Kaynak |
| --- | --- | --- |
| 0x0 | `bootloader.bin` (14032 bayt) | PlatformIO derlemesi |
| 0x8000 | `partitions.bin` (3072 bayt) | `app3M_fat9M_16MB.csv`'den PlatformIO üretti |
| 0xE000 | `boot_app0.bin` (8192 bayt) | `framework-arduinoespressif32/tools/partitions/boot_app0.bin` |
| 0x10000 | `firmware.bin` (1248032 bayt) | PlatformIO derlemesi (uygulama) |

```text
esptool.py --chip esp32s3 merge_bin -o firmware_combined_0x0.bin --flash_mode dio --flash_freq 80m --flash_size 16MB \
  0x0 bootloader.bin 0x8000 partitions.bin 0xe000 boot_app0.bin 0x10000 firmware.bin
```

## Doğrulama (donanımsız)

- **Bölge eşitliği:** v1.2.0 birleşik imajının 0x0000-0xFFFF bölgesi (bootloader + bölüm tablosu + boş NVS + boot_app0) v1.1.2 ile
  bayt bayt aynıdır (bölge SHA-256 iki imajda da `9d1afa71aced81c6b5a475e4c987c235c4ad9606acf2e6113440efc31f0da3cd`; dört parça ayrı
  ayrı da aynı); 0x10000 sonrası `app_0x10000_v1.2.0.bin` ile birebir aynıdır.
- **Uygulama imajı:** `esptool image_info`: 5 bölüt, çip kimliği ESP32-S3 (9), giriş noktası `0x4037769c` (v1.1.2 ile aynı), sağlama
  (0xab) ve SHA-256 eki geçerli; gömülü ELF özeti derlemenin `firmware.elf` SHA-256'sıyla aynı
  (`8b394b7d64a1b9370b77e30a4a22d838ec0528eccc5ffa6ee3c6303ea74c23b1`).
- **Fabrika aracı:** `version_info.json` -> v1.2.0; `inspect_firmware_file` yeni imaj için uyarısız geçti; `FACTORYINIT` imzası bulundu.
- **Dizgi taraması (ikili):** `1.2.0` var, `1.1.2` yok; `FACTORYINIT`, `/api/safety/config`, `cfg_dump`, `REBOOT FORCE` var.
- **Testler:**
  - Firmware Unity testleri (`test/test_*`): MSVC 2022 `/std:c++17 /W4` + Unity alt kümesi (bu makinede gcc/clang yok): **17 paket,
    324 test, 0 hata, derleme uyarısı 0** (hizalamada +1: `test_json_aid_and_test_without_feedback`; inceleme turunda +15:
    `test_safety_fsm` +9, `test_actuator_map` +2, `test_safety_cfg_edit` +2, `test_safety_config` +2; inceleme turu 2'de +3:
    `test_safety_config` +2, `test_safety_cfg_edit` +1). Yeni: `test_valve_guard` (9), `test_safety_view` (6), `test_safety_cfg_edit` (8),
    `test_event_log` (4). Eski 8 paket (179 test) ve dalga 1'in 5 paketi değişmeden geçti.
  - QA simülatörü (`tools/qa_stack`, `npm test`): **546/546** (dalga 1 sonunda 490, hizalamada 521, inceleme turunda 541); yeni
    `sim_safety.test.js` (uçtan uca, çok panolu ev dahil 9 senaryo), `sim_valve_guard.test.js` (5), `fw_valve_guard`, `fw_safety_view`,
    `fw_safety_cfg_edit`, `fw_event_log` (Unity portları). `sim_mqtt*` testlerinde `v === 2` beklentisi `v === 3` yapıldı, `smoke.js`
    `v >= 2` denetler [O8]; yerel API rota tablosu 26 -> 32.
  - Fabrika aracı (`python -m unittest discover -s tests`): **358/358**.

## Derleme bilgisi

- Derleme tarihi: 2026-10-07. `FW_VERSION` = `1.2.0` (`WiFiManager.h` varsayılanı).
- Araçlar (v1.1.2 ile aynı): PlatformIO Core; platform espressif32 7.1.3 (çekirdek dizini `G:\.platformio`, ağ kullanılmadı);
  framework-arduinoespressif32 4.20017.260907 (Arduino-ESP32 2.0.17, ESP-IDF v4.4.7); toolchain-xtensa-esp32s3 gcc 8.4.0;
  esptool 4.11.0. Kütüphaneler: ArduinoJson 6.21.6, PubSubClient 2.8.0, NTPClient 3.2.1.
- Derleme: `pio run -e esp32-s3-waveshare` (temiz dizin, `subst P:` kısa yolu; Windows yol uzunluğu sınırı). RAM %20,6
  (67488 / 327680 bayt); Flash %39,7 (1247673 / 3145728 bayt). Derleyici uyarısı: **0** (82 derleme birimi, temiz derleme).
- Kaynak parmak izi (`platformio.ini` + `src/**`, 76 dosya, LF normalleştirilmiş; `<sha256>  <src/... göreli yol>` satırları yola göre
  sıralı, her satır `\n` ile biten metnin SHA-256'sı): `98261493b1c373ac3da3e2c246f55677983df8b9adc35efa5b2c2db7f930078e`.

## Eski imajlar

`v1.0.0` ve `v1.0.1` **KULLANILMAZ**. `v1.1.0`, `v1.1.1` ve `v1.1.2` klasörleri silinmedi (karşılaştırma/geri dönüş; bootloader ve bölüm
tablosu aynı olduğundan eski uygulama imajı 0x10000'a geri yazılabilir; geri dönüşte NVS'teki `ahbu_safety`/`ahbu_latch` ad alanları
eski firmware tarafından yok sayılır). Güncel imaj **v1.2.0**'dır (`version_info.json`).
