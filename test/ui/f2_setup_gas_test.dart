import 'package:ev_otomasyon/ui/pages/service_setup/setup_steps.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'f_flow_support.dart';
import 'f_support.dart';
import 'f_widget_support.dart';

/// Faz 2 WP-G2 (tasarım F2.A.3): sihirbazda dedektör bağlantı yönergesi, gaz vanası önerisi ve gaz vanalı bölge
/// testinden önce onay.
void main() {
  Future<ServiceHarness> open(WidgetTester tester) async {
    final env = await serviceHarness(flush: () async {});
    addTearDown(env.dispose);
    env.device.safetyCaps = true;
    await openWizardResumedAt(tester, env, SetupSteps.relays, size: const Size(900, 6000));
    await pumpUntil(tester, env, () => present('card_relay_5'), reason: 'röle listesi yüklenmedi');
    return env;
  }

  Finder inKey(String key, Finder matching) => find.descendant(of: find.byKey(Key(key)), matching: matching);

  Future<void> pickRole(WidgetTester tester, String input, String label) async {
    await tester.ensureVisible(find.byKey(Key('dd_role_$input')));
    await tester.tap(find.byKey(Key('dd_role_$input')));
    await settle(tester);
    await tester.tap(find.text(label).last);
    await settle(tester);
  }

  testWidgets('gaz/duman dedektörü rolü: bağlantı yönergesi (NC, arıza rölesi seri, ayrı besleme); butonda yok', (tester) async {
    await open(tester);
    expect(find.byKey(const Key('note_detector_d1')), findsNothing);
    await pickRole(tester, 'd1', 'Gaz dedektörü çıkışı');
    expect(find.byKey(const Key('note_detector_d1')), findsOneWidget);
    expect(inKey('note_detector_d1', find.textContaining('Dedektör bağlantısı')), findsOneWidget);
    expect(inKey('note_detector_d1', find.textContaining('alarm rölesini NC (normalde kapalı)')), findsOneWidget);
    expect(inKey('note_detector_d1', find.textContaining('arıza rölesi')), findsOneWidget);
    expect(inKey('note_detector_d1', find.textContaining('kendi besleme kaynağından')), findsOneWidget);

    await pickRole(tester, 'd1', 'Duman dedektörü çıkışı');
    expect(find.byKey(const Key('note_detector_d1')), findsOneWidget);
    await pickRole(tester, 'd1', 'Su sensörü');
    expect(find.byKey(const Key('note_detector_d1')), findsNothing);
  });

  testWidgets('gaz vanası: elle kurmalı vana önerisi', (tester) async {
    await open(tester);
    await tapKey(tester, 'chip_use_5_valve');
    await tapKey(tester, 'chip_medium_5_gas');
    expect(inKey('panel_valve_5', find.textContaining('Önerilen: elle kurmalı (manuel reset) gaz vanası')), findsOneWidget);
  });

  testWidgets('gaz vanalı bölge: kayıt+test öncesi onay; vazgeç -> panoya yazılmaz; onay -> yazılır', (tester) async {
    final env = await open(tester);
    await tapKey(tester, 'chip_use_5_valve');
    await tapKey(tester, 'chip_close_5_deenergize');
    await tapKey(tester, 'chip_medium_5_gas');
    expect(buttonEnabled(tester, 'btn_save_safety'), isTrue);

    await tapKey(tester, 'btn_save_safety');
    expect(find.textContaining('Test gaz vanasını kapatır.'), findsOneWidget);
    await tapKey(tester, 'btn_gas_test_cancel');
    expect(env.device.savedSafetyConfig, isNull, reason: 'vazgeçildi: panoya yazılmaz, test yok');

    await tapKey(tester, 'btn_save_safety');
    await tapKey(tester, 'btn_gas_test_confirm');
    await pumpUntil(tester, env, () => env.device.savedSafetyConfig != null, reason: 'plan yazılmadı');
  });

  testWidgets('gaz vanası yoksa onay sorulmaz (bugünkü akış)', (tester) async {
    final env = await open(tester);
    await tapKey(tester, 'chip_use_7_siren');
    await tapKey(tester, 'btn_save_safety');
    expect(find.byKey(const Key('btn_gas_test_cancel')), findsNothing);
    await pumpUntil(tester, env, () => present('safety_test_result_1'), reason: 'test sonucu gelmedi');
  });
}
