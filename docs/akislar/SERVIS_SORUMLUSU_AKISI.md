# Servis Sorumlusu Akışı

> Kimin için: servis sorumlusu ve süper kullanıcı (ofis, atölye, saha, teslim). Kaynak: kodun kendisi, 2026-10-09
> (2026-10-09 akşam: sahip kararları, karekodun uygulamayı açması, firmware v1.3.2 kartta denendi). Ekrandaki düğme ve
> mesajlar tırnak içinde, koddaki gibi. Kullanıcı tarafı ayrı belgede: `DAIRE_KULLANICISI_AKISI.md`. Açık kalan konular en sonda
> (Bölüm 9).

---

## 0. Bu sürümde değişenler (2026-10-09)

**Sahip kararlarıyla gelenler (2026-10-09 öğleden sonra; ayrıntı `docs/denetim/2026-10-09-kararlar.md`):**

1. **Güvenlik ayarlı evde pano değişimini yalnız servis yapar.** Evin bulut kopyasında sensör ya da vana varsa ev sahibinin denemesi
   reddedilir ("Bu evde pano değişimini yetkili servis personeli yapmalıdır."); değişimi kendi hesabınızla, müşterinin servis
   PIN'iyle ya da süper kullanıcı olarak yaparsınız (Bölüm 6.1).
2. **Ethernet'te sınır yok (karar):** kablolu panoda yerel istekler anahtarsız tam yetkili kalır (gaz vanası ve alarm dahil), şablon
   yazımında kart kimliği denetlenmez; müşteri uygulaması da kablolu panoyu anahtarsız yönetir.
3. **Personel her kartın yerel anahtarını okuyabilir** (değişmedi); yasal metinler buna göre düzeltildi (taslak sürüm 2).
4. **Erişim bitince panonun bulut kimliği yenilenir:** üye çıkarma/ayrılma, devir kabulü ve **her servis oturumunun bitişi**. Tek
   panolu evde ve v1.3.0+ panoda; pano yeni kimliği kendisi alır (Bölüm 7, madde 3). EMQX'te cihaz kimliği panonun istemci
   kimliğine (`ESP32S3_<MAC>`) bağlıdır: aynı kimlikle başka bir istemci bağlanamaz.
5. **Telefon tek biçim:** telefon alanlarında "+90 " hazır gelir (5XX XXX XX XX); "0555…", "+90555…", "555…" aynı numara. Kayıtlı
   numaralar dönüştürüldü (başka bir hesapla çakışan numaraya dokunulmadı).
6. **Süper kullanıcının kalıcı silmesi:** kullanıcı panolu bir dairenin tek sahibiyse silinmez; önce devir ya da acil sıfırlama
   (Bölüm 6.3). Silinen kullanıcının sözleşme onay kayıtları kimliksiz (anonim) saklanır.
7. **Aile üyesi ve misafir "Evden Ayrıl"** ile evden kendisi ayrılabilir; aile üyesi ayrılınca yerel anahtar ve bulut kimliği değişir.
8. **Devirden, acil sıfırlamadan ve Home Admin atamasından sonra** yeni sahip yalnız o andan sonraki ve hâlâ açık alarmları görür.
9. **Rölelerde sabit görev yok:** firmware v1.3.2'nin fabrika ayarında 8 rölenin hepsi "Röle N" adlı lamba, 1-8. girişler aynı
   numaralı röleyi açıp kapatır; yeni açılan evin buluttaki varsayılan kanal listesi de aynıdır. Panjur yalnız şablonda seçilirse
   yanındaki röleyle çift olur; röle görevlerini yalnız şablon belirler. Eski (v1.3.1) panolu mevcut evlerde adlar değişmez.
10. **Bulut sunucu kilidi (v1.3.2):** pano yalnız firmware'e gömülü sunucuya (`evotomasyon.gudeteknoloji.com.tr`) bağlanır; başka
    adres `400 host_not_allowed`. v1.3.2 kartta denendi ve servis yazılımında seçili sürüm.
11. **Değişmeyenler (kararlarınız):** kablosuz sensör "yakında" olarak kapalı kalır; e-postasız müşteri panosunu kendi karekoduyla
    sahiplenir (e-posta/SMS sistemi gelene kadar); personel süper kullanıcının dondurduğu hesabı açabilir.

**Aynı gün sabah gelenler:**

1. **Pano değişiminde güvenlik ayarları aktarılmıyor; artık açıkça söyleniyor.** Su/gaz sensörü ya da vanası olan evde sonuç ekranı
   "Güvenlik ayarları (su/gaz sensörü, vana) yeni panoya aktarılmadı. Yetkili servisi çağırın." der. Değişimden sonra sihirbazın 7.
   adımında güvenlik ayarlarını yeniden yazıp bölge testini yapın (Bölüm 6.1).
