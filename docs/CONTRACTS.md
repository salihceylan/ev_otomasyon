# Ev Otomasyonu — Bileşenler Arası Sözleşmeler

> Backend (`server/`), firmware (`ev_otomasyon_servis_yazilimi/waveshare_s3_demo/`) ve Flutter uygulaması (`lib/`)
> aynı anda değiştirildiği için bu belge **tek doğruluk kaynağıdır**. Bir ajan/geliştirici bu belgeyle çelişen bir
> karar vermek zorunda kalırsa kodu değil önce bu belgeyi günceller ve bunu raporunda belirtir.
>
> Denetimde bulunan "uygulama bir şey yolluyor, firmware başka şey bekliyor" sınıfı hataların kaynağı sözleşmenin
> yazılı olmamasıydı. Bu belge o boşluğu kapatır.

## 0. Genel kurallar

| Konu | Kural |
|---|---|
| Ev kimliği (`home_id`) | **UUID string.** REST yolunda ve JSON'da hep string. Uygulamada `int` ev kimliği YOKTUR. |
| Kullanıcı kimliği | UUID string. |
| Cihaz kimliği (`device_uuid`) | `AHBU-...` biçiminde string (büyük harf, `^AHBU-[A-Z0-9-]{3,32}$`). |
| Röle / panjur numaraları | **Tüm dış arayüzlerde 1 tabanlı** (MQTT, HTTP, REST, UI). Yalnızca firmware iç dizileri 0 tabanlıdır ve sınırda dönüşür. |
| Panjur "pair" | 1 tabanlı panjur numarası. `pair N` = röle `2N-1` (YUKARI) ve `2N` (AŞAĞI). |
| Panjur konumu | `0..100` tamsayı. `0` = tam kapalı, `100` = tam açık. |
| Zaman | Sunucu → istemci: ISO-8601 UTC (`...Z`). İstemci gösterirken `toLocal()` kullanır. |
| Saat dilimi | Zamanlı kurallar `homes.timezone` (IANA, varsayılan `Europe/Istanbul`) içinde değerlendirilir. |
| Gün indeksi | `days_of_week`: `0=Pazar … 6=Cumartesi`, benzersiz tamsayılar. |
| JSON alan adları | **snake_case.** Sunucu geçiş dönemi için camelCase'i de kabul eder, yanıtlarda hep snake_case üretir. |
| Gizli değerler | Loglara, hata mesajlarına, `debugPrint`'e **yazılmaz** (PIN, OTP, token, parola, local key, QR içeriği). |
| Rastgelelik | Güvenlik amaçlı her değer `crypto.randomInt/randomBytes` (Node) veya `esp_random()` (firmware) ile üretilir. `Math.random` yasak. |

## 1. REST sözleşmesi

### 1.1 Yanıt ve hata biçimi

```json
{ "success": true,  "message": "…", "data": { } }
{ "success": false, "message": "Kullanıcıya gösterilebilir Türkçe mesaj", "code": "MAKINE_KODU" }
```

5xx hatalarında ham iç mesaj (SQL, constraint adı, yığın) **istemciye dönmez**; sunucu log'a yazar, istemciye genel mesaj verir.

| HTTP | `code` | Anlamı | İstemci davranışı |
|---|---|---|---|
| 400 | `VALIDATION` | Girdi geçersiz | Alan hatası göster |
| 401 | `TOKEN_EXPIRED` | Access token süresi doldu | **Yalnızca 401'de** refresh dene (tek-uçuş) |
| 401 | `INVALID_TOKEN` | Token geçersiz/iptal | Tek-uçuş refresh **bir kez** denenir (ör. `JWT_SECRET` değişimi sonrası kurtarma); refresh reddedilirse oturumu kapat, giriş ekranı. `token_version` artışı / dondurma / silme refresh ailesini de iptal ettiğinden sonuç oturum sonudur (UYELIK-06) |
| 401 | `SERVICE_SESSION_EXPIRED` | 2 saatlik servis oturumu bitti | Servis oturumunu kapat |
| 403 | `FORBIDDEN` | Yetki yok | Refresh DENEME; "yetkiniz yok" göster |
| 403 | `GUEST_EXPIRED` | Misafir süresi doldu | Ev erişimini kapat, ev listesini yenile, MQTT'yi kes |
| 404 | `NOT_FOUND` | Kayıt yok | |
| 409 | `CONFLICT` | Zaten sahiplenilmiş vb. (`PUT …/endpoints/:id`'de iki anlam, gövdedeki `reason` ile ayrılır: `TYPE_CHANGED` yerleşim çakışması, `NOT_APPLIED` pano süreyi uygulamadı, §1.5) | |
| 409 | `DEVICE_OFFLINE` | Cihaz çevrimdışı, komut iletilmedi | Anında rollback + "cihaz çevrimdışı" |
| 423 | `PIN_LOCKED` | PIN deneme kilidi (`retry_after` sn) | Kalan süreyi göster |
| 429 | `RATE_LIMITED` | Hız sınırı (`Retry-After` başlığı) | Bekleme göster |
| 502 | `BROKER_UNAVAILABLE` | MQTT broker'a yayın yapılamadı | Hata göster, rollback |

Ek hata kodları (A paketi gerçekleşmesi, 2026-10-01):

| HTTP | `code` | Anlamı |
|---|---|---|
| 401 | `INVALID_CREDENTIALS` | E-posta/parola hatalı (kullanıcı varlığı sızdırılmaz; genel mesaj) |
| 403 | `ACCOUNT_DISABLED` | Hesap dondurulmuş |
| 403 | `ACCOUNT_PENDING` | Hesap etkinleştirme (davet) bekliyor |
| 403 | `REAUTH_REQUIRED` | Hassas işlem için mevcut parola ile yeniden doğrulama gerekli |
| 405 | `METHOD_NOT_ALLOWED` | |
| 410 | `GONE` | Kod/bağlantı süresi doldu veya zaten kullanıldı |
| 413 | `PAYLOAD_TOO_LARGE` | Gövde 256 KB sınırını aştı |
| 500 | `INTERNAL` | Beklenmeyen sunucu hatası (ayrıntı istemciye dönmez) |
| 503 | `DELIVERY_FAILED` | E-posta/SMS gönderilemedi (sağlayıcı yok/başarısız) |
| 503 | `SERVICE_UNAVAILABLE` | İlgili özellik yapılandırılmamış (ör. Google/Apple yapılandırması yok) |

**403 hiçbir zaman refresh tetiklemez.** Aynı istek 401'de en fazla bir kez yeniden denenir.

### 1.1b Kimlik/oturum uçlarının gerçekleşmiş davranışı (istemci için)

- **Sihirli bağlantı** `…#token=<opak>` biçimindedir (token URL parçasında; sunucu loglarına/proxy'ye düşmez). İstemci token'ı parçadan okuyup
  `POST /auth/magic-login` ile gönderir; **GET artık `405`**. Token tek kullanımlık ve kısa ömürlüdür.
- Yeni uçlar: `POST /auth/change-password` (mevcut parola gerekli), `POST /auth/logout-all` (tüm cihazlardaki oturumlar).
- `users.must_change_password` → giriş yanıtında `must_change_password: true` ise istemci **parola değiştirme ekranına** zorlar (ör. teknisyenin açtığı müşteri hesabı).
- OTP/sıfırlama yanıtlarında `resend_after` (sn, yeniden gönderme bekleme süresi) ve `remaining_attempts` bulunur; istemci bunları gösterir ve süre dolmadan yeniden gönderimi kapatır.
- `GET /homes` her ev için ek olarak `mqtt_topic_id`, `access_state` (`active` | `expired` | `not_started`; sunucu gerçekleşmesi, istemci hepsini tanır) ve (misafirse) `valid_until` döner.
- Servis personeli kullanıcı oluştururken **parola veremez**; hesap `pending_invite` olur, etkinleştirme e-postası gider. Yeni: `POST /admin/users/:id/send-reset`.
  Başka bir süper kullanıcının parolasını değiştirmek için `current_password` zorunludur (`REAUTH_REQUIRED`).
- Servis oturumu yönetimi (ev sahibi): `GET /homes/:id/service-sessions`, `POST /homes/:id/service-access/revoke`. Servis PIN listesi **PIN değerini göstermez**
  (PIN yalnızca üretim anında bir kez döner).
- Envanter kaydı (`/admin/inventory/register`): süper kullanıcı JWT'si veya `ADMIN_API_KEY` (≥ 32 karakter) ile; yanıt `local_key` ve PIN'li `qr_claim_url` değerini **yalnızca bir kez** döner.
- Servis oturumu token'ı yalnızca **kendi evine** atıf yapan isteklerde (yol segmenti, gövde veya sorguda `home_id`) kabul edilir; ayrıca `/homes`, `/auth/me`, `/auth/logout` serbesttir.
- Devir kodu yalnızca özet olarak saklandığı için `transfer-status` kodu **tekrar göstermez** (üretim anında bir kez döner).
- Commissioning uçları (`/commissioning`, `/commissioning-status`) `service_routes`'tan kaldırıldı; B paketinin `home_device_routes`'u sağlar.

Akış denetimi düzeltmeleri (2026-10-04; ayrıntı `docs/superpowers/specs/2026-10-04-akis-denetimi-duzeltmeleri.md`):

- **Giriş yetenekleri (UYELIK-04):** `GET /auth/capabilities` (ve `/api/auth/capabilities`) kimliksizdir; IP başına 120/15 dk (`429 RATE_LIMITED` + `Retry-After`), `Cache-Control: no-store`. Yanıt `data: {sms_otp, google, apple}` (yalnız boolean): `sms_otp` = SMS göndericisi bağlı VEYA debug OTP izinli (`ALLOW_DEBUG_OTP=true` ve `NODE_ENV !== 'production'`); `google` / `apple` = `GOOGLE_CLIENT_IDS` / `APPLE_CLIENT_IDS` dolu. Değerler ilgili uçların `503` koşullarıyla aynı kaynaktandır (`false` iken o uç `503` verir).
  İstemci giriş ekranı açılışında sorar, YALNIZ başarılı yanıtı uygulama oturumu boyunca bellekte tutar (eşzamanlı çağrılar tek istek); `404` (eski sunucu) / hata önbelleğe alınmaz ve "yetenek yok" sayılır (fail-closed). "Telefon Numarası ile Şifresiz Giriş (SMS)" yalnız `sms_otp === true` iken görünür (üretimde SMS sağlayıcı bağlı olmadığından gizli; QA'da debug OTP açık olduğundan görünür). Google/Apple düğmeleri bu uca bağlı DEĞİLDİR.
- **Yer tutucu e-posta (UYELIK-07):** kullanıcı nesnesinde (giriş, kayıt, `/auth/me`, sosyal giriş, OTP doğrulama, sıfırlama, sihirli bağlantı yanıtları) teslim edilemeyen yer tutucu (`phone_<no>@ahbu.local`, `apple.<özet>@users.noreply.invalid`, `deleted+<id>@deleted.invalid`; büyük/küçük harf duyarsız) `email: null` döner. DB satırı ve içerdeki kullanım (telefonla eşleştirme, Apple `sub` ile yeniden giriş) değişmez; yönetici uçları ham değeri gösterir, `GET /homes/:id/members` henüz yer tutucuyu döndürür. İstemci `null`'u ve yer tutucuları boş e-posta sayar (`UserModel`, `HomeMember`); profil "E-Posta: Belirtilmedi" gösterir, teknik adres hiçbir yerde görünmez.
- **Şifremi unuttum / telefon OTP (UYELIK-08, UYELIK-K1, UYELIK-01):** yer tutucu e-postalı hesapta `POST /auth/forgot-password` kayıtsız kimlikle AYNI genel `200`'ü döner; kod gönderilmez, kullanıcıya bağlı talep açılmaz (60 sn / saatte 5 sınırı kayıtsız kimlikteki gibi işler). Önceki geçerli sıfırlama kodu/bağlantısı ve telefon OTP kodu YALNIZ yeni kod başarıyla teslim edilince (geliştirmede debug ile de) geçersizleşir; teslim başarısızsa yalnız yeni kod iptal edilir, yanıt `503 DELIVERY_FAILED` olur ve eldeki eski kod geçerli kalır (`INVALID_RECIPIENT`: yeni kayıt iptal, genel `200`).
  İstemci: SMS kod penceresinde "Tekrar Kod İste" başarısız olursa (`429`, `503`, ağ) kod adımı ve "Giriş Yap" korunur, yalnız ileti gösterilir (kod alanı kırmızı çizilmez; `429`'da `resend_after` geri sayılır). "Şifremi Unuttum"da kimlik biçimden telefon numarasıysa sunucu yanıtından BAĞIMSIZ ipucu gösterilir: "Yalnızca telefonla açılmış hesapların şifresi ve e-postası yoktur; bu hesaplara sıfırlama kodu gönderilemez." (hesap varlığı sızmaz).
- **Bilinçli takas (UYELIK-09):** `forgot-password` teslim edilebilir e-postalı var olan hesapta SMTP gönderimini bekler; SMTP geçici arızasında var olan hesap `503 DELIVERY_FAILED`, olmayan (ya da yer tutucu e-postalı) hesap anında `200` alır. Yanıt süresi ve kodu bu yüzden hesap varlığını açığa çıkarabilir (dürüst teslim hatası tasarımının bedeli); IP başına 10/saat ve kimlik başına 60 sn / saatte 5 sınırı numaralandırmayı yavaşlatır, engellemez.
- **Giriş kilidi (UYELIK-10):** `POST /auth/login` başarısız parola sayacı iki katmanlıdır (süreç belleği, 15 dk pencere): (kimlik | istemci IP) başına 10 ve kimlik başına toplam 50 hatalı deneme. Yalnız `401`'de ikisi birden artar, başarılı girişte ikisi de sıfırlanır; herhangi biri aşılınca `429 RATE_LIMITED` (`Retry-After` = engelleyenlerin en büyüğü). Üçüncü kişi kendi ağından hesabı kilitleyemez: "IP" sayaç anahtarında IPv4'te tek adres, IPv6'da adresin **/64 öneki**dir (fx2 S-5 / M1-01; `rate_limit.limitKey`; `::ffff:` eşlemesi IPv4 sayılır). Aynı indirgeme IP başına auth sınırlayıcılarının hepsinde (login, register, refresh, logout, forgot, reset, magic, otp-send/verify, social, service-login, capabilities) geçerlidir; denetim kayıtlarındaki `ip` tam adrestir. Bilinen takas: ≥ 5 ayrı ağı (IPv6'da ≥ 5 /64) olan dağıtık saldırgan 50 tavanıyla kimliği 15 dk kilitleyebilir ve kimlik başına deneme bütçesi tek katmanlı dönemin 10'u yerine 50'dir (D9). Sayaç anahtarı kimliğin ham kopyasını taşımaz: `sha256(normalize kimlik)` (64 hex; M1-02), uzun kimlik reddedilmez, sayılır. Genel giriş sınırı IP başına 30/15 dk sürer; istemci IP'si `TRUST_PROXY` ile türetilir (yanlış ayarda herkes vekil IP'sini paylaşır). Sayaçlar yeniden başlatmada sıfırlanır.
- **Şifre sıfırlama bağlantısı (UYELIK-05, UYELIK-K2):** `…/reset-password#token=` oturum AÇIKKEN açılırsa istemci magic-login ile aynı onayı ister ("Bu cihazda şu anda başka bir hesap açık. Bağlantıyla şifre yenilerseniz mevcut oturum kapanır ve bağlantının hesabı açılır." → "Bu Bağlantıyla Devam Et" / "Vazgeç"); onaysız form gösterilmez, istek atılmaz. İki derin bağlantı kolu da (magic-login, reset-password) açılış / biyometrik kilit sürerken bekler: istek atılmaz, kilit atlatılmaz. Sıfırlama yanıtı oturum taşımazsa açık oturum sürer ve başarı iletisi gösterilir.

**Bilinen sınır (Faz 2):** daire devrinde **cihaz** MQTT kimliği yenilenmez (uygulama kimlikleri, servis PIN/oturumları ve ev verisi temizlenir). Yenileme,
kimliği panoya ileten yetkili bir kanal ister (`sys` konusunda iki aşamalı `set_mqtt_credential` döndürmesi veya servis ziyareti). Acil sıfırlama ve pano değişiminde cihaz kimliği zaten yenilenir.

### 1.2 Kimlik doğrulama

- Access token: JWT (HS256), **15 dk**. Claim'ler: `sub`, `role` (global), `tv` (token_version), `iat`, `exp`, `iss`.
- Refresh token: opak rastgele değer, DB'de **yalnızca SHA-256 özeti**; her kullanımda **döner (rotation)**; kullanılmış token ikinci kez gelirse
  o kullanıcının tüm refresh ailesi iptal edilir. Süre 30 gün (365 değil).
- `JWT_SECRET` yoksa veya 32 karakterden kısaysa sunucu **başlamaz** (varsayılan değer yok).
- Şifre değişimi / sıfırlama / hesap dondurma (ayrıca yöneticinin parola ataması ve rol değişimi, `POST /auth/logout-all`, sosyal kimlik bağlamadaki ön-hesap savunması) → ilgili kullanıcının refresh token'ları iptal edilir, `token_version` artar ve kullanıcının TÜM evlerdeki uygulama MQTT kimlikleri (`mqtt_credentials` `kind='app'`) AYNI transaction'da silinir (UYELIK-02). Açık MQTT bağlantıları COMMIT sonrası EMQX REST ile atılır (en iyi çaba: hata yanıtı bozmaz, yanıt en çok 5 sn bekler, atma arka planda sürer; `EMQX_API_*` yoksa atlanır, uyarı loglanır).
  Parolayı değiştiren cihazın MQTT bağlantısı da atılır: istemci yanıtla gelen yeni belirteçle `POST /homes/:id/mqtt-credentials`'tan taze kimlik alıp kendiliğinden yeniden bağlanır; bu çağrılar sürerken (parola değişimi / sıfırlama, tüm cihazlardan çıkış) kimlik isteğini yanıta kadar bekletir (eski belirteçle istemez). Diğer cihazın canlı akışı kesilir (kick yapılandırılmışsa hemen), kimlik isteği `401` alır ve oturumu sona erer.
- Ev devri hesap düzeyinde iptal YAPMAZ (UYELIK-11): yalnız o eve ait üyelik, uygulama MQTT kimlikleri ve servis PIN/oturumları iptal edilir (§1.1b "Bilinen sınır"; Home Admin devri §1.5c ile aynı); JWT/refresh token'a ve `token_version`'a dokunulmaz. Eski sahip sonraki istekte o ev için `403` alır, diğer evlerdeki oturumu sürer.
- Şifre politikası: en az 10 karakter. bcrypt cost 12.
- Google/Apple girişi: **yalnızca** doğrulanmış kimlik jetonu ile (imza + `aud` + `iss` + `exp` + `email_verified`). Jeton yoksa/geçersizse giriş reddedilir; istemciden gelen `email` alanına güvenilmez.

### 1.3 Servis oturumu (PIN ile giriş)

`POST /api/v1/auth/service-login` gövde: `{ "service_pin": "123456", "technician_name": "Ad Soyad" }`

- PIN ev sahibi tarafından **bir ev için** üretilir (`POST /api/v1/homes/:homeId/service-token`, yalnızca `owner`). Yeni PIN eskisini iptal eder.
- PIN 6 hane, `crypto.randomInt`, DB'de özet olarak saklanır, **tek kullanımlıktır** (`UPDATE … WHERE used=false AND expires_at>now() RETURNING`), 2 saat geçerlidir.
- Yanıt: `{ "access_token", "expires_in": 7200, "scope": "home_service", "home": { "id", "name" } }` — **refresh token yok**.
- Token `role: "service_session"`, `home_id` ve `sid` taşır. Bu token **yalnızca o evin** uçlarına girer; global rol değildir, kullanıcı satırı oluşturmaz.
- IP başına 10 deneme / 15 dk; aşımında `429 RATE_LIMITED`.
- Kalıcı servis personeli (`users.role='service_user'`) e-posta+parola ile girer; yalnızca `home_users` kaydı (rol `service_user`) olan evlere erişir.

### 1.4 Rol / yetki matrisi (sunucu tarafında ZORUNLU)

Rol kaynakları: global `users.role` ∈ {`user`,`service_user`,`super_user`}; ev rolü `home_users.role` ∈ {`owner`,`resident`,`guest`,`service_user`}; servis oturumu (`service_session`, tek ev).

| İşlem | super | staff* | service_session | owner | resident | guest(geçerli) |
|---|:-:|:-:|:-:|:-:|:-:|:-:|
| Durum görme (state/endpoint listesi) | ✔ | ✔ | ✔ | ✔ | ✔ | ✔ |
| Röle / panjur komutu | ✔ | ✔ | ✔ | ✔ | ✔ | ✔ |
| Toplu komut (`all_*`) | ✔ | ✔ | ✔ | ✔ | ✔ | ✖ |
| Çocuk kilidi / huzur bildirimi ayarı | ✔ | ✔ | ✔ | ✔ | ✔ | ✖ |
| Panjur kalibrasyonu, kanal adı/oda | ✔ | ✔ | ✔ | ✔ | ✖ | ✖ |
| Zamanlı kural oluştur/düzenle | ✔ | ✔ | ✖ | ✔ | ✔ | ✖ |
| Üye davet / çıkar | ✔ | ✖ | ✖ | ✔ | ✖ | ✖ |
| Daire devri | ✖ | ✖ | ✖ | ✔ | ✖ | ✖ |
| Servis PIN üret | ✖ | ✖ | ✖ | ✔ | ✖ | ✖ |
| Cihaz sahiplen (claim) | ✔ | ✔** | ✖ | ✔ | ✔ | ✖ |
| Devreye alma (commissioning) | ✔ | ✔ | ✔ | ✖ | ✖ | ✖ |
| Pano değişimi | ✔ | ✔ | ✔ | ✔ | ✖ | ✖ |
| Acil sıfırlama | ✔ | ✔*** | ✖ | ✖ | ✖ | ✖ |
| Envanter oluştur/sil/durum | ✔ | ✖ | ✖ | ✖ | ✖ | ✖ |
| Envanter listele | ✔ | ✔ (yalnız kendi stoku) | ✖ | ✖ | ✖ | ✖ |
| Yönetici hesapları (admin panel) | ✔ | ✖ | ✖ | ✖ | ✖ | ✖ |
| Güvenlik: vanayı kapat / sireni-fanı sustur (`actuator_close`) | ✔ | ✔ | ✔ | ✔ | ✔ | ✔ |
| Güvenlik: alarmı onayla / sustur (`safety_ack`) | ✔ | ✔ | ✔ | ✔ | ✔ | ✖ |
| Güvenlik: su vanasını aç, siren/fan/diğer aç (`actuator_control`) | ✔ | ✔ | ✔ | ✔ | ✔ | ✖ |
| Güvenlik: **gaz vanasını aç** | ✖ | ✖ | ✖ | ✖ | ✖ | ✖ |
| Güvenlik: bölge testi (`safety_test`), güvenlik yapılandırması (`safety_config`) | ✔ | ✔ | ✔ | ✔ | ✖ | ✖ |
| Güvenlik: hırsız alarmı kur / çöz (`safety_arm`, Faz 2) | ✖ | ✖ | ✖ | ✔ | ✔ | ✖ |

\* staff = `home_users` kaydı olan kalıcı servis personeli (yalnız o evler). \*\* `target_owner` ile yalnızca staff/super; müşteri OTP'si **zorunlu**.
\*\*\* Gerekçe ≥ 15 karakter + cihaz UUID'sinin yazarak teyidi + denetim kaydı (IP dahil). Servis personeli kendisini yeni sahip yapamaz.
Staff'in ev üyeliği claim/devirde 72 saatliğine verilir; istemci süper olmayan servis personeline acil sıfırlama formunda kapsam notu gösterir ("Servis personeli yalnız son 72 saat içinde kurduğu ya da devraldığı dairelerin panolarını sıfırlayabilir; diğer daireler için süper yöneticiye başvurun."); `403`'te aynı yönlendirme hata kutusunda görünür (servis paneli kartı ve konsol/çekmece diyaloğu; SERVIS-07).

Misafir (`guest`) için her istekte `valid_from <= now <= valid_until` doğrulanır; dışındaysa `403 GUEST_EXPIRED`.

Güvenlik satırları (WP-S4, tasarım `docs/superpowers/specs/2026-10-06-guvenlik-iklim-senaryo-mimarisi-design.md` §5.2.4, kararlar §7.2b-4/8): yetenek eylemcide **yöne** göre seçilir (`to` = `closed`/`off` → `actuator_close`; `open`/`on` → `actuator_control`; `server/src/utils/command_schema.js` `capabilityForCommand`). Misafir vanayı her durumda **kapatabilir**, açamaz, alarmı onaylayamaz ve **güvenlik push'u almaz**. Gaz vanası buluttan hiçbir rolle açılmaz (`409 GAS_LOCAL_ONLY`; yalnız yerinde `GAS_RESET` düğmesi ya da elle kurmalı vana).
**Hırsız alarmı (Faz 2, karar F2-3):** kurma/çözme yalnız ev sakinleri (owner, resident); servis rolleri (super/staff/servis oturumu) bir evin hırsız alarmını buluttan kuramaz/çözemez (gizlilik ve hırsızlık riski; kurulumda test LAN ya da seri CLI ile).

### 1.5 Uçlar (bu sürümde sabitlenen / yeni olanlar)

Tüm uçlar `/api/v1/...` altındadır (eski `/api/...` takma adı korunur).

| Uç | Not |
|---|---|
| `GET /auth/capabilities` | **Kimliksiz.** `data: {sms_otp, google, apple}` (boolean); IP başına 120/15 dk, `no-store`. Eski sunucuda `404` (istemci "yetenek yok" sayar). Ayrıntı §1.1b. |
| `GET /homes` | Her ev: `{ id, name, role, timezone, mqtt_topic_id }`. `role` = ev bazlı rol. |
| `POST /homes/:homeId/mqtt-credentials` | Üyelik + misafir süresi doğrulanır. Yanıt: `{ host, port, username, password, client_id, expires_at, topic_id }`. **Salt-okunur** (yalnızca `state`/`status` abonelik) kimlik; süre = `min(12 saat, misafir bitişi)`. İstemci süre dolmadan yeniler. |
| `POST /devices/:id/command` gövde `{ home_id, command }` | Üyelik + rol matrisi + şema doğrulaması. Yanıt `{ delivered, device_online, command_id }`. Çevrimdışıysa `409 DEVICE_OFFLINE`. **Buluttan tüm komutlar bu uçtan geçer; uygulama MQTT'ye doğrudan yayın yapmaz.** Toplu `all_lights_off` / `all_off` (DAIRE-01): evde `type='plug'` uç noktası VARSA toplu komut yayınlanmaz; "Hepsini Kapat" (§1.5b close-all) ile AYNI kuralla yalnız canlı anlık görüntüdeki AÇIK ışık röleleri için `{relay:N, state:false, id}` sırayla yayınlanır (16'lık gruplar arası 150 ms; çok panolu evde ortak numaralar atlanır). Yanıt `{ delivered:true, device_online:true, command_id: ilk komut \| null, command_ids[], no_change?:true (açık lamba yoktu, komut gönderilmedi), skipped_count? }`; bu yolda istemcinin `id`'si kullanılmaz; canlı anlık görüntü yoksa `409 DEVICE_OFFLINE`. Evde priz yoksa davranış aynıdır (tek toplu komut, istemci `id`'si korunur). |
| `GET /homes/:homeId/devices` | `[{ device_uuid, name, online, last_seen_at, firmware }]` |
| `GET /homes/:homeId/devices/:uuid/local-key` | owner/resident/staff/service_session. Yanıt `{ local_key }` (LAN doğrudan mod için). |
| `PUT /homes/:homeId/endpoints/:id` | `shutter_duration_sec` (1..300), `name`, `room`, `type` (yalnız `light` ↔ `plug`; uygulamada ekranı yok). Yetki: kalibrasyon satırı. Süre verilirse (DAIRE-03/K3) sunucu `set_runtime` yayınlar ve cihaz ONAYINI (canlı `state.last_id` = komut kimliği, §2.4) en çok 4 sn bekler; DB yalnız onaydan sonra yazılır, yanıt `delivered:true, command_id`. Onay yoksa (panjur hareket halinde / ölü zamanda ya da çift panoda yapılandırılmamış: firmware reddeder, `last_id` değişmez) `409 CONFLICT` + `reason:"NOT_APPLIED"` "Pano panjur süresini uygulamadı (panjur hareket halinde olabilir). Panjuru durdurup yeniden deneyin." ve DB DEĞİŞMEZ (aynı gövdedeki ad/oda da yazılmaz). Onaydan sonra kanal yerleşimi değişmişse (ya da tip yazımında satır artık `light/plug` değilse) `409 CONFLICT` + `reason:"TYPE_CHANGED"` "Kanal tipi değişti; listeyi yenileyin.". Çevrimdışı `409 DEVICE_OFFLINE`, broker yok / yayın hatası `502 BROKER_UNAVAILABLE`, onay bekleyici sınırı (1000) doluysa yayın yapılmadan `503 SERVICE_UNAVAILABLE`; istek en kötü ~9 sn sürer. İstemci iki `409`'u ayırır: `reason:"NOT_APPLIED"` (sunucu fx2 S-4'ten itibaren; eski sunucuda mesajdaki "uygulamadı/uygulanmadı") → yenilemez, yinelemez, başlık "Süre panoda uygulanmadı" + sunucu mesajı ("Tekrar dene" panjuru önce durdurur); `reason:"TYPE_CHANGED"` (ya da `reason` yok) yerleşim çakışması → listeyi yeniler ve BİR KEZ yineler. `reason` hata gövdesinin beyaz listeli ek alanıdır (`http_errors` `EXPOSED_EXTRA_KEYS`, `retry_after`/`remaining_attempts` ile aynı desen). |
| `POST /homes/:homeId/commissioning` | `{ device_uuid, checks: { relays:{ok,detail}, buttons:{…}, shutters:{…}, network:{…}, cloud:{…} }, notes }`. `tests_passed` **sunucuda** hesaplanır (zorunlu 5 kontrolün hepsi `ok`). |
| `POST /devices/claim` | `{ device_uuid, setup_pin, home_name?, target_owner?, otp_code? }`. `home_id` kabul edilmez. `target_owner` varsa OTP zorunlu ve yalnızca staff/super. Yanıt `{ home_id, home_name, device_uuid }`. |
| `POST /devices/emergency-reset` | `{ device_uuid, confirm_uid, reason, new_owner_identifier? }` (bkz. matris). Yanıt, yeni kurulum PIN'ini **bir kez** döner. Yerel anahtar (`local_key_publish` `published\|pending\|failed\|skipped`): §1.5b. |
| `GET/POST/PUT/DELETE /homes/:homeId/scheduled-rules` | Gövde snake_case: `{ channel, channel_type: "relay"\|"shutter", action, hour, minute, days_of_week, device_id?, label?, enabled }`; `channel` 1 tabanlı. |
| `PUT /me/push-tokens` gövde `{ token, platform, app_version? }` | Cihazın FCM/APNs belirtecini **oturumdaki kullanıcıya** bağlar (ev bağımsız: alıcılar gönderim anında `home_users`'tan hesaplanır). `token` 20–512 görünür ASCII (boşluk yok), `platform` `android`\|`ios`, `app_version` ≤ 32 karakter. Yanıt `200 {registered:true}`. Aynı belirteç başka kullanıcıya yeniden bağlanabilir (paylaşılan telefon). Kullanıcı başına en çok 10 etkin belirteç (fazlasının en eskisi silinir). **Servis oturumu `403 FORBIDDEN`.** Kullanıcı başına 20/dk (`429`). Hata: `400 VALIDATION`. `Cache-Control: no-store`. |
| `DELETE /me/push-tokens` gövde `{ token }` | Yalnızca **çağıranın kendi** belirtecini devre dışı bırakır; belirteç yoksa da `200 {registered:false}` (idempotent; varlığı sızmaz). Çıkışta çağrılır. Aynı kimlik/hız kuralları. |

Push belirteci uçları (`/me/push-tokens`) hem `/api/v1/me/push-tokens` hem eski `/api/me/push-tokens` altındadır (router yol öneki eklemez).

### 1.5b Cihaz / claim / sıfırlama uçlarının gerçekleşmiş şekilleri (B paketi)

- **Çocuk kilidi:** `POST /devices/child-lock {home_id, enabled}` → `{home_id, requested, delivered, device_online, command_id, offline_devices[], no_change?}`
  (yanıtta `child_lock_enabled` **YOKTUR**: gerçek durum cihazın `state.child_lock` bildirimiyle gelir; REST yalnız NİYETİ (`homes.child_lock_requested*`) kaydeder).
  `GET /devices/child-lock/:home_id` → `{child_lock_enabled, requested, requested_at, in_sync, devices[]}` (`no-store`). Ev başına hız sınırı 6/dk + 30/sa (yalnız geçerli+yetkili istekler sayılır); tüm panolar çevrimdışıysa `409 DEVICE_OFFLINE`.
- **Cihaz kimliği (`device_credential`)**: `{host, port, mqtt_server, mqtt_port, username, password, client_id, topic_id}` — parola **tek seferlik** gösterilir (24 karakter);
  `mqtt_server` **DNS adıdır** (= `MQTT_PUBLIC_HOST`), firmware `POST /api/mqtt/config`'e bunu yazar. `host`/`port` geriye uyum için aynı değerlerdir. `client_id` bilgilendiricidir (firmware gerçekte `ESP32S3_<MAC>` kullanır; broker yetkisi yalnız `username`'e dayanır).
  Yeni uç: `POST /homes/:homeId/devices/:uuid/mqtt-credential` (cihaz kimliğini yeniden üretir; tek seferlik parola; yalnız owner/staff/service_session/super).
