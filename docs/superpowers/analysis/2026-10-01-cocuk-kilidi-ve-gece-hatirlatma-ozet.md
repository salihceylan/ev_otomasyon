# Çocuk kilidi ve gece hatırlatması — durum ve devir notu

**Yazan:** `site-kapi-kontrol-5a` oturumu (aynı kullanıcı adına), 2026-10-01.
**Okuyacak:** `docs/superpowers/plans/2026-10-01-denetim-duzeltmeleri.md` planını yürüten orkestratör ve paket ajanları (A, B, C, FW-core, FW-net, D, E).
**Ham denetimler** (dosya:satır kanıtlı, salt-okunur) bu klasörde: `cocuk-kilidi-firmware-denetimi.md`, `cocuk-kilidi-backend-denetimi.md`,
`gece-hatirlatma-backend-denetimi-ve-tasarim.md`, `taban-cizgisi-olcumu.md`. Hepsi 12:35–12:46 anlık görüntüsüdür; paketleriniz dosyaları o sırada da
değiştirdiği için satır numaraları kaymış olabilir. **Kendi kontrolünüzü yapmadan satır numarasına güvenmeyin.**

## 1. Neden bu belge var

Kullanıcı bu oturumdan üç şey istedi: (1) çocuk kilidinin gerçekten çalışması, (2) "açık kalan lambalar için gece hatırlatması"nın gerçekten çalışması,
(3) hepsi bitince sistemin akıcı/kilitlenmez ve görsel olarak etkileyici olması. Aynı ağaçta sizin plan da çalıştığı için çakışmamak üzere şöyle böldüm:

| İş | Planınızda | Bu oturumun yaptığı |
|---|---|---|
| Çocuk kilidi (firmware/backend/Flutter) | **Var**: F7, N1, N3, F2/F4, B1/B2/B8, C1, D5, D8, E-paketi, Dalga 4 senaryosu | **Dokunmuyor.** Yalnızca bulguları bu belgede devrediyor |
| Gece hatırlatması (gerçek bildirim) | **Yok** (yalnızca B8 "peace-notification şema/sütun uyumu") | **Yeni dosyalarla yapıyor (WP-H)**; mevcut dosyalarınıza yazmıyor; entegrasyonu sizin dalgalarınız bitince |
| Akıcılık / görsel cila | **Var**: §5c (Dalga 5) | **Başlamıyor.** Ölçüm/tasarım girdilerini bu klasöre koyuyor |

Kullanıcı farklı bir bölüşüm isterse bana (`site-kapi-kontrol-5a`) yazın ya da kullanıcıya sorun.

## 2. Taban çizgisi (12:35 ve 12:42 örnekleri)

`lib/` **derlenmiyor**: `flutter analyze` 126 hata (87'si `lib/`, çoğu `automation_state.dart`: eski API çağrıları — `SecureStorageService.getAppMode`,
`EvMqttService.connect/sendRelayCommand`, `HomeModel.effectiveId/idStr/mqttUsername`, `ShutterItem.pairIndex`, tür kayması int→String). 27 test dosyasından
26'sı yüklenemiyor (1 geçen). `server` testleri 417/417 yeşil, `lint:syntax` temiz, `pio run` BAŞARILI (RAM %19,9, Flash %36,6). Bu beklenen ara durum (Dalga 1 → D5/E).
Ayrıntı: `taban-cizgisi-olcumu.md`.

## 3. Çocuk kilidi — bulgular ve plan maddesine eşleme

### 3.1 Firmware

Kilit mantığı (`SmartAutomation.cpp` `setChildLock`, `begin()` geri yükleme, `checkDigitalInputs` kapısı, `pollExtModule`) 12:46'da `git HEAD` ile **birebir aynı**: F7 başlamamıştı.
Çalışanlar: 8 yerel DI'ın kapısı (`:859-863`), NVS geri yükleme (`:141-149`), `SET_CHILD_LOCK` kuyruğu (`DeviceCommand.h:27`, `:661`), sıkı MQTT ayrıştırma (`MqttManager.cpp:174-177`),
retained `state.child_lock` (`:745`, `:804`).

