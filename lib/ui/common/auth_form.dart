import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../widgets/orb/orb.dart' show ProgressArc;

/// Servisin açtığı (davet bekleyen) ya da hiç şifre belirlenmemiş hesapla girişte yönlendirme (uyelik-10): giriş
/// `INVALID_CREDENTIALS`, telefon-OTP / sihirli bağlantı `ACCOUNT_PENDING` aldığında gösterilir.
const String kAccountActivationHint = 'Hesabınızı servis açtıysa ve hiç şifre belirlemediyseniz e-postadaki etkinleştirme '
    'bağlantısını kullanın ya da Şifremi unuttum ile şifre belirleyin.';

/// Kimlik doğrulama formlarının alan çerçeve renkleri (WP-F4).
///
/// Dinlenme halindeki çerçeve UI bileşeni kontrastını sağlar (şartname §5: >= 3:1). TEK KAYNAK: temanın alan çerçevesi
/// ([AppTheme.fieldBorderDark]/[AppTheme.fieldBorderLight]; `inputDecorationTheme` ile AYNI renk). Eskiden burada ayrı,
/// biraz daha soluk iki sabit vardı (koyuda kartın üst ucuna ≈ 2.75:1): auth alanları uygulamanın diğer alanlarından
/// silik kalıyordu.
abstract final class AuthFieldColors {
  static const Color restDark = AppTheme.fieldBorderDark;
  static const Color restLight = AppTheme.fieldBorderLight;

  /// Dinlenme çerçevesi.
  static Color rest(bool dark) => dark ? restDark : restLight;

  /// Kilitli (devre dışı) alan çerçevesi: dinlenme tonunun soluğu (kilitli alan etkin alandan daha vurgulu olmaz).
  static Color disabled(bool dark) => rest(dark).withValues(alpha: 0.5);

  /// Odak halkası (tema ile aynı): koyuda parlak cyan, açıkta AA kontrastlı koyu cyan.
  static Color focus(bool dark) => dark ? AppFamilies.cyan.base : AppFamilies.cyan.deep;
}

