# Dağıtım Rehberi (Runbook)

> **Durum:** Bu rehber **uygulanmadı**. Sunucuya SSH erişimi (parola reddedildi) olmadığı için yalnızca hazırlandı.
> Geçerli kimlik bilgisiyle, aşağıdaki sırayla ve **her adımda doğrulayarak** uygulanır. Hiçbir adımı atlamayın.

## 0. Değişmez kurallar

1. **Üretimdeki site kapı sistemine dokunulmaz.** Aynı sunucuda çalışan Mosquitto (1883/8883) ve kapı API'si bu dağıtımın parçası değildir:
   ortak servisler (`systemctl restart mosquitto`, `iptables` sıfırlama, global nginx `reload` dışı işlemler) **yapılmaz**. Ev otomasyonu yığını
   yalnızca kendi kapsayıcıları/portlarıyla çalışır (EMQX **8884**, Postgres `127.0.0.1:5434`, API `127.0.0.1:5000`, düz MQTT köprüsü `127.0.0.1:1884`, panel `127.0.0.1:18084`).
2. Önce **salt-okunur keşif**, sonra **yedek**, sonra **hazırlık (staging) doğrulaması**, en son canlıya uygulama.
3. Uygulanmış hiçbir migration dosyası yerinde değiştirilmez.
4. Sır değerleri komut satırı geçmişine/loga/sohbet'e yazılmaz; `.env` dosyası `chmod 600`, git'te yok.

## 1. Salt-okunur keşif (hiçbir şeyi değiştirmez)

```bash
uname -a; uptime; df -h /; free -m
docker ps --format '{{.Names}}\t{{.Image}}\t{{.Ports}}\t{{.Status}}'      # hangi kapsayıcılar çalışıyor
ss -ltnp | head -40                                                        # dinleyen portlar (1883/8883/443/80/5000/5434/8884…)
pm2 list 2>/dev/null; systemctl list-units --type=service --state=running | head -40
ls -la ~/ ; ls -la /etc/nginx/sites-enabled/ 2>/dev/null
# Ev otomasyonu yığını zaten var mı? (varsa mevcut sürümü/şemayı not et)
docker ps -a --filter 'name=ev_otomasyon'
```

