import 'package:ev_otomasyon/models/api_models.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/service_setup_controller.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/steps/step_4_claim.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'f_flow_support.dart';
import 'f_support.dart';

/// uyelik-1: claim yanıtındaki müşteri hesabının durumu (yeni / bekleyen davet / güvenlik için sıfırlanmış) teknisyene
/// doğru anlatılır (sunucu sözleşme 7: `customer_account = {created, status, invite_sent, security_reset}`).
void main() {
  const resetWarning =
      'Müşterinin doğrulanmamış mevcut hesabı güvenlik için sıfırlandı; şifre belirleme e-postası gönderildi.';

  test('CustomerAccountInfo: security_reset ayrıştırılır (yoksa false)', () {
    final info = CustomerAccountInfo.fromJson(<String, dynamic>{
      'created': false,
      'status': 'pending_invite',
      'invite_sent': true,
      'security_reset': true,
    });
    expect(info.created, isFalse);
    expect(info.status, 'pending_invite');
    expect(info.securityReset, isTrue);
    expect(CustomerAccountInfo.fromJson(<String, dynamic>{'created': true}).securityReset, isFalse);
  });

  test('ClaimSummary: mevcut (bekleyen) hesap -> customerAccountPending; sıfırlandıysa customerSecurityReset', () async {
    final env = await serviceHarness();
    addTearDown(env.dispose);
    env.cloud.claimCustomerAccount = const CustomerAccountInfo(
      created: false,
      status: 'pending_invite',
      inviteSent: true,
      securityReset: true,
    );
    final c = await completeClaim(env);
    final s = c.claim.summary!;
    expect(s.customerAccountCreated, isFalse);
    expect(s.customerAccountPending, isTrue);
    expect(s.customerSecurityReset, isTrue);
    expect(s.inviteSent, isTrue);

    final env2 = await serviceHarness();
    addTearDown(env2.dispose);
    final c2 = await completeClaim(env2); // yeni hesap (created: true)
    expect(c2.claim.summary!.customerAccountPending, isFalse);
    expect(c2.claim.summary!.customerAccountCreated, isTrue);
  });

  Future<void> pumpStep4(WidgetTester tester, ServiceHarness env, ServiceSetupController controller) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<AutomationState>.value(
        value: env.state,
        child: MaterialApp(home: Scaffold(body: Step4Claim(controller: controller))),
      ),
    );
    await tester.pump();
  }

  testWidgets('4. adım: bekleyen hesap satırı; davet gönderilemediyse "Şifremi unuttum" yönlendirmesi', (tester) async {
    final env = (await tester.runAsync(serviceHarness))!;
    addTearDown(env.dispose);
    env.cloud.claimCustomerAccount =
        const CustomerAccountInfo(created: false, status: 'pending_invite', inviteSent: true);
    final c = (await tester.runAsync(() => completeClaim(env)))!;
    await pumpStep4(tester, env, c);
    expect(find.text('Müşteri hesabı henüz etkinleştirilmedi; davet yeniden gönderildi.'), findsOneWidget);

    final env2 = (await tester.runAsync(serviceHarness))!;
    addTearDown(env2.dispose);
    env2.cloud.claimCustomerAccount =
        const CustomerAccountInfo(created: false, status: 'pending_invite', inviteSent: false);
    final c2 = (await tester.runAsync(() => completeClaim(env2)))!;
    await pumpStep4(tester, env2, c2);
    expect(
      find.text(
        'Müşteri hesabı henüz etkinleştirilmedi; davet gönderilemedi; müşteri Şifremi unuttum ile etkinleştirebilir.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('4. adım: güvenlik sıfırlaması metni sunucu uyarısında varsa ikinci kez gösterilmez', (tester) async {
    final env = (await tester.runAsync(serviceHarness))!;
    addTearDown(env.dispose);
    env.cloud.claimCustomerAccount = const CustomerAccountInfo(
      created: false,
      status: 'pending_invite',
      inviteSent: true,
      securityReset: true,
    );
    env.cloud.claimWarnings = const <String>[resetWarning];
    final c = (await tester.runAsync(() => completeClaim(env)))!;
    await pumpStep4(tester, env, c);
    expect(find.text(resetWarning), findsOneWidget);

    final env2 = (await tester.runAsync(serviceHarness))!;
    addTearDown(env2.dispose);
    env2.cloud.claimCustomerAccount = const CustomerAccountInfo(
      created: false,
      status: 'pending_invite',
      inviteSent: true,
      securityReset: true,
    );
    final c2 = (await tester.runAsync(() => completeClaim(env2)))!;
    await pumpStep4(tester, env2, c2);
    expect(find.text(resetWarning), findsOneWidget, reason: 'sunucu uyarısı yoksa sıfırlama yine söylenir');
  });
}
