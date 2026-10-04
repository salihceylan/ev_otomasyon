# AHBU Neon Glass — görsel/etkileşim tasarım şartnamesi (v2)

> Kaynak: kullanıcı talebi (2026-10-02): "modern, premium, etkileşimli; panjur aç butonu standart buton olmasın, yuvarlak parlatılmış, belki animasyonlu; bunu tüm yapılara uyarla; çok zengin, dikkat çekici, canlı; akışlar hızlı, gecikmesiz; animasyonlu yapıları modern diye yorumla".
> Bu belge TEK doğruluk kaynağıdır (tasarım belirteçleri, bileşen şartnameleri, hareket/performans/erişilebilirlik kuralları, korunacak sözleşmeler). Ham girdiler: `gorsel-denetim.md` (eski denetim; yön önerisi "Quiet Premium" bu şartnameyle DEĞİŞTİRİLDİ: kullanıcı canlı/dikkat çekici istiyor), `akicilik-guncel.md` §11 (pinli test/metin sözleşmeleri), `onizleme-yontemi.md`.

## 1. Yön

**"Neon Glass":** derin lacivert/grafit zemin (marka devre kartı kimliği KALIR), üstünde **camsı kartlar** (kenar ışığı + yumuşak gölge, `BackdropFilter` YOK) ve **parlak, dışbükey "orb" kontroller** (radyal gradyan gövde + speküler vurgu + renkli parıltı). Koyu tema birinci sınıf, açık tema eşit kalitede (parıltı yerine renkli gölge). Her kontrolün **anlamsal rengi** vardır; her durum değişimi **hareketle** anlatılır; hareket ASLA komutu geciktirmez.