Çıktıyı kaydedin; ev otomasyonu yığınının **mevcut** durumunu (hangi migration'a kadar uygulandığı, hangi `.env`) bilmeden ilerlemeyin.

## 2. Yedek (geri dönüş noktası)

```bash
# Postgres (ev otomasyonu veritabanı — kapı sisteminin DEĞİL)
docker exec ev_otomasyon_postgres pg_dump -U "$POSTGRES_USER" -Fc "$POSTGRES_DB" > ~/backup/ev_$(date +%F_%H%M).dump
cp -a /<ev_otomasyon_dizini>/server/.env ~/backup/env_$(date +%F_%H%M)    # chmod 600 ile saklayın
docker run --rm -v ev_otomasyon_emqx_data:/d -v ~/backup:/b alpine tar czf /b/emqx_data_$(date +%F).tgz -C /d .
cp -a /etc/nginx/sites-available ~/backup/nginx_sites_$(date +%F)
```
Yedeğin **geri yüklenebildiğini** bir test veritabanında doğrulayın (`pg_restore --list` en azından).

## 3. Sırların döndürülmesi

`docs/SECRET_ROTATION.md`'deki sırayla. **Sunucu SSH parolası** ve süper kullanıcı parolaları ilk adımdır (repoda ifşa oldu).

## 4. EMQX yapılandırmasını hazırlık ortamında doğrula (ZORUNLU — çalıştırılamadığı için kodda doğrulanmadı)

`server/emqx_config/emqx.conf` ve `acl.conf` bu geliştirme makinesinde **hiç çalıştırılmadı** (Docker/EMQX yok). Canlıya almadan önce **ayrı bir hazırlık kapsayıcısı**yla (farklı port, ör. 18884) doğrulayın:

1. `docker compose -p ev_staging up -d postgres emqx` (ayrı proje adı, ayrı hacimler, ayrı portlar).
2. EMQX günlüklerinde `authn`/`authz` kaynaklarının **hatasız yüklendiğini** doğrulayın (`${EV_AUTHDB_*}` ortam yerine koyma çalışmıyorsa yedek: `EMQX_AUTHENTICATION__1__PASSWORD`, `EMQX_AUTHORIZATION__SOURCES__1__PASSWORD` ortam değişkenleri).
3. Beş sınama (mosquitto_pub/sub veya `mqttx` ile, TLS ile):
   - backend superuser kimliği her konuya yayın/abone olabiliyor mu,
   - cihaz kimliği (`d_{t}`) yalnız `ev/{t}/state|status` yayınlıyor ve `ev/{t}/cmd|sys` abone olabiliyor mu,
   - uygulama kimliği (`a_{t}_…`) **yalnız** `state|status` abone olabiliyor; `cmd`'ye yayın **reddediliyor** mu,
   - süresi dolmuş uygulama kimliği bağlanamıyor mu,
   - başka evin konusuna (`ev/{başkası}/#`) hiçbir kimlik erişemiyor mu.
4. Sonuçlar tutmuyorsa canlıya geçmeyin; yapılandırmayı düzeltip yeniden deneyin.

## 5. Backend dağıtımı (hazırlık doğrulandıktan sonra)

> Süreç yöneticisi: sunucu SIGTERM'de sıralı kapanır (HTTP → zamanlayıcı/köprü → MQTT → havuz; toplam sınır 10 sn). PM2'de `kill_timeout` ≥ 12000 ms (varsayılan 1600 ms kapanışı yarıda keser), systemd'de `TimeoutStopSec=15`. Çökmede (`uncaughtException`) çıkış kodu 1: otomatik yeniden başlatma açık olmalı.

```bash
cd /<ev_otomasyon_dizini>/server
git pull            # veya yeni sürümü yerleştirin; .env zaten sunucuda (git'te YOK)
npm ci --omit=dev
# .env içinde zorunlu değişkenleri doğrulayın: docs/CONTRACTS.md §6 + server/.env.example
node scripts/check_syntax.js
```

**Veritabanı (mevcut canlı şema için):**
```bash
export DATABASE_URL=...   # ev otomasyonu DB'si; kapı sistemi DB'si DEĞİL
MIGRATE_CONFIRM=<db_adı> node scripts/migrate.js --status         # önce durumu gör
MIGRATE_CONFIRM=<db_adı> node scripts/migrate.js --baseline 17    # eski run_*.js ile kurulmuş şemayı 001–017 olarak işaretle (beklenen tablolar yoksa reddeder)
MIGRATE_CONFIRM=<db_adı> node scripts/migrate.js --dry-run        # uygulanacakları gör
MIGRATE_CONFIRM=<db_adı> node scripts/migrate.js                  # 018,019 (A) → 020,021 (B) → 022–026 (C) → 027–029 (B2) → 030 (H) → 031 (L: yerleşim eşitleme) → 032 (akış denetimi: yerel anahtar bekletme)
node scripts/check_schema_contract.js --live                       # (DATABASE_URL ile) "Şema sözleşmesi TEMİZ" olmalı
```
Boş bir veritabanında `--baseline` kullanılmaz; doğrudan `node scripts/migrate.js` 001→sonuncu uygular.

**032 (yerel anahtar bekletme, akış denetimi 2026-10-04):** `devices.local_key_pending_enc` (TEXT) + `local_key_pending_at` (TIMESTAMPTZ), ikisi de NULL ve varsayılansız, COMMENT'li; `CREATE OR REPLACE FUNCTION` + `DROP/CREATE TRIGGER trg_devices_pending_key_superseded` (sahipsiz kayıtta bekleyene dokunmadan `local_key_enc` değişirse bekleyeni temizler: etiket yeniden üretimi). Tablo yeniden yazılmaz (kısa ACCESS EXCLUSIVE kilidi), idempotenttir (iki kez yeniden uygulandı, hata yok), içinde BEGIN/COMMIT yoktur (çalıştırıcı tek transaction açar).

- **Sıra:** ÖNCE migration, SONRA kod + yeniden başlatma. Yeni kod 032'siz veritabanında acil sıfırlamada `42703` (kolon yok) verir, köprü uzlaştırıcısının yerel anahtar turu da her çevrimiçi dönemde hata loglar; eski kod yeni kolonları görmezden gelir.
- Ortam değişkeni değişikliği YOK. Firmware değişikliği gerekmez (mevcut `sys set_local_key` ve `state.last_id` yankısı kullanılır).
- Geri alma: kod geri alınırsa 032 kolonları ve tetikleyici zararsız kalır (tetikleyici yalnız sahipsiz kayıtta, bekleyen doluyken çalışır); kalan bekleyen anahtarlar yeni kod yeniden açılınca uzlaştırılır.
- QA yığını (`tools/qa_stack`) kendi veritabanına `migrate.js` ile 032'yi de uygular; simülatör `sys set_local_key` ve `last_id` yankısını zaten taklit eder.

**Roller ve kimlikler:**
```bash
docker exec -i -e EMQX_AUTHDB_PASSWORD ev_otomasyon_postgres sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1' < scripts/create_db_roles.sql
MQTT_BACKEND_USER=backend_service MQTT_BACKEND_PASS='<≥24 karakter>' MIGRATE_CONFIRM=<db_adı> node scripts/create_backend_mqtt_user.js
SUPER_USER_EMAIL=... SUPER_USER_PASSWORD='<≥12 karakter>' node scripts/create_super_user.js     # ilk yönetici (eski seed hesapları KAPALI)
docker compose up -d emqx    # günlükte authn/authz yüklenmesini ve 8884 TLS'i doğrulayın
```

**API:** `BIND_HOST=127.0.0.1` ile başlatın (PM2/systemd; kapı sisteminin süreçlerinden ayrı). nginx: `nginx/evotomasyon.gudeteknoloji.com.tr.conf` yalnızca bu alan adı için eklenir; **`nginx -t` ile sınayın, sonra `nginx -s reload`** (global yeniden başlatma yok). Sertifika yenileme: certbot deploy-hook `scripts/emqx_cert_deploy_hook.sh`.

**Akış denetimi düzeltmeleri (2026-10-04) için sunucu ayarları** (ayrıntı: `docs/superpowers/specs/2026-10-04-akis-denetimi-duzeltmeleri.md`):

- Yeni ortam değişkeni YOK; yalnız 032 + kod + yeniden başlatma (bellek içi giriş kilidi sayaçları sıfırlanır).
- Oturumların toplu iptalinde (logout-all, parola değişimi/sıfırlama, dondurma) açık MQTT bağlantısının anında atılması için `.env`'de `EMQX_API_URL` / `EMQX_API_KEY` / `EMQX_API_SECRET` tanımlı olmalı; yoksa kimlikler yine silinir ama atma atlanır (`[MQTT-CRED] … atlandi` uyarısı).
- Giriş kilidinin (kimlik | IP) katmanı doğru istemci IP'sine dayanır: nginx arkasında `TRUST_PROXY` doğru olmalı (aksi halde herkes vekil IP'sini paylaşır, kilit "yalnız kimlik" davranışına döner).
- SMS sağlayıcı bağlı değil: `GET /api/v1/auth/capabilities` üretimde `sms_otp:false` döner, yeni istemci SMS ile giriş düğmesini gizler (nginx `/api` vekili altında; ek yapılandırma gerekmez).

