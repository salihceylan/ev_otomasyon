import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart' hide NotificationVisibility;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../ev_cloud_api_service.dart';
import '../ev_mqtt_service.dart';
import '../secure_storage_service.dart';
import 'alarm_notice.dart';
import 'alarm_watch_engine.dart';
import 'alarm_watch_models.dart';
import 'alarm_watch_support.dart';
import 'refresh_gate.dart';

export 'alarm_watch_support.dart';

// =============================================================================
// Android ön plan servisi (flutter_foreground_task) + yerel bildirimler (flutter_local_notifications).
//
// Servis ayrı bir FlutterEngine'de (ayrı isolate, AYNI süreç) [alarmWatchStartCallback] ile başlar; telefon yeniden
// açılınca ve uygulama güncellenince (kullanıcı açık bıraktıysa) eklenti kendiliğinden yeniden başlatır. iOS'ta hiçbir
// şey yapılmaz (özellik yalnız Android).
// =============================================================================

/// "Güvenlik alarmları" kanalı (yüksek öncelik, ses + titreşim; Rahatsız Etmeyin'i özel izin gerektirdiği için delmez).
const String kAlarmChannelId = 'ahbu_safety_alarms';
const String kAlarmChannelName = 'Güvenlik alarmları';
const String kAlarmChannelDescription = 'Su baskını, gaz, duman, hırsız alarmı ve vana arızası bildirimleri.';

/// Kalıcı servis bildirimi kanalı (sessiz).
const String kWatchChannelId = 'ahbu_alarm_watch';
const String kWatchChannelName = 'Arka planda alarm takibi';

/// İzleme durdu bilgisi kanalı.
const String kWatchInfoChannelId = 'ahbu_alarm_watch_info';
const String kWatchInfoChannelName = 'Alarm takibi bilgisi';

const int _serviceId = 4711;
const int _stoppedNoticeId = 998;

const String _launcherIcon = '@mipmap/ic_launcher';

/// Servisin giriş noktası (üst düzey + `vm:entry-point`: derleyici silmesin).
@pragma('vm:entry-point')
void alarmWatchStartCallback() {
  FlutterForegroundTask.setTaskHandler(AlarmWatchTaskHandler());
}

/// Ön plan servisinin görev işleyicisi: [AlarmWatchEngine]'i gerçek bağımlılıklarla kurar.
class AlarmWatchTaskHandler extends TaskHandler {
  AlarmWatchEngine? _engine;
  EvCloudApiService? _cloud;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    WidgetsFlutterBinding.ensureInitialized();
    final storage = SecureStorageService();
    String? access;
    String? refresh;
    try {
      access = await storage.getAuthToken();
      refresh = await storage.getRefreshToken();
    } catch (_) {
      // Güvenli depo okunamadı: oturum yok sayılır, motor servisi durdurur.
    }
    final cloud = EvCloudApiService();
    _cloud = cloud;
    cloud
      ..setAuthToken(access)
      ..setRefreshToken(refresh);
    // Ön plan uygulamasıyla AYNI oturum ailesi: yenileme süreç geneli kapıyla ve depodaki en son token'la yapılır;
    // yenisi yalnız depo hâlâ aynı oturumu gösteriyorsa yazılır (bu arada çıkış/giriş olduysa atılır).
    String? lastRead;
    cloud
      ..refreshGate = IsolateRefreshGate()
      ..storedSessionIsAuthoritative = true
      ..readStoredRefreshToken = () async {
        lastRead = await storage.getRefreshToken();
        return lastRead;
      }
      ..onTokenRefreshed = (newAccess, newRefresh) async {
        final current = await storage.getRefreshToken();
        if (lastRead == null || current != lastRead) return;
        if (newRefresh != null && newRefresh.isNotEmpty) await storage.saveRefreshToken(newRefresh);
        await storage.saveAuthToken(newAccess);
      };

