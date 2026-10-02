> ARSIV: Firebase kullanılmadığı için bu rehber UYGULANMAZ (kullanıcı kararı). Güncel durum: PUSH_KURULUM.md.

# Gece hatırlatması push bildirimi: Firebase kurulum rehberi

Bu rehber, sunucunun her yerel gece "açık lamba/panjur var" bildirimini (FCM) kullanıcıların telefonlarına
gönderebilmesi için gereken **Firebase tarafı** kurulumunu anlatır. Uygulamaya takılacak kod ve dosya listesi
için `ENTEGRASYON.md` dosyasına bakın.

> **Gizlilik kuralı:** Bu rehberdeki hiçbir değer gerçek değildir. API anahtarı, servis hesabı anahtarı (JSON),
> APNs `.p8` dosyası ve `fcm*.local.json` dosyaları **depoya girmez**, sohbete/ticket'a yapıştırılmaz, loglanmaz.

## 0. Nasıl çalışır (kısaca)

```
Sunucu (peace_reminder) --FCM HTTP v1--> Google FCM --> telefon
        ^ servis hesabı anahtarı            ^ istemci: FCM_* değerleriyle başlatılan Firebase uygulaması
```

* **İstemci** yalnızca dört herkese açık yapılandırma değerini (`FCM_*`) bilir; bunlar derleme sırasında
  `--dart-define` ile verilir. Değerler yoksa Firebase **hiç başlatılmaz**, uygulama push eklenmeden önceki
  haliyle çalışır (hata yok, çökme yok).
* **Sunucu** bildirimi göndermek için FCM'e bir **servis hesabı anahtarıyla** kimlik doğrular. Bu anahtar bir
  sırdır ve yalnızca sunucuda durur.
* Android'de sunucu `notification` bloğu gönderdiği için uygulama kapalıyken bildirimi **sistem** gösterir;
  dokunulunca uygulama açılır ve bildirim verisi uygulamaya iletilir.

## 1. Firebase projesi oluşturma

1. <https://console.firebase.google.com> adresinde **Proje ekle** deyin (mevcut bir Google Cloud projesini de
   seçebilirsiniz).
2. Google Analytics gerekmez; kapatabilirsiniz (bu özellik analitik kullanmaz).
3. Proje oluşunca **Proje ayarları → Genel** sayfasındaki **Proje kimliği** ve **Proje numarası** değerlerini not
   edin (aşağıda `FCM_PROJECT_ID` ve `FCM_SENDER_ID` olacaklar).
4. **Proje ayarları → Cloud Messaging** sayfasında **Firebase Cloud Messaging API (V1)** durumunun
   **Etkin** olduğunu doğrulayın. Eski "Cloud Messaging API (Legacy)" gerekmez ve kullanılmaz.

## 2. Android uygulamasını ekleme

1. **Proje ayarları → Genel → Uygulamalarınız → Android uygulaması ekle**.
2. **Android paket adı** (bu depodaki `android/app/build.gradle.kts` içindeki `applicationId`):

   ```
   com.ahbu.evotomasyon.ev_otomasyon
   ```

   Paket adı **birebir** aynı olmalıdır; farklı olursa FCM belirteç alma/gönderme çalışmaz.
3. SHA-1 parmak izi FCM için gerekmez (Google ile oturum açma için ayrı bir konu).
4. Konsolun önerdiği `google-services.json` dosyasını **indirebilirsiniz ama projeye eklemenize gerek yoktur**:
   bu entegrasyon Firebase'i Dart tarafında `FirebaseOptions` ile başlatır (bölüm 3), bu yüzden `google-services`
   Gradle eklentisi de gerekmez. Dosya, bölüm 3'teki değerlerin okunacağı kaynak olarak işe yarar.

## 3. `FCM_*` değerlerinin nereden alınacağı

Dört değer, indirilen `google-services.json` dosyasından (ya da konsolda **Proje ayarları → Genel → Uygulamalarınız
→ Android uygulaması** altından) alınır:

| `--dart-define` anahtarı | `google-services.json` içindeki alan | Konsolda |
|---|---|---|
| `FCM_API_KEY` | `client[0].api_key[0].current_key` | "Web API Anahtarı" / uygulama API anahtarı |
| `FCM_APP_ID` | `client[0].client_info.mobilesdk_app_id` (`1:<numara>:android:<hash>`) | "Uygulama Kimliği" |
| `FCM_SENDER_ID` | `project_info.project_number` | "Proje numarası" / "Gönderen kimliği" |
| `FCM_PROJECT_ID` | `project_info.project_id` | "Proje kimliği" |