/// Kimlik doğrulama formları için ortak alan görünümü.
///
/// Zemin dolgusu ve imleç **temadan** gelir (`ThemeData.inputDecorationTheme`: koyu ve açık tema aynı kurucudan,
/// eşit kalitede). Çerçeveler burada da verilir ([AuthFieldColors]: dinlenme çerçevesi >= 3:1, odak halkası cyan
/// 2 px, hata/devre dışı hâlleri); etiket 14 sp soluk, ön ek simgesi soluk (odakta cyan, hatada kırmızı).
///
/// * **Etiket kısa tutulur**: kural/açıklama [helper]'a ya da [hint]'e yazılır. Boş alanda etiket alanın içinde
///   durur ve uzunsa "…" ile KESİLİRdi ("Şifre (En az 10 karakter)").
/// * [alwaysFloatLabel]: kod/PIN gibi ortalanmış girdilerde etiket kenarlıkta sabit ve ORTALI durur (yazmaya
///   başlayınca hiza sıçramaz; uzun etiket kesilmez). İpucu ([hint]) alanda hemen görünür.
/// * [label] boşsa (yalnız ipucu) alan etiketsizdir; [prefixIcon] da isteğe bağlıdır.
/// * [hasError] `true` ise alan, [errorText] olmadan da HATALI çizilir (kırmızı çerçeve — odakta 2 px —, etiket ve ön ek
///   simgesi kırmızı). Hata iletisi alanın altında ayrı bir bileşende ([InlineMessage]) duruyorsa kullanılır: yanlış girilen
///   alan odak halkası (cyan) yüzünden "geçerli" görünmez ve hata, alan altında ikinci bir satır yer tutmadan okunur.
///
/// [onDarkBackground] geriye uyum için durur; giriş ekranı temaya uyduğundan renkler her zaman temadan çözülür.
InputDecoration authInputDecoration(
  BuildContext context, {
  String? label,
  IconData? prefixIcon,
  Widget? suffixIcon,
  String? hint,
  String? helper,
  String? errorText,
  String? counterText,
  bool alwaysFloatLabel = false,
  bool hasError = false,
  bool onDarkBackground = false,
}) {
  final dark = AppTheme.isDark(context);
  final muted = AppTheme.getTextMuted(context);
  final focus = AuthFieldColors.focus(dark);
  final danger = AppTheme.dangerText(context);

  OutlineInputBorder outline(Color color, [double width = 1.0]) => OutlineInputBorder(
    borderRadius: BorderRadius.circular(AppRadius.r12),
    borderSide: BorderSide(color: color, width: width),
  );

  return InputDecoration(
    labelText: label,
    hintText: hint,
    helperText: helper,
    helperMaxLines: 3,
    errorText: errorText,
    errorMaxLines: 3,
    counterText: counterText,
    labelStyle: TextStyle(color: hasError ? danger : muted, fontSize: 14),
    // Yüzen etiket: `labelStyle`i EZER (temanın durum-bağımlı stili de burada YENİDEN kurulur; dekorasyon düzeyi verilince
    // temanınki devreye girmez). Odakta cyan, odak dışında soluk, hatada (alan hatası ya da [hasError]) kırmızı; KİLİTLİ
    // alanda M3 pasif rengi (onSurface@.38 ≈ 2.4:1: kodun gönderildiği numaranın etiketi okunmuyordu) yerine okunur soluk ton.
    floatingLabelStyle: WidgetStateTextStyle.resolveWith((states) {
      if (hasError || states.contains(WidgetState.error)) return TextStyle(color: danger);
      if (states.contains(WidgetState.disabled)) return TextStyle(color: muted.withValues(alpha: 0.85));
      return TextStyle(color: states.contains(WidgetState.focused) ? focus : muted);
    }),
    helperStyle: TextStyle(color: muted, fontSize: 12),
    errorStyle: TextStyle(color: danger, fontSize: 12),
    floatingLabelBehavior: alwaysFloatLabel ? FloatingLabelBehavior.always : null,
    floatingLabelAlignment: alwaysFloatLabel ? FloatingLabelAlignment.center : null,
    prefixIcon: prefixIcon == null ? null : Icon(prefixIcon, size: 22),
    prefixIconColor: WidgetStateColor.resolveWith((states) {
      if (hasError || states.contains(WidgetState.error)) return danger;
      if (states.contains(WidgetState.focused)) return focus;
      return muted;
    }),
    suffixIcon: suffixIcon,
    border: outline(hasError ? danger : AuthFieldColors.rest(dark)),
    enabledBorder: outline(hasError ? danger : AuthFieldColors.rest(dark)),
    disabledBorder: outline(AuthFieldColors.disabled(dark)),
    focusedBorder: outline(hasError ? danger : focus, 2),
    errorBorder: outline(danger),
    focusedErrorBorder: outline(danger, 2),
  );
}

/// Altı haneli kod / PIN alanı görünümü ([authCodeTextStyle] ile birlikte): ortalı büyük rakamlar.
///
/// Etiket kenarlıkta sabit ve ORTALI durur ([authInputDecoration] `alwaysFloatLabel`): yazmaya başlayınca hiza
/// sıçramaz, 1.5 yazı ölçeğinde "Doğrulama Ko…" gibi kesilmez. Ön ek simgesini dengelemek için sağda aynı genişlikte
/// boş alan vardır: rakamlar ve etiket alanın tam ortasındadır. İpucu rakamlarla aynı boyda/aralıktadır.
///
/// [prefixIcon]: üç kod/PIN alanı (SMS kodu, kurtarma kodu, servis PIN'i) TEK glifi paylaşır (`pin_outlined`; eskiden
/// ilk ikisi parola maskesi `password_rounded` kullanıyordu: sayısal bir kod için yanlış okunuyordu). [hasError]:
/// bkz. [authInputDecoration].
InputDecoration authCodeInputDecoration(
  BuildContext context, {
  required String label,
  required String hint,
  IconData prefixIcon = Icons.pin_outlined,
  bool hasError = false,
}) {
  return authInputDecoration(
    context,
    label: label,
    hint: hint,
    prefixIcon: prefixIcon,
    suffixIcon: const SizedBox(width: 48, height: 48),
    alwaysFloatLabel: true,
    counterText: '',
    hasError: hasError,
  ).copyWith(hintStyle: TextStyle(color: AppTheme.getTextMuted(context).withValues(alpha: 0.7), fontSize: 22, letterSpacing: 8));
}

