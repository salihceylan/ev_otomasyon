# AHBU Ev Otomasyonu — Fabrika / Servis Aracı Kullanım Rehberi

**Kimler için:** Fabrikada yeni röle/pano kartlarını hazırlayan personel (**süper kullanıcı**) ve site/şablon/karta yazım işini
yapan **servis sorumlusu**. Teknik bilgi gerekmez; adımları sırayla uygulamanız yeterlidir.
Teknik ayrıntılar (kurulum, ortam değişkenleri, seri komutlar, derleme, testler) en sonda "Teknik Ek" bölümündedir.

> **Güncel durum (2026-10-09):** 1. sekmede seçili firmware `version_info.json`'a göre **v1.3.2**'dir (v1.3.1'in üstüne: bulut
> sunucu kilidi, rölelerde sabit görev olmayan fabrika ayarı, açılış çökmesi düzeltmesi; ayrıntı `firmware_releases/v1.3.2/SURUM_NOTLARI.md`).
> v1.3.2 kartta denendi: 12 açılışta çökme yok, Wi-Fi ve bulut bağlantısı tamam. v1.3.1 de kartta denenmişti (açılış, Wi-Fi, bulut,
> anahtar izi eşleşmesi) ama açılışta ara sıra çöküyordu: kurulu kartları v1.3.2 uygulama imajıyla güncelleyin. Ethernet kablosu ve
> panonun kendi bulut kimliği (bootstrap) gerçek kabloyla henüz denenmedi. Ethernet, şablon
> yazımı ve bireysel sahiplenme için kartta v1.3.0+ gerekir. Kartta daha yeni bir sürüm çalışırken eski bir imaj (ör. v1.2.1)
> seçilirse araç sormadan yazmaz: **"Güncelle (ayarlar korunur)"** kipinde **"Sürüm Düşürme Engellendi"** der (Gözat... ile v1.3.0+
> uygulama imajını seçin: `v1.3.1\app_0x10000_v1.3.1.bin` ya da `v1.3.0\app_0x10000_v1.3.0.bin`), birleşik imajda **"Sürüm Düşürme"** diye sorar.

**Aracı açmak için:** `ev_otomasyon_servis_yazilimi` klasöründeki **`ev_otomasyon_sistemi.bat`** dosyasına çift tıklayın.

> **Rehberin kapsamı:** Waveshare **ESP32-S3-ETH-8DI-8RO** pano kartı + AHBU firmware'i. Araç beş sekmeden oluşur:
> **1. Firmware Yükleyici**, **2. Karekod Üret & Etiket Bas (Envanter)**, **3. Cihaz Provizyonu (USB / Wi-Fi)**,
> **4. Siteler** ve **5. Şablonlar** (toplu site kurulumu: site/daire, kurulum şablonu, karta yazım, kablolama şeması — Bölüm 4b).
>
> **Tek bakışta akış:** Giriş yap → karttan MAC oku → sunucuya kaydet (PIN + etiket) → etiketi kaydet/yazdır → firmware yükle (provizyon USB'den **otomatik** başlar) → **"Provizyon doğrulandı"** görününce → (önerilir) **etiketteki 2. karekodu telefon kamerasıyla okutup ağa bağlan** → etiketi karta yapıştır.

---

## 1. Bu araç ne yapar? (kısaca)

Bir kartı müşteriye gönderilecek hâle getirmek için beş iş yapar:

1. **Sunucuya giriş** yapar (yetkili "süper kullanıcı" ya da "servis sorumlusu" hesabıyla; fabrika kaydı yalnız süper kullanıcı).
2. Kartı sunucudaki **envantere kaydeder**; kartın seri numarasını, 6 haneli **PIN**'ini ve gizli anahtarını üretir.
3. Kartın **etiketini** hazırlar. Etiketin üzerinde **iki karekod** vardır: **1) Daireye bağla (uygulama)** ve **2) Kurulum Wi-Fi'sine bağlan (telefon kamerası)**.
4. Kartın içine **yazılımı (firmware)** yükler.
5. Kartın gizli anahtarını **USB kablosuyla** karta yazar ve doğrular (**provizyon**).

Sonunda etiketi karta yapıştırırsınız. Müşteri kartı daha sonra uygulamadan **1. karekodu** okutarak kendi evine ekler; servis teknisyeni gerektiğinde **2. karekodu telefon kamerasıyla** okutarak kartın kurulum Wi-Fi'sine tek dokunuşla bağlanır.

### Sözlük

| Kelime | Ne demek? |
|---|---|
| **MAC adresi** | Kartın fabrikada verilmiş benzersiz adresi (örn. `E8:F6:0A:DD:87:54`). Karttan okunur. |
| **Seri No / UID** | Kartın adı (örn. `AHBU-S3-DD8754`). MAC adresinin son 6 hanesinden **otomatik** üretilir. |
| **PIN** | 6 haneli kurulum kodu. Müşteri kartı uygulamaya eklerken gerekir. **Yalnızca etikette** bulunur. |
| **Yerel anahtar** | Kartın gizli şifresi. Araç üretir ve karta yazar. Etikette **yoktur**; kimseye gösterilmez. |
| **AP parolası** | Kartın kendi Wi-Fi ağının (`AHBU-XXXXXX`) parolası. Etikette yazar ve **2. karekodun içindedir**; yalnızca kurtarma/servis gerekirse kullanılır. |
| **Kurulum Wi-Fi karekodu (2. karekod)** | Etiketteki ikinci karekod. Telefonun **kendi kamerasıyla** okutulunca telefon, kartın kurulum ağına (`AHBU-XXXXXX`) bağlanmayı önerir; parolayı elle yazmanız gerekmez. İçinde ağ adı ve parola vardır, bu yüzden **gizlidir**. |
| **Daireye bağlama karekodu (1. karekod)** | Etiketteki ilk karekod. Müşteri/teknisyen **uygulamayla** okutur; cihazı daireye bağlar (UID + PIN içerir). |
| **Provizyon** | Kartın gizli anahtarını kartın içine yazma işlemi. Bundan sonra kart "kurulmuş" sayılır. |
| **Firmware / Flash** | Kartın içinde çalışan yazılım / bu yazılımı karta yükleme işlemi. |
| **COM Port** | Bilgisayarın USB'ye takılı kartı gördüğü "kapı" (`COM3`, `COM7` gibi). |
| **Envanter** | Sunucudaki cihaz stok listesi. Her kart burada bir satırdır. |

---

## 2. Başlamadan önce

#### Gerekenler

- Windows bilgisayar, **internet bağlantısı** olan normal ağa bağlı. (Araç IT tarafından kurulmuş olmalı — bkz. Teknik Ek.)
- Hazırlanacak kart ve **USB-C VERİ kablosu**. (Yalnızca şarj eden kablolar çalışmaz; kart bilgisayarda "COM port" olarak görünmelidir.)
- **Süper kullanıcı hesabı** (kart kaydı, etiket yenileme, envanter durumu) ya da **servis sorumlusu hesabı** (siteler, şablonlar, karta yazım, sunucudaki anahtarla yeniden provizyon) — e-posta + parola. Yöneticiniz verir. Parolayı kimseyle paylaşmayın; araç parolanızı **hiçbir zaman kaydetmez**. İsterseniz **Beni hatırla** ile yalnızca *şifreli oturum anahtarı* bu bilgisayarda saklanır ve araç bir sonraki açılışta kendiliğinden girer (ortak bilgisayarda işareti kaldırın).
- İsteğe bağlı: etiket yazıcısı.

#### Kurallar (7 ALTIN KURAL)

1. **PIN ve gizli bilgiler yalnızca BİR KEZ gösterilir.** Kaydı yaptıktan sonra provizyon bitene kadar aracı **kapatmayın** ve **Kaydı Bellekten Sil** demeyin.
2. **Firmware yüklenir yüklenmez provizyon yapılır.** Yükleme bitince **USB kablosunu çıkarmayın**; araç provizyonu kendisi yapar (birkaç on saniye sürer).
3. **Etiket gizli bir belgedir** (PIN + Wi-Fi parolası içerir; 2. karekod da parolayı taşır): **yalnızca cihaz üzerinde veya elinizde** saklanır. Fotoğrafını çekmeyin, göndermeyin, masada bırakmayın.
4. **Aynı anda tek kart** hazırlayın. Birden fazla kart takılıysa yanlış karta yazılabilir.
5. **Her kart için yeni kayıt** yapın. Aynı PIN'i/etiketi başka karta kullanmayın.
6. **Wi-Fi ile provizyon yalnızca yedek yoldur** (güvensizdir). USB çalışıyorsa hiç kullanmayın. (Bölüm 5)
7. Vardiya bitince (özellikle ortak bilgisayarda) **Oturumu Kapat**'a basın; hatırlanan oturumu da siler.

> **Güncel firmware şartı:** Kartlara yalnızca **USB provizyon komutunu bilen güncel firmware** yüklenmelidir. Araç, yüklenecek imajı denetler; imajda bu komut (`FACTORYINIT`) yoksa yüklemeden önce **"Firmware Uyarısı"** gösterir. Bu uyarıyı görürseniz **Hayır** deyin ve IT'den güncel imajı isteyin (Teknik Ek E): eski imajla yüklenen kart USB ile provizyonlanamaz.
> Aynı pencere imajda v1.3.0 özellikleri yoksa da uyarır (engellemez): **"Bu imajla USB şablon / Ethernet/LAN şablon / panonun kendi bulut kimliği çalışmaz (v1.3.0+ gerekli)."** (v1.2.1 imajında üçü de çıkar.) Kartta zaten v1.3.0+ çalışıyorsa bu uyarı "normal" değildir: araç kartı yokladıktan sonra birleşik imajda ayrıca **"Sürüm Düşürme"** diye sorar, **Güncelle (ayarlar korunur)** kipinde ise hiç yazmaz (**"Sürüm Düşürme Engellendi"**). Provizyon sırasında kartta v1.3.0'dan eski yazılım görülürse araç **"Bu yazılım buluta kendiliğinden bağlanamaz; bireysel sahiplenme için v1.3.0+ yükleyin."** der: kart çalışır ama müşterinin kendisi sahiplendiğinde servis sihirbazı olmadan buluta bağlanamaz.

---

## 3. Ekranı tanıyın

Pencerenin en üstünde iki şerit vardır:

- **Lacivert başlık:** "AHBU AKILLI EV SİSTEMLERİ"; sağında yüklü firmware sürümü rozeti ve **Koyu tema / Açık tema** anahtarı (görünümü değiştirir; seçiminiz bir sonraki açılış için hatırlanır, iş akışı değişmez).
- **Oturum şeridi:** solda sunucu adresi, ortada kim girişli olduğu ("Giriş yapılmadı" veya e-posta adresiniz), sağda **Sunucuya Giriş** ve **Oturumu Kapat** düğmeleri. Oturum hatırlanıyorsa rozette **"(süper kullanıcı, hatırlanıyor)"** yazar.

Altında **5 sekme** vardır:

| Sekme | Ne için? |
|---|---|
| **1. Firmware Yükleyici (Flasher)** | COM port seçimi, firmware'i karta yükleme, çip bilgisi okuma, hafıza silme. |
| **2. Karekod Üret & Etiket Bas (Envanter)** | Kartı sunucuya kaydetme, etiket üretme/kaydetme/yazdırma, envanter listesi. |
| **3. Cihaz Provizyonu (USB / Wi-Fi)** | Kartın gizli anahtarını yazma ve doğrulama; sonuçların izlenmesi. |
| **4. Siteler** | Site ekle/düzenle/sil, daireleri toplu üret, daireye şablon ata, kartı daireye bağla, ilerleme. (Bölüm 4b) |
| **5. Şablonlar** | Kurulum şablonu düzenleyici, sürüm geçmişi, karta yazım (USB / Ethernet), kablolama şeması PDF. (Bölüm 4b) |

**Roller:** **süper kullanıcı** her şeyi yapar. **Servis sorumlusu** giriş yapabilir (giriş penceresinin başlığı **"Sunucuya Giriş (süper kullanıcı / servis sorumlusu)"**); şeritte **"(servis sorumlusu)"** yazar. Siteleri, şablonları ve karta yazımı kullanır, envanter listesini görür, **Sunucudaki Anahtarla Yeniden Provizyon (USB)** yapabilir; ama **SUNUCU ENVANTERİNE KAYDET & KAREKOD ÜRET**, **Askıya Al (Kilit)**, **Aktif Et (Stok)**, **Envanterden Sil** ve **Etiketi Yeniden Bas (USB)** düğmeleri onun için kapalıdır (fabrika kaydı ve etiket yenileme yalnızca süper kullanıcıya açıktır).

**Envanter tablosundaki "Durum" sütunu (2. sekme, altta):** `IN_STOCK` = stokta (müşteriye gitmemiş), `CLAIMED` = müşteri uygulamadan eşlemiş, `INSTALLED` = sahada devreye alınmış, `SUSPENDED` = askıda (kilitli), `REVOKED` = iptal. **Listeyi Yenile** tabloyu sunucudan yeniden çeker. Sunucu listeyi 100'er kayıtla verir: durum satırı **"Gösterilen X / Toplam Y"** yazar, kalan kayıtlar için **Daha fazla**'ya basın. Eski bir kartı bulmak için tablonun üstündeki kutuya UID'yi, seri numarasını ya da MAC'i yazıp **Ara**'ya (ya da Enter'a) basın; kutu boşken bütün liste gelir, liste yenilenince arama korunur. **Askıya Al (Kilit)**, **Aktif Et (Stok)** ve **Envanterden Sil** düğmeleri e-posta + parola ile giriş ister. Silme için ayrıca cihazın UID'sini aynen yazarak onaylarsınız; eşlenmiş (`CLAIMED`/`INSTALLED`) cihaz ve bir **daireye bağlı** kart **silinemez** ("Kart bir daireye bağlı; önce daireden ayırın.").

**Etiketi Yeniden Bas (USB)** (yalnız süper kullanıcı): etiketi kaybolan/bozulan **stoktaki** kart USB'de takılıyken basılır. Araç kartın kimliğini seri `STATUS` ile okur, sunucuda **yeni kurulum PIN'i** üretir (eski etiketteki PIN geçersiz olur), kartın **mevcut yerel anahtarını** sunucudan alır (anahtar **değişmez**; alma işlemi kayda geçer), **yeni AP parolası** üretip karta USB'den yazar (`RESETKEY` + `FACTORYINIT`), `STATUS` ile doğrular ve iki karekodlu yeni etiketi önizlemeye koyar ("Etiket Yenilendi"). Kart stokta değilse ya da bir daireye bağlıysa sunucu reddeder ve nedeni gösterilir; karta yazma başarısız olursa **etiket basılmaz** (yeniden deneyin, yeni PIN üretilir).

---

## 4. Adım adım: yeni bir kartı hazırlama

Her kart için aynı 8 adımı uygulayın.

### Adım 1 — Aracı açın ve sunucuya giriş yapın

