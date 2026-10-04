import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/automation_state.dart';
import '../../services/clock.dart';
import '../../utils/friendly_error.dart';
import '../motion/motion.dart';
import '../pages/auth/social_sign_in.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../theme/tone_button_surface.dart';
import '../widgets/orb/orb.dart';
import 'app_dialogs.dart';
import 'auth_form.dart' show BalancedText, authInputDecoration;

// =============================================================================
// Paylaşılan onay / hata yardımcıları (WP-E2). İMZALAR SABİTTİR: E1 ve F paketleri kullanır.
//
//  * [ConfirmDestructiveDialog]  -> yıkıcı eylemi YAZARAK onaylatır ("SİL", UUID'nin son 4 hanesi ...)
//  * [confirmAndLogout]          -> onay + çıkış + Navigator yığınını ilk rotaya kadar temizleme
//  * [showFriendlyError]         -> hatayı ham istisna metni göstermeden Türkçe SnackBar ile bildirir
//  * [DialogBusyNotice]          -> uzun süren, iptal edilemeyen işlemde belirgin ilerleme (PF-50)
//
// Erişilebilir test anahtarları:
//   Key('field_confirm_phrase'), Key('btn_confirm_destructive'), Key('btn_cancel_destructive'),
//   Key('btn_logout_confirm'),   Key('btn_logout_cancel'),      Key('snack_friendly_error').
// =============================================================================

// -----------------------------------------------------------------------------
// Neon Glass ortak parçaları (WP-V3): giriş animasyonu + yıkıcı (rose) düğme yüzeyi.
// -----------------------------------------------------------------------------

/// Onay diyaloğunun giriş hareketi: ölçek 0.94 -> 1 + solma (220 ms, tek sefer). `MotionMode.off` (varsayılan) ve
/// "hareketi azalt"ta anında tam görünür. Girdiyi bloklamaz; yalnız dekoratif.
/// [AppDialogRoute] içinde (`showAppDialog`) rota geçişi zaten solma+ölçek yaptığı için anında tam görünür (çift
/// geçiş yok); eski `showDialog` ile açılan yerlerde bugünkü gibi canlanır.
class ConfirmDialogEntrance extends StatefulWidget {
  const ConfirmDialogEntrance({super.key, required this.child});

  final Widget child;

  @override
  State<ConfirmDialogEntrance> createState() => _ConfirmDialogEntranceState();
}

class _ConfirmDialogEntranceState extends State<ConfirmDialogEntrance> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(vsync: this, duration: AppMotion.base);
  late final Animation<double> _curve = CurvedAnimation(parent: _controller, curve: AppMotion.standard);
  late final Animation<double> _scale = Tween<double>(begin: 0.94, end: 1.0).animate(_curve);
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (MotionScope.enabledOf(context) && !AppDialogScope.isInside(context)) {
      _controller.forward();
    } else {
      _controller.value = 1.0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _curve,
      child: ScaleTransition(scale: _scale, child: widget.child),
    );
  }
}

/// Yıkıcı onay düğmesi stili: tür `ElevatedButton` KALIR; temanın sky gradyanı yerine **rose** gradyan yüzey.
/// Gerçekleme ortak yüzeydedir ([toneButtonStyle] / `ToneButtonSurface`; `accentButtonStyle(AppFamilies.rose)` ile
/// AYNI görünür). Devre dışıyken nötr cam yüzey çizilir. Beyaz metinle AA.
ButtonStyle destructiveButtonStyle() => toneButtonStyle(AppFamilies.rose);

// -----------------------------------------------------------------------------
// Ortak diyalog kabuğu (WP-F4): auth + onay akışındaki TÜM diyaloglar aynı kabuğu kullanır.
// -----------------------------------------------------------------------------

