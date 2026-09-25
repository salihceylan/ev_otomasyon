// test/homeless_individual_user_test.dart
//
// Dairesi olmayan bireysel kullanıcıya yalnızca "Kod ile Bir Eve Katıl"
// ekranının gösterildiğini; eve katıldıktan sonra normal dashboard'a
// geçileceğini doğrulayan widget testleri.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/ui/pages/dashboard_page.dart';

/// Minimal AutomationState alt sınıfı — gerçek network/MQTT bağlantısı yapmaz.
class _FakeState extends AutomationState {
  _FakeState();

  @override
  Future<void> refresh({bool silent = false}) async {}
}

Widget _wrap(_FakeState state) {
  return ChangeNotifierProvider<AutomationState>.value(
    value: state,
    child: const MaterialApp(home: DashboardPage()),
  );
}

UserModel _fakeUser() => UserModel.fromJson({
      'id': 42,
      'email': 'test@ahbu.test',
      'full_name': 'Test Kullanıcı',
      'role': 'user',
    });

HomeModel _fakeHome() => HomeModel(
      id: 1,
      name: 'Test Dairesi',
      mqttUsername: 'home_1',
      role: 'owner',
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Dairesi olmayan bireysel kullanıcı', () {
    testWidgets(
      'Yalnızca "Kod ile Bir Eve Katıl" butonu görünür; '
      'diğer dashboard içerikleri gizlidir',
      (tester) async {
        final state = _FakeState();

        // Kullanıcı giriş yapmış ama hiçbir eve üye değil
        state.setCurrentUserForTesting(_fakeUser());
        state.setHomesForTesting([]);

        await tester.pumpWidget(_wrap(state));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        // ── Gösterilmesi gerekenler ──────────────────────────────────
        expect(find.text('Kod ile Bir Eve Katıl'), findsOneWidget,
            reason: 'Eve katılım butonu gösterilmeli');
        expect(find.text('Karekod ile Katıl'), findsOneWidget,
            reason: 'QR katılım butonu gösterilmeli');
        expect(find.text('Henüz kayıtlı bir daireniz yok'), findsOneWidget,
            reason: 'Uyarı etiketi gösterilmeli');

        // ── Gizlenmesi gerekenler ───────────────────────────────────
        // Normal daire ekranında bulunan widget'lar gösterilmemeli
        expect(find.byIcon(Icons.cloud_outlined), findsNothing,
            reason: 'Mod değiştirici dairesi olmayan kullanıcıda görünmemeli');
        expect(find.byIcon(Icons.settings_outlined), findsNothing,
            reason: 'Cihaz Ayarları dairesi olmayan kullanıcıda görünmemeli');
      },
    );

    testWidgets(
      'Dairesi olan kullanıcıda normal daire dashboard\'ı açılır; '
      'eve katılım ekranı görünmez',
      (tester) async {
        final state = _FakeState();

        state.setCurrentUserForTesting(_fakeUser());
        state.setHomesForTesting([_fakeHome()], activeHome: _fakeHome());

        await tester.pumpWidget(_wrap(state));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        // Eve katılım butonu gösterilmemeli
        expect(find.text('Kod ile Bir Eve Katıl'), findsNothing,
            reason: 'Dairesi olan kullanıcıda katılım butonu olmamalı');
        expect(find.text('Henüz kayıtlı bir daireniz yok'), findsNothing,
            reason: 'Uyarı etiketi dairesi olan kullanıcıda olmamalı');
      },
    );
  });
}
