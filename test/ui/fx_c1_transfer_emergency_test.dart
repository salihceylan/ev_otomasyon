import 'package:ev_otomasyon/models/api_models.dart';
import 'package:ev_otomasyon/ui/pages/family/transfer_ownership_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'e2_support.dart';

/// `TransferOwnershipDialog` acil sıfırlama sekmesi (konsol / çekmece girişi; servis panelindeki kartla aynı sözleşme):
///
/// * SERVIS-01 (D13): `local_key_publish: 'pending'` (yanıtta `local_key` yok) bilgi notu olarak gösterilir: yeni anahtar
///   pano buluta bağlanınca sunucu tarafından otomatik iletilecek. Eski sunucu yanıtındaki anahtar için uygulanamaz
///   "yerinde girilmeli" yerine gerçek kurtarma yolu: seri konsolda RESETKEY + FACTORYINIT (fabrika aracı).
/// * SERVIS-07 (D15): kalıcı servis personeli (süper değil) 72 saat kısıt notunu görür; 403'te yönlendirme hata kutusunun
///   altında (tek kez) görünür. Süper yöneticinin 403 metni değişmez.
void main() {
  const uid = 'AHBU-S3-A1B2C3';
  const reason = 'Kiracı tahliye edildi, sözleşme ibraz edildi';
  const scopeNote = 'Servis personeli yalnız son 72 saat içinde kurduğu ya da devraldığı dairelerin panolarını '
      'sıfırlayabilir; diğer daireler için süper yöneticiye başvurun.';

  bool shown(String key) => find.byKey(Key(key)).evaluate().isNotEmpty;

  Future<E2Env> openEmergency(WidgetTester tester, {String globalRole = 'super_user'}) async {
    final env = e2Env(role: null, globalRole: globalRole);
    await openFromHost<void>(tester, env.state, (context) => TransferOwnershipDialog.show(context, initialTab: 1));
    expect(find.byKey(const Key('emergency_form')), findsOneWidget);
    return env;
  }

  Future<void> submitAndConfirm(WidgetTester tester) async {
    await typeInto(tester, 'field_reset_uid', uid);
    await typeInto(tester, 'field_reset_reason', reason);
    await tapKey(tester, 'btn_reset_submit');
    await tester.enterText(find.byKey(const Key('field_confirm_phrase')), uid);
    await tester.pump();
    await tester.tap(find.byKey(const Key('btn_confirm_destructive')));
    await settle(tester);
  }

  group('SERVIS-01: sonuç ekranı', () {
    testWidgets('pending: bilgi notu (otomatik iletilecek, mevcut anahtar geçerli); yerel anahtar kartı YOK', (tester) async {
      final env = await openEmergency(tester);
      env.cloud.emergencyResetToReturn = const EmergencyResetResult(
        action: 'REASSIGNED',
        deviceUuid: uid,
        newOwner: ResetNewOwner(id: 'u2', fullName: 'Yeni Malik'),
        localKeyPublish: 'pending',
        deviceCredential: DeviceMqttCredential(host: 'broker.ornek.test', port: 8884, username: 'd_x', password: 'gizli', topicId: 'h_x'),
      );
      await submitAndConfirm(tester);

      expect(find.byKey(const Key('emergency_result')), findsOneWidget);
      expect(shown('reset_key_pending'), isTrue);
      final note = textOf(tester, 'reset_key_pending');
      expect(note, contains('otomatik iletilecek'));
      expect(note, contains('mevcut anahtarı geçerlidir'));
      expect(shown('reset_local_key'), isFalse, reason: 'yanıtta anahtar yok');
      expect(find.textContaining('yerinde'), findsNothing);
    });

    testWidgets('ESKİ sunucu yanıtı (local_key döndü): anahtar kartı + seri konsol RESETKEY + FACTORYINIT yönergesi', (tester) async {
      final env = await openEmergency(tester);
      env.cloud.emergencyResetToReturn = const EmergencyResetResult(
        action: 'UNCLAIMED',
        deviceUuid: uid,
        setupPin: '482916',
        localKeyPublish: 'skipped_offline',
        localKey: 'yerel-anahtar-ornek',
        partial: true,
        warnings: <String>['Cihaz çevrimdışı; yeni yerel anahtar cihaza iletilemedi, yerinde elle yazılmalıdır.'],
      );
      await submitAndConfirm(tester);

      expect(textOf(tester, 'reset_local_key'), 'yerel-anahtar-ornek');
      expect(shown('reset_key_pending'), isFalse);
      final hint = textOf(tester, 'reset_key_manual_hint');
      expect(hint, contains('seri konsolda'));
      expect(hint, contains('RESETKEY'));
      expect(hint, contains('FACTORYINIT'));
      expect(hint, contains('fabrika aracı'));
      expect(find.textContaining('yerinde girilmeli'), findsNothing, reason: 'uygulanamaz eski başlık kalktı');
    });
  });

  group('SERVIS-07: servis personeli kısıt notu', () {
    testWidgets('kalıcı servis personeli: formda 72 saat kısıt notu görünür', (tester) async {
      await openEmergency(tester, globalRole: 'service_user');
      expect(shown('reset_staff_scope_note'), isTrue);
      expect(textOf(tester, 'reset_staff_scope_note'), scopeNote);
    });

    testWidgets('süper yönetici: kısıt notu YOK', (tester) async {
      await openEmergency(tester);
      expect(shown('reset_staff_scope_note'), isFalse);
      expect(find.textContaining('son 72 saat'), findsNothing);
    });

    testWidgets('servis personeline 403: sunucu mesajı aynen + altında süper yönetici yönlendirmesi (tek kez)', (tester) async {
      final env = await openEmergency(tester, globalRole: 'service_user');
      env.cloud.emergencyError =
          apiError(403, 'Bu cihazın dairesinde servis yetkiniz yok. Süper yönetici ile iletişime geçin.', code: 'FORBIDDEN');
      await submitAndConfirm(tester);

      expect(textOf(tester, 'reset_error'), 'Bu cihazın dairesinde servis yetkiniz yok. Süper yönetici ile iletişime geçin.');
      expect(textOf(tester, 'reset_forbidden_hint'), scopeNote);
      expect(find.textContaining('son 72 saat'), findsOneWidget, reason: 'aynı not ekranda iki kez yazılmaz');
      expect(find.byKey(const Key('emergency_form')), findsOneWidget);
    });

    testWidgets('süper yöneticiye 403: yönlendirme eklenmez', (tester) async {
      final env = await openEmergency(tester);
      env.cloud.emergencyError = apiError(403, 'Bu cihazı yalnızca süper kullanıcı sıfırlayabilir.', code: 'FORBIDDEN');
      await submitAndConfirm(tester);

      expect(textOf(tester, 'reset_error'), 'Bu cihazı yalnızca süper kullanıcı sıfırlayabilir.');
      expect(shown('reset_forbidden_hint'), isFalse);
    });
  });

  // M2-F2 / KAÇAN: gerçek sözleşme yanıtları; M4-02: süper yöneticinin devri.
  group('Sonuç ekranı: bekleyen anahtar (gerçek yanıt) ve süper yönetici', () {
    const pendingWarning = 'Yeni yerel anahtar şu an panoya iletilemedi (pano ya da bulut bağlantısı yok). Pano buluta '
        'bağlandığında otomatik iletilecek; o zamana kadar panonun mevcut anahtarı geçerli kalır.';
    const childLockWarning = 'Pano çevrimdışı; çocuk kilidi sıfırlanamadı. Pano yerelde kilitli kalmış olabilir.';
    const superNote = 'Süper yönetici hesabına cihaz anahtarı verilmez ve bu devir servis personeline daire yetkisi '
        "vermez. Panoyu bağlamak için yeni sahibin uygulamasından servis PIN'i alınıp servis girişiyle sihirbaz açılmalı.";

    EmergencyResetResult pending(Map<String, dynamic> extra) => EmergencyResetResult.fromJson(<String, dynamic>{
          'action': 'REASSIGNED',
          'device_uuid': uid,
          'home_id': 'home-1',
          'new_owner': <String, dynamic>{'id': 'u2', 'full_name': 'Yeni Malik'},
          'local_key_publish': 'pending',
          'device_credential': <String, dynamic>{
            'host': 'broker.ornek.test',
            'port': 8884,
            'username': 'd_x',
            'password': 'gizli-sifre-ornek-123',
            'topic_id': 'h_x',
          },
          ...extra,
        });

    testWidgets('yalnız pending (partial:false): başlık uyarı değil, uyarı satırı yok, bilgi bir kez', (tester) async {
      final env = await openEmergency(tester);
      env.cloud.emergencyResetToReturn = pending(<String, dynamic>{'child_lock_reset': 'published', 'partial': false});
      await submitAndConfirm(tester);

      expect(textOf(tester, 'reset_headline'), isNot(contains('eksik kaldı')));
      expect(shown('reset_warning_0'), isFalse);
      expect(find.textContaining('otomatik ilet'), findsOneWidget);
    });

    testWidgets('pending + çocuk kilidi uyarısı + partial:true: yalnız çocuk kilidi uyarısı, bekleyen anahtar bir kez',
        (tester) async {
      final env = await openEmergency(tester);
      env.cloud.emergencyResetToReturn = pending(<String, dynamic>{
        'child_lock_reset': 'skipped_offline',
        'warnings': <String>[childLockWarning],
        'partial': true,
      });
      await submitAndConfirm(tester);

      expect(textOf(tester, 'reset_headline'), contains('eksik kaldı'));
      expect(textOf(tester, 'reset_warning_0'), childLockWarning);
      expect(shown('reset_warning_1'), isFalse);
      expect(find.textContaining('otomatik ilet'), findsOneWidget);
    });

    testWidgets('ESKİ sunucu (warnings içinde bekleyen anahtar uyarısı + partial:true): çift gösterim yok', (tester) async {
      final env = await openEmergency(tester);
      env.cloud.emergencyResetToReturn = pending(<String, dynamic>{
        'child_lock_reset': 'published',
        'warnings': <String>[pendingWarning],
        'partial': true,
      });
      await submitAndConfirm(tester);

      expect(textOf(tester, 'reset_headline'), isNot(contains('eksik kaldı')));
      expect(shown('reset_warning_0'), isFalse);
      expect(find.textContaining('otomatik ilet'), findsOneWidget);
      expect(find.textContaining('iletilemedi'), findsNothing);
    });

    testWidgets('süper + REASSIGNED + pending: sihirbaz yönlendirmesi yerine servis PIN yolu', (tester) async {
      final env = await openEmergency(tester);
      env.cloud.emergencyResetToReturn = pending(<String, dynamic>{'child_lock_reset': 'published'});
      await submitAndConfirm(tester);

      expect(textOf(tester, 'reset_super_note'), superNote);
      expect(shown('reset_credential_note'), isFalse, reason: 'süper için sihirbazın "Bulut Bağlantısı" adımı yol değil');
    });

    testWidgets('servis personeli + REASSIGNED + pending: sihirbaz notu var, süper notu yok', (tester) async {
      final env = await openEmergency(tester, globalRole: 'service_user');
      env.cloud.emergencyResetToReturn = pending(<String, dynamic>{'child_lock_reset': 'published'});
      await submitAndConfirm(tester);

      expect(shown('reset_credential_note'), isTrue);
      expect(shown('reset_super_note'), isFalse);
    });
  });
}