> Not (doğrulama): Alan adlarının `firebase_core`'daki karşılığı `FirebaseOptions(apiKey, appId,
> messagingSenderId, projectId)` biçimindedir (paket kaynağında doğrulandı). `google-services.json` biçimi ise
> Firebase konsolunun çıktısıdır; paket kaynaklarından doğrulanamaz. Konsol arayüzü değişirse alanları
> yukarıdaki anlamlarına göre eşleştirin.

Değerleri yerel bir dosyaya koyun (örnek **uydurma** değerlerle; gerçeklerini kendiniz yazın):

```json
{
  "FCM_API_KEY": "<api-anahtari>",
  "FCM_APP_ID": "1:<proje-numarasi>:android:<hash>",
  "FCM_SENDER_ID": "<proje-numarasi>",
  "FCM_PROJECT_ID": "<proje-kimligi>"
}
```

Dosyayı `fcm.local.json` adıyla kaydedin ve **`.gitignore`'a ekleyin** (`fcm*.local.json`; aşağıdaki `fcm.android.local.json`/`fcm.ios.local.json` dosyalarını da kapsar). CI'da değerler gizli
değişken (secret) olarak verilir.

### iOS için ek değerler

iOS uygulamasının paket kimliği (`ios/Runner.xcodeproj` içindeki `PRODUCT_BUNDLE_IDENTIFIER`) Android'dekinden
**farklıdır**:

```
com.ahbu.evotomasyon.evOtomasyon
```

Konsolda ayrıca **iOS uygulaması ekle** ile bu kimliği kaydedin. iOS'ta Dart tarafında verilen `FCM_APP_ID`
**iOS uygulamasının** kimliği olmalıdır (`1:<numara>:ios:<hash>`); aynı derleme komutu iki platform için aynı
dosyayı kullanacaksa iki ayrı dosya tutun (`fcm.android.local.json`, `fcm.ios.local.json`). iOS kimlik değeri
`GoogleService-Info.plist` içindeki `GOOGLE_APP_ID` alanından okunur (Firebase konsolu biçimi; doğrulanamaz).

## 4. Sunucu için servis hesabı anahtarı (`FCM_SERVICE_ACCOUNT_FILE`)

Sunucu FCM HTTP v1 API'sini bir **servis hesabı** ile çağırır.

1. Konsolda **Proje ayarları → Hizmet hesapları → Yeni özel anahtar oluştur** deyin; bir `.json` dosyası iner.
2. Dosyayı **sunucu makinesinde, depo dışında** bir yere koyun ve yalnızca sunucu kullanıcısının okuyabileceği
   izinle koruyun (ör. Linux'ta `chmod 600`). Hiçbir zaman git'e, Docker imajına ya da sohbete koymayın.
3. Sunucunun ortam değişkenlerini ayarlayın (değişken adları `server/src/services/push_service.js` içinde
   doğrulandı):

   | Değişken | Açıklama |
   |---|---|
   | `FCM_PROJECT_ID` | Firebase proje kimliği (bölüm 3'teki `FCM_PROJECT_ID` ile aynı) |
   | `FCM_SERVICE_ACCOUNT_FILE` | Servis hesabı JSON dosyasının yolu (alternatif: `GOOGLE_APPLICATION_CREDENTIALS`) |

   Anahtarı ortam değişkenine **gömme seçeneği bilerek yoktur** (özel anahtar `ps`, çökme dökümü ya da compose
   dosyası üzerinden sızabilir): yalnızca dosya yolu verilir; dosya git'e/imaja girmez, salt okunur bağlanır.

   `FCM_PROJECT_ID` ile kimlik bilgisi dosyası birlikte yoksa sunucu push'u **yapılandırılmamış**
   sayar: hatırlatıcı yine çalışır ve kaydını yazar, ama gönderim yapmaz (`no_recipients`, neden
   `push_not_configured`).
4. Servis hesabının FCM'e gönderme yetkisi olmalıdır (Firebase'in oluşturduğu varsayılan "firebase-adminsdk"
   hesabı yeterlidir). Yetki hatası alırsanız bölüm 8'e bakın.

## 5. iOS: APNs anahtarı yükleme

iOS bildirimleri Apple'ın APNs hizmetinden geçer; Firebase'in APNs'e bağlanabilmesi için Apple'dan bir
kimlik doğrulama anahtarı gerekir.

1. <https://developer.apple.com/account> → **Certificates, Identifiers & Profiles → Keys** → yeni anahtar
   oluşturun, **Apple Push Notifications service (APNs)** kutusunu işaretleyin ve `.p8` dosyasını indirin
   (yalnızca bir kez indirilebilir). **Key ID** ve **Team ID** değerlerini not edin.
2. Firebase konsolunda **Proje ayarları → Cloud Messaging → Apple uygulaması yapılandırması → APNs kimlik
   doğrulama anahtarı → Yükle** ile `.p8`, Key ID ve Team ID'yi girin. `.p8` dosyası depoya girmez.
3. Xcode'da `Runner` hedefi → **Signing & Capabilities** altında şunları ekleyin:
   * **Push Notifications** (uygulamanın `aps-environment` yetkisini üretir),
   * **Background Modes → Remote notifications** (`Info.plist` içinde `UIBackgroundModes` →
     `remote-notification`; ayrıntı `ENTEGRASYON.md`).
4. Gerçek bir iPhone ile deneyin. Simülatörde APNs belirteci alınamayabilir; bu durumda uygulama belirteci "henüz
   yok" sayar (APNs belirtecini 10 sn yoklar), sonra geri çekilmeyle yeniden dener (kayıt oluşmaz, çökme olmaz).
5. iOS minimum sürümü: `firebase_messaging` 16.7.0 `ios/firebase_messaging.podspec` içinde iOS 15.0 ister;
   projenin `IPHONEOS_DEPLOYMENT_TARGET` değeri 15.0 olduğundan uyumludur.

## 6. Derleme ve çalıştırma örnekleri

Değerler dosyadan okunur (önerilen):

```bash
# Geliştirme (Android, USB'li cihaz)
flutter run --dart-define-from-file=fcm.local.json

