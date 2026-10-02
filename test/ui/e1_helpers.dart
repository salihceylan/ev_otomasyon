import 'dart:async';

import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/models/api_models.dart';
import 'package:ev_otomasyon/models/scheduled_rule_model.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:ev_otomasyon/ui/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/support.dart';

// =============================================================================
// Sahte bulut: E1 arayüzünün kullandığı, FakeCloudApi'de olmayan uçlar
// =============================================================================

/// `FakeCloudApi` + E1 arayüzünün kullandığı ek uçlar (toplu kapatma, huzur ayarı, zamanlı kural
/// yazma, süper kullanıcı özeti, envanter/aboneler). Her çağrı `calls` listesine yazılır.
class E1Cloud extends FakeCloudApi {
  E1Cloud({super.clock});

  // Toplu kapatma ("Hepsini Kapat").
  Map<String, dynamic> closeAllResponse = <String, dynamic>{'closed_count': 2, 'delivered': true};
  Object? closeAllError;
  Completer<void>? closeAllGate;

  @override
  Future<Map<String, dynamic>> closeAllOpenLights(String homeId) async {
    calls.add('closeAllOpenLights');
    final gate = closeAllGate;
    if (gate != null) await gate.future;
    final error = closeAllError;
    if (error != null) throw error;
    return Map<String, dynamic>.of(closeAllResponse);
  }

  // Huzur bildirimi.
  Object? peaceGetError;
  Object? peaceUpdateError;
  final List<Map<String, dynamic>> peaceUpdates = <Map<String, dynamic>>[];

  @override
  Future<Map<String, dynamic>> getPeaceNotification(String homeId) async {
    final error = peaceGetError;
    if (error != null) {
      calls.add('getPeaceNotification');
      throw error;
    }
    return super.getPeaceNotification(homeId);
  }

  @override
  Future<Map<String, dynamic>> updatePeaceNotification(
    String homeId, {
    bool? enabled,
    String? notificationTime,
  }) async {
    calls.add('updatePeaceNotification');
    final error = peaceUpdateError;
    if (error != null) throw error;
    peaceUpdates.add(<String, dynamic>{'enabled': enabled, 'notification_time': notificationTime});
    if (enabled != null) peaceNotification['peace_notification_enabled'] = enabled;
    if (notificationTime != null) peaceNotification['peace_notification_time'] = notificationTime;
    return Map<String, dynamic>.of(peaceNotification);
  }

  // Zamanlı kurallar (bellek içi).
  Object? rulesError;
  Object? ruleWriteError;
  Completer<void>? rulesGate;
  final List<Map<String, dynamic>> createdRulePayloads = <Map<String, dynamic>>[];
  int _ruleSeq = 0;

  @override
  Future<List<ScheduledRule>> getScheduledRules(String homeId) async {
    final gate = rulesGate;
    if (gate != null) {
      calls.add('getScheduledRules');
      await gate.future;
    }
    final error = rulesError;
    if (error != null) {
      if (gate == null) calls.add('getScheduledRules');
      throw error;
    }
    if (gate != null) return List<ScheduledRule>.of(rules);
    return super.getScheduledRules(homeId);
  }

  @override
  Future<Map<String, dynamic>> createScheduledRule(String homeId, Map<String, dynamic> ruleData) async {
    calls.add('createScheduledRule');
    final error = ruleWriteError;
    if (error != null) throw error;
    createdRulePayloads.add(Map<String, dynamic>.of(ruleData));
    final id = 'rule-${++_ruleSeq}';
    rules = <ScheduledRule>[
      ...rules,
      ScheduledRule.fromJson(<String, dynamic>{...ruleData, 'id': id, 'home_id': homeId}),
    ];
    return <String, dynamic>{'id': id};
  }

  @override
  Future<Map<String, dynamic>> updateScheduledRule(
    String homeId,
    String ruleId,
    Map<String, dynamic> updates,
  ) async {
    calls.add('updateScheduledRule');
    final error = ruleWriteError;
    if (error != null) throw error;
    rules = <ScheduledRule>[
      for (final rule in rules)
        rule.id == ruleId
            ? ScheduledRule.fromJson(<String, dynamic>{...rule.toJson(), ...updates})
            : rule,
    ];
    return <String, dynamic>{'id': ruleId};
  }

  @override
  Future<void> deleteScheduledRule(String homeId, String ruleId) async {
    calls.add('deleteScheduledRule');
    final error = ruleWriteError;
    if (error != null) throw error;
    rules = rules.where((r) => r.id != ruleId).toList();
  }

  // Servis erişimi yönetimi (ev sahibi).
  Object? serviceSessionsError;