2. **Kablosuz (köprü) sensör bu sürümde desteklenmiyor.** Sihirbaz "Kablosuz sensör ekle"yi yalnız destekleyen panoda gösterir;
   şablondaki kablosuz sensör (b1..b16) doğrulamada reddedilir. Sensörler panodaki girişlere (d1..d40) bağlanır.
3. **"Panoyu Hazırla" kurulum ağı parolasını iki kez ister** ve etiketteki parolayla karşılaştırır (5. adım); yanlış parolayla pano
   hazırlanmaz.
4. **Parmak izi / yüz kilidi sihirbazı kapatmıyor.** Wi-Fi ayarlarında 30 sn'den uzun kalsanız da kilit açılınca sihirbaz kaldığınız
   adımda sürer. Mevcut cihazın sihirbazı hangi yoldan açılırsa açılsın yarım kayıt sorulur.
5. **9. adımda güvenlik girişleri buton sayılmıyor** (sensör, vana geri bildirimi ve kumanda girişleri listelenmez).
6. **Kurulmuş / teslim edilmiş dairenin kartı** yalnız Pano Değişimi ile ya da süper kullanıcı tarafından değiştirilir. Karta dairenin
   güncel şablonundan başka bir şablon yazılırsa daire "Yazıldı" olmaz; servis yazılımı uyarır.
7. **Servis yazılımı:** envanterde arama ve "⬇️ Daha fazla"; kartta yarım kalmış şablonu ("YARIM") tanıma; daireden yazmadan önce
   dairenin şablonunu sunucudan yeniden okuma.
8. **Telefonla giriş yapan (e-postasız) müşteriye sahiplenme kodu gönderilemiyor;** artık bunu açıkça söyleyen ileti çıkıyor
   (Bölüm 5.3, 3. adım).
9. **Firmware v1.3.2 paketlendi** (kartta denenmedi; servis yazılımında seçili sürüm hâlâ v1.3.1): kablosuz sensör yazımı reddi, uzun
   onay sürelerinin çalışması, kalıcı belleğe (NVS) yazımda yeniden deneme, ek modül düzeltmeleri.

