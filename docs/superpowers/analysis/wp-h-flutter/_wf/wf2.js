export const meta = {
  name: 'wp-h-flutter-duzeltme',
  description: 'Flutter gece hatirlatmasi: dogrulanmis elestiri bulgularini duzelt (cekirdek, arayuz MaterialBanner, platform), sonra 2 bagimsiz delta incelemesi',
  phases: [
    { title: 'Duzelt', detail: 'F1 cekirdek + F3 platform paralel' },
    { title: 'Arayuz', detail: 'F2 MaterialBanner koprusu (F1 sonrasi)' },
    { title: 'Delta', detail: 'RR1 cekirdek, RR2 arayuz/erisilebilirlik' },
  ],
}

const SP = 'C:/Users/FINGON~1/AppData/Local/Temp/claude/g--site-site-kapi-kontrol/a379bdb3-93a0-4167-8a2c-eed43f0e926f/scratchpad'
const INTEG = SP + '/flutter_integ'
const HEAD = SP + '/flutter_head'
const INTEG_BASE = SP + '/flutter_integ_base'
const INTEG_WF1 = SP + '/flutter_integ_wf1'
const HEAD_BASE = SP + '/flutter_head_base'
const WF = SP + '/wp-h-flutter-wf'
const DOCS = 'G:/site/ev_otomasyon/docs/superpowers/analysis'

