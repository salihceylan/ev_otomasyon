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
| 401 | `INVALID_TOKEN` | Token geçersiz/iptal | Oturumu kapat, giriş ekranı |
| 401 | `SERVICE_SESSION_EXPIRED` | 2 saatlik servis oturumu bitti | Servis oturumunu kapat |
| 403 | `FORBIDDEN` | Yetki yok | Refresh DENEME; "yetkiniz yok" göster |
| 403 | `GUEST_EXPIRED` | Misafir süresi doldu | Ev erişimini kapat, ev listesini yenile, MQTT'yi kes |
| 404 | `NOT_FOUND` | Kayıt yok | |
| 409 | `CONFLICT` | Zaten sahiplenilmiş vb. | |
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

**Bilinen sınır (Faz 2):** daire devrinde **cihaz** MQTT kimliği yenilenmez (uygulama kimlikleri, servis PIN/oturumları ve ev verisi temizlenir). Yenileme,
kimliği panoya ileten yetkili bir kanal ister (`sys` konusunda iki aşamalı `set_mqtt_credential` döndürmesi veya servis ziyareti). Acil sıfırlama ve pano değişiminde cihaz kimliği zaten yenilenir.

### 1.2 Kimlik doğrulama

- Access token: JWT (HS256), **15 dk**. Claim'ler: `sub`, `role` (global), `tv` (token_version), `iat`, `exp`, `iss`.
- Refresh token: opak rastgele değer, DB'de **yalnızca SHA-256 özeti**; her kullanımda **döner (rotation)**; kullanılmış token ikinci kez gelirse
  o kullanıcının tüm refresh ailesi iptal edilir. Süre 30 gün (365 değil).
- `JWT_SECRET` yoksa veya 32 karakterden kısaysa sunucu **başlamaz** (varsayılan değer yok).
- Şifre değişimi / sıfırlama / hesap dondurma / ev devri → ilgili kullanıcının refresh token'ları iptal edilir ve `token_version` artar.
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

\* staff = `home_users` kaydı olan kalıcı servis personeli (yalnız o evler). \*\* `target_owner` ile yalnızca staff/super; müşteri OTP'si **zorunlu**.
\*\*\* Gerekçe ≥ 15 karakter + cihaz UUID'sinin yazarak teyidi + denetim kaydı (IP dahil). Servis personeli kendisini yeni sahip yapamaz.

Misafir (`guest`) için her istekte `valid_from <= now <= valid_until` doğrulanır; dışındaysa `403 GUEST_EXPIRED`.

### 1.5 Uçlar (bu sürümde sabitlenen / yeni olanlar)

Tüm uçlar `/api/v1/...` altındadır (eski `/api/...` takma adı korunur).

| Uç | Not |
|---|---|
| `GET /homes` | Her ev: `{ id, name, role, timezone, mqtt_topic_id }`. `role` = ev bazlı rol. |
| `POST /homes/:homeId/mqtt-credentials` | Üyelik + misafir süresi doğrulanır. Yanıt: `{ host, port, username, password, client_id, expires_at, topic_id }`. **Salt-okunur** (yalnızca `state`/`status` abonelik) kimlik; süre = `min(12 saat, misafir bitişi)`. İstemci süre dolmadan yeniler. |
| `POST /devices/:id/command` gövde `{ home_id, command }` | Üyelik + rol matrisi + şema doğrulaması. Yanıt `{ delivered, device_online, command_id }`. Çevrimdışıysa `409 DEVICE_OFFLINE`. **Buluttan tüm komutlar bu uçtan geçer; uygulama MQTT'ye doğrudan yayın yapmaz.** |
| `GET /homes/:homeId/devices` | `[{ device_uuid, name, online, last_seen_at, firmware }]` |
| `GET /homes/:homeId/devices/:uuid/local-key` | owner/resident/staff/service_session. Yanıt `{ local_key }` (LAN doğrudan mod için). |
| `PUT /homes/:homeId/endpoints/:id` | `shutter_duration_sec` (1..300), `name`, `room`. Yetki: kalibrasyon satırı. |
| `POST /homes/:homeId/commissioning` | `{ device_uuid, checks: { relays:{ok,detail}, buttons:{…}, shutters:{…}, network:{…}, cloud:{…} }, notes }`. `tests_passed` **sunucuda** hesaplanır (zorunlu 5 kontrolün hepsi `ok`). |
| `POST /devices/claim` | `{ device_uuid, setup_pin, home_name?, target_owner?, otp_code? }`. `home_id` kabul edilmez. `target_owner` varsa OTP zorunlu ve yalnızca staff/super. Yanıt `{ home_id, home_name, device_uuid }`. |
| `POST /devices/emergency-reset` | `{ device_uuid, confirm_uid, reason, new_owner_identifier? }` (bkz. matris). Yanıt, yeni kurulum PIN'ini **bir kez** döner. |
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
- **Acil sıfırlama yanıtı:** `UNCLAIMED` → `setup_pin` (tek sefer); `REASSIGNED` → `new_owner`, `device_credential`; ortak alanlar `local_key_publish`, `child_lock_reset` (`published|failed|skipped_offline|skipped`), `local_key` (cihaza iletilemediyse), `warnings`, `partial`.
  REVOKED/SUSPENDED cihazı yalnız `super_user` sıfırlar.
