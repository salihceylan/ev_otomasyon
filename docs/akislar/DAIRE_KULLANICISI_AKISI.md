# Daire Kullanıcısı Akışı

> Kimin için: ev sahibi, ev üyesi (aile), misafir ve panoyu kendisi kuran bireysel kullanıcı. Kaynak: kodun kendisi,
> 2026-10-08 (commit `c64a08a` sonrası). Ekrandaki düğme ve mesajlar tırnak içinde, koddaki gibi. Servis tarafı ayrı
> belgede: `SERVIS_SORUMLUSU_AKISI.md`. Açık kalan konular en sonda (Bölüm 10).

---

## 0. Bu sürümde değişenler (2026-10-08)

1. **Panoyu kendiniz sahiplenince pano buluta kendiliğinden bağlanıyor.** Pano internete bağlıysa birkaç dakika içinde
   bulut kimliğini sunucudan kendisi alır; servis çağırmanız gerekmez.
2. **Yanlış kurulum PIN'inde** artık "Geçersiz kurulum PIN kodu. Kalan deneme hakkı: N" görünüyor.
3. **Telefona alarm bildirimi (yalnız Android, isteğe bağlı):** ayarlarda "Arka planda alarm bildirimi"; bkz. Bölüm 7.6.

---

## 1. Kim ne yapabilir

| İş | Ev sahibi | Ev üyesi | Misafir |
|---|---|---|---|
| Işık, panjur, darbe çıkışı | Evet | Evet | Evet |
| Vanayı kapatma | Evet | Evet | Evet |
| Vanayı açma (gaz hariç) | Evet | Evet | Hayır |
| Gaz vanasını açma | Hayır (yalnız panonun yanındaki "gaz sıfırlama" girişiyle) | Hayır | Hayır |
| Alarmı onaylama | Evet | Evet | Hayır |
| Hırsız alarmını kurma/çözme | Evet | Evet | Hayır |
| Hızlı senaryolar, zamanlı kurallar | Evet | Evet | Hayır |
| Çocuk kilidi | Evet | Evet | Hayır |
| Aile/misafir davet etme, devir, servis PIN'i | Evet | Hayır | Hayır |
| Panoyu sahiplenme | Evet (evi olmayan kullanıcı da) | Evet | Hayır |
| Alarm bildirimi | Evet | Evet | Hayır |

Misafir erişimi en çok 72 saattir; süre bitince "Erişiminiz sona erdi" görünür.

---

## 2. Hesap

### 2.1 Kayıt
1. Giriş ekranında "Hesabınız yok mu? Kayıt Olun".
2. "Ad Soyad", "E-Posta Adresi", "Telefon" (isteğe bağlı), "Şifre" (en az 10 karakter), "Şifre Tekrar" → "Kayıt Ol ve Giriş Yap".
3. Hesap **hemen açılır**; e-posta doğrulaması yoktur.
4. Servis sizin adınıza panoyu bağladıysa hesabınız "davet bekliyor" olarak açılır; e-postadaki bağlantıyla 72 saat içinde
   şifrenizi belirleyip etkinleştirirsiniz.

### 2.2 Giriş
1. E-posta + şifre → "Giriş Yap". Ayrıca "Google ile Devam Et", "Apple ile Giriş Yap" (iOS), SMS ile şifresiz giriş (açıksa),
   "E-postadaki Bağlantım Var".
2. Oturum 30 gün sürer. Çok hatalı denemede geçici kilit ("Tekrar dene (mm:ss)").
3. İlk girişten sonra parmak izi/yüz tanıma sorulur. Açıksa uygulama açılışta ve 30 sn'den uzun arka planda kaldıktan
   sonra kilitlenir.

### 2.3 Şifre ve hesap
1. "Şifremi Unuttum" → e-posta/telefon → 6 haneli kod (15 dk) → yeni şifre. Diğer cihazlardaki oturumlar kapanır.
2. Profil penceresi: "Oturumu Kapat", "Tüm Cihazlardan Çıkış Yap", "Şifreyi Değiştir", "Hesabımı Sil" ("SİL" yazılır; başka
   üyesi olan evin tek sahibiyseniz önce devretmeniz istenir).

---