    final notifier = LocalAlarmNotifier();
    await notifier.init();
    final store = PrefsAlarmWatchStore();
    final engine = AlarmWatchEngine(
      cloud: cloud,
      settings: AlarmWatchSettingsRepository(store),
      dedupe: AlarmDedupeStore(store),
      notifier: notifier,
      mqttFactory: EvMqttService.new,
      readUser: () async {
        try {
          return await storage.getUser();
        } catch (_) {
          return null;
        }
      },
      onStopRequested: (_) => unawaited(FlutterForegroundTask.stopService()),
    );
    _engine = engine;
    await engine.start();
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    unawaited(_engine?.refresh());
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    await _engine?.stop();
    _engine = null;
    _cloud?.dispose();
    _cloud = null;
  }

  @override
  void onNotificationPressed() {
    FlutterForegroundTask.launchApp();
  }
}

/// `flutter_local_notifications` ile gerçek bildirimler.
class LocalAlarmNotifier implements AlarmNotifier {
  LocalAlarmNotifier([FlutterLocalNotificationsPlugin? plugin]) : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin _plugin;

  Future<void> init() async {
    try {
      await _plugin.initialize(
        settings: const InitializationSettings(android: AndroidInitializationSettings(_launcherIcon)),
      );
      await createAlarmChannels(_plugin);
    } catch (_) {
      // Bildirim katmanı başlatılamadı: gösterimler sessizce başarısız olur.
    }
  }

  @override
  Future<void> show(AlarmNotice notice) => _plugin.show(
        id: notice.notificationId,
        title: notice.title,
        body: notice.body,
        payload: notice.payload,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            kAlarmChannelId,
            kAlarmChannelName,
            channelDescription: kAlarmChannelDescription,
            importance: Importance.max,
            priority: Priority.max,
            category: AndroidNotificationCategory.alarm,
            visibility: NotificationVisibility.public,
            styleInformation: BigTextStyleInformation(notice.body),
            ticker: notice.title,
          ),
        ),
      );

  @override
  Future<void> cancel(int notificationId) => _plugin.cancel(id: notificationId);

  @override
  Future<void> status(String text) async {
    await FlutterForegroundTask.updateService(notificationTitle: kWatchChannelName, notificationText: text);
  }

  @override
  Future<void> stopped(String text) => _plugin.show(
        id: _stoppedNoticeId,
        title: 'Alarm takibi durdu',
        body: text,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            kWatchInfoChannelId,
            kWatchInfoChannelName,
            importance: Importance.defaultImportance,
            priority: Priority.defaultPriority,
            styleInformation: BigTextStyleInformation(text),
          ),
        ),
      );
}

/// Kanalları oluşturur (idempotent; ön plan ve arka plan isolate'leri çağırabilir).
Future<void> createAlarmChannels(FlutterLocalNotificationsPlugin plugin) async {
  final android = plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
  if (android == null) return;
  await android.createNotificationChannel(const AndroidNotificationChannel(
    kAlarmChannelId,
    kAlarmChannelName,
    description: kAlarmChannelDescription,
    importance: Importance.max,
    playSound: true,
    enableVibration: true,
    audioAttributesUsage: AudioAttributesUsage.alarm,
  ));
  await android.createNotificationChannel(const AndroidNotificationChannel(
    kWatchInfoChannelId,
    kWatchInfoChannelName,
    importance: Importance.defaultImportance,
  ));
}

/// Ön plan uygulamasının gördüğü platform işlemleri (testte sahte).
abstract class AlarmWatchPlatform {
  /// Özellik bu cihazda var mı (yalnız Android).
  bool get isSupported;

  Future<bool> notificationsAllowed();

  /// Android 13+ bildirim izni penceresi.
  Future<bool> requestNotifications();

  Future<bool> batteryOptimizationIgnored();

  /// Pil optimizasyonu muafiyeti penceresi (servis Doze'da ve yeniden başlatmada yaşasın).
  Future<bool> requestBatteryExemption();

  Future<bool> isRunning();

  Future<bool> start();

  Future<void> stop();

  /// Uygulama açıkken alarm bildirimine dokunuş yükleri.
  Stream<String> get taps;

  /// Uygulamayı başlatan dokunuşun yükü (bir kez).
  Future<String?> takeLaunchPayload();
}

