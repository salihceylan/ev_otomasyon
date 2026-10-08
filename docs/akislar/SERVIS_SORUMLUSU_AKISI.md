# Servis Sorumlusu Akışı

> Kimin için: servis sorumlusu ve süper kullanıcı (ofis, atölye, saha, teslim). Kaynak: kodun kendisi, 2026-10-08
> (commit `c64a08a` sonrası). Ekrandaki düğme ve mesajlar tırnak içinde, koddaki gibi. Kullanıcı tarafı ayrı belgede:
> `DAIRE_KULLANICISI_AKISI.md`. Açık kalan konular en sonda (Bölüm 9).

---

## 0. Bu sürümde değişenler (2026-10-08)

1. **Pano bulut kimliğini kendisi alıyor.** Provizyonu yapılmış ve bir eve sahiplenilmiş pano internete çıkınca kimliğini
   sunucudan kendisi ister. Ev sahibi panoyu kendisi sahiplenirse servis sihirbazının 6. adımına gerek kalmaz.
2. **Yanlış kurulum PIN'inde** artık "Geçersiz kurulum PIN kodu. Kalan deneme hakkı: N" görünüyor ("yetkiniz yok" değil).
3. **Sihirbaz Ethernet'li panoyu tanıyor.** 5. adımda "Pano kabloyla (Ethernet) bağlı" seçeneği var; teslimde ağ satırı
   "Pano ev ağına Ethernet ile bağlı (IP x)".
