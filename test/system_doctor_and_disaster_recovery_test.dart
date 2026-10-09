import 'dart:async';

import 'package:ev_otomasyon/models/api_models.dart';
import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/services/api_exception.dart';
import 'package:ev_otomasyon/ui/pages/replace_board_dialog.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/panel/doctor_report.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/service_setup_wizard_page.dart';
import 'package:ev_otomasyon/ui/pages/system_doctor_dialog.dart';
import 'package:ev_otomasyon/ui/pages/wifi_recovery_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/support.dart' show kHomeA, kHomeB;
import 'ui/f_support.dart';
import 'ui/f_widget_support.dart';

/// Sistem doktoru ve pano değişimi (felaket kurtarma) davranış testleri.
///
/// Not: Cihaz ayarları sayfasındaki doktor/kurtarma kartı testi bu dosyadan çıkarıldı; o ekran WP-E1
/// paketinindir (test/ui/e1_settings_test.dart).

const String kOldUid = 'AHBU-S3-OLD001';
const String kOldUid2 = 'AHBU-S3-OLD002';
const String kNewUid = 'AHBU-S3-NEW001';
const String kNewPin = '246810';
const String kNewLabelQr = 'https://evotomasyon.gudeteknoloji.com.tr/claim?uid=$kNewUid&pin=$kNewPin';

HomeModel staffHome({String id = kHomeA, String name = 'Daire 5 - Nilüfer', String role = 'service_user'}) =>
    HomeModel(id: id, name: name, role: role);

Map<String, dynamic> healthyReport() => <String, dynamic>{
      'cloud': <String, dynamic>{
        'status': 'OK',
        'latency_ms': 37,
        'db_connected': true,
        'mqtt_bridge_connected': true,
      },
      'home_network': <String, dynamic>{
        'status': 'OK',
        'device_ip': '192.168.1.42',
        'seconds_since_last_seen': 12,
      },
      'hardware_power': <String, dynamic>{'status': 'OK', 'is_online': true},
      'devices': <Map<String, dynamic>>[],
      'endpoint_count': 8,
      'diagnosis_title': 'Tüm Sistemler Sağlıklı ve Çevrimiçi',
      'diagnosis_summary': 'Bulut, ev modemi ve pano kesintisiz haberleşiyor.',
      'diagnosis_level': 'ok',
    };

Future<ServiceHarness> doctorEnv(
  WidgetTester tester, {
  String role = 'staff',
  bool withHome = true,
  String homeRole = 'service_user',
}) async {
  final env = await serviceHarness(role: role, flush: () async {});
  if (withHome) await activateHome(tester, env, staffHome(role: homeRole));
  return env;
}

Future<void> openDoctor(WidgetTester tester, ServiceHarness env, {Map<String, dynamic>? initialData}) async {
  await pumpLauncher(tester, env, (ctx) => SystemDoctorDialog.show(ctx, initialData: initialData));
  await tester.tap(find.byKey(const Key('launcher')));
  await settle(tester);
}

bool exists(String key) => find.byKey(Key(key)).evaluate().isNotEmpty;

String badgeOf(WidgetTester tester, String tier) =>
    tester.widget<Text>(find.byKey(Key('${tier}_badge'))).data!;

