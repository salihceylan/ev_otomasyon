import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:ev_otomasyon/ui/pages/auth/delete_account_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/support.dart';
import 'e2_support.dart';

/// UYELIK-03 (D21): sunucu kuralı değişti: üyesiz + panosuz tek sahipli daireler hesap silmeye ENGEL değildir
/// (hesapla birlikte silinir, yanıtta `released_homes`). İstemci SOLE_OWNER'ı önceden hesaplayıp engellemez (kararı
/// sunucu verir); başarıda `released_homes > 0` ise kısa bilgi verilir. Diğer durumlar 409 SOLE_OWNER (aynen).
void main() {
  Future<void> deleteWithPhrase(WidgetTester tester, E2Env env) async {
    await openFromHost<void>(tester, env.state, (context) => DeleteAccountDialog.show(context));
    await typeInto(tester, 'field_delete_confirm', 'SİL');
    await tapKey(tester, 'btn_delete_account');
    await tester.pumpAndSettle();
  }

  testWidgets('tek sahipli (üyesiz + panosuz) daire: istemci engellemez; sunucu siler ve sayısını bildirir -> kısa bilgi', (tester) async {
    final env = e2Env(role: 'owner'); // kullanıcı aktif dairenin TEK sahibi
    env.cloud.deleteReleasedHomes = 2;

    await deleteWithPhrase(tester, env);

    expect(env.cloud.deleteAccountArgs, hasLength(1), reason: 'istek sunucuya gitti (istemci ön-engeli yok)');
    expect(env.state.authStatus, AuthStatus.unauthenticated);
    expect(find.byType(DeleteAccountDialog), findsNothing);
    expect(find.text('Hesabınız silindi. Üyesi ve panosu olmayan 2 daireniz de kaldırıldı.'), findsOneWidget);
  });

  testWidgets('released_homes 1: tekil ileti', (tester) async {
    final env = e2Env(role: 'owner');
    env.cloud.deleteReleasedHomes = 1;

    await deleteWithPhrase(tester, env);

    expect(find.text('Hesabınız silindi. Üyesi ve panosu olmayan 1 daireniz de kaldırıldı.'), findsOneWidget);
  });

  testWidgets('released_homes 0 / eski sunucu: mevcut ileti aynen', (tester) async {
    final env = e2Env(role: 'owner');

    await deleteWithPhrase(tester, env);

    expect(find.text('Hesabınız silindi.'), findsOneWidget);
    expect(find.textContaining('daireniz de kaldırıldı'), findsNothing);
  });

  testWidgets('üyeli/panolu daire: 409 SOLE_OWNER davranışı aynen (hiçbir şey silinmez, devir yönlendirmesi)', (tester) async {
    final env = e2Env(role: 'owner');
    env.cloud.deleteAccountError = apiError(
      409,
      'Bazı dairelerin tek sahibisiniz.',
      code: 'SOLE_OWNER',
      details: <String, dynamic>{
        'homes': <Map<String, dynamic>>[
          <String, dynamic>{'id': kHomeA, 'name': 'Ev A', 'other_member_count': 1, 'device_count': 0},
        ],
      },
    );

    await deleteWithPhrase(tester, env);

    expect(find.byKey(const Key('sole_owner_notice')), findsOneWidget);
    expect(find.byKey(const Key('sole_home_$kHomeA')), findsOneWidget);
    expect(env.state.authStatus, AuthStatus.authenticated);
  });
}