const COMMON = `
BAGLAM
Ev Otomasyonu (Flutter 3.47 / Dart 3.13, provider, REST + MQTT) uygulamasina "acik kalan lambalar icin gece hatirlatmasi" (FCM push) istemci tarafi ekleniyor. SUNUCU TARAFI BITTI. Birinci tur (WF1) INTEG kopyasinda cekirdegi (A1), arayuzu (A2) ve HEAD kopyasinda platform+derleme dogrulamasini (A3) yazdi; 3 bagimsiz elestirmen (R1, R2, R3) 22 bulgu verdi (kritik 0, yuksek 1, orta 8, dusuk 13); ben yuksek bulguyu ve ilgili orta bulgulari KODDA DOGRULADIM. Sen simdi bu bulgularin duzeltilmesi turunun parcasisin. Baska bir (orkestrator) oturum, baska bir ekiple GERCEK depoyu (G:/site/ev_otomasyon) su anda es zamanli yeniden yaziyor: oraya HICBIR SEY YAZMA (yalnizca okuma serbest). Commit yapma. Sir (.env, anahtar, jeton) okuma/yazma/yazdirma.

KOPYALAR (yalniz bunlara yaz):
- INTEG = ${INTEG}
  Gercek agacin 18:13 anlik kopyasi + WF1 calismasi. DIKKAT: orkestrator Dalga 2'yi yaziyor; bu kopya BUTUN OLARAK DERLENMIYOR (lib/ui/pages/auth/**, service_mode_page.dart, replace_board_dialog.dart ve eski ust duzey testler yarim). INTEG'de TAM 'flutter analyze', TAM 'flutter test' veya build CALISTIRMA. Yalnizca hedefle: 'flutter analyze <yollar>' ve 'flutter test <test yollari>'. Taban cizgisi: ${WF}/baseline-integ-analyze.txt ve baseline-integ-failures.txt.
- INTEG_WF1 = ${INTEG_WF1}: WF1 bittigi andaki INTEG anlik kopyasi (SALT OKUNUR; bu turun farkini gormek icin: diff -ru -x .dart_tool -x build INTEG_WF1/lib INTEG/lib). INTEG_BASE = ${INTEG_BASE}: 18:13 dokunulmamis kaynak (WF1 oncesi). HEAD = ${HEAD} ve HEAD_BASE = ${HEAD_BASE}: deponun son commit'i (derlenebilir; APK/web dogrulamasi burada).
- Rapor/defter dizini WF = ${WF} (buraya serbestce yaz). WF1 raporlari: A1-rapor.md, A2-rapor.md, A3-rapor.md, R1-rapor.md, R2-rapor.md, R3-rapor.md (OKU; bulgularin ayrintisi ve kanitlari orada).

KAYNAK MALZEME: ${DOCS}/wp-h-flutter/ (ENTEGRASYON.md, PUSH_KURULUM.md, lib/test .txt dosyalari; kismen eskidi: yeni mimari asagida), ${DOCS}/wp-h-contracts-satirlari.md (sunucu sozlesmesi), ${INTEG}/docs/CONTRACTS.md.

MIMARI KARARI (orkestratorle mutabik; degismedi):
1. Entegrasyon sayfalara ve AutomationState'e DEGIL uygulama kabuguna baglanir: PeaceNoticeController (kendi dosyasi) AutomationState'in PUBLIC API'sini kullanir; afis MaterialApp.builder icindeki gorunmez/koprulu bilesenle gosterilir; sayfalara satir eklenmez. AutomationState'e YALNIZCA cikis kancasi eklenir.
2. E1/E2/F ekipleri dashboard, ayarlar sayfasi, main.dart, auth sayfalari, android/ios ve automation_state.dart'i HALA yaziyor: mevcut dosyalara yapilan HER ekleme minimum olsun (bicim degisikligi, yeniden adlandirma, ilgisiz temizlik YOK). Yeni islev YENI dosyalarda. Yama hareketli bir agaca uygulanacak.
3. Firebase yapilandirmasi YOKTUR; yapilandirma yoksa uygulama push'suz surumle AYNI davranir (PushConfig.fromEnvironment() == null -> hicbir Firebase cagrisi yok). KORUNMALI.
4. pubspec.yaml'daki firebase paketleri AYRI hunk (kullanicidan ayrica onay alinacak).

GENEL KURALLAR:
- Turkce kullanici metinleri ve yorumlar. ONEMLI: bu gorev metnindeki Turkce ifadeler ASCII'ye sadelestirildi; kullaniciya gorunen METINLERI ve yorumlari DOGRU Turkce karakterlerle (ç, ğ, ı, ö, ş, ü, İ) yaz. Kodu degistirmeden once ilgili mevcut dosyalari OKU; anlamadigin yere dokunma. Gizli veri / push belirteci / ev adi log'a yazilmaz.
- Windows: yeni dosyalari LF yaz; mevcut dosyada satir sonunu (CRLF/LF) node ile say ve koru. Cok satirli string degistirmeden once kontrol et. Regex / ters egik cizgi / kesme isareti iceren betikleri Bash heredoc veya node -e ile DEGIL, Write araciyla dosyaya yazip calistir. Node'da yol 'C:/...' veya 'G:/...' bicimindedir.
- Flutter komutlari uzun surebilir: 10 dakikayi asabilecekleri run_in_background ile calistir ve ciktiyi dosyaya al. ASLA 'flutter run', adb, emulator, pio, docker calistirma; 54329 / 1883 / 18083 / 5000 / 8081-8083 portlarina dokunma. Ayni dizinde es zamanli iki flutter komutu calistirma.
- dart format'i yalnizca KENDI yeni/degistirdigin dosyalarina uygula; mevcut dosyalarin bicimini bozma.
- Her duzeltme icin ONCE basarisiz (kirmizi) test yaz ve calistirip kirmiziyi gor, SONRA duzelt; sonunda gecici mutasyon denemeleriyle (duzeltmeyi geri alip testin kirmizi oldugunu gosterme) testlerin gercekten yakaladigini kanitla. Durust ol: calistirmadigini 'gecti' deme. Sonucu semaya uygun dondur, ayrintili raporu WF dizinine yaz.
`

const RESULT = {
  type: 'object',
  properties: {
    agent: { type: 'string' },
    summary: { type: 'string' },
    filesCreated: { type: 'array', items: { type: 'string' } },
    filesModified: { type: 'array', items: { type: 'string' } },
    verification: {
      type: 'array',
      items: {
        type: 'object',
        properties: { command: { type: 'string' }, result: { type: 'string' }, ok: { type: 'boolean' } },
        required: ['command', 'result', 'ok'],
      },
    },
    findingsClosed: { type: 'array', items: { type: 'string' } },
    findingsNotFixed: { type: 'array', items: { type: 'string' } },
    deviations: { type: 'array', items: { type: 'string' } },
    notVerified: { type: 'array', items: { type: 'string' } },
    reportPath: { type: 'string' },
  },
  required: ['agent', 'summary', 'filesCreated', 'filesModified', 'verification', 'findingsClosed', 'notVerified', 'reportPath'],
}

