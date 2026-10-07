# Güvenlik, İklim ve Senaryo Katmanları: Mimari ve İlk Modül (Su Baskını + Vana) Tasarımı

- Tarih: 2026-10-06
- Plan: `docs/superpowers/plans/2026-10-06-guvenlik-iklim-senaryo-katmanlari.md` (maddeler 1.1, 1.3, 2.1-2.3; kararlar K1-K5)
- Durum: TASARIM, revizyon 2. Kod yazılmadı. Uygulama, bölüm 7'deki iş paketleriyle yapılacak.
- Revizyon 2 (2026-10-06): üç bağımsız inceleme (emniyet/fail-safe, sözleşme/geriye uyum, gömülü kaynak/uygulanabilirlik) işlendi. Kabul edilen bulgular ilgili bölümlere yazıldı; bulgu kodları (ör. `[K-1]`, `[Y2]`, `[B8]`) metinde köşeli parantezle anılır. Reddedilen ya da kısmen kabul edilenler §8 "İnceleme kararları"ndadır.
- Kapsam: firmware (ESP32-S3 Waveshare 8DI-8RO), sunucu (`server/`), Flutter (`lib/`), QA simülatörü (`tools/qa_stack/sim`), sözleşme (`docs/CONTRACTS.md`).

**Yol kısaltmaları.** Firmware yolları `ev_otomasyon_servis_yazilimi/waveshare_s3_demo/src/` altındadır ve burada yalnız dosya adıyla yazılır (ör. `SmartAutomation.cpp:1154`). Sunucu yolları `server/src/` altındadır; migration'lar `server/migrations/` altındadır. Flutter yolları `lib/` ile başlar.

**Satır numaraları.** Satır numaraları bu klonun 2026-10-06 tarihli durumundan alındı. Bölüm 0'da işaretli olanlar ayrıca açılıp doğrulandı. Diğerleri teknik haritalardan geliyor; her iş paketi başlamadan önce yeniden doğrulanmalı.

---

## 0. Kodda doğrulanan dayanak noktaları

| Olgu | Yer |
|---|---|
| `RelayType` 0..3, `DIMode` 0..4, `RelayConfig`/`DIConfig`, NVS ad alanları `ahbu_cfg/ahbu_auto/ahbu_pos` | `SystemConfig.h:13-46` |
| `CmdType` (13 komut), `CmdSource {MQTT, WEB, CLI, DI, RULE}`, `DeviceCommand` | `DeviceCommand.h:15-39` |
| Açılışta tüm röleler KAPALI: önce `_want` temizlenir, ardından `TCA_WriteOutputs(0x00)` ve ek modülde `extAllOff` | `SmartAutomation.cpp:322-337`; ayrıca `WS_Relay.cpp:74-76` (`TCA9554PWR_Init(0x00,0x00)`) |
| `emergencyAllOff` her şeyi kapatır | `SmartAutomation.cpp:1074-1085` |
| Tur sırası `… checkDigitalInputs → stepOutputs …` | `SmartAutomation.cpp:1154-1155` |
| `handleDiEdge` tek kapıdır: `_diGate.sample` çağrılır, ardından `markChanged` | `SmartAutomation.cpp:803-810` |
| DiGate'te çocuk kilidi geçerli bir modda `dropped` döndürür; bilinmeyen modda hiçbir şey yapılmaz | `DiGate.h:104-121` |
| `publishSnapshot` değişimi `relayMask`'tan yapının sonuna kadar `memcmp` ile algılar | `SmartAutomation.cpp:1192-1225` (`:1218`) |
| `AutomationSnapshot` alanları | `SmartAutomation.h:63-77` |
| PubSubClient yalnız QoS 0 yayınlar | `MqttManager.cpp:621` (yorum), yayınlar `:622,806` |
| Komut bayrak maskesi `uint8_t` ve 8 bitin hepsi dolu | `MqttManager.cpp:31-38` |
| sys yükü `StaticJsonDocument<384>` | `MqttManager.cpp:904` |
| TCA yardımcıları: `TCA_WriteOutputs`, `TCA_ClearBits` (yalnız kapatma), `TCA_SetShutterPairs`, `TCA_Verify`; bit KURAN bir acil yardımcı yok | `WS_TCA9554PWR.h:46-72` |
| Köprü yalnız `state` ve `status` konularını işler | `server/src/mqtt_bridge.js:79` (regex), `:108` (`SUBSCRIPTIONS`) |
| Yerleşim çıkarıcı `v >= MIN_STATE_VERSION` koşulunu arar. `type` yalnız 4 değerden biri olabilir; bilinmeyen tip `null` döndürür. Röle satırındaki bilinmeyen ek alanlar yok sayılır | `server/src/utils/endpoint_layout.js:40,273-292` |
| `endpoints.type` CHECK kısıtı `light/shutter/impulse/plug` | `server/migrations/001_multi_tenant_schema.sql:78` |
| Son migration 032 | `server/migrations/032_local_key_pending.sql` |
| Native testler `-Isrc` ile derlenir; kaynaklar derlenmez (`test_build_src = no`) | `platformio.ini:37,74-82` |
| QA simülatöründe `SOURCES.json` anahtarları `src/<dosya>` biçimindedir | `tools/qa_stack/sim/fw/SOURCES.json` |
| Flutter'da yük üst sınırı 64 KB | `lib/services/ev_mqtt_service.dart:286,631` |
| `shutdownHandler` her `esp_restart`'ta `TCA_WriteOutputs(0x00)` yazar; `performRestart` önce `emergencyAllOff` sonra `ESP.restart` çağırır | `SmartAutomation.cpp:362-364,1112-1118` |
| `_restartPending` iken `executeCommand` durdurma dışındaki her komutu reddeder | `SmartAutomation.cpp:493-497` |
| `Relay_Init` `setup()`'ın ilk işidir ve `TCA9554PWR_Init(0x00,0x00)` yazar; `ConfigManager::begin` ondan sonra gelir | `main.cpp:38-42,66-67`; `WS_Relay.cpp:77` |
| `/api/system/reboot`, `/api/system/reset`, `/api/rs485/relay` `Access::KEYED` | `WebPortal.cpp:600-608` |
| Fabrika sıfırlaması `clearNamespace` ile ad alanlarını siler | `ConfigManager.cpp:346,384-386` |
| `DiGate` başlangıçta `stable_=false` | `DiGate.h:62-63` |
| sys yükü `cmd` anahtarıyla ayrıştırılır; sys dahil her yük 512 bayt sınırına önce takılır | `MqttManager.cpp:26,850-856,912-915` |
| `Buzzer_Open_Time(uint16_t, uint16_t)`: FIFO, iptal yok | `WS_GPIO.h:43`, `WS_GPIO.cpp:118` |
| **Kimlik türleri UUID**: `users`, `homes`, `devices`, `endpoints` | `server/migrations/001_multi_tenant_schema.sql:10,24,50,73` |
| `mqtt_acl` tablosunda benzersiz kısıt yok | `server/migrations/020_mqtt_credentials.sql:48-59` |
| Rol adları `super_user, service_user, service_session, owner, resident, guest`; `local_key` resident'ı kapsar | `server/src/utils/role_matrix.js:18-46` |
| Gece huzur özeti `type='light' AND current_state` sayar | `server/src/services/peace_snapshot.js:24,48` |
| QA smoke ve sim `v === 2` / `v: 2` bekler | `tools/qa_stack/lib/smoke.js:131`, `tools/qa_stack/sim/fw/mqtt_manager.js:387` |

---

## 1. Hedefler, kapsam dışı, K1-K5'in mimariye etkisi

### 1.1 Hedefler

1. **Su baskını algılanınca vana bulut olmadan kapanır.** Alarm kilitlenir (latched) ve NVS'e yazılır. Pano yeniden başlasa, fabrika ayarına dönse ya da yapılandırma bozulsa da vana kapalı kalır (§5.1.6). Gecikme hedefi kaynağa göredir `[O-6]`:
   - **Yerel DI (8DI) ve yerel röle:** onay penceresi dolduktan (varsayılan 1000 ms, §2.6) sonra en geç 1 loopTask turu + röle süresi.
   - **Ek modül DI'si ya da ek modül rölesi:** ek DI okuması coil okumasıyla dönüşümlüdür (`SmartAutomation_Rs485.cpp:236,250-254`), yazım hatasında geri çekilme 1,6 sn'ye çıkar (`SmartAutomation.cpp:958-960`). Hedef: modül yanıt verirken onay + 1,5 sn. Modül yanıt vermiyorsa sensör `ok=false` olur ve `sensor_fault` / `actuator_fault` üretilir (§2.5). Test ölçütü bu iki değer için ayrı ayrı ölçülür.
   - **Köprü sensörü:** onay + kuyruk boşaltma (1 tur) + yerel/ek röle süresi.
2. **Lamba ve panjur davranışı değişmez.** Eylemci ya da sensör yapılandırılmamış bir panoda (bugünkü tüm sahadaki panolar ve fabrika varsayılanı) her çıkış bit bit bugünkü gibi davranır. Kanıt ve test yükümlülüğü §2.9'dadır.
3. **Ortak sözleşme.** State `v:3`, `v:2`'nin katı bir üst kümesidir. Yeni komutlar ve `ev/{t}/event` konusu tanımlanır. Yerel HTTP API aynı JSON'u taşır (K5).
4. **Saf C++ çekirdekler.** Karar mantığı yalnız `<stdint.h>` kullanır ve `now_ms` parametresiyle çalışır. PC'de Unity ile test edilir. QA simülatörüne birebir port edilir ve sürüklenmeyi `fwcheck` denetler.
5. **Sonraki modüller aynı kalıba oturur.** Gaz/duman, kapı/pencere, iklim, enerji, varlık ve senaryo modülleri aynı `SensorSource → çekirdek → Actuator` hattını kullanır.

### 1.2 Kapsam dışı (bu tasarım turunda)

- Gaz eşiği, duman algılama ya da kalibrasyon kodu (K3: algılama sertifikalı dedektörün işidir).
- Zigbee/Thread hub'ının somut ürün ve taşıma seçimi. Yalnız `BridgeSensor` arayüzü ve sözleşmesi tanımlanır; hub seçimi açık sorudur (§7.2).
- Dimmer sürücüsü. K4'te yalnız sihirbaz sorusu, kayıt alanları ve "dimmer yoksa %N = aç" kuralı vardır.
- Termostat, enerji, varlık ve güneş modüllerinin ayrıntılı tasarımı (§6'da yalnız oturma kalıpları var).
- Gerçek push ağ geçidi (Firebase ve benzeri). Plan 2.6'ya kalır. Sunucu push yükü bu tasarımda tanımlanır.
- Plan 1.2'deki donanım eşleme kararı (hangi DI/röle). Kurulum sihirbazı bunu sahada seçtirir; fabrika varsayılanı eylemcisizdir.

### 1.3 Kararların mimariye etkisi

| Karar | Mimari etki |
|---|---|
| **K1** Röleyle sürülen her cihaz eylemci olabilir | `RelayType` enum'u **değişmez**. Eylemci ataması ayrı bir `ActuatorConfig` tablosunda tutulur (NVS `ahbu_safety`). State'te röle satırına yalnız `act` alanı eklenir, `type` aynı kalır. Gerekçe: E1. Sunucu bilinmeyen `type` görünce yerleşim eşitlemesini tümden durdurur (`endpoint_layout.js:288`); Flutter da `ReportedLayout`'u `null` yapar. Güvenlik eylemleri "mantıksal güvenli konum" üzerinden çalışır; röle seviyesi eylemcinin `close_mode` alanından çıkarılır (§2.4). |
| **K2** Kablolu ve köprülü sensör birlikte | `SensorSource` soyutlaması kurulur. `DiSensor` DiGate'in kararlı seviyesini okur; `BridgeSensor` ayrı bir kuyruktan rapor alır. İkisi de `SensorHub`'a aynı `SensorReport` yapısını verir. Güvenlik çekirdeği kaynağı bilmez; state'te yalnız `src: "di"|"bridge"` görünür. |
| **K3** Bağımsız dedektör | Gaz ve duman, su ile aynı ikili sensör modelini kullanır (`kind: gas|smoke`). Panoda eşik kodu yoktur. Tepki politikası (vana kes, siren, fan) yapılandırma tablosundan gelir. |
| **K4** Parlaklık sorusu | `LightOptions {dimmable, dimmer_src, dimmer_addr}` alanları NVS'te ve bulutta tutulur. Senaryo motoru `%N` için yetenek denetimi yapar ve dimmer yoksa "aç" uygular. Sihirbaz metni §4.5'tedir. |
| **K5** Buluttan bağımsızlık, varsayılanla | Bütün kararlar loopTask'ta panoda verilir. Yapılandırmanın asıl kaynağı panodaki NVS'tir; bulut yalnız kopyasıdır (§4.2). Yerel HTTP API'de her komutun karşılığı vardır. Fabrika varsayılanında `safety.policy = on` gelir; bir sensör su tipine atandığı anda tepki kendiliğinden devreye girer. Zamanlama için RTC↔SNTP işi gerekir (§2.8). |

---

## 2. Modüler firmware mimarisi (plan 1.1)

### 2.1 Dosya yapısı

`src/` bugün düz bir dizindir. Yeni modüller alt dizinlere girer. PlatformIO `src_dir = src` altını özyinelemeli derler. Native testler `-Isrc` ile `#include "safety/SafetyFsm.h"` biçiminde içerir (`platformio.ini:37,82`). `SOURCES.json` anahtarları da `src/safety/SafetyFsm.h` olur.

```
src/
  sensors/
    SensorTypes.h        SAF  SensorKind, SensorReport, SensorConfig (POD), sınırlar
    SensorHub.h          SAF  NC/NO çevirme, onay süzgeci, köprü kalp atışı, bölge ıslak maskesi
    DiSensor.cpp/.h      BAĞ  DiGate kararlı seviyesini SensorHub'a verir (loopTask)
    BridgeSensor.cpp/.h  BAĞ  köprü raporu kuyruğu (s_sensorQ, derinlik 16); hub sürücüsü sonra
  actuators/
    ActuatorTypes.h      SAF  ActuatorKind {VALVE, SIREN, FAN, GENERIC}, CloseMode, ActuatorConfig
    ActuatorMap.h        SAF  mantıksal → röle seviyesi, güvenli seviye maskesi, izin kuralları
  safety/
    SafetyConfig.h       SAF  bölge/politika yapısı, validate(), blob serileştirme + CRC32
    SafetyFsm.h          SAF  bölge durum makinesi (NORMAL / ALARM_LATCHED / VALVE_FAULT / TEST)
    SafetyManager.cpp/.h BAĞ  tick(now), SmartAutomation'a eylem uygulama, NVS kilit kaydı, olay üretimi
    SafetyStore.cpp/.h   BAĞ  NVS ad alanı "ahbu_safety"
  events/
    EventOutbox.h        SAF  halka tampon (sabit yapılı yuvalar), eid üretimi, yeniden deneme planı (5/10/20/40/60 sn)
    EventOutboxRtos.h    BAĞ  EventOutbox'ı mutex ile saran ince katman (üretici loopTask, tüketici MqttTask) [B16]
  climate/   Thermostat.h (SAF), ClimateManager.cpp (BAĞ)          [modül 3.x]
  energy/    EnergyMeter.h (SAF, Modbus sayaç ayrıştırma)           [modül 3.4]
  presence/  PresenceTimer.h (SAF)                                  [modül 4.2]
  scenes/    SceneEngine.h (SAF), SceneStore.cpp (BAĞ)              [modül 5.x]
```

SAF: saf C++. Yalnız `<stdint.h>`, `<string.h>` ve `<stddef.h>` kullanılır; Arduino, FreeRTOS ya da NVS yoktur; `now_ms` parametre olarak verilir ve `(uint32_t)(now - start) >= span` kuralı uygulanır (desen: `NetTime.h:6-15`). BAĞ: ince donanım ya da RTOS bağlayıcısı; karar içermez, yalnız SAF çekirdeği çağırır ve sonucu uygular.

### 2.2 Görev ve çekirdek yerleşimi

| Bileşen | Görev / çekirdek | Öncelik | Not |
|---|---|---|---|
| `SafetyManager::tick` (SensorHub ve SafetyFsm dahil) | **loopTask, Core 1** | 1 (mevcut) | `SmartAutomation::loop()` içinde `checkDigitalInputs` ile `stepOutputs` arasına girer (`SmartAutomation.cpp:1154-1155`). Böylece karar aynı turda sürücüye ulaşır. Yeni görev yok, ek yığın yok. loopTask zaten TWDT'ye kayıtlı (`main.cpp:86`). |
| ValveGuard (bağımsız emniyet) | **ShutterGuard görevine ek adım**, Core 0, 50 ms | 3 (mevcut) | Yeni görev açılmaz. ShutterGuard gövdesine (`SmartAutomation.cpp:89-126`) bir `guardSafeOutputs()` çağrısı eklenir. Görev zaten TWDT'ye abone. Garantileri yalnız **yerel 8 röle** içindir (§5.1.5) `[B7]`. |
| EventOutbox yayını | **MqttTask, Core 0** | 1 (mevcut) | `publishIfDue` yanına `publishEventsIfDue()` gelir (döngü `MqttManager.cpp:410-501`, 50 ms tick). |
| BridgeSensor sürücüsü (ileride) | Hub taşımasına göre: RS485'te loopTask'ta `pollExtModule` sonrası; UART veya LAN'da ayrı bir Core 0 görevi (öncelik 1, TWDT'ye abone, ShutterGuard deseni) | — | Raporlar `s_sensorQ` kuyruğuna yazılır, `SafetyManager::tick` kuyruğu boşaltır. |

**Neden ayrı bir SafetyTask yok?** Röle mutasyonlarının asıl hattı `executeCommand → _want → stepOutputs`'tur (`SmartAutomation.cpp:488-646, 872-956`). Bu hat **tek** değildir `[B2][Y-6]`: `rs485ControlExtRelay`, `/api/rs485/send`, `applyRawExtAllOff`, `syncConfig` (ek modül kapatma), `emergencyAllOff` ve `shutdownHandler` doğrudan donanıma ya da `_want`'a yazar. Bu yolların her biri §2.3 madde 4 ve §2.9'da ayrıca kapatılır; SafetyManager da kilitli eylemcilerin güvenli seviyesini her turda yeniden dayatır (§2.3 madde 2). Ayrı bir görev aynı dizilere kilitsiz erişemezdi; kilit eklemek de panjur interlock'unun dayandığı "tek yazıcı" varsayımını bozardı. loopTask bir yerde takılırsa TWDT 10 sn içinde panoyu sıfırlar (`main.cpp:56`). Açılışta kilitli alarm NVS'ten okunur (§5.1.6), dolayısıyla güvenli konum geri gelir. Bu 10 sn'lik pencereyi ValveGuard daraltır (§5.1.5).

### 2.3 SmartAutomation ile gevşek bağ

SafetyManager, SmartAutomation'ın iç dizilerine dokunmaz. Arada iki dar arayüz vardır.

1. **Komut yolu (giriş).** Kullanıcı ve uzak komutlar bugünkü gibi `postDeviceCommand` kuyruğuyla gelir. `drainCommands → executeCommand` yeni `CmdType` değerlerini SafetyManager'a yönlendirir: `ACTUATOR_SET`, `ALARM_ACK`, `ALARM_TEST`, `SAFETY_ARM`, `CLIMATE_TARGET`, `SCENE_RUN`. Yönlendirme `SafetyManager::handleCommand(cmd, now)` çağrısıyla yapılır; dönen değer kabul ya da ret kodudur.
2. **Eylem yolu (çıkış).** SafetyManager kendi kararını kuyruğa koymaz. Kuyruk dolarsa güvenlik eylemi kaybolur; DI'nin "kuyruk doluluğunda kaybolmaz" ilkesi bunu yasaklar. Bunun yerine `SmartAutomation::applySafetyOutput(relayIdx, level, now)` çağrılır. Bu dar ve **public** yöntem `executeCommand`'ı **kullanmaz** `[O-4][O5][B1]`: `executeCommand` `_restartPending` iken durdurma dışındaki her komutu reddeder (`SmartAutomation.cpp:493-497`) ve her yazımda `Buzzer_Open_Time(80)` bipini kuyruğa ekler (`:539,546`). `applySafetyOutput` doğrudan `_want[idx] = level` yazar; restart ve açılış-bekleme (boot-hold) kapılarından muaftır; bip üretmez. Fiziksel yazımı yine `stepOutputs` yapar (tek yazıcı ilkesi korunur).
   - **Her turda yeniden dayatma** `[O-3][B2]`. `SafetyManager::tick` yalnız geçişte değil, kilit sürdüğü **her turda** kilitli eylemcilerin `_want` değerini güvenli seviyeye yazar. Böylece `syncConfig`, `applyRawExtAllOff` ya da `emergencyAllOff` `_want`'ı sıfırlasa bile bir sonraki turda güvenli seviye geri gelir.
   - **Yeni kaynak `CmdSource::SAFETY`** `[Y-7]`. Yalnız `applySafetyOutput` bu kaynağı kullanır (`DeviceCommand.h:31` enum'una eklenir). `CmdSource::RULE` senaryo, varlık ve iklim motorlarına kalır ve eylemci rölesine **ham** erişim vermez; bu motorlar eylemciye yalnız `ACTUATOR_SET` ile gider, dolayısıyla açma izni denetiminden geçer.
3. **Olay yolu.** SafetyManager olayları `EventOutbox`'a yazar. Saf `EventOutbox.h` mutex içermez; mutex `EventOutboxRtos.h` sarmalayıcısındadır `[B16]`. Üretici loopTask, tüketici MqttTask'tır. Durum değişimleri `markChanged()` ve `AutomationSnapshot` üzerinden bugünkü state yayınına akar.
4. **Eylemci rölesine ham komut kuralı.** Koşul **yöne** bakar `[O4][B15]`:
   - `executeCommand`'ın RELAY_SET/TOGGLE dalının (`SmartAutomation.cpp:540-544`) başında: röle `_actuatorMask` içindeyse ve istenen seviye eylemcinin **güvenli seviyesi** (vana: kapalı; siren/fan/generic: kapalı) değilse → ret `actuator_relay`. Güvenli yöne giden ham komut (duvar butonu, CLI, LAN `/api/relay` ile vanayı **kapatmak**, sireni **susturmak**) serbesttir ve SafetyManager'a "kullanıcı kapattı" olarak bildirilir (`act_pos` güncellenir). TOGGLE yalnız sonucu güvenli yöne gidiyorsa kabul edilir.
   - **Duvar butonu (DI) eylemci rölesine eşlenmişse** `runDiDecision` komutu `RELAY_SET` yerine `ACTUATOR_SET` olarak üretir (`SmartAutomation.cpp:842-850`); açma isteği böylece açma izni denetiminden geçer.
   - **Ham RS485 yolları** `[B2][Y-6]`: `rs485ControlExtRelay` (`SmartAutomation_Rs485.cpp:516-574`; `/api/rs485/relay`, CLI `CH`) ve `/api/rs485/send` (`:454-489`) eylemci kanalına giden **açma** yazımını yazmadan önce reddeder (`extChannelIsShutter` reddi deseni). Ham çerçevede hedef coil çözülemiyorsa ve ek modülde eylemci varsa yazım `actuator_relay` ile reddedilir.
   - `applyRawExtAllOff` (`:494-510`) ve `syncConfig` (`SmartAutomation.cpp:400-415`) dokunulmadan kalır; her turda yeniden dayatma (madde 2) etkilerini ilk turda geri alır. `syncConfig`'in ek modülü kapatması ise madde 5'teki çapraz doğrulamaya takılır.
   - `_actuatorMask == 0` olduğunda hiçbir koşul tutmaz.
5. **Ana yapılandırma yolu ile çapraz doğrulama** `[B3][Y-6][O-10]`. `applyConfigOnLoop` (`WebPortal.cpp:448-470`) ve `/api/config` kaydı (`:1178,1206-1232`) yazımdan önce `SafetyConfig::validate(liveSystemConfig, safetyConfig)` çağırır. Şunlar denetlenir: eylemci rölesinin tipi panjur/IMPULSE'a çevrilmesin; `ext_module_enabled/channels` değişimi eylemci rölesini ya da sensör/geri bildirim DI'sini `totalRelays`/`totalDIs` dışına düşürmesin; sensör DI'si duvar butonu yapılmasın. Kilitli ya da arızalı bölgeye dokunan değişiklik `409 zone_latched`; kilit yokken geçersiz bileşim `409 cfg_invalid` ile reddedilir. Yapılandırmaya bağlı olarak erişilemez kalan eylemci için `actuator_fault` olayı üretilir.
6. **Görevler arası okuma** `[B13]`. `SafetyConfig` RAM kopyası kendi mutex'i (`SafetyCfgLock`, `ConfigLock` deseni `MqttManager.cpp:706-713`) arkasındadır. Yazıcı yalnız loopTask'tır (`applySafetyConfigOnLoop`). MqttTask ve WebTask ad ve yapılandırma alanlarını bu kilit altında yerel bir görünüme kopyalar (`takeCfgView` deseni, `WebPortal.cpp:885`); kilit altında JSON üretilmez. Durum alanları (aktif, konum, bölge durumu) ise `AutomationSnapshot`'tan okunur.

### 2.4 Eylemci soyutlaması (K1)

```cpp
// actuators/ActuatorTypes.h (SAF)
enum class ActKind : uint8_t { VALVE = 1, SIREN = 2, FAN = 3, GENERIC = 4 };
enum class CloseMode : uint8_t {    // yalnız VALVE için anlamlı
  ENERGIZE_TO_CLOSE   = 0,          // röle AÇIK = vana kapalı (NO selenoid / motorlu vana kapama hattı)
  DEENERGIZE_TO_CLOSE = 1           // röle KAPALI = vana kapalı (NC selenoid: enerji kesilince kapanır, "fail-safe")
};
enum class Medium : uint8_t { NONE = 0, WATER = 1, GAS = 2 };   // yalnız VALVE: vananın kestiği akışkan [K-3]
struct ActuatorConfig {             // 32 B, NVS blob dizisinin bir öğesi
  uint8_t  relay;                   // 1 tabanlı röle (0 = boş satır)
  uint8_t  kind;                    // ActKind
  uint8_t  close_mode;              // CloseMode
  uint8_t  fb_di;                   // geri bildirim DI'si, 1 tabanlı (0 = yok)
  uint8_t  fb_closed_active;        // 1: DI aktifken (kontak kapalı) vana kapalı demektir
  uint8_t  zone_mask;               // bit z = bölge z+1 (en çok 4 bölge)
  uint16_t fb_timeout_s;            // geri bildirim beklemesi (vars. 60; selenoid için 5 yeterli)
  uint16_t run_limit_s;             // SIREN/FAN için en uzun çalışma. TEK KAYNAK [D-2]; siren 10..1800, 0 reddedilir
  uint8_t  medium;                  // Medium (VALVE için zorunlu: WATER ya da GAS)
  uint8_t  aflags;                  // bit0 FAN: ex-proof/ATEX onayı (gaz alarmında açılabilir) [Y-1]
  char     name[20];
};
```

- **Akışkan ve tepki eşlemesi** `[K-3]`. Politika bölge içinde **tür → akışkan** eşlemesiyle vana seçer: `water` sensörü yalnız `medium=WATER` vanaları, `gas` sensörü yalnız `medium=GAS` vanaları kapatır; `smoke` **hiçbir vanayı** kapatmaz (yangında su hattı, yangın hortumu ve sprinkler açık kalmalı). Varsayılan tek bölge "Ev" olsa da su baskını gaz vanasını, duman su vanasını kesmez.
- **Gaz vanası kuralları** `[K-4]`:
  - **Açma yalnız yerinde ve fiziksel onayla.** Gaz vanasına `open` yalnız şu yollardan biri ile gelir: (a) sensör tablosunda `kind=gas_reset` olarak atanmış panodaki/vana yanındaki bir DI butonu, (b) mekanik elle kurmalı (manuel reset) vana kullanılıyorsa röle zaten açma yapmaz. MQTT, LAN API, CLI ve senaryolardan gelen gaz vanası `open` isteği `gas_local_only` ile reddedilir. Kapatma her yoldan serbesttir.
  - **Test bitince kapalı kalır.** TEST → NORMAL geçişinde gaz vanası önceki konuma dönmez.
  - **Açılışta her zaman kapalı.** `act_pos` gaz vanaları için okunmaz; açılış maskesi gaz vanasını daima güvenli (kapalı) seviyeye koyar. Sihirbaz bunun sonucunu yazar: "Her elektrik kesintisinden sonra gaz vanasını yerinde düğmeyle açmanız gerekir."
- **Fan ve gaz** `[Y-1]`. Fabrika varsayılanında gaz alarmı fanı **açmaz** (röle kontağı ve fırçalı motor tutuşturma kaynağıdır). Fan, gaz alarmında yalnız `aflags.bit0` (kurulumcunun "fan ex-proof/ATEX" onayı) işaretliyse açılır. Duman alarmında fan **kapatılır**. Sihirbaz gaz bölgesindeki siren ve fan röleleri için "röle ve cihaz gaz kaçağı bölgesinin dışında olmalı" uyarısı gösterir.

- **Mantıksal durum ile röle seviyesi ayrımı.** Çekirdek "vana KAPALI olsun" der. `ActuatorMap::relayLevelFor(cfg, closed)` bunu `ENERGIZE_TO_CLOSE` için `true`, `DEENERGIZE_TO_CLOSE` için `false` yapar. SIREN, FAN ve GENERIC'te "güvenli/etkin" doğrudan röle AÇIK demektir.
- **Sürüş.** Bu turda yalnız **sürekli (level)** sürüş vardır. Tek röleli 3 telli motorlu vanalar (COM → ortak uç, NO → kapat, NC → aç) ve selenoidler bu kipte çalışır. K1'deki "darbe" kipi iki röle (aç ve kapat) ister ve panjur çiftine benzer bir interlock gerektirir. Bu kip §7.2'de açık soru olarak bırakıldı; sözleşmede `drive` alanı yer tutucu olarak tanımlıdır.
- **Doğrulama (`SafetyConfig::validate(system, safety)`).** Eylemci rölesi panjur çiftinde olamaz (`RELAY_TYPE_SHUTTER_*` reddedilir) ve IMPULSE olamaz. `fb_di` hem sensör hem duvar butonu olarak kullanılamaz. Aynı röle iki eylemciye atanamaz. VALVE'da `medium` WATER ya da GAS olmalıdır. SIREN'de `run_limit_s` 10..1800 olmalıdır; 0 reddedilir `[D-2]`. Gaz ya da duman sensörü `active_open=1` (NC) olmalıdır `[O-2]`. Eylemci ve sensör DI'leri `system.totalRelays()`/`totalDIs()` içinde kalmalıdır `[B3]`. En çok 16 eylemci ve 4 bölge vardır. Validate hem güvenlik yapılandırması hem ana yapılandırma (`/api/config`) değişiminde çağrılır (§2.3 madde 5).

### 2.5 Sensör soyutlaması (K2)

```cpp
// sensors/SensorTypes.h (SAF)
enum class SensorKind : uint8_t { WATER = 1, GAS = 2, SMOKE = 3, DOOR = 4, WINDOW = 5, MOTION = 6, GENERIC = 7,
                                  // Güvenlik DI rolleri (sensör değil, yerel kumanda) [B15][K-4]:
                                  ALARM_ACK = 16, VALVE_CLOSE = 17, GAS_RESET = 18 };
enum class SensorSrc  : uint8_t { DI = 0, BRIDGE = 1 };
struct SensorConfig {               // 28 B
  uint8_t  src, index;              // DI: 1..40 (DI no) | BRIDGE: 1..16 (köprü yuvası)
  uint8_t  kind, zone;              // zone 1..4
  uint8_t  active_open;             // 1: NC kontak (kontak AÇILINCA aktif). Gaz/duman için zorunlu [O-2]
  uint8_t  flags;                   // bit0 tepki etkin, bit1 sabotaj/hat izleme (ileride), bit2 arızada kapat
  uint16_t confirm_ms;              // onay penceresi içinde gereken toplam aktif süre (vars.: su 1000, gaz/duman 300, kapı 0)
  char     name[20];
};
struct SensorReport { uint8_t slot; bool active; bool ok; uint32_t at_ms; };
```

- **Güvenlik DI rolleri** `[B15]`. Buluttan ve yerel anahtardan bağımsız yerel kumanda için üç DI rolü vardır: `ALARM_ACK` (sireni sustur / kuruyken kilidi kaldır, bölge = `zone`, 0 = tümü), `VALVE_CLOSE` (bölge vanalarını kapat) ve `GAS_RESET` (yerinde gaz vanası açma, §2.4). Bunlar `DIMode`'a değil sensör tablosunun `kind` alanına girer; böylece DiGate ve `static_assert` (`SmartAutomation.cpp:797-799`) korunur. Kenarda (kararlı seviye pasif→aktif) bir kez tetiklenir. Duvar butonu kararına girmezler (aşağıdaki "DI yolundan ayırma").
- **`DiSensor`.** DiGate 60 ms'lik süzgeci zaten uygular (`DiGate.h:60,76-87`). `DiSensor`, `_diGate.stable(i)` sonucunu her turda okur ve `active_open` ile çevirir. **Kenar değil seviye** kullanılır: kaçırılmış kenar ya da açılıştaki "ilk okuma kenar üretmez" kuralı (`SmartAutomation_Rs485.cpp:288-295`) sensörü kör bırakmaz.
- **Sensör sağlığı (`ok`)** `[Y-2][B6]`. `DiGate` başlangıçta `stable_=false` ("kontak açık") değeriyle başlar (`DiGate.h:62-63`); NC sensör bu değeri "aktif" okurdu. Bu yüzden:
  - **Yerel DI:** `ok` ilk DI okuma turu tamamlanana kadar `false`, sonra `true`.
  - **Ek modül DI:** `ok = ext_enabled && _extDiInit && _extModuleResponding && !scanning`. Modül 3 hatada "yanıt vermiyor" olunca (`SmartAutomation_Rs485.cpp:241-256`) ya da RS485 taraması sürerken (`:228`) değer donar; `ok=false` bu donmuş değerin kullanılmasını engeller.
  - **Köprü:** kalp atışı süresi (aşağıda).
  - **`ok=false` sensör bilinmeyendir:** ne ıslak ne kuru sayılır. Islaklık maskesine girmez, kuruluk sayacını **durdurur** (bölge kuruyamaz, kilit kalkamaz, vana açılamaz) `[Y-3]`. `ok` true→false geçişinde `sensor_fault`, geri dönüşte `sensor_fault_cleared` olayı üretilir. `flags.bit2` ("arızada kapat") işaretliyse arıza, vana kapatmayı tetikler; varsayılan su için 0, gaz için 1, duman için 0.
- **MOMENTARY artığı** `[B17]`. Bir DI sensör maskesine alınırken `_diGate.clearActed(i)` ve `momentary_` biti temizlenir; aksi halde bırakma kenarı `_sensorDiMask` yüzünden işlenmez ve önceki eşlemenin rölesi açık kalabilir (`DiGate.h:105-125`, `SmartAutomation.cpp:810`). Birim testi WP-F1'dedir.
- **DI yolundan ayırma.** `handleDiEdge` içinde `markChanged()` çağrısından hemen sonra (`SmartAutomation.cpp:810`) tek satır eklenir: `if (_sensorDiMask & bit(idx)) return;`. Böylece sensör ve geri bildirim DI'leri duvar butonu kararına (`runDiDecision`) hiç girmez, çocuk kilidinin `dropped` yutmasından da etkilenmez (`DiGate.h:110`). `DIMode` enum'u ve DiGate değişmez; ad uyumunu koruyan `static_assert` (`SmartAutomation.cpp:797-799`) da aynı kalır. `_sensorDiMask == 0` olduğunda koşul hiç tutmaz.
- **`BridgeSensor`.** Hub sürücüsü (taşıması sonra seçilecek) her rapor için `SensorReport` yapısını `xQueueSend(s_sensorQ, …, 0)` ile kuyruğa koyar. `SafetyManager::tick` turun başında kuyruğu boşaltır. Kuyruk dolarsa rapor düşer, ama sensör seviye tabanlı olduğu için bir sonraki rapor durumu düzeltir. Her yuva için kalp atışı süresi tanımlıdır (vars. 15 dk). Süre aşılırsa `ok=false` olur ve bölgeye `sensor_fault` uyarısı düşer; politika aksini söylemedikçe vana eylemi yapılmaz.
- **SensorHub çıktısı.** Her bölge için `activeMask[kind]`, `faultMask` ve "bölgedeki **bütün** sensörler en az `dry_hold_ms` süredir `ok && !active`" bilgisi. Güvenlik çekirdeği yalnız bu özeti görür.

### 2.6 Debounce kararı

İki katman var:

1. DiGate'in mevcut 60 ms kararlılık süzgeci (dokunulmaz).
2. SensorHub'da türe göre **pencereli birikim** `[O-1]`: kayan 3 sn'lik pencerede toplam aktif süre ≥ `confirm_ms` (su 1000 ms) olunca sensör onaylı aktif sayılır. Kesintisiz süre şartı aranmaz; damlayan suda aç/kapa olan sensör de birikimle onaya ulaşır. Tek bir kısa sıçrama (temizlik bezi) birikimi doldurmaz. Gaz/duman için pencere 1 sn, `confirm_ms` 300.

Kuruma tarafında, alarmın çözülebilmesi için `dry_hold_ms` (vars. 10 sn) boyunca kesintisiz `ok && !active` okuma gerekir. Arada bir aktif ya da `ok=false` okuma sayacı sıfırlar.

### 2.7 NVS bütçesi

- **İki yeni ad alanı** `[Y-5][Y4][B4]`. `SystemConfig.h:44-46` desenine eklenir.
  - `NVS_NS_SAFETY "ahbu_safety"` (11 karakter; NVS sınırı 15): yapılandırma. Fabrika sıfırlamasındaki `clearNamespace` listesine konur (`ConfigManager.cpp:384-386`).
  - `NVS_NS_LATCH "ahbu_latch"` (10 karakter): kilit kaydı, açılış sayacı, son komut konumu ve siren süre birikimi. **Fabrika sıfırlaması bu ad alanını silmez.** Kilit sıfırlamadan, yapılandırma bozulmasından ve yapılandırma silinmesinden sağ çıkar; kilidi yalnız ACK + kuruluk ya da güvenli kipteki yerel zorlamalı onay (§5.1.6) kaldırır.
- **Neden mevcut yapılara alan eklenmiyor?** `RelayConfig`/`DIConfig`'e alan eklemek `SystemConfig`'i büyütürdü. Bu yapının RAM kopyaları var (`WebPortal.cpp:461-462,1188`). Yapıyı değiştirmek aynı zamanda lamba/panjur yapılandırma yolunu değiştirmek olurdu.

| Ad alanı / anahtar | Tür | Boyut | Yazım sıklığı |
|---|---|---|---|
| `ahbu_safety/ver` | u8 | 1 | şema sürümü (1) |
| `ahbu_safety/rev` | u32 | 4 | her yapılandırma değişiminde +1 (§4.2) |
| `ahbu_safety/pol` | blob | 16 | politika: `policy_on`, `dry_hold_ms`, bayraklar (siren süresi buradan **kaldırıldı**, tek kaynak `run_limit_s`) `[D-2]` |
| `ahbu_safety/zones` | blob | 4 × 16 = 64 | bölge adları ve bayrakları |
| `ahbu_safety/sens` | blob | kullanılan yuva × 28 (+4 CRC), en çok 56 × 28 | yalnız dolu yuvalar yazılır `[B9]` |
| `ahbu_safety/act` | blob | kullanılan × 32 (+4 CRC), en çok 16 × 32 | eylemciler |
| `ahbu_safety/light` | blob | 40 × 4 = 160 | K4: `dimmable`, `dimmer_src`, `dimmer_addr` |
| `ahbu_latch/latch` | blob | 4 × 32 + maske bloğu 32 = 160 (+4 CRC) | bölge başına: durum, tür, `aid[15]` `[B16]`, `since_epoch`, `silenced`; ayrıca **o anki güvenli röle maskeleri** (`safeAssertMask`/`safeLevelMask`, yerel ve ek; §5.1.6) `[Y-4]`. **Yalnız geçişte yazılır** |
| `ahbu_latch/act_pos` | u16 | 2 | eylemci başına son komut konumu (1 = açık). Kullanıcı eyleminde **ve güvenlik kapatmasında** yazılır `[K-1][B9]` |
| `ahbu_latch/bootc` | u32 | 4 | açılış sayacı (`boot` alanı, çökme döngüsü tespiti) |
| `ahbu_latch/crash` | blob | 8 | son N açılışın zamanı/nedeni (§5.1.6 güvenli kip) `[O-8]` |
| `ahbu_latch/siren_s` | u16 | 2 | kilit başına siren toplam çalma süresi; çalarken 30 sn'de bir yazılır `[O-8]` |
| `scn` / `thermo` | blob | ileride | §6 |

- **Toplam (yeni).** Tam dolu yapılandırmada ~2,6 KB veri. Blob başına girdi ek yükü ve 32 baytlık girdilerle yaklaşık **95-100 girdi**.
- **Bölüm doğrulaması.** Standart `app3M_fat9M_16MB.csv` tablosunda NVS 0x5000 (20 KB) olarak tanımlıdır. **Düzeltme** `[B9]`: sayfa başına 126 girdi vardır ve 5 sayfadan biri çöp toplama için boş tutulur; kullanılabilir alan ~**504 girdi**dir (önceki "640" yanlıştı). CSV klonda yok (kart paketinden geliyor); WP-F0'da doğrulanır.
- **Mevcut kullanım (düzeltilmiş tahmin)** `[B9]`. Röle ve DI başına anahtarlar (`ConfigManager.cpp:184-202`, `r_nm_/r_tp_/r_rt_/d_*`); 80 ad dizge olarak tutulur ve dizge başına başlık + veri ≈ 2 girdi (~160). Buna ~160 sayısal anahtar, kimlik alanları, `ahbu_net` (`WiFiManager.cpp:137`) ve PHY kalibrasyon blob'u eklenir: kabaca **350-400 girdi**. Yeni ~100 girdiyle doluluk %90'a yaklaşabilir; o noktada çöp toplama yapılamaz ve `latch` yazımı `ESP_ERR_NVS_NOT_ENOUGH_SPACE` ile düşebilir.
- **WP-F0 ölçümü ve kabul eşiği.** Tam dolu bir yapılandırma (40 röle, 40 DI, en uzun adlar, 56 sensör, 16 eylemci) yazılıp `nvs_get_stats` ile ölçülür. Kabul eşiği: **kullanılan ≤ %60**. Aşılırsa iki seçenek sırayla denenir: (1) röle/DI adlarını tek blob'a toplamak (ana yapılandırma yolu değişir, ayrı iş paketi), (2) özel bölüm tablosuyla NVS'i büyütmek (OTA ile değiştirilemez; yalnız seri yüklemede). Ayrıca `latch` yazımı başarısızsa `nvs_fail` olayı ve state'te uyarı üretilir (§5.1.6 madde 7).
- **Yıpranma.** Kilit kaydı yalnız alarm geçişlerinde, `act_pos` kullanıcı eyleminde ve güvenlik kapatmasında, `siren_s` yalnız siren çalarken 30 sn'de bir yazılır. Yapılandırma yalnız kurulumda değişir.

### 2.8 Bellek bütçesi

| Kalem | Yer | Boyut |
|---|---|---|
| `SafetyConfig` RAM kopyası (sens, act, zones, pol, light) | statik (`.bss`) | ~2,4 KB |
| SensorHub çalışma durumu (56 yuva × 12 B) | statik | ~0,7 KB |
| SafetyFsm (4 bölge × 32 B) + ActuatorMap durumu (16 × 12 B) | statik | ~0,3 KB |
| EventOutbox (16 olay × sabit yapı ~96 B: tür, bölge, `srcs[8]` yuva no, `actions[16]` bit maskesi, zaman, eid) `[Y6]` | statik | ~1,5 KB |
| `/api/events` LAN halkası (32 × ~96 B) `[B16]` | statik | ~3 KB |
| `cfg_dump` geçici arabelleği (outbox dışında, onaysız, parça ≤ 3,5 KB) `[Y6]` | MqttTask içinde geçici `malloc`, iş bitince serbest | 3,5 KB (yalnız döküm sırasında) |
| `s_sensorQ` (16 × 8 B) | FreeRTOS heap | ~0,2 KB |
| `AutomationSnapshot` ek alanları (§3.2'deki özet: 56 sensör × 2 B, 16 eylemci × 4 B, 4 bölge × 20 B, `last_rej` 28 B) | yığın kopyası | ~0,3 KB |

**loopTask yığını.** `publishSnapshot` her turda yığında tam bir `AutomationSnapshot next` kurar (`SmartAutomation.cpp:1195-1196`). Snapshot ~0,3 KB büyüyeceği için `next` statik bir sınıf üyesine taşınmalı. Bu taşıma yalnız loopTask'ta yapılır, `_snap` kopyası mutex altında kalır. CLI `STATUS` loopTask'ın yüksek su işaretini de göstermeli (`main.cpp:159-160` deseni).

**MqttTask** `[B12]`. Önceki "~9 KB" tahmini düşüktü: adlarla birlikte tam dolu yük 12-14 KB tutar (56 sensör × ~110 B, 40 röle × ~80 B, 16 eylemci × ~130 B) ve `publishState` aynı anda `DynamicJsonDocument`, `malloc(len+1)` ve kalıcı büyüyen PubSubClient arabelleğini tutar (`MqttManager.cpp:699-730,784-797`); tepe ≈ 3 × yük. Karar:
- **Sensör, eylemci ve bölge adları state'e yazılmaz.** State yalnız kimlik ve durum taşır; adlar `cfg_dump` (bulut, `device_configs` kopyası) ve `GET /api/safety/config` (LAN) üzerinden gelir. Röle adları `v:2`'de olduğu gibi kalır.
- Yeni tahmin: sensör ~45 B, eylemci ~70 B, bölge ~90 B → ek yük tam dolu kurulumda ~4 KB, toplam ~7-8 KB.
- `cap` formülü (`MqttManager.cpp:725-728`) yeni dizilerle güncellenir. WP-F4 kabul ölçütü: tam dolu yapılandırmada yük boyutu ve `ESP.getMinFreeHeap()` tepe ölçümü kaydedilir; en düşük boş heap ≥ 40 KB.
- `sendFullStatus` (`WebPortal.cpp:879-905`) aynı yükü WebTask'ta ikinci kez üretir; o da adsız biçimi kullanır.

**Flash.** Uygulama bölümü 3 MB; mevcut `.bin` 1 787 376 B (`Firmware/ESP32-S3-POE-ETH-8DI-8RO.bin`). Yeni modül için risk düşük; WP-R'de boyut kaydedilir `[B16]`.

### 2.9 Mevcut lamba/panjur yolunun değişmediğinin kanıtı

Her değişiklik bir maske ya da sayaç arkasındadır. Eylemci ve sensör tablosu boşken (fabrika varsayılanı ve bugünkü saha) her koşul yanlıştır:

| Dokunulan yer | Değişiklik | Boş yapılandırmada etki |
|---|---|---|
| `executeCommand` RELAY dalı (`SmartAutomation.cpp:540-544`) | `_actuatorMask & bit` ve güvenli yön değilse ret | `_actuatorMask = 0`, dal hiç tutmaz |
| `handleDiEdge` (`:810` sonrası) | `_sensorDiMask & bit` ise dön | `_sensorDiMask = 0`, dal hiç tutmaz |
| `runDiDecision` (`:842-850`) | eylemci rölesine eşli DI → `ACTUATOR_SET` | maske 0 |
| `Relay_Init` (`WS_Relay.cpp:77`) | `TCA9554PWR_Init(0x00,…)` yerine `ahbu_latch`'ten okunan yerel güvenli maske `[K-2][Y-4]` | kilit kaydı yok → maske 0, aynı çağrı |
| Açılış (`:322-337`) | `TCA_WriteOutputs(0x00)` yerine `TCA_WriteOutputs(safeBootMaskLocal)`; ek modülde `extAllOff` yerine maske | `safeBootMaskLocal = 0`, aynı çağrı |
| `emergencyAllOff` (`:1074-1085`) | `_want[i] = safeLevel(i)` **ve** donanıma doğrudan yazılan `TCA_WriteOutputs(0x00)`/`extAllOff()` yerine güvenli maske `[B1]` | `safeLevel` her röle için `false`, maske 0: aynı |
| `shutdownHandler` (`:362-364`) | `TCA_WriteOutputs(0x00)` yerine `TCA_WriteOutputs(g_safeLevelMask & g_safeAssertMask)` (yalnız kapatır, güvenli bitleri korur) `[K-2][B1]` | maske 0, aynı çağrı |
| `_restartPending` dalı (`:1136-1146`) | `checkDigitalInputs` ve `_safety.tick` bu dalda da çalışır `[O-4][B1]` | sensör yok → O(1) |
| `rs485ControlExtRelay`, `/api/rs485/send` (`SmartAutomation_Rs485.cpp:454-574`) | eylemci kanalına açma yazımı reddi `[B2]` | maske 0 |
| `/api/config` kaydı, `applyConfigOnLoop` (`WebPortal.cpp:448-470,1206-1232`) | `SafetyConfig::validate` çapraz denetimi `[B3]` | boş güvenlik yapılandırmasında her zaman geçer |
| RS485 taraması (`tryEnterScan`, `SmartAutomation_Rs485.cpp:598-608`) | kilitli bölge varsa ya da ek modülde eylemci/güvenlik sensörü varsa ret `[O-5][B6]` | eylemci/sensör yok → bugünkü gibi |
| `/api/system/reboot`, `/api/system/reset`, CLI `REBOOT` (`WebPortal.cpp:1590-1618`, `main.cpp:542-544`) | kilit varken `409 zone_latched`, `force=1` / `REBOOT FORCE` ile geçilir `[K-2]` | kilit yok → bugünkü gibi |
| ALL_LIGHTS_OFF (`:582-589`) | eylemci röleleri atlanır | maske 0 |
| CLI `RELAY ALL ON` (`main.cpp:263`) | eylemci röleleri atlanır | maske 0 |
| Tur (`:1154-1155` arası) | `_safety.tick(now)` | sensör yoksa erken dönüş: O(1) |
| ShutterGuard (`:89-126`) | `guardSafeOutputs()` | `safeAssertMask = 0` ise erken dönüş |
| `publishSnapshot` | yeni alanlar sona eklenir; zamanla değişen alanlar (`since_up`, kuruluk süresi, siren sayacı) `memcmp` bölgesinin **dışında** tutulur `[B14]` | alanlar sıfır, `memcmp` sonucu bugünkü gibi |
| `publishState` | `v:3`; `caps`, `boot`, `time_ok` her zaman; modül dizileri yalnız yapılandırılmışsa | **`v:2` alanları birebir aynı; ek anahtarlar yalnız `caps`, `boot`, `bn`, `time_ok`, `epoch`** `[B14]` |
| Sunucu `peace_snapshot.js:24,48`, `device_service.js:1888-1896`, `peace_service.js:365-398` | açık lamba sayımı ve "hepsini kapat" `actuator_type IS NULL` koşulu alır `[Y3]` | kolon NULL → bugünkü sonuç |
| Sunucu `scheduler.js:29-30,565-567` | `actuator_type` dolu kanala bağlı kural kapatılır, `_checkTarget` reddeder `[O6]` | kolon NULL → bugünkü gibi |

**Test yükümlülüğü (WP-F2 kabul ölçütü)** `[B8]`:

- Mevcut tüm native Unity testleri (ShutterFsm 37, DiGate 23, RelayRules 27, SystemConfig 19, ModbusRtu 17, NetTime 27, CliParse 14, ApAccess 15) **değiştirilmeden** geçmeli.
- QA'daki `fw_*.test.js` ve `sim_automation.test.js` testleri değiştirilmeden geçmeli. **İstisna** `[O8]`: `tools/qa_stack/lib/smoke.js:131` (`st.v === 2`) `st.v >= 2` yapılır ve `sim/fw/mqtt_manager.js:387` `v: 3` olur; bu iki değişiklik WP-F4'ün sim portundadır.
- "Eşdeğerlik" testi (`sim_safety_equivalence.test.js`) F2'nin kabul ölçütüdür (F1'de SmartAutomation kancası yoktur). Kaydedilmiş bir komut ve DI dizisini boş güvenlik yapılandırmasıyla ve güvenlik katmanı hiç yokken çalıştırır; `_want`/`_hw` izlerinin bit bit aynı olduğunu doğrular.

---

## 3. Ortak payload sözleşmesi (plan 1.3; CONTRACTS'a yeni §2.6)

### 3.1 Sürüm kuralları

1. **`v:3`, `v:2`'nin katı üst kümesidir.** `v:2`'deki her alan aynı ad, tür ve anlamla kalır; `v` değeri 3 olur. Yapılandırılmamış panoda ek olarak yalnız `caps`, `boot`, `bn`, `time_ok`, `epoch` yazılır `[B14]`. Tüketiciler `v === 2` değil `v >= 2` denetlemelidir `[O8]`.
2. **Yeni alanlar isteğe bağlıdır.** Tüketici bilmediği alanı yok saymalıdır. Bugün böyle davranıyorlar:
   - Köprü: `validateStatePayload` bilinmeyen alanları yok sayıyor (`mqtt_bridge.js:166-245`).
   - Yerleşim çıkarıcı: `v >= 2` koşulunu arıyor, röle satırlarındaki ek alanları yok sayıyor (`endpoint_layout.js:275,284-292`).
   - Flutter: `DeviceStatus` `v` alanını okumuyor (harita: `endpoint_sync.dart:178`).
3. **Modül yapılandırılmamışsa ilgili anahtar YAZILMAZ.** `sensors`, `actuators` ve `safety` yalnız en az bir sensör ya da eylemci varsa yazılır; `climate` ve `energy` de ancak ilgili modül varsa. `caps` her zaman yazılır.
4. **`caps`: panonun desteklediği yetenekler** (ör. `["safety","actuator","event","cfg"]`). Sunucu ve Flutter yeni bir komutu ancak ilgili yetenek ilan edildiyse gönderir.
5. **Eski firmware ile karşılaşma.**
   - `v:2` ya da `caps` yok → sunucu panoyu "güvenlik desteklemiyor" sayar. Yeni komut uçları `409 FIRMWARE_UNSUPPORTED` döner, alarm satırı açılmaz.
   - Sunucu bu kararı vermek için `caps`'i saklar: köprünün `validateStatePayload`'ı (`mqtt_bridge.js:166-245`) `caps`, `safety`, `last_rej`, `bn`, `boot` alanlarını da çıkarır; `_processState` (`:1110-1135`) bunları 033'te eklenen `devices.caps JSONB` ve `devices.safety_state JSONB` kolonlarına yazar `[O1]`.
   - Flutter `SafetyState.unsupported` üretir; güvenlik bölümü gizlenir, kurulum sihirbazında "Bu pano yazılımı güvenlik modülünü desteklemiyor, v1.2.0'a güncelleyin" notu çıkar.
   - **`safety` anahtarının yokluğu** `[O11]`. Üç durum ayrı ele alınır: (a) `caps` yok → eski firmware, açık alarm satırlarına **dokunulmaz**, satır `status='lost'` olur ve owner'a bilgi push'u gider (firmware geri alınmış olabilir); (b) `caps` içinde `safety` var ama `safety` anahtarı yok → modül yapılandırılmamış ya da yapılandırma bozuk/silinmiş; açık satırlar yine `lost` olur, otomatik `cleared` **yapılmaz**; (c) `safety` var → normal uzlaştırma (§5.2.2).
6. **Bilinmeyen `act` değeri.** Eylemci rölesinin `type` alanı bugünkü RelayType adıyla yazılmaya devam eder (`light` ya da `impulse`). Bu yüzden eski uygulama ve eski sunucu yerleşimi bozulmadan okur. Eski bir uygulama bu satırı lamba kartı olarak gösterir; açma girişimi firmware'de reddedilir (§2.3, madde 4), yeni sunucuda da reddedilir (§5.2.4).
   - **`act` buluta taşınır** `[Y2]`. Yerleşim eşitlemesi (`server/src/utils/endpoint_layout.js:273-292` ve `endpoint_layout_sync`) röle satırındaki `act` alanını çıkarır ve `endpoints.actuator_type` kolonuna yazar. `act` sunucu yerleşim imzasına ve Flutter `ReportedLayout.signature`'a (`lib/models/endpoint_sync.dart:180-197`) girer; böylece bir kanalın lambadan vanaya çevrilmesi eşitlemeyi tetikler. CONTRACTS §2.4b "Yük" maddesi buna göre güncellenir.
   - **Vana lamba sayılmaz** `[Y3]`. Gece huzur özeti (`server/src/services/peace_snapshot.js:24,48`), "hepsini kapat" (`peace_service.js` `closeLightsKeepingPlugs`, çağrı yeri `device_service.js:1888-1896`), `all_lights_off` ve huzur uyarıları (`peace_service.js:365-398`) `actuator_type IS NULL` koşulu alır. Aksi halde NC selenoidin normal "röle açık" konumu her gece "1 lamba açık" bildirimi üretirdi.
   - **Zamanlı kurallar** `[O6]`. `actuator_type` dolunca o kanala bağlı kurallar `enabled=false` yapılır (CONTRACTS §2.4b "Zamanlı kurallar" deseni); `scheduler.js` `_checkTarget` (`:565-567`) `actuator_type` dolu hedefi reddeder.

### 3.2 `state` v:3 eki

```json
{
  "v": 3, "uid": "AHBU-S3-…", "fw": "1.2.0", "seq": 1240, "uptime": 3600, "ip": "192.168.1.30",
  "child_lock": false, "last_id": "c81f",
  "caps": ["safety", "actuator", "event", "cfg"],
  "boot": 57, "bn": "9f3a11c0", "time_ok": true, "epoch": 1791273600,
  "cfg": { "safety": { "rev": 12, "crc": "9a3c11f0" } },
  "last_rej": { "id": "c820", "code": "zone_latched" },
  "relays": [
    { "id": 5, "name": "Ana Su Vanası", "type": "light", "state": false, "act": "valve" },
    { "id": 6, "name": "Siren", "type": "light", "state": false, "act": "siren" }
  ],
  "shutters": [], "dis": [ { "id": 3, "state": true } ],
  "sensors": [
    { "id": "d3", "src": "di", "kind": "water", "zone": 1, "active": true, "ok": true },
    { "id": "b1", "src": "bridge", "kind": "water", "zone": 1, "active": false, "ok": false }
  ],
  "actuators": [
    { "id": "a1", "relay": 5, "kind": "valve", "medium": "water", "zones": [1], "pos": "closed", "fb": true, "fault": false },
    { "id": "a2", "relay": 6, "kind": "siren", "zones": [1], "on": true, "fault": false }
  ],
  "safety": {
    "policy": "on", "mode": "normal",
    "zones": [ { "id": 1, "st": "latched", "kind": "water", "aid": "9f3a11c0-3", "since": 1791273000, "since_up": 3000, "silenced": false, "srcs": ["d3"] } ]
  }
}
```

Sensör, eylemci ve bölge **adları state'te yoktur** `[B12]`; `cfg_dump` / `GET /api/safety/config` ile gelir ve istemci kimlikle eşler.

**Alan sınırları ve anlamları**

| Alan | Tür / sınır | Anlam |
|---|---|---|
| `caps` | dizge dizisi, ≤ 8 öğe, her öğe ≤ 12 karakter | yetenekler |
| `boot` | u32 | NVS açılış sayacı (`ahbu_latch`, sıfırlamada silinmez). Sunucu yeniden başlatmayı bundan anlar |
| `bn` | 8 hex | **Açılış nonce'u** `[Y4][B4]`: her açılışta `esp_random()` ile üretilen 32 bit. eid öneki budur. Fabrika sıfırlaması, flash silme ya da pano değişiminden sonra bile eid'ler çakışmaz |
| `safety.mode` | `normal` ya da `safe` | `safe`: güvenli kip (yapılandırma CRC'si bozuk, kilit var ama eylemci tablosu yok, ya da çökme döngüsü; §5.1.6). Bu kipte açma komutları reddedilir |
| `time_ok`, `epoch` | bool, u32 | saat güvenilir mi (SNTP ya da RTC, §2.8 ve §7). `false` ise `since` yazılmaz, yalnız `since_up` vardır |
| `cfg.<modül>.rev/crc` | u32, 8 hex | yapılandırma sürümü ve CRC32'si (§4.2) |
| `last_rej` | `{id ≤ 24, code ≤ 24}` | **Yeni.** Son reddedilen komut. Bugün reddedilen komut `last_id`'yi değiştirmiyor ve istemci 30 sn bekliyor; bu alanla ret anında görülür. `code` değerleri: `zone_latched`, `zone_test`, `actuator_relay`, `unknown_actuator`, `bad_state`, `unsupported`, `cfg_conflict`, `cfg_invalid`, `gas_local_only` `[K-4]`, `stale_ack` `[Y-9]`, `safe_mode` `[Y-4]`, `bad_cmd` (ayrıştırma: bilinmeyen alan, aralık dışı) ve `busy` (kuyruk dolu) `[O10]`. `bad_cmd`/`busy`, kimliği (`id`) çözülebilen ve `uid`'si bu panoyla eşleşen komutlar için MqttTask'ta yazılır (`MqttManager.cpp:874-893`); `uid` uyuşmazlığı ise bilinçli olarak sessizdir (§3.3) |
| `relays[].act` | `"valve"`, `"siren"`, `"fan"`, `"generic"` | yalnız eylemci rölelerinde bulunur |
| `sensors[].id` | `d<1..40>` ya da `b<1..16>` | kaynağa göre kararlı kimlik |
| `sensors[].src` | `"di"` ya da `"bridge"` | K2 |
| `sensors[].kind` | `water`, `gas`, `smoke`, `door`, `window`, `motion`, `generic` | |
| `sensors[].active` | bool | onay süzgecinden geçmiş, NC çevrilmiş seviye |
| `sensors[].ok` | bool | sensör değeri güvenilir mi: yerel DI ilk okuma, ek modül yanıt/tarama durumu, köprü kalp atışı (§2.5). `false` ise `active` anlamsızdır |
| `actuators[].medium` | `water` ya da `gas` | yalnız vana `[K-3]` |
| `actuators[].pos` | yalnız vana: `closed`, `closing`, `open`, `opening`, `cmd_closed`, `cmd_open`, `unknown` | `cmd_*`: geri bildirim yok, yalnız komut edilen konum bilinir. `closing`/`opening`: geri bildirim bekleniyor |
| `actuators[].on` | bool | SIREN, FAN, GENERIC |
| `actuators[].fb` | bool ya da `null` | geri bildirim kontağının ham "kapalı" yorumu; geri bildirim yoksa `null` |
| `safety.zones[].st` | `normal`, `latched`, `fault`, `test` | `fault` = VALVE_FAULT (kilit de sürer) |
| `safety.zones[].aid` | ≤ 14 karakter (`<bn>-<n>`) | alarmı açan olayın eid'si; alarm kimliği olarak kullanılır. NVS'te `aid[15]` (NUL dahil) `[B16]` |
| `climate`, `energy` | nesne | **ayrılmış.** Bu sürümde yazılmaz; şekil §6'da |

**Diğer sınırlar**

- En çok 56 sensör, 16 eylemci, 4 bölge.
- Ad uzunlukları (yapılandırmada, state'te değil): sensör 19, eylemci 19, bölge 15 bayt (UTF-8, NUL hariç).
- **Düzeltme** `[D6]`: köprünün mevcut doğrulayıcısı `sensors` dizisine hiç bakmıyor (`mqtt_bridge.js:211-242`); `MAX_ARRAY_ITEMS` (64) yalnız röle/panjur dizilerinde uygulanıyor. Yeni doğrulayıcı `sensors` ≤ 56, `actuators` ≤ 16, `safety.zones` ≤ 4 sınırlarını **ayrıca** uygular.

**Yayın tetiği.** `StateSignature`'a (`MqttManager.h:115-124`, `makeSignature` `MqttManager.cpp:642`) şunlar eklenir: `sensorActiveMask` (u64), `zoneStateWord` (u32), `actuatorPosWord` (u64) ve `lastRej` dizgesinin özeti. Eklenmezse alarm, 30 sn'lik kalp atışına kadar yayınlanmaz.

### 3.3 `cmd` ekleri

Bütün yeni komutlar bugünkü kuralları izler (CONTRACTS §2.3): bilinmeyen alan ya da aralık dışı değer gelirse komut uygulanmaz; isteğe bağlı `id` ≤ 24 karakterdir; son 8 kimlik tekilleştirilir.

**`uid` yeni komutlarda ZORUNLU** `[Y5][Y-9][Y4]`. `cmd` ev konusuna gidiyor ve evdeki tüm panolar bunu alıyor (`MqttManager.cpp:338-341`; `peace_service.js:366`); eylemci kimlikleri (`a1`…`a16`) ve bölge numaraları pano başınadır. Bu yüzden yeni komutların hepsinde (`actuator`, `alarm_ack`, `alarm_test`, `safety_arm`, `climate_target`, `scene_run`, `event_ack`) `uid` zorunludur; yoksa `bad_cmd`. `uid` panonunkiyle eşleşmiyorsa komut **sessizce** yok sayılır (`last_rej` yazılmaz; başka panonun komutudur). Düz `relay` komutunda (v:2, `uid`'siz) eşleşmeyen panolar `last_rej` yazmaz kuralı uygulanamaz, bu yüzden sunucu ret yankısını yalnız hedef panonun `uid`'siyle eşleşen state'ten kabul eder (§5.2.4).

**Onayda alarm kimliği** `[Y-9]`. `alarm_ack` `aid` taşır. `aid` bölgenin güncel `aid`'siyle eşleşmezse (kullanıcının görmediği yeni bir alarm) `last_rej = stale_ack` yazılır, hiçbir şey susturulmaz.

**Durum anahtarı** `[D1]`. Mevcut sözleşmede `state` yalnız boolean'dır (CONTRACTS §2.3, `MqttManager.cpp:121`). Eylemci komutu karışıklığı önlemek için ayrı `to` anahtarını kullanır.

```json
{ "actuator": "a1", "to": "closed", "uid": "AHBU-S3-…", "id": "c81f" }       // vana: closed | open
{ "actuator": "a2", "to": "on", "uid": "AHBU-S3-…" }                         // siren/fan/generic: on | off
{ "cmd": "alarm_ack",   "zone": 1, "aid": "9f3a11c0-3", "uid": "AHBU-S3-…", "id": "c820" }   // onay + susturma (§5.1.3)
{ "cmd": "alarm_test",  "zone": 1, "uid": "AHBU-S3-…", "id": "c821" }
{ "cmd": "safety_arm",  "mode": "away", "uid": "AHBU-S3-…" }                 // away | home | off   [modül 2.5; o modüle kadar "unsupported"]
{ "cmd": "climate_target", "zone": 1, "c10": 215, "uid": "AHBU-S3-…" }       // 0.1 °C tamsayı, 50..350 [modül 3.2]
{ "cmd": "scene_run",   "scene": 3, "uid": "AHBU-S3-…" }                     // 1..32 [modül 5.x]
{ "cmd": "event_ack",   "eids": ["9f3a11c0-3", "9f3a11c0-4"], "uid": "AHBU-S3-…" }   // YALNIZ backend; ≤ 8 eid
```

**Firmware değişiklikleri**

- `parseCommand` bayrak maskesi `uint16_t` olur (`MqttManager.cpp:31-38,98`). Yeni bayraklar: `F_ACTUATOR`, `F_TO`, `F_ZONE`, `F_AID`, `F_MODE`, `F_C10`, `F_SCENE`, `F_EIDS`, `F_UID`.
- `actuator` alanı dizge olarak gelir (`a1`…`a16`). Eylemci kimliğiyle röle numarası ayrıdır; röle değişse bile kimlik sabit kalır.
- `DeviceCommand.index` = eylemci ya da bölge numarası; `value` = durum, kip ya da hedef.
- Yük üst sınırı 512 bayt aynen kalır (`MqttManager.cpp:26`). En büyük yeni komut `event_ack` olup 8 eid ve `uid` ile ~200 bayttır.
- **sys konusu** `[D2][B11]`. Yeni sys işleri mevcut `cmd` anahtarını kullanır: `{"cmd":"cfg_get"|"cfg_patch", …}` (`op` değil; `MqttManager.cpp:912-940`, CONTRACTS `:388`). `onMessage` boyut denetimi (`:850-856`) sys için ayrı bir `MAX_SYS_PAYLOAD = 1024` sınırı alır; `handleSys` belgesi 1024'e çıkarılır ve ayrıştırıcı birden çok `cmd` değerini tanıyacak şekilde yeniden yazılır (WP-F4).

### 3.4 `ev/{t}/event` konusu ve teslim garantisi

**Neden gerekli?** State "seviye"yi taşır ve retain edilir; aradaki kısa süreli alarmları ve "ne zaman, hangi sensör" bilgisini kaybedebilir. Olay konusu "kenar"ı taşır.

**QoS gerçeği.** Plan QoS1 istiyor. Ancak PubSubClient yalnız QoS 0 yayınlar (`MqttManager.cpp:621`). Bu yüzden teslim garantisi **uygulama düzeyinde onayla** sağlanır. Kütüphaneyi değiştirmek kapsam dışıdır; bu sapma CONTRACTS §2.6'ya yazılmalıdır.

```json
{ "v": 1, "uid": "AHBU-S3-…", "eid": "9f3a11c0-3", "bn": "9f3a11c0", "boot": 57, "n": 3,
  "type": "alarm_raised", "zone": 1, "kind": "water", "srcs": ["d3"],
  "at": 1791273000, "at_up": 3000, "actions": [ { "a": "a1", "do": "close" }, { "a": "a2", "do": "on" } ] }
```

**Olay türleri (ilk modül)**

| Tür | Anlam |
|---|---|
| `alarm_raised` | bölge alarma geçti |
| `valve_fault` | vana geri bildirimi zaman aşımına uğradı |
| `valve_fault_cleared` | vana arızası düzeldi |
| `alarm_silenced` | alarm ıslakken onaylandı (susturuldu) |
| `alarm_cleared` | kilit kalktı |
| `test_result` | `{ok, fb_ms}` |
| `sensor_fault` | sensör arızası (`ok` true→false) |
| `sensor_fault_cleared` | sensör arızası düzeldi |
| `actuator_fault` | eylemci erişilemez (ek modül yanıt vermiyor, yapılandırma dışında kaldı) `[Y-6]` |
| `safe_mode` | pano güvenli kipe girdi (`reason`: `cfg_corrupt`, `latch_orphan`, `crash_loop`) `[Y-4][O-8]` |
| `nvs_fail` | kilit ya da konum kaydı NVS'e yazılamadı |
| `policy_changed` | `policy` açıldı/kapandı (kim, hangi yoldan: `lan`, `cloud`, `local_web`) `[O3]` |
| `actuator_changed` | kullanıcı eylemi; en düşük öncelik |
| `cfg_conflict` | yama reddedildi (`{rev, crc}`) |

`cfg_dump` **olay değildir** `[Y6]`: outbox dışında, geçici arabellekten, onaysız ve `ev/{t}/event` konusunda `type:"cfg_dump"` zarfıyla yayınlanır; parça sınırı zarf payı düşülerek **≤ 3,5 KB** (`part`/`parts`). Kaybolan parça, sunucunun `cfg_get`'i yinelemesiyle telafi edilir (rev/crc karşılaştırması). Olay yuvası sabit yapıdır (§2.8); en kötü durumda (`srcs` 8, `actions` 16) yayın JSON'u ~400 B'dir ve köprünün 4 KB sınırının altında kalır.

**Teslim kuralları**

- **eid** `[Y4][B4]`. `<bn>-<n>` biçimindedir: `bn` her açılışta `esp_random()` ile üretilen 8 hex karakterlik nonce, `n` açılış başına 1'den artan sayaç (en çok 5 hane). Fabrika sıfırlaması (sayaç sıfırlanabilir), flash silme ya da pano değişimi sonrası da eid'ler pratikte çakışmaz (32 bit nonce). Önceki `b<boot>-<n>` biçimi `bootc` silinince yinelenirdi ve sunucu yeni alarmı "yinelenen" sayıp yutardı.
- **Cihaz tarafı yeniden deneme.** EventOutbox her olayı `retain=false` ile yayınlar. Onay gelmezse 5, 10, 20, 40 sn sonra, ardından 60 sn'de bir yeniden dener. Kopukluk sırasında olay bekler; yeniden bağlanınca sırayla gönderilir. Onay, backend'in `cmd` konusuna QoS1 ile yayınladığı `event_ack` komutudur (`uid` zorunlu, §3.3).
- **Yeniden bağlanma penceresi** `[D4]`. Abonelikten sonraki ilk 1500 ms'de gelen komutlar yok sayılıyor (`MqttManager.cpp:845-849`). Outbox bu pencere bitmeden boşaltılmaz; aksi halde ilk onaylar kaybolur ve gereksiz yinelemeler oluşur.
- **Taşma.** Tampon 16 olay tutar. Dolarsa önce en eski `actuator_changed`, sonra en eski `*_cleared` olayı atılır. `alarm_raised` ve `valve_fault` atılmaz; bunlar dolarsa en eski alarm olayının üstüne yazılır. Kaybın hiçbiri bilgi kaybı değildir, çünkü kilitli durum state'te durur (aşağıdaki maddeye bakın).
- **Yeniden başlatmada tampon kaybolur** (RAM). Telafi: kilitli bölge NVS'ten geri gelir ve state'te `safety.zones[].aid` ile birlikte yayınlanır. Sunucu, açık alarm satırı olmayan bir `latched` bölge görürse alarmı `origin='state'` ile açar (§5.2.2). Sonuç olarak teslim **çalışma süresince en az bir kez, açılışlar arasında ise state üzerinden nihai tutarlılık** garantisiyle yapılır.
- **Sunucu tarafı.** `(device_id, eid)` benzersiz indeksiyle tekilleştirir; yinelenen olay geldiğinde yine `event_ack` gönderir. Pano devrinde (`device_id` aynı kalır) eid nonce'u sayesinde eski kayıtlarla çakışma olmaz.
- **Retained olay.** Gelirse yok sayılır (yanlış yapılandırma savunması).
- **ACL.** Cihaz `ev/{t}/event` konusuna yayın yapabilir. Uygulama kimlikleri bu konuya abone **olmaz**; alarmı state ve push üzerinden alır. Böylece uygulama ACL'si değişmez.

### 3.5 Yerel HTTP API (LAN; aynı sözleşme)

Bütün yeni rotalar `Access::KEYED` erişimlidir (`X-Device-Key`) ve `setupRoutes` içine eklenir (`WebPortal.cpp:573-611`). Komutlar `postOrFail` (`:816`) üzerinden aynı kuyruğa gider. Gövde biçimi MQTT `cmd` ile birebir aynıdır (LAN'da `uid` isteğe bağlıdır: tek pano). Yanıt `{ok, id, rej?}` biçimindedir. `rej`, komut işlenince yazılan `last_rej` ile aynı kodları taşır. Web görevi en çok 1 sn boyunca `AutomationSnapshot`'taki `last_id` ya da `last_rej` eşleşmesini yoklar. **`g_job` kullanılmaz** `[D3]`: tek yuvalıdır (`WebPortal.cpp:475-476`, meşgulse 503) ve yapılandırma/RS485 işleriyle çakışırdı.

**Güven sınırı (bilinçli)** `[O3]`. LAN anahtarı (`local_key`) bugün resident rolüne de verilir (`role_matrix.js:44`). Bu anahtarla `POST /api/safety/config` çağrılarak politika kapatılabilir; bulutta ise `safety_config` yalnız owner ve servis rollerindedir. Bu fark bu sürümde **bilinçli güven sınırı** olarak kabul edilir (anahtarı olan, evin içinde fiziksel erişimi olan kişidir). Telafi: `policy:off` ve eylemci silme state'te (`safety.policy`), `policy_changed` olayında ve sunucu denetim kaydında görünür; owner'a bilgi push'u gider. Ayrı bir servis anahtarı ya da fiziksel onay gerekip gerekmediği §7.2'de açık sorudur.

| Yöntem ve yol | MQTT karşılığı |
|---|---|
| `GET /api/status` | bugünkü LAN durum yanıtına (CONTRACTS §3b; `v`/`uid` yok, `shutters[]` farklı) **`caps`, `bn`, `sensors`, `actuators`, `safety` ve `last_rej` eklenir** `[D3]` (`WebPortal.cpp:879` tam görünümü) |
| `POST /api/actuator` `{actuator, state, id?}` | `{"actuator":…}` |
| `POST /api/alarm/ack` `{zone, id?}` | `alarm_ack` |
| `POST /api/alarm/test` `{zone, id?}` | `alarm_test` |
| `GET /api/events?after=<eid>` | **Yalnız LAN.** EventOutbox'ın son 32 olayının kopyası (onaylanmış olanlar dahil, ayrı bir halka). İnternetsiz uygulama, alarm geçmişini buradan okur (K5) |
| `GET /api/safety/config` · `POST /api/safety/config` `{base_rev, …}` | `sys cfg_get` / `cfg_patch` (§4.2) |

---

## 4. Yapılandırma modeli

### 4.1 Asıl kaynak: panodaki NVS (K5)

Güvenlik, eylemci, ışık (K4) ve ileride senaryo ile termostat yapılandırması `ahbu_safety` (ve ileride `ahbu_scene`) ad alanında tutulur. Pano bu bilgiyle internet olmadan tam çalışır.

**Değişiklik yolları.** Her yolun sonunda aynı adımlar uygulanır: `SafetyConfig::validate`, `rev++`, CRC güncellemesi, NVS'e yazım (web görevinde, `WebPortal.cpp:1227` deseni) ve loopTask'a `applySafetyConfigOnLoop` işi (`applyConfigOnLoop` deseni, `:448-470`).

1. Yerel web sayfası veya LAN API: `POST /api/safety/config`.
2. Kurulum sihirbazı (Flutter): LAN üzerinden ya da AP `192.168.4.1` üzerinden.
3. Buluttan `sys cfg_patch`.

**Alarm sırasında yapılandırma** `[O-10]`. Bir bölge `latched` ya da `fault` durumundayken o bölgeye dokunan **her** değişiklik `409 zone_latched` ile reddedilir: eylemcinin silinmesi, kipinin/akışkanının değişmesi, `zone_mask`'inin daraltılması; bölgedeki sensörün silinmesi, başka bölgeye alınması ya da türünün değişmesi; bölgenin silinmesi. Ana yapılandırma yolu da (`/api/config`) aynı kurala tabidir (§2.3 madde 5). `policy_on=0` kabul edilir ama **mevcut kilidi kaldırmaz**; yalnız yeni alarmları engeller ve `policy_changed` olayı üretir. Gerekçe: alarm sırasında vananın "unutulması" engellenir.

### 4.2 Bulut eşitlemesi

| Konu | Kural |
|---|---|
| Yön | **Pano → bulut** asıl yöndür. Bulut, panonun ilan ettiği `cfg.safety.rev/crc` değerlerini kendi kopyasıyla karşılaştırır. Farklıysa `sys {"cmd":"cfg_get","module":"safety","uid":"…"}` gönderir; pano yanıtı `cfg_dump` yayınıyla verir (outbox dışında, onaysız; parçalı: `part`/`parts`, her parça ≤ 3,5 KB, §3.4) `[Y6][B11]`. |
| Buluttan değişiklik | Uygulama değişikliği sunucuya yazar. Sunucu `sys {"cmd":"cfg_patch","module":"safety","uid":"…","base_rev":12,"set":{"sensor":{"id":"d3","kind":"water","zone":1,"active_open":0}}}` gönderir. Her yamada tek öğe değişir, bu yüzden yük ≤ 400 bayttır. sys belge kapasitesi 384'ten 1024'e (`MqttManager.cpp:904`) ve sys yük sınırı 512'den 1024'e (`:26,850-856`, yalnız sys için) çıkarılır `[D2]`. Backend'in `MAX_COMMAND_BYTES` sınırı 1024'tür (`mqtt_bridge.js:84-86`). |
| Çakışma | **İyimser eşzamanlılık, pano kazanır.** `base_rev ≠ rev` ise pano yamayı uygulamaz ve `cfg_conflict` olayı gönderir (`{rev, crc}`). Sunucu güncel dökümü çeker, kopyasını yeniler ve uygulamaya `409 CONFIG_CHANGED_ON_DEVICE` döner; kullanıcı güncel durum üzerinden yeniden dener. Gerekçe (K5): sahada yerel yapılan değişiklik, bulutun eski görüntüsüyle ezilmemeli. |
| Sürüm ve imza | `rev` (u32, monoton) + CRC32 (bütünlük). Ayrıca kriptografik imza **yok**. Gerekçe: `sys` konusuna yalnız backend yayın yapabiliyor (CONTRACTS §2.2 ACL), bağlantı TLS ve LAN yolu `X-Device-Key` ister. Bu, bugünkü `set_local_key` modeliyle aynı güven sınırıdır. |
| Çevrimdışı pano | Yama gönderilmez. İstek `device_configs.pending` alanına yazılır; pano çevrimiçi olunca `device_reconciler` deseniyle uygulanır (`onLiveState` `device_reconciler.js:327`). |
| Çok panolu ev | Her yamada `uid` zorunludur (§3.3). |

### 4.3 Fabrika varsayılanları

- `pol.policy_on = 1` (K5: güvenlik tepkileri AÇIK).
- `dry_hold_ms = 10000`, tek bölge "Ev" (id 1). Yeni siren eylemcisinin `run_limit_s` varsayılanı 180 (tek kaynak, `pol.siren_max_s` yok) `[D-2]`.
- **Sensör ve eylemci tablosu boş.** Gerekçe: hangi DI'ye ne bağlandığını yalnız kurulumcu bilir (plan 1.2). Mevcut lamba/panjur varsayılanları (`ConfigManager.cpp:28-112`) değişmez. Kanıt §2.9'dadır.
- **"Varsayılan olarak açık" ne demek?** Kurulumcu bir DI'yi `water` olarak atadığı anda, ek bir "tepkiyi etkinleştir" adımı olmadan şunlar olur:
  - Sensör kendi bölgesinde **kendi akışkanının** vanalarını kapatır (su → su vanası, gaz → gaz vanası; duman → vana yok) `[K-3]`.
  - Bölgedeki sirenleri `run_limit_s` süresince çalar.
  - Kart üstü buzzer da çalar. Mevcut `Buzzer_Open_Time` FIFO'su (`WS_GPIO.cpp:118-160`) bunun için uygun değildir (en çok ~65 sn, iptal yok, kilitsiz, komut bipleriyle aynı kuyruk) `[O-7][B10]`; yeni `Buzzer_SetAlarm(bool)` kalıcı alarm kipi ve iptal sağlar, ACK onu sıfırlar. Alarm kipi açıkken komut bipleri yutulur.

  Gaz alarmında fan **varsayılan olarak açılmaz**; yalnız kurulumcu fanı "ex-proof/ATEX" olarak işaretlediyse açılır. Duman alarmında fan kapatılır (§2.4) `[Y-1]`.
- `resetToDefaults` `ahbu_safety` ad alanını siler (`ConfigManager.cpp:384-386`) ama **`ahbu_latch`'i silmez** `[Y-5]`. **Karar değişti:** eski metin "fabrika sıfırlaması kilidi kaldırır, çünkü fiziksel erişim ya da servis yetkisi ister" diyordu; oysa `/api/system/reset` `Access::KEYED` ile ağ üzerinden çalışıyor (`WebPortal.cpp:607,1600-1618`) ve ardından yeniden başlatma geliyor. Artık kilit sıfırlamadan sağ çıkar; kilit varken `/api/system/reset` `409 zone_latched` döner, `force=1` ile geçilebilir. Sıfırlama sonrası eylemci tablosu boş olduğundan pano **güvenli kipte** açılır ve kilitteki maskeleri uygular (§5.1.6).

### 4.4 Kurulum sihirbazı akışları (Flutter)

Sihirbazda bugün kanal ayarları adımı yok. `saveConfig` (`lib/services/automation_api_service.dart:582`) hiç çağrılmıyor. **Adım 7 ("Röle Testi") genişletilir.** Yeni bir adım açmak `total=10`, adım dosyaları ve `_skipped` mantığını etkiler (`setup_steps.dart:25`, `service_setup_controller.dart:99,104,430`), bu yüzden daha pahalıdır.

1. **Röle kartı** (`lib/ui/pages/service_setup/steps/step_7_relays.dart` `_RelayCard`, 101-280).
   - "Bu kanala ne bağlı?" sorusu: Lamba, Panjur (çift), Darbe, **Vana**, **Siren**, **Fan**, **Diğer cihaz**, Kullanılmıyor.
   - Vana seçilirse:
     - "Vana, rölede enerji varken mi kapalı?" (`close_mode`). Yanında "Bilmiyorum" düğmesi var: test et → kullanıcı vananın konumunu görür ve işaretler.
     - "Bu vana neyi kesiyor?" **Su** / **Gaz** (`medium`, zorunlu) `[K-3]`. Gaz seçilirse: "Gaz vanası yalnız yerinde düğmeyle açılır; her elektrik kesintisinden ve testten sonra kapalı kalır" notu ve "Gaz vanası açma düğmesi hangi girişe bağlı?" sorusu (`GAS_RESET` DI) `[K-4]`.
     - "Konum geri bildirim kontağı var mı? Hangi girişe bağlı?" (`fb_di`).
     - Bölge seçimi.
   - Fan seçilirse: "Bu fan gaz kaçağında çalıştırılabilir mi (ex-proof/ATEX)?" Varsayılan Hayır `[Y-1]`. Gaz bölgesindeki siren/fan için "röle ve cihaz gaz kaçağı bölgesinin dışında olmalı" uyarısı.
2. **Giriş (DI) kartları** (aynı adımda ikinci sekme: "Girişler ve Sensörler").
   - Her DI için: Duvar butonu (bugünkü davranış), **Su sensörü**, **Gaz dedektörü çıkışı**, **Duman dedektörü çıkışı**, Kapı, Pencere, Hareket, Vana geri bildirimi, **Alarm onay düğmesi**, **Vana kapat düğmesi**, **Gaz vanası açma düğmesi** `[B15]`, Kullanılmıyor.
   - Kontak tipi NO/NC sorulur, bölge seçilir `[O-2]`:
     - Gaz ve duman dedektörü için **NC zorunludur** (dedektörün enerjisi kesilirse ya da kablo koparsa alarm olur); NO seçeneği gösterilmez.
     - Su sensörü için NC ya da EOL dirençli bağlantı önerilir. NO seçilirse "Kablo koparsa pano bunu algılayamaz" uyarısı gösterilir.
   - Canlı gösterge: `/api/status` içindeki `dis[]` ve `sensors[]` her saniye yoklanır. "Sensöre su damlatın, gösterge kırmızıya dönmeli."
3. **Doğrulama ve kayıt.** `POST /api/safety/config`, ardından bölge başına bir `alarm_test` çalıştırılır. Sonuç ekranında şu yazar: "Vana 4,2 sn'de kapandı (geri bildirim doğrulandı)" ya da "Geri bildirim yok: vananın kapandığını gözle doğrulayın."
4. **Kayıt biçimi.** `RelayCheck`'e (`lib/ui/pages/service_setup/logic/relay_logic.dart:13-100`) `actuatorKind`, `closeMode`, `medium`, `fanExProof`, `fbDi`, `zone`, `wantsDimming` ve `dimmerTarget` eklenir. `setup_store.dart:78` kayıt sürümü `'v': 1` iken `'v': 2` yapılır; `v:1` kayıtları yeni alanlar varsayılanlarıyla okunur.

### 4.5 K4: Dimmer sorusu ve yönerge metni

Bu soru, "Lamba" seçilen her kanalın kartında çıkar: **"Bu lambanın parlaklığı ayarlanacak mı?"** Varsayılan yanıt "Hayır"dır.

"Evet" seçilince açılan panelin metni (Türkçe arayüz dizgesi):

> **Bu kanal için dimmer gerekiyor.** Panodaki röleler lambayı yalnızca açıp kapatabilir; parlaklık ayarlayamaz. Parlaklık için aşağıdakilerden birini ekleyin:
>
> **A) RS485 Modbus dimmer modülü (kablolu, internetsiz çalışır)**
> 1. Modülü panonun **RS485 A/B** klemenslerine, ek röle modülüyle **aynı hatta paralel** bağlayın (A→A, B→B, ortak GND).
> 2. Modülün adresini **{önerilen_adres}** yapın. Bu adres ek modülün adresinden ({ext_addr}) farklı olmalı.
> 3. Lamba hattını **Röle {n}** yerine dimmer modülünün **Çıkış {k}** ucuna taşıyın. Röle {n} bundan sonra "Kullanılmıyor" olarak kalır (ya da dimmerin besleme kontaktörü olarak kullanılabilir).
> 4. LED lambalar "dim edilebilir" (dimmable) olmalı; değilse titreme olur.
>
> **B) Zigbee/Thread dimmer (kablosuz)**
> 1. Dimmeri lambanın duvar kutusuna ya da armatüre takın ve ev hub'ına eşleyin.
> 2. Hub panoya yerel olarak bağlı olmalı (bulut gerekmez).
> 3. Bu kanalı "Hub cihazı: {seçim}" ile eşleyin.
>
> Dimmer takılana kadar bu lamba senaryolarda **%N parlaklık yerine "aç"** olarak çalışır.

**Kayıt.** NVS `light[n] = {dimmable:1, dimmer_src: 0=yok | 1=modbus | 2=bridge, dimmer_addr, dimmer_ch}` biçiminde tutulur. Bulutta `endpoints.dimmable` ve `endpoints.dimmer_source` kolonları vardır (033). Panoda dimmer sürücüsü olmadığı sürece `dimmer_src` kaydedilir ama "takılmadı" sayılır; senaryo motoru yalnız sürücüsü olan kaynakta yüzde uygular.

`{önerilen_adres}` değeri: ek modül kapalıysa 2, açıksa `ext_module_address + 1`, 247'ye kadar. `{ext_addr}` değeri `SystemConfig.ext_module_address` alanından okunur.

---

## 5. İlk modül: su baskını + vana (plan 2.1-2.3)

### 5.1 Firmware

#### 5.1.1 Bölge durum makinesi (`safety/SafetyFsm.h`, saf)

Durumlar ve girdiler:

- Durumlar: `NORMAL`, `ALARM_LATCHED`, `VALVE_FAULT`, `TEST`. Ayrıca kilitli durumlarda `silenced` bayrağı tutulur.
- Girdiler (her `tick(now, in)` çağrısında):
  - `wet`: bölgede onaylanmış ıslak sensör var (yalnız `ok=true` sensörler).
  - `dryForMs`: bölgedeki **bütün** sensörlerin kesintisiz `ok && !active` olduğu süre. Bir sensör `ok=false` iken sayaç sıfırlanır ve ilerlemez `[Y-3]`.
  - `valveConfirmedClosed`: bölgedeki geri bildirimli bütün vanalar kapalı.
  - `cmd`: `ACK`, `TEST` ya da `NONE`.

```
                 wet (onaylı)                       fb zaman aşımı (geri bildirimli vana kapanmadı)
  NORMAL ─────────────────────────▶ ALARM_LATCHED ──────────────────────────▶ VALVE_FAULT
    ▲  │                               │    ▲  ACK (ıslak): silenced=1           │  ▲
    │  │ TEST                          │    └──────────────┐                     │  │ ACK: silenced=1
    │  ▼                               │                   │                     │  │
   TEST ──wet──▶ ALARM_LATCHED         │ (acked && kuru ≥ dry_hold)              │ fb kapandı
    │                                  ▼                                         ▼
    └─ test bitti (ok/fail) ─▶ NORMAL ◀──────────────── (acked && kuru ≥ dry_hold && fb kapalı)
```

| Geçiş | Koşul | Eylemler (çekirdeğin döndürdüğü `Actions` yapısı) | Olay |
|---|---|---|---|
| NORMAL → ALARM_LATCHED | `wet` | Bölgedeki **sensör türünün akışkanına uyan** vanalara `CLOSE` (smoke: vana yok) `[K-3]`, sirenlere `ON` (`run_limit_s` sayacı başlar), buzzer alarm kipine girer. Kilit (güvenli maskelerle) NVS'e yazılır ve kapatılan vanaların `act_pos` biti **kapalı** yapılır `[K-1]`. | `alarm_raised` |
| ALARM_LATCHED → VALVE_FAULT | Geri bildirimli bir vana `fb_timeout_s` içinde kapanmadı | `CLOSE` sürmeye devam eder; ValveGuard güvenli seviyeyi yeniden dayatır. Siren susturulmuş olsa bile yeniden `ON`. | `valve_fault` |
| VALVE_FAULT → ALARM_LATCHED | Geri bildirim kapandı | — | `valve_fault_cleared` |
| LATCHED/FAULT → aynı durum, `silenced` | `ACK` geldi ve hâlâ ıslak | Sirenler `OFF`, buzzer susar. **Vana kapalı kalır.** | `alarm_silenced` |
| LATCHED → NORMAL | (`ACK` geldi ya da önceden alındı) ve `dryForMs ≥ dry_hold_ms` | Kilit NVS'ten silinir, sirenler `OFF`. **Vanalar KAPALI kalır**; `act_pos` zaten "kapalı" olduğu için elektrik kesintisinden sonra da kapalı açılır `[K-1]`. Açmak ayrı bir kullanıcı `open` komutudur (§5.1.3). | `alarm_cleared` |
| FAULT → NORMAL | Yukarıdakiyle aynı, ayrıca geri bildirim kapalı | Aynı | `alarm_cleared` |
| NORMAL → TEST | `TEST` komutu | Bölge vanalarına `CLOSE`, sirenlere 3 sn `ON`. Geri bildirim süresi ölçülür. | — |
| TEST → NORMAL | Geri bildirim kapandı ya da zaman aşımı doldu (geri bildirim yoksa 5 sn) | Su vanaları **testten önceki** komut konumuna döner. **Gaz vanaları kapalı kalır** ve `act_pos` kapalı yazılır `[K-4]`. | `test_result {ok, fb_ms}` |
| TEST → ALARM_LATCHED | Test sırasında gerçek `wet` | Vanalar kapalı kalır (öncelik gerçek alarmdadır). | `alarm_raised` |
| Herhangi bir durumda `ACK` | NORMAL'de etkisiz; `last_rej` yazılmaz, `last_id` yankılanır (idempotent). `aid` bölgenin güncel `aid`'siyle eşleşmezse `stale_ack` `[Y-9]` | — | — |

**"Sensör kurumadan açma yok" kuralı** `[Y-3]`. Vanaya gelen `open` komutu yalnız şu durumda kabul edilir: pano güvenli kipte değil; vananın `zone_mask`'indeki her bölge `NORMAL`; o bölgelerde vananın akışkanına uyan **bütün** sensörler `ok && !active`. Aksi halde `last_rej = zone_latched` (ya da `safe_mode`) yazılır. Gaz vanası ayrıca yalnız `GAS_RESET` DI'sinden açılır (§2.4). `close` komutu **her zaman** kabul edilir.

**Çoklu sensör ve çoklu vana.**

- Bir bölgede herhangi bir sensör ıslaksa (VEYA mantığı) o bölgenin `zone_mask` kesişimindeki, sensör türünün akışkanına uyan bütün vanalar kapanır.
- Bir vana birden çok bölgeye bağlı olabilir (ör. ana vana bütün bölgelerde). Açılması için bütün bölgelerin NORMAL olması gerekir.
- `srcs[]` alanı, alarmı tetikleyen ve sonradan katılan sensörleri birlikte listeler (en çok 8).

#### 5.1.2 Zaman aşımları (varsayılan, yapılandırılabilir)

| Parametre | Varsayılan | Aralık |
|---|---|---|
| `confirm_ms` (su) | 1000 | 100..10000 |
| `dry_hold_ms` | 10000 | 1000..600000 |
| `fb_timeout_s` | 60 | 2..300 |
| Siren `run_limit_s` (tek kaynak) | 180 | 10..1800; 0 reddedilir `[D-2]`. Süre kilit başına `ahbu_latch/siren_s`'te birikir; yeniden başlatma sayacı sıfırlamaz `[O-8]` |
| Onay penceresi (su / gaz-duman) | 3000 / 1000 ms | sabit (§2.6) |
| TEST siren süresi | 3 sn | sabit |
| Köprü kalp atışı | 900 sn | 60..86400 |

#### 5.1.3 Kullanıcı eylemleri

- **Vanayı kapat:** her zaman ve her yoldan serbest (uygulama, LAN, CLI, duvar butonu, `VALVE_CLOSE` DI'si). Aynı zamanda alarmsız "elle kapatma" için de kullanılır.
- **Alarmı onayla:** ıslakken susturur; kuruyken (≥ `dry_hold`) kilidi kaldırır. Buluttan ve yerel anahtardan bağımsız yol: `ALARM_ACK` DI'si `[B15]`.
- **Vanayı aç:** yalnız NORMAL durumda ve bütün sensörler `ok && !active` iken. Gaz vanası yalnız yerinde (`GAS_RESET`). Tek dokunuşla iki işlem yapılmaz: arayüz önce onayı, kilit kalkınca da "Vanayı Aç" düğmesini gösterir. Kilit kalkmadan "aç" düğmesi devre dışıdır ve neden devre dışı olduğunu yazar.
- **Test et:** NORMAL durumda serbest.

#### 5.1.4 Neden kesme (ISR) değil, debounce'lu yoklama

1. **Gecikme bütçesi** `[D-1]`. loopTask turu `vTaskDelay(5)` ile biter ama tur süresi bundan uzundur: `drainCommands` (~15 ms), iki RS485 değişimi (2 × ~70 ms) ve `WebPortal::loop` dahil kodun kendi notu "birkaç yüz ms" diyor (`main.cpp:579`). DiGate süzgeci 60 ms, su onayı 1000 ms, vananın kendi kapanma süresi 1-30 sn. ISR'nin kazandıracağı süre yine anlamsızdır; 1 sn'lik bütçe için tur süresi sorun değildir.
2. **Ek modül DI'leri zaten yoklamalı.** RS485 FC02 ile 120 ms'de bir okunuyorlar (`SmartAutomation_Rs485.cpp:225-305`); orada kesme mümkün değil. Köprü sensörleri de mesaj tabanlı. Tek bir seviye tabanlı yol, üç kaynağı aynı mantıkla işler (K2).
3. **Gürültü.** Uzun sensör kablolarında kesme sahte tetik fırtınası üretir. Seviye ve onay süzgeci bunu doğal olarak keser.
4. **Tek yazıcı.** ISR doğrudan röle yazamaz (I²C TCA, mutex). Yazabilmesi için yine loopTask'a bayrak bırakması gerekirdi; bu da yoklamayla aynı gecikmeye varır.
5. **Kaçırma riski yok.** Kenar değil seviye okunduğu için açılışta zaten ıslak olan sensör ilk geçerli okumada yakalanır (500 ms'lik açılış kapısından sonra, `SmartAutomation.cpp:1127-1133`). Ek modül DI'si ise ilk başarılı Modbus okumasına kadar `ok=false`'tur; bu sürede ne alarm ne kuruluk üretir (§2.5) `[Y-2]`.

#### 5.1.5 Bağımsız emniyet: ValveGuard

ShutterGuard deseniyle çalışır (`SmartAutomation.cpp:57-126`).

- **Tutarlı yayın** `[Y-8c][B7]`. SafetyManager her turda maskeleri **tek bir yapı** olarak (`struct SafeMasks { u64 assert; u64 level; u32 gen; }`) mevcut `s_guardMux` desenindeki spinlock altında yayınlar; guard aynı kilit altında kopyalar. ESP32-S3'te (32 bit Xtensa) u64 okuma/yazma atomik değildir ve iki ayrı değişken birbiriyle tutarlı okunamaz.
- **Donanımdan okuma** `[Y-8a]`. Guard karşılaştırmayı `TCA_OutputShadow()` ile değil, çıkış yazmacını **donanımdan** okuyarak (`TCA_ReadReg(OUTPUT)`) yapar. Gölge yazılımsaldır; çip sıfırlansa da "1" der ve yalnız loopTask'taki 2 sn'lik `TCA_Verify` ile düzelir (`WS_TCA9554PWR.cpp:58,235-241`; `SmartAutomation.cpp:1162-1170`). Okuma `I2C_Lock` (80 ms) alamazsa o tur atlanır.
  - **`DEENERGIZE_TO_CLOSE` vana açık kaldıysa** `TCA_ClearBits` kullanılır (`:58`; kapatma her zaman serbest).
  - **`ENERGIZE_TO_CLOSE` vana enerjisizse** yeni bir yardımcı gerekir: `TCA_SetSafeBits(mask)`. Bu yardımcı panjur çifti maskesindeki bitleri (`TCA_SetShutterPairs`) **reddeder**; böylece interlock bozulamaz. Bugün bit kuran bir acil yardımcı yok. Bu yardımcının eklenmesi WP-F3'tedir.
- **Kapsam: yalnız yerel 8 röle** `[B7]`. Ek modül coil'lerinin gerçek durumu guard görevinde bilinmez (`_hw[]`/`_hwKnown[]` loopTask'a ait ve kilitsiz; `SmartAutomation_Rs485.cpp:110-142`); 50 ms'de bir körlemesine yazım hattı her seferinde 150 ms'ye kadar tutar. Bu yüzden ek modülde guard yalnız **loop beslemesi kesildiğinde** (loopTask N = 1000 ms boyunca tur sayacını artırmadıysa) ve **hız sınırlı** (en çok 1 sn'de bir) güvenli seviye yazımı yapar. Ek modüldeki vana için garanti "loopTask çalıştığı sürece her turda yeniden dayatma"dır (§2.3 madde 2).
- **Neden gerekli ve sınırları** `[Y-8b]`. Loop takılırsa TWDT 10 sn sonra sıfırlama yapar. Guard bu pencerede **önceden kurulmuş** güvenli konumu korur; çip sıfırlamasında enerjiyle kapanan vananın açılmasını donanım okumasıyla 50 ms içinde düzeltir. Guard **yeni** bir ıslak sensörü işlemez: loop takılıyken başlayan bir baskın, TWDT sıfırlamasından sonra (≤ 10 sn + açılış) ilk turda yakalanır. Guard görevinde bağımsız bir "yerel DI → vana kapat" yolu bu sürümde eklenmez (§8, karar R-2).

#### 5.1.6 Güç kesintisi ve yeniden başlatma

1. **`Relay_Init`** (`WS_Relay.cpp:77`, `main.cpp:38-42`) `setup()`'ın ilk işidir ve bugün donanımı 0'a çeker. TCA9554'ün çıkış latch'i ESP32 yeniden başlatmasında önceki durumu korur; 0 yazımı kilitli bir `ENERGIZE_TO_CLOSE` vanayı ~1 sn açardı `[K-2]`. **Değişiklik:** `Relay_Init`'ten hemen önce `SafetyStore::readBootLatchMask()` çalışır: `nvs_flash_init` + yalnız `ahbu_latch/latch` blob'unun okunması (CRC doğrulamalı). Kilit kaydı varsa `TCA9554PWR_Init(latchLocalLevelMask & latchLocalAssertMask, 0x00)`; yoksa bugünkü gibi 0. Bu okuma `ConfigManager`'dan bağımsızdır, bu yüzden yapılandırma bozuk olsa da çalışır. Okuma süresi ve `nvs_flash_init`'in `ConfigManager::begin` (`Preferences`) ile çift çağrılmasının zararsızlığı WP-F2'de doğrulanır.
2. **Kilit kaydı güvenli maskeleri taşır** `[Y-4]`. `latch` blob'u bölge durumlarının yanında, kilitlendiği anda hesaplanmış `safeAssertMask`/`safeLevelMask` değerlerini (yerel 8 bit + ek modül 32 bit) taşır. Açılışta bu maske **yapılandırmadan bağımsız** uygulanır. Böylece CRC bozulması, fabrika sıfırlaması ya da silinmiş eylemci tablosu kilitli vanayı açamaz.
3. **`SafetyManager::begin`**, `SmartAutomation::begin` içinde, açılıştaki kapatma bloğundan **önce** çağrılır. Yaptığı işler:
   - `ahbu_safety` ad alanını okur ve CRC'yi doğrular.
   - `ahbu_latch` kaydını okur, `bootc` sayacını artırır, `bn` nonce'unu üretir.
   - **Güvenli kip** `[Y-4][O-8]`. Şu durumlarda pano `safety.mode = "safe"` ile açılır ve `safe_mode` olayı üretir: (a) yapılandırma CRC'si bozuk (`cfg_corrupt`); (b) kilit kaydı var ama eylemci tablosu boş ya da kilitteki rölelerle uyuşmuyor (`latch_orphan`, ör. fabrika sıfırlaması sonrası); (c) `crash` kaydına göre son 10 dakikada ≥ 3 beklenmeyen sıfırlama (TWDT, panik, brownout; `esp_reset_reason`) (`crash_loop`). Güvenli kipte: kilitteki maske uygulanır ve her turda yeniden dayatılır; bütün `open` komutları `safe_mode` ile reddedilir; senaryo/iklim/varlık motorları çalışmaz; güvenlik dışı lamba/panjur komutları çalışır. Çıkış: (a)/(b) için yapılandırma yeniden yüklenip validate geçince ve kullanıcı yerel yoldan (LAN `POST /api/alarm/ack` `force=1`, CLI `SAFETY ACK FORCE` ya da `ALARM_ACK` DI'si 5 sn basılı) kilidi onaylayınca; (c) için 30 dk kesintisiz çalışma.
4. **Açılış maskesi** (`SmartAutomation.cpp:322-337`). `TCA_WriteOutputs(0x00)` yerine `TCA_WriteOutputs(safeBootMaskLocal)` yazılır. Bu maskede yalnız şu bitler 1 olur:
   - kilitli bölgedeki `ENERGIZE_TO_CLOSE` vanalar (kilit maskesinden),
   - kilitli olmayan bölgede, `act_pos` biti "açık" olan `DEENERGIZE_TO_CLOSE` **su** vanaları,
   - **gaz vanaları hiçbir zaman** (her açılışta güvenli/kapalı seviye; `ENERGIZE_TO_CLOSE` gaz vanasında bit 1) `[K-4]`.

   Ek modülde `extAllOff` yerine aynı maske coil'lere yazılır. Siren açılışta **çalmaz**; kilit sürüyorsa, `silenced=0` ise ve `siren_s` birikimi `run_limit_s`'i aşmadıysa ilk turda yeniden başlar `[O-8]`.
5. **Son komut konumu** `[K-1]`. `act_pos` (u16 bit maskesi, `ahbu_latch`'te) iki durumda yazılır: kullanıcının aç/kapat eylemi ve **güvenlik kapatması** (alarm, test sonrası gaz vanası). Açma yalnız kullanıcının `open` komutuyla (ya da `GAS_RESET`) olur. Gerekçe: K5 ve gündelik kullanım; bir elektrik kesintisinden sonra, alarm geçmişi olmayan bir vananın ev suyunu kendiliğinden kesik bırakması istenmez; alarmın kapattığı vana ise onaysız açılmamalı.
   - **Varsayılan:** konum kaydı yoksa su vanası "açık" kabul edilir (ilk kurulumdaki doğal durum "su akıyor"dur). Alarmın kapattığı vananın kaydı her zaman vardır, çünkü güvenlik kapatması `act_pos`'u yazar. `act_pos` yazımı başarısız olursa kilit kaydındaki maske yine geçerlidir; kilit kalktıktan sonraki kesintide vana açık gelebilir: bu durum `nvs_fail` olayıyla görünür kılınır.
6. **Yazılımsal yeniden başlatma ve kapanma** `[K-2][B1]`.
   - `shutdownHandler` (`SmartAutomation.cpp:362-364`) `TCA_WriteOutputs(0x00)` yerine yalnız güvenli bitleri koruyan maskeyi yazar; yine yalnız kapatır, interlock'a takılmaz.
   - `emergencyAllOff` (`:1074-1085`) donanıma doğrudan `TCA_WriteOutputs(0x00)`/`extAllOff()` yazmak yerine güvenli maskeyi yazar.
   - `_restartPending` dalı (`:1136-1146`) `checkDigitalInputs` ve `_safety.tick`'i çalıştırmaya devam eder; `applySafetyOutput` restart kapısından muaftır (§2.3).
   - Kilit varken `/api/system/reboot`, `/api/system/reset`, MQTT sys reboot ve CLI `REBOOT` (`WebPortal.cpp:1590-1618`, `main.cpp:542-544`) `409 zone_latched` / "kilit var, REBOOT FORCE yazın" döner; `force=1` ile geçilir. OTA güncellemesi kilit varken reddedilir.
7. **Fail-safe önerisi (sihirbaz metni).** "Elektrik kesildiğinde suyun da kesilmesini istiyorsanız enerji kesilince kapanan (NC) selenoid seçin. Motorlu vanalar kesintide konumunu korur."
8. **Kesinti anında su basarsa.** Pano enerjisizken hiçbir şey yapamaz; bu donanımsal bir sınırdır. NC selenoid zaten kapanır.
9. **Kilit kaydının yazım anı.** NVS'e alarm geçişi **eylemden sonra** yazılır; vana komutu yazımı beklemez. Yazım başarısız olursa kilit RAM'de sürer, `nvs_fail` olayı üretilir ve state'te uyarı görünür. Bu durumda yazılımsal yeniden başlatma `force` olmadan reddedilir (madde 6), dolayısıyla RAM'deki kilit planlı bir yeniden başlatmada kaybolmaz.

#### 5.1.7 Buluttan bağımsızlık

Bütün karar zinciri (sensör → çekirdek → röle) loopTask'ta, panoda çalışır. MQTT, Wi-Fi ya da saat gerektirmez. Bulut yoksa olaylar tamponda bekler (16'ya kadar). Yerel uygulama alarmı `/api/status` ve `/api/events` üzerinden görür; siren ve kart buzzer'ı yerel uyarıyı verir. İnternet ve yerel anahtar yokken de `ALARM_ACK` ve `VALVE_CLOSE` DI düğmeleriyle susturma, onay ve kapatma yapılabilir `[B15]`.

**RS485 taraması** `[O-5][B6]`. Tarama sürerken `stepExtOutputs` ve `pollExtModule` çalışmaz (`SmartAutomation.cpp:970`; `SmartAutomation_Rs485.cpp:228`). `tryEnterScan` (`:598-608`) bugün yalnız panjur hareketine bakıyor; kilitli bölge varsa ya da ek modülde eylemci veya güvenlik sensörü tanımlıysa tarama `409 safety_active` ile reddedilir.

### 5.2 Sunucu

#### 5.2.1 Migration `033_safety_alarms.sql`

031 ve 032 biçiminde yazılır: idempotent, `IF NOT EXISTS`, başlıkta rolling-deploy notu.

```sql
-- Kimlik türleri UUID'dir (001_multi_tenant_schema.sql:10,24,50,73) [Y1][B5]
-- alarms: bölge alarmının yaşam döngüsü (bir aid = bir satır)
CREATE TABLE IF NOT EXISTS alarms (
  id            BIGSERIAL PRIMARY KEY,
  home_id       UUID NOT NULL REFERENCES homes(id) ON DELETE CASCADE,
  device_id     UUID NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
  aid           VARCHAR(16) NOT NULL,              -- firmware eid (<bn>-<n>)
  zone          SMALLINT NOT NULL CHECK (zone BETWEEN 1 AND 4),
  kind          VARCHAR(12) NOT NULL,              -- water|gas|smoke|...
  status        VARCHAR(12) NOT NULL,              -- latched|fault|silenced|cleared|lost
  origin        VARCHAR(8)  NOT NULL DEFAULT 'event',  -- event|state|tomb
  sources       JSONB NOT NULL DEFAULT '[]',
  raised_at     TIMESTAMPTZ NOT NULL,
  device_epoch  BIGINT,                            -- time_ok ise panonun saati
  acked_by      UUID REFERENCES users(id) ON DELETE SET NULL,
  acked_at      TIMESTAMPTZ,
  ack_requested_at TIMESTAMPTZ,                    -- çevrimdışı panoya onay isteği (§5.2.4) [D5]
  ack_requested_by UUID REFERENCES users(id) ON DELETE SET NULL,
  cleared_at    TIMESTAMPTZ,
  cleared_by    VARCHAR(16),                       -- device_event|device_state|lost [D5]
  push_status   VARCHAR(12) NOT NULL DEFAULT 'pending',  -- 030 deseni: pending|claimed|sending|sent|failed|skipped
  push_attempts SMALLINT NOT NULL DEFAULT 0,
  fault_push_status VARCHAR(12),                   -- valve_fault için ikinci push (NULL = gerekmedi) [D5]
  CONSTRAINT alarms_status_check CHECK (status IN ('latched','fault','silenced','cleared','lost')),
  CONSTRAINT alarms_device_aid_uniq UNIQUE (device_id, aid)
);
CREATE INDEX IF NOT EXISTS alarms_home_open_idx ON alarms(home_id) WHERE status NOT IN ('cleared','lost');

-- devices: son state'ten güvenlik yetenekleri ve durum özeti [O1]
ALTER TABLE devices ADD COLUMN IF NOT EXISTS caps JSONB;
ALTER TABLE devices ADD COLUMN IF NOT EXISTS safety_state JSONB;

-- device_events: ham olay günlüğü + eid tekilleştirme (saklama: 90 gün, bakım işi)
CREATE TABLE IF NOT EXISTS device_events (
  device_id UUID NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
  eid       VARCHAR(16) NOT NULL,
  type      VARCHAR(24) NOT NULL,
  body      JSONB NOT NULL,
  received_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (device_id, eid)
);

-- device_configs: panonun modül yapılandırma kopyası (K5: asıl kaynak pano)
CREATE TABLE IF NOT EXISTS device_configs (
  device_id UUID NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
  module    VARCHAR(16) NOT NULL,
  rev       BIGINT NOT NULL, crc VARCHAR(8) NOT NULL,
  body      JSONB NOT NULL, pending JSONB,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (device_id, module)
);

-- endpoints: eylemci ve dimmer (K1/K4). type CHECK'ine DOKUNULMAZ (E2'den kaçınılır).
ALTER TABLE endpoints ADD COLUMN IF NOT EXISTS actuator_type VARCHAR(10);   -- NULL|valve|siren|fan|generic
ALTER TABLE endpoints ADD COLUMN IF NOT EXISTS dimmable BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE endpoints ADD COLUMN IF NOT EXISTS dimmer_source VARCHAR(8);    -- NULL|modbus|bridge
-- CHECK'ler NOT VALID + VALIDATE deseniyle (030:46-49)

-- mqtt_acl: mevcut cihaz kimliklerine ev/{t}/event yayını (E3) [O9]
-- mqtt_acl'de benzersiz kısıt YOK (020:48-59): ON CONFLICT işe yaramaz, NOT EXISTS kullanılır.
-- LIKE 'd_%' kullanılmaz ('_' joker karakterdir); kimlik türü kind='device' ile seçilir.
INSERT INTO mqtt_acl (credential_id, username, permission, action, topic)
SELECT c.id, c.username, 'allow', 'publish', 'ev/' || <konu kimliği ifadesi> || '/event'
  FROM mqtt_credentials c
 WHERE c.kind = 'device'
   AND NOT EXISTS (SELECT 1 FROM mqtt_acl a
                    WHERE a.credential_id = c.id AND a.action = 'publish' AND a.topic LIKE '%/event');
-- <konu kimliği ifadesi>: mevcut 'ev/{t}/state' ACL satırındaki {t} ile aynı kaynaktan (020 ve mqtt_credential_service.js:194-207 desenine bakılarak yazılır)
```

**Dikkat edilecekler**

- Anahtar türleri **UUID** olarak düzeltildi `[Y1][B5]`. `mqtt_acl` kolonları (`020_mqtt_credentials.sql:48-56`) ve konu kimliği ifadesi uygulama sırasında doğrulanır.
- **Kabul ölçütü:** migration gerçek PG'de (55432) QA ikilileriyle uygulanır ve iki kez çalıştırılınca satır sayıları değişmez (idempotentlik, özellikle `mqtt_acl`).
- `scripts/check_schema_contract.js` yeni SQL'i taramalı.
- Yeni cihaz kimliği üreten servis de event yayın satırını eklemeli (`services/mqtt_credential_service.js:194-207`).

#### 5.2.2 Olay işleme (`services/alarm_service.js` + köprü)

**Köprü değişiklikleri**

- `INCOMING_TOPIC_RE` deseni `(state|status|event)` olur. `SUBSCRIPTIONS` listesine `ev/+/event` eklenir (`mqtt_bridge.js:79,108`).
- `handleIncomingMessage` (`:999-1071`) içine `event` dalı gelir:
  - Retained mesaj yok sayılır.
  - Yük 4 KB'ı aşarsa ret. (`cfg_dump` parçası ≤ 3,5 KB + zarf bu sınıra sığar `[Y6]`.)
  - Doğrulama `validateEventPayload` ile yapılır (katı: bilinmeyen `type` olursa günlük + ack, işlem yok). `uid` zorunludur ve konu kimliğindeki evin cihazlarından biri olmalıdır; `device_id` bu `uid`'den çözülür.
  - `type:"cfg_dump"` olay işleme hattına girmez; `device_configs` güncelleyicisine gider, ack üretmez.
  - İş `KeyedWorkQueue`'ya `kind:'event'` ve **`coalesce:false`** ile girer (`:404-410`). Aksi halde ara alarmlar birleşip kaybolur.
- Servis `_getAlarmService` / `_notifyAlarm` ile bağlanır; tembel kurulum ve hata yalıtımı `_getLayoutSync` (`:858-880`) ile aynıdır.
- Push servisi köprüye `start()` sırasında enjekte edilir (`server.js:232-238`'deki örnek). Köprü tekilinde push bulunmuyor (`:1391`).

**İşlem sırası, tek transaction**

1. `INSERT INTO device_events … ON CONFLICT DO NOTHING`. Satır eklenmediyse olay yinelenmiştir: 4. adıma atla.
2. Olay türüne göre `alarms` tablosu güncellenir:
   - `alarm_raised`: `INSERT … ON CONFLICT (device_id, aid) DO NOTHING`. Çakışan satır `origin='tomb'` (mezar taşı) ise hiçbir şey açılmaz ve push gitmez `[O7]`.
   - `valve_fault`: `status='fault'`.
   - `alarm_silenced`: `status='silenced'`.
   - `alarm_cleared`: `status='cleared'`, `cleared_at`, `cleared_by='device_event'`. **Bilinmeyen `aid`** için (sırasız teslim: `alarm_raised` henüz gelmedi) kapalı bir mezar taşı satırı yazılır: `status='cleared'`, `origin='tomb'`, `push_status='skipped'` `[O7]`.
3. `device_audit_logs` tablosuna `event='safety_<type>'` yazılır (021:99-111).
4. COMMIT, ardından `publishCommand(t, {cmd:'event_ack', uid, eids:[…]})` (`uid` zorunlu, §3.3) `[Y4]`. Birikmiş onaylar pano başına 250 ms birleştirme penceresiyle ve en çok 8 eid olarak gönderilir.
5. Satır yeni açıldıysa push talep edilir (aşağıda).

**State uzlaştırması.** `_processState` COMMIT'inden sonra (`:1144-1158`) `devices.caps` ve `devices.safety_state` yazılır ve `alarmService.onLiveState(device, state)` çağrılır:

- Panoda `latched` ya da `fault` olan ama tabloda açık satırı olmayan bölge için satır açılır (`origin='state'`, `aid` state'ten gelir).
- **Kanıtlı kapanma** `[O-9][O11]`. Tabloda açık olan satır yalnız şu iki kanıttan biriyle `cleared` olur: (a) `alarm_cleared` olayı; (b) state'te **aynı bölge** `normal`, `safety.mode = "normal"` ve `cfg.safety.rev` geriye gitmemiş. Kilit artık fabrika sıfırlamasından ve yeniden başlatmadan sağ çıktığı için (§2.7) bu üç koşul birlikte "kilit gerçekten kaldırıldı, yalnız `alarm_cleared` olayı kayboldu" demektir. Bu durumda `cleared_by='device_state'`.
- Kanıtsız kayıp: `caps` yok, `safety` anahtarı yok (§3.1 kural 5), `safety.mode="safe"` ya da yapılandırma `rev`'i geriye gitmiş/sıfırlanmışken açık satır `status='lost'`, `cleared_by='lost'` yapılır ve owner'a "Alarm durumu doğrulanamadı, panoyu kontrol edin" push'u gider.

Bu uzlaştırma, yeniden başlatmada kaybolan olayları telafi eder (§3.4).

#### 5.2.3 Yüksek öncelikli push

`push_service.buildMessage` içine tür parametresi eklenir (E4: `push_service.js:49-52,130-182`). Yeni tür `safety_alarm`:

| Alan | Değer |
|---|---|
| Android kanalı | `safety_alarm` (önem düzeyi `IMPORTANCE_HIGH`, alarm sesi; uygulama oluşturur) |
| Android `priority` | `HIGH`; `ttl` 6 sa |
| APNs | `apns-priority 10`. `interruption-level` değeri, kritik izin (entitlement) varsa `critical` (`sound:{critical:1,name:'alarm.caf',volume:1}`), yoksa `time-sensitive` |
| collapse / `apns-collapse-id` | `alarm_<home>_<device>_<zone>` |
| Kategori | `SAFETY_ALARM` (eylemler: "Onayla", "Vanayı Kapat") |
| Veri | `{type:'safety_alarm', v:1, home_id, device_id, alarm_id, zone, kind, status}` |
| Alıcılar | `owner` ve `resident` rolündeki aktif üyeler. `guest` ve servis rolleri (`super_user`, `service_user`, `service_session`) dahil edilmez; misafir için karar §7.2'de açık sorudur. Rol filtresi `push_service.js:473` deseniyle uygulanır. |

- **Tek gönderim garantisi.** `peace_notification_logs` desenindeki `claimed → sending → sent/failed` döngüsü `alarms.push_status` üzerinde uygulanır. Bu, "en çok bir push" kuralıdır. `valve_fault` ikinci bir push üretir; durumu `fault_push_status` kolonundadır `[D5]`.
- **Push yapılandırılmamışsa** `PUSH_NOT_CONFIGURED` döner (`:544-550`), `push_status='skipped'` yazılır. Alarm kaydı yine açılır.

#### 5.2.4 Komut ve onay akışı

**Şema** (`utils/command_schema.js`). Yeni türler: `actuator`, `alarm_ack`, `alarm_test` (`KINDS` `:45-51`). Doğrulayıcılar `findUnknownKey` desenini izler (`:66`).

**Yetki** (`utils/role_matrix.js:31-53`). Yeni yetenekler:

Rol adları koddaki `ROLES` sabitleridir (`role_matrix.js:18-25`): `SUPER`=`super_user`, `STAFF`=`service_user`, `SESSION`=`service_session`, `OWNER`, `RESIDENT`, `GUEST` `[O2]`.

| Yetenek | Roller | Not |
|---|---|---|
| `actuator_close` | `ALL_ROLES` (misafir dahil) | güvenli yön: vanayı kapatmak, sireni susturmak; mevcut `control` ile aynı küme |
| `safety_ack` | SUPER, STAFF, SESSION, OWNER, RESIDENT | misafir yok |
| `actuator_control` | SUPER, STAFF, SESSION, OWNER, RESIDENT | su vanası açma, siren/fan/generic açma. **Gaz vanası açma hiçbir rolde yok** (yalnız yerinde, §2.4) `[K-4]` |
| `safety_test` | SUPER, STAFF, SESSION, OWNER | |
| `safety_config` | SUPER, STAFF, SESSION, OWNER | |

`capabilityForKind` eşlemesi buna göre güncellenir (`:245-259`); `actuator` türünde yetenek, istenen `to` değerine göre (`closed`/`off` → `actuator_close`, diğerleri → `actuator_control`) seçilir.

**Hedef denetimi** (`device_service._assertCommandTarget` `:1923-1933`), sırasıyla:

1. Eylemci olan bir uç noktaya (`actuator_type IS NOT NULL`) düz `relay` komutu gelirse `409 ACTUATOR_USE_SAFETY_COMMAND`.
2. Gaz vanasına `open` → `409 GAS_LOCAL_ONLY`.
3. Vana `open` isteğinde sunucu `devices.safety_state`'te bölgenin `normal` ve panonun `mode` değerinin `normal` olduğunu doğrular; değilse `409 ZONE_ALARM_ACTIVE`. Bu bir savunma katmanıdır; asıl yetki firmware'dedir.
4. `devices.caps` içinde `safety` yoksa `409 FIRMWARE_UNSUPPORTED` `[O1]`.

**Rotalar**

| Rota | İşlev |
|---|---|
| `GET /homes/:id/alarms?state=open|all&before=` | alarm listesi |
| `POST /homes/:id/alarms/:alarmId/ack` | panoya `alarm_ack {zone, aid, uid, id}` gönderir; `aid` alarm satırından gelir `[Y-9]` |
| `POST /homes/:id/devices/:deviceId/actuators/:aid` `{state}` | eylemci komutu |
| `POST …/alarm-test` | bölge testi |

Onay `expectAck` ile `last_id` yankısından alınır (`mqtt_bridge.js:1292`). `last_rej.id` eşleşirse beklemeden 409 ve ret kodu döner; bunun için `expectAck`'e "red" yankısı da eklenir. **Ret yankısı yalnız hedef panonun `uid`'siyle gelen state'ten kabul edilir** `[Y5]`: bekleyici anahtarı (`ackKey`, `:359`) konu + komut kimliği + hedef `uid` olur. Böylece aynı evdeki başka bir panonun (ör. düz `relay:5` komutunu kendi vanası yüzünden reddeden A panosunun) `last_rej`'i B panosuna giden komutu 409'a çevirmez. Bütün yeni komutlar `uid` taşır (§3.3).

**Pano çevrimdışıysa** bugünkü gibi 409 döner (`sendCommand` `:1853-1905`). Çevrimdışı panoya onay uygulanamaz; alarm satırına `ack_requested_at`/`ack_requested_by` yazılır. Pano dönünce uzlaştırıcı onayı **yalnız** state'teki bölge `aid`'si satırın `aid`'siyle aynıysa gönderir (`aid` ile birlikte); farklıysa (kullanıcının görmediği yeni alarm) gönderilmez ve istek düşürülür `[Y-9]`. Bu yalnız ack için geçerlidir; vana açma asla kuyruğa alınmaz.

**`event_ack` yalnız backend'den çıkar.** Uygulama bu komutu gönderemez (şema `kind` listesinde yoktur).

### 5.3 Flutter durum modeli ve arayüz

#### 5.3.1 Sınıflar (`lib/models/safety_models.dart`, yeni)

```dart
enum ZoneStatus { normal, latched, fault, test, unknown }
enum ActuatorKind { valve, siren, fan, generic, unknown }
enum ValvePos { closed, closing, open, opening, cmdClosed, cmdOpen, unknown }

@immutable
class SensorItem {            // fromJson: id(String, zorunlu), src, kind, zone, active, ok, name
  final String id; final String src; final String kind; final int zone;
  final bool active; final bool ok; final String name;
}

@immutable
class AlarmItem {
  final int zone; final String kind; final ZoneStatus status;
  final String? aid; final bool silenced; final int? sinceEpoch; final int? sinceUptime;
  final List<String> sources;
  /// state.safety.zones[] öğesinden; st=='normal' ise null döner (alarm değil).
  static AlarmItem? fromZoneJson(Map<String, dynamic> j);
}

@immutable
class ActuatorItem {
  final String id; final int relay; final ActuatorKind kind; final List<int> zones;
  final ValvePos? pos; final bool? on; final bool? feedback; final bool fault; final String name;
  bool get isValve => kind == ActuatorKind.valve;
  bool get isClosedOrClosing => pos == ValvePos.closed || pos == ValvePos.closing || pos == ValvePos.cmdClosed;
  static ActuatorItem? fromJson(Map<String, dynamic> j);   // kimliksiz ya da bozuk öğe → null (atlanır, fırlatmaz)
}

@immutable
class SafetyState {
  final bool supported;                 // caps içinde 'safety' var mı
  final String policy;                  // on|off
  final List<SensorItem> sensors; final List<AlarmItem> alarms;
  final List<ActuatorItem> actuators; final Map<int, ZoneStatus> zones;
  final ({String id, String code})? lastRej;
  static const unsupported = SafetyState._unsupported();
  factory SafetyState.fromStateJson(Map<String, dynamic> state);
  final bool safeMode;                  // safety.mode == 'safe'
  bool get hasActiveAlarm => alarms.any((a) => a.status != ZoneStatus.normal);
  // [Y-3][K-4]: sensör ok değilse kuru sayılmaz; gaz vanası uygulamadan açılmaz.
  bool canOpenValve(ActuatorItem v) => !safeMode && v.medium != 'gas' &&
      v.zones.every((z) => zones[z] == ZoneStatus.normal) &&
      sensors.where((s) => s.kind == v.medium && v.zones.contains(s.zone))
             .every((s) => s.ok && !s.active);
}
```

`ActuatorItem`'a `medium` (String?) alanı eklenir. `SensorItem`/`ActuatorItem` adları state'te gelmez; `name` alanları yapılandırma kopyasından (bulut: `device_configs` üzerinden uç nokta yanıtı; LAN: `GET /api/safety/config`) kimlikle doldurulur, yoksa kimlik gösterilir `[B12]`.

**Ayrıştırma kuralları**

- `fromJson` hiçbir zaman fırlatmaz. Bilinmeyen `kind` değeri `unknown` olur ve satır yine görünür. `EndpointModel.fromJson` bilinmeyen türde fırlatıyor (`cloud_models.dart:403`); bu sınıflar o hatayı tekrarlamamalı.
- Dizi uzunlukları kesilir: sensör 64, eylemci 16, bölge 4.

**Eşitlik.** Bütün sınıflar `==` ve `hashCode` uygular (`Object.hash` + `listEquals`/`mapEquals`). `_applyCloudSnapshot` yalnız `SafetyState` değiştiğinde bildirim yapar (PF-04 deseni, `automation_state.dart:2648-2652`). Aksi halde 30 sn'lik kalp atışı bütün arayüzü uyandırır.

#### 5.3.2 Bağlantı noktaları

| Ne | Nerede |
|---|---|
| `DeviceStatus.safety` alanı | `lib/models/automation_models.dart` `DeviceStatus` alanları (295-358). `fromJson` içinde (391-440) `SafetyState.fromStateJson(json)` çağrılır, `copyWith` (551+) güncellenir. MQTT (`ev_mqtt_service.dart:643-658`) ve LAN (`automation_state.dart:2870`) yolları aynı `fromJson`'u kullandığı için iki kip birden kapsanır. `restricted` sezgisi (402-405) değişmez. |
| `RelayItem.actuator` | `automation_models.dart` `RelayItem` (5-91): `act` okunur. `controllableRelays` (380-385) eylemci rölelerini **hariç tutar**, böylece vana lamba kartına düşmez. `relayItemsFromEndpoints` (`endpoint_sync.dart:107-117`) `EndpointModel.actuatorType` alanını taşır. `ReportedLayout.signature` (`endpoint_sync.dart:180-197`) `act` değerini de içerir `[Y2]`. Yerel "tüm lambalar" sayaçları ve hızlı senaryolar eylemci rölelerini saymaz `[Y3]`. |
| `EndpointModel` | `actuatorType`, `dimmable`, `dimmerSource` alanları eklenir (`cloud_models.dart:333-465`). `type` değerleri ve `knownTypes` (394) **değişmez**. |
| Durum | `automation_state.dart` `_applyCloudSnapshot` (2604-2652). Yeni `safety`, `alarmItems` ve `actuatorItems` getter'ları `_viewGen` önbelleğini kullanır (459-485 deseni). Sıfırlama 989, 1045 ve 2058'de yapılır. |
| Komutlar | `closeValve(a)`, `openValve(a)`, `ackAlarm(zone)`, `testZone(zone)`. Anahtarlar: `actuator:<id>`, `alarm:ack:<zone>`, `alarm:test:<zone>`. `_submit`/`_dispatch` (3107-3148) deseni kullanılır. Bulutta yeni rotalara, LAN'da `automation_api_service.dart`'a eklenecek `postActuator`, `ackAlarm` ve `testAlarm` çağrılarına gider. |
| Onay | `CommandConfirm` (`command_pipeline.dart:575-614`) içine eklenenler: `valvePos(id, {closed})` (`closed`, `cmd_closed` ya da `closing` kabul edilir), `alarmSilencedOrCleared(zone)`, `actuatorOn(id, on)`. `observe` (497-514) ayrıca `lastRej.id == cmdId` ise komutu **hemen** reddeder ve geri alır; kullanıcıya ret kodunun Türkçe metni gösterilir. |
| Yetki | `capabilities.dart` içine `canAckAlarm`, `canControlActuators`, `canTestSafety` bayrakları gelir; sunucu yetenekleriyle eşlenir. |

#### 5.3.3 Kartlar ve tek dokunuş eylemleri

**`CriticalAlarmCard`**

- Yeri: `apartment_dashboard.dart` `_CloudContent` içinde `OfflineBanner`'dan sonra, `PeaceBanner`'ın hemen **üstü** (294-295). Aynı kart `_DirectContent`'e de girer (K5).
- Görünüm: tam genişlik, Neon Glass kırmızı tonu. Başlık "Su baskını: Mutfak Tezgah Altı" ve geçen süre.
- Vana durumu satırı:
  - "Ana Su Vanası: Kapalı (doğrulandı)" ya da "Kapatıldı (geri bildirim yok)".
  - VALVE_FAULT durumunda: "Vana kapanmadı! Ana vanayı elle kapatın".
- Düğmeler:
  - **[Sesi Sustur / Alarmı Onayla]**: ıslakken "Sustur", kuruyken "Onayla".
  - **[Vanayı Kapat]**: yalnız açık ya da belirsiz vana varsa görünür.
  - Kilit kalkınca kartın yerini "Su kesik. **[Vanayı Aç]**" bilgi kartı alır.
- Hareket: Hareket v3 kurallarına uyar. Sürekli yanıp sönme yerine tek seferlik giriş animasyonu ve erişilebilir `liveRegion`.

**`DeviceSections`'ta yeni bölüm** (`endpoint_sections.dart:293-383`)

- "Güvenlik ve Eylemciler" bölümü panjurlardan önce gelir. `ActuatorCard` gösterir: vana durumu pili, siren/fan anahtarı ve bölgede alarm varsa kilitli "Aç" düğmesi ile kısa gerekçe metni.
- `_signature` (272) eylemci kimliklerini ve durumlarını kapsamalı.
- Sensörler aynı bölümde küçük pillerle gösterilir: "Kuru", "Islak", "Bağlantı yok". DI pillerinden farklı olarak bulut kipinde de görünür.

**Ret metinleri.** `zone_latched`: "Alarm sürerken vana açılamaz. Önce sensörün kuruduğundan emin olup alarmı onaylayın." `actuator_relay`: "Bu kanal bir güvenlik cihazına bağlı; lamba gibi açılamaz." `gas_local_only`: "Gaz vanası güvenlik gereği yalnız yerinde, panodaki düğmeyle açılır." `stale_ack`: "Bu arada yeni bir alarm oluştu; lütfen güncel alarmı inceleyip yeniden onaylayın." `safe_mode`: "Pano güvenli kipte; vanalar açılamaz. Kurulumcunuza başvurun."

### 5.4 QA simülatörü modeli

| Dosya | İçerik |
|---|---|
| `sim/fw/safety_fsm.js` | `SafetyFsm.h`'nin birebir portu |
| `sim/fw/sensor_hub.js` | `SensorHub.h` portu |
| `sim/fw/actuator_map.js` | `ActuatorMap.h` portu |
| `sim/fw/event_outbox.js` | `EventOutbox.h` portu |
| `sim/fw/SOURCES.json` | dört yeni başlık için eşleme; `node run.js fwcheck --update` |
| `sim/fw/automation.js` | `tick` sırasına `safety.tick` eklenir (firmware ile aynı yer); `executeCommand` eylemci koruması |
| `sim/fw/mqtt_manager.js` | state v:3 alanları, `parseCommand` yeni komutları, `event` konusu ve `event_ack` |
| `sim/device_sim.js` | **Hata enjeksiyon API'si:** `setSensor(id, wet)`, `pulseSensor(id, onMs, offMs, n)` (damla), `setValveFeedback(id, 'follow'|'stuck_open'|'none', delayMs)`, `reboot({keepNvs:true})`, `softRestart()` (shutdown kancası dahil), `factoryReset()`, `corruptSafetyCfg()`, `extModuleDown(ms)`, `dropEventAcks(n)`, `reorderEvents()`, `brokerDown(ms)`, `bridgeSilence(slot)` |
| `sim/local_api.js` | §3.5 rotaları |
| `sim/command_schema.js` | sunucu şemasıyla eşleşen yeni türler |

Simülatör NVS'i bugün nasıl modelliyorsa (`config_manager.js`) `ahbu_safety` ve `ahbu_latch` da aynı şekilde modellenir. `reboot` ve `factoryReset` sonrası kilit geri gelir.

**Sahiplik** `[B8]`. `SOURCES.json` firmware dosyalarının SHA-256 özetini tutar ve `fwcheck.test.js` (`:28-30`) her değişiklikte kırmızı olur. Bu yüzden her F paketi, dokunduğu firmware dosyasının sim portunu ve `node run.js fwcheck --update` adımını **kendi içinde** yapar. `SOURCES.json` paylaşılan dosyadır; çakışmayı önlemek için F paketleri sırayla birleştirilir (§7.3).

### 5.5 Test planı

**Firmware, native Unity** (`test/test_safety_fsm`, `test/test_sensor_hub`, `test/test_actuator_map`, `test/test_safety_config`, `test/test_event_outbox`)

- **Çalıştırma ortamı** `[B17]`. Bu makinede gcc/clang yok; native testler `platformio.ini`'deki NDK clang (wasm32) + Node shim düzeneğiyle koşuyor. WP-F1'in ilk adımı, yeni test dizinlerinin bu shim'le derlenip koştuğunu bir iskelet testle doğrulamaktır.
- **SafetyFsm:**
  - Islak sinyal onay süresinden kısaysa alarm yok.
  - Damla deseni (ör. 300 ms aktif / 200 ms pasif) pencereli birikimle alarma ulaşır `[O-1]`.
  - `ok=false` sensör varken kuruluk sayacı ilerlemez; kilit kalkmaz; açma reddedilir `[Y-3]`.
  - Kilit kalkınca `act_pos` kapalı; ardından "elektrik kesintisi" (yeniden kurulum) vanayı açmaz `[K-1]`.
  - Tür → akışkan: su sensörü gaz vanasını, duman hiçbir vanayı kapatmaz `[K-3]`.
  - Gaz vanası: TEST sonrası kapalı; MQTT/LAN `open` → `gas_local_only`; `GAS_RESET` ile açılır `[K-4]`.
  - Bayat `aid` ile ACK → `stale_ack`, susturma yok `[Y-9]`.
  - `policy_on=0` mevcut kilidi kaldırmaz `[O-10]`.
  - Onaylı ıslak: LATCHED olur, eylemler `CLOSE`/`ON`.
  - Islakken ACK yalnız susturur; kuru + `dry_hold` sonrası NORMAL; vana kapalı kalır.
  - Geri bildirim zaman aşımı FAULT'a götürür; geri bildirim gelince LATCHED'e döner.
  - TEST sırasında gerçek ıslak sinyal LATCHED'e götürür; TEST sonunda vana önceki konuma döner.
  - Çok bölgeli vananın açma izni.
  - `millis` taşması (`now` 0xFFFFF000'den başlatılır).
- **SensorHub:** NC çevirme; köprü kalp atışı aşımında `ok=false` olur ve vana eylemi yapılmaz; seviye tabanlı olduğu için ilk okumada ıslak sensör yakalanır; ek DI ilk okumadan önce ve modül yanıt vermezken `ok=false` (NC sensör sahte alarm üretmez) `[Y-2]`; `ok` geçişlerinde `sensor_fault`/`_cleared`.
- **DiGate geçişi:** MOMENTARY bir DI sensöre çevrilince `clearActed` + `momentary_` temizliği `[B17]`.
- **ActuatorMap:** `close_mode` × mantıksal durum tablosu; `safeBootMask` (kilitli/kilitsiz × iki kip × son konum × su/gaz); kilit maskesinin yapılandırmasız uygulanması `[Y-4]`; panjur çifti ve IMPULSE rölesi reddi; `TCA_SetSafeBits` maske süzgeci (saf yardımcı olarak); ham komutun yön kuralı (kapatma serbest, açma ret) `[O4]`.
- **SafetyConfig:** `validate(system, safety)` sınırları ve çapraz kurallar (panjura çevrilen eylemci, kanal sayısı düşüşü, `medium` eksik, siren `run_limit_s=0`, gaz/duman NO bağlantı); kilitli bölgeye dokunan değişiklik reddi; blob serileştirme gidiş-dönüşü; bozuk CRC → güvenli kip.
- **EventOutbox:** eid biçimi (`<bn>-<n>`); yeniden deneme zamanlaması; taşmada atılma önceliği; ack ile silme; çoklu eid ack; yeniden bağlanma penceresinde boşaltmama `[D4]`; en kötü durum yük boyutu ≤ 400 B `[Y6]`.
- **Çökme döngüsü:** son 10 dk'da 3 beklenmeyen sıfırlama → güvenli kip; siren birikimi `run_limit_s`'i aşmaz `[O-8]`.

**QA simülatörü** (`test/fw_safety_*.test.js` Unity portları + uçtan uca)

- `sim_safety.test.js`: ıslak → vana kapandı → state v:3 → event → ack. Broker kesikken alarm oluşur, olay bekler ve bağlantı dönünce teslim edilir. Alarm sırasında yeniden başlatma: vana kapalı kalır, state `latched` ve aynı `aid`. `stuck_open` geri bildirimi FAULT üretir. `open` reddi `last_rej` ile görülür.
- **Kesinti ve yeniden başlatma senaryoları** `[K-1][K-2][Y-4][Y-5]`: (a) kilit kalktıktan sonra `reboot` → vana kapalı; (b) kilitliyken `softRestart` → `shutdownHandler` ve `Relay_Init` boyunca ENERGIZE_TO_CLOSE vananın bit izi hiç 0'a düşmez; (c) kilitliyken `factoryReset` → güvenli kip, vana kapalı; (d) `corruptSafetyCfg` → güvenli kip, vana kapalı, `open` → `safe_mode`; (e) kilitliyken `/api/system/reboot` `force`'suz → 409.
- **Yasak yollar** `[Y-6][B2][B3]`: `/api/rs485/relay` ve `/api/rs485/send` ile ek modüldeki vanayı açma → ret; `/api/config` ile eylemci rölesini panjura çevirme → 409; ek modülü kapatma → 409 (kilitliyken) ya da `actuator_fault`; `applyRawExtAllOff` sonrası ilk turda güvenli seviye geri gelir.
- **Ek modül arızası** `[Y-2][B6][O-5]`: `extModuleDown` → ek DI sensörleri `ok=false`, `sensor_fault`, kuruluk ilerlemez; RS485 taraması güvenlik varken 409.
- **Çok panolu ev** `[Y5][Y4]`: iki sim pano, aynı `a1`; `uid`'li komut yalnız hedefte uygulanır; A'nın `last_rej`'i B'ye giden komutu 409'a çevirmez; `event_ack` yalnız hedef panonun eid'lerini siler.
- `sim_safety_equivalence.test.js`: §2.9 (WP-F2 kabul ölçütü).
- `fwcheck.test.js`: yeni eşlemeler.

**Sunucu** (`test/safety/*`, `*_pg.test.js`)

- Migration testi (031 deseninde), gerçek PG (55432): UUID FK'ler; idempotentlik (iki çalıştırmada `mqtt_acl` satır sayısı aynı) `[O9]`; CHECK ve UNIQUE kısıtları.
- `alarm_service`:
  - Yinelenen eid yine ack üretir ama tek satır açar.
  - Olay kaybolduğunda state uzlaştırması satırı açar.
  - State `normal` + `mode=normal` gelince satır `cleared` olur; `safety` anahtarı yok / `caps` yok / `mode=safe` → `lost` + push `[O-9][O11]`.
  - Sırasız teslim: önce `alarm_cleared`, sonra `alarm_raised` → mezar taşı, push yok `[O7]`.
  - Push talebi en çok bir kez yapılır; push yapılandırılmamışsa `skipped`.
- Yerleşim eşitlemesi: `act` → `actuator_type`; `act` değişimi imzayı değiştirir; gece huzur özeti ve "hepsini kapat" vana rölesini saymaz; vana kanalındaki zamanlı kural kapatılır `[Y2][Y3][O6]`.
- Köprü: ret yankısı yalnız hedef `uid`'den kabul edilir `[Y5]`; `validateStatePayload` `caps`/`safety`/`last_rej`'i çıkarır `[O1]`; `sensors` ≤ 56 sınırı `[D6]`.
- Köprü (`_mini_broker.js`): `event` aboneliği; retained olay yok sayılır; `coalesce:false` ile ardışık iki olay da işlenir.
- Komut şeması ve yetki matrisi: yeni türler, misafirin vana açamaması, eylemci rölesine düz `relay` gelince 409.
- `check_schema_contract.js` yeşil.
- Push: `buildMessage('safety_alarm')` yük şekli (kritik izin var ve yok).

**Flutter** (`test/models/safety_models_test.dart`, `test/services/automation_state_safety_test.dart`, widget testleri)

- `fromStateJson`:
  - `v:2` yükü `unsupported` üretir.
  - `v:3` örneği (§3.2) birebir ayrıştırılır.
  - Bilinmeyen `kind` `unknown` olur ve fırlatmaz.
  - Kesme sınırları uygulanır.
- Eşitlik: aynı JSON iki kez gelirse bildirim yapılmaz.
- `controllableRelays` eylemciyi dışarıda bırakır.
- `CommandConfirm.valvePos`; `lastRej` gelince anında geri alma.
- `CriticalAlarmCard` durumları: susturma, onay, fault, açma kilidi. Altın görseller (PNG önizleme düzeneği) çekilir.
- LAN kipinde aynı kartın göründüğü doğrulanır.
- Sihirbaz: `RelayCheck` `v:1` → `v:2` geri yükleme; dimmer paneli metninde adres ve kanal yer tutucuları dolu gelir.

**Saha listesi (plan 6.2'ye eklenecek aşama)**

- Gerçek su sensörüyle damla testi.
- NC selenoid ile güç kesme testi; alarm temizlendikten **sonra** güç kesme: vana kapalı açılmalı `[K-1]`.
- Alarm sırasında `REBOOT` (409 beklenir) ve `REBOOT FORCE`: ENERGIZE_TO_CLOSE vana yeniden başlatma boyunca hiç açılmamalı (osiloskop ya da vana geri bildirimiyle) `[K-2]`.
- Alarm sırasında fabrika sıfırlaması (`force`): vana kapalı kalmalı, pano güvenli kipte açılmalı `[Y-5]`.
- Ek modül RS485 kablosu çekilince: ek DI sensörü "Bağlantı yok", vana açma reddi `[Y-2]`.
- Geri bildirimli motorlu vana için zaman aşımı ölçümü.
- Gecikme ölçümü: yerel DI → yerel röle ve ek DI → ek röle ayrı ayrı `[O-6]`.

---

## 6. Sonraki modüller aynı kalıba nasıl oturur

| Modül | Sensör (K2) | Saf çekirdek | Eylemci (K1) | Sözleşme |
|---|---|---|---|---|
| **Gaz/duman (2.4, K3)** | DI ya da köprü, `kind: gas|smoke`; dedektörün kuru kontağı (çoğunlukla NC ya da röle çıkışı), `confirm_ms` 300 | Aynı `SafetyFsm`; politika tablosu tür → akışkan eşlemesiyle eylem kümesi seçer `[K-3][Y-1]`: gaz → `medium=GAS` vanalar `CLOSE` + siren; FAN yalnız ATEX onaylıysa `ON`, değilse dokunulmaz. Duman → siren + FAN **OFF** (duman yayılmasın); **hiçbir vana kapatılmaz** (yangın suyu). Dedektör bağlantısı NC zorunlu `[O-2]`; gaz vanası yalnız yerinde açılır `[K-4]` | valve/siren/fan | Aynı `alarms`, push türü `safety_alarm` (`kind` farklı). Kalibrasyon kodu yok |
| **Kapı/pencere (2.5)** | `door`/`window` | `IntrusionFsm.h` (DISARMED/ARMED_HOME/ARMED_AWAY/ENTRY_DELAY/ALARM); `safety_arm` komutu | siren | `safety.arm` alanı; pencere durumu iklime girdi |
| **İklim (3.1-3.3)** | I²C ya da RS485 sıcaklık/nem → `AnalogSensor` (SensorSource'un sayısal kardeşi, 0,1 birim tamsayı) | `climate/Thermostat.h`: histerezis, en kısa açık/kapalı süreleri, pencere açıkken dur | kombi rölesi = `generic` | `climate: {zones:[{id, t10, h10, target10, mode, heating}]}`, komut `climate_target` |
| **Enerji (3.4)** | RS485 Modbus sayaç; `pollExtModule` sonrası sınırlı süreli ikinci yoklayıcı, aynı `rs485Exchange` mutex'i (`SmartAutomation_Rs485.cpp:74-128`) | `energy/EnergyMeter.h` (ayrıştırma + aşırı yük eşiği) | yük atma = generic/lamba kapatma | `energy: {w, wh_today, over}`; aşırı yük olayı `alarms`'a düşük önemle yazılır |
| **Varlık (4.2)** | mmWave/PIR DI ya da köprü, `motion` | `presence/PresenceTimer.h` (oda başına "son görülme + bekleme süresi") | lamba (`CmdSource::RULE`; eylemci rölesine ham erişimi yok, §2.3) | `presence` alanı ayrılmış |
| **Güneş (4.3)** | RTC + konum (NVS) | `SunCalc.h` (saf, tamsayı yaklaşık hesap) | panjur (mevcut `SHUTTER_POS`) | senaryo tetiği |
| **Senaryolar (5.2-5.4)** | yukarıdakilerin olayları + saat | `scenes/SceneEngine.h`: tetik (saat, olay, sensör) + koşul + eylem listesi (≤ 8). Eylemler mevcut `CmdType`'lara çevrilip `CmdSource::RULE` ile **kuyruğa** konur (güvenlik dışı oldukları için kayıp kabul edilebilir; kuyruk doluysa sonraki turda yeniden denenir). Eylemciye yalnız `ACTUATOR_SET` ile gider; açma izni denetiminden geçer, gaz vanasını açamaz `[Y-7]`. Güvenli kipte senaryo motoru çalışmaz. `%N` için dimmer yoksa "aç" (K4) | hepsi | `scene_run`; tanımlar `cfg` eşitlemesiyle panoya iner (§4.2, `module:"scene"`). Bulut zamanlayıcısı (`scheduler.js`) yerel senaryo yeteneği ilan eden panoda o kuralı **çalıştırmaz** (çift çalışmayı önler) |

**Ortak ön koşul: saat.** Zamanlı senaryo, güneş ve termostat programları için internetsiz saat gerekir. Bugün SNTP yalnız Wi-Fi varken kuruluyor (`WiFiManager.cpp:262-264`) ve SNTP'den RTC'ye yazan kod yok (`WS_PCF85063.cpp:30-37`'deki ayarlayıcılar yorum satırında). Gereken iki iş:

1. SNTP eşitlemesi sonrası `PCF85063_Set_*` çağrısı.
2. Açılışta RTC'den `settimeofday`.

`time_ok` alanı bu iki kaynaktan beslenir. Su modülü saate **bağımlı değildir** (yalnız `since_up` yeterli).

---

## 7. Riskler, açık sorular, uygulama sırası

### 7.1 Riskler

| Risk | Etki | Azaltma |
|---|---|---|
| Açılışta vana koruması için `0x00` yazımının değiştirilmesi lamba güvenliğini (ADIM 15, `SmartAutomation.cpp:322-324`) bozabilir | Kesinti sonrası lamba yanabilir | Maske yalnız `ActuatorMap`'ten gelir ve eylemci olmayan bitler için kurucu tarafından sıfırlanır; birim testi + eşdeğerlik testi |
| `ENERGIZE_TO_CLOSE` vanada `Relay_Init`/`shutdownHandler`/`emergencyAllOff` 0 yazımıyla açılma `[K-2][B1]` | Alarm sırasındaki yeniden başlatmada su akışı | Üç yol da kilit maskesini uygular (§5.1.6); kilitliyken yazılımsal yeniden başlatma `force` ister; sihirbaz NC selenoid önerir; saha listesinde ölçülür. **Kalan risk:** güç kesintisinde TCA latch'i kaybolur ve ilk `Relay_Init`'e kadar (ms mertebesi) röle enerjisizdir; ENERGIZE_TO_CLOSE vana bu sürede ve **pano enerjisizken** açıktır (donanım sınırı) |
| Gaz vanasının uzaktan ya da kendiliğinden açılması `[K-4]` | Pilot alevi sönmüş cihazdan gaz kaçağı | Açma yalnız yerinde (`GAS_RESET`); test ve açılış sonrası kapalı; sunucuda hiçbir rol açamaz |
| Gaz alarmında röle/fan kıvılcımı `[Y-1]` | Tutuşma | Fan varsayılan kapalı, ATEX onayıyla açılır; sihirbaz konum uyarısı |
| Çökme döngüsü `[O-8]` | Vananın tekrar tekrar açılması, sirenin süre sınırını aşması | Güvenli kip; siren birikimi NVS'te |
| NVS dolu `[B9]` | Kilit yazılamaz | WP-F0 ölçümü, %60 eşiği, `nvs_fail` olayı |
| LAN anahtarlı resident politikayı kapatabilir `[O3]` | Güvenlik tepkisi devre dışı | Bilinçli güven sınırı; state, olay, denetim kaydı ve owner push'u; §7.2 soru 7 |
| `TCA_SetSafeBits` yeni bir "bit kuran" yol açar | Interlock ihlali | Panjur çifti maskesi reddi; yalnız `g_safeAssertMask` bitleri; saf maske testi |
| Uygulama düzeyinde ack ve QoS0 | Olay kaybı | State uzlaştırması (§5.2.2) ile nihai tutarlılık |
| Ev konusu çok panoya gider | Yanlış panoda yama ya da ack | Zorunlu `uid` (§3.3) |
| Push hiç yok (Flutter: `createPushGateway` boş ağ geçidi) | Uygulama kapalıyken alarm ulaşmaz | Plan 2.6 bu modülün **sürüm ön koşulu** sayılmalı. O zamana kadar siren ve buzzer yerel uyarı verir |
| LAN kipi otomatik değil, yerel anahtar bulut gerektirebilir (`automation_state.dart:2231-2262`) | İnternetsiz ilk kullanımda alarm görülemez | Kurulum sırasında yerel anahtarın güvenli depoya yazılması zorunlu tutulmalı; ayrı iş paketi |
| NVS bölüm boyutu doğrulanmadı | Yapılandırma yazılamaz | WP-F0'da `nvs_get_stats` ile ölçülür (kullanılabilir ~504 girdi, §2.7) |
| Eski uygulamada vana lamba kartı gibi görünür | Kafa karışıklığı | Firmware ve sunucu reddeder; ret metni yeni uygulamada var. Eski sürümde yalnız komut başarısız görünür (kabul edilen sınır) |

### 7.2 Açık sorular

1. **Zigbee/Thread hub.** Hangi ürün, hangi taşıma (UART koordinatörü, LAN üzerinde Thread sınır yönlendiricisi ya da Modbus ağ geçidi)? `BridgeSensor` sürücüsünü belirler.
2. **İki röleli (aç/kapat darbe) vana sürüşü** ilk sürüme girecek mi? Girerse panjur çiftine benzer bir interlock gerekir.
3. **iOS kritik uyarı izni.** Apple'a başvurulacak mı? Başvurulmazsa `time-sensitive` kullanılır.
4. **Misafir alarm bildirimi** alacak mı? Önerilen yanıt hayır; ürün kararı gerekiyor. (Misafir vanayı her durumda **kapatabilir**; açamaz.)
5. ~~Fabrika sıfırlaması kilitli alarmı kaldırsın mı?~~ **Kapandı (revizyon 2):** kaldırmaz; kilit `ahbu_latch`'te sıfırlamadan sağ çıkar (§4.3) `[Y-5]`.
6. **Vananın son konum kaydı (`act_pos`).** Kayıt yokken su vanasının "açık" kabul edilmesi ürün sahibince onaylanmalı. (Alarmın kapattığı vana artık her zaman "kapalı" kaydıyla kalır `[K-1]`; gaz vanası her açılışta kapalıdır `[K-4]`.)
7. **LAN'dan güvenlik yapılandırması** `[O3]`. Yerel anahtarı olan resident LAN üzerinden politikayı kapatabilir ya da eylemci silebilir (bulutta yapamaz). Bu sürümde bilinçli güven sınırı olarak bırakıldı. Ayrı bir servis anahtarı ya da panoda fiziksel onay (ör. düğmeye basılı tutma) istensin mi?
8. **Gaz vanası açma düğmesi** `[K-4]`. Gaz vanası yalnız yerinde açılabilir. Panoya/vana yanına ayrı bir "gaz aç" düğmesi (DI) mı bağlanacak, yoksa yalnız mekanik elle kurmalı (manuel reset) gaz vanası mı önerilecek? Önerilen: manuel reset vana + isteğe bağlı DI.
9. **Ex-proof fan** `[Y-1]`. Gaz alarmında fan hiç açılmasın mı, yoksa kurulumcu ATEX onayıyla açılabilsin mi? Tasarım ikincisini varsayar; varsayılan kapalı.
10. **Güvenli kipten çıkış yetkisi** `[Y-4]`. Güvenli kipteki kilidi yalnız yerel yol (LAN `force`, CLI, `ALARM_ACK` 5 sn) mı kaldırsın, yoksa owner buluttan da kaldırabilsin mi? Tasarım yalnız yerel yolu varsayar.

### 7.2b Açık soruların kararları (orkestratör, 2026-10-06; kullanıcı "soru sorma, gerekeni yap" dedi — standart/emniyet önceliğiyle)

1. **Hub:** bu sürümde yalnız `BridgeSensor` arayüzü + QA simülatör kaynağı; somut hub sürücüsü (UART Zigbee koordinatörü) ayrı paket (donanım seçimine bağlı). Arayüz sözleşmesi şimdiden sabit.
2. **İki röleli vana:** EVET, ilk sürümde (K1 "röle ile tetiklenen her cihaz"). Panjur interlock deseni: aç/kapat röleleri aynı anda asla enerjili olmaz, darbe süresi yapılandırılır (varsayılan 15 sn).
3. **iOS kritik uyarı:** başvuru yok; `interruption-level: time-sensitive` + Android yüksek önem kanalı.
4. **Misafir:** alarm bildirimi ALMAZ; vanayı kapatabilir, açamaz.
5. (kapandı)
6. **Konum kaydı yok:** su vanası "bilinmiyor" sayılır ve emniyet tarafında AÇIK kabul edilir (alarmda her zaman kapat sürülür); arayüz "konum bilinmiyor" gösterir.
7. **LAN'dan güvenlik yapılandırması:** yerel anahtarla politika KAPATILAMAZ ve eylemci SİLİNEMEZ; yalnız ekleme/sıkılaştırma. Gevşetme yalnız seri CLI (fiziksel erişim) ya da bulutta owner/servis rolüyle.
8. **Gaz vanası:** manuel reset (elle kurmalı) vana önerilir; isteğe bağlı yerel "gaz aç" DI düğmesi desteklenir. Buluttan açma yok.
9. **Fan:** varsayılan kapalı; kurulumcu ATEX/ex-proof onayıyla açılabilir.
10. **Güvenli kip:** yalnız yerel yol (fiziksel erişim) kaldırır; buluttan kaldırılamaz (yapılandırma bozukken uzaktan açma emniyetsiz).

### 7.3 Uygulama sırası ve dosya sahipliği

| Paket | İçerik | Dosyalar (sahip) | Bağımlılık |
|---|---|---|---|
| **WP-F0** | NVS ölçümü (tam dolu yapılandırma, `nvs_get_stats`, eşik %60) `[B9]`; Unity testlerinin NDK clang + Node shim ile koştuğunun iskelet testle doğrulanması `[B17]`; `CONTRACTS.md` §2.6 taslağı (bu belgeden) | `docs/CONTRACTS.md` | — |
| **WP-F1** | Saf çekirdekler + Unity testleri (§5.5 listesi; tür→akışkan, gaz kuralları, pencereli onay, `ok` semantiği, güvenli kip kararı, çökme döngüsü sayacı, yön kuralı) + **kendi sim portları ve `fwcheck --update`** `[B8]` | `src/sensors/*.h`, `src/actuators/*.h`, `src/safety/SafetyFsm.h`, `src/safety/SafetyConfig.h`, `src/events/EventOutbox.h`, `test/test_*`, `tools/qa_stack/sim/fw/{safety_fsm,sensor_hub,actuator_map,event_outbox}.js`, `SOURCES.json` (paylaşılan) | F0 |
| **WP-F2** | Bağlayıcılar: `SafetyManager` (her tur yeniden dayatma), `SafetyStore` (`ahbu_safety` + `ahbu_latch`, `readBootLatchMask`), `DiSensor` (`ok`), `EventOutboxRtos`, `SafetyCfgLock`; `SmartAutomation` kancaları (§2.9: `applySafetyOutput` + `CmdSource::SAFETY`, yön kuralı, DI→`ACTUATOR_SET`, `emergencyAllOff`, `shutdownHandler`, `_restartPending` dalı, ham RS485 reddi, tarama reddi); `Relay_Init` öncesi kilit maskesi; `Buzzer_SetAlarm` `[B10]`; **sim portu (`automation.js`) + `fwcheck --update` + eşdeğerlik testi kabul ölçütü** `[B8]` | `src/safety/SafetyManager.*`, `src/safety/SafetyStore.*`, `src/sensors/DiSensor.*`, `src/events/EventOutboxRtos.h`, `SmartAutomation.{h,cpp}`, `SmartAutomation_Rs485.cpp`, `WS_Relay.cpp`, `WS_GPIO.{h,cpp}`, `main.cpp` (yalnız açılış sırası), `DeviceCommand.h`, `SystemConfig.h` (NS sabitleri), `ConfigManager.cpp` (yalnız `clearNamespace`), `tools/qa_stack/sim/fw/automation.js`, `sim_safety_equivalence.test.js` | F1 |
| **WP-F3** | ValveGuard (donanım okuması, spinlock'lu `SafeMasks`, ek modülde yalnız loop açlığında hız sınırlı yazım) + `TCA_SetSafeBits` + `TCA_ReadReg` + sim portu | `SmartAutomation.cpp` (ShutterGuard), `WS_TCA9554PWR.{h,cpp}`, sim karşılığı | F2 |
| **WP-F4** | MQTT: v:3, `caps`, `bn`, `last_rej` (ret kodları dahil `bad_cmd`/`busy`), `StateSignature`, `parseCommand` (`uint16_t`, `to`, `aid`, zorunlu `uid`), event outbox yayını (1500 ms penceresi), `event_ack`, `cfg_dump` (outbox dışı, ≤ 3,5 KB), sys `cmd:cfg_*` (sys sınırı 1024), adsız state, `cap` formülü + heap ölçümü `[B12]`; **sim portu (`mqtt_manager.js`, `v:3`) + smoke `v >= 2`** `[O8]` | `MqttManager.{h,cpp}`, `tools/qa_stack/sim/fw/mqtt_manager.js`, `tools/qa_stack/lib/smoke.js` | F2 |
| **WP-F5** | Web: `/api/status` ekleri, yeni KEYED rotalar (`g_job`'suz bekleme), `/api/events`, `/api/safety/config`; `/api/config` çapraz doğrulaması `[B3]`; reboot/reset/rs485 kilit kuralları; CLI `SAFETY STATUS/TEST/ACK [FORCE]`, `REBOOT FORCE`; **sim portu (`local_api.js`)** | `WebPortal.cpp`, `WebPortalPage.h`, `main.cpp` (CLI), `tools/qa_stack/sim/local_api.js` | F2 |
| **WP-Q1** | Uçtan uca sim senaryoları ve hata enjeksiyonu (§5.4, §5.5 QA listesi; çok panolu ev dahil) | `tools/qa_stack/sim/device_sim.js`, `tools/qa_stack/sim/command_schema.js`, `tools/qa_stack/test/fw_safety_*`, `sim_safety.test.js` | F1-F5 (her F kendi portunu getirdiği için Q1 yalnız senaryoları yazar) |
| **WP-S1** | Migration 033 (UUID FK'ler, `devices.caps/safety_state`, `alarms` ek kolonları, `NOT EXISTS` ile ACL) + şema sözleşmesi + PG testleri (55432, iki kez çalıştırma) | `server/migrations/033_safety_alarms.sql`, `server/test/safety/migration_033*.test.js` | F0 |
| **WP-S2** | Köprü event dalı (`uid` doğrulaması, `cfg_dump` ayrımı) + `validateStatePayload` ekleri `[O1]` + `alarm_service` (mezar taşı, `lost`) + state uzlaştırma + **yerleşim eşitlemesinde `act` → `actuator_type`, imza** `[Y2]` + **gece huzur/hepsini kapat/zamanlı kural süzgeçleri** `[Y3][O6]` | `server/src/mqtt_bridge.js`, `server/src/services/alarm_service.js`, `server/src/services/mqtt_credential_service.js`, `server/src/utils/endpoint_layout.js`, `server/src/services/endpoint_layout_sync.js`, `server/src/services/peace_snapshot.js`, `server/src/services/peace_service.js`, `server/src/scheduler.js`, `peace_service.js` içindeki `closeLightsKeepingPlugs` (çağrı yeri `device_service.js:1888-1896`) | S1, F4 (sözleşme) |
| **WP-S3** | Push genelleştirme (`safety_alarm`, `lost` bilgi push'u, `policy_changed`) | `server/src/services/push_service.js`, CONTRACTS §2.5 | S2 |
| **WP-S4** | Komut şeması (`to`, `aid`, `uid`), rol matrisi (gerçek `ROLES`) `[O2]`, hedef denetimi (`GAS_LOCAL_ONLY`, `caps`), ret yankısında `uid` anahtarı `[Y5]`, alarm rotaları, çevrimdışı ack (`aid` eşleşmeli), yapılandırma eşitleme rotaları | `server/src/utils/command_schema.js`, `server/src/utils/role_matrix.js`, `server/src/services/device_service.js`, `server/src/mqtt_bridge.js` (yalnız `expectAck`), `server/src/routes/*` | S2 |
| **WP-A1** | Flutter modelleri + ayrıştırma + eşitlik + testler (`canOpenValve` `ok`/gaz/güvenli kip; `ReportedLayout.signature`'a `act`) | `lib/models/safety_models.dart`, `lib/models/automation_models.dart`, `lib/models/cloud_models.dart`, `lib/models/endpoint_sync.dart` | F0 |
| **WP-A2** | Durum, komut ve onay hattı | `lib/services/automation_state.dart`, `lib/services/command_pipeline.dart`, `lib/services/automation_api_service.dart`, `lib/services/ev_cloud_api_service.dart`, `lib/models/capabilities.dart` | A1, S4 |
| **WP-A3** | Kartlar ve bölüm | `lib/ui/widgets/critical_alarm_card.dart`, `lib/ui/widgets/actuator_card.dart`, `lib/ui/dashboard/apartment_dashboard.dart`, `lib/ui/dashboard/endpoint_sections.dart` | A2 |
| **WP-A4** | Sihirbaz Adım 7 genişletmesi + K4 paneli | `lib/ui/pages/service_setup/steps/step_7_relays.dart`, `.../logic/relay_logic.dart`, `.../setup_store.dart` | A1, F5 |
| **WP-R** | Sürüm: firmware 1.2.0 (`WiFiManager.h:15-17`), dağıtım sırası **sunucu (033 + köprü) → firmware → uygulama** | — | hepsi |

**Paralel çalışma.** F1, S1 ve A1 birbirinden bağımsızdır. F2'den sonra F3, F4 ve F5 paraleldir, ama `SmartAutomation.cpp` dosyasının sahibi yalnız F2 ve F3'tür; F4 ve F5 bu dosyaya dokunmaz. `main.cpp`'de F2 yalnız açılış sırasına, F5 yalnız CLI'ya dokunur. **Paylaşılan dosya:** `tools/qa_stack/sim/fw/SOURCES.json`; her F paketi kendi `fwcheck --update`'ini yapar ve paketler sırayla birleştirilir (F1 → F2 → F3/F4/F5 birleşme sırasında her birleşmeden sonra `fwcheck --update` yeniden çalıştırılır) `[B8]`.

**Dağıtım sırası gerekçesi.** Yeni sunucu `v:2` ile eskisi gibi çalışır (§3.1). Yeni firmware'in olayları ise ancak 033 ACL satırı ve köprü aboneliği varken teslim edilir; aksi halde olaylar tamponda bekler ve state uzlaştırması devreye girer.

---

## 8. İnceleme kararları (revizyon 2)

Üç inceleme işlendi: **emniyet/fail-safe** (kodlar `K-n`, `Y-n`, `O-n`, `D-n`; 25 bulgu), **sözleşme/geriye uyum** (`Yn`, `On`, `Dn`; 23 bulgu), **gömülü kaynaklar/uygulanabilirlik** (`Bn`; 17 bulgu). Kanıtları bu klonda açılıp doğrulandı; en önemli olanlar §0 tablosuna eklendi.

### 8.1 Kabul edilenler ve işlendikleri yer

| Bulgu | Karar | Yer |
|---|---|---|
| K-1 alarm sonrası kesintide vana açılır | Kabul | §5.1.1 tablo, §5.1.6 madde 5, §2.7 `act_pos` |
| K-2, B1 yeniden başlatma/kapanma yolları vanayı açar | Kabul | §5.1.6 madde 1 ve 6, §2.9, §7.1 |
| K-3 akışkan bilgisi yok | Kabul (`medium`) | §2.4, §4.3, §5.1.1, §6 |
| K-4 gaz vanası uzaktan/kendiliğinden açılır | Kabul | §2.4, §5.1.1, §5.1.6 madde 4, §5.2.4 |
| Y-1 gazda fan, çelişki | Kabul (varsayılan kapalı, ATEX onayı) | §2.4, §4.3, §4.4, §6 |
| Y-2, B6 ek DI açılışta/kopuklukta yanlış | Kabul | §2.5 "Sensör sağlığı" |
| Y-3 arızalı sensör kuru sayılır | Kabul | §2.5, §2.6, §5.1.1, §5.3.1 |
| Y-4 CRC bozulunca güvenli konum kaybolur | Kabul (kilit maskeleri + güvenli kip) | §2.7, §5.1.6 madde 2-3 |
| Y-5 LAN fabrika sıfırlaması kilidi kaldırır | Kabul (kilit `ahbu_latch`'te sağ çıkar + 409/`force`) | §2.7, §4.3; §7.2 soru 5 kapandı |
| Y-6, B2, B3 yasak yollarda delikler | Kabul | §2.2, §2.3 madde 4-5, §2.9 |
| Y-7 `RULE` iki anlamlı | Kabul (`CmdSource::SAFETY`) | §2.3 madde 2, §6 |
| Y-8, B7 ValveGuard sınırları | Kabul (donanım okuması, spinlock, kapsam yerel 8 röle); GPIO yolu hariç, bkz. R-2 | §2.2, §5.1.5 |
| Y-9 onayda alarm kimliği yok | Kabul (`aid`, `stale_ack`, zorunlu `uid`) | §3.3, §5.1.1, §5.2.4 |
| O-1 damla | Kabul (pencereli birikim) | §2.6 |
| O-2 kablo kopması | Kabul (gaz/duman NC zorunlu, su için uyarı) | §2.4, §2.5, §4.4 |
| O-3 her turda yeniden dayatma | Kabul | §2.3 madde 2 |
| O-4, O5 restart beklerken körlük | Kabul | §2.3 madde 2, §2.9, §5.1.6 madde 6 |
| O-5 RS485 taraması | Kabul (güvenlik sensörlerini de kapsayacak şekilde genişletildi) | §5.1.7, §2.9 |
| O-6 gecikme hedefi kaynağa göre | Kabul | §1.1 madde 1, §5.5 saha listesi |
| O-7, B10 buzzer | Kabul (`Buzzer_SetAlarm`) | §4.3, WP-F2 |
| O-8 çökme döngüsü | Kabul (güvenli kip; siren birikimi yıpranmaya karşı 30 sn'de bir yazılır) | §2.7, §5.1.6 madde 3-4 |
| O-9, O11 sessiz kapanma, `safety` yokluğu | Kabul (`lost`, kanıtlı kapanma) | §3.1 kural 5, §5.2.2 |
| O-10 korunmayan alanlar | Kabul | §4.1 |
| D-1 tur süresi | Kabul | §5.1.4 madde 1 |
| D-2 siren süresinin iki kaynağı | Kabul (`run_limit_s` tek kaynak, 0 ret) | §2.4, §2.7, §4.3, §5.1.2 |
| Y1, B5 UUID | Kabul | §5.2.1 |
| Y2 `actuator_type` yazılmıyor, imza | Kabul | §3.1 kural 6, §5.3.2, WP-S2/A1 |
| Y3 vana lamba sayılıyor | Kabul | §3.1 kural 6, §2.9 |
| Y4, B4 eid tekil değil | Kabul (eid = `<bn>-<n>`, `bn` açılış nonce'u; `bootc` silinmeyen ad alanında; `event_ack`'te `uid` zorunlu) | §2.7, §3.2, §3.4 |
| Y5 çok panolu karışma | Kabul (zorunlu `uid`, `uid` anahtarlı ret yankısı); bir alt öneri hariç, bkz. R-3 | §3.3, §5.2.4 |
| Y6 `cfg_dump`/tampon/köprü sınırı | Kabul (`cfg_dump` outbox dışında ≤ 3,5 KB, sabit yapılı yuva) | §2.8, §3.4 |
| O1 `caps`/`safety` saklanmıyor | Kabul (`devices.caps`, `devices.safety_state`) | §3.1 kural 5, §5.2.1 |
| O2 rol adları | Kabul | §5.2.3, §5.2.4 |
| O3 LAN güven sınırı | Kısmen: bilinçli güven sınırı olarak yazıldı, görünürlük önlemleri eklendi; teknik kısıt kullanıcıya soruldu | §3.5, §7.1, §7.2 soru 7 |
| O4, B15 kapatma her yoldan / yerel onay | Kabul (yön kuralı, DI→`ACTUATOR_SET`, `ALARM_ACK`/`VALVE_CLOSE` DI rolleri) | §2.3 madde 4, §2.5, §5.1.3 |
| O6 zamanlı kurallar | Kabul | §3.1 kural 6, §2.9 |
| O7 sırasız olaylar | Kabul (mezar taşı) | §5.2.2 |
| O8 QA `v === 2` | Kabul | §2.9 test yükümlülüğü, WP-F4 |
| O9 ACL idempotentlik | Kabul (`NOT EXISTS`, `kind='device'`) | §5.2.1 |
| O10 `last_rej` kapsamı | Kabul (`bad_cmd`, `busy`; `uid` uyuşmazlığı bilinçli olarak sessiz) | §3.2 |
| D1 `state` iki tür | Kabul (`to` anahtarı) | §3.3 |
| D2, B11 sys biçimi ve 512 sınırı | Kabul (`cmd`, sys sınırı 1024) | §3.3, §4.2 |
| D3 LAN durum yanıtı, `g_job` | Kabul | §3.5 |
| D4 yeniden bağlanma penceresi | Kabul | §3.4 |
| D5 eksik kolonlar | Kabul | §5.2.1 |
| D6 sensör sınırının dayanağı | Kabul | §3.2 |
| B8 fwcheck/sim sahipliği | Kabul (her F kendi portunu getirir, eşdeğerlik F2'de) | §2.9, §5.4, §7.3 |
| B9 NVS bütçesi | Kabul (~504 girdi, %60 eşiği) | §2.7, WP-F0 |
| B12 state boyutu | Kabul (adlar state'ten çıktı, heap ölçümü) | §2.8, §3.2 |
| B13 görevler arası okuma | Kabul (`SafetyCfgLock`) | §2.3 madde 6 |
| B14 eşdeğerlik iddiası | Kabul | §2.9, §3.1 kural 1 |
| B16 saf modül sınırı ve küçük tutarsızlıklar | Kabul | §2.1, §2.7, §2.8 |
| B17 test altyapısı, MOMENTARY artığı | Kabul | §2.5, §5.5, WP-F0 |

### 8.2 Reddedilen ya da farklı çözülen öneriler

- **R-1 (K-1 alt önerisi): "Kayıt yokken bile alarm geçmişi olan vana kapalı sayılsın".** Ayrı bir alarm geçmişi kaydı açılmadı. Gerekçe: güvenlik kapatması `act_pos`'u zaten "kapalı" yazıyor, dolayısıyla alarm geçmişi olan vananın kaydı her zaman vardır. İkinci bir kayıt aynı bilgiyi iki yerde tutar ve tutarsızlık riski getirir. `act_pos` yazımı başarısız olursa `nvs_fail` olayı bunu görünür kılar (§5.1.6 madde 5).
- **R-2 (Y-8 alt önerisi): "Yerel DI su sensörleri için guard görevinde bağımsız GPIO → vana kapat yolu".** Bu sürümde eklenmedi. Gerekçeler:
  1. Onay penceresi, NC çevirme, `ok` semantiği ve tür→akışkan eşlemesinin ikinci bir görevde yeniden uygulanması gerekirdi. İki karar noktası ayrışırsa (biri onaylı ıslak der, diğeri demez) hata ayıklaması zor bir "bölünmüş beyin" durumu doğar.
  2. Loop takılması TWDT ile 10 sn'de sınırlıdır. Sıfırlamadan sonra kilit ve seviye okuması baskını ilk turda yakalar; guard da önceden kurulmuş güvenli konumu bu süre boyunca korur.

  Sahada loop takılması ölçülürse (CLI `STATUS` yüksek su işareti, sıfırlama nedeni kayıtları) öneri yeniden değerlendirilir.
- **R-3 (Y5 alt önerisi): "Uid eşleşmeyen panolar düz relay komutunda `last_rej` yazmasın".** Uygulanamaz. Gerekçe: düz `relay` komutu `v:2` biçimindedir ve `uid` taşımaz; pano hedefin kendisi olup olmadığını bilemez. Sorun sunucu tarafında çözüldü: ret yankısı yalnız hedef panonun `uid`'siyle gelen state'ten kabul edilir (§5.2.4). Sunucunun bundan sonra gönderdiği bütün yeni komutlar `uid` taşır.
- **R-4 (Y4/B4 alt önerileri): "Devir ve sıfırlamada `device_events` temizlensin" ve "tekilleştirme `(device_id, eid, boot_nonce)` olsun".** Uygulanmadı. Gerekçe: nonce eid'in içinde (`<bn>-<n>`), bu yüzden `(device_id, eid)` anahtarı zaten tekildir. Kayıtları silmek denetim geçmişini yok ederdi.
- **R-5 (Y-5 seçenekleri): "Ya kilit sağ çıksın ya da sıfırlama 409 dönsün".** İkisinden biri seçilmedi, ikisi birlikte uygulandı: kilit sıfırlamadan sağ çıkar ve kilit varken sıfırlama `force` ister. Yalnız 409 yetmezdi, çünkü `force` ya da seri yoldan yapılan bir sıfırlama kilidi yine silerdi.
- **R-6 (B7 seçeneği): "Ek modül guard kapsamı dışında ilan edilsin".** Tümden kapsam dışı bırakılmadı. Bunun yerine "loop N ms beslemedi" koşuluna bağlı ve 1 sn'de bir sınırlı yazım seçildi. Gerekçe: loop takıldığında ek modüldeki vanayı korumanın tek yolu budur; hız sınırı da hat çakışmasını sınırlar.
- **R-7 (O1 seçeneği): "caps denetimi `firmware_version >= 1.2.0` koşuluna bağlansın".** Seçilmedi; `devices.caps` kolonu açıldı. Gerekçe: sürüm karşılaştırması, yeteneklerin tek tek açılıp kapanmasını (ör. `cfg` olmadan `safety`) ifade edemez.
- **R-8 (D1 ad önerisi): `pos_req` ya da `on`.** Bunların yerine `to` seçildi. Gerekçe: vana (`closed`/`open`) ve anahtar (`on`/`off`) için tek ve kısa bir anahtar yeterli.

### 8.3 İncelemelerde "sorun yok" diye doğrulananlar

- `InterlockGuard` ölü zamanı yalnız panjur çiftlerine uygulanır (`RelayRules.h`). Açılış maskesindeki vana biti bu kurala takılmaz.
- `SensorConfig` 28 B'tır. `ActuatorConfig` revizyon 2'de `medium`/`aflags` eklenip ad alanı 20 bayta indirildiği için 32 B'ta kalır.
- `MAX_ARRAY_ITEMS=64` ve `MAX_COMMAND_BYTES=1024` doğrudur (`mqtt_bridge.js:84-86`).
- `KeyedWorkQueue`'da `coalesce` parametresi vardır.

---

## Uygulama notları (SRV)

Ekip SRV (WP-S1..S4), 2026-10-07. Kod esastır; aşağıdakiler tasarımdan sapma ya da tasarımın açık bıraktığı noktalar için verilen kararlardır. Sözleşme ayrıntısı `docs/CONTRACTS.md` §1.4, §1.5d, §2.5 (güvenlik push'u) ve §6'dadır.

**S1 — migration 033**

- ACL satırının konu kimliği, `homes` birleştirmesi yerine mevcut `ev/{t}/state` yayın satırından türetilir (`left(topic, …) || '/event'`). Tasarımdaki "aynı kaynaktan" koşulunu birebir karşılar. `NOT EXISTS` tam konu eşitliğiyle çalışır; `LIKE '%/event'` kullanılmaz. Uygulama kimliklerine yayın satırı eklenmez.
- `alarms` tablosuna ek olarak `updated_at` kolonu ve `origin`/`push_status`/`fault_push_status` CHECK'leri eklendi. Geçmiş listesi için `alarms_home_raised_idx`, 90 günlük saklama işi için `device_events_received_idx` indeksi var.
- `npm test` ile gerçek PG'de dosya üç kez çalıştırıldı. Satır sayıları değişmedi.

**S2 — köprü ve alarm servisi**

- **Olayın alarm kimliği.** `alarm_raised` olayında alarm kimliği olayın kendi `eid`'sidir. Diğer alarm olaylarında (`valve_fault`, `valve_fault_cleared`, `alarm_silenced`, `alarm_cleared`) isteğe bağlı bir `aid` alanı okunur. Tasarımda bu alan tanımlı değildi; F4 firmware'inin bu alanı yazması önerilir. Alan yoksa bölgenin açık alarmı kullanılır. Bilinmeyen `aid` ile gelen `alarm_cleared` olayı mezar taşı satırı açar.
- **`devices.safety_state` biçimi** (sürüm 1): `{v, state_v, present, policy, mode, boot, bn, time_ok, cfg:{rev,crc}|null, last_rej, zones[], actuators[], sensors[]}`. Ad içermez. Ayrıştırıcı `server/src/utils/safety_payload.js`'tir.
  - Sınırlar: sensör ≤ 56, eylemci ≤ 16, bölge ≤ 4. Tarama sınırı 64 öğedir.
  - Bilinmeyen eylemci ya da sensör türü `generic` olur.
- **v:2 eşdeğerliği.** `caps` yoksa ve cihazda daha önce de `caps` kaydı yoksa cihaz `UPDATE` metni, sorgu sayısı ve sırası değişmez; alarm servisi çağrılmaz. Bu durum testle kanıtlandı. `RESOLVE` sorgusuna yalnız iki kolon eklendi: `has_caps` ve `safety_state`.
- **Eski firmware'e dönüş.** Cihazda `caps` kaydı varken `caps` taşımayan canlı bir state gelirse `devices.caps` ve `safety_state` NULL yapılır. Açık alarm satırları `lost` olur ve owner'a bilgi push'u gider.
- **Uzlaştırma kuralı** (§5.2.2 yorumu):
  - State'te bölge `latched` ya da `fault` durumundaysa ve `aid` aynıysa satırın durumu eşitlenir (`latched`, `silenced` ya da `fault`).
  - Bölge `normal` ya da `test` durumundaysa, ya da bölgede başka bir `aid` varsa: kanıt koşulları (mode `normal` ve `cfg.rev` geri gitmemiş) tutuyorsa satır `cleared` (`device_state`) olur, tutmuyorsa `lost` olur.
  - Bölge state'te hiç bildirilmemişse ya da `aid` taşımayan bir kilit varsa satıra dokunulmaz.
- **`event_ack` gönderimi.** Onay yalnız olay transaction'ı COMMIT edildikten sonra gönderilir; DB hatasında gönderilmez ve pano yeniden dener. Köprü bağlı değilse onay atılır.
- **Yerleşim eşitleme.**
  - Bilinmeyen `act` metni `generic` sayılır. Dizge olmayan ya da boş `act` gelirse yerleşim `null` olur.
  - `act` alanı imzaya ve tabana yalnız mevcutsa girer, bu yüzden v:2 imzası ve tabanı birebir aynı kalır.
  - Eylemci taşıyan pano geçici (D1) sayılmaz.
  - `actuator_type` alanını yeni `SQL.syncActuators` sorgusu yazar. Bu sorgu yalnız bildirimde ya da tabanda eylemci varsa çalışır.
- **`cfg_dump`.** Çok parçalı döküm `{parts:[…]}` olarak saklanır. Eski `rev` yenisini ezmez. `cfg.safety.rev/crc` kopyadan farklıysa `sys {cmd:"cfg_get"}` gönderilir; bu istek cihaz başına dakikada en çok bir kezdir.

**S3 — push**

- **Yeni `safety_info` türü.** Alarm doğrulanamadığında (`alarm_lost`) ve politika değiştiğinde (`policy_off` ya da `policy_on`) yalnız owner'a gider.
  - Tasarım bu bilgi push'unu istiyordu ama biçimini tanımlamamıştı.
  - `policy_changed` olayında iki yön için de push gönderilir.
- **Alıcılar.** `safety_alarm` push'u owner ve resident'a gider; misafir ve servis rolleri almaz (§7.2b-4). iOS'ta `interruption-level` değeri `time-sensitive`'dir; kritik izin kullanılmaz (§7.2b-3).

**S4 — komut, rol, rotalar**

- **Hedef denetiminin sırası.** `caps` denetimi ilk sıraya alındı; tasarımda 4. sıradaydı. Gerekçe: `caps` yoksa güvenlik özeti de yoktur ve gaz/bölge denetimi yapılamaz.
- **Vana açma denetimi genişletildi.** Vana `open` isteğinde bölge ve mode denetimine ek olarak, bölgede aynı akışkana bakan bir sensör `ok` değilse ya da aktifse yine `409 ZONE_ALARM_ACTIVE` döner (§5.1.1 [Y-3] kuralının savunma katmanı).
- **Eylemci rotasının gövdesi** `{to}` biçimindedir ([D1]). §5.2.4 tablosundaki `{state}` da metin olarak kabul edilir.
- **Komut sonucu.** Güvenlik komutları hedef `uid`'nin yankısını en çok 10 sn bekler (`expectOutcome`).
  - `last_rej` gelirse `409 DEVICE_REJECTED` döner ve `reason` alanı firmware kodunu taşır.
  - Süre dolarsa yanıt `applied:null` olur.
  - Eski `expectAck` boolean davranışı aynen korundu; ret yankısı onu bitirmez.
- **Çevrimdışı onay.** `409 DEVICE_OFFLINE` yanıtı `ack_queued:true` taşır; bu alan `http_errors` beyaz listesine eklendi. Onay pano dönünce gönderilir ve aynı anda `acked_by` yazılır.

**Kalan işler (bu paketlerde yapılmadı)**

- **Buluttan yapılandırma yaması.** Şunlar yok: `sys cfg_patch`, `device_configs.pending` uzlaştırması, `409 CONFIG_CHANGED_ON_DEVICE` ve `safety_config` yeteneğini kullanan yapılandırma rotaları. Yetenek matriste tanımlı ama ona bağlı bir uç yok.
- **Bakım işleri.** `device_events` için 90 günlük saklama işi yazılmadı. Başarısız (`failed`) alarm push'u yeniden denenmez; şu an tek deneme yapılır.
- **Ortak SQL denetimi.** Sema sözleşmesi denetiminin (`check_schema_contract.js`) `--live` kipi temiz. Yeni servisler `WP_C_SRC` katı listesine alınmadı; danışma (advisory) olarak taranıyorlar.
## Uygulama notları (EKIP FW)

Dalga 1, WP-F0 + WP-F1 + WP-F2 (2026-10-07). Kod esastır; aşağıdakiler tasarımdan sapmalar ve uygulamada verilen kararlardır.

### F0 ölçümleri

**NVS bütçesi (kabul eşiği TUTMADI, en kötü durumda).** Pano/COM kullanılamadığı için `nvs_get_stats` cihazda çalıştırılamadı; ESP-IDF girdi modeliyle hesaplandı (sayfa başına 126 girdi; ilkel 1, dizge 1 + ⌈(uzunluk+1)/32⌉, blob 2 + ⌈boyut/32⌉, ad alanı başına 1). Bölüm: `app3M_fat9M_16MB.csv`, NVS `0x5000` = 5 sayfa = 630 girdi, kullanılabilir 504 (çerçeve paketinde doğrulandı). PHY kalibrasyonu NVS'te (`CONFIG_ESP_PHY_CALIBRATION_AND_DATA_STORAGE=1`, `esp_phy_calibration_data_t` 1904 B ≈ 66 girdi); Wi-Fi sürücüsü RAM depolamada (`WiFi.persistent(false)`).

| Durum | Girdi | 504'e oran |
|---|---|---|
| Bugünkü en kötü (40 röle + 40 DI, en uzun adlar, PHY dahil) | 427 | %84,7 |
| Yeni ad alanları en kötü (56 sensör, 16 eylemci) | +105 | |
| Toplam en kötü | 532 | **%105,6** |
| Seçenek 1: röle/DI adları tek blob'a | 456 | %90,5 |
| Seçenek 2: NVS 0x8000 (7 kullanılabilir sayfa) | 532 / 882 | %60,3 |

Sonuç: §2.7'deki "≤ %60" eşiği yalnız iki seçeneğin BİRLİKTE uygulanmasıyla (%51,7) sağlanır. Bölüm tablosunu değiştirmek OTA ile yapılamaz (seri yükleme gerekir), bu yüzden bu pakette yapılmadı; ürün kararı gerekiyor. Bu paketteki önlemler: (a) kilit kaydı ilk açılışta boş olarak yazılır (`SafetyStore::reserveLatch`): NVS dolarsa önce yapılandırma yazımı başarısız olur, kilit değil; (b) yalnız dolu sensör/eylemci yuvaları yazılır (8 sensörlük tipik kurulumda sensör blob'u 52 değil 10 girdi); (c) her kilit/konum yazım hatası `nvs_fail` olayı üretir. Hesap betiği: oturum scratchpad'i `f0-nvs-butce.js`. Cihazda ölçüm saha listesine eklenmeli.

**Native test ortamı.** §5.5'teki "NDK clang (wasm32) + Node shim" düzeneği bu makinede yok. Gerçek Unity kaynağı da yok (yalnız eski derlenmiş `unity.obj`); ağ kullanılamadığı için indirilemedi. Testler, scratchpad'deki Unity alt kümesi (`fw-unity/unity.{h,c}`, `setjmp/longjmp` ile gerçek Unity gibi testi keser) ve MSVC 2022 (`/std:c++17 /W4`) ile çalıştırıldı. Test dosyaları değiştirilmedi. Bir mutasyonla, başarısız iddiaların raporlandığı doğrulandı. Sonuç: 13 paket, 278 test (eski 8 paket 179 test değişmeden geçiyor, yeni 5 paket 99 test). Gerçek `pio test -e native` gcc/clang olan bir makinede ayrıca koşulmalı.

### Tasarımdan sapmalar ve uygulama kararları

1. **`ActuatorConfig` 36 bayt** (§2.4'te 32 B). Karar 7.2b-2 ile iki röleli vana ilk sürüme girdiği için `relay2` (AÇ rölesi) ve 3 ayrılmış bayt eklendi. `close_mode = 2 (PULSE_TWO_RELAY)`: `relay` KAPAT, `relay2` AÇ rölesidir; `run_limit_s` darbe süresidir (vars. 15 sn, en çok 120). İki röle asla birlikte enerjilenmez. Yön değişiminde ya da son darbeden 500 ms içinde gelen ters komutta, ikisi de kapalıyken 500 ms beklenir. Aynı yöndeki komut darbeyi uzatmaz. Açılışta iki röle de enerjisizdir. Kilit boyunca AÇ rölesi 0'a dayatılır; kilit maskesine yalnız `relay2` girer.
2. **`TCA9554PWR_Init` imzası `(yön, çıkış)`'tır** (`WS_TCA9554PWR.h:91`). §2.9 ve §5.1.6 madde 1'deki `TCA9554PWR_Init(maske, 0x00)` yazımı ters; kod `TCA9554PWR_Init(0x00, safeLocal)` çağırır.
3. **`act_pos` u32**: düşük 16 bit "açık", yüksek 16 bit "konum biliniyor". Gerekçe karar 7.2b-6: kayıt yoksa durum "bilinmiyor"dur, emniyet tarafında AÇIK kabul edilir ve state'te `unknown` görünür. Bu bilgi u16'ya sığmaz. NVS'te yine 1 girdi.
4. **`siren_s`** kilit başına tek değer tutar: sirenlerin en büyük birikimi (sn). Açılışta kilit sürüyorsa bütün sirenlere yüklenir.
5. **Olay JSON'unun en kötü boyutu 641 bayttır** (§3.4 ve §5.5'te "≤ 400 B"). Ölçüm: 8 kaynak, 16 eylem, 20 karakterlik `uid`. Köprü sınırı (4 KB) ve firmware arabelleği (`EVENT_JSON_MAX` = 768) içinde kalır. Test sınırı ≤ 700 B. CONTRACTS §2.6 taslağına yazıldı.
6. **`ZoneConfig` 16 bayttır** ve yalnız ad taşır (15 + NUL). §2.7'deki "ad ve bayraklar" tanımında bayrak alanı ad sınırıyla çakışıyordu.
7. **Pencereli onay.** Pencere 8 kovaya bölünür (su 375 ms, gaz/duman 125 ms çözünürlük). Onaylı aktiflik, pencere boşalana kadar sürer. Kuruluk sayacı (`dry_hold`) "ok && onaylı değil && ham pasif" koşuluyla başlar. Su için kilit en erken "kuruma + yaklaşık 3 sn + dry_hold" sonra kalkar.
8. **`SF_FAULT_CLOSE` açılış toleransı.** Hiç okunamamış bir sensörün arızası, açılıştan 30 sn sonra "ıslak" sayılır. Daha önce sağlıklı görülmüş sensörün arızası hemen sayılır. Örnek: gaz ek modülü hiç yanıt vermiyorsa vana 30 sn sonra kapanır. Bu toleransın amacı, ilk okuma turundan önceki `ok=false` halinin sahte alarm üretmemesidir.
9. **Kilit kaydında `kinds = 0`** (beklenmez) olursa tür, en tutucu değer olan `HZ_ALL` kabul edilir: bölgedeki bütün vanalar kapalı tutulur.
10. **Ana yapılandırmayla uyuşmayan güvenlik yapılandırması.** Açılışta `validate(system, safety)` başarısız olursa (ör. ek modül kapatıldı, eylemci rölesi panjura çevrildi) durum `cfg_corrupt` gibi ele alınır. Sensör ve eylemci tabloları RAM'de KULLANILMAZ, kilit maskesi uygulanır ve `actuator_fault` olayı üretilir. NVS'e dokunulmaz.
11. **Çökme döngüsü.** "Son 10 dakikada ≥ 3" kuralı RTC/epoch gerektirdiği için şöyle uygulandı: arada 10 dk kesintisiz çalışma olmadan ≥ 3 beklenmeyen sıfırlama (`PANIC`, `INT_WDT`, `TASK_WDT`, `WDT`, `BROWNOUT`). 10 dk kesintisiz çalışma sayacı sıfırlar; NVS'e açılış başına en çok bir kez yazılır. Güvenli kipten çıkış 30 dk kesintisiz çalışmayla olur.
12. **Güvenli kipten çıkış yalnız fiziksel erişimle** (karar 7.2b-10): `CmdSource::CLI` ya da `ALARM_ACK` DI'si 5 sn basılı. LAN'dan (`force=1`) ve buluttan gelen `force` `safe_mode` ile reddedilir. §5.1.6 madde 3'teki "LAN `POST /api/alarm/ack` `force=1`" ifadesi bu karara uydurulmalı (WP-F5). `crash_loop` yalnız süreyle çıkar. `cfg_corrupt`/`latch_orphan` ancak yapılandırma kullanılabilir hale gelince çıkar (`setConfigUsable`, WP-F5 yapılandırma yolu).
13. **Yol eşlemesi.** `CmdSource::DI` ve `CLI` → `Origin::LOCAL_DI`; `MQTT`, `WEB` ve `RULE` → `REMOTE`. Gaz vanası yalnız `GAS_RESET` DI rolüyle açılır. Duvar butonu bir gaz vanasına eşliyse açma `gas_local_only` ile reddedilir.
14. **Siren ve fan ayrıntıları.** Kilit sürerken kullanıcı sireni kapatırsa (eylemci `off` ya da ham röle) yalnız o siren susar; bölge susturulmuş sayılmaz ve bastırma kilit bitince kalkar. Gaz alarmında ex-proof olmayan fana dokunulmaz (anahtarlama kıvılcımı); fanı açma isteği `zone_latched` ile reddedilir. Duman alarmında fan zorla kapatılır. Testte siren en çok 3 sn çalar ve test bitince susar.
15. **Ham RS485 yolları.** Ek modülde eylemci varken toplu yazım (`0x00FF`, kanal 0) ve TOGGLE (`0x5500`) her kanal için reddedilir. Tek kanala yalnız güvenli yöndeki yazım serbesttir. Eylemci yoksa bugünkü davranış sürer. Tarama, kilitli bölge varken ya da ek modülde eylemci/güvenlik sensörü varken reddedilir. `rs485StartScan` bugün `false` döner; HTTP `409 safety_active` eşlemesi WP-F5'tedir.
16. **`_restartPending` dalı.** `checkDigitalInputs` ve güvenlik turu bu dalda yalnız katman etkinse çalışır. Yapılandırılmamış panoda yeniden başlatma beklenirken DI işlenmez; davranış bugünküyle aynıdır.
17. **Açılış.** Ek modülde enerjili kalması gereken bir güvenlik rölesi varsa `extAllOff` (toplu KAPAT) yazılmaz. Diğer ek röleler açılış beklemesinden sonra `stepExtOutputs` ile tek tek kapatılır. `emergencyAllOff` aynı durumda yalnız korunmayan coil'leri kapatır (`extOffExcept`). `shutdownHandler` ve `emergencyAllOff`, kilit kaydındaki yerel güvenli bitleri gölgeyle VE'leyerek korur (yalnız kapatma yönü).
18. **Kilit kuralı.** `EventOutboxRtos` kilidini loopTask `portMAX_DELAY` ile alır (öncelik kalıtımlı mutex). Bu yüzden WP-F4'te MqttTask kilit altında yalnız JSON'u kendi arabelleğine kopyalamalı; ağ çağrısı ya da bekleme YAPMAMALIDIR.
19. **Dosya yerleşimi.** `SafetyCore` sınıfı `safety/SafetyFsm.h` dosyasındadır. Spec'teki `SafetyFsm` adı bölge FSM'ini ve çekirdeği birlikte karşılar. `DiSensor.h` ve `BridgeSensor.h` saf ve yalnız başlık dosyasıdır (§2.1'de BAĞ yazıyordu). Köprü kuyruğu (`s_sensorQ`) `SafetyManager::postBridgeReport` içindedir.
20. **QA dosya adları.** Unity portları `test/fw_sensor_hub`, `fw_actuator_map`, `fw_safety_config`, `fw_safety_fsm`, `fw_event_outbox` adlarıyla yazıldı (mevcut `fw_<modül>` deseni). WP-Q1 `fw_safety_*` adını kullanacaksa `fw_safety_config` ve `fw_safety_fsm` ile çakışır; Q1 farklı ad seçmeli. `lib/fwcheck.js` `SOURCES` listesine yeni firmware dosyaları eklendi; bu ekleme `SOURCES.json` eşlemesi için gerekliydi. Eşdeğerlik testi için `Automation` yeni bir `safety:false` seçeneği aldı (katman hiç kurulmaz) ve `test/_rig.js` bu seçeneği iletir. Sim NVS modeline `safety` (`{ver, cfg, crc}`) ve `latch` ad alanları eklendi; fabrika sıfırlaması `safety`'yi siler.
21. **Komut yapısı.** `DeviceCommand`'a `aid[15]` alanı eklendi (`ALARM_ACK`, WP-F4 doldurur). `CmdType`'a `ACTUATOR_SET`, `ALARM_ACK`, `ALARM_TEST`, `SAFETY_ARM`, `CLIMATE_TARGET`, `SCENE_RUN`; `CmdSource`'a `SAFETY` eklendi. Bütün eklemeler mevcut değerlerin sonuna yapıldı. `makeCommand` `aid`'i boşaltır.

### Kabul ölçütleri (bu turda)

- Firmware: `pio run -e esp32-s3-waveshare`, temiz derleme, 0 uyarı. Taban `297f276` ile karşılaştırma: RAM 55 616 → 62 856 B (+7,2 KB), flash 1 185 981 → 1 207 365 B (+21 KB).
- Eşdeğerlik (§2.9): `test/sim_safety_equivalence.test.js`. Kayıtlı ~460 eylemlik dizi (komutlar, yerel ve ek DI'ler, ham RS485, çocuk kilidi, planlı yeniden başlatma) her 10 ms'de karşılaştırıldı: `want`, `hw`, `hwKnown`, TCA gölgesi ve latch'i, ek coil'ler, anlık görüntü, bipler ve olaylar boş güvenlik yapılandırmasında ve katman yokken bit bit aynı. Testin ayrışmayı yakaladığı iki mutasyonla doğrulandı.
- Kancaların davranışı: `test/sim_safety_hooks.test.js` (6 senaryo).

### Kalan işler (bu paket dışı)

- NVS bütçesi kararı (yukarıda) ve cihazda `nvs_get_stats` ölçümü.
- `readBootLatchLocal` süresi ve `nvs_flash_init`'in iki kez çağrılmasının cihazda ölçülmesi (§5.1.6 madde 1).
- loopTask yığın yüksek su işareti (`SafetyManager` büyük yapıları statik tutar; yığındaki en büyük yereller `Event` ve `SensorConfig`'tir, < 50 B).
- WP-F3 ValveGuard: `SafetyManager::shutdownKeep*` maskeleri hazır; spinlock'lu `SafeMasks`, `TCA_SetSafeBits` (`filterSafeBits` saf yardımcısı hazır) ve `TCA_ReadReg` karşılaştırması.
- WP-F4 / WP-F5: state v:3 alanları (`AutomationSnapshot` henüz değişmedi), komut ayrıştırma, olay yayını, LAN rotaları, `/api/config` çapraz doğrulaması, yeniden başlatma/sıfırlama 409'ları, yapılandırma yazma yolu (`SafetyStore::saveConfig` hazır, `setConfigUsable` çağrısı).
- Saat (`time_ok`/`epoch`): çekirdek `epoch = 0` ile çalışıyor; RTC↔SNTP işi gelince `SafetyManager::tick` epoch'u verecek.

### Dalga 2: WP-F3 + WP-F4 + WP-F5 + WP-Q1 (2026-10-07)

Firmware v1.2.0 (`firmware_releases/v1.2.0`, DONANIMDA DOĞRULANMADI). Kod esastır; aşağıdakiler tasarımdan sapmalar ve uygulamada
verilen kararlardır.

**WP-F3 ValveGuard**

1. **Tutma maskesi yalnız KAPALI komutlu vanalardır** (`safety/ValveGuard.h` `safeHoldMasks`): ENERGIZE_TO_CLOSE'da röle 1,
   DEENERGIZE_TO_CLOSE'da 0, iki röleli vanada AÇ rölesi 0 (KAPAT darbesine dokunulmaz); güvenli kipte kilit maskesi eklenir ve seviyesi
   kazanır. Siren/fan/generic ve açık komutlu vana TUTULMAZ: guard hiçbir şeyi "açmaz", yalnız güvenli konumu korur (§5.1.5 "önceden
   kurulmuş güvenli konum"). Kullanıcının kapattığı (alarmsız) vana da tutulur.
2. **Tutarlılık.** `SafeMasks{assert, level, gen}` loopTask'ın `safetyTick`'inde `s_guardMux` altında yayınlanır; `gen` yalnız içerik
   değişince artar, ayrı bir tur sayacı (`s_loopBeat`) her güvenlik turunda artar. Guard donanımı okuduktan SONRA `gen`'i yeniden okur;
   arada yayın olduysa (loop yeni karar verdi, yazımı henüz yapmamış olabilir) o tur yazmaz. Planlı yeniden başlatmada (`performRestart`)
   guard bekletilir (`s_guardHold`): kapatma yazımına karışmaz, korunan bitler zaten shutdown maskesindedir.
3. **`TCA_SetSafeBits`** önce donanımı okuyup gölgeyi eşitler (çip sıfırlanmasında yön yazmacı da geri yüklenir), sonra yalnız istenen
   güvenli bitleri ekler; panjur çifti bitleri süzülür; okuma başarısızsa hiçbir şey yazmaz. Okuma için `TCA_ReadOutputHw` (I2C kilidi 80 ms).
4. **Ek modül:** `ExtGuardPacer` -- loop tur sayacı 1000 ms ilerlemezse ve son yazımdan ≥ 1 sn geçtiyse kilit maskesindeki ek coil'ler
   güvenli seviyeye yazılır (`extWriteCoil`, kilit beklemesi 150 ms, tek deneme).

**WP-F4 MQTT**

5. **Komut bayrak maskesi `uint32_t`** (§3.3 `uint16_t` diyordu; 8 eski + 9 yeni = 17 alan sığmaz).
6. **`ACTUATOR_SET` değer kodlaması:** yerel yollar (DI, CLI) `0` güvenli / `1` açma; MQTT/LAN `to` türü de taşır: `0x10 closed`,
   `0x11 open` (yalnız vana), `0x20 off`, `0x21 on` (siren/fan/generic); uyuşmazlık `bad_state` (`SafetyManager::handleCommand`).
7. **`uid`.** Yeni komutlarda zorunlu; yoksa ayrıştırma hatası (`last_rej = bad_cmd`, id geçerliyse). Düz v:2 komutlarında isteğe bağlı;
   verilirse ve eşleşmezse sessiz. `uid` denetimi ayrıştırmadan ÖNCE yapılır (başka panonun bozuk komutu da sessiz).
8. **State v:3 eki saf yazıcıyla** (`safety/SafetyView.h` `writeStateExtras`) üretilir ve ArduinoJson çıktısının kapanış `}`'inden önce
   eklenir (aynı fonksiyon `GET /api/status`'ta; QA portu aynı bayt dizisini üretir). `safety.zones` yalnız NORMAL olmayan bölgeleri
   listeler (yokluğu = normal); güvenli kipte `"mode":"safe","reason":"…"`; sensör listesinde yerel kumanda rolleri de bulunur
   (`kind`: `alarm_ack|valve_close|gas_reset`, `active` = ham basılı seviye). `fb`: geri bildirim yok ya da henüz okunmadıysa `null`.
9. **Yayın tetiği:** `StateSignature`'a görünüm imzası (CRC32, `since_up` hariç), `last_rej` sayacı ve `time_ok` eklendi. Görünüm
   loopTask'ta her turda üretilir, içerik değişince ya da 1 sn'de bir kendi mutex'i altında yayınlanır (`SafetyManager::copyView`).
10. **Olay yayını:** MqttTask her 50 ms'de en çok bir olay; JSON kilit altında sabit arabelleğe, yayın kilit dışında. Sığmayan olay
    (beklenmez) onaylanmış sayılıp atılır (state uzlaştırması telafi eder). `connectedAt` aboneliğin tamamlandığı an.
11. **sys:** gelen yük sınırı 1024 bayt; PubSubClient taban arabelleği 1024 -> **1280** (aksi halde 1024 baytlık sys yükü kütüphanede
    düşerdi). `set_local_key` davranışı v1.1.x ile aynı (ayrı işleyici).
12. **`cfg_dump` parçalama öğe tabanlıdır:** 1. parça politika + 4 bölge + ışık seçeneklerini taşır, sensör ve eylemci öğeleri sırayla
    sığdığı kadar (zarf payı 260 bayt, parça ≤ 3500). Ölçüm arabelleği çağırandan gelir (yığında 3,5 KB tutulmaz).

**WP-F5 yapılandırma, LAN, CLI**

13. **Yama modeli tek öğedir** (LAN `POST /api/safety/config` ve bulut `cfg_patch` aynı gövde, `safety/SafetyCfgApi.cpp`). Sihirbaz
    her öğe için ayrı istek gönderir ve bir sonraki istekte yanıttaki `rev`'i `base_rev` olarak kullanır. LAN'da `base_rev` isteğe
    bağlıdır (verilmezse çakışma denetimi yapılmaz). `id`'siz eylemci yeni satırdır; eylemci silinince sonraki kimlikler kayar
    (`act_pos` bitleri kimlik eşleşmesiyle taşınır: aynı röle(ler)/tür/kip/akışkan).
14. **Çalışırken eklenen su vanasında konum o anki röle seviyesinden benimsenir** (`remapActPos`): yapılandırma vanayı kendiliğinden
    açıp kapatmaz (örn. DEENERGIZE_TO_CLOSE vana "bilinmiyor = açık" kuralıyla bir anda enerjilenmezdi). İki röleli ve gaz vanası
    benimsenmez.
15. **Gevşetme tanımı** (`isLoosening`, karar 7.2b-7): CONTRACTS §2.6 "Gerçekleşen ayrıntılar". Kapı/pencere/hareket sensörleri ve
    yerel kumanda rolleri bu modülde emniyet sürmediğinden serbesttir. Kuruluk süresini kısaltmak da gevşetmedir (yalnız CLI/bulut).
16. **Yazım sırası:** yama -> `validate(system, safety)` -> kilitli bölge (`touchesLockedZones`) -> (LAN) gevşetme -> `rev+1` -> NVS
    (isteyen görevde) -> loopTask uygulaması (`serviceConfig`; bölge durumları, aid'ler ve kilit korunur, `SafetyCore::reconfigured`
    indeks tabanlı geçici durumu sıfırlar ve politika değiştiyse `policy_changed` üretir). Uygulama anında kilitli bölgeye değdiği
    anlaşılırsa NVS eski yapılandırmaya geri yazılır. Güvenli kipte (`cfg_corrupt`/`latch_orphan`) uygulanan geçerli yapılandırma kilit
    maskesini kapsıyorsa `setConfigUsable(true)`; çıkış yine yalnız yerel onayla.
17. **`/api/config` çapraz doğrulaması WebTask'ta**, iş loopTask'a postalanmadan önce yapılır (`applyConfigOnLoop` değişmedi). Geçersiz
    bileşim reddedildiği için "erişilemez kalan eylemci" (`actuator_fault`) yalnız açılıştaki uyuşmazlıkta üretilir (dalga 1 not 10).
    Seri CLI `EXTMOD`/`SET_DI` de aynı doğrulamadan geçer.
18. **Komut yanıtı** `{ok, id, rej?}` 1 sn içinde gelmezse `504 {"error":"timeout","id"}`; `id` verilmezse `lan-<ms>-<sıra>` üretilir.
19. **LAN `POST /api/alarm/ack` `force`** güvenli kipten ÇIKARMAZ: `safe_mode` döner (karar 7.2b-10; §5.1.6 madde 3'teki "LAN force"
    ifadesi bu karara uydu). Yerel çıkış: CLI `SAFETY ACK FORCE` ya da `ALARM_ACK` DI'si 5 sn.
20. **Güvenli kipte (`cfg_corrupt`) eylemci tablosu kullanılmaz:** `a<n>` komutları `unknown_actuator` döner (§5.5 (d) "open ->
    safe_mode" yerine); kilit maskesindeki röleye açma yönündeki düz `relay` komutu `actuator_relay`. QA senaryosu buna göre yazıldı.
21. **Yeniden başlatma/sıfırlama:** `force` sorgu argümanıdır (`/api/system/reboot?force=1`). MQTT sys reboot ve OTA bu firmware'de
    yok (yalnız HTTP ve CLI denetlendi).
22. **CLI gevşetme yolu:** `SAFETY POLICY ON|OFF` ve `SAFETY DEL <aN|dN|bN>` (satır içi yama, loopTask'ta). `RELAY ALL ON` eylemci
    rölelerini atlar.
23. **Gömülü web sayfası (`WebPortalPage.h`) değişmedi:** güvenlik ekranı yok (yalnız API). Ayrı iş.

**WP-Q1 ve QA portları**

24. Yeni portlar: `sim/fw/valve_guard.js`, `safety_view.js`, `safety_cfg_edit.js` (edit + JSON), `safety_cfg_api.js`; `EventOutbox`
    LAN halkası; `SafetyManager`/`Automation`/`MqttManager`/yerel API ekleri. `Automation` yeni seçenekler: `epoch` (saat kaynağı),
    `qaLoopStalled` (loop takılması; yalnız bağımsız görevler çalışır).
25. **Hata enjeksiyonu** (`DeviceSimulator`): `setSensor`, `pulseSensor`, `setValveFeedback(follow|stuck_open|none)`, `reboot`,
    `softRestart`, `corruptSafetyCfg`, `extModuleDown`, `dropEventAcks`, `brokerDown`, `bridgeSilence`; QA ucu `POST /__sim/safety`.
    `factoryReset` (QA, flash silme) mevcut anlamını korur; "kilitliyken fabrika sıfırlaması" senaryosu `POST /api/system/reset?force=1`
    ile yapılır (`ahbu_latch` sağ çıkar). `reorderEvents` cihazda değil sunucu testinde (WP-S2) anlamlıdır; eklenmedi.
26. Değişen eski QA beklentileri (yalnız sözleşme gereği): `sim_mqtt*.test.js` `v === 2` -> `v === 3` (+ yapılandırılmamış panoda ek
    anahtar denetimi), `sim_http.test.js` rota tablosu 26 -> 32 (KEYED 20 -> 26), `lib/smoke.js` `v >= 2` [O8].

**Ölçümler**

- RAM 55 616 (v1.1.2) -> 62 856 (dalga 1) -> **66 680** bayt (dalga 2: görünüm x2, olay halkası 32 x 48 B; yapılandırma yazımı ve
  `cfg_dump` kopyaları kalıcı RAM yerine iş süresince öbekten). Flash 1 242 553 bayt (%39,5). En kötü state ek yükü ~7 KB (8 KB
  arabellek); en düşük boş heap ölçümü (≥ 40 KB) cihazda yapılamadı.
- Olay JSON'u en kötü 641 bayt (dalga 1 ölçümü), `cfg_dump` parçası ≤ 3500 bayt (tam dolu yapılandırmada ≥ 3 parça).

**Kabul (bu dalga)**

- Firmware: temiz derleme, uyarı 0; birleşik imajın 0x0000-0xFFFF bölgesi v1.1.2 ile bayt bayt aynı.
- Unity (MSVC): 17 paket, 305 test, 0 hata. QA `npm test`: 521/521. Fabrika aracı: 358/358.
- Uçtan uca: `tools/qa_stack/test/sim_safety.test.js` (9 senaryo, çok panolu ev dahil), `sim_valve_guard.test.js` (5).

**Kalan işler**

- Donanım: sürüm notlarındaki "İlk kartta denenecekler" listesi (ValveGuard çip sıfırlaması, NC selenoid kesinti testi, REBOOT FORCE
  boyunca vana izi, ek modül kopukluğu, gecikme ölçümü, `nvs_get_stats`, en düşük boş heap).
- NVS bütçesi ürün kararı (dalga 1 F0 ölçümü), saat (RTC<->SNTP), köprü sürücüsü, web sayfası güvenlik ekranı.
- Sunucu (WP-S1..S4) ve uygulama (WP-A1..A4) bu sözleşmeye göre uyarlanmalı (`ev/{t}/event` ACL'i, `event_ack`, `cfg_dump` birleştirme).
## Uygulama notları (EKİP APP — WP-A1 + WP-A2, dalga 1)

Kod gerçeğiyle tasarım arasındaki sapmalar ve uygulamada verilen kararlar. Esas kaynak koddur.

1. **Olay akışı uygulamada türetilir.** Uygulama `ev/{t}/event` konusuna abone olmaz (§3.4 ACL kuralı korunur). `EvMqttService.safetyEvents`, pano başına ardışık `state v:3` görüntülerinin farkından `SafetyEvent` üretir (`alarmRaised`, `alarmSilenced`, `alarmCleared`, `valveFault`, `valveFaultCleared`, `sensorFault`, `sensorFaultCleared`, `safeModeEntered`, `safeModeExited`, `commandRejected`). Teslim garantisi yoktur (QoS 0 state); gerçek durum her zaman `DeviceStatus.safety`'dir. `safety` anahtarı kaybolursa "kalktı" olayı üretilmez [O11]. İlk görülen durumdan türeyen olaylar `initial=true` taşır.
2. **[GEÇERSİZ, hizalama: gövde `{to, id}`]** **REST eylemci gövdesi** `{state, id}`'dir (§5.2.4 ve §3.5 tablosuyla uyumlu); `state` değeri metindir: vana `closed|open`, siren/fan/genel `on|off` (MQTT'de `to`). Yol: `POST /v1/homes/:homeId/devices/:deviceUid/actuators/:actuatorId`. Güvenlik uçlarında yanıt `delivered` taşımazsa iletildi sayılmaz (fail-closed). WP-S4 bu gövdeyi kabul etmelidir.
3. **Bulutta onay** `POST /v1/homes/:homeId/alarms/:alarmId/ack {id}`. Uygulama `alarmId`'yi `GET /v1/homes/:homeId/alarms?state=open` listesinde state'teki `aid` (+ bölge, varsa `device_uuid`) ile bulur. Kayıt yoksa ağa komut gitmez, `ALARM_NOT_FOUND` (istemci) ile anlaşılır ret verilir. Liste yanıtında `device_uuid` alanı beklenir (yoksa yalnız `aid`/bölge ile eşlenir). Bölge testi: `POST /v1/homes/:homeId/devices/:deviceUid/alarm-test {zone, id}`, iletim onayı yeterli (`delivery`).
4. **LAN onay gövdesi `aid` taşır**: `POST /api/alarm/ack {zone, aid?, id?}`. §3.5 tablosu `{zone, id?}` yazıyor ama aynı bölüm "gövde MQTT `cmd` ile birebir aynı" diyor ve `alarm_ack` `aid` taşır [Y-9]. LAN yanıtındaki `rej` ve HTTP hata gövdesindeki güvenlik kodları (`zone_latched` ...) Türkçe metne çevrilir. `GET /api/events` yanıtının `{"events":[…]}` biçiminde olduğu varsayıldı (`DeviceEventRecord`). [Hizalama: firmware `{bn, events, more}`; uygulama `more` ile sayfalar.]
5. **İyimser arayüz kuralı (güvenlik).** Yalnız güvenli yön iyimserdir: vanayı kapat (`cmd_closed` anında görünür), sireni/fanı kapat. Vanayı aç, siren/fan aç ve alarm onayı iyimser DEĞİLDİR; onaya kadar gerçek değer kalır, `isActuatorPending` / `isAlarmAckPending` "uygulanıyor" göstergesi verir. Açma ön denetimi (`SafetyState.openBlockReason`) ağa çıkmadan gerekçeli ret üretir: `safe_mode`, `gas_local_only`, `zone_latched` ve istemciye özgü `sensor_unknown` (ok=false sensör kuru sayılmaz [Y-3]) / `sensor_wet`. Vananın `medium` alanı bilinmiyorsa bölgedeki bütün sensörler denetlenir (en tutucu kural).
6. **`last_rej` anında geri alma** `CommandPipeline.observe` içindedir ve bütün komutlara (düz röle dahil) uygulanır. Ret yankısı yalnız komutun hedef panosundan kabul edilir: `submit(targetUid:)` [Y5]; bulut röle/panjur gönderimleri de hedef panoyu (`endpoint.deviceUuid`) verir; LAN'da hedef yok (tek pano). `CommandFailure.code` panonun ya da sunucunun ret kodunu taşır. Sunucu 409 kodları (`ZONE_ALARM_ACTIVE`, `GAS_LOCAL_ONLY`, `ACTUATOR_USE_SAFETY_COMMAND`, `FIRMWARE_UNSUPPORTED`) Türkçe metne çevrilir. `lastRej`, §5.3.1'deki kayıt (record) yerine `SafetyRejection` sınıfıdır; hem `SafetyState.lastRej` hem `DeviceStatus.lastRej` (güvenlik yeteneğinden bağımsız) vardır.
7. **Komut hattı anahtarları pano kapsamlıdır**: `actuator:<id>@<uid>`, `alarm:ack:<zone>@<uid>`, `alarm:test:<zone>@<uid>` (çok panolu evde `a1` ve bölge numaraları pano başınadır). Arayüz anahtar yerine `isActuatorPending(a)` / `isAlarmAckPending(alarm)` kullanmalıdır.
8. **Yerleşim imzası** eylemci rölesinde tür harfinin ardına küçük eylemci harfi ekler (`v` vana, `s` siren, `f` fan, `g` genel, `x` bilinmeyen; ör. `AHBU-…|UDUDLvLLL`); eylemcisiz panoda imza bugünküyle birebir aynıdır (eşdeğerlik testi). `compareWith` lamba/darbe satırında `actuator_type` ile `act`'ı karşılaştırır. Eski sunucu `actuator_type` göndermezse eylemcili panoda uyuşmazlık görülür ve mevcut sınır gereği imza başına en çok 3 sessiz uç nokta yenilemesi yapılır.
9. **Eylemci lamba sayılmaz [Y3]**: `DeviceStatus.controllableRelays`, bulut `relayItems` ve `openLightsCount` eylemci rölelerini/uç noktalarını dışarıda bırakır. Eylemci kanalına düz `setRelay`/`toggleRelay`/`triggerImpulse` ağa çıkmadan `actuator_relay` ile reddedilir. **WP-A4 için not:** sihirbaz röle testi (`relay_logic.dart:170`) `controllableRelays` kullandığından eylemci röleleri o listede artık görünmez; eylemci testi `alarm_test` ile yapılmalıdır.
10. **Yetenekler**: `canCloseActuators` (misafir dahil), `canAckAlarm` ve `canControlActuators` (misafir hariç üyeler), `canTestSafety` (owner/staff/session/super); yerel anahtar sahibi resident düzeyinde (test hariç). `Capabilities` eşitliği web'deki 32 bit sınırı yüzünden ikinci bir maskeyle (`_mask2`) genişletildi.
11. **Adlar [B12]**: eylemci adı röle kanalı üzerinden uç nokta adından (bulut) ya da röle adından (LAN) doldurulur. Sensör adı için yapılandırma kopyası (`cfg_dump` / `GET /api/safety/config`) uygulamada henüz okunmuyor; kimlik gösterilir (`SafetyState.withNames` hazır).
12. **Ayrıştırma ayrıntıları**: `sensors[].ok` alanı yoksa `false` (kuru varsayılmaz); `SafetyState.alarms` test bölgesini de içerir, `hasActiveAlarm` yalnız `latched`/`fault` sayar; sensör üst sınırı istemcide 64 (firmware 56).

## Uygulama notları (EKİP APP — WP-A3 + WP-A4, dalga 2)

Kod gerçeğiyle tasarım arasındaki sapmalar ve uygulamada verilen kararlar. Esas kaynak koddur.

**WP-A3 (kartlar, bölüm, geçmiş)**

1. **Kartın yeri.** §5.3.3 kartı `PeaceBanner`'ın hemen üstüne koyuyordu (o zamanki 294-295). Bugün `OfflineBanner` ile `PeaceBanner` arasında `HomeHero` ve durum şeridi var. Kritik alarm ilk görülen şey olmalı, bu yüzden `SafetyAlertsPanel` (`lib/ui/widgets/critical_alarm_card.dart`) `OfflineBanner`'dan hemen sonra, `HomeHero`'nun **üstünde** durur. LAN kipinde (`_DirectContent`) de aynı yerdedir (K5).
2. **Panel içeriği.** Güvenli kip kartı (`safety.mode=safe`), kilitli ya da arızalı bölge başına `CriticalAlarmCard`, test süren bölge için bilgi kartı ve **"Su kesik"** kartı. "Su kesik" kartı, alarmı olmayan bölgede kapalı ya da kapanan **su** vanası olduğunda çıkar. Uygulama "kilit yeni kalktı" ile "kullanıcı elle kapattı" durumlarını ayırt edemez; iki durumda da kart görünür. Gaz vanası bu kartı üretmez (yalnız yerinde açılır).
3. **Vana satırları türe göre süzülür [K-3].** Su alarmı yalnız su vanalarını, gaz alarmı yalnız gaz vanalarını gösterir; duman alarmında vana satırı ve "Vanayı Kapat" yoktur. "Vanayı Kapat" yalnız açık ya da konumu belirsiz vana varsa görünür; tek onayla bunların hepsine `closeValve` gönderilir.
4. **Onay düğmesi.** Bölgede ıslak sensör varken ve alarm susturulmamışken düğme "Sesi Sustur", aksi halde "Alarmı Onayla" olur. Susturulmuş ve hâlâ ıslak bölgede düğme gizlenir ve açıklama gösterilir ("sensör kuruyunca onaylayın"). `SensorItem` pano kimliği taşımadığı için çok panolu evde ıslaklık bölge numarasıyla birleşir. Bu yalnız düğme etiketini etkiler; komut hedefi alarmın panosudur.
5. **Onay diyaloğu.** "Sesi Sustur / Alarmı Onayla", "Vanayı Kapat" ve "Vanayı Aç" `showSimpleConfirm` ile (`showAppDialog`, ortak kabuk) onaylatılır; anahtarlar `btn_safety_confirm` / `btn_safety_cancel`. Siren/fan anahtarı diyalogsuzdur (anlık güvenli yön). Komut hataları kabuktaki tek hata abonesinde gösterilir. "Yeniden dene" kaydı pano kapsamlı komut anahtarını (`actuator:<id>@<uid>`) kullanır.
6. **Misafir (7.2b karar 4).** Misafir vanayı kapatabilir ve sireni susturabilir. Alarmı onaylama düğmesi gizlidir (yerine açıklama gösterilir); "Vanayı Aç", "Aç" ve kapalı sirenin anahtarı **hiç çizilmez**. Alarm geçmişi bağlantısı da gizlidir, çünkü misafir alarm bildirimi almaz.
7. **Açma engeli arayüzde.** `AutomationState.valveOpenBlockReason` (yeni, ham durumdan) düğmeyi devre dışı bırakır ve gerekçeyi `safetyRejectMessage` ile yazar (`sensor_unknown`, `sensor_wet`, `zone_latched`, `safe_mode`). Açma iyimser değildir; bekleme sırasında "Açılıyor…" / "Uygulanıyor…" gösterilir.
8. **Güvenlik ve Eylemciler bölümü** (`endpoint_sections.dart`) panjurlardan önce gelir. `ActuatorCard` canlı değerini kendisi seçer, bölüm yalnız kart kümesi değişince kurulur (`_signature`'a eylemci ve sensör kimlikleri eklendi). Oda süzgecinde eylemcinin odası rölesinin uç noktasından gelir. Sensörlerin odası yoktur, bu yüzden süzgeç seçiliyken sensör hapları gizlenir. LAN kipinde süzgeç yoktur. Eylemcisiz ve sensörsüz (v:2) panoda bölüm hiç yoktur; lamba/panjur bölümleri birebir aynıdır.
9. **Alarm geçmişi** (`lib/ui/pages/alarm_history_page.dart`, `AutomationState.fetchAlarmHistory`, model `AlarmHistory`). Bulutta `GET …/alarms?state=all`, LAN'da `GET /api/events` kullanılır. Yükleniyor, hata + yeniden dene ve boş durumları ayrıdır. **WP-S4:** liste ucu `state=all` desteklemelidir.
10. **Hareket v3.** Kartlar yalnız tek seferlik `StaggeredEntrance` ile girer; yanıp sönme ya da döngü yoktur. `MotionScope.off`'ta süre 0'dır. Etkin orb'un mevcut ortam nabzı tasarımın bilinçli ambient katmanıdır (PeaceBanner ile aynı); tam kip testi bu yüzden sabit `AmbientClock` ile yapılır. Başlık ve güvenli kip metni `liveRegion`'dır.

**WP-A4 (sihirbaz Adım 7)**

11. **Kayıt biçimi.** §4.4'teki düz alanlar (`actuatorKind`, `closeMode` …) yerine `RelayCheck.assign` (`ChannelAssignment`) tutulur; girişler `RelayLogic.inputs` (`InputAssignment`) içindedir (`logic/safety_assignment.dart`, saf). Kayıt `v:2`'dir. Adım 7 verisine `assign`, `inputs` ve `safety_dirty` eklendi, ama bunlar yalnız doluyken yazılır: atamasız kurulumda kayıt bugünküyle birebir aynıdır. `v:1` kaydı varsayılanlarla açılır.
12. **Panoda zaten eylemci olan röle.** Bu röle listede kalır (`controllableRelays` yerine "lamba/darbe ve panjur dışı" süzgeci; eylemcisiz panoda liste aynıdır). Türü panodan önceden seçili gelir. Doğrulaması "Bölge Testi" (`alarm_test`) ve gözle teyitle yapılır. Düz röle komutu bu kanala hiç gönderilmez.
13. **[GEÇERSİZ, hizalama: firmware F5 tek öğelik yama; uygulama `buildSafetyPatches` + `applySafetyConfigPatches`, CONTRACTS §2.6]** **`POST /api/safety/config` gövdesi (F5 eşleşmeli).** Firmware'in kesin biçimi tasarımda yoktu; uygulamanın gönderdiği biçim şudur:
    - Gövde: `{base_rev, actuators[], sensors[], lights[]}`.
    - `actuators[]`: `{relay, kind, zones:[z], close_mode: energize|deenergize, medium, drive: level|pulse2, open_relay?, pulse_s?, fb_di?, run_limit_s? (siren 180), atex? (fan)}`.
    - `sensors[]`: `{src: di|bridge, index, kind, zone, active_open}`. `kind` değerleri: `water|gas|smoke|door|window|motion|alarm_ack|valve_close|gas_reset`.
    - `lights[]`: `{relay, dimmable, dimmer_src, dimmer_addr, dimmer_ch}`.
    - Geri bildirim girişi ayrı sensör satırı değildir; vananın `fb_di` alanıdır.
    - `GET` yanıtı `{rev, crc, …aynı diziler}` kabul edilir. Okunabildiğinde sihirbaz mevcut atamayı bundan doldurur (asıl kaynak pano, K5); okunamazsa `state` özetini kullanır.
    - Ret `{ok:false, rej}` ile gelir.
14. **Bölge testi sonucu.** Sonuç `GET /api/events` halkasındaki yeni `test_result {zone, ok, fb_ms}` olayından okunur (`DeviceEventRecord.ok/fbMs` eklendi). En çok 15 sn beklenir. Sonuç gelmezse "Geri bildirim yok: vananın kapandığını gözle doğrulayın." yazılır. Vanası olmayan bölgede metin siren/cihaz için yazılır. `ok:false` adımı tamamlatmaz.
15. **"Bilmiyorum" (kapanma kipi).** §4.4 rehberli bir test öneriyordu. Bunun yerine kartın mevcut Aç/Kapat testiyle gözleme yönlendirilir; yanıt seçilmeden kayıt yapılamaz. Bu, bilinmeyen kiple vananın ters sürülmesini önler.
16. **İki röleli vana (7.2b karar 2).** Bu kanal KAPAMA rölesidir, açma rölesi listeden seçilir. Açma rölesinin kendi "ne bağlı?" sorusu kilitlenir ve not gösterilir. Darbe süresi varsayılan 15 sn'dir; arayüzde henüz düzenlenmiyor.
17. **K4 yer tutucuları.** `{k}` (dimmer çıkışı), dimmer isteyen kanallar arasındaki sıradır (1'den). Bütün Modbus dimmer kanalları tek modül adresini (`{önerilen_adres}`) paylaşır; modülün kanal sayısı denetlenmez. `{seçim}` hub yokken "hub kurulunca seçilir" olur. `{ext_addr}` `GET /api/config` `ext_module_address`'tan okunur (yalnız ek modül açıkken).
18. **Tamamlanma koşulu.** Güvenlik cihazı ya da sensör ataması panoya yazılmadan Adım 7 bitmez. Yalnız dimmer yanıtı bitişi engellemez (yönergedir; desteklemeyen panoda da kaydedilebilir). Güvenlik yeteneği olmayan panoda eylemci seçilirse "v1.2.0'a güncelleyin" notu çıkar ve kayıt kapalı kalır.
19. **Yerel anahtarla gevşetme (7.2b karar 7).** Uygulama LAN'dan eylemci silmeyi ya da politikayı kapatmayı ayrıca engellemez. Firmware reddeder; ret metni sihirbazın hata kutusunda gösterilir.
20. **Kalan.** Sihirbazda canlı sensör göstergesi yok ("sensöre su damlatın", `dis[]`/`sensors[]` saniyelik yoklama). Panoda sensör adı yerine kimlik gösteriliyor (`cfg_dump` okunmuyor). Altın PNG görseller çekilmedi. Darbe süresi ayarı yok.

## Sözleşme hizalaması (2026-10-07, üç ekip birleşimi sonrası)

Üç ekip (FW, SRV, APP) birbirini görmeden çalıştı. Birleşik ağaçta her mesaj ve uç alan alan karşılaştırıldı (state v:3, olaylar,
cmd, sys, REST, LAN). Tek doğru kaynak `docs/CONTRACTS.md` §1.5d, §2.5, §2.6 ve yeni §2.7 (üretici/tüketici eşlemesi). Yukarıdaki
uygulama notlarında "[GEÇERSİZ, hizalama …]" işaretli maddeler bu bölümle değişti.

**Düzeltilen uyumsuzluklar (yer ve test)**

1. **Eylemci gövdesi.** APP REST `{state, id}` ve LAN `{actuator, state}` gönderiyordu; firmware LAN'da `state`'i `400 unknown_field`
   ile reddeder, sözleşme `to` der. APP artık iki yolda da `to` gönderir (sunucu eski `state`'i kabul etmeye devam eder).
   Test: `test/services/safety_api_test.dart`, `automation_state_safety_test.dart`.
2. **Alarm listesi.** Sunucu `data: {items, next_before}` döner; APP `data.alarms` okuduğu için liste (ve onay için `aid` araması)
   HER ZAMAN boştu: bulutta alarm onayı `ALARM_NOT_FOUND` ile hiç gitmiyordu. APP `items`'ı okur; `before` tarih değil alarm
   kimliğidir. `state=all` ve `device_uuid` sunucuda zaten vardı (PG testi mevcut). Test: `safety_contract_alignment_test.dart`.
3. **`safety.zones` yokluğu = normal.** Firmware yalnız normal olmayan bölgeleri yazar; APP bildirilmeyen bölgeyi "normal değil"
   sayıp vana açmayı kalıcı engelliyor, alarm onayının "kilit kalktı" teyidini hiç görmüyordu. `SafetyState.zoneStatus` eklendi;
   `openBlockReason` ve `CommandConfirm.alarmSilencedOrCleared` bunu kullanır. Eski model testi bu yanlış varsayımı kodluyordu,
   düzeltildi. Sunucu zaten doğruydu.
4. **`cfg_dump`.** Firmware öğe dizilerini KÖKTE yazar; sunucu `body` nesnesi beklediği için her dökümü reddediyordu (yapılandırma
   kopyası hiç oluşmuyordu). Sunucu iki biçimi de kabul eder ve parçaları tek belgeye birleştirir (`mergeCfgDumpParts`; eski
   `{parts:[…]}` kayıtları okurken düzleştirilir). Test: `server/test/safety/safety_payload.test.js`, `alarm_service_pg.test.js`.
5. **Adlar (`cfg`).** Yeni uç `GET /homes/:homeId/devices/:deviceId/safety-config` (view). APP `state.cfg.safety.rev/crc`
   değişince bulutta bu ucu, LAN'da `GET /api/safety/config`'i okur (pano başına tek uçuş, hata/eski kopyada 60 sn sonra) ve
   sensör/eylemci adlarını gösterir (eylemci adı kopyada yoksa uç nokta / röle adı). Test: `safety_contract_alignment_test.dart`,
   `server/test/safety/safety_routes.test.js`.
6. **LAN yapılandırma yazımı.** APP toplu `{base_rev, actuators[], sensors[], lights[]}` gönderiyordu; firmware TEK öğe (`set`/`del`)
   kabul eder (`400 bad_field`). Sihirbaz artık panonun yapılandırmasını okuyup yalnız değişen öğeleri sırayla yazar (sıra ve
   eşleme CONTRACTS §2.6). Panodan okuma (`fromBoard`) firmware alanlarını (`close_mode:pulse`, `relay2`, `fb_di:0`, `exproof`,
   ışık `src` sayısı) anlar. Test: `test/ui/f_setup_safety_assignment_test.dart` (sahte pano F5 gibi davranır).
7. **Olaylara `aid` (firmware).** `valve_fault`, `valve_fault_cleared`, `alarm_silenced`, `alarm_cleared` bölgenin alarm kimliğini
   taşır (sunucu bunu zaten okuyordu). `Event` yuvası +15 B (`aid[15]`), RAM +768 B. Test: Unity `test_event_outbox`,
   `test_safety_fsm`; QA `fw_event_outbox`, `fw_safety_fsm`.
8. **`test_result` (firmware).** Biçim APP'in beklediğiyle aynıydı (`zone, ok, fb_ms`), ama geri bildirimsiz bölgede `fb_ms:0`
   yazılıyordu ve uygulama "Vana 0,0 sn'de kapandı (geri bildirim doğrulandı)" diyordu. `fb_ms` artık yalnız ölçüldüyse yazılır.
9. **LAN olay halkası sayfalama.** Halka 32, sayfa 16: 16'dan fazla olay varken yeni `test_result` ilk sayfada görünmüyordu.
   APP `more` ile son eid'den devam eder. Test: `safety_contract_alignment_test.dart`.
10. **Sunucu ret eşlemesi (APP).** `409 DEVICE_REJECTED` `reason` (firmware kodu) Türkçe metne ve hata koduna, `DEVICE_OFFLINE` +
    `ack_queued` "kuyruğa alındı" metnine, `ALARM_NOT_OPEN` metne çevrilir. LAN `local_loosen_forbidden`, `safety_active`,
    `timeout` (504) ve 400 kodları metne çevrilir.
11. **İstemci komut kimliği (SRV).** Güvenlik rotaları gövdedeki `id`'yi yok sayıyordu; sunucu kendi kimliğini ürettiğinden
    `last_rej.id` uygulamanın komutuyla eşleşmiyordu. Rotalar `id`'yi panoya taşır (şema doğrular). Test: `safety_routes.test.js`,
    `command_schema_safety.test.js`.
12. **Kumanda rolleri.** Firmware `sensors[]`'a `alarm_ack|valve_close|gas_reset` satırlarını da yazar; sunucu bunları `generic`,
    uygulama `unknown` yapıyordu. İkisi de türü korur; uygulama vana açma ön denetiminde kumanda satırını sensör saymaz.
13. **Bakım (SRV).** `device_events` 90 gün saklama (zamanlayıcının günlük temizliği); başarısız alarm push'u 5 sn sonra bir kez
    yeniden denenir. Test: `server/test/bridge/scheduler_tick.test.js`, `server/test/safety/alarm_service.test.js`.

**Firmware paketi.** v1.2.0 aynı sürüm numarasıyla yeniden üretildi (henüz hiçbir karta yazılmadı): `firmware_releases/v1.2.0`
(yeni SHA-256'lar `SHA256SUMS.txt`'te; 0x0000-0xFFFF bölgesi değişmedi).

**Kalanlar (bu turda yapılmadı)**

- Uygulamada FCM push alıcısı yok (Firebase'siz yapı): `safety_alarm`/`safety_info` kanalları ve bildirime dokununca alarm ekranı.
- Buluttan yapılandırma yazımı (`sys cfg_patch`, `device_configs.pending`, `409 CONFIG_CHANGED_ON_DEVICE`) ve bulut kipinde
  sihirbazın yapılandırma yazması yok (sihirbaz LAN/AP üzerinden yazar).
- Bölge adları kopyadan okunuyor (`SafetyConfigNames.zones`) ama arayüzde henüz gösterilmiyor (kartlar "Bölge N" yazar).
- Bulut alarm geçmişi tek sayfa okur (`next_before` ile "daha fazla" yok).
- Donanım doğrulaması (sürüm notlarındaki "İlk kartta denenecekler") ve NVS bütçesi ürün kararı aynen açık.

## İnceleme turu (entegrasyon)

Üç ekibin birleşik dalı (taban `297f276`, inceleme HEAD `9362fe2`) üzerinde yapılan karşıt doğrulamanın CONFIRMED ve PARTIAL
bulguları bu turda TDD ile ele alındı. Her düzeltmenin önce kırmızı (eski mantıkta başarısız) testi yazıldı. Firmware'in saf
çekirdek değişiklikleri QA simülatörünün JS portuna da birebir taşındı (`sim/fw/*`, `test/fw_*.test.js`, `fwcheck --update`).
Firmware sürümü değişmedi (**1.2.0**, henüz hiçbir karta yazılmadı); paket yeniden üretildi (`firmware_releases/v1.2.0`).

### Düzeltilenler

| Bulgu | Önem | Ne yapıldı | Nerede |
|---|---|---|---|
| E2E-1 / RV-1: sunucu, state'te listelenmeyen bölgeyi "bilinmiyor" sayıyordu | yüksek | `onLiveState` sözleşmeye uyar: `zones[]`'ta olmayan bölge NORMAL'dir. Kanıt gücü değişmedi: mode normal + rev geri gitmedi → `cleared/device_state`, aksi halde `lost` + bilgi push'u. Bekleyen onay isteği düşürülür. PG testleri firmware'in gerçek biçimine (`zones: []`) çevrildi. **Doğrulayıcı önerisinden sapma:** fallback yalnız `mode==='normal'` iken değil, `safety.present` olduğu her durumda uygulanır. Güvenli kipte yokluk böylece `lost` olur. Yalnız normal kipte uygulansaydı güvenli kipteki panonun satırı hiç kapanmazdı. | `server/src/services/alarm_service.js` |
| E2E-2: kilitli bölgeye yeni tehlike türü için olay yoktu | yüksek | Firmware yeni bir `alarm_raised` üretir: yeni `aid` = olayın eid'si, `kind` = bölgenin bütün türleri (öncelik gaz > duman > su), kaynaklar birleşik, susturma/onay sıfır. Eski `aid` ile onay `stale_ack` alır. Sunucu yeni satırı açar ve push gönderir. Aynı bölgede başka `aid` ile kilit görürse eski satırı `cleared_by=superseded` ile kapatır. Sunucu ve uygulamada şema değişikliği yok (`cleared_by` VARCHAR(16)). | `SafetyFsm.h` `stepZone`; `alarm_service.js`; CONTRACTS §2.6 |
| EM-1: kilitsiz kapalı E2C vana ve gaz vanası yeniden başlatmada açılıyordu | yüksek | (1) `shutdownKeep*` artık kilit kaydından değil, her turda ValveGuard'ın tutma maskesinden gelir: KAPALI komutlu enerjiyle-kapanan vanalar ve güvenli kipte kilit/açılış maskesi. (2) Yeni kalıcı **açılış güvenli maskesi** `ahbu_latch/safe_msk` (2 x u64, `bootSafeMasks`): KAPALI komutlu vanalar + bütün gaz vanaları (K-4). Konum değişince ya da yapılandırma uygulanınca yazılır. `Relay_Init` kilit maskesine ek olarak bunun yerel seviyesini ilk yazımda korur. **Spec §5.1.6 madde 1 ve 6 genişletildi:** "yalnız kilit maskesi" yerine "kilit maskesi + açılış güvenli maskesi". | `SafetyManager.cpp` (`refreshKeep`, `persistSafeMask`), `SafetyStore.*`, `WS_Relay.cpp`, `ActuatorMap.h` |
| EM-2: yama/yeniden başlatma FAULT'u ve geri bildirim zamanlayıcısını sıfırlıyordu | yüksek | (1) `ActuatorCore::reconfigure` + `actuatorIdentityMap`: eşlenen eylemcinin çalışma durumu taşınır (konum, `cmdAt`/`fbFault`/`fbSeen`, darbe, siren bütçesi). `SafetyCore::reconfigured(via, now, map)` elle açık, kullanıcı susturması ve test vana bitlerini aynı eşlemeyle taşır. Kimlik: röle(ler) + tür + kip + akışkan + geri bildirim girişi. (2) FAULT kilit kaydında FAULT olarak saklanır ve geri yüklenir. (3) Bölgenin geri bildirimli vanaları KAPALI görülmeden FAULT kalkmaz (`fbUnconfirmed`) ve `canClear` bölgeyi NORMAL'e döndürmez. Bu, açılış varyantını da kapatır: fbFault sıfırdan başlasa bile kuru + onaylı bölge temizlenmez. | `SafetyFsm.h`, `ActuatorMap.h`, `SafetyCfgEdit.h`, `SafetyManager.cpp` |
| EM-3: yarıda kalan iki röleli KAPAT darbesi yenilenmiyordu | yüksek | `SafetyCore::begin`: KAPALI komutlu her iki röleli vanaya bir KAPAT darbesi verilir. Bu yalnız kilitli bölgedekileri değil, gaz vanasını da kapsar (K-4). Yamada darbe artık `reconfigure` ile korunur. | `SafetyFsm.h` |
| EM-4: test sonu geri açma kullanıcı kapatmasını ve açma iznini yok sayıyordu | orta | `actuatorSet(safe)` her bölgenin `testPrevOpen` bitini temizler. Geri açma yalnız güvenli kip dışında ve `openPermission == OK` iken yapılır (bölge önce NORMAL'e alınır). | `SafetyFsm.h` `stepTest` |
| EM-5: cfg_corrupt ve kilit yokken vana maskesi boştu | orta | Yapılandırma kullanılamıyorsa son geçerli açılış güvenli maskesi güvenli kipte dayatılır (`imposeBootMask`). `bootMaskForSystem` bu maskeyi ana yapılandırmaya göre süzer: panjur ya da darbe rölesine ve var olmayan röleye dokunulmaz. Güvenli kipten çıkış kullanılabilirliği yalnız kilit kaydının maskesine bakar (`latchRecordAssert`), bu yüzden silinmiş bir vana çıkışı kilitlemez. cfg_corrupt iken maske üzerine yazılmaz. | `SafetyFsm.h`, `SafetyConfig.h`, `SafetyManager.cpp` |
| EM-6: LAN'dan bir DI satırı GAS_RESET'e çevrilebiliyordu | orta (kısmi, bkz. ertelenenler) | `isLoosening` artık şunları gevşetme sayar: mevcut bir sensör ya da rol satırını GAS_RESET'e çevirmek (kapı kontağı, VALVE_CLOSE...) ve mevcut GAS_RESET satırının bölgesini değiştirmek. Boş girişe YENİ GAS_RESET eklemek gevşetme sayılmaz, yani sihirbaz akışı aynen çalışır. | `SafetyCfgEdit.h` |
| EM-7: yeni eklenen ex-proof fan denetlenmiyordu | orta | `isLoosening`: `i >= a.nAct` olan yeni satırlarda `AF_FAN_EXPROOF` gevşetmedir. | `SafetyCfgEdit.h` |
| RV-2: uid'siz düz röle komutu başka panonun sirenini susturuyordu | orta | Firmware (MqttManager) eylemci rölesine gelen uid'siz `RELAY_SET`/`RELAY_TOGGLE` komutunu sessizce yok sayar. Eylemci olmayan rölede komut v:2 gibi işler. Sunucu (`sendCommand`), güvenlik destekli panoya (caps `safety`) düz röle komutunu hedef `uid` ile gönderir. v:2 pano bilinmeyen alanı reddettiği için ona `uid` eklenmez. | `MqttManager.cpp`, `device_service.js`, CONTRACTS |
| RV-3 (geçerli kısım): yazım öncesi boş girdi denetimi yoktu | orta | `saveConfig` önce `nvs_get_stats` ile `nvsRoomForConfig` denetimini yapar. Yapılandırma, kilit kaydı + act_pos + güvenli maske + siren için ayrılan 16 girdilik payı yiyemez; pay yetmezse hiçbir şey yazılmaz ve sonuç `storage` olur. | `SafetyConfig.h`, `SafetyStore.cpp` |
| RV-4: yarım NVS yazımı geri alınmıyordu | düşük | `saveConfig` sırası: `ver=0` (geçersiz işaret) → blob'lar → `rev` → `ver=geçerli`. Yarıda kalan yazım açılışta cfg_corrupt olur (EM-5 maskesi devrede). Karışık ama blob başına CRC'si geçerli bir tablo artık kullanılmaz. `submitEdit` yazım bir şeye dokunduysa eski yapılandırmayı geri yazar. | `SafetyStore.cpp`, `SafetyManager.cpp` |
| RV-5: PG testinde "deadlock detected" | orta/düşük | `migration_033_pg.test.js` 033'ü (DDL) paralel koşan diğer PG test dosyalarıyla aynı veritabanında çalıştırıyor. Kilitlenme kurbanı test her şey ROLLBACK olduğu için en çok 3 kez yeniden denenir. | `server/test/safety/migration_033_pg.test.js` |
| RV-6: 14 Dart dosyası CRLF'ye dönmüştü | düşük | 9 dosya tabanda LF idi; 5'i yeni dosya. Hepsi LF'ye çevrildi (depo kuralı). | `lib/**`, `test/**` |
| RV-7: her canlı state'te açık alarm sorgusu | düşük | Cihaz başına "açık alarm yok" önbelleği (60 sn). Önbellek ancak sorgu satır döndürmediğinde, satır açılmadığında ve bütün bölgeler normal olduğunda kurulur. Kilitli/arızalı bölge içeren state, `alarm_raised` olayı ve açılan satır önbelleği bozar. | `alarm_service.js` |
| Yan etki: yamada GAS_RESET ile açılmış gaz vanası kapanıyordu | düşük | `reconfigure` konumu taşır. K-4 (her **açılışta** kapalı) değişmedi. | `ActuatorMap.h` |

### Ertelenenler ve gerekçeleri

- **RV-3, sayısal kısım (7/4/0 boş girdi):** Bu sayılar model hesabıdır. Ayrılmış GC sayfasının ve ad girdilerinin hesaba etkisi
  ancak kartta `nvs_get_stats` ile ölçülebilir; donanım yasağı yüzünden ölçülmedi. Bu turda yazım öncesi pay denetimi eklendi.
  `nvsBlobEntries` tahmini çok sayfalı blob'larda sayfa başına ek başlığı saymayabilir. Sahada ölçülüp `NVS_SAFETY_RESERVE_ENTRIES`
  gerekirse büyütülmeli. NVS bölümünü büyütmek (0x8000) ayrı bir karar: seri yükleme gerektirir.
- **EM-6, ürün kararı gerektiren kısım:** Boş bir girişe **yeni** GAS_RESET atamak LAN'dan hâlâ serbest. Kurulum sihirbazı gaz
  vanası seçilince bu atamayı yerel anahtarla yapıyor; bunu yasaklamak sihirbaz akışını bozar. Fiziksel onay istenip istenmeyeceği
  (ör. seri CLI ya da düğmeye basılı tutma) bir ürün kararıdır ve bu turda verilmedi. Kapı kontağı gibi var olan bir satırı
  çevirmek artık reddediliyor; bu, doğrulayıcının "ağırlaştırıcı" dediği durumu kapsıyor.
- **RV-2, sunucunun diğer yolları:** `peace_service` (lambaları kapat) ve zamanlayıcı/senaryo hâlâ uid'siz düz röle komutu
  gönderiyor. Bu komutlar eylemci rölesine düşerse firmware artık onları yok sayıyor, yani güvenlik etkisi kapandı. Çok panolu
  evde, eylemci olmayan aynı numaralı rölelerin çakışması v:2'den kalma bir davranış ve bu turun kapsamı dışında.
- **RV-5, canlı göç riski:** Bu risk çıkarımdır ve gözlenmedi. `migrate.js` göçü tek transaction içinde, `lock_timeout` 15 sn ve
  danışma kilidi ile çalıştırıyor. Kilitlenme olursa göç atomik olarak geri alınır ve dağıtım görünür biçimde durur; yarım şema
  kalmaz. Dağıtım adımı aynı kalır: göçü köprü/PM2 yükü düşükken çalıştırın.
- **Donanım doğrulaması:** Yeni `safe_msk` anahtarı, Relay_Init'te korunan bitler, açılıştaki darbe yenilemesi ve uid'siz komutun
  yok sayılması kartta denenmedi (COM/pano erişimi yasak). Sürüm notlarındaki "İlk kartta denenecekler" listesine bu maddeler de
  eklenmeli: kapalı E2C vananın planlı yeniden başlatmada enerjili kalması, cfg_corrupt sonrası vananın kapalı kalması, iki röleli
  vananın açılışta KAPAT darbesi.

### Bu turun test sonuçları

- Firmware Unity (MSVC): 17 paket, **321 test**, 0 hata, derleme uyarısı 0. Önceki 306 teste 15 yeni test eklendi.
- QA simülatörü (`tools/qa_stack`, `npm test`): **541/541**. İnceleme HEAD'inde 522 test vardı; 19 yeni test eklendi: Unity portları +15, `sim_safety_hooks` +3, `sim_safety` +1.
  `fwcheck` güncel.
- Sunucu `npm test`: PG'siz 2172 testten **2022 geçti**, 150 atlandı (PG), 0 hata. PG'li (`evy_gk_ver`) 2172 testten **2171 geçti**, 1 atlandı, 0 hata.
  İnceleme HEAD'inde 2167 test vardı ve PG'li koşuda 1 hata çıkıyordu (RV-5 kilitlenmesi); 5 yeni test eklendi.
- Fabrika aracı: **358/358**. Flutter: `analyze` 0 sorun; `test` **4380 geçti**, 485 atlandı, 0 hata.
- Firmware derleme: temiz, uyarı 0, RAM %20,6 (67472 B), Flash %39,6 (1246317 B). Paket v1.2.0 için ana imaj SHA-256
  `bf2fd161e9836caf8b94f00503172f1a7840296156c0a70dc42c16c7c481aa60`, uygulama SHA-256
  `c65e58f0ea864eb9da19026bb145dac48596f5cb01cf9062203c0bf322222db7`. 0x0000-0xFFFF bölgesi v1.1.2 ile bayt bayt aynı.

## İnceleme turu 2

İnceleme turu (entegrasyon) düzeltmelerinin (HEAD `a2921e7`) karşıt doğrulamasında FW2-1, FW2-2 ve RV2-2 CONFIRMED, FW2-3 ve RV2-1
PARTIAL çıktı; çürütülen bulgu yok. Beşi de bu turda TDD ile ele alındı: önce kırmızı test yazıldı (Unity, QA simülatörü, sunucu),
sonra düzeltme yapıldı. Simülatör portlarının bulguyu yakaladığı mutasyonla da doğrulandı: düzeltme geri alınınca iki yeni
`sim_safety_hooks` testi kırmızıya döndü. Firmware sürümü değişmedi (**1.2.0**, hiçbir karta yazılmadı); paket yeniden üretildi.

### Düzeltilenler

| Bulgu | Önem | Ne yapıldı | Nerede |
|---|---|---|---|
| FW2-1: güvenli kipte (cfg_corrupt ya da bayat `safe_msk`) vana rölesi darbe/panjur rölesine çevrilebiliyordu; Relay_Init sonraki her açılışta onu enerjiliyordu | yüksek | (1) Ana yapılandırma doğrulaması `validateSystemChange(sys, safety, relayGuard)` oldu. `relayGuard`, NVS'teki açılış güvenli maskesi ile çekirdeğin kilit maskesinin birleşimidir. Bu maskedeki röle, güvenlik tablosu boş olsa bile panjur ya da darbe rölesine çevrilemez (`409 cfg_invalid`, `act_relay_impulse`/`act_relay_shutter`). `/api/config` ve seri CLI bu yolu kullanır. Maske `copyConfig` ile aynı kilit altında okunur. Yazımı başarısız kalmış bayat bitler de korunur, çünkü `safeMaskA_` yalnız başarılı yazımda güncellenir. (2) Güvenli kipte açılışta `bootMaskForSystem`'in düşürdüğü bitler (panjur/darbe ya da var olmayan röle) kalıcı maskeden de silinir. Bu işlem yalnız bit siler. Böylece doğrulamasız bir yoldan kalmış eski durumda bile Relay_Init darbe rölesini enerjilemez. Aynı oturum varyantı da kapanır: dayatılan maske açılışta süzülür ve oturum boyunca o röle tür değiştiremez. **Öneriden sapma:** Relay_Init'te süzme yapılamadı, çünkü ana yapılandırma Relay_Init'ten sonra yükleniyor. Bunun yerine maskenin kendisi tutarlı tutuluyor. | `SafetyConfig.h` (`validateSystemChange`), `SafetyManager.cpp` (`publishGuard`, `begin`), `WebPortal.cpp`, `main.cpp` |
| FW2-2: sil + yeniden ekle iki adımıyla kapı kontağı girişine GAS_RESET atanabiliyordu (GAS_RESET bölgesi için de aynısı geçerliydi) | orta | Kalıcı **DI kullanım geçmişi** eklendi: NVS `ahbu_latch/di_hist` (u64; fabrika sıfırlaması silmez, `/api/reset` ile atlatılamaz). Uygulanan her yapılandırmanın sensör/rol satırlarının ve vana geri bildirim girişlerinin DI'leri bu geçmişe eklenir (`diUseMask`); geçmiş yalnız büyür. `isLoosening(a, b, diHist)`: a'da karşılığı olmayan YENİ bir GAS_RESET satırının DI'si geçmişte varsa bu gevşetmedir. Hiç kullanılmamış girişe yeni GAS_RESET (sihirbaz akışı) serbest kalır; seri CLI ve bulut owner/servis yolu değişmedi. | `SafetyCfgEdit.h`, `SafetyManager.cpp` (`mergeDiHist`), `SafetyStore.*` |
| FW2-3: IDF 4.4'te `free_entries` boş GC sayfasını da sayıyordu ve geri yazım aynı pay denetimine takılıp `ver=0` bırakabiliyordu | orta | `NVS_GC_PAGE_ENTRIES = 126` paydan düşülür (`nvsRoomForConfig` = yapılandırma + 16 + 126). Başarısız yazımdan sonra eski yapılandırmanın geri yazımı (`submitEdit`'in iki geri dönüş yolu) pay denetimini atlar (`saveConfig(c, touched, checkRoom=false)`). | `SafetyConfig.h`, `SafetyStore.*`, `SafetyManager.cpp` |
| RV2-1: `zones[]` bozuk ya da ileri sürümden gelince listede olmayan bölge "normal" sayılıp satır kapanıyordu | orta | Ayrıştırıcı özete `zones_complete` yazar. Değer `false` olur: `zones` dizi değilse, bir öğe düşürüldüyse (bilinmeyen `st`, geçersiz öğe, sınır aşımı) ya da `safety` hiç yoksa. Anahtar yoksa ya da liste tamsa `true` olur. `onLiveState` eksik listede, listede olmayan bölgenin satırına dokunmaz (ne `cleared` ne `lost`) ve "temiz pano" önbelleğini kurmaz. Alanı olmayan eski özet tam sayılır. Uygulama bilinmeyen `st`'yi zaten `unknown` gösteriyor; değişiklik gerekmedi. | `server/src/utils/safety_payload.js`, `server/src/services/alarm_service.js`, CONTRACTS §2.6 |
| RV2-2: 033 PG testi paylaşılan veritabanında DDL koşuyordu; kilitlenme kurbanı başka dosya olunca o dosyanın temizliği hatayı yutuyordu | düşük | `migration_033_pg.test.js` yetki varsa kendi geçici veritabanını kurar (`<db>_t033_<pid>`, `scripts/migrate.js` ile 001..033) ve sonunda siler. `CREATE DATABASE` yetkisi yoksa eski yola (aynı veritabanı + yeniden deneme) döner. `peace_integration.test.js` temizliği 40P01/55P03'te yeniden dener; hatayı artık yutmaz. | `server/test/safety/migration_033_pg.test.js`, `server/test/peace/peace_integration.test.js` |

### Ertelenenler ve gerekçeleri

- **FW2-2, hiç yapılandırılmamış ama fiziksel olarak kablolu giriş:** Kapı kontağı güvenlik tablosuna hiç girmemiş bir DI'ye LAN'dan
  doğrudan GAS_RESET atamak hâlâ mümkün. Pano kablonun ucunda ne olduğunu bilemez. Bunu kapatmak fiziksel onay ister (seri CLI ya da
  düğmeye basılı tutma); bu ürün kararıdır ve sihirbaz akışını değiştirir. Önceki turdaki erteleme bu kısım için sürüyor.
  **Yan etki:** LAN'dan silinmiş bir GAS_RESET satırını aynı girişe yeniden eklemek de artık reddedilir (`403 local_loosen_forbidden`).
  Bu durumda seri CLI ya da bulut owner/servis yolu kullanılmalı. Fabrika sıfırlamasından sonra eski girişler için de durum aynıdır,
  çünkü geçmiş bilinçli olarak `ahbu_latch`'te tutuluyor.
- **FW2-1, Relay_Init'te süzme:** Relay_Init ana yapılandırma yüklenmeden çalışır (TCA latch'i önce kapatılmalı). Ana yapılandırmayı
  orada okumak açılış sırasını değiştirir. Maskeyi tutarlı tutmak aynı güvenceyi verir: doğrulamalı yollar maskedeki röleyi çeviremez,
  güvenli kipte açılış da uyuşmayan biti siler. Ana yapılandırmayı doğrulamasız değiştiren bir yol bilinmiyor. `/api/reset` ana
  yapılandırmayı varsayılana döndürür (röleler lamba) ve güvenlik ad alanını siler; sonraki ilk açılışta maske yeniden hesaplanıp
  boş yazılır. Bu yolda eski bit en çok bir açılışta, Relay_Init ile `SmartAutomation::begin` arasındaki ~1-2 sn boyunca etkili olur.
- **FW2-3, sahada ölçüm:** `free_entries`'in GC sayfasını saydığı SDK başlığından ve bilinen IDF davranışından çıkarıldı. Kartta
  `nvs_get_stats` ile ölçülmedi (donanım yasağı). "İlk kartta denenecekler" listesine eklendi (madde 16).
- **RV2-2, PG günlüğü:** Kilitlenme kayıtları ve sızan satırlar yeniden ölçülmedi. Bu makinede `psql` yok. PG'li sunucu takımı arka
  arkaya üç kez koşuldu; üçünde de hata çıkmadı ve geçici veritabanı kalmadı.

### Bu turun test sonuçları

- Firmware Unity (MSVC): 17 paket, **324 test**, 0 hata, derleme uyarısı 0. Yeni testler: `test_safety_config` +2
  (`test_nvs_budget_excludes_gc_page`, `test_system_change_respects_relay_guard`), `test_safety_cfg_edit` +1
  (`test_loosening_gas_reset_on_used_di`).
- QA simülatörü (`tools/qa_stack`, `npm test`): **546/546**. Unity portları +3; `sim_safety_hooks` +2 (FW2-1 güvenli kip + maske
  temizliği, FW2-2 LAN iki adımlı yol + yeniden başlatma). `fwcheck --update` yapıldı.
- Sunucu `npm test`: PG'siz 2174 testten **2024 geçti**, 150 atlandı, 0 hata. PG'li (`evy_gk_rv`) 2174 testten **2173 geçti**, 1 atlandı
  (`EV_PG_TEST_EXCLUSIVE`), 0 hata; üç koşu. Yeni testler: `safety_payload` +1 (`zones_complete`), `alarm_service` +1 (RV2-1).
- Fabrika aracı: **358/358**; `inspect_firmware_file` yeni imajda uyarısız, FACTORYINIT imzası bulundu.
- Flutter: `analyze` 0 sorun; `test` **4380 geçti**, 485 atlandı, 0 hata (uygulama kodu bu turda değişmedi).
- Firmware derleme: temiz, uyarı 0, RAM %20,6 (67488 B), Flash %39,7 (1247673 B). v1.2.0 ana imaj SHA-256
  `dd39a3ef765ea50213ef8585f4a4f695673ef2f2f6f8e78793bb5eb2f7888374`, uygulama SHA-256
  `165ccc0dc304cb22d574ea06577b5dd670838f26a1a0c8f8569eb7fd1b00df39`. 0x0000-0xFFFF bölgesi v1.1.2 ile bayt bayt aynı.

## Faz 2 tasarımı (2026-10-07)

- Kapsam: plan 2.4 (gaz/duman uçtan uca), 2.5 (kapı/pencere alarm kipi), 2.6 (Flutter bildirim alıcısı) ve buluttan yapılandırma
  yazımı (`sys cfg_patch`). Taban `751f815` (canlı). **Durum: TASARIM; kod yazılmadı.** Uygulama F2.E'deki iş paketleriyle, TDD ile
  (önce kırmızı test) yapılır.
- Değişmez ilkeler: (1) K5: bütün kararlar panoda; bulut yalnız uzaktan erişim, bildirim, geçmiş ve yapılandırma eşitlemesi.
  (2) Mevcut davranış korunur: yeni alanlar yalnız ilgili sensör/eylemci yapılandırılmışsa yazılır; yapılandırılmamış panoda
  `state`, `_want`/`_hw` izleri ve sunucu sorguları bugünkü ile bit bit aynıdır (§2.9 eşdeğerlik testi her pakette yeşil kalır).
  (3) Tehlike katmanı (su/gaz/duman, `SafetyCore`) ile hırsız alarmı katmanı birbirinden ayrıdır; ortak tek kaynak siren ve buzzer'dır.
  (4) Kararlar §7.2b'de verilmiş olanlarla çelişmez; yeni kararlar F2.E.3'te listelenir.

### F2.0 Kodda doğrulanan dayanaklar (bu tasarım için açıldı)

| Olgu | Yer |
|---|---|
| Gaz/duman tepkisi çekirdekte hazır: tür→akışkan vana eşlemesi, duman vana kapatmaz, gaz alarmında ex-proof olmayan fana dokunulmaz, dumanda fan kapatılır | `src/safety/SafetyFsm.h:323-326,530-532,725-734`; `src/sensors/SensorTypes.h:46,102-115` |
| Sensör bayrakları `SF_REACT 0x01`, `SF_TAMPER 0x02`, `SF_FAULT_CLOSE 0x04`; varsayılan gazda `SF_FAULT_CLOSE` | `src/sensors/SensorTypes.h:40-42,113-115` |
| `SensorKind` `DOOR=4, WINDOW=5, MOTION=6` var; bunlara bağlı tepki yok | `src/sensors/SensorTypes.h:31` |
| `CmdType::SAFETY_ARM` var, `safety_arm {mode}` MQTT'de ayrıştırılıyor, `SafetyManager::handleCommand` `unsupported` döndürüyor | `src/DeviceCommand.h:34`, `src/MqttManager.cpp:258-266`, `src/SmartAutomation.cpp:746-756` |
| `Policy` 16 B; `rsv` (2 B) ve `rsv2[8]` boş | `src/safety/SafetyConfig.h:32-39` |
| sys `cfg_patch` firmware'de var (`VIA_CLOUD`, gevşetebilir); başarıda `last_id` YAZILMIYOR, yalnız `triggerPublish`; ret `last_rej` (`cfg_conflict`, `zone_latched`, `cfg_invalid`, diğerleri `busy`) | `src/MqttManager.cpp:1160-1239` |
| `caps` sabit `["safety","actuator","event","cfg"]` | `src/safety/SafetyView.h:188` |
| Sunucu push türleri `peace`, `safety_alarm`, `safety_info`; kanal kimlikleri `safety_alarm`, `safety_info` | `server/src/services/push_service.js:55-65,180-237` |
| Alarm metinleri türe göre; `valve_fault` gövdesi türden bağımsız | `server/src/services/alarm_service.js:130-153,593-594` |
| Yapılandırma kopyası farkında `cfg_get` (cihaz başına dakikada bir) | `server/src/services/alarm_service.js:411,477,504` |
| Bekleyen değişiklik uzlaştırma deseni (yerel anahtar, `publishSys`) | `server/src/services/device_reconciler.js:39,227-244,327,704-794` |
| `device_configs.pending JSONB` kolonu var, kullanılmıyor | `server/migrations/033_safety_alarms.sql:108` |
| `alarms.kind VARCHAR(12)` CHECK'siz; `zone` 1..4 zorunlu; `scheduled_rule_runs.status VARCHAR(24)` CHECK'siz | `033_safety_alarms.sql:44-45,61-65`; `022_scheduled_rules_fix.sql:185` |
| `safety_config` yeteneği SUPER, STAFF, SESSION, OWNER | `server/src/utils/role_matrix.js:61` |
| Uygulama push'u Firebase'siz: `createPushGateway` her zaman `UnsupportedPushGateway`; `pubspec.yaml`'da `firebase_*` yok | `lib/services/push/push_gateway_factory.dart:14`, `push_gateway.dart:84-121` |
| `PushCoordinator` yalnız `PeaceNotice` üretir (`_handleMessage`), tanınmayan mesajı sessizce atar | `lib/services/push/push_coordinator.dart:581-600` |
| Android'de bildirim kanalı oluşturan kod yok (`peace_reminder` dahil); `POST_NOTIFICATIONS` izni manifestte yok | `android/app/src/main/kotlin/.../MainActivity.kt`, `AndroidManifest.xml:4-8` |
| Kritik alarm kartı anahtarı `card_critical_alarm_<uid>_<bölge>` (pano `uid`'si, DB kimliği değil) | `lib/ui/widgets/critical_alarm_card.dart:31,235` |

---

### F2.A Gaz ve duman uçtan uca (plan 2.4)

#### A.1 Bugünkü durum ve eksikler

Firmware çekirdeği gaz/duman tepkisini zaten uygular (F2.0). Sunucu `alarm_raised` olayını türden bağımsız işler ve push başlığını
türe göre seçer. Uygulamada kart türe göre vana satırı süzer. Uçtan uca eksikler şunlardır:

1. Sihirbazda dedektör bağlantı yönergesi eksik (arıza rölesi, besleme, sertifika notu); gaz bölgesi testinin vanayı kapalı bıraktığı
   test öncesi söylenmiyor.
2. `valve_fault` push gövdesi türden bağımsız ("Ana vanayı elle kapatın"); gaz için 187 yönlendirmesi yok.
3. Gaz alarmı sürerken bulut zamanlayıcısı ve gece "Hepsini kapat" akışı röle anahtarlamaya devam ediyor (kıvılcım kaynağı).
4. Uygulamada gaz/duman kartında davranış talimatı (havalandır, anahtarlara dokunma, dışarı çık, 112/187) yok; duman kartında
   "pano su vanasını kapatmaz" açıklaması yok.
5. QA simülatöründe gaz/duman uçtan uca senaryosu yok (Unity çekirdek testleri var).

#### A.2 Davranış tablosu (tek doğru kaynak; firmware zaten böyle, değişmez)

| | Gaz (`kind=gas`) | Duman (`kind=smoke`) |
|---|---|---|
| Algılama | Sertifikalı dedektör (TS EN 50194-1 doğalgaz/LPG); pano yalnız kuru kontağına bakar (K3). Eşik/kalibrasyon kodu YOK | Sertifikalı dedektör (TS EN 14604 ya da EN 54); aynı |
| Bağlantı | NC zorunlu (`active_open=1`) [O-2]; onay 300 ms / pencere 1 sn | Aynı |
| Vana | Bölgedeki `medium=GAS` vanalar KAPANIR; su vanasına dokunulmaz | **Hiçbir vana kapanmaz** (yangın suyu) |
| Siren | Bölge sirenleri `run_limit_s` (vars. 180 sn) | Aynı |
| Fan | Yalnız `exproof` işaretliyse AÇILIR; değilse dokunulmaz (açma da kapatma da yok: anahtarlama kıvılcımı) [Y-1] | Bölge fanları zorla KAPATILIR (duman yayılmasın) |
| Kart buzzer'ı | Alarm kipi (ACK susturur) | Aynı |
| Arıza (`ok=false`) | `SF_FAULT_CLOSE` varsayılan 1: arıza vana kapatmayı tetikler (açılışta 30 sn tolerans, dalga 1 not 8) | 0: yalnız `sensor_fault` olayı |
| Vana açma | Yalnız yerinde: `GAS_RESET` DI'si ya da elle kurmalı vana (K-4, 7.2b-8). Uzak yollar `gas_local_only` | — |
| Test | Gaz vanası test sonunda KAPALI kalır | Siren 3 sn, vana yok |
| Açılış | Gaz vanası her açılışta kapalı | — |

#### A.3 Dedektör bağlantısı ve sihirbaz metinleri (APP, `step_7_safety.dart`)

Girişler sekmesinde rol "Gaz dedektörü çıkışı" ya da "Duman dedektörü çıkışı" seçilince açılan bilgi kutusu (Türkçe arayüz dizgesi):

> **Dedektör bağlantısı.** Pano gaz ya da dumanı kendisi ölçmez; yalnız sertifikalı dedektörün röle çıkışına tepki verir.
> 1. Dedektörün **alarm rölesini NC (normalde kapalı)** uçtan bağlayın. Kablo koparsa ya da dedektörün enerjisi kesilirse pano bunu alarm sayar.
> 2. Dedektörde ayrı bir **arıza rölesi** varsa onu da alarm kontağıyla **seri** bağlayın; dedektör arızası da alarm olarak görünür.
> 3. Dedektörü panodan değil, kendi besleme kaynağından (tercihen yedekli) besleyin; dedektör panodan bağımsız da ses vermelidir.
> 4. Dedektörün montaj yeri ve bakım süresi için üreticinin kılavuzuna uyun.

Gaz vanası seçilen rölede mevcut not korunur ("yalnız yerinde açılır") ve şu eklenir: **"Önerilen: elle kurmalı (manuel reset) gaz
vanası. Panodaki 'Gaz vanası açma düğmesi' isteğe bağlıdır."** (7.2b-8).

Bölge testi düğmesine basınca, bölgede gaz vanası varsa onay diyaloğu (`showSimpleConfirm`):

> **Test gaz vanasını kapatır.** Test bittiğinde gaz vanası kapalı kalır; yeniden açmak için vananın yanındaki düğmeyi ya da vananın
> kendi kurma kolunu kullanmanız gerekir. Devam edilsin mi?

#### A.4 Gaz alarmında anahtarlama kısıtı (SRV + APP)

Gerekçe: gaz kaçağında elektrik anahtarlamak tutuşma kaynağıdır (alarm push metni de "elektrik anahtarlarına dokunmayın" diyor).
Pano rölesi elektrik panosundadır, ama lamba ve priz devresinin yükünü anahtarlamak yine kıvılcım üretebilir. Kural yalnız **otomatik**
anahtarlamayı durdurur; kullanıcının bilinçli komutu engellenmez (yalnız uyarılır), çünkü karanlıkta tahliye için ışık gerekebilir.

- **Sunucu zamanlayıcısı** (`scheduler.js` `_dispatch`): kuralın evinde `alarms` tablosunda açık (`status IN ('latched','fault','silenced')`)
  ve `kind='gas'` satırı varsa röle/panjur kuralı yayınlanmaz; çalıştırma kaydı `status='skipped_hazard'`, `detail='gas_alarm'`.
  Sorgu ev başına tek `EXISTS`; `alarms_home_open_idx` kullanılır. Gaz alarmı yoksa sorgu sonucu yanlış, davranış bugünkü gibi.
- **Gece hatırlatması:** `peace_service` gaz alarmı açık evde push'u göndermez (`skipped`, neden `gas_alarm`) ve `POST …/close-all`
  `409 HAZARD_ACTIVE` döner. Gaz alarmında "lambaları kapat" önerisi tehlikelidir.
- **Uygulama:** gaz alarmı açıkken lamba/priz/panjur komutu ilk dokunuşta onay ister (`showSimpleConfirm`):
  "**Gaz alarmı sürüyor.** Elektrik anahtarlamak kıvılcım oluşturabilir. Yine de uygulansın mı?" Onaylanırsa komut normal hattan gider.
  Hızlı senaryolar ("İyi Geceler", "Evden Çıkıyorum", "Tüm Lambalar") gaz alarmında aynı onayı ister.
- **Firmware:** değişiklik yok (yerel duvar butonu fiziksel kullanıcı eylemidir; senaryo motoru henüz panoda yok, 5.2 geldiğinde
  `CmdSource::RULE` röle yazımı gaz kilidi sürerken atlanır; bu kural o pakete not olarak eklenir).

#### A.5 Sunucu metinleri (push, `alarm_service.js`)

| Durum | Başlık | Gövde |
|---|---|---|
| Gaz alarmı | Gaz kaçağı alarmı | Gaz kaçağı algılandı (bölge N). Gaz vanası kapatıldı. Ortamı havalandırın, elektrik anahtarlarına dokunmayın; gerekirse 187'yi arayın. |
| Duman alarmı | Duman alarmı | Duman algılandı (bölge N). Evde biri varsa hemen dışarı çıkın ve 112'yi arayın. Pano su vanasını kapatmaz. |
| Su alarmı | Su baskını alarmı | (bugünkü metin aynen) |
| Vana arızası, su | Vana kapanmadı! | Su vanası kapanmadı! Ana su vanasını elle kapatın ve panoyu kontrol edin. |
| Vana arızası, gaz | Gaz vanası kapanmadı! | Gaz vanası kapanmadı! Sayaçtaki ana gaz vanasını elle kapatın, ortamı havalandırın ve 187'yi arayın. |

`faultBody(kind)` türe göre seçer; bilinmeyen tür bugünkü genel metni alır. Push `data` alanlarında değişiklik yalnız F2.C.8'dedir.

#### A.6 Uygulama metinleri (`critical_alarm_card.dart`, `safety_labels.dart`)

Kartın başlığının altına türe göre **talimat satırı** (ikonlu, `liveRegion` başlıktan sonra okunur):

- Gaz: "Ortamı havalandırın. Elektrik anahtarlarına ve prizlere dokunmayın, ateş yakmayın. Kokuyu hâlâ alıyorsanız evden çıkın ve 187'yi arayın."
- Duman: "Evde biri varsa hemen dışarı çıkın ve 112'yi arayın. Pano su vanasını kapatmaz; havalandırma fanları durduruldu."
- Gaz vanası satırında "Vanayı Aç" düğmesi hiç çizilmez (bugün de çizilmiyor); yerine kalıcı açıklama:
  "Gaz vanası güvenlik gereği yalnız yerinde açılır: vananın yanındaki düğme ya da vananın kurma kolu."
- Gaz alarmında fan satırı: ex-proof olmayan fan "Fan güvenlik gereği çalıştırılmıyor (gaz)"; ex-proof fan "Havalandırma çalışıyor".

Telefon araması (`tel:`) için `url_launcher` yok; numara yalnız metindir (yeni bağımlılık eklenmez).

#### A.7 Sözleşme değişiklikleri (alan alan)

| Yer | Alan / değer | Değişiklik |
|---|---|---|
| CONTRACTS §1.5d | `POST …/close-all` | Yeni hata `409 HAZARD_ACTIVE` (evde açık gaz alarmı) |
| CONTRACTS §2.4b / §1.5 zamanlayıcı | `scheduled_rule_runs.status` | Yeni değer `skipped_hazard` (`detail='gas_alarm'`); şema değişmez (VARCHAR(24), CHECK yok) |
| CONTRACTS §2.5 güvenlik push'u | `notification.body` | A.5 metinleri (alan değil, metin) |
| `state`, `cmd`, `event`, LAN | — | **değişiklik yok** (çekirdek davranışı zaten sözleşmede) |

#### A.8 İş paketleri ve dosya sahipliği

| Paket | İçerik | Dosyalar |
|---|---|---|
| **WP-G1 (SRV)** | `faultBody(kind)`, A.5 metinleri; zamanlayıcı `skipped_hazard`; gece hatırlatması gaz kısıtı ve `409 HAZARD_ACTIVE` | `server/src/services/alarm_service.js`, `server/src/scheduler.js`, `server/src/services/peace_service.js`, `server/src/routes/device_routes.js` (yalnız close-all hata eşlemesi) |
| **WP-G2 (APP)** | A.3 sihirbaz metinleri ve test onayı; A.4 anahtarlama onayı; A.6 kart talimatları; `HAZARD_ACTIVE` Türkçe metni | `lib/ui/pages/service_setup/steps/step_7_safety.dart`, `lib/ui/widgets/critical_alarm_card.dart`, `lib/ui/widgets/safety_labels.dart`, `lib/services/automation_state.dart` (yalnız `hasOpenGasAlarm` getter'ı ve onay kancası), `lib/ui/dashboard/*` (onay çağrısı) |
| **WP-G3 (QA)** | Gaz/duman uçtan uca sim senaryoları (A.9) | `tools/qa_stack/test/sim_safety_gas.test.js` (yeni) |

Firmware'e dokunulmaz. G1, G2, G3 birbirinden bağımsızdır.

#### A.9 Test planı

- **QA (`sim_safety_gas.test.js`):** (1) gaz sensörü → gaz vanası kapalı, su vanası açık kalır, siren çalar, `alarm_raised kind=gas`;
  (2) ex-proof olmayan fan gaz alarmında dokunulmadan kalır, ex-proof fan açılır, kullanıcının ex-proof olmayan fanı açma isteği
  `zone_latched`; (3) duman → hiçbir vana kapanmaz, fan kapatılır; (4) gaz kuruyup ACK sonrası gaz vanası kapalı kalır, MQTT ve LAN
  `open` → `gas_local_only`, `GAS_RESET` DI'si ile açılır; `GAS_RESET` sensör hâlâ aktifken açmaz; (5) kilitliyken `reboot` ve
  kilitsizken `reboot` → gaz vanası kapalı; (6) gaz ek modülü yanıt vermiyor → 30 sn sonra vana kapanır (`SF_FAULT_CLOSE`);
  (7) su alarmı sürerken gaz → yeni `aid`, `kind=gas` (E2E-2). Kırmızı kanıtı: senaryolar önce gaz kuralı mutasyonuyla (ör. dumanda
  vana kapatma) kırmızıya döndürülüp doğrulanır.
- **Sunucu:** `alarm_service` metin testleri (gaz/duman/su, `valve_fault` gaz ve su); `scheduler_tick` gaz alarmlı evde
  `skipped_hazard`, alarmsız evde bugünkü sonuç (sorgu sayısı dahil); `peace_service` gaz alarmında push yok + `close-all` 409; PG'li
  testte `EXISTS` sorgusu.
- **Flutter:** kart talimat satırları (gaz/duman), gaz vanasında "Aç" yokluğu, fan satırı metinleri; gaz alarmında lamba komutu onay
  diyaloğu (iptal → komut gitmez, onay → gider); sihirbaz test onay diyaloğu yalnız gaz vanalı bölgede; `HAZARD_ACTIVE` metni.

---

### F2.B Kapı/pencere alarm kipi (plan 2.5)

#### B.1 Kavramlar

- **Kip** (`mode`): `off` (çözülü), `home` (evde kurulu: yalnız çevre), `away` (dışarıda kurulu: hepsi). Kip pano başınadır; evde
  birden çok pano varsa uygulama "evin kipi"ni panoların kiplerinden gösterir (hepsi aynıysa o, değilse "karışık").
- **Durum** (`st`): `idle` (kip `off` ise çözülü bekleme; kurulu kipte bekçi), `exit` (çıkış gecikmesi), `entry` (giriş gecikmesi),
  `alarm`.
- **Sensör sınıfı** (mevcut `SensorConfig.flags`'e iki bit eklenir; `kind` `door|window|motion`, `SF_REACT` alarm sistemine dahil demektir):
  - `SF_ENTRY = 0x08` giriş yolu: tetiklenince önce giriş gecikmesi başlar (varsayılan: kapı 1, pencere 0, hareket 0).
  - `SF_AWAY_ONLY = 0x10` yalnız `away` kipinde etkin (varsayılan: hareket 1, kapı/pencere 0). `home` kipinde etkin sensörler çevredir.
  - Diğerleri **anlık**: etkin kipte tetiklenince hemen alarm.
- **Gecikmeler** (`Policy.rsv2`'nin ilk 2 baytı; yeni NVS girdisi yok): `exit_s` (vars. 45, 0..255), `entry_s` (vars. 30, 0..255).
  0 değeri "varsayılan" demektir; gecikmesiz istenirse 255 yerine ayrı bayrak kullanılmaz, en küçük değer 1 sn'dir (sözleşme: 1..255,
  0 = varsayılan).
- **Kalıcılık:** kip ve alarm belleği `ahbu_latch/arm` blob'u (20 B: `mode u8`, `alarm u8`, `aid[15]`, CRC yok, sürüm baytı 1).
  Yalnız kip değişiminde ve alarm geçişinde yazılır. Fabrika sıfırlaması silmez (kilit ilkesiyle aynı: kurulu ev sıfırlamayla çözülmez).
  NVS bütçesine +1 girdi (dalga 1 F0: en kötü %105,6 → %105,8; NVS bütçe kararı açık ve bu kalemle değişmez).

#### B.2 Saf çekirdek `safety/IntrusionFsm.h` (SAF, `now_ms` parametreli)

Girdi her turda: `armedMask(mode)` içindeki sensörlerin onaylı aktifliği ve `ok` bitleri (SensorHub'dan), komut (`ARM home|away`,
`DISARM`), saat. Çıktı: `IntrusionActions {sirenOn, sirenOff, buzzerPattern, events[]}`.

| Geçiş | Koşul | Eylem | Olay |
|---|---|---|---|
| off → (home/away, `exit`) | `ARM m` ve **hazır**: `m` kipinde etkin, giriş yolu OLMAYAN her sensör `ok && !active` | `until = now + exit_s`; buzzer çıkış bip'i (1 sn'de bir) | `arm_changed {mode, via}` |
| off → off | `ARM m` hazır değil | — (ret `not_ready`) | — |
| `exit` → `idle` | süre doldu ve giriş yolu sensörleri kapalı | buzzer susar | — |
| `exit` → `entry` | süre doldu ama giriş yolu sensörü hâlâ açık ("çıkış hatası") | `until = now + entry_s` | — |
| `exit` → `alarm` | anlık sensör aktif | sirenler + buzzer alarm | `intrusion_alarm` |
| `idle` → `entry` | giriş yolu sensörü aktif | buzzer giriş bip'i (hızlı) | — |
| `idle`/`entry` → `alarm` | anlık sensör aktif ya da giriş süresi doldu | sirenler + buzzer alarm | `intrusion_alarm` (`aid` = eid, `srcs`) |
| `alarm` → `alarm` | yeni sensör aktif | `srcs`'e eklenir; siren durmuşsa ve sensörün bu kurulumdaki tetik sayısı < 3 ise siren yeniden `run_limit_s` | — |
| herhangi → off | `DISARM` | sirenlerin hırsız isteği kalkar, buzzer susar, alarm belleği silinir | `arm_changed {mode:"off"}`; `alarm` idiyse ayrıca `intrusion_cleared {aid, via}` |
| kurulu `idle` → aynı | `ARM` farklı kip | yeni kip için `exit` (hazırlık denetimi yeni kipe göre) | `arm_changed` |

- **Swinger sınırı:** sensör başına kurulum dönemi boyunca en çok 3 alarm tetiği (EN 50131-1 yaklaşımı); sonra o sensör yalnız
  `srcs`'e eklenir, sireni yeniden başlatmaz.
- **`ok=false` sensör kurulu kipte** alarm üretmez (NC kontak kopması zaten "açık" = aktif okunur); `sensor_fault` olayı mevcut yoldan
  gelir. Hazırlık denetiminde `ok=false` sensör "hazır değil" sayılır.
- **Gecikme sayaçları** `(uint32_t)(now - start) >= span` kuralıyla, `millis` taşmasına dayanıklı.

#### B.3 Açılış, buluttan bağımsızlık ve yerel yollar (K5)

- **Açılış:** `ahbu_latch/arm` okunur; kip geri yüklenir, `st=idle`, çıkış gecikmesi YOK. Sensörler ilk okuma turuna kadar `ok=false`
  olduğundan sahte alarm olmaz. Alarm belleği varsa `st=alarm` ve aynı `aid` ile açılır, siren **çalmaz** (bütçe tükenmiş sayılır);
  kullanıcı çözene kadar state'te alarm görünür (sunucu uzlaştırması tutarlı kalır).
- **Güvenli kip** (`cfg_corrupt`/`latch_orphan`): sensör tablosu kullanılamaz; kip korunur, `arm.ok=false` yazılır, alarm üretilmez.
  `crash_loop`'ta tablo kullanılabilir olduğundan hırsız katmanı çalışır.
- **Yerel yollar:** (1) LAN `POST /api/arm` (yerel anahtar, resident düzeyi); (2) seri CLI `ARM AWAY|HOME|OFF`; (3) yeni DI rolü
  `ARM_KEY = 19` (`kind:"arm_key"`): **anahtarlı kontak** içindir; pasif→aktif kenarı `away` kurar (hazır değilse kurulmaz, buzzer 3
  kısa hata bip'i), aktif→pasif kenarı çözer. Sıradan bir duvar butonu bu role atanmamalıdır (sihirbaz uyarısı:
  "Bu giriş alarmı çözer. Yalnız anahtarlı ya da korumalı bir kontak bağlayın.").
- **`ARM_KEY` gevşetme kuralı (EM-6/FW2-2 ile aynı mantık):** LAN'dan daha önce herhangi bir satırda kullanılmış bir DI'ye (`di_hist`)
  yeni `arm_key` eklemek ya da mevcut satırı `arm_key`'e çevirmek gevşetmedir (`403 local_loosen_forbidden`); aksi halde kapı kontağı
  girişi "çözme anahtarı" yapılabilirdi. Hiç kullanılmamış girişe yeni `arm_key` serbesttir.
- **Diğer hırsız ayarları LAN'dan serbesttir** (kapı/pencere/hareket sensörü ekleme/silme, `SF_ENTRY`/`SF_AWAY_ONLY`, gecikmeler):
  yerel anahtar sahibi zaten çözebilir; ek bir yetki yükseltmesi yoktur (dalga 2 not 15 ile uyumlu).

#### B.4 Tehlike katmanıyla ilişki

- Hırsız alarmı **vana sürmez**, bölge kilidi (`zones[]`) üretmez, vana açma iznini etkilemez; `policy:off` hırsız katmanını kapatmaz
  (politika yalnız tehlike tepkisidir).
- **Siren paylaşımı:** siren rölesi iki istek kaynağının VEYA'sıdır: `hazardReq` (SafetyCore, mevcut) ve `intrusionReq` (yeni). Her
  kaynak kendi `run_limit_s` bütçesini tutar. Tehlike ACK'i yalnız `hazardReq`'i, çözme yalnız `intrusionReq`'i kaldırır. Kullanıcının
  sireni `off` yapması (eylemci komutu) iki isteği de o alarm dönemi için bastırır (dalga 1 not 14 ile aynı). Hırsız alarmı tüm
  pano sirenlerini sürer (bölge eşlemesi yok; hırsız alarmı ev genelidir). Gaz kilidi sürerken siren zaten açıktır; ek anahtarlama yok.
- **Buzzer önceliği:** tehlike alarmı > hırsız alarmı > giriş bip'i > çıkış bip'i. `Buzzer_SetAlarm(bool)` yanına
  `Buzzer_SetPattern(OFF|EXIT|ENTRY|ALARM)` gelir; tehlike alarm kipi açıkken desen yok sayılır.
- **ValveGuard etkilenmez** (siren tutulmaz, dalga 2 not 1).

#### B.5 Kontak sinyali iklim ve senaryolara olay olarak (`sensors/ContactBus.h`, SAF)

- SensorHub, `door`/`window` sensörlerinin onaylı seviye değişiminde (`confirm_ms` kapı/pencere vars. 0, DiGate 60 ms süzgeci)
  sabit boyutlu halkaya `ContactEdge {slot, kind, zone, open, at_ms}` yazar (16 yuva; taşmada en eski atılır, seviye zaten state'te).
- Tüketiciler aynı loopTask turunda halkayı okur, kendi okuma imleçleriyle (çok tüketicili, kilitsiz: tek yazıcı ve okuyucular aynı görevde):
  1. `IntrusionCore` (bu paket).
  2. `ClimateCore` (plan 3.2, ileride): pencere `window_hold_s` (vars. 60) kesintisiz açıksa o bölgede ısıtma durur; kapanınca devam.
     Bu tasarım yalnız arabirimi sabitler: `bool zoneWindowOpenFor(zone, now, hold_ms)`.
  3. `SceneEngine` (plan 5.2, ileride): tetik türü `contact {sensor|zone, kind, edge: open|close}`.
- Kontak değişimi **olay kutusuna (outbox) yazılmaz** (16 yuvalık tampon kapı aç/kapa ile dolmasın); bulut ve uygulama seviyeyi
  `state.sensors[].active`'ten okur. Yayın tetiği mevcut görünüm imzasıyla zaten değişir.

#### B.6 Yetkiler

| Yol | Kurma / çözme | Not |
|---|---|---|
| Bulut, owner | evet | |
| Bulut, resident | evet | |
| Bulut, guest | **hayır** | `403`; arayüzde kip yalnız okunur |
| Bulut, super / staff / service_session | **hayır** | Gizlilik ve hırsızlık riski: servis personeli bir evin hırsız alarmını uzaktan çözememeli. Kurulumda test LAN (yerel anahtar) ya da CLI ile yapılır |
| LAN (yerel anahtar) | evet | Yerel anahtar resident düzeyindedir (`role_matrix.js:44`) |
| Seri CLI, `ARM_KEY` DI'si | evet | Fiziksel erişim |

Rol matrisi: yeni yetenek `safety_arm` = `[OWNER, RESIDENT]`. CONTRACTS §1.4 tablosuna satır eklenir.

#### B.7 Sözleşme değişiklikleri (alan alan)

| Yer | Alan | Tür / sınır | Anlam |
|---|---|---|---|
| `state.caps` | `"intrusion"` | dizge | yalnız firmware hırsız katmanını destekliyorsa (v1.3.0+). Sunucu ve uygulama kurma komutunu yalnız bu yetenekle gönderir |
| `state.safety.arm` | nesne | yalnız `SF_REACT`'li en az bir `door|window|motion` sensörü varsa yazılır | |
| `arm.mode` | `"off"\|"home"\|"away"` | | kip |
| `arm.st` | `"idle"\|"exit"\|"entry"\|"alarm"` | | durum |
| `arm.ok` | bool | | `false`: güvenli kipte sensör tablosu yok; hırsız katmanı etkisiz |
| `arm.until_up` | u32 | yalnız `exit`/`entry` | gecikmenin bittiği `uptime` saniyesi (sabit değer: görünüm imzasını her saniye değiştirmez). İstemci kalan süreyi `until_up - uptime` ile hesaplar |
| `arm.aid` | ≤ 14 | yalnız `alarm` | `intrusion_alarm` olayının eid'si |
| `arm.srcs` | dizge dizisi ≤ 8 | yalnız `alarm` | tetikleyen sensör kimlikleri |
| `last_rej.code` | yeni `not_ready` | | kurma reddi: hazır olmayan sensör var |
| `cmd` | `{"cmd":"safety_arm","mode":"away"\|"home"\|"off","uid","id"?}` | mevcut ayrıştırıcı aynen | `uid` zorunlu (zaten); `off` = çözme |
| `ev/{t}/event` | `intrusion_alarm` | `zone` (ilk tetikleyen sensörün bölgesi), `kind:"intrusion"`, `srcs`, `at?`, `at_up`; `aid` yazılmaz (alarm kimliği olayın eid'si) | taşmada ATILMAZ (alarm sınıfı) |
| | `intrusion_cleared` | `aid`, `via` (`cloud\|lan\|cli\|di`) | `*_cleared` sınıfı |
| | `arm_changed` | `mode`, `via` (`cloud\|lan\|cli\|di\|boot`) | en düşük öncelik (`actuator_changed` sınıfı) |
| LAN | `POST /api/arm {mode, uid?, id?}` | `KEYED` | yanıt `{ok,id,rej?}`, 1 sn bekleme, `504 timeout`; bilinmeyen alan `400 unknown_field`, geçersiz `400 invalid_value`. Rota tablosu 32 → 33 |
| LAN | `GET /api/status` | | `safety.arm` aynı biçimde |
| cfg (`cfg_dump`, `GET /api/safety/config`, yama) | `"intrusion":{"exit_s","entry_s"}` | 1..255, 0 = varsayılan | 1. parçada; yama `set:{intrusion:{…}}` |
| cfg sensör öğesi | `flags` | bit3 `entry`, bit4 `away_only` | mevcut alan; v1.2.0 `0x07`'den büyük değeri `bad_value` ile reddeder (`SafetyCfgApi.cpp:101-103`), bu yüzden sunucu ve sihirbaz bu bitleri yalnız `caps` `intrusion` varken yazar; 1.3.0 sınırı `0x1F` olur |
| cfg sensör `kind` | `"arm_key"` | yerel kumanda rolü | state `sensors[]`'te `active` = ham seviye; tehlike sensörü değil |
| CLI | `ARM [STATUS]`, `ARM AWAY\|HOME\|OFF` | | |
| REST | `POST /homes/:homeId/devices/:deviceId/arm {mode, id?}` | `safety_arm` | panoya `safety_arm`; yanıt güvenlik komutlarıyla aynı (`expectOutcome`): `{delivered, applied: true\|null, command_id}`; `last_rej` → `409 DEVICE_REJECTED reason:not_ready\|unsupported`; `caps` `intrusion` yok → `409 FIRMWARE_UNSUPPORTED`; çevrimdışı → `409 DEVICE_OFFLINE` (**kuyruğa alınmaz**) |
| REST | `GET /homes/:homeId/alarms` | | `kind:"intrusion"` satırları da listelenir |
| REST | `POST …/alarms/:id/ack` | | `kind='intrusion'` satırına `409 ALARM_USE_DISARM` |
| `devices.safety_state` | `arm` | `{mode, st, ok, aid?, srcs?}` | `parseStateSafety` sınırlarıyla (`srcs ≤ 8`); `until_up` saklanmaz |
| Push `safety_alarm` | `kind:"intrusion"`, `status:"latched"` | | başlık "Hırsız alarmı", gövde "Ev alarmı tetiklendi (bölge N). Uygulamadan durumu kontrol edin; tehlikedeyseniz 112'yi arayın." Alıcılar owner + resident (mevcut kural) |

Sürüm: firmware **1.3.0** (yeni yetenek). Sunucu ve uygulama `caps` yoksa bugünkü gibi davranır.

#### B.8 Sunucu akışları

- `validateEventPayload`: üç yeni tür (katı alan listesi). `alarm_service`:
  - `intrusion_alarm` → `alarms` `INSERT … kind='intrusion', zone=<olay zone>, aid=<eid>, status='latched'` + `safety_alarm` push (en çok bir).
  - `intrusion_cleared` → satır `cleared`, `cleared_by='device_event'`; bilinmeyen `aid` → mezar taşı (mevcut desen).
  - `arm_changed` → yalnız `device_audit_logs` (`event='safety_arm_changed'`, `mode`, `via`); push yok.
- **Uzlaştırma ayrımı (kritik):** mevcut bölge uzlaştırması (`onLiveState`, `alarm_service.js:414-470`) `kind='intrusion'` satırlarını
  **atlar**; aksi halde `zones[]`'ta olmayan bölge "normal" sayılıp hırsız alarmı kapatılırdı. Hırsız satırı ayrı kuralla uzlaştırılır:
  `arm.st='alarm'` ve `arm.aid` açık satırı yoksa satır açılır (`origin='state'`); açık satır var ve `arm` mevcut, `arm.ok=true`,
  (`st≠alarm` ya da `aid` farklı) → `cleared` (`device_state`); `safety`/`caps` yok ya da `arm.ok=false` → `lost` (mevcut bilgi push'u).
  `arm` anahtarı yoksa ve `caps` `intrusion` içeriyorsa (hırsız sensörü kalmamış) açık satır `lost`.
- `command_schema`: `safety_arm` türü (`mode ∈ away|home|off`, `uid` zorunlu, `id`); `capabilityForCommand` → `safety_arm`.
- `_assertCommandTarget`: `caps` `intrusion` yoksa `409 FIRMWARE_UNSUPPORTED`.
- Uygulamanın açık alarm listesinden onay araması `kind='intrusion'` satırını kullanmaz (F2.B.9).

#### B.9 Uygulama

- Model: `SafetyState.arm` (`ArmState {mode, st, ok, untilUp, aid, srcs}`; bilinmeyen değer `unknown`, fırlatmaz; eşitlik dahil).
  `SafetyState.supportsIntrusion` (`caps`). `DeviceStatus.uptime` zaten okunuyor; kalan süre `untilUp - uptime`, sonra yerel geri sayım.
- Komut: `AutomationState.setArmMode(deviceUid, mode)`; anahtar `arm:<uid>`; iyimser DEĞİL (çözme dahil; onaya kadar "Uygulanıyor…").
  Bulutta REST, LAN'da `POST /api/arm`. Ön denetim (`armBlockReason`): kurulacak kipte etkin, giriş yolu olmayan açık ya da `ok=false`
  sensör varsa ağa çıkmadan ret ve liste: "Kurulamaz: Salon penceresi açık." Panonun `not_ready` reddi aynı metne çevrilir.
- Arayüz:
  - `AlarmModeTile` (pano bölümünde, "Güvenlik ve Eylemciler" bölümünün başı): üç seçenekli seçici "Kapalı / Evde / Dışarıda";
    çözme ve kurma onay diyaloğuyla. Çıkış gecikmesinde "Çıkış için 38 sn" geri sayımı. Misafirde seçici çizilmez, yalnız kip metni.
  - `SafetyAlertsPanel`'e `IntrusionAlarmCard` (kritik kartlarla aynı yer, tehlike kartlarından SONRA): başlık "Hırsız alarmı",
    tetikleyen sensör adları, "**[Alarmı Çöz]**" (owner/resident). Giriş gecikmesinde bilgi kartı: "Giriş gecikmesi: 23 sn içinde alarmı çözün."
  - Alarm geçmişinde tür adı "Hırsız alarmı" (`safety_labels.dart`).
  - Açık alarm listesinden `alarm_ack` için kayıt aranırken `kind=='intrusion'` satırlar atlanır.
  - Hızlı senaryo "Evden Çıkıyorum" (`caps` `intrusion` ve yetki varsa) son adımda "Alarmı dışarıda kip ile kurayım mı?" onayı sorar;
    hayır seçilirse bugünkü davranış aynen.
  - Sihirbaz Girişler sekmesi: kapı/pencere/hareket için "Giriş yolu (gecikmeli)" ve "Yalnız dışarıda kipte" anahtarları
    (varsayılanlar B.1); `arm_key` rolü ve uyarı metni (B.3); "Çıkış gecikmesi" / "Giriş gecikmesi" alanları (sn).
- Ret metinleri: `not_ready` "Alarm kurulamadı: açık kapı ya da pencere var."; `ALARM_USE_DISARM` "Hırsız alarmı onaylanmaz, çözülür.";
  `FIRMWARE_UNSUPPORTED` (kurma) "Bu pano yazılımı alarm kipini desteklemiyor; v1.3.0'a güncelleyin."

#### B.10 İş paketleri ve dosya sahipliği

| Paket | İçerik | Dosyalar | Bağımlılık |
|---|---|---|---|
| **WP-I1 (FW, saf)** | `IntrusionFsm.h`, `ContactBus.h`, `SensorTypes.h` bitleri ve `ARM_KEY`, `SafetyCfgEdit.h` (`arm_key` gevşetmesi), `SafetyConfig.h` (`Policy.rsv2` gecikmeleri, validate), Unity testleri + sim portları + `fwcheck --update` | `src/safety/IntrusionFsm.h`, `src/sensors/ContactBus.h`, `src/sensors/SensorTypes.h`, `src/safety/SafetyCfgEdit.h`, `src/safety/SafetyConfig.h`, `test/test_intrusion_fsm/`, `test/test_contact_bus/`, `tools/qa_stack/sim/fw/{intrusion_fsm,contact_bus}.js`, `SOURCES.json` | — |
| **WP-I2 (FW, bağ)** | `SafetyManager` (tick, komut, siren VEYA'sı, buzzer deseni, `ahbu_latch/arm`), `SafetyStore`, `SafetyView` (`arm`, `caps`), `EventOutbox` (3 tür + öncelik), `SafetyCfgApi`/`SafetyCfgJson` (`intrusion` öğesi, bayraklar), `WS_GPIO` (`Buzzer_SetPattern`), `WebPortal` (`/api/arm`), `main.cpp` (CLI `ARM`), sürüm 1.3.0; sim portları | `src/safety/SafetyManager.*`, `src/safety/SafetyStore.*`, `src/safety/SafetyView.h`, `src/events/EventOutbox.h`, `src/safety/SafetyCfgApi.cpp`, `src/safety/SafetyCfgJson.h`, `src/WS_GPIO.*`, `src/WebPortal.cpp`, `src/main.cpp` (yalnız CLI), `src/WiFiManager.h` (sürüm), `tools/qa_stack/sim/**` karşılıkları | I1 |
| **WP-I3 (QA)** | Uçtan uca hırsız senaryoları (B.11) | `tools/qa_stack/test/sim_intrusion.test.js`, `sim/device_sim.js` (`setContact`) | I2 |
| **WP-I4 (SRV)** | Olay türleri, alarm servisi (ayrı uzlaştırma), şema/rol/rota, push metni | `server/src/mqtt_bridge.js` (yalnız `validateEventPayload`), `server/src/services/alarm_service.js`, `server/src/utils/safety_payload.js`, `server/src/utils/command_schema.js`, `server/src/utils/role_matrix.js`, `server/src/services/safety_service.js`, `server/src/routes/safety_routes.js`, `server/src/services/device_service.js` (yalnız `_assertCommandTarget`) | sözleşme (B.7) |
| **WP-I5 (APP, model+durum)** | `ArmState`, ayrıştırma, komut, ön denetim, ret metinleri, yetenek `canArm` | `lib/models/safety_models.dart`, `lib/models/capabilities.dart`, `lib/services/automation_state.dart`, `lib/services/automation_api_service.dart`, `lib/services/ev_cloud_api_service.dart`, `lib/services/command_pipeline.dart` | sözleşme |
| **WP-I6 (APP, arayüz)** | `AlarmModeTile`, `IntrusionAlarmCard`, senaryo onayı, sihirbaz anahtarları | `lib/ui/widgets/alarm_mode_tile.dart` (yeni), `lib/ui/widgets/critical_alarm_card.dart`, `lib/ui/widgets/safety_labels.dart`, `lib/ui/dashboard/endpoint_sections.dart`, `lib/ui/dashboard/apartment_dashboard.dart`, `lib/ui/pages/service_setup/steps/step_7_safety.dart`, `.../logic/safety_assignment.dart` | I5 |

`WP-G2` ile `WP-I6` aynı iki dosyaya (`critical_alarm_card.dart`, `step_7_safety.dart`) dokunur: sırayla birleştirilir (G2 → I6).

#### B.11 Test planı

- **Unity (`test_intrusion_fsm`)**: hazır olmayan kurma `not_ready`; giriş yolu açıkken kurma kabul + çıkış hatası → giriş gecikmesi;
  çıkış gecikmesinde anlık sensör → alarm; giriş süresinde çözme → alarm yok; giriş süresi dolunca alarm; `home` kipinde hareket yok
  sayılır; swinger 3; `ok=false` alarm üretmez ama kurmayı engeller; `millis` taşması (0xFFFFF000); açılışta kip geri yükleme ve
  alarm belleğinde siren çalmama; kip değişimi (`home`→`away`) yeni çıkış gecikmesi; `until_up` sabitliği (görünüm imzası).
  `test_contact_bus`: halka taşması, çok okuyucu imleç, yalnız door/window kenarı. `test_safety_cfg_edit`: `arm_key` gevşetme kuralı
  (kullanılmış DI reddi, yeni DI serbest), hırsız ayarlarının LAN'dan serbest olması. Siren VEYA'sı: tehlike ACK hırsız sirenini
  susturmaz, çözme tehlike sirenini susturmaz.
- **QA (`sim_intrusion.test.js`)**: uçtan uca kur/çık/gir/çöz, alarm → `intrusion_alarm` + ack, çözme → `intrusion_cleared`;
  kurulu kipte yeniden başlatma; LAN `/api/arm` ve `not_ready`; `ARM_KEY` DI kenarları; su alarmı + hırsız alarmı birlikte (vana ve
  siren bağımsız); **eşdeğerlik**: kapı/pencere sensörü olmayan panoda iz bit bit aynı (`sim_safety_equivalence` genişletilir);
  `sim_http` rota sayısı 33.
- **Sunucu**: olay doğrulama (3 tür, bilinmeyen alan reddi); `intrusion_alarm` → satır + tek push; `intrusion_cleared` ve mezar taşı;
  **bölge uzlaştırması hırsız satırına dokunmaz** (kırmızı testi: atlama olmadan satır `cleared` olur); `arm` ile uzlaştırma
  (açma/kapama/`lost`); `ALARM_USE_DISARM`; rol matrisi (misafir ve servis rollerinde `403`); `FIRMWARE_UNSUPPORTED`; PG'li test.
- **Flutter**: `ArmState` ayrıştırma ve eşitlik; ön denetim metni; kurma/çözme iyimser değil; misafirde seçici yok; geri sayım
  (`AmbientClock`/sahte saat); `IntrusionAlarmCard` ve geçmiş etiketi; onay aramasında `intrusion` satırının atlanması; "Evden
  Çıkıyorum" onayı (hayır → bugünkü komut dizisi birebir).

---

### F2.C Flutter bildirim alıcısı (plan 2.6)

#### C.1 Mevcut altyapı (okundu)

- İstemci: `PushGateway` (dar platform arayüzü), `PushCoordinator` (izin, belirteç kaydı, `onForegroundMessage` /
  `onMessageOpened` / `getInitialMessage`, tekilleştirme, dinleyici yokken tampon), `PeaceNotice.tryParse` (sıkı doğrulama),
  `PeaceNoticeController` + `PeaceNoticeHost` (kabuk düzeyi). Fabrika **her zaman** `UnsupportedPushGateway` döndürür: uygulama
  Firebase'siz derlenir (`pubspec.yaml`'da `firebase_core`/`firebase_messaging` yok).
- Sunucu: `push_service.sendNotice({kind})`; `safety_alarm` (owner + resident, `channel_id=safety_alarm`, `priority=HIGH`,
  `apns-priority=10`, `interruption-level=time-sensitive`, `category=SAFETY_ALARM`, `collapse=alarm_<home>_<device>_<zone>`) ve
  `safety_info` (owner, `channel_id=safety_info`). Gece hatırlatması `channel_id=peace_reminder`.

#### C.2 Ön koşul ve karar: gerçek FCM ağ geçidi

Bu paket **alıcı mantığını, kanalları ve yönlendirmeyi** üretir ve sahte ağ geçidiyle uçtan uca test eder. Gerçek FCM ağ geçidi
(`FirebasePushGateway`) `firebase_core` + `firebase_messaging` bağımlılığı, `google-services.json` / `GoogleService-Info.plist`,
APNs anahtarı ve `pub get` gerektirir; bu, 2026-10-02'de bilinçli alınan "Firebase'siz uygulama" kararını değiştirir. Bu yüzden ağ
geçidi ayrı bir iş paketidir (**WP-N4**, F2.E.3 karar F2-6): kullanıcı onayı ve yapılandırma değerleri gelince yazılır; fabrikanın
imzası (`createPushGateway(PushConfig?)`) değişmez. O zamana kadar:

- Uygulama açıkken ve açılınca alarm, state (`DeviceStatus.safety`) ve `GET …/alarms?state=open` üzerinden zaten görünür.
- **Kalan risk (7.1 "Push hiç yok") sürer:** uygulama kapalıyken alarm telefona ulaşmaz; yerel siren ve kart buzzer'ı tek uyarıdır.
  Sürüm notu ve sihirbaz bitiş ekranı bunu yazar: "Uygulama kapalıyken alarm bildirimi bu sürümde gelmez; siren takmanız önerilir."

#### C.3 Ayrıştırma: `SafetyPushNotice` (`lib/services/push/safety_notice.dart`, yeni)

`PeaceNotice` deseninde, `data` güvenilmeyen girdidir; `tryParse` asla fırlatmaz, geçersizde `null`.

| `data` anahtarı | Kural |
|---|---|
| `type` | `safety_alarm` ya da `safety_info`; başka değer → `null` (peace ayrıştırıcısına bırakılır) |
| `v` | `"1"`; başka → `null` |
| `home_id`, `device_id` | `[A-Za-z0-9_-]`, ≤ 64 |
| `device_uuid` | **yeni, isteğe bağlı** (C.8): `^[A-Z0-9-]{1,32}$`; yoksa `null` |
| `alarm_id` | rakam metni ≤ 18 hane |
| `zone` | `1..4` (yalnız `safety_alarm`) |
| `kind` | `water|gas|smoke|intrusion`; başka kısa kod `generic` (gösterimde "Güvenlik alarmı") |
| `status` | `latched|fault` (alarm); `reason` `alarm_lost|policy_off|policy_on|cfg_pending_dropped` (bilgi); bilinmeyen → `null` |
| `title`, `body` | `PeaceNotice` temizleyicisiyle (denetim/çift yön karakterleri atılır, 120/300 karakter) |

`dedupeKey`: alarm `a:<alarm_id>:<status>` (aynı alarmın `fault` push'u ayrı bildirimdir), bilgi `i:<alarm_id|home_id>:<reason>`.

#### C.4 Koordinatör genelleştirmesi (gece hatırlatması birebir korunur)

- `PushCoordinator._handleMessage` sırayla dener: `PeaceNotice.tryParse` → `SafetyPushNotice.tryParse`. Gece bildirimi yolu, akışı
  (`notices`), tamponu ve tekilleştirmesi **değişmez** (mevcut koordinatör testleri değiştirilmeden geçer).
- Yeni akış `safetyNotices` (`Stream<SafetyPushNotice>`, broadcast) ve ayrı tampon (en çok 8, süre 30 dk). Tekilleştirme penceresi
  ortak `_seenNotices` haritasını kullanır (anahtar önekleri çakışmaz).
- Yeni denetleyici `SafetyNoticeController` (`lib/services/safety_notice_controller.dart`): kabuğa bağlanır (Peace deseni:
  `AutomationState`'in yalnız public arayüzü), oturum/ev değişiminde nesil artırır, içerik loglamaz.

#### C.5 Platform kanalları ve izinler (bağımlılıksız)

- **Android** (`MainActivity.onCreate`, Kotlin, yalnız `NotificationManager`; API 26+). Oluşturma idempotenttir; FCM gelmeden de zararsızdır
  ve gelecekteki ağ geçidi için kanalları hazır eder:

  | Kanal kimliği | Ad (kullanıcı görür) | Önem | Ses / titreşim | Kilit ekranı |
  |---|---|---|---|---|
  | `safety_alarm` | Güvenlik alarmları | `IMPORTANCE_HIGH` | `RingtoneManager.TYPE_ALARM` sesi, `AudioAttributes.USAGE_ALARM`; uzun titreşim deseni; `setBypassDnd(true)` (yalnız kullanıcı izin verirse etkili) | `VISIBILITY_PUBLIC` |
  | `safety_info` | Güvenlik bilgileri | `IMPORTANCE_DEFAULT` | varsayılan | `VISIBILITY_PRIVATE` |
  | `peace_reminder` | Gece hatırlatması | `IMPORTANCE_DEFAULT` | varsayılan | `VISIBILITY_PRIVATE` |

  Kanal tanımları saf bir Kotlin nesnesinde (`NotificationChannels.specs`) tutulur; `peace_reminder` bugün sunucunun kullandığı ama
  uygulamanın hiç oluşturmadığı kanaldı (mevcut eksik kapanır). `AndroidManifest.xml`'e `android.permission.POST_NOTIFICATIONS` eklenir
  (Android 13+; izin penceresi yine yalnız kullanıcı isteyince, mevcut koordinatör kuralı).
- **iOS:** `Runner.entitlements`'a `com.apple.developer.usernotifications.time-sensitive` (kritik uyarı izni YOK, 7.2b-3).
  `AppDelegate` `UNUserNotificationCenter.setNotificationCategories` ile `SAFETY_ALARM`, `SAFETY_INFO`, `PEACE_CLOSE_ALL`
  kategorilerini **eylemsiz** kaydeder. Bildirimden doğrudan "Onayla"/"Vanayı Kapat" eylemleri bu sürümde YOK: arka planda kimlik
  doğrulamalı komut gerektirir; dokunma uygulamayı açar (F2.E.3 karar F2-7). `aps-environment` (push yeteneği) WP-N4'e aittir.

#### C.6 Bildirime dokununca alarm kartına git

Kaynak `opened` ya da `initial` olan `SafetyPushNotice` için `SafetyNoticeController.open(notice)`:

1. Oturum yoksa bildirim bekletilir (oturum açılınca bir kez işlenir, 30 dk geçerlilik).
2. `notice.homeId` kullanıcının evlerinden biri değilse yok sayılır (çıkış yapmış/rolü düşmüş telefon).
3. Etkin ev farklıysa `selectHome(homeId)`; gezinti yığını panoya (kök) indirilir (`Navigator.popUntil(isFirst)`).
4. `refresh()` beklenir (en çok 5 sn), ardından alarm aranır:
   - `kind=intrusion` → `IntrusionAlarmCard` (`card_intrusion_<uid>`);
   - diğerleri → `card_critical_alarm_<device_uuid>_<zone>`; `device_uuid` yoksa aynı `zone`'daki ilk kritik kart.
5. Kart varsa `Scrollable.ensureVisible` (Hareket v3 süresi, `MotionScope.off`'ta 0) ve kart bir kez vurgulanır (tek seferlik
   çerçeve animasyonu; yanıp sönme yok). Ekran okuyucuya "Alarm kartı açıldı: <başlık>" duyurusu.
6. Kart yoksa (alarm bu arada kapanmış): alarm geçmişi sayfası açılır ve alt bilgi "Bu alarm kapanmış." gösterilir. Misafir (rolü
  sonradan düşmüş) için geçmiş açılmaz, yalnız pano.
7. `safety_info` dokunuşu: `alarm_lost` → ilgili panonun kartı ya da pano; `policy_*` ve `cfg_pending_dropped` → cihaz ayarları
   sayfası (yoksa pano).

#### C.7 Uygulama açıkken gelen bildirim (`foreground`)

Sistem bildirimi gösterilmez (sunucu `notification` alanı yine gelir; ön planda platform göstermez). Alarm zaten etkin evdeyse state
kartı gösterir; ek olarak `SafetyAlertsPanel` yoksa (başka sayfadaysa) kabuk üst afişi: "**Gaz kaçağı alarmı** – dokunun" (dokunma C.6).
Başka evdeyse afiş "Diğer evinizde alarm: <ev adı>". Afiş Hareket v3 giriş animasyonu, `liveRegion`, 10 dk aynı `dedupeKey` için tek.

#### C.8 Sözleşme değişiklikleri (alan alan)

| Yer | Alan | Değişiklik |
|---|---|---|
| CONTRACTS §2.5 `safety_alarm` `data` | `device_uuid` | **Yeni, metin**: panonun `uid`'si (`devices.device_uuid`). Uygulama kart anahtarı pano `uid`'siyle kurulduğu için gerekli. `v` `"1"` kalır (ek alan; eski istemci yok sayar) |
| §2.5 `safety_info` `data` | `device_uuid` | aynı |
| §2.5 `safety_info` `reason` | `cfg_pending_dropped` | yeni değer (F2.D.2) |
| §2.5 `safety_alarm` `kind` | `intrusion` | yeni değer (F2.B) |
| §2.5 istemci kuralları | — | "Android kanalları `safety_alarm`/`safety_info`/`peace_reminder` uygulama ilk açılışta oluşturur; iOS kategorileri eylemsizdir" notu |

#### C.9 İş paketleri ve dosya sahipliği

| Paket | İçerik | Dosyalar |
|---|---|---|
| **WP-N1 (SRV)** | push `data`'ya `device_uuid` (alarm ve bilgi); push testleri | `server/src/services/push_service.js` (`buildSafetyData`), `server/src/services/alarm_service.js` (çağrı yeri) |
| **WP-N2 (APP, servis)** | `SafetyPushNotice`, koordinatör genelleştirmesi, `SafetyNoticeController` | `lib/services/push/safety_notice.dart` (yeni), `lib/services/push/push_coordinator.dart`, `lib/services/safety_notice_controller.dart` (yeni) |
| **WP-N3 (APP, arayüz + platform)** | yönlendirme ve vurgu, ön plan afişi, kabuk bağlantısı; Android kanalları + izin; iOS yetki + kategoriler | `lib/ui/app_shell.dart`, `lib/ui/widgets/safety_notice_host.dart` (yeni), `lib/ui/widgets/critical_alarm_card.dart` (yalnız vurgu kancası), `android/app/src/main/kotlin/.../MainActivity.kt`, `.../NotificationChannels.kt` (yeni), `android/app/src/main/AndroidManifest.xml`, `ios/Runner/AppDelegate.swift`, `ios/Runner/Runner.entitlements` |
| **WP-N4 (APP, ertelenmiş)** | `FirebasePushGateway` + fabrika + derleme yapılandırması | `lib/services/push/firebase_push_gateway.dart`, `push_gateway_factory.dart`, `pubspec.yaml`, platform dosyaları. **Kullanıcı kararı bekler** (C.2) |

`critical_alarm_card.dart`: G2 → I6 → N3 sırasıyla birleştirilir.

#### C.10 Test planı

- `safety_notice_test.dart`: geçerli alarm/bilgi; her alanın sınır ve bozuk değerleri (`null`, fırlatmaz); denetim karakteri
  temizliği; bilinmeyen `kind` → `generic`; `device_uuid` yok/var; `dedupeKey` (`latched` ve `fault` ayrı).
- `push_coordinator_test.dart`: **mevcut testler değiştirilmeden** geçer; yeni: güvenlik mesajı `safetyNotices`'a gider, `notices`'a
  gitmez; dinleyici yokken tampon ve süre; aynı mesaj `foreground` + `opened` tek olay.
- `safety_notice_controller_test.dart` (sahte ağ geçidi + sahte `AutomationState`): oturum yokken bekletme; yabancı ev yok sayılır;
  ev değişimi + `refresh`; kart bulunur / bulunamaz → geçmiş; misafir; nesil değişiminde uçuştaki yönlendirme iptali.
- Widget: `opened` mesajı → pano kaydırılır ve `card_critical_alarm_<uid>_<z>` görünür; vurgu tek seferlik (`MotionScope.off` süre 0);
  ön plan afişi ve dokunma.
- Android/iOS: JVM birim testi yok; `flutter analyze` + derleme denetimi; cihazda kanal ayarları ekranı kullanıcı denemesine bırakılır.
- Sunucu: `buildSafetyData` `device_uuid` (geçerli/geçersiz biçim atılır), mevcut push testleri aynen.

---

### F2.D Buluttan yapılandırma yazımı (`sys cfg_patch`)

#### D.1 Çevrimiçi akış

`POST /homes/:homeId/devices/:deviceId/safety-config` (gövde F2.D.6) sırası, tek transaction + cihaz satırı kilidi
(`SELECT … FROM device_configs WHERE device_id=$1 AND module='safety' FOR UPDATE`; aynı panoya aynı anda tek yama):

1. Üyelik ve yetenek `safety_config` (SUPER, STAFF, SESSION, OWNER). Misafir/resident `403`.
2. Şema doğrulaması `utils/safety_cfg_patch.js` (firmware `parseCfgEdit` ile aynı alan listesi ve aralıklar; bilinmeyen alan `400`).
   sys yükü (`cmd`, `module`, `uid`, `id`, `base_rev` eklenmiş) seri hali > 1024 bayt ise `400 PAYLOAD_TOO_LARGE`.
3. `devices.caps` `cfg` içermiyorsa `409 FIRMWARE_UNSUPPORTED`. Kopya (`device_configs`) yoksa `409 CONFIG_NOT_AVAILABLE`
   (önce `cfg_get` tetiklenir; kullanıcı yeniden dener).
4. `pending` boş değilse ve pano çevrimiçiyse `409 CONFIG_PENDING` (önce kuyruk boşalmalı ya da iptal edilmeli).
5. **Ön çakışma denetimi:** `base_rev` ≠ panonun son bildirdiği `cfg.safety.rev` (`devices.safety_state.cfg.rev`) → `409
   CONFIG_CHANGED_ON_DEVICE` (`data: {rev, crc, copy_rev}`) ve kopya eskiyse `cfg_get`. Ağa çıkılmaz.
6. Gevşetme sınıflandırması (`utils/safety_cfg_loosen.js`, firmware `isLoosening`'in portu; yalnız denetim kaydı ve bilgi push'u
   içindir, yetki kararı değildir).
7. Çevrimdışı → D.2. Çevrimiçi → `expectOutcome(topic, id, 10 sn, {uid})` kurulur, `publishSys(t, {cmd:"cfg_patch", module:"safety",
   uid, id, base_rev, set|del})`.
8. Sonuç:
   - `last_id = id` (FW değişikliği, D.6) **ya da** aynı `uid`'den canlı state'te `cfg.safety.rev = base_rev + 1` → `200 {applied:true,
     rev, crc, command_id}`; ardından `cfg_get` (adlar ve kopya için; mevcut dakika sınırı) ve denetim kaydı `safety_config_patch`
     (`actor`, rol, öğe türü ve kimliği, `loosening`; değer içeriği ve ad yazılmaz).
   - `last_rej.code`: `cfg_conflict` → `409 CONFIG_CHANGED_ON_DEVICE {rev, crc}` + `cfg_get`; `cfg_invalid` → `400 CONFIG_INVALID`;
     `zone_latched` → `409 ZONE_ALARM_ACTIVE`; `cfg_storage` → `507 DEVICE_STORAGE_FULL`; `busy` → `503 DEVICE_BUSY`.
   - 10 sn içinde sonuç yok → `202 {applied:null, command_id}` (sonuç state'te görünür).
9. Gevşetme ve aktör owner değilse owner'a `safety_info` (`reason:"policy_off"` zaten firmware olayıyla gider; diğer gevşetmeler için
   yeni push üretilmez, denetim kaydı yeterli; F2.E.3 karar F2-9).

#### D.2 Çevrimdışı pano: `device_configs.pending` uzlaştırması

- `pending` JSON biçimi (sürüm 1):
  `{"v":1,"items":[{"id":"<komut kimliği>","base_rev":N,"patch":{"set"|"del":…},"by":"<user uuid>","role":"owner|service_user|service_session|super_user","at":"<ISO>","loosening":bool}]}`.
  En çok 16 öğe (`409 CONFIG_QUEUE_FULL`); öğe ömrü 24 sa.
- Kuyruğa ekleme: kuyruk boşsa `base_rev` = panonun son `cfg.safety.rev`'i olmalı; doluysa `base_rev` = son öğenin `base_rev + 1`
  (uygulama bunu `GET …/safety-config` yanıtındaki `next_base_rev`'ten okur). Uyuşmazsa `409 CONFIG_CHANGED_ON_DEVICE`.
  Yanıt `202 {queued:true, position, expires_at, command_id}`.
- Uzlaştırma (`device_reconciler.onLiveState`, yerel anahtar deseni; `publishSys` köprüden): canlı state + `caps` `cfg`:
  1. Süresi dolan öğeler atılır (denetim `safety_config_pending_dropped {reason:"expired"}`).
  2. İsteyen kullanıcının eve erişimi kalmadıysa (üyelikten çıkarıldı, hesap silindi) öğesi ve sonrakiler atılır (`reason:"revoked"`).
     Rol yetkisi istek anında denetlendi; yeniden denetlenmez (servis oturumunun bitmesi kuyruğu düşürmez, 24 sa ömür sınırlar).
  3. Baş öğenin `base_rev` ≠ state `cfg.safety.rev` → **pano kazanır** (K5): bütün kuyruk atılır (`reason:"conflict"`), owner'a
     `safety_info {reason:"cfg_pending_dropped"}`.
  4. Eşitse baş öğe D.1 madde 7-8 ile gönderilir. `applied` → öğe çıkarılır, sonraki öğe bir sonraki canlı state'te (rev artmış
     olarak) gönderilir. `cfg_invalid`/`zone_latched`/`cfg_conflict` → baş öğe ve sonrakiler atılır (bağımlıdırlar) + bilgi push'u.
     Zaman aşımı → aynı çevrimiçi oturumda en çok 3 deneme (bekleyici yeniden kurulur; firmware aynı `id`'yi tekilleştirmez, ama
     `base_rev` artık eşleşmeyeceği için ikinci uygulama `cfg_conflict` olur: çift uygulama mümkün değildir).
  5. Kuyruk anahtarlı iş kuyruğunda cihaz başına tek uçuştadır.
- `DELETE /homes/:homeId/devices/:deviceId/safety-config/pending` (`safety_config`): kuyruğu boşaltır (denetim kaydı).

#### D.3 `409 CONFIG_CHANGED_ON_DEVICE`

Üç kaynaktan doğar: ön denetim (D.1-5), firmware `cfg_conflict` (D.1-8), kuyruk ekleme (D.2). Gövde
`{error:{code:"CONFIG_CHANGED_ON_DEVICE", message:"Pano yapılandırması bu arada değişti; güncel hali okunup yeniden denenmeli."}, data:{rev, crc, copy_rev}}`.
Sunucu her durumda kopyayı tazelemek için `cfg_get` ister (dakika sınırı). İstemci kuralı: kopyanın `rev`'i `data.rev`'e ulaşana kadar
(en çok 15 sn, `GET …/safety-config` yoklaması) bekle, planı **yeniden hesapla** (`buildSafetyPatches` fark tabanlıdır) ve bir kez
daha dene; ikinci çakışmada kullanıcıya göster.

#### D.4 Yetki ve gevşetme (karar 7.2b-7 aynen)

| Yol | Ekleme / sıkılaştırma | Gevşetme | Denetim |
|---|---|---|---|
| Bulut, owner | evet | evet | firmware `VIA_CLOUD`; sunucu denetim kaydı |
| Bulut, super / staff / service_session | evet | evet | aynı; politika kapatma owner'a `safety_info` (mevcut `policy_changed` yolu) |
| Bulut, resident / guest | hayır (`403`) | hayır | |
| LAN (yerel anahtar) | evet | **hayır** (`403 local_loosen_forbidden`, firmware) | |
| Seri CLI | evet | evet | fiziksel erişim |

**Faz 2 incelemesi (G-1) istisnası:** bulut yolu gevşetebilir ama gaz vanasını uzaktan açılabilir kılan değişikliği (her zaman) ve kurulu kipte
hırsız alarmını zayıflatan değişikliği uygulayamaz; ayrıntı belge sonundaki "Faz 2 inceleme" bölümü.

Gevşetmenin tanımı firmware'dedir (`isLoosening`, CONTRACTS §2.6 "Gevşetme"); sunucu portu yalnız denetim ve arayüz uyarısı içindir.
Port ile firmware'in ayrışmaması için ortak test vektörü dosyası kullanılır: `tools/qa_stack/sim/fw/fixtures/loosening_vectors.json`
(QA portu üretir; sunucu testi okur).

#### D.5 Sihirbazın bulut yolu (APP)

- Taşıma soyutlaması `SafetyConfigTransport` (`logic/safety_config_transport.dart`, yeni): `read()` ve `apply(patch, baseRev)`;
  gerçeklemeler `LanSafetyConfigTransport` (bugünkü `automation_api_service` çağrıları) ve `CloudSafetyConfigTransport` (REST).
  `applySafetyConfigPatches` taşımadan bağımsız olur (davranışı LAN'da birebir aynı).
- **Seçim kuralı (K5: yerel öncelikli):** (1) LAN/AP erişilebilir ve yerel anahtar varsa LAN. (2) Değilse kullanıcının `safety_config`
  yeteneği varsa ve pano `caps` `cfg` ilan ediyorsa bulut. (3) Hiçbiri değilse kayıt kapalı: "Yapılandırma için panoya yerel ağdan
  bağlanın ya da yetkili bir hesapla internet üzerinden deneyin."
- **LAN gevşetme reddinde bulut önerisi:** LAN `403 local_loosen_forbidden` dönerse ve kullanıcının `safety_config` yeteneği varsa
  diyalog: "Bu değişiklik güvenliği azaltır ve yerel ağdan yapılamaz. İnternet üzerinden yetkili hesabınızla uygulansın mı?" Onayla
  aynı yama bulut taşımasıyla gönderilir (planın kalanı da bulut taşımasıyla sürer).
- **Bulutta okuma:** `GET …/safety-config` kopyası `rev`'i panonun state'teki `cfg.safety.rev`'ine eşit olana kadar beklenir (en çok
  15 sn); eşit değilse "Pano yapılandırması okunuyor…" ve yeniden deneme.
- **Çevrimdışı pano:** `202 queued` → adım sonunda "Pano çevrimdışı. Değişiklikler pano bağlanınca (24 saat içinde) uygulanacak."
  Adım 7 **tamamlanmış sayılmaz** (tamamlanma koşulu panoya yazılmış olmaktır, dalga 2 not 18); kurulumcu daha sonra adımı yeniden
  açtığında kuyruk durumu (`pending`) gösterilir, "Kuyruğu iptal et" düğmesi `DELETE …/pending` çağırır.
- **Bölge testi** bulutta mevcut `POST …/alarm-test` ile; sonuç LAN'daki `/api/events` yerine state (`test` bölgesi) ve alarm
  listesinden okunamadığı için bulutta "Geri bildirim sonucu yalnız yerel bağlantıda görünür; vananın kapandığını gözle doğrulayın"
  yazılır (sunucuya `test_result` saklama eklenmez; F2.E.3 karar F2-10).

#### D.6 Sözleşme değişiklikleri (alan alan)

| Yer | Alan | Değişiklik |
|---|---|---|
| FW sys `cfg_patch` | başarı yankısı | Başarıda ve `id` geçerliyse `last_id = id` (`rejectCmd`'nin kabul karşılığı `acceptCmd(id)`); bugün yalnız `triggerPublish` |
| FW sys `cfg_patch` | `last_rej.code` | `CfgResult::STORAGE` artık `busy` değil yeni `cfg_storage` (NVS payı yetmedi, inceleme RV-3) |
| FW yama gövdesi | `set.intrusion` | F2.B.7 |
| REST yeni | `POST /homes/:homeId/devices/:deviceId/safety-config` gövde `{base_rev: int ≥ 0, set?: {sensor|actuator|policy|zone|light|intrusion: {…}}, del?: {sensor: "dN|bN"} | {actuator: "aN"}, id?}` (`set` ya da `del`'den tam biri) | yanıtlar: `200 {applied:true, rev, crc, command_id}`, `202 {applied:null, command_id}`, `202 {queued:true, position, expires_at, command_id}`, `400 VALIDATION|CONFIG_INVALID|PAYLOAD_TOO_LARGE`, `403`, `409 FIRMWARE_UNSUPPORTED|CONFIG_NOT_AVAILABLE|CONFIG_PENDING|CONFIG_CHANGED_ON_DEVICE|CONFIG_QUEUE_FULL|ZONE_ALARM_ACTIVE`, `503 DEVICE_BUSY`, `507 DEVICE_STORAGE_FULL` |
| REST yeni | `DELETE /homes/:homeId/devices/:deviceId/safety-config/pending` | `200 {dropped: n}` |
| REST mevcut | `GET …/safety-config` | ek alanlar: `state_rev` (panonun son bildirdiği rev), `next_base_rev` (kuyruk varsa son öğe + 1, yoksa `state_rev`), `pending: [{id, op:"set|del", item:"sensor|actuator|…", target, at, role, loosening}]` (yalnız `safety_config` yeteneği olanlara; diğerlerine alan yok) |
| `device_configs.pending` | JSONB | D.2 biçimi (migration gerekmez; kolon 033'te var) |
| Push `safety_info.reason` | `cfg_pending_dropped` | F2.C.8 |
| Denetim kaydı | `safety_config_patch`, `safety_config_pending_dropped` | `device_audit_logs.event` değerleri |
| Uygulama hata eşlemesi | yeni kodlar | `CONFIG_CHANGED_ON_DEVICE` "Pano yapılandırması bu arada değişti; güncel hali okundu, yeniden deneyin."; `CONFIG_PENDING` "Bu pano için bekleyen değişiklikler var."; `CONFIG_QUEUE_FULL` "Bekleyen değişiklik sınırı doldu."; `DEVICE_STORAGE_FULL` "Panonun yapılandırma belleği dolu; kurulumcunuza başvurun."; `CONFIG_NOT_AVAILABLE` "Pano yapılandırması henüz okunmadı; biraz sonra yeniden deneyin." |

#### D.7 İş paketleri ve dosya sahipliği

| Paket | İçerik | Dosyalar | Bağımlılık |
|---|---|---|---|
| **WP-C1 (FW)** | `acceptCmd` yankısı, `cfg_storage` kodu; sim portu | `src/MqttManager.cpp`, `src/safety/SafetyFsm.h` (yalnız `Rej` metni), `tools/qa_stack/sim/fw/mqtt_manager.js` | — (I2 ile aynı sürüm 1.3.0'a girer; `MqttManager.cpp` I2'de yoktur) |
| **WP-C2 (SRV)** | yama şeması, gevşetme portu + ortak vektörler, rota, `safety_service.patchConfig`, kuyruk + uzlaştırma, `GET` ekleri, denetim, push nedeni | `server/src/utils/safety_cfg_patch.js` (yeni), `server/src/utils/safety_cfg_loosen.js` (yeni), `server/src/services/safety_service.js`, `server/src/routes/safety_routes.js`, `server/src/services/device_reconciler.js` (yalnız güvenlik yapılandırması kuyruğu), `server/src/services/alarm_service.js` (yalnız `requestConfig` dışa açımı), `server/src/services/push_service.js` (yeni neden), `tools/qa_stack/sim/fw/fixtures/loosening_vectors.json` (QA üretir) | C1 (sözleşme) |
| **WP-C3 (APP)** | taşıma soyutlaması, bulut taşıması, seçim kuralı, LAN gevşetme reddinde bulut önerisi, kuyruk görünümü, hata metinleri | `lib/ui/pages/service_setup/logic/safety_config_transport.dart` (yeni), `.../logic/safety_assignment.dart`, `.../steps/step_7_safety.dart`, `lib/services/ev_cloud_api_service.dart`, `lib/services/api_exception.dart` (metinler) | C2 |

`device_reconciler.js` C2 ile birlikte yalnız bu pakette değişir; `step_7_safety.dart` ve `safety_assignment.dart` sırası G2 → I6 → C3.

#### D.8 Test planı

- **FW/QA:** `cfg_patch` başarıda `last_id` yankısı (kırmızı: bugün yok); `cfg_storage` kodu (NVS payı dolu sahte depo);
  uid uyuşmazlığında sessizlik (mevcut); `base_rev` yanlış → `cfg_conflict` + olay. `sim_safety.test.js`'e bulut yaması senaryosu.
- **Sunucu (PG'siz):** şema (her öğe türü, sınırlar, `set`+`del` birlikte reddi, 1024 bayt sınırı); gevşetme portu ortak vektörlerle
  firmware portuyla aynı sonucu verir; rol matrisi (resident/guest `403`); ön çakışma `409`; `expectOutcome` ile `applied`,
  `cfg_conflict`, `cfg_invalid`, `zone_latched`, zaman aşımı; çevrimdışı kuyruğa ekleme ve `next_base_rev` kuralı; kuyruk dolu.
- **Sunucu (PG'li):** satır kilidiyle iki eşzamanlı yamadan biri `409 CONFIG_PENDING`/`CONFIG_CHANGED_ON_DEVICE`; uzlaştırma
  zinciri (3 öğe sırayla, her biri bir canlı state sonrası); baş öğe çakışması → tüm kuyruk düşer + bilgi push'u; süre dolumu;
  üyelikten çıkarılan isteyen; `DELETE …/pending`; denetim kaydında değer/ad olmaması.
- **Flutter:** `CloudSafetyConfigTransport` istek/yanıt eşlemesi; seçim kuralı (LAN var/yok, yetenek var/yok, `caps` `cfg` var/yok);
  LAN `local_loosen_forbidden` → bulut önerisi diyaloğu (onay/iptal); `CONFIG_CHANGED_ON_DEVICE` → kopya bekleme + plan yeniden
  hesaplama + tek yeniden deneme; `queued` → adım tamamlanmaz ve kuyruk görünür; LAN yolunun mevcut testleri
  (`f_setup_safety_assignment_test.dart`) değiştirilmeden geçer.

---

### F2.E Uygulama sırası, riskler, kararlar

#### E.1 Sıra ve paralellik

1. **Dalga A (bağımsız):** WP-G1, WP-G2, WP-G3, WP-N1, WP-N2, WP-I1, WP-C1.
2. **Dalga B:** WP-I2 (I1'den sonra), WP-C2 (C1 sözleşmesiyle), WP-N3 (N2'den sonra), WP-I5.
3. **Dalga C:** WP-I3, WP-I4, WP-I6, WP-C3.
4. **Sürüm (WP-R2):** firmware 1.3.0 (I2 + C1), dağıtım sırası **sunucu → firmware → uygulama** (yeni sunucu `intrusion`/`cfg` yeteneği
   ilan etmeyen panoda bugünkü gibi çalışır). WP-N4 ayrı karara bağlıdır.

Paylaşılan dosyalar ve birleşme sırası: `critical_alarm_card.dart` (G2 → I6 → N3), `step_7_safety.dart` ve `safety_assignment.dart`
(G2 → I6 → C3), `alarm_service.js` (G1 → N1 → I4 → C2), `SOURCES.json` (I1 → I2 → C1, her birleşmeden sonra `fwcheck --update`),
`safety_routes.js` / `safety_service.js` (I4 → C2).

#### E.2 Riskler

| Risk | Etki | Azaltma |
|---|---|---|
| Push alıcısı var ama ağ geçidi yok (C.2) | Uygulama kapalıyken alarm ulaşmaz | Açık ürün kararı (F2-6); siren önerisi metni; WP-N4 hazır arayüze oturur |
| Hırsız satırının bölge uzlaştırmasında kapanması | Sessizce kapanan hırsız alarmı | B.8 ayrım kuralı + kırmızı testi |
| `ARM_KEY`'in kapı kontağı girişine atanması | Kapıyı kapatmak alarmı çözer | `di_hist` gevşetme kuralı (B.3) |
| Kuyruktaki eski yamanın sahadaki yerel değişikliği ezmesi | Kurulumcunun yaptığı değişiklik kaybolur | `base_rev` zinciri; pano kazanır, kuyruk düşer (D.2-3) |
| Gaz alarmında otomatik anahtarlama | Tutuşma | A.4 (zamanlayıcı, gece hatırlatması, uygulama onayı) |
| NVS bütçesi (`ahbu_latch/arm` +1) | Kilit yazımı | Bütçe kararı zaten açık (dalga 1 F0); `reserveLatch` payına `arm` dahil edilir (I2) |
| Hırsız alarmında sahte tetik (uzun kablo) | Komşu rahatsızlığı | DiGate süzgeci + swinger 3 + siren `run_limit_s` |
| v1.2.0 `parseCfgEdit` `flags > 0x07`'yi reddeder (doğrulandı) | Eski panoda sihirbaz yazımı `cfg_invalid` | Uygulama ve sunucu yeni bitleri yalnız `caps` `intrusion` varken yazar (B.7) |

#### E.3 Bu tasarımda verilen kararlar (kullanıcı "soru sorma, gerekeni yap"; standart/emniyet önceliği)

- **F2-1** Gaz alarmında otomatik anahtarlama (bulut zamanlayıcısı, gece hatırlatması) durur; kullanıcı komutu onayla serbesttir.
- **F2-2** Hırsız alarmı ev geneli: bütün pano sirenleri; bölge eşlemesi yok.
- **F2-3** Kurma/çözme: owner ve resident; misafir ve **servis rolleri buluttan yapamaz** (yerelde LAN/CLI ile test).
- **F2-4** Kip ve alarm belleği güç kesintisinden sağ çıkar; açılışta çıkış gecikmesi yok, bellekteki alarm sirensiz geri gelir.
- **F2-5** Kontak kenarları olay kutusuna yazılmaz; yerel `ContactBus` ve state seviyesi yeterli.
- **F2-6** Firebase'siz karar korunur; gerçek FCM ağ geçidi (WP-N4) kullanıcı onayı ve yapılandırma değerleriyle ayrı yapılır.
- **F2-7** Bildirim eylem düğmeleri (Onayla / Vanayı Kapat) bu sürümde yok; dokunma uygulamayı açar.
- **F2-8** Çevrimdışı yapılandırma kuyruğu en çok 16 öğe, 24 sa; çakışmada pano kazanır, kuyruk bütünüyle düşer.
- **F2-9** Bulut gevşetmesi denetim kaydına yazılır; politika kapatma dışındaki gevşetmeler için ayrı push yok.
- **F2-10** Bulutta bölge testi sonucu (`test_result`) saklanmaz; yalnız LAN'da gösterilir.

#### E.4 Açık kalanlar (bu fazın dışında)

Somut Zigbee/Thread köprü sürücüsü; RTC↔SNTP; termostat (3.x) ve senaryo motoru (5.x) — `ContactBus` arabirimi bunlara hazırdır;
gömülü web sayfası güvenlik/alarm ekranı; NVS bölüm büyütme kararı; donanım doğrulaması ("İlk kartta denenecekler" listesine
eklenecekler: hırsız giriş/çıkış gecikmesi gerçek kapı kontağıyla, `ARM_KEY` anahtarlı kontak, sirenin iki kaynakla sürülmesi,
kurulu kipte güç kesintisi).

---

## Uygulama notları (SRV Faz 2: WP-G1, WP-N1, WP-I4, WP-C2)

Ekip SRV, 2026-10-07, taban `caa41ef` (tasarım) / `751f815` (canlı). TDD: her paketin testi önce yazıldı ve kırmızı görüldü
(eksik modül/alan, yanlış metin, eski davranış), sonra kod. Sözleşme ayrıntısı `docs/CONTRACTS.md` §1.4, §1.5b, yeni §1.5e, §2.5,
§2.6 ve §2.7. Firmware ve uygulamaya dokunulmadı.

**WP-G1 (gaz/duman).**
- Push metinleri F2.A.5 aynen; `faultTitle(kind)` / `faultBody(kind)` türe göre, bilinmeyen tür eski genel metin. Su metni değişmedi.
- "Açık gaz alarmı" = `alarms.kind='gas'` ve `status IN ('latched','fault','silenced')`. **Ek sorgu yok:** zamanlayıcıda mevcut cihaz
  sorgusuna, gece hatırlatmasında mevcut canlı anlık görüntü sorgusuna `EXISTS … AS gas_alarm` kolonu eklendi (ilintisiz alt sorgu,
  `alarms_home_open_idx`). Gaz alarmı yokken sonuç ve sorgu sayısı aynen (test).
- Zamanlayıcı: `skipped_hazard` / `gas_alarm`, yuva **tüketilir** (alarm kapanınca gecikmiş anahtarlama yapılmaz).
- **Sapma:** gece hatırlatmasının değerlendiricisi `peace_service.js` değil `peace_reminder.js`'tir. Tasarımdaki "`skipped`" durumu CHECK'te yoktu:
  yeni durum `skipped_hazard` için **migration 034** yazıldı (yalnız `peace_logs_status_check` genişletildi; idempotent, NOT VALID + VALIDATE;
  gerçek PG'de yalıtılmış veritabanında `migrate.js` iki kez + dosya iki kez daha). `skipped_hazard` `skipped_offline` gibi pencere içinde
  yeniden denenir (alarm kapanırsa bildirim yine gider). Gönderim öncesi ikinci anlık görüntüde de denetlenir.
- `POST …/close-all` → `409 HAZARD_ACTIVE` `peace_service.closeAll` içinde, yayından önce (rota dosyasına değişiklik gerekmedi).
  Kullanıcının toplu `all_lights_off` komutu (`closeLightsKeepingPlugs`) bilinçli komuttur, engellenmez (F2-1).

**WP-N1 (push `device_uuid`).** `buildSafetyData` yalnız uygulamanın kuralına (`^[A-Z0-9-]{1,32}$`, büyük harfe çevrilir) uyan değeri yazar;
geçersizde anahtar hiç yoktur. Alarm push'unda değer talep sorgusunun `RETURNING` alt sorgusundan, bilgi push'unda çağıranın bildiği
`uid`'den gelir (ek sorgu yok).

**WP-I4 (hırsız alarmı).**
- Yeni olay türleri **katı alan listesiyle** doğrulanır (bilinmeyen alan → olay atılır); eski türler eskisi gibi esnek. `intrusion_alarm`
  için `zone` zorunlu (alarms.zone NOT NULL 1..4).
- **Ek savunma (tasarımda yoktu):** `findAlarm`'ın `aid`'siz bölge dalı `kind <> 'intrusion'` ile süzülür; aksi halde aid taşımayan bir
  `valve_fault`/`alarm_cleared` aynı bölgedeki hırsız satırını değiştirebilirdi.
- `intrusion_cleared` bilinmeyen `aid` → mezar taşı; olay bölge taşımadığı için bölge yer tutucusu 1 (mezar taşı listelenmez).
  State'ten açılan hırsız satırının bölgesi ilk kaynak sensörün bölgesi (yoksa 1).
- `arm` özetinde bilinmeyen `mode`/`st` → `"unknown"`; uzlaştırma `unknown` durumda satıra dokunmaz (RV2-1 ilkesi).
- Temiz-pano önbelleği `arm.st='alarm'` iken kurulmaz.
- Rota `POST /homes/:homeId/devices/:deviceId/arm`; yetki `safety_arm` (owner, resident) rota + servis + rol matrisi testli.

**WP-C2 (buluttan yapılandırma yazımı).**
- **Sapma (dosya yerleşimi):** iş mantığı yeni `server/src/services/safety_cfg_sync.js`'tedir (REST yolu ve kuyruk aynı kodu kullanır);
  `safety_service.js` yalnız yetki + cihaz çözümü, `device_reconciler.js` yalnız `onSafetyState` bağlantısı (cihaz başına sıralı iş) içerir.
- **Sapma (kilit):** tasarım "tek transaction + satır kilidi" diyordu; ağ beklemesi (≤ 10 sn) boyunca transaction açık tutulmadı
  (havuz bağlantısı ve `idle_in_transaction_session_timeout` 20 sn). Bunun yerine satır kilidi altında `pending.inflight = {id, at}` yazılır,
  gönderim transaction dışında yapılır, sonuç ikinci transaction'da temizlenir; uçuş işareti 30 sn sonra geçersizdir (süreç çökerse kilit
  kalıcı olmaz). Gerçek PG testi: aynı anda iki yamadan biri uygulanır, diğeri `409 CONFIG_PENDING`.
- Kuyruk biçimi tasarımdaki sürüm 1'e iki isteğe bağlı alan ekler: `inflight` ve öğede `sent_at`. `sent_at`'li baş öğe ve state rev =
  `base_rev + 1` → **uygulandı** sayılır (`applied_inferred`): zaman aşımından sonra panonun uyguladığı yama "pano kazanır" kuralıyla
  kuyruğu yanlışlıkla düşürmez ve çift uygulanmaz. Açık ret (busy vb.) ya da yayın hatası `sent_at`'i siler.
- Sonuç tespiti: köprü `expectOutcome(..., {uid, cfgRev})` (firmware v1.2.0 başarıda `last_id` yazmaz; C1 sonrası `last_id` de çalışır).
  Ret anındaki panonun `{rev, crc}`'si `409 CONFIG_CHANGED_ON_DEVICE` `data`'sına girer (`http_errors` beyaz listesine `data`).
- `caps` `intrusion` olmadan `set.intrusion`, sensör `flags > 0x07` ya da `kind:"arm_key"` → `409 FIRMWARE_UNSUPPORTED` (B.7: v1.2.0 bunları
  `bad_value` ile reddeder). Gövde kuralları firmware `parseCfgEdit` JS portuyla 37 örnekte birebir karşılaştırılır (test).
- **Kusur düzeltmesi (alarm_service):** dakika sınırına takılan `cfg_get` bir daha istenmiyordu (sonraki state'ler aynı rev'i taşıdığı için
  erken dönüş); sihirbazın art arda yamalarında kopya kalıcı bayat kalırdı. Artık kopyanın eşitliği doğrulanana kadar dakikada en çok bir
  kez yeniden denenir; `requestConfig({force})` yama/çakışma sonrası 5 sn taban aralıkla ister.
- Erişimi kalmayan isteyen: kullanıcı yok / pasif / engelli durum ya da evde (süresi dolmamış) üyeliği yok ve süper değil. Servis oturumu
  (kullanıcısız) öğeleri yalnız 24 sa ömürle sınırlanır (tasarım D.2-2).
- Denetim: `queued` sonucu da yazılır (tasarım yalnız `applied` diyordu); değer ve ad hiçbir kayıtta yok (test).
- Gevşetme ortak vektörleri: `tools/qa_stack/sim/fw/fixtures/gen_loosening_vectors.js` firmware JS portundan 44 vektör üretir
  (`loosening_vectors.json`); QA testi dosyanın portla güncel olduğunu, sunucu testi sunucu portunun her vektörde aynı sonucu verdiğini
  denetler. Mutasyon kanıtı: sunucu portundan EM-7 / DI geçmişi / siren kuralı çıkarılınca sırasıyla 1 / 2 / 1 vektör kırmızı.
  Sunucu panonun `di_hist` kaydını bilmez; alt sınır olarak kopyadaki kullanım (`diUseMask`) verilir (yalnız denetim bilgisi).

**Dağıtım sırası:** migration 034 → sunucu → (firmware 1.3.0 / C1) → uygulama. Yeni sunucu `caps` `intrusion`/`cfg` ilan etmeyen panoda
bugünkü gibi çalışır.

**Kalanlar / riskler (bu paketlerde yapılmadı).**
- Firmware C1 (`acceptCmd` yankısı, `cfg_storage`) ve I1/I2 (hırsız katmanı); sunucu ikisini de bekleyerek hazır (testli).
- Uygulama paketleri (G2, I5, I6, N2, N3, C3) ve QA senaryoları (G3, I3).
- Uzlaştırıcının iş kuyruğu eşzamanlılığı 2'dir; bir panoya yama gönderimi (≤ 10 sn) bir şeridi meşgul eder. Çok sayıda çevrimdışı
  kuyruklu pano aynı anda dönerse çocuk kilidi / yerel anahtar uzlaştırmaları gecikebilir (doğruluk etkilenmez).
- Gevşetme sınıflandırması kopyaya göre yapılır; kopya bayatsa bilgi amaçlı sonuç yanlış olabilir (yetki kararı değildir).

## Faz 2 inceleme

Faz 2'nin (taban `751f815`, HEAD `d867346`) karşıt doğrulamasında 11 bulgudan 8'i CONFIRMED, 2'si PARTIAL, 1'i REFUTED çıktı; RV-E1 ile R1
tek kökte (G-1) birleştirildi. Geçerli bulguların hepsi bu turda TDD ile düzeltildi: önce kırmızı test (Unity, QA simülatörü, sunucu,
gerçek PG, Flutter), sonra düzeltme. Doğrulayıcının yeniden üretim testlerinden `rv_e2_entry`, `rv_cfgrev_race` ve `rv_settle_order` artık
yeşil; `rv_e1_medium`, `rv_arm_bypass` ve `rv_e3_armkey` düzeltmeyle anlamını yitirdi (yama artık reddedilir / NO yapılandırma geçersizdir)
ve beklentisi ters çevrilmiş halleriyle takıma girdi. Firmware sürümü **1.2.1** olarak kaldı (hiçbir karta yazılmadı); paket yeniden
üretildi. **Migration yok.**

### Karar: G-1, K-4 / 7.2b-8 ile D.4 arasındaki boşluk

D.4 bulutta owner/servis rolüne gevşetmeyi (eylemci silme dahil) açar; 7.2b-8 "gaz vanası buluttan açılmaz" der. İkisi birlikte, gaz
vanasını önce bulut yamasıyla "su vanası" ya da sıradan röle yapıp sonra uzaktan açmaya izin veriyordu. Emniyet önceliğiyle karar:
**bulut yolu gevşetebilir, ama iki sınıfı uygulayamaz.** (1) `isGasRelease`: mevcut gaz vanasının röle(ler)/tür/kip/akışkan kimliğini
değiştirmek ya da onu silmek ve `gas_reset` satır kuralı (EM-6/FW2-2). Bu değişiklik her zaman reddedilir (`gas_local_only`, sunucuda
`403 GAS_VALVE_LOCAL_ONLY`) ve yalnız seri CLI'dan yapılabilir. (2) `isIntrusionLoosening`: hırsız alarmını zayıflatmak. Bu yalnız kurulu
kipte reddedilir (`armed`, sunucuda `409 INTRUSION_ARMED`). F2-3 servis rollerinin buluttan çözmesini yasaklar; sensörü susturarak
dolaylı çözme de aynı kapsamdadır. B.3'teki LAN serbestliği değişmedi (yerel anahtar sahibi zaten çözebilir). D.4 tablosu bu iki sınıf
dışında aynen geçerlidir.

### Düzeltilenler

| Bulgu | Önem | Ne yapıldı | Nerede |
|---|---|---|---|
| G-1a (RV-E1): bulut yaması gaz vanasının akışkanını suya çevirip ya da eylemciyi silip vanayı uzaktan açılabilir kılıyordu | yüksek | `isGasRelease(a, b, diHist)` (saf; `roleRowLoosening` ortak yardımcı). `submitEdit` `VIA_CLOUD`'da `CfgResult::GAS_LOCAL` döner, MQTT `last_rej = gas_local_only`. Sunucu kopyaya göre önceden reddeder (`403`, ağa çıkmaz, kuyruğa girmez, denetim `rejected_gas_local`); kuyruktaki öğe firmware reddinde düşer. Bölge daraltma ya da gaz sensörünü silme vanayı açmadığı için bu sınıfa girmez (yine gevşetmedir) | `SafetyCfgEdit.h`, `SafetyManager.{h,cpp}`, `MqttManager.cpp`, `WebPortal.cpp`, `main.cpp`; `utils/safety_cfg_loosen.js`, `services/safety_cfg_sync.js`; QA portları |
| G-1b (R1): kurulu evde bulut yaması hırsız sensörünü alarm dışı bırakıyordu (`isLoosening` yalnız tehlike sensörlerine bakıyordu) | yüksek | `isIntrusionLoosening`: SF_REACT'li kapı/pencere/hareket sensörünü silmek ya da alarm dışı bırakmak, `SF_ENTRY`/`SF_AWAY_ONLY` eklemek, NC->NO, onay süresini ya da etkin çıkış/giriş gecikmesini uzatmak, `arm_key` satır kuralı. `submitEdit` `VIA_CLOUD` ve kip ≠ `off` -> `CfgResult::ARMED` (yeni `Rej::ARMED`, `armed`). Sunucu son state'teki `arm.mode`'a göre `409 INTRUSION_ARMED` (çevrimiçi ve kuyruk); hırsız zayıflatması denetimde `loosening:true` sayılır. Ortak vektörler 51 -> 68, her vektörde `gas_release` ve `intrusion_loosening` beklentisi | aynı dosyalar; `fixtures/gen_loosening_vectors.js`, `loosening_vectors.json` |
| RV-E2: giriş gecikmesi sürerken enerji kesilirse olay kayboluyordu | orta | Giriş gecikmesi başlangıcı `dirty` (NVS yazımı); `ArmRecord.alarm = ARM_REC_ENTRY (2)`, giriş yolu sensör kodları `aid[]`'de (en çok 8, sayısı `rsv[0]`). Açılışta giriş gecikmesi baştan başlar, süre dolunca kaydedilen kaynakla alarm; çözme önler. Bilinmeyen `alarm` değeri durum uydurmaz (kip geri gelir, `idle`). Yapı boyutu 20 B değişmedi | `IntrusionFsm.h`, `intrusion_fsm.js` |
| RV-E3: anahtarlı kontak NO bağlıyken kablo kesmek alarmı çözüyordu | orta | `validate`: `arm_key` satırında `active_open = 0` -> `CfgErr::ARM_KEY_NOT_NC` (`arm_key_not_nc`); bütün yollar (LAN, bulut, CLI) aynı doğrulamadan geçer. Uygulama: `InputRole.armKey.requiresNc` (rol seçilince NC, NO plan engelli), dedektör notu yalnız sensörlerde, anahtar notunda NC açıklaması. Kurulu konumda kontak açık: kablo kesilirse "kurulu" okunur | `SafetyConfig.h`, `safety_config.js`; `safety_assignment.dart`, `step_7_safety.dart` |
| R2: bekleyici `rev == base_rev + 1` ile başka kaynaklı değişikliği "uygulandı" sayıyordu | orta | Köprü: rev çıkarımı yalnız `last_id` yankısı vermeyen panoda (`caps` `intrusion` yok; yankı ve hırsız katmanı aynı sürüm 1.2.1). Kuyruk: yankılı panoda `applied_inferred` yalnız state `last_id` = baş öğe kimliğiyse; aksi halde "pano kazanır" (köprü uzlaştırıcıya `lastId` iletir). v1.2.0 davranışı aynen | `mqtt_bridge.js`, `safety_cfg_sync.js` |
| R3: yanıt cihaz durumu DB'ye yazılmadan dönüyordu; uygulama bayat kopyayla planı daha yeni `base_rev` ile gönderebiliyordu | düşük | Köprü: `cfgRev`'li bekleyici eşleşmesi aynı yerde yapılır, çözümü state işi (`devices.safety_state`) bittikten sonra verilir (diğer bekleyiciler eskisi gibi hemen). Uygulama: `read()` kopyanın `max(minRev, state_rev)`'e ulaşmasını bekler; `base_rev` planın hesaplandığı kopyanın rev'idir (yalnız sunucu kuyruğu doluysa `next_base_rev`) | `mqtt_bridge.js`; `safety_config_transport.dart`, `relay_logic.dart` |
| RG-1: pano rev'i gerileyince (fabrika sıfırlaması) kopya kalıcı bayat kalıyordu | orta | `upsertConfig`: eski döküm yenisini yine ezmez; ama panonun son bildirdiği `(rev, crc)` (`devices.safety_state.cfg`) ile aynı döküm, kopyadan küçük rev'li olsa da yazılır. Gerçek PG testiyle doğrulandı (panonun bildirmediği eski rev ve aynı rev/farklı crc yine `stale`) | `alarm_service.js` |
| RG-2: yapılandırma kuyruğu ev uzlaştırmasıyla aynı (eşzamanlılık 2) kuyruğu kullanıyordu | düşük-orta | Ayrı şerit `_cfgQueue` (eşzamanlılık 4); `whenIdle` ikisini bekler, `stop` ikisini boşaltır, `stats().safety_cfg_queue` | `device_reconciler.js` |
| RG-3: hırsız deseni sürerken komut bip'leri birikiyordu | düşük | `Buzzer_Open_Time` desen sürerken de yutar; desen/alarm başlarken FIFO boşaltılır. Simülatör `beep` aynı kural (kırmızı/yeşil test) | `WS_GPIO.{h,cpp}`, `automation.js` |

### Ertelenenler ve gerekçeleri

- **RV-E4 (PARTIAL, ürün kararı): kurulu kipte sensör arızası alarm ya da push üretmiyor.** B.2 bunu açıkça karar olarak yazdı
  ("`ok=false` kurulu kipte alarm üretmez"): kablolu NC kontakta kopma zaten "aktif" okunup alarm verir. Boşluk yalnız köprü (kablosuz) ve
  RS485 ek modül sensörlerinde, ikisi de bu sürümde sahada yok (somut köprü sürücüsü E.4'te açık). Kurulu kipte arızayı alarma ya da
  push'a çevirmek EN 50131 "tamper/fault" sınıfına ve yanlış alarm oranına dair ürün kararıdır (kablosuz denetim süresi, kaç kaçırılmış
  okuma); köprü sürücüsüyle birlikte ele alınacak. Bugün arıza `sensor_fault` olayıyla günlük ve denetim kaydına yazılıyor, kurmayı da
  engelliyor ("hazır değil").
- **RV-E5 (REFUTED, iyileştirme): giriş gecikmesinde hareket sensörü anında alarm veriyor.** Davranış B.1 tablosuyla aynıdır;
  kurulumcu hareket sensörüne `SF_ENTRY` atayarak (sihirbaz anahtarı) bunu zaten önleyebilir. EN 50131'deki "follow" (giriş yolunu izleyen)
  bölge türü yeni bir bayrak ve sihirbaz sorusu ister; sonraki hırsız katmanı iyileştirmesine bırakıldı.
- **RG-1, ek geri çekilme:** kök neden (upsert koşulu) giderildi. Kopya panodan farklı kaldığı sürece dakikalık `cfg_get` tasarım §4.2
  gereği sürer. Başka bir nedenle hiç yakınsamayan kopya için üstel geri çekilme bu turda eklenmedi; yeniden doğrulamada görülürse eklenir.
- **G-1, sunucunun kopyası bayatsa:** sunucunun ön reddi kopyaya göredir. Asıl karar panodadır (`gas_local_only` / `armed`), sunucu
  bu kodları `403` / `409`'a eşler ve kuyruktaki öğeyi düşürür. Kurulu kip bilgisi son canlı state'ten okunur: pano çevrimdışıyken
  kurulduysa kuyruk öğesi gönderimde firmware tarafından reddedilir.
- **R2, yankılı panoda yanlış "düşürme":** zaman aşımından sonra `last_id` başka bir komutla ezilmişse uygulanmış bir kuyruk öğesi "pano
  kazanır" kuralıyla düşer ve owner'a `cfg_pending_dropped` bilgisi gider. Bu güvenli yönde bir hatadır (yanlış "uygulandı" demez);
  kullanıcı adımı yeniden açınca güncel kopyayı görür.

### Bu turun test sonuçları

- Firmware Unity (MSVC 2022, `/W4`): 19 paket, **360 test**, 0 hata, derleme uyarısı 0. Yeni testler: `test_gas_release_rules`,
  `test_intrusion_loosening_rules` (`test_safety_cfg_edit`), `test_boot_restores_entry_delay`, `test_boot_entry_disarm_and_bad_record`
  (`test_intrusion_fsm`); `test_safety_config` NO anahtar reddi; `test_intrusion_fsm` `rejText(ARMED)`. Kırmızı kanıtı: önce derleme hatası (sembol yok), sonra
  boş saplamalarla 3 pakette davranış hataları (`isGasRelease` / `isIntrusionLoosening` beklenen `true`, `takeDirty` beklenen `true`,
  açılış durumu 2 yerine 0, `validate` 30 yerine 0).
- QA simülatörü (`tools/qa_stack`, `npm test`): **603/603** (önce 595). Yeni: Unity portları (+4), G-1a ve G-1b uçtan uca (MQTT `last_rej`
  `gas_local_only` / `armed`; vana ve rölesi uzaktan açılmaz; çözülüyken uygulanır; LAN serbest), RG-3 buzzer, ortak vektör sınıfları; I3
  `arm_key` senaryosu NC'ye güncellendi (NO -> `400 cfg_invalid arm_key_not_nc`). `fwcheck --update`: 64 kaynak.
- Sunucu `npm test`: **2270 test** (önce 2259). PG'siz 2113 geçti / 157 atlandı / 0 hata; PG'li (`evy_g2_ver`, 001..034) 2269 geçti / 1
  atlandı / 0 hata. Yeni: gevşetme portu G-1 sınıfları (ortak vektörler), `safety_cfg_sync` G-1a/G-1b/ret eşlemesi/R2 kuyruk/RG-2 şeridi,
  köprü R2/R3 (+lastId), gerçek PG RG-1.
- Fabrika aracı: **358/358**; `inspect_firmware_file` yeni imajda uyarısız, `FACTORYINIT` imzası bulundu.
- Flutter: `analyze` 0 sorun; `test` **4495 geçti**, 485 atlandı, 0 hata (önce 4492; yeni: R3 kopya bekleme + `base_rev`, `arm_key` NC saf mantık, G-1 hata metinleri; `arm_key` arayüz testi NC ve dedektör notu yokluğuyla genişledi).
- Firmware derleme (temiz, `G:\.platformio`, ağ yok): uyarı 0, RAM %20,9 (68624 B), Flash %39,9 (1256049 B). v1.2.1 ana imaj SHA-256
  `abe7f6852afdd387378395e403f82032300f3d4b850a7e01eb3d59508699f398`, uygulama SHA-256
  `68f300a44d92e77af2d45af72f41297f8f1f764dc25ec130d108bb4e0025fd40`, ELF SHA-256
  `e0f930caacaf7c462902f60d18246fcb251cabe262e6e1e8db71cd6b6b69ec7e`. 0x0000-0xFFFF bölgesi v1.2.0 ve v1.1.2 ile bayt bayt aynı.
  Önceki 1.2.1 paketinin özetleri (`f5d439bf…` / `f3fb8c41…`) geçersizdir. **Firmware DONANIMDA DOĞRULANMADI**; "İlk kartta denenecekler"
  listesine 11-14 eklendi (giriş gecikmesinde enerji kesintisi, NC anahtar kablosu, bulut yaması sınırları, desen sırasında bip).
