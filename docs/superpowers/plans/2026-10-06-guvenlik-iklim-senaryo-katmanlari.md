# Güvenlik, İklimlendirme ve Senaryo Katmanları — İş Planı

> Amaç: Lamba + panjur uzaktan kumandasını; can/mal güvenliği, enerji tasarrufu ve otonom senaryolarla çalışan
> uçtan uca bir ekosisteme dönüştürmek. Mevcut lamba/panjur mantığı bozulmaz; yeni modüller gevşek bağlı eklenir.
> İşaretler: `[x]` tamamlandı (kodda mevcut / bu planla yapıldı), `[ ]` yapılacak.

## 0. Mevcut temel (zaten çalışan)

- [x] ESP32-S3 (Waveshare 8DI-8RO) firmware: 8 yerel + RS485 ek modül ile 40'a kadar röle, panjur çiftleri (interlock, ölü zaman, konum takibi, NVS'e konum yazımı)
- [x] FreeRTOS görev yapısı, komut kuyruğu (`postDeviceCommand`), bloklamayan ana döngü, watchdog (`esp_task_wdt`)
- [x] Dijital girişlerde yazılımsal debounce (`DiGate.h`) ve duvar butonu → röle/panjur eşlemesi (bulut yokken de çalışır)
- [x] MQTTS (TLS, ISRG kökleri) `ev/{t}/cmd|state|status|sys`; state yükü `v:2` (röle/panjur/DI, `last_id` onayı); LWT çevrimiçi/dışı
- [x] Yerel HTTP API (LAN/AP, `X-Device-Key`), seri CLI, FACTORYINIT provizyonu, firmware v1.1.2
- [x] Sunucu: komut yetki matrisi, köprü, yerleşim eşitleme (WP-L), zamanlı kurallar, gece huzur hatırlatması, çocuk kilidi, push (FCM) altyapısı
- [x] Flutter: pano kartları (lamba/panjur), komut hattı (iyimser UI + onay/geri alma), hızlı senaryolar ("İyi Geceler", "Evden Çıkıyorum", "Tüm Lambalar"), Neon Glass + Hareket v3

## 1. Mimari ve sözleşme (ilk adım)

- [x] 1.1 Modüler firmware mimarisi tasarımı (yeni dosya/görev yapısı): `sensors/` (giriş sürücüleri), `safety/` (SafetyManager durum makinesi), `climate/`, `energy/`, `presence/`, `scenes/` (yerel senaryo motoru); mevcut `SmartAutomation` yalnız komut alıcısı olarak kalır
- [x] 1.2 Donanım eşleme kararı: hangi DI su/gaz/duman/kapı kontağı, hangi röle vana (NC/NO, motorlu/selenoid, geri bildirim kontağı); 8DI yetmezse RS485 sensör modülü
- [x] 1.3 Ortak payload sözleşmesi (CONTRACTS §2.6 yeni): `state v:3` (geriye uyumlu, `v:2` istemcileri bozulmaz) — `sensors[]`, `alarms[]`, `valves[]`, `climate{}`, `energy{}`; `cmd` ekleri (`valve`, `alarm_ack`, `scene`, `climate_target`); olay (event) konusu `ev/{t}/event` (QoS1, kalıcı alarm kaydı)
- [x] 1.4 Sunucu şema/migration: `alarms` (olay geçmişi), `sensor_readings` (telemetri, zaman serisi özet), `scenes` tabloları
- [x] 1.5 QA simülatörüne yeni sensör/vana modeli (donanımsız uçtan uca test)

## 2. Güvenlik ve erken uyarı (öncelikli)

