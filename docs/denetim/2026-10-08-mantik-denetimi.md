# Mantık Denetimi — 2026-10-08

> Kaynak: 8 alanlı denetim iş akışı (28 ajan). Bulgular kodla doğrulandı (adversarial), düzeltmeler bileşen bazında
> TDD ile yapıldı ve ayrıca gözden geçirildi. Bu dosya iş akışı çıktısından betikle üretildi (elle yazılmadı).

**Özet:** 92 doğrulanmış bulgu, 1 belirsiz, 6 çürütülmüş.

Önem dağılımı: yüksek 11, orta 34, düşük 47

## Bulgular ve durumları

| # | Önem | Başlık | Roller | Durum |
|---|---|---|---|---|
| atolye-1 | yüksek | Birleşik imajla güncelleme NVS'i siliyor; araç kartı yeniden provizyonlayamıyor | super_user, service_user, owner (bireysel kullanıcı) | Düzeltildi: servis yazılımı |
| atolye-2 | yüksek | Etiket yeniden üretimi yerel anahtarı yalnız sunucuda değiştiriyor | super_user, service_user, service_session, owner (bireysel kullanıcı) | Düzeltildi: uygulama, sunucu, servis yazılımı |
| ev_uyelik-1 | yüksek | PIN ile servis girisi: kullanici ve kimlik basina deneme sayaci yok, yalniz IP basina 10/15dk | service_session, owner | Düzeltildi: sunucu |
| kullanim-1 | yüksek | Yerel (LAN) modda uygulama yeniden açılınca aktif ev seçilmiyor: tüm komutlar 'yetkiniz yok', anahtar bulunamıyor, buluta dönüş düğmesi gizli | owner, resident, service_user, super_user, bireysel kullanıcı | Düzeltildi: uygulama |
| kullanim-2 | yüksek | Alarm bildirimine dokununca canlı durum beklenmeden karar veriliyor: süren alarm için 'Bu alarm kapanmış' gösteriliyor | owner, resident, bireysel kullanıcı | Düzeltildi: uygulama |
| kullanim-4 | yüksek | Pano değişiminde zamanlı kurallar eski cihaza bağlı kalıyor: kurallar sessizce hiç çalışmıyor ve düzenlemeyle düzeltilemiyor | owner, resident, service_user, service_session, super_user | Düzeltildi: sunucu |
| pano-1 | yüksek | Yalnız sensörlü güvenlik kurulumunda kilitli alarmla yeniden başlayan pano güvenli kipten (latch_orphan) çıkamıyor | owner, resident, service_user, service_session, individual | Düzeltildi: firmware |
| pano-2 | yüksek | Ethernet'ten /api/auth/check her anahtara 200 dönüyor, tam durum 'provisioned:true' diyor: provizyonsuz ya da yanlış anahtarlı pano Ethernet kurulumunda fark edilmiyor | service_user, service_session, super_user | Düzeltildi: uygulama, firmware, servis yazılımı (servis_kurulum-1 ile birleştirildi) |
| servis_kurulum-1 | yüksek | Ethernet yolu provizyonsuz panoyu hazırlamadan teslim ediyor; açık kurulum ağı ve korumasız factory/init kalıcı kalıyor | service_user, super_user, service_session | Düzeltildi: uygulama, firmware, servis yazılımı |
| servis_kurulum-2 | yüksek | Başarısız vana/bölge testi kayda yazılmıyor; kayıttan devamda 7. adım tamamlanmış sayılıyor | service_user, super_user, service_session | Düzeltildi: uygulama |
| uyelik-1 | yüksek | Doğrulanmamış, önceden açılmış hesap servis kurulumunda/atamada ev sahibi yapılıyor (ön-hesap ele geçirme) | bireysel kullanıcı (saldırgan), service_user, super_user, owner (müşteri) | Düzeltildi: uygulama, sunucu |
| atolye-3 | orta | Ethernet provizyonunda 'doğrulandı' sahte; eski anahtarlı kart fark edilmiyor | super_user, service_user, owner | Düzeltildi: uygulama, firmware, servis yazılımı (servis_kurulum-1 ile birleştirildi) |
| atolye-5 | orta | Röle tipi değişince güvenlik cihazı ve dimmer sessizce siliniyor | super_user, service_user, owner, resident | Düzeltildi: servis yazılımı |
| atolye-6 | orta | Atölyede NC sensörlü şablon yazılınca kart hemen alarma kilitleniyor | super_user, service_user, service_session, owner | Düzeltildi: servis yazılımı |
| atolye-7 | orta | Daire durumu ve 'Son yazım' karta/şablona bağlı değil; 'Yazıldı' yanıltıyor | super_user, service_user, owner | Düzeltildi: sunucu, servis yazılımı |
| atolye-8 | orta | Pano değişiminde site dairesinin kart bağlantısı eskide kalıyor | super_user, service_user, service_session, owner | Düzeltildi: sunucu, servis yazılımı |
| bireysel-1 | orta | Fabrika aracı hâlâ v1.2.1 seçiyor: bootstrap'sız panoda bireysel sahiplenme buluta hiç bağlanmıyor, uygulama aksini söylüyor | bireysel kullanıcı (user→owner), owner | Düzeltildi: uygulama, servis yazılımı |
| bireysel-10 | orta | Kendi kuran ev sahibi kanal adı/oda ve panjur süresini değiştiremiyor (sunucu ve yetki var, ekran yok) | owner, bireysel kullanıcı | Düzeltildi: uygulama |
| bireysel-2 | orta | Yalnız misafir üyeliği olan kullanıcı kendi panosunu sahiplenemiyor (uygulama engelliyor, sunucu izin veriyor) | guest, bireysel kullanıcı | Düzeltildi: uygulama |
| bireysel-4 | orta | Ev sahibinin pano değişiminden sonra 'Yeni Panoyu Şimdi Bağla' yetkisiz sihirbaza götürüyor | owner, bireysel kullanıcı | Düzeltildi: uygulama |
| bireysel-5 | orta | Girişsiz yerel mod çıkmaz: IP/anahtar kartı gizli, Ethernet'te anahtarsız erişim de kullanılamıyor | girişsiz kullanıcı, bireysel kullanıcı, owner, resident | Düzeltildi: uygulama |
| bireysel-6 | orta | Bootstrap kart başı hız sınırı imzasız isteklerle tüketiliyor ve 202 yoklama hızına eşit (yeniden başlatma 30 dk ceza) | bireysel kullanıcı, owner, saldırgan (kimliksiz) | Düzeltildi: sunucu |
| bireysel-8 | orta | Etiket yeniden üretimi yerel anahtarı panoya iletmeden değiştiriyor; yeni etikette AP parolası yok | super_user, bireysel kullanıcı | Düzeltildi: uygulama, sunucu, servis yazılımı (atolye-2 ile birleştirildi) |
| bireysel-9 | orta | Etiket karekodu telefon kamerasıyla açılınca uygulama yerine tarayıcıda 404; PIN nginx günlüğüne düşüyor | bireysel kullanıcı, girişsiz kullanıcı | Düzeltildi: sunucu |
| guvenlik-1 | orta | Pano değişimi / acil sıfırlamada eski panonun açık alarm kayıtları hiç kapanmıyor | owner, resident, service_user, service_session, super_user | Düzeltildi: uygulama, sunucu |
| guvenlik-2 | orta | Kritik alarm kartı 'ıslak' hesabına kapı/pencere/hareket sensörlerini katıyor; onay düğmesi kayboluyor | owner, resident, service_user, service_session, super_user | Düzeltildi: uygulama |
| guvenlik-4 | orta | Sihirbaz çevrimdışı panoda planı bayat kopyadan yeniden üretip kuyruğa ekliyor; yanlış vana silinebiliyor | service_user, service_session, super_user | Düzeltildi: uygulama, sunucu |
| guvenlik-5 | orta | Servis oturumunun kuyruğa aldığı güvenlik yamaları oturum iptal edilse de uygulanıyor | service_session, owner | Düzeltildi: sunucu |
| guvenlik-6 | orta | Çok panolu evde bir panonun LWT'si diğer panoyu çevrimdışı yapıyor, state birleştirmesi diğer panonun state'ini yutuyor | owner, resident, guest, service_user, service_session, super_user | Düzeltildi: firmware, sunucu |
| kullanim-3 | orta | Yerel modda ev değiştirince önceki evin panosu (IP + anahtar) kullanılmaya devam ediyor: komut ve durum yanlış eve ait | owner, resident, bireysel kullanıcı (iki evli), guest (ikinci ev misafirse) | Düzeltildi: uygulama |
| kullanim-5 | orta | Servis sorumlusunun kurduğu zamanlı kurallar 72 saat sonra sessizce duruyor, listede etkin görünüyor | service_user, owner, resident | Düzeltildi: uygulama, sunucu |
| kullanim-6 | orta | Servis PIN oturumunda uygulama arka plandan dönünce canlı (MQTT) bağlantı yeniden kurulmuyor | service_session | Düzeltildi: uygulama |
| kullanim-7 | orta | Giriş yapmadan 'Yerel ağ modu' çıkmaz sokak: IP/anahtar alanı hiç görünmüyor, elle girilen anahtar saklanmıyor (bilinen madde 5 hâlâ açık) | giriş yapmamış daire kullanıcısı, bireysel kullanıcı | Düzeltildi: uygulama (bireysel-5 ile birleştirildi) |
| kullanim-8 | orta | Servis erişimi kapatıldığında ya da servis üyeliği bittiğinde canlı MQTT izlemesi sürüyor | service_session, service_user, owner | Düzeltildi: sunucu (uyelik-6 ile birleştirildi) |
| pano-4 | orta | Ek modül kanal sayısı artırılınca yeni DI'ler başlatılmıyor: NC gaz/duman sensörü ilk turlarda 'açık' okunup sahte alarm üretiyor | service_user, super_user, owner, resident | Düzeltildi: firmware |
| pano-5 | orta | set_local_key panoda doğrulanmadan sunucuda kesinleşiyor: pano eski anahtarla kalırsa bootstrap ve yerel erişim kalıcı kopuyor | service_user, super_user, owner | Düzeltildi: firmware, sunucu |
| pano-6 | orta | Erişim bitince yerel anahtar değişmiyor: geçici servis (PIN) ve evden çıkarılan üye panoyu süresiz yerelden yönetebiliyor | service_session, resident, service_user | Düzeltildi: uygulama, sunucu |
| servis_kurulum-3 | orta | Motorlu panjuru olmayan dairede 8. adım dürüstçe tamamlanamıyor (varsayılan yerleşimde 2 panjur çifti var) | service_session, service_user, super_user | Düzeltildi: uygulama |
| servis_kurulum-4 | orta | Ev sahibi pano değişiminden sonra 'Yeni Panoyu Şimdi Bağla' ile kendisini reddeden sihirbaza yönleniyor; tek seferlik kimlik kayboluyor | owner, super_user | Düzeltildi: uygulama (bireysel-4 ile birleştirildi) |
| servis_kurulum-6 | orta | Yalnız panjur rölesi olan panoda 7. adım hiç tamamlanamıyor | service_user, super_user, service_session | Düzeltildi: uygulama |
| uyelik-15 | orta | Servis PIN'i küresel 6 haneli ve yalnız IP başına sınırlı: dağıtık denemeyle rastgele bir evde 2 saatlik servis oturumu açılabilir | service_session, owner | Düzeltildi: sunucu (ev_uyelik-1 ile birleştirildi) |
| uyelik-2 | orta | Yenileme yanıtı kaybolunca eski refresh token 'yeniden kullanım' sayılıp tüm oturum ailesi iptal ediliyor (rastgele çıkışlar, alarm servisi ölür) | owner, resident, guest, bireysel kullanıcı, service_user, super_user | Düzeltildi: sunucu |
| uyelik-3 | orta | Güvenli depo yazım hatası yutulduğu için _storedRefreshSeen yanlış güncelleniyor; sonraki yenileme depodaki eski token'ı benimseyip aileyi iptal ettiriyor | owner, resident, guest, bireysel kullanıcı, service_user, super_user (Android) | Düzeltildi: uygulama |
| uyelik-5 | orta | IP başına yenileme/giriş/kayıt sınırları ortak NAT arkasındaki site sakinlerini kilitliyor | owner, resident, guest, bireysel kullanıcı | Düzeltildi: uygulama, sunucu |
| uyelik-6 | orta | 'Servis erişimini kapat' servis oturumunun MQTT kimliğini silmiyor; teknisyen 2 saate kadar canlı durumu okumaya devam ediyor | owner, service_session | Düzeltildi: sunucu |
| atolye-10 | düşük | Kart başka daireye bağlıyken yazım kaydı daireyi 'Yazıldı' yapıyor | super_user, service_user, owner | Düzeltildi: sunucu, servis yazılımı |
| atolye-11 | düşük | Karta yazım kaydı kaybolabiliyor (oturum yoksa sessiz, hata yalnız günlükte) | super_user, service_user, owner | Düzeltildi: servis yazılımı |
| atolye-12 | düşük | Daire 'Teslim edildi'ye hiç geçmiyor; durum ucu denetimsiz | super_user, service_user, service_session | Düzeltildi: sunucu, servis yazılımı (servis_kurulum-10 ile birleştirildi) |
| atolye-13 | düşük | Eşzamanlı şablon düzenlemesi sessizce eziliyor | super_user, service_user | Düzeltildi: sunucu, servis yazılımı |
| atolye-14 | düşük | 'Genel (standart şablonlar)' listesi tüm sitelerin şablonlarını gösteriyor | super_user, service_user | Düzeltildi: sunucu, servis yazılımı |
| atolye-15 | düşük | Şema PDF'inde kart UID'si yok; etiketin daire satırı yalnız aynı oturumda | service_user, owner | Düzeltildi: servis yazılımı |
| atolye-16 | düşük | Eskimiş ekran ve rehber metinleri yanlış yönlendiriyor | super_user, service_user | Düzeltildi: uygulama, servis yazılımı |
| atolye-4 | düşük | Servis yazılımı hâlâ v1.2.1 yüklüyor: şablon, Ethernet ve bootstrap yok | super_user, service_user, owner (bireysel kullanıcı) | Düzeltildi: uygulama, servis yazılımı (bireysel-1 ile birleştirildi) |
| atolye-9 | düşük | Ek modül değişikliği 'Kanalları Uygula' basılmadan kaydedilmiyor | super_user, service_user | Düzeltildi: servis yazılımı |
| bireysel-11 | düşük | Sahiplenme/Wi-Fi yönergeleri görünmüyor ya da yanlış düğmeyi işaret ediyor; giriş yapmış evsiz kullanıcıda Wi-Fi kurulum girişi yok | bireysel kullanıcı, owner | Düzeltildi: uygulama |
| bireysel-12 | düşük | Hiç bağlanmamış (yeni sahiplenilmiş) pano için teşhis 'uzun süredir çevrimdışı / güç kesik' diyor | owner, bireysel kullanıcı | Düzeltildi: uygulama, sunucu |
| bireysel-13 | düşük | Provizyonsuz panoda bireysel kullanıcı açamayacağı servis sihirbazına yönlendiriliyor; sahiplenme sessizce başarılı oluyor | bireysel kullanıcı, owner | Düzeltildi: uygulama |
| bireysel-3 | düşük | Sahiplenme yanıtı kaybolunca yeniden deneme 409 alıyor ve 'başka daireye bağlı / devir kodu alın' diyor | bireysel kullanıcı, owner | Düzeltildi: uygulama, sunucu |
| bireysel-7 | düşük | Kurulum PIN kilidi kart genelinde: SSID'den UID'yi gören herkes sahibin sahiplenmesini süresiz kilitleyebiliyor | bireysel kullanıcı, saldırgan (herhangi bir user hesabı) | Düzeltildi: uygulama, sunucu |
| ev_uyelik-2 | düşük | Daire devrinde hedef hesabin global rolu kontrol edilmiyor: servis_user/super_user owner yapilabilir | owner | Düzeltildi: uygulama, sunucu |
| ev_uyelik-6 | düşük | Davet 'aktif davet' sayaci ve e-posta/telefon hedefi yok: ayni ev icin 20'ye kadar tek-kullanimlik kod kime verildigi denetlenmeden uretilebilir | owner | Düzeltildi: uygulama, sunucu |
| ev_uyelik-8 | düşük | Zamanli kural sahibi 72 saatlik servis uyeligi dolunca kural calismiyor ama owner/resident goremiyor/devralamiyor (skipped_creator sessiz) | service_user, owner, resident | Düzeltildi: uygulama, sunucu (kullanim-5 ile birleştirildi) |
| guvenlik-10 | düşük | SafetyEvent.between gerçek firmware yükünde 'alarm kalktı' olayını hiç üretmiyor | owner, resident, guest | Düzeltildi: uygulama |
| guvenlik-11 | düşük | Aynı bölgede birden çok tehlike tek 'kind'e indirgeniyor; kart ve bildirim metni yanlış | owner, resident | Düzeltildi: uygulama |
| guvenlik-12 | düşük | Kendi evinin sahibi olan servis sorumlusu/süper kullanıcı alarm kuramıyor ve arka plan bildirimi açamıyor | service_user, super_user, owner | Düzeltildi: uygulama |
| guvenlik-14 | düşük | Not: Ethernet anahtarsız erişim + VIA_CLI, 'gaz vanası uzaktan açılmaz' ve 'alarmı yalnız sakin çözer' kurallarını deliyor | guest, individual | Karar gerekiyor (aşağıda) |
| guvenlik-3 | düşük | Güvenlik yapılandırması boş panoya buluttan yapılandırma yazılamıyor | service_user, service_session, super_user, owner | Düzeltildi: uygulama, firmware, sunucu |
| guvenlik-7 | düşük | Gaz alarmında havalandırma fanı misafir dahil herkes tarafından onaysız kapatılabiliyor | guest, owner, resident | Düzeltildi: uygulama, sunucu |
| guvenlik-8 | düşük | Aynı alarm içinde tekrarlayan vana arızası telefona bildirilmiyor | owner, resident | Düzeltildi: uygulama |
| guvenlik-9 | düşük | Arka plan alarm servisi yeniden başlayınca eski hırsız/arıza bildirimleri tepside kalıyor | owner, resident | Düzeltildi: uygulama |
| kullanim-10 | düşük | Uygulama MQTT kimlik yenilemesi telefon saatine göre hesaplanıyor: saat ileriyse 15 saniyede bir yeni kimlik, hız sınırı ve alarm takibi kesintisi | owner, resident, guest | Düzeltildi: uygulama, sunucu |
| kullanim-11 | düşük | Misafir, REST'te gizlenen pano IP'sini ve Ethernet IP'sini MQTT state'ten alıyor (karar 1 ile anahtarsız tam erişim yolu — not) | guest | Karar gerekiyor (aşağıda) |
| kullanim-9 | düşük | Yanıtı kaybolan bulut komutu 'İşlem geri alındı' diye gösteriliyor ve gerçek durum yeniden okunmuyor | owner, resident, guest, service_user, service_session, super_user | Düzeltildi: uygulama |
| pano-10 | düşük | Not (kararların yeni sonucu): Ethernet (VIA_CLI) ve LAN şablonu gaz vanasını yeniden tanımlayıp uzaktan açılabilir kılabiliyor; Ethernet değişiklikleri olay kaydında 'cli' görünüyor | guest, resident, service_session | Karar gerekiyor (aşağıda) |
| pano-7 | düşük | rekey ve sys set_local_key provizyonsuz panoya AP parolası olmadan anahtar yazıyor: kurulum/kurtarma ağı kalıcı olarak kapanıyor | service_user, super_user | Düzeltildi: firmware |
| pano-8 | düşük | Çekirdekte reddedilen genel komutlar last_rej üretmiyor: bulut sonucu bekleyip zaman aşımına düşüyor | owner, resident, guest, service_user | Düzeltildi: firmware |
| pano-9 | düşük | Seri DEFAULT_DI güvenlik çapraz denetimini atlıyor: sensör DI'si butona çevriliyor, sonraki açılışta güvenlik tabloları devre dışı kalıyor | service_user, super_user | Düzeltildi: firmware |
| servis_kurulum-10 | düşük | Devreye alma daireyi 'Teslim edildi' durumuna geçirmiyor (açık konu hâlâ kodda) | service_user, super_user, service_session | Düzeltildi: sunucu, servis yazılımı |
| servis_kurulum-11 | düşük | Acil sıfırlamada yeni yerel anahtar yayınlanır yayınlanmaz pano bağlantısı atılıyor; pano almadıysa telafi yok | service_user, super_user | Düzeltildi: firmware, sunucu (pano-5 ile birleştirildi) |
| servis_kurulum-5 | düşük | Süper kullanıcıda cihaz anahtarı elle giriliyor ve sunucu anahtarıyla doğrulanmadan factory/init'e yazılıyor | super_user, service_user, service_session | Düzeltildi: uygulama |
| servis_kurulum-7 | düşük | Mevcut cihaz/kayıttan devamda ilk hazırlık kurulum ağı yerine eski ev IP'sine gidiyor; tamamlanmış 5. adım yeniden yapılamıyor | service_user, super_user, service_session | Düzeltildi: uygulama |
| servis_kurulum-8 | düşük | 'Testleri yap / Bağlantıyı yeniden kur' aynı cihazın yarım kurulum kaydını sessizce eziyor | service_user, super_user, service_session | Düzeltildi: uygulama |
| servis_kurulum-9 | düşük | Süper kullanıcı müşteri evine üye olmadığından yanıtı kaybolan claim'i ve sonraki kurulumu sürdüremiyor | super_user | Düzeltildi: uygulama, sunucu |
| uyelik-10 | düşük | Davet bekleyen müşteri girişte 'şifre hatalı' görüyor; ACCOUNT_PENDING yanıtı fiilen dönmüyor ve denemeler kilit sayacını dolduruyor | owner (personelin açtığı müşteri hesabı), service_user | Düzeltildi: uygulama, sunucu |
| uyelik-11 | düşük | Etkinleştirilmemiş (pending_invite) müşteriye ikinci kurulumda davet yeniden gönderilmiyor ve teknisyene bildirilmiyor | service_user, super_user, owner (müşteri) | Düzeltildi: uygulama, sunucu (uyelik-1 ile birleştirildi) |
| uyelik-12 | düşük | Servis (PIN) oturumundan çıkış yalnız yerel; sunucudaki oturum 2 saat açık kalıyor ve ev sahibinde 'açık oturum' görünüyor | service_session, owner | Düzeltildi: uygulama, sunucu |
| uyelik-13 | düşük | Rolü 'user'a düşürülen servis sorumlusu eski servis evlerini görüyor; uygulama servis yetkisi gösteriyor, her işlem 403 | super_user, service_user (rolü düşürülen) | Düzeltildi: uygulama, sunucu |
| uyelik-16 | düşük | Şifremi unuttum'da telefon girilince kod e-postaya gidiyor ama ekran 'numaraya gönderilen kodu girin' diyor | owner, resident, guest, bireysel kullanıcı | Düzeltildi: uygulama |
| uyelik-4 | düşük | Şifre değişince arka plan alarm servisi eski token'la yarışıp oturumunu kaybediyor; uygulama servisi yeniden başlatmıyor, kart 'Açık' gösteriyor | owner, resident (Android) | Düzeltildi: uygulama |
| uyelik-7 | düşük | Tüm cihazlardan çıkış / şifre değişimi / sıfırlama / dondurma, kullanıcının ürettiği servis PIN'lerini ve açık servis oturumlarını kapatmıyor | owner, service_session, super_user | Düzeltildi: uygulama, sunucu |
| uyelik-8 | düşük | Google/Apple ile bağlama parolayı geçersiz kılıyor ama password_changed_at ve must_change_password kalıyor: hesap silme ve zorunlu şifre ekranı çıkmaza giriyor | bireysel kullanıcı, owner, super_user tarafından açılan hesap | Düzeltildi: uygulama, sunucu |
| uyelik-9 | düşük | Panosu olan evin tek sahibi (bireysel kullanıcı) devredecek kimse yoksa hesabını hiç silemiyor; belge yalnız 'başka üye' koşulunu söylüyor | bireysel kullanıcı, owner | Düzeltildi: uygulama |

