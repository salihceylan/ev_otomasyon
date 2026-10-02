# WP-H — `docs/CONTRACTS.md` için hazır satırlar (gece hatırlatması + push)

> Kaynak: WP-H sunucu modülleri (`server/src/peace_reminder.js`, `src/services/peace_snapshot.js`, `src/services/peace_text.js`, `src/services/push_service.js`, `src/services/peace_service.js`,
> `src/routes/push_routes.js`, `migrations/030_peace_reminder.sql`) ve Flutter modülleri (`wp-h-flutter/`).
> Bu dosyadaki her satır **koddan** yazılmıştır; "Doğrulama" sütunu hangi testin kanıtladığını gösterir.
> `CONTRACTS.md` kilitli olduğu için buraya yazıldı: sahibi (orkestratör) uygun bölümlere yapıştırır.
> Yapıştırınca `server/test/peace/peace_integration.test.js` içindeki "CONTRACTS" todo testi kendiliğinden gerçek denetime döner
> (`{ todo: ... }` seçeneğini kaldırın).

## 1. §1.5 tablosuna eklenecek satırlar

| Uç | Not |
|---|---|
| `PUT /me/push-tokens` gövde `{ token, platform, app_version? }` | Cihazın FCM/APNs belirtecini **oturumdaki kullanıcıya** bağlar (ev bağımsız: alıcılar gönderim anında `home_users`'tan hesaplanır). `token` 20–512 görünür ASCII (boşluk yok), `platform` `android`\|`ios`, `app_version` ≤ 32 karakter. Yanıt `200 {registered:true}`. Aynı belirteç başka kullanıcıya yeniden bağlanabilir (paylaşılan telefon). Kullanıcı başına en çok 10 etkin belirteç (fazlasının en eskisi silinir). **Servis oturumu `403 FORBIDDEN`.** Kullanıcı başına 20/dk (`429`). Hata: `400 VALIDATION`. `Cache-Control: no-store`. |
| `DELETE /me/push-tokens` gövde `{ token }` | Yalnızca **çağıranın kendi** belirtecini devre dışı bırakır; belirteç yoksa da `200 {registered:false}` (idempotent; varlığı sızmaz). Çıkışta çağrılır. Aynı kimlik/hız kuralları. |

Her iki uç da `/api/v1/me/push-tokens` ve eski `/api/me/push-tokens` altındadır (router yol öneki eklemez; `server.js` iki yere bağlar).

## 2. §1.5b'ye eklenecek maddeler — gece hatırlatması v2

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

## 3. Yeni §2.5 — Push (FCM) bildirimi (sunucu → uygulama)

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

## 4. §6 tablosuna eklenecek satırlar (ortam değişkenleri)

| Değişken | Zorunlu | Kim okur |
|---|:-:|---|
| `FCM_PROJECT_ID` | – | push_service (yoksa push **kapalı**, değerlendirme `no_recipients`/uygulama içi yedekle sürer) |
| `FCM_SERVICE_ACCOUNT_FILE` veya `GOOGLE_APPLICATION_CREDENTIALS` | – | push_service: servis hesabı anahtarının **dosya yolu** (anahtarı ortam değişkenine gömme seçeneği bilerek YOKTUR). Dosya git'e/imaja girmez, salt okunur bağlanır |
| `PEACE_REMINDER_ENABLED` (`true`\|`false`, varsayılan `true`) | – | peace_reminder: kapatma anahtarı. Tanınmayan değer ⇒ **KAPALI** (uyarı loglanır) |
| `PEACE_REMINDER_DRY_RUN` (`true`\|`false`, varsayılan `false`) | – | `true` ise kayıt tutulur ama **push gitmez**. Tanınmayan değer ⇒ **AÇIK** (güvenli taraf). İlk gece bununla doğrulanır |
| `PEACE_REMINDER_HOME_ALLOWLIST` (virgüllü ev UUID'leri) | – | doluysa yalnızca bu evler (kademeli açılış). Dolu ama hiçbiri geçerli UUID değilse **kimse** |
| `PEACE_CATCHUP_MIN` (1–720, varsayılan 60) | – | hedef saatten sonra kaç dakika boyunca (yeniden başlatma/çevrimdışı telafisi) denenir |

Örnek (`.env.example` — gerçek değer YOK):

```ini
# Gece hatırlatması (push)
# FCM_PROJECT_ID=
# FCM_SERVICE_ACCOUNT_FILE=/run/secrets/fcm_service_account.json
# PEACE_REMINDER_ENABLED=true
# PEACE_REMINDER_DRY_RUN=true
# PEACE_REMINDER_HOME_ALLOWLIST=
# PEACE_CATCHUP_MIN=60
```

## 5. §7 sahiplik satırı (H) — güncel hali

| **H — Gece hatırlatması (başka oturum)** | `server/src/peace_reminder.js`, `src/services/peace_snapshot.js`, `src/services/peace_text.js`, `src/services/push_service.js`, `src/services/peace_service.js`, `src/routes/push_routes.js`, `server/migrations/030_peace_reminder.sql` (**uygulandıktan sonra yerinde değiştirilmez; gerekirse 031+**), `server/test/peace/**` (PostgreSQL'e bağlanan testler `EV_PG_TEST_URL` ile açılır) — entegrasyon (`server.js`, `device_service.js`, `device_routes.js`, Flutter) bu planın sahiplerinin onayıyla |

## 6. Migration sırası satırı

`… → C: 022–026 → H: 030` (zaten yazılı). **030, 022 (`homes.timezone`) ve 025 (`peace_notification_time` HH:MM CHECK) SONRASINDA** uygulanır; `homes` tablosuna dokunmaz.
Tek transaction'da, idempotenttir. Gerçek PostgreSQL 18.4'te `001…030` temiz bir veritabanına sıfırdan uygulanarak doğrulandı (bkz. entegrasyon istekleri §Doğrulama).

## 7. §2.3/§5 için bilgi notu

Çocuk kilidi ve gece hatırlatması **birbirinden bağımsızdır**; hatırlatma kilit durumuna bakmaz ve kilit komutu üretmez.
