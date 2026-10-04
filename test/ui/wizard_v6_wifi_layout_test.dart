import 'package:ev_otomasyon/services/automation_api_service.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:ev_otomasyon/ui/common/wifi_provision_panel.dart';
import 'package:ev_otomasyon/ui/common/wifi_signal_bars.dart';
import 'package:ev_otomasyon/ui/pages/wifi_recovery_dialog.dart';
import 'package:ev_otomasyon/ui/theme/tokens.dart';
import 'package:ev_otomasyon/ui/widgets/orb/orb.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'e2_support.dart';
import 'e2_wifi_support.dart';

/// WP-V6 Wi-Fi paneli ve kurtarma diyaloğu yerleşim taraması: ağ listesi (sinyal çubukları + kilit), bağlanma beklemesi
/// (yay + geri sayım), başarı (orb ✓) ve hata durumları küçük ekran ve büyük yazıda (2.0x) taşma/çizim istisnası olmadan
/// çizilir. Akış davranışı (CONTRACTS §3d, başarı yalnız `success`) `wifi_recovery_mode_test.dart` içinde sınanır.

void _scale(WidgetTester tester, Size size, double scale) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}

Future<void> _pumpPanel(WidgetTester tester, E2Env env, FakeWifiDevice dev, {List<WifiConnectResult>? results}) async {
  await tester.pumpWidget(
    ChangeNotifierProvider<AutomationState>.value(
      value: env.state,
      child: MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: WifiProvisionPanel(
              api: dev.client(env.clock),
              clock: env.clock,
              expectedUid: kDeviceUid,
              onResult: results?.add,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

Future<void> _tap(WidgetTester tester, String key) async {
  final f = find.byKey(Key(key));
  await tester.ensureVisible(f);
  await tester.pump();
  await tester.tap(f, warnIfMissed: false);
  await tester.pump();
}

void main() {
  for (final config in <({Size size, double scale})>[
    (size: const Size(320, 568), scale: 2.0),
    (size: const Size(360, 640), scale: 2.0),
  ]) {
    group('WP-V6 Wi-Fi yerleşim ${config.size.width.toInt()}x${config.size.height.toInt()}, yazı ${config.scale}x', () {
      testWidgets('panel: bağlantı testi ✓ kartı, ağ listesi (sinyal çubukları), bekleme (yay + geri sayım), başarı', (
        tester,
      ) async {
        _scale(tester, config.size, config.scale);
        final env = e2Env(role: 'owner');
        final dev = FakeWifiDevice();
        final results = <WifiConnectResult>[];
        await _pumpPanel(tester, env, dev, results: results);
        expect(tester.takeException(), isNull, reason: 'boşta');

        await _tap(tester, 'btn_wifi_check');
        await advanceUntil(tester, env.clock, () => shown('wifi_network_list'));
        expect(tester.takeException(), isNull, reason: 'bağlantı kuruldu + ağ listesi');
        expect(find.byType(WifiSignalBars), findsNWidgets(3));
        final orb = tester.widget<OrbIconBadge>(find.byKey(const Key('wifi_connection_orb')));
        expect(orb.family, AppFamilies.emerald, reason: 'başarılı test yeşil orb ✓');

        await _tap(tester, 'wifi_network_0');
        await tester.enterText(find.byKey(const Key('field_wifi_password')), 'ev-wifi-sifre-1');
        await tester.pump();
        await _tap(tester, 'btn_wifi_submit');
        await advanceUntil(tester, env.clock, () => shown('wifi_waiting'), step: const Duration(milliseconds: 100));
        env.clock.advance(const Duration(seconds: 5));
        await tester.pump();
        expect(find.byKey(const Key('wifi_wait_countdown')), findsOneWidget);
        expect(tester.takeException(), isNull, reason: 'bağlanma bekleniyor');
        expect(find.byKey(const Key('wifi_result_success')), findsNothing, reason: 'başarı yalnız success ile');

        dev.connectState = 'success';
        await advanceUntil(tester, env.clock, () => shown('wifi_result_success'));
        expect(results.single.isSuccess, isTrue);
        expect(find.byKey(const Key('wifi_success_orb')), findsOneWidget);
        expect(tester.takeException(), isNull, reason: 'başarı kartı');
      });

      testWidgets('panel: bağlantı hatası ve yanlış parola (hata kartı) taşmaz; bekleme sayacı iptalde kalkar', (
        tester,
      ) async {
        _scale(tester, config.size, config.scale);
        final env = e2Env(role: 'owner');
        final dev = FakeWifiDevice()..statusDown = true;
        await _pumpPanel(tester, env, dev);
        await _tap(tester, 'btn_wifi_check');
        await tester.pump();
        expect(shown('wifi_check_error'), isTrue);
        expect(tester.takeException(), isNull, reason: 'pano bulunamadı');

        dev.statusDown = false;
        await _tap(tester, 'btn_wifi_check');
        await advanceUntil(tester, env.clock, () => shown('wifi_network_list'));
        await _tap(tester, 'wifi_network_0');
        await tester.enterText(find.byKey(const Key('field_wifi_password')), 'yanlis-parola-1');
        await tester.pump();
        await _tap(tester, 'btn_wifi_submit');
        await advanceUntil(tester, env.clock, () => shown('wifi_waiting'), step: const Duration(milliseconds: 100));
        await _tap(tester, 'btn_wifi_cancel');
        expect(shown('wifi_waiting'), isFalse, reason: 'iptal bekleme kartını kaldırır');
        expect(tester.takeException(), isNull, reason: 'bekleme iptal edildi');

        await _tap(tester, 'btn_wifi_submit');
        await advanceUntil(tester, env.clock, () => shown('wifi_waiting'), step: const Duration(milliseconds: 100));
        dev.connectState = 'failed';
        dev.connectReason = 202;
        await advanceUntil(tester, env.clock, () => shown('wifi_result_failed') || shown('wifi_result_uncertain'));
        expect(tester.takeException(), isNull, reason: 'yanlış parola sonucu');
      });

      testWidgets('kurtarma diyaloğu: adım 1 (kopyalanabilir parola) -> ağ listesi -> tamamlandı taşmaz', (tester) async {
        _scale(tester, config.size, config.scale);
        final env = e2Env(role: null, authenticated: false);
        final dev = FakeWifiDevice();
        await openFromHost<void>(
          tester,
          env.state,
          (context) => WifiRecoveryDialog.show(context, api: dev.client(env.clock), deviceUuid: kDeviceUid),
          size: config.size,
        );
        expect(shown('wifi_dialog_title'), isTrue);
        expect(tester.takeException(), isNull, reason: 'adım 1');

        await tester.enterText(find.byKey(const Key('field_ap_password')), 'etiket-parolasi-77');
        await tester.pump();
        await _tap(tester, 'btn_wifi_check');
        await advanceUntil(tester, env.clock, () => shown('wifi_network_list'));
        expect(tester.takeException(), isNull, reason: 'ağ listesi');

        await _tap(tester, 'wifi_network_0');
        await tester.enterText(find.byKey(const Key('field_wifi_password')), 'ev-wifi-sifre-1');
        await tester.pump();
        await _tap(tester, 'btn_wifi_submit');
        dev.connectState = 'success';
        await advanceUntil(tester, env.clock, () => shown('btn_wifi_done'));
        expect(tester.takeException(), isNull, reason: 'tamamlandı');
      });
    });
  }
}
