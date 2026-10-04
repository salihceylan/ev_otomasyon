import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../config/app_config.dart';
import '../../services/automation_state.dart';
import '../../utils/magic_link_parser.dart';
import '../../utils/qr_claim_parser.dart';
import '../pages/auth/magic_link_page.dart';
import '../pages/claim/claim_manual_dialog.dart';
import '../theme/app_theme.dart';

// =============================================================================
// Derin bağlantı (Flutter yerleşik destek; yeni paket YOK).
//
// Android'de gelen `https://<site>/reset-password#token=...` bağlantısı Flutter'a
// `/reset-password#token=...` (yalnızca yol + parça) olarak, iOS'ta tam URL olarak iletilir. Navigator
// 1.0 uygulaması bunu `pushNamed` ile açar; `MaterialApp.onGenerateRoute` / `onUnknownRoute` bu
// dosyadaki işlevlerle **uygulama kabuğunda bağlıdır** (`lib/ui/app_shell.dart`):
//
//   MaterialApp(
//     onGenerateRoute: deepLinkOnGenerateRoute,
//     onUnknownRoute: deepLinkOnUnknownRoute,
//     ...
//   )
//
// Bağlanmazsa Flutter bilinmeyen rotada istisna fırlatırdı (debug: FlutterError, release: null denetimi).
//
// Belirteçler (sihirli bağlantı) loglanmaz ve rota adında saklanmaz (rota adı sabit `/deep-link`).
// =============================================================================

/// Derin bağlantının türü.
enum DeepLinkKind { magicLink, claim, invalid }

class DeepLink {
  const DeepLink._(this.kind, {this.magicLink, this.claimUid, this.claimPin, this.message});

  const DeepLink.magic(MagicLink link) : this._(DeepLinkKind.magicLink, magicLink: link);

  const DeepLink.claim({required String uid, required String pin})
      : this._(DeepLinkKind.claim, claimUid: uid, claimPin: pin);

  const DeepLink.invalid(String message) : this._(DeepLinkKind.invalid, message: message);

  final DeepLinkKind kind;
  final MagicLink? magicLink;
  final String? claimUid;
  final String? claimPin;

  /// [DeepLinkKind.invalid] için kullanıcıya gösterilebilir neden.
  final String? message;

  @override
  String toString() => 'DeepLink($kind)';
}

const Set<String> _knownPaths = <String>{'/reset-password', '/magic-login', '/auth/magic-login', '/claim'};

/// Gelen yol/URL'yi çözer. Tanınmayan yol için `null` (sıradan yönlendirme; deep link değil).
/// Bilinen yol ama geçersiz içerik için [DeepLink.invalid].
DeepLink? parseDeepLink(String? routeOrUrl) {
  var text = (routeOrUrl ?? '').trim();
  if (text.isEmpty) return null;
  // Android: yalnızca yol + sorgu + parça gelir -> üretim ana makinesi eklenir.
  if (text.startsWith('/')) text = 'https://${AppConfig.productionHost}$text';
  final uri = Uri.tryParse(text);
  if (uri == null || !uri.hasScheme) return null;
  var path = uri.path;
  while (path.length > 1 && path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }
  if (!_knownPaths.contains(path)) return null;

  if (path == '/claim') {
    final result = QrClaimParser.parseDetailed(text);
    final data = result.data;
    if (data == null) return DeepLink.invalid(result.error?.message ?? 'Cihaz eşleme bağlantısı geçersiz.');
    return DeepLink.claim(uid: data.uid, pin: data.pin);
  }
  final result = MagicLinkParser.parseDetailed(text);
  final link = result.link;
  if (link == null) return DeepLink.invalid(result.error?.message ?? 'Bağlantı geçersiz.');
  return DeepLink.magic(link);
}

/// `MaterialApp.onGenerateRoute`: derin bağlantıyı ilgili sayfaya çevirir; derin bağlantı değilse
/// `null` döner (normal yönlendirme sürer).
Route<dynamic>? deepLinkOnGenerateRoute(RouteSettings settings) {
  final link = parseDeepLink(settings.name);
  if (link == null) return null;
  // Rota adı belirteç taşımasın.
  const safe = RouteSettings(name: '/deep-link');
  switch (link.kind) {
    case DeepLinkKind.magicLink:
      // Giriş VE şifre sıfırlama kolu: sayfa açılış / biyometrik kilit sürerken bekler (istek atılmaz, kilit
      // atlatılmaz) ve açık oturumu onaysız değiştirmez (UYELIK-K2 / UYELIK-05; bkz. MagicLinkPage).
      return MaterialPageRoute<void>(settings: safe, builder: (_) => MagicLinkPage(link: link.magicLink!));
    case DeepLinkKind.claim:
      return MaterialPageRoute<void>(
        settings: safe,
        builder: (_) => _ClaimLinkPage(uid: link.claimUid!, pin: link.claimPin!),
      );
    case DeepLinkKind.invalid:
      return MaterialPageRoute<void>(settings: safe, builder: (_) => _InvalidLinkPage(message: link.message!));
  }
}

