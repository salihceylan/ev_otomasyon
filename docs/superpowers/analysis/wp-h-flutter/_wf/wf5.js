export const meta = {
  name: 'wp-h-flutter-son',
  description: 'Flutter gece hatirlatmasi (Firebase YOK): orkestratorun KAPANIS sonrasi taze kopyasina 3 yonlu birlestir, TAM dogrula, bagimsiz incele, belgele, yama paketi + belge-kod denetimi',
  phases: [
    { title: 'Entegre', detail: 'RB: taze kopyaya birlestirme + TAM analyze/test' },
    { title: 'Incele', detail: 'RR3 entegre durum incelemesi + D1 belgeler paralel' },
    { title: 'Kapi', detail: 'G1: ardisik derlemeler + yama paketi + uygulama betigi' },
    { title: 'Denetim', detail: 'DR: belge iddialarini koda karsi dogrula' },
  ],
}

const SP = 'C:/Users/FINGON~1/AppData/Local/Temp/claude/g--site-site-kapi-kontrol/a379bdb3-93a0-4167-8a2c-eed43f0e926f/scratchpad'
const INTEG = SP + '/flutter_integ'
const INTEG_BASE = SP + '/flutter_integ_base'
const LIVE_BASE = SP + '/flutter_live_base2'
const LIVE = SP + '/flutter_live2'
const WF = SP + '/wp-h-flutter-wf'
const DOCS = 'G:/site/ev_otomasyon/docs/superpowers/analysis'
const YAMA = DOCS + '/wp-h-flutter/yamalar'