## Belirsiz (donanımda doğrulanmalı)

- **pano-3** (orta): Kurulum ağı (SoftAP) istemcisi panonun Ethernet IP'sine istek atınca 'kablodan gelmiş' sayılıyor ve anahtarsız tam yetki alıyor — Düzeltildi: firmware

## Çürütülen aday bulgular

- **uyelik-14**: Kimlik başına 50 hatalı deneme tavanı, birkaç IP'den deneyen üçüncü kişinin hesap sahibini şifreli girişten sürekli kilitlemesine izin veriyor — Bu bilinen ve belgelenmiş bir takas. CONTRACTS.md:95 (UYELIK-10, karar D9) aynen şunu söylüyor: 'Bilinen takas: ≥ 5 ayrı ağı (IPv6'da ≥ 5 /64) olan dağıtık saldırgan 50 tavanıyla kimliği 15 dk kilitleyebilir'. Ayrıca kil
- **ev_uyelik-3**: App'te stale rol/misafir penceresi: bayat ev listesi onbellekten yetki hesaplaniyor, gercek 403 gelene kadar yetkili gorunuyor — Çürütüldü. Önbellekten açılış (SWR, PF-03) bilinçli bir tasarım ve kendini düzeltiyor. _startSession (automation_state.dart:1848-1863) önbellekten açarken aynı anda fetchHomes başlatır. _reconcileHomes (1979-2007) kaybed
- **ev_uyelik-4**: Cihaz yerel anahtari telefonda silinmiyor: uye cikarilinca/misafir suresi dolunca/devir sonrasi anahtar yerel depoda kalir — Çürütüldü: anlatılan yol uygulamada erişilebilir değil. Saklı anahtar yalnız _lookupLocalKey(uuid) ile okunur. uuid, _localKeyDeviceUuid()'den gelir: ya saklı servis cihazı (bunu yalnız selectDevice ve updateSelectedDevi
- **ev_uyelik-5**: Alarm takibi (Android arka plan) stale ev listesiyle surebilir: cikarilan uye/suresi dolan misafir evi 401 disi hatada izlemeye devam eder — Çürütüldü. Üye çıkarmada removeHomeMember (invitation_service.js:408-423) aynı işlemde kullanıcının o evdeki uygulama MQTT kimliklerini siler (mqtt_credential_service.revokeUserAccess) ve COMMIT'ten sonra açık bağlantıyı
- **ev_uyelik-7**: App join/transfer sonrasi 'Tekrar Kod Iste' yok ama 'zaten uye' iyimser sonucu yanilticidir: already_member'da kod tuketilmedigi halde ev yeniden secilir — Çürütüldü. Sunucu rol yoluna özel ileti döner: misafir yenilemede 'misafir süreniz yenilendi', misafir→sakin yükseltmede 'aile bireyi olarak katıldınız' (invitation_service.js:272-296). Uygulama alreadyMember değilse bu 
- **guvenlik-13**: Bireysel kullanıcı güvenlik cihazlarını (sensör/vana) tanımlayamıyor — Bu bir mantık hatası değil, belgelenmiş ürün sınırı. DAIRE_KULLANICISI_AKISI.md §4.3 madde 2 (satır 126-128) açıkça söylüyor: 'güvenlik cihazı (vana/siren) tanımlama ve devreye alma testleri servis sihirbazındadır; ev sa

## Karar gerektiren maddeler (uygulanmadı)

- **guvenlik-14 — Ethernet anahtarsız erişimi (karar 1/2) gaz vanası ve hırsız alarmı kurallarını (karar 7) deliyor**: pano-10 ve kullanim-11'in karar sonucu bu maddede toplandı. Kodda doğrulandı: Ethernet'ten gelen /api/safety/config VIA_CLI sayıldığı için gaz vanası 'su vanası'na çevrilip ardından buluttan ya da LAN'dan açılabiliyor; LAN şablonu (anahtarlı: resident, servis oturumu) aynı yeniden tanımı yapabiliyor; Ethernet'te /api/arm rol ve anahtar istemeden hırsız alarmını çözüyor; misafir eth_ip'yi MQTT state'ten öğrenip süresi bittikten sonra da ev ağındayken bunları yapabiliyor; Ethernet değişiklikleri olay kaydında 'cli' (fiziksel erişim) görünüyor. Seçenekler: (A) olduğu gibi bırakıp belgeye yazmak; (B) dar düzeltme: firmware'de isGasRelease her ağ yolunda (Ethernet safety-config ve şablon uygulaması; yalnız gerçek seri CLI serbest) reddedilsin (409 gas_local_only), /api/arm Ethernet'te de X-Device-Key istesin, Ethernet olayları ayrı VIA_ETH ('eth') koduyla kaydedilsin (sunucu safety_payload INTRUSION_CLEARED_VIA/ARM_CHANGED_VIA listelerine 'eth' eklenir). Öneri: B; Ethernet kolaylığı korunur, yalnız karar 7'nin iki güvenlik değişmezi geri gelir. Karar 1/2'yi daralttığı için onaysız uygulanmadı.
- **kayit-dogrulama — Kayıtta e-posta/telefon doğrulaması zorunlu değil (ön-hesap sorununun kökü)**: uyelik-1 düzeltmesi personel akışlarında (claim, assign-admin, acil sıfırlama) doğrulanmamış mevcut hesabı güvenlik için sıfırlıyor. Bu yüzden uygulamadan kendisi kaydolup e-postasını doğrulamamış MEŞRU müşteriler de servis kurulumunda/atamada şifrelerini e-postadaki bağlantıyla yeniden belirlemek zorunda kalacak. Kalıcı çözüm kayıtta doğrulamayı zorunlu kılmak (site_kapi_kontrol'deki 'bekleyen kayıt' modeli gibi: hesap kod girilince açılır). Bu bir ürün kararı. Öneri: bir sonraki sürümde bekleyen kayıt modeline geçiş; o zamana kadar bu plandaki sıfırlama + davet yeterli.
- **bireysel-9-yayin — Android App Links / iOS Universal Links doğrulama dosyaları için gerçek bilgiler gerekli**: /.well-known/assetlinks.json ve apple-app-site-association yayınlanmadıkça etiketteki sahiplenme karekodu telefon kamerasıyla tarayıcıda açılır (bu planda PIN'i yansıtmayan yönlendirme sayfası ve nginx günlük hijyeni eklendi). Dosyalar release imza sertifikasının SHA-256 parmak izini, applicationId'yi ve Apple Team ID'yi ister; ajanlar bu değerleri uyduramaz. Kullanıcı bilgileri verirse sunucu/nginx şablonuna eklenip dağıtılır.
- **bireysel-5-eth — Girişsiz kullanıcıya Ethernet'teki anahtarsız erişim uygulamada da açılsın mı?**: Karar 1 gereği pano Ethernet IP'sinde anahtarsız tam yetki veriyor; uygulama ise girişsiz ve anahtarsız kullanıcıya hiçbir kontrol yetkisi vermiyor (Capabilities.none). Bulgu bunu isteğe bağlı olarak açmayı önerdi; açmak aynı LAN'daki herkesin uygulamayı kurup panoyu yönetmesini kolaylaştırır. Öneri: açılmasın. Bu planda yalnız girişsiz yerel modun IP + anahtar girişiyle çalışması ve anahtarın saklanması düzeltildi.

## Bileşen sonuçları

### sunucu

- Düzeltilen: 36 madde + gözden geçirme turu: 5
- Test (ekip): Final verification (all run from G:\site\ev_otomasyon\server):
1) EV_PG_TEST_URL=postgresql://postgres@127.0.0.1:55432/evy_srvfix npm test: 2512 tests, 2511 pass, 0 fail, 0 cancelled, 1 skipped. The skip is the PG offline-sweeper test, which only runs with EV_PG_TEST_EXCLUSIVE=1.
   - evy_srvfix is a database I created and migrated with migrations 001-038 (node scripts/migrate.js, MIGRATE_CONFIRM=evy_srvfix) on the local QA PG at 55432. Port 54329 was not touched.
   - The previous full run had one file-level failure in test/bootstrap/bootstrap_routes.test.js. Its stack pointed to auth_service.loginWithApple, which that test process never loads, so the runner misattributed output under load. The file then passed 5/5 on its own, and it passed in the first and third full runs.
2) npm test with no PG URL: 2512 tests, 2339 pass, 0 fail, 173 skipped (PG tests).
3) npm run lint:syntax: clean.
4) node scripts/check_schema_contract.js: TEMIZ. With DATABASE_URL=evy_srvfix and --live: TEMIZ.
5) Baseline before my changes, against the shared evy_pg database: 2507 tests, 2493 pass, 13 fail. All 13 were "column does not exist" errors because evy_pg was never migrated to 037/038. I left evy_pg untouched, so the shared-DB PG tests will still fail there until it is migrated; evy_srvfix can be reused or dropped.
6) Each new or changed test was run first against the unfixed code and failed for the expected reason, then passed after the fix.
- Gözden geçirme bulguları (yüksek/orta olanlar ikinci turda düzeltildi):
  - [yüksek] `server/src/services/device_service.js:1371 (emergencyReset keyPlan) + :1471 (UNCLAIMED devices UPDATE) + :1601 (_requestReconcile); test server/test/devices/emergency_reset.test.js ('stoga donus...' and 'retained state/status BOS yayinla...')`: Emergency reset to stock (UNCLAIMED) of a board that is in a home now always uses the 'pending' plan. The new key is written to devices.local_key_pending_enc, but the same UPDATE sets home_id = NULL. The reconciler's localKeyPending query joins devices to homes by topic, so it can never find this row and the key cannot be delivered. devices.local_key_enc and device_inventory.local_key_enc both keep the OLD key. The next claim copies the inventory key (_resolveLocalKeyEnc(inv)) into the new customer's home and leaves the pending key alone. So the previous owner's key stays valid on the next customer's board until the board is live in the new home, plus 30 days of prev on firmware 1.3.0 or older (see the prev issue). During that time the previous owner can sign POST /devices/bootstrap and get the new home's device MQTT credential. Before this change, an online board got the new key immediately (the 'publish' plan). The updated test only checks that requestReconcile was called, which cannot detect that delivery is impossible.
  - [yüksek] `server/src/services/device_bootstrap_service.js:156,171 (prev candidate + revert); server/src/services/device_reconciler.js:198 (localKeySwap writes prev) and :996 (fp==current returns without clearing prev); bootstrap pending promotion (prev write); device_service.js:1377 (direct plan prevKeyEnc)`: This is the 'residual risk' the fixer left open, and the user asked for fixes without approval. Bootstrap is reachable from the internet, and it now accepts the previous key for 30 days. A prev-only match reverts the server to the old key (devices and inventory), issues the home's device MQTT credential to the caller (kicking the real board), and requests a reconcile. The reconcile re-sends the new key on ev/{t}/sys, which that device credential subscribes to. So any former key holder (removed owner or resident, ended service session, old owner after an emergency reset) defeats pano-6 rotation and emergency reset. The window can also be kept open indefinitely: after a revert, the real board must bootstrap again with the new key, and the pending promotion writes prev = old key for another 30 days (the PUBACK swap does the same). On firmware 1.3.1 prev is cleared only in the reconciler's pending-match path. _handleLocalKeyFp returns early when lk_fp matches the current key and leaves prev in place. For stock boards, a prev revert also rewrites device_inventory.local_key_enc, so the next claim uses the attacker's key. Each attacker bootstrap also uses up the card's 20/h budget.
  - [orta] `server/src/routes/auth_routes.js:73,278-310 (serviceLoginFailAll, global key 'svc-pin-fail:all')`: The global failure budget of 100 per 15 minutes is never reset by a successful login, and once it is full every service-PIN login is refused for everyone, even with the correct PIN (the test explicitly expects this). The per-IP limiter allows 10 attempts per 15 minutes, so about 10 IPv4 addresses (or 10 /64 networks spread over 5 /48s) can keep every temporary technician locked out of POST /auth/service-login across the whole system, repeating the attack every window. This is a new, cheap way for an unauthenticated attacker to deny service.
  - [orta] `server/src/services/scheduled_rules_service.js:293,485-490 (updateRule adoption)`: When a rule's creator is no longer authorized, the editor adopts it, and ADOPTER_ROLES includes 'service_user'. A staff member whose home membership has the 72-hour installer window becomes created_by. When the window ends, isCreatorAuthorized fails and the rule stops silently again, which is the failure kullanim-5 was meant to fix. createRule avoids this by recording the sole owner as created_by for service_user, but updateRule does not.
  - [orta] `server/src/services/device_service.js:1853-1862 (replaceBoard step 11c); test server/test/devices/replace_board.test.js 'atolye-8'`: replaceBoard is also allowed for owners and service_session. It silently removes the new card from another site flat and only returns a warning. That flat keeps its status ('written', 'installed' or 'handed_over') with no card; the test even expects flatB to stay 'written' with device_uuid null. This breaks the new rule that installed/handed_over need a card. The replaced flat also keeps its status, although the new card may carry the other flat's template written on it. Inventory delete, reissue and restock all return 409 DEVICE_LINKED_TO_FLAT for linked cards, but this path does not.
  - [düşük] `server/src/mqtt_bridge.js:1375 (_writeLocalKeyFp early return) + server/src/services/device_reconciler.js:850 (fpCapable = isValidFingerprint(row.key_fp))`: Once a board has reported lk_fp, devices.local_key_fp is never cleared. If the board is reflashed from 1.3.1 back to 1.3.0 (a normal bench step), the reconciler still treats it as fp-capable. It publishes set_local_key, the board applies it, but the server never swaps on PUBACK. It retries until MAX_ATTEMPTS and stops, leaving devices.local_key_enc on the old key while the board runs the new one. LAN calls then return 401 and GET local-key returns the wrong key.
  - [düşük] `server/src/services/mqtt_credential_service.js:356 (revokeServiceSessionAccess) used by auth_routes.js:188 (self-logout) and auth_service._revokeUserServicePins`: Session MQTT credentials are deleted per home (kind='app' AND user_id IS NULL). A home can have several service sessions at once (several PINs). One technician's self-logout (uyelik-12), or an owner's password change or suspension that revokes only that owner's PINs (uyelik-7), deletes and kicks the live MQTT connections of every other valid service session in the same home.
  - [düşük] `server/src/utils/rule_creator.js:45 (isCreatorAuthorized) + server/src/services/admin_user_service.js (uyelik-13 demotion cleanup)`: uyelik-13 deletes service_user memberships only on future demotions. Memberships left over from accounts demoted earlier stay in place. requireHomeAccess denies them, but the scheduler's isCreatorAuthorized accepts home_role 'service_user' whatever the global role is. Their scheduled rules keep running and the new rule list shows creator_active:true for someone who has no access to the home.
  - [düşük] `server/src/services/local_key_rotation.js (pano-6 design) + server/src/services/transfer_service.js (revokeHomeAccess without includeDevice)`: Note on deliberate decision 8 (bootstrap with the user-readable local key). The pano-6 rotation does not cut access at once. Until the swap completes, a former member who knows the current key can bootstrap, get the device credential (which subscribes to ev/{t}/sys) and capture the set_local_key carrying the new key. Transfer also leaves the device MQTT credential in place, so an ex-owner who kept the device password from the claim response or the reissue endpoint can subscribe to sys directly.

