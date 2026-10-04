# AHBU Ev Otomasyonu - Deneme Rehberi

**Ne için:** Sistemi kendi makinenizde adım adım çalıştırıp denemek için kurulum ve komut rehberi. **Neyi** deneyeceğiniz `EVOTOMASYON_CANLI_TEST_KONTROL_LISTESI.md`'dedir; bu rehber **nasıl** hazırlanacağını anlatır.

**Doğruluk:** Komutlar, yollar ve ekran metinleri 2026-10-02 itibarıyla kodla (`tools/qa_stack/run.js` ve `lib/`, `lib/config/app_config.dart`, `server/`, fabrika aracı) karşılaştırıldı. QA yığını komutları (§2, §8) ayrı bir çalışma klasöründe gerçekten çalıştırıldı (temiz `up --stage2` ~27 sn, `smoke` 23/23, ikinci `up --stage2` hiçbir şeyi çoğaltmadı). Uygulama (Flutter), gerçek pano ve canlı sunucu bu rehberle çalıştırılarak denenmedi. Aşama 33 / WP-L (pano yerleşiminin buluta eşitlenmesi) ile ilgili notlar (§1, §2.4, §2.5, §4.2, §6, §7.1, §7.4) 2026-10-03'te `server/src/services/endpoint_layout_sync.js`, `server/src/utils/endpoint_layout.js`, `server/src/mqtt_bridge.js`, `tools/qa_stack/sim` ve uygulamanın WP-L istemci yenilemesi (dev kopya: `G:\site\ev_otomasyon_dev`; ana ağaçta henüz yok) kaynağıyla karşılaştırıldı; QA yığınında çalıştırılarak denenmedi. Aşama 27 (biyometrik) ile ilgili notlar (§3.2, §6, §7.1 ve Sık Sorulan Sorular) 2026-10-03'te ana ağaçtaki (henüz commit'lenmemiş) biyometrik düzeltmesinin kaynağıyla (`lib/services/biometric_auth_service.dart`, `lib/ui/pages/dashboard_page.dart`, `lib/ui/widgets/biometric_prompt_dialog.dart`, `lib/ui/pages/auth/auth_gate.dart`, `lib/ui/widgets/settings/appearance_cards.dart`, `lib/ui/widgets/settings/child_lock_card.dart`, `lib/services/automation_state.dart`; derlemeyi etkileyen `pubspec.yaml` ve `pubspec.lock`) ve `local_auth_android` 1.0.56 eklenti kaynağıyla karşılaştırıldı; telefonda denenmedi.

**Kabuk:** Bütün komutlar **Windows PowerShell** içindir ve **tek satırdır** (satır devamı yok). Tek istisna §4.2'deki `bash` etiketli bloktur: o blok canlı sunucuda (Linux) çalışır. Kod bloklarını satır satır kopyalayın. `<cihaz kimliği>`, `[AVD adı]`, `[PID]` gibi yer tutucuları, parantezleriyle birlikte kendi değerinizle değiştirin; PowerShell `<` işaretini olduğu gibi kabul etmez. `curl` yerine `curl.exe` yazın: Windows PowerShell 5.1'de `curl`, `Invoke-WebRequest`'in takma adıdır ve `-X` gibi bayrakları tanımaz.

**Tarih:** 2026-10-03  
**Sürüm:** 1.3  

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

**Ortam kuralı (gerçek pano):** QA yığını yalnız `127.0.0.1`'e açıktır: yerel ağdaki gerçek pano QA'nın MQTT broker'ına ve REST API'sine ulaşamaz. Firmware de buluta yalnız ISRG (Let's Encrypt) köklü TLS ile bağlanır; QA broker'ında TLS yoktur. Bu yüzden **gerçek pano + bulut** adımları yalnız **canlı sunucu dağıtıldıktan sonra** yapılabilir (canlı dağıtım henüz yapılmadı, §4.1). Kural sihirbazın Adım 6 "Buluta Bağla ve Bekle" adımını ve ondan sonraki her şeyi kapsar. Kontrol listesinde bunlar: Aşama 5–7 uçtan uca (6.1'in Adım 6 kısmı ve 6.3 dahil), 8.x, 9.3, 16.9, 17–18, 23.x (23.2 yalnız burada), 29, 31.x ve 33'ün gerçek pano yoludur (33'te panonun web sayfasındaki "Kanal Ayarları" cihaz anahtarı ister). Bugün gerçek panoyla yapılabilenler:

- 4.5–4.8: fabrika aracı. QA'ya kayıt yalnız aracı denemek içindir.
- 16.1–16.8 ve 16.10–16.11: kurulum ağı, sunucusuz. Ağ süreli açılır (§5.4): 16.5'ten sonra seri konsolda `AP ON` gerekir. Üç istisna: 16.5'in son cümlesi (panonun uygulamada çevrimiçi görünmesi) ve 16.11(b)'nin "bulut normale dönmeli" kontrolü canlı dağıtımdan sonra yapılır; 16.7'nin anahtarlı yolu DOĞRULANMADI (test kişisinde cihaz anahtarı yok; "yapılamadı" işaretlenir).
- 16.9 servis sorumlusu ve sunucu gerektirir; gerçek panoyla canlı dağıtımdan sonra yapılır. Madde Adım 5'tir ve kendi başına buluta ihtiyaç duymaz; ama sihirbaza Adım 2–4'te panonun sunucuda sahiplenilmesiyle gelinir.

Hangi aşamanın nerede yapılacağı: §6 Test Haritası.

---

## 2. Seçenek A: Yerel QA Yığını (Önerilen)

### 2.1 Ön Koşullar

Makinenizde şunlar bulunmalıdır:

- **Node.js** ≥ 20.11 (yığın Node 24'te geliştirildi)
- **Flutter** SDK (emülatör, USB'li telefon, Windows ya da Chrome için)
- **Android SDK** ve bir emülatör (AVD) ya da USB hata ayıklaması açık bir Android telefon; SDK sürümleri Flutter'ın varsayılanlarıdır
- Windows masaüstü uygulaması için Visual Studio'nun "Desktop development with C++" iş yükü (Türkçe kurulumda C++ ile masaüstü geliştirme)
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

Yeni bir deneme turuna **temiz** başlamak için önce `reset` çalıştırın. `reset` önceki turun verisini siler: veritabanı, sırlar, hesaplar, simülatör kayıtları.

```powershell
cd G:\site\ev_otomasyon\tools\qa_stack
node run.js reset
node run.js up --stage2
```

- **Android emülatörü** için yukarıdaki `up --stage2` yeterlidir (uygulamaya bildirilen MQTT adresi `10.0.2.2`).
- **Windows masaüstü** ya da **USB'li gerçek telefon** (`adb reverse`) kullanacaksanız `up` satırını şöyle yazın: `node run.js up --stage2 --public-host 127.0.0.1`
- **Emülatör ile Windows ya da USB'li telefon birlikte:** yığın uygulamalara tek bir MQTT adresi bildirir. Yığını `--public-host 127.0.0.1` ile başlatın ve emülatör için `adb -s emulator-5554 reverse tcp:1883 tcp:1883` çalıştırın; yoksa emülatördeki uygulama "Canlı izleme kesik" kalır. İki Android cihaz bağlıyken her `adb` komutuna `-s <kimlik>` ekleyin (kimlikler: `adb devices`). En kolayı ikinci cihaz olarak Chrome'u kullanmaktır (§3.4; MQTT kullanmaz).
- Yığın zaten çalışıyorsa `up` yeni seçenekleri uygulamaz ("QA yigini zaten calisiyor." der): önce `node run.js down`.
- **Tekrarlanan `up --stage2` güvenlidir.** Tohumlama idempotenttir; hiçbir şeyi çoğaltmaz (özet satırı `0 yapildi, 17 atlandi`). Yalnız tohumdan sapanı onarır: süresi dolan servis PIN'ini ve 24 saatlik misafiri yeniler. Uygulamada değiştirdiğiniz tohum hesap parolalarını da `accounts.json` değerine **geri alır**. Değiştirdiğiniz parolayı korumak için `--no-seed` ekleyin.
- **Her `up` JWT sırrını yeniler.** Uygulamanın oturumu refresh token ile kendiliğinden sürer. Servis PIN oturumu ve yenilemesi başarısız olan oturumlar ise girişe döner (§8). Sırları korumak için `--keep-secrets` ekleyin.

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
  Tohumlama      tamam  (20/20 adim: 17 yapildi, 0 atlandi (zaten var), 3 dogrulandi)

Emulator (Android) icin:
  flutter run -d emulator-5554 --dart-define=API_BASE_URL=http://10.0.2.2:5000/api --dart-define=MQTT_TLS=false --dart-define=DEVICE_AP_HOST=10.0.2.2:8081
…
```

Aynı yığında sonraki `up --stage2`'lerde tohum satırı `tamam  (20/20 adim: 0 yapildi, 17 atlandi (zaten var), 3 dogrulandi)` olur. Tohum bir parolayı geri aldıysa altında `Tohumlama notu: … geri alindi` satırı çıkar.

Çıkış kodları:

- `0` = READY.
- `2` = DEGRADED: bir bileşen ya da tohum adımı başarısız. Satırlarda `BASLATILAMADI`, `BASARISIZ` ya da `UYARI` arayın.
- `1` = başlatılamadı.

Çıkış kodunu görmek için komuttan hemen sonra `$LASTEXITCODE` yazın. Süre: ilk `up --stage2` (initdb + migration + tohumlama) makine yüküne göre ~20 sn–2 dk sürer; sonrakiler ~5–15 sn.

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

`smoke` (23 uçtan uca denetim) son satırı: `23/23 denetim gecti.` Bir satır `HATA` ise **[8. Sorun Giderme](#8-sorun-giderme)** → "`smoke` 23/23 değil" bölümüne bakın. `smoke` servis PIN'ini de kullanıp yeniler (§2.3).

### 2.3 Hesaplar, E-postalar ve Loglar

Hesaplar `up --stage2` ile **gerçek REST akışıyla** oluşturulur ve `tools/qa_stack/.runtime/accounts.json`'a yazılır (gitignore'lu; repoya yazılmaz):

```powershell
node run.js accounts
```

Çıktıda: "Wi-Fi (simulator ev agi): QA-Ev-WiFi / [parola]", "CIHAZLAR" (her cihazın `setup_pin=`'i), "KULLANICILAR" (e-posta, **parola**, rol), "SERVIS PIN (home1): …" ve "EV home1: …" / "EV home2: …" satırları. Ekranda parolalar görünür: ekran görüntüsü paylaşmayın.

Servis PIN'i ("QA Daire 1") 2 saat geçerlidir ve tek kullanımlıktır: servis girişi PIN'i tüketir. Bir evin yeni PIN'i, o evin kullanılmamış eski PIN'ini iptal eder.

- `smoke` her çalıştırmada PIN'i kullanıp yenisini üretir.
- `seed` ve `up --stage2`, PIN kullanılmışsa, iptal edilmişse ya da 15 dk'dan az kalmışsa yenisini üretir.
- Güncel PIN'i her zaman `node run.js accounts`'tan alın.
- Uygulamada ev sahibi olarak ürettiğiniz PIN'i kullanmadan önce `smoke`, `seed` ya da `up --stage2` çalıştırmayın: yeni PIN üretirlerse sizinkini iptal ederler.

**Hesap tablosu:**

| Anahtar | E-posta | Rol | Not |
|---------|---------|-----|------|
| `super` | `qa.super@example.com` | Süper Yönetici | |
| `staff` | `qa.servis@example.com` | Servis Sorumlusu | Süper yönetici tarafından **parolayla** açılır. QA tohumu zorunlu şifre değişimini kapatır: ilk girişte doğrudan "Yetkili Servis Konsolu" açılır ("Şifrenizi Değiştirin" sayfası **çıkmaz**). "QA Daire 1"de servis üyeliği vardır |
| `owner1` | `qa.sahip1@example.com` | Ev Sahibi | "QA Daire 1" (pano `AHBU-S3-0A0002` = simülatör `home1`), 4 zamanlı kural, servis PIN'i |
| `owner2` | `qa.sahip2@example.com` | Ev Sahibi | "QA Daire 2 (baska ev)" (pano `AHBU-S3-0A0004`, simülatörsüz): başka evin verisine erişim (IDOR) denemeleri |
| `resident` | `qa.aile@example.com` | Aile Üyesi | "QA Daire 1" |
| `guest_valid` | `qa.misafir@example.com` | Süreli Misafir (24 saat) | "QA Daire 1" |
| `guest_expired` | `qa.misafir.eski@example.com` | Süresi Dolmuş Misafir | "QA Daire 1"; girişte "Erişim süreniz doldu" ekranı |

**Tohum zamanlı kuralları kendiliğinden çalışır** (evin saat diliminde): "Aksam lambasi" her gün 19:30'da kanal 5'i ("Salon Aydınlatma") açar, "Gece kapat" 23:00'te kapatır, "Hafta ici panjur kapat" hafta içi 21:00'de panjur 1'i kapatır. Akşam deneyen kişi kendiliğinden yanan lambayı ya da kapanan panjuru hata sanabilir; gerekirse kuralı uygulamada anahtarla geçici kapatın (kontrol listesi 25.5) ve geri açın. `qa.misafir` yalnız son `seed` / `up --stage2`'den itibaren 24 saat geçerlidir (`--no-seed` yenilemez): tur bir günü aşarsa `node run.js seed`.

**Zorunlu şifre değişimini denemek için** (kontrol listesi 26.2) yeni bir hesap açın. Tohumlanan `qa.servis` hesabıyla bu sayfa çıkmaz.

1. `qa.super@example.com` ile girin.
2. Konsolda "Servis Sorumluları Yönetimi"ne (ya da ☰ → "Servis Sorumluları") girin.
3. "Servis Yönetimi" sayfasında "Hesap Ekle"ye basın.
4. "Hesap türü"nü seçin: "Servis sorumlusu" ya da "Müşteri".
5. "Geçici parola" alanını (altındaki yardım metni: "İsteğe bağlı. Boş bırakırsanız kullanıcıya hesap etkinleştirme e-postası gider (önerilir). En az 10 karakter.") **doldurun** (en az 10 karakter); e-postada `@example.com` kullanın.
6. "Kaydet"e basın.

Bu hesapla ilk girişte "Şifrenizi Değiştirin" sayfası çıkar.

**Tohum hesabının şifresini uygulamada değiştirirseniz** (örn. 26.1) `accounts` eski parolayı göstermeye devam eder. Sonraki `up --stage2` ya da `node run.js seed` bu parolayı `accounts.json` değerine **geri alır**; reset gerekmez. Çıktıda `Tohumlama notu: … geri alindi` (`seed`'de `NOT …`) satırı görünür. Bu yüzden bir sonraki `up`'tan sonra yeni şifreniz geçmez; `accounts`'taki parolayı kullanın. Değiştirdiğiniz şifreyi korumak için yığını yeniden başlatırken tohumu atlayın: `node run.js down`, sonra `node run.js up --stage2 --keep-secrets --no-seed`.

**E-postalar (kodlar, etkinleştirme bağlantıları):** sunucu e-postayı dışarı göndermez; SMTP çukuruna düşer:

```powershell
node run.js mails
node run.js mails 1
```

- `node run.js mails` en yeni (en çok) 30 e-postayı `N. [zaman]  To: …  Subject: …` biçiminde numaralı listeler (1 = en yeni; `[zaman]` 13 haneli epoch milisaniyedir). Türkçe konu listede **kodlu ve kısaltılmış** görünür (`Subject: =?UTF-8?Q?AHBU_Ak=C4=B1ll=C4=B1_Ev_-_…?=`): e-postayı `To:` adresinden ve sırasından tanıyın.
- `node run.js mails 1` 1 numaralı (en yeni) e-postanın **ham gövdesini** yazdırır. `mails 10` "son 10 e-posta" değil, 10 numaralı e-postadır; yoksa `Boyle bir e-posta yok: 10 …` yazar ve çıkış kodu `1` olur.
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
| `home1` | `AHBU-S3-0A0002` | 8082 | `10.0.2.2:8082` | **Provizyonlu**, bulutta | "QA Daire 1" (lamba/panjur, LAN modu; Aşama 33'te yerleşim değişir ve geri alınır) |
| `stock2` | `AHBU-S3-0A0003` | 8083 | `10.0.2.2:8083` | Provizyonsuz, 16 röle | Yalnız `up --stage2 --devices 3` |
| (`own2`) | `AHBU-S3-0A0004` | — | — | Simülatörsüz | "QA Daire 2 (baska ev)" |

`AHBU-S3-0A0003` simülatörü olmasa da envanterde stokta kayıtlıdır: eşlenebilir ama pano çevrimdışı görünür. Kurulum PIN'i: `node run.js accounts` → `stock2 … setup_pin=`. Simülatörlerin tanıdığı ev Wi-Fi'si `QA-Ev-WiFi`'dir (parola `accounts` çıktısında). Simülatör `10.0.2.2` ve `localhost` adlarını kendi içinde `127.0.0.1`'e eşler.

**Stoktaki iki boş pano** (`AHBU-S3-0A0001` ve `AHBU-S3-0A0003`) eşlenince stoktan çıkar. Hangi aşamanın hangisini kullandığını kontrol listesindeki stok panosu kullanım sırası belirler; rehberdeki senaryolar da bu panoları tüketir (§6). Stoğu yenilemek için `node run.js reset` + `node run.js up --stage2`.

Çalışan yığına 3. simülatörü (`stock2`) eklemek için önce `node run.js down`, sonra `node run.js up --stage2 --devices 3 --keep-secrets --no-seed` çalıştırın (`--no-seed` tohumun yeniden çalışıp uygulamada değiştirdiğiniz tohum parolalarını geri almasını önler). Önceki `up`'ta `--public-host 127.0.0.1` kullandıysanız onu da ekleyin.

### 2.5 QA Kontrol Uçları

Simülatör, yalnız `127.0.0.1`'den erişilen test uçları açar (firmware'de yoktur):

| Uç | İşlev | PowerShell komutu |
|-------|-------|--------|
| `GET /__sim/state` | İç durum (`relays`, `shutters`, `child_lock`, `mqtt`, `wifi`, `provisioned`, `violation_count`) | `Invoke-RestMethod http://127.0.0.1:8082/__sim/state` |
| `POST /__sim/offline` / `POST /__sim/online` | Ani bağlantı kaybı (LWT `offline`) / geri gelme | `curl.exe -s -X POST http://127.0.0.1:8082/__sim/offline` |
| `POST /__sim/di/{n}/press` | n numaralı duvar girişine basış (varsayılan 150 ms) | `curl.exe -s -X POST http://127.0.0.1:8082/__sim/di/1/press` |
| `POST /__sim/slow` `{delay_ms, drop}` / `DELETE /__sim/slow` | Komut gecikmesi ya da sessizce düşürme / kaldırma | `Invoke-RestMethod -Method Post -Uri http://127.0.0.1:8082/__sim/slow -ContentType 'application/json' -Body '{"delay_ms":500}'` |
| `POST /__sim/power-cycle` | Güç kesintisi + yeniden açılış | `curl.exe -s -X POST http://127.0.0.1:8082/__sim/power-cycle` |
| `POST /__sim/ap` `{open}` | Kurulum/servis AP penceresini aç/kapat (simülatör firmware'in AP penceresini taklit eder: `new1`'in ağı `up`'tan sonra yaklaşık en çok 30 dk açık, sonra 15 dk kapalıdır; durum: `(Invoke-RestMethod http://127.0.0.1:8081/__sim/state).wifi.ap_active`; Adım 5'ten önce `False` ise açın) | `Invoke-RestMethod -Method Post -Uri http://127.0.0.1:8081/__sim/ap -ContentType 'application/json' -Body '{"open":true}'` |
| `POST /__sim/ext` `{present, address, baud, channels}` | Ek modül donanımı: var/yok, Modbus adresi, baud, kanal sayısı. Yalnız donanım modelidir ve röle sayısını DEĞİŞTİRMEZ (16 röle için ayrıca `POST /api/config` ile `ext_module_enabled`: kontrol listesi 33.7) | `Invoke-RestMethod -Method Post -Uri http://127.0.0.1:8082/__sim/ext -ContentType 'application/json' -Body '{"present":true,"channels":8}'` |

Kısa yollar: `(Invoke-RestMethod http://127.0.0.1:8082/__sim/state).relays | Format-Table id,name,type,state` ve `(Invoke-RestMethod http://127.0.0.1:8082/__sim/state).violation_count` (panjur emniyet ihlali sayısı; 0 olmalı). Gecikmeyi kaldırmak: `Invoke-RestMethod -Method Delete -Uri http://127.0.0.1:8082/__sim/slow`.

Yerleşimi (röle türü ve adı, panjur çifti, ek modül) simülatörde değiştirmek için panonun yerel API'si `POST /api/config` kullanılır: bir QA ucu değildir (firmware'de vardır; panonun web sayfasındaki "Kanal Ayarları" kaydı aynı isteği gönderir) ve `X-Device-Key` ister (anahtar: `node run.js accounts` → `home1` satırının altındaki `X-Device-Key=`). Örnek komutlar kontrol listesi Aşama 33'tedir; diziler sıra tabanlıdır ve `{}` o sıradaki kaydı değiştirmez.

### 2.6 Yığını Kapatma

```powershell
node run.js down
node run.js reset
```

- `down`: temiz kapatır; veritabanı, sırlar ve hesaplar korunur. Sonraki `up --stage2` güvenlidir: tohumu yeniden denetler ama hiçbir şeyi çoğaltmaz (§2.2). Kaldığınız yerden sürdürmek için `node run.js up --stage2 --keep-secrets --no-seed` kullanın. `--keep-secrets` sırları ve oturumları korur. `--no-seed` tohumu atlar, böylece uygulamada değiştirdiğiniz tohum parolaları geri alınmaz. Ama `--no-seed` ile süresi dolan servis PIN'i ve 24 saatlik misafir de yenilenmez; gerekirse sonra `node run.js seed` çalıştırın.
- `reset`: kapatır ve `.runtime`'ı siler (veritabanı, sırlar, hesaplar, simülatör kayıtları); sonra `node run.js up --stage2` ile temiz başlarsınız.

---

## 3. Uygulamayı Çalıştırma

Bütün `flutter run` komutları **debug** derleme içindir: release derleme (`flutter build … --release` ya da `flutter run --release`) `--dart-define` değerlerini yok sayar ve her zaman canlı sunucuya gider (§7).

### 3.1 Android Emülatörü

**En uygun ortam:** Maddelerin çoğu için önerilir (yığın `node run.js up --stage2` ile başlatılmış olmalı). Emülatörü Windows uygulaması ya da USB'li telefonla birlikte kullanacaksanız §2.2'deki "Emülatör ile Windows ya da USB'li telefon birlikte" maddesini uygulayın.

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
- Android'in ağ güvenlik yapılandırması (NSC) düz (cleartext) HTTP'yi yalnız Java/Kotlin ağ yığınında kısıtlar; uygulamanın HTTP istemcisi (dart:io) NSC'ye tabi değildir. Debug yapılandırması ayrıca tüm düz HTTP'ye izin verir (`android/app/src/debug/res/xml/network_security_config.xml`).

---

### 3.2 Gerçek Android Telefon (USB)

**Ön Koşul:** USB veri kablosu, ADB sürücüsü, telefonda Geliştirici seçenekleri → USB hata ayıklama açık. Yığın `--public-host 127.0.0.1` ile başlatılmalı (turun başında; turun ortasında aşağıdaki `down` + `up` satırına `--keep-secrets --no-seed` ekleyin, yoksa tohum parolaları geri alınır, kullanılmamış servis PIN'iniz iptal olabilir ve servis PIN oturumları düşer). Emülatör de açıksa her `adb` komutuna `-s <cihaz kimliği>` ekleyin (`adb devices`; §2.2).

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
- Android NSC uygulamanın HTTP istemcisini (dart:io) kısıtlamaz. Bu yüzden release derlemede de LAN doğrudan modun (ham IP, örn. `192.168.1.40`) ve pano kurulum ağının düz HTTP ile çalışması beklenir; bu cihazda DOĞRULANMADI. Pano adresini uygulama kodu yerel adreslerle sınırlar (`isAllowedDeviceHost`: `10.x`, `127.x`, `172.16–31.x`, `192.168.x`, `169.254.x`, `100.64–127.x`, `localhost`, `*.local`).
- Bu derleme kurulum ağı adresi olarak simülatörü (`127.0.0.1:8081`) kullanır: **gerçek panoya değil simülatöre gider** ve Android süreç bağlama çalışmaz. Kontrol listesi 16.11 bu derlemeyle sınanamaz.
- Biyometrik denemeler (kontrol listesi Aşama 27) telefonda ekran kilidi ve kayıtlı parmak izi ister. Telefonda eski bir kurulum kalmış olabilir; üç derleme vardır: "[etiket] Kullanılsın mı?" penceresinin açıklamasında "(200 ms)" yazıyorsa kurulum eskidir, bu aşamanın beklentileri geçersizdir; "hızlıca" yazıyorsa ayrıca sistem doğrulama penceresinin başlığına bakın (Türkçe "Kimlik doğrulama" = düzeltmeli; İngilizce "Authentication required" = `30891ef` sonrası ama düzeltmesiz, nedene özel iletiler yok). Eski ve düzeltmesiz derlemede beklentiler geçersizdir; güncel ağaçtan yeniden derleyip kurun (§6 "Biyometrik Giriş İstemi: Ne Beklemeli").

**Gerçek panonun kurulum ağı için derleme (kontrol listesi Aşama 16):** yalnız `DEVICE_AP_HOST`'u **vermeyin**. Adres varsayılan `192.168.4.1` kalır.

```powershell
cd G:\site\ev_otomasyon
flutter run -d <cihaz kimliği> --dart-define=API_BASE_URL=http://127.0.0.1:5000/api --dart-define=MQTT_TLS=false
```

`API_BASE_URL` ve `MQTT_TLS` yalnız aynı derlemeyle QA'ya giriş yapacaksanız gerekir (yığın ve yukarıdaki `adb reverse tcp:5000` / `tcp:1883` satırları). Kurulum ağı maddeleri (16.1–16.8, 16.10–16.11) girişsiz de yapılır: giriş ekranında "Pano Wi-Fi Kurulumu (İnternet Gerekmez)". Gerçek pano QA sunucusuna bağlanamaz (§1 ortam kuralı).

---

### 3.3 Windows Masaüstü

**Ön Koşul:** Windows 10+, Visual Studio "Desktop development with C++" iş yükü (§2.1). Windows'ta MQTT ham TCP ile `MQTT_PUBLIC_HOST`'a bağlanır: yığın `--public-host 127.0.0.1` ile başlatılmalı (varsayılan `10.0.2.2` Windows'tan erişilemez; turun ortasında aşağıdaki `down` + `up` satırına `--keep-secrets --no-seed` ekleyin, §3.2). Emülatör de kullanacaksanız ona `adb -s emulator-5554 reverse tcp:1883 tcp:1883` gerekir (§2.2).

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

1. Yeni sunucu kodu dağıtılmış ve **migration'ların tamamı** (001–031) uygulanmış olmalı. Kontrol komutu salt okunurdur ve `MIGRATE_CONFIRM` istemez. Komutu canlı sunucuda, sunucu kodunun `server/` klasöründe çalıştırın (klasör: `docs/DEPLOY_RUNBOOK.md` §5).

   ```bash
   # sunucuda, bash
   node scripts/migrate.js --status
   ```

   Beklenen: ilk satır `Hedef: …` hedef veritabanını gösterir (kullanıcı@sunucu:port/veritabanı); bunun ev otomasyonu veritabanı olduğunu doğrulayın, kapı sistemininki değil. Ardından dosyalar `[uygulandi]` olarak listelenir. Eski şema `--baseline 17` ile işaretlendiyse ilk dosyalar `[baseline ]` görünür. Hiçbir satır `[bekliyor ]` ya da `!! ICERIK DEGISMIS` olmamalı. Son dosya `031_endpoint_layout_sync.sql` olur (Aşama 33 / WP-L için gerekir: `devices.reported_layout`) ve özet `Ozet: 31 uygulanmis, 0 bekliyor.` der.
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

İlk satır yalnız QA sunucusu içindir; canlıda atlayın (araç varsayılan olarak canlı adrese gider). Araç ayrıca `ev_otomasyon_sistemi.bat` ile de açılır.

**QA'ya kayıt yalnız aracı denemek içindir:** kayıt, etiket, flash ve USB provizyonu (kontrol listesi 4.5–4.8). QA'ya kaydedilen kart QA sunucusuna bağlanamaz (§1 ortam kuralı). Kartla bulut adımları canlı dağıtımdan sonra yapılır; kart o zaman canlı sunucuya kaydedilip yeniden provizyonlanır. Araç kartta eski anahtar bulursa "Kartta Eski Anahtar Var" penceresinde anahtarı sıfırlayıp (`RESETKEY`) yeniden provizyon yapmayı önerir; bu yol kartta denenmedi.

1. "🔐 Sunucuya Giriş" → "🔐 Süper Kullanıcı Girişi" ("Sunucu adresi:", "E-posta:", "Parola:") → "✓ Giriş Yap" (araç yalnız süper yönetici hesabıyla çalışır).
2. Kartı USB-C veri kablosuyla bağlayın; "⚡ 1. Firmware Yükleyici (Flasher)" sekmesinde "COM Port:" seçin ("🔄 Portları Yenile").
3. "🏷️ 2. Karekod Üret & Etiket Bas (Envanter)" sekmesinde "📡 Karttan MAC Oku" → UID ve kurulum PIN'i dolar → "☁️ SUNUCU ENVANTERİNE KAYDET & KAREKOD ÜRET" → "Cihaz Envantere Eklendi!".
4. "💾 Etiketi Kaydet (PNG)" / "🖨️ Yazdır (Barkod / Termal)".
5. Aynı oturumda 1. sekmede "🚀 Bizim Geliştirdiğimiz Yazılım (Otomatik Seçili)" işaretliyken "⚡ FİRMWARE'İ KARTA YÜKLE (FLASH)" (30–60 sn; USB'yi çıkarmayın).

**Elle (yedek):**

```powershell
cd G:\site\ev_otomasyon\ev_otomasyon_servis_yazilimi\waveshare_s3_demo\firmware_releases\v1.1.0
esptool --chip esp32s3 --port COM3 --baud 460800 write_flash 0x0 firmware_combined_0x0.bin
```

`COM3` yerine kartın portunu yazın (fabrika aracının "COM Port:" listesinde ya da Windows Aygıt Yöneticisi'nde görünür). `esptool` bulunamazsa aynı satırı `esptool.py …` ya da `python -m esptool …` ile başlatın. Elle yazılan kart **provizyonsuz** kalır: aynı araç oturumunda kayıt (adım 3) varken "📡 3. Cihaz Provizyonu (USB / Wi-Fi)" sekmesinde "🔌 Seri (USB) ile Provizyonla (Önerilen)"ye basın. Kayıt önceki bir oturumdaysa (yerel anahtar sunucudan yalnız bir kez gelir) kartı yeniden kaydetmek gerekir; aynı kartın ikinci kaydı `409` ile reddedilir ve araç çıkış yolunu söyler: önce süper yönetici aracın envanter tablosunda panonun "Stokta" durumundaki kaydını "🗑️ Envanterden Sil" ile siler (cihaz UID'sini yazarak onaylar; daireye bağlanmış kayıt silinemez), sonra kart yeniden kaydedilir.

### 5.3 Provizyonlama (Fabrika Aracı)

Flash bitince ve kayıt (5.2 adım 3) aynı oturumdaysa araç 3. sekmeye geçer ve USB (seri) `FACTORYINIT` provizyonunu **kendiliğinden** başlatır; yerel anahtar ve AP parolası kablosuz ağdan geçmez. Hemen ardından açılan "Başarılı" penceresi "Provizyon USB (seri) üzerinden OTOMATİK başlatıldı" der. Provizyon bu pencere açıkken de sürer; kartı ve kabloyu çıkarmayın. Sonuç alanında sırayla "USB (seri) provizyon başlıyor …", "… FACTORYINIT gönderildi …" ve "✅ USB (seri) provizyon tamamlandı ve doğrulandı …" görünür; üstte "Durum: Provizyon doğrulandı ✔ (USB seri)" ve "Provizyon Tamamlandı" penceresi çıkar. Sonra:

1. Etiketin sağdaki 2. karekodunu telefon kamerasıyla okutup kurulum ağına bağlanmayı deneyin (5.4).
2. Etiketi pano kapağına yapıştırın; 3. sekmede "🧹 Kaydı Bellekten Sil / Yeni Cihaz"; PNG dosyasını silin (PIN ve Wi-Fi parolası içerir).

### 5.4 Kurulum Ağı

Provizyonlu kart kendi Wi-Fi erişim noktasını (WPA2) açar:

| Öğe | Değer |
|-----|-------|
| **SSID** | `AHBU-<MAC son 6 hex, büyük harf>` (örn. `AHBU-DD8754`) |
| **Parola** | Etikette "AĞ PAROLASI (AP)" satırındaki karta özel değer: 10 karakterlik harf-rakam dizisi (8–32 karakter kabul edilir). Etiketin 2. karekodu telefon kamerasıyla okutulunca tek dokunuşla bağlanır |
| **Frekans** | 2,4 GHz |
| **IP** | Pano: `192.168.4.1` (web arayüzü 80 numaralı port) |

Ağ ne zaman açık (süreli pencere; firmware `ApPolicy`): kurulum ağı sürekli yayında değildir. Ev Wi-Fi'si tanımlı değilken ya da ev Wi-Fi'si 3 dk koptuğunda 10 dk'lık bir pencere açılır; telefon bağlıyken pencere 2'şer dk uzar ve açılıştan sonra en çok 30 dk açık kalır. Pencere kapanınca (kesinti ya da tanımsız ev Wi-Fi'si sürüyorsa) 15 dk boyunca yeniden açılmaz. Ev Wi-Fi'sine bağlanan (kontrol listesi 16.5) pano bağlantı 30 sn kararlı kalınca ağı kapatır ve kendiliğinden açmaz: yeniden açmak için ev Wi-Fi'sini 3 dk kesin ya da seri konsolda `AP ON` yazın (10 dk; §5.5). Telefon bu ağa bağlanınca uygulamada ekran **kendiliğinden açılmaz**: giriş ekranında "Pano Wi-Fi Kurulumu (İnternet Gerekmez)" ya da servis sihirbazı Adım 5 ile sihirbazı elle açın (kontrol listesi Aşama 16).

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
3. **Seri terminal ve kurulum ağını açma:** USB-C bağlıyken 115200 baud bir seri terminal açın (fabrika aracı ya da başka bir program portu tutuyorsa onu kapatın); örnek, pyserial kuruluysa: `python -m serial.tools.miniterm COM3 115200` (`COM3` yerine kartın portu). `AP` yazıp Enter'a basın: "AP: ACIK" ya da "AP: KAPALI". KAPALI ise `AP ON` yazın: "Servis AP'si istendi (10 dk): SSID …" (§5.4; kontrol listesi Aşama 16'da 16.5'ten sonra gerekir).
4. **Provizyon durumu:** seri konsola `STATUS` yazın → "Yerel anahtar (local_key): tanimli" (provizyonsuz kartta "YOK (provizyonsuz cihaz)").
5. **Kurulum ağı:** telefonun Wi-Fi listesinde `AHBU-XXXXXX` görünmeli (5.4); pencere kapalıysa görünmez: 3. madde.

---

## 6. Ne Denemeli: Test Haritası

`EVOTOMASYON_CANLI_TEST_KONTROL_LISTESI.md` (saha test belgesi) aşamalarının ortamlara eşlenmesi. İki sütun §1'deki ortam kuralına göre ayrılır:

- **Bugün:** yerel QA yığını (§2) ve ona bağlanan emülatör, Windows, Chrome ya da USB'li gerçek telefon (§3). Gerçek panoyla yalnız 4.5–4.8 ve Aşama 16 (16.9 hariç).
- **Canlı dağıtımdan sonra:** canlı sunucu (§4) ve gerçek pano + bulut adımları.

| Aşama | Başlık | Bugün | Canlı dağıtımdan sonra | Gereken donanım / not |
|-------|--------|-------|-----------|-------|
| **1** | Süper Kullanıcı Girişi & Konsol | QA | Canlı | — |
| **2** | Servis Sorumlusu Tanımlama | QA | Canlı | — |
| **3** | Servis Sorumlusunu Etkinleştirme & Konsol | QA | Canlı | — |
| **4** | Daire Sahibi (Müşteri) | QA | Canlı | — |
| **4.5** | Fabrika aracı: kayıt, etiket, flash, provizyon | Gerçek pano + QA sunucusu (yalnız aracı denemek için, §5.2) | Gerçek pano + canlı sunucu | Windows PC, USB-C veri kablosu |
| **5** | Sihirbaz Adım 1–4 (eşleme) | QA (`new1`) | Gerçek pano + canlı (Aşama 5–7 uçtan uca) | Karekod için gerçek telefon |
| **6** | Sihirbaz Adım 5, 6, 8 (Wi-Fi, bulut, panjur) | QA (`new1`; emülatörde Adım 6 DOĞRULANMADI) | Gerçek pano + canlı | Gerçek pano + gerçek Android telefon |
| **7** | Sihirbaz Adım 7, 9, 10 (röle, buton, teslim) | QA (`new1`) | Gerçek pano + canlı | Röle sesi ve lamba için gerçek pano |
| **8** | Ev sahibinin paneli | QA (`home1`) | Gerçek pano + canlı | — |
| **9** | Süper yönetici takip & Sistem Doktoru | QA | Canlı; 9.3 gerçek panolu daireyle | — |
| **10** | Servis konsolu & saha araçları | QA | Canlı | — |
| **11** | Dairesi olmayan kullanıcı | QA | Canlı | 11.3 karekod için gerçek telefon (QA'ya USB ile, §3.2) |
| **12** | Menü & panel izolasyonu | QA | Canlı | — |
| **13** | Sihirbazda karekod & müşteri kodu | QA | Canlı | 13.2 için gerçek telefon (kamera) |
| **14** | Acil sıfırlama & pano değişimi | QA (tur sonunda, Aşama 33'ten sonra) | Canlı | Kamera için gerçek telefon |
| **15** | Tema | Her ortam | Her ortam | — |
| **16** | Pano Wi-Fi kurulum ağı | Gerçek pano: 16.1–16.8, 16.10–16.11 (sunucusuz; kurulum ağı süreli açılır, 16.5'ten sonra `AP ON`: §5.4–5.5; 16.5 son cümle ve 16.11(b) hariç; 16.7 anahtarlı yol DOĞRULANMADI) | 16.9 (servis sorumlusu + sunucu); 16.5 son cümle ve 16.11(b) | Gerçek pano + gerçek Android telefon; debug derlemede `DEVICE_AP_HOST` verilmez (§3.2); iOS kapsam dışı |
| **17** | Sihirbaz röle/buton/teslim ayrıntıları | QA (`new1`) | Gerçek pano + canlı | — |
| **18** | Devam eden kurulum, mevcut cihazlar, adres | QA | Gerçek pano + canlı | — |
| **19** | Abonelerim & Home Admin | QA | Canlı | — |
| **20** | Süreli misafir | QA | Canlı | 20.4 için gerçek telefon; 20.3 gerçek bekleme ister |
| **21** | Üye yönetimi & rol matrisi | QA | Canlı | İkinci cihaz/hesap |
| **22** | Daire devri | QA | Canlı | İkinci hesap |
| **23** | Çocuk kilidi | QA (`home1`): 23.1, 23.3, 23.4 | Gerçek pano + canlı; 23.2 (iki pano) yalnız burada | 23.4 için gerçek telefon (biyometrik) |
| **24** | Gece huzur bildirimi | QA | Canlı | — |
| **25** | Zamanlı kurallar | QA | Canlı | — |
| **26** | Hesap güvenliği | QA (26.2 yeni açılan hesapla, §2.3) | Canlı | İkinci cihaz |
| **27** | Biyometrik kilit | Gerçek Android telefon (QA'ya USB ile); 27.1'in telefon kodu (SMS) yolu uygulamadan tamamlanamaz (kod ekranda gösterilmez; QA'da API yanıtındaki `debug_code` ile elle denenebilir) | Canlı | Gerçek Android telefon (ekran kilidi + kayıtlı parmak izi); uygulama sürümü: biyometrik düzeltmesini içeren derleme ("Kullanılsın mı?" penceresinde "(200 ms)" yazıyorsa eski kurulum; "hızlıca" yazıyorsa sistem penceresinin başlığı Türkçe "Kimlik doğrulama" olmalı, İngilizce "Authentication required" ise düzeltmesiz derlemedir: aşağıdaki "Biyometrik Giriş İstemi: Ne Beklemeli") |
| **28** | Hesap silme | QA | Canlı | — |
| **29** | Yerel ağ (LAN) doğrudan mod | QA (`home1`) | Gerçek pano + canlı (telefon ve pano aynı ev Wi-Fi'sinde) | — |
| **30** | Derin bağlantı & karekod yönlendirme | QA: 30.2 ve kopyala-yapıştır yolu ("E-postadaki Bağlantım Var"); 30.3 gerçek telefonla | Canlı: 30.1 bağlantıya dokunma | Gerçek Android telefon |
| **31** | Dayanıklılık | QA | Canlı; gerçek panoyla | İkinci cihaz |
| **32** | Servis PIN'i & yetki sınırları | QA | Canlı | İkinci cihaz |
| **33** | Pano yerleşimi → uç noktalara otomatik eşitleme (WP-L) & uygulamanın sessiz yenilemesi | QA (`home1`; yerleşim `POST /api/config` ile; Aşama 14'ten ÖNCE; 33.8(a) QA'da yapılamaz) | Gerçek pano + canlı (panonun web sayfasındaki "Kanal Ayarları" cihaz anahtarı ister; 33.8(a) yalnız burada ya da sunucuyu kendiniz başlatıyorsanız) | Uygulama sürümü: WP-L istemci yenilemesi içeren (şimdilik yalnız dev kopya `G:\site\ev_otomasyon_dev`, ana ağaçta yok; yoksa, Chrome'da ya da "Canlı izleme kesik" iken "Yenile"); ek modül maddesi `home1`'in ek modül ayarıyla yapılır, stok panosu kullanılmaz |

QA'ya bağlanan emülatör, Windows ve web şunları yapamaz: gerçek radyo ve elektrik, kamera/karekod, biyometrik, derin bağlantıya dokunma, iOS. Kamera/karekod ve biyometrik, USB'li gerçek telefonu QA'ya bağlayarak yapılabilir (§3.2). Gerçek panonun buluta bağlanması ise QA'da hiç yapılamaz (§1 ortam kuralı).

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
   - "Süper Yönetici Konsolu" açılır (üst çubuk başlığı; çok dar ekranda ya da büyük yazı ölçeğinde "Süper Yönetici" diye kısalabilir); "Servis Sorumluları", "Pano Envanteri", "Devreye Alınan" sayaçları "—" değil, sayı gösterir.
   - Konsolda altyapı (API/veritabanı/MQTT) satırı yoktur: altyapı sağlığı 1. adımdaki `status` çıktısıdır.

4. **Çıkış:** ☰ → "Güvenli Çıkış Yap" (ya da profil → "Oturumu Kapat") → "Çıkış Yapılsın mı?" → "Evet, Çıkış Yap".

### Servis Kurulum Senaryosu (30–45 dakika)

**Amaç:** 10 adımlı servis kurulum sihirbazını simülatör `new1` (`AHBU-S3-0A0001`, provizyonsuz) ile uçtan uca denemek. Simülatör provizyonsuz başlar; Adım 5'te önce ilk hazırlık yapılır (8. madde).

**Kontrol listesiyle çakışma:** bu senaryo kontrol listesi Aşama 5–7'nin kısa yoludur ve aynı stok panoyu kullanır. Pano eşlenince stoktan çıkar (§2.4). Kontrol listesini izliyorsanız senaryoyu ayrıca yapmayın. İkisini de yapacaksanız arada `node run.js reset` + `node run.js up --stage2` çalıştırın.

1. `node run.js accounts` → `new1 … setup_pin=` değerini ve "Wi-Fi (simulator ev agi)" parolasını not edin.
2. Emülatörde `qa.servis@example.com` ile girin (parola: `node run.js accounts`). Doğrudan "Yetkili Servis Konsolu" açılır; QA tohumu zorunlu şifre değişimini kapatır (§2.3).
3. Konsol → "Devreye Alma (Servis Modu)" → "Servis Paneli" → "Yeni Kurulum Başlat".
4. **Adım 1 "Hazırlık":** sayfa açılınca oturum ve sunucu kendiliğinden doğrulanır ("Doğrulandı" rozeti, "Oturumunuz geçerli ve sunucuya ulaşıldı."); "Bağlantıyı Doğrula" düğmesi yalnız doğrulama başarısız olduysa ya da henüz bitmediyse görünür → "Devam".
5. **Adım 2 "Cihazı Tanı":** "Karekodu okutamıyorum: elle yazacağım" → "Cihaz seri numarası" `AHBU-S3-0A0001`, "Kurulum PIN (6 rakam)" → "Bilgileri Kullan" → "Devam".
6. **Adım 3 "Müşteri":** müşteri e-postası (örn. `musteri1@example.com`) → "Kod Gönder". Kodu bulmak için:
   - `node run.js mails` listesinde `To:` alanı müşteri e-postası olan en yeni satırın numarasını bulun. Konu listede kodlu ve kısaltılmış görünür (§2.3).
   - `node run.js mails <numara>` ile gövdede "Onay kodunuz:" ifadesinden sonraki 6 haneli kodu okuyun. Satır sonundaki `=` yalnız satır bölmesidir.
   - Kodu "6 haneli kod" alanına (yardım metni "Müşterinin söylediği kod"; alan "Kod Gönder"den sonra görünür) yazın → "Devam".
7. **Adım 4 "Daireye Bağla":** "Daireye Bağla" → "Evet, Bağla" → "Müşteri için yeni hesap açıldı; etkinleştirme e-postası gönderildi." → "Devam".
8. **Adım 5 "Wi-Fi Kurulumu":** Önce simülatörün kurulum ağı penceresini denetleyin: `new1`'in ağı `up`'tan sonra yaklaşık en çok 30 dk açık kalır, sonra 15 dk kapalıdır; Aşama 1–5 bu süreyi aşabilir ve pencere kapalıyken tarama/yükleme anahtarsız yolda reddedilir (401). `(Invoke-RestMethod http://127.0.0.1:8081/__sim/state).wifi.ap_active` → `False` ise: `Invoke-RestMethod -Method Post -Uri http://127.0.0.1:8081/__sim/ap -ContentType 'application/json' -Body '{"open":true}'` (AP 10 dk açılır). Sonra:
   1. "Bağlandım: Panoyu Kontrol Et"e basın. `new1` provizyonsuz olduğu için önce "Pano ilk kez hazırlanacak" kartı çıkar.
   2. "Kurulum ağı parolası" alanına 8–32 karakterlik bir değer yazın: QA'da kendi seçtiğiniz bir değer, gerçek panoda etiketteki "AĞ PAROLASI (AP)". Kart "Cihaz anahtarı bellekte yok" derse önce "Anahtarı Sunucudan Al (internet gerekir)"e basın.
   3. "Panoyu Hazırla"ya basın. "Pano hazırlandı. …" iletisinden birkaç saniye sonra yeniden "Bağlandım: Panoyu Kontrol Et"e basın.
   4. "2) Müşterinin ev Wi-Fi bilgisi" bölümünde ağ listesi kendiliğinden taranır (gerekirse "Ağları Tara").
   5. Listeden `QA-Ev-WiFi`'yi seçin, parolasını yazın → "Yeni Wi-Fi Şifresini Panoya Yükle".
   6. "Pano ev Wi-Fi ağına bağlandı …" iletisi çıkınca "Devam".
9. **Adım 6 "Bulut Bağlantısı":** "Pano IP adresi" alanına `10.0.2.2:8081` yazın → "Panoya Bağlan" → "Buluta Bağla ve Bekle" → "Çevrimiçi". (Emülatörde bu adım çalıştırılarak denenmedi: DOĞRULANMADI.)
10. **Adım 7 "Röle Testi":** liste kendiliğinden yüklenir (yüklenmezse "Röleleri Listele" düğmesi çıkar) → her röle "Aç" / "Kapat" → "Evet, çalıştı" (simülatörde gözle değil `(Invoke-RestMethod http://127.0.0.1:8081/__sim/state).relays` ile doğrulayın).
11. **Adım 8 "Panjur Testi ve Kalibrasyon":** liste kendiliğinden yüklenir (yüklenmezse "Panjurları Listele" düğmesi çıkar). `new1`'de 2 panjur vardır; her panjur için: "Yukarı" → "Evet, yukarı gitti" → "Süreyi biliyorum: elle gireceğim" → `20` → "Bu Süreyi Kullan" (kronometreli ölçüm de yapılabilir; `up --time-scale N` panjuru hızlandırır). Adım 8, her panjur ya test edilip kaydedilince ya da "Bu panjur kullanılmıyor" → "Evet, kullanılmıyor" işaretlenince geçilir (en az biri gerçekten test edilmiş olmalı); yoksa "Devam" pasif kalır.
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

4. **Durum yenilenir, pano çevrimiçi görünür:** durum şeridindeki hapta "Sistem Hazır" yazar (geniş ekranda üst çubuk hapı "Sistem Hazır • Bulut" der; dar telefonda üst çubukta yalnız ev adının önündeki yeşil nokta kalır; kesin genişlik sınırı DOĞRULANMADI).

### Pano Yerleşimi Değişince: Ne Beklemeli (WP-L)

Servis sorumlusu panonun yerleşimini değiştirdiğinde (çift panjur, lamba ↔ darbe, kanal adı, ek modül) daire ekranının kartlarını elle düzeltmek gerekmez: sunucu köprüsü panonun canlı `state` mesajındaki yerleşimi buluttaki uç noktalara **otomatik eşitler** (`docs/CONTRACTS.md` §2.4b). Deneme adımları: kontrol listesi **Aşama 33**.

- **Ne eşitlenir:** tür ve panjur çifti (pano esastır), kanal sayısı (ek modül dahil) ve panoda verilen kanal adı. Satırlar yerinde güncellendiği için uç nokta kimlikleri korunur (yalnız silinip yeniden açılan satırlar, ör. kapatılıp yeniden açılan ek modülün satırları, yeni kimlik alır). Panonun ASCII fabrika adları ("Salon Aydinlatma") buluta taşınmaz; kullanıcının bulutta verdiği ad, pano tarafı değişmedikçe korunur; pano adı özel bir addan fabrika varsayılanına döndürülürse (ve bulut hâlâ o eski pano adını gösteriyorsa) bulut adı da varsayılana döner. Sınıfı değişen kanalların zamanlı kuralları kapatılır (silinmez, kendiliğinden açılmaz). Yeni panjur satırı 20 sn süreyle başlar (panonun gerçek süresini servis sihirbazı ölçer: kontrol listesi 6.3).
- **Ne kadar sürer:** panjur çifti ve kanal sayısı değişimi ≈ 1 sn (pano ~0,4 sn'de yayınlar); yalnız ad ya da lamba ↔ darbe değişimi panonun bir sonraki 30 sn'lik kalp atışına kalır; ek modül küçülmesinde satırlar, aynı küçülme ≥ 20 sn arayla ikinci kez görülünce silinir (≈ 30 sn; ek modül açıldıktan sonra ≈ 5 sn içinde kapatılırsa ≈ 60 sn: cihaz başına 5 sn hız sınırı; kontrol listesi 33.7 güvenli pay olarak en az 10 sn bekletir, 5–10 sn arası belirsizdir).
- **Uygulamada:** WP-L istemci yenilemesi içeren sürüm (şimdilik yalnız dev kopya `G:\site\ev_otomasyon_dev`; ana ağaçta yok), açık panelde yalnız tür / panjur çifti / kanal sayısı farkını görünce ≈ 3 sn içinde uç noktaları sessizce (yükleme göstergesi ve hata şeridi olmadan) yeniden çeker; lamba ↔ darbe farkı da tür farkıdır ve tetikler, adlar karşılaştırılmaz; en çok 3 deneme yapılır (≈ 2., 12., 42. sn). Kendiliğinden yenileme canlı MQTT durumu ister: Chrome'da ya da durum etiketi "Sistem Hazır" yerine "Canlı izleme kesik" iken WP-L'li sürümde bile gelmez. Bu sürümde değilse (ya da bu iki durumda) üst çubuktaki (dar ekranda ⋮ "Diğer işlemler" içindeki) "Yenile"ye basın ya da aşağı çekin. Eşitleme tamamlandıktan sonra, yenileme gelene kadar eski bir lamba kartına dokunmak motoru sürmez: sunucu, 5. / 6. kanal satırları artık `shutter` olduğundan komutu `400` "Panjur kanalları röle komutuyla sürülemez; panjur komutu kullanın." ile reddeder ve kart eski hâline döner; motor yalnız iki durumda eski lamba kartıyla sürülebilir: panonun yeni yerleşimi yayınlanıp sunucu satırları güncelleyene kadarki ≈ 1 sn'lik aralıkta (kontrol listesi 33.1) ve eşitleme kapalıyken (kontrol listesi 33.8(a)).
- **QA'da deneme:** Simülatörün cihaz web sayfası yoktur; yerleşim `home1`'e `POST /api/config` ile yazılır (§2.5). Sunucu migration 031'i `up --stage2` ile kendiliğinden uygular. QA yığını `ENDPOINT_LAYOUT_SYNC` değişkenini sunucuya geçirmez: eşitleme QA'da hep açıktır (kapatma anahtarı canlıda ya da sunucuyu kendiniz başlatıyorsanız denenebilir). Aşama 33'ü Aşama 14'ten ÖNCE yapın (14.3 "QA Daire 1"in panosunu değiştirir).
- **Sınır:** Gerçek pano (web sayfasındaki "Kanal Ayarları" cihaz anahtarı ister) ve gerçek EMQX üzerinde doğrulanmadı; açık uygulamanın kendiliğinden yenilenmesi QA yığınıyla denenmedi (§7.1).

### Biyometrik Giriş İstemi: Ne Beklemeli (Aşama 27)

Biyometrik giriş yalnız gerçek Android telefonda denenir (telefonda ekran kilidi ve kayıtlı parmak izi ya da yüz gerekir; QA'ya USB ile bağlı telefon yeter, §3.2). Etiket ([etiket]): Android'de eklenti yalnız biyometrik sınıfı (güçlü / zayıf) bildirir; güçlü biyometri (class 3) varsa "Parmak İzi", yalnız zayıf (class 2) varsa "Biyometrik Giriş" olur, "Face ID" yalnız iOS'ta çıkar: yüz tanımalı Android telefonda da "Face ID" beklemeyin (eklenti kaynağından türetildi, telefonda gözlenmedi). Deneme adımları: kontrol listesi **Aşama 27**. Düzeltme ana ağaçta uygulandı, henüz commit'lenmedi.

- **Hangi derleme:** "[etiket] Kullanılsın mı?" penceresinin açıklama satırı "Sonraki girişlerinizde [etiket] ile şifre yazmadan anında (200 ms) evinize erişebilirsiniz." ise telefondaki kurulum ESKİDİR (2026-10-02 07:03'teki `30891ef` öncesi): o derlemede Android etkinliği `FlutterActivity` olduğundan sistem doğrulaması açılamaz ve "Evet, Etkinleştir" pencereyi hiçbir ileti vermeden kapatır; Aşama 27'nin beklentileri o derlemede geçersizdir. "Sonraki girişlerinizde [etiket] ile şifre yazmadan evinize hızlıca erişebilirsiniz." ise kurulum `30891ef` sonrasıdır (düzeltme öncesi ya da düzeltmeli: bu cümle ikisini ayırmaz; aşağıdaki sistem penceresi başlığı ölçütüne bakın). Sürüm numarası ayırt etmez: `pubspec.yaml` `version: 1.0.0+1` üç derlemede de aynıdır; yayın öncesi build numarası (`+1`) artırılmalıdır (öneri; henüz yapılmadı). `30891ef` sonrası ama düzeltme öncesi commit'li derleme sistem penceresinin başlığından ayrılır: düzeltmelide Türkçe "Kimlik doğrulama", düzeltmesizde İngilizce "Authentication required" (koddan türetildi, telefonda gözlenmedi); düzeltmesiz derlemede nedene özel iletiler (kontrol listesi 27.5) de yoktur, bu yüzden Aşama 27'yi düzeltmeli derlemeyle sınayın.
- **İstem ne zaman çıkar:** Girişle biten her akışta (e-posta + şifre, kayıt, Google / Apple, telefon kodu, sihirli bağlantı, kodla ya da bağlantıyla şifre sıfırlama) cihaz biyometriği destekliyorsa ve "istem gösterildi" kaydı yoksa; yalnız pano rotası en üstteyken: girişin kendi sayfası ya da penceresi kapanınca açılır ve siz seçene kadar açık kalır. Servis PIN'iyle girişte ve uygulamayı açarken kayıtlı oturum geri yüklenirken çıkmaz. Çıkış güvenli depoyu siler (biyometrik tercih dahil: anahtar kapanır): çıkış-giriş pencereyi yeniden getirir. Telefon kodu (SMS) yolu uygulamadan tamamlanamaz (kod ekranda gösterilmez): sunucuda SMS gönderici bağlı değildir (QA'da kod gitmez ve ekranda gösterilmez; QA sunucusu kodu API yanıtında `debug_code` olarak döndürür, elle denenebilir, bu rehberle denenmedi; canlıda istek 503 ile reddedilir).
- **Sistem penceresi:** Başlık "Kimlik doğrulama"; açıklama uygulamanın metnidir ("AHBU Ev Otomasyonu için [etiket] girişini etkinleştirin"; kilit ekranında "AHBU Ev Otomasyonu için [etiket] doğrulaması yapın"). Düğmeleri Android yazar: uygulama ekran kilidi yedeğine izin verir (`biometricOnly: false`), bu yüzden eklentinin "Vazgeç" düğme metni bu pencerede beklenmez.
- **Başarısızlıkta:** Neden her yerde yazılır: "Kullanılsın mı?" penceresi açık kalır ve nedeni yazar ("Tekrar Dene"), ⚙ kartı ve çocuk kilidi sayfası nedeni yazar, kilit ekranı kilitli kalır ve nedeni yazar. İptalde "[etiket] doğrulaması tamamlanamadı." (kartta ve çocuk kilidinde "Kimlik doğrulanamadı."), çok fazla hatalı denemede "Çok fazla hatalı deneme yapıldı. Yaklaşık 30 saniye bekleyin." Diğer nedenler ve tam metinler: kontrol listesi 27.5.
- **Sınır:** Telefonda denenmedi (§7.1). DOĞRULANMADI: 5 hatalı parmaktan sonra telefonun uygulamaya kilitlenme hatası bildirip bildirmediği (ekran kilidi yedeği açıkken Android kendi PIN / desen ekranına geçebilir); sistem penceresinin düğme metinleri.

---

## 7. Bilinen Sınırlar ve Doğrulanmayanlar

### 7.1 Yerel QA Yığınında Kanıtlanmayanlar

QA yığını REST/MQTT/cihaz sözleşmesini ve gerçek PostgreSQL'i sınar; aşağıdakiler sınanmaz (`docs/QA_STACK.md` §9):

| Konu | QA yığınında | Nerede doğrulanır |
|------|------|------|
| **ESP32 zamanlaması, bellek, I2C/RS485 elektriği** | Node simülatörü (firmware mantığının portu); zamanlama ±10 ms oynar | Gerçek pano |
| **MQTT TLS, EMQX kimlik/ACL yapılandırması** | aedes (EMQX taklidi), düz TCP `1883` | Canlı EMQX (`8884`, TLS), dağıtımdan sonra |
| **Gerçek panonun buluta bağlanması** (sihirbaz Adım 6 ve sonrası) | Yapılamaz: yığın yalnız `127.0.0.1`'e açıktır, firmware yalnız ISRG köklü TLS ile bağlanır (§1) | Gerçek pano + canlı sunucu, dağıtımdan sonra |
| **Wi-Fi radyosu, kurulum ağı (SoftAP), telefonun ağ değiştirmesi** | Sanal (`/__sim/client-net` modeli) | Gerçek pano + gerçek Android telefon (Aşama 16) |
| **Röle/panjur elektriği, motor süresi** | Yazılım modeli (`violation_count` emniyet gözlemcisi) | Gerçek pano + motor |
| **LWT gecikmesi** | `__sim/offline` soketi hemen kapatır: sunucu birkaç saniyede "çevrimdışı" görür | Gerçek panoda elektrik kesilince ≈45 sn (keepalive 30 sn × 1,5) |
| **Android'de pano ağına bağlanma** (`bindProcessToNetwork`, `docs/CONTRACTS.md` §5), mobil veri | Sınanamaz | Gerçek Android telefon (16.11) |
| **Kamera / karekod** | Emülatör, Windows ve web'de yok: elle giriş yollarını kullanın | Gerçek telefon |
| **Biyometrik** | Sınanamaz | Gerçek telefon (Aşama 27): sistem penceresinin düğme metinleri ve 5 hatalı parmaktaki davranış telefona özgüdür; telefonda denenmedi |
| **Telefona bildirim (push)** | Bu sürümde yok (Firebase/APNs yapılandırılmadı); gece hatırlatması yalnız uygulama içinde görünür ("Bu sürümde bildirim telefona gönderilmez; uygulamayı açtığınızda hatırlatma görünür.") | — |
| **Derin bağlantı (App Links)** | Sınanamaz | Gerçek telefon; alan adında doğrulama dosyası (`assetlinks.json`) yayımlandıktan sonra (Aşama 30) |
| **iOS** | Bu turda kapsam dışı: derlenip denenmedi (macOS + Xcode gerekir) | — |
| **PostgreSQL sürümü** | 18 | Canlı 16: sürüm farkı canlıda doğrulanır |
| **Kod / davet / oturum süreleri** | QA'da kısaltılamaz | Gerçek süre beklenerek (kontrol listesindeki maddeler belirtir) |
| **Pano yerleşiminin buluta eşitlenmesi (WP-L)** | Simülatörde `POST /api/config` ile denenir; gerçek panonun web sayfası ("Kanal Ayarları", cihaz anahtarı ister) ve gerçek EMQX sınanamaz; açık uygulamanın kendiliğinden yenilemesi (WP-L istemci yenilemesi) QA yığınıyla denenmedi; `ENDPOINT_LAYOUT_SYNC=off` QA'da denenemez | Gerçek pano + canlı sunucu, dağıtımdan sonra (Aşama 33) |

### 7.2 Release Derlemesi

`lib/config/app_config.dart`: `API_BASE_URL`, `MQTT_TLS` ve `DEVICE_AP_HOST` değerleri **release** derlemede (`kReleaseMode`) yok sayılır. Bu yüzden:

- `flutter build apk --release` de `flutter run --release` de uygulamayı her zaman **canlı** sunucuya (`https://evotomasyon.gudeteknoloji.com.tr/api`, TLS'li MQTT) ve gerçek kurulum ağına (`192.168.4.1`) yönlendirir; `--dart-define` işe yaramaz.
- QA yığınıyla deneme için **debug** derleme (`--release` olmadan `flutter run`) zorunludur.
- Canlı sunucu dağıtılana kadar (§4.1) release derlemeyle giriş denenemez.

### 7.3 Windows Derlemesi

- Visual Studio "Desktop development with C++" iş yükü gerekir (§2.1).
- `STL1011` için gereken tanım (`add_definitions(-D_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS)`) `windows/CMakeLists.txt`'te **zaten vardır**: dosyayı değiştirmeyin (§3.3).
- Kamera/karekod yoktur; MQTT için yığın `--public-host 127.0.0.1` ile başlatılmalıdır.

### 7.4 Web (Chrome)

Web uygulaması **yalnız bulut (REST) modunda** çalışır:

- **Canlı durum (MQTT):** ✗ web'de hiç başlatılmaz; durum çubuğunda "Canlı izleme kesik" beklenir, durumu "Yenile" ile güncelleyin (üst çubukta yenileme simgeli cam disk; 640 dp'den dar pencerede ⋮ "Diğer işlemler" menüsünde; "Canlı izleme kesik" hapına dokunmak da yeniler). Aşama 33'te açık uygulamanın kendiliğinden yenilenmesi (WP-L istemci yenilemesi) de canlı durum ister: web'de gelmez, "Yenile" ile okuyun.
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
4. `Tohumlama      KISMEN BASARISIZ` görürseniz (çıkış kodu `2`): `node run.js seed` hangi adımın başarısız olduğunu satır satır yazar (`HATA` / `ENGELLENDI`). Ayrıntı için `node run.js logs daemon -n 80`. Çoğunlukla `reset` + `up --stage2` çözer.

### Uygulamada "Pano çevrimdışı" görünüyor

1. Simülatörün bulut bağlantısı: `(Invoke-RestMethod http://127.0.0.1:8082/__sim/state).mqtt` → `connected` ve `cmd_subscribed` `True` olmalı.
2. Daha önce `__sim/offline` gönderdiyseniz geri alın: `curl.exe -s -X POST http://127.0.0.1:8082/__sim/online` (simülatör birkaç saniyede yeniden bağlanır).
3. Broker günlüğü: `node run.js logs broker -n 50` → `connect_denied` (cihaz kimliği reddedildi) ya da `sub_denied` / `pub_denied` (ACL reddi); simülatör tarafında `node run.js logs sim -n 50` → `mqtt_subscribe_denied`.
4. Simülatörü kapatıp açın: `curl.exe -s -X POST http://127.0.0.1:8082/__sim/power-cycle` (açılış birkaç saniye sürer).
5. Sürerse `node run.js seed` çalıştırın: tohum, bağlı olmayan simülatörün bulut kimliğini yeniden yazar. Bunu yaparken uygulamada değiştirdiğiniz tohum parolalarını da geri alır (§2.3). Yine olmazsa: `node run.js down` + `node run.js up --stage2 --keep-secrets`.

### Uygulamada "Canlı izleme kesik" görünüyor

Pano çevrimiçi ama uygulamanın kendi MQTT bağlantısı kurulamamış demektir:

- Windows masaüstü ya da USB'li telefonda yığın `--public-host 127.0.0.1` ile başlatılmış olmalı (varsayılan `10.0.2.2` yalnız emülatörden erişilir); USB'li telefonda ayrıca `adb reverse tcp:1883 tcp:1883`.
- Emülatör ile Windows ya da USB'li telefonu birlikte kullanıyorsanız yığın tek bir MQTT adresi bildirir. Biri bu yüzden MQTT'siz kalır. Yığını `--public-host 127.0.0.1` ile başlatın ve emülatör için `adb -s emulator-5554 reverse tcp:1883 tcp:1883` çalıştırın (§2.2).
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

Her `up` (`--keep-secrets` olmadan) JWT sırrını yeniler. Eski erişim belirteci `401` alır ama uygulama oturumu refresh token ile kendiliğinden sürdürür; normalde girişe dönmezsiniz. Girişe dönme şu durumlarda olur:

- Yenileme başarısız olur. Örneğin `reset` sonrasında veritabanı silindiği için eski oturum yoktur. İleti: "Oturumunuz sona erdi. Lütfen tekrar giriş yapın."
- Servis PIN oturumu kullanıyorsunuz. Bu oturumun yenilemesi yoktur; `--keep-secrets`'sız her `up`'tan sonra "Servis oturumunuzun süresi doldu. Yeni bir servis PIN'i gerekir." ile girişe döner. Yeni PIN: `node run.js accounts`.

Yeniden giriş yapın. Hiç kesinti istemiyorsanız (turun ortasında) yığını sırları koruyarak ve tohumu atlayarak başlatın: `node run.js down`, sonra `node run.js up --stage2 --keep-secrets --no-seed` (`--no-seed` uygulamada değiştirdiğiniz tohum parolalarının geri alınmasını önler).

### Adım 5'te tarama / yükleme / hazırlama reddediliyor (401)

`new1` simülatörü firmware'in kurulum ağı penceresini taklit eder: `up`'tan sonra yaklaşık en çok 30 dk açık kalır, ardından 15 dk kapalıdır ve bu döngü sürer. Pencere kapalıyken anahtarsız kurulum ağı yolu çalışmaz (401) ve sihirbazın Adım 5'i geçilemez. Durumu görün: `(Invoke-RestMethod http://127.0.0.1:8081/__sim/state).wifi.ap_active`. `False` ise açın: `Invoke-RestMethod -Method Post -Uri http://127.0.0.1:8081/__sim/ap -ContentType 'application/json' -Body '{"open":true}'` (AP 10 dk açılır; yineleyebilirsiniz).

### "Çok fazla istek gönderildi. Lütfen N saniye sonra tekrar deneyin."

QA'da bütün istemciler `127.0.0.1` olduğu için sunucunun IP başına sınırları herkes için ortaktır: kayıt saatte 10 (temiz `up --stage2` tohumu bunun 5'ini kullanır), "Şifremi Unuttum" saatte 10, giriş 15 dk'da 30. `node run.js sweep` bu sınırları hızla tüketir: her koşuda (`--only` dahil) en az 7 geçici kullanıcıyı kaydedip giriş yaptırır, 1 geçici süper yönetici açar, 3 pano ve 2 daire oluşturur ve hiçbirini silmez; ikinci sweep kayıt 429'uyla çöker. Bu yüzden sweep'i turun SONUNDA bir kez çalıştırın (kontrol listesi 21.4). Sayaçlar sunucu belleğindedir: bekleyin ya da `node run.js down` + `node run.js up --stage2 --keep-secrets --no-seed` ile sıfırlayın (sweep'in oluşturduğu kayıtlar, "Stokta Hazır" listesindeki fazladan pano dahil, kalır; temiz tur için `reset`).

### `smoke` 23/23 değil

`smoke` tohumlanan başlangıç durumunu varsayar; elle yapılan denemeler bunu bozabilir:

- **`giris: <anahtar>` HATA** (örn. `giris: staff`): o tohum hesabının şifresi uygulamada değiştirildi; `accounts.json` eski parolayı tutar. `node run.js seed` parolayı `accounts.json` değerine geri alır (`NOT … geri alindi`); reset gerekmez.
- **`zamanli kurallar … kural sayisi N`** (4'ten farklı): üç olası neden var. Aşama 25'te kural eklediniz, tohum kurallarından birini sildiniz ya da eski bir `.runtime` kullanıyorsunuz. Önce `node run.js seed` çalıştırın: silinen tohum kuralını geri ekler, eski sürümün bıraktığı yinelenenleri siler. Sizin eklediğiniz kurallara dokunmaz; düzelmezse `node run.js reset` + `node run.js up --stage2`. Tekrarlanan `up --stage2` kuralları çoğaltmaz.
- **`servis PIN: …` HATA:** `accounts`'taki PIN uygulamada kullanıldı ya da ev sahibi uygulamada yeni PIN üretti (eskisi iptal olur). `node run.js seed` yeni PIN üretir.
- Üyelik, devir ve hesap silme denemeleri (Aşama 21, 22, 28) giriş, yetki ve komut denetimlerini bozabilir. Bundan sonra `seed` / `up --stage2` de `KISMEN BASARISIZ` diyebilir: `node run.js reset` + `node run.js up --stage2`.

Sonra yeniden `node run.js smoke`.

### Komut sonunda "Assertion failed … UV_HANDLE_CLOSING" ya da çıkış kodu `3221226505`

Windows/libuv kaynaklıdır (`docs/QA_STACK.md` §11); `status`, `seed` ve `smoke`'ta görülebilir. Ekrandaki çıktı doğrudur ama çıkış kodu bozulur: `$LASTEXITCODE` `0` yerine `3221226505` (0xC0000409) olabilir. Çıkış koduna bakıyorsanız komutu yineleyin.

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

**C:** İlk `up --stage2` (initdb + migration + tohumlama) makine yüküne göre ~20 sn–2 dk sürer; sonrakiler ~5–15 sn. `up` hazır olmayı en çok 300 sn bekler (`--timeout` ile değişir).

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

**C:** Android emülatörünün içinden bakıldığında bilgisayarınızın `127.0.0.1`'idir. QA yığını uygulamaya MQTT adresi olarak varsayılan `10.0.2.2`'yi bildirir; simülatörler bu adı kendi içinde `127.0.0.1`'e çevirir. Windows masaüstü ve USB'li telefonda bu adres çalışmaz: `--public-host 127.0.0.1` kullanın. Yığın tek bir MQTT adresi bildirdiği için emülatörü onlarla birlikte kullanırken emülatöre `adb -s emulator-5554 reverse tcp:1883 tcp:1883` gerekir (§2.2).

### S: Süreli kodları ya da misafir süresini telefonun saatini ileri alarak deneyebilir miyim?

**C:** Hayır. Süreleri sunucu kendi saatine göre denetler; telefonun saati sonucu değiştirmez ve QA'da süreler kısaltılamaz. Süresi dolmuş misafir için hazır `qa.misafir.eski@example.com` hesabını kullanın; diğer sürelerde gerçek süreyi bekleyin.

### S: Pano "çevrimdışı" görünüyor ama simülatör çalışıyor.

**C:** §8'deki "Uygulamada 'Pano çevrimdışı' görünüyor" adımlarını izleyin (`__sim/state` → `mqtt`, broker günlüğü, `__sim/online`, `__sim/power-cycle`, `seed`).

### S: "Parmak İzi Kullanılsın mı?" penceresinde "Evet, Etkinleştir" deyince hiçbir şey olmadan uygulamaya dönüyorum. Neden?

**C:** Telefondaki kurulum eskidir. Pencerenin açıklamasında "(200 ms)" yazıyorsa eski derlemedir (`30891ef` öncesi): Android etkinliği `FlutterActivity` olduğundan sistem doğrulaması açılamaz ve pencere hiçbir ileti vermeden kapanır. Güncel ağaçtan yeniden derleyip kurun (§3.2). Düzeltmeli derlemede doğrulama başarısız olursa pencere kapanmaz: nedenini yazar ve "Tekrar Dene" sunar (§6 "Biyometrik Giriş İstemi: Ne Beklemeli"); `30891ef` sonrası ama düzeltmesiz derlemede de pencere kapanmaz ama nedeni yazmaz (genel ileti) ve sistem penceresinin başlığı İngilizce "Authentication required" olur. Sürüm numarası (`1.0.0+1`) üç derlemede de aynıdır, ayırt etmeye yaramaz.

---

## Kaynaklar

| Kaynak | İçerik |
|--------|------|
| `EVOTOMASYON_CANLI_TEST_KONTROL_LISTESI.md` | Neyin deneneceği: Aşama 1–33 (+ 4.5), beklenen sonuçlar |
| `docs/QA_STACK.md` | Yerel QA yığınının teknik başvurusu (bileşenler, simülatör, sınırlar, sorun giderme) |
| `docs/CONTRACTS.md` | REST / MQTT / pano yerel API sözleşmeleri (§2.4b: pano yerleşiminin buluta eşitlenmesi, WP-L) |
| `docs/DEPLOY_RUNBOOK.md` | Canlı sunucu dağıtımı (henüz uygulanmadı) |
| `docs/SECRET_ROTATION.md` | Sır ve parola yenileme adımları |
| `ev_otomasyon_servis_yazilimi/EV_OTOMASYON_KULLANIM_REHBERI.md` | Fabrika aracı (kayıt, etiket, flash, provizyon) |
| `ev_otomasyon_servis_yazilimi/waveshare_s3_demo/firmware_releases/v1.1.0/SURUM_NOTLARI.md` | Firmware v1.1.0 sürüm notları ve imajları |

---

**Son güncelleme:** 2026-10-03, sürüm 1.3 (Aşama 33 / WP-L: §1, §2.4, §2.5, §4.2, §6, §7.1, §7.4 ve Kaynaklar güncellendi; yeni içerik kodla karşılaştırıldı ve bağımsız doğrulayıcı bulgularıyla düzeltildi, düzeltmeler yeniden bağımsız doğrulamadan geçmedi; QA yığınında çalıştırılarak denenmedi; ayrıca Aşama 27 / biyometrik: §3.2, §6, §7.1 ve Sık Sorulan Sorular güncellendi, ana ağaçtaki commit'siz biyometrik düzeltmesinin kaynağıyla karşılaştırıldı ve bağımsız doğrulayıcı bulgularıyla düzeltildi, düzeltmeler yeniden bağımsız doğrulamadan geçmedi, telefonda denenmedi). Sürüm 1.2 (2026-10-02): Bağımsız doğrulayıcı bulgularıyla düzeltildi: QA yığını komutları gerçekten çalıştırıldı, geri kalanı kodla karşılaştırıldı. Uygulama, gerçek pano ve canlı sunucu bu rehberle çalıştırılarak denenmedi.
