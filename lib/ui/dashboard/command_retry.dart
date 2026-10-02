import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../../services/automation_state.dart';

/// Hata olursa "Tekrar dene" eylemini beslemek için kullanıcının **son niyetini** hatırlar.
///
/// Komut geri alındığında ([CommandFailure]) hangi değerin hedeflendiği hata olayında yoktur;
/// bu yüzden komutu veren kart/düğme, komutla birlikte bir "yeniden dene" kapanışını buraya yazar
/// ([runCommand]). Uygulama kabuğundaki **tek** hata abonesi ([AppShell]) bunu uygun bir uç nokta
/// anahtarı için ([CommandFailure.key]) ve yalnızca kısa bir süre içinde kullanır.
class CommandRetryRegistry {
  CommandRetryRegistry({this.maxAge = const Duration(seconds: 20)});

  /// Bir niyetin "tekrar dene" için geçerli kalma süresi (komut hattı üst sınırı 10 sn).
  final Duration maxAge;

  final Map<String, _Intent> _intents = <String, _Intent>{};

  /// [key] için son niyeti kaydeder (aynı anahtardaki öncekinin yerine geçer).
  void remember(String key, Future<bool> Function() retry, DateTime now) {
    _intents[key] = _Intent(retry, now);
  }

  /// [key] için taze bir niyet varsa döndürür ve **kaydı siler** (yalnızca bir kez kullanılır).
  Future<bool> Function()? take(String key, DateTime now) {
    final intent = _intents.remove(key);
    if (intent == null) return null;
    if (now.difference(intent.at) > maxAge) return null;
    return intent.retry;
  }

  /// Anahtarın niyetini siler.
  void discard(String key) => _intents.remove(key);

  void clear() => _intents.clear();

  int get length => _intents.length;

  /// Ağaçta [CommandRetryRegistry] sağlanmamışsa (ör. kabuksuz sayfa testi) `null`.
  static CommandRetryRegistry? maybeOf(BuildContext context) =>
      Provider.of<CommandRetryRegistry?>(context, listen: false);
}

class _Intent {
  const _Intent(this.retry, this.at);

  final Future<bool> Function() retry;
  final DateTime at;
}

/// Komutu çalıştırır; hata olursa kabuk "Tekrar dene" gösterebilsin diye niyeti hatırlar.
///
/// Dönüş değeri yalnızca "iletildi mi"dir (çift dokunuşta önceki çağrı `false` döner): arayüz bu
/// değere bakarak **hata göstermemelidir**; hatalar kabuktaki tek abone tarafından gösterilir.
Future<bool> runCommand(
  BuildContext context,
  String key,
  Future<bool> Function() command,
) {
  final registry = CommandRetryRegistry.maybeOf(context);
  if (registry != null) {
    final state = context.read<AutomationState>();
    registry.remember(key, command, state.clock.now());
  }
  return command();
}

/// Bir komut hatasının kullanıcı tarafından yeniden denenebilir olup olmadığı.
extension CommandFailureRetry on CommandFailure {
  /// Geçici nedenler (çevrimdışı, ağ, zaman aşımı, iletilemedi, broker) yeniden denenebilir;
  /// yetki/doğrulama/hız sınırı hataları denenmez.
  bool get isRetryable {
    switch (reason) {
      case CommandFailureReason.offline:
      case CommandFailureReason.notDelivered:
      case CommandFailureReason.timeout:
      case CommandFailureReason.network:
      case CommandFailureReason.brokerUnavailable:
        return true;
      case CommandFailureReason.forbidden:
      case CommandFailureReason.rateLimited:
      case CommandFailureReason.validation:
      case CommandFailureReason.rejected:
        return false;
    }
  }
}