| # | Önem | Bulgu | Plan |
|---|---|---|---|
| 1 | yüksek | **Harici RS485 modül DI'ları kilidi atlıyor**: `pollExtModule` (`SmartAutomation.cpp:1197-1231`) kilit denetimi yok. Öneri: tek `handleDiEdge(di, closed, now)`; hem `checkDigitalInputs` hem `pollExtModule` çağırsın | F7 |
| 2 | yüksek | **`POST /api/child-lock` kimliksiz + CORS `*` + hatalı gövdede kilidi AÇAR**: `doc["enabled"] \| doc["child_lock"] \| false` → `{"enabled":"true"}` bile `setChildLock(false)` + `200`. Kabul ölçütü: `X-Device-Key`, `Content-Type: application/json`, ayrıştırma hatası/eksik/bool olmayan `enabled` → 400 ve **durum değişmez**, bilinmeyen anahtar reddi, yalnız `postDeviceCommand(SET_CHILD_LOCK, CmdSource::WEB)` ile `{"status":"queued"}`, CORS yok; Flutter doğrudan modu şekli (`POST {"enabled":bool}`, `GET {"child_lock":bool}`) korunur | N3 |
| 3 | yüksek | `Set_EXIO` (`WS_TCA9554PWR.cpp:59`) donanımdan oku-değiştir-yaz; başarısız okuma `0xFF` → "diğer tüm röleler ON". I2C'de mutex yok | F2 |
| 4 | orta | **Bırakma (release) olayı yutuluyor** (`:860-863` `continue` bastır/bırak dalından önce). Basış kilitten önce kabul edildiyse MOMENTARY röle açık kalır; kilit açılınca yutulmuş basışın bırakması bayat `setRelayState(false)` üretir. Çözüm: DI başına `_diActedMask` | F7 |
| 5 | orta | Debounce 150 ms ve iki yerde kopya (`:849`, `:1199`); istenen 60 ms, tek `constexpr` | F7 |
| 6 | orta | `setChildLock` değişim koruması yok: her çağrı NVS `putBool`+commit (flash aşınması kuralı), `begin()/putBool()` sonucu denetlenmiyor (kilit sessizce kaybolur) | F6/F7 |
| 7 | orta | Kilit değişince `MqttManager::triggerPublish()` yok: retained `child_lock` 30 sn bayat kalabilir; Flutter'ın 2,5 sn doğrulaması (`command_pipeline.dart:555`) uygulanmış kilidi geri alır | F7/N1 |
| 8 | orta | Seri CLI'da `CHILDLOCK ON\|OFF\|STATUS` yok (telefon/bulut yokken fiziksel kaçış yolu); `STATUS` `child_lock` yazmıyor; `main.cpp:83` `WIFI <ssid> <parola>` komutunu yankılıyor | F7 |
| 9 | orta | `loopTask` (Core 1) bloklayıcı işler barındırıyor (CLI 1 sn, `WebServer::handleClient` 5 sn, `delay(500)`, RS485 `delay(20)`); bu sürede duvar anahtarı ve kilit işlenmez; TWDT'ye kayıtlı değil | F5/N3 |
| 10 | orta | Harici modül DI çerçevelerinde CRC yok; gürültü sahte basış üretir ve (1) ile birleşince kilitliyken ışık açar | F4 |
| 11 | orta | `setRelayState/toggleRelay` `relayIndex>=8` için sessizce çıkıyor: harici röle 9..40 telefon/MQTT komutları etkisiz; kilitliyken o yükler için denetim yolu kalmaz. `allShuttersDown/Up` `\|\|` yerine `&&` | F4/F3 |
| 12 | düşük | `isChildLockEnabled()` mutex zaman aşımında `false` döner (raporlamada fail-open); bayrak `volatile` değil; `setChildLock` public ve satır içi çalışıyor (başlık yorumu kuyruğa alındığını söylüyor) | F7 |
| 13 | düşük | `ConfigManager::resetToDefaults()` NVS'i siler ama RAM bayrağı yeniden başlatmaya kadar kalır | F6 |
| 14 | düşük | Kullanılmayan vendor yolları (`WS_DIN.cpp` `DINTask`, `WS_RTC.cpp` `TimerEvent_handling`) kilidi/interlock'u/kuyruğu atlar; tek `DIN_Init()` çağrısı kilidi etkisiz kılar | F8 |
| 15 | düşük | Saf `DiGate` sınıfı + Unity testleri yok (bu makinede derleyici olmadığı için çalıştırılamaz; `ShutterFsm` örüntüsü) | F7/F8 |

