# Gece hatırlatması (Flutter) yama paketi

Taban: orkestratörün kapanış sonrası (2026-10-02 01:06) ağacının dokunulmamış kopyası (LIVE_BASE). Sonuç: LIVE (taban + entegrasyon). **Durum:** 01/03/04 gerçek ağaca 2026-10-02 02:46–02:50'de uygulandı; `01` yaması aynı gün ~05:00'te yenilendi (zorunlu parola ekranı = kilit düzeltmesi: `peace_notice_controller.dart`, `peace_notice_host.dart` yorumları ve 2 test dosyası); `03` ve `04` değişmedi. Geri alma bu güncel `01` yamasına göre çalışır (gerçek ağaçta ters kontrol temiz). **Firebase yok** (kullanıcı kararı): `pubspec.yaml`'a yalnızca `fake_async` (dev) eklenir.

Bu pakette **YOKTUR** (hepsi `../arsiv/` ya da `arsiv/` altında, uygulanmaz):

* `firebase_push_gateway.dart` ve testi, iOS `AppDelegate.swift` / `Runner-Bridging-Header.h` değişiklikleri (bkz. `../arsiv/`, ayrım: `../arsiv/SPL-dosya-ayrimi.txt`);
* Firebase'siz sürümde işe yaramayan platform değişiklikleri (kullanıcı kararı, RR3-03): Android bildirim kanalı (`MainActivity.kt`), `AndroidManifest.xml` meta-data'sı, `ic_stat_peace.xml`, iOS `Info.plist` `UIBackgroundModes` ve `.gitignore` push-sır satırları. Eski yamaları: `arsiv/05-platform.patch`, `arsiv/06-gitignore.patch` (not: `arsiv/OKU-BENI.md`). Böylece orkestratörün Android işiyle (`MainActivity.kt`, `AndroidManifest.xml`) çakışma riski de yoktur.

Hepsi LF-normalize `git diff --no-index` çıktısıdır; yol önekleri depo köküne göredir (`a/lib/...`). `pubspec.lock` pakette yoktur: uygulamadan sonra `flutter pub get` çalıştırılır (kilit farkı yalnızca `fake_async` transitive -> direct dev).

## Uygulama sırası

