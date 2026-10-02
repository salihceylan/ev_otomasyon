# Akıcılık ve kilitlenmeme: GÜNCEL durum ve iş paketi planı (Dalga 5a)

> 2026-10-02 anlık görüntüsü. SALT-OKUNUR birleştirme: beş okuyucunun bulguları tekilleştirildi; kritik/yüksek ve belirsiz iddialar koordinatör tarafından kodu bizzat okuyarak yeniden doğrulandı.
> flutter / dart / gradle, emülatör, cihaz ve tarayıcı ÇALIŞTIRILMADI. Performans/raster cümleleri YAPISALDIR (ölçülmedi).
> Satır numaraları 2026-10-02 çalışma ağacına aittir ve ağaç hareketlidir: düzenlemeden önce çapa dizgesiyle yeniden bulun.
> Önceki ham denetim: `docs/superpowers/analysis/akicilik-denetimi.md` (PF-01..PF-26). Yollar `G:/site/ev_otomasyon` köküne göredir.
> Etiketler: **[K]** koordinatör kodu/kaynağı bizzat okudu; **[O]** okuyucu bulgusu, koordinatör doğrulamadı (uygulayıcı ilk adımda doğrular).

---

## 1. Özet

- **Eski 26 bulgu:** 6 çözüldü (PF-07, 10, 12, 22, 24, 26), 10 kısmen (PF-01, 04, 05, 06, 08, 11, 18, 21, 23, 25), 10 açık (PF-02, 03, 09, 13, 14, 15, 16, 17, 19, 20).
- **Yeni 26 kayıt** (PF-27..PF-52; tekilleştirildi, takma adlar §4'te). Toplam **46 açık kayıt**: 3 yüksek, 14 orta, 29 düşük. **Kritik kalmadı.**
- **Yüksek 3:** PF-01 (LAN yoklaması 401/403/423'te durmuyor), PF-02 (platform kanalı çağrıları süre sınırsız), PF-03 (ağ-öncelikli soğuk açılış).
- PF-02 denetimde "kritik"ti; "yüksek"e indirildi: açılış splash'ında 15 sn'lik kaçış var ve olasılık ölçülmedi. Ama sonuç gerçekten kurtarılamaz olabilir: depo askıdayken yeni giriş de `_handleAuthSuccess` içinde takılır (§6.2).
- Arayüzün büyük kısmı denetimden beri düzeldi: `select` tabanlı daraltma, üç durumlu yükleme/boş/hata fazları, "Hepsini Kapat" tek widget'ı, `TimedLoadingView`, AuthGate `select` + itilmiş rotaların kapatılması. Kalan iş çoğunlukla **durum/servis katmanında** ve **yeni yüzeylerde** (servis sihirbazı, Wi-Fi akışı, aile/devir diyalogları).
- **Denetimdeki iki varsayım çürüdü:** (a) "firmware portalında kilit yok / kapsam tanımsız" yanlış (`NetTime.h:181-193` AuthLimiter vardır); (b) PF-03 önerisi "SWR penceresinde `homesFromCache = true`" yanlış yönlendirirdi (`dashboard_states.dart:178` çevrimiçi kullanıcıya "Çevrimdışısınız" şeridi çıkarırdı).
- Çalışma ağacı büyük ölçüde **commit edilmemiş** (HEAD `8cf17c0` eski; 269 değişiklik girdisi). Bu yüzden her paket yalnız kendi `owner_files` yollarını stage etmeli (`git add -A` yok).

### Hızlı kazanımlar (risk/fayda sırası)

1. PF-01: restricted dalında koşulsuz bildirimi kaldır + 401/423'te yoklamayı durdur/duraklat (yalnız `automation_state.dart`, eklemeli).
2. PF-02: `SecureStorageService` / `BiometricAuthService` süre sınırları + `_doRefresh` içinde 3 sn'lik sınır (küçük, çakışmasız dosyalar).
3. PF-09: `_call` için toplam süre bütçesi (tek metot).
4. PF-03: önbellek-önce açılış + `_startRealtime` ile `refresh` eşzamanlı (≈15 satır).
5. PF-27: MQTT `transport.connect` için Clock tabanlı üst sınır (çakışmasız dosya).
6. PF-37 + PF-38: splash ve `TimedLoadingView` spinner'larını `RepaintBoundary`'ye al (birkaç satır).
7. PF-16 + PF-17 (kısmen): varlık diyeti (`pubspec` açık liste, 6 kullanılmayan PNG, logo boyutları) ve Android `NormalTheme` zemini.
8. PF-04: `_applyCloudSnapshot` yalnız değişimde bildirsin.
9. PF-40: sihirbaz buton dinlemesi yalnız değişimde bildirsin.

---

## 2. Doğrulama defteri

**[K] koordinatör okudu:** `automation_state.dart` (başlatma, yoklama, soğuk açılış, bulut yenileme, bildirimler, türetilmiş değerler, dispose), `secure_storage_service.dart`, `biometric_auth_service.dart`, `ev_cloud_api_service.dart` (`_sendRaw/_call/_doRefresh`), `ev_mqtt_service.dart` (`connect/_run`), `mqtt_client-10.11.11` kaynakları (kilit dosyasındaki sürüm; önbellekte 10.11.9 da var, ilgisiz), `automation_api_service.dart` (`LocalApiException`, `_check`, `_sendOnce`), `command_pipeline.dart`, `confirm_dialogs.dart`, `auth_gate.dart`, `apartment_dashboard.dart`, `dashboard_states.dart`, `connection_status.dart`, `status_pills.dart`, `endpoint_sections.dart`, `relay_switch_card.dart`, `dashboard_app_bar.dart`, `dashboard_page.dart`, `circuit_background.dart`, `app_theme.dart`, `main.dart`, `app_shell.dart`, servis sihirbazı (`setup_context`, `button_logic`, `shutter_logic`, `claim_logic`, `cloud_logic`, `handover_logic`, `service_setup_controller`, `service_setup_wizard_page`, `setup_problem`), `wifi_provision_panel`, `wifi_recovery_dialog`, `transfer_ownership_dialog`, `emergency_reset_card`, `replace_board_dialog`, `service_mode_page`, `service_management_page`, `cooldown`, `capabilities`, `cloud_models`, firmware `NetTime.h` + `WebPortal.cpp` (kaynak), sunucu `device_service.js` (claim), Android `res/`, `AndroidManifest.xml`, `assets/images` (boyut + md5), `pubspec.yaml`, `test/support/*`, sabitlenmiş testler (`automation_state_commands_test.dart` 540-727, `automation_state_session_test.dart` 1018-1211, `ev_mqtt_service_test.dart` 270-409), Flutter 3.47.2 SDK `page_transitions_theme.dart`.

**[O] doğrulanmadı (uygulayıcı kontrol eder):** `google_fonts` çalışma zamanı iç işleyişi (PF-14), PF-19 geçmişi (`fb78615`), dart:io `HttpClient` bağlantı denemesini iptal etmediği (PF-36), release derlemede kaynak küçültme davranışı (PF-17), YN-01/YN-02 ayrıntıları, NS-12, tüm raster/kare süresi iddiaları (PF-05, PF-15, PF-37), "bugün yeşil" kilit testlerinin gerçekten yeşil olduğu.

---

## 3. PF-01..PF-26 güncel durum

| ID | Eski | Güncel | Kanıt (özet) |
|---|---|---|---|
| PF-01 | kritik | **kısmen, yüksek** | UI: `TimedLoadingView` 15 sn + "Cihaz kontrol edilemiyor" kartı var (`apartment_dashboard.dart:310-333`). Durum: yoklama durmuyor (`automation_state.dart:2049`), 401'de `_connState` değişmiyor (2119-2126), 423 işlenmiyor, restricted dalı koşulsuz bildiriyor (2098-2102) |
| PF-02 | kritik | **açık, yüksek** | `_read`: `return await _store.read(key);` try/catch askıyı yakalamaz (`secure_storage_service.dart:87-93`); `.timeout(` servis/durum/biyometrik dosyalarında yok |
| PF-03 | yüksek | **açık, yüksek** | `await fetchHomes(autoSelect: false);` `authenticated`'dan önce (`automation_state.dart:1414-1416`); önbellek yalnız ağ hatasından sonra (1465-1467) |
| PF-04 | yüksek | **kısmen, düşük** | LAN: `changed = previous == null \|\| !previous.sameAs(st);` (2104) ve değişim-koşullu bildirim (2138) tamam. Bulut: `_applyCloudSnapshot` koşulsuz (2036-2038), `_loadEndpoints` koşulsuz `observe` (1880), REST yağmuru 4-5 bildirim |
| PF-05 | yüksek | **kısmen, düşük** | Kök artık izlemiyor (`dashboard_page.dart:45`), bileşenler kendi `select`lerini yapıyor. Kalan: kartlar tek katmanda, projede tek `RepaintBoundary` (`circuit_background.dart:68`) |
| PF-06 | yüksek | **kısmen, düşük** | `ShutterCard/RelaySwitchCard/QuickScenarioBar/DeviceSettingsPage` `select`e geçti. Kalan: 18 `context.watch<AutomationState>()` (ikincil sayfa/diyalog), kart başına `relayItems` türetimi |
| PF-07 | yüksek | **çözüldü** | `apartment_dashboard.dart:60` `if (s.homesLoaded) return ApartmentPhase.homeless;`; `TimedLoadingView` (`dashboard_states.dart:18-97`); karşılama kartı yalnız owner + başarılı boş yanıt (242-244) |
| PF-08 | yüksek | **kısmen, düşük** | `CloseAllLightsButton`: `_busy` + try/finally + gerçek sayı (`close_all_lights_button.dart:34-67`). Kalan: mod düğmesi `_toggleMode` yeniden girişe açık (`dashboard_app_bar.dart:286-303`) |
| PF-09 | orta | **açık, orta** | `_call`: `_sendRaw` (288) + `_refreshSingleFlight` (297) + yeniden `_sendRaw` (305), toplam sınır yok |
| PF-10 | orta | **çözüldü** | `_onResult`: `_restartConfirmTimer(entry)` (`command_pipeline.dart:432`); `maxTotal` 10 sn (365-374); `CONTRACTS.md:475` |
| PF-11 | orta | **kısmen, orta** | UI: hata kartı + elle "Yeniden dene". Otomatik yeniden deneme yok; `_loadDevices` hatayı yutuyor (`automation_state.dart:1905-1907`), `presence == unknown` -> `connecting` (318-319) |
| PF-12 | orta | **çözüldü** (çalışma ağacında) | `main.dart:63` `const AppShell(home: AuthGate())`; `auth_gate.dart:53` "sabit bir bekleme süresi yoktur". HEAD'de hâlâ `minSplashDuration: Duration(milliseconds: 2600)` var: commit edilmeden kaybolabilir. Artık: 350 ms çapraz geçiş (PF-18/WP-BOOT) |
| PF-13 | orta | **açık, düşük** | 8 ardışık kanal turu: `automation_state.dart:583,604-605,613-616,623` |
| PF-14 | orta | **açık, orta (karar bekler)** | `GoogleFonts.interTextTheme(...)` (`app_theme.dart:177,261`); `pubspec.yaml` `fonts:` bölümü yok |
| PF-15 | orta | **açık, orta** | `circuit_background.dart:24-77` üç tam ekran statik katman + yalnız painter sarılı; `device_inventory_page.dart:211-231` ve `service_management_page.dart:356-398` opak Scaffold içinde ikinci `CircuitBackground` |
| PF-16 | orta | **açık, orta** | lib'de `cacheWidth/cacheHeight/ResizeImage` yok; 1024² logolar 28-130 dp'de; `app_logo.png` == `round_app_logo.png` (md5 `b233994f...`); 6 kullanılmayan PNG = 6.558.365 B |
| PF-17 | orta | **açık, orta** | `launch_background.xml` `gravity=fill` 2.402.557 B bitmap; `NormalTheme` `?android:colorBackground`; `splash_bg` kullanılmıyor; `splash_bg_circuit.png` (2.780.093 B) + `splash_logo.png` referanssız |
| PF-18 | orta | **kısmen, düşük** | Flutter 3.47.2 Android varsayılanı `PredictiveBack` -> `FadeForwards` (`page_transitions_theme.dart:766`), çıkan sayfaya opak `ColorScheme.surface` perdesi (541-552) |
| PF-19 | orta | **açık, orta (cihaz)** | `EnableImpeller=false` (`AndroidManifest.xml:22-25`), saha gerekçesi `fb78615` [O] |
| PF-20 | orta | **açık, düşük** | `relayItems/shutterItems/capabilities` önbelleksiz (`automation_state.dart:382-389,398-417`); `Capabilities.==` iki 32'lik Map kurar (`capabilities.dart:490-491`) |
| PF-21 | düşük | **kısmen, düşük** | AuthGate `context.select<AutomationState, AuthGateView>(gateViewFor)` (`auth_gate.dart:139`), debug çıktısı yok. Kalan: splash `context.watch` (193) |
| PF-22 | düşük | **çözüldü** | `auth_gate.dart:96-98` `_closePushedRoutes`; pano görünümünden çıkışta itilmiş rotalar kapanıyor |
| PF-23 | düşük | **kısmen, düşük** | Denetleyici sızıntısı çözüldü; `Cooldown` her saniye tüm diyaloğu `setState` ile kuruyor (`cooldown.dart:42-53`) |
| PF-24 | düşük | **çözüldü** | lib'de 6 `debugPrint` çağrısı, hepsi `kDebugMode` korumalı ve yalnız tür/sayı yazar; QR ham içeriği yok |
| PF-25 | düşük | **kısmen, düşük** | `MediaQuery.of` kalmadı. Kalan: `shutterBaseName` her çağrıda `RegExp` (`cloud_models.dart:253`), `labels.dart:19,38,59,97`, build içinde `DateFormat` (6 yer) |
| PF-26 | düşük | **çözüldü** | `catchError` yalnız `biometric_prompt_dialog.dart:101` (bilinçli); servis yönetimi hata kartı + "Tekrar Dene" var (küçük kalıntı: `fetchPeaceNotification` hatayı yalnız loglar) |

---

## 4. Yeni kayıtlar ve takma adlar (tekilleştirme)

| Yeni ID | Takma adlar | Konu |
|---|---|---|
| PF-27 | YENI-01, GK-04 | MQTT TCP/TLS bağlanması süre sınırsız |
| PF-28 | YENI-02 | MQTT geri çekilme sayacı kısa ömürlü bağlantıda sıfırlanıyor |
| PF-29 | YENI-03, GK-02 | `_initInner` oturum nesli/dispose denetlemiyor |
| PF-30 | YENI-04, GK-03 | `_unlockWithBiometrics`/`toggleBiometric` nesil denetimi ve askıdaki istem |
| PF-31 | NS-05, GK-01, NEW-E | `confirmAndLogout` global `_logoutRunning` bayrağı kilitlenebiliyor |
| PF-32 | YENI-05 | LAN tek-uçuş adres/anahtar değişimini bilmiyor |
| PF-33 | YENI-06 | LAN telemetri kartı donuyor; `_childLockUpdatedAt` yalnız değişimde |
| PF-34 | YENI-07 | Dispose sonrası zamanlayıcı/MQTT kurulabiliyor |
| PF-35 | YENI-08 | Ev önbelleği her başarılı `fetchHomes`'ta yeniden yazılıyor |
| PF-36 | GK-05 | Varsayılan `http.Client`'ta `connectionTimeout` yok (LAN) |
| PF-37 | NEW-A, YN-03 | Splash spinner'ı tüm sayfayı her karede boyatıyor |
| PF-38 | NEW-B | `TimedLoadingView` zaman aşımından sonra da dönüyor |
| PF-39 | NEW-F | Giriş diyalogları ev yüklemesi bitene kadar açık kalıyor |
| PF-40 | NS-01, GK-06 | Duvar butonu dinlemesi 5 Hz koşulsuz bildirim |
| PF-41 | NS-02 | Sihirbazdan çıkışta panjur ölçüm süresi geri yüklenmeyebiliyor |
| PF-42 | NS-03 | Claim yanıtı kaybolursa kör "Tekrar dene" çıkmaza sokuyor |
| PF-43 | NS-04 | Wi-Fi paneli `onDeviceChecked` zaman aşımsız (PF-02'ye bağlı) |
| PF-44 | NS-06 | Tek seferlik sırlı sonuçlar ağ yenilemesi bitene kadar verilmiyor |
| PF-45 | NS-07 | Acil sıfırlama sekmesi kör tekrar + belirsiz sonuç yok |
| PF-46 | NS-08 | Pano değişimi diyaloğu işlem sürerken kapatılabiliyor |
| PF-47 | NS-09 | Servis paneli girişlerinde çift dokunuşla çift sihirbaz |
| PF-48 | NS-10 | Sihirbazda bağımsız LAN ve REST istekleri ardışık |
| PF-49 | NS-11 | Hesap listesi tembel değil (eager `ListView`) |
| PF-50 | NS-12 | Katıl/devir/etiket yeniden üretimi: uzun, ilerlemesiz kilit |
| PF-51 | YN-01 | `MaterialApp` yerelleştirme yok (zaman seçici İngilizce/AM-PM) |
| PF-52 | YN-02 | iOS/web beyaz açılış ve yer tutucu metinler; Android etiketi ham paket adı |

NEW-C (LAN 401'de sebep arayüzde görünmüyor) ayrı kayıt değildir: PF-01'in arayüz yarısıdır ve PF-01'in önerilen tasarımıyla (bağlı + durum yok) kendiliğinden çözülür.

---

## 5. Açık bulgular: önem sırası

Sütunlar: **Paket** = §8'deki iş paketi. Ayrıntı blokları §6'dadır.

| # | ID | Önem | Durum | Yer (dosya:satır) | Kök neden (kısa) | Paket |
|---|---|---|---|---|---|---|
| 1 | PF-01 [K] | yüksek | kısmen | `automation_state.dart:2049-2053, 2085-2103, 2117-2131, 1748-1759`; `apartment_dashboard.dart:310-314`; `connection_status.dart:86-105` | Yoklama hata türünden bağımsız sabit periyotlu: 401/403/423'te durmuyor, 401'de `connecting`'de kalıyor, 423 işlenmiyor, restricted dalı koşulsuz bildiriyor | WP-STATE (+WP-DASH rozet) |
| 2 | PF-02 [K] | yüksek | açık | `secure_storage_service.dart:87-109,222-228`; `biometric_auth_service.dart:15-36,63-76`; `automation_state.dart:582-627,750-781,1258,1359-1367,1378-1387`; `ev_cloud_api_service.dart:388-391` | Platform kanalı çağrıları (depo, biyometrik sonda) süre sınırsız; seri kuyruğa ve tek-uçuş yenilemeye bağlı | WP-INFRA, WP-STATE, WP-CLOUD-API, WP-UI-DIALOGS |
| 3 | PF-03 [K] | yüksek | açık | `automation_state.dart:1414-1417,1465-1467,1573-1574,1046-1048,1637-1638` | Soğuk açılış ağ-öncelikli; saklı erişim jetonu çoğu açılışta bitmiş (15 dk): 401 -> refresh -> yeniden = 3 ardışık tur | WP-STATE |
| 4 | PF-09 [K] | orta | açık | `ev_cloud_api_service.dart:288,297,305,361-367` | Toplam süre sınırı yok (GET en kötü 10+10+10 sn; komut 8+10+8; claim 20+10+20) | WP-CLOUD-API |
| 5 | PF-27 [K] | orta | yeni | `ev_mqtt_service.dart:154,173,469`; `mqtt_client` `...connection_handler.dart:116`, `mqtt_client.dart:94-98` | `connectTimeoutPeriod` yalnız CONNACK beklemesi; soket/TLS kurulumu sınırsız (`socketTimeout` null) | WP-NET |
| 6 | PF-37 [K] | orta | yeni | `auth_gate.dart:356-363, 239-240, 263, 290` | Sonsuz dönen spinner `RepaintBoundary`siz; sayfa (tam ekran JPEG + 3 büyük blur gölge) Skia'da her karede yeniden kaydediliyor [yapısal] | WP-BOOT |
| 7 | PF-40 [K] | orta | yeni | `button_logic.dart:55,139,153-163`; `service_setup_wizard_page.dart:224-226` | 200 ms yoklamada koşulsuz `ctx.notify()`; `ListenableBuilder` tüm Scaffold'u 5 Hz kuruyor | WP-SETUP |
| 8 | PF-41 [K] | orta | yeni | `shutter_logic.dart:451-495,634-647`; `service_setup_controller.dart:330-339`; `setup_context.dart:337-338`; `service_setup_wizard_page.dart:106-142` | Hazırlık sürerken çıkış: `settleMeasurements` `run` meşgulken `false` döner, `previousSeconds` yalnız sonda kaydedilir -> 300 sn ölçüm süresi panoda kalabilir | WP-SETUP |
| 9 | PF-11 [K] | orta | kısmen | `automation_state.dart:1858-1908, 318-319`; `connection_status.dart:129-133`; `cloud_models.dart:310,353` | Otomatik yeniden deneme yok; `devices()` hatası görünmez; `device_online` uç noktada geliyor ama kullanılmıyor | WP-STATE |
| 10 | PF-42 [K] | orta | yeni | `claim_logic.dart:103-171,173-268`; `setup_context.dart:354-362`; `uncertain_outcome_card.dart:37`; `device_service.js:678` | Tek kullanımlık OTP/PIN tüketen claim POST'u ağ hatasında "Tekrar dene"ye bağlı; sunucu CLAIMED cihazı reddeder | WP-SETUP |
| 11 | PF-16 [K] | orta | açık | 11 `Image.asset`; `assets/images/**`; `pubspec.yaml:72-73` | `cacheWidth` yok, 4 MiB/çözüm; yinelenen logo; 6 kullanılmayan PNG APK'da | WP-BOOT |
| 12 | PF-17 [K] | orta | açık | `android/app/src/main/res/{drawable,drawable-v21}/launch_background.xml`; `values*/styles.xml` | 2,4 MB tam ekran bitmap `gravity=fill`; `NormalTheme` zemini açık/koyu gri (`splash_bg` kullanılmıyor); referanssız 2,9 MB | WP-BOOT |
| 13 | PF-15 [K] | orta | açık | `circuit_background.dart:24-77`; `device_inventory_page.dart:211-231`; `service_management_page.dart:356-398`; `auth_gate.dart:196-222`; `login_page.dart:160-186` | Statik katmanlar tek sınırda değil; opak sayfalarda genel + iç arka plan birlikte çiziliyor | WP-BOOT (+WP-SVC-PAGES) |
| 14 | PF-45 [K] | orta | yeni | `transfer_ownership_dialog.dart:343-361,396-397` | Acil sıfırlama sekmesi: zaman aşımı/belirsiz sonuç yok; ağ hatasında "tekrar deneyin" (yeni PIN üretebilir) | WP-UI-DIALOGS |
| 15 | PF-14 [O] | orta | açık | `app_theme.dart:160-177,244-261`; `pubspec.yaml` | Yazı tipi çalışma zamanında ağdan; 600-900 ağırlık yok | **ertelendi** (karar) |
| 16 | PF-19 [O] | orta | açık | `AndroidManifest.xml:22-25` | Skia/Impeller seçimi cihaz profili gerektirir | **ertelendi** (cihaz) |
| 17 | PF-51 [O] | orta | yeni | `app_shell.dart:216-234`; `pubspec.yaml:39` | Yerelleştirme delegeleri yok; `flutter_localizations` + `intl ^0.20.3` gerekir | **ertelendi** (bağımlılık) |
| 18 | PF-04 [K] | düşük | kısmen | `automation_state.dart:2010-2039,1858-1944,2098-2102` | Bulut anlık görüntüsü ve REST yükleyicileri koşulsuz bildiriyor | WP-STATE |
| 19 | PF-20 [K] | düşük | açık | `automation_state.dart:308,382-389,398-417,509,520-524`; `capabilities.dart:489-494` | Türetilmiş değerler önbelleksiz; `Capabilities.==` Map kuruyor | WP-STATE |
| 20 | PF-06 [K] | düşük | kısmen | 18 `context.watch` yeri (§8.6-8.9) | İkincil sayfa/diyalog köklerinde tüm durumu izleme | WP-UI-DIALOGS, WP-SVC-PAGES, WP-SETUP, WP-BOOT |
| 21 | PF-13 [K] | düşük | açık | `automation_state.dart:583,604-627` | Bağımsız okumalar ardışık; oturumsuz açılışta da biyometrik sonda | WP-STATE |
| 22 | PF-29 [K] | düşük | yeni | `automation_state.dart:582-675` | `_initInner` `_sessionEpoch`/`_isDisposed` denetlemiyor | WP-STATE |
| 23 | PF-30 [K] | düşük | yeni | `automation_state.dart:1058-1083,1092-1105,986-998` | `authenticate` sonrası nesil denetimi yok; `toggleBiometric` epoch'u await'ten SONRA okuyor; askıdaki istem için kaçış yok | WP-STATE |
| 24 | PF-31 [K] | düşük | yeni | `confirm_dialogs.dart:276,284,336-346` | `logout()` askıda kalırsa `_logoutRunning` hiç sıfırlanmaz (PF-02 çözülünce büyük ölçüde kapanır) | WP-UI-DIALOGS |
| 25 | PF-39 [K] | düşük | yeni | `automation_state.dart:1320-1373` | `_handleAuthSuccess` `await fetchHomes()` (otomatik ev seçimi + REST + MQTT) bitene kadar diyalogları açık tutuyor | WP-STATE |
| 26 | PF-28 [K] | düşük | yeni | `ev_mqtt_service.dart:490,520` | Bağlanır bağlanmaz `attempt = 0`; kopmada hep `_backoff(0)` | WP-NET |
| 27 | PF-32 [K] | düşük | yeni | `automation_state.dart:2058-2067,1660-1731` | Tek-uçuş eski adrese giden isteği yeni adres için devralıyor | WP-STATE |
| 28 | PF-33 [K] | düşük | yeni | `info_cards.dart:112`; `automation_state.dart:2104-2113` | `sameAs` uptime/RSSI'yi yok sayıyor: ayarlar telemetri kartı donuyor | WP-STATE |
| 29 | PF-34 [K] | düşük | yeni | `automation_state.dart:2045-2054,2145-2150,1959-1981,1587-1604,1312-1318` | Beş giriş noktası `_isDisposed` denetlemiyor | WP-STATE |
| 30 | PF-35 [K] | düşük | yeni | `automation_state.dart:1459,1478-1482` | Her başarılı `fetchHomes` ev listesini tümden güvenli depoya yazıyor | WP-STATE |
| 31 | PF-36 [O] | düşük | yeni | `automation_api_service.dart:107,344-361` | Varsayılan istemcide `connectionTimeout` yok | WP-NET |
| 32 | PF-38 [K] | düşük | yeni | `dashboard_states.dart:66` | `TimedLoadingView` spinner'ı zaman aşımından sonra da döner | WP-DASH |
| 33 | PF-05 [K] | düşük | kısmen | `endpoint_sections.dart:317-337` | Kartlar tek katmanda (`CardGrid` içinde sınır yok) [yapısal] | WP-DASH |
| 34 | PF-08 [K] | düşük | kısmen | `dashboard_app_bar.dart:286-303` | `_toggleMode` yeniden girişe açık, ilerleme göstermiyor | WP-DASH |
| 35 | PF-18 [K] | düşük | kısmen | `app_theme.dart` (pageTransitionsTheme yok) | Opak surface perdesi + arka plan geri sıçraması | **ertelendi** (görsel onay) |
| 36 | PF-21 [K] | düşük | kısmen | `auth_gate.dart:193` | Splash `context.watch` | WP-BOOT |
| 37 | PF-23 [K] | düşük | kısmen | `cooldown.dart:42-53`; `phone_otp_dialog.dart:54-59`; `forgot_password_dialog.dart:62-67`; `claim_manual_dialog.dart:126-138` | Geri sayım her saniye tüm diyaloğu kuruyor | WP-UI-DIALOGS |
| 38 | PF-25 [K] | düşük | kısmen | `cloud_models.dart:253`; `labels.dart:19,38,59,97`; `DateFormat` 6 yer | Sıcak yolda `RegExp`/`DateFormat` her çağrıda | WP-STATE, WP-DASH, WP-SETUP, WP-SVC-PAGES |
| 39 | PF-43 [K] | düşük | yeni | `wifi_provision_panel.dart:185`; `wifi_recovery_dialog.dart:107` | `onDeviceChecked` -> `getLocalKey` sınırsız (PF-02 çözülünce büyük ölçüde kapanır) | WP-UI-DIALOGS |
| 40 | PF-44 [K] | düşük | yeni | `automation_state.dart:2938-2945,2862,2971` | Sırlı sonuç `fetchHomes`/`refresh` bitene kadar döndürülmüyor | WP-STATE |
| 41 | PF-46 [K] | düşük | yeni | `replace_board_dialog.dart:32-41,219-230,356-362` | Diyalog işlem sürerken kapatılabiliyor; tek seferlik sonuç atılıyor | WP-SVC-PAGES |
| 42 | PF-47 [K] | düşük | yeni | `service_mode_page.dart:56-74`; `service_tool_cards.dart:37-39` | Çift dokunuşta çift sihirbaz rotası | WP-SVC-PAGES, WP-SETUP |
| 43 | PF-48 [K] | düşük | yeni | `cloud_logic.dart:138-142`; `handover_logic.dart:148-151`; `shutter_logic.dart:197-198` | LAN + REST ardışık bekleniyor | WP-SETUP |
| 44 | PF-49 [K] | düşük | yeni | `service_management_page.dart:424-444,620-636` | Eager `ListView` + her build'de `freezeBlock` | WP-SVC-PAGES |
| 45 | PF-50 [O] | düşük | yeni | `join_home_dialog.dart`; `transfer_ownership_dialog.dart`; `device_inventory_page.dart` | Uzun busy kilidi, ilerleme göstergesi yok | WP-UI-DIALOGS, WP-SVC-PAGES |
| 46 | PF-52 [O] | düşük | yeni | `ios/Runner/Base.lproj/LaunchScreen.storyboard`; `web/index.html`; `AndroidManifest.xml:16` | Beyaz iOS/web açılış; yer tutucu metin; ham etiket | **ertelendi** |

---

## 6. Ayrıntılı kayıtlar (yüksek ve seçili orta)

### 6.1 PF-01: LAN yoklaması durmuyor (yüksek, kısmen)

**Kanıt [K].**
- `automation_state.dart:2049-2053`: `_pollTimer = clock.periodic(_directPollInterval, (_) { ... unawaited(_directRefresh(silent: true)); })`. Durma/geri çekilme yok.
- 401/403-unprovisioned (2119-2126): `_directError = e.message; _directFailures = 0;` ve tek `_resolveLocalKey(forceRefresh: true)`. `_connState` hiç değişmez; başlangıç değeri `connecting` (176; 848, 1627, 1672'de de). Arayüz: `else if (vm.conn == ConnectionStateEnum.connecting) { body = TimedLoadingView(message: 'Cihaza bağlanılıyor…' ...` (`apartment_dashboard.dart:310-312`); rozet "Bağlanıyor…" (`connection_status.dart:100-105`). 15 sn sonra yalnız "Yeniden dene" çıkar, anahtar sorunu hiç görünmez.
- 423: `LocalApiException.isLocked/retryAfter` var (`automation_api_service.dart:64,31`) ama `automation_state.dart` kullanmıyor. Genel dala düşer (2127-2131): `_directFailures++; if (!silent || _directFailures >= 3) _connState = ConnectionStateEnum.offline;` -> ≈4,5 sn sonra yanıltıcı "Yerel Wi-Fi ağına bağlı olduğunuzdan emin olun" kartı; yoklama 1,5 sn'de sürer.
- restricted (anahtarsız özet) dalı: `if (epoch == _homeEpoch) { _endpointView = null; notifyListeners(); } return;` (2098-2102) koşulsuz: anahtar yokken yoklama sonsuz + 0,67 Hz bildirim. Oturumsuz yerel kullanıcıda (`isAuthenticated` false) anahtar yenileme hiç denenmez.
- `setLocalKey` (1748-1759) yoklamayı tetiklemiyor, yalnız bildirir.
- **Firmware (kaynak okundu, cihazda denenmedi):** `NetTime.h:181-193` AuthLimiter: IP başına 5 yanlış anahtar -> 60 sn `423`; 60 sn'de 20 hata -> 60 sn GENEL kilit. `WebPortal.cpp` `checkKey`: anahtarsız istek sayılmaz (`MISSING`), kilitliyken istek sayılmaz. Sonuç: bayat anahtarlı tek telefon 5 hatayı ≈7,5 sn'de doldurup ~60 sn kilitli kalır ve döngüyü sürdürür; ≥4 bayat istemci genel kilidi tetikleyip doğru anahtarlıları da dışarıda bırakabilir.

**Kök neden.** Yoklama hata türünden bağımsız, sabit periyotlu; "kalıcı" (401/403) ve "süreli" (423) koşullar ayrıştırılmıyor.

**En küçük güvenli düzeltme** (yalnız `automation_state.dart`, eklemeli; `AuthStatus` ve `ConnectionStateEnum`'a değer EKLENMEZ):
1. Alanlar `bool _pollHalted`, `DateTime? _pollNotBefore`; getter'lar `bool get directNeedsKey`, `DateTime? get directBlockedUntil`.
2. `_startPolling` geri çağrısı başında: `if (_isDisposed || _mode != AppMode.direct || _inBackground || _pollHalted) return; final nb = _pollNotBefore; if (nb != null && clock.now().isBefore(nb)) return;` (tek periyodik zamanlayıcı ve tek-uçuş korunur).
3. 401/unprovisioned: mevcut tek `_resolveLocalKey(forceRefresh: true)`'ten sonra anahtar DEĞİŞMEDİYSE (veya yenileme yapılamadıysa: `_localKeyRefreshTried` zaten true / oturumsuz / yetkisiz): `_status = null; _connState = ConnectionStateEnum.connected; _pollHalted = true; changed = true;` ("cihaza ulaşıldı", restricted dalıyla aynı anlam). **`offline` YAPILMAZ**: `automation_state_commands_test.dart:696-703` ("anahtar reddi (401): çevrimdışı sayılmaz", `directError` 'anahtar' içerir) bunu sabitler. Anahtar değiştiyse durdurma yok (ikinci 401'de durur).
4. 423 için yeni dal (genel `else`'ten önce): `_directFailures = 0; _connState = connected; _status = null; _directError = e.message; _pollNotBefore = clock.now().add((e.retryAfter ?? const Duration(seconds: 60)) + const Duration(seconds: 1));`.
5. restricted dalı: `directApi.localKey` hâlâ boşsa `_pollHalted = true`; koşulsuz bildirim yerine dalın sonunda mevcut ortak koşula düş (2136-2142: `changed || _connState != beforeConn || _directError != beforeError`).
6. `_resumeDirectPolling()` (`_pollHalted = false; _pollNotBefore = null;`) çağrı noktaları: `_startPolling()` başı (ön plana dönüş/mod değişimi), `setLocalKey` (+ `unawaited(refresh(silent: true))`, `directApi.localKey` atamasından HEMEN sonra, depo beklenmeden), `selectDevice`, `updateSelectedDeviceUuid`, `setHost`, `updateSelectedDeviceIp`, `refresh(silent: false)` (kullanıcının "Yeniden dene"si).
7. Arayüz (WP-DASH, WP-STATE'ten sonra): `connectionBadgeOf` `directBlockedUntil != null` iken "Cihaz geçici kilitli" göstersin; yoksa 423'te `connected + directError` -> "Cihaz anahtarı gerekli" (`connection_status.dart:86-92`) yanıltıcı olur. Kart zaten `vm.error` metnini gösterir ("...kilitlendi. Biraz bekleyin.").
8. `docs/CONTRACTS.md` §5'e tek satır (belge önce): "LAN yoklaması 401/403(unprovisioned)/423'te durur; 423'te Retry-After kadar bekler; kullanıcı eylemi / ön plana dönüş sürdürür."
9. Bu dalgada AĞ hatası geri çekilmesi (üstel/jitter) YOK (§10).

**Test** (`StateHarness` + `FakeClock` + `directMock`; `test/services/automation_state_commands_test.dart` `directHarness()` kalıbı):
- 401: `h.directMock.on('GET','/api/status',(r)=>jsonResponse(<String,dynamic>{'error':'unauthorized'}, status: 401)); h.directMock.requests.clear(); await h.clock.elapse(const Duration(seconds: 60));` -> `count('GET','/api/status') <= 3`, `directNeedsKey == true`, `connState != offline`, `directError` 'anahtar' içerir. Sonra 200 yanıtı + `await h.state.setLocalKey('devicekey-5678'); await h.clock.elapse(const Duration(seconds: 2));` -> `status != null`, `directNeedsKey == false`.
- 423: `jsonResponse(<String,dynamic>{'error':'locked','retry_after':60}, status: 423, headers: <String,String>{'Retry-After':'60'})`: ilk 59 sn'de YALNIZ 1 istek, `directBlockedUntil != null`, `elapse(3 sn)` sonrası +1 istek, `connState` offline OLMAZ.
- restricted: `h.direct.localKey = null` + `{'device':'AHBU-S3-TEST01','name':'Pano','fw':'1.1.0','provisioned':true,'wifi_connected':true}`; `addListener` sayacı: `elapse(30 sn)` -> bildirim `<= 1`, istek `<= 2`, `directNeedsKey == true`.
- Widget: 401 sonrası `ApartmentDashboard` (direct) `find.text('Cihaz kontrol edilemiyor')` görünür, `loading_view` yok.

**Risk/sözleşme.** Pinli: `automation_state_commands_test.dart:636-660` (3 hata -> offline; başarıda 1,6 sn içinde toparlanma: ağ hatası aralığı değişmediği için geçer), 662-668, 670-694 (tek-uçuş), 696-703. e1 testleri `Cihaza bağlanılıyor…`/`Cihaza ulaşılamıyor` 401/423 kullanmıyor. Davranış değişikliği: 401/423'te `status` null olur (bayat kontrol kartları kalkar); kullanıcı "Yeniden dene" ile sürdürür. Servis sihirbazının `deviceCall` yolu ayrı API örneği kullanıyor görünüyor (`setup_context.dart:225-250`); uygulayıcı doğrular.

### 6.2 PF-02: platform kanalı çağrıları süre sınırsız (yüksek, açık)

**Kanıt [K].**
- `secure_storage_service.dart:87-93`: `try { return await _store.read(key); } catch (e) { throw SecureStorageException('read', e); }`. try/catch askıyı yakalamaz; `_write/_delete/clearAll` aynı. `.timeout(` yalnız HTTP çağrılarında var (`automation_api_service.dart:354`, `ev_cloud_api_service.dart:170`); `secure_storage_service.dart`, `biometric_auth_service.dart` ve `automation_state.dart` içinde hiç yok (`ev_mqtt_service.dart:193` yalnız paketten gelen `TimeoutException`'ı yakalar).
- `biometric_auth_service.dart:17-18`: `final canCheck = await _auth.canCheckBiometrics; final isSupported = await _auth.isDeviceSupported();` sınırsız; `authenticate` bunu da çağırıyor (44).
- `_initInner`: `SharedPreferences.getInstance()` (583), iki biyometrik tur (604-605), dört depo okuması (613-616), bayrak okuması (623) ardışık; `_init`'in try/catch'i askıyı yakalayamaz (569-580).
- `_enqueueStorage` seri kuyruk, işlem sınırı yok: `final run = _storageQueue.then((_) async { ... await operation();` (750-765). Takılan tek işlem sonrakileri bloklar: `logout` (`await _enqueueStorage(() => secureStorage.clearAll());` 1384), `setLocalKey` (1756), `localKeyFor` (1785), `changePassword` (1258).
- `_doRefresh`: `final callback = onTokenRefreshed; if (callback != null) { await callback(access, newRefresh);` (`ev_cloud_api_service.dart:388-391`) -> `_onTokenRefreshed` `_enqueueStorage`'a bağlı (773-781): takılı yazım `_refreshInFlight`'i ve bekleyen TÜM 401 yeniden denemelerini sonsuza dek bloklar.
- `_handleAuthSuccess` (1359-1367): `isBiometricPromptShown` + iki biyometrik sonda `fetchHomes()`'tan ÖNCE, korumasız. Yani depo askıdayken yeni giriş de takılır.
- Arayüz kaçışları: splash'ta yalnız `if (_slow && !state.biometricChecking)` (`auth_gate.dart:375`); `confirmAndLogout`: `_logoutRunning = true; try { await state.logout(); ... } finally { _logoutRunning = false; }` (`confirm_dialogs.dart:336-346`): `logout` askıdaysa bayrak kalıcı true, sonraki tüm "Çıkış" dokunuşları `if (_logoutRunning) return false;` (284) ile sessizce ölü.
- Referans iyi örnek: `board_network_binding.dart:497-501` `_invoke` Clock zamanlayıcılı üst sınır.

**Kök neden.** Platform kanalı await'lerinde üst sınır yok; sınırsız await'ler seri kuyruğa ve tek-uçuş yenilemeye bağlanmış.

**En küçük düzeltme (katmanlı, hepsi küçük):**
1. `lib/services/clock.dart`: `extension ClockBound on Clock { Future<T> bound<T>(Future<T> future, Duration limit, T Function() onTimeout) }`. Zamanlayıcı Clock'tan (FakeClock ile deterministik); zamanlayıcı iptal edilir; geç dönen sonuç/hata YUTULUR (aksi halde `main.dart` `onError`'a düşer); eşzamanlı istisnalar iletilir.
2. `SecureStorageService`: `Clock clock = const SystemClock()`, `Duration opTimeout = const Duration(seconds: 6)` (5-8 sn bandı; soğuk Keystore ilk okuma payı); `_read/_write/_delete/clearAll` içinde `bound` -> `SecureStorageException(op, TimeoutException(...))`. `SecureKeyValueStore` arayüzüne üye EKLENMEZ (`InMemorySecureStore implements` ediyor).
3. `BiometricAuthService`: `isBiometricSupported/getAvailableBiometrics` için 3 sn (Clock tabanlı; false / `[]`). Etkileşimli `_auth.authenticate`'e ASLA sınır konmaz.
4. `AutomationState` kurucusu: `secureStorage ?? SecureStorageService(clock: clock ?? const SystemClock())` ve biyometrik servis aynı. `_handleAuthSuccess` üç sondayı `Future.wait` ile paralel yapsın; **unawaited YAPILMAZ**: `DashboardPage` `shouldPromptBiometrics`'ı `initState` postFrame'inde BİR kez okur (`dashboard_page.dart:34-40`) ve bildirim 1368'dedir (ilk giriş biyometrik istemi kaçar).
5. `EvCloudApiService._doRefresh`: `await callback(access, newRefresh)` -> Clock tabanlı 3 sn sınır (belirteçler zaten bellekte; yazım arka planda sürer; sonraki `generation != _generation` denetimi aynen) (WP-CLOUD-API).
6. `confirmAndLogout`: `await state.logout().timeout(const Duration(seconds: 10))` ek emniyet (2. adımla `logout` ≈6-7 sn'de biter) (WP-UI-DIALOGS).
7. Kuyruk düzeyinde ek `operation().timeout` GEREKMEZ (2. adım her işlemi sınırlıyor). `_init` bekçisi isteniyorsa YALNIZ platform fazını kapsamalı (token/bayrak okuması ve sonda); `_startSession` ağ fazını KAPSAMAMALI, aksi halde yavaş ağda (3x10 sn) oturum yanlışlıkla düşer (§7 G12).

**Test.** `InMemorySecureStore` `hangReads/hangWrites/hangDeleteAll` (Completer) + `FakeStorage(clock:)` (WP-INFRA):
- `SecureStorageService(store: hang, clock: fake)`: `read` -> `clock.elapse(7 sn)` sonra `SecureStorageException('read', TimeoutException)`; write/delete/clearAll aynı; kapı sonradan açılınca işlenmemiş hata YOK.
- `StateHarness(autoInit: true, storage: FakeStorage(store, clock: fakeClock))`, `store.hangReads`: `elapse(15 sn)` -> `authStatus != checking`, `storageError != null`, `await h.state.ready` tamamlanır.
- `logout()` + `hangDeleteAll`: `elapse(10 sn)` içinde biter.
- `EvCloudApiService`: ilk GET 401, `/api/v1/auth/refresh` 200, ikinci GET 200, `onTokenRefreshed = (a, b) => Completer<void>().future`: çağrı `clock.elapse(4 sn)` içinde tamamlanır (`ev_cloud_api_auth_test.dart` kurgusu).
- `BiometricAuthService(auth: _HangingLocalAuth(), clock: fake)`: `isBiometricSupported()` 3 sn'de `false`; `authenticate` 10 sn sonra hâlâ beklemede.
- `confirmAndLogout`: `hangDeleteAll` + `elapse` sonrası ikinci çağrı yine onay diyaloğu açar.

**Risk.** Yavaş ama çalışan Keystore 6 sn'yi aşarsa kullanıcı giriş ekranı + `storageError` görür (belirteçler silinmez; sonraki açılışta düzelir): mesaj nötr kalsın. Zaman aşımına uğrayan platform çağrısı iptal EDİLEMEZ; Android `flutter_secure_storage` tek yürütücüde sırayı korur. Pinli testler: `automation_state_session_test.dart:1078` ("depolama okuma hatası"), biyometrik "okunamayan tercih: kilit AÇIK" (~909), `auth_secure_storage_test.dart`: hepsi `SecureStorageException` yolunu kullanır. `AppShell` `storageError` snackbar'ı (`app_shell.dart:178-205`) yeni tetikleyiciler kazanır.

### 6.3 PF-03: ağ-öncelikli soğuk açılış (yüksek, açık)

**Kanıt [K].** `_startSession`: `await fetchHomes(autoSelect: false);` (1414), `_authStatus = AuthStatus.authenticated;` (1416). Önbellek yalnız hata sonrası: `if (e.isNetwork && !_homesLoaded) { await _loadHomesFromCache(epoch, autoSelect); }` (1465-1467). Saklı erişim jetonu 15 dk ömürlü (`secure_storage_service.dart:113`); kapalı kalan uygulamada çoğunlukla bitmiş: GET 401 -> refresh -> yeniden = 3 ardışık ağ turu (`ev_cloud_api_service.dart:288-306`); kara delikli ağda 10+10+10 sn. Sonrası da ardışık: `selectHome` `await refresh(); await _startRealtime();` (1573-1574), `_resumeSession` `fetchHomes -> refresh -> _startRealtime` (1046-1048), `setMode(cloud)` aynı (1637-1638). Not: `EvMqttService.start` döngüyü başlatıp hemen döner (`ev_mqtt_service.dart:340`), yani kazanç MQTT'nin REST yığınından önce başlaması.

**Düzeltme (≈15 satır, `automation_state.dart`):**
1. `_startSession`: servis oturumu ve refresh-only yolu AYNEN kalsın (pinli sıra `refreshSession < fetchHomes`). Normal yolda: `final cached = await secureStorage.loadHomesCache(user.id)` (yerel; `SecureStorageException` -> `_storageError`, ağ-öncelikli akışa dön). `cached.isNotEmpty` ise `_homes = cached; _authStatus = AuthStatus.authenticated; notifyListeners(); unawaited(_selectInitialHome()); unawaited(fetchHomes(autoSelect: false)); return;` (direct modda mevcut `_prepareDirect/_startPolling/refresh` sırası). Önbellek BOŞSA mevcut akış aynen.
2. **`homesFromCache` SWR penceresinde SET EDİLMEZ**: `dashboard_states.dart:178` çevrimiçi kullanıcıya yanlış "Çevrimdışısınız" şeridi çıkarırdı. Bayrak yalnız ağ hatasında (mevcut davranış) set edilir; SWR sırasında `homesLoading == true` zaten var.
3. `selectHome`: `unawaited(_startRealtime()); await refresh();` (`_loadEndpoints` canlı anlık görüntüyü REST üstüne zaten uyguluyor: 1870-1874). `_resumeSession` ve `setMode(cloud)`: `await Future.wait<void>([fetchHomes(autoSelect: false), refresh(silent: true), _startRealtime()])`.
4. İsteğe bağlı sonraki dalga: son bilinen uç nokta önbelleği (SharedPreferences) + "son bilinen" rozeti (§10).

**Test.** `StateHarness(autoInit: true)` + önceden doldurulmuş depo (belirteç + kullanıcı + `await storage.saveHomesCache('user-1', [testHome()])`) + `cloud.fetchHomesGate = Completer<void>()` (VAR, `fakes.dart:247`) hiç tamamlanmadan: `await h.clock.elapse(const Duration(seconds: 1));` -> `authStatus == authenticated`, `homes` dolu, `activeHome?.id == kHomeA`, `homesLoading == true`, **`homesFromCache == false`**, `cloud.count('fetchEndpoints') >= 1`; kapı açılınca rol/ev uzlaşır. Çevrimdışı varyant: `fetchHomesError = ApiException.network()` -> `homesFromCache` true + `homesError` dolu. `selectHome`: REST kapısı açılmadan `mqtt.startCount == 1` (kapı için `FakeCloudApi.fetchEndpointsGate` eklenir: WP-INFRA).

**Risk.** Orta-düşük: kısa süre önbellekteki roller görünür (`_reconcileHomes` 1499-1534 rol/üyelik değişimini düzeltir; 401 `SessionExpiredEvent` üretir; geçersiz oturumda pano kısa süre görünüp girişe dönebilir). `ready` zamanlaması yalnız önbellekli yolda değişir: pinli `_init` testleri (`automation_state_session_test.dart:1046-1210`) `await ready; await settle()` kullanır ve önbellekli tek test "çevrimdışı açılış" (1089-1104) geçer. Biyometrik kapı hep önce kalır.

**PF-39 (giriş sonrası diyalog bekleme).** `_handleAuthSuccess`: `await fetchHomes(); return true;` (1371-1372) -> otomatik ev seçimi + REST + MQTT bitene kadar telefon-OTP/şifre-sıfırlama/magic-link diyalogları (`PopScope(canPop: !busy)`) açık kalır; AuthGate pano görünümüne HEMEN geçer ama itilmiş rotaları girişte kapatmaz. Arayüzde kapı-pop'u ÖNERİLMEZ (`password_reset_and_recovery_test.dart:210-219` "Şifreniz yenilendi ve oturumunuz açıldı." mesajını sabitler). En küçük düzeltme: `await fetchHomes(autoSelect: false); unawaited(_selectInitialHome()); return true;` (`_startSession` ile aynı desen; ev listesi 1 tur beklenir, REST yığını/MQTT beklenmez). Risk: `await login()` sonrası hemen `activeHome` bekleyen testler; sabitlenmiş login testleri `settle()` kullanıyor (`automation_state_session_test.dart:41-60`); `auth_secure_storage_test.dart:218,252`, `biometric_auth_test.dart:326`, `e2_confirm_dialogs_test.dart:92` uygulayıcı tarafından gözden geçirilir.

### 6.4 PF-09: toplam süre bütçesi yok (orta, açık)

**Kanıt [K].** `ev_cloud_api_service.dart:288` `var res = await _sendRaw(method, uri, body: body, auth: auth, timeout: timeout);` -> 401'de `await _refreshSingleFlight(...)` (297; kendi 10 sn'si 361-367) -> `res = await _sendRaw(...)` (305). GET: 10+10+10 sn; `sendCommand` 8+10+8; claim/commission 20+10+20. `_sendRaw` içindeki `future.timeout(timeout)` (170) yalnız tek isteği sınırlar; asılan istek iptal edilmez.

**Düzeltme (yerel, ≈15 satır, yalnız `_call`).** Gövdeyi `_callOnce(..., _Budget budget)`'e taşı; yeni `_call` = `_clock.bound(_callOnce(...), timeout + const Duration(seconds: 4), () { budget.expired = true; throw ApiException.network(message: 'Sunucu zamanında yanıt vermedi. Tekrar deneyin.'); })`. `_callOnce` refresh'ten ÖNCE ve yeniden deneme gönderiminden ÖNCE `if (budget.expired) throw ...` denetler (terk edilen iç koşu, çağıran hata aldıktan sonra POST'u hayalet olarak yeniden göndermesin). `refreshSession()` (başlangıç) kendi 10 sn'sini korur. Komut çağrılarında bütçe komut hattının `maxTotal` (10 sn, CONTRACTS §5) ile uyumlu seçilmeli.

**Test (plain test, FakeClock).** `MockApi` hiç dönmeyen GET (`Completer<http.Response>().future`) + `EvCloudApiService(baseUrl: ..., client: api.client, clock: clock)..setAuthToken('a')..setRefreshToken('r')`; `final f = service.fetchHomes(); await clock.elapse(const Duration(seconds: 14));` -> `isNetwork`. 401 senaryosu: ilk GET 401 hemen, `/auth/refresh` dönmez -> 14 sn içinde `isNetwork`; oturum KORUNUR (`hasSession == true`, `onSessionExpired` çağrılmaz); iç koşunun POST'u en çok 1 kez gönderilir.

**Risk.** Düşük-orta: gerçekten yavaş sunucu daha erken ağ hatası verir (ağ hatası oturumu düşürmez). `ev_cloud_api_auth_test.dart` akışları zaman tabanlı değil. Terk edilen isteğin sunucuda yine işlenmesi mümkündür (yeniden gönderim engellenir, ilk gönderim değil).

### 6.5 PF-27 (+PF-28): MQTT bağlanması süre sınırsız (orta, yeni)

**Kanıt [K].** `ev_mqtt_service.dart:154` `..connectTimeoutPeriod = timeout.inMilliseconds` ve `_connectTimeout = Duration(seconds: 10)`: paket belgesine göre `connectTimeoutPeriod` "successive connection attempts" arası/CONNACK beklemesidir (`mqtt_client.dart:101-108`); soket/TLS kurulumu `await connection.connect(hostname, port);` (`...synchronous_mqtt_server_connection_handler.dart:116`) -> `SecureSocket.connect(..., timeout: socketTimeout)` ve `socketTimeout` null. `_run` bunu sarmıyor: `final outcome = await transport.connect(...)` (469). 8884 sessizce düşürülen ağda işletim sistemi zaman aşımına kadar bekler (tahmin 75-130 sn; ölçülmedi). `stop()/start()` yeni döngü açsa da eski soket bekler; geç bağlanırsa kapatılmış taşıma üstünde "zombi" bağlantı kalabilir (`MqttClientTransport.close()` bağlanma bitmeden `_client?.disconnect()` etkisiz) ve aynı `clientId`'yi broker'da düşürüp çalkalanma yaratabilir.

**TUZAK.** `client.socketTimeout` KULLANMAYIN: atandığında `_connectTimeoutPeriod = 10` olur (`mqtt_client.dart:94-98`), CONNACK beklemesi fiilen kapanır ve `maxConnectionAttempts: 1` ile bağlantılar başarısız olur. `client.connect().timeout(...)` de yetersizdir (`Future.timeout` soketi iptal etmez).

**Düzeltme (`ev_mqtt_service.dart`, çakışmasız).**
1. `_run`: `transport.connect(...)`'i Clock yarışına al: `Completer<MqttConnectOutcome>` + `_clock.timer(_connectTimeout + const Duration(seconds: 5), ...)` zaman aşımında `MqttConnectOutcome.failed(MqttFailure.timeout)` tamamlar; `transport.connect(...).then(...)` ilk tamamlanan kazanır, zamanlayıcı iptal edilir. Mevcut `!outcome.ok` dalı (`_closeTransport(); _setLink(reconnecting); await _sleep(_backoff(attempt++), generation);`) çalışır.
2. `MqttClientTransport.connect`: `await client.connect()` döndükten sonra `if (_closed) { try { client.disconnect(); } catch (_) {} return const MqttConnectOutcome.failed(MqttFailure.other); }` (zombi önleme).
3. **PF-28:** `connectedAt = _clock.now()`; `attempt = 0` bağlanır bağlanmaz DEĞİL, `await ended.future` sonrası: kopma beklemesi `if (!renewal) { await _sleep(_backoff(attempt), generation); attempt = stable ? 0 : attempt + 1; }` (`stable` = bağlantı ≥ 30 sn yaşadı). İlk kısa kopma yine `_backoff(0)` ≈2 sn bekler (pinli test 323-334 aynen geçer); planlı yenileme (`renewal`) anında yeniden bağlanır ve sayacı sıfırlar.

**Test.** `FakeMqttTransport.connectGate` (WP-INFRA; `connect` önce `await connectGate!.future`): `EvMqttService(clock: FakeClock, transportFactory: ...)` ile `start`; `await clock.elapse(const Duration(seconds: 20))` -> `lastFailure == MqttFailure.timeout`, `linkState == reconnecting`, bekleme sonrası ikinci `providerCalls == 2`; kapı sonradan açılırsa eski taşıma `closed == true` ve ileti iletmez. PF-28: her bağlantıdan 100 ms sonra `drop()`; `elapse(5 dk)` -> `providerCalls <= 12` (bugün ~100+), aralıklar 2,4,8,... artar ve 60 sn'de doyar; 40 sn yaşayan bağlantıdan sonra sayaç sıfırlanır.

**Risk.** Düşük: `FakeMqttTransport` anında döndüğünden pinli `ev_mqtt_service_test.dart` 292-393 etkilenmez (kimlik yenileme 292-321, kopma 323-334, auth reddi 336-367, üstel 369-393). Yavaş mobil ağda >15 sn TLS erken pes edip yeniden dener (kabul).

### 6.6 PF-37 (+PF-38): splash ve yükleme spinner'ları (orta/düşük, yeni)

**Kanıt [K].** Splash: `CircularProgressIndicator` (`auth_gate.dart:356-362`) sürekli döner ve hiçbir `RepaintBoundary` yok (lib'de tek sınır `circuit_background.dart:68`). Sayfa; tam ekran JPEG (200-206), tam ekran gradient (207-222), iki büyük blur gölge (`blurRadius: 36, spreadRadius: 6` ve `60/10`, 239-240), metin gölgesi (263), panel gölgesi (290) aynı sayfa katmanında. Skia (`EnableImpeller=false`) her karede sayfa resmini yeniden kaydeder [yapısal çıkarım, profil gerekir]. `TimedLoadingView`: `const CircularProgressIndicator(),` koşulsuz (`dashboard_states.dart:66`), `_timedOut` dalının dışında -> zaman aşımından sonra da sonsuz animasyon (ve `pumpAndSettle` bu görünümde asla bitmez).

**Düzeltme.** Splash: spinner'ın `SizedBox`'ını `RepaintBoundary` ile sar ve statik arka plan (JPEG + gradient) `Positioned.fill` çiftini tek `RepaintBoundary` içine al. `TimedLoadingView`: spinner yalnız `!_timedOut` iken, `RepaintBoundary` içinde; `Key('loading_view')`, mesaj metni ve `Key('btn_retry')` aynı kalır. Splash'a başka efekt eklenmez.

**Test.** Katman testi (düzeltmeden önce KIRMIZI): `nearestBoundary(tester, find.byType(CircularProgressIndicator))` ile `nearestBoundary(tester, find.text('AHBU OTOMASYON'))` AYNI olmamalı. `TimedLoadingView`: 16 sn sonra `CircularProgressIndicator` yok, `btn_retry` var, `pumpAndSettle` takılmaz. Pinli: `splash_and_logo_design_test.dart` (metinler, `ClipOval`, 320x568 ölçek 1,5), `e1_dashboard_states_test.dart:57-74,360-376`, `scheduled_rules_test.dart:185-191`; `guest_and_dynamic_qr_test.dart:107,178` ve `e2_closeout_test.dart:419` spinner YOKLUĞUNU doğrular: bu akışlara yeni spinner eklenmez.

### 6.7 PF-40: duvar butonu dinlemesi 5 Hz (orta, yeni)

**Kanıt [K].** `button_logic.dart:55` `pollInterval = Duration(milliseconds: 200)`; `_tick` her başarılı turda `if (_listening) { _applyStatus(status); ctx.notify(); }` (160-163); `_applyStatus` her tikte yeni liste/`ButtonCheck` üretir. `ctx.notify` -> denetleyici `notifyListeners` yalnız `_disposed` korumalı (`service_setup_controller.dart:484-485`); `ListenableBuilder(listenable: c, ...)` tüm Scaffold'u (AppBar, banner, `AnimatedSwitcher`, 9. adım kartları) saniyede 5 kez kurar. Algılanan kartta her kurulumda `DateFormat('HH:mm:ss')` (`step_9_buttons.dart:156`).

**Düzeltme (yerel, ≈10 satır).** `_applyStatus` değişim bayrağı döndürsün (pressed/verdict/liste uzunluğu/`childLockOn`); `_tick` yalnız değişimde `ctx.notify()`. `DateFormat` `static final`. Aralık DEĞİŞMEZ (kısa basışlar kaçmasın; `f_setup_device_steps_test.dart:751-785` 400 ms kenar bekliyor).

**Test.** `serviceHarness()` + `reachStep(env, SetupSteps.buttons)` + `drive(env, c.buttons.startListening())`; `c.addListener(() => n++)`; `await env.clock.elapse(const Duration(seconds: 10))` DI sabitken `n <= 1`; `env.device.setDi(1, true)` sonrası `n > 0` ve `ButtonVerdict.detected`.

### 6.8 PF-41: sihirbazdan çıkışta panjur ölçüm süresi (orta, yeni)

**Kanıt [K].** `SetupLogic.run`: `if (_busy) return false;` (`setup_context.dart:338`). `prepareMeasure` hazırlıkta `_writeRuntime(pair, 300)` yazar; `previousSeconds` yalnız SONDA kaydedilir (`shutter_logic.dart:489-494`). `settleMeasurements` yalnız `hasMeasureOverride || phase != idle` olanlara bakar (635): hazırlık sürerken `pending` boş -> hemen `true`. `_writeRuntime` (451-459) `_ensureStopped` ile `updateEndpoint` arasında `ensureActive()` yok. Çıkış: `_confirmExit` busy denetlemiyor (`service_setup_wizard_page.dart:106-135`), `_settleAndPop` sonuca bakmadan `Navigator.pop()` yapar (138-142), denetleyici kapanır; uçuştaki hazırlık `_awaitRuntime`'de `SetupCancelled` alır, `catch (_) {}` geri yüklemesi (480-486) de aynı iptalle düşer. Sonuç: 300 sn ölçüm süresi panoda/sunucuda kalır (kodun kendi uyarısı: panjur motoru her komutta 300 sn'ye kadar enerjili kalabilir). Pencere: hazırlama sırasında (≤ ~20 sn) geri tuşu.

**Düzeltme.** (1) `settleBeforeExit` başında, `ctx.isBusy` iken en çok ~20 sn bekle (200 ms aralıkla `ctx.delay`), sonra settle. (2) `_writeRuntime`'ta `_ensureStopped` sonrası `ctx.ensureActive()`. (3) `previous` değerini 300'ü yazmadan ÖNCE kayda geçir (`previousSeconds` erken) ki yarım kalan hazırlık sonradan geri yüklenebilsin. (4) İsteğe bağlı: `_confirmExit`'te busy iken "Bir işlem sürüyor" iletisi. `previousSeconds` kayıt sırasına ve pinli `f_setup_device_steps_test.dart:668-704` akışına dokunulmaz.

**Test.** `ServiceFakeCloud`'a `updateEndpointGate` (Completer; `f_support.dart`, WP-SETUP). `final p = c.shutters.prepareMeasure(1); final x = c.settleBeforeExit();` kapıyı aç; `await drive(env, Future.wait([p, x]))`; `expect(env.device.shutterRuntime(1), 20)` (300 değil).

### 6.9 PF-11: yüklemelerde otomatik yeniden deneme yok (orta, kısmen)

**Kanıt [K].** `_loadDevices`: `} on ApiException catch (e) { _log('Cihaz listesi alınamadı (${e.statusCode})'); } catch (_) {}` (`automation_state.dart:1905-1907`) -> `_presence` bilinmiyor kalır -> bulutta `case DevicePresence.unknown: return ConnectionStateEnum.connecting;` (318-319) ve rozet sonsuza dek "Bağlanıyor…" (`connection_status.dart:129-133`). `_loadEndpoints` hatayı saklıyor ama tetikleyen yok (1881-1885). Sunucu `GET /homes/:id/endpoints` her satırda `device_online` döndürür (`endpoint_service.js:51,58`), istemci `EndpointModel.deviceOnline`'a okur (`cloud_models.dart:310,353`) ama `AutomationState` hiç kullanmıyor (grep).

**Düzeltme.** (1) Varlık yedeği: `_loadEndpoints` başarısında `_presence == DevicePresence.unknown || !brokerConnected` iken `deviceOnline != null` olan uç nokta varsa `_presence = list.any((e) => e.deviceOnline == true) ? online : offline` (`_loadDevices` ile aynı kural). (2) `_devicesFailed` bayrağı. (3) Sınırlı otomatik deneme: `_cloudRefreshImpl` sonunda `(_endpointsError != null && !_endpointsLoaded) || _devicesFailed` ise `clock.timer` ile 2, 5, 15, 30 sn (en çok 4; `_homeEpoch` değişiminde, arka plana geçişte ve dispose'ta iptal; `_cancelAllTimers`/`_resetHomeScopedState`/`_enterBackground`'a ekle); `silent: true`. UI'da değişiklik gerekmez (hata kartı + elle "Yeniden dene" var).

**Test.** `FakeCloudApi.devicesError` (WP-INFRA). `readyHarness(configure: (h) { h.cloud.fetchEndpointsError = ApiException.network(); })`: `endpointsLoaded == false`; hatayı temizle, `elapse(3 sn)` -> `count('fetchEndpoints') == 2`, `endpointsLoaded == true`. `handleLifecycleState(paused)` sonrası `elapse(60 sn)`: ek istek YOK. `selectHome(testHome(id: kHomeB))` sonrası eski ev için deneme yok. `devicesError` + uç noktada `deviceOnline: true`: `devicePresence == online`, `connState == connected`.

**Risk.** Düşük. FakeClock'u uzun ilerleten testlerde yalnız BAŞARISIZ ilk yükleme yeniden denenir (en çok 4); UI testleri FakeClock'u ilerletmiyor. Varlık yedeği yanlış "çevrimiçi" üretemez (MQTT canlıysa devreye girmez).

### 6.10 PF-42: claim yanıtı kaybolursa çıkmaz (orta, yeni)

**Kanıt [K].** `_claimMapped` ağ `ApiException`'ını olduğu gibi döndürür (`claim_logic.dart:267`, `return e;`); `SetupLogic.run` hatada `_retry = () => run(label, action);` (`setup_context.dart:361`); ağ/zaman aşımı hatası `SetupProblemKind.network/timeout` ve varsayılan `retryable: true` (`setup_problem.dart:177-193`). İkinci POST: sunucu `_assertInventoryClaimable(inv)` CLAIMED cihazı reddeder (`device_service.js:678`), OTP tek kullanımlık -> 409 "Cihaz eşlenemedi". `ctx.target` hiç atanmadığı için ilerleme kaydı da yazılmaz. Karşılaştırma: acil sıfırlama ve pano değişimi `UncertainOutcomeCard.isUncertain(e)` ile çözülmüş (`uncertain_outcome_card.dart:37-38`).

**Düzeltme (`claim_logic.dart`, yerel).** `UncertainOutcomeCard.isUncertain(e)` ise `_maybeSent = true`; bir sonraki claim/retry ÖNCE doğrulasın: `ctx.cloud.fetchHomes()` + uygun evlerde `devices(homeId)` içinde uid ara (servis personeline claim sonrası 72 saatlik üyelik verilir: CONTRACTS §1.5b); bulunursa `ctx.target = ServiceTarget(...)` + `_summary` (`credentialReceived: false`) ata ve POST'u atla; bulunmazsa normal claim. Yeni kullanıcı metni eklenir, mevcut metinler değişmez.

**Test.** `ServiceFakeCloud`'a `claimLosesResponseOnce` (claim'i sunucuda uygula, sonra `ApiException.network()` at): `expect(await c.claim.claim(), isFalse); await drive(env, c.claim.retry()); expect(env.cloud.claimCalls, 1); expect(c.claim.isComplete, isTrue);` + mevcut `f_setup_controller_test.dart:397-407` (hata sunucuya ulaşmadı) aynen geçer.

**Risk.** Orta: eve erişim sunucu sözleşmesine bağlı; evler listesinde yoksa normal yola düş. Sunucu claim'in idempotent olmadığı doğrulandı.

### 6.11 PF-15 / PF-16 / PF-17: varlık ve açılış kabuğu (orta, açık)

- **PF-16 [K].** lib'de `cacheWidth|cacheHeight|ResizeImage|precacheImage` yok; logolar 1024² RGBA (≈4 MiB çözülmüş) 28-130 dp'de (`dashboard_app_bar.dart:377`, `auth_gate.dart:244`, `login_page.dart:449`, `super_user_drawer.dart:84`, `device_settings_page.dart:75,123`, `family_members_page.dart:195`, `scheduled_rules_page.dart:206`). `app_logo.png` ile `round_app_logo.png` BAYT BAYT AYNI (md5 `b233994fd36cfd83d307e6f98585aaed`) ama farklı yol = iki ayrı ImageCache girdisi. Referanssız 6 PNG: `app_badge` 954.384, `app_banner` 293.947, `refined_thin_ring_logo` 1.296.017, `round_app_logo_large` 1.475.845, `round_app_logo_thin_ring` 1.234.748, `thin_ring_logo_cropped` 1.303.424 = **6.558.365 B**; `pubspec.yaml` `- assets/images/` ile APK'ya giriyor. `scripts/generate_adaptive_icons.py:4` yalnız `round_app_logo_thin_ring.png`'yi KAYNAK olarak okur (dosya silinmemeli, pakete alınmamalı). Betikler `round_app_logo.png`'yi de kaynak/hedef olarak kullanır (`make_round_icons.py`, `generate_hd_splash.py`): tam boyutlu ana kopyalar ayrı dizine (ör. `assets_src/`) taşınmalı ve betik yolları güncellenmeli.
  *Tercih edilen yol (kod çakışmasız):* varlık tarafı. `pubspec.yaml` dizin yerine AÇIK liste (`ai_circuit_bg.jpg`, `ai_circuit_bg_light.jpg`, `round_app_logo.png`, `app_logo.png`); `round_app_logo.png` 512², `app_logo.png` 256² olarak küçültülür (aynı dosya adı: 11 `Image.asset` çağrısı değişmez; `device_settings_page.dart` ve ayar kartları diğer oturumun alanında kalır). *Alternatif:* `AppLogo(size)` yardımcısı + `cacheWidth` (dosya sahipliği çakışır: yalnız yamadan sonra).
- **PF-15 [K].** `circuit_background.dart:26-31` düz renk Container, 34-40 `Image.asset(bgAsset...)`, 43-64 gradient; yalnız 67-73 painter `RepaintBoundary` içinde. Genel arka plan `MaterialApp.builder`'da (`app_shell.dart:228-232`, Navigator dışında) ve opak rota üstteyken de çizilir. `device_inventory_page.dart:211-231` ve `service_management_page.dart:356-398` opak `Scaffold(backgroundColor: ...)` İÇİNDE ikinci `CircuitBackground` çiziyor (≈8 tam ekran katman). Splash/giriş de kendi JPEG+gradient'ini ekler. Açık temada küresel katman `ai_circuit_bg_light.jpg` (1.096.421 B, ≈4,2 MB çözülmüş).
  *Düzeltme:* (a) `circuit_background.dart`: düz renk Container (KALMALI: `theme_and_circuit_background_test.dart` ilk renkli Container'ı bekler) + JPEG + gradient tek `RepaintBoundary` içine; (b) üç yerde arka plan görseli için ya hiç `cacheWidth` ya da AYNI sabit (farklı `cacheWidth` = ayrı önbellek girdisi); (c) iç içe `CircuitBackground`'ların kaldırılması (görsel onay: açık temada Scaffold zemini `0xFFF1F5F9` farkı) WP-SVC-PAGES; (d) splash/giriş kopyalarının kaldırılması + küresel katmana "kapı koyu" bayrağı `app_shell.dart` ve görsel onay gerektirir: **ertelendi**.
- **PF-17 [K].** `launch_background.xml` `gravity=fill` `splash_screen_full.png` (2.402.557 B, 1080x2400 çözülmüş ≈10 MB, `drawable/` yoğunluksuz); `drawable-v21` kopyası birebir aynı (`diff` boş). `NormalTheme`: `android:windowBackground` = `?android:colorBackground` üç stilde (`values`, `values-night`, `values-v31`); yerel biyometrik düzeltmesi parent'ları AppCompat'a taşıdı -> zemin açıkta #FAFAFA, koyuda #303030 (eskiden siyah). `values/colors.xml` `splash_bg #0B1120` tanımlı ama kullanılmıyor. `splash_bg_circuit.png` (2.780.093 B) ve `splash_logo.png` (136.917 B) hiçbir XML/Kotlin'de referanssız (yalnız betikler üretir; `17596ad` referansları kaldırdı).
  *Düzeltme (görünümü koruyarak):* (1) `NormalTheme` `windowBackground` -> `@color/splash_bg` üç dosyada (parent'lara dokunma: `e2_platform_files_test.dart:103-115` AppCompat kilidi); (2) `splash_screen_full.png` -> lossy WebP (q≈85) ya da 720x1600, `drawable-nodpi/` altında (kaynak adı aynı), `drawable-v21` kopyasını sil, `scripts/generate_hd_splash.py` çıktısını güncelle; (3) referanssız iki PNG'yi sil (betikler yeniden üretir; betikler güncellenir). Denetimin "düz #0B1120 + 288 px logo" önerisi UYGULANMAZ: `17596ad` bilinçli tasarım (§7 G6).

---

## 7. Çözüldü ve geçersiz tabloları

### 7.1 Çözüldü (kanıtlı)

| ID | Kanıt |
|---|---|
| PF-07 | `apartment_dashboard.dart:20-67`: üç durumlu `ApartmentPhase`; `if (s.homesLoaded) return ApartmentPhase.homeless;` (60), `homesError` -> `homesFailed` (61), `endpointsLoaded` -> `content` (64). `WelcomeClaimCard` yalnız `vm.isOwner` ve başarılı boş yanıt (242-244). `TimedLoadingView` 15 sn + `Key('btn_retry')` (`dashboard_states.dart:18-97`) |
| PF-10 | `command_pipeline.dart:432` `_restartConfirmTimer(entry); // "uygulanıyor": onay penceresi iletimden başlar`; 365-374 `deadline = submittedAt.add(maxTotal)`; `CONTRACTS.md:475`. Kalan küçük kenar (REST > 10 sn): `maxTotal` geri alması ve terk edilen istek sonradan iletilebilir (kabul) |
| PF-12 | `main.dart:63`; `auth_gate.dart:53`. **Uyarı:** çalışma ağacı; HEAD'de `minSplashDuration: Duration(milliseconds: 2600)` + `AUTH_GATE_DEBUG` + `Consumer` hâlâ var (`git show HEAD:...`). Commit edilmezse kaybolur |
| PF-22 | `auth_gate.dart:90-128`: `if (_isSignedInView(previous) && !_isSignedInView(view)) { _closePushedRoutes(...)` -> `popUntil(route.isFirst)`. Kalan: kilit açılınca pano yeniden kurulur (kaydırma/oda filtresi kaybı; güvenlik gereği kabul) |
| PF-24 | lib genelinde 6 `debugPrint` çağrısı (`main.dart:16`, `json_utils.dart:111-112`, `automation_state.dart:566`, `confirm_dialogs.dart:343`, `board_network_binding.dart:350`, `automation_api_service.dart:297`), hepsi `kDebugMode` korumalı (bizzat okundu) ve yalnız tür/sayı yazar; QR ham içeriği yazdırılmıyor |
| PF-26 | `catchError` yalnız `biometric_prompt_dialog.dart:101` (bilinçli). Servis yönetimi: hata kartı + "Tekrar Dene" [O]. Kalıntı: `fetchPeaceNotification` hatayı yalnız loglar (ayar kartı yaması sonrası) |

Kısmen çözülenlerin çözülen yarıları: PF-01 UI (spinner artık sonsuz değil), PF-04 LAN (`sameAs` + değişim-koşullu bildirim), PF-05 (kök izleme yok), PF-06 (`ShutterCard`, `QuickScenarioBar`, `DeviceSettingsPage` `select`), PF-08 (`CloseAllLightsButton`), PF-21 (`AuthGate` `select`, debug çıktısı yok), PF-25 (`MediaQuery.of` kalmadı), PF-23 (denetleyici sızıntısı).

### 7.2 Geçersiz / uygulanamaz / çürütülen iddialar

| Kod | İddia | Karar ve kanıt |
|---|---|---|
| G1 | PF-01: "firmware portalında kilit yok, kapsam tanımsız" | **GEÇERSİZ.** `NetTime.h:181-193` AuthLimiter (IP başına 5 hata -> 60 sn `423`; tüm kaynaklardan 60 sn'de 20 hata -> 60 sn genel kilit); `WebPortal.cpp` `checkKey`: yanlış anahtar sayılır, anahtarsız (`MISSING`) sayılmaz, kilitliyken istek sayılmaz |
| G2 | PF-01 düzeltmesi: "401'de `_connState = offline`" | **UYGULANAMAZ.** `automation_state_commands_test.dart:696-703` `connState isNot offline` ve `directError` 'anahtar' bekler. Alternatif tasarım: `connected` + `status == null` + `directNeedsKey` |
| G3 | PF-03: "SWR penceresinde `homesFromCache = true`" | **YANLIŞ.** `dashboard_states.dart:178` `if (s.homesFromCache) message = 'Çevrimdışısınız. Kayıtlı daireler gösteriliyor...'`: çevrimiçi kullanıcıya her açılışta yanlış şerit. Bayrak yalnız ağ hatasında set edilir |
| G4 | PF-04: "tüm modellere `==`" | **GEREKSİZ/ZARARLI.** UI artık skaler/record/`==`'li `RoomOptions`/`ConnectionBadge` seçiyor; yalnız `TelemetryCard` `DeviceStatus` seçiyor (`info_cards.dart:112`). `DeviceStatus ==` uptime/RSSI'yi yok sayıp telemetri kartını dondururdu (PF-33) |
| G5 | PF-02 derecesi "kritik" | **Yüksek'e indirildi:** açılış splash'ında 15 sn kaçışı var (`auth_gate.dart:171-181`); olasılık ölçülmedi. (Ama bkz. §6.2: giriş de takılır) |
| G6 | PF-17: "launch bitmap yerine düz renk + 288 px logo" | **UYGULANMAZ.** Commit `17596ad` baked splash'ı bilinçli tasarım olarak getirdi (Flutter splash'ı birebir taklit eder); geri alınması tasarım kararıdır |
| G7 | PF-05: "SliverList/ListView'e çevir" | **GEREKMİYOR.** Röle/panjur id ≤ 64, DI ≤ 64; pinli testler kartları kaydırmadan bulur ve 400x3000'de tümünü tarar (`e1_accessibility_test`, `e1_layout_test.dart:73`); `DeviceSettingsPage` bilerek eager |
| G8 | NEW-C: arayüze "`connecting && directError != null`" sezgiseli | **YANLIŞ.** `directError` taze sinyal değil: `setHost` (1660-1677) ve `setMode` (1612-1630) sıfırlamıyor |
| G9 | GK-04: `client.connect().timeout(timeout * 2)`; "`socketTimeout` ata" | **Yetersiz / TUZAK.** `Future.timeout` soketi iptal etmez; `socketTimeout` atanınca `connectTimeoutPeriod = 10` ms olur (`mqtt_client.dart:94-98`). Doğru çözüm: PF-27 (1)+(2) |
| G10 | PF-02 (okuyucu 5): `_init` için tüm `_initInner`'ı saran 12 sn bekçi | **YANLIŞ KAPSAM.** Ağ fazını da keser; yavaş ağda (3x10 sn) oturumu yanlışlıkla düşürür. Bekçi yalnız platform fazını kapsamalı; servis düzeyi sınırlar yeterli |
| G11 | PF-02: `_enqueueStorage`'a ayrıca 8 sn işlem sınırı | **GEREKSİZ.** Servis düzeyi sınır her depo işlemini zaten sınırlıyor; ek sınır sırasız yazma riski doğurur |
| G12 | PF-01 (okuyucu 5): ağ hatasında geri çekilme | **Ertelendi** (§10): `automation_state_commands_test.dart:636-660` 1,5 sn aralığını sabitliyor; kazanç düşük |
| G13 | GK-03: auth_gate'te 45 sn eşikli ikinci kaçış | **Gereksiz.** Durum tarafı bekçisi (PF-30) `biometricFailed`'i set eder; `auth_gate.dart` çakışması önlenir |

---

## 8. İş paketleri (dosya sahipliği ayrık)

Genel kurallar: bir dosyaya yalnız sahibi paket yazar; paylaşılan dosyada sıra §9'dadır. Her paket yalnız kendi yollarını stage eder. Her adım kendi commit'i. Salt-okunur bu planlama turunda hiçbir şey commit edilmedi.

| Paket | Tür | Sahip dosyalar (özet) | Bulgular | Bağımlılık |
|---|---|---|---|---|
| **WP-INFRA** | flutter-expert | `lib/services/{clock,secure_storage_service,biometric_auth_service}.dart`, `test/support/{fakes,support}.dart`, `test/support/rebuild_counter.dart` (yeni) + yeni testler | PF-02 (a-c), test altyapısı | yok (ilk) |
| **WP-NET** | flutter-expert | `lib/services/{ev_mqtt_service,automation_api_service}.dart` + yeni testler | PF-27, PF-28, PF-36 | WP-INFRA |
| **WP-CLOUD-API** | flutter-expert | `lib/services/ev_cloud_api_service.dart` + yeni test | PF-09, PF-02 (5. adım) | WP-INFRA + DIŞ YAMA |
| **WP-STATE** | flutter-expert | `lib/services/automation_state.dart`, `lib/models/{capabilities,cloud_models}.dart`, `docs/CONTRACTS.md` (§5 satırları) + yeni testler | PF-01, 03, 04, 11, 13, 20, 25 (model), 29, 30, 32-35, 39, 44 | WP-INFRA + DIŞ YAMA |
| **WP-DASH** | flutter-expert | `lib/ui/dashboard/**`, `lib/ui/widgets/{relay_switch_card,shutter_card}.dart` + yeni testler | PF-05, 08, 38, 01 (rozet), 25 (labels) | WP-INFRA, WP-STATE |
| **WP-BOOT** | mobile-developer | `lib/ui/pages/auth/{auth_gate,login_page}.dart`, `lib/ui/widgets/circuit_background.dart`, `pubspec.yaml`, `assets/**`, `android/app/src/main/res/**`, `scripts/*.py` + yeni testler | PF-37, 21, 15 (a,b), 16, 17 (1-3) | yok (paralel) |
| **WP-UI-DIALOGS** | flutter-expert | `lib/ui/common/{confirm_dialogs,cooldown,wifi_provision_panel,deep_links}.dart`; `lib/ui/pages/auth/{phone_otp_dialog,forgot_password_dialog,change_password_page,magic_link_page}.dart`; `lib/ui/pages/claim/claim_manual_dialog.dart`; `lib/ui/pages/family/{family_members_page,invite_family_dialog,join_home_dialog,transfer_ownership_dialog}.dart`; `lib/ui/pages/wifi_recovery_dialog.dart`; `lib/ui/widgets/user_profile_dialog.dart` | PF-31, 45, 43, 23, 50 (diyaloglar), 06 (9 yer) | WP-INFRA (yalnız test fake'leri) |
| **WP-SETUP** | flutter-expert | `lib/ui/pages/service_setup/**`, `test/ui/{f_support,f_flow_support,f_widget_support}.dart` + yeni testler | PF-40, 41, 42, 47 (kartlar), 48, 06 (3 yer), 25 (DateFormat) | yok (paralel) |
| **WP-SVC-PAGES** | flutter-expert | `lib/ui/pages/{service_mode_page,service_management_page,device_inventory_page,replace_board_dialog,system_doctor_dialog,service_subscribers_page}.dart` + yeni testler | PF-46, 47 (sayfa), 49, 50 (envanter), 15 (c), 06 (5 yer), 25 (DateFormat) | yok (paralel) |

### 8.1 WP-INFRA: hang/zaman aşımı altyapısı ve test düzeneği
Adımlar (testler önce):
1. `test/support/fakes.dart`: `InMemorySecureStore` -> `Completer<void>? hangReads/hangWrites/hangDeleteAll`, `Completer<void>? readGate` (değer kapıdan ÖNCE yakalanır: platform okumayı bitirip yanıtı geciktirir), `startedReads`, `writeCount`, `deleteAllCount`. `FakeBiometric` -> `supportedCalls`, `labelCalls`, `Completer<bool>? hangSupported`. `FakeCloudApi` -> `devicesError`, `fetchEndpointsGate`, `localKeyGate`. `FakeMqttTransport` -> `Completer<void>? connectGate`. `test/support/rebuild_counter.dart`: `debugOnRebuildDirtyWidget` sayacı (öncekini geri yükler; `builtOnce` parametresine GÜVENİLMEZ: yalnız `debugPrintRebuildDirtyWidgets` açıkken set edilir; ilk kurulum da sayılır, ölçüm öncesi `reset()`).
2. `clock.dart` `ClockBound.bound`; `SecureStorageService(clock:, opTimeout:)`; `BiometricAuthService(clock:, probeTimeout:)`. Sonra `FakeStorage({memory, clock})` ve `StateHarness` bağlantısı (üretim API'sine bağlı: bu yüzden aynı pakette sırayla).
3. Bugün YEŞİL olması beklenen kilit testleri (kodla çıkarım; çalıştırılmadı): `test/ui/perf_rebuild_lock_test.dart` (kalp atışı: `pumpReady(DashboardPage)`, 400x3000, ilk ileti sunucuyu çevrimiçi yapar -> sayaçları sıfırla -> aynı `emitStateJson` 10 kez -> `RelaySwitchCard/ShutterCard/DashboardStatusBar/PeaceBanner/DashboardAppBar/ApartmentDashboard/QuickScenarioBar` 0 yeniden kurulum; tek röle değişimi -> `RelaySwitchCard` yalnız 1) ve `test/services/lan_poll_lock_test.dart` (aynı `/api/status` yanıtı -> `elapse(15 sn)` boyunca 0 bildirim). Kırmızı çıkarsa bulgu yenidir.
Kırmızı->yeşil testler ilgili düzeltme paketinde yazılır (ayrı dosyalar). **Test:** `clock_bound_test` (değer/zaman aşımı/geç hata yutulur/zamanlayıcı iptal), `secure_storage_bounds_test`, `biometric_probe_bounds_test`; pinli `auth_secure_storage_test.dart`, `automation_state_session_test.dart:1078`, biyometrik fail-closed testi aynen geçer.

### 8.2 WP-NET
PF-27 (Clock yarışı + zombi koruması), PF-28 (kararlı-bağlantı geri çekilmesi), PF-36 (`kIsWeb` değilse `IOClient(HttpClient()..connectionTimeout = const Duration(seconds: 4))`, yalnız enjekte EDİLMEMİŞ varsayılan istemci; iddia [O], test yapısal). **Test:** `ev_mqtt_connect_bound_test`, `ev_mqtt_backoff_test` (§6.5). Pinli: `ev_mqtt_service_test.dart:292-393`.

### 8.3 WP-CLOUD-API
`_call` toplam bütçe (PF-09) ve `_doRefresh` callback 3 sn sınırı (PF-02 5. adım). **Ön koşul:** diğer oturumun `ev_cloud_api_service.dart` yaması işlendi; çapa dizgeleriyle uygula (`_sendRaw(`, `await callback(access, newRefresh)`). **Test:** `ev_cloud_api_budget_test` (§6.4 + §6.2). Pinli: `ev_cloud_api_auth_test.dart` 401->refresh->tek yeniden deneme akışları.

### 8.4 WP-STATE: `automation_state.dart` (tek dosya, sıralı adımlar)
**Ön koşul (S0):** diğer oturumun `automation_state.dart` yaması işlendi; HER hunk çapa dizgesiyle bulunur (satır numarası değil). Hunk'lar küçük/eklemeli; her adım ayrı commit ve hedefli test.
- **S1 (PF-01 + PF-32 + PF-33):** §6.1 tasarımı; `_directRefresh` uçuş kaydına `base/key` ekle, adres/anahtar değiştiyse yeni uçuş başlat ve eski sonucu at (`_directRefreshImpl` `await fetchStatus()` sonrası `if (base != directApi.baseUrl || key != directApi.localKey) return;`); `_directRefreshImpl` bildirim koşuluna kaba kova (`uptimeSec ~/ 60`, `wifiStaRssi ~/ 10`: ≈dakikada 1 bildirim; `sameAs`'a dokunulmaz) ve `_childLockUpdatedAt` koşulsuz güncellensin (bildirimsiz). `docs/CONTRACTS.md` §5 satırı (WP-H aynı dosyaya satır ekliyor olabilir: küçük hunk, `git apply --3way`).
- **S2 (PF-02 durum yarısı + PF-13 + PF-29 + PF-30):** kurucuda `SecureStorageService(clock: ...)`/`BiometricAuthService(clock: ...)`; `_handleAuthSuccess` üç sondayı `Future.wait` (UNAWAITED DEĞİL); `_initInner`: beş bağımsız depo okuması `Future.wait` ile paralel (her biri `{value, SecureStorageException?}` kaydına sarılı; semantik AYNI: dört oturum okumasından biri hatalıysa `_storageError` + oturum yok; bayrak okuması hatalıysa fail-closed `_isBiometricEnabled = _isBiometricSupported`); biyometrik sonda yalnız `hasTokens` ya da bayrak okuması hata verdiyse; `final epoch = _sessionEpoch;` ve platform okumalarından sonra `if (_isDisposed || epoch != _sessionEpoch) return;`. `_unlockWithBiometrics`: `authenticate` öncesi `final epoch = _sessionEpoch;` sonra `if (_isDisposed || epoch != _sessionEpoch) { _biometricChecking = false; return false; }`; `toggleBiometric`: epoch'u AWAIT'TEN ÖNCE al; etkileşimli istem için 2 dk bekçi (`clock.timer`; süre dolarsa `_biometricChecking = false; _biometricFailed = true; notifyListeners();`, `finally`'de iptal).
- **S3 (PF-03 + PF-39 + PF-35):** §6.3. PF-35: son yazılan liste özeti (örn. `jsonEncode(homes.map(toJson))` karması) bellekte; değişmediyse yazma; `_resetSessionState`'te sıfırla.
- **S4 (PF-04 + PF-11):** `_applyCloudSnapshot`: `var changed = sync.changed;` `_shutterRuntime` yalnız `moving/direction/target` farkında atanır ve `changed = true`; çocuk kilidi değer değiştiyse `changed`, ama `_childLockDeviceAt/_childLockUpdatedAt` HER iletide güncellenmeye devam eder (bayat etiket saati); `ip` değiştiyse; `_presence != online` (canlı iletide) ise `changed`; sonda `if (changed) { _endpointView = null; notifyListeners(); }` (`observe` kendi bildirimini yapar). `_loadEndpoints`: `if (_pipeline.hasPending) _pipeline.observe(...)`; REST yükleyicileri yalnız alan atasın, `Future.wait` sonrası TEK bildirim (+ `!silent` için bir erken). §6.9 yeniden deneme.
- **S5 (PF-44 + PF-34):** `emergencyResetDevice`/`claimDevice`/`replaceBoard`: başarı sonrası yenileme en iyi çaba ve sınırlı (`fetchHomes(...)` / `refresh(silent: true)` Clock tabanlı 3 sn; sonuç hemen döner). `_startPolling`, `_pollSoon` (+ geri çağrısı), `_startRealtime`, `_scheduleGuestExpiry`, `_scheduleServiceSessionExpiry`, `generateServicePin` zamanlayıcı kurulumu başına `if (_isDisposed) return;`.
- **S6 (PF-20, son ve ayrı commit):** tek `int _viewGen` + `_invalidateViews()` (`_endpointView = null; _viewGen++;`); `_endpointView = null` ve `_status` atama noktalarının TÜMÜ buna çevrilir (grep ile: ≈15 yer); `relayItems/shutterItems/status` `(_viewGen, _mode)` anahtarlı önbellek; `UnmodifiableListView`'lar atama başına bir kez; `capabilities` anahtarı `(kullanıcı, authStatus, aktif ev, mod, localKey var mı, misafir süresi)`; misafir rolü için `home.isGuestExpiredAt(now)` her erişimde ucuzca hesaplanıp anahtara girer. `capabilities.dart`: `==`/`hashCode` 32 bayrağı tek `int` bit maskesine (sınıf `const` kurucu içerdiğinden `late final` alan KULLANILAMAZ; `toMap()` testler için kalır). `cloud_models.dart`: `shutterBaseName` `RegExp`'i dosya düzeyi `final`. İnvalidasyon kaçırma riski: `...ForTesting` ayarlayıcıları da `_invalidateViews()` çağırır.

**Testler (yeni dosyalar, `test/services/`):** `state_lan_poll_halt_test` (§6.1), `state_init_hang_test` (§6.2: `ready` tamamlanır, `storageError`, geç dönen okuma oturumu geri DÖNDÜRMEZ, giriş sonrası `h.cloud.authToken` yeni oturumunki kalır), `state_biometric_epoch_test` (`FakeBiometric.pending`: istem açıkken `logout`, sonra `pending.complete(true)` -> `authStatus == unauthenticated`, `currentUser == null`; `toggleBiometric` doğrulama sırasında çıkış -> depoda `ahbu_biometric_enabled` YOK; 3 dk -> `biometricFailed == true`), `state_cold_start_cache_first_test` (§6.3), `state_cloud_notifications_test` (aynı `emitStateJson` 2. kez `n` artmaz; röle değişirse artar; `refresh(silent: true)` bildirim `<= 2`), `state_load_retry_test` (§6.9), `state_memo_test` (`identical(relayItems, relayItems)`; bekleyen komut/rollback sonrası bayat liste YOK; `capabilities` rol/ev/oturum/misafir süresi değişiminde güncellenir), `state_dispose_guards_test` (`localKeyGate` ile `setMode(direct)` sırasında `dispose()`; `clock.activeTimerCount == 0`, `directMock.requests` boş), `state_secret_result_test` (`fetchHomesGate` hiç tamamlanmadan `emergencyResetDevice` 5 sn içinde döner).
**Pinli:** `automation_state_commands_test.dart:636-703`, `automation_state_session_test.dart:1020-1211` + biyometrik 786-930, `command_pipeline_test.dart:212-290`, `child_lock_behavior_test.dart` (bildirim sayacı kalıbı 719-728), `capabilities_test.dart`, `e1_dashboard_states_test.dart` ("Çevrimdışı açılış" `homesFromCache`'e bağlı), `...ForTesting` ayarlayıcıları SENKRON bildirimi korur.

### 8.5 WP-DASH (WP-STATE'ten sonra)
1. PF-05: `endpoint_sections.dart` `CardGrid`: `SizedBox(width: itemWidth, child: RepaintBoundary(child: child))` (tek nokta; `Key`/imzalar aynı). 2. PF-38 (§6.6). 3. PF-08: `_toggleMode` için küçük `_ModeButton` (`_busy` iken `onPressed` null + 18 dp spinner, `finally` ile bırak; `Key('nav_mode')` ve tooltip'ler aynı). 4. PF-01 rozet: `connection_status.dart` `directBlockedUntil != null` -> "Cihaz geçici kilitli" + widget testi (401 -> "Cihaz kontrol edilemiyor", `loading_view` yok; 423 -> rozet). 5. PF-25: `labels.dart` `RegExp`'leri üst düzey `final`, `roomKey/roomLabel` küçük statik memo (anahtar sayısı sınırlı). PF-20 sonrası kartlarda ek değişiklik gerekmez. **Test:** katman (`nearestBoundary`: `card_relay_1` ile `card_relay_2` farklı sınır), `RebuildCounter` kilit testleri (WP-INFRA) yeşil kalır. **Pinli:** `e1_dashboard_roles_test.dart:33-101` (nav matrisi/mod testi), anahtarlar `card_relay_N, card_shutter_N, switch_relay_N, slider_shutter_N, btn_shutter_*, nav_mode`; "Hepsini Kapat" TEK widget.

### 8.6 WP-BOOT (paralel)
1. PF-37: §6.6 (splash). 2. PF-21: `_AuthSplashScreenState.build` -> `context.select<AutomationState, ({bool failed, bool checking, String label})>(...)` + eylemlerde `context.read`. 3. PF-15 (a)(b): `circuit_background.dart` (düz renk Container KALIR; üç statik katman tek `RepaintBoundary`). 4. PF-16: §6.11 (varlık tarafı yolu; `pubspec.yaml` yalnız `assets:` bölümü, dev_dependencies hunk'ına dokunma). 5. PF-17 (1-3): §6.11. 6. PF-12 kalıntısı: `AnimatedSwitcher` süresi 350 -> 240 ms (isteğe bağlı `layoutBuilder` yalnız görsel onayla). **Test:** `test/ui/boot_assets_and_theme_test.dart` (dosya okuyan): `pubspec.yaml` `assets:` altında `/` ile biten dizin girişi yok; listelenen her dosya diskte var ve lib/ içinde geçiyor; ikisi aynı baytlara sahip değil; `NormalTheme` `windowBackground == '@color/splash_bg'` üç dosyada ve AppCompat parent'ları aynı (`e2_platform_files_test.dart:103-115`); `res/` altında 200 KB'tan büyük referanssız PNG yok; `splash_screen_full.*` ≤ 500 KB; katman testi; splash'ta ilgisiz bildirim -> `_AuthSplashScreen` yeniden kurulumu 0. **Pinli:** `splash_and_logo_design_test.dart` (metinler `AHBU OTOMASYON`, `YAPAY ZEKA DESTEKLİ AKILLI YAŞAM`, `ClipOval`+`Image`, `splash_checking`, `splash_slow_notice`, `btn_splash_fallback`, `biometric_locked`, `btn_biometric_retry`, `btn_biometric_fallback`), `theme_and_circuit_background_test.dart:139-185` (`CircuitBackground(child:)`, `CustomPaint`, ilk renkli `Container` `0xFF0B1120`/`0xFFF8FAFC`, `errorBuilder`), 500-600 ms pump'lı AuthGate testleri. `AuthStatus`'a değer EKLENMEZ.

### 8.7 WP-UI-DIALOGS
1. PF-31: `confirmAndLogout`: `await state.logout().timeout(const Duration(seconds: 10))` (TimeoutException yutulur). 2. PF-45: `_executeEmergencyReset`: `.timeout(40 sn)` + `UncertainOutcomeCard.isUncertain(e)` -> `_uncertainUid` + envanterde durum kontrolü, belirsizken `btn_reset_submit` pasif (servis panelindeki `EmergencyResetCard` sözleşmesi); mevcut anahtarlar/metinler korunur (`transfer_and_emergency_reset_test.dart:397`). 3. PF-43: `wifi_provision_panel.dart` `await widget.onDeviceChecked?.call(status).timeout(const Duration(seconds: 3))`; `wifi_recovery_dialog.dart` `getLocalKey(uid).timeout(3 sn)` (kök çözüm PF-02). 4. PF-23: `Cooldown`'a `ValueListenable<int> remaining` + `notifyOnTick` (varsayılan true); üç diyalogta `notifyOnTick: false` + geri sayım metni `ValueListenableBuilder`'da. 5. PF-06: 9 yer `context.watch` -> `select` (`user_profile_dialog`, `claim_manual_dialog`, `family_members_page`, `invite_family_dialog`, `join_home_dialog`, `transfer_ownership_dialog`, `change_password_page` (yalnız `context.read`), `magic_link_page`, `deep_links` (yan etki build içinde: `_maybeStart`)). 6. PF-50: katıl diyaloğu busy iken belirgin ilerleme; 25 sn sonra "Kapat". **Test:** `hangDeleteAll` + `elapse` sonrası ikinci `confirmAndLogout` yine onay açar; `wifi_recovery_mode_test.dart:36-69` `pumpPanel` kalıbıyla `onDeviceChecked: (_) => Completer<void>().future` -> 4 sn sonra tarama başlar; geri sayım: 5 sn'de diyalog kökü 0, sayaç metni 5 kez. **Pinli:** `wifi_recovery_mode_test.dart:262-300`, `social_and_otp_auth_test.dart:17-190`, `password_reset_and_recovery_test.dart:210-219`.

### 8.8 WP-SETUP
PF-40 (§6.7), PF-41 (§6.8), PF-42 (§6.10), PF-48 (`Future.wait([ctx.cloud.devices(id), lanOrNull()])`; LAN kolu try/catch ile null, `SetupCancelled`/`SetupSessionExpiredException` yeniden fırlatılır), PF-47 (`service_tool_cards.dart` `_push` için `ModalRoute.of(context)?.isCurrent == true`), PF-06 (3 yer: `session_banner.dart:87`, `existing_devices_list.dart:22`, `service_tool_cards.dart:43`), PF-25 (`DateFormat` `static final`: `handover_logic.dart:256`, `setup_resume_list.dart:135`, `step_4_claim.dart:144`, `step_6_cloud.dart:201`, `step_9_buttons.dart:156`; `wifi_logic.dart:88` `RegExp`). **Pinli:** `f_setup_controller_test.dart:397-407`, `f_setup_device_steps_test.dart:668-704, 751-785`.

### 8.9 WP-SVC-PAGES
PF-46 (`barrierDismissible: false` + `PopScope(canPop: !_submitting)` + X düğmesi `_submitting ? null : ...`), PF-47 (`_ServiceModePageState._opening` bayrağı + `finally`), PF-49 (`ListView.builder`; `freezeBlock` itemBuilder içinde), PF-50 (envanter etiket yeniden üretimde `LinearProgressIndicator`; kapatma yasağı kalır), PF-15 (c) (iç `CircuitBackground`'ları kaldır; görsel onay notu), PF-06 (5 yer: `service_mode_page:82`, `service_management_page:353`, `device_inventory_page:195` (yalnız `canManageInventory` -> `select<bool>`), `replace_board_dialog:328`, `system_doctor_dialog:178`), PF-25 (`device_inventory_page.dart:525` `DateFormat`). **Pinli:** `super_user_and_service_management_test.dart`, `device_inventory_management_test.dart` (`card_account_*`, `btn_retry` anahtarları), `e2_platform_files_test.dart`.

---

## 9. Sıra, paralellik ve çakışma haritası

**Dalgalar.**
- **Dalga 1 (paralel, dosya-ayrık):** WP-INFRA, WP-BOOT, WP-SETUP, WP-SVC-PAGES.
- **Dalga 2:** WP-NET (WP-INFRA biter bitmez), WP-UI-DIALOGS (WP-INFRA biter bitmez), **WP-CLOUD-API ve WP-STATE (WP-INFRA + diğer oturumun yaması)**.
- **Dalga 3:** WP-DASH (WP-STATE'ten sonra).
- WP-STATE kritik yoldur: WP-INFRA biter bitmez ve diğer oturumun yaması işlenince başlayın. Dalga 1'in kalanı yamadan bağımsız ilerler.

**Çakışma haritası (diğer oturumun yama listesi vurgulu).**

| Dosya | Sahip | Not |
|---|---|---|
| `lib/services/automation_state.dart` | yalnız WP-STATE | **DIŞ YAMA ÖNCE.** Çapa dizgeleri; hunk'lar ≤ 30 satır |
| `lib/services/ev_cloud_api_service.dart` | yalnız WP-CLOUD-API | **DIŞ YAMA ÖNCE.** İki küçük hunk |
| `lib/models/api_models.dart` | kimse | Bu dalgada dokunulmaz |
| `lib/ui/app_shell.dart` | kimse | PF-15(d)/PF-51 ertelendi: yamadan SONRA |
| ayar kartları `lib/ui/widgets/settings/**`, `device_settings_page.dart` | kimse | `TelemetryCard` düzeltmesi durum tarafında (PF-33) |
| `docs/CONTRACTS.md` | WP-STATE | Yalnız §5 satırları; WP-H aynı dosyaya satır ekliyor olabilir: küçük hunk, `git apply --3way` |
| `pubspec.yaml` | WP-BOOT | Yalnız `assets:` bölümü; WP-H `dev_dependencies`'e `fake_async` ekliyor: farklı hunk |
| `test/support/fakes.dart` | yalnız WP-INFRA | WP-STATE/WP-NET/WP-DASH/WP-UI-DIALOGS yalnız KULLANIR; eksik kanca için WP-INFRA'ya istek |
| `lib/ui/pages/auth/{auth_gate,login_page}.dart` | WP-BOOT | WP-UI-DIALOGS bu iki dosyaya DOKUNMAZ |
| `lib/ui/dashboard/**` | WP-DASH | WP-SETUP/WP-SVC-PAGES dokunmaz |

**Test koşusu kuralları.** (1) Aynı anda tek `flutter test`/`flutter analyze` süreci (ortak `.dart_tool`/derleme kilidi, C: diskinde yer dar, bellek çakışması); paketler dosya-ayrık YAZILABİLİR ama koşular sırayla ya da ayrı çalışma kopyasında. (2) Önce hedefli test dosyaları ve yalnız sahip dosyaların `analyze`'ı; tam test paketi yalnız entegrasyon sonunda. (3) Emülatör/cihaz/Chrome YOK (kullanıcı kararı). (4) İlerleme/sözleşme özetleri bir deftere (dosya) yazılsın ki hesap kullanım sınırı kesintisinde kalınan yerden devam edilsin. (5) Bulgu başına doğrulayıcı ajan AÇILMAZ; yalnız yüksek/orta bulgular koordinatör tarafından doğrulanır.

---

## 10. Ertelenenler (gerekçeyle)

| Konu | Neden |
|---|---|
| PF-19 Impeller/Skia | Gerçek Adreno cihazında profil + logcat gerektirir (`fb78615` cihaz/log repoda yok); bayrağı kanıtsız kaldırmak resume donmasını geri getirebilir. Cihaz deneyi listesi: bayrağı geçici kaldır, `--purge-persistent-cache`, DevTools shader derleme olayları, >100 ms kareler |
| Raster/kare süresi ölçümleri (PF-05, PF-15, PF-37) | Profil modu + cihaz gerekir; ucuz `RepaintBoundary` değişiklikleri planda, kazancın ölçümü ertelendi (`integration_test` `watchPerformance`, `debugRepaintRainbowEnabled`) |
| PF-14 yazı tipi paketleme | **Karar:** Inter (görünüm değişmez) mi, Manrope mi (`gorsel-denetim.md:75-79`; değişken eksen varsayılan 200 tuzağı). 5 TTF (~1,54 MB) + OFL lisansı + `pubspec` `fonts:` + `app_theme.dart` `fontFamily` + `.apply(fontFamily)` (Android'de `ThemeData.dark().textTheme` Roboto taşır) birlikte yapılır; `google_fonts` bağımlılığı testler/`tool/preview` kullandığı için kaldırılmaz. Karar verilince WP-BOOT'a eklenir |
| PF-51 yerelleştirme | `flutter_localizations` + `intl ^0.19 -> ^0.20.3` (SDK şartı) bağımlılık değişikliği ve ürün kararı (`Locale('tr','TR')` cihaz dilini yok sayar); `app_shell.dart` diğer oturumun yamasından sonra |
| PF-52 iOS/web/etiket | Windows'ta iOS derlenemez (yalnız statik doğrulama); `web/` ve `AndroidManifest` etiketi ürün/mağaza adı kararı. `Info.plist` izin anahtarlarına dokunulmaz |
| PF-18 sayfa geçişi | Görünüm değişir (`PredictiveBackPageTransitionsBuilder(fallbackColor: Colors.transparent)` ve tüm platformların haritada olması şart); sahip onayı + cihaz doğrulaması |
| PF-17 (4): düz renk + logo launch | Tasarım kararı (`17596ad`); yalnız (1-3) planda |
| PF-15 (d) splash/giriş kopya arka planları | `app_shell.dart` + görsel onay |
| PF-01 ağ hatası geri çekilmesi | `automation_state_commands_test.dart:636-660` 1,5 sn aralığını ve 1,6 sn toparlanmayı sabitler; kazanç düşük. İstenirse sonraki dalgada "offline sonrası 5 sn" + testin BİLİNÇLİ güncellenmesi |
| PF-03 son bilinen uç nokta önbelleği | Yeni özellik (SharedPreferences + "son bilinen" rozeti); `EndpointModel.toJson` var ama kullanılmıyor |
| PF-05 tembel liste (Sliver) | Gerekmiyor: üst sınır 64+64; pinli testler (§7 G7) |
| Gerçek cihazda LAN kilit döngüsü (423) | Firmware yalnız kaynaktan okundu; cihazda denenmedi |
| 8884 engelli ağda MQTT davranışı | Gerçek ağ/cihaz gerekir; 75-130 sn tahmini ölçülmedi |
| Release küçültme / APK boyutu | `flutter build apk --analyze-size` çalıştırılamaz (derleme yasak) |

---

## 11. Korunacak sözleşmeler ve pinli testler

- **CONTRACTS §5:** komut hattı uç nokta başına tek bekleyen komut; onay penceresi 2,5 sn İLETİMDEN itibaren, toplam üst sınır 10 sn; geri alma nötr mesaj; widget başına hata aboneliği YOK (`e1_shell_test.dart:135-150`); "Hepsini Kapat" TEK widget (`CloseAllLightsButton`, `btn_close_all_lights`). `AuthStatus` enum'una yeni değer EKLENMEZ (yeniden kilit = `checking` + `_awaitingUnlock`). Davranış değişikliği önce belgeye (`CONTRACTS.md` §5).
- **`AutomationState`:** `...ForTesting` ayarlayıcılarının adı/imzası/SENKRON bildirimi; sıfır argümanlı `AutomationState()` ucuz ve eklentisiz güvenli; `dispose()` idempotent (`_init` sürerken de). Fake'ler `EvMqttService`/`SecureKeyValueStore` arayüzlerine eklenen üyede kırılır: arayüze üye EKLENMEZ.
- **UI anahtarları:** `card_relay_N`, `card_shutter_N`, `switch_relay_N`, `btn_relay_impulse_N`, `btn_shutter_up/stop/down_N`, `slider_shutter_N`, `view_apartment`, `loading_view`, `btn_retry`, `error_card`, `banner_offline`, `btn_banner_retry`, `btn_go_local`, `btn_go_cloud`, `btn_open_settings`, `btn_wifi_recovery`, `view_homeless`, `view_pick_home`, `status_bar`, `pill_system`, `chip_child_lock`, `banner_peace`, `card_scenario_*`, `nav_*`, `splash_screen`, `splash_checking`, `splash_slow_notice`, `btn_splash_fallback`, `biometric_locked`.
- **UI metinleri:** "Evinize Hoş Geldiniz!", "Karekod ile Cihaz Eşle", "Kodu Elle Gir (Manuel Eşleme)", "Henüz kayıtlı bir daireniz yok", "Daireleriniz yükleniyor…", "Daireler yüklenemedi", "Cihazlar yüklenemedi", "Cihaza bağlanılıyor…", "Cihaz kontrol edilemiyor", "Cihaza ulaşılamıyor", "Hepsini Kapat", "Sistem Hazır", "Canlı izleme kesik", "Pano çevrimdışı", "Uygulanıyor…", "Çevrimdışı • son bilinen", "AHBU OTOMASYON", "YAPAY ZEKA DESTEKLİ AKILLI YAŞAM", "Oturum güvenli şekilde doğrulanıyor...".
- **Sabitlenmiş testler:** `automation_state_commands_test.dart:636-660, 662-668, 670-694, 696-703`; `automation_state_session_test.dart:1020-1211` (+ biyometrik 786-930, 1078); `ev_mqtt_service_test.dart:292-393`; `command_pipeline_test.dart:212-290`; `e1_dashboard_states_test.dart` (SWR: `homesFromCache` YALNIZ ağ hatasında); `theme_and_circuit_background_test.dart:139-185`; `e2_platform_files_test.dart:103-115`; `splash_and_logo_design_test.dart`; `pumpAndSettle` kullanılan akışlarda sonsuz animasyon/`CircularProgressIndicator` olmamalı.