**Ürün soruları (kullanıcıya):** (a) kilitliyken duvar anahtarı *hareket halindeki* panjuru DURDURABİLSİN mi? Şu an durduramıyor; telefonla başlatılan panjuru duvardan durduramamak sıkışma riski.
(b) bastırılan basış için sesli/LED geri bildirim; (c) telefon ve bulut yokken kaçış yolu (seri `CHILDLOCK OFF`, `local_key` ile LAN HTTP, servis modu);
(d) kilit + "elektrik gelince ışıklar KAPALI" birleşimi: elektrik kesintisi sonrası telefon bağlanana kadar kimse duvardan ışık açamaz (tasarım gereği; belgelensin).

### 3.2 Backend

REST katmanı WP-B yeniden yazımıyla (12:35/12:37) **sağlam**: JWT, `requireHomeAccess(rolesFor('child_lock'))` (IDOR yok, misafir 403, süresi dolmuş misafir `GUEST_EXPIRED`), sıkı boolean, `409 DEVICE_OFFLINE`,
`502 BROKER_UNAVAILABLE`, komut yükü sözleşmedeki gibi (`ev/{t}/cmd`, QoS1, retain=false). Aşağıdakiler kalan boşluklar:

| # | Önem | Bulgu | Plan |
|---|---|---|---|
| 1 | kritik | Köprü `devices.last_ack_id/last_ack_at` yazıyor; bunları yaratan migration yoktu (şimdi `023/024` içinde mi doğrulayın). Her REST komutu `id` taşır, firmware `state.last_id` yankılar → her canlı durum işlemi `42703` ile geri alınır, sağlıklı pano 120 sn sonra "çevrimdışı" süpürülür ve her çağrı `409` döner | C1/C3 |
| 2 | yüksek | `GET /child-lock` `homes.child_lock_enabled` okur; bunu yalnız REST yazar, köprü yalnız `devices.child_lock_enabled` yazar. Kaybolan komut, yerel/LAN/dokunmatik değişiklik, yeniden başlatma, pano değişimi, acil sıfırlama kalıcı sapma bırakır; Flutter `refresh()` UI'yi bundan ezer. **Öneri: cihaz bildirimi tek doğruluk**; köprü aynı `withTransaction` içinde `homes.child_lock_enabled`'ı `bool_and(devices…)` ile eşitler | C1 |
| 3 | yüksek | REST yalnızca broker PUBACK sonrası isteneni kalıcılaştırır ve "kilitlendi" der; PUBACK uygulandığını göstermez (`is_online` 120 sn bayat olabilir, pano `clean session`). Öneri: isteneni kalıcılaştırma, `{requested, delivered, device_online, command_id, offline_devices[]}` + nötr mesaj döndür, gerçek değeri durum mesajı belirlesin | B1/B2 |
| 3b | orta | Genel `POST /devices/:id/command` `set_child_lock` kabul eder ama DB/audit yazmaz; iki giriş yolu farklı davranır. Tek uygulama: `setChildLock` = `validateCommand` + aynı dağıtım | B1/B2 |
| 4 | yüksek | `server/test/devices/child_lock.test.js` yok (route/servis/köprü→homes senkronu/şema sözleşmesi) | B11/C8 |
| 5 | yüksek | Açılışta şema doğrulaması yok; `scripts/migrate.js` (020/021 başlıklarında anılıyor) yok, `schema_migrations` yok | C4/A2 |
| 6 | orta | Aynı ev için eşzamanlı iki geçiş sırayla yayınlanıp ters sırayla commit olabilir; `homes` satırı `FOR UPDATE` ya da `pg_advisory_xact_lock` ile serileştirin | B1 |
| 7 | orta | `mqtt_bridge` retained yolu (`live=false`) `devices.child_lock_enabled` yazıyor; bridge yeniden bağlanınca bayat retained, yeni uygulanmış komutu ezer. Çevrimdışı pano dışında retained'dan yazma | C1 |
| 8 | orta | `emergencyReset` yalnız `homes.child_lock_enabled=FALSE` yapar; `devices.child_lock_enabled` ve panonun NVS kilidi yerinde kalır, devredilen pano yeni sahibe kilitli gider. `replaceBoard` kilidi taşımaz/yeniden uygulamaz. Çevrimdışı→çevrimiçi uzlaştırma yok | B5/B6 |
| 9 | düşük | `last_id` boş dizge (taze pano) `validateStatePayload`'da geçersiz sayılıp her heartbeat'te uyarı üretiyor | C1 |
| 10 | düşük | Ev başına hız sınırı (`POST /child-lock` 6/dk, 30/sa) + zaten istenen değerdeyse no-op; her geçiş panoda NVS yazar ve bip çalar | B1 |
| 11 | düşük | `child_lock_set` denetim olayı yok; kullanıcıya dönen mesajlar ASCII'ye çevrilmiş Türkçe (ör. "Cocuk kilidi aktif"), UTF-8 olmalı; `GET` yanıtında `Cache-Control: no-store` yok | B1 |
| 12 | düşük | `homes/devices.child_lock_enabled` nullable (NOT NULL + geri doldurma), `peace_notification_time` için HH:MM `CHECK` yok | C3 |
| 13 | düşük | `CONTRACTS.md §1.5`'te child-lock REST satırları yok (`POST /devices/child-lock`, `GET /devices/child-lock/:home_id`) | doküman |
| 14 | operasyon | `server/.env` git'te izleniyor ve canlı sır içeriyor; `MQTT_USER/MQTT_PASS` tanımlı, köprü `MQTT_BACKEND_USER/MQTT_BACKEND_PASS` bekliyor ve yoksa kapalı kalıyor (her komut `502`) | A13/C5 |

