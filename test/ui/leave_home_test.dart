import 'package:ev_otomasyon/services/api_exception.dart';
import 'package:ev_otomasyon/ui/widgets/user_profile_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/support.dart';
import 'e2_support.dart';

/// Karar 13 (2026-10-09): sakin ve misafir "Evden ayrıl" ile evden çıkar (`DELETE /homes/:id/members/me`).
/// Sahip / personel düğmeyi görmez; 409 sunucu iletisi gösterilir; başarıda ev yerelden düşer.
void main() {
  group('state.leaveHome', () {
    test('aktif ev yerelden düşer ve diğer eve geçilir', () async {
      final env = e2Env(role: 'resident');
      final a = testHome(role: 'resident');
      final b = testHome(id: kHomeB, name: 'Ev B', role: 'guest');
      env.state.setHomesForTesting([a, b], activeHome: a);
      env.cloud.homes = [a, b];

      await env.state.leaveHome(kHomeA);

      expect(env.cloud.leftHomes, [kHomeA]);
      expect(env.state.homes.map((h) => h.id), [kHomeB]);
      expect(env.state.activeHome?.id, isNot(kHomeA));
    });

    test('tek ev: evsiz duruma geçilir', () async {
      final env = e2Env(role: 'guest');
      await env.state.leaveHome(kHomeA);
      expect(env.state.homes, isEmpty);
      expect(env.state.activeHome, isNull);
    });

    test('409 OWNER_CANNOT_LEAVE: ev listede kalır, hata fırlar', () async {
      final env = e2Env(role: 'resident');
      env.cloud.leaveHomeError =
          const ApiException(statusCode: 409, code: 'OWNER_CANNOT_LEAVE', message: 'Ev sahibi evden ayrılamaz.');
      await expectLater(env.state.leaveHome(kHomeA), throwsA(isA<ApiException>()));
      expect(env.state.activeHome?.id, kHomeA);
    });
  });

  group('profil penceresi "Evden Ayrıl"', () {
    testWidgets('sahip görmez', (tester) async {
      final env = e2Env();
      await openFromHost<void>(tester, env.state, (c) => UserProfileDialog.show(c));
      expect(find.byKey(const Key('btn_leave_home')), findsNothing);
    });

    testWidgets('servis personeli (sakin rolünde de olsa) görmez', (tester) async {
      final env = e2Env(role: 'resident', globalRole: 'service_user');
      await openFromHost<void>(tester, env.state, (c) => UserProfileDialog.show(c));
      expect(find.byKey(const Key('btn_leave_home')), findsNothing);
    });

    testWidgets('sakin: onay sorulur; vazgeçilirse istek yok, onaylanınca ayrılır', (tester) async {
      final env = e2Env(role: 'resident');
      await openFromHost<void>(tester, env.state, (c) => UserProfileDialog.show(c));
      await tapKey(tester, 'btn_leave_home');
      await tapKey(tester, 'btn_leave_home_cancel');
      expect(env.cloud.leftHomes, isEmpty);

      await tapKey(tester, 'btn_leave_home');
      await tapKey(tester, 'btn_leave_home_confirm');
      await settle(tester);
      expect(env.cloud.leftHomes, [kHomeA]);
      expect(env.state.activeHome, isNull);
      expect(find.textContaining('evinden ayrıldınız'), findsOneWidget);
    });

    testWidgets('misafir: 409 sunucu iletisi gösterilir, ev kalır', (tester) async {
      final env = e2Env(role: 'guest');
      env.cloud.leaveHomeError =
          const ApiException(statusCode: 409, code: 'OWNER_CANNOT_LEAVE', message: 'Ev sahibi evden ayrılamaz; önce evi devredin.');
      await openFromHost<void>(tester, env.state, (c) => UserProfileDialog.show(c));
      await tapKey(tester, 'btn_leave_home');
      await tapKey(tester, 'btn_leave_home_confirm');
      await settle(tester);
      expect(find.text('Ev sahibi evden ayrılamaz; önce evi devredin.'), findsOneWidget);
      expect(env.state.activeHome?.id, kHomeA);
    });
  });
}