1. **`ev_otomasyon_sistemi.bat`** dosyasına çift tıklayın. Pencere açılır, oturum şeridinde **"Giriş yapılmadı"** yazar.
2. Üstteki **Sunucuya Giriş** düğmesine basın.
3. Açılan pencerede:
   - **Sunucu adresi:** olduğu gibi bırakın (yönetici başka bir adres vermediyse).
   - **E-posta** ve **Parola:** süper kullanıcı hesabınızı yazın. (Parolayı görmek için yandaki göz düğmesine basabilirsiniz.)
   - **Beni hatırla** (varsayılan işaretli): işaretliyse parola değil, yalnızca *şifreli oturum anahtarı* ve e-postanız bu bilgisayarda saklanır; araç bir sonraki açılışta **kendiliğinden** girer. **Ortak bilgisayarda işareti kaldırın.**
   - **Giriş Yap**'a basın.
4. **Ne görmelisiniz?** Şeritte e-posta adresiniz ve **(süper kullanıcı)** yazar, **Sunucuya Giriş** düğmesi **Hesap Değiştir**'e dönüşür; **2. sekmedeki** tablo envanteri listeler. **Beni hatırla** işaretliyse bir sonraki açılışta giriş penceresi çıkmaz: araç kayıtlı oturumla sessizce girer (Günlükte "Kayıtlı oturum sessizce açıldı"; şeritte "hatırlanıyor"). Oturum artık geçerli değilse kayıt silinir ve eskisi gibi **Sunucuya Giriş** beklenir.

> Giriş olmazsa Bölüm 7'deki **"Giriş"** tablosuna bakın. Kart kaydı (bu 8 adım) **süper kullanıcı** hesabı ister; servis sorumlusu hesabı siteler/şablonlar/karta yazım ve sunucudaki anahtarla yeniden provizyon içindir.

### Adım 2 — Kartı bağlayın ve kimliğini okuyun

1. Kartı **USB-C veri kablosuyla** bilgisayara takın. (Kartın gücü USB'den gelir.)
2. **1. sekmede** **COM Port** kutusunda kartınızı seçin (örn. `COM7 (USB Serial...)`). Liste boşsa **Portları Yenile**'ye basın; yine yoksa kabloyu/portu değiştirin.
3. **2. sekmeye** geçin ve **Karttan MAC Oku** düğmesine basın (birkaç saniye sürer).
4. **Ne görmelisiniz?** "MAC Okundu" penceresi çıkar; **1. Donanım MAC** ve **2. Cihaz Seri No (UID)** kutuları otomatik dolar (örn. `AHBU-S3-DD8754`).

> **Önemli:** Seri No (UID) her zaman kartın MAC adresinden türetilir. Elle değiştirmeyin; farklı yazarsanız araç sizi uyarır.

### Adım 3 — PIN'i hazırlayın ve kartı sunucuya kaydedin

1. **3. Kurulum PIN** kutusunda araç **rastgele bir PIN** üretmiştir (noktalı görünür). Yeni bir tane isterseniz **Rastgele PIN Üret**'e basın. (Göz düğmesi PIN'i gösterir.) PIN'i **kendiniz seçmeyin**, rastgele olsun.
2. **4. Donanım Modeli** ve **5. Üretim Partisi** kutularını kontrol edin (genellikle hazır gelir; parti `BATCH-YIL-AY` biçimindedir).
3. **SUNUCU ENVANTERİNE KAYDET & KAREKOD ÜRET** düğmesine basın.
   - Giriş yapmadıysanız önce giriş penceresi açılır.
4. **Ne görmelisiniz?** "Cihaz Envantere Eklendi!" penceresi: Sıra No, Cihaz UID, MAC ve sıradaki adımlar yazar. Sağ tarafta **etiketin önizlemesi** belirir. **3. sekmede** kartın adı ve "Provizyon bekliyor" görünür.

> **UYARI:** PIN ve kartın gizli anahtarı artık **bir daha gösterilmez**. Etiket önizlemesi ekranda durduğu sürece PIN'e oradan bakabilirsiniz. Etiketi kaydedip provizyonu bitirene kadar aracı **kapatmayın**.

### Adım 4 — Etiketi alın

1. Sağdaki önizlemenin altında **Etiketi Kaydet (PNG)** düğmesine basın.
2. Dosyayı kaydedeceğiniz yeri seçin (örn. Masaüstü) ve **Kaydet**'e basın.
3. Etiketi yazdırmak için **Yazdır (Barkod / Termal)** düğmesine basın. (Etiket kaydedilmemişse araç önce kaydetme penceresini açar.)
4. Yazdırma işi bitince **PNG dosyasını silin** (içinde PIN ve Wi-Fi parolası var).

**Etiketin düzeni** (100 x 50 mm; soldan sağa üç bölüm, iki karekod net ayrılmıştır):

| Bölüm | İçerik | Kim okur? |
|---|---|---|
| **Sol: 1) Daireye bağla (uygulama)** | Karekod + "Karekodu uygulamayla okutun" | Müşteri/teknisyen, **uygulamayla**. Cihazı daireye bağlar (UID + PIN içerir). |
| **Orta: okunabilir metinler** | **Cihaz Seri No (UID)**, **Kurulum PIN**, **Kurulum Wi-Fi Ağı** adı, **Ağ Parolası (AP)**, **MAC Adresi** | İnsan gözü. |
| **Sağ: 2) Kurulum Wi-Fi'sine bağlan (telefon kamerası)** | Karekod + "Telefon kamerasıyla okutun, ağa bağlanın" | **Telefonun kendi kamerası** (ek uygulama gerekmez): kartın kurulum ağına tek dokunuşla bağlanır. İçinde ağ adı ve parola vardır. |

Üstte sıra numarası (`#0001` gibi), altta model ve kayıt tarihi bulunur. En altta kırmızı bantta güvenlik notu yazar: **"GİZLİ: Bu etiket yalnızca cihaz üzerinde/elde saklanır; fotoğrafı paylaşılmaz (kurulum parolası ve PIN içerir)."**

> **Yazdırma notu:** Etiket **100 x 50 mm (4 x 2 inç)** etiket kâğıdı için hazırlanır (PNG dosyasına gerçek boyut bilgisi yazılır). Yazıcı ayarında kâğıt boyutunu etiketle aynı seçin; "sayfaya sığdır / büyüt" seçeneklerini kapatın ki karekodlar bulanıklaşmasın. İlk baskıda **iki karekodu da telefonla okutup deneyin** (yazıcıyla henüz denenmedi).
>
> Araç etiketi **kendiliğinden diske yazmaz**; yalnızca siz **Etiketi Kaydet** (veya Yazdır) derseniz yazılır.

### Adım 5 — Firmware'i yükleyin (provizyon otomatik başlar)

1. **1. sekmeye** geçin. **COM Port**'un doğru kart olduğundan emin olun.
2. **Yüklenecek Firmware Seçimi** bölümünde **"Bizim Geliştirdiğimiz Yazılım (Otomatik Seçili)"** işaretli olmalı. **Dosya** kutusunda `version_info.json`'un gösterdiği güncel **birleşik** imajın yolu yazar (şu an `...\firmware_releases\v1.3.2\firmware_combined_0x0.bin`). **➕ Versiyon Arttır** düğmesine basmayın: yalnız yeni bir sürüm hazırlayan IT içindir (Teknik Ek E); basılırsa kutudaki dosyayı yeni bir sürüm numarasıyla kopyalayıp güncel sürüm yapar. (**"Fabrika Çıkış Orijinal Yazılımı"** yalnızca test/kurtarma içindir: bu yazılım AHBU provizyonu yapmaz; üretimde seçmeyin.)
   - Daha önce kullanılmış/farklı yazılımlı bir kartsa önce **Hafızayı Sil (Erase Flash)** düğmesine basıp onay sorusuna **Evet** deyin; bitince bu adıma dönün.
   - **Birleşik imaj (0x0) yeni/boş ya da Waveshare yazılımlı kart içindir:** kartın kalıcı belleğini yeniden yazar; kartta yerel anahtar, AP parolası, Wi-Fi, bulut kimliği, şablon ve güvenlik ayarları varsa **SİLER**. **Kurulu (provizyonlu/şablonlu) bir kartı güncellemek için** üçüncü seçenek **"Güncelle (ayarlar korunur)"**'u seçin: araç yalnız uygulama imajını (`v<sürüm>\app_0x10000_v<sürüm>.bin`) **0x10000** adresine yazar; ayarlar korunur, provizyon gerekmez, etiket geçerli kalır. Bu kip önce kartın AHBU firmware'i çalıştırdığını seri `STATUS` ile doğrular; doğrulanamazsa **"Güncelleme Yapılamadı"** der ve hiçbir şey yazmaz (kart yükleme kipinde kalmış olabilir: **BOOT'a basmadan** RESET'e bir kez basıp yeniden deneyin). Kartta v1.3.0+ çalışırken seçilen uygulama imajında v1.3.0 özellikleri yoksa (ör. elle seçilmiş v1.2.1 uygulaması) araç **"Sürüm Düşürme Engellendi"** der ve yazmaz: ayarlar kalır ama Ethernet, şablon ve panonun kendi bulut kimliği giderdi. **Gözat...** ile v1.3.0+ uygulama imajını (`v1.3.1\app_0x10000_v1.3.1.bin`; `v1.3.0\app_0x10000_v1.3.0.bin` da olur) seçip FLASH'a yeniden basın. Araç kipe yanlış dosya verilmesine izin vermez: uygulama imajı 0x0'a, birleşik imaj 0x10000'a yazılamaz ("Dosya Sorunu").
