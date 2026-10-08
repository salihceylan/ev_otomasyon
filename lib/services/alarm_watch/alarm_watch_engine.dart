import 'dart:async';

import '../../models/automation_models.dart';
import '../../models/cloud_models.dart';
import '../../models/json_utils.dart';
import '../api_exception.dart';
import '../clock.dart';
import '../ev_cloud_api_service.dart';
import '../ev_mqtt_service.dart';
import 'alarm_notice.dart';
import 'alarm_watch_models.dart';

/// Arka plan servisinin bildirim yüzeyi (gerçekte `flutter_local_notifications` + ön plan servis bildirimi).
abstract class AlarmNotifier {
  /// "Güvenlik alarmları" kanalında yüksek öncelikli bildirim.
  Future<void> show(AlarmNotice notice);

  Future<void> cancel(int notificationId);

  /// Kalıcı (ön plan servis) bildiriminin metni.
  Future<void> status(String text);

  /// Oturum bitti / izleme durdu bilgisi (tek, normal bildirim).
  Future<void> stopped(String text);
}

/// Arka planda alarm izleyicisinin çekirdeği (Android ön plan servisinin içinde çalışır; testte sahtelerle).
///
/// * Uygun evler (owner/resident, hesap rolü `user`) için birer MQTT abonesi ([EvMqttService]: süreli kimlik yenileme,
///   kimlik reddinde taze kimlik, üstel geri çekilme onun içinde).
/// * Her `state`'te güvenlik durumu bir öncekiyle karşılaştırılır ([planAlarmNotices]); yeni alarm kalıcı tekilleştirme
///   kaydından geçerse bildirilir, kalkan alarmın bildirimi silinir.
/// * Ayar kapandıysa / kullanıcı değiştiyse / oturum bittiyse izleme durur ve [onStopRequested] çağrılır.
/// * Ev listesi alınamazsa (internet yok) kayıtlı listeyle başlanır; [refresh] geri çekilmeyle yeniden dener.
/// * Hiçbir kimlik/belirteç loglanmaz ya da bildirime yazılmaz.
class AlarmWatchEngine {
  AlarmWatchEngine({
    required this.cloud,
    required this.settings,
    required this.dedupe,
    required this.notifier,
    required this._mqttFactory,
    required this._readUser,
    this.onStopRequested,
    this._clock = const SystemClock(),
    AlarmBackoff? backoff,
    this.namesTimeout = const Duration(seconds: 3),
  }) : _backoff = backoff ?? AlarmBackoff();

  final EvCloudApiService cloud;
  final AlarmWatchSettingsRepository settings;
  final AlarmDedupeStore dedupe;
  final AlarmNotifier notifier;
  final EvMqttService Function() _mqttFactory;
  final Future<UserModel?> Function() _readUser;
  final Clock _clock;
  final AlarmBackoff _backoff;
  final Duration namesTimeout;

  /// Servisin durması gerektiğinde (ayar kapalı, kullanıcı yok/değişti, oturum bitti, uygun ev yok).
  void Function(String reason)? onStopRequested;

  final Map<String, _HomeWatch> _watches = <String, _HomeWatch>{};
  bool _stopped = false;
  bool _running = false;
  String? _userId;
  DateTime? _nextHomesFetch;

  /// Ev listesinin son BAŞARIYLA alındığı an (uyelik-5).
  DateTime? _lastHomesOk;

  /// Bütün evler MQTT'ye bağlıyken ev listesi bu aralıkla tazelenir (ortak NAT arkasında istek sayısı düşer; uyelik-5).
  static const Duration _connectedHomesEvery = Duration(minutes: 60);

  bool get isRunning => _running && !_stopped;

  /// İzlenen ev kimlikleri (testler / durum metni).
  List<String> get watchedHomeIds => List<String>.unmodifiable(_watches.keys);

