# Yasal Metinler

> **Durum (2026-10-09):** İki metin de **TASLAK** (sürüm 1, `status: draft`, yürürlük tarihi alanı 2026-10-08).
> Metinlerde `[DOLDURULACAK: …]` yer tutucuları var. Yer tutucular doldurulmadan, aşağıdaki kararlar verilmeden ve
> metinler bir **avukata incelettirilmeden** `status: final` yapılmamalıdır.
>
> Metinler, 2026-10-08 tarihli kişisel veri envanterine (salt okunur kod incelemesi) ve kodun kendisine dayanır;
> 2026-10-09'da KVKK, tüketici hukuku ve kodla tutarlılık açısından yeniden incelenip düzeltildi (Bölüm 8).
> Kod bu metinlerin anlattığı davranışı değiştirirse metin de güncellenmeli ve sürümü artırılmalıdır (Bölüm 7).
>
> **Taslağı canlıya almadan önce bilin:** sunucu taslak metni de yayımlar ve kayıt ekranı taslak sürüm 1'in kabulünü
> ister. Taslak metin web sayfasında "henüz yürürlükte değildir", uygulamada "henüz kesinleşmedi" bandıyla
> gösterildiği ve yer tutucular içerdiği için bu kabulün bağlayıcılığına güvenmeyin; final sürüm (Bölüm 3, madde 6)
> yayımlanana kadar kullanıcılarla geçerli bir kullanım sözleşmesi bulunmadığını varsayın.

## 1. Metinler nerede

| Belge | Dosya | `id` | Onay | Herkese açık adres |
|---|---|---|---|---|
| Kullanıcı Sözleşmesi ve Son Kullanıcı Lisans Koşulları | `server/legal/kullanici-sozlesmesi.md` | `terms` | İster (`requires_acceptance: true`) | https://evotomasyon.gudeteknoloji.com.tr/yasal/kullanici-sozlesmesi |
| Gizlilik Politikası ve KVKK Aydınlatma Metni | `server/legal/gizlilik-politikasi.md` | `privacy` | **İstemez** (`requires_acceptance: false`) | https://evotomasyon.gudeteknoloji.com.tr/yasal/gizlilik-politikasi |

Belgeler veritabanında değil, yalnız bu iki dosyadadır. KVKK gereği aydınlatma metni bilgilendirmedir ve hiçbir zaman
onaya ya da rızaya bağlanmaz: sunucu `privacy` belgesinde `requires_acceptance: true` görürse belgeyi yayımlamaz.
Aydınlatma metnine "okudum, onaylıyorum" gibi bir ifade ya da onay kutusu **eklenmez**.

### Dosya biçimi

- UTF-8, **LF** satır sonu.
- Ön bilgi iki `---` satırı arasındadır: `id`, `slug`, `title`, `version` (pozitif tamsayı), `effective_date`
  (YYYY-AA-GG), `status` (`draft` | `final`), `requires_acceptance` (`true` | `false`). `id`, `slug`, `title` ve
  `requires_acceptance` değiştirilmez (sunucu, uygulama ve testler bunlara bağlıdır).
- Gövdede yalnız şu alt küme kullanılır: `# `, `## `, `### ` başlıkları; boş satırla ayrılan paragraflar; `- ` maddeler;
  `1. ` numaralı maddeler; satır içinde yalnız `**kalın**`. HTML, tablo, bağlantı, görsel, kod ve iç içe liste
  **kullanılmaz** (adresler düz metin olarak yazılır; düzenleyicinin MD034 "bare URL" uyarıları bu yüzden bilinçlidir).
- Başlık, sayfada ve uygulamada ön bilgideki `title`'dan gösterilir; bu yüzden gövde `# ` ile başlamaz, bölümler `## `
  ile başlar.
