# AHBU Ev Otomasyonu - Canlı Saha & Sistem Uçtan Uca Test Kontrol Listesi

Bu kontrol listesi, sıfırlanmış ve temizlenmiş veritabanı üzerinde **hayatın normal akışında** sistemin canlı olarak ayağa kaldırılması ve test edilmesi için hazırlanmıştır.

---

## 🔑 Başlangıç Bilgileri

* **Sunucu (VPS API):** `http://178.210.161.55:5000` / Canlı Port 5000 (PM2: `ev-api`)
* **Süper Yönetici E-Posta:** `salihceylan@gmail.com`
* **Süper Yönetici Şifre:** `Fingon08.`
* **Veritabanı Durumu:** Tamamen temizlendi. Sadece `salihceylan@gmail.com` (`super_user`) mevcuttur. Test cihazları, test daireleri ve test kullanıcıları sıfırlanmıştır.
* **MQTT Altyapısı:** EMQX Port 1884 & Port 8883 MQTTS devrede ve aktiftir (`mqtt_bridge: healthy`).

---

## 📋 Adım Adım Kontrol Listesi

### AŞAMA 1: Süper Kullanıcı Girişi & Sistem Sağlık Kontrolü
- [x] **1.1. Uygulamayı Başlatma:** Mobil veya masaüstü uygulamayı açın. Açılış animasyonunun ve dairesel AI devre logosunun akıcı geldiğini doğrulayın.
- [X] **1.2. Süper Kullanıcı Girişi:** `salihceylan@gmail.com` ve `Fingon08.` bilgileriyle giriş yapın.
- [X] **1.3. Süper Yönetici Konsolu:** Daire kullanıcısı olmadığınız için ana ekranda gereksiz lamba, panjur, oda veya ev eşleme kartları yer almaz; doğrudan altyapı durumunu ve yönetim kısayollarını içeren **Süper Yönetici Konsolu** karşılar.
- [X] **1.4. Sol Sandviç Menü (☰):** Sol üstteki sandviç (hamburger) menü simgesine dokunarak Süper Yönetici Çekmecesini (Drawer) açın. Buradan Servis Sorumluları, Teknisyenler, Servis Modu, Sistem Doktoru, Afet Modu Pano Değişimi, Tema ve Çıkış seçeneklerine erişildiğini doğrulayın.
- [X] **1.5. Canlı Altyapı & Operasyonel Sayaçlar:** Ana konsoldaki API Sunucusu (Port 5000), Veritabanı (Port 5434) ve MQTT Köprüsü (EMQX) yeşil durumlarını, ayrıca Servis Sorumluları, Saha Teknisyenleri ve Devreye Alınan Daire sayaçlarını inceleyin.

---

### AŞAMA 2: Yeni Servis Sorumlusu (Service User) Tanımlama
- [X] **2.1. Sorumlu Ekleme:** Sorumlular sekmesinin sağ altındaki `+ Sorumlu Ekle` butonuna dokunun.
- [X] **2.2. Bilgileri Doldurma:**
  - **Ad Soyad:** (Örn: *Ahmet Servis Müdürü*)
  - **E-posta:** (Örn: *servis@gudeteknoloji.com.tr*)
  - **Şifre:** En az 6 karakter (Örn: *Servis2026!*)
  - **Telefon:** (Örn: *+905551112233*)
  - **Rol:** `Servis Sorumlusu (service_user)` seçin.
- [X] **2.3. Kayıt ve Canlı Yenileme:** Kaydet butonuna basın. Form kapandıktan sonra listenin otomatik yenilenerek yeni servis sorumlusunun listede belirdiğini teyit edin.
- [X] **2.4. Süper Kullanıcı Çıkışı:** Sağ üstteki profil simgesinden *"Çıkış Yap"* diyerek oturumu kapatın.

---

### AŞAMA 3: Servis Sorumlusu Olarak Giriş Yapma & Teknisyen Tanımlama
- [X] **3.1. Servis Sorumlusu Girişi:** Oluşturulan servis sorumlusu e-postası ve şifresi ile sisteme giriş yapın.
- [X] **3.2. Yetkili Servis Konsolu Doğrulaması:** 
  - Servis sorumlusu giriş yaptığında karmaşık daire ekranı (ışık, panjur vb.) yerine doğrudan **Yetkili Servis Konsolu** karşılar.
  - Canlı altyapı çipleri (API Port 5000, DB 5434, MQTT EMQX), operasyonel sayaçlar ve saha devreye alma aksiyon listesi (Saha Teknisyen Yönetimi, Devreye Alma, Pano Değişimi, Acil Devir, Sistem Doktoru, Yetkili Servis Ağı) yer alır.
  - Sol sandviç menüde (☰) `🛠️ YETKİLİ SERVİS KONSOLU` rozeti görüntülenir.
