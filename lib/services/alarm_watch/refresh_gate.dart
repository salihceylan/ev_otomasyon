import 'dart:async';
import 'dart:isolate';
import 'dart:ui' show IsolateNameServer;

/// Oturum yenilemesini (refresh token rotasyonu) **süreç içindeki bütün Dart isolate'leri arasında** sıraya koyan kapı.
///
/// Neden: Android'de arka plan alarm bildirimi ayrı bir FlutterEngine'de (ayrı isolate) çalışır ve uygulamanın aynı
/// oturum ailesini (güvenli depodaki refresh token) kullanır. Sunucu her yenilemede yeni token verir ve kullanılmış
/// token'ın ikinci kez gelmesini "çalıntı" sayıp kullanıcının bütün oturum ailesini iptal eder (CONTRACTS §1.2). İki
/// isolate aynı anda yenilerse kullanıcı her yerden çıkarılır. Kapı içinde her taraf önce depodaki EN SON token'ı
/// okur, yeniler ve yenisini depoya yazar; sonra kapıyı bırakır.
abstract class RefreshGate {
  /// [action]'ı kapı tutularak çalıştırır (aynı anda tek yenileme).
  Future<T> run<T>(Future<T> Function() action);
}

/// Ad -> port eşlemesi (gerçekte `IsolateNameServer`; testte bellek içi).
abstract class PortRegistry {
  /// Ad boşsa kaydeder ve `true` döner; doluysa `false` (atomik "dene ve al").
  bool register(SendPort port, String name);
  SendPort? lookup(String name);
  bool remove(String name);
}

/// Süreç geneli gerçek kayıt (`dart:ui` `IsolateNameServer`; aynı süreçteki bütün FlutterEngine'ler paylaşır).
class IsolateNameServerRegistry implements PortRegistry {
  const IsolateNameServerRegistry();

  @override
  bool register(SendPort port, String name) => IsolateNameServer.registerPortWithName(port, name);

  @override
  SendPort? lookup(String name) => IsolateNameServer.lookupPortByName(name);

  @override
  bool remove(String name) => IsolateNameServer.removePortNameMapping(name);
}

/// [PortRegistry] üzerinde ad kilidi.
///
/// * Alma: bu isolate'in "canlılık" portu adla kaydedilir; ad doluysa sahibine ping atılır. Sahip yanıt vermiyorsa
///   (isolate'i ölmüş: ör. ön plan motoru kapandı) ya da [maxWait] dolduysa kilit devralınır (kilitlenme olmaz).
/// * Bırakma: ad yalnız hâlâ bu isolate'in portunu gösteriyorsa silinir.
class IsolateRefreshGate implements RefreshGate {
  IsolateRefreshGate({
    PortRegistry? registry,
    this.name = defaultName,
    this.pingTimeout = const Duration(seconds: 1),
    this.pollInterval = const Duration(milliseconds: 150),
    this.maxWait = const Duration(seconds: 45),
  }) : _registry = registry ?? const IsolateNameServerRegistry();

  static const String defaultName = 'ahbu.auth.refresh.lock';

  final PortRegistry _registry;
  final String name;
  final Duration pingTimeout;
  final Duration pollInterval;
  final Duration maxWait;

  /// Aynı isolate içindeki eşzamanlı çağrılar zincirlenir (port kaydı isolate başına tektir).
  Future<void> _local = Future<void>.value();

  @override
  Future<T> run<T>(Future<T> Function() action) {
    final previous = _local;
    final done = Completer<void>();
    _local = done.future;
    return previous.then((_) async {
      ReceivePort? held;
      try {
        held = await _acquire();
        return await action();
      } finally {
        if (held != null) _release(held);
        done.complete();
      }
    });
  }

  Future<ReceivePort> _acquire() async {
    final started = DateTime.now();
    while (true) {
      final port = ReceivePort();
      port.listen((message) {
        if (message is SendPort) message.send(true); // canlılık yanıtı
      });
      if (_registry.register(port.sendPort, name)) return port;
      port.close();
      final holder = _registry.lookup(name);
      if (holder == null) continue; // bu arada bırakıldı
      final alive = await _ping(holder);
      if (!alive || DateTime.now().difference(started) >= maxWait) {
        // Sahip ölmüş ya da kilidi çok uzun tuttu: devral.
        if (_registry.lookup(name) == holder) _registry.remove(name);
        continue;
      }
      await Future<void>.delayed(pollInterval);
    }
  }

  Future<bool> _ping(SendPort holder) async {
    final reply = ReceivePort();
    try {
      holder.send(reply.sendPort);
      await reply.first.timeout(pingTimeout);
      return true;
    } catch (_) {
      return false;
    } finally {
      reply.close();
    }
  }

  void _release(ReceivePort port) {
    if (_registry.lookup(name) == port.sendPort) _registry.remove(name);
    port.close();
  }
}
