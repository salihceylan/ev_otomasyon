import 'package:ev_otomasyon/ui/pages/service_setup/setup_steps.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'f_flow_support.dart';
import 'f_support.dart';
import 'f_widget_support.dart';

/// WP-A4 (arayüz): Adım 7 röle kartında "Bu kanala ne bağlı?", vana soruları, K4 parlaklık sorusu + dimmer yönergesi,
/// girişler ve sensörler bölümü, panoya yazma düğmesi.
void main() {
  Future<ServiceHarness> open(
    WidgetTester tester, {
    bool safety = true,
    bool bridge = false,
    List<Map<String, dynamic>> sensors = const <Map<String, dynamic>>[],
  }) async {
    final env = await serviceHarness(flush: () async {});
    addTearDown(env.dispose);
    env.device.safetyCaps = safety;
    env.device.bridgeCaps = bridge;
    env.device.boardSensors.addAll(sensors);
    await openWizardResumedAt(tester, env, SetupSteps.relays, size: const Size(900, 6000));
    await pumpUntil(tester, env, () => present('card_relay_5'), reason: 'röle listesi yüklenmedi');
    return env;
  }

  Finder inKey(String key, Finder matching) => find.descendant(of: find.byKey(Key(key)), matching: matching);

  testWidgets('"Bu kanala ne bağlı?" -> Vana: kapanma kipi, akışkan, sürüş ve bölge soruları; eksikken kayıt kapalı', (tester) async {
    await open(tester);
    expect(inKey('card_relay_5', find.text('Bu kanala ne bağlı?')), findsOneWidget);
    expect(find.byKey(const Key('panel_valve_5')), findsNothing);

    await tapKey(tester, 'chip_use_5_valve');
    expect(find.byKey(const Key('panel_valve_5')), findsOneWidget);
    expect(inKey('panel_valve_5', find.textContaining('rölede enerji varken mi kapalı')), findsOneWidget);
    expect(inKey('panel_valve_5', find.textContaining('neyi kesiyor')), findsOneWidget);
    expect(inKey('panel_valve_5', find.textContaining('NC) selenoid')), findsOneWidget, reason: 'fail-safe önerisi');
    expect(buttonEnabled(tester, 'btn_save_safety'), isFalse, reason: 'kapanma kipi ve akışkan seçilmedi');
    expect(inKey('card_relay_5', find.textContaining('Su ya da Gaz')), findsOneWidget, reason: 'eksik bilgi kartta yazılı');

    await tapKey(tester, 'chip_close_5_deenergize');
    await tapKey(tester, 'chip_medium_5_gas');
    expect(inKey('panel_valve_5', find.textContaining('yalnız yerinde')), findsWidgets, reason: 'gaz vanası notu');
    await tapKey(tester, 'chip_drive_5_dual');
    expect(find.byKey(const Key('dd_open_relay_5')), findsOneWidget);
    await tapKey(tester, 'chip_zone_5_2');
    expect(find.textContaining('açma rölesini seçin'), findsWidgets);
  });

  testWidgets('K4: lamba için parlaklık sorusu; "Evet" dimmer yönergesini doldurulmuş yer tutucularla gösterir', (tester) async {
    await open(tester);
    expect(inKey('card_relay_6', find.text('Bu lambanın parlaklığı ayarlanacak mı?')), findsOneWidget);
    expect(find.byKey(const Key('panel_dimmer_6')), findsNothing, reason: 'varsayılan yanıt Hayır');
    await tapKey(tester, 'chip_dim_6_yes');
    final panel = find.byKey(const Key('panel_dimmer_6'));
    expect(panel, findsOneWidget);
    expect(inKey('panel_dimmer_6', find.textContaining('Bu kanal için dimmer gerekiyor')), findsOneWidget);
    expect(inKey('panel_dimmer_6', find.textContaining('adresini 2 yapın')), findsOneWidget);
    expect(inKey('panel_dimmer_6', find.textContaining('Röle 6 yerine dimmer modülünün Çıkış 1 ucuna')), findsOneWidget);
    expect(inKey('panel_dimmer_6', find.textContaining('%N parlaklık yerine "aç"')), findsOneWidget);
    // Vana seçilince parlaklık sorusu kalkar (yalnız lamba).
    await tapKey(tester, 'chip_use_6_siren');
    expect(find.byKey(const Key('panel_dimmer_6')), findsNothing);
    expect(inKey('card_relay_6', find.text('Bu lambanın parlaklığı ayarlanacak mı?')), findsNothing);
  });

  testWidgets('fw-tarama-1 (C1): caps "bridge" yoksa "Kablosuz sensör ekle" gösterilmez; varsa gösterilir', (tester) async {
    await open(tester);
    expect(find.byKey(const Key('card_inputs')), findsOneWidget);
    expect(find.byKey(const Key('btn_add_bridge')), findsNothing);
    expect(find.text('Kablosuz sensör ekle'), findsNothing);
  });

  testWidgets('fw-tarama-1 (C1): desteklemeyen panodaki kayıtlı kablosuz sensör uyarıyla gösterilir ve kaldırılabilir',
      (tester) async {
    await open(tester, sensors: <Map<String, dynamic>>[
      <String, dynamic>{'id': 'b1', 'src': 'bridge', 'kind': 'water', 'zone': 1, 'active': false, 'ok': false},
    ]);
    expect(find.byKey(const Key('input_b1')), findsOneWidget);
    expect(inKey('input_b1', find.text('Bu panoda kablosuz sensör desteklenmiyor; kaldırın.')), findsOneWidget);
    await tapKey(tester, 'chip_use_7_siren');
    expect(buttonEnabled(tester, 'btn_save_safety'), isFalse, reason: 'kablosuz sensör kaldırılmadan plan yazılamaz');
    await tapKey(tester, 'btn_remove_bridge_1');
    expect(find.byKey(const Key('input_b1')), findsNothing);
    expect(find.byKey(const Key('btn_add_bridge')), findsNothing);
    expect(buttonEnabled(tester, 'btn_save_safety'), isTrue);
  });

  testWidgets('fw-tarama-1 (C1): kaldırılan kayıtlı kablosuz sensör panodan silinir ve plan yazılır', (tester) async {
    // v1.3.2: köprü sensörü tabloda kaldıkça silme dışındaki her yama sensor_bridge_unsupported ile reddedilir.
    final env = await open(tester, sensors: <Map<String, dynamic>>[
      <String, dynamic>{'id': 'b1', 'src': 'bridge', 'kind': 'water', 'zone': 1, 'active': false, 'ok': false},
    ]);
    env.device.savedSafetyConfig = <String, dynamic>{
      'sensors': <Map<String, dynamic>>[
        <String, dynamic>{'id': 'b1', 'kind': 'water', 'zone': 1, 'nc': 0, 'confirm_ms': 2000, 'flags': 0},
      ],
      'actuators': <Map<String, dynamic>>[],
      'lights': <Map<String, dynamic>>[],
    };
    await tapKey(tester, 'chip_use_7_siren');
    await tapKey(tester, 'btn_remove_bridge_1');
    expect(buttonEnabled(tester, 'btn_save_safety'), isTrue);
    await tapKey(tester, 'btn_save_safety');
    await pumpUntil(tester, env, () => present('safety_test_result_1'), reason: 'plan yazılmadı');
    expect(env.device.safetyPatches.first['del'], <String, dynamic>{'sensor': 'b1'}, reason: 'silme ilk yama');
    final sensors = (env.device.savedSafetyConfig!['sensors'] as List).cast<Map<String, dynamic>>();
    expect(sensors.where((s) => '${s['id']}'.startsWith('b')), isEmpty);
  });

  testWidgets('Girişler ve Sensörler: DI satırları, kablosuz sensör ekleme ve kaldırma, su sensörü NO uyarısı', (tester) async {
    await open(tester, bridge: true);
    expect(find.byKey(const Key('card_inputs')), findsOneWidget);
    for (final id in <String>['d1', 'd2', 'd3', 'd4']) {
      expect(find.byKey(Key('input_$id')), findsOneWidget);
    }
    await tapKey(tester, 'btn_add_bridge');
    expect(find.byKey(const Key('input_b1')), findsOneWidget);
    expect(inKey('input_b1', find.text('Kablosuz sensör 1')), findsOneWidget);
    // Su sensörü NO -> uyarı; NC seçilince kalkar.
    expect(inKey('input_b1', find.textContaining('Kablo koparsa')), findsOneWidget);
    await tapKey(tester, 'chip_contact_b1_nc');
    expect(inKey('input_b1', find.textContaining('Kablo koparsa')), findsNothing);

    await tapKey(tester, 'btn_remove_bridge_1');
    expect(find.byKey(const Key('input_b1')), findsNothing);
  });

  testWidgets('eski pano: güvenlik cihazı seçilince "v1.2.0\'a güncelleyin" notu, kayıt düğmesi kapalı', (tester) async {
    await open(tester, safety: false);
    await tapKey(tester, 'chip_use_5_siren');
    expect(find.textContaining("v1.2.0'a güncelleyin"), findsWidgets);
    expect(buttonEnabled(tester, 'btn_save_safety'), isFalse);
  });

  testWidgets('kayıt: plan panoya yazılır, bölge testi sonucu ekranda', (tester) async {
    final env = await open(tester);
    env.device.testResultFbMs = 4200;
    await tapKey(tester, 'chip_use_7_siren');
    expect(buttonEnabled(tester, 'btn_save_safety'), isTrue);
    await tapKey(tester, 'btn_save_safety');
    await pumpUntil(tester, env, () => present('safety_test_result_1'), reason: 'test sonucu gelmedi');
    expect(env.device.savedSafetyConfig, isNotNull);
    expect(find.byKey(const Key('safety_test_result_1')), findsOneWidget);
    expect(buttonEnabled(tester, 'btn_save_safety'), isFalse, reason: 'değişiklik kalmadı');
  });
}