const FINDINGS = {
  type: 'object',
  properties: {
    agent: { type: 'string' },
    summary: { type: 'string' },
    previousFindingsStatus: {
      type: 'array',
      items: {
        type: 'object',
        properties: { id: { type: 'string' }, status: { type: 'string', enum: ['closed', 'partially', 'open', 'not-applicable'] }, note: { type: 'string' } },
        required: ['id', 'status', 'note'],
      },
    },
    findings: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          id: { type: 'string' },
          severity: { type: 'string', enum: ['critical', 'high', 'medium', 'low'] },
          file: { type: 'string' },
          line: { type: 'integer' },
          title: { type: 'string' },
          evidence: { type: 'string' },
          failureScenario: { type: 'string' },
          suggestedFix: { type: 'string' },
        },
        required: ['id', 'severity', 'file', 'title', 'evidence', 'failureScenario', 'suggestedFix'],
      },
    },
    checked: { type: 'array', items: { type: 'string' } },
    reportPath: { type: 'string' },
  },
  required: ['agent', 'summary', 'previousFindingsStatus', 'findings', 'checked', 'reportPath'],
}

// ---------------------------------------------------------------------------------------------
const F1 = COMMON + `
GOREVIN: F1 - CEKIRDEK DUZELTMELERI (INTEG).
Sahip oldugun yollar: INTEG/lib/services/**, INTEG/lib/models/**, INTEG/test/services/**, INTEG/test/push/**, INTEG/test/support/**. Baskasinin yollarina YAZMA (INTEG/lib/ui/**, android/**, ios/** F2/F3'un).
Once WF/R1-rapor.md ve WF/R3-rapor.md'yi OKU. KARAR VERILMIS duzeltmeler:

B1 + R3-01 (YUKSEK, gizlilik): oturum bitince / cikista / baska cihazdan 'tum cihazlardan cik' sonrasi bu cihazin FCM belirteci YERELDE gecerli kaliyor ve sunucuda kullaniciya bagli kaliyor; gece bildirimi (ev adi + acik lamba ozeti) cikis yapmis telefona dusebilir. Mevcut yorum ('sunucu eski belirteci ilk basarisiz gonderimde kapatir') YANLIS: FCM gonderimi basarili oldugu icin sunucu belirteci hic kapatmaz; sunucuda disableAllTokensForUser hicbir yerden cagrilmiyor.
 a. PushGateway'e Future<void> deleteToken() ekle. FirebasePushGateway: FirebaseMessaging.instance.deleteToken() (sinirli sure <= 3 sn; hata yutulur; cevrimdisiysa basarisiz olabilir: bilinen sinir, yorumda soyle). UnsupportedPushGateway: no-op. Test sahteleri (test/push/fakes.dart ve diger): cagri sayaci/izlenebilir.
 b. PushCoordinator.stop({bool unregister = true, bool? invalidateLocalToken}): invalidateLocalToken varsayilani unregister; true iken, sunucu DELETE denemesinden BAGIMSIZ olarak (onun basarisina/basarisizligina/zaman asimina bakmadan) gateway.deleteToken() cagrilir; toplam bekleme mevcut unregisterTimeout (3 sn) tavanini ASMAZ; sonra yerel bellek durumu sifirlanir. Eszamanli start/stop yarislarinda (epoch iptali) guvenli kalsin; mevcut push_coordinator_test.dart davranislari bozulmasin (gerekirse testleri yeni imzaya uyarla ama davranis sozlesmesini zayiflatma).
 c. PeaceNoticeController: (i) SessionExpiredEvent ve 'oturum acik degil / servis oturumu oldu' gecislerinde stop(unregister: false, invalidateLocalToken: true); (ii) yalniz 'oturum acik ama artik owner/resident degil' gecisinde stop(unregister: false) (yerel belirteci SILME: rol degisimi gecici olabilir; sunucu alicilari anlik rolden hesaplar). Yorumlari DUZELT (yanlis gerekce kalkmali; yerine: belirtec yerelde gecersiz kilindigi icin sonraki gonderim UNREGISTERED doner ve sunucu satiri kapatir; cevrimdisiysa silinemeyebilir).
 d. Testler: oturum bitince deleteToken cagrilir ve sunucu DELETE cagrilmaz; cikista (stop(unregister:true)) hem DELETE hem deleteToken; DELETE basarisiz/zaman asimi olsa da deleteToken cagrilir; deleteToken hata verir/asili kalirsa stop 3 sn icinde doner; rol kaybinda deleteToken CAGRILMAZ; servis oturumuna geciste cagrilir.
B2 (orta): push kaynakli afis is bitince kalkmiyor. closeAll istisnasiz bitip skippedCount == 0 ise afisi KAYNAGINA BAKMADAN kaldir (komut gitti ya da yapacak bir sey yoktu; resolved/nothingToDo ayrimina bagli degil). Ayrica yedek-afis senkronunda TAZE ve gecerli veri (stale == false, home_id aktif evle esleser) geldiginde: canli sayilar 0 ise ya da last_notice.id == pending.noticeId ve cozulmusse (status resolved) pending'i KAYNAGINA BAKMADAN kaldir. Testler (R1'in P1/P2 senaryolari kirmizi->yesil).
B3 (orta): panodaki ESKI 'Hepsini Kapat' dugmesi v2 sunucuda panjurlari da indirir (include_shutters varsayilani true) ve kullaniciya soylenmez. DUZELTME: EvCloudApiService.closeAllOpenLights'in includeShutters varsayilani FALSE ve govdede HER ZAMAN acikca gonderilir ({home_id, include_shutters: false}); AutomationState.closeAllOpenLights (eski dugme) DEGISMEDEN kalir (yalniz lamba kapatir). PeaceNoticeController afisteki 'Hepsini kapat' icin includeShutters: true'yu ACIKCA gonderir. Mevcut test/services/peace_v2_models_and_api_test.dart'taki 'yalnizca home_id' beklentisini guncelle. Sunucu varsayilani DEGISMEZ.
B4 + B5 (orta/dusuk): cikis kancasi semantigi: (i) kancalar logout() icinde ve YALNIZCA orada calisir (logoutAll()'dan KALDIR: logoutAll sunucuda basarisiz olursa kullanici oturumda kalir ve push kapanmamali; basarili olursa zaten logout()'a duser ve kanca orada calisir - API istemcisi belirtecleri silmis olabilir: sunucu DELETE'i basarisiz olabilir ama yerel deleteToken (B1) bagimsizdir); (ii) kancalar logout() basinda ESZAMANLI BASLATILIR ama cikis en cok 1 sn (adlandirilmis sabit; yorumda gerekce) bekler; sure dolsa da yerel temizlik HEMEN yapilir, kancalar arka planda tamamlanmaya devam eder (hata/zaman asimi yutulur; her kanca icin 3 sn tavani korunur); (iii) es zamanli ikinci logout() cagrisinda kancalar IKINCI kez calismaz (tek ucus). Kanca yokken hic await yok (korunur). logout()'un belge yorumundaki 'once yerel temizlik' ifadesini gercege uydur. Testler (sahte saat/FakeAsync: yavas kanca cikisi 1 sn'den fazla ertelemez; kanca arka planda tamamlanir; logoutAll sunucu hatasinda kanca CALISMAZ).
B8 + R3-06 (dusuk): _onNotice'ta state.homes yukluyken bildirimin home_id'si kullanicinin evlerinden biri DEGILSE bildirimi yok say (eski hesabin bildirimi yeni kullaniciya sizmasin). Test.
R2-4 icin cekirdek destegi: PushCoordinator'da kalici red (PushRegistrationRejected) ile gecici basarisizligi ayirt et; PeaceNoticeController'da bool get pushRegistrationBlocked ve Future<void> retryPushRegistration() (elle yeniden dene; mevcut coordinator API'sine uygun: refresh/zorla kayit). Testler.
BILINCLI OLARAK YAPMA: B6 (LAN modu), B7 (kapatilan afisin geri gelmesi).
Hedefli dogrulama: flutter analyze lib/services lib/models test/services test/push test/support (0 sorun); flutter test test/services test/push (879+ test, hepsi gecmeli). Kirmizi->yesil kanitini ve en az 6 mutasyon sonucunu raporla. Rapor: ${WF}/F1-rapor.md (yeni/degisen public API listesi ve F2 icin denetleyici arayuzu: pending, pushState, pushPermissionDenied, softPromptVisible, closing, closeMessage, pushRegistrationBlocked, retryPushRegistration, requestPermission, dismissSoftPrompt, dismiss, closeAll ...).
`

