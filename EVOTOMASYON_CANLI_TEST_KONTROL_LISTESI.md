# AHBU Ev Otomasyonu - CanlÄ± Saha & Sistem UÃ§tan Uca Test Kontrol Listesi

Bu kontrol listesi, sÄ±fÄ±rlanmÄ±ÅŸ ve temizlenmiÅŸ veritabanÄ± Ã¼zerinde **hayatÄ±n normal akÄ±ÅŸÄ±nda** sistemin canlÄ± olarak ayaÄŸa kaldÄ±rÄ±lmasÄ± ve test edilmesi iÃ§in hazÄ±rlanmÄ±ÅŸtÄ±r.

---

## ğŸ”‘ BaÅŸlangÄ±Ã§ Bilgileri

* **Sunucu (VPS API):** `http://178.210.161.55:5000` / CanlÄ± Port 5000 (PM2: `ev-api`)
* **SÃ¼per YÃ¶netici E-Posta:** `salihceylan@gmail.com`
* **SÃ¼per YÃ¶netici Åifre:** `Fingon08.`
* **VeritabanÄ± Durumu:** Tamamen temizlendi. Sadece `salihceylan@gmail.com` (`super_user`) mevcuttur. Test cihazlarÄ±, test daireleri ve test kullanÄ±cÄ±larÄ± sÄ±fÄ±rlanmÄ±ÅŸtÄ±r.
* **MQTT AltyapÄ±sÄ±:** EMQX Port 1884 & Port 8883 MQTTS devrede ve aktiftir (`mqtt_bridge: healthy`).

---

## ğŸ“‹ AdÄ±m AdÄ±m Kontrol Listesi

### AÅAMA 1: SÃ¼per KullanÄ±cÄ± GiriÅŸi & Sistem SaÄŸlÄ±k KontrolÃ¼
- [x] **1.1. UygulamayÄ± BaÅŸlatma:** Mobil veya masaÃ¼stÃ¼ uygulamayÄ± aÃ§Ä±n. AÃ§Ä±lÄ±ÅŸ animasyonunun ve dairesel AI devre logosunun akÄ±cÄ± geldiÄŸini doÄŸrulayÄ±n.
- [X] **1.2. SÃ¼per KullanÄ±cÄ± GiriÅŸi:** `salihceylan@gmail.com` ve `Fingon08.` bilgileriyle giriÅŸ yapÄ±n.
- [X] **1.3. SÃ¼per YÃ¶netici Konsolu:** Daire kullanÄ±cÄ±sÄ± olmadÄ±ÄŸÄ±nÄ±z iÃ§in ana ekranda gereksiz lamba, panjur, oda veya ev eÅŸleme kartlarÄ± yer almaz; doÄŸrudan altyapÄ± durumunu ve yÃ¶netim kÄ±sayollarÄ±nÄ± iÃ§eren **SÃ¼per YÃ¶netici Konsolu** karÅŸÄ±lar.
- [X] **1.4. Sol SandviÃ§ MenÃ¼ (â˜°):** Sol Ã¼stteki sandviÃ§ (hamburger) menÃ¼ simgesine dokunarak SÃ¼per YÃ¶netici Ã‡ekmecesini (Drawer) aÃ§Ä±n. Buradan Servis SorumlularÄ±, Teknisyenler, Servis Modu, Sistem Doktoru, Afet Modu Pano DeÄŸiÅŸimi, Tema ve Ã‡Ä±kÄ±ÅŸ seÃ§eneklerine eriÅŸildiÄŸini doÄŸrulayÄ±n.
- [X] **1.5. CanlÄ± AltyapÄ± & Operasyonel SayaÃ§lar:** Ana konsoldaki API Sunucusu (Port 5000), VeritabanÄ± (Port 5434) ve MQTT KÃ¶prÃ¼sÃ¼ (EMQX) yeÅŸil durumlarÄ±nÄ±, ayrÄ±ca Servis SorumlularÄ±, Saha Teknisyenleri ve Devreye AlÄ±nan Daire sayaÃ§larÄ±nÄ± inceleyin.

---

