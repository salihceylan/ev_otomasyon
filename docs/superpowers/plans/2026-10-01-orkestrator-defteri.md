# Orkestratör defteri (2026-10-01) — kaldığı yerden devam için

> Amaç: bağlam/kota kesintisinde işin nerede kaldığını tek yerde tutmak. Sır DEĞERİ yazılmaz. Plan: `2026-10-01-denetim-duzeltmeleri.md`; sözleşme: `docs/CONTRACTS.md`.

## 1. Durum özeti (≈23:00)

Kanıtlı son durum (kapanış öncesi anlık kopya, 22:37): `flutter analyze` 0 sorun, `flutter test` 1606 geçti, `server npm test` 1559 test / 0 kırık, `tools/qa_stack npm test` 296 geçti, firmware `pio run` BAŞARILI (RAM %17,0 / Flash %37,3), Python fabrika aracı 312 test. Donanımda/gerçek EMQX'te/iOS'ta DOĞRULANMADI.

Biten paketler: A, B, C, FW-core (F12 dahil), FW-net (N6 + W1 AP-kaynak yetkisi + gömülü sayfa), D, E1, Q (QA yığını), G (+G3 etiket 2. karekod), H sunucu tarafı (başka oturum).

## 2. Çalışan işler (ID = alt ajan)

