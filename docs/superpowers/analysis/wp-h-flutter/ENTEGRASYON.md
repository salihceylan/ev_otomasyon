# Gece hatırlatması: Flutter istemcisi entegrasyon rehberi (Firebase'siz)

Bu belge, "açık kalan lambalar için gece hatırlatması" istemci tarafının gerçek uygulamaya (`ev_otomasyon`) **neyle, hangi sırayla ve hangi sınırlarla** alınacağını anlatır. Uygulayıcıya yöneliktir; her somut iddia aşağıda anılan dosyalarda doğrulanabilir.

Kullanıcı kararları:

* **Firebase kullanılmayacak.** `pubspec.yaml`'a `firebase_core` / `firebase_messaging` eklenmez; bildirim yalnızca uygulama açıkken ya da açılınca görünür (sunucunun `last_notice` verisinden yedek afiş). Firebase kümesi canlıya alınmaz (bkz. Ek bölüm).
* **Firebase'siz sürümde işe yaramayan platform değişiklikleri paketten ÇIKARILDI** (Android bildirim kanalı, manifest meta-data'sı, `ic_stat_peace.xml`, iOS `UIBackgroundModes`, `.gitignore` push-sır satırları; bölüm 5).
* **Emülatör/cihaz denemesi yapılmadı;** deneme kullanıcıda/orkestratördedir (bölüm 8).

Yama paketi ve uygulama betiği: `yamalar/README.md` ve `uygula.sh`. Bu belgedeki sıra onlarla aynıdır; ayrılık görürseniz `yamalar/README.md` geçerlidir. Arşiv: `arsiv/` (Firebase istemci kodu, `SPL-dosya-ayrimi.txt`) ve `yamalar/arsiv/` (eski platform ve `.gitignore` yamaları, `OKU-BENI.md`).

Kısaltmalar: `R1`, `RR1`, `RR2`, `RR3`, `RB`, `FXC`, `G1` gibi kodlar geliştirme turlarının bağımsız inceleme/entegrasyon raporlarına atıftır (iş akışı dizininde; pakette yok). `RR3-02` = RR3 raporunun 2. bulgusu; `B6` ve `B7` = R1 raporunun 6. ve 7. (düşük şiddetli) bulguları (ilgili maddede ayrıca açıklandı); `SPL` = Firebase'siz / Firebase'li dosya ayrımı turu. Her madde bu kodlar bilinmeden de anlaşılır yazıldı.

## 1. Mimari (kabuk tabanlı bağlantı)

```
AppShell (lib/ui/app_shell.dart)
  |- _peace = PeaceNoticeController(state: AutomationState)        initState'te kurulur, dispose'ta kapatılır
  `- MaterialApp.builder:
       ChangeNotifierProvider<PeaceNoticeController>.value
         `- PeaceNoticeHost            (görünmez köprü; çocuğu aynen döndürür)
              `- CircuitBackground(child)
