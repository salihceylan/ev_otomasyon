@Tags(['visual'])
library;

// Wi-Fi paneli, kurtarma diyaloğu ve sihirbaz bileşenleri (gizli değer satırı, oturum bandı, durum rozetleri, hata
// kutusu) görsel galerisi (WP-V6).
//
//   flutter test --tags visual --update-goldens test/visual/wizard
//   AHBU_VISUAL=1 flutter test --tags visual test/visual/wizard
//
// Koyu + açık, yazı ölçeği 1.0 + 1.5, 360 dp telefon genişliği. MotionScope(full) + AmbientClock.fixed.

import 'dart:async';

import 'package:ev_otomasyon/services/automation_api_service.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:ev_otomasyon/ui/common/wifi_provision_panel.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/secret_value_row.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/service_setup_controller.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/session_banner.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/setup_problem.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/setup_widgets.dart';
import 'package:ev_otomasyon/ui/pages/wifi_recovery_dialog.dart';
import 'package:ev_otomasyon/ui/theme/tokens.dart';
import 'package:ev_otomasyon/ui/widgets/surface_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../../ui/e2_support.dart' hide settle;
import '../../ui/e2_wifi_support.dart';
import '../../ui/f_support.dart' show ServiceHarness, serviceHarness;
import '../support/golden_support.dart';
import 'wizard_support.dart';

Size _phone(double scale, {double h = 900}) => Size(360, scale > 1 ? h * 1.4 : h);

Future<void> _wait(WidgetTester tester, [int frames = 8]) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
}

Future<void> _tap(WidgetTester tester, String key) async {
  final f = find.byKey(Key(key));
  await tester.ensureVisible(f);
  await tester.pump();
  await tester.tap(f, warnIfMissed: false);
}

Future<void> _shot(WidgetTester tester, GlobalKey key, String name, double scale) async {
  await _wait(tester);
  await expectGolden(tester, key, name, pixelRatio: scale > 1 ? 1.0 : 1.5);
}

/// Diyalog kaydırmasını başa alır (çekimde başlık ve kapat düğmesi karede olsun: `ensureVisible` diyaloğu aşağı kaydırıyordu).
Future<void> _dialogToTop(WidgetTester tester) async {
  for (final element in find.descendant(of: find.byType(Dialog), matching: find.byType(Scrollable)).evaluate()) {
    final state = (element as StatefulElement).state as ScrollableState;
    if (state.position.axis == Axis.vertical) state.position.jumpTo(0);
  }
  await tester.pump();
}