### 3.3 Flutter (ham rapor: `cocuk-kilidi-flutter-denetimi.md`, 13:01 görüntüsü)

**Durum katmanı** (D paketi, 12:45'te yeniden yazıldı: `automation_state.dart` ~2936 satır, `command_pipeline.dart`, `capabilities.dart`, `endpoint_sync.dart`, `test/support/fakes.dart`) kilit için CONTRACTS §5'in büyük kısmını
uyguluyor: `Capabilities` kapısı `toggleChildLock` içinde, komut başına `CommandPipeline` ve `409 DEVICE_OFFLINE / 403 / 502 / ağ / delivered=false` için anında geri alma, MQTT `state.child_lock` + LAN yoklama senkronu,
çıkış/ev değişimi/misafir bitişinde sıfırlama, LAN çağrısında `X-Device-Key`. **Arayüz ve test taşınmadı** (`device_settings_page.dart`, `dashboard_page.dart`, kartlar, `test/child_lock_and_night_notification_test.dart`): derlenmiyorlar.
Geçici betiklerle (probe) bulunan **kalan durum/pipeline hataları — D paketi için, yüksekten başlayarak:**

| # | Önem | Bulgu | Düzeltme |
|---|---|---|---|
| D1 | yüksek | `command_pipeline.dart:560` `CommandConfirm.childLock` `childLockKnown`'ı yok sayıyor; `_loadEndpoints` REST'ten türetilmiş `DeviceStatus(childLockKnown:false, childLock:false)` ile uçuştaki **KİLİT AÇMA** komutunu yanlışlıkla "doğrulanmış" sayıyor, sonraki REST hatası yutuluyor (UI "açık", pano kilitli) | `(s) => s.childLockKnown && s.childLock == enabled`; REST türevi anlık görüntüleri doğrulanamayan anahtarlar için yok say; pipeline testi ekle |
| D2 | yüksek | `automation_state.dart:2299` `if (ok) _childLock = enabled;` REST "delivered" der demez hedefi gerçek değer yapıyor; cihaz hiç doğrulamazsa 2,5 sn sonunda "geri alındı" snackbar'ı çıkar ama anahtar kapalı konuma dönmez | Durum modunda teslimde kalıcılaştırma; yalnız pipeline girdiyi bıraktığında (onay/zaman aşımı) uygula |
| D3 | orta | `command_pipeline.dart:340` 2,5 sn doğrulama süresi submit anında başlıyor; REST gecikmesi bütçeden yeniyor → yanlış zaman aşımı. REST 2,0 sn'de cevap verir, durum 2,7 sn'de gelirse "geri alındı" gösterilir ama komut uygulanmıştır | Zamanlayıcıyı `_onResult`'ta teslimde yeniden başlat (üst sınır ~10 sn); zaman aşımında nötr mesaj + anında REST yeniden eşitleme |
| D4 | orta | `_loadChildLockAndPeace` (`:1653`) tazelik denetimi yok: bayat GET daha yeni MQTT durumunu eziyor (≤ 30 sn yanlış UI); REST hataları yalnız loglanıyor | `requestedAt` kaydet, daha yeni canlı anlık görüntü varsa uygulama; hatada `unknown` |
| D5 | yüksek | Kilit düz `bool` (varsayılan `false`), çıkış/ev değişiminde `false`: bilinmeyen durum "Devre Dışı (Anahtarlar Serbest)" görünür (ebeveyn denetimi özelliğinde fail-open). Çevrimdışı panonun retained durumu "güncel" gösteriliyor | `ChildLockStatus {unknown, unlocked, locked}` + `childLockPending` + `childLockStale` + `childLockUpdatedAt`; arayüzde "Durum alınıyor…" / "Son bilinen" |
| D6 | düşük | `childLockKnown: json.containsKey('child_lock')` `null`/çöp değer için `true` (`models/automation_models.dart:303`); tek `_childLock` iki pano arasında gidip gelir; misafir REST anlık görüntüsü almıyor; `_enterBackground` bekleyen komutu sessizce düşürüyor; `setChildLock` `delivered` yoksa `true` varsayıyor (`api_models.dart:80-84`, fail-open; 8 sn zaman aşımı) | `asBool(...) != null`; uid başına tut + "karışık"; `canViewState` ile yükle; `CommandResult` döndür, bu rota için `delivered` varsayılanı `false` |
| D7 | orta | `automation_state.dart:1802-1805` doğrudan modda her 1,5 sn yoklamada değişim olmasa da `notifyListeners()` — tüm sayfa yeniden çizilir (akıcılık hedefiyle ilgili) | Değişim yoksa bildirme |
| D8 | düşük | `test/support/fakes.dart:327` `FakeCloudApi.setChildLock` `{'child_lock': enabled}` döndürüyor; gerçek rota `{home_id, child_lock_enabled, delivered, device_online, command_id, message}`; `delivered=false` simüle edilemiyor. Peace fake'i `{'enabled':false}` döndürüp anahtar adı hatasını **gizliyor** | Sunucu şeklini döndür, sonuç kancası ekle |

**Arayüz (E paketi) — çocuk kilidi için:** (1) `isMember` kara listesi yerine `state.capabilities.canChangeChildLock` (eski koşul yanlıştı: `resident`'ı engelleyip `guest`'i engellemiyordu); misafir durumu salt-okunur görür.
(2) `AutomationState.commandFailures` akışına HİÇBİR widget abone değil → uygulama kabuğunda tek abone (`ScaffoldMessenger`), `CommandFailure.message` + yeniden denenebilirse "Tekrar dene"; widget başına snackbar'ı kaldır; `toggleChildLock`'un `bool`'una güvenme (çift dokunuşta `false` döner).
(3) Üç durumlu gösterim (unknown/pending/stale), açıklayıcı bilgi sayfası ("Neyi kilitler, neyi kilitlemez; elektrik kesintisinde de sürer; evdeki TÜM duvar anahtarlarını kapsar; kim değiştirebilir") ve başlık "Çocuk Kilidi" (jargon "Yazılımsal" kalksın).
(4) **Kilidi KAPATMAK için bilinçli eylem** (biyometrik ya da 1,2 sn basılı tutma); açmak tek dokunuş + `HapticFeedback`. Çocuğun açık telefonla tek dokunuşla kilidi kaldırması engellensin.
(5) Kilit rozeti dokunulabilir (bilgi sayfası), kartlarda/DI listesinde kilit simgesi ve "Kilitli: duvar anahtarları devre dışı" notu (misafirler ölü anahtarlara şaşırıyor). Cihaz tarafında engellenen basış için çift bip/LED + durumda sayaç (FW F7 + CONTRACTS §2.4).
(6) Açık tema: kart rengi `AppTheme.cardDark` sabit, başlığın kontrastı ≈ 1,2:1, rozet ≈ 1,5:1 (WCAG AA değil) → `getCardColor/getTextPrimary(context)`, açık temada koyu amber.
(7) Erişilebilirlik: anahtarın `Semantics` etiketi yok (`SwitchListTile` ya da `MergeSemantics`), durum değişimi `SemanticsService.announce`, rozet `liveRegion`.
(8) `context.watch<AutomationState>()` sayfa kökünde: her `notifyListeners`'da 10 kartlık sayfa yeniden çizilir → `context.select`/küçük `Consumer`'lar (akıcılık, Dalga 5).
(9) Test dosyası davranış testine çevrilmeli (`test/support` üzerinde); mevcut testler yalnızca iyimser bool'u doğruluyor ve eski toggle geri almadığı için geçiyordu; yeni geçit altında tasarım gereği kırılır.
(10) Bitişik hata (gece hatırlatması kartı): arayüz `peaceData['enabled']/['time']` okuyor, sunucu `peace_notification_enabled/_time` döndürüyor → kart hep "Aktif (Saat seçilmedi)"; fake yanlış anahtarları kodlayıp hatayı gizliyor.

**Sözleşme (CONTRACTS):** uygulamanın bağımlı olduğu `POST/GET /v1/devices/child-lock`, LAN `/api/child-lock` ve peace-notification yolları belgede yok; 2,5 sn zamanlayıcının ne zaman başladığı ve doğrudan modda `Capabilities` (localKeyHolder) anlamı yazılı değil. `EVOTOMASYON_CANLI_TEST_KONTROL_LISTESI.md`'de çocuk kilidi bölümü yok.

## 4. Gece hatırlatması — WP-H (bu oturumun işi)

> **Güncelleme (2026-10-01 ~18:00): kod HAZIR ve doğrulandı; entegrasyon "şimdi uygula" onayını bekliyor.** Sunucu modülleri ve `peace_service.js` yazıldı; gerçek PostgreSQL 18.4'te
> `001…030` migrate edilip tüm testler (peace + `pg_live` + köprü) geçti. Kilitli dosyalardaki değişiklik izole kopyada uygulanıp **tüm paket yeşil** çalıştırıldı ve tek yama olarak hazırlandı:
> `wp-h-entegrasyon.patch`. Ayrıntı: `wp-h-entegrasyon-istekleri.md` (doğrulama, davranış değişiklikleri, dağıtım sırası, kararlar), `wp-h-contracts-satirlari.md` (CONTRACTS satırları),
> `wp-h-flutter/` (Flutter modülleri; sandbox'ta derlendi ve test edildi). Aşağıdaki "Durum" paragrafı **başlangıçtaki** (kod yazılmadan önceki) tespittir.

**Durum (başlangıç):** gerçek hatırlatma YOK. Ayar `GET/PUT` ve manuel `close-all` var; `homes.peace_notification_time/enabled`'ı okuyup tetikleyen hiçbir iş, push kanalı ya da bildirim kaydı yok.
`peace_notification_logs` gecede-bir kuralını zorlayamaz (`local_date`/`status`/benzersiz anahtar yok). Commit edilmiş HEAD'deki huzur kodu ayrıca bozuk (olmayan sütunlar, olmayan `mqttBridge.publish`,
yalnız `authenticateToken` ile IDOR); çalışma ağacındaki WP-B yeniden yazımı bunları düzeltiyor.

**Tasarım** (ayrıntı: `gece-hatirlatma-backend-denetimi-ve-tasarim.md`): `homes.peace_notification_time` + `homes.timezone` ile yerel gece başına en çok bir kez, canlı cihaz anlık görüntüsünden
açık lamba/panjur varsa tek `peace_notification_logs` kaydı + owner/resident push token'larına tek FCM HTTP v1 push (`google-auth-library` zaten bağımlılık). Değerlendirici yalnız DB okur/push gönderir;
**MQTT komutu yayınlamaz, `endpoints`'e yazmaz.** Uygulama kapalıyken ulaşabilen tek kanal push olduğu için Flutter tarafında `firebase_messaging` + token kaydı gerekir; Firebase kimlik bilgisi
yoksa uygulama zarifçe devre dışı kalır, sunucu kaydı yazar ve `GET settings.last_notice` ile uygulama içi afiş çalışır.

**Bu oturumun YENİ dosyaları (mevcut dosyalarınıza dokunulmayacak):**

| Yol | Paket benzeri |
|---|---|
| `server/src/peace_reminder.js` | C (scheduler.js ile aynı yaşam döngüsü) |
| `server/src/services/peace_snapshot.js`, `peace_text.js`, `push_service.js`, `peace_service.js` (ayar GET v2 + Hepsini kapat v2) | B/C |
| `server/src/routes/push_routes.js` | A |
| `server/migrations/030_peace_reminder.sql` (018–029 sizin; çakışırsa 031…) | C |
| `server/test/peace/**` | — |

**Entegrasyon istekleri (sahipleri bitirince, ya da "şimdi uygula" derseniz):**

| Dosya | Sahip | Değişiklik |
|---|---|---|
| `server/src/server.js` | A | `scheduler` bloğunun yanına `peace_reminder` için aynı try/catch kancası + kapatma adımı (~10 satır); `push_routes`'ı `/api` ve `/api/v1` altına bağla |
| `server/src/services/device_service.js`, `routes/device_routes.js` | B | `getPeaceNotificationSettings` v2 (geriye uyumlu: `enabled/time` + uzun adlar, `timezone`, `devices_online`, `stale`, `open_shutters`, `last_notice`) ve `closeAllOpenLights` v2 (canlı anlık görüntü, panjurlar dahil, `notice_id`, tek transaction'da kaydı çöz, `endpoints.current_*` yazma) — hazır: `peace_service.js` + `wp-h-entegrasyon.patch` |
| `docs/CONTRACTS.md` | — | §1.5 satırları (peace v2, push-token uçları), §6 (`FCM_PROJECT_ID`, `FCM_SERVICE_ACCOUNT_FILE`/`GOOGLE_APPLICATION_CREDENTIALS`, `PEACE_REMINDER_ENABLED/DRY_RUN/HOME_ALLOWLIST`, `PEACE_CATCHUP_MIN`), §7 yeni satır H |
| `pubspec.yaml`, `lib/**`, `android/**`, `ios/**` | D/E | `firebase_core`, `firebase_messaging` (`flutter_local_notifications` **gerekmez**); token kaydı; bildirime dokununca onay sayfası + `close-all`; ayar sayfasında anahtar adı hizası. **Dalga 2 (E) bitmeden yazılmayacak.** |

**Dağıtım sırası (öneri):** `migrate.js --baseline` → 018+ (022 `homes.timezone`, 023/024 `devices.last_ack_*`, 030) → kod `PEACE_REMINDER_DRY_RUN=true` ile bir gece → Flutter sürümü → `DRY_RUN=false`.
`peace_notification_enabled` varsayılanı TRUE: token'ı olan her ev 23:30'da bildirim almaya başlar — **ürün kararı**.

## 5. Akıcılık / görsel cila (§5c, Dalga 5) için hazır girdiler

Bu oturum başlamıyor (orkestratörle mutabık kalındı: Dalga 5'i orkestratör yürütür). Bağımsız ölçüm ve tasarım denetimi yapıldı, girdiler bu klasörde hazır:

| Belge | İçerik |
|---|---|
| `akicilik-denetimi.md` | Donma/jank bulguları (dosya:satır, neden, düzeltme, doğrulama), hızlı kazanımlar, `AutomationState` yeniden çizim kapsamını testleri bozmadan bölme önerisi |
| `gorsel-denetim.md` | Mevcut görünümün dürüst tarifi, zayıflıklar, tasarım yönü, belirteçler (design tokens), bileşen bileşen yükseltme planı (dosya, teknik, performans notu, risk), bozulmaması gerekenler |
| `onizleme-yontemi.md` | `tool/preview/` düzeneği: gerçek sayfaları sahte durumla web olarak derleyip ekran görüntüsü alır; "önce/sonra" için `compare` komutu |
| `taban-cizgisi-olcumu.md` | 12:35/12:42 ölçümü (analyze/test/pio/npm) — Dalga 5 öncesi ve sonrası karşılaştırma için |

Dalga 4 bitince bu girdileri kullanın. İki not: (1) kullanıcı çocuk kilidi arayüzü için kapatmayı **bilinçli eylem** istiyor olabilir (§3.3 madde 4), bu tasarım dilinin parçası; (2) çocuk kilidi ve gece hatırlatması arayüzleri (E paketi) Dalga 5 cilasına girmeden önce işlevsel olarak bitmiş olmalı, yoksa cila iki kez yapılır.
