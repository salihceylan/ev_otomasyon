import 'dart:async';
import 'dart:math';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ev_otomasyon/services/push/peace_notice.dart';
import 'package:ev_otomasyon/services/push/push_coordinator.dart';
import 'package:ev_otomasyon/services/push/push_gateway.dart';

import 'fakes.dart';

const String _home = '3f2b8c1e-9d4a-4e7b-a1c2-5d6e7f8a9b0c';

Map<String, dynamic> _data({String? noticeId = '41', String lights = '2', String shutters = '1'}) => <String, dynamic>{
  'type': 'peace_open_devices',
  'home_id': _home,
  'notice_id': ?noticeId,
  'open_lights': lights,
  'open_shutters': shutters,
  'action': 'close_all',
  'v': '1',
};

PushMessage _message({String? noticeId = '41', String body = 'Salonda 2 lamba, 1 panjur açık.'}) => PushMessage(
  data: _data(noticeId: noticeId),
  title: 'Evim',
  body: body,
);

/// Her testte taze bir düzen kurar; zaman ve rastgelelik deterministiktir.
class _Rig {
  _Rig(
    this.async, {
    double random = 0.5,
    Duration retryBase = const Duration(seconds: 30),
    Duration retryMax = const Duration(minutes: 15),
    Duration reRegisterAfter = const Duration(hours: 24),
    Duration unregisterTimeout = const Duration(seconds: 3),
    Duration stepTimeout = const Duration(seconds: 30),
    String? appVersion = '1.0.0+1',
  }) {
    final clock = async.getClock(DateTime.utc(2026, 10, 1, 20));
    coordinator = PushCoordinator(
      gateway: gateway,
      api: api,
      platform: 'android',
      appVersion: appVersion,
      now: clock.now,
      reRegisterAfter: reRegisterAfter,
      retryBase: retryBase,
      retryMax: retryMax,
      unregisterTimeout: unregisterTimeout,
      stepTimeout: stepTimeout,
      random: FixedRandom(random),
    );
    coordinator.states.listen(states.add);
  }

  final FakeAsync async;
  final FakeGateway gateway = FakeGateway();
  final FakeApi api = FakeApi();
  late final PushCoordinator coordinator;
  final List<PushState> states = <PushState>[];

  /// Çağrıyı başlatır ve mikro görevleri boşaltır; tamamlandı mı bilgisini döndürür.
  bool run(Future<void> future) {
    var done = false;
    future.then((_) => done = true);
    async.flushMicrotasks();
    return done;
  }

  bool start({bool prompt = false}) => run(coordinator.start(promptForPermission: prompt));
  bool refresh() => run(coordinator.refresh());
  bool stop({bool unregister = true, bool? invalidateLocalToken}) =>
      run(coordinator.stop(unregister: unregister, invalidateLocalToken: invalidateLocalToken));
}

void _test(String name, void Function(_Rig rig) body, {double random = 0.5}) {
  test(name, () {
    fakeAsync((async) {
      final rig = _Rig(async, random: random);
      body(rig);
    });
  });
}

