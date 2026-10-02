import 'package:ev_otomasyon/services/automation_api_service.dart';
import 'package:ev_otomasyon/services/board_network_binding.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/service_setup_wizard_page.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/service_target.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/setup_problem.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/setup_steps.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'f_support.dart';
import 'f_widget_support.dart';

/// Servis kurulum sihirbazı 5. adım + pano ağına yönlenme (Android; WP-NET): yönergenin yumuşatılması ve
/// bağlama başarısızken hata kutusuna eklenen ipucu. Bağlama SAHTE (`FakeBoardNetworkBinding`); gerçek Android
/// cihazda DOĞRULANMADI.
const String _hintNotOnNetwork =
    'Telefon pano kurulum ağına (AHBU-…) bağlı görünmüyor: Wi-Fi ayarlarından panonun ağına bağlanın.';
const String _hintNoRoute = 'Pano ağına yönlenme kurulamadı: mobil veriyi kapatıp yeniden deneyin.';

LocalApiException _networkError({String? hint}) => LocalApiException(
      statusCode: 0,
      code: 'network',
      message: 'Cihaza ulaşılamadı.${hint == null ? '' : ' $hint'}',
      hint: hint,
    );

Future<void> _openStep5(WidgetTester tester, ServiceHarness env) async {
  tester.view.physicalSize = const Size(900, 3200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await pumpLauncher(tester, env, (context) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => ServiceSetupWizardPage(
          existingTarget: ServiceTarget(homeId: kClaimedHome, deviceUuid: kDeviceUid, homeName: 'Daire 5', ip: ''),
          startStep: SetupSteps.wifi,
          store: env.store,
          deviceApiFactory: env.deviceFactory,
          scanner: fakeScanner(kWifiQr),
        ),
      ),
    );
  });
  await tester.tap(find.byKey(const Key('launcher')));
  await tester.pump();
  await settle(tester, frames: 25);
  await pumpUntil(tester, env, () => present('setup_step_${SetupSteps.wifi}'), reason: 'başlangıç adımı açılmadı');
}

Future<ServiceHarness> _wifiEnv() async {
  final env = await serviceHarness(flush: () async {});
  env.cloud.seedClaimed();
  env.phoneOnSetupNetwork(); // internet yok
  return env;
}

