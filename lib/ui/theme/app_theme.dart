import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../motion/fade_through_transitions.dart';
import 'slider_shapes.dart';
import 'tokens.dart';
import 'tone_button_surface.dart';

/// AHBU Akıllı Ev & Bina Otomasyonu
/// Merkezi Tema & Renk Yönetimi (Design System)
///
/// Aydınlık ve Karanlık mod renklerini, fontları ve bileşen stillerini
/// tek bir noktadan yönetir.
class AppTheme {
  // --- KOYU MOD (DARK THEME) RENK PALETİ ---
  static const Color bgDark = Color(0xFF0B1120);
  static const Color surfaceDark = Color(0xFF131D31);
  static const Color cardDark = Color(0xFF1E293B);
  static const Color cardBorder = Color(0xFF334155);
  static const Color textPrimary = Color(0xFFF8FAFC);
  static const Color textMuted = Color(0xFF94A3B8);

  // --- AYDINLIK MOD (LIGHT THEME) RENK PALETİ ---
  static const Color bgLight = Color(0xFFF1F5F9);
  static const Color surfaceLight = Color(0xFFFFFFFF);
  static const Color cardLight = Color(0xFFFFFFFF);
  static const Color cardBorderLight = Color(0xFFCBD5E1);
  static const Color textPrimaryLight = Color(0xFF0F172A);
  /// İkincil metin (açık tema): sayfa zemininde ve hafif renkli (%20'ye kadar vurgu tonlu) yüzeylerde
  /// de WCAG AA (4.5:1) sağlar.
  static const Color textMutedLight = Color(0xFF4B5B70);

  // --- ORTAK VURGU (ACCENT) RENKLERİ ---
  static const Color primaryBlue = Color(0xFF2563EB);
  static const Color primaryBlueLight = Color(0xFF60A5FA);
  static const Color accentGreen = Color(0xFF10B981);
  static const Color accentAmber = Color(0xFFF59E0B);
  static const Color accentPurple = Color(0xFFA855F7);
  static const Color accentRed = Color(0xFFEF4444);
  static const Color accentCyan = Color(0xFF06B6D4);

  // --- CONTEXT-DUYARLI RENK YARDIMCILARI ---
  static bool isDark(BuildContext context) => Theme.of(context).brightness == Brightness.dark;

  static Color getScaffoldBg(BuildContext context) =>
      isDark(context) ? bgDark : bgLight;

  static Color getSurfaceColor(BuildContext context) =>
      isDark(context) ? surfaceDark : surfaceLight;

  static Color getCardColor(BuildContext context) =>
      isDark(context) ? cardDark : cardLight;

  static Color getCardBorder(BuildContext context) =>
      isDark(context) ? cardBorder : cardBorderLight;

  static Color getTextPrimary(BuildContext context) =>
      isDark(context) ? textPrimary : textPrimaryLight;

  static Color getTextMuted(BuildContext context) =>
      isDark(context) ? textMuted : textMutedLight;

  // --- GİRİŞ ALANI (TextField) RENKLERİ: tek kaynak -------------------------------------------------------------
  /// Alan dolgusu.
  static const Color fieldFillDark = Color(0xFF0F172A);
  static const Color fieldFillLight = Color(0xFFF8FAFC);

  /// Alan dinlenme (enabled) çerçevesi: alan dolgusuna, kart yüzeyine (üst ucu dahil) ve sayfaya karşı ≥ 3:1
  /// (WCAG 1.4.11): koyu `#66768F` ≈ 3.9 / 3.6 / 3.2, açık `#7F8EA3` ≈ 3.2 / 3.3 / 3.0 (`foundation_fix_test` pinler).
  /// Tema (`inputDecorationTheme`) ve alanı yerelde boyayan ekranlar bunu kullanmalıdır (ham `cardBorder` ≈ 1.5:1'di).
  static const Color fieldBorderDark = Color(0xFF66768F);
  static const Color fieldBorderLight = Color(0xFF7F8EA3);

  static Color getFieldFill(BuildContext context) => isDark(context) ? fieldFillDark : fieldFillLight;

  static Color getFieldBorder(BuildContext context) => isDark(context) ? fieldBorderDark : fieldBorderLight;

  /// **Pasif iz / nokta / halka izi** (adım noktaları, ilerleme halkasının boş izi, çevrimdışı kaydırıcı dolgusu/başparmağı):
  /// kart ve sayfa yüzeyine karşı ≥ 3:1 (WCAG 1.4.11; eskiden `muted@0.28` ≈ 1.5:1 verip noktalar/iz kayboluyordu). Alan
  /// çerçevesiyle ([getFieldBorder]) AYNI ton: tek "nötr bileşen sınırı" değeri. Etkin (aile renkli) parçadan SÖNÜKtür
  /// (açıkta ≈ 3.3:1 orta slate; koyu mürekkep/`muted` metin rengi kadar baskın DEĞİL): pasif durum etkinden baskın okunmaz.
  ///
  /// ```dart
  /// Container(width: 8, height: 8, decoration: BoxDecoration(shape: BoxShape.circle, color: active ? accent : AppTheme.getInactiveTrack(context)))
  /// ```
  static Color getInactiveTrack(BuildContext context) => inactiveTrackOn(isDark(context) ? Brightness.dark : Brightness.light);

  /// [getInactiveTrack]'ın BAĞLAMSIZ çekirdeği (tema kurulurken / `BuildContext` olmayan yerlerde).
  static Color inactiveTrackOn(Brightness brightness) => brightness == Brightness.dark ? fieldBorderDark : fieldBorderLight;

  /// Çekmece yüzeyi. Koyu temada sayfa zemininden ([bgDark]) bir kademe açık [surfaceDark]: perdenin altında çekmece
  /// kenarı sayfadan ayrışır (eskiden zemin rengiyle AYNIydı, kontrast ≈ 1.1:1).
  static Color getDrawerBg(BuildContext context) =>
      isDark(context) ? surfaceDark : bgLight;

  static Color getDrawerHeaderBg(BuildContext context) =>
      isDark(context) ? cardDark : Colors.white;

  /// Kartın içindeki girdi/çukur yüzeyi (koyu temada `0F172A`, açık temada açık gri).
  static Color getInsetColor(BuildContext context) =>
      isDark(context) ? const Color(0xFF0F172A) : const Color(0xFFF1F5F9);

  /// İki rengin WCAG kontrast oranı (1:1 .. 21:1).
  static double contrastRatio(Color a, Color b) => wcagContrast(a, b);

  static final Map<int, Color> _readableCache = <int, Color>{};

