# Firmware v1.3.2 — Sürüm Notları (2026-10-09)

> Durum: v1.3.2 = v1.3.1 + 2026-10-09 gece düzeltmelerinin firmware maddeleri (fw-tarama-1, fw-tarama-3, fw-tarama-4, fw-tarama-5,
> sko-5; sözleşme `docs/CONTRACTS.md` C1 ve C6) + iki sahip kararı (bulut sunucu kilidi; sabit rolsüz fabrika varsayılanı, madde 7-8).
> Sürüm numarası 1.3.2 olarak kaldı (hiç yayımlanmadı/karta yazılmadı); imajlar bu iki madde ile yeniden paketlendi.
> **Kartta denendi (2026-10-09, AHBU-S3-DD8754):** açılış 12/12 temiz (panik 0), Wi-Fi, MQTTS (istemci kimliği bağlı EMQX ile),
> kayıtlı ayarların korunması (yalnız uygulama 0x10000'e yazıldı). Bu denemede v1.3.1'den beri süren açılış çökmesi bulunup
> düzeltildi (madde 9) ve imajlar yeniden paketlendi. Aşağıdaki "donanımda doğrulanacaklar" maddeleri hâlâ açık.
> `version_info.json` bu sürümü gösterir (servis yazılımı yeni karta v1.3.2 yazar).

## Dosyalar

| Dosya | Boyut | Ne zaman |
|---|---|---|
| `firmware_combined_0x0.bin` | 1411664 | Yeni / boş kart. 0x0'a yazılır. **Panonun ayarlarını (NVS: anahtar, Wi-Fi, bulut kimliği, güvenlik) SİLER.** |
| `app_0x10000_v1.3.2.bin` | 1346128 | Kurulu kartı güncellemek. **0x10000'e** yazılır; ayarlar korunur. 0x0'a yazmayın (kart açılmaz). |

SHA-256 (ana imaj): `d2dd086dd589287726eaf72d2a0ba5abd99c062f540cef97a5484d7825edf307`
SHA-256 (yalnız uygulama): `21fb3b13feea52d112362bb89af9e4e42aac1fed1c613ededbb0f2104cb95545` (ELF SHA-256 ilk 16: `bcdc8e292fc78284`)
ELF SHA-256: `dedb76d154f090d742f4ce48e2d03974268d1be6e6044ee27091d573d14bd8e8`

Derleme: PlatformIO espressif32@7.1.3 (Arduino-ESP32 2.0.17 / IDF 4.4), temiz derleme; esptool `merge_bin` (`--flash_mode dio
--flash_freq 80m --flash_size 16MB`; 0x0 bootloader / 0x8000 bölüm tablosu / 0xe000 boot_app0 / 0x10000 uygulama). 0x0-0xFFFF bölgesi
v1.3.1 ile aynı; `image_info` sağlama ve doğrulama özeti geçerli.
Boyut: Flash 1345381 bayt (%42,8), statik RAM ~69 KB. Testler: 26 grup / 430 test, 0 hata; QA yığını `npm test` 647/647 (smoke 23/23;
simülatör artık bootstrap'i de modelliyor: kimlik döndürülünce art arda 3 CONNACK 4/5 -> bootstrap -> yeni kimlik).

## v1.3.1'e göre değişenler

1. **Köprü (kablosuz) sensörü yazım yollarında reddedilir** (fw-tarama-1, C1). Bu sürümde hub sürücüsü yok: köprü sensörü hiç
   okunmaz (bölge vanası yeniden açılamaz, gaz bölgesinde sönmeyen arıza, hırsız kipi kurulamaz). LAN ve bulut yaması, seri CLI ve
   kurulum şablonu köprü sensörü içeren tabloyu `sensor_bridge_unsupported` ile reddeder (LAN: 400 `cfg_invalid` + `detail`; bulut:
   `last_rej` `cfg_invalid`; şablon: `sensor_bridge_unsupported` @ `safety.sensors`). Köprüde kumanda rolü yine `sensor_src`.
   - Eski sürümden kalan **kayıtlı** köprü sensörü açılışta güvenli kipe düşürmez.
   - Böyle bir panoda silme dışındaki güvenlik yazımları reddedilir: önce köprü sensörleri silinmeli (silme serbest, birer birer).
   - Ana yapılandırma değişimi (`POST /api/config`, seri CLI) etkilenmez. Durumdaki `caps`'te `bridge` yok (değişmedi).
2. **Uzun onay süresinde onay penceresi büyür** (fw-tarama-3). `confirm_ms` tür penceresinden (su 3 sn, gaz/duman 1 sn) uzunsa
   pencere = en büyük(tür penceresi, ⌈confirm_ms / 7⌉ × 8). Eskiden örneğin gaz 1500 ms sürekli kaçakta bile hiç onaylanmıyordu (vana
   kapanmaz, siren çalmaz); pencerenin 7/8'inden büyük değerlerde onay her kova başında düşüp kalkıyordu. Varsayılanlarda (su 1000,
   gaz/duman 300 ms) ve tür penceresinin 7/8'ine kadar (su 2625, gaz/duman 875 ms) zamanlama birebir aynı. Doğrulama aralığı
   (100..10000 ms) değişmedi. **v1.3.1 ve öncesi panolarda bu düzeltme yoktur**: güncellenene kadar daha uzun onay süresi
   kullanmayın.
3. **Kilit kaydı, hırsız kipi ve vana konumu NVS yazımı yeniden denenir** (fw-tarama-5). Yazım başarısızsa ~2 sn sonra yeniden
   denenir (eskiden bir daha denenmezdi: kilit kaydı yazılamadan elektrik kesilirse bölge NORMAL başlar, kuru vana onaysız
   açılabilirdi). `nvs_fail` olayı ardışık başarısızlıkta anahtar başına bir kez üretilir; başarılı yazım sıfırlar.
4. **Ek modül kanal sayısı azalınca kapsam dışı röleler kapatılır** (fw-tarama-4). Örneğin 16 → 8 kanalda açık röle 21'e KAPAT
   yazılır (en iyi çaba; başarısızsa geri çekilmeyle yeniden, ardışık 5 başarısızlıkta bırakılır, ör. modülde o kanal yoksa).
   Eskiden fiziksel olarak açık kalıyor ve artık komutla da kapatılamıyordu.
5. **Seri `EXTMOD` panjur hareket ederken reddedilir** (fw-tarama-4): `[CLI-HATA] EXTMOD reddedildi: panjur hareket ediyor; degisiklik
   yapilmadi.` LAN `POST /api/config` ve şablonla aynı kural (hareket ya da ölü zaman beklemesi); değişmeyen istek serbest.
6. **`state.cfg.safety.id`** (sko-5, C6): güncel rev'i üreten bulut `cfg_patch` kimliği (desen `[A-Za-z0-9_.:-]{1,24}`). Araya giren
   komut `last_id`'yi değiştirse de kalır; rev başka yoldan (LAN, CLI, şablon) değişince, kimliksiz yamada ve yeniden başlatmada
   yazılmaz. Eski sunucu alanı yok sayar (yalnız `rev`/`crc` okur). LAN `GET /api/status` değişmedi.
7. **Bulut sunucu kilidi** (sahip kararı). `POST /api/mqtt/config` eskiden sözdizimi geçerli her sunucu adını kabul ediyordu: yerel
   anahtarı bilen ya da anahtarsız kablolu Ethernet'teki herkes panoyu yabancı bir brokere taşıyabiliyordu. Artık `server` yalnız
   derlemeye gömülü izin listesinden olabilir: `DEFAULT_MQTT_SERVER` (`evotomasyon.gudeteknoloji.com.tr`) + isteğe bağlı derleme
   bayrağı `-DAHBU_MQTT_HOST_ALLOW="h1,h2"` (virgüllü; büyük/küçük harf duyarsız TAM eşleşme; bu paket bayraksız = yalnız varsayılan
   sunucu). Listede olmayan ad: **400 `{"error":"host_not_allowed"}`**, hiçbir şey değişmez (sözdizimi bozuk ad ve diğer alan
   hataları yine `invalid_value`). Boş ya da verilmemiş `server` mevcut sunucuyu korur; port/kullanıcı/parola değişimi serbest.
   Bootstrap yanıtındaki `host` da aynı listeye tabidir (aksi: kimlik yazılmaz, `BAD_RESPONSE`). MQTT sistem komutları sunucu adı
   taşımaz. Seri CLI'da sunucu adı yazan komut yoktur; fabrika sıfırlaması kayıtlı sunucuyu korur. Anahtarsız Ethernet yetkisi (sahip
   kararı) değişmedi. Kod: `src/MqttHostPolicy.h` (saf mantık, `test_mqtt_host_policy`).
