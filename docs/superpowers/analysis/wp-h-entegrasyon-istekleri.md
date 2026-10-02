# WP-H — Entegrasyon istekleri (kilitli dosyalar için) ve doğrulama sonucu

> Durum (2026-10-01 ~18:00): WP-H'nin **yalnız yeni dosyalarla** yazılan kısmı bitti ve gerçek PostgreSQL 18.4'te doğrulandı.
> Kilitli dosyalardaki entegrasyon **uygulanmadı**; bunun yerine izole bir kopyada uygulanıp tüm paket çalıştırıldı ve sonuç
> **tek bir yama dosyası** olarak hazırlandı: [`wp-h-entegrasyon.patch`](wp-h-entegrasyon.patch). Siz "şimdi uygula" demeden
> `server.js`, `device_service.js`, `device_routes.js`, `docs/CONTRACTS.md`, `lib/**`, `android/**`, `ios/**`, `pubspec.yaml`'a **dokunulmaz**.

## 1. Doğrulama özeti

| Ne | Sonuç |
|---|---|
| WP-H yalnız yeni dosyalar (`server/test/peace/**`), PostgreSQL **yok** | 327 testten 299 geçti, 0 hata, 24 PostgreSQL'e bağlı test atlandı, 4 `todo` (entegrasyon bekleyenler) |
| Aynı dizin, **gerçek PostgreSQL 18.4** (`001…030` sıfırdan migrate edilmiş) | **323 geçti, 0 hata, 0 atlanan**, 4 `todo` |
| Mevcut ağaçta `npm test` (PostgreSQL yok) | 1422 test: 1359 geçti, **0 hata**, 59 atlandı, 4 `todo` |
| **Yama uygulanmış izole kopya**, `npm test` (PostgreSQL yok) | 1425 test: 1366 geçti, **0 hata**, 59 atlandı, **0 `todo`** (4 entegrasyon testi gerçek denetime döndü) |
| Yama uygulanmış kopya, **tüm PostgreSQL testleri açık** (peace + `pg_live` + köprü `pg_integration`) | 1425 test: **1424 geçti, 0 hata**, 1 atlandı |
| `git apply --check wp-h-entegrasyon.patch` (şimdiki çalışma ağacı) | temiz uygulanır |
| **Uçtan uca duman testi** (yama uygulanmış kopya: gerçek `start()` + gerçek giriş + gerçek PostgreSQL, MQTT yok) — `wp-h-smoke-e2e.js.txt` | 12/12 adım geçti: hatırlatma `DRY_RUN` ile başlar; `PUT/DELETE /me/push-tokens` (`/api/v1` ve eski `/api`), kimliksiz 401, geçersiz gövde 400; peace GET v2 canlı veri + `no-store`; `close-all` (broker yok) `502`, bildirim **çözülmez**, kayıt yazılmaz; zarif kapanış hatasız |