- [X] **3.3. Servis Sorumlusu Ekleme Kısıtlaması (Rol İzolasyonu):**
  - Servis sorumlusunun yeni bir servis sorumlusu (`service_user`) veya süper kullanıcı (`super_user`) ekleyemediğini doğrulayın. (Servis sorumlularını sadece Süper Kullanıcı ekler).
  - Servis Yönetim Paneli -> "Sorumlular" sekmesinde `+ Sorumlu Ekle` butonu tamamen gizlidir; liste "Salt Okunur" rozetiyle korunur.
  - Backend API seviyesinde `service_user` rolünün `super_user` veya `service_user` oluşturması/düzenlemesi 403 Forbidden ile engellenmiştir.


---

### AŞAMA 4: Daire Sahibi (Müşteri / Admin) Tanımlama
- [ ] **4.1. Müşteri Hesabı Oluşturma:** Servis Sorumlusu panelinden dairenin asıl sahibi olacak kullanıcıyı sisteme ekleyin veya cihaz eşleme adımında müşterinin e-posta/telefon bilgisini hedef sahip olarak belirleyin.
- [ ] **4.2. Daire Bilgisi:** Daireye verilecek isim (Örn: *"Daire 4 - Ceylan Apartmanı"* veya *"Yazlık Daire"*).

---

### AŞAMA 4.5: Fabrika / Atölye - Cihaz Karekodu Üretimi & Etiket Basımı (Masaüstü Aracı)
- [ ] **4.5. Masaüstü Servis Yazılımını Başlatma:** `G:\site\ev_otomasyon\ev_otomasyon_servis_yazilimi\ev_otomasyon_sistemi.bat` çalıştırılır ve *"🏷️ 2. Karekod Üret & Etiket Bas (Envanter)"* sekmesine geçilir.
- [ ] **4.6. Donanımdan MAC Okuma & Bilgi Üretimi:** COM Port seçilerek *"📡 Karttan MAC Oku"* butonuna basılır. Çipin donanım MAC adresi (`E8:F6:0A:XX:XX:XX`), benzersiz UUID'si (`AHBU-S3-XXXXXX`) ve 6 haneli rastgele Kurulum PIN'i (`XXXXXX`) otomatik doldurulur.
- [ ] **4.7. Sunucuya Kayıt & Sıfır-Mükerrerlik Doğrulaması:** 
  - *"☁️ Sunucu Envanterine Kaydet & Karekod Üret"* butonuna basılır.
  - Cihazın sunucuda değişmez ID, artan sıra no (`serial_no`) ve kayıt zamanıyla (`created_at`) envantere `IN_STOCK` olarak eklendiği görülür.
  - Aynı cihaz için butona 2. kez basılarak mükerrer kayıt korumasının (HTTP 409) devreye girdiği ve engellediği teyit edilir.
- [ ] **4.8. Termal Etiket Çıktısı & Yapıştırma:** Ekranda otomatik render edilen yüksek çözünürlüklü etiket önizlenir, *"💾 Kaydet"* veya *"🖨️ Yazdır"* ile termal barkod etiketi çıkartılarak pano kapağına yapıştırılır.

---

### AŞAMA 5: Cihazı Sisteme Ekleme & Daireye Atama (Claiming)
- [ ] **5.1. Pano Eşleme Ekranını Açma:** Ana ekrandaki *"Karekod ile Cihaz Eşle"* veya *"Kodu Elle Gir (Manuel Eşleme)"* seçeneğini açın.
- [ ] **5.2. Cihaz Bilgilerini Girme:**
  - **Cihaz Seri No / UUID:** Panonun üzerinde yazan UUID (Örn: `DEV-S3-XXXX-AHBU`)
  - **Kurulum PIN (Setup PIN):** Panonun 6 haneli kurulum şifresi
  - **Daire Adı:** Hedef Daire İsmi
  - **Müşteri (Hedef Sahip):** 4. Adımda tanımlanan daire sahibinin e-postası
- [ ] **5.3. Sahiplenme Onayı:** "Eşle ve Daireye Ata" butonuna basın.
- [ ] **5.4. Otomatik Yapılandırma:** Cihazın daireye başarıyla bağlandığını, 16 adet kontrol kanalının (röleler ve panjurlar) veritabanında otomatik oluştuğunu görün.

---

### AŞAMA 6: Servis Modu ile Röle & Panjur Yapılandırması (Kalibrasyon)
- [ ] **6.1. Servis Modunu Açma:** Servis Yönetim Paneli -> *Görevler & Araçlar* sekmesinden **"Servis Modu (Cihaz Kurulumu & Kalibrasyon)"** aracına girin.
- [ ] **6.2. Kanal İsimlendirme:**
  - Kanal 1-2: *Salon Panjuru (Yukarı / Aşağı)*
  - Kanal 3: *Salon Avize (Lamba)*
  - Kanal 4: *Mutfak Tezgah Spot (Lamba)*
  - Kanal 5: *Kombi / Termostat (İmpuls / Darbe Rölesi)*
  - vb. çıkışları isimlendirin.
