# Firmware v1.3.2 — Sürüm Notları (2026-10-09)

> Durum: v1.3.2 = v1.3.1 + 2026-10-09 gece düzeltmelerinin firmware maddeleri (fw-tarama-1, fw-tarama-3, fw-tarama-4, fw-tarama-5,
> sko-5; sözleşme `docs/CONTRACTS.md` C1 ve C6) + iki sahip kararı (bulut sunucu kilidi; sabit rolsüz fabrika varsayılanı, madde 7-8).
> Sürüm numarası 1.3.2 olarak kaldı (hiç yayımlanmadı/karta yazılmadı); imajlar bu iki madde ile yeniden paketlendi.
> **Kartta HENÜZ DENENMEDİ**: yalnız derleme, PC birim testleri (Unity/MSVC) ve QA yığınının simülatörü. `version_info.json` bilerek
> değiştirilmedi (hâlâ v1.3.1'i gösterir); kartta denendikten sonra güncellenmeli.

## Dosyalar

| Dosya | Boyut | Ne zaman |
|---|---|---|
| `firmware_combined_0x0.bin` | 1411280 | Yeni / boş kart. 0x0'a yazılır. **Panonun ayarlarını (NVS: anahtar, Wi-Fi, bulut kimliği, güvenlik) SİLER.** |
| `app_0x10000_v1.3.2.bin` | 1345744 | Kurulu kartı güncellemek. **0x10000'e** yazılır; ayarlar korunur. 0x0'a yazmayın (kart açılmaz). |

SHA-256 (ana imaj): `da5273fa1831a2428c81f8f0e61b19f2c1ee42661e973da7f70aebc578924d47`
SHA-256 (yalnız uygulama): `0de1b4546d37bade0ffd3bd2d8189c52b077e80bf72d219a60565fd2fea586e6`
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

## Bilinen / donanımda doğrulanacaklar
- Bu sürüm kartta denenmedi. Kartta bakılacaklar: açılış ve `fw: 1.3.2`, MQTTS bağlantısı, bulut `cfg_patch` sonrası state'te
  `cfg.safety.id`; v1.3.1'den kalan kayıtlı köprü sensörlü panoda açılışın normal kipte olması; ek modüllü kartta 16 → 8 kanal
  geçişinde açık rölenin kapanması; panjur hareketindeyken `EXTMOD` reddi; yabancı sunucuyla `POST /api/mqtt/config` -> 400
  `host_not_allowed` (Ethernet'ten ve anahtarla), `server`sız istekte sunucunun korunması, bootstrap sonrası bağlantı; fabrika
  sıfırlamasından sonra `CFG` çıktısında röle 1-8 `Röle N` tip 0, DI n -> röle n mod 0.
- NVS yeniden denemesi ve kapsam dışı KAPAT yalnız QA simülatöründe hata enjeksiyonuyla sınandı (`SafetyManager.cpp`,
  `SmartAutomation.cpp` PC'de derlenmez; simülatör aynası `tools/qa_stack/sim/fw`).