PostgreSQL doğrulamasında **gerçek bir test hatası bulundu ve düzeltildi** (misafir satırı `home_users_guest_window_check` CHECK'ini ihlal ediyordu; yalnız test düzeneği, sunucu kodu değil).
Sahte db'nin göstermediği SQL davranışları artık gerçek veritabanında kanıtlı: `ON CONFLICT … WHERE … RETURNING` ile **eşzamanlı** talepte tek kazanan, bildirim çözme durum kısıtı
(`claimed/failed/skipped_offline/clear` çözülmez), iki eşzamanlı "Hepsini kapat"ta **tam bir** çözücü, denetim yazımı hata verirse çözümün **geri alınması**, çok panolu ev düzeni sorgusu, `DATE`'in saat dilimiyle kaymaması.

Kullandığım PostgreSQL: **kendi geçici örneğim** (`127.0.0.1:55432`, `scratchpad/pg55432`, QA yığınının gömülü PostgreSQL ikili dosyalarıyla; QA yığınının `54329` portuna, veri dizinine ya da emülatöre **dokunulmadı**). Doğrulamalar bitti, örnek **kapatıldı** (veri dizini oturumun geçici klasöründe duruyor; yeniden doğrulama gerekirse birkaç saniyede açılır). Not: PostgreSQL'i arka plan görevi içinde çalıştırırsanız görev süre sınırında öldürülünce çocuk süreçleri de ölür (bu yüzden bir kez 58 sahte hata gördüm ve örneği yeniden başlattım; kod hatası değildi).

Yeniden üretmek için: tam migrate edilmiş boş bir veritabanı verip
`EV_PG_TEST_URL=postgresql://…/<db> node --test "test/peace/**/*.test.js"` (ve yama sonrası `node --test test/devices/pg_live.test.js`).

## 2. Yamanın içeriği (`wp-h-entegrasyon.patch`, 11 dosya, `git apply` ile)

| Dosya | Sahibi | Ne değişir |
|---|---|---|
| `server/src/server.js` | A | `createApp`: `createPushService({db})` + `createPushRouter({pushService, authenticateToken})`, `/api/v1` ve `/api` altına bağlanır (`app.locals.pushService`). `start()`: **kendi try/catch'inde** `require('./peace_reminder').start({db, push})`; kapanışta `['peace-reminder', …]` adımı **mqtt ve db'den önce** (scheduler'dan sonra). |
| `server/src/routes/device_routes.js` | B | `POST /peace-notification/close-all`: `notice_id`/`include_shutters` iletilir; `GET /peace-notification/:home_id`: `noStore(res)`. |
| `server/src/services/device_service.js` | B | Tembel `get peace()` (`createPeaceService`: `publishCommand`, `newCommandId`, `audit` DeviceService'inkiler); `getPeaceNotificationSettings` ve `closeAllOpenLights` **ince devir** (yetki `can('group')` DeviceService'te kalır). Kullanılmayan `_homeDeviceStates`/`_homeTopicId` **bilerek silinmedi** (birleştirme yüzeyi küçük kalsın; istenirse silinebilir). |
| `server/.env.example` | A | `FCM_PROJECT_ID`, `FCM_SERVICE_ACCOUNT_FILE`, `PEACE_*` yer tutucuları (gerçek değer yok). |
| `docs/CONTRACTS.md` | orkestratör | `wp-h-contracts-satirlari.md` içeriği: §1.5 satırları, §1.5b maddeleri, yeni §2.5, §6 satırları, §7 H satırı (dosya adları ayrı ayrı yazılı). |
| `server/test/devices/{_world,commands,peace_diagnostic,b13_firmware_contract,pg_live}.test.js` | B | v1 davranışına bağlı 6 test + sahte db v2'ye uyarlandı (aşağıda **davranış değişiklikleri**). |
| `server/test/peace/peace_integration.test.js` | H | Dört `todo` bayrağı kaldırıldı (artık gerçek denetim). |

Uygulama: `cd G:\site\ev_otomasyon && git apply --3way docs/superpowers/analysis/wp-h-entegrasyon.patch`. Yama, ben kopyayı aldığım andaki çalışma ağacına göre üretildi ve **şimdi** temiz uygulanıyor;
bu dosyalarda sonradan değişiklik olduysa `--3way` ya da elle (üç yöntem metin olarak §3'te) birleştirin. `device_service.js`'teki dokunuş üç küçük yer: getter, iki yöntem gövdesi.

## 3. v1 → v2 davranış değişiklikleri (B'nin testlerine yansıyanlar — **karar gerekebilir**)

1. **`closeAllOpenLights` artık yalnız CANLI veriye göre komut üretir.** Cihaz canlı değil (`is_online` değil ya da `last_seen_at` > 120 sn) ⇒ `409 DEVICE_OFFLINE` (v1 yalnızca `is_online` bakıyordu).
2. **İyimser `endpoints.current_state = FALSE` yazımı YOK** (v1 yayından sonra yazıyordu; cihaz komutu uygulamasa DB yalan söylüyordu). Gerçek durum `state` yankısıyla gelir.
3. **Evde priz varsa** tek `all_lights_off` yerine yalnız açık ışık röleleri `{relay:N,state:false}` ile kapanır (priz kapanmaz); **açık panjur çiftleri `{shutter:P,cmd:"down"}`** ile indirilir (`include_shutters:false` ile kapatılabilir).
4. **Hiçbir şey açık değilse komut GÖNDERİLMEZ** (`nothing_to_do:true`, bildirim yine çözülür). v1 "0 açık lambada yine de komut iletilir" diyordu. **Karar noktası:** state yankısı bayatsa fiziksel olarak açık kalmış lamba olabilir.
   Önerim: v2 olduğu gibi kalsın (yanıt dürüst: "komut gönderilmedi", uygulama "kapatıldı" göstermez; priz olan evlerde "yine de all_lights_off" zaten güvenli değil). İsterseniz "priz yoksa yine de `all_lights_off`" tek satırlık değişikliktir; haber verin.
5. **Bildirim kaydı:** v1'in her tıklamada eklediği satır yerine, çözülecek bildirim varsa o satır çözülür (`resolved_via='close_all'`, `command_id`, `resolved_by_user_id`); yoksa `status='manual'` günlük satırı eklenir. Denetim kaydı (`device_audit_logs`, `peace_close_all`) her çağrıda yazılır.
6. **Çok panolu ev:** ev konusu tüm panolara gittiği için, başka panoda aynı kanal numarası priz/panjur rölesiyse o lamba **gönderilmez** (`skipped_count`, bildirim çözülmez). Kalıcı çözüm komuta pano adresi eklemek (firmware/sözleşme).
7. **GET** yanıtı: v1 anahtarları durur; `enabled/time/timezone/stale/devices_*/open_shutters/last_notice` eklenir; `open_lights` öğelerinde artık `current_state` yok; `summary_text` biçimi değişti ("Salonda 2 lamba, 1 panjur açık.").

Flutter tarafında (henüz yazılmadı; D/E): `closeAllOpenLights` yanıtında `nothing_to_do`/`skipped_count`/`resolved`; GET'te `stale` ve `last_notice` (uygulama içi yedek afiş). v1 anahtarları durduğundan **mevcut uygulama bozulmaz**.

## 4. Dağıtım sırası (sunucu, sizin onayınızla; ben dağıtım yapmam)

1. Kodu al; **migration `030`'u uygula** (`MIGRATE_CONFIRM=<db> node scripts/migrate.js`; 022 ve 025'ten sonra; tek transaction, idempotent). QA veritabanınıza **eski** 030 uygulanmışsa checksum uyuşmaz: QA DB'yi sıfırlayın (ya da `schema_migrations.checksum`'u güncelleyin); dosya artık donduruldu.
2. `PEACE_REMINDER_DRY_RUN=true` ile başlat → ilk gece kayıt tutulur, **push gitmez**; `peace_notification_logs`'u kontrol et (`sent` yerine `no_recipients`/`clear`, `details`'ta açık öğeler).
3. FCM: Firebase projesi + servis hesabı anahtarı **dosya olarak** (`FCM_PROJECT_ID`, `FCM_SERVICE_ACCOUNT_FILE`); `DRY_RUN=false`, önce `PEACE_REMINDER_HOME_ALLOWLIST=<kendi evin>`; sonra allowlist'i boşalt.
4. Acil durdurma: `PEACE_REMINDER_ENABLED=false` (yeniden başlatma yeter; tanınmayan değer de kapatır).

