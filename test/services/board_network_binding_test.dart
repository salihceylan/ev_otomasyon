import 'dart:async';
import 'dart:io' show Platform;

import 'package:ev_otomasyon/config/app_config.dart';
import 'package:ev_otomasyon/services/board_network_binding.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/support.dart';

/// Pano kurulum ağına süreç bağlama (Android; WP-NET): Dart tarafı + kanal sözleşmesi
/// (`ev_otomasyon/board_network`). Yerel taraf SAHTEDİR (`TestDefaultBinaryMessengerBinding`): gerçek Android
/// cihazda DOĞRULANMADI; burada Dart'ın kanal sözleşmesine uyumu, kira sayacı, bekleme (linger), ağ kaybı,
/// hata/zaman aşımı yolları ve zamanlayıcı temizliği sınanır.
const MethodChannel _channel = MethodChannel(AndroidBoardNetworkBinding.channelName);
const String _ap = '192.168.4.1';

/// Sahte yerel taraf: çağrıları kaydeder; yanıtlar değiştirilebilir. Gerçek `MainActivity` kodu değildir.
class _Native {
  final List<MethodCall> calls = <MethodCall>[];
  Future<Object?> Function(MethodCall call)? onAcquire;
  Future<Object?> Function(MethodCall call)? onRelease;

  List<String> get names => calls.map((c) => c.method).toList();

  int count(String name) => calls.where((c) => c.method == name).length;

  Future<Object?> _handle(MethodCall call) async {
    calls.add(call);
    switch (call.method) {
      case 'acquire':
        final handler = onAcquire;
        return handler != null ? handler(call) : <String, Object?>{'status': 'bound'};
      case 'release':
        final handler = onRelease;
        return handler != null ? handler(call) : <String, Object?>{'status': 'released'};
    }
    throw MissingPluginException(call.method);
  }

  void install() =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, _handle);

  void uninstall() =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, null);

  /// yerel -> Dart: `networkLost` (yerel taraf ağı ÖNCE kendisi çözmüştür).
  Future<void> sendNetworkLost() async {
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
      AndroidBoardNetworkBinding.channelName,
      const StandardMethodCodec().encodeMethodCall(const MethodCall('networkLost')),
      (_) {},
    );
  }
}

