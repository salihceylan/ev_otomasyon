# Daire Kullanıcısı Akışı

> Kimin için: ev sahibi, ev üyesi (aile), misafir ve panoyu kendisi kuran bireysel kullanıcı. Kaynak: kodun kendisi,
> 2026-10-09 (commit `8912b20` ve 2026-10-09 gece düzeltmeleri sonrası). Ekrandaki düğme ve mesajlar tırnak içinde, koddaki gibi.
> Servis tarafı ayrı belgede: `SERVIS_SORUMLUSU_AKISI.md`. Açık kalan konular en sonda (Bölüm 10).

---

## 0. Bu sürümde değişenler (2026-10-09)

**Sahip kararlarıyla gelenler (2026-10-09 öğleden sonra; ayrıntı `docs/denetim/2026-10-09-kararlar.md`):**

1. **"Evden Ayrıl":** aile üyesi ve misafir evden kendisi ayrılabilir (Bölüm 8.3). Ev sahibi ayrılamaz; önce evi devreder.
2. **Telefon numarası tek biçimde:** telefon alanlarında "+90 " hazır gelir; numarayı 5 ile başlayarak yazarsınız (5XX XXX XX XX).
   "0555…", "+90555…" ve "555…" artık aynı numara sayılır; kayıtlı numaralar da bu biçime çevrildi (Bölüm 2.1).
3. **Kayıtta e-posta iki kez yazılır** ("E-posta (tekrar)"); iki yazım farklıysa "E-posta adresleri eşleşmiyor" görünür. E-posta
   doğrulaması yine yoktur (Bölüm 2.1).
4. **Devirden sonra alarm geçmişi:** yeni sahip yalnız kendi dönemindeki alarmları ve hâlâ açık alarmları görür (Bölüm 8.4).
5. **Güvenlik ayarlı evde (su/gaz sensörü ya da vana) pano değişimini yalnız yetkili servis yapar;** ev sahibi denerse "Bu evde pano
   değişimini yetkili servis personeli yapmalıdır." görünür. Servis PIN'i üretip servise verin (Bölüm 8.5).
6. **Kablolu (Ethernet) panoya anahtarsız erişim:** pano modeme kabloyla bağlıysa yerel modda uygulama panoyu yerel anahtar sormadan
   yönetir (kararınız; Bölüm 5.5).
7. **Erişimi biten kişinin pano bağlantısı kesilir:** üye çıkarılınca ya da ayrılınca, devir kabul edilince ve her servis oturumu
   bitince panonun bulut kimliği yenilenir; erişimi biten kişi eski kimlikle buluta bağlanamaz (Bölüm 8.3).
8. **Firmware v1.3.2 (karta yazılınca geçerli):** pano yalnız kendi bulut sunucusuna bağlanır; fabrika ayarında rölelere sabit görev
   yoktur (8 rölenin hepsi "Röle N" adlı lamba, 1-8. girişler aynı numaralı röleyi açıp kapatır). Yeni açılan evin varsayılan kanal
   listesi de böyledir; panjur yalnız servis şablonunda seçilirse yanındaki röleyle çift olur.

**Aynı gün sabah gelenler:**

1. **Yasal metinler:** kayıtta "Kullanıcı Sözleşmesi'ni okudum ve kabul ediyorum." kutusu zorunlu; sözleşme kesinleşince (bugün
   taslak) güncel sürümü onaylamayan hesaba onay ekranı çıkar; metinler "Cihaz & Sistem Ayarları" → "Hakkında" → "Yasal Metinler"de
   (Bölüm 2.1, 2.2, 9).
2. **Pano değişiminden sonra güvenlik ayarları:** su/gaz sensörü ya da vanası olan evde panoyu değiştirince uygulama "Güvenlik
   ayarları (su/gaz sensörü, vana) yeni panoya aktarılmadı. Yetkili servisi çağırın." der; servis ayarları yeniden yazana kadar su/gaz
   koruması çalışmaz (Bölüm 9).
3. **Misafir erişimi sunucu saatine göre açılıp kapanır:** telefonun saati yanlış olsa da erişim doğru zamanda başlar ve biter;
   başlangıç saati gelince uygulama kendiliğinden canlı bağlanır, süre uzatılınca da yeniden bağlanır.