const COMMON = `
BAGLAM
Ev Otomasyonu (Flutter 3.47 / Dart 3.13, provider, REST + MQTT) uygulamasina "acik kalan lambalar icin gece hatirlatmasi" istemci tarafi izole kopyalarda hazirlandi ve iki tur bagimsiz incelemeden gecti (WF1-WF3: A1/A2/A3, R1-R3, F1/F2/F3, RR1/RR2, FXC/FXU, SPL). Raporlar: ${WF}/*.md. Sunucu tarafi BITTI ve canli agaca uygulandi. Baska bir (orkestrator) oturum GERCEK depoyu (G:/site/ev_otomasyon) yaziyor: oraya YAZMA (yalniz okuma; istisna: bu gorevde acikca belirtilen dizinler). Commit yapma. Sir okuma/yazma/yazdirma.

KULLANICI KARARLARI (kesin): (1) FIREBASE KULLANILMAYACAK: pubspec'e firebase_core/firebase_messaging EKLENMEYECEK; bildirim yalniz uygulama acikken/acilinca (sunucunun last_notice verisinden yedek afis) gorunur. Sonuc: 02-firebase yamasi YOK; INTEG'deki Firebase kumesi (lib/services/push/firebase_push_gateway.dart, test/push/firebase_push_gateway_test.dart, pubspec firebase satirlari, ios/Runner/AppDelegate.swift + Runner-Bridging-Header.h degisiklikleri) CANLIYA ALINMAZ (liste: ${WF}/SPL-dosya-ayrimi.txt; yalniz belge olarak saklanir). pubspec.yaml'a yalniz fake_async (dev) eklenir (testler kullaniyorsa). Push gonderim katmani (UnsupportedPushGateway, koordinator) 'yapilandirilmadi' no-op olarak KALIR (kapali, zararsiz). (2) Emulator/AVD/Chrome/ekran gezme denemeleri IPTAL; denemeyi kullanici yapacak: bu yuzden kod dogrulugu + analyze/test/derleme hatasizligi kesin olmali.

KOPYALAR: INTEG = ${INTEG} (bizim final calismamiz; ESKI 18:13 tabanli; derlenmez: yalniz hedefli analyze/test). INTEG_BASE = ${INTEG_BASE} (18:13 dokunulmamis). LIVE_BASE = ${LIVE_BASE}: orkestratorun KAPANIS sonrasi (01:06) gercek agacinin TAZE dokunulmamis kopyasi; tam yesil taban: ${WF}/baseline-live2.txt. LIVE = ${LIVE}: LIVE_BASE uzerine bizim entegrasyonun uygulandigi kopya (RB olusturur). WF = ${WF}.
ORKESTRATOR PROTOKOLU: lib/**, android/**, ios/**, pubspec.yaml onlarin; dogrulama KOPYADA; hazir olunca 'simdi uygula' penceresi (15-30 dk). Yama paketi KUCUK, cakisma-dayanikli, sirali uygulanabilir olmali. Orkestratorun son turda dokundugu ve bizimle CAKISABILECEK dosyalar: lib/ui/app_shell.dart (onGenerateRoute/onUnknownRoute + import), lib/services/automation_state.dart (fetchHomeMembers/getHomeTransferStatus basina kilit korumasi), lib/ui/pages/auth/auth_gate.dart, lib/services/ev_mqtt_service.dart, automation_api_service.dart, capabilities.dart, relay_switch_card.dart. Su an baslayan Android isi MainActivity.kt (configureFlutterEngine + plugins.add), AndroidManifest.xml (2 uses-permission), yeni Kotlin dosyalari, automation_api_service.dart, yeni lib/services/board_network_binding.dart dosyalarina dokunacak: bizim MainActivity kanal/AndroidManifest meta-data degisikligimizle ayni dosyalar; uygulama aninda iki satirlik elle birlestirme yeterli: yamayi KUCUK tut. AuthStatus enum'una yeni deger YOK (yeniden kilit = checking + _awaitingUnlock); closeAllOpenLights(String) imzasi DEGISMEZ.

KISITLAR: C: diskinde yer DAR (~9 GB bos), bellek ~1 GB: ayni anda TEK flutter komutu; build'ler ARDISIK (run_in_background, cikti dosyaya); gecici kopyalari isin sonunda SIL (silme: PowerShell'de Remove-Item/rmdir/rd KULLANMA (guvenlik denetimi engelliyor); kopyalarda .plugin_symlinks gibi baglantilar var ve pub onbellegine gider: once 'cmd /c dir /AL /S /B <dizin>' ile baglantilari listele, her birini [System.IO.Directory]::Delete(baglanti, \$false) ile TEK TEK kaldir, sonra [System.IO.Directory]::Delete('\\\\?\\' + tamYol, \$true) ile klasoru sil). ASLA flutter run, adb, emulator, AVD, pio, docker; derlemeleri YALNIZ kopyada; 54329/1883/18083/5000/8081-8083/18090 portlarina dokunma. Windows: yeni dosyalar LF; mevcut dosyada satir sonunu node ile say ve koru. Regex/ters egik cizgi/kesme isareti iceren betikleri Bash heredoc veya node -e ile DEGIL, Write araciyla dosyaya yazip calistir. Node'da yol 'C:/...' veya 'G:/...'. Turkce kullanici metinleri/yorumlar DOGRU Turkce karakterlerle (bu metin ASCII'ye sadelestirildi). dart format'i yalniz KENDI yeni/degistirdigin dosyalarina uygula. Durust ol: calistirmadigini 'gecti' deme. Sonucu semaya uygun dondur, ayrintili raporu WF dizinine yaz.
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
GOREVIN: RB - TAZE CANLI KOPYAYA 3 YONLU BIRLESTIRME + TAM DOGRULAMA. Yazma izni: LIVE ve WF. Once ${WF}/SPL-rapor.md, SPL-dosya-ayrimi.txt (hangi dosyalar Firebase kumesinde: ALINMAZ), FXC-rapor.md, FXU-rapor.md'yi OKU.
1. LIVE = LIVE_BASE'in tam kopyasi (.dart_tool dahil). Taban kaydini kontrol et: ${WF}/baseline-live2.txt.
2. Bizim degisikliklerimizi INTEG'den LIVE'a aktar (INTEG ile INTEG_BASE arasindaki farki 'diff -rq -x .dart_tool -x build -x pubspec.lock' ile cikar; Firebase kumesi HARIC):
   a) YENI dosyalar (INTEG'de var, INTEG_BASE'de yok): LIVE'da AYNI yola kopyala (LF). Ayni yolda baska bir canli dosya varsa DUR ve raporla. (push_gateway_factory.dart Firebase'siz surum ALINIR; firebase_push_gateway.dart ve testi ALINMAZ.)
   b) MEVCUT dosyalar (INTEG_BASE'de de var, INTEG'de degismis): pubspec.yaml (YALNIZ fake_async dev; firebase satirlari DEGIL), lib/services/ev_cloud_api_service.dart, lib/models/api_models.dart, lib/services/automation_state.dart, lib/ui/app_shell.dart, android/** (MainActivity.kt, AndroidManifest.xml, res/drawable/ic_stat_peace.xml), ios/Runner/Info.plist (yalniz UIBackgroundModes; AppDelegate.swift ve Runner-Bridging-Header.h ALINMAZ) ve varsa digerleri: 3 YONLU birlestirme: 'git merge-file' (current = LIVE_BASE dosyasi, base = INTEG_BASE dosyasi, other = INTEG dosyasi); once LF'e normalize et, birlestir, sonucu LIVE dosyasinin ORIJINAL satir sonuyla (CRLF/LF; node ile say) yaz. Catisma varsa elle coz (orkestrator ayni dosyalara dokundu). Birlestirme sonrasi 'diff LIVE_BASE/<dosya> LIVE/<dosya>' ile SADECE bizim hunk'larin eklendigini dogrula.
   c) .gitignore: ${WF}/F3-gitignore.patch'in satirlarini ekle (zaten varsa atla).
   d) Ayar karti: canli ayar sayfasindaki Huzur bildirimi kartini (peaceSettings kullanan kart; lib/ui altinda ara) bul; govdesine iki TEK SATIR ekle: const PeaceReminderDetails(); const PushStatusTile(); Bilesenler PeaceNoticeController saglayicisi YOKKEN (mevcut kart testleri) COKMEMELI (nullable arama; SizedBox.shrink); gerekirse duzelt + test.
   e) Derlenmeyen/kirilan canli test yardimcilari varsa MINIMUM uyarlama; E1/E2/F kodunda hata bulursan DEGISTIRME, raporla.
3. DOGRULAMA (LIVE'da TAM): flutter pub get; flutter analyze (TAM; taban 0 sorun -> 0); flutter test (TAM; taban ${WF}/baseline-live2.txt: tabanda gecen HICBIR test kirilmamali; yeni testlerimiz gecmeli; sayilar). 'grep -rln "package:firebase" lib test pubspec.yaml' -> HIC sonuc OLMAMALI. Kirilan/yuklenmeyen test varsa kok nedeni bul; bizim kodun hatasiysa duzelt ve ayni duzeltmeyi INTEG'e yansit (INTEG ve LIVE'daki bizim dosyalar BIREBIR ayni kalmali; fark varsa raporla).
4. Rapor ${WF}/RB-rapor.md ve ${WF}/RB-merge-notlari.md (hangi dosyada hangi catisma nasil cozuldu; LIVE_BASE'e gore tum farklar; analyze/test sayilari). Gereksiz build/ klasorlerini temizle; LIVE KALSIN.
`