  @override
  Future<List<ServiceSessionSummary>> listServiceSessions(String homeId) async {
    final error = serviceSessionsError;
    if (error != null) {
      calls.add('listServiceSessions:$homeId');
      throw error;
    }
    return super.listServiceSessions(homeId);
  }

  // Davet / devir.
  Object? joinError;
  JoinHomeResult joinResult = const JoinHomeResult(homeId: kHomeB, homeName: 'Yazlık', role: 'resident', message: 'Eve katıldınız.');
  final List<String> joinedCodes = <String>[];
  Object? transferError;
  final List<String> acceptedTransfers = <String>[];

  @override
  Future<JoinHomeResult> joinHome(String code) async {
    calls.add('joinHome');
    joinedCodes.add(code);
    final error = joinError;
    if (error != null) throw error;
    return joinResult;
  }

  @override
  Future<TransferAcceptResult> acceptTransfer(String transferCode) async {
    calls.add('acceptTransfer');
    acceptedTransfers.add(transferCode);
    final error = transferError;
    if (error != null) throw error;
    return const TransferAcceptResult(homeId: kHomeB, homeName: 'Yazlık', message: '');
  }

  // Süper kullanıcı özeti, envanter ve aboneler.
  Map<String, dynamic> summary = <String, dynamic>{
    'users': <String, dynamic>{'total_users': 12, 'super_users': 2, 'service_users': 3, 'regular_users': 7},
    'homes': <String, dynamic>{'total_homes': 20},
    'devices': <String, dynamic>{
      'total_devices': 40,
      'claimed_devices': 22,
      'commissioned_devices': 18,
      'pending_commissioning': 4,
    },
  };
  Object? summaryError;
  Completer<void>? summaryGate;

  @override
  Future<Map<String, dynamic>> getServiceSummary() async {
    calls.add('getServiceSummary');
    final gate = summaryGate;
    if (gate != null) await gate.future;
    final error = summaryError;
    if (error != null) throw error;
    return Map<String, dynamic>.of(summary);
  }

  Map<String, dynamic> inventory = <String, dynamic>{
    'items': <dynamic>[],
    'stats': <String, dynamic>{'total': 5, 'in_stock': 3, 'claimed': 2, 'suspended': 0},
  };
  Object? inventoryError;
  List<Map<String, dynamic>> subscribers = <Map<String, dynamic>>[
    <String, dynamic>{'home_id': 'h1'},
    <String, dynamic>{'home_id': 'h2'},
  ];
  Object? subscribersError;

  @override
  Future<Map<String, dynamic>> fetchDeviceInventory({
    String? status,
    String? search,
    int limit = 100,
    int offset = 0,
  }) async {
    calls.add('fetchDeviceInventory');
    final error = inventoryError;
    if (error != null) throw error;
    return Map<String, dynamic>.of(inventory);
  }

  @override
  Future<List<Map<String, dynamic>>> fetchServiceSubscribers() async {
    calls.add('fetchServiceSubscribers');
    final error = subscribersError;
    if (error != null) throw error;
    return List<Map<String, dynamic>>.of(subscribers);
  }
}

extension E1Harness on StateHarness {
  /// Harness'ın [E1Cloud] sahte bulutu.
  E1Cloud get e1 => cloud as E1Cloud;
}

// =============================================================================
// Kurulum
// =============================================================================

/// `readyHarness`'ın [E1Cloud] kullanan eşi: giriş yapmış kullanıcı + seçili ev + uç noktalar +
/// çevrimiçi cihaz + (varsayılan) bağlı MQTT. Gerçek durum yolları sahte bağımlılıklarla çalışır.
Future<StateHarness> e1Ready({
  String role = 'owner',
  String globalRole = 'user',
  List<EndpointModel>? endpoints,
  HomeModel? home,
  bool brokerConnected = true,
  bool deviceOnline = true,
  bool biometricSupported = false,
  void Function(StateHarness h)? configure,
}) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final clock = FakeClock();
  final cloud = E1Cloud(clock: clock);
  final h = StateHarness(clock: clock, cloud: cloud, biometricSupported: biometricSupported);
  h.mqtt.autoConnect = brokerConnected;
  cloud.homes = <HomeModel>[home ?? testHome(role: role)];
  cloud.endpoints[kHomeA] = endpoints ?? testEndpoints();
  cloud.devicesByHome[kHomeA] = <DeviceInfo>[
    DeviceInfo(deviceUuid: 'AHBU-S3-TEST01', name: 'Pano', online: deviceOnline, firmware: '1.1.0'),
  ];
  h.state
    ..setCurrentUserForTesting(UserModel(id: 'user-1', email: 'ayse@example.test', fullName: 'Ayşe Yılmaz', role: globalRole))
    ..setAuthStatusForTesting(AuthStatus.authenticated);
  configure?.call(h);
  if (globalRole == 'service_session') {
    final sessionHome = home ?? testHome(role: role);
    h.state.setHomesForTesting(<HomeModel>[sessionHome]);
    await h.state.selectHome(sessionHome);
  } else {
    await h.state.fetchHomes();
  }
  await pumpEventQueue();
  if (biometricSupported) h.state.setBiometricForTesting(isSupported: true);
  return h;
}

