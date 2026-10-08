import 'package:ev_otomasyon/models/api_models.dart';
import 'package:ev_otomasyon/ui/dashboard/dashboard_states.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/panel/doctor_report.dart';
import 'package:ev_otomasyon/ui/pages/wifi_recovery_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/support.dart';
import 'e2_support.dart';

/// bireysel-12: buluta hiç bağlanmamış pano "çevrimdışı / son bilinen durum" diye gösterilmez; Sistem Doktoru `NEVER_SEEN` ve
/// tanımadığı ağ durumlarını hata saymadan gösterir (sunucu sözleşme 15).
void main() {
  group('DoctorReport: NEVER_SEEN ve tanınmayan ağ durumu', () {
    test('NEVER_SEEN: uyarı seviyesi (arıza değil), Wi-Fi kurulumu önerilir', () {
      final r = DoctorReport.parse(<String, dynamic>{
        'home_network': <String, dynamic>{'status': 'NEVER_SEEN', 'seconds_since_last_seen': null},
        'hardware_power': <String, dynamic>{'status': 'UNKNOWN'},
        'devices': <Map<String, dynamic>>[
          <String, dynamic>{'device_uuid': 'AHBU-S3-AAA111', 'online': false, 'network_status': 'NEVER_SEEN'},
        ],
        'diagnosis_level': 'warning',
      });
      expect(r.networkLevel, DoctorLevel.warning);
      expect(r.neverSeen, isTrue);
      expect(r.suggestsWifiRecovery, isTrue);
      expect(r.devices.single.networkStatus, 'NEVER_SEEN');
    });

    test('tanınmayan ağ durumu hata sayılmaz (bilinmiyor); OFFLINE ve ERROR yine sorun', () {
      DoctorLevel levelOf(String s) =>
          DoctorReport.parse(<String, dynamic>{'home_network': <String, dynamic>{'status': s}}).networkLevel;
      expect(levelOf('YENI_DURUM'), DoctorLevel.unknown);
      expect(levelOf('OFFLINE'), DoctorLevel.error);
      expect(levelOf('ERROR'), DoctorLevel.error);
    });
  });

  group('DeviceOfflineNotice: hiç bağlanmamış pano', () {
    Future<E2Env> pumpNotice(WidgetTester tester, {required List<DeviceInfo> devices, String role = 'owner'}) async {
      final env = e2Env(role: role);
      env.state.setDevicesForTesting(devices);
      await pumpApp(
        tester,
        state: env.state,
        child: const Scaffold(body: SingleChildScrollView(child: DeviceOfflineNotice())),
      );
      await tester.pump();
      return env;
    }

    testWidgets('hiç görülmemiş panoda başlık "Pano henüz bağlanmadı", "son bilinen durum" yok, Wi-Fi kurulumu düğmesi var',
        (tester) async {
      await pumpNotice(tester, devices: const <DeviceInfo>[DeviceInfo(deviceUuid: 'AHBU-S3-AAA111')]);
      expect(find.text('Pano henüz bağlanmadı'), findsOneWidget);
      expect(find.textContaining('son bilinen durum'), findsNothing);
      expect(find.text('Pano Wi-Fi Kurulumu'), findsOneWidget);
      await tapKey(tester, 'btn_wifi_recovery');
      final dialog = tester.widget<WifiRecoveryDialog>(find.byType(WifiRecoveryDialog));
      expect(dialog.deviceUuid, 'AHBU-S3-AAA111');
    });

    testWidgets('daha önce görülmüş panoda eski metin (çevrimdışı + son bilinen durum)', (tester) async {
      await pumpNotice(
        tester,
        devices: <DeviceInfo>[DeviceInfo(deviceUuid: 'AHBU-S3-AAA111', lastSeenAt: kTestNow.subtract(const Duration(hours: 2)))],
      );
      expect(find.text('Pano çevrimdışı'), findsOneWidget);
      expect(find.textContaining('son bilinen durumdur'), findsOneWidget);
    });

    testWidgets('misafire hiç bağlanmamış panoda da Wi-Fi düğmesi önerilmez', (tester) async {
      await pumpNotice(
        tester,
        devices: const <DeviceInfo>[DeviceInfo(deviceUuid: 'AHBU-S3-AAA111')],
        role: 'guest',
      );
      expect(find.text('Pano henüz bağlanmadı'), findsOneWidget);
      expect(find.byKey(const Key('btn_wifi_recovery')), findsNothing);
    });
  });
}