/// Auth / onay diyaloglarının ORTAK kabuğu: camsı yüzey (gradyan gövde + rim + gölge, r24), orb başlık satırı,
/// kaydırılabilir gövde ve altta SABİT eylem satırı.
///
/// Eskiden aynı akıştaki diyaloglar üç ayrı kabuk kullanıyordu: şifre yenileme geniş (323 dp) gradyan cam,
/// OTP/onay varsayılan `AlertDialog` (280 dp, düz yüzey), biyometrik istem 280 dp + dikey yığılmış eylemler.
/// Kabuk hepsini tek dile indirir:
///  * genişlik: ekran - 36 dp, en çok [maxWidth] (440);
///  * başlık: orb rozeti ([icon], [family]) + dengeli sarılan başlık ([BalancedText]; yetim kelime kalmaz) +
///    isteğe bağlı alt başlık;
///  * gövde ([content]) uzunsa kaydırılır, [actions] (bkz. [AuthDialogActions]) her zaman görünür kalır;
///  * giriş hareketi [ConfirmDialogEntrance] (220 ms, tek sefer; `MotionMode.off`'ta anında);
///  * ekran okuyucu: `AlertDialog` ile aynı anlam düğümü (rota adı + kapsam).
class AuthDialogShell extends StatelessWidget {
  const AuthDialogShell({
    super.key,
    required this.icon,
    required this.family,
    required this.title,
    required this.content,
    this.subtitle,
    this.actions,
    this.semanticLabel,
    this.maxWidth = 440,
  });

  /// Başlık rozetinin simgesi ve renk ailesi (kenar ışığı da bu ailenin tonudur).
  final IconData icon;
  final AccentFamily family;
  final String title;

  /// Başlığın altındaki küçük açıklama (ör. "Hesap kurtarma").
  final String? subtitle;

  /// Gövde: uzunsa kabuk kaydırır (kendiniz `SingleChildScrollView` eklemeyin).
  final Widget content;

  /// Eylem satırı ([AuthDialogActions] ya da tek düğme); gövdeyle birlikte kaydırılmaz.
  final Widget? actions;
  final String? semanticLabel;
  final double maxWidth;

  /// Kenar boşluğu: 360 dp telefonda diyalog 324 dp genişliğindedir.
  static const EdgeInsets insetPadding = EdgeInsets.symmetric(horizontal: 18, vertical: 24);

  /// `dialogTheme` ile aynı köşe yarıçapı ([AppRadius.dialog]; belirteç tek yerden).
  static const double radius = AppRadius.dialog;

  @override
  Widget build(BuildContext context) {
    final primary = AppTheme.getTextPrimary(context);
    final muted = AppTheme.getTextMuted(context);

    String? label = semanticLabel;
    switch (Theme.of(context).platform) {
      case TargetPlatform.iOS:
      case TargetPlatform.macOS:
        break;
      case TargetPlatform.android:
      case TargetPlatform.fuchsia:
      case TargetPlatform.linux:
      case TargetPlatform.windows:
        label ??= MaterialLocalizations.of(context).alertDialogLabel;
    }

    final header = Row(
      children: [
        OrbIconBadge(icon: icon, family: family, size: OrbSize.sm, glow: true),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              BalancedText(title, style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: primary)),
              if (subtitle != null) ...[
                const SizedBox(height: 2),
                Text(subtitle!, style: TextStyle(fontSize: 12, color: muted), maxLines: 2, overflow: TextOverflow.ellipsis),
              ],
            ],
          ),
        ),
      ],
    );

    Widget dialog = ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: DecoratedBox(
        // Camsı yüzey: koyu ve açık temada eşit kalite; kenar ışığı ailenin tonu (accent@0.28).
        decoration: AppTheme.glassDecoration(context, radius: radius, accent: family.base),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 22, 22, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              header,
              const SizedBox(height: 16),
              Flexible(child: SingleChildScrollView(child: content)),
              if (actions != null) ...[const SizedBox(height: 18), actions!],
            ],
          ),
        ),
      ),
    );
    if (label != null) {
      dialog = Semantics(scopesRoute: true, explicitChildNodes: true, namesRoute: true, label: label, child: dialog);
    }

    return ConfirmDialogEntrance(
      child: Dialog(
        // Yüzeyi kabuğun kendi dekorasyonu çizer: Material saydam ve kenarlıksız (çift kenar olmasın).
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.transparent,
        elevation: 0,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(radius))),
        insetPadding: insetPadding,
        child: dialog,
      ),
    );
  }
}

