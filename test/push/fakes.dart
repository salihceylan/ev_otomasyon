import 'dart:async';
import 'dart:math';

import 'package:ev_otomasyon/services/push/push_coordinator.dart';
import 'package:ev_otomasyon/services/push/push_gateway.dart';

/// Sabit değer döndüren rastgelelik: geri çekilme sapmasını deterministik yapar.
class FixedRandom implements Random {
  FixedRandom(this.value);

  final double value;

  @override
  double nextDouble() => value;

  @override
  bool nextBool() => value >= 0.5;

  @override
  int nextInt(int max) => (value * max).floor().clamp(0, max - 1);
}

/// Sahte gateway: gerçek platform kanalı yok. Çağrılar [calls] içinde sırayla tutulur.
class FakeGateway implements PushGateway {
  bool supported = true;

  /// `initialize` sonrasında `isSupported` değeri (başlatma başarısız senaryosu için).
  bool supportedAfterInitialize = true;

  PushPermission permission = PushPermission.granted;

  /// `requestPermission` çağrılırsa dönecek ve kalıcı hale gelecek sonuç.
  PushPermission requestResult = PushPermission.granted;

  Future<String?> Function() tokenProvider = () async => 'token-1';
  Future<PushMessage?> Function() initialMessageProvider = () async => null;

  /// Doluysa ilgili yöntem bu tamamlanana kadar bekler (platform çağrısının takıldığı/yavaş döndüğü senaryolar).
  Completer<void>? initializeGate;
  Completer<void>? permissionStatusGate;
  Completer<void>? requestPermissionGate;

  /// Bu adlardaki yöntemler [StateError] fırlatır (gateway'in "asla fırlatmaz" sözleşmesini bozan hatalı uygulama).
  final Set<String> throwing = <String>{};

  final List<String> calls = <String>[];

  /// `deleteToken` (yerel FCM belirtecini geçersiz kılma) çağrı sayısı. [calls]'a YAZILMAZ: mevcut
  /// sıra iddiaları (başlatma/izin/belirteç akışı) çıkış temizliğinden etkilenmesin.
  int deleteTokenCalls = 0;

  /// Doluysa `deleteToken` bu tamamlanana kadar bekler (takılan platform çağrısı).
  Completer<void>? deleteTokenGate;

  /// Doluysa `deleteToken` bunu fırlatır (çevrimdışı vb.).
  Object? deleteTokenError;

  final StreamController<String> tokenRefresh = StreamController<String>.broadcast();
  final StreamController<PushMessage> foreground = StreamController<PushMessage>.broadcast();
  final StreamController<PushMessage> opened = StreamController<PushMessage>.broadcast();

  int count(String name) => calls.where((c) => c == name).length;

  void _record(String name) {
    calls.add(name);
    if (throwing.contains(name)) throw StateError('sahte hata: $name');
  }

  @override
  bool get isSupported => supported;

  @override
  Future<void> initialize() async {
    _record('initialize');
    await initializeGate?.future;
    supported = supported && supportedAfterInitialize;
  }

  @override
  Future<PushPermission> permissionStatus() async {
    _record('permissionStatus');
    await permissionStatusGate?.future;
    return permission;
  }

  @override
  Future<PushPermission> requestPermission() async {
    _record('requestPermission');
    await requestPermissionGate?.future;
    permission = requestResult;
    return requestResult;
  }

  @override
  Future<String?> getToken() async {
    _record('getToken');
    return tokenProvider();
  }

  @override
  Stream<String> get onTokenRefresh => tokenRefresh.stream;

  @override
  Stream<PushMessage> get onForegroundMessage => foreground.stream;

  @override
  Stream<PushMessage> get onMessageOpened => opened.stream;

  @override
  Future<PushMessage?> getInitialMessage() async {
    _record('getInitialMessage');
    return initialMessageProvider();
  }

  @override
  Future<void> deleteToken() async {
    deleteTokenCalls++;
    await deleteTokenGate?.future;
    final error = deleteTokenError;
    if (error != null) throw error;
  }
}

/// Sahte API: kayıt/silme çağrılarını tutar; sonuçlar sırayla verilen betikten gelir.
class FakeApi implements PushTokenApi {
  /// Her `registerPushToken` çağrısı sırayla bir sonuç tüketir: `null` = başarı, bir istisna = fırlat.
  /// Betik bitince başarı döner.
  final List<Object?> registerOutcomes = <Object?>[];

  /// Doluysa `registerPushToken` bu tamamlanana kadar bekler (uçuştaki istek senaryoları için).
  Completer<void>? registerGate;

  /// Doluysa `unregisterPushToken` bu tamamlanana kadar bekler.
  Completer<void>? unregisterGate;

  Object? unregisterError;

  final List<({String token, String platform, String? appVersion})> registerCalls =
      <({String token, String platform, String? appVersion})>[];
  final List<String> unregisterCalls = <String>[];

  @override
  Future<void> registerPushToken({required String token, required String platform, String? appVersion}) async {
    registerCalls.add((token: token, platform: platform, appVersion: appVersion));
    final outcome = registerOutcomes.isEmpty ? null : registerOutcomes.removeAt(0);
    final gate = registerGate;
    if (gate != null) await gate.future;
    if (outcome != null) throw outcome;
  }

  @override
  Future<void> unregisterPushToken(String token) async {
    unregisterCalls.add(token);
    final gate = unregisterGate;
    if (gate != null) await gate.future;
    final error = unregisterError;
    if (error != null) throw error;
  }
}