  /// Bir vurgu renginin **metin/simge** olarak okunabilir tonu: en zor zeminde WCAG AA (4.5:1)
  /// sağlayana kadar **yalnızca açıklığı** değiştirilir (ton korunur; zaten yeterliyse renk olduğu gibi
  /// döner). En zor zemin: koyu temada en açık yüzey (kart), açık temada en koyu yüzey (sayfa zemini);
  /// ayrıca rozet ve bilgi kutusu gibi **vurgu rengiyle %20 boyanmış** yüzeyde de okunur. Dolgu/kenarlık
  /// için ham vurgu rengi kullanılır; yalnızca yazı ve ince simgeler için bunu kullanın.
  static Color readableAccent(BuildContext context, Color accent) =>
      readableAccentOn(isDark(context) ? Brightness.dark : Brightness.light, accent);

  /// [readableAccent]'in BAĞLAMSIZ çekirdeği: tema parlaklığı verilir (tema kurulurken ya da `BuildContext` olmayan
  /// yerlerde — `ThemeData` bileşen temaları, sabit tablolar — kullanılır). Aynı sonucu ve aynı önbelleği paylaşır.
  static Color readableAccentOn(Brightness brightness, Color accent) {
    final dark = brightness == Brightness.dark;
    final cacheKey = (accent.toARGB32() << 1) | (dark ? 1 : 0);
    final cached = _readableCache[cacheKey];
    if (cached != null) return cached;

    final background = dark ? cardDark : bgLight;
    final tinted = Color.alphaBlend(accent.withValues(alpha: 0.2), background);
    final hsl = HSLColor.fromColor(accent);
    var lightness = hsl.lightness;
    var color = accent;
    for (var i = 0;
        i < 24 && (contrastRatio(color, background) < 4.5 || contrastRatio(color, tinted) < 4.5);
        i++) {
      lightness = dark ? (lightness + 0.03).clamp(0.0, 0.92) : (lightness - 0.03).clamp(0.08, 1.0);
      color = hsl.withLightness(lightness).toColor();
    }
    return _readableCache[cacheKey] = color;
  }

  static final Map<int, Color> _filledCache = <int, Color>{};

  /// **Beyaz yazılı dolgulu düğme** zemini: [accent]'in açıklığı, beyaz metinle WCAG AA (4.5:1)
  /// sağlanana kadar azaltılır (ton korunur; zaten yeterliyse renk olduğu gibi döner).
  static Color filledAccent(Color accent) {
    final key = accent.toARGB32();
    final cached = _filledCache[key];
    if (cached != null) return cached;
    final hsl = HSLColor.fromColor(accent);
    var lightness = hsl.lightness;
    var color = accent;
    for (var i = 0; i < 24 && contrastRatio(color, Colors.white) < 4.5; i++) {
      lightness = (lightness - 0.03).clamp(0.08, 1.0);
      color = hsl.withLightness(lightness).toColor();
    }
    return _filledCache[key] = color;
  }

  /// Anlamsal metin renkleri (uyarı / başarı / hata / bilgi) — açık temada AA kontrastlı.
  static Color warningText(BuildContext context) => readableAccent(context, accentAmber);
  static Color successText(BuildContext context) => readableAccent(context, accentGreen);
  static Color dangerText(BuildContext context) => readableAccent(context, accentRed);
  static Color infoText(BuildContext context) =>
      isDark(context) ? primaryBlueLight : const Color(0xFF1D4ED8);

  static final Map<int, Color> _borderCache = <int, Color>{};

  /// Bir vurgu renginin **çerçeve / ince çizgi / simge çizgisi** olarak okunabilir tonu (UI bileşeni kontrastı ≥ 3:1,
  /// WCAG 1.4.11). Koyu temada ham vurgu rengi olduğu gibi döner (koyu yüzeylerde zaten ≥ 3:1). Açık temada, beyaz kart
  /// ve sayfa zemininde ([bgLight]) ≥ 3:1 olana kadar YALNIZCA açıklığı azaltılır (ton korunur). Metin için
  /// [readableAccent] (AA 4.5:1) kullanın; bu yardımcı yalnız kenarlık/çizgi içindir (ham `AppTheme.accent*` ya da
  /// `Colors.amber/cyanAccent` açık temada 1.2–2.2:1 verir).
  ///
  /// ```dart
  /// side: BorderSide(color: AppTheme.readableAccentBorder(context, AppFamilies.amber.base))
  /// ```
  static Color readableAccentBorder(BuildContext context, Color accent) {
    if (isDark(context)) return accent;
    final key = accent.toARGB32();
    final cached = _borderCache[key];
    if (cached != null) return cached;
    final hsl = HSLColor.fromColor(accent);
    var lightness = hsl.lightness;
    var color = accent;
    for (var i = 0;
        i < 24 && (contrastRatio(color, Colors.white) < 3.0 || contrastRatio(color, bgLight) < 3.0);
        i++) {
      lightness = (lightness - 0.03).clamp(0.08, 1.0);
      color = hsl.withLightness(lightness).toColor();
    }
    return _borderCache[key] = color;
  }

  // --- ÇERÇEVELİ (OutlinedButton) DÜĞME KENARI: TEK ton kuralı ----------------------------------------------------------

  /// Çerçeveli düğme kenarının hedef kontrastı: WCAG 1.4.11 eşiği 3:1'dir; 1.5 dp'lik çizginin anti-alias'ı için küçük bir
  /// pay eklenir. [outlinedBorderOn] kenarı bu oranı, düğmenin durabileceği TÜM yüzeylerde ([outlineSurfacesOn]) sağlar.
  static const double outlineMinContrast = 3.2;

  /// Koyu temada kenar alfasının başlangıç değeri (eski `accentOutlinedButtonStyle` kuralı: `family.base@0.70`). Bu alfa
  /// 3:1'i vermiyorsa (sky/rose/violet koyu kartta ≈ 2.5–2.9:1 veriyordu) alfa artırılır; opak ton da yetmezse açıklık artar.
  static const double outlineBaseAlpha = 0.70;

  /// Çerçeveli düğmenin üzerinde durabileceği yüzeyler. Koyu: kart üst/alt ucu, [cardDark], diyalog yüzeyi, sayfa zemini,
  /// çekmece. Açık: beyaz kart, kart alt ucu, sayfa zemini ([bgLight]: en koyu açık yüzey), alan dolgusu.
  static List<Color> outlineSurfacesOn(Brightness brightness) => brightness == Brightness.dark
      ? <Color>[
          SurfaceTokens.dark.cardTop,
          SurfaceTokens.dark.cardBottom,
          cardDark,
          const Color(0xFF141E33), // diyalog yüzeyi
          bgDark,
          surfaceDark,
        ]
      : <Color>[Colors.white, SurfaceTokens.light.cardBottom, bgLight, fieldFillLight];

