export const meta = {
  name: 'wp-h-flutter-entegrasyon',
  description: 'Gece hatirlatmasi Flutter istemcisini izole kopyalarda hazirla: cekirdek + arayuz + platform/derleme, 3 bagimsiz elestirmen',
  phases: [
    { title: 'Uygula', detail: 'A1 cekirdek (INTEG) ve A3 platform/derleme (HEAD) paralel' },
    { title: 'Arayuz', detail: 'A2 afis / yumusak izin istemi / ayar karti bilesenleri (A1 sonrasi)' },
    { title: 'Incele', detail: 'R1 durum+denetleyici, R2 arayuz+erisilebilirlik, R3 platform+guvenlik' },
  ],
}

const SP = 'C:/Users/FINGON~1/AppData/Local/Temp/claude/g--site-site-kapi-kontrol/a379bdb3-93a0-4167-8a2c-eed43f0e926f/scratchpad'
const INTEG = SP + '/flutter_integ'
const HEAD = SP + '/flutter_head'
const INTEG_BASE = SP + '/flutter_integ_base'
const HEAD_BASE = SP + '/flutter_head_base'
const WF = SP + '/wp-h-flutter-wf'
const DOCS = 'G:/site/ev_otomasyon/docs/superpowers/analysis'

const COMMON = `
BAGLAM
Ev Otomasyonu (Flutter 3.47 / Dart 3.13, provider, REST + MQTT) uygulamasina "acik kalan lambalar icin gece hatirlatmasi" (FCM push) istemci tarafi ekleniyor. SUNUCU TARAFI BITTI ve gercek PostgreSQL'de dogrulandi. Sen, istemci entegrasyonunu IZOLE KOPYALARDA hazirlayan bir ekibin parcasisin. Baska bir (orkestrator) oturum, baska bir ekiple GERCEK depoyu (G:/site/ev_otomasyon) su anda es zamanli yeniden yaziyor: oraya HICBIR SEY YAZMA (yalnizca okuma serbest). Commit yapma. Sir (.env, anahtar, jeton) okuma/yazma/yazdirma.

KOPYALAR (yalniz bunlara yaz):
- INTEG = ${INTEG}
  Gercek agacin 18:13 anlik kopyasi. DIKKAT: orkestrator Dalga 2'yi yaziyor; bu kopya BUTUN OLARAK DERLENMIYOR (lib/ui/pages/auth/**, service_mode_page.dart, replace_board_dialog.dart ve eski testler yarim; ~57 analiz hatasi var). Bu yuzden INTEG'de TAM 'flutter analyze', TAM 'flutter test' veya build CALISTIRMA (anlamsiz ve kirmizi). Yalnizca kendi dosyalarini hedefleyerek calistir: 'flutter analyze <dosya-veya-dizin> ...' ve 'flutter test <test dosyasi>'. Var olan hatalar senin degil; YENI hata ekleme. Taban cizgisi kayitlari: ${WF}/baseline-integ-analyze.txt (57 analiz hatasi) ve ${WF}/baseline-integ-failures.txt (18:13 durumunda tam 'flutter test' = 575 gecti, ~30 dosya/test kirik; kiriklar esas olarak eski ust duzey test/*.dart dosyalari - auth/servis sayfalarina ve kaldirilmis API'lere bagli; test/services/** buyuk olcude geciyor). Kendi dosyalarini ve dokundugun mevcut testleri bu kayitlarla karsilastir.
- HEAD = ${HEAD}
  Deponun son commit'i (8cf17c0), kendi icinde tutarli: analiz 0 sorun, 107 test, derlenir. Bagimlilik cozumu, uygulamanin analiz kurallari ve derleme (APK, web) dogrulamasi YALNIZ burada yapilir.
- INTEG_BASE = ${INTEG_BASE} ve HEAD_BASE = ${HEAD_BASE}: dokunulmamis kaynak kopyalari (SALT OKUNUR; farklari gormek icin: diff -ru -x .dart_tool -x build ...).
- Rapor/defter dizini WF = ${WF} (buraya serbestce yaz).

KAYNAK MALZEME (oku):
- ${DOCS}/wp-h-flutter/ : lib/services/push/*.dart.txt (push_config, peace_notice, push_gateway, push_coordinator), test/push/*.dart.txt, ENTEGRASYON.md, PUSH_KURULUM.md. Sandbox'ta yazildi; flutter analyze 0 sorun, 209 test gecti. Moduller bagimsizdir (yalniz birbirine goreli import). Gerekmedikce DEGISTIRME; degistirirsen gerekceyi ve testi raporla.
- ${DOCS}/wp-h-contracts-satirlari.md : sunucu sozlesmesi (PUT/DELETE /me/push-tokens, peace GET v2, close-all v2 yaniti, FCM data yuku).
- ${INTEG}/docs/CONTRACTS.md : genel sozlesme (JSON snake_case, kimlikler UUID dizesi; tek istisna notice_id tam sayi).

MIMARI KARARI (orkestratorle mutabik; COK ONEMLI):
1. Entegrasyon sayfalara ve AutomationState'e DEGIL uygulama kabuguna baglanir. Push mantigi kendi dosyasinda ayri bir ChangeNotifier (PeaceNoticeController) olur; AutomationState'i dinler (addListener, sessionEvents) ve yalnizca onun PUBLIC API'sini kullanir. Bildirim afisi lib/ui/app_shell.dart icindeki MaterialApp.builder'da OVERLAY olarak gosterilir; sayfalara satir eklenmez.
2. AutomationState'e YALNIZCA su kucuk kanca eklenir: cikistan once (oturum belirteci hala gecerliyken) calisan geri cagrilar (push belirtecini sunucudan silmek icin). Baska hicbir yerine dokunma.
3. E1/E2/F ekipleri dashboard, ayarlar sayfasi, main.dart, auth sayfalari ve automation_state.dart'i HALA yaziyor. Mevcut dosyalara yapilan HER ekleme minimum olsun (bicim degisikligi, yeniden adlandirma, ilgisiz temizlik YOK; mevcut satirlari yeniden dizme YOK). Yeni islev YENI dosyalarda. Yama sonradan hareketli bir agaca uygulanacak.
4. Firebase yapilandirmasi (google-services.json / GoogleService-Info.plist) YOKTUR ve kullanicidan gelmeden push calismaz. Moduller yapilandirma yoksa (PushConfig.fromEnvironment() == null) hicbir Firebase cagrisi yapmadan 'unsupported' kalir; uygulama push'suz surumle AYNI davranir. Bu ozellik KORUNMALI.
5. pubspec.yaml'a firebase paketleri eklenmesi ayri bir hunk olarak tutulur (kullanicidan ayrica onay alinacak).

GENEL KURALLAR:
- Turkce kullanici metinleri ve Turkce yorumlar (mevcut kodun uslubu); yorumlar NEDEN'i anlatir. ONEMLI: bu gorev metnindeki Turkce ifadeler ASCII'ye sadelestirildi (ornek: 'Acik kalan lambalar icin gece bildirimi almak ister misiniz?'); kullaniciya gorunen METINLERI ve yorumlari DOGRU Turkce karakterlerle (ç, ğ, ı, ö, ş, ü, İ) yaz: 'Açık kalan lambalar için gece bildirimi almak ister misiniz?'. Kodu degistirmeden once ilgili mevcut dosyalari (AutomationState, ApiException, test/support, app_shell) OKU; anlamadigin yere dokunma. Gizli veri / push belirteci / ev adi log'a yazilmaz.
- Windows: yeni dosyalari LF yaz; mevcut dosyada satir sonunu (CRLF/LF) node ile say ve koru. Cok satirli string degistirmeden once bunu kontrol et. Regex / ters egik cizgi / kesme isareti iceren betikleri Bash heredoc veya node -e ile DEGIL, Write araciyla dosyaya yazip calistir (kabuk bunlari bozuyor). Node'da yol 'C:/...' veya 'G:/...' bicimindedir.
- Flutter komutlari uzun surebilir: 10 dakikayi asabilecek olanlari (build) run_in_background ile calistir ve ciktiyi dosyaya al (zaman asimi: 1800000 ms). ASLA 'flutter run', adb, emulator, pio, docker calistirma; 54329 / 1883 / 18083 / 5000 / 8081-8083 portlarina dokunma (baskalarina ayrili).
- dart format'i yalnizca KENDI yeni dosyalarina uygula; mevcut dosyalarin bicimini bozma.
- Durust ol: calistirmadigini 'gecti' deme; dogrulayamadigini acikca yaz. Sonucu semaya uygun dondur ve ayrintili raporu WF dizinine yaz.
`