4. **Davet ya da devir kodunu yeniden girmek güvenli:** bağlantı koptuysa ve kodu tekrar denerseniz "Bu davet kodunu zaten
   kullandınız; dairenin üyesisiniz." / "… dairesinin sahipliği zaten size devredildi." görünür ve ev listenize gelir (Bölüm 8.2, 8.4).
5. **Telefonla (SMS) giriş yalnız doğrulanmış telefona açılır** (Bölüm 2.2).
6. **İnternet dönünce cihaz listesi kendiliğinden yeniden yüklenir;** açık alarm varsa alarm kartı liste yüklenemese de görünür.
7. **Arka planda alarm bildirimi telefon yeniden başlarken kapanmaz** (güvenli depo geç okunsa da ayar korunur).
8. **Sözleşme ya da zorunlu şifre ekranı açıkken** bildirime dokunma ve etiket bağlantısı bekletilir; ekran geçilince açılır.

**2026-10-08 sürümünde gelenler (geçerli):** panoyu kendiniz sahiplenince pano buluta kendiliğinden bağlanıyor (Bölüm 4.2); yanlış
kurulum PIN'inde "Geçersiz kurulum PIN kodu. Kalan deneme hakkı: N"; Android'de isteğe bağlı "Arka planda alarm bildirimi" (Bölüm 7.6).

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

Misafir erişimi en çok 72 saattir; süre bitince "Erişiminiz sona erdi" görünür. Başlangıç ve bitiş sunucunun saatine göredir
(telefonun saati ileri ya da geri olsa da değişmez).

---

## 2. Hesap

### 2.1 Kayıt
1. Giriş ekranında "Hesabınız yok mu? Kayıt Olun".
2. "Ad Soyad", "E-Posta Adresi", "E-posta (tekrar)", "Telefon" (isteğe bağlı; "+90 " hazır gelir, 5XX XXX XX XX),
   "Şifre" (en az 10 karakter), "Şifre Tekrar". İki e-posta farklıysa "E-posta adresleri eşleşmiyor".
3. "Kullanıcı Sözleşmesi'ni okudum ve kabul ediyorum." kutusunu işaretleyin ("Kullanıcı Sözleşmesi" bağlantısı metni açar). Kutu
   işaretlenmeden "Kayıt Ol ve Giriş Yap" pasiftir; sözleşme yüklenemezse "Tekrar Dene". Altındaki "Kişisel verileriniz Gizlilik
   Politikası ve KVKK Aydınlatma Metni kapsamında işlenir." satırı yalnız bilgilendirmedir.
4. "Kayıt Ol ve Giriş Yap": hesap **hemen açılır**; e-posta doğrulaması yoktur. Kayıtta yazılan telefon doğrulanmamış sayılır.
5. Servis sizin adınıza panoyu bağladıysa hesabınız "davet bekliyor" olarak açılır; e-postadaki bağlantıyla 72 saat içinde
   şifrenizi belirleyip etkinleştirirsiniz.

### 2.2 Giriş
1. E-posta + şifre → "Giriş Yap". Ayrıca "Google ile Devam Et", "Apple ile Giriş Yap" (iOS), SMS ile şifresiz giriş (açıksa),
   "E-postadaki Bağlantım Var". Ekranın altındaki "Kullanıcı Sözleşmesi" · "Gizlilik ve KVKK" bağlantıları metinleri girişsiz açar.
2. SMS ile giriş yalnız SMS koduyla doğrulanmış telefona açılır. Telefonunuz kayıtta ya da servis tarafından yazıldıysa (doğrulanmamış)
   "Bu telefon numarası doğrulanmamış bir hesapta kayıtlı. E-posta adresiniz ve şifrenizle giriş yapın." görünür.
3. Oturum 30 gün sürer. Çok hatalı denemede geçici kilit ("Tekrar dene (mm:ss)").
4. İlk girişten sonra parmak izi/yüz tanıma sorulur. Açıksa uygulama açılışta ve 30 sn'den uzun arka planda kaldıktan
   sonra kilitlenir.
