export const meta = {
  name: 'wp-h-flutter-firebase-ayrimi',
  description: 'Flutter gece hatirlatmasi: Firebase paketlerine bagli kodu ayri dosyalara/yamaya ayir; Firebase paketleri OLMADAN derlenip tum testlerin gectigini kanitla',
  phases: [{ title: 'Ayir', detail: 'SPL: firebase importlarini firebase_push_gateway.dart + fabrika + 02 yama kumesine tasi, nofb kopyada kanitla' }],
}

const SP = 'C:/Users/FINGON~1/AppData/Local/Temp/claude/g--site-site-kapi-kontrol/a379bdb3-93a0-4167-8a2c-eed43f0e926f/scratchpad'
const INTEG = SP + '/flutter_integ'
const WF = SP + '/wp-h-flutter-wf'
const NOFB = SP + '/flutter_integ_nofb'

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

const SPL = `
BAGLAM
Ev Otomasyonu (Flutter 3.47 / Dart 3.13) uygulamasina "acik kalan lambalar icin gece hatirlatmasi" (FCM push) istemci tarafi izole bir kopyada hazirlaniyor: INTEG = ${INTEG} (gercek agacin ESKI 18:13 anlik kopyasi + bizim calismamiz; BUTUN OLARAK DERLENMEZ: yalnizca HEDEFLI analyze/test). Gercek depoya (G:/site/ev_otomasyon) YAZMA (yalniz okuma). Commit yapma. Sir okuma/yazma/yazdirma. Onceki rapor/defterler: ${WF} (FXC-rapor.md, FXU-rapor.md, F2-rapor.md, F3-rapor.md vb.).

NEDEN BU GOREV: orkestrator oturum, kullanici firebase paketlerini henuz ONAYLAMADIGI icin su kosulu koydu: WP-H'nin Firebase'siz kismi pubspec'te firebase paketleri OLMADAN derlenmeli ve TUM testleri gecmeli (token alicisi arayuz + 'yapilandirilmadi' no-op; Firebase yoksa ozellik sessizce kapali). Firebase'e bagli her sey AYRI bir yamada (02-firebase) olacak ve onay gelince eklenecek.

KISITLAR (onemli): C: diskinde yer DAR (~11 GB bos) ve bellek ~1 GB bos: ayni anda TEK flutter komutu calistir; gecici kopyalari isin sonunda SIL. Silme: PowerShell'de Remove-Item/rmdir/rd KULLANMA (guvenlik denetimi engelliyor); kopyada .plugin_symlinks gibi baglantilar olabilir (pub onbellegine gider; yanlis silme paylasilan onbellegi bozar): once 'cmd /c dir /AL /S /B <dizin>' ile baglantilari listele, her birini [System.IO.Directory]::Delete(baglanti, \$false) ile TEK TEK kaldir, sonra [System.IO.Directory]::Delete('\\\\?\\' + tamYol, \$true) ile klasoru sil. ASLA flutter run, adb, emulator, pio, docker; 54329/1883/18083/5000/8081-8083/18090 portlarina dokunma. Windows: yeni dosyalar LF; mevcut dosyada satir sonunu node ile say ve koru. Regex/ters egik cizgi/kesme isareti iceren betikleri Bash heredoc veya node -e ile DEGIL, Write araciyla dosyaya yazip calistir. Node'da yol 'C:/...'. Turkce metin/yorumlar dogru Turkce karakterlerle. dart format'i yalniz kendi yeni/degistirdigin dosyalarina uygula. Durust ol: calistirmadigini 'gecti' deme.

GOREVIN: SPL - FIREBASE'SIZ / FIREBASE'LI AYRIM (INTEG). Sahip oldugun yollar: INTEG/lib/services/**, INTEG/test/push/**, INTEG/test/services/** (gerekirse), WF dosyalari; ${NOFB} (gecici).
Su an firebase_core/firebase_messaging import eden dosyalar: lib/services/push/push_config.dart (FirebaseOptions donusumu), lib/services/push/push_gateway.dart (FirebasePushGateway + RemoteMessage donusumleri), ve testler (test/push/push_gateway_test.dart, push_config_test.dart); lib/services/peace_notice_controller.dart (~174. satir) FirebasePushGateway'i dogrudan kullaniyor. (grep -rn "firebase" INTEG/lib INTEG/test ile kendin dogrula; baska yer varsa onu da ele al.)
Yap:
1. push_config.dart'tan firebase importunu ve FirebaseOptions donusumunu CIKAR: PushConfig saf veri (alanlar + fromEnvironment + esitlik/dogrulama) olarak kalir (firebase importu YOK). FirebaseOptions donusumu yeni firebase_push_gateway.dart icine tasinir (extension veya yardimci).
2. push_gateway.dart'tan FirebasePushGateway'i (ve firebase'e bagli her seyi: RemoteMessage->PushMessage donusumleri, deleteToken zaman asimi sabiti vb.) yeni lib/services/push/firebase_push_gateway.dart dosyasina TASI (davranis BIREBIR ayni; yalniz konum). push_gateway.dart: PushPermission, PushMessage, PushGateway arayuzu, UnsupportedPushGateway (firebase importu YOK). 'Firebase'e hic dokunmaz' garantisi korunur.
3. Yeni lib/services/push/push_gateway_factory.dart (Firebase'SIZ surum): PushGateway createPushGateway(PushConfig? config) => const UnsupportedPushGateway(); yorumda: 'Firebase paketleri eklendiginde (02-firebase yamasi) bu dosya FirebasePushGateway dondurecek sekilde degisir'. peace_notice_controller.dart'taki dogrudan FirebasePushGateway kullanimini bu fabrikaya cevir (firebase importu YOK). Fabrikanin Firebase'li surumunu (02 yamasinda uygulanacak hali) ${WF}/SPL-factory-firebase.dart.txt olarak yaz: config null ise const UnsupportedPushGateway(), degilse FirebasePushGateway(config: config).
4. Testler: Firebase'siz testler (PushConfig saf testleri, UnsupportedPushGateway, koordinator/denetleyici testleri) Firebase importu OLMADAN calismali; Firebase'e bagli testleri (FirebasePushGateway desteklenme karari, deleteToken, FirebaseOptions donusumu) test/push/firebase_push_gateway_test.dart dosyasina TASI (02 yamasi). test/push/push_gateway_test.dart yalniz Firebase'siz kisimlari tutar. Hicbir testin kapsami KAYBOLMASIN (toplam test sayisi ayni; hangi testin nereye tasindigini rapora yaz).
5. DOGRULAMA A (Firebase'li, INTEG): flutter analyze lib/services lib/models lib/ui/widgets lib/ui/app_shell.dart test/services test/push test/ui test/support (0 sorun) + flutter test test/services test/push test/ui: hepsi gecmeli (onceki toplam: FXC/FXU raporlarina bak; sayilari kiyasla).
6. DOGRULAMA B (Firebase'SIZ kanit): ${NOFB} adli GECICI kopya olustur (INTEG'in lib test android ios pubspec.yaml pubspec.lock analysis_options.yaml; .dart_tool/build haric); bu kopyada: pubspec.yaml'dan firebase_core ve firebase_messaging satirlarini SIL; firebase_push_gateway.dart ve test/push/firebase_push_gateway_test.dart'i SIL; push_gateway_factory.dart Firebase'siz surum kalsin; 'flutter pub get' -> 'flutter analyze lib/services lib/models lib/ui/widgets test/services test/push test/ui test/support' 0 sorun ve 'flutter test test/services test/push test/ui' HEPSI GECMELI. Ayrica 'grep -rln "package:firebase" lib test' ile firebase paketlerini import eden TEK dosyalarin firebase_push_gateway.dart (+ testi) oldugunu (yorum satirlari sayilmaz) kanitla. Basarisizsa nedenini bul ve duzelt (INTEG'de).
7. 02-firebase kumesinin ICERIK LISTESINI ${WF}/SPL-dosya-ayrimi.txt'e yaz: (a) Firebase'siz set (01/03/04/05/06 yamalarina girecek), (b) Firebase seti: pubspec.yaml firebase satirlari (+ fake_async dev bagimliligi Firebase'siz sette de gerekli mi: testler fake_async kullaniyorsa o satir Firebase'siz sette KALMALI: pubspec hunk'ini iki parcaya ayir: 'fake_async (Firebase'siz, 01 ile)' ve 'firebase_core+firebase_messaging (02)'), lib/services/push/firebase_push_gateway.dart, push_gateway_factory.dart degisikligi, test/push/firebase_push_gateway_test.dart, ios/Runner/AppDelegate.swift ve Runner-Bridging-Header.h (Firebase pod'una bagli). iOS Info.plist UIBackgroundModes ve Android degisikliklerinin (kanal kodu, simge, manifest meta-data) Firebase paketleri OLMADAN zararsiz oldugunu (derleme/calisma) gerekcesiyle yaz.
8. Isin sonunda INTEG'in Firebase'li halinin testlerini yeniden calistirarak (5. adim) gectigini dogrula; ${NOFB} gecici kopyasini yukaridaki guvenli yontemle SIL.
9. EK KUCUK DUZELTME (Firebase ayriminden BAGIMSIZ ama ayni dosyalara dokunur: ayrimi bitirip dogruladiktan SONRA yap; raporda ayri baslik): FXU raporunda isaretlenen karar noktasi: sonuc SnackBar'inda maxLines 6 ile gercek 166 karakterlik sunucu iletisi ('... birden fazla panonun ortak baglantisi nedeniyle uzaktan kapatilamadi; lutfen elle kontrol edin.': kritik talimat SONDA) yazi olcegi >= 1.5'te gorsel olarak KISALIYOR. COZUM (istemci tarafi): PeaceNoticeController.closeAll'da skippedCount > 0 iken closeMessage icin sunucu mesajini KULLANMA; KISA ve talimati BASA alan Turkce ileti uret: kapatilan varsa 'Komut gönderildi; N öğe uzaktan kapatılamadı, lütfen elle kontrol edin.', kapatilan yoksa 'N öğe uzaktan kapatılamadı; lütfen elle kontrol edin.' (N = skippedCount; ~60-75 karakter). nothingToDo durumunda sunucu mesajini kullanmaya devam et. Mevcut testleri guncelle (sunucu mesajina bagli beklenti varsa) + once kirmizi, sonra yesil + en az 2 mutasyon. FXU'nun _maxResultLines (6) karari DEGISMEZ.
Referans sayilar (Firebase'li INTEG, hedefli): FXC raporu test/services + test/push = 976 gecti; FXU raporu test/ui + test/services + test/push = 1144 gecti (test/ui 168). Ayrim sonrasi toplam AYNI olmali (tasinan testler dahil), 9. madde yeni testler ekleyebilir.
Rapor: ${WF}/SPL-rapor.md (hangi dosyada ne tasindi, test eslemesi, dogrulama sayilari, 02 kumesi, 9. madde).
`

phase('Ayir')
const spl = await agent(SPL, { label: 'SPL firebase ayrimi', phase: 'Ayir', schema: RESULT, effort: 'high' })
return { spl }