void main() {
  group('DoctorReport (eksik veriye dayanıklı ayrıştırma)', () {
    test('tam yanıttan seviyeler ve değerler okunur', () {
      final r = DoctorReport.parse(healthyReport());
      expect(r.cloudLevel, DoctorLevel.ok);
      expect(r.networkLevel, DoctorLevel.ok);
      expect(r.powerLevel, DoctorLevel.ok);
      expect(r.latencyMs, 37);
      expect(r.deviceIp, '192.168.1.42');
      expect(r.level, 'ok');
      expect(r.suggestsWifiRecovery, isFalse);
    });

    test('boş yanıtta hiçbir alan uydurulmaz: tüm seviyeler bilinmiyor', () {
      final r = DoctorReport.parse(const <String, dynamic>{});
      expect(r.isEmpty, isTrue);
      expect(r.cloudLevel, DoctorLevel.unknown);
      expect(r.networkLevel, DoctorLevel.unknown);
      expect(r.powerLevel, DoctorLevel.unknown);
      expect(r.latencyMs, isNull);
      expect(r.level, isNull);
      expect(r.suggestsWifiRecovery, isTrue, reason: 'ev ağı durumu bilinmiyorsa kurtarma önerilir');
    });

    test('ağ durumu: OFFLINE/ERROR/UNKNOWN kurtarma önerir; OK, WARNING ve UNCLAIMED önermez', () {
      bool suggests(String status) => DoctorReport.parse(<String, dynamic>{
            'home_network': <String, dynamic>{'status': status},
          }).suggestsWifiRecovery;
      expect(suggests('OFFLINE'), isTrue);
      expect(suggests('ERROR'), isTrue);
      expect(suggests('UNKNOWN'), isTrue);
      expect(suggests('OK'), isFalse);
      expect(suggests('WARNING'), isFalse);
      expect(suggests('UNCLAIMED'), isFalse);
    });

    test('sko-6 (C15): bulut köprüsü kesikken ağ/güç UNKNOWN nötrdür; Wi-Fi kurtarma önerilmez', () {
      final r = DoctorReport.parse(<String, dynamic>{
        'cloud': <String, dynamic>{'status': 'DEGRADED', 'db_connected': true, 'mqtt_bridge_connected': false},
        'home_network': <String, dynamic>{'status': 'UNKNOWN'},
        'hardware_power': <String, dynamic>{'status': 'UNKNOWN'},
        'diagnosis_title': 'Bulut Bağlantısında Geçici Sorun',
        'diagnosis_summary': 'Sunucumuzun cihazlarla bağlantısında geçici bir sorun var; panonuz büyük olasılıkla '
            'çalışıyor. Birkaç dakika sonra yeniden deneyin.',
        'diagnosis_level': 'warning',
        'action_recommendation': null,
      });
      expect(r.networkLevel, DoctorLevel.unknown);
      expect(r.powerLevel, DoctorLevel.unknown);
      expect(r.suggestsWifiRecovery, isFalse, reason: 'durum bilinmiyor çünkü bulut köprüsü kesik; ev ağı arızası değil');
    });

    test('sko-6 (C15): köprü yeni bağlandıysa (bulut OK, 120 sn dolmadı) UNKNOWN yine nötr; Wi-Fi kurtarma önerilmez', () {
      // Sunucu köprü yeniden bağlandıktan sonraki 120 sn içinde de C15 metnini ve UNKNOWN'u verir; bulut katmanı o an OK'tur.
      final r = DoctorReport.parse(<String, dynamic>{
        'cloud': <String, dynamic>{'status': 'OK', 'db_connected': true, 'mqtt_bridge_connected': true},
        'home_network': <String, dynamic>{'status': 'UNKNOWN'},
        'hardware_power': <String, dynamic>{'status': 'UNKNOWN'},
        'diagnosis_title': 'Bulut Bağlantısında Geçici Sorun',
        'diagnosis_level': 'warning',
        'action_recommendation': null,
      });
      expect(r.suggestsWifiRecovery, isFalse);
    });

    test('bulut DEGRADED uyarı, bilinmeyen değer hata sayılır; sunucu seviyesi yalnızca ok/warning/error', () {
      expect(DoctorReport.parse(<String, dynamic>{'cloud': <String, dynamic>{'status': 'degraded'}}).cloudLevel, DoctorLevel.warning);
      expect(DoctorReport.parse(<String, dynamic>{'cloud': <String, dynamic>{'status': 'PATLADI'}}).cloudLevel, DoctorLevel.error);
      expect(DoctorReport.parse(<String, dynamic>{'diagnosis_level': 'felaket'}).level, isNull);
      expect(DoctorReport.parse(<String, dynamic>{'diagnosis_level': 'ERROR'}).level, 'error');
    });

    test('bozuk cihaz kaydı atlanır; görülme metni makul birimde yazılır', () {
      final r = DoctorReport.parse(<String, dynamic>{
        'devices': <dynamic>[
          <String, dynamic>{'device_uuid': 'AHBU-S3-AAA111', 'online': true, 'seconds_since_last_seen': 5},
          'saçma',
          <String, dynamic>{'name': 'kimliksiz'},
        ],
      });
      expect(r.devices.map((d) => d.deviceUuid), <String>['AHBU-S3-AAA111']);
      expect(DoctorReport.seenText(null), isNull);
      expect(DoctorReport.seenText(30), '30 sn önce');
      expect(DoctorReport.seenText(600), '10 dk önce');
      expect(DoctorReport.seenText(7200), '2 sa önce');
      expect(DoctorReport.seenText(172800), '2 gün önce');
    });
  });

  group('sistem doktoru', () {
    testWidgets('sunucu hiç yanıt vermezse 30 sn sonra zaman aşımı açıklaması ve Tekrar Dene çıkar', (tester) async {
      final env = await doctorEnv(tester);
      addTearDown(env.dispose);
      env.cloud.diagnostic = healthyReport();
      env.cloud.diagnosticGate = Completer<void>();
      await openDoctor(tester, env);
      expect(exists('doctor_loading'), isTrue);

      await tester.pump(const Duration(seconds: 31));
      await settle(tester);
      expect(exists('doctor_loading'), isFalse);
      expect(exists('doctor_error_timeout'), isTrue);
      expect(find.text('Sunucu zamanında yanıt vermedi'), findsOneWidget);

      env.cloud.diagnosticGate!.complete();
      await tapKey(tester, 'btn_doctor_retry');
      await settle(tester);
      expect(exists('doctor_report'), isTrue);
    });

    testWidgets('sağlıklı yanıtta üç katman sağlıklı görünür ve ölçülen gecikme yazılır', (tester) async {
      final env = await doctorEnv(tester);
      addTearDown(env.dispose);
      env.cloud.diagnostic = healthyReport();
      await openDoctor(tester, env);

      expect(badgeOf(tester, 'doctor_tier_cloud'), 'Sağlıklı');
      expect(badgeOf(tester, 'doctor_tier_network'), 'Sağlıklı');
      expect(badgeOf(tester, 'doctor_tier_power'), 'Sağlıklı');
      expect(find.textContaining('Gecikme: 37 ms'), findsOneWidget);
      expect(find.text('Tüm Sistemler Sağlıklı ve Çevrimiçi'), findsOneWidget);
      expect(find.textContaining('Daire 5 - Nilüfer'), findsOneWidget);
      expect(exists('btn_doctor_recovery'), isFalse, reason: 'ev ağı sağlıklıyken kurtarma düğmesi çıkmaz');
    });

    testWidgets('sunucunun göndermediği alanlar "Veri yok" yazar; uydurma OK ya da 20 ms görünmez', (tester) async {
      final env = await doctorEnv(tester);
      addTearDown(env.dispose);
      env.cloud.diagnostic = <String, dynamic>{};
      await openDoctor(tester, env);

      expect(badgeOf(tester, 'doctor_tier_cloud'), 'Veri yok');
      expect(badgeOf(tester, 'doctor_tier_network'), 'Veri yok');
      expect(badgeOf(tester, 'doctor_tier_power'), 'Veri yok');
      expect(find.textContaining('20 ms'), findsNothing);
      expect(find.text('Sağlıklı'), findsNothing);
      expect(find.textContaining('Teşhis özeti: Veri yok'), findsOneWidget);
    });

    testWidgets('gecikme alanı yoksa "Gecikme: Veri yok" yazılır', (tester) async {
      final env = await doctorEnv(tester);
      addTearDown(env.dispose);
      env.cloud.diagnostic = <String, dynamic>{
        'cloud': <String, dynamic>{'status': 'OK'},
        'home_network': <String, dynamic>{'status': 'OK'},
        'hardware_power': <String, dynamic>{'status': 'OK'},
      };
      await openDoctor(tester, env);
      expect(find.textContaining('Gecikme: Veri yok'), findsOneWidget);
      expect(find.textContaining('Son görülme: Veri yok'), findsOneWidget);
    });

    testWidgets('ev ağı kapalıysa neden/çözüm gösterilir ve Wi-Fi kurtarma düğmesi tanı penceresini kapatıp kurtarmayı açar',
        (tester) async {
      final env = await doctorEnv(tester);
      addTearDown(env.dispose);
      env.cloud.diagnostic = <String, dynamic>{
        ...healthyReport(),
        'home_network': <String, dynamic>{'status': 'OFFLINE', 'seconds_since_last_seen': 1800},
        'hardware_power': <String, dynamic>{'status': 'SUSPECTED_OFFLINE_OR_POWER_OUTAGE'},
        'diagnosis_title': 'Pano Çevrimdışı (Ev İnterneti veya Güç Kesik)',
        'diagnosis_summary': 'Pano 30 dakikadır sinyal göndermedi.',
        'diagnosis_level': 'error',
        'action_recommendation': '1. Sigortayı kontrol edin.',
      };
      await openDoctor(tester, env);

      expect(badgeOf(tester, 'doctor_tier_network'), 'Sorun var');
      expect(badgeOf(tester, 'doctor_tier_power'), 'Sorun var');
      expect(find.text('Ne yapmalıyım?'), findsOneWidget);
      expect(find.text('1. Sigortayı kontrol edin.'), findsOneWidget);
      expect(exists('btn_doctor_recovery'), isTrue);

      await tapKey(tester, 'btn_doctor_recovery');
      await settle(tester);
      expect(find.byType(SystemDoctorDialog), findsNothing);
      expect(find.byType(WifiRecoveryDialog), findsOneWidget);
    });

    testWidgets('ev ağı durumu bilinmiyorsa da kurtarma düğmesi çıkar; UNCLAIMED iken çıkmaz', (tester) async {
      final env = await doctorEnv(tester);
      addTearDown(env.dispose);
      env.cloud.diagnostic = <String, dynamic>{'home_network': <String, dynamic>{'status': 'UNKNOWN'}};
      await openDoctor(tester, env);
      expect(exists('btn_doctor_recovery'), isTrue);

      await tapKey(tester, 'btn_doctor_close');
      await settle(tester);
      env.cloud.diagnostic = <String, dynamic>{
        'home_network': <String, dynamic>{'status': 'UNCLAIMED'},
        'hardware_power': <String, dynamic>{'status': 'UNCLAIMED'},
        'cloud': <String, dynamic>{'status': 'OK', 'latency_ms': 5},
      };
      await tester.tap(find.byKey(const Key('launcher')));
      await settle(tester);
      expect(badgeOf(tester, 'doctor_tier_network'), 'Pano yok');
      expect(exists('btn_doctor_recovery'), isFalse);
    });

    testWidgets('bireysel-12: hiç bağlanmamış pano (NEVER_SEEN) arıza değil uyarı; Wi-Fi kurulumu önerilir', (tester) async {
      final env = await doctorEnv(tester);
      addTearDown(env.dispose);
      env.cloud.diagnostic = <String, dynamic>{
        ...healthyReport(),
        'home_network': <String, dynamic>{'status': 'NEVER_SEEN', 'seconds_since_last_seen': null},
        'hardware_power': <String, dynamic>{'status': 'UNKNOWN'},
        'devices': <Map<String, dynamic>>[
          <String, dynamic>{'device_uuid': kOldUid, 'online': false, 'network_status': 'NEVER_SEEN'},
          <String, dynamic>{'device_uuid': kOldUid2, 'online': false, 'network_status': 'YENI_DURUM'},
        ],
        'diagnosis_title': 'Pano Henüz Buluta Hiç Bağlanmadı',
        'diagnosis_level': 'warning',
      };
      await openDoctor(tester, env);

      expect(badgeOf(tester, 'doctor_tier_network'), 'Uyarı');
      expect(find.text('Pano henüz buluta hiç bağlanmadı'), findsOneWidget);
      expect(find.textContaining('İnternet / modem bağlantısı yok'), findsNothing);
      expect(find.text('$kOldUid: henüz buluta hiç bağlanmadı'), findsOneWidget);
      expect(find.textContaining('$kOldUid2: çevrimdışı'), findsOneWidget, reason: 'tanınmayan durum çökmeden genel biçimde');
      expect(find.text('Pano Wi-Fi Kurulumu'), findsOneWidget);
    });

    testWidgets('çok panolu dairede tüm panolar son görülme bilgisiyle listelenir', (tester) async {
      final env = await doctorEnv(tester);
      addTearDown(env.dispose);
      env.cloud.diagnostic = <String, dynamic>{
        ...healthyReport(),
        'devices': <Map<String, dynamic>>[
          <String, dynamic>{'device_uuid': kOldUid, 'name': 'Salon Panosu', 'online': true, 'seconds_since_last_seen': 20},
          <String, dynamic>{'device_uuid': kOldUid2, 'online': false, 'seconds_since_last_seen': 4000},
        ],
      };
      await openDoctor(tester, env);
      expect(find.textContaining('Salon Panosu: çevrimiçi'), findsOneWidget);
      expect(find.textContaining('$kOldUid2: çevrimdışı'), findsOneWidget);
      expect(find.textContaining('1 sa önce'), findsOneWidget);
    });

    testWidgets('ağ yokken, zaman aşımında, 401/403/404/500 durumlarında ayrı ve açıklayıcı mesaj gösterilir', (tester) async {
      final cases = <({Object error, String key, String title})>[
        (
          error: ApiException.network(),
          key: 'doctor_error_offline',
          title: 'İnternet bağlantısı yok',
        ),
        (
          error: ApiException.network(cause: TimeoutException('x'), message: 'Sunucu zamanında yanıt vermedi. Tekrar deneyin.'),
          key: 'doctor_error_timeout',
          title: 'Sunucu zamanında yanıt vermedi',
        ),
        (
          error: TimeoutException('x'),
          key: 'doctor_error_timeout',
          title: 'Sunucu zamanında yanıt vermedi',
        ),
        (
          error: const ApiException(statusCode: 401, code: 'TOKEN_EXPIRED', message: 'Oturumunuz sona erdi.'),
          key: 'doctor_error_unauthorized',
          title: 'Oturumunuz sona erdi',
        ),
        (
          error: const ApiException(statusCode: 403, code: 'FORBIDDEN', message: 'Bu işlem için yetkiniz yok.'),
          key: 'doctor_error_forbidden',
          title: 'Bu daire için yetkiniz yok',
        ),
        (
          error: const ApiException(statusCode: 404, code: 'NOT_FOUND', message: 'Daire bulunamadı.'),
          key: 'doctor_error_notFound',
          title: 'Daire bulunamadı',
        ),
        (
          error: const ApiException(statusCode: 500, code: 'INTERNAL', message: 'x'),
          key: 'doctor_error_server',
          title: 'Sunucu şu anda yanıt veremiyor',
        ),
      ];
      for (final c in cases) {
        final env = await doctorEnv(tester);
        addTearDown(env.dispose);
        env.cloud.diagnosticError = c.error;
        await openDoctor(tester, env);
        expect(exists(c.key), isTrue, reason: c.title);
        expect(find.text(c.title), findsOneWidget, reason: c.key);
        // Yanlış rozetler görünmemeli: hata durumunda "Sağlıklı" yazılmaz.
        expect(find.text('Sağlıklı'), findsNothing);
        final retryable = c.key != 'doctor_error_unauthorized' && c.key != 'doctor_error_forbidden';
        expect(exists('btn_doctor_retry'), retryable, reason: 'yeniden deneme yalnızca anlamlı hatalarda: ${c.key}');
        await tapKey(tester, 'btn_doctor_close');
        await settle(tester);
      }
    });

    testWidgets('hatadan sonra Tekrar Dene başarılı olursa rapor gelir', (tester) async {
      final env = await doctorEnv(tester);
      addTearDown(env.dispose);
      env.cloud.diagnosticError = ApiException.network();
      env.cloud.diagnostic = healthyReport();
      await openDoctor(tester, env);
      expect(exists('doctor_error'), isTrue);

      env.cloud.diagnosticError = null;
      await tapKey(tester, 'btn_doctor_retry');
      await settle(tester);
      expect(exists('doctor_error'), isFalse);
      expect(badgeOf(tester, 'doctor_tier_cloud'), 'Sağlıklı');
      expect(env.cloud.diagnosticCalls, 2);
    });

    testWidgets('Testi Yeniden Çalıştır yeni istek atar', (tester) async {
      final env = await doctorEnv(tester);
      addTearDown(env.dispose);
      env.cloud.diagnostic = healthyReport();
      await openDoctor(tester, env);
      await tapKey(tester, 'btn_doctor_rerun');
      await settle(tester);
      expect(env.cloud.diagnosticCalls, 2);
    });

    testWidgets('yanıt beklenirken yükleniyor göstergesi çıkar; sonsuz dönmez', (tester) async {
      final env = await doctorEnv(tester);
      addTearDown(env.dispose);
      env.cloud.diagnostic = healthyReport();
      env.cloud.diagnosticGate = Completer<void>();
      await openDoctor(tester, env);
      expect(exists('doctor_loading'), isTrue);
      env.cloud.diagnosticGate!.complete();
      await settle(tester);
      expect(exists('doctor_loading'), isFalse);
      expect(exists('doctor_report'), isTrue);
    });

    testWidgets('süper yönetici daire seçmediyse nedeni açıkça yazılır ve istek atılmaz', (tester) async {
      final env = await doctorEnv(tester, role: 'super', withHome: false);
      addTearDown(env.dispose);
      await openDoctor(tester, env);
      expect(exists('doctor_no_home'), isTrue);
      expect(find.textContaining('Süper yönetici hesabı belirli bir daireye bağlı değildir'), findsOneWidget);
      expect(env.cloud.diagnosticCalls, 0);
    });

    testWidgets('servis personeli de daire seçmediyse "önce daire seçin" der', (tester) async {
      final env = await doctorEnv(tester, withHome: false);
      addTearDown(env.dispose);
      await openDoctor(tester, env);
      expect(find.textContaining('Önce bir daire seçin'), findsOneWidget);
      expect(env.cloud.diagnosticCalls, 0);
    });

    testWidgets('hazır veri verilirse ilk açılışta istek atılmaz ve pencere yine de yeniden çalıştırılabilir', (tester) async {
      final env = await doctorEnv(tester);
      addTearDown(env.dispose);
      env.cloud.diagnostic = healthyReport();
      await openDoctor(tester, env, initialData: healthyReport());
      expect(env.cloud.diagnosticCalls, 0);
      expect(badgeOf(tester, 'doctor_tier_cloud'), 'Sağlıklı');
      await tapKey(tester, 'btn_doctor_rerun');
      await settle(tester);
      expect(env.cloud.diagnosticCalls, 1);
    });

    testWidgets('pencere kapandıktan sonra gelen yanıt hata üretmez', (tester) async {
      final env = await doctorEnv(tester);
      addTearDown(env.dispose);
      env.cloud.diagnostic = healthyReport();
      env.cloud.diagnosticGate = Completer<void>();
      await openDoctor(tester, env);
      await tapKey(tester, 'btn_doctor_close');
      await settle(tester);
      env.cloud.diagnosticGate!.complete();
      await settle(tester);
      expect(tester.takeException(), isNull);
    });

    testWidgets('dar ekranda ve büyük yazıda taşma olmadan çalışır', (tester) async {
      final env = await doctorEnv(tester);
      addTearDown(env.dispose);
      env.cloud.diagnostic = <String, dynamic>{
        ...healthyReport(),
        'home_network': <String, dynamic>{'status': 'OFFLINE', 'device_ip': '192.168.100.200', 'seconds_since_last_seen': 99999},
        'diagnosis_level': 'error',
        'action_recommendation': 'Çok uzun bir öneri metni ' * 8,
      };
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await pumpLauncher(tester, env, (ctx) => SystemDoctorDialog.show(ctx), size: const Size(360, 800));
      await tester.tap(find.byKey(const Key('launcher')));
      await settle(tester);
      expect(tester.takeException(), isNull);
    });
  });

  group('pano değişimi', () {
    Future<ServiceHarness> replaceEnv(
      WidgetTester tester, {
      String homeRole = 'service_user',
      List<DeviceInfo>? devices,
      bool withHome = true,
      String role = 'staff',
    }) async {
      final env = await serviceHarness(role: role, flush: () async {});
      env.cloud.devicesByHome[kHomeA] = devices ??
          <DeviceInfo>[
            const DeviceInfo(deviceUuid: kOldUid, name: 'Salon Panosu', online: false, firmware: '1.1.0'),
          ];
      if (withHome) await activateHome(tester, env, staffHome(role: homeRole));
      return env;
    }

    Future<void> openReplace(WidgetTester tester, ServiceHarness env, {String? scan = kNewLabelQr}) async {
      await pumpLauncher(tester, env, (ctx) => ReplaceBoardDialog.show(ctx, scanner: fakeScanner(scan)));
      await tester.tap(find.byKey(const Key('launcher')));
      await settle(tester);
    }

    testWidgets('hedef daire adı en üstte görünür; tek panolu dairede eski pano otomatik seçilir ve istekle gider', (tester) async {
      final env = await replaceEnv(tester);
      addTearDown(env.dispose);
      await openReplace(tester, env);

      expect(find.descendant(of: find.byKey(const Key('replace_target_home')), matching: find.text('Daire 5 - Nilüfer')), findsOneWidget);
      expect(find.byKey(const Key('card_oldboard_$kOldUid')), findsOneWidget);

      await tapKey(tester, 'btn_scan_new_board');
      await settle(tester);
      await tapKey(tester, 'btn_replace_submit');
      await settle(tester);
      // Onay penceresi: daire + eski pano + yeni pano özeti
      final summary = find.byKey(const Key('replace_summary'));
      expect(summary, findsOneWidget);
      expect(find.descendant(of: summary, matching: find.text('Daire 5 - Nilüfer')), findsOneWidget);
      expect(find.descendant(of: summary, matching: find.textContaining(kOldUid)), findsOneWidget);
      expect(find.descendant(of: summary, matching: find.text(kNewUid)), findsOneWidget);
      expect(env.cloud.replaceRequests, isEmpty, reason: 'onaydan önce istek yok');

      await tapKey(tester, 'btn_replace_confirm');
      await settle(tester);
      expect(env.cloud.replaceRequests, hasLength(1));
      final req = env.cloud.replaceRequests.single;
      expect(req['home_id'], kHomeA);
      expect(req['old'], kOldUid, reason: 'eski pano kimliği her zaman gönderilir');
      expect(req['new'], kNewUid);
      expect(req['pin_length'], 6);
      expect(find.byKey(const Key('replace_result_title')), findsOneWidget);
    });

    testWidgets('PIN etiketten okunsa bile ekranda açık yazılmaz: alan gizlidir, hiçbir metinde geçmez', (tester) async {
      final env = await replaceEnv(tester);
      addTearDown(env.dispose);
      await openReplace(tester, env);
      await tapKey(tester, 'btn_scan_new_board');
      await settle(tester);

      final pinField = tester.widget<TextField>(find.descendant(of: find.byKey(const Key('field_new_pin')), matching: find.byType(TextField)));
      expect(pinField.obscureText, isTrue);
      expect(find.byWidgetPredicate((w) => w is Text && (w.data ?? '').contains(kNewPin)), findsNothing);
    });

    testWidgets('çok panolu dairede eski pano seçilmeden gönderilemez; seçilen pano istekle gider', (tester) async {
      final env = await replaceEnv(tester, devices: const <DeviceInfo>[
        DeviceInfo(deviceUuid: kOldUid, name: 'Salon Panosu', online: true),
        DeviceInfo(deviceUuid: kOldUid2, name: 'Mutfak Panosu', online: false),
      ]);
      addTearDown(env.dispose);
      await openReplace(tester, env);

      await tapKey(tester, 'btn_scan_new_board');
      await settle(tester);
      await tapKey(tester, 'btn_replace_submit');
      await settle(tester);
      expect(exists('replace_old_error'), isTrue, reason: 'eski pano seçilmedi');
      expect(exists('replace_summary'), isFalse);

      await tapKey(tester, 'card_oldboard_$kOldUid2');
      await tester.pump();
      await tapKey(tester, 'btn_replace_submit');
      await settle(tester);
      await tapKey(tester, 'btn_replace_confirm');
      await settle(tester);
      expect(env.cloud.replaceRequests.single['old'], kOldUid2);
    });

    testWidgets('yeni pano eski panoyla aynı olamaz; kimlik biçimi ve PIN doğrulanır', (tester) async {
      final env = await replaceEnv(tester);
      addTearDown(env.dispose);
      await openReplace(tester, env, scan: null);

      await tapKey(tester, 'btn_replace_submit');
      await settle(tester);
      expect(find.textContaining('AHBU- ile başlamalıdır'), findsOneWidget);
      expect(find.textContaining('tam 6 rakam'), findsOneWidget);

      await typeKey(tester, 'field_new_uid', kOldUid);
      await typeKey(tester, 'field_new_pin', '123456');
      await tapKey(tester, 'btn_replace_submit');
      await settle(tester);
      expect(find.text('Yeni pano, değiştirilecek eski panoyla aynı olamaz.'), findsOneWidget);
      expect(env.cloud.replaceRequests, isEmpty);
    });

    testWidgets('onay penceresinden vazgeçilirse istek atılmaz', (tester) async {
      final env = await replaceEnv(tester);
      addTearDown(env.dispose);
      await openReplace(tester, env);
      await tapKey(tester, 'btn_scan_new_board');
      await settle(tester);
      await tapKey(tester, 'btn_replace_submit');
      await settle(tester);
      await tapKey(tester, 'btn_replace_cancel');
      await settle(tester);
      expect(env.cloud.replaceRequests, isEmpty);
      expect(exists('field_new_uid'), isTrue, reason: 'form açık kalır');
    });

    testWidgets('sonuç: uyarılar, kısmi başarı, bekleyen panjur süreleri ve çocuk kilidi kullanıcıya gösterilir', (tester) async {
      final env = await replaceEnv(tester);
      addTearDown(env.dispose);
      env.cloud.replaceBoardToReturn = ReplaceBoardResult(
        newDeviceUuid: kNewUid,
        oldDeviceUuid: kOldUid,
        homeId: kClaimedHome,
        migratedEndpointsCount: 12,
        runtimeSync: 'pending_device_online',
        shutterRuntimes: const <ShutterRuntimeSync>[
          ShutterRuntimeSync(shutter: 1, seconds: 22),
          ShutterRuntimeSync(shutter: 2, seconds: 31),
        ],
        childLockEnabled: true,
        childLockSync: 'pending_device_online',
        warnings: const <String>['Eski pano çevrimdışıydı; yetki iptali kuyruğa alındı.'],
        partial: true,
      );
      await openReplace(tester, env);
      await tapKey(tester, 'btn_scan_new_board');
      await settle(tester);
      await tapKey(tester, 'btn_replace_submit');
      await settle(tester);
      await tapKey(tester, 'btn_replace_confirm');
      await settle(tester);

      expect(find.text('Pano değişimi kısmen tamamlandı'), findsOneWidget);
      expect(exists('replace_partial'), isTrue);
      expect(find.text('Eski pano çevrimdışıydı; yetki iptali kuyruğa alındı.'), findsOneWidget);
      expect(find.textContaining('12 kanal yeni panoya aktarıldı'), findsOneWidget);
      expect(find.text('Panjur süreleri yeni pano çevrimiçi olunca otomatik uygulanacak.'), findsOneWidget);
      expect(find.text('Panjur 1: 22 sn'), findsOneWidget);
      expect(find.text('Panjur 2: 31 sn'), findsOneWidget);
      expect(exists('replace_childlock_pending'), isTrue);
    });

    testWidgets('sonuç ekranından kurulum sihirbazı mevcut cihaz kipinde açılır; yanıttaki tek seferlik bulut kimliği ona aktarılır', (tester) async {
      final env = await replaceEnv(tester);
      addTearDown(env.dispose);
      env.cloud.replaceBoardToReturn = ReplaceBoardResult(
        newDeviceUuid: kNewUid,
        oldDeviceUuid: kOldUid,
        homeId: kClaimedHome,
        migratedEndpointsCount: 6,
        deviceCredential: const DeviceMqttCredential(
          host: 'mqtt.ornek.test',
          port: 8884,
          username: 'd_h_yeni',
          password: kCredentialPassword,
          topicId: 'h_yeni',
        ),
      );
      await openReplace(tester, env);
      await tapKey(tester, 'btn_scan_new_board');
      await settle(tester);
      await tapKey(tester, 'btn_replace_submit');
      await settle(tester);
      await tapKey(tester, 'btn_replace_confirm');
      await settle(tester);
      await tapKey(tester, 'btn_replace_open_wizard');
      await settle(tester);
      expect(find.byKey(const Key('nav_setup_title')), findsOneWidget);
      expect(find.byType(ReplaceBoardDialog), findsNothing);
      final page = tester.widget<ServiceSetupWizardPage>(find.byType(ServiceSetupWizardPage));
      expect(page.initialCredential?.password, kCredentialPassword,
          reason: 'yanıttaki tek seferlik bulut kimliği sihirbaza (yalnızca bellek) aktarılır');
      expect(page.existingTarget?.deviceUuid, kNewUid);
    });

    testWidgets('sunucu hatasında hata görünür, PIN alanı temizlenir, kimlik alanı korunur', (tester) async {
      final env = await replaceEnv(tester);
      addTearDown(env.dispose);
      env.cloud.replaceError = const ApiException(
        statusCode: 403,
        code: 'FORBIDDEN',
        message: 'Geçersiz kurulum PIN kodu. Kalan deneme hakkı: 4',
      );
      await openReplace(tester, env);
      await tapKey(tester, 'btn_scan_new_board');
      await settle(tester);
      await tapKey(tester, 'btn_replace_submit');
      await settle(tester);
      await tapKey(tester, 'btn_replace_confirm');
      await settle(tester);

      expect(find.text('Geçersiz kurulum PIN kodu. Kalan deneme hakkı: 4'), findsOneWidget);
      TextField field(String key) => tester.widget<TextField>(find.descendant(of: find.byKey(Key(key)), matching: find.byType(TextField)));
      expect(field('field_new_pin').controller!.text, isEmpty);
      expect(field('field_new_uid').controller!.text, kNewUid);
    });

    group('sonucu belirsiz kesinti (değişim körlemesine tekrarlanmaz)', () {
      Future<ServiceHarness> submitWithError(WidgetTester tester, Object error) async {
        final env = await replaceEnv(tester);
        addTearDown(env.dispose);
        env.cloud.replaceError = error;
        await openReplace(tester, env);
        await tapKey(tester, 'btn_scan_new_board');
        await settle(tester);
        await tapKey(tester, 'btn_replace_submit');
        await settle(tester);
        await tapKey(tester, 'btn_replace_confirm');
        await settle(tester);
        return env;
      }

      testWidgets('ağ kesintisinde "sonuç belirsiz" denir, hata kutusu çıkmaz ve gönderim kilitlenir', (tester) async {
        final env = await submitWithError(tester, ApiException.network());
        expect(exists('replace_uncertain'), isTrue);
        expect(find.text('Değişimin sonucu belirsiz'), findsOneWidget);
        expect(find.textContaining('TAMAMLANMIŞ olabilir'), findsOneWidget);
        expect(exists('replace_error'), isFalse);
        expect(buttonEnabled(tester, 'btn_replace_submit'), isFalse, reason: 'durum kontrol edilmeden yinelenemez');
        expect(env.cloud.calls.where((c) => c.startsWith('replaceBoard')), hasLength(1));
        TextField field(String key) => tester.widget<TextField>(find.descendant(of: find.byKey(Key(key)), matching: find.byType(TextField)));
        expect(field('field_new_pin').controller!.text, isEmpty, reason: 'PIN ekranda bırakılmaz');
      });

      testWidgets('istemci zaman aşımı da belirsiz sayılır; yeni pano dairenin listesinde görünüyorsa değişim tamamlanmış kabul edilir', (tester) async {
        final env = await submitWithError(tester, TimeoutException('yanıt gelmedi'));
        expect(exists('replace_uncertain'), isTrue);

        // Sunucu işlemi aslında tamamlamış: yeni pano artık dairede.
        env.cloud.devicesByHome[kHomeA] = const <DeviceInfo>[DeviceInfo(deviceUuid: kNewUid, name: 'Yeni Pano', online: true)];
        await tapKey(tester, 'btn_replace_check');
        await settle(tester, frames: 20);

        expect(exists('replace_result_title'), isTrue);
        expect(exists('replace_uncertain'), isFalse);
        expect(find.textContaining('dairenin pano listesinde görünüyor'), findsOneWidget);
        expect(find.textContaining('Aktarılan kanal sayısı bilinmiyor'), findsOneWidget);
        expect(find.textContaining('0 kanal'), findsNothing, reason: 'bilinmeyen sayı "0" diye gösterilmez');
        expect(find.textContaining('aktarılan kanal sayısı ve uyarılar bilinmiyor'), findsOneWidget, reason: 'uyarı gösterilir');
        expect(exists('btn_replace_open_wizard'), isTrue, reason: 'kalan iş yeni panoyu bağlamaktır');
        expect(env.cloud.calls.where((c) => c.startsWith('replaceBoard')), hasLength(1), reason: 'istek yinelenmedi');
      });

      testWidgets('yeni pano listede yoksa değişim yapılmamış görünür; gönderim yeniden açılır', (tester) async {
        final env = await submitWithError(tester, ApiException.network());
        env.cloud.replaceError = null;
        await tapKey(tester, 'btn_replace_check');
        await settle(tester, frames: 20);

        expect(find.textContaining('listesinde görünmüyor: değişim yapılmamış görünüyor'), findsOneWidget);
        expect(exists('replace_result_title'), isFalse);
        expect(buttonEnabled(tester, 'btn_replace_submit'), isTrue);
        expect(env.cloud.replaceRequests, isEmpty, reason: 'kontrol işlem başlatmaz');
      });

      testWidgets('durum kontrolü de başarısız olursa ham istisna değil açıklama gösterilir ve kilit sürer', (tester) async {
        final env = await submitWithError(tester, ApiException.network());
        env.cloud.devicesError = ApiException.network();
        await tapKey(tester, 'btn_replace_check');
        await settle(tester, frames: 20);
        expect(find.textContaining('Durum kontrol edilemedi'), findsOneWidget);
        expect(find.textContaining('Exception'), findsNothing);
        expect(buttonEnabled(tester, 'btn_replace_submit'), isFalse);
      });
    });

    testWidgets('pencere açıkken aktif daire değişirse işlem engellenir (yanlış daire riski)', (tester) async {
      final env = await replaceEnv(tester);
      addTearDown(env.dispose);
      await openReplace(tester, env);
      await tapKey(tester, 'btn_scan_new_board');
      await settle(tester);

      final other = HomeModel(id: kHomeB, name: 'Başka Daire', role: 'service_user');
      env.cloud.homes = <HomeModel>[staffHome(), other];
      env.state.setHomesForTesting(<HomeModel>[staffHome(), other]);
      unawaited(env.state.selectHome(other));
      await settle(tester, frames: 30);
      expect(env.state.activeHome?.id, kHomeB);

      expect(exists('replace_home_changed'), isTrue);
      expect(buttonEnabled(tester, 'btn_replace_submit'), isFalse);
      expect(env.cloud.replaceRequests, isEmpty);
    });

    testWidgets('daire seçili değilse açıklayıcı mesaj gösterilir ve form açılmaz', (tester) async {
      final env = await replaceEnv(tester, withHome: false);
      addTearDown(env.dispose);
      await openReplace(tester, env);
      expect(exists('replace_no_home'), isTrue);
      expect(exists('field_new_uid'), isFalse);
    });

    testWidgets('yetkisiz ev rolünde (sakin) form yerine yetki mesajı gösterilir', (tester) async {
      final env = await replaceEnv(tester, homeRole: 'resident');
      addTearDown(env.dispose);
      await openReplace(tester, env);
      expect(exists('replace_forbidden'), isTrue);
      expect(exists('field_new_uid'), isFalse);
      expect(env.cloud.replaceRequests, isEmpty);
    });

    testWidgets('geçici servis oturumu (PIN) kendi dairesinde pano değiştirebilir', (tester) async {
      final env = await serviceHarness(role: 'pin', flush: () async {});
      addTearDown(env.dispose);
      await openReplace(tester, env);
      expect(exists('field_new_uid'), isTrue);
      expect(find.descendant(of: find.byKey(const Key('replace_target_home')), matching: find.text('Servis Evi')), findsOneWidget);
    });

    testWidgets('eski pano listesi yüklenemezse hata ve Tekrar dene gösterilir', (tester) async {
      final env = await replaceEnv(tester, devices: const <DeviceInfo>[]);
      addTearDown(env.dispose);
      env.cloud.devicesError = ApiException.network();
      await openReplace(tester, env);
      expect(exists('replace_devices_error'), isTrue);

      env.cloud.devicesError = null;
      env.cloud.devicesByHome[kHomeA] = const <DeviceInfo>[DeviceInfo(deviceUuid: kOldUid, online: true)];
      await tapKey(tester, 'btn_devices_retry');
      await settle(tester);
      expect(exists('replace_devices_error'), isFalse);
      expect(exists('card_oldboard_$kOldUid'), isTrue);
    });

    testWidgets('dairede hiç pano yoksa "değiştirilecek pano yok" denir ve gönderim kapalıdır', (tester) async {
      final env = await replaceEnv(tester, devices: const <DeviceInfo>[]);
      addTearDown(env.dispose);
      await openReplace(tester, env);
      expect(exists('replace_no_devices'), isTrue);
      expect(buttonEnabled(tester, 'btn_replace_submit'), isFalse);
    });
  });
}
