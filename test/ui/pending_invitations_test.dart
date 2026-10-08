import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/services/api_exception.dart';
import 'package:ev_otomasyon/services/ev_cloud_api_service.dart';
import 'package:ev_otomasyon/ui/pages/family/family_members_page.dart';
import 'package:ev_otomasyon/ui/pages/family/invite_family_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/support.dart';
import 'e2_support.dart';

/// ev_uyelik-6: bekleyen davetler listelenir ve iptal edilir (sunucu sözleşme 12:
/// `GET /homes/:homeId/invitations`, `DELETE /homes/:homeId/invitations/:id`; yalnız ev sahibi / süper).
void main() {
  PendingInvitation guestInvite({String id = 'inv-1'}) => PendingInvitation(
        id: id,
        role: 'guest',
        expiresAt: DateTime.utc(2026, 10, 2, 12),
        guestName: 'Temizlik Görevlisi',
        guestValidUntil: DateTime.utc(2026, 10, 1, 20),
        createdAt: DateTime.utc(2026, 10, 1, 11),
      );

  group('bulut istemcisi', () {
    test('liste GET ve iptal DELETE doğru yola gider; kod alanı beklenmez', () async {
      final api = MockApi();
      final service = EvCloudApiService(baseUrl: 'https://api.test/api', client: api.client, clock: FakeClock());
      addTearDown(service.dispose);
      service.setAuthToken('tok');
      api
        ..on('GET', '/api/v1/homes/$kHomeA/invitations', (r) => okResponse(<dynamic>[
              <String, dynamic>{
                'id': 'inv-1',
                'role': 'guest',
                'expires_at': '2026-10-02T12:00:00.000Z',
                'guest_name': 'Temizlik',
                'guest_valid_until': '2026-10-01T20:00:00.000Z',
                'created_at': '2026-10-01T11:00:00.000Z',
              },
              <String, dynamic>{'role': 'resident'}, // kimliksiz kayıt atlanır
            ]))
        ..on('DELETE', '/api/v1/homes/$kHomeA/invitations/inv-1', (r) => okResponse(<String, dynamic>{'id': 'inv-1'}));
      final list = await service.listInvitations(kHomeA);
      expect(list.single.id, 'inv-1');
      expect(list.single.role, 'guest');
      expect(list.single.guestName, 'Temizlik');
      expect(list.single.guestValidUntil, DateTime.utc(2026, 10, 1, 20));
      await service.revokeInvitation(kHomeA, 'inv-1');
      expect(api.requests.last.method, 'DELETE');
    });

    test('oluşturma yanıtındaki id okunur', () {
      final inv = InvitationModel.fromJson(<String, dynamic>{'id': 'inv-9', 'code': 'AHBU-FAMILY1234', 'role': 'resident'});
      expect(inv.id, 'inv-9');
    });
  });

  group('aile sayfası', () {
    testWidgets('ev sahibi bekleyen daveti görür ve onaylı iptal eder; liste yenilenir', (tester) async {
      final env = e2Env(role: 'owner');
      env.cloud.pendingInvitations = <PendingInvitation>[guestInvite()];
      await pumpApp(tester, state: env.state, child: const FamilyMembersPage(), size: const Size(800, 2400));
      await settle(tester);

      expect(find.byKey(const Key('pending_invitations')), findsOneWidget);
      expect(find.textContaining('Temizlik Görevlisi'), findsOneWidget);
      final listCalls = env.cloud.count('listInvitations');

      await tapKey(tester, 'btn_revoke_invite_inv-1');
      expect(env.cloud.revokedInvitations, isEmpty, reason: 'onay beklenir');
      await tapKey(tester, 'btn_simple_confirm');
      await settle(tester);

      expect(env.cloud.revokedInvitations, <String>['inv-1']);
      expect(env.cloud.count('listInvitations'), greaterThan(listCalls));
      expect(find.byKey(const Key('pending_invite_inv-1')), findsNothing);
    });

    testWidgets('iptalde 404 (davet kullanılmış / süresi dolmuş): liste yenilenir ve açıklanır', (tester) async {
      final env = e2Env(role: 'owner');
      env.cloud.pendingInvitations = <PendingInvitation>[guestInvite()];
      env.cloud.revokeInvitationError = apiError(404, 'Davet bulunamadı.', code: 'NOT_FOUND');
      await pumpApp(tester, state: env.state, child: const FamilyMembersPage(), size: const Size(800, 2400));
      await settle(tester);
      final listCalls = env.cloud.count('listInvitations');
      env.cloud.pendingInvitations = const <PendingInvitation>[];

      await tapKey(tester, 'btn_revoke_invite_inv-1');
      await tapKey(tester, 'btn_simple_confirm');
      await settle(tester);

      expect(env.cloud.count('listInvitations'), greaterThan(listCalls));
      expect(find.textContaining('zaten kullanılmış ya da süresi dolmuş'), findsOneWidget);
      expect(find.byKey(const Key('pending_invite_inv-1')), findsNothing);
    });

    testWidgets('sakinde bölüm yok ve liste istenmez', (tester) async {
      final env = e2Env(role: 'resident');
      env.cloud.pendingInvitations = <PendingInvitation>[guestInvite()];
      await pumpApp(tester, state: env.state, child: const FamilyMembersPage(), size: const Size(800, 2400));
      await settle(tester);
      expect(find.byKey(const Key('pending_invitations')), findsNothing);
      expect(env.cloud.count('listInvitations'), 0);
      await expectLater(env.state.fetchPendingInvitations(), throwsA(isA<ApiException>()));
    });
  });

  testWidgets('davet penceresi: üretilen davet "Bu daveti iptal et" ile iptal edilir', (tester) async {
    final env = e2Env(role: 'owner');
    env.cloud.invitationToReturn = InvitationModel(
      id: 'inv-7',
      code: 'AHBU-FAMILY1234',
      role: 'resident',
      expiresAt: DateTime.utc(2026, 10, 2, 12),
    );
    await openFromHost<void>(tester, env.state, (context) => InviteFamilyDialog.show(context), size: const Size(800, 2000));
    await tapKey(tester, 'btn_generate_member_invite');
    expect(find.byKey(const Key('invite_member_code')), findsOneWidget);

    await tapKey(tester, 'btn_revoke_member_invite');
    await tapKey(tester, 'btn_simple_confirm');
    await settle(tester);

    expect(env.cloud.revokedInvitations, <String>['inv-7']);
    expect(find.byKey(const Key('invite_member_code')), findsNothing, reason: 'iptal edilen kod ekranda kalmaz');
  });
}
