# AHBU Neon Glass: bileşen API'si (WP-V0 FOUNDATION)

> Kaynak şartname: `gorsel-tasarim-v2.md` (TEK doğruluk kaynağı). Bu belge **kullanım kılavuzudur**: imzalar, parametreler, örnekler, tuzaklar. Kod: `lib/ui/theme/`, `lib/ui/motion/`, `lib/ui/widgets/orb/`, `lib/ui/widgets/surface_card.dart`. Testler: `test/ui/design/**` (+ `test/ui/neon_app_bar_test.dart`, `test/ui/feature_accent_usage_test.dart`). Görsel galeri: `test/visual/**` (PNG).

## 0. İçe aktarma

```dart
import 'package:ev_otomasyon/ui/theme/app_theme.dart';   // AppTheme (mevcut API + glassDecoration)
import 'package:ev_otomasyon/ui/theme/tokens.dart';      // AppFamilies, SurfaceTokens, AppRadius, AppSpace, OrbSize, AppMotion, SpringCurve, PressHaptic, wcagContrast
import 'package:ev_otomasyon/ui/motion/motion.dart';     // MotionScope, AmbientClock, Pressable, AnimatedCount, StaggeredEntrance, Skeleton, SkeletonCard, PulseRing, FadeThroughPageTransitionsBuilder (+ AppMotion/SpringCurve/PressHaptic yeniden dışa aktarım)
import 'package:ev_otomasyon/ui/widgets/orb/orb.dart';   // OrbButton, OrbToggle, OrbIconBadge, GlassIconButton, GlowDot, ProgressArc, OrbStatus, OrbColors, OrbPainter
import 'package:ev_otomasyon/ui/widgets/surface_card.dart'; // SurfaceCard
import 'package:ev_otomasyon/ui/theme/feature_accent.dart';  // AppFeature, featureFamily, FeatureGroups (§11)
import 'package:ev_otomasyon/ui/widgets/neon_app_bar.dart';  // NeonAppBar, NeonBarAction (§9)
import 'package:ev_otomasyon/ui/widgets/app_pill.dart';      // AppPill, AppChip, AppPillShell, AppPillTokens (§10)
import 'package:ev_otomasyon/ui/widgets/glass_pill.dart';    // GlassPill (AppPill sarmalayıcısı; user_profile_dialog.dart'tan da export edilir)
```

## 1. Hareket kipi (`MotionScope`) ve test kuralı

| | |
|---|---|
| `MotionScope(mode: MotionMode.full, clock: AmbientClock?, child: ...)` | `lib/main.dart`'ta `runApp(MotionScope(mode: full, child: await buildApp()))` ile BİR KEZ verilir. |
| `MotionScope.modeOf(ctx)` / `enabledOf(ctx)` / `durationOf(ctx, d)` / `clockOf(ctx)` | Kapsam yoksa **off**; `MediaQuery.disableAnimations` ⇒ **off**. |