**2026-10-08 sürümünde gelenler (geçerli):** pano bulut kimliğini kendisi alıyor (Bölüm 7, madde 3; 6. adımda pano zaten çevrimiçiyse
adım kendiliğinden tamamlanır); yanlış kurulum PIN'inde "Geçersiz kurulum PIN kodu. Kalan deneme hakkı: N"; sihirbaz Ethernet'li
panoyu tanıyor ve Ethernet'li panoda kurulum ağı açılıp kapanmıyor; Android'de "Arka planda alarm bildirimi"; uygulamada yasal
metinler (müşteri kayıtta Kullanıcı Sözleşmesi'ni onaylar; süper kullanıcı ve servis sorumlusu hesaplarına onay ekranı çıkmaz).

---

## 1. Roller ve yetkiler

| İş | Süper kullanıcı | Servis sorumlusu | Geçici servis (PIN) |
|---|---|---|---|
| Servis yazılımına giriş | Evet | Evet | Hayır |
| Kartı envantere kaydetme, askıya alma, silme | Evet | Hayır | Hayır |
| Site, daire, şablon ekleme/düzenleme/silme | Evet | Evet | Hayır |
| Şablonu karta yazma, PDF üretme | Evet | Evet | Hayır |
| Kurulmuş / teslim edilmiş dairenin kartını değiştirme ya da ayırma (pano değişimi dışında) | Evet | Hayır | Hayır |
| Panoyu müşteriye bağlama (sahiplendirme) | Evet | Evet | **Hayır** |
| Sihirbazla kurulum ve test | Evet | Evet (müşteri evinde 72 saat) | Evet (yalnız o ev, 2 saat) |
| Sihirbazda şablon uygulama | Evet | Evet | Hayır |
| Pano değişimi | Evet | Evet | Evet |
| Acil sıfırlama | Evet | Evet (son 72 saatte kurduğu evler) | Hayır |
| Evin yerel anahtarını okuma | **Hayır** | Evet | Evet |
| Herhangi bir envanter kartının anahtarını okuma (servis yazılımı) | Evet | Evet | Hayır |
| Hırsız alarmını kurma/çözme | Hayır | Hayır | Hayır |
| Gaz vanasını uzaktan açma | Hayır (kimse) | Hayır | Hayır |

---

## 2. Ofis: site ve şablon (servis yazılımı)

### 2.1 Giriş
1. Servis yazılımını açın. Sekmeler: "⚡ 1. Firmware Yükleyici (Flasher)", "🏷️ 2. Karekod Üret & Etiket Bas (Envanter)",
   "📡 3. Cihaz Provizyonu (USB / Wi-Fi)", "🏢 4. Siteler", "📐 5. Şablonlar".
2. "🔐 Sunucuya Giriş" → e-posta + parola. "Beni hatırla" işaretliyse sonraki açılışta oturum kendiliğinden açılır.
3. Servis sorumlusuysanız envanter kayıt/askı/silme düğmeleri pasiftir (not çıkar). Envanter listesi 100'er kayıtla gelir: UID ya
   da seri no ile arayın, sonraki sayfa için "⬇️ Daha fazla" (durum satırı "Gösterilen X / Toplam Y").

### 2.2 Site ve daireler (4. sekme)
1. "🔄 Siteleri Yenile" → "➕ Site Ekle": "Site adı *", adres, il, ilçe, sorumlu adı, sorumlu telefonu, e-posta, blok sayısı,
   daire sayısı, not.
2. Siteyi seçin → "🧱 Toplu Daire Üret": blok (A), ilk–son daire no, isteğe bağlı daire tipi ve şablon (en çok 500;
   var olan blok+no atlanır). Her blok için tekrarlayın.
3. Daire seçip "📐 Şablon Ata", "🔗 Kart Bağla" (yalnız **stoktaki** kart; bir kart tek daireye). Kuruldu ya da Teslim edildi
   dairenin kartını yalnız Pano Değişimi ya da süper kullanıcı değiştirir/ayırır; aksi halde sunucu "Kurulmuş ya da teslim edilmiş
   dairenin kartı yalnız Pano Değişimi ile ya da yönetici tarafından değiştirilebilir." der. Yazıldı dairede kart ayrılırsa daire
   Planlandı'ya döner.
4. "İlerleme" sütunu: Planlandı → Yazıldı (dairenin güncel şablonu dairenin kartına yazılınca) → Kuruldu (kart bir müşteriye
   sahiplenilince) → Teslim edildi (sihirbazda "Devreye Almayı Tamamla" ile kendiliğinden ya da "✅ Teslim Edildi" ile elle).
   "Son yazım" sütunu dairenin şablonundan başka bir şablonun yazımını "(farklı şablon)" diye işaretler.

### 2.3 Şablon (5. sekme)
1. "Site:" seçin (ya da "Genel (standart şablonlar)") → "➕ Yeni Şablon" ya da "📑 Çoğalt".
2. Üst satır: ad, daire tipi, "Ek modül (RS485) var" + kanal + adres → **"↔ Kanalları Uygula"ya mutlaka basın**.
3. "⚡ Röle Çıkışları": ad, oda, tip ("Lamba/Priz", "Panjur (çift)" — tek numaralı röle Yukarı, sonraki Aşağı, aynı süre;
   "Darbe" — ms), bağlanacak yük. Lamba satırında "💡" → "Parlaklık ayarı yapılacak mı?" → dimmer kaynağı/adres/kanal ve
   yerleşim yönergesi.
4. "🔘 Girişler (DI)": hedef röle, kip (hepsi **yaylı buton**; kalıcı duvar anahtarı desteklenmez), kablolama notu,
   güvenlik rolü (su, gaz, duman, kapı, pencere, hareket, alarm susturma, vana kapatma, gaz vanası sıfırlama, anahtarlı
   kontak), NO/NC (gaz/duman/anahtarlı kontak her zaman NC), bölge. Kablosuz (köprü) sensör bu sürümde desteklenmiyor: sensörler
   panodaki girişlere (d1..d40) bağlanır; şablonda köprü sensörü (b1..b16) varsa doğrulama reddeder.
5. "🛡️ Güvenlik": tepkiler, kuruluk bekleme, bölge adları, güvenlik cihazları (vana: kapanma kipi + su/gaz; siren; fan).
   Güvenlik cihazı panjur/darbe rölesine bağlanamaz.
6. "💾 Doğrula ve Kaydet (yeni sürüm)": yerel + sunucu doğrulaması, yeni sürüm. Eski sürümler değişmez ("🕘 Sürüm Geçmişi").

---

## 3. Atölye: kartı hazırlama (servis yazılımı)

### 3.1 Kayıt ve etiket (yalnız süper kullanıcı, 2. sekme)
1. Kart USB'de → "📡 Karttan MAC Oku" (UID = `AHBU-S3-` + MAC son 6) → "🎲 Rastgele PIN Üret".
2. "☁️ SUNUCU ENVANTERİNE KAYDET & KAREKOD ÜRET": sunucu yerel anahtarı **bir kez** verir; AP parolası araçta üretilir.
3. Etiket: "1) Daireye bağla" karekodu (uygulama, UID+PIN) ve "2) Kurulum Wi-Fi'sine bağlan" karekodu (telefon kamerası).
   "💾 Etiketi Kaydet (PNG)" / "🖨️ Yazdır". Etiket gizlidir (PIN + parola içerir).

### 3.2 Firmware (1. sekme)
1. Port seçin → "⚡ FİRMWARE'İ KARTA YÜKLE (FLASH)". **Ethernet, şablon ve kendi kendine bulut bağlantısı için v1.3.0+
   gerekir**; servis yazılımında seçili sürüm v1.3.2'dir (kartta denendi: 12 açılışta çökme yok). v1.3.1'li kartları "Güncelle
   (ayarlar korunur)" ile v1.3.2'ye yükseltin: v1.3.1'de açılışta ara sıra çökme vardı.
2. Yükleme bitince kayıt bekliyorsa provizyon **aynı USB'den otomatik** başlar.

### 3.3 Provizyon (3. sekme)
1. Otomatik olmadıysa "🔌 Seri (USB) ile Provizyonla (Önerilen)". Kartta eski anahtar varsa "Kartta Eski Anahtar Var"
   sorusu (Evet → `RESETKEY` + yeniden).
2. Ethernet'le: "🌐 Ethernet ile Provizyonla" → kartın Ethernet IP'si.
3. Wi-Fi yedek yolu: "📶 Wi-Fi ile Provizyonla (güvensiz yedek yol)" → "✅ Wi-Fi ile Doğrula".
4. **Önemli:** pano bulut kimliğini kendisi alabilmek için **provizyonlu** olmalı. Ethernet'te provizyonsuz da şablon yazılır,
   ama provizyonsuz pano buluta kendiliğinden bağlanamaz.

### 3.4 Şablonu karta yazma
1. Servis yazılımında daireyi (4. sekme) ya da şablonu (5. sekme) seçin → "💾 Karta Yaz". Daireden yazarken araç daireyi önce
   sunucudan yeniden okur: dairenin şablonu bu arada değiştiyse "Daire Şablonu Değişti" diye sorar (Evet: güncel şablon yazılır),
   daire silindiyse ya da şablonu kaldırıldıysa "Daire Değişti" der ve yazmaz.
2. **USB:** port seçin; daireye bağlı kart varsa takılı kartın o kart olduğu MAC'ten denetlenir (değilse hiçbir şey yazılmaz).
3. **Ethernet:** kartın **Ethernet** IP'si + UID. Anahtar gerekmez; **IP–kart eşleşmesi denetlenmez**, IP'yi doğru girin.
   Wi-Fi IP'si girerseniz kart anahtar ister ve yazım reddedilir. Araç yazmadan önce kartın mevcut şablon kaydını okur.
4. Kartta yarım kalmış bir şablon varsa ("YARIM") araç yazmadan önce söyler. Yanıt kaybolursa araç yalnız kart yeni şablonu
   bitirdiyse başarı der; kart hâlâ yarımsa "Şablon yarım kaldı; aynı şablonu yeniden yazın.".
5. Başarıda daire **Yazıldı** olur (yazılan şablon dairenin güncel şablonuysa; değilse "Daire Şablonu Farklı" penceresi çıkar ve
   daire Yazıldı yapılmaz), kart daireye bağlı değilse bağlama sorulur, "Kablolama şeması (PDF) şimdi kaydedilsin mi?" sorulur.
   Bellekteki kart bu kartsa etikete daire satırı eklenir; etiketi yeniden yazdırın.

### 3.5 Atölye kontrol listesi
1. Firmware v1.3.0 yüklendi, provizyon "doğrulandı".
2. Kart doğru daireye bağlı (UID etiketle aynı).
3. Şablon yazıldı, geri okuma doğruladı.
4. Etiket (daire satırıyla) ve PDF şema basıldı, sürümler aynı.

---

## 4. Saha: montaj ve test
1. Etiketteki blok/daire ve şemadaki şablon sürümü kontrol edilir.
2. Kablolar şemaya göre: röle kontağı kuru kontak (faz COM, yük NO), girişlere yaylı buton/sensör (DI–GND).
3. Enerji verilir (internet gerekmez). Duvar butonları, panjur yönü, su sensörü (vana kapanmalı) denenir; gaz dedektörü
   kendi test düğmesiyle.
4. Pano modeme kabloyla bağlanacaksa: Ethernet'ten gelen her istek anahtarsız tam yetkilidir (karar 2026-10-08).

---

## 5. Teslim: uygulamadaki kurulum sihirbazı

### 5.1 Sihirbazı açma
1. **Servis sorumlusu:** e-posta + parola → ana ekranda "Devreye Alma (Servis Modu)".
2. **Süper kullanıcı:** "Tüm Paneli Aç" → "Görevler ve Araçlar" → "Kurulum Sihirbazı".
3. **Geçici servis:** giriş ekranında "Yetkili Servis Girişi (PIN)" → ev sahibinin 6 haneli PIN'i (2 saat, tek ev).
4. "Servis Paneli": "Yeni Kurulum Başlat", "Wi-Fi Kurulum & Kurtarma Sihirbazı", "Devam eden kurulumlar" ("Devam Et"),
   "Mevcut cihazlarım" ("Bağlantıyı yeniden kur" → 5. adım, "Testleri yap" → 7. adım), yönetim araçları, acil durum.
5. Mevcut bir pano için sihirbaz hangi yoldan açılırsa açılsın (Servis Modu, Aboneler, pano değişimi, acil sıfırlama), o panonun
   yarım kaydı varsa "Bu panonun yarım kalmış kurulumu var (Adım N)" sorulur: "Kaldığınız Yerden Devam", "Baştan Başla (kayıt
   silinir)", "Vazgeç" (kayıt değişmez).