5. Kullanıcı Sözleşmesi kesinleştiğinde (bugün taslak; onay ekranı çıkmaz) güncel sürümü onaylamamış hesapta, bulut modunda girişten
   sonra tam ekran "Kullanıcı Sözleşmesi" açılır: "Kabul Ediyorum" ya da "Çıkış Yap" (geri tuşu kapatmaz). Uygulama sözleşme
   durumunu açılışta, buluta geçişte ve öne gelince (son denetimden 12 saat geçtiyse) sunucudan yeniden alır. Yerel ağ modunda bu
   ekran çıkmaz.

### 2.3 Şifre ve hesap
1. "Şifremi Unuttum" → e-posta/telefon → 6 haneli kod (15 dk) → yeni şifre. Diğer cihazlardaki oturumlar kapanır.
2. Profil penceresi: "Oturumu Kapat", "Tüm Cihazlardan Çıkış Yap", "Şifreyi Değiştir", "Hesabımı Sil" ("SİL" yazılır; başka
   üyesi olan evin tek sahibiyseniz önce devretmeniz istenir); "Hakkında" → "Yasal Metinler".

---

## 3. Pano kurulumu: servis kurduysa
1. Servis sorumlusu panoyu sizin e-postanıza bağlarken size 6 haneli bir kod gelir; kodu servis sorumlusuna söylersiniz.
2. Uygulamaya yalnız telefonla (SMS) giriş yapıyorsanız hesabınızda e-posta olmadığı için kod gönderilemez; servis bunu ekranda
   görür. Panoyu kendi uygulamanızdan etiketteki karekodla sahiplenin (Bölüm 4.2), kurulum için servise geçici PIN verin (Bölüm 8.5).
3. Hesabınız yoksa açılır ve etkinleştirme e-postası gelir.
4. Servis kurulumu bitirip teslim ettiğinde uygulamada evinizi hazır bulursunuz (site dairesiyse ev adı ör. "Güneş Sitesi A-12").

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
6. Etiketteki karekodu uygulama dışında açarsanız (bağlantı), giriş yapılıysa eşleştirme penceresi doğrudan açılır. Sözleşme onayı
   ya da zorunlu şifre değişimi ekranı açıksa pencere bu ekran geçilince açılır.

### 4.3 Kendi kurduğunuz panoda eksik kalanlar
1. Kanal adı, oda, lamba/priz tipi ve panjur süresi "Cihaz & Sistem Ayarları" → "Kanallar ve Panjurlar" → "Kanalları Düzenle" ile
   değiştirilir (ev sahibi; aile üyesi değiştiremez). Panjurun adı ve odası çiftin iki rölesine birlikte yazılır.
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
5. Cihazlar yüklenemezse (internet yok) bağlantı dönünce liste kendiliğinden yeniden yüklenir; açık alarm varsa alarm kartı ve
   "Vanayı Kapat" bu durumda da görünür.

### 5.2 Hızlı senaryolar (misafire görünmez)
"Evden Çıkıyorum" (lambalar kapanır, panjurlar iner, alarm kurulsun mu diye sorar), "Günaydın", "İyi Geceler",
"Tüm Lambalar", "Panjurları Durdur". Başka senaryo/otomasyon yok.

### 5.3 Zamanlı kurallar
"Zamanlı Kurallar" (bulut modu gerekir): kanal, "Aç"/"Kapat"/"Tetikle", saat, günler. Çakışmada uyarı. Vana, siren ve fan gibi
güvenlik kanalları listede yoktur (kurala bağlanamaz).

### 5.4 Çocuk kilidi
"Çocuk Kilidi": duvar butonları çalışmaz (hareketli panjuru durdurmak hariç). Kilitlemek tek dokunuş; kaldırmak parmak izi
ya da basılı tutma ister.