```

* **`PeaceNoticeController`** (`lib/services/peace_notice_controller.dart`): sayfalara ve `AutomationState`'e değil kabuğa bağlıdır. `AutomationState`'in yalnızca public yüzünü kullanır: dinleme/eylem (`addListener`, `sessionEvents`, `selectHome`, `refresh`, `fetchPeaceNotification`, `cloudApi`, `addBeforeLogoutHook`) ve okuma alanları (`peaceNotificationData`, `authStatus`, `isAuthenticated`, `isServiceSession`, `mustChangePassword`, `mode`, `homes`, `activeHome`, `capabilities`). Hiçbir yöntem istisna fırlatmaz.
* **`PeaceNoticeHost`** (`lib/ui/widgets/peace_notice_host.dart`): kendisi bir şey çizmez; denetleyiciyi dinler ve `ScaffoldMessenger` üzerinden gösterir:
  * bekleyen bildirim afişi ve yumuşak izin istemi = **`MaterialBanner`** (sayfayı aşağı iter, AppBar'ı kapatmaz; Tab ile erişilir; öncelik: bildirim afişi > yumuşak istem);
  * "Hepsini kapat" sonucu = **`SnackBar`** (8 sn, kalıcı değil, kapatma simgesi var, eylem yok; içerik yazı ölçeği 1.5 ile ve 6 satırla sınırlı). Oturum bitince, denetleyici uygun olmayınca, kilit ekranına ya da zorunlu parola ekranına geçilince, yeni bildirim afişi gelince ve köprü ağaçtan kalkınca kaldırılır.
* **Uygunluk** (`isEligible`): oturum açık, bulut modu, servis (PIN) oturumu değil ve evlerden en az birinde rol `owner` ya da `resident`. Misafir/servis oturumu afiş görmez.
* **`AutomationState`'e yalnızca çıkış kancası** eklendi: `addBeforeLogoutHook(Future<void> Function())`. Kancalar yalnızca `logout()` içinde, oturum belirteci henüz geçerliyken **eşzamanlı** başlatılır; çıkış en çok **1 sn** bekler (sonra yerel temizlik hemen yapılır), kancalar arka planda en çok 3 sn sürer; hata/zaman aşımı yutulur. `logoutAll()` sunucuda başarısız olursa kanca çalışmaz (oturum sürer). `AuthStatus` enum'una yeni değer **yok**; `closeAllOpenLights(String)` imzası **değişmedi**.
* **Push katmanı = "yapılandırılmadı" no-op.** `createPushGateway(config)` (`lib/services/push/push_gateway_factory.dart`) config ne olursa olsun `const UnsupportedPushGateway()` döndürür: izin/belirteç/akış yok, koordinatör `PushState.unsupported` kalır, sunucuya belirteç kaydı gitmez. Kapalı ve zararsızdır; ileride Firebase eklenirse yalnızca bu fabrika değişir (Ek bölüm). Ayar kartındaki `PushStatusTile`, bu durumda uygun kullanıcıya bildirimin telefona gönderilmediğini dürüstçe söyleyen tek bir bilgi satırı çizer (bölüm 4, RR3-02).

## 2. Yedek afiş (bu sürümde bildirimin tek yolu)

Uygulama açılınca / ev verisi yenilenince `AutomationState.refresh` → `fetchPeaceNotification()` (yalnızca bulut modunda, etkin ev varken ve `canChangeChildLock` yetkisi olan kullanıcılar için; ayar kartı da açılınca aynı çağrıyı yapar) sunucudan `GET /api/v1/devices/peace-notification/:home_id` yanıtını `peaceNotificationData`'ya yazar. Denetleyici bunu dinler (`_syncFallback`) ve `PeaceNotice.fromSettings` (`lib/services/push/peace_notice.dart`) ile afiş üretir. Afiş **yalnızca şu koşulların hepsi sağlanırsa** çıkar:

1. `home_id` geçerli;
2. `stale == false` (en az bir cihaz canlı; bayat veriyle "lamba açık" denmez);
3. `last_notice` var, `status` `sent` ya da `no_recipients` ve `resolved_at` boş (çözülmemiş);
4. `created_at` geçerli, **en çok 14 saat önce** (`defaultFallbackMaxAge`) ve gelecekte değil (2 dk saat sapması payı);
5. **canlı** `open_lights_count + open_shutters_count > 0` (sayılar gece kaydından değil canlı veriden alınır).

`noticeId = last_notice.id` olduğundan, ileride push de eklenirse aynı `dedupeKey` ile çift afiş çıkmaz.

**Afiş kalkması** (`_syncFallback`, her yeni ayar yanıtında; sıra önemlidir):

* Kullanıcı "Kapat" der: aynı afiş (kimliğiyle) oturum boyunca bir daha gösterilmez (bellek içi; bkz. bölüm 9, madde 8).
* **Taze** veri (`stale == false`, etkin eve ait) işin bittiğini söyler: `last_notice` aynı bildirim ve `resolved`/`resolved_at` dolu **ya da** tüm cihazlar çevrimiçi (`devices_total > 0` ve `devices_online == devices_total`) ve canlı lamba + panjur sayıları 0. Bu kural afişin KAYNAĞINA bakmaz (push afişi de kalkar).
* **Yedek afiş** (kaynağı ayar yanıtı olan), ayar yanıtından afiş artık üretilemiyorsa ayrıca kalkar: veri bayat (`stale`), `last_notice` yok ya da uygun durumda değil, 14 saat dolmuş ya da canlı sayılar 0. Dikkat: sayılar 0 ise bu kural evin bir kısmı çevrimdışı olsa da işler (bölüm 9, madde 9). Push kaynaklı afiş bu kurala tabi değildir.
* Oturum bitince ya da denetleyici uygun olmayınca afiş, kapatılanlar kümesi ve istem sıfırlanır (kilit ekranı ve zorunlu parola ekranı oturum bitişi sayılmaz; bölüm 9, madde 2).

Sunucu tarafı (salt okunur doğrulandı): `server/src/peace_reminder.js`, hatırlatma penceresinde ev için **canlı cihaz VAR ve açık lamba/panjur VARSA** kaydı yazar; push yapılandırılmamışsa durum `no_recipients` olur (`reason: push_not_configured`, satır 444 ve 818; kayıtlı belirteç yoksa `no_tokens`, satır 823). Canlı cihaz yoksa `skipped_offline` (`no_live_device`), hiçbir şey açık değilse `clear` (evin bir kısmı çevrimdışıysa `skipped_offline` / `partial_offline`) yazılır ve afiş çıkmaz. `peace_service.js` `no_recipients` kaydını ayar yanıtında görünür tutar (`NOTICE_VISIBLE_STATUSES = sent | no_recipients | resolved`) ve "Hepsini kapat" ile çözülebilir sayar (`RESOLVABLE_STATUSES = sent | no_recipients | sending`). Yani sunucuda push hiç kurulmasa da, o gece canlı bir cihaz ve açık lamba/panjur varsa kayıt oluşur ve uygulama açılınca yedek afişle görünür.

## 3. Model ve API değişiklikleri

İstemci yolları `/v1/...` biçimindedir; taban adres (`API_BASE_URL`, varsayılan `https://evotomasyon.gudeteknoloji.com.tr/api`) `/api` ile bittiğinden tam yol `/api/v1/...` olur (sunucu `/api/v1/devices` ve `/api/devices` olarak bağlar). Bu belgede yollar tam biçimiyle yazılır.

