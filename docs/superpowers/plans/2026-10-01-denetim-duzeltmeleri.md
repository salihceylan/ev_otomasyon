# Denetim Düzeltmeleri ve Servis Kurulum Paneli — Uygulama Planı

> **Ajan/geliştirici için:** Bu planı görev görev uygula (`superpowers:subagent-driven-development` veya `superpowers:executing-plans`).
> Adımlar `- [ ]` ile işaretlenir; bitince `- [x]` yap. Önce `docs/CONTRACTS.md`'yi oku — bileşenler arası TÜM kararlar orada.

**Hedef:** 2026-10-01 kod denetiminde bulunan kritik güvenlik açıklarını, çalışmayan özellikleri ve mantık hatalarını düzeltmek;
servis sorumlusu için adım adım ilerleten bir **kurulum paneli** eklemek.

**Mimari:** Üç bileşen (backend, firmware, Flutter) tek sözleşme belgesine (`docs/CONTRACTS.md`) bağlanır. En büyük mimari karar:
**uygulamalar MQTT'ye yalnızca okuma yetkisiyle bağlanır, tüm komutlar sunucudan (REST) geçer.** Böylece rol/oda/misafir süresi/denetim
tek yerde (sunucu) zorlanır ve paylaşılan MQTT parolası sorunu kökünden kalkar. Cihazlar kendi kimlikleriyle (cihaz başına parola) bağlanır.

**Teknoloji:** Node.js 24 + Express + PostgreSQL + EMQX 5 · Flutter 3.47 · ESP32-S3 (Arduino, PlatformIO) · Python/Tk (fabrika aracı)

---

## 0. Başlangıç durumu (düzeltmelerden ÖNCE ölçüldü)

| Kontrol | Sonuç |
|---|---|
| `flutter analyze` | 0 sorun |
| `flutter test` | 107/107 geçti |
| `pio run` (firmware) | BAŞARILI, RAM %19.5, Flash %35.8 |
| `node --check` (tüm server dosyaları) | hata yok |
| Çalışma ağacı yedeği | `…/scratchpad/baseline/pre_fix_tracked.patch` + `untracked_copy/` (HEAD `head.txt`) |

Yerel C++ derleyicisi (gcc/clang) **yok** → firmware için bilgisayarda birim testi çalıştırılamaz; firmware yalnızca **derleme** ile doğrulanır.
Docker/PostgreSQL/EMQX **yok** → sunucu davranışı mock'lu testlerle doğrulanır; gerçek entegrasyon yalnızca dağıtım sonrası.
Sunucuya SSH şifresi iki kez reddedildi → **dağıtım bu planda "BLOKE"**; hazırlıkları yapılır, uygulanmaz (bkz. §6).

## 1. Çalışma ilkeleri

1. Bir dosyanın tek sahibi vardır (`docs/CONTRACTS.md` §7). Çakışma çıkarsa raporda "istek" olarak yaz.
2. Her düzeltme için önce **başarısız olan test**, sonra düzeltme (mümkün olduğunda). Test yazılamıyorsa (firmware/altyapı) nedenini rapora yaz.
3. Hiçbir sır değeri koda, teste, loga, rapora yazılmaz. Sır gerektiren her yer ortam değişkeni okur ve yoksa **fail-closed** davranır.
4. Davranış değişikliği olan her düzeltmede eski testler **yeniden yazılır** (hatayı kutsayan testler silinir/düzeltilir), yeşile zorlanmaz.
5. Commit YAPILMAZ (kullanıcı istemedi). Değişiklikler çalışma ağacında kalır; yedek patch ile geri dönülebilir.
6. Üretimdeki site kapı sistemine (aynı sunucuda çalışan Mosquitto + API) hiçbir yolla dokunulmaz; ortak servisler yeniden başlatılmaz.

## 2. Dalga planı

