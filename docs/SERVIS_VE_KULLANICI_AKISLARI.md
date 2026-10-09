# AHBU Ev Otomasyonu: Servis ve Kullanıcı Akışları

> **Güncel akış belgeleri:** `docs/akislar/SERVIS_SORUMLUSU_AKISI.md` ve `docs/akislar/DAIRE_KULLANICISI_AKISI.md`
> (2026-10-08, düzeltmeler sonrası). Bu belge ayrıntılı başvuru olarak kalır. Bölüm 12'deki 1, 2, 3 ve 6. maddeler
> 2026-10-08'de düzeltildi (pano bulut kimliğini kendisi alıyor; yanlış PIN mesajı; sihirbazda Ethernet; Ethernet'li
> panoda kurulum ağı döngüsü). 4. madde (bildirim) Android için Firebase'siz yapılıyor.

> Kaynak: kodun kendisi (2026-10-08, commit `b79cc2b` sonrası). Ekrandaki düğme ve mesaj metinleri koddaki gibi tırnak içinde
> verildi. Belge koddan dört ayrı inceleme ile çıkarıldı; akışı etkileyen iddialar ayrıca elle doğrulandı. Kodda olmayan bir şey
> "YOK" diye yazıldı. Bulunan hatalar ve tutarsızlıklar en sonda, **Bölüm 12**'de numaralı liste olarak duruyor.
>
> Okuma sırası: önce Bölüm 1 (genel resim) ve 2 (roller); sonra işinize göre ilgili bölüm.

---

## 1. Genel resim

### 1.1 Parçalar
1. **Pano (kart):** Waveshare ESP32-S3 8 röle + 8 giriş. İsteğe bağlı RS485 ek modülüyle 40 röle/40 girişe kadar. Firmware güncel
   paket v1.3.0 (donanımda denenmedi); servis yazılımında "güncel" olarak hâlâ v1.2.1 seçili.
2. **Sunucu (bulut):** `evotomasyon.gudeteknoloji.com.tr`. Hesaplar, evler, cihaz kayıtları, şablonlar, alarm kayıtları.
3. **MQTT aracı (EMQX):** pano ile sunucu arasındaki canlı bağlantı (TLS, port 8884).
4. **Mobil uygulama:** ev sahibi/aile/misafir kullanımı + servis sihirbazı (aynı uygulama, role göre farklı ekran).
5. **Servis yazılımı (Windows):** atölye ve ofis işleri: firmware yükleme, envanter, etiket, provizyon, site ve şablon.

### 1.2 Temel kural: pano her şeyi kendisi yapar
1. Lambalar, panjurlar, duvar butonları, su/gaz alarmı ve vanalar **internet olmadan** çalışır. Bulut yalnızca bir kopyadır;
   ayarların asıl yeri panonun kendi belleğidir.
2. İnternet yalnızca uzaktan kontrol, alarm kaydı/bildirimi, aile paylaşımı ve servis işleri için gerekir.

### 1.3 Uçtan uca bir dairenin hayatı (toplu kurulum)
1. **Ofis:** servis yazılımında site açılır, daireler üretilir, daire tipi şablonları hazırlanır (Bölüm 4).
2. **Atölye:** kart envantere kaydedilir, etiketi basılır, firmware yüklenir, provizyon yapılır (ya da Ethernet'le hiç
   gerekmez), şablon yazılır, kablolama şeması basılır (Bölüm 3).
3. **Saha:** pano takılır, şemaya göre kablolanır, duvar butonlarıyla denenir (Bölüm 5).
4. **Teslim:** servis sorumlusu uygulamadaki sihirbazla panoyu müşterinin evine bağlar, testleri yapar, devreye alır (Bölüm 6).
5. **Kullanım:** ev sahibi uygulamadan kullanır, aileyi davet eder (Bölüm 8-9).

---

## 2. Roller ve kim ne yapabilir

### 2.1 Roller
| Rol | Kim | Nasıl girer |
|---|---|---|
| Süper kullanıcı (`super_user`) | Siz | E-posta + parola |
| Servis sorumlusu (`service_user`) | Kalıcı servis personeli | E-posta + parola |
| Geçici servis oturumu (`service_session`) | Ev sahibinin PIN verdiği teknisyen | 6 haneli PIN (2 saat, tek ev) |
| Ev sahibi (`owner`) | Daire sahibi | E-posta + parola / Google / Apple / SMS |
| Ev üyesi (`resident`) | Aile | Davet koduyla katılır |
| Misafir (`guest`) | Süreli misafir | Davet koduyla, en çok 72 saat |

### 2.2 Önemli yetki kuralları (sunucu)
1. **Hırsız alarmını kurma/çözme:** yalnız ev sahibi ve ev üyesi. Servis ve süper kullanıcı kuramaz.
2. **Gaz vanasını açma:** hiçbir rol uzaktan açamaz; yalnız panodaki "gaz sıfırlama" girişiyle yerinde açılır.
3. **Vana kapatma, ışık/panjur kontrolü:** misafir dahil herkes.
4. **Alarm onaylama, vana açma (gaz hariç):** süper kullanıcı, servis, geçici servis, ev sahibi, ev üyesi. Misafir yapamaz.
5. **Güvenlik ayarı değiştirme, panjur kalibrasyonu, pano değişimi:** süper kullanıcı, servis, geçici servis, ev sahibi.
6. **Devreye alma (teslim):** süper kullanıcı, servis, geçici servis.
7. **Evin yerel anahtarını okuma (ev üzerinden):** servis, geçici servis, ev sahibi, ev üyesi. **Süper kullanıcı okuyamaz.**
8. **Herhangi bir envanter kartının anahtarını okuma (servis yazılımı ucu):** süper kullanıcı ve servis sorumlusu, müşteri
   kartları dahil; her okuma kayıt altına alınır, kişi başı saatte en çok 60 (2026-10-08 kararı).
9. **Servis sorumlusunun bir eve erişimi:** müşteri adına kurduğu evde 72 saat geçerli kurulum yetkisi.
10. **Servis yazılımına giriş:** süper kullanıcı ve servis sorumlusu. Envantere kayıt/askıya alma/silme yalnız süper kullanıcı.

---

## 3. Pano davranışı (ortak bilgi)

### 3.1 İlk açılış (fabrika ayarı)
1. Tüm röleler kapalı başlar, panjurlar hareket etmez.
2. Röleler (v1.3.2+, sahip kararı 2026-10-09): hiçbir röleye sabit görev yok; 8 rölenin hepsi "Röle N" adlı lamba. Panjur yalnız
   servis şablonunda seçilirse yanındaki röleyle çift olur. (v1.3.1 ve öncesi: 1-2 Salon panjur, 3-4 Oda panjur, 5-8 lamba.)
3. Girişler (v1.3.2+): D1-D8 → aynı numaralı röleyi aç/kapa ("Anahtar / Buton N"). (v1.3.1 ve öncesi: D1 → panjur 1 tek buton,
   D3 → panjur 2 tek buton, D2/D4 boşta, D5-D8 → röle 5-8 aç/kapa.)