const RR3 = COMMON + `
SEN BAGIMSIZ BIR ELESTIRMENSIN (adversarial): entegre durumu CURUTMEYE calis. Dosya DEGISTIRME (yalniz ${WF}/RR3-rapor.md ve WF altindaki gecici kopyalar; gecici kopyalari isin sonunda guvenli yontemle sil). Yalnizca KOD ALINTILI KANITLA bulgu bildir; tahmin/stil yazma; kritik/yuksek bulgulari calistirarak kanitla. Farklar: diff -ru -x .dart_tool -x build ${LIVE_BASE} ${LIVE}. RB raporu: ${WF}/RB-rapor.md, RB-merge-notlari.md; onceki raporlar FXC, FXU, SPL, RR1, RR2.
Odak: (a) entegrasyon noktalari: app_shell hunk'i (canli dosyaya dogru birlesti mi: Provider kapsami, dispose sirasi, builder zinciri, orkestratorun yeni onGenerateRoute/onUnknownRoute kodu ile etkilesim), ayar karti 2 satir (saglayici yokken cokmeme), automation_state kancasi (logout() zamanlamasi; hesap silme / oturum kapatma / servis oturumu girisi akislari), AuthStatus.checking + _awaitingUnlock yeniden kilidinin denetleyicide GERCEK gecislerle (handleLifecycleState, biyometrik, auth_gate'in popUntil'i) kilit sirasinda gelen bildirimi/yedek afisi bozmadigi; (b) Firebase'siz set gercekten Firebase'siz mi (import taramasi, pubspec); push katmani 'yapilandirilmadi' no-op'ken uygulama push'suz surumle AYNI davranir mi, ve yedek afis (last_notice) yolu uygulama acilinca/ev verisi yenilenince GERCEKTEN calisiyor mu (fetchPeaceNotification -> fromSettings -> banner; canUseGroupCommands/capabilities kosullari; bulut modu); (c) onceki bulgularin kapanisi (RR1-01/02/04/08, RR2-01..05, B1-B8, R3-01) previousFindingsStatus'ta; yeni regresyon; (d) TAM test paketini KENDIN calistir (LIVE'in gecici kopyasinda) ve tabanla karsilastir; (e) E1/E2 yuzeyleriyle etkilesim: panodaki 'Huzur Modu' bandi (lib/ui/dashboard/peace_banner.dart) + CloseAllLightsButton + yeni afis; AppShell testleri; (f) gizlilik/guvenlik: log, ev adi/ozet sizmasi; (g) yama paketi riskleri: hareketli dosyalar, satir sonlari (CRLF/LF), MainActivity/AndroidManifest cakismasi (orkestratorun yeni Android isi).
`

