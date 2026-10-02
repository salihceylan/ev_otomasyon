import 'dart:async';

import 'package:ev_otomasyon/models/api_models.dart';
import 'package:ev_otomasyon/models/automation_models.dart';
import 'package:ev_otomasyon/services/api_exception.dart';
import 'package:ev_otomasyon/services/automation_api_service.dart';
import 'package:ev_otomasyon/services/command_pipeline.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/support.dart';

DeviceStatus relayState(int id, bool on, {String? lastId}) => DeviceStatus(
      relays: <RelayItem>[RelayItem(id: id, name: 'R$id', type: 0, state: on)],
      lastId: lastId,
    );

DeviceStatus shutterState(int pair, {int pos = 0, bool moving = false, int dir = 0, int? target}) =>
    DeviceStatus(
      shutters: <ShutterItem>[
        ShutterItem(pair: pair, name: 'P$pair', pos: pos, isMoving: moving, direction: dir, target: target),
      ],
    );

void main() {
  late FakeClock clock;
  late CommandPipeline pipeline;
  late List<CommandFailure> failures;
  late List<String> confirmations;
  var changes = 0;

  /// Yayın akışı olayları mikro görev kuyruğunda iletilir: dinleyicilerin çalışması için boşalt.
  Future<void> flush() => pumpEventQueue();

  setUp(() {
    clock = FakeClock();
    changes = 0;
    pipeline = CommandPipeline(clock: clock, onChanged: () => changes++);
    failures = <CommandFailure>[];
    confirmations = <String>[];
    pipeline.failures.listen(failures.add);
    pipeline.confirmations.listen(confirmations.add);
  });

  tearDown(() => pipeline.dispose());

  CommandSender okSender({bool? deviceOnline, List<String>? ids, Completer<void>? gate}) => (id) async {
        ids?.add(id);
        if (gate != null) await gate.future;
        return CommandResult(delivered: true, deviceOnline: deviceOnline, commandId: id);
      };

  group('geri alma ve onay', () {
    test('2.5 sn içinde onay gelmezse geri alınır + hata olayı (timeout)', () async {
      final dispatch = await pipeline.submit(
        key: 'relay:3',
        original: false,
        target: true,
        send: okSender(),
        confirms: CommandConfirm.relay(3, true),
      );
      expect(dispatch.ok, isTrue); // REST iletildi
      expect(pipeline.isPending('relay:3'), isTrue);
      expect(pipeline.pendingFor('relay:3')!.target, true);
      expect(pipeline.pendingFor('relay:3')!.original, false);

      await clock.elapse(const Duration(milliseconds: 2400));
      expect(pipeline.isPending('relay:3'), isTrue, reason: '2.4 sn: henüz geri alınmaz');
      expect(failures, isEmpty);

      await clock.elapse(const Duration(milliseconds: 200));
      expect(pipeline.isPending('relay:3'), isFalse);
      expect(failures, hasLength(1));
      expect(failures.single.reason, CommandFailureReason.timeout);
      expect(failures.single.key, 'relay:3');
      expect(failures.single.message, contains('onay'));
    });

    test('hedefi doğrulayan state gelirse zamanlayıcı iptal olur (rollback YOK)', () async {
      await pipeline.submit(
        key: 'relay:3',
        original: false,
        target: true,
        send: okSender(),
        confirms: CommandConfirm.relay(3, true),
      );
      await clock.elapse(const Duration(seconds: 1));
      pipeline.observe(relayState(3, true));
      await flush();
      expect(pipeline.isPending('relay:3'), isFalse);
      expect(confirmations, <String>['relay:3']);

      await clock.elapse(const Duration(seconds: 10));
      expect(failures, isEmpty);
      expect(clock.activeTimerCount, 0);
    });

    test('hedefi doğrulamayan state onay sayılmaz; süre dolunca geri alınır', () async {
      await pipeline.submit(
        key: 'relay:3',
        original: false,
        target: true,
        send: okSender(),
        confirms: CommandConfirm.relay(3, true),
      );
      pipeline.observe(relayState(3, false)); // cihaz hâlâ eski değeri raporluyor
      pipeline.observe(relayState(4, true)); // başka röle
      expect(pipeline.isPending('relay:3'), isTrue);
      await clock.elapse(const Duration(milliseconds: 2600));
      expect(failures.single.reason, CommandFailureReason.timeout);
    });

    test('last_id komut kimliğimizi yankılarsa onay sayılır', () async {
      final ids = <String>[];
      await pipeline.submit(
        key: 'relay:3',
        original: false,
        target: true,
        send: okSender(ids: ids),
        confirms: (_) => false, // değer eşleşmesi hiç sağlanmasa da
      );
      pipeline.observe(relayState(3, false, lastId: ids.single));
      await flush();
      expect(pipeline.isPending('relay:3'), isFalse);
      expect(confirmations, <String>['relay:3']);
    });

    test('REST delivered=false -> ANINDA geri alınır (zamanlayıcıyı beklemez)', () async {
      final dispatch = await pipeline.submit(
        key: 'relay:3',
        original: false,
        target: true,
        send: (_) async => const CommandResult(delivered: false),
        confirms: CommandConfirm.relay(3, true),
      );
      await flush();
      expect(dispatch.status, CommandDispatchStatus.failed);
      expect(dispatch.failure!.reason, CommandFailureReason.notDelivered);
      expect(pipeline.isPending('relay:3'), isFalse);
      expect(failures, hasLength(1));
      expect(clock.activeTimerCount, 0);
    });

    test('409 DEVICE_OFFLINE -> anında geri alma + "çevrimdışı" mesajı', () async {
      final dispatch = await pipeline.submit(
        key: 'relay:3',
        original: false,
        target: true,
        send: (_) async => throw const ApiException(
          statusCode: 409,
          code: 'DEVICE_OFFLINE',
          message: 'Cihaz çevrimdışı',
        ),
        confirms: CommandConfirm.relay(3, true),
      );
      await flush();
      expect(dispatch.failure!.reason, CommandFailureReason.offline);
      expect(pipeline.isPending('relay:3'), isFalse);
      expect(failures.single.message, contains('çevrimdışı'));
      await clock.elapse(const Duration(seconds: 5));
      expect(failures, hasLength(1), reason: 'zamanlayıcı ikinci bir hata üretmemeli');
    });

    test('deviceOnline=false yanıtı da çevrimdışı sayılır', () async {
      final dispatch = await pipeline.submit(
        key: 'relay:3',
        original: false,
        target: true,
        send: (_) async => const CommandResult(delivered: true, deviceOnline: false),
      );
      expect(dispatch.failure!.reason, CommandFailureReason.offline);
    });

    test('ağ hatası ve sunucu reddi sınıflandırılır', () async {
      Future<CommandFailure> failWith(Object error) async {
        final d = await pipeline.submit(
          key: 'k${error.hashCode}',
          original: 0,
          target: 1,
          send: (_) async => throw error,
        );
        return d.failure!;
      }

      expect((await failWith(ApiException.network())).reason, CommandFailureReason.network);
      expect(
        (await failWith(const ApiException(statusCode: 403, code: 'FORBIDDEN', message: 'Yetkiniz yok'))).reason,
        CommandFailureReason.forbidden,
      );
      expect(
        (await failWith(const ApiException(statusCode: 429, code: 'RATE_LIMITED', message: 'Yavaş'))).reason,
        CommandFailureReason.rateLimited,
      );
      expect(
        (await failWith(const ApiException(statusCode: 502, code: 'BROKER_UNAVAILABLE', message: 'x'))).reason,
        CommandFailureReason.brokerUnavailable,
      );
      expect(
        (await failWith(const ApiException(statusCode: 400, code: 'VALIDATION', message: 'Geçersiz'))).reason,
        CommandFailureReason.validation,
      );
      final five = await failWith(const ApiException(statusCode: 500, message: 'ham iç mesaj'));
      expect(five.reason, CommandFailureReason.rejected);
      expect(five.message, isNot(contains('ham iç mesaj')));
      expect(
        (await failWith(const LocalApiException(statusCode: 401, message: 'anahtar'))).reason,
        CommandFailureReason.forbidden,
      );
      expect((await failWith(LocalApiException.network())).reason, CommandFailureReason.network);
      expect((await failWith(StateError('x'))).reason, CommandFailureReason.rejected);
    });

    test('onay penceresi İLETİMDEN başlar: REST 2.0 sn sürse de state 2.7 sn sonra gelirse YANLIŞ zaman aşımı yok', () async {
      final gate = Completer<void>();
      final dispatchFuture = pipeline.submit(
        key: 'relay:3',
        original: false,
        target: true,
        send: okSender(gate: gate),
        confirms: CommandConfirm.relay(3, true),
      );
      await clock.elapse(const Duration(milliseconds: 2000));
      expect(failures, isEmpty, reason: 'REST hâlâ uçuşta: onay bütçesi harcanmadı');
      gate.complete(); // REST t=2.0 sn'de döndü: "uygulanıyor"
      expect((await dispatchFuture).ok, isTrue);
      await clock.elapse(const Duration(milliseconds: 700)); // t=2.7 sn
      expect(pipeline.isPending('relay:3'), isTrue);
      pipeline.observe(relayState(3, true));
      await flush();
      expect(confirmations, <String>['relay:3']);
      expect(failures, isEmpty);
      await clock.elapse(const Duration(seconds: 10));
      expect(failures, isEmpty);
    });

    test('iletildi ama onay yoksa geri alma, İLETİMDEN 2.5 sn sonra (nötr mesaj)', () async {
      final gate = Completer<void>();
      final dispatchFuture = pipeline.submit(
        key: 'relay:3',
        original: false,
        target: true,
        send: okSender(gate: gate),
        confirms: CommandConfirm.relay(3, true),
      );
      await clock.elapse(const Duration(milliseconds: 2000));
      gate.complete();
      await dispatchFuture;
      await clock.elapse(const Duration(milliseconds: 2400)); // t=4.4 sn (iletimden 2.4 sn)
      expect(pipeline.isPending('relay:3'), isTrue);
      await clock.elapse(const Duration(milliseconds: 200)); // t=4.6 sn
      expect(pipeline.isPending('relay:3'), isFalse);
      expect(failures.single.reason, CommandFailureReason.timeout);
      expect(failures.single.message, isNot(contains('çevrimdışı')));
    });

    test('REST hiç dönmezse toplam üst sınırda (10 sn) geri alınır; geç gelen yanıt yok sayılır', () async {
      final gate = Completer<void>();
      final dispatchFuture = pipeline.submit(
        key: 'relay:3',
        original: false,
        target: true,
        send: okSender(gate: gate),
        confirms: CommandConfirm.relay(3, true),
      );
      await clock.elapse(const Duration(seconds: 9));
      expect(failures, isEmpty);
      await clock.elapse(const Duration(seconds: 2));
      expect(failures.single.reason, CommandFailureReason.network);
      expect((await dispatchFuture).status, CommandDispatchStatus.failed);

      gate.complete(); // yanıt sonunda geldi
      await clock.elapse(const Duration(milliseconds: 100));
      expect(failures, hasLength(1));
      expect(pipeline.isPending('relay:3'), isFalse);
    });

    test('onay penceresi toplam üst sınırı AŞMAZ (REST 9.8 sn sürerse pencere kısalır)', () async {
      final gate = Completer<void>();
      final dispatchFuture = pipeline.submit(
        key: 'relay:3',
        original: false,
        target: true,
        send: okSender(gate: gate),
        confirms: CommandConfirm.relay(3, true),
      );
      await clock.elapse(const Duration(milliseconds: 9800));
      gate.complete();
      await dispatchFuture;
      await clock.elapse(const Duration(milliseconds: 600)); // kalan 0.2 sn < 0.5 sn alt sınır
      expect(failures.single.reason, CommandFailureReason.timeout);
    });

    test('sunucu no_change derse (pano zaten hedef değerde) anında doğrulanmış sayılır', () async {
      final d = await pipeline.submit(
        key: 'childLock',
        original: null,
        target: true,
        send: (_) async => const CommandResult(delivered: true, deviceOnline: true, noChange: true),
        confirms: CommandConfirm.childLock(true),
      );
      await flush();
      expect(d.ok, isTrue);
      expect(d.result!.noChange, isTrue);
      expect(pipeline.isPending('childLock'), isFalse);
      expect(confirmations, <String>['childLock']);
      await clock.elapse(const Duration(seconds: 10));
      expect(failures, isEmpty);
    });
  });

  group('uç nokta başına tek bekleyen komut / çift basış', () {
    test('art arda dokunuş: tek kayıt, ilk dokunuştaki GERÇEK değer saklanır, hedef güncellenir', () async {
      final gate = Completer<void>();
      final first = pipeline.submit(
        key: 'relay:3',
        original: false,
        target: true,
        send: okSender(gate: gate),
        confirms: CommandConfirm.relay(3, true),
      );
      final second = pipeline.submit(
        key: 'relay:3',
        original: true, // ikinci dokunuşta görünen değer (iyimser); YOK SAYILMALI
        target: false,
        send: okSender(),
        confirms: CommandConfirm.relay(3, false),
      );
      expect(pipeline.pending, hasLength(1));
      final pending = pipeline.pendingFor('relay:3')!;
      expect(pending.original, false, reason: 'ilk dokunuştaki gerçek değer');
      expect(pending.target, false, reason: 'son niyet');
      expect((await first).status, CommandDispatchStatus.superseded);

      gate.complete();
      expect((await second).ok, isTrue);
      expect(pipeline.pending, hasLength(1));
    });

    test('gönderimler SIRAYLA yapılır ve birleştirilir: üç hızlı dokunuş -> en çok iki gönderim', () async {
      final sent = <bool>[];
      final gates = <Completer<void>>[Completer<void>(), Completer<void>()];
      CommandSender sender(bool value, int gateIndex) => (id) async {
            sent.add(value);
            await gates[gateIndex].future;
            return CommandResult(delivered: true, commandId: id);
          };

      final a = pipeline.submit(key: 'relay:1', original: false, target: true, send: sender(true, 0));
      final b = pipeline.submit(key: 'relay:1', original: false, target: false, send: sender(false, 1));
      final c = pipeline.submit(key: 'relay:1', original: false, target: true, send: sender(true, 1));
      await clock.elapse(const Duration(milliseconds: 50));
      expect(sent, <bool>[true], reason: 'ilk istek uçuşta; ikincisi bekliyor');

      gates[0].complete();
      await clock.elapse(const Duration(milliseconds: 50));
      expect(sent, <bool>[true, true], reason: 'ara hedef (false) atlanır; yalnızca SON niyet gönderilir');

      gates[1].complete();
      expect((await a).status, CommandDispatchStatus.superseded);
      expect((await b).status, CommandDispatchStatus.superseded);
      expect((await c).ok, isTrue);
    });

    test('eski komutun hatası, daha yeni bir hedef verilmişse görmezden gelinir', () async {
      final gate = Completer<void>();
      final first = pipeline.submit(
        key: 'relay:1',
        original: false,
        target: true,
        send: (_) async {
          await gate.future;
          throw ApiException.network();
        },
      );
      final second = pipeline.submit(
        key: 'relay:1',
        original: false,
        target: false,
        send: okSender(),
      );
      gate.complete();
      expect((await first).status, CommandDispatchStatus.superseded);
      expect((await second).ok, isTrue);
      expect(failures, isEmpty, reason: 'eski komutun ağ hatası geri alma üretmemeli');
    });

    test('zamanlayıcı son dokunuştan itibaren yeniden başlar', () async {
      await pipeline.submit(key: 'relay:3', original: false, target: true, send: okSender());
      await clock.elapse(const Duration(milliseconds: 2000));
      await pipeline.submit(key: 'relay:3', original: false, target: false, send: okSender());
      await clock.elapse(const Duration(milliseconds: 2000)); // ilk dokunuştan 4 sn, sonuncudan 2 sn
      expect(pipeline.isPending('relay:3'), isTrue);
      await clock.elapse(const Duration(milliseconds: 600));
      expect(failures.single.reason, CommandFailureReason.timeout);
    });

    test('farklı uç noktalar birbirinden bağımsızdır', () async {
      await pipeline.submit(
        key: 'relay:1',
        original: false,
        target: true,
        send: (_) async => throw ApiException.network(),
      );
      await pipeline.submit(key: 'relay:2', original: false, target: true, send: okSender());
      expect(pipeline.isPending('relay:1'), isFalse);
      expect(pipeline.isPending('relay:2'), isTrue);
    });
  });

  group('iptal', () {
    test('cancelAll: zamanlayıcılar iptal, geri alma olayı YOK, bekleyenler cancelled', () async {
      final gate = Completer<void>();
      final a = pipeline.submit(key: 'relay:1', original: false, target: true, send: okSender(gate: gate));
      await pipeline.submit(key: 'relay:2', original: false, target: true, send: okSender());
      expect(pipeline.pending, hasLength(2));
      pipeline.cancelAll();
      expect(pipeline.pending, isEmpty);
      expect((await a).status, CommandDispatchStatus.cancelled);
      expect(clock.activeTimerCount, 0);
      await clock.elapse(const Duration(seconds: 10));
      expect(failures, isEmpty);
      gate.complete();
      await clock.elapse(const Duration(milliseconds: 50));
      expect(failures, isEmpty);
    });

    test('dispose sonrası submit iptal döner ve hiçbir şey çalışmaz', () async {
      pipeline.dispose();
      final d = await pipeline.submit(key: 'k', original: 0, target: 1, send: okSender());
      expect(d.status, CommandDispatchStatus.cancelled);
      expect(pipeline.pending, isEmpty);
    });

    test('cancel(key) yalnızca o kaydı siler', () async {
      await pipeline.submit(key: 'a', original: 0, target: 1, send: okSender());
      await pipeline.submit(key: 'b', original: 0, target: 1, send: okSender());
      pipeline.cancel('a');
      expect(pipeline.isPending('a'), isFalse);
      expect(pipeline.isPending('b'), isTrue);
    });
  });

  group('onay kipleri', () {
    test('delivery: iletim başarılıysa tamamlanır, geri alma yok', () async {
      final d = await pipeline.submit(
        key: 'group:all_lights_off',
        original: null,
        target: null,
        mode: CommandConfirmMode.delivery,
        send: okSender(),
      );
      await flush();
      expect(d.ok, isTrue);
      expect(pipeline.isPending('group:all_lights_off'), isFalse);
      expect(confirmations, <String>['group:all_lights_off']);
      await clock.elapse(const Duration(seconds: 5));
      expect(failures, isEmpty);
    });

    test('delivery: iletim başarısızsa yine anında hata', () async {
      final d = await pipeline.submit(
        key: 'g',
        original: null,
        target: null,
        mode: CommandConfirmMode.delivery,
        send: (_) async => throw ApiException.network(),
      );
      await flush();
      expect(d.status, CommandDispatchStatus.failed);
      expect(failures, hasLength(1));
    });

    test('settle: iletildiyse iyimser değer süre boyunca tutulur, dolunca HATA GÖSTERMEDEN bırakılır', () async {
      await pipeline.submit(
        key: 'relay:3',
        original: false,
        target: true,
        mode: CommandConfirmMode.settle,
        send: okSender(),
        confirms: CommandConfirm.relay(3, true),
      );
      expect(pipeline.isPending('relay:3'), isTrue);
      await clock.elapse(const Duration(milliseconds: 2600));
      expect(pipeline.isPending('relay:3'), isFalse);
      expect(failures, isEmpty);
    });

    test('settle: iletilemezse yine geri alınır', () async {
      await pipeline.submit(
        key: 'relay:3',
        original: false,
        target: true,
        mode: CommandConfirmMode.settle,
        send: (_) async => const CommandResult(delivered: false),
      );
      await flush();
      expect(failures, hasLength(1));
    });

    test('özel zaman aşımı ve kimlik üreteci', () async {
      final custom = CommandPipeline(
        clock: clock,
        confirmTimeout: const Duration(milliseconds: 500),
        idGenerator: () => 'sabit-id',
      );
      addTearDown(custom.dispose);
      final ids = <String>[];
      final timeouts = <CommandFailure>[];
      custom.failures.listen(timeouts.add);
      await custom.submit(key: 'k', original: 0, target: 1, send: okSender(ids: ids));
      expect(ids.single, 'sabit-id');
      await clock.elapse(const Duration(milliseconds: 600));
      expect(timeouts, hasLength(1));
    });

    test('komut kimliği ≤ 24 karakter ve sunucunun command_id değeri benimsenir', () async {
      final ids = <String>[];
      await pipeline.submit(
        key: 'k',
        original: 0,
        target: 1,
        send: (id) async {
          ids.add(id);
          return const CommandResult(delivered: true, commandId: 'sunucu-id');
        },
      );
      expect(ids.single.length, lessThanOrEqualTo(24));
      expect(pipeline.pendingFor('k')!.commandId, 'sunucu-id');
    });
  });

  group('onay koşulları (CommandConfirm)', () {
    test('röle', () {
      expect(CommandConfirm.relay(2, true)(relayState(2, true)), isTrue);
      expect(CommandConfirm.relay(2, true)(relayState(2, false)), isFalse);
      expect(CommandConfirm.relay(2, true)(relayState(3, true)), isFalse);
      expect(CommandConfirm.relay(2, true)(const DeviceStatus()), isFalse);
    });

    test('panjur konumu: hedefe gidiyor ya da orada durmuş', () {
      final c = CommandConfirm.shutterPosition(1, 40);
      expect(c(shutterState(1, pos: 10, moving: true, dir: 1, target: 40)), isTrue);
      expect(c(shutterState(1, pos: 40)), isTrue);
      expect(c(shutterState(1, pos: 40, moving: true, dir: 1, target: 80)), isFalse);
      expect(c(shutterState(1, pos: 10)), isFalse);
      expect(c(shutterState(2, pos: 40)), isFalse);
    });

    test('panjur yukarı / aşağı / dur', () {
      expect(CommandConfirm.shutterUp(1)(shutterState(1, pos: 10, moving: true, dir: 1)), isTrue);
      expect(CommandConfirm.shutterUp(1)(shutterState(1, pos: 100)), isTrue);
      expect(CommandConfirm.shutterUp(1)(shutterState(1, pos: 50)), isFalse);
      expect(CommandConfirm.shutterUp(1)(shutterState(1, pos: 10, moving: true, dir: 2)), isFalse);
      expect(CommandConfirm.shutterDown(1)(shutterState(1, pos: 90, moving: true, dir: 2)), isTrue);
      expect(CommandConfirm.shutterDown(1)(shutterState(1, pos: 0)), isTrue);
      expect(CommandConfirm.shutterStopped(1)(shutterState(1, pos: 50)), isTrue);
      expect(CommandConfirm.shutterStopped(1)(shutterState(1, pos: 50, moving: true, dir: 1)), isFalse);
    });

    test('çocuk kilidi: yalnızca BİLİNEN değer onaylar (REST türevi anlık görüntü onaylamaz)', () {
      expect(CommandConfirm.childLock(true)(const DeviceStatus(childLock: true)), isTrue);
      expect(CommandConfirm.childLock(true)(const DeviceStatus(childLock: false)), isFalse);
      expect(CommandConfirm.childLock(false)(const DeviceStatus(childLock: false)), isTrue);
      // `child_lock` taşımayan (bilinmeyen) anlık görüntü: false varsayılanı "kilit kapalı" onayı SAYILMAZ.
      expect(CommandConfirm.childLock(false)(const DeviceStatus(childLockKnown: false)), isFalse);
      expect(CommandConfirm.childLock(true)(const DeviceStatus(childLock: true, childLockKnown: false)), isFalse);
    });
  });

  test('onChanged: kayıt kümesi değiştikçe çağrılır', () async {
    expect(changes, 0);
    await pipeline.submit(key: 'k', original: 0, target: 1, send: okSender());
    expect(changes, greaterThan(0));
    final before = changes;
    pipeline.observe(const DeviceStatus()); // eşleşme yok: değişim yok
    expect(changes, before);
    pipeline.cancelAll();
    expect(changes, greaterThan(before));
  });

  test('emitFailure yerel redleri aynı akıştan duyurur', () async {
    pipeline.emitFailure(const CommandFailure(
      key: 'x',
      reason: CommandFailureReason.forbidden,
      message: 'Yetkiniz yok',
    ));
    await clock.elapse(const Duration(milliseconds: 10));
    expect(failures.single.reason, CommandFailureReason.forbidden);
  });
}