const F3 = COMMON + `
GOREVIN: F3 - PLATFORM HUNK'LARI (INTEG). Yollar: INTEG/android/**, INTEG/ios/**; ayrica ${WF}/F3-* dosyalari.
Baglam: A3 HEAD kopyasinda Android/iOS degisikliklerini yapti ve APK derledi (${WF}/A3-rapor.md, A3-degisen-dosyalar.txt; HEAD farki flutter_head vs flutter_head_base). AMA gercek agactaki dosyalar HEAD'dekinden FARKLI (R3-02): MainActivity.kt FlutterFragmentActivity kullaniyor ve LF; AndroidManifest degisti (INTERNET, allowBackup=false, networkSecurityConfig, deep link...). Bu yuzden platform degisiklikleri INTEG'deki (18:13 gercek agac) dosyalara GORE uygulanmali ve yamalar BURADAN uretilmeli. Flutter derlemesi/APK CALISTIRMA (kapi asamasi yapacak); yalnizca statik dogrulama.
Yap:
1. INTEG/android/app/src/main/kotlin/**/MainActivity.kt: A3'un HEAD'deki kanal kodunu (flutter_head MainActivity.kt; WF/a3-kt.js) INTEG'in MainActivity'sine (FlutterFragmentActivity, LF) uyarlayarak ekle: onCreate icinde super.onCreate sonrasi; gerekli import'lar + yardimci fonksiyon; kanal kimligi 'peace_reminder' sunucuyla BIREBIR (server/src/services/push_service.js ve ${DOCS}/wp-h-contracts-satirlari.md); API 26 korumasi; IMPORTANCE_HIGH; ad 'Gece hatırlatması'; mevcut kodun satir sonunu koru; mevcut sinif yapisini bozma.
2. Bildirim kucuk simgesi (R3-03): INTEG/android/app/src/main/res/drawable/ic_stat_peace.xml (tek renkli BEYAZ vektor, 24dp, sade ampul silueti; vektor sozdizimi gecerli) ve AndroidManifest.xml <application> icine com.google.firebase.messaging.default_notification_icon meta-data'si (+ isteğe bagli default_notification_color: tema vurgu rengi; mevcut renk kaynagi varsa onu kullan, yoksa EKLEME). Manifestteki mevcut degisikliklere (INTERNET, allowBackup=false, networkSecurityConfig...) DOKUNMA; yalniz meta-data ekle. Dogrulama: XML iyi-bicimliligi (node), vektor yollarinin gecerliligi; aapt2 mevcutsa (Android SDK build-tools) 'aapt2 compile' ile kaynagi derle ve sonucu raporla.
3. iOS: INTEG/ios/Runner/Info.plist (UIBackgroundModes: remote-notification), AppDelegate.swift, Runner-Bridging-Header.h - A3'un HEAD'deki degisikliklerini (diff -u flutter_head_base/ios flutter_head/ios) INTEG dosyalarina GORE yeniden uygula (INTEG'in AppDelegate'i HEAD'dekiyle ayni mi kontrol et; farkliysa uyarla); eklenti kaynagiyla (pub onbellegi: firebase_messaging-16.7.0/ios) dogrula. project.pbxproj / entitlements DOKUNMA.
4. .gitignore (R3-04): gercek agactaki G:/site/ev_otomasyon/.gitignore'u OKU ve push sirlarini kapsayan satirlari ekleyen kucuk bir yama yaz (${WF}/F3-gitignore.patch; 'git apply --check' ile GERCEK agacta temiz uygulandigini dogrula): *.p8, fcm*.local.json, google-services.json, GoogleService-Info.plist, *service-account*.json, *firebase-adminsdk*.json (mevcut kaliplari tekrar etme).
5. Yamalari uret: INTEG ile INTEG_BASE arasindaki android/** ve ios/** farkini LF-normalize 'git diff --no-index' ciktisi olarak ${WF}/F3-platform.patch'e yaz (a/ b/ onekleri repo kokune goreli: android/..., ios/...; git diff --no-index iki dizin adini onek yapar: basliklari duzelt; ben WF1'de make_patch.js ile yaptim: ${WF}/../make_patch.js ornegine bak), ardindan GERCEK agaca (G:/site/ev_otomasyon) 'git apply --check' ile denetle (agac hareketli; uyusmazlik varsa hangi hunk'in neden uygulanamadigini raporla). pubspec.lock YAMALANMAZ.
6. Gercek agactaki android/ios dosyalarinda su an E2 (Dalga 2) calisiyor: yama KUCUK ve cakisma-dayanikli olsun.
Rapor: ${WF}/F3-rapor.md.
`

