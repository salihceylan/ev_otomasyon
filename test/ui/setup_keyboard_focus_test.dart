import 'package:ev_otomasyon/ui/pages/service_setup/service_setup_controller.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/setup_step_scaffold.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// Saha hatası (2026-10-07): sihirbaz adım 3'te müşteri e-postası yazılamıyordu. Klavye açılınca kalan yükseklik
// "sıkışık" eşiğinin altına düşüyor, iskelet düzen değiştiriyor, gövdedeki metin kutusu yeniden kuruluyor ve odak
// kayboluyordu -> klavye kapanıyor -> yükseklik geri geliyor -> döngü.
void main() {
  testWidgets('klavye açılınca (viewInsets) adım iskeleti düzen değiştirmez, metin kutusu odağını korur', (tester) async {
    tester.view.physicalSize = const Size(1200, 2652);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          appBar: AppBar(title: const Text('Kurulum')),
          // Sihirbazın sayfa düzeyi adım şeridi + oturum bandı (gerçek sayfadaki sabit üst alan).
          body: Column(
            children: [
              const SizedBox(height: 140),
              Expanded(
                child: SetupStepScaffold(
                  step: 3,
                  total: 10,
                  title: 'Müşteri',
                  instructions: const <String>[],
                  phase: StepPhase.working,
                  body: TextField(key: const Key('field_customer'), controller: controller),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('field_customer')));
    await tester.pump();
    final state = tester.state<EditableTextState>(find.byType(EditableText));
    expect(state.widget.focusNode.hasFocus, isTrue);

    // Klavye: ekranın yaklaşık yarısı (fiziksel piksel). Scaffold gövdeyi küçültür.
    tester.view.viewInsets = const FakeViewPadding(bottom: 1300);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('setup_compact_scroll')), findsNothing, reason: 'klavye yüzünden sıkışık düzene geçilmemeli');
    expect(
      identical(tester.state<EditableTextState>(find.byType(EditableText)), state),
      isTrue,
      reason: 'metin kutusu yeniden kurulmamalı',
    );
    expect(state.widget.focusNode.hasFocus, isTrue, reason: 'odak korunmalı (klavye kapanmamalı)');

    await tester.enterText(find.byKey(const Key('field_customer')), 'musteri@ornek.com');
    expect(controller.text, 'musteri@ornek.com');
  });
}
