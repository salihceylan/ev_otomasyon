export const meta = {
  name: 'wp-h-flutter-entegre',
  description: 'Flutter gece hatirlatmasi: delta bulgularini duzelt (cekirdek + arayuz paralel), canli agac kopyasina entegre et ve TAM dogrula, sonra bagimsiz entegrasyon incelemesi ve belgeler',
  phases: [
    { title: 'Duzelt', detail: 'FXC cekirdek (RR1) + FXU arayuz (RR2) paralel' },
    { title: 'Entegre', detail: 'RB: canli agac kopyasina 3 yonlu birlestirme + TAM analyze/test' },
    { title: 'Incele', detail: 'RR3 entegre durum incelemesi + D1 belgeler paralel' },
  ],
}

const SP = 'C:/Users/FINGON~1/AppData/Local/Temp/claude/g--site-site-kapi-kontrol/a379bdb3-93a0-4167-8a2c-eed43f0e926f/scratchpad'
const INTEG = SP + '/flutter_integ'
const INTEG_BASE = SP + '/flutter_integ_base'
const INTEG_WF1 = SP + '/flutter_integ_wf1'
const LIVE_BASE = SP + '/flutter_live_base'
const LIVE = SP + '/flutter_live'
const WF = SP + '/wp-h-flutter-wf'
const DOCS = 'G:/site/ev_otomasyon/docs/superpowers/analysis'