3. **FİRMWARE'İ KARTA YÜKLE (FLASH)** düğmesine basın.
   - Araç önce kartı USB'den yoklar (`STATUS` + `TPL STATUS`; çalışan kart hemen yanıt verir, yanıt vermeyen kartta en çok ~10 sn: port açılınca yeniden başlayan kart da bu sürede yanıt verir). Kartta yerel anahtar ya da şablon varsa **"Kart Ayarları Silinecek"** sorusu çıkar: *"Yerel anahtar, AP parolası, Wi-Fi, bulut kimliği, şablon ve güvenlik ayarları SİLİNECEK. Devam?"* **Hayır** derseniz araç **"Güncelle (ayarlar korunur)"** kipine geçer ve **seçtiğiniz birleşik imajla aynı klasördeki** uygulama imajını (`app_0x10000_v<sürüm>.bin`) seçer (**"Güncelle Kipi Seçildi"**; klasörde yoksa araç uyarır, **Gözat...** ile aynı sürümün uygulama imajını seçin); FLASH'a yeniden basın. Boş/yeni kartta soru çıkmaz.
   - Kartın durumu okunamazsa (port/bağlantı hatası) ya da kart **yükleme kipinde** bekliyorsa (BOOT+RESET ile açılmış; `Failed to connect` çözümü kartı bu kipte bırakır, kart o zaman STATUS'a yanıt vermez) araç **"Kart Durumu Okunamadı"** diye sorar: kart kuruluysa **Hayır** deyin, kartı **BOOT'a basmadan** RESET'leyip FLASH'a yeniden basın.
   - Kartta v1.3.0+ çalışırken seçilen birleşik imaj daha eskiyse araç ayrıca **"Sürüm Düşürme"** diye sorar; kartı bilerek eski sürüme döndürmüyorsanız **Hayır** deyin ve **Gözat...** ile v1.3.0+ imajını seçin.
   - **"Firmware Uyarısı"** çıkarsa metni okuyun. "FACTORYINIT bulunamadı / ESKİ firmware" diyorsa **Hayır** deyin ve IT'den güncel imajı isteyin (Bölüm 2 ve Teknik Ek E).
   - **İşlem Log Çıktısı** alanında satırlar akar (30–60 saniye).
4. Yükleme bitince **"Başarılı"** penceresi çıkar. Bu kartın kaydı (Adım 3) hazırsa ve kartın MAC adresi kayıtla eşleşiyorsa araç **3. sekmeye kendiliğinden geçer** ve provizyonu başlatır. Bellekteki kayıt bu karta aitse ve kart daha önce provizyonlanmışsa (birleşik imaj anahtarı sildi) araç **aynı anahtar ve AP parolasıyla** yeniden provizyon yapar; etiket geçerli kalır. Bellekte kaydı olmayan ama önceden provizyonlu bir kartsa araç **Sunucudaki anahtarla yeniden provizyon** önerir (Bölüm 5c). MAC uyuşmuyorsa araç provizyonu **başlatmaz**; nedenini "Başarılı" penceresinde yazar. Kartta şablon vardıysa birleşik imaj onu da sildiği için araç şablonu yeniden yazmanızı söyler.

> **Bu sırada USB kablosunu ÇIKARMAYIN ve başka kart takmayın.** Kart yeniden başlarken kısa süre **parolasız** bir Wi-Fi ağı (`AHBU-XXXXXX`) yayınlar; araç USB'den hemen provizyonu yapıp bu ağı parolalı hâle getirir.

### Adım 6 — Provizyonun bittiğini kontrol edin

**3. sekmede** **Sonuç** alanında satırlar akar:

1. `USB (seri) provizyon başlıyor (COM7, 115200 baud)...`
2. `Kart yeniden başlıyor; USB seri portun yeniden görünmesi bekleniyor...` (port bir süre kaybolur — normaldir)
3. `Seri porta bağlanıldı; kartın açılması ve STATUS yanıtı bekleniyor...`
4. `Kart provizyonsuz; yerel anahtar ve AP parolası USB üzerinden yazılıyor (kablosuz ağdan geçmez)...`
5. `FACTORYINIT gönderildi (parametreler gizli); kartın yanıtı bekleniyor...`
6. `Yazma tamam; kart STATUS ile doğrulanıyor...`
7. **`✅ USB (seri) provizyon tamamlandı ve doğrulandı ...`** ve **"Provizyon Tamamlandı"** penceresi.

**Ne görmelisiniz?** Üstte **"Durum: Provizyon doğrulandı ✔ (USB seri)"** yazar ve "Provizyon Tamamlandı" penceresi, etiketi yapıştırmadan önce telefonla kontrolü önerir (Adım 7).

Firmware v1.3.1'de `STATUS` çıktısında **"Anahtar izi"** satırı da vardır (anahtarın kendisi değil, ondan türetilen 8 haneli iz): araç bu izi kayıttaki anahtarla karşılaştırır ve eşleşirse "Karttaki anahtar izi bu kayıttaki anahtarla eşleşti." yazar. Eşleşmezse kartta başka bir anahtar vardır; araç sıfırlamayı (RESETKEY) önerir. Eski firmware'de bu satır yoktur; araç eskisi gibi çalışır.

- **Gizli Bilgiler** kutusunda yerel anahtar ve AP parolası noktalı (••••) görünür (**Değerleri göster** açar). Fabrikada **yazmanız/kopyalamanız gerekmez** (AP parolası etikettedir). Tek istisna: kartın web sayfası (Bölüm 11) için **yerel anahtar** gerekecekse, kaydı bellekten silmeden önce **📋 Anahtarı kopyala** ile alıp güvenli bir parola yöneticisine kaydedin (anahtar panoya kopyalanır ve 45 sn sonra panodan silinir). Anahtar etikette yazmaz, mobil uygulama da ayarlarda göstermez; **Kaydı Bellekten Sil**'den ya da aracı kapattıktan sonra bir daha gösterilmez.
- Beklerken **Beklemeyi İptal Et** düğmesiyle işlemi durdurabilirsiniz.
- Araç otomatik başlamadıysa (ör. firmware'i başka bir yolla yüklediyseniz) **Seri (USB) ile Provizyonla (Önerilen)** düğmesine siz basın.
- Hata çıkarsa **Bölüm 7**'deki tabloya bakın; çoğu hata "tekrar dene" ile geçer.

### Adım 7 — Etiketteki 2. karekodu telefon kamerasıyla okutun, ağa bağlanın (önerilir)

Provizyon bittikten sonra kartın kurulum ağı (`AHBU-XXXXXX`, parolalı) yaklaşık **10 dakika** açıktır. Etiketin doğru olduğunu ve kartın ağına bağlanılabildiğini denemenin en kolay yolu:

1. Telefonun **kamerasını** açın (Android ve iPhone'un kendi kamerası yeter; ek uygulama gerekmez).
2. Kamerayı etiketteki **2) Kurulum Wi-Fi'sine bağlan (telefon kamerası)** karekoduna tutun; etiketi düz tutun, karekod ekranda net görünsün.
3. Ekranda kartın ağına bağlanmayı öneren bir bildirim çıkar (örn. "AHBU-XXXXXX ağına bağlan"; iPhone'da "Ağa Katıl" benzeri). Bildirime dokunun.
4. Telefon bağlanırsa etiket ve parola doğrudur. Bu ağda internet yoktur; telefon "internet yok" uyarısı verebilir — **normaldir**.
5. Bitince telefonun Wi-Fi'sini normal ağınıza geri alın.

> **Karekod okunmazsa:** telefonun Wi-Fi ayarlarında `AHBU-XXXXXX` ağını seçip etikette **Ağ Parolası (AP)** olarak yazan parolayı elle yazın. Ağ listede yoksa kartın USB'sini çıkarıp takın ve yarım dakika bekleyin. Sorun sürerse Bölüm 7'deki **"Etiket ve telefonla bağlanma"** tablosuna bakın.
>
> **1. karekod (Daireye bağla)** yalnızca **uygulama** içindir; telefonun kamerasıyla okutmaya gerek yoktur.

### Adım 8 — Etiketi yapıştırın ve sıradaki karta geçin

1. Basılı etiketi **kartın kapağına** yapıştırın. (Kart ve etiket artık eşleşmiştir; başka karta yapıştırmayın. Etiket **yalnızca cihaz üzerinde/elde** saklanır; fotoğrafı paylaşılmaz.)
2. **3. sekmede** **Kaydı Bellekten Sil / Yeni Cihaz** düğmesine basın. (PIN, anahtar ve etiket görseli bellekten silinir.)
3. PNG etiket dosyasını silmeyi unutmayın.
4. Sıradaki kart için **Adım 2**'ye dönün.

#### Kontrol listesi (her kart için)

- [ ] Giriş yapıldı (şeritte e-posta görünüyor)
- [ ] MAC okundu, UID otomatik doldu
- [ ] "Cihaz Envantere Eklendi!" göründü
- [ ] Etiket kaydedildi/yazdırıldı, PNG silindi
- [ ] Firmware "Başarılı"
- [ ] **"Provizyon doğrulandı ✔"** göründü
- [ ] (Önerilir) 2. karekod telefon kamerasıyla okutuldu, telefon kartın ağına bağlandı
- [ ] Etiket karta yapıştırıldı
- [ ] "Kaydı Bellekten Sil / Yeni Cihaz" yapıldı

---

## 4b. Siteler ve kurulum şablonları (toplu kurulum)

Toplu (site) kurulumlarda sahadaki işi azaltmak için ofiste **site** ve **daire tipi şablonu** hazırlanır; atölyede şablon karta
**USB** ya da **Ethernet** ile yazılır; kartla birlikte **kablolama şeması (PDF)** sahaya gider. Bu bölüm **süper kullanıcı** ve
**servis sorumlusu** içindir. Tek daire kurulumunda da aynı şablonlar kullanılabilir (sitesi olmayan **Genel** şablonlar).

### 4b.1 Site oluşturma (4. Siteler sekmesi)

1. **Siteleri Yenile** ile listeyi alın; **Site Ekle** ile yeni site açın: site adı (zorunlu), adres, il, ilçe, sorumlu adı,
   sorumlu telefonu, e-posta, blok sayısı, daire sayısı, not. **Siteyi Düzenle** / **Siteyi Sil** seçili site içindir
   (dairesine kart bağlı site silinemez; silme "yumuşaktır", şablon sürümleri ve yazım kayıtları kalır).
2. Siteyi seçin; alttaki **Daireler** tablosu dolar. **Toplu Daire Üret**: blok (ör. `A`), ilk ve son daire no (ör. 1-24),
   isteğe bağlı daire tipi ve şablon. Var olan blok+no atlanır.
3. Daireyi seçip **Şablon Ata** ile şablonunu, **Kart Bağla** ile kartın UID'sini (`AHBU-S3-XXXXXX`; boş = bağlantıyı kaldır) girin.
   Şablon eski karta yazılmışken kart değiştirilirse araç **"Şablon yeni karta yeniden yazılmalı"** uyarır. Yalnız **stoktaki** kart
   bağlanır; kart pano değişimiyle bu daireye takıldıysa bağlantı sunucuda otomatik taşınır, değilse süper kullanıcı bağlayabilir.
   Başka bir daireye bağlı kart için "Kart bir daireye bağlı; önce daireden ayırın." denir. **Kuruldu** ya da **Teslim edildi**
   durumundaki dairenin kartını değiştirmeyi/ayırmayı sunucu reddederse (yalnız Pano Değişimi ile ya da süper kullanıcı) araç
   sunucunun iletisini gösterir.
4. "Durum" sütunu ilerlemeyi gösterir: **Planlandı → Yazıldı → Kuruldu → Teslim edildi** (sitenin "İlerleme" sütunu da bu sayıları
   gösterir). Daire müşteriye teslim edilince **Teslim Edildi** düğmesiyle işaretleyin. Araç önce daireye kart bağlı mı ve durum
   **Yazıldı** ya da **Kuruldu** mu diye bakar; değilse **"Teslim Edilemez"** der ve sunucuya hiçbir şey göndermez (önce **Kart Bağla**,
   sonra **Karta Yaz**). Durum yalnız ileri gider; geri alma yalnız süper kullanıcı. "Son yazım" hangi sürümün hangi yolla (USB/ETH) yazıldığını gösterir:
   başarısız yazım **`⚠ vN (kod)`**, şablonun güncel sürümünden eski son başarılı yazım **"eski sürüm"**, dairenin kartından başka
   bir karta yapılan yazım **"başka kart (UID)"**, dairenin şablonundan başka bir şablonun son başarılı yazımı **"(farklı şablon)"**
   olarak ayrıca belirtilir.

### 4b.2 Şablon hazırlama (5. Şablonlar sekmesi)

1. Üstten **Site**'yi (ya da **Genel**) seçip **Şablonları Yenile**'ye basın. **Yeni Şablon** / **Şablonu Düzenle** düzenleyiciyi açar;
   **Çoğalt** aynı içeriği yeni adla kopyalar; **Sürüm Geçmişi** eski sürümleri listeler (eski sürümler değişmez);
   **Şablonu Sil** listeden kaldırır (sürümler ve yazım kayıtları sunucuda kalır).
2. Düzenleyicide: şablon adı, daire tipi, **Ek modül (RS485) var** + kanal + adres (**Kanalları Uygula** tabloları büyütür/küçültür).
   Yalnız adresi değiştirdiyseniz düğmeye basmanız gerekmez. Kutu/kanal sayısını değiştirip **Kanalları Uygula**'ya basmadan
   kaydederseniz araç uygulamayı sorar; "Hayır" derseniz kayıt durur ("Ek modül değişikliği uygulanmadı: Kanalları Uygula
   düğmesine basın") — değişiklik sessizce kaybolmaz.
   - **Röle Çıkışları:** ad, oda, tip (**Lamba/Priz**, **Panjur (çift)**, **Darbe**), süre, bağlanacak yük. Panjur seçilince röle
     **çift** olarak kurulur: tek numaralı röle **Yukarı**, ardından gelen **Aşağı**, ikisinin süresi aynıdır. Tip değişikliği bir
     güvenlik cihazını (vana/siren/fan; panjur çiftinin eşindeki dahil) ya da dimmeri silecekse araç önce
     **"Güvenlik Öğesi Silinecek"** diye sorar (ör. "R8 Ana Su Vanası (vana, su)"); "Hayır" derseniz hiçbir şey değişmez. Kaydederken düzenleyici
     açıldığından beri güvenlik cihazı/dimmer azaldıysa son kez sorulur ("N güvenlik cihazı silindi, yine de kaydedilsin mi?").
   - Lamba satırındaki **💡** düğmesi **"Parlaklık ayarı yapılacak mı?"** diye sorar: evetse dimmer kaynağı (Modbus dimmer modülü /
     köprü), adres ve kanal girilir; pencere dimmerin **nereye** konacağını yazar (K4 yönergesi; şemada da yer alır).
   - **Girişler (DI):** ad, hedef röle, kip (**Aç/Kapa – yaylı (kalıcı olmayan) buton; her basışta değiştirir**,
     **Basılı tut (yaylı buton; basılıyken açık)**, panjur kipleri de yaylı butondur — kalıcı/mandallı anahtar desteklenmez), kablolama notu ve **güvenlik rolü** (su, gaz, duman, kapı, pencere, hareket...) +
     kontak **NO/NC** + bölge. Gaz/duman dedektörü her zaman **NC** bağlanır; sensör olan girişin hedef rölesi "Boşta" olur.
   - **Güvenlik:** tepkiler açık/kapalı, kuruluk bekleme, bölge adları, güvenlik cihazları (vana / siren / fan; vanada kapanma kipi
     ve akışkan). Cihaz panjur ya da darbe rölesine bağlanamaz. Kablosuz (köprü) sensör bu sürümde desteklenmiyor: sensörler
     panodaki girişlere (d1..d40) bağlanır; şablonda köprü sensörü (b1..b16) varsa doğrulama reddeder.
3. **Doğrula** yerel denetimi yapar; **Doğrula ve Kaydet (yeni sürüm)** önce yerel, sonra sunucu doğrulamasından geçirip **yeni sürüm**
   olarak kaydeder. Sunucu reddederse hata kodu ve alan gösterilir; düzenleyiciye dönüp düzeltebilirsiniz. Siz düzenlerken başka biri
   aynı şablonu kaydettiyse **"Şablon Değişti"** sorusu çıkar: yeni sürümü açabilir ya da bilerek üstüne yazabilirsiniz (öteki
   değişiklikler o zaman yeni sürümde olmaz).

### 4b.3 Şablonu karta yazma

1. **Siteler** sekmesinde daireyi seçip **Karta Yaz**'a (ya da **Şablonlar** sekmesinde şablonu seçip **Karta Yaz**'a) basın.
   Daireden yazımda araç daireyi önce sunucudan yeniden okur: liste yüklendikten sonra dairenin şablonu değiştirildiyse
   **"Daire Şablonu Değişti"** diye sorar ("Evet": dairenin güncel şablonu yazılır; "Hayır": hiçbir şey yazılmaz). Daire silinmiş ya da
   şablonu kaldırılmışsa **"Daire Değişti"** der ve yazmaz; iki durumda da daire listesi yenilenir.
2. Pencerede yol seçin:
   - **USB (seri) — önerilen:** USB portunu seçin. Kart fiziksel olarak bağlı olduğu için güvenlik ayarlarını tamamen yazabilir.
     Daireye bağlı kart varsa araç bağlı kartın o kart olduğunu denetler; değilse hiçbir şey yazmaz. Dairenin kartı yoksa araç
     takılı kartı **yazmadan önce** daireye bağlar; kart başka bir daireye bağlıysa (sunucu reddeder) **hiçbir şey yazılmaz**
     ("Kart … başka bir daireye bağlı").
   - **Ethernet (LAN) - kartın Ethernet IP'si; anahtar gerekmez:** kartın IP adresi (yalnız yerel ağ) ve UID'si. Kart (firmware
     v1.3.0+) **kablolu Ethernet'ten gelen isteği anahtarsız ve provizyonsuz kabul eder** (kullanıcı kararı 2026-10-08): sunucudan
     anahtar alınmaz, kart envantere kaydedilmemiş ya da provizyonsuz olsa da yazılır. **IP'nin doğru karta ait olduğu DENETLENMEZ,
     yanlış IP başka karta yazar; UID yalnız yazım kaydı içindir** (pencere "Yazım kaydı için kart UID'si gerekir" der). IP kartın
     Wi-Fi adresiyse kart anahtar ister ve yazım reddedilir; kartın Ethernet IP'sini girin.
3. **NC tehlike girişi (atölye):** şablonda **NC** bağlı gaz, duman ya da su sensörü varsa araç yazmadan önce **"NC Tehlike Girişi"**
   uyarısı gösterir (ör. *"D3 (Gaz) NC: atölyede giriş boşsa kart hemen alarma geçip kilitlenir (vana kapanır, siren çalar). Yazmadan
   önce girişi DI-GND köprüleyin ya da dedektörü bağlayın."*). Atölyede girişe dedektör bağlı değilse **girişi DI ile GND arasında
   köprüleyin** (kısa bir kablo), sonra yazın. USB yazımından sonra araç kartın güvenlik durumunu (`SAFETY`) okur; bölge kilitlendiyse
   **"Alarm Kilitlendi (Atölye)"** penceresi çıkar: köprüleyin ve **Alarmı Onayla (USB)** düğmesine basın (araç `SAFETY ACK <bölge>`
   gönderir; kuruluk bekleme süresi dolunca bölge normale döner). Bu, kartın bilinçli güvenli davranışıdır (fail-safe); firmware
   değiştirilmedi. Bölge **FAULT** durumundaysa (vana arızası: geri bildirimli vana "kapalı" görülmedi; atölyede vana bağlı değilse
   olur) onay bu bölgeyi **temizlemez**: vanayı ve kapalı-konum geri bildirim kablosunu bağlayın, vana KAPALI görülünce bölge kilitli
   olur, sonra yeniden onaylayın. Kartın güvenlik durumu (`SAFETY`) okunamazsa araç **"Güvenlik Durumu Okunamadı"** der (durum
   bilinmiyor, normal sayılmaz): **Alarmı Onayla (USB)** ile kontrol edin. Onaydan sonra kilitli ya da arızalı bölge kalırsa
   **"Alarm Sürüyor"** çıkar; **"Alarm Onaylandı"** yalnız `SAFETY` okunup kilitli/arızalı bölge kalmadığında görünür.
4. Araç şablonu gönderir, kart **atomik** uygular (geçersizse hiçbir şey değişmez), ardından karttan **geri okur**. Sonuç
   "Karta Yazım Sonucu" alanında görünür ve sunucuya yazım kaydı işlenir (daire **Yazıldı** olur). Kayıt işlenemezse (oturum yok,
   ağ/sunucu hatası) **kaybolmaz**: bellekte bekler, araç uyarır; giriş yapıp **Bekleyen Kayıtları Gönder**'e basın. Başarı
   penceresi kaydın sonucunu da yazar ("Yazım kaydı: sunucuya işlendi" / "işlenemedi, bekliyor" / "sunucu reddetti"). Kart başka bir
   daireye bağlıysa sunucu kaydı yine alır ama seçili dairenin durumunu değiştirmez; araç bunu hata penceresiyle bildirir. Yazılan
   şablon dairenin güncel şablonu değilse de sunucu kaydı alır ama daireyi Yazıldı yapmaz: **"Daire Şablonu Farklı"** penceresi
   *"Karta yazılan şablon dairenin güncel şablonu değil; daire Yazıldı yapılmadı. Daire listesini yenileyip güncel şablonu yazın."*
   der (kayıt kuyruktan sonradan gönderilse de). Kartta yarım kalmış bir şablon uygulaması varsa (seri `STATUS`'ta **YARIM**; kart
   güvenli kipte) araç bunu yazmadan önce söyler, flaş öncesi yoklama da şablonu "(YARIM ...)" diye gösterir. Yanıt kaybolduğunda
   (USB'de COMMIT yanıtı yok, Ethernet'te 202 ya da kopma) araç yalnız kart yeni şablonu bitirdiyse başarı der; kart hâlâ yarım
   görünüyorsa *"Şablon yarım kaldı; aynı şablonu yeniden yazın."* der. Sunucu
   kaydı **kalıcı olarak reddederse** (kart envanterde kayıtlı değil — ör. Ethernet ile kayıtsız karta yazım —, şablon sürümü ya da
   daire bulunamadı, şablon/site silinmiş, daireye başka kart bağlı, şablon başka siteye ait) yeniden göndermek işe yaramaz: kayıt
   kuyruktan çıkarılır ve **"Yazım Kaydı Reddedildi"** penceresi kart UID'si, şablon sürümü ve kodla **bir kez** gösterilir.
5. Firmware yükleme + USB provizyon bittikten sonra **3. sekmede** **Şablon Yaz (aynı USB portu)** düğmesi aynı porttan şablon
   yazmanızı kolaylaştırır.
6. Daireye yazımdan sonra araç kablolama şemasını ve **daire etiketini** sorar: **"Daire Etiketi"** (kart UID'si + site/blok/daire +
   şablon adı/sürümü; **PIN ve parola içermez**) PNG olarak kaydedilir; yazdırıp dairenin panosuna yapıştırın. Kart bellekteki son
   kaydedilen kartsa ayrıca kart etiketine daire satırı eklenir (ör. `A Blok / Daire 12 · 3+1 · Şablon v4`); etiketi 2. sekmeden
   yeniden kaydedip yazdırın.

### 4b.4 Kablolama şeması (PDF)

**Kablolama Şeması (PDF)** düğmesi (Şablonlar ve Siteler sekmesinde; ayrıca karta yazım sonrası araç sorar) A4 PDF üretir: başlık
(site, blok/daire, şablon, daire tipi, sürüm, tarih, **Kart UID** — dairenin bağlı kartı ya da yazımın yapıldığı kart; bilinmiyorsa
`-`), karta bakan klemens düzeni (R1-R8 üstte, D1-D8 altta; ek modül ayrı blok),
her röle → yük/oda/tip (panjur çiftlerinde yön notu ve kilit uyarısı), her giriş → kablolama notu/kip/hedef ve sensörlerde tür +
NO/NC + bölge, dimmer yerleşimi, güvenlik cihazları ve uyarılar (gaz için **sertifikalı bağımsız gaz dedektörü** şartı, vana kapanma kipi),
şablon kimliği + sürümü taşıyan karekod. Alt bilgide **"Bu şema şablon sürümü vN içindir"** yazar: şemayı kartla birlikte sahaya gönderin.

### 4b.5 Karta yazım hataları

| Mesaj (kısaltılmış) | Anlamı | Ne yapmalı? |
|---|---|---|
| "Önce provizyon yapın" (`unprovisioned`) | Kart provizyonsuz | 3. sekmede provizyon, sonra yeniden yazın |
| "güvenlik değişikliğini ağ üzerinden kabul etmedi" (`local_loosen_forbidden`) | Eski firmware | Firmware'i güncelleyin ya da USB ile deneyin |
| "Kartın firmware'i şablon yazmayı desteklemiyor" (`unsupported_fw`) | Firmware v1.3.0'dan eski | Önce firmware güncelleyin |
| "Aktarım bozuldu (CRC uyuşmadı)" (`tpl_crc`, `tpl_b64`) | USB verisi bozuldu; hiçbir şey değişmedi | Kabloyu kontrol edip yeniden deneyin |
| "kilitli (alarmdaki) bir bölge" (`zone_latched`), "Hırsız alarmı kurulu" (`armed`) | Kart güvenlik durumunda (atölyede çoğunlukla boş bırakılmış NC gaz/duman/su girişi) | Girişi DI-GND köprüleyin, **Alarmı Onayla (USB)**'ya basın (`SAFETY ACK <bölge>`), kuruluk süresi dolunca yeniden yazın; hırsız alarmını kapatın |
| "Kart meşgul" (`busy`) | Panjur hareket halinde ya da bellek yetersiz | Birkaç saniye bekleyin |
| "kalıcı belleğinde yer yok" (`storage`) | NVS dolu; uygulanmadı | Servis ekibine bildirin |
| "Bağlı kart ... eşleşmiyor" (`mac_mismatch`) | Yanlış kart takılı ya da kartın kimliği okunamadı | Doğru kartı bağlayın |
| "Bu kart stokta değil ... daireye bağlanamaz" (`DEVICE_NOT_IN_STOCK`, Kart Bağla) | Kart müşteriye ait ya da askıda | Doğru kartı seçin. Kart pano değişimiyle bu daireye takıldıysa bağlantı sunucuda otomatik taşınır; değilse süper kullanıcı bağlayabilir |
| "Kart bir daireye bağlı; önce daireden ayırın." (`DEVICE_LINKED_TO_FLAT`) | Kart başka bir daireye bağlı (silme / durum / etiket yenileme / bağlama reddedildi) | Kartı önce o dairenin **Kart Bağla** penceresinde boş UID ile ayırın |
| "Kart … başka bir daireye bağlı; şablon yazılmadı." | Kartsız daireye USB yazımında kart başka daireye bağlı çıktı | Doğru daireyi seçin ya da kartı önce o daireden ayırın |
| "Şablon Değişti" (`TEMPLATE_CHANGED`) | Siz düzenlerken başkası şablonu kaydetti | Yeni sürümü açın ya da bilerek üstüne yazın |
| "Daire durumu yalnız ileri gider…" (`INVALID_STATUS_TRANSITION`, Teslim Edildi) | Geçiş geçersiz (ör. kart bağlı değil) | Önce kartı bağlayın; geri alma yalnız süper kullanıcı |
| "Yazım kaydı işlenemedi …" | Oturum yok ya da sunucu/ağ hatası (5xx, hız sınırı); kayıt bellekte bekliyor | Giriş yapıp **Bekleyen Kayıtları Gönder**'e basın. Bekleyen kayıt varken araç kapatılırsa **"Bekleyen Yazım Kaydı"** sorusu çıkar (kapatırsanız kayıt kaybolur) |
| "Yazım Kaydı Reddedildi": "Sunucu yazım kaydını kalıcı olarak reddetti; kayıt bekleyen kuyruktan çıkarıldı …" | Kart envanterde kayıtlı değil, şablon sürümü/daire bulunamadı, şablon ya da site silinmiş, daireye başka kart bağlı ya da şablon başka siteye ait (HTTP 400/404/409/422); kayıt yeniden gönderilmez | Penceredeki kodu giderin (ör. kartı envantere kaydedin, doğru daireyi seçin), gerekirse yeniden yazın |
| "Güvenlik Durumu Okunamadı" | Yazımdan ya da alarm onayından sonra `SAFETY` okunamadı; bölgelerin durumu bilinmiyor | USB bağlantısını kontrol edip **Alarmı Onayla (USB)**'ya basın |
| "Alarm Sürüyor" / "… vana ARIZASINDA (FAULT …) … temizlemez" | Bölge hâlâ kilitli ya da geri bildirimli vana "kapalı" görülmedi (FAULT; onay temizlemez) | Girişi DI-GND köprüleyin; FAULT için vanayı ve geri bildirim kablosunu bağlayın, sonra yeniden onaylayın |
| "Teslim Edilemez" | Daireye kart bağlı değil ya da şablon henüz yazılmadı (durum Planlandı) | Önce **Kart Bağla**, sonra **Karta Yaz**; daire **Yazıldı** olunca teslim edin |
| "provizyonu bu yoldan kabul etmedi" (`factory_ap_only`) | Eski firmware | Firmware'i güncelleyin ya da USB ile provizyon yapın |

---

## 5. Yedek yol: Wi-Fi ile provizyon (GÜVENSİZ — yalnızca gerekirse)

USB (seri) provizyon **birincil ve güvenli** yoldur: anahtar hiçbir zaman havadan geçmez. Yalnızca USB seri **hiç çalışmıyorsa** (ör. bilgisayarda gerekli bileşen yok) yedek yolu kullanın.

**Neden güvensiz?** Yeni yazılan kart, provizyon bitene kadar **parolasız (açık)** bir Wi-Fi ağı yayınlar. Wi-Fi yolunda anahtar ve parola bu açık ağdan **düz (şifresiz) HTTP** ile gönderilir: menzildeki biri dinleyebilir veya kartı kendisi sahiplenebilir. Bu yüzden yalnızca **kontrollü ortamda** (fabrika içi, yabancı olmayan alanda) ve **flash'tan hemen sonra** yapın.

Araç USB'yi kullanamazsa kendisi size sorar: *"USB (Seri) Provizyon Yapılamadı - Yedek Yol?"* — onaylamazsanız hiçbir şey kablosuz gönderilmez.

**Elle başlatmak için (3. sekme):**

1. **Wi-Fi ile Provizyonla (güvensiz yedek yol)** düğmesine basın; çıkan uyarıyı okuyup onaylayın.
2. Bilgisayarın Wi-Fi'sini kartın ağına bağlayın: ağ adı etikette **"Kurulum Wi-Fi Ağı"** ve 3. sekmede **SSID** olarak yazar (örn. `AHBU-DD8754`). Provizyonsuz kartta bu ağın **parolası yoktur**. (Ağ, kart açılınca yayına başlar ve yaklaşık 10 dakika açık kalır; bilgisayar bağlıysa en çok 30 dakikaya uzar. Kapanırsa kartın USB'sini çıkarıp takın.)
3. Araç kartı bulunca anahtarı yazar. Kart ağını **parolalı** yapınca bağlantınız kopar.
4. Bilgisayarı aynı ağa, etikette yazan **Ağ Parolası (AP)** ile yeniden bağlayın ve **Wi-Fi ile Doğrula**'ya basın.
5. İşiniz bitince bilgisayarı normal (internetli) ağınıza geri alın.

Ayrıntılı elle adımlar için **Elle Provizyon Talimatı** düğmesine basın.

### 5b. Ethernet ile provizyon (firmware v1.3.0+)

Kart atölye ağına **Ethernet kablosuyla** bağlıysa provizyon USB'siz de yapılabilir:

1. Firmware'i USB'den yükleyin (otomatik USB provizyonu çalışırsa bu adıma gerek kalmaz).
2. Kartın Ethernet IP adresini öğrenin (modem/DHCP listesi ya da seri `STATUS` çıktısındaki `Ethernet:` satırı).
3. 3. sekmede **Ethernet ile Provizyonla**'ya basın ve IP'yi girin (yalnız yerel/özel IP kabul edilir). Araç kartın kimliğini
   denetler, anahtarı yazar ve doğrular; kart erişilebilir kaldığı için ayrıca yeniden bağlanmanız gerekmez.
4. **Doğrulama nasıl yapılır?** Kart kablolu Ethernet'ten gelen isteği **anahtarsız** kabul ettiği için (kullanıcı kararı 2026-10-08)
   "anahtar doğru mu?" sorusu Ethernet'te hiçbir şey kanıtlamaz. Araç bu yüzden kartın **provizyon durumuna** ve (firmware v1.3.1)
   kartın bildirdiği **anahtar izine** bakar. Kart zaten provizyonluysa: iz bu kayıttaki anahtarla eşleşirse "Kart bu kayıttaki
   anahtarla zaten provizyonlu (anahtar izi eşleşti)"; eşleşmezse
   **"Kartta farklı bir yerel anahtar var; USB ile bağlayıp RESETKEY + yeniden provizyon yapın."**; kart iz bildirmiyorsa (v1.3.0)
   **"Kart zaten provizyonlu; Ethernet yolu anahtarı doğrulayamaz…"**.
   Son iki durumda araç **"Ethernet ile Doğrulanamadı"** penceresinde USB (seri) provizyonu (`RESETKEY` ile) başlatmayı önerir.
5. Anahtar yazıldı ama doğrulama sırasında karta ulaşılamadıysa (kablo/ağ) durum **"Anahtar yazıldı (Ethernet …) - doğrulama
   bekliyor"** olur: kabloyu kontrol edip **Ethernet ile Provizyonla**'ya yeniden basın (anahtar yeniden **yazılmaz**, yalnız Ethernet
   IP'sinden doğrulanır) ya da **Wi-Fi ile Doğrula**'ya basın (bu kayıtta o da Ethernet IP'sine gider, `192.168.4.1`'e değil).

**Bilinmesi gereken (kullanıcı kararıyla kabul edildi):** anahtar yerel ağdan düz HTTP ile gider ve aynı ağdaki başka bir
bilgisayar da provizyonsuz kartı ilk sahiplenebilir. Kartı Ethernet'e bağladıktan sonra provizyonu **hemen** yapın; mümkünse
yalnız atölye bilgisayarlarının olduğu ayrı bir ağ kullanın.

### 5c. Sunucudaki anahtarla yeniden provizyon (bellekte kayıt yoksa)

Önceden kaydedilmiş bir kartın anahtarı silindiyse (birleşik imaj yüklendi ya da **Hafızayı Sil** yapıldı) ve bu kartın kaydı
aracın belleğinde yoksa, kartı yeniden kaydetmek **gerekmez** (yeniden kayıt sunucuda reddedilir):

1. Kartı USB ile bağlayın, 1. sekmede COM portu seçin.
2. 3. sekmede **Sunucudaki Anahtarla Yeniden Provizyon (USB)**'a basın (birleşik imajdan sonra araç bunu kendisi önerir).
3. Araç kartın kimliğini (`STATUS`) okur, onayınızı alır, girişinizi ister (süper kullanıcı ya da servis sorumlusu) ve kartın
   **yerel anahtarını sunucudan alır** (gösterilmez; alma işlemi sunucuda kayda geçer).
4. Etiketteki **AP parolasını** sorulan kutuya aynen yazın (değer gösterilmez, saklanmaz).
5. Araç `FACTORYINIT` ile yazar ve `STATUS` ile doğrular ("Yeniden Provizyon Tamamlandı"). **Etiket geçerli kalır.** Kartta şablon
   vardıysa araç onun da silindiğini söyler: şablonu **Karta Yaz** ile yeniden yazın.

---

## 6. Güvenlik uyarıları

| Konu | Kural |
|---|---|
| **Açık Wi-Fi penceresi** | Yeni yazılan kart, provizyon bitene kadar parolasız `AHBU-XXXXXX` ağını yayınlar. Firmware'den sonra kartı **provizyonsuz** bırakmayın; USB'yi çıkarmayın. Provizyon yarım kaldıysa kartın gücünü kesin veya hemen provizyonu tamamlayın. |
| **Etiket** | PIN ve AP parolası **yalnızca etikettedir**. Etiket **yalnızca cihaz üzerinde veya elde** saklanır; fotoğrafı (karekodlar dahil) WhatsApp/e-posta/sosyal medya ile **paylaşılmaz**. Etiketi karta yapıştırın; basılı fazla/bozuk etiketleri **parçalayın**. |
| **2. karekod (Wi-Fi)** | Karekodun içinde kartın kurulum ağı adı ve **parolası** vardır: karekodu okutan herkes kartın ağına bağlanabilir. Bu yüzden etiket, 1. karekodla (PIN) birlikte aynı gizlilikte korunur. Telefon kamerasıyla yalnızca **kendi elinizdeki** etiketi okutun. |
| **PNG etiket dosyası** | Yazdırdıktan sonra silin (Çöp Kutusu'nu da boşaltın). Araç dosyayı kendiliğinden diske yazmaz. |
| **Hesap** | Süper kullanıcı parolanızı kimseyle paylaşmayın; araç parolayı **kaydetmez**. **Beni hatırla** yalnızca şifreli oturum anahtarını (bu Windows kullanıcısına bağlı) saklar; ortak bilgisayarda işaretlemeyin. Ayrılırken **Oturumu Kapat** (hatırlanan oturumu siler ve sunucuda iptal eder). |
| **Bir kez gösterilen bilgi** | PIN/anahtar kaybolursa **geri alınamaz** (sunucuda yalnızca özeti vardır). Çözüm: kaydı (yalnızca Durum'u `IN_STOCK` ise) **Envanterden Sil** ile silip kartı yeniden kaydetmek. Silme, cihaz UID'sini yazarak onaylanır; eşlenmiş cihaz silinemez. |
| **Panoya kopyalama** | "Anahtarı kopyala / AP parolasını kopyala" 45 sn sonra panodan silinir; yine de başka yere yapıştırmayın. |
| **Wi-Fi yedek yolu** | Yalnızca kontrollü ortamda, USB mümkün değilse (Bölüm 5). |
| **Yanlış kart** | Araç, karttaki MAC ile kaydı karşılaştırır. Uyuşmazlık uyarısı çıkarsa **durun**, doğru kartı bağladığınızı kontrol edin. |

---

## 7. Sorun giderme (hata → anlamı → ne yapmalı)

Aracın gösterdiği mesajlar sade Türkçedir; ham teknik ayrıntı göstermez. Aşağıdaki tablolar en sık karşılaşılanlardır.

### Giriş ve sunucu

| Gördüğünüz mesaj | Anlamı | Ne yapmalı? |
|---|---|---|
| E-posta veya parola hatalı. | Giriş bilgisi yanlış. | Bilgileri kontrol edin (Caps Lock?). Çok denerseniz hesap kısa süre kilitlenir. |
| Bu araç yalnızca süper kullanıcı veya servis sorumlusu hesabıyla çalışır (bu hesabın rolü: …) | Hesabınız yetkili değil. | Yöneticinizden süper kullanıcı (kart kaydı) ya da servis sorumlusu (site/şablon) hesabı isteyin. |
| Çok fazla istek/deneme yapıldı… N saniye sonra tekrar deneyin. / …geçici olarak kilitlendi. | Çok sayıda deneme yapıldı. | Belirtilen süre kadar bekleyin, sonra tekrar deneyin. |
| Hesap dondurulmuş. / Hesap henüz etkinleştirilmemiş (davet bekliyor). | Hesap kullanıma kapalı. | Sistem yöneticisine başvurun. |
| Sunucuya ulaşılamadı… (… cihazın kurulum Wi-Fi ağına bağlıysa internet yoktur…) | İnternet yok veya bilgisayar kartın Wi-Fi'sine bağlı. | Bilgisayarı **normal internetli ağa** geri alın; tekrar deneyin. |
| Sunucu adı çözümlenemedi (DNS). / Sunucu bağlantıyı reddetti (kapalı olabilir). | Ağ/DNS sorunu veya sunucu kapalı. | İnternet bağlantısını ve sunucu adresini kontrol edin; sürerse IT'ye bildirin. |
| Sunucu zamanında yanıt vermedi (zaman aşımı). | Yavaş/kopuk bağlantı. | Bağlantıyı kontrol edip tekrar deneyin. |
| Sunucunun güvenlik sertifikası doğrulanamadı… / Güvenli bağlantı (TLS) kurulamadı. | Bilgisayarın tarih/saati yanlış veya ağ filtreli. | Tarih/saati düzeltin; sürerse IT'ye bildirin. **Asla** güvenlik uyarısını geçmeye çalışmayın. |
| Sunucuda beklenmeyen bir hata oluştu… (Hata ref: …) | Sunucu tarafında sorun. | Biraz sonra tekrar deneyin; sürerse **Hata ref** kodunu IT'ye iletin. |
| Oturum süresi doldu / Oturum geçersiz veya sonlandırılmış… | Oturum kapandı. | **Sunucuya Giriş** ile yeniden giriş yapın. |
| [UYARI] Kayıtlı oturum artık geçerli değil; kayıt silindi. Yeniden giriş yapın. | Hatırlanan oturum sunucuda sona ermiş ya da iptal edilmiş (ör. başka yerden "tüm cihazlardan çıkış", uzun süre kullanılmadı) ya da hesap artık süper kullanıcı değil. | **Sunucuya Giriş** ile yeniden giriş yapın. |
| [UYARI] Kayıtlı oturum şimdi denetlenemedi (ağ/sunucu); kayıt korundu… | İnternet yok ya da sunucu geçici olarak yanıt vermiyor; kayıt SİLİNMEDİ. | Bağlantıyı düzeltip aracı yeniden açın ya da **Sunucuya Giriş** ile elle girin. |
| [UYARI] Kayıtlı oturum başka bir sunucu adresine ait… | Kayıt farklı bir sunucu (ör. QA adresi) için alınmış; oturum anahtarı başka sunucuya GÖNDERİLMEZ. | Doğru sunucu adresiyle giriş yapın. |
| Düz http yalnızca yerel test (127.0.0.1) için kabul edilir… | Sunucu adresi güvenli değil (http://). | Adresi `https://…` olarak yazın; yönetici verdiyse onu kullanın. |

### Kayıt (2. sekme)

| Gördüğünüz mesaj | Anlamı | Ne yapmalı? |
|---|---|---|
| Lütfen geçerli bir MAC adresi girin… | MAC okunmadı/yanlış. | **Karttan MAC Oku**'ya basın. |
| MAC Okunamadı: Kart zamanında yanıt vermedi. / Çipten MAC adresi okunamadı. | Kart yükleme moduna girmedi veya port/kablo sorunu. | **BOOT** düğmesini basılı tutup **RESET**'e bir kez basın, sonra BOOT'u bırakıp tekrar deneyin; portu ve kabloyu kontrol edin. |
| UID MAC ile Uyuşmuyor | UID elle değiştirilmiş. | **Hayır** deyin; **UID Üret (MAC'ten)**'e basın. |
| Mükerrer Cihaz Uyarısı (aynı UID/MAC zaten kayıtlı) | Kart daha önce kaydedilmiş (ör. yarıda kalan bir deneme). | PIN ve anahtar yeniden gösterilemez. Etiketi **kayıpsa**: kart USB'de takılıyken **Etiketi Yeniden Bas (USB)** (yeni PIN + yeni AP parolası; anahtar değişmez). Kartın anahtarı silindiyse **Sunucudaki Anahtarla Yeniden Provizyon (USB)** (Bölüm 5c). Kaydı silip yeniden kaydederseniz yeni anahtar üretilir: kart önceden provizyonlandıysa USB ile RESETKEY gerekir. |
| Sunucudaki ilgili özellik şu anda kullanılamıyor (yapılandırma eksik olabilir). | Sunucu ayarı eksik. | Sistem yöneticisine bildirin; kayıt yapılamaz. |
| Sunucu yanıtı eksik: cihaz anahtarı alınamadı… | Kayıt yapıldı ama anahtar alınamadı. | Envanter listesini yenileyin; kart görünüyorsa **Envanterden Sil** ve yeniden kaydedin. |
| Silme Onayı → "UID eşleşmedi; silme işlemi yapılmadı." | Silme için yazdığınız UID eşleşmedi. | UID'yi tablodaki gibi aynen yazın (kopyala-yapıştır). |
| Önceki Cihaz Tamamlanmadı | Önceki kartın provizyonu bitmedi. | **Hayır** deyip önce onu tamamlayın. **Evet** derseniz önceki kartın PIN/anahtarı **bir daha gösterilemez**. |
| Etiket dosyası yazılamadı… | Seçtiğiniz yere yazma izni yok. | Başka bir klasör seçin. |
| Etiket yazıcıya gönderilemedi. | Yazıcı/varsayılan yazıcı sorunu. | Kaydedilen PNG'yi açıp elle yazdırın. |

### Firmware yükleme (1. sekme)

| Gördüğünüz mesaj | Anlamı | Ne yapmalı? |
|---|---|---|
| Port Seçilmedi / Port bulunamadı (USB bağlayın) | Kart USB'de görünmüyor. | Veri destekli kablo kullanın; başka USB girişi deneyin; **Portları Yenile**. |
| `Failed to connect to ESP32-S3` (logda) | Kart yükleme moduna girmedi. | **BOOT** düğmesini basılı tutun, **RESET**'e bir kez basıp bırakın, sonra BOOT'u bırakın; tekrar deneyin. (Bu yöntem kartı yükleme kipinde bırakır: araç sonra kartın ayarlarını okuyamaz ve **"Kart Durumu Okunamadı"** diye sorar.) |
| Dosya Sorunu: … | Firmware dosyası yok/bozuk. | **Gözat** ile doğru `.bin` dosyasını seçin veya "Bizim Geliştirdiğimiz Yazılım"ı yeniden seçin. |
| Dosya Sorunu: …BİRLEŞİK imaj değil (0x8000'de bölüm tablosu yok)… | 0x0 kipine uygulama imajı seçildi (kart açılmazdı; yazılmadı). | Birleşik imajı (`firmware_combined_0x0.bin`) seçin ya da kurulu kart için **Güncelle (ayarlar korunur)** kipini kullanın. |
| Dosya Sorunu: …'Güncelle (ayarlar korunur)' kipinde 0x10000 adresine yazılamaz | Güncelle kipine birleşik imaj seçildi. | `app_0x10000_v<sürüm>.bin` dosyasını seçin. |
| Kart Ayarları Silinecek | Kartta yerel anahtar ya da şablon var; birleşik imaj hepsini siler. | Kurulu kartsa **Hayır** (araç **Güncelle (ayarlar korunur)** kipine geçer ve seçtiğiniz birleşik imajla aynı klasördeki uygulama imajını seçer). Kartı bilerek sıfırlıyorsanız **Evet**. |
| Güncelle Kipi Seçildi: … uygulama imajı (`app_0x10000_v<sürüm>.bin`) yok … | Seçtiğiniz birleşik imajın klasöründe aynı sürümün uygulama imajı yok (ya da birden çok aday var); araç başka sürüme sessizce geçmez. | **Gözat...** ile birleşik imajla aynı sürümün `app_0x10000_v<sürüm>.bin` dosyasını seçin. |
| Kart Durumu Okunamadı | Birleşik imajdan önce kartın ayarları okunamadı: port/bağlantı hatası ya da kart **yükleme kipinde** (BOOT+RESET ile açılmış). Kart kurulu olabilir. | Kurulu kartsa **Hayır**; kartı **BOOT'a basmadan** RESET'leyip FLASH'a yeniden basın. Kartın boş/yeni olduğundan eminseniz **Evet**. |
| Güncelleme Yapılamadı | Güncelle kipi kartta AHBU firmware'i doğrulayamadı (~10 sn STATUS yanıtı yok, kart yükleme kipinde ya da port/bağlantı hatası); hiçbir şey yazılmadı. | **BOOT'a basmadan** RESET'e bir kez basın, birkaç saniye bekleyip FLASH'a yeniden basın; kablo/portu kontrol edin. Kart gerçekten yeni/boş ya da Waveshare yazılımlıysa (ayarı yoksa) birleşik imajı kullanın. |
| Sürüm Düşürme Engellendi | Kartta v1.3.0+ çalışıyor; Güncelle kipinde seçilen uygulama imajında v1.3.0 özellikleri yok (ör. elle seçilmiş v1.2.1). Yazılsaydı ayarlar kalır ama Ethernet, şablon ve panonun kendi bulut kimliği giderdi (yalnız Ethernet'le bağlı kart çevrimdışı kalırdı). | **Gözat...** ile `v1.3.0\app_0x10000_v1.3.0.bin`'i seçip FLASH'a yeniden basın. |
| Sürüm Düşürme | Kartta v1.3.0+ çalışıyor; seçilen birleşik imaj daha eski. | Kartı bilerek eski sürüme döndürmüyorsanız **Hayır**; **Gözat...** ile v1.3.0+ birleşik imajını seçin. Kabul edip ardından "Kart Ayarları Silinecek"e **Hayır** derseniz hiçbir şey yazılmaz (eski sürüm kartın ayarları korunarak yazılamaz). |
| Firmware Uyarısı: …USB (seri) provizyon komutu (FACTORYINIT) bulunamadı… ESKİ firmware | İmaj eski sürüm: kart USB ile provizyonlanamaz. | **Hayır** deyin; IT'den güncel imajı isteyin (Teknik Ek E). Yine de **Evet** derseniz kartı provizyonlayamazsınız. |
| Firmware Uyarısı: Bu imajla … çalışmaz (v1.3.0+ gerekli). | İmajda USB şablon / Ethernet şablon / panonun kendi bulut kimliği yok (ör. v1.2.1). | Engellemez. Bu özellikler gerekecekse v1.3.0+ imajı kullanın. Kartta zaten v1.3.0+ varsa yoklamadan sonra **Sürüm Düşürme** sorusu çıkar (Güncelle kipinde yazılmaz). |
| esptool Bulunamadı | Yükleme programı kurulu değil. | IT'ye bildirin. |
| Meşgul: Kartla başka bir işlem sürüyor | Başka bir işlem bitmedi. | Bitmesini bekleyin. |
| Zaman Aşımı: İşlem zamanında bitmedi… | Kablo/port sorunu. | Kabloyu yeniden takıp tekrar deneyin. |
| Hata (Hata Kodu: 2) | Yükleme başarısız. | Logu okuyun; BOOT+RESET yöntemiyle tekrar deneyin. |

### USB (seri) provizyon (3. sekme)

| Gördüğünüz mesaj | Anlamı | Ne yapmalı? |
|---|---|---|
| Seri port bulunamadı (COMx). | Port görünmüyor (kart yeniden başlarken kısa süre normal). | Birkaç sn bekleyin; kablo/portu kontrol edin; 1. sekmede **Portları Yenile**; tekrar deneyin. |
| Seri port başka bir programda açık. | Başka bir program portu tutuyor. | Seri monitör, PuTTY, Arduino/PlatformIO terminalini **kapatın**; tekrar deneyin. |
| Seri bağlantı koptu. | Kablo çıktı/kart yeniden başladı. | Kabloyu kontrol edip **Seri (USB) ile Provizyonla**'ya yeniden basın. |
| Kart seri komutlara yanıt vermedi. | Kartta güncel AHBU firmware'i çalışmıyor (eski imaj yüklenmiş olabilir) veya kart takılı kalmış. | Önce **güncel** firmware'in yüklendiğinden emin olun; USB'yi çıkarıp takın; BOOT basılı olmasın; tekrar deneyin. Araç sonra yedek Wi-Fi yolunu önerirse yalnızca kontrollü ortamda kabul edin. |
| Bağlı kartın MAC adresi (…) bu kayıtla (…) eşleşmiyor. | **Yanlış kart** bağlı. | **Durun.** Doğru kartı bağlayın. Yanlış karta yazılmaz. |
| Kartta zaten bir yerel anahtar var (provizyonlu). → "Kartta Eski Anahtar Var" sorusu | Kart daha önce provizyonlanmış. | Yeni/fabrika kartıysa **Evet** (anahtarı sıfırlayıp yeniden yazar; eski anahtar kullanılamaz olur). Müşteride/dairede kullanılmış bir kartsa **Hayır** deyip yöneticiye danışın. |
| Kart anahtarı kalıcı belleğe yazamadı (persist_failed). | Kartın belleği yazmadı (araç 3 kez dener). | Kartı USB'den çıkarıp takın, tekrar deneyin; sürerse **Hafızayı Sil (Erase Flash)** + firmware'i yeniden yükleyin. |
| Kart 'OK' dedi ama yerel anahtar STATUS çıktısında görünmüyor. | Doğrulama başarısız. | Tekrar deneyin; sürerse **Hafızayı Sil** + yeniden yükleyin. |
| Karttaki yerel anahtarın izi (STATUS 'Anahtar izi') bu kayıttaki anahtarla eşleşmiyor. | Kartta başka bir anahtar var (firmware v1.3.1). | "Kartta Eski Anahtar Var" sorusuna **Evet** (RESETKEY + yeniden yazım). |
| Bu yazılım buluta kendiliğinden bağlanamaz; bireysel sahiplenme için v1.3.0+ yükleyin. | Kartta v1.3.0'dan eski firmware var (uyarıdır; provizyon tamamlandı). | Müşteri kartı kendisi sahiplenecekse v1.3.0+ yükleyin (kurulu kartta **Güncelle (ayarlar korunur)**). |
| Kart yerel anahtarı reddetti (invalid_local_key). / Kart AP parolasını reddetti (invalid_ap_pass). | Araç–firmware sürüm uyumsuzluğu. | Kartı yeniden kaydedin; sürerse IT'ye bildirin. |
| Kart eski yerel anahtarı silemedi (RESETKEY). | Sıfırlama komutu işlemedi. | Kartı USB'den çıkarıp takın ve tekrar deneyin; sürerse **Hafızayı Sil (Erase Flash)** + firmware'i yeniden yükleyin. |
| Kartın yanıtı anlaşılamadı… | Beklenmeyen firmware yanıtı. | Firmware sürümünü kontrol edin (güncel imaj), tekrar deneyin. |
| Seri port açılamadı. | Port açılamadı (sürücü/kablo). | Başka bir USB kablosu veya USB girişi deneyin. |
| USB (seri) provizyon bu bilgisayarda kullanılamıyor. | Bilgisayarda gerekli bileşen (pyserial) yok; araç yeni paket **kurmaz**. | IT'ye bildirin (PlatformIO kuruluysa araç onun pyserial'ını kullanır). Gerekirse Bölüm 5'teki yedek yolu (kontrollü ortamda) onaylayın. |
| İşlem iptal edildi. | **Beklemeyi İptal Et**'e bastınız. | Hazır olunca **Seri (USB) ile Provizyonla**'ya yeniden basın. |

### Etiket ve telefonla bağlanma (2. karekod)

| Gördüğünüz durum | Olası neden | Ne yapmalı? |
|---|---|---|
| Telefon kamerası 2. karekodu okumuyor. | Etiket bulanık/küçük basılmış, ışık yansıması, karekod ekranda net değil. | Etiketi düz tutup yansımayı azaltın ve netleştirin. Hâlâ okunmazsa ağı elle bağlayın (aşağıdaki satır). Baskı bulanıksa yazıcı ayarında "sayfaya sığdır / büyüt"ü kapatıp **Etiketi Kaydet → Yazdır** ile yeniden basın. |
| Karekod okunuyor ama telefon ağa bağlanamıyor ("parola yanlış"). | Etiket başka karta ait olabilir; kart provizyonsuz (kurulum ağı parolasız) ya da kayıt/etiket eşleşmemiş. | 3. sekmede **"Provizyon doğrulandı"** yazdığını ve etiketteki ağ adının kartınkiyle aynı olduğunu kontrol edin. Kartı USB'den çıkarıp takın. Sürerse kaydı silip (Durum `IN_STOCK` ise) kartı yeniden kaydedin. |
| `AHBU-XXXXXX` ağı telefonda/ağ listesinde yok. | Ağ penceresi (yaklaşık 10 dk) kapandı veya kart kapalı. | Kartın USB'sini çıkarıp takın, yarım dakika bekleyin; telefonu karta yaklaştırın. |
| Telefon bağlandıktan sonra "internet yok" diyor. | Normal: kurulum ağında internet yoktur. | Bir şey yapmayın; işiniz bitince telefonu normal ağınıza geri alın. |
| Telefon karekodu okuyup bir internet adresi (`.../claim?...`) açıyor ya da AHBU uygulaması açılıyor. | **1. karekodu** (Daireye bağla) okuttunuz. | Kurulum ağına bağlanmak için geri dönün ve telefonun kamerasıyla **2. karekodu** (sağdaki) okutun. 1. karekod sahiplenme içindir: Android'de uygulamayı doğrudan açar (2026-10-09); uygulama kurulu değilse ya da iPhone'da tarayıcıda yönlendirme sayfası açılır. |
| Etiketteki ikinci karekodun yerinde kırmızı kutu ve "Wi-Fi karekodu üretilemedi" yazıyor. | MAC veya AP parolası geçersiz görünüyor. | Etiketi kullanmayın. Kartı yeniden kaydedin (Adım 2-3); sürerse IT'ye bildirin. |

### Wi-Fi yedek yolu

| Gördüğünüz mesaj | Anlamı | Ne yapmalı? |
|---|---|---|
| Cihaza ulaşılamadı. | Bilgisayar kartın Wi-Fi ağında değil. | Bilgisayarı `AHBU-XXXXXX` ağına bağlayın; ağ görünmüyorsa kartı USB'den çıkarıp takın; kart daha önce bir Wi-Fi'ye kaydedildiyse önce **Hafızayı Sil**. |
| Bu adres bir AHBU cihazı gibi yanıt vermedi (HTTP …). | Başka bir cihaza (örn. modem) bağlanıldı. | Doğru ağda olduğunuzdan emin olun. |
| Bağlanılan cihaz bu kayıtla eşleşmiyor (cihaz UID'si: …). | Yanlış kart. | Doğru kartın ağına bağlanın. |
| Cihaz zaten provizyonlu (başka bir anahtarla kurulmuş). | Kartta başka (eski) bir anahtar var. | Kayıt hâlâ provizyon bekliyorsa kartı USB ile bağlayıp **Seri (USB) ile Provizyonla** → "Kartta Eski Anahtar Var" sorusuna **Evet** (USB tablosu, yukarıda). Ya da aracın önerdiği gibi seri terminalden (115200 baud) `RESETKEY` gönderin (kurulum ağı açılmazsa ardından `AP ON`) ve tekrar deneyin. |
| Cihaz anahtarı kalıcı belleğe yazamadı (storage). | Kart, anahtarı kendi kalıcı belleğine (NVS) yazamadı (firmware v1.1.2 bunu `503 storage` ile açıkça bildirir). | Kartı yeniden başlatıp tekrar deneyin; sürerse **Hafızayı Sil (Erase Flash)** ile firmware'i yeniden yükleyin. |
| Cihaz meşgul. / Cihaz geçici olarak kilitli. | Kart yoğun / çok deneme. | Belirtilen süre bekleyip tekrar deneyin. |

### Diğer

| Gördüğünüz mesaj | Ne yapmalı? |
|---|---|
| Beklenmeyen Hata (…) | Aracı kapatıp yeniden açın; sürerse IT'ye bildirin. Teknik inceleme için `EV_TOOL_DEBUG=1` ortam değişkeniyle açılabilir (Teknik Ek). |
| Provizyon Tamamlanmadı (pencereyi kapatırken) / Kaydı Sil (**Kaydı Bellekten Sil / Yeni Cihaz**'e basarken) | **Hayır** deyin ve provizyonu bitirin. **Evet** derseniz PIN/anahtar bir daha gösterilemez. |
| Önceki Cihaz Tamamlanmadı (yeni kayıt yaparken) | **Hayır** deyin ve önceki kartın provizyonunu bitirin. |
| İşlem Sürüyor (pencereyi kapatırken) | Kartla işlem sürerken kapatmayın; kart yarım kalabilir. |
| Meşgul: USB (seri) provizyon sürüyor… | Provizyon bitene kadar flash/MAC okuma yapılamaz; bekleyin veya **Beklemeyi İptal Et**. |
| Eksik Paket (araç hiç açılmıyor) | IT'ye bildirin: bilgisayarda `qrcode` / `pillow` kurulu değil (Teknik Ek A). |

---

## 8. Sık sorulan sorular

**Kartı daha önce yazılımla yüklemiştim; şimdi mi kaydetsem?**
Evet. 2. sekmede kaydı yapın, sonra 3. sekmede **Seri (USB) ile Provizyonla (Önerilen)**'e basın (kart USB'de takılı olmalı). Firmware'i yeniden yüklemeniz gerekmez.

**Provizyon ne kadar sürer?**
Firmware yükleme yaklaşık 30–60 sn; provizyon kartın yeniden başlamasını beklediği için birkaç on saniye sürer (kart yanıt vermezse araç en çok yaklaşık yarım dakika bekler). Süreler gerçek kartla ölçülmemiştir.

**Etiketi kaybettim / bozuldu. Yeniden basabilir miyim?**
Aynı etiketi hayır: PIN yalnızca bir kez gösterilir. Kart stokta ise (Durum `IN_STOCK`) ve hiçbir daireye bağlı değilse, kart USB'de takılıyken 2. sekmede **Etiketi Yeniden Bas (USB)**'a basın (süper kullanıcı): sunucu **yeni PIN** üretir, araç karta **yeni AP parolası** yazar, kartın yerel anahtarı **değişmez**; yeni etiket iki karekodla hazırlanır. Eski etiketi imha edin.

**Kurulu (provizyonlu, şablonlu) bir kartın yazılımını nasıl güncellerim?**
Firmware Yükleyici sekmesinde **Güncelle (ayarlar korunur)** kipini seçin: yalnız uygulama imajı (`app_0x10000_v<sürüm>.bin`) yazılır; anahtar, AP parolası, Wi-Fi, bulut kimliği, şablon ve güvenlik ayarları korunur, etiket geçerli kalır. **Birleşik imaj** bunların hepsini siler (araç önce sorar). Kipin varsayılan dosyası `version_info.json`'daki sürümün (v1.3.2) uygulama imajıdır. Elle daha eski bir imaj (ör. v1.2.1) seçilirse ve kartta v1.3.0+ çalışıyorsa bu sürüm düşürme olur, araç yazmaz (**"Sürüm Düşürme Engellendi"**); **Gözat...** ile v1.3.0+ uygulama imajını (`v1.3.1\app_0x10000_v1.3.1.bin` ya da `v1.3.0\app_0x10000_v1.3.0.bin`) seçin.

**Yanlışlıkla birleşik imaj yükledim / Hafızayı Sil yaptım; kartın anahtarı silindi. Ne yapmalıyım?**
Kartın kaydı aracın belleğindeyse araç aynı anahtar ve AP parolasıyla kendisi yeniden provizyon yapar. Değilse 3. sekmede **Sunucudaki Anahtarla Yeniden Provizyon (USB)** kullanın (Bölüm 5c); kartı yeniden kaydetmeyin. Kartta şablon vardıysa yeniden yazın.

**Atölyede şablon yazınca kart siren çalıp vanayı kapattı. Bozuldu mu?**
Hayır. Şablonda NC bağlı gaz/duman/su sensörü var ve girişe henüz dedektör bağlı değil: kart bunu "kablo koptu / alarm" sayar (bilerek böyle tasarlandı). Girişi DI ile GND arasında köprüleyin, **Alarmı Onayla (USB)**'ya basın; kuruluk bekleme süresi dolunca bölge normale döner. Bir dahaki sefere köprüyü yazmadan önce takın (araç **"NC Tehlike Girişi"** penceresinde hatırlatır).

**Etiketteki iki karekod ne işe yarar?**
**1) Daireye bağla (uygulama):** müşteri/kurulum teknisyeni uygulamayla okutur; cihaz daireye bağlanır. **2) Kurulum Wi-Fi'sine bağlan (telefon kamerası):** servis teknisyeni telefonun kendi kamerasıyla okutur; telefon kartın kurulum ağına (`AHBU-XXXXXX`) tek dokunuşla bağlanır, parolayı elle yazmak gerekmez.

**Müşteri PIN'i nereden bilecek?**
Müşteri/kurulum teknisyeni uygulamadan etiketteki **1. karekodu** okutur; PIN o karekodun içindedir (ayrıca etikette de yazar).

**Aynı anda iki kart hazırlayabilir miyim?**
Hayır; tek kart takılı olsun.

**Kartı bozmuş olabilir miyim?**
Bu araç yalnızca firmware yükler/okur. Yanlış dosya seçilirse araç uyarır. Kart açılmazsa BOOT+RESET yöntemiyle firmware'i yeniden yükleyin.

**Wi-Fi şifresini nereden girerim?**
Fabrikada girilmez. Müşteri/teknisyen kurulumda uygulamayla (servis sihirbazı) ev Wi-Fi'sini ve bulut bağlantısını yapar.

---

## 9. Donanıma kısa bakış

Waveshare **ESP32-S3-ETH-8DI-8RO** endüstriyel pano modülü (DIN-ray):

| Özellik | Değer |
|---|---|
| İşlemci | ESP32-S3 (çift çekirdek, 240 MHz), Wi-Fi + BLE 5 |
| Röle çıkışları | 8 adet (10 A 250 V AC / 10 A 30 V DC), optik izoleli |
| Dijital girişler | 8 adet opto-izole (kuru kontak: duvar butonu, kapı manyetiği…) |
| Haberleşme | RS485 (izole, Modbus RTU), USB Type-C (güç + COM port + yazılım yükleme), Ethernet (RJ45, W5500) |
| Besleme | 7–36 V DC (klemens) veya 5 V USB |
| Yardımcı | Buzzer, WS2812 RGB LED, PCF85063 gerçek zamanlı saat (RTC), microSD yuvası |
| Kasa | DIN-ray ABS kutu |

> **Not:** AHBU firmware'i **v1.3.0'dan itibaren Ethernet (RJ45, W5500)** kullanır: kart Wi-Fi ya da kablolu Ethernet'ten buluta bağlanır; atölyede provizyon ve şablon yazımı Ethernet'ten de yapılabilir (kablolu Ethernet'ten gelen yerel istek **anahtarsız** kabul edilir — kullanıcı kararı 2026-10-08; Wi-Fi ve kurulum ağından gelenler anahtarlıdır). v1.2.x ve öncesi yalnız Wi-Fi kullanır. Bluetooth donanımda vardır ama kullanılmaz. Müşteri tarafı **mobil uygulama + bulut (MQTT)** üzerinden çalışır.

### Pin haritası

| Donanım | Pin / çip | İşlevi |
|---|---|---|
| 8 röle | TCA9554PWR (I2C) | `EXIO1…EXIO8` ile röleler sürülür |
| 8 dijital giriş | GPIO4…GPIO11 | DI1=4, DI2=5, DI3=6, DI4=7, DI5=8, DI6=9, DI7=10, DI8=11 |
| RS485 | GPIO17 (TX), GPIO18 (RX) | Harici modül / okuyucu |
| Buzzer | GPIO46 | Sesli bildirim |
| RGB LED | GPIO38 | Durum ışığı |
| RTC | PCF85063 (I2C) | SCL=41, SDA=42 (röle çıkış yongasıyla aynı I2C hattı) |
| BOOT düğmesi | GPIO0 | Yükleme/kurtarma |
| Ethernet (W5500) | SPI | CS=16, SCLK=15, MOSI=13, MISO=14, INT=12, RST=39 (firmware v1.3.0+ ile etkin) |

---

## 10. Tesisat notları (panjur ve aydınlatma)

### Panjur motoru güvenlik kilidi (interlock)

- Panjur tüp motorlarında 4 kablo vardır: nötr (mavi), toprak (sarı-yeşil), yukarı fazı (kahverengi), aşağı fazı (siyah).
- **Tehlike:** Yukarı ve aşağı fazı **aynı anda** verilirse motor yanar veya şalter atar.
- Panjur olarak ayarlanan kanallar daima **çift** kullanılır: **1-2, 3-4, 5-6, 7-8** (ilk röle YUKARI, ikincisi AŞAĞI). Bir kanalın panjur mu aydınlatma mı olduğu kurulumda uygulamadan/servis sayfasından ayarlanır; fabrikada ayarlanmaz.
- Yön değiştirirken önce diğer röle kapatılır ve **en az 500 ms** beklenir; iki röle asla birlikte çekilmez. Bu koruma yazılımsaldır: tesisatta **mekanik interlock/harici kontaktör** de önerilir.
- Motor süresi dolunca röle otomatik kapanır; ayrıca bağımsız bir süre aşımı emniyeti (planlanan süre + marj) vardır.

### Duvar butonları (kuru kontak) bağlantısı

- Röle klemenslerindeki **COM** uçları şebeke fazını röleye girmek içindir.
- Duvardaki **yaylı (kalıcı olmayan) butonlar** / kapı manyetikleri **DI1…DI8** klemensleri ile **DGND** (dijital toprak) arasına bağlanır.
- **Kalıcı (mandallı) duvar anahtarı DESTEKLENMEZ; tüm girişlere yaylı buton bağlayın.** "Aç/Kapa" kipi her basışta değiştirir.
- Butona basılınca DI pini DGND ile kısa devre olur ve ilgili işlem tetiklenir. İnternet/Wi-Fi kesilse bile duvar butonları çalışır.

---

## 11. Cihazın kendi web sayfası (teknik servis)

Kurulmuş bir kartın içinde küçük bir web sayfası vardır. **Normal kullanıcı için değildir**; teknik servis içindir.

- Kart evin Wi-Fi'sine bağlandığında kendi `AHBU-XXXXXX` ağı **kapanır**. Sayfaya kartın evdeki IP adresiyle (`http://<kart-IP>`) girilir.
- Sayfa açılınca **cihaz anahtarını** sorar (anahtar sunucuda saklıdır ama mobil uygulama onu ayarlarda göstermez; kayıt bu aracın belleğindeyken 3. sekmedeki **Gizli Bilgiler** kutusundan **📋 Anahtarı kopyala** ile alınır: Adım 6). Anahtar girilmeden sayfa kullanılamaz. Anahtar bir kez girilince **bu tarayıcıda hatırlanır** (firmware v1.1.1 ve sonrası): sonraki açılışlarda sayfa kendiliğinden girer ve anahtar kutusu görünmez; sayfa başlığındaki **Çıkış** düğmesi anahtarı tarayıcıdan siler (**ortak bir telefonda işiniz bitince basın**). Yanlış ya da eski anahtarda kayıt kendiliğinden silinir ve anahtar yeniden sorulur. **İSTİSNA (kurulum modu):** telefon/bilgisayar kartın kendi `AHBU-XXXXXX` ağına (WPA2, etiketteki AP parolası) bağlıyken `http://192.168.4.1` açılırsa — müşteride internet olmadığı için anahtar alınamaz — sayfa "**Kurulum modu (AP): yalnızca Wi-Fi ayarlarını değiştirebilirsiniz**" bandıyla açılır ve **anahtarsız** yalnızca **Wi-Fi (Station)** sekmesi çalışır (ağ listesi, modem karekodu, bağlan); diğer sekmeler "Bu işlem için cihaz anahtarı gerekir" der. Bu ayrıcalık yalnızca kurulmuş (provizyonlu) kartta ve **parolalı** kurtarma ağında geçerlidir; açık kurulum ağında verilmez.
- Kart Wi-Fi'den **3 dakika** kopuk kalırsa (veya hiç Wi-Fi tanımlı değilse) ya da servis modunda (seri komut `AP ON`) kendi ağını **10 dakikalığına** açar; bilgisayar bağlıysa en çok 30 dakikaya uzar. Bu ağın parolası **etikette yazan AP parolasıdır** (kurulumdan sonra parola **cihaza özeldir**, sabit parola yoktur); telefonla **etiketteki 2. karekodu kamerayla okutarak** tek dokunuşla bağlanabilirsiniz (Adım 7).
- Sekmeler: **Kontrol** (röle/panjur), **Kanal Ayarları**, **Wi-Fi (Station)**, **RS485 Terminal**, **Sistem**.
- Provizyonsuz bir karta girilirse sayfa **"Cihaz Kurulumu (Provizyon)"** formunu gösterir (elle provizyon). Firmware v1.1.2'de formda şu uyarı yazar: "Sunucuya kayıtlı (etiketli) panolarda bu formu kullanmayın: kurulumu fabrika aracı (USB) ya da uygulamanın kurulum sihirbazı yapar; burada belirlenen anahtarı sunucu bilmez." Bu araçla kaydedilen (etiketli) kartlarda formu **doldurmayın**: provizyonu araç USB'den yapar (Adım 5–6); formla belirlenen anahtarı sunucu bilmez ve araç sonra "Kartta Eski Anahtar Var" sorusunu sorar.

---

## 12. Teknik Ek (IT / servis / geliştirici)

### A. Kurulum ve çalıştırma

- Gerekli: **Python 3.11+** (Tkinter ile; `python` komutu PATH'te olmalı), `qrcode`, `Pillow`; flash için **esptool** (PlatformIO paketi, PATH veya `python -m esptool`).
- `pyserial` **isteğe bağlıdır**: aracın kendi Python'unda yoksa PlatformIO'nun Python'undaki (`penv`) pyserial kullanılır; hiçbirinde yoksa USB seri provizyon kapanır ve yalnızca güvensiz Wi-Fi yedek yolu kalır. Araç **hiçbir zaman yeni paket kurmaz**.
- Başlatma: `ev_otomasyon_sistemi.bat` (veya `python ev_otomasyon_sistemi.py`).
- Dosyalar:

| Dosya | İçerik |
|---|---|
| `ev_otomasyon_sistemi.py` | Tk arayüzü (flash, envanter, etiket, provizyon). |
| `factory_client.py` | Ağ/güvenlik katmanı: sunucu istemcisi, USB-seri ve Wi-Fi provizyonu, hata çevirisi. Yalnız standart kütüphane. |
| `tests/` | Donanımsız/ağsız testler (`test_factory_tool.py`, `test_serial_provision.py`, `test_wifi_label.py` — etiketin iki karekodu —, `test_guide_consistency.py` — rehberdeki düğme/pencere adlarının araçla uyumunu denetler —; yardımcı modüller: `serial_fakes.py`, `qr_decode.py` (bağımsız QR çözücü), `wifi_qr_reference.py` (uygulamanın Wi-Fi karekod ayrıştırıcısının Python karşılığı)). |
| `waveshare_s3_demo/` | Firmware kaynağı ve `firmware_releases/` (sürümlü imajlar). |

### B. Ortam değişkenleri (hepsi isteğe bağlı)

| Değişken | Anlamı |
|---|---|
| `EV_SERVER_URL` | Sunucu adresi (varsayılan üretim adresi; QA için `http://127.0.0.1:5000`). Düz http yalnızca loopback için kabul edilir. |
| `EV_DEVICE_AP_HOST` | Yedek Wi-Fi yolunda cihaz adresi (varsayılan `192.168.4.1`; QA simülatörü için `127.0.0.1:8081`). Yalnızca yerel/özel adresler. |
| `ADMIN_API_KEY` | ≥ 32 karakterse giriş penceresinde "ADMIN_API_KEY ile devam" çıkar (`x-api-key`). Kayıt ve liste için yeter; durum değiştirme/silme için e-posta + parola gerekir. Değer asla gösterilmez/yazılmaz. |
| `ESPTOOL_PATH` | `esptool.py` / `esptool.exe` yolu (yoksa PlatformIO paketi, PATH, `python -m esptool` aranır). |
| `PLATFORMIO_CORE_DIR` | PlatformIO çekirdek dizini (esptool ve `penv` aramasında kullanılır). |
| `EV_TOOL_DEBUG=1` | Hata ayıklama: yalnızca istisna **sınıf adları** `stderr`'e yazılır (gizli değer içermez). |

### C. Seri (USB) provizyon — nasıl çalışır?

Firmware seri CLI'sı (115200 baud, CR/LF; docs/CONTRACTS.md §3c). Araç şu sırayı izler:

1. Flash sonrası aynı COM portun yeniden görünmesini bekler (kart yeniden başlarken USB yeniden numaralanır).
2. Portu **DTR/RTS kapalı** açar (kartı sıfırlamamak için), satır tamponunu boş satırla temizler, `STATUS` ile kartın **MAC**'ini ve `Yerel anahtar (local_key): tanimli | YOK` durumunu okur (açılış bitene kadar yoklar, en çok ~30 sn).
3. MAC kayıtla eşleşmiyorsa **durur** (yanlış kart). Kartta anahtar varsa kullanıcıya sorar; onaylarsa `RESETKEY` gönderir.
4. `FACTORYINIT <local_key> <ap_pass>` gönderir. Firmware satırı **asla yankılamaz**; yanıt: `OK factory_init` | `ERR already_provisioned` | `ERR invalid_local_key` | `ERR invalid_ap_pass` | `ERR persist_failed` (en çok 3 deneme).
5. Yeniden `STATUS` ile `tanimli` görünene kadar doğrular. Doğrulama HTTP ile değil seridir; bilgisayarın cihaz Wi-Fi'sine bağlanması gerekmez.

**Gizlilik:** anahtar/AP parolası loglanmaz, ilerleme metnine yazılmaz, cihazdan gelen ham satırlar gösterilmez; gönderim tamponu kullanımdan sonra sıfırlanır; ekrandaki tüm metinler bellekteki gizli değerlere karşı maskelenir.

**Flash öncesi yoklama (1. sekme):** aynı portta `STATUS` (+ `TPL STATUS`) okunur. Yanıt yoksa `STATUS` ~10 sn boyunca yinelenir (port açılınca yeniden başlayan kart; bağlantı koparsa port yeniden açılır). Süre dolunca araç esptool'un SLIP `SYNC` çerçevesini gönderir: yalnız ROM yükleme kipindeki (BOOT+RESET) kart yanıt verir (çerçevede CR/LF yoktur, çalışan yazılımda komut çalıştırmaz; karta hiçbir şey yazılmaz). Yanıt verirse kart "yükleme kipinde" sayılır (birleşik imaj önce sorar, Güncelle kipi yazmaz); hiç yanıt yoksa boş kart / Waveshare yazılımı sayılır.

**pyserial bulunamazsa:** araç önce kendi Python'unda `import serial` dener; yoksa PlatformIO `penv` yorumlayıcısında arar (alt süreç röleliyle, gizli değerler komut satırına değil boruya gider); hiçbirinde yoksa **yeni paket kurmaz**, seri provizyon kapanır ve Wi-Fi yedek yolu (onayla) önerilir.

#### Elle seri komutlar (terminalde)

| Komut | Etki |
|---|---|
| `STATUS` | Cihaz, MAC, AP durumu, `local_key` tanımlı/YOK, röle/DI/panjur özeti. |
| `FACTORYINIT <local_key> <ap_pass>` | Yalnız provizyonsuzken; `local_key` 8–32 ASCII (boşluksuz), `ap_pass` 8–32 karakter. |
| `RESETKEY` | Yerel anahtarı siler (cihaz provizyonsuz olur). Yanıt (v1.1.2): `[CLI-SONUC] Yerel anahtar SILINDI. Cihaz artik PROVIZYONSUZ (FACTORYINIT <local_key> <ap_pass> ya da /api/factory/init). AP gerekirse: AP ON` (silinemezse `SILINEMEDI`). Yeniden anahtarlama tercihen aynı seri hattan `FACTORYINIT` ile yapılır (anahtar kablosuz ağdan geçmez). |
| `AP [ON\|OFF\|STATUS]` | Servis AP penceresi (10 dk). |
| `HELP` | Komut listesi. |

### D. Kullanılan sunucu uçları

`POST /api/v1/auth/login` (+ `refresh`, `logout`), `POST /api/v1/admin/inventory/register` (yanıt: `local_key` + PIN'li `qr_claim_url`, **bir kez**), `GET /api/v1/admin/inventory`, `PATCH /api/v1/admin/inventory/:uid/status`, `DELETE /api/v1/admin/inventory/:uid`, `POST /api/v1/admin/inventory/:uid/reissue-label` (yalnız süper kullanıcı JWT'si; yanıt yeni `setup_pin` + `qr_claim_url`; `local_key` **yok**, anahtar değişmez; daireye bağlı kartta 409 `DEVICE_LINKED_TO_FLAT`), `GET /api/v1/admin/inventory/:uid/local-key` (sunucudaki anahtarla yeniden provizyon ve etiket yenileme; denetim kaydı + oran sınırı; değer maskelenir). Hata biçimi `{success:false, message, code}`; ham gövde kullanıcıya gösterilmez. Süper kullanıcı / servis sorumlusu JWT'si (15 dk, otomatik yenilenir) veya isteğe bağlı `x-api-key` (yalnız kayıt ve liste).

**Yerel anahtar izi (firmware v1.3.1):** `lk_fp` = HMAC-SHA256(anahtar = yerel anahtar, ileti = `ahbu-lk-fp/1|` + büyük harfli UID) çıktısının küçük harf hex ilk 8 karakteri. Kart tam `GET /api/status`'ta (Ethernet'te `X-Device-Key` başlığı tam durumu ister) ve seri `STATUS`'ta (`- Anahtar izi: <8 hex|yok>` satırı, `Bootstrap:` satırından hemen sonra) bildirir; araç aynı formülle hesaplayıp karşılaştırır (`factory_client.local_key_fingerprint`). İz anahtarı geri vermez; yine de loglanmaz.

Site / şablon (CONTRACTS §3e; süper kullanıcı + servis sorumlusu JWT'si, API anahtarı yetmez): `GET/POST /api/v1/sites`,
`PATCH/DELETE /api/v1/sites/:id`, `GET /api/v1/sites/:id/flats`, `POST /api/v1/sites/:id/flats/bulk`, `PATCH/DELETE …/flats/:flatId`,
`PUT …/flats/:flatId/device`, `GET/POST /api/v1/templates`, `GET/PUT/DELETE /api/v1/templates/:id`, `GET …/versions[/:v]`,
`POST /api/v1/templates/validate` (422 `TEMPLATE_INVALID` + şablon kodu + alan yolu), `PUT /api/v1/templates/:id {body, base_version}`
(eşzamanlı düzenlemede 409 `TEMPLATE_CHANGED` + `current_version`), `PATCH …/flats/:flatId {status:"handed_over"}` (Teslim Edildi;
yalnız ileri, aksi 409 `INVALID_STATUS_TRANSITION`), `POST /api/v1/template-writes` (`via` usb|eth; yanıtta
`warning:"DEVICE_LINKED_ELSEWHERE"` olabilir). Ethernet şablon yazımı sunucudan anahtar **istemez** (kart Ethernet'te anahtarsız).
Karta: seri `TPL BEGIN <bayt> <crc32>` → `TPL DATA <base64 ≤150>` → `TPL COMMIT` (`OK tpl_applied <id> <sürüm>` | `ERR <kod> [yol]`)
→ `TPL STATUS`; LAN `POST /api/template/apply` (`X-Device-Key`) → `GET /api/template`. Şablon biçimi ve kodlar:
`docs/contracts/template/README.md`; araç doğrulayıcısı `template_model.py`, PDF `wiring_pdf.py`, arayüz `site_template_ui.py`.

### E. Firmware derleme ve sürüm klasörü

> **DİKKAT:** `firmware_releases` altındaki ESKİ imajlar (`v1.0.0`, `v1.0.1`; klasörlerinde `KULLANILMAZ.txt` vardır) **USB provizyon komutunu (`FACTORYINIT`) ve `RESETKEY`'i içermez** (imaj içinde bu metinler aranıp bulunamadı). Bu imajlarla yüklenen kart USB ile provizyonlanamaz; araç bu durumu yüklemeden önce "Firmware Uyarısı" ile bildirir. Seçili (güncel) imaj `version_info.json`'a göre **v1.3.1**'dir (araç üst şeridinde "Firmware v1.3.1" rozeti görünür; Ethernet, USB/LAN şablon, panonun kendi bulut kimliği, yerel anahtar izi; `v1.3.1/SURUM_NOTLARI.md`). v1.3.1 kartta denendi (açılış, Wi-Fi, bulut, sunucuyla anahtar izi eşleşmesi). Elle v1.3.0 özellikleri olmayan bir imaj (ör. v1.2.1) seçilirse araç "Bu imajla … çalışmaz (v1.3.0+ gerekli)" uyarısını gösterir (engellemez); kartın seri `STATUS`'unda v1.3.0+ izi (Bootstrap/Sablon satırı) varsa ise bu sürüm düşürmedir: birleşik imajda ayrıca sorulur ("Sürüm Düşürme"), 'Güncelle (ayarlar korunur)' kipinde yazılmaz ("Sürüm Düşürme Engellendi"). Yeni bir sürüm üretilince aşağıdaki gibi sürüm klasörüne konmalıdır.
>
> **Uygulama imajı ('Güncelle (ayarlar korunur)' kipi):** her sürüm klasöründe birleşik imajın yanında `app_0x10000_v<sürüm>.bin` bulunur (v1.2.1, v1.3.0 ve sonrası; v1.3.1'de bootloader ve bölüm tablosu v1.3.0 ile bayt bayt aynıdır). Araç bu dosyayı `version_info.json`'daki isteğe bağlı `app_file` alanından, yoksa `v<current_version>/app_0x10000_v<current_version>.bin` kuralından bulur ve **0x10000**'a yazar (OTA alıcısı olmadığı için kart her zaman bu uygulamadan açılır). "Kart Ayarları Silinecek" sorusunda **Hayır** denince ise `version_info.json` kullanılmaz: seçilen birleşik imajla aynı klasördeki `app_0x10000_v<klasör sürümü>.bin` (yoksa klasördeki tek `app_0x10000_*.bin`) seçilir; bulunamazsa araç uyarır ve dosya kutusunu boş bırakır.

1. Derleme (PlatformIO; makineye özel çekirdek dizini `waveshare_s3_demo\platformio_local.ini` içindedir, depoya girmez):

   ```powershell
   pio run -d ev_otomasyon_servis_yazilimi\waveshare_s3_demo
   ```

2. Birleşik (0x0) imaj (PlatformIO'nun standart flash düzeni: bootloader 0x0, bölüm tablosu 0x8000, `boot_app0.bin` 0xE000, uygulama 0x10000):

   ```powershell
   $B   = "ev_otomasyon_servis_yazilimi\waveshare_s3_demo\.pio\build\esp32-s3-waveshare"
   $PIO = "$env:USERPROFILE\.platformio"   # çekirdek dizini farklıysa (platformio_local.ini) onu yazın
   python -m esptool --chip esp32s3 merge_bin -o yeni_firmware.bin --flash_mode dio --flash_size 16MB `
     0x0 "$B\bootloader.bin" 0x8000 "$B\partitions.bin" `
     0xe000 "$PIO\packages\framework-arduinoespressif32\tools\partitions\boot_app0.bin" 0x10000 "$B\firmware.bin"
   ```

   Not: mevcut eski imajlarda `boot_app0.bin` (0xE000) yoktur. OTA ile güncellenmiş/önceden kullanılmış kartlarda eski sürümün açılmaması için bu kartlara **önce Hafızayı Sil** uygulanır. Bu düzendeki v1.1.1 birleşik imajı 2026-10-04'te bir test kartına esptool ile yazıldı (yazım hash'i doğrulandı) ve seri çıkışta açılışı görüldü; FACTORYINIT provizyonu ve sonrası bu imajla kartta henüz **denenmedi** (`firmware_releases/v1.1.1/SURUM_NOTLARI.md`). Güncel v1.1.2 birleşik imajı aynı düzendedir (0x0000-0xFFFF bölgesi v1.1.1 ile bayt bayt aynı) ve 2026-10-04'te aynı test kartına yazıldı: yazım hash'i ve karttan geri okuma doğrulandı, seri `STATUS` yanıt verdi; FACTORYINIT provizyonu ve sonrası kartta henüz **denenmedi** (`firmware_releases/v1.1.2/SURUM_NOTLARI.md`).

3. Aracı açın, 1. sekmede **Gözat...** ile `yeni_firmware.bin` dosyasını seçin ve **Versiyon Arttır**'a basın: araç dosyayı yeni sürüm klasörüne (`firmware_releases\vX.Y.Z\`) kopyalar ve "güncel sürüm" olarak `version_info.json`'a yazar. Bundan sonra "Bizim Geliştirdiğimiz Yazılım" bu imajı kullanır.

Araç, yazılacak dosyayı denetler: `.bin` uzantısı, boyut, ilk bayt `0xE9`; **0x0 kipinde** `0x8000`'de bölüm tablosu ŞART (yoksa dosya reddedilir: uygulama imajı 0x0'a yazılırsa kart açılmaz), **Güncelle (0x10000) kipinde** bölüm tablosu OLMAMALI (birleşik imaj reddedilir); (AHBU modunda) imajda `FACTORYINIT` komut adı (yoksa "eski firmware" uyarısı) ve v1.3.0 özellik izleri `TPL BEGIN`, `/api/template/apply`, `devices/bootstrap` (eksikse engellemeyen uyarı). Yazmadan önce kart seri `STATUS` + `TPL STATUS` ile yoklanır (Güncelle kipi AHBU firmware'i ister; birleşik imaj provizyonlu/şablonlu kartta önce sorar).

### F. Testler

```powershell
cd ev_otomasyon_servis_yazilimi
python -m unittest discover -s tests -v
python -m py_compile ev_otomasyon_sistemi.py
```

`tests/test_session_store.py` (Beni hatırla deposu: DPAPI gidiş-dönüşü [yalnız Windows], bozuk/başka kullanıcı dosyası, rotasyon yazımı, sessiz geri yükleme sonuçları) ve `tests/test_tool_theme.py` (tema/kontrast/tercih) dahildir; testler gerçek `%APPDATA%\AHBU` içeriğine dokunmaz.

Testler gerçek ağa/COM porta/esptool'a **çıkmaz** (sahte HTTP, sahte seri port, gizli Tk penceresi). Gerçek kartla denenmesi gerekenler (doğrulanmadı): flash sonrası USB'nin yeniden numaralanma süresi, gerçek `STATUS`/`FACTORYINIT` zamanlaması, esptool çıktısından MAC okuma, yazdırma, gerçek telefon kamerasıyla 2. karekodun okunması.

### H. Etiket karekodları (teknik)

| Karekod | İçerik | Okuyan |
|---|---|---|
| 1) Daireye bağla | `https://evotomasyon.gudeteknoloji.com.tr/claim?uid=<UID>&pin=<PIN>` (AP parolası **yok**; kök sabittir: uygulamanın Android uygulama bağlantısı ana makinesi, `factory_client.CLAIM_LINK_BASE`; sunucu adresi ya da sunucunun `APP_PUBLIC_URL`'si farklı olsa da değişmez) | Uygulama (QrClaimParser) |
| 2) Kurulum Wi-Fi'sine bağlan | `WIFI:T:WPA;S:<AP SSID>;P:<ap_pass>;;` | Telefon kamerası (Android / iOS 11+) ve uygulamanın WifiQrParser'ı |

- **AP SSID** = `AHBU-` + MAC'in son 6 hex'i, büyük harf (firmware `WiFiManager::apSsid()` ile aynı kural; ağ gizli değildir, bu yüzden `H:true` yoktur). **ap_pass** = etikette yazan değer.
- **Kaçış:** `\` `;` `,` `:` `"` karakterlerinin önüne `\` konur (uygulamanın WifiQrParser kuralı: `\;` `\\` `\:` `\,` `\"` çözülür). Araç ürettiği parolalarda bu karakterleri kullanmaz; yine de firmware ASCII 0x20-0x7E kabul ettiği için üretici hepsini kaçışlar.
- **Etiket görseli:** 800 x 400 px, 203 dpi = 100 x 50 mm; PNG'ye dpi bilgisi yazılır. Üretici: `factory_client.wifi_qr_payload` / `device_wifi_qr_payload` (saf fonksiyonlar), görsel: `ev_otomasyon_sistemi.build_label_image`.
- **Test:** `tests/test_wifi_label.py` — biçim/kaçış/SSID kuralı, uygulamanın kendi test vektörleriyle doğrulanmış referans ayrıştırıcıyla gidiş-dönüş, etiket PNG'sinden iki karekodun bağımsız çözücüyle okunması, AP parolasının yalnızca metinde ve 2. karekodda bulunması. Dart SDK kuruluysa (`dart` PATH'te) uygulamanın **gerçek** `WifiQrParser` kodu (`lib/utils/wifi_qr_parser.dart`) da çalıştırılır: üretilen karekod metinleri özgün SSID/parolaya çözülür ve Python referansı gerçek ayrıştırıcıyla farksız çalışır; Dart yoksa bu testler atlanır.

### G. Güvenlik tasarımı (özet)

- Kodda **sabit** API anahtarı/parola yoktur; parola yalnızca giriş penceresinden alınır, saklanmaz, loglanmaz.
- **Beni hatırla** (kullanıcının açık onayıyla; `session_store.py`): yalnızca **refresh token**, Windows **DPAPI** ile (CryptProtectData, kullanıcı kapsamı, uygulamaya özel entropi; `ctypes`, yeni paket yok) şifrelenip `%APPDATA%\AHBU\factory_session.dat` dosyasına yazılır; sunucu adresi + e-posta (gizli değil) `servis_araci_ayarlar.json` içindedir. **Parola ve erişim token'ı ASLA yazılmaz.** DPAPI yoksa (Windows dışı) token yazılmaz, yalnız kimlik hatırlanır. Sunucu refresh token'ı **tek kullanımlık** döndürdüğünden (rotasyon) her yenilemede yeni token ANINDA yazılır; yazılamazsa eski dosya silinir (kapalı-hata). Token yalnızca şifreli yükteki **sunucu adresine** gönderilir; rol yine `super_user` olmalıdır (değilse oturum iptal edilir, kayıt silinir). Pencere kapanışında hatırlanan oturum sunucuda iptal EDİLMEZ; **Oturumu Kapat** kaydı siler ve sunucuda iptal eder; **Beni hatırla** işaretsiz giriş de eski kaydı siler.
- TLS doğrulaması her zaman açık; yönlendirme izlenmez; düz http yalnızca loopback.
- `local_key` ve PIN'li karekod adresi sunucudan **bir kez** gelir; bellekte tutulur; diske yalnızca kullanıcı **Etiketi Kaydet** derse etiket görseli olarak yazılır.
- AP parolası etikette yalnızca **metinde ve 2. karekodda** bulunur (1. karekodda ve loglarda yoktur); 2. karekodun metni gizli değer sayılır (maskelenir, loglanmaz, yalnızca etiket görseline gider).
- PIN ve AP parolası yalnızca `secrets` ile üretilir.
- Alt süreçler liste argümanlıdır (kabuk yok); port ve firmware yolu doğrulanır; tüm ağ/seri çağrılarında zaman aşımı vardır.
- Arayüz iş parçacığı bloklanmaz: ağ, flash ve seri işler arka planda çalışır.