Widget _panelPage(E2Env env, FakeWifiDevice dev, {List<WifiConnectResult>? results, Duration? timeout}) {
  return ChangeNotifierProvider<AutomationState>.value(
    value: env.state,
    child: Material(
      type: MaterialType.transparency,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        // Üretimde panel kartsız durmaz: sihirbazda `SetupCard`, kurtarmada diyalog yüzeyi içindedir. Kartsız çizim saydam
        // çerçeveli düğmelerin ve pasif cam hapların içinden devre izlerini/silkscreen'i gösteriyor, iskelet satırlarını doğrudan
        // PCB üstüne çiziyordu (2. tur eleştirmen bulgusu, harness artefaktı): sihirbazdaki gibi kart içinde çizilir.
        child: SurfaceCard(
          margin: EdgeInsets.zero,
          padding: const EdgeInsets.all(AppSpace.s16),
          child: WifiProvisionPanel(
            api: dev.client(env.clock),
            clock: env.clock,
            numberedSteps: false,
            expectedUid: kDeviceUid,
            connectTimeout: timeout ?? const Duration(seconds: 40),
            onResult: results?.add,
          ),
        ),
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Wi-Fi paneli, kurtarma diyaloğu ve sihirbaz bileşenleri galerisi', () {
    setUpAll(() async {
      await loadGoldenFonts();
      await loadWizardGalleryExtras();
    });

    for (final brightness in [Brightness.dark, Brightness.light]) {
      for (final scale in [1.0, 1.5]) {
        final tag = '${brightness.name}_$scale';

        testWidgets('Wi-Fi paneli: boşta, tarama, ağ listesi, bekleme, başarı, hata ($tag)', (tester) async {
          final key = GlobalKey();
          final env = e2Env(role: 'owner');
          final dev = FakeWifiDevice()..scanningFirst = 2;
          final results = <WifiConnectResult>[];
          await pumpGallery(
            tester,
            boundaryKey: key,
            brightness: brightness,
            textScale: scale,
            realBackground: true,
            size: _phone(scale, h: 980),
            child: _panelPage(env, dev, results: results),
          );
          await _shot(tester, key, 'wifi_panel_idle_$tag.png', scale);

          await _tap(tester, 'btn_wifi_check');
          await tester.pump();
          await advanceUntil(tester, env.clock, () => shown('wifi_scan_skeleton'), step: const Duration(milliseconds: 100));
          await _shot(tester, key, 'wifi_panel_scanning_$tag.png', scale);

          await advanceUntil(tester, env.clock, () => shown('wifi_network_list'));
          await _tap(tester, 'wifi_network_0');
          await tester.pump();
          await tester.enterText(find.byKey(const Key('field_wifi_password')), 'ev-wifi-sifre-1');
          await tester.pump();
          await _shot(tester, key, 'wifi_panel_networks_$tag.png', scale);

          // Bekleme: pano bağlanıyor (geri sayım + dönen yay).
          await _tap(tester, 'btn_wifi_submit');
          await tester.pump();
          await advanceUntil(tester, env.clock, () => shown('wifi_waiting'), step: const Duration(milliseconds: 100));
          env.clock.advance(const Duration(seconds: 7));
          await tester.pump();
          await _shot(tester, key, 'wifi_panel_waiting_$tag.png', scale);

          // Başarı YALNIZ pano gerçekten bağlandığında.
          dev.connectState = 'success';
          await advanceUntil(tester, env.clock, () => shown('wifi_result_success'));
          expect(results.single.isSuccess, isTrue);
          await _shot(tester, key, 'wifi_panel_success_$tag.png', scale);
          expect(tester.takeException(), isNull);
        });

        testWidgets('Wi-Fi paneli: bağlantı hatası ve yanlış parola ($tag)', (tester) async {
          final key = GlobalKey();
          final env = e2Env(role: 'owner');
          final dev = FakeWifiDevice()..statusDown = true;
          await pumpGallery(
            tester,
            boundaryKey: key,
            brightness: brightness,
            textScale: scale,
            realBackground: true,
            size: _phone(scale, h: 1060),
            child: _panelPage(env, dev),
          );
          await _tap(tester, 'btn_wifi_check');
          await tester.pump();
          await tester.pump();
          await _shot(tester, key, 'wifi_panel_check_error_$tag.png', scale);

          dev.statusDown = false;
          await _tap(tester, 'btn_wifi_check');
          await tester.pump();
          await advanceUntil(tester, env.clock, () => shown('wifi_network_list'));
          await _tap(tester, 'wifi_network_0');
          await tester.pump();
          await tester.enterText(find.byKey(const Key('field_wifi_password')), 'yanlis-parola-1');
          await tester.pump();
          await _tap(tester, 'btn_wifi_submit');
          await tester.pump();
          dev.connectState = 'failed';
          dev.connectReason = 202; // kimlik doğrulama hatası (yanlış parola)
          await advanceUntil(tester, env.clock, () => shown('wifi_result_failed') || shown('wifi_result_uncertain'));
          await _shot(tester, key, 'wifi_panel_failed_$tag.png', scale);
          expect(tester.takeException(), isNull);
        });

        testWidgets('Wi-Fi kurtarma diyaloğu: adım 1, ağ listesi, tamamlandı ($tag)', (tester) async {
          final key = GlobalKey();
          final hostKey = GlobalKey();
          final env = e2Env(role: null, authenticated: false);
          final dev = FakeWifiDevice();
          await pumpGallery(
            tester,
            boundaryKey: key,
            brightness: brightness,
            textScale: scale,
            realBackground: true,
            // Tuval diyalogun tamamını alacak kadar yüksek (1.5 ölçekte ≈ 2400 dp): kaydırma çıkmaz, başlık/kapat karede kalır.
            size: Size(360, scale > 1 ? 2520 : 1500),
            child: ChangeNotifierProvider<AutomationState>.value(
              value: env.state,
              child: Builder(key: hostKey, builder: (_) => const SizedBox.shrink()),
            ),
          );
          // GERÇEK akış: `showDialog` (modal perde ve diyalog rotası PNG'ye girer). Eskiden diyalog düz widget olarak Center içinde
          // çiziliyor, perde yoktu ve yüzey/perde kontrastı üretimi temsil etmiyordu (harness artefaktı).
          unawaited(WifiRecoveryDialog.show(hostKey.currentContext!, api: dev.client(env.clock), deviceUuid: kDeviceUid));
          await _wait(tester);
          await _shot(tester, key, 'recovery_dialog_step1_$tag.png', scale);

          await tester.enterText(find.byKey(const Key('field_ap_password')), 'etiket-parolasi-77');
          await tester.pump();
          await _tap(tester, 'btn_wifi_check');
          await tester.pump();
          await advanceUntil(tester, env.clock, () => shown('wifi_network_list'));
          await _tap(tester, 'wifi_network_1');
          await tester.pump();
          await _dialogToTop(tester);
          await _shot(tester, key, 'recovery_dialog_networks_$tag.png', scale);

          await _tap(tester, 'wifi_network_0');
          await tester.pump();
          await tester.enterText(find.byKey(const Key('field_wifi_password')), 'ev-wifi-sifre-1');
          await tester.pump();
          await _tap(tester, 'btn_wifi_submit');
          await tester.pump();
          dev.connectState = 'success';
          await advanceUntil(tester, env.clock, () => shown('btn_wifi_done'));
          await _dialogToTop(tester);
          await _shot(tester, key, 'recovery_dialog_done_$tag.png', scale);
          expect(tester.takeException(), isNull);
        });

        testWidgets('Sihirbaz bileşenleri: rozetler, hata kutusu, gizli değer, oturum bandı ($tag)', (tester) async {
          final key = GlobalKey();
          final ServiceHarness env = await serviceHarness(role: 'pin', flush: () async {});
          addTearDown(env.dispose);
          await pumpGallery(
            tester,
            boundaryKey: key,
            brightness: brightness,
            textScale: scale,
            realBackground: true,
            size: _phone(scale, h: 1300),
            child: ChangeNotifierProvider<AutomationState>.value(
              value: env.state,
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        SetupStatusBadge(phase: StepPhase.pending),
                        SetupStatusBadge(phase: StepPhase.working),
                        SetupStatusBadge(phase: StepPhase.done),
                        SetupStatusBadge(phase: StepPhase.failed),
                        SetupStatusBadge(phase: StepPhase.skipped),
                      ],
                    ),
                    const ServiceSessionBanner(),
                    SetupProblemBox(
                      problem: SetupProblems.fromError(LocalApiException.network(), step: 7),
                      onRetry: () {},
                    ),
                    const SetupProblemBox(
                      problem: SetupProblem(
                        kind: SetupProblemKind.locked,
                        title: 'Cihaz geçici olarak kilitlendi',
                        why: 'Çok sayıda hatalı PIN denemesi yapıldı.',
                        todo: 'Yaklaşık 2 dakika bekleyin.',
                        retryAfter: Duration(minutes: 2),
                        fixStep: 2,
                      ),
                    ),
                    SetupCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const SetupInfoRow(icon: Icons.lock_rounded, text: 'Tek seferlik değerler (örnek):'),
                          SecretValueRow(
                            label: 'Kurulum PIN\'i',
                            shown: '705 318',
                            copyKey: const Key('copy_a'),
                            onCopy: () {},
                          ),
                          SecretValueRow(
                            label: 'Cihaz anahtarı',
                            shown: 'yeni-yerel-anahtar-9988',
                            copyKey: const Key('copy_b'),
                            onCopy: () {},
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
          await tester.tap(find.byKey(const Key('copy_b')));
          await tester.pump();
          await tester.pump(const Duration(seconds: 12));
          await _shot(tester, key, 'components_$tag.png', scale);

          // Oturum bandı: 2 dakikadan az kalınca uyarı (kırmızı halka kısa).
          env.clock.advance(const Duration(hours: 1, minutes: 58, seconds: 30));
          await tester.pump(const Duration(seconds: 1));
          await _shot(tester, key, 'components_session_low_$tag.png', scale);
          expect(tester.takeException(), isNull);
        });
      }
    }
  }, skip: visualSkipReason);
}