const F2 = (f1) => COMMON + `
GOREVIN: F2 - ARAYUZ YENIDEN ISLEME (INTEG). Yollar: INTEG/lib/ui/widgets/peace_notice_overlay.dart (yeniden yaz; istersen peace_notice_banner.dart olarak yeniden adlandir: tutarli olsun, eski dosyayi sil), push_status_tile.dart, peace_reminder_details.dart, INTEG/lib/ui/app_shell.dart (yalniz bizim ekledigimiz hunk), INTEG/test/ui/**.
F1 cekirdek duzeltmelerini bitirdi: ${WF}/F1-rapor.md (ONCE OKU: denetleyici arayuzu). F1 ozeti: ${f1 ? f1.summary : '(F1 ozeti yok)'}
Baglam: ilk tur arayuz (A2) afisi MaterialApp.builder icinde Navigator USTUNDE bir Stack/Positioned kart olarak ciziyordu. Bagimsiz elestirmen R2 CALISTIRARAK sunlari kanitladi (${WF}/R2-rapor.md, kanit testleri ${WF}/r2_copy/test/ui/): (R2-1) Tab ile afis dugmelerine ulasilamiyor (kart rota FocusScope'u disinda); (R2-2) kalici afis her sayfanin AppBar eylemlerini kapatiyor ve dokunuslari yutuyor (yatayda ekranin %55'i); (R2-3) buyuk yazi + 320x568'de metin bolgesi cokuyor, 3.0 olcekte tasma; mevcut testler gorunurlugu olcmuyor; (R2-4) failed tile metni kalici reddi yanlis anlatiyor; (R2-5) acik temada successText kontrasti 3.55:1.
KARAR: Afisi, yumusak izin istemini ve sonuc iletisini ScaffoldMessenger uzerinden goster (AppShell zaten komut hatalarini boyle gosteriyor): bildirim afisi ve yumusak istem = MaterialBanner (icerik sayfayi ASAGI iter, rota odak kapsamindadir, Tab ile ulasilir, standart semantik); sonuc iletisi (closeMessage) = SnackBar. PeaceNoticeHost artik Stack/Positioned KULLANMAZ: yalnizca denetleyiciyi dinleyip ScaffoldMessenger'a banner/snackbar gosteren/kaldiran GORUNMEZ bir kopru widget'idir (build: child'i aynen dondurur).
 - Banner icerigi reaktif olmali (closing iken ilerleme gostergesi + 'Hepsini kapat' devre disi; yetki yoksa gizli): MaterialBanner bir kez gosterilir, icerik/actions icinde Consumer/ListenableBuilder ile denetleyiciye baglanir; gereksiz yeniden gosterme/titresim yok (imza: tur + dedupeKey). Oncelik: bildirim afisi > yumusak istem. Bildirim kalkinca/denetleyici dispose olunca banner kaldirilir (removeCurrentMaterialBanner). Hizli ardisik degisimlerde animasyon cakismasi/istisna yok; dispose sonrasi messenger erisimi yok.
 - Metin blogu buyuk yazida tasmamali: icerik ConstrainedBox(maxHeight: ekranin ~%35'i) + SingleChildScrollView; GERCEK yazi tipiyle (R2'nin yontemi: SDK onbelleginde Roboto; ${WF}/R2-rapor.md ve r2_copy/test/ui/r2_real_test.dart'a bak) 320x568 ve 360x740, olcek 1.0/1.5/2.0/3.0: baslik+govde en az bir satir gorunur, eylemler erisilebilir, RenderFlex tasmasi YOK. 'hareketi azalt' saygisi; dokunma hedefi >= 48 dp; metin blogu canli bolge (liveRegion).
 - Sonuc iletisi: SnackBar (mevcut AppShell snackbar'lariyla cakismadan: hideCurrentSnackBar sonra goster; closeMessage'i denetleyiciden bir kez tuket: mevcut denetleyici API'sine/mesaj sahipligine bak).
 - Klavye erisilebilirligi TESTI: gercek bir Scaffold rotasi icinde banner gosterilirken Tab ile 'Hepsini kapat' ve 'Kapat' dugmelerine odak gectigini dogrula (R2'nin r2_kbd_test.dart'i).
 - Hit-test TESTI: banner varken sayfanin AppBar geri dugmesine dokunus CALISIR (icerik asagi itilir).
 - app_shell.dart baglantisi: kopru ScaffoldMessenger'i MaterialApp.builder icinden bulabilir (builder ScaffoldMessenger icindedir) ya da AppShell'in _messengerKey'ini kullanir: hangisi daha kucuk ve saglamsa; ${WF}/A2-app-shell.diff'i guncelle (${WF}/F2-app-shell.diff). Provider yerlesimi (builder icinde) ayni kalabilir. AppShell INTEG'de derlenmez: 'dart analyze lib/ui/app_shell.dart' ile yalniz bizim satirlarimizin hata uretmedigini dogrula; testlerde AppShell'i import ETME, kendi harness'ini (MaterialApp builder + Scaffold rotalari) kullan.
 - R2-4: PushStatusTile 'failed' durumunda: denetleyicinin pushRegistrationBlocked'i true ise durust metin 'Bildirim kaydı bu cihazda kabul edilmedi. Çıkış yapıp yeniden giriş yapmayı deneyin.' ve 'Yeniden dene' dugmesi (controller.retryPushRegistration()); gecici ise mevcut 'otomatik yeniden denenecek' metni (+ yeniden dene dugmesi olabilir). Testi bunu sabitlesin.
 - R2-5: tile durum rengi: metin Theme.of(context).colorScheme.onSurface/primary (AA), yalniz simge yesil; acik/koyu temada kontrast TESTI (hesaplayan test: >= 4.5:1).
 - PeaceReminderDetails ve PushStatusTile'in diger mantigi degismez; ayar kartina yerlestirme notu ayni (2 tek satir).
Hedefli: flutter analyze lib/ui/widgets lib/ui/app_shell.dart test/ui lib/services lib/models test/services test/push test/support (0 sorun); flutter test test/ui test/services test/push (hepsi gecmeli). En az 8 mutasyonla testlerin yakalama gucunu kanitla. Rapor: ${WF}/F2-rapor.md.
`