/// [AuthDialogShell] eylem satırı: İKİNCİL (iptal/geri) + BİRİNCİL düğme.
///
/// * Sığıyorsa tek satır: ikincil ~1/3, birincil kalan genişlik (tam genişlik satır; hap düğmeler).
/// * Sığmıyorsa (uzun etiket, büyük yazı) BİRİNCİL üstte, İKİNCİL altta, ikisi de tam genişlikte yığılır:
///   düğme etiketi kırpılmaz, ikincil eylem birincilin sağ kenarına hizasız kalmaz.
///
/// Sığma kararı, etiketlerin (`primaryLabel`/`secondaryLabel`) gerçek yazı tipi ve ölçeğiyle ölçülen genişliğine
/// dayanır; etiket yükleniyor/bekleme gibi durumlarda değişiyorsa **en uzun** olası etiketi verin (düzen
/// durum değişiminde sıçramaz). Tek düğme ([secondary] null) tam genişliktir.
class AuthDialogActions extends StatelessWidget {
  const AuthDialogActions({
    super.key,
    required this.primary,
    required this.primaryLabel,
    this.secondary,
    this.secondaryLabel,
  });

  final Widget primary;
  final String primaryLabel;
  final Widget? secondary;
  final String? secondaryLabel;

  static const double _gap = 12;

  /// Etiketin gerçek (kalın, tema `labelLarge`) genişliği + düğme iç boşluğu + yazı tipi payı.
  static double _need(BuildContext context, String label, {required double padding}) {
    final style = (Theme.of(context).textTheme.labelLarge ?? const TextStyle(fontSize: 15)).copyWith(fontWeight: FontWeight.bold);
    final painter = TextPainter(
      text: TextSpan(text: label, style: style),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final width = painter.width;
    painter.dispose();
    return width * 1.08 + padding;
  }

  @override
  Widget build(BuildContext context) {
    final secondaryButton = secondary;
    if (secondaryButton == null) return primary;
    return LayoutBuilder(
      builder: (context, constraints) {
        final available = constraints.maxWidth - _gap;
        final primaryNeed = _need(context, primaryLabel, padding: 48);
        final secondaryNeed = _need(context, secondaryLabel ?? '', padding: 28);
        if (available > 0 && primaryNeed + secondaryNeed <= available) {
          var secondaryWidth = math.max(secondaryNeed, available / 3);
          if (available - secondaryWidth < primaryNeed) secondaryWidth = available - primaryNeed;
          return Row(
            children: [
              SizedBox(width: secondaryWidth, child: secondaryButton),
              const SizedBox(width: _gap),
              Expanded(child: primary),
            ],
          );
        }
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [primary, const SizedBox(height: 8), secondaryButton],
        );
      },
    );
  }
}

/// İptal/geri/"daha sonra" gibi İKİNCİL düğme etiketi: tek stil (soluk metin rengi, w600).
Text authSecondaryLabel(BuildContext context, String text) =>
    Text(text, style: TextStyle(color: AppTheme.getTextMuted(context), fontWeight: FontWeight.w600));

/// BİRİNCİL düğme etiketi: tema `labelLarge` (15 sp) + kalın (tüm auth düğmelerinde tek tipografi).
///
/// [color] verilirse etiket o renkte çizilir (pasif düğmenin soluk ön plan rengi yerine). Geri sayım gibi KRİTİK bilgiyi
/// taşıyan pasif etiketler ("Bekleyin (0:30)", "Tekrar dene (0:45)") için `AppTheme.getTextMuted` verilir: tema pasif ön planı
/// muted@0.75 ≈ 3.4-3.6:1 idi; kalan süre kullanıcının TEK bilgisi olduğunda okunmalıdır (muted açıkta 6.3:1, koyuda 6.5:1).
Text authPrimaryLabel(String text, {Color? color}) =>
    Text(text, style: TextStyle(fontWeight: FontWeight.bold, color: color));

/// Türkçe büyük/küçük harf ve noktalı/noktasız i ayrımını katlayarak karşılaştırma için
/// normalleştirir: `SİL`, `sil`, `SIL`, `Sıl` hepsi `sil` olur. Baştaki/sondaki boşluk atılır.
@visibleForTesting
String foldConfirmText(String input) {
  final b = StringBuffer();
  for (final rune in input.trim().runes) {
    if (rune == 0x0307) continue; // birleşik nokta (ayrışık 'İ' girişi)
    final ch = String.fromCharCode(rune);
    switch (ch) {
      case 'İ':
      case 'I':
      case 'ı':
        b.write('i');
      default:
        b.write(ch.toLowerCase());
    }
  }
  return b.toString();
}