## 5. Ürün kararları (kullanıcıya sorulacak)

- **`homes.peace_notification_enabled` varsayılanı AÇIK** (şema varsayılanı; değerlendirici `NULL`'u da açık sayar): uygulamanın yeni sürümünü kurup bildirim izni veren her ev sahibi/sakin gece hatırlatması alır; kapatma ayarı mevcut. Varsayılan KAPALI isterseniz yeni bir migration (`031`) gerekir.
- Hatırlatma saati ev başına ayarlı (varsayılan 23:30, `homes.timezone` yereli).
- §3 madde 4: hiçbir şey açık değilken yine de komut gönderilsin mi (önerim: hayır, yukarıda gerekçe).

## 6. Doğrulanamayanlar (bu ortamda mümkün değil)

Gerçek FCM/APNs teslimi; Firebase projesi/kimlik bilgisi (yok); gerçek cihazda Android soğuk açılış ve iOS APNs; EMQX/gerçek firmware ile uçtan uca "Hepsini kapat"; saat dilimi/DST davranışı için gerçek gece (birim testlerde İstanbul/UTC/DST simüle edildi);
yük altında 500+ ev (turda en çok 500 ev, ev başına 15 sn zaman aşımı, eşzamanlılık 10; çalıştırılmadı).

## 7. Flutter entegrasyonu (sunucudan sonra; D/E sahipleri)

`wp-h-flutter/` (README → ENTEGRASYON.md → PUSH_KURULUM.md). Sandbox: `flutter analyze` 0 sorun, 209 birim testi (uygulama içi yedek afiş `PeaceNotice.fromSettings` dahil), `flutter build apk --debug` başarılı (yedek afiş eklenmeden önce). `pubspec.yaml`'a `firebase_core ^4.15.0`, `firebase_messaging ^16.7.0`
(+ dev `fake_async`) eklenir (D'nin `integration_test` eklemesiyle aynı dosya); Android bildirim kanalı `peace_reminder` (Kotlin 12 satır); iOS `UIBackgroundModes` + Push yeteneği (macOS gerekir, **doğrulanamadı**).