const REVIEW_COMMON = `
SEN BAGIMSIZ BIR ELESTIRMENSIN: yazilan kodu CURUTMEYE calis (adversarial). Dosya DEGISTIRME (yalnizca ${WF}/RR*-rapor.md ve gecici kopyalarini WF altinda yaz). Yalnizca KOD ALINTILI KANITLA bulgu bildir; tahmin/stil/'olabilir' yazma. Her bulgu icin: dosya:satir, kisa kod alintisi, somut girdi/durum -> yanlis sonuc senaryosu, onerilen duzeltme. Kritik/yuksek bulgulari mumkunse calistirarak (hedefli flutter test, WF altindaki gecici kopyada) kanitla. previousFindingsStatus alaninda ONCEKI turun ilgili bulgularinin (B1-B8, R2-1..R2-5, R3-01, R3-06) gercekten KAPANIP kapanmadigini tek tek yaz. Bu turun farki: diff -ru -x .dart_tool -x build ${INTEG_WF1}/lib ${INTEG}/lib (ve test, android, ios, pubspec). Raporlar: ${WF}/F1-rapor.md, F2-rapor.md, F3-rapor.md; onceki tur: A1-rapor.md, A2-rapor.md, R1-rapor.md, R2-rapor.md, R3-rapor.md.
`