/// [input], [phrase] ile (büyük/küçük harf ve Türkçe i/ı farkı gözetilmeden) aynı mı?
/// Boş ifade hiçbir girdiyle eşleşmez (yanlışlıkla "boş = onay" olmasın).
bool confirmPhraseMatches(String input, String phrase) {
  final expected = foldConfirmText(phrase);
  if (expected.isEmpty) return false;
  return foldConfirmText(input) == expected;
}

/// Yıkıcı bir eylemi (silme, devir, sıfırlama ...) kullanıcıya bir ifade **yazdırarak** onaylatır.
///
/// Düğme, ifade doğru yazılana kadar pasiftir. Sonuç: yalnızca ifade doğru yazılıp onay
/// düğmesine basıldıysa `true`; vazgeç / dışarı dokunma / geri tuşu `false`.
class ConfirmDestructiveDialog extends StatefulWidget {
  const ConfirmDestructiveDialog({
    super.key,
    required this.title,
    required this.message,
    this.confirmPhrase = 'SİL',
    this.confirmLabel = 'Sil',
    this.cancelLabel = 'Vazgeç',
    this.icon = Icons.warning_amber_rounded,
  });

  final String title;
  final String message;

  /// Kullanıcının yazması gereken ifade (örn. `SİL` ya da cihaz UUID'sinin son 4 hanesi).
  final String confirmPhrase;
  final String confirmLabel;
  final String cancelLabel;
  final IconData icon;

  /// Diyaloğu gösterir. `true` yalnızca ifade doğru yazılıp onaylandığında döner.
  static Future<bool> show(
    BuildContext context, {
    required String title,
    required String message,
    String confirmPhrase = 'SİL',
    String confirmLabel = 'Sil',
    String cancelLabel = 'Vazgeç',
    IconData icon = Icons.warning_amber_rounded,
  }) async {
    final result = await showAppDialog<bool>(
      context,
      builder: (_) => ConfirmDestructiveDialog(
        title: title,
        message: message,
        confirmPhrase: confirmPhrase,
        confirmLabel: confirmLabel,
        cancelLabel: cancelLabel,
        icon: icon,
      ),
    );
    return result == true;
  }

  @override
  State<ConfirmDestructiveDialog> createState() => _ConfirmDestructiveDialogState();
}

class _ConfirmDestructiveDialogState extends State<ConfirmDestructiveDialog> {
  final TextEditingController _controller = TextEditingController();

  bool get _matches => confirmPhraseMatches(_controller.text, widget.confirmPhrase);

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onChanged);
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _controller.removeListener(_onChanged);
    _controller.dispose();
    super.dispose();
  }

  void _confirm() {
    if (!_matches) return;
    unawaited(HapticFeedback.mediumImpact()); // yıkıcı onay: orta şiddetli titreşim (komutu geciktirmez)
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final muted = AppTheme.getTextMuted(context);
    final primary = AppTheme.getTextPrimary(context);
    return AuthDialogShell(
      icon: widget.icon,
      family: AppFamilies.rose,
      title: widget.title,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.message, style: TextStyle(color: muted, fontSize: 13, height: 1.35)),
          const SizedBox(height: 14),
          Text.rich(
            TextSpan(
              style: TextStyle(color: primary, fontSize: 13),
              children: [
                const TextSpan(text: 'Onaylamak için '),
                TextSpan(
                  text: widget.confirmPhrase,
                  // Anahtar sözcük AA kontrastlı kırmızı (ham #EF4444 açık zeminde ~3.8:1'di).
                  style: TextStyle(fontWeight: FontWeight.bold, color: AppTheme.dangerText(context), letterSpacing: 0.5),
                ),
                const TextSpan(text: ' yazın:'),
              ],
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            key: const Key('field_confirm_phrase'),
            controller: _controller,
            autofocus: true,
            autocorrect: false,
            enableSuggestions: false,
            textCapitalization: TextCapitalization.characters,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _confirm(),
            style: TextStyle(color: primary),
            decoration: authInputDecoration(
              context,
              hint: widget.confirmPhrase,
              suffixIcon: _matches ? Icon(Icons.check_circle_rounded, color: AppTheme.successText(context), size: 20) : null,
            ),
          ),
        ],
      ),
      actions: AuthDialogActions(
        secondaryLabel: widget.cancelLabel,
        secondary: TextButton(
          key: const Key('btn_cancel_destructive'),
          onPressed: () => Navigator.of(context).pop(false),
          child: authSecondaryLabel(context, widget.cancelLabel),
        ),
        primaryLabel: widget.confirmLabel,
        primary: ElevatedButton(
          key: const Key('btn_confirm_destructive'),
          onPressed: _matches ? _confirm : null,
          style: destructiveButtonStyle(),
          child: authPrimaryLabel(widget.confirmLabel),
        ),
      ),
    );
  }
}