- [x] 2.1 **Su baskını + akıllı vana (İLK MODÜL)** — firmware `SafetyManager`: sensör tetiklenince (debounce sonrası) bulut/uygulamadan BAĞIMSIZ vanayı kapat, kilitli alarm (latched) durumu, NVS'e yaz, yeniden başlatmada kapalı kalır; yalnız onay + sensör kuruyken açılabilir; vana geri bildirimi/zaman aşımı arızası
- [x] 2.2 Su modülü sözleşmesi + sunucu: alarm olayı → `alarms` kaydı → yüksek öncelikli push
- [x] 2.3 Su modülü Flutter durum modeli: `SafetyState` / `AlarmItem` / `ValveItem`, kritik alarm kartı, "vanayı kapat" / "alarmı onayla" tek dokunuş
- [x] 2.4 Gaz ve duman algılama: yerel siren rölesi, gaz vanası kesme, (isteğe bağlı) tahliye fanı; aynı SafetyManager deseni
- [ ] 2.5 Kapı/pencere kontakları: alarm (kurulu/çözülü kip) + iklim/enerji senaryolarına girdi — *alarm kipi tamam (firmware 1.2.1); iklim/senaryo girdisi 3.2/5.2 ile*
- [x] 2.6 Flutter: kritik bildirim kanalı (Android high-importance, iOS critical alert izni), alarm geçmişi ekranı — *uygulama tarafı hazır; uygulama kapalıyken teslim için Firebase (FCM) bağlantısı ayrı karar (WP-N4)*

## 3. İklimlendirme ve enerji

- [ ] 3.1 Sıcaklık/nem sensörü okuma (I²C/RS485), telemetri
- [ ] 3.2 Termostat: histerezis (ilk sürüm) → isteğe bağlı PID; kombi rölesi; pencere açıkken ısıtmayı durdur
- [ ] 3.3 TRV entegrasyonu (Zigbee/Thread köprüsü gerektirir — mimari karar)
- [ ] 3.4 Enerji izleme: akım trafosu/ölçüm modülü (RS485 Modbus sayaç), anlık güç, aşırı yük alarmı
- [ ] 3.5 Flutter: sıcaklık/nem göstergesi, hedef sıcaklık çarkı, günlük/haftalık tüketim grafiği veri modeli

## 4. Motor ve aydınlatma geliştirmeleri

- [x] 4.1 Panjur/lamba mantığı ve zamanlı (saat bazlı) kurallar
- [ ] 4.2 mmWave/PIR varlık sensörü: odada insan varken ışığı açık tut (varlık zaman aşımı)
- [ ] 4.3 Güneş açısı (konum + saatten hesap) ve sıcaklık eşiğine bağlı panjur senaryosu

## 5. Senaryolar ve otonom çalışma

- [x] 5.1 Basit hızlı senaryolar (Flutter tarafı toplu komutlar)
- [ ] 5.2 Sunucu/firmware senaryo modeli (tetik + koşul + eylem listesi), yerel çalışabilen alt küme panoda
- [ ] 5.3 "Evden Çıkış" (ışıklar, prizler, panjur, termostat ekonomi, alarm kur), "Gece Modu" (%-parlaklık gerektirir: dimmer donanımı kararı), "Güneş/Isı Koruması"

## 6. Doğrulama ve teslim