const RESULT = {
  type: 'object',
  properties: {
    agent: { type: 'string' },
    summary: { type: 'string' },
    filesCreated: { type: 'array', items: { type: 'string' } },
    filesModified: { type: 'array', items: { type: 'string' } },
    testsAdded: { type: 'array', items: { type: 'string' } },
    verification: {
      type: 'array',
      items: {
        type: 'object',
        properties: { command: { type: 'string' }, result: { type: 'string' }, ok: { type: 'boolean' } },
        required: ['command', 'result', 'ok'],
      },
    },
    deviations: { type: 'array', items: { type: 'string' } },
    notVerified: { type: 'array', items: { type: 'string' } },
    reportPath: { type: 'string' },
  },
  required: ['agent', 'summary', 'filesCreated', 'filesModified', 'verification', 'notVerified', 'reportPath'],
}

const FINDINGS = {
  type: 'object',
  properties: {
    agent: { type: 'string' },
    summary: { type: 'string' },
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
  required: ['agent', 'summary', 'findings', 'checked', 'reportPath'],
}

// ---------------------------------------------------------------------------------------------
const A1 = COMMON + `
GOREVIN: A1 - CEKIRDEK (INTEG kopyasinda).
Sahip oldugun yollar: INTEG/lib/services/**, INTEG/lib/models/**, INTEG/test/services/**, INTEG/test/push/**, INTEG/pubspec.yaml. Baskasinin yollarina (INTEG/lib/ui/**, android/**, ios/**) YAZMA.

Yap:
1. INTEG/lib/services/push/ altina ${DOCS}/wp-h-flutter/lib/services/push/*.dart.txt dosyalarini .dart olarak kopyala (moduller testli; icerigi KORU). INTEG/test/push/ altina testleri kopyala ve ice aktarmalari 'package:peace_sandbox/' -> 'package:ev_otomasyon/' cevir. Uygulamanin analysis_options.yaml'i sandbox'tan farkli olabilir: INTEG icinde 'flutter analyze lib/services/push test/push' calistir; yeni uyari cikarsa modulleri minimum degisiklikle duzelt (hangi dosyada neyi neden degistirdigini raporla).
2. INTEG/pubspec.yaml: dependencies'e firebase_core: ^4.15.0 ve firebase_messaging: ^16.7.0, dev_dependencies'e fake_async: ^1.3.3 ekle (yalniz bu 3 satir + gerekirse yorum; baska hicbir seye dokunma). 'flutter pub get' calistir (INTEG'de calisir; cozum cakismasi veya dusurulen paket varsa raporla). pubspec.lock farkinin yalnizca yeni paketleri ekledigini dogrula (mevcut paket SURUMU degismemeli; degisirse raporla).
3. INTEG/lib/services/ev_cloud_api_service.dart: (a) closeAllOpenLights(String homeId, {int? noticeId, bool? includeShutters}) geriye uyumlu genislet (govde: home_id, notice_id?, include_shutters?; null-aware map elemani sozdizimi uygulamada zaten kullaniliyor: 'anahtar': ?deger); (b) registerPushToken({required String token, required String platform, String? appVersion}) -> PUT /v1/me/push-tokens; (c) unregisterPushToken(String token) -> DELETE /v1/me/push-tokens (govde {token}; kisa zaman asimi: cikisi geciktirmesin). Mevcut _call/_sendRaw/DELETE-govde desteğini ve zaman asimi secenegini OKU ve onlara uy; yeni HTTP yolu icat etme. Yalniz sinifin uygun yerine EKLEME yap.
4. INTEG/lib/services/push_token_api_adapter.dart (YENI): push_coordinator.dart'taki PushTokenApi arayuzunu EvCloudApiService uzerinden saglar; kalici hatalar (ApiException.statusCode 400/401/403/404) PushRegistrationRejected olur, digerleri (ag=0, 429, 5xx) oldugu gibi firlar. (ENTEGRASYON.md bolum 3 taslagi; gercek ApiException alanlarini dogrula.)
5. INTEG/lib/models/api_models.dart: CloseAllResult'a v2 alanlari ekle (closedShutters, skippedCount (varsayilan 0), nothingToDo (varsayilan false), resolved (varsayilan false), noticeId) - v1 sunucu yanitiyla da calismali (alan yoksa varsayilan). PeaceNotificationSettings (ayar yanitinin tipli gorunumu) icin v2 alanlarini ekle: stale, devicesTotal, devicesOnline, openShutters (sayi veya liste), lastNotice (yeni kucuk sinif PeaceLastNotice: id, localDate, status, summaryText, openLightsCount, openShuttersCount, createdAt, resolvedAt) - hepsi istege bagli/varsayilanli; mevcut kullanicilari ve testleri bozma. Mevcut asInt/asBool/asString yardimcilarini kullan.
6. INTEG/lib/services/automation_state.dart: YALNIZCA cikis kancasi:
   - private liste + public addBeforeLogoutHook(Future<void> Function() hook) -> kaldirici geri cagri dondurur;
   - private _runBeforeLogoutHooks(): her kanca en cok 3 sn bekletilir, hata/zaman asimi yutulur, cikisi ENGELLEMEZ; liste bossa HIC await yapilmaz (mevcut cikis zamanlamasi ve mevcut testler AYNEN kalmali);
   - logout() ve logoutAll() basinda (cloudApi.logoutAll()'dan ONCE) cagrilir.
   Bu en kucuk degisiklik olmali (yaklasik 15 satir). Once dosyayi oku: AutomationState ~2800 satir; sessionEvents/commandFailures akislari ve ChangeNotifier addListener var. test/services/automation_state_session_test.dart gibi mevcut testlerin desenini izleyerek kanca icin test yaz (cikista kanca oturum belirteci hala gecerliyken calisir; zaman asimi cikisi engellemez; hata yutulur; kanca yokken davranis degismez).
7. INTEG/lib/services/peace_notice_controller.dart (YENI): PeaceNoticeController extends ChangeNotifier with WidgetsBindingObserver (SARTNAME asagida). AutomationState'in PUBLIC API'sini kullan. Public olmayan bir seye ihtiyac duyarsan once alternatif ara; yoksa raporla (AutomationState'e baska ekleme YAPMA).
8. Testler: INTEG/test/services/peace_notice_controller_test.dart (gercek AutomationState + sahte API; mevcut test/support ve test/services desenleriyle; sahte PushCoordinator/PushGateway), push_token_api_adapter_test.dart, ev_cloud_api_service push uclari + closeAll v2 govdesi testi, CloseAllResult/PeaceNotificationSettings v2 ayristirma testi, cikis kancasi testi. Testleri yalnizca hedefleyerek calistir ve gecir. Ayrica kancanin dokundugu mevcut testlerin (ornegin test/services/automation_state_session_test.dart) HALA gectigini calistirarak dogrula (derlenmiyorlarsa INTEG_BASE'de de derlenmedigini kanitla).

PEACENOTICECONTROLLER SARTNAMESI
Kurucu: PeaceNoticeController({required AutomationState state, PushCoordinator? push, PromptStore? promptStore, DateTime Function()? now}). promptStore: 'izin penceresi daha once soruldu mu' bayragi icin kucuk arayuz (varsayilan: shared_preferences'e yazan; uygulamada zaten kullaniliyor - mevcut kullanimi incele; testte bellek ici sahte).
Okuma durumu: PeaceNotice? pending; PushState pushState; bool pushPermissionDenied; bool softPromptVisible; bool closing; String? closeMessage (kullaniciya gosterilecek sonuc/hata metni, Turkce).
Davranislar:
 a) Uygunluk: state.isAuthenticated && !state.isServiceSession && bulut modunda && state.homes icinde rolu owner veya resident olan en az bir ev (mevcut rol sabitleri/yardimcilari icin lib/models/capabilities.dart ve HomeModel.role'a bak). Her state bildiriminde yeniden degerlendir; yalnizca DEGISIMDE harekete gec. Uygun olunca push.start(promptForPermission: false); uygun olmaktan cikinca push.stop(unregister: false). Sistem izin penceresi kendiliginden ACILMAZ.
 b) Yumusak istem: uygun && pushState == needsPermission && !pushPermissionDenied && promptStore'a gore daha once sorulmadiysa softPromptVisible = true. requestPermission(): bayragi kalicilastir, push.requestPermissionAndRegister(); dismissSoftPrompt(): bayragi kalicilastir (bir daha sorma; ayar kartindaki dugme kalir).
 c) Cikis kancasi: kurucuda state.addBeforeLogoutHook(() => push.stop()) (unregister: true; en cok 3 sn). dispose'ta kancayi kaldir.
 d) sessionEvents: SessionExpiredEvent -> push.stop(unregister: false) ve pending/dismissed temizle.
 e) push.notices: _onNotice: kimligi dogrulanmamis/servis oturumu ise yok say; source != foreground ve etkin ev bildirimin evinden farkliysa ve ev listede varsa state.selectHome(home); pending = notice; notifyListeners; etkin ev bildirim evi ise state.fetchPeaceNotification() ve state.refresh(silent: true) (bayat sayi olmasin). Onceden kapatilmis (dismissed) bildirimi (dedupeKey) tekrar gosterme.
 f) Yedek afis: state bildirimlerinde state.peaceNotificationData referansi degistiyse PeaceNotice.fromSettings(data, homeName: state.activeHome?.name) ile uret (ENTEGRASYON.md bolum 4.6 kurallari): null ise ve pending.source == settings ise pending'i kaldir (push kaynakli afise DOKUNMA); dismissed ise gosterme; baska bir afis zaten pending ise ona dokunma.
 g) closeAll(): pending yoksa/yetki yoksa (state.capabilities.canUseGroupCommands) bir sey yapma (anlasilir closeMessage); closing = true; state.cloudApi.closeAllOpenLights(home.id, noticeId: notice.noticeId) -> CloseAllResult.fromJson; resolved || nothingToDo ise dismiss; skippedCount > 0 ise afis acik kalir ve closeMessage = sunucu mesaji; nothingToDo ise 'kapatildi' DENMEZ (sunucu mesajini goster); ApiException'da kullaniciya gosterilebilir mesaj (mevcut ApiException API'sini kullan); sonunda closing = false, state.refresh(silent: true) ve state.fetchPeaceNotification(). Bildirim baska eve aitse (state.activeHome.id != notice.homeId) once o eve gec ya da anlasilir hata ver.
 h) dismiss(): pending'i dismissed kumesine ekle ve temizle (oturum boyunca; cikista/oturum bitiminde kume ve pending sifirlanir).
 i) WidgetsBindingObserver: didChangeAppLifecycleState(resumed) -> uygunsa push.refresh().
 j) dispose(): tum abonelikleri iptal et, observer'i kaldir, kancayi kaldir, kendi olusturdugu PushCoordinator'i dispose et; dispose sonrasi gelen olaylar sessizce yok sayilir (notifyListeners cagrilmaz).
 k) Hicbir kosulda istisna disari sizmaz; push zaman asimi/basarisizliklari AutomationState akislarini bozmaz. Yaris/epoch: cikis/oturum degisiminde ucustaki closeAll sonucu yeni oturuma yansimamali.
PushCoordinator'in gercek API'sini (start/stop/refresh/requestPermissionAndRegister/states/notices/dispose; PushState enum) push_coordinator.dart'tan OKU ve ona uy.

CIKTI: semaya uygun; ayrica ${WF}/A1-rapor.md dosyasina ayrintili rapor yaz (degisen dosyalar, kararlar, sapmalar, dogrulanamayanlar, kullandigin AutomationState public API listesi).
`

const A3 = COMMON + `
GOREVIN: A3 - PLATFORM + DERLEME UYUMU (HEAD kopyasinda; INTEG'e dokunma). Sahip oldugun yollar: HEAD/** (hepsi).
HEAD, deponun son commit'idir (eski ama kendi icinde tutarli). Amac: pubspec bagimliliklarinin, push modullerinin ve platform degisikliklerinin GERCEK uygulamanin Android ve web derlemesiyle uyumunu KANITLAMAK. (Windows derlemesi taban cizgisinde ZATEN kirik: local_auth_windows STL1011; Windows'u deneme.)
Adimlar:
1. Taban cizgisi: HEAD'de 'flutter pub get', 'flutter analyze' (beklenen 0 sorun), 'flutter test' (beklenen 107 gecti) - sonuclari kaydet. Taban cizgisi kirmiziysa nedenini raporla ve ilerlemeden once ayir. Ayrica DEGISIKLIK ONCESI 'flutter build web' (run_in_background; ~80 sn) basarili mi kaydet.
2. Bagimliliklar: pubspec.yaml'a firebase_core ^4.15.0, firebase_messaging ^16.7.0, dev fake_async ^1.3.3; 'flutter pub get'; pubspec.lock farki yalnizca yeni paketler olmali (mevcut surum degisimi/dusurme varsa raporla). Cozum cakismasi cikarsa uyumlu en yuksek surumleri bul ve raporla.
3. Moduller: ${DOCS}/wp-h-flutter/lib/services/push/*.dart.txt -> HEAD/lib/services/push/*.dart; testler -> HEAD/test/push/*.dart ('package:peace_sandbox/' -> 'package:ev_otomasyon/'). 'flutter analyze' HEAD'in analysis_options.yaml'i ile 0 sorun olmali: uygulama kurallari sandbox'tan farkliysa modulleri minimum degisiklikle duzelt (ayrintiyi raporla). 'flutter test' tum testler (107 + push testleri) gecmeli.
4. Android: HEAD/android/app/src/main/kotlin/**/MainActivity.kt'ye 'peace_reminder' bildirim kanalini (IMPORTANCE_HIGH, ad 'Gece hatirlatmasi') olusturan kodu ekle (ENTEGRASYON.md bolum 5.1 taslagi; mevcut sinif yapisini OKU, Flutter sablonuna uygun: configureFlutterEngine veya onCreate; API 26 korumasi). AndroidManifest.xml'de gerekli degisiklik YOK (POST_NOTIFICATIONS eklentiden birlesir): bunu derleme sonrasi birlesik manifestten (build/app/intermediates/merged_manifests/**) dogrula ve POST_NOTIFICATIONS ile FirebaseMessagingService kayitlarini raporla. 'flutter build apk --debug' (yaklasik 7 dk; run_in_background, cikti ${WF}/A3-apk.log) BASARILI olmali; uyarilari raporla (Kotlin KGP uyarisi beklenen). minSdk uyumunu (firebase_messaging 23 ister) dogrula.
5. Web: degisikliklerden SONRA tekrar 'flutter build web': basarili kalmali (moduller web'de dart:io yuzunden kirilmamali; kirilirsa conditional import/guard ile minimum duzelt).
6. iOS (yalniz statik; macOS/Xcode yok): HEAD/ios/Runner/Info.plist'e UIBackgroundModes -> remote-notification ekle; AppDelegate.swift'i OKU (UIScene / FlutterImplicitEngineDelegate mi?) ve ENTEGRASYON.md bolum 5.2'deki yonergeyi yalnizca derlenebilir oldugundan EMIN olabiliyorsan uygula: eklenti kaynagini pub onbelleginde (%LOCALAPPDATA%/Pub/Cache veya ~/.pub-cache; firebase_messaging paketinin ios/ dizini) OKUYARAK dogrula (ornegin configureNotificationCenterDelegate var mi, hangi import gerekir); emin degilsen EKLEME ve nedenini belgele. project.pbxproj / entitlements DOKUNMA (Xcode'da elle 'Push Notifications' yetenegi eklenecek; belgele). plutil yoksa Info.plist'in XML gecerliligini node ile dogrula.
7. Belge onerileri: PUSH_KURULUM.md ve ENTEGRASYON.md bolum 5'te gercek derleme sonuclarina gore duzeltilmesi gereken yerleri ${WF}/A3-belge-onerileri.md'ye yaz (belgeleri kendin degistirme).
8. HEAD ile HEAD_BASE arasindaki farki (pubspec.yaml, pubspec.lock, lib/services/push/**, test/push/**, android/**, ios/**) 'diff -ru' ile incele ve ${WF}/A3-degisen-dosyalar.txt'e listele; beklenmeyen degisiklik varsa temizle.
Not: Her flutter komutu bir oncekinin bitmesini beklesin (ayni dizinde es zamanli flutter calistirma).

CIKTI: semaya uygun; ayrica ${WF}/A3-rapor.md dosyasina ayrintili rapor (komut, sonuc, sure, uyarilar; birlesik manifest alintilari; taban cizgisi vs sonrasi karsilastirmasi).
`

const A2 = (a1) => COMMON + `
GOREVIN: A2 - ARAYUZ BILESENLERI (INTEG kopyasinda).
Sahip oldugun yollar: INTEG/lib/ui/widgets/peace_notice_overlay.dart (YENI), INTEG/lib/ui/widgets/push_status_tile.dart (YENI), INTEG/lib/ui/widgets/peace_reminder_details.dart (YENI), INTEG/test/ui/** (yeni test dosyalari), ve INTEG/lib/ui/app_shell.dart'a COK kucuk baglanti (asagida). A1 cekirdegi bitirdi: INTEG/lib/services/peace_notice_controller.dart, push modulleri, CloseAllResult/PeaceNotificationSettings v2 alanlari hazir; A1 raporu: ${WF}/A1-rapor.md (once OKU). A1'in ozeti: ${a1 ? a1.summary : '(A1 ozeti yok)'}

Tasarim: mevcut tema belirteclerine (INTEG/lib/ui/theme/app_theme.dart, Theme.of(context)) uy; sabit renk/olcu icat etme. Acik/koyu tema, yazi olcegi 1.0-1.5 (tasma YOK), dokunma hedefi >= 48 dp, Semantics (afis icin canli bolge/liveRegion, dugme etiketleri), 'hareketi azalt' (MediaQuery.disableAnimations) saygisi; renge bagimli olmayan durum gostergeleri. Gorsel yon: sakin, guvenilir, canli; Dalga 5 sonradan cilalayacak, sen temiz ve tutarli bir temel kur.
1. peace_notice_overlay.dart:
   - PeaceNoticeHost(child): Stack ile child'in USTUNE overlay koyar; PeaceNoticeController'i Provider'dan okur (kok yeniden kurma YOK: yalnizca overlay alt agaci dinler; Selector/Consumer). Bildirim yokken agac maliyeti ~0 (SizedBox.shrink).
   - Bildirim afisi (controller.pending != null): ustte, SafeArea icinde, kart: baslik (ev adi, yoksa 'Gece hatirlatmasi'), govde (notice.body, yoksa 'Acik lamba ve panjur var.'), eylemler 'Hepsini kapat' (yetki yoksa gizli; closing iken ilerleme gostergesi + devre disi) ve 'Kapat'; closeMessage varsa altinda goster. Yumusak giris/cikis animasyonu (120-350 ms, easeOutCubic).
   - Yumusak izin istemi (pending yoksa ve controller.softPromptVisible): kompakt kart: 'Gece hatirlatmasi' / 'Acik kalan lambalar icin gece bildirimi almak ister misiniz?' ve 'Bildirimleri ac' / 'Simdi degil'.
   - Overlay MaterialApp.builder icinde (Navigator USTUNDE) yasayacak: Overlay/Navigator'a ihtiyac duyan bilesen (Tooltip vb.) KULLANMA; Material ve Directionality sagla. Sayfa icerigini orterken boyut icerige gore, ekranin en cok yaklasik %30'u.
2. push_status_tile.dart: PushStatusTile - PushState'e gore ENTEGRASYON.md bolum 7 tablosundaki Turkce metinler ve eylemler ('Bildirimleri ac' -> controller.requestPermission(); reddedilmisse yonlendirici metin). unsupported/idle -> SizedBox.shrink. Ayar kartina TEK satirla yerlestirilecek: const PushStatusTile().
3. peace_reminder_details.dart: PeaceReminderDetails - state.peaceSettings (v2 alanlari): 'Son hatirlatma: <gun> <saat> - acik N lamba, M panjur (kapatilmadi/kapatildi)', 'Cihazlar: x/y cevrimici', stale ise 'Cihaz cevrimdisi; acik lamba bilgisi guncel degil.' uyarisi. Veri yoksa gizli. Ayar kartina TEK satirla yerlestirilecek: const PeaceReminderDetails().
4. app_shell.dart baglantisi: INTEG/lib/ui/app_shell.dart (E1'in yeni dosyasi, 17:54 surumu) OKU. En kucuk ekleme: _AppShellState icinde PeaceNoticeController olustur (initState; state = context.read<AutomationState>()), dispose'ta dispose et; MaterialApp sarmalayicisina ChangeNotifierProvider<PeaceNoticeController>.value ekle ve MaterialApp.builder'da (varsa mevcut builder'i koruyarak) PeaceNoticeHost ile sar. Bu dosya INTEG'de TAM DERLENMEZ (auth_gate zinciri yarim): 'dart analyze lib/ui/app_shell.dart' ile yalnizca SENIN ekledigin satirlarin hata uretmedigini dogrula (baska dosyalardaki mevcut hatalar sayilmaz). Eklemeyi ayrica ${WF}/A2-app-shell.diff olarak kaydet (diff -u INTEG_BASE/lib/ui/app_shell.dart INTEG/lib/ui/app_shell.dart).
5. Testler (INTEG/test/ui/...): her bilesen icin widget testleri, MaterialApp(builder: ... PeaceNoticeHost(child: ...)) gibi KENDI harness'inle (AppShell'i import etme: derlenmez). Sahte PeaceNoticeController (alt sinif/arayuz) veya gercek denetleyici + sahte AutomationState/PushCoordinator; acik/koyu tema; textScaler 1.5 ile RenderFlex tasmasi YOK (tester.takeException() == null); Semantics; dugmelerin denetleyiciyi cagirmasi; yetki yokken 'Hepsini kapat' gizli; closing durumu; animasyonlarda pumpAndSettle zaman asimina girmemeli (sonsuz animasyon YOK). Testleri yalnizca hedefleyerek calistir ve gecir.
6. Gercek ayar sayfasina (device_settings_page.dart) ve dashboard'a DOKUNMA (E1 yeniden yaziyor). Tile/details bilesenlerinin tek satirlik yerlestirme noktasini ve metin-karti degisikligini ${WF}/A2-rapor.md'ye yaz.

CIKTI: semaya uygun; ayrintili rapor ${WF}/A2-rapor.md.
`

const REVIEW_COMMON = `
SEN BAGIMSIZ BIR ELESTIRMENSIN: yazilan kodu CURUTMEYE calis (adversarial). Dosya DEGISTIRME (yalnizca ${WF}/R*-rapor.md yaz). Yalnizca KOD ALINTILI KANITLA bulgu bildir; tahmin/stil/'olabilir' yazma. Her bulgu icin: dosya:satir, kisa kod alintisi, somut girdi/durum -> yanlis sonuc senaryosu, onerilen duzeltme. Kritik/yuksek bulgulari mumkunse calistirarak (hedefli flutter test) kanitla. Bulgu yoksa 'bulgu yok' demek serbest ama NEYI kontrol ettigini 'checked' listesine yaz. Farklari gor: diff -ru -x .dart_tool -x build ${INTEG_BASE}/lib ${INTEG}/lib ; diff -ru -x .dart_tool -x build ${HEAD_BASE} ${HEAD} (pubspec.lock, android, ios dahil). Raporlar: ${WF}/A1-rapor.md, A2-rapor.md, A3-rapor.md, A3-belge-onerileri.md.
`

const R1 = COMMON + REVIEW_COMMON + `
GOREVIN: R1 - DURUM + DENETLEYICI DOGRULUGU. Odak: INTEG/lib/services/peace_notice_controller.dart, push_token_api_adapter.dart, automation_state.dart kancasi (fark), ev_cloud_api_service.dart eklemeleri, api_models.dart v2 alanlari, push modulleri ile etkilesim, ilgili testler.
Ozellikle ara: yarislar (giris/cikis/ev degisimi/uygulama on plana gelme; cift start; stop sirasi; eski epoch sonucunun yeni oturuma sizmasi), unutulan abonelik/kanca/observer (bellek sizintisi, dispose sonrasi notifyListeners), yutulmayan istisnalar ve unawaited Future'lar, state bildirim firtinasi (her notifyListeners'ta agir is), mahremiyet (cikista pending/dismissed/bildirim verisi temizleniyor mu; belirtec silme cikisin ONUNDE mi; servis oturumu/misafir/dogrudan(LAN) modda davranis), cok evli kullanici, rol degisimi, AutomationState farkinin MINIMALLIGI (mevcut cikis zamanlamasini degistiriyor mu; kanca yokken davranis ayni mi), sozlesme uyumu (${DOCS}/wp-h-contracts-satirlari.md: govde/yanit alanlari, hata kodlari, notice_id tam sayi), testlerin gercekten bir sey kanitlayip kanitlamadigi (tautolojik/asiri sahte testler, yanlis yesil), kapsam boslugu. AutomationState degisikligi gercek agacin (INTEG_BASE, 18:13) uzerine uygulanacak: yamanin kucuk ve cakisma-dayanikli oldugunu degerlendir.
`

const R2 = COMMON + REVIEW_COMMON + `
GOREVIN: R2 - ARAYUZ + ERISILEBILIRLIK + KABUK BAGLANTISI. Odak: INTEG/lib/ui/widgets/peace_notice_overlay.dart, push_status_tile.dart, peace_reminder_details.dart, INTEG/lib/ui/app_shell.dart farki (${WF}/A2-app-shell.diff), INTEG/test/ui/**.
Ozellikle ara: tasma (yazi olcegi 1.5, kucuk ekran 320 dp, yatay), acik/koyu tema kontrasti, Semantics/liveRegion/dokunma hedefi, hareketi azalt, sonsuz animasyon, gereksiz yeniden cizim (Provider kapsami; kok MaterialApp yeniden kurulmasi), MaterialApp.builder icinde Navigator USTUNDE yasayan widget'in tuzaklari (Overlay/Navigator/ScaffoldMessenger/Localizations eksikligi; klavye; SafeArea/notch; Directionality), afisin sayfa icerigini/dokunmalarini engellemesi (IgnorePointer/hit-test), AppShell farkinin dogrulugu (builder zincirleme, Provider kapsami, dispose sirasi, initState'te context.read), Turkce metin dili (yazim, tutarlilik, durust ifade: nothing_to_do'da 'kapatildi' denmemeli), testlerin kalitesi (gercekten gorunurluk/etkilesim/semantik dogruluyor mu). Gerekirse kucuk widget testleri yazip calistirarak kanitla (yalniz WF altina yaz, INTEG'e DEGIL; ya da gecici kopya).
`

const R3 = COMMON + REVIEW_COMMON + `
GOREVIN: R3 - PLATFORM + DERLEME + GUVENLIK. Odak: HEAD kopyasindaki degisiklikler (pubspec.yaml, pubspec.lock, android/**, ios/**, lib/services/push/**, test/push/**), derleme kayitlari (${WF}/A3-apk.log), INTEG'deki pubspec farki ve tum yeni Dart kodunda gizlilik.
Ozellikle ara: Kotlin kanal kodunun dogrulugu (kanal kimligi sunucuyla birebir 'peace_reminder' mi: ${DOCS}/wp-h-contracts-satirlari.md ve server/src/services/push_service.js; API seviyesi korumasi; mukerrer olusturma; onCreate/configureFlutterEngine secimi), birlesik manifest (POST_NOTIFICATIONS, servisler, beklenmeyen izin/bilesen eklenmesi), pubspec.lock farkinin yalnizca yeni paketler olmasi ve gecişli bagimlilik listesi (yeni paket sayisi, boyut etkisi), firebase_core'un yapilandirma YOKKEN Android'de/iOS'ta acilista cokme/yan etki riski (eklenti kaynagini pub onbelleginde OKUYARAK: FirebaseInitProvider, otomatik baslatma; yapilandirma yoksa uygulama eskisi gibi acilmali), web/Windows/masaustu derlemesine etkisi (taban cizgisi web basariliydi; Windows zaten kirik), iOS Info.plist/AppDelegate degisikliginin derlenebilirligi (eklenti kaynagiyla dogrula), gizlilik/guvenlik: yeni Dart kodunda belirtec/ev kimligi/ozet metni log'a yaziliyor mu (debugPrint/print/log/toString), PushConfig dart-define degerlerinin sizmasi, FCM data'sinin guvenilmeyen girdi olarak ele alinmasi, belge tutarliligi (ENTEGRASYON.md / PUSH_KURULUM.md ile gercek kod ve derleme sonuclari uyumlu mu; yanlis/eski iddialari listele).
`

// ---------------------------------------------------------------------------------------------
phase('Uygula')
log('A1 (cekirdek) ve A3 (platform+derleme) paralel basliyor')
const p1 = agent(A1, { label: 'A1 cekirdek', phase: 'Uygula', schema: RESULT, effort: 'high' })
const p3 = agent(A3, { label: 'A3 platform+derleme', phase: 'Uygula', schema: RESULT, effort: 'medium' })

const a1 = await p1
if (!a1) {
  log('A1 basarisiz: arayuz asamasi atlandi')
}
phase('Arayuz')
const a2 = a1 ? await agent(A2(a1), { label: 'A2 arayuz', phase: 'Arayuz', schema: RESULT, effort: 'high' }) : null
const a3 = await p3

phase('Incele')
const reviews = await parallel([
  () => agent(R1, { label: 'R1 durum+denetleyici', phase: 'Incele', schema: FINDINGS, effort: 'high' }),
  () => agent(R2, { label: 'R2 arayuz+erisilebilirlik', phase: 'Incele', schema: FINDINGS, effort: 'high' }),
  () => agent(R3, { label: 'R3 platform+guvenlik', phase: 'Incele', schema: FINDINGS, effort: 'high' }),
])
const all = reviews.filter(Boolean)
const counts = { critical: 0, high: 0, medium: 0, low: 0 }
for (const r of all) for (const f of r.findings) counts[f.severity] += 1
log('Bulgular: ' + JSON.stringify(counts))
return { a1, a2, a3, reviews: all, counts }