4. Güvenlik: tepkiler açık, kuruluk bekleme 10 sn, tek bölge "Ev", sensör/vana tanımlı değil.
5. MQTT sunucu adresi hazır ama **kimliği yok**: pano bu haliyle buluta bağlanmaz, yalnız yerelde çalışır.
6. Yerel anahtar ve kurulum ağı parolası boş: **provizyonsuz**.

### 3.2 Kurulum Wi-Fi'si (AP)
1. Adı `AHBU-XXXXXX` (MAC'in son 6 hanesi), adresi `192.168.4.1`, en çok 3 bağlantı.
2. Provizyonsuz panoda **parolasız**; provizyondan sonra etiketteki "AĞ PAROLASI (AP)" ile WPA2.
3. Açılma kuralları:
   1. Kayıtlı ev Wi-Fi'si yoksa açılışta açılır.
   2. Ev Wi-Fi'si 3 dakika koparsa 10 dakika açılır; bağlı biri varsa 2'şer dakika uzar, en çok 30 dakika.
   3. Kapandıktan sonra Wi-Fi hâlâ yoksa 15 dakika sonra yeniden açılır.
   4. Ev Wi-Fi'si 30 sn kararlı bağlıysa erken kapanır.
   5. Seri komut `AP ON` ayrı 10 dakikalık pencere açar; `AP OFF` kapatır ve 15 dakika açılmasını engeller.
4. Ethernet etkisi: bkz. Bölüm 12, madde 6 (beklenenden farklı davranış var).

### 3.3 Provizyon nedir
1. Panoya kendi **yerel anahtarını** (8-32 karakter) ve **kurulum ağı parolasını** yazma işlemi.
2. Yollar: USB seri `FACTORYINIT`, ağdan `POST /api/factory/init` (kurulum Wi-Fi'si, ev Wi-Fi'si ya da Ethernet; arayüz
   denetimi yok), servis sihirbazının 5. adımı.
3. Yalnız provizyonsuz panoda yapılır. Geri almak için USB'den `RESETKEY`.
4. **Ethernet'ten gelen istekler için provizyon gerekmez** (Bölüm 3.5).

### 3.4 Ağlar
1. **Ev Wi-Fi'si:** yalnız 2,4 GHz. Bağlantı başarılı olursa kaydedilir; olmazsa eski ağa döner.
2. **Ethernet (v1.3.0):** DHCP ile IP alır. Wi-Fi bağlıysa trafik Wi-Fi'den, değilse Ethernet'ten gider. Kablo çekilince
   Ethernet IP'si silinir.
3. **Bulut (MQTT):** kimlik yazıldıktan ve saat internetten alındıktan sonra bağlanır; Wi-Fi ya da Ethernet fark etmez.

### 3.5 Panonun yerel arayüzüne kim komut verebilir
1. **Herkese açık:** ana sayfa ve kısa durum (cihaz kimliği, ad, sürüm, provizyon, Wi-Fi bağlı mı).
2. **Wi-Fi ve kurulum ağından:** her komut için yerel anahtar (`X-Device-Key`) gerekir. 5 yanlış anahtar → o adres 60 sn
   kilitli. Kurulum ağından (WPA2 + parolalı) yalnız Wi-Fi tarama/bağlanma anahtarsız yapılabilir.
3. **Ethernet'ten (kablodan) gelen her istek:** **anahtarsız ve provizyonsuz tam yetkili**: röleler, güvenlik ayarları
   (gevşetme dahil), şablon, fabrika sıfırlaması, anahtar değiştirme, MQTT ayarı. Hatalı deneme kilidi yok.
   (2026-10-08 kararı; pano modeme kabloyla bağlıysa evin ağındaki herkes için geçerlidir.)

### 3.6 Duvar butonları ve çıkışlar
1. Girişler yalnız **yaylı (kalıcı olmayan) butonla** doğru çalışır; kalıcı duvar anahtarı desteklenmez.
2. Kipler: aç/kapa (her basışta değiştirir), basılı tut, panjur tek buton (yukarı/dur/aşağı), panjur yukarı, panjur aşağı.
3. Panjur: yukarı ve aşağı rölesi asla aynı anda çekmez, yön değişiminde en az 0,5 sn bekleme, süre 1-300 sn, konum süreden
   hesaplanır. Ayrı bir koruma görevi röleleri planlanan süre + 1,5 sn'de keser.
4. Darbe rölesi: belirtilen süre (ms) çekip bırakır (kapı otomatiği, zil).
5. Çocuk kilidi: duvar butonları çalışmaz (hareketli panjuru durdurmak hariç).

### 3.7 Güvenlik (alarm)
1. **Sensörler:** su, gaz, duman, kapı, pencere, hareket. Gaz ve duman her zaman **NC** bağlanır.
2. **Alarm:** onaylanmış tehlikede bölge kilitlenir: ilgili vanalar kapanır, siren çalar, pano zili öter.
3. **Onay:** sensör hâlâ ıslakken yalnız susturur; kuruduktan 10 sn sonra onay alarmı kaldırır. **Vana kapalı kalır**,
   açmak ayrı bir işlemdir.
4. **Vana açma:** bölge normal ve sensörler kuru olmalı. **Gaz vanası yalnız yerinde** "gaz sıfırlama" girişiyle açılır.
5. **Güvenli kip:** ayar bozulursa, elektrik kesintisinde şablon yazımı yarım kalırsa ya da pano sürekli yeniden başlarsa.
   Güvenli kipten çıkış yalnız yerinde (USB `SAFETY ACK FORCE` ya da alarm onay butonunu 5 sn basılı tutma).
6. **Hırsız alarmı:** kapalı / evde / dışarıda; çıkış gecikmesi 45 sn, giriş 30 sn.
7. **Kablosuz bildirim:** pano her olayı buluta gönderir, sunucu onaylayana kadar yeniden dener.

### 3.8 Sıfırlama ve güncelleme
1. **Fabrika sıfırlaması** (`POST /api/system/reset`; anahtarla ya da Ethernet'ten anahtarsız): uygulama ayarları, Wi-Fi,
   çocuk kilidi, panjur konumları, güvenlik ayarları ve şablon kaydı silinir. Yerel anahtar, AP parolası, MQTT kimliği ve
   alarm kilit kaydı **kalır**.
2. **Firmware güncellemesi:** yalnız USB'den. Uzaktan (OTA) güncelleme **YOK**.

---

## 4. Ofis: servis yazılımında site ve şablon

### 4.1 Açılış ve giriş
1. Program açılır; beş sekme var: "⚡ 1. Firmware Yükleyici (Flasher)", "🏷️ 2. Karekod Üret & Etiket Bas (Envanter)",
   "📡 3. Cihaz Provizyonu (USB / Wi-Fi)", "🏢 4. Siteler", "📐 5. Şablonlar".
2. "🔐 Sunucuya Giriş" → sunucu adresi, e-posta, parola. "Beni hatırla" varsayılan işaretli: oturum anahtarı bu bilgisayarda
   şifreli saklanır, parola saklanmaz. Sonraki açılışta sessizce oturum açılır.
3. Yalnız süper kullanıcı ve servis sorumlusu girebilir; başkası "Bu araç yalnızca süper kullanıcı veya servis sorumlusu
   hesabıyla çalışır" uyarısı alır.
4. Servis sorumlusunda envantere kaydetme/askıya alma/silme düğmeleri pasiftir ve bunu anlatan bir not çıkar.
5. "🚪 Oturumu Kapat" hatırlanan oturumu da siler.

### 4.2 Site açma (4. sekme)
1. "🔄 Siteleri Yenile" → "➕ Site Ekle".
2. Alanlar: "Site adı *", "Adres", "İl", "İlçe", "Sorumlu adı", "Sorumlu telefonu", "E-posta", "Blok sayısı", "Daire sayısı",
   "Not". Site adı en çok 120 karakter.
3. "✏️ Siteyi Düzenle", "🗑️ Siteyi Sil" (yumuşak silme; dairesine kart bağlı site silinemez).
4. Liste sütunu "İlerleme": Planlandı / Yazıldı / Kuruldu / Teslim edildi sayıları.

### 4.3 Daireler
1. Siteyi seçince "🏠 Daireler (seçili site)" listesi dolar.
2. "🧱 Toplu Daire Üret": blok (ör. A), ilk ve son daire no, isteğe bağlı daire tipi ve şablon. Bir seferde en çok 500;
   var olan blok+no atlanır.
3. "📐 Şablon Ata": daireye şablon seçilir.
4. "🔗 Kart Bağla": kartın UID'si (`AHBU-S3-XXXXXX`) yazılır; boş bırakılırsa bağlantı kalkar. Yalnız **stoktaki** kart
   bağlanabilir; bir kart yalnız bir daireye bağlanır.
5. "💾 Karta Yaz", "📄 Kablolama Şeması (PDF)", "🗑️ Daireyi Sil" (kartı bağlı daire silinemez).
6. Durumlar: **Planlandı** (ilk) → **Yazıldı** (şablon karta yazılınca, sunucu kendisi geçirir) → **Kuruldu** (kart bir
   müşteriye sahiplenilince) → **Teslim edildi** (bkz. Bölüm 12, madde 14).

### 4.4 Şablon hazırlama (5. sekme)
1. Üstten "Site:" seçilir (ya da "Genel (standart şablonlar)"), "🔄 Şablonları Yenile".
2. "➕ Yeni Şablon" düzenleyiciyi açar. Varsayılan: ad "Yeni Şablon", tip "2+1", 8 lamba rölesi, 8 boş giriş, tek bölge "Ev".
3. Üst satır: şablon adı, daire tipi, "Ek modül (RS485) var" + kanal (2/4/8/12/16/24/32) + adres, "↔ Kanalları Uygula".
   **Ek modül değişikliği yalnız bu düğmeye basınca işlenir** (Bölüm 12, madde 15).
4. **"⚡ Röle Çıkışları"** sekmesi: her röle için ad, oda, tip ("Lamba/Priz", "Panjur (çift)", "Darbe"), süre, bağlanacak yük.
   1. "Panjur (çift)" seçilince tek numaralı röle "⬆ Yukarı", sonraki "⬇ Aşağı" olur; süre (varsayılan 25 sn) ikisine aynı yazılır.
   2. Darbe süresi ms (varsayılan 1000).
   3. Lamba satırında "💡" düğmesi: "Parlaklık ayarı yapılacak mı?" Evet → dimmer kaynağı (Modbus modülü / kablosuz köprü),
      adres, kanal; pencere dimmerin nereye takılacağını yazar, aynı yönerge şemaya basılır.
5. **"🔘 Girişler (DI)"** sekmesi: ad, hedef röle, kip (hepsi yaylı buton), kablolama notu, güvenlik rolü, kontak, bölge.
   1. Güvenlik rolleri: su baskını, gaz, duman, kapı, pencere, hareket, genel kontak, alarm susturma butonu, vana kapatma
      butonu, gaz vanası sıfırlama, anahtarlı kontak.
   2. Rol seçilen girişin hedefi "Boşta" olur. Gaz/duman/anahtarlı kontak her zaman NC.
6. **"🛡️ Güvenlik"** sekmesi: tepkiler açık/kapalı, kuruluk bekleme (sn), bölge adları (1-4), güvenlik cihazları tablosu
   (vana/siren/fan/genel; vanada kapanma kipi "Enerji verince kapanır" / "Enerji kesilince kapanır" / "İki röle (darbe)",
   akışkan su/gaz). "➕ Cihaz Ekle" boş bir lamba rölesine ekler; panjur/darbe rölesine güvenlik cihazı bağlanamaz.
7. Arayüzde **olmayan** ayarlar: hırsız alarmı gecikmeleri, sensör onay süresi, vana geri bildirim girişi, fan ATEX onayı
   (var olan değerler korunur ama düzenlenemez).
8. "✓ Doğrula" yerel denetim yapar. "💾 Doğrula ve Kaydet (yeni sürüm)": önce yerel, sonra sunucu doğrular, yeni sürüm olarak
   kaydedilir. İçerik değişmediyse sürüm artmaz.
9. "📑 Çoğalt" (yeni ad sorar), "🕘 Sürüm Geçmişi" (eski sürümler değişmez), "🗑️ Şablonu Sil" (yumuşak silme; bu şablona
   atanmış dairelerin şablonu boşaltılır).

---

## 5. Atölye: kartı hazırlama (servis yazılımı)

### 5.1 Kaydet ve etiket (2. sekme, yalnız süper kullanıcı)
1. Kart USB ile takılı. "📡 Karttan MAC Oku" → MAC ve UID dolar (UID = `AHBU-S3-` + MAC'in son 6 hanesi).
2. "🎲 Rastgele PIN Üret" (6 hane), model ve parti alanları.
3. "☁️ SUNUCU ENVANTERİNE KAYDET & KAREKOD ÜRET": sunucu kartı kaydeder ve **yerel anahtarı bir kez** verir; AP parolası
   servis yazılımında üretilir. PIN ve anahtar bir daha gösterilemez.
4. Etiket (100x50 mm): sol karekod "1) Daireye bağla" (uygulama sahiplenme bağlantısı, UID+PIN), sağ karekod "2) Kurulum
   Wi-Fi'sine bağlan" (telefon kamerası; ağ adı + AP parolası). Ortada UID, PIN, ağ adı, AP parolası, MAC. Kırmızı uyarı:
   etiket gizlidir. Şablon yazıldıysa alt satırda daire bilgisi.
5. "💾 Etiketi Kaydet (PNG)", "🖨️ Yazdır".
6. Envanter tablosu: "🔄 Listeyi Yenile", "⏸️ Askıya Al", "▶️ Aktif Et", "🗑️ Envanterden Sil" (UID'yi yazarak onay).

### 5.2 Firmware yükleme (1. sekme)
1. COM port seçilir. "🚀 Bizim Geliştirdiğimiz Yazılım" seçili (şu an v1.2.1; v1.3.0 klasörde hazır ama seçili değil).
2. "⚡ FİRMWARE'İ KARTA YÜKLE (FLASH)". Dosya denetlenir (boyut, ESP32 imajı mı, birleşik imaj mı).
3. Bitince: kayıt bekliyorsa ve MAC eşleşiyorsa provizyon **aynı USB'den otomatik** başlar (3. sekmeye geçer).
4. Diğer düğmeler: "🔍 Çip Bilgisi Oku", "🗑️ Hafızayı Sil (Erase Flash)", "➕ Versiyon Arttır".

### 5.3 Provizyon (3. sekme)
1. **USB (önerilen):** "🔌 Seri (USB) ile Provizyonla (Önerilen)". Araç kartın açılmasını bekler, `STATUS` ile MAC'i ve
   provizyonsuz olduğunu denetler, `FACTORYINIT` ile anahtarı yazar, `STATUS` ile doğrular. Kartta eski anahtar varsa
   "Kartta Eski Anahtar Var" sorusu: Evet → `RESETKEY` + yeniden provizyon.
2. **Wi-Fi yedek yolu:** "📶 Wi-Fi ile Provizyonla (güvensiz yedek yol)". Bilgisayar kartın parolasız kurulum ağına bağlanır;
   anahtar düz HTTP ile gider. Sonra "✅ Wi-Fi ile Doğrula".
3. **Ethernet:** "🌐 Ethernet ile Provizyonla" → kartın Ethernet IP'si sorulur (yalnız yerel IP). Kimlik `/api/status`
   ile denetlenir, anahtar yazılır ve hemen doğrulanır. (Ethernet'le çalışacak kartta provizyon zaten gerekmez; bkz. 5.4.)
4. Gizli bilgiler (yerel anahtar, AP parolası) yalnız bellekte; kopyalanınca 45 sn sonra panodan silinir.
5. "🧹 Kaydı Bellekten Sil / Yeni Cihaz": provizyon bitmediyse uyarır (anahtar bir daha gösterilemez).
6. "📐 Şablon Yaz (aynı USB portu)": yalnız portu seçip 5. sekmeye geçer; yazımı siz "Karta Yaz" ile başlatırsınız.

### 5.4 Şablonu karta yazma
1. 4. sekmede daireyi ya da 5. sekmede şablonu seçip "💾 Karta Yaz".
2. **USB yolu:** port seçilir. Daireye bağlı kart varsa araç takılı kartın o kart olduğunu MAC'ten denetler; okunamaz ya da
   farklıysa **hiçbir şey yazmaz**. Şablon parça parça (`TPL BEGIN/DATA/COMMIT`) gönderilir, CRC ile denetlenir, kart tek
   seferde uygular, `TPL STATUS` ile geri okunur.
3. **Ethernet yolu:** kartın Ethernet IP'si ve UID'si girilir. **Anahtar ve provizyon gerekmez**, sunucuya sorulmaz.
   **IP–kart kimlik denetimi yok**: yanlış IP girilirse başka karta yazılır. Kart 10 sn'de bitiremezse "bekleniyor"
   denip 20 sn'ye kadar geri okunur.
4. Kart şablonu reddederse sebep gösterilir: alarm kilitli, hırsız alarmı kurulu, panjur hareket halinde, bellek yetersiz,
   şablon geçersiz (alan adıyla).
5. Başarıda: sonuç sunucuya işlenir (daire **Yazıldı**), daireye kart bağlı değilse "Kartı Daireye Bağla" sorulur,
   "Kablolama şeması (PDF) şimdi kaydedilsin mi?" sorulur. Bellekteki kart bu kartsa etikete daire satırı eklenir.
6. Ekranda hâlâ eski metinler var (ör. "yerel anahtar sunucudan alınır"); gerçek davranış yukarıdaki gibidir
   (Bölüm 12, madde 11).

### 5.5 Kablolama şeması (PDF)
1. A4, 300 DPI, birkaç sayfa. Her sayfada site, blok/daire, şablon, tip, sürüm, tarih ve şablon karekodu.
2. Bölümler: (1) karta bakan klemens çizimi (R1-R8 üstte, D1-D8 altta, ek modül ayrı blok), (2) röle tablosu (panjur yön
   notları, darbe süresi, güvenlik cihazı, dimmer), (3) giriş tablosu + "Kalıcı (mandallı) duvar anahtarı DESTEKLENMEZ"
   uyarısı, (4) dimmer yerleşimi, (5) güvenlik cihazları ve gaz uyarısı, (6) genel kurallar.
3. Alt bilgi: "Bu şema şablon sürümü vN içindir".

---

## 6. Saha: montaj ve kablolama testi
1. Etiketteki blok/daire ile bulunulan daire aynı mı, şemadaki şablon sürümü etiketle aynı mı kontrol edilir.
2. Kablolar şemaya göre bağlanır: röle kontağı kuru kontak (faz COM'a, yük NO'ya), girişler DI–GND arasına yaylı buton/sensör.
3. Enerji verilir; pano internetsiz çalışır.
4. Test (uygulama gerekmez): her duvar butonuna basılır (lamba/panjur şemadaki gibi çalışmalı), panjur yönü kontrol edilir
   (ters ise motor uçları değiştirilir), su sensörü ıslatılır (vana kapanmalı, siren çalmalı), gaz dedektörü kendi test
   düğmesiyle denenir.

---

## 7. Servis: uygulamadaki kurulum sihirbazı

### 7.1 Giriş yolları
1. **Servis sorumlusu:** e-posta + parola. Ana ekranda "Devreye Alma (Servis Modu)" kartı.
2. **Süper kullanıcı:** "Tüm Paneli Aç" → "Görevler ve Araçlar" → "Kurulum Sihirbazı".
3. **Geçici servis (PIN):** giriş ekranında "Yetkili Servis Girişi (PIN)" → ev sahibinin ürettiği 6 haneli PIN ve isteğe
   bağlı ad. PIN 2 saat geçerli, yalnız o ev. Açık başka hesap varsa kapanır.
4. "Servis Paneli" içeriği: oturum bandı (PIN'de kalan süre), "Yeni Kurulum Başlat", "Wi-Fi Kurulum & Kurtarma Sihirbazı",
   "Devam eden kurulumlar" (yarım kalanlar; "Devam Et"), "Mevcut cihazlarım" ("Bağlantıyı yeniden kur" → 5. adım,
   "Testleri yap" → 7. adım), yönetim araçları, acil durum kartı.

### 7.2 Sihirbazın genel kuralları
1. 10 adım; her adımda "Ne yapacaksın?" listesi. "Devam" yalnız adım gerçek pano/sunucu yanıtıyla doğrulanınca açılır.
2. İleriye atlanamaz; ilk tamamlanmamış adımdan ötesine gidilemez.
3. İlerleme telefonda saklanır (en çok 20 kurulum). **Saklanmayanlar:** cihaz anahtarı, kurulum PIN'i, müşteri kodu,
   bulut kimliği, Wi-Fi şifresi.
4. Çıkışta: panjur işlemi bitmesi beklenir (en çok 20 sn), ölçüm için yazılan geçici süre geri alınır, 7. adımdaysa
   lambalar kapatılır.
5. **PIN oturumunda:** 3. ve 4. adım atlanır (sahiplenme yapılamaz), şablon kartı görünmez, acil sıfırlama yok.
6. **Mevcut cihaz kipinde:** 2-4. adımlar atlanır.

### 7.3 Adım 1 — Hazırlık
1. Teknisyen adı, rol bilgisi, "Yanınızda olması gerekenler" listesi (etiket, müşteri e-postası/telefonu, ev Wi-Fi adı ve
   şifresi, şarjlı telefon, elektriği verilmiş pano).
2. "Bağlantıyı Doğrula": oturum ve sunucu erişimi denetlenir.

### 7.4 Adım 2 — Cihazı Tanı
1. "Etiketi Tara (Karekod)" ya da elle seri no + 6 haneli PIN → "Bilgileri Kullan".
2. Sunucuda stok durumu denetlenir: stokta / askıda / iptal / zaten bir daireye bağlı.
3. PIN oturumunda: dairedeki panolar listelenir, biri seçilir.

### 7.5 Adım 3 — Müşteri
1. Müşterinin e-postası ya da telefonu → "Kod Gönder". Kendi hesabınızı yazamazsınız.
2. Müşteriye 6 haneli kod gider (15 dakika geçerli; 60 sn sonra yeniden gönderilebilir).
3. Müşteri kodu teknisyene söyler, kod yazılır. Kod 4. adımda doğrulanır.

### 7.6 Adım 4 — Daireye Bağla
1. Özet; isteğe bağlı daire adı → "Daireye Bağla" → onay ("Bu işlem geri alınamaz").
2. Sunucu: müşterinin boş evi varsa onu kullanır, yoksa yeni ev açar. Kart bir site dairesine bağlıysa ev adı
   "<site> <blok>-<no>" olur ve cihaz listesi kartın şablonundan oluşur. Müşterinin hesabı yoksa açılır ve davet e-postası
   gider. Teknisyene 72 saat kurulum yetkisi verilir. Tek kullanımlık bulut kimliği üretilir.
3. Yanıt kopsa bile "Tekrar dene" önce cihazın bağlanıp bağlanmadığını sunucudan kontrol eder (çift kayıt olmaz).

### 7.7 Adım 5 — Wi-Fi Kurulumu (internet gerekmez)
1. Telefon kartın kurulum ağına (`AHBU-XXXXXX`) etiketteki parola ya da 2. karekodla bağlanır; "Yine de bağlı kal".
2. "Bağlandım: Panoyu Kontrol Et": pano kimliği doğrulanır.
3. Pano provizyonsuzsa: "Pano ilk kez hazırlanacak" → "Panoyu Hazırla" (anahtar ve kurulum parolası yazılır), telefon yeniden
   parolalı ağa bağlanır.
4. "Ağları Tara" ya da elle ağ adı/şifre (yalnız 2,4 GHz) → "Yeni Wi-Fi Şifresini Panoya Yükle".
5. Sonuç: bağlandı (IP gösterilir) / şifre yanlış / 5 GHz / zaman aşımı.
6. Pano zaten ev ağındaysa "Bu IP ile Doğrula".
7. Sonunda telefon ev Wi-Fi'sine geri alınır.
8. **Ethernet'le bağlı panoda bu adım tamamlanamaz** (Bölüm 12, madde 3).

### 7.8 Adım 6 — Bulut Bağlantısı
1. Telefon ev ağında; "Panoya Bağlan" (pano IP'si). Anahtar bellekten ya da sunucudan alınır.
2. "Buluta Bağla ve Bekle": bulut kimliği panoya yazılır, en çok 90 sn "çevrimiçi" beklenir.
3. Pano zaten çevrimiçiyse kimlik değiştirilmez, adım hemen tamamlanır.
4. Zaman aşımında sebep söylenir: Wi-Fi'den düştü / kimlik kaydedilmedi ("Kimliği Yeniden Yaz") / saat alınamadı /
   sunucuya güvenli bağlanamıyor (port 8884).

### 7.9 Adım 7 — Röle Testi ve güvenlik ataması
1. **Şablon kartı (isteğe bağlı, yalnız servis sorumlusu/süper kullanıcı):** "Şablon Seç" → site ya da genel → şablon →
   önizleme → "Panoya Uygula". Uygulanınca 7-9. adımların test ilerlemesi sıfırlanır, sunucuda bekleyen bulut güvenlik
   değişiklikleri silinir, röleler şablon adlarıyla yeniden okunur. Panoda şablon varsa "Panoda yüklü şablon … (vN)".
2. Özet: "N röle", doğrulandı/kullanılmıyor/sorunlu/bekliyor sayıları, "Şablon vN", "N panjur (Adım 8)".
3. Panjur röleleri bilgi kartı olarak görünür ("Adım 8'de denenir"), düğmesi yoktur.
4. Her lamba rölesi: "Aç"/"Kapat" → pano cevabı → "Lamba / yük gerçekten çalıştı mı?" Evet/Hayır. Darbe rölesi "Tetikle".
   Bağlı değilse "Kullanılmıyor".
5. "Bu kanala ne bağlı?": Lamba/priz (parlaklık sorusu ve dimmer yönergesi), Vana (enerjide kapalı mı, su/gaz, tek/iki
   röle, geri bildirim girişi, bölge), Siren, Fan (ATEX onayı), Diğer.
6. "Girişler ve Sensörler": her girişin rolü (duvar butonu, su, gaz, duman, kapı, pencere, hareket, vana geri bildirimi,
   alarm onay, vana kapat, gaz vanası açma, alarm anahtarı), NC/NO, bölge, hırsız alarmı gecikmeleri, kablosuz sensör yuvası.
7. "Güvenlik Ayarlarını Panoya Yaz ve Test Et": önce yerel ağdan yazar; pano erişilemezse buluttan; buluttan yazıldıysa ve
   pano çevrimdışıysa 24 saat kuyrukta bekler (adım tamamlanmaz). Sonra her bölgede test: vana kapanmalı, siren çalmalı.
   Gaz vanası testten sonra kapalı kalır.
8. Tamamlanma: en az bir röle doğrulanmış, diğerleri doğrulanmış ya da kullanılmıyor, güvenlik ayarı kaydedilmiş, bölge
   testi başarılı.

### 7.10 Adım 8 — Panjur Testi ve Kalibrasyon
1. Yön testi: "Yukarı"/"Dur"/"Aşağı" → "Panjur gerçekten YUKARI mı gitti?" Ters ise klemensler değiştirilir.
2. Süre ölçümü: "Ölçüme Hazırla" (süre geçici 300 sn yapılır) → "Alta İndir" → "Ölçümü Başlat" → panjur tam açılınca
   "Bitti" → ±1 sn ayar → "Kaydet ve Panoda Doğrula". Ya da "Süreyi biliyorum: elle gireceğim".
3. Süre **buluttan** yazılır; pano çevrimiçi olmalı.
4. "Bu panjur kullanılmıyor" seçilebilir ama en az bir panjur gerçekten test edilmeli.

### 7.11 Adım 9 — Duvar Butonları
1. "Dinlemeyi Başlat" → butonlara sırayla basılır (1 sn); her giriş "Algılandı" olur ya da "Bu girişte buton yok" işaretlenir.
2. Çocuk kilidi açıksa basışlar algılanır ama röleler çalışmayabilir (uyarı çıkar).

### 7.12 Adım 10 — Teslim
1. Kontrol listesi: Wi-Fi, Bulut, Röleler, Panjurlar, Duvar butonları.
2. "Montaj notu", "Teslim alan kişi", "Müşteriye kurulumu gösterdim ve teslimi onayladı" kutusu.
3. "Devreye Almayı Tamamla": sunucu beş kontrolü değerlendirir; hepsi tamamsa cihaz "devrede" olur.
4. Kurulum raporu (PIN, anahtar, kimlik, Wi-Fi şifresi içermez) → "Raporu Kopyala / Paylaş" (yalnız panoya kopyalar).
5. Uyarı: "Uygulama kapalıyken alarm bildirimi bu sürümde gelmez; siren takmanız önerilir."

---

## 8. Servis: diğer işler

### 8.1 Pano değişimi (arızalı panoyu yenisiyle değiştirme)
1. Yetki: süper kullanıcı, servis, geçici servis, ev sahibi. Seçili evde yapılır.
2. Eski pano seçilir; yeni panonun kimliği (etiket tarama) ve kurulum PIN'i, isteğe bağlı neden.
3. "Pano değişimi onayı" (geri alınamaz) → kanallar, adlar, panjur süreleri yeni panoya aktarılır, eski pano devreden çıkar.
4. "Yeni Panoyu Şimdi Bağla" → sihirbaz 5. adımdan başlar.

### 8.2 Acil servis sıfırlaması
1. Yalnız süper kullanıcı ve servis sorumlusu (servis sorumlusu yalnız son 72 saatte kurduğu evlerde).
2. Cihaz kimliği, en az 15 karakter gerekçe, isteğe bağlı yeni sahip. UID yazılarak onaylanır.
3. Eski ailenin tüm yetkileri biter; cihaz stoğa döner ya da yeni sahibe devredilir. Yeni kurulum PIN'i bir kez gösterilir.
4. Yeni sahibe devredildiyse (servis sorumlusu için) "Panoyu şimdi bağla" → sihirbaz 5. adım.

### 8.3 Abone ve hesap yönetimi
1. "Servis Yönetimi": "Hesaplar" (hesap/müşteri ekle, dondur, davet yeniden gönder) ve "Görevler ve Araçlar".
2. "Abonelerim & Cihaz Atama": aboneler listesi, "Home Admin Ata" / "Yöneticiyi Devret" (mevcut sahibe kod gider; süper
   kullanıcı gerekçeyle zorla atayabilir).

### 8.4 Wi-Fi kurtarma (modem/şifre değişince)
Bölüm 9.3 ile aynı sihirbaz; servis panelinde de kart olarak var.

---

## 9. Kullanıcı akışları (ev sahibi, aile, misafir)

### 9.1 Kayıt ve giriş
1. **Açılış:** "Oturum güvenli şekilde doğrulanıyor..."; 15 sn sürerse "Şifre ile Giriş Yap" önerilir.
2. **Kayıt ("Kayıt Ol"):** ad soyad, e-posta, telefon (isteğe bağlı), şifre (en az 10 karakter) → "Kayıt Ol ve Giriş Yap".
   Hesap **hemen açılır**; e-posta doğrulaması YOK. (Yalnız teknisyenin müşteri adına açtığı hesap "davet bekliyor"
   durumunda başlar ve e-postadaki bağlantıyla 72 saat içinde etkinleştirilir.)
3. **Giriş:** e-posta + şifre; ayrıca "Google ile Devam Et", "Apple ile Giriş Yap" (iOS), SMS ile şifresiz giriş (sunucu
   açarsa), "E-postadaki Bağlantım Var". 15 dakikada çok hatalı denemede geçici kilit ("Tekrar dene (mm:ss)").
4. **Oturum:** 30 gün sürer. "Beni hatırla" diye ayrı bir seçenek uygulamada YOK.
5. **Parmak izi/yüz:** ilk girişten sonra sorulur; uygulama açılışta ve 30 sn+ arka planda kaldıktan sonra kilitlenir.
6. **Şifremi unuttum:** e-posta/telefon → 6 haneli kod (15 dakika) → yeni şifre. Diğer cihazlardaki oturumlar kapanır.
7. **Çıkış / tüm cihazlardan çıkış / şifre değiştir / hesabı sil** (profil penceresi). Hesap silmede "SİL" yazılır; başka
   üyesi olan evin tek sahibiyse önce devretmesi istenir.

### 9.2 Evi olmayan kullanıcı ve panoyu sahiplenme
1. Ekran: "Hoş Geldiniz, <ad>!" → "Kod ile Bir Eve Katıl", "Karekod Tara (Katıl / Cihaz Eşle)", "Cihaz Kodunu Elle Gir".
2. Etiketin 1. karekodu taranır (ya da UID + 6 haneli PIN elle) → "Cihaz Eşleştirme" → "Ev / Daire Adı" (varsayılan "Evim")
   → "Eşle & Sahiplen".
3. Sunucu: boş ev varsa kullanır, yoksa açar; kart site dairesine bağlıysa ev adı daireden gelir; cihaz listesi şablondan
   ya da modelden. 5 yanlış PIN → 15 dakika kilit.
4. **Dikkat:** bu yolla sahiplenilen pano **buluta bağlanmaz**; buluta bağlanması için servisin sihirbazı 6. adımı
   çalıştırması gerekir (Bölüm 12, madde 1).
5. Etiketteki karekod uygulama dışında açılırsa (bağlantı), giriş yapılmışsa doğrudan eşleştirme penceresi açılır.

### 9.3 Wi-Fi kurulumu ve kurtarma (kullanıcı)
1. Giriş ekranında "Pano Wi-Fi Kurulumu (İnternet Gerekmez)" ya da ayarlarda "Wi-Fi Şifre Değişimi & Kurtarma".
2. Telefon kartın kurulum ağına bağlanır (etiketin 2. karekodu) → "Bağlantıyı Test Et" → "Ağları Tara" / modem karekodu /
   elle → "Yeni Wi-Fi Şifresini Panoya Yükle".
3. Başarıda "Pano ev Wi-Fi ağına bağlandı!"; telefon ev ağına geri alınır. Sunucuya hiç gidilmez.
4. Provizyonsuz panoda çalışmaz ("Pano henüz hazırlanmamış… servis kurulum sihirbazını kullanın").

### 9.4 Bulut modu ve yerel mod
1. Mod **elle seçilir** ve telefonda saklanır; uygulama kendiliğinden geçmez. Misafir mod değiştiremez.
2. **Bulut modu:** komut sunucuya gider; sonuç panonun bir sonraki durum bildirimiyle onaylanır (en çok 10 sn), gelmezse
   "Cihazdan onay alınamadı. İşlem geri alındı…".
3. **Yerel mod:** uygulama panonun IP'sine doğrudan bağlanır; IP elle girilir (otomatik bulma YOK), anahtar telefonda ya da
   sunucudan. Giriş yapılmadan ve anahtar yokken yerel moda geçiş tıkanıyor (Bölüm 12, madde 5; doğrulanmadı).

### 9.5 Günlük kullanım
1. Ana ekran: çevrimdışı uyarısı → güvenlik uyarıları → sayaçlar (açık lamba, hareketli panjur) → huzur bandı → "Hızlı
   Senaryolar" → oda filtreleri → "Panjurlar", "Aydınlatma & Çıkışlar", "Duvar Butonları & Girişler", "Güvenlik ve Eylemciler".
2. Lamba: AÇIK/KAPALI; darbe çıkışı "Tetikle"; panjur "Aç"/"Durdur"/"Kapat" ve yüzde kaydırıcı.
3. Gaz alarmı sürerken her anahtarlamada "Elektrik anahtarlamak kıvılcım oluşturabilir. Yine de uygulansın mı?" sorulur.
4. Hızlı senaryolar (misafire görünmez): "Evden Çıkıyorum" (lambalar kapanır, panjurlar iner, alarm kurulsun mu diye
   sorar), "Günaydın", "İyi Geceler", "Tüm Lambalar", "Panjurları Durdur". Başka senaryo/otomasyon YOK.
5. Zamanlı kurallar (yalnız bulut modu, sahip ve üye): kanal, aç/kapat/tetikle, saat, günler.
6. Çocuk kilidi: kilitlemek tek dokunuş, kaldırmak parmak izi ya da basılı tutma ister.
7. Gece huzur bildirimi: seçilen saatte (varsayılan 23:30) açık lamba varsa sunucu kayıt oluşturur; telefona bildirim
   gitmez (bildirim altyapısı kapalı), uygulama açılınca bant olarak görünür.
8. Kullanıcı kanal ve oda adlarını uygulamadan **değiştiremez** (yalnız servis sihirbazında).

### 9.6 Güvenlik (kullanıcı)
1. Alarm kartı: "Su baskını: <sensör>" vb.; ıslakken "Sesi Sustur", kuruyunca "Alarmı Onayla". Vana kapalı kalır.
2. "Vanayı Kapat" herkes için, "Vanayı Aç" yalnız koşullar uygunsa; gaz vanası uygulamadan **açılamaz**.
3. Gaz/duman için yönerge (havalandırın, 187/112'yi arayın).
4. Hırsız alarmı: "Kapalı"/"Evde"/"Dışarıda"; açık sensör varsa "Kurulamaz: <sensör> açık."; girişte "Giriş gecikmesi".
5. Misafir: ışık/panjur kullanabilir, vana kapatabilir; alarm onaylayamaz, vana açamaz, alarm kuramaz, alarm bildirimi almaz.
6. **Telefona anlık bildirim bu sürümde YOK** (uygulamada Firebase yok); uyarılar uygulama açılınca görünür.

### 9.7 Aile ve paylaşım
1. **Davet (yalnız sahip):** "Erişim Paylaş & Davet Et" → aile üyesi kodu (24 saat, tek kullanım) ya da süreli misafir
   kodu (2/4/8/24/48/72 saat). Evde en çok 20 açık davet.
2. **Katılma:** "Kod ile Bir Eve Katıl" → kod → önizleme → "Eve Katıl".
3. **Üyeler:** "Aile & Misafir Yönetimi" → "Yetkiyi İptal Et". Son sahip kaldırılamaz.
4. **Misafir süresi bitince:** "Erişiminiz sona erdi".
5. **Devir:** sahip "48 Saatlik Devir Kodu & QR Üret"; yeni sahip kodu girip "DEVRAL" yazar. Eski sahip dahil tüm üyeler
   erişimini kaybeder. Devir iptal edilebilir.
6. **Servis PIN'i:** sahip "6 Haneli Servis PIN'i Üret" (bir kez gösterilir, 2 saat). Açık servis oturumları listelenir,
   "Servis erişimini kapat" hepsini sonlandırır.

### 9.8 Ayarlar
1. "Cihaz & Sistem Ayarları": Güvenlik (çocuk kilidi, biyometrik, servis PIN'i), Görünüm (koyu/açık/sistem), Cihaz (Sistem
   Doktoru, Wi-Fi kurtarma, Pano Değişimi, IP/anahtar, telemetri), Otomasyon (gece bildirimi, zamanlı kurallar), Aile.
2. **Sistem Doktoru** (misafir hariç): bulut bağlantısı, ev modemi/internet, pano gücü ve donanım katmanlarını denetler;
   gerekirse Wi-Fi kurtarmayı önerir.

---

## 10. Sunucu tarafında ne olur

### 10.1 Sahiplenme (claim)
1. UID + PIN denetlenir (5 yanlış → 15 dk kilit). Servis sorumlusu müşteri adına bağlıyorsa müşteri kodu (15 dk) zorunlu.
2. Ev seçilir/açılır, ev adı belirlenir (site dairesi → "<site> <blok>-<no>"), kanallar şablondan ya da modelden kurulur,
   daire **Kuruldu** olur, PIN yakılır, tek kullanımlık bulut kimliği üretilir, denetim kaydı yazılır.

### 10.2 Devreye alma
Beş kontrol (röle, buton, panjur, ağ, bulut) gelir; hepsi tamamsa cihaz "devrede", değilse "testler başarısız" olarak
kaydedilir.

### 10.3 Pano ile köprü (MQTT)
1. Pano çevrimiçi/çevrimdışı, durum ve olay bildirir; 120 sn ses gelmezse çevrimdışı sayılır.
2. Pano çevrimdışıyken komut kuyruğa alınmaz (hata döner); yalnız güvenlik ayarı değişiklikleri 24 saat bekletilir.
3. Panodaki şablon numarası ve sürümü sunucuya işlenir.

### 10.4 Yerleşim eşitlemesi
1. Kanal tipi ve panjur çiftleri **panoyu** esas alır; kullanıcının verdiği adlar ve odalar korunur.
2. Kanal silinmesi için aynı küçülme en az 20 sn arayla iki kez görülmelidir. Değişen kanallardaki zamanlı kurallar kapatılır.

### 10.5 Alarm kayıtları ve bildirim
1. Her olay bir kez kaydedilir, panoya onay gönderilir.
2. Bildirim kararı: yeni alarm → ev sahibi ve üyeler; vana arızası → arıza bildirimi; misafir ve servis hesapları alarm
   bildirimi almaz. (Sunucu bildirim gönderebilir; uygulama tarafında alıcı yok, bkz. 9.6.)

---

## 11. Özet: bir işi kim, nerede yapar

| İş | Nerede | Kim |
|---|---|---|
| Site / daire / şablon | Servis yazılımı 4-5. sekme | Süper kullanıcı, servis sorumlusu |
| Envantere kayıt, etiket | Servis yazılımı 2. sekme | Süper kullanıcı |
| Firmware yükleme | Servis yazılımı 1. sekme (USB) | Atölye |
| Provizyon | Servis yazılımı 3. sekme / sihirbaz 5. adım | Atölye / servis |
| Şablon yazma | Servis yazılımı "Karta Yaz" (USB/Ethernet) / sihirbaz 7. adım (Wi-Fi) | Atölye / servis |
| Kablolama | Sahada, PDF şemaya göre | Saha ekibi |
| Müşteriye bağlama ve devreye alma | Uygulama, servis sihirbazı | Servis sorumlusu (PIN oturumu bağlayamaz) |
| Wi-Fi değişikliği | Uygulama, Wi-Fi kurtarma sihirbazı | Ev sahibi ya da servis |
| Aile/misafir/devir | Uygulama | Ev sahibi |

---

## 12. Bulunan sorunlar ve tutarsızlıklar (incelemeniz için)

Her madde koddan çıkarıldı. "Doğrulandı" yazanlar ayrıca elle kontrol edildi.

1. **Ev sahibi panoyu kendisi sahiplenirse pano buluta bağlanmıyor.** Sunucu tek kullanımlık bulut kimliğini veriyor ama
   uygulamanın eşleştirme penceresi bunu panoya yazmıyor; bunu yalnız servis sihirbazının 6. adımı yapıyor. (Doğrulandı.)
2. **Yanlış kurulum PIN'inde yanlış mesaj.** Sunucu kalan deneme sayısıyla 403 dönüyor; uygulama 403'ü "Bu işlem için
   yetkiniz yok…" diye gösteriyor, kalan hak hiç görünmüyor. (Doğrulandı.)
3. **Servis sihirbazı Ethernet'i tanımıyor.** Panonun bildirdiği Ethernet alanları hiçbir ekranda kullanılmıyor; 5. adım
   ("Bu IP ile Doğrula") ve teslimdeki ağ kontrolü yalnız Wi-Fi'ye bakıyor. Yalnız Ethernet'le bağlı pano 5. adımda ve
   teslimde takılır. (Doğrulandı.)
4. **Telefona anlık bildirim yok.** Uygulamada Firebase yok; alarm ve gece hatırlatması yalnız uygulama açılınca görünüyor.
5. **Yerel moda ilk kez geçişte IP/anahtar alanı görünmeyebilir.** Giriş yapılmamış ve anahtarı olmayan telefonda yetki
   sıfır olduğu için ayarlar sayfasında IP/anahtar kartı çıkmıyor. (İnceleme bulgusu; elle denenmedi.)
6. **Ethernet'li panoda kurulum ağı açılıp kapanmaya devam ediyor.** Kodun yorumu aksini söylese de, provizyonlu ama kayıtlı
   Wi-Fi'si olmayan pano Ethernet bağlıyken de kurulum ağını 10 dk açık / 15 dk kapalı döngüsüyle açıyor (ağ parolalı).
7. **Provizyon her arayüzden kabul ediliyor.** Provizyonsuz pano ev Wi-Fi'sinden de ilk anahtarını alabilir (yorum "yalnız
   kurulum ağından" diyor).
8. **Ethernet'ten gelen isteklerde hiçbir koruma yok.** Fabrika sıfırlaması, anahtar değiştirme, MQTT ayarı, güvenlik
   gevşetmesi anahtarsız ve deneme sınırı olmadan yapılabilir. (2026-10-08 kararınız; bilgi için.)
9. **Ethernet'le şablon yazımında kart kimliği denetlenmiyor.** Yanlış IP girilirse başka bir karta yazılır ve kayıt
   girilen UID'ye işlenir. (Kararınız; bilgi için.)
10. **Servis sorumlusu her müşteri panosunun anahtarını alabiliyor** (kayıt + saatte 60 sınırı ile). (Kararınız.)
11. **Servis yazılımında eskimiş metinler:** "Karta Yaz" penceresindeki Ethernet açıklamaları hâlâ "yerel anahtar sunucudan
    alınır" diyor ve UID'yi "anahtar için" zorunlu tutuyor; giriş penceresi başlığı "Süper Kullanıcı Girişi"; envanter notu
    "süper kullanıcı hesabıyla giriş yapın"; bir ipucu var olmayan "Provizyonu Başlat" düğmesini anıyor.
12. **Servis yazılımı rehberinde eskimiş bilgiler:** firmware sürümü v1.1.2 yazıyor (seçili olan v1.2.1), "Ethernet
    firmware'de kapalı" diyor, "yalnız süper kullanıcı girebilir" diyor.
13. **Güncel firmware seçimi v1.2.1.** v1.3.0 paketi hazır ama `version_info.json` bilerek değiştirilmedi; Ethernet ve
    şablon özellikleri için kartlara v1.3.0 yüklenmeli (önce donanım denemesi).
14. **Daire "Teslim edildi" durumuna fiilen geçmiyor.** Sunucuda daire durumunu değiştiren uç var (`PATCH …/flats/:id`
    `status`), ama onu kullanan bir ekran yok ve uygulamadaki devreye alma (teslim) daire durumunu güncellemiyor; sunucu
    kendiliğinden yalnız "Yazıldı" ve "Kuruldu"yu koyuyor.
15. **Şablon düzenleyicide ek modül değişikliği kaybolabilir:** kutu işaretlenip "↔ Kanalları Uygula"ya basılmadan
    kaydedilirse değişiklik işlenmiyor.
16. **Ethernet provizyonunda hızlı doğrulama başarısız olursa yeniden doğrulama yolu yok:** "✅ Wi-Fi ile Doğrula" kurulum
    ağı adresine (192.168.4.1) gidiyor, Ethernet IP'sine değil.
17. **Uygulamadaki şablon hata metni eskimiş:** "Şablon bu bağlantıdan yazılamaz (USB…)" mesajı kaldı; pano artık bu hatayı
    şablon için vermiyor (zararsız).
18. **Yazım kaydı oturum yoksa sessizce atlanıyor** (servis yazılımı): giriş yapılmadan karta yazılırsa sunucuya kayıt
    düşmüyor ve uyarı çıkmıyor.
19. **Sihirbazda 8. adımın panjur süresi buluttan yazılıyor:** pano çevrimiçi değilse kalibrasyon kaydedilemez
    (tasarım gereği, bilgi için).
20. **Uygulamada kullanıcı kanal/oda adlarını değiştiremiyor;** yalnız servis sihirbazından yapılabiliyor.