| İş | ID / çalıştırma | Çıktı |
|---|---|---|
| Kapanış Workflow'u `wf_bcf93c6f-0af` (script: `~/.claude/projects/G--site-ev-otomasyon/<oturum>/workflows/scripts/wave2-closeout-wf_bcf93c6f-0af.js`) | Audit ✔ → Fix: E2 `a13f4af9acca39ad8`, F `a7e4725b49630fad2` → Integrate (henüz başlamadı) | Fix: denetim boşlukları + Wi-Fi servis akışı (W2). Integrate: analyze/test/APK/Windows/web/firmware + sözleşme uyumu |
| WP-S sunucu birikmiş işler | `a69ff4256eecb9346` — BİTTİ (server npm test 1636/1554 geçti/0 kırık; gerçek PG'de 1635 geçti; CONTRACTS+RUNBOOK işlendi; plan §5d madde 1,3,5 tamam) | Açık kararlar: refresh `reuse_detected` push belirtecini kapatmıyor; `create_super_user.js` parola sıfırlaması belirteç kapatmıyor; acil sıfırlamada pano çevrimdışıysa çocuk kilidi niyeti NULL'lanıyor (düşük öncelik) |
| QSYNC QA simülatörü senkronu | `a0178f7d98fa8e39b` | `fwcheck` yeşil, AP-kaynaklı yetki (`/__sim/client-net`), QA_STACK.md güncel |

Integrate başlayınca ajanına İLET (SendMessage): (a) QA sim senkronu QSYNC'te; yalnız sonunda `npm test` + `fwcheck` koş, `tools/qa_stack/sim/**`'e yazma; (b) `docs/FLUTTER_API_CHANGES.md` §8.2/§8.4'ü W2 sonuçlarına göre güncelle (`GET /api/wifi/status`, AP-kaynaklı anahtarsız erişim, 429 `rate_limited`); (c) AuthStatus'a yeni değer eklenmediğini doğrula; (d) `ahbu1234`/`AHBU-Kurtarma` yalnız olumsuz testlerde kalmalı.

## 3. Diğer oturumla (peer `site-kapi-kontrol-5a`, WP-H Flutter push/gece hatırlatması) protokol

- Peer yamayı KOPYADA doğrular (≈2–2,5 sa). Ben "kapanış entegrasyonu yeşil, snapshot hazır (saat)" yazınca taze kopyadan yeniden birleştirir.
- Dalga 4 TARAMA aşaması `lib/**`, `android/**`, `ios/**`, `pubspec.yaml`'a YAZMAZ. Tarama bitince ve ilk düzeltme turundan ÖNCE peer'e "şimdi uygula" yazılır → peer doğrulanmış yamayı gerçek ağaca uygular (≈15–30 dk), "kilit açıldı" yazar → sonra lib/** düzeltmeleri.
- Firebase paketleri (pubspec firebase hunk'ı + FirebasePushGateway + iOS AppDelegate) AYRI yama (`02-firebase`); kullanıcı onayı olmadan UYGULANMAZ. Firebase'siz kısım (arayüz + "yapılandırılmadı" no-op + denetleyici + afiş + ayar + Android kanal) tek başına derlenmeli.
- AuthStatus enum'una YENİ değer EKLENMEZ (peer denetleyicisi `checking`'i "kilitli, oturum bitmedi" sayar).
- Ortak kaynaklar: emulator-5554/AVD'ler ve portlar 5000, 1883, 18083, 54329, 8081–8083, 18090 BENİM (Dalga 4); peer derlemeleri kopyada, Gradle/AVD'ye dokunmaz.

## 3b. KULLANICI KARARI (gece): emülatör/Chrome/ekran gezme QA'sı İPTAL

Kullanıcı Dalga 4'ü (emülatör/Chrome/Windows'ta deneme, menü gezme, monkey) iptal etti: "deneme işlerini bana bırak; kodları doğru yazdığına ve derleme hatası almadığına emin olduktan sonra bana ver". Dalga 4 çalıştırılMAYACAK (taslak scratchpad/wave4-qa-scan.js kullanılmaz). QSYNC ajanı yarıda durduruldu: `tools/qa_stack` yarım kalmış olabilir (ürün kodu değil; Integrate'te qa_stack testi/fwcheck KOŞMA, yalnız rapora "yarım" yaz). Kalan kapı: analyze + test + APK/web/Windows DERLEME + firmware pio run. Sonra Dalga 5 (akıcılık/görsel cila; yalnız kod+birim/widget testi, cihazda çalıştırma yok) ve v1.1.0 firmware imajı. Peer'e "snapshot hazır" → doğrulama → "şimdi uygula".

Peer'in aktardığına göre (kullanıcıdan): Firebase EKLENMEYECEK; bildirim yalnız uygulama açıkken/açılınca (sunucu `last_notice` yedek afişi). Firebase onayı sorulmayacak; yama 02-firebase çıkarıldı, pubspec'e yalnız `fake_async` (dev) eklenecek.

## 3c. Gece notları (00:00)

- Workflow `wll8rqddw`'e/Fix ajanlarına SendMessage göndermek ajanı AYRIŞTIRIYOR (E2'nin ikiz kopyası oluştu; E2 raporu SubagentHandback ile geldi, workflow journal'ında 'result' YOK). Bir daha workflow ajanlarına mesaj ATMA. İki Fix raporu (E2 ikiz + F) gelince journal'da ilerleme yoksa workflow'u TaskStop et ve `scratchpad/wave2-integrate.js` ile entegrasyonu yeniden başlat (Gate: Flutter/server/firmware paralel → Build: APK debug+release, web, Windows → Critic). İlerleme varsa (Entegrasyon başladıysa) ona dokunma.
- Entegrasyon yeşil → peer'e "snapshot hazır" yaz (kullanıcı da "snapshot hazır mı" diye sordu).
- YENİ KULLANICI İSTEĞİ: Android'de mobil veri açıkken 192.168.4.1 trafiğinin hücreselden gitmesini önleyen platform kodu. Script hazır: `scratchpad/android-board-network.js` (Implement [Kotlin+Dart paralel, kanal sözleşmesi `ev_otomasyon/board_network`] → 3 mercekli inceleme → düzeltme → derleme doğrulaması). Entegrasyon/snapshot SONRASI çalıştır; MainActivity.kt + AndroidManifest.xml'e eklenen satırları peer'e bildir (onun yamasıyla çakışabilir).

## 3d. Durum (02:55, 2 Ekim)

- Kapanış entegrasyonu YEŞİL (analyze 0, test 1911, server 1636/1636 gerçek PG, qa_stack 384, py 312, APK debug+Windows debug+web DERLENDİ, firmware OK). Peer'in WP-H yaması (Firebase'siz) gerçek ağaca UYGULANDI (02:46–02:50): analyze 0, test +2641; kilit açıldı. Ağaç yine bizim.
- Firmware v1.1.0 sürüm imajı ÜRETİLDİ + bağımsız doğrulandı (72 kontrol): `ev_otomasyon_servis_yazilimi/waveshare_s3_demo/firmware_releases/v1.1.0/` (firmware_combined_0x0.bin, app_0x10000_v1.1.0.bin, SHA256SUMS.txt, SURUM_NOTLARI.md), version_info.json 1.1.0'a güncel; v1.0.x `KULLANILMAZ.txt`. Donanımda DOĞRULANMADI; bootloader v1.0.1'inkinden farklı: ilk kartta açılış doğrulanmalı.
- Çalışan: (1) Android mobil-veri bağlama `wf_8d3a474d-c14` (Fix aşamasında; incelemede kritik/yüksek yok); (2) Dalga 5a ön hazırlık `wf_d040f850-4e4` (Plan/sentez aşamasında; çıktı `docs/superpowers/analysis/akicilik-guncel.md`).
- HAZIR script'ler (`G:/site/ev_otomasyon/build/workflow_scripts/`, gitignored): `docs-refresh.js` (canlı test listesi Aşama 1–19 kodla yeniden yazım + yeni aşamalar + docs/DENEME_REHBERI.md; bağımsız doğrulama), `wave2-integrate.js` (kapı şablonu), `android-board-network.js`, `wave5a-reaudit.js`, `firmware-release.js`.
- SIRA: binding Fix biter → son kapı (analyze/test/APK/Windows/web/server) → kullanıcıya "deneyebilirsiniz" (kendi duyurum) → docs-refresh → Dalga 5a (kod-only akıcılık; plan akicilik-guncel.md) → (isteğe bağlı) 5b görsel. Dağıtım BLOKE (SSH). CONTRACTS'a WP-H istemci notu + WP-NET düzeltmeleri binding Fix bitince eklenecek.

## 3e. Durum (05:00, 2 Ekim) — KULLANICIYA "DENEYEBİLİRSİNİZ" DENDİ

- ANA AĞAÇ (`G:\site\ev_otomasyon`) = kullanıcının deneme ağacı; son kapı YEŞİL (analyze 0, test +2643; peer'in mustChangePassword düzeltmesiyle +2650; APK debug+release, web, Windows debug, Kotlin JVM 72/72). Bu ağaçta artık YALNIZ belge düzeltmeleri ve kullanıcı hata bildirimleri için küçük düzeltmeler yapılır; büyük lib/ değişikliği YAPMA.
- GELİŞTİRME KOPYASI: `G:\site\ev_otomasyon_dev` (04:53 anlık kopya; kendi git deposu: base commit `e3fb350`; baseline test +2635 ~8). Dalga 5a (akıcılık) workflow'u `wf_c2bd2791-4fc` BURADA çalışır (9 paket; Wave1 INFRA/BOOT/SETUP/SVC-PAGES → Wave2 NET/UI-DIALOGS/CLOUD-API/STATE → Wave3 DASH → Review → Fix → Gate). Bitince `git diff e3fb350` ile yama üret; ana ağaca ANCAK kullanıcı onayıyla ve `git apply --check` + tam kapı sonrası uygula (ana ağaçta peer'in peace_notice_controller düzeltmesi vb. var; dev tabanında yok: çakışmaz).
- docs-refresh (`wf_201efb76-ab0`) Fix aşamasında: kontrol listesi + docs/DENEME_REHBERI.md. Bitince son bütünlük eleştirmeninin belge bulgularını (rehber §5.4, §7 'Bilinen sınırlar': Windows MQTT TCP, web'de MQTT yok, release'te dart-define yok sayılır, push/Firebase yok; Android NSC dart:io'yu kısıtlamaz) rehberde kontrol et.
- Not: temp'te 4,4 GB eski flutter_tools.* silindi, C: ~9,5 GB boş.
- Açık kullanıcı kararları: pubspec'teki kullanılmayan dev `integration_test` bağımlılığı kalsın mı; sırların döndürülmesi; dağıtım erişimi; v1.1.0 ilk kartta açılış doğrulaması.

## 4. Sıradaki adımlar (Dalga 4 maddeleri artık YOK)

1. Kapanış Workflow'u biter → raporları oku (Fix E2/F, Integrate); yeşil değilse hedefli düzeltme ajanı.
2. Peer'e "snapshot hazır" yaz.
3. **Dalga 4 tarama Workflow'u**: taslak `scratchpad/wave4-qa-scan.js` (Setup → 6 tarayıcı [persona A/B, senaryo A/B, başsız profil, masaüstü/web/iOS/Python] → Triage). Sonuç: `docs/qa/triage.{md,json}`.
4. Peer'e "şimdi uygula" (WP-H yaması penceresi) → "kilit açıldı" bekle.
5. **Dalga 4b düzeltme + yeniden tarama** (triage gruplarına göre, dosya sahipliği ayrık; loop-until-dry: 2 ardışık temiz tur) → `docs/QA_RAPORU.md`.
6. **Dalga 5** akıcılık/kilitlenmeme/görsel cila: girdiler `docs/superpowers/analysis/{akicilik-denetimi,gorsel-denetim,onizleme-yontemi}.md`, `tool/preview/` önizleme düzeneği; bütçeler plan §5c; bağımsız tasarım eleştirmenleri; son QA kapısı (monkey + integration_test + analyze + test).
7. **Yeni firmware sürüm imajı v1.1.0** (birleşik 0x0 imaj, `FACTORYINIT` + `Kurulum modu (AP)` dizgisi doğrulanır; eski v1.0.x "kullanılmaz" notu) — firmware işleri tamam, QA'dan sonra.
8. Dağıtım (BLOKE, aşağıya bak) ve son rapor.

## 5. Kullanıcıya sorulacaklar / bildirilecekler (iş sonunda)

- **Dağıtım erişimi:** verilen `gudeteknoloji` hesabına parolayla girilemedi (3 deneme, sonra durdum; kilitlenme riski). Hafızadaki kayda göre sunucu paylaşımlı (`kapi-api`, `ev-api`, `teklif-pro-api`, `dijitarla`) ve giriş ANAHTARLA (parola yok; başka bir oturum `salihceylan` hesabıyla anahtarla bağlandı). Parola reddi büyük olasılıkla `PasswordAuthentication no` yüzünden. İzin sorusu: bu makinedeki mevcut anahtarla `ev-api` için SALT-OKUNUR keşif başlatayım mı (üretimdeki kapı sistemine dokunmadan)? Aksi halde `ssh-ed25519 …claude-ev-otomasyon-dagitim` genel anahtarı `authorized_keys`'e eklenmeli.
- **Sırlar:** sohbette/depoda görünen SSH parolası ve repodaki tüm sırlar döndürülmeli (`docs/SECRET_ROTATION.md`).
- **Firebase:** push için `firebase_core/firebase_messaging` paketleri + `google-services.json`/`GoogleService-Info.plist` eklensin mi (WP-H)?
- **Ürün kararları:** çocuk kilidinde duvar anahtarı hareketteki panjuru durdurabilsin (uygulandı: evet); gece hatırlatması varsayılan açık (şu an açık).
- **Depo hijyeni:** `Arduino/examples/**`, `Firmware/`, `*.zip` satıcı demo sabitleri; `ev_otomasyon_servis_yazilimi/labels/AHBU-S3-DD8754_label.png` eski PIN/QR içeriyor (git dışı) — silme önerilir.
- **Doğrulanmadı listesi:** gerçek ESP32/röle/panjur/TLS/OTA, SoftAP istemci algısı ve telefon davranışı, iOS (Windows'ta derlenemez), FCM/APNs, gerçek EMQX.
- **Ortam:** C: diskinde az yer vardı (6 GB); yapı çıktıları G: altında tutuldu; Windows derlemesi `local_auth_windows` STL1011 nedeniyle taban çizgisinde kırık olabilir (Dalga 4'te araştırılıyor).