## 6. Doğrulama (canlıda)

```bash
curl -fsS https://evotomasyon.gudeteknoloji.com.tr/health                     # healthy; hata metni sızmıyor
curl -sS -X POST .../api/v1/auth/login -d '{"email":"…","password":"yanlış"}' # 401 INVALID_CREDENTIALS (genel mesaj)
openssl s_client -connect evotomasyon.gudeteknoloji.com.tr:8884 -showcerts </dev/null | head -60
curl -fsS https://evotomasyon.gudeteknoloji.com.tr/api/v1/auth/capabilities  # kimliksiz 200; data.sms_otp=false (SMS sağlayıcı yokken), Cache-Control: no-store
```
- **TLS zinciri** `ISRG Root X1` (veya X2) ile bitmeli ve EMQX `fullchain.pem` ara sertifikayı göndermeli (cihazlar yalnız kök tutar). `CaCerts.h` parmak izlerini `https://letsencrypt.org/certificates/` ile karşılaştırın (`openssl x509 -in <pem> -noout -fingerprint -sha256 -dates`).
- Yetki matrisi duman testi: ev sahibi → komut 200; başka evin kullanıcısı → 403; süresi dolmuş misafir → `GUEST_EXPIRED`; uygulama kimliği ile `cmd` yayını → broker reddi.
- Kapı sistemi: `mosquitto` ve kapı API'si **etkilenmedi** (portlar/süreçler keşif çıktısıyla aynı).

