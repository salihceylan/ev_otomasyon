import 'dart:async';

import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/ui/common/date_format.dart';
import 'package:ev_otomasyon/ui/pages/family/family_members_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/support.dart';
import 'ui/e2_support.dart';

/// Aile & misafir listesi: UUID (String) kimlikli üyeler, rol/süre gösterimi, onaylı silme ve
/// sonucun yeniden okunarak doğrulanması, yükleme hata/zaman aşımı/yeniden dene yolları.
void main() {
  const idOwner = 'aaaaaaaa-0000-4000-8000-000000000001';
  const idResident = 'aaaaaaaa-0000-4000-8000-000000000002';
  const idGuest = 'aaaaaaaa-0000-4000-8000-000000000003';
  const idExpired = 'aaaaaaaa-0000-4000-8000-000000000004';

  List<HomeMember> sampleMembers() => <HomeMember>[
        const HomeMember(userId: idOwner, fullName: 'Ev Sahibi Ali', role: 'owner', email: 'ali@ornek.test'),
        const HomeMember(userId: idResident, fullName: 'Aile Üyesi Ayşe', role: 'member', email: 'ayse@ornek.test'),
        HomeMember(
          userId: idGuest,
          fullName: 'Misafir Can',
          role: 'guest',
          validUntil: kTestNow.add(const Duration(hours: 5, minutes: 20)),
        ),
        HomeMember(
          userId: idExpired,
          fullName: 'Eski Misafir',
          role: 'guest',
          validUntil: kTestNow.subtract(const Duration(hours: 3)),
        ),
      ];

  /// Ev sahibi olarak liste sayfası. Kullanıcı kimliği listedeki `idOwner` ile eşleşir.
  Future<E2Env> pumpPage(WidgetTester tester, {String role = 'owner', List<HomeMember>? members}) async {
    final env = e2Env(role: role);
    env.cloud.members = members ?? sampleMembers();
    env.state.setCurrentUserForTesting(const UserModel(id: idOwner, email: 'ali@ornek.test', fullName: 'Ev Sahibi Ali'));
    await pumpApp(tester, state: env.state, child: const FamilyMembersPage());
    await settle(tester);
    return env;
  }

  group('üye listesi', () {
    testWidgets('üyeler UUID kimlikleriyle listelenir; eski rol adı `member` aile üyesi olarak normalleştirilir', (tester) async {
      await pumpPage(tester);

      for (final id in <String>[idOwner, idResident, idGuest, idExpired]) {
        expect(find.byKey(Key('card_member_$id')), findsOneWidget, reason: id);
      }
      expect(find.text('4 Kişi'), findsOneWidget);
      expect(find.text('EV SAHİBİ'), findsOneWidget);
      expect(find.text('AİLE ÜYESİ'), findsOneWidget, reason: '`member` -> `resident`');
      expect(find.text('SÜRELİ MİSAFİR'), findsOneWidget);
      expect(find.text('MİSAFİR (SÜRESİ DOLDU)'), findsOneWidget);
    });

    testWidgets('misafirin kalan süresi ve erişim bitişi (YEREL saat) gösterilir; süresi dolan "sona erdi" der', (tester) async {
      await pumpPage(tester);

      expect(textOf(tester, 'member_remaining_$idGuest'), '5 saat 20 dk kaldı');
      expect(
        textOf(tester, 'member_until_$idGuest'),
        'Erişim bitişi: ${formatLocalDateTime(kTestNow.add(const Duration(hours: 5, minutes: 20)))}',
      );
      expect(textOf(tester, 'member_remaining_$idExpired'), 'Süresi sona erdi');
    });

    testWidgets('kendisi ve ev sahibi için silme düğmesi YOKTUR; aile üyesi ve misafir için vardır', (tester) async {
      await pumpPage(tester);

      expect(find.byKey(const Key('btn_remove_member_$idOwner')), findsNothing, reason: 'ev sahibi/kendisi silinemez');
      expect(find.byKey(const Key('btn_remove_member_$idResident')), findsOneWidget);
      expect(find.byKey(const Key('btn_remove_member_$idGuest')), findsOneWidget);
    });

    testWidgets('üye yönetim yetkisi olmayan rol (aile üyesi) listeyi görür ama silme/davet/devir düğmesi görmez', (tester) async {
      await pumpPage(tester, role: 'resident');

      expect(find.byKey(const Key('card_member_$idResident')), findsOneWidget);
      expect(find.byKey(const Key('btn_remove_member_$idGuest')), findsNothing);
      expect(find.byKey(const Key('btn_invite_family')), findsNothing);
      expect(find.byKey(const Key('btn_transfer_home')), findsNothing);
    });

    testWidgets('ev sahibi davet ve devir girişlerini görür', (tester) async {
      await pumpPage(tester);
      expect(find.byKey(const Key('btn_invite_family')), findsOneWidget);
      expect(find.byKey(const Key('btn_transfer_home')), findsOneWidget);
    });

    testWidgets('liste boşsa boş durum gösterilir (hata ile karışmaz)', (tester) async {
      await pumpPage(tester, members: <HomeMember>[]);
      expect(find.byKey(const Key('members_empty')), findsOneWidget);
      expect(find.byKey(const Key('members_error')), findsNothing);
    });

    testWidgets('aktif daire yoksa sonsuz yükleme yerine açıklayıcı ileti gösterilir', (tester) async {
      final env = e2Env(role: null);
      await pumpApp(tester, state: env.state, child: const FamilyMembersPage());
      await settle(tester);

      expect(find.byKey(const Key('members_no_home')), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(env.cloud.calls.where((c) => c.startsWith('getHomeMembers')), isEmpty);
    });
  });

  group('silme (onaylı, sonucu doğrulanan)', () {
    testWidgets('onaylanırsa UUID kimlikle silinir, liste yeniden okunur ve üye kaybolur', (tester) async {
      final env = await pumpPage(tester);

      await tapKey(tester, 'btn_remove_member_$idResident');
      expect(find.text('Üyeyi Evden Çıkar'), findsOneWidget);
      expect(env.cloud.removedMembers, isEmpty, reason: 'onaydan önce silinmez');
      await tapKey(tester, 'btn_remove_confirm');

      expect(env.cloud.removedMembers, <String>[idResident], reason: 'String UUID (int DEĞİL) gönderilir');
      expect(find.byKey(const Key('card_member_$idResident')), findsNothing);
      expect(find.textContaining('yetkisi iptal edildi'), findsOneWidget);
      expect(env.cloud.calls.where((c) => c.startsWith('getHomeMembers')).length, greaterThanOrEqualTo(2), reason: 'sonuç yeniden okunarak doğrulandı');
    });

    testWidgets('vazgeçilirse hiçbir şey silinmez', (tester) async {
      final env = await pumpPage(tester);

      await tapKey(tester, 'btn_remove_member_$idGuest');
      await tapKey(tester, 'btn_remove_cancel');

      expect(env.cloud.removedMembers, isEmpty);
      expect(find.byKey(const Key('card_member_$idGuest')), findsOneWidget);
    });

    testWidgets('misafir için doğru başlık ve açıklama gösterilir', (tester) async {
      await pumpPage(tester);
      await tapKey(tester, 'btn_remove_member_$idGuest');
      expect(find.text('Misafir Yetkisini İptal Et'), findsOneWidget);
      expect(find.textContaining('"Misafir Can" kullanıcısının'), findsOneWidget);
    });

    testWidgets('sunucu silmeyi reddederse (yetki) Türkçe hata gösterilir ve üye listede kalır', (tester) async {
      final env = await pumpPage(tester);
      env.cloud.removeError = apiError(403, 'Bu işlem için yetkiniz yok.', code: 'FORBIDDEN');

      await tapKey(tester, 'btn_remove_member_$idResident');
      await tapKey(tester, 'btn_remove_confirm');

      expect(find.text('Bu işlem için yetkiniz yok.'), findsOneWidget);
      expect(find.byKey(const Key('card_member_$idResident')), findsOneWidget);
      expect(find.textContaining('Exception'), findsNothing);
    });

    testWidgets('sunucu "tamam" der ama üye hâlâ listedeyse başarı DENMEZ, uyarı gösterilir', (tester) async {
      final env = await pumpPage(tester);
      env.cloud.removeKeepsMember = true;

      await tapKey(tester, 'btn_remove_member_$idResident');
      await tapKey(tester, 'btn_remove_confirm');

      expect(find.textContaining('listede görünmeye devam ediyor'), findsOneWidget);
      expect(find.textContaining('yetkisi iptal edildi'), findsNothing);
      expect(find.byKey(const Key('card_member_$idResident')), findsOneWidget);
    });
  });

  group('yükleme durumları (sonsuz spinner yok)', () {
    testWidgets('ağ hatası hata kartı ve "Tekrar Dene" gösterir; yeniden deneyince liste gelir', (tester) async {
      final env = e2Env();
      env.cloud.members = sampleMembers();
      env.cloud.membersError = apiError(0, 'Sunucuya ulaşılamadı. İnternet bağlantınızı kontrol edin.', code: 'NETWORK');
      await pumpApp(tester, state: env.state, child: const FamilyMembersPage());
      await settle(tester);

      expect(textOf(tester, 'members_error'), 'Sunucuya ulaşılamadı. İnternet bağlantınızı kontrol edin.');
      expect(find.byType(CircularProgressIndicator), findsNothing);

      env.cloud.membersError = null;
      await tapKey(tester, 'btn_members_retry');

      expect(find.byKey(const Key('members_error')), findsNothing);
      expect(find.byKey(const Key('card_member_$idResident')), findsOneWidget);
    });

    testWidgets('yanıt hiç gelmezse 20 sn sonra zaman aşımı hatası ve yeniden deneme yolu açılır', (tester) async {
      final env = e2Env();
      env.cloud.membersGate = Completer<void>(); // asla tamamlanmaz
      await pumpApp(tester, state: env.state, child: const FamilyMembersPage());
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(CircularProgressIndicator), findsWidgets, reason: 'yükleniyor');

      await tester.pump(const Duration(seconds: 21));

      expect(find.byKey(const Key('members_error')), findsOneWidget);
      expect(find.textContaining('zaman aşımına'), findsOneWidget);
      expect(find.byKey(const Key('btn_members_retry')), findsOneWidget);
    });

    testWidgets('sayfa kapanırken bekleyen yanıt gelirse hata oluşmaz (mounted koruması)', (tester) async {
      final env = e2Env();
      final gate = Completer<void>();
      env.cloud.membersGate = gate;
      env.cloud.members = sampleMembers();
      await pumpApp(tester, state: env.state, child: const FamilyMembersPage());
      await tester.pump();
      await tester.pumpWidget(const SizedBox());

      gate.complete();
      await tester.pump(const Duration(milliseconds: 100));

      expect(tester.takeException(), isNull);
    });
  });
}
