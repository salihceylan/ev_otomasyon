import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:ev_otomasyon/main.dart';
import 'package:ev_otomasyon/services/automation_state.dart';

void main() {
  testWidgets('App starts smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => AutomationState()),
        ],
        child: const EvOtomasyonApp(),
      ),
    );

    expect(find.byType(EvOtomasyonApp), findsOneWidget);
  });
}