* **`PeaceNotificationSettings` v2** (`lib/models/api_models.dart`): `stale`, `devicesTotal`, `devicesOnline`, `openShutters`, `lastNotice` (yeni `PeaceLastNotice`) alanları; eski alanlar ve `raw` korunur.
* **`CloseAllResult` v2**: `closedShutters`, `skippedCount` (varsayılan 0), `nothingToDo`, `resolved`, `noticeId`.
* **`includeShutters` kuralı** (`lib/services/ev_cloud_api_service.dart`):
  * Eski pano düğmesi yolu `closeAllOpenLights(String homeId)` (imza değişmedi; test sahteleri `e1_helpers.dart` bu imzayla derlenir): gövde artık `{home_id, include_shutters: false}` (sunucu v2 varsayılanı panjurları da indirdiği için alan hep açıkça gider; eski davranış "yalnız lamba").
  * Afişten kapatma `closeAllForNotice(homeId, {noticeId, includeShutters = true})`: aynı uç (`POST /api/v1/devices/peace-notification/close-all`), gövde `{home_id, notice_id?, include_shutters}`. Denetleyici `includeShutters: notice.openShutters > 0` verir (afişte panjur yoksa panjura dokunulmaz).
* **Sonuç iletisi** (`_closeAllImpl`): `skipped_count == 0` ise afiş (çözüldü ya da `nothing_to_do` ayrımına bakılmadan) kalkar ve sunucu iletisi gösterilir; `nothing_to_do` ise "kapatıldı" denmez. `skipped_count > 0` ise afiş **açık kalır** ve sunucunun yaklaşık 166 karakterlik iletisi kullanılmaz (kritik talimat sonda; büyük yazıda kesiliyordu): istemci **53-72 karakterlik** kısa bir ileti üretir (rakamın hane sayısına göre). "Komut gönderildi; N öğe uzaktan kapatılamadı, lütfen elle kontrol edin." (71-72 karakter) yalnızca komut iletildiyse (`delivered` ve en az bir lamba/panjur kapatıldı/hedeflendiyse); aksi halde "N öğe uzaktan kapatılamadı; lütfen elle kontrol edin." (53-54 karakter).
* Push belirteci uçları (`PUT|DELETE /api/v1/me/push-tokens`; `registerPushToken` / `unregisterPushToken`) taban sürümde zaten vardır ve değişmez; bu sürümde push katmanı kapalı olduğundan hiç çağrılmazlar.

## 4. Ayar kartı: 2 satır ve dürüst bilgi satırı

`lib/ui/widgets/settings/peace_notification_card.dart`: 2 import (`../peace_reminder_details.dart`, `../push_status_tile.dart`) ve `CardCaption` açıklamasından hemen sonra, "Bildirim saati" satırından önce:

```dart
const PeaceReminderDetails(),   // "Son hatırlatma: ...", "Cihazlar: 1/2 çevrimiçi", bayat uyarısı
const PushStatusTile(),         // push durumu; sağlayıcı yoksa hiçbir şey çizmez
```

