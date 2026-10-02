export const meta = {
  name: 'wp-h-flutter-son-entegrasyon',
  description: 'Flutter gece hatirlatmasi: orkestratorun KAPANIS sonrasi taze anlik kopyasina Firebase\'siz + Firebase\'li iki asamada 3 yonlu birlestir, TAM dogrula, bagimsiz incele, belgele, yama paketini uret ve belge-kod capraz denetimi yap',
  phases: [
    { title: 'Entegre', detail: 'RB: taze kopyaya birlestirme; TAM analyze/test (Firebase\'siz), sonra Firebase kumesi ayri kopyada' },
    { title: 'Incele', detail: 'RR3 entegre durum incelemesi + D1 belgeler paralel' },
    { title: 'Kapi', detail: 'G1: derlemeler (ardisik) + yama paketi + uygulama betigi' },
    { title: 'Denetim', detail: 'DR: belge iddialarini koda karsi dogrula' },
  ],
}

const SP = 'C:/Users/FINGON~1/AppData/Local/Temp/claude/g--site-site-kapi-kontrol/a379bdb3-93a0-4167-8a2c-eed43f0e926f/scratchpad'
const INTEG = SP + '/flutter_integ'
const INTEG_BASE = SP + '/flutter_integ_base'
const LIVE_BASE = SP + '/flutter_live_base2'
const LIVE = SP + '/flutter_live2'
const LIVE_FB = SP + '/flutter_live2_fb'
const WF = SP + '/wp-h-flutter-wf'
const DOCS = 'G:/site/ev_otomasyon/docs/superpowers/analysis'
const YAMA = DOCS + '/wp-h-flutter/yamalar'

