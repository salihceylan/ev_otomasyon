# AHBU Ev Otomasyonu - Canlı Saha & Sistem Uçtan Uca Test Kontrol Listesi

Bu kontrol listesi, sistemin uçtan uca (fabrikadan servis kurulumuna, ev sahibinin günlük kullanımına kadar) **hayatın normal akışında** denenmesi için hazırlanmıştır. Maddeler 2026-10-02 itibarıyla uygulama kodundan (`lib/**`), sunucudan (`server/src/**`), firmware'den ve `docs/CONTRACTS.md`'den doğrulanarak yazıldı; uygulama bu metinle çalıştırılarak denenmedi (denemeleri siz yapacaksınız).

---

## 🔑 Başlangıç Bilgileri

### Bu listeyi nasıl kullanırsınız
- Her aşamanın başındaki **Ortam / Hesap / Ön koşul** satırı, o aşamaya başlamadan neyin hazır olması gerektiğini söyler.
- Maddeler **Yapın** (adımlar), **Beklenen** (ekranda görmeniz gereken sonuç) ve **Olumsuz** (yanlış girdi / yetkisiz deneme) satırlarından oluşur.
- Tırnak içindeki metinler ekranda **birebir** böyle yazar (büyük/küçük harf ve noktalama dahil). Ekranda farklı bir metin görürseniz hata olarak not edin. `[ad]`, `N` gibi köşeli parantezli yerler ve sayılar değişen değerlerdir.
- "(DOĞRULANMADI)" işaretli beklentiler koddan kesinleştirilemedi: ne gördüğünüzü aynen not edin.
- Ortamınızda yapamadığınız maddenin (ör. gerçek pano yok, iOS yok) kutusunu boş bırakıp yanına "yapılamadı" yazın.
- Arayüz yeniden yazıldığı için önceki turun tüm işaretleri sıfırlandı.
- *Not: Her test adımını sırayla gerçekleştirdikten sonra ilgili kutucuğu `[x]` olarak işaretleyebilirsiniz.*

### Test Ortamı Seçimi

| | **Yerel QA yığını (önerilen)** | **Canlı sunucu** |
|---|---|---|
| Durum | Bu makinede, yalnız `127.0.0.1` üzerinde çalışır; canlı sisteme dokunmaz | **Henüz dağıtılmadı** (`docs/DEPLOY_RUNBOOK.md` uygulanmadı) |
| Başlatma | `cd G:\site\ev_otomasyon\tools\qa_stack` → `node run.js reset` → `node run.js up --stage2` (Windows masaüstü / USB'li telefon için `node run.js up --stage2 --public-host 127.0.0.1`) → `node run.js status` | Yeni sunucu kodu + migration'ların tamamı (001–030) dağıtıldıktan sonra |
| REST API | `http://127.0.0.1:5000/api` (Android emülatöründen `http://10.0.2.2:5000/api`) | `https://evotomasyon.gudeteknoloji.com.tr/api` (nginx → `127.0.0.1:5000`; ham IP:5000 dışarıdan erişilemez) |
| Veritabanı | PostgreSQL 18 (gömülü), `127.0.0.1:54329`, veritabanı `ev_qa` | PostgreSQL 16 (docker), `127.0.0.1:5434` (yalnız sunucu içinden) |
| MQTT | aedes (EMQX taklidi), `127.0.0.1:1883` (ws `9001`), **TLS yok**, gerçek EMQX değildir | EMQX, `evotomasyon.gudeteknoloji.com.tr:8884` (TLS). **1883/8883 aynı sunucudaki kapı sisteminin Mosquitto'sudur: bu testlerde kullanmayın** |
| Sağlık kontrolü | `node run.js status` → tüm satırlar `OK` (çıkış kodu `0`), `rest api` satırında `hazir=ready mqtt_koprusu=up` | `https://evotomasyon.gudeteknoloji.com.tr/ready` → `{"status":"ready","components":{"database":"up","mqtt_bridge":"up"},…}` |
| E-postalar (kodlar, etkinleştirme) | Dışarı çıkmaz: `node run.js mails` (liste), `node run.js mails 1` (en yeni e-postanın gövdesi) | Gerçek e-posta kutusu |
| Uygulama | Debug derleme + `--dart-define` (komutlar: `docs/DENEME_REHBERI.md` §3) | Debug derlemede `--dart-define` vermeyin; release derleme her zaman canlı değerleri kullanır |

Ayrıntılı kurulum, komutlar ve sorun giderme: **`docs/DENEME_REHBERI.md`**.

### Test Hesapları & Parolalar

| Rol | Yerel QA (`up --stage2` tohumlar) | Canlı |
|---|---|---|
| Süper yönetici | `qa.super@example.com` | `salihceylan@gmail.com` |
| Servis sorumlusu | `qa.servis@example.com` (ilk girişte zorunlu şifre değişimi çıkar: 26.2) ve Aşama 2'de açacağınız hesap | Aşama 2'de açacağınız hesap |
| Daire sahibi | `qa.sahip1@example.com` ("QA Daire 1", pano `AHBU-S3-0A0002`); `qa.sahip2@example.com` ("QA Daire 2 (baska ev)", başka ev denemeleri için) | Aşama 5'te kurulumda açılan müşteri hesabı |
| Aile üyesi / misafir | `qa.aile@example.com` (aile üyesi), `qa.misafir@example.com` (24 saatlik misafir), `qa.misafir.eski@example.com` (süresi dolmuş misafir) — üçü de "QA Daire 1"de | Aşama 20–21'de davetle eklenir |

- **Parolalar:** QA'da yalnız `node run.js accounts` çıktısındadır (repoya yazılmaz). Canlı süper yönetici şifresi: `<parola: repoda tutulmaz, güvenli yerden alın>` (parola yöneticisinden alın; `docs/SECRET_ROTATION.md` madde 2'ye göre döndürüldükten sonra yalnız yeni parola geçerlidir).
- `node run.js accounts` ayrıca simülatör ev Wi-Fi'sini (`QA-Ev-WiFi` ve parolası), cihazların kurulum PIN'lerini (`setup_pin=`) ve "QA Daire 1" için tek kullanımlık servis PIN'ini (üretildiği `up` anından itibaren 2 saat geçerli) yazar.
- QA'da yeni hesap açarken `@example.com` uzantılı adres kullanın: `.local` / `.invalid` uzantılı adreslere e-posta gönderilmez.

### Veritabanı Durumu
- **QA:** `up --stage2` şunları tohumlar: 7 hesap, 2 daire ("QA Daire 1", "QA Daire 2 (baska ev)"), "QA Daire 1"de 4 zamanlı kural ("Aksam lambasi", "Gece kapat", "Hafta ici panjur kapat", "Hafta sonu panjur ac" [kapalı]), bir servis PIN'i; envanterde stokta (`IN_STOCK`) `AHBU-S3-0A0001` ve `AHBU-S3-0A0003`.
- **Her deneme turundan önce** `node run.js reset` ve ardından `node run.js up --stage2` çalıştırın: `reset` yapmadan tekrarlanan `up --stage2` zamanlı kuralları çoğaltır (4 → 8 → …; bilinen QA aracı hatası) ve her `up` yeni sırlar ürettiği için uygulamadaki oturumlar düşer (`--keep-secrets` bunu önler).
- **Migration kontrolü:** QA: `node run.js sql "SELECT name FROM schema_migrations ORDER BY name"` → JSON listesinin son kaydı `"name": "030_peace_reminder.sql"` (numaralarda boşluk vardır: 002 ve 015 yok, 004 iki dosya, 010b var). Canlı: `MIGRATE_CONFIRM=<db_adı> node scripts/migrate.js --status` (`docs/DEPLOY_RUNBOOK.md`).
- **Canlı:** "yalnız süper yöneticinin bulunduğu temiz veritabanı" varsayımı yalnız canlı kurulum sıfırdan yapılırsa geçerlidir.

### Cihaz Envanteri
- **QA simülatörleri** (gerçek radyo/röle yok): `new1` = `AHBU-S3-0A0001`, `http://127.0.0.1:8081` (emülatörden `10.0.2.2:8081`) — provizyonsuz, stokta; servis sihirbazı ve Wi-Fi akışı için. `home1` = `AHBU-S3-0A0002`, `:8082` — provizyonlu, "QA Daire 1"in panosu (2 panjur + 4 lamba). `stock2` = `AHBU-S3-0A0003`, `:8083` — yalnız `up --stage2 --devices 3` ile (16 röleli).
- **Gerçek pano:** Waveshare ESP32-S3 8DI-8RO, firmware v1.1.0 (**donanımda henüz denenmedi**), Aşama 4.5'teki gibi hazırlanmış (etiket + USB provizyonu).

### MQTT Altyapısı
- **QA:** aedes broker `127.0.0.1:1883` (TLS yok). Uygulamaya bildirilen MQTT adresi varsayılan `10.0.2.2`'dir (emülatör); Windows masaüstü / USB'li telefon için yığını `--public-host 127.0.0.1` ile başlatın.
- **Canlı:** EMQX `8884` (TLS); köprünün düz bağlantısı yalnız sunucu içinde (`127.0.0.1:1884`). Köprü durumu `/ready` yanıtında `mqtt_bridge: "up"` (ya da `"down"`).

### Test Cihazları
- **Android emülatörü** (maddelerin çoğu) ve **en az bir gerçek Android telefon** (karekod/kamera, biyometrik, panonun Wi-Fi kurulum ağı, Aşama 16, 27, 30).
- **İkinci bir cihaz/hesap** (ikinci emülatör, Windows uygulaması ya da Chrome): aile/misafir daveti, devir ve "tüm cihazlardan çıkış" maddeleri için.
- **iOS bu turda kapsam dışıdır** (bu Windows makinede derlenemez; macOS + Xcode gerekir): iOS'a özel maddeleri (ör. 16.10(b)) "yapılamadı" işaretleyin.
- **Chrome (web)** yalnız bulut modunda ve MQTT'siz (canlı durum olmadan) çalışır; **Windows masaüstünde** kamera yoktur (rehber §3).

---

## 📋 Adım Adım Kontrol Listesi

### AŞAMA 1: Süper Kullanıcı Girişi & Sistem Sağlık Kontrolü
> **Ortam:** QA ya da canlı · **Hesap:** süper yönetici (QA: `qa.super@example.com`; canlı: `salihceylan@gmail.com`) · **Ön koşul:** QA'da `node run.js status` tüm satırlar `OK` (canlıda `/ready` → `"ready"`).