const D1 = COMMON + `
GOREVIN: D1 - BELGELER (duz yazi; .txt disa aktarimi G1 yapar). Yazma izni YALNIZ ${DOCS}/wp-h-flutter/ altinda .md dosyalari (_wf ve yamalar dizinlerine DOKUNMA). Once ${WF}/RB-rapor.md, SPL-rapor.md, FXC-rapor.md, FXU-rapor.md, F2/F3, A1-A3, R1-R3, RR1, RR2 raporlarini ve LIVE'daki GERCEK kodu OKU; belgeyi GERCEK koda gore yaz (uydurma/varsayim YOK; her somut iddia kodda dogrulanabilir olmali).
1. ENTEGRASYON.md'yi BASTAN YAZ (kisa, uygulayiciya yonelik, sirali): FIREBASE'SIZ mimari: kabuk tabanli baglanti (PeaceNoticeController + PeaceNoticeHost koprusu + AppShell hunk'i; afis=MaterialBanner, sonuc=SnackBar), AutomationState'e yalniz cikis kancasi (addBeforeLogoutHook; logout() icinde; 1 sn tavan; arka planda tamamlanir), push katmani 'yapilandirilmadi' no-op (UnsupportedPushGateway + fabrika), yedek afis: uygulama acilinca/ev verisi yenilenince sunucunun last_notice'indan (PeaceNotice.fromSettings; kosullar: cozulmemis, 14 saatten yeni, canli cihazlar, canli sayi > 0), CloseAllResult/PeaceNotificationSettings v2, includeShutters kurali (eski pano dugmesi closeAllOpenLights(String): include_shutters:false; afis closeAllForNotice: panjur varsa true), ayar kartina 2 satir, Android (kanal 'peace_reminder' + kucuk simge + manifest meta-data: Firebase'siz de zararsiz), iOS Info.plist UIBackgroundModes, .gitignore; yama uygulama SIRASI/komutlari (G1'in yamalar/README.md ve uygula.sh ile tutarli; satir sonu notu: git apply --ignore-whitespace ve elle birlestirme); dogrulama (otomatik komutlar ve SAYILAR: RB raporundan); BILINEN SINIRLAR (durust): uygulama KAPALIYKEN telefona bildirim DUSMEZ (kullanici karari: Firebase yok); kilit ekrani (checking) sirasinda gelen push olayi yok sayilir ama yedek afis kilit acilinca gelir; panodaki eski 'Huzur Modu' bandi ile ikili yuzey (RR2-08); banner icerik yazi olcegi 1.5 siniri (RR2-06); kisa mesaj kurali; bayat ev listesi (RR1-03). Firebase'in ileride istenirse nasil eklenecegi: SPL-dosya-ayrimi.txt'teki Firebase kumesi (kisa not; paketler/APNs/FCM gerekir) - bu belgenin ANA yolu DEGIL, ek bolum.
2. PUSH_KURULUM.md: kisa bir 'KULLANILMIYOR' notuna indir: Firebase kullanilmadigi, ileride istenirse gereken adimlarin (mevcut icerigin ozeti, gizlilik kurallari, FCM_SERVICE_ACCOUNT_JSON yok: yalniz dosya yolu) arsivlendigi; sunucuda PUSH yapilandirilmazsa kaydin no_recipients yazildigi ve uygulama icinde gorundugu (kod/dokumandan dogrula).
3. README.md: guncel durum (Firebase'siz), dogrulama sonuclari, yama dosyasi listesi ve sirasi (G1 yazinca tutarlilik icin 'yamalar/README.md bkz.'); kullanicinin yapacagi bir sey YOK (Firebase hesabi vb. gerekmiyor).
Rapor: ${WF}/D1-rapor.md.
`

