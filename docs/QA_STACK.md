# Yerel QA Yığını (`tools/qa_stack`)

Bu belge, **tüm sistemi (Flutter uygulaması + Node/PostgreSQL/MQTT sunucusu + ESP32-S3 firmware)** bu makinede, **yalnızca `127.0.0.1` üzerinde**,
gerçek sunucuya/internete/Docker'a dokunmadan uçtan uca sınamak için kurulan yığını anlatır. Her şey `tools/qa_stack/` altındadır;
çalışma verisi (veritabanı, sırlar, hesaplar, loglar) yalnızca **gitignore'lu** `tools/qa_stack/.runtime/` içine yazılır.

> Bu yığın bir **firmware değildir** ve gerçek EMQX değildir. Neyi kanıtlayıp neyi kanıtlamadığı §9'da açıktır; "yeşil" sonuç sahada çalışacağı anlamına gelmez.

## 1. Kurulum ve ilk çalıştırma

Gereksinim: Node ≥ 20.11 (Node 24'te geliştirildi), Windows. **Docker, `psql`, `gcc` gerekmez.**

```bat
cd G:\site\ev_otomasyon\tools\qa_stack
npm install                 :: yalnızca bu klasöre kurar (embedded-postgres, aedes, mqtt, pg, bcryptjs, smtp-server, acorn ...)
node run.js up --stage2     :: PostgreSQL + MQTT broker + simülatörler + SMTP çukuru + migration + sunucu + REST tohumlama
                            ::   temiz kurulum (initdb dahil) ~100 sn'ye kadar (ölçülen 17-103 sn; makine yüküne ve disk önbelleğine bağlı),
                            ::   mevcut veritabanıyla ~10-15 sn (ölçülen 7-14 sn)
node run.js status          :: bileşenlerin durumu (çıkış kodu 0 = hepsi çalışıyor)
node run.js smoke           :: uçtan uca duman testi (REST + MQTT + simülatör, 23 denetim; ~10 sn)
node run.js down            :: temiz kapatır (yetim postgres.exe / sunucu bırakmaz)
```

`up` (stage2 olmadan) yalnızca altyapıyı (PG, broker, simülatörler) kaldırır; sunucuyu siz `server/`'dan kendi ortamınızla çalıştırabilirsiniz (§6).

**Tohumlama idempotenttir (§4):** mevcut veritabanında ikinci/üçüncü `up --stage2` (ya da `seed`) hiçbir varlığı çoğaltmaz, yeniden üretmez ve `accounts.json`'u değiştirmez;
çıktı `Tohumlama tamam (20/20 adim: 0 yapildi, 17 atlandi (zaten var), 3 dogrulandi)` der (ilk kurulumda `17 yapildi`).

**Sırlar ve oturumlar:** `up` her çağrıda yalnızca **dönen sırları** yeniden üretir: JWT sırrı, yönetici API anahtarı, MQTT arka uç parolası, EMQX API anahtarı/sırrı, SMTP parolası.
Veriye bağlı sırlar (`db_password`, `pin_pepper`, `local_key_secret`) `pgdata` ile birlikte yaşar ve yalnızca `reset` ile yenilenir (değişirlerse veritabanındaki PIN özetleri / şifreli yerel anahtarlar bozulurdu).
**JWT sırrı değişince daha önce verilmiş access token'lar (15 dk) geçersiz olur (`401`) ve uygulamada oturum düşebilir:** kullanıcı oturumları refresh token'la sürebilir (refresh token'lar
veritabanında özet olarak saklanır, sırdan bağımsızdır; istemci 401'de bir kez yeniler), ancak refresh'i olmayan servis PIN oturumları ve yenilemesi başarısız olan oturumlar "Oturumunuz sona erdi" ile girişe döner.
**`--keep-secrets` hiçbir sırrı yenilemez ve oturumları korur** (yeniden başlatma sonrası eski access token geçerli kalır). Her ikisi de `test/seed_idempotency.test.js` ve `test/secrets.test.js` ile sınanır.

## 2. Komutlar

| Komut | Ne yapar |
|---|---|
| `up [--stage2] [--no-seed] [--public-host H] [--devices 2\|3] [--time-scale N] [--keep-secrets] [--pg-port N] [--cors-origins a,b] [--foreground]` | Yığını arka planda başlatır |
| `status [--json]` | Bileşen durumu |
| `logs [daemon\|broker\|pg\|api\|sim\|mail\|migrate] [-n N] [-f]` | Log gösterir |
| `down` / `reset` | Kapatır / kapatır + `.runtime`'ı siler (veritabanı, sırlar, hesaplar, simülatör "NVS" dosyaları) |
| `accounts` | `.runtime/accounts.json`'u yazdırır (**parolalar içerir; yalnızca yerel**) |
| `seed` | Çalışan yığında REST tohumlamayı yeniden çalıştırır. **İdempotent** (§4): var olanı çoğaltmaz/yeniden üretmez, yalnızca eksik/süresi dolmuş/bozulmuş olanı yapar; adım adım `YAPILDI`/`ATLANDI`/`DOGRULANDI`/`HATA`/`ENGELLENDI` yazar. Çıkış kodu 0 = tümü tamam, 2 = bir adım başarısız |
| `smoke` | 23 denetimli uçtan uca duman testi (yan etkileri geri alınır) |
| `sqlcheck [--all] [--json]` | `server/src` + `server/scripts` içindeki SQL'leri **gerçek PG'ye karşı `PREPARE`** ile denetler (çalıştırmaz) |
| `sweep [--quick] [--only ÖNEK] [-v]` | **Gerçek PG + gerçek sunucuya düşman girdi / akış süpürmesi** (§7) |
| `sql "<SORGU>"` | Çalışan PG'ye tek sorgu (psql yok); sonuç JSON |
| `mails [N]` | SMTP çukuruna düşen e-postalar (OTP, etkinleştirme, şifre sıfırlama kodları). **`mails`** = **en yeni en çok 30** e-postayı numaralı listeler (1 = en yeni): `<no>. <zaman damgası>  To: …  Subject: …` (zaman damgası `.eml` dosya adının ilk 13 hanesi = epoch ms). **`mails N`** = listedeki **N. e-postanın ham gövdesi** (quoted-printable çözülmez; `mails 10` "son 10 e-posta" değil, 10 numaralı e-postadır). N yoksa (ya da kutu boşsa) `Boyle bir e-posta yok: N …` **hatası (stderr) ve çıkış kodu 1**; N pozitif tam sayı değilse de hata + çıkış kodu 1. N verilmeden kutu boşsa `E-posta yok.` (çıkış kodu 0) |
| `fwcheck [--update]` | Simülatörün portlandığı firmware kaynaklarının **sürüklenme** denetimi (§5.5) |
| `npm test` | Birim + entegrasyon testleri (broker, ACL, PG, simülatör, firmware uyumluluk; tohumlama idempotency'si gerçek yığında — §8) |

## 3. Bileşenler ve adresler

| Bileşen | Adres | Not |
|---|---|---|
| PostgreSQL 18 (gömülü) | `127.0.0.1:54329`, DB `ev_qa` | kalıcı `.runtime/pgdata`; rastgele parola `.runtime/secrets.json` |
| MQTT broker (aedes, EMQX taklidi) | `tcp 127.0.0.1:1883`, `ws 127.0.0.1:9001` | TLS **yok**; kimlik/ACL `mqtt_credentials` + `mqtt_acl` tablolarından (bcrypt) |
| Broker kontrol (EMQX v5 REST taklidi) | `http://127.0.0.1:18083` | `POST /api/v5/clients/{id}/kick`, `GET /api/v5/clients` ... (sunucunun `kick`'i bunu kullanır) |
| REST API (gerçek `server/`) | `http://127.0.0.1:5000/api/v1` (+ `/api`) | alt süreç; **`server/.env` yüklenmez** (üretim değerleri/SMTP sızmasın diye boş çalışma dizini + asgari ortam) |
| SMTP çukuru | `127.0.0.1:2525` (STARTTLS, kendinden imzalı) | e-posta dışarı çıkmaz; gövde loga yazılmaz (`mails` ile okunur) |
| Simülatör `new1` | `127.0.0.1:8081` — `AHBU-S3-0A0001`, 8 röle, **provizyonsuz** | servis kurulum sihirbazı / cihaz AP simülasyonu. **Wi-Fi servis akışı (CONTRACTS §3d):** istemci konumu varsayılan `ap`; önce `factory/init` (veya `/__sim/provision`; açık AP → WPA2), sonra **anahtarsız** `wifi/scan\|connect\|status` (§5.2) |
| Simülatör `home1` | `127.0.0.1:8082` — `AHBU-S3-0A0002`, 8 röle, provizyonlu + bulutta | ev 1 cihazı; LAN (doğrudan) mod + MQTT |
| Simülatör `stock2` | `127.0.0.1:8083` — `AHBU-S3-0A0003`, 16 röle (ek modül), provizyonsuz | yalnızca `up --devices 3` |
| Süpervizör kontrol ucu | `127.0.0.1:18090` | `/health`, belirteçli `/shutdown` (daemon'u `down` kapatır) |

Portlar ortam değişkenleriyle değişir: `QA_PG_PORT`, `QA_MQTT_PORT`, `QA_MQTT_WS_PORT`, `QA_BROKER_CONTROL_PORT`, `QA_SUPERVISOR_PORT`, `QA_API_PORT`, `QA_SMTP_PORT`, `QA_SIM_PORT_1..3`.
Çalışma dizini `QA_RUNTIME_DIR` ile değişir (varsayılan `tools/qa_stack/.runtime`). **Yalıtılmış deneme** için ayrı dizin + ayrı portlar verin (`seed_idempotency.test.js` böyle çalışır): kendi `.runtime`'ınıza ve varsayılan portlarınıza dokunulmaz.
`reset` yalnızca adı `.runtime` ya da `qa_runtime…` ile başlayan ya da geçici dizin altında olan çalışma dizinlerini siler (başka bir klasörü yanlışlıkla silmez).

### Emülatör (Android) ve Windows/Chrome

- Emülatörde makinenin `127.0.0.1`'i **`10.0.2.2`**'dir; yığın `up` çıktısında hazır komutu yazar:
  `flutter run -d emulator-5554 --dart-define=API_BASE_URL=http://10.0.2.2:5000/api --dart-define=MQTT_TLS=false --dart-define=DEVICE_AP_HOST=10.0.2.2:8081`
- Sunucu, istemciye MQTT adresi olarak `MQTT_PUBLIC_HOST` bildirir (varsayılan **`10.0.2.2`**). Windows/Chrome için `node run.js up --stage2 --public-host 127.0.0.1`.
  Simülatör, `10.0.2.2` ve `localhost`'u kendi içinde `127.0.0.1`'e eşler.
- Alternatif (adres değiştirmeden): `adb reverse tcp:5000 tcp:5000` (ve 1883, 8081, 8082) → emülatör `127.0.0.1:5000` ile de ulaşır.
- Flutter web için CORS kökenleri varsayılan `http://localhost:7357`, `http://127.0.0.1:7357` (+ 8090): `flutter run -d chrome --web-port=7357`.
  **Cihazın yerel HTTP API'sine tarayıcıdan erişilemez** (firmware CORS vermez ve `Origin` ≠ `Host` ise `403 bad_origin` döner) — web yalnızca bulut modunda çalışır.
- **Android 9+ açık metin (cleartext) HTTP**'yi varsayılan engeller: `http://10.0.2.2:...` ve cihazın LAN API'si için **debug** derlemesi
  `src/debug/AndroidManifest.xml` (`usesCleartextTraffic`) + `src/debug/res/xml/network_security_config.xml` (tüm açık metne izin) ile açılır
  (`flutter build apk --debug` birleşik manifestinde doğrulandı). Release manifestinde ağ güvenlik yapılandırması (NSC) düz HTTP'yi yalnız `192.168.4.1`, `*.local` ve `localhost` için açar;
  **ancak NSC yalnız Java/Kotlin ağ yığınını kısıtlar, Flutter'ın `dart:io` HTTP istemcisi NSC'ye TABİ DEĞİLDİR** (statik kanıt: `flutter.jar`'da NSC ayrıştırıcısı yok; cihazda DOĞRULANMADI).
  Yani release'te de pano AP'si ve LAN doğrudan mod (ham IP) düz HTTP ile çalışması beklenir; düz HTTP'nin yalnız yerel adreslere gitmesini uygulama kodu sağlar (`AppConfig` + `isAllowedDeviceHost`).

## 4. Hesaplar ve tohum verisi

`up --stage2` (veya `seed`) **gerçek REST akışıyla** üretir; hepsi `.runtime/accounts.json`'a yazılır (repoya değil):

| Anahtar | Rol | Not |
|---|---|---|
| `super` | `super_user` | SQL ile oluşturulur (bcrypt); parolası `accounts.json` ile birebir eşitlenir |
| `staff` | `service_user` (kalıcı servis personeli) | admin API ile **parolayla** oluşturulur; ev 1'e `service_user` üyeliği (SQL). **İlk girişte zorunlu parola ekranı ÇIKMAZ** (`must_change_password=false`; aşağıya bakın) |
| `owner1` | ev 1 sahibi | cihaz `AHBU-S3-0A0002` claim edilmiş, 4 zamanlı kural, servis PIN'i |
| `owner2` | ev 2 sahibi (başka ev) | IDOR denemeleri için cihaz `AHBU-S3-0A0004` (simülatörsüz) |
| `resident`, `guest_valid`, `guest_expired` | ev 1: aile üyesi / 24 sa misafir / **süresi dolmuş** misafir (SQL ile) | |
| envanter `IN_STOCK` | `AHBU-S3-0A0001` (provizyonsuz sim), `AHBU-S3-0A0003` | claim için `setup_pin` accounts.json'da |

Cihaz UID'leri firmware kuralıdır: **`AHBU-S3-<MAC son 3 bayt, 6 hex>`**; simülatörün MAC'i UID'den türetilir (`02:A5:00:0A:00:02`).
`home1` simülatörü, claim yanıtındaki **tek seferlik `device_credential`** ile `POST /api/mqtt/config` üzerinden bulut kimliğini alır ve bulutta çevrimiçi görünür.

**Servis personeli ve zorunlu parola değişimi.** Sunucu, süper kullanıcının *parolayla* açtığı hesaba `must_change_password=TRUE` yazar (istemci ilk girişte "Şifrenizi Değiştirin" ekranına zorlar; bkz. `docs/CONTRACTS.md`).
QA'da servis personeliyle doğrudan denemek için tohum hesabı **gerçek REST akışıyla** (`POST /admin/users`) oluşturur, ardından bayrağı **SQL ile `FALSE` yapar**; `accounts.json`'daki parola geçerli kalır.
Her `up`/`seed` bayrağı yeniden denetler (eski tohumun bıraktığı `TRUE` da kapatılır). **Zorunlu parola akışını (ilk giriş → parola değiştir) tohumlanan hesapla DEĞİL, yeni oluşturulan bir hesapla sınayın:**
`qa.super@example.com` ile parolalı yeni bir kullanıcı/servis personeli açın (`POST /admin/users` ya da uygulamadaki yönetici ekranı; bayrak açık gelir).
Tohum hesabının parolasını uygulamada kendiniz değiştirirseniz `accounts.json` eskisinde kalır; bir sonraki `up`/`seed` parolayı `accounts.json` değerine **geri alır** (aşağıda "Onarım").

### Tohumlama davranışı (idempotent)

Her adım önce mevcut durumu OKUR; istenen durumdaysa hiçbir şey yazmaz. Sonuç: aynı yığında ikinci/üçüncü `seed` ya da `up --stage2` tohum varlıklarının (kullanıcı, ev, cihaz, envanter, üyelik, davet, zamanlı kural, servis PIN'i, MQTT kimliği)
kayıt sayılarını ve satır kimliklerini ile `accounts.json`'u (içerik **ve** dosya zamanı) değiştirmez. Gerçek PostgreSQL + gerçek sunucu üzerinde `test/seed_idempotency.test.js` ile sınanır.
Tek fark **oturum kayıtlarıdır** (`refresh_tokens`): tohum, owner1/owner2 için her çalıştırmada gerçek `POST /auth/login` yapar (JWT sırrı her `up`'ta değişebildiğinden önbellekli token kullanılamaz), bu da çalıştırma başına 2 oturum satırı ekler;
bu bir tohum varlığı değildir (QA veritabanında zararsız birikir; `reset` temizler).

| Varlık | Anahtar / karar |
|---|---|
| kullanıcılar | `accounts.json` parolası veritabanındaki özetle eşleşiyorsa dokunulmaz (owner1/owner2 için gerçek `POST /auth/login`); `register` yalnızca hesap yoksa |
| envanter, ev (claim) | cihaz envanterde (SQL) / ev sahibin listesinde (`GET /homes`) varsa ne `register` ne `claim` istenir |
| simülatör `home1` | zaten bu evin konusuna bağlı ve bulutta çevrimiçiyse bulut kimliği **yeniden üretilmez** (yeniden üretmek eski kimliği siler ve cihazı atar); yeniden başlatma sonrası bağlanması için ≤ 10 sn beklenir |
| zamanlı kurallar | anahtar = **ev + kural adı** (`label`: `Aksam lambasi`, `Gece kapat`, `Hafta ici panjur kapat`, `Hafta sonu panjur ac`); aynı adlı kural varsa eklenmez. Plan dışı (sizin eklediğiniz) kurallara dokunulmaz |
| aile üyesi / misafirler | üye evde doğru rolde ise **davet üretilmez** (`GET /homes/:id/members`); süresi dolmuş misafir zaten geçmişteyse dokunulmaz |
| servis personeli üyeliği | `home_users` satırı zaten `service_user` ise yazılmaz |
| servis PIN'i | `accounts.json`'daki PIN sunucuda hâlâ `active` (kullanılmamış, iptal edilmemiş, süresi dolmamış) ve ≥ 15 dk kalmışsa yenisi üretilmez |

**Onarım** (idempotent ≠ "hiç dokunma": bozulmuş/eksik olanı düzeltir):

- Eski sürümün ikinci `up`'ta bıraktığı **yinelenen zamanlı kurallar** silinir (aynı adlı kurallardan en küçük `id` korunur). Mevcut `.runtime`'ınızda `smoke` "kural sayisi 8" (12 ...) diyorsa tek bir `seed` düzeltir.
- `accounts.json` parolası geçersizse (uygulamada değiştirilmiş ya da `accounts.json` yenilenmiş) parola SQL ile **`accounts.json` değerine geri alınır** ve çıktıya not yazılır (`seed`: `NOT …` satırı; `up` özeti: `Tohumlama notu: …`). Yalnızca bu QA veritabanındaki sahte `@example.com` hesapları içindir. Önceden bu durumda `reset` gerekiyordu.
- Silinen aile üyesi / servis üyeliği geri eklenir; kullanılmış ya da süresi dolmuş servis PIN'i yenilenir; kopan simülatör bulut kimliği yeniden yazılır.

**Zamana bağlı varlıklar** (tohumun ömrü sınırlıdır): 24 saatlik misafir ve 2 saatlik servis PIN'i. Süresi dolunca bir sonraki `seed`/`up` yeniler (24 saatlik misafir "süre yenilendi" olarak, PIN yeni değerle `accounts.json`'a yazılır);
o ana kadar `accounts.json` eski değeri gösterir.

**Çıktı.** `seed` adım adım yazar; `up` özeti tek satırdır (her adım `YAPILDI`, `ATLANDI` = zaten var, `DOGRULANDI` = salt-okunur kontrol, `HATA` ya da `ENGELLENDI` = önkoşul adımı başarısız):

```text
ATLANDI    zamanli_kurallar  - 4 kural zaten var
ATLANDI    servis_pin  - PIN hala gecerli (~111 dk kaldi; yenisi uretilmedi)
DOGRULANDI dogrulama_cihaz_cevrimici  - cihaz bulutta cevrimici (MQTT -> kopru -> DB -> REST)

Tohumlama tamam  (20/20 adim: 0 yapildi, 17 atlandi (zaten var), 3 dogrulandi)
```

`N/N` yalnızca **başarılı** (yapılan + atlanan + doğrulanan) adımları sayar; başarısız ve `ENGELLENDI` adımlar ayrı yazılır (`KISMEN BASARISIZ  (14/20 adim: …; 3 basarisiz, 3 engellendi)`, çıkış kodu 2).
Temiz kurulumda `17 yapildi`, tekrarda `0 yapildi` görülür; `0 yapildi` olmayan bir tekrar, o adımın gerçekten bir şey düzelttiği anlamına gelir.

**Hız sınırı.** Sunucu girişi IP başına 15 dk'da 30 istekle sınırlıdır (tüm istemciler `127.0.0.1`'dir; sayaçlar sunucu belleğindedir). Tekrarlanan `seed` yalnızca owner1/owner2 için 2 giriş yapar (diğer hesapların parolası SQL ile doğrulanır); `smoke` 6 giriş yapar.
`HTTP 429 RATE_LIMITED` görürseniz bildirilen süre kadar bekleyin ya da `up` ile sunucuyu yeniden başlatın.

## 5. Cihaz simülatörü

`sim/device_sim.js` — firmware **kaynağının birebir portları** üzerine kurulu bir "pano":

### 5.1 Mimari (hangi parça neye dayanır)

| Simülatör modülü | Dayandığı firmware kaynağı | Doğrulama |
|---|---|---|
| `sim/fw/shutter_fsm.js` | `src/ShutterFsm.h` (panjur durum makinesi, ölü zaman, konum, kesintisiz çalışma sınırı) | firmware'in **kendi Unity testlerinin birebir portu** (`test/fw_shutter_fsm.test.js`, 37 test) |
| `sim/fw/interlock_guard.js` | `src/RelayRules.h` (sürücü seviyesi emniyet) | `test/fw_relay_rules.test.js` (14 test) |
| `sim/fw/di_gate.js` | `src/DiGate.h` (60 ms süzgeç, çocuk kilidi, "basış işlendi" biti) | `test/fw_di_gate.test.js` (23 test) |
| `sim/fw/sysconfig.js`, `netutil.js` | `src/SystemConfig.h`, `src/NetUtil.h` | `test/fw_system_config.test.js` (19), `test/fw_netutil.test.js` |
| `sim/fw/net_time.js` | `src/NetTime.h` (ağ katmanının "son olay + bekleme" zamanlayıcıları: yeniden bağlanma geri çekilmesi, yayın hızlandırıcı, kimlik hata sınırlayıcı, AP penceresi, STA durum makinesi, aday kimlik akışı, tarama kapısı; **hedef zaman saklanmaz**, CONTRACTS §3c ZAMAN KURALI) | `test/fw_net_time.test.js` (firmware `test/test_net_time` Unity testinin portu, 27 test; sarma tabanları dahil) |
| `sim/fw/ap_access.js` | `src/ApAccess.h` (Wi-Fi servis akışı **AP kaynaklı yetki kararı** + `POST /api/wifi/connect` hız sınırlayıcısı) | `test/fw_ap_access.test.js` (firmware `test/test_ap_access` Unity testlerinin portu) |
| `sim/fw/automation.js` | `src/SmartAutomation.cpp/.h` + `SmartAutomation_Rs485.cpp` + `WS_TCA9554PWR.cpp` (komut kuyruğu, yürütücü, çıkış katmanı + `TCA_Verify`, DI, darbe, ek modül yazma/yoklama/geri okuma, ham RS485 komut/gönderim/tarama, konum kalıcılığı, planlı yeniden başlatma, bağımsız emniyet görevi) | `test/sim_automation.test.js` (rastgele fırtına testleri dahil) + bağımsız fiziksel gözlemci (`sim/fw/observer.js`) |
| `sim/fw/modbus.js` | `src/ModbusRtu.h` (CRC16, çerçeve kur/doğrula) + **QA ek modül donanım modeli** (Waveshare tipi Modbus RTU röle modülü: 0x01/0x02/0x03/0x04/0x05, baud + slave adresi uyumu) | `test/fw_modbus.test.js` (firmware'in 17 Unity testinin tüm doğrulamaları 13 blokta + modül modeli için 5 test) |
| `sim/fw/config_manager.js` | `src/ConfigManager.cpp` (NVS imajı: yapılandırma, kimlik, çocuk kilidi, konumlar; fabrika sıfırlama kuralları) | `test/sim_automation.test.js`, `test/sim_device.test.js` |
| `sim/fw/wifi_manager.js` | `src/WiFiManager.cpp` (STA, aday kimlik, kurtarma/kurulum AP penceresi, SNTP, **`isRecoveryApSecured()`**: AP şu an FİİLEN WPA2 mi) — **radyo sanal** | `test/sim_wifi.test.js`, `test/sim_http.test.js`, `test/sim_mqtt.test.js` |
| `sim/fw/mqtt_manager.js` + `sim/command_schema.js` | `src/MqttManager.cpp` (bağlanma, LWT, abonelik, 1500 ms yok sayma, id tekilleştirme, `state` v2, `sys`) | `test/sim_mqtt.test.js`, `test/command_schema.test.js` |
| `sim/local_api.js` | `src/WebPortal.cpp` (yerel HTTP API: kimlik/kilit, Host/Origin, hata kodları, durum/yapılandırma doğrulaması; yol tablosu **26 rota, 3'ü `AP_OR_KEYED`**: `authorizeApOrKeyed`) | `test/sim_http.test.js` |

Saat dışarıdan verilir (`loop(now)`); gerçek zamanlayıcı yalnızca kabukta (`device_sim.js`: 10 ms ana döngü, 100 ms Wi-Fi, 50 ms MQTT) vardır.
Bu yüzden çekirdek, sanal saatle (taşma dahil) hızlı ve deterministik sınanır.

### 5.2 Davranış özeti (firmware ile aynı)

- **Komut hattı:** MQTT/HTTP/DI tek `postDeviceCommand` kapısı; kuyruk 24, **FIFO** (DURDURMA öne geçmez: aynı turdaki "YUKARI, sonra DURDUR" DURDURMA ile biter).
  Kuyruk DOLUYKEN gelen DURDURMA kaybolmaz: acil bayrak kurulur, o tur hemen durdurur, kuyruk boşalınca bir kez daha durdurur (tur başına en çok 12 komut).
  Açılıştan sonraki **500 ms** komut/DI işlenmez. Başarısız komut `last_id`'yi yankılamaz.
- **Panjur:** ölü zaman ≥ 500 ms (röle KAPALI teyidinden sayılır), konum tamsayı, tam hareket = yol + 2 sn oturma payı, kesintisiz çalışma sınırı (yeniden hedefleme süreyi uzatmaz);
  yetim panjur rölesi panjur sayılmaz (komut reddedilir, röle hep kapalı). Röle tipleri: lamba / panjur↑ / panjur↓ / darbe.
  Bağımsız emniyet görevi (firmware: Core 0) enerjilenme anından "tam yol + oturma payı + 1,5 sn"yi aşan panjuru ana döngü kilitlense bile keser.
- **Yerel röle sürücüsü (TCA9554):** her yazım InterlockGuard'dan geçer (iki yön / doğrudan yön değişimi / < 500 ms ölü zaman reddedilir). `TCA_Verify` 2 sn'de bir çıkış/yön yazmacını okur:
  beklenmeyen AÇIK röle kapatılır; çip sıfırlanması / düşen röle → yerel panjurlar DURDURULUR ve gölge donanıma çekilir (QA: `/__sim/tca`).
- **Durum yayını:** QoS 0 + retained; değişimde ~250 ms birleştirme, değişim gözcüsü (100 ms), **hareket sürerken ~1 sn'de bir**, en az 30 sn'de bir; bağlanınca önce `online`, sonra ilk tam durum.
  `last_id` boşsa alan hiç yoktur; `shutters[]` yalnızca yapılandırılmış çiftleri içerir; `relays[].type` metindir.
- **MQTT:** `cmd`/`sys` aboneliği QoS 1; **abonelik çağrısından itibaren 1500 ms** gelen `cmd` VE `sys` yok sayılır (SUBACK beklenmez, firmware gibi **SUBACK reddine bakılmaz** → ACL hatası "sessiz arıza"dır);
  son 8 `id` tekilleştirilir (bağlantıda temizlenir); yük 1..512 bayt; `sys` `local_key` veya `key` alanıyla `set_local_key`.
- **Yerel HTTP:** `X-Device-Key`; **5. hatalı anahtar hâlâ 401, sonrakiler 423 + `Retry-After`** (kilit doğru anahtarı da engeller; anahtarsız istek sayılmaz); tüm kaynaklardan 60 sn'de 20 hata → genel kilit;
  Host (IPv4 sabiti/`localhost`/`*.local`) ve Origin denetimi (`400 bad_host`, `403 bad_origin`); CORS başlığı yok; bilinmeyen yol **ve yöntem** `404` (405 yok);
  rölelere komut `{"status":"queued"}`; `state` yalnızca `"0"`/`"1"`; çocuk kilidi POST'u yalnızca TEK `enabled` boolean'ı; yapılandırma doğrulama kodları (`invalid_shutter_pair`, `invalid_ext_channels`, `409 busy` ...) firmware kaynağıyla aynıdır.
- **Wi-Fi servis akışı (CONTRACTS §3d; firmware `ApAccess.h` + `WebPortal.cpp` ile aynı kural):** yalnız `GET /api/wifi/scan`, `POST /api/wifi/connect` ve `GET /api/wifi/status` **AP kaynaklı anahtarsız** erişime de açıktır;
  koşul: istemci SoftAP alt ağında + AP şu an **WPA2** + `ap_pass` ≥ 8 karakter + cihaz **provizyonlu**. Diğer 20 uç yalnız anahtarla çalışır (AP istemcisi `401`). Provizyonsuz cihaz (açık kurulum AP'si dahil) → `403 unprovisioned`;
  `factory/init` sonrası ~1,5 sn AP hâlâ açıkken yol kapalıdır (`401`), WPA2'ye dönünce açılır. AP yolunda yanlış anahtar hata sayacına işlenmez ve `423` yoklanmaz. Anahtarsız AP kaynaklı `connect` için GLOBAL kayan pencere:
  herhangi bir 60 sn'de en çok **6** istek (geçersiz gövdeliler dahil) → `429 {"error":"rate_limited","retry_after":N}` + `Retry-After` (geçerli anahtarlı istek sınıra girmez). STA alt ağı da `192.168.4.0/24` ile kesişirse AP yolu KAPANIR.
  `GET /api/wifi/status` → `{wifi_connect_state, wifi_connect_reason, wifi_connected, wifi_sta_ssid, wifi_sta_ip, wifi_rssi, ap_active}`; başarı YALNIZ `success`. Simülatör localhost'ta çalıştığından istemcinin ağ konumu (SoftAP/LAN)
  gerçek soketten çıkarılamaz: `/__sim/client-net` ile modellenir (§5.4); karar yine gerçek `clientOnSoftAp` fonksiyonundan geçer.
- **Kalıcılık ("NVS"):** `.runtime/sim/<UID>.json`: yapılandırma + kimlik (`local_key`, `ap_pass`, MQTT) + çocuk kilidi + konumlar. Konum **hareket bittikten ~8 sn sonra** yazılır
  (ani güç kesintisinde son konum kaybolur; planlı yeniden başlatmada zorla yazılır). `POST /api/system/reset` Wi-Fi + uygulama ayarını siler, **yerel anahtar/AP parolası/MQTT kimliğini korur**.
- **Wi-Fi:** gerçek radyo yok; "dünya" (`WifiWorld`) ev ağı + birkaç sahte ağ bilir (geçersiz UTF-8'li SSID, 32 bayt SSID, açık ağ). Bağlanma ~1,5 sn; doğrulanınca NVS'e yazılır, başarısızsa eski kimliğe dönülür
  (neden 201 ağ yok / 202 yanlış parola). STA tanımsız/3 dk kopuk iken kurulum/kurtarma AP penceresi (`wifi_ap_active`) firmware kuralıyla açılır.
- **Ek modül (16 röle, RS485/Modbus RTU):** elektrik yok ama **çerçeveler gerçek** — firmware portu CRC'li 0x01/0x02/0x05 isteği kurar, modül modeli (`sim/fw/modbus.js`) CRC/adres/baud'u denetleyip yanıtlar,
  firmware yankıyı/uzunluğu doğrular. Yapılandırmada açık ama bağlı olmayan (ya da baud'u uyuşmayan) modülde ek röleler "doğrulanamadı" sayılır (**state'te AÇIK görünür** — güvenli taraf varsayımı) ve panjur başlamaz.
  Ek panjur AÇILMADAN önce modülün **gerçek coil durumu okunur** (eş başka bir master tarafından açılmışsa hareket iptal, eş kapatılır). `POST /api/rs485/relay` (ham komut; panjur kanalı/toplu AÇMA yasak),
  `/api/rs485/send` (yalnız okuma + panjur dışı tek coil 0x05; doğrulamayı geçen çerçeve modül susarsa da 200), `/api/rs485/scan` (**bloklamayan**: baud 9600/38400/115200/19200/4800 × slave 1..8 ≈ 9,3 sn modül yokken;
  tarama sürerken hat tutulur: ek röle yazımı/yoklaması durur, ek panjur komutları reddedilir, ek panjur hareket ederken tarama 503 `busy`), `/api/rs485/logs` (`[SA:DD:SN]` önekli 25 satır).
  Modül ayarları QA ucundan değiştirilir (`/__sim/ext`: var/yok, Modbus adresi, baud, kanal sayısı) → "baud uyuşmazlığı → yanıt vermiyor → tarama düzeltir" akışı sınanır.

### 5.3 Simülatör seçenekleri (`node sim/device_sim.js --help`)

`--uid` (zorunlu; `AHBU-S3-<6 hex>` firmware biçimi — başka biçim "QA sapması"dır), `--relays 8|16`, `--http-port`, `--mqtt-host/--mqtt-port/--mqtt-user/--mqtt-pass`, `--local-key` (yoksa **provizyonsuz**),
`--time-scale N` (**yalnız** panjur yol/oturma payı N kat hızlı; ölü zaman 500 ms sabit), `--firmware-timing` (MQTT yeniden bağlanma 5 sn..5 dk ±%20; varsayılan **hızlı** 2..10 sn),
`--millis-offset N` (49,7 gün taşma testi), `--boot-hold-ms`, `--boot-ms`, `--state-file`, `--reset-state`, `--strict`.
Komut satırı değerleri yalnızca **ilk açılışta** (boş NVS) fabrika provizyonu gibi işlenir.

### 5.4 QA kontrol ucu (yalnızca `127.0.0.1`'den; firmware'de YOKTUR)

| Uç | İşlev |
|---|---|
| `GET /__sim/state` | iç durum (röleler, panjur FSM, DI, MQTT/Wi-Fi/HTTP kilit, **`violations`**, sayaçlar; **anahtar değerleri YOK**) |
| `GET /__sim/log?since=N` | olay günlüğü |
| `POST /__sim/di/{n}/press` (`{hold_ms}`) · `/down` · `/up` | duvar butonu (60 ms süzgeç firmware döngüsünde uygulanır; **kısa dokunuş `state.dis`'te görünmeyebilir**: yayın ~250 ms birleştirir) |
| `POST /__sim/offline` / `/online` | soketi ani yok eder (LWT `offline`) / geri bağlanır |
| `POST /__sim/crash` | temiz DISCONNECT, **LWT yok, `offline` yayınlanmaz** → retained `online` bayat kalır |
| `POST /__sim/power-cycle` | güç kesintisi + yeniden açılış (LWT; yazılmamış konum kaybolur) |
| `POST /__sim/slow` `{delay_ms, drop}` · `DELETE` | komut gecikmesi / düşürme |
| `POST /__sim/wifi` `{up:false}` | ev ağı arızası (STA kopar → MQTT LWT) |
| `POST /__sim/hw-fail` `{i2c, ext_module}` | röle sürücüsü (I2C) yazma arızası / ek modül tümüyle susar |
| `POST /__sim/ext` `{present, address, baud, channels}` | ek modül donanımı: var/yok, Modbus adresi (1..247), baud (4800..115200), kanal sayısı (state: `ext.*`, `ext.coils`, `ext.uart_baud`, `ext.scan`) |
| `POST /__sim/tca` `{action: chip_reset\|stuck_on\|drop, relay}` | yerel röle çipi arızası: brown-out sıfırlaması / röle kendiliğinden çeker / röle düşer (firmware yalnız `TCA_Verify` ile fark eder; state: `tca.latch/shadow`) |
| `POST /__sim/provision` · `/unprovision` · `/factory-reset` | yerel anahtar yaz/sil · tüm NVS'i sil |
| `POST /__sim/ap` `{open, window_ms?}` | servis AP penceresini aç/kapat (seri CLI `AP ON/OFF`; varsayılan 10 dk, 1 sn..60 dk). Provizyonluysa yalnız geçerli `ap_pass` varsa açılır (firmware kuralı) |
| `GET/POST /__sim/client-net` `{mode: ap\|lan, remote_ip?, ap_clients?}` | HTTP istemcisinin **ağ konumu modeli** (AP kaynaklı yetki için): `ap` → cihazın SoftAP'sinde (uzak IP 192.168.4.2), `lan` → ev ağında; `remote_ip` açık IP (örn. alt ağ çakışması), `ap_clients` SoftAP istasyon sayısı (0..3). CLI: `--client-net`, `--sta-ip` (192.168.4.x = "modem de 192.168.4.0/24" çakışması). `state`: `client_net`, `wifi.ap_secured` |

**Bağımsız fiziksel gözlemci:** her tikte fiziksel röle maskesi (yerel TCA gölgesi + ek modül coil'leri) sistemin kendi `InterlockGuard`'ından bağımsız denetlenir; geçerli panjur çiftinde
*iki yön aynı anda*, *doğrudan yön değişimi* veya *< 500 ms ölü zaman* ihlali `violations`'a yazılır (smoke/test bunun 0 olmasını bekler).

### 5.5 Firmware sürüklenmesi

Firmware paralel geliştirildiği için simülatör, belirli kaynakların **o anki** sürümünden portlandı. `node run.js fwcheck` bu kaynakların SHA-256'sını `sim/fw/SOURCES.json` ile karşılaştırır ve değişenleri
"hangi modülü etkiler" ile listeler; değişirse ilgili modülü + `test/fw_*.test.js` portunu yeniden eşitleyin, sonra `fwcheck --update`.

## 6. Sunucuyu kendi başınıza çalıştırmak

`up --stage2` sunucuyu **asgari ortamla** (CONTRACTS §6) kendisi çalıştırır: `DATABASE_URL`, rastgele `JWT_SECRET`/`PIN_PEPPER`/`LOCAL_KEY_SECRET`/`ADMIN_API_KEY` (`PIN_PEPPER` ve `LOCAL_KEY_SECRET` veriye bağlıdır, `pgdata` ile kalır; diğerleri her `up`'ta yenilenir, §1), `MQTT_*` (backend_service),
`MQTT_PUBLIC_HOST/PORT`, `EMQX_API_*` (kick → QA brokeri), `ALLOW_DEBUG_OTP=true`, `CORS_ORIGINS`, `SMTP_*` (çukur; `NODE_EXTRA_CA_CERTS` ile yalnız bu süreç kendinden imzalı sertifikaya güvenir —
sunucunun mailer'ı `requireTLS` ve doğrulama ile çalışır, doğrulama KAPATILMAZ). Değerler diske/loga yazılmaz. Alt sürecin yerel çökmeleri `.runtime/api_reports/` altına Node tanılama raporu olarak düşer.
Migration: `server/scripts/migrate.js` (`MIGRATE_CONFIRM=ev_qa`); dosya yoksa yedek çalıştırıcı sıralı uygular (010 < 010b < 011) ve başarısızı kaydedip devam eder.
`dev_seeds` ve sabit parolalı demo tohumları **uygulanmaz**.

## 7. Gerçek PostgreSQL üzerinde sunucu denetimi

Mock'lu testlerin yakalayamadığı sınıf: gerçek şemada eksik sütun, `ON CONFLICT` belirtimi, belirsiz parametre tipi (`42P08`), `FOR UPDATE` + dış birleştirme, geçersiz uuid metni, NUL baytı, tam sayı taşması ...

- **`sqlcheck`**: `acorn` ile `.query(...)` SQL'lerini çıkarır, her biri için gerçek PG'de `PREPARE` (çalıştırmadan ayrıştırma + analiz). Statik çözülemeyen (`${...}` ile kurulan) sorgular "dinamik" listelenir (denetlenmez).
- **`sweep`**: 78 spec × (alan/yol/sorgu/gövde-şekli düşman değerleri) + 14 akış (kimlik yaşam döngüsü, admin, envanter, claim + OTP + PIN kilidi, acil sıfırlama, pano değişimi, daire devri, servis PIN, zamanlı kurallar, IDOR, etiket yeniden üretimi, davet önizleme, hesap silme, servis paneli/Home Admin atama).
  Tüm değiştirici işlemler **süpürmeye özgü geçici kullanıcı/ev/cihazlarla** yapılır; hız sınırlayıcılar kullanıcı/ev anahtarlı olduğundan "dönen aktör" (her ~35 istekte yeni kullanıcı+ev) kullanılır.
  **Yan etkileri:** süpürme oluşturduklarını SİLMEZ. Her koşu (`--only` dahil; temel bağlam her seferinde yeniden kurulur) en az 7 kullanıcıyı `POST /auth/register` ile kaydeder ve giriş yaptırır (IP başına saatte 10 kayıt sınırı; temiz `up --stage2` tohumu bunun 5'ini kullanır), 1 geçici süper yönetici açar, 3 panoyu envantere kaydeder (2'si `Sweep` dairelerinde, 1'i stokta) ve 4 tohum hesabıyla giriş yapar (15 dk'da 30). Sonuç: ikinci koşu kayıt 429'uyla çökebilir, sonraki bir saatte "Kayıt Olun" akışları reddedilebilir, "Stokta Hazır" listesinde fazladan pano görünür (sayaçlar sunucu belleğindedir: `down` + `up --stage2 --keep-secrets --no-seed`). Kontrol listesiyle tur yapıyorsanız sweep'i turun sonuna bırakın.
  Her 5xx yanıtı `X-Error-Ref` (veya B paketinin `[WP-B] error` satırı) ile `api.log` yığınına, her `[DB-QUERY-ERROR]` `.runtime/sweep_report.json`'a bağlanır (dosya:satır).

## 8. Testler

`npm test` (`node --test`): broker/ACL/credstore/PG/SMTP + simülatör (firmware uyumluluk portları, entegrasyon, HTTP, MQTT, kabuk) + tohumlama — sayılar `docs/QA_STACK.md` değil, çalıştırma çıktısındadır.

**Tohumlama testleri:** `seed_helpers.test.js` (adım durumu/özet metni, zamanlı kural planı = ev + kural adı, servis PIN geçerliliği; saf, hızlı), `mails.test.js` (`mails [N]` anlamı + gerçek CLI çıkış kodu),
`secrets.test.js` (`up` dönen sırları yeniler, `--keep-secrets` korur) ve **`seed_idempotency.test.js`** — GERÇEK yığın: gömülü PostgreSQL 18 + broker + simülatör + gerçek `server/` + gerçek REST tohumlaması, `node run.js` alt süreç olarak;
yalıtılmış geçici `QA_RUNTIME_DIR` + rastgele portlarla çalışır (kendi `.runtime`'ınıza/portlarınıza dokunmaz; ~80 sn; `server/` kaynağı ya da `node_modules` yoksa ATLANIR). Kanıtladıkları: ikinci/üçüncü `seed` ve yeniden başlatma
DB kayıtlarını/kimliklerini/`accounts.json`'u değiştirmez ("0 yapildi"); servis personeli zorunlu parola istemez; bozulmuş durum (yinelenen kural, değişen parola, silinen üye, süresi dolan misafir/PIN, kopan cihaz kimliği) onarılır;
`--keep-secrets` eski access token'ı korur, sırsız `up` eskisini geçersiz kılar (refresh token çalışır); `smoke` 23/23.
Firmware Unity testlerinin portları: ShutterFsm 37, RelayRules 14, DiGate 23, SystemConfig 19, ModbusRtu 17 Unity testi (C++ testleriyle birebir; PC'de `pio test -e native` gerektirmez).

**Flutter ↔ simülatör çapraz testi:** `test/services/wifi_service_flow_simulator_test.dart` (Flutter paketinde; `flutter test`), gerçek `AutomationApiService`'i bu simülatörün AP kaynaklı yetki kuralına (CONTRACTS §3d) karşı gerçek HTTP ile sınar
(alt süreç olarak `node sim/device_sim.js`, rastgele portlar, rastgele gizli değerler; `node` veya `tools/qa_stack/node_modules` yoksa testler ATLANIR). İstemci testleri (`FakeDevice`/`MockApi`) ile simülatör testleri kuralın iki yanını ayrı doğrular; bu test ikisinin SAPMASINI yakalar.

`sim_automation` testleri iki **rastgele fırtına** içerir (yerel: komut/DI/yapılandırma; ek modül: ham RS485 komut/gönderim, tarama, modül susması, baud uyuşmazlığı, başka master, TCA lamba arızası): bağımsız fiziksel gözlemci
ihlali **0** ve fırtına sonunda firmware inancı = donanım (yerel latch + modül coil'leri) beklenir.

## 9. Ne kanıtlanır, ne kanıtlanmaz (sınırlar)

**Kanıtlanır:** REST ↔ MQTT ↔ cihaz **sözleşmesinin** uçtan uca davranışı (hata kodları, yetki matrisi, ACL/LWT/retained/1500 ms penceresi/id tekilleştirme, komut yaşam döngüsü, kick, süresi dolan misafir),
sunucunun **gerçek PG'de** çalışması (şema + sorgular + düşman girdi), firmware'in saf mantığının (panjur FSM, DI kapısı, interlock, yapılandırma doğrulaması) kendi testleriyle uyumu.

**Kanıtlanmaz (gerçek donanım/EMQX gerekir):**

- ESP32 zamanlaması (döngü hızı, Core 0/1 yarışları, WDT, yığın/bellek, NVS aşınması), I2C/TCA9554 ve RS485/Modbus **elektriği/zamanlaması** (çerçeveler gerçek ama hat gecikmesi, yankı, gürültü, mutex/yarış yok;
  tarama süresi firmware zaman aşımlarından hesaplanır), gerçek röle/panjur motoru.
- **TLS**: yığın düz TCP kullanır; sertifika zinciri/ana makine adı doğrulaması, SNTP bağımlılığı, `MQTT sunucusu DNS adı olmalı` kuralı sınanmaz.
- **LWT gecikmesi:** gerçekte keepalive ×1,5 (≈45 sn); burada soket yok edilince anında.
- **EMQX'e özgü:** HOCON yapılandırması, tek PG authenticator varsayımı, ACL önbelleği, kick REST ayrıntıları (burada aedes + taklit REST). Broker kimlik/ACL'i yalnızca `username` ile eşler (EMQX gibi; `clientid` zorlanmaz).
- Wi-Fi/AP radyosu (burada sanal), gerçek ağ kopmaları, mDNS, Bluetooth/CAN/SD, OTA. **AP kaynaklı yetkinin girdileri** (`remoteIP()`, `softAPSubnetMask()`, STA+AP birlikteyken yönlendirme) gerçek SoftAP istemcisinde
  DOĞRULANMADI: simülatör bunları `/__sim/client-net` modeliyle besler; telefonun "internetsiz Wi-Fi"yi bırakıp mobil veriye geçmesi, SoftAP kanal değişiminde telefonun düşmesi ve tarayıcı `BarcodeDetector` desteği yalnız sahada sınanır (canlı test listesi Aşama 16.8 ve 16.10).
- Simülatör Node olay döngüsünde çalışır: zamanlama ±10 ms oynar; çok hızlı peş peşe komut dizileri gerçek cihazdan farklı sıralanabilir.
- Android cleartext/ağ güvenlik yapılandırması, FCM/APNs, biyometrik, kamera/QR tarama emülatörde sınanmaz.

## 10. Gizli bilgi politikası

Rastgele sırlar yalnızca `.runtime/secrets.json` ve `accounts.json`'dadır (gitignore: `tools/qa_stack/.gitignore` → `node_modules/`, `.runtime/`). Loglar/raporlar parola, anahtar, token, OTP, PIN değerlerini içermez
(günlükleyici bu anahtarları maskeler). Repoya sır **yazılmaz**; `up` her çağrıda **dönen** sırları (JWT, yönetici API anahtarı, MQTT arka uç, EMQX, SMTP) yeniler, veriye bağlı sırlar (`db_password`, `pin_pepper`, `local_key_secret`)
`pgdata` ile birlikte kalır; `--keep-secrets` hiçbirini yenilemez (§1).

## 11. Sorun giderme

| Belirti | Çözüm |
|---|---|
| `Port çakışması` | `node run.js status`; başka bir PG/broker varsa `QA_*_PORT` ile port değiştirin. Başka bir ajanın PG'sine dokunmayın |
| `up` PG'de takılır | `node run.js logs pg`; yetim `postgres.exe` için `node run.js down` (PID dosyası + `pg_ctl` + taskkill yedeği) |
| Sunucu açılmıyor | `node run.js logs api -n 80`; `.runtime/api_reports/` (yerel çökme raporu) |
| Cihaz bulutta "çevrimdışı" | `GET /__sim/state` → `mqtt` alanı (`connected`, `cmd_subscribed`, `last_error`); **ACL reddi iki ayrı günlükte iki ayrı adla görünür**: broker günlüğünde (`node run.js logs broker`) `sub_denied` / `pub_denied` / `connect_denied` satırları (broker olayı); simülatör günlüğünde (`node run.js logs sim`) `sim_mqtt_subscribe_denied` satırı — olay adı `mqtt_subscribe_denied` (`GET /__sim/log` olay dizisinde de bu adla). `mqtt_subscribe_denied` BROKER olayı değildir: firmware gibi SUBACK reddini yalnızca günlüğe yazar, bağlantı "çevrimiçi" görünmeye devam eder (sessiz arıza) |
| Komut cihaza ulaşıyor ama uygulanmıyor | cihaz yeniden bağlandıktan sonraki **ilk 1500 ms** `cmd` yok sayılır (REST `delivered:true` döner) — uygulamanın 2,5 sn geri alma zamanlayıcısı bunu yakalamalıdır |
| `status` çıkışında "Assertion failed ... UV_HANDLE_CLOSING" ya da çıkış kodu `3221226505` (0xC0000409) | Windows/libuv: açık tutamaç varken `process.exit()` bazen böyle çöker (çıktı doğru olsa da kod bozulur). Komutlar artık `process.exit()` yerine **doğal çıkış** yapar (5 sn'de zorla); yine görürseniz komutu yineleyin |
| `up`: "Daemon ani olarak coktu ..." ya da `migrate.log`'da "yerel olarak coktu" | Aynı Windows/libuv aralıklı yerel çökmesi (süreç kodu `3221226505`) bir QA alt sürecini ya da daemon'u vurmuş. `up` daemon çökmesinde kalıntıları temizleyip **bir kez** yeniden dener; `migrate.js` çökerse (migration'lar idempotent, dosya başına işlemde) **2 kez** yeniden çalıştırılır. Yine de başarısızsa `node run.js logs daemon -n 80` / `logs migrate` |
| `seed`/`smoke` "HTTP 429 RATE_LIMITED" | sunucu girişi IP başına 15 dk'da 30 istekle sınırlıdır (§4 "Hız sınırı"): bildirilen süre kadar bekleyin ya da `up` ile sunucuyu yeniden başlatın |
| `smoke`: "zamanli kurallar ... kural sayisi 8" | eski sürümün yinelenen kuralları: `node run.js seed` (ya da `up --stage2`) fazlalıkları siler (§4 "Onarım") |
| `smoke`: "giris: staff" HTTP 401 | `qa.servis` parolası uygulamada değiştirilmiş (`accounts.json` eskisinde): `node run.js seed` parolayı `accounts.json` değerine geri alır |

## 12. Bilinen bulgular ve diğer bileşenlerden beklentiler

Bu bölüm **2026-10-01** itibarıyla durumu özetler; güncel durum için `node run.js sweep` / `sqlcheck` / `npm test` çalıştırın.

**Sunucu (gerçek PostgreSQL 18 üzerinde, `sweep` ile yeniden üretilir):**

- **NUL baytı (`\u0000`) içeren metin → `500 INTERNAL` (PG `22021`)**, 400 `VALIDATION` olmalı: `GET /admin/inventory?search|batch_no` (`inventory_service.js:188`),
  `GET /admin/users?search` + `/admin/staff` (`admin_user_service.js:158`), `POST /admin/users` / `PATCH /admin/users/:id` `admin_notes` (`:268` / `:389`),
  `POST /homes/:homeId/commissioning` `notes` (`device_service.js:2179`), `GET /service/subscribers?q` (`service_panel_service.js:234`). Tek noktadan çözüm: JSON/sorgu dizgilerinde `\u0000` reddeden genel bir ara katman.
- **Çok büyük sayısal `offset` (40 hane) → `500`** (`parseInt` → `1e+39` → PG `bigint` hatası): `GET /admin/inventory` (`inventory_service.js:191`), `GET /admin/users` (`admin_user_service.js:161`).
  `service_panel_service.js`'in `toBoundedInt` yardımcısı doğru örnektir.
- Ortam: ağır makine yükünde (CPU %85, boş bellek <1 GB) birkaç sn'lik DB/olay-döngüsü duraksamaları `Connection terminated due to connection timeout` (pool `connectionTimeoutMillis: 5000`, `db.js:16`) → `500` üretir;
  yük düşünce toparlanır. Sunucu hatası değil, ortam gürültüsüdür; `sweep` bu yüzden iki kez çalıştırılıp karşılaştırılmalıdır.

**Firmware (simülatör karakterizasyon testleriyle belgeli; FW-core'a bilgi):**

- `SmartAutomation_Rs485.cpp` `rs485ControlExtRelay` — TOGGLE (action 2, servis sayfasındaki "Modül Röle 1 Toggle" düğmesi ve `/api/rs485/relay` varsayılanı) panjur olmayan bir ek röleyi AÇAR ama
  rölenin durumu "bilinmiyor" (`_hwKnown=false`, `_want=false`) bırakıldığı için `stepExtOutputs` 1. geçişi (KAPATMALAR) aynı/sonraki turda geri KAPATIR: röle ~10-20 ms çekip bırakır (test: `ham TOGGLE ...`).
  Öneri: 1. geçişte `_adoptNextPoll[i]` bayraklı röleleri atlamak (benimseme yoklaması durumu belirlesin).
- `WS_TCA9554PWR.cpp` `TCA_WriteOutputsEx` — çip sıfırlanması / röle düşmesi ile `TCA_Verify` (2 sn) arasındaki herhangi bir yazım, firmware'in "açık" sandığı bitleri (dahil panjur rölesi) tüm 8 bitlik yazımla yeniden çeker;
  fiziksel kapanma anı bilinmediği için ölü zaman uygulanmaz (test: `[FW-core bulgusu, karakterizasyon] TCA cip sifirlanmasi ...`). Öneri: panjur rölesi enerjilenecek yazımda önce çıkış yazmacını okumak (ek modüldeki `extReadbackBeforeEnergize` gibi).
- Ham `POST /api/rs485/send` ile panjur dışı kanala 0x05 AÇ, firmware'in `want` durumunu değiştirmediğinden sonraki coil yoklamasında (≤ ~1,5 sn) geri kapatılır (tasarım gereği olabilir; kalıcı AÇMA için `/api/rs485/relay`).

**Diğer bileşenlerden beklentiler:** `android/` açık metin HTTP izni (§3), Flutter istemcisinde cihaz yerel API'si için `X-Device-Key` + `Host` kuralları (§5.2), kuyruk dolu `503 queue_full` ve `409 busy` yanıtlarının kullanıcıya gösterimi.