8. **Fabrika varsayılanında hiçbir rölenin sabit rolü yok** (sahip kararı). Eskiden röle 1-4 "Salon/Oda Panjur (Yukarı/Aşağı)" panjur
   çiftleri, DI 1/3 panjur butonu olarak geliyordu. Yeni tablo: yerel röle 1..8 = `Röle N`, genel aç-kapa (`light`), süre 0; ek modül
   röleleri `Ek Modül Röle N` (değişmedi); DI n -> röle n, `TOGGLE` (`Anahtar / Buton N`, ek modülde `Ek Giriş / Buton N`). Panjur
   davranışı (komşu röleyle YUKARI/AŞAĞI eşleşmesi, kilit) yalnız servisin yazdığı şablon/yapılandırmadan gelir; çıkış/kilit kodu
   zaten tipten türetiyordu (röle 1-4'e özgü kod yok). Seri `DEFAULT_DI` artık DI 1..4'ü bu fabrika düzenine döndürür; panjur DI düzeni
   yalnız açık `SET_SHUTTER_DI` komutuyla. Etki: yalnız fabrika sıfırlaması / boş NVS; kayıtlı yapılandırması olan pano değişmez.
9. **Açılışta tekrarlayan çökme düzeltildi** (v1.3.1'de de vardı). Belirti: `STA baglantisi kuruluyor` satırından hemen sonra
   `Backtrace: 0xfffffffe:0x8037f3ec |<-CORRUPTED` ve `Reset nedeni: PANIC`; v1.3.1'de açılış başına ~1, v1.3.2'nin ilk paketinde
   3-8 çökme (sonunda açılıyordu; her çökmede röleler kapanıp açılır). Kök neden (çekirdek dökümü + ELF ile kanıtlı):
   `eth_init` görevi (Core 0) `gpio_install_isr_service(0)` çağırır; IDF 4.4 bunu `esp_ipc_call_blocking(0, ...)` ile 1 KB yığınlı
   `ipc0` görevine yaptırır (`CONFIG_ESP_IPC_TASK_STACK_SIZE=1024`). `esp_intr_alloc` -> `heap_caps_malloc` zincirinin en derin
   noktasında gelen kesme yığını taşırır (yığın sonu izleme noktası -> çift istisna). Düzeltme: `-Wl,--wrap=esp_ipc_call_blocking`
   (`src/IdfIpcWrap.cpp`, karar kuralı `src/IpcPolicy.h`, test `test_ipc_policy`): çağıran görev hedef çekirdeğe sabitse iş IPC'ye
   gitmeden çağıranın kendi yığınında koşar (IDF'in tek çekirdek davranışı); diğer durumlar gerçek IPC. Açılışta
   `[ETH] GPIO ISR servisi eth_init yiginda kuruldu (ipc0 atlandi).` görünür. `platformio.ini`'deki bayrak KALDIRILMAMALI.
   Kartta: 12 yeniden başlatmada panik 0, `eth_init` boş yığını ~2 KB, her açılışta Wi-Fi + MQTTS bağlandı.

## Bilinen / donanımda doğrulanacaklar
- Kartta denendi: açılış, Wi-Fi, MQTTS, ayarların korunması (yukarıda). Hâlâ bakılacaklar: bulut `cfg_patch` sonrası state'te
  `cfg.safety.id`; v1.3.1'den kalan kayıtlı köprü sensörlü panoda açılışın normal kipte olması; ek modüllü kartta 16 → 8 kanal
  geçişinde açık rölenin kapanması; panjur hareketindeyken `EXTMOD` reddi; yabancı sunucuyla `POST /api/mqtt/config` -> 400
  `host_not_allowed` (Ethernet'ten ve anahtarla), `server`sız istekte sunucunun korunması, bootstrap sonrası bağlantı; fabrika
  sıfırlamasından sonra `CFG` çıktısında röle 1-8 `Röle N` tip 0, DI n -> röle n mod 0.
- NVS yeniden denemesi ve kapsam dışı KAPAT yalnız QA simülatöründe hata enjeksiyonuyla sınandı (`SafetyManager.cpp`,
  `SmartAutomation.cpp` PC'de derlenmez; simülatör aynası `tools/qa_stack/sim/fw`).