### uygulama

- Düzeltilen: 51 madde + gözden geçirme turu: 2
- Atlanan `note (not a review item): step 7 zone test aborted by an exception after the plan was written`: Pre-existing and left unchanged because it is outside the two review items. In saveSafety, after a successful plan write, _safetyDirty is set to false and _testResults to []. If _runZoneTest then throws (for example testAlarm 409 zone_latched, or a SetupProblemException from ensureDeviceReady), no zone result is recorded and isComplete can become true without a zone test. The longer feedback wait makes this window larger. A proper fix needs a 'not run' test state; this is suggested as a follow-up.
- Test (ekip): All commands run in G:\site\ev_otomasyon.
- `flutter analyze`: No issues found!
- `flutter test` (full suite, run after the last edit): exit 0, final line '+4812 ~485: All tests passed!'. That is 4812 passed, 0 failed, and 485 skipped; the skipped ones are the existing tag-gated visual/golden gallery tests.
- Targeted runs during TDD:
  - `flutter test test/services/ev_cloud_api_refresh_rate_limit_test.dart`: RED 2 passed / 3 failed, then GREEN.
  - `flutter test test/services/ev_cloud_api_refresh_rate_limit_test.dart test/services/alarm_watch_refresh_test.dart test/services/ev_cloud_api_service_test.dart test/services/ev_cloud_api_auth_test.dart test/services/ev_cloud_api_budget_test.dart test/services/alarm_watch_models_test.dart`: 153 passed.
  - `flutter test test/ui/relay_step_fixes_test.dart`: RED 9 passed / 7 failed, then a label RED 18 passed / 1 failed, then GREEN 19/19.
  - `flutter test test/ui/relay_step_fixes_test.dart test/ui/f_setup_safety_assignment_test.dart test/ui/f_setup_safety_widget_test.dart`: 42 passed.
- No git state changes, no devices or emulators, no docs edits. No secrets were printed.
- Gözden geçirme bulguları (yüksek/orta olanlar ikinci turda düzeltildi):
  - [orta] `lib/services/ev_cloud_api_service.dart:611-631 (_refreshAttempt 429 branch, run inside gate.run from _doRefresh) + lib/services/alarm_watch/refresh_gate.dart:50 (maxWait 45 s)`: uyelik-5 sleeps up to 30 s for Retry-After and then retries, all while holding the cross-isolate refresh gate. The worst-case hold is now about 10 s (first request) + 30 s (sleep) + 10 s (second request) + 10 s (_gatedPersistLimit), which is more than IsolateRefreshGate.maxWait (45 s). Before this change the hold was at most about 20 s. A waiter that reaches maxWait takes the lock from a holder that is still alive. It then reads the stored, not-yet-rotated refresh token and refreshes with it at the same time as the holder. The server treats the reused token as stolen and revokes the whole session family, which logs the user out on every device. The refresh limiters use 15-minute windows (auth_routes.js:42-43), so Retry-After is almost always longer than 30 s. The single in-gate retry therefore almost always gets 429 again, and the only effect of the wait is the long gate hold. The rate-limit tests run without a gate, so they do not cover this.
  - [orta] `lib/ui/pages/service_setup/logic/relay_logic.dart:846-871 (_runZoneTest 15 s deadline), 875 (testActuator), 920 (retestFailedZones); test/ui/f_support.dart _alarmTest`: The servis_kurulum-2 fix depends on reading a failing test_result, but firmware sends ok=false for a feedback valve that did not close only after fb_timeout_s (SafetyFsm.stepTest; FB_TIMEOUT_DEFAULT_S = 60). The wizard never writes fb_timeout_s (safety_assignment.dart safetyActuatorItem), so the default 60 s applies. _runZoneTest gives up after 15 s and returns ok=null, which does not count as failed. As a result: (a) testActuator still offers visual confirmation for a stuck valve and never marks it as a problem; (b) saveSafety never records safety_failed; (c) retestFailedZones gives a false pass, because a valve that is still stuck returns ok=null and the zone's failed result is replaced, so step 7 can complete. The fake device in the tests emits test_result immediately, even for failures, so relay_step_fixes_test does not cover the real timing.
  - [düşük] `lib/ui/pages/service_setup/steps/step_7_safety.dart:827-828 (_save after useCloudTransport)`: After the user accepts the cloud offer, _save calls logic.saveSafety() a second time. If the server already has a pending queue that this setup does not know about (_queued == null), saveSafety sets queueReplaceOffer and returns success. _save then ends: the replace dialog is not shown, no problem is set, and there is no other UI for queueReplaceOffer. The user's save silently does nothing until they press Kaydet again.
  - [düşük] `lib/ui/pages/service_setup/steps/step_5_wifi.dart:363-378 (_provisionCard, ethernet branch) + lib/ui/pages/service_setup/logic/wifi_logic.dart:247 (_ethNoKey)`: On the Ethernet provisioning path, only super users get the manual key fields; for staff and service PIN sessions, keyFetchedOnTheFly is always true. If the server returns no key (403/404, so fetchLocalKey returns null), provisionViaEthernet fails with _ethNoKey, which says 'anahtarı elle (iki kez) girin'. The card never shows fields for that, so the user is stuck unless they guess to switch to the AP path.
  - [düşük] `lib/services/automation_state.dart:2245-2256 (setMode, direct branch)`: kullanim-3 resets the LAN key, refresh flag and host only in selectHome's direct-mode branch. The user can switch homes in cloud mode (selectHome cloud branch does not clear directApi.localKey) and then enter direct mode. The previous home's key is kept, so _prepareDirect skips _resolveLocalKey and the old key is sent to the new home's board address. If _localKeyRefreshTried was already set in the earlier direct session, the 401 triggers no refresh and the new home stays at 'Cihaz anahtarı gerekli'.
  - [düşük] `lib/services/automation_state.dart:3233-3242 (board-mismatch branch sets _pollHalted) + 718 (directNeedsKey => _pollHalted) + lib/ui/dashboard/connection_status.dart:118`: When the board at the address belongs to another flat, the code sets _pollHalted. The connection badge reads that as 'Cihaz anahtarı gerekli', which pushes the user to type a key. setLocalKey then stores that key under the active home's board uid, overwriting the correct stored key.
  - [düşük] `lib/ui/pages/service_setup/logic/handover_logic.dart:234-245 (_ensureProvisioned)`: The comment says the check is skipped when the board cannot be reached, but only network and not_configured LocalApiExceptions are caught. A WrongDeviceException (the IP now answers as another AHBU board, for example after a DHCP change on a shared site LAN) and non-network LocalApiExceptions (a non-AHBU HTTP host at that IP) are passed up and block the handover. Before this change, handover did not depend on reaching the board on the LAN.
  - [düşük] `lib/services/automation_state.dart:1970-1978 (_startDirectSession)`: _startPolling() now runs after selectHome has already done refresh(). _startPolling calls _resumeDirectPolling(), which clears a _pollHalted that this refresh had just set (rejected key or board mismatch). On every direct-mode start, the next poll sends the rejected key once more, and it counts toward the board's 5-attempt lockout. The previous order (_startPolling before refresh) did not have this problem.
  - [düşük] `lib/ui/pages/service_mode_page.dart:124-141 (half-finished record prompt)`: The setup record is loaded by (ownerKey, deviceUuid) and offered for resume without comparing record.homeId with existing.homeId. If the board has since been moved to or re-claimed in another flat, 'Kaldığınız Yerden Devam' resumes the old flat's setup and its server calls fail.
  - [düşük] `lib/services/alarm_watch/alarm_watch_engine.dart:118-123 (refresh early return while all homes are connected)`: Note on uyelik-5: the home list, including roles and membership, is now re-fetched only every 60 min while all MQTT links are connected (previously about every 15-minute tick). A user who is removed from a home or downgraded to guest keeps getting background alarm notifications for that home for up to 60 minutes, while decision 7 says guests get no alarm push.