void main() {
  late FakeBoardNetworkBinding fake;

  setUp(() {
    fake = FakeBoardNetworkBinding();
    BoardNetworkBinding.overrideForTesting(fake);
  });

  tearDown(() => BoardNetworkBinding.overrideForTesting(null));

  group('SetupProblem.fromError: ağ hatası + pano ağına yönlenme ipucu', () {
    test('5. adım: ipucu "Neden" metnine eklenir; "Ne yapmalıyım" yalnız yedek cümleyi söyler (ön bilgiyle ÇELİŞMEZ)', () {
      fake.supported = true;
      final problem = SetupProblems.fromError(_networkError(hint: _hintNoRoute), step: 5);
      expect(problem.kind, SetupProblemKind.deviceNetwork);
      expect(problem.why, 'Telefonunuz panoyla aynı ağda değil, adres yanlış ya da pano kapalı. $_hintNoRoute');
      // Hata kutusunda "Mobil veri açık kalabilir..." ön bilgisi YOK: az önce başarısız olmuş bağlantının yanında,
      // "Neden?" satırındaki "mobil veriyi kapatıp yeniden deneyin" ipucuyla çelişirdi.
      expect(problem.todo, contains(BoardNetworkBinding.mobileDataFallback));
      expect(problem.todo, isNot(contains('Mobil veri açık kalabilir')), reason: 'ön bilgi yalnız bilgi kartında');
      expect(problem.todo, isNot(contains(BoardNetworkBinding.mobileDataAdvice)));
      expect(problem.todo, isNot(contains('geçici olarak kapatın')), reason: 'eski "kapatın" yönergesi yumuşatıldı');
      expect(problem.todo, startsWith('Telefonunuzun Wi-Fi ayarlarını açıp panonun kurulum ağına (AHBU-...)'));
    });

    test('5. adım: "pano ağına bağlı değil" ipucu ile de Neden/Ne yapmalıyım tutarlı', () {
      fake.supported = true;
      final problem = SetupProblems.fromError(_networkError(hint: _hintNotOnNetwork), step: 5);
      expect(problem.why, endsWith(_hintNotOnNetwork));
      expect(problem.todo, endsWith(BoardNetworkBinding.mobileDataFallback));
    });

    test('ipucu yoksa "Neden" metni değişmez', () {
      final problem = SetupProblems.fromError(_networkError(), step: 5);
      expect(problem.why, 'Telefonunuz panoyla aynı ağda değil, adres yanlış ya da pano kapalı.');
    });

    test('Android dışı: 5. adım yönergesi eski metin AYNEN', () {
      fake.supported = false;
      final problem = SetupProblems.fromError(_networkError(hint: _hintNoRoute), step: 5);
      expect(problem.todo, contains('Mobil veri açıksa geçici olarak kapatın, sonra "Tekrar dene"ye basın.'));
      expect(problem.todo, isNot(contains('Mobil veri açık kalabilir')));
    });

    test('ev ağı adımları (6+) bağlamadan etkilenmez: ev Wi-Fi yönergesi aynı', () {
      fake.supported = true;
      final problem = SetupProblems.fromError(_networkError(), step: 6);
      expect(problem.todo, startsWith('Telefonunuzun, panonun bağlı olduğu ev Wi-Fi ağında olduğundan emin olun.'));
      expect(problem.todo, isNot(contains('Mobil veri')));
    });
  });

  group('5. adım arayüzü', () {
    testWidgets('mobil veri notu: Android\'de "açık kalabilir"; diğer platformlarda eski yönerge', (tester) async {
      fake.supported = true;
      final env = await _wifiEnv();
      addTearDown(env.dispose);
      await _openStep5(tester, env);
      expect(find.byKey(const Key('wifi_mobile_data_note')), findsOneWidget);
      expect((tester.widget(find.byKey(const Key('wifi_mobile_data_note'))) as Text).data, BoardNetworkBinding.mobileDataAdvice);
    });

    testWidgets('mobil veri notu (bağlama yok): eski yönerge AYNEN', (tester) async {
      fake.supported = false;
      final env = await _wifiEnv();
      addTearDown(env.dispose);
      await _openStep5(tester, env);
      expect(
        (tester.widget(find.byKey(const Key('wifi_mobile_data_note'))) as Text).data,
        'Mobil veri açıksa ve telefon panoya ulaşamıyorsa mobil veriyi geçici olarak kapatın.',
      );
    });

    testWidgets('panoya ulaşılamayınca (telefon pano ağında değil) hata kutusu ipucunu gösterir; kira bırakılır', (tester) async {
      fake.status = BoardNetworkStatus.notOnBoardNetwork;
      final env = await _wifiEnv();
      addTearDown(env.dispose);
      env.device.apReachable = false; // telefon pano ağında değil: AP adresi yanıt vermiyor
      await _openStep5(tester, env);

      await tapKey(tester, 'btn_check_device');
      await pumpUntil(tester, env, () => find.text('Panoya ulaşılamadı').evaluate().isNotEmpty);
      expect(find.textContaining(_hintNotOnNetwork), findsOneWidget, reason: 'ipucu "Neden?" satırında');
      expect(find.textContaining('Exception'), findsNothing, reason: 'ham teknik hata metni gösterilmez');
      expect(fake.hosts, isNotEmpty);
      expect(fake.hosts.toSet(), <String>{'192.168.4.1'});
      expect(fake.activeLeases, 0);
    });

    testWidgets('bağlama BAŞARILI iken aynı hata ipucusuz gelir', (tester) async {
      fake.status = BoardNetworkStatus.bound;
      final env = await _wifiEnv();
      addTearDown(env.dispose);
      env.device.apReachable = false;
      await _openStep5(tester, env);

      await tapKey(tester, 'btn_check_device');
      await pumpUntil(tester, env, () => find.text('Panoya ulaşılamadı').evaluate().isNotEmpty);
      expect(find.textContaining('AHBU-…'), findsNothing);
      expect(find.textContaining('yönlenme'), findsNothing);
      expect(fake.activeLeases, 0);
    });

    testWidgets('pano ağındayken adım normal ilerler: kimlik doğrulanır, kira bırakılır, bulut çağrısı yok', (tester) async {
      final env = await _wifiEnv();
      addTearDown(env.dispose);
      await _openStep5(tester, env);

      await tapKey(tester, 'btn_check_device');
      await pumpUntil(tester, env, () => present('wifi_provision_panel'));
      await pumpUntil(tester, env, () => present('wifi_network_list'));
      expect(fake.acquireCount, greaterThanOrEqualTo(2));
      expect(fake.activeLeases, 0);
      expect(fake.hosts.toSet(), <String>{'192.168.4.1'});
      expect(env.cloud.calls.where((c) => c.startsWith('localKey')), isEmpty);
    });
  });
}