/// Desteklenmeyen platform (iOS, web, testler): hiçbir şey yapmaz.
class UnsupportedAlarmWatchPlatform implements AlarmWatchPlatform {
  const UnsupportedAlarmWatchPlatform();

  @override
  bool get isSupported => false;

  @override
  Future<bool> notificationsAllowed() async => false;

  @override
  Future<bool> requestNotifications() async => false;

  @override
  Future<bool> batteryOptimizationIgnored() async => false;

  @override
  Future<bool> requestBatteryExemption() async => false;

  @override
  Future<bool> isRunning() async => false;

  @override
  Future<bool> start() async => false;

  @override
  Future<void> stop() async {}

  @override
  Stream<String> get taps => const Stream<String>.empty();

  @override
  Future<String?> takeLaunchPayload() async => null;
}

/// Gerçek Android uygulaması.
class AndroidAlarmWatchPlatform implements AlarmWatchPlatform {
  AndroidAlarmWatchPlatform({FlutterLocalNotificationsPlugin? plugin})
      : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin _plugin;
  final StreamController<String> _taps = StreamController<String>.broadcast();
  bool _initialized = false;
  bool _launchTaken = false;

  Future<void> _init() async {
    if (_initialized) return;
    _initialized = true;
    try {
      await _plugin.initialize(
        settings: const InitializationSettings(android: AndroidInitializationSettings(_launcherIcon)),
        onDidReceiveNotificationResponse: (response) {
          final payload = response.payload;
          if (payload != null && !_taps.isClosed) _taps.add(payload);
        },
      );
      await createAlarmChannels(_plugin);
    } catch (_) {}
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: kWatchChannelId,
        channelName: kWatchChannelName,
        channelDescription: 'Uygulama kapalıyken alarm bildirimi için bulut bağlantısını açık tutar.',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(showNotification: false),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(15 * 60 * 1000),
        autoRunOnBoot: true,
        autoRunOnMyPackageReplaced: true,
        allowWakeLock: true,
        allowWifiLock: true,
        allowAutoRestart: true,
        stopWithTask: false,
      ),
    );
  }

  @override
  bool get isSupported => true;

  @override
  Future<bool> notificationsAllowed() async {
    try {
      return await FlutterForegroundTask.checkNotificationPermission() == NotificationPermission.granted;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> requestNotifications() async {
    try {
      return await FlutterForegroundTask.requestNotificationPermission() == NotificationPermission.granted;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> batteryOptimizationIgnored() async {
    try {
      return await FlutterForegroundTask.isIgnoringBatteryOptimizations;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> requestBatteryExemption() async {
    try {
      return await FlutterForegroundTask.requestIgnoreBatteryOptimization();
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> isRunning() async {
    try {
      return await FlutterForegroundTask.isRunningService;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> start() async {
    await _init();
    if (await isRunning()) return true;
    final result = await FlutterForegroundTask.startService(
      serviceId: _serviceId,
      serviceTypes: const <ForegroundServiceTypes>[ForegroundServiceTypes.specialUse],
      notificationTitle: kWatchChannelName,
      notificationText: 'Bağlantı kuruluyor…',
      callback: alarmWatchStartCallback,
    );
    return result is ServiceRequestSuccess;
  }

  @override
  Future<void> stop() async {
    try {
      await FlutterForegroundTask.stopService();
    } catch (_) {}
  }

  @override
  Stream<String> get taps {
    unawaited(_init());
    return _taps.stream;
  }

  @override
  Future<String?> takeLaunchPayload() async {
    if (_launchTaken) return null;
    _launchTaken = true;
    await _init();
    try {
      final details = await _plugin.getNotificationAppLaunchDetails();
      if (details == null || !details.didNotificationLaunchApp) return null;
      return details.notificationResponse?.payload;
    } catch (_) {
      return null;
    }
  }
}

/// Varsayılan platform: Android'de gerçek, diğerlerinde no-op.
AlarmWatchPlatform createAlarmWatchPlatform() =>
    alarmWatchPlatformSupported ? AndroidAlarmWatchPlatform() : const UnsupportedAlarmWatchPlatform();