const COMMON = `
BAGLAM
Ev Otomasyonu (Flutter 3.47 / Dart 3.13, provider, REST + MQTT) uygulamasina "acik kalan lambalar icin gece hatirlatmasi" (FCM push) istemci tarafi izole kopyalarda hazirlandi ve incelendi (WF1: A1/A2/A3 + R1-R3; WF2: F1/F2/F3 + RR1/RR2; WF3: FXC/FXU duzeltmeleri + SPL Firebase ayrimi). Raporlar: ${WF}/*.md. SUNUCU TARAFI BITTI ve canli agaca uygulandi. Baska bir (orkestrator) oturum GERCEK depoyu (G:/site/ev_otomasyon) yaziyor: oraya YAZMA (yalnizca okuma; istisna: yalniz bu gorevde acikca belirtilen dizinler). Commit yapma. Sir okuma/yazma/yazdirma.

KOPYALAR:
- INTEG = ${INTEG}: bizim FINAL calismamiz (ESKI 18:13 tabanli; derlenmez/yarim: yalniz hedefli analyze/test). INTEG_BASE = ${INTEG_BASE} (18:13 dokunulmamis).
- LIVE_BASE = ${LIVE_BASE}: orkestratorun KAPANIS entegrasyonu SONRASI gercek agacinin TAZE, dokunulmamis anlik kopyasi (tam yesil taban: ${WF}/baseline-live2.txt).
- LIVE = ${LIVE}: LIVE_BASE uzerine bizim FIREBASE'SIZ entegrasyonun uygulandigi kopya (RB olusturur). LIVE_FB = ${LIVE_FB}: LIVE + Firebase kumesi (02) (RB olusturur).
- WF = ${WF}.

ORKESTRATOR PROTOKOLU: lib/**, android/**, ios/**, pubspec.yaml onlarin; dogrulama KOPYADA yapilir; hazir olunca onlar 'simdi uygula' penceresi acar (15-30 dk). Bu yuzden yama paketi KUCUK, CAKISMA-DAYANIKLI ve sirali uygulanabilir olmali. KOSUL (orkestrator): Firebase paketleri henuz kullanici tarafindan ONAYLANMADI: WP-H'nin Firebase'siz kismi pubspec'te firebase_core/firebase_messaging OLMADAN derlenmeli ve TUM testleri gecmeli; Firebase'e bagli her sey AYRI yama (02-firebase). Kisitlar (orkestrator, kendi duzeltme ajanlarina da koydu): AuthStatus enum'una yeni deger/olay YOK (yeniden kilit = checking + _awaitingUnlock); app_shell.dart, automation_state.dart, ev_cloud_api_service.dart, api_models.dart degisiklikleri MINIMUM ve yerel; EvCloudApiService.closeAllOpenLights(String) imzasi DEGISMEZ.

KISITLAR: C: diskinde yer DAR (~11 GB bos), bellek ~1 GB bos: ayni anda TEK flutter komutu calistir; build'leri ARDISIK yap (run_in_background, cikti dosyaya); gecici kopyalari isin sonunda SIL (silme: PowerShell'de Remove-Item/rmdir/rd KULLANMA (guvenlik denetimi engelliyor); kopyalarda .plugin_symlinks gibi baglantilar olur ve pub onbellegine gider: once 'cmd /c dir /AL /S /B <dizin>' ile baglantilari listele, her birini [System.IO.Directory]::Delete(baglanti, \$false) ile TEK TEK kaldir, sonra [System.IO.Directory]::Delete('\\\\?\\' + tamYol, \$true) ile klasoru sil; yanlis silme paylasilan G:/flutter_pub_cache'i bozar). ASLA flutter run, adb, emulator, AVD, Gradle daemon baskasina ait: derlemeleri YALNIZ kopyada, flutter build ile yap; pio, docker yok; 54329/1883/18083/5000/8081-8083/18090 portlarina dokunma. Windows: yeni dosyalar LF; mevcut dosyada satir sonunu node ile say ve koru. Regex/ters egik cizgi/kesme isareti iceren betikleri Bash heredoc veya node -e ile DEGIL, Write araciyla dosyaya yazip calistir. Node'da yol 'C:/...' veya 'G:/...'. Turkce kullanici metinleri/yorumlar DOGRU Turkce karakterlerle (bu metin ASCII'ye sadelestirildi). dart format'i yalniz KENDI yeni/degistirdigin dosyalarina uygula. Durust ol: calistirmadigini 'gecti' deme. Sonucu semaya uygun dondur, ayrintili raporu WF dizinine yaz.
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

const DOCFINDINGS = {
  type: 'object',
  properties: {
    agent: { type: 'string' },
    summary: { type: 'string' },
    discrepancies: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          file: { type: 'string' },
          claim: { type: 'string' },
          reality: { type: 'string' },
          evidence: { type: 'string' },
          severity: { type: 'string', enum: ['high', 'medium', 'low'] },
          suggestedFix: { type: 'string' },
        },
        required: ['file', 'claim', 'reality', 'evidence', 'severity', 'suggestedFix'],
      },
    },
    verifiedClaims: { type: 'integer' },
    reportPath: { type: 'string' },
  },
  required: ['agent', 'summary', 'discrepancies', 'verifiedClaims', 'reportPath'],
}

// ---------------------------------------------------------------------------------------------
const RB = COMMON + `
GOREVIN: RB - TAZE CANLI KOPYAYA 3 YONLU BIRLESTIRME + TAM DOGRULAMA (iki asama). Yazma izni: LIVE, LIVE_FB ve WF. Once ${WF}/SPL-rapor.md ve SPL-dosya-ayrimi.txt'i OKU (hangi dosyalar Firebase'siz sette, hangileri 02-firebase kumesinde), ayrica FXC-rapor.md, FXU-rapor.md.
ASAMA 1 - FIREBASE'SIZ (LIVE):
1. LIVE = LIVE_BASE'in tam kopyasi (.dart_tool dahil).
2. Bizim FIREBASE'SIZ degisikliklerimizi INTEG'den LIVE'a aktar (INTEG ile INTEG_BASE arasindaki farki 'diff -rq -x .dart_tool -x build -x pubspec.lock' ile cikar; SPL-dosya-ayrimi.txt'teki 02 kumesi HARIC):
   a) YENI dosyalar (INTEG'de var, INTEG_BASE'de yok): LIVE'da AYNI yola kopyala (LF). Ayni yolda baska bir canli dosya varsa DUR ve raporla.
   b) MEVCUT dosyalar (INTEG_BASE'de de var, INTEG'de degismis): pubspec.yaml (YALNIZ fake_async dev bagimliligi; firebase satirlari DEGIL), lib/services/ev_cloud_api_service.dart, lib/models/api_models.dart, lib/services/automation_state.dart, lib/ui/app_shell.dart, android/** (MainActivity.kt, AndroidManifest.xml, res/drawable/ic_stat_peace.xml), ios/Runner/Info.plist (UIBackgroundModes) ve varsa digerleri: 3 YONLU birlestirme: 'git merge-file' (current = LIVE_BASE dosyasi, base = INTEG_BASE dosyasi, other = INTEG dosyasi); uc dosyayi once LF'e normalize et, birlestir, sonucu LIVE dosyasinin ORIJINAL satir sonuyla (CRLF/LF; node ile say) yaz. Catisma varsa elle coz (canli dosyanin yeni yapisina saygi: orkestrator ayni dosyalara dokundu: app_shell.dart, automation_state.dart; kilit/yeniden kilit akisi 'checking + _awaitingUnlock'). Birlestirme sonrasi 'diff LIVE_BASE/<dosya> LIVE/<dosya>' ile SADECE bizim hunk'larin eklendigini dogrula.
   c) .gitignore: ${WF}/F3-gitignore.patch'in satirlarini ekle (zaten varsa atla).
   d) Ayar karti: canli ayar sayfasindaki Huzur bildirimi kartini (peaceSettings kullanan kart; lib/ui altinda ara) bul; kart govdesine iki TEK SATIR ekle: const PeaceReminderDetails(); const PushStatusTile(); Bilesenler PeaceNoticeController saglayicisi YOKKEN (mevcut kart testleri) COKMEMELI (nullable arama; SizedBox.shrink); gerekirse duzelt + test.
   e) Derlenmeyen/kirilan canli test yardimcilari (ornegin test/ui/e1_helpers.dart) varsa MINIMUM uyarlama; E1/E2/F kodunda hata bulursan DEGISTIRME, raporla.
3. DOGRULAMA (LIVE'da TAM, Firebase'SIZ): flutter pub get; flutter analyze (TAM; taban 0 sorun -> 0); flutter test (TAM; taban ${WF}/baseline-live2.txt -> tabanda gecen HICBIR test kirilmamali; yeni testlerimiz gecmeli; sayilar). 'grep -rln "package:firebase" lib test' -> HIC sonuc OLMAMALI (Firebase'siz sette firebase importu yok). Kirilan/yuklenmeyen test varsa kok nedeni bul; bizim kodun hatasiysa duzelt ve ayni duzeltmeyi INTEG'e yansit (INTEG ve LIVE'daki bizim dosyalar BIREBIR ayni kalmali; fark varsa raporla).
ASAMA 2 - FIREBASE KUMESI (LIVE_FB):
4. LIVE_FB = ASAMA 1 sonrasi LIVE'in kopyasi. SPL-dosya-ayrimi.txt'teki 02 kumesini uygula: pubspec.yaml'a firebase_core ^4.15.0 + firebase_messaging ^16.7.0, lib/services/push/firebase_push_gateway.dart, push_gateway_factory.dart'in Firebase'li surumu (${WF}/SPL-factory-firebase.dart.txt), test/push/firebase_push_gateway_test.dart, ios/Runner/AppDelegate.swift + Runner-Bridging-Header.h (canli dosyalara 3 yonlu birlestirme; canli iOS dosyalari degismis olabilir). 'flutter pub get' (pubspec.lock YENI paketler disinda degismemeli: mevcut paket surumu degisimi/dusurme varsa raporla), flutter analyze (TAM 0 sorun), flutter test (TAM hepsi gecmeli).
5. Rapor ${WF}/RB-rapor.md ve birlestirme notlari ${WF}/RB-merge-notlari.md (hangi dosyada hangi catisma nasil cozuldu; LIVE_BASE'e gore tum farklar; iki asamanin analyze/test sayilari). Isin sonunda gereksiz gecici dosyalari (build/ klasorleri) temizle; LIVE ve LIVE_FB KALSIN (sonraki asamalar kullanir).
`

const RR3 = COMMON + `
SEN BAGIMSIZ BIR ELESTIRMENSIN (adversarial): entegre durumu CURUTMEYE calis. Dosya DEGISTIRME (yalniz ${WF}/RR3-rapor.md ve WF altindaki gecici kopyalar; gecici kopyalari isin sonunda guvenli yontemle sil). Yalnizca KOD ALINTILI KANITLA bulgu bildir; tahmin/stil yazma; kritik/yuksek bulgulari calistirarak kanitla. Farklar: diff -ru -x .dart_tool -x build ${LIVE_BASE} ${LIVE} (Firebase'siz entegrasyon) ve diff -ru -x .dart_tool -x build ${LIVE} ${LIVE_FB} (Firebase kumesi). RB raporu: ${WF}/RB-rapor.md, RB-merge-notlari.md; onceki raporlar FXC, FXU, SPL, RR1, RR2.
Odak: (a) entegrasyon noktalari: app_shell hunk'i (canli dosyaya dogru birlesti mi: Provider kapsami, dispose sirasi, builder zinciri, orkestratorun yeni yeniden-kilit/rota kapatma kodu ile etkilesim), ayar karti 2 satir (saglayici yokken cokmeme), automation_state kancasi (logout() zamanlamasi; E2'nin hesap silme / oturum kapatma / servis oturumu girisi akislari push belirtecini nasil etkiliyor), AuthStatus.checking + _awaitingUnlock yeniden kilidinin denetleyicide GERCEK gecislerle (handleLifecycleState, biyometrik) belirteci SILMEDIGI; (b) Firebase'siz set gercekten Firebase'siz mi (import taramasi), Firebase kumesi (02) temiz ve ayri mi; (c) onceki bulgularin kapanisi (RR1-01/02/04/08, RR2-01..05, B1-B8, R3-01) previousFindingsStatus'ta tek tek; yeni regresyon; (d) TAM test paketini KENDIN calistir (LIVE'in gecici kopyasinda) ve tabanla (${WF}/baseline-live2.txt) karsilastir; (e) E1/E2 yuzeyleriyle etkilesim: panodaki 'Huzur Modu' bandi (lib/ui/dashboard/peace_banner.dart) + CloseAllLightsButton + yeni afis; AppShell testleri; (f) gizlilik/guvenlik: log, belirtec/ev adi/ozet sizmasi; FCM data guvenilmeyen girdi; (g) yama paketi riskleri: hareketli dosyalar, satir sonlari (CRLF/LF), birlestirme riski.
`

const D1 = COMMON + `
GOREVIN: D1 - BELGELER (duz yazi; .txt disa aktarimi G1 yapar). Yazma izni YALNIZ ${DOCS}/wp-h-flutter/ altinda .md dosyalari (_wf ve yamalar dizinlerine DOKUNMA). Once ${WF}/RB-rapor.md, SPL-rapor.md, FXC-rapor.md, FXU-rapor.md, F2/F3, A1-A3, R1-R3, RR1, RR2 raporlarini ve LIVE/LIVE_FB'deki GERCEK kodu OKU; belgeyi GERCEK koda gore yaz (uydurma/varsayim YOK; her somut iddia kodda dogrulanabilir olmali).
1. ENTEGRASYON.md'yi son mimariye gore BASTAN YAZ (kisa, uygulayiciya yonelik, sirali): iki kume: (A) FIREBASE'SIZ (hemen uygulanabilir): kabuk tabanli baglanti (PeaceNoticeController + PeaceNoticeHost koprusu + AppShell hunk'i; afis=MaterialBanner, sonuc=SnackBar), AutomationState'e yalniz cikis kancasi (addBeforeLogoutHook; logout() icinde; 1 sn tavan; arka planda tamamlanir), token alicisi arayuz + UnsupportedPushGateway 'yapilandirilmadi' no-op, CloseAllResult/PeaceNotificationSettings v2, includeShutters kurali (eski pano dugmesi closeAllOpenLights(String): include_shutters:false; afis closeAllForNotice: panjur varsa true), ayar kartina 2 satir, Android (kanal 'peace_reminder' + kucuk simge + manifest meta-data), iOS Info.plist UIBackgroundModes, .gitignore; (B) FIREBASE KUMESI (kullanici onayiyla): pubspec firebase satirlari, firebase_push_gateway.dart, fabrika degisikligi, iOS AppDelegate/bridging header, Xcode 'Push Notifications' yetenegi (elle), --dart-define degerleri; yama uygulama SIRASI/komutlari (G1'in yamalar/README.md ve uygula betigi ile tutarli; satir sonu notu: git apply --ignore-whitespace ve elle birlestirme), dogrulama (otomatik komutlar ve SAYILAR: RB raporundan; elle gercek cihaz listesi), BILINEN SINIRLAR (durust): cevrimdisi cikista deleteToken basarisiz olabilir ve kalici yeniden deneme yok (RR1-05); bayat ev listesinde yeni evin bildirimi kaybolabilir (RR1-03); logoutAll sonrasi sunucu DELETE belirtecsiz (401) - sunucu onerisi: logout-all'da push.disableAllTokensForUser; eklenti bildirim icerigini SharedPreferences'ta saklar (R3-07); Windows derlemesinde firebase_core C++ SDK indirmesi (R3-05) ve tabanda Windows zaten kirik olabilir (taban kaydina bak); LAN modunda push (B6); kapatilan afisin geri gelmesi (B7); banner icerik yazi olcegi 1.5 siniri (RR2-06); panodaki eski 'Huzur Modu' bandi ile ikili yuzey (RR2-08); iOS derlenmedi; gercek FCM/APNs/cihaz denenmedi.
2. PUSH_KURULUM.md: R3-08/R3-03 duzeltmeleri (WF/R3-rapor.md); FCM API anahtari KISITLAMA adimi (Google Cloud Console > API'ler ve Hizmetler > Kimlik bilgileri: Android uygulamasi kisiti paket adi + SHA-1, API kisiti: Firebase Cloud Messaging API / FCM Registration API; dart-define ile APK'ya gomulen anahtar sir degildir ama kisitlanmalidir); Windows notu; kucuk simge; bolum numaralari tutarli; FCM_SERVICE_ACCOUNT_JSON secenegi YOK (yalniz dosya yolu): koru; kullanicinin yapacagi adimlar (Firebase projesi/servis hesabi) basta, sade Turkce.
3. README.md: guncel durum, dogrulama sonuclari, yama dosyasi listesi ve sirasi (G1 yazinca tutarlilik icin 'yamalar/README.md bkz.').
Rapor: ${WF}/D1-rapor.md.
`

const G1 = COMMON + `
GOREVIN: G1 - KAPI: ardisik derlemeler + yama paketi + uygulama betigi. Yazma izni: LIVE, LIVE_FB, WF ve ${YAMA} (YENI dizin; olustur) ve ${DOCS}/wp-h-flutter/ altinda .txt disa aktarimlari. RR3 ve D1 bitti (raporlar ${WF}/RR3-rapor.md, D1-rapor.md; RR3 bulgusu varsa ONCE kucuk/kanitli duzeltmeleri LIVE ve INTEG'e uygula (kritik/yuksek ve acik/kolay orta bulgular; belirsizse DOKUNMA, raporla)).
1. Dogrulama (ARDISIK, her biri bitince bir sonrakine): LIVE'da flutter analyze (0) + flutter test (TAM; taban ${WF}/baseline-live2.txt) -> LIVE_FB'de flutter analyze (0) + flutter test (TAM). Sayilari kaydet.
2. Derlemeler (ARDISIK; her biri icin YENI bir gecici kaynak kopyasi, bitince SIL; ~3.5 GB/kopya; diskte yer dar): (i) LIVE (Firebase'siz) 'flutter build apk --debug' ~7 dk (run_in_background; Kotlin artimli onbellek / farkli surucu sorunu: ${WF}/A3-rapor.md'deki yontem: kaynak kopyayi C: altinda, PUB_CACHE=C: altindaki ${SP}/pubcache_c ile derle); (ii) LIVE_FB (Firebase'li) 'flutter build apk --debug'; birlesik manifestte POST_NOTIFICATIONS, default_notification_icon meta-data ve (yalniz FB'de) FirebaseMessaging bilesenlerini goster; (iii) LIVE_FB 'flutter build web' (~2 dk). Windows derlemesini DENEME (taban kaydina bak). Bellek yetmezse zaman asimi olabilir: yeniden dene ve raporla. Her derleme bitince kopyayi guvenli yontemle sil.
3. Yama paketi (${YAMA}/; hepsi LF-normalize 'git diff --no-index' ciktisi, a/ b/ onekleri repo kokune GORELI (git diff --no-index iki dizin adini onek yapar: basliklari duzelt; ornek betik ${SP}/make_patch.js), pubspec.lock HARIC), LIVE_BASE -> LIVE (Firebase'siz) ve LIVE -> LIVE_FB (Firebase):
   - 01-yeni-dosyalar.patch: Firebase'siz YENI dosyalar (lib/services/push/** (firebase_push_gateway.dart HARIC), peace_notice_controller.dart, push_token_api_adapter.dart, lib/ui/widgets/ yeni dosyalar, yeni testler)
   - 03-mevcut-dosyalar.patch: ev_cloud_api_service.dart + api_models.dart + automation_state.dart (kanca) + pubspec.yaml (yalniz fake_async) + degisen mevcut dosyalar (ayar karti 2 satir dahil) + varsa degisen MEVCUT testler
   - 04-app-shell.patch: lib/ui/app_shell.dart baglantisi
   - 05-platform.patch: android + ios Info.plist (Firebase'siz)
   - 06-gitignore.patch
   - 02-firebase.patch: pubspec.yaml firebase satirlari + firebase_push_gateway.dart + fabrika degisikligi + firebase testi + iOS AppDelegate/bridging header (ayri onaya bagli)
   - README.md: UYGULAMA SIRASI (01, 03, 04, 05, 06; sonra onayla 02 + 'flutter pub get'), her yama icin hangi ekibin dosyasina dokundugu, satir sonu uyarisi (CRLF/LF: git apply --ignore-whitespace), cakisma durumunda 3 yonlu birlestirme notlari, geri alma (git apply -R ters sira).
   - uygula.sh: yamalari sirayla 'git apply --check' ile deneyip uygulayan, hata olursa durup ne yapacagini yazan, sonunda hedefli analyze/test komutlarini yazdiran (otomatik KOMUT CALISTIRMAYAN yalniz basan) betik; Windows Git Bash'te calismali. Betigi GERCEK AGACA CALISTIRMA; yalniz bir temiz kopyada dene.
   KANIT: yamalari LIVE_BASE'in GECICI temiz kopyasina sirayla (01,03,04,05,06) uygulayip sonucun LIVE ile BIREBIR ayni oldugunu, sonra 02'yi uygulayip LIVE_FB ile BIREBIR ayni oldugunu (diff -r; .dart_tool/build/pubspec.lock haric) goster. Her yamayi GERCEK agaca (G:/site/ev_otomasyon) 'git apply --check' ile ayrica dene (agac hareketli; sonuc anlik; basarisiz hunk'lari dürüstce yaz).
4. Disa aktarim: LIVE_FB'deki YENI dosyalari .txt olarak ${DOCS}/wp-h-flutter/ altina aktar (lib/services/push/*, lib/services/peace_notice_controller.dart, push_token_api_adapter.dart, lib/ui/widgets/ yeni dosyalar, yeni testler; ayni yol agaci); eski .txt'leri guncelle/sil (yalniz .txt); BIREBIR ayni oldugunu diff ile kanitla.
5. Rapor ${WF}/G1-rapor.md: tum komutlar/sonuclar/sayilar/sureler, derleme boyutlari, acik riskler.
`

const DR = COMMON + `
GOREVIN: DR - BELGE-KOD CAPRAZ DENETIMI (SALT OKUNUR; yalniz ${WF}/DR-rapor.md yaz). Dokumantasyon ajanlari uyduruyor/madde kaybediyor/eski iddialari koruyor: ${DOCS}/wp-h-flutter/ENTEGRASYON.md, PUSH_KURULUM.md, README.md ve ${YAMA}/README.md + uygula.sh icindeki HER somut iddiayi (dosya/sinif/yontem adi, sabit, sure, metin, komut, sayi, sira, kosul) LIVE/LIVE_FB'deki gercek koda / G1 derleme kayitlarina (${WF}/G1-rapor.md) / sunucu koduna (G:/site/ev_otomasyon/server/src/services/push_service.js, peace_service.js, peace_reminder.js) / pub onbellegindeki eklenti kaynagina karsi dogrula. Dogrulanamayan, yanlis, eski (WF1 oncesi mimariye ait: AutomationState'e dogrudan baglama, Stack/Positioned overlay kart, FCM_SERVICE_ACCOUNT_JSON, eski test sayilari, 02 yamasi disindaki Firebase iddialari vb.), kendi icinde celisen veya yama paketiyle uyusmayan her iddiayi listele (belge, iddia, gercek, kanit, siddet, onerilen duzeltme). Ayrica yamalar/README.md ve uygula.sh'taki komutlari bir temiz kopyada KURU calistir (git apply --check vb.). verifiedClaims = dogruladigin iddia sayisi.
`

// ---------------------------------------------------------------------------------------------
phase('Entegre')
const rb = await agent(RB, { label: 'RB taze kopyaya birlestirme + TAM dogrulama', phase: 'Entegre', schema: RESULT, effort: 'high' })
if (!rb) {
  log('RB basarisiz: devam edilmiyor')
  return { rb }
}

phase('Incele')
const p3 = agent(RR3, { label: 'RR3 entegre durum incelemesi', phase: 'Incele', schema: FINDINGS, effort: 'high' })
const pd = agent(D1, { label: 'D1 belgeler', phase: 'Incele', schema: RESULT, effort: 'medium' })
const rr3 = await p3
const d1 = await pd
const counts = { critical: 0, high: 0, medium: 0, low: 0 }
if (rr3) for (const f of rr3.findings) counts[f.severity] += 1
log('RR3 bulgulari: ' + JSON.stringify(counts))

phase('Kapi')
const g1 = await agent(G1, { label: 'G1 derleme + yama paketi', phase: 'Kapi', schema: RESULT, effort: 'medium' })

phase('Denetim')
const dr = g1 ? await agent(DR, { label: 'DR belge-kod denetimi', phase: 'Denetim', schema: DOCFINDINGS, effort: 'high' }) : null
return { rb, rr3, d1, g1, dr, counts }