### 5.2 Genel kurallar
1. 10 adım; "Devam" yalnız adım gerçek pano/sunucu yanıtıyla doğrulanınca açılır; ileri atlanmaz.
2. İlerleme telefonda saklanır (anahtar, PIN, kod, bulut kimliği, Wi-Fi şifresi saklanmaz).
3. PIN oturumunda 3-4. adım atlanır, şablon kartı görünmez. Mevcut cihaz kipinde 2-4. adım atlanır.
4. Parmak izi / yüz kilidi açıksa uygulama 30 sn'den uzun arka planda kalınca kilitlenir; sihirbaz açıkken kilit ekranı sihirbazın
   üstüne gelir, kilit açılınca aynı adımda devam edilir (bellekteki pano anahtarı korunur). Çıkış yaparsanız sihirbaz kapanır.

### 5.3 Adımlar
1. **Hazırlık:** "Bağlantıyı Doğrula" (oturum + sunucu).
2. **Cihazı Tanı:** "Etiketi Tara (Karekod)" ya da seri no + PIN → stok durumu denetlenir. (PIN oturumunda dairedeki pano seçilir.)
3. **Müşteri:** müşterinin e-postası/telefonu → "Kod Gönder" → müşteriye 6 haneli kod (15 dk) → kodu yazın. Müşteri uygulamaya
   yalnız telefonla (SMS) giriş yapıyorsa hesabında e-posta yoktur ve kod gönderilemez: "Bu müşteri uygulamaya telefonla giriş
   yapıyor; hesabında e-posta olmadığı için onay kodu gönderilemez. Müşteri panoyu kendi uygulamasından etiketteki karekodla
   sahiplenmeli." Müşteri panoyu kendisi sahiplenir, kurulum için size servis PIN'i verir.