### AÅAMA 2: Yeni Servis Sorumlusu (Service User) TanÄ±mlama
- [X] **2.1. Sorumlu Ekleme:** Sorumlular sekmesinin saÄŸ altÄ±ndaki `+ Sorumlu Ekle` butonuna dokunun.
- [X] **2.2. Bilgileri Doldurma:**
  - **Ad Soyad:** (Ã–rn: *Ahmet Servis MÃ¼dÃ¼rÃ¼*)
  - **E-posta:** (Ã–rn: *servis@gudeteknoloji.com.tr*)
  - **Åifre:** En az 6 karakter (Ã–rn: *Servis2026!*)
  - **Telefon:** (Ã–rn: *+905551112233*)
  - **Rol:** `Servis Sorumlusu (service_user)` seÃ§in.
- [X] **2.3. KayÄ±t ve CanlÄ± Yenileme:** Kaydet butonuna basÄ±n. Form kapandÄ±ktan sonra listenin otomatik yenilenerek yeni servis sorumlusunun listede belirdiÄŸini teyit edin.
- [X] **2.4. SÃ¼per KullanÄ±cÄ± Ã‡Ä±kÄ±ÅŸÄ±:** SaÄŸ Ã¼stteki profil simgesinden *"Ã‡Ä±kÄ±ÅŸ Yap"* diyerek oturumu kapatÄ±n.

---

### AÅAMA 3: Servis Sorumlusu Olarak GiriÅŸ Yapma & Teknisyen TanÄ±mlama
- [X] **3.1. Servis Sorumlusu GiriÅŸi:** OluÅŸturulan servis sorumlusu e-postasÄ± ve ÅŸifresi ile sisteme giriÅŸ yapÄ±n.
- [X] **3.2. Yetkili Servis Konsolu DoÄŸrulamasÄ±:** 
  - Servis sorumlusu giriÅŸ yaptÄ±ÄŸÄ±nda karmaÅŸÄ±k daire ekranÄ± (Ä±ÅŸÄ±k, panjur vb.) yerine doÄŸrudan **Yetkili Servis Konsolu** karÅŸÄ±lar.
  - CanlÄ± altyapÄ± Ã§ipleri (API Port 5000, DB 5434, MQTT EMQX), operasyonel sayaÃ§lar ve saha devreye alma aksiyon listesi (Saha Teknisyen YÃ¶netimi, Devreye Alma, Pano DeÄŸiÅŸimi, Acil Devir, Sistem Doktoru, Yetkili Servis AÄŸÄ±) yer alÄ±r.
  - Sol sandviÃ§ menÃ¼de (â˜°) `ğŸ› ï¸ YETKÄ°LÄ° SERVÄ°S KONSOLU` rozeti gÃ¶rÃ¼ntÃ¼lenir.
- [X] **3.3. Servis Sorumlusu Ekleme KÄ±sÄ±tlamasÄ± (Rol Ä°zolasyonu):**
  - Servis sorumlusunun yeni bir servis sorumlusu (`service_user`) veya sÃ¼per kullanÄ±cÄ± (`super_user`) ekleyemediÄŸini doÄŸrulayÄ±n. (Servis sorumlularÄ±nÄ± sadece SÃ¼per KullanÄ±cÄ± ekler).
  - Servis YÃ¶netim Paneli -> "Sorumlular" sekmesinde `+ Sorumlu Ekle` butonu tamamen gizlidir; liste "Salt Okunur" rozetiyle korunur.
  - Backend API seviyesinde `service_user` rolÃ¼nÃ¼n `super_user` veya `service_user` oluÅŸturmasÄ±/dÃ¼zenlemesi 403 Forbidden ile engellenmiÅŸtir.


---

### AÅAMA 4: Daire Sahibi (MÃ¼ÅŸteri / Admin) TanÄ±mlama
- [ ] **4.1. MÃ¼ÅŸteri HesabÄ± OluÅŸturma:** Servis Sorumlusu panelinden dairenin asÄ±l sahibi olacak kullanÄ±cÄ±yÄ± sisteme ekleyin veya cihaz eÅŸleme adÄ±mÄ±nda mÃ¼ÅŸterinin e-posta/telefon bilgisini hedef sahip olarak belirleyin.
- [ ] **4.2. Daire Bilgisi:** Daireye verilecek isim (Ã–rn: *"Daire 4 - Ceylan ApartmanÄ±"* veya *"YazlÄ±k Daire"*).

