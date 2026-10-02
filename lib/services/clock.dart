import 'dart:async';

/// Zaman ve zamanlayıcı soyutlaması (CONTRACTS §5).
///
/// Uygulama kodu `DateTime.now()` ve `Timer(...)` yerine bu arayüzü kullanır; böylece
/// komut hattı (2.5 sn geri alma), oturum süresi, MQTT kimlik yenileme gibi zamana bağlı
/// davranışlar testlerde sahte saatle (bkz. `test/support/fakes.dart` -> `FakeClock`)
/// gerçek beklemeden doğrulanabilir.
abstract class Clock {
  const Clock();

  /// Şu anki zaman (yerel saat dilimi; sunucudan gelen UTC değerlerle karşılaştırırken
  /// `DateTime` karşılaştırması zaten mutlak zamana göre yapılır).
  DateTime now();

  /// Tek seferlik zamanlayıcı.
  Timer timer(Duration duration, void Function() callback);

  /// Periyodik zamanlayıcı.
  Timer periodic(Duration period, void Function(Timer timer) callback);
}

/// Gerçek sistem saati.
class SystemClock extends Clock {
  const SystemClock();

  @override
  DateTime now() => DateTime.now();

  @override
  Timer timer(Duration duration, void Function() callback) => Timer(duration, callback);

  @override
  Timer periodic(Duration period, void Function(Timer timer) callback) =>
      Timer.periodic(period, callback);
}