## 3. Pano kurulumu: servis kurduysa
1. Servis sorumlusu panoyu sizin e-postanıza bağlarken size 6 haneli bir kod gelir; kodu servis sorumlusuna söylersiniz.
2. Hesabınız yoksa açılır ve etkinleştirme e-postası gelir.
3. Servis kurulumu bitirip teslim ettiğinde uygulamada evinizi hazır bulursunuz (site dairesiyse ev adı ör. "Güneş Sitesi A-12").

---

## 4. Pano kurulumu: kendiniz kuruyorsanız (bireysel kullanıcı)

### 4.1 Panoyu ev ağına bağlama
1. Pano kabloyla (Ethernet) modeme bağlıysa bu adımı atlayın.
2. Wi-Fi ile bağlanacaksa: giriş ekranında "Pano Wi-Fi Kurulumu (İnternet Gerekmez)" ya da ayarlarda
   "Wi-Fi Şifre Değişimi & Kurtarma".
3. Telefonu panonun kurulum ağına bağlayın: etiketin **2. karekodunu telefon kamerasıyla** okutun (ağ adı `AHBU-XXXXXX`,
   parola etikette "AĞ PAROLASI (AP)"). Telefon "internet yok" derse "Yine de bağlı kal".
4. "Bağlantıyı Test Et" → "Ağları Tara" (yalnız 2,4 GHz) ya da "Modem Wi-Fi Karekodu Tara (Kamera)" ya da elle →
   "Yeni Wi-Fi Şifresini Panoya Yükle".
5. "Pano ev Wi-Fi ağına bağlandı!" → telefonu ev ağına geri alın.
6. Pano hiç hazırlanmamışsa (provizyonsuz) bu yol çalışmaz: "Pano henüz hazırlanmamış (ilk kurulum yapılmamış)… servis
   kurulum sihirbazını kullanın."

### 4.2 Panoyu sahiplenme
1. Evi olmayan kullanıcı: "Hoş Geldiniz, <ad>!" ekranında "Karekod Tara (Katıl / Cihaz Eşle)" ya da "Cihaz Kodunu Elle Gir".
2. Etiketin **1. karekodu** ("Daireye bağla") taranır ya da seri no (`AHBU-S3-…`) + 6 haneli "Kurulum PIN Kodu" yazılır;
   "Ev / Daire Adı" (varsayılan "Evim") → "Eşle & Sahiplen".
3. "Cihaz başarıyla evinize eşleştirildi." ve bilgi: "Pano internete bağlı olduğunda birkaç dakika içinde kendiliğinden
   buluta bağlanır. Pano henüz ev ağına bağlı değilse 'Pano Wi-Fi Kurulumu' ile bağlayın."
4. Pano buluta bağlanınca cihaz listesi panonun gerçek düzenine göre (adlar, panjurlar) kendiliğinden güncellenir.
5. Hatalar: yanlış PIN → "Geçersiz kurulum PIN kodu. Kalan deneme hakkı: N" (5 yanlışta 15 dk kilit); pano başka evdeyse
   "Bu cihaz zaten bir daireye bağlı veya işlem çakıştı…".
6. Etiketteki karekodu uygulama dışında açarsanız (bağlantı), giriş yapılıysa eşleştirme penceresi doğrudan açılır.

### 4.3 Kendi kurduğunuz panoda eksik kalanlar
1. Kanal/oda adlarını uygulamadan değiştiremezsiniz (servis sihirbazında yapılır); adlar panodan gelir.
2. Panjur süresi kalibrasyonu, güvenlik cihazı (vana/siren) tanımlama ve devreye alma testleri servis sihirbazındadır.
   Ev sahibi olarak servise "Yetkili Servis İçin Geçici PIN" verebilirsiniz (Bölüm 8.5).

---

## 5. Günlük kullanım

### 5.1 Ana ekran
1. Sırasıyla: çevrimdışı uyarısı → güvenlik uyarıları → sayaçlar ("Açık lamba", "Hareketli panjur") → gece huzur bandı →
   "Hızlı Senaryolar" → oda filtreleri → "Panjurlar", "Aydınlatma & Çıkışlar", "Duvar Butonları & Girişler",
   "Güvenlik ve Eylemciler".
2. Lamba: "AÇIK"/"KAPALI"; darbe çıkışı "Tetikle"; panjur "Aç"/"Durdur"/"Kapat" ve yüzde kaydırıcı.
3. Komut panodan onay gelmezse (en çok 10 sn) "Cihazdan onay alınamadı. İşlem geri alındı…".
4. Gaz alarmı sürerken her anahtarlamada "Elektrik anahtarlamak kıvılcım oluşturabilir. Yine de uygulansın mı?"