/// Yazı gerektirmeyen basit onay diyaloğu (vazgeç / onayla). Onaylanırsa `true`; vazgeç, dışarı
/// dokunma ve geri tuşu `false`. [destructive] `true` ise onay düğmesi kırmızıdır.
///
/// Diyalog ortak kabuktadır ([AuthDialogShell]: orb başlık + hap eylemler): ham `AlertDialog` (orb'suz, sağa yaslı küçük
/// metin düğmeleri) yerine TÜM basit onaylar bu dilde durur. Mevcut testlerin anahtarlarını korumak için [dialogKey],
/// [cancelKey] ve [confirmKey] verilebilir (varsayılan: `btn_simple_cancel` / `btn_simple_confirm`); [family] orb ailesini
/// seçer (varsayılan: yıkıcıysa rose, değilse sky).
Future<bool> showSimpleConfirm(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = 'Evet',
  String cancelLabel = 'Vazgeç',
  bool destructive = false,
  IconData icon = Icons.help_outline_rounded,
  AccentFamily? family,
  Key? dialogKey,
  Key cancelKey = const Key('btn_simple_cancel'),
  Key confirmKey = const Key('btn_simple_confirm'),
}) async {
  final result = await showAppDialog<bool>(
    context,
    builder: (ctx) => AuthDialogShell(
      key: dialogKey,
      icon: icon,
      family: family ?? (destructive ? AppFamilies.rose : AppFamilies.sky),
      title: title,
      content: Text(message, style: TextStyle(color: AppTheme.getTextMuted(ctx), fontSize: 13, height: 1.35)),
      actions: AuthDialogActions(
        secondaryLabel: cancelLabel,
        secondary: TextButton(
          key: cancelKey,
          onPressed: () => Navigator.of(ctx).pop(false),
          child: authSecondaryLabel(ctx, cancelLabel),
        ),
        primaryLabel: confirmLabel,
        primary: ElevatedButton(
          key: confirmKey,
          onPressed: () {
            if (destructive) unawaited(HapticFeedback.mediumImpact());
            Navigator.of(ctx).pop(true);
          },
          style: destructive ? destructiveButtonStyle() : null,
          child: authPrimaryLabel(confirmLabel),
        ),
      ),
    ),
  );
  return result == true;
}

bool _logoutRunning = false;

/// `state.logout()` için üst süre (PF-31). `logout` yerel sıfırlamadan sonra güvenli deponun toplu silmesini
/// bekler; servis katmanı (PF-02) her depo çağrısını ≈6 sn'de sınırlar, bu ise kuyrukta birden fazla takılı
/// işlem olsa bile arayüzü serbest bırakan ek emniyettir.
const Duration _logoutTimeout = Duration(seconds: 10);

