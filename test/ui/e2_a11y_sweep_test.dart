import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/ui/pages/auth/change_password_page.dart';
import 'package:ev_otomasyon/ui/pages/auth/forgot_password_dialog.dart';
import 'package:ev_otomasyon/ui/pages/auth/login_page.dart';
import 'package:ev_otomasyon/ui/pages/auth/phone_otp_dialog.dart';
import 'package:ev_otomasyon/ui/pages/auth/register_page.dart';
import 'package:ev_otomasyon/ui/pages/auth/service_pin_dialog.dart';
import 'package:ev_otomasyon/ui/pages/claim/claim_manual_dialog.dart';
import 'package:ev_otomasyon/ui/pages/family/family_members_page.dart';
import 'package:ev_otomasyon/ui/pages/family/invite_family_dialog.dart';
import 'package:ev_otomasyon/ui/pages/family/join_home_dialog.dart';
import 'package:ev_otomasyon/ui/pages/family/transfer_ownership_dialog.dart';
import 'package:ev_otomasyon/ui/pages/wifi_recovery_dialog.dart';
import 'package:ev_otomasyon/ui/widgets/user_profile_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/support.dart';
import 'e2_support.dart';
import 'e2_wifi_support.dart';

/// E2 ekranlarında erişilebilirlik kuralları (Flutter yönergeleri): dokunulabilir her öğe **48x48 dp**
/// (Android) ve **44x44 dp** (iOS) hedefini karşılar ve ekran okuyucu için **etiketlidir**.
void main() {
  Future<void> expectAccessible(WidgetTester tester) async {
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    await expectLater(tester, meetsGuideline(iOSTapTargetGuideline));
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
  }

  final scenarios = <String, Future<void> Function(WidgetTester tester)>{
    'giriş sayfası': (tester) async {
      final env = e2Env(authenticated: false);
      await pumpApp(tester, state: env.state, size: const Size(412, 915), child: const LoginPage());
      await settle(tester);
    },
    'kayıt sayfası': (tester) async {
      final env = e2Env(authenticated: false);
      await pumpApp(tester, state: env.state, size: const Size(412, 915), child: const RegisterPage());
      await settle(tester);
    },
    'şifremi unuttum (ikinci adım)': (tester) async {
      final env = e2Env(authenticated: false);
      await openFromHost<void>(tester, env.state, size: const Size(412, 915), (c) => ForgotPasswordDialog.show(c));
      await typeInto(tester, 'field_identifier', 'ayse@ornek.test');
      await tapKey(tester, 'btn_send_code');
    },
    'telefonla giriş (kod adımı)': (tester) async {
      final env = e2Env(authenticated: false);
      await openFromHost<void>(tester, env.state, size: const Size(412, 915), (c) => PhoneOtpDialog.show(c));
      await typeInto(tester, 'field_phone', '05551112233');
      await tapText(tester, 'Kod Gönder');
    },
    'servis PIN girişi': (tester) async {
      final env = e2Env(authenticated: false);
      await openFromHost<void>(tester, env.state, size: const Size(412, 915), (c) => ServicePinDialog.show(c));
    },
    'şifre değiştirme': (tester) async {
      final env = e2Env();
      await pumpApp(tester, state: env.state, size: const Size(412, 915), child: const ChangePasswordPage());
      await settle(tester);
    },
    'profil': (tester) async {
      final env = e2Env();
      await openFromHost<void>(tester, env.state, size: const Size(412, 915), (c) => UserProfileDialog.show(c));
    },
    'aile ve misafir listesi': (tester) async {
      final env = e2Env();
      env.cloud.members = <HomeMember>[
        const HomeMember(userId: 'uye-sahip', fullName: 'Ev Sahibi Ali', role: 'owner', email: 'ali@ornek.test'),
        const HomeMember(userId: 'uye-1', fullName: 'Aile Üyesi Ayşe', role: 'resident', email: 'ayse@ornek.test'),
        HomeMember(userId: 'uye-2', fullName: 'Misafir Can', role: 'guest', validUntil: kTestNow.add(const Duration(hours: 30))),
      ];
      env.state.setCurrentUserForTesting(const UserModel(id: 'uye-sahip', email: 'ali@ornek.test', fullName: 'Ev Sahibi Ali'));
      await pumpApp(tester, state: env.state, size: const Size(412, 915), child: const FamilyMembersPage());
      await settle(tester);
    },
    'davet': (tester) async {
      final env = e2Env();
      await openFromHost<void>(tester, env.state, size: const Size(412, 915), (c) => InviteFamilyDialog.show(c));
      await tapKey(tester, 'btn_generate_member_invite');
    },
    'eve katıl': (tester) async {
      final env = e2Env(role: null);
      await openFromHost<bool>(tester, env.state, size: const Size(412, 915), (c) => JoinHomeDialog.show(c));
    },
    'daire devri': (tester) async {
      final env = e2Env();
      await openFromHost<void>(tester, env.state, size: const Size(412, 915), (c) => TransferOwnershipDialog.show(c));
    },
    'cihaz eşleştirme (servis personeli)': (tester) async {
      final env = e2Env(role: null, globalRole: 'service_user');
      await openFromHost<bool>(tester, env.state, size: const Size(412, 915), (c) => ClaimManualDialog.show(c));
    },
    'Wi-Fi kurulum sihirbazı (liste yüklü)': (tester) async {
      final env = e2Env(authenticated: false);
      final dev = FakeWifiDevice();
      await openFromHost<void>(
        tester,
        env.state,
        size: const Size(412, 915),
        (c) => WifiRecoveryDialog.show(c, api: dev.client(env.clock)),
      );
      await tester.ensureVisible(find.byKey(const Key('btn_wifi_check')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('btn_wifi_check')));
      await tester.pump();
      await advanceUntil(tester, env.clock, () => shown('wifi_network_list'));
    },
  };

  for (final entry in scenarios.entries) {
    testWidgets('${entry.key}: dokunma hedefleri yeterli büyüklükte ve ekran okuyucu için etiketli', (tester) async {
      final handle = tester.ensureSemantics();
      try {
        await entry.value(tester);
        await expectAccessible(tester);
      } finally {
        handle.dispose(); // testin bitiş denetiminden ÖNCE kapatılmalı
      }
    });
  }
}