---

### AÅAMA 4.5: Fabrika / AtÃ¶lye - Cihaz Karekodu Ãœretimi & Etiket BasÄ±mÄ± (MasaÃ¼stÃ¼ AracÄ±)
- [ ] **4.5. MasaÃ¼stÃ¼ Servis YazÄ±lÄ±mÄ±nÄ± BaÅŸlatma:** `G:\site\ev_otomasyon\ev_otomasyon_servis_yazilimi\ev_otomasyon_sistemi.bat` Ã§alÄ±ÅŸtÄ±rÄ±lÄ±r ve *"ğŸ·ï¸ 2. Karekod Ãœret & Etiket Bas (Envanter)"* sekmesine geÃ§ilir.
- [ ] **4.6. DonanÄ±mdan MAC Okuma & Bilgi Ãœretimi:** COM Port seÃ§ilerek *"ğŸ“¡ Karttan MAC Oku"* butonuna basÄ±lÄ±r. Ã‡ipin donanÄ±m MAC adresi (`E8:F6:0A:XX:XX:XX`), benzersiz UUID'si (`AHBU-S3-XXXXXX`) ve 6 haneli rastgele Kurulum PIN'i (`XXXXXX`) otomatik doldurulur.
- [ ] **4.7. Sunucuya KayÄ±t & SÄ±fÄ±r-MÃ¼kerrerlik DoÄŸrulamasÄ±:** 
  - *"â˜ï¸ Sunucu Envanterine Kaydet & Karekod Ãœret"* butonuna basÄ±lÄ±r.
  - CihazÄ±n sunucuda deÄŸiÅŸmez ID, artan sÄ±ra no (`serial_no`) ve kayÄ±t zamanÄ±yla (`created_at`) envantere `IN_STOCK` olarak eklendiÄŸi gÃ¶rÃ¼lÃ¼r.
  - AynÄ± cihaz iÃ§in butona 2. kez basÄ±larak mÃ¼kerrer kayÄ±t korumasÄ±nÄ±n (HTTP 409) devreye girdiÄŸi ve engellediÄŸi teyit edilir.
- [ ] **4.8. Termal Etiket Ã‡Ä±ktÄ±sÄ± & YapÄ±ÅŸtÄ±rma:** Ekranda otomatik render edilen yÃ¼ksek Ã§Ã¶zÃ¼nÃ¼rlÃ¼klÃ¼ etiket Ã¶nizlenir, *"ğŸ’¾ Kaydet"* veya *"ğŸ–¨ï¸ YazdÄ±r"* ile termal barkod etiketi Ã§Ä±kartÄ±larak pano kapaÄŸÄ±na yapÄ±ÅŸtÄ±rÄ±lÄ±r.

---

### AÅAMA 5: CihazÄ± Sisteme Ekleme & Daireye Atama (Claiming)
- [ ] **5.1. Pano EÅŸleme EkranÄ±nÄ± AÃ§ma:** Ana ekrandaki *"Karekod ile Cihaz EÅŸle"* veya *"Kodu Elle Gir (Manuel EÅŸleme)"* seÃ§eneÄŸini aÃ§Ä±n.
- [ ] **5.2. Cihaz Bilgilerini Girme:**
  - **Cihaz Seri No / UUID:** Panonun Ã¼zerinde yazan UUID (Ã–rn: `DEV-S3-XXXX-AHBU`)
  - **Kurulum PIN (Setup PIN):** Panonun 6 haneli kurulum ÅŸifresi
  - **Daire AdÄ±:** Hedef Daire Ä°smi
  - **MÃ¼ÅŸteri (Hedef Sahip):** 4. AdÄ±mda tanÄ±mlanan daire sahibinin e-postasÄ±