## 7. Cihaz (firmware) yaygınlaştırma

1. **Tüm panolar yeniden flash'lanır** (eski firmware `setInsecure` + paylaşılan kimlik + sabit AP parolası kullanıyordu; yeni firmware yalnızca yeni kimlikle bağlanır).
2. Flash sonrası **hemen** provizyon (provizyonsuz cihaz 10 dk **açık** kurulum ağı yayınlar): fabrika aracı `factory/init` → servis sihirbazı `wifi/connect` → `mqtt/config` (`server` **DNS adı**, port 8884, `d_<t>` kimliği).
3. NTP (UDP 123) müşteri ağında açık olmalı (TLS saat ister); MQTT sunucusu **DNS adı** olmalı (IP olmaz).
4. Sahadaki eski firmware'li panolar için gerekiyorsa geçiş: `LEGACY_MQTT_USER/PASS node scripts/upgrade_legacy_mqtt_user.js`; tüm panolar geçince `acl.conf` legacy bloğu ve `mqtt_users` satırları **silinir**.
5. CA kökleri: ISRG Root X1 **2035-06-04**, X2 **2040-09-17**'de sona erer → o tarihlerden önce firmware güncellenmeli. Sunucu başka bir CA'ya geçerse `CaCerts.h`'ye yeni kök eklenip firmware yeniden yayımlanmalı.
6. **Güncel imaj v1.1.2 (akış denetimi, 2026-10-04): DONANIMDA DOĞRULANMADI.** `firmware_releases/v1.1.2/firmware_combined_0x0.bin` (`version_info.json` 1.1.2; fabrika aracının "Bizim Geliştirdiğimiz Yazılım" seçimi bu yolu getirir). v1.1.1'den farkı yalnız provizyon yolu: `factory/init` + `rekey` NVS hatasında `503 {"error":"storage"}`, atomik `provisionIfEmpty` (seri `FACTORYINIT` ile HTTP `factory/init` yarışamaz), yeni `RESETKEY` metni (`docs/CONTRACTS.md` §3/§3b/§3c). Sunucu ve uygulama için değişiklik gerekmez (istemci `storage`'ı `storage_error` ile aynı iletiye eşler).
   - Önce `sha256sum -c SHA256SUMS.txt` (birleşik imaj `9941046…a42`, yalnız uygulama `a37ea24…4cd`); bootloader + bölüm tablosu + boot_app0 (0x0000–0xFFFF) v1.1.1 ile bayt bayt aynı.
   - Toplu yüklemeden ÖNCE tek test kartında: `esptool --chip esp32s3 --port COMx --baud 460800 write_flash 0x0 firmware_combined_0x0.bin` (ya da araçta FLASH) → açılışta `fw`=1.1.2 → USB `FACTORYINIT` → `OK factory_init` → `RESETKEY` (yeni metin) + yeniden `FACTORYINIT` → provizyonlu kartta `factory/init` `403` → `rekey`. Sonra `SURUM_NOTLARI.md`'deki "DONANIMDA DOĞRULANMADI" bandını güncelleyin.
   - Provizyonlu v1.1.1 kartında anahtarları korumak için yalnız `app_0x10000_v1.1.2.bin` 0x10000'a yazılabilir (denenmedi). Birleşik imaj NVS alanını da kapsar: yazınca kart provizyonsuz kalır.
   - Paketlenmiş ikilileri kullanın: aynı kaynak başka dizinde derlenirse uygulama imajının 64 baytı (gömülü ELF özeti + sağlama/SHA eki) farklı çıkar. İkili dosyalar `git diff` ile taşınmaz (`git diff --binary`, `format-patch` ya da cherry-pick/merge).