/// Onay ister, [AutomationState.logout] çağırır ve Navigator yığınını ilk rotaya kadar temizler
/// (açık diyaloglar ve itilmiş sayfalar kapanır; kapı [AuthGate] giriş ekranını gösterir).
///
/// Uygulamadaki **tüm** çıkış yolları (profil, çekmece, kısıtlı ekranlar) bunu kullanır.
/// Dönüş: çıkış yapıldıysa `true`; vazgeçildi / zaten sürüyor / başarısız ise `false`.
///
/// **Askıda kalmaz (PF-31):** `logout` en çok [_logoutTimeout] beklenir. Süre dolarsa yerel oturum ZATEN
/// sıfırlanmıştır (`logout`'un ilk adımı; yalnız depo/ağ yanıtı gecikiyor): yığın yine de temizlenir, geç
/// dönen sonuç/hata yutulur ve `_logoutRunning` bayrağı her yolda sıfırlanır (aksi halde sonraki TÜM çıkış
/// dokunuşları sessizce ölü kalırdı).
Future<bool> confirmAndLogout(BuildContext context, AutomationState state) async {
  if (_logoutRunning) return false;
  // Gezgin, await'ler öncesinde alınır: çağıran widget (ör. profil diyaloğu) kapanmış olabilir.
  final navigator = Navigator.of(context, rootNavigator: true);
  final confirmed = await showAppDialog<bool>(
    context,
    builder: (ctx) => AuthDialogShell(
      icon: Icons.logout_rounded,
      family: AppFamilies.rose,
      title: 'Çıkış Yapılsın mı?',
      content: Text(
        'Oturumunuz kapatılacak ve bu cihazdaki güvenli veriler temizlenecek. Devam etmek istiyor musunuz?',
        style: TextStyle(color: AppTheme.getTextMuted(ctx), fontSize: 13, height: 1.35),
      ),
      actions: AuthDialogActions(
        secondaryLabel: 'Vazgeç',
        secondary: TextButton(
          key: const Key('btn_logout_cancel'),
          onPressed: () => Navigator.of(ctx).pop(false),
          child: authSecondaryLabel(ctx, 'Vazgeç'),
        ),
        primaryLabel: 'Evet, Çıkış Yap',
        primary: ElevatedButton(
          key: const Key('btn_logout_confirm'),
          onPressed: () {
            unawaited(HapticFeedback.mediumImpact());
            Navigator.of(ctx).pop(true);
          },
          style: destructiveButtonStyle(),
          child: authPrimaryLabel('Evet, Çıkış Yap'),
        ),
      ),
    ),
  );
  if (confirmed != true) return false;

  _logoutRunning = true;
  try {
    final finished = await state.clock.bound<bool>(state.logout().then((_) => true), _logoutTimeout, () => false);
    if (!finished && kDebugMode) debugPrint('[Çıkış] depo/ağ yanıtı gecikti; çıkış sürdürülüyor');
    unawaited(SocialSignIn.signOutGoogle()); // bir sonraki girişte hesap seçilebilsin
  } catch (e) {
    // Yerel temizlik `logout` içinde ilk adımdır; beklenmedik bir hata yığını temizlemeyi
    // engellememeli. Hata türü dışında bir şey loglanmaz.
    if (kDebugMode) debugPrint('[Çıkış] beklenmeyen hata: ${e.runtimeType}');
  } finally {
    _logoutRunning = false;
  }
  navigator.popUntil((route) => route.isFirst);
  return true;
}

/// [error]'ı ham istisna/sunucu metni göstermeden, Türkçe ve kullanıcıya uygun bir SnackBar ile
/// bildirir ([friendlyError]). [context] kapanmışsa ya da `ScaffoldMessenger` yoksa sessizce çıkar.
void showFriendlyError(BuildContext context, Object? error, {String? fallback}) {
  if (!context.mounted) return;
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  final message = fallback == null ? friendlyError(error) : friendlyError(error, fallback: fallback);
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        key: const Key('snack_friendly_error'),
        content: Text(message),
        // Beyaz iletiyle AA (ham #EF4444 ile ~3.8:1'di).
        backgroundColor: AppTheme.filledAccent(AppTheme.accentRed),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 5),
      ),
    );
}

/// Uzun süren ve **iptal edilemeyen** bir işlemin (eve katıl, daire devri, acil sıfırlama) belirgin ilerleme
/// göstergesi (PF-50): ince doğrusal ilerleme çubuğu + açıklama. Yalnız düğme içindeki küçük çark yetmez:
/// kullanıcı pencerenin neden kapanmadığını ve ne kadar bekleyeceğini görmelidir.
///
/// [slow] `true` iken (işlem beklenenden uzun sürüyor) [slowMessage] gösterilir (varsa).
class DialogBusyNotice extends StatelessWidget {
  const DialogBusyNotice({super.key, required this.message, this.slowMessage, this.slow = false});

  final String message;
  final String? slowMessage;
  final bool slow;

  /// Şu an gösterilen metin.
  String get text => slow && slowMessage != null ? slowMessage! : message;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ClipRRect(borderRadius: BorderRadius.circular(4), child: const LinearProgressIndicator(minHeight: 4)),
        const SizedBox(height: 8),
        // Canlı bölge: ekran okuyucu metin değişince (ör. "gecikiyor") bunu bir kez duyurur.
        Semantics(
          liveRegion: true,
          child: Text(
            text,
            style: TextStyle(
              fontSize: 12,
              height: 1.35,
              fontWeight: slow ? FontWeight.w600 : FontWeight.normal,
              color: slow ? AppTheme.warningText(context) : AppTheme.getTextMuted(context),
            ),
          ),
        ),
      ],
    );
  }
}