- [ ] **5.3. Sahiplenme OnayÄ±:** "EÅŸle ve Daireye Ata" butonuna basÄ±n.
- [ ] **5.4. Otomatik YapÄ±landÄ±rma:** CihazÄ±n daireye baÅŸarÄ±yla baÄŸlandÄ±ÄŸÄ±nÄ±, 16 adet kontrol kanalÄ±nÄ±n (rÃ¶leler ve panjurlar) veritabanÄ±nda otomatik oluÅŸtuÄŸunu gÃ¶rÃ¼n.

---

### AÅAMA 6: Servis Modu ile RÃ¶le & Panjur YapÄ±landÄ±rmasÄ± (Kalibrasyon)
- [ ] **6.1. Servis Modunu AÃ§ma:** Servis YÃ¶netim Paneli -> *GÃ¶revler & AraÃ§lar* sekmesinden **"Servis Modu (Cihaz Kurulumu & Kalibrasyon)"** aracÄ±na girin.
- [ ] **6.2. Kanal Ä°simlendirme:**
  - Kanal 1-2: *Salon Panjuru (YukarÄ± / AÅŸaÄŸÄ±)*
  - Kanal 3: *Salon Avize (Lamba)*
  - Kanal 4: *Mutfak Tezgah Spot (Lamba)*
  - Kanal 5: *Kombi / Termostat (Ä°mpuls / Darbe RÃ¶lesi)*
  - vb. Ã§Ä±kÄ±ÅŸlarÄ± isimlendirin.
- [ ] **6.3. Panjur Motor SÃ¼resi:** Panjur Ã§Ä±kÄ±ÅŸlarÄ± iÃ§in motor seyir sÃ¼resini (Ã–rn: *20 saniye*) ve elektriksel interlock (Ã§ift yÃ¶n Ã§akÄ±ÅŸma Ã¶nleyici) korumasÄ±nÄ± ayarlayÄ±n.
- [ ] **6.4. AyarlarÄ± Panoya GÃ¶nderme:** "Panoya Senkronize Et" butonuna basarak ayarlarÄ±n cihaza iletildiÄŸini doÄŸrulayÄ±n.

---

### AÅAMA 7: Devreye Alma (Commissioning) OnayÄ±
- [ ] **7.1. CanlÄ± DonanÄ±m Testi:** Servis Modu test ekranÄ±nda her bir rÃ¶leyi sÄ±rayla aÃ§Ä±p kapatarak panodaki rÃ¶le seslerini ve lamba tepkilerini doÄŸrulayÄ±n.
- [ ] **7.2. Panjur Testi:** PanjurlarÄ± yukarÄ±/aÅŸaÄŸÄ± sÃ¼rÃ¼p durdurma emrinin Ã§alÄ±ÅŸtÄ±ÄŸÄ±nÄ± gÃ¶rÃ¼n.
- [ ] **7.3. Devreye Alma OnayÄ± Verme:** TÃ¼m testlerin geÃ§tiÄŸini iÅŸaretleyip *"Devreye AlmayÄ± Onayla ve MÃ¼ÅŸteriye Teslim Et"* butonuna basÄ±n.
- [ ] **7.4. Servis Ã‡Ä±kÄ±ÅŸÄ±:** Servis sorumlusu oturumunu kapatÄ±n.

---

### AÅAMA 8: Daire Sahibinin Kendi EkranÄ±ndan CanlÄ± KontrolÃ¼
- [ ] **8.1. Daire Sahibi GiriÅŸi:** Daire sahibinin e-posta ve ÅŸifresi ile uygulamaya giriÅŸ yapÄ±n.
- [ ] **8.2. HazÄ±r Panel KarÅŸÄ±lamasÄ±:** Daire sahibinin karÅŸÄ±sÄ±na doÄŸrudan dairesinin kontrol paneli, tanÄ±mlanmÄ±ÅŸ lamba ve panjur kartlarÄ±nÄ±n eksiksiz geldiÄŸini gÃ¶rÃ¼n.
- [ ] **8.3. Lamba AÃ§/Kapa:** Lamba kartlarÄ±na dokunarak canlÄ± olarak rÃ¶leleri aÃ§Ä±p kapatÄ±n.
- [ ] **8.4. Panjur KontrolÃ¼:** Panjur kartÄ±ndan yukarÄ±/aÅŸaÄŸÄ± ve yÃ¼zdeye gÃ¶re konumlandÄ±rma komutlarÄ±nÄ± Ã§alÄ±ÅŸtÄ±rÄ±n.
- [ ] **8.5. Hepsini Kapat (Gece Huzur Modu):** Glanceable Ã¼st bar veya Huzur Modu kartÄ±ndan *"Hepsini Kapat"* butonuna basarak tÃ¼m Ä±ÅŸÄ±klarÄ±n tek dokunuÅŸla kapandÄ±ÄŸÄ±nÄ± test edin.