const G1 = COMMON + `
GOREVIN: G1 - KAPI: ardisik derlemeler + yama paketi + uygulama betigi. Yazma izni: LIVE, WF ve ${YAMA} (YENI dizin; olustur) ve ${DOCS}/wp-h-flutter/ altinda .txt disa aktarimlari. RR3 ve D1 bitti (${WF}/RR3-rapor.md, D1-rapor.md; RR3 bulgusu varsa ONCE kucuk/kanitli duzeltmeleri LIVE ve INTEG'e uygula (kritik/yuksek ve acik/kolay orta bulgular; belirsizse DOKUNMA, raporla)).
1. Dogrulama: LIVE'da flutter analyze (0) + flutter test (TAM; taban ${WF}/baseline-live2.txt). Sayilari kaydet.
2. Derlemeler (ARDISIK; her biri icin YENI gecici kaynak kopyasi, bitince SIL; ~3.5 GB/kopya): (i) LIVE 'flutter build apk --debug' ~7 dk (run_in_background; Kotlin artimli onbellek / farkli surucu sorunu: ${WF}/A3-rapor.md'deki yontem: kaynak kopyayi C: altinda, PUB_CACHE=${SP}/pubcache_c ile derle); birlesik manifestte default_notification_icon meta-data'sini ve ic_stat_peace kaynaginin derlendigini goster; (ii) LIVE 'flutter build web' (~2 dk). Windows derlemesi: orkestrator kendi agacinda derledi; DENEME. Bellek yetmezse zaman asimi olabilir: yeniden dene ve raporla.
3. Yama paketi (${YAMA}/; hepsi LF-normalize 'git diff --no-index' ciktisi, a/ b/ onekleri repo kokune GORELI (git diff --no-index iki dizin adini onek yapar: basliklari duzelt; ornek betik ${SP}/make_patch.js), pubspec.lock HARIC), LIVE_BASE -> LIVE:
   - 01-yeni-dosyalar.patch: YENI dosyalar (lib/services/push/** (Firebase'siz), peace_notice_controller.dart, push_token_api_adapter.dart, lib/ui/widgets/ yeni dosyalar, yeni testler)
   - 03-mevcut-dosyalar.patch: ev_cloud_api_service.dart + api_models.dart + automation_state.dart (kanca) + pubspec.yaml (fake_async) + ayar karti 2 satir + degisen MEVCUT testler (varsa)
   - 04-app-shell.patch: lib/ui/app_shell.dart baglantisi
   - 05-platform.patch: android (MainActivity.kt, AndroidManifest.xml meta-data, drawable) + ios Info.plist; MainActivity.kt hunk'ini MINIMUM tut (orkestratorun yeni Android isi ayni dosyaya configureFlutterEngine ekleyecek)
   - 06-gitignore.patch
   - README.md: UYGULAMA SIRASI (01, 03, 04, 05, 06), her yamanin hangi ekibin dosyasina dokundugu, satir sonu uyarisi (CRLF/LF: git apply --ignore-whitespace), cakisma durumunda 3 yonlu birlestirme notlari (ozellikle MainActivity.kt, app_shell.dart, automation_state.dart), geri alma (git apply -R ters sira).
   - uygula.sh: yamalari sirayla 'git apply --check' ile deneyip uygulayan, hata olursa durup ne yapacagini yazan, sonunda hedefli analyze/test komutlarini YAZDIRAN (otomatik calistirmayan) betik; Windows Git Bash'te calismali. Betigi GERCEK AGACA CALISTIRMA; yalniz bir temiz kopyada dene.
   KANIT: yamalari LIVE_BASE'in GECICI temiz kopyasina sirayla uygulayip sonucun LIVE ile BIREBIR ayni oldugunu (diff -r; .dart_tool/build/pubspec.lock haric) goster. Her yamayi GERCEK agaca (G:/site/ev_otomasyon) 'git apply --check' ile ayrica dene (agac hareketli; sonuc anlik; basarisiz hunk'lari durustce yaz).
4. Disa aktarim: LIVE'daki YENI dosyalari .txt olarak ${DOCS}/wp-h-flutter/ altina aktar (lib/services/push/*, peace_notice_controller.dart, push_token_api_adapter.dart, lib/ui/widgets/ yeni dosyalar, yeni testler; ayni yol agaci); eski .txt'leri guncelle/sil (yalniz .txt; Firebase kumesi dosyalari firebase_push_gateway.dart.txt + testi 'arsiv/' alt klasorune); BIREBIR ayni oldugunu diff ile kanitla.
5. Rapor ${WF}/G1-rapor.md: tum komutlar/sonuclar/sayilar/sureler, derleme boyutlari, acik riskler.
`

