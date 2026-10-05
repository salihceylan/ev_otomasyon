import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/automation_state.dart';
import '../services/peace_notice_controller.dart';
import 'common/app_dialogs.dart';
import 'common/deep_links.dart';
import 'dashboard/command_retry.dart';
import 'theme/app_theme.dart';
import 'widgets/circuit_background.dart';
import 'widgets/content_width_limit.dart';
import 'widgets/peace_notice_host.dart';

/// Uygulama kabuğu: `MaterialApp` + **tek** komut-hatası abonesi + oturum olayları.
///
/// * [AutomationState.commandFailures] akışına **yalnızca burada** abone olunur; geri alınan her
///   komut tek bir `SnackBar` ile gösterilir (`CommandFailure.message`) ve yeniden denenebilirse
///   "Tekrar dene" eylemi eklenir. Widget başına hata snackbar'ı yoktur.
/// * [SessionExpiredEvent]: tüm açık sayfalar/diyaloglar kapatılır; giriş kapısı (`AuthGate`) giriş
///   ekranını gösterir ve oturum mesajını (`sessionNotice`) orada gösterir.
/// * [GuestExpiredEvent]: tüm sayfalar kapatılır, "Erişiminiz sona erdi" diyaloğu gösterilir ve ev
///   listesi yenilenir (pano "süre doldu" ekranını `capabilities.isGuestExpired` ile gösterir).
/// * Güvenli depolama hatası ([AutomationState.storageError]) bir kez kullanıcıya bildirilir.
///
/// Kök `MaterialApp` durum değiştikçe yeniden kurulmaz: yalnızca tema modu için `select` kullanılır.
///
/// Erişilebilir test anahtarları: `Key('snack_command_failure')`, `Key('snack_storage_error')`, `Key('dialog_guest_expired')`, `Key('btn_guest_expired_ok')`.
class AppShell extends StatefulWidget {
  const AppShell({
    super.key,
    required this.home,
    this.navigatorKey,
    this.scaffoldMessengerKey,
  });

  /// Ana sayfa (uygulamada kimlik kapısı `AuthGate`; `main.dart` bağlar).
  final Widget home;

  final GlobalKey<NavigatorState>? navigatorKey;
  final GlobalKey<ScaffoldMessengerState>? scaffoldMessengerKey;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  late final GlobalKey<NavigatorState> _navigatorKey =
      widget.navigatorKey ?? GlobalKey<NavigatorState>(debugLabel: 'AppShell.navigator');
  late final GlobalKey<ScaffoldMessengerState> _messengerKey =
      widget.scaffoldMessengerKey ?? GlobalKey<ScaffoldMessengerState>(debugLabel: 'AppShell.messenger');

  final CommandRetryRegistry _retry = CommandRetryRegistry();

  AutomationState? _state;

  /// Gece hatırlatması (push + afiş) mantığı: sayfalara/AutomationState'e değil kabuğa bağlıdır.
  late final PeaceNoticeController _peace;
  StreamSubscription<CommandFailure>? _failureSub;
  StreamSubscription<SessionEvent>? _sessionSub;

  String? _lastFailureMessage;
  DateTime? _lastFailureAt;
  String? _shownStorageError;
  bool _guestDialogOpen = false;

  @override
  void initState() {
    super.initState();
    final state = context.read<AutomationState>();
    _state = state;
    _peace = PeaceNoticeController(state: state);
    _failureSub = state.commandFailures.listen(_onFailure);
    _sessionSub = state.sessionEvents.listen(_onSessionEvent);
    state.addListener(_onStateChanged);
  }