* **Kapsamsız (mevcut) testler `off` görür**: süre 0, ara değer yok, döngü yok, `pumpAndSettle` takılmaz, bekleyen `Timer`/`Ticker` yok.
* **Yeni animasyon/golden testi** `MotionScope(mode: MotionMode.full, clock: AmbientClock.fixed(0.65), child: ...)` ile sarar (MaterialApp'in ÜSTÜNDE ya da içinde olabilir). `full` kipte etkin (`active`) bir orb VARSA `pumpAndSettle` biter DEĞİL (ambient saat çalışır): `pump(Duration)` kullanın ya da `AmbientClock.fixed` verin.
* `test/ui/design/design_support.dart`: `designHost(child, mode:, clock:, brightness:, disableAnimations:, textScale:)`, `effectiveOpacity`, `pressableScale`, `recordHaptics`, `guardedAppTheme`.

## 2. Belirteçler (`tokens.dart`)

* **Renk aileleri** `AppFamilies.{amber,emerald,sky,rose,violet,cyan,slate}` → `AccentFamily{light, base, deep, glow}` (§2.1 tablosu). Anlam: amber lamba açık/uyarı/çocuk kilidi · emerald panjur AÇ/başarı · sky panjur KAPAT/birincil · rose DURDUR/hata · violet gece/ek modül · cyan marka/odak · slate nötr. `AppFamilies.all` sabit sıralı liste.
* **Yüzey** `SurfaceTokens.of(Brightness)` → `cardTop/cardBottom/raised/rimStart/rimEnd/rimSolid/shadow/shadowBlur/shadowOffset/orbShadow*`. `AppGlass.accentRimAlpha(0.55)/accentRimWidth(1.4)/accentGlowAlpha(0.14)`.
* **Şekil/boşluk**: `AppRadius.{r8,r12,r16,card(20),dialog(24),sheet(28),pill(999)}` (iç kutu r12, kart içi kart/satır r16, kart 20, diyalog 24 — `AuthDialogShell.radius` = `AppRadius.dialog`, düğme/çip/rozet pill; 6/10/14 gibi ölçek dışı değer YOK), `AppSpace.{s4..s32}`, `AppTouch.minTarget(48)/minFontSize(12)`.
* **Yazı belirteçleri** `AppText.{badge 12, caption 12.5, body 14, cardTitle 15, title 18, metric 28}` (hepsi >= 12 sp; rozet/çip/istatistik etiketi/yardımcı metin 12'nin altına İNMEZ; `test/ui/design/v9_consistency_guard_test.dart` 12 sp altı sabit yazı boyutunu reddeder).
* **Cam/yüzey ek belirteçleri** `AppGlass.{accentGlowAlphaLight, accentTintAlphaDark/Light, orbGlowIdle/Active, scrimDark/Light}` (açıkta daha düşük parıltı, vurgulu olmayan accent'li kartın hafif tonu, orb parıltı seviyeleri, lacivert tonlu modal perde).
* **Orb boyutu** `OrbSize.{xl(76), lg(64), md(52), sm(44)}`: `.diameter`, `.footprint` (= max(çap, 48): düzende kaplanan kare), `.iconSize` (0.44 d).
* **Hareket** `AppMotion.{instant 90, fast 140, base 220, slow 320, hero 480, pageTransition 260, staggerStep 40, staggerMaxItems 8, standard (easeOutCubic), spring (SpringCurve), linear}`; `SpringCurve({damping=0.72, settle=0.01})` (uçlar tam 0/1, ≈%3.8 aşım).
* `PressHaptic.{none, selection, light, medium, heavy}`: selection aç/kapat, light senaryo, medium durdur/yıkıcı. `wcagContrast(a, b)`.

## 3. Tema (`AppTheme`)

Mevcut `AppTheme.*` API ve sabitler **aynen** durur. Değişenler:

* `AppTheme.cardDecoration(ctx, {accent, radius = 20, emphasized = false})` → imza korunur; **camsı** yüzey: dikey gradyan (`SurfaceTokens`), 1 px rim (`rimSolid`), gölge (koyu blur 22 y+10 / açık blur 18 y+8). `accent` ⇒ kenar `accent@0.28`; `emphasized` ⇒ `accent@0.55` 1.4 px + sol-üst `accent@0.14` RADYAL parıltı (BoxShadow değil). `BoxDecoration.color` kart yüzey rengi olarak KALIR (taban). **Varsayılan yarıçap 14 → 20**: eski çağrılar `radius:` vermiyorsa kartları büyür; sorun olursa açıkça verin.
* `AppTheme.glassDecoration(ctx, {accent, radius, emphasized, solidRim = true})`: çekirdek (`SurfaceCard` `solidRim: false` ile gradyan rim'i kendisi boyar).
* `ThemeData` (koyu + açık AYNI kurucudan, eşit kalite): `elevatedButtonTheme` + `filledButtonTheme` (**türler `ElevatedButton`/`FilledButton` kalır**; ikisi AYNI `primaryButtonStyle` ile kurulur: `ButtonStyle.backgroundBuilder` → `PrimaryButtonSurface` → ortak `ToneButtonSurface`: mavi→koyu cyan gradyan, beyaz metinle AA, stadium, renkli gölge, basınçta 0.97 ölçek anında; boyut `ElevatedButton` min 52, `FilledButton` min 48), `outlined/text` (stadium, min 48), `switchTheme` (emerald/slate), `sliderTheme` (`GlowSliderTrackShape` + `OrbSliderThumbShape`; **`Slider` türü kalır**; renk `SliderThemeData.activeTrackColor/thumbColor`'dan türer), `chipTheme`, `snackBarTheme` (yüzen, yan boşluk 8), `bottomSheetTheme` (üst yarıçap 28), `dialogTheme` (24), `inputDecorationTheme` (odak halkası + yüzen etiket + imleç cyan, 2 px), `tabBarTheme`, `popupMenuTheme`, `progressIndicatorTheme`, `pageTransitionsTheme` = `FadeThroughPageTransitionsBuilder` (tüm platformlar). `colorScheme.onPrimary` artık beyaz (koyu temada siyahtı).
* **Tema düğmesi YEREL stili okur (`ToneButtonSurface`).** Düğmenin kendi `style`ı opak bir `backgroundColor` taşıyorsa (ve tema birincil rengi değilse) gradyan o rengin ailesinden çizilir (açık ton → ana/derin ton, gölge o renk, metin/simge mürekkebi AA); yerel `shape` yarıçapı yüzeye uygulanır; yerel `foregroundColor`/`iconColor`/`disabledBackgroundColor` varsa ona saygı gösterilir. Böylece çağrı yerindeki `backgroundColor`/`shape` alta dikdörtgen "plaka" bırakmaz ve renk anlamı mavi gradyana inmez. YİNE DE aile renkli düğme için `accentButtonStyle(family)` (birincil, `ElevatedButton`), `accentOutlinedButtonStyle(context, family)` (çerçeveli: çerçeve + metin + simge AYNI aile, açıkta `family.deep`) ve `destructiveButtonStyle()` (rose) kullanın; `ElevatedButton.styleFrom(backgroundColor/shape/textStyle)` YASAKTIR (`v9_consistency_guard_test.dart` kaynak taramasıyla reddeder).
* **`FilledButton` hizalı:** `ElevatedButton` ile aynı gradyan/cam dili (tür DEĞİŞMEZ; yalnız boyut/dolgu farklı); eskiden düz `#2563EB` + r14 dikdörtgendi ve aynı eylem ekrana göre iki görünümdeydi.
* **`AppTheme` okunur-renk yardımcıları (ham `AppTheme.accent*`/`Colors.*Accent` yazı/çerçeve rengi olarak KULLANILMAZ):** `readableAccent(ctx, renk)` / `readableAccentOn(Brightness, renk)` (metin/ince simge, AA 4.5:1; ton korunur, yalnız açıklık değişir) · `readableFamily(ctx, aile)` (= `readableAccent(ctx, aile.base)`) · `readableAccentBorder(ctx, renk)` (çerçeve/çizgi, ≥ 3:1) · `accentTone(ctx, aile)` (yay/halka/çizgi çekirdeği: koyuda `light`, açıkta `deep`) · `filledAccent(renk)` (beyaz yazılı dolgu zemini) · `warningText/successText/dangerText/infoText(ctx)` · alan: `getFieldFill/getFieldBorder(ctx)` (`fieldBorderDark/Light`: dinlenme kenarı dolguya ve karta karşı ≥ 3:1) · `getInsetColor(ctx)` (kart içi çukur) · `quietTextButtonStyle(ctx)` (İptal/Geri: soluk ön plan, tek stil).
* **Tema yazma kuralları (tuzak):** (1) `ButtonStyle.textStyle`/`ChipThemeData.labelStyle`/`SnackBarThemeData.contentTextStyle` gibi **sabit `TextStyle` VERMEYİN**: aile/ölçek kullanım anında tema `textTheme`'inden çözülmeli (testler `copyWith(textTheme:)` ile Roboto enjekte eder; aile taşımayan stil platform yazı tipine düşer) ve null olmayan düğme `textStyle`ı, tema `ThemeData.lerp` (varsayılan temaya/temadan geçiş) sırasında `AnimatedDefaultTextStyle` "farklı inherit" hatası verir. Düğme tipografisi `textTheme.labelLarge` (15 sp, ağırlık değişmez; yeni Inter ağırlığı = yeni google_fonts indirmesi olurdu) ile ayarlanır. (2) Yeni renk ihtiyacı için `colorScheme`'e değil bileşen temasına yazın.

## 4. Hareket bileşenleri (`lib/ui/motion/`)

### `AmbientClock`
`AmbientClock()` · `AmbientClock.shared` · `AmbientClock.fixed(seconds)` (asla çalışmaz, golden). `time`, `isTicking`, `isFixed`, `activeSlots`, `tryAcquireSlot(owner) → bool`, `releaseSlot(owner)`, `addListener/removeListener`. Tek `Ticker`; ≈20-24 Hz bildirim; dinleyici yoksa DURUR; `paused/hidden/detached`'ta durur, dönüşte sürer (zaman monoton); en çok **8** slot. Tüketim: yalnız küçük bir `CustomPainter(repaint: clock)`; kartı yeniden KURMAYIN.

### `Pressable`
```dart
Pressable({child | builder: (ctx, pressed) => ..., onTap, onLongPress, enabled = true,
           pressedScale = 0.96, releaseOvershoot = 1.0, haptic = PressHaptic.none,
           behavior = HitTestBehavior.opaque, slop = kTouchSlop})
```
Pressed ölçeği **pointer-down ile aynı karede** (tween yok, `onTapDown`'un 100 ms gecikmesi beklenmez); `onTap` pointer-up ile **eşzamanlı**; bırakınca yaylanma yalnız `full` kipte; kayma `slop`'u aşarsa basılı bırakılır; `onTap == null` ⇒ pasif. Anlamsal düğüm EKLEMEZ.

### `AnimatedCount`
`AnimatedCount({value: int, format: (int) => String, style, duration = slow, curve, textAlign, maxLines = 1, overflow})`. `off` kipinde **ara değer yok** (anında son değer); `full`'de akar, hedef değişirse görünen değerden devam eder; ağaçta her an TEK `Text`; tabular rakam; anlamsal etiket yalnız son değer.
```dart
AnimatedCount(value: pos, format: (v) => '%$v', style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800))
```

### `StaggeredEntrance`
`StaggeredEntrance({index, child, step = 40 ms, duration = base, offset = 12, curve})`. Fade + dikey kayma, **tek sefer**, `Interval` gecikmesi (Timer/Future.delayed YOK), `off`'ta anında. Not: `ListView.builder`'da öğe ekrana her girişinde yeniden oynar; yalnız ilk yüklemede/küçük listede kullanın. Sonlu `FadeTransition` kullanır (ambient değil).

### `Skeleton` / `SkeletonCard`
`Skeleton({width, height = 14, radius = 8, maxSweep = 12 s})`, `Skeleton.circle({size = 44})`, `SkeletonCard({lines = 2, showLeading = true, leadingSize = 44, padding})`. Paylaşılan saatten tek süpürme; **12 sn sonra durur**; `off`'ta statik; `ExcludeSemantics` (yükleme metnini kapsayıcıda verin). `width: null` ⇒ üst kısıtın tam genişliği (sınırlı olmalı; `Row` içinde `Expanded`/`SizedBox` verin).

### `SkeletonText`
`SkeletonText({width, fontSize = 14, lineHeight = 1.2, barHeightFactor = 0.78, radius = 8, alignment})`: yer tuttuğu metnin satır yüksekliği YAZI ÖLÇEĞİNE göre (`MediaQuery.textScalerOf`) hesaplanır; veri gelip gerçek metin (aynı `fontSize` x `lineHeight`) yerine geçince düzen ZIPLAMAZ (sabit yükseklikli `Skeleton(height: 28)` 1.5 ölçekte gerçek sayıdan ≈ 17 dp kısa kalıyordu). Sayaç değeri için: `SkeletonText(fontSize: 28, lineHeight: 1.1, width: 64)`.

### `PulseRing`
`PulseRing({color, diameter, trigger = 0, playOnMount = false, duration = 450 ms, maxScale = 1.55, strokeWidth = 2.5})`. `trigger` değişince bir kez; `off`'ta çizilmez.

### `FadeThroughPageTransitionsBuilder`
Giden sayfa ilk %35'te solar, gelen sonraki %65'te belirir (+12 dp kayma); iki sayfa hiçbir karede birlikte görünmez; ileri 260 ms, geri 240 ms. `AppTheme.pageTransitions`.

## 5. Orb bileşenleri (`lib/ui/widgets/orb/`)

Ortak sözleşme: dokunma kutusu ≥ 48 dp (`size.footprint`); pressed ölçeği 0.92 parmak değdiği AN; `onTap` hiç gecikmez/kuyruklanmaz/AbsorbPointer yapmaz (çift dokunma koruması `CommandPipeline`'dadır, orb `pending` iken de dokunuş alır); `onTap/onChanged == null` ⇒ **devre dışı** (gri küre, parıltı yok, `Semantics.enabled = false`); gövde `OrbPainter` (parıltı → radyal gövde → alt iç gölge → speküler → rim) + simge widget'ı; her orb `RepaintBoundary` içinde; açık temada parıltı yerine renkli STATİK gölge (kendi RepaintBoundary'sinde); nefes yalnız `RadialGradient` alfa/yarıçapını değiştirir (blur değişmez). Anahtar (`Key`) widget'ın kendisine verilir: `find.byKey(...)` orb'u bulur, `tester.tap` merkezine dokunur.

**Simge rengi** otomatiktir (`OrbColors.iconFor`): gövdenin gerçek piksellerinde ≥ 3:1 olan beyaz/koyu mürekkep (şu an tüm saturated ailelerde koyu mürekkep). **Kalın/dolu ikonlar** seçin (ör. `Icons.arrow_upward_rounded`, `stop_rounded`, `arrow_downward_rounded`, `lightbulb_rounded`, `bolt_rounded`, `nightlight_round`); `keyboard_arrow_*` glifleri küçük görünür.

### `OrbButton`
```dart
OrbButton({icon | iconBuilder: (ctx, color, size) => Widget, required family, required semanticLabel,
           onTap, size = OrbSize.lg, active = false, pending = false, status = OrbStatus.none,
           haptic = PressHaptic.light, breathPhase = 0.0, glow = true})
```
`active`: parıltı güçlenir + (full, slot varsa) nefes alır. `pending`: çevresinde dönen yay (`ProgressArc`, en çok 10 sn). `status`: `success` ⇒ tek seferlik halka + parlak kenar; `error` ⇒ ±3 px sarsıntı + rose flaş + rose kenar (yalnız `full`; kenar `off`'ta da durur). Sonucu gösterdikten sonra `none`'a çevirmek SAHİBİNİN işidir (orb zamanlayıcı kullanmaz). Anlamsal: `button`, `enabled`, `label`.
```dart
OrbButton(key: Key('btn_shutter_up_$pair'), icon: Icons.arrow_upward_rounded, family: AppFamilies.emerald,
          semanticLabel: 'Aç', active: opening, pending: pendingUp, onTap: () => state.shutterUp(pair))
```

### `OrbToggle`
```dart
OrbToggle({required value, required onChanged: ValueChanged<bool>?, required icon, activeIcon, required family,
           required semanticLabel, size = OrbSize.lg, pending = false, status = OrbStatus.none,
           haptic = PressHaptic.selection, breathPhase = 0.0, glowWhenOn = true})
```
Kontrollü bileşen: tıklayınca `onChanged(!value)` çağrılır; değeri sahibi günceller. Kapalı = koyu/açık cam küre; açık = aile rengi + nefes. Geçiş `slow` yaylanma; açılışta 1.0 → 1.08 → 1.0 pop (yalnız `full`; `off`'ta anında). Anlamsal: `button` + **`toggled`** + `enabled` + `label`. `Switch` yerine kullanılırsa testler `find.byType(OrbToggle)` + `.value` okur.
```dart
OrbToggle(key: Key('switch_relay_$id'), value: isOn, onChanged: (v) => state.toggleRelay(id, v),
          icon: Icons.lightbulb_outline_rounded, activeIcon: Icons.lightbulb_rounded,
          family: AppFamilies.amber, semanticLabel: name, size: OrbSize.md)
```

### `OrbIconBadge`
`OrbIconBadge({icon, family, size = OrbSize.sm, active = false, pending = false, status, enabled = true, glow = false, semanticLabel})`. Etkileşimsiz (dokunuş alttaki sahibine geçer); `semanticLabel` yoksa anlamdan hariç.

### `GlassIconButton`
`GlassIconButton({icon, onTap, semanticLabel, size = 44, showBadge = false, badgeColor, badgeSemantics, iconColor, haptic = PressHaptic.light})`. Cam disk (kart gradyanı + rim + statik gölge), 44 görsel / 48 hedef, rozet noktası (`Key('glass_badge_dot')`); rozet açıklaması etikete eklenir (`'Bildirimler, 2 yeni'`).

### `AvatarOrb` / `ScrollCue`
`AvatarOrb({letter, family, size = 56, ringed = false, letterKey})`: harf taşıyan etkileşimsiz avatar orb'u (`lib/ui/widgets/orb/avatar_orb.dart`). `ScrollCue({color, builder})`: kaydırılabilir alanın sağ kenarında kalıcı ince kaydırma çubuğu (`lib/ui/widgets/scroll_cue.dart`). İkisi de eskiden `user_profile_dialog.dart` içindeydi; oradan `export` edilir (eski içe aktarma yolları kırılmaz).

### `GlowDot` / `ProgressArc`
`GlowDot({color, size = 10, breathing = false, pulses = 0})`: `pulses: 3` bağlanışta 3 nabız (≈2.7 sn) sonra sabit; `breathing` slot alır. Anlamdan hariç: durum metni yanında yazılmalı. `ProgressArc({diameter, color, strokeWidth = 3, sweep = 0.36, period = 1.1 s, maxSpin = 10 s})`: `off`'ta statik yay.

### Düşük seviye
`paintOrbBody(canvas, center, radius, OrbColors, {specularScale, flash})`, `paintOrbGlow(...)`, `OrbPainter`, `OrbColors.{family(f), glass(brightness), disabled(brightness), lerp, iconFor, inkFor}`, `OrbCore` (OrbButton/OrbToggle/OrbIconBadge'in ortak gövdesi). Şartname dışı TEK ekleme: gövdede alt "yansıma ışığı" (`light@0.42 → 0`, §3.1 ③ ile ④ arası) camsı derinlik için.

## 6. `SurfaceCard`
```dart
SurfaceCard({required child, accent, active = false, onTap, onLongPress, padding = EdgeInsets.all(16),
             margin, radius = 20, semanticLabel, haptic = PressHaptic.none, pressedScale = 0.985})
```
Camsı gövde (`AppTheme.glassDecoration`) + gradyan rim (`SurfaceRimPainter`) + `RepaintBoundary`; `onTap` varsa `Pressable`; `active` + `accent` ⇒ vurgu kenarı + radyal parıltı. `semanticLabel` verilirse tek `button` düğümü, verilmezse çocuk anlamı korunur. **İç içe dokunma:** kartın içindeki orb'un `onTap`'i kartınkinden ÖNCE kazanır (en içteki `TapGestureRecognizer`); orb dışı alana dokunuş kartın `onTap`'ini çağırır. Hem karta hem orb'a basılınca ikisinin pressed ölçeği birlikte uygulanır (0.985 × 0.92). `InkWell` dalgası YOK: mevcut `card_relay_<id>` `InkWell` davranışını koruyacaksanız `SurfaceCard`'ı onTap'siz kullanıp içine `InkWell` koyun ya da testleri `GestureDetector`'a göre güncelleyin.

## 7. Doğrulama kuralları (hatırlatma)

* **BackdropFilter / saveLayer / Opacity YOK** (`SurfaceCard`+orb ağacında testle doğrulanır). İstisna: tek seferlik sonlu solmalar (`StaggeredEntrance`, sayfa geçişi) `FadeTransition` kullanır.
* `Timer`/`Future.delayed` ile animasyon YASAK; `AnimationController` dispose edilir; sonlu animasyonlar `pumpAndSettle` ile biter.
* Metin değişiminde eski+yeni metin aynı anda ağaçta olmaz (`AnimatedCount` tek `Text`; orb simgesi değişince eski simge kalkar).
* Performans: ölçülmedi. Yapısal kanıt: ambient bütçesi (8), `RepaintBoundary` yerleşimi, "kare istenmez" testleri.

## 8. Görsel galeri

```
flutter test --tags visual --update-goldens test/visual     # test/visual/goldens/*.png üretir (gerçek Roboto + MaterialIcons)
AHBU_VISUAL=1 flutter test --tags visual test/visual         # kayıtlı PNG'lerle piksel karşılaştırır
```
Varsayılan `flutter test` bu grubu ATLAR. Harness (`test/visual/support/golden_support.dart`): `galleryAppBuilder(boundaryKey, textScale, realBackground)` (yakalama sınırı Navigator'ı KAPSAR: diyalog/alt sayfa/modal perde PNG'ye girer) · `pumpGallery(tester, boundaryKey, brightness, textScale, size, child, {clockSeconds, realBackground, fitHeight})` (`fitHeight`: yüzey yüksekliği içeriğe eşitlenir, kesme/boş bant yok; `realBackground`: üretimdeki GERÇEK `CircuitBackground`, arka planda doğrudan duran metinlerin kontrastı üretimle birebir) · `precacheGalleryImages(tester, {backgrounds})` (logo/arka plan görsellerini önceden çözer; kendi `MaterialApp`ını kuran galeriler çağırır) · `PushedOverHome(child)` (sayfayı boş bir kök sayfanın ÜSTÜNE yığar: gerçek akıştaki gibi `NeonAppBar`'da geri diski görünür; kök rotada geri düğmesi çizilmez) · `loadGoldenFonts()` ('Inter' ve 'monospace' adları Roboto dosyalarına bağlanır: Ahem bloğu yok). Sayfalar: `orbs_matrix_*` (7 varyant × idle/pressed/active/pending/success/disabled), `components_*` (boyutlar, toggle, rozet, cam düğme, nokta/yay/halka), `cards_*` (SurfaceCard, panjur kartı örneği, kaydırıcılar), `controls_*` (düğmeler, çip, anahtar, hap, iskelet), `overlays_*` (diyalog, alt sayfa, snackbar, odaklı giriş alanı); `{dark,light}_{1.0,1.5}` (yazı ölçeği). 1.0 ölçekliler 2× piksel. `flutter_test` gölgeleri düz bloğa çevirdiği için galeri `debugDisableShadows = false` yapar (gerçek blur görünür).

## 9. `NeonAppBar` (WP-V9) — ikincil sayfaların ortak üst çubuğu

`lib/ui/widgets/neon_app_bar.dart`. `Scaffold.appBar` için bir `PreferredSizeWidget`; `build` GERÇEK bir `AppBar` döndürür (alt sınıf DEĞİL: `find.byType(AppBar)` bulur, ekran okuyucu `AppBar` anlamını aynen görür). Pano/konsol üst çubuğu (`DashboardAppBar`) ayrıdır ve BÖYLE KALIR.

```dart
Scaffold(
  appBar: NeonAppBar(
    title: 'Cihaz Envanteri',                         // metin AYNEN
    subtitle: 'Karekodlar, Seri No & Donanım Takibi', // isteğe bağlı, soluk
    feature: AppFeature.inventory,                    // orb rengi (featureFamily); family: ile ezilebilir
    icon: Icons.inventory_2_rounded,                  // verilmezse orb çizilmez
    titleKey: Key('nav_service_title'),               // isteğe bağlı (testler okur)
    actions: [NeonBarAction(key: Key('btn_refresh'), icon: Icons.refresh_rounded, tooltip: 'Yenile', onTap: reload)],
    bottom: TabBar(...),                              // isteğe bağlı; yükseklik preferredSize'a eklenir
  ),
)
```

* **Yükseklik 64 dp** (`NeonAppBar.toolbarHeight`) + `bottom`; arka plan şeffaf, `scrolledUnderElevation: 0`, `surfaceTintColor: transparent` (kaydırınca M3 "scrolled-under" tonu YOK).
* **Geri düğmesi:** rota geri gidilebiliyorsa (`automaticallyImplyLeading`, varsayılan true) `GlassIconButton` (cam disk, `Key('nav_back')`, ipucu/anlam etiketi `MaterialLocalizations.backButtonTooltip` — eski `BackButton` ile aynı, `tester.pageBack()` bulur; `Navigator.maybePop`: `PopScope` kapıları çalışır). Görsel sol kenar 16 dp içerik oluğuna oturur; kök rotada düğme YOK (başlık 16 dp'den başlar).
* **Özellik orb'u** `OrbIconBadge` (~32 dp: 44 dp'lik orb ölçeklenir, büyük orb'larla AYNI gövde/parıltı); rengi `featureFamily(feature)` — çekmece/konsol/araç kartıyla AYNI (§11).
* **Başlık** `AppText.title` 18 sp / w700, **alt başlık** `AppText.caption` 12.5 sp w600 soluk (`getTextMuted`, iki temada AA). Sığmayan başlık/alt başlık en çok 2 satıra SARILIR (kesilmez); blok `NeonAppBar.maxTextScale` (1.3; pano üst çubuğuyla aynı sınır) kadar büyür ve yine 64 dp'ye sığmazsa tek parça küçülür (`FittedBox.scaleDown`): yazı ölçeği 1.5/2.0 ve 320-412 dp'de taşma/kesilme yok (`test/ui/neon_app_bar_test.dart` matrisi).
* **Eylemler** `NeonBarAction(icon, tooltip, onTap, showBadge, badgeSemantics, iconColor)`: `GlassIconButton` (44 görsel / 48 hedef) + işaretçi ipucu (anlamdan hariç; anlam etiketini düğmenin kendisi verir). `Key` ve etiket çağıranda KORUNUR (`btn_refresh`, `nav_refresh`, `btn_add_rule`); son diskin görsel sağ kenarı 16 dp'ye oturur. `onTap == null` ⇒ pasif.
* **Uygulandığı sayfalar:** Cihaz Envanteri (inventory), Zamanlı Kurallar (rules), Servis Yönetimi (management, TabBar bottom), Abonelerim (subscribers), Aile & Misafir (family), Cihaz & Sistem Ayarları (settings), Servis Paneli (commissioning). Giriş/kayıt/şifre sayfaları, tarayıcı ve sihirbaz kendi çubuklarında kalır.
* Galeri: sayfalar `PushedOverHome` ile yığılır (geri diski görünür).

## 10. `AppPill` / `AppChip` (WP-V9) — TEK rozet/çip dili

`lib/ui/widgets/app_pill.dart`. Eskiden beş ayrı elle yazılmış rozet vardı (konsol `GlassPill`, pano `StatusPill`, servis `ServiceStatusPill`, ayar `StatusBadge`, `ModuleBadge`) ve üç çip stili; hepsi tek yüzeye iner: **stadium, vurgu tonu `.14` + okunur tonun kenarı `.40`, >= 12 sp / w700, isteğe bağlı `GlowDot`/simge, metin `readableFamily` (açık temada okunur, AA ≥ 4.5:1)**. Dolgu OPAKTIR (kart gradyanı + ton): doğrudan devre kartı zemininde (üst çubuk, durum şeridi) iz çizgileri metnin altından geçmez. Sabitler `AppPillTokens` (tint .14, rim .40, seçili .20/.70 1.4 px, yatay dolgu 8/12, boşluk 6, dikey 4/2).

| Bileşen | Kullanım |
|---|---|
| `AppPillShell({color, child, leading, ink, active, selected, compact, animate, minHeight, padding, gap})` | Ortak yüzey (Container + BoxDecoration + RepaintBoundary). `active: false` ⇒ nötr cam. |
| `AppPill({label, family, icon, dot, leading, maxLines = 2, compact, textKey, letterSpacing, textColor, active, animate})` / `AppPill.tinted({..., color})` | Metin rozeti. `maxLines > 1` ⇒ sarar (kesilmez); `1` ⇒ tek satır + üç nokta. `AppPill.chromeWidth({leadingWidth})` etiket dışı sabit genişlik (üst çubuk "sığar mı" ölçümü). |
| `AppChip({label, selected, onTap, family = cyan, icon, semanticLabel})` | Filtre/seçim çipi: seçili ⇒ aile tonlu dolgu + kalın kenar + **onay işareti** (yalnız renkle anlatılmaz) + AA etiket; seçili değil ⇒ nötr cam. Görsel ≈ 36 dp, dokunma hedefi ≥ 48 dp, `Pressable` 0.95, `selection` haptiği; anlam `button` + `selected` + `enabled`. `Wrap`/`Row` içinde içerik genişliğindedir. |

İnce sarmalayıcılar (ADLAR ve imzalar korundu; `test/ui/design/app_pill_test.dart` kilitler): `GlassPill` (`glass_pill.dart`; `user_profile_dialog.dart`'tan da export edilir; `chromeWidth` AppPill ile aynı), `StatusPill` (`AppPillShell`; 36 dp görsel + 48 dp hedef, sayaç `AnimatedCount`), `ServiceStatusPill`/`ServicePillShell` (servis/sihirbaz), `StatusBadge` (ayar/aile), `ModuleBadge` ('CH 3', 'RS485'). Çip tüketicileri: oda filtresi (`chip_room_*`), envanter durum filtresi (`chip_filter_*`), yönetim rol filtresi, hesap oluşturma rol çipi (`chip_role_*`), misafir süre çipi (`chip_guest_*`, violet). Profil diyaloğunun tema seçimi `ChoiceChip` KALIR (testler türü okur).

## 11. `AppFeature` vurgu haritası (WP-V9) — aynı özellik her yerde aynı renk

`lib/ui/theme/feature_accent.dart`: `enum AppFeature` + `featureFamily(AppFeature)` (= `feature.accentFamily`; alan adı `family` DEĞİL: `AppFeature.family` bir özelliktir). `const` bağlamda kullanılamaz (enum alanı sabit ifade değildir): `OrbIconBadge(family: AppFeature.inventory.accentFamily)` gibi `const` OLMAYAN kurucularda. Eski yerel `ServiceAccents` haritası SİLİNDİ (servis özellikleri buraya bağlandı).

**İlkeler:** (1) AYNI özellik her yerde AYNI aile. (2) Aynı listedeki (çekmece, konsol kutucukları, servis araç kartları, ayarlar 'Cihaz' bölümü) İKİ FARKLI özellik AYNI aileyi paylaşmaz (`FeatureGroups`; `test/ui/design/feature_accent_test.dart` + `test/ui/feature_accent_usage_test.dart` GERÇEK widget'larla kilitler). (3) Anlam (§2.1) korunur: rose yalnız tehlike; amber uyarı/erişim/kilit; emerald sağlık/başarı; violet gece/ek modül; cyan marka/teknoloji; sky insan/birincil; slate idari/nötr.

| Özellik | Aile | Nerede kullanılır |
|---|---|---|
| `inventory` | cyan | süper konsol sayaç + satır, servis konsolu sayaç, çekmece, servis araç kartı, envanter sayfası (orb, boş durum, yenileme rengi) |
| `subscribers` | sky | konsollarda 'Devreye Alınan' sayacı + 'Aboneler' satırı, çekmece, servis araç kartı, abone sayfası |
| `doctor` | emerald | süper konsol satırı, çekmece, servis araç kartı, ayarlar eylem kartı (sonuç diyaloğu başlığı sağlık durumunu emerald/amber/rose gösterir; boşta bu aile) |
| `boardReplace` | violet | servis konsolu satırı, çekmece, servis araç kartı, ayarlar eylem kartı, diyalog başlık orb'u + birincil düğme |
| `emergencyReset` | rose | konsollar, çekmece, servis paneli acil durum kartı, devir diyaloğu 'Acil Pano Sıfırlama' sekmesi (TEK tehlike özelliği) |
| `wifiRecovery` | amber | servis konsolu satırı, çekmece, servis paneli Wi-Fi kartı, ayarlar eylem kartı, kurtarma diyaloğu |
| `servicePin` | amber | ayarlar 'Yetkili Servis İçin Geçici PIN' kartı (eskiden violet: pano değişimiyle karışıyordu), servis PIN girişi kartı + diyaloğu |
| `management` | slate | süper konsol sayaç + satır, çekmece, servis araç kartı (Servis Hesapları), Servis Yönetimi sayfası |
| `commissioning` | slate | servis konsolu satırı, çekmece, yönetim sayfası araç kartı (Kurulum Sihirbazı), Servis Paneli sayfası, boş durum |
| `family` | sky | Aile & Misafir sayfası (NeonAppBar orb'u + başlık kartı), ayarlar 'Aile' bölüm başlığı |
| `ownershipTransfer` | amber | 'Daireyi Devret' düğmesi + devir diyaloğu sekmesi |
| `rules` | cyan | Zamanlı Kurallar sayfası (orb, boş durum), ayarlar kural kartı |
| `nightPeace` | violet | ayarlar gece huzur bildirimi kartı + 'Otomasyon' bölüm başlığı |
| `childLock` | amber | çocuk kilidi kartı (kilitliyken; açıkken sky), bilgi sayfası, 'Güvenlik' bölüm başlığı |
| `biometric` | emerald | biyometrik giriş kartı |
| `deviceHost` | sky | cihaz adresi kartı |
| `telemetry` | cyan | cihaz telemetrisi kartı |
| `appearance` | sky | görünüm (tema) kartı + 'Görünüm' bölüm başlığı |
| `settings` | cyan | Cihaz & Sistem Ayarları sayfası (NeonAppBar orb'u) + 'Cihaz' bölüm başlığı |
| `superConsole` | violet | rol: süper konsol başlık kartı, çekmece başlığı + 'Yönetici Konsolu' satırı |
| `serviceConsole` | cyan | rol: servis konsolu başlık kartı, çekmece başlığı + 'Servis Konsolu' satırı |

**Birlikte görünen listeler (`FeatureGroups`, hepsi benzersiz):** `superDrawer` (superConsole, inventory, management, subscribers, doctor, emergencyReset) · `serviceDrawer` (serviceConsole, subscribers, commissioning, boardReplace, wifiRecovery, emergencyReset) · `superConsole` (management, inventory, subscribers, doctor) · `serviceConsole` (inventory, subscribers, commissioning, boardReplace, wifiRecovery, emergencyReset) · `servicePanelTools` (subscribers, inventory, boardReplace, doctor, management) · `managementTools` (commissioning, subscribers, inventory, boardReplace, doctor) · `settingsDevice` (doctor, wifiRecovery, boardReplace, deviceHost, telemetry) · `settingsAutomation` (nightPeace, rules).

**Çözülen çelişkiler (çapraz eleştirmen #6):** envanter amber/cyan/violet → cyan · aboneler emerald/cyan/sky → sky · doktor cyan/emerald → emerald · pano değişimi rose/cyan/violet → violet (artık rose DEĞİL) · Wi-Fi cyan/amber/sky → amber · servis PIN violet → amber (artık pano değişimiyle aynı renk DEĞİL). Neden iki özellik slate: altı vurgulu ailenin hepsi servis özellikleri (envanter, aboneler, doktor, pano değişimi, acil sıfırlama, Wi-Fi) tarafından alınmıştı; iki idari özellik (hesaplar, servis modu) hiçbir listede birlikte görünmez ve nötr kalır.

**Haritada OLMAYANLAR (rol/durum; özellik rengi uygulanmaz):** tema satırı (güneş amber / ay violet) ve "Güvenli Çıkış"/"Hesabımı Sil" (rose = tehlike rolü); birincil eylem düğmeleri ve CTA kahramanı ('Yeni Kurulum' sky gradyan, profil diyaloğundaki 'Servis & Yönetici Panelini Aç' cyan CTA); pano üst çubuğu simgeleri (marka cyan; `DashboardAppBar` BÖYLE KALIR); giriş ekranındaki 'Servis ve kurulum' satırları (sessiz/nötr: nadir kullanılır); durum renkleri (sağlık emerald/amber/rose, çevrimdışı rose, uyarı amber, hata rose); filtre/seçim çipleri (cyan çip dili; misafir süre çipi violet). Kart KENARI özellik rengini taşımaz: ayarlar kartlarında kenar yalnız `active` (canlı durum) iken vurgulu (çapraz eleştirmen #7).