const RR1 = COMMON + REVIEW_COMMON + `
GOREVIN: RR1 - CEKIRDEK DELTA INCELEMESI. Odak: bu turda degisen INTEG/lib/services/** (push_gateway, push_coordinator, peace_notice_controller, automation_state cikis kancasi, ev_cloud_api_service, api_models) ve testleri.
Ozellikle ara: deleteToken akisinin dogrulugu (zaman asimi tavani, yaris: stop sirasinda start, cift stop, deleteToken'in asili kalmasi, hata yutma), stop(unregister,invalidateLocalToken) kombinasyonlari ve cagiranlarin dogru kombinasyonu secmesi (rol kaybi vs oturum bitisi vs servis oturumu vs cikis), 1 sn cikis beklemesi + arka plan tamamlanmasi (cikis sonrasi kancanin API oturumu olmadan calismasi, istisna/unawaited sizintisi, FakeAsync dışında gerçek zamanlayıcı sızıntısı), tek ucus (es zamanli logout), logoutAll'dan kancanin kalkmasinin sonuclari, B2 afis kaldirma mantiginin YANLIS POZITIFI (yanlis evin verisiyle ya da bayat veriyle gecerli afisi silmek; yeni bildirim yarisi), includeShutters varsayilaninin tum cagiranlarda tutarliligi (eski dugme, afis, testler), pushRegistrationBlocked/retry'in durum makinesiyle uyumu (sonsuz dongu/gereksiz kayit baskisi), bilinmeyen ev bildirimini yok sayma kuralinin soguk acilis/ev listesi yuklenmeden gelen bildirimi kaybetme riski, regresyonlar (mevcut test/services testleri; yeni testlerin gercekten kirmizi->yesil olup olmadigi: mutasyonla), AutomationState farkinin MINIMALLIGI ve gercek agaca (INTEG_BASE, 18:13) temiz uygulanabilirligi.
`