  @override
  void dispose() {
    _failureSub?.cancel();
    _sessionSub?.cancel();
    _state?.removeListener(_onStateChanged);
    _retry.clear();
    _peace.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Komut hataları (TEK abone)
  // ---------------------------------------------------------------------------

  void _onFailure(CommandFailure failure) {
    final state = _state;
    final messenger = _messengerKey.currentState;
    if (state == null || messenger == null) return;

    final now = state.clock.now();
    // Aynı ileti kısa sürede tekrar gelirse (ör. art arda geri alınan komutlar) yinelenmez.
    if (failure.message == _lastFailureMessage &&
        _lastFailureAt != null &&
        now.difference(_lastFailureAt!) < const Duration(seconds: 2)) {
      _retry.discard(failure.key);
      return;
    }
    _lastFailureMessage = failure.message;
    _lastFailureAt = now;

    final retry = failure.isRetryable ? _retry.take(failure.key, now) : null;
    if (!failure.isRetryable) _retry.discard(failure.key);

    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          key: const Key('snack_command_failure'),
          content: Text(failure.message),
          behavior: SnackBarBehavior.floating,
          duration: Duration(seconds: retry == null ? 5 : 8),
          action: retry == null
              ? null
              : SnackBarAction(
                  label: 'Tekrar dene',
                  onPressed: () {
                    // Sonuç yine kabuktaki aboneye düşer; burada ayrıca hata gösterilmez.
                    unawaited(retry());
                  },
                ),
        ),
      );
  }

  // ---------------------------------------------------------------------------
  // Oturum olayları
  // ---------------------------------------------------------------------------

  void _onSessionEvent(SessionEvent event) {
    switch (event) {
      case SessionExpiredEvent():
        // Oturum sıfırlanınca mod bulut'a döner: giriş kapısı (`AuthGate`) giriş ekranını gösterir ve
        // oturum mesajını (`sessionNotice`) orada, kapatılana kadar kendisi gösterir. Kabuk yalnızca
        // üstte kalan sayfa/diyalogları kapatır (mesajı yinelemez, temizlemez).
        _popToRoot();
      case GuestExpiredEvent(:final homeName):
        _popToRoot();
        // Sunucudaki gerçek erişim durumuyla ev listesini tazele (uçuştaki istek varsa birleşir).
        unawaited(_state?.fetchHomes(autoSelect: false));
        _showGuestExpiredDialog(homeName);
    }
  }

  void _popToRoot() {
    _navigatorKey.currentState?.popUntil((route) => route.isFirst);
  }

  void _showGuestExpiredDialog(String? homeName) {
    if (_guestDialogOpen) return;
    final context = _navigatorKey.currentContext;
    if (context == null) return;
    _guestDialogOpen = true;
    final name = (homeName == null || homeName.trim().isEmpty) ? 'Bu daire' : homeName.trim();
    showAppDialog<void>(
      context,
      builder: (ctx) => AlertDialog(
        key: const Key('dialog_guest_expired'),
        icon: const Icon(Icons.timer_off_outlined, color: AppTheme.accentAmber, size: 32),
        title: const Text('Erişiminiz sona erdi'),
        content: Text(
          '$name için misafir erişim süreniz doldu. Cihazları artık göremez veya kontrol edemezsiniz. '
          'Yeniden erişim için ev sahibinden yeni bir davet isteyebilirsiniz.',
        ),
        actions: [
          FilledButton(
            key: const Key('btn_guest_expired_ok'),
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Tamam'),
          ),
        ],
      ),
    ).whenComplete(() => _guestDialogOpen = false);
  }

  // ---------------------------------------------------------------------------
  // Güvenli depolama hatası
  // ---------------------------------------------------------------------------

  void _onStateChanged() {
    final state = _state;
    if (state == null) return;
    final error = state.storageError;
    if (error == null) {
      _shownStorageError = null;
      return;
    }
    if (error == _shownStorageError) return;
    _shownStorageError = error;
    // Dinleyici içinden yeniden bildirim yapmamak için bir sonraki mikro göreve ertele.
    scheduleMicrotask(() {
      if (!mounted) return;
      final messenger = _messengerKey.currentState;
      if (messenger == null) return;
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            key: const Key('snack_storage_error'),
            content: Text(error),
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 8),
          ),
        );
      state.clearStorageError();
    });
  }

  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    // Yalnızca tema değişince yeniden çiz (her durum değişiminde tüm uygulamayı değil).
    final themeMode = context.select<AutomationState, ThemeMode>((s) => s.themeMode);

    return Provider<CommandRetryRegistry>.value(
      value: _retry,
      child: MaterialApp(
        navigatorKey: _navigatorKey,
        scaffoldMessengerKey: _messengerKey,
        title: 'AHBU Ev Otomasyonu',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.lightTheme,
        darkTheme: AppTheme.darkTheme,
        themeMode: themeMode,
        // Derin bağlantı (Android'de flutter_deeplinking_enabled): e-postadaki sihirli bağlantı ve
        // cihaz etiketi bağlantısı rota olarak gelir; üreteç yoksa Flutter istisna fırlatırdı.
        onGenerateRoute: deepLinkOnGenerateRoute,
        onUnknownRoute: deepLinkOnUnknownRoute,
        builder: (context, child) {
          // Sağlayıcı ve afiş köprüsü Navigator'ın ÜSTÜNDE: tüm sayfalar/diyaloglar denetleyiciyi okuyabilir; afiş
          // ScaffoldMessenger üzerinden (MaterialBanner/SnackBar) gösterilir, köprü kendisi bir şey çizmez.
          return ChangeNotifierProvider<PeaceNoticeController>.value(
            value: _peace,
            child: PeaceNoticeHost(
              child: CircuitBackground(
                // Geniş pencerede (masaüstü) içerik ortalanmış bir sütunda kalır; arka plan tam ekran.
                child: ContentWidthLimit(child: child ?? const SizedBox.shrink()),
              ),
            ),
          );
        },
        home: widget.home,
      ),
    );
  }
}