## 8. Mobil uygulama sürümü

- Release derlemede `AppConfig` override'ları (`--dart-define`) **yok sayılır** (HTTPS + TLS açık + `192.168.4.1`).
- Android: ana manifest'te açık `INTERNET` izni, `FlutterFragmentActivity`, `allowBackup=false`; iOS: `NSFaceIDUsageDescription`, `NSLocalNetworkUsageDescription` (bkz. E paketi).
- Eski uygulama sürümleri yeni sunucuyla uyumsuz olabilir (HomeModel.id String, kimlik akışı, komutların REST'ten geçmesi): **zorunlu güncelleme** planlayın; sunucu eski istemciyi `426`/mesajla yönlendirebilir.
- Akış denetimi (2026-10-04): yeni istemci eski sunucuyla da çalışır (`/auth/capabilities` `404` → SMS düğmesi gizli; `released_homes` yoksa `0`; eski acil sıfırlama yanıtındaki anahtar seri konsol yönergesiyle gösterilir; `409` "uygulamadı" hiç gelmezse eski akış sürer). Yeni sunucu + ESKİ istemci: parola değişiminde bu cihazın MQTT bağlantısı da atılır; eski istemci taze kimliği değişim yanıtı gelmeden eski belirteçle isterse (yavaş ağ) oturumu kapanabilir; panjur süresinde yeni `409` "uygulamadı" eski istemcide (yenile + tek yinelemeden sonra) "Kanal yerleşimi değişti" başlığıyla görünebilir. İstemci güncellemesi sunucuyla birlikte yayınlanmalıdır.

## 9. Geri alma

- Uygulama/API: önceki sürüm + eski `.env`; migration'lar **geri alınmaz** (ileri uyumlu tasarlandı); veri sorunu olursa §2'deki dump'tan `pg_restore` (ayrı DB'ye önce deneyin).
- EMQX: önceki `emqx.conf` + `emqx_data` yedeği; **kapı sisteminin Mosquitto'su hiç değişmediği için etkilenmez.**
- Cihazlar: eski firmware **yalnızca** legacy kimlik yükseltilmişse çalışır — bu yüzden geri alma penceresi, cihazların toplu yeniden flash'ından **önce** kapanmamalıdır.

## 10. İzleme (ilk 48 saat)

`/health`, 5xx oranı, broker ACL ret günlüğü, cihaz çevrimdışı sayısı (`devices.is_online`), köprü yazma gecikmesi, `schema_migrations` son satır, disk/RAM, `scheduled_rule_runs` hata oranı.
Akış denetimi günlükleri: `[RECONCILE] yerel_anahtar … sonuc=…` (`uygulandi` / `yayin_basarisiz` / `atlandi` / `gecersiz_bekleyen`), `[ENDPOINT] set_runtime cihaz onayi gelmedi`, `[MQTT-BRIDGE] Cihaz onayi bekleyici siniri`, `[PEACE] isik-kapat …`, `[AUTH] MQTT baglanti atma …`, `[MQTT-CRED] … atlandi`; bekleyen anahtar sayısı: `SELECT COUNT(*) FROM devices WHERE local_key_pending_enc IS NOT NULL`.