---

### AÅAMA 9: SÃ¼per KullanÄ±cÄ± Takip & TeÅŸhis (Final Kontrol)
- [ ] **9.1. SÃ¼per KullanÄ±cÄ± ile Tekrar GiriÅŸ:** `salihceylan@gmail.com` ile oturum aÃ§Ä±n.
- [ ] **9.2. CanlÄ± Servis Ä°statistikleri:** Servis Paneli'ndeki gÃ¶stergelerin gÃ¼ncellendiÄŸini gÃ¶rÃ¼n (OluÅŸturulan servis gÃ¶revlisi sayÄ±sÄ±, pano envanteri, devreye alÄ±nmÄ±ÅŸ aktif daireler).
- [ ] **9.3. Sistem Doktoru:** Sistem Doktoru aracÄ±nÄ± Ã§alÄ±ÅŸtÄ±rarak VeritabanÄ± Gecikmesi, MQTT KÃ¶prÃ¼sÃ¼, WebSocket ve Servis UÃ§ NoktalarÄ±nÄ±n yeÅŸil/saÄŸlÄ±klÄ± olduÄŸunu teyit edin.

---

### AÅAMA 10: Yetkili Servis Konsolu & TÃ¼mleÅŸik Saha AraÃ§larÄ± DoÄŸrulamasÄ±
- [ ] **10.1. Yetkili Servis GiriÅŸi:** `mistikahmet35@gmail.com` (Yetkili Servis Sorumlusu) ile giriÅŸ yapÄ±n.
- [ ] **10.2. Konsol BaÅŸlÄ±ÄŸÄ± & Rozet:** Ekranda "Yetkili Servis Konsolu", "Saha Operasyon & Montaj YÃ¶netimi" alt baÅŸlÄ±ÄŸÄ± ve turkuaz "YETKÄ°LÄ° SERVÄ°S" rozetinin gÃ¶rÃ¼ntÃ¼lendiÄŸini doÄŸrulayÄ±n.
- [ ] **10.3. TÃ¼mleÅŸik 8 Saha AracÄ±:** Ekranda 8 saha aracÄ±nÄ±n (Devreye Alma, Karekod ile Pano EÅŸle, Cihaz Envanteri & Seri No, Pano DeÄŸiÅŸimi, Wi-Fi YapÄ±landÄ±rma & Kurtarma, Sistem Doktoru, Acil SÄ±fÄ±rlama & MÃ¼lk Devri, Yetkili Servis AÄŸÄ±) eksiksiz yer aldÄ±ÄŸÄ±nÄ± ve Ã§alÄ±ÅŸtÄ±ÄŸÄ±nÄ± test edin.
- [ ] **10.4. 2 Sekmeli Servis Paneli:** "TÃ¼m Paneli AÃ§" veya SandviÃ§ MenÃ¼den "Servis SorumlularÄ±" sayfasÄ±na giderek tablarÄ±n yalnÄ±zca "Sorumlular" ve "GÃ¶revler & AraÃ§lar" olarak 2 sekmeden oluÅŸtuÄŸunu doÄŸrulayÄ±n.

---

*Not: Her test adÄ±mÄ±nÄ± sÄ±rayla gerÃ§ekleÅŸtirdikten sonra ilgili kutucuÄŸu `[x]` olarak iÅŸaretleyebilirsiniz.*

---

### ASAMA 11: Dairesi Olmayan Yeni Bireysel Kullanici - Sadelesstirilmis Katilim Ekrani