/// `MaterialApp.onUnknownRoute`: bilinmeyen rota **hata fırlatmaz**; kullanıcıya açık sayfa gösterir.
Route<dynamic> deepLinkOnUnknownRoute(RouteSettings settings) {
  return MaterialPageRoute<void>(
    settings: const RouteSettings(name: '/unknown'),
    builder: (_) => const _InvalidLinkPage(message: 'Bu bağlantı açılamadı.'),
  );
}

class _InvalidLinkPage extends StatelessWidget {
  const _InvalidLinkPage({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Bağlantı')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.link_off_rounded, size: 56, color: AppTheme.accentAmber),
              const SizedBox(height: 16),
              Text(message, key: const Key('deep_link_invalid'), textAlign: TextAlign.center),
              const SizedBox(height: 20),
              ElevatedButton(
                key: const Key('btn_deep_link_back'),
                onPressed: () => Navigator.of(context).popUntil((r) => r.isFirst),
                child: const Text('Ana Ekrana Dön'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Cihaz etiketi sayfasının durumdan okuduğu değerler (PF-06: `context.select`; `Capabilities` yerine skaler).
typedef _ClaimLinkView = ({bool isAuthenticated, bool canClaim, bool checking, bool biometricFailed});

/// Cihaz etiketi bağlantısı (`/claim?uid=&pin=`): oturum açıksa eşleştirme diyaloğunu açar.
///
/// Soğuk açılışta (oturum geri yükleniyor / biyometrik kilit) bağlantı oturum durumu belli olmadan
/// gelir: durum **sonradan** oturum açık + yetkili olursa diyalog **o anda** açılır (yalnızca ilk
/// karede karar verilip takılı kalınmaz). Oturum yoksa açıklayıcı bir yönlendirme gösterilir.
class _ClaimLinkPage extends StatefulWidget {
  const _ClaimLinkPage({required this.uid, required this.pin});

  final String uid;
  final String pin;

  @override
  State<_ClaimLinkPage> createState() => _ClaimLinkPageState();
}

class _ClaimLinkPageState extends State<_ClaimLinkPage> {
  bool _started = false;

  static _ClaimLinkView _viewOf(AutomationState s) => (
        isAuthenticated: s.isAuthenticated,
        canClaim: s.capabilities.canClaimDevice,
        checking: s.authStatus == AuthStatus.checking,
        biometricFailed: s.biometricFailed,
      );

  /// Oturum açık ve yetkiliyse (bir kez) eşleştirme diyaloğunu açar; değilse durum değişince yeniden denenir.
  /// (Yan etki `build` içindedir ama yalnız seçilen değerler değişince çalışır: `context.select`.)
  void _maybeStart(_ClaimLinkView view) {
    if (_started || !view.isAuthenticated || !view.canClaim) return;
    _started = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final navigator = Navigator.of(context);
      await ClaimManualDialog.show(context, initialUid: widget.uid, initialPin: widget.pin);
      if (mounted) navigator.popUntil((r) => r.isFirst);
    });
  }

  String _statusText(_ClaimLinkView view) {
    if (view.isAuthenticated) {
      return view.canClaim
          ? 'Eşleştirme penceresi açılıyor...'
          : 'Bu hesabın cihaz eşleştirme yetkisi yok. Etiketteki karekodu yetkili bir hesapla okutun.';
    }
    if (view.checking) {
      // Açılış / biyometrik kilit: oturum henüz doğrulanmadı (bu sayfa kilit ekranının üstündedir).
      return view.biometricFailed
          ? 'Oturum kilitli. Ana ekrana dönüp kilidi açın, ardından etiketteki karekodu yeniden okutun.'
          : 'Oturum doğrulanıyor...';
    }
    return 'Cihazı eşleştirmek için önce hesabınızla giriş yapın, sonra etiketteki karekodu yeniden okutun.';
  }

  @override
  Widget build(BuildContext context) {
    final view = context.select<AutomationState, _ClaimLinkView>(_viewOf);
    _maybeStart(view);
    return Scaffold(
      appBar: AppBar(title: const Text('Cihaz Eşleştirme')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.qr_code_2_rounded, size: 56, color: AppTheme.primaryBlueLight),
              const SizedBox(height: 16),
              Text(
                _statusText(view),
                key: const Key('deep_link_claim_text'),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              ElevatedButton(
                key: const Key('btn_deep_link_back'),
                onPressed: () => Navigator.of(context).popUntil((r) => r.isFirst),
                child: const Text('Ana Ekrana Dön'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