4. **Ethernet'li panoda kurulum ağı artık açılıp kapanmıyor** (provizyonlu panoda kablo bağlıyken kurulum ağı kapalı kalır).
5. **Telefona alarm bildirimi (Android, Firebase'siz):** ev sahibi/üye ayarlarda "Arka planda alarm bildirimi"ni açarsa
   uygulama kapalıyken de alarm bildirimi alır (iOS'ta yok). Teslimde müşteriye gösterin; siren önerisi sürüyor.
6. **Sihirbaz 6. adım:** pano kimliğini kendisi aldıysa ve çevrimiçiyse sihirbaz kimliğe dokunmadan adımı tamamlar.

---

## 1. Roller ve yetkiler

| İş | Süper kullanıcı | Servis sorumlusu | Geçici servis (PIN) |
|---|---|---|---|
| Servis yazılımına giriş | Evet | Evet | Hayır |
| Kartı envantere kaydetme, askıya alma, silme | Evet | Hayır | Hayır |
| Site, daire, şablon ekleme/düzenleme/silme | Evet | Evet | Hayır |
| Şablonu karta yazma, PDF üretme | Evet | Evet | Hayır |
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
3. Servis sorumlusuysanız envanter kayıt/askı/silme düğmeleri pasiftir (not çıkar).

### 2.2 Site ve daireler (4. sekme)
1. "🔄 Siteleri Yenile" → "➕ Site Ekle": "Site adı *", adres, il, ilçe, sorumlu adı, sorumlu telefonu, e-posta, blok sayısı,
   daire sayısı, not.
2. Siteyi seçin → "🧱 Toplu Daire Üret": blok (A), ilk–son daire no, isteğe bağlı daire tipi ve şablon (en çok 500;
   var olan blok+no atlanır). Her blok için tekrarlayın.
3. Daire seçip "📐 Şablon Ata", "🔗 Kart Bağla" (yalnız **stoktaki** kart; bir kart tek daireye).
4. "İlerleme" sütunu: Planlandı → Yazıldı (şablon karta yazılınca) → Kuruldu (kart bir müşteriye sahiplenilince) →
   Teslim edildi (bkz. Bölüm 9, madde 6).

### 2.3 Şablon (5. sekme)
1. "Site:" seçin (ya da "Genel (standart şablonlar)") → "➕ Yeni Şablon" ya da "📑 Çoğalt".
2. Üst satır: ad, daire tipi, "Ek modül (RS485) var" + kanal + adres → **"↔ Kanalları Uygula"ya mutlaka basın**.
3. "⚡ Röle Çıkışları": ad, oda, tip ("Lamba/Priz", "Panjur (çift)" — tek numaralı röle Yukarı, sonraki Aşağı, aynı süre;
   "Darbe" — ms), bağlanacak yük. Lamba satırında "💡" → "Parlaklık ayarı yapılacak mı?" → dimmer kaynağı/adres/kanal ve
   yerleşim yönergesi.
4. "🔘 Girişler (DI)": hedef röle, kip (hepsi **yaylı buton**; kalıcı duvar anahtarı desteklenmez), kablolama notu,
   güvenlik rolü (su, gaz, duman, kapı, pencere, hareket, alarm susturma, vana kapatma, gaz vanası sıfırlama, anahtarlı
   kontak), NO/NC (gaz/duman/anahtarlı kontak her zaman NC), bölge.
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
1. Port seçin → "⚡ FİRMWARE'İ KARTA YÜKLE (FLASH)". **Ethernet, şablon ve kendi kendine bulut bağlantısı için v1.3.0
   gerekir**; servis yazılımında "güncel" sürüm hâlâ v1.2.1 seçili (bkz. Bölüm 9, madde 3).
2. Yükleme bitince kayıt bekliyorsa provizyon **aynı USB'den otomatik** başlar.

### 3.3 Provizyon (3. sekme)
1. Otomatik olmadıysa "🔌 Seri (USB) ile Provizyonla (Önerilen)". Kartta eski anahtar varsa "Kartta Eski Anahtar Var"
   sorusu (Evet → `RESETKEY` + yeniden).
2. Ethernet'le: "🌐 Ethernet ile Provizyonla" → kartın Ethernet IP'si.
3. Wi-Fi yedek yolu: "📶 Wi-Fi ile Provizyonla (güvensiz yedek yol)" → "✅ Wi-Fi ile Doğrula".
4. **Önemli:** pano bulut kimliğini kendisi alabilmek için **provizyonlu** olmalı. Ethernet'te provizyonsuz da şablon yazılır,
   ama provizyonsuz pano buluta kendiliğinden bağlanamaz.

### 3.4 Şablonu karta yazma
1. 4. sekmede daireyi (ya da 5. sekmede şablonu) seçin → "💾 Karta Yaz".
2. **USB:** port seçin; daireye bağlı kart varsa takılı kartın o kart olduğu MAC'ten denetlenir (değilse hiçbir şey yazılmaz).
3. **Ethernet:** kartın **Ethernet** IP'si + UID. Anahtar gerekmez; **IP–kart eşleşmesi denetlenmez**, IP'yi doğru girin.
   Wi-Fi IP'si girerseniz kart anahtar ister ve yazım reddedilir.
4. Başarıda daire **Yazıldı** olur, kart daireye bağlı değilse bağlama sorulur, "Kablolama şeması (PDF) şimdi kaydedilsin
   mi?" sorulur. Bellekteki kart bu kartsa etikete daire satırı eklenir; etiketi yeniden yazdırın.

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

### 5.2 Genel kurallar
1. 10 adım; "Devam" yalnız adım gerçek pano/sunucu yanıtıyla doğrulanınca açılır; ileri atlanmaz.
2. İlerleme telefonda saklanır (anahtar, PIN, kod, bulut kimliği, Wi-Fi şifresi saklanmaz).
3. PIN oturumunda 3-4. adım atlanır, şablon kartı görünmez. Mevcut cihaz kipinde 2-4. adım atlanır.

### 5.3 Adımlar
1. **Hazırlık:** "Bağlantıyı Doğrula" (oturum + sunucu).
2. **Cihazı Tanı:** "Etiketi Tara (Karekod)" ya da seri no + PIN → stok durumu denetlenir. (PIN oturumunda dairedeki pano seçilir.)
3. **Müşteri:** müşterinin e-postası/telefonu → "Kod Gönder" → müşteriye 6 haneli kod (15 dk) → kodu yazın.
4. **Daireye Bağla:** özet → "Daireye Bağla" → onay. Sunucu evi açar/seçer (site dairesiyse ad "<site> <blok>-<no>",
   kanallar şablondan), müşteri hesabı yoksa açar ve davet gönderir, size 72 saat yetki verir. Yanlış PIN'de
   "Kurulum PIN'i hatalı" + kalan hak → 2. adıma döner.
5. **Ağ (Wi-Fi ya da Ethernet):**
   1. **Wi-Fi:** telefonu kurulum ağına (`AHBU-XXXXXX`, etiketin 2. karekodu) bağlayın → "Bağlandım: Panoyu Kontrol Et" →
      (provizyonsuzsa "Panoyu Hazırla") → "Ağları Tara" / elle (2,4 GHz) → "Yeni Wi-Fi Şifresini Panoya Yükle" → telefonu
      ev Wi-Fi'sine geri alın.
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
   3. "Bu kanala ne bağlı?" (lamba + parlaklık sorusu / vana / siren / fan / diğer), "Girişler ve Sensörler".
   4. "Güvenlik Ayarlarını Panoya Yaz ve Test Et" → bölge testi (vana kapanmalı; gaz vanası kapalı kalır).
8. **Panjur Testi:** yön ("Panjur gerçekten YUKARI mı gitti?") → "Ölçüme Hazırla" → "Alta İndir" → "Ölçümü Başlat" →
   "Bitti" → "Kaydet ve Panoda Doğrula" (süre buluttan yazılır; pano çevrimiçi olmalı).
9. **Duvar Butonları:** "Dinlemeyi Başlat" → her butona basın → "Algılandı" ya da "Bu girişte buton yok".
10. **Teslim:** kontrol listesi (ağ satırı Wi-Fi ya da Ethernet), not, teslim alan, "Müşteriye kurulumu gösterdim…" →
    "Devreye Almayı Tamamla" → kurulum raporu ("Raporu Kopyala / Paylaş"). Ekrandaki not Android müşteriye
    "Arka planda alarm bildirimi" ayarını hatırlatır; siren önerisi kalır.

---

## 6. Diğer servis işleri

### 6.1 Pano değişimi
1. Seçili evde: eski pano → yeni panonun etiketi + PIN + neden → "Pano değişimi onayı".
2. Kanallar, adlar, panjur süreleri aktarılır; "Yeni Panoyu Şimdi Bağla" → sihirbaz 5. adım.

### 6.2 Acil sıfırlama
1. Cihaz kimliği + en az 15 karakter gerekçe + isteğe bağlı yeni sahip; UID yazılarak onay.
2. Eski ailenin yetkileri biter; cihaz stoğa ya da yeni sahibe geçer. Yeni kurulum PIN'i bir kez gösterilir.

### 6.3 Abone ve hesap yönetimi
"Servis Yönetimi" (hesap/müşteri ekle, dondur, davet), "Abonelerim & Cihaz Atama" ("Home Admin Ata" / "Yöneticiyi Devret").

### 6.4 Wi-Fi değişikliği (modem/şifre değişince)
"Wi-Fi Kurulum & Kurtarma Sihirbazı": kurulum ağına bağlan → yeni ağ bilgisini yükle. Giriş/internet gerekmez.

---

## 7. Pano neyi kendisi yapar (bilmeniz gerekenler)
1. İnternetsiz: lambalar, panjurlar, butonlar, su/gaz alarmı, vanalar çalışır.
2. Kurulum ağı: kayıtlı Wi-Fi yoksa açılır; Wi-Fi koparsa 10 dk açılır (en çok 30), kapanınca Wi-Fi hâlâ yoksa 15 dk sonra
   yeniden. **Provizyonlu ve Ethernet'i bağlı panoda açılmaz.**
3. Bulut kimliği: provizyonlu + ağı var + saati doğru + kimliği yok (ya da sunucu 3 kez reddetti) ise sunucudan kendisi
   ister. Sahiplenilmemişse 10 dk sonra yeniden dener.
4. Ethernet'ten gelen yerel istekler anahtarsız tam yetkili; Wi-Fi'den gelenler anahtarlı.
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
| "Kart meşgul" / "Panoda alarm sürüyor" / "Hırsız alarmı kurulu" | Kart yazmaya uygun değil | Bekleyin / alarmı çözün |

---

## 9. Açık kalan konular

> 2026-10-08 akşamı mantık denetiminden sonra güncellendi (92 bulgu, 89'u düzeltildi; ayrıntı
> `docs/denetim/2026-10-08-mantik-denetimi.md`). Önceki listeden kapananlar: servis yazılımında seçili sürüm artık v1.3.1
> (kartta denendi); eskimiş ekran/rehber metinleri (atolye-16); daire "Teslim edildi" geçişi (servis_kurulum-10); "Kanalları
> Uygula"ya basmadan kaydetme (atolye-9); Ethernet'te ilk hazırlık ve yeniden deneme artık panonun kablolu adresine gidiyor
> (servis_kurulum-1); girişsiz karta yazımda kaydın kaybolması artık uyarılıyor (atolye-11).

1. **Uzaktan güncelleme yok:** her firmware değişikliği için kart USB'ye takılmalı.
2. **Provizyonsuz pano buluta kendiliğinden bağlanamaz** (kimlik isteğini imzalayacak anahtarı yok). Ethernet'te de sihirbaz
   önce ilk hazırlığı ister (pano v1.3.1'de gerçek `provisioned` değerini bildirir).
3. **Ethernet yazımında kart kimliği denetlenmiyor** (kararınız; yanlış IP başka karta yazar).
4. **Telefon alarm bildirimi** yalnız Android'de ve cihazda henüz denenmedi; iOS'ta yok.
5. **Ethernet kablosu ve panonun kendi bulut kimliği (bootstrap)** gerçek kablo ve sunucuyla henüz denenmedi.
6. **Kararınızı bekleyen maddeler** (raporda "Karar gerektiren maddeler"; uygulanmadı):
   - **guvenlik-14:** Ethernet'teki anahtarsız erişim, gaz vanası ve hırsız alarmı kurallarını deliyor (Ethernet'ten güvenlik
     yapılandırması yazılabiliyor, alarm anahtarsız çözülebiliyor). Öneri: gaz vanası yalnız gerçek seri konsoldan açılsın,
     alarm Ethernet'te de anahtar istesin; Ethernet kolaylığı korunur.
   - **kayit-dogrulama:** kayıtta e-posta/telefon doğrulaması zorunlu değil. Doğrulanmamış hesaba servis kurulumunda/atamada
     güvenlik için parola sıfırlaması gider. Öneri: sonraki sürümde "bekleyen kayıt" modeli (hesap kod girilince açılır).
   - **bireysel-9-yayin:** etiket karekodunun telefonda doğrudan uygulamayı açması için Android/iOS bağlantı doğrulama
     dosyaları gerekiyor (imza sertifikası parmak izi, uygulama kimliği, Apple Team ID). Bilgiler gelince eklenir.