  /// Başlatır. `false`: izlenecek bir şey yok (servis durmalı; [onStopRequested] çağrıldı).
  Future<bool> start() async {
    if (_stopped) return false;
    final config = await settings.load();
    if (!config.enabled) return _requestStop('disabled');
    final user = await _readUser();
    if (user == null || user.id.isEmpty || (config.userId != null && config.userId != user.id)) {
      return _requestStop('user');
    }
    if (!cloud.hasSession) return _requestStop('session');
    _userId = user.id;
    _running = true;
    cloud.onSessionExpired = (_) => unawaited(_sessionEnded());
    final homes = await _loadHomes(config, user);
    if (_stopped) return false;
    if (homes.isEmpty) return _requestStop('no_homes');
    _apply(homes);
    await _updateStatus();
    return true;
  }

  /// Periyodik (ör. 15 dk) denetim: ayar hâlâ açık mı, ev listesi değişti mi.
  Future<void> refresh() async {
    if (_stopped || !_running) return;
    final config = await settings.load();
    if (!config.enabled) {
      _requestStop('disabled');
      return;
    }
    if (config.userId != null && config.userId != _userId) {
      _requestStop('user');
      return;
    }
    final next = _nextHomesFetch;
    if (next != null && _clock.now().isBefore(next)) {
      await _updateStatus();
      return;
    }
    final lastOk = _lastHomesOk;
    final allConnected = _watches.isNotEmpty && _watches.values.every((w) => w.mqtt.isConnected);
    if (lastOk != null && allConnected && _clock.now().difference(lastOk) < _connectedHomesEvery) {
      await _updateStatus();
      return;
    }
    final user = await _readUser();
    if (user == null || user.id != _userId) {
      _requestStop('user');
      return;
    }
    final homes = await _loadHomes(config, user);
    if (_stopped) return;
    if (homes.isEmpty) {
      _requestStop('no_homes');
      return;
    }
    _apply(homes);
    await _updateStatus();
  }

  /// İzlemeyi durdurur (servis kapanırken).
  Future<void> stop() async {
    _stopped = true;
    _running = false;
    for (final w in _watches.values) {
      await w.dispose();
    }
    _watches.clear();
  }

  bool _requestStop(String reason) {
    if (!_stopped) {
      unawaited(stop());
      onStopRequested?.call(reason);
    }
    return false;
  }

  Future<void> _sessionEnded() async {
    if (_stopped) return;
    await notifier.stopped('Oturumunuz kapandı; arka plan alarm bildirimi durdu. Uygulamaya yeniden giriş yapın.');
    _requestStop('session');
  }

  /// Sunucudan uygun evler; alınamazsa kayıtlı liste (ve geri çekilmeyle yeniden deneme zamanı).
  Future<List<WatchedHome>> _loadHomes(AlarmWatchSettings config, UserModel user) async {
    try {
      final homes = await cloud.fetchHomes();
      final eligible = eligibleWatchHomes(globalRole: user.role, homes: homes);
      _backoff.reset();
      _nextHomesFetch = null;
      _lastHomesOk = _clock.now();
      if (!_stopped && eligible != config.homes) {
        try {
          await settings.save(config.copyWith(homes: eligible));
        } catch (_) {}
      }
      return eligible;
    } on ApiException catch (e) {
      if (e.statusCode == 401 || e.isServiceSessionExpired) return const <WatchedHome>[];
      _nextHomesFetch = _clock.now().add(_backoff.next());
      return config.homes;
    } catch (_) {
      _nextHomesFetch = _clock.now().add(_backoff.next());
      return config.homes;
    }
  }

  void _apply(List<WatchedHome> homes) {
    final wanted = <String, WatchedHome>{for (final h in homes) h.id: h};
    for (final id in _watches.keys.toList()) {
      if (!wanted.containsKey(id)) unawaited(_watches.remove(id)!.dispose());
    }
    for (final home in homes) {
      final existing = _watches[home.id];
      if (existing != null) {
        existing.home = home;
        continue;
      }
      final watch = _HomeWatch(home, _mqttFactory());
      _watches[home.id] = watch;
      watch.stateSub = watch.mqtt.stateMessages.listen((m) => unawaited(_onState(watch, m)));
      watch.linkSub = watch.mqtt.linkStates.listen((_) => unawaited(_updateStatus()));
      unawaited(watch.mqtt.start(credentialsProvider: () => cloud.mqttCredentials(home.id)));
    }
  }