| # | Dosya | İçerik | Dokunduğu mevcut dosyalar / sahip ekip |
| --- | --- | --- | --- |
| 1 | `01-yeni-dosyalar.patch` | 25 YENİ dosya. lib (10): `lib/services/peace_notice_controller.dart`, `lib/services/push_token_api_adapter.dart`, `lib/services/push/{peace_notice, push_config, push_coordinator, push_gateway, push_gateway_factory}.dart` (5, Firebase'siz), `lib/ui/widgets/{peace_notice_host, peace_reminder_details, push_status_tile}.dart`. test (15): `test/push` (6), `test/services` (4), `test/ui` (5) | Yok (yalnızca yeni dosya). Çakışma olası değil. |
| 2 | `03-mevcut-dosyalar.patch` | `lib/models/api_models.dart` (gece hatırlatması v2 modelleri: `PeaceNotificationSettings` yeni alanları, `PeaceLastNotice`, `CloseAllResult` v2), `lib/services/ev_cloud_api_service.dart` (`closeAllOpenLights` gövdesine `include_shutters: false` + yeni `closeAllForNotice`; push belirteci uçları tabanda zaten vardır, değişmez), `lib/services/automation_state.dart` (çıkış kancası; **2 bölge**), `lib/ui/widgets/settings/peace_notification_card.dart` (2 import + 2 satır), `pubspec.yaml` (`fake_async`) | Flutter/uygulama ekibi; `automation_state.dart` orkestratörle ORTAK (kilit korumaları `fetchHomeMembers`/`getHomeTransferStatus` başında; bizim bölgelerimiz `logoutAll` öncesi ve `logout()` başı) |
| 3 | `04-app-shell.patch` | `lib/ui/app_shell.dart`: 2 import, `_peace` alanı + `initState`/`dispose`, `MaterialApp.builder` sarmalayıcısı | orkestratörle ORTAK (`onGenerateRoute`/`onUnknownRoute`/import satırları) |

Numaralar (01, 03, 04) bilerek böyledir: `02` (Firebase yaması) ve `05`, `06` (platform, `.gitignore`) pakette YOKTUR; `05`/`06` `arsiv/` altındadır.

Yamalar birbirinden ayrık dosyalara dokunur; sıra yine de yukarıdaki gibidir (yeni dosyalar -> mevcut dosyalar (`pubspec.yaml` dahil) -> kabuk), ardından `flutter pub get`. 03 ve 04 yamaları `-U1` (1 satır bağlam) ile üretildi: komşu satırlara başkaları dokunduysa yine uygulanabilsin diye. 01 `-U3`.

## Satır sonu uyarısı (CRLF / LF)

Gerçek ağaçta satır sonları karışıktır: `app_shell.dart`, `automation_state.dart`, `api_models.dart`, `pubspec.yaml` ve ayar kartı **CRLF**; `ev_cloud_api_service.dart` **LF** (2026-10-02'de gerçek ağaçta sayıldı; yalnız okuma). Yamalar LF'dir.

* Elle uygularken: `git -c core.autocrlf=false apply --ignore-whitespace <yama>` (Windows'ta `core.autocrlf=true` iken `git apply` LF'li dosyaları da tümden CRLF'e çevirir; `=false` bunu önler).
* `--ignore-whitespace` CRLF'li dosyalarda eklenen satırları LF yazar: CRLF'li dosya uygulamadan sonra tamamen CRLF'e çevrilmelidir: `sed -i 's/\r$//; s/$/\r/' <dosya>`. `uygula.sh` bunu otomatik yapar (uygulamadan ÖNCE dosyada CR varsa).
* Kanıt: temiz bir LIVE_BASE kopyasına `uygula.sh` ile uygulanınca sonuç LIVE ile **bayt bayt aynı** çıktı (`diff -r`, `.dart_tool`/`build`/`pubspec.lock` hariç; çıktı boş, çıkış kodu 0).

## Çakışma olursa: 3 yönlü birleştirme notları

İki dosyayı orkestratör de değiştiriyor (`app_shell.dart`, `automation_state.dart`). Bir yama `git apply --check` ile reddedilirse: `git -c core.autocrlf=false apply --reject --ignore-whitespace <yama>` ile uygulanabilen hunk'lar yazılır, reddedilenler `<dosya>.rej` olur; aşağıdaki yerlere elle ekleyin (hepsi küçük, bağımsız eklemelerdir), sonra `.rej`/`.orig` dosyalarını silin.

* **`app_shell.dart`**: (a) `import '../services/peace_notice_controller.dart';` ve `import 'widgets/peace_notice_host.dart';` (alfabetik sıraya yakın); (b) `late final PeaceNoticeController _peace;` alanı, `initState`'te `_peace = PeaceNoticeController(state: state);`, `dispose`'ta `_peace.dispose();` (en sonda, `super.dispose()` öncesi); (c) `MaterialApp.builder`: `CircuitBackground`'u `ChangeNotifierProvider<PeaceNoticeController>.value(value: _peace, child: PeaceNoticeHost(child: CircuitBackground(...)))` ile sarın. `onGenerateRoute`, `onUnknownRoute`, `home: widget.home` DEĞİŞMEZ.
* **`automation_state.dart`**: iki bağımsız bölge: (a) `logoutAll()` doc yorumundan ÖNCE `_beforeLogoutHooks` alanları + `addBeforeLogoutHook` + `_startBeforeLogoutHooks` + `_awaitLogoutHooksBriefly` bloğu (saf ekleme); (b) `logout()` başında tek satır: `if (_beforeLogoutHooks.isNotEmpty) await _awaitLogoutHooksBriefly(_startBeforeLogoutHooks());` ve doc yorumu. Orkestratörün `fetchHomeMembers` / `getHomeTransferStatus` başındaki kilit koruması farklı bölgededir. `AuthStatus` enum'una yeni değer EKLENMEZ; `closeAllOpenLights(String)` imzası DEĞİŞMEZ.
* **`pubspec.yaml`**: `dev_dependencies` altına `fake_async: ^1.3.3` (yorumlu) satırı; sonra `flutter pub get`.
* **`ev_cloud_api_service.dart`** ve **`api_models.dart`**: yalnızca ekleme ve `closeAllOpenLights` gövdesinde tek satır (`include_shutters: false`); çakışma beklenmez.

## Geri alma

Yama klasörünün MUTLAK yolunu bir değişkene koyun (yamalar proje kökünün içinde DEĞİL, `docs/superpowers/analysis/wp-h-flutter/yamalar/` altındadır) ve TERS sırayla geri alın:

```bash
cd <proje kökü>
YAMA_DIZIN=/g/site/ev_otomasyon/docs/superpowers/analysis/wp-h-flutter/yamalar   # bu klasörün mutlak yolu
git -c core.autocrlf=false apply -R --ignore-whitespace \
  "$YAMA_DIZIN/04-app-shell.patch" "$YAMA_DIZIN/03-mevcut-dosyalar.patch" "$YAMA_DIZIN/01-yeni-dosyalar.patch"
```

Geri alma, yeniden eklenen satırları LF yazar: `lib/services/automation_state.dart` ve `lib/ui/app_shell.dart` dosyalarını `sed -i 's/\r$//; s/$/\r/' <dosya>` ile yeniden CRLF'e çevirin (diğer CRLF'li dosyalar yalnızca satır kaybeder), sonra `flutter pub get` çalıştırın. Kanıt: uygulanmış temiz kopyada bu komut + iki dosyanın CRLF onarımı sonucu LIVE_BASE ile bayt bayt aynıdır (`diff -r`). Yalnızca bir yamayı geri almak için yalnız o yamayı verin.

## Uygulama betiği

```bash
bash uygula.sh --sadece-kontrol <proje kökü>   # hiçbir şey yazmaz; bütün yamaları toptan 'git apply --check' ile dener
bash uygula.sh <proje kökü>                    # önce HEPSİNİ toptan dener; biri bile uygulanamazsa HİÇBİRİNİ uygulamaz; sonra uygular
```

`<proje kökü>` depo kökü olmalıdır (betik, git deposunun alt dizininde çalışmayı reddeder: `git apply` orada kök-göreli yolları hata vermeden atlar). Betik analyze/test'i ÇALIŞTIRMAZ; sonunda komutları yazdırır. Beklenen sonuç: `flutter analyze` 0 sorun; tam `flutter test` **+2493 ~8** (taban +1903 ~8; 05:00 düzeltmesinden önce +2486; bu kopyada ölçüldü, gerçek ağaçta diğer ekiplerin testleriyle sayı değişebilir, hiçbir test kırılmamalı).