/// [authCodeInputDecoration] alanının girilen metin stili (22 sp kalın, geniş harf aralığı).
TextStyle authCodeTextStyle(BuildContext context) =>
    TextStyle(color: AppTheme.getTextPrimary(context), fontSize: 22, fontWeight: FontWeight.bold, letterSpacing: 8);

/// Hatalı kod iletisinin "Kalan deneme: N." eki. Sözcükler BÖLÜNMEYEN boşlukla bağlanır: ileti iki satıra sarılırken
/// "2." tek başına ikinci satırda yetim kalmaz (ek bir bütün olarak alt satıra iner). Kalan hak TEK yerde (iletinin
/// içinde) verilir; alan altında ayrıca ikinci bir "Kalan deneme hakkı" satırı yoktur.
String remainingAttemptsText(int remaining) => 'Kalan deneme: $remaining.';

/// Parola alanındaki göster/gizle düğmesi (çizgisel simge: ön ek simgeleriyle aynı dil).
Widget passwordVisibilityButton({
  required BuildContext context,
  required bool obscured,
  required VoidCallback onToggle,
  bool onDarkBackground = false,
  Key? key,
}) {
  return IconButton(
    key: key,
    tooltip: obscured ? 'Şifreyi göster' : 'Şifreyi gizle',
    icon: Icon(
      obscured ? Icons.visibility_off_outlined : Icons.visibility_outlined,
      size: 20,
      color: AppTheme.getTextMuted(context),
    ),
    onPressed: onToggle,
  );
}

/// Yükleme göstergeli birincil düğme içeriği: marka yayı ([ProgressArc]; `MotionMode.off`/"hareketi azalt"ta
/// statik yay). Renk, düğmenin pasif (yükleniyor) cam yüzeyinde okunur: koyuda açık cyan, açıkta koyu mavi.
/// Ekran okuyucu için "Yükleniyor" etiketi taşır. [color] verilirse o kullanılır.
Widget buttonSpinner({Color? color}) => Builder(
  builder: (context) {
    final dark = AppTheme.isDark(context);
    return Semantics(
      label: 'Yükleniyor',
      child: ProgressArc(
        diameter: 20,
        strokeWidth: 2.4,
        color: color ?? (dark ? AppFamilies.cyan.light : AppFamilies.sky.deep),
        // Ağ zaman aşımı (≈30 sn) boyunca dönsün; sınır yalnız unutulmuş göstergeler içindir.
        maxSpin: const Duration(seconds: 60),
      ),
    );
  },
);

/// "Soru + bağlantı" satırı ("Hesabınız yok mu? Kayıt Olun"): bağlantının dokunma hedefi >= 48 dp
/// (şartname §5), metin ortalı; dar ekranda/büyük yazıda bağlantı alt satıra iner. Giriş ve kayıt ekranları
/// AYNI bileşeni kullanır (eskiden kayıttaki hedef ~33 dp'ydi).
class AuthLinkRow extends StatelessWidget {
  const AuthLinkRow({super.key, required this.prompt, required this.actionLabel, required this.onTap, this.actionKey});