### 5.2 Hızlı senaryolar (misafire görünmez)
"Evden Çıkıyorum" (lambalar kapanır, panjurlar iner, alarm kurulsun mu diye sorar), "Günaydın", "İyi Geceler",
"Tüm Lambalar", "Panjurları Durdur". Başka senaryo/otomasyon yok.

### 5.3 Zamanlı kurallar
"Zamanlı Kurallar" (bulut modu gerekir): kanal, "Aç"/"Kapat"/"Tetikle", saat, günler. Çakışmada uyarı.

### 5.4 Çocuk kilidi
"Çocuk Kilidi": duvar butonları çalışmaz (hareketli panjuru durdurmak hariç). Kilitlemek tek dokunuş; kaldırmak parmak izi
ya da basılı tutma ister.

### 5.5 Bulut modu ve yerel mod
1. Mod elle seçilir ("Bulut Modu (yerel moda geç)" / "Yerel Ağ Modu (buluta geç)"); uygulama kendiliğinden geçmez.
2. Bulut modu: her yerden kontrol. Yerel mod: panoya ev ağından doğrudan; panonun IP'si elle girilir.
3. Misafir mod değiştiremez.

### 5.6 Gece huzur bildirimi
Ayarlarda "Gece Huzur Bildirimi" saati (varsayılan 23:30): o saatte açık lamba/panjur varsa uygulamada "Gece hatırlatması"
bandı çıkar ("Hepsini kapat" / "Gizle").

---

## 6. Wi-Fi değişince (modem ya da şifre)
"Wi-Fi Şifre Değişimi & Kurtarma": telefonu kurulum ağına bağlayın (pano ev Wi-Fi'sini 3 dk kaybedince kurulum ağını 10 dk
açar) → yeni ağ bilgisini yükleyin. Giriş ve internet gerekmez. Pano kabloyla bağlıysa gerekmez.

---

## 7. Güvenlik

### 7.1 Su/gaz/duman alarmı
1. Alarm kartı: "Su baskını: <sensör>" vb.; etiketler "ALARM" / "SUSTURULDU" / "VANA ARIZASI".
2. Islakken "Sesi Sustur" (siren ve pano zili susar, vana kapalı kalır). Kuruyunca "Alarmı Onayla" (alarm kalkar,
   vana güvenlik için kapalı kalır).