# Sürüm APK
flutter build apk --release --dart-define-from-file=fcm.local.json

# iOS
flutter build ipa --release --dart-define-from-file=fcm.ios.local.json
```

Ya da tek tek:

```bash
flutter run \
  --dart-define=FCM_API_KEY=<api-anahtari> \
  --dart-define=FCM_APP_ID=<uygulama-kimligi> \
  --dart-define=FCM_SENDER_ID=<proje-numarasi> \
  --dart-define=FCM_PROJECT_ID=<proje-kimligi>
```

`--dart-define` verilmeden derlenen uygulama push'suz çalışır (ayarlar sayfasında "Bildirimler bu sürümde
kapalı" gibi bir durum gösterilebilir); bu **normal ve güvenlidir**.

## 7. Test adımları

### 7.1 İstemci tarafı (sunucusuz)

1. `fcm.local.json` ile uygulamayı bir Android 13+ telefonda çalıştırın ve giriş yapın.
2. Ayarlar sayfasında **Bildirimleri aç** deyin; sistem izin penceresi çıkmalıdır (Android 13+; daha eski
   sürümlerde pencere çıkmaz, bildirimler sistem ayarından kapatılmadıkça açıktır).
3. Sunucuda `push_tokens` tablosunda kullanıcının satırını görün (`disabled_at` boş olmalı).
4. Çıkış yapın: satır `disabled_at` ile işaretlenmeli (silme isteği gitti).

### 7.2 Sunucu tarafı: kuru çalıştırma (`PEACE_REMINDER_DRY_RUN`)

Kuru çalıştırma **hiçbir şey yazmaz ve push göndermez**; yalnızca hangi evlerin bildirim alacağını değerlendirir
ve loglar. Hatırlatıcının doğru evleri ve cihazları gördüğünü doğrulamak içindir.

```bash
# sunucu ortamı (örnek)
PEACE_REMINDER_DRY_RUN=true
PEACE_REMINDER_HOME_ALLOWLIST=<test-evinin-uuid>   # yalnızca bu ev değerlendirilir
```

Evin bildirim saatini (uygulamada Cihaz ayarları → Huzur bildirimi) birkaç dakika sonrasına alın, bir lambayı
açık bırakın ve sunucu loglarında o evin "açık bir şey var" olarak değerlendirildiğini görün.

### 7.3 Sunucu tarafı: gerçek gönderim

1. `PEACE_REMINDER_DRY_RUN` değişkenini kaldırın (ya da `false` yapın) ve `PEACE_REMINDER_HOME_ALLOWLIST`'i
   yalnızca test evinizle sınırlı tutun.
2. Bir lambayı açık bırakın, bildirim saatini 2-3 dakika sonrasına alın, uygulamayı **kapatın** (arka plana değil,
   tamamen kapatın).
3. Saat gelince telefonda "Salonda 1 lamba açık." biçiminde bir sistem bildirimi görünmelidir. Dokununca uygulama
   açılır ve uygulama içi "Hepsini kapat" akışı karşılar.
4. Sunucuda `peace_notification_logs` içinde ilgili günün satırının `status` değeri `sent` olmalıdır.
   Diğer değerler: `clear` (hiçbir şey açık değil), `no_recipients` (token yok ya da push yapılandırılmamış),
   `skipped_offline` (cihaz çevrimdışıydı, pencere bitene kadar yeniden denenir), `failed`.
5. Aynı gece ikinci kez denemek için **yalnızca test veritabanında** o günün satırını silmeniz gerekir
   (hatırlatıcı bir evde gecede en çok bir kez gönderir).

Ön plan testi: uygulama açıkken bildirim saati gelirse sistem bildirimi **gösterilmez**; uygulama kendi afişini
çıkarır (bu bir tasarım kararıdır).

## 8. Sorun giderme

| Belirti | Olası neden | Ne yapmalı |
|---|---|---|
| Uygulamada push hiç etkin değil, hata da yok | `--dart-define` verilmemiş ya da dört değerden biri boş | `flutter run --dart-define-from-file=...` ile çalıştırın; dosyadaki dört anahtarı kontrol edin |
| Başlangıçta `duplicate-app` benzeri sessiz kapanma | Projede ayrıca `google-services.json`/plist var ve `apiKey` değeri `FCM_API_KEY` ile uyuşmuyor | İkisini aynı Firebase uygulamasına ait yapın ya da yerel dosyayı kaldırın (bu durumda push "desteklenmiyor" sayılır) |
| Android 13+'ta izin penceresi çıkmıyor | İzin daha önce iki kez reddedilmiş (sistem artık sormaz) | Sistem ayarları → Uygulamalar → Bildirimler'den açın; uygulama dönünce kendiliğinden kaydolur |
| Android 12 ve altında "izin kapalı" uyarısı | Kullanıcı bildirimleri sistem ayarından kapatmış (bu sürümlerde izin penceresi yoktur) | Sistem ayarlarından açtırın |
| Uygulama açıkken bildirim gelmiyor | Beklenen davranış: ön planda sistem bildirimi yok, uygulama kendi afişini gösterir | Afişin arayüzde bağlandığını kontrol edin (`ENTEGRASYON.md`) |
| Uygulama kapalıyken bildirim geliyor ama başlık/ikon bozuk ya da sessiz | Android `peace_reminder` bildirim kanalı uygulamada oluşturulmamış (sunucu bu kanal kimliğini yollar) | `ENTEGRASYON.md` "Android bildirim kanalı" bölümünü uygulayın |
| iOS'ta token hiç gelmiyor | APNs anahtarı Firebase'e yüklenmemiş, Push Notifications yeteneği yok ya da simülatör | Bölüm 5'i tamamlayın; gerçek cihazla deneyin |
| Sunucu logunda `PUSH_NOT_CONFIGURED` / kayıtta `push_not_configured` | `FCM_PROJECT_ID` ya da servis hesabı değişkeni yok | Bölüm 4 |
| Sunucu FCM'den 401/403 alıyor | Servis hesabı anahtarı geçersiz/iptal ya da projede FCM v1 API kapalı | Yeni anahtar üretin; bölüm 1.4'ü doğrulayın |
| Sunucu FCM'den 404/`UNREGISTERED` alıyor | Uygulama silinmiş ya da belirteç eskimiş | Normaldir: sunucu belirteci kapatır, uygulama sonraki açılışta yenisini kaydeder |
| Kayıt `failed` kalıyor, yeniden denemiyor | Sunucu belirteci kalıcı reddetti (ör. servis oturumu 403, geçersiz belirteç 400) | Normal kullanıcı hesabıyla giriş yapın; ya da yeni belirteç/oturumla yeniden denenir |
| Bildirim her gece iki kez geliyor | İki ayrı cihaz/hesap kaydı ya da çifte sunucu örneği | `push_tokens` satırlarını ve sunucu örnek sayısını kontrol edin (sunucu ev başına tek kayıt yazar) |

## 9. Doğrulama kapsamı (dürüst not)

Bu rehberin paket-davranışı iddiaları `firebase_core 4.15.0` ve `firebase_messaging 16.7.0` kaynak kodları
okunarak doğrulandı. **Gerçek cihaz, gerçek FCM ve iOS tarafında henüz hiçbir şey denenmedi**; özellikle:

* Android'de uygulama tamamen kapalıyken, yalnızca Dart tarafında başlatılmış (yerel `google-services.json`
  olmayan) Firebase ile sistem bildiriminin gelmesi gerçek cihazda doğrulanmalıdır. Gelmezse yedek yol:
  `google-services.json` dosyasını `android/app/` altına koyup `com.google.gms.google-services` Gradle
  eklentisini eklemek (bu durumda `FCM_*` değerleri o dosyayla uyumlu olmalıdır).
* APNs akışı (bölüm 5) yalnızca belge olarak yazıldı.