  /// Soru metni (sonunda boşluk bırakılır).
  final String prompt;
  final String actionLabel;

  /// `null` ise bağlantı pasiftir (ör. işlem sürerken).
  final VoidCallback? onTap;

  /// Bağlantının (InkWell) test anahtarı.
  final Key? actionKey;

  @override
  Widget build(BuildContext context) {
    final muted = AppTheme.getTextMuted(context);
    final link = AppTheme.infoText(context);
    return Wrap(
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(prompt, style: TextStyle(color: muted, fontSize: 14)),
        InkWell(
          key: actionKey,
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppRadius.r8),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: AppTouch.minTarget),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Center(
                widthFactor: 1,
                child: Text(actionLabel, style: TextStyle(color: link, fontWeight: FontWeight.bold, fontSize: 14)),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Satır sonlarını DENGELER: metin birden çok satıra sarıyorsa, aynı satır sayısını koruyan en dar genişlik
/// kullanılır; böylece son satırda tek kelime ("mı?") kalmaz. Metin DEĞİŞMEZ (aynı [Text], aynı `data`: testlerin
/// `find.text`'i ve ekran okuyucu etkilenmez; bölünmeyen boşluk gibi bir karakter eklenmez).
///
/// Tek satıra sığan, [maxLines]'dan çok satıra sarılan ya da sınırsız genişlikte kurulan metinde normal [Text]
/// gibi davranır. Ölçüm yalnız başlıklar gibi kısa metinler içindir.
class BalancedText extends StatelessWidget {
  const BalancedText(this.data, {super.key, this.style, this.maxLines = 3, this.textAlign = TextAlign.start});

  final String data;
  final TextStyle? style;
  final int maxLines;
  final TextAlign textAlign;

  /// Aynı satır sayısını koruyan en dar genişlik (sığmıyorsa/tek satırsa [maxWidth]).
  @visibleForTesting
  static double balancedWidth({
    required String text,
    required TextStyle style,
    required TextDirection direction,
    required TextScaler scaler,
    required double maxWidth,
    int maxLines = 3,
  }) {
    if (!maxWidth.isFinite || maxWidth <= 0 || !text.contains(' ')) return maxWidth;
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: direction,
      textScaler: scaler,
    );
    try {
      painter.layout(maxWidth: maxWidth);
      final lines = painter.computeLineMetrics().length;
      if (lines <= 1 || lines > maxLines) return maxWidth;
      var lo = 0.0;
      var hi = maxWidth;
      for (var i = 0; i < 10; i++) {
        final mid = (lo + hi) / 2;
        painter.layout(maxWidth: mid);
        if (painter.computeLineMetrics().length <= lines) {
          hi = mid;
        } else {
          lo = mid;
        }
      }
      // Ölçüm/çizim yuvarlama payı + yazı tipi payı (yazı tipi ilk karede yedek aileyle ölçülmüş olabilir; gerçek
      // yazı tipi yüklenince biraz genişler): %3 + 1 dp pay satır sayısını korur, yetim kelimeyi geri getirmez.
      return math.min(maxWidth, hi * 1.03 + 1);
    } finally {
      painter.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    final effective = DefaultTextStyle.of(context).style.merge(style);
    final direction = Directionality.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    final text = Text(data, style: style, maxLines: maxLines, overflow: TextOverflow.ellipsis, textAlign: textAlign);
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = balancedWidth(
          text: data,
          style: effective,
          direction: direction,
          scaler: scaler,
          maxWidth: constraints.maxWidth,
          maxLines: maxLines,
        );
        if (width >= constraints.maxWidth) return text;
        // Üst kısıt sıkı (Expanded) olabilir: Align gevşetir, ConstrainedBox daraltır.
        return Align(
          alignment: AlignmentDirectional.centerStart,
          heightFactor: 1,
          child: ConstrainedBox(constraints: BoxConstraints(maxWidth: width), child: text),
        );
      },
    );
  }
}
