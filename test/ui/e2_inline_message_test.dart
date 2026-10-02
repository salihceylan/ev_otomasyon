import 'package:ev_otomasyon/ui/common/inline_message.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/support.dart';
import 'e2_support.dart';

/// `InlineMessage` yerleşimi: eylem (trailing) düğmesi sığıyorsa mesajla aynı satırda sağdadır; sığmıyorsa
/// (dar ekran, büyük yazı, uzun etiket) mesajın ALTINA iner. Eskiden `Row` içindeki sınırsız genişlikli
/// düğme bu durumlarda "RenderFlex overflowed" üretiyordu (Wi-Fi sihirbazı hata kutuları).
void main() {
  Future<void> pumpMessage(
    WidgetTester tester, {
    required double width,
    required String message,
    required String label,
    double textScale = 1.0,
  }) async {
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.platformDispatcher.clearAllTestValues);
    final env = e2Env(role: 'owner');
    await pumpApp(
      tester,
      state: env.state,
      size: const Size(400, 800),
      child: Scaffold(
        body: Center(
          child: SizedBox(
            width: width,
            child: InlineMessage.error(
              message,
              key: const Key('msg'),
              trailing: TextButton(key: const Key('action'), onPressed: () {}, child: Text(label)),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('kısa mesaj ve kısa eylem aynı satırdadır: eylem mesajın sağındadır', (tester) async {
    await pumpMessage(tester, width: 380, message: 'Hata', label: 'Tamam');

    final text = tester.getRect(find.text('Hata'));
    final action = tester.getRect(find.byKey(const Key('action')));
    expect(action.left, greaterThan(text.right), reason: 'eylem sağda');
    expect((action.center.dy - text.center.dy).abs(), lessThan(20), reason: 'aynı satır');
    expect(tester.takeException(), isNull);
  });

  for (final width in <double>[296, 232]) {
    for (final label in <String>['Tekrar Dene', 'Yeniden Dene']) {
      testWidgets('dar ($width dp) ve 1,5x yazıda uzun eylem etiketi ($label) TAŞMAZ; eylem mesajın altına iner', (tester) async {
        await pumpMessage(
          tester,
          width: width,
          message: 'Wi-Fi şifresi hatalı görünüyor. Şifreyi kontrol edip tekrar deneyin.',
          label: label,
          textScale: 1.5,
        );

        expect(tester.takeException(), isNull, reason: 'RenderFlex taşması yok');
        final text = tester.getRect(find.textContaining('Wi-Fi şifresi hatalı'));
        final action = tester.getRect(find.byKey(const Key('action')));
        expect(action.top, greaterThanOrEqualTo(text.bottom - 1), reason: 'eylem mesajın altında');
        final box = tester.getRect(find.byKey(const Key('msg')));
        expect(action.right, lessThanOrEqualTo(box.right), reason: 'kutunun içinde');
      });
    }
  }

  testWidgets('eylemsiz mesaj ve ekran okuyucu: metin tek parça, canlı bölge korunur', (tester) async {
    final env = e2Env(role: 'owner');
    await pumpApp(
      tester,
      state: env.state,
      child: const Scaffold(body: InlineMessage.warning('Dikkat: bilgi mesajı', key: Key('plain'))),
    );

    expect(find.text('Dikkat: bilgi mesajı'), findsOneWidget);
    expect(find.byType(TextButton), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