### firmware

- Düzeltilen: 10 madde
- Atlanan `fw-paket`: Partly skipped because the instructions conflict. COMPONENT RULES say 'Do NOT regenerate firmware_releases/ and do NOT change FW_VERSION (stays 1.3.0); the orchestrator packages the release'. I followed that: FW_VERSION is still 1.3.0, firmware_releases/ and version_info.json are untouched, no flash and no serial port. Done: (1) PlatformIO build (espressif32@7.1.3, core G:\.platformio, P: subst) SUCCESS with 0 downloads and 0 warnings. RAM 69320 B (21.2%; v1.3.0 was 69272, +48). Flash 1343693 B (42.7%; v1.3.0 was 1341713, +1980). App image 1344064 B (v1.3.0: 1342192). (2) A trial esptool merge_bin into the scratchpad (same flags: dio/80m/16MB, 0x0/0x8000/0xe000/0x10000; file deleted afterwards) gives a 0x0000-0xFFFF region whose SHA-256 (9d1afa71aced81c6...) equals the v1.3.0 combined image. Bootloader, partition table and boot_app0 are unchanged; the raw build bootloader.bin differs only in header byte 3 and the trailing digest, which merge_bin patches identically. (3) Native and qa_stack tests run (see test_results). Remaining orchestrator steps: (a) src/WiFiManager.h FW_VERSION '1.3.1' plus a 1.3.1 history comment; tools/qa_stack/sim/fw/wifi_manager.js FW_VERSION_DEFAULT '1.3.1'; then 'cd tools/qa_stack && node run.js fwcheck --update', otherwise fwcheck.test.js and the sim_device 'surum' test fail. (b) Package firmware_releases/v1.3.1 (combined + app_0x10000_v1.3.1.bin + SHA256SUMS + SURUM_NOTLARI.md) and add the 'Yerini v1.3.1 aldi' note to v1.3.0. (c) Release-note change list: pano-1, real provisioned in full status, lk_fp + STATUS 'Anahtar izi', JSON status/LWT, pano-4 (per-channel variant), pano-7, pano-8, pano-9, cfg.safety on unconfigured boards, pano-3. Mark 'DONANIMDA DENENMEDI' and that the server must be deployed first (it must accept JSON status). (d) 'Ilk kartta denenecekler' additions: STATUS 'Anahtar izi' after FACTORYINIT with a test key equals the contract formula; MQTT status JSON (uid) on connect and LWT; actuator-less latch + power cut boots to normal mode and clears with ack; raising ext channel count gives no false gas alarm and no spurious button press; rekey on an unprovisioned board returns 403; full status over Ethernet shows provisioned:false; DEFAULT_DI is rejected when a sensor DI 1/3 is defined.
- Test (ekip): 1) Native Unity (MSVC shim). PowerShell: & "C:\Users\FINGON~1\AppData\Local\Temp\claude\g--site-site-kapi-kontrol\10edb2b1-509c-4adc-9e41-95d3f3723ba3\scratchpad\fw-unity\run_tpl.ps1" -tests <all 25 test_* folders> -out "out-fix". Result: 25 suites, 417 tests, 0 failures, 0 MSVC warnings. Baseline before changes (out-fixbase): 24 suites, 406 tests, 0 failures. New: test_lk_fp (5); +1 each in test_cli_parse, test_net_link, test_safety_config, test_sensor_hub; +2 in test_safety_fsm; test_safety_view expectation updated.

2) Firmware build. scratchpad\fwfix-build.ps1 sets PLATFORMIO_CORE_DIR=G:\.platformio, runs subst P: to the waveshare_s3_demo folder, runs 'penv python -m platformio run -d P:\ -e esp32-s3-waveshare', then subst P: /D. Result: SUCCESS (fwfix-build-final.log), 0 warnings, 0 package downloads, RAM 69320 B (21.2%), Flash 1343693 B (42.7%). Trial merge_bin: 0x0000-0xFFFF identical to v1.3.0.

3) qa_stack full suite: 'cd G:\site\ev_otomasyon\tools\qa_stack && npm test' (node --test --test-concurrency=2 "test/*.test.js"). Log: scratchpad\fwfix-qa-final.log. Result: 628 tests, 626 pass, 2 fail. Both failures are the full-stack smoke check 'cevrimdisi: LWT -> sunucu is_online=false' (seed_idempotency.test.js, reported twice). Root cause: the current server tree's mqtt_bridge parseStatusPayload rejects the new JSON status, confirmed by calling helpers.parseStatusPayload, which returns null for JSON. It is expected to pass once the server-side agreement 3 change lands. Baseline before my changes (fwfix-qa-baseline.log): 603 tests, 601 pass, 2 fail (fwcheck drift and sim version 1.2.1 vs 1.3.0); both now pass.

4) Targeted runs: 'node --test test/fw_*.test.js' subsets plus sim_safety_hooks, sim_automation, sim_mqtt (23/23), sim_http, sim_device, f2_cross_layer_contract, sim_safety_equivalence all GREEN after their RED steps. 'node run.js fwcheck --update' then '--json' gives ok:true, 0 drift, fw_version 1.3.0, 69 sources.

Progress ledger: C:\Users\FINGON~1\AppData\Local\Temp\claude\g--site-site-kapi-kontrol\10edb2b1-509c-4adc-9e41-95d3f3723ba3\scratchpad\fw-fix-defter.md
- Gözden geçirme bulguları (yüksek/orta olanlar ikinci turda düzeltildi):
  - [düşük] `ev_otomasyon_servis_yazilimi/waveshare_s3_demo/src/SmartAutomation.cpp syncConfig, pano-4 branch (~L525-548); stepExtOutputs (~L1167, L1192)`: When the ext module channel count goes DOWN while the module stays enabled, the changed range [8+newCh, 8+oldCh) lies beyond cfg.totalRelays(). stepExtOutputs only loops over i < totalR, so the OFF write that the new comment and log line promise for the changed range never happens. The _hw=true / _hwKnown=false / forceHw bookkeeping for those indices is dead. A relay that was ON in the removed range stays energized indefinitely. That can be a lamp, or the relay of an ext shutter that was moving: its pair becomes invalid and the FSM is force-stopped, but no coil OFF is ever written. The gap existed before this change, but the new code claims to handle it. Note the disable path does handle it, with extAllOff and force-stopping the ext pairs.
  - [düşük] `ev_otomasyon_servis_yazilimi/waveshare_s3_demo/test/test_safety_fsm/test_main.cpp test_safe_mode_exit_after_actuatorless_config_applied; src/safety/SafetyManager.cpp submitEdit L525 / applyConfigOnLoop L609`: This pano-1 test does not exercise the changed SafetyManager line, and it covers a path the firmware cannot reach. The test adds a gas sensor to zone 1 while zone 1 is latched in cfg_corrupt mode, using Bench.reconfigure, and then calls setConfigUsable(latchCovered(...)) itself. Reverting SafetyManager.cpp:628 would leave it green. On the board, submitEdit and applyConfigOnLoop refuse that same edit with CfgResult::LATCHED / zone_latched. The reason is that touchesLockedZones compares against the zeroed cfg_corrupt table, so any hazard sensor in a latched zone counts as touching it. So for a cfg_corrupt board with a sensor-only latch, re-applying the original config still fails. The only real way out is an edit that does not touch the latched zone, for example SAFETY POLICY ON (which pano-1 now makes usable), then SAFETY ACK 0 FORCE, then re-adding the sensors. That sequence is neither tested nor documented.
  - [düşük] `ev_otomasyon_servis_yazilimi/waveshare_s3_demo/src/MqttManager.cpp handleSetLocalKey (~L1361-1373); interplay with server/src/services/device_reconciler.js _syncLocalKey (fpCapable, ~L850)`: With pano-7, an unprovisioned board ignores sys set_local_key (it only writes a serial log line), and as designed it publishes no lk_fp. The server reconciler decides whether a board reports a fingerprint only from a stored devices.local_key_fp. If that column is NULL it treats the board as old firmware and commits the key swap to both the device row and inventory on PUBACK alone. A 1.3.1 board that is MQTT-connected while unprovisioned and has never reported an lk_fp would therefore get a swap the server records but the board never stored. Examples: a board upgraded from 1.3.0 and RESETKEY'd before its first 1.3.1 state, or one whose MQTT credentials were set over keyless Ethernet. The contract note 'set_local_key on an unprovisioned board is ignored (log line only)' does not mention this.

### servis yazılımı

