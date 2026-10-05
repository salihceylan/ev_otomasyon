import 'package:ev_otomasyon/ui/widgets/content_width_limit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> pump(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      const MaterialApp(
        home: ContentWidthLimit(child: Scaffold(body: SizedBox.expand(key: Key('icerik')))),
      ),
    );
  }

  testWidgets('geniş pencerede içerik ortalanır ve sütun genişliğine sınırlanır', (tester) async {
    await pump(tester, const Size(1920, 1000));
    final rect = tester.getRect(find.byKey(const Key('icerik')));
    expect(rect.width, ContentWidthLimit.defaultMaxWidth);
    expect(rect.left, (1920 - ContentWidthLimit.defaultMaxWidth) / 2);
    final mq = MediaQuery.of(tester.element(find.byKey(const Key('icerik'))));
    expect(mq.size.width, ContentWidthLimit.defaultMaxWidth, reason: 'kırılımlar sütun genişliğine göre karar verir');
  });

  testWidgets('dar pencerede (telefon) hiçbir şey değişmez', (tester) async {
    await pump(tester, const Size(400, 800));
    final rect = tester.getRect(find.byKey(const Key('icerik')));
    expect(rect.width, 400);
    expect(rect.left, 0);
  });
}
