# Biyometrik ilk kullanım istemi (geri yüklemede) ve kalıcı oturum (WP-BIO2)

> Tarih: 2026-10-03 · Dal: `bio2` (temel: dev master `5ae9dc7`) · Kapsam: yalnız durum katmanı
> (`lib/services/automation_state.dart`) + testler + bu belge. Arayüz (`DashboardPage._maybePromptBiometrics`,
> `BiometricPromptDialog`), güvenli depo anahtarları, REST biçimi ve sunucu **değişmedi**.
> **DOĞRULANMADI (gerçek cihaz):** davranış yalnız birim/widget testleriyle (sahte depo, sahte biyometrik, sahte
> bulut) doğrulandı; gerçek Keystore/Keychain, gerçek `local_auth` istemi ve gerçek ağ kesintisi cihazda denenmedi.

Kullanıcı isteği: *"Oturum geri yüklenirken parmak izi isteğinin bir kez sunulmasını ekle. İlk kullanımda. Bir de
bir kere girince artık otomatik girsin, insanların işini zorlaştırmayalım."*

## 1. İlk kullanım istemi, oturum geri yüklenirken de (A)

Eskiden "Biyometrik kullanılsın mı?" istemi yalnız **girişten** sonra (`_handleAuthSuccess`) kuruluyordu; uygulama
kapatılıp açıldığında (saklı oturum, giriş formu yok) istem hiç çıkmıyordu. Artık `_initInner` (soğuk açılış) aynı
kararı verir ve pano açılmadan önce `shouldPromptBiometrics` hazırdır; `DashboardPage` istemi ilk karede, rota en
üstteyken açar (mevcut kapı, değişmedi).

| Koşul (hepsi) | Not |
|---|---|
| saklı **kullanıcı** oturumu var (`hasTokens`, servis PIN oturumu değil) | servis oturumunda istem yok |
| biyometrik tercih okunabildi ve **kapalı** | tercih okunamazsa kilit AÇIK varsayılır (fail-closed, mevcut) → istem yok |
| cihaz destekliyor (`_isBiometricSupported`) | sonda zaman aşımı "desteklenmiyor" sayılır → istem yok |
| "istem gösterildi" kaydı okunabildi ve `true` değil | kayıt okunamazsa istem yok (fail-safe); `storageError` yazılmaz |

* **Tek sefer:** "Daha Sonra" (`dismissBiometricPrompt`) ve "Evet, Etkinleştir" (`enableBiometricWithVerification`)
  kaydı `true` yazar; sonraki açılışlarda istem çıkmaz. Programatik kapanış (çıkış, kilit, derin bağlantı) karar
  değildir, kayıt yazılmaz (mevcut kural).
* **Kilit açıkken istem gerekmez:** biyometrik etkinse açılışta kilit ekranı gelir; kilit açılınca istem YOK ve kayıt
  hiç okunmaz.
* **Okuma maliyeti:** "istem gösterildi" kaydı beş oturum okuması bittikten sonra, biyometrik destek sondasıyla
  **eşzamanlı** okunur (takılmada süreler toplanmaz). Oturumsuz açılışta, servis oturumunda ve kilit açıkken bu okuma
  hiç yapılmaz (`startedReads == 5` sözleşmesi korunur). Reddeden kullanıcıda her açılış +1 güvenli depo okuması.
* `logout()` → `clearAll()` kaydı da siler: açık çıkış + yeniden girişte istem yeniden sorulur (bilinçli, değişmedi).

## 2. Kalıcı oturum: "bir kere girince artık otomatik girsin" (B)

Saklı oturum, yenileme belirteci geçerli olduğu sürece her açılışta sessizce sürer. Giriş ekranına düşüren yollar
tek tek incelendi:

| Yol | Karar |
|---|---|
| `logout()` / "Şifre ile giriş" (kilit ekranı, onaylı) / `logoutAll` / parola değişimi | **kasıtlı, kalır** |
| Servis PIN oturumunun 2 saati doldu (`serviceSessionExpired`) | kalır (refresh yok, tasarım) |
| Sunucu yenilemeyi **kalıcı** reddetti (401; yeniden kullanım, iptal, süre) → `onSessionExpired` → `_handleSessionExpired` | kalır: yerel temizlik + "Oturumunuz sona erdi" |
| Yenilemede **ağ hatası / 5xx / 429 / bütçe aşımı** | oturum **korunur** (mevcut; artık testle sabit): önbellek varsa pano önbellekle, yoksa "evler yüklenemedi" + yeniden dene; belirteçler silinmez, olay yok |
| Açılışta erişim belirteci süresi dolmuş | mevcut: ilk 401'de tek-uçuş yenileme + tek yineleme (sessiz) |
| **Bozuk/eksik kullanıcı kaydı** + çözülemeyen erişim belirteci + **geçerli yenileme belirteci** | **DÜZELTİLDİ:** eskiden `_wipeStorageQuietly` ile oturum siliniyordu; artık silinmez, `_startSession` önce yeniler ve kullanıcıyı yenilenen JWT'den (`sub`, `role`) türetip kaydı onarır. Ağ hatasında kullanıcısız oturum kurulmaz (giriş ekranı) ama belirteçler kalır; sunucu reddinde oturum olayı. Yenileme belirteci de yoksa eski davranış (temizle) |
| Olaysız `refreshSession() == false` (üretim istemcisi üretmez) | **savunma eklendi:** açılış ekranında sonsuza dek "doğrulanıyor" yerine giriş ekranı; depo silinmez |
| Depo okuma hatası / zaman aşımı | mevcut: giriş ekranı + `storageError`, belirteçler silinmez (sonraki açılış dener) |
| Biyometrik kilit (etkinse açılışta ve ≥ 30 sn arka plandan dönüşte) | güvenlik özelliği, **korunur**; etkin değilse hiç kilit yok (doğrulandı) |