  static final Map<int, Color> _outlineCache = <int, Color>{};

  /// **Çerçeveli düğme kenarı: tüm yollar için TEK ton kuralı.** Tema `OutlinedButton`ı, `accentOutlinedButtonStyle` ve
  /// elle çerçeve çizen düğmeler (`Hepsini Kapat`, `Yeniden dene`, `Oturumu Kapat` ...) bu kenarı kullanmalıdır: aynı aile
  /// aynı ekranda iki farklı çerçeve tonunda ÇİZİLMEZ ve kenar iki temada da ≥ 3:1'dir ([outlineMinContrast]).
  ///
  /// * **Koyu:** `family.base`, alfa [outlineBaseAlpha]'dan başlar; kart/diyalog/sayfa zeminlerinde ≥ 3.2:1 olana kadar artar
  ///   (amber/cyan/emerald 0.70'te kalır; sky/rose/violet neredeyse opak olur). Hiçbir alfa yetmezse açıklık artar.
  /// * **Açık:** `family.base` OPAK; ≥ 3.2:1 olana kadar YALNIZCA açıklığı azaltılır (ton korunur; sky/rose/violet/slate zaten
  ///   yeterli, amber/cyan/emerald bir kademe koyulaşır). Eski tema kenarı (sky@0.70 ≈ #76A8F9) beyazda ≈ 2.4:1 idi.
  ///
  /// Nötr aile (slate) de AYNI kuralı izler (özel durum yok): açıkta `slate.base`, koyuda bir kademe açılmış slate; alan
  /// çerçevesiyle ([getFieldBorder]) aynı ≥ 3:1 ailesindedir. Metin/simge rengi [readableAccent]'tir (AA); bu yardımcı yalnız
  /// kenar içindir.
  static Color outlinedBorder(BuildContext context, AccentFamily family) =>
      outlinedBorderOn(isDark(context) ? Brightness.dark : Brightness.light, family);

  /// [outlinedBorder]'ın BAĞLAMSIZ çekirdeği (tema kurulurken kullanılır; aynı sonuç, aynı önbellek).
  static Color outlinedBorderOn(Brightness brightness, AccentFamily family) => _outlineFor(brightness, family.base);

  /// Ailesi elde olmayan ham bir vurgu rengi ([accent]) için [outlinedBorder]: renk önce ailesine oturtulur
  /// ([ButtonTone.familyFor]: aynı anlam hangi API ile verilirse verilsin aynı kenar); aileye yakın değilse renk kendisi
  /// taban sayılır.
  static Color outlinedBorderOfColor(BuildContext context, Color accent) {
    final brightness = isDark(context) ? Brightness.dark : Brightness.light;
    final family = ButtonTone.familyFor(accent);
    return family == null ? _outlineFor(brightness, accent) : outlinedBorderOn(brightness, family);
  }

  /// `side:` için hazır çerçeve çizgisi ([outlinedBorder] rengi, varsayılan 1.5 dp).
  static BorderSide outlinedSide(BuildContext context, AccentFamily family, {double width = 1.5}) =>
      BorderSide(color: outlinedBorder(context, family), width: width);

  static Color _outlineFor(Brightness brightness, Color base) {
    final dark = brightness == Brightness.dark;
    final key = (base.toARGB32() << 1) | (dark ? 1 : 0);
    final cached = _outlineCache[key];
    if (cached != null) return cached;

    final surfaces = outlineSurfacesOn(brightness);
    bool enough(Color c) => surfaces.every((s) => contrastRatio(Color.alphaBlend(c, s), s) >= outlineMinContrast);

    final opaque = base.withValues(alpha: 1.0);
    Color? result;
    if (dark) {
      // Önce alfa artırılır (eski `@0.70` görünümü korunur); opak ton da yetmezse açıklık artırılır.
      for (var percent = (outlineBaseAlpha * 100).round(); percent <= 100 && result == null; percent += 2) {
        final candidate = base.withValues(alpha: percent / 100);
        if (enough(candidate)) result = candidate;
      }
    }
    if (result == null) {
      final hsl = HSLColor.fromColor(opaque);
      var lightness = hsl.lightness;
      var color = opaque;
      for (var i = 0; i < 40 && !enough(color); i++) {
        lightness = (lightness + (dark ? 0.02 : -0.02)).clamp(0.04, 0.96);
        color = hsl.withLightness(lightness).toColor();
      }
      result = color;
    }
    return _outlineCache[key] = result;
  }

  /// Bir aile renginin **yay / halka / ince çizgi / parıltı çekirdeği** tonu: koyu temada açık ton ([AccentFamily.light]),
  /// açık temada koyu ton ([AccentFamily.deep]). Açık zeminde `family.light` ≈ 1.3:1 verip kaybolur (bekleyen komut yayı,
  /// başarı halkası). `OrbCore` bekleme yayını/halkayı aynı kuralla boyar; orb dışında çizilen yay/halka için bunu kullanın.
  static Color accentTone(BuildContext context, AccentFamily family) => isDark(context) ? family.light : family.deep;

  /// Bir aile renginin **metin/ince simge** olarak okunabilir tonu: `readableAccent(context, family.base)` kısayolu
  /// (açık temada AA 4.5:1). Aile kullanan ekranlarda ham `family.base`/`family.light` metin rengi olarak KULLANILMAZ.
  static Color readableFamily(BuildContext context, AccentFamily family) => readableAccent(context, family.base);

  /// İptal / Geri / "Daha sonra" gibi **ikincil metin düğmesi** stili: soluk ([getTextMuted]) ön plan. Tema `TextButton`
  /// bağlantı rengidir (koyuda cyan, açıkta mavi); aynı iletişimde bağlantı rengindeki bir İptal birincil eylemle
  /// yarışıyordu ve ekrandan ekrana gri/cyan/mavi değişiyordu. Yalnız ön plan rengi verilir (boyut/şekil/yazı tipi temadan).
  ///
  /// ```dart
  /// TextButton(style: AppTheme.quietTextButtonStyle(context), onPressed: close, child: const Text('İptal'))
  /// ```
  static ButtonStyle quietTextButtonStyle(BuildContext context) => TextButton.styleFrom(
        foregroundColor: getTextMuted(context),
        disabledForegroundColor: getTextMuted(context).withValues(alpha: 0.5),
      );