- Düzeltilen: 16 madde + gözden geçirme turu: 6
- Test (ekip): Full suite: `cd G:\site\ev_otomasyon\ev_otomasyon_servis_yazilimi; .venv\Scripts\python.exe -m unittest discover -s tests`. Ran 540 tests, OK (512 OK at the start of this round). Each new test was run and seen failing before its fix, then passing. `py_compile` passes on the changed modules; no pyflakes or ruff is installed, so no lint was run. Read-only server check (no server edits): `cd server; node --test test/templates/flat_status_transition.test.js test/templates/site_template_routes.test.js` passed 30, failed 0. I did not touch any hardware, serial port or production system. The SLIP SYNC download-mode detection and the ~9 s window are not yet tested on a real board.
- Gözden geçirme bulguları (yüksek/orta olanlar ikinci turda düzeltildi):
  - [orta] `ev_otomasyon_servis_yazilimi/ev_otomasyon_sistemi.py:2810 (apply_mode_selection 'update'), :3066-3080 (_continue_flash update branch), :3112 (_switch_to_update_mode)`: 'Güncelle (ayarlar korunur)' always uses app_image_relpath(version_info). Today that is v1.2.1/app_0x10000_v1.2.1.bin, because version_info.json deliberately stays at 1.2.1. _switch_to_update_mode also replaces a merged image the user browsed to (e.g. v1.3.0) with that v1.2.1 app. Nothing compares the image with the probed board. On a v1.3.0+ board (probe.supports_bootstrap is True; the user's COM9 board has run v1.3.0 since 2026-10-08) the only guard is the generic warning 'Bu imajla … çalışmaz (v1.3.0+ gerekli)', and the guide tells technicians this warning is normal for v1.2.1 and does not block. Accepting it writes the v1.2.1 app over v1.3.0 while the v1.3.0 settings stay. Ethernet, templates and bootstrap stop working, so an Ethernet-only board goes offline. The success text still says 'ayarlar korundu; provizyon GEREKMEZ'. Confirmed: on the real version_info.json, app_image_relpath gives the v1.2.1 app, which has 3 missing features.
  - [orta] `ev_otomasyon_servis_yazilimi/factory_client.py:2631 (probe_board); ev_otomasyon_sistemi.py:3066-3096 (_continue_flash, incl. line 3090)`: probe_board sends STATUS once and waits 4 s. 'No answer' (probe None, err None) is treated as a blank board. A provisioned or templated AHBU board can stay silent in two cases: it is in download mode, which is exactly what the guide's fix for 'Failed to connect' (BOOT+RESET) leaves it in, or it resets when the port opens (rst:0x15 was seen on this board). In that case the merged mode writes 0x0 without asking 'Kart Ayarları Silinecek'. The key, AP password, Wi-Fi, cloud identity, template and safety settings are wiped, and no template note follows. The update mode is refused, and its message points the user to the merged image. Probe errors other than SerialUnavailableError (port_io, serial_error) also skip the confirmation. test_merged_flash_on_a_blank_board_needs_no_extra_confirmation locks this behaviour in.
  - [orta] `ev_otomasyon_servis_yazilimi/site_template_ui.py:1719-1737 (acknowledge_safety_alarm.done); factory_client.py:3058-3065 (write read_safety); site_template_ui.py:1656`: After SAFETY ACK, done() shows '✅ Alarm onaylandı; güvenlik bölgeleri normal' whenever summary.latched is empty. That includes two wrong cases. (a) The SAFETY header was never read (summary.seen is False because of a timeout, garbled output or cancel). (b) A zone is in 'fault': summary.faults is parsed but never used. In the firmware, ack() acknowledges FAULT zones but canClear() clears only LATCHED ones. A zone with an unwired feedback valve, which is typical in the workshop, stays in alarm while the tool says it is normal. In the write path, outcome.safety_checked is set but never read and fault zones are dropped. So an unread SAFETY or a fault zone after a write produces no warning.
  - [orta] `ev_otomasyon_servis_yazilimi/site_template_ui.py:1799-1827 (_flush_pending_writes.done)`: Every failure keeps the record in _pending_writes, including permanent rejections from server recordWrite. Examples: 404 'Bu cihaz envanterde kayıtlı değil' when a USB or Ethernet write goes to a board that is not registered yet (the guide says Ethernet writes work on unregistered boards); 404 for a missing template version or flat; 409 TEMPLATE_DELETED, SITE_DELETED, or CONFLICT 'Daireye başka bir kart bağlı'; 422 TEMPLATE_SITE_MISMATCH. Such a record is resent on every later write and on 'Bekleyen Kayıtları Gönder', and shows 'Yazım Kaydı İşlenemedi' each time. The close dialog always reports unsent records. The queue never empties.
  - [orta] `ev_otomasyon_servis_yazilimi/site_template_ui.py:1260 (mark_flat_handed_over); factory_client.py:498 (DEVICE_NOT_IN_STOCK_TEXT); EV_OTOMASYON_KULLANIM_REHBERI.md §4b.1/§4b.2`: The tool and the guide rely on server rules that are not in server/src in this tree (site_template_service.js is unmodified). updateFlat accepts any status from service roles: no forward-only rule, no card requirement, no INVALID_STATUS_TRANSITION. updateTemplate ignores base_version: there is no TEMPLATE_CHANGED, so a concurrent edit is still silently overwritten. Flats have no last_ok_write or result. recordWrite never returns the DEVICE_LINKED_ELSEWHERE warning. linkFlatDevice rejects cards that are not IN_STOCK for super_user too. As a result, 'Teslim Edildi' can mark a planned flat with no card as delivered. Its confirm text ('Durum geri alınamaz; geri alma yalnız süper kullanıcıya açıktır') and the DEVICE_NOT_IN_STOCK text ('değilse süper kullanıcı bağlayabilir') are false today, and the guide's promise that 'Şablon Değişti' will appear does not hold.
  - [düşük] `ev_otomasyon_servis_yazilimi/factory_client.py:1640-1700 (full_status, _status_evidence, verify); ev_otomasyon_sistemi.py:2018-2033 (_start_verify)`: Ethernet re-verify runs when the record is init_sent and the user presses 'Ethernet ile Provizyonla', or presses 'Wi-Fi ile Doğrula' with rec.path == 'eth'. It calls verify(trust_key_check=False) with no UID check. With after_init=True and a v1.3.0 board, which has no lk_fp (true of every Ethernet board today), any provisioned board at the typed or DHCP-reassigned IP marks the record verified. Reproduced: a board reporting AHBU-S3-0A1B2C verified a record for AHBU-S3-DD8754. Separately, full_status() returns None for any non-200 reply, e.g. 503 'busy' from sendFullStatus when memory is short, or a timeout. _status_evidence reads that as 'the board reports no fingerprint' and gives already_provisioned plus USB RESETKEY advice for a temporary error.
  - [düşük] `ev_otomasyon_servis_yazilimi/ev_otomasyon_sistemi.py:3121 (_after_update_flash_success)`: The update-mode success text always says 'Kartın ayarları ... korundu; provizyon GEREKMEZ ve etiket geçerlidir', even when the pre-flash probe showed provisioned=False. This happens with a templated but unprovisioned board (Ethernet template writes work on unprovisioned boards) after the user answers 'Hayır' to 'Kart Ayarları Silinecek', or with a stock board updated in this mode. The board keeps its open setup AP. A pending registered record is not provisioned automatically, unlike in _after_flash_success.
  - [düşük] `ev_otomasyon_servis_yazilimi/ev_otomasyon_sistemi.py:1755-1770 (_fetch_key_for_reprovision)`: The label AP password is typed once into a masked askstring, checked only for format, and written to the board with FACTORYINIT. A typo gives the board an AP password that differs from the printed label. The label's AP password and Wi-Fi QR then no longer open the setup AP, which breaks individual-user onboarding and Wi-Fi provisioning. Nothing detects the mismatch.
  - [düşük] `ev_otomasyon_servis_yazilimi/site_template_ui.py:1761-1790 (_flush_pending_writes)`: (a) If a send is already running, a new record gets on_done('gönderiliyor (önceki gönderim sürüyor)'). But the running batch took its copy before the new record was added, and done() never sends again. The record stays queued without notice while the success dialog says it is being sent. (b) In the no-session branch, on_done is skipped while a login is running (_login_busy/_restoring). on_done then never runs if that login fails, if the login dialog after a failed session restore is cancelled, or if open_login_dialog returns early because a login is already running. Then after_record never runs, so the user never sees 'Şablon Karta Yazıldı', the PDF prompt or the 'Daire Etiketi' prompt.
  - [düşük] `ev_otomasyon_servis_yazilimi/site_template_ui.py:105-130 (flat_last_write_text)`: 'eski sürüm' compares last_ok_write.version with current_version of the flat's current template, without checking template_id. After the flat is moved to another template, two things go wrong. An old write of template A v5 against template B v2 shows nothing, although the card carries the wrong template. A v1 against B v3 shows a misleading 'eski sürüm (son başarılı v1, güncel v3)'.
  - [düşük] `ev_otomasyon_servis_yazilimi/ev_otomasyon_sistemi.py:1786 (_start_keyed_serial_provision)`: template_note = _template_lost_note(probe) is added on every path. In the manual 'Sunucudaki Anahtarla Yeniden Provizyon (USB)' path, the probe is taken now, after any flash. So a template it shows is still on the board: RESETKEY only clears the local key (ConfigManager::clearLocalKey) and FACTORYINIT does not touch the template. The success dialog still says 'Kartta şablon vardı (...); birleşik imaj sildi ... yeniden yazın'.
  - [düşük] `ev_otomasyon_servis_yazilimi/site_template_ui.py:1597-1660 (link_to_flat; error branch of _on_template_written)`: For a flat with no card, the card is linked to the flat before writing. If the TPL write then fails or is cancelled, the error branch does not say the card is now linked and does not refresh the flats list. The flat shows no card until a manual refresh. A wrong card plugged in by mistake stays linked without notice.

## Sözleşme ve belge notları (ekiplerin raporu, teknik)

### Plan: bileşenler arası anlaşmalar

0) SAHİPLİK VE ORTAK KURALLAR
- server: yalnız server/** ; app: lib/** ve test/** (Flutter kökü; yeni paket bağımlılığı EKLENMEZ); firmware: ev_otomasyon_servis_yazilimi/waveshare_s3_demo/** + tools/qa_stack/** (sim/fw yansısı, fw_* testleri, SOURCES.json için 'node run.js fwcheck'); tool: ev_otomasyon_servis_yazilimi/*.py, ev_otomasyon_servis_yazilimi/tests/**, ev_otomasyon_servis_yazilimi/labels/**, ev_otomasyon_servis_yazilimi/EV_OTOMASYON_KULLANIM_REHBERI.md. docs/** yalnız orkestratör. firmware_releases/version_info.json'a KİMSE dokunmaz.
- Gizli değer (anahtar, parola, token, .env içeriği) loglanmaz/test çıktısına yazılmaz; canlıya, seri porta, flash'a dokunulmaz; durum değiştiren git komutu yok.
- Dağıtım sırası: server -> app -> firmware. Sunucu eski (<=1.3.0: düz metin status, lk_fp yok, tam durumda provisioned hep true) ve yeni (1.3.1) firmware yüklerini birlikte kabul eder.
- Ortam tuzakları: regex/kesme işaretli betikleri Write ile dosyaya yazıp çalıştır; kaynağa ters eğik çizgi-u kaçışlı görünmez karakter yazma; CRLF dosyalarda çok satırlı değiştirme öncesi satır sonunu denetle; gerçek PG gerekiyorsa tools/qa_stack gömülü PostgreSQL ikilileriyle KENDİ örneğin (port 55432, scratchpad veri dizini, postgres.exe arka planda), 54329'a dokunma. Her mühendis ilerlemesini scratchpad'de bir defter dosyasında tutar.

1) YEREL ANAHTAR PARMAK İZİ lk_fp (pano-5, servis_kurulum-1)
- Tanım: lk_fp = HMAC-SHA256(anahtar = local_key ASCII baytları, ileti = 'ahbu-lk-fp/1|' + büyük harfli UID) çıktısının küçük harf hex gösteriminin ilk 8 karakteri. UID = durumdaki 'device' alanı (ör. AHBU-S3-DD8754) = sunucu devices.device_uuid.
- Test vektörleri (sunucu, firmware/sim ve araç testlerinde): ('ABCDEFGH23456789', 'AHBU-S3-DD8754') -> 'c7076562'; ('k3yTEST-9999', 'AHBU-S3-0A1B2C') -> '9814f286'.
- Firmware 1.3.1: provizyonluyken tam GET /api/status ve her MQTT ev/{t}/state JSON'unda 'lk_fp'; provizyonsuzken alan yok; kısıtlı (anahtarsız) durumda ASLA yok. Seri STATUS: '  - Bootstrap:' satırından hemen sonra '  - Anahtar izi: <8 hex|yok>'. Anahtar her değiştiğinde yeniden hesaplanır; sys set_local_key uygulanınca hemen yeni state yayınlanır.
- Sunucu: state.lk_fp yalnız /^[0-9a-f]{8}$/ ise ve canlı (retained olmayan) iletide işlenir; devices.local_key_fp/_at; GET /api/v1/homes/:homeId/devices/:uuid/local-key yanıtına 'local_key_fp' (sunucuda aynı formül). fp bildiren panoda anahtar takası PUBACK'te değil, state'te yeni fp görülünce kesinleşir.
- App HMAC hesaplamaz: panonun status lk_fp'sini sunucunun local_key_fp'siyle karşılaştırır (biri yoksa karşılaştırma yapılmaz). Araç Python hmac ile hesaplar.

2) DURUM ALANLARI (servis_kurulum-1)
- Firmware 1.3.1 tam /api/status 'provisioned' gerçek değer (hasLocalKey). Kısıtlı durum değişmez. GET/POST /api/auth/check ve Ethernet anahtarsız yetki (karar 1) DEĞİŞMEZ: Ethernet'te auth/check her zaman 200; anahtar doğrulaması lk_fp ile.
- İstemciler provisioned'ı önce anahtarsız kısıtlı durumdan okur (eski firmware tam durumda true yazar); tam durumda provisioned:false da provizyonsuz demektir. Provizyonsuz pano için ilk anahtar factory/init (Ethernet dahil her arayüz, karar 2) ya da seri FACTORYINIT.

3) STATUS KONUSU (guvenlik-6)
- Firmware 1.3.1: ev/{t}/status retained yükü bağlanınca JSON {status:'online', uid:'<UID>'}; LWT JSON {status:'offline', uid:'<UID>'}; yeniden başlatma öncesi yayın da aynı JSON (gerçek JSON, çift tırnaklı). QoS/retain/clean session aynı.
- Sunucu: düz 'online'/'offline' ve JSON {status|state, uid?} kabul; uid varsa yalnız o cihaz güncellenir; uid yoksa ve evde >1 cihaz varsa ileti yok sayılır (state + 120 sn süpürücü karar verir); tek cihazlı evde eski davranış. State işleri pano bazında birleştirilir (state:<uid>).
- App: _parsePresence JSON'u zaten okuyor; değişiklik yok.

4) KOMUT RETLERİ (pano-8): firmware kuyruğa alınıp uygulanmayan kimlikli genel komutlarda state.last_rej {id, code} yazar; yalnız mevcut kodlar 'busy' (yeniden başlatma bekliyor, RS485 taraması, panjur hareketteyken set_runtime) ve 'bad_cmd' (geçersiz röle/çift, panjur olmayan çift, geçersiz süre). Yeni kod yok; sunucu REJECTION_TEXT ve uygulama ret metinleri değişmez; MQTT yinelenen kimlik halkası değişmez.

5) ANAHTARSIZ PANOYA ANAHTAR YAZIMI (pano-7): firmware POST /api/auth/rekey provizyonsuz panoda 403 {error:'unprovisioned'} (Ethernet dahil); sys set_local_key provizyonsuz panoda yok sayılır. App/araç rekey'i yalnız provizyonlu panoda kullanır (servis_kurulum-1/5 onarımları).

6) ETHERNET SINIFLAMASI (pano-3): istek, yerel adres Ethernet IP'si VE istemci SoftAP istemcisi değilse (ApAccess::clientOnSoftAp anlamı) Ethernet'ten sayılır. İstemci değişikliği yok.

7) SAHİPLENME / ATAMA (uyelik-1/11, bireysel-3, bireysel-2)
- POST /api/v1/devices/claim yanıtı data.customer_account = {created:bool, status:'pending_invite', invite_sent:bool, security_reset:bool}: yeni hesapta created:true; mevcut pending_invite ya da doğrulanmamış olduğu için sıfırlanan hesapta created:false (sıfırlandıysa security_reset:true); aktif ve doğrulanmış hesapta alan yok. Sıfırlama uyarısı warnings[] içinde: 'Müşterinin doğrulanmamış mevcut hesabı güvenlik için sıfırlandı; şifre belirleme e-postası gönderildi.'
- Aynı sahibin yeniden sahiplenmesi: HTTP 409, code 'CONFLICT', reason 'ALREADY_YOURS', data {home_id, home_name} (http_errors EXPOSED_EXTRA_KEYS: reason, data). App ApiException.details['reason'] ve details['data'] ile okur. Diğer 409'larda reason yok.
- assign-admin ve acil sıfırlama yeni sahip: yalnız telefonla verilen ve gerçek e-postalı hesaba denk gelen hedef 400 VALIDATION 'Bu numara e-postalı bir hesaba kayıtlı; atama için hesabın e-posta adresini girin.'
- Claim ev kapsamlı değildir: global rolü user olan herkes (aktif evdeki rolü misafir olsa da) sahiplenir; sunucu değişmez.

8) OTURUM / HIZ SINIRLARI (uyelik-2, uyelik-5, ev_uyelik-1, uyelik-12)
- 429 gövdesi {success:false, code:'RATE_LIMITED', message, retry_after} + Retry-After başlığı (mevcut). App: POST /auth/refresh 429'da Retry-After kadar (en çok 30 sn) bekleyip BİR kez yeniden dener; yine 429 ise oturumu korur ve 'Sunucu geçici olarak yoğun; biraz sonra yeniden deneyin.' gösterir.
- Sınırlar: refresh token-özeti başına 10/15 dk + IP 1000/15 dk; login IP 200/15 dk; register 50/sa; forgot 50/sa; service-login mevcut /64 10/15 dk + yalnız HATALI denemeleri sayan /48 (IPv4 tam adres) 20/15 dk ve genel 100/15 dk (429 RATE_LIMITED).
- Refresh: yanıtı kaybolan yenilemenin tekrarı REFRESH_RETRY_GRACE_SEC (varsayılan 3600 sn) içinde ve halef hiç kullanılmamışsa 200 (yeni token çifti; halef 'retry_superseded' ile iptal); 'retry_superseded' token sunulursa aile iptali (401 INVALID_TOKEN). İstemci değişmez.
- POST /api/v1/auth/logout: gövdede refresh_token yoksa ve Authorization'da geçerli servis oturumu JWT'si varsa o oturum iptal edilir (revoked_reason 'self_logout') ve evin servis oturumu MQTT kimlikleri silinip atılır; yanıt her durumda 200. App servis oturumunda Bearer ile, gövdesiz gönderir (en çok 3 sn).

9) SERVİS OTURUMU / MQTT / ANAHTAR ROTASYONU (uyelik-6, uyelik-7, guvenlik-5, pano-6)
- POST /api/v1/homes/:id/service-access/revoke yanıtı {revoked_pins, revoked_sessions} (kullanıcı adları yanıtta yok); evin user_id'si boş uygulama MQTT kimlikleri silinir ve atılır.
- service_user'a verilen uygulama MQTT kimliği süresi = min(12 sa, installer_expires_at).
- Tüm cihazlardan çıkış, şifre değişimi/sıfırlama, dondurma, parola atama ve sosyal bağlama kullanıcının ürettiği kullanılmamış servis PIN'lerini ve bunlarla açılmış oturumları da kapatır (role_changed hariç).
- Kuyruktaki güvenlik yamaları 'sid' taşır; oturum iptal/süresi dolmuşsa 'revoked' ile düşer.
- Yerel anahtar rotasyonu (sunucu, bekleyen yol, yalnız tek panolu ev): devir kabulü, owner/resident çıkarılması, assign-admin'in üyelik silmesi, kalan evin owner/resident'ının hesap silmesi, anahtarı okumuş servis oturumunun bitişi. App LAN'da 401 alınca mevcut tazelemeyle yeni anahtarı alır; ayrıca bulut kipinde en çok 12 saatte bir önden tazeler.

10) ZAMANLI KURALLAR (kullanim-4, kullanim-5): kural öğelerine 'creator_active': bool. Kayıtlı sahip yetkisizken yetkili bir üyenin PUT'u created_by = düzenleyen yapar (üstlenme). Ev rolü service_user olan biri tek owner'lı evde kural oluşturursa created_by = owner. App ScheduledRule.creatorActive (alan yoksa true). Pano değişimi kuralları yeni cihaza taşır.

11) MQTT KİMLİĞİ (kullanim-10): POST /api/v1/homes/:id/mqtt-credentials yanıtına 'expires_in' (tam sayı saniye, sunucuda hesaplanmış). App önce bunu kullanır; yoksa expires_at - yerel saat; sonuç <= 0 ise en az 5 dk bekler.

12) DAVETLER (ev_uyelik-6): GET /api/v1/homes/:homeId/invitations -> data: [{id, role, expires_at, guest_valid_from, guest_valid_until, guest_name, created_at}] (kod DÖNMEZ); DELETE /api/v1/homes/:homeId/invitations/:invitationId -> 200 {id} | 404 NOT_FOUND | 400 VALIDATION; ikisi de HOME_ROLE_SETS.MEMBERS (owner + super) ve Cache-Control: no-store. Oluşturma yanıtı zaten 'id' içeriyor.

13) ENVANTER (atolye-2, bireysel-7, servis_kurulum-9, atolye-7/8)
- POST /api/v1/admin/inventory/:uuid/reissue-label yanıtı {device, setup_pin, qr_claim_url, message}; 'local_key' YOK; yerel anahtar DEĞİŞMEZ.
- POST /api/v1/admin/inventory/:uuid/clear-pin-lock (yalnız super_user) -> 200 {device_uuid, cleared:true}; anahtar/PIN değişmez.
- super_user için envanter liste/get öğelerinde 'claimed_home_id'.
- Daireye bağlı kart silinemez, REVOKED -> IN_STOCK yapılamaz, etiketi yenilenemez: 409 DEVICE_LINKED_TO_FLAT.

14) ACİL SIFIRLAMA (pano-5): yanıt local_key_publish yalnız 'pending' ya da 'skipped' ('published'/'failed' artık üretilmez; app 'pending'i zaten ele alıyor); 'local_key' yalnız 'skipped'de.

15) SİSTEM DOKTORU (bireysel-12): cihaz öğesinde network_status 'NEVER_SEEN' (level 'warning', başlık 'Pano Henüz Buluta Hiç Bağlanmadı') gelebilir; app bilinmeyen durumu çökmeden genel biçimde gösterir.

16) GÜVENLİK (guvenlik-3, guvenlik-4, guvenlik-7)
- GET .../safety-config kopya yokken cfg_get tetikler ama yine 404 CONFIG_NOT_AVAILABLE döner; app 404 ya da 409 CONFIG_NOT_AVAILABLE'da 15 sn boyunca pollInterval aralığıyla yeniden okur.
- Çevrimdışı kuyruğa eklemede zincir geçersizse 409 CONFIG_CHANGED_ON_DEVICE (kuyruğa alınmaz); app iptal + yeniden gönder sunar. DELETE .../safety-config/pending mevcut.
- Gaz kilidi sürerken safety_ack yetkisi olmayan aktörün fan 'off' komutu 403 FORBIDDEN 'Gaz alarmı sürerken havalandırmayı yalnız ev sahibi/üyeleri durdurabilir.'
- Firmware 1.3.1 yapılandırılmamış panoda da state.cfg.safety{rev,crc} yazar.

17) DEVİR (ev_uyelik-2): transfer-accept ve devir join-preview, kabul eden hesabın global rolü service_user ya da super_user ise 403 FORBIDDEN 'Servis personeli ve yönetici hesapları daire sahibi olamaz. Devri bir müşteri hesabına yapın.' (devir PENDING kalır). App sunucu mesajını gösterir.

18) SİTE / ŞABLON (atolye-7/8/10/13/14, servis_kurulum-10)
- Daire satırı: last_write {version, via, at, result, error_code, device_uuid}, last_ok_write {version, via, at, device_uuid} | null.
- PATCH /api/v1/sites/:id/flats/:flatId status: yalnız ileri (planned -> written -> installed -> handed_over); installed/handed_over için device_uuid şart; geri alma yalnız super_user; aksi 409 INVALID_STATUS_TRANSITION. Başarılı devreye alma (tests_passed) bağlı daireyi handed_over yapar.
- Daire kart bağlama: IN_STOCK olmayan kart, değişim kaydı (eski = dairenin kartı, yeni = kart) varsa ya da super_user ise kabul. Pano değişimi daire bağını yeni karta taşır.
- POST template-writes: kart başka daireye bağlıysa kayıt yine eklenir, daire durumu değişmez, yanıtta warning:'DEVICE_LINKED_ELSEWHERE' ve linked_flat_id.
- PUT /api/v1/templates/:id {body, base_version?}: base_version current_version'dan farklı ve gövde farklıysa 409 TEMPLATE_CHANGED, data {current_version}.
- GET /api/v1/templates site_id olmadan yalnız genel (site_id IS NULL) şablonları döner.

19) BOOTSTRAP (bireysel-6, pano-5): kart başı bütçe 20/sa ve yalnız imzası doğrulanan (401 olmayan) istekler harcar; IP 60/sa aynı; 429 + Retry-After. Önceki anahtar (prev, 30 gün) 4. aday; yalnız o tutarsa sunucu geri döner (current = prev, pending = yeni) ve uzlaştırıcı yeni anahtarı yeniden iletir.

20) FİRMWARE SÜRÜMÜ: FW_VERSION '1.3.1'. Bootloader ve bölüm tablosu v1.3.0 ile bayt bayt aynı; araç uygulama imajını 'app_0x10000_v<sürüm>.bin' adıyla 0x10000'a yazabilir. App/araç 'fw >= 1.3.0' denetimleri 1.3.1'i kapsar.

### Plan: belge notları

ORKESTRATÖR NOTLARI (düzeltmeler birleştikten ve testler geçtikten sonra)

A) docs/CONTRACTS.md
1. §1.1b/§1.3 hız sınırları: refresh token-özeti 10/15 dk + IP 1000/15 dk; login IP 200/15 dk; register 50/sa; forgot 50/sa; service-login /64 10/15 dk + yalnız hatalı denemeler /48 (IPv4 tam adres) 20/15 dk ve genel 100/15 dk (bilinçli takas: genel bütçe dolunca servis PIN girişi 15 dk kapanabilir, PIN öğrenilemez). Bootstrap kart başı 20/sa yalnız imzalı isteklerle. POST /auth/logout servis oturumu Bearer'ıyla oturumu kapatır.
2. §1.2: yanıtı kaybolan yenilemenin tekrarı (REFRESH_RETRY_GRACE_SEC=3600, halef kullanılmamış) 200; retry_superseded token aile iptali. Oturumları toplu kapatan işlemler (logout-all, şifre değişimi/sıfırlama, dondurma, parola atama, sosyal bağlama) kullanıcının ürettiği servis PIN'lerini ve açık servis oturumlarını da kapatır (role_changed hariç). Sosyal bağlamada password_changed_at=NULL ve must_change_password=FALSE.
3. §1.4: claim ev kapsamlı değildir (global rolü user olan herkes, misafir dahil; tablodaki 'guest ✖' düzeltilsin); aynı sahibin tekrarına 409 reason ALREADY_YOURS + data; daire devrinde hedef hesap personel/yönetici olamaz (403, assign-admin ile aynı).
4. §1.5: davet listesi/iptali (GET/DELETE /homes/:id/invitations); mqtt-credentials expires_in ve service_user kimlik süresi min(12 sa, installer_expires_at); servis erişimi kapatma servis oturumu MQTT kimliklerini siler/atar; local-key yanıtında local_key_fp; zamanlı kurallarda creator_active, üstlenme, personelin tek-owner'lı evde owner adına kural kurması ve pano değişiminde kuralların taşınması; Sistem Doktoru NEVER_SEEN.
5. §1.5b/§1.5c: personel akışlarında (claim, assign-admin, acil sıfırlama yeni sahip) doğrulanmamış mevcut hesap sıfırlanır (parola kullanılamaz, oturumlar düşer, pending_invite, davet gider); yalnız telefonla verilen hedef yalnız telefon-OTP (yer tutucu e-postalı) hesapta kabul; claim customer_account {created, status, invite_sent, security_reset}; bekleyen müşteriye her kurulumda davet yeniden gider. Etiket yenileme yalnız PIN'i yeniler (local_key yanıtta yok, anahtar değişmez; 'yeni etiket anahtarı esastır' cümlesi kaldırılsın); clear-pin-lock ucu; envanterde super için claimed_home_id; DEVICE_LINKED_TO_FLAT. Acil sıfırlamada anahtar her zaman bekleyen yoldan (uzlaştırıcı) iletilir: local_key_publish yalnız pending|skipped (§1.5b'deki published|failed açıklamaları ve 'failed' uyarı metni kaldırılsın).
6. Yerel anahtar yaşam döngüsü (§1.5 ve §3f): prev anahtar 30 gün bootstrap adayı ve geri dönüş; lk_fp ile takas onayı (fp bildiren panoda PUBACK'te takas yok); local_key_mismatch denetim kaydı; rotasyon tetikleri (devir kabulü, owner/resident çıkarma, assign-admin, kalan evin owner/resident'ının hesap silmesi, anahtarı okumuş servis oturumunun bitişi); çok panolu evde rotasyon/uzlaştırma yapılmaz (bilinen sınır).
7. §2/§3b firmware: lk_fp tanımı ve iki test vektörü; tam durumda provisioned gerçek değer; seri STATUS 'Anahtar izi' satırı; status konusu JSON {status, uid} (sunucu düz metni de kabul eder; çok panolu evde uid'siz status yok sayılır); rekey/set_local_key provizyonsuzda ret; kuyruğa alınıp reddedilen genel komutlarda last_rej busy|bad_cmd; yapılandırılmamış panoda state.cfg.safety; Ethernet sınıflaması SoftAP istemcisini dışlar; auth/check semantiği DEĞİŞMEDİ (Ethernet'te 200; doğrulama lk_fp ile).
8. §3e: devreye alma -> handed_over; durum geçiş kuralları (409 INVALID_STATUS_TRANSITION); daire satırında last_write.result/error_code/device_uuid ve last_ok_write; kart ya da şablon değişiminde written -> planned; pano değişimi daire bağını taşır, değişim kaydıyla IN_STOCK olmayan kart bağlanabilir; template-writes DEVICE_LINKED_ELSEWHERE; şablon PUT base_version / 409 TEMPLATE_CHANGED; site_id'siz şablon listesi yalnız genel.
9. Güvenlik/alarm bölümü: GET safety-config kopya yokken cfg_get tetikler; çevrimdışı kuyrukta zincir doğrulaması (409 CONFIG_CHANGED_ON_DEVICE); servis oturumu yamaları oturum bitince düşer; gaz kilidinde safety_ack yetkisiz fan kapatma 403; evden ayrılan panonun açık alarmları 'lost' (cleared_by 'detached'); başka eve sahiplenilen pano aynı aid ile yeni evde satır açar; gaz bastırması yalnız evde bağlı cihazların alarmlarına bakar.
10. Karar 1 notuna ekle: misafir MQTT state'ten eth_ip öğrenebilir, REST'teki IP gizlemesi güvenlik sınırı değildir (kullanim-11); Ethernet + VIA_CLI ile gaz vanası yeniden tanımlanıp açtırılabilir, LAN şablonu da (anahtarlı) aynısını yapabilir ve /api/arm Ethernet'te rol/anahtar istemez (guvenlik-14/pano-10; kullanıcı kararı bekliyor).

B) docs/akislar/SERVIS_SORUMLUSU_AKISI.md
- Bölüm 1 (roller): süper kullanıcı cihaz anahtarını yalnız servis yazılımından alır (karar 3), sihirbaz vermez (karar 7); elle girilen anahtar iki kez yazılır; personel/PIN oturumunda 6. adımda sunucu anahtarıyla eşitlenir.
- 3.2 ve 9.1: birleşik imaj NVS'i (anahtar, AP parolası, Wi-Fi, bulut kimliği, şablon, güvenlik ayarı) siler; provizyonlu/şablonlu karta araçtaki 'Güncelle (ayarlar korunur)'; birleşik imajdan sonra araç aynı kayıtla ya da sunucu anahtarı + etiket AP parolasıyla yeniden provizyonlar; güncel paket v1.3.1 (yayın kararı sonrası).
- 3.3.2: Ethernet provizyonu yalnız provizyonsuz kartta; provizyonlu kartta anahtar izi eşleşmezse USB RESETKEY; init_sent sonrası doğrulama Ethernet IP'sine gider.
- 3.5: NC tehlike girişleri atölyede köprülü ya da dedektör bağlı; ilk enerjide kilitlenen alarmın SAFETY ACK ile onaylanması (bölüm 4); röle tipi değişiminde güvenlik öğesi silme onayı.
- Etiket yenileme yordamı: uygulama yalnız PIN'i yeniler; tam etiket (yeni AP parolası) araçta USB 'Etiketi Yeniden Bas'.
- 5. adım Ethernet yolu: pano hazırlanmamışsa etiketteki AP parolasıyla 'Panoyu Hazırla' (Ethernet üzerinden); 'Ağ bağlantısını yeniden kur'. 6. adım: provizyonsuz pano 6-9 ve teslimi kilitler; Ethernet'te anahtar uyuşmazlığında 'Panonun Anahtarını Eşitle'.
- 7. adım: başarısız bölge testi kayıttan devamda da kilitler, 'Bölge Testini Yeniden Çalıştır'; yalnız panjurlu pano. 8. adım / 7.10: 'Bu dairede motorlu panjur yok' beyanı.
- Pano değişimi sonrası role göre sonraki adım; aynı panoda yarım kayıt için devam diyaloğu; süper için Aboneler > Kurulumu sürdür.
- Site: kart/şablon değişimi durumu 'planned'e çeker; 'Teslim edildi olarak işaretle'; eşzamanlı şablon düzenleme uyarısı; PDF'te kart UID'si.
- §9 açık konular: madde 2 (Ethernet provizyonu) ve 6 (teslim edildi) kapandı.

C) docs/akislar/DAIRE_KULLANICISI_AKISI.md
- §0.1 ve §4.2.3: kendiliğinden bulut bağlantısı pano yazılımı v1.3.0+ ister; eski yazılımda yetkili servis (geçici PIN ile 6. adım).
- §1 tablo: 'Panoyu sahiplenme / Misafir' -> 'Kendi panosu için Evet (yeni ev açılır)'.
- §2.3: 'başka üyesi ya da panosu olan evin tek sahibiyseniz önce devretmeniz istenir; üyesiz ve panosuz daireler hesapla birlikte silinir; devredecek kimse yoksa yetkili servis panoyu sıfırlayıp daireyi boşaltabilir'.
- §4: önerilen sıra önce sahiplenme sonra Wi-Fi; gerçek düğme adları (girişli 'Wi-Fi Şifre Değişimi & Kurtarma', girişsiz ve evsiz karşılama ekranında 'Pano Wi-Fi Kurulumu'); kurulum ağı açılıştan sonra 10 dk açık, 15 dk kapalı.
- §4.1.6: provizyonsuz pano için role göre yönerge (servis değilse satıcı/yetkili servis; geçici PIN).
- §4.2.6: etiketteki 1. karekod uygulamadaki 'Karekod Tara' ile okutulur; telefon kamerası App Links yayınlanana dek tarayıcıda yönlendirme sayfası açar.
- §4.3, §10.2: 'Kanallar ve Panjurlar' sayfası (ad, oda, tip, panjur süresi).
- §10.1: girişsiz yerel mod (IP + anahtar girilebilir, anahtar saklanır) düzeltildi; giriş yapmış kullanıcı yerel moddan her zaman buluta dönebilir; yeniden açılışta aktif ev seçilir; ev değişince LAN hedefi o evin panosudur.
- Diğer: pano değişimi sonrası ev sahibine Wi-Fi yönlendirmesi; bekleyen davetleri listeleme/iptal; şifremi unuttum telefon metni; servis oturumundan çıkış sunucuda da oturumu kapatır; tüm cihazlardan çıkış servis PIN'lerini kapatır; alarm bildirimine dokununca canlı durum beklenir; arka plan alarm servisi durursa yeniden başlatılır.
- Açık konu 6 (alarm kalktı olayı) kapandı; açık konu 4'e Ethernet sonuçları (kullanim-11, guvenlik-14) eklendi.

D) docs/SERVIS_VE_KULLANICI_AKISLARI.md §12
- Kapanan maddeler: 5 (bireysel-5), 11 ve 12 ve 17 (atolye-16), 14 (servis_kurulum-10), 15 (atolye-9), 16 (servis_kurulum-1 araç parçası), 18 (atolye-11), 20 (bireysel-10).
- 13: v1.3.1 paketi hazır (DONANIMDA DENENMEDİ); version_info.json kullanıcının donanım denemesinden sonra 1.3.1'e çevrilecek.
- 8: kullanim-11 ve guvenlik-14/pano-10 sonuçları eklensin.
- 6: açık kalır (provizyonlu Ethernet panosunda açılışta yaklaşık 35 sn kurulum ağı; pano-3'ün bu parçası yapılmadı).
- §9.1 madde 7: hesap silme metni (uyelik-9).
- Yeni bilinen konular: çok panolu evde yerel anahtar rotasyonu/uzlaştırması yapılmaz; kayıtta doğrulama zorunlu olmadığından doğrulanmamış meşru müşteriler personel kurulumunda/atamada şifrelerini e-postadaki bağlantıyla yeniden belirler; App Links/Universal Links dosyaları yayınlanmadı; servis PIN'i 6 hane (genel hata bütçesiyle korunuyor).

E) docs/contracts/template/README.md: şablon biçimi değişmedi; atölye uyarıları (NC tehlike girişi köprüsü, röle tipi değişiminde güvenlik öğesi silme onayı) yalnız servis akışına.

F) Firmware yayını ve kullanıcının bağlı kartı: hiçbir ajan seri port açmaz/flash yapmaz. v1.3.1 paketi firmware_releases/v1.3.1/ altında üretilir. Bellekteki nota göre COM9 kartı provizyonsuz v1.1.2: birleşik imaj (0x0) uygundur; kart provizyonlu/şablonluysa araçtaki yeni 'Güncelle (ayarlar korunur)' kipi (app_0x10000_v1.3.1.bin @ 0x10000) kullanılmalı. Kullanıcı SURUM_NOTLARI'ndaki 'İlk kartta denenecekler' listesini geçirince version_info.json -> {current_version:'1.3.1', firmware_file:'v1.3.1/firmware_combined_0x0.bin'} yapılır ve §12/13 kapanır. Sunucu (kod + migration 037/038) yeni firmware'den ÖNCE dağıtılmalı; nginx şablonundaki access_log değişikliği canlı yapılandırmaya ayrıca taşınmalı (canlı dağıtım orkestratör/kullanıcı adımı).

G) Birleşim sonrası doğrulama: server npm test + node scripts/check_syntax.js + node scripts/check_schema_contract.js (gerekirse --live, 55432 PG) + node scripts/check_client_contract.js (yeni istemci çağrıları: invitations GET/DELETE, admin clear-pin-lock); app flutter analyze + flutter test; araç 'python -m unittest discover -s tests' (ev_otomasyon_servis_yazilimi içinde); firmware native Unity testleri + tools/qa_stack 'node --test test/fw_*.test.js' ve tam paket (gömülü PG/broker; f2_cross_layer_contract, broker ve acl testleri sunucu + firmware değişikliklerini birlikte sınar).

H) Bu planda bilinçli olarak yapılmayanlar (bilinen konu olarak yazılmalı): servis PIN'ini 8 haneye çıkarma; (kart, kullanıcı) başına kurulum PIN kilidi tablosu; atölyede birleşik flash sonrası 'flash_erased' yazım kaydı; ev sahibine 'Bulut kimliğini panoya yaz' eylemi; zaman sınırlı türetilmiş servis anahtarı; açılış kurulum ağı penceresinin ertelenmesi; firmware bootstrap 429 Retry-After; firmware 'kinds' alanı; uygulamada uid'li çok panolu varlık gösterimi; girişsiz kullanıcıya Ethernet anahtarsız kontrol (karar bekliyor); VIA_ETH olay kodu (karar bekliyor).

### sunucu: sözleşme değişiklikleri

These need docs/ updates (orchestrator) and attention from other components:

AUTH / SESSIONS
- Rate limits:
  - refresh: per token hash 10/15min, plus IP ceiling 1000/15min
  - login: IP 200/15min
  - register: 50/h
  - forgot: 50/h
  - capabilities: 600/15min
  - service-login: /64 10/15min kept, plus failure-only budgets /48 (IPv4 full address) 20/15min and global 100/15min. Response 429 RATE_LIMITED 'Çok fazla hatalı servis PIN denemesi. Lütfen daha sonra tekrar deneyin.' with Retry-After.
- Refresh retry grace: env REFRESH_RETRY_GRACE_SEC (default 3600, 0 = off, max 86400). The successor is revoked as 'retry_superseded'; presenting a retry_superseded token revokes the family with 401 INVALID_TOKEN.
- POST /auth/logout without a body and with a service-session Bearer:
  - session revoked as 'self_logout'
  - the home's session MQTT credentials are deleted and kicked
  - an immediate key-rotation sweep runs
  - always 200
- magic-login: a pending_invite account gets ACCOUNT_PENDING before the token is consumed; the token stays valid.
- GET /homes: service_user memberships are hidden for non-staff accounts. Demoting staff to user deletes their service_user memberships.

SERVICE ACCESS / MQTT
- POST /homes/:id/service-access/revoke returns only {revoked_pins, revoked_sessions}. Session MQTT credentials (user_id NULL) are deleted and kicked, and a rotation sweep runs.
- POST /homes/:id/mqtt-credentials adds expires_in (integer seconds). For service_user, validity is min(12h, installer_expires_at). req.homeAccess.installer_expires_at is now set.

INVITATIONS / TRANSFER
- GET /homes/:homeId/invitations returns [{id, role, expires_at, guest_valid_from, guest_valid_until, guest_name, created_at}].
- DELETE /homes/:homeId/invitations/:id returns 200 {id}, 404 or 400. Both endpoints: MEMBERS role set, Cache-Control no-store, audit invitation_revoked.
- transfer-accept and transfer join-preview return 403 with STAFF_TARGET_MESSAGE when the acceptor is staff or super_user.

CLAIM / ASSIGN / EMERGENCY RESET
- Claim response data.customer_account = {created, status:'pending_invite', invite_sent, security_reset}.
- Re-claim by the same owner: 409 CONFLICT, reason ALREADY_YOURS, data {home_id, home_name}.
- assign-admin and emergency-reset new owner: a phone-only target that maps to a real-email account gets 400 VALIDATION.
- Clarification to document: only targets found by EMAIL with email_verified=false are neutralized. Phone-found placeholder (phone-OTP) accounts are NOT reset.
- Emergency reset: local_key_publish is only 'pending' or 'skipped'; local_key appears only with 'skipped'. There is no post-commit set_local_key and no telafi. The 'direct' plan keeps the old key as prev for 30 days.

INVENTORY
- reissue-label returns {device, setup_pin, qr_claim_url, message}. There is NO local_key and the key is unchanged; the audit records key_changed:false.
- POST /admin/inventory/:uuid/clear-pin-lock (super_user only, 30/h) returns {device_uuid, cleared:true}.
- super_user list and get items include claimed_home_id.
- 409 DEVICE_LINKED_TO_FLAT 'Kart bir daireye bağlı; önce daireden ayırın.' for delete, REVOKED->IN_STOCK, and reissue of a card linked to a flat.

LOCAL KEY (pano-5, pano-6, contracts 1 and 19)
- Columns: devices.local_key_fp/_at and local_key_prev_enc/_until; service_sessions.local_key_read_at/key_rotated_at.
- state.lk_fp is used only on live states and only if it matches /^[0-9a-f]{8}$/.
- GET .../local-key returns {local_key, local_key_fp}.
- On fp-reporting boards, the swap is confirmed by the state fp. If no confirmation arrives within 30 s, the reconciler retries with exponential backoff up to MAX_ATTEMPTS. Prev is cleared on confirmation.
- Old firmware: the swap happens on PUBACK and the old key is kept as prev for 30 days.
- A board reporting the prev fp triggers a revert (single-board homes only).
- Audit events:
  - local_key_rotated {via: state | reconciler | bootstrap}
  - local_key_reverted {via: state | bootstrap}
  - local_key_mismatch (once per device and fp)
  - local_key_rotation_scheduled {reason: home_transfer | member_removed | admin_assigned | member_deleted | service_session_ended}
- Bootstrap: the per-card budget is 20/h and only counts non-401 requests. Prev is the 4th candidate; a prev-only match reverts (current=prev, pending=new) and requests a reconcile. The device_bootstrap audit adds prev_key_reverted.
- Rotation runs only in single-board homes. A service session is marked when it reads the key; a sweeper runs every 5 min.
- RESIDUAL RISK (decision needed): for 30 days after a PUBACK-only swap on firmware ≤1.3.0 (and after the emergency 'direct' plan), anyone holding the previous key can call bootstrap. That returns a device MQTT credential (which receives sys and therefore the re-sent new key) and forces a revert. This weakens pano-6 rotation and emergency reset on old firmware until the board reports lk_fp (firmware 1.3.1 clears prev on confirmation). Option: do not write prev for rotation-triggered swaps, or shorten the window.

STATUS / STATE (guvenlik-6)
- Status payload accepted as plain 'online'/'offline' or JSON {status|state, uid}.
- With a uid, only that device is updated.
- A uid-less status in a multi-board home is ignored.
- State coalescing is per board (state:<uid>).
- The reconciler and layout sync still clear the whole home's online-period cache on a uid'd offline; this only causes extra idempotent checks.

SAFETY
- Fan 'off' during a gas latch without safety_ack returns 403 FORBIDDEN (contract text).
- Offline queue chain validation returns 409 CONFIG_CHANGED_ON_DEVICE 'Bekleyen değişikliklerle çelişiyor; kuyruğu iptal edip planı yeniden gönderin.'
- Queued items carry sid. A service-session item is dropped as 'revoked' once that session is revoked or expired.
- GET safety-config with no copy sends cfg_get, then returns 404 CONFIG_NOT_AVAILABLE.
- The alarm service requests a copy for present:false boards that have caps 'cfg'. For old firmware with present:false, the patch base is the copy rev.

SYSTEM DOCTOR
- network_status 'NEVER_SEEN': level warning, title 'Pano Henüz Buluta Hiç Bağlanmadı', power_status 'UNKNOWN'.

SCHEDULED RULES
- Rule items get creator_active.
- A PUT by an authorized member adopts a rule whose creator is no longer authorized (audit scheduled_rule_adopted {rule_id}).
- Staff creating a rule in a single-owner home stores created_by = owner (audit scheduled_rule_created_for_owner {rule_id, owner_id}).
- replaceBoard migrates rules to the new device.

SITE / TEMPLATE
- Flat rows: last_write {template_id, version, via, at, result, error_code, device_uuid} and last_ok_write {version, via, at, device_uuid} | null.
- PATCH flat status: forward-only; installed/handed_over need a card; rollback super_user only; otherwise 409 INVALID_STATUS_TRANSITION.
- written -> planned when the template changes, or when the card changes and the new card has no ok write with the flat's template.
- A non-IN_STOCK card can be linked if a replacement log exists or the actor is super_user.
- template-writes responses can carry warning 'DEVICE_LINKED_ELSEWHERE' and linked_flat_id.
- PUT /templates/:id accepts base_version (409 TEMPLATE_CHANGED with data {current_version}; invalid value 400).
- GET /templates without site_id returns ONLY global templates. The service tool (site_template_ui.py) must send site_id to list site templates.
- Commissioning with tests_passed sets the linked flat to handed_over.
- replaceBoard moves the flat link to the new card, with warning 'Yeni kart başka bir daireye bağlıydı; o bağ kaldırıldı.'

DEPLOY
- New migrations 037_local_key_consistency.sql and 038_replace_board_repairs.sql: run scripts/migrate.js before restarting the service.
- New nginx locations /claim, /reset-password and ^~ /magic-login with access_log off: deploy the conf and reload nginx (not done here).
- Static HTML pages /claim, /reset-password and /magic-login(/:token) are served by the API.

### sunucu (ikinci tur): sözleşme değişiklikleri

The docs agent should update docs/CONTRACTS.md (sections 1.5b, 3f, 1.3), docs/FLUTTER_API_CHANGES.md and docs/akislar/* to match the following. I did not edit docs/.

(1) POST /devices/emergency-reset
- UNCLAIMED: the new local key becomes current at once in devices and in inventory; there is no pending key. local_key is now returned once for every UNCLAIMED response and for any 'direct' plan.
- local_key_publish values for UNCLAIMED:
  - 'published': single-board home, board online, bridge connected; set_local_key was sent on ev/{t}/sys before the kick.
  - 'failed': the publish failed. Adds the warning "Yeni yerel anahtar panoya iletilemedi; anahtar yalnız bu yanıtta gösterilir. Panoya seri konsoldan RESETKEY ve ardından FACTORYINIT ile (fabrika aracı) yazılabilir." and partial:true.
  - 'skipped_offline': new value for this field (the Flutter model already parses it). The board is offline or the bridge is disconnected.
  - 'skipped': no home or device row, or a multi-board home.
- REASSIGNED is unchanged: 'pending', no key in the response.
- CONTRACTS lines 177/193/196 currently say "local_key yalnız skipped|failed" and list the values as published|pending|failed|skipped. Both need updating.
- Flutter: EmergencyResetResult.manualKeyHint says the key cannot be written over the network. For 'published' the board probably already has the key, so that text may need softening (this is in lib/, outside my scope).

(2) POST /devices/bootstrap (section 3f)
- Key candidates are only the device key, the inventory key and the pending key.
- A previous key is never accepted and never stored: no revert, no local_key_reverted audit event, and no prev_key_reverted field in the device_bootstrap audit details.
- Migration 037 no longer has local_key_prev_enc / local_key_prev_until. It is untracked and was never deployed. Any database that applied the old 037 would report a checksum mismatch and keep two unused columns; evy_pg never had 037.
- The reconciler swap no longer keeps the old key. A board whose fingerprint shows the old key only gets the local_key_mismatch audit; recovery is serial RESETKEY + FACTORYINIT.

(3) POST /auth/service-login
- When the global failure budget (100 per 15 minutes) is exhausted, only networks (IPv4 address or IPv6 /48) with at least 3 failures in the current window get 429 RATE_LIMITED. Other networks can still try.
- Per-network budget (20) and per-IP limiter (10) are unchanged.

(4) PUT scheduled-rules
- When the editor's home role is service_user and the home has exactly one authorized owner, adopting an unauthorized creator's rule sets created_by to that owner.
- The scheduled_rule_adopted audit has actor = staff and details {rule_id, owner_id, editor_id}.

(5) POST /homes/:id/replace-board
- New error: 409 DEVICE_LINKED_TO_FLAT 'Kart bir daireye bağlı; önce daireden ayırın.' when the new card is linked to another site flat and the actor is not super_user.
- A super_user override unlinks that flat and sets it to 'planned'. The warning text is now 'Yeni kart başka bir daireye bağlıydı; o bağ kaldırıldı ve o daire "Planlandı" durumuna alındı.'
- The replaced flat's 'written' status becomes 'planned' unless the new card has an ok template_writes row for that flat's template.

Notes:
- REASSIGNED in a multi-board home: the reconciler skips multi-board homes, so the pending key is never delivered and the previous owner's key stays valid on that board until it is re-keyed by serial. This existed before my change; HEAD's 'publish' plan instead changed the keys of every board in the home.
- Longer term, raising service-PIN entropy or binding the PIN to a home would allow relaxing the global cap. Not done.

### uygulama: sözleşme değişiklikleri

Docs and contracts to update (I did not edit docs/):
(1) Contract 1/2 (lk_fp): the app now reads full-status 'lk_fp' (8 lowercase hex) and GET local-key 'local_key_fp'. The comparison is only made when the board was verified on its Ethernet IP, in staff or service-PIN sessions; if either value is missing, nothing is compared. On mismatch, step 6 stops and offers a confirmed POST /api/auth/rekey with the server key (keyless on Ethernet per decision 1).
(2) Service wizard Ethernet path: an unprovisioned board (full-status provisioned:false, fw 1.3.1) is provisioned via factory/init to its Ethernet IP (decision 2). ensureDeviceReady and handover refuse unprovisioned boards ('Pano hazırlanmamış', fixStep 5). The test FakeDevice now reports the real provisioned value in full status and includes eth_connected/net_if in the restricted status.
(3) servis_kurulum-5: a manual key is entered twice. In step 6, if the board accepted a manual key that differs from the server key, the app rekeys the board to the server key (not for super users).
(4) Inventory: the app uses claimed_home_id (super users) for lost-claim recovery and calls POST /v1/admin/inventory/:uuid/clear-pin-lock (super only).
(5) Invitations: GET /homes/:id/invitations and DELETE /homes/:id/invitations/:id are used. A 404/405 on the list (old server) hides the section; a DELETE 404 reloads the list. InvitationModel reads 'id'.
(6) Safety-config queue (contract 16, app behaviour):
- The app never appends to an existing pending queue. It asks the user, DELETEs pending and resends from state_rev.
- It refuses offline plans over 16 patches, rolling back the first queued patch if the board turned out to be offline.
- A mid-chain error rolls back a partial queue this save created.
- CONFIG_CHANGED_ON_DEVICE in the offline/queued case disables auto-retry and offers 'Planı Yeniden Gönder'.
(7) System Doctor: home_network.status NEVER_SEEN is shown as a warning; unknown statuses are shown as unknown, not as an error. Devices with network_status NEVER_SEEN get their own line.
(8) New and changed user texts for the flow docs (DAIRE_KULLANICISI_AKISI / SERVIS_SORUMLUSU_AKISI / SERVIS_VE_KULLANICI_AKISLARI §12):
- claimCloudBootstrapNote is conditional on v1.3.0.
- Claim snackbar has a 'Wi-Fi Kurulumu' action; ALREADY_YOURS and network hints; repeated PIN_LOCKED hint.
- HomelessWelcome has 'Pano Wi-Fi Kurulumu'; a Wi-Fi QR opens the Wi-Fi wizard.
- Wi-Fi wizard: new done text; AP-window hint (10 min open / 15 min closed, plus a ~3 min note when the board is searching for a saved network); fw<1.3.0 warning; unprovisioned-board text for non-service users (also used for the local-mode message).
- Board-replacement result differs by role; Channels page; 'Kurulumu sürdür' for super users; half-finished record dialog; 'Bu dairede motorlu panjur yok' declaration; shutter-relay-only boards in step 7; 'Bölge Testini Yeniden Çalıştır'.
- Logout-all and change-password mention service PINs; REAUTH_REQUIRED and SOLE_OWNER guidance; activation hint for INVALID_CREDENTIALS/ACCOUNT_PENDING; forgot-password texts.
(9) Possible issue in the task text: the bireysel-11 (e) AP-window wording does not match the firmware ApPolicy exactly. The window opens about 3 min after boot when a saved network exists (RECOVERY_TRIGGER), so I added that sentence. Docs should use the precise wording.
(10) fw comparison helper: kCloudBootstrapMinFirmware = '1.3.0'; 1.3.1 counts as newer.

### uygulama (ikinci tur): sözleşme değişiklikleri

No wire or API changes: server and firmware are untouched. Client behavior changes the docs owner may want to record (docs/ was not edited):
(1) Refresh 429 handling (CONTRACTS §1.2 / uyelik-5): the back-off now happens outside the cross-isolate refresh gate. If Retry-After is 30 s or less (1 s when absent), the client retries once after the wait, re-reading the stored refresh token first. If Retry-After is over 30 s, it raises RATE_LIMITED 'Sunucu geçici olarak yoğun; biraz sonra yeniden deneyin.' at once, with no wait. The session is kept in every case.
(2) Service wizard step 7 zone test: for zones with a feedback valve the wizard waits max(fb_timeout_s, default 60) + 5 s (15 s otherwise). A missing result for a feedback valve counts as 'unconfirmed' and blocks step completion like a failure.
(3) The local setup-progress snapshot has a new optional key 'safety_unconfirmed' (list of zones) next to 'safety_failed'. It is backward compatible: older snapshots restore unchanged.

### firmware: sözleşme değişiklikleri

For the orchestrator to apply (I did not edit docs/).

CONTRACTS section 2 (MQTT):
- ev/{t}/status payload is now JSON {"status":"online","uid":"<UID>"}. The LWT and the planned-restart message use the same shape with "offline". QoS, retain and clean session are unchanged. The server must accept both forms BEFORE firmware 1.3.1 ships. The working-tree server/src/mqtt_bridge.js helpers.parseStatusPayload still returns null for JSON, which is why the qa_stack full-stack smoke currently fails.
- state.lk_fp (8 lowercase hex) is present only when provisioned. A new state is published promptly after any key change; after sys set_local_key it goes out immediately (pacer connected).
- state.cfg.safety{rev,crc} is now present on unconfigured boards too.
- state.last_rej {id, code} is now also written for rejected general commands that carry an id: bad_cmd for invalid relay/pair/position/runtime, unmatched shutter relay or unknown type; busy for restart pending, RS485 scan, or SET_RUNTIME while moving. No new codes.
- sys set_local_key on an unprovisioned board is ignored (log line only).

CONTRACTS section 3 (local API):
- Full GET /api/status 'provisioned' is the real value and 'lk_fp' is present only when provisioned. The restricted status never has lk_fp.
- POST /api/auth/rekey on an unprovisioned board returns 403 {error:'unprovisioned'} before the body is read, Ethernet included.
- A request counts as Ethernet only if the local endpoint is the Ethernet IP AND the client is not a SoftAP client (NetLinkCore::requestViaEth 3-arg form).

CONTRACTS 3c (serial): new STATUS line '  - Anahtar izi: <8 hex|yok>' directly after '  - Bootstrap:'. DEFAULT_DI/SET_SHUTTER_DI now runs the safety cross-check; on conflict it prints '[CLI-HATA] Guvenlik yapilandirmasiyla celisiyor (...)' and saves nothing.

Safety spec 5.1.6:
- LATCH_ORPHAN only when the latch needs relays not covered by the actuator table. A latch that needs no relay boots to normal mode as LATCHED and clears with ack + dry_hold.
- In safe mode, applying an actuator-less valid config allows a local ACK FORCE exit when the latch record needs no uncovered relay.

Ext module (CONTRACTS / spec 2.5): when the channel count changes while the module is enabled, new channels count as 'unknown' (sensor ok=false, not active) until the first fresh discrete-input read. They are initialised with no edge. Changed-range relays are re-verified OFF. Log line: '[RS485] Ek modul kanal sayisi X -> Y: yeni kanallar ilk okumaya kadar bilinmiyor.'

Deviation to record: pano-4 deliberately does NOT drop ext-ok globally. Doing so would trip SF_FAULT_CLOSE on already-read gas sensors (false gas alarm and valve closure).

docs/QA_STACK.md 5.1:
- lib/fwcheck.js NOT_PORTED now lists the v1.3.0 parts the sim does not model: EthLink/NetLink driver, BootstrapCore + bootstrap client, src/template/* (template HTTP/serial routes, ahbu_tpl, tpl/tpl_incomplete fields), MQTT/SNTP over Ethernet, MQTT state eth fields.
- New tracked sources: Utf8Util.h, LocalKeyFp.h, test_lk_fp, NetLinkCore.h (subset), test_net_link (subset).
- New sim surface: clientNet mode 'eth' plus local_ip override, sim.setEthernet / POST /__sim/eth {up}, CLI --eth. Restricted/full status eth_connected/net_if/eth_ip. ApPolicy ethUp input. sim/fw/local_key_fp.js, sim/fw/net_link.js.
- Sim FW_VERSION_DEFAULT is now 1.3.0 to match firmware; SOURCES.json refreshed (69 sources, fw 1.3.0, no drift).

Release: when FW_VERSION goes to 1.3.1, also bump the sim constant and run 'node run.js fwcheck --update'.

### servis yazılımı: sözleşme değişiklikleri

Docs I did not edit, which the orchestrator should update:

1) CONTRACTS §3c, 'Fabrika aracının bağımlı olduğu seri çıktı kalıpları'. Add the patterns the tool now parses:
- STATUS end lines: '  - Bootstrap: <durum>', '  - Anahtar izi: <8 hex|yok>' (right after Bootstrap; main.cpp already prints it), '  - Sablon: <id|-> v<n>[ YARIM...]'.
- '  - Panjurlar:' is treated as the last base line before v1.3.0.
- SAFETY output: '[GUVENLIK] politika=...' header, then only non-NORMAL zones as '  - Bolge N: latched|fault|test (...)', or '  - Butun bolgeler NORMAL'.
- 'SAFETY ACK <0-4>' reply: '[CLI-SONUC] Alarm onayi ... kuyruga yazildi (bolge N).'
- Tool rule to record: no 'Bootstrap:' or 'Sablon:' line after a complete STATUS means firmware < 1.3.0 (old-firmware warning).

2) CONTRACTS §3e.
- The 'GET /admin/inventory/:uuid/local-key' row says 'Ethernet yazımı için'. That is stale: the tool no longer calls it for Ethernet template writes. It now uses it for 'Sunucudaki Anahtarla Yeniden Provizyon (USB)' (service_user + super_user) and for 'Etiketi Yeniden Bas (USB)'.
- Document how the tool verifies Ethernet provisioning: auth/check is never used as proof. Proof is restricted provisioned=true, plus the full status (X-Device-Key: ETH_NO_KEY) with provisioned:false meaning unprovisioned and lk_fp matching when present. No lk_fp on an already-provisioned board means 'cannot verify', and the tool suggests USB RESETKEY.
- Flats row: the tool consumes last_write.result/error_code/device_uuid and last_ok_write (contract 18).
- template-writes reply may carry warning/linked_flat_id.
- PUT /templates/:id {body, base_version}; on 409 TEMPLATE_CHANGED the tool reads data.current_version.

3) Contract 13 / reissue-label. The tool expects {device, setup_pin, qr_claim_url, message}. During rollout, if an old server still returns local_key, the tool ignores it but masks it. The tool always fetches the current key afterwards, so it stays consistent with either server version.

4) version_info.json. The tool accepts an optional 'app_file' key. Without it the convention is v<ver>/app_0x10000_v<ver>.bin. The file was not changed.

5) SERVIS_VE_KULLANICI_AKISLARI.md and docs/akislar/SERVIS_SORUMLUSU_AKISI.md.
- §12 items 11, 12, 15, 16 and 18, and the tool side of 14, are resolved.
- §5.2: add the 'Güncelle (ayarlar korunur)' mode, the pre-flash STATUS/TPL probe and the 'Kart Ayarları Silinecek' confirm.
- §5.3: Ethernet re-verify goes to the Ethernet IP; add the server-key re-provision button (5c in the guide).
- §5.4: drop item 6 (stale text fixed). Add: a cardless flat is auto-linked before a USB write; NC hazard confirm, SAFETY read and 'Alarmı Onayla (USB)'; pending write queue with 'Bekleyen Kayıtları Gönder'; flat label PNG; 'Kart UID' in the PDF.
- §4.3: 'Teslim Edildi' action and the last-write indicators.
- §4.4: kind-change and save confirmations for safety items; ext-module apply prompt; TEMPLATE_CHANGED choice.
- Label reissue over USB is super_user only; service_user may use server-key re-provisioning.

### servis yazılımı (ikinci tur): sözleşme değişiklikleri

Tool-internal API:
- `factory_client.SerialProvisioner.probe_board(port, *, timeout=2.5, window=9.0, read_template=True, cancel=None)` now retries within the window and reopens the port on a USB drop.
  - It can now raise `ProvisionError` with code `download_mode` (new entry in `_SERIAL_ERRORS`).
  - New constants: `SERIAL_BOARD_PROBE_WINDOW_S`, `SERIAL_BOARD_PROBE_ATTEMPT_S`, `SERIAL_ROM_SYNC_TRIES`, `_ROM_SYNC_FRAME`, `_ROM_SYNC_REPLY`, plus `_Session.read_raw`.
  - It writes the esptool SLIP SYNC frame to the port only after the window, and only when the board stayed silent.
- `TemplateWriteOutcome.fault_zones`: new field.
- `ev_otomasyon_sistemi`:
  - new `sibling_app_image()`, `downgrade_lost_features()` and `RESET_WITHOUT_BOOT_HINT`
  - `_continue_flash(mode, cmd, probe, err, check=None)`
  - `_switch_to_update_mode(merged_path)`
- `site_template_ui`:
  - new `write_record_rejected()`, `RECORD_REJECTED_STATUS` and `RECORD_PENDING_STATUS`
  - `_flush_pending_writes(on_done=None, focus_seq=None)`
  - `_report_latched_alarm(port, zones, faults=None)`
  - new `_report_unread_safety` and `_fault_zone_text`

New UI dialog titles:
- 'Sürüm Düşürme Engellendi'
- 'Sürüm Düşürme'
- 'Güvenlik Durumu Okunamadı'
- 'Yazım Kaydı Reddedildi'
- 'Teslim Edilemez'
- 'Güncelle Kipi Seçildi' (can now also appear as a warning)
- 'Kart Durumu Okunamadı' and 'Alarm Sürüyor' (existing titles, now used in more cases)

UX change: a board that never answers is now probed for about 10-11 s before esptool starts (was about 4 s).

Deployment dependency: several tool texts rely on the uncommitted server changes listed under item 5. They must be committed and deployed together with this tool change:
- 'Teslim Edildi' / INVALID_STATUS_TRANSITION (forward-only, card required, revert for super_user only)
- the DEVICE_NOT_IN_STOCK note that a super_user, or a board replacement, can still link the card
- 'Şablon Değişti' (TEMPLATE_CHANGED on base_version)
- the last_ok_write / last_write result columns
- the DEVICE_LINKED_ELSEWHERE warning

I did not edit server/, docs/ or waveshare_s3_demo/ (I only read them).