/// Hazır bir durumla sayfayı kurar ve pompalar. Durum **gerçek asenkron** bölgede kurulur
/// (`tester.runAsync`); sayfa sahte-zamanlı bölgede pompalanır.
Future<StateHarness> pumpReady(
  WidgetTester tester,
  Widget child, {
  String role = 'owner',
  String globalRole = 'user',
  HomeModel? home,
  List<EndpointModel>? endpoints,
  bool brokerConnected = true,
  bool deviceOnline = true,
  bool biometricSupported = false,
  void Function(StateHarness h)? configure,
  Size size = const Size(800, 1400),
  double textScale = 1.0,
  ThemeMode themeMode = ThemeMode.dark,
  bool settle = false,
}) async {
  final h = (await tester.runAsync(
    () => e1Ready(
      role: role,
      globalRole: globalRole,
      home: home,
      endpoints: endpoints,
      brokerConnected: brokerConnected,
      deviceOnline: deviceOnline,
      biometricSupported: biometricSupported,
      configure: configure,
    ),
  ))!;
  addTearDown(h.dispose);
  await pumpPage(tester, h.state, child, size: size, textScale: textScale, themeMode: themeMode, settle: settle);
  return h;
}

/// Hazır bir [AutomationState] ile sayfayı pompalar.
Future<void> pumpPage(
  WidgetTester tester,
  AutomationState state,
  Widget child, {
  Size size = const Size(800, 1400),
  double textScale = 1.0,
  ThemeMode themeMode = ThemeMode.dark,
  bool settle = false,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ChangeNotifierProvider<AutomationState>.value(
      value: state,
      child: MaterialApp(
        themeMode: themeMode,
        // Gerçek uygulamada sayfa zemini şeffaftır ve devre arka planı görünür; testte aynı zemin
        // renkleri kullanılır (kontrast ölçümleri gerçek yüzeyi yansıtsın).
        darkTheme: ThemeData.dark().copyWith(scaffoldBackgroundColor: AppTheme.bgDark),
        theme: ThemeData.light().copyWith(scaffoldBackgroundColor: AppTheme.bgLight),
        builder: (context, page) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
          child: page ?? const SizedBox.shrink(),
        ),
        home: child,
      ),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
}

/// Bir sayfayı kaydırmasız bir iskelet içinde (yalnızca tek kart/bileşen testi için) pompalar.
Widget scaffolded(Widget child) => Scaffold(body: SingleChildScrollView(padding: const EdgeInsets.all(16), child: child));

/// Girişsiz **yerel mod**: oturum yok, cihaz anahtarı ve adresi var (`Capabilities.localKeyHolder`).
Future<StateHarness> anonymousLocalHarness() async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final h = StateHarness();
  h.state
    ..setModeForTesting(AppMode.direct)
    ..setAuthStatusForTesting(AuthStatus.unauthenticated);
  h.direct.localKey = 'test-local-key-1234';
  return h;
}

/// Geçerli bir misafir evi ([kTestNow]'dan itibaren [hours] saat geçerli).
HomeModel guestHome({int hours = 2, String name = 'Misafir Evi'}) => HomeModel(
      id: kHomeA,
      name: name,
      role: 'guest',
      mqttTopicId: 'h_test',
      guestValidFrom: kTestNow.subtract(const Duration(hours: 1)),
      guestValidUntil: kTestNow.add(Duration(hours: hours)),
    );

/// Açık lambaları olan uç nokta listesi (varsayılan düzen + tüm aydınlatma açık).
List<EndpointModel> litEndpoints() =>
    testEndpoints().map((e) => e.isLight ? e.copyWith(currentState: true) : e).toList();

/// Bir anahtarlı widget'ın bulucusu (kısa yazım).
Finder byKeyName(String name) => find.byKey(Key(name));

/// Sunucu hata örnekleri.
const ApiException kNetworkError = ApiException(
  statusCode: 0,
  code: 'NETWORK',
  message: 'Sunucuya ulaşılamadı. İnternet bağlantınızı kontrol edin.',
);

const ApiException kServerError = ApiException(
  statusCode: 500,
  code: 'INTERNAL',
  message: 'Sunucu şu anda yanıt veremiyor. Lütfen daha sonra tekrar deneyin.',
);

/// `CommandResult` yardımcı (kullanılmayan içe aktarmayı önlemek için).
CommandResult deliveredResult() => const CommandResult(delivered: true, deviceOnline: true);