  /// Standart kart süslemesi (Neon Glass, şartname §2.2/§3.2): **camsı** yüzey — dikey gradyan gövde, 1 px rim,
  /// yumuşak çevresel gölge (koyu/açık temada eşit kalite). İmza KORUNUR; tüm kartlar tek noktadan yükselir.
  ///
  /// * [accent] verilirse kenar o renkten türetilir; [emphasized] (aktif/vurgulu kart) kenarı `accent@0.55`
  ///   1.4 px yapar ve kartın sol-üstüne **radyal parıltı** (BoxShadow DEĞİL) ekler: koyuda `accent@0.14`
  ///   ([AppGlass.accentGlowAlpha]), açıkta `accent@0.12` ([AppGlass.accentGlowAlphaLight]; geniş kartlarda "bulut
  ///   lekesi" olmasın). Vurgulu olmayan accent'li kartın gövde tonu çok hafiftir (koyu 0.02, açık 0.05).
  /// * [radius] varsayılanı kart yarıçapı [AppRadius.card] (20).
  /// * `BoxDecoration.color` kart yüzey rengi ([getCardColor]) olarak KALIR (opak gradyanın altında taban renk;
  ///   kart rengini okuyan kod/test için); görünen yüzey gradyandır.
  /// * Gradyan taşıyan rim (sol-üst → sağ-alt) `BoxDecoration` ile çizilemez: bu süsleme tek renkli rim
  ///   ([SurfaceTokens.rimSolid]) kullanır; gradyan rim [SurfaceCard]'dadır.
  static BoxDecoration cardDecoration(
    BuildContext context, {
    Color? accent,
    double radius = AppRadius.card,
    bool emphasized = false,
  }) =>
      glassDecoration(context, accent: accent, radius: radius, emphasized: emphasized);