- [ ] **11.1.** Dairesi olmayan kullanici ile giris: Normal daire kontrolleri gizlenmeli, yalnizca 'Kod ile Bir Eve Katil' ve 'Karekod ile Katil' butonlari ile bilgi karti gorulmeli.
- [ ] **11.2.** Kod ile katilim akisi: Gecerli davet kodu ile katilim basarili oldugunda sayfa otomatik yenilenmeli ve normal dashboard acilmali.
- [ ] **11.3.** QR ile katilim: Davet QR'i basarili islenmeli; cihaz esleme QR'i hata vermeli.
- [ ] **11.4.** AppBar sadelesstirilmesi: Yalnizca Yenile ve Profil ikonlari gozukmeli; mod degistirici ve ayarlar gizli olmali.

---

### AŞAMA 12: Süper Kullanıcı ve Servis Sorumlusu Menü & Panel İzolasyonu Doğrulaması

- [ ] **12.1. Süper Kullanıcı Sandviç Menü:** Süper kullanıcıda menüde yalnızca 'Yönetici Konsolu', 'Cihaz Envanteri', 'Servis Sorumluları', 'Sistem Doktoru' yer almalı; saha montaj araçları ('Servis Modu', 'Karekod ile Pano Eşle', 'Pano Değişimi', 'Wi-Fi Yapılandırma & Kurtarma', 'Acil Sıfırlama & Mülk Devri') kesinlikle bulunmamalıdır.
- [ ] **12.2. Süper Kullanıcı Panel İzolasyonu:** Konsol hızlı işlemlerinde yalnızca 'Cihaz Envanteri & Ekleme', 'Servis Sorumluları Yönetimi' ve 'Sistem Doktoru' kartları yer almalı; saha/kalibrasyon kartları bulunmamalıdır.
- [ ] **12.3. Süper Kullanıcı Sorumlular Sayfası:** 'Servis Sorumluları' sayfası açıldığında doğrudan sorumlu listesi ve 'Sorumlu Ekle' butonu yer almalı; servis araçları sekmesi bulunmamalıdır.
- [ ] **12.4. Servis Sorumlusu Sandviç Menü İzolasyonu:** Servis sorumlusunda menüde yalnızca 'Servis Konsolu' ve saha montaj araçları ('Servis Modu & Kalibrasyon', 'Karekod ile Pano Eşle', 'Pano Değişimi (Afet Modu)', 'Wi-Fi Yapılandırma & Kurtarma', 'Acil Sıfırlama & Mülk Devri') yer almalı; 'Cihaz Envanteri', 'Servis Sorumluları' ve 'Sistem Doktoru' KESİNLİKLE görünmemelidir.
- [ ] **12.5. Servis Sorumlusu Panel İzolasyonu:** Servis Sorumlusu Dashboard'ında yalnızca 5 saha aracı (Devreye Alma, Karekod ile Pano Eşle, Pano Değişimi, Wi-Fi Yapılandırma, Acil Sıfırlama) yer almalı; Süper User'a ait 'Cihaz Envanteri & Seri No', 'Sistem Doktoru (Teşhis)', 'Yetkili Servis Ağı' kartları ve 'Tüm Paneli Aç' linki KESİNLİKLE görünmemelidir.

---

### AŞAMA 13: Servis Sorumlusu Devreye Alma Menüsünde Karekod Eşleme & Müşteri OTP Doğrulaması