const DR = COMMON + `
GOREVIN: DR - BELGE-KOD CAPRAZ DENETIMI (SALT OKUNUR; yalniz ${WF}/DR-rapor.md yaz). Dokumantasyon ajanlari uyduruyor/madde kaybediyor/eski iddialari koruyor: ${DOCS}/wp-h-flutter/ENTEGRASYON.md, PUSH_KURULUM.md, README.md ve ${YAMA}/README.md + uygula.sh icindeki HER somut iddiayi (dosya/sinif/yontem adi, sabit, sure, metin, komut, sayi, sira, kosul) LIVE'daki gercek koda / G1 derleme kayitlarina (${WF}/G1-rapor.md) / sunucu koduna (G:/site/ev_otomasyon/server/src/services/push_service.js, peace_service.js, peace_reminder.js) karsi dogrula. Dogrulanamayan, yanlis, eski (WF1 oncesi mimariye ait: AutomationState'e dogrudan baglama, Stack/Positioned overlay kart, FCM_SERVICE_ACCOUNT_JSON, eski test sayilari, Firebase'i ana yol gibi anlatan iddialar vb.), kendi icinde celisen veya yama paketiyle uyusmayan her iddiayi listele (belge, iddia, gercek, kanit, siddet, onerilen duzeltme). Ayrica yamalar/README.md ve uygula.sh'taki komutlari bir temiz kopyada KURU calistir. verifiedClaims = dogruladigin iddia sayisi.
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