- [x] 6.1 Her modül için TDD: firmware mantığı saf C++ (PC'de test edilebilir), QA simülatörü, sunucu ve Flutter testleri
- [ ] 6.2 Donanımda deneme listesi (saha kontrol listesine yeni aşamalar)
- [ ] 6.3 Firmware sürümü (v1.2.0) + sunucu migration + uygulama sürümü dağıtımı

## Kararlar (kullanıcı, 2026-10-06)

- [x] K1 **Vana / eylemci:** röle ile tetiklenip açılıp kapanabilen HER cihaz desteklenir (selenoid, motorlu vana, siren, fan…).
  Kurulumda röle başına "eylemci tipi" seçilir: `valve` (kapat = enerji ver/kes kipi, darbe/sürekli, isteğe bağlı konum
  geri bildirim girişi), `siren`, `fan`, `generic`. Güvenlik kuralı yalnız "kapalı/güvenli konuma getir" ister; cihaz türünden bağımsız.
- [x] K2 **Sensör bağlantısı ikisi birden:** (a) kablolu kuru kontak / sensörlü dijital giriş (8DI + RS485 ek giriş modülü),
  (b) Zigbee/Thread hub üzerinden kablosuz. Firmware'de ortak `SensorSource` arayüzü: `DiSensor` ve `BridgeSensor` aynı olayı üretir;
  güvenlik mantığı kaynağı bilmez. Hub bağlantısı yerel (LAN/RS485/seri) olmalı, bulut gerektirmemeli.
- [x] K3 **Gaz/duman:** sertifikalı bağımsız dedektör; pano yalnız onun kuru kontak/röle çıkışına tepki verir (vana kes, siren, fan, bildirim).
  Algılama sorumluluğu dedektörde; panoda gaz eşik/kalibrasyon kodu YOK.
- [x] K4 **Parlaklık:** kurulum sihirbazında kanal başına "parlaklık ayarı yapılacak mı?" sorusu. Evet seçilirse sihirbaz
  dimmer donanımının gerektiğini ve nereye ekleneceğini söyler (röle çıkışı dimmer yapamaz: RS485 Modbus dimmer modülü ya da
  Zigbee/Thread dimmer; bağlantı noktası, adres ve hangi kanalın yerine geçeceği ekranda gösterilir). Dimmer yoksa senaryolardaki
  "%N parlaklık" o kanal için "aç" olarak uygulanır.
- [x] K5 **Buluttan bağımsız çalışma (TÜM özellikler, varsayılan ayarlarla):** güvenlik kuralları, termostat, varlık-ışık, senaryolar ve
  zamanlamalar panoda çalışır; bulut yalnız uzaktan erişim, bildirim, geçmiş ve yapılandırma eşitlemesi içindir. Yapılandırma panoda
  (NVS) tutulur, bulut kopyası eşitlenir; internet yokken yerel uygulama (LAN) ve duvar butonları her şeyi yönetebilir. Varsayılan
  (fabrika) ayarlarda güvenlik tepkileri AÇIK gelir.

Bu kararların plana etkisi: 1.1'de `SensorSource` + `Actuator` soyutlamaları, 1.3'te kaynak alanı (`src: di|bridge`), 2.x'te güvenlik
eylemleri eylemci tipinden bağımsız, 3.x/4.x/5.x'te tüm mantık panoda (senaryo motoru yerel), sihirbaza dimmer adımı (yeni madde 4.4).

- [x] 4.4 Kurulum sihirbazı: kanal başına parlaklık sorusu + dimmer donanım yönergesi (K4)
- [ ] 5.4 Senaryo ve kural tanımlarının panoya indirilip yerel çalıştırılması; bulut yalnız eşitleme (K5)

Tasarım: `docs/superpowers/specs/2026-10-06-guvenlik-iklim-senaryo-mimarisi-design.md` (1.1, 1.3 ve 2.1-2.3 için tasarım, revizyon 2: üç bağımsız inceleme işlendi, kararlar §8, açık sorular §7.2; uygulama yapılmadı)

## İlerleme kaydı

- **2026-10-07 — Su baskını + vana modülü ve güvenlik altyapısı TAMAM** (1.1–1.5, 2.1–2.3, 4.4, 6.1):
  firmware v1.2.0 (SafetyCore/SafetyManager/ValveGuard, state v:3, `ev/{t}/event` + eid/ack, yerel API, CLI, kilit NVS),
  sunucu (migration 033, alarm servisi, push, komut/rol kuralları), Flutter (modeller, alarm/vana kartları, alarm geçmişi,
  sihirbazda sensör/eylemci atama + K4 dimmer sorusu), QA simülatörü uçtan uca. İki karşıt inceleme turu; bulguların hepsi
  düzeltildi. Doğrulama: server 2174 test 0 kırık (PG'siz/PG'li), qa_stack 546/546, firmware Unity 321+, fabrika aracı 358,
  flutter analyze 0, flutter test +4380 0 kırık. Firmware DONANIMDA DOĞRULANMADI (karta yazılmadı).
- Kalan (sonraki adımlar): 2.4 gaz/duman uçtan uca (çekirdek destekli; sunucu/uygulama akışları ve saha), 2.5 kapı/pencere
  alarm kipi, 2.6 Flutter FCM alıcısı + alarm kanalları, buluttan yapılandırma yazımı (`sys cfg_patch`), somut Zigbee/Thread
  köprü sürücüsü, gerçek kartta deneme + NVS ölçümü; 3.x, 4.2–4.3, 5.2–5.4.
- **2026-10-07 — Faz 2 tasarımı yazıldı** (kod yok): 2.4 gaz/duman uçtan uca, 2.5 alarm kipi (+ `ContactBus`), 2.6 bildirim alıcısı
  (gerçek FCM ağ geçidi ayrı karar, WP-N4), buluttan yapılandırma yazımı (`cfg_patch`, `device_configs.pending`). Tasarım belgesi
  "Faz 2 tasarımı (2026-10-07)" bölümü; iş paketleri WP-G1..G3, WP-I1..I6, WP-N1..N4, WP-C1..C3; kararlar F2-1..F2-10.
- **2026-10-07 — Faz 2 uygulandı ve birleştirildi** (2.4 gaz/duman, 2.5 alarm kipi + `ContactBus`, 2.6 bildirim alıcısı,
  buluttan yapılandırma yazımı): FW (WP-I1/I2/C1, firmware **1.2.1**, sürüm paketi `firmware_releases/v1.2.1`), SRV (WP-G1/N1/I4/C2,
  migration 034), APP (WP-G2/N2/N3/I5/I6/C3) ayrı dallarda yazılıp tek ağaçta birleştirildi; üç katman alan alan karşılaştırıldı
  (CONTRACTS §2.6/§2.7 "Faz 2 birleştirme hizalaması"; uçtan uca bağlayıcı test `tools/qa_stack/test/f2_cross_layer_contract.test.js`).
  Düzeltilen uyumsuzluklar: `cfg_dump` `intrusion` sunucuda atılıyordu, state `arm_key` sunucuda `generic` oluyordu, sunucu gevşetme
  portunda `arm_key` kuralı yoktu (ortak vektör 44 -> 51), sunucu kopyasında kapı/hareket varsayılan bayrakları, "v1.3.0" sürüm metni.
  Doğrulama: server 2259 test 0 kırık (PG'siz 2103 geçti/156 atlandı; PG'li 2258/1 atlandı), qa_stack 595/595, firmware Unity 356/356
  (MSVC /W4, 0 uyarı), PlatformIO derlemesi 0 uyarı ve yayın paketiyle bayt bayt aynı, fabrika aracı 358, flutter analyze 0,
  flutter test +4492 0 kırık. Firmware DONANIMDA DOĞRULANMADI. Kalan: WP-N4 (gerçek FCM ağ geçidi, iOS entitlements), gerçek kartta
  deneme (sürüm notları "İlk kartta denenecekler" 1-10) + NVS ölçümü, iki davranış kararı (giriş yolu olmayan hareket sensörü dışarıda
  kurmayı engeller; v1.2.0'da tanımlı kapılarda giriş gecikmesi bayrağı yok -> anlık tetik).
- **2026-10-07 — Faz 2 karşıt inceleme düzeltmeleri TAMAM** (tasarım belgesi sonu "Faz 2 inceleme"; 2.4 ve 2.6 [x]; 2.5'in alarm kısmı
  bitti, iklim/senaryo girdisi yalnız `ContactBus` arabirimi olarak hazır, 3.2/5.2 ile tamamlanacak): G-1 bulut yolunun yetki sınırı
  (gaz vanası uzaktan açılabilir kılınamaz `gas_local_only` / `403 GAS_VALVE_LOCAL_ONLY`; kurulu kipte hırsız alarmı zayıflatılamaz
  `armed` / `409 INTRUSION_ARMED`; ortak vektörler 51 -> 68), RV-E2 giriş gecikmesi enerji kesintisinden sağ çıkar, RV-E3 anahtarlı kontak
  yalnız NC, R2 yankılı firmware'de rev çıkarımı yok, R3 yanıt durum yazımından sonra + uygulama bayat kopya planı göndermez, RG-1 rev
  gerileyince kopya güncellenir, RG-2 yapılandırma kuyruğu ayrı şerit, RG-3 desen sırasında bip yutulur. Ertelenen: RV-E4 (kurulu kipte
  sensör arızası; ürün kararı, köprü sürücüsüyle), RV-E5 ("follow" bölge iyileştirmesi). Migration yok. Firmware **1.2.1** paketi yeniden
  üretildi (ana imaj SHA-256 `abe7f685…f398`, uygulama `68f300a4…fd40`). Doğrulama: server 2270 test 0 kırık (PG'siz 2113 geçti/157
  atlandı; PG'li 2269/1 atlandı), qa_stack 603/603, firmware Unity 360/360 (MSVC /W4, 0 uyarı), PlatformIO temiz derleme 0 uyarı, fabrika
  aracı 358, flutter analyze 0, flutter test +4495 0 kırık. Firmware DONANIMDA DOĞRULANMADI ("İlk kartta denenecekler" 11-14 eklendi).