  Future<void> _updateStatus() async {
    if (_stopped) return;
    final total = _watches.length;
    final connected = _watches.values.where((w) => w.mqtt.isConnected).length;
    final text = total == 0
        ? 'İzlenecek ev yok'
        : (connected == total
            ? 'Alarm takibi açık • $total ev'
            : 'Bağlantı kuruluyor ($connected/$total ev bağlı)');
    try {
      await notifier.status(text);
    } catch (_) {}
  }

  Future<void> _onState(_HomeWatch watch, DeviceStateMessage message) async {
    if (_stopped) return;
    final next = message.status.safety;
    if (!next.supported) return;
    final uid = next.deviceUid ?? message.status.uid ?? '-';
    final previous = watch.last[uid];
    // Sürmekte olan alarmların kaydı tazelenir (guvenlik-9): aylarca süren kilit, servis yeniden başlayınca yeni sayılmaz.
    final active = activeAlarmDedupeKeys(homeId: watch.home.id, state: next);
    if (active.isNotEmpty) await dedupe.touch(active);
    if (_stopped) return;
    if (previous == next) return;
    watch.last[uid] = next;
    final needsNames = next.hasActiveAlarm || next.intrusionAlarmActive;
    if (needsNames && !watch.names.containsKey(uid)) await _loadNames(watch, uid);
    if (_stopped) return;
    final names = watch.names[uid] ?? const <String, String>{};
    final plan = planAlarmNotices(
      homeId: watch.home.id,
      homeName: watch.home.name,
      before: previous,
      after: next,
      sensorName: (id) => names[id],
    );
    for (final c in plan.cancel) {
      try {
        await notifier.cancel(c.notificationId);
      } catch (_) {}
      final key = c.forgetKey;
      if (key != null) await dedupe.forget(key);
      final prefix = c.forgetPrefix;
      if (prefix != null) await dedupe.forgetPrefix(prefix);
    }
    for (final notice in plan.show) {
      if (_stopped) return;
      if (!await dedupe.markIfNew(notice.dedupeKey)) continue;
      try {
        await notifier.show(notice);
      } catch (_) {}
    }
  }

  /// Sensör adları (state'te yoktur): yapılandırma kopyasından, süre sınırlı ve en iyi çaba.
  Future<void> _loadNames(_HomeWatch watch, String uid) async {
    if (uid == '-') return;
    try {
      final data = await cloud.safetyConfig(watch.home.id, uid).timeout(namesTimeout);
      final names = <String, String>{};
      for (final raw in asList(data['sensors']) ?? const <dynamic>[]) {
        final map = asMap(raw);
        final id = asNonEmptyString(map?['id']);
        final name = asNonEmptyString(map?['name']);
        if (id != null && name != null) names[id] = name;
      }
      watch.names[uid] = names;
    } catch (_) {
      watch.names[uid] = const <String, String>{}; // bir daha bekletme; bölge adıyla bildirilir
    }
  }
}

class _HomeWatch {
  _HomeWatch(this.home, this.mqtt);

  WatchedHome home;
  final EvMqttService mqtt;
  final Map<String, SafetyState> last = <String, SafetyState>{};
  final Map<String, Map<String, String>> names = <String, Map<String, String>>{};
  StreamSubscription<DeviceStateMessage>? stateSub;
  StreamSubscription<MqttLinkState>? linkSub;

  Future<void> dispose() async {
    await stateSub?.cancel();
    await linkSub?.cancel();
    await mqtt.stop();
    mqtt.dispose();
  }
}