- [ ] **13.1. Bağımsız Karekod Menüsü İzolasyonu:** Servis Sorumlusu konsolunda ve Sandviç Menüde bağımsız 'Karekod ile Pano Eşle' seçeneğinin bulunmadığını; bunun yerine tüm pano eşleme işlemlerinin 'Devreye Alma (Commissioning)' menüsü içine taşındığını doğrulayın.
- [ ] **13.2. Devreye Alma İçinde Karekod Tarama:** Devreye Alma menüsünde 'Yeni Pano Cihazı Eşleme & Müşteriye Teslim' kartında 'Pano Karekodunu Oku (Kamera ile Tara)' butonuna basıldığında kameranın açıldığını, QR okutulduğunda Pano UUID ve 6 haneli Kurulum PIN alanlarının otomatik dolduğunu test edin.
- [ ] **13.3. Servis Sorumlusu Cihaz Sahipliği Engeli:** Servis sorumlusu kendi e-posta/telefonunu girdiğinde veya müşteri alanı boşken sistemi kurmayı denediğinde sistemin 'Yetkili servis sorumlusu cihaz sahibi olamaz! Cihaz daire sahibine (müşteriye) tanımlanmalıdır.' uyarısı verdiğini doğrulayın.
- [ ] **13.4. Müşteri OTP Gönderim ve Doğrulama Akışı:** Daire sahibinin e-posta/telefonu girilip 'Müşteriye Doğrulama Kodu Gönder' butonuna basıldığında müşteriye 6 haneli onay kodu iletildiğini; bu kod sisteme girilmeden cihazın kişiye veya daireye kesinlikle tanımlanamadığını (onay kodu girilip doğrulandığında ise cihazın müşteriye başarıyla tanımlandığını) doğrulayın.

---

### AŞAMA 14: Acil Servis Sıfırlaması & Pano Değişiminde Karekod (QR Kod) Okuma Doğrulaması

- [ ] **14.1. Devreye Alma Menüsünde Acil Servis Sıfırlaması QR Okuma:** Servis Modu (Devreye Alma) sayfasındaki '⚠️ Acil Servis Sıfırlaması' kartında 'Acil Sıfırlama için Pano Karekodunu Oku' butonu veya UUID alanı yanındaki QR tarama ikonuna basıldığında kameranın açıldığını, panonun QR kodu okutulduğunda UUID alanının otomatik olarak dolduğunu ve yeşil onay bildirimi gösterildiğini doğrulayın.
- [ ] **14.2. Acil Sıfırlama & Mülk Devri Diyaloğunda QR Okuma:** Dashboard ve menüdeki 'Acil Sıfırlama & Mülk Devri' diyaloğuna 'Acil Pano Sıfırlama' sekmesinin eklendiğini, bu sekmede kamera ile pano QR kodunun okutularak UUID'nin otomatik doldurulduğunu ve gerekçe girilerek cihazın tek tıkla boşa çıkarılabildiğini test edin.
- [ ] **14.3. Pano Değişimi (Disaster Recovery) QR Okuma:** 'Pano Değişimi & Kurtarma' diyaloğunda Yeni Pano UUID alanındaki kamera ikonuyla yeni kartın QR kodunun okutulduğunda hem UUID hem de Kurulum PIN alanlarının otomatik doldurulduğunu doğrulayın.

---

### AŞAMA 15: Aydınlık Tema & Yüksek Çözünürlüklü Elektronik Devre Arka Planı Doğrulaması

- [ ] **15.1. Aydınlık Temada Elektronik Devre Görünürlüğü:** Aydınlık tema modunda (Light Theme) arka planda özel tasarlanmış platin/buz mavisi elektronik devre kartı (PCB yolları, via delikleri, mikroçip hatları) net ve estetik şekilde görünmeli; gri veya düz beyazla örtülmemelidir.
- [ ] **15.2. Saha Servis & Konsol Başlık Metinleri Kontrastı:** Aydınlık temada "🛠️ Saha Servis & Devreye Alma Görevleri", "⚡ Hızlı Yönetici İşlemleri" ve tüm bölüm başlıkları `#0F172A` (koyu lacivert/siyah) renginde olmalı, asla beyaz veya silik görünmemelidir.
- [ ] **15.3. Görev Kartları ve Metrik Kutuları Uyumluluğu:** Servis sorumlusu ve süper kullanıcı konsolundaki tüm görev kartları, metrik kutuları ve bilgi panelleri açık modda temiz beyaz kart yüzeyi (`#FFFFFF`), belirgin çerçeve (`#CBD5E1`) ve yüksek kontrastlı okunabilir metinlerle görüntülenmelidir.
- [ ] **15.4. Koyu Mod Uyumluluğunun Korunması:** Koyu tema moduna (Dark Theme) geçildiğinde derin siber lacivert devre kartı arka planı ve parlak neon cyan/mavi veri hatları eksiksiz çalışmalı; hiçbir modda taşma (RenderFlex overflow) olmamalıdır.