  /// [cardDecoration]'ın çekirdeği. [solidRim] `false` ise kenarlık çizilmez ([SurfaceCard] gradyan rim'i
  /// kendisi boyar).
  static BoxDecoration glassDecoration(
    BuildContext context, {
    Color? accent,
    double radius = AppRadius.card,
    bool emphasized = false,
    bool solidRim = true,
  }) {
    final dark = isDark(context);
    final t = SurfaceTokens.of(dark ? Brightness.dark : Brightness.light);

    final Gradient gradient;
    if (accent != null && emphasized) {
      gradient = RadialGradient(
        center: const Alignment(-0.75, -1.0),
        radius: 1.55,
        colors: [
          Color.alphaBlend(
            accent.withValues(alpha: dark ? AppGlass.accentGlowAlpha : AppGlass.accentGlowAlphaLight),
            t.cardTop,
          ),
          t.cardTop,
          t.cardBottom,
        ],
        stops: const [0.0, 0.5, 1.0],
      );
    } else {
      gradient = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          accent == null
              ? t.cardTop
              : Color.alphaBlend(
                  accent.withValues(alpha: dark ? AppGlass.accentTintAlphaDark : AppGlass.accentTintAlphaLight),
                  t.cardTop,
                ),
          t.cardBottom,
        ],
      );
    }

    final Border? border;
    if (!solidRim) {
      border = null;
    } else if (accent != null) {
      border = Border.all(
        color: accent.withValues(alpha: emphasized ? AppGlass.accentRimAlpha : 0.28),
        width: emphasized ? AppGlass.accentRimWidth : 1.0,
      );
    } else {
      border = Border.all(color: t.rimSolid, width: 1.0);
    }

    return BoxDecoration(
      color: getCardColor(context),
      gradient: gradient,
      borderRadius: BorderRadius.circular(radius),
      border: border,
      boxShadow: [BoxShadow(color: t.shadow, blurRadius: t.shadowBlur, offset: t.shadowOffset)],
    );
  }

  // --- TEMALAR ---------------------------------------------------------------------------------

  static ThemeData get darkTheme => _build(Brightness.dark);
  static ThemeData get lightTheme => _build(Brightness.light);

  /// Sayfa geçişi: tüm platformlarda "fade through" (≤ 280 ms).
  static const PageTransitionsTheme pageTransitions = PageTransitionsTheme(
    builders: <TargetPlatform, PageTransitionsBuilder>{
      TargetPlatform.android: FadeThroughPageTransitionsBuilder(),
      TargetPlatform.iOS: FadeThroughPageTransitionsBuilder(),
      TargetPlatform.fuchsia: FadeThroughPageTransitionsBuilder(),
      TargetPlatform.linux: FadeThroughPageTransitionsBuilder(),
      TargetPlatform.macOS: FadeThroughPageTransitionsBuilder(),
      TargetPlatform.windows: FadeThroughPageTransitionsBuilder(),
    },
  );

  /// Koyu ve açık tema AYNI kurucudan çıkar: bileşen temaları eşit kalitede ve birbirine paralel kalır.
  static ThemeData _build(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final t = SurfaceTokens.of(brightness);
    final baseTextTheme = (dark ? ThemeData.dark() : ThemeData.light()).textTheme;
    final fg = dark ? textPrimary : textPrimaryLight;
    final muted = dark ? textMuted : textMutedLight;
    final page = dark ? bgDark : bgLight;
    // Odak halkası / bağlantı rengi: koyuda parlak cyan, açıkta AA kontrastlı koyu cyan.
    final focus = dark ? AppFamilies.cyan.base : AppFamilies.cyan.deep;
    final linkColor = dark ? AppFamilies.cyan.light : AppFamilies.sky.deep;
    final surface = dark ? const Color(0xFF141E33) : surfaceLight;
    final rim = t.rimSolid;
    const stadium = StadiumBorder();
    // Alan dolgusu ve dinlenme kenarı. Kenar, dolguya ve kart yüzeyine (üst ucu dahil) karşı ≥ 3:1'dir
    // (koyu: #66768F ≈ 3.9 / 3.6 / 3.2; açık: #7F8EA3 ≈ 3.2 / 3.3 / 3.0; testle pinli).
    final fieldFill = dark ? fieldFillDark : fieldFillLight;
    final fieldBorder = dark ? fieldBorderDark : fieldBorderLight;
    // Hata metni/etiketi: ham `error` (#EF4444) açık temada beyazda ≈ 3.8:1'dir; okunur ton (AA).
    final danger = readableAccentOn(brightness, accentRed);
    // Çerçeveli düğme kenarı (tek ton kuralı): koyuda marka camgöbeği, açıkta sky ailesi.
    final outline = outlinedBorderOn(brightness, dark ? AppFamilies.cyan : AppFamilies.sky);

    // ElevatedButton ve FilledButton'ın ORTAK birincil stili: hap, saydam Material zemini (gradyanı
    // `PrimaryButtonSurface` çizer), beyaz metin/simge (pasifte opak `muted`). Boyut ve dolgu çağıran tarafından verilir.
    ButtonStyle primaryButtonStyle({required Size minimumSize, required EdgeInsetsGeometry padding}) => ButtonStyle(
          minimumSize: WidgetStatePropertyAll(minimumSize),
          padding: WidgetStatePropertyAll(padding),
          shape: const WidgetStatePropertyAll(stadium),
          // Dış renkli gölge: Material yükseltme gölgesi (saydam zemin üstünde yalnız dışarıda görünür). `backgroundBuilder`
          // olan düğmede Material içeriği şekle KIRPAR (`Clip.antiAlias`; FilledButton/`ElevatedButton.icon` varsayılanı
          // `Clip.none` olduğundan yalnız onlarda yüzeyin kendi BoxShadow'u görünürdü): yükseltme gölgesi kırpmanın DIŞINDA
          // çizilir ve ElevatedButton'da da renkli gölge görünür. Basınç/pasif geçişi ANINDA (animationDuration sıfır).
          elevation: WidgetStateProperty.resolveWith(ToneButtonSurface.elevationFor),
          shadowColor: WidgetStatePropertyAll(AppFamilies.sky.base),
          animationDuration: Duration.zero,
          surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
          backgroundColor: const WidgetStatePropertyAll(Colors.transparent),
          // Pasif etiket/simge: OPAK `muted` (eskiden muted@0.75 ≈ 3.3:1 idi). Pasif yüzey de OPAK cam ([ToneButtonSurface]
          // `disabledFill`): etiket kendi zemininde ≥ 4.5:1 (açık ≈ 5.6, koyu ≈ 4.9) ve devre izleri etiketin altından geçmez.
          foregroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.disabled) ? muted : Colors.white,
          ),
          overlayColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.pressed)) return Colors.white.withValues(alpha: 0.16);
            if (states.contains(WidgetState.focused)) return Colors.white.withValues(alpha: 0.12);
            if (states.contains(WidgetState.hovered)) return Colors.white.withValues(alpha: 0.08);
            return null;
          }),
          iconColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.disabled) ? muted : Colors.white,
          ),
          backgroundBuilder: (context, states, child) =>
              PrimaryButtonSurface.forButton(context, states, child, dark: dark),
        );

    final inter = GoogleFonts.interTextTheme(baseTextTheme).apply(
      bodyColor: fg,
      displayColor: fg,
    );
    // Düğme etiketi tipografisi TEMA düzeyinde (`labelLarge`) ayarlanır; `ButtonStyle.textStyle` VERİLMEZ:
    // gerek yok (M3 varsayılanı labelLarge'ı kullanır) ve null olmayan düğme `textStyle`ı, tema `ThemeData.lerp`
    // ile varsayılan temaya/temadan geçerken `AnimatedDefaultTextStyle` "farklı inherit" hatası verir.
    // Etiket KALIN (w700): düğmeler arası tipografi tek yerden verilir (eskiden w500 idi ve çağrı yerleri kendi kalın
    // `TextStyle`larını geçersiz kılıyordu: aynı ekranda 'Giriş Yap' bold iken 'Parmak İzi ile Aç' medium görünüyordu).
    // AİLE değişmez (google_fonts `Inter_500` dosyası): yeni Inter ağırlığı = yeni google_fonts indirmesi OLMAZ (PF-14
    // kararı hâlâ bekliyor); kalın görünüm uygulamadaki diğer kalın metinler gibi sentezlenir (gerçek Inter 700 dosyasına
    // geçilirse yalnız `GoogleFonts.inter(fontWeight: w700)` ile bu satır güncellenir). `labelLarge` düğmelerin yanında
    // çip, sekme, snackbar eylemi ve açılır menü öğelerinin de varsayılan etiket stilidir: onlar da kalın olur.
    final textTheme = inter.copyWith(
      labelLarge: inter.labelLarge?.copyWith(fontSize: 15, fontWeight: FontWeight.w700, letterSpacing: 0.2),
    );
    // AppBar ve diyalog BAŞLIKLARI: `AppBarTheme/DialogThemeData.titleTextStyle` aile vermezse AppBar/AlertDialog bunu
    // `DefaultTextStyle` olarak YERİNE koyar (birleştirmez) ve başlık platform yazı tipine (Android Roboto / iOS SF)
    // düşer, gövde ise Inter kalır. Burada gövdeyle AYNI aile (google_fonts adı + yedek) verilir; boyut/ağırlık
    // (18 sp, w700) ve `inherit` değişmez. Yeni Inter ağırlığı İSTENMEZ: aile `bodyMedium`dan gelir, kalın başlık
    // uygulamanın geri kalanındaki kalın metinlerle aynı biçimde çizilir.
    TextStyle titleStyle() => TextStyle(
          fontFamily: inter.bodyMedium?.fontFamily,
          fontFamilyFallback: inter.bodyMedium?.fontFamilyFallback,
          fontSize: 18,
          fontWeight: FontWeight.w700,
          color: fg,
        );
    // NOT: çip/snackbar/düğme metin stilleri tema kurulurken `TextStyle` olarak SABİTLENMEZ: yazı tipi ve ölçek
    // KULLANIM anında temanın (çağıranın `copyWith(textTheme:)`ı dahil) metin temasından çözülür. Çip etiketi de
    // M3 varsayılanı `labelLarge`'ı kullanır (aile taşımayan açık bir `labelStyle` etiketi platform yazı tipine
    // düşürürdü); renkler `colorScheme.onSurfaceVariant/onSecondaryContainer` varsayılanlarından gelir ve
    // aşağıdaki çip zeminlerinde AA kontrastlıdır.
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      scaffoldBackgroundColor: Colors.transparent,
      pageTransitionsTheme: pageTransitions,
      // Çekmece: koyuda sayfadan bir kademe açık yüzey + sağ kenarda yuvarlak köşe ve 1 px rim (perdenin altında
      // kenar kaybolmasın); perde rengi diyalog perdesiyle aynı (lacivert tonlu).
      drawerTheme: DrawerThemeData(
        backgroundColor: dark ? surfaceDark : page,
        surfaceTintColor: Colors.transparent,
        scrimColor: dark ? AppGlass.scrimDark : AppGlass.scrimLight,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: const BorderRadiusDirectional.horizontal(end: Radius.circular(AppRadius.sheet)),
          side: BorderSide(color: rim),
        ),
      ),
      colorScheme: dark
          ? ColorScheme.dark(
              primary: primaryBlue,
              onPrimary: Colors.white,
              secondary: primaryBlueLight,
              surface: surfaceDark,
              onSurface: textPrimary,
              error: accentRed,
              inverseSurface: const Color(0xFF1B2740),
              onInverseSurface: Colors.white,
              inversePrimary: AppFamilies.cyan.light,
              // Seçili çip zemini/etiketi (M3 `secondaryContainer` çifti): cyan tonlu koyu cam, AA kontrast.
              secondaryContainer: const Color(0xFF17465C),
              onSecondaryContainer: const Color(0xFFE6FBFF),
            )
          : ColorScheme.light(
              primary: primaryBlue,
              onPrimary: Colors.white,
              secondary: primaryBlueLight,
              surface: surfaceLight,
              onSurface: textPrimaryLight,
              error: accentRed,
              inverseSurface: const Color(0xFF111B30),
              onInverseSurface: Colors.white,
              inversePrimary: AppFamilies.cyan.light,
              secondaryContainer: const Color(0xFFDCE8FD),
              onSecondaryContainer: const Color(0xFF0B1B3D),
            ),
      textTheme: textTheme,
      // Şeffaf Neon Glass çubuk: kaydırınca M3 "scrolled-under" tonu YOK. `backgroundColor` saydam olsa da varsayılan
      // `scrolledUnderElevation` (3) + `surfaceTint` saydam zemine yarı saydam bir ton bindirir: açıkta lavanta bant, koyuda
      // ton sıçraması (kaydırılmış sihirbaz/ayar sayfaları; yalnız `NeonAppBar` yerelde kapatıyordu). Tema düzeyinde
      // kapatılır: uygulamadaki TÜM düz `AppBar`lar da aynı olur.
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        foregroundColor: fg,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: titleStyle(),
        iconTheme: IconThemeData(color: fg),
      ),
      cardTheme: CardThemeData(
        color: dark ? const Color(0xE6172238) : cardLight,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.card),
          side: BorderSide(color: dark ? AppFamilies.cyan.base.withValues(alpha: 0.22) : rim, width: 1.0),
        ),
      ),

      // --- Düğmeler ---------------------------------------------------------------------------
      // Birincil düğme: TÜR ElevatedButton KALIR (testler `find.widgetWithText(ElevatedButton, …)` kullanır).
      // FilledButton AYNI gradyan/cam dilini kullanır (tür DEĞİŞMEZ; yalnız boyut/dolgu farklıdır): ikisi de
      // `PrimaryButtonSurface` ile çizilir ve düğmenin YEREL `backgroundColor`/`shape`/`foregroundColor`ını okur.
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: primaryButtonStyle(
          minimumSize: const Size(64, 52),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: primaryButtonStyle(
          minimumSize: const Size(64, 48),
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: ButtonStyle(
          minimumSize: const WidgetStatePropertyAll(Size(64, 48)),
          padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 22, vertical: 12)),
          shape: const WidgetStatePropertyAll(stadium),
          foregroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.disabled) ? muted.withValues(alpha: 0.6) : linkColor,
          ),
          // Kenar: `accentOutlinedButtonStyle` ile AYNI tek ton kuralı ([outlinedBorderOn]; ≥ 3:1 her yüzeyde). Varsayılan aile
          // koyuda marka camgöbeği, açıkta sky: açıkta tema düğmesi ile `accentOutlinedButtonStyle(sky)` birebir aynı çerçeve
          // tonunu verir (eskiden sky@0.70 ≈ #76A8F9 ≈ 2.4:1 iken aynı ekrandaki accentOutlined koyu #1D4ED8 idi).
          side: WidgetStateProperty.resolveWith(
            (states) => BorderSide(color: states.contains(WidgetState.disabled) ? rim : outline, width: 1.5),
          ),
          overlayColor: WidgetStatePropertyAll(focus.withValues(alpha: 0.12)),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: ButtonStyle(
          minimumSize: const WidgetStatePropertyAll(Size(48, 48)),
          shape: const WidgetStatePropertyAll(stadium),
          foregroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.disabled) ? muted.withValues(alpha: 0.6) : linkColor,
          ),
          overlayColor: WidgetStatePropertyAll(focus.withValues(alpha: 0.12)),
        ),
      ),

      // --- Anahtar / kaydırıcı ----------------------------------------------------------------
      // Switch TÜRÜ değişmez (testler `find.byType(Switch)` kullanır); orb dili renklerle yaklaştırılır: beyaz "inci"
      // başparmak, sabit zümrüt iz, basınçta/odakta zümrüt (kapalıda slate) halka. Salt-okunur (onChanged null) AÇIK
      // anahtar GRİ'ye düşmez: soluk zümrüt iz + açık başparmak (değer okunur; kapalı pasif anahtardan ayrışır).
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          if (states.contains(WidgetState.disabled)) {
            if (selected) return dark ? const Color(0xFFD5DEEB) : Colors.white;
            return dark ? const Color(0xFF64748B) : const Color(0xFFCBD5E1);
          }
          if (selected) return Colors.white;
          return dark ? const Color(0xFFCBD5E1) : Colors.white;
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          if (states.contains(WidgetState.disabled)) {
            if (selected) return AppFamilies.emerald.base.withValues(alpha: 0.42);
            return dark ? const Color(0x33FFFFFF) : const Color(0x1F0B1016);
          }
          if (selected) return AppFamilies.emerald.base;
          return dark ? const Color(0xFF334155) : const Color(0xFFCBD5E1);
        }),
        trackOutlineColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return Colors.transparent;
          if (states.contains(WidgetState.disabled)) return dark ? const Color(0x33FFFFFF) : const Color(0x330B1016);
          return dark ? const Color(0xFF5B6B84) : const Color(0xFF8493A8);
        }),
        overlayColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.disabled)) return null;
          final base = states.contains(WidgetState.selected)
              ? AppFamilies.emerald.base
              : (dark ? Colors.white : AppFamilies.slate.base);
          if (states.contains(WidgetState.pressed)) return base.withValues(alpha: 0.24);
          if (states.contains(WidgetState.focused)) return base.withValues(alpha: 0.20);
          if (states.contains(WidgetState.hovered)) return base.withValues(alpha: 0.12);
          return null;
        }),
      ),
      // Kaydırıcı: pasif (kalan aralık) iz yarı saydam dolgu + 1 px "oluk" kenarı. Dolgu zemine yakındır (≈1.4–1.7:1),
      // kenar ise karta/sayfaya karşı ≥ 3:1'dir (WCAG 1.4.11): izin uzunluğu/ucu okunur (eskiden %0'da yalnız
      // başparmak görünüyordu). Kenar rengi `GlowSliderTrackShape.inactiveRim`dedir.
      sliderTheme: SliderThemeData(
        trackHeight: 8,
        activeTrackColor: AppFamilies.sky.base,
        inactiveTrackColor: dark ? const Color(0x29FFFFFF) : const Color(0x47647489), // white@0.16 / slate@0.28
        disabledActiveTrackColor: dark ? const Color(0xFF475569) : const Color(0xFF94A3B8),
        disabledInactiveTrackColor: dark ? const Color(0x14FFFFFF) : const Color(0x24647489),
        thumbColor: AppFamilies.sky.base,
        disabledThumbColor: dark ? const Color(0xFF64748B) : const Color(0xFFA3B1C4),
        overlayColor: AppFamilies.sky.base.withValues(alpha: 0.14),
        trackShape: dark
            ? const GlowSliderTrackShape(inactiveRim: Color(0x61FFFFFF)) // white@0.38
            : const GlowSliderTrackShape(inactiveRim: Color(0xFF7F8EA3)),
        // Açıkta başparmağa ince koyu dış halka: beyaz rim'i beyaz kartta görünmez, açık tonlu başparmak kartta kaybolurdu.
        thumbShape: OrbSliderThumbShape(outlined: !dark),
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 24),
        tickMarkShape: SliderTickMarkShape.noTickMark,
      ),

      // --- Çip / snackbar / sheet / diyalog ---------------------------------------------------
      // Çip: SEÇİLİ durum yalnız dolgu rengine bırakılmaz (açık temada seçili/seçilmemiş zemin farkı ≈ 1.1:1'di):
      // seçili çipin kenarı odak halkasıyla aynı cyan ve 1.5 px (≥ 3:1); seçilmemiş çipin kenarı belirgin ama ince
      // (1 px). Kenar `WidgetStateBorderSide` ile durumdan çözülür. Çağrı yerleri kendi `selectedColor/side/shape`
      // vermek yerine bu temayı kullanmalıdır.
      chipTheme: ChipThemeData(
        shape: stadium,
        side: WidgetStateBorderSide.resolveWith((states) {
          if (states.contains(WidgetState.disabled)) {
            return BorderSide(color: dark ? const Color(0x14FFFFFF) : const Color(0x140B1016));
          }
          if (states.contains(WidgetState.selected)) return BorderSide(color: focus, width: 1.5);
          return BorderSide(color: dark ? const Color(0x38FFFFFF) : const Color(0x330B1016));
        }),
        backgroundColor: dark ? const Color(0x0FFFFFFF) : const Color(0x0A0B1016),
        selectedColor: dark ? const Color(0xFF17465C) : const Color(0xFFDCE8FD), // = colorScheme.secondaryContainer
        disabledColor: dark ? const Color(0x08FFFFFF) : const Color(0x06000000),
        checkmarkColor: fg,
        padding: const EdgeInsets.symmetric(horizontal: 4),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        // Yüzen kutunun yan boşluğu dar tutulur (varsayılan 15): büyük yazı ölçeğinde ileti genişliği korunur.
        insetPadding: const EdgeInsets.fromLTRB(8, 5, 8, 10),
        // Renkler `colorScheme.inverseSurface/onInverseSurface/inversePrimary` ile verilir (M3 varsayılanları):
        // iletinin metin stili (aile/boyut/ölçek) varsayılanla AYNI kalır.
        closeIconColor: Colors.white70,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.r16),
          side: BorderSide(color: Colors.white.withValues(alpha: 0.14)),
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: surface,
        modalBackgroundColor: surface,
        modalBarrierColor: dark ? AppGlass.scrimDark : AppGlass.scrimLight,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        modalElevation: 0,
        clipBehavior: Clip.antiAlias,
        dragHandleColor: dark ? const Color(0xFF475569) : const Color(0xFFB4C0D0),
        shape: RoundedRectangleBorder(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(AppRadius.sheet)),
          side: BorderSide(color: rim),
        ),
      ),
      // Diyalog kabuğu TEK yerden: yan boşluk 16 dp ve en az 328 dp (360 dp telefonda her diyalog 328 dp; eskiden
      // AlertDialog 280 dp'ydi ve özel diyaloglar 323-328 dp: üç ayrı kabuk, dar kabukta etiket/başlık kesilmeleri),
      // üst sınır 560 dp. Perde lacivert tonlu (açık temada mat gri sis YOK). Yarıçap [AppRadius.dialog].
      dialogTheme: DialogThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        barrierColor: dark ? AppGlass.scrimDark : AppGlass.scrimLight,
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
        constraints: const BoxConstraints(minWidth: 328, maxWidth: 560),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.dialog),
          side: BorderSide(color: dark ? AppFamilies.cyan.base.withValues(alpha: 0.26) : rim, width: 1.0),
        ),
        titleTextStyle: titleStyle(),
      ),
      // Giriş alanı: dinlenme kenarı alan dolgusuna VE kart yüzeyine karşı ≥ 3:1 (WCAG 1.4.11; eskiden ≈ 1.4–1.7:1:
      // açık temada beyaz üstü beyaz alanın sınırı görünmüyordu). Etiket/ipucu/simge odak dışında SOLUK (muted): boş
      // alan "dolu" gibi okunmasın (etiket eskiden `colorScheme.onSurface` = birincil metin rengindeydi). Hatada etiket
      // ve iletisi AA kontrastlı tehlike tonunda ([danger]); pasifte renk M3 varsayılanına bırakılır.
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: fieldFill,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.r12),
          borderSide: BorderSide(color: fieldBorder),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.r12),
          borderSide: BorderSide(color: fieldBorder),
        ),
        disabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.r12),
          borderSide: BorderSide(color: dark ? cardBorder : cardBorderLight),
        ),
        // Odak halkası: cyan (koyuda parlak, açıkta AA kontrastlı koyu ton), 2 px.
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.r12),
          borderSide: BorderSide(color: focus, width: 2),
        ),
        // Satır içi etiket (boş alan): soluk. Durum-bağımlı stil; yalnız renk verilir (aile/boyut varsayılandan
        // MERGE edilir). Hata/pasifte renk verilmez (M3 hata/pasif rengi korunur).
        labelStyle: WidgetStateTextStyle.resolveWith((states) {
          if (states.contains(WidgetState.disabled)) return const TextStyle();
          return TextStyle(color: states.contains(WidgetState.error) ? danger : muted);
        }),
        // Yüzen etiket: odakta cyan (halkayla aynı renk), odak dışında soluk, hatada okunur tehlike tonu.
        floatingLabelStyle: WidgetStateTextStyle.resolveWith((states) {
          if (states.contains(WidgetState.disabled)) return const TextStyle();
          if (states.contains(WidgetState.error)) return TextStyle(color: danger);
          return TextStyle(color: states.contains(WidgetState.focused) ? focus : muted);
        }),
        hintStyle: TextStyle(color: muted, fontSize: 13),
        // Alt metinler: yardımcı/sayaç/önek-sonek soluk (eskiden `onSurface` = birincil metin rengindeydi: değerle aynı
        // vurguda), hata iletisi AA kontrastlı tehlike tonunda.
        helperStyle: TextStyle(color: muted),
        counterStyle: TextStyle(color: muted),
        prefixStyle: TextStyle(color: muted),
        suffixStyle: TextStyle(color: muted),
        errorStyle: TextStyle(color: danger),
        prefixIconColor: WidgetStateColor.resolveWith(
          (states) => states.contains(WidgetState.disabled)
              ? muted.withValues(alpha: 0.5)
              : (states.contains(WidgetState.focused) ? focus : muted),
        ),
        suffixIconColor: WidgetStateColor.resolveWith(
          (states) => states.contains(WidgetState.disabled)
              ? muted.withValues(alpha: 0.5)
              : (states.contains(WidgetState.focused) ? focus : muted),
        ),
      ),
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: focus,
        selectionHandleColor: focus,
        selectionColor: focus.withValues(alpha: 0.30),
      ),
      dividerTheme: DividerThemeData(
        color: dark ? cardBorder : cardBorderLight,
        thickness: 1,
      ),
      tabBarTheme: TabBarThemeData(
        labelColor: fg,
        unselectedLabelColor: muted,
        indicatorColor: focus,
        dividerColor: Colors.transparent,
      ),
      // FAB: hap (genişletilmiş FAB'ın köşeli M3 dikdörtgeni birincil düğmenin hapıyla uyuşmuyordu) + birincil renk +
      // ince parlak kenar. Bu tema HAM `FloatingActionButton` için düz YEDEK görünümdür: gradyan/parlak yüzey tema ile
      // verilemez (FAB `ButtonStyle.backgroundBuilder` desteklemez). Birincil FAB için [AccentFab] kullanılır
      // (`lib/ui/widgets/accent_fab.dart`): şeffaf FAB + [ToneButtonSurface] gradyanı + cila + 1 px kenar + renkli parıltı;
      // canlı tek kullanım `Hesap Ekle` (`btn_add_account`). Burada rengin primaryBlue + hap kalması pinlidir.
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: primaryBlue,
        foregroundColor: Colors.white,
        splashColor: Colors.white.withValues(alpha: 0.20),
        elevation: 4,
        focusElevation: 5,
        hoverElevation: 6,
        highlightElevation: 2,
        shape: StadiumBorder(side: BorderSide(color: Colors.white.withValues(alpha: 0.28))),
        extendedPadding: const EdgeInsets.symmetric(horizontal: 22),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.r16),
          side: BorderSide(color: rim),
        ),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(color: focus),
    );
  }
}