- [ ] **6.3. Panjur Motor Süresi:** Panjur çıkışları için motor seyir süresini (Örn: *20 saniye*) ve elektriksel interlock (çift yön çakışma önleyici) korumasını ayarlayın.
- [ ] **6.4. Ayarları Panoya Gönderme:** "Panoya Senkronize Et" butonuna basarak ayarların cihaza iletildiğini doğrulayın.

---

### AŞAMA 7: Devreye Alma (Commissioning) Onayı
- [ ] **7.1. Canlı Donanım Testi:** Servis Modu test ekranında her bir röleyi sırayla açıp kapatarak panodaki röle seslerini ve lamba tepkilerini doğrulayın.
- [ ] **7.2. Panjur Testi:** Panjurları yukarı/aşağı sürüp durdurma emrinin çalıştığını görün.
- [ ] **7.3. Devreye Alma Onayı Verme:** Tüm testlerin geçtiğini işaretleyip *"Devreye Almayı Onayla ve Müşteriye Teslim Et"* butonuna basın.
- [ ] **7.4. Servis Çıkışı:** Servis sorumlusu oturumunu kapatın.

---

### AŞAMA 8: Daire Sahibinin Kendi Ekranından Canlı Kontrolü
- [ ] **8.1. Daire Sahibi Girişi:** Daire sahibinin e-posta ve şifresi ile uygulamaya giriş yapın.
- [ ] **8.2. Hazır Panel Karşılaması:** Daire sahibinin karşısına doğrudan dairesinin kontrol paneli, tanımlanmış lamba ve panjur kartlarının eksiksiz geldiğini görün.
- [ ] **8.3. Lamba Aç/Kapa:** Lamba kartlarına dokunarak canlı olarak röleleri açıp kapatın.
- [ ] **8.4. Panjur Kontrolü:** Panjur kartından yukarı/aşağı ve yüzdeye göre konumlandırma komutlarını çalıştırın.
- [ ] **8.5. Hepsini Kapat (Gece Huzur Modu):** Glanceable üst bar veya Huzur Modu kartından *"Hepsini Kapat"* butonuna basarak tüm ışıkların tek dokunuşla kapandığını test edin.

---

### AŞAMA 9: Süper Kullanıcı Takip & Teşhis (Final Kontrol)
- [ ] **9.1. Süper Kullanıcı ile Tekrar Giriş:** `salihceylan@gmail.com` ile oturum açın.
- [ ] **9.2. Canlı Servis İstatistikleri:** Servis Paneli'ndeki göstergelerin güncellendiğini görün (Oluşturulan servis görevlisi sayısı, pano envanteri, devreye alınmış aktif daireler).
- [ ] **9.3. Sistem Doktoru:** Sistem Doktoru aracını çalıştırarak Veritabanı Gecikmesi, MQTT Köprüsü, WebSocket ve Servis Uç Noktalarının yeşil/sağlıklı olduğunu teyit edin.

---

### AŞAMA 10: Yetkili Servis Konsolu & Tümleşik Saha Araçları Doğrulaması
- [ ] **10.1. Yetkili Servis Girişi:** `mistikahmet35@gmail.com` (Yetkili Servis Sorumlusu) ile giriş yapın.
- [ ] **10.2. Konsol Başlığı & Rozet:** Ekranda "Yetkili Servis Konsolu", "Saha Operasyon & Montaj Yönetimi" alt başlığı ve turkuaz "YETKİLİ SERVİS" rozetinin görüntülendiğini doğrulayın.
- [ ] **10.3. Tümleşik 8 Saha Aracı:** Ekranda 8 saha aracının (Devreye Alma, Karekod ile Pano Eşle, Cihaz Envanteri & Seri No, Pano Değişimi, Wi-Fi Yapılandırma & Kurtarma, Sistem Doktoru, Acil Sıfırlama & Mülk Devri, Yetkili Servis Ağı) eksiksiz yer aldığını ve çalıştığını test edin.
- [ ] **10.4. 2 Sekmeli Servis Paneli:** "Tüm Paneli Aç" veya Sandviç Menüden "Servis Sorumluları" sayfasına giderek tabların yalnızca "Sorumlular" ve "Görevler & Araçlar" olarak 2 sekmeden oluştuğunu doğrulayın.

---

*Not: Her test adımını sırayla gerçekleştirdikten sonra ilgili kutucuğu `[x]` olarak işaretleyebilirsiniz.*