| Dalga | Paketler (paralel) | Bağımlılık |
|---|---|---|
| **1** | A (backend güvenlik), B (backend cihaz), C (köprü/altyapı), FW-core, FW-net, D (Flutter çekirdek) | `CONTRACTS.md`, `db.js withTransaction`, `DeviceCommand.h` hazır |
| **2** | E (Flutter arayüz), F (servis kurulum paneli), G (fabrika aracı) | D bitmiş (yeni model/servis API'leri), A bitmiş (REST davranışı) |
| **3** | Entegrasyon (ben): derleme/analiz/test, çapraz tutarlılık, dağıtım dosyaları, runbook | Hepsi |
| **4** | **Emülatör QA** (bkz. §5b): yerel QA yığını + tüm emülatör/cihaz profillerinde tüm menüleri gezme → hata bul → düzelt → tekrar tara | Dalga 1–3 bitmiş; WP-Q (QA yığını) hazır |

| **5** | **Akıcılık, kilitlenmeme ve görsel cila** (bkz. §5c): ölçüm → performans düzeltmeleri → tasarım dili ve hareket → görsel inceleme döngüsü → son QA kapısı | Dalga 4 temiz bitmiş |

WP-Q (QA yığını, `tools/qa_stack/`) Dalga 1 ile paralel başlar: sunucudan bağımsız parçalar (gömülü PostgreSQL, EMQX davranışını taklit eden broker, firmware simülatörü) hemen, sunucuyla entegrasyon (migration + API + tohum veri) backend paketleri bitince.

## 3. Paketler ve görev listeleri

Bulgu numaraları (§8) denetim raporundaki maddelerin kısa adıdır. Her görevin kabul ölçütü **koyu** yazılmıştır.

### WP-A — Backend güvenlik ve kimlik (`server/`)

- [ ] **A0** Önce: `src/middlewares/rate_limit.js` — `rateLimit({ windowMs, max, keyGenerator, code })` fabrikası (bellek içi, test edilebilir). B ve C bunu kullanır. **Paket başında yaz, sonra devam et.**
- [ ] **A1** `src/utils/pin.js` — `hashPin(pin)` = HMAC-SHA256(`PIN_PEPPER`), `verifyPin(pin, storedHash)` sabit zamanlı; eski tuzsuz SHA-256 özetini doğrular ve başarıda yükseltir. **PIN_PEPPER yoksa başlamaz.**
- [ ] **A2** `server.js`: `helmet`, `trust proxy`, `CORS_ORIGINS` listesi, `BIND_HOST` (varsayılan 127.0.0.1), gövde boyut sınırı (256 KB), global hata yakalayıcı (`HttpError`, 5xx'te genel mesaj, `code`), `unhandledRejection`/`uncaughtException` log, graceful shutdown (server.close, cron/scheduler durdur, MQTT end, pool.end), `/health` sadeleştirme (hata metni yok) + `/ready`, cron bloğunu `require('./scheduler').start({ mqttBridge, db })` ile değiştir (C yazar), B/C route'larını bağla. **Sunucu `JWT_SECRET` yoksa/kısaysa başlamaz.**
- [ ] **A3** `auth_middleware.js`: UUID doğrulama (`parseInt` yok), `requireHomeAccess(roles)` yeniden yaz — üyelik + rol listesi + misafir `valid_from/valid_until` (`GUEST_EXPIRED`) + `service_session` yalnız kendi `home_id`'si + staff için `home_users` üyeliği zorunlu + `super_user` açık istisna; `requireHomeMember`, `requireServiceManager`, `requireSuperUser` aynı mantık; token `tv` (token_version) ve kullanıcı aktifliği kontrolü (kısa önbellek ≤ 30 sn). **Matris testi: her rol × her uç.**
- [ ] **A4** `auth_service.js` — kimlik: Google `google-auth-library` (`aud` listesi, `email_verified`), Apple `jose` JWKS (`iss`,`aud`,`exp`), **geri dönüş yolu yok**; kayıt: parola politikası, e-posta normalizasyonu, bcrypt 12, kullanıcı yokken sahte bcrypt (zamanlama), `phone` UNIQUE (kısmi) ; access 15 dk; refresh rotation + tekrar-kullanım tespiti (aile iptali) + 30 gün; `token_version` JWT'ye ve kontrole; şifre değişimi/sıfırlama/dondurma oturumları iptal eder; logout refresh'i iptal eder.
- [ ] **A5** `auth_service.js` — OTP/sıfırlama: kodlar `crypto.randomInt`; DB'de özet; yeniden istek bekleme 60 sn + saatte 5; deneme sayacı **atomik** (`UPDATE … SET attempts=attempts+1 … RETURNING`) ve yeniden gönderimle sıfırlanmaz; gönderim sonucu (mailer/SMS) başarısızsa hata dön; kod/token **loglanmaz**; `debug_*` alanları yalnızca `ALLOW_DEBUG_OTP=true`; ölü `forgotPassword`/gölgelenen `resetPassword` silinir; sihirli bağlantı GET ile oturum açmaz (POST + tek kullanım); `/auth/*` uçlarına rate limit.
- [ ] **A6** Servis oturumu: `service_sessions` tablosu (018), `service_token_service.js` + `auth_routes /service-login` yeniden yaz (CONTRACTS §1.3): PIN özetli, atomik tüketim, tek-ev kapsamlı token, kullanıcı satırı yaratmaz, global rol vermez, IP rate limit. Yeni PIN eskisini iptal eder; ev devri/sıfırlama servis PIN'lerini ve oturumlarını iptal eder (fonksiyon dışa açılır: `revokeHomeServiceAccess(homeId, tx?)`).
- [ ] **A7** `admin_routes` / `admin_user_service.js`: servis personeli son kullanıcıların parolasını değiştiremez (yalnızca sıfırlama bağlantısı tetikler), süper kullanıcı detayını göremez, liste `created_by` kapsamlı; kendini/son süper kullanıcıyı dondurma/düşürme engeli; başka süper kullanıcının parolası için mevcut parola ile yeniden doğrulama; parola/aktiflik değişince oturumlar iptal; hard delete **tek transaction'da** (FK'ler, sahipsiz ev, MQTT kimlikleri → `mqttCredentialService.revokeUserAccess` çağrısı B'nin arayüzüyle); hata mesajında constraint sızıntısı yok.
- [ ] **A8** `admin_api_key_middleware.js`: sabit varsayılan anahtar ve süper kullanıcı parolasını anahtar sayma **tamamen silinir**; `ADMIN_API_KEY` (≥ 32) varsa `timingSafeEqual`, yoksa yol **kapalı** (fail-closed). Envanter uçları öncelikle JWT rolüne (`super_user`) bağlanır.
- [ ] **A9** `invitation_service.js` / routes: rol beyaz listesi (`resident`,`guest`; `owner` yalnızca devirle), kod 10 karakter `generateCode`, atomik tüketim (`UPDATE … WHERE used=false … RETURNING`) **gerçek transaction** içinde, misafir süresi üst sınırı 72 saat ve `valid_from < valid_until`, `member` rol hatası düzelt (`resident`), `getHomeMembers` süresi dolmuş misafire kapalı + misafire iletişim bilgisi gösterilmez, owner başka owner'ı / son owner'ı silemez, üye çıkınca `revokeUserAccess` ; hatalar `HttpError` (403/404/410 doğru kodla), rate limit (`/homes/join`).
- [ ] **A10** `transfer_service.js` / routes: `target_identifier` zorunlu + normalize + kabul eden kimlik eşleşmeli, kod 16 karakter + özetli saklama, kabul atomik + gerçek transaction, hata mesajı genel (e-posta sızdırmaz), **yalnızca o evle ilgili** oturum/MQTT/servis erişimi iptal (kullanıcının başka evlerdeki oturumları düşmez), `scheduled_rules`/davet/servis PIN temizliği için `homeCleanupHook(tx, homeId)` çağırır (C/B sağlar; yoksa no-op), rate limit.
- [ ] **A11** `inventory_service.js` / routes: yetki matrisi (§1.4), durum geçiş matrisi (REVOKED/CLAIMED → IN_STOCK yalnız super; CLAIMED silinemez), sayfalama, PIN özeti `pin.js` ile, `local_key` üretimi B'nin `secret_box` arayüzüyle (oluşturma yanıtında bir kez döner).
- [ ] **A12** `mailer.js`: OTP/token loglamaz; gönderim sonucunu döner; SMTP yoksa açık hata.
- [ ] **A13** `.gitignore` (`.env`, `*.pem`, `*.key`, `server/.env*` ama `.env.example` hariç), `git rm --cached server/.env` (yalnız dizinden; dosya diskte kalır), `server/.env.example`, `package.json`: `helmet`, `express-rate-limit` **kullanma → kendi `rate_limit.js`**; `google-auth-library`, `jose` ekle; devDependencies: `supertest`; scripts: `test`, `lint:syntax`; `engines`; **sahipsiz `nodemon` düzeltilir**. `npm install` çalıştır.
- [ ] **A14** Migration `018_auth_hardening.sql` (idempotent): `service_sessions`, `refresh_tokens` (özet, aile, kullanıldı), `users.token_version`, `users.must_change_password`, `users.account_status`, `phone`/`google_id`/`apple_id` kısmi UNIQUE, OTP tabloları özet/deneme alanları, `home_users.role` CHECK düzeltme. `019_*` gerekirse.
- [ ] **A15** Testler (`node --test`, mock db): yetki matrisi, rate limit, Google/Apple doğrulama (stub), refresh rotation/reuse, OTP deneme sayacı, PIN özet/doğrulama, hata yakalayıcı, servis oturumu kapsamı. **`npm test` yeşil.**

### WP-B — Backend cihaz, komut ve MQTT kimlik (`server/`)

- [ ] **B0** `utils/secret_box.js` (AES-256-GCM, `LOCAL_KEY_SECRET`) ve `utils/command_schema.js` (CONTRACTS §2.3 şema doğrulayıcı: bilinmeyen alan/aralık dışı → hata). Önce bunları yaz; A11 kullanır.
- [ ] **B1** `device_routes.js`: **her** uç `authenticateToken` + `requireHomeAccess(...)` (matris), `home_id` yalnızca doğrulanmış üyelikten; `POST /devices/:id/command` şema doğrulama + rol matrisi (misafir toplu/çocuk kilidi yok) + çevrimdışı → `409 DEVICE_OFFLINE` + `{delivered, device_online, command_id}`; çocuk kilidi/huzur bildirimi/close-all/diagnostic/replace-board/emergency-reset aynı.
- [ ] **B2** Yanıltıcı başarıları kaldır: `mqttBridge.publish` çağrıları `publishCommand`'a (firmware sözlüğü, `ev/{t}/cmd`) çevrilir; hata **yutulmaz** (502 `BROKER_UNAVAILABLE`); DB durumu yayın başarılı olduktan sonra veya "bekliyor" durumuyla yazılır; `closeAllOpenLights` `{cmd:'all_lights_off'}` yollar ve gerçek sayıyı yanıtlar.
- [ ] **B3** `claimDevice` yeniden yaz — **tek `withTransaction`**: `device_inventory` satırı `FOR UPDATE`; durum kontrolü; PIN hatası **atomik** sayaç (`UPDATE … RETURNING`) + kilit; rate limit (IP+kullanıcı+UID); eski `devices` yolu **silinir**; `target_owner` varsa OTP **her zaman** zorunlu ve yalnızca staff/super; normal kullanıcıda `home_id` yok sayılır; teknisyen sahip olamaz; müşteri hesabı **rastgele kullanılamaz parola + `account_status='pending_invite'` + davet bağlantısı** (sabit parola yok); kanallar tek `INSERT … SELECT generate_series` (model kanal sayısı), MAC çakışması giderilir, yedek sabit MAC kaldırılır; sahiplenmede cihaz kimliği (`d_{t}`) üretilir ve **tek seferlik** yanıtla döner; `local_key` üretilip şifreli saklanır.
- [ ] **B4** Claim OTP: yalnızca staff/super; IP+hedef rate limit; yeniden istek deneme sayacını sıfırlamaz; e-posta gönderim hatası yüzeye çıkar; tablo oluşturma DDL'i koddan kalkar (migration'a taşınır).
- [ ] **B5** `emergencyReset`: yetki §1.4; gerekçe ≥ 15 + `confirm_uid`; **her seferinde yeni rastgele PIN** (yanıtta bir kez), yeni local_key; `devices.setup_pin` düz metin kolonu kullanılmaz; servis kendini sahip yapamaz; tek transaction; oturum iptali hataları yutulmaz (207/uyarı); **cleanup**: endpoints, scheduled_rules, davetler, servis PIN/oturumları silinir; MQTT kimlikleri iptal; retained `state/status` boş yayınla temizlenir (`mqttBridge.clearRetained`); yanıt gerçek dalı yansıtır.
- [ ] **B6** `replaceBoard`: PIN kilit sayacı (claim ile aynı), `SUSPENDED/CLAIMED` reddi, `old_device_uuid` zorunlu (çok cihazlı evde) — `LIMIT 1` yedeği **yok**, düz metin PIN yazımı kalkar, `UNIQUE(device_id,channel_index)` çakışması çözülür, tek `home_id` doğrulaması (sessiz "ilk ev" yok), eski cihaz kimliği iptal + yeni cihaz kimliği, transaction.
- [ ] **B7** `mqtt_credential_service.js` (CONTRACTS §2.2): `issueDeviceCredential`, `issueUserCredential` (salt-okunur, süreli), `revokeUserAccess`, `revokeHomeAccess`, `revokeDeviceCredential`, süresi dolanları silen temizlik, EMQX REST kick (isteğe bağlı), bcrypt; `routes/mqtt_routes.js` → `POST /homes/:homeId/mqtt-credentials`; yeni ev `mqtt_username` = `h_`+16 hex (çakışmada yeniden dene); migration `020_mqtt_credentials.sql` (`mqtt_credentials`, `mqtt_acl`).
- [ ] **B8** Endpoint servisi/rotası: `GET /homes/:homeId/devices`, `…/devices/:uuid/local-key`, `PUT …/endpoints/:id` kalibrasyon (1..300) + `cmd set_runtime` yayını, kanal adı/oda; `getSystemDiagnostic` tüm cihazlar; `peace-notification` şema/sütun uyumu (`endpoints.state/is_active/shutter_position` yerine gerçek sütunlar); tarih alanı biçim doğrulaması; `getPeaceNotificationSettings` 404.
- [ ] **B9** Devreye alma: `POST /homes/:homeId/commissioning` (CONTRACTS §1.5) sunucu tarafı `tests_passed` hesabı, kontrol sonuçlarının ayrı kaydı (migration `021_*`), varsayılan "tümü test edildi" notu yok.
- [ ] **B10** Migration `021`: FK/`ON DELETE` kararları (yetim cihaz/envanter), eksik indeksler, `devices.setup_pin` boşaltma, `device_inventory.local_key_enc`, `devices.local_key_enc`, `commissioning_checks`.
- [ ] **B11** Testler (`node --test`, mock db/mqtt): rol×uç matrisi, claim yarışı (iki eşzamanlı claim → yalnız biri), PIN sayacı atomikliği, OTP zorunluluğu, emergency reset cleanup, komut şeması, çevrimdışı 409, kimlik iptali. **`npm test` yeşil.**

### WP-C — Köprü, zamanlayıcı ve altyapı (`server/`)

- [ ] **C1** `mqtt_bridge.js`: `packet.retain` farkında (retained `state` yalnızca endpoint günceller, **`is_online` değiştirmez**; online yalnız `status`/LWT + `last_seen`); cihaz eşleme `uid` ile (yoksa evin tek cihazı); payload doğrulama (tip/aralık, 64 KB sınır, `try/catch` her mesajda); **toplu** `UPDATE … FROM (VALUES …) WHERE … IS DISTINCT FROM` tek transaction; `last_id` ack kaydı; `status` LWT ve 120 sn çevrimdışı süpürücü; `clean:false` + sabit clientId, abonelik `granted` kontrolü, üstel yeniden bağlanma; `publishCommand(topicId, obj)` (retain=false, QoS1) ve `clearRetained(topicId)`; `backend_service` kimliği ortamdan.
- [ ] **C2** `scheduler.js` (`start({ mqttBridge, db })`, `stop()`): ev saat diliminde (`homes.timezone`, `Intl`) dakika eşleştirme, `last_run_at` ile **atomik** tekrar engeli (çoklu instance güvenli), 2 dk telafi penceresi, kuralı firmware komutuna çevirme (CONTRACTS §2.3), çalıştırma anında `created_by` hâlâ owner/resident mı, kural cihazı hâlâ o evde mi, çevrimdışı cihaz atlanır + `scheduled_rule_runs` günlüğü, `Promise.allSettled` + zaman aşımı.
- [ ] **C3** `scheduled_rules_service.js` / routes: snake_case+camelCase kabulü, **şema doğrulama** (kanal 1..N tamsayı, gün 0-6 benzersiz tamsayı, `action` beyaz liste, saat/dakika aralığı, `channel_type` doğru kaydedilir), `PUT` doğrulaması, `device_id` eve ait mi, ev başına en çok 50 kural, `requireHomeAccess` (süresi dolmuş misafir/servis erişimi), hata mesajı sızıntısı yok; migration `022_scheduled_rules_fix.sql` (UUID tipleri, `last_run_at`, `(hour,minute) WHERE enabled` indeksi, `scheduled_rule_runs`, `homes.timezone`).
- [ ] **C4** Migration yönetimi: `scripts/migrate.js` (`schema_migrations`, hedef host/db'yi yazdırır ve `MIGRATE_CONFIRM=<dbname>` ister, `--baseline N`, transaction başına dosya); eski `run_*.js` ve sabit bağlantı dizeleri **silinir/yönlendirilir**; seed'ler (`002`,`003`,`014`, `seed_demo_credentials.js`, `list_demo_users.js`) `migrations/dev_seeds/`'e taşınır ve üretimde çalışmaz; yıkıcı `016`'nın denetim kaydı silmesi için düzeltici migration; `003` yeniden çalıştırma durumu geri alma sorunu giderilir.
- [ ] **C5** `docker-compose.yml`: `acl.conf` yolu düzelt, **parolalar `${VAR:?}`** ile `.env`'den, `user: "0:0"` ve geniş `/etc/letsencrypt` bağlaması kalkar (yalnızca ilgili sertifika dizini salt-okunur, değişkenle), Postgres/EMQX yalnızca `127.0.0.1`'e, kullanılmayan **Redis kaldırılır**, healthcheck/kaynak limiti, EMQX için en az yetkili DB rolü (`SELECT` yalnız `mqtt_credentials`,`mqtt_acl`,`mqtt_users`) → `scripts/create_db_roles.sql`.
- [ ] **C6** `emqx_config/`: authn zinciri (1: `mqtt_credentials` bcrypt + `expires_at`; 2: legacy `mqtt_users` sha256 — **geçiş için, kapatma adımı runbook'ta**), authz PG (`mqtt_acl`), `acl.conf` dosya fallback'i (backend + `deny all`), TLS 1.2+/1.3 notu, `max_packet_size`, parolalı artık dosyalar (`add_users.sh`, `import.sh`, `auth-built-in-db-bootstrap.csv`, `test_inspect.escript`, `init_mqtt_users.sql`) **silinir**; yerine `scripts/create_backend_mqtt_user.js` (parola ortamdan, bcrypt).
- [ ] **C7** `nginx/`: 443 bloğu şablonu (HSTS, `limit_req`, `$connection_upgrade` map, `client_max_body_size 256k`, zaman aşımları, yalnızca `127.0.0.1:5000`'e proxy), HTTP→HTTPS yönlendirme.
- [ ] **C8** Testler (`node --test`): bridge payload doğrulama/retain davranışı/toplu güncelleme SQL üretimi, scheduler saat dilimi/DST/telafi/tekrar engeli/yetki, şema doğrulama. **`npm test` yeşil.**

### WP-FW-core — Firmware çekirdek (röle/panjur/RS485/NVS)

- [ ] **F1** Komut kuyruğu: `postDeviceCommand` (`DeviceCommand.h`) `SmartAutomation.cpp`'de uygulanır (FreeRTOS kuyruk, `begin()`'de oluşur); `loop()` sınırlı sürede boşaltır; **tüm** giriş yolları (DI, CLI, kural, MQTT, Web) bu hat üzerinden röle/panjur'a ulaşır; röle/panjur API'leri artık yalnızca `SmartAutomation` içinden çağrılır.
- [ ] **F2** I2C/TCA9554: `I2C_Driver` recursive mutex; `Read_REG` dönüş kontrolü; çıkış yazmacı için **RAM gölge kaydı** (donanımdan oku-değiştir-yaz kalkar); `writeMask()` panjur çiftlerinde `(m&0x03)==0x03` vb. durumu **reddeder**; yazma sonucu kontrol + 2-3 deneme; durum yalnızca başarıdan sonra güncellenir; RTC okuma I2C mutex altında ve 1 Hz.
- [ ] **F3** Panjur durum makinesi: yön değişiminde `target_position/start_position/duration_ms/start_time` **koşulsuz** yeniden atanır (konumun ters uca sabitlenmesi hatası); süre orantılı (`diff*tUp/100 + overrun`); `runtime_sec` 1..300; `shutterUp/Down` çift tipini doğrular; `allShutters*` koşulu `&&`; ölü zaman `uint32_t` farkı (millis taşması) ve `dead_time_start>0` bayrağı yerine ayrı `bool`; aynı yön tekrar komutu başlangıcı bozmaz; `shutterStep` konuma göre yön seçer; hareket sırasında yapılandırma değişimi reddedilir; impulse bitişi `now - start >= dur`.
- [ ] **F4** Harici modül (RS485): `_rs485Mutex` **oluşturulur** ve her işlem tek `rs485Transaction()` içinden geçer; CRC16 + yankı/uzunluk doğrulama; başlatılmamış tampon yok; yanıtsız slave için üstel geri çekilme + `_extModuleResponding` gerçek durum; `checkRs485Incoming` toplam süre/bayt sınırlı; **ek modül panjur çiftleri için de interlock**: eş OFF doğrulanmadan ON gönderilmez; ham `rs485ControlExtRelay/Send` yalnızca servis/yetkili bağlamdan ve panjur kanallarını/`channel=0` toplu ON'u reddeder; `setRelayState/toggleRelay` `relayIndex >= totalRelays()`; `rs485ScanModule` **bloklamayan** (ayrı görev, `202` + yoklama).
- [ ] **F5** TWDT: `esp_task_wdt_init(10,true)`, loopTask ve ilgili görevler kayıtlı/beslenir; açılışta `esp_reset_reason()` loglanır; bağımsız **motor süre aşımı emniyeti** (görev/`esp_timer`): panjur rölesi planlanan süre + marj aşılırsa kapatır; `delay()` çağrıları (reboot/reset/CLI) bayrak + sonraki turda `ESP.restart()` ile değişir ve restart öncesi tüm panjurlar durdurulur.
- [ ] **F6** NVS/Config: panjur konumu kaydı **debounce** (hareket bittikten 5–10 sn sonra, |Δ| ≥ %2, tüm çiftler tek yazım); `prefs.begin/put*` dönüşleri kontrol edilir; `ConfigManager::validate()` (`ext_module_channels` ∈ {0,2,4,8,12,16,24,32}, adres 1..247, `type/mode/target_relay/runtime` aralıkları, `uint8_t t = 8 + …` taşması) `load()` ve tüm yazma yollarında; `resetToDefaults()` ek modül anahtarlarını ve `ahbu_auto/ahbu_pos` ad alanlarını siler; **derleme içinde varsayılan MQTT kimliği kalkar** (`home_101`/parola) → kimlik yoksa MQTT başlamaz; `local_key`, `ap_pass`, MQTT kimlik alanları eklenir (FW-net kullanır; alan adlarını `ConfigManager.h`'de önce yayınla).
- [ ] **F7** Çocuk kilidi: harici modül DI'larında da uygulanır; bırakma (release) olayı **asla** yutulmaz (yalnızca basma engellenir); DI debounce 60 ms; `Relay_Init()` `setup()`'ın ilk işi; CLI Wi-Fi parolasını yankılamaz; test SSID kalıntısı silinir.
- [ ] **F8** Derleme: `platformio.ini` — `platform = espressif32@<kurulu sürüm>` sabitle, göreli `core_dir`, `build_src_filter` ile kullanılmayan demo dosyaları (`WS_MQTT/WS_WIFI/WS_ETH/WS_Bluetooth/WS_CAN/WS_SD/WS_RS485/WS_Serial/WS_GPIO(buzzer/RGB hariç kısımlar)/WS_RTC…`) çıkar (**çağrılan fonksiyonlar kırılmadan** — gerekirse yalnız gerçekten ölü olanlar); `[env:native]` + Unity için pure `ShutterFsm` ve testleri **yazılır** (bu makinede derleyici yok → çalıştırılamaz, bunu rapora yaz). **`pio run` BAŞARILI** ve flash/RAM önceki değeri belirgin aşmaz.

### WP-FW-net — Firmware ağ ve web (MQTT/Wi-Fi/portal)

- [ ] **N1** `MqttManager`: `onMessage` yalnızca JSON'u **doğrular** (CONTRACTS §2.3: tip/aralık, `is<T>()`, eksik/bozuk alanda **uygulama**; `pos` 256→0 kesmesi yok; çocuk kilidi fail-open yok; `state` boolean) ve `postDeviceCommand` çağırır (kuyruk dolu → logla); `cmd` aboneliğinden sonra ilk **1500 ms** gelen mesaj yok sayılır; `sys` konusu: yalnızca `set_local_key`; `id` tekilleştirme (son 8 kimlik); `state` yükü §2.4 (`v:2`, `uid`, `fw`, `seq`, `last_id`, `pair` 1 tabanlı, `moving/dir/target/child_lock`), **ArduinoJson kapasitesi `measureJson` ile** ve `overflowed()` kontrolü (taşarsa yayın yok + log), `_needPublish` bayrağı snapshot'tan **önce** temizlenir + 250 ms birleştirme + hata durumunda üstel bekleme; LWT/`offline` planlı restart öncesi yayınlanır; Wi-Fi kopunca soket kapatılır; yeniden bağlanma üstel (5→300 sn) + ±%20 jitter, CONNACK 4/5'te uzun bekleme; `setHandshakeTimeout`; **TLS sertifika doğrulaması AÇIK**: `setCACert` (ISRG Root X1, `src/CaCerts.h`) + saat senkronu olmadan bağlanmama (`time(nullptr) > 1.7e9`); yığın 12 KB + watermark logu; "TLS 1.3" metinleri düzelt; kimlik yoksa MQTT başlamaz.
- [ ] **N2** `WiFiManager`: kurtarma AP tetiği `continue`'dan **önce** (3 dk kesinti → AP) ve histerezis; AP SSID `AHBU-<MAC son 6>` (32 bayt sınırı), parola `ap_pass` (cihaza özel); STA bağlanınca AP **kapanır** (parola "waveshare" ile yeniden kurmak yok), kurtarma AP'si süreli (10 dk); `/api/wifi/connect` — aday kimlik RAM'de, `GOT_IP`'de NVS'e commit, zaman aşımında eskiye dönüş, tek `WiFi.begin` sahibi (WiFiManager), SSID 1..32 bayt/parola 0 veya 8..63 doğrulama, yanıt gönderildikten sonra bağlanma; `disconnect` WiFiManager kimliğini de temizler; `LOST_IP` olayı ve `WiFi.status()` mutabakatı; `String` paylaşımı mutex altında; `WiFi.persistent(false)` + fabrika sıfırlamada `esp_wifi_restore()`.
- [ ] **N3** `WebPortal`: **kimlik doğrulama** (CONTRACTS §3: `X-Device-Key`, sabit zamanlı karşılaştırma, 5 hata → 60 sn kilit, provizyonsuz mod, `/api/factory/init`, `/api/auth/rekey`, `/api/auth/check`, `/api/mqtt/config`), **CORS başlıkları kaldırılır**, JSON uçlarında `Content-Type` zorunlu, `Origin`/`Host` kontrolü; tüm JSON alanları `is<const char*>()` ile doğrulanır (`strncpy(nullptr)` çökmesi), `deserializeJson` hatasında 400 (child-lock/rs485 fail-open yok); `pair` **1 tabanlı**, `cmd=pos` için `val` zorunlu, `toInt()` hatası/aralık → 400, bilinmeyen komut → 400; röle/panjur komutları `postDeviceCommand`; `/api/rs485/*` yalnızca anahtarlı; baud beyaz liste {9600,19200,38400,115200}; `rs485/relay` panjur/`channel=0`; `scan` bloklamaz; reboot/reset öncesi `allShuttersStop`; `resetToDefaults` kapsamlı; `/api/wifi/scan` hız sınırlı (≥ 10 sn), SSID geçerli UTF-8'e zorlanır (geçersiz bayt → `�`), `refresh` olmadan eski önbellek sonsuz dönmez; config doğrulama (`type/mode/runtime ≤ 300/ext_module_channels/adres`), ext modül etkinleştirmede `ext_module_channels` doldurulur (varsayılan 8) ve sunucu `enabled && channels==0`'ı normalize eder; **gömülü JS**: `escapeHtml`/DOM API (saklı XSS), `loadConfig` try/catch+yeniden deneme, yolda-istek kilidi ve `document.hidden` kontrolü, idempotent `state=` komutları, QR ayrıştırıcıda `\;` `\\` `\:` çözümü, "150ms donanımsal kilit" metni → "yazılımsal, 500 ms; harici kontaktör/mekanik interlock önerilir", güvenlik başlıkları (CSP, X-Frame-Options), HTTP hata kodları (200 + `error` yok).
- [ ] **N4** Derleme/test: `pio run` **BAŞARILI**; yeni `src/CaCerts.h` doğrulama notu (sertifikanın kaynağı ve geçerlilik tarihi yorumda); cihazda denenemeyen her şey raporda "doğrulanmadı" olarak listelenir.

### WP-D — Flutter çekirdek (`lib/services`, `lib/models`, `lib/utils`)

- [ ] **D1** Bağımlılık enjeksiyonu (CONTRACTS §5), `EvCloudApiService` singleton değil, `Clock` arayüzü; `test/support/` (`fakes.dart`: FakeCloudApi/FakeMqtt/FakeStorage/FakeBiometric, `MockClient` yardımcıları, `pumpApp`).
- [ ] **D2** `HomeModel.id` → `String` ve **tüm** `int homeId` API imzaları `String`; `UserModel/ScheduledRule/Endpoint` modelleri `(x as num).toInt()`/`tryParse` ile esnek parse, kural bazlı `try/catch` (bozuk kayıt listeyi silmez), `days_of_week` doğrulama; `userId` String; `fetchHomeMembers/removeHomeMember/fetchEndpoints` tip hatası (aile üyesi listesi/silme) giderilir.
- [ ] **D3** `ev_cloud_api_service`: **gömülü admin API anahtarı SİLİNİR**; merkezi `_decode()` + `ApiException(status, code, message, retryAfter)`; yalnızca 401'de **tek-uçuş** refresh (403'te yok), kalıcı red → `onSessionExpired`, ağ/5xx'te oturum korunur; refresh sonrası `await onTokenRefreshed`; oturum nesli sayacı (logout sonrası gelen refresh yanıtı yazılmaz); `GUEST_EXPIRED` → `onGuestExpired`; `serviceLogin` kapsam token'ı (refresh yok, süre izleme); yeni uçlar: `mqttCredentials`, `sendCommand`, `devices`, `localKey`, `commission(checks)`, `updateEndpoint(shutter_duration_sec)`; `getChildLock` hatada fırlatır; `controlEndpoint` sonuç türü.
- [ ] **D4** `ev_mqtt_service`: **gömülü parola kalkar** — kimlik sunucudan gelir (`mqttCredentials`) ve süre dolmadan yenilenir; **yalnızca abonelik** (publish yolları silinir); benzersiz `clientId` (kalıcı UUID + oturum eki); canlı `Stream<MqttLinkState>` (connected/reconnecting/disconnected); batch'teki **tüm** mesajlar işlenir; `_handleMqttStateUpdate` güvenli dönüşüm, `moving/dir/target/child_lock/last_id`; kopyalanan `withWillQos` kaldırılır.
- [ ] **D5** `command_pipeline.dart` (CONTRACTS §5) ve `AutomationState`: tüm komutlar REST `sendCommand` → pipeline; uç nokta eşleştirme **tip + kanal** (`isShutter` filtre, `channel == 2*pair-1`); `_optimisticShutterPositions` onay/zaman aşımında temizlenir, `oldPos` gerçek konum; `selectHome` ev-bazlı tüm önbellekleri sıfırlar; `fetchHomes` hatayı ayırır (`homesError`, çevrimdışıyken önbellekli evler, 401 → oturum kapat), `refresh()` aktif ev yokken `fetchHomes`; `isConnected` = `brokerConnected` ve cihaz çevrimiçi **ayrı alanlar**; direkt modda ardışık 3 hata → offline, tek-uçuşlu poll, `val=` ile `pos`, `X-Device-Key`, `ShutterItem.pos/target`, hayalet panjur filtresi; `toggleChildLock` rollback + sonuç kontrolü; `logout()` tek `_resetSessionState()` (kullanıcı kapsamlı **tüm** alanlar, abonelikler, zamanlayıcılar, servis PIN, prefs `saved_service_device_*`), önce yerel temizlik sonra sunucu iptali; `loginWithServicePin` yerel oturumu sıfırlar, süreyi izler; `AppLifecycleListener`; biyometrik: kilitliyken ağ/MQTT başlamaz, `fallbackToPasswordLogin` token/MQTT temizler, devre dışı bırakma doğrulama ister; token yalnızca SecureStorage (SharedPreferences yedeği kalkar, iOS `first_unlock_this_device`); `secure_storage_service` hataları yüzeye çıkar.
- [ ] **D6** `Capabilities` (CONTRACTS §5) ve `AutomationState` metotlarında savunmacı yetki kontrolü; rol enum + normalizasyon; ev bazlı rol (`activeHome.role`), `/homes` ile yenileme (ön plana dönünce, devir/katılım sonrası, 403'te).
- [ ] **D7** `qr_claim_parser` + `wifi_qr_parser` + yeni `qr_router.dart` (`QrPayload` sealed: Claim/Invite/Transfer/Wifi/Unknown): host allowlist, yalnızca `https`, `path==/claim`, UID `^AHBU-[A-Z0-9-]{3,32}$` (trim+upper), PIN `^\d{6}$`, JSON'da yalnızca `String`, uzunluk sınırı, `AHBU-INVITE:`/`AHBU-TRANSFER:`/`AHBU-TR-` ayrımı, **ham metin hiçbir zaman UUID olmaz**; Wi-Fi: tırnak kaçışları, SSID ≤ 32 bayt, WPA 8–63, WEP/EAP "desteklenmiyor", kontrol karakteri reddi, `isOpen`/`security` doğrulaması.
- [ ] **D8** Testler: `test/services/**` — pipeline (rollback 2.5 sn, onayda iptal, çift basış, çevrimdışı 409, logout/dispose iptali), refresh tek-uçuş/403/ağ hatası/oturum nesli, MQTT yük bozukluğu/batch, endpoint eşleştirme (karışık düzen), logout izolasyonu, hesap değiştirme, `fetchHomeMembers` UUID, Capabilities matrisi, parser tabloları. **Mevcut testlerin hatayı kutsayanları (`child_lock`, `clamping`) düzeltilir.**

### WP-E — Flutter arayüz (Dalga 2)

- [ ] **E1** Tüm rol kapıları `Capabilities`'e geçer (kara liste `!isMember` kalkar); misafir cihaz ayarları/IP/Wi-Fi kurtarma/pano değişimi **göremez**; mod anahtarı yalnızca yetkililere; girişsiz yerel mod kısıtlı arayüz.
- [ ] **E2** Dashboard: yüklenme/hata/boş ayrımı (`homesError`, `endpointsError`) — "Henüz kayıtlı daireniz yok"/"Evinize Hoş Geldiniz" yalnızca başarılı boş yanıtta ve yalnızca owner'a; çevrimdışı kartı cihaz durumuna göre; kurtarma kartı doğru koşulda; sayaçlar (servis kullanıcısı) çalışır; sabit altyapı satırı (`Port 5000/PostgreSQL 5434`) kaldırılır; sabit yedek ad/e-posta kaldırılır; QR tarama → `QrRouter`; oda çipleri endpoint'lerden; açık tema kontrastı; `select` ile yeniden çizim azaltma.
- [ ] **E3** Aile ekranları: üye listesi/silme çalışır (+ onay), devir kabulü önizleme + onay adımı, devir kodunda hedef **zorunlu** + yazarak onay, davet yalnız "Üret" ile (initState'te otomatik yok), süre çipi yalnız seçim, UTC → yerel biçim, `GUEST_EXPIRED` ekranı, hata/iptal yönetimi, rol dizgisi normalizasyonu.
- [ ] **E4** Auth: e-posta doğrulama regex'i (basit, geçerli adresleri reddetmez), parola `trim` tutarsızlığı, sıfırlama sonrası mesaj, OTP yeniden gönderim bekleme (sunucudan `resend_after`), Apple düğmesi yalnız iOS/macOS + iptal sessiz, Google `serverClientId`/token yoksa hata, `ForgotPasswordPage` ölü kod + sahte başarı **silinir**, kayıt telefon doğrulama, giriş formunda yalnız boş kontrolü, hata mesajları `friendlyError`, `debugPrint` temizliği (`kDebugMode`), splash süresi durum hazır olunca biter, hesap silme akışı (mağaza gereksinimi).
- [ ] **E5** Wi-Fi kurtarma sihirbazı: host **`192.168.4.1`** için ayrı `AutomationApiService` örneği, SSID/parola `trim` yok, doğrulama (≤ 32 bayt, 8–63), gönderim sonrası `wifiConnected`/`wifi_last_reason` yoklama (başarı yalnız doğrulanırsa), tarama hatası görünür + iptal edilebilir, QR fallback SSID alanına ham metin yazmaz, `utf8` allowMalformed, AP parolası etiketten/QR'dan (sabit `ahbu1234` metni kalkar).
- [ ] **E6** Platform: `FlutterFragmentActivity`, `NSFaceIDUsageDescription`, `NSLocalNetworkUsageDescription`, ana manifest'e **açık `INTERNET`** izni, `allowBackup=false`, `ClaimManualDialog` (`barrierDismissible:false`, PIN yalnız rakam, hata kodu eşleme), `QrScannerPage` (`scanWindow`, `validator`, `torchState`, izin reddi → ayarlar), `BiometricPromptDialog` meşgul/geri tuşu, logout `popUntil`, tek `confirmAndLogout`, profil avatarı `characters.first`, `main.dart` `select` + `runZonedGuarded/FlutterError.onError`, fontlar asset.
- [ ] **E7** Testler: yerleşim/metin testleri **davranış testine** çevrilir (rol matrisi widget testi, `AuthGate` biyometrik sonrası, evsiz/çevrimdışı, devir onayı, QR yönlendirme, Wi-Fi sihirbaz akışları); "ADIM n" adları davranış cümlesine, `installer` kalıntıları temizlenir.

### WP-F — Servis sorumlusu kurulum paneli (Dalga 2) — bkz. §4

- [ ] **S1–S9** §4'te ayrıntılı.

### WP-G — Fabrika aracı (Dalga 2)

- [ ] **G1** `ev_otomasyon_sistemi.py`: sunucu kimlik doğrulaması yönetici girişiyle (`/auth/login` + Bearer), sabit API anahtarı/sunucu parolası yok (oturum içi diyalog); envanter oluşturma yanıtındaki `local_key`'i kullanarak flash sonrası `POST /api/factory/init` (cihaza özel `ap_pass` ile) **en iyi çaba** + elle talimat yedeği; PIN `secrets.randbelow`; etiket QR'ına `ap_pass` eklenir; Wi-Fi/sunucu parolası loglanmaz. (Donanımsız doğrulanamaz → raporda belirtilir.)

## 4. Servis sorumlusu kurulum paneli — tasarım

**Yer:** Flutter uygulaması, servis modu (`lib/ui/pages/service_setup/`). Servis sorumlusu "Yeni Kurulum Başlat"a basar ve **tek seferde bir adım**
gören, her adımda ne yapacağı Türkçe ve basit anlatılan bir sihirbazla ilerler. İlerleme cihaz bazında saklanır (yarıda bırakıp devam edilebilir).

| # | Adım | Ne yapar | Geçiş koşulu (gerçek doğrulama) |
|---|---|---|---|
| 1 | **Hazırlık** | Giriş (servis PIN'i veya personel hesabı), gerekenler listesi (cihaz etiketi, müşteri telefonu/e-postası, Wi-Fi şifresi), oturum süresi geri sayımı | Oturum geçerli |
| 2 | **Cihazı Tanı** | Etiket QR'ı tara (UID+PIN) veya elle gir; cihaz envanterde mi, durumu uygun mu | `QrRouter` Claim + sunucu `IN_STOCK` |
| 3 | **Müşteri** | Müşteri e-posta/telefon; "kendi adıma" engeli; OTP gönder → müşteri kodu söyler → doğrula (geri sayım, tekrar gönderme bekleme) | OTP doğrulandı |
| 4 | **Daireye Bağla (Claim)** | Cihazı müşterinin dairesine bağlar; özet ekranı (hedef ev adı, cihaz UUID) | Sunucu claim başarılı, `home_id` alındı → **bundan sonra tüm adımlar bu eve** (`ServiceTarget`) |
| 5 | **Wi-Fi Kurulumu** | Telefonu kurulum ağına bağla (SSID/AP parolası ekranda), ev Wi-Fi bilgisini gir/QR tara, gönder, **bağlantı sonucunu bekle** | Cihaz `wifi_connected=true` ve IP aldı |
| 6 | **Bulut Bağlantısı** | Cihaz kimliğini cihaza yaz (`/api/mqtt/config`), yerel anahtarı al/yaz, bulutta çevrimiçi olmasını bekle | Sunucuda `online=true` + `state` alındı |
| 7 | **Röle Testi** | Her röle için "Aç/Kapat" butonu; cihazdan **gerçek geri bildirim** (state eşleşmesi) gelirse ✔; teknisyen "yanıyor mu?" teyit eder | Her röle ✔ veya "kullanılmıyor" işaretli |
| 8 | **Panjur Testi ve Kalibrasyon** | Yukarı/Aşağı/Dur, **süre ölçümü** (kronometre: motor tam açıldığında "Bitti"ye basar) → süre kaydedilir (`set_runtime`), yön doğru mu teyidi | Her panjur için süre kayıtlı (1–300 sn) |
| 9 | **Duvar Butonları** | Her buton için "Butona bas" → cihazdan DI olayı gelir ✔ | Her buton ✔ veya "yok" |
| 10 | **Teslim** | Kontrol listesi özeti, notlar, sonuçlar **ayrı alanlarla** sunucuya (`commissioning`), müşteri (ev sahibi) onayı, kurulum raporu paylaş/yazdır | Sunucu `tests_passed=true` |

İlke: **hiçbir adım kullanıcı "tamam" dedi diye geçilmez; geçiş koşulu gerçek cihaz/sunucu yanıtıdır.** Başarısız adımda "Neden?" + "Ne yapmalıyım?" metni ve "Tekrar dene". Kritik uyarılar (ör. yön ters) görsel olarak vurgulanır. Üstte ilerleme çubuğu (n/10), altta tek büyük "Devam" düğmesi (başparmak bölgesi).

- [ ] **S1** `ServiceTarget{homeId, deviceUuid, ip, localKey}` + `ServiceSetupController` (ChangeNotifier, durum makinesi, `SharedPreferences` ile cihaz bazlı kalıcılık, süre izleme).
- [ ] **S2** Ortak adım iskeleti (`SetupStepScaffold`: başlık, "ne yapacaksın" maddeleri, durum rozeti, hata/çözüm kutusu, tekrar dene).
- [ ] **S3** Adım 1–4 (hazırlık, cihazı tanı, müşteri+OTP, claim). `QrRouter` ve D'nin yeni API'leri kullanılır.
- [ ] **S4** Adım 5–6 (Wi-Fi + bulut): E5'in doğrulamalı Wi-Fi bileşeni yeniden kullanılır (kopya yok); cihaz yerel API'si `X-Device-Key` ile.
- [ ] **S5** Adım 7–9 (röle, panjur+kalibrasyon, buton): gerçek geri bildirim bekleyen test bileşenleri.
- [ ] **S6** Adım 10 (teslim): `commissioning(checks)` çağrısı, özet/rapor.
- [ ] **S7** `service_mode_page.dart` sadeleştirilir: "Yeni Kurulum" sihirbazı + "Mevcut cihazlar" + yönetim kartları; eski commissioning kutuları, sahte kalibrasyon kartı, sabit demo UUID/PIN ve ön-dolu değerler **silinir**; acil sıfırlama kartı yalnızca `canEmergencyReset`; geçici (PIN) oturumda yıkıcı kartlar gizli.
- [ ] **S8** `service_subscribers_page` (tip güvenli parse, onaylı Home Admin atama, sayfalama+debounce), `device_inventory_page` (durum geçişleri kısıtlı, yazarak silme onayı), `replace_board_dialog` (hedef daire + eski/yeni pano özeti + onay), `system_doctor_dialog` (eksik alan = "veri yok", hata türü ayrımı), `service_management_page` (kendini/son süper kullanıcıyı dondurma engeli, onay, form doğrulama, hata görünür).
- [ ] **S9** Testler: sihirbaz durum makinesi (her geçiş koşulu), süre bitimi, yarıda bırakıp devam, yanlış cihaz/ev sızıntısı yok, widget akışları.

## 5. Doğrulama (her dalga sonunda ve sonda)

```bash
cd /g/site/ev_otomasyon && flutter analyze && flutter test            # 0 sorun, tüm testler yeşil
cd /g/site/ev_otomasyon/server && npm test && npm run lint:syntax      # tüm server testleri yeşil
cd /g/site/ev_otomasyon/ev_otomasyon_servis_yazilimi/waveshare_s3_demo && pio run   # BAŞARILI
python -m py_compile /g/site/ev_otomasyon/ev_otomasyon_servis_yazilimi/ev_otomasyon_sistemi.py
```

Ek: `git status` ile yalnızca beklenen dosyaların değiştiği, hiçbir sır değerinin (parola/anahtar/jeton) kodda **kalmadığı** `grep` ile doğrulanır.

## 5b. Emülatör QA (Dalga 4) — "tüm kodları tüm emülatörlerde çalıştır, menülerde gez, hataları düzelt"

**Hedef:** Yazılan her kodun gerçekten çalıştığını, her menünün açıldığını, hiçbir ekranda istisna/taşma/kilitlenme olmadığını ve
rol sınırlarının fiilen uygulandığını **çalıştırarak** kanıtlamak. Statik analiz ve birim testleri bunu göstermez.

**Test ortamı (yerel QA yığını, `tools/qa_stack/`):** gerçek PostgreSQL 18 (gömülü), EMQX davranışını taklit eden aedes broker
(bcrypt authn + `mqtt_acl` yetkilendirme + `kick`), **gerçek sunucu kodu**, Node firmware simülatörleri (CONTRACTS §2–§3'e birebir),
gerçek REST API üzerinden tohumlanmış hesaplar. Uygulama QA için `--dart-define=API_BASE_URL=http://10.0.2.2:5000/api
--dart-define=MQTT_TLS=false --dart-define=DEVICE_AP_HOST=10.0.2.2:8081` ile derlenir (**release derlemede bu override'lar yok sayılır**).

**Hedefler (cihaz/profil matrisi):**

| Hedef | Profil |
|---|---|
| Android emülatörü (Pixel 8, API 36) | normal (1080×2400/420dpi) · küçük telefon (`wm size 720x1280`, 320dpi) · tablet benzeri (`wm size 1600x2560`) · yazı ölçeği 1.0/1.3/1.5 · açık/koyu tema · dikey/yatay · TR yerel |
| Windows masaüstü | duman testi (kamera/biyometrik yok; desteklenmeyen özellik çökme değil zarif devre dışı olmalı) |
| Chrome / Edge (web) | duman testi (mobil-öncelikli uygulama; `dart:io` MQTT web'de çalışmaz → çökme yerine açık "desteklenmiyor" mesajı) |
| iOS simülatörü | **Windows'ta mümkün değil** — derlenemez; iOS yapılandırması (Info.plist anahtarları) statik olarak doğrulanır |
| Firmware | gerçek cihaz/ESP32 emülatörü yok → derleme + Node simülatörü sözleşme doğrulaması; donanım davranışı "doğrulanmadı" |
| Fabrika aracı (Python/Tk) | pencere gizli örneklenir, tüm düğme/menü geri çağrıları sahte ağla tetiklenir (`py_compile` + davranış duman testi) |

**Rol kişilikleri (her biri tüm menüleri gezer, hem izinli hem yasak yolları dener):** ev sahibi · aile üyesi · geçerli misafir ·
süresi dolmuş misafir · servis oturumu (PIN) · kalıcı servis personeli · süper kullanıcı · girişsiz/yerel mod.

**Zorunlu senaryolar:** giriş/çıkış/hesap değiştirme · token süresi dolması ve yenileme · refresh iptali · biyometrik açık/kapalı ·
çevrimdışı açılış · MQTT kopma/yeniden bağlanma · cihaz çevrimdışı (LWT) · komut gecikmesi ve 2.5 sn rollback · çift basış ·
panjur yön değişimi · toplu komutlar · çocuk kilidi · zamanlı kurallar · aile daveti/misafir süresi bitişi (oturum içinde) ·
devir/acil sıfırlama sonrası eski sahibin erişimi · QR (claim/davet/devir) yönlendirme · Wi-Fi kurtarma sihirbazı (doğru/yanlış parola) ·
**servis kurulum sihirbazı uçtan uca (10 adım)** · arka plana alma/geri dönme · yazı ölçeği/küçük ekran taşmaları.

**Hata toplama:** `flutter run` logları + `adb logcat` + `FlutterError.onError` yakalamaları + RenderFlex taşma uyarıları + ANR/crash +
sunucu `server.log` 5xx + broker ACL ret günlüğü + simülatör "interlock ihlali" günlüğü. Her bulgu: ekran görüntüsü + tekrar adımları + log satırı.

**Döngü:** Tara → bulguları tekilleştir → **çoklu bağımsız doğrulama** (gerçek hata mı, kök neden hangi dosya) → sahibi ajan düzeltir →
düzeltilen ekran/akış yeniden taranır → **iki ardışık temiz tur** olana kadar tekrar (loop-until-dry). Her düzeltme için regresyon testi eklenir.

**Kalıcı artefaktlar:** `integration_test/` altında menü gezme testleri (cihazda `flutter test integration_test -d <id>`), `docs/QA_RAPORU.md`
(ne çalıştırıldı, hangi profil, bulunan/düzeltilen/açık hatalar, ekran görüntüleri indeksi).

## 5c. Akıcılık, kilitlenmeme ve görsel cila (Dalga 5)

> İstek: "sistemi akıcı, kilitlenmeyecek ve görsel olarak etkileyici hale getir". Bu dalga **işlevsel QA temiz bittikten sonra** başlar;
> çünkü görsel değişiklik yeni hata getirebilir. Her şey **ölçülür**: "akıcı" bir his değil, aşağıdaki bütçelerle kanıtlanan bir sonuçtur.

### Performans bütçeleri (kabul ölçütü)

| Katman | Ölçüt | Nasıl ölçülür |
|---|---|---|
| Flutter kare süresi | Panel/liste/geçiş senaryolarında kare başına build ≤ 8 ms ve raster ≤ 8 ms (p95); **100 ms üzeri kare YOK**; kaçırılan kare oranı < %2 | `integration_test` + `traceAction`/`watchPerformance` (profil modu), emülatörde |
| Açılış | Soğuk açılıştan etkileşime hazır ≤ 2.5 sn (ağsız); splash sabit 2.6 sn beklemesi kalkar | `flutter run --profile` zaman damgaları |
| Yeniden çizim | `MaterialApp`/kök yeniden kurma yok; saniyede > 10 kez tüm sayfa `notifyListeners` yok; `select`/`Selector`/küçük dinleyiciler | kod incelemesi + `debugPrintRebuildDirtyWidgets` sayacı |
| UI isolate | Ana isolate'ta büyük JSON çözme/ağır hesap yok (`compute`/`Isolate.run`); **her** ağ çağrısında zaman aşımı; sonsuz spinner yok (zaman aşımı + hata + yeniden dene) | kod taraması + simülatörde `slow`/`offline` enjeksiyonu |
| Kilitlenmeme | Monkey testi: rastgele 20.000 olay, **0 çökme, 0 ANR**; arka plan/ön plan 100 döngü sonrası bellek sızıntısı yok | `adb shell monkey`, `dumpsys meminfo`, logcat |
| Backend | p95 ≤ 100 ms (liste uçları, 50 eşzamanlı kullanıcı), olay döngüsü gecikmesi p99 ≤ 50 ms, komut yolu REST→broker→simülatör state ≤ 300 ms | `autocannon` + `perf_hooks.monitorEventLoopDelay` yerel yığında |
| Firmware | `loop()` en uzun yineleme ≤ 20 ms (bloklayan iş yok), web portalı ilk boyama ≤ 1.5 sn (gzip + LittleFS) | derleme boyutu + simülatör/Node ölçümü; donanımda doğrulanmadı |

### Teknik düzeltme listesi (ölçümle öncelik verilir)

- `context.watch<AutomationState>()` kök dinlemeleri → `select`/`Selector`/bölünmüş `ChangeNotifier`; poll'da değişim yoksa `notifyListeners` yok.
- Büyük sayfalar (`dashboard_page`, `service_mode_page`, `device_settings_page`) → küçük `const` widget'lar, `RepaintBoundary` (devre arka planı, panjur animasyonu), tembel listeler (`SliverList`/`ListView.builder`), `AutomaticKeepAlive` yerinde.
- `google_fonts` çalışma zamanı indirmesi → paketlenmiş fontlar (ilk kare takılması ve çevrimdışı tutarsızlık biter); görseller `precacheImage`, doğru çözünürlük, `cacheWidth`.
- Ağır efektler (bulanıklık/`BackdropFilter`, çok katmanlı gölge) ölçülür; bütçeyi aşanlar hafifletilir; "hareketi azalt" (`MediaQuery.disableAnimations`) ve düşük donanım için efekt azaltma.
- Her yükleme durumu: iskelet (shimmer) + zaman aşımı + hata kartı + yeniden dene; "dönüp duran" ekran yok.
- Backend: `compression`, gereksiz sorgu/N+1 temizliği, indeksler, `GET /homes` tek sorgu, MQTT köprüsünde toplu yazım (C1), uzun işlerin olay döngüsünü bloklamaması.
- Firmware gömülü portal: gzip + `LittleFS`/`ETag`, tek `innerHTML` yenilemesi yerine hedefli DOM güncellemesi.

### Görsel tasarım yönü

Ürün: premium bir akıllı ev kumandası. Hedef his: **sakin, güvenilir, canlı** — karanlıkta kullanılan bir ev paneli gibi (koyu tema birinci sınıf), açık tema da eşit kalitede.

1. **Tasarım dili (tek kaynak):** `lib/ui/theme/` altında renk/tipografi/boşluk/yarıçap/gölge/hareket **belirteçleri** (design tokens); marka renkleri korunur; semantik renkler (açık/kapalı/uyarı/hata/çevrimdışı) tek tabloda; WCAG AA kontrast; tipografi ölçeği (paketlenmiş font).
2. **Hareket dili:** sayfa geçişleri (paylaşılan eksen/solma), `AnimatedSwitcher`/`AnimatedContainer` ile durum geçişleri, **panjur kartında canlı konum animasyonu** (perde iner/çıkar, yüzde sayacı), ışık kartında yumuşak yanma (renk + parıltı), komut onayında mikro-etkileşim + dokunsal geri bildirim (`HapticFeedback`), çevrimdışı/yeniden bağlanma durum geçişleri, servis sihirbazında adım ilerleme animasyonu ve başarıda kutlama. Süreler 120–350 ms, `Curves.easeOutCubic` ailesi; **hareketi azalt** ayarına saygı.
3. **Ekran bazlı cila:** Dashboard (durum şeridi, oda kartları, hızlı senaryolar), giriş/kayıt, aile & misafir, zamanlı kurallar, ayarlar, **servis kurulum sihirbazı (vitrin ekranı)**, süper/servis panelleri, boş/hata/yükleme durumları, onay diyalogları, ikonografi tutarlılığı.
4. **Erişilebilirlik:** yazı ölçeği 1.5'te taşma yok, dokunma hedefi ≥ 48 dp, `Semantics` etiketleri, TalkBack gezinmesi, renge bağımlı olmayan durum göstergeleri.
5. **Gömülü cihaz portalı (WebPortal) ve fabrika aracı:** aynı renk/tipografi dili, taşmasız mobil görünüm; fabrika aracı (Tk) tutarlı tema ve net hata/başarı geri bildirimi.

### Süreç (Workflow)

`Ölç → Tasarım yönü (ui-designer) → Uygula (ekran grupları paralel, dosya sahipliği) → Ekran görüntüsü incelemesi (bağımsız tasarım eleştirmenleri, her profilde) → Performans yeniden ölçümü →
Kapı: bütçeler tutuyor + 0 işlevsel gerileme (integration_test + monkey + analyze + test) → değilse döngü`. Görsel eleştiri bağımsız ajanlarca yapılır (uygulayan kendi işini onaylamaz).

## 5d. Dalga 3 birikmiş işler (entegrasyon / teslimat) — Dalga 2 bitince

Yürütme sırasında ortaya çıkan, henüz yapılmamış işler (hiçbiri unutulmasın):

0. **★ Wi-Fi servis akışı (WP-W) — KULLANICI HATIRLATTI ("ev_otomasyon: Wi-Fi servis akışı işini unutma").** Kaynak: `EVOTOMASYON_CANLI_TEST_KONTROL_LISTESI.md` **Aşama 16** (16.1–16.6): servis sorumlusu, panonun kurtarma ağına (192.168.4.1) bağlanıp modem Wi-Fi bilgilerini yükler.
   Tespit edilen İKİ ÇATIŞMA (benim değişikliklerim bu akışı bozuyordu): (a) firmware `wifi/scan|connect` artık `X-Device-Key` istiyor — teknisyen müşteride AP'dayken internet yok, anahtarı sunucudan alamaz; (b) `Capabilities.canOpenWifiRecovery` girişsiz kullanıcı için `false` — oysa 16.1 "giriş yapılmış olsun ya da olmasın" kartın görünmesini şart koşuyor.
   **Çözüm (güvenlik modeli: cihaza özel WPA2 AP parolasını bilmek = fiziksel erişim):** firmware'de yalnız Wi-Fi uçları (`scan`, `connect`, yeni `GET /api/wifi/status`) için **AP kaynaklı anahtarsız erişim** (istemci SoftAP arayüzünde + AP WPA2 korumalı + cihaz provizyonlu); diğer HER uç anahtarlı kalır. Etikete **ikinci karekod** (`WIFI:T:WPA;S:AHBU-<MAC6>;P:<ap_pass>;;`) → telefon kamerası tek dokunuşla ağa bağlanır.
   Durum: W1 (firmware AP-kaynak yetkisi + tarayıcı arayüzü) FW-net'e verildi; G3 (etiket ikinci karekodu) G'ye verildi; **W2 (uygulama) Dalga 2 bitince:** (i) ServiceModePage'de "Pano Wi-Fi & Modem Kurulumu" kartı + "Wi-Fi Kurulum & Kurtarma Sihirbazı" düğmesi GİRİŞ DURUMUNDAN BAĞIMSIZ (16.1); (ii) WifiRecoveryDialog anahtarsız AP modunda çalışır — "Pano Bağlantısını Test Et" (16.2: yeşil başarı), "Modem Wi-Fi Karekodu Tara (Kamera)" düğmesi + SSID alanında QR ikonu (16.3), "Ağları Tara" listesi sinyal çubuğu+kilit simgesi, dokununca SSID seçilir ve şifre kutusuna odaklanılır (16.4), "Yeni Wi-Fi Şifresini Panoya Yükle" → sonucu `wifi/status` ile bekle, başarıda kurtarma modunun bittiğini göster (16.5); AP adı/parolası artık etiketten (sabit `AHBU-Kurtarma`/`ahbu1234` metinleri kalkar); servis sihirbazı adım 5 aynı bileşeni kullanır (kopya yok); (iii) `Capabilities`'te Wi-Fi AP akışı için girişsiz erişim (cihaz zaten zorluyor); (iv) tarayıcı arayüzü 16.6 firmware'de; (v) QA simülatörü (port 8081 "AP" örneği) AP-kaynak kuralını uygular (Q senkronu); (vi) canlı test listesi Aşama 16 metni güncellenir (yeni AP adı/parola modeli, ikinci karekod); (vii) emülatör QA'sında uçtan uca senaryo.

1. **Push belirteci gizliliği (sunucu):** `POST /auth/logout-all` ve oturumları toplu iptal eden her akış (`revokeAllUserSessions`, parola değişimi, hesap dondurma) sonrasında `push.disableAllTokensForUser(userId)` çağrılmalı (WP-H `push_service.js`'te hazır, testli; hiçbir yerden çağrılmıyor). Aksi halde gece bildirimi (ev adı + açık lamba özeti) çıkış yapmış telefona düşebilir. Tek cihaz çıkışında yalnız o cihazın belirteci (istemci tarafı).
2. **Yeni firmware sürüm imajı (TESLİMAT):** mevcut `firmware_releases/v1.0.0` ve `v1.0.1` imajlarında seri provizyon (`FACTORYINIT`/`RESETKEY`) YOK → bu imajla yüklenen kart USB ile provizyonlanamaz. Firmware işleri (FW-core F12, FW-net N6) bitince: `pio run` → birleşik (0x0) imaj (`merge_bin`, boot_app0 0xE000 dahil) → yeni sürüm klasörü (`v1.1.0`) + `fw` sürüm dizgisi tutarlı + fabrika aracının `load_version_info` formatı; imajda `FACTORYINIT` metninin bulunduğu doğrulanır (`strings`/ikili tarama); eski imajlar silinmez ama rehberde "kullanılmaz" notu.
3. **Çevrimiçi olunca uzlaştırma (köprü, C paketi alanı):** `homes.child_lock_requested` ve pano değişimi sonrası bekleyen `set_runtime`/çocuk kilidi niyeti, cihaz çevrimiçi olduğunda (canlı state/status) yeniden uygulanmalı (B raporu: `child_lock.sync: pending_device_online`, `runtime_sync`). Şu an yalnız niyet kaydediliyor.
4. **WP-H Flutter push yaması** (diğer oturum, `docs/superpowers/analysis/wp-h-flutter/yamalar/`): kabuğa bağlı mimari; `pubspec.yaml` firebase hunk'ı ayrı. **Kullanıcı onayı + Firebase yapılandırması (google-services.json / GoogleService-Info.plist) gerekir** → bağımlılıklar ayrı onay kapısı. Uygulama sırası: Dalga 2 entegrasyonu yeşil olduktan sonra.
5. **Sunucu çökme gözlemi:** QA'da bir kez 0xC0000409 çıkış kodu (Windows) görüldü, yeniden üretilemedi; üretimde süreç yöneticisi (PM2/systemd) ile otomatik yeniden başlatma ve `unhandledRejection/uncaughtException` günlüğü şart (runbook §5). Ağır yükte `connectionTimeoutMillis 5000` zaman aşımları görüldü: havuz/zaman aşımı değerleri yük testinde (Dalga 5) ayarlanır.
6. **Depo hijyeni (kullanıcı kararı):** `Arduino/examples/**`, `Firmware/`, `*.zip` içindeki satıcı demo Wi-Fi/bulut sabitleri; `ev_otomasyon_servis_yazilimi/labels/AHBU-S3-DD8754_label.png` eski PIN/QR içeriyor (git dışı). Silme önerilir, kullanıcı onayı beklenir.
7. **Ürün kararları (kullanıcıya):** (a) çocuk kilidinde duvar anahtarı hareketteki panjuru durdurabilsin mi (uygulandı: evet); (b) gece hatırlatması varsayılan açık mı (şu an açık); (c) Firebase eklensin mi.
8. **Dağıtım (BLOKE):** SSH şifresi reddedildi; kullanıcı `authorized_keys`'e oturum anahtarını eklerse salt-okunur keşiften başlanır (`docs/DEPLOY_RUNBOOK.md`). Sunucu SSH parolası ve repoda ifşa olan tüm sırlar döndürülmeli (`docs/SECRET_ROTATION.md`).
9. **iOS:** Windows'ta derlenemez; Info.plist anahtarları statik doğrulanır, gerçek doğrulama macOS gerektirir.

## 6. Dağıtım (BLOKE — sunucu erişimi yok)

Sunucuya SSH şifresi kabul edilmedi (iki deneme). Aşağıdakiler **hazırlanır, uygulanmaz**; geçerli kimlik bilgisiyle sonra uygulanacak:

- `docs/DEPLOY_RUNBOOK.md`: salt-okunur keşif → yedek (`pg_dump`, `.env`, EMQX veri) → hazırlık ortamında deneme → sıfır-kesinti sırası → doğrulama → geri alma. **Üretimdeki kapı sistemine dokunmama** kuralları.
- `docs/SECRET_ROTATION.md`: döndürülecek tüm sırların listesi (değerler olmadan) ve sırası.
- Migration sırası: `018 → 019 → 020 → 021 → 022` (`scripts/migrate.js --baseline` ile mevcut canlı şemaya hizalanır).
- Cihazlar: yeni firmware **tüm panolara yeniden flash** gerektirir (MQTT kimliği ve yerel anahtar değişiyor); eski firmware yalnızca legacy authenticator açıkken çalışır.

## 7. Bilinen sınırlar (dürüstlük notu)

- Firmware değişiklikleri **yalnızca derleme** ile doğrulanabilir; I2C/panjur/Wi-Fi/TLS davranışı cihazda denenmeden "çalışıyor" denmez.
- EMQX/PostgreSQL entegrasyonu (bcrypt authn, PG authz, `retain` kuralları) bu makinede çalıştırılamaz; yapılandırma dağıtım öncesi hazırlık ortamında doğrulanmalıdır.
- Per-oda yetkisi (TASKS 1.4: "yalnızca yetkili odalar") şemada yoktur; bu planda kapsam dışıdır (rapora "açık madde" olarak yazılır).
- Git geçmişinden sır temizliği (`git filter-repo`) ve uzak sunucu sırlarının fiilen döndürülmesi kullanıcı onayı/erişimi gerektirir; plan yalnızca kodu ve rehberi hazırlar.

## 8. Bulgu kısa adları (kaynak: denetim raporu)

IDOR-komut · servis-PIN-global · sosyal-giriş-doğrulamasız · sahte-transaction · claim-yarışı · legacy-claim · sabit-parola-hesap · OTP-bypass ·
emergency-reset-PIN · devirde-veri-temizlenmiyor · replaceBoard · mqttBridge.publish-yok · zamanlı-kural-şema · TZ/çift-tetik · migration-sürüklenmesi ·
MQTT-izolasyon · sabit-MQTT-parola · TLS-doğrulama-kapalı · retained-cmd · sır-repoda · API-anahtarı · fw-web-kimliksiz · AP-parolası · CORS ·
strncpy-null · I2C-mutex · interlock-yarışı · RS485-mutex · TWDT-yok · ext-röle-≥8 · yön-değişimi-konum · kurtarma-AP-erişilemez ·
komut-sözleşmesi · rollback-yok · bayat-bağlantı-durumu · logout-temizlik · refresh-tek-uçuş · rol-global · aile-listesi-tip · biyometrik-Android ·
QR-parser-gevşek · test-boşlukları.