/// Temanın düğme yüzeyi (`ElevatedButton` ve `FilledButton` için `ButtonStyle.backgroundBuilder` çıktısı): varsayılan
/// mavi → koyu cyan gradyan (beyaz metinle AA), stadium, üst cila (sheen), 1 px parlak kenar ve renkli gölge.
/// Basınçta (`pressed`) ölçek 0.97 ve gölge sönümü ANINDA uygulanır (tween yok). Devre dışıyken düz cam yüzey.
///
/// **Yerel stili okur (WP-V8):** düğmenin kendi `style`ı ([localStyle]) opak bir `backgroundColor` taşıyorsa (ve bu
/// tema birincil rengi [AppTheme.primaryBlue] değilse) gradyan o rengin ailesinden çizilir (açık ton → ana/derin ton,
/// gölge o renk, metin/simge mürekkebi AA); yerel `shape` yarıçapı yüzeye uygulanır; yerel `foregroundColor` /
/// `iconColor` / `disabledBackgroundColor` varsa ona saygı gösterilir. Yerel renk yoksa varsayılan görünüm AYNEN
/// kalır. Çizimin tamamı ortak [ToneButtonSurface]'tedir (accent/yıkıcı stiller de aynı widget'ı kullanır).
class PrimaryButtonSurface extends StatelessWidget {
  const PrimaryButtonSurface({super.key, required this.states, required this.dark, required this.child, this.localStyle});