### 5.5 Bulut modu ve yerel mod
1. Mod elle seçilir ("Bulut Modu (yerel moda geç)" / "Yerel Ağ Modu (buluta geç)"); uygulama kendiliğinden geçmez.
2. Bulut modu: her yerden kontrol. Yerel mod: panoya ev ağından doğrudan; panonun IP'si elle girilir.
3. Misafir mod değiştiremez.
4. Pano modeme kabloyla (Ethernet) bağlıysa yerel modda yerel anahtar sorulmaz: aynı ağdaki uygulama panoyu anahtarsız yönetir
   (kararınız). Pano Wi-Fi'den yanıt verirse ya da anahtar isterse uygulama yeniden anahtar ister.

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
4. Pano çevrimdışıyken verilen onay pano bağlanınca iletilir; ancak 24 saatten eskiyse ya da onayı veren kişinin (ör. servis
   oturumunun) yetkisi bu arada bittiyse iletilmez, alarmı yeniden onaylamanız gerekir.

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
      "Vana kapanmadı (arıza) — Evim", "Pano güvenli kipe girdi — Evim". Dokununca uygulama o evde açılır (sözleşme onayı ya da
      zorunlu şifre ekranı açıksa bu ekran geçilince). Alarm kalkınca bildirim kendiliğinden silinir; aynı alarm iki kez çalmaz.
   4. Çıkış yaparsanız ya da hesabınızda ev sahibi/üye olduğunuz ev kalmazsa takip durur. Telefon açılırken güvenli depo geç
      okunursa takip kapanmaz.
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
"Kod ile Bir Eve Katıl" → "Davet / Devir Kodu" → "Devam" (önizleme) → "Eve Katıl". Katılım sunucuda tamamlandığı hâlde yanıt
kaybolduysa aynı kodu yeniden denediğinizde "Bu davet kodunu zaten kullandınız; dairenin üyesisiniz." görünür ve ev seçilir; her
hatadan sonra uygulama ev listesini yeniden çeker. Kodu başka biri kullandıysa ya da süresi dolduysa kod geçersizdir.

### 8.3 Üyeler
"Aile & Misafir Yönetimi" → "Yetkiyi İptal Et". Son sahip kaldırılamaz. Bekleyen (henüz kullanılmamış) davetler aynı
ekranda listelenir ve iptal edilebilir.

Sahip ya da aile üyesi (misafir değil) evden çıkarılınca sunucu, **tek panolu evde** panonun yerel anahtarını kendiliğinden
değiştirir: çıkarılan kişinin bildiği anahtar geçersiz olur. Pano çevrimiçiyken birkaç saniyede tamamlanır; yerel moddaki
telefonlar yeni anahtarı buluttan kendiliğinden alır. Çok panolu evde bu değişim yapılmaz.

Üye çıkarılınca ya da ayrılınca, devir kabul edilince ve her servis oturumu bitince **tek panolu evde** panonun bulut kimliği de
yenilenir (v1.3.0+ pano yenisini kendisi alır); erişimi biten kişi eski kimlikle buluta bağlanamaz.

**Evden ayrılma (aile üyesi, misafir):** profil penceresindeki "Evden Ayrıl" → onay. Evdeki cihazlara erişiminiz biter; yeniden
katılmak için ev sahibinden yeni davet gerekir. Ev sahibi ayrılamaz: "Ev sahibi evden ayrılamaz; önce evi devredin.". Aile üyesi
ayrılınca panonun yerel anahtarı ve bulut kimliği yukarıdaki gibi değişir.