4. **Daireye Bağla:** özet → "Daireye Bağla" → onay. Sunucu evi açar/seçer (site dairesiyse ad "<site> <blok>-<no>",
   kanallar şablondan), müşteri hesabı yoksa açar ve davet gönderir, size 72 saat yetki verir. Yanlış PIN'de
   "Kurulum PIN'i hatalı" + kalan hak → 2. adıma döner.
5. **Ağ (Wi-Fi ya da Ethernet):**
   1. **Wi-Fi:** telefonu kurulum ağına (`AHBU-XXXXXX`, etiketin 2. karekodu) bağlayın → "Bağlandım: Panoyu Kontrol Et" →
      (provizyonsuzsa "Panoyu Hazırla": kurulum ağı parolası iki kez yazılır ya da etiket karekodu okutulur; parolalar
      uyuşmazsa "Kurulum ağı parolaları eşleşmiyor.", etiketteki parolayla uyuşmazsa "Yazdığınız parola etiketteki parolayla
      eşleşmiyor." ve pano hazırlanmaz) → "Ağları Tara" / elle (2,4 GHz) → "Yeni Wi-Fi Şifresini Panoya Yükle" → telefonu ev
      Wi-Fi'sine geri alın.
   2. **Ethernet:** "Pano kabloyla (Ethernet) bağlı" seçin → "Panonun Ethernet IP adresi" → "Ethernet ile Doğrula". Kurulum
      ağı ve Wi-Fi bilgisi gerekmez. Pano Ethernet bildirmezse "Pano Ethernet bağlantısı bildirmiyor" (v1.3.0'dan eski olabilir).
   3. Pano zaten ev ağındaysa "Bu IP ile Doğrula" (Wi-Fi ya da Ethernet fark etmez).
6. **Bulut Bağlantısı:** "Panoya Bağlan" (IP) → "Buluta Bağla ve Bekle" (kimlik yazılır, en çok 90 sn). Pano zaten
   çevrimiçiyse (ör. kimliğini kendisi aldıysa) adım hemen tamamlanır. Zaman aşımında sebep söylenir; Ethernet'li panoya
   "Wi-Fi'den düştü" denmez.
7. **Röle Testi:**
   1. İsteğe bağlı "Şablon uygula": "Şablon Seç" → site/genel → şablon → önizleme → "Panoya Uygula".
   2. Panjur röleleri bilgi kartı ("Adım 8'de denenir"). Lamba rölelerinde "Aç"/"Kapat" → "Lamba / yük gerçekten çalıştı
      mı?"; darbe "Tetikle"; bağlı değilse "Kullanılmıyor".
   3. "Bu kanala ne bağlı?" (lamba + parlaklık sorusu / vana / siren / fan / diğer), "Girişler ve Sensörler". "Kablosuz sensör
      ekle" yalnız kablosuz sensörü destekleyen panoda görünür (v1.3.2 dahil hiçbir sürüm desteklemiyor). Panoda kayıtlı
      desteklenmeyen kablosuz sensör "Bu panoda kablosuz sensör desteklenmiyor; kaldırın." uyarısıyla görünür; kaldırılana kadar
      kayıt yapılamaz, kaldırılınca panodan da silinir.
   4. "Güvenlik Ayarlarını Panoya Yaz ve Test Et" → bölge testi (vana kapanmalı; gaz vanası kapalı kalır).
8. **Panjur Testi:** yön ("Panjur gerçekten YUKARI mı gitti?") → "Ölçüme Hazırla" → "Alta İndir" → "Ölçümü Başlat" →
   "Bitti" → "Kaydet ve Panoda Doğrula" (süre buluttan yazılır; pano çevrimiçi olmalı).
9. **Duvar Butonları:** "Dinlemeyi Başlat" → her butona basın → "Algılandı" ya da "Bu girişte buton yok". Güvenlik rolüne
   atanmış girişler (sensörler, vana geri bildirimi, alarm susturma / vana kapatma / gaz sıfırlama / anahtarlı kontak) bu adımda
   listelenmez ve teslim raporunda buton sayılmaz ("Güvenlik girişleri (N) bu adımda gösterilmez.").
10. **Teslim:** kontrol listesi (ağ satırı Wi-Fi ya da Ethernet), not, teslim alan, "Müşteriye kurulumu gösterdim…" →
    "Devreye Almayı Tamamla" → kurulum raporu ("Raporu Kopyala / Paylaş"). Ekrandaki not Android müşteriye
    "Arka planda alarm bildirimi" ayarını hatırlatır; siren önerisi kalır.

---

## 6. Diğer servis işleri

### 6.1 Pano değişimi
Evin bulut kopyasında güvenlik ayarı (sensör ya da vana) varsa değişimi yalnız servis yapar (personel hesabı, müşterinin servis
PIN'i ya da süper kullanıcı); ev sahibi denerse "Bu evde pano değişimini yetkili servis personeli yapmalıdır." görür. Yalnız
bölge adı tanımlı (sensörsüz, vanasız) evde ev sahibi de yapabilir.

1. Seçili evde: eski pano → yeni panonun etiketi + PIN + neden → "Pano değişimi onayı".
2. Kanal adları, kurallar ve panjur süreleri aktarılır; "Yeni Panoyu Şimdi Bağla" → sihirbaz 5. adım. Panjur süreleri yeni pano
   çevrimiçi olunca gönderilir; v1.2.1+ panoda yalnız panonun onayıyla "eşitlendi" sayılır.
3. **Güvenlik ayarları (sensörler, vanalar, bölgeler) yeni panoya aktarılmaz.** Eski panoda su/gaz sensörü ya da vana varsa sonuç
   ekranı uyarır ("Güvenlik ayarları (su/gaz sensörü, vana) yeni panoya aktarılmadı. Yetkili servisi çağırın."): sihirbazın 7. adımında
   güvenlik ayarlarını yeniden yazıp bölge testini yapmadan teslim etmeyin; o zamana kadar su/gaz koruması çalışmaz.

### 6.2 Acil sıfırlama
1. Cihaz kimliği + en az 15 karakter gerekçe + isteğe bağlı yeni sahip; UID yazılarak onay.
2. Eski ailenin yetkileri biter; cihaz stoğa ya da yeni sahibe geçer. Yeni kurulum PIN'i bir kez gösterilir.

### 6.3 Abone ve hesap yönetimi
1. "Servis Yönetimi" (hesap/müşteri ekle, dondur, davet), "Abonelerim & Cihaz Atama" ("Home Admin Ata" / "Yöneticiyi Devret").
   Aboneler listesindeki "Kurulumu sürdür" de yarım kaydı sorar (Bölüm 5.1, madde 5).
2. Dondurma: etkin hesap "askıda" olur; davet bekleyen hesap dondurulup çözülünce "davet bekliyor" kalır. Silinmiş hesapta
   dondurma, rol ve parola işlemi yapılamaz ("Silinmiş hesap üzerinde bu işlem yapılamaz.").
3. Müşterinin telefonunu siz yazar ya da değiştirirseniz telefon "doğrulanmamış" sayılır: o numarayla SMS girişi bu hesaba açılmaz
   (müşteri e-posta ve şifresiyle girer). Telefon alanlarında "+90 " hazır gelir; numara tek biçimde (+905…) saklanır.
4. Kalıcı silme (süper kullanıcı): kullanıcı panosu takılı bir dairenin tek sahibiyse "Kullanıcı, panosu olan bir dairenin tek
   sahibi. Kalıcı silmeden önce daireyi devredin ya da panoya acil sıfırlama yapın." görünür. Silinen kullanıcının sözleşme onay
   kayıtları kimliksiz saklanır.

### 6.4 Wi-Fi değişikliği (modem/şifre değişince)
"Wi-Fi Kurulum & Kurtarma Sihirbazı": kurulum ağına bağlan → yeni ağ bilgisini yükle. Giriş/internet gerekmez.

---

## 7. Pano neyi kendisi yapar (bilmeniz gerekenler)
1. İnternetsiz: lambalar, panjurlar, butonlar, su/gaz alarmı, vanalar çalışır.
2. Kurulum ağı: kayıtlı Wi-Fi yoksa açılır; Wi-Fi koparsa 10 dk açılır (en çok 30), kapanınca Wi-Fi hâlâ yoksa 15 dk sonra
   yeniden. **Provizyonlu ve Ethernet'i bağlı panoda açılmaz.**
3. Bulut kimliği: provizyonlu + ağı var + saati doğru + kimliği yok (ya da sunucu 3 kez reddetti) ise sunucudan kendisi
   ister. Sahiplenilmemişse 10 dk sonra yeniden dener. Aynı modemin arkasındaki çok sayıda sahiplenilmemiş pano, sahiplenilen
   panonun kimlik almasını artık engellemez (sunucunun ağ başına sınırını yalnız başarısız istekler harcar). Erişim bitince
   (üye çıkarma/ayrılma, devir, servis oturumunun bitişi) sunucu kimliği geçersiz kılar; pano reddedilince yenisini bu yolla alır.
4. Ethernet'ten gelen yerel istekler anahtarsız tam yetkili (kararınız, sınırsız); Wi-Fi'den gelenler anahtarlı. Bulut sunucu
   adresi v1.3.2'de kilitlidir: yalnız firmware'e gömülü sunucu kabul edilir.
5. Uzaktan firmware güncellemesi yok; yalnız USB.

---

## 8. Hata mesajları (sık görülenler)

| Mesaj | Anlamı | Ne yapmalı |
|---|---|---|
| "Geçersiz kurulum PIN kodu. Kalan deneme hakkı: N" | PIN yanlış | Etiketteki PIN'i kontrol edin; 5 yanlışta 15 dk kilit |
| "Bu cihaz zaten bir daireye bağlı" | Kart başka evde | Acil sıfırlama ya da devir |
| "Pano Ethernet bağlantısı bildirmiyor" | Firmware eski ya da IP yanlış | v1.3.0 yükleyin, kablolu IP'yi girin |
| "Pano 90 saniyede buluta bağlanamadı" | Kimlik/saat/ağ sorunu | Ekrandaki ayrıntıya göre; gerekirse "Kimliği Yeniden Yaz" |
| "Bağlı kart … eşleşmiyor" (USB) | Yanlış kart takılı | Doğru kartı takın |
| "Bu kart stokta değil" (Kart Bağla) | Kart müşteriye ait/askıda | Stoktaki kart kullanın |
| "Kurulmuş ya da teslim edilmiş dairenin kartı yalnız Pano Değişimi ile ya da yönetici tarafından değiştirilebilir." | Kuruldu / Teslim edildi daire | Pano Değişimi yapın ya da süper kullanıcıya başvurun |
| "Daire Şablonu Farklı" | Karta dairenin güncel şablonu yazılmadı | Daire listesini yenileyip güncel şablonu yazın |
| "Şablon yarım kaldı; aynı şablonu yeniden yazın." | Kartta şablon uygulaması yarım | Aynı şablonu yeniden yazın |
| "Kart meşgul" / "Panoda alarm sürüyor" / "Hırsız alarmı kurulu" | Kart yazmaya uygun değil | Bekleyin / alarmı çözün |
| "Kurulum ağı parolaları eşleşmiyor." / "Yazdığınız parola etiketteki parolayla eşleşmiyor." | AP parolası yanlış yazıldı | Etiketteki parolayı yeniden yazın ya da 2. karekodu okutun |
| "Bu müşteri uygulamaya telefonla giriş yapıyor; …" | Müşteri hesabında e-posta yok | Müşteri kendi karekoduyla sahiplenip servis PIN'i versin |
| "Bu panoda kablosuz sensör desteklenmiyor; kaldırın." | Panoda kayıtlı kablosuz sensör | 7. adımda kaldırın |
| "Bulut Bağlantısında Geçici Sorun" (Sistem Doktoru) | Sunucu ile panolar arasında geçici kesinti | Birkaç dakika bekleyin; Wi-Fi ayarına dokunmayın |

---

## 9. Açık kalan konular

> 2026-10-09 sahip kararlarından sonra güncellendi (`docs/CONTRACTS.md` §3j; kararlar `docs/denetim/2026-10-09-kararlar.md`).

1. **Uzaktan güncelleme yok:** her firmware değişikliği için kart USB'ye takılmalı.
2. **Provizyonsuz pano buluta kendiliğinden bağlanamaz** (kimlik isteğini imzalayacak anahtarı yok). Ethernet'te de sihirbaz
   önce ilk hazırlığı ister (pano v1.3.1'de gerçek `provisioned` değerini bildirir).
3. **Ethernet'te sınır yok (kararınız):** şablon yazımında kart kimliği denetlenmez, yerel istekler anahtarsız tam yetkilidir.
   Yazmadan önce IP'nin doğru dairenin kartı olduğunu kontrol edin.
4. **Telefon alarm bildirimi** yalnız Android'de ve cihazda henüz denenmedi; iOS'ta yok.
5. **Ethernet kablosu ve panonun kendi bulut kimliği (bootstrap)** gerçek kablo ve sunucuyla henüz denenmedi.
6. **Firmware v1.3.2'nin Ethernet kablosu, panonun bulut kimliğini kendisi alması, sunucu kilidinin reddi ve fabrika sıfırlaması
   kartta henüz denenmedi;** açılış, Wi-Fi ve bulut bağlantısı denendi (12/12 çökmesiz).
7. **v1.3.1 ve önceki panolarda uzun onay süresi hiç onaylanmaz** (gaz/duman 875 ms'den, su 2625 ms'den uzun): bu panolarda
   şablona bu değerlerden uzun onay süresi yazmayın. v1.3.2 pencereyi büyüterek düzeltir.
8. **Pano değişiminde güvenlik ayarları aktarılmıyor;** güvenlik ayarlı evde değişimi yalnız servis yapar (Bölüm 6.1). Buluttaki
   kopyadan geri yükleme sonraki sürümde.
9. **Bulut kimliği yenileme yalnız tek panolu evde** (çok panolu evde ve v1.3.0 öncesi panoda atlanır, sunucu günlüğüne yazılır).
10. **Kısa bir açık pencere:** erişimi biten kişi panonun eski yerel anahtarını biliyorsa, pano yeni bulut kimliğini alıp anahtar
    değişimi tamamlanana kadar panonun yerine kimlik isteyebilir (teknik bilgi gerekir; pano çevrimiçiyse kısa sürer). İzleniyor.
11. **Sonraya bırakılanlar (kararlarınız):** servis PIN'i ve giriş uçlarına toplu saldırıya karşı CAPTCHA; sözleşme onayı ve zorunlu
    şifre değişiminin sunucuda da zorlanması (şimdilik izleniyor); e-posta sistemi kurulunca e-postasız müşteri sahiplenmesi; etiket
    karekodunun iPhone'da uygulamayı doğrudan açması için Apple Team ID (Android'de 2026-10-09'dan beri açıyor); yasal metinlerdeki
    şirket bilgileri ve hukuk kararları (proje sonunda).