const RR2 = COMMON + REVIEW_COMMON + `
GOREVIN: RR2 - ARAYUZ DELTA INCELEMESI + ERISILEBILIRLIK. Odak: INTEG/lib/ui/widgets/(peace_notice_*, push_status_tile, peace_reminder_details), INTEG/lib/ui/app_shell.dart farki (${WF}/F2-app-shell.diff), INTEG/test/ui/**, F3 platform degisikliklerinin (android/ios) dogrulugu ve gercek agaca uygulanabilirligi (${WF}/F3-platform.patch ve F3-gitignore.patch'i 'git apply --check' ile kendin dene).
Ozellikle ara (R2'nin kanit yontemlerini kullan: WF/r2_copy ve test dosyalari): MaterialBanner koprusunun tuzaklari - Scaffold'suz rota/diyalog/bottom sheet, ic ice Scaffold (banner ikinci kez mi cikiyor?), route gecislerinde banner kalintisi veya kaybi, ScaffoldMessenger'in birden fazla olmasi, hot restart, banner ve snackbar cakismasi (AppShell'in komut-hatasi snackbar'lari ile), dispose sonrasi messenger erisimi, bildirimin hizli degisimi/ardisik gosterme-kaldirma animasyon istisnalari, banner icerigi reaktifligi (closing/closeMessage guncellenirken yeniden gosterme titresimi), Tab odagi + Enter ile 'Hepsini kapat' tetiklenmesi, ekran okuyucu semantigi (liveRegion, etiketler), buyuk yazi (gercek Roboto; 320x568 ve 360x740; 1.0/1.5/2.0/3.0), karanlik/aydinlik tema kontrasti, hareketi azalt, PushStatusTile durumlari (failed/blocked/needsPermission/denied) ve yeniden dene dugmesi, testlerin gorunurluk/etkilesimi gercekten olcup olcmedigi (Ahem yerine gercek font; mutasyon). Android: Kotlin kanal kodunun dogrulugu (kanal kimligi sunucuyla birebir, API korumasi, FlutterFragmentActivity ile uyum), ic_stat_peace.xml gecerliligi, manifest meta-data konumu; iOS: AppDelegate/bridging header eklenti kaynagiyla uyumu.
`

// ---------------------------------------------------------------------------------------------
phase('Duzelt')
log('F1 (cekirdek) ve F3 (platform) paralel basliyor')
const p1 = agent(F1, { label: 'F1 cekirdek duzeltme', phase: 'Duzelt', schema: RESULT, effort: 'high' })
const p3 = agent(F3, { label: 'F3 platform hunk', phase: 'Duzelt', schema: RESULT, effort: 'medium' })

const f1 = await p1
if (!f1) log('F1 basarisiz: arayuz asamasi atlandi')
phase('Arayuz')
const f2 = f1 ? await agent(F2(f1), { label: 'F2 MaterialBanner arayuz', phase: 'Arayuz', schema: RESULT, effort: 'high' }) : null
const f3 = await p3

phase('Delta')
const reviews = await parallel([
  () => agent(RR1, { label: 'RR1 cekirdek delta', phase: 'Delta', schema: FINDINGS, effort: 'high' }),
  () => agent(RR2, { label: 'RR2 arayuz+platform delta', phase: 'Delta', schema: FINDINGS, effort: 'high' }),
])
const all = reviews.filter(Boolean)
const counts = { critical: 0, high: 0, medium: 0, low: 0 }
for (const r of all) for (const f of r.findings) counts[f.severity] += 1
log('Delta bulgulari: ' + JSON.stringify(counts))
return { f1, f2, f3, reviews: all, counts }
