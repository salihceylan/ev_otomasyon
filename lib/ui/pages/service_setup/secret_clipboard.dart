import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../../services/clock.dart';

/// Hassas bir metni (kurulum PIN'i, QR bağlantısı, cihaz anahtarı ...) panoya kopyalar ve
/// [wipeAfter] sonra siler.
///
/// Sayfa kapansa bile silme zamanlayıcısı çalışmaya devam eder. Yeni bir gizli kopyalama
/// öncekinin zamanlayıcısını iptal eder (her kopya kendi 45 saniyesini alır).
///
/// **Silme güvenilirliği** (kullanıcı değeri başka bir uygulamaya yapıştırmak için uygulamadan ayrılır):
/// * Pano hâlâ aynı metni tutuyorsa silinir; kullanıcı bu arada başka bir metin kopyaladıysa ona dokunulmaz.
/// * Android 10+ uygulama **arka plandayken panoyu okuyamaz** (`null` döner) ve iOS 16+ başka uygulamanın
///   panosunu okurken izin sorar. Bu yüzden süre dolduğunda uygulama arka plandaysa ve pano okunamıyorsa
///   gizli değerin panoda kalmaması için üzerine **boş metin yazılır** (içerik doğrulanamadığı için güvenli
///   taraf), silme "doğrulanmamış" sayılır ve uygulama **ön plana dönünce** yeniden denenir.
/// * Hassas içerik bayrağı (Android 13+) ve klavye pano geçmişi uygulama tarafından denetlenemez: bu kalan
///   risk belgelidir (CONTRACTS); değerler mümkün olduğunca ekranda gösterilip elle yazılmalıdır.
class SecretClipboard {
  SecretClipboard._();

  /// Varsayılan silme süresi.
  static const Duration defaultWipeAfter = Duration(seconds: 45);

  static Timer? _timer;
  static String? _pending;
  static DateTime? _deadline;
  static Clock _clock = const SystemClock();
  static _ResumeWatcher? _watcher;

  /// Silinmeyi bekleyen bir gizli kopya var mı.
  static bool get hasPending => _pending != null;

  static Future<void> copy(
    String text, {
    Clock clock = const SystemClock(),
    Duration wipeAfter = defaultWipeAfter,
  }) async {
    await Clipboard.setData(ClipboardData(text: text));
    _timer?.cancel();
    _pending = text;
    _clock = clock;
    _deadline = clock.now().add(wipeAfter);
    _timer = clock.timer(wipeAfter, () => unawaited(_wipe(text)));
    _watch();
  }

  /// Uygulama şu an arka planda mı (pano okuması kısıtlanabilir). Durum bilinmiyorsa ön plan sayılır.
  static bool get _inBackground {
    try {
      final state = WidgetsBinding.instance.lifecycleState;
      return state != null && state != AppLifecycleState.resumed;
    } catch (_) {
      return false;
    }
  }

  static Future<void> _wipe(String expected) async {
    var verified = false;
    try {
      final current = await Clipboard.getData(Clipboard.kTextPlain);
      final text = current?.text;
      if (text == null || text.isEmpty) {
        // Okunamadı (arka plan kısıtı) ya da pano gerçekten boş: gizli değer kalmasın diye boş yazılır.
        await Clipboard.setData(const ClipboardData(text: ''));
        // Ön plandayken `null` = pano boş (doğrulandı); arka plandayken ön plana dönünce yeniden denenecek.
        verified = !_inBackground;
      } else if (text == expected) {
        await Clipboard.setData(const ClipboardData(text: ''));
        verified = true;
      } else {
        verified = true; // kullanıcı kendi metnini kopyalamış: dokunulmaz
      }
    } catch (_) {
      // Platform pano hatası: bekleyen silme korunur, ön plana dönünce yeniden denenir.
    }
    if (verified && _pending == expected) {
      _pending = null;
      _timer = null;
      _deadline = null;
      _unwatch();
    }
  }

  /// Bekleyen silmeyi hemen yapar (örneğin hassas diyalog kapanırken).
  static Future<void> wipeNow() async {
    final text = _pending;
    _timer?.cancel();
    _timer = null;
    if (text != null) await _wipe(text);
  }

  /// Uygulama ön plana döndü: süresi dolmuş ama doğrulanamamış bir silme varsa yeniden denenir.
  static void _onResume() {
    final text = _pending;
    final deadline = _deadline;
    if (text == null) return;
    if (deadline != null && _clock.now().isBefore(deadline)) return; // süre dolmadı: zamanlayıcı silecek
    unawaited(_wipe(text));
  }

  static void _watch() {
    if (_watcher != null) return;
    try {
      final watcher = _ResumeWatcher();
      WidgetsBinding.instance.addObserver(watcher);
      _watcher = watcher;
    } catch (_) {
      // Bağlayıcı hazır değil (saf Dart testi): ön plana dönüş yeniden denemesi olmadan sürer.
    }
  }

  static void _unwatch() {
    final watcher = _watcher;
    if (watcher == null) return;
    _watcher = null;
    try {
      WidgetsBinding.instance.removeObserver(watcher);
    } catch (_) {}
  }

  @visibleForTesting
  static void reset() {
    _timer?.cancel();
    _timer = null;
    _pending = null;
    _deadline = null;
    _unwatch();
  }
}

class _ResumeWatcher with WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) SecretClipboard._onResume();
  }
}
