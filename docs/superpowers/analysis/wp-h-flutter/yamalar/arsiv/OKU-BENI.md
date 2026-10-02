# Arşiv: platform ve `.gitignore` yamaları (UYGULANMAZ)

Bu klasördeki yamalar **yama paketinin parçası DEĞİLDİR**; `uygula.sh` bunları uygulamaz ve `yamalar/README.md` sırasında yer almaz.

## Neden arşivlendi

Kullanıcı kararı: **Firebase yok.** Firebase'siz sürümde bildirim telefona gönderilmez; bu yüzden aşağıdaki platform değişiklikleri hiçbir iş görmez ve paketten çıkarıldı (RR3-03). Böylece orkestratörün kendi Android işiyle (`MainActivity.kt`, `AndroidManifest.xml`) çakışma riski de kalktı.

| Yama | İçerik |
|---|---|
| `05-platform.patch` | `android/.../AndroidManifest.xml`: `com.google.firebase.messaging.default_notification_icon` meta-data'sı; `android/.../MainActivity.kt`: `peace_reminder` bildirim kanalını oluşturan `createPeaceReminderChannel()` (2 import + 1 çağrı + 1 yöntem); yeni `android/app/src/main/res/drawable/ic_stat_peace.xml` (beyaz ampul simgesi); `ios/Runner/Info.plist`: `UIBackgroundModes = [remote-notification]` |
| `06-gitignore.patch` | `.gitignore`: push sırları için 6 desen (`*.p8`, `fcm*.local.json`, `google-services.json`, `GoogleService-Info.plist`, `*service-account*.json`, `*firebase-adminsdk*.json`) ve yorum satırı |

## Firebase / bildirim kanalı ileride istenirse

Bu yamalar, `../../arsiv/` altındaki Firebase istemci dosyalarıyla ve `../../arsiv/SPL-dosya-ayrimi.txt` dosyasındaki ayrımla **birlikte** düşünülmelidir (paketler, `AppDelegate.swift` / `Runner-Bridging-Header.h` değişiklikleri, fabrika ve testin Firebase'li sürümleri orada). Hesap/anahtar adımları: `../../PUSH_KURULUM_ARSIV.md`.

* Yamalar 2026-10-02 01:06 tarihli ağaç anlık görüntüsüne göre üretildi (G1 turunda gerçek ağaçta `git apply --check` geçti), ancak gerçek ağaç hareketlidir ve `MainActivity.kt` / `AndroidManifest.xml` orkestratörün Android işiyle ortaktır. Uygulamadan önce deneyin:
  `git -c core.autocrlf=false apply --ignore-whitespace --check yamalar/arsiv/05-platform.patch`
  Reddedilirse eklenen küçük parçaları elle birleştirin (`05-platform.patch` içinde okunabilir).
* `.gitignore`, `Info.plist` CRLF'dir; yama LF'dir. Uyguladıktan sonra bu iki dosyanın satır sonunu yeniden CRLF yapın (`sed -i 's/\r$//; s/$/\r/' <dosya>`).
* Bildirim kanalı ve simge tek başına işe yaramaz: gerçek push için Firebase paketleri, hesap ve (iOS için) APNs anahtarı da gerekir.
