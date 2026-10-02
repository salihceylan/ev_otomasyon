# WP-H Flutter: gece hatırlatması istemcisi (Firebase'siz)

Açık kalan lambalar için gece hatırlatmasının Flutter istemcisi **gerçek ağaca uygulandı ve doğrulandı** (2026-10-02 02:46–02:50, `yamalar/` paketiyle; aynı gün ~05:00'te bir düzeltme eklendi, aşağıdaki son satıra bakın). Sunucu tarafı bu çalışmanın konusu değildir: orkestratör tarafından tamamlandığı ve canlıya uygulandığı bildirildi (bu belge dağıtım durumunu doğrulamaz); kodu depodaki `server/src` altındadır (`peace_reminder.js`, `peace_service.js`).

**Hesap/anahtar işi YOK:** Firebase hesabı, `google-services.json`, APNs anahtarı, `--dart-define` değerleri ya da sunucu kimlik bilgisi gerekmez. **Kalan iş yalnız cihazda/emülatörde denemedir** (kullanıcıda). Kod doğruluğu gerçek ağaçta analyze + tam test, izole kopyada ayrıca Android debug APK derlemesiyle kanıtlandı; cihaz denemesi yapılmadı.

## Güncel durum

* **Firebase KULLANILMIYOR** (kullanıcı kararı): `pubspec.yaml`'a yalnızca `fake_async` (dev) eklenir; `firebase_core` / `firebase_messaging` yok.
* Bildirim yalnızca uygulama açıkken / açılınca görünür: sunucunun `last_notice` verisinden yedek afiş (`MaterialBanner`; "Hepsini kapat" sonucu `SnackBar`). Uygulama **kapalıyken** telefona bildirim düşmez. Ayar kartı bunu uygun kullanıcıya (owner/resident) dürüstçe söyler: "Bu sürümde bildirim telefona gönderilmez; uygulamayı açtığınızda hatırlatma görünür." (RR3-02, çözüldü).
* Push gönderim katmanı "yapılandırılmadı" no-op olarak kalır (kapalı, zararsız). Sunucuda push kurulmazsa, o gece canlı bir cihaz ve açık lamba/panjur varsa gece kaydı `no_recipients` yazılır ve uygulama içinde görünür.
* **Platform dosyaları pakette YOK** (kullanıcı kararı; Firebase'siz sürümde işe yaramazlar): Android bildirim kanalı (`MainActivity.kt`), `AndroidManifest.xml` meta-data'sı, `ic_stat_peace.xml`, iOS `UIBackgroundModes`, `.gitignore` push-sır satırları. Paket `android/` ve `ios/` dosyalarına dokunmaz; orkestratörün Android işiyle çakışma riski yoktur. Eski yamalar `yamalar/arsiv/` altında saklıdır.
* Firebase kümesi (`firebase_push_gateway.dart`, testi, pubspec firebase satırları, iOS `AppDelegate.swift` + `Runner-Bridging-Header.h` değişiklikleri) **canlıya alınmaz**; yalnızca belge olarak saklanır.

## Doğrulama sonuçları

Taze canlı kopya (orkestratörün kapanış sonrası 01:06 ağacı) + bu entegrasyon:

| Komut | Sonuç |
| --- | --- |
| `flutter pub get` | başarılı (lock farkı yalnız `fake_async`) |
| `flutter analyze` (tam) | No issues found (taban 0 → 0) |
| `flutter test` (tam) | **+2493 ~8: All tests passed** (taban +1903 ~8; +590 yeni test, kırılan yok; 05:00 düzeltmesinden önce +2486 / +583) |
| `grep -rln "package:firebase" lib test pubspec.yaml` | sonuç yok |
| Yama uygulama kanıtı | temiz LIVE_BASE kopyası + `uygula.sh` = LIVE, bayt bayt aynı (`diff -r` boş) |
| Gerçek ağaçta `git apply --check` (uygulama öncesi, yazma yok) | 3/3 yama geçti; sonra uygulandı (sonraki satırlar) |
| Gerçek ağaçta uygulama (02:46–02:50) | `uygula.sh` atomik, 3/3 uygulandı; `flutter pub get` OK; tam `flutter analyze` **0 sorun**; tam `flutter test` **+2641 geçti** (ağaçtaki başka ekip testleriyle birlikte); hedefli set **+611** geçti |
| Düzeltme (~05:00): zorunlu parola ekranı da kilit (orkestratörün eleştirmen bulgusu, düşük) | `isLocked` + 7 yeni test (önce kırmızı, sonra yeşil; 3/3 mutasyon yakalandı); gerçek ağaçta analyze **0 sorun**, tam test **+2650 geçti**; `01` yaması ve `.txt` dışa aktarımları yenilendi (`ENTEGRASYON.md` bölüm 8-9) |
| `flutter build apk --debug` (taze kaynak kopya) | **başarılı**: `app-debug.apk` 203.238.208 bayt, ≈ 2 dk 57 sn |

**Çalıştırılmayanlar:** iOS/Windows derlemesi, gerçek cihaz/emülatör, TalkBack/VoiceOver; web derlemesi önceki turda (G1) başarılıydı, son turda yeniden çalıştırılmadı. Ayrıntı ve sınırlar: `ENTEGRASYON.md` bölüm 8-9.

## Dosyalar

* `ENTEGRASYON.md`: mimari, yedek afiş kuralları, API/model değişiklikleri, ayar kartı, pubspec ve platform (arşiv) notu, uygulama sırası ve komutları, doğrulama, bilinen sınırlar, ek: Firebase ileride istenirse.
* `PUSH_KURULUM.md`: "KULLANILMIYOR" notu ve arşiv özeti.
* `yamalar/README.md` ve `uygula.sh`: yama dosyaları (01, 03, 04), **uygulama sırası**, geri alma ve betik (sıra `ENTEGRASYON.md` bölüm 7 ile aynıdır, ayrılıkta `yamalar/README.md` geçerlidir). `yamalar/arsiv/`: eski platform ve `.gitignore` yamaları (uygulanmaz; `OKU-BENI.md`).
* `PUSH_KURULUM_ARSIV.md`: eski Firebase kurulum rehberi (uygulanmaz).
* `lib/`, `test/` altındaki `.txt` dosyalar: yeni 25 dosyanın (10 lib + 15 test) güncel, LIVE ile birebir salt-okunur kopyaları (yama paketindeki dosyalarla aynı içerik).
* `arsiv/`: Firebase kümesi (`firebase_push_gateway.dart`, testi, Firebase'li fabrika sürümleri; **uygulanmaz**) ve `SPL-dosya-ayrimi.txt` (Firebase'siz / Firebase'li dosya ayrımı; üstündeki arşiv notunu okuyun).
* `_wf/`: iş akışı betikleri (yeniden üretim için).

## Yama sırası (özet)

1. `01-yeni-dosyalar.patch`: yeni 10 lib + 15 test dosyası
2. `03-mevcut-dosyalar.patch`: `pubspec.yaml` (`fake_async`), `api_models.dart`, `ev_cloud_api_service.dart`, `automation_state.dart` (çıkış kancası), ayar kartı (2 satır)
3. `04-app-shell.patch`: `app_shell.dart`
4. `flutter pub get`

Çakışma beklenen yerler (orkestratörle ortak dosyalar): `app_shell.dart` import satırları ve `automation_state.dart`; gerçek ağaçta satır sonları karışıktır, `uygula.sh` bunu yönetir (elle: `git -c core.autocrlf=false apply --ignore-whitespace`). Ayrıntı: `ENTEGRASYON.md` bölüm 7.
