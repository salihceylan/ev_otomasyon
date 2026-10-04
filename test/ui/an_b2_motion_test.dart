// Hareket v3 / ekip B2: ikincil sayfa giriş ve durum geçişleri.
// * off kipinde (testlerin varsayılanı) içerik ilk karede TAM görünür (ara durum yok);
// * full kipinde geçiş sonunda tam görünür, pumpAndSettle biter (zamanlayıcı yok);
// * durum geçişinde ağaçta her an TEK durum çocuğu bulunur.
import 'package:ev_otomasyon/ui/dashboard/welcome_cards.dart';
import 'package:ev_otomasyon/ui/motion/motion.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(Widget child, {MotionMode mode = MotionMode.off}) => MaterialApp(
      home: MotionScope(
        mode: mode,
        child: Scaffold(body: SingleChildScrollView(child: child)),
      ),
    );

double _minOpacityAbove(WidgetTester tester, Finder target) {
  var min = 1.0;
  for (final fade in tester.widgetList<FadeTransition>(find.ancestor(of: target, matching: find.byType(FadeTransition)))) {
    if (fade.opacity.value < min) min = fade.opacity.value;
  }
  return min;
}

void main() {
  testWidgets('WelcomeClaimCard: off kipinde ilk karede tam görünür', (tester) async {
    await tester.pumpWidget(_host(const WelcomeClaimCard()));
    final card = find.byKey(const Key('card_welcome_claim'));
    expect(card, findsOneWidget);
    expect(_minOpacityAbove(tester, card), 1.0);
    expect(tester.hasRunningAnimations, isFalse);
  });

  testWidgets('WelcomeClaimCard: full kipinde giriş biter, sonunda tam görünür', (tester) async {
    await tester.pumpWidget(_host(const WelcomeClaimCard(), mode: MotionMode.full));
    final card = find.byKey(const Key('card_welcome_claim'));
    expect(_minOpacityAbove(tester, card), lessThan(1.0));
    // Etkin orb'un ortam nabzı sürekli olduğundan pumpAndSettle yerine giriş süresinden uzun sabit pompa.
    await tester.pump(const Duration(seconds: 1));
    expect(_minOpacityAbove(tester, card), 1.0);
    expect(find.byKey(const Key('btn_scan_qr')), findsOneWidget);
  });

  testWidgets('StateSwitcher (liste durumu): full kipinde bile ağaçta tek durum metni', (tester) async {
    Widget body(String state) => _host(
          StateSwitcher(
            stateKey: state,
            child: SizedBox(width: double.infinity, child: Text(state == 'loading' ? 'Yükleniyor' : 'İçerik')),
          ),
          mode: MotionMode.full,
        );
    await tester.pumpWidget(body('loading'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(body('content'));
    await tester.pump(const Duration(milliseconds: 16));
    expect(find.text('Yükleniyor'), findsNothing);
    expect(find.text('İçerik'), findsOneWidget);
    await tester.pumpAndSettle();
    expect(_minOpacityAbove(tester, find.text('İçerik')), 1.0);
  });
}
