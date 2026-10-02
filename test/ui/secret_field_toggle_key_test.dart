import 'package:ev_otomasyon/ui/pages/service_setup/setup_fields.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Anahtar sözleşmesi: gizli değer alanının (`SecretField`) göz düğmesi de test anahtarı taşır.
/// Anahtar, alanın `field_<ad>` anahtarından türetilir: `btn_secret_toggle_<ad>`.
void main() {
  Future<TextEditingController> pumpField(WidgetTester tester, {Key? fieldKey}) async {
    final controller = TextEditingController(text: 'gizli-deger');
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SecretField(key: fieldKey, controller: controller, label: 'Gizli alan'),
        ),
      ),
    );
    return controller;
  }

  bool obscured(WidgetTester tester) => tester.widget<TextField>(find.byType(TextField)).obscureText;

  testWidgets('field_<ad> anahtarlı alanın göz düğmesi btn_secret_toggle_<ad> anahtarını taşır ve değeri açıp kapatır', (tester) async {
    await pumpField(tester, fieldKey: const Key('field_demo_pass'));

    final toggle = find.byKey(const Key('btn_secret_toggle_demo_pass'));
    expect(toggle, findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('field_demo_pass')), matching: toggle), findsOneWidget);
    expect(obscured(tester), isTrue, reason: 'varsayılan: gizli');

    await tester.tap(toggle);
    await tester.pump();
    expect(obscured(tester), isFalse);

    await tester.tap(toggle);
    await tester.pump();
    expect(obscured(tester), isTrue);
  });

  testWidgets('anahtarsız ya da field_ önekli olmayan anahtarlı alanda düğme anahtarsızdır ama çalışır (istisna yok)', (tester) async {
    for (final key in <Key?>[null, const Key('baska_ad'), const ValueKey<int>(7)]) {
      await pumpField(tester, fieldKey: key);

      final button = tester.widget<IconButton>(find.byType(IconButton));
      expect(button.key, isNull, reason: 'anahtar türetilemez: $key');
      expect(obscured(tester), isTrue);

      await tester.tap(find.byType(IconButton));
      await tester.pump();
      expect(obscured(tester), isFalse);
      expect(tester.takeException(), isNull);
    }
  });
}