İmza öğeler: (1) orb düğmeler (panjur Aç/Durdur/Kapat, lamba güç orb'u, senaryo orb'ları, üst çubuk cam orb'ları), (2) canlı **panjur penceresi** (çıta animasyonu), (3) nefes alan lamba parıltısı, (4) akıcı sayfa geçişi (fade-through), (5) iskelet (skeleton) yükleme, (6) giriş koreografisi (kademeli belirme), (7) sayaç animasyonları.

## 2. Belirteçler (tek kaynak: `lib/ui/theme/tokens.dart`, `AppTheme` yardımcıları buna bağlanır)

### 2.1 Renk aileleri (orb/parıltı için; her aile: `light`, `base`, `deep`, `glow`)

| Aile | base | light | deep | Anlam |
|---|---|---|---|---|
| amber | #FFB020 | #FFD36B | #E07A00 | lamba AÇIK, uyarı, çocuk kilidi |
| emerald | #10B981 | #6EE7B7 | #047857 | panjur AÇ, başarı, bağlı |
| sky | #3B82F6 | #93C5FD | #1D4ED8 | panjur KAPAT, birincil eylem |
| rose | #F43F5E | #FDA4AF | #BE123C | DURDUR, tehlike, hata |
| violet | #A855F7 | #D8B4FE | #7E22CE | gece senaryosu, ek modül rozeti |
| cyan | #22D3EE | #A5F3FC | #0E7490 | marka/teknoloji vurgusu, odak halkası |
| slate | #64748B | #CBD5E1 | #334155 | nötr/pasif |

Mevcut `AppTheme.accent*`/`primary*` sabitleri KALIR (geriye uyum); yeni bileşenler aileleri kullanır. Metin/simge olarak vurgu kullanılacaksa mevcut `AppTheme.readableAccent` (AA kontrast) kullanılır.

### 2.2 Zemin ve yüzeyler (koyu)
`bg` #0B1120 (mevcut) · kart gövdesi: dikey gradyan `#1B2740` → `#141E33` (opak) · yükseltilmiş/basılı `#223253` · **kenar ışığı (rim)**: 1 px, sol-üstten sağ-alta `white@0.18 → white@0.02` · çevresel gölge: `black@0.40`, blur 22, y+10 · vurgulu kartta (aktif): kenar `accent@0.55` 1.4 px + `accent@0.14` yarıçap-gradyan parıltı (BoxShadow YOK; bkz. §4).
Açık tema: kart #FFFFFF → #F6F8FC gradyan, rim `#0B1016@0.08`, gölge `#101820@0.14` blur 18 y+8; orb gölgesi `accent@0.30` blur 14 y+6.

### 2.3 Şekil/boşluk/boyut
Yarıçap: 8 / 12 / 16 / **20 (kart)** / 28 (sheet) / 999 (pill-orb). Boşluk (4'lü ızgara): 4, 8, 12, 16, 20, 24, 32. Orb boyutları: `xl` 76 · `lg` 64 · `md` 52 · `sm` 44 (görsel çap; dokunma alanı HER ZAMAN ≥ 48 dp). Yazı: minimum 12 sp; kart başlığı 14.5–15/700; sayaç 28–32/800 (tabular rakam: `FontFeature.tabularFigures()`).

### 2.4 Hareket belirteçleri (`lib/ui/motion/motion.dart`)
Süreler: `instant` 90 ms · `fast` 140 · `base` 220 · `slow` 320 · `hero` 480. Eğriler: varsayılan `Curves.easeOutCubic`; yaylanma `SpringCurve(damping: 0.72)` (basma-bırakma, açılma); `Curves.linear` YALNIZ motor hareketi/ilerleme. Kademe aralığı 40–45 ms/öğe (en çok 8 öğe). Sayfa geçişi ≤ 280 ms.

## 3. Bileşen şartnameleri

### 3.1 `OrbButton` / `OrbToggle` / `OrbIconBadge` / `GlassIconButton` (`lib/ui/widgets/orb/`)
Katmanlar (alttan üste): ① dış parıltı (aktifken; `RadialGradient`, BoxShadow blur YOK) ② gövde: `RadialGradient(center: Alignment(-0.35,-0.45), radius 1.05, [light, base, deep], stops [0, .55, 1])` ③ alt iç gölge (alt %35 yay, `black@0.25 → 0`) ④ **speküler vurgu**: üst bölgede elips (genişlik 0.62 d, yükseklik 0.34 d, üstten 0.10 d), `white@0.62 → 0` dikey gradyan ⑤ kenar ışığı: 1.5 px halka `white@0.7 (sol-üst) → white@0.05 (sağ-alt)` ⑥ simge (beyaz/koyu mürekkep, çap 0.44 d, hafif gölge).
Durumlar: **idle** (parıltı soluk) · **pressed** (parmak değdiği AN ölçek 0.92, vurgu azalır; bırakınca yaylanma 1.0 → 1.04 → 1.0) · **active/hareketli** (parıltı nefes alır, §4) · **pending** (halka çevresinde dönen yay ≤ 2.5 s; komut hattının bekleyen durumuna bağlı) · **success** (tek seferlik genişleyen halka 450 ms) · **error/rollback** (2 kare 3 px sarsıntı + rose flaş) · **disabled** (doygunluk düşük, parıltı yok, ≥ 3:1 kenar). `OrbToggle`: `toggled` anlamsal; açık/kapalı geçişi `slow` yaylanma. `OrbIconBadge`: etkileşimsiz küçük orb (kart başlıkları, senaryo). `GlassIconButton`: cam disk (kart gradyanı + rim) üst çubuk eylemleri için, 44 görsel / 48 hedef, rozet noktası desteği.
**Komut ile ilişki:** dokunuş görseli iletimden önce ANINDA (aynı kare) değişir; hiçbir animasyon `onTap`'i geciktirmez/kuyruklamaz/AbsorbPointer yapmaz; çift dokunuş korumasını mevcut `CommandPipeline` sağlar (animasyon değil).

### 3.2 `SurfaceCard` ve `AppTheme.cardDecoration` yükseltmesi
`AppTheme.cardDecoration(context, accent:, emphasized:, radius:)` imzası KALIR (60+ çağrı); içi §2.2 camsı yüzeyi çizer → TÜM kartlar tek noktadan yükselir. Yeni `SurfaceCard` (child + `accent` + `active` + `onTap` + `Pressable`) kart bileşenlerinde kullanılır. Her animasyonlu/parıltılı kart `RepaintBoundary` içindedir.

### 3.3 Hareket yardımcıları
`MotionScope` (§4) · `Pressable` (ölçek geri bildirimi) · `AnimatedCount` (sayı/yüzde tween; testte anında son değer) · `StaggeredEntrance(index)` (fade + 12 dp kayma, tek sefer) · `Skeleton`/`SkeletonCard` (tek paylaşılan süpürme; 12 sn zaman aşımında durur) · `PulseRing` (tek seferlik halka) · `GlowDot` (canlı durum noktası) · `FadeThroughPageTransitionsBuilder` (giden sayfa ilk %35'te solar, gelen sonraki %65'te belirir: saydam scaffold hayalet görüntüsü YOK; ≤ 280 ms; tüm platformlar `ThemeData.pageTransitionsTheme`'e).

### 3.4 Panjur kartı v2 (`shutter_card.dart` + yeni `shutter_visual.dart`)
Sol: **ShutterVisual** 64×72 pencere (çerçeve r10, cam gradyanı #1E3A5F → #0F172A, 9 çıta; kapalı oran = (100−pos)/100 yukarıdan aşağı; alt rayda parlak çizgi). Hareket sırasında konum, ardışık raporlar arasında **lineer tween** ile sürekli akar (raporlar ~1 sn aralıkla gelir; tween süresi = ölçülen aralık, en çok 1.2 s; hedefe ulaşınca durur). Orta: `AnimatedCount` yüzde (28/800) + durum metni ("Durdu / Açılıyor… / Kapanıyor… / Uygulanıyor…" AYNEN) + hedef. Alt: **3 orb**: Aç (emerald, ▲), Durdur (rose, ■), Kapat (sky, ▼), altlarında 12.5 sp başlık ("Aç", "Durdur", "Kapat" AYNEN); hareket yönündeki orb "active" (nefes + çevik şerit/chevron animasyonu, §4). Altında `Slider` (tür KALIR, `Key('slider_shutter_<pair>')`): özel parlak iz (dolu kısım gradyan) + orb başparmak (özel `SliderComponentShape`); sürükleme canlı olarak ShutterVisual'i günceller.
Anahtarlar AYNEN: `card_shutter_<pair>`, `btn_shutter_up_/stop_/down_<pair>`, `slider_shutter_<pair>`.

### 3.5 Lamba/röle kartı v2 (`relay_switch_card.dart`)
Sol: **güç orb'u** 56 (`OrbToggle`, `Key('switch_relay_<id>')`): KAPALI = koyu cam orb, soluk ampul çizgisi; AÇIK = amber orb, dolu ampul + akkor parıltısı, kartın arkasında amber **radyal bloom**; açılışta orb 1.0→1.08→1.0 yaylanır. Orta: ad (2 satır), durum metni ("AÇIK/KAPALI/Darbe çıkışı/Uygulanıyor…" AYNEN), çevrimdışı notu. Sağ: kilit/CH rozeti. Darbe rölesi: bolt orb (`Key('btn_relay_impulse_<id>')`, metin "Tetikle" AYNEN), basınca tek seferlik halka. Kartın tamamı dokunuşla aç/kapat (`Key('card_relay_<id>')` InkWell davranışı korunur). Anlamsal: `toggled`.

### 3.6 Senaryo kutucukları v2 (`quick_scenario_bar.dart`)
156×~124 cam kutucuk: üstte 44 `OrbIconBadge` (senaryo rengi), başlık + alt başlık AYNEN. Çalışırken orb çevresinde dönen yay (`pending`), kutucuk hafif parlar; başarıda simge ✓'e dönüşür (≤ 900 ms, sonra geri). `Key('card_scenario_<id>')` KALIR; yalnız ilk hatada durma/çift dokunuş koruması KALIR.

### 3.7 Durum şeridi ve kabuk
`StatusPill` v2: cam hap, solda `GlowDot`/mini orb; değer değişiminde `AnimatedCount`; bağlantı noktası "bağlanıyor"da 3 nabız sonra sabit, "çevrimdışı"da kesik simge + metin (renk TEK ipucu değil). Üst çubuk eylemleri `GlassIconButton`. Yönetici/sakin panosunun başına **`HomeHero`** (isteğe bağlı P1): ev adı + ev silüeti (CustomPainter; pencere sayısı açık lambaya göre yanar, çatı marka camgöbeği) + büyük sayaçlar; mevcut metinleri ÇİFTLEMEZ. Boş/hata/yükleme: skeleton + anlamlı hata kartı (spinner'sız).

### 3.8 Birincil düğme (form/CTA)
`ElevatedButton` TÜRÜ KALIR (testler `find.widgetWithText(ElevatedButton, ...)` kullanır): `ThemeData.elevatedButtonTheme` `ButtonStyle.backgroundBuilder` ile sky→cyan gradyan, stadium şekil, min yükseklik 52, rim ışığı, renkli gölge; basınçta ölçek/overlay. `FilledButton`/`OutlinedButton`/`TextButton`/`ChoiceChip`/`SnackBar`/`BottomSheet` temaları aynı dile hizalanır.

## 4. Hareket ve performans kuralları (SERT)

1. **`MotionScope`**: `MotionMode.off` (VARSAYILAN: kapsam yoksa) → süre 0, tween yok, döngü yok → mevcut testler/pumpAndSettle etkilenmez; `MotionMode.full` yalnız `lib/main.dart`'ta `runApp` sarmalayıcısıyla verilir (EvOtomasyonApp'i doğrudan pompalayan testler `off` görür). `MediaQuery.disableAnimations` ⇒ `off` gibi davranır. Golden/animasyon testleri `MotionScope(mode: full, ...)` ile açıkça sarar.
2. **Ambient (sonsuz) animasyon** yalnız `MotionMode.full` + uygulama ön planda + ilgili öğe görünür/aktif iken: **tek paylaşılan `AmbientClock`** (≈24 Hz, `Ticker`; dinleyici yoksa DURUR; arka plana geçince durur). Nefes/parıltı bu saatten türetilir. Aynı anda en çok **8** nefes alan parıltı (`tryAcquireSlot`); fazlası statik. Golden için `AmbientClock.fixed(t)`.
3. **Animasyonlu parıltı `RadialGradient` ile çizilir; `MaskFilter.blur`/büyük `BoxShadow` blur'ı kare başına DEĞİŞTİRİLMEZ** (Skia/Android, Impeller kapalı). Statik gölgede blur ≤ 24. `BackdropFilter`, `saveLayer`, `Opacity` listede YASAK; yarı saydamlık için renk alfası kullan.
4. Her animasyonlu kart/orb `RepaintBoundary` içinde; ambient dinleyicisi `AnimatedBuilder`+küçük `CustomPainter` (kartın tamamını yeniden kurmaz). `context.select`/mevcut daraltma KORUNUR; bildirim başına tüm panoyu yeniden kuran kod EKLENMEZ.
5. **`Timer`/`Future.delayed` ile animasyon YASAK** (bekleyen zamanlayıcı testi bozar); gecikme `Interval` ile. Her `AnimationController` `dispose` edilir; sonlu animasyonlar `pumpAndSettle` ile biter.
6. **Metin değişiminde eski+yeni metin aynı anda ağaçta OLMAZ** (testler `find.text(...)`/`findsOneWidget` kullanır): `AnimatedSwitcher` kullanılacaksa `reverseDuration: Duration.zero`; ya da yalnız renk/ölçek animasyonu. `AnimatedCount` `off` modunda ara değer göstermez.
7. Hiçbir animasyon girdiyi/komutu bloklamaz; tüm uzun animasyonlar kesilebilir (yeni durum geldiğinde hedef güncellenir).
8. Süreler §2.4; dekoratif hareket 120–350 ms, imza hareketler ≤ 480 ms.

## 5. Erişilebilirlik
Kontrast: metin ≥ 4.5:1, büyük metin/UI bileşeni ≥ 3:1 (orb gövdesi üstündeki simge beyaz/koyu mürekkep seçimi hesapla; `AppTheme.contrastRatio`). Dokunma hedefi ≥ 48 dp. Yazı ölçeği 1.5 ve 2.0'da taşma yok (`Wrap`/`FittedBox`/esnek yükseklik; sabit yükseklik YOK). Renk tek ipucu değil (simge + metin). `Semantics` (button/toggled/liveRegion) KORUNUR; orb'lar yalnız görsel katmandır. `MediaQuery.disableAnimationsOf` ⇒ hareket kapalı. Haptik: `selectionClick` aç/kapat, `lightImpact` senaryo, `mediumImpact` durdur/yıkıcı onay.

## 6. KORUNACAK sözleşmeler (kırarsan testle birlikte BİLİNÇLİ güncelle + gerekçe)
`docs/superpowers/analysis/akicilik-guncel.md` §11 ve `gorsel-denetim.md` "Bozulmaması gerekenler": pinli metinler (`'Hepsini Kapat'` tam 1 widget, `'Çocuk Kilidi Aktif'`, `'Huzur Modu / Gece Kontrolü'`, panjur/lamba durum metinleri, `'Aç'/'Durdur'/'Kapat'`, `'Tetikle'`, senaryo başlıkları, `'Giriş Yap'` tam 1 …); Key sözleşmesi (`nav_/btn_/field_/setup_step_/card_/switch_/slider_/chip_`); `ElevatedButton` türü (giriş/kayıt/sıfırlama); DeviceSettingsPage'de ilk `Switch` çocuk kilidi; yönetici çekmecesinde tek `Scaffold`; eager-build sayfalar (DeviceSettingsPage, panolar) sanallaştırılmaz; `AuthStatus` değişmez; yeni pub.dev bağımlılığı YOK (animasyon yalnız Flutter yerleşikleri); `CommandPipeline` zamanlaması (2,5 sn geri alma) ve iyimser UI aynen. Yeni görsel öğeler mevcut `find.text` kalıplarını ÇİFTLEMEZ (yeni metin eklemeden önce `grep -rn "find.text('...')" test/`).

## 7. Doğrulama (cihazda çalıştırma YOK — kullanıcı kararı)
`flutter analyze` (0 sorun) · `flutter test` (tüm paket) · **golden render** (`test/visual/`, `@Tags(['visual'])`, varsayılan koşuda atlanır; gerçek yazı tipiyle PNG üretir: `flutter test --tags visual --update-goldens`) · `flutter build apk --debug`. Performans iddiaları ÖLÇÜLMEDİ olarak işaretlenir (yapısal kanıt: yeniden-çizim sayacı, RepaintBoundary, ambient bütçesi testleri). Görsel inceleme bağımsız eleştirmenlerce PNG'ler üzerinden yapılır (uygulayan kendi işini onaylamaz).