void main() {
  group('desteklenmeme', () {
    _test('desteklenmiyorsa unsupported olur ve hiçbir çağrı yapılmaz', (rig) {
      rig.gateway.supported = false;
      expect(rig.start(), isTrue);
      expect(rig.coordinator.state, PushState.unsupported);
      expect(rig.gateway.calls, isEmpty);
      expect(rig.api.registerCalls, isEmpty);
      expect(rig.states, <PushState>[PushState.unsupported]);
      expect(rig.async.pendingTimers, isEmpty);
    });

    _test('refresh ve requestPermissionAndRegister de desteklenmiyorsa çağrı yapmaz', (rig) {
      rig.gateway.supported = false;
      rig.start();
      rig.refresh();
      rig.run(rig.coordinator.requestPermissionAndRegister());
      expect(rig.gateway.calls, isEmpty);
      expect(rig.api.registerCalls, isEmpty);
    });

    _test('initialize sonrası destek düşerse (ağ geçidi başlatılamadı) unsupported olur', (rig) {
      rig.gateway.supportedAfterInitialize = false;
      rig.start();
      expect(rig.coordinator.state, PushState.unsupported);
      expect(rig.gateway.calls, <String>['initialize']);
      expect(rig.api.registerCalls, isEmpty);
    });

    _test('initialize fırlatırsa unsupported olur ve yeniden denenmez', (rig) {
      rig.gateway.throwing.add('initialize');
      expect(rig.start(), isTrue);
      expect(rig.coordinator.state, PushState.unsupported);
      expect(rig.async.pendingTimers, isEmpty);
    });

    _test('gateway izin durumu unsupported dönerse unsupported olur', (rig) {
      rig.gateway.permission = PushPermission.unsupported;
      rig.start();
      expect(rig.coordinator.state, PushState.unsupported);
      expect(rig.api.registerCalls, isEmpty);
    });
  });

  group('izin', () {
    _test('izin reddedilmiş ve istem kapalıysa needsPermission, kayıt yok', (rig) {
      rig.gateway.permission = PushPermission.denied;
      rig.start();
      expect(rig.coordinator.state, PushState.needsPermission);
      expect(rig.coordinator.permissionDenied, isTrue);
      expect(rig.gateway.count('requestPermission'), 0);
      expect(rig.gateway.count('getToken'), 0);
      expect(rig.api.registerCalls, isEmpty);
    });

    _test('izin hiç sorulmamışsa needsPermission ama permissionDenied false', (rig) {
      rig.gateway.permission = PushPermission.notDetermined;
      rig.start();
      expect(rig.coordinator.state, PushState.needsPermission);
      expect(rig.coordinator.permissionDenied, isFalse);
      expect(rig.api.registerCalls, isEmpty);
    });

    _test('promptForPermission ile izin istenir; verilirse kayıt yapılır', (rig) {
      rig.gateway.permission = PushPermission.notDetermined;
      rig.gateway.requestResult = PushPermission.granted;
      rig.start(prompt: true);
      expect(rig.gateway.count('requestPermission'), 1);
      expect(rig.coordinator.state, PushState.registered);
      expect(rig.api.registerCalls, hasLength(1));
      expect(rig.coordinator.permissionDenied, isFalse);
    });

    _test('promptForPermission ile istenen izin reddedilirse needsPermission + permissionDenied', (rig) {
      rig.gateway.permission = PushPermission.notDetermined;
      rig.gateway.requestResult = PushPermission.denied;
      rig.start(prompt: true);
      expect(rig.coordinator.state, PushState.needsPermission);
      expect(rig.coordinator.permissionDenied, isTrue);
      expect(rig.api.registerCalls, isEmpty);
    });

    _test('izin zaten varsa istem açık olsa da izin penceresi çıkmaz', (rig) {
      rig.start(prompt: true);
      expect(rig.gateway.count('requestPermission'), 0);
      expect(rig.coordinator.state, PushState.registered);
    });

    _test('requestPermissionAndRegister izin verilince kaydı tamamlar', (rig) {
      rig.gateway.permission = PushPermission.notDetermined;
      rig.start();
      expect(rig.coordinator.state, PushState.needsPermission);
      rig.run(rig.coordinator.requestPermissionAndRegister());
      expect(rig.coordinator.state, PushState.registered);
      expect(rig.api.registerCalls, hasLength(1));
    });

    _test('requestPermissionAndRegister oturum yokken hiçbir şey yapmaz', (rig) {
      expect(rig.run(rig.coordinator.requestPermissionAndRegister()), isTrue);
      expect(rig.gateway.calls, isEmpty);
      expect(rig.coordinator.state, PushState.idle);
    });

    _test('refresh sırasında izin geri alınmışsa needsPermission olur', (rig) {
      rig.start();
      expect(rig.coordinator.state, PushState.registered);
      rig.gateway.permission = PushPermission.denied;
      rig.refresh();
      expect(rig.coordinator.state, PushState.needsPermission);
      expect(rig.coordinator.permissionDenied, isTrue);
    });

    _test('ayarlardan izin verilince refresh kaydı yapar', (rig) {
      rig.gateway.permission = PushPermission.denied;
      rig.start();
      rig.gateway.permission = PushPermission.granted;
      rig.refresh();
      expect(rig.coordinator.state, PushState.registered);
      expect(rig.coordinator.permissionDenied, isFalse);
    });
  });

  group('kayıt', () {
    _test('izin varsa token alınır, registering sonra registered olunur', (rig) {
      rig.start();
      expect(rig.states, <PushState>[PushState.registering, PushState.registered]);
      expect(rig.api.registerCalls, hasLength(1));
      expect(rig.api.registerCalls.single.token, 'token-1');
      expect(rig.api.registerCalls.single.platform, 'android');
      expect(rig.api.registerCalls.single.appVersion, '1.0.0+1');
    });

    _test('aynı token, süre dolmadan start/refresh yeni istek göndermez', (rig) {
      rig.start();
      rig.start();
      rig.refresh();
      rig.async.elapse(const Duration(hours: 23));
      rig.refresh();
      expect(rig.api.registerCalls, hasLength(1));
      expect(rig.coordinator.state, PushState.registered);
    });

    _test('reRegisterAfter dolunca aynı token yeniden kaydedilir', (rig) {
      rig.start();
      rig.async.elapse(const Duration(hours: 24));
      rig.refresh();
      expect(rig.api.registerCalls, hasLength(2));
      expect(rig.coordinator.state, PushState.registered);
    });

    _test('refresh sırasında token değiştiyse yenisi kaydedilir, eskisi silinmez', (rig) {
      rig.start();
      rig.gateway.tokenProvider = () async => 'token-2';
      rig.refresh();
      expect(rig.api.registerCalls.map((c) => c.token), <String>['token-1', 'token-2']);
      expect(rig.api.unregisterCalls, isEmpty);
    });

    _test('onTokenRefresh yeni token kaydeder, eskisini silmeye uğraşmaz', (rig) {
      rig.start();
      rig.gateway.tokenRefresh.add('token-2');
      rig.async.flushMicrotasks();
      expect(rig.api.registerCalls.map((c) => c.token), <String>['token-1', 'token-2']);
      expect(rig.api.unregisterCalls, isEmpty);
      expect(rig.coordinator.state, PushState.registered);
    });

    _test('aynı token tekrar yenilendi olarak gelirse yeni istek gitmez', (rig) {
      rig.start();
      rig.gateway.tokenRefresh.add('token-1');
      rig.async.flushMicrotasks();
      expect(rig.api.registerCalls, hasLength(1));
    });

    _test('izin yokken gelen token yenilemesi kayıt yapmaz', (rig) {
      rig.gateway.permission = PushPermission.denied;
      rig.start();
      rig.gateway.tokenRefresh.add('token-2');
      rig.async.flushMicrotasks();
      expect(rig.api.registerCalls, isEmpty);
    });

    _test('oturum açılmadan gelen token yenilemesi yok sayılır', (rig) {
      rig.gateway.tokenRefresh.add('token-2');
      rig.async.flushMicrotasks();
      expect(rig.api.registerCalls, isEmpty);
    });

    _test('token alınamazsa (null) failed olur ve geri çekilmeyle yeniden denenir', (rig) {
      var calls = 0;
      rig.gateway.tokenProvider = () async => ++calls == 1 ? null : 'token-1';
      rig.start();
      expect(rig.coordinator.state, PushState.failed);
      expect(rig.api.registerCalls, isEmpty);
      rig.async.elapse(const Duration(seconds: 30));
      expect(rig.coordinator.state, PushState.registered);
      expect(rig.api.registerCalls, hasLength(1));
    });

    _test('getToken fırlatırsa failed olur, istisna sızmaz', (rig) {
      rig.gateway.throwing.add('getToken');
      expect(rig.start(), isTrue);
      expect(rig.coordinator.state, PushState.failed);
    });

    _test('boş token geçici hata sayılır', (rig) {
      rig.gateway.tokenProvider = () async => '';
      rig.start();
      expect(rig.coordinator.state, PushState.failed);
      expect(rig.api.registerCalls, isEmpty);
    });
  });

  group('geçici hata ve geri çekilme', () {
    _test('hata -> failed; retryBase sonra kendiliğinden yeniden dener', (rig) {
      rig.api.registerOutcomes.add(StateError('ağ'));
      rig.start();
      expect(rig.coordinator.state, PushState.failed);
      expect(rig.api.registerCalls, hasLength(1));
      rig.async.elapse(const Duration(seconds: 29, milliseconds: 999));
      expect(rig.api.registerCalls, hasLength(1));
      rig.async.elapse(const Duration(milliseconds: 1));
      expect(rig.api.registerCalls, hasLength(2));
      expect(rig.coordinator.state, PushState.registered);
    });

    _test('gecikme her başarısızlıkta ikiye katlanır (30s, 60s, 120s)', (rig) {
      rig.api.registerOutcomes.addAll(<Object?>[StateError('1'), StateError('2'), StateError('3')]);
      rig.start();
      expect(rig.api.registerCalls, hasLength(1));
      rig.async.elapse(const Duration(seconds: 30));
      expect(rig.api.registerCalls, hasLength(2));
      rig.async.elapse(const Duration(seconds: 59));
      expect(rig.api.registerCalls, hasLength(2));
      rig.async.elapse(const Duration(seconds: 1));
      expect(rig.api.registerCalls, hasLength(3));
      rig.async.elapse(const Duration(seconds: 119));
      expect(rig.api.registerCalls, hasLength(3));
      rig.async.elapse(const Duration(seconds: 1));
      expect(rig.api.registerCalls, hasLength(4));
      expect(rig.coordinator.state, PushState.registered);
    });

    test('gecikme retryMax ile sınırlanır ve sapma sonrası da aşılmaz', () {
      fakeAsync((async) {
        // random=1.0 -> en uç yukarı sapma (+%20); sınır yine aşılmamalı.
        final rig = _Rig(
          async,
          random: 1.0,
          retryBase: const Duration(seconds: 30),
          retryMax: const Duration(seconds: 100),
        );
        rig.api.registerOutcomes.addAll(List<Object?>.generate(6, (_) => StateError('x')));
        rig.start();
        // n=0: 30*1.2=36s
        rig.async.elapse(const Duration(seconds: 36));
        expect(rig.api.registerCalls, hasLength(2));
        // n=1: 60*1.2=72s
        rig.async.elapse(const Duration(seconds: 72));
        expect(rig.api.registerCalls, hasLength(3));
        // n=2: 120 -> 100 sınırı, *1.2=120 -> yine 100
        rig.async.elapse(const Duration(seconds: 99));
        expect(rig.api.registerCalls, hasLength(3));
        rig.async.elapse(const Duration(seconds: 1));
        expect(rig.api.registerCalls, hasLength(4));
        // n=3: yine 100
        rig.async.elapse(const Duration(seconds: 100));
        expect(rig.api.registerCalls, hasLength(5));
      });
    });

    test('alt sapma (-%20) ilk gecikmeyi 24 saniyeye indirir', () {
      fakeAsync((async) {
        final rig = _Rig(async, random: 0.0);
        rig.api.registerOutcomes.add(StateError('x'));
        rig.start();
        rig.async.elapse(const Duration(seconds: 23, milliseconds: 999));
        expect(rig.api.registerCalls, hasLength(1));
        rig.async.elapse(const Duration(milliseconds: 1));
        expect(rig.api.registerCalls, hasLength(2));
      });
    });

    _test('başarıdan sonra geri çekilme sayacı sıfırlanır', (rig) {
      rig.api.registerOutcomes.addAll(<Object?>[StateError('1'), StateError('2')]);
      rig.start();
      rig.async.elapse(const Duration(seconds: 30)); // 2. hata
      rig.async.elapse(const Duration(seconds: 60)); // başarı
      expect(rig.coordinator.state, PushState.registered);
      // Yeni bir hata: gecikme yeniden 30s olmalı (120s değil).
      rig.async.elapse(const Duration(hours: 24));
      rig.api.registerOutcomes.add(StateError('3'));
      rig.refresh();
      expect(rig.coordinator.state, PushState.failed);
      final before = rig.api.registerCalls.length;
      rig.async.elapse(const Duration(seconds: 30));
      expect(rig.api.registerCalls.length, before + 1);
    });

    _test('refresh bekleyen geri çekilmeyi beklemeden dener', (rig) {
      rig.api.registerOutcomes.add(StateError('ağ'));
      rig.start();
      expect(rig.coordinator.state, PushState.failed);
      rig.refresh();
      expect(rig.coordinator.state, PushState.registered);
      expect(rig.api.registerCalls, hasLength(2));
      expect(rig.async.pendingTimers, isEmpty, reason: 'eski geri çekilme zamanlayıcısı iptal edilmeli');
      // Eski zamanlayıcı artık ikinci bir deneme üretmez.
      rig.async.elapse(const Duration(minutes: 5));
      expect(rig.api.registerCalls, hasLength(2));
      expect(rig.async.pendingTimers, isEmpty);
    });

    _test('geri çekilme üssü taşmaz: yüzlerce başarısızlıktan sonra da gecikme retryMax kalır', (rig) {
      rig.api.registerOutcomes.addAll(List<Object?>.generate(200, (_) => StateError('ağ')));
      rig.start();
      for (var i = 0; i < 70; i++) {
        rig.async.elapse(const Duration(minutes: 15));
      }
      // Taşma olsaydı üs 59'dan sonra gecikme 1 ms'ye düşer, kuyruktaki 200 hata hemen tüketilirdi.
      expect(rig.api.registerCalls.length, lessThan(100));
      expect(rig.coordinator.state, PushState.failed);
    });

    _test('api zaman aşımı gibi her türlü istisna geçici sayılır', (rig) {
      rig.api.registerOutcomes.add(TimeoutException('yavaş'));
      rig.start();
      expect(rig.coordinator.state, PushState.failed);
      expect(rig.async.pendingTimers, hasLength(1));
    });
  });

  group('kalıcı red', () {
    _test('PushRegistrationRejected failed yapar ve yeniden denemeyi durdurur', (rig) {
      rig.api.registerOutcomes.add(const PushRegistrationRejected('403'));
      rig.start();
      expect(rig.coordinator.state, PushState.failed);
      expect(rig.async.pendingTimers, isEmpty);
      rig.async.elapse(const Duration(hours: 48));
      expect(rig.api.registerCalls, hasLength(1));
    });

    _test('red sonrası refresh de sunucuyu yormaz', (rig) {
      rig.api.registerOutcomes.add(const PushRegistrationRejected());
      rig.start();
      rig.refresh();
      rig.refresh();
      expect(rig.api.registerCalls, hasLength(1));
      expect(rig.coordinator.state, PushState.failed);
    });

    _test('red sonrası yeni token (onTokenRefresh) yeniden dener', (rig) {
      rig.api.registerOutcomes.add(const PushRegistrationRejected());
      rig.start();
      rig.gateway.tokenRefresh.add('token-2');
      rig.async.flushMicrotasks();
      expect(rig.api.registerCalls, hasLength(2));
      expect(rig.coordinator.state, PushState.registered);
    });

    _test('yeni token ile kayıt başarılı olunca kalıcı red kalkar: sonraki refresh yeniden kaydeder', (rig) {
      rig.api.registerOutcomes.add(const PushRegistrationRejected());
      rig.start();
      rig.gateway.tokenProvider = () async => 'token-2';
      rig.gateway.tokenRefresh.add('token-2');
      rig.async.flushMicrotasks();
      expect(rig.api.registerCalls, hasLength(2));
      rig.async.elapse(const Duration(hours: 25));
      rig.refresh();
      expect(rig.api.registerCalls, hasLength(3), reason: 'red bayrağı yeni token ile sıfırlanmalı');
    });

    _test('red sonrası kullanıcının açık eylemi yeniden dener', (rig) {
      rig.api.registerOutcomes.add(const PushRegistrationRejected());
      rig.start();
      rig.run(rig.coordinator.requestPermissionAndRegister());
      expect(rig.api.registerCalls, hasLength(2));
      expect(rig.coordinator.state, PushState.registered);
    });

    _test('red sonrası yeni oturum (stop + start) yeniden dener', (rig) {
      rig.api.registerOutcomes.add(const PushRegistrationRejected());
      rig.start();
      rig.stop();
      rig.start();
      expect(rig.api.registerCalls, hasLength(2));
      expect(rig.coordinator.state, PushState.registered);
    });

    test('PushRegistrationRejected.toString neden olmadan da çalışır', () {
      expect(const PushRegistrationRejected().toString(), 'PushRegistrationRejected');
      expect(const PushRegistrationRejected('400').toString(), 'PushRegistrationRejected(400)');
    });
  });

  group('tek uçuş ve yarışlar', () {
    _test('eşzamanlı çoklu start tek istek üretir', (rig) {
      rig.api.registerGate = Completer<void>();
      rig.start();
      rig.start();
      rig.start(prompt: true);
      expect(rig.api.registerCalls, hasLength(1));
      rig.api.registerGate!.complete();
      rig.async.flushMicrotasks();
      expect(rig.api.registerCalls, hasLength(1));
      expect(rig.coordinator.state, PushState.registered);
    });

    _test('uçuştaki kayıt hızlı biterse stop onu bekler ve silme de tamamlanır', (rig) {
      rig.api.registerGate = Completer<void>();
      rig.start();
      expect(rig.coordinator.state, PushState.registering);

      var stopped = false;
      rig.coordinator.stop().then((_) => stopped = true);
      rig.async.flushMicrotasks();
      expect(rig.coordinator.state, PushState.idle);
      expect(stopped, isFalse, reason: 'unregisterTimeout dolmadı, kayıt hâlâ uçuşta');

      rig.async.elapse(const Duration(seconds: 1));
      rig.api.registerGate!.complete();
      rig.async.flushMicrotasks();
      expect(stopped, isTrue);
      expect(rig.api.unregisterCalls, <String>['token-1']);
      expect(rig.coordinator.state, PushState.idle, reason: 'eski oturumun sonucu durumu değiştirmemeli');
      expect(rig.async.pendingTimers, isEmpty);
    });

    _test('uçuştaki kayıt takılırsa stop yine de unregisterTimeout sonra döner, geç düşen kayıt silinir', (rig) {
      rig.api.registerGate = Completer<void>();
      rig.start();
      var stopped = false;
      rig.coordinator.stop().then((_) => stopped = true);
      rig.async.elapse(const Duration(seconds: 2, milliseconds: 999));
      expect(stopped, isFalse);
      rig.async.elapse(const Duration(milliseconds: 1));
      expect(stopped, isTrue, reason: 'çıkış ekranı kayıt isteğine bağlı donmamalı');
      expect(rig.api.unregisterCalls, isEmpty);

      // İstek sonunda sunucuya ulaşırsa, çıkış yapmış kullanıcıya bildirim gitmesin diye arka planda silinir.
      rig.api.registerGate!.complete();
      rig.async.flushMicrotasks();
      expect(rig.api.unregisterCalls, <String>['token-1']);
      expect(rig.coordinator.state, PushState.idle);
    });

    _test('stop ile geçersiz kılınan sıradaki refresh gateway ya da api çağırmaz', (rig) {
      rig.api.registerGate = Completer<void>();
      rig.start();
      expect(rig.gateway.count('initialize'), 1);
      rig.coordinator.refresh();
      rig.coordinator.stop();
      rig.api.registerGate!.complete();
      rig.async.flushMicrotasks();
      expect(rig.gateway.count('initialize'), 1);
      expect(rig.gateway.count('permissionStatus'), 1);
      expect(rig.gateway.count('getToken'), 1);
      expect(rig.api.registerCalls, hasLength(1));
      expect(rig.api.unregisterCalls, <String>['token-1']);
    });

    _test('stop sonra hemen start: eski oturum silinir, yeni oturum kaydolur', (rig) {
      rig.start();
      rig.coordinator.stop();
      rig.coordinator.start();
      rig.async.flushMicrotasks();
      expect(rig.api.unregisterCalls, <String>['token-1']);
      expect(rig.api.registerCalls, hasLength(2));
      expect(rig.coordinator.state, PushState.registered);
    });

    _test('start sonra hemen stop: kayıt hiç denenmez ya da sonradan temizlenir', (rig) {
      rig.coordinator.start();
      rig.coordinator.stop();
      rig.async.flushMicrotasks();
      expect(rig.coordinator.state, PushState.idle);
      // Kayıt yapılmışsa mutlaka silinmiş olmalı.
      expect(rig.api.unregisterCalls.length, rig.api.registerCalls.length);
      expect(rig.async.pendingTimers, isEmpty);
    });

    _test('stop uçuştaki yeniden denemeyi iptal eder (zamanlayıcı kalmaz)', (rig) {
      rig.api.registerOutcomes.add(StateError('ağ'));
      rig.start();
      expect(rig.async.pendingTimers, hasLength(1));
      rig.stop();
      expect(rig.async.pendingTimers, isEmpty);
      rig.async.elapse(const Duration(hours: 1));
      expect(rig.api.registerCalls, hasLength(1));
      expect(rig.api.unregisterCalls, isEmpty);
    });

    _test('çoklu stop güvenlidir', (rig) {
      rig.start();
      rig.coordinator.stop();
      rig.coordinator.stop();
      rig.async.flushMicrotasks();
      expect(rig.api.unregisterCalls, hasLength(1));
      expect(rig.coordinator.state, PushState.idle);
    });

    _test('stop oturum açılmadan çağrılırsa zararsızdır', (rig) {
      expect(rig.stop(), isTrue);
      expect(rig.api.unregisterCalls, isEmpty);
      expect(rig.coordinator.state, PushState.idle);
    });
  });

  group('takılan çağrılar kuyruğu kilitlemez', () {
    _test('takılan kayıt stepTimeout sonra geçici hata sayılır; sonuç belirsiz olduğundan çıkışta silinir', (rig) {
      rig.api.registerGate = Completer<void>(); // hiç tamamlanmaz
      rig.start();
      rig.async.elapse(const Duration(seconds: 29, milliseconds: 999));
      expect(rig.coordinator.state, PushState.registering);
      rig.async.elapse(const Duration(milliseconds: 1));
      expect(rig.coordinator.state, PushState.failed);
      expect(rig.async.pendingTimers, hasLength(1), reason: 'geri çekilmeyle yeniden denenmeli');
      // İstek sunucuya ulaşmış olabilir: çıkışta bu belirteç için silme gönderilmeli.
      expect(rig.stop(), isTrue);
      expect(rig.api.unregisterCalls, <String>['token-1']);
    });

    _test('takılan kayıt + stop sonrası yeni oturum, kuyruk boşalınca kaydolur', (rig) {
      rig.api.registerGate = Completer<void>();
      rig.start();
      rig.coordinator.stop();
      rig.api.registerGate = null;
      rig.coordinator.start();
      rig.async.elapse(const Duration(seconds: 3));
      expect(rig.api.registerCalls, hasLength(1), reason: 'eski istek hâlâ uçuşta, kuyruk bekliyor');
      rig.async.elapse(const Duration(seconds: 27));
      expect(rig.api.unregisterCalls, <String>['token-1'], reason: 'zaman aşımına uğrayan kayıt belirsizdi');
      expect(rig.api.registerCalls, hasLength(2));
      expect(rig.coordinator.state, PushState.registered);
    });

    _test('takılan initialize: stop hemen döner, zaman aşımı sonrası yeni oturum kaydolur', (rig) {
      rig.gateway.initializeGate = Completer<void>();
      var stopped = false;
      rig.start();
      rig.coordinator.stop().then((_) => stopped = true);
      rig.async.elapse(const Duration(seconds: 3));
      expect(stopped, isTrue);
      rig.gateway.initializeGate = null;
      rig.start();
      rig.async.elapse(const Duration(seconds: 27));
      expect(rig.gateway.count('initialize'), 2);
      expect(rig.coordinator.state, PushState.registered);
    });

    _test('takılan initialize açık oturumda geçici hata sayılır (unsupported değil) ve yeniden denenir', (rig) {
      rig.gateway.initializeGate = Completer<void>();
      rig.start();
      rig.async.elapse(const Duration(seconds: 30));
      expect(rig.coordinator.state, PushState.failed);
      rig.gateway.initializeGate = null;
      rig.async.elapse(const Duration(seconds: 30));
      expect(rig.coordinator.state, PushState.registered);
    });

    _test('takılan getInitialMessage kaydı geciktirmez ve stop\'u bloklamaz', (rig) {
      rig.gateway.initialMessageProvider = () => Completer<PushMessage?>().future;
      expect(rig.start(), isTrue);
      expect(rig.coordinator.state, PushState.registered);
      expect(rig.stop(), isTrue);
      expect(rig.api.unregisterCalls, <String>['token-1']);
      // Yeni oturum da aynı takılma altında kaydolur.
      expect(rig.start(), isTrue);
      expect(rig.coordinator.state, PushState.registered);
    });

    _test('geç gelen başlangıç mesajı oturum hâlâ geçerliyse iletilir', (rig) {
      final late = Completer<PushMessage?>();
      rig.gateway.initialMessageProvider = () => late.future;
      final notices = <PeaceNotice>[];
      rig.coordinator.notices.listen(notices.add);
      rig.start();
      expect(notices, isEmpty);
      late.complete(_message(noticeId: '9'));
      rig.async.flushMicrotasks();
      expect(notices.map((n) => n.noticeId), <int?>[9]);
    });

    _test('takılan getToken stepTimeout sonra geçici hata sayılır', (rig) {
      rig.gateway.tokenProvider = () => Completer<String?>().future;
      rig.start();
      expect(rig.coordinator.state, PushState.idle);
      rig.async.elapse(const Duration(seconds: 30));
      expect(rig.coordinator.state, PushState.failed);
      expect(rig.async.pendingTimers, hasLength(1));
    });

    _test('takılan permissionStatus kuyruğu kilitlemez; refresh sonra düzeltir', (rig) {
      rig.gateway.permissionStatusGate = Completer<void>();
      rig.start();
      rig.async.elapse(const Duration(seconds: 30));
      expect(rig.coordinator.state, PushState.needsPermission);
      rig.gateway.permissionStatusGate = null;
      rig.refresh();
      expect(rig.coordinator.state, PushState.registered);
    });

    _test('sistem izin penceresi zaman aşımına uğramaz: kullanıcı yanıtlayana kadar beklenir', (rig) {
      rig.gateway.permission = PushPermission.notDetermined;
      rig.gateway.requestPermissionGate = Completer<void>();
      rig.start(prompt: true);
      rig.async.elapse(const Duration(minutes: 10));
      expect(rig.coordinator.state, PushState.idle);
      expect(rig.api.registerCalls, isEmpty);
      rig.gateway.requestPermissionGate!.complete();
      rig.async.flushMicrotasks();
      expect(rig.coordinator.state, PushState.registered);
    });

    _test('önceki oturumun silme isteği bitmeden aynı belirteç yeniden kaydedilmez', (rig) {
      rig.start();
      rig.api.unregisterGate = Completer<void>();
      rig.coordinator.stop();
      rig.coordinator.start();
      rig.async.flushMicrotasks();
      expect(rig.api.unregisterCalls, <String>['token-1']);
      expect(rig.api.registerCalls, hasLength(1), reason: 'PUT, DELETE\'ten önce işlenmemeli');
      rig.async.elapse(const Duration(seconds: 3));
      expect(rig.api.registerCalls, hasLength(2));
      expect(rig.coordinator.state, PushState.registered);
    });
  });

  group('stop her bekleme noktasında oturumu geçersiz kılar', () {
    void expectInert(_Rig rig) {
      expect(rig.coordinator.state, PushState.idle);
      expect(rig.api.registerCalls, isEmpty);
      expect(rig.api.unregisterCalls, isEmpty);
      expect(rig.gateway.tokenRefresh.hasListener, isFalse);
      expect(rig.gateway.foreground.hasListener, isFalse);
      expect(rig.gateway.opened.hasListener, isFalse);
      expect(rig.async.pendingTimers, isEmpty);
    }

    _test('initialize sürerken', (rig) {
      rig.gateway.initializeGate = Completer<void>();
      rig.start();
      rig.coordinator.stop();
      rig.gateway.initializeGate!.complete();
      rig.async.flushMicrotasks();
      expect(rig.gateway.count('permissionStatus'), 0);
      expect(rig.gateway.count('getToken'), 0);
      expectInert(rig);
    });

    _test('permissionStatus sürerken', (rig) {
      rig.gateway.permission = PushPermission.notDetermined;
      rig.gateway.permissionStatusGate = Completer<void>();
      rig.start(prompt: true);
      rig.coordinator.stop();
      rig.gateway.permissionStatusGate!.complete();
      rig.async.flushMicrotasks();
      expect(rig.gateway.count('requestPermission'), 0);
      expect(rig.gateway.count('getToken'), 0);
      expectInert(rig);
    });

    _test('requestPermission sürerken', (rig) {
      rig.gateway.permission = PushPermission.notDetermined;
      rig.gateway.requestPermissionGate = Completer<void>();
      rig.start(prompt: true);
      rig.coordinator.stop();
      rig.gateway.requestPermissionGate!.complete();
      rig.async.flushMicrotasks();
      expect(rig.gateway.count('getToken'), 0);
      expectInert(rig);
    });

    _test('getToken sürerken', (rig) {
      final token = Completer<String?>();
      rig.gateway.tokenProvider = () => token.future;
      rig.start();
      rig.coordinator.stop();
      token.complete('token-1');
      rig.async.flushMicrotasks();
      expectInert(rig);
    });

    _test('getInitialMessage sürerken gelen mesaj iletilmez', (rig) {
      final initial = Completer<PushMessage?>();
      rig.gateway.initialMessageProvider = () => initial.future;
      final notices = <PeaceNotice>[];
      rig.coordinator.notices.listen(notices.add);
      rig.start();
      rig.stop(unregister: false);
      initial.complete(_message());
      rig.async.flushMicrotasks();
      expect(notices, isEmpty);
    });

    _test('dispose sırasında uçuştaki işlem durumu ya da akışları bozmaz', (rig) {
      rig.gateway.permissionStatusGate = Completer<void>();
      rig.start();
      rig.coordinator.dispose();
      rig.async.elapse(const Duration(seconds: 3));
      rig.gateway.permissionStatusGate!.complete();
      rig.async.flushMicrotasks();
      expect(rig.api.registerCalls, isEmpty);
      expect(rig.async.pendingTimers, isEmpty);
    });
  });

  group('stop ve kayıt silme', () {
    _test('stop(unregister: false) sunucu kaydını hatırlar; sonraki stop() onu siler', (rig) {
      rig.start();
      rig.stop(unregister: false);
      expect(rig.api.unregisterCalls, isEmpty);
      rig.stop();
      expect(rig.api.unregisterCalls, <String>['token-1']);
      rig.stop();
      expect(rig.api.unregisterCalls, hasLength(1));
    });

    _test('stop(unregister: false) sonrası start tazelik bilgisini atar ve yeniden kaydeder', (rig) {
      rig.start();
      rig.stop(unregister: false);
      rig.start();
      expect(rig.api.registerCalls, hasLength(2), reason: 'yeni oturum sunucuya yeniden bağlanmalı');
      rig.stop();
      expect(rig.api.unregisterCalls, <String>['token-1']);
    });

    _test('kapanmış oturumun geç düşen kaydı yeni oturumda taze sayılmaz, yeniden kaydedilir', (rig) {
      rig.api.registerGate = Completer<void>();
      rig.start();
      rig.coordinator.stop(unregister: false);
      rig.api.registerGate!.complete();
      rig.async.flushMicrotasks();
      rig.api.registerGate = null;
      rig.start();
      expect(rig.api.registerCalls, hasLength(2), reason: 'yeni kullanıcı belirteci kendi hesabına bağlamalı');
      expect(rig.coordinator.state, PushState.registered);
    });

    _test('stop(unregister: false) ile geç düşen kayıt da sonraki stop() ile silinir', (rig) {
      rig.api.registerGate = Completer<void>();
      rig.start();
      rig.coordinator.stop(unregister: false);
      rig.api.registerGate!.complete();
      rig.async.flushMicrotasks();
      expect(rig.api.unregisterCalls, isEmpty);
      rig.stop();
      expect(rig.api.unregisterCalls, <String>['token-1']);
    });

    _test('registered iken stop son token\'ı siler, abonelikleri iptal eder', (rig) {
      rig.start();
      expect(rig.gateway.tokenRefresh.hasListener, isTrue);
      expect(rig.stop(), isTrue);
      expect(rig.api.unregisterCalls, <String>['token-1']);
      expect(rig.coordinator.state, PushState.idle);
      expect(rig.gateway.tokenRefresh.hasListener, isFalse);
      expect(rig.gateway.foreground.hasListener, isFalse);
      expect(rig.gateway.opened.hasListener, isFalse);
    });

    _test('yenilenmiş token varsa yalnızca sonuncusu silinir', (rig) {
      rig.start();
      rig.gateway.tokenRefresh.add('token-2');
      rig.async.flushMicrotasks();
      rig.stop();
      expect(rig.api.unregisterCalls, <String>['token-2']);
    });

    _test('unregister: false ise silme isteği gitmez', (rig) {
      rig.start();
      rig.stop(unregister: false);
      expect(rig.api.unregisterCalls, isEmpty);
    });

    _test('kayıtlı değilse (needsPermission) silme isteği gitmez', (rig) {
      rig.gateway.permission = PushPermission.denied;
      rig.start();
      rig.stop();
      expect(rig.api.unregisterCalls, isEmpty);
    });

    _test('kayıt hiç başarılı olmadıysa (failed) silme isteği gitmez', (rig) {
      rig.api.registerOutcomes.add(const PushRegistrationRejected());
      rig.start();
      rig.stop();
      expect(rig.api.unregisterCalls, isEmpty);
    });

    _test('silme hatası yutulur', (rig) {
      rig.api.unregisterError = StateError('401');
      rig.start();
      expect(rig.stop(), isTrue);
      expect(rig.api.unregisterCalls, hasLength(1));
      expect(rig.coordinator.state, PushState.idle);
    });

    _test('silme yanıt vermezse stop en çok unregisterTimeout bekler', (rig) {
      rig.start();
      rig.api.unregisterGate = Completer<void>();
      var stopped = false;
      rig.coordinator.stop().then((_) => stopped = true);
      rig.async.elapse(const Duration(seconds: 2, milliseconds: 999));
      expect(stopped, isFalse);
      rig.async.elapse(const Duration(milliseconds: 1));
      expect(stopped, isTrue);
      expect(rig.async.pendingTimers, isEmpty);
    });

    _test('stop sonrası aynı belirteç için ikinci silme gitmez', (rig) {
      rig.start();
      rig.stop();
      rig.stop();
      expect(rig.api.unregisterCalls, hasLength(1));
    });

    _test('stop sonrası gelen mesajlar ve token yenilemeleri yok sayılır', (rig) {
      final notices = <PeaceNotice>[];
      rig.coordinator.notices.listen(notices.add);
      rig.start();
      rig.stop();
      rig.gateway.foreground.add(_message());
      rig.gateway.opened.add(_message(noticeId: '42'));
      rig.gateway.tokenRefresh.add('token-9');
      rig.async.flushMicrotasks();
      expect(notices, isEmpty);
      expect(rig.api.registerCalls, hasLength(1));
    });

    _test('stop sonrası start yeniden kaydeder ve yeniden abone olur', (rig) {
      rig.start();
      rig.stop();
      rig.start();
      expect(rig.coordinator.state, PushState.registered);
      expect(rig.api.registerCalls, hasLength(2));
      expect(rig.gateway.foreground.hasListener, isTrue);
    });
  });

  group('bildirimler', () {
    _test('foreground / opened / initial kaynakları etiketlenir', (rig) {
      final notices = <PeaceNotice>[];
      rig.coordinator.notices.listen(notices.add);
      rig.gateway.initialMessageProvider = () async => _message(noticeId: '1');
      rig.start();
      rig.gateway.foreground.add(_message(noticeId: '2'));
      rig.gateway.opened.add(_message(noticeId: '3'));
      rig.async.flushMicrotasks();
      expect(notices.map((n) => n.noticeId), <int?>[1, 2, 3]);
      expect(notices.map((n) => n.source), <PeaceNoticeSource>[
        PeaceNoticeSource.initial,
        PeaceNoticeSource.foreground,
        PeaceNoticeSource.opened,
      ]);
      expect(notices.first.openLights, 2);
      expect(notices.first.title, 'Evim');
    });

    _test('geçersiz mesaj sessizce yok sayılır', (rig) {
      final notices = <PeaceNotice>[];
      rig.coordinator.notices.listen(notices.add);
      rig.start();
      rig.gateway.foreground.add(const PushMessage(data: <String, dynamic>{'type': 'baska'}));
      rig.gateway.foreground.add(const PushMessage(data: <String, dynamic>{}));
      rig.gateway.opened.add(PushMessage(data: _data(lights: '-1')));
      rig.async.flushMicrotasks();
      expect(notices, isEmpty);
    });

    _test('aynı noticeId 10 dk içinde ikinci kez iletilmez (kaynak fark etmez)', (rig) {
      final notices = <PeaceNotice>[];
      rig.coordinator.notices.listen(notices.add);
      rig.start();
      rig.gateway.foreground.add(_message());
      rig.async.flushMicrotasks();
      rig.async.elapse(const Duration(minutes: 9, seconds: 59));
      rig.gateway.opened.add(_message());
      rig.async.flushMicrotasks();
      expect(notices, hasLength(1));
      expect(notices.single.source, PeaceNoticeSource.foreground);
    });

    _test('10 dk geçtikten sonra aynı noticeId yeniden iletilir', (rig) {
      final notices = <PeaceNotice>[];
      rig.coordinator.notices.listen(notices.add);
      rig.start();
      rig.gateway.foreground.add(_message());
      rig.async.flushMicrotasks();
      rig.async.elapse(const Duration(minutes: 10));
      rig.gateway.opened.add(_message());
      rig.async.flushMicrotasks();
      expect(notices, hasLength(2));
    });

    _test('farklı noticeId\'ler ayrı ayrı iletilir', (rig) {
      final notices = <PeaceNotice>[];
      rig.coordinator.notices.listen(notices.add);
      rig.start();
      rig.gateway.foreground.add(_message(noticeId: '1'));
      rig.gateway.foreground.add(_message(noticeId: '2'));
      rig.async.flushMicrotasks();
      expect(notices, hasLength(2));
    });

    _test('noticeId yoksa ev+başlık+gövdeye göre tekilleştirilir', (rig) {
      final notices = <PeaceNotice>[];
      rig.coordinator.notices.listen(notices.add);
      rig.start();
      rig.gateway.foreground.add(_message(noticeId: null));
      rig.gateway.opened.add(_message(noticeId: null));
      rig.gateway.opened.add(_message(noticeId: null, body: 'Mutfakta 1 lamba açık.'));
      rig.async.flushMicrotasks();
      expect(notices, hasLength(2));
      expect(notices.last.body, 'Mutfakta 1 lamba açık.');
    });

    _test('tekilleştirme stop/start boyunca korunur', (rig) {
      final notices = <PeaceNotice>[];
      rig.coordinator.notices.listen(notices.add);
      rig.start();
      rig.gateway.foreground.add(_message());
      rig.async.flushMicrotasks();
      rig.stop();
      rig.start();
      rig.gateway.foreground.add(_message());
      rig.async.flushMicrotasks();
      expect(notices, hasLength(1));
    });

    _test('notices akışı stop ile kapanmaz, dispose ile kapanır', (rig) {
      var done = false;
      rig.coordinator.notices.listen((_) {}, onDone: () => done = true);
      rig.start();
      rig.stop();
      expect(done, isFalse);
      rig.run(rig.coordinator.dispose());
      expect(done, isTrue);
    });

    _test('dinleyici yokken gelen bildirim ilk dinleyiciye iletilir', (rig) {
      rig.gateway.initialMessageProvider = () async => _message(noticeId: '7');
      rig.start();
      final notices = <PeaceNotice>[];
      rig.coordinator.notices.listen(notices.add);
      rig.async.flushMicrotasks();
      expect(notices.map((n) => n.noticeId), <int?>[7]);
      expect(notices.single.source, PeaceNoticeSource.initial);
    });

    _test('dinleyici yokken biriken bildirim 10 dk sonra bayat sayılır', (rig) {
      rig.gateway.initialMessageProvider = () async => _message(noticeId: '7');
      rig.start();
      rig.async.elapse(const Duration(minutes: 11));
      final notices = <PeaceNotice>[];
      rig.coordinator.notices.listen(notices.add);
      rig.async.flushMicrotasks();
      expect(notices, isEmpty);
    });

    _test('tamponlanan bildirim yalnızca bir kez iletilir', (rig) {
      rig.gateway.initialMessageProvider = () async => _message(noticeId: '7');
      rig.start();
      final first = <PeaceNotice>[];
      final firstSub = rig.coordinator.notices.listen(first.add);
      rig.async.flushMicrotasks();
      firstSub.cancel();
      final second = <PeaceNotice>[];
      rig.coordinator.notices.listen(second.add);
      rig.async.flushMicrotasks();
      expect(first, hasLength(1));
      expect(second, isEmpty);
    });

    _test('izin reddedilmiş olsa da açılış bildirimi iletilir', (rig) {
      final notices = <PeaceNotice>[];
      rig.coordinator.notices.listen(notices.add);
      rig.gateway.permission = PushPermission.denied;
      rig.gateway.initialMessageProvider = () async => _message(noticeId: '5');
      rig.start();
      expect(rig.coordinator.state, PushState.needsPermission);
      expect(notices, hasLength(1));
    });

    _test('çok sayıda farklı bildirimin hepsi iletilir ve akış sürer', (rig) {
      final notices = <PeaceNotice>[];
      rig.coordinator.notices.listen(notices.add);
      rig.start();
      for (var i = 1; i <= 200; i++) {
        rig.gateway.foreground.add(_message(noticeId: '$i'));
      }
      rig.async.flushMicrotasks();
      expect(notices, hasLength(200));
    });

    _test('tekilleştirme belleği sınırlıdır: en eski kayıt unutulur, yenileri hatırlanır', (rig) {
      final notices = <PeaceNotice>[];
      rig.coordinator.notices.listen(notices.add);
      rig.start();
      const cap = PushCoordinator.maxSeenNotices;
      for (var i = 1; i <= cap + 1; i++) {
        rig.gateway.foreground.add(_message(noticeId: '$i'));
      }
      rig.async.flushMicrotasks();
      expect(notices, hasLength(cap + 1));

      // En yeniler hâlâ hatırlanıyor: tekrar iletilmez.
      rig.gateway.foreground.add(_message(noticeId: '${cap + 1}'));
      rig.gateway.foreground.add(_message(noticeId: '2'));
      rig.async.flushMicrotasks();
      expect(notices, hasLength(cap + 1));

      // En eskisi (1) sınır aşılınca atıldı: bellek şişmesin diye yeniden iletilebilir.
      rig.gateway.foreground.add(_message(noticeId: '1'));
      rig.async.flushMicrotasks();
      expect(notices, hasLength(cap + 2));
    });

    _test('dinleyici yokken tampon sınırlıdır: en eski bildirimler atılır', (rig) {
      rig.start();
      const cap = PushCoordinator.maxBufferedNotices;
      for (var i = 1; i <= cap + 2; i++) {
        rig.gateway.foreground.add(_message(noticeId: '$i'));
      }
      rig.async.flushMicrotasks();
      final notices = <PeaceNotice>[];
      rig.coordinator.notices.listen(notices.add);
      rig.async.flushMicrotasks();
      expect(notices.map((n) => n.noticeId), <int?>[for (var i = 3; i <= cap + 2; i++) i]);
    });

    _test('tampon boşaltılırken yalnızca bayatlamamış olanlar iletilir', (rig) {
      rig.start();
      rig.gateway.foreground.add(_message(noticeId: '1'));
      rig.async.flushMicrotasks();
      rig.async.elapse(const Duration(minutes: 6));
      rig.gateway.foreground.add(_message(noticeId: '2'));
      rig.async.flushMicrotasks();
      rig.async.elapse(const Duration(minutes: 5)); // 1: 11 dk (bayat), 2: 5 dk
      final notices = <PeaceNotice>[];
      rig.coordinator.notices.listen(notices.add);
      rig.async.flushMicrotasks();
      expect(notices.map((n) => n.noticeId), <int?>[2]);
    });
  });

  group('getInitialMessage', () {
    _test('her start oturumunda en çok bir kez okunur', (rig) {
      rig.start();
      rig.start();
      rig.refresh();
      rig.refresh();
      rig.run(rig.coordinator.requestPermissionAndRegister());
      expect(rig.gateway.count('getInitialMessage'), 1);
    });

    _test('stop sonrası yeni oturumda yeniden okunur', (rig) {
      rig.start();
      rig.stop();
      rig.start();
      expect(rig.gateway.count('getInitialMessage'), 2);
    });

    _test('getInitialMessage fırlatırsa kayıt akışı etkilenmez', (rig) {
      rig.gateway.throwing.add('getInitialMessage');
      rig.start();
      expect(rig.coordinator.state, PushState.registered);
    });
  });

  group('hata dayanıklılığı (asla fırlatma)', () {
    _test('tüm gateway yöntemleri fırlatsa bile start/refresh/stop tamamlanır', (rig) {
      rig.gateway.throwing.addAll(<String>['permissionStatus', 'requestPermission', 'getToken', 'getInitialMessage']);
      expect(rig.start(prompt: true), isTrue);
      expect(rig.coordinator.state, PushState.needsPermission);
      expect(rig.refresh(), isTrue);
      expect(rig.stop(), isTrue);
    });

    _test('api her zaman fırlatsa bile durum makinesi çökmez', (rig) {
      rig.api.registerOutcomes.addAll(List<Object?>.generate(20, (_) => ArgumentError('x')));
      rig.api.unregisterError = ArgumentError('y');
      expect(rig.start(), isTrue);
      rig.async.elapse(const Duration(hours: 3));
      expect(rig.coordinator.state, anyOf(PushState.failed, PushState.registering, PushState.registered));
      expect(rig.stop(), isTrue);
    });

    _test('gateway akışlarındaki hatalar yutulur ve dinleme sürer', (rig) {
      final notices = <PeaceNotice>[];
      rig.coordinator.notices.listen(notices.add);
      rig.start();
      rig.gateway.foreground.addError(StateError('platform'));
      rig.gateway.tokenRefresh.addError(StateError('platform'));
      rig.gateway.opened.addError(StateError('platform'));
      rig.gateway.foreground.add(_message());
      rig.async.flushMicrotasks();
      expect(notices, hasLength(1));
    });
  });

  group('dispose', () {
    _test('akışları kapatır, kayıt silmez, sonrasında çağrılar etkisizdir', (rig) {
      var statesDone = false;
      rig.coordinator.states.listen((_) {}, onDone: () => statesDone = true);
      rig.start();
      expect(rig.run(rig.coordinator.dispose()), isTrue);
      expect(statesDone, isTrue);
      expect(rig.api.unregisterCalls, isEmpty);
      final calls = rig.gateway.calls.length;
      expect(rig.start(), isTrue);
      expect(rig.refresh(), isTrue);
      expect(rig.stop(), isTrue);
      expect(rig.gateway.calls.length, calls);
      expect(rig.api.registerCalls, hasLength(1));
    });

    _test('dispose iki kez çağrılabilir', (rig) {
      rig.start();
      rig.run(rig.coordinator.dispose());
      expect(rig.run(rig.coordinator.dispose()), isTrue);
    });
  });

  group('durum akışı', () {
    _test('yalnızca gerçek değişimlerde olay yayar', (rig) {
      rig.start();
      rig.refresh();
      rig.refresh();
      expect(rig.states, <PushState>[PushState.registering, PushState.registered]);
      rig.stop();
      expect(rig.states.last, PushState.idle);
    });

    _test('başlangıç durumu idle', (rig) {
      expect(rig.coordinator.state, PushState.idle);
      expect(rig.coordinator.permissionDenied, isFalse);
    });

    _test('desteklenmeyen cihazda stop durumu unsupported bırakır', (rig) {
      rig.gateway.supported = false;
      rig.start();
      rig.stop();
      expect(rig.coordinator.state, PushState.unsupported);
    });
  });

  // F1 (B1 / R3-01): çıkışta yerel FCM belirteci de geçersiz kılınır. Sunucu yalnızca FCM `UNREGISTERED`
  // görünce satırı kapatır; belirteç yerelde geçerli kalırsa çıkış yapmış telefona bildirim akar.
  group('yerel FCM belirtecini geçersiz kılma (deleteToken)', () {
    _test('stop() (çıkış): sunucu DELETE + yerel deleteToken ikisi de çağrılır', (rig) {
      rig.start();
      expect(rig.stop(), isTrue);
      expect(rig.api.unregisterCalls, <String>['token-1']);
      expect(rig.gateway.deleteTokenCalls, 1);
    });

    _test('stop(unregister: false) varsayılanı: deleteToken ÇAĞRILMAZ (geçici durdurma)', (rig) {
      rig.start();
      expect(rig.stop(unregister: false), isTrue);
      expect(rig.gateway.deleteTokenCalls, 0);
      expect(rig.api.unregisterCalls, isEmpty);
    });

    _test('stop(unregister: false, invalidateLocalToken: true): DELETE yok, deleteToken var, bellek sıfırlanır', (rig) {
      rig.start();
      expect(rig.stop(unregister: false, invalidateLocalToken: true), isTrue);
      expect(rig.gateway.deleteTokenCalls, 1);
      expect(rig.api.unregisterCalls, isEmpty);
      // Belirteç yerelde zaten geçersiz: sonraki çıkış sunucuya eski belirteç için DELETE yollamaz.
      rig.stop();
      expect(rig.api.unregisterCalls, isEmpty);
    });

    _test('stop(unregister: true, invalidateLocalToken: false): yalnızca sunucu DELETE', (rig) {
      rig.start();
      expect(rig.stop(invalidateLocalToken: false), isTrue);
      expect(rig.api.unregisterCalls, <String>['token-1']);
      expect(rig.gateway.deleteTokenCalls, 0);
    });

    _test('sunucu DELETE hata verse de deleteToken çağrılır', (rig) {
      rig.api.unregisterError = StateError('401');
      rig.start();
      expect(rig.stop(), isTrue);
      expect(rig.api.unregisterCalls, hasLength(1));
      expect(rig.gateway.deleteTokenCalls, 1);
    });

    _test('sunucu DELETE askıdayken deleteToken HEMEN çağrılır; stop 3 sn içinde döner', (rig) {
      rig.start();
      rig.api.unregisterGate = Completer<void>();
      var stopped = false;
      rig.coordinator.stop().then((_) => stopped = true);
      rig.async.flushMicrotasks();
      expect(rig.gateway.deleteTokenCalls, 1, reason: 'DELETE sonucunu/zaman aşımını beklemeden');
      rig.async.elapse(const Duration(seconds: 2, milliseconds: 999));
      expect(stopped, isFalse);
      rig.async.elapse(const Duration(milliseconds: 1));
      expect(stopped, isTrue);
    });

    _test('belirteç sunucuya hiç kaydedilmemiş olsa da (önceki oturum) deleteToken çağrılır', (rig) {
      expect(rig.stop(), isTrue);
      expect(rig.api.unregisterCalls, isEmpty);
      expect(rig.gateway.deleteTokenCalls, 1);
    });

    _test('deleteToken fırlatırsa stop yine döner; sonraki çıkış yeniden dener, başarıdan sonra denemez', (rig) {
      rig.start();
      rig.gateway.deleteTokenError = StateError('çevrimdışı');
      expect(rig.stop(), isTrue);
      expect(rig.gateway.deleteTokenCalls, 1);
      rig.gateway.deleteTokenError = null;
      expect(rig.stop(), isTrue);
      expect(rig.gateway.deleteTokenCalls, 2, reason: 'silinemedi: bir sonraki fırsatta yeniden denenir');
      expect(rig.stop(), isTrue);
      expect(rig.gateway.deleteTokenCalls, 2, reason: 'silindi ve yeni belirteç alınmadı: tekrar gerekmez');
    });

    _test('deleteToken askıda kalırsa stop en çok unregisterTimeout (3 sn) bekler', (rig) {
      rig.start();
      rig.gateway.deleteTokenGate = Completer<void>();
      var stopped = false;
      rig.coordinator.stop().then((_) => stopped = true);
      rig.async.elapse(const Duration(seconds: 2, milliseconds: 999));
      expect(stopped, isFalse);
      rig.async.elapse(const Duration(milliseconds: 1));
      expect(stopped, isTrue);
      expect(rig.async.pendingTimers, isEmpty);
    });

    _test('DELETE ve deleteToken birlikte askıdayken toplam bekleme 3 sn tavanını AŞMAZ', (rig) {
      rig.start();
      rig.api.unregisterGate = Completer<void>();
      rig.gateway.deleteTokenGate = Completer<void>();
      var stopped = false;
      rig.coordinator.stop().then((_) => stopped = true);
      rig.async.elapse(const Duration(seconds: 3));
      expect(stopped, isTrue);
    });

    _test('eşzamanlı ikinci stop deleteToken\'ı ikinci kez çağırmaz (tek uçuş)', (rig) {
      rig.start();
      rig.gateway.deleteTokenGate = Completer<void>();
      rig.coordinator.stop();
      rig.coordinator.stop(unregister: false, invalidateLocalToken: true);
      rig.async.flushMicrotasks();
      expect(rig.gateway.deleteTokenCalls, 1);
      rig.gateway.deleteTokenGate!.complete();
      rig.async.flushMicrotasks();
      rig.stop();
      expect(rig.gateway.deleteTokenCalls, 1, reason: 'belirteç zaten geçersiz');
    });

    _test('yeni oturum belirteç alınca sonraki çıkış yeniden geçersiz kılar', (rig) {
      rig.start();
      rig.stop();
      rig.start();
      rig.stop();
      expect(rig.gateway.deleteTokenCalls, 2);
    });

    _test('yenilenen belirteç de çıkışta geçersiz kılınır', (rig) {
      rig.start();
      rig.stop();
      expect(rig.gateway.deleteTokenCalls, 1);
      rig.gateway.tokenRefresh.add('token-2'); // oturum kapalı: yok sayılır
      rig.async.flushMicrotasks();
      rig.start();
      rig.gateway.tokenRefresh.add('token-3');
      rig.async.flushMicrotasks();
      rig.stop();
      expect(rig.gateway.deleteTokenCalls, 2);
    });

    _test('geçersiz kılma sürerken start: getToken bitmeden çağrılmaz (yeni belirteci silmesin)', (rig) {
      rig.start();
      rig.gateway.deleteTokenGate = Completer<void>();
      rig.coordinator.stop();
      rig.async.flushMicrotasks();
      final before = rig.gateway.count('getToken');
      rig.coordinator.start();
      rig.async.flushMicrotasks();
      expect(rig.gateway.count('getToken'), before, reason: 'deleteToken bitmedi');
      rig.gateway.deleteTokenGate!.complete();
      rig.async.flushMicrotasks();
      expect(rig.gateway.count('getToken'), before + 1);
      expect(rig.coordinator.state, PushState.registered);
    });

    _test('askıdaki deleteToken yeni oturumun kaydını SONSUZA DEK engellemez (3 sn sonra kaydolur)', (rig) {
      rig.start();
      rig.gateway.deleteTokenGate = Completer<void>(); // hiç bitmez
      rig.coordinator.stop();
      rig.coordinator.start();
      rig.async.elapse(const Duration(seconds: 2, milliseconds: 999));
      expect(rig.coordinator.state, isNot(PushState.registered), reason: 'silme bitmeden yeni belirteç alınmaz');
      rig.async.elapse(const Duration(milliseconds: 1));
      rig.async.flushMicrotasks();
      expect(rig.coordinator.state, PushState.registered);
      expect(rig.api.registerCalls, hasLength(2));
    });

    _test('yalnızca-yerel geçersiz kılma: uçuştaki kayıt sonradan düşse de bellek temiz kalır', (rig) {
      rig.api.registerGate = Completer<void>();
      rig.start();
      rig.coordinator.stop(unregister: false, invalidateLocalToken: true);
      rig.api.registerGate!.complete();
      rig.async.flushMicrotasks();
      rig.stop();
      expect(rig.api.unregisterCalls, isEmpty);
    });

    _test('dispose deleteToken çağırmaz (kaydı silmez)', (rig) {
      rig.start();
      rig.run(rig.coordinator.dispose());
      expect(rig.gateway.deleteTokenCalls, 0);
    });
  });

  // F1 (R2-4): kalıcı red ile geçici başarısızlık ayrımı ve elle yeniden deneme.
  group('kalıcı red bilgisi ve elle yeniden deneme', () {
    _test('kalıcı red: registrationBlocked true; geçici hata: false', (rig) {
      rig.api.registerOutcomes.add(const PushRegistrationRejected('400'));
      rig.start();
      expect(rig.coordinator.state, PushState.failed);
      expect(rig.coordinator.registrationBlocked, isTrue);

      final other = _Rig(rig.async);
      other.api.registerOutcomes.add(StateError('ağ'));
      other.start();
      expect(other.coordinator.state, PushState.failed);
      expect(other.coordinator.registrationBlocked, isFalse, reason: 'geçici hata otomatik yeniden denenir');
    });

    _test('başarıda ve yeni oturumda registrationBlocked false', (rig) {
      expect(rig.coordinator.registrationBlocked, isFalse);
      rig.api.registerOutcomes.add(const PushRegistrationRejected());
      rig.start();
      expect(rig.coordinator.registrationBlocked, isTrue);
      rig.stop();
      expect(rig.coordinator.registrationBlocked, isFalse);
      rig.start();
      expect(rig.coordinator.state, PushState.registered);
      expect(rig.coordinator.registrationBlocked, isFalse);
    });

    _test('retryRegistration: kalıcı reddi sıfırlar ve izin istemeden yeniden kaydeder', (rig) {
      rig.api.registerOutcomes.add(const PushRegistrationRejected());
      rig.start();
      expect(rig.run(rig.coordinator.retryRegistration()), isTrue);
      expect(rig.api.registerCalls, hasLength(2));
      expect(rig.coordinator.state, PushState.registered);
      expect(rig.coordinator.registrationBlocked, isFalse);
      expect(rig.gateway.count('requestPermission'), 0);
    });

    _test('retryRegistration tekrar reddedilirse yine kalıcı red', (rig) {
      rig.api.registerOutcomes
        ..add(const PushRegistrationRejected())
        ..add(const PushRegistrationRejected('403'));
      rig.start();
      rig.run(rig.coordinator.retryRegistration());
      expect(rig.api.registerCalls, hasLength(2));
      expect(rig.coordinator.state, PushState.failed);
      expect(rig.coordinator.registrationBlocked, isTrue);
      // Elle yeniden denenmedikçe sunucu yorulmaz.
      rig.refresh();
      rig.async.elapse(const Duration(hours: 2));
      expect(rig.api.registerCalls, hasLength(2));
    });

    _test('retryRegistration oturum yokken ve izin yokken etkisizdir (izin penceresi açmaz)', (rig) {
      expect(rig.run(rig.coordinator.retryRegistration()), isTrue);
      expect(rig.gateway.calls, isEmpty);

      rig.gateway.permission = PushPermission.notDetermined;
      rig.start();
      rig.run(rig.coordinator.retryRegistration());
      expect(rig.coordinator.state, PushState.needsPermission);
      expect(rig.gateway.count('requestPermission'), 0);
      expect(rig.api.registerCalls, isEmpty);
    });
  });

  group('varsayılan Random ve parametre doğrulaması', () {
    test('Random verilmezse kurucu hata vermez', () {
      final coordinator = PushCoordinator(gateway: FakeGateway(), api: FakeApi(), platform: 'ios');
      expect(coordinator.state, PushState.idle);
      expect(coordinator.retryBase, const Duration(seconds: 30));
      expect(coordinator.retryMax, const Duration(minutes: 15));
      expect(coordinator.reRegisterAfter, const Duration(hours: 24));
      expect(coordinator.unregisterTimeout, const Duration(seconds: 3));
    });

    test('geçersiz platform değeri assert ile reddedilir', () {
      expect(() => PushCoordinator(gateway: FakeGateway(), api: FakeApi(), platform: 'web'), throwsAssertionError);
    });

    test('FixedRandom gerçek Random arayüzünü karşılar', () {
      final Random random = FixedRandom(0.25);
      expect(random.nextDouble(), 0.25);
    });
  });
}