- **Claim yanıtı:** `{home_id, home_name, device_uuid, device_credential, customer_account?, technician_access_expires_at?, warnings?}`; gövdede `home_id` **kabul edilmez**. Servis personeline claim/devirde **72 saatlik** `home_users(service_user)` üyeliği verilir; servis hesabı cihaz sahibi olamaz.
- **Acil sıfırlama yanıtı:** `UNCLAIMED` → `setup_pin` (tek sefer); `REASSIGNED` → `new_owner`, `device_credential`; ortak alanlar `local_key_publish` (`published|pending|failed|skipped`), `child_lock_reset` (`published|failed|skipped_offline|skipped`), `local_key` (yalnız `skipped|failed`), `warnings`, `partial` (yalnız gerçek uyarı varsa; `pending` tek başına uyarı/partial üretmez, fx2 S-1).
  REVOKED/SUSPENDED cihazı yalnız `super_user` sıfırlar.
  **Yerel anahtar (SERVIS-01/K1/K2, migration `032`):** her sıfırlama yeni anahtar üretir. Pano ŞU AN iletilebiliyorsa (`is_online` VE köprü broker'a bağlı) yeni anahtar commit ile geçerli olur ve `ev/{t}/sys set_local_key` ile iletilir → `published`; yayın başarısızsa telafi: geçerli anahtar eskisine, yeni anahtar bekleyene çekilir → `pending`. İletilemiyorsa (pano çevrimdışı ya da köprü kopuk) `devices.local_key_enc` ve envanter anahtarı DEĞİŞMEZ (panodaki gerçek anahtar; yerel anahtar ucu bunu verir, "Panoyu şimdi bağla" sihirbazı 6. adımda LAN'dan bununla bağlanıp yeni `device_credential`'ı yazar. **İstisna (M4-02):** yerel anahtar ucu `super_user`'a KAPALIDIR (rol matrisi `local_key`: STAFF, SESSION, OWNER, RESIDENT) ve süper yöneticinin yaptığı devir personele 72 saatlik üyelik VERMEZ (yalnız `service_user` aktöre verilir). Bu yüzden süperin yaptığı `REASSIGNED`'da "Panoyu şimdi bağla" süper hesabıyla 6. adımı geçemez; pano yeni sahibin uygulamasından alınan servis PIN'iyle (servis girişi) bağlanır. Devir tüm üyelikleri sildiği için süperin devrinden sonra evde personel üyeliği kalmaz; personel hesabıyla bağlama yalnız devri personelin kendisi yaptığında (72 saatlik kurulum penceresi içinde) mümkündür), yeni anahtar `devices.local_key_pending_enc`'de bekler → `pending`; köprü uzlaştırıcısı pano buluta bağlanınca iletir (aşağıda "Birikmiş sunucu işleri").
  `pending` iken yanıtta `local_key` YOKTUR ve bekleyen anahtar için `warnings`'e uyarı EKLENMEZ; `pending` tek başına `partial:true` yapmaz (fx2 S-1: bekleyen anahtar hata değildir, uzlaştırıcı otomatik iletir; istemci bilgi notunu `local_key_publish`'ten üretir). Başka gerçek uyarı (ör. çocuk kilidi, EMQX) varsa `partial` onlar yüzünden `true` olur. (fx2 öncesi sunucu "Yeni yerel anahtar şu an panoya iletilemedi (pano ya da bulut bağlantısı yok). …" uyarısını ekleyip `partial:true` dönüyordu.) `local_key` yalnız `skipped` (ev/konu ya da cihaz kaydı yok: anahtar hemen değişir) ve `failed` (yayın + telafi başarısız; telafi CAS'ı arada başka yazım görürse hiçbir şey değiştirmez) durumlarında bir kez döner; ağ üzerinden yazılamaz. `failed` uyarısı (fx2 S-3): "Yeni yerel anahtar panoya iletilemedi; anahtar yalnız bu yanıtta gösterilir. Panoya seri konsoldan RESETKEY ve ardından FACTORYINIT ile (fabrika aracı) yazılabilir." (istemci yönergesiyle aynı; eski "yerinde elle yazılmalıdır" metni kaldırıldı).
  **Çocuk kilidi (M1-03):** komut ŞU AN gönderilebiliyorsa (pano `is_online` VE köprü bağlı) `set_child_lock false` yayınlanır, DB durumu sıfırlanır → `published`. Gönderilemiyorsa `skipped_offline` ve uyarı NEDENE göredir: köprü kopuksa "Bulut bağlantısı yok; …", pano çevrimdışıysa "Pano çevrimdışı; …" + "çocuk kilidi sıfırlama komutu gönderilemedi." Devirde (`REASSIGNED`) bu durumda `homes.child_lock_requested=FALSE, child_lock_requested_at=NOW()` NİYETİ yazılır ve cihazın bildirdiği `child_lock_enabled` KORUNUR (uzlaştırıcı niyeti bildirilen durumla karşılaştırır; durum FALSE'a çekilseydi niyet hemen "karşılandı" sayılıp silinirdi). Pano bağlanıp kilitli bildirirse uzlaştırıcı `set_child_lock false` gönderir; uyarı sonu "Kilit, pano bağlandığında otomatik kaldırılacak." Stoğa dönüşte (`UNCLAIMED`) ev bağı kalmadığı için niyet yazılmaz, DB durumu sıfırlanır; uyarı sonu "Pano yerelde kilitli kalmış olabilir." `skipped_offline` artık yalnız `child_lock_reset` içindir (eski sunucu `skipped_offline` + `local_key` dönebilir; istemci aynı yönergeyle gösterir). REASSIGNED'da eski cihaz MQTT kimliği yine silinir; çevrimdışı pano yeni kimliği sihirbazla (mevcut anahtarla, LAN'dan) alır. İstemci `pending`'i bilgi notu olarak gösterir; uygulanamaz "panoya yerinde yazılmalıdır" yönergesi kaldırıldı.
- **Pano değişimi yanıtı:** `device_credential`, `shutter_runtimes`, `runtime_sync`, `child_lock` (`pending_device_online` olabilir: cihaz çevrimiçi olunca yeniden uygulanır).
- **Kısmi başarısızlık** (EMQX kick yapılandırılmamış, çocuk kilidi komutu gönderilemedi, yerel anahtar `failed` vb.; bekleyen anahtar `pending` DEĞİL): **HTTP 200 + `warnings` + `partial: true`** (207 değil; Flutter yalnız 200'ü başarı sayıyor).
- **Commissioning:** `checks` = 5 zorunlu kontrol (`relays, buttons, shutters, network, cloud`), `tests_passed` **sunucuda** hesaplanır.
- **Endpoint JSON takma adları:** `channel`, `endpoint_type`, `shutter_position`, `online`.
- **Hata gövdesi ek alanları:** `retry_after`, `remaining_attempts`, `device_online`, `offline_devices`.
- Huzur/diagnostic uçları `child_lock` yetenek kümesindedir (misafir yok). `command_id` = 12 karakter rastgele `[A-Za-z0-9_-]`; istemcinin verdiği id de `^[A-Za-z0-9._:-]{1,24}$` olmalıdır (aksi `400`).
- **Davranış (sunucu, zamanlayıcı):** her ev için, `homes.peace_notification_time` (HH:MM; boş/bozuk ⇒ `23:30`) saatinde ve `homes.timezone`
  yerel saatiyle, her yerel gece **en çok bir** bildirim kaydı (`peace_notification_logs`, `UNIQUE (home_id, local_date)`) ve en çok bir push.
  Pencere: hedef saat + `PEACE_CATCHUP_MIN` (varsayılan 60 dk; yeniden başlatma/kesinti telafisi). `peace_notification_enabled = FALSE` ise hiç değerlendirilmez.
  Açık = canlı cihazlarda `type='light' AND current_state` ya da panjur çifti `current_position >= 1`.
  **Canlı** = `devices.is_online IS TRUE` **ve** `last_seen_at` son **120 sn** içinde (veritabanı saatiyle). Bayat veriyle **asla** bildirilmez
  (`skipped_offline`, pencere bitene kadar 1-1-2-2-5 dk aralıkla yeniden denenir). Evin yalnız bir kısmı canlıysa ve canlı kısımda açık yoksa
  "temiz" yazılmaz (çevrimdışı panonun durumu bilinmiyor). Alıcılar: **yalnızca `owner` ve `resident`** (misafir/servis/staff yok), kullanıcı başına en çok 3, ev başına en çok 100 belirteç.
  Değerlendirici **MQTT'ye yayın yapmaz** ve **`endpoints` tablosuna yazmaz** (komutlar yalnızca REST'ten gider).
- **`peace_notification_logs.status` değerleri** (CHECK): `manual` (kullanıcı tıklama günlüğü, `local_date` NULL), `claimed`, `sending`,
  `clear` (açık bir şey yok), `sent`, `no_recipients` (push yok → uygulama içi yedek), `skipped_offline`, `skipped_hazard` (Faz 2 F2.A.4, migration `034`:
  evde açık **gaz** alarmı var, "lambaları kapat" önerisi gönderilmez; `details.reason = "gas_alarm"`, `skipped_offline` gibi pencere içinde yeniden denenir),
  `failed`, `resolved` (kullanıcı kapattı).
  Kullanıcı kapatması yalnızca `sent`, `no_recipients`, `sending` satırını çözer; `claimed/failed/skipped_offline/clear` satırlarına **dokunmaz**.
- **`GET /devices/peace-notification/:home_id` yanıtı (v2; v1 anahtarları KALIR):**
  `{ home_id, enabled, time, peace_notification_enabled, peace_notification_time, timezone, devices_total, devices_online, stale,
  open_lights_count, open_shutters_count, open_lights:[{id, channel_index, name, room}], open_shutters:[{pair, room, position}],
  summary_text, last_notice }`. `last_notice` = `null` ya da `{ id, local_date:"YYYY-MM-DD", status:"sent"|"no_recipients"|"resolved", summary_text,
  open_lights_count, open_shutters_count, created_at, resolved_at }` (yalnız bu üç durum görünür; en yenisi). `stale:true` ⇒ canlı cihaz yok: sayılar `0`, listeler boş
  ve `summary_text` "Cihaz çevrimdışı…" (bilinmiyor; "hepsi kapalı" **DEMEZ**). Yanıt canlı anlık görüntüdür: `Cache-Control: no-store` olmalıdır (entegrasyonda route'a `noStore(res)` eklenir).
  İstemci aynı ilkeyi panoda uygular (DAIRE-02/K1): pano **kesin** çevrimdışıyken (bulutta `devicePresence = offline`; doğrudan kipte cihaza ulaşılamıyor) huzur bandı ("N lamba açık kaldı." + "Hepsini Kapat") gösterilmez, durum şeridinde ışık/panjur sayaç hapları çizilmez (yalnız sistem hapı kalır); son bilinen değer kesin sunulmaz. Durum bilinmiyor / bağlanılıyorken davranış değişmez.
- **`POST /devices/peace-notification/close-all` (v2)** gövde `{ home_id, notice_id?, include_shutters? }` (`notice_id` pozitif tam sayı ya da rakam metni; `include_shutters` boolean, varsayılan `true`):
  yalnızca **canlı** cihaz verisine göre komut üretir. Evde priz (`type='plug'`) yoksa lambalar için tek `{cmd:"all_lights_off"}`, varsa yalnız açık ışık röleleri için
  `{relay:N, state:false}` (priz kapanmasın; aynı kural `POST /devices/:id/command` toplu `all_lights_off` / `all_off`'ta da uygulanır: §1.5, DAIRE-01). Her açık panjur çifti için `{shutter:P, cmd:"down"}` (`all_shutters_down` **kullanılmaz**). Komutlar sırayla ve PUBACK
  beklenerek yayınlanır (16'lık gruplar arası 150 ms). **`endpoints.current_state`'e iyimser yazım YOKTUR**: gerçek durum cihazın `state` yankısıyla gelir.
  Yanıt: `{ closed_lights, closed_shutters, closed_count (=closed_lights), skipped_count, nothing_to_do, delivered:true, device_online:true, command_ids[], command_id|null,
  notice_id|null, resolved, message }`. `resolved:true` ⇒ bildirim kaydı çözüldü. `nothing_to_do:true` ⇒ sunucu kayıtlarına göre kapatılacak şey yoktu ve **hiç komut gönderilmedi**
  (kayıtlar bayat olabilir: istemci "kapatıldı" **göstermemeli**). `skipped_count > 0` ⇒ çok panolu evde ev konusu tüm panolara gittiği için ortak kanal numarası nedeniyle
  güvenle kapatılamayan öğeler var (bildirim çözülmez, `message` elle kontrolü söyler). Hatalar: `400 VALIDATION`, `404 NOT_FOUND` (ev yok / pano yok), `409 DEVICE_OFFLINE`
  (`device_online:false`), `409 HAZARD_ACTIVE` (Faz 2 F2.A.4: evde açık gaz alarmı; toplu anahtarlama kıvılcım kaynağı, hiçbir komut gönderilmez, kayıt yazılmaz),
  `502 BROKER_UNAVAILABLE` (hiçbir kayıt yazılmaz). Yetki `group` (misafir yok). Kayıt yazımı hatası komutları geri almaz: yanıt başarılı, `resolved:false`.
- **Kimlik istisnası:** §0 "kimlikler UUID dizesidir" kuralının **tek** istisnası `notice_id`'dir: `peace_notification_logs.id` `SERIAL` (**tam sayı**). FCM `data` içinde metin olarak,
  REST gövdesinde sayı (ya da rakam metni) olarak gider; kimlik bilinmiyorsa FCM `data.notice_id` boş metindir.
- **Bir dairede tek pano (DAIRE-04):** bu sürümde hiçbir API yolu mevcut bir eve ikinci pano eklemez (claim yalnız sahibin panosuz evine ya da yeni eve bağlar; acil sıfırlama cihazı aynı evde tutar; pano değişimi eskisini evden çıkarır) ve cihaz MQTT kimliği ev başına tektir (`d_{t}`; yeni kimlik eskisini siler). Bu belgedeki "çok panolu ev" kuralları (close-all `skipped_count`, uzlaştırıcının çok panolu evde atlaması, yerleşim eşitlemede `device_id` boş kurallar) savunma amaçlıdır; çok panolu daire yalnız veritabanına elle ikinci pano eklenerek oluşur. Gerçekten istenirse önce cihaz kimliği pano başına ayrılmalı (ör. `d_{t}_{uid}`) ve claim'e "mevcut eve ekle" tasarlanmalıdır.

**Birikmiş sunucu işleri (WP-S, 2026-10-01):**
- Oturumlar toplu iptal edilince (logout-all, change-password, reset-password, admin parola/rol/dondurma/pasife alma, sosyal kimlik bağlama) kullanıcının TÜM push belirteçleri de kapanır (COMMIT sonrası, FCM yapılandırmasından bağımsız; push hatası iptali/yanıtı bozmaz). Tek cihaz çıkışı belirtece dokunmaz (istemci `DELETE /me/push-tokens` ile kendininkini kaldırır). change-password/reset-password sonrası istemci belirtecini `PUT /me/push-tokens` ile yeniden kaydeder. Aynı yollar kullanıcının TÜM evlerdeki uygulama MQTT kimliklerini de siler ve bağlantıları atar (§1.2, akış denetimi UYELIK-02).
- Çocuk kilidi `requested`/`requested_at` = bekleyen niyet; cihaz bildirimi niyetle eşleşince ya da niyet 7 günden eskiyse `null`'lanır.
- Köprü uzlaştırıcısı (`device_reconciler.js`): cihazın çevrimiçi döneminin başında (ilk canlı state / 120 sn sessizlik sonrası) bekleyen çocuk kilidi niyeti ve pano değişimi sonrası `set_runtime` (`devices.config_snapshot.runtime_sync` = pending|synced) uygulanır; cihaz/niyet başına en çok 3 deneme (5/10/20 sn), idempotent. Çok panolu evde `set_runtime` otomatik uygulanmaz (elle kalibrasyon). `cmd` yayıncıları: REST, zamanlayıcı, köprü uzlaştırıcı (yalnız backend).
  **Bekleyen yerel anahtar (akış denetimi, migration `032`):** REST bekleyen yazınca köprü `requestReconcile` ile evin çevrimiçi dönem kaydını sıfırlar (pano köprünün kısa kopukluğu boyunca bağlı kaldıysa da sonraki canlı state yeni dönem sayılır). Pano CANLI iken (`is_online` ve `last_seen_at` ≤ `MQTT_OFFLINE_AFTER_SEC`, varsayılan 120 sn) `ev/{t}/sys {cmd:"set_local_key", local_key, id}` yayınlanır; PUBACK sonrası TEK transaction'da (kilit sırası envanter → cihaz) CAS takas (`local_key_enc = local_key_pending_enc`, bekleyen ve zamanı `NULL`; yalnız bekleyen yayınlananla hâlâ aynıysa), `device_inventory.local_key_enc` aynı değere ve `device_audit_logs` `local_key_rotated` (`actor_role='system'`, anahtarsız). Yayın başarısızsa bekleyen kalır (5/10/20 sn, sonra sonraki çevrimiçi dönem); çözülemeyen ya da biçim dışı bekleyen yayınlanmaz (loglanır); çok panolu evde otomatik uygulanmaz. Firmware `sys`'i yankılamaz: kanıt PUBACK'tir. Anahtar ve şifreli değer loglanmaz. Log: `[RECONCILE] yerel_anahtar home=… cihaz=… sonuc=…` (ör. `uygulandi`, `yayin_basarisiz`, `atlandi`, `gecersiz_bekleyen`, `deneme_hakki_bitti`).
- Süreç: kapanışta `/ready` 503 `shutting_down`; PM2 `kill_timeout` ≥ 12000 ms (systemd `TimeoutStopSec=15`).

### 1.5c Servis paneli, hesap silme, etiket yeniden üretimi ve davet önizleme uçları (WP-B2; gerçekleşen şekiller, kod + gerçek PostgreSQL ile doğrulandı 2026-10-02)

Hepsi `/api/v1/...` altındadır (eski `/api/...` takma adı da vardır); başarı gövdesi `{success:true, message?, data}`, hata gövdesi §1.1 (`{success:false, message, code, ...ek alanlar}`). Kişisel veri/gizli içeren yanıtlar `Cache-Control: no-store`. Migration'lar: `027`, `028`, `029`.

- **`GET /service/subscribers?q=&limit=&offset=`** — JWT + global rol `service_user` | `super_user` (servis PIN oturumu, owner, resident, misafir `403`). Kapsam EV bazlıdır: süper tüm evleri, staff yalnız `home_users`'ta SÜRESİ DOLMAMIŞ `service_user` üyeliği olan evleri görür; iletişim bilgisi yalnız kapsamdaki evler için döner.
  `q` ≤ 64 karakter (ev adı, adres, sahip adı/e-posta/telefon, cihaz UID; `% _ \` kaçışlıdır), `limit` 1..100 (varsayılan 50), `offset` 0..1 000 000 (taşan/geçersiz değer sınıra çekilir, `500` üretmez). Yanıt `data`:
  `{subscribers:[{home_id, home_name, home_address|null, owner:{full_name, email|null, phone|null, account_status}|null, device_count, online_count, commissioned_count, commissioned_at|null, last_seen_at|null, device_uuids[≤10], created_at}], total, count, limit, offset}`.
  Yer tutucu e-postalar (telefon/Apple hesapları) sızdırılmaz (`email:null`). Hız sınırı kullanıcı başına 120/dk.
- **`POST /service/subscribers/:homeId/assign-admin/request-otp`** gövde `{full_name, email|phone}` — staff (yalnız kendi evi) / süper. Evin sahibi YOKSA yanıt `{otp_required:false, message}` (kod gerekmez). Sahibi varsa sahibin e-postasına 6 haneli kod gider (kod HEDEF KİŞİYE bağlıdır): `{otp_required:true, message, owner_hint (maskeli e-posta), expires_in:900, resend_after:60}`
  (`debug_code` yalnız `ALLOW_DEBUG_OTP=true` geliştirmede). Hatalar: `400 VALIDATION`; `403 FORBIDDEN` (ev yetkisi yok, kendini atama, servis/süper hesabı hedef); `404 NOT_FOUND`; `409` `MULTIPLE_OWNERS` | `OWNER_UNREACHABLE` | `CONFLICT` (hedef zaten tek sahip, hesap pasif/silinmiş);
  `429 RATE_LIMITED` (+`resend_after`, `Retry-After`: 60 sn bekleme; 15 dk'da 5 hatalı kod denemesi); `503 DELIVERY_FAILED` (e-posta gitmedi; yeni kod geçersiz kılınır ve bekleme kalkar. Ev başına TEK kod tutulduğundan yeni istek önceki kodun yerine geçmiştir: şifre sıfırlama / telefon OTP'deki "eski kod geçerli kalır" kuralı burada YOKTUR). Hız sınırları: IP başına 10/15 dk, kullanıcı+ev başına 5/saat.
- **`POST /service/subscribers/:homeId/assign-admin`** gövde `{full_name, email|phone, otp_code?, force?, reason?}` — TEK gerçek transaction. Modlar: `no_owner` (sahip yok: kod gerekmez, mevcut üyeler korunur; yalnız servis PIN/oturumları iptal edilir), `owner_consent` (sahibin kodu zorunlu), `forced` (yalnız süper, `force:true` + gerekçe 15..500 karakter; sahip rızası aranmaz, sahibe bildirim gider, denetim kaydı).
  Sahip varsa (`owner_consent` ve `forced`) daire DEVRİ uygulanır: tüm üyelikler kalkar [işlemi yapan staff'in kendi servis üyeliği hariç], hedef TEK owner olur, servis PIN/oturumları ve evin uygulama MQTT kimlikleri iptal edilir, davet/kural/devir temizliği yapılır. Hedef hesap yoksa `pending_invite` hesap açılır (telefonla yeni hesap açılamaz: e-posta zorunlu) ve etkinleştirme e-postası gider. Yanıt `data`:
  `{home_id, home_name, mode, new_owner:{id, full_name, email|null, phone|null, account_status}, account_created, invite_sent, previous_owner_count, revoked:{memberships, service_pins, service_sessions, app_credentials}, message, warnings?, partial?}` (kısmi başarısızlıkta HTTP 200 + `warnings` + `partial:true`).
  Hatalar: `400 OWNER_CONSENT_REQUIRED` (kod yok/geçersiz/başka kişi için istenmiş), `400 VALIDATION` + `remaining_attempts` (hatalı kod; başarısız deneme sayacı commit edilir), `429 RATE_LIMITED` (+`Retry-After`), `403 FORBIDDEN` (zorla atama yalnız süper; kendini/servis hesabını atama), `404`, `409` `MULTIPLE_OWNERS` | `CONFLICT`. Hız sınırları: kullanıcı başına 10/15 dk, ev başına 10/saat.
- **`DELETE /auth/account`** gövde `{password}` ya da (hiç parola belirlememiş Google/Apple/telefon hesabı) `{confirm:"SİL"}` ("sil/Sil/SIL/SİL" kabul) — JWT (servis PIN oturumu `403`), 5/15 dk. Yumuşak silme + anonimleştirme TEK transaction'da: e-posta `deleted+<id>@deleted.invalid` olur (ESKİ e-posta serbest kalır: aynı adresle yeniden kayıt mümkün), telefon/google_id/apple_id `NULL`, ad "Silinmiş Kullanıcı", `account_status='deleted'`, `deleted_at` dolu;
  tüm oturumlar/refresh belirteçleri, push belirteçleri, tüm evlerdeki uygulama MQTT kimlikleri, ev üyelikleri, bekleyen davet/devir/servis PIN'leri ve iletişim bilgisi taşıyan tek kullanımlık kodlar iptal edilir; denetim kaydı (`details.released_homes` dahil). Yanıt `data`: `{deleted:true, deleted_at, released_memberships, released_homes, message, warnings?}`.
  Hatalar: `400 INVALID_CREDENTIALS` (yanlış parola), `400 VALIDATION` (parolasız hesapta "SİL" yok), `403 REAUTH_REQUIRED` (parolalı hesapta yalnız `confirm` gönderildi), `403 FORBIDDEN` (staff/süper kendi hesabını bu uçtan silemez), `404`, **`409 SOLE_OWNER`** yalnız tek sahibi olduğu VE başka üyesi ya da panosu olan daireler varsa; gövdede yalnız bunlar `homes:[{id, name, other_member_count, device_count}]` (önce daire devri; engel varsa hiçbir şey silinmez).
  **Boş daire (UYELIK-03):** üyesiz VE panosuz tek-sahipli daireler engel değildir: aynı transaction'da, üyelik silindikten sonra yönetici kalıcı silme sırasıyla silinir (evin MQTT kimlikleri, cihaz kimliği dahil [kick COMMIT sonrası], servis PIN/oturumları, ev temizliği `keepEndpoints:false`, `DELETE FROM homes`); sayısı `released_homes` (her başarılı yanıtta; yoksa `0`). İstemci SOLE_OWNER'ı önceden hesaplamaz; `released_homes > 0` ise "Hesabınız silindi. Üyesi ve panosu olmayan N daireniz de kaldırıldı." der (`data` içini ve üst düzeyi okur; eski sunucuda `0`).
- **`POST /admin/inventory/:uid/reissue-label`** — YALNIZ `super_user` JWT'si (API anahtarı ve staff KABUL EDİLMEZ), yalnız `IN_STOCK` + daireye bağlı/claim edilmemiş/devreye alınmamış cihaz. Yeni kurulum PIN'i + yeni `local_key` üretilir (`local_key` şifreli saklanır, eski PIN geçersizleşir, kilit/sayaç sıfırlanır); yanıt `data`:
  `{device, setup_pin, local_key, qr_claim_url (PIN'li), message}` — gizli değerler **yalnız bu yanıtta** (`no-store`). Sahipsiz cihaz kaydındaki bekleyen yerel anahtar (`devices.local_key_pending_enc`, §1.5b) temizlenir (migration `032` tetikleyicisi `trg_devices_pending_key_superseded`): yeni etiket anahtarı esastır. Hatalar: `400 VALIDATION` (geçersiz UID), `403`, `404 NOT_FOUND`, `409 CONFLICT` (IN_STOCK değil / daireye bağlı), `429 RATE_LIMITED` (kullanıcı başına 20/saat), `503 SERVICE_UNAVAILABLE` (`LOCAL_KEY_SECRET` yok; anahtar üretilemez).
- **`POST /homes/join-preview`** gövde `{code}` — davet/devir kodunu **TÜKETMEDEN** önizler (giriş yapmış kullanıcı; servis PIN oturumu hariç). Yanıt `data`: `{kind:"invitation"|"transfer", is_transfer, home_name, resident_count, role, expires_at, already_member?, guest_valid_from?, guest_valid_until?}`.
  Bulunamayan/kullanılmış/süresi dolmuş kod AYNI yanıttır: `410 GONE` (numaralandırma ayrımı yok; istemci 404/405'i "uç yok" sayar); devir kodu yalnız HEDEF hesaba önizlenir (`403`), hedef kimlik hiçbir yanıtta dönmez; `400 VALIDATION` (biçim), kendi dairenizi kendinize devir `400`. Hız sınırı: IP başına 30/15 dk, kullanıcı başına 10/15 dk.

### 1.5d Güvenlik uçları ve komutları (WP-S4, 2026-10-06; kod + gerçek PostgreSQL ile doğrulandı)

Tasarım: `docs/superpowers/specs/2026-10-06-guvenlik-iklim-senaryo-mimarisi-design.md` §3.3, §5.2. Migration `033`. Hepsi `/api/v1/homes/...` (ve eski `/api/homes/...`) altındadır; `homeId` yalnız üyelikten okunur (`requireHomeAccess`). Komutlar `POST /devices/:id/command` ile AYNI hattan geçer (şema → rol → hedef denetimi → çevrimdışı `409` → yayın).

| Uç | Yetki | Gövde / yanıt |
|---|---|---|
| `GET /homes/:homeId/alarms?state=open\|all&before=<id>&limit=<1..200>` | `view` (tüm roller) | `data: {items:[{id, device_id, device_uuid, aid, zone, kind, status: latched\|fault\|silenced\|cleared\|lost, origin: event\|state, sources[], raised_at, device_epoch, acked_at, ack_requested, cleared_at, cleared_by: device_event\|device_state\|superseded\|lost}], next_before}`; `superseded` = aynı bölgede yeni tehlike türüyle YENİ alarm açıldı (eski satır kapanır); yeniden eskiye, mezar taşı satırları (`origin='tomb'`) listelenmez; `no-store`. |
| `POST /homes/:homeId/alarms/:alarmId/ack` | `safety_ack` | Gövde `{id?}` (istemci komut kimliği; aşağıda). Panoya `{cmd:"alarm_ack", zone, aid, uid, id}` gider; `zone`/`aid` **alarm satırından**, `uid` cihazdan. Yanıt `{delivered, device_online, command_id, applied: true\|null, alarm_id}`. Kapalı alarm `409 ALARM_NOT_OPEN`. **Pano çevrimdışı:** onay isteği kaydedilir (`alarms.ack_requested_*`) ve `409 DEVICE_OFFLINE` + `ack_queued:true`; pano dönünce köprü onayı YALNIZ state'teki bölge `aid`'si aynıysa gönderir, farklıysa (kullanıcının görmediği yeni alarm) istek düşer. |
| `POST /homes/:homeId/devices/:deviceId/actuators/:actuatorId` gövde `{to, id?}` (eski `{state}` metni de kabul; uygulama `to` gönderir) | rota: tüm roller; servis: yöne göre `actuator_close`/`actuator_control` | `to`: vana `open\|closed`, siren/fan/diğer `on\|off`. `:deviceId` cihaz kaydı UUID'si ya da `device_uuid`. Panoya `{actuator:"a1", to, uid, id}`. |
| `POST /homes/:homeId/devices/:deviceId/alarm-test` gövde `{zone, id?}` | `safety_test` | Panoya `{cmd:"alarm_test", zone, uid, id}`. |
| `GET /homes/:homeId/devices/:deviceId/safety-config` | `view` (tüm roller) | Panonun yapılandırma kopyası (`cfg_dump`'tan; sensör/eylemci/bölge **adları** yalnız burada): `data: {device_uuid, rev, crc, updated_at, policy, zones:[{id,name}], lights, sensors:[{id,kind,zone,active_open,flags,confirm_ms,name}], actuators:[{id,relay,relay2?,kind,close_mode,medium,zones,fb_di,fb_closed_active,fb_timeout_s,run_limit_s,exproof,name}]}` = panonun `GET /api/safety/config` biçimi (§2.6). Kopya henüz yoksa `404 CONFIG_NOT_AVAILABLE`. `no-store`. Uygulama `state.cfg.safety.rev/crc` değişince okur. |

**İstemci komut kimliği:** üç güvenlik ucunda gövdedeki isteğe bağlı `id` (≤ 24, `[A-Za-z0-9_.:-]`; geçersizse `400`) panoya **aynen** gider ve `state.last_id` / `last_rej.id`'de geri yankılanır; uygulama reddi kendi komutuyla anında eşler. Verilmezse sunucu üretir.

**Liste sayfalama:** `before` bir önceki sayfanın `next_before`'udur (alarm kimliği, tarih DEĞİL). Uygulama `data.items`'ı okur.

**Komut şeması** (`command_schema.js`): yeni türler `actuator`, `alarm_ack`, `alarm_test`; üçünde de `uid` **zorunlu** (yoksa `400`), sunucuda büyük harfe çevrilir ve hedef cihazın `device_uuid`'siyle eşleşmelidir (`400`). `actuator` = `a1`…`a16`, `zone` 1..4, `aid` = `<bn 8 hex>-<n ≤ 5 hane>`. Durum anahtarı `to`'dur (`state` boolean yalnız röle içindir). `event_ack`, `cfg_get`/`cfg_patch` uygulamadan **gönderilemez** (yalnız backend üretir). Düz `relay` komutunda `uid` isteğe bağlıdır: sunucu güvenlik destekli panoya (`caps` `safety` içeriyor, firmware 1.2+) hedef `uid`'yi **ekler**; v:2 panoya eklemez (bilinmeyen alanı reddeder). Firmware 1.2+ eylemci rölesine gelen **`uid`'siz** düz röle komutunu **sessizce yok sayar** (ev konusu bütün panolara gider; başka panonun aynı numaralı lambası için gönderilen komut çalan sireni susturmasın — inceleme RV-2). Eylemci olmayan rölede `uid`'siz komut v:2 gibi uygulanır.

**Hedef denetimi** (`device_service._assertCommandTarget`; savunma katmanı, asıl yetki firmware'dedir):
1. `endpoints.actuator_type` dolu kanala düz `relay` komutu (toggle dahil) → `409 ACTUATOR_USE_SAFETY_COMMAND`. Panjur kanalına röle komutu → `400` (aynen).
2. `devices.caps` içinde `safety` yoksa → `409 FIRMWARE_UNSUPPORTED` (kapatma dahil: eski firmware komutu tanımaz). Bu denetim önce yapılır.
3. Gaz vanasına (`safety_state.actuators[].medium = "gas"`) `open` → `409 GAS_LOCAL_ONLY` (her rol).
4. Vana `open`: `safety_state.mode = "normal"`, vananın bütün bölgeleri `normal` ve o bölgelerdeki aynı akışkanlı sensörler `ok && !active` değilse → `409 ZONE_ALARM_ACTIVE`. Kapatma/susturma her zaman serbest. Bilinmeyen eylemci `404`; vana/anahtar hedef uyumsuzluğu `400`. Bölge testi alarm/test sürerken `409 ZONE_ALARM_ACTIVE`.

**Uygulamanın ret eşlemesi:** `409 DEVICE_REJECTED` -> `reason` (firmware kodu) Türkçe ret metnine çevrilir ve komut hatasının kodu olur; `409 DEVICE_OFFLINE` + `ack_queued:true` -> "onay pano bağlanınca iletilecek"; `409 ALARM_NOT_OPEN` -> "alarm zaten kapanmış".

**Onay:** güvenlik komutunda sunucu yayından önce bekleyici kurar ve en çok 10 sn **yalnız hedef panonun `uid`'siyle gelen** canlı state'i dinler (köprü `expectOutcome`): `last_id` = komut kimliği → `applied:true`; `last_rej.id` = komut kimliği → `409 DEVICE_REJECTED` + `reason:<firmware kodu>` (`zone_latched`, `gas_local_only`, `stale_ack`, `safe_mode`, `actuator_relay`, `busy` …; mesaj Türkçe ret metnidir); süre dolarsa `applied:null` (komut iletildi, sonuç state'te görünür). Aynı evdeki başka panonun aynı kimlikli yankısı sayılmaz. Vana açma **asla** kuyruğa alınmaz (çevrimdışı → `409 DEVICE_OFFLINE`).

**Sunucu tarafı süzgeçler** (`actuator_type` dolu kanal; kolon NULL iken davranış birebir eskisi gibi): gece huzur özeti ve "Hepsini kapat" onu lamba saymaz (`peace_snapshot`); çok panolu evde o kanal numarası çakışma sayılır (`relay:N` başka panonun vanasını sürmez); zamanlı kural o kanalda çalışmaz (`scheduler` `skipped_invalid`) ve yeni kural oluşturulamaz (`400`); yerleşim eşitlemesi kanal eylemciye dönünce bağlı röle kurallarını kapatır. Uç nokta listesi (`GET /homes/:home_id/endpoints`) her satırda `actuator_type` (`valve`|`siren`|`fan`|`generic`|`null`), `dimmable` ve `dimmer_source` döner; `type` eylemci kanalında da `light`/`impulse` kalır.

#### 1.5e Faz 2 sunucu uçları ve kuralları (WP-G1, WP-N1, WP-I4, WP-C2; 2026-10-07; kod + gerçek PostgreSQL ile doğrulandı)

Tasarım: aynı belge "Faz 2 tasarımı" F2.A-F2.D. Migration `034` (yalnız `peace_notification_logs.status` CHECK'ine `skipped_hazard`).

**Gaz alarmında otomatik anahtarlama yok (F2.A.4, karar F2-1).** "Açık gaz alarmı" = evde `alarms.kind='gas'` ve `status IN ('latched','fault','silenced')` satırı.
- Zamanlayıcı: röle ve panjur kuralı yayınlanmaz, çalıştırma kaydı `scheduled_rule_runs.status='skipped_hazard'`, `detail='gas_alarm'`, yuva tüketilir
  (gecikmiş anahtarlama yok). Denetim cihaz sorgusunun içinde (`EXISTS … AS gas_alarm`): gaz alarmı yokken sorgu sayısı ve sonuç aynen.
- Gece hatırlatması: push yok, kayıt `skipped_hazard` (pencere içinde yeniden denenir). `POST …/peace-notification/close-all` → `409 HAZARD_ACTIVE`.
- Kullanıcının bilinçli komutu (`POST /devices/:id/command`, toplu `all_lights_off` dahil) engellenmez; uyarı uygulamadadır (WP-G2).

**Hırsız alarmı kipi (F2.B; firmware 1.2.1, `caps` `intrusion`).**

| Uç | Yetki | Gövde / yanıt |
|---|---|---|
| `POST /homes/:homeId/devices/:deviceId/arm` | `safety_arm` (owner, resident) | `{mode: "away"\|"home"\|"off", id?}` → panoya `{cmd:"safety_arm", mode, uid, id}`; yanıt `{delivered, device_online, command_id, applied: true\|null}`. `caps` `intrusion` yok → `409 FIRMWARE_UNSUPPORTED`; çevrimdışı → `409 DEVICE_OFFLINE` (**kuyruğa alınmaz**); `last_rej` → `409 DEVICE_REJECTED reason: not_ready\|unsupported\|…` ("Alarm kurulamadı: açık kapı ya da pencere var.") |
| `POST …/alarms/:id/ack` | `safety_ack` | `kind='intrusion'` satırına `409 ALARM_USE_DISARM` ("Hırsız alarmı onaylanmaz, çözülür."; komut ve çevrimdışı onay kuyruğu yok) |
| `GET …/alarms` | `view` | `kind:"intrusion"` satırları da listelenir |

- Komut şeması: `safety_arm` (`mode` ∈ `away|home|off`, `uid` zorunlu, `id`); yetenek `capabilityForCommand` → `safety_arm`.
- Olaylar (katı alan listesi, bilinmeyen alan → olay atılır): `intrusion_alarm {zone (1..4, zorunlu), kind:"intrusion", srcs}` → `alarms` satırı
  `kind='intrusion'`, `aid = eid`, tek `safety_alarm` push'u ("Hırsız alarmı" / "Ev alarmı tetiklendi (bölge N). Uygulamadan durumu kontrol edin; tehlikedeyseniz 112'yi arayın.");
  `intrusion_cleared {aid (zorunlu), via: cloud|lan|cli|di}` → satır `cleared` (`device_event`), bilinmeyen `aid` → mezar taşı (`origin='tomb'`, bölge yer tutucu 1);
  `arm_changed {mode, via: cloud|lan|cli|di|boot}` → yalnız `device_audit_logs` `safety_arm_changed {mode, via}`.
- `devices.safety_state.arm = {mode, st, ok, aid, srcs}` (`until_up` saklanmaz; bilinmeyen `mode`/`st` → `"unknown"`).
- **Uzlaştırma ayrımı:** bölge uzlaştırması `kind='intrusion'` satırlarına dokunmaz. Hırsız satırı: `arm` yok ya da `arm.ok=false` → `lost` (+ bilgi push'u);
  `st="alarm"` ve aynı `aid` → kalır; `st` bilinmiyor → dokunulmaz; aksi (`st≠alarm` ya da başka `aid`) → `cleared` (`device_state`). Olayı kaybolmuş hırsız
  alarmı state'ten açılır (`origin='state'`, bölge = ilk kaynak sensörün bölgesi, yoksa 1). Bölge olayı (aid'siz) hırsız satırını bulmaz.

**Buluttan yapılandırma yazımı (F2.D; kararlar F2-8, F2-9).**

| Uç | Yetki | Gövde / yanıt |
|---|---|---|
| `POST /homes/:homeId/devices/:deviceId/safety-config` | `safety_config` (super, staff, session, owner) | `{base_rev: u32, set: {sensor\|actuator\|policy\|zone\|light\|intrusion: {…}} \| del: {sensor:"dN\|bN"} \| {actuator:"aN"}, id?}` (`set`/`del`'den tam biri, tek öğe; alanlar ve aralıklar firmware `parseCfgEdit` ile aynı, §2.6). `200 {applied:true, rev, crc, command_id}`; `202 {applied:null, command_id}` (10 sn içinde sonuç yok; sonuç state'te); `202 {queued:true, position, expires_at, command_id}` (pano çevrimdışı) |
| `DELETE …/safety-config/pending` | `safety_config` | `200 {dropped: n}` (denetim `safety_config_pending_dropped {reason:"cancelled", count}`) |
| `GET …/safety-config` (mevcut) | `view` | ek alanlar `state_rev` (panonun son bildirdiği rev, yoksa `null`), `next_base_rev` (kuyruk varsa son öğe + 1, yoksa `state_rev`), `pending: [{id, op, item, target, at, role, loosening}]` (yalnız `safety_config` yetkilisine; değer/ad içermez) |

- Hatalar: `400 VALIDATION` (gövde), `400 PAYLOAD_TOO_LARGE` (sys yükü > 1024 B), `400 CONFIG_INVALID` (firmware `cfg_invalid`), `403`, `409 FIRMWARE_UNSUPPORTED`
  (`caps` `cfg` yok; ya da `caps` `intrusion` olmadan `set.intrusion` / sensör `flags > 0x07` / `kind:"arm_key"`), `409 CONFIG_NOT_AVAILABLE` (kopya ya da
  panonun `cfg.safety.rev`'i yok; sunucu `cfg_get` ister), `409 CONFIG_PENDING` (çevrimiçi panoda kuyruk dolu ya da aynı panoya başka yama uçuşta),
  `409 CONFIG_CHANGED_ON_DEVICE` + `data: {rev, crc, copy_rev}` (ön denetim: `base_rev` ≠ panonun son rev'i; firmware `cfg_conflict`; kuyruk zinciri kırık),
  `409 CONFIG_QUEUE_FULL` (16 öğe), `409 ZONE_ALARM_ACTIVE` (`zone_latched`), `409 DEVICE_REJECTED reason` (diğer kodlar), `502 BROKER_UNAVAILABLE`,
  `503 DEVICE_BUSY` (`busy`), `507 DEVICE_STORAGE_FULL` (`cfg_storage`). `data` hata gövdesinin beyaz listeli ek alanıdır (`http_errors`).
  **Faz 2 incelemesi (G-1) bulut yolunun yetki sınırı:** `403 GAS_VALVE_LOCAL_ONLY` (yama gaz vanasını uzaktan açılabilir kılar: mevcut gaz
  vanasının röle/tür/kip/akışkan kimliğini değiştirir ya da onu siler, ya da `gas_reset` satır kuralı; karar 7.2b-8; firmware `gas_local_only`),
  `409 INTRUSION_ARMED` (panonun son state'inde `arm.mode` ≠ `off` iken hırsız alarmını zayıflatan yama; F2-3; firmware `armed`). İkisi de
  çevrimiçi ve kuyruk yolunda ağa çıkmadan döner, denetim kaydına `result: rejected_gas_local | rejected_armed` yazılır; asıl karar panodadır
  (kopya bayat olabilir). Sınıflar `utils/safety_cfg_loosen.js` `isGasRelease` / `isIntrusionLoosening` (firmware portu, ortak vektörler).
- Panoya giden: `ev/{t}/sys {cmd:"cfg_patch", module:"safety", uid, id, base_rev, set|del}`. Sonuç bekleyicisi yayından ÖNCE kurulur ve yalnız hedef
  `uid`'nin canlı state'ini dinler: `last_id = id` (firmware C1 sonrası) **ya da** `cfg.safety.rev = base_rev + 1` (v1.2.0 başarıda `last_id` yazmaz) →
  uygulandı; `last_rej.id = id` → ret. **Faz 2 incelemesi R2:** rev çıkarımı yalnız `last_id` yankısı vermeyen panoda (`caps` `intrusion` yok;
  yankı ve hırsız katmanı aynı sürümde, 1.2.1) yapılır; yankılı panoda başka kaynaklı (LAN/CLI) rev artışı uygulandı sayılmaz. **R3:** sonuç,
  o state `devices.safety_state`'e yazıldıktan SONRA verilir (yanıttan hemen sonraki `GET`'te `state_rev` günceldir). Başarıdan sonra kopya
  `cfg_get` ile tazelenir (`requestConfig({force})`: 5 sn taban aralık). Kopya yazımı (`cfg_dump`) eski rev'i yeniyle ezmez; ancak pano rev'i
  gerilediyse (fabrika sıfırlaması) panonun son bildirdiği `(rev, crc)` ile aynı döküm yazılır (RG-1).
- Aynı panoya tek uçuş: `device_configs` satır kilidi altında `pending.inflight = {id, at}` yazılır (ağ beklemesi transaction dışında; 30 sn sonra geçersiz).
- Kuyruk (`device_configs.pending` sürüm 1): `{"v":1, "items":[{id, base_rev, patch:{set|del}, by, role, at, loosening, sent_at?}], "inflight"?}`; ≤ 16 öğe,
  24 sa. Uzlaştırıcı cfg yetenekli panonun her canlı state'inde (kuyruk boşken sorgu yok): süresi dolan → `expired`; isteyenin eve erişimi kalmadı → o ve
  sonrakiler `revoked`; daha önce gönderilmiş baş öğe ve state rev = `base_rev + 1` (yankılı panoda ayrıca state `last_id` = öğe kimliği, R2) →
  uygulandı (`applied_inferred`, çift uygulama yok); baş öğenin
  `base_rev`'i ≠ state rev → **pano kazanır**: bütün kuyruk `conflict` ile düşer + owner'a `safety_info {reason:"cfg_pending_dropped"}`; eşitse baş öğe gönderilir
  (tur başına tek öğe). Firmware `cfg_invalid|zone_latched|cfg_conflict|cfg_storage|gas_local_only|armed` → baş öğe ve sonrakiler düşer + bilgi push'u;
  `busy`/zaman aşımı → öğe kalır (en çok 3 deneme / 10 dk). Kuyruk işleri ev uzlaştırmasından ayrı şeritte çalışır (RG-2: yanıt beklemesi ev
  uzlaştırmasını bekletmez).
- Denetim kaydı (`device_audit_logs`): `safety_config_patch {op, item, target, loosening, result: applied|queued|applied_inferred|rejected_gas_local|rejected_armed, via: cloud|queue, command_id}`
  (aktör = isteyen kullanıcı ve rolü) ve `safety_config_pending_dropped {reason: expired|revoked|conflict|cancelled|<firmware kodu>, count}`. Değer ve ad yazılmaz.
- Gevşetme sınıflandırması (`utils/safety_cfg_loosen.js`, firmware `isLoosening` portu) yalnız denetim/bilgi içindir (hırsız zayıflatması da
  `loosening:true` sayılır); `isGasRelease` / `isIntrusionLoosening` ise yukarıdaki yetki sınırıdır. Firmware ile ayrışmaması ortak vektör
  dosyasıyla denetlenir (`tools/qa_stack/sim/fw/fixtures/loosening_vectors.json`, firmware JS portu üretir; sunucu testi okur). Bulut gevşetmesi için ayrı push
  yok (F2-9; politika kapatma mevcut `policy_changed` yolundan).

## 2. MQTT sözleşmesi

Broker: EMQX, `evotomasyon.gudeteknoloji.com.tr:8884` (TLS). `{t}` = `homes.mqtt_username` = **rastgele, tahmin edilemeyen** ev konu kimliği (`h_` + 16 hex).

### 2.1 Konular ve yön

| Konu | Yayıncı | Abone | Notlar |
|---|---|---|---|
| `ev/{t}/cmd` | **yalnızca backend** | cihaz | `retain=false`, QoS 1. Uygulamalar buraya yayın YAPAMAZ. |
| `ev/{t}/state` | cihaz | backend, uygulama | `retain=true`, QoS 0/1. Tam anlık durum. |
| `ev/{t}/status` | cihaz (LWT dahil) | backend, uygulama | `online` / `offline`, `retain=true`, QoS 1. |
| `ev/{t}/sys` | **yalnızca backend** | cihaz | Yönetim komutları (`set_local_key`). `retain=false`. |

### 2.2 Kimlik ve ACL

| Kimlik | Kullanıcı adı | Yetki |
|---|---|---|
| Backend | `backend_service` (ortam değişkeninden, rastgele güçlü parola) | superuser |
| Cihaz | `d_{t}` (cihaz başına rastgele parola) | pub `ev/{t}/state`, `ev/{t}/status`; sub `ev/{t}/cmd`, `ev/{t}/sys` |
| Uygulama | `a_{t}_{rastgele}` (**kullanıcı oturumu başına, süreli**) | **yalnızca sub** `ev/{t}/state`, `ev/{t}/status` |

- Parolalar DB'de **bcrypt** özeti olarak tutulur (`mqtt_credentials` tablosu). **SAPMA (C paketi):** EMQX 5'te zincirde aynı mekanizma/backend çifti bir kez
  bulunabildiği ve özet algoritması authenticator başına olduğu için "ikinci legacy SHA-256 authenticator" **kurulmadı**; yerine tek bcrypt authenticator vardır.
  Eski paylaşılan kimlikler (`home_101` …) yalnızca `scripts/upgrade_legacy_mqtt_user.js` ile (gerçek eski parola ortamdan verilerek) bcrypt'e **yükseltilirse**
  kabul edilir; SHA-256 ve eski superuser **kabul edilmez**. Sahadaki eski firmware'li panolar yükseltme yapılana kadar bağlanamaz (zaten tüm panolar yeniden flash'lanacak).
  Tüm cihazlar yeni firmware'e geçince `acl.conf` legacy bloğu ve `mqtt_users` satırları silinir (`docs/DEPLOY_RUNBOOK.md`).
  **UYARI:** EMQX yapılandırması (`emqx.conf` HOCON ortam yerine koyma, authn/authz sözdizimi, tek PG authenticator varsayımı) EMQX çalıştırılamadığı için **doğrulanmadı**;
  dağıtım öncesi hazırlık ortamında doğrulanmalıdır (yedek: parolaları `EMQX_AUTHENTICATION__1__PASSWORD` / `EMQX_AUTHORIZATION__SOURCES__1__PASSWORD` ile ver).
- Üye çıkarma, misafir süresi dolması, daire devri, acil sıfırlama, pano değişimi → ilgili uygulama kimlikleri DB'den silinir ve
  (varsa) EMQX REST API ile bağlantı atılır (`kick`). Cihaz kimliği yalnızca devir/sıfırlama/pano değişiminde yenilenir.
  Oturumların toplu iptali (logout-all, parola değişimi/sıfırlama, yönetici parola/rol/dondurma, sosyal bağlamadaki ön-hesap savunması; §1.2) ve hesap silme → kullanıcının TÜM evlerdeki uygulama kimlikleri silinir + kick (UYELIK-02).
- Uygulama istemcisi: aracı kimliği CONNACK ile reddederse (bad username/password, not authorized) bayat kimlik atılır ve beklemeden BİR kez taze kimlik istenir (`POST /homes/:id/mqtt-credentials`); taze kimlik de reddedilirse üstel geri çekilme (2, 4, 8 … en çok 60 sn, ±%20) sürer; hak başarılı bağlantıda yenilenir. Kimlik ucu `401`/`403`/`404` verirse döngü kalıcı durur (`401`'de oturum-sonu akışı: refresh reddi → oturum olayı).
- Cihaz `cmd` abone olduktan sonra **ilk 1500 ms içinde** gelen `cmd` mesajlarını yok sayar (retained mesaj yeniden uygulanmasına karşı savunma).

### 2.3 `cmd` yükleri (JSON, UTF-8)

Tüm indeksler **1 tabanlıdır**. İsteğe bağlı `"id"` (≤ 24 karakter) cihazın `state.last_id` alanında geri yankılanır; tekrar gelen aynı `id` yok sayılır.

```json
{ "relay": 3, "state": true }
{ "relay": 3, "cmd": "toggle" }
{ "shutter": 2, "cmd": "up" }            // up | down | stop | step
{ "shutter": 2, "pos": 40 }              // 0..100
{ "cmd": "all_lights_off" }              // eşanlamlı: all_off
{ "cmd": "all_shutters_up" }             // all_shutters_down | all_shutters_stop
{ "cmd": "set_child_lock", "enabled": true }
{ "cmd": "set_runtime", "shutter": 2, "sec": 24 }    // 1..300; NVS'e yazılır (nadir)
```

Kural: bilinmeyen alan/komut, tip uyuşmazlığı, aralık dışı değer → komut **uygulanmaz** (firmware sessizce varsayılana düşmez).
`state` boolean olmalıdır (`"ON"` string kabul edilmez). `pos` tamsayı `0..100`.

- `all_lights_off` firmware'de tüm `light` tipli röleleri kapatır (firmware'de priz tipi yoktur; priz yalnız buluttaki `endpoints.type='plug'`'tır). Bulut yolunda evde priz varsa sunucu bu yükü yayınlamaz, açık ışık rölelerini tek tek kapatır (§1.5, DAIRE-01); istemcide toplu komutun iyimser hedefi yoktur (kartlar pano bildirimiyle güncellenir, açık lamba sayacı yalnız `light` sayar). LAN doğrudan modunda priz kavramı yoktur.
- `all_shutters_up|down` hedefsiz tam süre (+ taşma payı) çalışır: zaten uçtaki panjurun motoru da yeniden çalışır (uç noktaya oturtma; DAIRE-K2 bilinçli kabul). Sunucunun close-all'u bu yüzden `all_shutters_down` kullanmaz; "Evden Çıkıyorum" / "İyi Geceler" senaryoları kullanır.

### 2.4 `state` yükü (cihaz → bulut)

```json
{
  "v": 2, "uid": "AHBU-S3-…", "fw": "1.1.2", "seq": 1234, "uptime": 3600, "ip": "192.168.1.30",
  "child_lock": false, "last_id": "abc123",
  "relays":   [ { "id": 1, "name": "Salon", "type": "light", "state": true } ],
  "shutters": [ { "pair": 1, "pos": 100, "moving": false, "dir": 0, "target": 255 } ],
  "dis":      [ { "id": 1, "state": false } ]
}
```
`dir`: `0` durdu, `1` yukarı, `2` aşağı. `target`: `255` = hedef yok. Büyük kurulumlarda (≥ 16 röle) JSON havuzu ölçülerek ayrılır ve taşma durumunda yayın yapılmaz, hata loglanır.

- **`last_id` = cihaz onayı (DAIRE-03):** firmware başarılı komutta `last_id`'yi komut kimliğine eşitler ve hemen yayınlar; reddettiği komutta (ör. panjur hareket halindeyken `set_runtime`) değiştirmez. Köprü bu yankıyı onay olarak kullanır (`expectAck`): bekleyici yayından önce kurulur, yalnız CANLI state sayılır (retained sayılmaz), yankı kuyruk birleştirmesinden önce denetlenir. Kullanıcı: `PUT …/endpoints/:id` süre yolu (§1.5). `state` QoS 0 olduğundan yankı kaybolabilir: uygulanmış süre `409` alır, yeniden deneme düzeltir.
- **Panjur konumu kesinti sonrası (DAIRE-05, bilinçli sınır):** konum sensörsüzdür (süreyle hesaplanır). Pano konumu hareket bittikten 8 sn sonra (değişim ≥ %2 ise) NVS'e yazar; hareket sırasında ya da bu 8 sn içinde enerji kesilirse açılışta eski konum yüklenir ve `pos` kesin değer gibi yayınlanır (bilinmezlik alanı yoktur; planlı yeniden başlatmada konum zorla yazılır). İlk tam `up` / `down` (hedefsiz tam süre + taşma) konumu uca oturtup düzeltir; o zamana kadar `pos` komutları yanlış referanstan hesaplanabilir. Gerekirse ileride geriye uyumlu `pos_known` alanı eklenir.

### 2.4b Yerleşim eşitleme: pano → bulut uç noktaları (WP-L, 2026-10-03)

Bulut `endpoints` satırları sahiplenmede sabit şablondan açılır (`device_service.js` `SEED_ENDPOINTS_SQL`); bundan sonra **panonun bildirdiği gerçek yerleşime** otomatik uzlaştırılır. Servis sorumlusu yalnız panoyu ayarlar (cihaz web sayfası, "Kanal Ayarları"); uygulamada kontrol ayrıca "kurulmaz". Tasarım: `docs/superpowers/specs/2026-10-03-uc-nokta-yerlesim-esitleme-design.md`.

- **Kaynak:** canlı (retained olmayan) `state` mesajındaki `relays[].{id,name,type}` ve `shutters[].pair`. Köprü durum/konum güncellemesini COMMIT ettikten sonra `services/endpoint_layout_sync.js`'i çağırır (hata yalıtımlı; ana `state` yolu değişmez). Saf kurallar: `utils/endpoint_layout.js`.
- **Kabul koşulu (hepsi sağlanmazsa o mesaj yok sayılır, satır değişmez):** `v ≥ 2`; `relays` 1..N (N ≤ 40) boşluksuz, yinelemesiz ve sıralı (i. kayıt `id = i`; pano böyle yayınlar); `name` varsa dizge (`null` dahil başka tür reddedilir); her `type` ∈ `light | impulse | shutter_up | shutter_down`; panjur çiftleri tam (röle `2p-1` = `shutter_up` ⇔ röle `2p` = `shutter_down`); `shutters[]` çift kümesi tiplerden çıkan kümeyle aynı.
- **Tip ve çift (pano esastır):** `shutter_up` + `shutter_down` → iki `shutter` satırı (`shutter_pair_index = p`; süre: satır zaten panjursa korunur, değilse 20 sn); `impulse` → `impulse`; `light` → `light` (satır `plug` ise `plug` korunur). Satır yerinde güncellenir, uç nokta kimliği değişmez.
- **Ad:** pano adı fabrika varsayılanı değilse ve (bulut adı otomatik bir adsa | panoda ad değiştiyse | kanalın sınıfı röle ↔ panjur değiştiyse) pano adı alınır. Kullanıcının bulutta verdiği ad, pano tarafında değişiklik olmadıkça korunur. Panonun ASCII fabrika adları buluta taşınmaz (bulutun Türkçe varsayılanları kalır). Karşılaştırma büyük/küçük harf, aksan ve noktalama duyarsızdır; Türkçe dışı harfler (Kiril, Arap, CJK…) korunur; yalnız emoji/noktalamadan oluşan ad da özel ad sayılır. Ad temizliği kontrol ve biçim karakterlerini (Unicode `Cc`/`Cf`/`Zl`/`Zp`, yalnız vekiller, Hangul dolguları) atar.
- **Oda:** panoda yoktur. Yeni satırda ve sınıf (röle ↔ panjur) değişiminde yeni addan türetilir; aksi halde yalnız ad değiştiğinde ve oda otomatik bir değerdeyse (boş / `Genel` / şablon odası / eski addan türetilmiş) yeniden türetilir: adın başındaki bilinen oda adı, yoksa `Genel`. Kullanıcının verdiği oda, sınıf değişmedikçe korunur.
- **Kanal sayısı:** bildirilen 1..N için eksik satır açılır (ek modül röleleri dahil). N'den büyük kanallı satırlar, aynı küçülme en az 20 sn arayla ikinci kez görülünce silinir.
- **Zamanlı kurallar:** sınıfı değişen (röle ↔ panjur) ya da silinen kanal/çifte ve tipi lamba/priz ↔ darbe değişen kanala bağlı kurallar `enabled = FALSE` yapılır (lambaya yazılmış kural panjur motorunu ya da kapı/kilit darbesini sürmesin). `device_id` boş kurallar yalnız evde tek pano varsa kapatılır. Kapatılmış bir kural yeniden açılırken (`PUT …/scheduled-rules/:id` `{enabled:true}`) kanal tipine göre yeniden doğrulanır; uymuyorsa `400 VALIDATION`. Zamanlayıcı ayrıca ateşleme anında hedefi denetler: röle kuralının kanalı panjursa ya da panjur kuralının çifti artık panjur değilse komut yayınlanmaz (`scheduled_rule_runs.status = 'skipped_invalid'`).
- **Taban:** `devices.reported_layout` (JSONB, migration `031`) bu panonun en son uygulanan bildirimini tutar; "panoda ad değişti" kararı buna göre verilir. Sahiplenme, acil sıfırlama (devir ya da stoğa dönüş) ve pano değişimi tabanı boşaltır.
- **Geçici (fabrika) pano koruması:** cihaz devreye alınmamış (`devices.is_commissioned` doğru değil) ve tabanı boşken pano tam fabrika yerleşimini bildirirse (örnek: pano değişiminden sonra henüz ayarlanmamış yeni pano), yalnız güvenlik gereği değişiklikler uygulanır: bulutta röle olup panoda panjur olan kanallar panjura çevrilir, lamba/priz ↔ darbe değişimi işlenir, eksik satırlar açılır. Panjurdan röleye dönüş, satır silme ve ad/oda değişimi ertelenir; taban yazılmaz. Pano fabrika dışı bir yerleşim bildirince ya da cihaz devreye alınınca normal kurallar uygulanır. Ertelenecek bir şey yoksa davranış normaldir. Ertelenen yönlerde pano bu komutları zaten reddeder (yapılandırılmamış çift, aralık dışı röle).
- **Denetim:** uygulanan her değişiklik `device_audit_logs`'a `endpoint_layout_synced` olayı olarak yazılır (`actor_role = 'device'`; ayrıntı yalnız sayılar ve kapatılan kural kimlikleri, ad içermez).
- **Yük:** yerleşim imzası (id + tip + ad) değişmediyse sorgu yapılmaz; aynı imza için cihaz başına 5 dakikada bir kilitsiz doğrulama okuması; cihaz başına en sık 5 sn'de bir çalışır. Canlı `status: offline` (LWT) ve acil sıfırlama (devir) cihazın imza önbelleğini atar: pano ilk canlı state'te hemen eşitlenir. Hız sınırı ve küçülme onayı LWT ile sıfırlanmaz. Cihaz başına saatte en çok 30 satır değiştiren eşitleme uygulanır; aşılırsa o saat yazılmaz, uyarı loglanır (ele geçirilmiş cihaz kimliğine karşı yazma bütçesi).
- **İstemci:** REST biçimi **değişmez** (§1.5 `GET /homes/:homeId/endpoints`). Uç nokta listesi artık çalışma sırasında değişebilir (yeni satır, tip/ad değişimi); istemci listeyi her çekişte baştan kurar. Uygulama (WP-L istemci yenilemesi): canlı `state` yerleşimi (tür / panjur çifti / kanal sayısı; ad HARİÇ) uç nokta listesiyle uyuşmazsa ≈2 sn sonra uç noktaları sessizce yeniden çeker; pano ve yerleşim imzası başına en çok 3 deneme (2, +10, +30 sn), sonra yerleşim değişene ya da uyuşana dek durur (`ENDPOINT_LAYOUT_SYNC=off` ise sonsuz istek yok; ayrıntı: `docs/superpowers/analysis/endpoint-yerlesim-istemci-yenileme.md`). Sunucu, panjura dönmüş kanala gelen röle komutunu `400` ile reddeder (`_assertCommandTarget`); yenileme gelene kadar eski lamba kartına dokunmak motoru sürmez.
- **Kapatma anahtarı:** `ENDPOINT_LAYOUT_SYNC=off` (§6).
- **Sınırlar:** ad ya da lamba ↔ darbe değişimi buluta panonun bir sonraki kalp atışında (en geç 30 sn) ulaşır; yeni açılan panjur satırı 20 sn süreyle başlar (pano süreyi `state`'te yayınlamaz; servis sihirbazının 8. adımında ölçülür); gerçek panoda doğrulanmadı.

### 2.5 Push (FCM) bildirimi (sunucu → uygulama, WP-H)

Sunucu FCM HTTP v1 (`https://fcm.googleapis.com/v1/projects/{FCM_PROJECT_ID}/messages:send`) çağırır; erişim belirteci `google-auth-library` ile (kapsam `firebase.messaging`), istek
global `fetch` ile yapılır (yeni bağımlılık yok). Her **belirteç için ayrı** mesaj gönderilir. `data` yalnızca **string** değerler taşır:

| `data` anahtarı | Değer |
|---|---|
| `type` | sabit `peace_open_devices` |
| `home_id` | ev UUID'si (`[A-Za-z0-9_-]`, ≤ 64) |
| `notice_id` | `peace_notification_logs.id` (rakam metni) ya da `""` |
| `open_lights`, `open_shutters` | rakam metni (en az biri > 0) |
| `action` | sabit `close_all` |
| `v` | sabit `1` (bilinmeyen sürüm istemcide yok sayılır) |

`notification.title` = ev adı, `notification.body` = Türkçe özet (ör. "Salonda 2 lamba, 1 panjur açık."). **Android:** `priority=HIGH`, `ttl=3600s`, `collapse_key=peace_<home_id>`,
`notification.channel_id=peace_reminder` (**uygulama bu kanalı oluşturmalıdır**), `tag=peace_<home_id>`. **iOS (APNs):** `apns-priority=10`, `apns-collapse-id=peace_<home_id>`,
`apns-expiration=+3600s`, `aps.category=PEACE_CLOSE_ALL`, `aps.thread-id=<home_id>`, `sound=default`. FCM yanıtı `UNREGISTERED` ya da belirteçle ilgili `INVALID_ARGUMENT` ise o belirteç `disabled_at` ile kapatılır; kanıtsız `404` (yanlış `FCM_PROJECT_ID`/API kapalı) yapılandırma
hatası sayılır ve belirteçlere **dokunulmaz** (operatör düzeltince sonraki denemede gider); 401/403/429/5xx/ağ hataları geçicidir (yeniden denenir).
**İstemci kuralları:** `data` güvenilmeyen girdidir (sıkı doğrulama; geçersizse yok sayılır); aynı `notice_id` 10 dk içinde tek afiş üretir; uygulama ön plandayken sistem bildirimi gösterilmez,
uygulama kendi afişini çıkarır; "Hepsini kapat" mevcut `POST …/close-all` ucunu `notice_id` ile çağırır (bildirimin kendisi komut taşımaz).

**Güvenlik push'u (WP-S3, tasarım §5.2.3; kararlar §7.2b-3/4).** `push_service.sendNotice({kind})`; `kind` verilmezse yukarıdaki gece hatırlatması mesajı **aynen** üretilir.

| | `safety_alarm` (alarm açıldı / vana arızası) | `safety_info` (alarm doğrulanamadı / politika değişti) |
|---|---|---|
| Alıcı | `owner` + `resident` (misafir ve servis rolleri **asla**) | yalnız `owner` |
| `data` (hepsi metin) | `{type:"safety_alarm", v:"1", home_id, device_id, alarm_id, zone, kind, status}` (`status`: `latched`\|`fault`) | `{type:"safety_info", v:"1", home_id, device_id, alarm_id, reason}` (`reason`: `alarm_lost`\|`policy_off`\|`policy_on`) |
| Android | `priority=HIGH`, `ttl=21600s`, `channel_id=safety_alarm` (**uygulama yüksek önemli bu kanalı oluşturmalı**), `collapse_key=tag=alarm_<home>_<device>_<zone>` | `priority=HIGH`, `ttl=86400s`, `channel_id=safety_info`, `collapse_key=safety_info_<home>` |
| iOS | `apns-priority=10`, `aps.interruption-level=time-sensitive` (kritik uyarı izni **yok**), `aps.category=SAFETY_ALARM`, `sound=default` | `apns-priority=5`, `interruption-level=active`, `aps.category=SAFETY_INFO` |

Tek gönderim: `alarms.push_status` `pending → claimed → sending → sent|failed|skipped` (yalnız `pending` satır alınır: en çok bir push); `valve_fault` ikinci push'u `fault_push_status` ile aynı döngüden geçer. Push yapılandırılmamışsa ya da alıcı yoksa `skipped` yazılır, alarm kaydı yine açılır. **Yeniden deneme:** gönderim hiçbir belirtece ulaşmazsa (`sent = 0` ya da istisna) 5 sn sonra alıcılar yeniden okunup **bir kez** daha denenir; ikinci deneme de başarısızsa `failed` (`alarm_service.pushRetryDelayMs`, sayaç `pushRetries`).

**Faz 2 ekleri (WP-N1, WP-G1, WP-I4, WP-C2; 2026-10-07).**
- `data.device_uuid` (**yeni, ek alan**, `v` `"1"` kalır): panonun `uid`'si (`devices.device_uuid`, büyük harf, `^[A-Z0-9-]{1,32}$`); hem `safety_alarm` hem
  `safety_info`. Geçersiz biçim **atılır** (anahtar yazılmaz). Uygulama kritik alarm kartını pano `uid`'siyle anahtarlar.
- `safety_alarm.kind` yeni değer `intrusion` (başlık "Hırsız alarmı"); `safety_info.reason` yeni değer `cfg_pending_dropped` (başlık "Bekleyen yapılandırma
  iptal edildi"; çevrimdışı panoya sıralanan yamalar uygulanamadı).
- Metinler (F2.A.5): gaz "Gaz kaçağı algılandı (bölge N). Gaz vanası kapatıldı. Ortamı havalandırın, elektrik anahtarlarına dokunmayın; gerekirse 187'yi arayın.";
  duman "Duman algılandı (bölge N). Evde biri varsa hemen dışarı çıkın ve 112'yi arayın. Pano su vanasını kapatmaz."; su metni aynen. Vana arızası türe göre:
  su "Vana kapanmadı!" / "Su vanası kapanmadı! Ana su vanasını elle kapatın ve panoyu kontrol edin."; gaz "Gaz vanası kapanmadı!" / "Gaz vanası kapanmadı!
  Sayaçtaki ana gaz vanasını elle kapatın, ortamı havalandırın ve 187'yi arayın."; bilinmeyen tür eski genel metin.

**Olay günlüğü saklama:** `device_events` (ham olay + `(device_id, eid)` tekilleştirme) 90 gün tutulur; zamanlayıcının günlük temizliği (`scheduler.js` `SQL.eventRetention`, `received_at` indeksi) siler. `alarms` satırları silinmez. eid açılış nonce'u taşıdığından eski satırın silinmesi yinelenen olayı yeniden işletmez.
### 2.6 Güvenlik katmanı: `state` v:3, yeni komutlar ve `ev/{t}/event` (firmware v1.2.0, WP-F0..F5, 2026-10-07)

> **Durum: firmware'de UYGULANDI (v1.2.0; donanımda doğrulanmadı).** Sunucu (WP-S1..S4) ve uygulama (WP-A1..A4) bu sözleşmeye uyar.
> Gerçekleşen ayrıntılar bu bölümün sonundaki "Gerçekleşen ayrıntılar (v1.2.0)" alt başlığındadır. Kaynak: `docs/superpowers/specs/2026-10-06-guvenlik-iklim-senaryo-mimarisi-design.md` §3 (revizyon 2 + karar 7.2b) ve
> aynı belgenin "Uygulama notları (EKIP FW)" bölümü. Çelişkide **kod** esastır: `src/sensors/*`, `src/actuators/*`, `src/safety/*`, `src/events/EventOutbox.h`.

**Sürüm kuralları.**
- `v:3`, `v:2`'nin **katı üst kümesidir**: §2.4'teki her alan aynı ad, tür ve anlamla kalır. Tüketiciler `v === 2` değil `v >= 2` denetler.
- Yapılandırılmamış panoda (sensör/eylemci tablosu boş: bugünkü saha ve fabrika varsayılanı) ek olarak yalnız `caps`, `boot`, `bn`, `time_ok`, `epoch` yazılır.
  `sensors`, `actuators`, `safety` anahtarları yalnız en az bir sensör ya da eylemci varsa yazılır. Bilinmeyen alan yok sayılır.
- Eylemci rölesinin `type`'ı bugünkü RelayType adıyla kalır (`light`/`impulse`); yalnız `act` eklenir (`valve|siren|fan|generic`). Eski istemci yerleşimi bozulmadan okur;
  eylemci rölesine açma yönündeki düz `relay` komutu firmware'de `actuator_relay` ile reddedilir (kapatma yönü serbest). MQTT'de eylemci rölesine gelen `uid`'siz düz komut yok sayılır (yukarıda `cmd` ekleri).

**`state` ekleri** (adlar state'te YOK; `cfg_dump` / `GET /api/safety/config` ile gelir):

| Alan | Tür | Anlam |
|---|---|---|
| `caps` | dizge dizisi (≤ 8 × ≤ 12) | yetenekler, ör. `["safety","actuator","event","cfg"]`; yoksa pano güvenlik desteklemiyor sayılır |
| `boot` / `bn` | u32 / 8 hex | açılış sayacı (`ahbu_latch`, fabrika sıfırlamasında silinmez) / açılış nonce'u (eid öneki) |
| `time_ok`, `epoch` | bool, u32 | saat güvenilir mi; `false` ise `since` yazılmaz |
| `cfg.safety` | `{rev:u32, crc:"8hex"}` | yapılandırma sürümü + CRC32 (pol + bölgeler + dolu sensör/eylemci yuvaları + ışık seçenekleri; `rev` CRC'ye girmez) |
| `last_rej` | `{id ≤ 24, code ≤ 24}` | son reddedilen komut; kodlar: `zone_latched`, `zone_test`, `actuator_relay`, `unknown_actuator`, `bad_state`, `unsupported`, `cfg_conflict`, `cfg_invalid`, `gas_local_only`, `stale_ack`, `safe_mode`, `bad_cmd`, `busy`; 1.2.1+: `not_ready`, `cfg_storage`, `armed` (kurulu kipte bulut yaması hırsız alarmını zayıflatırdı) |
| `relays[].act` | dizge | yalnız eylemci rölelerinde |
| `sensors[]` | `{id:"d<1..40>"\|"b<1..16>", src:"di"\|"bridge", kind, zone, active, ok}` | ≤ 56; `ok=false` iken `active` anlamsızdır. `kind` ∈ `water, gas, smoke, door, window, motion, generic` **ya da yerel kumanda rolü** `alarm_ack, valve_close, gas_reset` (bu satırlarda `active` = ham basılı seviye; tehlike sensörü DEĞİL, vana açma iznine girmez) |
| `actuators[]` | `{id:"a<1..16>", relay, relay2?, kind, medium?, zones[], pos?\|on?, fb?, fault}` | ≤ 16; `pos` ∈ `closed, closing, open, opening, cmd_closed, cmd_open, unknown`; `medium` (`water\|gas`) yalnız vanada; `fb` yalnız vanada: `true` = geri bildirim KAPALI, `false` = açık, `null` = geri bildirim yok / henüz okunmadı; siren/fan/generic `on` taşır |
| `safety` | `{policy:"on"\|"off", mode:"normal"\|"safe", reason?, zones:[{id, st, kind?, aid?, since?, since_up, silenced, srcs[]}]}` | **`zones[]` yalnız NORMAL OLMAYAN bölgeleri listeler; listede olmayan bölge `normal`dır** (tüketiciler yokluğu normal saymalı; sunucu `zoneNormal`, uygulama `SafetyState.zoneStatus`). Yokluk ancak liste **tam** ise kanıttır: `zones` dizi değilse ya da bir öğe düşürüldüyse (bilinmeyen `st`, geçersiz öğe, sınır aşımı) sunucu özete `zones_complete:false` yazar ve listede olmayan bölgenin alarm satırına dokunmaz (inceleme turu 2). `st` ∈ `latched, fault, test`; `aid` ≤ 14 karakter; `mode:"safe"` iken `reason` ∈ `cfg_corrupt, latch_orphan, crash_loop` |

**`cmd` ekleri.** Yeni komutların HEPSİNDE `uid` zorunludur (`cmd` ev konusuna gider, evdeki bütün panolar alır); yoksa `bad_cmd`, eşleşmezse komut **sessizce** yok sayılır.
Eylemci komutu `state` (boolean) yerine `to` kullanır:
```json
{ "actuator": "a1", "to": "closed", "uid": "AHBU-S3-…", "id": "c81f" }        // vana: closed | open
{ "actuator": "a2", "to": "on", "uid": "AHBU-S3-…" }                          // siren/fan/generic: on | off
{ "cmd": "alarm_ack", "zone": 1, "aid": "9f3a11c0-3", "uid": "AHBU-S3-…" }   // aid bayatsa stale_ack, hiçbir şey susturulmaz
{ "cmd": "alarm_test", "zone": 1, "uid": "AHBU-S3-…" }
{ "cmd": "event_ack", "eids": ["9f3a11c0-3"], "uid": "AHBU-S3-…" }          // YALNIZ backend; ≤ 8 eid
```
- Vana `open` yalnız şu durumda kabul edilir: güvenli kip yok; vananın bütün bölgeleri `normal`; o bölgelerde vananın akışkanına uyan bütün sensörler `ok` ve boşta. Aksi `zone_latched` / `zone_test` / `safe_mode`.
  **Gaz vanası** hiçbir uzak yoldan açılmaz (`gas_local_only`); yalnız panodaki `GAS_RESET` DI'sinden. `closed`/`off` her zaman ve her yoldan serbesttir.
- `safety_arm`, `climate_target`, `scene_run`: ilgili modüle kadar `unsupported`. **Faz 2 (firmware 1.2.1, `caps` `intrusion`):** `{"cmd":"safety_arm",
  "mode":"away"|"home"|"off","uid","id"?}` (sunucu yalnız `caps` `intrusion` ilan eden panoya gönderir; §1.5e). `state.safety.arm` `{mode, st, ok,
  until_up?, aid?, srcs?}`; olaylar `intrusion_alarm`, `intrusion_cleared`, `arm_changed` (alan listeleri §1.5e ve tasarım F2.B.7).
- sys konusu aynı `cmd` anahtarını kullanır: `{"cmd":"cfg_get"|"cfg_patch","module":"safety","uid":…}`; sys yük sınırı 1024 bayt (diğer konular 512).
  **Faz 2 sunucu kullanımı:** `cfg_patch` buluttan yapılandırma yazımıdır (`{cmd, module, uid, id, base_rev, set|del}`, §1.5e). Sunucu sonucu hedef `uid`'nin
  canlı state'inden okur: `last_id = id` (firmware C1 sonrası) ya da `cfg.safety.rev = base_rev + 1` (yalnız v1.2.0; R2) → uygulandı; `last_rej`
  (`cfg_conflict`, `cfg_invalid`, `zone_latched`, `cfg_storage` (C1), `busy`, 1.2.1 incelemesi: `gas_local_only`, `armed`) → ret.

**`ev/{t}/event` konusu** (cihaz → backend; `retain=false`, QoS 0 + uygulama düzeyinde onay):
```json
{ "v":1, "uid":"AHBU-S3-…", "eid":"9f3a11c0-3", "bn":"9f3a11c0", "boot":57, "n":3, "type":"alarm_raised", "zone":1, "kind":"water",
  "srcs":["d3"], "at":1791273000, "at_up":3000, "actions":[{"a":"a1","do":"close"},{"a":"a2","do":"on"}] }
```
- Alan sırası ve biçimi `EventOutbox::toJson` ile sabittir: `v, uid, eid, bn, boot, n, type, zone?, kind?, aid?, srcs?, <türe özel>, at?, at_up, actions?`. `kind` çoklu türde öncelikle `gas > smoke > water`.
- **Alarm kimliği (`aid`):** `alarm_raised`'da alarm kimliği olayın kendi `eid`'sidir (`aid` alanı yazılmaz). Kilitli bölgeye YENİ tehlike türü eklenirse (ör. su alarmı sürerken gaz) firmware yeni bir `alarm_raised` üretir: bölgenin alarm kimliği bu olayın `eid`'si olur, `kind` bölgenin bütün türlerinin öncelikli olanıdır (gaz > duman > su), susturma/onay sıfırlanır; eski `aid` ile onay `stale_ack` alır, sunucu eski satırı `cleared_by=superseded` ile kapatır (inceleme E2E-2); `valve_fault`, `valve_fault_cleared`, `alarm_silenced`, `alarm_cleared` olayları bölgenin güncel alarm kimliğini `aid` ile taşır (sunucu alarm satırını bununla bulur; yoksa bölgenin açık alarmı). Test bölgesi ve bölgesiz olaylarda yoktur.
- Türe özel alanlar: `test_result` → `zone`, `ok`, `fb_ms` (**yalnız** geri bildirimli vanada ölçüldüyse; yoksa alan yok = "gözle doğrulayın");
  `safe_mode` → `reason` (`cfg_corrupt|latch_orphan|crash_loop`); `policy_changed` → `policy`, `via` (`cli|lan|cloud|local_web`); `cfg_conflict` → `rev`, `crc`; `nvs_fail` → `key`.
- Türler: `alarm_raised`, `valve_fault`, `valve_fault_cleared`, `alarm_silenced`, `alarm_cleared`, `test_result`, `sensor_fault`, `sensor_fault_cleared`,
  `actuator_fault`, `safe_mode`, `nvs_fail`, `policy_changed`, `actuator_changed`, `cfg_conflict`. `cfg_dump` olay DEĞİLDİR (outbox dışı, onaysız, parçalı ≤ 3,5 KB).
- `eid = <bn>-<n>`; `n` açılış başına 1'den, 99999'dan sonra 1. Backend `(device_id, eid)` ile tekilleştirir ve her alışta (yineleme dahil) `event_ack` gönderir.
- Yeniden deneme: 5, 10, 20, 40 sn, sonra 60 sn'de bir; aboneliğin ilk 1500 ms'inde yayın yok. Tampon 16 olay (RAM; yeniden başlatmada kaybolur → kilit state'te `safety.zones[].aid` ile görünür, backend state'ten uzlaştırır).
- Taşma: önce en eski `actuator_changed`, sonra en eski `*_cleared`, sonra alarm dışı en eski; yalnız alarm kaldıysa en eski alarmın üstüne yazılır.
- **Boyut (ölçülen):** en kötü durum (8 kaynak, 16 eylem, 20 karakter `uid`) **641 bayt** (spec'teki "≤ 400 B" tahmini tutmadı); köprü sınırı 4 KB'nin altında. Firmware arabelleği 768 B.
- **ACL:** cihaz `ev/{t}/event`'e yayın yapar (migration 033); uygulama kimlikleri abone OLMAZ.

**Yerel HTTP (LAN; aynı gövde, `uid` isteğe bağlı):** `POST /api/actuator`, `POST /api/alarm/ack`, `POST /api/alarm/test`,
`GET /api/events?after=<eid>`, `GET|POST /api/safety/config`; yanıt `{ok, id, rej?}`. **Karar 7.2b-7:** yerel anahtarla politika KAPATILAMAZ ve eylemci SİLİNEMEZ (yalnız ekleme/sıkılaştırma);
gevşetme yalnız seri CLI ya da bulutta owner/servis rolüyle. **Karar 7.2b-10:** güvenli kipten çıkış (`force` onayı) yalnız fiziksel erişimle: seri CLI `SAFETY ACK FORCE` ya da `ALARM_ACK` DI'si 5 sn basılı; LAN ve buluttan gelen `force` `safe_mode` ile reddedilir. Kilit varken `/api/system/reboot`, `/api/system/reset` `409 zone_latched` (`force=1` ile geçilir).

**Pano davranışı (özet; ayrıntı spec §5.1):** ıslak (onaylı) → bölge `latched`, akışkana uyan vanalar kapanır (duman vana kapatmaz), siren + kart buzzer'ı; ACK ıslakken yalnız susturur;
ACK + `dry_hold` (vars. 10 sn) kesintisiz kuruluk → `normal`, **vana kapalı kalır**. Kilit NVS `ahbu_latch`'te güvenli röle maskeleriyle tutulur; fabrika sıfırlaması bu ad alanını SİLMEZ;
yapılandırma bozuk/silinmişse pano güvenli kipte açılır ve kilit maskesini uygular. Bütün kararlar panoda, buluttan bağımsız verilir (K5).

**Gerçekleşen ayrıntılar (v1.2.0).** Çelişkide kod esastır (`src/MqttManager.cpp`, `src/WebPortal.cpp`, `src/safety/*`).
- **`uid`.** Düz v:2 komutlarında (`relay`, `shutter`, `cmd:toggle` ...) `uid` isteğe bağlıdır; verilir ve panonunkiyle eşleşmezse komut
  sessizce yok sayılır. Ayrıştırılamayan komut, `id`'si geçerliyse ve `uid` yoksa ya da eşleşiyorsa `last_rej = bad_cmd` yazar; kuyruk
  doluysa `busy`. Komut bayrak maskesi 17 alan nedeniyle `uint32_t`'dir.
- **Eylemci `to` ve tür.** `closed`/`open` yalnız vanaya, `on`/`off` yalnız siren/fan/generic'e; uyuşmazsa `bad_state`. Olmayan eylemci
  `unknown_actuator`. Güvenli kipte (yapılandırma bozuk/silinmiş) eylemci tablosu kullanılmadığından `a<n>` komutları `unknown_actuator`,
  kilit maskesindeki röleye açma yönündeki düz `relay` komutu `actuator_relay` alır.
- **`cfg_get` -> `cfg_dump`** (`ev/{t}/event`, retain yok, onaysız): `{"v":1,"uid","type":"cfg_dump","module":"safety","rev","crc",
  "part":k,"parts":n, ["policy":{"on","dry_hold_ms"},"zones":[{"id","name"}],"lights":[{"relay","dimmable","src","addr","ch"}]],
  "sensors":[...],"actuators":[...]}`; politika/bölge/ışık yalnız 1. parçada, her parça ≤ 3500 bayt; `body` sarmalayıcısı YOKTUR
  (öğe dizileri köktedir; `sensors`/`actuators` her parçada bulunur, boş olabilir). Sunucu parçaları `(device, module, rev, crc)` ile
  toplar, TEK belgeye birleştirir (`mergeCfgDumpParts`: baş parçadan politika/bölge/ışık, sırayla sensör ve eylemciler) ve
  `device_configs.body`'ye yazar; uygulamaya `GET …/devices/:id/safety-config` (§1.5d) ile verir. Sensör öğesi
  `{"id":"d3","kind","zone","active_open":0|1,"flags","confirm_ms","name"}`; eylemci öğesi `{"id":"a1","relay",["relay2"],"kind",
  "close_mode":"energize"|"deenergize"|"pulse","medium":"water"|"gas"|"none","zones":[...],"fb_di","fb_closed_active","fb_timeout_s",
  "run_limit_s","exproof","name"}`. Sensör kind'ları ayrıca `alarm_ack`, `valve_close`, `gas_reset` (yerel kumanda rolleri) olabilir.
  **Faz 2 (firmware 1.2.1, `caps` `intrusion`):** 1. parçada `policy`'den hemen sonra `"intrusion":{"exit_s","entry_s"}` (saklanan ham değer;
  0 = varsayılan 45 / 30 sn); sunucu bu anahtarı kopyada korur (`mergeCfgDumpParts`; v1.2.0 kopyasında anahtar yoktur) ve
  `GET …/safety-config` ile uygulamaya verir. Ek kumanda rolü `arm_key` (anahtarlı kontak; state `sensors[]`'te de bu adla görünür).
  Sensör `flags` ek bitleri `0x08` giriş yolu (SF_ENTRY), `0x10` yalnız dışarıda (SF_AWAY_ONLY); `flags` verilmeyen yeni sensörün
  varsayılanı: kapı `0x09`, hareket `0x11`, gaz `0x05`, diğerleri `0x01` (v1.2.0: kapı/hareket `0x01`).
- **`cfg_patch` / `POST /api/safety/config` gövdesi** (tek öğe): `{"base_rev"?:N, "set":{"sensor"|"actuator"|"policy"|"zone"|"light"|"intrusion":{...}}}`
  (`intrusion` yalnız 1.2.1+: `{"exit_s"?:0..255,"entry_s"?:0..255}`, en az biri)
  ya da `{"base_rev"?:N, "del":{"sensor":"d3"}|{"actuator":"a2"}}`; öğe alanları `cfg_dump` ile aynıdır (eksik isteğe bağlı alanlar
  türün varsayılanını alır; `id`'siz eylemci yeni satırdır). Eylemci silinince sonraki eylemcilerin kimliği bir kayar (`a3` -> `a2`).
  Sıra: yama -> `validate(system, safety)` -> kilitli bölge kuralı -> (LAN ise) gevşetme yasağı -> `rev+1` -> NVS -> loopTask uygulaması.
  Çalışırken eklenen su vanasının konumu o anki röle seviyesinden benimsenir (yapılandırma vanayı kendiliğinden açıp kapatmaz).
  Bulut sonuçları: başarı -> state `cfg.safety.rev` artar (1.2.1+: ayrıca `state.last_id` = yamanın `id`'si, otomasyon yeni bir komut
  işleyene kadar); `base_rev` uyuşmazlığı -> `cfg_conflict` olayı + `last_rej = cfg_conflict`; geçersiz -> `cfg_invalid`; kilitli bölgeye
  dokunuyor -> `zone_latched`; NVS payı yetmedi -> `cfg_storage` (1.2.1+; v1.2.0'da `busy`). **Faz 2 incelemesi (G-1, 1.2.1):** bulut yolu
  gevşetebilir ama iki sınıfı uygulayamaz: `isGasRelease` (mevcut gaz vanasının röle(ler)/tür/kip/akışkan kimliğini değiştirmek ya da onu
  silmek; `gas_reset` satır kuralı) -> `gas_local_only` (her zaman); `isIntrusionLoosening` (SF_REACT'li kapı/pencere/hareket sensörünü silmek
  ya da alarm dışı bırakmak, `SF_ENTRY`/`SF_AWAY_ONLY` eklemek, NC->NO, onay süresini ya da etkin çıkış/giriş gecikmesini uzatmak, `arm_key`
  satır kuralı) -> `armed` (yalnız kip ≠ `off`). Seri CLI ikisinde de serbesttir; LAN'da hırsız ayarları B.3 gereği serbest kalır.
  **RV-E3:** `arm_key` satırı yalnız NC: `active_open = 0` -> `cfg_invalid` (`detail: arm_key_not_nc`; kablo kesilince kurulu okunur).
- **Gevşetme (LAN'dan yasak, karar 7.2b-7):** politika kapatma, `dry_hold_ms` kısaltma, tehlike sensörünü (su/gaz/duman) silme ya da
  türünü/bölgesini değiştirme, `SF_REACT`/`SF_FAULT_CLOSE` bayrağını kaldırma, onay süresini uzatma, NC->NO; eylemciyi silme, rölesini/
  türünü/kipini/akışkanını değiştirme, bölge çıkarma, geri bildirimi kaldırma/değiştirme ya da zaman aşımını uzatma, siren süresini kısaltma,
  fanı ex-proof işaretleme; mevcut satırı `gas_reset`'e çevirme ya da `gas_reset`'in bölgesini değiştirme; **daha önce herhangi bir satırda
  kullanılmış bir DI'ye yeni `gas_reset` ekleme** (kalıcı DI kullanım geçmişi NVS `ahbu_latch/di_hist`, fabrika sıfırlaması silmez; sil +
  yeniden ekle yolunu kapatır). Hiç kullanılmamış girişe yeni `gas_reset` (sihirbaz) serbesttir. **Faz 2 (1.2.1):** `arm_key` aynı DI
  geçmişi kuralıyla korunur (mevcut satırı `arm_key`'e çevirmek ya da kullanılmış DI'ye yeni `arm_key` gevşetmedir; bölgesi anlamsızdır,
  değişimi gevşetme değildir). Kapı/pencere/hareket sensörleri, `SF_ENTRY`/`SF_AWAY_ONLY` bayrakları, hırsız gecikmeleri ve diğer yerel
  kumanda rolleri serbesttir.
- **LAN gövdeleri (birebir).** `POST /api/actuator {actuator, to, uid?, id?}` (`state` DEĞİL), `POST /api/alarm/ack {zone, aid?, force?, uid?, id?}`,
  `POST /api/alarm/test {zone, uid?, id?}`, `POST /api/arm {mode:"away"|"home"|"off", uid?, id?}` (1.2.1+; ret `not_ready|bad_state|safe_mode`). Bilinmeyen alan `400 unknown_field`; diğer 400 kodları `invalid_actuator`, `invalid_value`,
  `invalid_zone`, `invalid_aid`, `invalid_id`, `uid_mismatch`.
- **LAN yanıtları.** `POST /api/actuator`, `/api/alarm/ack`, `/api/alarm/test`: `200 {"ok":true,"id"}` ya da `200 {"ok":false,"id","rej"}`;
  1 sn içinde sonuç yoksa `504 {"error":"timeout","id"}`; kuyruk dolu `503 queue_full`; `id` verilmezse `lan-...` üretilir.
  `GET /api/events?after=<eid>` -> `{"bn","events":[olay JSON'u...],"more":bool}` (en çok 16; bilinmeyen/başka açılışın eid'i -> baştan).
  Halka 32 olaydır: `more:true` ise istemci son eid ile devam eder (uygulama en çok 4 sayfa okur, yinelenen eid'i atar). `GET /api/safety/config`
  -> `{rev, crc, policy, intrusion?, zones, lights, sensors, actuators}` (cfg_dump öğeleriyle aynı alanlar, adlar dahil; `intrusion` 1.2.1+).
  `POST /api/safety/config` -> `200 {"status":"ok","rev","crc"}` | `400 {"error":"cfg_invalid","detail"}` (`detail` ör. `arm_key_not_nc`) | `403 local_loosen_forbidden`
  | `409 {"error":"cfg_conflict","rev","crc"}` | `409 zone_latched` | `500 storage_error` | `503 busy`.
  `POST /api/config`: güvenlik yapılandırmasıyla uyuşmazsa `409 {"error":"cfg_invalid","detail"}` (kilit varken `409 zone_latched`).
  Açılış güvenli maskesindeki (`safe_msk`) ya da kilit maskesindeki röle, güvenlik tablosu boş olsa bile (güvenli kip `cfg_corrupt`)
  panjur/darbe rölesine çevrilemez: `detail` = `act_relay_shutter` / `act_relay_impulse` (inceleme turu 2).
- **Kurulum sihirbazının yazımı (uygulama).** Sihirbaz panonun yapılandırmasını okur (`GET /api/safety/config`) ve planı **tek öğelik**
  yamalara çevirir (`buildSafetyPatches`): sensör silme -> eylemci silme (büyük kimlikten; silme sonraki kimlikleri kaydırır) ->
  mevcut eylemci güncelleme (kaydırılmış kimlikle, panodaki ad/`fb_timeout_s` gibi alanlar korunur) -> yeni eylemci (kimliksiz) ->
  sensör ekleme/güncelleme -> ışık seçenekleri. Yalnız değişen öğe yazılır. Her istek bir öncekinin yanıtındaki `rev`'i `base_rev`
  olarak taşır (`applySafetyConfigPatches`). Eşleme: iki röleli vana `close_mode:"pulse"`, `relay2` = açma rölesi, `run_limit_s` =
  darbe süresi; `fb_di` `0` = geri bildirim yok; fan `exproof`; ışık `src` `1` = Modbus, `2` = köprü (`addr`, `ch`).
  Ham RS485 (`/api/rs485/relay`, `/api/rs485/send`) eylemci kanalını açma / toplu yazım / TOGGLE: `409 actuator_relay`; güvenlik etkinken
  (kilit ya da ek modülde eylemci/sensör) `POST /api/rs485/scan`: `409 safety_active`. `GET /api/status` (anahtarlı) MQTT state ile aynı
  ek alanları ve rölelerde `act`'ı taşır.
- **Seri CLI** (fiziksel erişim): `SAFETY [STATUS]`, `SAFETY TEST <1-4>`, `SAFETY ACK [0-4] [FORCE]`, `SAFETY POLICY ON|OFF`,
  `SAFETY DEL <aN|dN|bN>`, `REBOOT FORCE` (kilit varken düz `REBOOT` reddedilir).

## 3. Firmware yerel HTTP API (LAN / AP)

- Kimlik: `X-Device-Key: <local_key>`. `local_key` 8–32 karakter, NVS'te saklanır. Sunucuda şifreli tutulur (`devices.local_key_enc`, AES-256-GCM, `LOCAL_KEY_SECRET`).
  Sunucu anahtarı değiştirmek istediğinde (acil sıfırlama) pano erişilemiyorsa `devices.local_key_enc` panodaki gerçek anahtar olarak kalır; yenisi `local_key_pending_enc`'de bekler ve pano buluta bağlanınca `sys set_local_key` ile iletilip takas edilir (§1.5b; `GET …/local-key` her zaman geçerli anahtarı döner). Etiket yeniden üretimi sahipsiz kayıttaki bekleyeni temizler (migration `032` tetikleyicisi); claim ve pano değişimi bekleyene dokunmaz (envanterdeki gerçek anahtarı kullanır).
- **CORS başlığı yoktur.** JSON gövdeli POST'larda `Content-Type: application/json` zorunlu.
- Anahtarsız / yanlış anahtar: `401 {"error":"unauthorized"}`. 5 yanlış deneme → 60 sn `423 {"error":"locked","retry_after":60}`.
- Anahtarsız erişilebilen tek uç: `GET /api/status` **kısıtlı** özet → `{ "device":…, "name":…, "fw":…, "provisioned":bool, "wifi_connected":bool }`. **TEK İSTİSNA (§3d):** Wi-Fi servis akışı uçları (`GET /api/wifi/scan`, `POST /api/wifi/connect`, `GET /api/wifi/status`) **AP kaynaklı** anahtarsız erişime de açıktır (istemci SoftAP arayüzünde + AP şu an WPA2 + geçerli `ap_pass` + cihaz provizyonlu); diğer HER uç yalnız anahtarla çalışır.
- **Provizyonsuz cihaz** (`local_key` boş): yalnızca `POST /api/factory/init` `{ "local_key", "ap_pass" }` ve kısıtlı `status` çalışır; diğer her uç `403 {"error":"unprovisioned"}`. DI / MQTT yolu etkilenmez.
- `POST /api/factory/init` yalnızca `local_key` boşken çalışır. Sonradan değiştirmek için `POST /api/auth/rekey` (mevcut anahtarla).
  Firmware 1.1.2+ (SERVIS-04): denetim yazmayla aynı kilit altındadır (`ConfigManager::provisionIfEmpty`, seri `FACTORYINIT` ile ortak yöntem): gövde ayrıştırılırken seri yoldan anahtar yazıldıysa istek `403 already_provisioned` alır, yazılan anahtar ezilmez. Yazım sırası önce `ap_pass`, sonra `local_key`; `local_key` yazılamazsa `ap_pass` önceki değerine geri alınır ve `503 storage` döner (cihaz provizyonsuz kalır). Baştaki kilitsiz denetim yalnız hızlı rettir.
- `POST /api/mqtt/config` `{ server, port, user, pass }` (anahtarlı) — cihaz bulut kimliğini buradan alır. **Derleme içinde varsayılan MQTT kimliği yoktur**; kimlik yoksa MQTT başlamaz, cihaz yerelde çalışır.
- **`pair` parametresi 1 tabanlıdır** (`/api/relay?pair=2&cmd=up`). `cmd=pos` için `val=0..100` zorunlu; yoksa `400`.
- Hatalı girdi `400 {"error":"…"}`; başarı `200 {"status":"ok"}` / kuyruğa alındıysa `{"status":"queued"}`. Bilinmeyen komut `400` (200 değil).
- AP (kurtarma/yerel kurulum) **adı `AHBU-<STA MAC son 6 hex, büyük harf>`**, parolası **cihaza özeldir** (`ap_pass`, NVS, WPA2). Sabit/varsayılan kurtarma adı veya parolası **YOKTUR** (eski sabit değerler kaldırıldı; firmware, tarayıcı sayfası, uygulama ve belgelerin hiçbirinde geçmez). Cihaz Wi-Fi'ye bağlandığında AP kapanır; yalnızca bağlantı kaybı veya servis modunda süreli (10 dk) açılır.
- Seri CLI'da `RESETKEY` komutu: fiziksel erişimle `local_key`'i temizler (kilitlenme durumunda kurtarma yolu). Yeniden anahtarlama tercihen aynı seri hattan `FACTORYINIT` ile, yedek olarak açık kurulum AP'si üzerinden `POST /api/factory/init` ile yapılır (§3c).

## 3b. Firmware'in gerçekleşmiş davranışı ve sözleşmeden sapmalar (FW-net, 2026-10-01)

**MQTT (§2'ye ek/sapma):**
- Cihaz `state` ve `status`'u **QoS 0** yayınlar (PubSubClient yalnız QoS0 yayınlar); yalnızca LWT QoS 1 retained `offline`. "status QoS1" beklentisi gevşetildi; kayıp, 30 sn kalp atışı ve ~0.4 sn'lik değişiklik gözcüsüyle telafi edilir.
- `sys` yükü tam şekli: `{"cmd":"set_local_key","local_key":"<8..32 ASCII 0x21-0x7E>","id":"…"?}` (`key` takma ad olarak kabul edilir). Backend `local_key` adını kullanır.
- `cmd` `id`'si: 1..24 karakter `[A-Za-z0-9._:-]`; son 8 id tekilleştirilir; kuyruk doluysa id kaydedilmez.
- `state` (§2.4): `last_id` boşsa **alan hiç yoktur**; `shutters[]` yalnızca yapılandırılmış (YUKARI+AŞAĞI) çiftleri içerir; `relays[].type` metindir (köprü durum güncellemesinde kullanmaz; yerleşim eşitleme §2.4b bu alanı ve `name`'i kullanır); JSON havuzu öğe sayısından hesaplanır, taşarsa yayın yapılmaz.
- Kimlikler: `uid = "AHBU-S3-" + <STA MAC son 3 bayt, 6 hex, büyük harf>` (fabrika aracının UID'si ve etiket adı aynı kuralla üretilir); MQTT `clientId = "ESP32S3_<12 hex MAC>"`.
- TLS: sertifika doğrulaması **açık** (`CaCerts.h`: ISRG Root X1 + X2), saat senkronu (`time() > 1.7e9`) olmadan TLS denenmez, yalnızca yaprak sertifikanın tarihi denetlenir. **MQTT sunucusu DNS adıyla verilmelidir (IP olmaz)**; sunucu zinciri ISRG dışı bir köke taşınırsa tüm cihazlar bağlanamaz.
- Kimlik yoksa/devre dışıysa MQTT **hiç başlamaz** (yalnız yerel çalışma). Eski `home_*` paylaşılan kimlik ilk açılışta NVS'ten silinir.
- Planlı yeniden başlatma öncesi `offline` yayınlanır.

**Yerel HTTP API (§3'e ek):**
- `GET /` (statik arayüz sayfası) anahtarsız herkese açıktır; "tek anahtarsız uç" ifadesi **API** içindir (`GET /api/status` kısıtlı özet).
- Hata kodları: `400` `invalid_*` / `unknown_command` / `empty_body` / `invalid_json` / `bad_host`; `401 unauthorized`; `403` `unprovisioned` | `already_provisioned` | `bad_origin`; `409 busy` (panjur hareketliyken config); `413 too_large`; `415` Content-Type yok; `423 locked` (+`Retry-After`); `429 rate_limited` (+`Retry-After`; **yalnız** AP kaynaklı anahtarsız `POST /api/wifi/connect`, §3d); `502` RS485; `503` `busy` | `queue_full` | `storage` (`storage` = biçim geçerli ama yerel anahtar / AP parolası NVS'e yazılamadı: `POST /api/factory/init` ve `POST /api/auth/rekey`, firmware 1.1.2+ (SERVIS-03; önceden `400 invalid_key` / `500 storage_error`); factory/init'te cihaz provizyonsuz kalır, rekey'de eski anahtar geçerli kalır. Biçim hataları `400` kodlarını korur. `POST /api/config`, `POST /api/wifi/disconnect`, `POST /api/rs485/baud` ve `POST /api/system/reset` NVS hatasında hâlâ `500 {"error":"storage_error"}` döner; istemci ikisini aynı iletiye eşler).
- Şekiller: `POST /api/child-lock {"enabled":bool}` → `200 {"status":"queued"}`, `GET` → `{"child_lock":bool}`; `POST /api/wifi/connect` → `200 {"status":"connecting"}`, sonuç `GET /api/status` içindeki `wifi_connect_state` (`idle|connecting|success|failed`) ve `wifi_connect_reason`; `GET /api/wifi/scan` → `{"status":"scanning"}` | `{"status":"done","cached":bool,"networks":[{ssid,rssi,enc}]}`; **YENİ** `GET /api/wifi/status` → `{wifi_connect_state,wifi_connect_reason,wifi_connected,wifi_sta_ssid,wifi_sta_ip,wifi_rssi,ap_active}` (§3d); `POST /api/system/reboot` → `{"status":"rebooting"}`; `/reset` → `{"status":"reset_ok"}`.
- Anahtarlı tam `GET /api/status` alanları: `device,name,device_name,fw,provisioned,ip,wifi_rssi,uptime_sec,wifi_connected,wifi_sta_ssid/ip/rssi,wifi_ap_active/ip/ssid,wifi_last_reason,wifi_connect_state/reason,time_synced,mqtt_configured,mqtt_connected,ext_module_enabled/channels/address/responding,total_relays,total_dis,child_lock,last_id,relays[],shutters[] (pair,is_shutter,is_moving,moving,dir,pos,target),dis[]`. LAN `status` içinde `uid` yoktur (cihaz kimliği `device` alanında); `relays[].runtime_sec` status'ta yok (config'te var).
- Host allow-list: yalnız IPv4 sabiti / `localhost` / `*.local`; Origin varsa Host ile aynı olmalı (DNS-rebinding savunması). CORS başlığı yoktur.
- `POST /api/rs485/relay` panjur kanalını ve `channel=0` toplu AÇMAYI reddeder (kapatma serbest); `POST /api/rs485/scan` bloklamaz (`202` + `GET` yoklama).

**Provizyon sırası (fabrika/servis):** flash → provizyonsuz cihaz **açık** kurulum AP'si `AHBU-<MAC son 6>` yayınlar (10 dk; istemci bağlıyken en fazla 30 dk; STA tanımsızsa 15 dk arayla yeniden) →
`POST /api/factory/init {local_key (8..32 ASCII), ap_pass (8..32)}` → AP WPA2'ye döner → `X-Device-Key` ile `POST /api/wifi/connect` → `POST /api/mqtt/config {server (DNS adı), port 8884, user d_<t>, pass}`.
**Risk:** provizyonsuz pencerede yakındaki biri `factory/init` ile cihazı sahiplenebilir → fabrikada flash sonrası HEMEN provizyon yapılmalıdır; sahadaki yeniden flash'lanmış panolar için servis sihirbazı provizyonu hemen yapar. (1.1.2+: seri `FACTORYINIT` ile aynı anda gelen `factory/init` yazılan anahtarı EZEMEZ, `403`; provizyonsuz kart ise hâlâ açıktır.)

## 3c. Firmware çekirdeği: seri CLI, komut kuyruğu ve zaman kuralı (FW-core, 2026-10-01)

**Seri CLI** (115200 baud, CR/LF, en çok 159 karakter, büyük/küçük harf duyarsız; her komut `[CLI] Komut alindi: …` yankılar — İSTİSNA: `WIFI <ssid> <parola>` maskeli, `FACTORYINIT` hiç yankılanmaz):
`HELP|?` · `STATUS` (cihaz, STA, AP durumu+SSID, MQTT, `local_key` tanımlı/YOK, ek modül, röle/DI/panjur, `child_lock`, yığın su işaretleri) · `MQTT [PUB]` · `RELAY <n> [ON|OFF|TOGGLE]`, `RELAY ALL ON|OFF` ·
`SHUTTER <n> UP|DOWN|STOP|STEP|POS <0-100>`, `SHUTTER ALL UP|DOWN|STOP` · `DI|INPUTS`, `CFG|CONFIG`, `SET_DI <di> <hedef 0-N> <mod 0-4>`, `DEFAULT_DI` · `WIFI <ssid> <parola>|WIFI CLEAR` ·
`EXTMOD <0|1> [kanal]` · `SCAN [RESULT]` (bloklamayan RS485 tarama) · `CH <1-32> [ON|OFF|TOGGLE]` (ham ek modül rölesi; panjur kanalına AÇ/toplu AÇ reddedilir) · `SEND <hex>` · `BAUD <…>` ·
`CHILDLOCK [ON|OFF|STATUS]` · `AP [ON|OFF|STATUS]` (servis AP penceresi 10 dk; provizyonluysa yalnız geçerli `ap_pass` varsa; parola asla yazdırılmaz) · `FACTORYINIT <local_key> <ap_pass>` · `RESETKEY` (yerel anahtarı siler → provizyonsuz; yanıt `[CLI-SONUC] Yerel anahtar SILINDI|SILINEMEDI. Cihaz artik PROVIZYONSUZ (FACTORYINIT <local_key> <ap_pass> ya da /api/factory/init). AP gerekirse: AP ON`, firmware 1.1.2+; önceden "yalnizca /api/factory/init" diyordu, SERVIS-06) · `REBOOT|RESTART`.

**`FACTORYINIT <local_key> <ap_pass>` (USB-seri provizyon; fabrika aracının tercih ettiği yol — anahtar açık AP'den DÜZ HTTP ile gitmez):**
satır ve parametreler asla yankılanmaz/loglanmaz; seri çıktıda yalnızca `OK factory_init` · `ERR already_provisioned` (cihazda `local_key` varsa; ayrıştırmadan ÖNCE denetlenir, hiçbir şey değişmez) · `ERR invalid_local_key` (8..32 karakter ASCII 0x21–0x7E) ·
`ERR invalid_ap_pass` (8..32 karakter ASCII 0x20–0x7E; satırın geri kalanı, iç boşluk olabilir) · `ERR persist_failed` (NVS yazılamadı; cihaz provizyonsuz KALIR, yeniden denenebilir). Önce `ap_pass`, sonra `local_key` yazılır; `local_key` yazılamazsa `ap_pass` önceki değerine geri alınır ve cihaz provizyonsuz kalır. Denetim + yazma `ConfigManager::provisionIfEmpty` içinde TEK kilit altındadır ve HTTP `POST /api/factory/init` aynı yöntemi kullanır (firmware 1.1.2+): iki yol yarışamaz, ikinci yazan `already_provisioned` alır.

**Komut kuyruğu:** tam **FIFO** (uzunluk 24; yalnız `SmartAutomation::loop()` boşaltır, tur başına en çok 12 komut). Aynı turda gelen "YUKARI, DURDUR" sonunda durur; "DURDUR, YUKARI" ise hareket eder → komutlar **geliş sırasıyla** postalanmalıdır.
Kuyruk doluyken gelen STOP kaybolmaz (acil durdurma bayrağı); `postDeviceCommand` `false` döner (çağıran loglar/503 `queue_full`). DI olayları kuyruktan bağımsız aynı yürütücüye satır içi girer. `SmartAutomation::setChildLock()` public yöntemi **kaldırıldı** (yalnız `CmdType::SET_CHILD_LOCK`).

**RS485 tarama:** `rs485StartScan()` ek modül panjuru hareket halindeyse `false` döner (web `503 busy`); tarama sürerken ek modül panjur HAREKET komutları reddedilir (DURDUR serbest); tarama hattı saniyelerce tutar.
**Ek modül (RS485) istenen durum kuralları (F12):**
(1) `POST /api/rs485/relay` TOGGLE (`action=2`): sonuç "bilinmiyor"dur; röle geri KAPANMAZ, durum sonraki coil okumasında (bir döngü içinde) benimsenir; benimseme beklerken gelen AÇIK komut (MQTT/Web/CLI/DI: `RELAY_SET`/`RELAY_TOGGLE`/`ALL_LIGHTS_OFF`) benimsemeyi iptal eder — kullanıcının SON komutu kazanır.
(2) **Ham tek-coil yazımı** (`POST /api/rs485/send` HEX `0x05`, CLI `SEND`): yapılandırılmış ek modül adresine ve yankısı DOĞRULANMIŞ ise uygulama istenen durumunu günceller (kalıcı; MQTT `state`'e yansır; coil yoklaması geri almaz): ON/OFF → `RELAY_SET`, TOGGLE (`0x5500`) → `RELAY_TOGGLE` (`CmdSource::WEB`); toplu KAPAT `0x00FF` → tüm ek röleler istenmeyen + ek panjurlar durur;
panjur kanalına ham KAPAT = panjuru durdurur; panjur kanalına ham AÇ/TOGGLE ve toplu AÇ REDDEDİLİR (mevcut kural); darbe kanalına ham AÇ = süreli darbe; başka slave'e veya modül kapalıyken yazım uygulama durumunu etkilemez; yansıtılan komut kısa bip verebilir. Komut kuyruğu doluysa yazım modülde uygulanır ama yansıtılamaz → RS485 günlüğüne `[UYARI] Ham yazim modulde uygulandi ama uygulama durumuna yansitilamadi (komut kuyrugu dolu)` yazılır (sonraki coil okumasıyla geri dönüş mümkündür).
**Yeniden başlatma:** `requestRestart(delayMs)` bayrak + sonraki tur; restart öncesi panjurlar durdurulur, konumlar kaydedilir, `registerPreRestartHook` kancaları (en çok 4) çağrılır.
**Anlık görüntü API'si:** `getSnapshot()/getShutterSnapshot()/getRelayMask()/getRelaySnapshot()/isChildLockEnabled()` (mutex altında kopya; `false` = mutex alınamadı → "bilinmiyor", asla "kilitsiz" değil).

**ZAMAN KURALI (kritik):** `millis()` 24,86 günde 2^31'i aşar. "Gelecekteki hedef zaman" saklayıp `(int32_t)(now - hedef) < 0` veya `NetUtil::timeReached(now, hedef)` ile karşılaştıran bir değişken, hedef ESKİ kalırsa (hiç tazelenmeyen / 0 başlangıçlı) 24,86–49,7 gün aralığında "hâlâ gelecekte" sanılır ve döngü donabilir (FW-core'da gerçekten oldu; simülasyonla bulundu). **Kural:** "son olay + bekleme süresi" çifti ve `(uint32_t)(now - son) < bekleme`, ya da "ayarlı mı" bayrağı. Yasak: işaretli karşılaştırmayla saklanmış hedef zaman.
**Uygulama ipucu (referans: `src/NetTime.h`):** her zamanlayıcıyı sahip görev **HER TUR** yoklamalı ve süre dolunca ANINDA sonlandırmalı (`armed=false`) — aksi halde 49,7 günde `uint32_t` sarmasında eski damga yeniden "taze" görünür (aliasing). `now`, zaman damgası alındıktan SONRA okunur. Zaman damgası görevler arasında PAYLAŞILMAZ (başka görev yalnız `volatile` istek bayrağı bırakır). Yeni zamanlayıcı eklenirse bu kural ve wasm32 testi (sarma tabanları 0x7FFFFFF0/0xFFFFFFF0 …) zorunludur.
Bilinen sınır: ESP-IDF 4.4'te `time_t` 32 bit → `time()>1.7e9` saat denetimi ve yaprak sertifika tarihi **2038-01-19**'da bozulur (millis ile ilgisiz; çekirdek 64 bit `time_t`'ye geçmeden önce ele alınmalı).
**Fabrika aracının bağımlı olduğu seri çıktı kalıpları (DEĞİŞİRSE ARAÇ SESSİZCE BOZULUR; değiştiren aracı da günceller):**
`STATUS` → `[STATUS] Cihaz: … (MAC: …)`, `(SSID: AHBU-XXXXXX`, `Yerel anahtar (local_key): tanimli|YOK`; `RESETKEY` → `Yerel anahtar SILINDI|SILINEMEDI`; `FACTORYINIT` → `OK factory_init` | `ERR <kod>`.
`RESETKEY` yanıt satırı ve tüm `FACTORYINIT` yanıtları (`main.cpp` `factoryInitReply` + `CliParse.h` `factoryInitErrorText`) araç testlerinde (`tests/test_serial_provision.py` `FirmwareSerialOutputContractTests`) kaynaktan okunup aracın ayrıştırıcısıyla ve sahte firmware ile karşılaştırılır; `STATUS` kalıpları hâlâ elle eşleştirilir.

**Cihaz etiketi (fabrika aracı, G3) — İKİ karekod:** (1) *Daireye bağla (uygulama)*: `https://…/claim?uid=…&pin=…` (ap_pass YOK); (2) *Kurulum Wi-Fi'sine bağlan (telefon kamerası)*: standart Wi-Fi karekodu
`WIFI:T:WPA;S:AHBU-<MAC son 6 hex büyük>;P:<ap_pass>;;` (özel karakterler `\ ; , : "` önüne ters bölü ile kaçışlanır; uygulamanın `WifiQrParser`'ı aynı kuralla çözer). Etiket 100×50 mm (203 dpi). `ap_pass` yalnız etiket metninde ve 2. karekodda bulunur (claim karekodunda ve loglarda YOK);
etiket yalnız cihaz üzerinde/elde saklanır, fotoğrafı paylaşılmaz. AP SSID kuralı (`AHBU-<MAC son 6>`), görünür SSID ve WPA2 varsayımı firmware'e bağlıdır (fabrika aracı testi firmware kaynağıyla eşliği doğrular).

**Provizyon (güncel sıra):** flash → **seri `FACTORYINIT`** (tercih) veya (yedek) açık kurulum AP'si + `POST /api/factory/init` → servis sihirbazı `wifi/connect` → `mqtt/config`.

## 3d. Wi-Fi servis akışı: AP kaynaklı yetkilendirme (FW-net / WP-W1, 2026-10-01)

**Sorun:** teknisyen müşterinin evinde panonun kurtarma ağındayken (`http://192.168.4.1`) **İNTERNET YOKTUR** → `local_key`'i sunucudan alamaz; girişsiz/PIN'siz kullanıcı için `wifi/scan|connect` anahtarla çalışmaz (canlı test listesi Aşama 16: "giriş yapılmış olsun ya da olmasın"; tarayıcı arayüzü de anahtarsız açılamazdı).
**Güvenlik modeli:** cihaza özel WPA2 AP parolasını (`ap_pass`) bilmek = fiziksel erişim (etikette; yalnız yetkili elde).

**Kural** (karar fonksiyonu `src/ApAccess.h`; wasm32/Unity testi `test/test_ap_access`; uygulama `WebPortal.cpp` `authorizeApOrKeyed()`): YALNIZ şu üç uç — `GET /api/wifi/scan`, `POST /api/wifi/connect`, YENİ `GET /api/wifi/status` — için **geçerli `X-Device-Key` YA DA şu üç koşulun HEPSİ**:
(a) **istemci SoftAP arayüzündedir:** uzak IP, `WiFi.softAPIP()`/`softAPSubnetMask()` alt ağındadır (L2 komşusu: TCP el sıkışması AP arayüzünden döner, sahte kaynak adresiyle tamamlanamaz). STA bağlıysa ve **STA alt ağı AP alt ağıyla kesişiyorsa** (ev modemi de 192.168.4.0/24 ise) ağ konumu AP/LAN ayırt ettirmez → istemci AP SAYILMAZ (kapalı başarısızlık); AP yayında değilse / adres/maske geçersizse / uzak IP cihazın kendisiyse de değildir;
(b) **AP şu an FİİLEN WPA2'dir** (`WiFiManager::isRecoveryApSecured()`: `startAp` parolayla başladıysa true, `stopAp`'ta false; yapılandırmaya DEĞİL yayındaki kipe bakılır) **ve** cihazın geçerli `ap_pass`'i vardır (≥ 8 karakter). Provizyon penceresindeki **AÇIK** kurulum AP'sinde bu yol KAPALIDIR (`factory/init` sonrası AP ~1,5 sn daha açık kalsa bile);
(c) cihaz **provizyonludur** (`local_key` tanımlı). Provizyonsuz cihazda hiçbir uç bu yolla açılmaz: yalnız `POST /api/factory/init` + kısıtlı `GET /api/status` (`wifi/*` → `403 unprovisioned`).

| Durum (provizyonlu cihaz) | scan / connect / status | Diğer HER uç |
|---|---|---|
| geçerli `X-Device-Key` (her yerden) | izin ("anahtarlı"; hız sınırı yok) | izin |
| anahtarsız/yanlış, istemci AP'de + AP WPA2 + `ap_pass` var | **izin ("AP kaynaklı")** | `401 unauthorized` |
| anahtarsız, istemci AP dışı (LAN/internet) | `401 unauthorized` | `401` |
| anahtarsız, AP **açık** (WPA2 değil) veya `ap_pass` yok | `401 unauthorized` | `401` |
| provizyonsuz cihaz (her istemci) | `403 unprovisioned` | `403` |

Röle, çocuk kilidi, `config`, `rs485/*`, `system/reboot|reset`, `mqtt/config`, `auth/*` ve `wifi/disconnect` **anahtarlı kalır** (anahtarsız AP istemcisi `401` alır); `GET /api/status` anahtarsızken yine yalnız KISITLI özettir (tam durum için anahtar şart; yanlış anahtar `401`). `factory/init` kuralları aynen. **Host allow-list, `Origin == Host`, CORS başlığı yok, JSON uçlarında `Content-Type: application/json`** kuralları AP kaynaklı yolda da AYNEN geçerlidir (tarayıcı sayfasından çapraz kaynak istek AP konumuyla yetkilenemez: `403 bad_origin` / `415`).
AP kaynaklı yolda **yanlış `X-Device-Key` hata sayacına işlenmez ve `423` kilidi yoklanmaz** (yetki anahtardan bağımsızdır; bir oracle oluşmaz). AP kaynağı olmayan istekte tüm `KEYED` kuralları (401/403/423, 5 hata → 60 sn) aynen sürer.

**Uç sözleşmesi:**

- `GET /api/wifi/scan[?refresh=1]` → `{"status":"scanning"}` | `{"status":"done","cached":bool,"networks":[{"ssid":str,"rssi":int,"enc":bool}]}` (§3b; tarama en sık 10 sn'de bir başlar, sonuç önbelleği 120 sn; SSID geçerli UTF-8'e zorlanır).
- `POST /api/wifi/connect` `{"ssid":str (1..32 bayt UTF-8), "pass":str ("" açık ağ | 8..63 bayt; alan yok/null = "")}` → `200 {"status":"connecting"}` — **bağlandı demek DEĞİLDİR** (cihaz ~0,5 sn sonra bağlanır, doğrulanınca NVS'e yazar, 25 sn'de olmazsa eski kimliğe döner). `400 invalid_ssid|invalid_password|invalid_json|empty_body`, `409 busy` (önceki deneme sürüyor), `415` (Content-Type), `429` (aşağıda).
- **YENİ** `GET /api/wifi/status` → `200 {"wifi_connect_state":"idle|connecting|success|failed","wifi_connect_reason":0..255,"wifi_connected":bool,"wifi_sta_ssid":str,"wifi_sta_ip":str,"wifi_rssi":int,"ap_active":bool}`. `wifi_sta_ssid`/`wifi_sta_ip` yalnız `wifi_connected` iken dolu (aksi `""`), `wifi_rssi` bağlı değilse `0`. **Başarı YALNIZ `wifi_connect_state == "success"`** (`failed` → `wifi_connect_reason` = `wifi_err_reason_t`; 2/15/202/204 şifre, 201 ağ yok, 0 zaman aşımı/bilinmiyor). `POST connect` kabulünden sonra durum hemen `connecting`'dir (eski `success` kalıntısı görünmez).
- **Hız sınırı** (yalnız AP kaynaklı **anahtarsız** `POST /api/wifi/connect`): GLOBAL, kayan pencere — herhangi bir 60 sn'de en çok **6** istek (geçersiz gövdeli olanlar dahil sayılır); aşılınca `429 {"error":"rate_limited","retry_after":N}` + `Retry-After: N` (N = en erken boşalacak hakkın kalan sn'si, ≥ 1). Geçerli `X-Device-Key` ile gelen istekler sınıra girmez. `scan` için mevcut tarama kapısı (≥ 10 sn) geçerlidir.
- AP kapanışı: STA 30 sn kararlı bağlanınca kurtarma AP'si kapanır; bağlanma sırasında SoftAP kanalı STA'yı izler → telefon kısa süre düşebilir. İstemci bunu **başarısızlık değil belirsiz** saymalıdır (yoklama kesilirse "doğrulanamadı"; başarı yalnız `success`).

**Uçtan uca doğrulama ve istemci eşlemesi (entegrasyon, 2026-10-02):** bu sözleşme üç bağımsız yerde AYNI kuralla uygulanmıştır ve her biri kendi testiyle kilitlidir: firmware (`WebPortal.cpp` + `ApAccess.h`; 26 rota, 3'ü `AP_OR_KEYED`), QA simülatörü (`tools/qa_stack/sim/local_api.js` + `sim/fw/ap_access.js`; istemcinin SoftAP/LAN konumu `/__sim/client-net` ile modellenir; port 8081 varsayılan örneği provizyonsuz + "ap" konumludur, `factory/init` veya `/__sim/provision` sonrası AP WPA2'ye döner ve anahtarsız wifi uçları açılır) ve Flutter (`AutomationApiService.fetchWifiStatus/awaitWifiConnection`, `WifiProvisionPanel`; sahte pano `test/ui/f_support.dart` `FakeDevice`). İstemcinin cihaz yanıtlarına tepkisi:

| Cihaz yanıtı | Flutter davranışı |
|---|---|
| `wifi/status` 200 `success` | **tek başarı koşulu**: yeşil sonuç, `wifi_sta_ip` gösterilir; telefon ev ağına geri alınır |
| 200 `failed` + `wifi_connect_reason` | hata metni (2/15/202/204 şifre, 201 ağ yok, 0 zaman aşımı, diğer: kod) + "Yeniden Dene" |
| 200 `connecting` / `idle` | beklemeye devam (en çok 40 sn, 1,5 sn aralık); süre dolarsa `timedOut` |
| en az bir okumadan sonra ağ hatası | `lostContact` = **belirsiz** (sarı uyarı; pano AP'yi kapatmış olabilir), başarısızlık sayılmaz |
| `401` | "kurulum ağına (AHBU-…) bağlı olun": AP kaynaklı yol kapalıdır (AP dışı istemci, açık AP, `ap_pass` yok, alt ağ çakışması). Anahtar sunucudan İSTENMEZ (internet yok). İSTİSNA: sonuç beklenirken en az bir okumadan SONRA gelen `401` = `lostContact` (belirsiz): pano bağlandı ve modem ağı da `192.168.4.x` ise yol bağlanma anında kapanır; başarısızlık/yetki hatası sanılmaz |
| `403 unprovisioned` | "pano henüz hazırlanmamış": Wi-Fi bilgisi bu yoldan gönderilemez; servis sihirbazı ilk hazırlığı (`factory/init`) yapar |
| `404` (`wifi/status`) | eski yazılım: `GET /api/status`'a düşer; anahtarsız AP'de kısıtlı özet `wifi_connect_state` taşımadığından başarı GÖRÜLEMEZ, yani eski v1.0.x imajları bu akışla desteklenmez (yeni imaj gerekir) |
| `409 busy` / `423` / `429` | meşgul uyarısı / kilit (yalnız anahtar yolunda) / `retry_after` (veya `Retry-After`) kadar geri sayım, gönder düğmesi o süre pasif |

Etiketteki 2. karekod (`WIFI:T:WPA;S:AHBU-<MAC6>;P:<ap_pass>;;`) **telefon kamerasıyla** okutulur; uygulama içi "Modem Wi-Fi Karekodu Tara" panonun KENDİ kurulum ağı karekodunu ev Wi-Fi bilgisi olarak KABUL ETMEZ (alanlar dolmaz, yönlendirme gösterilir). Servis kurulum sihirbazı (F) adım 5'i internetsiz ve anahtarsız yürütür (`ServiceTarget.localKey` yalnız bellekte); adım 6'da telefon ev Wi-Fi'sine döner ve yerel anahtar internetle sunucudan, SAKLAMAYAN okumayla (`cloudApi.localKey`; `localKeyFor` DEĞİL) alınır, güvenli depoya YAZILMAZ; sunucuda zaten çevrimiçi olan panoda bulut kimliği yeniden üretilmez. Kural kipten bağımsızdır (SERVIS-02): mevcut cihaz, geçici servis (PIN) oturumunda "Yeni Kurulum" ve kayıttan devam eden personel kurulumu aynı davranır ("Pano sunucuda zaten çevrimiçi: çalışan panonun bulut kimliği DEĞİŞTİRİLMEDİ."). Bellekte tek seferlik kimlik (claim / acil sıfırlama / pano değişimi yanıtı) varsa o yazılır; kimliği yalnız açık "Kimliği Yeniden Yaz" zorla yeniden üretir.

**Tarayıcı arayüzü (`GET /`):** sayfa anahtarsız yüklenir; anahtarsız kısıtlı özetten sonra `GET /api/wifi/status`'u anahtarsız sondalar: `200` → **kurulum modu** ("Kurulum modu (AP): yalnızca Wi-Fi ayarlarını değiştirebilirsiniz" bandı; yalnız "Wi-Fi (Station)" sekmesi çalışır: çevre ağlar (RSSI çubuğu + kilit; dokununca SSID seçilir ve şifre kutusuna odaklanılır), elle SSID/parola, "Modem Wi-Fi Karekodu Tara (Kamera / Fotoğraf)", bağlantı sonucu `/api/wifi/status` ile beklenir). Diğer sekmeler "Bu işlem için cihaz anahtarı gerekir" kutusu gösterir (anahtar girilirse normal arayüze geçilir). `401` → eski anahtar katmanı. Karekod çözme tarayıcının `BarcodeDetector`'ına bağlıdır; yoksa (güvenli olmayan `http` bağlamı, iOS Safari…) **sessiz yedek**: elle giriş.

**Doğrulanamayanlar (cihazda denenmedi):** gerçek SoftAP istemcisinde `remoteIP()`/alt ağ kararı ve STA+AP birlikteyken ağ yönlendirmesi; SoftAP kanal değişiminde telefon davranışı; iOS/Android tarayıcılarında arayüz; `BarcodeDetector` kullanılabilirliği. Karar mantığı (`test/test_ap_access`), hız sınırı, `WiFiManager` AP-kipi bayrağı, GERÇEK `WebPortal.cpp` yol/yetki/JSON akışı (sahte WebServer + Wi-Fi sürücüsüyle wasm32 glue testi), yol tablosu ve sayfa betiği (sahte DOM + gerçek Chrome) sentetik testlerle doğrulandı (ayrıntı: WP-W1 raporu).

## 3e. Site, kurulum şablonu ve Ethernet (2026-10-08; plan `2026-10-08-site-sablon-kurulum.md`)

Şablon biçimi, kart uygulama zarfı, hata kodları ve seri `TPL` protokolü: **`docs/contracts/template/README.md`**
(ortak örnekler `docs/contracts/template/fixtures/`). Burada yalnız uçlar ve alanlar listelenir.

**REST (sunucu, `/api/v1`; hepsi `requireServiceManager`: `service_user` + `super_user`; servis PIN oturumu 403).**
Yanıt zarfı her zamanki `{success, data}`; hata `{success:false, code, message, path?}`.

| Uç | Gövde / sonuç |
|---|---|
| `GET /sites` · `POST /sites` | Site: `id, name, address, city, district, contact_name, contact_phone, contact_email, block_count, flat_count, notes, created_at, updated_at` (+ liste satırında `flat_stats {planned, written, installed, handed_over}`) |
| `GET/PATCH/DELETE /sites/:siteId` | DELETE yumuşak (`deleted_at`); dairesine kart bağlı site silinemez (409 `SITE_HAS_DEVICES`) |
| `GET /sites/:siteId/flats` | Daire: `id, site_id, block, number, flat_type, template_id, device_uuid, status (planned\|written\|installed\|handed_over), last_write {template_id, version, via, at}` |
| `POST /sites/:siteId/flats/bulk` | `{block, from, to, flat_type?, template_id?}` → oluşturulanlar (var olan blok+no atlanır) |
| `PATCH/DELETE /sites/:siteId/flats/:flatId` | `flat_type, template_id, status, block, number` |
| `PUT /sites/:siteId/flats/:flatId/device` | `{device_uuid}` ya da `{device_uuid:null}`; kart envanterde olmalı ve başka daireye bağlı olmamalı (409 `DEVICE_ALREADY_LINKED`) |
| `GET /templates?site_id=&include_global=1` | Şablon: `id, site_id, name, flat_type, current_version, updated_at, created_by` |
| `POST /templates` | `{site_id, body}` → şablon + sürüm 1 (`body.meta.template_id/version` sunucuca doldurulur) |
| `GET /templates/:id` | güncel sürüm `{..., body}` |
| `PUT /templates/:id` | `{body}` → yeni sürüm (gövde aynıysa sürüm artmaz, mevcut döner) |
| `DELETE /templates/:id` | yumuşak; sürümler ve yazım kayıtları kalır |
| `GET /templates/:id/versions` · `GET /templates/:id/versions/:version` | sürüm listesi (`version, sha256, created_at, created_by`) · gövde |
| `POST /templates/validate` | `{body}` → `{ok:true}` ya da 422 `{code:"TEMPLATE_INVALID", error:"<şablon kodu>", path}` |
| `POST /template-writes` | `{device_uuid, template_id, version, flat_id?, via:"usb"\|"eth"\|"lan", result:"ok"\|"error", error_code?}`; `ok` ise daire `written` |
| `GET /admin/inventory/:uuid/local-key` | Ethernet yazımı için `{local_key}`; her envanter kartı (müşteri kartı dahil; kullanıcı kararı 2026-10-08); denetim kaydı + oran sınırı |

Claim (K-Ş8): kart bir daireye bağlıysa ev adı `"<site adı> <blok>-<no>"`, uç noktalar karta son yazılan şablon
sürümünden tohumlanır; WP-L eşitlemesi (§2.4b) sonrasında panoyu esas alır. Daire durumu `installed`'a geçer.

**Firmware (v1.3.0+).**
- `POST /api/template/apply` (KEYED), `GET /api/template` (KEYED) — README.md.
- Tam `/api/status` ve MQTT state yeni alanlar: `"tpl":{"id","ver"}` (yalnız şablon yüklüyse), `"eth_connected"`,
  `"eth_ip"`, `"net_if":"wifi"|"eth"|"none"`. Mevcut alanlar değişmez; `ip` etkin arayüzün IP'sidir.
- Seri: `TPL BEGIN|DATA|COMMIT|ABORT|STATUS`; `STATUS` çıktısına yeni satırlar `Ethernet: <bagli|yok> <ip>` ve
  `Sablon: <id|-> v<ver>` eklenir, eski satırlar aynen kalır (fabrika aracı ayrıştırması).
- **Kablolu Ethernet'ten gelen yerel API isteği anahtarsız ve provizyonsuz yetkilidir** (KEYED + AP_OR_KEYED; `safety/config`
  gevşetmesi serbest, seri CLI ile eşit). Wi-Fi STA / SoftAP'ten gelenler anahtarlı kalır. Kullanıcı kararı 2026-10-08.
- Ethernet bağlıyken kurtarma AP'si kendiliğinden açılmaz; MQTT ve SNTP Wi-Fi ya da Ethernet'ten çalışır; UID Wi-Fi MAC'ten.

## 3f. Panonun bulut kimliğini kendisi alması (bootstrap, 2026-10-08)

Amaç: ev sahibinin kendi sahiplendiği (ya da yalnız Ethernet'le bağlı) pano, servis sihirbazının 6. adımı olmadan buluta
bağlansın. Pano yerel anahtarıyla imzalı istekle kendini kanıtlar; sunucu sahiplenilmiş panoya MQTT kimliği verir.

**İstek** (pano → sunucu, HTTPS 443, MQTT sunucusuyla aynı alan adı; JWT YOK):
`POST /api/v1/devices/bootstrap`
```json
{"device_uuid":"AHBU-S3-DD8754","ts":1791460000,"nonce":"<32 hex>","fw":"1.3.0","sig":"<64 hex>"}
```
`sig = hex(HMAC-SHA256(local_key, "ahbu-bootstrap/1|" + device_uuid + "|" + ts + "|" + nonce))` (ts = UNIX saniye, nonce
16 rastgele bayt). Sunucu anahtar olarak `devices.local_key_enc`, yoksa `device_inventory.local_key_enc`, ayrıca varsa
`devices.local_key_pending_enc`'i dener (sabit zamanlı karşılaştırma).

**Yanıtlar:**
- `200 {"status":"ok","mqtt":{"host","port","username","password"}}` — pano sahiplenilmiş (bir eve bağlı) ve kimlik doğru:
  sunucu cihaz MQTT kimliğini yeniden üretir (sihirbazın `mqtt-credential` ucuyla aynı mantık), denetim kaydı
  `device_bootstrap`. Pending yerel anahtarla doğrulandıysa o anahtar asıl anahtar olarak işaretlenir.
- `202 {"status":"pending"}` — imza doğru ama pano henüz sahiplenilmemiş (stokta): pano daha sonra yeniden dener.
- `401 {"code":"BOOTSTRAP_DENIED"}` — bilinmeyen kart / imza yanlış / `|now-ts| > 300` / nonce tekrarı / askıda-iptal kart.
  (Hangi nedenin olduğu söylenmez.)
- `429` — oran sınırı (kart başına saatte 6, IP başına saatte 60).

**Pano davranışı (v1.3.0):** provizyonlu + ağ (Wi-Fi ya da Ethernet) var + saat senkron + (MQTT kimliği yok **ya da** broker
art arda 3 kez `not authorized` döndü) ise bootstrap çağrılır. 200 → kimlik NVS'e yazılır (`/api/mqtt/config` ile aynı yol)
ve MQTT bağlanır. Bekleme: 202 → 10 dk, 401 → 60 dk, 429/ağ hatası → 30 dk (her başarısızlıkta en çok 60 dk). Sertifika
doğrulaması MQTT ile aynı kök sertifikalarla (ISRG). Provizyonsuz pano (yerel anahtar yok) bootstrap yapamaz.
Durum alanı: tam `/api/status` ve seri `STATUS`'ta `bootstrap: idle|waiting_claim|ok|denied|error`.

## 3g. 2026-10-08 mantık denetimi: sözleşme değişiklikleri (özet)

Ayrıntı ve bileşen ekiplerinin tam notları: `docs/denetim/2026-10-08-mantik-denetimi.md` ("Sözleşme ve belge notları").
Firmware v1.3.1, sunucu `c5f9ece` (migration `037`, `038`).

- **Yerel anahtar izi `lk_fp`:** `HMAC-SHA256(anahtar = local_key, ileti = "ahbu-lk-fp/1|" + BÜYÜK HARF UID)` çıktısının
  küçük harf hex ilk 8 karakteri; anahtarın kendisi hiçbir yere yazılmaz. Firmware yalnız provizyonluyken bildirir: tam
  `GET /api/status` `lk_fp`, MQTT state `lk_fp`, seri `STATUS` "Anahtar izi:". Sunucu state'tekini `devices.local_key_fp`'ye
  yazar; `GET /homes/:homeId/devices/:uuid/local-key` yanıtı `local_key_fp` da döndürür. Ethernet'te `auth/check` her zaman
  200 olduğundan uygulama ve servis yazılımı anahtar uyumunu bununla doğrular. Test vektörü:
  (`ABCDEFGH23456789`, `AHBU-S3-DD8754`) → `c7076562`.
- **Yerel anahtar döndürme (pano-6):** sahip/aile üyesi çıkarma, ev devri, assign-admin'in üyelik silmesi, kalan evin
  sahibinin/üyesinin hesap silmesi ve anahtarı okumuş servis oturumunun bitişi yeni anahtarı `local_key_pending_enc`'e yazar.
  Köprü uzlaştırıcısı pano canlıyken `ev/{t}/sys {cmd:'set_local_key'}` yayınlar ve state'teki `lk_fp` yeni anahtara uyunca
  takas eder (v1.3.1 öncesi panoda PUBACK sonrası). Yalnız tek panolu ev; uyumsuz izde `local_key_mismatch` denetim kaydı.
- **`ev/{t}/status` JSON:** `{"status":"online|offline","uid":"<UID>"}` (bağlantı, LWT, planlı yeniden başlatma). Sunucu
  düz metni de okur (geriye uyumlu); çok panolu evde bir panonun düşmesi diğerini çevrimdışı göstermez.
- **Provizyon durumu:** tam durumda gerçek `provisioned` (Ethernet'ten anahtarsız erişilen provizyonsuz pano `false` bildirir).
  Provizyonsuz panoda `POST /api/auth/rekey` → `403 unprovisioned`; MQTT `set_local_key` yok sayılır.
- **Komut retleri:** reddedilen genel komutlar `last_rej` üretir; `cfg.safety{rev,crc}` boş yapılandırmada da bildirilir.
- **Yeni REST uçları:** `GET /homes/:homeId/invitations` (kullanılmamış, süresi dolmamış davetler; kod dönmez),
  `DELETE /homes/:homeId/invitations/:invitationId`, `POST /admin/inventory/:uuid/clear-pin-lock` (yalnız süper kullanıcı:
  kurulum PIN deneme kilidi sıfırlanır).
- **Ortam değişkeni:** `REFRESH_RETRY_GRACE_SEC` (varsayılan 3600, 0 = kapalı, en çok 86400): yanıtı kaybolan refresh
  isteğinin tekrarı bu süre içinde oturum ailesini iptal ettirmez.
- **Migration:** `034` (huzur bildirimi `skipped_hazard`), `035` (site/şablon), `036` (bootstrap nonce), `037` (yerel anahtar
  izi ve tutarlılık), `038` (pano değişimi onarımları).

## 4. Firmware iç sözleşmesi (çekirdekler arası)

`src/DeviceCommand.h` içinde tanımlıdır. Her görev (MQTT, Web, CLI, DI) röle/panjur durumunu **doğrudan değiştirmez**;
`postDeviceCommand()` ile kuyruğa yazar. Kuyruğu `SmartAutomation::loop()` (Core 1) boşaltır. Röle sürücüsü ve panjur
durum makinesine tek bağlamdan erişilir. I2C hattı mutex ile korunur; çıkış yazmacı için RAM'de gölge kayıt tutulur.

**Değişmez kural (invariant):** hiçbir koşulda aynı panjur çiftinin YUKARI ve AŞAĞI röleleri aynı anda enerjili olamaz;
yön değişiminde en az 500 ms ölü zaman. Bu kural sürücü seviyesinde (`writeMask`) de doğrulanır.

**Sürücü seviyesi genişleme (FW-core F12; çip kendiliğinden sıfırlanırsa/röle düşerse de değişmez kural korunur):** enerjilemeye gidecek her yazımdan ÖNCE sürücü TCA9554 çıkış + yön yazmacını okur (3 deneme) ve gölgeyi fiziksel gerçeğe eşitler:
(a) **düşen röle yeniden çekilmez**; yerel panjur hareket ediyorsa/bekliyorsa DURDURULUR (`moving=false`, bilinen durum eşitlenir); (b) fiziksel olarak fazla AÇIK bulunan panjur rölesi kapatılırsa 500 ms ölü zaman o kapanma anından sayılır; (c) çip sıfırlanması (yön yazmacı sıfırlanmış) tespitinde TÜM yerel çiftler için ölü zaman tespit anından başlar (yeni panjur hareketi ≤ 500 ms gecikebilir);
(d) donanım okunamıyorsa (3 deneme) korunan panjur röleleri yazımdan ÇIKARILIR (kapanır, panjur durur) — lambalar ve yeni enerjilenecek bitler etkilenmez; (e) KAPATMA yazımı (maske 0) engellenmez/bekletilmez (öncesinde tek denemelik salt-okuma eşitleme). Ölü zaman, kapanma anı bilinmiyorsa tespit anından sayılır (muhafazakâr).
Maliyet: enerjileme yazımı başına +2 I2C okuması (~0,5 ms normal), KAPATMA başına +1; hat kilitlenirse en kötü ~+150 ms (tahmin, ölçülmedi). Yeni MQTT/HTTP alanı yoktur. Yeni seri günlük önekleri (yalnız tanı amaçlı, araçlar bunlara bağlı DEĞİLDİR): `[TCA] UYARI: role(ler) dusmus …`, `… beklenmeyen ACIK rolenin kapatilmasi …`, `… yon yazmaci sifirlanmis …`, `… donanim okunamadi …`, `[TCA] Role(ler) dustu/sifirlandi … DURDURULDU`.

## 5. Flutter iç sözleşmeleri

- `HomeModel.id` → `String`. `effectiveId`/`idStr` kaldırılır.
- `AutomationState` bağımlılıkları kurucudan alır:
  `AutomationState({ EvCloudApiService? cloudApi, EvMqttService? mqttService, SecureStorageService? secureStorage, BiometricAuthService? biometricService, AutomationApiService? directApi, Clock? clock })`.
  `EvCloudApiService` tekil (singleton) olmaktan çıkar; test için örneklenebilir.
- `Capabilities` (yeni, `lib/models/capabilities.dart`): `(globalRole, activeHome.role, guestValidUntil)` → alanlar:
  `canControlDevices`, `canUseGroupCommands`, `canChangeChildLock`, `canCalibrate`, `canManageRules`, `canInvite`, `canManageMembers`,
  `canTransferOwnership`, `canGenerateServicePin`, `canClaimDevice`, `canCommission`, `canReplaceBoard`, `canEmergencyReset`,
  `canOpenWifiRecovery`, `canEditDeviceHost`, `isStaff`, `isSuperUser`, `isServiceSession`. **Beyaz liste** mantığı: bilinmeyen rol = hiçbir yetki.
  UI ve `AutomationState` metotları aynı nesneyi kullanır (UI gizleme tek başına yetki değildir; sunucu esas).
- Komut hattı (`lib/services/command_pipeline.dart`, yeni): uç nokta başına **tek** bekleyen komut; ilk dokunuştaki gerçek değer saklanır;
  REST yanıtı `delivered=false` / hata ise anında geri alınır + snackbar; `state` mesajı hedefi doğrularsa zamanlayıcı iptal olur;
  2.5 sn içinde onay yoksa geri alınır + snackbar; `dispose`/`logout`/ev değişiminde tümü iptal edilir.
- Oturum olayları: `onSessionExpired` (refresh kalıcı red) ve `onGuestExpired` tek merkezden.
- Yaşam döngüsü: `AppLifecycleListener` ile arka planda MQTT + poll durur; ön plana dönüşte tek snapshot + gerekirse biyometrik yeniden kilit.
- Direkt (LAN) mod: her istekte `X-Device-Key`; anahtar `GET /homes/:id/devices/:uuid/local-key` ile alınır, `SecureStorage`'da saklanır.

**Gerçekleşme notları (WP-D, 2026-10-01; ayrıntı: `docs/FLUTTER_API_CHANGES.md`):**

- *Onay penceresi:* 2.5 sn REST **iletiminden** (`delivered`) itibaren ölçülür (REST gecikmesi bütçeden yemez), komut başına toplam üst sınır 10 sn; zaman aşımında mesaj nötrdür
  ("Cihazdan onay alınamadı…") ve durum hemen REST ile yeniden eşitlenir. MQTT kopukken (`settle`) iletim başarılıysa değer pencere boyunca tutulur, hata gösterilmez.
- *Çocuk kilidi:* durum üç değerlidir (`unknown | unlocked | locked`, çok panoda `mixed`); **cihaz bildirimi (`state.child_lock`) tek doğruluk kaynağıdır**, REST yalnızca cihaz değeri yokken/kanal kopukken kullanılır
  ve bayat yanıt daha yeni bildirimi ezmez. `POST /devices/child-lock` yanıtı "uygulandı" demez (`delivered` ≠ uygulandı; `child_lock_enabled` yok); bilinmeyen durum "kilitsiz" gösterilmez.
- *Çevrimiçilik:* canlı (retained olmayan) `state` cihazı çevrimiçi sayar; retained `status:offline` taze (≤ 90 sn) canlı `state` varken yok sayılır; canlı `status:offline` kesindir.
- *Gizli değerler:* `device_credential.password`, `setup_pin`, `local_key` (acil sıfırlama) yanıttan çağırana **bir kez** döner; uygulama bunları saklamaz/loglamaz (güvenli depo dahil).
- *Yapılandırma:* `lib/config/app_config.dart` — `API_BASE_URL`, `MQTT_TLS`, `DEVICE_AP_HOST` (`--dart-define`); **release derlemede üçü de yok sayılır**.
- *LAN adres kuralı:* cihaz adresi yalnızca yerel olabilir (özel/link-local/loopback/CGNAT IPv4, `localhost`, `*.local`); `X-Device-Key` internete gitmez.

**Gerçekleşme notları (WP-E2 kapanış / W2 Wi-Fi servis akışı, 2026-10-01; CONTRACTS §3d ile birlikte oku):**

- *Wi-Fi Kurulum & Kurtarma Sihirbazı* (`WifiRecoveryDialog`) **kapısızdır**: girişsiz, misafir ve internetsiz kullanıcıda açılır; sunucuya hiç istek atmaz; kendi `AutomationApiService.recoveryAp` örneği (adres `AppConfig.deviceApHost`, varsayılan `192.168.4.1`) kullanılır, global cihaz adresine dokunmaz. `Capabilities.canOpenWifiRecovery` yalnız GİRİŞ YAPMIŞ alanlardaki giriş noktalarını (pano kartları, sistem doktoru, çekmece) gizler; giriş sayfasında girişsiz kullanıcı için ayrı giriş vardır (`btn_wifi_setup`).
- Anahtar: istek `X-Device-Key` taşımaz; yalnız pano kimliği (anahtarsız `status`) okunduktan sonra **O panonun** anahtarı yerel güvenli depoda zaten varsa (ağ çağrısı yok) eklenir. Anahtar için sunucuya GİDİLMEZ, 401'de anahtar yenilenmez (kullanıcıya "kurulum ağına bağlı olun" yönergesi). Başka panonun anahtarı gönderilmez.
- Sonuç bekleme `GET /api/wifi/status` ile yapılır (`AutomationApiService.fetchWifiStatus`/`awaitWifiConnection`; 404'te eski yazılım için `/api/status`'a düşer); başarı YALNIZ `wifi_connect_state == success`; temas kopması (`lostContact`) başarısızlık değil "belirsiz"dir; `429 rate_limited` (AP kaynaklı dakikada 6) geri sayımlı bekleme gösterir.
- `WifiProvisionPanel` (ortak bileşen: sihirbaz + servis kurulum sihirbazı adım 5): isteğe bağlı `expectedUid` (yanlış pano ENGELLEMEYEN uyarı), `onDeviceChecked`, `numberedSteps`, `clock`. AP adı etiketten (`AHBU-<MAC son 6>`), parola etiketteki cihaza özel `ap_pass`; panonun kendi kurulum ağı karekodu modem bilgisi olarak kabul edilmez.
- Biyometrik/oturum kilidi: `AuthGate` pano görünümünden kilit/giriş/zorunlu-parola görünümüne geçerken Navigator'daki TÜM itilmiş sayfaları ve diyalogları kapatır (kök rotaya `popUntil`); `AuthStatus` değerleri aynıdır (`checking|authenticated|unauthenticated`); kilitliyken `fetchHomeMembers`/`getHomeTransferStatus` istek atmaz. Kilit anında Wi-Fi sihirbazı açıksa (`WifiRecoveryDialog.routeName` = `/wifi-setup`) kilit açılınca YALNIZ o sihirbaz yeniden açılır (girilmiş alanlar korunmaz, yeniden test gerekir); diğer sayfalar bilinçli olarak kapalı kalır.
- Derin bağlantılar: `MaterialApp.onGenerateRoute/onUnknownRoute` bağlıdır; iOS Associated Domains ve sunucuda `/.well-known/assetlinks.json` + `apple-app-site-association` YAYINLANMADI (dağıtım işi).

**Gerçekleşme notları (WP-NET, 2026-10-02): Android'de pano kurulum ağına süreç bağlama (§3d ile birlikte oku; ayrıntı: `docs/FLUTTER_API_CHANGES.md` §8.4):**

- *Sorun:* pano kurulum ağı (`AHBU-<MAC son 6>`, `192.168.4.1`) İNTERNETSİZDİR; Android bu Wi-Fi'yi "doğrulanmamış" sayar ve **mobil veri açıksa** uygulamanın varsayılan ağını hücresele çevirir: `192.168.4.1` istekleri hücreselden çıkar ve başarısız olur. Önceki tek çözüm yönergeydi ("mobil veriyi kapatın").
- *Çözüm:* YALNIZ pano kurulum ağıyla konuşulan SÜRELERDE uygulama sürecini Wi-Fi ağına bağlamak (`ConnectivityManager.requestNetwork` + `bindProcessToNetwork`), iş bitince ya da ağ kaybolunca çözmek. Dart: `lib/services/board_network_binding.dart` (`BoardNetworkBinding`; Android'de `AndroidBoardNetworkBinding`, diğer her yerde `NoopBoardNetworkBinding` = HİÇBİR kanal çağrısı yok; testte `FakeBoardNetworkBinding` + `BoardNetworkBinding.overrideForTesting`). `AutomationApiService` adresi pano kurulum ağı olan HER isteği (`_send`, tarama döngüsü, `awaitWifiConnection`, `connectWifiAndWait`) tek sarmalayıcıdan geçirir: kira al → istek → `finally` bırak; `awaitWifiConnection`, `connectWifiAndWait` ve tarama döngüsü baştan sona **tek** kira tutar. Kurucuya isteğe bağlı `boardNetwork` verilir (varsayılan `BoardNetworkBinding.instance`).
- *Kapsam (yalnız):* ana makine == `AppConfig.deviceApHost` ana makinesi ∧ ham IPv4 ∧ `192.168.0.0/16` ∧ Android; alt ağ = ana makinenin /24'ü. Emülatör/QA (`10.0.2.2`, `127.0.0.1`, `localhost`), `*.local` ve **LAN doğrudan mod** (ev ağındaki cihaz IP'si; internetli Wi-Fi) için bağlama YAPILMAZ (süreç varsayılan ağı doğru kalır).
- *Kanal sözleşmesi* (`ev_otomasyon/board_network`, `StandardMethodCodec`). Yerel taraf `android/app/src/main/kotlin/com/ahbu/evotomasyon/ev_otomasyon/` altındadır: `BoardNetworkPlugin.kt` (kanal köprüsü), `BoardNetworkBinder.kt` (ConnectivityManager yapıştırıcısı), `BoardNetworkCore.kt` (platformdan bağımsız durum makinesi), `Ipv4Subnet.kt`; `MainActivity.configureFlutterEngine` YALNIZ eklentiyi kaydeder (`flutterEngine.plugins.add(BoardNetworkPlugin())`, `super.configureFlutterEngine` çağrısından sonra; `AndroidManifest.xml`'de iki normal izin: `ACCESS_NETWORK_STATE`, `CHANGE_NETWORK_STATE`):

  | Yön | Çağrı | Yanıt |
  |---|---|---|
  | Dart → yerel | `acquire {subnet: "192.168.4.0/24", timeoutMs: int}` (yerel varsayılan 8000; Dart 5000 gönderir) | `{status, detail?}`; `status` ∈ `bound`, `already_bound`, `not_on_board_network`, `no_wifi`, `timeout`, `permission_denied`, `unsupported`, `error` |
  | Dart → yerel | `release` | `{status: "released" \| "not_bound"}` (her zaman güvenli) |
  | Dart → yerel | `status` | `{bound: bool, sdk: int}` (Dart çağırmaz) |
  | yerel → Dart | `networkLost` | yok (yerel taraf ÖNCE kendisi çözer, sonra bildirir) |

- *Yerel taraf gerçekleşmesi (sözleşmenin yorumu; Dart ile birebir):*
  - **`timeout` yerelden ÜRETİLMEZ.** Yerel istek YALNIZ Wi-Fi taşıyıcısı ister; işletim sistemi zaman aşımı (`onUnavailable`, API 24-25'te elle bekçi), ya da cihazda Wi-Fi donanımı yoksa "bağlı Wi-Fi ağı yok" demektir → `no_wifi` (`detail`: `no_wifi_network` | `no_wifi_hardware`). `timeout` yalnız Dart tarafı üst sınırı dolunca üretilir (`detail` `dart_timeout`). *Sapma notu:* sözleşme metni `timeout` ile `no_wifi`'yi ayrı sayıyordu; yerelde süre dolması = "bağlı Wi-Fi yok" olduğundan doğru ipucu "panonun ağına bağlanın"dır (`timeout` ipucu "mobil veriyi kapatın" yanlış yönlendirirdi). Lead onayı bekliyor; geri alma tek satır (`BoardNetworkCore.noWifiNetwork` içindeki durum).
  - Ağ görüldükten sonra adresi alt ağa uymazsa 3 sn'lik **GRACE** (`BoardNetworkCore.GRACE_MS`; DHCP gecikmesi payı) sonra `not_on_board_network` (`detail`: `other_subnet` | `no_ipv4_address` | `bind_returned_false`). Bu yüzden **yerel en kötü yanıt süresi `timeoutMs + 3 sn`**dir; Dart üst sınırı `timeoutMs + 4 sn`dir (`AndroidBoardNetworkBinding.defaultNativeGrace`) ve bu ilişkiyi `test/services/board_network_android_wiring_test.dart` (Kotlin kaynağından `GRACE_MS` okuyarak) kilitler. `timeoutMs` yerelde 500..60000 ms aralığına kırpılır (≤ 0 → 8000).
  - `bindProcessToNetwork` false dönerse: ağ CANLI ve alt ağa uyuyorsa işletim sistemi bağlamayı REDDETMİŞTİR (AOSP netd EPERM: UID'ye atlanamaz bir VPN uygulanıyor; `VpnService.Builder.allowBypass()` çağırmayan her VPN uygulaması dahil, yalnız "her zaman açık + kilitli VPN" değil) → GRACE beklenmeden `error` + `detail` `bind_denied`; Dart ipucu: "Pano ağına yönlenme reddedildi: telefonda VPN (özel ağ) açıksa kapatıp yeniden deneyin." Ağ gerçekten koptuysa eski yol (GRACE, `bind_returned_false`).
  - Bağlıyken kayıp: `requestNetwork` geri çağrısı yalnız o anki "en iyi" Wi-Fi'yi izler (daha iyi bir Wi-Fi çıkarsa `onAvailable(yeni)` gelir, bağlı ağın `onLost`'u HİÇ gelmez); bu yüzden bağlıyken ek bir `registerNetworkCallback` (yalnız Wi-Fi; yalnız `onLost`) bağlı ağın kaybını izler, ayrıca istek başka ağa geçince bağlı ağın canlılığı denetlenir. Kayıpta yerel taraf ÖNCE çözer, SONRA `networkLost` gönderir.
  - Beklenmeyen yerel istisnada uygulama ÇÖKMEZ: `acquire` ve `release` `{status: "error", detail: "exception:<Sınıf>"}` döner (Dart `release` yanıtını yok sayar; sözleşmedeki `released | not_bound` dışındaki tek sapma), `status` `{bound: false, sdk}` döner. Geçersiz/eksik `subnet` → `error` + `invalid_subnet`; eşzamanlı `acquire`'lar tek ağ isteğine birleşir, farklı alt ağ için sürmekte olan istek varken ikinci `acquire` → `error` + `other_subnet_pending`.
  - Yaşam döngüsü: motor ayrılınca (`onDetachedFromEngine`) ve etkinlik yok edilince (`onDetachedFromActivity`; bağlıysa `networkLost` da gönderilir) yerel `release`; yapılandırma değişiminde bağlama korunur. `release` bekleyen `acquire`'ı `error` + `released` ile bitirir.
  - Yerel birim testleri (JVM, 72 test; sahte platform + sanal zaman): `cd android && ./gradlew --offline :app:testDebugUnitTest` (`flutter test` bunları ÇALIŞTIRMAZ; sonuç: `build/app/test-results/testDebugUnitTest/`). Yalnız test kapsamında `testImplementation("junit:junit:4.12")` kullanılır (`android/app/build.gradle.kts`; APK'ya girmez; çevrimdışı önbellekte bulunan sürüm, 4.13.2'ye yükseltme çevrimiçi fırsatta).
- *Dart davranışı:* kira sayaçlı (ilk kira yerel `acquire`'ı BİR kez çağırır, eşzamanlı `acquire`'lar birleşir); son kira bırakılınca (varsayılan: bekleme/linger YOK) yerel `release` HEMEN çağrılır ve bırakma, bu çağrının yanıtından sonra tamamlanır — yani bir AP çağrısı döndüğünde süreç artık pano ağına bağlı değildir (ardından gelen bulut isteği internetsiz ağdan çıkmaz; `linger` kurucudan verilirse son kira sonrası o kadar beklenir ve bekleme sırasında yeni `acquire` beklemeyi iptal edip mevcut bağlamayı kullanır); `networkLost` → Dart durumu sıfırlanır, açık kiralar pasifleşir (bırakmaları güvenli), sonraki `acquire` yeniden bağlar; yerel hata / `MissingPluginException` / takılı çağrı (Dart tarafı üst sınır = `timeout` + 4 sn) istisna FIRLATMAZ (`error` / `unsupported` / `timeout`); yerel eklenti yoksa (`MissingPluginException`) ya da yerel taraf `unsupported` derse özellik KALICI kapanır: `isSupported` false olur, arayüz eski yönergeye döner, pano çağrıları kira açmaz (kanala bir daha gidilmez). `dispose` sonrası yeni yerel çağrı/zamanlayıcı yoktur; açık yerel bağlama en iyi çabayla çözülür. Hata ayıklama derlemesinde durum/ayrıntı belirteçleri (acquire sonucu, release, networkLost, yutulan istisna TÜRÜ; SSID/IP/anahtar ASLA) `debugPrint` ile yazılır: saha denemesinde `adb logcat -s BoardNetwork flutter` (yerel etiket `BoardNetwork`, Dart satırları `[BoardNetwork/Dart]`).
- *Bağlama başarısızsa* istek YİNE DE denenir (davranış bağlamasız sürümden kötü olmaz); istek ağ hatasıyla (`LocalApiException.isNetwork`) biterse hataya Türkçe ipucu eklenir (`LocalApiException.hint`; `message` içinde de vardır): `not_on_board_network` / `no_wifi` → "Telefon pano kurulum ağına (AHBU-…) bağlı görünmüyor: Wi-Fi ayarlarından panonun ağına bağlanın."; `timeout` / `error` → "Pano ağına yönlenme kurulamadı: mobil veriyi kapatıp yeniden deneyin."; `error` + `bind_denied` → VPN ipucu (yukarıda); `permission_denied` → kısa, teknik olmayan metin. Ham istisna metni gösterilmez. Arayüz (`WifiRecoveryDialog`, `WifiProvisionPanel`, servis sihirbazı adım 5): "mobil veriyi kapatın" yönergesi Android'de ön bilgi olarak "Mobil veri açık kalabilir; uygulama pano ağını otomatik kullanır. Bağlantı kurulamazsa mobil veriyi kapatıp yeniden deneyin." olur; HATA kutusunda ("Ne yapmalıyım") yalnız yedek cümle ("Bağlantı kurulamazsa mobil veriyi kapatıp yeniden deneyin.") kullanılır (diğer platformlarda eski metin aynen).
- *Bilinçli sınırlar:* süreç pano ağına bağlıyken uygulamanın YENİ bulut bağlantıları da internetsiz Wi-Fi'den çıkar; bu yüzden bağlama yalnız AP çağrılarının etrafındadır ve kısadır (en uzunu `awaitWifiConnection`, ~40 sn; o pencerede başarısız olan MQTT yeniden bağlanması üstel bekleme nedeniyle en çok ~60 sn sonra yeniden dener). Ayarlardaki doğrudan mod pano ağı adresine (`192.168.4.1`) ayarlıysa 1,5 sn'lik yoklama her turda kira alıp bırakır. Bağlama yalnız AP çağrısı SÜRERKEN geçerlidir (bırakma çağrı dönmeden tamamlanır): pano çağrısının hemen ardından yapılan bulut çağrısı (ör. `AutomationState`'in doğrudan modda `192.168.4.1` yoklaması sonrası yerel anahtarı sunucudan yenilemesi) bağlı süreçte başlamaz; ancak AP çağrısıyla EŞZAMANLI bir bulut çağrısı yine internetsiz ağdan çıkar. `AutomationState` yerel anahtarı yenilemeyi ağ hatasında da "denendi" sayar (`_localKeyRefreshTried`): böyle eşzamanlı bir hatada anahtar yeniden istenmez (bu paketin dışı; `AutomationState` sahibine iletildi). AppState/uygulama kabuğuna bağlama kancası EKLENMEDİ (yerel taraf motor ayrılınca/etkinlik yok edilince kendisi çözer). **Bilinçli karar:** yerel taraf `not_on_board_network` / `no_wifi` dese bile istek YİNE DE gönderilir (eski davranış; hızlı başarısızlık/`X-Device-Key`'i göndermeme, yerel tespit sahada doğrulanana kadar ertelendi: yanlış-negatif tespit, "mobil veri kapalı" yolunu bozardı); `X-Device-Key` her durumda yalnız yerel (özel) adreslere gider (§8.1). Debug sıcak yeniden başlatmada (hot restart) yerel bağlama Dart durumundan bağımsız sürer (üretimde yok): uygulamayı yeniden başlatın.
- **Gerçek Android cihazda DOĞRULANMADI.** Dart tarafı sahte kanalla (`TestDefaultBinaryMessengerBinding`) ve sahte HTTP ile sınandı (`test/services/board_network_binding_test.dart`, `automation_api_ap_binding_test.dart`, `board_network_android_wiring_test.dart`, `test/ui/e2_wifi_board_network_test.dart`, `f_setup_board_network_test.dart`); yerel durum makinesi JVM'de sahte platformla sınandı; yerel tarafın gerçek `ConnectivityManager` davranışı (özellikle internetsiz Wi-Fi'de `requestNetwork` + `bindProcessToNetwork`, ağ geçişinde `onLost` yokluğu, VPN altında `bind_denied`) ve satıcıya özgü cihaz farkları saha testi ister: canlı test listesi Aşama 16.11.

**Gerçekleşme notları (WP-H istemci: gece hatırlatması, FIREBASE'SİZ, 2026-10-02; ayrıntı `docs/superpowers/analysis/wp-h-flutter/ENTEGRASYON.md`):**

- Bildirim YALNIZ uygulama açıkken veya açıldığında görünür (push/FCM yoktur; kullanıcı kararı: Firebase eklenmedi, `pubspec.yaml`'a yalnız dev `fake_async` girdi). Kaynak: `GET /devices/peace-notification/:home_id` yanıtındaki `last_notice` (§1.5b; sunucu push yapılandırılmamışken kaydı `no_recipients` yazar) → uygulama içi afiş.
- Bağlama: `lib/ui/app_shell.dart` `MaterialApp.builder` sarmalayıcısı + `PeaceNoticeController` (`lib/services/peace_notice_controller.dart`); `lib/services/push/**` Firebase'siz kapılar (`UnsupportedPushGateway` "yapılandırılmadı" no-op); `AutomationState.addBeforeLogoutHook` çıkış kancası (belirteç/afiş temizliği); `AuthStatus` DEĞİŞMEDİ (`checking` = "kilitli, oturum bitmedi"; yalnız `unauthenticated` ve servis oturumu oturum bitişi sayılır).
- "Hepsini Kapat": `EvCloudApiService.closeAllForNotice` (`notice_id` ile `POST /devices/peace-notification/close-all`, `include_shutters` HER ZAMAN açıkça gönderilir: afiş açık panjur sayıyorsa `true` [panjurlar da iner], saymıyorsa `false`; eski pano düğmesi `closeAllOpenLights` her zaman `include_shutters:false` [yalnız lambalar]); `nothing_to_do` ⇒ "kapatıldı" DENMEZ; `skipped_count > 0` ⇒ afiş açık kalır; eski `closeAllOpenLights(String)` imzası aynen.
- Firebase/push ileride istenirse: `docs/superpowers/analysis/wp-h-flutter/arsiv/` (Firebase istemci dosyaları) + platform yamaları `yamalar/arsiv/` (kanal `peace_reminder`, simge, `UIBackgroundModes`) birlikte düşünülür.

**Gerçekleşme notları (WP-STATE, Dalga 5a: akıcılık ve kilitlenmeme, 2026-10-02; `AutomationState` davranış değişiklikleri; denetim: `docs/superpowers/analysis/akicilik-guncel.md`):**

- *LAN yoklaması durur (PF-01):* doğrudan modda `401`, `403 unprovisioned` ve anahtarsız (kısıtlı) özet kalıcı koşuldur: `401`/`403 unprovisioned`'da tek anahtar yenilemesinden sonra anahtar DEĞİŞMEDİYSE, kısıtlı özette anahtar hâlâ YOKSA yoklama DURUR (`directNeedsKey`; bağlantı `connected`, `status == null`, `directError` cihazın anahtar/kurulum mesajı; çevrimdışı SAYILMAZ). `423` süreli koşuldur: `Retry-After` (yoksa 60 sn; en çok 5 dk) + 1 sn beklenir (`directBlockedUntil`), bağlantı `connected`, `status == null`. Yoklamayı sürdüren eylemler: kullanıcının `refresh()` çağrısı ("Yeniden dene"/çekip bırak), `setLocalKey`, `selectDevice`, `updateSelectedDeviceUuid`, `setHost`, `updateSelectedDeviceIp`, mod değişimi ve ön plana dönüş. Bulut moduna dönüş durdurmayı/engeli temizler (`directNeedsKey`/`directBlockedUntil` yalnız doğrudan modda anlamlıdır; arayüz bunları mod denetimiyle okur). Engel her LAN isteğinin başında kalkar; kilit süresi dolup yine `423` gelirse yeni `directBlockedUntil` bildirilir (bayat zaman görünmez). Ağ hatası geri çekilmesi YOKTUR (3 hata -> çevrimdışı, 1,5 sn aralık aynen). Anahtar yenileme hakkı (`_localKeyRefreshTried`) yalnız sunucudan YANIT alınan denemede tüketilir; ağ hatasında ya da cihaz bilinmiyorken sonraki `401`'de yeniden denenir.
- *LAN telemetri (PF-32/33):* tek-uçuşlu yoklama adres ya da anahtar değişince eski uçuşu devralmaz, eski uçuşun sonucu atılır; `uptime`/Wi-Fi RSSI için bildirim eşiği kabadır (son bildirilene göre ≥ 60 sn / ≥ 10 dB: ≈ dakikada 1 bildirim), diğer alanlar `sameAs` ile aynen; çocuk kilidi zamanı (`childLockUpdatedAt`) her yoklamada tazelenir ama bildirim üretmez.
- *Açılış (PF-02/13/29/30):* depo okumaları paraleldir ve her biri 6 sn ile sınırlıdır; dört oturum okumasından biri hatalıysa `storageError` + oturum yok (belirteç SİLİNMEZ); biyometrik tercih okunamazsa AÇIK varsayılır; tercih AÇIKKEN destek sondası zaman aşımına uğrarsa kilit atlanmaz (ekran "yeniden dene / şifre ile giriş" sunar; fail-closed). Biyometrik destek sondası yalnız saklı oturum varken (ya da tercih okunamadıysa) çalışır. `_initInner`, `_unlockWithBiometrics` ve `toggleBiometric` oturum nesli/dispose denetler: çıkış ya da yeni giriş sürerken geç dönen sonuç eski oturumu yeniden kurmaz, tercihi yazmaz. Etkileşimli biyometrik istem 2 dk sonra "başarısız" sayılır (`biometricFailed`; yeniden dene / şifre ile giriş sunulur). Giriş sonrası biyometrik sondalar paraleldir ve bildirimden ÖNCE biter (`shouldPromptBiometrics` ilk karede doğrudur).
- *Soğuk açılış önbellek-önce (PF-03/39/35):* saklı ev listesi varsa oturum HEMEN `authenticated` olur, ilk ev seçilir (uç noktalar + canlı kanal) ve ev listesi arka planda sunucuyla uzlaşır (`homesLoading == true`); `homesFromCache` YALNIZ ağ hatasında `true` olur (yanlış "Çevrimdışısınız" şeridi yok); önbellek boşsa ağ-öncelikli akış aynen. `selectHome` REST yenilemesi ve canlı kanalı (MQTT) eşzamanlı başlatır (REST beklenirken gelen daha yeni canlı `state` REST'in üzerine uygulanır); `setMode(cloud)` (aktif ev varken) REST yenilemesi + MQTT'yi eşzamanlı başlatır (ev listesi burada yenilenmez: eski davranış); `_resumeSession` (ön plana dönüş) ev listesi + REST + MQTT'yi eşzamanlı başlatır. `login()` ve kardeşleri ev listesini bekler (bir tur) ama ilk evin REST yığınını/MQTT'yi BEKLEMEZ (giriş diyalogları açık kalmaz). Ev listesi önbelleği içerik değişmedikçe yeniden yazılmaz.
- *Bildirim politikası (PF-04):* cihaz `state` iletisi (MQTT) yalnız görünür bir şey değiştiyse bildirir (röle/panjur/çocuk kilidi değeri, panjur hareketi, cihaz IP'si, çevrimiçi geçişi); bekleyen komut onayı kendi bildirimini yapar. REST yenilemesi (`refresh`) uç nokta + cihaz + kilit + huzur yüklemelerini TEK bildirimle bitirir (`silent: false` ayrıca yükleme başlangıcını bildirir).
- *Otomatik yeniden deneme (PF-11):* ilk uç nokta yüklemesi ya da cihaz listesi başarısız kalırsa 2, 5, 15, 30 sn sonra (en çok 4; sessiz) yeniden denenir; ev değişiminde, çıkışta, arka plana geçişte ve `dispose`'ta iptal olur; kullanıcının elle yenilemesi (`refresh()`, `silent: false`) yeni bir deneme zinciri başlatır. Cihaz listesi alınamadıysa (ya da boşsa) çevrimiçilik, uç noktaların `device_online` bilgisinden de türetilir (`devicePresence`; yalnız canlı kanal bağlı değilken ya da durum bilinmiyorken; liste başarıyla geldiyse o esastır).
- *Tek seferlik sırlı sonuçlar (PF-44):* `claimDevice`, `emergencyResetDevice`, `replaceBoard` başarı sonrası ev/uç nokta yenilemesini en iyi çabayla ve en çok 3 sn bekler; sonuç (PIN, yerel anahtar, cihaz kimliği) hemen döner, yenileme arka planda sürer (`claimDevice` müşteri akışında sahiplenilen evin seçimi de bu en iyi çaba bloğundadır: sınır aşılırsa liste gelince arka planda seçilir). `dispose` sonrası zamanlayıcı, yoklama, MQTT ve istek kurulmaz (PF-34).
- *Görünüm önbelleği (PF-20/25):* `relayItems`, `shutterItems`, `status`, `scheduledRules`, `capabilities` (ve `inventoryDevices`/`inventoryStats`/`serviceSubscribers`/`childLockOfflineDevices` salt-okunur görünümleri; liste görünümleri DEĞİŞTİRİLEMEZ) girdileri değişmedikçe AYNI nesneyi döndürür (`identical`); girdi değişince (MQTT/REST/LAN verisi, bekleyen komut ve geri alması, rol/ev/oturum, misafir penceresinin zamanla başlaması/bitmesi) yeni nesne. `...ForTesting` ayarlayıcıları senkron bildirir ve görünümü geçersiz kılar. `Capabilities ==`/`hashCode` bayrak bit maskesiyle karşılaştırır (anlamı `toMap()` eşitliğiyle aynı).

## 6. Ortam değişkenleri (sunucu)

| Değişken | Zorunlu | Kim okur |
|---|:-:|---|
| `DATABASE_URL` | ✔ | db.js |
| `JWT_SECRET` (≥ 32) | ✔ | auth |
| `PIN_PEPPER` (≥ 32) | ✔ | utils/pin.js |
| `LOCAL_KEY_SECRET` (32 bayt hex) | ✔ | utils/secret_box.js |
| `MQTT_HOST`, `MQTT_PORT`, `MQTT_BACKEND_USER`, `MQTT_BACKEND_PASS` | ✔ | mqtt_bridge |
| `MQTT_PUBLIC_HOST`, `MQTT_PUBLIC_PORT` | ✔ | mqtt_credential_service (istemciye bildirilen) |
| `EMQX_API_URL`, `EMQX_API_KEY`, `EMQX_API_SECRET` | – | kick (yoksa atlanır, uyarı loglanır; kimlikler yine silinir ama oturum iptali / üye çıkarmada açık bağlantı atılamaz, yalnız yeniden bağlanmada reddedilir) |
| `GOOGLE_CLIENT_IDS` (virgüllü) | ✔* | Google girişi |
| `APPLE_CLIENT_IDS` (virgüllü) | ✔* | Apple girişi |
| `ADMIN_API_KEY` (≥ 32) | – | Yoksa API-anahtarı yolu **kapalıdır** (fail-closed) |
| `CORS_ORIGINS` (virgüllü) | – | Boşsa tarayıcı kökenleri reddedilir (mobil istemci etkilenmez) |
| `BIND_HOST` (varsayılan `127.0.0.1`) | – | server.js |
| `ALLOW_DEBUG_OTP` (`true` yalnız geliştirmede) | – | OTP'yi yanıtta döndürür; üretimde asla. SMS göndericisi yokken telefon-OTP yalnız bununla çalışır (`GET /auth/capabilities` `sms_otp`) |
| `SMTP_*` | ✔* | mailer |
| `FCM_PROJECT_ID` | – | push_service (yoksa push **kapalı**, değerlendirme `no_recipients`/uygulama içi yedekle sürer) |
| `FCM_SERVICE_ACCOUNT_FILE` veya `GOOGLE_APPLICATION_CREDENTIALS` | – | push_service: servis hesabı anahtarının **dosya yolu** (anahtarı ortam değişkenine gömme seçeneği bilerek YOKTUR). Dosya git'e/imaja girmez, salt okunur bağlanır |
| `PEACE_REMINDER_ENABLED` (`true`\|`false`, varsayılan `true`) | – | peace_reminder: kapatma anahtarı. Tanınmayan değer ⇒ **KAPALI** (uyarı loglanır) |
| `PEACE_REMINDER_DRY_RUN` (`true`\|`false`, varsayılan `false`) | – | `true` ise kayıt tutulur ama **push gitmez**. Tanınmayan değer ⇒ **AÇIK** (güvenli taraf). İlk gece bununla doğrulanır |
| `PEACE_REMINDER_HOME_ALLOWLIST` (virgüllü ev UUID'leri) | – | doluysa yalnızca bu evler (kademeli açılış). Dolu ama hiçbiri geçerli UUID değilse **kimse** |
| `PEACE_CATCHUP_MIN` (1–720, varsayılan 60) | – | hedef saatten sonra kaç dakika boyunca (yeniden başlatma/çevrimdışı telafisi) denenir |
| `ENDPOINT_LAYOUT_SYNC` (`off`\|`0`\|`false` = kapalı; varsayılan **açık**) | – | mqtt_bridge: yerleşim eşitleme (§2.4b) kapatma anahtarı. Kapalıyken uç noktalar tohum şablonunda / son eşitlenen hâlinde kalır |

SMS sağlayıcı: henüz YOK (`authService.setSmsSender` `server.js`'te bağlanmadı; akış denetiminde yeni ortam değişkeni eklenmedi). Bağlanınca `SMS_*` değişkenleri bu tabloya eklenir ve `capabilities.sms_otp` kendiliğinden `true` olur; o zamana kadar üretimde `false` (istemci SMS düğmesini gizler).

Ek (A paketi): isteğe bağlı `TRUST_PROXY` (varsayılan loopback; giriş kilidinin (kimlik | IP) katmanı doğru istemci IP'sine dayanır, §1.1b), `APP_PUBLIC_URL`, `JWT_ISSUER`, `AUTH_CACHE_TTL_MS` (en fazla 30000),
ve **yalnızca `NODE_ENV !== 'production'`** iken dikkate alınan süre override'ları `ACCESS_TOKEN_TTL_SEC`, `SERVICE_SESSION_TTL_SEC`,
`REFRESH_TOKEN_TTL_SEC`, `OTP_TTL_SEC` (production'da sessizce yok sayılır; her ortamda [10 sn, varsayılan] aralığına kırpılır).
**Kaldırılan:** `JWT_REFRESH_SECRET`, `INVENTORY_ADMIN_API_KEY`. Zorunlu olup yoksa sunucunun BAŞLAMADIĞI değişkenler: `DATABASE_URL`, `JWT_SECRET`, `PIN_PEPPER`, `LOCAL_KEY_SECRET`.

Ek (C paketi, altyapı): `docker-compose` `${VAR:?}` ile **zorunlu** kılar → `POSTGRES_USER`, `POSTGRES_DB`, `POSTGRES_PASSWORD`, `EMQX_DASHBOARD_PASSWORD`, `EMQX_AUTHDB_USER`, `EMQX_AUTHDB_PASSWORD`,
`EMQX_CERT_DIR` (içinde `fullchain.pem` + `privkey.pem`), `EMQX_TLS_BIND_ADDR`, `EMQX_NODE_COOKIE`. Köprü opsiyonelleri: `MQTT_TLS`, `MQTT_CLIENT_ID`, `MQTT_OFFLINE_AFTER_SEC` (varsayılan 120, en az 30),
`MQTT_RECONNECT_MIN_MS`, `MQTT_RECONNECT_MAX_MS`, `MQTT_PUBLISH_TIMEOUT_MS`. `MQTT_BACKEND_USER/PASS` yoksa köprü **başlamaz** (komutlar `502 BROKER_UNAVAILABLE`).
Yönetim betikleri (yalnız komut satırında): `MIGRATE_CONFIRM=<db adı>`, `ALLOW_DEV_SEEDS`, `DEV_SEED_*`, `SUPER_USER_*`, `LEGACY_MQTT_*`. Tam liste `server/.env.example`'dadır.

**Migration sırası (gerçekleşen):** `001…017` (+`010b`) → A: `018`, `019` → B: `020`, `021` → C: `022`–`026` → B2 (servis paneli): `027` (hesap silme), `028` (Home Admin atama), `029` (etiket yeniden üretimi) → H: `030` → L: `031` (yerleşim eşitleme tabanı: `devices.reported_layout`) → akış denetimi: `032` (bekleyen yerel anahtar: `devices.local_key_pending_enc/_at` + tetikleyici `trg_devices_pending_key_superseded`; kod `032`'siz veritabanında acil sıfırlamada `42703` verir: önce migration) → güvenlik modülü (WP-S1): `033` (`alarms`, `device_events`, `device_configs`, `devices.caps/safety_state`, `endpoints.actuator_type/dimmable/dimmer_source`, mevcut cihaz kimliklerine `ev/{t}/event` yayın ACL'i; köprü v:3 state'te `devices.caps`'i yazdığı için **dağıtım sırası: 033 → sunucu kodu → firmware**). Güvenlik modülü yeni ortam değişkeni eklemez (push `FCM_*` ile ortaktır). Çalıştırıcı `server/scripts/migrate.js` (`schema_migrations`, hedef DB onayı `MIGRATE_CONFIRM`, `--baseline 17` mevcut canlı şema için).
Uygulanmış bir migration dosyası **yerinde değiştirilmez** (checksum hatası); düzeltme yeni bir migration'dır.

\* ilgili özellik kullanılacaksa. `.env` git'te **takip edilmez**; `server/.env.example` yalnızca yer tutucu içerir.

## 7. Dosya sahipliği (paralel çalışmada çakışmayı önler)

Bir dosyaya yalnızca sahibi yazar. Başkasının dosyasında değişiklik gerekiyorsa raporda "istek" olarak yazılır.

| Paket | Sahip olduğu yollar |
|---|---|
| **A — Backend güvenlik/kimlik** | `server/src/server.js`, `src/middlewares/**`, `src/routes/{auth,admin,service,invitation,transfer,inventory}_routes.js`, `src/services/{auth,admin_user,invitation,transfer,inventory,service_token}_service.js`, `src/utils/{mailer,pin}.js`, `server/package.json`, `server/package-lock.json`, `server/.env.example`, kök `.gitignore`, `server/migrations/018–019_*`, `server/test/auth/**` |
| **B — Backend cihaz/komut/MQTT kimlik** | `src/services/{device,mqtt_credential,endpoint}_service.js`, `src/routes/{device,endpoint,mqtt}_routes.js`, `src/utils/{secret_box,command_schema}.js`, `server/migrations/020–021_*`, `server/test/devices/**` |
| **H — Gece hatırlatması (başka oturum)** | `server/src/peace_reminder.js`, `src/services/peace_snapshot.js`, `src/services/peace_text.js`, `src/services/push_service.js`, `src/services/peace_service.js`, `src/routes/push_routes.js`, `server/migrations/030_peace_reminder.sql` (**uygulandıktan sonra yerinde değiştirilmez; gerekirse 031+**), `server/test/peace/**` (PostgreSQL'e bağlanan testler `EV_PG_TEST_URL` ile açılır) — entegrasyon (`server.js`, `device_service.js`, `device_routes.js`, Flutter) bu planın sahiplerinin onayıyla |
| **L — Yerleşim eşitleme (WP-L, 2026-10-03)** | `server/src/utils/endpoint_layout.js`, `src/services/endpoint_layout_sync.js`, `server/migrations/031_endpoint_layout_sync.sql`, `server/test/layout/**` (PostgreSQL'e bağlanan testler `EV_PG_TEST_URL` ile açılır); `src/mqtt_bridge.js` içinde yalnız yerleşim kancası (kurucu seçenekleri `layoutSync`/`layoutSyncer`, `_getLayoutSync`/`_extractLayout`/`_notifyLayoutSync`, `invalidateLayout`, `handleIncomingMessage`'daki yerleşim çıkarma, `_processStatus`'taki `onOffline`, `_processState` sonundaki bildirim, `getStatus().layout_sync`, `end()`/`init()` kapanış bayrağı, üretim tekili). İnceleme düzeltmeleri (2026-10-04) başka paketlerin dosyalarında küçük, testli değişiklikler yaptı: `scheduled_rules_service.updateRule` (yeniden açma doğrulaması), `scheduler._dispatch` (ateşleme anı hedef denetimi), `device_reconciler` (çift süresi kaynağı: pano değişimi kaydı), `endpoint_service.updateEndpoint` (tip yarışı, kilit sırası), `device_service` (taban sıfırlama, devirde önbellek geçersiz kılma, sıfırlamada kilit sırası) |
| **C — Köprü/zamanlayıcı/altyapı** (gerçekleşen migration'lar: `010b`, `022`–`026`) | `src/mqtt_bridge.js`, `src/scheduler.js`, `src/services/scheduled_rules_service.js`, `src/routes/scheduled_rules_routes.js`, `server/migrations/022+_*`, `server/migrations/dev_seeds/**`, `server/scripts/**`, `server/docker-compose.yml`, `server/emqx_config/**`, `server/nginx/**`, `server/init_mqtt_users.sql`, `server/run_*.js`, `server/migrations/run_*.js`, `server/test/bridge/**` |
| **FW-core** | `src/{SmartAutomation,WS_Relay,WS_DIN,WS_RS485,WS_TCA9554PWR,I2C_Driver,ConfigManager,main}.*`, `src/DeviceCommand.h` (arayüz değişikliği önerisi raporlanır), `platformio.ini`, `test/**` |
| **FW-net** | `src/{MqttManager,WiFiManager,WebPortal,WS_WIFI,WS_ETH,WS_MQTT}.*`, `src/{CaCerts,NetUtil,NetTime,ApAccess,WebPortalPage}.h`, `test/{test_net_time,test_ap_access}/**` (FW-core'un `test/**` alanında bu iki dizin FW-net'indir) |
| **D — Flutter çekirdek** | `lib/services/**`, `lib/models/**`, `lib/utils/**`, `lib/main.dart`, `test/support/**`, yeni `test/services/**` |
| **E — Flutter arayüz** | `lib/ui/pages/{auth,family,claim}/**`, `dashboard_page.dart`, `device_settings_page.dart`, `scheduled_rules_page.dart`, `wifi_recovery_dialog.dart`, `lib/ui/widgets/**`, `lib/ui/theme/**`, `android/**`, `ios/**`, ilgili mevcut testler |
| **F — Servis kurulum paneli** | `lib/ui/pages/service_setup/**` (yeni), `service_mode_page.dart`, `service_management_page.dart`, `service_subscribers_page.dart`, `device_inventory_page.dart`, `replace_board_dialog.dart`, `system_doctor_dialog.dart`, ilgili testler |
| **G — Fabrika aracı** | `ev_otomasyon_servis_yazilimi/ev_otomasyon_sistemi.py` |
| **Akış denetimi düzeltmeleri (2026-10-04; geçici ekipler, tasarım: `docs/superpowers/specs/2026-10-04-akis-denetimi-duzeltmeleri.md`)** | Başka paketlerin dosyalarında testli değişiklikler; birleştirmeden sonra sahiplik eski paketlere döner. **S1:** `src/services/{device_service,device_reconciler,endpoint_service,peace_service,inventory_service}.js`, `src/mqtt_bridge.js` (yalnız `expectAck` / `cancelAck` / `pendingAcks` / `requestReconcile` ve uzlaştırıcıya `publishSys`), `server/migrations/032_local_key_pending.sql`. **S2:** `src/services/{auth_service,account_deletion_service,mqtt_credential_service,admin_user_service}.js`, `src/routes/auth_routes.js`. **C1:** `lib/ui/pages/service_setup/**`, `lib/ui/dashboard/{peace_banner,status_pills}.dart`, `transfer_ownership_dialog.dart`, `lib/models/api_models.dart`. **C2:** `lib/ui/pages/auth/**`, `lib/ui/common/deep_links.dart`, `lib/ui/widgets/user_profile_dialog.dart`, `lib/services/{automation_state,ev_cloud_api_service,ev_mqtt_service}.dart`, `lib/models/cloud_models.dart`. **F1:** firmware `src/{ConfigManager,WebPortal,WebPortalPage,WiFiManager,main}.*`, `firmware_releases/v1.1.2/**` + `version_info.json`, `tools/qa_stack/**`, `ev_otomasyon_servis_yazilimi/tests/**` |

### 2.7 Güvenlik sözleşmesi: üretici / tüketici eşlemesi (tek doğru kaynak, 2026-10-07 hizalaması)

§1.5d ve §2.6 tek doğru kaynaktır; aşağıdaki tablo her mesaj ve uç için üreten ve tüketen kodu gösterir (alan alan karşılaştırıldı,
uyumsuzluklar düzeltildi; her düzeltmenin testi en az bir tarafta vardır).

| Mesaj / uç | Üretici | Tüketici(ler) |
|---|---|---|
| `state` v:3 ekleri | FW `safety/SafetyView.h` `writeStateExtras` (MQTT + `GET /api/status`) | SRV `utils/safety_payload.js` `parseStateSafety`; APP `models/safety_models.dart` `SafetyState.fromStateJson` |
| `ev/{t}/event` olayları | FW `events/EventOutbox.h` `eventJson` (+ LAN halkası) | SRV `validateEventPayload` + `services/alarm_service.js`; APP (LAN) `DeviceEventRecord` |
| `cfg_dump` | FW `safety/SafetyCfgJson.h` `writeDumpPart` | SRV `validateEventPayload` (kök diziler) + `handleCfgDump` (`mergeCfgDumpParts`) -> `device_configs` |
| `cmd` güvenlik komutları (`actuator`, `alarm_ack`, `alarm_test`, `event_ack`) | SRV `utils/command_schema.js` + `safety_service.js` / `alarm_service.js` | FW `MqttManager.cpp` `parseCommand` |
| `sys` `cfg_get` | SRV `alarm_service._maybeRequestConfig` (kopya doğrulanana kadar dakikada en çok bir) ve `requestConfig({force})` (Faz 2: yama/çakışma sonrası, 5 sn taban) `{cmd, module:"safety", uid}` | FW `MqttManager.cpp` sys işleyicisi |
| REST `…/alarms`, `…/ack`, `…/actuators/:a`, `…/alarm-test`, `…/safety-config` | SRV `routes/safety_routes.js` | APP `services/ev_cloud_api_service.dart` |
| LAN `/api/actuator`, `/api/alarm/*`, `/api/events`, `/api/safety/config` | FW `WebPortal.cpp`, `safety/SafetyCfgApi.cpp` | APP `services/automation_api_service.dart`, sihirbaz `logic/safety_assignment.dart` |
| `cmd` `safety_arm` (Faz 2) | SRV `command_schema.js` + `safety_service.armDevice` (REST `…/arm`) | FW `MqttManager.cpp` `parseCommand` (1.2.1) |
| `ev/{t}/event` `intrusion_alarm` / `intrusion_cleared` / `arm_changed` (Faz 2) | FW (1.2.1) | SRV `validateEventPayload` (katı alan listesi) + `alarm_service` (`kind='intrusion'`, ayrı uzlaştırma) |
| `sys` `cfg_patch` (Faz 2) | SRV `services/safety_cfg_sync.js` (REST `POST …/safety-config` ve uzlaştırıcı kuyruğu) | FW `MqttManager.cpp` sys işleyicisi (`parseCfgEdit` ortak gövde) |
| Gevşetme sınıflandırması | FW `safety/SafetyCfgEdit.h` `isLoosening` (JS portu `tools/qa_stack/sim/fw/safety_cfg_edit.js` vektörleri üretir) | SRV `utils/safety_cfg_loosen.js` (yalnız denetim; ortak vektörlerle test) |
| Bulut yetki sınırı `isGasRelease` / `isIntrusionLoosening` (Faz 2 incelemesi G-1) | FW `SafetyCfgEdit.h` + `SafetyManager::submitEdit` (VIA_CLOUD -> `gas_local_only` / `armed`) | SRV `safety_cfg_loosen.js` + `safety_cfg_sync.js` (`403 GAS_VALVE_LOCAL_ONLY` / `409 INTRUSION_ARMED`); APP `api_exception.dart` metinleri; ortak vektörler `gas_release` / `intrusion_loosening` |
| Push `data.device_uuid`, `kind:intrusion`, `reason:cfg_pending_dropped` (Faz 2) | SRV `push_service.buildSafetyData`, `alarm_service` | APP `SafetyPushNotice` (WP-N2) |
| REST `…/arm`, `…/safety-config` (POST), `…/safety-config/pending` (DELETE) (Faz 2) | SRV `routes/safety_routes.js` + `services/safety_cfg_sync.js` | APP `ev_cloud_api_service.dart` `armCommand` / `patchSafetyConfig` / `clearSafetyConfigPending`, sihirbaz `logic/safety_config_transport.dart` |
| LAN `POST /api/arm` (Faz 2) | FW `WebPortal.cpp` `handleApiArm` | APP `automation_api_service.dart` `postArm` |
| `cfg_dump` `intrusion`, state `arm_key` (Faz 2) | FW `SafetyCfgJson.h` `writeCfgHead`, `SafetyView.h` | SRV `validateEventPayload` / `mergeCfgDumpParts` (`CFG_DUMP_KEYS`), `parseStateSafety` (`CONTROL_KINDS`); APP `relay_logic.dart` / `safety_assignment.dart` |

**Faz 2 birleştirme hizalaması (2026-10-07; üç ekibin dalları tek ağaçta).** Uçtan uca bağlayıcı test:
`tools/qa_stack/test/f2_cross_layer_contract.test.js` (firmware simülatörünün gerçek yükleri sunucunun gerçek doğrulayıcılarından geçer; sunucunun
`safety_arm` ve `cfg_patch` yükleri firmware'de uygulanır). Bu turda düzeltilen uyumsuzluklar: sunucu `cfg_dump`'taki `intrusion` gecikmelerini
atıyordu (uygulama sihirbazı bulutta hep varsayılanı görüyordu); state'teki `arm_key` kumandası sunucu özetinde `generic`'e düşüyordu;
sunucunun gevşetme portunda `arm_key` kuralı yoktu (ortak vektörlere 7 Faz 2 vektörü eklendi, 51 vektör); sunucu kopyasında `flags`'siz yeni
kapı/hareket sensörünün varsayılan bayrakları firmware'den farklıydı; "alarm kipi desteklenmiyor" metni (sunucu + uygulama) var olmayan v1.3.0'ı
gösteriyordu (hırsız katmanı firmware **1.2.1** ile gelir).

Bu turda düzeltilen uyumsuzluklar (ayrıntı: tasarım belgesi "Sözleşme hizalaması" bölümü): REST/LAN eylemci gövdesi `to`; alarm listesi
`data.items` + `before` = kimlik; `safety.zones` yokluğu = normal (uygulamada vana açma kalıcı olarak engelleniyordu); `cfg_dump` kök
dizileri (sunucu her dökümü `body` yok diye reddediyordu); LAN yapılandırma yazımı tek öğelik yama; firmware olaylarına `aid`;
`test_result` `fb_ms` yalnız ölçüldüyse; LAN olay halkası sayfalama; adlar `cfg` kopyasından; sunucu `DEVICE_REJECTED`/`ack_queued`
eşlemesi; istemci komut kimliğinin güvenlik uçlarında panoya taşınması; kumanda rolü sensörleri.
