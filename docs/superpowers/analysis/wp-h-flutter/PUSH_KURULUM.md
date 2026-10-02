# Gece hatırlatması push bildirimi: KULLANILMIYOR

**Durum: Firebase / FCM bu projede kullanılmıyor (kullanıcı kararı).** Bu belgedeki eski Firebase kurulum rehberi arşivlenmiştir; **yapılacak bir kurulum adımı yoktur.** Uygulamaya `firebase_core` / `firebase_messaging` eklenmez, `google-services.json` / APNs anahtarı / `FCM_*` değerleri gerekmez.

## Şu anki davranış (koddan doğrulandı)

* **İstemci:** push katmanı "yapılandırılmadı" no-op'tur: `createPushGateway` (`lib/services/push/push_gateway_factory.dart`) her zaman `UnsupportedPushGateway` döndürür; belirteç alınmaz ve sunucuya kaydedilmez. Bildirim yalnızca uygulama açıkken / açılınca, sunucunun `last_notice` verisinden **yedek afiş** olarak görünür (kurallar: `ENTEGRASYON.md` bölüm 2). Ayar kartı, uygun kullanıcıya bildirimin telefona gönderilmediğini söyler (`ENTEGRASYON.md` bölüm 4).
* **Sunucu:** push yapılandırılmamışsa (`FCM_PROJECT_ID` ve kimlik bilgisi dosyası yoksa) gece hatırlatıcısı, ev için **canlı cihaz VAR ve açık lamba/panjur VARSA** kaydı **`no_recipients`** yazar (`reason: push_not_configured`; kayıtlı belirteç yoksa `no_tokens`): `server/src/peace_reminder.js` (satır 444, 818, 823). Canlı cihaz yoksa `skipped_offline`, hiçbir şey açık değilse `clear` yazılır ve afiş çıkmaz. `no_recipients` kaydı `peace_service.js`'te görünür sayılır (`NOTICE_VISIBLE_STATUSES = sent | no_recipients | resolved`) ve ayar yanıtında `last_notice` olarak döner; uygulama açılınca yedek afiş olarak **uygulama içinde görünür** ve "Hepsini kapat" ile çözülebilir (`RESOLVABLE_STATUSES = sent | no_recipients | sending`).
* **Bilinen sınır:** uygulama kapalıyken telefona bildirim düşmez.

## Arşiv: ileride Firebase istenirse (özet)

Eski rehberin içeriği kısaca (uygulanmaz; yalnızca ileride karar verilirse yol göstermek için):

1. **Firebase projesi** (Analytics gerekmez), **FCM API (V1)** etkin; Android uygulaması `com.ahbu.evotomasyon.ev_otomasyon`, iOS uygulaması `com.ahbu.evotomasyon.evOtomasyon`.
2. **İstemci değerleri** (herkese açık yapılandırma; `--dart-define` ile derlemede verilir, depoya girmez): `FCM_API_KEY`, `FCM_APP_ID` (Android/iOS için ayrı), `FCM_SENDER_ID`, `FCM_PROJECT_ID`. Yerel dosyada tutulur (`fcm*.local.json`). Dört değerden biri eksikse Firebase hiç başlatılmaz.
3. **Sunucu:** `FCM_PROJECT_ID` + servis hesabı anahtarının **dosya yolu** (`FCM_SERVICE_ACCOUNT_FILE` ya da `GOOGLE_APPLICATION_CREDENTIALS`; `server/src/services/push_service.js`). Anahtarı ortam değişkenine gömme seçeneği bilerek yoktur; **`FCM_SERVICE_ACCOUNT_JSON` diye bir değişken yoktur**, yalnızca dosya yolu verilir. Dosya depo dışında, yalnızca sunucu kullanıcısının okuyabileceği izinle durur.
4. **iOS:** Apple APNs kimlik doğrulama anahtarı (`.p8`) Firebase'e yüklenir; Xcode'da Push Notifications ve Background Modes (Remote notifications) yetenekleri; gerçek iPhone ile deneme.
5. **Kuru çalıştırma ve gerçek gönderim:** `PEACE_REMINDER_DRY_RUN=true` ve `PEACE_REMINDER_HOME_ALLOWLIST=<test-evi>` ile önce değerlendirme, sonra yalnızca test evinde gerçek gönderim.
6. **Uygulama tarafı:** `ENTEGRASYON.md` "Ek: Firebase ileride istenirse" bölümü (paketler, `firebase_push_gateway.dart`, fabrika değişikliği, iOS `AppDelegate`/köprü başlığı) ve `yamalar/arsiv/05-platform.patch` (Android bildirim kanalı, manifest meta-data'sı, `ic_stat_peace.xml`, `Info.plist` `UIBackgroundModes`).

## Gizlilik kuralları (her zaman geçerli)

API anahtarı, servis hesabı anahtarı (JSON), APNs `.p8` dosyası ve `fcm*.local.json` dosyaları **depoya girmez**, sohbete/ticket'a yapıştırılmaz, loglanmaz. Bu sürümde bu dosyalar zaten oluşmaz; yama paketi `.gitignore`'a bunlar için desen **eklemez** (platform/`.gitignore` yamaları paketten çıkarıldı). İleride Firebase istenirse `yamalar/arsiv/06-gitignore.patch` içindeki desenler (`*.p8`, `fcm*.local.json`, `google-services.json`, `GoogleService-Info.plist`, `*service-account*.json`, `*firebase-adminsdk*.json`) `.gitignore`'a eklenmelidir.

Eski rehberin tam metni (sorun giderme tablosu dahil): `PUSH_KURULUM_ARSIV.md`. Firebase'li istemci kodu: `arsiv/` (Firebase istemci dosyaları) ve `arsiv/SPL-dosya-ayrimi.txt` (dosya ayrımı); eski platform/`.gitignore` yamaları: `yamalar/arsiv/`.