  /// Tema `backgroundBuilder`'ının köprüsü: builder'ın `context`'i düğmenin durum nesnesinin bağlamıdır
  /// (`_ButtonStyleState.build`), dolayısıyla `context.widget` düğmenin kendisidir ve `style` YEREL stildir.
  /// Düğme olmayan bir bağlamda (Flutter'ın gelecekteki bir değişikliği dahil) yerel stil `null` sayılır ve
  /// varsayılan görünüm çizilir.
  static Widget forButton(BuildContext buttonContext, Set<WidgetState> states, Widget? child, {required bool dark}) {
    final widget = buttonContext.widget;
    return PrimaryButtonSurface(
      states: states,
      dark: dark,
      localStyle: widget is ButtonStyleButton ? widget.style : null,
      child: child,
    );
  }

  final Set<WidgetState> states;
  final bool dark;
  final Widget? child;

  /// Düğmenin YEREL `style`ı (`null` = yerel stil yok: varsayılan görünüm).
  final ButtonStyle? localStyle;

  /// Gradyan uçları: beyaz metinle ≥ 4.5:1 (testle doğrulanır).
  static const Color gradientStart = AppTheme.primaryBlue;
  static const Color gradientEnd = Color(0xFF0E7490);

  /// Varsayılan (renksiz düğme) ton: sky → koyu cyan, sky gölge, beyaz mürekkep.
  static final ButtonTone primaryTone = ButtonTone(
    name: 'primary',
    start: gradientStart,
    end: gradientEnd,
    glow: AppFamilies.sky.base,
    ink: Colors.white,
  );

  @override
  Widget build(BuildContext context) => ToneButtonSurface.forStyle(
        style: localStyle,
        states: states,
        dark: dark,
        fallbackTone: primaryTone,
        fallbackColor: AppTheme.primaryBlue,
        child: child,
      );
}
