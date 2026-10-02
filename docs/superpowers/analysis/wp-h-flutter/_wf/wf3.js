export const meta = {
  name: 'wp-h-flutter-kapi',
  description: 'Flutter gece hatirlatmasi: (gerekirse) delta duzeltmeleri, son dogrulama kapisi + yama paketi, belgeler, belge-kod capraz denetimi',
  phases: [
    { title: 'Duzelt', detail: 'FX: dogrulanmis delta bulgulari (args.fixes bossa atlanir)' },
    { title: 'Kapi', detail: 'G1: analyze/test/APK/web + yama paketi + gercek agaca git apply --check' },
    { title: 'Belge', detail: 'D1: ENTEGRASYON/PUSH_KURULUM/README yeniden yaz + .txt disa aktar' },
    { title: 'Denetim', detail: 'DR: belge iddialarini koda karsi dogrula' },
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
const YAMA = DOCS + '/wp-h-flutter/yamalar'

const COMMON = `
BAGLAM
Ev Otomasyonu (Flutter 3.47 / Dart 3.13, provider, REST + MQTT) uygulamasina "acik kalan lambalar icin gece hatirlatmasi" (FCM push) istemci tarafi izole kopyalarda hazirlandi: WF1 (cekirdek A1, arayuz A2, platform+derleme A3, 3 elestirmen) ve WF2 (duzeltmeler F1 cekirdek, F2 arayuz MaterialBanner, F3 platform; 2 delta elestirmeni RR1/RR2). Raporlar: ${WF}/*.md (A1,A2,A3,R1,R2,R3,F1,F2,F3,RR1,RR2). Baska bir (orkestrator) oturum GERCEK depoyu (G:/site/ev_otomasyon) su anda es zamanli yeniden yaziyor: oraya YAZMA (yalnizca okuma; istisna: yalniz bu gorevde acikca belirtilen ${DOCS}/wp-h-flutter/ belge dizini). Commit yapma. Sir okuma/yazma/yazdirma.

KOPYALAR: INTEG = ${INTEG} (gercek agacin 18:13 anlik kopyasi + bizim degisiklikler; BUTUN OLARAK DERLENMEZ: Dalga 2 yarim; yalnizca hedefli analyze/test; taban cizgisi ${WF}/baseline-integ-*.txt). INTEG_BASE = ${INTEG_BASE} (dokunulmamis 18:13 kaynak). INTEG_WF1 = ${INTEG_WF1} (WF1 sonu). HEAD = ${HEAD} (deponun son commit'i, derlenebilir; APK/web dogrulamasi burada) ve HEAD_BASE = ${HEAD_BASE}. WF = ${WF}.
GENEL KURALLAR: Windows: yeni dosyalari LF yaz; mevcut dosyada satir sonunu node ile say ve koru. Regex/ters egik cizgi/kesme isareti iceren betikleri Bash heredoc veya node -e ile DEGIL, Write araciyla dosyaya yazip calistir. Node'da yol 'C:/...' veya 'G:/...'. Flutter komutlari uzun surebilir: build'leri run_in_background ile calistir, ciktiyi dosyaya al; ayni dizinde es zamanli iki flutter komutu calistirma. ASLA 'flutter run', adb, emulator, pio, docker; 54329/1883/18083/5000/8081-8083 portlarina dokunma. Durust ol: calistirmadigini 'gecti' deme. Turkce kullanici metinleri DOGRU Turkce karakterlerle (bu metin ASCII'ye sadelestirildi). Sonucu semaya uygun dondur ve ayrintili raporu WF dizinine yaz.
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

const FX = (fixes) => COMMON + `
GOREVIN: FX - DELTA BULGULARI DUZELTMESI (INTEG; gerekiyorsa F3 ile ilgili android/ios). Yollar: INTEG/lib/**, INTEG/test/**, INTEG/android/**, INTEG/ios/** (yalniz asagidaki bulgulari duzeltmek icin; baska hicbir seye dokunma; mevcut dosyalara EKLEME minimum).
Dogrulanmis bulgular (ben kodda dogruladim; ayrintisi ${WF}/RR1-rapor.md ve RR2-rapor.md):
${fixes}
Her duzeltme icin ONCE basarisiz test (kirmizi, calistirip gor), SONRA duzelt, sonra gecici mutasyonla testin yakaladigini kanitla. Hedefli: flutter analyze lib/services lib/models lib/ui/widgets lib/ui/app_shell.dart test/services test/push test/ui test/support (0 sorun); flutter test test/services test/push test/ui (hepsi gecmeli). Rapor: ${WF}/FX-rapor.md (hangi bulgu nasil kapandi, calistirdigin komutlar).
`

const G1 = COMMON + `
GOREVIN: G1 - KAPI: son dogrulama + yama paketi. Esas olarak dogrulama ve paketleme; kodu YALNIZCA kucuk, kanitlanmis duzeltmeler icin degistir (her degisikligi raporla). Yazma izni: INTEG, HEAD, WF ve ${YAMA} (YENI dizin; olustur).
1. INTEG: 'flutter analyze lib/services lib/models lib/ui/widgets lib/ui/app_shell.dart test/services test/push test/ui test/support' -> 0 sorun; 'flutter test test/services test/push test/ui' -> hepsi gecmeli (sayilari kaydet). Taban cizgisi karsilastirmasi: ${WF}/baseline-integ-failures.txt'deki kirik dosyalar disinda, bizim dokundugumuz alanin KAPSADIGI mevcut testlerden (test/services/** ve varsa test/ui/**) tabanda gecip simdi kirilan YOK; 'flutter test test/services' sonucunu tabanda (INTEG_BASE'e esdeger: bizim eklemelerimiz olmadan) gecen test sayisiyla kiyasla (INTEG_BASE'de .dart_tool yok: gerekirse gecici kopya olustur; ya da yalniz bizim yeni test dosyalari disindaki mevcut testlerin gectigini kanitla).
2. HEAD kopyasi: INTEG'deki lib/services/push/** ve test/push/** (WF2 sonrasi) dosyalarini ${HEAD}'e BIREBIR senkronla (HEAD'de lib/services/push_token_api_adapter.dart ve peace_notice_controller.dart GEREKTIRDIKLERI dosyalar olmadigindan EKLENMEZ), 'flutter pub get', 'flutter analyze' (0 sorun), 'flutter test' (hepsi gecmeli; taban 100 + push testleri), 'flutter build web' (basarili; run_in_background ~2 dk). Android: F3'un platform degisikliklerini (kanal kodu, ic_stat_peace.xml, manifest meta-data) HEAD'e UYARLA (HEAD'in MainActivity'si FlutterActivity olabilir; F3 raporuna ve flutter_head farklarina bak) ve 'flutter build apk --debug' (A3'un calisan yontemi: HEAD'in KAYNAK kopyasini ayri dizinde derle - ${WF}/A3-rapor.md: Kotlin artimli onbellek / farkli surucu sorunu; ~7 dk; run_in_background). Birlesik manifestte POST_NOTIFICATIONS ve default_notification_icon meta-data'sinin bulundugunu goster; APK'nin derlendigini (boyut) raporla. Windows derlemesi taban cizgisinde kirik: DENEME.
3. Yama paketi (${YAMA}/): hepsi LF-normalize 'git diff --no-index' ciktisi, a/ b/ onekleri repo kokune GORELI (git diff --no-index iki dizin adini onek yapar: basliklari duzelt; ornek betik: ${SP}/make_patch.js), pubspec.lock HARIC:
   - 01-yeni-dosyalar.patch: INTEG'deki YENI dosyalar (lib/services/push/**, lib/services/peace_notice_controller.dart, lib/services/push_token_api_adapter.dart, lib/ui/widgets/ icindeki yeni dosyalar, tum yeni testler: test/push, test/services, test/ui yenileri)
   - 02-pubspec.patch: yalniz pubspec.yaml (firebase_core, firebase_messaging, dev fake_async) - AYRI ve ayri onaya bagli
   - 03-mevcut-dosyalar.patch: ev_cloud_api_service.dart + api_models.dart + automation_state.dart (kanca) + degisen MEVCUT testler (varsa)
   - 04-app-shell.patch: lib/ui/app_shell.dart baglantisi
   - 05-platform.patch: android + ios (F3'un uretimini INTEG'e karsi YENIDEN uret ve dogrula)
   - 06-gitignore.patch: F3'un yamasi (gercek agaca karsi dogrula)
   - README.md: UYGULAMA SIRASI ve komutlar (git apply --check ve git apply; CRLF/LF uyarisi: 'patch --binary' notu; pubspec.lock YAMALANMAZ: 02 sonrasi 'flutter pub get'; hunk'lar cakisirsa elle birlestirme notlari; hangi yama hangi paketin/ekibin dosyasina dokunuyor: pubspec -> D, app_shell/android/ios -> E1/E2, automation_state/models/services -> D).
   Her yamayi GERCEK agaca (G:/site/ev_otomasyon) 'git apply --check' ile dene (agac hareketli ve su an derlenmiyor; yalniz UYGULANABILIRLIK; basarisiz hunk'lari ve nedenlerini dürüstce yaz). Ayrica: yamalari INTEG_BASE'in GECICI bir kopyasina sirayla 'patch -p1 --binary' ile uygula (01,02,03,04,05) ve sonucun INTEG ile BIREBIR ayni oldugunu (diff -r; .dart_tool/build/pubspec.lock haric) kanitla: paket eksiksiz ve sirali uygulanabilir olmali. Eksik/fazla dosya varsa duzelt.
4. Rapor ${WF}/G1-rapor.md: tum komutlar/sonuclar/sayilar, APK/web sonucu, acik kalan riskler.
`

const D1 = COMMON + `
GOREVIN: D1 - BELGELER VE DISA AKTARIM. Yazma izni YALNIZ ${DOCS}/wp-h-flutter/ altinda (.md ve .txt; _wf ve yamalar dizinlerine DOKUNMA). Once ${WF}/G1-rapor.md ve tum WF raporlarini, INTEG'deki GERCEK kodu ve ${YAMA}/README.md'yi OKU; belgeyi GERCEK koda gore yaz (uydurma/varsayim YOK; her somut iddia kodda dogrulanabilir olmali).
1. ENTEGRASYON.md'yi son mimariye gore BASTAN YAZ (kisa, uygulayiciya yonelik, sirali adimlar): kabuk tabanli baglanti (PeaceNoticeController + PeaceNoticeHost koprusu + AppShell hunk'i; afis=MaterialBanner, sonuc=SnackBar), AutomationState'e yalniz cikis kancasi (addBeforeLogoutHook; logout() icinde, 1 sn tavan, arka planda tamamlanir), pubspec hunk'i AYRI ve kullanici onayina bagli, CloseAllResult/PeaceNotificationSettings v2, includeShutters kurali (eski pano dugmesi lamba-only: include_shutters:false; afis panjur dahil: true), ayar kartina 2 satir (PeaceReminderDetails, PushStatusTile; PeaceNoticeController saglayicisi gerekir: testlerde sahte saglayici), Android (kanal 'peace_reminder' + kucuk simge + manifest meta-data), iOS (Info.plist, AppDelegate, bridging header; Xcode capability elle), .gitignore, yama uygulama SIRASI ve komutlari (yamalar/README.md ile tutarli), dogrulama listesi (otomatik komutlar ve sayilar; elle gercek cihaz listesi), BILINEN SINIRLAR (durust): cevrimdisi cikista deleteToken basarisiz olabilir; eklenti bildirim icerigini SharedPreferences'ta saklar (R3-07); Windows derlemesinde firebase_core C++ SDK indirmesi (R3-05) ve tabanda Windows zaten kirik; LAN modunda push (B6); kapatilan afisin geri gelmesi (B7); iOS derlenmedi; gercek FCM/APNs denenmedi; sunucu onerisi: logout-all'da push.disableAllTokensForUser (A sahibine istek).
2. PUSH_KURULUM.md: R3-08/R3-03 duzeltmeleri (WF/R3-rapor.md); FCM API anahtari KISITLAMA adimi (Google Cloud Console > API'ler ve Hizmetler > Kimlik bilgileri: Android uygulamasi kisiti paket adi + SHA-1, API kisiti: Firebase Cloud Messaging API / FCM Registration API; dart-define ile APK'ya gomulen anahtar sir degildir ama kisitlanmalidir); Windows notu; kucuk simge; bolum numaralari tutarli; FCM_SERVICE_ACCOUNT_JSON secenegi YOK (yalniz dosya yolu) - zaten duzeltildi, koru.
3. README.md: guncel durum, dogrulama sonuclari (analyze/test sayilari; APK/web), yama dosyasi listesi ve sirasi.
4. Disa aktarim: INTEG'deki YENI dosyalari .txt olarak ${DOCS}/wp-h-flutter/ altina aktar (ayni yol agaci): lib/services/push/*, lib/services/peace_notice_controller.dart, lib/services/push_token_api_adapter.dart, lib/ui/widgets/ yeni dosyalari, ilgili testler (test/push/*, test/services/ yeni testler, test/ui/*). Eski .txt'leri guncelle; artik var olmayan eski dosyalari sil (yalniz .txt/.md). Disa aktarilanlarin INTEG'dekiyle BIREBIR ayni oldugunu (diff) kanitla.
Rapor: ${WF}/D1-rapor.md.
`

const DR = COMMON + `
GOREVIN: DR - BELGE-KOD CAPRAZ DENETIMI (SALT OKUNUR; yalniz ${WF}/DR-rapor.md yaz). Dokumantasyon ajanlari uyduruyor/madde kaybediyor/eski iddialari koruyor: ${DOCS}/wp-h-flutter/ENTEGRASYON.md, PUSH_KURULUM.md, README.md ve ${YAMA}/README.md icindeki HER somut iddiayi (dosya/sinif/yontem adi, sabit, sure, metin, komut, sayi, sira, kosul) INTEG'deki gercek koda / HEAD derleme kayitlarina (${WF}/G1-rapor.md, A3-rapor.md, A3-apk.log) / sunucu koduna (G:/site/ev_otomasyon/server/src/services/push_service.js, peace_service.js, peace_reminder.js) / pub onbellegindeki eklenti kaynagina karsi dogrula. Dogrulanamayan, yanlis, eski (WF1 oncesi mimariye ait: AutomationState'e dogrudan baglama, Stack/Positioned overlay kart, FCM_SERVICE_ACCOUNT_JSON, 209 test sayisi vb.), kendi icinde celisen veya yama paketiyle uyusmayan her iddiayi listele (belge, iddia, gercek, kanit, siddet, onerilen duzeltme). Ayrica yamalar/README.md'deki komutlari KURU calistir (git apply --check vb.; degistirmeden). verifiedClaims = dogruladigin iddia sayisi.
`

// ---------------------------------------------------------------------------------------------
const fixes = typeof args === 'string' ? args : (args && args.fixes ? args.fixes : '')
let fx = null
if (fixes && fixes.trim() !== '') {
  phase('Duzelt')
  log('FX basliyor')
  fx = await agent(FX(fixes), { label: 'FX delta duzeltme', phase: 'Duzelt', schema: RESULT, effort: 'high' })
} else {
  log('FX atlandi (duzeltilecek delta bulgusu yok)')
}

phase('Kapi')
const g1 = await agent(G1, { label: 'G1 kapi + yama paketi', phase: 'Kapi', schema: RESULT, effort: 'medium' })

phase('Belge')
const d1 = await agent(D1, { label: 'D1 belgeler', phase: 'Belge', schema: RESULT, effort: 'medium' })

phase('Denetim')
const dr = await agent(DR, { label: 'DR belge-kod denetimi', phase: 'Denetim', schema: DOCFINDINGS, effort: 'high' })
return { fx, g1, d1, dr }