- **Pano değişimi yanıtı:** `device_credential`, `shutter_runtimes`, `runtime_sync`, `child_lock` (`pending_device_online` olabilir: cihaz çevrimiçi olunca yeniden uygulanır).
- **Kısmi başarısızlık** (EMQX kick yapılandırılmamış, panoya iletilemedi vb.): **HTTP 200 + `warnings` + `partial: true`** (207 değil; Flutter yalnız 200'ü başarı sayıyor).
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
  `clear` (açık bir şey yok), `sent`, `no_recipients` (push yok → uygulama içi yedek), `skipped_offline`, `failed`, `resolved` (kullanıcı kapattı).
  Kullanıcı kapatması yalnızca `sent`, `no_recipients`, `sending` satırını çözer; `claimed/failed/skipped_offline/clear` satırlarına **dokunmaz**.
- **`GET /devices/peace-notification/:home_id` yanıtı (v2; v1 anahtarları KALIR):**
  `{ home_id, enabled, time, peace_notification_enabled, peace_notification_time, timezone, devices_total, devices_online, stale,
  open_lights_count, open_shutters_count, open_lights:[{id, channel_index, name, room}], open_shutters:[{pair, room, position}],
  summary_text, last_notice }`. `last_notice` = `null` ya da `{ id, local_date:"YYYY-MM-DD", status:"sent"|"no_recipients"|"resolved", summary_text,
  open_lights_count, open_shutters_count, created_at, resolved_at }` (yalnız bu üç durum görünür; en yenisi). `stale:true` ⇒ canlı cihaz yok: sayılar `0`, listeler boş
  ve `summary_text` "Cihaz çevrimdışı…" (bilinmiyor; "hepsi kapalı" **DEMEZ**). Yanıt canlı anlık görüntüdür: `Cache-Control: no-store` olmalıdır (entegrasyonda route'a `noStore(res)` eklenir).
- **`POST /devices/peace-notification/close-all` (v2)** gövde `{ home_id, notice_id?, include_shutters? }` (`notice_id` pozitif tam sayı ya da rakam metni; `include_shutters` boolean, varsayılan `true`):
  yalnızca **canlı** cihaz verisine göre komut üretir. Evde priz (`type='plug'`) yoksa lambalar için tek `{cmd:"all_lights_off"}`, varsa yalnız açık ışık röleleri için
  `{relay:N, state:false}` (priz kapanmasın). Her açık panjur çifti için `{shutter:P, cmd:"down"}` (`all_shutters_down` **kullanılmaz**). Komutlar sırayla ve PUBACK
  beklenerek yayınlanır (16'lık gruplar arası 150 ms). **`endpoints.current_state`'e iyimser yazım YOKTUR**: gerçek durum cihazın `state` yankısıyla gelir.
  Yanıt: `{ closed_lights, closed_shutters, closed_count (=closed_lights), skipped_count, nothing_to_do, delivered:true, device_online:true, command_ids[], command_id|null,
  notice_id|null, resolved, message }`. `resolved:true` ⇒ bildirim kaydı çözüldü. `nothing_to_do:true` ⇒ sunucu kayıtlarına göre kapatılacak şey yoktu ve **hiç komut gönderilmedi**
  (kayıtlar bayat olabilir: istemci "kapatıldı" **göstermemeli**). `skipped_count > 0` ⇒ çok panolu evde ev konusu tüm panolara gittiği için ortak kanal numarası nedeniyle
  güvenle kapatılamayan öğeler var (bildirim çözülmez, `message` elle kontrolü söyler). Hatalar: `400 VALIDATION`, `404 NOT_FOUND` (ev yok / pano yok), `409 DEVICE_OFFLINE`
  (`device_online:false`), `502 BROKER_UNAVAILABLE` (hiçbir kayıt yazılmaz). Yetki `group` (misafir yok). Kayıt yazımı hatası komutları geri almaz: yanıt başarılı, `resolved:false`.
- **Kimlik istisnası:** §0 "kimlikler UUID dizesidir" kuralının **tek** istisnası `notice_id`'dir: `peace_notification_logs.id` `SERIAL` (**tam sayı**). FCM `data` içinde metin olarak,
  REST gövdesinde sayı (ya da rakam metni) olarak gider; kimlik bilinmiyorsa FCM `data.notice_id` boş metindir.

**Birikmiş sunucu işleri (WP-S, 2026-10-01):**
- Oturumlar toplu iptal edilince (logout-all, change-password, reset-password, admin parola/rol/dondurma/pasife alma, sosyal kimlik bağlama) kullanıcının TÜM push belirteçleri de kapanır (COMMIT sonrası, FCM yapılandırmasından bağımsız; push hatası iptali/yanıtı bozmaz). Tek cihaz çıkışı belirtece dokunmaz (istemci `DELETE /me/push-tokens` ile kendininkini kaldırır). change-password/reset-password sonrası istemci belirtecini `PUT /me/push-tokens` ile yeniden kaydeder.
- Çocuk kilidi `requested`/`requested_at` = bekleyen niyet; cihaz bildirimi niyetle eşleşince ya da niyet 7 günden eskiyse `null`'lanır.
- Köprü uzlaştırıcısı (`device_reconciler.js`): cihazın çevrimiçi döneminin başında (ilk canlı state / 120 sn sessizlik sonrası) bekleyen çocuk kilidi niyeti ve pano değişimi sonrası `set_runtime` (`devices.config_snapshot.runtime_sync` = pending|synced) uygulanır; cihaz/niyet başına en çok 3 deneme (5/10/20 sn), idempotent. Çok panolu evde `set_runtime` otomatik uygulanmaz (elle kalibrasyon). `cmd` yayıncıları: REST, zamanlayıcı, köprü uzlaştırıcı (yalnız backend).
- Süreç: kapanışta `/ready` 503 `shutting_down`; PM2 `kill_timeout` ≥ 12000 ms (systemd `TimeoutStopSec=15`).

### 1.5c Servis paneli, hesap silme, etiket yeniden üretimi ve davet önizleme uçları (WP-B2; gerçekleşen şekiller, kod + gerçek PostgreSQL ile doğrulandı 2026-10-02)

Hepsi `/api/v1/...` altındadır (eski `/api/...` takma adı da vardır); başarı gövdesi `{success:true, message?, data}`, hata gövdesi §1.1 (`{success:false, message, code, ...ek alanlar}`). Kişisel veri/gizli içeren yanıtlar `Cache-Control: no-store`. Migration'lar: `027`, `028`, `029`.

- **`GET /service/subscribers?q=&limit=&offset=`** — JWT + global rol `service_user` | `super_user` (servis PIN oturumu, owner, resident, misafir `403`). Kapsam EV bazlıdır: süper tüm evleri, staff yalnız `home_users`'ta SÜRESİ DOLMAMIŞ `service_user` üyeliği olan evleri görür; iletişim bilgisi yalnız kapsamdaki evler için döner.
  `q` ≤ 64 karakter (ev adı, adres, sahip adı/e-posta/telefon, cihaz UID; `% _ \` kaçışlıdır), `limit` 1..100 (varsayılan 50), `offset` 0..1 000 000 (taşan/geçersiz değer sınıra çekilir, `500` üretmez). Yanıt `data`:
  `{subscribers:[{home_id, home_name, home_address|null, owner:{full_name, email|null, phone|null, account_status}|null, device_count, online_count, commissioned_count, commissioned_at|null, last_seen_at|null, device_uuids[≤10], created_at}], total, count, limit, offset}`.
  Yer tutucu e-postalar (telefon/Apple hesapları) sızdırılmaz (`email:null`). Hız sınırı kullanıcı başına 120/dk.
- **`POST /service/subscribers/:homeId/assign-admin/request-otp`** gövde `{full_name, email|phone}` — staff (yalnız kendi evi) / süper. Evin sahibi YOKSA yanıt `{otp_required:false, message}` (kod gerekmez). Sahibi varsa sahibin e-postasına 6 haneli kod gider (kod HEDEF KİŞİYE bağlıdır): `{otp_required:true, message, owner_hint (maskeli e-posta), expires_in:900, resend_after:60}`
  (`debug_code` yalnız `ALLOW_DEBUG_OTP=true` geliştirmede). Hatalar: `400 VALIDATION`; `403 FORBIDDEN` (ev yetkisi yok, kendini atama, servis/süper hesabı hedef); `404 NOT_FOUND`; `409` `MULTIPLE_OWNERS` | `OWNER_UNREACHABLE` | `CONFLICT` (hedef zaten tek sahip, hesap pasif/silinmiş);
  `429 RATE_LIMITED` (+`resend_after`, `Retry-After`: 60 sn bekleme; 15 dk'da 5 hatalı kod denemesi); `503 DELIVERY_FAILED` (e-posta gitmedi; kod geçersiz kılınır). Hız sınırları: IP başına 10/15 dk, kullanıcı+ev başına 5/saat.
- **`POST /service/subscribers/:homeId/assign-admin`** gövde `{full_name, email|phone, otp_code?, force?, reason?}` — TEK gerçek transaction. Modlar: `no_owner` (sahip yok: kod gerekmez, mevcut üyeler korunur; yalnız servis PIN/oturumları iptal edilir), `owner_consent` (sahibin kodu zorunlu), `forced` (yalnız süper, `force:true` + gerekçe 15..500 karakter; sahip rızası aranmaz, sahibe bildirim gider, denetim kaydı).
  Sahip varsa (`owner_consent` ve `forced`) daire DEVRİ uygulanır: tüm üyelikler kalkar [işlemi yapan staff'in kendi servis üyeliği hariç], hedef TEK owner olur, servis PIN/oturumları ve evin uygulama MQTT kimlikleri iptal edilir, davet/kural/devir temizliği yapılır. Hedef hesap yoksa `pending_invite` hesap açılır (telefonla yeni hesap açılamaz: e-posta zorunlu) ve etkinleştirme e-postası gider. Yanıt `data`:
  `{home_id, home_name, mode, new_owner:{id, full_name, email|null, phone|null, account_status}, account_created, invite_sent, previous_owner_count, revoked:{memberships, service_pins, service_sessions, app_credentials}, message, warnings?, partial?}` (kısmi başarısızlıkta HTTP 200 + `warnings` + `partial:true`).
  Hatalar: `400 OWNER_CONSENT_REQUIRED` (kod yok/geçersiz/başka kişi için istenmiş), `400 VALIDATION` + `remaining_attempts` (hatalı kod; başarısız deneme sayacı commit edilir), `429 RATE_LIMITED` (+`Retry-After`), `403 FORBIDDEN` (zorla atama yalnız süper; kendini/servis hesabını atama), `404`, `409` `MULTIPLE_OWNERS` | `CONFLICT`. Hız sınırları: kullanıcı başına 10/15 dk, ev başına 10/saat.
- **`DELETE /auth/account`** gövde `{password}` ya da (hiç parola belirlememiş Google/Apple/telefon hesabı) `{confirm:"SİL"}` ("sil/Sil/SIL/SİL" kabul) — JWT (servis PIN oturumu `403`), 5/15 dk. Yumuşak silme + anonimleştirme TEK transaction'da: e-posta `deleted+<id>@deleted.invalid` olur (ESKİ e-posta serbest kalır: aynı adresle yeniden kayıt mümkün), telefon/google_id/apple_id `NULL`, ad "Silinmiş Kullanıcı", `account_status='deleted'`, `deleted_at` dolu;
  tüm oturumlar/refresh belirteçleri, push belirteçleri, tüm evlerdeki uygulama MQTT kimlikleri, ev üyelikleri, bekleyen davet/devir/servis PIN'leri ve iletişim bilgisi taşıyan tek kullanımlık kodlar iptal edilir; denetim kaydı. Yanıt `data`: `{deleted:true, deleted_at, released_memberships, message, warnings?}`.
  Hatalar: `400 INVALID_CREDENTIALS` (yanlış parola), `400 VALIDATION` (parolasız hesapta "SİL" yok), `403 REAUTH_REQUIRED` (parolalı hesapta yalnız `confirm` gönderildi), `403 FORBIDDEN` (staff/süper kendi hesabını bu uçtan silemez), `404`, **`409 SOLE_OWNER`** + gövdede `homes:[{id, name, other_member_count, device_count}]` (önce daire devri).
- **`POST /admin/inventory/:uid/reissue-label`** — YALNIZ `super_user` JWT'si (API anahtarı ve staff KABUL EDİLMEZ), yalnız `IN_STOCK` + daireye bağlı/claim edilmemiş/devreye alınmamış cihaz. Yeni kurulum PIN'i + yeni `local_key` üretilir (`local_key` şifreli saklanır, eski PIN geçersizleşir, kilit/sayaç sıfırlanır); yanıt `data`:
  `{device, setup_pin, local_key, qr_claim_url (PIN'li), message}` — gizli değerler **yalnız bu yanıtta** (`no-store`). Hatalar: `400 VALIDATION` (geçersiz UID), `403`, `404 NOT_FOUND`, `409 CONFLICT` (IN_STOCK değil / daireye bağlı), `429 RATE_LIMITED` (kullanıcı başına 20/saat), `503 SERVICE_UNAVAILABLE` (`LOCAL_KEY_SECRET` yok; anahtar üretilemez).
- **`POST /homes/join-preview`** gövde `{code}` — davet/devir kodunu **TÜKETMEDEN** önizler (giriş yapmış kullanıcı; servis PIN oturumu hariç). Yanıt `data`: `{kind:"invitation"|"transfer", is_transfer, home_name, resident_count, role, expires_at, already_member?, guest_valid_from?, guest_valid_until?}`.
  Bulunamayan/kullanılmış/süresi dolmuş kod AYNI yanıttır: `410 GONE` (numaralandırma ayrımı yok; istemci 404/405'i "uç yok" sayar); devir kodu yalnız HEDEF hesaba önizlenir (`403`), hedef kimlik hiçbir yanıtta dönmez; `400 VALIDATION` (biçim), kendi dairenizi kendinize devir `400`. Hız sınırı: IP başına 30/15 dk, kullanıcı başına 10/15 dk.

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

### 2.4 `state` yükü (cihaz → bulut)

```json
{
  "v": 2, "uid": "AHBU-S3-…", "fw": "1.1.0", "seq": 1234, "uptime": 3600, "ip": "192.168.1.30",
  "child_lock": false, "last_id": "abc123",
  "relays":   [ { "id": 1, "name": "Salon", "type": "light", "state": true } ],
  "shutters": [ { "pair": 1, "pos": 100, "moving": false, "dir": 0, "target": 255 } ],
  "dis":      [ { "id": 1, "state": false } ]
}
```
`dir`: `0` durdu, `1` yukarı, `2` aşağı. `target`: `255` = hedef yok. Büyük kurulumlarda (≥ 16 röle) JSON havuzu ölçülerek ayrılır ve taşma durumunda yayın yapılmaz, hata loglanır.

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

## 3. Firmware yerel HTTP API (LAN / AP)

- Kimlik: `X-Device-Key: <local_key>`. `local_key` 8–32 karakter, NVS'te saklanır. Sunucuda şifreli tutulur (`devices.local_key_enc`, AES-256-GCM, `LOCAL_KEY_SECRET`).
- **CORS başlığı yoktur.** JSON gövdeli POST'larda `Content-Type: application/json` zorunlu.
- Anahtarsız / yanlış anahtar: `401 {"error":"unauthorized"}`. 5 yanlış deneme → 60 sn `423 {"error":"locked","retry_after":60}`.
- Anahtarsız erişilebilen tek uç: `GET /api/status` **kısıtlı** özet → `{ "device":…, "name":…, "fw":…, "provisioned":bool, "wifi_connected":bool }`. **TEK İSTİSNA (§3d):** Wi-Fi servis akışı uçları (`GET /api/wifi/scan`, `POST /api/wifi/connect`, `GET /api/wifi/status`) **AP kaynaklı** anahtarsız erişime de açıktır (istemci SoftAP arayüzünde + AP şu an WPA2 + geçerli `ap_pass` + cihaz provizyonlu); diğer HER uç yalnız anahtarla çalışır.
- **Provizyonsuz cihaz** (`local_key` boş): yalnızca `POST /api/factory/init` `{ "local_key", "ap_pass" }` ve kısıtlı `status` çalışır; diğer her uç `403 {"error":"unprovisioned"}`. DI / MQTT yolu etkilenmez.
- `POST /api/factory/init` yalnızca `local_key` boşken çalışır. Sonradan değiştirmek için `POST /api/auth/rekey` (mevcut anahtarla).
- `POST /api/mqtt/config` `{ server, port, user, pass }` (anahtarlı) — cihaz bulut kimliğini buradan alır. **Derleme içinde varsayılan MQTT kimliği yoktur**; kimlik yoksa MQTT başlamaz, cihaz yerelde çalışır.
- **`pair` parametresi 1 tabanlıdır** (`/api/relay?pair=2&cmd=up`). `cmd=pos` için `val=0..100` zorunlu; yoksa `400`.
- Hatalı girdi `400 {"error":"…"}`; başarı `200 {"status":"ok"}` / kuyruğa alındıysa `{"status":"queued"}`. Bilinmeyen komut `400` (200 değil).
- AP (kurtarma/yerel kurulum) **adı `AHBU-<STA MAC son 6 hex, büyük harf>`**, parolası **cihaza özeldir** (`ap_pass`, NVS, WPA2). Sabit/varsayılan kurtarma adı veya parolası **YOKTUR** (eski sabit değerler kaldırıldı; firmware, tarayıcı sayfası, uygulama ve belgelerin hiçbirinde geçmez). Cihaz Wi-Fi'ye bağlandığında AP kapanır; yalnızca bağlantı kaybı veya servis modunda süreli (10 dk) açılır.
- Seri CLI'da `RESETKEY` komutu: fiziksel erişimle `local_key`'i temizler (kilitlenme durumunda kurtarma yolu).

## 3b. Firmware'in gerçekleşmiş davranışı ve sözleşmeden sapmalar (FW-net, 2026-10-01)

**MQTT (§2'ye ek/sapma):**
- Cihaz `state` ve `status`'u **QoS 0** yayınlar (PubSubClient yalnız QoS0 yayınlar); yalnızca LWT QoS 1 retained `offline`. "status QoS1" beklentisi gevşetildi; kayıp, 30 sn kalp atışı ve ~0.4 sn'lik değişiklik gözcüsüyle telafi edilir.
- `sys` yükü tam şekli: `{"cmd":"set_local_key","local_key":"<8..32 ASCII 0x21-0x7E>","id":"…"?}` (`key` takma ad olarak kabul edilir). Backend `local_key` adını kullanır.
- `cmd` `id`'si: 1..24 karakter `[A-Za-z0-9._:-]`; son 8 id tekilleştirilir; kuyruk doluysa id kaydedilmez.
- `state` (§2.4): `last_id` boşsa **alan hiç yoktur**; `shutters[]` yalnızca yapılandırılmış (YUKARI+AŞAĞI) çiftleri içerir; `relays[].type` metindir; JSON havuzu öğe sayısından hesaplanır, taşarsa yayın yapılmaz.
- Kimlikler: `uid = "AHBU-S3-" + <STA MAC son 3 bayt, 6 hex, büyük harf>` (fabrika aracının UID'si ve etiket adı aynı kuralla üretilir); MQTT `clientId = "ESP32S3_<12 hex MAC>"`.
- TLS: sertifika doğrulaması **açık** (`CaCerts.h`: ISRG Root X1 + X2), saat senkronu (`time() > 1.7e9`) olmadan TLS denenmez, yalnızca yaprak sertifikanın tarihi denetlenir. **MQTT sunucusu DNS adıyla verilmelidir (IP olmaz)**; sunucu zinciri ISRG dışı bir köke taşınırsa tüm cihazlar bağlanamaz.
- Kimlik yoksa/devre dışıysa MQTT **hiç başlamaz** (yalnız yerel çalışma). Eski `home_*` paylaşılan kimlik ilk açılışta NVS'ten silinir.
- Planlı yeniden başlatma öncesi `offline` yayınlanır.

**Yerel HTTP API (§3'e ek):**
- `GET /` (statik arayüz sayfası) anahtarsız herkese açıktır; "tek anahtarsız uç" ifadesi **API** içindir (`GET /api/status` kısıtlı özet).
- Hata kodları: `400` `invalid_*` / `unknown_command` / `empty_body` / `invalid_json` / `bad_host`; `401 unauthorized`; `403` `unprovisioned` | `already_provisioned` | `bad_origin`; `409 busy` (panjur hareketliyken config); `413 too_large`; `415` Content-Type yok; `423 locked` (+`Retry-After`); `429 rate_limited` (+`Retry-After`; **yalnız** AP kaynaklı anahtarsız `POST /api/wifi/connect`, §3d); `502` RS485; `503` `busy` | `queue_full` | `storage`.
- Şekiller: `POST /api/child-lock {"enabled":bool}` → `200 {"status":"queued"}`, `GET` → `{"child_lock":bool}`; `POST /api/wifi/connect` → `200 {"status":"connecting"}`, sonuç `GET /api/status` içindeki `wifi_connect_state` (`idle|connecting|success|failed`) ve `wifi_connect_reason`; `GET /api/wifi/scan` → `{"status":"scanning"}` | `{"status":"done","cached":bool,"networks":[{ssid,rssi,enc}]}`; **YENİ** `GET /api/wifi/status` → `{wifi_connect_state,wifi_connect_reason,wifi_connected,wifi_sta_ssid,wifi_sta_ip,wifi_rssi,ap_active}` (§3d); `POST /api/system/reboot` → `{"status":"rebooting"}`; `/reset` → `{"status":"reset_ok"}`.
- Anahtarlı tam `GET /api/status` alanları: `device,name,device_name,fw,provisioned,ip,wifi_rssi,uptime_sec,wifi_connected,wifi_sta_ssid/ip/rssi,wifi_ap_active/ip/ssid,wifi_last_reason,wifi_connect_state/reason,time_synced,mqtt_configured,mqtt_connected,ext_module_enabled/channels/address/responding,total_relays,total_dis,child_lock,last_id,relays[],shutters[] (pair,is_shutter,is_moving,moving,dir,pos,target),dis[]`. LAN `status` içinde `uid` yoktur (cihaz kimliği `device` alanında); `relays[].runtime_sec` status'ta yok (config'te var).
- Host allow-list: yalnız IPv4 sabiti / `localhost` / `*.local`; Origin varsa Host ile aynı olmalı (DNS-rebinding savunması). CORS başlığı yoktur.
- `POST /api/rs485/relay` panjur kanalını ve `channel=0` toplu AÇMAYI reddeder (kapatma serbest); `POST /api/rs485/scan` bloklamaz (`202` + `GET` yoklama).

**Provizyon sırası (fabrika/servis):** flash → provizyonsuz cihaz **açık** kurulum AP'si `AHBU-<MAC son 6>` yayınlar (10 dk; istemci bağlıyken en fazla 30 dk; STA tanımsızsa 15 dk arayla yeniden) →
`POST /api/factory/init {local_key (8..32 ASCII), ap_pass (8..32)}` → AP WPA2'ye döner → `X-Device-Key` ile `POST /api/wifi/connect` → `POST /api/mqtt/config {server (DNS adı), port 8884, user d_<t>, pass}`.
**Risk:** provizyonsuz pencerede yakındaki biri `factory/init` ile cihazı sahiplenebilir → fabrikada flash sonrası HEMEN provizyon yapılmalıdır; sahadaki yeniden flash'lanmış panolar için servis sihirbazı provizyonu hemen yapar.

## 3c. Firmware çekirdeği: seri CLI, komut kuyruğu ve zaman kuralı (FW-core, 2026-10-01)

**Seri CLI** (115200 baud, CR/LF, en çok 159 karakter, büyük/küçük harf duyarsız; her komut `[CLI] Komut alindi: …` yankılar — İSTİSNA: `WIFI <ssid> <parola>` maskeli, `FACTORYINIT` hiç yankılanmaz):
`HELP|?` · `STATUS` (cihaz, STA, AP durumu+SSID, MQTT, `local_key` tanımlı/YOK, ek modül, röle/DI/panjur, `child_lock`, yığın su işaretleri) · `MQTT [PUB]` · `RELAY <n> [ON|OFF|TOGGLE]`, `RELAY ALL ON|OFF` ·
`SHUTTER <n> UP|DOWN|STOP|STEP|POS <0-100>`, `SHUTTER ALL UP|DOWN|STOP` · `DI|INPUTS`, `CFG|CONFIG`, `SET_DI <di> <hedef 0-N> <mod 0-4>`, `DEFAULT_DI` · `WIFI <ssid> <parola>|WIFI CLEAR` ·
`EXTMOD <0|1> [kanal]` · `SCAN [RESULT]` (bloklamayan RS485 tarama) · `CH <1-32> [ON|OFF|TOGGLE]` (ham ek modül rölesi; panjur kanalına AÇ/toplu AÇ reddedilir) · `SEND <hex>` · `BAUD <…>` ·
`CHILDLOCK [ON|OFF|STATUS]` · `AP [ON|OFF|STATUS]` (servis AP penceresi 10 dk; provizyonluysa yalnız geçerli `ap_pass` varsa; parola asla yazdırılmaz) · `FACTORYINIT <local_key> <ap_pass>` · `RESETKEY` (yerel anahtarı siler → provizyonsuz) · `REBOOT|RESTART`.

**`FACTORYINIT <local_key> <ap_pass>` (USB-seri provizyon; fabrika aracının tercih ettiği yol — anahtar açık AP'den DÜZ HTTP ile gitmez):**
satır ve parametreler asla yankılanmaz/loglanmaz; seri çıktıda yalnızca `OK factory_init` · `ERR already_provisioned` (cihazda `local_key` varsa; ayrıştırmadan ÖNCE denetlenir, hiçbir şey değişmez) · `ERR invalid_local_key` (8..32 karakter ASCII 0x21–0x7E) ·
`ERR invalid_ap_pass` (8..32 karakter ASCII 0x20–0x7E; satırın geri kalanı, iç boşluk olabilir) · `ERR persist_failed` (NVS yazılamadı; cihaz provizyonsuz KALIR, yeniden denenebilir). Önce `ap_pass`, sonra `local_key` yazılır (yarıda kalırsa provizyonsuz kalır).

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
Araç testleri sahte firmware kullandığından bu bağımlılığı yakalamaz; sahte firmware çıktısı gerçek `main.cpp`/`CliParse.h` ile elle eşleştirildi.

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

Etiketteki 2. karekod (`WIFI:T:WPA;S:AHBU-<MAC6>;P:<ap_pass>;;`) **telefon kamerasıyla** okutulur; uygulama içi "Modem Wi-Fi Karekodu Tara" panonun KENDİ kurulum ağı karekodunu ev Wi-Fi bilgisi olarak KABUL ETMEZ (alanlar dolmaz, yönlendirme gösterilir). Servis kurulum sihirbazı (F) adım 5'i internetsiz ve anahtarsız yürütür (`ServiceTarget.localKey` yalnız bellekte); adım 6'da telefon ev Wi-Fi'sine döner ve yerel anahtar internetle sunucudan, SAKLAMAYAN okumayla (`cloudApi.localKey`; `localKeyFor` DEĞİL) alınır, güvenli depoya YAZILMAZ; sunucuda zaten çevrimiçi olan panoda bulut kimliği yeniden üretilmez.

**Tarayıcı arayüzü (`GET /`):** sayfa anahtarsız yüklenir; anahtarsız kısıtlı özetten sonra `GET /api/wifi/status`'u anahtarsız sondalar: `200` → **kurulum modu** ("Kurulum modu (AP): yalnızca Wi-Fi ayarlarını değiştirebilirsiniz" bandı; yalnız "Wi-Fi (Station)" sekmesi çalışır: çevre ağlar (RSSI çubuğu + kilit; dokununca SSID seçilir ve şifre kutusuna odaklanılır), elle SSID/parola, "Modem Wi-Fi Karekodu Tara (Kamera / Fotoğraf)", bağlantı sonucu `/api/wifi/status` ile beklenir). Diğer sekmeler "Bu işlem için cihaz anahtarı gerekir" kutusu gösterir (anahtar girilirse normal arayüze geçilir). `401` → eski anahtar katmanı. Karekod çözme tarayıcının `BarcodeDetector`'ına bağlıdır; yoksa (güvenli olmayan `http` bağlamı, iOS Safari…) **sessiz yedek**: elle giriş.

**Doğrulanamayanlar (cihazda denenmedi):** gerçek SoftAP istemcisinde `remoteIP()`/alt ağ kararı ve STA+AP birlikteyken ağ yönlendirmesi; SoftAP kanal değişiminde telefon davranışı; iOS/Android tarayıcılarında arayüz; `BarcodeDetector` kullanılabilirliği. Karar mantığı (`test/test_ap_access`), hız sınırı, `WiFiManager` AP-kipi bayrağı, GERÇEK `WebPortal.cpp` yol/yetki/JSON akışı (sahte WebServer + Wi-Fi sürücüsüyle wasm32 glue testi), yol tablosu ve sayfa betiği (sahte DOM + gerçek Chrome) sentetik testlerle doğrulandı (ayrıntı: WP-W1 raporu).

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

## 6. Ortam değişkenleri (sunucu)

| Değişken | Zorunlu | Kim okur |
|---|:-:|---|
| `DATABASE_URL` | ✔ | db.js |
| `JWT_SECRET` (≥ 32) | ✔ | auth |
| `PIN_PEPPER` (≥ 32) | ✔ | utils/pin.js |
| `LOCAL_KEY_SECRET` (32 bayt hex) | ✔ | utils/secret_box.js |
| `MQTT_HOST`, `MQTT_PORT`, `MQTT_BACKEND_USER`, `MQTT_BACKEND_PASS` | ✔ | mqtt_bridge |
| `MQTT_PUBLIC_HOST`, `MQTT_PUBLIC_PORT` | ✔ | mqtt_credential_service (istemciye bildirilen) |
| `EMQX_API_URL`, `EMQX_API_KEY`, `EMQX_API_SECRET` | – | kick (yoksa atlanır, uyarı loglanır) |
| `GOOGLE_CLIENT_IDS` (virgüllü) | ✔* | Google girişi |
| `APPLE_CLIENT_IDS` (virgüllü) | ✔* | Apple girişi |
| `ADMIN_API_KEY` (≥ 32) | – | Yoksa API-anahtarı yolu **kapalıdır** (fail-closed) |
| `CORS_ORIGINS` (virgüllü) | – | Boşsa tarayıcı kökenleri reddedilir (mobil istemci etkilenmez) |
| `BIND_HOST` (varsayılan `127.0.0.1`) | – | server.js |
| `ALLOW_DEBUG_OTP` (`true` yalnız geliştirmede) | – | OTP'yi yanıtta döndürür; üretimde asla |
| `SMTP_*` | ✔* | mailer |
| `FCM_PROJECT_ID` | – | push_service (yoksa push **kapalı**, değerlendirme `no_recipients`/uygulama içi yedekle sürer) |
| `FCM_SERVICE_ACCOUNT_FILE` veya `GOOGLE_APPLICATION_CREDENTIALS` | – | push_service: servis hesabı anahtarının **dosya yolu** (anahtarı ortam değişkenine gömme seçeneği bilerek YOKTUR). Dosya git'e/imaja girmez, salt okunur bağlanır |
| `PEACE_REMINDER_ENABLED` (`true`\|`false`, varsayılan `true`) | – | peace_reminder: kapatma anahtarı. Tanınmayan değer ⇒ **KAPALI** (uyarı loglanır) |
| `PEACE_REMINDER_DRY_RUN` (`true`\|`false`, varsayılan `false`) | – | `true` ise kayıt tutulur ama **push gitmez**. Tanınmayan değer ⇒ **AÇIK** (güvenli taraf). İlk gece bununla doğrulanır |
| `PEACE_REMINDER_HOME_ALLOWLIST` (virgüllü ev UUID'leri) | – | doluysa yalnızca bu evler (kademeli açılış). Dolu ama hiçbiri geçerli UUID değilse **kimse** |
| `PEACE_CATCHUP_MIN` (1–720, varsayılan 60) | – | hedef saatten sonra kaç dakika boyunca (yeniden başlatma/çevrimdışı telafisi) denenir |

Ek (A paketi): isteğe bağlı `TRUST_PROXY` (varsayılan loopback), `APP_PUBLIC_URL`, `JWT_ISSUER`, `AUTH_CACHE_TTL_MS` (en fazla 30000),
ve **yalnızca `NODE_ENV !== 'production'`** iken dikkate alınan süre override'ları `ACCESS_TOKEN_TTL_SEC`, `SERVICE_SESSION_TTL_SEC`,
`REFRESH_TOKEN_TTL_SEC`, `OTP_TTL_SEC` (production'da sessizce yok sayılır; her ortamda [10 sn, varsayılan] aralığına kırpılır).
**Kaldırılan:** `JWT_REFRESH_SECRET`, `INVENTORY_ADMIN_API_KEY`. Zorunlu olup yoksa sunucunun BAŞLAMADIĞI değişkenler: `DATABASE_URL`, `JWT_SECRET`, `PIN_PEPPER`, `LOCAL_KEY_SECRET`.

Ek (C paketi, altyapı): `docker-compose` `${VAR:?}` ile **zorunlu** kılar → `POSTGRES_USER`, `POSTGRES_DB`, `POSTGRES_PASSWORD`, `EMQX_DASHBOARD_PASSWORD`, `EMQX_AUTHDB_USER`, `EMQX_AUTHDB_PASSWORD`,
`EMQX_CERT_DIR` (içinde `fullchain.pem` + `privkey.pem`), `EMQX_TLS_BIND_ADDR`, `EMQX_NODE_COOKIE`. Köprü opsiyonelleri: `MQTT_TLS`, `MQTT_CLIENT_ID`, `MQTT_OFFLINE_AFTER_SEC` (varsayılan 120, en az 30),
`MQTT_RECONNECT_MIN_MS`, `MQTT_RECONNECT_MAX_MS`, `MQTT_PUBLISH_TIMEOUT_MS`. `MQTT_BACKEND_USER/PASS` yoksa köprü **başlamaz** (komutlar `502 BROKER_UNAVAILABLE`).
Yönetim betikleri (yalnız komut satırında): `MIGRATE_CONFIRM=<db adı>`, `ALLOW_DEV_SEEDS`, `DEV_SEED_*`, `SUPER_USER_*`, `LEGACY_MQTT_*`. Tam liste `server/.env.example`'dadır.

**Migration sırası (gerçekleşen):** `001…017` (+`010b`) → A: `018`, `019` → B: `020`, `021` → C: `022`–`026` → B2 (servis paneli): `027` (hesap silme), `028` (Home Admin atama), `029` (etiket yeniden üretimi) → H: `030`. Çalıştırıcı `server/scripts/migrate.js` (`schema_migrations`, hedef DB onayı `MIGRATE_CONFIRM`, `--baseline 17` mevcut canlı şema için).
Uygulanmış bir migration dosyası **yerinde değiştirilmez** (checksum hatası); düzeltme yeni bir migration'dır.

\* ilgili özellik kullanılacaksa. `.env` git'te **takip edilmez**; `server/.env.example` yalnızca yer tutucu içerir.

## 7. Dosya sahipliği (paralel çalışmada çakışmayı önler)

Bir dosyaya yalnızca sahibi yazar. Başkasının dosyasında değişiklik gerekiyorsa raporda "istek" olarak yazılır.

| Paket | Sahip olduğu yollar |
|---|---|
| **A — Backend güvenlik/kimlik** | `server/src/server.js`, `src/middlewares/**`, `src/routes/{auth,admin,service,invitation,transfer,inventory}_routes.js`, `src/services/{auth,admin_user,invitation,transfer,inventory,service_token}_service.js`, `src/utils/{mailer,pin}.js`, `server/package.json`, `server/package-lock.json`, `server/.env.example`, kök `.gitignore`, `server/migrations/018–019_*`, `server/test/auth/**` |
| **B — Backend cihaz/komut/MQTT kimlik** | `src/services/{device,mqtt_credential,endpoint}_service.js`, `src/routes/{device,endpoint,mqtt}_routes.js`, `src/utils/{secret_box,command_schema}.js`, `server/migrations/020–021_*`, `server/test/devices/**` |
| **H — Gece hatırlatması (başka oturum)** | `server/src/peace_reminder.js`, `src/services/peace_snapshot.js`, `src/services/peace_text.js`, `src/services/push_service.js`, `src/services/peace_service.js`, `src/routes/push_routes.js`, `server/migrations/030_peace_reminder.sql` (**uygulandıktan sonra yerinde değiştirilmez; gerekirse 031+**), `server/test/peace/**` (PostgreSQL'e bağlanan testler `EV_PG_TEST_URL` ile açılır) — entegrasyon (`server.js`, `device_service.js`, `device_routes.js`, Flutter) bu planın sahiplerinin onayıyla |
| **C — Köprü/zamanlayıcı/altyapı** (gerçekleşen migration'lar: `010b`, `022`–`026`) | `src/mqtt_bridge.js`, `src/scheduler.js`, `src/services/scheduled_rules_service.js`, `src/routes/scheduled_rules_routes.js`, `server/migrations/022+_*`, `server/migrations/dev_seeds/**`, `server/scripts/**`, `server/docker-compose.yml`, `server/emqx_config/**`, `server/nginx/**`, `server/init_mqtt_users.sql`, `server/run_*.js`, `server/migrations/run_*.js`, `server/test/bridge/**` |
| **FW-core** | `src/{SmartAutomation,WS_Relay,WS_DIN,WS_RS485,WS_TCA9554PWR,I2C_Driver,ConfigManager,main}.*`, `src/DeviceCommand.h` (arayüz değişikliği önerisi raporlanır), `platformio.ini`, `test/**` |
| **FW-net** | `src/{MqttManager,WiFiManager,WebPortal,WS_WIFI,WS_ETH,WS_MQTT}.*`, `src/{CaCerts,NetUtil,NetTime,ApAccess,WebPortalPage}.h`, `test/{test_net_time,test_ap_access}/**` (FW-core'un `test/**` alanında bu iki dizin FW-net'indir) |
| **D — Flutter çekirdek** | `lib/services/**`, `lib/models/**`, `lib/utils/**`, `lib/main.dart`, `test/support/**`, yeni `test/services/**` |
| **E — Flutter arayüz** | `lib/ui/pages/{auth,family,claim}/**`, `dashboard_page.dart`, `device_settings_page.dart`, `scheduled_rules_page.dart`, `wifi_recovery_dialog.dart`, `lib/ui/widgets/**`, `lib/ui/theme/**`, `android/**`, `ios/**`, ilgili mevcut testler |
| **F — Servis kurulum paneli** | `lib/ui/pages/service_setup/**` (yeni), `service_mode_page.dart`, `service_management_page.dart`, `service_subscribers_page.dart`, `device_inventory_page.dart`, `replace_board_dialog.dart`, `system_doctor_dialog.dart`, ilgili testler |
| **G — Fabrika aracı** | `ev_otomasyon_servis_yazilimi/ev_otomasyon_sistemi.py` |
