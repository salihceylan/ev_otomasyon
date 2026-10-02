# AHBU Ev Otomasyonu - Deneme Rehberi

**Ne için:** Sistemi kendi makinenizde adım adım çalıştırıp denemek için kurulum ve komut rehberi. **Neyi** deneyeceğiniz `EVOTOMASYON_CANLI_TEST_KONTROL_LISTESI.md`'dedir; bu rehber **nasıl** hazırlanacağını anlatır.

**Doğruluk:** Komutlar, yollar ve ekran metinleri 2026-10-02 itibarıyla kodla (`tools/qa_stack/run.js` ve `lib/`, `lib/config/app_config.dart`, `server/`, fabrika aracı) karşılaştırıldı; uygulama bu rehberle çalıştırılarak denenmedi.

**Kabuk:** Bütün komutlar **Windows PowerShell** içindir ve **tek satırdır** (satır devamı yok). Kod bloklarını satır satır kopyalayın. `curl` yerine `curl.exe` yazın: Windows PowerShell 5.1'de `curl`, `Invoke-WebRequest`'in takma adıdır ve `-X` gibi bayrakları tanımaz.

**Tarih:** 2026-10-02  
**Sürüm:** 1.1  

---

## İçindekiler

1. [Genel Bakış](#1-genel-bakış)
2. [Seçenek A: Yerel QA Yığını](#2-seçenek-a-yerel-qa-yığını-önerilen)
3. [Uygulamayı Çalıştırma](#3-uygulamayı-çalıştırma)
4. [Seçenek B: Canlı Sunucu](#4-seçenek-b-canlı-sunucu)
5. [Gerçek Pano (Donanım)](#5-gerçek-pano-donanım)
6. [Ne Denemeli: Test Haritası](#6-ne-denemeli-test-haritası)
7. [Bilinen Sınırlar ve Doğrulanmayanlar](#7-bilinen-sınırlar-ve-doğrulanmayanlar)
8. [Sorun Giderme](#8-sorun-giderme)
9. [Başlamadan Önce Kontrol Listesi](#başlamadan-önce-kontrol-listesi)
10. [Sık Sorulan Sorular](#sık-sorulan-sorular)
11. [Kaynaklar](#kaynaklar)

---

## 1. Genel Bakış

### Sistem yapısı

Bu sistem üç ana bileşenden oluşur:

| Bileşen | İşlev | Denenebilir |
|---------|-------|-----------|
| **Flutter Uygulaması** (`lib/`) | Kullanıcı arayüzü | Emülatör, gerçek telefon, Windows masaüstü, web (Chrome) |
| **Node/PostgreSQL/MQTT Sunucusu** (`server/`) | API, yetkilendirme, MQTT köprüsü | Yerel QA yığını veya canlı dağıtım |
| **ESP32-S3 Firmware** (`ev_otomasyon_servis_yazilimi/`) | Cihaz denetim mantığı | Simülatör veya gerçek pano |

### Gerçek vs. Simüle

| Öğe | Yerel QA | Canlı Sunucu (henüz dağıtılmadı) | Gerçek Pano |
|-----|----------|-------------|-----------|
| **PostgreSQL** | 18, gömülü (Windows), `127.0.0.1:54329`, veritabanı `ev_qa` | 16 (docker), `127.0.0.1:5434` (yalnız sunucu içinden) | - |
| **MQTT Broker** | aedes (EMQX taklidi), TCP `1883`, ws `9001`, TLS yok | EMQX, `8884` (TLS) | Panonun bulut bağlantısı |
| **ESP32 Cihazı** | Node simülatörü (firmware mantığının portu) | - | Gerçek kart (firmware v1.1.0, **donanımda denenmedi**) |
| **TLS/Sertifika** | Yok | LetsEncrypt (dağıtımdan sonra) | Panonun MQTT TLS'i |
| **Wi-Fi Radyosu** | Sanal | - | Gerçek |
| **Röle/Panjur Motoru** | Yazılım modeli | - | Gerçek elektrik |

**Önemli:** QA'da REST yetki matrisi, veritabanı şeması ve sorgular **gerçek PostgreSQL'de** çalışır; TLS, EMQX'e özgü kimlik/ACL yapılandırması, gerçek radyo ve donanım sınanmaz (`docs/QA_STACK.md` §9). QA'da "yeşil" sonuç sahada da çalışacağı anlamına gelmez.

---

## 2. Seçenek A: Yerel QA Yığını (Önerilen)

### 2.1 Ön Koşullar

Makinenizde şunlar bulunmalıdır:

- **Node.js** ≥ 20.11 (yığın Node 24'te geliştirildi)
- **Flutter** SDK (emülatör, USB'li telefon, Windows ya da Chrome için)
- **Android SDK** ve bir emülatör (AVD) ya da USB hata ayıklaması açık bir Android telefon; SDK sürümleri Flutter'ın varsayılanlarıdır
- Windows masaüstü uygulaması için Visual Studio "Masaüstü geliştirme (C++ ile)" iş yükü
- Docker, `psql` gerekmez.

**Kurulum doğrulaması ve bağımlılıklar** (ilk kez ya da temiz bir klonda; yığın sunucuyu `server/` klasöründen çalıştırdığı için iki klasöre de kurulum gerekir):

```powershell
node --version
flutter --version
cd G:\site\ev_otomasyon\server
npm install
cd G:\site\ev_otomasyon\tools\qa_stack
npm install
```

### 2.2 Yığını Başlatma

Her deneme turuna **temiz** başlayın (`reset` veritabanını, sırları ve hesapları siler; tekrarlanan `up --stage2` zamanlı kuralları çoğaltır):

```powershell
cd G:\site\ev_otomasyon\tools\qa_stack
node run.js reset
node run.js up --stage2
```

- **Android emülatörü** için yukarıdaki `up --stage2` yeterlidir (uygulamaya bildirilen MQTT adresi `10.0.2.2`).
- **Windows masaüstü** ya da **USB'li gerçek telefon** (`adb reverse`) kullanacaksanız `up` satırını şöyle yazın: `node run.js up --stage2 --public-host 127.0.0.1`
- Yığın zaten çalışıyorsa `up` yeni seçenekleri uygulamaz ("QA yigini zaten calisiyor." der): önce `node run.js down`.
- Her `up` yeni sırlar üretir (uygulamadaki oturumlar düşer); oturumları korumak için `--keep-secrets` ekleyin.

**Beklenen `up` çıktısı** (satır kalıbı; PID, yol ve sayılar değişir):

```text
Daemon baslatildi (PID …); hazir olmasi bekleniyor (ilk calistirmada initdb ~20-60 sn)...
  [postgres,broker,…]

QA yigini: READY  (daemon PID …)
  PostgreSQL     127.0.0.1:54329  veritabani ev_qa  PID …
  MQTT broker    127.0.0.1:1883 (TCP)  ws://127.0.0.1:9001  kontrol http://127.0.0.1:18083  (tablolar hazir: true)
  Simulator      new1   AHBU-S3-0A0001   http://127.0.0.1:8081  emulator: http://10.0.2.2:8081  role=8
  Simulator      home1  AHBU-S3-0A0002   http://127.0.0.1:8082  emulator: http://10.0.2.2:8082  role=8
  SMTP cukuru    127.0.0.1:2525  -> …
  Migration      tamam  (scripts/migrate.js)
  REST API       http://127.0.0.1:5000/api/v1  emulator: …  PID …
  Tohumlama      tamam  (N/N adim)

Emulator (Android) icin:
  flutter run -d emulator-5554 --dart-define=API_BASE_URL=http://10.0.2.2:5000/api --dart-define=MQTT_TLS=false --dart-define=DEVICE_AP_HOST=10.0.2.2:8081
…
```

Çıkış kodu `0` = READY, `2` = DEGRADED (bir bileşen ya da tohum adımı başarısız: satırlarda `BASLATILAMADI` / `BASARISIZ` / `UYARI` arayın), `1` = başlatılamadı. Süre: ilk çalıştırma (initdb + migration + tohumlama) 1,5–2 dk sürebilir; sonrakiler ~10–15 sn.

**Başarı kontrolü:**

```powershell
node run.js status
node run.js smoke
```

`status` beklenen çıktısı (her satır `OK`, çıkış kodu `0`):

```text
OK    daemon       PID …, durum ready
OK    postgresql   127.0.0.1:54329 PID …
OK    mqtt broker  tcp:1883=true ws:9001=true istemci=… tablolar=true
OK    sim new1     … :8081 provizyonlu=false wifi=false
OK    sim home1    … :8082 provizyonlu=true wifi=true
OK    smtp cukuru  :2525
OK    rest api     :5000 PID … hazir=ready mqtt_koprusu=up
```

`smoke` (23 uçtan uca denetim) son satırı: `23/23 denetim gecti.` Bir satır `HATA` ise ya da `smoke` "zamanli kurallar … kural sayisi 8" derse tohum tekrarlanmıştır: `node run.js reset` + `node run.js up --stage2`. Diğer hatalar için **[8. Sorun Giderme](#8-sorun-giderme)**.

### 2.3 Hesaplar, E-postalar ve Loglar

Hesaplar `up --stage2` ile **gerçek REST akışıyla** oluşturulur ve `tools/qa_stack/.runtime/accounts.json`'a yazılır (gitignore'lu; repoya yazılmaz):

```powershell
node run.js accounts
```

Çıktıda: "Wi-Fi (simulator ev agi): QA-Ev-WiFi / [parola]", "CIHAZLAR" (her cihazın `setup_pin=`'i), "KULLANICILAR" (e-posta, **parola**, rol), "SERVIS PIN (home1): …" ve "EV home1 / home2" satırları. Ekranda parolalar görünür: ekran görüntüsü paylaşmayın.

**Hesap tablosu:**

| Anahtar | E-posta | Rol | Not |
|---------|---------|-----|------|
| `super` | `qa.super@example.com` | Süper Yönetici | |
| `staff` | `qa.servis@example.com` | Servis Sorumlusu | Süper yönetici tarafından **parolayla** açılır: uygulamada ilk girişte "Şifrenizi Değiştirin" sayfası zorunludur. "QA Daire 1"de servis üyeliği vardır |
| `owner1` | `qa.sahip1@example.com` | Ev Sahibi | "QA Daire 1" (pano `AHBU-S3-0A0002` = simülatör `home1`), 4 zamanlı kural, servis PIN'i |
| `owner2` | `qa.sahip2@example.com` | Ev Sahibi | "QA Daire 2 (baska ev)" (pano `AHBU-S3-0A0004`, simülatörsüz): başka evin verisine erişim (IDOR) denemeleri |
| `resident` | `qa.aile@example.com` | Aile Üyesi | "QA Daire 1" |
| `guest_valid` | `qa.misafir@example.com` | Süreli Misafir (24 saat) | "QA Daire 1" |
| `guest_expired` | `qa.misafir.eski@example.com` | Süresi Dolmuş Misafir | "QA Daire 1"; girişte "Erişim süreniz doldu" ekranı |

`qa.servis` hesabının şifresini uygulamada değiştirirseniz `accounts` eski parolayı göstermeye devam eder ve sonraki tohumlamada servis adımı giriş yapamaz: yeni şifreyi not edin; tohumu tazelemek için `node run.js reset` + `node run.js up --stage2`.

**E-postalar (kodlar, etkinleştirme bağlantıları):** sunucu e-postayı dışarı göndermez; SMTP çukuruna düşer:

```powershell
node run.js mails
node run.js mails 1
```

- `node run.js mails` en yeni 30 e-postayı `N. [zaman]  To: …  Subject: …` biçiminde numaralı listeler; `node run.js mails 1` 1 numaralı (en yeni) e-postanın **ham gövdesini** yazdırır. `mails 10` "son 10 e-posta" değil, 10 numaralı e-postadır (yoksa "Boyle bir e-posta yok.").
- Ham gövde quoted-printable kodlu olabilir: konu `=?UTF-8?Q?…?=`, Türkçe harfler `=C4=B1` gibi, bağlantıdaki `=` işareti `=3D` görünür ve uzun satırlar sonda `=` ile bölünür. 6 haneli kodlar rakam olarak okunur; bağlantıyı kopyalarken `=3D`'yi `=` yapın ve satır sonu `=` işaretlerini silin (ya da kodla ilerleyin).
- Bağlantılar QA'da da `https://evotomasyon.gudeteknoloji.com.tr/...` alan adını taşır (QA sunucusunda `APP_PUBLIC_URL` tanımlı değildir); debug uygulama bu alan adını tanır ve belirteci bağlı olduğu QA sunucusuna gönderir.
- E-posta düşen akışlar: hesap etkinleştirme, "Şifremi Unuttum" kodu, servis sihirbazı Adım 3 müşteri onay kodu ("Pano kurulum onay kodu"), Home Admin devri onay kodu. **Aile/misafir davet kodları ve daire devir kodu e-postayla gitmez**: ev sahibinin ekranında gösterilir.
- `.local` / `.invalid` uzantılı adreslere e-posta gönderilmez: yeni hesaplarda `@example.com` kullanın.

**Loglar:** `node run.js logs api -n 80`, `node run.js logs broker -f` (adlar: `daemon`, `broker`, `pg`, `api`, `sim`, `mail`, `migrate`).

### 2.4 Simülatör Cihazları

Yığın 2 (`--devices 3` ile 3) sanal pano başlatır:

| Ad | UID | HTTP portu | Emülatörden | Durum | Amaç |
|-----|-----|-----------|-------|-------|------|
| `new1` | `AHBU-S3-0A0001` | 8081 | `10.0.2.2:8081` | **Provizyonsuz**, stokta | Servis kurulum sihirbazı ve Wi-Fi akışı |
| `home1` | `AHBU-S3-0A0002` | 8082 | `10.0.2.2:8082` | **Provizyonlu**, bulutta | "QA Daire 1" (lamba/panjur, LAN modu) |
| `stock2` | `AHBU-S3-0A0003` | 8083 | `10.0.2.2:8083` | Provizyonsuz, 16 röle | Yalnız `up --stage2 --devices 3` |
| (`own2`) | `AHBU-S3-0A0004` | — | — | Simülatörsüz | "QA Daire 2 (baska ev)" |

`AHBU-S3-0A0003` simülatörü olmasa da envanterde stokta kayıtlıdır (eşlenebilir; pano çevrimdışı görünür). Simülatörlerin tanıdığı ev Wi-Fi'si `QA-Ev-WiFi`'dir (parola `accounts` çıktısında). Simülatör `10.0.2.2` ve `localhost` adlarını kendi içinde `127.0.0.1`'e eşler.

### 2.5 QA Kontrol Uçları

Simülatör, yalnız `127.0.0.1`'den erişilen test uçları açar (firmware'de yoktur):

| Uç | İşlev | PowerShell komutu |
|-------|-------|--------|
| `GET /__sim/state` | İç durum (`relays`, `shutters`, `child_lock`, `mqtt`, `wifi`, `provisioned`, `violation_count`) | `Invoke-RestMethod http://127.0.0.1:8082/__sim/state` |
| `POST /__sim/offline` / `POST /__sim/online` | Ani bağlantı kaybı (LWT `offline`) / geri gelme | `curl.exe -s -X POST http://127.0.0.1:8082/__sim/offline` |
| `POST /__sim/di/{n}/press` | n numaralı duvar girişine basış (varsayılan 150 ms) | `curl.exe -s -X POST http://127.0.0.1:8082/__sim/di/1/press` |
| `POST /__sim/slow` `{delay_ms, drop}` / `DELETE /__sim/slow` | Komut gecikmesi ya da sessizce düşürme / kaldırma | `Invoke-RestMethod -Method Post -Uri http://127.0.0.1:8082/__sim/slow -ContentType 'application/json' -Body '{"delay_ms":500}'` |
| `POST /__sim/power-cycle` | Güç kesintisi + yeniden açılış | `curl.exe -s -X POST http://127.0.0.1:8082/__sim/power-cycle` |
| `POST /__sim/ap` `{open}` | Kurulum/servis AP penceresini aç/kapat | `Invoke-RestMethod -Method Post -Uri http://127.0.0.1:8081/__sim/ap -ContentType 'application/json' -Body '{"open":true}'` |

Kısa yollar: `(Invoke-RestMethod http://127.0.0.1:8082/__sim/state).relays | Format-Table id,name,type,state` ve `(Invoke-RestMethod http://127.0.0.1:8082/__sim/state).violation_count` (panjur emniyet ihlali sayısı; 0 olmalı). Gecikmeyi kaldırmak: `Invoke-RestMethod -Method Delete -Uri http://127.0.0.1:8082/__sim/slow`.

### 2.6 Yığını Kapatma

```powershell
node run.js down
node run.js reset
```

- `down`: temiz kapatır; veritabanı, sırlar ve hesaplar korunur. Sonraki `up --stage2` tohumlamayı tekrarlar (zamanlı kurallar çoğalır) ve yeni sırlar üretir: kaldığınız yerden sürdürmek için `node run.js up --stage2 --keep-secrets --no-seed`.
- `reset`: kapatır ve `.runtime`'ı siler (veritabanı, sırlar, hesaplar, simülatör kayıtları); sonra `node run.js up --stage2` ile temiz başlarsınız.

---

## 3. Uygulamayı Çalıştırma

Bütün `flutter run` komutları **debug** derleme içindir: release derleme (`flutter build … --release` ya da `flutter run --release`) `--dart-define` değerlerini yok sayar ve her zaman canlı sunucuya gider (§7).

### 3.1 Android Emülatörü

**En uygun ortam:** Maddelerin çoğu için önerilir (yığın `node run.js up --stage2` ile başlatılmış olmalı).

**Adımlar:**

```powershell
flutter emulators
flutter emulators --launch <AVD adı>
flutter devices
cd G:\site\ev_otomasyon
flutter run -d emulator-5554 --dart-define=API_BASE_URL=http://10.0.2.2:5000/api --dart-define=MQTT_TLS=false --dart-define=DEVICE_AP_HOST=10.0.2.2:8081
```

Son satır, `up` çıktısındaki satırın aynısıdır (`emulator-5554` yerine `flutter devices`'ta gördüğünüz kimliği yazın).

**Beklenen davranış:**
- İlk derleme birkaç dakika sürer; uygulama emülatörde açılır ve giriş ekranı gelir.
- §2.3'teki bir hesapla giriş yapın.

**Bilinen sınırlar:**
- Emülatörde kamera/karekod, biyometrik ve gerçek Wi-Fi radyosu sınanmaz: karekod maddelerinde elle giriş yollarını kullanın ("Karekodu okutamıyorum: elle yazacağım", "Cihaz Kodunu Elle Gir").
- Android 9+ düz (cleartext) HTTP'yi engeller; debug derlemenin manifesti bunu açar (QA ve simülatör için gerekir).

---

### 3.2 Gerçek Android Telefon (USB)

**Ön Koşul:** USB veri kablosu, ADB sürücüsü, telefonda Geliştirici seçenekleri → USB hata ayıklama açık. Yığın `--public-host 127.0.0.1` ile başlatılmalı.

**Adımlar:**

```powershell
cd G:\site\ev_otomasyon\tools\qa_stack
node run.js down
node run.js up --stage2 --public-host 127.0.0.1
adb devices
adb reverse tcp:5000 tcp:5000
adb reverse tcp:1883 tcp:1883
adb reverse tcp:8081 tcp:8081
adb reverse tcp:8082 tcp:8082
cd G:\site\ev_otomasyon
flutter run -d <cihaz kimliği> --dart-define=API_BASE_URL=http://127.0.0.1:5000/api --dart-define=MQTT_TLS=false --dart-define=DEVICE_AP_HOST=127.0.0.1:8081
```

**Beklenen davranış:** Uygulama telefona kurulur, giriş ekranı gelir.

**Bilinen sınırlar:**
- Release derlemede düz HTTP yalnız `192.168.4.1`, `*.local` ve `localhost` için açıktır; ham LAN IP'siyle (örn. `192.168.1.40`) doğrudan mod release'te engellenir.
- Bu derleme kurulum ağı adresi olarak simülatörü (`127.0.0.1:8081`) kullanır. Gerçek panonun kurulum ağını (`192.168.4.1`) denemek için `DEVICE_AP_HOST` vermeden derleyin (§4.4).

---

### 3.3 Windows Masaüstü

**Ön Koşul:** Windows 10+, Visual Studio "Masaüstü geliştirme (C++ ile)". Windows'ta MQTT ham TCP ile `MQTT_PUBLIC_HOST`'a bağlanır: yığın `--public-host 127.0.0.1` ile başlatılmalı (varsayılan `10.0.2.2` Windows'tan erişilemez).

**Adımlar:**

```powershell
cd G:\site\ev_otomasyon\tools\qa_stack
node run.js down
node run.js up --stage2 --public-host 127.0.0.1
cd G:\site\ev_otomasyon
flutter run -d windows --dart-define=API_BASE_URL=http://127.0.0.1:5000/api --dart-define=MQTT_TLS=false --dart-define=DEVICE_AP_HOST=127.0.0.1:8081
```

**Beklenen davranış:** İlk derleme birkaç dakika sürer; masaüstü penceresinde giriş ekranı gelir.

**Bilinen sınırlar:**
- Kamera/karekod tarama yoktur (elle giriş yollarını kullanın).
- Biyometrik (Windows Hello) cihaza bağlıdır; denenmedi.
- `STL1011` derleme hatası için gereken tanım (`-D_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS`) `windows/CMakeLists.txt`'te **zaten vardır**: dosyayı değiştirmeyin; hata sürerse Visual Studio/MSVC sürümünü not edip bildirin.

---

### 3.4 Web (Chrome)

**Ön Koşul:** Chrome. QA sunucusu CORS için yalnız `http://localhost:7357`, `http://127.0.0.1:7357` (ve 8090) kökenlerine izin verir: `--web-port=7357` zorunludur. `API_BASE_URL` verilmezse uygulama **canlı** adrese gider.

**Adımlar:**

```powershell
cd G:\site\ev_otomasyon
flutter run -d chrome --web-port=7357 --dart-define=API_BASE_URL=http://127.0.0.1:5000/api --dart-define=MQTT_TLS=false
```

**Beklenen davranış:** Chrome açılır (`http://localhost:7357`), giriş ekranı gelir.

**Platform sınırları:**

| Özellik | Web (Chrome) | Windows masaüstü | Android (emülatör / telefon) |
|---------|-----|----------|-------|
| **Giriş, ev listesi, komutlar (REST)** | ✓ | ✓ | ✓ |
| **Canlı durum (MQTT)** | **✗** (web'de hiç başlatılmaz; durum "Yenile" ile güncellenir) | ✓ (TCP 1883; `--public-host 127.0.0.1` gerekir) | ✓ |
| **Cihaz yerel HTTP API / pano kurulum ağı** | **✗** (`403 bad_origin`; firmware CORS göndermez) | ✓ (QA'da `DEVICE_AP_HOST` ile simülatör) | ✓ |
| **Kamera / karekod tarama** | **✗** | ✗ | Yalnız gerçek telefonda |
| **Biyometrik** | **✗** | Denenmedi (Windows Hello) | Yalnız gerçek telefonda |

Web yalnız bulut modunda çalışır; Chrome için `--public-host` gerekmez (MQTT kullanılmaz).

---

## 4. Seçenek B: Canlı Sunucu

### 4.1 Durum

**ÖNEMLİ:** Canlı sunucu dağıtımı **henüz yapılmamıştır** (`docs/DEPLOY_RUNBOOK.md` uygulanmadı; sunucuya SSH erişimi yok). Aşağıdakiler dağıtımdan sonraki hedef düzendir:

- **API:** `https://evotomasyon.gudeteknoloji.com.tr/api` (nginx → `127.0.0.1:5000`; sunucu `BIND_HOST=127.0.0.1` ile dinler, ham IP:5000 dışarıdan erişilemez)
- **Sağlık:** `https://evotomasyon.gudeteknoloji.com.tr/ready` → `{"status":"ready","components":{"database":"up","mqtt_bridge":"up"},…}`
- **Veritabanı:** PostgreSQL 16 (docker), `127.0.0.1:5434` (yalnız sunucu içinden)
- **MQTT:** EMQX `evotomasyon.gudeteknoloji.com.tr:8884` (TLS); düz köprü yalnız `127.0.0.1:1884`, panel `127.0.0.1:18084`

### 4.2 Ön Koşullar

Canlı sunucuda deneme yapabilmek için:

1. Yeni sunucu kodu dağıtılmış ve **migration'ların tamamı** (001–030) uygulanmış: `MIGRATE_CONFIRM=<db_adı> node scripts/migrate.js --status` → son kayıt `030_peace_reminder.sql`
2. EMQX yapılandırması hazırlık kapsayıcısında doğrulanmış (`docs/DEPLOY_RUNBOOK.md`)
3. Süper yönetici hesabı hazır; parolası `docs/SECRET_ROTATION.md` madde 2'ye göre döndürülmüş (parola belgelere yazılmaz)
4. `/ready` → `database: "up"`, `mqtt_bridge: "up"`

### 4.3 Riskler

- Aynı sunucuda **üretimdeki site kapı sistemi** çalışır (Mosquitto `1883`/`8883` ve kapı API'si): ortak servisleri yeniden başlatmayın, testlerde `1883`/`8883`'e bağlanmayın.
- QA PostgreSQL 18 ile, canlı PostgreSQL 16 ile çalışır: bu sürüm farkı QA'da sınanmadı.
- Derin bağlantılar için `/.well-known/assetlinks.json` yayınlanmadı: e-postadaki bağlantı uygulama yerine tarayıcıda açılabilir.

### 4.4 Uygulamayı Canlıya Yönlendirme

Debug derlemenin varsayılanları zaten canlı değerlerdir (`https://evotomasyon.gudeteknoloji.com.tr/api`, TLS açık, kurulum ağı `192.168.4.1`): **hiç `--dart-define` vermeyin**.

```powershell
cd G:\site\ev_otomasyon
flutter run -d <cihaz kimliği>
```

Release APK da (`flutter build apk --release`) her zaman bu değerleri kullanır. `DEVICE_AP_HOST`'u canlıda vermeyin: gerçek panonun kurulum ağı adresi `192.168.4.1`'dir ve panonun web sunucusu 80 numaralı porttadır (`:8081` yalnız QA simülatörünün portudur).

**Beklenen davranışlar:**
- Giriş canlı veritabanına karşı doğrulanır.
- MQTT TLS bağlantısı (8884) sertifika doğrulamasıyla kurulur.
- Ev listesi canlı veritabanından yüklenir.

---

## 5. Gerçek Pano (Donanım)

### 5.1 Firmware Sürümü

**DONANIMDA DOĞRULANMADI:** v1.1.0 imajı yalnız dosya düzeyinde doğrulandı; hiçbir karta yazılıp çalıştırılmadı (`SURUM_NOTLARI.md`). Toplu üretimden önce tek bir test kartında deneyin.

| Dosya | SHA-256 | Durum |
|-------|---------|-------|
| `firmware_combined_0x0.bin` | `d1b5cb97a84b746b48282ad5ff37a04e18e9207dfe2969334aff617d9777ebd6` | **KULLANILACAK** (0x0 adresine) |
| `app_0x10000_v1.1.0.bin` | `08e372be0b6ee9f461103d2e48f3273e49b6c05f391a85b4bd0115c6e28339cf` | Yedek (yalnız 0x10000'a; 0x0'a yazmayın) |
| Eski v1.0.0/v1.0.1 | - | **KULLANILAMAZ** (USB provizyonu yok) |

Dosya konumu: `G:\site\ev_otomasyon\ev_otomasyon_servis_yazilimi\waveshare_s3_demo\firmware_releases\v1.1.0\` (`SHA256SUMS.txt` aynı klasörde). Özet doğrulama:

```powershell
cd G:\site\ev_otomasyon\ev_otomasyon_servis_yazilimi\waveshare_s3_demo\firmware_releases\v1.1.0
Get-FileHash -Algorithm SHA256 firmware_combined_0x0.bin
```

### 5.2 Flash Hazırlığı (Fabrika Aracı)

**Araçlar:** Fabrika aracı `ev_otomasyon_servis_yazilimi\ev_otomasyon_sistemi.py` (Python 3.11+, Tkinter, `qrcode`, `Pillow`; flash için esptool). Ayrıntılı, adım adım kullanım: `ev_otomasyon_servis_yazilimi/EV_OTOMASYON_KULLANIM_REHBERI.md`.

**Sıra önemlidir: sunucuya kaydet → firmware yükle → provizyon.** Kayıt flash'tan önce yapılmazsa provizyon kendiliğinden başlamaz ve kart bu arada **parolasız** kurulum ağı yayınlar.

```powershell
$env:EV_SERVER_URL='http://127.0.0.1:5000'
cd G:\site\ev_otomasyon\ev_otomasyon_servis_yazilimi
python ev_otomasyon_sistemi.py
```

(İlk satır yalnız QA sunucusu içindir; canlıda atlayın. Araç ayrıca `ev_otomasyon_sistemi.bat` ile de açılır.)

1. "🔐 Sunucuya Giriş" → "🔐 Süper Kullanıcı Girişi" ("Sunucu adresi:", "E-posta:", "Parola:") → "✓ Giriş Yap" (araç yalnız süper yönetici hesabıyla çalışır).
2. Kartı USB-C veri kablosuyla bağlayın; "⚡ 1. Firmware Yükleyici (Flasher)" sekmesinde "COM Port:" seçin ("🔄 Portları Yenile").
3. "🏷️ 2. Karekod Üret & Etiket Bas (Envanter)" sekmesinde "📡 Karttan MAC Oku" → UID ve kurulum PIN'i dolar → "☁️ SUNUCU ENVANTERİNE KAYDET & KAREKOD ÜRET" → "Cihaz Envantere Eklendi!".
4. "💾 Etiketi Kaydet (PNG)" / "🖨️ Yazdır (Barkod / Termal)".
5. Aynı oturumda 1. sekmede "🚀 Bizim Geliştirdiğimiz Yazılım (Otomatik Seçili)" işaretliyken "⚡ FİRMWARE'İ KARTA YÜKLE (FLASH)" (30–60 sn; USB'yi çıkarmayın).

**Elle (yedek):**

```powershell
esptool --chip esp32s3 --port COM3 --baud 460800 write_flash 0x0 firmware_combined_0x0.bin
```

(`esptool` PATH'te değilse `python -m esptool …`.) Elle yazılan kart **provizyonsuz** kalır: aynı araç oturumunda kayıt (adım 3) varken "📡 3. Cihaz Provizyonu (USB / Wi-Fi)" sekmesinde "🔌 Seri (USB) ile Provizyonla (Önerilen)"ye basın. Kayıt önceki bir oturumdaysa (yerel anahtar sunucudan yalnız bir kez gelir) kartı yeniden kaydedin.

### 5.3 Provizyonlama (Fabrika Aracı)

Flash bitince ve kayıt (5.2 adım 3) aynı oturumdaysa araç 3. sekmeye geçer ve USB (seri) `FACTORYINIT` provizyonunu **kendiliğinden** başlatır; yerel anahtar ve AP parolası kablosuz ağdan geçmez. Sonuç alanında sırayla "USB (seri) provizyon başlıyor …", "… FACTORYINIT gönderildi …" ve "✅ USB (seri) provizyon tamamlandı ve doğrulandı …" görünür; üstte "Durum: Provizyon doğrulandı ✔ (USB seri)" ve "Provizyon Tamamlandı" penceresi çıkar. Sonra:

1. Etiketin sağdaki 2. karekodunu telefon kamerasıyla okutup kurulum ağına bağlanmayı deneyin (5.4).
2. Etiketi pano kapağına yapıştırın; 3. sekmede "🧹 Kaydı Bellekten Sil / Yeni Cihaz"; PNG dosyasını silin (PIN ve Wi-Fi parolası içerir).

### 5.4 Kurulum Ağı

Provizyonlu kart kendi Wi-Fi erişim noktasını (WPA2) açar:

| Öğe | Değer |
|-----|-------|
| **SSID** | `AHBU-<MAC son 6 hex, büyük harf>` (örn. `AHBU-DD8754`) |
| **Parola** | Etikette "Ağ Parolası (AP)" satırındaki karta özel değer: 10 karakterlik harf-rakam dizisi (8–32 karakter kabul edilir). Etiketin 2. karekodu telefon kamerasıyla okutulunca tek dokunuşla bağlanır |
| **Frekans** | 2,4 GHz |
| **IP** | Pano: `192.168.4.1` (web arayüzü 80 numaralı port) |

Ağ ne zaman açık: provizyondan sonra yaklaşık 10 dk; ev Wi-Fi'si tanımlı değilken ya da 3 dk kopukken; seri `AP ON` komutuyla 10 dk. Telefon bu ağa bağlanınca uygulamada ekran **kendiliğinden açılmaz**: giriş ekranında "Pano Wi-Fi Kurulumu (İnternet Gerekmez)" ya da servis sihirbazı Adım 5 ile sihirbazı elle açın (kontrol listesi Aşama 16).

### 5.5 Açılış Kontrolü (Doğrulanmadı)

**ÖNEMLİ NOT:** Firmware gerçek kartta çalıştırılmadı; v1.1.0'ın bootloader'ı v1.0.1'inkinden farklıdır. İlk test kartında açılışı doğrulayın.

1. **Seri çıktı** (115200 baud, USB-C kablo): kalıp (zaman damgası yoktur):
   ```text
   ========================================
     AHBU Akilli Ev & Bina Otomasyonu (ESP32-S3)
   ========================================
   [BOOT] Reset nedeni: …
   [BOOT] GPIO_Init basliyor...
   [BOOT] RTC (PCF85063) basliyor...
   [BOOT] ConfigManager basliyor...
   [BOOT] ConfigManager tamam.
   [BOOT] SmartAutomation basliyor...
   [BOOT] SmartAutomation tamam.
   …
   Sistem hazir!
   ```
2. **LED ve bip:** açılışta durum LED'i yaklaşık 1 sn yeşil yanar ve kısa bir bip duyulur.
3. **Provizyon durumu:** seri konsola `STATUS` yazın → "Yerel anahtar (local_key): tanimli" (provizyonsuz kartta "YOK (provizyonsuz cihaz)").
4. **Kurulum ağı:** telefonun Wi-Fi listesinde `AHBU-XXXXXX` görünmeli (5.4).

---

## 6. Ne Denemeli: Test Haritası

`EVOTOMASYON_CANLI_TEST_KONTROL_LISTESI.md` (saha test belgesi) aşamalarının ortamlara eşlenmesi. "Canlı" ancak dağıtımdan sonra kullanılabilir (§4).

| Aşama | Başlık | Önerilen ortam | Gereken donanım / not |
|-------|--------|-----------|-------|
| **1** | Süper Kullanıcı Girişi & Konsol | QA / canlı | — |
| **2** | Servis Sorumlusu Tanımlama | QA / canlı | — |
| **3** | Servis Sorumlusunu Etkinleştirme & Konsol | QA / canlı | — |
| **4** | Daire Sahibi (Müşteri) | QA / canlı | — |
| **4.5** | Fabrika aracı: kayıt, etiket, flash, provizyon | QA ya da canlı sunucu | Gerçek pano + USB-C, Windows PC |
| **5** | Sihirbaz Adım 1–4 (eşleme) | QA (`new1`) / gerçek pano | Karekod için gerçek telefon |
| **6** | Sihirbaz Adım 5, 6, 8 (Wi-Fi, bulut, panjur) | Gerçek pano (QA kısmen) | Gerçek pano |
| **7** | Sihirbaz Adım 7, 9, 10 (röle, buton, teslim) | QA / gerçek pano | — |
| **8** | Ev sahibinin paneli | QA (`home1`) / gerçek pano | — |
| **9** | Süper yönetici takip & Sistem Doktoru | QA / canlı | — |
| **10** | Servis konsolu & saha araçları | QA / canlı | — |
| **11** | Dairesi olmayan kullanıcı | QA / canlı | Karekod için gerçek telefon |
| **12** | Menü & panel izolasyonu | QA / canlı | — |
| **13** | Sihirbazda karekod & müşteri kodu | QA / canlı | 13.2 için gerçek telefon |
| **14** | Acil sıfırlama & pano değişimi | QA / canlı | Kamera için gerçek telefon |
| **15** | Tema | Herhangi | — |
| **16** | Pano Wi-Fi kurulum ağı | Gerçek pano | Gerçek pano + gerçek Android telefon (iOS kapsam dışı) |
| **17** | Sihirbaz röle/buton/teslim ayrıntıları | QA / gerçek pano | — |
| **18** | Devam eden kurulum, mevcut cihazlar, adres | QA / gerçek pano | — |
| **19** | Abonelerim & Home Admin | QA / canlı | — |
| **20** | Süreli misafir | QA / canlı | 20.4 için gerçek telefon; 20.3 gerçek bekleme ister |
| **21** | Üye yönetimi & rol matrisi | QA / canlı | İkinci cihaz/hesap |
| **22** | Daire devri | QA / canlı | İkinci hesap |
| **23** | Çocuk kilidi | QA / gerçek pano | 23.2 iki pano; 23.4 gerçek telefon |
| **24** | Gece huzur bildirimi | QA / canlı | — |
| **25** | Zamanlı kurallar | QA / canlı | — |
| **26** | Hesap güvenliği | QA / canlı | İkinci cihaz |
| **27** | Biyometrik kilit | Gerçek telefon | Gerçek Android telefon |
| **28** | Hesap silme | QA / canlı | — |
| **29** | Yerel ağ (LAN) doğrudan mod | QA (`home1`) / gerçek pano | — |
| **30** | Derin bağlantı & karekod yönlendirme | Gerçek telefon | Gerçek Android telefon |
| **31** | Dayanıklılık | QA / canlı | İkinci cihaz |
| **32** | Servis PIN'i & yetki sınırları | QA / canlı | İkinci cihaz |

QA yığınında yapılamayanlar: gerçek radyo ve elektrik, kamera/karekod (emülatör, Windows, web), biyometrik, derin bağlantıya dokunma, iOS.

### Başlangıç Senaryosu (15 dakika)

**Amaç:** Sistemin sağlıklı açıldığını doğrulamak.

1. **Yerel QA başlat:**
   ```powershell
   cd G:\site\ev_otomasyon\tools\qa_stack
   node run.js reset
   node run.js up --stage2
   node run.js status
   node run.js smoke
   ```
   Beklenen: `status`'ta tüm satırlar `OK` (`rest api` satırında `hazir=ready mqtt_koprusu=up`), `smoke` → `23/23 denetim gecti.`

2. **Emülatörde uygulamayı başlatın** (§3.1) ve `qa.super@example.com` ile (parola: `node run.js accounts`) giriş yapın.

3. **Konsolu kontrol edin:**
   - "Süper Yönetici Konsolu" açılır; "Servis Sorumluları", "Pano Envanteri", "Devreye Alınan" sayaçları "—" değil, sayı gösterir.
   - Konsolda altyapı (API/veritabanı/MQTT) satırı yoktur: altyapı sağlığı 1. adımdaki `status` çıktısıdır.

4. **Çıkış:** ☰ → "Güvenli Çıkış Yap" (ya da profil → "Oturumu Kapat") → "Çıkış Yapılsın mı?" → "Evet, Çıkış Yap".

### Servis Kurulum Senaryosu (30–45 dakika)

**Amaç:** 10 adımlı servis kurulum sihirbazını simülatör `new1` (`AHBU-S3-0A0001`, provizyonsuz) ile uçtan uca denemek. Simülatörü ayrıca provizyonsuz yapmaya gerek yoktur.

1. `node run.js accounts` → `new1 … setup_pin=` değerini ve "Wi-Fi (simulator ev agi)" parolasını not edin.
2. Emülatörde `qa.servis@example.com` ile girin → "Şifrenizi Değiştirin" → yeni şifre (not edin).
3. Konsol → "Devreye Alma (Servis Modu)" → "Servis Paneli" → "Yeni Kurulum Başlat".
4. **Adım 1 "Hazırlık":** "Bağlantıyı Doğrula" → "Devam".
5. **Adım 2 "Cihazı Tanı":** "Karekodu okutamıyorum: elle yazacağım" → "Cihaz seri numarası" `AHBU-S3-0A0001`, "Kurulum PIN (6 rakam)" → "Bilgileri Kullan" → "Devam".
6. **Adım 3 "Müşteri":** müşteri e-postası (örn. `musteri1@example.com`) → "Kod Gönder" → `node run.js mails` ve `node run.js mails 1` ile "Pano kurulum onay kodu"nu okuyun → "Müşterinin söylediği 6 haneli kod" → "Devam".
7. **Adım 4 "Daireye Bağla":** "Daireye Bağla" → "Evet, Bağla" → "Müşteri için yeni hesap açıldı; etkinleştirme e-postası gönderildi." → "Devam".
8. **Adım 5 "Wi-Fi Kurulumu":** "Bağlandım: Panoyu Kontrol Et" → ağ listesinden `QA-Ev-WiFi` → parola → "Yeni Wi-Fi Şifresini Panoya Yükle" → "Pano ev Wi-Fi ağına bağlandı" mesajı → "Devam".
9. **Adım 6 "Bulut Bağlantısı":** "Pano IP adresi" alanına `10.0.2.2:8081` yazın → "Panoya Bağlan" → "Buluta Bağla ve Bekle" → "Çevrimiçi". (Emülatörde bu adım çalıştırılarak denenmedi: DOĞRULANMADI.)
10. **Adım 7 "Röle Testi":** "Röleleri Listele" → her röle "Aç" / "Kapat" → "Evet, çalıştı" (simülatörde gözle değil `(Invoke-RestMethod http://127.0.0.1:8081/__sim/state).relays` ile doğrulayın).
11. **Adım 8 "Panjur Testi ve Kalibrasyon":** "Panjurları Listele" → "Yukarı" → "Evet, yukarı gitti" → "Süreyi biliyorum: elle gireceğim" → `20` → "Bu Süreyi Kullan" (kronometreli ölçüm de yapılabilir; `up --time-scale N` panjuru hızlandırır).
12. **Adım 9 "Duvar Butonları":** "Dinlemeyi Başlat" → her giriş için `curl.exe -s -X POST http://127.0.0.1:8081/__sim/di/1/press` (numarayı değiştirerek) ya da "Bu girişte buton yok".
13. **Adım 10 "Teslim":** "Müşteriye kurulumu gösterdim ve teslimi onayladı" → "Devreye Almayı Tamamla" → "Kurulum tamamlandı: sunucu tüm testleri doğruladı ve cihazı devreye aldı." → "Bitir".

### Panjur Kontrolü Senaryosu (20 dakika)

**Amaç:** Lamba ve panjur komutlarını ve panjur emniyetini doğrulamak.

1. **Ev sahibi** `qa.sahip1@example.com` ile girin ("QA Daire 1", simülatör `home1`).
2. **Kontrol paneli:** "Aydınlatma & Çıkışlar"da bir lambayı açıp kapatın; "Panjurlar"da "Aç", "Durdur", "Kapat" ve kaydırıcıyı deneyin.
3. **Durumu kontrol edin:**
   ```powershell
   (Invoke-RestMethod http://127.0.0.1:8082/__sim/state).relays | Format-Table id,name,type,state
   ```
   `state` değerleri komutlarla değişmeli.
4. **Yön değişimi (ters yön) testi:**
   - Panjuru açmaya başlatın ("Aç"), 2 sn sonra "Kapat"a basın.
   - Beklenen: komut **reddedilmez**; panjur hemen durur, en az 0,5 sn ölü zamandan sonra aşağı iner.
   - `(Invoke-RestMethod http://127.0.0.1:8082/__sim/state).violation_count` → `0` kalmalı (iki yön aynı anda, doğrudan yön değişimi ya da 0,5 sn'den kısa ölü zaman olmamalı).
5. **Kesintisiz çalışma sınırı:** aynı yönde komutu tekrarlamak toplam süreyi uzatmaz; panjur "tam yol + 2 sn oturma payı" sonunda kendiliğinden durur.

### Çevrimdışılık Senaryosu (10 dakika)

**Amaç:** Çevrimdışı cihaz davranışını doğrulamak.

1. **Cihazı çevrimdışı yapın:**
   ```powershell
   curl.exe -s -X POST http://127.0.0.1:8082/__sim/offline
   ```

2. **Uygulamada:**
   - Kartlarda "Çevrimdışı • son bilinen" ve ekranda "Pano çevrimdışı" kartı ("Yeniden dene", "Sistem Doktoru"; yetkili hesapta "Wi-Fi Kurtarma Modu") görünür.
   - Lambaya dokunun: hemen (2,5 sn beklenmeden) "Cihaz çevrimdışı. Komut iletilemedi." + "Tekrar dene"; anahtar eski hâline döner.

3. **Cihazı çevrimiçi yapın:**
   ```powershell
   curl.exe -s -X POST http://127.0.0.1:8082/__sim/online
   ```

4. **Durum yenilenir, pano çevrimiçi görünür** ("Sistem Hazır • Bulut").

---

## 7. Bilinen Sınırlar ve Doğrulanmayanlar

### 7.1 Yerel QA Yığınında Kanıtlanmayanlar

QA yığını REST/MQTT/cihaz sözleşmesini ve gerçek PostgreSQL'i sınar; aşağıdakiler sınanmaz (`docs/QA_STACK.md` §9):

| Konu | QA yığınında | Nerede doğrulanır |
|------|------|------|
| **ESP32 zamanlaması, bellek, I2C/RS485 elektriği** | Node simülatörü (firmware mantığının portu); zamanlama ±10 ms oynar | Gerçek pano |
| **MQTT TLS, EMQX kimlik/ACL yapılandırması** | aedes (EMQX taklidi), düz TCP `1883` | Canlı EMQX (`8884`, TLS), dağıtımdan sonra |
| **Wi-Fi radyosu, kurulum ağı (SoftAP), telefonun ağ değiştirmesi** | Sanal (`/__sim/client-net` modeli) | Gerçek pano + gerçek Android telefon (Aşama 16) |
| **Röle/panjur elektriği, motor süresi** | Yazılım modeli (`violation_count` emniyet gözlemcisi) | Gerçek pano + motor |
| **LWT gecikmesi** | `__sim/offline` soketi hemen kapatır: sunucu birkaç saniyede "çevrimdışı" görür | Gerçek panoda elektrik kesilince ≈45 sn (keepalive 30 sn × 1,5) |
| **Android'de pano ağına bağlanma** (`bindProcessToNetwork`, `docs/CONTRACTS.md` §5), mobil veri | Sınanamaz | Gerçek Android telefon (16.11) |
| **Kamera / karekod** | Emülatör, Windows ve web'de yok: elle giriş yollarını kullanın | Gerçek telefon |
| **Biyometrik** | Sınanamaz | Gerçek telefon (Aşama 27) |
| **Telefona bildirim (push)** | Bu sürümde yok (Firebase/APNs yapılandırılmadı); gece hatırlatması yalnız uygulama içinde görünür ("Bu sürümde bildirim telefona gönderilmez; uygulamayı açtığınızda hatırlatma görünür.") | — |
| **Derin bağlantı (App Links)** | Sınanamaz | Gerçek telefon; alan adında doğrulama dosyası (`assetlinks.json`) yayımlandıktan sonra (Aşama 30) |
| **iOS** | Bu turda kapsam dışı: derlenip denenmedi (macOS + Xcode gerekir) | — |
| **PostgreSQL sürümü** | 18 | Canlı 16: sürüm farkı canlıda doğrulanır |
| **Kod / davet / oturum süreleri** | QA'da kısaltılamaz | Gerçek süre beklenerek (kontrol listesindeki maddeler belirtir) |

### 7.2 Release Derlemesi

`lib/config/app_config.dart`: `API_BASE_URL`, `MQTT_TLS` ve `DEVICE_AP_HOST` değerleri **release** derlemede (`kReleaseMode`) yok sayılır. Bu yüzden:

- `flutter build apk --release` de `flutter run --release` de uygulamayı her zaman **canlı** sunucuya (`https://evotomasyon.gudeteknoloji.com.tr/api`, TLS'li MQTT) ve gerçek kurulum ağına (`192.168.4.1`) yönlendirir; `--dart-define` işe yaramaz.
- QA yığınıyla deneme için **debug** derleme (`--release` olmadan `flutter run`) zorunludur.
- Canlı sunucu dağıtılana kadar (§4.1) release derlemeyle giriş denenemez.

### 7.3 Windows Derlemesi

- Visual Studio "Masaüstü geliştirme (C++ ile)" iş yükü gerekir.
- `STL1011` için gereken tanım (`add_definitions(-D_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS)`) `windows/CMakeLists.txt`'te **zaten vardır**: dosyayı değiştirmeyin (§3.3).
- Kamera/karekod yoktur; MQTT için yığın `--public-host 127.0.0.1` ile başlatılmalıdır.

### 7.4 Web (Chrome)

Web uygulaması **yalnız bulut (REST) modunda** çalışır:

- **Canlı durum (MQTT):** ✗ web'de hiç başlatılmaz; durum çubuğunda "Canlı izleme kesik" beklenir, durumu üst çubuktaki "Yenile" ile güncelleyin.
- **Pano yerel HTTP API'si / kurulum ağı:** ✗ pano tarayıcı isteğini `403 bad_origin` ile reddeder, CORS başlığı göndermez.
- **Kamera / karekod:** ✗ (elle giriş yollarını kullanın).
- **Biyometrik:** ✗

---

## 8. Sorun Giderme

Komutlar `G:\site\ev_otomasyon\tools\qa_stack` klasöründe çalıştırılır.

### Yığın başlamıyor: "Port cakismasi"

`up` şu biçimde durur (çıkış kodu `1`):

```text
QA yigini BASLATILAMADI: Port cakismasi:
  - REST API :5000 dolu -> … (degistirmek icin QA_API_PORT)
```

1. Önceki yığın açık kalmış olabilir: `node run.js status`, sonra `node run.js down`.
2. Portu başka bir program kullanıyorsa hangisi olduğuna bakın: `Get-NetTCPConnection -LocalPort 5000 -State Listen | Select-Object LocalPort,OwningProcess` ve `Get-Process -Id [PID]`. Size ait olmayan süreci kapatmayın; QA portunu değiştirin.
3. Port değiştirme (aynı PowerShell penceresinde, `up`'tan önce ve sonraki komutlarda da aynı pencerede): `$env:QA_API_PORT='5001'` ya da `$env:QA_MQTT_PORT='1884'`, sonra `node run.js up --stage2`. Değişkenler: `QA_API_PORT`, `QA_MQTT_PORT`, `QA_MQTT_WS_PORT`, `QA_BROKER_CONTROL_PORT`, `QA_SUPERVISOR_PORT`, `QA_SMTP_PORT`, `QA_SIM_PORT_1`…`QA_SIM_PORT_3`; PostgreSQL için `--pg-port N`.
4. API portunu değiştirdiyseniz uygulamayı yeni portla başlatın (`up` çıktısındaki `flutter run` satırı yeni portu gösterir); USB'li telefonda `adb reverse` satırlarını da yeni portlarla yazın. MQTT portunu uygulama sunucudan öğrenir.

### PostgreSQL başlamıyor / `up` takılıyor

1. `node run.js logs pg -n 50` ve `node run.js logs daemon -n 50`.
2. Önceki çalışmadan yetim `postgres.exe` kaldıysa: `node run.js down` (yalnız yığının kendi veri klasörüne ait süreçleri kapatır).
3. İlk çalıştırma yavaşsa bekleme süresini uzatın: `node run.js up --stage2 --timeout 600` (varsayılan 300 sn).
4. Sürerse temiz başlangıç: `node run.js reset` + `node run.js up --stage2`.

### Sunucu (REST API) açılmıyor

`up` çıktısında `REST API       BASLATILAMADI: …` ya da `Migration      BASARISIZ`, `status`'ta `HATA  rest api`:

1. `node run.js logs api -n 80`; yerel çökme raporları `tools\qa_stack\.runtime\api_reports\` altındadır.
2. `Cannot find module …` görürseniz bağımlılıklar eksiktir: `cd G:\site\ev_otomasyon\server` → `npm install`, `cd G:\site\ev_otomasyon\tools\qa_stack` → `npm install`, sonra `node run.js down` + `node run.js up --stage2`.
3. Migration hatası: `node run.js logs migrate -n 100`; ardından `node run.js reset` + `node run.js up --stage2`.
4. `Tohumlama      KISMEN BASARISIZ` görürseniz (çıkış kodu `2`): `node run.js logs daemon -n 80`; çoğunlukla `reset` + `up --stage2` çözer.

### Uygulamada "Pano çevrimdışı" görünüyor

1. Simülatörün bulut bağlantısı: `(Invoke-RestMethod http://127.0.0.1:8082/__sim/state).mqtt` → `connected` ve `cmd_subscribed` `True` olmalı.
2. Daha önce `__sim/offline` gönderdiyseniz geri alın: `curl.exe -s -X POST http://127.0.0.1:8082/__sim/online` (simülatör birkaç saniyede yeniden bağlanır).
3. Broker günlüğü: `node run.js logs broker -n 50` → `connect_denied` (cihaz kimliği reddedildi) ya da `sub_denied` / `pub_denied` (ACL reddi); simülatör tarafında `node run.js logs sim -n 50` → `mqtt_subscribe_denied`.
4. Simülatörü kapatıp açın: `curl.exe -s -X POST http://127.0.0.1:8082/__sim/power-cycle` (açılış birkaç saniye sürer).
5. Sürerse: `node run.js down` + `node run.js up --stage2 --keep-secrets --no-seed`.

### Uygulamada "Canlı izleme kesik" görünüyor

Pano çevrimiçi ama uygulamanın kendi MQTT bağlantısı kurulamamış demektir:

- Windows masaüstü ya da USB'li telefonda yığın `--public-host 127.0.0.1` ile başlatılmış olmalı (varsayılan `10.0.2.2` yalnız emülatörden erişilir); USB'li telefonda ayrıca `adb reverse tcp:1883 tcp:1883`.
- Web'de (Chrome) MQTT hiç başlatılmaz: bu etiket web'de beklenir; durumu "Yenile" ile güncelleyin.
- Yığın yeniden başlatıldıysa uygulama artan aralıklarla (2, 4, 8, 16, 32, en çok 60 sn) yeniden bağlanmayı dener: en geç yaklaşık bir dakika bekleyin.

### Komut gidiyor ama pano uygulamıyor / anahtar geri dönüyor

- Pano buluta yeniden bağlandıktan sonraki **ilk 1500 ms** içinde gelen komutları yok sayar (`docs/CONTRACTS.md` §2.2); sunucu yine "iletildi" der. Uygulama 2,5 sn içinde onay gelmezse anahtarı geri alır ve "Cihazdan onay alınamadı. İşlem geri alındı; durum yeniden kontrol ediliyor." + "Tekrar dene" gösterir: "Tekrar dene"ye basın.
- `__sim/slow` ile gecikme ya da düşürme açık kaldıysa kaldırın: `Invoke-RestMethod -Method Delete -Uri http://127.0.0.1:8082/__sim/slow`.

### Emülatör açılmıyor / `flutter devices` emülatörü göstermiyor

```powershell
flutter emulators
flutter emulators --launch [AVD adı]
flutter devices
```

- Liste boşsa Android Studio'da "Device Manager" ile bir sanal cihaz (AVD) oluşturun ya da `flutter emulators --create --name qa_pixel` (kurulu bir Android sistem imajı gerekir).
- `flutter doctor` çıktısındaki Android uyarılarını giderin.
- `flutter run -d` için `flutter devices`'ta görünen kimliği (`emulator-5554` gibi) kullanın.

### E-posta (kod / bağlantı) görünmüyor

1. `node run.js mails` listesinde yoksa: `node run.js logs mail -n 20` ve `node run.js logs api -n 80` (gönderim hatası).
2. Alıcı adresi `.local` ya da `.invalid` ile bitiyorsa sunucu e-postayı hiç göndermez: `@example.com` kullanın.
3. Liste en yeni 30 e-postayı gösterir; `node run.js mails 1` en yenisidir.
4. Aile/misafir davet kodu ve daire devir kodu e-postayla gelmez: ev sahibinin ekranında gösterilir.

### Uygulama girişe döndü: "Oturumunuz sona erdi. Lütfen tekrar giriş yapın."

Her `up` yeni JWT sırrı üretir ve önceki oturumlar geçersiz olur. Yeniden giriş yapın; yığını yeniden başlatırken oturumları korumak için `node run.js up --stage2 --keep-secrets --no-seed` kullanın.

### `smoke` 23/23 değil

`smoke` tohumlanan başlangıç durumunu varsayar; elle yapılan denemeler bunu bozabilir:

- `giris: staff` HATA: `qa.servis` şifresi uygulamada değiştirildi (`accounts.json` eski parolayı tutar).
- `zamanli kurallar … kural sayisi` 4'ten farklı: tohum tekrarlandı (`up --stage2` iki kez) ya da Aşama 25'te kural eklendi/silindi.
- Üyelik, devir ve hesap silme denemeleri (Aşama 21, 22, 28) giriş, yetki ve komut denetimlerini bozabilir.

Çözüm: `node run.js reset` + `node run.js up --stage2`, sonra `node run.js smoke`.

### `status` sonunda "Assertion failed … UV_HANDLE_CLOSING"

Windows/libuv kaynaklıdır ve zararsızdır (`docs/QA_STACK.md` §11).

### `.runtime` klasörü büyüdü

`tools\qa_stack\.runtime` veritabanını, günlükleri, e-postaları ve simülatör kayıtlarını tutar. `node run.js reset` hepsini siler (hesaplar ve sırlar dahil); sonra `node run.js up --stage2`.

---

## Başlamadan Önce Kontrol Listesi

- [ ] Node.js ≥ 20.11 (`node --version`)
- [ ] Flutter SDK (`flutter --version`; `flutter doctor`'da Android satırı sorunsuz)
- [ ] Android emülatörü (AVD) ya da USB hata ayıklaması açık bir Android telefon
- [ ] `G:\site\ev_otomasyon\server` ve `G:\site\ev_otomasyon\tools\qa_stack` klasörlerinde `npm install` yapıldı
- [ ] `node run.js reset` + `node run.js up --stage2` (Windows/USB'li telefon için `--public-host 127.0.0.1`) `QA yigini: READY` ile bitti (çıkış kodu `0`)
- [ ] `node run.js status`: her satır `OK` (çıkış kodu `0`)
- [ ] `node run.js smoke` → `23/23 denetim gecti.`
- [ ] `node run.js accounts` ile hesaplar ve parolalar görüldü
- [ ] Uygulama **debug** derlemeyle, §3'teki `--dart-define` değerleriyle başlatıldı
- [ ] `qa.sahip1@example.com` ile giriş yapıldı; "QA Daire 1" panelinde durum "Sistem Hazır" (web'de "Canlı izleme kesik" beklenir)

Bir adım başarısızsa [8. Sorun Giderme](#8-sorun-giderme) bölümüne bakın.

---

## Sık Sorulan Sorular

### S: Yerel QA yığını ne kadar sürede açılır?

**C:** İlk çalıştırma (initdb + migration + tohumlama) 1,5–2 dk sürebilir; sonrakiler ~10–15 sn. `up` hazır olmayı en çok 300 sn bekler (`--timeout` ile değişir).

### S: Kodları (doğrulama, etkinleştirme, şifre sıfırlama) nerede bulurum?

**C:** `node run.js mails` (liste) ve `node run.js mails N` (N numaralı e-postanın ham gövdesi; §2.3). Aile/misafir davet kodu ve daire devir kodu e-postayla gitmez: ev sahibinin ekranında gösterilir.

### S: Release derlemesi neden yerel QA sunucusuna bağlanmıyor?

**C:** `API_BASE_URL`, `MQTT_TLS` ve `DEVICE_AP_HOST` release derlemede (`flutter build … --release` ve `flutter run --release`) yok sayılır; uygulama her zaman canlı adrese gider. QA için debug derleme kullanın (§7.2).

### S: Gerçek pano neden "doğrulanmadı" olarak geçiyor?

**C:** Firmware v1.1.0 gerçek kartta çalıştırılarak doğrulanmadı; QA simülatörü firmware mantığının Node portudur. Açılış, Wi-Fi radyosu, röle/motor elektriği ve TLS sahada doğrulanmalıdır (§5.5, kontrol listesi Aşama 4.5 ve 16).

### S: Web uygulaması panoya (kurulum ağı / yerel IP) neden bağlanamıyor?

**C:** Pano tarayıcı isteklerini `Origin` denetimiyle reddeder (`403 bad_origin`) ve CORS başlığı göndermez; web'de MQTT de başlatılmaz. Web yalnız bulut (REST) modunda çalışır.

### S: Windows'ta `STL1011` derleme hatası alıyorum.

**C:** Gereken tanım (`_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS`) `windows/CMakeLists.txt`'te zaten vardır; dosyayı değiştirmeyin. `flutter clean` sonrası yeniden derleyin; hata sürerse Visual Studio/MSVC sürümünü not edip bildirin.

### S: `10.0.2.2` nedir?

**C:** Android emülatörünün içinden bakıldığında bilgisayarınızın `127.0.0.1`'idir. QA yığını uygulamaya MQTT adresi olarak varsayılan `10.0.2.2`'yi bildirir; simülatörler bu adı kendi içinde `127.0.0.1`'e çevirir. Windows masaüstü ve USB'li telefonda bu adres çalışmaz: `--public-host 127.0.0.1` kullanın.

### S: Süreli kodları ya da misafir süresini telefonun saatini ileri alarak deneyebilir miyim?

**C:** Hayır. Süreleri sunucu kendi saatine göre denetler; telefonun saati sonucu değiştirmez ve QA'da süreler kısaltılamaz. Süresi dolmuş misafir için hazır `qa.misafir.eski@example.com` hesabını kullanın; diğer sürelerde gerçek süreyi bekleyin.

### S: Pano "çevrimdışı" görünüyor ama simülatör çalışıyor.

**C:** §8'deki "Uygulamada 'Pano çevrimdışı' görünüyor" adımlarını izleyin (`__sim/state` → `mqtt`, broker günlüğü, `__sim/online`, `__sim/power-cycle`).

---

## Kaynaklar

| Kaynak | İçerik |
|--------|------|
| `EVOTOMASYON_CANLI_TEST_KONTROL_LISTESI.md` | Neyin deneneceği: Aşama 1–32 (+ 4.5), beklenen sonuçlar |
| `docs/QA_STACK.md` | Yerel QA yığınının teknik başvurusu (bileşenler, simülatör, sınırlar, sorun giderme) |
| `docs/CONTRACTS.md` | REST / MQTT / pano yerel API sözleşmeleri |
| `docs/DEPLOY_RUNBOOK.md` | Canlı sunucu dağıtımı (henüz uygulanmadı) |
| `docs/SECRET_ROTATION.md` | Sır ve parola yenileme adımları |
| `ev_otomasyon_servis_yazilimi/EV_OTOMASYON_KULLANIM_REHBERI.md` | Fabrika aracı (kayıt, etiket, flash, provizyon) |
| `ev_otomasyon_servis_yazilimi/waveshare_s3_demo/firmware_releases/v1.1.0/SURUM_NOTLARI.md` | Firmware v1.1.0 sürüm notları ve imajları |

---

**Son güncelleme:** 2026-10-02 (kodla karşılaştırıldı; uygulama bu rehberle çalıştırılarak denenmedi)
