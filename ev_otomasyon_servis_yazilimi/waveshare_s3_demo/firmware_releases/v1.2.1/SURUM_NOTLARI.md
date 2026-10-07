# AHBU Akıllı Ev - ESP32-S3 firmware v1.2.1 (sürüm notları)

> **DONANIMDA YALNIZ YAZMA VE AÇILIŞ DOĞRULANDI (2026-10-07):** COM9 test kartına (ESP32-S3, MAC E8:F6:0A:DD:87:54) esptool 4.11.0 ile 0x0'a yazıldı, "Hash of data verified"; kart açıldı, seri `STATUS` ve `SAFETY STATUS` yanıt verdi (`politika=ACIK kip=normal`, provizyonsuz, AP AHBU-DD8754). Sensör/eylemci, alarm kipi, siren ve provizyon denemeleri aşağıdaki listede ve henüz YAPILMADI.
>
> **DONANIMDA DOĞRULANMADI.** Bu imaj hiçbir karta yazılmadı ve hiçbir kartta açılmadı. Dosya düzeyinde doğrulandı (başlık,
> bölüm tablosu, SHA-256 özetleri, 0x0000-0xFFFF bölgesinin v1.2.0 ve v1.1.2 ile bayt bayt eşitliği, dizgi taraması, fabrika aracının
> imaj doğrulayıcısı) ve değişen kod donanımsız testlerle sınandı (firmware'in kendi Unity testleri MSVC ile, QA simülatörü, fabrika
> aracı). Gerçek kapı/pencere kontağı, hareket sensörü, anahtarlı kontak (ARM_KEY), siren, buzzer desenleri ve NVS doluluğu bu sürümde
> **ölçülmedi**. Toplu üretimden ve sahaya çıkmadan önce aşağıdaki "İlk kartta denenecekler" listesinin tamamı tek bir test kartında
> yapılmalı. Dağıtım sırası: **sunucu -> firmware -> uygulama** (Faz 2 tasarımı F2.E.1). Yeni sunucu, `intrusion`/`cfg` yeteneğini ilan
> etmeyen panoda bugünkü gibi çalışır; v1.2.1 kartı eski sunucuyla da çalışır (yeni olay türleri bilinmeyen tür olarak onaylanıp yok
> sayılır, `cfg_dump`'taki yeni `intrusion` anahtarı yok sayılır).

## Dosyalar

| Dosya | Boyut (bayt) | Amaç |
| --- | --- | --- |
| `firmware_combined_0x0.bin` | 1321952 | **Karta yazılacak ana imaj** (0x0 adresine). Bootloader + bölüm tablosu + boot_app0 + uygulama birleşik. |
| `app_0x10000_v1.2.1.bin` | 1256416 | Yalnızca uygulama (yedek; v1.2.1'de OTA alıcısı YOKTUR). Gerekirse esptool ile 0x10000'a yazılır; **0x0'a yazmayın**. |
| `SHA256SUMS.txt` | - | `sha256sum -c SHA256SUMS.txt` ile doğrulayın. |

SHA-256 (ana imaj): `abe7f6852afdd387378395e403f82032300f3d4b850a7e01eb3d59508699f398`
SHA-256 (yalnız uygulama): `68f300a44d92e77af2d45af72f41297f8f1f764dc25ec130d108bb4e0025fd40`

Paket, Faz 2 karşıt incelemesinin düzeltmeleriyle (aşağıda "Faz 2 incelemesi düzeltmeleri") **yeniden üretildi**; sürüm numarası
değişmedi (1.2.1 hiçbir karta yazılmadı). Önceki 1.2.1 paketinin özetleri (`f5d439bf…` / `f3fb8c41…`) geçersizdir.

## v1.2.0'dan farklar (bu sürümde)

Tasarım: `docs/superpowers/specs/2026-10-06-guvenlik-iklim-senaryo-mimarisi-design.md` "Faz 2 tasarımı (2026-10-07)" (F2.B kapı/pencere
alarm kipi, F2.D.6 `cfg_patch` firmware ekleri; kararlar F2-2..F2-5). Gaz/duman (F2.A) firmware davranışı v1.2.0'da zaten tamdır ve
**değişmedi**; bu sürümde QA simülatöründe uçtan uca kilitlendi. **Kapı/pencere/hareket sensörü olmayan panoda (bugünkü bütün saha ve
fabrika varsayılanı) lamba/panjur/tehlike davranışı v1.2.0 ile aynıdır**; tek görünür fark state/`GET /api/status` `caps` dizisine
eklenen `"intrusion"`tır (eşdeğerlik testi: `tools/qa_stack/test/sim_safety_equivalence.test.js`, su + vana + siren yapılandırılmış
panoda hırsız katmanı varken ve yokken iz bit bit aynı).

- **Hırsız alarmı (WP-I1/I2; saf çekirdek `safety/IntrusionFsm.h`):** kip `off` / `home` (evde kurulu: çevre) / `away` (dışarıda
  kurulu: hepsi); durum `idle` / `exit` / `entry` / `alarm`. `SF_REACT`'li kapı/pencere/hareket sensörleri dahildir; sensör
  bayraklarına iki bit eklendi: `SF_ENTRY = 0x08` (giriş yolu, gecikmeli; varsayılan kapı) ve `SF_AWAY_ONLY = 0x10` (yalnız dışarıda;
  varsayılan hareket). Kurma hazırlığı: kurulacak kipte etkin, giriş yolu olmayan her sensör sağlam ve kapalı (`not_ready` reddi);
  giriş yolu açıkken kurulabilir. Çıkış gecikmesinde giriş yolu yok sayılır; süre dolduğunda giriş yolu hâlâ açıksa giriş gecikmesi
  ("çıkış hatası"). Anlık sensör hemen alarm; giriş süresi dolunca alarm. Okunamayan (`ok=false`) sensör alarm üretmez. Alarm sürerken
  yeni tetik `srcs`'e eklenir; sensör başına kurulum döneminde en çok 3 tetik durmuş sireni yeniden çaldırır (swinger).
  Gecikmeler `Policy`'nin v1.2.0'da ayrılmış iki baytında (`exit_s`, `entry_s`; 0 = 45 / 30 sn; yeni NVS girdisi yok, fabrika
  yapılandırmasının CRC'si değişmez).
- **Siren VEYA'sı ve buzzer:** siren rölesi tehlike isteği ile hırsız isteğinin VEYA'sıdır; her kaynak kendi `run_limit_s` bütçesini
  tutar. Tehlike ACK'i yalnız tehlike isteğini, çözme yalnız hırsız isteğini kaldırır; kullanıcının sireni kapatması ikisini de o alarm
  dönemi için bastırır. Hırsız alarmı vana sürmez, bölge kilidi üretmez, `policy:off` onu kapatmaz; ev genelidir (bütün sirenler).
  Kart buzzer'ı: tehlike alarmı > hırsız alarmı (500/500 ms) > giriş bip'i (200/400 ms) > çıkış bip'i (100 ms / 1 sn)
  (`Buzzer_SetPattern`).
- **Kalıcılık (F2-4):** kip ve alarm belleği yeni NVS anahtarı `ahbu_latch/arm` (20 B; yalnız kip değişiminde ve alarm geçişinde
  yazılır; fabrika sıfırlaması silmez; açılışta kilit kaydıyla birlikte yer ayrılır). Açılışta kip geri yüklenir, çıkış gecikmesi
  YOKTUR (`arm_changed via:"boot"`); bellekteki alarm aynı `aid` ile geri gelir ve siren **çalmaz** (yeni tetik çaldırır). Güvenli
  kipte (`cfg_corrupt` / `latch_orphan`) kip korunur, `arm.ok=false`, alarm üretilmez, kurma `safe_mode`, çözme serbest.
- **ARM_KEY (yeni DI rolü 19, `kind:"arm_key"`):** anahtarlı kontak; pasif->aktif kenarı `away` kurar (hazır değilse kurulmaz, kısa
  hata bip'leri), aktif->pasif kenarı çözer; ilk okuma kenar değildir. Yalnız panodaki DI'den. LAN'dan daha önce kullanılmış bir
  DI'ye yeni `arm_key` eklemek ya da mevcut satırı `arm_key`'e çevirmek gevşetmedir (`403 local_loosen_forbidden`; GAS_RESET'teki
  `di_hist` kuralı); diğer hırsız ayarları LAN'dan serbesttir. Güvenlik çekirdeğinin kumanda rolleri ARM_KEY'i atlar (vana sürmez).
- **ContactBus (`sensors/ContactBus.h`, F2.B.5, F2-5):** kapı/pencere onaylı seviye kenarları 16 yuvalık çok tüketicili halkada
  (iklim/senaryo çekirdekleri için arabirim, `zoneWindowOpenFor`); olay kutusuna yazılmaz.
- **State / LAN durumu:** `caps` += `"intrusion"`; `safety.arm` `{mode, st, ok, until_up?, aid?, srcs?}` yalnız hırsız sensörü varsa
  (ya da kip kuruluysa); `until_up` gecikmenin bittiği uptime saniyesidir (sabit; görünüm imzası her saniye değişmez). Yeni ret kodu
  `last_rej.code = "not_ready"`.
- **Olaylar (`ev/{t}/event`):** `intrusion_alarm` (`zone`, `kind:"intrusion"`, `srcs`; alarm kimliği olayın eid'si; taşmada atılmaz),
  `intrusion_cleared` (`aid`, `via`), `arm_changed` (`mode`, `via`: `cloud|lan|cli|di|boot`; en düşük öncelik).
- **Komutlar:** MQTT `{"cmd":"safety_arm","mode":"away"|"home"|"off","uid",...}` artık uygulanır (v1.2.0'da `unsupported`). Yeni LAN
  ucu `POST /api/arm {mode, uid?, id?}` (KEYED; yanıt `{ok, id, rej?}`; bilinmeyen alan `400 unknown_field`, geçersiz kip
  `400 invalid_value`; rota tablosu 32 -> 33). Seri CLI `ARM [STATUS]`, `ARM AWAY|HOME|OFF`.
- **Yapılandırma:** yama `set.intrusion {exit_s, entry_s}` (0..255, en az biri); sensör `flags` sınırı 0x07 -> 0x1F; `kind:"arm_key"`.
  `GET /api/safety/config` ve `cfg_dump` 1. parça `"intrusion":{"exit_s","entry_s"}` (policy'den hemen sonra).
- **sys `cfg_patch` (WP-C1, F2.D.6):** başarıda (geçerli `id` varsa) `state.last_id = id` (sunucunun bekleyicisi için; otomasyon daha
  yeni bir komut işleyene dek); NVS payı yetmezse ret kodu `busy` yerine yeni `cfg_storage`.
- **Faz 2 incelemesi düzeltmeleri (aynı 1.2.1 içinde):**
  - **Bulut yaması gaz vanasını açılabilir kılamaz (G-1a; karar 7.2b-8):** `cfg_patch` mevcut gaz vanasının kimliğini (röle, tür, kip,
    akışkan) değiştiremez ya da onu silemez; kapı kontağını gaz açma düğmesine çeviremez (GAS_RESET satır kuralı). Ret
    `last_rej.code = "gas_local_only"`. Yalnız seri CLI (fiziksel erişim); LAN'da zaten gevşetme yasağı.
  - **Kurulu kipte bulut yaması hırsız alarmını zayıflatamaz (G-1b; F2-3):** SF_REACT'li kapı/pencere/hareket sensörünü silmek ya da
    alarm dışı bırakmak, SF_ENTRY/SF_AWAY_ONLY eklemek, NC->NO, onay süresini ya da çıkış/giriş gecikmesini uzatmak, kullanılmış girişe
    `arm_key`: yeni ret kodu `last_rej.code = "armed"`. Çözülüyken bulut yolu ve her zaman LAN/CLI serbest (B.3).
  - **Giriş gecikmesinde enerji kesintisi (RV-E2):** giriş gecikmesi başlangıcı `ahbu_latch/arm` kaydına yazılır (`alarm = 2`, giriş
    yolu sensör kodları); açılışta giriş gecikmesi baştan başlar, süre dolunca alarm (kapı bu arada kapatılmış olsa da). Çözme önler.
  - **Anahtarlı kontak yalnız NC (RV-E3):** `arm_key` satırında `active_open = 0` artık `cfg_invalid` (`detail: arm_key_not_nc`).
    Kurulu konumda kontak açık olmalı; kablo kesilirse alarm kurulu kalır (NO bağlantıda kablo kesmek alarmı çözerdi).
  - **Buzzer (RG-3):** hırsız deseni (çıkış/giriş/alarm) sürerken komut bip'leri yutulur; desen başlarken bekleyen bip'ler atılır
    (desen bitince art arda bip seli olmaz).
- **Sürüm:** `FW_VERSION` 1.2.0 -> **1.2.1** (`WiFiManager.h`).
- **Boyut:** uygulama imajı +8384 bayt (1248032 -> 1256416). RAM 67488 -> 68624 bayt (+1136; hırsız çekirdeği, ContactBus, görünüm `arm`). Flash %39,9.
- **Değişmeyenler:** bootloader, bölüm tablosu (NVS 0x5000 dahil) ve boot_app0 v1.2.0 (ve v1.1.2) ile **bayt bayt aynıdır** (aşağıda).
  Gaz/duman/su tepkileri, vana/ValveGuard, Wi-Fi/AP provizyon akışı, `FACTORYINIT`/`RESETKEY`, gömülü web sayfası
  (`WebPortalPage.h`) değişmedi; web sayfasında güvenlik/alarm ekranı YOKTUR.

## Bilinen sınırlar ve açık işler

- **Sürüm numarası:** Faz 2 tasarımı hırsız katmanını "1.3.0" olarak anar; bu paket iş emrine göre **1.2.1** olarak numaralandı.
  Uygulama/sunucu yetenek denetimi sürüm numarasına değil `caps` `"intrusion"`a bakar.
- **NVS bütçesi:** `ahbu_latch/arm` +1 girdi (en kötü durum %105,6 -> %105,8; bütçe kararı v1.2.0'daki gibi açık). Cihazda
  `nvs_get_stats` ölçülmeli.
- Hareket sensörü giriş yolu (`SF_ENTRY`) işaretlenmezse anlık sayılır: dışarıda kipte kurarken önünde durulan PIR kurmayı engeller
  (`not_ready`); koridor PIR'ı giriş yolu olarak işaretlenmeli (sihirbaz anahtarı, F2.B.9).
- v1.2.0'da yapılandırılmış kapı sensörleri `flags = 1` (giriş yolu değil) olarak kalır; kip kurulursa kapı anlık davranır. Sihirbaz
  bayrakları ancak `caps` `"intrusion"` gördükten sonra yazar (F2.B.7).
- Somut Zigbee/Thread köprü sürücüsü, RTC<->SNTP, termostat (3.x) ve senaryo motoru (5.x) bu sürümde yok (`ContactBus` arabirimi hazır).
- Gerçek `pio test -e native` gcc/clang olan bir makinede ayrıca koşulmalı (bu makinede MSVC ile koşuldu).

## Nasıl flash'lanır

Fabrika aracı (`ev_otomasyon_sistemi.py`): "Bizim Geliştirdiğimiz Yazılım" seçili iken dosya yolu
`firmware_releases/v1.2.1/firmware_combined_0x0.bin` olarak gelir (`version_info.json` bunu gösterir) -> kartı USB ile bağlayın ->
**FİRMWARE'İ KARTA YÜKLE (FLASH)**. Provizyon akışı v1.2.0 ile aynıdır (USB-seri `FACTORYINIT`).

Elle (aracın kullandığı komutun aynısı):

```text
esptool --chip esp32s3 --port COMx --baud 460800 write_flash 0x0 firmware_combined_0x0.bin
```

Not: imaj 0x0'dan itibaren NVS alanını (0x9000-0xDFFF) da kapsar; yazma sonrası kart provizyonsuzdur (FACTORYINIT gerekir) ve
güvenlik yapılandırması/kilit kaydı/hırsız kipi silinir.

Sahadaki provizyonlu bir v1.2.0 kartın yalnız uygulamasını yenilemek (anahtar/Wi-Fi/kimlik ve NVS korunur; **donanımda denenmedi**):

```text
esptool --chip esp32s3 --port COMx --baud 460800 write_flash 0x10000 app_0x10000_v1.2.1.bin
```

## İlk kartta denenecekler

1. Flash (ana imaj) -> açılış seri çıktısı -> `FACTORYINIT` -> `fw` = **1.2.1**, `caps` içinde `"intrusion"` (`GET /api/status`,
   MQTT state `v:3`). Yapılandırılmamış kartta: lamba/panjur/duvar butonu/çocuk kilidi/RS485 ve v1.2.0 "İlk kartta denenecekler"
   1-18 aynı sonucu vermeli; seri `ARM` "Hirsiz alarmi yapilandirilmamis".
2. Kapı kontağı (NC, giriş yolu) + pencere kontağı (NC) + siren ekleyin (`POST /api/safety/config`; ör.
   `{"set":{"sensor":{"id":"d3","kind":"door","zone":1,"active_open":1}}}`, `{"set":{"intrusion":{"exit_s":20,"entry_s":15}}}`).
3. Pencere açıkken `POST /api/arm {"mode":"away"}` -> `{"ok":false,"rej":"not_ready"}`; pencere kapalı, kapı açıkken kurulur;
   çıkış bip'i (1 sn'de bir) duyulur; kapı kapanınca süre sonunda bip susar.
4. Gerçek kapı kontağıyla giriş: giriş bip'i (hızlı), süre içinde `ARM OFF` -> alarm yok; süre dolunca siren + `intrusion_alarm`.
5. Siren süre bütçesi (`run_limit_s`) dolunca susar; aynı pencere 3 kez daha açılınca yalnız 2 kez yeniden çalar (swinger).
6. Su alarmı + hırsız alarmı birlikte: tehlike ACK'i sireni susturmaz (hırsız sürer); çözme tehlike sirenini susturmaz; vana yalnız
   su ile kapanır.
7. Kurulu kipte güç kesintisi: açılışta çıkış gecikmesi yok, kip korunur; alarm sırasında güç kesintisi: alarm aynı `aid` ile geri
   gelir, siren çalmaz; yeni tetik çaldırır.
8. ARM_KEY anahtarlı kontak: kenarla kur/çöz; pencere açıkken anahtar çevrilince kurulmaz ve kısa hata bip'leri duyulur.
9. MQTT (sunucu ile): `safety_arm` -> `arm_changed via:cloud`; `intrusion_alarm` -> `event_ack`; `cfg_patch` başarısında state
   `last_id` = yama `id`'si; NVS dolu yapılandırmada `last_rej.code` = `cfg_storage`.
10. NVS ölçümü: `ahbu_latch/arm` dahil `nvs_get_stats`.
11. Giriş gecikmesi sürerken (kapı açılıp kapandıktan sonra) kartın enerjisini kesin: açılışta giriş bip'i yeniden başlar, süre dolunca
    siren + `intrusion_alarm` (kaynak kapı); süre içinde `ARM OFF` alarmı önler. Giriş başlangıcında `ahbu_latch/arm` yazımı ölçülsün.
12. ARM_KEY NC: anahtar kurulu konumda kontağı açar; kurulu iken anahtar kablosunu sökün -> kip kurulu kalır, alarm çözülmez. NO
    bağlantıyla yapılandırma `400 cfg_invalid` (`arm_key_not_nc`).
13. Bulut yaması sınırları (sunucu ile): gaz vanasının akışkanını suya çevirmek / silmek -> `last_rej.code = gas_local_only`, vana
    kapalı kalır ve rölesi uzaktan açılmaz; kurulu kipte pencerenin bayraklarını sıfırlamak -> `armed`; çözülüyken uygulanır.
14. Çıkış/giriş deseni sürerken duvar butonuyla lamba açıp kapayın: komut bip'i duyulmaz; desen bitince birikmiş bip çalmaz.

## Birleşik imajın yapısı ve kaynağı

Adresler ve tarif v1.2.0 ile aynıdır.

| Adres | Parça | Kaynak |
| --- | --- | --- |
| 0x0 | `bootloader.bin` (14032 bayt) | PlatformIO derlemesi |
| 0x8000 | `partitions.bin` (3072 bayt) | `app3M_fat9M_16MB.csv`'den PlatformIO üretti |
| 0xE000 | `boot_app0.bin` (8192 bayt) | `framework-arduinoespressif32/tools/partitions/boot_app0.bin` |
| 0x10000 | `firmware.bin` (1256416 bayt) | PlatformIO derlemesi (uygulama) |

```text
esptool.py --chip esp32s3 merge_bin -o firmware_combined_0x0.bin --flash_mode dio --flash_freq 80m --flash_size 16MB \
  0x0 bootloader.bin 0x8000 partitions.bin 0xe000 boot_app0.bin 0x10000 firmware.bin
```

## Doğrulama (donanımsız)

- **Bölge eşitliği:** v1.2.1 birleşik imajının 0x0000-0xFFFF bölgesi (bootloader + bölüm tablosu + boş NVS + boot_app0) v1.2.0 ve v1.1.2
  ile bayt bayt aynıdır (bölge SHA-256 üç imajda da `9d1afa71aced81c6b5a475e4c987c235c4ad9606acf2e6113440efc31f0da3cd`; dört parça ayrı
  ayrı da aynı); 0x10000 sonrası `app_0x10000_v1.2.1.bin` ile birebir aynıdır.
- **Uygulama imajı:** `esptool image_info`: 5 bölüt, çip kimliği ESP32-S3 (9), giriş noktası `0x4037769c` (v1.2.0 ile aynı), sağlama
  (0x97) ve SHA-256 eki geçerli; gömülü ELF özeti derlemenin `firmware.elf` SHA-256'sıyla aynı
  (`e0f930caacaf7c462902f60d18246fcb251cabe262e6e1e8db71cd6b6b69ec7e`). Kaynak parmak izi (platformio.ini + src/**, 78 dosya, LF):
  `54b35a5322afb1e00a9488a9ecd6c47e634d29d74b7b30c88710a769e4b6e396`.
- **Derleme:** temiz derleme (`.pio/build` silinerek), PlatformIO çekirdeği `G:\.platformio`, **uyarı 0**; RAM %20,9 (68624 B),
  Flash %39,9 (1256049 B).
- **Fabrika aracı:** `version_info.json` -> v1.2.1; `inspect_firmware_file` yeni imaj için uyarısız geçti; `FACTORYINIT` imzası bulundu.
- **Dizgi taraması (ikili):** `1.2.1` var, `1.2.0` yok; `FACTORYINIT`, `/api/arm`, `intrusion_alarm`, `arm_changed`, `arm_key`,
  `not_ready`, `cfg_storage` var; inceleme düzeltmeleriyle `armed`, `gas_local_only`, `arm_key_not_nc` da var.
- **Testler:**
  - Firmware Unity testleri (`test/test_*`): MSVC 2022 `/std:c++17 /W4` + Unity alt kümesi: **19 paket, 360 test, 0 hata, derleme
    uyarısı 0** (v1.2.0: 17 paket / 324; Faz 2 incelemesi +4: `test_gas_release_rules`, `test_intrusion_loosening_rules`,
    `test_boot_restores_entry_delay`, `test_boot_entry_disarm_and_bad_record`; `test_safety_config` NC denetimi genişledi). Yeni: `test_intrusion_fsm` (19), `test_contact_bus` (8); ek: `test_event_outbox` +1,
    `test_safety_cfg_edit` +2, `test_safety_config` +1, `test_safety_view` +1 (`caps` beklentisi `"intrusion"` ile güncellendi).
  - QA simülatörü (`tools/qa_stack`, `npm test`): **603/603** (v1.2.0: 546; Faz 2 incelemesi +8: G-1a/G-1b uçtan uca, RV-E2 ve
    G-1 Unity portları, RG-3 buzzer, ortak vektörler 51 -> 68 ve `gas_release` / `intrusion_loosening` sınıfları). Yeni: `sim_intrusion.test.js` (5 uçtan uca senaryo),
    `sim_safety_gas.test.js` (5; gaz/duman F2.A.9, mutasyonla kırmızı kanıtı), `fw_intrusion_fsm` / `fw_contact_bus` (Unity portları),
    `sim_safety.test.js` +1 (`cfg_patch` `last_id` yankısı + `cfg_storage`), `sim_safety_equivalence` +1 (hırsız katmanı varken/yokken
    iz bit bit aynı), `broker.test.js` +1 (QA brokeri: aedes eşzamanlı retained yayın kaybı düzeltildi). Yerel API rota tablosu 32 -> 33.
    `fwcheck`: 64 kaynak, firmware 1.2.1.
  - Fabrika aracı (`python -m unittest discover -s tests`): **358/358**.