`PushStatusTile` sağlayıcıyı nullable arar (`PeaceNoticeController?`): kartın mevcut testleri sağlayıcısız çizdiği için bu şarttır (RB'de yakalanan kusur; düzeltme ve `test/ui/peace_card_integration_test.dart`).

**Dürüst bilgi satırı (RR3-02, ÇÖZÜLDÜ).** Kartın canlı açıklama metni (bizim değil, DOKUNULMADI) "Her gece belirlenen saatte açık kalan lamba veya panjur varsa tek bir bildirim alırsınız ve tek dokunuşla hepsini kapatabilirsiniz." der; Firebase'siz sürümde bildirim telefona hiç gönderilmediği için tek başına yanlış beklenti doğururdu. Bu yüzden `PushStatusTile`, **oturum uygunsa (owner/resident) ve push durumu `unsupported` ise** (bu sürümde hep) açıklamanın ve `PeaceReminderDetails` bloğunun altında, "Bildirim saati" satırından önce, soluk renkli, simgeli, eylemsiz tek satır çizer: "Bu sürümde bildirim telefona gönderilmez; uygulamayı açtığınızda hatırlatma görünür." Diğer durumlar değişmedi: `idle` ve uygun olmayan oturumda hiçbir şey çizilmez; `registered` / `registering` / `needsPermission` / `failed` metinleri Firebase eklenirse devreye girer (bu sürümde ulaşılamaz). Kart metnini ayrıca yumuşatmak ürün kararıdır (kart dosyası orkestratör/uygulama ekibinindir).

Testler: `test/ui/push_status_tile_test.dart` (unsupported + owner / resident / misafir, idle, açık/koyu tema AA kontrastı, 1.5 yazı ölçeği, Semantics) ve `test/ui/peace_card_integration_test.dart` (4 test; kartta satırın görünmesi dahil).

## 5. `pubspec.yaml` ve platform dosyaları

* **`pubspec.yaml`**: yalnızca `dev_dependencies` altına `fake_async: ^1.3.3` (`test/push/push_coordinator_test.dart` ve `test/services/automation_state_logout_hook_test.dart` kullanır; `flutter_test` bunu dışa aktarmaz). `pubspec.lock` farkı yalnızca `fake_async`'in "transitive" → "direct dev" olması. `pubspec.yaml`'da "firebase" kelimesi hiç geçmez. `pubspec.yaml` değişikliği `03-mevcut-dosyalar.patch` içindedir.
* **Platform dosyaları pakette YOKTUR (arşiv).** Kullanıcı kararı (Firebase yok) gereği şu değişiklikler paketten çıkarıldı, çünkü Firebase'siz sürümde hiçbir iş görmezler (RR3-03): Android `MainActivity.kt` bildirim kanalı (`peace_reminder`), `AndroidManifest.xml` `default_notification_icon` meta-data'sı ve `res/drawable/ic_stat_peace.xml`, iOS `Info.plist` `UIBackgroundModes = [remote-notification]`, `.gitignore` push-sır desenleri. Eski yamalar `yamalar/arsiv/05-platform.patch` ve `06-gitignore.patch` dosyalarındadır (not: `yamalar/arsiv/OKU-BENI.md`); Firebase/bildirim kanalı ileride istenirse bunlar `arsiv/` altındaki Firebase istemci dosyalarıyla ve `arsiv/SPL-dosya-ayrimi.txt` ayrımıyla birlikte düşünülür. iOS `AppDelegate.swift` ve `Runner-Bridging-Header.h` hiç değiştirilmedi (Firebase pod'una bağlıdırlar; paket yokken iOS derlemesini kırarlar). Sonuç: paket Android/iOS dosyalarına dokunmaz; orkestratörün Android işiyle (`MainActivity.kt`, `AndroidManifest.xml`) çakışma riski yoktur.

## 6. Dosya listesi (25 yeni + 6 değişen)

**Yeni lib (10):** `lib/services/peace_notice_controller.dart`, `lib/services/push_token_api_adapter.dart`, `lib/services/push/{peace_notice, push_config, push_coordinator, push_gateway, push_gateway_factory}.dart`, `lib/ui/widgets/{peace_notice_host, peace_reminder_details, push_status_tile}.dart`.
**Yeni test (15):** `test/push/{fakes, peace_notice_test, push_config_test, push_coordinator_test, push_gateway_factory_test, push_gateway_test}.dart`, `test/services/{automation_state_logout_hook_test, peace_notice_controller_test, peace_v2_models_and_api_test, push_token_api_adapter_test}.dart`, `test/ui/{peace_card_integration_test, peace_notice_host_test, peace_reminder_details_test, peace_ui_rig, push_status_tile_test}.dart`.
**Değişen (6):** `pubspec.yaml`, `lib/models/api_models.dart`, `lib/services/ev_cloud_api_service.dart`, `lib/services/automation_state.dart`, `lib/ui/app_shell.dart`, `lib/ui/widgets/settings/peace_notification_card.dart`. Ayrıca `pubspec.lock` (`flutter pub get` üretir; pakette yok).
**Pakette OLMAYAN (arşiv):** `android/**`, `ios/**` ve `.gitignore` değişiklikleri (bölüm 5), Firebase istemci kodu (`arsiv/`).

## 7. Uygulama sırası ve komutlar

Sıra (`yamalar/README.md` ve `uygula.sh` ile aynı):

1. `01-yeni-dosyalar.patch` (yeni 10 lib + 15 test dosyası)
2. `03-mevcut-dosyalar.patch` (`pubspec.yaml` dahil; `api_models.dart`, `ev_cloud_api_service.dart`, `automation_state.dart`, ayar kartı)
3. `04-app-shell.patch` (`app_shell.dart`)
4. `flutter pub get`

Komutlar (Git Bash; `<proje kökü>` depo köküdür):

```bash
cd <proje kökü>
bash docs/superpowers/analysis/wp-h-flutter/yamalar/uygula.sh --sadece-kontrol .   # hiçbir şey yazmaz
bash docs/superpowers/analysis/wp-h-flutter/yamalar/uygula.sh .                    # önce HEPSİNİ toptan dener; biri bile uygulanamazsa HİÇBİRİNİ uygulamaz
```

Elle, tek yama için: `git -c core.autocrlf=false apply --ignore-whitespace --check <yama>`, geçerse `git -c core.autocrlf=false apply --ignore-whitespace <yama>`; ardından CRLF'li dosyaları yeniden CRLF'e çevirin (aşağıdaki not). Geri alma ve çakışma çözümü: `yamalar/README.md`.

**Satır sonu notu:** gerçek ağaçta dosyalar karışık satır sonu taşır: `app_shell.dart`, `api_models.dart`, `automation_state.dart`, `pubspec.yaml` ve ayar kartı CRLF; `ev_cloud_api_service.dart` LF. Yeni dosyalar LF'dir. `--ignore-whitespace`, CRLF'li dosyalara eklenen satırları LF yazar: uygulamadan sonra o dosyaları `sed -i 's/\r$//; s/$/\r/' <dosya>` ile tamamen CRLF'e çevirin (`uygula.sh` bunu kendisi yapar). Satır sonu yüzünden hunk reddedilirse hunk'ı elle birleştirin ve dosyanın kendi satır sonunu koruyun (`patch --binary` CRLF/LF karışıklığında başarısız olur: RR1-07, RR2-07).

**Bilinen çakışma noktaları (el ile birleştirme gerekebilir):**

* `lib/ui/app_shell.dart`: `import` satırları (RB'de orkestratörün `common/deep_links.dart` importuyla çakıştı; çözüm: `../services/automation_state.dart`, `../services/peace_notice_controller.dart`, `common/deep_links.dart`, … alfabetik) ve `builder` gövdesi (`CircuitBackground` bizim `ChangeNotifierProvider` + `PeaceNoticeHost` sarmasının içinde kalır; `onGenerateRoute/onUnknownRoute/home: widget.home` dokunulmaz).
* `lib/services/automation_state.dart`: `addBeforeLogoutHook` bloğu ve `logout()` başındaki tek satır (`if (_beforeLogoutHooks.isNotEmpty) await _awaitLogoutHooksBriefly(_startBeforeLogoutHooks());`); orkestratörün `fetchHomeMembers/getHomeTransferStatus` kilit korumalarından farklı bölgededir.

Her adımdan sonra (özellikle mevcut dosyalar uygulandıktan sonra) hedefli çözümleme:

```
flutter analyze lib/services lib/models lib/ui/widgets lib/ui/app_shell.dart test/services test/push test/ui test/support
```

Tüm uygulandıktan sonra tam doğrulama (bölüm 8). Tek seferde yalnızca bir `flutter` komutu çalıştırın.

## 8. Doğrulama (taze canlı kopya `flutter_live2` = canlı taban + bu entegrasyon)

| Komut | Sonuç |
| --- | --- |
| `flutter pub get` | başarılı; lock farkı yalnız `fake_async` |
| `flutter analyze` (tam) | **No issues found** (taban 0 → 0; ~25 sn) |
| `flutter test` (tam) | **+2493 ~8: All tests passed** (taban +1903 ~8 → +590 yeni test; düzeltme öncesi +2486 / +583, bkz. tablonun son satırı; tabandaki hiçbir test kırılmadı; testlerin kendi süresi 1 dk 12 sn, komut toplam ≈ 1,5 dk) |
| `grep -rln "package:firebase" lib test pubspec.yaml` | sonuç yok |
| Yama uygulama kanıtı | temiz LIVE_BASE kopyasına `uygula.sh` ile 01 → 03 → 04 uygulandı; sonuç LIVE ile bayt bayt aynı (`diff -r`, çıktı boş, çıkış kodu 0); hata durumunda hiçbir şey uygulanmadığı da denendi (bozuk kopya: çıkış 1, dosyalar değişmedi) |
| Gerçek ağaçta `git apply --check` (YAZMA YOK) | 3/3 yama toptan ve tek tek geçti; `uygula.sh --sadece-kontrol` geçti (ağaç hareketlidir: uygulama anında yeniden deneyin) |
| `flutter build apk --debug` (LIVE'in taze kaynak kopyası, `PUB_CACHE` C: üstünde) | **BAŞARILI**: `app-debug.apk` 203.238.208 bayt (≈ 193,8 MiB); `flutter pub get` dahil toplam ≈ 2 dk 57 sn (pub get 5 sn; Gradle `assembleDebug` 166,7 sn). Birleşik manifestte `ic_stat_peace` ve `default_notification_icon` YOK (platform dosyaları tabanla aynı) |
| Gerçek ağaçta uygulama (2026-10-02 02:46–02:50; orkestratörün penceresi) | `uygula.sh` ile 3/3 yama atomik uygulandı (ters `git apply -R --check` 3/3 temiz; satır sonları korundu: CRLF'li 5 dosya tam CRLF, `ev_cloud_api_service.dart` LF); `flutter pub get` başarılı (lock farkı yalnız `fake_async`); tam `flutter analyze` **No issues found**; tam `flutter test` **+2641: All tests passed** (ağaçta orkestratörün kendi testleri de vardır, sayı bu yüzden farklıdır); gece hatırlatması hedefli seti **+611** geçti |
| Entegrasyon sonrası düzeltme: zorunlu parola ekranı da kilit (orkestratörün bağımsız eleştirmen bulgusu, düşük; 2026-10-02 ~05:00) | `PeaceNoticeController.isLocked` düzeltildi + 7 yeni test (`peace_notice_host_test` 3, `peace_notice_controller_test` 4): önce kırmızı (6 başarısız, 1 geçti), sonra yeşil (7/7); mutasyon 3/3 yakalandı (`_eligible` koşulunu silmek, `\|\|` → `&&`, `checking`'i silmek). Gerçek ağaçta tam `flutter analyze` **No issues found**; tam `flutter test` **+2650: All tests passed**. İzole `flutter_live2` kopyasında: analyze 0, tam test **+2493 ~8: All tests passed** (düzeltme öncesi +2486). Değişen dosyalar: `lib/services/peace_notice_controller.dart`, `lib/ui/widgets/peace_notice_host.dart` (yalnız yorum), 2 test dosyası; `01-yeni-dosyalar.patch` (447.965 → 455.201 bayt) ve `.txt` dışa aktarımları buna göre yenilendi (`03` ve `04` değişmedi). Kanıt: yeni `01` boş dizine uygulanınca 25 dosya gerçek ağaçla bayt bayt aynı; üç yamanın ters `git apply -R --check`'i gerçek ağaçta temiz |

Çakışma: RB birleştirmesinde 1 (yalnız `app_shell.dart` import satırları, elle çözüldü). Firebase'siz ayrımda ek kanıt (önceki tur): `flutter test test/services test/push test/ui` 1140 test geçti, hedefli analyze 0 sorun.

Önceki tur (G1, platform değişiklikleri paketteyken, `PushStatusTile` satırı eklenmeden önce): `flutter build apk --debug` başarılı (203.237.760 bayt, 2 dk 50 sn) ve `flutter build web` başarılı (1 dk 17 sn). Web derlemesi son turda yeniden çalıştırılmadı (yalnız APK).

Test titizliği (geliştirme turlarından; kayıtlar iş akışı dizinindedir, pakette yok): çekirdek delta 18 mutasyonun 17'si yakalandı (kaçan 1 tanesi, `_sessionEnded` savunma değişikliği, kanıtlı eşdeğer); arayüz 16/16, kısmi-sonuç iletisi 6/6, son turda `PushStatusTile` satırı (RR3-02) 6/6 mutasyon yakalandı. Her düzeltme önce kırmızı testle kanıtlandı.

**Çalıştırılmayanlar (dürüstlük):** iOS/Windows derlemesi, gerçek cihaz/emülatör, TalkBack/VoiceOver, gerçek Inter yazı tipi, gerçek gece akışı doğrulanmadı. Testler widget düzeyindedir. Yama uygulaması, `flutter pub get`, tam `flutter analyze` ve tam `flutter test` gerçek ağaçta yapıldı (yukarıdaki iki satır). **Cihazda/emülatörde deneme yapılmadı** (kullanıcıda); gerçek ağaçta APK/web/Windows derlemesini ben koşmadım (orkestratörün Android işi sürüyordu; debug APK ve web derlemesi izole kopyada, uygulamadan önce yapılmıştı).

## 9. Bilinen sınırlar (dürüst)

1. **Uygulama KAPALIYKEN telefona bildirim DÜŞMEZ.** Kullanıcı kararı: Firebase yok. Sunucu push yapılandırılmamış olduğundan kaydı `no_recipients` yazar; kullanıcı uygulamayı **açınca** yedek afişi görür (14 saat penceresi: 23:30 hatırlatması ertesi sabaha kadar anlamlıdır). Yedek afiş ayrıca `canChangeChildLock` yetkisi olan kullanıcıların ev verisi yenilemesine bağlıdır. Ayar kartının "bildirim alırsınız" açıklaması bu yüzden yanlış beklenti doğururdu: **ÇÖZÜLDÜ (RR3-02)**: `PushStatusTile` dürüst satırı gösterir (bölüm 4); kart metninin kendisi değişmedi.
2. **Kilit ekranı (`AuthStatus.checking`).** Kilit sırasında gelen push olayı yok sayılır (`_onNotice` `!isAuthenticated` ile atar); bu sürümde push olayı üretilmediği için pratik etkisi yoktur, yedek afiş ise kilit açılıp `authenticated` olunca ve veri yenilenince gelir (Firebase eklenirse bu kural gözden geçirilmelidir: öneri `authStatus == unauthenticated || isServiceSession`). Kilit (`checking`) sırasında uygunluk değerlendirmesi hiç yapılmaz (belirsiz durum; RR1-01 düzeltmesi). **Kilit ekranında bekleyen afiş görünmesi (RR3-01) ÇÖZÜLDÜ:** kilitliyken bekleyen afiş/istem/sonuç iletisi kilit ekranında gösterilmez (`PeaceNoticeController.isLocked`); afiş korunur ve kilit açılınca aynı afiş gelir. **Zorunlu parola değişimi ekranı da kilit sayılır (orkestratörün bağımsız eleştirmen bulgusu, düşük; ÇÖZÜLDÜ 2026-10-02):** oturum açık ve `mustChangePassword` iken `AuthGate` pano/oturum verisi göstermez (`forcedPasswordChange`); bu yüzden `isLocked` artık `_eligible && (authStatus == checking || mustChangePassword)` ve afiş, yumuşak istem, sonuç iletisi ile "Hepsini kapat" bu ekranda görünmez. Bekleyen afiş korunur, parola değişince aynı afiş gelir; uygunluk ve push etkilenmez (bu da oturum bitişi değildir). Testler: `test/ui/peace_notice_host_test.dart` ve `test/services/peace_notice_controller_test.dart` içindeki "zorunlu parola değişimi" grupları.
3. **Panodaki eski "Huzur Modu" bandı ile ikili yüzey (RR2-08).** `lib/ui/dashboard/peace_banner.dart` ("Huzur Modu / Gece Kontrolü") ve `CloseAllLightsButton` olduğu gibi duruyor; yeni afiş sayfanın tepesinde ayrıca çıkar, yani aynı anda iki "hepsini kapat" yüzeyi olabilir. Ürün kararı bekliyor (afiş açıkken eski bandı gizlemek ya da aynı eylemi çağırmak).
4. **Banner içerik yazı ölçeği 1.5 sınırı (RR2-06).** Çerçevenin `MaterialBanner`'ı içerik metnini 1.5'te sınırlar (eylem düğmeleri 2.0'a kadar büyür); WCAG 1.4.4 (%200) için başlık/gövde 2.0'da büyümez. Çerçeve davranışıdır, düzeltilmedi. Sonuç SnackBar'ı da yazı ölçeğinde 1.5 ve 6 satırla sınırlıdır: ölçekte >= 1.5'te uzun bir ileti görsel olarak kısalabilir (tam metin ekran okuyucuda durur). Bu yüzden kısmi sonuç iletisi kısa tutuldu (53-72 karakter, talimat başta); sunucunun uzun iletisi yine de hata yolundan gelirse (ör. `ApiException`) aynen gösterilir.
5. **Kısa ileti kuralı:** `skipped_count > 0` iken sunucunun ayrıntılı iletisi (ör. "2 lamba, 1 panjur") kullanıcıya gösterilmez; bilinçli (talimat önce).
6. **Bayat ev listesi (RR1-03):** ev listesi doluyken listede olmayan bir evin bildirimi atılır (önceki hesabın sızıntısını önlemek için); kullanıcı yeni eve eklenmişse ve liste henüz yenilenmediyse push bildirimi kaybolabilir. Yedek afiş etkilenmez (etkin evin ayar yanıtından gelir).
7. **Push katmanı kapalı olduğu için bu sürümde etkisiz olanlar** (Firebase eklenirse gözden geçirilmelidir): çevrimdışı çıkışta yerel belirteç iptalinin yeniden denenmemesi (RR1-05); `logoutAll` sonrası sunucu `DELETE` 401 (RR1-06); **doğrudan (LAN) moda geçişte push aboneliklerinin kopması ve o sırada dokunulan bildirimin kaybolması (R1 turunun B6 bulgusu; uygunluk `mode != cloud` iken false olur ve push durur)**.
8. **Kapatılan afişin kümesi yalnızca bellektedir ve oturumla sınırlıdır (R1 turunun B7 bulgusu):** "Kapat" dedikten sonra doğrudan moda geçip bulut moda dönmek ya da uygulamayı yeniden açmak, o gece için lambalar hâlâ açıksa (14 saat penceresi boyunca) aynı yedek afişi yeniden gösterir. Bu sürümde de GEÇERLİDİR (yedek afişi etkiler); kalıcı kapatma (kimlik + gün) ürün kararıdır.
9. **Kısmen çevrimdışı evde yedek afişin "hepsi kapalı" varsayımı:** canlı sayılar 0 ise `fromSettings` null döner ve mevcut yedek afiş kalkar, evin bir kısmı çevrimdışı olsa bile (bölüm 2; FXC gözlem b). Taze veriyle "iş bitti" kararı ise yalnızca tüm cihazlar çevrimiçiyken verilir (RR1-04).
10. Gerçek ağaçta e1 sahtesi (`test/ui/e1_helpers.dart`) `closeAllOpenLights(String homeId)` imzasıyla derlenir (imza geri alındı; RR1-02 kapandı). Başka bir sahte/test `closeAllForNotice`'u kullanan afiş yolunu geçersiz kılmak zorundaysa `UiCloudApi` (`peace_ui_rig.dart`) örneğine bakın.
11. **`PushStatusTile` satırı ve uygunluk değişimi:** denetleyici `isEligible` değişince dinleyicileri ayrıca uyarmaz; push durumu `unsupported` kalırken uygunluk kaybolursa satır bir sonraki yeniden çizime kadar kalabilir. Kart zaten uygunluk kaybında (çıkış, rol kaybı, doğrudan mod) sayfadan kalktığı için pratikte ulaşılamaz; kodda değiştirilmedi.

## Ek: Firebase ileride istenirse (ANA YOL DEĞİL)

Firebase kümesi canlıya alınmaz; yalnızca belge olarak saklanır. Dosya listesi ve gerekçeleri: `arsiv/SPL-dosya-ayrimi.txt` (üstündeki arşiv notunu okuyun: platform kısmı sonradan paketten çıkarıldı). Özet:

* **Paketler:** `pubspec.yaml`'a `firebase_core: ^4.15.0`, `firebase_messaging: ^16.7.0`. Kilide toplam **7 paket** girer: 2 doğrudan (`firebase_core 4.15.0`, `firebase_messaging 16.7.0`) + 5 geçişli (`_flutterfire_internals 1.3.77`, `firebase_core_platform_interface 8.1.1`, `firebase_core_web 3.12.0`, `firebase_messaging_platform_interface 4.10.0`, `firebase_messaging_web 4.2.5`).
* **Dart:** `lib/services/push/firebase_push_gateway.dart` (yeni; `FirebasePushGateway` + `PushConfig` uzantısı `toFirebaseOptions`; metni `arsiv/lib/services/push/firebase_push_gateway.dart.txt`), `push_gateway_factory.dart` değişir (config doluysa `FirebasePushGateway(config: config)`; imza aynı, denetleyici değişmez; Firebase'li metin `arsiv/lib/services/push/push_gateway_factory.dart.firebase-surumu.txt`), `test/push/firebase_push_gateway_test.dart` (21 test; `arsiv/test/push/firebase_push_gateway_test.dart.txt`) ve fabrika testinin 2. testi (`arsiv/test/push/push_gateway_factory_test.dart.firebase-surumu.txt`).
* **iOS:** `AppDelegate.swift` (`FLTFirebaseMessagingPlugin.configureNotificationCenterDelegate()`) ve `Runner-Bridging-Header.h` (`FLTFirebaseMessagingPlugin.h` bloğu); yalnızca paketle birlikte uygulanır.
* **Platform:** `yamalar/arsiv/05-platform.patch` (Android bildirim kanalı, manifest meta-data'sı, `ic_stat_peace.xml`, `Info.plist` `UIBackgroundModes`) ve `06-gitignore.patch` (push-sır desenleri).
* **Hesap/anahtarlar (yalnızca ileride Firebase istenirse kullanıcının yapacağı işler):** Firebase projesi ve Android/iOS uygulamaları, `FCM_*` `--dart-define` değerleri, sunucuda `FCM_PROJECT_ID` + `FCM_SERVICE_ACCOUNT_FILE` (dosya yolu), iOS için Apple APNs anahtarı (`.p8`) ve Xcode'da Push Notifications / Background Modes yetenekleri, FCM v1 API. Arşivlenmiş adımlar: `PUSH_KURULUM_ARSIV.md` (özet: `PUSH_KURULUM.md`).
* Firebase'li hâl yalnızca önceki turda INTEG kopyasında doğrulandı (analyze 0 sorun, `test/services test/push test/ui` 1161 test geçti); canlı kopyada ve gerçek cihazda denenmedi. INTEG'in `android/` ve `ios/` dosyaları son turda tabana döndürüldü.
