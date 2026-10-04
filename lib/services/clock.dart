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

/// Süre sınırı (PF-02): platform kanalı gibi **kendi kendine dönmeyebilen** çağrıları bekleyen
/// kod, sonsuza dek takılmasın diye `Future.timeout` yerine bunu kullanır. Fark: sınır zamanlayıcısı
/// [Clock]'tan kurulur (testte `FakeClock.elapse` ile deterministik), tamamlanınca iptal edilir ve
/// süreyi aşan çağrının GEÇ dönen sonucu/hatası yutulur.
extension ClockBound on Clock {
  /// [future]'ı en çok [limit] kadar bekler.
  ///
  /// * Süre dolmadan tamamlanırsa değer (ya da hata) aynen iletilir ve zamanlayıcı iptal edilir.
  /// * Süre dolarsa dönen gelecek [onTimeout]'un sonucuyla tamamlanır; [onTimeout] bir hata
  ///   fırlatırsa dönen gelecek o hatayla tamamlanır (eşzamanlı istisna çağırana sızmaz).
  /// * Süre dolduktan sonra [future] değerle ya da hatayla dönerse YUTULUR: aksi halde ele alınmamış
  ///   hata olarak `main.dart` `onError`'una düşerdi.
  ///
  /// Not: zaman aşımına uğrayan çağrı İPTAL EDİLEMEZ (platform işi sürer); yalnız beklemeyi bırakırız.
  /// Zamanlayıcı tetiklendiğinde karar bir mikro görev ertelenir: sonucu zaten hazır olup devamı
  /// henüz çalışmamış bir çağrı (sahte saatin eşzamanlı `advance`'ı dahil) zaman aşımına uğratılmaz.
  Future<T> bound<T>(Future<T> future, Duration limit, T Function() onTimeout) {
    final completer = Completer<T>();
    final timer = this.timer(limit, () {
      scheduleMicrotask(() {
        if (completer.isCompleted) return;
        try {
          completer.complete(onTimeout());
        } catch (error, stack) {
          completer.completeError(error, stack);
        }
      });
    });
    unawaited(
      future.then<void>(
        (value) {
          timer.cancel();
          if (!completer.isCompleted) completer.complete(value);
        },
        onError: (Object error, StackTrace stack) {
          timer.cancel();
          if (!completer.isCompleted) completer.completeError(error, stack);
        },
      ),
    );
    return completer.future;
  }
}