**Rotasyon (B-5):** sunucu her yenilemede yeni yenileme belirteci verir; istemci bellekte ve `onTokenRefreshed` ile
depoda saklar (mevcut). Yazım sırası değişti: **önce yeni yenileme belirteci, sonra erişim belirteci.** Gerekçe: iki
yazım arasında uygulama ölürse eskiden "eski yenileme + yeni erişim" kalır, ilk yenileme sunucuda *yeniden
kullanım* sayılır ve tüm oturum ailesi iptal edilirdi (zorla çıkış). Ters artık ("yeni yenileme + eski erişim")
zararsızdır: ilk 401 sessizce yeniler.

**Sunucu gözlemi (salt okunur, değişiklik yok):** `jwt_config.js` access 15 dk, refresh 30 gün (üretimde override
yok); `auth_service.js` `refreshToken` → `_issueSession` her yenilemede **yeni satır, `expires_at = şimdi + 30 gün`**
→ **kaydırmalı** pencere: en az 30 günde bir açılan uygulama hiç giriş istemez; 30 gün hiç açılmazsa giriş gerekir.
Kullanılmış belirtecin tekrar gelmesi aileyi iptal eder (`reuse_detected`). 30 gün bu ürün için yeterli görünüyor;
uzatmak gerekirse yalnız `REFRESH_TOKEN_TTL_SEC` varsayılanı (sunucu) değişir, istemci değişmez.

Ürün kabulü (kullanıcı): oturum kaydı kalıcıysa ve biyometrik kilit kapalıysa uygulama her açılışta doğrudan panoya
girer.

## 3. Sınırlar / riskler

* `_tokenPersistLimit` (3 sn): yenilenen belirteçlerin depoya yazımı 3 sn'den uzun sürerse bellekteki belirteçlerle
  devam edilir, yazım arka planda sürer; uygulama o pencerede ölürse eski yenileme belirteci kalır → sunucu
  "yeniden kullanım" → zorla çıkış (nadir; yazım sırası değişikliği pencereyi küçültür ama kapatmaz).
* Yenilemede 404/405/400/403 de kalıcı red sayılır (mevcut `_doRefresh`; yanlış sunucu adresi/proxy durumunda da
  çıkış). Testler bu sözleşmeye dayanır; değiştirilmedi.
* JWT'den türetilen kullanıcı kaydında e-posta/ad boştur (sunucuda profil ucu yok); normal girişte kayıt tam yazılır.
* Gerçek cihazda sınanmadı (bkz. üst not): özellikle Android `resetOnError` ile Keystore sıfırlanması (tüm kayıt
  gider → giriş gerekir) ve iOS `first_unlock_this_device` davranışı.

## 4. Testler

* `test/services/state_restore_biometric_prompt_test.dart` (13): (a) istem, karar ilk bildirimden önce, "Daha
  Sonra"/"Etkinleştir" tek sefer; (b) kayıt `true`; (c) kilit var/istem yok; (c2) tercih okunamadı; (d) servis
  oturumu; (e) kayıt okunamadı; (e2) desteklenmiyor; (e3) sonda zaman aşımı; oturumsuz açılış; geri yükleme sürerken
  çıkış.
* `test/services/state_persistent_session_test.dart` (16): (f) ağ hatası/5xx → oturum korunur, önbellek, yeniden
  deneme; (g) 401 → çıkış; olaysız `false`; bozuk kayıt + refresh (başarı/ağ/red/refresh yok/kilit/JWT); rotasyon
  yazım sırası.
* `test/ui/biometric_prompt_restore_test.dart` (5): AuthGate + DashboardPage gerçek rotada istem, "Daha Sonra",
  "Etkinleştir" → sonraki açılış kilit, biyometrik açık → istem yok, servis oturumu, programatik kapanış.
* Mevcut testler değiştirilmedi.