- [ ] **1.1. Uygulamayı Başlatma**
  - Yapın: Uygulamayı açın.
  - Beklenen: Logolu açılıştan sonra (donma ya da kırmızı hata ekranı olmadan) giriş ekranı gelir: "AHBU OTOMASYON", "Yapay Zeka Destekli Akıllı Yaşam", "E-Posta Adresi", "Şifre", "Şifremi Unuttum", "Giriş Yap", "Hesabınız yok mu? Kayıt Olun"; "VEYA" altında "Google ile Devam Et", "Telefon Numarası ile Şifresiz Giriş (SMS)", "E-postadaki Bağlantım Var", "Yetkili Servis Girişi (PIN)", "Pano Wi-Fi Kurulumu (İnternet Gerekmez)", "Yerel Ağ Modu (ESP32 Doğrudan Erişim)". ("Apple ile Giriş Yap" yalnız iOS/macOS'ta görünür.)
- [ ] **1.2. Süper Kullanıcı Girişi**
  - Yapın: Süper yönetici e-postası ve şifresiyle (şifre: `<parola: repoda tutulmaz, güvenli yerden alın>`; QA'da `node run.js accounts`) "Giriş Yap".
  - Beklenen: "Süper Yönetici Konsolu" açılır.
  - Olumsuz: Yanlış şifreyle "Geçersiz e-posta / telefon veya şifre." görünür, giriş olmaz.
- [ ] **1.3. Süper Yönetici Konsolu**
  - Beklenen: Üst çubukta "Süper Yönetici Konsolu" ve alt başlık "AHBU Altyapı & Servis Denetimi"; solda ☰ ("Menü"), sağda "Sistem Doktoru (Teşhis)" ve "Yenile" simgeleri ile profil simgesi. Ekranda lamba, panjur, oda ya da daire eşleme kartı **yoktur**; en üstte adınız ve "SÜPER" rozetli tanıtım kartı vardır.
- [ ] **1.4. Sol Sandviç Menü (☰) — Menü İzolasyonu**
  - Yapın: Sol üstteki ☰ simgesine dokunun.
  - Beklenen: Menü başlığında adınız, e-postanız ve "SÜPER YÖNETİCİ KONSOLU" rozeti; sırasıyla "Yönetici Konsolu", "Cihaz Envanteri", "Servis Sorumluları", "Tüm Aboneler & Atamalar", "Sistem Doktoru", "Acil Sıfırlama", tema satırı ("Karanlık Temaya Geç"; koyu temadaysanız "Aydınlık Temaya Geç") ve en altta "Güvenli Çıkış Yap". "Acil Sıfırlama" süper yöneticide **görünür** (beklenen davranış).
  - Olumsuz: Saha araçları "Devreye Alma & Servis Modu", "Pano Değişimi (Afet Modu)" ve "Wi-Fi Yapılandırma & Kurtarma" süper yönetici menüsünde **görünmez** (yalnız servis sorumlusunda vardır: 12.4). "Karekod ile Pano Eşle" adlı bir öğe hiçbir menüde yoktur.
- [ ] **1.5. Konsol Sayaçları & Hızlı İşlemler**
  - Beklenen: Üç sayaç kartı: "Servis Sorumluları" ("YÖNETİCİ"), "Pano Envanteri" ("ENVANTER"), "Devreye Alınan" ("AKTİF PANO"); değerler sunucudan gelir. "Hızlı Yönetici İşlemleri" başlığı ve yanında "Tüm Paneli Aç"; dört kart: "Cihaz Envanteri & Ekleme", "Servis Sorumluları Yönetimi", "Tüm Aboneler & Atamalar", "Sistem Doktoru (Sağlık & Teşhis)". Konsolda API / veritabanı / MQTT portlarını gösteren "yeşil ışık" satırı **yoktur**: altyapı sağlığını QA'da `node run.js status`, canlıda `/ready` ile denetleyin.
  - Olumsuz: Sayaçlar yüklenemezse kartlarda "—" ve üstte hata iletisiyle "Yeniden dene" görünür (uydurma "0" gösterilmez).

---

### AŞAMA 2: Yeni Servis Sorumlusu (Service User) Tanımlama
> **Ortam:** QA ya da canlı · **Hesap:** süper yönetici · **Ön koşul:** Aşama 1; QA'da e-posta çukuru çalışıyor (`node run.js status` → `smtp cukuru` `OK`).

- [ ] **2.1. Sorumlu Ekleme Ekranı**
  - Yapın: ☰ → "Servis Sorumluları" (ya da konsolda "Servis Sorumluları Yönetimi").
  - Beklenen: Sayfa başlığı "Servis Yönetimi" (alt başlık "Yöneticiler, servis sorumluları, müşteriler"); sekmeler "Hesaplar" ve "Görevler ve Araçlar"; "Sistem özeti" kartı ("Süper", "Servis", "Müşteri", "Pano"); arama kutusu "Ad, e-posta veya telefon ara"; süzgeçler "Tümü", "Süper", "Servis", "Müşteri"; sağ altta "Hesap Ekle".
  - Yapın: "Hesap Ekle".
- [ ] **2.2. Bilgileri Doldurma**
  - Beklenen: Pencere başlığı "Yeni Servis Sorumlusu / Yönetici"; "Hesap türü" çiplerinde "Servis sorumlusu" seçili gelir ("Süper yönetici" ve "Müşteri" de vardır).
  - Yapın: "Ad soyad" (Örn: *Ahmet Servis Müdürü*), "E-posta" (QA'da örn. *servis.deneme@example.com*; canlıda erişebildiğiniz gerçek bir adres), "Telefon (isteğe bağlı)" (Örn: *05551112233*), "Görev / bölge notu (isteğe bağlı)". **"Geçici parola (isteğe bağlı)" alanını BOŞ bırakın**: boşsa kişi şifresini etkinleştirme e-postasıyla kendisi belirler. (Doldurulursa hesap hemen "Aktif" açılır ve ilk girişte şifre değişimi zorunlu olur: 26.2.)
  - Olumsuz: "Ad soyad" 1 karakter → "Ad soyad en az 2 karakter olmalıdır."; "Geçici parola"ya 10 karakterden kısa değer → "Şifre en az 10 karakter olmalıdır".
- [ ] **2.3. Kayıt ve Canlı Yenileme**
  - Yapın: "Kaydet".
  - Beklenen: Pencere kapanır; bildirim "[Ad] hesabı oluşturuldu; etkinleştirme bağlantısı [e-posta] adresine gönderildi."; liste kendiliğinden yenilenir ve yeni kartta "SERVİS SORUMLUSU" ile "Davet bekliyor" rozetleri, "Oluşturan: [adınız]" ve "Düzenle", "Daveti yeniden gönder", "Dondur" düğmeleri görünür. QA'da e-posta `node run.js mails` listesine düşer (konu "AHBU Akıllı Ev - Hesabınızı etkinleştirin"; listede `=?UTF-8?Q?…` biçiminde kodlu görünebilir).
  - Olumsuz: Aynı e-postayla ikinci hesap → "Bu e-posta adresi sistemde zaten kayıtlı."
- [ ] **2.4. Süper Kullanıcı Çıkışı**
  - Yapın: ☰ → "Güvenli Çıkış Yap" → "Çıkış Yapılsın mı?" penceresinde "Evet, Çıkış Yap".
  - Beklenen: Giriş ekranı. "Vazgeç" seçilirse oturum açık kalır.

---

### AŞAMA 3: Servis Sorumlusu Hesabını Etkinleştirme & Giriş
> **Ortam:** QA ya da canlı · **Hesap:** Aşama 2'de açılan servis sorumlusu · **Ön koşul:** bu hesaba gelen e-postaları okuyabilmek (QA: `node run.js mails`).

- [ ] **3.1. Hesabı Etkinleştirme & İlk Giriş**
  - Olumsuz (önce): Etkinleştirmeden bu e-postayla herhangi bir şifreyle "Giriş Yap" → "Geçersiz e-posta / telefon veya şifre."
  - Yapın (önerilen, kodla): Giriş ekranında "Şifremi Unuttum" → "Şifre Yenileme" penceresinde "E-posta veya Telefon" alanına servis e-postasını yazın → "Kod Gönder" → bilgi "Eğer kayıtlı bir hesap varsa şifre sıfırlama kodu gönderildi." → yeni gelen e-postadaki 6 haneli kodu (QA: `node run.js mails` → en yeni "Şifre sıfırlama kodu" e-postası, gövdesi `node run.js mails 1`) "6 Haneli Kurtarma Kodu" alanına yazın; "Yeni Şifre (En az 10 karakter)" ve "Yeni Şifre Tekrar" → "Şifreyi Yenile".
  - Yapın (alternatif, bağlantıyla): Etkinleştirme e-postasındaki `https://evotomasyon.gudeteknoloji.com.tr/reset-password#token=…` bağlantısını kopyalayın → giriş ekranında "E-postadaki Bağlantım Var" → yapıştırın (ya da "Panodan yapıştır") → "Devam" → "Yeni Şifre Belirle" sayfasında "Yeni Şifre" ve "Yeni Şifre Tekrar" → "Şifreyi Yenile". Bağlantı 72 saat geçerli ve tek kullanımlıktır. E-postadaki bağlantıya dokunmak uygulamayı açmayabilir (Android App Links doğrulama dosyası henüz yayınlanmadı): bu durumda kopyala-yapıştır yolunu kullanın. QA'da ham e-posta gövdesinde bağlantıdaki `=` işareti `=3D` görünebilir ve uzun satır `=` ile bölünebilir (quoted-printable): kopyalarken düzeltin ya da kod yolunu kullanın.
  - Beklenen: Şifre yenilenince oturum kendiliğinden açılır (kod yolunda bildirim "Şifreniz yenilendi ve oturumunuz açıldı.") ve "Yetkili Servis Konsolu" gelir. Süper yöneticinin listesinde hesap artık "Aktif" görünür.
  - Not: Etkinleştirme e-postasındaki 6 haneli kod uygulamaya doğrudan girilemez; kodla etkinleştirme "Şifremi Unuttum"un gönderdiği **yeni** kodla yapılır (önceki kod geçersizleşir).
- [ ] **3.2. Yetkili Servis Konsolu Doğrulaması**
  - Beklenen: Üst çubukta "Yetkili Servis Konsolu" ve "Saha Operasyon & Montaj Yönetimi"; ☰, "Sistem Doktoru (Teşhis)", "Yenile" ve profil simgeleri. Tanıtım kartında ad ve "YETKİLİ SERVİS" rozeti. Sayaçlar "Pano Envanteri" ("STOK & PANO") ve "Devreye Alınan" ("ABONE DAİRE"). "Saha Servis & Devreye Alma Görevleri" başlığı altında beş kart: "Devreye Alma (Servis Modu)", "Abonelerim & Cihaz Atama", "Pano Değişimi (Afet & Hasar)", "Wi-Fi Yapılandırma & Kurtarma", "Acil Sıfırlama"; altta "Yetkili Servis Güvenlik Uyarısı". Daire ekranı (ışık, panjur) yoktur.
  - Yapın: ☰ simgesine dokunun.
  - Beklenen: Rozet "YETKİLİ SERVİS KONSOLU"; öğeler "Servis Konsolu", "Abonelerim & Cihaz Atama", "Devreye Alma & Servis Modu", "Pano Değişimi (Afet Modu)", "Wi-Fi Yapılandırma & Kurtarma", "Acil Sıfırlama", tema satırı, "Güvenli Çıkış Yap".
  - Olumsuz: Menüde "Cihaz Envanteri", "Servis Sorumluları", "Sistem Doktoru" ve "Tüm Aboneler & Atamalar" **yoktur**; konsolda "Tüm Paneli Aç" yoktur.
- [ ] **3.3. Servis Sorumlusu Ekleme Kısıtlaması (Rol İzolasyonu)**
  - Yapın: Sağ üstteki profil simgesi → "Servis & Yönetici Panelini Aç".
  - Beklenen: Başlık "Servis ve Saha Konsolu" (alt başlık "Müşteri hesapları ve araçlar"); sekmeler "Hesaplar" ve "Görevler ve Araçlar"; bilgi kutusu "Servis sorumlusu ve yönetici hesaplarını yalnızca süper yönetici tanımlayabilir. Burada oluşturduğunuz müşteri hesaplarını görür ve yönetirsiniz."; "Sistem özeti" ve rol süzgeçleri yoktur; listede yalnız kendi hesabınız ("[ad] (siz)") ve sizin açtığınız müşteriler bulunur. Sağ alttaki "Müşteri Ekle" → "Yeni Müşteri Hesabı" penceresinde "Hesap türü" seçimi ve "Geçici parola" alanı **yoktur**; not: "Servis sorumlusu yalnızca müşteri hesabı oluşturabilir. Hesap etkinleştirme bağlantısı müşterinin e-postasına gönderilir; parolayı müşteri kendisi belirler."
  - Olumsuz: Servis sorumlusu süper yönetici ya da servis sorumlusu hesabı açamaz: arayüzde seçenek yoktur, sunucu da reddeder ("Servis sorumluları yalnızca standart daire kullanıcısı tanımlayabilir.").

---

### AŞAMA 4: Daire Sahibi (Müşteri / Admin) Tanımlama
> **Ortam:** QA ya da canlı · **Hesap:** servis sorumlusu · **Ön koşul:** müşterinin e-posta adresi (QA'da `@example.com` uzantılı).

- [ ] **4.1. Müşteri Hesabının Açılması**
  - Yapın: Bu turda müşteri hesabını **kurulum sihirbazında** açtırın (5.3): Adım 3 "Müşteri"de müşterinin e-postası yazılır; bu e-postayla hesap yoksa Adım 4'te "Daireye Bağla" ile sunucu hesabı açar.
  - Beklenen: Adım 4 sonucunda "Müşteri için yeni hesap açıldı; etkinleştirme e-postası gönderildi." Müşteri hesabını 3.1'deki gibi etkinleştirir (8.1).
  - Diğer yollar (isteğe bağlı): "Servis ve Saha Konsolu" → "Müşteri Ekle" → "Yeni Müşteri Hesabı" → "Kaydet" (kartta "MÜŞTERİ" ve "Davet bekliyor"); ya da müşteri kendisi giriş ekranında "Kayıt Olun" ile (11.1).
  - Olumsuz: Adım 3'e hesabı olmayan bir telefon numarası yazıp "Kod Gönder" → "Bu telefon numarasına bağlı bir hesap yok. Kod e-posta ile gönderilir; müşterinin e-posta adresini girin." (yeni müşteri hesabı telefonla açılamaz).
- [ ] **4.2. Daire Bilgisi**
  - Yapın: Sihirbaz Adım 4'te "Daire adı (isteğe bağlı)" alanına ad yazın (Örn: *Daire 4 - Ceylan Apartmanı*; en fazla 100 karakter).
  - Beklenen: Başarı kartında "Daire: [yazdığınız ad]". Boş bırakılırsa müşterinin yeni dairesi "Evim" adını alır (müşterinin panosuz bir dairesi varsa pano o daireye bağlanır).
  - Olumsuz: 100 karakterden uzun ad → "Daire adı çok uzun" ("Daire adı en fazla 100 karakter olabilir.").

---

### AŞAMA 4.5: Fabrika / Atölye - Cihaz Karekodu Üretimi, Etiket, Firmware & Provizyon (Masaüstü Aracı)
> **Ortam:** Windows PC + gerçek pano (USB-C veri kablosu) + QA ya da canlı sunucu · **Hesap:** süper yönetici · **Ön koşul:** Python 3.11+ ve esptool kurulu; ayrıntılı rehber `ev_otomasyon_servis_yazilimi/EV_OTOMASYON_KULLANIM_REHBERI.md` (Adım 1–8). Sıra önemlidir: **sunucuya kaydet → firmware yükle → provizyon (kendiliğinden başlar)**; ters sırada kart parolasız kurulum ağı yayınlar.

- [ ] **4.5. Masaüstü Servis Yazılımını Başlatma & Sunucuya Giriş**
  - Yapın: QA sunucusunu kullanacaksanız önce PowerShell'de `$env:EV_SERVER_URL='http://127.0.0.1:5000'` yazın ve aracı aynı pencereden açın (`G:\site\ev_otomasyon\ev_otomasyon_servis_yazilimi\ev_otomasyon_sistemi.bat` ya da `python ev_otomasyon_sistemi.py`); canlı için değişken gerekmez. Üstteki "🔐 Sunucuya Giriş" → "🔐 Süper Kullanıcı Girişi" penceresinde "Sunucu adresi:", "E-posta:", "Parola:" → "✓ Giriş Yap".
  - Beklenen: Oturum şeridinde e-postanız ve "(süper kullanıcı)"; düğme "🔄 Hesap Değiştir" olur. Sekmeler: "⚡ 1. Firmware Yükleyici (Flasher)", "🏷️ 2. Karekod Üret & Etiket Bas (Envanter)", "📡 3. Cihaz Provizyonu (USB / Wi-Fi)".
- [ ] **4.6. Donanımdan MAC Okuma & Bilgi Üretimi**
  - Yapın: 1. sekmede "COM Port:" listesinden kartı seçin (liste boşsa "🔄 Portları Yenile"); 2. sekmede "📡 Karttan MAC Oku".
  - Beklenen: "MAC Okundu" penceresi; "1. Donanım MAC:" ve "2. Cihaz Seri No (UID):" (`AHBU-S3-` + MAC'in son 6 hanesi, örn. `AHBU-S3-DD8754`) kendiliğinden dolar; "3. Kurulum PIN (6 Hane):" rastgele üretilmiştir (noktalı görünür; "👁️" ile gösterilir, "🎲 Rastgele PIN Üret" ile yenilenir).
- [ ] **4.7. Sunucuya Kayıt & Sıfır-Mükerrerlik Doğrulaması**
  - Yapın: "☁️ SUNUCU ENVANTERİNE KAYDET & KAREKOD ÜRET".
  - Beklenen: "Cihaz Envantere Eklendi!" penceresi (sıra no, UID, MAC); sağda etiket önizlemesi; 3. sekmede kart "Provizyon bekliyor"; "📊 Sunucu Cihaz Envanteri & Durum Yönetimi (Süper Yönetici)" tablosunda yeni satır. PIN ve gizli anahtar bir daha gösterilmez: provizyon bitene kadar aracı kapatmayın.
  - Olumsuz: Aynı kartı ikinci kez kaydetmek reddedilir (araçtaki not: "🛡️ Aynı MAC veya UID sunucuya 2. kez eklenemez."; sunucu `409`).
- [ ] **4.8. Etiket Çıktısı, Firmware Yükleme & USB Provizyonu**
  - Yapın: "💾 Etiketi Kaydet (PNG)" ve/veya "🖨️ Yazdır (Barkod / Termal)". Sonra **aynı araç oturumunda** 1. sekmede "🚀 Bizim Geliştirdiğimiz Yazılım (Otomatik Seçili)" işaretliyken (dosya `firmware_releases/v1.1.0/firmware_combined_0x0.bin`) "⚡ FİRMWARE'İ KARTA YÜKLE (FLASH)"; yükleme 30–60 sn sürer, USB kablosunu çıkarmayın.
  - Beklenen: "Başarılı" penceresinden sonra araç 3. sekmeye geçer ve USB (seri) provizyonu kendiliğinden başlar; sonunda "Durum: Provizyon doğrulandı ✔ (USB seri)" ve "Provizyon Tamamlandı" penceresi. Ardından etiketin sağdaki 2. karekodunu ("Kurulum Wi-Fi'sine bağlan") telefon kamerasıyla okutup `AHBU-XXXXXX` ağına bağlanabildiğinizi deneyin; etiketi pano kapağına yapıştırın; 3. sekmede "🧹 Kaydı Bellekten Sil / Yeni Cihaz"; PNG dosyasını silin (PIN ve Wi-Fi parolası içerir).
  - Olumsuz: Kayıt (4.7) yapılmadan flash edilirse provizyon başlamaz ("Başarılı" penceresi önce 2. sekmede kaydetmeyi söyler). Yüklenen kartın MAC'i kayıtla eşleşmezse provizyon başlatılmaz.

---

### AŞAMA 5: Cihazı Sisteme Ekleme & Daireye Atama (Kurulum Sihirbazı 1/3: Adım 1–4)
> **Ortam:** QA (simülatör `new1` = `AHBU-S3-0A0001`; kurulum PIN'i `node run.js accounts` → `new1 … setup_pin=`) ya da gerçek pano (Aşama 4.5) · **Hesap:** servis sorumlusu (Aşama 3; QA'da `qa.servis@example.com` da kullanılabilir) · **Ön koşul:** müşterinin e-postasına erişim (QA: `node run.js mails`). Eski "Karekod ile Pano Eşle" ve "Eşle ve Daireye Ata" ekranları kaldırıldı: eşleme 10 adımlı kurulum sihirbazındadır (Aşama 5–7; ayrıntılı denemeler 13, 17, 18).

- [ ] **5.1. Sihirbazı Açma & Adım 1 "Hazırlık"**
  - Yapın: Konsolda "Devreye Alma (Servis Modu)" (ya da ☰ → "Devreye Alma & Servis Modu") → "Servis Paneli" ("Kurulum, test ve yönetim") → "Yeni Kurulum" kartında "Yeni Kurulum Başlat".
  - Beklenen: "Yeni Kurulum" sayfasında "Adım 1 / 10" ve başlık "Hazırlık"; "Teknisyen: [ad]", "Yanınızda olması gerekenler" listesi ve "Sunucu bağlantısı" bölümü. "Bağlantıyı Doğrula" → "Oturumunuz geçerli ve sunucuya ulaşıldı." ve durum "Doğrulandı" → "Devam".
  - Not: Ev sahibinin servis olmadan kendi panosunu eşlemesi (sahibin panosuz dairesinde "Karekod ile Cihaz Eşle" / "Kodu Elle Gir (Manuel Eşleme)", dairesiz kullanıcıda "Cihaz Kodunu Elle Gir") 11.3'te denenir.
- [ ] **5.2. Cihaz Bilgilerini Girme (Adım 2 "Cihazı Tanı")**
  - Yapın: Gerçek telefonda "Etiketi Tara (Karekod)" ile etiketin soldaki 1. karekodunu okutun; kamerasız ortamda (emülatör / Windows) "Karekodu okutamıyorum: elle yazacağım" → "Cihaz seri numarası" (QA: `AHBU-S3-0A0001`) ve "Kurulum PIN (6 rakam)" → "Bilgileri Kullan".
  - Beklenen: "Cihaz: AHBU-…" ve "Kurulum PIN: ••••••  (gizli tutulur)". Servis sorumlusunda "Bu hesapla stok durumu görüntülenemiyor. Cihazın kuruluma uygunluğunu sunucu, müşteriye kod gönderilirken kesin olarak kontrol eder." (normal: stoktaki cihazları yalnız süper yönetici görür; süper yöneticide "Sunucuda stokta görünüyor: kuruluma uygun."). Durum "Cihaz tanındı" → "Devam".
  - Olumsuz: "AHBU-" ile başlamayan seri no → "Seri numarası geçersiz"; 5 haneli PIN → "PIN geçersiz"; Wi-Fi karekodu okutulursa "Bu bir Wi-Fi karekodu" (13.2).
- [ ] **5.3. Sahiplenme Onayı (Adım 3 "Müşteri" & Adım 4 "Daireye Bağla")**
  - Yapın (Adım 3): "Müşteri e-posta veya telefon" alanına müşterinin e-postasını yazın → "Kod Gönder" → müşterinin e-postasındaki 6 haneli kodu (QA: `node run.js mails` → "Pano kurulum onay kodu" e-postası) "Müşterinin söylediği 6 haneli kod" alanına yazın → "Devam".
  - Beklenen (Adım 3): "Doğrulama kodu müşteriye gönderildi." (ya da sunucunun iletisi), "Kodun geçerlilik süresi: …" geri sayımı; gönder düğmesi 60 sn "Yeniden gönder: N sn sonra" ile pasif kalır; durum "Kod girildi".
  - Yapın (Adım 4): "Özet"i kontrol edin ("Cihaz: …", "Müşteri: …", "Kurulum PIN'i ve müşteri kodu hazır."), "Daire adı (isteğe bağlı)" (4.2) → "Daireye Bağla" → "Cihaz daireye bağlansın mı?" penceresinde "Evet, Bağla".
  - Beklenen (Adım 4): "Cihaz müşterinin dairesine bağlandı.", "Daire: …", "Cihaz: …"; müşteri hesabı yoksa "Müşteri için yeni hesap açıldı; etkinleştirme e-postası gönderildi."; "Bu daire için kurulum yetkiniz [tarih saat] tarihine kadar geçerlidir." (servis sorumlusuna 72 saatlik kurulum yetkisi); durum "Daireye bağlandı" → "Devam". Kendi hesabınızı yazma ve yanlış kod denemeleri: 13.3–13.4.
- [ ] **5.4. Otomatik Yapılandırma (Varsayılan Kanallar)**
  - Beklenen: Sunucu eşlemede 8 röleli panoya 8 kanal açar: "Salon Panjur Yukarı" / "Salon Panjur Aşağı" ve "Oda Panjur Yukarı" / "Oda Panjur Aşağı" (2 panjur; varsayılan tam açılma süresi 20 sn), "Salon Aydınlatma", "Mutfak Aydınlatma", "Koridor Aydınlatma", "Balkon Aydınlatma". 16 röleli (ek modüllü) modelde ayrıca "Ek Modül Röle 1"–"Ek Modül Röle 8". (Eski "16 kanal" ifadesi yalnız ek modüllü model içindir.) Kontrol: ev sahibinin ekranında (8.2) "Panjurlar" bölümünde 2 panjur, "Aydınlatma & Çıkışlar" bölümünde 4 lamba.

---

### AŞAMA 6: Wi-Fi, Bulut Bağlantısı & Panjur Kalibrasyonu (Kurulum Sihirbazı 2/3: Adım 5, 6, 8)
> **Ortam:** gerçek pano (önerilen) ya da QA (`new1` simülatörü kurulum ağını taklit eder; simülatörün ev Wi-Fi'si `QA-Ev-WiFi`, parolası `node run.js accounts` → "Wi-Fi (simulator ev agi)") · **Hesap:** servis sorumlusu · **Ön koşul:** Aşama 5 tamamlandı (sihirbaz Adım 5'te). Eski "Servis Modu (Cihaz Kurulumu & Kalibrasyon)" aracı ve "Görevler & Araçlar" sekmesindeki karşılığı kaldırıldı.

- [ ] **6.1. Adım 5 "Wi-Fi Kurulumu" & Adım 6 "Bulut Bağlantısı"**
  - Yapın (Adım 5): Aşama 16.9'daki gibi (telefonu panonun kurulum ağına bağlayın → "Bağlandım: Panoyu Kontrol Et" → ev Wi-Fi'sini seçip şifresini yazın → "Yeni Wi-Fi Şifresini Panoya Yükle"); adım yalnız pano gerçekten bağlanınca geçilir.
  - Yapın (Adım 6): Telefonu ev Wi-Fi'sine geri alın ("Önce telefonu ev Wi-Fi ağına geri alın" kartı) → gerekirse "Pano IP adresi"ni düzeltip "Panoya Bağlan" → "Buluta Bağla ve Bekle".
  - Beklenen: "Pano sunucuya bağlanıyor, bekleniyor..." ve "Kalan bekleme süresi: …" (en çok 90 sn) → "Pano sunucuda çevrimiçi: bulut bağlantısı doğrulandı." ve durum "Çevrimiçi" → "Devam". Bağlanmazsa "Tekrar Bekle" / "Kimliği Yeniden Yaz" düğmeleri ve "Panonun kendi bildirdiği durum" çipleri ("Ev Wi-Fi ağı", "Saat (internetten)", "Bulut kimliği kayıtlı", "Bulut bağlantısı") çıkar.
  - QA notu: Emülatörde "Pano IP adresi" alanına `10.0.2.2:8081` yazın (simülatörün bildirdiği ev ağı adresine emülatörden ulaşılamaz; alan `adres:port` kabul eder). Bu QA yolu uygulamada çalıştırılarak denenmedi (DOĞRULANMADI).
- [ ] **6.2. Kanal İsimlendirme — (KALDIRILDI: uygulamada karşılığı yok)**
  - Uygulamada kanal adı / oda düzenleme ekranı **yoktur**; kanallar 5.4'teki varsayılan adlarla gelir (sunucuda uç var, arayüz yok: açık konular listesinde).
  - Beklenen: Sihirbazda ve ev sahibinin ekranında kanal adını değiştiren bir düğme bulunmaz; karta dokunmak yalnız aç/kapat yapar. Eski listedeki "Kanal 3: Salon Avize" önerisi geçersizdir: kanal 3 "Oda Panjur Yukarı"dır (panjur çiftleri 1-2 ve 3-4).
- [ ] **6.3. Panjur Motor Süresi (Adım 8 "Panjur Testi ve Kalibrasyon")**
  - Yapın: "Panjurları Listele". Her panjur için "1) Yön testi": "Yukarı" → "Panjur gerçekten YUKARI mı gitti?" → "Evet, yukarı gitti" (ters giderse "Hayır, aşağı gitti" → "Yön ters: YUKARI ve AŞAĞI kablolarını yer değiştirin." → kabloları değiştirip "Düzelttim, yeniden dene"). "2) Tam açılma süresi": "Ölçüme Hazırla" (süre geçici olarak 300 sn yapılır) → "Alta İndir" → panjur en alttayken "Alta indi" → "Ölçümü Başlat" (kronometre) → panjur tam açılınca "Bitti: panjur tam açıldı" → gerekirse "1 saniye azalt" / "1 saniye artır" → "Kaydet ve Panoda Doğrula". Süreyi biliyorsanız: "Süreyi biliyorum: elle gireceğim" → "Tam açılma süresi (saniye, 1-300)" → "Bu Süreyi Kullan".
  - Beklenen: "Yön doğrulandı." ve "Kayıtlı süre: N sn (sunucuya kaydedildi, panoda doğrulandı)."; panjur rozeti "Hazır • N sn"; adım durumu "N/N hazır". Motoru bağlı olmayan panjur: "Bu panjur kullanılmıyor" → "Bu panjur kullanılmıyor mu?" → "Evet, kullanılmıyor".
  - Olumsuz: Tüm panjurları "Kullanılmıyor" işaretleyip geçmeye çalışınca: 'En az bir panjuru gerçekten test edin (yön + süre): hepsi "Kullanılmıyor" işaretlenerek geçilemez.' Çift yön kilidi (interlock) bir ayar değildir: firmware her zaman uygular.
- [ ] **6.4. Ayarları Panoya Gönderme — (KALDIRILDI: "Panoya Senkronize Et" yok)**
  - Ayrı bir "Panoya Senkronize Et" düğmesi yoktur; ayarlar adım adım yazılır: Adım 6'da bulut kimliği ("Buluta Bağla ve Bekle"), Adım 8'de panjur süresi ("Kaydet ve Panoda Doğrula").
  - Beklenen: 6.3'teki "Kayıtlı süre: … (sunucuya kaydedildi, panoda doğrulandı)." satırı ayarın panoya yazılıp doğrulandığını gösterir.

---

### AŞAMA 7: Devreye Alma (Commissioning) Onayı (Kurulum Sihirbazı 3/3: Adım 7, 9, 10)
> **Ortam:** gerçek pano (röle sesi ve lambayı gözlemek için) ya da QA (`new1`) · **Hesap:** servis sorumlusu · **Ön koşul:** Aşama 6 tamamlandı. Eski "Devreye Almayı Onayla ve Müşteriye Teslim Et" düğmesinin yerini Adım 10 "Teslim" aldı.

- [ ] **7.1. Canlı Donanım Testi (Adım 7 "Röle Testi")**
  - Yapın: "Röleleri Listele" → her röle kartında "Aç", sonra "Kapat" (darbe rölesinde "Tetikle") → "Lamba / yük gerçekten çalıştı mı?" sorusuna gözlediğinize göre "Evet, çalıştı".
  - Beklenen: Kartta "Pano: açıldı ✔" ve "Pano: kapandı ✔", rozet "Doğrulandı"; gerçek panoda röle sesi ve lambanın yanıp sönmesi. Bağlı olmayan çıkış "Kullanılmıyor" ile işaretlenir. Hepsi doğrulanınca ya da işaretlenince "Devam". Ayrıntılı olumsuz denemeler: 17.1.
- [ ] **7.2. Panjur Testi (Adım 8)**
  - Yapın: Adım 8'de (6.3) her panjur için "Yukarı", "Dur", "Aşağı".
  - Beklenen: Motor ilgili yönde döner ve "Dur" ile durur; kartta "Pano: yukarı gidiyor • konum %N" / "Pano: aşağı gidiyor • …" / "Pano: duruyor • …" güncellenir.
- [ ] **7.3. Devreye Alma Onayı Verme (Adım 9 "Duvar Butonları" & Adım 10 "Teslim")**
  - Yapın: Adım 9'u 17.2'deki gibi tamamlayın. Adım 10'da "Kontrol listesi"ni gözden geçirin (17.3), müşteriye gösterin, "Müşteriye kurulumu gösterdim ve teslimi onayladı" kutusunu işaretleyin → "Devreye Almayı Tamamla".
  - Beklenen: "Kurulum tamamlandı: sunucu tüm testleri doğruladı ve cihazı devreye aldı." ve "Kurulum raporu" (17.4); adımın düğmesi "Bitir" olur.
- [ ] **7.4. Servis Çıkışı**
  - Yapın: "Bitir" → "Servis Paneli"nin en altında "Çıkış Yap" (servis PIN oturumunda "Servis Oturumunu Kapat") → "Çıkış Yapılsın mı?" → "Evet, Çıkış Yap" (ya da ☰ → "Güvenli Çıkış Yap").
  - Beklenen: Giriş ekranı.

---

### AŞAMA 8: Daire Sahibinin Kendi Ekranından Canlı Kontrolü
> **Ortam:** QA ("QA Daire 1", simülatör `home1` `:8082`) ya da Aşama 5–7'de kurulan daire + gerçek pano · **Hesap:** daire sahibi (QA: `qa.sahip1@example.com`; ya da Aşama 5'te açılan müşteri hesabı) · **Ön koşul:** pano çevrimiçi.

- [ ] **8.1. Daire Sahibi Girişi**
  - Yapın: Hesap Aşama 5'te yeni açıldıysa önce etkinleştirin (3.1'deki "Şifremi Unuttum" → kod → "Şifreyi Yenile" ya da etkinleştirme bağlantısı). Sonra e-posta ve şifreyle "Giriş Yap".
  - Beklenen: Doğrudan dairenin paneli açılır (8.2).
  - Olumsuz: Etkinleştirmeden giriş denemesi → "Geçersiz e-posta / telefon veya şifre."
- [ ] **8.2. Hazır Panel Karşılaması**
  - Beklenen: Üst çubukta daire adı ve altında "Sistem Hazır • Bulut"; simgeler "Karekod Tara (Cihaz / Eve Katıl)", "Cihaz Ayarları", "Aile & Misafir Yönetimi" ve (geniş ekranda doğrudan, dar ekranda ⋮ "Diğer işlemler" içinde) "Bulut Modu (yerel moda geç)", "Sistem Doktoru (Teşhis)", "Yenile"; en sağda profil. Bölümler: "Panjurlar" (2 panjur), "Aydınlatma & Çıkışlar" (4 lamba), "Duvar Butonları & Girişler"; "Hızlı Senaryolar": "Evden Çıkıyorum", "Günaydın", "İyi Geceler", "Tüm Lambalar", "Panjurları Durdur". Birden çok dairesi olan hesapta başlığa dokununca "Daire Seç" açılır.
- [ ] **8.3. Lamba Aç/Kapa**
  - Yapın: "Aydınlatma & Çıkışlar"da bir lamba kartına dokunun; sonra tekrar dokunun.
  - Beklenen: Kısa süre "Uygulanıyor…", ardından "AÇIK" / "KAPALI"; gerçek panoda röle çeker. QA'da `curl.exe -s http://127.0.0.1:8082/__sim/state` çıktısındaki `relays` değeri değişir.
  - Olumsuz: Pano çevrimdışıyken (QA: `curl.exe -s -X POST http://127.0.0.1:8082/__sim/offline`; gerçek panoda enerjiyi kesin) kartlarda "Çevrimdışı • son bilinen", ekranda "Pano çevrimdışı" kartı; lambaya dokununca "Cihaz çevrimdışı. Komut iletilemedi." + "Tekrar dene". Sonra QA'da `curl.exe -s -X POST http://127.0.0.1:8082/__sim/online`.
- [ ] **8.4. Panjur Kontrolü**
  - Yapın: "Panjurlar"da "Aç", "Durdur", "Kapat" düğmelerini ve kaydırıcıyla bir yüzde seçmeyi deneyin.
  - Beklenen: Durum "Açılıyor…" / "Kapanıyor…" / "Durdu"; kaydırıcıda "Hedef %N"; konum güncellenir.
  - Sınır: Açılırken "Kapat"a basmak reddedilmez: panjur durur, yaklaşık 0,5 sn sonra aşağı iner (QA: `(Invoke-RestMethod http://127.0.0.1:8082/__sim/state).violation_count` → `0` kalır).
- [ ] **8.5. Hepsini Kapat (Gece Huzur Modu)**
  - Ön koşul: en az 2 lamba açık.
  - Beklenen: Ana ekranda "Huzur Modu / Gece Kontrolü" bandı, "2 lamba açık kaldı." ve "Hepsini Kapat".
  - Yapın: "Hepsini Kapat".
  - Beklenen: "2 açık lamba için kapatma komutu gönderildi." bildirimi; lambalar söner, bant kaybolur. Açık lamba yokken bant görünmez.
  - Olumsuz: Misafir hesabında bant ve "Hızlı Senaryolar" görünmez (21.4).

---

### AŞAMA 9: Süper Kullanıcı Takip & Teşhis (Final Kontrol)
> **Ortam:** QA ya da canlı · **Hesap:** süper yönetici; 9.3 için ayrıca bir daire sahibi · **Ön koşul:** Aşama 2–7 yapıldı.

- [ ] **9.1. Süper Kullanıcı ile Tekrar Giriş**
  - Yapın: QA'da `qa.super@example.com`, canlıda `salihceylan@gmail.com` ile giriş.
  - Beklenen: "Süper Yönetici Konsolu".
- [ ] **9.2. Canlı Servis İstatistikleri**
  - Beklenen: Konsolda "Servis Sorumluları" Aşama 2'den, "Pano Envanteri" (sunucuda daireye bağlanmış pano kayıtları) Aşama 5'ten, "Devreye Alınan" Aşama 7'den sonra birer artmıştır. ☰ → "Servis Sorumluları" → "Sistem özeti"nde "Süper", "Servis", "Müşteri", "Pano" sayıları görünür; Aşama 2'de açılan hesabın kartı artık "Aktif"tir.
- [ ] **9.3. Sistem Doktoru**
  - Yapın: Süper yönetici olarak ☰ → "Sistem Doktoru".
  - Beklenen: "Sistem Doktoru" penceresinde "Daire seçili değil" ve "Süper yönetici hesabı belirli bir daireye bağlı değildir; sistem doktoru bir daire için çalışır. …" (süper yöneticinin dairesi olmadığından beklenen budur).
  - Yapın: Daire sahibi hesabıyla üst çubukta "Sistem Doktoru (Teşhis)" ya da ⚙ "Cihaz Ayarları" → "Sistem Doktoru (Teşhis & Analiz)" → "Sistem Doktorunu Çalıştır".
  - Beklenen: "Daire: [ad]"; "1. Bulut sunucu ve güvenli bağlantı" ("Gecikme: N ms", "Veritabanı bağlı", "Mesaj köprüsü bağlı"), "2. Ev modemi ve internet", "3. Pano gücü ve donanım" satırlarında "Sağlıklı"; "Dairedeki panolar" listesi; "Testi Yeniden Çalıştır". (Eski "WebSocket" ve "Servis Uç Noktaları" satırları yoktur.)
  - Olumsuz: Pano çevrimdışıyken (QA: `__sim/offline`) 2. ve 3. satırlar "Sağlıklı" dışında bir rozet ("Uyarı" ya da "Sorun var") gösterir.

---

### AŞAMA 10: Yetkili Servis Konsolu & Tümleşik Saha Araçları Doğrulaması
> **Ortam:** QA ya da canlı · **Hesap:** servis sorumlusu (Aşama 2–3'te açılan; QA'da `qa.servis@example.com`) · **Ön koşul:** hesabın en az bir daireye servis üyeliği (QA: "QA Daire 1"; ya da Aşama 5'te kurulan daire, 72 saat).

- [ ] **10.1. Yetkili Servis Girişi**
  - Yapın: Servis sorumlusu e-postası ve şifresiyle giriş. `qa.servis@example.com` ilk girişte "Şifrenizi Değiştirin" sayfasını açar (26.2): yeni şifre belirleyip not edin.
  - Beklenen: "Yetkili Servis Konsolu".
- [ ] **10.2. Konsol Başlığı & Rozet**
  - Beklenen: Ekranda "Yetkili Servis Konsolu", "Saha Operasyon & Montaj Yönetimi" alt başlığı ve turkuaz "YETKİLİ SERVİS" rozeti görünür.
- [ ] **10.3. Tümleşik Saha Araçları (5 kart)**
  - Yapın: Konsoldaki beş kartı sırayla açıp kapatın.
  - Beklenen: "Devreye Alma (Servis Modu)" → "Servis Paneli"; "Abonelerim & Cihaz Atama" → "Abonelerim & Cihaz Atama" sayfası; "Pano Değişimi (Afet & Hasar)" → "Pano Değişimi" penceresi (aktif daire yoksa "Önce bir daire seçin. …"); "Wi-Fi Yapılandırma & Kurtarma" → "Wi-Fi Kurulum & Kurtarma Sihirbazı" penceresi; "Acil Sıfırlama" → "Acil Pano Sıfırlama" penceresi. "Servis Paneli"nde ayrıca "Yönetim araçları": "Aboneler ve Home Admin", "Cihaz Envanteri" ("Stoğunuzdaki panolar ve karekodları"), "Pano Değişimi", "Sistem Doktoru", "Servis Hesapları"; "Acil durum" altında "Acil Servis Sıfırlaması" kartı.
  - Olumsuz: Eski "Karekod ile Pano Eşle", "Cihaz Envanteri & Seri No", "Acil Sıfırlama & Mülk Devri", "Yetkili Servis Ağı" kartları yoktur.
- [ ] **10.4. 2 Sekmeli Servis Paneli**
  - Yapın: Profil → "Servis & Yönetici Panelini Aç" (servis sorumlusunda ☰ menüde "Servis Sorumluları", konsolda "Tüm Paneli Aç" yoktur).
  - Beklenen: "Servis ve Saha Konsolu"; tam iki sekme: "Hesaplar" ve "Görevler ve Araçlar". "Görevler ve Araçlar"da "Yönetim araçları": "Kurulum Sihirbazı", "Aboneler ve Home Admin", "Cihaz Envanteri", "Pano Değişimi" (aktif daire varsa), "Sistem Doktoru".

---

### AŞAMA 11: Dairesi Olmayan Yeni Bireysel Kullanıcı - Sadeleştirilmiş Katılım Ekranı
> **Ortam:** QA ya da canlı (11.3'ün karekod kısmı için gerçek telefon) · **Hesap:** hiçbir daireye üye olmayan yeni hesap (ikinci cihazda ya da emülatörde açın) · **Ön koşul:** bir ev sahibinin ürettiği geçerli aile ya da misafir kodu (21.1 / 20.1; QA'da `qa.sahip1@example.com` ile üretin); 11.3 için stokta bir pano (QA: `AHBU-S3-0A0003`, PIN `node run.js accounts` → `stock2 … setup_pin=`).

- [ ] **11.1.** **Kayıt ve ilk ekran**
  - Yapın: Giriş ekranında "Kayıt Olun" → "Kayıt Ol" sayfası ("Yeni Hesap Oluşturun"): "Ad Soyad", "E-Posta Adresi", "Telefon Numarası (İsteğe Bağlı)", "Şifre (En az 10 karakter)", "Şifre Tekrar" → "Kayıt Ol ve Giriş Yap".
  - Beklenen: "Hoş Geldiniz, [ad]!" ve "Henüz kayıtlı bir daireniz yok"; "Daireye Katılmak İçin" başlığı altında "Kod ile Bir Eve Katıl", "Karekod Tara (Katıl / Cihaz Eşle)", "Cihaz Kodunu Elle Gir" ve "Nasıl Daireye Katılırım?" bilgi kartı. Lamba/panjur kartı yoktur.
  - Olumsuz: "Şifre Tekrar" farklı → "Şifreler eşleşmiyor"; 9 karakterlik şifre → "Şifre en az 10 karakter olmalıdır".
- [ ] **11.2.** **Kod ile katılım**
  - Yapın: "Kod ile Bir Eve Katıl" → "Bir Eve Katıl" penceresinde "Davet / Devir Kodu" alanına kodu yazın (`AHBU-` + 10 karakter) → "Devam" → "Katılımı Onayla" ekranında "İşlem", "Ev", "Mevcut sakin", "Rolünüz", "Kod geçerliliği" satırlarını kontrol edin → "Eve Katıl".
  - Beklenen: Bildirim '"[ev adı]" evine aile bireyi olarak katıldınız.' (misafir kodunda '"[ev adı]" evine süreli misafir olarak katıldınız.'); pencere kapanır ve ekran kendiliğinden daire paneline döner.
  - Olumsuz: Biçimsiz kod → "Geçerli bir davet veya devir kodu girin"; kullanılmış / süresi dolmuş / var olmayan kodla "Devam" → "Geçersiz veya süresi dolmuş kod."
- [ ] **11.3.** **Karekodla katılım ve kendi panosunu eşleme**
  - Yapın (gerçek telefon): "Karekod Tara (Katıl / Cihaz Eşle)" ile ev sahibinin ekranındaki davet karekodunu okutun → "Bir Eve Katıl" penceresi kod dolu açılır → "Devam" → "Eve Katıl".
  - Yapın (pano): Pano etiketinin soldaki 1. karekodunu okutun (kamerasız ortamda "Cihaz Kodunu Elle Gir").
  - Beklenen: Pano karekodu hata VERMEZ: "Cihaz Eşleştirme" penceresi açılır ("Cihaz UID / Seri No", "Kurulum PIN Kodu (6 Hane)", "Ev / Daire Adı" [varsayılan "Evim"]) → "Eşle & Sahiplen" → "Cihaz başarıyla evinize eşleştirildi." ve kullanıcı bu dairenin sahibi olur.
  - Olumsuz: Wi-Fi karekodu → 'Bu bir Wi-Fi karekodu. Wi-Fi kurulumu için "Wi-Fi Kurulum & Kurtarma Sihirbazı"nı kullanın.'; tanınmayan karekod → "Geçersiz karekod formatı. Lütfen bilgileri kontrol edin." (tarayıcı açık kalır). Yanlış PIN'i 5 kez denemek: 32.4.
- [ ] **11.4.** **Üst çubuğun sadeleştirilmesi**
  - Beklenen: "Karekod Tara (Cihaz / Eve Katıl)" simgesi, "Yenile" (dar ekranda ⋮ "Diğer işlemler" içinde) ve profil simgesi görünür.
  - Olumsuz: "Cihaz Ayarları", "Aile & Misafir Yönetimi", mod simgesi ("Bulut Modu (yerel moda geç)") ve "Sistem Doktoru (Teşhis)" görünmez.

---

### AŞAMA 12: Süper Kullanıcı ve Servis Sorumlusu Menü & Panel İzolasyonu Doğrulaması
> **Ortam:** QA ya da canlı · **Hesap:** süper yönetici (12.1–12.3) ve servis sorumlusu (12.4–12.5) · **Ön koşul:** yok.

- [ ] **12.1. Süper Kullanıcı Sandviç Menü**
  - Beklenen: Menüde yalnız 1.4'teki öğeler: "Yönetici Konsolu", "Cihaz Envanteri", "Servis Sorumluları", "Tüm Aboneler & Atamalar", "Sistem Doktoru", "Acil Sıfırlama", tema satırı, "Güvenli Çıkış Yap" ("Acil Sıfırlama" süper yöneticide bilerek vardır).
  - Olumsuz: "Devreye Alma & Servis Modu", "Pano Değişimi (Afet Modu)", "Wi-Fi Yapılandırma & Kurtarma" bulunmaz.
- [ ] **12.2. Süper Kullanıcı Panel İzolasyonu**
  - Beklenen: "Hızlı Yönetici İşlemleri"nde dört kart: "Cihaz Envanteri & Ekleme", "Servis Sorumluları Yönetimi", "Tüm Aboneler & Atamalar", "Sistem Doktoru (Sağlık & Teşhis)".
  - Olumsuz: Saha kartları ("Devreye Alma (Servis Modu)", "Pano Değişimi (Afet & Hasar)", "Wi-Fi Yapılandırma & Kurtarma", "Acil Sıfırlama") konsolda yoktur.
- [ ] **12.3. Süper Kullanıcı Sorumlular Sayfası**
  - Yapın: ☰ → "Servis Sorumluları".
  - Beklenen: "Servis Yönetimi" sayfası iki sekmelidir: "Hesaplar" (açılışta seçili; "Sistem özeti", "Tümü"/"Süper"/"Servis"/"Müşteri" süzgeçleri, hesap listesi, sağ altta "Hesap Ekle") ve "Görevler ve Araçlar" ("Yönetim araçları": "Kurulum Sihirbazı", "Aboneler ve Home Admin", "Cihaz Envanteri", "Sistem Doktoru"; aktif daire varsa "Pano Değişimi").
- [ ] **12.4. Servis Sorumlusu Sandviç Menü İzolasyonu**
  - Beklenen: Menüde "Servis Konsolu", "Abonelerim & Cihaz Atama", "Devreye Alma & Servis Modu", "Pano Değişimi (Afet Modu)", "Wi-Fi Yapılandırma & Kurtarma", "Acil Sıfırlama", tema satırı, "Güvenli Çıkış Yap".
  - Olumsuz: "Cihaz Envanteri", "Servis Sorumluları", "Sistem Doktoru" ve "Tüm Aboneler & Atamalar" görünmez.
- [ ] **12.5. Servis Sorumlusu Panel İzolasyonu**
  - Beklenen: Konsolda yalnız 3.2'deki beş saha kartı vardır. Üst çubukta "Sistem Doktoru (Teşhis)" simgesi **vardır** (beklenen) ve "Servis Paneli" → "Yönetim araçları"nda "Cihaz Envanteri" (yalnız kendi stoğunuz) ile "Sistem Doktoru" kartları bulunur.
  - Olumsuz: Konsolda "Cihaz Envanteri & Ekleme", "Servis Sorumluları Yönetimi", "Sistem Doktoru (Sağlık & Teşhis)" kartları ve "Tüm Paneli Aç" bağlantısı görünmez.

---

### AŞAMA 13: Kurulum Sihirbazında Karekod Eşleme & Müşteri OTP Doğrulaması
> **Ortam:** QA ya da gerçek pano (13.2 için gerçek telefon kamerası) · **Hesap:** servis sorumlusu · **Ön koşul:** stokta, henüz eşlenmemiş bir pano (QA'da 13.3–13.4'ü Aşama 5'ten önce `AHBU-S3-0A0001` ile, sonra `up --devices 3` ile `AHBU-S3-0A0003` üzerinde yapın).

- [ ] **13.1. Karekod Eşleme Menüsü Birleşimi**
  - Beklenen: Servis konsolunda ve ☰ menüde bağımsız bir "Karekod ile Pano Eşle" seçeneği **yoktur**. Pano eşleme "Servis Paneli" → "Yeni Kurulum Başlat" sihirbazının içindedir: karekod/elle tanıma Adım 2 "Cihazı Tanı"da, müşteriye bağlama Adım 4 "Daireye Bağla"dadır. (Süper yönetici sihirbaza "Servis Yönetimi" → "Görevler ve Araçlar" → "Kurulum Sihirbazı" kartıyla ulaşır.)
- [ ] **13.2. Adım 2 — Karekod Okutma**
  - Yapın: Gerçek telefonda "Etiketi Tara (Karekod)" → tarayıcı ("Cihaz Etiketi", "Pano etiketindeki karekodu çerçeveye hizalayın") → etiketin soldaki 1. karekodunu okutun.
  - Beklenen: Alan doldurmak yerine doğrudan kabul kartı çıkar: "Cihaz: AHBU-…" ve "Kurulum PIN: ••••••  (gizli tutulur)"; durum "Cihaz tanındı". Okutulamazsa yedek yol "Karekodu okutamıyorum: elle yazacağım" çalışır (5.2).
  - Olumsuz: Etiketin sağdaki 2. (Wi-Fi) karekodu ya da modem karekodu → "Bu bir Wi-Fi karekodu"; davet/devir karekodu → "Bu bir cihaz etiketi değil"; bozuk karekod → "Karekod tanınmadı".
- [ ] **13.3. Teknisyen Kendi Hesabıyla Kurulum Engeli**
  - Yapın: Adım 3 "Müşteri"de kendi e-postanızı (ya da telefonunuzu) yazıp "Kod Gönder".
  - Beklenen: "Kendi hesabınız adına kurulum yapamazsınız. Müşterinin bilgisini yazın." uyarısı; kod gönderilmez.
- [ ] **13.4. Müşteri OTP Doğrulaması**
  - Beklenen: Kod 15 dk geçerlidir ("Kodun geçerlilik süresi: …"; süre bitince "Kodun süresi doldu: yeni kod isteyin."); yeniden gönderme 60 sn sonra açılır ("Yeniden gönder: N sn sonra" → "Kodu Yeniden Gönder"). Kod Adım 4'te "Daireye Bağla" sırasında sunucuda doğrulanır; kod girilmeden Adım 3 geçilmez.
  - Olumsuz: Adım 3'e yanlış 6 haneli kod yazıp Adım 4'te "Daireye Bağla" → "Müşteri kodu hatalı" (… "Kalan deneme hakkı: N."); geri dönüp doğru kodu yazın. 5 hatalı denemeden sonra "Çok fazla hatalı kod denendi" (yaklaşık 15 dk beklenir, sonra Adım 3'ten yeni kod istenir).

---

### AŞAMA 14: Acil Servis Sıfırlaması & Pano Değişiminde Karekod (QR Kod) Okuma Doğrulaması
> **Ortam:** gerçek telefon (kamera) + QA ya da canlı · **Hesap:** servis sorumlusu (ya da süper yönetici) · **Ön koşul:** sıfırlanacak/değiştirilecek pano servis sorumlusunun stoğunda ya da servis üyesi olduğu dairede. **Dikkat:** bu işlemler daireyi boşaltır ya da panoyu değiştirir; QA'da "QA Daire 1" yerine Aşama 5'te kurduğunuz daireyle ve turun sonunda yapın.

- [ ] **14.1. Servis Panelinde Acil Servis Sıfırlaması (Karekod)**
  - Yapın: "Servis Paneli" → "Acil durum" → "Acil Servis Sıfırlaması" kartında "Cihaz kimliği (pano etiketi)" alanının sağındaki kamera simgesi ("Etiketi kamerayla oku") → tarayıcı "Sıfırlanacak panonun etiketi" → etiketin 1. karekodunu okutun. "Sıfırlama gerekçesi (en az 15 karakter)" ve isteğe bağlı "Yeni sahip e-posta / telefon (isteğe bağlı)" ("Boş bırakılırsa cihaz stoğa alınır") → "Acil Sıfırla" → "Acil sıfırlama onayı" penceresinde cihaz kimliğini aynen yazın → "Acil Sıfırla".
  - Beklenen: Karekoddan yalnız cihaz kimliği alanı dolar (PIN alınmaz). Sonuçta "Sıfırlama tamamlandı" ve "Cihaz stoğa alındı; eski daire bağlantısı kaldırıldı." (ya da yeni sahibe devir iletisi); "Yeni kurulum PIN" yalnız bu kez gösterilir → "Kaydettim, Kapat".
  - Olumsuz: Gerekçe 15 karakterden kısa → "Gerekçe en az 15 karakter olmalıdır (şu an N)."; yeni sahip olarak kendi hesabınız → "Kendi hesabınızı yeni sahip olarak seçemezsiniz."; onay penceresinde kimlik yanlış yazılırsa onay düğmesi pasif kalır; servis yetkiniz olmayan dairedeki pano → "Bu cihazın dairesinde servis yetkiniz yok. Süper yönetici ile iletişime geçin."
- [ ] **14.2. "Acil Sıfırlama" Penceresinde Karekod Okuma**
  - Yapın: Konsoldaki "Acil Sıfırlama" kartı ya da ☰ → "Acil Sıfırlama" → "Acil Pano Sıfırlama" penceresi → "Pano QR Kodunu Tara (Kamera)" (tarayıcı "Pano Karekodunu Tara") → "Cihaz UID (Pano Etiketi)" dolar → "Sıfırlama Gerekçesi (en az 15 karakter)", "Yeni Sahip E-posta / Telefon (Opsiyonel)" → "Acil Sıfırla & Eski Aileyi Çıkar" → "Acil Sıfırlama Onayı" penceresinde UID'yi yazın → "Sıfırla".
  - Beklenen: Servis ve süper hesapta ayrı bir "Acil Sıfırlama & Mülk Devri" sekmesi yoktur; pencere tek görünümlüdür. İşlem "tek tıkla" değil, kimliği yazarak teyit ederek yapılır; sonuçta "Cihaz sıfırlandı ve stoğa alındı." ve "YENİ KURULUM PIN (yalnızca bir kez gösterilir)".
  - Olumsuz: Pano etiketi olmayan karekod → "Bu bir pano (cihaz etiketi) karekodu değil."
- [ ] **14.3. Pano Değişimi (Disaster Recovery) Karekod Okuma**
  - Ön koşul: aktif dairede kayıtlı eski pano ve stokta yeni pano (QA: `AHBU-S3-0A0003` + PIN).
  - Yapın: Konsolda "Pano Değişimi (Afet & Hasar)" → "Pano Değişimi" penceresi ("Değişim yapılacak daire") → "1. Değiştirilecek (eski) pano" listesinden seçin → "2. Yeni pano": "Yeni pano kimliği" alanındaki kamera simgesi ("Etiketi kamerayla oku"; tarayıcı "Yeni pano etiketi") ile yeni panonun 1. karekodunu okutun → "Değişim nedeni (isteğe bağlı)" → "Eski Panonun Ayarlarını Yeni Panoya Aktar" → "Pano değişimi onayı" → "Panoyu Değiştir".
  - Beklenen: Karekoddan hem "Yeni pano kimliği" hem "Yeni panonun 6 haneli kurulum PIN'i" (gizli) dolar; sonuçta "Pano değişimi tamamlandı".
  - Olumsuz: Aynı kimlik → "Yeni pano, değiştirilecek eski panoyla aynı olamaz."; aktif daire yoksa "Önce bir daire seçin. Pano değişimi, ekranda seçili olan dairede yapılır."

---

### AŞAMA 15: Aydınlık Tema & Yüksek Çözünürlüklü Elektronik Devre Arka Planı Doğrulaması
> **Ortam:** herhangi biri · **Hesap:** süper yönetici ve servis sorumlusu (konsollar için) · **Ön koşul:** temayı değiştirme yolları: profil → "Tema" → "Sistem" / "Aydınlık" / "Karanlık"; konsollarda ☰ → "Aydınlık Temaya Geç" / "Karanlık Temaya Geç"; ⚙ "Cihaz Ayarları" → "Görünüm & Tema Modu" ("Koyu" / "Açık" / "Sistem"). Renk kodları başvuru içindir; gözle değerlendirin.

- [ ] **15.1. Aydınlık Temada Elektronik Devre Görünürlüğü**
  - Beklenen: Aydınlık temada arka planda açık renkli elektronik devre kartı deseni (yollar, via delikleri, çip hatları) seçilir; arka plan düz beyaz ya da düz gri değildir.
- [ ] **15.2. Saha Servis & Konsol Başlık Metinleri Kontrastı**
  - Beklenen: Aydınlık temada "Saha Servis & Devreye Alma Görevleri", "Hızlı Yönetici İşlemleri" ve diğer bölüm başlıkları koyu lacivert/siyah (`#0F172A`) ve rahat okunur; beyaz ya da silik değildir. (Başlıklarda emoji yoktur.)
- [ ] **15.3. Görev Kartları ve Metrik Kutuları Uyumluluğu**
  - Beklenen: Her iki konsolda görev kartları, sayaç kartları ve bilgi kutuları aydınlık temada beyaz zeminli (`#FFFFFF`), belirgin gri çerçeveli (`#CBD5E1`) ve okunur metinlidir.
- [ ] **15.4. Koyu Mod Uyumluluğunun Korunması**
  - Beklenen: Koyu temaya geçince koyu lacivert devre arka planı ve camgöbeği/mavi hatlar görünür; hiçbir ekranda taşma (sarı-siyah çizgili şerit ya da kesik metin) olmaz.
- [ ] **15.5. Sandviç Menü (Drawer) Aydınlık Mod Uyumu**
  - Beklenen: Aydınlık temaya geçince ☰ menü anında açık zemine (`#F1F5F9`), beyaz başlık kartına ve koyu, yüksek kontrastlı yazılara döner; simgeler ve ayırıcılar seçilir. Koyu temaya dönünce menü de koyulaşır.

---

### AŞAMA 16: Servis Sorumlusu Pano Wi-Fi Kurulumu (192.168.4.1) — İnternetsiz & Girişsiz Kurulum Ağı, Karekod Okuma & Çevresel Ağ Seçimi Doğrulaması

> **Model (docs/CONTRACTS.md §3d):** Pano kendi kurulum ağını yayınlar: adı `AHBU-<MAC son 6 hex, büyük harf>`, **WPA2**, parolası **cihaza özeldir** (pano etiketinde yazılıdır; etiketteki **2. karekod** telefon kamerasıyla ağa tek dokunuşla bağlanır). Sabit/varsayılan kurtarma adı veya parolası YOKTUR. Teknisyen bu ağdayken **internet yoktur** ve cihaz anahtarını (`local_key`) sunucudan alamaz; bu yüzden yalnızca `GET /api/wifi/scan`, `POST /api/wifi/connect` ve `GET /api/wifi/status` uçları, kurulum ağından gelen **anahtarsız** isteğe açıktır (pano WPA2 + cihaz provizyonlu). Diğer HER uç (röle, config, mqtt/config, reboot...) yalnız cihaz anahtarıyla çalışır. Bu aşama için uygulamaya **giriş yapmak gerekmez**; uygulama sunucuya hiç istek atmaz.

- [ ] **16.1. Servis Modu Ekranında Doğrudan Wi-Fi Kurulum Kartı:** Yetkili Servis Menüsü açıldığında (ister PIN ile giriş yapılmış olsun ister henüz giriş yapılmamış olsun) "Pano Wi-Fi & Modem Kurulumu" kartının ve "Wi-Fi Kurulum & Kurtarma Sihirbazı" butonunun yer aldığını doğrulayın. Giriş sayfasında da "Pano Wi-Fi Kurulumu (İnternet Gerekmez)" girişinin bulunduğunu; sihirbazın girişsiz kullanıcıda ve telefonda internet yokken (mobil veri/Wi-Fi internetsiz) de açılıp çalıştığını doğrulayın.
- [ ] **16.2. Kurulum Ağına Bağlanma & 192.168.4.1 Bağlantı Doğrulaması:** Servis sorumlusu telefonunu panonun kurulum ağına (`AHBU-<MAC son 6>`, WPA2; parola: pano etiketindeki **cihaza özel** "AĞ PAROLASI (AP)" değeri — etiketteki 2. karekod telefon kamerasıyla ağa tek dokunuşla bağlanır; sabit/varsayılan ad veya parola YOKTUR) bağlayın. Telefon "internet yok" uyarısı verirse bağlantıyı koruyun (Android'de uygulama pano ağını otomatik kullanır, mobil veri açık kalabilir: bkz. 16.11; iOS'ta gerekirse mobil veriyi geçici kapatın). Sihirbazda "Pano Bağlantısını Test Et" butonuna bastığında yeşil başarı kartının (pano adı, UID, sürüm, adres `192.168.4.1`) geldiğini doğrulayın. **Cihaz anahtarı olmadan** (internet yok) telefon tarayıcısında `http://192.168.4.1/api/wifi/status` adresinin `200` ve `wifi_connect_state`, `wifi_connected`, `ap_active` alanlarını içeren bir JSON döndürdüğünü test edin. Sihirbaz, beklenenden farklı bir panoya bağlanıldığını fark ederse ENGELLEMEYEN bir uyarı vermelidir.
- [ ] **16.3. Modem Wi-Fi Karekodu Okutma:** "Modem Wi-Fi Karekodu Tara (Kamera)" butonuna veya SSID alanındaki QR ikonuna basıldığında kamera vizörünün açıldığını; modemin arkasındaki veya müşterinin telefonunda paylaşılan standart Wi-Fi karekodu (`WIFI:T:WPA;S:<ağ adı>;P:<parola>;;`) okutulduğunda hem SSID hem de Wi-Fi şifresinin otomatik olarak doldurulduğunu doğrulayın. Wi-Fi olmayan bir karekod (URL, e-posta vb.) okutulursa SSID alanına ham metin YAZILMAMALI, açık bir hata görünmelidir. Etiketteki 2. karekod (panonun KENDİ kurulum ağı, `AHBU-…`) bu tarayıcıyla okutulursa alanlar DOLMAMALI; "telefon kamerasıyla okutup ağa bağlanın, burada modemin karekodunu okutun" yönlendirmesi çıkmalıdır.
- [ ] **16.4. Çevredeki Wi-Fi Ağlarını Tarama & Seçme:** Pano bağlandıktan sonra "Ağları Tara" butonuyla çevredeki 2,4 GHz Wi-Fi ağlarının listelendiğini (liste kısa süre "taranıyor" kalabilir; pano taramayı en sık 10 sn'de bir başlatır), listede sinyal seviyesi (dBm + sinyal çubuğu ikonu) ve kilit durumunun gösterildiğini, "Pano yalnızca 2,4 GHz Wi-Fi ağlarına bağlanabilir" notunun göründüğünü, listeden bir ağa dokunulduğunda SSID alanının otomatik seçildiğini ve şifreli ağda şifre kutusuna odaklanıldığını (açık ağda şifrenin boşaldığını) test edin. Türkçe karakter içeren ağ adlarının bozulmadan göründüğünü kontrol edin.
- [ ] **16.5. Yeni Bilgileri Panoya Yükleme & Ev Modemi Bağlantısı (Sonuç Bekleme):** "Yeni Wi-Fi Şifresini Panoya Yükle" butonuna basıldığında uygulamanın bağlantı sonucunu panodan **beklediğini** (en çok ~40 sn; `GET /api/wifi/status` yoklaması) ve "Pano ev Wi-Fi ağına bağlandı!" başarısını YALNIZ pano gerçekten bağlandığında (`wifi_connect_state=success`; ev ağındaki IP gösterilir) verdiğini doğrulayın; yükleme isteğinin kabul edilmesi ("bağlanıyor") başarı sayılmamalıdır. Yanlış şifrede anlaşılır hata ("Wi-Fi şifresi hatalı görünüyor…") + "Yeniden Dene" çıkmalı ve panonun eski Wi-Fi bilgisi bozulmamalıdır (pano ~25 sn'de doğrulayamazsa eski kimliğe döner); olmayan/menzil dışı ağda "Ağ bulunamadı" mesajı çıkmalıdır. Başarıdan ~30 sn sonra pano kurulum ağını kapatır: telefon kurulum ağından düşebilir ve uygulama bunu başarısızlık değil **"belirsiz" (sarı) uyarı** olarak göstermelidir; telefonu ev Wi-Fi'sine alıp panonun uygulamada çevrimiçi göründüğünü doğrulayın.
- [ ] **16.6. WebPortal (192.168.4.1 Tarayıcı Arayüzü) Karekod Uyumluluğu:** Servis sorumlusu telefonunun tarayıcısından (Chrome/Safari) doğrudan `http://192.168.4.1` web arayüzünü **anahtarsız** açtığında, sayfa üstünde "Kurulum modu (AP): yalnızca Wi-Fi ayarlarını değiştirebilirsiniz" bandının göründüğünü, Wi-Fi (Station) sekmesinde çevredeki ağlar listesine (sinyal çubuğu + kilit simgesi; dokununca SSID seçilir ve şifre kutusuna odaklanılır) ek olarak "Modem Wi-Fi Karekodu Tara (Kamera / Fotoğraf)" butonunun yer aldığını ve (tarayıcı destekliyorsa) kameradan karekod fotoğrafı çekilerek SSID ile şifrenin otomatik aktarılabildiğini doğrulayın (karekod çözme desteklenmiyorsa buton sessizce elle girişe yönlendirir). Bağlan sonrası sonucun "Bağlandı" olarak YALNIZ pano gerçekten bağlandığında (`wifi_connect_state=success`) gösterildiğini; diğer sekmelerin "Bu işlem için cihaz anahtarı gerekir" kutusu gösterdiğini doğrulayın.
- [ ] **16.7. Sıklık Sınırı (429):** Kurulum ağından anahtarsız "Yeni Wi-Fi Şifresini Panoya Yükle" isteği dakikada 6'dan fazla gönderildiğinde (geçersiz gövdeli denemeler dahil) panonun `429 rate_limited` + `Retry-After` döndürdüğünü; uygulamanın "pano kısa sürede çok fazla deneme aldı (yaklaşık N sn bekleyin)" mesajını gösterdiğini ve gönder butonunun o süre boyunca geri sayımla pasif kaldığını doğrulayın. Geçerli cihaz anahtarıyla gelen isteklerin bu sınıra takılmadığını (anahtarlı yol) kontrol edin.
- [ ] **16.8. Yetki Sınırları (negatif testler):** (a) Telefon ev Wi-Fi'sindeyken (panonun kurulum ağında DEĞİLKEN) tarayıcıda panonun LAN IP'siyle açılan anahtarsız `http://<pano LAN IP>/api/wifi/status` (ve `wifi/scan`, `wifi/connect`) isteklerinin `401` (`{"error":"unauthorized"}`) ile reddedildiğini (aynı durumda sihirbazdaki "Pano Bağlantısını Test Et" `192.168.4.1`'e hiç ulaşamaz, 401 görmez: "Pano bulunamadı. Telefonunuzun Wi-Fi ayarlarından panonun kurulum ağına bağlı olduğunuzdan emin olup tekrar deneyin." hatası, Android'de ayrıca 16.11(c)'deki ipucu çıkmalı; yalnız mobil veride panoya hiç ulaşılamaz); (b) kurulum ağındayken anahtarsız `POST /api/relay`, `/api/config`, `/api/mqtt/config`, `/api/system/reboot` gibi DİĞER uçların `401` ile reddedildiğini; (c) yeni (provizyonsuz) panonun AÇIK kurulum ağında `wifi/*` uçlarının `403 unprovisioned` verdiğini (servis sihirbazı önce "ilk hazırlık" yapar; sonrasında ağ WPA2'ye döner ve telefon parolayla yeniden bağlanır); (d) modemin yerel ağı da `192.168.4.x` ise kurulum ağı yolunun kapandığını (`401`) doğrulayın: bu durumda Wi-Fi kurulumu yalnızca cihaz anahtarıyla yapılabilir ya da modemin ağ aralığı değiştirilmelidir.
- [ ] **16.9. Servis Kurulum Sihirbazı Adım 5 (İnternetsiz & Anahtarsız):** "Yeni Kurulum Başlat" sihirbazının 5. adımında (Wi-Fi Kurulumu) telefonun kurulum ağına bağlanma yönergesinin (ağ adı ve etiketteki parola) göründüğünü; "Bağlandım: Panoyu Kontrol Et" ile panonun kimliğinin anahtarsız okunup beklenen panoyla eşleştirildiğini (yanlış panoya bilgi gitmemeli); ev Wi-Fi bilgisinin yukarıdaki bileşenle (tarama listesi, karekod, sonuç bekleme) yüklendiğini ve adımın YALNIZ pano gerçekten bağlandığında geçildiğini doğrulayın. 6. adımda ("Bulut Bağlantısı") önce telefon ev Wi-Fi'sine döner (internet gerekir), "Panoya Bağlan" ile pano ev ağındaki adresinden bağlanır; yerel anahtar sunucudan alınır ve telefona KAYDEDİLMEZ.
- [ ] **16.10. Telefon (Android/iOS) Davranışı & Bilinen Sınırlar:** (a) Android'de telefon "internet yok" nedeniyle kurulum ağını bırakıp mobil veriye geçebilir; uygulama artık YALNIZ pano ile konuşulan sürelerde sürecini kurulum ağına bağlar (16.11). Bağlama yine de başarısız olursa (üretici/Android sürümü farkı): "Bu ağda kal / internetsiz bağlantıyı koru" seçin veya mobil veriyi geçici kapatın. iOS'ta bağlama YOKTUR (platform kodu yalnız Android). (b) iOS'ta aynı davranış ve "Yerel Ağ" izin istemi (uygulama ilk erişimde izin ister) test edilmelidir. (c) Tarayıcı arayüzünde (16.6) karekod çözme yalnızca tarayıcının `BarcodeDetector` desteği varsa çalışır; çoğu telefonda (güvenli olmayan `http` bağlamı, iOS Safari) yedek yol elle girişe düşer: bu bir hata değildir.
- [ ] **16.11. Android: Mobil Veri AÇIKKEN İnternetsiz Pano Ağı (Süreç Bağlama):** *(Dart tarafı sahte kanal + sahte HTTP ile sınandı; **gerçek Android cihazda DOĞRULANMADI** — bu madde o saha doğrulamasıdır. Not: numara 16.7 değil 16.11'dir; 16.7–16.10 başka maddelerdir ve dış başvurular (`docs/QA_STACK.md`) bozulmasın diye numaralar kaydırılmadı.)* **ÖN KOŞUL (aksi halde bu madde özelliği SINAMAZ):** Android, kullanıcının elle seçip "internetsiz de olsa bu ağda kal" onayını verdiği Wi-Fi'yi hücreselin önüne alıp VARSAYILAN ağ yapar; o durumda `192.168.4.1` istekleri özellik olmadan da Wi-Fi'den gider. Bu yüzden: telefonda **mobil veri AÇIK** olsun; panonun ağını (`AHBU-<MAC son 6>`, WPA2) telefonun Wi-Fi ayarlarından **"Ağı unut"** ile silip yeniden bağlayın ve "internet yok / bu ağda kal" önerisini ONAYLAMAYIN (ağ "bağlı, internet yok" kalsın). Pano ağındayken telefon tarayıcısında (Chrome) bir internet sitesinin AÇILDIĞINI doğrulayın (= varsayılan ağ hücresel; ayrıca `adb shell dumpsys connectivity` çıktısında varsayılan ağa bakılabilir): açılmıyorsa telefon pano ağını varsayılan yapmıştır ve test GEÇERSİZDİR. İki kipte koşun: (1) varsayılan hücresel (özellik burada sınanır), (2) "bu ağda kal" onaylı (pano ağındayken bulutun çalışmaması bu kipte beklenen bir durumdur; yalnız pano çağrılarının çalıştığını doğrulayın). (a) Wi-Fi Kurulum & Kurtarma Sihirbazı'nda (ve servis kurulum sihirbazı 5. adımında) "Pano Bağlantısını Test Et" mobil veriyi kapatmadan yeşil başarı vermeli; "Ağları Tara", "Yeni Wi-Fi Şifresini Panoya Yükle" ve sonuç bekleme (`wifi/status`, ~40 sn) de çalışmalıdır; ekranda "Mobil veri açık kalabilir; uygulama pano ağını otomatik kullanır. Bağlantı kurulamazsa mobil veriyi kapatıp yeniden deneyin." yönergesi görünmelidir (iOS'ta eski "gerekirse mobil veriyi kapatın" metni). (b) **Sihirbaz bitince bulut normale dönmeli:** başarı, "belirsiz" (sarı), hata ya da "Kapat" sonrası uygulamanın bulut REST istekleri (giriş, cihaz listesi) birkaç saniye içinde, MQTT yeniden bağlanması üstel bekleme nedeniyle en çok ~60 sn içinde yeniden çalışmalı (hemen düzelmezse uygulamayı arka plana alıp geri getirin: MQTT sıfırdan başlar); süreç pano ağında takılı kalmamalıdır (pano isteği sürerken yeni bulut bağlantılarının başarısız olması bilinçli sınırdır). (c) Negatif: telefon panonun ağında DEĞİLKEN (ev Wi-Fi'sinde, yalnız mobil veride ya da Wi-Fi kapalıyken) "Pano Bağlantısını Test Et" hata vermeli ve hata kutusunda "Telefon pano kurulum ağına (AHBU-…) bağlı görünmüyor: Wi-Fi ayarlarından panonun ağına bağlanın." ipucu görünmelidir; ham teknik hata metni görünmemelidir. (d) Ev Wi-Fi'sinde panoya LAN IP'siyle bağlanma (ayarlardaki cihaz adresi; servis sihirbazı 6. adım / "IP ile bağlan") bu işlemden ETKİLENMEMELİ: bağlama yalnız `192.168.4.1` içindir; bulut ve LAN çağrıları normal çalışmalıdır. (e) Sihirbaz açıkken telefonun Wi-Fi'sini kapatıp açın ya da panonun ağından ayrılıp dönün: uygulama donmamalı (yerel çağrı üst sınırı ~9 sn), "Yeniden Dene" çalışmalıdır. (f) Ayarlarda doğrudan mod adresini `192.168.4.1` yapıp panoyu bu ağdan yoklarken (1,5 sn) bağlantı kopmadan çalıştığını ve ağdan çıkınca bulutun normale döndüğünü doğrulayın. (g) VPN: telefonda bir VPN açıkken sihirbazı deneyin: işletim sistemi süreç bağlamasını reddederse (yerel `bind_denied`) ağ hatasında "telefonda VPN (özel ağ) açıksa kapatıp yeniden deneyin" ipucu görünmeli ("pano ağına bağlanın" ipucu DEĞİL); VPN kapatılınca çalışmalıdır. (h) Tanı günlüğü: `adb logcat -s BoardNetwork flutter` (debug derleme). Beklenen sıra (HER pano işlemi için ayrı döngü: "Pano Bağlantısını Test Et", "Ağları Tara" ve "Yükle + sonuç bekleme" kendi kirasını açıp kapatır; sihirbaz boyunca TEK sürekli bağlama beklemeyin): `acquire: istek kaydedildi` → `wifi ağı görüldü, değerlendiriliyor` → `bound` (Dart: `[BoardNetwork/Dart] acquire -> bound (-)`) → işlem bitince `release: wasBound=true` (Dart: `release -> tamam`); sonuç bekleme (~40 sn) tek kirayla bütün yoklamaları kapsar; telefon pano ağından ayrılırsa `bağlı ağ kayboldu; çözülüyor` (Dart: `networkLost: ...`). Ev Wi-Fi'sindeyken ~3 sn sonra `GRACE doldu ... other_subnet` (not_on_board_network), Wi-Fi kapalıyken ~5–6,5 sn sonra `no_wifi`. `[BoardNetwork/Dart] yerel eklenti kayıtlı değil` satırı görünürse yerel eklenti kaydı (MainActivity) kaybolmuştur: arayüz eski "mobil veriyi kapatın" yönergesine döner. Yalnız durum/ayrıntı belirteçleri yazılır; SSID/IP/anahtar yazılmaz. En az iki farklı Android sürümünde/üreticide (ör. Samsung 13/14 ve Xiaomi/Pixel) tekrarlayın. iOS'ta bu madde geçerli değildir (bağlama yalnız Android; "Yerel Ağ" izni için 16.10(b)).

---

### AŞAMA 17: Kurulum Sihirbazında Röle & Buton Doğrulaması (Adım 7–10)
> **Ortam:** QA (`new1`) ya da gerçek pano · **Hesap:** servis sorumlusu · **Ön koşul:** sihirbaz Adım 7'de (Aşama 5–6 tamam). Bu aşama Aşama 7'nin ayrıntılı ve olumsuz denemeleridir. Eski "Canlı Röle & Buton Test Konsolu" ve "Tümünü Doğrula" kaldırıldı.

- [ ] **17.1. Adım 7 — Röle Testi**
  - Yapın: "Röleleri Listele" → bir rölede "Aç" ve "Kapat" (darbe rölesinde "Tetikle") → "Lamba / yük gerçekten çalıştı mı?" sorusuna "Hayır, çalışmadı".
  - Beklenen: Pano geri bildirimi "Pano: açıldı ✔" / "Pano: kapandı ✔" (bekleme sırasında "Pano: açma bekleniyor"); "Hayır, çalışmadı" sonrası rozet "Sorun var" ve "Yeniden test et"; "Evet, çalıştı" sonrası "Doğrulandı"; bağlı olmayan çıkış "Kullanılmıyor" (geri almak için "Kullanılıyor olarak işaretle").
  - Olumsuz: "Sorun var" durumunda bir röle varken adım geçilmez: 'Sorunlu röle var: düzeltip yeniden test edin ya da "Kullanılmıyor" işaretleyin.'
- [ ] **17.2. Adım 9 — Duvar Butonları Dinlemesi**
  - Yapın: "Girişleri Listele" → "Dinlemeyi Başlat" → duvardaki her butona sırayla basın (1 saniye basılı tutun). QA'da basışı simülatörle yapın: `curl.exe -s -X POST http://127.0.0.1:8081/__sim/di/1/press` (giriş 1; diğerleri için numarayı değiştirin).
  - Beklenen: "Dinleniyor: şimdi duvardaki butonlara sırayla basın (1 saniye basılı tutun)."; basılan girişte "Basış algılandı: [saat]" ve rozet "Algılandı"; adım durumu "N/N tamam". Butonu olmayan girişte "Bu girişte buton yok" → rozet "Buton yok". "Dinlemeyi Durdur" ile dinleme biter.
  - Not: Çocuk kilidi açıksa bilgi kutusu "Çocuk kilidi AÇIK: duvar butonları röleleri tetiklemez. Basışlar yine de algılanır; …" çıkar ve basışlar yine algılanır.
- [ ] **17.3. Adım 10 — Otomatik Kontrol Özeti**
  - Beklenen: "Kontrol listesi" kartında beş satır: "Wi-Fi" ("Pano ev Wi-Fi ağına bağlı…"), "Bulut" ("Sunucuda çevrimiçi"), "Röleler" ("N röle doğrulandı…"), "Panjurlar" ("[ad]: N sn, yön doğru" ya da "Panoda panjur yok"), "Duvar butonları" ("N buton algılandı"); eksik satırda "Adım N" düğmesi o adıma götürür; "Güncel durumu yeniden oku". Altında "Not ve teslim": "Montaj notu (isteğe bağlı)", "Teslim alan kişi (isteğe bağlı)" ve onay kutusu "Müşteriye kurulumu gösterdim ve teslimi onayladı".
  - Olumsuz: Kutuyu işaretlemeden "Devreye Almayı Tamamla" → "Müşteri onayı gerekli"; eksik adım varken "Eksik adımlar: …" ve "Önceki adımlar tamamlanmadı".
- [ ] **17.4. Devreye Alma Tamamlanması**
  - Yapın: Not yazıp kutuyu işaretleyin → "Devreye Almayı Tamamla".
  - Beklenen: "Kurulum tamamlandı: sunucu tüm testleri doğruladı ve cihazı devreye aldı."; "Kurulum raporu" (Tarih, Teknisyen, Daire, Cihaz, "Sonuç: BAŞARILI - sunucu devreye almayı onayladı", Kontroller) ve "Rapor PIN, cihaz anahtarı, bulut kimliği ve Wi-Fi şifresi içermez."; "Raporu Kopyala / Paylaş" → "Rapor panoya kopyalandı"; adım düğmesi "Bitir".
  - Olumsuz: Sunucu kontrolleri onaylamazsa "Sunucu devreye almayı onaylamadı" ve "Başarısız kontroller: …"; ilgili adıma dönüp yeniden deneyin.

---

### AŞAMA 18: Servis Panelinde Devam Eden Kurulum, Mevcut Cihazlar & Cihaz Adresi
> **Ortam:** QA ya da gerçek pano · **Hesap:** servis sorumlusu · **Ön koşul:** Aşama 5'te başlatılmış bir kurulum. Eski "Aktif Çalışma Panosu", "Çalışma Cihazı: [UUID]", "Hızlı IP" çipleri ve "Ping Testi" kaldırıldı; sihirbaz Adım 1'de cihaz listesi ya da UID araması **yoktur**.

- [ ] **18.1. Devam Eden Kurulumlar**
  - Yapın: Sihirbazda Adım 4'ü geçtikten sonra üst çubuktaki geri oku (ya da telefonun geri tuşu) ile çıkın (adım başlığındaki "Önceki adım" oku yalnız bir önceki adıma döner) → "Sihirbazdan çıkılsın mı?" ('İlerlemeniz bu telefonda kaydedildi. "Devam eden kurulumlar" listesinden kaldığınız yerden sürdürebilirsiniz.') → "Çık".
  - Beklenen: "Servis Paneli" → "Devam eden kurulumlar" kartında "Kaldığı yer: Adım N / 10 - [adım adı]", "Müşteri: …", "Son işlem: …" ve "Devam Et" (kurulumu aynı adımdan açar); "Kaydı sil" → "Kurulum kaydı silinsin mi?". Kayıt yokken 'Yarım kalan kurulum yok. "Yeni Kurulum Başlat" ile başlayabilirsiniz.'
  - Olumsuz: Adım 4'ten ÖNCE çıkınca pencere "Cihaz henüz daireye bağlanmadı; şimdi çıkarsanız baştan başlamanız gerekir." der ve kayıt oluşmaz.
- [ ] **18.2. Cihaz Adresi (Hızlı IP Seçimi Yok)**
  - Beklenen: Sihirbazda hızlı IP çipi yoktur; Adım 6'da yalnız "Pano IP adresi" alanı ve "Panoya Bağlan" vardır. Kurulumdan sonra adres ⚙ "Cihaz Ayarları" → "Cihaz Yerel Adresi (IP)" kartından yönetilir: "Cihaz adresi" alanı, çipler "192.168.4.1 (kurtarma ağı)" (QA emülatöründe "10.0.2.2:8081 (kurtarma ağı)") ve biliniyorsa "Son bilinen: [IP]"; düğme bulut modunda "Adresi Kaydet", yerel modda "Kaydet ve Bağlan" (29.2–29.3). Pano çevrimdışıyken adres kendiliğinden bulunmaz.
- [ ] **18.3. Cihaz Seçim Yolları (Mevcut Cihazlarım)**
  - Yapın: "Servis Paneli" → "Mevcut cihazlarım".
  - Beklenen: "Daire: [aktif daire]" ve o dairenin panoları ("Çevrimiçi" / "Çevrimdışı"); her pano için "Bağlantıyı yeniden kur" (sihirbazı Adım 5'ten açar) ve "Testleri yap" (Adım 7'den açar). Aktif daire yoksa "Aktif daire seçili değil. …". Yeni pano için yollar Adım 2'dedir: "Etiketi Tara (Karekod)" ya da karekod bozuksa "Karekodu okutamıyorum: elle yazacağım" (13.2).

---

### AŞAMA 19: Servis Sorumlusu Abonelerim Menüsü & Home Admin (Ev Yöneticisi) Atama
> **Ortam:** QA ya da canlı · **Hesap:** servis sorumlusu (yalnız servis üyeliği süresi dolmamış daireleri görür) ya da süper yönetici (tüm daireler) · **Ön koşul:** listede en az bir daire (QA: "QA Daire 1"; ya da Aşama 5'te kurulan daire, 72 saat). **Dikkat:** 19.4(b) daireyi devreder; QA'da sonra `reset` gerekir.

- [ ] **19.1. Abonelerim Sayfasına Erişim**
  - Yapın: Servis sorumlusu: ☰ → "Abonelerim & Cihaz Atama" (alternatifler: konsoldaki "Abonelerim & Cihaz Atama" kartı, "Devreye Alınan" sayacı ya da "Servis Paneli" → "Yönetim araçları" → "Aboneler ve Home Admin"). Süper yönetici: ☰ → "Tüm Aboneler & Atamalar".
  - Beklenen: Sayfa başlığı "Abonelerim & Cihaz Atama" (iki rolde de).
- [ ] **19.2. Abone ve Daire Listesi Görünümü**
  - Beklenen: Üstte "Toplam Abone", "Home Admin Var", "Atama Bekleyen" çipleri (liste tamamı yüklenmediyse "N+"); arama kutusu "Daire adı, adres, pano UUID veya müşteri ara..." (yazmayı bırakınca ~300 ms sonra süzer; ev adı, adres, sahip adı/e-posta/telefon ve pano UID'si); her kartta daire adı, adres (yoksa "Adres belirtilmemiş"), "Pano UUID: …" ("UUID Kopyala" → "Pano UUID panoya kopyalandı"); sayfa başına 30 kayıt, fazlası için "Daha fazla yükle".
  - Olumsuz: Eşleşmeyen arama → "Aramanıza uygun daire veya pano bulunamadı".
- [ ] **19.3. Devreye Alma ve Home Admin Durum Rozetleri**
  - Beklenen: Her kartta devreye alma rozeti "Devrede" ya da "Bekliyor"; yönetici satırı "Home Admin: [ad soyad]" ve iletişim bilgisi, sahibi yoksa "Home Admin henüz atanmadı" ve "Pano şu an servis kontrolünde. Daire sahibine devredin." Düğme: sahip varsa "Yöneticiyi Devret", yoksa "Home Admin Ata".
- [ ] **19.4. Home Admin Yetkilendirme — Çok Adımlı OTP Akışı**
  - (a) Sahibi olmayan daire (karttaki "Home Admin henüz atanmadı"; böyle bir daire yoksa "yapılamadı" işaretleyin): "Home Admin Ata" → "Home Admin Ata" penceresi: "Yeni yönetici adı soyadı *", "E-posta adresi" / "Telefon numarası" → "Devam" → "Yönetici değişikliğini onaylıyor musunuz?" → "Evet, Ata". Kod istenmez; mevcut üyeler korunur.
  - (b) Sahibi olan daire: "Yöneticiyi Devret" → "Home Admin Devret" penceresi ("Pano: …", "Mevcut yönetici: [ad] ([iletişim])") → ad ve e-posta → "Devam" → "Yönetici değişikliğini onaylıyor musunuz?" ("…Mevcut yöneticiye onay kodu gönderilecek.") → "Evet, Devret" → "Mevcut yöneticiye ([maskeli e-posta]) onay kodu gönderildi." → mevcut yöneticinin e-postasındaki kodu (QA: `node run.js mails`) "Mevcut yöneticinin söylediği 6 haneli kod" alanına yazın → "Devret". Kod 900 sn geçerli; yeniden gönderme 60 sn sonra ("Kodu yeniden gönder").
  - Beklenen: Yeşil bildirim (sunucu iletisi; uyarı varsa sarı bildirim ve "Atama tamamlandı, ancak uyarılar var" penceresi). (b)'de daire DEVREDİLİR: eski sahip dahil tüm aile/misafir üyelikleri kalkar (işlemi yapan servisin kendi servis üyeliği hariç), servis PIN'leri/oturumları ve uygulama bulut kimlikleri iptal edilir. Hedef kişinin hesabı yoksa "pending_invite" hesap açılır ve etkinleştirme e-postası gider (telefonla yeni hesap açılamaz).
  - Süper yönetici ek yolu: sahipli dairede "Sahibe ulaşılamıyor mu? (süper yönetici)" → "Gerekçe (en az 15 karakter)" → "Gerekçeyle Zorla Ata" → "Sahibin onayı olmadan atansın mı?" penceresinde `ZORLA` yazın → "Zorla Ata".
  - Olumsuz: E-posta ve telefon boş → "E-posta veya telefondan en az birini girin."; mevcut yöneticinin kendisi → "Bu kişi zaten dairenin mevcut yöneticisi."; kod alanı eksik → "Mevcut yöneticiye giden 6 haneli kodu yazın."; yanlış kod → hata ve "Kalan deneme hakkı: N."; kendinizi ya da bir servis/süper hesabını hedeflemek sunucuda reddedilir (403).
- [ ] **19.5. Otomatik Sayfa Yenileme**
  - Beklenen: Atama bitince pencere kapanır, liste kendiliğinden yeniden yüklenir ve kart uygulamayı kapatıp açmadan "Home Admin: [yeni ad]" olur.

---

## İLERİ ÖZELLİKLER (Aşama 20–32)

### AŞAMA 20: Süreli Misafir Daveti (Davet Kodu & QR) — Zaman Sınırı Doğrulaması
> **Ortam:** QA ya da canlı (20.4 için gerçek telefon kamerası) · **Hesap:** ev sahibi (QA: `qa.sahip1@example.com`) + misafir olacak, daireye üye olmayan ikinci hesap (ikinci cihazda) · **Ön koşul:** telefon saatini değiştirmeyin: süreleri sunucu kendi saatiyle denetler.

- [ ] **20.1. Davet Kodu Üretimi (4 Saat)**
  - Yapın: Ev sahibi: profil → "Aile & Misafir Yönetimi" (ya da üst çubuk "Aile & Misafir Yönetimi" simgesi) → "Yeni Birey / Misafir Davet Et (QR Üret)" (kısa yol: profil → "Hızlı Davet Kodu / QR Üret") → "Erişim Paylaş & Davet Et" penceresi → "Süreli Misafir" sekmesi → "Erişim Süresi Seçin:" altında "4 Saat" (seçenekler "2 Saat", "4 Saat", "8 Saat (Mesai)" [varsayılan], "24 Saat (1 Gün)", "48 Saat (2 Gün)", "72 Saat (3 Gün)"), isteğe bağlı "Misafir / Görevli Adı (İsteğe Bağlı)" → "Geçici Misafir QR'ı Üret".
  - Beklenen: Karekod kendiliğinden çizilir (ayrı "QR Göster" düğmesi yoktur); "GEÇİCİ MİSAFİR KODU" altında `AHBU-` + 10 karakter (büyük harf/rakam); "Son erişim: [tarih saat]" (kod üretildiği andan 4 saat sonra: süre kod üretilince başlar). "Kodu Kopyala & Paylaş" → "Davet kodu (AHBU-…) panoya kopyalandı!".
- [ ] **20.2. Davet Kodu ile Katılım (Geçerli Zaman)**
  - Yapın: Misafir hesabıyla **giriş yaptıktan sonra** (giriş ekranında katılım yoktur): "Kod ile Bir Eve Katıl" (dairesizse) ya da profil → "Başka Bir Eve Katıl (Kod İle)" → "Davet / Devir Kodu" → "Devam" → "Katılımı Onayla" ("Rolünüz: Süreli misafir", "Erişim başlangıcı", "Erişim bitişi") → "Eve Katıl".
  - Beklenen: '"[ev adı]" evine süreli misafir olarak katıldınız.'; daire paneli açılır; profil rozeti "Süreli Misafir". Ev sahibinin "Kayıtlı Kişiler & Yetkiler" listesinde "SÜRELİ MİSAFİR", "[süre] kaldı" ve "Erişim bitişi: …".
  - Olumsuz: Aynı kodu başka bir hesapla tekrar kullanmak → "Geçersiz veya süresi dolmuş kod."
- [ ] **20.3. Davet Kodu Süresi Bitişi**
  - Yapın (a): "2 Saat" seçerek kod üretin, 2 saatten fazla bekleyip yeni bir hesapla bu kodla katılmayı deneyin.
  - Beklenen (a): "Devam" sonrası "Geçersiz veya süresi dolmuş kod."
  - Yapın (b, QA): `qa.misafir.eski@example.com` ile giriş yapın.
  - Beklenen (b): "Erişim süreniz doldu" ekranı ("QA Daire 1 için misafir erişiminiz (…) sona erdi. Cihazları göremez ve kontrol edemezsiniz. …") ve "Daire listesini yenile"; lamba/panjur kartı yoktur.
- [ ] **20.4. QR Kod ile Misafir Daveti**
  - Yapın (gerçek telefon): Misafir hesabında "Karekod Tara (Katıl / Cihaz Eşle)" (dairesizse) ya da üst çubuk "Karekod Tara (Cihaz / Eve Katıl)" → ev sahibinin ekranındaki karekodu okutun (içeriği `AHBU-INVITE:[kod]`) → "Bir Eve Katıl" penceresi kod dolu açılır → "Devam" → "Eve Katıl".
  - Beklenen: 20.2'deki gibi katılım. Giriş ekranında karekod tarayıcı yoktur; önce kayıt olun ya da giriş yapın.
- [ ] **20.5. Oturum İçinde Misafir Süresi Bitişi & Misafir Kısıtları**
  - Beklenen (bitişten önce): Bu sürümde bitişten önce uyarı bandı **gösterilmez**. Misafir oturumunda "Hızlı Senaryolar" ve "Huzur Modu / Gece Kontrolü" bandı görünmez; ⚙ "Cihaz Ayarları"nda "Misafir erişimi: ayarlar salt-okunurdur. …" notu bulunur ve "Çocuk Kilidi" kartı salt okunurdur (23.1); "Aile & Misafir Yönetimi" yoktur.
  - Yapın: Geçerli bir misafir oturumu açıkken süre dolduktan sonra bir işlem yapın (ör. lamba ya da "Yenile"; en kısa seçenek "2 Saat").
  - Beklenen (bitişte): "Erişiminiz sona erdi" penceresi ("[ev adı] için misafir erişim süreniz doldu. …") → "Tamam" → "Erişim süreniz doldu" ekranı. Daire listede kalır ama kontrol edilemez (görünmez olmaz).

---

### AŞAMA 21: Üye Yönetimi & Davet — Kabul, Ret, Çıkarma, İzolasyon
> **Ortam:** QA ya da canlı · **Hesap:** ev sahibi + aile üyesi olacak ikinci hesap; 21.4 için QA'da `qa.sahip1`, `qa.aile`, `qa.misafir` · **Ön koşul:** yok.

- [ ] **21.1. Aile Üyesi Davet**
  - Yapın: "Erişim Paylaş & Davet Et" (20.1'deki yol) → "Aile Bireyi" sekmesi → "Aile Katılım Kodu Üret".
  - Beklenen: Karekod ve "AİLE KATILIM KODU" altında `AHBU-` + 10 karakter; "Son geçerlilik: [tarih saat]". Açıklama: aile bireyine "24 saat geçerli, tek kullanımlık" kod. Üyelik kalıcıdır (misafir gibi süreli değildir) ama **kodun kendisi 24 saat geçerlidir**. Karekod içeriği de `AHBU-INVITE:[kod]` biçimindedir. "Yeni Kod Üret" ile yenilenir.
  - Olumsuz: Aile üyesi ve misafir hesabında profilde "Aile & Misafir Yönetimi" ve davet düğmeleri görünmez.
- [ ] **21.2. Davet Kabul**
  - Yapın: İkinci hesapla "Kod ile Bir Eve Katıl" (ya da profil → "Başka Bir Eve Katıl (Kod İle)") → kod → "Devam" → "Katılımı Onayla" ("Rolünüz: Aile üyesi") → "Eve Katıl".
  - Beklenen: '"[ev adı]" evine aile bireyi olarak katıldınız.'; profil rozeti "Aile Bireyi"; ev sahibinin listesinde "AİLE ÜYESİ".
  - Olumsuz: Kullanılmış kod → "Geçersiz veya süresi dolmuş kod."; zaten üye olan hesap → onay ekranında "Bu dairenin zaten üyesisiniz. Devam etmeniz yeni bir üyelik oluşturmaz ve davet kodu kullanılmaz." ve sonuçta "Zaten bu evin üyesisiniz." (Ayrı bir "sahibin PIN'i ile doğrulama" seçeneği yoktur.)
- [ ] **21.3. Aile Üyesini Çıkarma**
  - Yapın: Ev sahibi: "Aile & Misafir Yönetimi" → "Kayıtlı Kişiler & Yetkiler" listesinde üyenin satırındaki çöp kutusu simgesi ("Yetkiyi İptal Et") → "Üyeyi Evden Çıkar" penceresi (misafirde "Misafir Yetkisini İptal Et") → "Yetkiyi İptal Et".
  - Beklenen: '"[ad]" kullanıcısının yetkisi iptal edildi.' ve üye listeden düşer. Çıkarılan kişinin uygulamasında bir sonraki işlem "Bu daireye erişim yetkiniz bulunmamaktadır." ile reddedilir ve ev listesi yenilenince daire görünmez.
  - Olumsuz: Ev sahibinin kendi satırında ve diğer ev sahiplerinin satırında çöp kutusu simgesi yoktur.
- [ ] **21.4. Rol İzolasyonu Matrisi (CONTRACTS §1.4)**
  - Yapın: "QA Daire 1"de sırayla `qa.sahip1` (sahip), `qa.aile` (aile üyesi), `qa.misafir` (misafir) ile girip aşağıdakileri karşılaştırın.
  - Beklenen: (1) Lamba/panjur komutu: üçünde de çalışır. (2) Toplu komut ("Hızlı Senaryolar", "Hepsini Kapat"): sahip ve aile üyesinde görünür, misafirde görünmez. (3) Çocuk kilidi: sahip ve aile üyesi değiştirebilir; misafirde kart salt okunurdur. (4) Üye davet ("Aile & Misafir Yönetimi"): yalnız sahipte. (5) Zamanlı kurallar (⚙ "Zamanlı Otomasyon Kuralları"): sahip ve aile üyesinde var, misafirde yok.
  - Not: Yetkisiz rolde düğmeler gizli olduğu için sunucunun `403` yanıtı arayüzden üretilemez; sunucu tarafı geliştirici denetimiyle doğrulanır (QA: `node run.js sweep --only flow.idor`; çıktıda `GUVENLIK_IDOR` bulgusu olmamalı).

---

### AŞAMA 22: Daire Devri (Transfer) — Eski Sahibin Erişim Kaybı
> **Ortam:** QA ya da canlı · **Hesap:** ev sahibi + yeni sahip olacak kayıtlı hesap (e-postası bilinen) + mümkünse bir aile üyesi · **Ön koşul:** devir dairedeki TÜM üyelikleri siler; QA'da "QA Daire 1" yerine 11.3'te sahiplendiğiniz daireyi kullanın ya da sonra `node run.js reset` + `up --stage2` yapın.

- [ ] **22.1. Daire Devri Başlatma**
  - Yapın: Ev sahibi: "Aile & Misafir Yönetimi" → "Daireyi Devret (Mülkiyet Transferi)" → "Daire Devri (Mülkiyet Transferi)" penceresi → "Yeni Sahip E-posta / Telefon (Zorunlu)" ("Devri yalnızca bu hesap kabul edebilir. Hesap sahibine kodu güvenli bir kanaldan iletin.") → "48 Saatlik Devir Kodu & QR Üret" → "Daire Devri Onayı" penceresinde `DEVRET` yazın → "Devri Başlat".
  - Beklenen: Karekod ve "DEVİR KODU (48 saat geçerli)" altında `AHBU-TR-` + 16 karakter; "Bu kod yalnızca şimdi gösterilir; sunucuda yalnızca özeti saklanır."; "Yalnızca [hedef] kullanıcısı devralabilir."; "Son geçerlilik: …"; "Devir İşlemini İptal Et" ve "Yeni Devir Başlat (öncekini geçersiz kılar)". Sunucu yeni sahibe e-posta **göndermez**: kodu siz iletirsiniz.
  - Olumsuz: Kendi e-postanız → "Dairenizi kendinize devredemezsiniz."; `DEVRET` yazılmadan "Devri Başlat" pasif kalır.
- [ ] **22.2. Devir Kodu Doğrulama (Kabul)**
  - Yapın: Yeni sahip hesabıyla "Kod ile Bir Eve Katıl" / profil → "Başka Bir Eve Katıl (Kod İle)" (ya da karekodu tarayın) → devir kodu → "Devam" → "Daire Devrini Onayla" ("İşlem: Daire devri (mülkiyet)" ve kırmızı "DİKKAT: Onaylarsanız bu dairenin TEK SAHİBİ siz olursunuz. …") → `DEVRAL` yazın → "Daireyi Devral".
  - Beklenen: '"[daire]" dairesinin sahipliği size devredildi. Önceki sakinlerin bu evdeki tüm erişimleri kaldırıldı.'; yeni sahibin profil rozeti "Ev Sahibi".
  - Olumsuz: Hedef dışı bir hesap kodu girerse "Devam" sonrası "Bu devir kodu hesabınız için geçerli değil."; kodu ikinci kez kullanmak → "Geçersiz veya süresi dolmuş kod."
- [ ] **22.3. Eski Sahibinin Erişim Kaybı**
  - Beklenen: Eski sahibin uygulamasında bir sonraki işlem (ör. lamba) "Bu daireye erişim yetkiniz bulunmamaktadır." ile reddedilir; ev listesi yenilenince daire görünmez.
- [ ] **22.4. Devir Sonrası Diğer Üyeler**
  - Beklenen: Devir kabul edilince eski sahip DAHİL tüm aile üyeleri ve misafirlerin erişimi kalkar (aile üyesinin rolü korunmaz); yeni sahibin "Kayıtlı Kişiler & Yetkiler" listesinde yalnız kendisi kalır. Eski aile üyesinin uygulamasında daire listeden düşer.

---

### AŞAMA 23: Çocuk Kilidi (Child Lock) — 3 Değerli Durum & Çevrimdışı Davranış
> **Ortam:** QA ("QA Daire 1", simülatör `home1`) ya da gerçek pano · **Hesap:** ev sahibi ya da aile üyesi; misafir denemesi için `qa.misafir` · **Ön koşul:** pano çevrimiçi.

- [ ] **23.1. Çocuk Kilidi Anahtarı — Başarılı Komut**
  - Yapın: Üst çubuk ⚙ "Cihaz Ayarları" → "Cihaz & Sistem Ayarları" → "Çocuk Kilidi" kartı (durum "Kilit kapalı: duvar anahtarları serbest") → anahtarı açın.
  - Beklenen: Kısa süre "Uygulanıyor…", sonra "Kilitli: duvar anahtarları devre dışı"; ana ekranda "Kilitli: duvar anahtarları devre dışı. Uygulamadan kontrol edebilirsiniz." notu. Duvar butonu röleyi tetiklemez (QA: `curl.exe -s -X POST http://127.0.0.1:8082/__sim/di/1/press` sonrası röle değişmez); uygulamadan kontrol sürer.
  - Yapın: Anahtarı kapatın → "Çocuk kilidi kaldırılsın mı?" sayfası → biyometrik destekli telefonda "[Parmak İzi / Face ID] ile doğrula", destek yoksa "Kilidi kaldırmak için basılı tutun".
  - Beklenen: "Kilit kapalı: duvar anahtarları serbest".
  - Olumsuz: "Vazgeç (kilitli kalsın)" → kilit kalır; doğrulama başarısızsa "Kimlik doğrulanamadı. Çocuk kilidi kaldırılmadı." Misafirde kart **görünür** ama anahtar pasiftir ve "Bu ayarı yalnızca ev sahibi ve aile üyeleri değiştirebilir." yazar.
- [ ] **23.2. Karışık Durum (İki Pano)**
  - Ön koşul: iki panolu daire (gerçek donanım; QA'daki tek simülatörlü dairede yapılamaz: "yapılamadı" işaretleyin).
  - Beklenen: Panolardan biri kilitli, diğeri kilitsizken kartta "Panolar farklı durumda"; anahtar kapalı konumda ve kullanılabilir görünür, açınca tüm çevrimiçi panolar kilitlenir. Bir pano çevrimdışıyken kilitlemede "Bazı panolar çevrimdışı (N). Kilit, çevrimiçi olunca onlara uygulanır."
- [ ] **23.3. Çevrimdışı Pano — Bekleyen / Bayat Durum**
  - Yapın: Panoyu çevrimdışı yapın (QA: `curl.exe -s -X POST http://127.0.0.1:8082/__sim/offline`; gerçek panoda enerjiyi kesin) → kartı izleyin → anahtara dokunun.
  - Beklenen: Durum bayat gösterilir: "Son bilinen: Kilitli ([saat])" ya da "Son bilinen: Kilit kapalı ([saat])" (durum hiç alınamadıysa "Durum alınamadı. Pano çevrimdışı olabilir." + "Yeniden dene"). Tek panolu dairede anahtara dokunmak "Cihaz çevrimdışı. Komut iletilemedi." + "Tekrar dene" verir; istek kaydedilmez, pano gelince kendiliğinden uygulanmaz. QA'da `curl.exe -s -X POST http://127.0.0.1:8082/__sim/online` sonrası durum tazelenir.
- [ ] **23.4. Biyometrik Kilitle Beraber**
  - Ön koşul: gerçek telefon, biyometrik giriş açık (27.1), çocuk kilidi "Kilitli".
  - Yapın: Uygulamayı arka plana alın, 40 sn bekleyin, geri dönün, biyometrik doğrulamayı yapın.
  - Beklenen: Panel açılır; çocuk kilidi hâlâ "Kilitli: duvar anahtarları devre dışı" (iki özellik birbirinden bağımsızdır).

---

### AŞAMA 24: Gece Huzur Bildirimi / Hatırlatma — Afiş & Saat Seçimi
> **Ortam:** QA ya da canlı · **Hesap:** ev sahibi ya da aile üyesi (misafirde kart yoktur) · **Ön koşul:** pano çevrimiçi. Bu sürümde telefona push bildirimi **gönderilmez**: hatırlatma yalnız uygulama açıkken ya da açıldığında afiş olarak görünür.

- [ ] **24.1. Gece Huzur Bildirimi Varsayılan Açık**
  - Yapın: ⚙ "Cihaz Ayarları" → "Gece Huzur Bildirimi" kartı.
  - Beklenen: Yeni bir dairede durum "Açık • saat 23:30" (sunucu varsayılanı: açık, 23:30); kart metni "Her gece belirlenen saatte açık kalan lamba veya panjur varsa tek bir bildirim alırsınız …" ve "Bu sürümde bildirim telefona gönderilmez; uygulamayı açtığınızda hatırlatma görünür." Anahtar kapatılınca **onay sorulmaz**, durum "Kapalı" olur. (Duvar anahtarlarıyla ilgili ayar çocuk kilididir: Aşama 23.)
- [ ] **24.2. "Hepsini Kapat" Düğmesi (Ayarlar Kartı)**
  - Ön koşul: en az bir lamba açık.
  - Beklenen: Kartta "Şu an evde N lamba açık" ve "Hepsini Kapat"; basınca "N açık lamba için kapatma komutu gönderildi." ve lambalar söner. Lamba açık değilken satır görünmez.
  - Olumsuz: Misafir hesabında kart ve "Hepsini Kapat" görünmez.
- [ ] **24.3. Bildirim Davranışı (Uygulama İçi Afiş)**
  - Yapın: "Bildirim saati"ni 2–3 dk sonrasına ayarlayın, bir lamba açık bırakın (pano çevrimiçi), uygulamayı arka plana alın; saat geçince uygulamayı açın.
  - Beklenen: Arka plandayken telefona sistem bildirimi **gelmez**. Uygulama açılınca "Gece hatırlatması" afişi ("Hepsini kapat" / "Kapat"); kartta "Son hatırlatma: Bugün SS:DD - açık N lamba, M panjur (kapatılmadı)". Afişte "Hepsini kapat" → lambalar kapanır ve satır "(kapatıldı)" olur.
  - Olumsuz: Pano çevrimdışıyken hatırlatma üretilmez (durum bilinmiyor; kartta "Cihaz çevrimdışı; açık lamba bilgisi güncel değil.").
- [ ] **24.4. Saat Dilimi Seçimi — (KALDIRILDI: değiştirme ekranı yok)**
  - Beklenen: Uygulamada saat dilimi seçme/değiştirme ekranı **yoktur**; saat dilimi yalnız gösterilir: ⚙ → "Zamanlı Otomasyon Kuralları" → "Zamanlı Kurallar" sayfasında "Kurallar evinizin saat dilimine göre çalışır: Türkiye saati (Europe/Istanbul, UTC+3)" ve kural penceresinde "Saat, evinizin saat dilimine göre çalışır: …".
- [ ] **24.5. Gece Hatırlatması Saati**
  - Yapın: Kartta "Bildirim saati" satırındaki düğmeye ("Saat Seç" ya da mevcut "SS:DD") dokunun → telefonun saat seçicisinden saat seçin.
  - Beklenen: Durum "Açık • saat SS:DD" olur. Hatırlatma telefonun değil **evin saat diliminde** (varsayılan Europe/Istanbul) değerlendirilir.

---

### AŞAMA 25: Zamanlı Kurallar (Scheduled Rules) — Ekle / Düzenle / Sil & Saat Dilimi
> **Ortam:** QA ya da canlı (bulut modu) · **Hesap:** ev sahibi ya da aile üyesi (misafirde ve servis PIN oturumunda yoktur) · **Ön koşul:** pano çevrimiçi. QA'da `qa.sahip1`'in 4 hazır kuralı vardır ("Aksam lambasi", "Gece kapat", "Hafta ici panjur kapat", "Hafta sonu panjur ac" [kapalı]).

- [ ] **25.1. Kural Oluşturma**
  - Yapın: ⚙ "Cihaz Ayarları" → "Zamanlı Otomasyon Kuralları" ("Işıklar ve panjurlar için otomatik açma/kapama saatleri belirleyin") → "Zamanlı Kurallar" sayfası → sağ üstteki "+" ("Yeni Kural Ekle"; boş listede "İlk Kuralı Ekle") → "Yeni Kural Ekle" penceresi: "Kanal" (ör. "Salon Aydınlatma"), "Eylem" ("Aç" / "Kapat"), "Saat" (2–3 dk sonrası), "Günler" ("Pzt" … "Paz"), "Etiket (opsiyonel)" (ör. *Sabah Işıkları*) → "Ekle".
  - Beklenen: "Kural eklendi"; kartta etiket, "Röle N • Aç", saat ve günler, anahtar açık. Saat gelince ilgili lamba kendiliğinden yanar.
  - Olumsuz: Aynı kanal ve saatte ters eylemli ya da aynı kural varsa uyarı çıkar ve düğme "Yine de Kaydet" olur.
- [ ] **25.2. Kural Düzenleme**
  - Yapın: Kart üzerindeki ⋮ ("[başlık] kuralı işlemleri") → "Düzenle" → "Kural Düzenle" → saati değiştirin → "Güncelle".
  - Beklenen: "Kural güncellendi"; kural yeni saatte çalışır.
  - Not: Başka bir evin kuralını düzenleme denemesi arayüzden yapılamaz (yalnız kendi dairenizin kuralları listelenir); sunucu tarafı 21.4'teki geliştirici denetimine dahildir.
- [ ] **25.3. Kural Silme**
  - Yapın: ⋮ → "Sil" → "Kural silinsin mi?" ("[ad] → [eylem] ([saat]) kuralı silinecek.") → "Sil".
  - Beklenen: "Kural silindi"; kart listeden düşer ve kural saati gelince çalışmaz. "İptal" seçilirse kural kalır.
- [ ] **25.4. Çoklu Kural & Saat Dilimi Tutarlılığı**
  - Not: Ev saat dilimi uygulamadan değiştirilemez (24.4); "Europe/London'a değiştir" adımı yapılamaz.
  - Yapın: İki kural (ör. 07:30 ve 19:00) oluşturun; isteğe bağlı olarak telefonun saat dilimini değiştirip listeye bakın.
  - Beklenen: Kart saatleri aynen kalır (07:30 / 19:00) ve kurallar evin saat diliminde ("Türkiye saati (Europe/Istanbul, UTC+3)") çalışır.
- [ ] **25.5. Kural Durumu — Aktif/Devre Dışı**
  - Yapın: Kart üzerindeki anahtarı kapatın.
  - Beklenen: Kart soluklaşır; kural saati gelince komut gönderilmez. Anahtar açılınca yeniden çalışır.

---

### AŞAMA 26: Hesap Güvenliği — Şifre, Kod (OTP), Zorunlu Değiştirme
> **Ortam:** QA ya da canlı · **Hesap:** e-posta+şifreli bir müşteri hesabı; 26.1 ve 26.5 için aynı hesap iki cihazda açık (ör. emülatör + Windows/Chrome) · **Ön koşul:** e-postaya erişim (QA: `node run.js mails`). Profil = sağ üstteki avatar ("Kullanıcı Profili & Oturum").

- [ ] **26.1. Şifre Değiştirme**
  - Yapın: Profil → "Şifreyi Değiştir" → "Şifre Değiştir" sayfası ("Şifrenizi değiştirdiğinizde diğer tüm cihazlardaki oturumlarınız kapatılır.") → "Mevcut Şifre", "Yeni Şifre (En az 10 karakter)", "Yeni Şifre Tekrar" → "Şifreyi Değiştir".
  - Beklenen: "Şifreniz değiştirildi. Diğer cihazlardaki oturumlar kapatıldı."; bu cihaz oturumda kalır. Diğer cihazda bir sonraki işlemde açık sayfalar kapanır ve giriş ekranında "Oturumunuz sona erdi. Lütfen tekrar giriş yapın." + "Tamam" görünür.
  - Olumsuz: Yanlış mevcut şifre → alanın altında "Mevcut şifre hatalı."; yeni şifre eskisiyle aynı → "Yeni şifre mevcut şifreyle aynı olamaz"; 9 karakter → "Şifre en az 10 karakter olmalıdır"; tekrar uyuşmazsa "Şifreler eşleşmiyor".
- [ ] **26.2. Zorunlu Şifre Değiştirme**
  - Ön koşul: Süper yönetici bir hesabı "Geçici parola (isteğe bağlı)" alanını doldurarak (en az 10 karakter) açar ya da mevcut hesapta "Düzenle" → "Yeni parola (değiştirmeyecekseniz boş bırakın)" ile parola verir. QA'da `qa.servis@example.com` bu durumda gelir. (Etkinleştirme e-postasıyla şifresini kendisi belirleyen hesapta zorunlu değişim **olmaz**.)
  - Yapın: Bu hesapla giriş yapın.
  - Beklenen: Panel yerine "Şifrenizi Değiştirin" sayfası: "Güvenliğiniz için devam etmeden önce size verilen geçici şifreyi değiştirmeniz gerekiyor.", alanlar "Geçici / Mevcut Şifre", "Yeni Şifre (En az 10 karakter)", "Yeni Şifre Tekrar", düğme "Şifreyi Değiştir", sağ üstte "Çıkış"; geri tuşu sayfayı kapatmaz. Değiştirince panel açılır.
  - Olumsuz: Değiştirmeden "Çıkış" yapıp tekrar girince aynı sayfa yine gelir. (QA: `qa.servis` şifresini değiştirirseniz `node run.js accounts` eskisini göstermeye devam eder; yeni şifreyi not edin, tohumu tazelemek için `node run.js reset` + `up --stage2`.)
- [ ] **26.3. Şifremi Unuttum / Kod (OTP)**
  - Yapın: Giriş ekranında "Şifremi Unuttum" → "Şifre Yenileme" penceresi → "E-posta veya Telefon" → "Kod Gönder".
  - Beklenen: Sunucu iletisi "Eğer kayıtlı bir hesap varsa şifre sıfırlama kodu gönderildi." (kayıtlı olmayan adres için de aynı ileti); "Kod geçerlilik süresi: …" (15 dk); "Kodu Tekrar Gönder" 60 sn geri sayımla pasif ("Kodu Tekrar Gönder (0:59)"). QA'da kod `node run.js mails` → "Şifre sıfırlama kodu" e-postasında.
  - Olumsuz: Bir saatte 5'ten fazla kod istenirse "Bir saat içinde çok fazla kod istendi. Lütfen daha sonra tekrar deneyin."
- [ ] **26.4. Kodla Şifre Sıfırlama**
  - Yapın: "6 Haneli Kurtarma Kodu", "Yeni Şifre (En az 10 karakter)", "Yeni Şifre Tekrar" → "Şifreyi Yenile".
  - Beklenen: "Şifreniz yenilendi ve oturumunuz açıldı." ve doğrudan panel (giriş ekranına dönülmez); diğer cihazlardaki oturumlar kapanır.
  - Olumsuz: Yanlış kod → "Hatalı kod. Kalan deneme: 4." ve "Kalan deneme hakkı: 4"; 5 hatalı denemeden sonra "Çok fazla hatalı deneme yapıldı. 60:00 sonra yeni kod isteyin."; süresi dolmuş (15 dk) ya da kullanılmış kod → "Geçersiz veya süresi dolmuş kod."; şifreler farklı → "Girdiğiniz şifreler birbiriyle uyuşmuyor".
- [ ] **26.5. Tüm Cihazlardan Çıkış (Logout All)**
  - Yapın: Profil → "Tüm Cihazlardan Çıkış Yap" → "Tüm Cihazlardan Çıkış" ("Bu hesabın tüm cihazlardaki oturumları kapatılacak ve bu cihazdan da çıkış yapılacak. Devam edilsin mi?") → "Tümünden Çık".
  - Beklenen: Bu cihaz giriş ekranına döner; ikinci cihazda bir sonraki işlemde giriş ekranı ve "Oturumunuz sona erdi. Lütfen tekrar giriş yapın." (sunucu diğer oturumları `401 INVALID_TOKEN` ile reddeder).

---

### AŞAMA 27: Biyometrik Kilit (Biometric Auth) — 30+ Sn & Arka Plan
> **Ortam:** gerçek Android telefon (parmak izi ya da yüz tanımlı); emülatörde, Windows'ta ve Chrome'da sınanmaz · **Hesap:** herhangi bir giriş yapılmış hesap · **Ön koşul:** yok.

- [ ] **27.1. Biyometrik Kilit Etkinleştirme**
  - Yapın: ⚙ "Cihaz Ayarları" → "[Face ID / Parmak İzi / Biyometrik Giriş] Girişi" kartı ("Açılışta Parmak İzi ile anında giriş yapın") → anahtarı açın → sistem doğrulaması. (Girişten sonra "[etiket] Kullanılsın mı?" penceresi de çıkabilir: "Daha Sonra" / "Evet, Etkinleştir".)
  - Beklenen: Anahtar açık kalır. Kapatırken de doğrulama istenir.
  - Olumsuz: Doğrulamayı iptal edince "Kimlik doğrulanamadı. Biyometrik giriş açılmadı." (kapatırken "Kimlik doğrulanamadı. Biyometrik giriş açık kalıyor."). Biyometrik donanımı/kaydı olmayan cihazda kart görünür ama anahtar pasiftir: "Cihazınızda biyometrik donanım bulunamadı".
- [ ] **27.2. Arka Plandan Kilit (≥30 sn)**
  - Yapın: Uygulamayı arka plana alın, en az 30 sn (ör. 35 sn) bekleyin, geri dönün.
  - Beklenen: Kilit ekranı gelir ve sistem doğrulaması kendiliğinden başlar; başarıda panel açılır. 30 sn'den kısa sürede dönünce kilit sorulmaz.
- [ ] **27.3. Biyometrik Başarısızlığı (Yeniden Deneme)**
  - Yapın: Doğrulamayı iptal edin ya da yanlış parmak kullanın.
  - Beklenen: "[etiket] doğrulaması tamamlanamadı." + "[etiket] ile Aç" (yeniden dener) + "Şifre ile Giriş Yap" (→ "Çıkış Yapılsın mı?" onayı → giriş ekranı). "3 başarısız denemede şifreye düşme" sayacı yoktur.
- [ ] **27.4. Kilit Zaman Ayarı — (KALDIRILDI: ayar yok)**
  - Beklenen: Ayarlanabilir "Kilit Zamanı" seçeneği **yoktur**; kilit eşiği sabit 30 sn'dir (27.2).

---

### AŞAMA 28: Hesap Silme (Account Deletion) — SOLE_OWNER Kontrolü
> **Ortam:** QA ya da canlı · **Hesap:** müşteri hesabı (servis sorumlusu ve süper yönetici hesaplarında "Hesabımı Sil" görünmez) · **Ön koşul:** 28.2 için tek sahibi olunan bir daire (QA: `qa.sahip1`); 28.3 için yalnız bu test için açılmış, sahibi olduğu dairesi olmayan bir hesap (ör. 11.1'deki).

- [ ] **28.1. Hesap Silme Başlatma**
  - Yapın: Profil → "Hesabımı Sil" → "Hesabı Sil" penceresi ("Hesabınız, kişisel verileriniz ve bu hesaba bağlı tüm oturumlarınız kalıcı olarak silinir. Bu işlem geri alınamaz.") → "Şifreniz" ("Google, Apple veya SMS ile giriş yapıyorsanız boş bırakın.") → "Onaylamak için SİL yazın:" alanına `SİL`.
  - Beklenen: "Hesabı Kalıcı Olarak Sil" yalnız `SİL` yazılınca etkinleşir. E-posta yazarak doğrulama, onay e-postası, bağlantı ya da kod adımı **yoktur**.
  - Olumsuz: Yanlış şifre → "Şifre hatalı."; şifreli hesapta şifre boş → "Hesabı silmek için mevcut şifrenizi girin."
- [ ] **28.2. SOLE_OWNER Kontrolü**
  - Yapın: Tek sahibi olduğunuz dairesi olan hesapla 28.1'i doğru şifreyle tamamlayın.
  - Beklenen: "Hesabınızı silmeden önce aşağıdaki dairelerin sahipliğini devretmelisiniz; aksi halde bu dairelerin kontrolü kimsede kalmaz. Hiçbir şey silinmedi."; her daire için ad, "N diğer üye · N pano" ve "Devret" (devir penceresi açılır: Aşama 22); alt düğmeler "Kapat" ve "Tekrar Dene". Hesap silinmez.
- [ ] **28.3. Silme Onayı**
  - Yapın: Sahibi olduğu dairesi olmayan hesapla 28.1 → "Hesabı Kalıcı Olarak Sil".
  - Beklenen: "Hesabınız silindi." ve giriş ekranı. Aynı e-posta ve şifreyle giriş → "Geçersiz e-posta / telefon veya şifre."; aynı e-postayla "Kayıt Olun" ile yeni (boş) hesap açılabilir.
- [ ] **28.4. Silme Sonrası Üyelikler**
  - Beklenen: Silinen kullanıcının üyelikleri kalkar: üyesi olduğu dairenin sahibinin "Kayıtlı Kişiler & Yetkiler" listesinde artık görünmez; dairenin diğer üyeleri kontrol etmeye devam eder. (Tek sahip silinemediği için "sahibi silinmiş daire" durumu oluşmaz: 28.2.)

---

### AŞAMA 29: Yerel (LAN) Doğrudan Modu — Cihaz Anahtarı, IP, X-Device-Key
> **Ortam:** gerçek pano + telefon aynı ev Wi-Fi'sinde (debug derleme; release derlemede ham LAN IP'siyle düz HTTP engellenir) ya da QA ("QA Daire 1", simülatör `home1`; emülatörde adres `10.0.2.2:8082`) · **Hesap:** ev sahibi, aile üyesi ya da servis sorumlusu (misafirde bu araçlar yoktur) · **Ön koşul:** bulut modunda giriş yapılmış.

- [ ] **29.1. Cihaz Anahtarı (Yerel Anahtar)**
  - Beklenen: Uygulama anahtarı **göstermez** ve kopyalatmaz ("Yerel Anahtarı Göster" yoktur). Yetkili rolde (sahip, aile üyesi, servis) anahtar gerektiğinde sunucudan kendiliğinden alınıp telefonun güvenli deposuna yazılır. ⚙ "Cihaz Yerel Adresi (IP)" kartında "Cihaz anahtarı kayıtlı" (ya da "Cihaz anahtarı kayıtlı değil") yazar; elle girmek için "Cihaz anahtarı (8–32 karakter)" → "Anahtarı Kaydet" → "Cihaz anahtarı kaydedildi."
  - Olumsuz: Misafirde bu kart ve mod simgesi görünmez; süper yönetici anahtarı sunucudan alamaz.
- [ ] **29.2. Cihaz IP Adresi Ayarı**
  - Yapın: ⚙ → "Cihaz Yerel Adresi (IP)" → "Cihaz adresi" (ipucu "Örn: 192.168.1.20 veya 192.168.4.1") alanına panonun LAN adresini yazın (QA emülatörü: `10.0.2.2:8082`) → "Adresi Kaydet".
  - Beklenen: "Adres kaydedildi. Yerel ağ moduna geçtiğinizde kullanılacak."; çipler "192.168.4.1 (kurtarma ağı)" ve biliniyorsa "Son bilinen: [IP]".
  - Olumsuz: İnternet adresi (ör. `8.8.8.8`) → "Geçersiz cihaz adresi."; boş → "Cihaz adresini girin (örn. 192.168.1.20)."
- [ ] **29.3. Yerel Moda Geçiş & X-Device-Key**
  - Yapın: Üst çubuk "Bulut Modu (yerel moda geç)" (dar ekranda ⋮ "Diğer işlemler" içinde) → bir lambayı açıp kapatın; ⚙ kartındaki düğme artık "Kaydet ve Bağlan".
  - Beklenen: "Yerel ağ moduna geçildi"; başlık altı "Sistem Hazır • Yerel Ağ ([adres])"; komutlar panoya doğrudan (anahtarla) gider. "Kaydet ve Bağlan" → "Cihaza bağlanıldı ([adres])." Geri dönmek için "Yerel Ağ Modu (buluta geç)" → "Bulut moduna geçildi".
  - Olumsuz: Anahtar yoksa ya da yanlışsa rozet "Cihaz anahtarı gerekli" ve "Cihaz anahtarı gerekli. Anahtarı girin veya hesabınızla giriş yapın." (pano anahtarsız/yanlış anahtarlı isteğe `401 {"error":"unauthorized"}` döner; 5 hatalı denemeden sonra 60 sn `423` kilidi). Anahtar değeri sunucuya ya da ekrana yazılmaz.
- [ ] **29.4. Onay Gelmezse Geri Alma (2,5 sn)**
  - Yapın (QA): Komutları sessizce düşürün: `Invoke-RestMethod -Method Post -Uri http://127.0.0.1:8082/__sim/slow -ContentType 'application/json' -Body '{"drop":true}'` → bir lambaya dokunun → sonra `Invoke-RestMethod -Method Delete -Uri http://127.0.0.1:8082/__sim/slow` ile geri alın. (Gerçek panoda tetiklemek zordur: "yapılamadı" işaretleyebilirsiniz.)
  - Beklenen: Lamba yaklaşık 2,5 sn sonra eski durumuna döner ve "Cihazdan onay alınamadı. İşlem geri alındı; durum yeniden kontrol ediliyor." + "Tekrar dene" görünür. Bulut ile yerel mod arasında **otomatik geçiş yoktur** (geçiş elle yapılır); ev internetsizken yerel mod çalışmaya devam eder.

---

### AŞAMA 30: Derin Bağlantı (Deep Link) — Bağlantıyla Giriş & QR Yönlendirme
> **Ortam:** gerçek Android telefon (bağlantıya dokunma ve kamera için); kopyala-yapıştır yolu her ortamda · **Hesap:** e-postasına erişilen bir müşteri hesabı · **Ön koşul:** özel bir `ahbu://` şeması **yoktur**; bağlantılar `https://evotomasyon.gudeteknoloji.com.tr/...` biçimindedir (QA e-postalarında da bu alan adı görünür; uygulama belirteci bağlı olduğu sunucuya gönderir).

- [ ] **30.1. Şifre Sıfırlama Derin Bağlantısı**
  - Yapın: "Şifremi Unuttum" → "Kod Gönder" ile gelen e-postadaki `https://evotomasyon.gudeteknoloji.com.tr/reset-password#token=…` bağlantısına telefonda dokunun; uygulama açılmazsa bağlantıyı kopyalayıp giriş ekranında "E-postadaki Bağlantım Var" → yapıştırın → "Devam".
  - Beklenen: "Yeni Şifre Belirle" sayfası: "Yeni Şifre", "Yeni Şifre Tekrar" → "Şifreyi Yenile" (kod alanı yoktur) → oturum açılır. Bağlantıya dokunmak uygulama yerine tarayıcıyı açabilir: Android App Links doğrulama dosyası (`assetlinks.json`) henüz yayınlanmadı (DOĞRULANMADI; bilinen sınır).
  - Olumsuz: Kullanılmış ya da süresi dolmuş bağlantı (sıfırlama 15 dk, etkinleştirme 72 saat) → "Bu bağlantının süresi dolmuş veya daha önce kullanılmış. Yeni bir bağlantı isteyin."; belirteci `?token=` ile taşıyan bağlantı → "Bağlantı geçersiz biçimde."; başka alan adı → "Bu bağlantı tanınan bir sunucuya ait değil."
- [ ] **30.2. Bağlantıyla Giriş (Magic Login)**
  - Not: Sunucu e-postalarda ayrı bir "magic-login" bağlantısı **üretmez**; normal kullanıcı akışında bu madde yoktur. Uygulama `https://evotomasyon.gudeteknoloji.com.tr/magic-login#token=…` biçimini tanır (sunucu "Şifremi Unuttum" belirtecini bu uçta da kabul eder).
  - Yapın (isteğe bağlı istemci denemesi): Yeni bir "Şifremi Unuttum" e-postasındaki bağlantıda `/reset-password` kısmını `/magic-login` yapın → "E-postadaki Bağlantım Var" → yapıştırın → "Devam".
  - Beklenen: "Bağlantıyla Giriş" sayfası, "Giriş yapılıyor..." ve ardından panel (şifre değişmez). Cihazda başka hesap açıksa önce "Bu cihazda şu anda başka bir hesap açık. …" ve "Bu Bağlantıyla Giriş Yap".
  - Olumsuz: Aynı bağlantı ikinci kez → "Bu bağlantının süresi dolmuş veya daha önce kullanılmış. Yeni bir bağlantı isteyin." + "Giriş Ekranına Dön".
- [ ] **30.3. QR Yönlendirme**
  - Yapın: Giriş yaptıktan **sonra** (giriş ekranında karekod tarayıcı yoktur) üst çubuk "Karekod Tara (Cihaz / Eve Katıl)" (dairesiz kullanıcıda "Karekod Tara (Katıl / Cihaz Eşle)") ile sırayla okutun: (a) davet/devir karekodu, (b) pano etiketinin 1. karekodu (`https://evotomasyon.gudeteknoloji.com.tr/claim?uid=…&pin=…`), (c) Wi-Fi karekodu (etiketin 2. karekodu dahil), (d) rastgele bir karekod ya da yalnız `AHBU-S3-…` metni.
  - Beklenen: (a) "Bir Eve Katıl" penceresi kod dolu açılır; (b) "Cihaz Eşleştirme" penceresi UID/PIN dolu açılır (eşleme yetkisi olmayan hesapta "Bu hesapla cihaz eşleştiremezsiniz."); (c) 'Bu bir Wi-Fi karekodu. Wi-Fi kurulumu için "Wi-Fi Kurulum & Kurtarma Sihirbazı"nı kullanın.'; (d) "Geçersiz karekod formatı. Lütfen bilgileri kontrol edin." (tarayıcı açık kalır).

---

### AŞAMA 31: Dayanıklılık — Belirteç Yenileme, MQTT Yeniden Bağlanma, Oturum Bitişi
> **Ortam:** QA ya da canlı · **Hesap:** müşteri hesabı; 31.4 için ayrıca süper yönetici · **Ön koşul:** telefonun saatini **değiştirmeyin**: belirteç ve misafir süreleri sunucu saatiyle denetlenir, telefon saati sunucu davranışını değiştirmez.

- [ ] **31.1. Erişim Belirtecinin Süresi Dolması & Otomatik Yenileme**
  - Yapın: Giriş yapın, uygulamayı açık bırakın; en az 16 dk sonra (erişim belirteci 15 dk geçerlidir) bir lambayı açın.
  - Beklenen: Komut yeniden giriş istemeden çalışır (uygulama arka planda belirteci yeniler ve isteği bir kez tekrarlar); kullanıcı hata görmez.
- [ ] **31.2. Oturumun Sona Ermesi**
  - Not: 30 günlük yenileme belirtecinin dolmasını beklemek pratik değildir; aynı davranışı sunucu tarafında oturumu kapatarak deneyin.
  - Yapın: Aynı hesap iki cihazda açıkken birinde "Tüm Cihazlardan Çıkış Yap" (26.5) ya da "Şifreyi Değiştir" (26.1); diğer cihazda bir işlem yapın.
  - Beklenen: Diğer cihazda açık sayfalar kapanır, giriş ekranında "Oturumunuz sona erdi. Lütfen tekrar giriş yapın." + "Tamam".
- [ ] **31.3. MQTT Yeniden Bağlanma (Üstel Bekleme)**
  - Yapın (QA): Uygulama "QA Daire 1"de açıkken `node run.js down` → bekleyin → `node run.js up --stage2 --keep-secrets --no-seed` (daha önce `--public-host 127.0.0.1` kullandıysanız onu da ekleyin; `--keep-secrets` oturumu korur, `--no-seed` kuralları çoğaltmaz).
  - Beklenen: Yığın kapalıyken başlık altı canlı izlemenin koptuğunu gösterir (ör. "Canlı izleme kesik" / "Bulut • son bilinen durum"); yığın dönünce uygulama kendiliğinden yeniden bağlanır (bekleme 2 → 4 → 8 → 16 → 32 → en çok 60 sn, ±%20) ve en geç ~1 dk içinde "Sistem Hazır • Bulut" olur.
- [ ] **31.4. Oturum Bitti Uyarısı (Hesap Dondurma)**
  - Yapın: Müşteri uygulamada açıkken süper yönetici "Servis Yönetimi" → o hesabın kartında "Dondur" → "Hesap dondurulsun mu?" → "Dondur".
  - Beklenen: Müşterinin uygulamasında bir sonraki işlemde açık sayfalar kapanır ve giriş ekranında satır içi uyarı "Oturumunuz sona erdi. Lütfen tekrar giriş yapın." + "Tamam" görünür (ayrı bir "Oturumunuz Sona Erdi" penceresi ve "Giriş Yap" düğmesi yoktur). Yeniden giriş denemesi → "Hesabınız askıya alınmış. Destek ile iletişime geçin." Sonra süper yönetici "Aktifleştir" ile hesabı açar.
- [ ] **31.5. Ağ Kesintisi & Hata Mesajları**
  - Yapın: Telefonun ağını kesin (uçak modu; QA'da alternatif `node run.js down`) → bir lambaya dokunun → ağı geri açın.
  - Beklenen: Anahtar eski hâline döner ve "Sunucuya ulaşılamadı. İşlem geri alındı." (yanıt hiç gelmezse "Sunucudan yanıt alınamadı. İşlem geri alındı.") + "Tekrar dene" (yaklaşık 8 sn görünür). Ağ dönünce komut kendiliğinden tekrarlanmaz; "Tekrar dene"ye basınca gönderilir. Ana ekranda "Çevrimdışısınız. Kayıtlı daireler gösteriliyor; durum güncel olmayabilir." bandı görünebilir.

---

### AŞAMA 32: Servis PIN'i (Geçici Servis Oturumu) & Yetki Sınırları
> **Ortam:** QA ya da canlı · **Hesap:** ev sahibi (PIN üretir) + ikinci cihazda giriş yapmamış uygulama (teknisyen) · **Ön koşul:** bulut modu. QA'da "QA Daire 1" için hazır PIN'i `node run.js accounts` → "SERVIS PIN" verir (üretildiği `up`'tan itibaren 2 saat geçerli).

- [ ] **32.1. Servis PIN'i Üretme**
  - Yapın: Ev sahibi: ⚙ "Cihaz Ayarları" → "Yetkili Servis İçin Geçici PIN" → "6 Haneli Servis PIN'i Üret".
  - Beklenen: "Servis PIN'i: 1 2 3 4 5 6" biçiminde PIN, "Kalan süre …" (2 saat), "Bu PIN yalnızca şimdi gösterilir. …" ve "PIN'i gizle". Yeniden üretmek "Yeni PIN üretilsin mi?" → "Yeni PIN Üret" ile önceki PIN'i iptal eder.
  - Olumsuz: Aile üyesi, misafir ve servis hesaplarında bu kart görünmez.
- [ ] **32.2. PIN ile Servis Oturumu**
  - Yapın: İkinci cihazda giriş ekranı → "Yetkili Servis Girişi (PIN)" → "Yetkili Servis Girişi" penceresi → PIN ve "Adınız Soyadınız (isteğe bağlı)" → "Doğrula".
  - Beklenen: Yalnız o dairenin paneli açılır; profil rozeti "Servis Oturumu (PIN)" ve "Oturum Süresi"; üst çubukta "Servis Modu (devreye alma)" simgesi → "Servis Paneli"nde 'Geçici servis oturumunda cihazı müşteriye bağlama (claim) yapılamaz; yalnızca bu dairedeki panoda çalışabilirsiniz.'; çıkış düğmesi "Servis Oturumunu Kapat". Ev sahibinin kartında "Açık servis oturumları" altında teknisyen adı ve "Bitiş …".
  - Olumsuz: Aynı PIN'i ikinci kez kullanmak, yanlış ya da süresi dolmuş PIN → "Geçersiz, kullanılmış veya süresi dolmuş servis PIN kodu. Ev sahibinden yeni kod isteyin."
- [ ] **32.3. Servis Erişimini Kapatma & Süre Bitişi**
  - Yapın: Ev sahibi kartta "Servis erişimini kapat" → "Servis erişimi kapatılsın mı?" → "Erişimi Kapat".
  - Beklenen: "Servis erişimi kapatıldı: N PIN ve M oturum iptal edildi."; teknisyenin uygulamasında bir sonraki işlemde oturum biter. Süre (2 saat) dolduğunda giriş ekranında "Servis oturumunuzun süresi doldu. Yeni bir servis PIN'i gerekir." görünür.
- [ ] **32.4. Kurulum PIN'i Kilidi (Yanlış PIN)**
  - Yapın: Stokta bir pano için (QA: `AHBU-S3-0A0003`) dairesiz bir hesapta "Cihaz Kodunu Elle Gir" → "Cihaz Eşleştirme" → doğru UID ile 5 kez yanlış "Kurulum PIN Kodu (6 Hane)" → "Eşle & Sahiplen". (Servis sihirbazında aynı deneme Adım 2'ye yanlış PIN yazıp Adım 4'te "Daireye Bağla" ile yapılır.)
  - Beklenen: "Cihaz Eşleştirme" penceresinde her hatada "Bu işlem için yetkiniz yok veya bu cihazı eşleştiremezsiniz." (kalan hak bu pencerede gösterilmez; sihirbazda ise "Kurulum PIN'i hatalı" ve "Geçersiz kurulum PIN kodu. Kalan deneme hakkı: N"). 5. hatadan sonra pencerede "Çok fazla hatalı PIN denemesi yapıldı; bu cihaz geçici olarak kilitlendi. … sonra tekrar deneyin." ve düğme "Bekleyin (mm:ss)" ile yaklaşık 15 dk pasif (sihirbazda "Cihaz geçici olarak kilitlendi"). Kilit sürerken doğru PIN de kabul edilmez.
- [ ] **32.5. Başka Evin Verisine Erişim (IDOR)**
  - Yapın: `qa.sahip2@example.com` ile girin.
  - Beklenen: Ev listesinde yalnız "QA Daire 2 (baska ev)" vardır; "QA Daire 1"in cihazları, kuralları ve üyeleri hiçbir ekranda görünmez. Sunucunun başka evin uçlarına `403/404` döndüğü geliştirici denetimiyle doğrulanır (QA: `node run.js sweep --only flow.idor`; `GUVENLIK_IDOR` bulgusu olmamalı).

---

## 📌 Ek Bilgi: Açık Konular & Bilinen Sınırlar

### Bu sürümde değişenler (özet)
- Arayüz yeniden yazıldığı için tüm maddeler güncellendi ve tüm kutular sıfırlandı; madde numaraları korundu.
- Kaldırılan eski öğeler: "Karekod ile Pano Eşle", "Eşle ve Daireye Ata", "Servis Modu (Cihaz Kurulumu & Kalibrasyon)", "Panoya Senkronize Et", "Devreye Almayı Onayla ve Müşteriye Teslim Et", "Canlı Röle & Buton Test Konsolu", "Tümünü Doğrula", "Aktif Çalışma Panosu", konsoldaki altyapı (port) satırı, "Sorumlu Ekle" / "Sorumlular" sekmesi. Yerlerine 10 adımlı kurulum sihirbazı (Aşama 5–7; ayrıntı 13, 17, 18) ve "Servis Yönetimi" / "Servis ve Saha Konsolu" sayfaları geldi.
- "(KALDIRILDI)" işaretli maddeler (6.2, 6.4, 24.4, 27.4) uygulamada karşılığı olmayan eski isteklerdir; yalnız "yokluk" doğrulanır.
- Yeni: Aşama 32 (servis PIN'i, kurulum PIN'i kilidi, başka evin verisine erişim).

### Doğrulanmayanlar & bilinen sınırlar
- **Gerçek donanım:** firmware v1.1.0 hiçbir karta yazılıp denenmedi (Aşama 4.5, 6–7 ve 16'nın donanım kısmı sahada doğrulanacak).
- **16.11 / 16.10:** Android'de mobil veri açıkken pano ağına bağlanma yalnız sahte kanalla sınandı; gerçek telefonda DOĞRULANMADI. iOS bu turda kapsam dışı.
- **Push bildirimi yok:** gece hatırlatması yalnız uygulama açıkken ya da açıldığında afiş olarak görünür; uygulama kapalıyken bildirim düşmez (24.3).
- **Derin bağlantılar:** `assetlinks.json` / Associated Domains yayınlanmadı; e-postadaki bağlantıya dokunmak uygulama yerine tarayıcıyı açabilir (30.1). Kopyala-yapıştır yolu ("E-postadaki Bağlantım Var") çalışır.
- **Kanal adı/oda düzenleme** ve **ev saat dilimi değiştirme** ekranı yok (6.2, 24.4, 25.4).
- **Etkinleştirme e-postasındaki 6 haneli kod** uygulamaya doğrudan girilemez; kodla etkinleştirme "Şifremi Unuttum"un gönderdiği yeni kodla yapılır (3.1).
- **"Cihaz Eşleştirme" penceresi** yanlış kurulum PIN'inde kalan hakkı göstermez, genel "Bu işlem için yetkiniz yok veya bu cihazı eşleştiremezsiniz." iletisini verir (32.4; sihirbazda doğru ileti var).
- **QA yığını:** gerçek EMQX/TLS değildir; yerel e-postalar quoted-printable kodlu görünebilir; `reset` yapılmadan tekrarlanan `up --stage2` zamanlı kuralları çoğaltır. Emülatörde sihirbaz Adım 6'nın `10.0.2.2:8081` adresiyle tamamlanması DOĞRULANMADI (6.1).
- **Canlı sunucu:** dağıtılmadı; canlı maddeler dağıtım + migration 001–030 sonrasında yapılabilir.

### Ortam özeti
- Yalnız gerçek donanım/telefon: 4.5–4.8, 13.2, 14.x (kamera), 16.x, 23.2, 23.4, 27.x, 30.1 (bağlantıya dokunma), 30.3.
- QA yığınında yapılabilir: 1–3, 5–10 (simülatörle), 11–12, 13.1/13.3/13.4, 15, 17–22, 23.1/23.3, 24–26, 28–29, 31–32.

---

**Güncelleme Tarihi:** 2026-10-02  
**Kapsam:** AŞAMA 1–32 (+ 4.5)  
**Durum:** Kodla karşılaştırılarak güncellendi; uygulama bu metinle çalıştırılarak denenmedi  
**Sonraki Adım:** Başlangıç Bilgileri'ndeki ortamı hazırlayın ve aşamaları sırayla deneyin (kutuları `[x]` yapın)
