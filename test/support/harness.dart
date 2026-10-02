import 'package:ev_otomasyon/models/api_models.dart';
import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes.dart';

/// Giriş yapmış kullanıcı + seçili ev ([kHomeA]) + yüklenmiş uç noktalar ([testEndpoints]) +
/// çevrimiçi cihaz + (varsayılan) bağlı MQTT. `AutomationState`'in gerçek yolları (fetchHomes ->
/// selectHome -> refresh -> gerçek zamanlı başlatma) sahte bağımlılıklarla çalıştırılır.
///
/// [role]: aktif evdeki rol (`owner`, `resident`, `guest`, `service_user`, `service_session`);
/// [globalRole]: hesabın küresel rolü. [home] verilirse [role] yok sayılır (misafir pencereleri için).
/// [configure]: `fetchHomes`'tan ÖNCE çağrılır (ör. `h.cloud.childLockError = ...`).
Future<StateHarness> readyHarness({
  String role = 'owner',
  String globalRole = 'user',
  List<EndpointModel>? endpoints,
  HomeModel? home,
  bool brokerConnected = true,
  bool deviceOnline = true,
  void Function(StateHarness harness)? configure,
}) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final h = StateHarness();
  h.mqtt.autoConnect = brokerConnected;
  h.cloud.homes = <HomeModel>[home ?? testHome(role: role)];
  h.cloud.endpoints[kHomeA] = endpoints ?? testEndpoints();
  h.cloud.devicesByHome[kHomeA] = <DeviceInfo>[
    DeviceInfo(deviceUuid: 'AHBU-S3-TEST01', name: 'Pano', online: deviceOnline, firmware: '1.1.0'),
  ];
  h.state
    ..setCurrentUserForTesting(UserModel(id: 'user-1', email: 'a@b.c', fullName: 'Ayşe', role: globalRole))
    ..setAuthStatusForTesting(AuthStatus.authenticated);
  configure?.call(h); // ev yüklenmeden önce sahteleri ayarlamak için (hata/kapı enjekte etme)
  if (globalRole == 'service_session') {
    // Servis PIN oturumunda ev listesi sunucudan değil giriş yanıtından gelir (tek ev).
    final sessionHome = home ?? testHome(role: role);
    h.state.setHomesForTesting(<HomeModel>[sessionHome]);
    await h.state.selectHome(sessionHome);
  } else {
    await h.state.fetchHomes();
  }
  await pumpEventQueue();
  return h;
}

/// Görünen uç nokta (bekleyen komutlar dahil): röle için `shutter: false`, panjur satırı için `true`.
EndpointModel ep(AutomationState s, int channel, {bool shutter = false}) =>
    s.cloudEndpoints.firstWhere((e) => e.channel == channel && e.isShutter == shutter);