- Her paragraf ve madde **tek satırda** yazılır. İşaretsiz bir satır önceki maddeye eklenir; liste ile ardından gelen
  paragraf arasında boş satır bırakın. Madde ya da paragraf metnini sayıyla başlatmayın (`- 16. bölüm …` standart
  Markdown'da iç içe numaralı liste gibi okunur).
- Ayrıştırıcı ve HTML sayfası: `server/src/utils/legal_markdown.js`. Yükleyici: `server/src/services/legal_service.js`.
- Denetim: `cd server && node --test test/legal/*.test.js`. "GERCEK belge …" testleri iki dosyanın ön bilgisini,
  gövde alt kümesini ve LF satır sonunu sınar.

**Satır sonu uyarısı:** Bu geliştirme makinesinde `core.autocrlf=true` ve depoda `.gitattributes` yok. Dosyalar
Windows'ta git'ten yeniden çekilirse CRLF olur ve "LF satır sonu" testi düşer (sunucu CRLF'yi yine okur).
`.gitattributes` dosyasına `server/legal/*.md text eol=lf` satırının eklenmesi önerilir (bu iş kapsamında eklenmedi).

## 2. Nerede yayımlanır

- **Web (oturumsuz):** `GET /yasal/<slug>` HTML sayfası: başlık, "Sürüm N · Yürürlük: GG.AA.YYYY" satırı, taslakta
  TASLAK bandı. Çerez ve betik yoktur; yanıt 5 dakika önbelleğe alınabilir (`public, max-age=300`). Bilinmeyen adres
  404 sayfası döner. Canlı nginx bütün yolları Express uygulamasına ilettiği için ek ayar gerekmez.
- **API (oturumsuz):** `GET /api/v1/legal` (liste) ve `GET /api/v1/legal/:id` (`terms`, `privacy` ya da slug;
  bloklarla). Eski `/api/legal…` yolları aynıdır.
- **Kabul:** `POST /api/v1/legal/accept` gövdesi `{ "document": "terms", "version": N }`; kayıtta `accept_terms_version`.
  Her kabul `legal_acceptances` tablosuna (kullanıcı, belge, sürüm, zaman, IP, en çok 255 karakter User-Agent) ve
  `users.terms_version` / `users.terms_accepted_at` alanlarına yazılır (migration `039`).
- **Uygulama:**
  - Kayıt ekranı: zorunlu kutu "Kullanıcı Sözleşmesi'ni okudum ve kabul ediyorum." ve altında kutusuz KVKK bilgi satırı.
  - Giriş ekranının alt bağlantıları: "Kullanıcı Sözleşmesi" · "Gizlilik ve KVKK".
  - Profil penceresi → "Hakkında" → "Yasal Metinler" ve "Cihaz & Sistem Ayarları" → "Hakkında" kartı. "Açık Kaynak
    Lisansları" da buradadır.
  - Sözleşme `final` iken bulut girişinden sonra tam ekran onay: "Kabul Ediyorum" / "Çıkış Yap".
- Sunucu dosyaları **açılışta bir kez** okur: metin değişikliği ancak dağıtımla (yeniden başlatma) yayına girer. Dosya
  eksik ya da geçersizse açılış günlüğüne `[LEGAL]` satırı düşer (metnin kendisi günlüğe yazılmaz).
- **Dağıtım uyarısı:** `server/legal/` klasörü sunucuya `server/` ile birlikte gitmelidir. Dosyalar sunucuda yoksa
  sunucu yine açılır, ancak `/yasal/...` 404 verir, liste boş döner ve **uygulamadan yeni kayıt yapılamaz** (kayıt
  ekranı sözleşme sürümünü alamadığında kaydı göndermez).

## 3. Sürüm kuralı

1. Metinde yapılan **her değişiklik** (yazım düzeltmesi dahil) `version` değerini 1 artırır ve `effective_date`
   değerini yeni yürürlük tarihine çeker.
2. Yayımlanan her sürümün metni bulunabilir tutulmalıdır (etiketli commit ya da arşiv klasörü). Sözleşme, kullanıcının
   kabul ettiği sürümü isterse e-postayla gönderileceğini söyler.
3. `status: draft` iken sayfada ve uygulamada TASLAK bandı görünür. Kayıt yine güncel sözleşme sürümünün kabulüyle
   yapılır, ama girişte kimseye onay ekranı gösterilmez (`needs_acceptance` her zaman `false`).
4. `status: final` yapıldığında, küresel rolü personel olmayan (yani `super_user` ve `service_user` dışındaki) **her
   kullanıcı**, hiç kabul etmemişse ya da kabul ettiği sürüm güncelden küçükse, bulut girişinden sonra güncel sözleşmeyi
   **bir kez** onaylar. Personel, servis PIN oturumu ve yerel ağ (LAN) kipi bu ekranı görmez.
5. **Final sözleşmede her sürüm artışı bütün kullanıcılardan yeniden onay ister.** Değişiklikleri toplayıp birlikte
   yayımlayın.
6. **İlk final sürüm `version: 2` olmalıdır.** Taslak sürüm 1'i kayıtta onaylamış kullanıcılara, sürüm 1 aynı numarayla
   final yapılırsa yeniden sorulmaz (kabul edilen sürüm güncel sürüme eşittir). Yer tutucular doldurulunca metin
   değişeceği için final yayın sürüm 2 ile yapılır ve herkes doldurulmuş metni bir kez onaylar.
7. **Aleyhe önemli değişiklikte 30 gün ön bildirim (Sözleşme 14):** final bir sözleşmede kullanıcının aleyhine önemli
   bir değişiklik yapılacaksa yeni sürüm, dağıtılmadan **en az 30 gün önce** duyurulmalıdır: kayıtlı e-posta
   adreslerine bildirim + uygulama içi duyuru. Onay ekranı yeni sürüm dağıtıldığı anda çıktığı için bildirim
   dağıtımdan önce yapılır. Mevzuat, mahkeme/idari karar ya da acil güvenlik değişikliklerinde süre kısalabilir; gerekçe bildirilir.
   Sözleşme, değişikliği kabul etmeyen kullanıcıya ücretli dönem varsa kullanılmayan bedelin iadesini vaat eder.
8. Gizlilik Politikası ve KVKK Aydınlatma Metni değiştiğinde yalnızca sürüm artar; onay istenmez. Metin, önemli
   değişikliklerin kayıtlı e-posta adreslerine bildirileceğini ve verilerin **yeni bir amaçla** işlenmesinden önce
   ayrıca bilgilendirme yapılacağını söyler (Aydınlatma Tebliği): böyle bir değişiklikte işlemeye başlamadan önce
   kullanıcılara e-posta gönderin.

Değişiklik adımları:

1. Dosyayı düzenleyin; `version` ve `effective_date` değerlerini güncelleyin.
2. `grep -n "DOLDURULACAK" server/legal/*.md` (final için boş çıkmalı).
3. `cd server && node --test test/legal/*.test.js`.
4. Dağıtın. Açılış günlüğünde `[LEGAL]` hatası olmadığını, iki adresin yeni sürümü gösterdiğini ve uygulamadaki
   Yasal Metinler sayfasının açıldığını doğrulayın.

## 4. Yer tutucular (tam liste)

Biçim `[DOLDURULACAK: <açıklama>]`. Listelemek için:

```bash
grep -no "\[DOLDURULACAK: [^]]*\]" server/legal/*.md
```

"Sözleşme" = `kullanici-sozlesmesi.md`, "Aydınlatma" = `gizlilik-politikasi.md`; numaralar bölüm numarasıdır.

| # | Yer tutucu | Nerede | Not |
|---|---|---|---|
| 1 | `[DOLDURULACAK: şirket tam unvanı]` | Sözleşme 1, Aydınlatma 1 | Ticaret sicilindeki unvan |
| 2 | `[DOLDURULACAK: MERSİS no]` | Sözleşme 1, Aydınlatma 1 | |
| 3 | `[DOLDURULACAK: vergi dairesi ve vergi no]` | Sözleşme 1 | |
| 4 | `[DOLDURULACAK: KEP adresi]` | Sözleşme 1, Aydınlatma 1 ve 10 | KVKK başvuru yolu olarak da geçer; Sözleşme 19 "KEP adresimize" der |
| 5 | `[DOLDURULACAK: 18 yaşından küçük aile bireylerinin veli izniyle hesap açıp eve katılıp katılamayacağına ilişkin karar]` | Sözleşme 3, Aydınlatma 11 | Ürün kararı; kodda yaş denetimi yok |
| 6 | `[DOLDURULACAK: Uygulama ve Bulut Hizmeti ücretleri ile ödeme koşulları ya da ücretsiz olduğu]` | Sözleşme 9 | Ücretliyse mesafeli sözleşme ön bilgilendirmesi gerekir |
| 7 | `[DOLDURULACAK: Bulut Hizmetinin sona erdirilmesi için ön bildirim süresi]` | Sözleşme 15.3 | |
| 8 | `[DOLDURULACAK: barındırma hizmet sağlayıcısı]` | Aydınlatma 5.1 | VPS sağlayıcısı repoda geçmiyor |
| 9 | `[DOLDURULACAK: sunucu konumu (ülke)]` | Aydınlatma 5.1 | Yurt dışıysa KVKK m. 9 |
| 10 | `[DOLDURULACAK: e-posta gönderim hizmet sağlayıcısı]` | Aydınlatma 5.1 | SMTP sağlayıcısı (`.env`'de; okunmadı) |
| 11 | `[DOLDURULACAK: varsa yetkili servis firmalarının adları veya nitelikleri]` | Aydınlatma 5.2 | Dış servis firması yoksa cümle sadeleştirilir |
| 12 | `[DOLDURULACAK: yurt dışına aktarımın yapıldığı ülkeler ve KVKK m. 9 kapsamındaki dayanağı]` | Aydınlatma 5.6 | Google Fonts, ML Kit, NTP ve (yurt dışındaysa) barındırma/e-posta |
| 13 | `[DOLDURULACAK: silinmiş hesap kayıtlarının saklama süresi]` | Aydınlatma 6 | Kodda süre yok |
| 14 | `[DOLDURULACAK: oturum ve doğrulama kodu kayıtlarının saklama süresi]` | Aydınlatma 6 | `refresh_tokens`, `password_resets`, kod tabloları; temizlik yok |
| 15 | `[DOLDURULACAK: süresi dolmuş misafir ve kurulum üyeliklerinin saklama süresi]` | Aydınlatma 6 | Temizlik yok |
| 16 | `[DOLDURULACAK: davet ve devir kayıtlarının saklama süresi]` | Aydınlatma 6 | Temizlik yok |
| 17 | `[DOLDURULACAK: servis PIN'i ve servis oturumu kayıtlarının saklama süresi]` | Aydınlatma 6 | Temizlik yok |
| 18 | `[DOLDURULACAK: cihaz, kurulum ve acil sıfırlama kayıtlarının saklama süresi]` | Aydınlatma 6 | Garanti ve ispat süresiyle uyumlu olmalı |
| 19 | `[DOLDURULACAK: alarm geçmişinin saklama süresi]` | Aydınlatma 6 | `alarms` bilerek süresiz (`scheduler.js`) |
| 20 | `[DOLDURULACAK: denetim kayıtlarının saklama süresi]` | Aydınlatma 6 | `device_audit_logs` ve diğer günlük tabloları |
| 21 | `[DOLDURULACAK: sözleşme kabul kayıtlarının saklama süresi]` | Aydınlatma 6 | `legal_acceptances`; hesap silmede kalır |
| 22 | `[DOLDURULACAK: site ve toplu kurulum kayıtlarının saklama süresi]` | Aydınlatma 6 | Yumuşak silme; sorumlu bilgileri kalır |
| 23 | `[DOLDURULACAK: sunucu erişim kayıtları ve uygulama günlüklerinin saklama süresi]` | Aydınlatma 6 | nginx, PM2, EMQX dosya günlükleri |
| 24 | `[DOLDURULACAK: yedeklerin saklama süresi]` | Aydınlatma 6 | Yedekler elle alınıyor, şifresiz, süresiz |
| 25 | `[DOLDURULACAK: başvuru ve destek yazışmalarının saklama süresi]` | Aydınlatma 6 | |
| 26 | `[DOLDURULACAK: periyodik imha aralığı]` | Aydınlatma 6 | Saklama ve imha politikasıyla aynı olmalı; Silme/İmha Yönetmeliği'ndeki üst sınırı aşmamalı (imha politikası hazırlayan veri sorumlusu için en çok 6 ay) |
| 27 | `[DOLDURULACAK: idari tedbirler (personel gizlilik taahhütleri, eğitim, yetki gözden geçirme, veri işleyen sözleşmeleri)]` | Aydınlatma 8 | Yalnız gerçekten uygulananlar yazılmalı |

**Saklama sürelerine dikkat:** 13-26 numaralı yer tutuculara yazılan her süre **gerçekten uygulanmalıdır**. Bugün bu
kayıtlar için kodda temizlik işi yoktur; süre yazılmadan önce temizlik işi yazılmalı ya da süre "hesap/ev sürdükçe"
gibi gerçek davranışa uygun ifade edilmelidir.

## 5. Yürürlüğe almadan önce (kontrol listesi)

- [ ] Bütün yer tutucular dolduruldu (`grep` boş).
- [ ] Yazılan her saklama süresi bir temizlik işiyle uygulanıyor. Metnin "otomatik silinir" dediği 30 ve 90 günlük
      temizliklerin üretimde gerçekten çalıştığı doğrulandı: `scheduled_rule_runs` ve `device_events` temizliği yalnız
      zamanlayıcı çalışırken, `peace_notification_logs` temizliği yalnız gece hatırlatması açıkken ve `DRY_RUN`
      kapalıyken koşar.
- [ ] Yurt dışı aktarımın KVKK m. 9 dayanağı belirlendi ya da aktarım kaldırıldı (Bölüm 6, madde 2-4 ve 27).
- [ ] Barındırma ve e-posta sağlayıcılarıyla veri işleme sözleşmesi yapıldı.
- [ ] VERBİS kayıt yükümlülüğü değerlendirildi; gerekiyorsa kişisel veri saklama ve imha politikası hazırlandı ve
      aydınlatma metni VERBİS kaydıyla uyumlu hâle getirildi.
- [ ] Personel erişimi için kurallar ve kayıt (Bölüm 6, madde 25-26) netleşti; metin buna göre güncellendi.
- [ ] Uygulama metinleri metinlerle uyumlu hâle getirildi (Bölüm 6, madde 12).
- [ ] Aleyhe değişikliklerde 30 gün ön bildirim (Bölüm 3, madde 7) ve önemli değişikliklerde e-posta süreci hazır.
- [ ] **Avukat incelemesi** (iki metin, bu README'deki kararlarla birlikte).
- [ ] `version: 2`, `status: final`, yeni `effective_date`; testler; dağıtım; iki adres ve uygulama doğrulandı.

## 6. Şirketin vermesi gereken kararlar

1. **Şirket kimliği:** unvan, MERSİS no, vergi dairesi ve no, KEP adresi; VERBİS kaydı gerekip gerekmediği.
2. **Barındırma ve e-posta sağlayıcıları:** adları, sunucu ülkesi; yurt dışındaysa KVKK m. 9 mekanizması (yeterlilik
   kararı, Kurula beş iş günü içinde bildirilen standart sözleşme, bağlayıcı şirket kuralları ya da taahhütname).
3. **Google Fonts:** Uygulama Inter yazı tipini çalışma anında Google'dan indiriyor; telefonun IP adresi Google'a gidiyor
   (`pubspec.yaml` `google_fonts`, `lib/ui/theme/app_theme.dart`; PF-14 kararı bekliyor). Öneri: yazı tipini pakete
   gömüp çalışma anında indirmeyi kapatmak; ardından Aydınlatma 5.6'daki madde kaldırılır (sürüm artışıyla).
4. **NTP:** Pano `pool.ntp.org`, `time.google.com` ve `time.cloudflare.com` sunucularına bağlanıyor ve evin internet IP
   adresi bu sunuculara gidiyor (`waveshare_s3_demo/src/WiFiManager.cpp`). Seçenekler: yurt içi bir zaman sunucusuna
   geçmek ya da metindeki açıklamayı ve m. 9 değerlendirmesini korumak.
5. **Saklama süreleri ve temizlik işleri:** Bölüm 4'teki 13-26 numaralı süreler ve bunları uygulayacak işler.
6. **Yedekler:** Yedekler elle, aynı sunucuda (`~/backup`), şifresiz ve süresiz tutuluyor (`docs/DEPLOY_RUNBOOK.md`).
   Saklama süresi, şifreleme ve silinen verinin yedekten düşme süresi belirlenmeli.
7. **18 yaş altı aile bireyleri:** Veli izniyle hesap açıp eve katılabilirler mi? Kodda yaş denetimi yok.
8. **Ücret:** Uygulama ve Bulut Hizmeti ücretsiz mi, ücretliyse koşullar ve mesafeli sözleşme belgeleri. Sözleşme 14,
   yeni sürümü kabul etmeyen kullanıcıya önceden ödenmiş ve kullanılmamış dönemin bedelinin iadesini vaat eder.
9. **Bulut Hizmetinin sona erdirilmesi:** ön bildirim süresi.
10. **Yetkili dış servis firmaları** var mı; varsa aydınlatma metninde alıcı olarak adları veya nitelikleri.
11. **Yetkili mahkeme:** Sözleşme 18 yetki şartını yalnız tacir ve kamu tüzel kişisi kullanıcılar için koyar
    ("İzmir Mahkemeleri ve İcra Daireleri"; HMK m. 17 yetki sözleşmesine yalnız bunlar arasında izin verir). Tüketiciler
    için hakem heyeti ve tüketici mahkemesi, diğerleri için kanuni yetki geçerlidir. İzmir'in (şirket Karşıyaka'da)
    seçimi onaylanmalı.
12. **Uygulama metinleri ile çelişki:** Hesap silme penceresi "Hesabınız, kişisel verileriniz ve … kalıcı olarak silinir"
    diyor; gerçek davranış anonimleştirme ve bazı kayıtların saklanmasıdır (Aydınlatma 7 bunu anlatıyor). Pencere ayrıca
    "SMS ile giriş" diyor, oysa üretimde SMS sağlayıcısı yok. Pencere metni düzeltilmeli
    (`lib/ui/pages/auth/delete_account_dialog.dart`; bu iş kapsamında değiştirilmedi).
13. **Alarm geçmişi devirde kalıyor:** Daire devrinde alarm geçmişi silinmiyor ve yeni sahip görüyor
    (`server/src/services/home_cleanup.js`). Metin bunu açıkça yazıyor; ürün kararıyla değişirse metin güncellenir.
14. **Üye iletişim bilgileri:** Misafir dışındaki herkes (o evde kurulum süresi devam eden servis personeli dahil) diğer
    üyelerin e-posta adresini ve telefonunu görüyor (`invitation_service.js` `getHomeMembers`). Metin bunu açıkça
    yazıyor; kısıtlanırsa metin güncellenir.
15. **Düzeltme ve erişim hakkı:** Kullanıcı adını, telefonunu ve e-postasını değiştiremiyor; e-postayı yönetici de
    değiştiremiyor (`admin_user_service.js`). Veri dışa aktarma yok. Metin "bize başvurun" diyor; bu başvuruları
    karşılayacak bir yöntem (elle süreç ya da uç) gerekir.
16. **Personelin açtığı hesaplar (KVKK m. 10):** Hesap etkinleştirme ve kurulum onayı e-postalarına aydınlatma metninin
    adresinin eklenmesi önerilir; veri kişinin kendisinden alınmadığında aydınlatma ilk iletişimde yapılmalıdır.
17. **Hesapsız Yerel Mod:** Uygulamayı yalnız Yerel Modda kullananlar sözleşmeyi uygulama içinde onaylamıyor (yalnız
    giriş ekranındaki bağlantıdan okuyabiliyor). TBK m. 21 gereği onaylanmayan genel işlem koşulları bağlamaz; Sözleşme 3
    bu yüzden bu kullanıcılardan yalnız uymalarını "rica eder". Sözleşmenin ilk açılışta gösterilip onaylatılıp
    onaylatılmayacağı karar verilmeli.
18. **Push ve SMS:** FCM push bugün kapalı (uygulamada Firebase yok). Açılırsa ev adı, oda adları ve alarm türü Google'a
    (ABD) gider; SMS sağlayıcısı eklenirse o da alıcı olur. Her iki durumda metinler önceden güncellenmelidir.
19. **Google ve Apple ile giriş:** Üretimde açık olup olmadıkları doğrulanamadı (`GOOGLE_CLIENT_IDS`,
    `APPLE_CLIENT_IDS`); metin koşullu yazıldı ("giriş yaptıysanız").
20. **5651 sayılı Kanun:** Erişim günlüğü tutma yükümlülüğü ve nginx günlük biçimi/süresi hukuken değerlendirilmeli.
21. **Ev ağındaki anahtarsız erişim (guvenlik-14):** Ethernet'e bağlı panoda ev ağındaki herkes panoyu anahtarsız tam
    yetkiyle yönetebiliyor. Önceki taslak bunu "erişmeyi deneyebilir" diye hafifletiyordu; metinler artık açığın
    ayrıntısını vermeden doğruyu söylüyor: "kurulum biçimine bağlı olarak ev ağınıza bağlanabilen herkes Panoyu yerel
    ağ üzerinden kontrol edebilir" (Sözleşme 5.7, Aydınlatma 8) ve anahtar değişiminin çıkarılan kişinin ev ağına
    bağlanmasını engellemediğini (Sözleşme 5.6). Açık kapatılırsa ifade yumuşatılabilir (sürüm artışıyla).
22. **Pano yazılımı açık kaynak bildirimi:** Sözleşme, Pano yazılımındaki açık kaynak bileşenlerin listesinin ve
    lisanslarının e-postayla verileceğini söylüyor; bu liste hazırlanmalı.
23. **App Store:** Uygulama iOS'ta yayımlanacaksa Apple'ın özel son kullanıcı lisansı için istediği asgari maddeler
    gözden geçirilmeli.
24. **Önceki sürümlerin arşivi** ve önemli değişikliklerde kullanıcılara e-posta gönderme süreci (iki metin de bunu
    vaat ediyor).
25. **Yönetici (süper kullanıcı) erişimi:** `super_user` üyelik olmadan **her evin** anlık durumunu, alarm geçmişini ve
    üye listesini görebiliyor; röle/panjur komutu gönderebiliyor, zamanlı kuralları yönetebiliyor, üyeleri
    çıkarabiliyor (`auth_middleware.requireHomeAccess`, `role_matrix.js`, CONTRACTS §1.4). Röle komutları denetim
    kaydına yazılmıyor. Metinler bunu açıkça yazıyor (Sözleşme 6, Aydınlatma 5.2). Karar: bu erişimin iç kuralı
    (yalnız destek talebiyle, kimin ne zaman eriştiği) ve yönetici komutlarının denetim kaydına yazılması.
26. **Servis personelinin erişimi:** servis sorumlusu kendi açtığı müşteri hesaplarını **süresiz** görüp ad, telefon,
    not ve hesap durumunu değiştirebiliyor (`admin_user_service.js` `staffCanSee`); kurulumdan sonraki 72 saatte
    panonun yerel anahtarını okuyabiliyor ve bu anahtar 72 saat bitince **değişmiyor** (`local_key_rotation.js`
    tetikleyicilerinde kurulum üyeliğinin bitişi yok). Metinler bunu açıkça yazıyor. Öneri: kurulum üyeliği bitince de
    anahtar değişsin; personelin süresiz hesap görünürlüğü gerekiyorsa gerekçelendirilsin.
27. **ML Kit (Android karekod):** `mobile_scanner` Android'de Google ML Kit'i (paket içi model) kullanıyor; ML Kit
    koşullarına göre kullanım ve performans ölçümlerini Google'a gönderiyor. Aydınlatma 5.6'ya eklendi. Google'ın
    güncel "ML Kit data disclosure" sayfasıyla gönderilen veriler doğrulanmalı ve m. 9 değerlendirmesine katılmalı.
28. **Ev sahibinin bölge testi:** sunucu `safety_test` yetkisini ev sahibine veriyor ama uygulamada ev sahibine açık bir
    bölge testi ekranı yok (yalnız servis kurulum sihirbazının 7. adımı). Önceki taslak "Ev Sahibi Bölge Testi ile
    sınayabilir" diyordu; düzeltildi (Sözleşme 7: bölge testini Yetkili Servis yapar). Ekran eklenirse metin
    güncellenir.
29. **Pano yazılımı lisansı:** Sözleşme 4 ve 15.4, Pano yazılımını kullanma hakkının Panoya bağlı olduğunu, Pano
    devredilince yeni sahibe geçtiğini ve hesap silinse de sürdüğünü söyler (satın alınan donanımın kullanılabilmesi).
    Onaylanmalı.
30. **Uygulama adı:** Metinler "AHBU Ev Otomasyonu" der (`AppConfig.appDisplayName`); Android başlatıcı etiketi
    `ev_otomasyon`, iOS görünen adı "Ev Otomasyon". Mağaza yayınından önce adlar birleştirilmeli.

## 7. Metinlerin dayandığı kod davranışları

Aşağıdaki davranışlardan biri değişirse ilgili metin güncellenmeli ve sürümü artırılmalıdır.

| Metindeki ifade | Kaynak |
|---|---|
| Aile Üyesi daveti 24 saat, tek kullanım; Misafir en çok 72 saat | `server/src/services/invitation_service.js` |
| Daire devir kodu 48 saat, yalnız hedef e-posta/telefonun sahibi kullanır; devirde bütün üyelikler kalkar | `server/src/services/transfer_service.js` |
| Devirde kurallar, davetler ve gece kayıtları silinir; servis PIN'leri ve oturumları iptal edilir; alarm geçmişi kalır | `server/src/services/home_cleanup.js` |
| Servis PIN'i 6 hane, tek kullanım, 2 saat, yalnız o ev; yalnız Ev Sahibi üretir | `server/src/services/service_token_service.js`, `server/src/routes/service_routes.js` |
| Erişim belirteci 15 dakika, yenileme en çok 30 gün; kodlar en çok 72 saat (sıfırlama 15 dk, etkinleştirme 72 saat) | `server/src/middlewares/jwt_config.js`, `server/src/services/auth_service.js` |
| Yerel anahtar yalnız tek panolu evde değişir (üye çıkarma, devir, Ev Sahibi ataması, hesap silme, servis oturumu); kurulum üyeliğinin bitişinde değişmez | `server/src/services/local_key_rotation.js` |
| Hesap silme: silinen, iptal edilen, anonimleştirilen ve kalan kayıtlar | `server/src/services/account_deletion_service.js` |
| Hesap silme yolu ve düğme adları | `lib/ui/dashboard/dashboard_app_bar.dart`, `lib/ui/widgets/user_profile_dialog.dart`, `lib/ui/pages/auth/delete_account_dialog.dart`, `lib/ui/widgets/settings/info_cards.dart` |
| 30 ve 90 günlük temizlikler; alarmlar süresiz | `server/src/scheduler.js`, `server/src/peace_reminder.js` |
| Uygulama MQTT kimliği en çok 12 saat, yalnız okuma | `server/src/services/mqtt_credential_service.js`, `server/migrations/020_mqtt_credentials.sql` |
| IP/giriş bilgisine bağlı deneme sayaçları bellekte, en çok 60 dakika; kod/PIN deneme sayıları kod kaydında | `server/src/middlewares/rate_limit.js` ve rota sınırlayıcıları, `password_resets.attempts` |
| Kabul kaydı alanları (sürüm, zaman, IP, User-Agent) | `server/migrations/039_legal_acceptances.sql`, `server/src/services/legal_service.js` |
| Üye listesinde kim neyi görür; servis PIN oturumu üye listesini göremez | `server/src/services/invitation_service.js` (`getHomeMembers`), `server/src/routes/invitation_routes.js` |
| Yönetici her evi üyeliksiz görür ve komut gönderir; hırsız alarmını kuramaz. Yönetici ve servis personeli `GET /admin/inventory/:uuid/local-key` ile müşteri panoları dahil her panonun yerel anahtarını süresiz okur (sahip kararı 6, 2026-10-09; denetim kaydı + oran sınırı) | `server/src/routes/site_template_routes.js`, `server/src/services/site_template_service.js`, `server/src/middlewares/auth_middleware.js` (`requireHomeAccess`), `server/src/utils/role_matrix.js`, `docs/CONTRACTS.md` §1.4 |
| Servis personeli 72 saat ev erişimi (yerel anahtar dahil); envanter ucundan her panonun yerel anahtarını süresiz okur (karar 6); kendi açtığı hesapları süresiz görür | `server/src/services/device_service.js`, `server/src/services/service_panel_service.js`, `server/src/services/admin_user_service.js` |
| Ev Sahibi kurulum personelinin üyeliğini erken kaldırabilir | `server/src/services/invitation_service.js` (`removeHomeMember`), `lib/ui/pages/family/family_members_page.dart` |
| Misafir ve servis rollerinin sınırları; hırsız alarmı; gaz vanası | `server/src/utils/role_matrix.js`, `docs/CONTRACTS.md` §1.4 ve §2.6 |
| Bölge testi yalnız servis sihirbazında (ev sahibine ekran yok) | `lib/ui/pages/service_setup/logic/relay_logic.dart`, `lib/services/automation_state.dart` (`testZone` çağıranı yok) |
| Alarm bildirimi yalnız Android, Ev Sahibi ve Aile Üyesi, bulut oturumu açıkken; iOS'ta yok | `lib/services/alarm_watch/`, `docs/akislar/DAIRE_KULLANICISI_AKISI.md` §7.6 |
| Pano alarmı, vanayı ve sireni internetsiz yönetir; duman vana kapatmaz | `docs/akislar/DAIRE_KULLANICISI_AKISI.md` §7.4, `docs/CONTRACTS.md` §2.6 |
| Pano yazılımı uzaktan güncellenmez (yalnız USB) | `docs/akislar/SERVIS_SORUMLUSU_AKISI.md` §7 ve §9 |
| Ev ağına bağlanan herkes kurulum biçimine göre panoyu kontrol edebilir (Ethernet anahtarsız) | `docs/akislar/SERVIS_SORUMLUSU_AKISI.md` §7 madde 4, `docs/akislar/DAIRE_KULLANICISI_AKISI.md` §10 |
| Kalıcı (mandallı) duvar anahtarı desteklenmez | `ev_otomasyon_servis_yazilimi/EV_OTOMASYON_KULLANIM_REHBERI.md` |
| Google Fonts çalışma anında indirilir | `pubspec.yaml`, `lib/ui/theme/app_theme.dart` |
| Android karekod okuma Google ML Kit (paket içi) | `pubspec.yaml` (`mobile_scanner`), `android/gradle.properties` (`useUnbundled` yok) |
| Pano NTP sunucuları | `ev_otomasyon_servis_yazilimi/waveshare_s3_demo/src/WiFiManager.cpp` |
| Çerez yok; analitik ve çökme raporlama yok; konum izni yok | `server/src`, `server/nginx` (eşleşme yok), `pubspec.yaml`, `android/app/src/main/AndroidManifest.xml`, `ios/Runner/Info.plist` |
| Ev Wi-Fi şifresi uygulamada ve sunucuda saklanmaz | `lib/services/automation_api_service.dart`, `lib/services/automation_state.dart`; sunucuda eşleşme yok |
| Bulut iletişimi TLS 1.2/1.3; yerel mod düz HTTP (`X-Device-Key` başlığı) | `server/nginx/evotomasyon.gudeteknoloji.com.tr.conf`, `server/emqx_config/emqx.conf`, `lib/services/automation_api_service.dart` |
| bcrypt, HMAC, SHA-256, AES-256-GCM | `server/src/services/auth_service.js`, `server/src/utils/pin.js`, `server/migrations/018_auth_hardening.sql`, `server/migrations/021_device_security_hardening.sql` |
| Telefonda güvenli depo; yedeğe gitmez; çıkışta silinir | `lib/services/secure_storage_service.dart` (iOS `first_unlock_this_device`), `android/app/src/main/AndroidManifest.xml` (`allowBackup=false`) |

## 8. 2026-10-09 incelemesinde düzeltilenler (özet)

- **Kodla çelişen iddialar:** "Ev Sahibi Bölge Testi ile sınayabilir" (ekran yok), "kurulum personeli bilgileri
  yalnız 72 saat görür" (kendi açtığı hesapları süresiz görür), "devirde servis PIN'leri silinir" (iptal edilir),
  "doğrulama kodları 15 dakika ile 72 saat" (kodlar en çok 72 saat), "gaz vanası yalnızca yerinde açılır" (mutlak
  ifade kaldırıldı; uygulamadan açılamadığı korunuyor), "erişmeyi deneyebilir" (ev ağındaki erişim hafife alınıyordu).
- **Açıklanmayan veri erişimi:** yöneticinin her eve üyeliksiz erişimi ve komut yetkisi, servis personelinin yerel
  anahtarı görmesi, ML Kit'in Google'a ölçüm göndermesi metinlere eklendi.
- **KVKK:** toplama yöntemlerine "otomatik olmayan" yol, teknik işletim ve hata giderme amacı (hukuki sebebiyle), yeni
  amaç öncesi bilgilendirme, başvuruda "telefon ve faks", hatalı ücretin iadesi, silme talebine 30 gün eklendi.
- **Tüketici hukuku:** "geri alınabilir" lisans kaldırıldı; Pano yazılımı hakkı Panoya bağlandı ve sona ermeden
  etkilenmez yapıldı; kod paylaşımında kusursuz sorumluluk "kanun hükümlerine göre" yapıldı; aleyhe değişiklikte 30 gün
  ön bildirim, ücretsiz fesih ve iade; aleyhe hizmet değişikliğinde fesih hakkı; ayıplı hizmet ve 7223 ürün
  sorumluluğu saklı tutuldu; HMK 193 "delil sözleşmesi" ifadesi kaldırıldı (kayıtlar kesin delil değildir); yetki şartı
  HMK 17'ye uyduruldu; hesapsız Yerel Mod kullanıcısını onaylamadığı koşullarla bağlayan ifade kaldırıldı; tesisat
  işleri için "yalnız Yetkili Servis" zorunluluğu "Yetkili Servis veya yetkili elektrikçi" yapıldı.
- **Güvenlik bölümü:** yaşamsal cihazları kumandalı prizlere bağlamama, dedektör değişim süresi, bildirimin oturum açık
  olmasını gerektirdiği eklendi.