Future<void> settle() async {
  for (var i = 0; i < 12; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// Kanal çağrısının KENDİSİ fırlatan kanal (beklenmeyen/programlama hatası türü yutulan istisna yolunu sınamak için).
class _ThrowingChannel extends MethodChannel {
  _ThrowingChannel() : super(AndroidBoardNetworkBinding.channelName);

  @override
  Future<T?> invokeMethod<T>(String method, [dynamic arguments]) => throw StateError('gizli-ayrıntı-metni');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _Native native;
  late FakeClock clock;
  final created = <AndroidBoardNetworkBinding>[];
  final logs = <String>[];

  /// [grace] verilmezse SINIFIN varsayılan Dart üst sınır payı ([AndroidBoardNetworkBinding.defaultNativeGrace]) kullanılır.
  AndroidBoardNetworkBinding make({Duration linger = Duration.zero, Duration? grace}) {
    final binding = grace == null
        ? AndroidBoardNetworkBinding(linger: linger, clock: clock, log: logs.add)
        : AndroidBoardNetworkBinding(linger: linger, nativeGrace: grace, clock: clock, log: logs.add);
    created.add(binding);
    return binding;
  }

  setUp(() {
    native = _Native()..install();
    clock = FakeClock();
    logs.clear();
    AppConfig.current = AppConfig.defaults;
  });

  tearDown(() {
    for (final binding in created) {
      binding.dispose();
    }
    created.clear();
    native.uninstall();
    BoardNetworkBinding.overrideForTesting(null);
    AppConfig.current = AppConfig.defaults;
  });

  group('kanal sözleşmesi', () {
    test('acquire -> yerel acquire {subnet: /24, timeoutMs: int}; bound kira; release -> yerel release', () async {
      final binding = make();
      final lease = await binding.acquire(host: _ap, timeout: const Duration(seconds: 7));

      expect(lease.status, BoardNetworkStatus.bound);
      expect(lease.isBound, isTrue);
      expect(native.names, <String>['acquire']);
      expect(native.calls.single.arguments, <String, Object?>{'subnet': '192.168.4.0/24', 'timeoutMs': 7000});

      await lease.release();
      expect(native.names, <String>['acquire', 'release']);
      expect(lease.isBound, isFalse, reason: 'bırakılan kira bağlı sayılmaz');
      expect(lease.isReleased, isTrue);
    });

    test('varsayılan bekleme: timeoutMs = BoardNetworkBinding.defaultTimeout (5000 ms)', () async {
      final lease = await make().acquire(host: _ap);
      expect(native.calls.single.arguments['timeoutMs'], BoardNetworkBinding.defaultTimeout.inMilliseconds);
      await lease.release();
    });

    test('yerel durum metinleri birebir eşlenir; detail aktarılır', () async {
      const wire = <String, BoardNetworkStatus>{
        'bound': BoardNetworkStatus.bound,
        'already_bound': BoardNetworkStatus.alreadyBound,
        'not_on_board_network': BoardNetworkStatus.notOnBoardNetwork,
        'no_wifi': BoardNetworkStatus.noWifi,
        'timeout': BoardNetworkStatus.timeout,
        'permission_denied': BoardNetworkStatus.permissionDenied,
        'unsupported': BoardNetworkStatus.unsupported,
        'error': BoardNetworkStatus.error,
      };
      for (final entry in wire.entries) {
        native.onAcquire = (_) async => <String, Object?>{'status': entry.key, 'detail': 'not-${entry.key}'};
        final binding = make();
        final lease = await binding.acquire(host: _ap);
        expect(lease.status, entry.value, reason: entry.key);
        expect(lease.detail, 'not-${entry.key}');
        expect(lease.isBound, entry.value == BoardNetworkStatus.bound || entry.value == BoardNetworkStatus.alreadyBound);
        await lease.release();
        binding.dispose();
      }
      expect(BoardNetworkStatus.values.map((s) => s.wire).toSet(), wire.keys.toSet(), reason: 'tüm sözleşme durumları kapsandı');
    });

    test('bilinmeyen / bozuk yerel yanıt -> error (istisna yok)', () async {
      for (final bad in <Object?>[
        <String, Object?>{'status': 'bilinmeyen'},
        <String, Object?>{'detail': 'x'},
        <String, Object?>{},
        'bound',
        null,
        42,
      ]) {
        native.onAcquire = (_) async => bad;
        final binding = make();
        final lease = await binding.acquire(host: _ap);
        expect(lease.status, BoardNetworkStatus.error, reason: '$bad');
        expect(lease.isBound, isFalse);
        await lease.release();
        binding.dispose();
      }
    });
  });

  group('kira sayacı ve eşzamanlı acquire birleşmesi', () {
    test('eşzamanlı acquire\'lar TEK yerel acquire\'a birleşir; son kira bırakılana kadar release YOK', () async {
      final binding = make();
      final gate = Completer<Object?>();
      native.onAcquire = (_) => gate.future;

      final pending = <Future<BoardNetworkLease>>[
        binding.acquire(host: _ap),
        binding.acquire(host: _ap),
        binding.acquire(host: _ap),
      ];
      await settle();
      expect(native.count('acquire'), 1, reason: 'yerel taraf TEK istek görür');

      gate.complete(<String, Object?>{'status': 'bound'});
      final leases = await Future.wait(pending);
      expect(leases.map((l) => l.status), everyElement(BoardNetworkStatus.bound));
      expect(native.count('acquire'), 1);

      await leases[0].release();
      await leases[1].release();
      expect(native.count('release'), 0, reason: 'bir kira hâlâ açık');
      expect(leases[2].isBound, isTrue);
      await leases[2].release();
      expect(native.count('release'), 1, reason: 'son kira bırakılınca yerel release');
    });

    test('açık kira varken (sonuçlanmış bağlama) yeni acquire mevcut bağlamayı kullanır: yerel acquire tekrarlanmaz', () async {
      final binding = make();
      final first = await binding.acquire(host: _ap);
      final second = await binding.acquire(host: _ap);

      expect(native.count('acquire'), 1);
      expect(second.status, BoardNetworkStatus.bound);
      await first.release();
      expect(native.count('release'), 0);
      expect(second.isBound, isTrue, reason: 'birinci kiranın bırakılması ikincisini etkilemez');
      await second.release();
      expect(native.count('release'), 1);
    });

    test('çifte release güvenli: yerel release tek kez; eşzamanlı çifte release de', () async {
      final binding = make();
      final lease = await binding.acquire(host: _ap);
      await lease.release();
      await lease.release();
      expect(native.count('release'), 1);

      final lease2 = await binding.acquire(host: _ap);
      await Future.wait(<Future<void>>[lease2.release(), lease2.release(), lease2.release()]);
      expect(native.count('release'), 2, reason: 'ikinci kira da yalnızca bir kez bıraktı');
    });

    test('çifte release başka bir kiranın bağlamasını çözmez (sayaç taşmaz/eksilmez)', () async {
      final binding = make();
      final a = await binding.acquire(host: _ap);
      final b = await binding.acquire(host: _ap);
      await a.release();
      await a.release(); // ikinci bırakma b'nin sayacını düşürmemeli
      expect(native.count('release'), 0);
      expect(b.isBound, isTrue);
      await b.release();
      expect(native.count('release'), 1);
    });

    test('başarısız sonuç yapışkan DEĞİL: açık başarısız kira varken yeni acquire yeniden dener; eski kirayı bırakmak yeni bağlamayı çözmez', () async {
      final binding = make();
      native.onAcquire = (_) async => <String, Object?>{'status': 'not_on_board_network'};
      final failed = await binding.acquire(host: _ap);
      expect(failed.status, BoardNetworkStatus.notOnBoardNetwork);
      expect(failed.isBound, isFalse);

      native.onAcquire = (_) async => <String, Object?>{'status': 'bound'}; // kullanıcı panonun ağına bağlandı
      final ok = await binding.acquire(host: _ap);
      expect(ok.status, BoardNetworkStatus.bound);
      expect(native.count('acquire'), 2);

      await failed.release();
      expect(native.count('release'), 0, reason: 'yeni bağlama korunur');
      expect(ok.isBound, isTrue);
      await ok.release();
      expect(native.count('release'), 1);
    });

    test('başarısız bağlamada da son kira bırakılınca yerel release çağrılır (yerel durum temiz kalsın)', () async {
      final binding = make();
      native.onAcquire = (_) async => <String, Object?>{'status': 'no_wifi'};
      final lease = await binding.acquire(host: _ap);
      await lease.release();
      expect(native.names, <String>['acquire', 'release']);
    });

    test('release sürerken gelen acquire, release\'ten SONRA yerel acquire yapar (sıra korunur)', () async {
      final binding = make();
      final first = await binding.acquire(host: _ap);
      final gate = Completer<Object?>();
      native.onRelease = (_) => gate.future;

      final releasing = first.release(); // yerel release başladı (yanıt bekleniyor)
      final second = binding.acquire(host: _ap);
      await settle();
      expect(native.names, <String>['acquire', 'release', 'acquire']);

      gate.complete(<String, Object?>{'status': 'released'});
      await releasing;
      final lease = await second;
      expect(lease.status, BoardNetworkStatus.bound);
      await lease.release();
    });

    test('alt ağ değişirse eski bağlama çözülür, sonra yenisi kurulur (yerel taraf TEK bağlama tutar)', () async {
      final binding = make();
      final first = await binding.acquire(host: _ap);
      AppConfig.current = AppConfig.forTest(deviceApHost: '192.168.7.1');
      final second = await binding.acquire(host: '192.168.7.1');

      expect(native.names, <String>['acquire', 'release', 'acquire']);
      expect(native.calls.last.arguments['subnet'], '192.168.7.0/24');
      expect(first.isBound, isFalse, reason: 'yerini yeni oturum aldı');
      expect(second.isBound, isTrue);

      await first.release(); // eski kirayı bırakmak yeni bağlamayı ÇÖZMEZ
      expect(native.names, <String>['acquire', 'release', 'acquire']);
      await second.release();
      expect(native.count('release'), 2);
    });
  });

  group('linger (kısa bekleme): bağlama/çözme çalkantısı olmaz', () {
    test('VARSAYILAN linger SIFIR: bırakma dönünce yerel release yapılmıştır; bekleyen zamanlayıcı yok', () async {
      final binding = AndroidBoardNetworkBinding(clock: clock, log: logs.add); // tüm varsayılanlar
      created.add(binding);
      expect(binding.linger, Duration.zero);

      final lease = await binding.acquire(host: _ap);
      await lease.release();

      expect(native.names, <String>['acquire', 'release'], reason: 'bırakma Future\'ı tamamlandığında süreç artık pano ağına bağlı değil');
      expect(clock.activeTimerCount, 0, reason: 'ardından gelen bulut isteği internetsiz pano ağından çıkmamalı: 300 ms kuyruk YOK');
    });

    test('son kira bırakılınca beklenir; bekleme sırasında acquire bekleme iptal eder ve bağlamayı korur', () async {
      final binding = make(linger: const Duration(milliseconds: 300));
      final first = await binding.acquire(host: _ap);
      await first.release();
      expect(native.names, <String>['acquire'], reason: 'henüz release yok');
      expect(clock.activeTimerCount, 1, reason: 'bekleme zamanlayıcısı kuruldu');

      clock.advance(const Duration(milliseconds: 200)); // dolmadı
      await settle();
      expect(native.names, <String>['acquire']);

      final second = await binding.acquire(host: _ap); // bekleme sırasında
      expect(second.status, BoardNetworkStatus.bound);
      expect(native.names, <String>['acquire'], reason: 'yeniden bağlanılmadı (çalkantı yok)');
      expect(clock.activeTimerCount, 0, reason: 'bekleme İPTAL edildi (zamanlayıcı kalmadı)');

      clock.advance(const Duration(seconds: 5));
      await settle();
      expect(native.names, <String>['acquire'], reason: 'iptal edilen bekleme release çağırmaz');
      expect(second.isBound, isTrue);
    });

    test('bekleme dolunca yerel release (tam olarak linger sonunda, bir kez)', () async {
      final binding = make(linger: const Duration(milliseconds: 300));
      final lease = await binding.acquire(host: _ap);
      await lease.release();

      clock.advance(const Duration(milliseconds: 299));
      await settle();
      expect(native.count('release'), 0);
      clock.advance(const Duration(milliseconds: 1));
      await settle();
      expect(native.names, <String>['acquire', 'release']);
      expect(clock.activeTimerCount, 0, reason: 'zamanlayıcı bırakılmadı');

      clock.advance(const Duration(seconds: 10));
      await settle();
      expect(native.count('release'), 1, reason: 'tekrar release yok');
    });

    test('bekleme dolduktan sonra gelen acquire yeniden bağlar', () async {
      final binding = make(linger: const Duration(milliseconds: 300));
      await (await binding.acquire(host: _ap)).release();
      clock.advance(const Duration(milliseconds: 300));
      await settle();
      expect(native.names, <String>['acquire', 'release']);

      final again = await binding.acquire(host: _ap);
      expect(native.names, <String>['acquire', 'release', 'acquire']);
      expect(again.isBound, isTrue);
    });

    test('bekleme sırasında yeniden alınıp bırakılan kira beklemeyi yeniden başlatır (eski zamanlayıcı erken bitirmez)', () async {
      final binding = make(linger: const Duration(milliseconds: 300));
      await (await binding.acquire(host: _ap)).release();
      clock.advance(const Duration(milliseconds: 200));
      await (await binding.acquire(host: _ap)).release(); // yeni bekleme: 300 ms
      clock.advance(const Duration(milliseconds: 150)); // eski zamanlayıcı 300. ms'de dolacaktı
      await settle();
      expect(native.count('release'), 0, reason: 'eski bekleme iptal; yenisi dolmadı');
      clock.advance(const Duration(milliseconds: 150));
      await settle();
      expect(native.count('release'), 1);
    });
  });

  group('networkLost (yerel -> Dart)', () {
    test('durum sıfırlanır, kira pasifleşir (bırakma yerel release ÇAĞIRMAZ, güvenli); sonraki acquire yeniden bağlar', () async {
      final binding = make();
      final lease = await binding.acquire(host: _ap);
      expect(lease.isBound, isTrue);

      await native.sendNetworkLost();
      expect(lease.isBound, isFalse);
      expect(lease.isLost, isTrue);
      expect(lease.failureHint, BoardNetworkStatus.notOnBoardNetwork.hint, reason: 'telefon pano ağından ayrıldı');

      await lease.release(); // yerel taraf ağ kaybında kendisi çözmüştü
      expect(native.count('release'), 0);

      final again = await binding.acquire(host: _ap);
      expect(native.count('acquire'), 2, reason: 'sonraki acquire yeniden bağlar');
      expect(again.isBound, isTrue);
      await again.release();
      expect(native.count('release'), 1);
    });

    test('ağ kaybında açık TÜM kiralar pasifleşir; eski kirayı bırakmak yeni bağlamayı çözmez', () async {
      final binding = make();
      final a = await binding.acquire(host: _ap);
      final b = await binding.acquire(host: _ap);
      await native.sendNetworkLost();
      expect(<bool>[a.isBound, b.isBound], <bool>[false, false]);

      final fresh = await binding.acquire(host: _ap);
      expect(native.count('acquire'), 2);
      await a.release();
      await b.release();
      expect(native.count('release'), 0, reason: 'yeni bağlama korunur');
      expect(fresh.isBound, isTrue);
      await fresh.release();
      expect(native.count('release'), 1);
    });

    test('ağ kaybında bekleyen linger zamanlayıcısı İPTAL edilir; yerel release çağrılmaz (yerel taraf zaten çözdü)', () async {
      final binding = make(linger: const Duration(milliseconds: 300));
      final lease = await binding.acquire(host: _ap);
      await lease.release(); // son kira: linger zamanlayıcısı kurulur
      expect(clock.activeTimerCount, 1, reason: 'zamanlayıcı gerçekten kuruldu (test boş geçmemeli)');

      await native.sendNetworkLost();
      expect(clock.activeTimerCount, 0, reason: 'networkLost bekleyen zamanlayıcıyı iptal eder');

      clock.advance(const Duration(seconds: 5));
      await settle();
      expect(native.names, <String>['acquire'], reason: 'iptal edilen bekleme release çağırmaz');
    });

    test('bağlı oturum yokken (işleyici kurulu, oturum bitmiş) networkLost zararsızdır; sonraki acquire normal bağlar', () async {
      final binding = make(); // linger yok: bırakma anında çözülür
      final lease = await binding.acquire(host: _ap); // kanal dinleyicisi kuruldu
      await lease.release();
      expect(native.names, <String>['acquire', 'release']);

      await native.sendNetworkLost(); // _current == null
      expect(logs, contains('networkLost: bağlı oturum yok; yok sayıldı'), reason: 'mesaj Dart işleyicisine GERÇEKTEN ulaştı');
      expect(native.names, <String>['acquire', 'release'], reason: 'ek yerel çağrı yok');

      final again = await binding.acquire(host: _ap);
      expect(again.isBound, isTrue);
      expect(native.names, <String>['acquire', 'release', 'acquire']);
    });

    test('başarısız (bağlı olmayan) oturumda networkLost yok sayılır', () async {
      final binding = make();
      native.onAcquire = (_) async => <String, Object?>{'status': 'not_on_board_network'};
      final lease = await binding.acquire(host: _ap);
      await native.sendNetworkLost();
      expect(lease.isLost, isFalse, reason: 'zaten bağlı değildi');
      expect(lease.status, BoardNetworkStatus.notOnBoardNetwork);
    });
  });

  group('hata ve zaman aşımı: istisna FIRLATILMAZ', () {
    test('yerel PlatformException -> error; izin hatası -> permissionDenied', () async {
      native.onAcquire = (_) async => throw PlatformException(code: 'boom', message: 'ayrıntı');
      final b1 = make();
      final l1 = await b1.acquire(host: _ap);
      expect(l1.status, BoardNetworkStatus.error);
      expect(l1.detail, 'boom');
      expect(l1.failureHint, BoardNetworkStatus.error.hint);

      for (final code in <String>['permission_denied', 'SecurityException', 'PERMISSION']) {
        native.onAcquire = (_) async => throw PlatformException(code: code);
        final b = make();
        final lease = await b.acquire(host: _ap);
        expect(lease.status, BoardNetworkStatus.permissionDenied, reason: code);
        b.dispose();
      }
    });

    test('MissingPluginException (yerel kod yok) -> unsupported; sonraki acquire kanalı yeniden çağırmaz', () async {
      native.onAcquire = (_) async => throw MissingPluginException('yok');
      final binding = make();
      final first = await binding.acquire(host: _ap);
      expect(first.status, BoardNetworkStatus.unsupported);
      expect(first.failureHint, isNull, reason: 'yapılabilecek bir şey yok: ipucu da yok');
      await first.release();

      final second = await binding.acquire(host: _ap);
      expect(second.status, BoardNetworkStatus.unsupported);
      expect(native.names, <String>['acquire'], reason: 'kanal bir kez denendi; release de çağrılmadı');
    });

    test('yerel taraf "unsupported" derse (ör. eski Android sürümü) kalıcı sayılır: kanal bir daha çağrılmaz, release de çağrılmaz', () async {
      native.onAcquire = (_) async => <String, Object?>{'status': 'unsupported', 'detail': 'sdk_too_old'};
      final binding = make();
      final first = await binding.acquire(host: _ap);
      expect(first.status, BoardNetworkStatus.unsupported);
      expect(first.detail, 'sdk_too_old');
      await first.release();

      final second = await binding.acquire(host: _ap);
      expect(second.status, BoardNetworkStatus.unsupported);
      await second.release();
      expect(native.names, <String>['acquire'], reason: 'tek deneme; sonrası ek kanal çağrısı yok');
    });

    test('hiç yerel işleyici yokken de (null yanıt) istisnasız unsupported', () async {
      native.uninstall();
      final lease = await make().acquire(host: _ap);
      expect(lease.status, BoardNetworkStatus.unsupported);
      await lease.release();
    });

    test('yerel release hatası yutulur (bırakma her zaman güvenli)', () async {
      final binding = make();
      final lease = await binding.acquire(host: _ap);
      native.onRelease = (_) async => throw PlatformException(code: 'release_failed');
      await lease.release(); // fırlatmaz
      expect(native.count('release'), 1);
      // sonraki acquire normal çalışır
      native.onRelease = null;
      final again = await binding.acquire(host: _ap);
      expect(again.isBound, isTrue);
    });

    test('takılı yerel acquire: Dart tarafı üst sınır (timeout + pay) dolunca timeout; uygulama kilitlenmez', () async {
      final binding = make(grace: const Duration(seconds: 2)); // açık pay: 1 sn + 2 sn
      native.onAcquire = (_) => Completer<Object?>().future; // asla yanıt vermez
      var done = false;
      final future = binding.acquire(host: _ap, timeout: const Duration(seconds: 1)).then((lease) {
        done = true;
        return lease;
      });
      await settle();
      expect(clock.activeTimerCount, 1, reason: 'Dart tarafı üst sınır zamanlayıcısı');

      clock.advance(const Duration(milliseconds: 2999)); // 1 sn + 2 sn pay dolmadı
      await settle();
      expect(done, isFalse);
      clock.advance(const Duration(milliseconds: 1));
      final lease = await future;

      expect(lease.status, BoardNetworkStatus.timeout);
      expect(lease.isBound, isFalse);
      expect(lease.failureHint, 'Pano ağına yönlenme kurulamadı: mobil veriyi kapatıp yeniden deneyin.');
      expect(clock.activeTimerCount, 0);

      // Takılı yerel release de üst sınırlıdır: bırakma kilitlenmez.
      native.onRelease = (_) => Completer<Object?>().future;
      var released = false;
      final releasing = lease.release().then((_) => released = true);
      await settle();
      expect(released, isFalse);
      clock.advance(const Duration(seconds: 2));
      await releasing;
      expect(released, isTrue);
      expect(clock.activeTimerCount, 0);
    });

    test('geç gelen yerel yanıt, zaman aşımına uğramış acquire\'ı geriye dönük "bound" yapmaz', () async {
      final binding = make(grace: const Duration(seconds: 2));
      final gate = Completer<Object?>();
      native.onAcquire = (_) => gate.future;
      final future = binding.acquire(host: _ap, timeout: const Duration(seconds: 1));
      await settle();
      clock.advance(const Duration(seconds: 3));
      final lease = await future;
      expect(lease.status, BoardNetworkStatus.timeout);

      gate.complete(<String, Object?>{'status': 'bound'}); // çok geç
      await settle();
      expect(lease.status, BoardNetworkStatus.timeout);
      expect(lease.isBound, isFalse);
      await lease.release();
      expect(native.names, <String>['acquire', 'release'], reason: 'takılmış yerel istek temizlensin diye release gönderilir');
    });
  });

  group('süre bütçesi: Dart üst sınırı, yerelin EN KÖTÜ yanıt süresinden (timeoutMs + 3 sn GRACE) büyüktür', () {
    test('varsayılan pay 4 sn (> yerel GRACE 3 sn)', () {
      expect(AndroidBoardNetworkBinding.defaultNativeGrace, const Duration(seconds: 4));
      expect(make().nativeGrace, AndroidBoardNetworkBinding.defaultNativeGrace);
      expect(AndroidBoardNetworkBinding.defaultNativeGrace, greaterThan(const Duration(seconds: 3)), reason: 'yerel GRACE_MS = 3 sn');
    });

    test('ağ son saniyede görülüp GRACE sonunda "not_on_board_network" gelirse (timeout + 3 sn) sonuç KORUNUR; timeout DEĞİL', () async {
      final binding = make();
      final gate = Completer<Object?>();
      native.onAcquire = (_) => gate.future;
      final future = binding.acquire(host: _ap); // varsayılan 5 sn
      await settle();

      // Yerel en kötü durum: ağ 5. saniyeye yakın görüldü, 3 sn GRACE sonunda karar verildi (~8 sn).
      clock.advance(BoardNetworkBinding.defaultTimeout + const Duration(seconds: 3));
      await settle();
      gate.complete(<String, Object?>{'status': 'not_on_board_network', 'detail': 'other_subnet'});
      final lease = await future;

      expect(lease.status, BoardNetworkStatus.notOnBoardNetwork, reason: 'eski 2 sn pay ile 7. saniyede yanlışlıkla timeout olurdu');
      expect(lease.detail, 'other_subnet');
      expect(lease.failureHint, BoardNetworkStatus.notOnBoardNetwork.hint, reason: 'doğru ipucu: "panonun ağına bağlanın"');
      expect(clock.activeTimerCount, 0);
    });

    test('üst sınır tam timeout + 4 sn: bir milisaniye önce beklenir, sonra dart_timeout', () async {
      final binding = make();
      native.onAcquire = (_) => Completer<Object?>().future;
      var done = false;
      final future = binding.acquire(host: _ap).then((l) {
        done = true;
        return l;
      });
      await settle();

      clock.advance(const Duration(seconds: 9) - const Duration(milliseconds: 1));
      await settle();
      expect(done, isFalse);
      clock.advance(const Duration(milliseconds: 1));
      final lease = await future;
      expect(lease.status, BoardNetworkStatus.timeout);
      expect(lease.detail, 'dart_timeout');
    });
  });

  group('isSupported: özellik GERÇEKTEN çalışıyor mu?', () {
    test('Android\'de başlangıçta true; MissingPluginException (yerel eklenti yok) sonrası KALICI false + hata ayıklama günlüğü', () async {
      final binding = make();
      expect(binding.isSupported, isTrue);
      native.onAcquire = (_) async => throw MissingPluginException('yok');

      final lease = await binding.acquire(host: _ap);

      expect(lease.status, BoardNetworkStatus.unsupported);
      expect(lease.detail, 'no_plugin');
      expect(binding.isSupported, isFalse, reason: 'arayüz "mobil veri açık kalabilir" demeyi bırakıp eski yönergeye dönmeli');
      expect(logs.any((l) => l.contains('yerel eklenti kayıtlı değil')), isTrue, reason: 'birleştirme hatası günlükte görünür');
      expect(logs, contains('acquire -> unsupported (no_plugin)'));

      await binding.acquire(host: _ap); // kalıcı: tekrar denenmez
      expect(native.count('acquire'), 1);
      expect(binding.isSupported, isFalse);
    });

    test('yerel taraf "unsupported" derse de kalıcı false', () async {
      final binding = make();
      native.onAcquire = (_) async => <String, Object?>{'status': 'unsupported', 'detail': 'no_process_binding_api'};
      expect(binding.isSupported, isTrue);
      await binding.acquire(host: _ap);
      expect(binding.isSupported, isFalse);
    });

    test('başarısız ama GEÇİCİ sonuçlar (not_on_board_network, no_wifi, timeout, error, permission_denied) isSupported\'ı değiştirmez', () async {
      for (final status in <String>['not_on_board_network', 'no_wifi', 'timeout', 'error', 'permission_denied']) {
        native.onAcquire = (_) async => <String, Object?>{'status': status};
        final binding = make();
        final lease = await binding.acquire(host: _ap);
        expect(lease.isBound, isFalse, reason: status);
        expect(binding.isSupported, isTrue, reason: status);
        await lease.release();
      }
    });

    test('dispose sonrası false; Android dışı (Noop) hep false', () {
      final binding = make();
      expect(binding.isSupported, isTrue);
      binding.dispose();
      expect(binding.isSupported, isFalse);
      expect(const NoopBoardNetworkBinding().isSupported, isFalse);
    });
  });

  group('dispose yarışı: dispose sonrası YENİ yerel çağrı / zamanlayıcı YOK', () {
    test('başarısız oturum açıkken acquire + aynı eşzamanlı blokta dispose: ikinci yerel acquire GİTMEZ, zamanlayıcı kalmaz', () async {
      final binding = make();
      native.onAcquire = (_) async => <String, Object?>{'status': 'not_on_board_network'};
      final failed = await binding.acquire(host: _ap); // başarısız oturum _current kalır
      expect(failed.status, BoardNetworkStatus.notOnBoardNetwork);
      expect(native.names, <String>['acquire']);

      final pending = binding.acquire(host: _ap); // yeni oturum: önceki sonucu bekler (await)
      binding.dispose(); // araya girer
      final lease = await pending;
      await settle();

      expect(lease.status, BoardNetworkStatus.unsupported);
      expect(lease.detail, 'disposed');
      expect(lease.isBound, isFalse);
      expect(native.count('acquire'), 1, reason: 'dispose sonrası yerel acquire gönderilmedi');
      expect(clock.activeTimerCount, 0, reason: 'üst sınır zamanlayıcısı kurulmadı');
    });

    test('bağlı önceki oturum + alt ağ değişimi sırasında dispose: yeni acquire GİTMEZ; yerel bağlama dispose tarafından çözülür (sızmaz)', () async {
      final binding = make();
      final first = await binding.acquire(host: _ap);
      expect(first.isBound, isTrue);

      AppConfig.current = AppConfig.forTest(deviceApHost: '192.168.7.1');
      final pending = binding.acquire(host: '192.168.7.1'); // önceki bağlamayı çözüp yenisini kuracaktı
      binding.dispose();
      final lease = await pending;
      await settle();

      expect(lease.status, BoardNetworkStatus.unsupported);
      expect(native.count('acquire'), 1, reason: 'yeni acquire gitmedi');
      expect(native.count('release'), 1, reason: 'açık yerel bağlama dispose ile TEK kez çözüldü');
      expect(clock.activeTimerCount, 0);
    });

    test('yanıtı beklenen yerel acquire sırasında dispose: en iyi çabayla release gönderilir (geç gelen bağlama sızmaz)', () async {
      final binding = make();
      native.onAcquire = (_) => Completer<Object?>().future;
      final pending = binding.acquire(host: _ap);
      await settle();
      expect(native.names, <String>['acquire']);

      binding.dispose();
      await pending;
      await settle();

      expect(native.names, <String>['acquire', 'release']);
    });

    test('hiç kullanılmamış örnekte dispose yerel çağrı YAPMAZ', () async {
      final binding = make();
      binding.dispose();
      await settle();
      expect(native.calls, isEmpty);
    });
  });

  group('hata ayıklama günlüğü (yalnız durum/ayrıntı belirteçleri)', () {
    test('acquire sonucu, release, networkLost ve yutulan istisna türü günlüğe yazılır; adres/alt ağ/anahtar/ileti YAZILMAZ', () async {
      final binding = make();
      final lease = await binding.acquire(host: _ap);
      await native.sendNetworkLost();
      await lease.release(); // yerel taraf zaten çözdü: yerel release yok

      native.onAcquire = (_) async => throw PlatformException(code: 'boom', message: 'gizli-ayrıntı-metni');
      final failed = await binding.acquire(host: _ap);
      expect(failed.status, BoardNetworkStatus.error);
      native.onRelease = (_) async => throw PlatformException(code: 'release_failed', message: 'gizli-ayrıntı-metni');
      await failed.release();

      // Kanal çağrısının kendisi fırlatırsa (programlama hatası türü): yalnız TÜR yazılır.
      final broken = AndroidBoardNetworkBinding(channel: _ThrowingChannel(), clock: clock, log: logs.add);
      created.add(broken);
      final brokenLease = await broken.acquire(host: _ap);
      expect(brokenLease.status, BoardNetworkStatus.error);
      expect(brokenLease.detail, 'native_failure');

      expect(logs, contains('acquire -> bound (-)'));
      expect(logs, contains('networkLost: yerel taraf bağlamayı çözdü; kiralar pasifleşti'));
      expect(logs, contains('acquire -> error (boom)'));
      expect(logs, contains('release: yutulan hata (PlatformException)'));
      expect(logs, contains('acquire: beklenmeyen hata (StateError)'));
      for (final line in logs) {
        expect(line, isNot(contains('192.168')), reason: 'IP/alt ağ günlüğe yazılmaz: $line');
        expect(line, isNot(contains('AHBU')), reason: line);
        expect(line, isNot(contains('gizli-ayrıntı-metni')), reason: 'istisna İLETİSİ yazılmaz: $line');
        expect(line, isNot(contains('subnet')), reason: line);
      }
    });

    test('günlük hedefi enjekte edilebilir (kurucudaki log parametresi)', () async {
      var captured = 0;
      final binding = AndroidBoardNetworkBinding(clock: clock, log: (_) => captured++);
      created.add(binding);
      await (await binding.acquire(host: _ap)).release();
      expect(captured, greaterThan(0));
    });
  });

  group('host koruması (yalnız pano kurulum ağı adresi)', () {
    test('pano ağı OLMAYAN adreslerde yerel çağrı YAPILMAZ (emülatör/QA, loopback, localhost, *.local, LAN, geçersiz)', () async {
      final binding = make();
      for (final host in <String>[
        '10.0.2.2',
        '127.0.0.1',
        'localhost',
        'pano.local',
        '192.168.1.30', // ev ağındaki cihaz (LAN doğrudan mod)
        '192.168.4.2', // AP alt ağında ama AP adresi değil
        '192.168.004.001', // kurallı olmayan yazım
        '192.168.4.1:80', // ana makine + port (çağıran ayıklamalı)
        'http://192.168.4.1',
        '192.168.4',
        '192.168.4.256',
        '8.8.8.8',
        '',
      ]) {
        final lease = await binding.acquire(host: host);
        expect(lease.status, BoardNetworkStatus.unsupported, reason: 'host: "$host"');
        expect(lease.isBound, isFalse);
        expect(lease.failureHint, isNull);
        await lease.release();
      }
      expect(native.calls, isEmpty, reason: 'hiçbir yerel çağrı yapılmadı');
    });

    test('adres, yapılandırılmış kurulum ağı adresine (AppConfig.deviceApHost) bağlıdır', () async {
      AppConfig.current = AppConfig.forTest(deviceApHost: '192.168.7.1');
      final binding = make();

      final other = await binding.acquire(host: _ap); // artık kurulum ağı adresi değil
      expect(other.status, BoardNetworkStatus.unsupported);
      expect(native.calls, isEmpty);

      final lease = await binding.acquire(host: '192.168.7.1');
      expect(lease.status, BoardNetworkStatus.bound);
      expect(native.calls.single.arguments['subnet'], '192.168.7.0/24');
      await lease.release();
    });

    test('QA adresi (DEVICE_AP_HOST=10.0.2.2:8081) 192.168/16 dışındadır: bağlama YOK', () async {
      AppConfig.current = AppConfig.forTest(deviceApHost: '10.0.2.2:8081');
      final binding = make();
      for (final host in <String>['10.0.2.2', _ap]) {
        final lease = await binding.acquire(host: host);
        expect(lease.status, BoardNetworkStatus.unsupported, reason: host);
      }
      expect(native.calls, isEmpty);
    });

    test('BoardNetworkTarget: ham IPv4 + 192.168/16 + yapılandırılmış AP adresi; alt ağ /24; port yok sayılır', () {
      expect(BoardNetworkTarget.tryParse(_ap)?.subnet, '192.168.4.0/24');
      expect(BoardNetworkTarget.tryParse(_ap)?.host, _ap);
      expect(BoardNetworkTarget.forBaseUrl('http://192.168.4.1')?.subnet, '192.168.4.0/24');
      expect(BoardNetworkTarget.forBaseUrl('http://192.168.4.1:8081')?.subnet, '192.168.4.0/24');
      expect(BoardNetworkTarget.tryParse('192.168.9.1', apHost: '192.168.9.1:8081')?.subnet, '192.168.9.0/24');

      expect(BoardNetworkTarget.forBaseUrl(''), isNull);
      expect(BoardNetworkTarget.forBaseUrl('http://pano.local'), isNull);
      expect(BoardNetworkTarget.forBaseUrl('http://10.0.2.2:8081'), isNull);
      expect(BoardNetworkTarget.forBaseUrl('http://192.168.1.30'), isNull);
      expect(BoardNetworkTarget.tryParse(null), isNull);
      expect(BoardNetworkTarget.tryParse('192.168.4.1', apHost: 'pano.local'), isNull);
      expect(BoardNetworkTarget.tryParse('172.16.0.1', apHost: '172.16.0.1'), isNull, reason: 'yalnız 192.168/16');
    });
  });

  group('dispose ve Android dışı platform', () {
    test('dispose: bekleyen linger zamanlayıcısını temizler; açık bağlamayı en iyi çabayla çözer', () async {
      final binding = make(linger: const Duration(milliseconds: 300));
      final lease = await binding.acquire(host: _ap);
      await lease.release();
      expect(clock.activeTimerCount, 1);

      binding.dispose();
      expect(clock.activeTimerCount, 0, reason: 'dispose zamanlayıcıları temizler');
      await settle();
      expect(native.names, <String>['acquire', 'release'], reason: 'açık bağlama dispose ile çözüldü');

      clock.advance(const Duration(seconds: 5));
      await settle();
      expect(native.count('release'), 1, reason: 'iptal edilen zamanlayıcı ikinci release çağırmaz');
    });

    test('dispose: yanıt beklenen yerel çağrının üst sınır zamanlayıcısını da temizler; bekleyen acquire istisnasız biter', () async {
      final binding = make();
      native.onAcquire = (_) => Completer<Object?>().future;
      final future = binding.acquire(host: _ap);
      await settle();
      expect(clock.activeTimerCount, 1);

      binding.dispose();
      expect(clock.activeTimerCount, 0);
      final lease = await future;
      expect(lease.status, BoardNetworkStatus.error);
      expect(lease.isBound, isFalse);
    });

    test('dispose sonrası: acquire yerel çağrı YAPMAZ (unsupported); bırakma güvenli; çifte dispose güvenli', () async {
      final binding = make();
      final lease = await binding.acquire(host: _ap);
      binding.dispose();
      binding.dispose();
      await settle();
      final callsAfterDispose = native.calls.length;

      final afterDispose = await binding.acquire(host: _ap);
      expect(afterDispose.status, BoardNetworkStatus.unsupported);
      await afterDispose.release();
      await lease.release();
      await native.sendNetworkLost(); // dinleyici kaldırıldı: yok sayılır
      expect(native.calls.length, callsAfterDispose);
      expect(lease.isBound, isFalse);
    });

    test('Android dışı platformda (Noop) kanal HİÇ çağrılmaz; kira "unsupported"', () async {
      final binding = BoardNetworkBinding.createForPlatform(isAndroid: false);
      expect(binding, isA<NoopBoardNetworkBinding>());
      expect(binding.isSupported, isFalse);

      final lease = await binding.acquire(host: _ap);
      expect(lease.status, BoardNetworkStatus.unsupported);
      expect(lease.isBound, isFalse);
      expect(lease.failureHint, isNull);
      await lease.release();
      binding.dispose();
      expect(native.calls, isEmpty, reason: 'HİÇBİR kanal çağrısı yok');
    });

    test('platform seçimi: Android -> AndroidBoardNetworkBinding (kanalı kullanır)', () async {
      final printed = <String?>[];
      final originalDebugPrint = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) => printed.add(message); // varsayılan günlük hedefi: test çıktısı kirlenmesin
      addTearDown(() => debugPrint = originalDebugPrint);

      final android = BoardNetworkBinding.createForPlatform(isAndroid: true);
      created.add(android as AndroidBoardNetworkBinding);
      expect(android.isSupported, isTrue);
      final lease = await android.acquire(host: _ap);
      expect(lease.status, BoardNetworkStatus.bound);
      await lease.release();
      android.dispose();
      expect(native.names, containsAllInOrder(<String>['acquire', 'release']));
    });

    test('varsayılan örnek (override yok) Android DIŞI konakta Noop: kanal çağrılmaz', () async {
      expect(BoardNetworkBinding.instance, isA<NoopBoardNetworkBinding>(), reason: 'flutter test konağı Android değildir');
      final viaInstance = await BoardNetworkBinding.instance.acquire(host: _ap);
      expect(viaInstance.status, BoardNetworkStatus.unsupported);
      expect(native.calls, isEmpty);
    }, skip: Platform.isAndroid ? 'konak Android: varsayılan örnek AndroidBoardNetworkBinding olur' : null);

    test('overrideForTesting: etkin örneği değiştirir ve null ile platform varsayılanına geri alır', () {
      final fake = FakeBoardNetworkBinding();
      final before = BoardNetworkBinding.instance;
      BoardNetworkBinding.overrideForTesting(fake);
      expect(BoardNetworkBinding.instance, same(fake));
      BoardNetworkBinding.overrideForTesting(null);
      expect(BoardNetworkBinding.instance, same(before));
      expect(BoardNetworkBinding.instance, isNot(same(fake)));
    });
  });

  group('durum ipuçları (kullanıcıya gösterilen Türkçe metin)', () {
    test('notOnBoardNetwork/noWifi, timeout/error, permissionDenied ipuçları; başarı ve unsupported ipucu YOK', () {
      const notOnNetwork = 'Telefon pano kurulum ağına (AHBU-…) bağlı görünmüyor: Wi-Fi ayarlarından panonun ağına bağlanın.';
      const noRoute = 'Pano ağına yönlenme kurulamadı: mobil veriyi kapatıp yeniden deneyin.';
      expect(BoardNetworkStatus.notOnBoardNetwork.hint, notOnNetwork);
      expect(BoardNetworkStatus.noWifi.hint, notOnNetwork);
      expect(BoardNetworkStatus.timeout.hint, noRoute);
      expect(BoardNetworkStatus.error.hint, noRoute);
      expect(BoardNetworkStatus.permissionDenied.hint, isNotNull);
      expect(BoardNetworkStatus.permissionDenied.hint, isNot(anyOf(contains('Exception'), contains('exception'), contains('permission'))));
      for (final ok in <BoardNetworkStatus>[BoardNetworkStatus.bound, BoardNetworkStatus.alreadyBound, BoardNetworkStatus.unsupported]) {
        expect(ok.hint, isNull, reason: '$ok');
      }
    });

    test('bind_denied (error + detail): VPN ipucu; başka error ayrıntısında genel ipucu; teknik terim yok', () async {
      native.onAcquire = (_) async => <String, Object?>{'status': 'error', 'detail': BoardNetworkLease.bindDeniedDetail};
      final denied = await make().acquire(host: _ap);
      expect(denied.status, BoardNetworkStatus.error);
      expect(denied.failureHint, BoardNetworkLease.bindDeniedHint);
      expect(BoardNetworkLease.bindDeniedHint, contains('VPN'));
      expect(BoardNetworkLease.bindDeniedHint, isNot(anyOf(contains('bind'), contains('Exception'), contains('netd'))));
      expect(denied.failureHint, isNot(BoardNetworkStatus.error.hint), reason: 'yanıltıcı "pano ağında değil" ya da genel ipucu verilmez');

      native.onAcquire = (_) async => <String, Object?>{'status': 'error', 'detail': 'request_failed:IllegalStateException'};
      final other = await make().acquire(host: _ap);
      expect(other.failureHint, BoardNetworkStatus.error.hint, reason: 'yalnız bind_denied özel ipucu alır');

      // Yalnız `error` durumunda: aynı ayrıntı başka bir durumda ipucunu değiştirmez.
      native.onAcquire = (_) async => <String, Object?>{'status': 'no_wifi', 'detail': BoardNetworkLease.bindDeniedDetail};
      final noWifi = await make().acquire(host: _ap);
      expect(noWifi.failureHint, BoardNetworkStatus.noWifi.hint);
    });

    test('isBound sınıflaması: yalnız bound ve already_bound', () {
      expect(BoardNetworkStatus.values.where((s) => s.isBound), <BoardNetworkStatus>[BoardNetworkStatus.bound, BoardNetworkStatus.alreadyBound]);
    });

    test('mobil veri yönergesi (Android): ön bilgi = "açık kalabilir" + yedek cümle; hata kutuları yalnız yedek cümleyi kullanır', () {
      expect(BoardNetworkBinding.mobileDataFallback, 'Bağlantı kurulamazsa mobil veriyi kapatıp yeniden deneyin.');
      expect(
        BoardNetworkBinding.mobileDataAdvice,
        'Mobil veri açık kalabilir; uygulama pano ağını otomatik kullanır. Bağlantı kurulamazsa mobil veriyi kapatıp yeniden deneyin.',
      );
      expect(BoardNetworkBinding.mobileDataAdvice, endsWith(BoardNetworkBinding.mobileDataFallback));
    });
  });
}