const COMMON = `
BAGLAM
Ev Otomasyonu (Flutter 3.47 / Dart 3.13, provider, REST + MQTT) uygulamasina "acik kalan lambalar icin gece hatirlatmasi" (FCM push) istemci tarafi izole kopyalarda hazirlaniyor. SUNUCU TARAFI BITTI ve canli agaca uygulandi. Istemci icin: WF1 (cekirdek A1, arayuz A2, platform A3; eleştirmenler R1-R3) ve WF2 (F1 cekirdek duzeltmeleri, F2 arayuz MaterialBanner yeniden yazimi, F3 platform; delta elestirmenleri RR1/RR2) bitti. RR1 ve RR2 raporlari: ${WF}/RR1-rapor.md, ${WF}/RR2-rapor.md (OKU; bulgularin kanitli ayrintisi ve calistirilmis kanit testleri orada: ${WF}/rr1_probe*, ${WF}/RR2_copy/...). Baska bir (orkestrator) oturum GERCEK depoyu (G:/site/ev_otomasyon) yaziyor: oraya YAZMA (yalnizca okuma; istisna: yalniz bu gorevde acikca belirtilen dizinler). Commit yapma. Sir okuma/yazma/yazdirma.

KOPYALAR:
- INTEG = ${INTEG}: 18:13 anlik (ESKI) kopya + bizim tum calismamiz (WF1+WF2). Derlenmez/yarim: yalnizca HEDEFLI analyze/test. Duzeltme turu (FXC/FXU) BURADA yapilir. INTEG_BASE = ${INTEG_BASE} (18:13 dokunulmamis), INTEG_WF1 = ${INTEG_WF1} (WF1 sonu).
- LIVE_BASE = ${LIVE_BASE}: orkestratorun GERCEK agacinin 22:37 anlik, dokunulmamis kopyasi. Bu agac ARTIK TAM YESIL: flutter analyze 0 sorun, flutter test +1606 hepsi gecti (kayit: ${WF}/baseline-live.txt).
- LIVE = ${LIVE}: LIVE_BASE uzerine bizim entegrasyonun uygulandigi kopya (RB olusturur; sonraki asamalar burada TAM analyze/test calistirabilir).
- WF = ${WF} (rapor/defter; serbestce yaz).

MIMARI KARARI (orkestratorle mutabik): push AutomationState'e/sayfalara degil uygulama kabuguna baglanir (PeaceNoticeController + PeaceNoticeHost koprusu; afis MaterialBanner, sonuc SnackBar); AutomationState'e yalniz cikis kancasi; pubspec firebase hunk'i AYRI; yapilandirma yoksa push'suz davranis AYNI. Mevcut (E1/E2/F'nin) dosyalarina HER ekleme minimum olsun (bicim degisikligi/yeniden adlandirma/ilgisiz temizlik YOK).

GENEL KURALLAR: Turkce kullanici metinleri/yorumlar DOGRU Turkce karakterlerle (bu metin ASCII'ye sadelestirildi; ç, ğ, ı, ö, ş, ü, İ kullan). Kodu degistirmeden once ilgili dosyalari OKU. Gizli veri/belirtec/ev adi log'a yazilmaz. Windows: yeni dosyalar LF; mevcut dosyada satir sonunu (CRLF/LF) node ile say ve koru. Regex/ters egik cizgi/kesme isareti iceren betikleri Bash heredoc veya node -e ile DEGIL, Write araciyla dosyaya yazip calistir. Node'da yol 'C:/...' veya 'G:/...'. Flutter: ayni dizinde es zamanli iki flutter komutu calistirma; build gibi uzun komutlari run_in_background ile calistir; ASLA 'flutter run', adb, emulator, pio, docker; 54329/1883/18083/5000/8081-8083 portlarina dokunma. dart format'i yalnizca KENDI yeni/degistirdigin dosyalarina uygula. Her duzeltme icin ONCE basarisiz (kirmizi) test, SONRA duzeltme, sonra gecici mutasyonla testin yakaladigini kanitla (dosyalari geri alip ozdeslik dogrula). Durust ol: calistirmadigini 'gecti' deme. Sonucu semaya uygun dondur, ayrintili raporu WF dizinine yaz.
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

// ---------------------------------------------------------------------------------------------
const FXC = COMMON + `
GOREVIN: FXC - CEKIRDEK DELTA DUZELTMELERI (INTEG). Sahip oldugun yollar: INTEG/lib/services/**, INTEG/lib/models/**, INTEG/test/services/**, INTEG/test/push/**, INTEG/test/support/** ve test/ui/peace_ui_rig.dart'in YALNIZ sahte bulut API'si bolumu (closeAllOpenLights -> yeni yontem adi; baska hicbir yerine DOKUNMA: FXU arayuzu ayni anda duzeltiyor). Once ${WF}/RR1-rapor.md'yi OKU (kanit testleri: ${WF}/rr1_probe*). KARAR VERILMIS (ben kodda dogruladim):
1. RR1-01 (YUKSEK, F1 REGRESYONU): biyometrik yeniden kilit ve soguk acilis AuthStatus.checking yapar (automation_state.dart: isAuthenticated => _authStatus == AuthStatus.authenticated; _authStatus = checking satirlari 170, 669, 1024, 1061); denetleyicide _sessionEnded => !state.isAuthenticated || state.isServiceSession oldugu icin KILIT = oturum bitisi sanilir ve FCM belirteci SILINIR (gece bildirimi kaybolur, her kilitte belirtec yeniden uretilir). DUZELTME: AuthStatus.checking BELIRSIZDIR: oturum bitmis SAYILMAZ ve uygunluk degisikligi/baslat/durdur/gecersiz-kil HIC tetiklenmez (checking surerken onceki durum korunur; kilit acilinca authenticated'a donusu ESKI uygunlukla ayni ise yeniden baslatma/yeniden kayit baskisi YOK). Yalnizca authStatus == unauthenticated (veya servis oturumu) oturum bitisidir. Mevcut push/oturum-bitisi/soguk-acilis davranislarini (F1 testleri: SessionExpiredEvent yolu dahil) BOZMA. Testler (once kirmizi): gercek handleLifecycleState(paused -> 2 dk -> resumed) + biyometrik acik (setBiometricForTesting vb.; RR1'in rr1_probe2/RR1-D denemesi) -> kilitte deleteToken CAGRILMAZ ve push durmaz; kilit acilinca eski belirtec/kayit korunur (gereksiz yeniden kayit yok); soguk acilis checking -> authenticated: deleteToken yok; checking -> unauthenticated (olay yok): deleteToken yok (olay yolu ayri); gercek cikis (unauthenticated gecisi) hala deleteToken cagirir.
2. RR1-02 (ORTA, API uyumlulugu): canli agacin test yardimcilari (test/ui/e1_helpers.dart:30: E1Cloud.closeAllOpenLights(String homeId) override'i) EvCloudApiService.closeAllOpenLights imzasi genisleyince DERLENMEZ. DUZELTME: EvCloudApiService.closeAllOpenLights(String homeId) IMZASI ESKI HALINE donsun (tek konumsal parametre); GOVDESI {home_id, include_shutters: false} olsun (eski pano dugmesi yalniz lamba kapatir: B3). YENI yontem: Future<Map<String, dynamic>> closeAllForNotice(String homeId, {int? noticeId, bool includeShutters = true}) (POST ayni uc; govde: home_id, notice_id?, include_shutters). PeaceNoticeController bu yeni yontemi kullanir; testleri ve test/ui/peace_ui_rig.dart'taki sahte bulut API'sini (yalniz o bolum) yeni yonteme uyarla; test/services/peace_v2_models_and_api_test.dart'taki beklentileri guncelle (eski yontem govdesi {home_id, include_shutters:false}).
3. RR1-04 (ORTA): _finishedByFreshData sayi tabanli kaldirmada KISMI CEVRIMDISI evde (devices_online < devices_total) 'sayilar 0' diye push afisini kaldiriyor ('hepsi kapali' denemez: CONTRACTS yasakliyor). DUZELTME: sayi tabanli kaldirma YALNIZ devices_total ve devices_online verilmis, > 0 ve ESIT iken; aksi halde yalniz last_notice cozumuyle (id eslesir ve resolved) kalksin. Test (RR1-B kirmizi->yesil).
4. RR1-08 (DUSUK): afis 'Hepsini kapat' her zaman include_shutters:true gonderiyor: bildirim 0 panjur diyorsa gonderme: includeShutters = notice.openShutters > 0. Test.
5. Test boslugu: RR1'in kacan mutantlari S5 (ev listesi bosken gelen bildirimi atma korumasi: 'state.homes.isNotEmpty' - bos listede bildirim KAYBOLMAMALI) ve S14 (timer.cancel) icin test ekle.
YAPMA (bilincli, belgelenecek bilinen sinirlar): RR1-03 (bayat ev listesi), RR1-05 (cevrimdisi cikista kalici yeniden deneme), RR1-06 (logoutAll'da sunucu DELETE 401: sunucu tarafi iyilestirme onerisi), RR1-07 (satir sonu: yama yeniden uretilecek), B6, B7.
Hedefli dogrulama: flutter analyze lib/services lib/models test/services test/push test/support test/ui (0 sorun); flutter test test/services test/push test/ui (hepsi gecmeli; FXU ayni anda test/ui'yi degistiriyor: kendi calistirmanda onun yarim dosyalari kirmizi cikarsa tekrar dene/bekle, kendi alanin icin yalniz test/services + test/push'u esas al). Rapor: ${WF}/FXC-rapor.md (public API degisiklikleri: closeAllForNotice, eski yontem govdesi, denetleyici davranislari).
`

const FXU = COMMON + `
GOREVIN: FXU - ARAYUZ DELTA DUZELTMELERI (INTEG). Sahip oldugun yollar: INTEG/lib/ui/widgets/(peace_notice_host.dart, push_status_tile.dart, peace_reminder_details.dart), INTEG/test/ui/** (test/ui/peace_ui_rig.dart'in SAHTE BULUT API'si bolumune DOKUNMA: FXC ayni anda yeni yontem adina uyarliyor). Once ${WF}/RR2-rapor.md'yi (kanit testleri ${WF}/RR2_copy/test/ui/) ve ${WF}/F2-rapor.md'yi OKU. KARAR VERILMIS:
1. RR2-01 + RR2-02 + RR2-03 (ORTA/ORTA/DUSUK): sonuc iletisi SnackBar'i KALICI (persist) ve yazi olcegine sinirsiz: gercek 166 karakterlik sunucu iletisiyle 360x740'ta 2.0 olcekte ekranin %98'i, 3.0'da %100'u; 'Tamam' ekran disinda; hic dokunulmazsa 60 sn; sayfalarin kendi SnackBar'larini suresiz kuyrukta bekletiyor; cikista/giris ekraninda kaliyor. DUZELTME: sonuc SnackBar'i persist:false, makul sure (8 sn), showCloseIcon:true (action yok), icerik MediaQuery.withClampedTextScaling(maxScaleFactor: 1.5) + maxLines (6) + ellipsis; kopru gosterdigi SnackBar'in tutamagini (ScaffoldFeatureController) SAKLASIN ve oturum bitince / denetleyici uygun degilse / yeni bir bildirim afisi gelince / kopru dispose olunca hide etsin (RR2-03). Testler (once kirmizi): gercek Roboto + gercek uzunlukta ileti + 360x740 ve 320x568, olcek 1.0/1.5/2.0/3.0: kapatma simgesi ekranda ve dokunulabilir, toplam yukseklik <= ~%50; persist degil: sure sonunda kalkar ve sonraki sayfa SnackBar'i gorunur olur (kuyruk beklemez); oturum bitince kalkar; yeni bildirim gelince kalkar.
2. RR2-04 (DUSUK, test bosluklari): kacan mutantlar N18 (metin bolgesi kaydirilamaz) ve N20 (harici removeCurrentMaterialBanner/hideCurrentMaterialBanner sonrasi yeniden gosterim): RR2'nin kanit testlerini (RR2_copy/test/ui/rr2_adv_test.dart icinde RR2-E1/E2/E3 ve kaydirma) host test dosyasina al: drag sonrasi Scrollable konumunun degistigini ve govde son satirinin gorunur oldugunu assert et; disaridan kaldirilan banner'in (kullanici karari olmayan) yeniden gosterilmesini dogrula.
3. RR2-05 (DUSUK, ekran okuyucu): eylem dugmelerine anlasilir Semantics etiketleri: 'Kapat' -> 'Bildirimi kapat'; 'Hepsini kapat' -> 'Açık lambaların ve panjurların hepsini kapat' (gorunen metni icerecek bicimde: etiket gorunen metni barindirmali); canli bolge duzeni korunur. Test: semantik agacinda etiketler.
YAPMA (bilincli, belgelenecek): RR2-06 (cerceve banner icerik olcegi 1.5 siniri), RR2-08 (panodaki eski 'Huzur Modu' bandi ile ikili yuzey: urun karari), RR2-07 (AppShell yamasi yeniden uretilecek).
Hedefli: flutter analyze lib/ui/widgets lib/ui/app_shell.dart test/ui lib/services lib/models test/services test/push test/support (0 sorun); flutter test test/ui test/services test/push (hepsi gecmeli; FXC ayni anda lib/services'i degistiriyor: yarim dosyalarindan kaynakli gecici kirmizi olursa kisa sure sonra tekrar dene; kendi alanin icin test/ui'yi esas al). En az 8 mutasyonla testlerin yakalama gucunu kanitla. Rapor: ${WF}/FXU-rapor.md.
`

const RB = COMMON + `
GOREVIN: RB - ENTEGRASYONU CANLI AGAC KOPYASINA YENIDEN TEMELLENDIR + TAM DOGRULAMA. FXC ve FXU BITTI (INTEG'de son hal; raporlar ${WF}/FXC-rapor.md, FXU-rapor.md; once OKU). Yazma izni: LIVE ve WF.
1. LIVE = LIVE_BASE'in tam kopyasi (cp -r; .dart_tool dahil; ${LIVE} yoksa olustur; varsa onceki icerigi once yedekle/sifirdan kur).
2. Bizim degisiklikleri INTEG'den LIVE'a aktar (INTEG ile INTEG_BASE arasindaki farki 'diff -rq -x .dart_tool -x build -x pubspec.lock' ile cikar):
   a) YENI dosyalar (INTEG'de var, INTEG_BASE'de yok): LIVE'da AYNI yola kopyala (LF). LIVE'da ayni yolda baska bir dosya varsa DUR ve raporla.
   b) MEVCUT dosyalar (INTEG_BASE'de de var, INTEG'de degismis): pubspec.yaml, lib/services/ev_cloud_api_service.dart, lib/models/api_models.dart, lib/services/automation_state.dart, lib/ui/app_shell.dart, android/app/src/main/kotlin/**/MainActivity.kt, android/app/src/main/AndroidManifest.xml, ios/Runner/Info.plist, ios/Runner/AppDelegate.swift, ios/Runner/Runner-Bridging-Header.h, test/ui/peace_ui_rig.dart gibi bizim yeni dosyalarimiz DEGIL; varsa baskalari: 3 YONLU birlestirme: 'git merge-file' (current = LIVE_BASE'in dosyasi, base = INTEG_BASE dosyasi, other = INTEG dosyasi). Uc dosyayi once LF'e normalize et, birlestir, sonucu LIVE dosyasinin ORIJINAL satir sonuyla (CRLF/LF; node ile say) yaz. Catisma varsa elle coz (canli dosyanin yeni yapisina saygi: ornegin canli app_shell.dart'ta auth_gate importu/AuthGate varsayilani kalkmis; E1 degisikligi). Her birlestirmeden sonra 'diff LIVE_BASE/<dosya> LIVE/<dosya>' ile SADECE bizim hunk'larin eklendigini dogrula.
   c) .gitignore: ${WF}/F3-gitignore.patch'in satirlarini LIVE/.gitignore'a ekle (zaten varsa atla).
   d) Ayar karti: canli ayar sayfasindaki Huzur bildirimi kartini (peaceSettings kullanan kart; lib/ui altinda ara) bul; kart govdesine iki TEK SATIR ekle: const PeaceReminderDetails(); const PushStatusTile(); (yerlestirme notu: ${WF}/A2-rapor.md). Bu bilesenler PeaceNoticeController saglayicisi YOKKEN (mevcut kart testleri) COKMEMELI: nullable arama (context.watch<PeaceNoticeController?>() veya esdegeri) ile SizedBox.shrink; gerekirse bilesenleri bu sekilde duzelt ve test ekle.
   e) Derlenmeyen/kirilan canli test yardimcilari varsa (ornegin test/ui/e1_helpers.dart closeAllOpenLights override'i: FXC eski imzayi korudu, sorun cikmamali) MINIMUM uyarlama yap; E1/E2/F'nin KODUNDA hata bulursan DEGISTIRME, raporla.
3. DOGRULAMA (LIVE'da TAM): flutter pub get; flutter analyze (TAM; taban 0 sorun -> 0 olmali); flutter test (TAM; taban +1606 hepsi gecti: ${WF}/baseline-live.txt -> tabanda gecen HICBIR test kirilmamali; bizim yeni testlerimiz de gecmeli; sayilari kaydet). Kirilan/yuklenmeyen test olursa kok nedeni bul; bizim kodun hatasiysa duzelt (ayni duzeltmeyi INTEG'e de yansit: INTEG ile LIVE'daki bizim dosyalar BIREBIR ayni kalmali; fark varsa raporla).
4. Rapor ${WF}/RB-rapor.md ve birlestirme notlari ${WF}/RB-merge-notlari.md (hangi dosyada hangi catisma nasil cozuldu; LIVE_BASE'e gore tum farklarin listesi: diff -rq -x .dart_tool -x build LIVE_BASE LIVE).
`

const RR3 = COMMON + `
SEN BAGIMSIZ BIR ELESTIRMENSIN (adversarial): entegre durumu (LIVE) CURUTMEYE calis. Dosya DEGISTIRME (yalniz ${WF}/RR3-rapor.md ve WF altindaki gecici kopyalar). Yalnizca KOD ALINTILI KANITLA bulgu bildir; tahmin/stil yazma; kritik/yuksek bulgulari calistirarak kanitla (gecici kopyada). Farklar: diff -ru -x .dart_tool -x build ${LIVE_BASE} ${LIVE} (TUM entegrasyon). RB raporu: ${WF}/RB-rapor.md, RB-merge-notlari.md; duzeltme raporlari FXC-rapor.md, FXU-rapor.md.
Odak: (a) entegrasyon noktalari: app_shell hunk (canli dosyaya dogru birlesti mi: Provider kapsami, dispose sirasi, builder zinciri CircuitBackground ile), ayar karti 2 satir (saglayici yokken cokmeme), automation_state kancasi (logout() zamanlamasi; E2'nin 'Hesap silme' akisi gibi baska cikis yollari: hesap silme/oturum kapatma/servis oturumu girisi push belirtecini nasil etkiliyor?), pubspec; (b) FXC/FXU duzeltmeleri gercekten kapatti mi: RR1-01 (biyometrik kilit: gercek AuthStatus gecisleri), RR1-02 (eski closeAllOpenLights imzasi/govdesi + canli E1 sahteleri), RR1-04, RR1-08, RR2-01/02/03/04/05 - her biri icin previousFindingsStatus; yeni regresyon var mi (F1 regresyonu RR1-01 gibi); (c) TAM test paketini KENDIN calistir (LIVE'in gecici kopyasinda: flutter test) ve tabanla (${WF}/baseline-live.txt) karsilastir; (d) canli E1/E2 yuzeyleriyle etkilesim: panodaki mevcut 'Huzur Modu' bandi (lib/ui/dashboard/peace_banner.dart) + CloseAllLightsButton + yeni afis birlikte; AppShell testleri; biyometrik/lifecycle testleri; (e) gizlilik/guvenlik: log, belirtec/ev adi/ozet sizmasi; FCM data'nin guvenilmeyen girdi muamelesi; (f) yama paketi icin uyari: hangi dosyalar canli ve hareketli (E1/E2/F), satir sonlari (CRLF/LF), birlestirme riski.
`

const D1 = COMMON + `
GOREVIN: D1 - BELGELER (yalniz duz yazi; .txt disa aktarimi G1 yapacak). Yazma izni YALNIZ ${DOCS}/wp-h-flutter/ altinda .md dosyalari (_wf ve yamalar dizinlerine DOKUNMA). RB henuz bitti (rapor ${WF}/RB-rapor.md); once bunu, ${WF}/FXC-rapor.md, FXU-rapor.md, F2-rapor.md, F3-rapor.md, A1-A3, R1-R3, RR1, RR2 raporlarini ve LIVE'daki GERCEK kodu OKU; belgeyi GERCEK koda gore yaz (uydurma/varsayim YOK; her somut iddia kodda dogrulanabilir olmali).
1. ENTEGRASYON.md'yi son mimariye gore BASTAN YAZ (kisa, uygulayiciya yonelik, sirali): kabuk tabanli baglanti (PeaceNoticeController + PeaceNoticeHost koprusu + AppShell hunk'i; afis=MaterialBanner, sonuc=SnackBar), AutomationState'e yalniz cikis kancasi (addBeforeLogoutHook; logout() icinde, 1 sn tavan, arka planda tamamlanir), pubspec hunk'i AYRI ve kullanici onayina bagli, CloseAllResult/PeaceNotificationSettings v2, includeShutters kurali (eski pano dugmesi closeAllOpenLights: include_shutters:false; afis closeAllForNotice: panjur varsa true), ayar kartina 2 satir, Android (kanal 'peace_reminder' + kucuk simge + manifest meta-data), iOS (Info.plist, AppDelegate, bridging header; Xcode capability elle), .gitignore, yama uygulama SIRASI/komutlari (G1'in yamalar/README.md'si ile tutarli; satir sonu notu: git apply --ignore-whitespace ve elle birlestirme), dogrulama (otomatik komutlar ve SAYILAR: RB raporundan; elle gercek cihaz listesi), BILINEN SINIRLAR (durust): cevrimdisi cikista deleteToken basarisiz olabilir ve kalici yeniden deneme yok (RR1-05); bayat ev listesinde yeni evin bildirimi kaybolabilir (RR1-03); logoutAll sonrasi sunucu DELETE belirtecsiz (401) - sunucu onerisi: logout-all'da push.disableAllTokensForUser (A sahibine istek); eklenti bildirim icerigini SharedPreferences'ta saklar (R3-07); Windows derlemesinde firebase_core C++ SDK indirmesi (R3-05) ve tabanda Windows zaten kirik; LAN modunda push (B6); kapatilan afisin geri gelmesi (B7); banner icerik yazi olcegi 1.5 siniri (RR2-06); panodaki eski 'Huzur Modu' bandi ile ikili yuzey (RR2-08); iOS derlenmedi; gercek FCM/APNs/cihaz denenmedi.
2. PUSH_KURULUM.md: R3-08/R3-03 duzeltmeleri (WF/R3-rapor.md); FCM API anahtari KISITLAMA adimi (Google Cloud Console > API'ler ve Hizmetler > Kimlik bilgileri: Android uygulamasi kisiti paket adi + SHA-1, API kisiti: Firebase Cloud Messaging API / FCM Registration API; dart-define ile APK'ya gomulen anahtar sir degildir ama kisitlanmalidir); Windows notu; kucuk simge; bolum numaralari tutarli; FCM_SERVICE_ACCOUNT_JSON secenegi YOK (yalniz dosya yolu): koru.
3. README.md: guncel durum, dogrulama sonuclari, yama dosyasi listesi ve sirasi (G1 yazinca tutarlilik icin yer tutucu birak: 'yamalar/README.md bkz.').
Rapor: ${WF}/D1-rapor.md.
`

// ---------------------------------------------------------------------------------------------
phase('Duzelt')
log('FXC (cekirdek) ve FXU (arayuz) paralel basliyor')
const pc = agent(FXC, { label: 'FXC cekirdek delta', phase: 'Duzelt', schema: RESULT, effort: 'high' })
const pu = agent(FXU, { label: 'FXU arayuz delta', phase: 'Duzelt', schema: RESULT, effort: 'high' })
const fxc = await pc
const fxu = await pu

phase('Entegre')
let rb = null
if (!fxc || !fxu) {
  log('FXC veya FXU basarisiz: entegrasyon atlandi')
} else {
  rb = await agent(RB, { label: 'RB canli agaca entegre + TAM dogrulama', phase: 'Entegre', schema: RESULT, effort: 'high' })
}

phase('Incele')
let rr3 = null
let d1 = null
if (rb) {
  const p3 = agent(RR3, { label: 'RR3 entegre durum incelemesi', phase: 'Incele', schema: FINDINGS, effort: 'high' })
  const pd = agent(D1, { label: 'D1 belgeler', phase: 'Incele', schema: RESULT, effort: 'medium' })
  rr3 = await p3
  d1 = await pd
}
const counts = { critical: 0, high: 0, medium: 0, low: 0 }
if (rr3) for (const f of rr3.findings) counts[f.severity] += 1
log('RR3 bulgulari: ' + JSON.stringify(counts))
return { fxc, fxu, rb, rr3, d1, counts }