### 8.4 Ev devri
Sahip "48 Saatlik Devir Kodu & QR Üret" → yeni sahip kodu girip "DEVRAL" yazar → "Daireyi Devral". Eski sahip dahil tüm
üyeler erişimini kaybeder. "Devir İşlemini İptal Et" ile vazgeçilebilir. Devir kabul edilince panonun yerel anahtarı da
değişir (8.3'teki gibi). Kabul tamamlandığı hâlde yanıt kaybolduysa yeni sahip aynı kodu yeniden denediğinde
"<ev adı> dairesinin sahipliği zaten size devredildi." görünür (ev adı tırnak içinde; önizlemede "Bu daireyi zaten devraldınız.")
ve ev seçilir. Devirden (ya da acil sıfırlama / Home Admin atamasından) sonra yeni sahip yalnız o andan sonraki ve hâlâ açık alarmları
görür; önceki ailenin alarm geçmişi görünmez.

### 8.5 Servise geçici erişim
"Yetkili Servis İçin Geçici PIN" → "6 Haneli Servis PIN'i Üret" (bir kez gösterilir, 2 saat, tek kullanım, yalnız bu ev).
Açık servis oturumları listelenir; "Servis erişimini kapat" hepsini sonlandırır. Servis oturumu panonun yerel anahtarını
okuduysa oturum bitince anahtar değişir (8.3'teki gibi). Ev tam o sırada başka birine devredilirse (ya da servis yeni yönetici
atarsa) aynı anda istenen PIN ve davet kodu üretilmez: "Bu işlem için yetkiniz yok.".

---

## 9. Ayarlar
1. "Cihaz & Sistem Ayarları": Güvenlik (çocuk kilidi, parmak izi, servis PIN'i), Görünüm (koyu/açık/sistem), Cihaz
   ("Sistem Doktoru", Wi-Fi kurtarma, "Pano Değişimi", IP/anahtar, telemetri), Otomasyon (gece bildirimi, zamanlı kurallar),
   Aile, Hakkında ("Yasal Metinler": Kullanıcı Sözleşmesi ve Son Kullanıcı Lisans Koşulları, Gizlilik Politikası ve KVKK
   Aydınlatma Metni).
2. "Sistem Doktoru" (misafir hariç): bulut bağlantısı, ev modemi/internet, pano gücü ve donanımı denetler. Sorun sunucu ile panolar
   arasındaysa "Bulut Bağlantısında Geçici Sorun" der ve Wi-Fi ya da sigorta önermez: birkaç dakika sonra yeniden deneyin.
3. "Pano Değişimi": kanal adları, kurallar ve panjur süreleri yeni panoya taşınır; **su/gaz sensörü ve vana ayarları taşınmaz**.
   Evde bunlar varsa sonuç ekranı "Güvenlik ayarları (su/gaz sensörü, vana) yeni panoya aktarılmadı. Yetkili servisi çağırın." der.

---

## 10. Açık kalan konular

> 2026-10-09 sahip kararlarından sonra güncellendi (`docs/CONTRACTS.md` §3j; kararlar `docs/denetim/2026-10-09-kararlar.md`).

1. **Provizyonsuz pano buluta kendiliğinden bağlanamaz;** pano atölyede provizyon görmediyse servis gerekir.
2. **Pano modeme kabloyla bağlıysa** evin ağındaki herkes panoyu anahtarsız, uygulamada girişsiz bile yönetebilir; gaz vanası ve
   hırsız alarmı için de Ethernet'te sınır yoktur (kararınız, 2026-10-09). Panonun bulut sunucu adresi ise v1.3.2'de kilitlidir.
3. **Gece hatırlatması ve alarm, iOS'ta** yalnız uygulama açılınca görünür.
4. **Arka plan bildirimi cihazda denenmedi:** servisin başlaması, kaydırıp kapatınca sürmesi, yeniden başlatmada açılması,
   pil davranışı ve bildirim sesi ancak telefonda doğrulanır.
5. **Yasal metinler taslak:** sözleşme ve gizlilik metni avukat incelemesi ve yer tutucuların doldurulmasını bekliyor; onay ekranı
   ancak metin kesinleşince çıkar. Bugünkü metin taslak sürüm 2'dir (personelin yerel anahtar erişimi ve Ethernet gerçeği
   yazıldı); şirket bilgileri ve hukuk kararları proje sonunda girilecek.
6. **Kararlar verildi (2026-10-09);** ne yapıldığı `docs/denetim/2026-10-09-kararlar.md`'de. Sonraya kalanlar:
   - **Karekodun uygulamayı doğrudan açması:** Android'de yapıldı (2026-10-09): etiket karekodu, şifre sıfırlama ve sihirli giriş
     bağlantıları telefon kamerasıyla/e-postadan açılınca uygulama doğrudan açılır (uygulama kurulu değilse tarayıcıda yönlendirme
     sayfası). iPhone'da Apple Team ID gelene kadar tarayıcıda açılır.
   - **E-posta doğrulaması** sonraya bırakıldı (kararınız); kayıtta e-posta iki kez yazılır.
   - **Firmware v1.3.2 karta yazılmadı ve kartta denenmedi;** bulut sunucu kilidi ve sabit görevsiz fabrika ayarı karta yazılınca
     geçerli olur.
   - **Çok panolu evde** erişim bitince bulut kimliği yenilenmez (yalnız tek panolu ev).
