# Flutter çekirdek (WP-D) — API değişiklikleri

> **Kimler için:** E (arayüz) ve F (servis kurulum paneli) paketleri. Bu belge `lib/services/**`,
> `lib/models/**`, `lib/utils/**`, `lib/config/**`, `lib/main.dart` ve `test/support/**` değişikliklerinin
> **tek ve eksiksiz** özetidir; arayüz kodunu bu belgeye göre taşıyın. Sözleşme kaynağı: `docs/CONTRACTS.md`
> (§0, §1, §2, §3b, §5). "ESKİ" = WP-D öncesi API (git HEAD + çalışma ağacı); "YENİ" = bugünkü kod.
>
> **Beklenen durum:** `lib/ui/**` ve mevcut `test/*.dart` dosyaları şu an **derlenmez** (eski API'yi kullanır).
> Aşağıdaki tablolar hata satırlarını hızla bulup düzeltmeniz için yazıldı. Gizli değer (parola, PIN, anahtar,
> jeton) bu belgede yer almaz; örneklerdeki değerler **yer tutucudur**.

## İçindekiler

0. [Hızlı geçiş kontrol listesi](#0-hızlı-geçiş-kontrol-listesi)
1. [Mimari ve bağımlılıklar](#1-mimari-ve-bağımlılıklar) (DI, `Clock`, `AppConfig`, `buildApp`)
2. [Kırıcı değişiklikler: ESKİ → YENİ](#2-kırıcı-değişiklikler-eski--yeni)
3. [Yetki: `Capabilities`](#3-yetki-capabilities)
4. [Komut hattı ve komut geri bildirimi](#4-komut-hattı-ve-komut-geri-bildirimi) (`CommandPipeline`, `ChildLockStatus`)
5. [Oturum, olaylar ve hata modeli](#5-oturum-olaylar-ve-hata-modeli)
6. [Hesap uçları (A paketi)](#6-hesap-uçları-a-paketi) (parola değiştirme, tüm cihazlardan çıkış, OTP, sihirli bağlantı)
7. [Servis oturumu ve servis kurulum sihirbazı (F)](#7-servis-oturumu-ve-servis-kurulum-sihirbazı-f)
8. [Doğrudan (LAN/AP) mod](#8-doğrudan-lanap-mod)
9. [Çevrimiçilik türetmesi](#9-çevrimiçilik-türetmesi)
10. [QR / Wi-Fi QR / sihirli bağlantı çözücüler](#10-qr--wi-fi-qr--sihirli-bağlantı-çözücüler)
11. [`AppConfig` ve `dart-define`](#11-appconfig-ve-dart-define)
12. [Test yardımcıları (`test/support`)](#12-test-yardımcıları-testsupport)
13. [Sözleşmeden sapmalar, sınırlar ve açık noktalar](#13-sözleşmeden-sapmalar-sınırlar-ve-açık-noktalar)
14. [Sunucu davranış eklemeleri (push belirteci gizliliği, çevrimiçi olunca uzlaştırma)](#14-sunucu-davranış-eklemeleri-2026-10-01-plan-5d-1-ve-5d-3)

---

## 0. Hızlı geçiş kontrol listesi

Arayüz kodunda şunları arayın ve değiştirin (ayrıntı §2'de):

| Ara | Yapılacak |
|---|---|
| `int homeId`, `home.id` / `endpoint.id` / `user.id` / `rule.id` bir `int` gibi kullanılıyor | Hepsi **`String`** (UUID). `idStr`, `effectiveId`, `id.toString()` kalktı. |
| `shutter.pairIndex`, `cmdShutter(pairIndex, ...)`, `setShutterPosition(pairIndex, ...)` | **`shutter.pair` (1 tabanlı)**. Eski 0 tabanlı sıra numarası YOK. |
| `state.isMember` | Kalktı. `state.capabilities.*` kullanın (§3). |
| `state.generateServiceToken(...)` | `state.generateServicePin()` (→ `Future<String>` PIN). |
| `state.commissionSystem(notes:)` | `state.commission(checks: CommissioningChecks(...), notes:)` (→ `CommissioningResult`). |
| `state.emergencyResetDevice(deviceUuid:, reason:, newOwnerIdentifier:)` | `confirmUid:` **zorunlu** eklendi; dönüş `EmergencyResetResult` (Map değil). |
| `state.replaceBoard(...)` dönüşü `Map` | `ReplaceBoardResult` (`migratedEndpointsCount`, `newDeviceUuid` alanları artık gerçekten çalışır). |
| `res['message']`, `res['otp']` (OTP / şifre sıfırlama) | `CodeChallenge` (`.message`, `.expiresIn`, `.resendAfter`). |
| `user.token`, `HomeModel.mqttUsername` | `user.token` kalktı (jeton yalnız güvenli depoda). `home.mqttTopicId`. |
| `toggleChildLock(bool)` dönüşüne güvenmek / düz `bool childLock` | `childLockStatus` (§4.3). `childLock` yalnızca "kilitli mi?" kısayoludur; `unknown` = `false` görünür. |
| `state.isConnected`, `isMqttConnected` | Anlamları ayrıldı: `deviceOnline`, `brokerConnected`, `connState` (§9). |
| `e.toString().replaceFirst('Exception: ', '')` | Çalışmaya devam eder (`ApiException.toString()` = Türkçe mesaj). Tercihen `friendlyError(e)` (`lib/utils/friendly_error.dart`). |
| `await state.updateEndpoint(...)` sonucunu `bool` sanmak | `Future<void>`; hata **fırlatır** (eskiden yutulurdu). |
| `state.setMode(...)` dönüşü `Future<void>` | `Future<bool>` (`false` = yetki yok, mod değişmedi). |
| Her sayfada kendi `commandFailures` snackbar'ı | Uygulama kabuğunda **tek** abone (`state.commandFailures`) yeterli (§4.2). |
| Çıkış / oturum sonu için kendi yönlendirmesi | `state.sessionEvents` + `state.authStatus` (§5). |

---

## 1. Mimari ve bağımlılıklar

### 1.1 `AutomationState` kurucusu (CONTRACTS §5)

```dart
AutomationState({
  EvCloudApiService? cloudApi,
  EvMqttService? mqttService,
  SecureStorageService? secureStorage,
  BiometricAuthService? biometricService,
  AutomationApiService? directApi,   // LAN/AP istemcisi (boş adresle başlar)
  Clock? clock,                      // varsayılan SystemClock
  bool autoInit = true,              // false: _init çalışmaz (testler elle kurar)
  bool observeAppLifecycle = true,   // AppLifecycleListener bağla
  Duration biometricRelockAfter = const Duration(seconds: 30),
  Duration directPollInterval = const Duration(milliseconds: 1500),
  Duration confirmTimeout = const Duration(milliseconds: 2500),
})
```

* Verilmeyen bağımlılıklar gerçekleriyle kurulur ve **durum tarafından kapatılır**; verilenlerin sahipliği
  çağırandadır.
* `late final Future<void> ready` — başlatma (`_init`: depodan oturum geri yükleme, biyometrik kilit, ilk senkron)
  bitince tamamlanır (testler/`integration_test` için).
* **`EvCloudApiService` artık singleton değildir**: `EvCloudApiService({String? baseUrl, http.Client? client, Clock clock})`.
  `EvCloudApiService()` her çağrıda yeni örnek üretir. Arayüz doğrudan `EvCloudApiService()` kurmamalı; `state.cloudApi`
  kullanılmalıdır (aynı oturum belirteçlerini paylaşır).
* `Clock` (`lib/services/clock.dart`): `now()`, `timer(duration, cb)`, `periodic(period, cb)`. Zamana bağlı her davranış
  (komut geri alma, oturum süresi, MQTT yenileme, misafir bitişi, LAN yoklaması, Wi-Fi bağlanma bekleme) bunu kullanır.
  Uygulama kodunda `DateTime.now()` / `Timer(...)` yerine `state.clock` kullanın.

### 1.2 `buildApp` (`lib/main.dart`)

```dart
Future<Widget> buildApp({AutomationState? state})
```

`main()` bunu kullanır; `integration_test` aynı ağacı sahte/yerel arka uca bağlı bir `state` ile başlatabilir.
`state` verilirse sahipliği çağırandadır. Mevcut davranış değişmedi (`runZonedGuarded`, `FlutterError.onError`
yalnızca hata **türünü** raporlar; `appErrorReporter` ile çökme servisi bağlanabilir).

### 1.3 `AppConfig` — bkz. [§11](#11-appconfig-ve-dart-define).

---

## 2. Kırıcı değişiklikler: ESKİ → YENİ

### 2.1 Modeller (`lib/models/*`)

| Sınıf | ESKİ | YENİ |
|---|---|---|
| `UserModel` | `int id`, `String idStr`, `effectiveId`, `String? token`, `isOwner/isResident/isGuest` (**küresel** rol sanılırdı) | `String id` (UUID; servis PIN oturumunda boş), `token` **yok**, `idStr/effectiveId` **yok**. Alanlar: `email`, `fullName`, `phone`, `role` (küresel: `user|service_user|super_user|service_session`), `adminNotes`, **`mustChangePassword`**, **`emailVerified`**. Getter'lar: `globalRole`, `isSuperUser`, `isServiceUser`, `isServiceSession`, `isServiceManagerOrSuper`. `isOwner/isResident/isGuest` **kalktı** (ev rolü `HomeModel`'de). `copyWith({fullName, phone, role, mustChangePassword, emailVerified})`. `fromJson` kimlik yoksa `FormatException`. |
| `HomeModel` | `int id`, `idStr`, `effectiveId`, `mqttUsername`, `role` | `String id`, `mqttTopicId` (boş olabilir), `role` (**ev bazlı**, normalleştirilmiş), `timezone`, `guestValidFrom`, `guestValidUntil` (misafir penceresi; kalıcı servis personelinde kurulum süresi bitişi), `serverMarkedExpired`, **`accessState`** (`HomeAccessState.active/notStarted/expired/unknown`). Getter'lar: `homeRole`, `isOwnerRole`, `isGuestRole`, `isGuestExpiredAt(now)`. `copyWith({role, serverMarkedExpired, accessState})`. |
| `HomeAccessState` | — | Yeni enum. `GET /homes` `access_state`: sunucu `active|not_started|expired` yollar; sözleşme `guest_expired` da yazar (ikisi de `expired`). `isBlocked` = `notStarted || expired`. |
| `EndpointModel` | `int id/homeId/deviceId`, `channel`, `shutterPosition` | `String id/homeId`, `String? deviceId`, **`String? deviceUuid`**, `channel` **1 tabanlı**, `int? shutterPair`, `pair` (getter; 1 tabanlı panjur no), `isPrimaryShutterRow`, `isRelayLike`, `deviceOnline`. JSON takma adları (`channel`, `endpoint_type`, `shutter_position`, `online`) okunur; asıl alanlar önceliklidir. Bozuk tek kayıt listeyi düşürmez (`parseList`). |
| `RelayItem` | `id`, `name`, `type` (0..3), `state`, `runtimeSec` | Aynı + `typeKnown` (cihaz `type` bildirmedi mi). MQTT v2 metin tipleri (`light`, `shutter_up`...) de çözülür. `copyWith({state})`. |
| `ShutterItem` | `int pairIndex` (**0 tabanlı**), `fromJson(int pairIndex, json, name)` | **`int pair` (1 tabanlı)**; `pos` (0..100), `target` (`int?`; `255` = hedef yok → `null`), `isMoving`, `direction` (0 durdu/1 yukarı/2 aşağı), `runtimeSec`, `isExt` (`pair > 4`), `upRelay`/`downRelay` (`2*pair-1`/`2*pair`). `fromJson(json, {required pair, required name, runtimeSec})`. Aralık dışı `dir` → 0 (durdu). |
| `DeviceStatus` | `deviceName, ip, wifi*, relays, dis, shutters, childLock` | Aynı + `childLockKnown`, `uid`, `firmware`, `seq`, `lastId`, `provisioned`, **`restricted`** (anahtarsız kısıtlı özet), `wifiConnectState` (`WifiConnectState`), `wifiConnectReason`, `wifiApActive/wifiApSsid/wifiApIp`, `timeSynced`, `mqttConfigured`, `mqttConnected`, `totalRelays/totalDis`, `extModuleEnabled/extModuleResponding`, `wifiLastReason`. Getter'lar: `relayById`, `shutterByPair`, `shutterRelayIds`, `controllableRelays`, `sameAs`. `fromJson(json, {filterPhantomShutters = true})`: LAN'da `is_shutter:false` ve (tipler lamba/darbe ise) hayalet çiftler süzülür; MQTT yükünde `false` verilir. LAN `status`'ta kimlik **`device`** alanındadır (`uid` yok) → `uid` oraya düşer; `device` kimlik değilse ad sayılır. |
| `ScheduledRule` | `int id/homeId/deviceId` | `String id/homeId/deviceId`; `ScheduledRule.validate(...)` ve `ScheduledRule.createPayload(...)` (snake_case; `channel` 1 tabanlı; `days_of_week` benzersiz 0..6). Geçersiz `days_of_week` kaydı atlanır. |
| `ServiceTokenModel` | `fromJson(json)` | `fromJson(json, {DateTime? now})`; yalnızca `pin` + `expiresAt`. PIN **yalnızca üretim anında** gelir. |
| `CommandResult` | (`Map`) | Yeni: `{delivered, deviceOnline, commandId, noChange, requested, offlineDevices}`. `CommandResult.fromJson(json, {deliveredDefault = true})`; çocuk kilidi için `false` kullanılır (alan yoksa iletildi SAYILMAZ). |
| `ClaimResult` | `Map` | `{homeId, homeName, deviceUuid, deviceCredential, customerAccount, technicianAccessExpiresAt, warnings, raw}`; **`raw` içinde `device_credential` yoktur**. |
| `InvitationModel`, `HomeMember`, `JoinHomeResult`, `TransferInfo`, `TransferAcceptResult` | `Map` | Tipli. `HomeMember.userId` **String**. Davet: `code`, `role`, `expiresAt`, `qrContent` (`AHBU-INVITE:<kod>`). Devir: `code`, `qrContent` (`AHBU-TRANSFER:<kod>`). |
| `CommissioningChecks / CommissionCheck / CommissioningResult` | — (`commissionSystem(notes)`) | 5 zorunlu kontrol: `relays, buttons, shutters, network, cloud` (her biri `{ok, detail}`); `tests_passed` **sunucuda** hesaplanır → `CommissioningResult.testsPassed`. |
| `DeviceInfo` | — | `{deviceUuid, name, online, lastSeenAt, firmware}` (`GET /homes/:id/devices`). |
| `MqttCredentials` | — | `{host, port, username, password, expiresAt, topicId, clientId}`; `toString` parolayı gizler. |
| `ServiceSessionInfo` | — | `{homeId, homeName, expiresAt, technicianName}`; `remaining(now)`, `isExpiredAt(now)`. |
| `CodeChallenge` | `Map` | `{message, expiresIn, resendAfter (varsayılan 60 sn), debugCode, debugToken}` (debug alanları **yalnız release dışı** dolar). |
| `ChildLockInfo / ChildLockDeviceInfo` | — | `GET /devices/child-lock/:home` yanıtı (§4.3). |
| `DeviceMqttCredential` | — | Cihazın bulut kimliği: `{host, port, username, password, topicId, clientId}` (`mqtt_server/mqtt_port` varsa onlar `host/port` olur); `toLanConfigBody()`; **parola `toString`'e yazılmaz, saklanmaz** (§7). |
| `EmergencyResetResult`, `ReplaceBoardResult`, `ResetNewOwner`, `ShutterRuntimeSync` | `Map` | Tipli (§7.4). |
| `ServiceTokenSummary / ServiceSessionSummary / RevokeServiceAccessResult` | — | Ev sahibinin servis erişimi yönetimi (§7.2). |
| `PeaceNotificationSettings / CloseAllResult` | `Map` | Gece (huzur) ayarı ve "hepsini kapat" sonucu (§2.5). |
| `Capabilities`, `GlobalRole`, `HomeRole` | — | Bkz. §3. |

### 2.2 `EvCloudApiService` (`lib/services/ev_cloud_api_service.dart`)

Tüm yanıtlar merkezi `_decode` ile çözülür; hatalar **`ApiException`**'dır (bkz. §5.2). Tüm kimlik/yol parametreleri **String** (UUID).

| ESKİ | YENİ |
|---|---|
| `EvCloudApiService()` singleton, gömülü yönetici API anahtarı, `_adminHeaders` | Singleton **yok**; yönetici API anahtarı **silindi** (yetki yalnızca JWT). |
| `onTokenRefreshed` (senkron) | `FutureOr<void> Function(access, refresh)`, **beklenir** (yeniden deneme, dönen yeni refresh token kaydedildikten sonra gider). Yeni geri çağrılar: `onSessionExpired(SessionEndReason)`, `onGuestExpired(String? homeId)`, `onForbidden(String? homeId)`. Hepsini `AutomationState` bağlar; arayüz bağlamaz. |
| `refreshToken({token})` | `refreshSession()` (tek-uçuş). **Yalnız 401'de** refresh; **403 asla**; ağ/5xx/429'da oturum korunur; kalıcı red → `onSessionExpired`. Çıkış sonrası gelen yanıt yazılmaz (`sessionGeneration`). |
| `login/register/loginWithGoogle/loginWithApple/verifyPhoneOtp/magicLogin` → `Map` | Aynı (ham yük `Map`; belirteçler otomatik yeni oturum olur). `loginWithGoogle({required String idToken})`, `loginWithApple({required identityToken, fullName, nonce})`. |
| `sendPhoneOtp`, `forgotPassword` → `Map` | → **`CodeChallenge`**. |
| `resetPassword({required identifier, code, token, newPassword})` | `identifier` **isteğe bağlı** (bağlantı `token`'ı ile gerekmez); `code` ile gerekir. |
| — | **Yeni:** `changePassword({currentPassword, newPassword})`, `logoutAll()`, `registerPushToken/unregisterPushToken`, `reissueDeviceMqttCredential`, `listServiceTokens/listServiceSessions/revokeServiceAccess`, `sendAdminUserReset`, `fetchChildLockInfo`, `mqttCredentials`, `sendCommand`, `devices`, `localKey`, `commission`. |
| `serviceLogin(String pin)` → `Map` | `serviceLogin(pin, {technicianName})` → `ServiceSessionInfo` (refresh token **yok**, süre `expiresAt`). |
| `fetchEndpoints(int homeId)` | `fetchEndpoints(String homeId)` → `List<EndpointModel>`. |
| `controlEndpoint(int homeId, int endpointId, String command, {value}) → bool` | `controlEndpoint(String homeId, String endpointId, {cmd, state, pos}) → CommandResult`. **Yeni kod `sendCommand` kullanır** (`POST /devices/:id/command`; uygulama MQTT'ye yayın yapmaz). |
| `commissionSystem(int homeId, {notes, testsPassed = true}) → Map` | `commission({homeId, deviceUuid, checks, notes}) → CommissioningResult` (`tests_passed` istemci göndermez). |
| `createServiceToken(int homeId, {durationHours})` | `createServiceToken(String homeId)` → `ServiceTokenModel` (süre sunucuda 2 saat). |
| `createInvitation(int homeId, {role, ...}) → Map` | `createInvitation(String homeId, {role='resident'\|'guest', durationHours (1..72), validFrom, validUntil, guestName}) → InvitationModel`. |
| `getHomeMembers(int) → List<Map>`, `removeHomeMember(int, int)` | `getHomeMembers(String homeId) → List<HomeMember>`, `removeHomeMember(String homeId, String targetUserId)`. Hata **fırlatılır** (eskiden boş liste/false). |
| `initiateTransfer(dynamic, {targetIdentifier?})` | `initiateTransfer(String homeId, {required String targetIdentifier})` → `TransferInfo`. |
| `claimDevice(...) → Map` | `claimDevice({deviceUuid, setupPin, homeName, targetOwner, otpCode}) → ClaimResult`. **`home_id` gövdeye yazılmaz.** |
| `emergencyResetDevice(...) → Map` | → `EmergencyResetResult` (§7.4). |
| `replaceBoard(...) → Map` | → `ReplaceBoardResult` (§7.4). |
| `setChildLock({dynamic homeId, enabled}) → Map` | `setChildLock({String homeId, enabled}) → CommandResult` (§4.3). |
| `getChildLock(dynamic) → bool` (hata `false`) | `getChildLock(String) → bool` **hata fırlatır**; ayrıntı için `fetchChildLockInfo` → `ChildLockInfo`. |
| `getScheduledRules(int) → Map` | `getScheduledRules(String homeId) → List<ScheduledRule>`; `updateScheduledRule(homeId, String ruleId, ...)`, `deleteScheduledRule(homeId, String ruleId)`. |
| `createAdminUser({..., required password})` | `password` **isteğe bağlı**: servis personeli parola veremez (`403`); parolasız hesap `pending_invite` olur ve davet e-postası gider. `updateAdminUser(..., currentPassword)` (başka süper kullanıcının parolası için zorunlu; `REAUTH_REQUIRED`). |
| `updateEndpoint(...) → Map` | `updateEndpoint({homeId, endpointId, name, room, type, shutterDurationSec (1..300)})`. |

### 2.3 `AutomationApiService` (LAN/AP) — ayrıntı §8

| ESKİ | YENİ |
|---|---|
| `AutomationApiService({baseUrl = 'http://192.168.4.1'})` | `AutomationApiService({baseUrl, localKey, client, clock})`. Varsayılan adres `AppConfig.current.deviceApBaseUrl`. Kurtarma AP'si için `AutomationApiService.recoveryAp({localKey, client, clock})`. |
| anahtarsız istekler | Her istekte **`X-Device-Key`** (`localKey`); JSON POST'ta `Content-Type: application/json`. Hatalar `LocalApiException` (§8.3). |
| `cmdShutter(int pairIndex, action)` (0 tabanlı) | `cmdShutter(int pair, String action, {int? value})` — **pair 1 tabanlı**; `action = up|down|stop|step|pos`; `pos` için `value` (0..100) **zorunlu** (`val=`). `setShutterPosition(pair, value)`. |
| `toggleRelay(channel)` | + `setRelay(channel, on)` (idempotent, `state=1/0`); kanal 1..64. |
| `scanWifiNetworks()`, `connectWifi(...) → bool` | `scanWifiNetworks({refresh, isCancelled})` (`List<Map>`), **`scanWifi(...)` → `List<WifiNetwork>`**; `connectWifi(...)` → `Future<void>` (**bağlandı demek değildir**), **`awaitWifiConnection`**, **`connectWifiAndWait`**. |
| — | **Yeni:** `fetchPublicStatus`, `factoryInit`, `rekey`, `checkKey`, `configureMqtt`, `fetchChildLock`, `updateHost` (yalnız yerel adresler), `isAllowedDeviceHost`, `isValidLocalKey`. |

### 2.4 `EvMqttService` (`lib/services/ev_mqtt_service.dart`)

Arayüz doğrudan kullanmaz (durum bağlar). Değişenler:

| ESKİ | YENİ |
|---|---|
| Gömülü kullanıcı/parola, `connect(...)`, `subscribeToHome`, `publishCommand`, `sendRelayCommand`, `sendShutterCommand`, `sendScenarioCommand` | **Hepsi silindi.** Uygulama **yalnızca abone olur** (`ev/{t}/state`, `ev/{t}/status`); komutlar REST'ten gider. Kimlik sunucudan (`POST /homes/:id/mqtt-credentials`), süre dolmadan yenilenir. |
| `stateStream` (`Map`), `statusStream` | `stateMessages` (`DeviceStateMessage{topicId, status: DeviceStatus, retained, receivedAt}`), `statusMessages` (`DevicePresenceMessage{topicId, online, retained, receivedAt}`), **`linkStates`** (`Stream<MqttLinkState>`: `disconnected/connecting/connected/reconnecting`), `linkState`, `lastFailure`, `droppedMessageCount`, `topicId`. |
| Sabit istemci kimliği | Oturuma özgü benzersiz `clientId`. Mesaj yığınındaki **tüm** iletiler işlenir; bozuk yük atılır (`droppedMessageCount`). |
| TLS sabit | `AppConfig.current.mqttUseTls` (`MQTT_TLS=false` yalnız debug). Host/port `mqtt-credentials` yanıtından gelir. |

### 2.5 `AutomationState` — özellikler (getter) ve metotlar

**Kaldırılan / yeniden adlandırılan**

| ESKİ | YENİ |
|---|---|
| `isMember` | kalktı → `capabilities` |
| `generateServiceToken({durationHours})` | `generateServicePin()` → `Future<String>` |
| `commissionSystem({notes})` | `commission({required CommissioningChecks checks, String? notes, String? deviceUuid, String? homeId})` → `CommissioningResult` |
| `isOwner/isGuest` (**küresel** rol) | **Aktif evdeki** rol (`activeHome.homeRole`) |
| `isServiceMode` | `isServiceUser \|\| isServiceSession` |
| `bool childLock` (düz) | `childLockStatus` (+`childLockPending/Stale/UpdatedAt`) |
| `isMqttConnected` | `brokerConnected` (eski ad kısayol olarak durur) |
| `isConnected` | `deviceOnline` (bulut) / doğrudanda cihaz yanıtı (§9) |
| `fetchHomes()` | `fetchHomes({autoSelect = true})`; **hata ayrımı** (aşağıda) |
| `toggleRelay(int)`, `triggerImpulse(int)` → `Future<void>` | → `Future<bool>` ("iletildi mi"; sonuç sonradan `commandFailures` ile) |
| `setShutterPosition(int pairIndex, int percent)`, `cmdShutter(int pairIndex, ...)`, `getShutterPosition(int pairIndex)` | `pair` **1 tabanlı** (`setShutterPosition(int pair, int percent) → Future<bool>`, `cmdShutter(int pair, String action, {int? percent}) → Future<bool>`, `getShutterPosition(int pair) → int`) |
| `cmdAll(String)` → `Future<void>` | → `Future<bool>`; kabul edilenler: `lightsoff \| shuttersup \| shuttersdown \| shuttersstop` ve `all_lights_off`, `all_off`, `all_shutters_up/down/stop` |
| `toggleBiometric(bool)` → `Future<void>` | → `Future<bool>` (**açmak ve kapatmak doğrulama ister**; `false` = doğrulanamadı/desteklenmiyor) |
| `fallbackToPasswordLogin()` → `void` | → `Future<void>` (= `logout()`: belirteçler silinir, MQTT durur, refresh sunucuda iptal) |
| `loginWithServicePin(String pin)` | `loginWithServicePin(String pin, {String? technicianName})` |
| `setMode(AppMode)` → `Future<void>` | → `Future<bool>` |
| `createHomeInvitation(dynamic homeId, {...}) → Map` | `createHomeInvitation({String? homeId, String role='resident', int? durationHours, DateTime? validFrom, DateTime? validUntil, String? guestName}) → InvitationModel` (`homeId` **adlandırılmış**, isteğe bağlı) |
| `fetchHomeMembers([dynamic]) → List<Map>` | `fetchHomeMembers([String? homeId]) → List<HomeMember>` (hata fırlatır) |
| `removeHomeMember(dynamic, [dynamic])` | `removeHomeMember(String targetUserId, [String? homeId])` (yalnız `canManageMembers`) |
| `joinHome → Map`, `acceptHomeTransfer → Map`, `initiateHomeTransfer({targetIdentifier?, homeId}) → Map` | `JoinHomeResult`, `TransferAcceptResult`, `initiateHomeTransfer({required String targetIdentifier, String? homeId}) → TransferInfo`. Katılma/devir sonrası ev listesi (rol) yenilenir ve ev seçilir. |
| `claimDevice(...) → Map` | `claimDevice(String deviceUuid, String setupPin, {homeName, targetOwner, otpCode}) → ClaimResult` |
| `emergencyResetDevice({deviceUuid, reason, newOwnerIdentifier})` | `emergencyResetDevice({required deviceUuid, required confirmUid, required reason, newOwnerIdentifier}) → EmergencyResetResult` |
| `replaceBoard(...) → Map` | → `ReplaceBoardResult` |
| `updateEndpoint({int endpointId...}) → Future<bool>` | `updateEndpoint({required String endpointId, name, room, type, shutterDurationSec}) → Future<void>` (hata fırlatır) |
| `fetchEndpoints([dynamic homeId])` | `fetchEndpoints([String? homeId])` |
| `updateScheduledRule(int ruleId, ...)`, `deleteScheduledRule(int)` | `String ruleId`; `createScheduledRule({int channel (1 tabanlı), channelType, action, hour, minute, daysOfWeek, label, deviceId})` doğrulama hatası `ApiException.validation` |
| `scanRecoveryWifiNetworks()` (hata → `[]`), `sendRecoveryWifiCredentials(ssid, pass) → bool` | aynı adlar; **hata artık `LocalApiException` olarak fırlatılır** (eskiden `[]` / `false` döner, hata gizlenirdi); ikincisi `Future<void>` (kurtarma sihirbazı kendi `AutomationApiService.recoveryAp()` örneğini kullanmalı, §8.4) |

**Yeni okuma alanları (getter)**

| Alan | Anlam |
|---|---|
| `Capabilities capabilities` | Rol → yetki (§3). |
| `Stream<SessionEvent> sessionEvents` | `SessionExpiredEvent(reason)`, `GuestExpiredEvent(homeId, homeName)` (§5.1). |
| `Stream<CommandFailure> commandFailures`, `CommandPipeline commandPipeline` | Geri alınan komutlar (§4). |
| `String? sessionNotice` (+`clearSessionNotice()`) | Oturum bitince giriş ekranında gösterilecek tek seferlik Türkçe mesaj. |
| `String? storageError` (+`clearStorageError()`) | Güvenli depolama hatası (yazılamadı/okunamadı). Oturum bellekte açık kalır; kullanıcı uyarılmalı. |
| `bool mustChangePassword` | Sunucu parola değiştirmeyi zorunlu kıldı (§6). |
| `bool homesLoading / homesLoaded / homesFromCache`, `String? homesError`, `List<HomeModel> expiredHomes` | Ev listesi durumu ("ev yok" ile "hata" artık ayrı). |
| `bool endpointsLoading / endpointsLoaded`, `String? endpointsError`, `List<EndpointModel> cloudEndpoints`, `List<DeviceInfo> devices` | Aktif ev verisi. `cloudEndpoints` bekleyen komutların iyimser değerlerini içerir. |
| `List<RelayItem> relayItems`, `List<ShutterItem> shutterItems` | Moda göre (bulut/LAN) birleşik görünüm; panjurlar benzersiz, `pair` 1 tabanlı. |
| `DevicePresence devicePresence`, `bool deviceOnline`, `bool brokerConnected`, `MqttLinkState mqttLinkState`, `ConnectionStateEnum connState` | §9. |
| `bool isGuestExpired`, `isOwner`, `isGuest`, `isServiceSession`, `ServiceSessionInfo? serviceSession`, `Duration? serviceSessionRemaining` | §3 / §7. |
| `ChildLockStatus childLockStatus`, `childLockPending`, `childLockStale`, `childLockUpdatedAt`, `childLockRequested`, `childLockAwaitingDevices`, `childLockOfflineDevices` | §4.3. |
| `Map? peaceNotificationData`, **`PeaceNotificationSettings? peaceSettings`** | Gece ayarı. **`peaceNotificationData` sunucunun uzun anahtarlarını taşır** (`peace_notification_enabled/_time`); eski arayüz `['enabled']/['time']` okuyordu (kart hep "Saat seçilmedi" görünürdü). `peaceSettings.enabled / .time / .openLightsCount / .summaryText` kullanın. |
| `Future<void> ready`, `bool isInBackground`, `lastKnownDeviceIp`, `directError`, `hasLocalKey`, `selectedDeviceUuid/Ip/Name`, `hasSelectedDevice` | — |

**Davranış değişiklikleri (imza aynı kalsa da)**

* `fetchHomes()` hata ayrımı: başarıda `homesLoaded=true`; ağ hatası + önbellek varsa önbellek gösterilir (`homesFromCache`) ve `homesError` dolar;
  ağ hatası + önbellek yoksa liste boş **ve** `homesError` dolu; 401 → oturum sonu olayı; 5xx → genel mesaj, mevcut liste silinmez.
  Başka kullanıcının önbelleği kullanılmaz. Gecikmiş yanıt (çıkış/hesap değişimi sonrası) atılır.
* `refresh()`: aktif ev yoksa önce `fetchHomes`; tek-uçuş; yoksa tüm istekler birleşir.
* `selectHome(home)`: **tüm** ev kapsamlı önbellekler (uç noktalar, cihazlar, durum, kurallar, servis PIN, bekleyen komutlar, MQTT, çocuk kilidi bilgisi) sıfırlanır.
* `logout()`: **önce yerel temizlik** (tüm alanlar, abonelikler, zamanlayıcılar, servis PIN, MQTT, güvenli depo, `saved_service_device_*` tercihleri), **sonra** sunucuda refresh iptali (en iyi çaba).
* Hesap değiştirme (`login` başka kullanıcıyla): önceki kullanıcının hiçbir verisi kalmaz; önceki refresh token iptal edilir.
* Oturum açık + arka plan: MQTT ve yoklama durur, bekleyen komutlar iptal; ön plana dönüşte **tek** snapshot + yeniden bağlanma; `biometricRelockAfter` aşıldıysa biyometrik kilit (doğrulanana kadar ağ/MQTT yok).
* Kimlik/oturum belirteçleri **yalnızca güvenli depoda** (iOS `first_unlock_this_device`); SharedPreferences'ta belirteç yok; eski `saved_auth_token` açılışta silinir.
* Yetki kapıları metotlarda da vardır (`ApiException.forbidden()`); UI gizleme tek başına yetki değildir.

### 2.6 `SecureStorageService`

`SecureStorageService({SecureKeyValueStore? store})` (test için bellek içi depo enjekte edilir). Hatalar **`SecureStorageException`** olarak
yüzeye çıkar ("okunamadı" ≠ "oturum yok"). ESKİ `saveAppMode/getAppMode` kalktı. **Yeni:** `saveLocalKey/getLocalKey/deleteLocalKey(deviceUuid)`,
`saveHomesCache/loadHomesCache/deleteHomesCache`, `saveServiceSession/getServiceSession/deleteServiceSession`. Cihaz MQTT kimliği, PIN, `setup_pin`
ve `local_key` (sunucudan alınan LAN anahtarı **hariç**) buraya YAZILMAZ.

### 2.7 Yardımcılar (`lib/utils/*`)

| ESKİ | YENİ |
|---|---|
| `QrClaimParser.parse(raw)` serbest metin (`UID:PIN`, `UID/PIN`, yalnız UID) kabul ediyordu; ham metin UUID olabiliyordu | **Sıkı:** yalnızca `https://<izinli ana makine>/claim?uid=&pin=` (https, kullanıcı bilgisi yok, port 443, tekrar eden parametre yok) veya `{"uid":"…","pin":"…"}` (**yalnız String** değerler). UID `^AHBU-[A-Z0-9-]{3,32}$`, PIN `^\d{6}$`, metin ≤ 512. `parse(raw, {allowedHosts})`, `parseDetailed`, `normalizeUid`, `isValidUid`, `isValidPin`. `QrClaimData.toString()` PIN'i gizler. |
| — | **`QrRouter.route(String?) → QrPayload`** (§10). |
| — | `WifiQrParser`, `MagicLinkParser`, `friendlyError` (§10). |

---

## 3. Yetki: `Capabilities`

`state.capabilities` (`lib/models/capabilities.dart`) — CONTRACTS §1.4 matrisinin istemci yansıması. **Beyaz liste**: bilinmeyen/eksik rol = hiçbir yetki.
**UI gizleme yetki değildir** (sunucu esastır); `AutomationState` metotları aynı nesneyle savunmacı denetim yapar.

Kurucu: `Capabilities({globalRole, homeRole, guestValidUntil, guestValidFrom, now, hasActiveHome})`; sabitler `Capabilities.none()`,
`Capabilities.localKeyHolder()` (oturumsuz LAN modu + elle girilmiş anahtar: yalnız durum + komut + adres/mod).

| Alan | Anlam |
|---|---|
| `isAuthenticated`, `isSuperUser`, `isStaff`, `isServiceSession`, `isOwner`, `isResident`, `isGuest`, `isGuestExpired`, `hasHomeAccess` | Kimlik/rol rozetleri. `isGuest` = **geçerli** misafir; süresi dolmuş/başlamamış misafir `isGuestExpired` (tüm ev yetkileri kapalı). |
| `canViewState`, `canControlDevices` | Durum görme / röle-panjur komutu (geçerli misafir dahil). |
| `canUseGroupCommands` | Toplu komut (`all_*`). Misafir ✖. |
| `canChangeChildLock` | Çocuk kilidi ve huzur bildirimi ayarı. Misafir ✖ (durumu **salt-okunur görür**). |
| `canCalibrate` | Panjur kalibrasyonu, kanal adı/oda. Sakin ✖, misafir ✖. |
| `canManageRules` | Zamanlı kural. Servis PIN oturumu ✖, misafir ✖. |
| `canInvite`, `canManageMembers` | Yalnız owner ve süper. |
| `canTransferOwnership`, `canGenerateServicePin` | Yalnız owner. |
| `canClaimDevice` | Cihaz sahiplenme: servis PIN oturumu ✖, misafir ✖; evsiz sade kullanıcı ✔. |
| `canCommission`, `canReplaceBoard`, `canEmergencyReset` | Devreye alma (süper/staff/oturum); pano değişimi (+owner); acil sıfırlama (süper + kalıcı servis personeli; **ev bağlamından bağımsız**). |
| `canOpenWifiRecovery`, `canEditDeviceHost`, `canSwitchMode` | Wi-Fi kurtarma / cihaz adresi / bulut-LAN modu. Misafir ✖. **`canOpenWifiRecovery` yalnız giriş yapılmış alanlardaki giriş noktalarını (pano/ayarlar kartı, sistem doktoru) gizler/gösterir**; `WifiRecoveryDialog` ve servis paneli "Pano Wi-Fi & Modem Kurulumu" kartı **yetki kapısızdır** (girişsiz/internetsiz/misafir dahil herkeste açılır; CONTRACTS §3d: cihaza özel kurulum ağı parolası = fiziksel erişim, uygulama sunucuya hiç istek atmaz). |
| **`canFetchLocalKey`** | Sunucudan LAN anahtarı alma: owner, resident, staff, servis oturumu. **Süper kullanıcı ✖** (sunucu matrisi). |
| **`canReissueDeviceCredential`** | Cihazın bulut kimliğini yenileme: owner, staff, servis oturumu, süper. Resident/misafir ✖. |
| `canViewInventory`, `canManageInventory`, `canOpenServiceManagement`, `canManageAdminAccounts` | Envanter / servis yönetim ekranı / yönetici hesapları (süper; servis personeli kendi stoku). |

Rol matrisi (✔ = `true`):

| Alan | süper* | staff | servis oturumu | owner | resident | misafir (geçerli) |
|---|:-:|:-:|:-:|:-:|:-:|:-:|
| canViewState / canControlDevices | ✔ | ✔ | ✔ | ✔ | ✔ | ✔ |
| canUseGroupCommands / canChangeChildLock | ✔ | ✔ | ✔ | ✔ | ✔ | ✖ |
| canCalibrate | ✔ | ✔ | ✔ | ✔ | ✖ | ✖ |
| canManageRules | ✔ | ✔ | ✖ | ✔ | ✔ | ✖ |
| canInvite / canManageMembers | ✔ | ✖ | ✖ | ✔ | ✖ | ✖ |
| canTransferOwnership / canGenerateServicePin | ✖ | ✖ | ✖ | ✔ | ✖ | ✖ |
| canClaimDevice | ✔ | ✔ | ✖ | ✔ | ✔ | ✖ |
| canCommission | ✔ | ✔ | ✔ | ✖ | ✖ | ✖ |
| canReplaceBoard | ✔ | ✔ | ✔ | ✔ | ✖ | ✖ |
| canEmergencyReset | ✔ | ✔ (global staff) | ✖ | ✖ | ✖ | ✖ |
| canOpenWifiRecovery / canEditDeviceHost / canSwitchMode | ✔ | ✔ | ✔ | ✔ | ✔ | ✖ |
| canFetchLocalKey | ✖ | ✔ | ✔ | ✔ | ✔ | ✖ |
| canReissueDeviceCredential | ✔ | ✔ | ✔ | ✔ | ✖ | ✖ |

\* Süper kullanıcı üyelik olmadan da ev bağlamında işlem yapabilir (açık istisna); aktif ev yokken yalnızca küresel yetkileri vardır.

Kullanım:

```dart
final caps = context.select<AutomationState, Capabilities>((s) => s.capabilities);
if (caps.canChangeChildLock) { /* anahtarı etkin göster */ }
```

Rol dizgileri normalleştirilir (`GlobalRole.parse`, `HomeRole.parse`; büyük/küçük harf, boşluk, eski adlar: `member`→`resident`, `installer`→`service_user`).
`Capabilities.toMap()` testler/hata ayıklama içindir.

---

## 4. Komut hattı ve komut geri bildirimi

### 4.1 Komutlar nasıl gider

* **Bulut:** REST `POST /devices/:id/command` (`home_id` + sözleşme yükü; röle/panjur **1 tabanlı**). Uygulama MQTT'ye **yayın yapmaz**.
* **Doğrudan (LAN):** `AutomationApiService` (`X-Device-Key`; `pair` 1 tabanlı; `pos` için `val`).
* Çevrimdışı cihaz: `409 DEVICE_OFFLINE` → **anında geri alma** + "Cihaz çevrimdışı".
* Komut `id`'si (geri yankı için) `^[A-Za-z0-9._:-]{1,24}$` kuralına uyar (≈ 12 karakter, `[a-z0-9]`); sunucu kendi kısa kimliğini döndürürse o kullanılır.

### 4.2 `CommandPipeline` (arayüzün bilmesi gerekenler)

`AutomationState` komut metotları (`setRelay`, `toggleRelay`, `setShutterPosition`, `cmdShutter`, `cmdAll`, `setChildLock`) komut hattını kullanır;
arayüz doğrudan çağırmaz. Kurallar:

* **Uç nokta başına tek bekleyen komut** (`relay:3`, `shutter:2`, `childLock`, `group:all_lights_off`...). Art arda dokunuş mevcut kaydın hedefini günceller;
  **ilk dokunuştaki gerçek değer** saklanır; gönderimler sıralanır (uçuşta en çok bir + bekleyen son niyet).
* REST yanıtı `delivered=false` / hata → **anında geri al** + `commandFailures` olayı.
* Cihazdan hedefi doğrulayan `state` (veya `last_id` yankısı) gelirse zamanlayıcı iptal olur → komut onaylı.
* **Onay penceresi 2.5 sn ve REST TESLİMİNDEN itibaren başlar** (REST gecikmesi bütçeden yemez); toplam üst sınır 10 sn (CONTRACTS §5'in "2.5 sn" ifadesinin
  inceltmesi: ağ gecikmesi yüzünden yanlış zaman aşımı gösterilmez). Pencerede onay yoksa değer geri alınır; mesaj **nötrdür** ("Cihazdan onay alınamadı. İşlem geri alındı; durum yeniden kontrol ediliyor.")
  ve durum hemen REST ile yeniden eşitlenir (komut uygulanmış olabilir).
* Geri alma = kaydın silinmesi; arayüz değeri "gerçek durum + bekleyen hedefler" olarak türetilir (`cloudEndpoints`, `relayItems`, `shutterItems`, `status`).
* Arka plana geçiş / çıkış / ev değişimi / `dispose`: tüm kayıtlar **olay üretmeden** iptal edilir.
* Onay modları (`CommandConfirmMode`): `state` (cihaz onayı), `delivery` (iletim = tamam: toplu komut, darbe, adım), `settle` (MQTT koptuysa; iletim başarılıysa değer pencere boyunca tutulur, **hata gösterilmez**, REST ile uzlaşılır).

**Geri alınan komutları göstermek (uygulama kabuğunda tek abone):**

```dart
state.commandFailures.listen((CommandFailure f) {
  // f.key (relay:3, childLock, ...), f.reason, f.message (Türkçe, kullanıcıya gösterilebilir)
  messenger.showSnackBar(SnackBar(content: Text(f.message)));
});
```

`CommandFailureReason`: `offline`, `notDelivered`, `timeout`, `network`, `forbidden`, `rateLimited`, `brokerUnavailable`, `validation`, `rejected`.
`state.cmd*` / `setRelay` dönüşü `Future<bool>` yalnızca **"iletildi mi"**'dir; çift dokunuşta önceki çağrı `false` döner (`superseded`) — arayüz buna güvenip hata göstermemeli.
`setChildLock` ise `CommandDispatch` döndürür: `status` (`delivered|failed|superseded|cancelled`), `ok`, `failure`, `result` (`CommandResult`).

### 4.3 Çocuk kilidi: `ChildLockStatus` API'si (D10 + D14)

Çocuk kilidi bir ebeveyn denetimi özelliğidir: **bilinmeyen durum "kilit kapalı" olarak gösterilmez** (fail-open yok).

```dart
enum ChildLockStatus { unknown, unlocked, locked, mixed }
```

| Alan | Anlam |
|---|---|
| `ChildLockStatus childLockStatus` | `unknown`: henüz cihazdan/sunucudan değer alınmadı ya da alınamadı ("Durum alınıyor…"). `unlocked`: duvar anahtarları serbest. `locked`: duvar anahtarları devre dışı. `mixed`: aynı evde birden fazla pano **farklı** bildiriyor (pano başına tutulur; kilitli/açık arasında gidip gelmez). Bekleyen komutun iyimser hedefi dahil. |
| `bool childLockPending` | Komut iletildi ama cihaz doğrulamadı: **"uygulanıyor…"**. REST `delivered:true` "uygulandı" demek DEĞİLDİR. |
| `bool childLockStale` | Görünen değer güncel olmayabilir: pano çevrimdışı ya da canlı kanal kopuk → **"Son bilinen"** göster. |
| `DateTime? childLockUpdatedAt` | Görünen değerin alındığı zaman (bilinmiyorsa `null`). |
| `bool childLock` | Kısayol: `childLockStatus == locked`. `unknown/mixed` → `false`; **kapıda kullanmayın**, `childLockStatus` kullanın. |
| `bool? childLockRequested` | Sunucuda kayıtlı en son **istek** (niyet); hiç istek yoksa `null`. |
| `bool childLockAwaitingDevices` | Sunucudaki istek cihazların bildirdiği durumdan farklı: istek henüz uygulanmadı (ör. pano çevrimdışı); çevrimiçi olunca uygulanır. |
| `List<String> childLockOfflineDevices` | Kilit komutunun iletilemediği çevrimdışı panolar (REST yanıtı / son POST). Çok panolu evde "bazı panolar çevrimdışı" uyarısı. |

Kurallar (hepsi testli — `test/services/child_lock_behavior_test.dart`):

1. **Cihaz bildirimi tek doğruluk kaynağıdır:** MQTT `state.child_lock` (pano uid'si başına) / LAN `status.child_lock`. REST yalnızca cihaz değeri yokken ya da canlı kanal **kopukken** kullanılır; kopukken REST'in pano satırları (`devices[]`) bayat cihaz değerlerinin yerine geçer.
2. REST `GET` **bayat** gelirse daha yeni cihaz bildirimini ezmez; REST hatası/401/403/5xx **`unknown`** bırakır ("kilitsiz" sanılmaz).
3. Bekleyen komut varken `refresh()`/GET görünen değeri **ezmez**; REST'ten türetilen anlık görüntü (`childLockKnown:false`) bir kilit komutunu **doğrulayamaz**.
4. `POST /devices/child-lock` yanıtında **gerçek durum yoktur** (`child_lock_enabled` YOK): `{home_id, requested, delivered, device_online, command_id, offline_devices[], no_change?}`.
   `delivered` yoksa iletildi sayılmaz. `no_change` → anında doğrulanmış sayılır. `409 DEVICE_OFFLINE` → anında geri alma + `childLockOfflineDevices`.
5. LAN: `POST {"enabled":bool}` (`X-Device-Key`; cihaz `queued` yanıtlar), 4xx → geri alma; hızlı ardışık dokunuş korumalı (tek uçuş + son niyet).
6. Çıkış / ev değişimi / misafir bitişi: `unknown`'a döner. Misafir kilidi **salt-okunur görür** (`canViewState`), değiştiremez.
7. Doğrudan modda değişmeyen yoklamalar `notifyListeners()` çağırmaz (sayfa gereksiz yeniden çizilmez).

Önerilen arayüz eşlemesi: `unknown` → "Durum alınıyor…" (anahtar pasif); `pending` → "Uygulanıyor…"; `stale` → "Son bilinen: kilitli (saat)"; `mixed` → "Panolar farklı durumda".
**Kilidi KAPATMAK bilinçli eylem olmalı** (biyometrik / basılı tutma) — arayüz (E) kararı.

---

## 5. Oturum, olaylar ve hata modeli

### 5.1 Oturum olayları (tek merkez)

`state.sessionEvents` (`Stream<SessionEvent>`, broadcast):

```dart
sealed class SessionEvent
final class SessionExpiredEvent extends SessionEvent { final SessionEndReason reason; }
final class GuestExpiredEvent extends SessionEvent { final String? homeId; final String? homeName; }
```

| Olay | Ne zaman | Durum katmanı ne yapar | Arayüz ne yapar |
|---|---|---|---|
| `SessionExpiredEvent(reason)` | refresh token **kalıcı** reddedildi (`refreshRejected`), access token geçersiz ve yenilenemedi (`invalidToken`), refresh yok (`noRefreshToken`), 2 saatlik servis oturumu bitti (`serviceSessionExpired`) | Yerel oturum silinir (depo, MQTT, zamanlayıcılar, ev verisi), `authStatus = unauthenticated`, `sessionNotice` doldurulur. **Her oturum için bir kez.** | Giriş ekranına dön; `sessionNotice`'i göster ve `clearSessionNotice()` çağır. |
| `GuestExpiredEvent` | `403 GUEST_EXPIRED` ya da misafir penceresi doldu (zamanlayıcı) | O evin canlı bağlantısı kesilir, yerel verisi silinir, ev `expired` işaretlenir; ev listesi sunucudan tazelenir. Oturum **kapanmaz**. | "Erişim süreniz doldu" ekranı (`capabilities.isGuestExpired`). |
| (olay yok) `403 FORBIDDEN` | rol değişmiş olabilir | Ev listesi yenilenir (30 sn'de en çok bir kez); **refresh denenmez**. | "Yetkiniz yok" mesajı. |

`SessionEndReason`: `refreshRejected`, `invalidToken`, `noRefreshToken`, `serviceSessionExpired`, `userLogout` (iç kullanım).
Ağ hatası / 5xx / 429 **oturumu düşürmez**.

### 5.2 `ApiException` (`lib/services/api_exception.dart`)

`ApiException({statusCode, message, code, retryAfter, resendAfter, remainingAttempts, deviceOnline, offlineDevices, cause})`. `toString()` = Türkçe mesaj.
`statusCode == 0` → ağ/zaman aşımı (`isNetwork`). Fabrikalar: `ApiException.validation(msg)`, `.forbidden([msg])`, `.network({cause, message})`.
5xx'te sunucunun iç mesajı **gösterilmez** (genel mesaj); yalnızca `DELIVERY_FAILED` ve `SERVICE_UNAVAILABLE` mesajı gösterilir. Sunucu mesajı 300 karaktere kırpılır.

| `code` / durum | Getter | Arayüz davranışı |
|---|---|---|
| 400 `VALIDATION` | `isValidation` | Alan hatası göster (`remainingAttempts` varsa "Kalan deneme: N"). |
| 401 `INVALID_CREDENTIALS` | `isInvalidCredentials` | "E-posta/şifre hatalı" (kullanıcı varlığı sızmaz); kod doğrulamada `remainingAttempts`. |
| 401 `TOKEN_EXPIRED` | — | İç: tek-uçuş refresh + 1 yeniden deneme. Arayüze çıkmaz. |
| 401 `INVALID_TOKEN`, `SERVICE_SESSION_EXPIRED` | `isUnauthorized`, `isServiceSessionExpired` | `SessionExpiredEvent`. |
| 403 `FORBIDDEN` | `isForbidden` | "Yetkiniz yok"; refresh denenmez. |
| 403 `GUEST_EXPIRED` | `isGuestExpired` | `GuestExpiredEvent`. |
| 403 `ACCOUNT_DISABLED` / `ACCOUNT_PENDING` | `isAccountDisabled` / `isAccountPending` | "Hesap dondurulmuş" / "Hesabınızı etkinleştirin (e-postadaki bağlantı)". |
| 403 `REAUTH_REQUIRED` | `isReauthRequired` | Mevcut parolayı isteyen yeniden doğrulama (süper kullanıcı başka süperin parolasını değiştirirken). |
| 404 `NOT_FOUND` | `isNotFound` | — |
| 409 `DEVICE_OFFLINE` | `isDeviceOffline` | Anında rollback + "cihaz çevrimdışı"; `deviceOnline`, `offlineDevices` (çok panolu ev). |
| 409 `CONFLICT` | — | Zaten sahiplenilmiş vb. (sunucu mesajı). |
| 410 `GONE` | `isGone` | Kod/bağlantı süresi doldu veya kullanıldı. |
| 423 `PIN_LOCKED` | `isPinLocked` | Kalan süreyi (`retryAfter`) göster. |
| 429 `RATE_LIMITED` | `isRateLimited` | `retryAfter` / OTP için `resendAfter`; bekleme göster, "Yeniden gönder"i kapat. |
| 502 `BROKER_UNAVAILABLE` | `isBrokerUnavailable` | Hata göster, rollback. |
| 503 `DELIVERY_FAILED` | `isDeliveryFailed` | E-posta/SMS gönderilemedi (mesaj gösterilir). |
| 503 `SERVICE_UNAVAILABLE` | `isServiceUnavailable` | Özellik yapılandırılmamış. |
| 5xx diğer | `isServerError` | Genel "Sunucu şu anda yanıt veremiyor" mesajı. |

`friendlyError(Object? e, {fallback})` (`lib/utils/friendly_error.dart`): `ApiException`, `LocalApiException`, `SecureStorageException`, `TimeoutException`, `IOException`
için Türkçe mesaj döndürür; bilinmeyen hatada ham metin **asla** gösterilmez.

---

## 6. Hesap uçları (A paketi)

| İş | API | Not |
|---|---|---|
| Giriş / kayıt | `state.login(identifier, password)`, `state.register({fullName, email, password, phone})` | Parola **kırpılmaz**. `must_change_password:true` → `state.mustChangePassword`. |
| Google / Apple | `state.loginWithGoogle({required idToken})`, `state.loginWithApple({required identityToken, fullName, nonce})` | **Yalnızca doğrulanmış kimlik jetonu** gider. `nonce` Apple isteğine verilen **ham** nonce. |
| Telefon OTP | `state.sendPhoneOtp(phone) → CodeChallenge`, `state.verifyPhoneOtp(phone, code)` | `resendAfter` dolmadan "Yeniden gönder" kapalı; hatalı kodda `ApiException.remainingAttempts`; deneme bitince 429. |
| Şifre sıfırlama | `state.forgotPassword(identifier) → CodeChallenge`, `state.resetPassword({identifier?, code?, token?, newPassword})` | Kodla: `identifier` + `code`; bağlantıyla: yalnız `token`. Yanıt oturum taşırsa otomatik giriş. |
| **Parola değiştirme** | `state.changePassword({required currentPassword, required newPassword})` | Sunucu **diğer tüm cihazların** oturumlarını kapatır ve bu cihaz için **yeni belirteçler** döndürür: yeni belirteçler güvenli depoya yazılır (beklenir), yerel veri/MQTT korunur, `mustChangePassword` temizlenir. Yanlış mevcut parola: `isInvalidCredentials`. Servis oturumunda yasak. |
| **Tüm cihazlardan çıkış** | `state.logoutAll()` | Sunucu işlemi başarısızsa **çıkış yapılmaz** (hata fırlatılır). Başarıda yerel çıkış. |
| Çıkış | `state.logout()` | Önce yerel temizlik, sonra sunucuda iptal. |
| **Zorunlu parola değişimi** | `state.mustChangePassword` | `true` iken arayüz **parola değiştirme ekranına zorlamalıdır** (teknisyenin açtığı müşteri hesabı ilk giriş). Bayrak yeniden açılışta da korunur (kayıtlı kullanıcıdan). |
| **Sihirli bağlantı** | `MagicLinkParser.parse(url)` → `MagicLink{kind, token}`; `state.loginWithMagicLink(token)` ya da `state.resetPassword(token: ..., newPassword: ...)` | Bağlantı `https://<izinli>/reset-password#token=<opak>` (ya da `/magic-login`). Belirteç **yalnızca URL parçasından** okunur (`?token=` reddedilir); `POST /auth/magic-login` gövdesiyle gider (**GET → 405**). Derin bağlantı yakalama (Android/iOS intent) E paketindedir. |
| Bildirim jetonu | `state.cloudApi.registerPushToken({token, platform: 'android'\|'ios', appVersion})`, `unregisterPushToken(token)` | Jeton `[\x21-\x7E]{20,512}`; servis oturumunda yasak; **çıkıştan ÖNCE** `unregister` çağrılmalı (çıkış sonrası kimlik yok). `firebase_messaging` bağımlılığı eklenmedi (WP-H, Dalga 2 sonrası). |

---

## 7. Servis oturumu ve servis kurulum sihirbazı (F)

### 7.1 Servis PIN oturumu (2 saat, tek eve kapsamlı)

```dart
await state.loginWithServicePin('123456', technicianName: 'Usta Ad');   // → bool
state.isServiceSession;            // true
state.serviceSession;              // ServiceSessionInfo{homeId, homeName, expiresAt, technicianName}
state.serviceSessionRemaining;     // Duration?
```

* Refresh token **yoktur**; süre yerel olarak izlenir, bitince `SessionExpiredEvent(serviceSessionExpired)` ve yerel oturum kapanır.
  Önceki kullanıcı oturumu (varsa) tamamen sıfırlanır ve refresh token'ı iptal edilir.
* Oturum açılırken durum **servis evini** (`role: service_session`) seçer; `fetchHomes` çağrılmaz (tek ev giriş yanıtından bellidir).
* Servis oturumu token'ı sunucuda yalnızca **kendi evine** atıf yapan isteklerde kabul edilir (`/homes`, `/auth/me`, `/auth/logout` serbest).
  `changePassword`, `logoutAll`, `registerPushToken`, `claimDevice`, `emergencyReset`, envanter vb. servis oturumunda yasaktır.
* Yeniden açılışta kayıtlı servis oturumu süresi dolmamışsa geri yüklenir, dolduysa silinir.

### 7.2 Ev sahibi: servis erişimini yönetme

| API | Not |
|---|---|
| `state.generateServicePin() → Future<String>` | Yalnız owner (`canGenerateServicePin`). PIN `servicePin` / `servicePinExpiry`'ye yazılır, süre bitince silinir. Yeni PIN eskisini iptal eder. **PIN yalnızca üretim anında gelir**; geçmiş listesi PIN göstermez. |
| `state.fetchServiceTokens() → List<ServiceTokenSummary>` | PIN geçmişi: `id`, `status` (`active|used|expired|revoked`), tarihler, `createdByName`. |
| `state.fetchServiceSessions() → List<ServiceSessionSummary>` | Açık servis oturumları (`technicianName`, `expiresAt`). |
| `state.revokeServiceAccess() → RevokeServiceAccessResult` | Kullanılmamış tüm PIN'ler + açık oturumlar iptal ("servis erişimini kapat"); ekrandaki PIN silinir. |

### 7.3 Kurulum akışı için ilkeller (servis sihirbazı: iki ağ, iki aşama)

Sunucu tarafı sıra (CONTRACTS §3b "Provizyon sırası" + §3d + §1.5b): flash → provizyonsuz pano açık AP `AHBU-<MAC>` yayınlar → `factory/init` → AP WPA2'ye döner →
**AP'den anahtarsız** Wi-Fi bağlama → (telefon ev ağına döner) `X-Device-Key` ile `mqtt/config`. Telefon kurulum sırasında **iki farklı ağdadır**:

| Sihirbaz adımı | Telefonun ağı | İnternet | Cihaz anahtarı |
|---|---|:-:|---|
| 1-4 (giriş, etiket, OTP, claim) | mobil veri / ev Wi-Fi | VAR | gerekmez; claim yanıtındaki `device_credential` yalnız bellekte beklemeye alınır |
| 5 (Wi-Fi) | panonun WPA2 kurulum ağı (`AHBU-<MAC6>`) | **YOK** | **GEREKMEZ**: `GET /api/wifi/scan`, `POST /api/wifi/connect`, `GET /api/wifi/status` AP'den anahtarsız çalışır (§3d) |
| 6-9 (bulut, röle, panjur, buton) | müşterinin ev Wi-Fi'si | VAR | gerekir: **sunucudan okunur, yalnızca bellekte tutulur** |
| 10 (teslim) | ev Wi-Fi'si | VAR | - |

```dart
// 1) Cihazı sahiplen (servis sorumlusu müşteri adına: targetOwner + otpCode zorunlu) — internet VAR
final claim = await state.claimDevice(uid, pin, homeName: 'Daire 5', targetOwner: 'musteri@ornek.test', otpCode: '123456');
claim.homeId; claim.deviceCredential;           // DeviceMqttCredential? — TEK SEFERLİK parola (yalnız bellek)
claim.customerAccount;                          // müşteri hesabı açıldı mı / davet gitti mi
claim.technicianAccessExpiresAt;                // servis personeline 72 saatlik kurulum üyeliği
claim.warnings;                                 // kısmi başarı uyarıları (örn. davet gönderilemedi) → GÖSTERİN

// 2) Telefon panonun kurulum ağında: internet YOK, anahtar YOK — kendi örneğiyle
final ap = AutomationApiService.recoveryAp();                   // anahtar HİÇ verilmez
final id = await ap.fetchPublicStatus();                        // kimlik: beklenen pano mu? (yanlış panoya bilgi gitmesin)
//    (provizyonsuz = AP açık cihazsa) await ap.factoryInit(localKey: yeniAnahtar, apPass: apParolasi);  // Wi-Fi uçları 403 unprovisioned
final networks = await ap.scanWifi(refresh: true);              // List<WifiNetwork>
final r = await ap.connectWifiAndWait(ssid, pass);              // WifiConnectResult (success|failed|timedOut|lostContact); başarı YALNIZ success
r.ipAddress;                                                    // wifi_sta_ip: panonun ev ağındaki adresi (hedefe yazılır, ilerleme kaydına girer)

// 3) Telefon ev Wi-Fi'sine döndü (internet geri geldi): anahtar sunucudan alınır — KAYDEDİLMEZ
final key = await state.cloudApi.localKey(claim.homeId, claim.deviceUuid);   // localKeyFor güvenli depoya YAZAR; sihirbaz kullanmaz
final lan = AutomationApiService(baseUrl: '')..updateHost(r.ipAddress!)..localKey = key;
await lan.checkKey();                                           // reddedilen anahtar BİR DAHA gönderilmez (5 hatada pano 60 sn kilitlenir)
await lan.configureMqtt(claim.deviceCredential ?? await state.reissueDeviceMqttCredential(deviceUuid: claim.deviceUuid, homeId: claim.homeId));
final st = await lan.fetchStatus();                             // st.mqttConnected, st.provisioned, st.wifiConnectState
```

**Gizlilik kuralı:** `device_credential.password`, `setup_pin`, `local_key` **hiçbir yere yazılmaz** (güvenli depo dahil), loglanmaz, `toString`'e girmez; ekranda gösterilen tek seferlik
değerler yalnızca `SecretClipboard` yoluyla (45 sn sonra silinen, arka planda okunamazsa boş yazan ve ön plana dönünce yeniden deneyen) kopyalanabilir.
`ClaimResult.raw` içinde `device_credential` yoktur; sihirbaz kimliği hemen cihaza yazar ve bırakır. Uygulama adımlar arasında kapanıp kimlik kaybolursa 6. adım
`state.reissueDeviceMqttCredential({required deviceUuid, homeId})` ile yeni `DeviceMqttCredential` üretir (tek seferlik; eski kimlik geçersiz olur). Acil sıfırlama / pano
değişimi yanıtındaki tek seferlik kimlik `ServiceSetupWizardPage(initialCredential: ...)` ile sihirbaza (yalnızca bellek) aktarılır; yeniden üretilmez.
Yerel anahtarın güvenli depodaki kopyası (`state.localKeyFor`: önce güvenli depo, yoksa sunucu; her okuma güvenli depoya YAZAR) **hesap sahibi/oturumlu ev kullanımı içindir**; servis sihirbazı
teknisyenin telefonunda müşteri anahtarı bırakmamak için bunu kullanmaz. Süper kullanıcıya sunucu anahtar vermez: anahtar elle girilir.

Mevcut cihazlarda ("Mevcut cihazlarım -> Testleri yap / Bağlantıyı yeniden kur") pano sunucuda zaten çevrimiçiyse 6. adım bulut kimliğini **yeniden üretmez/yazmaz** (çalışan panoyu buluttan düşürmemek için).

`mqtt_server` **DNS adıdır** (IP olmaz: firmware TLS sertifikasını ana makine adıyla doğrular); `DeviceMqttCredential.host/port` bunu taşır.

### 7.4 Acil sıfırlama ve pano değişimi sonuçları

```dart
final res = await state.emergencyResetDevice(deviceUuid: u, confirmUid: u, reason: '≥ 15 karakter gerekçe', newOwnerIdentifier: 'musteri@ornek.test');
```

`EmergencyResetResult`: `action` (`UNCLAIMED`/`REASSIGNED`; `isUnclaimed/isReassigned`), `deviceUuid`, `homeId`, `affectedUsersCount`, `setupPin` (UNCLAIMED, **tek sefer**),
`newOwner{id, fullName}`, `deviceCredential` (REASSIGNED, **tek sefer**), `localKeyPublish`/`childLockReset` (`published|failed|skipped_offline|skipped`),
`localKey` (cihaza iletilemediyse **tek sefer**; `needsManualLocalKey`), `message`, `warnings`, `partial`, `hasWarnings`.
**Kısmi başarısızlık HTTP 200 + `warnings` + `partial:true`** döner (207 değil): arayüz **uyarıları göstermelidir**.
`REVOKED/SUSPENDED` cihazı yalnız süper kullanıcı sıfırlar. Yetki: `canEmergencyReset`; gerekçe ≥ 15 karakter ve `confirmUid == deviceUuid` istemcide de doğrulanır.

`ReplaceBoardResult` (`state.replaceBoard({oldDeviceUuid, required newDeviceUuid, required setupPin, reason})`): `oldDeviceUuid`, `newDeviceUuid`,
`migratedEndpointsCount`, `deviceCredential` (tek sefer), `shutterRuntimes` (`[ShutterRuntimeSync{shutter, seconds}]`), `runtimeSync`, `childLockEnabled`, `childLockSync`
(`pending_device_online`: yeni pano çevrimiçi olunca yeniden uygulanır; `childLockPending`), `warnings`, `hasWarnings`.
Çok cihazlı evde `oldDeviceUuid` **zorunludur** (sunucu "ilk pano" varsaymaz).

### 7.5 Devreye alma

```dart
final result = await state.commission(
  checks: const CommissioningChecks(
    relays: CommissionCheck(ok: true, detail: '8/8 röle'), buttons: CommissionCheck(ok: true),
    shutters: CommissionCheck(ok: true), network: CommissionCheck(ok: true), cloud: CommissionCheck(ok: true)),
  notes: 'Montaj tamam');
result.testsPassed;   // SUNUCUDA hesaplanır (5 zorunlu kontrolün hepsi ok)
```

`state.getCommissioningStatus()` → `Map?` (dairedeki tüm cihazların durumu).

---

## 8. Doğrudan (LAN/AP) mod

### 8.1 Adres kuralı (`AutomationApiService.updateHost`)

`X-Device-Key` açık metin gider; bu yüzden **yalnızca yerel adresler** kabul edilir: `localhost`, `*.local`, ve özel/link-local/loopback/CGNAT **IPv4**
(`10/8` — emülatör `10.0.2.2` dahil —, `172.16/12`, `192.168/16`, `169.254/16`, `127/8`, `100.64/10`). İnternet adresleri, IPv6, kullanıcı bilgisi, yol/sorgu, geçersiz port → adres "ayarlanmadı" (`isConfigured == false`).
`https://` öneki `http://`ye çevrilir (cihaz TLS konuşmaz). `state.setHost / selectDevice / updateSelectedDeviceIp` geçersiz adreste `ApiException.validation('Geçersiz cihaz adresi.')` fırlatır ve **önceki adresi korur**.
Cihaz kendi tarafında da ana makine allow-list'i uygular (`400 bad_host`, `403 bad_origin`).

### 8.2 `GET /api/status` (CONTRACTS §3b)

* **Anahtarsız** → kısıtlı özet: `device` (kimlik), `name`, `fw`, `provisioned`, `wifi_connected` → `DeviceStatus.restricted == true`, röle/panjur listesi **yok**.
  `AutomationState` doğrudan modda kısıtlı özeti görürse cihazı "bağlı ama kontrol edilemez" sayar: `status == null`, `directError` = "Cihaz anahtarı gerekli…" ya da (`provisioned:false`) "Cihaz henüz kurulmamış…"; anahtar yoksa sunucudan **bir kez** yeniden almayı dener.
* **Anahtarlı** → tam yanıt (alan listesi: CONTRACTS §3b). Kimlik `device` alanındadır (`uid` yok → `DeviceStatus.uid`'ye düşer); `relays[].runtime_sec` yoktur (config'te).
  `shutters[].is_shutter:false` çiftler atılır. `fetchPublicStatus()` anahtar göndermeden aynı özeti alır (yanlış anahtar kilidine takılmaz).
* Yoklama: tek-uçuş; ardışık 3 hata → çevrimdışı; değişim yoksa `notifyListeners()` yok.

### 8.3 `LocalApiException` (`lib/services/automation_api_service.dart`)

`{statusCode, code, message, retryAfter, hint}`; `statusCode == 0` ağ; `hint` (isteğe bağlı, yalnız ağ hatasında) Android'de pano ağına yönlenme kurulamadığında eklenen Türkçe ipucudur (§8.4; `message` de içerir). Getter'lar: `isNetwork`, `isUnauthorized` (401), `isLocked` (423; `retryAfter` gövdeden/`Retry-After`),
`isUnprovisioned` (403 `unprovisioned`), `isAlreadyProvisioned` (403 `already_provisioned`), `isBusy` (409 `busy`, 503 `busy|queue_full`), `isHostRejected` (`bad_host`/`bad_origin`),
`isInvalidInput` (400), `isCancelled`. Mesajlar Türkçe (`invalid_ssid`, `invalid_password`, `invalid_key`, `invalid_ap_pass`, `invalid_value`, `unknown_command`, `storage`, `too_large` ...).

### 8.4 Wi-Fi sihirbazı ve provizyon

| API | Davranış |
|---|---|
| `scanWifi({refresh, isCancelled}) → List<WifiNetwork>` | `{status:"scanning"}` ise 1.2 sn arayla yeniden sorar (en çok 12 kez, sonra `timeout`); SSID geçersiz UTF-8 olabilir (`allowMalformed`); aynı adlı ağlar tekil (en güçlüsü), gizli SSID atılır, sinyale göre sıralı. `WifiNetwork{ssid, rssi, secured}` (`enc` bool). |
| `connectWifi(ssid, pass) → Future<void>` | `POST /api/wifi/connect` → `200 {"status":"connecting"}`. **Bağlandı demek değildir.** SSID 1..32 bayt, parola boş (açık ağ) ya da 8..63 bayt; **kırpılmaz**; ağa gitmeden doğrulanır. `409 busy` → `isBusy`. |
| `awaitWifiConnection({timeout = 40 sn, interval = 1.5 sn, isCancelled}) → WifiConnectResult` | **`GET /api/wifi/status`** (`fetchWifiStatus()`; CONTRACTS §3d: kurtarma ağından ANAHTARSIZ çalışır; 404'te eski yazılım için `GET /api/status`'a düşer; `429 rate_limited` geri sayım) → `wifiConnectState` yoklanır: `success` → `WifiConnectOutcome.success` (+`ipAddress`); `failed` → `failed` (+`reason` = `wifi_err_reason_t`, `message` Türkçe: yanlış şifre / ağ yok / zaman aşımı); süre dolarsa `timedOut`; **yoklama sırasında cihazla bağlantı koparsa `lostContact` (belirsiz — pano AP'yi kapatmış olabilir; telefonu ev ağına alıp bulut cihaz listesinden `online` doğrulayın)**; en az bir okuma yapıldıktan SONRA gelen `401` de `lostContact`tır (AP kaynaklı anahtarsız yol kapandı: pano bağlandı ve modem ağı da `192.168.4.x` ise, CONTRACTS §3d); İLK okumadan önce gelen 401/423/403 yeniden fırlatılır. |
| `connectWifiAndWait(ssid, pass, {timeout, isCancelled})` | İkisi birlikte. |
| `factoryInit({required localKey, required apPass})` | `POST /api/factory/init` — **anahtar başlığı gönderilmez**; `local_key` 8..32 görünür ASCII (boşluksuz), `ap_pass` 8..32; başarıda `localKey` yeni anahtara ayarlanır. `403 already_provisioned` → `isAlreadyProvisioned` (anahtar değişmez). |
| `rekey(newKey)` | `POST /api/auth/rekey` — **mevcut** anahtarla imzalı; başarıda `localKey` güncellenir. |
| `checkKey() → bool` | `GET /api/auth/check`: `true` kabul, `false` (401) yanlış; 423/403/ağ **fırlatır**. |
| `configureMqtt(DeviceMqttCredential)` | `POST /api/mqtt/config {server, port, user, pass}`; ana makine/port/kullanıcı ≤ 47 bayt/parola ≤ 63 bayt cihaz sınırları ağa gitmeden doğrulanır; **parola hata mesajına sızmaz**. |
| `fetchChildLock() → bool` | `GET /api/child-lock` → `{"child_lock":bool}`; alan yoksa/hata **fırlatır**. |
| `setChildLock(bool)` | `POST /api/child-lock {"enabled":bool}` → `{"status":"queued"}` (gerçek durum `status.child_lock` ile doğrulanır). |

Kurtarma sihirbazları ana durumun adresini değiştirmemek için `AutomationApiService.recoveryAp(...)` (kendi örneği; adres `AppConfig.deviceApBaseUrl`) kullanmalıdır.

**Android: pano kurulum ağına süreç bağlama (WP-NET, 2026-10-02; CONTRACTS §5 "WP-NET" notu).** Pano kurulum ağı internetsizdir; Android bu Wi-Fi'yi "doğrulanmamış" sayıp **mobil veri açıkken** uygulamanın varsayılan ağını hücresele çevirir (`192.168.4.1` istekleri hücreselden çıkıp başarısız olur). `AutomationApiService`, adresi `AppConfig.deviceApHost` (varsayılan `192.168.4.1`; ham IPv4 + `192.168.0.0/16`) olan HER isteği Android'de `BoardNetworkBinding` ile sarar: kira al → istek → `finally` bırak (`lib/services/board_network_binding.dart`; yerel taraf `ev_otomasyon/board_network` kanalı: Kotlin `BoardNetworkPlugin` / `BoardNetworkBinder` / `BoardNetworkCore`, `MainActivity.configureFlutterEngine`'de kayıtlı; yerel durum eşlemesi, süre bütçesi ve JVM testleri: CONTRACTS §5 "WP-NET"). `awaitWifiConnection`, `connectWifiAndWait` ve `scanWifiNetworks` döngüsü baştan sona **tek** kira tutar. **Genel imzalar DEĞİŞMEDİ**; kurucu ve `recoveryAp` isteğe bağlı `boardNetwork` parametresi alır (varsayılan: çağrı anında `BoardNetworkBinding.instance`; testte `FakeBoardNetworkBinding` + `BoardNetworkBinding.overrideForTesting(...)`, geri almak için `null`). LAN doğrudan mod, emülatör/QA (`10.0.2.2`, `127.0.0.1`), `*.local` ve Android dışı platformlarda hiçbir şey değişmez (kanal HİÇ çağrılmaz). Bağlama başarısız olsa da istek YİNE DE denenir; istek ağ hatasıyla biterse `LocalApiException.hint` (ve `message`) şu ipuçlarından birini taşır: `not_on_board_network` / `no_wifi` → "Telefon pano kurulum ağına (AHBU-…) bağlı görünmüyor: …", `timeout` (YALNIZ Dart üst sınırı dolunca; yerel taraf `timeout` üretmez, işletim sistemi zaman aşımı `no_wifi` olur) / `error` → "Pano ağına yönlenme kurulamadı: mobil veriyi kapatıp yeniden deneyin.", `error` + `bind_denied` (ağ canlıyken işletim sistemi bağlamayı reddetti: VPN) → "Pano ağına yönlenme reddedildi: telefonda VPN (özel ağ) açıksa kapatıp yeniden deneyin." (`BoardNetworkLease.bindDeniedHint`), `permission_denied` → kısa teknik olmayan metin. Arayüz: "mobil veriyi kapatın" yönergesi Android'de ön bilgi olarak "Mobil veri açık kalabilir; uygulama pano ağını otomatik kullanır. Bağlantı kurulamazsa mobil veriyi kapatıp yeniden deneyin." (`BoardNetworkBinding.mobileDataAdvice`) olur; hata kutusunda ("Ne yapmalıyım") yalnız yedek cümle (`BoardNetworkBinding.mobileDataFallback`) kullanılır; `WifiProvisionPanel` ve servis sihirbazı hata kutusu `hint`'i ekler. `BoardNetworkBinding.isSupported` yerel eklenti yoksa / yerel taraf `unsupported` derse KALICI `false` olur (arayüz eski yönergeye döner, pano çağrıları kira açmaz). Son kira bırakılınca yerel `release` HEMEN yapılır ve bırakma bu çağrının yanıtından sonra tamamlanır (varsayılan bekleme/linger yok): bir AP çağrısı döndüğünde süreç artık pano ağına bağlı değildir. Dart üst sınırı yerel `acquire` için `timeout + 4 sn`dir (yerel en kötü yanıt `timeout + 3 sn`). Hata ayıklama derlemesinde durum/ayrıntı belirteçleri `debugPrint` ile yazılır (`adb logcat -s BoardNetwork flutter`; SSID/IP/anahtar ASLA). **Gerçek Android cihazda DOĞRULANMADI** (Dart tarafı sahte kanal + sahte HTTP ile, yerel durum makinesi JVM'de sahte platformla sınandı; canlı test listesi Aşama 16.11).

---

## 9. Çevrimiçilik türetmesi

İki ayrı kavram (ESKİ `isConnected` ikisini karıştırıyordu):

* `brokerConnected` / `mqttLinkState` (`MqttLinkState`): uygulamanın MQTT broker bağlantısı (canlı akış).
* `devicePresence` (`unknown|online|offline`) / `deviceOnline` / `connState`: **cihazın (panonun)** çevrimiçi bilgisi. Doğrudan modda `connState` cihazın yanıt vermesidir.

`deviceOnline` türetmesi (cihaz `state`/`status`'u **QoS 0** yayınlar; kaybolan "online" status'u retained LWT "offline"ı geçerli bırakabilir — D12):

| Olay | Sonuç |
|---|---|
| **Canlı** (retained olmayan) `state` | **çevrimiçi** (retained `offline`'ı düzeltir). |
| `status: online` (canlı veya retained) | çevrimiçi. |
| **Canlı** `status: offline` (LWT / planlı yeniden başlatma) | **kesin çevrimdışı** (sonraki canlı `state` yine düzeltir). |
| **Retained** `status: offline` | **taze canlı `state` yoksa** çevrimdışı; son 90 sn içinde canlı `state` geldiyse **yok sayılır**. Retained ileti cihazı **kalıcı** çevrimdışı yapmaz. |
| **Retained** `state` | Son bilinen değeri gösterir ama **çevrimiçiliği kanıtlamaz** (canlı tazelik başlatmaz). |
| Komut `409 DEVICE_OFFLINE` | çevrimdışı; sonraki canlı `state` düzeltir. |
| REST `GET /homes/:id/devices` | Yalnızca canlı kanal yokken/durum bilinmiyorken kullanılır; canlı kanal bağlıyken MQTT bilgisini ezmez. |

Ev değişiminde tazelik sıfırlanır. Cihaz başına çevrimiçi bilgisi **yoktur** (ev başına tek konu): çok panolu evde `deviceOnline` "en az bir pano" anlamındadır (sınır).

---

## 10. QR / Wi-Fi QR / sihirli bağlantı çözücüler

```dart
final payload = QrRouter.route(scannedText);       // sealed QrPayload
switch (payload) {
  case QrClaim(:final uid, :final pin): ...         // cihaz etiketi
  case QrInvite(:final code): ...                   // AHBU-INVITE:<kod>
  case QrTransfer(:final code): ...                 // AHBU-TRANSFER:<kod> veya AHBU-TR-<kod>
  case QrWifi(:final credentials): ...              // WIFI:T:WPA;S:...;P:...;;
  case QrUnknown(:final message): ...               // Türkçe mesaj; ham metin ASLA UUID olmaz
}
```

* `QrRouter` (`const QrRouter({allowedHosts, allowBareInviteCodes = false})`; `QrRouter.route`): önek **büyük/küçük harf duyarsız**. Çıplak davet kodu (`AHBU-123456`) yalnızca elle giriş alanları için (`allowBareInviteCodes: true`); taramada kapalı (UID ile karışmasın).
  Uzunluk ≤ 512, kontrol karakteri yok. `QrUnknown.reason` (`QrUnknownReason`) + `message`.
* `WifiQrParser.parse(raw) → WifiQrCredentials?` / `parseDetailed → WifiQrParseResult{credentials|error}`: kaçışlar (`\\ \; \, \: \"`), alan sırası serbest, SSID ≤ 32 bayt (UTF-8), WPA parolası 8..63, açık ağ parolasız;
  **WEP ve kurumsal (EAP) reddedilir** (açık hata), kontrol karakterleri reddedilir. `WifiQrCredentials{ssid, password, security: 'WPA'|'nopass', hidden, isOpen}`.
* `MagicLinkParser` (§6): `parse(raw, {allowedHosts})`, `parseDetailed` → `MagicLinkParseResult{link|error}`; hata `MagicLinkError` (+`message`). Belirteç `^[A-Za-z0-9_-]{16,512}$`, yalnız parçada.
* İzinli ana makineler: üretim sitesi + (**yalnız release dışı derlemede**) `AppConfig.current.apiHost`.

---

## 11. `AppConfig` ve `dart-define`

`lib/config/app_config.dart` — derleme zamanı yapılandırma (`String.fromEnvironment`):

| Değişken | Anlam | Varsayılan |
|---|---|---|
| `API_BASE_URL` | REST kök adresi (`/api` dahil; sonunda `/` yok; `http`/`https` mutlak URL, sorgu yok) | `https://evotomasyon.gudeteknoloji.com.tr/api` |
| `MQTT_TLS` | `false`/`0`/`no`/`off` → MQTT TLS kapalı (host/port `mqtt-credentials` yanıtından gelir) | TLS açık |
| `DEVICE_AP_HOST` | Cihaz kurtarma/kurulum AP adresi (`host[:port]`; şema/yol yok) | `192.168.4.1` |

**GÜVENLİK KURALI:** üç override da **`kReleaseMode == true` iken yok sayılır**; release derlemede her zaman güvenli varsayılan kullanılır (HTTPS, TLS açık, `192.168.4.1`). Geçersiz override değeri de varsayılana düşer.

Yerel QA arka ucu / emülatör:

```text
flutter run -d emulator-5554 \
  --dart-define=API_BASE_URL=http://10.0.2.2:5000/api \
  --dart-define=MQTT_TLS=false \
  --dart-define=DEVICE_AP_HOST=10.0.2.2:8081
```

API: `AppConfig.current` (etkin), `AppConfig.defaults`, `AppConfig.fromOverrides({apiBaseUrl, mqttTls, deviceApHost, releaseMode})`, `AppConfig.forTest(...)` (`@visibleForTesting`; `current` setter'ı da
yalnızca testlerde; test sonunda `AppConfig.current = AppConfig.defaults` ile geri alın). Alanlar: `apiBaseUrl`, `mqttUseTls`, `deviceApHost`, `overridesApplied`; getter'lar: `deviceApBaseUrl`, `apiHost`; statik: `productionHost`, `productionClaimUrl`.
Kullananlar: `EvCloudApiService` (`baseUrl`), `EvMqttService` (TLS bayrağı), `AutomationApiService` (varsayılan adres, `recoveryAp`), QR ana makine izin listesi. Başka sabit adres/port kalmadı.

**Android notu (E/android):** `http://10.0.2.2` düz HTTP olduğundan **debug** manifestinde `usesCleartextTraffic` (ya da ağ güvenlik yapılandırması) gerekir; release'de açılmamalıdır.
`integration_test` bağımlılığı `pubspec.yaml` dev_dependencies'e eklendi (`flutter pub get` çalıştırıldı; `pubspec.lock` güncel).

---

## 12. Test yardımcıları (`test/support`)

`import '../support/support.dart';` (testler `test/services/` altındaysa) — tümünü dışa aktarır.

| Yardımcı | Kullanım |
|---|---|
| `FakeClock([DateTime? start])` | Başlangıç `kTestNow` (2026-10-01 12:00 UTC). `now()`, `timer`, `periodic`, `advance(Duration)` (eşzamanlı), **`await elapse(Duration)`** (zamanlayıcıdan zamanlayıcıya atlar, her adımdan sonra olay kuyruğunu boşaltır; saatlerce hızlı), `activeTimerCount`. Zamana bağlı test verisi `DateTime.now()` değil `kTestNow`/`h.clock.now()` ile kurulur. |
| `InMemorySecureStore` / `FakeStorage` | `data` (ham anahtar-değer), `failReads`, `failWrites`, `failDeleteAll`, `failReadKeys` (yalnız belirli anahtarlar okunamasın), `FakeStorage.keys/isEmpty`. |
| `FakeBiometric({supported, authResult, label})` | `supported`, `authResult`, `pending` (`Completer<bool>`: gecikmeli doğrulama), `authenticateCalls`, `reasons`. |
| `FakeCloudApi({clock})` | `EvCloudApiService`'ten türer; bellek içi: `homes`, `endpoints[homeId]`, `devicesByHome`, `credentials`, `sendCommandHandler`, `sentCommands`, `childLockValue/childLockRequestedValue/childLockDevices/childLockError/childLockGate`, `setChildLockJson` (ham sunucu gövdesi), `setChildLockHandler`, `setChildLockError`, `peaceNotification` (sunucu anahtarlarıyla), `loginUser/loginError`, `changePasswordError/logoutAllError/refreshHandler/onRevoke`, `serviceSessionToReturn/serviceLoginError`, `serviceTokenToReturn`, `serviceTokens/serviceSessions/revokeResult`, `deviceCredentialToReturn`, `claimResultToReturn/claimError`, `emergencyResetToReturn`, `replaceBoardToReturn`, `members`, `localKeyValue/localKeyError`, `rules`; `calls` (çağrı günlüğü) ve `count('yöntem')`. Tanımsız uçlar `404` döner. |
| `FakeMqtt` | `EvMqttService` yerine; `emitState(DeviceStatus, {retained})`, `emitStateJson(json, {retained})`, `emitPresence(online, {retained})`, `setLink(MqttLinkState)`, `autoConnect`, `startCount/stopCount`, `lastCredentials`. |
| `FakeMqttTransport` | Gerçek `EvMqttService` döngüsünü sınamak için (`deliver(batch)`, `drop()`, `subscriptions`). |
| `StateHarness({autoInit, biometricSupported, biometricRelockAfter, confirmTimeout, directPollInterval, clock, cloud, mqtt, storage, biometric})` | `AutomationState` + tüm sahteler: `clock`, `cloud`, `mqtt`, `storage`, `biometric`, `directMock` (`MockApi`), `direct`, `state`, `dispose()`. |
| `readyHarness({role, globalRole, endpoints, home, brokerConnected, deviceOnline, configure})` | Giriş yapmış kullanıcı + seçili ev (`kHomeA`) + uç noktalar + çevrimiçi cihaz + bağlı MQTT; gerçek yollar (fetchHomes → selectHome → refresh → gerçek zamanlı) sahtelerle çalışır. `ep(state, channel, {shutter})` görünen uç noktayı bulur. |
| `testHome({id, name, role, topic})`, `testEndpoints({homeId, deviceUuid})`, `stateJson({uid, relays, shutters, childLock, lastId, ip})`, `kHomeA`, `kHomeB`, `kTestNow` | Hazır veri. `testEndpoints`: 1–2 lamba, 3–4 panjur çifti (pair 2), 5 lamba, 6 priz (karışık yerleşim). |
| `MockApi` + `okResponse/errorResponse/jsonResponse/RecordedRequest` | Yol tablolu `MockClient`: `on(method, path|RegExp, handler)` (aynı yola **son eklenen** geçerli), `onSequence`, `requests`, `where`, `count`. `errorResponse(status, msg, {code, headers, extra})`. Tanımsız yol `404`. |
| `pumpApp(tester, {child, state, size, themeMode, ...})` | Bir sayfayı `AutomationState` sağlayıcısı + `MaterialApp` ile pompalar (sahte durum otomatik). |

Örnek:

```dart
final h = await readyHarness(role: 'owner');
h.mqtt.emitStateJson(stateJson(childLock: true));
await pumpEventQueue();
expect(h.state.childLockStatus, ChildLockStatus.locked);
await h.clock.elapse(const Duration(seconds: 3));   // 2.5 sn doğrulama penceresi vb.
```

Eski `test/*.dart` dosyaları (E/F): iyimser `bool`'ları doğrulayan testler eski hataları (çocuk kilidi geri alma, panjur kıskacı) kutsuyordu; `test/services/*` içindeki davranış testlerine bakın
(`child_lock_behavior_test.dart`, `command_pipeline_test.dart`, `automation_state_commands_test.dart`, `automation_state_session_test.dart`, `device_presence_test.dart`, `device_contract_shapes_test.dart`...).

---

## 13. Sözleşmeden sapmalar, sınırlar ve açık noktalar

1. **Komut onay penceresi** (CONTRACTS §5 "2.5 sn içinde onay yoksa geri al"): pencere **iletimden** başlar, toplam üst sınır 10 sn (REST gecikmesi yanlış zaman aşımı vermesin diye). `docs/CONTRACTS.md` §5'e not düşüldü.
2. **`/devices/:id/command` `:id`:** istemci cihaz kimliğini (`device_uuid`, `AHBU-…`) gönderir; yoksa uç noktanın iç `device_id`'sine düşer (sunucu ikisini de kabul ediyor).
3. **Endpoint listesi JSON şekli** CONTRACTS'ta yazılı değildi: `channel_index/type/current_position` ve takma adları (`channel/endpoint_type/shutter_position`, `online`) kabul edilir.
4. **Cihaz başına çevrimiçi bilgisi yok** (ev başına tek `status` konusu); çok panolu evde `deviceOnline` "en az bir pano".
5. ~~`/service/subscribers` ve `assign-admin` uçları sunucuda yok~~ — **UYGULANDI** (sunucu B2 paketi; CONTRACTS §1.5c): aboneler listesi, Home Admin atama OTP'si ve atama istemcide çalışır.
6. ~~Hesap silme uç noktası yok~~ — **UYGULANDI** (`DELETE /auth/account`; ev sahibi için `409 SOLE_OWNER` ev listesi; CONTRACTS §1.5c).
7. **Kalıcı servis personeli ev penceresi:** `HomeModel.guestValidUntil` kalıcı servis personelinde `installer_expires_at`'ı taşır; süre bitince sunucu evi listeden çıkarır (`403 FORBIDDEN` → ev listesi yenilenir).
8. **`debug_code` / `debug_token`** (`ALLOW_DEBUG_OTP`) yalnız release dışı derlemede `CodeChallenge`'a girer; üretim sunucusu zaten dönmez.
9. Derin bağlantı (sihirli bağlantı, claim) yakalama E paketiyle ve Android pano ağı bağlama (süreç bağlama; §8.4, CONTRACTS §5 WP-NET) eklendi; iOS Associated Domains ve sunucuda `assetlinks.json`/`apple-app-site-association` yayını YOK (dağıtım işi). `firebase_messaging` kullanıcı kararıyla **yok**: gece hatırlatması yalnız uygulama açıkken/açılınca görünür (CONTRACTS §5 WP-H).

---

## 14. Sunucu davranış eklemeleri (2026-10-01, plan §5d-1 ve §5d-3)

İstemciye görünen iki sunucu davranışı. Yeni uç/alan **yok**; mevcut yanıt şekilleri değişmez.

**14.1 Push belirteci gizliliği (`push_tokens`).** Sunucu, oturumları **toplu iptal eden** her akışın ardından (COMMIT sonrası; hata
oturum iptalini bozmaz) kullanıcının **tüm** etkin push belirteçlerini devre dışı bırakır: `POST /auth/logout-all`, `POST /auth/change-password`,
`POST /auth/reset-password` (kod ve bağlantı), yönetici parola atama / rol değişimi / dondurma / pasife alma, doğrulanmamış hesaba sosyal kimlik
bağlama. Hesap silme belirteçleri zaten siler. **Tek cihaz çıkışı** (`POST /auth/logout`, refresh) belirteçlere dokunmaz: istemci çıkıştan **önce**
`DELETE /me/push-tokens {token}` ile yalnız **kendi** belirtecini kaldırmaya devam eder.
- **İstemci eylemi:** `change-password` ve `reset-password` bu cihaza **yeni oturum** verir ama bu cihazın belirtecini de kapatır → istemci yeni oturumdan
  hemen sonra belirtecini yeniden kaydetmelidir (`PUT /me/push-tokens`; aynı belirteç yeniden etkinleşir). `logout-all` sonrası oturum kalmaz; belirteç
  bir sonraki girişte zaten kaydedilir.

**14.2 Çevrimiçi olunca uzlaştırma (pano değişimi / çocuk kilidi niyeti).**
- `GET /devices/child-lock/:home_id` → `requested` / `requested_at` artık **bekleyen niyet** demektir: cihaz bildirimi niyetle eşleşince (ya da niyet
  7 günden eskiyse) sunucu ikisini de `null` yapar. `requested == null` ⇒ bekleyen istek yok (`childLockAwaitingDevices` zaten `false`). Gerçek durum yine
  yalnız cihazın `state.child_lock` bildirimidir.
- Pano değişimi (`child_lock.sync: pending_device_online`): yeni pano **çevrimiçi olunca** sunucu kilidi bir kez yeniden uygular (en çok 3 deneme, 5/10/20 sn
  üstel bekleme); `state.child_lock` birkaç sn içinde `true` olur. `runtime_sync: pending_device_online`: panjur süreleri de çevrimiçi olunca sunucu
  `set_runtime` ile uygular (**yalnız tek panolu evde**; çok panolu evde uygulanmaz, elle kalibrasyon gerekir). Bu iki yayın istemci komutu değildir:
  `command_id` dönmez, istemci bir şey beklemez.