3. Gaz/duman için yönerge (havalandırın, 187 / 112'yi arayın).

### 7.2 Vanalar
1. "Vanayı Kapat" herkes için her zaman.
2. "Vanayı Aç" yalnız bölge normal ve sensörler kuru iken.
3. **Gaz vanası uygulamadan açılamaz:** "Gaz vanası güvenlik gereği yalnız yerinde açılır: vananın yanındaki düğme ya da
   vananın kurma kolu."

### 7.3 Hırsız alarmı
1. "Kapalı" / "Evde" / "Dışarıda" → "Alarmı Kur" / "Alarmı Çöz".
2. Açık sensör varsa "Kurulamaz: <sensör> açık."
3. Çıkış gecikmesi 45 sn, giriş gecikmesi 30 sn ("Giriş gecikmesi: N sn içinde alarmı çözün.").
4. Yalnız ev sahibi ve ev üyesi kurup çözebilir.

### 7.4 İnternet yokken
Pano alarmı, vanayı ve sireni internetsiz yönetir; bulut yalnız kayıt ve uzaktan erişim içindir.

### 7.5 Misafir
Işık/panjur kullanır, vana kapatır; alarm onaylayamaz, vana açamaz, alarm kuramaz, alarm bildirimi almaz.

### 7.6 Telefona alarm bildirimi
1. **Android:** "Cihaz & Sistem Ayarları" → Güvenlik → **"Arka planda alarm bildirimi"** (varsayılan kapalı; yalnız ev
   sahibi ve ev üyesi görür).
   1. Açınca bildirim izni ve pil kısıtlamasını kaldırma istenir. Kart şunu söyler: "Uygulama kapalıyken de su baskını, gaz,
      duman, hırsız alarmı ve vana arızası telefonunuza bildirilir. Açıkken durum çubuğunda kalıcı bir bildirim simgesi
      durur ve telefon biraz daha fazla pil kullanır."
   2. Uygulama arka planda her eviniz için bulut bağlantısını açık tutar; uygulamayı kaydırıp kapatsanız ve telefon yeniden
      başlasa da sürer.
   3. Bildirimler "Güvenlik alarmları" kanalından sesli ve titreşimli gelir, ör. "Su baskını: Mutfak Su — Evim",
      "Vana kapanmadı (arıza) — Evim", "Pano güvenli kipe girdi — Evim". Dokununca uygulama o evde açılır. Alarm kalkınca
      bildirim kendiliğinden silinir; aynı alarm iki kez çalmaz.
   4. Çıkış yaparsanız ya da hesabınızda ev sahibi/üye olduğunuz ev kalmazsa takip durur.
   5. Bazı markalar (Xiaomi, Huawei, Oppo) arka plandaki uygulamayı yine de kapatabilir; telefonun pil ayarlarında uygulamayı
      "kısıtlama yok" yapın. "Rahatsız Etme" kipini aşmaz.
2. **iOS:** bu sürümde telefona bildirim yok ("Bu özellik yalnız Android'de"); uyarılar uygulama açılınca görünür.
   Siren takılması önerilir.
3. Gece huzur hatırlatması telefona gönderilmez; uygulama açılınca bant olarak görünür.

---

## 8. Aile ve paylaşım (ev sahibi)

### 8.1 Davet
"Erişim Paylaş & Davet Et": aile üyesi kodu (24 saat, tek kullanım) ya da süreli misafir kodu (2/4/8/24/48/72 saat).
Evde en çok 20 açık davet.

### 8.2 Katılma (davet edilen)
"Kod ile Bir Eve Katıl" → "Davet / Devir Kodu" → "Devam" (önizleme) → "Eve Katıl".

### 8.3 Üyeler
"Aile & Misafir Yönetimi" → "Yetkiyi İptal Et". Son sahip kaldırılamaz.

### 8.4 Ev devri
Sahip "48 Saatlik Devir Kodu & QR Üret" → yeni sahip kodu girip "DEVRAL" yazar → "Daireyi Devral". Eski sahip dahil tüm
üyeler erişimini kaybeder. "Devir İşlemini İptal Et" ile vazgeçilebilir.

### 8.5 Servise geçici erişim
"Yetkili Servis İçin Geçici PIN" → "6 Haneli Servis PIN'i Üret" (bir kez gösterilir, 2 saat, tek kullanım, yalnız bu ev).
Açık servis oturumları listelenir; "Servis erişimini kapat" hepsini sonlandırır.

---

## 9. Ayarlar
1. "Cihaz & Sistem Ayarları": Güvenlik (çocuk kilidi, parmak izi, servis PIN'i), Görünüm (koyu/açık/sistem), Cihaz
   ("Sistem Doktoru", Wi-Fi kurtarma, "Pano Değişimi", IP/anahtar, telemetri), Otomasyon (gece bildirimi, zamanlı kurallar),
   Aile.
2. "Sistem Doktoru" (misafir hariç): bulut bağlantısı, ev modemi/internet, pano gücü ve donanımı denetler.

---

## 10. Açık kalan konular (onayınızla düzeltilecek)

1. **Yerel moda ilk kez geçiş:** giriş yapılmamış ve anahtarı olmayan telefonda IP/anahtar alanı görünmeyebilir
   (incelemede bulundu, elle denenmedi).
2. **Kanal ve oda adlarını kullanıcı değiştiremiyor;** yalnız servis sihirbazında.
3. **Provizyonsuz pano buluta kendiliğinden bağlanamaz;** pano atölyede provizyon görmediyse servis gerekir.
4. **Pano modeme kabloyla bağlıysa** evin ağındaki herkes panoya anahtarsız erişebilir (kararınız; bilgi için).
5. **Gece hatırlatması ve alarm, iOS'ta** yalnız uygulama açılınca görünür.
6. **Uygulama içi güvenlik olay listesi "alarm kalktı" olayını üretmiyor olabilir** (pano normal bölgeleri durumda
   göndermiyor; arka plan bildirimi bunu ayrıca çözüyor). İncelemede bulundu, elle denenmedi.
7. **Arka plan bildirimi cihazda denenmedi:** servisin başlaması, kaydırıp kapatınca sürmesi, yeniden başlatmada açılması,
   pil davranışı ve bildirim sesi ancak telefonda doğrulanır.
