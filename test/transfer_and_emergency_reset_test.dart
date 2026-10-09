import 'dart:async';

import 'package:ev_otomasyon/models/api_models.dart';
import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/ui/common/date_format.dart';
import 'package:ev_otomasyon/ui/pages/family/transfer_ownership_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/support.dart';
import 'ui/e2_support.dart';

/// Daire devri (yalnızca ev sahibi) ve acil pano sıfırlama (yalnızca süper kullanıcı / kalıcı servis
/// personeli): yetkiye göre sekmeler, zorunlu hedef, kendini hedefleme engeli, yazarak onay, sonuç
/// uyarıları ve tek seferlik gizli değerler.
void main() {
  Future<Opened<void>> open(WidgetTester tester, E2Env env, {int initialTab = 0}) {
    return openFromHost<void>(
      tester,
      env.state,
      (context) => TransferOwnershipDialog.show(context, initialTab: initialTab),
    );
  }

  /// Yazarak onay diyaloğunda ifadeyi yazıp onaylar.
  Future<void> confirmTyped(WidgetTester tester, String phrase) async {
    expect(find.byKey(const Key('field_confirm_phrase')), findsOneWidget, reason: 'yazarak onay diyaloğu açık olmalı');
    await tester.enterText(find.byKey(const Key('field_confirm_phrase')), phrase);
    await tester.pump();
    await tester.tap(find.byKey(const Key('btn_confirm_destructive')));
    await settle(tester);
  }

  group('sekmeler YETKİYE göre gösterilir', () {
    testWidgets('ev sahibi: yalnızca devir; acil sıfırlama sekmesi ve formu HİÇ yok', (tester) async {
      final env = e2Env(role: 'owner');
      await open(tester, env);

      expect(find.text('Daire Devri (Mülkiyet Transferi)'), findsOneWidget);
      expect(find.byKey(const Key('tab_emergency')), findsNothing);
      expect(find.byKey(const Key('tab_transfer')), findsNothing, reason: 'tek sekme: seçici gösterilmez');
      expect(find.byKey(const Key('transfer_form')), findsOneWidget);
      expect(find.byKey(const Key('emergency_form')), findsNothing);
    });

    testWidgets('ev sahibi `initialTab: 1` istese de acil sıfırlama açılmaz', (tester) async {
      final env = e2Env(role: 'owner');
      await open(tester, env, initialTab: 1);

      expect(find.byKey(const Key('emergency_form')), findsNothing);
      expect(find.byKey(const Key('transfer_form')), findsOneWidget);
    });

    testWidgets('süper kullanıcı: yalnızca acil sıfırlama (devir yetkisi yok); alanlar BOŞ (ön-dolu demo UUID yok)', (tester) async {
      final env = e2Env(role: null, globalRole: 'super_user');
      await open(tester, env);

      expect(find.text('Acil Pano Sıfırlama'), findsOneWidget);
      expect(find.byKey(const Key('transfer_form')), findsNothing);
      expect(find.byKey(const Key('emergency_form')), findsOneWidget);
      for (final key in <String>['field_reset_uid', 'field_reset_reason', 'field_reset_new_owner']) {
        expect(tester.widget<TextField>(find.byKey(Key(key))).controller!.text, isEmpty, reason: key);
      }
    });

    testWidgets('kalıcı servis personeli de acil sıfırlamayı görür', (tester) async {
      final env = e2Env(role: null, globalRole: 'service_user');
      await open(tester, env);
      expect(find.byKey(const Key('emergency_form')), findsOneWidget);
    });

    testWidgets('aile üyesi / misafir: iki sekme de yok, açık "yetkiniz yok" mesajı', (tester) async {
      for (final role in <String>['resident', 'guest']) {
        final env = e2Env(
          role: role,
          home: role == 'guest'
              ? HomeModel(
                  id: kHomeA,
                  name: 'Ev A',
                  role: 'guest',
                  guestValidFrom: kTestNow.subtract(const Duration(hours: 1)),
                  guestValidUntil: kTestNow.add(const Duration(hours: 2)),
                )
              : null,
        );
        await open(tester, env);

        expect(find.byKey(const Key('transfer_forbidden')), findsOneWidget, reason: role);
        expect(find.byKey(const Key('transfer_form')), findsNothing, reason: role);
        expect(find.byKey(const Key('emergency_form')), findsNothing, reason: role);
        await tapKey(tester, 'btn_close');
      }
    });

    testWidgets('her iki yetkisi olan kullanıcı (ev sahibi + servis personeli) sekmeler arasında geçebilir', (tester) async {
      final env = e2Env(role: 'owner', globalRole: 'service_user');
      await open(tester, env);
      expect(find.byKey(const Key('tab_transfer')), findsOneWidget);
      expect(find.byKey(const Key('tab_emergency')), findsOneWidget);
      expect(find.byKey(const Key('transfer_form')), findsOneWidget);

      await tapKey(tester, 'tab_emergency');
      expect(find.byKey(const Key('emergency_form')), findsOneWidget);
      expect(find.byKey(const Key('transfer_form')), findsNothing);

      await tapKey(tester, 'tab_transfer');
      expect(find.byKey(const Key('transfer_form')), findsOneWidget);
    });

    testWidgets('`initialTab: 1` yetkili kullanıcıda doğrudan acil sıfırlamayı açar', (tester) async {
      final env = e2Env(role: 'owner', globalRole: 'service_user');
      await open(tester, env, initialTab: 1);
      expect(find.byKey(const Key('emergency_form')), findsOneWidget);
    });
  });

  group('daire devri: hedef ZORUNLU, doğrulanır, yazarak onaylanır', () {
    testWidgets('hedef boşken devir başlatılamaz; onay diyaloğu açılmaz, sunucuya gidilmez', (tester) async {
      final env = e2Env();
      await open(tester, env);

      await tapKey(tester, 'btn_initiate_transfer');

      expect(find.textContaining('zorunludur'), findsOneWidget);
      expect(find.byKey(const Key('field_confirm_phrase')), findsNothing);
      expect(env.cloud.initiatedTargets, isEmpty);
    });

    testWidgets('geçersiz hedef biçimi reddedilir', (tester) async {
      final env = e2Env();
      await open(tester, env);

      await typeInto(tester, 'field_transfer_target', 'bu-bir-adres-degil');
      await tapKey(tester, 'btn_initiate_transfer');

      expect(find.text('Geçerli bir e-posta adresi veya telefon numarası girin.'), findsOneWidget);
      expect(env.cloud.initiatedTargets, isEmpty);
    });

    testWidgets('kendini hedefleme engellenir (e-posta büyük/küçük harf ve telefon biçimi fark etmez)', (tester) async {
      final env = e2Env();
      await open(tester, env);

      await typeInto(tester, 'field_transfer_target', ' AYSE@ORNEK.TEST ');
      await tapKey(tester, 'btn_initiate_transfer');
      expect(find.text('Dairenizi kendinize devredemezsiniz.'), findsOneWidget);

      await typeInto(tester, 'field_transfer_target', '0555 111 22 33');
      await tapKey(tester, 'btn_initiate_transfer');
      expect(find.text('Dairenizi kendinize devredemezsiniz.'), findsOneWidget);
      expect(env.cloud.initiatedTargets, isEmpty);
    });

    testWidgets('"X kullanıcısına devredilecek" onayı YAZARAK alınır; vazgeçilirse devir başlamaz', (tester) async {
      final env = e2Env(home: testHome(role: 'owner', name: 'Kadıköy Daire 4'));
      await open(tester, env);
      await typeInto(tester, 'field_transfer_target', 'Yeni.Malik@Ornek.test');

      await tapKey(tester, 'btn_initiate_transfer');

      expect(find.textContaining('"Kadıköy Daire 4" dairesi yeni.malik@ornek.test kullanıcısına devredilecek'), findsOneWidget);
      expect(env.cloud.initiatedTargets, isEmpty, reason: 'onaydan önce devir başlamaz');
      // yanlış ifade ile onaylanamaz
      await tester.enterText(find.byKey(const Key('field_confirm_phrase')), 'EVET');
      await tester.pump();
      expect(tester.widget<ElevatedButton>(find.byKey(const Key('btn_confirm_destructive'))).onPressed, isNull);

      await tapKey(tester, 'btn_cancel_destructive');
      expect(env.cloud.initiatedTargets, isEmpty);
      expect(find.byKey(const Key('transfer_form')), findsOneWidget);
    });

    testWidgets('onaylanınca devir başlar: hedef normalleştirilir; kod, QR, hedef ve YEREL bitiş saati gösterilir', (tester) async {
      final env = e2Env();
      env.cloud.transferToReturn = TransferInfo(code: 'AHBU-TR-QWERTY123456', expiresAt: DateTime.utc(2026, 10, 3, 22, 45));
      await open(tester, env);
      await typeInto(tester, 'field_transfer_target', '0555 987 65 43');

      await tapKey(tester, 'btn_initiate_transfer');
      await confirmTyped(tester, 'devret');

      expect(env.cloud.initiatedTargets, <String>['+905559876543']);
      expect(find.byKey(const Key('transfer_active')), findsOneWidget);
      expect(textOf(tester, 'transfer_code'), 'AHBU-TR-QWERTY123456');
      expect(find.byKey(const ValueKey<String>('qr_payload:AHBU-TRANSFER:AHBU-TR-QWERTY123456')), findsOneWidget);
      expect(textOf(tester, 'transfer_target_text'), 'Yalnızca +905559876543 kullanıcısı devralabilir.');
      expect(textOf(tester, 'transfer_expiry_text'), 'Son geçerlilik: ${formatLocalDateTime(DateTime.utc(2026, 10, 3, 22, 45))}');
    });

    testWidgets('sunucu devri reddederse Türkçe hata gösterilir ve form açık kalır', (tester) async {
      final env = e2Env();
      env.cloud.initiateError = apiError(403, 'Bu işlem için yetkiniz yok.', code: 'FORBIDDEN');
      await open(tester, env);
      await typeInto(tester, 'field_transfer_target', 'malik@ornek.test');

      await tapKey(tester, 'btn_initiate_transfer');
      await confirmTyped(tester, 'DEVRET');

      expect(textOf(tester, 'transfer_error'), 'Bu işlem için yetkiniz yok.');
      expect(find.byKey(const Key('transfer_form')), findsOneWidget);
    });
  });

  group('bekleyen devir', () {
    testWidgets('kod GÖSTERİLMEZ (sunucuda yalnızca özet var); hedef ve bitiş gösterilir; iptal edilince form gelir', (tester) async {
      final env = e2Env();
      env.cloud.pendingTransfer = <String, dynamic>{
        'id': 't1',
        'target_identifier': 'bekleyen@ornek.test',
        'status': 'PENDING',
        'expires_at': '2026-10-03T10:00:00.000Z',
      };
      await open(tester, env);

      expect(find.byKey(const Key('transfer_active')), findsOneWidget);
      expect(find.byKey(const Key('transfer_code')), findsNothing);
      expect(find.byKey(const Key('transfer_code_hidden')), findsOneWidget);
      expect(textOf(tester, 'transfer_target_text'), 'Yalnızca bekleyen@ornek.test kullanıcısı devralabilir.');
      expect(textOf(tester, 'transfer_expiry_text'), 'Son geçerlilik: ${formatLocalDateTime(DateTime.utc(2026, 10, 3, 10))}');

      await tapKey(tester, 'btn_cancel_transfer');

      expect(env.cloud.calls, contains('cancelTransfer'));
      expect(find.byKey(const Key('transfer_form')), findsOneWidget);
      expect(find.byKey(const Key('transfer_active')), findsNothing);
    });

    testWidgets('durum yüklenemezse hata + "Tekrar Dene"; yeniden deneyince form gelir', (tester) async {
      final env = e2Env();
      env.cloud.transferStatusError = apiError(0, 'Sunucuya ulaşılamadı.', code: 'NETWORK');
      await open(tester, env);

      expect(textOf(tester, 'transfer_error'), 'Sunucuya ulaşılamadı.');
      expect(find.byType(CircularProgressIndicator), findsNothing);

      env.cloud.transferStatusError = null;
      await tapKey(tester, 'btn_transfer_retry');
      expect(find.byKey(const Key('transfer_form')), findsOneWidget);
    });

    testWidgets('yanıt hiç gelmezse 15 sn sonra zaman aşımı hatası gösterilir (sonsuz spinner yok)', (tester) async {
      final env = e2Env();
      env.cloud.transferStatusGate = Completer<void>();
      await open(tester, env);
      expect(find.byKey(const Key('transfer_loading')), findsOneWidget);

      await tester.pump(const Duration(seconds: 16));

      expect(find.byKey(const Key('transfer_error')), findsOneWidget);
      expect(find.byKey(const Key('btn_transfer_retry')), findsOneWidget);
    });

    testWidgets('iptal hatası dostu mesajla gösterilir', (tester) async {
      final env = e2Env();
      env.cloud.pendingTransfer = <String, dynamic>{'target_identifier': 'a@b.test', 'expires_at': '2026-10-03T10:00:00Z'};
      env.cloud.cancelTransferError = apiError(500, 'Sunucu şu anda yanıt veremiyor.');
      await open(tester, env);

      await tapKey(tester, 'btn_cancel_transfer');

      expect(textOf(tester, 'transfer_error'), 'Sunucu şu anda yanıt veremiyor.');
      expect(find.byKey(const Key('transfer_active')), findsOneWidget);
    });
  });

  group('acil sıfırlama (süper kullanıcı / servis personeli)', () {
    const uid = 'AHBU-S3-A1B2C3';
    const reason = 'Kiracı tahliye edildi, sözleşme ibraz edildi';

    Future<E2Env> openEmergency(WidgetTester tester) async {
      final env = e2Env(role: null, globalRole: 'super_user');
      await open(tester, env);
      return env;
    }

    testWidgets('boş / geçersiz UID, kısa gerekçe ve geçersiz yeni sahip alan hatası verir; sunucuya gidilmez', (tester) async {
      final env = await openEmergency(tester);

      await tapKey(tester, 'btn_reset_submit');
      expect(find.text('Cihaz kimliğini (UID) girin veya etiketini tarayın.'), findsOneWidget);
      expect(find.text('Gerekçe en az 15 karakter olmalıdır.'), findsOneWidget);

      await typeInto(tester, 'field_reset_uid', 'ABC-123');
      await typeInto(tester, 'field_reset_reason', 'kısa gerekçe');
      await typeInto(tester, 'field_reset_new_owner', 'gecersiz');
      await tapKey(tester, 'btn_reset_submit');
      expect(find.text('Geçerli bir cihaz kimliği girin (AHBU- ile başlar).'), findsOneWidget);
      expect(find.text('Gerekçe en az 15 karakter olmalıdır.'), findsOneWidget);
      expect(find.text('Geçerli bir e-posta adresi veya telefon numarası girin.'), findsOneWidget);
      expect(env.cloud.emergencyArgs, isEmpty);
    });

    testWidgets('kendini yeni sahip olarak atayamaz', (tester) async {
      final env = await openEmergency(tester);
      await typeInto(tester, 'field_reset_uid', uid);
      await typeInto(tester, 'field_reset_reason', reason);
      await typeInto(tester, 'field_reset_new_owner', kUserEmail);

      await tapKey(tester, 'btn_reset_submit');

      expect(find.text('Kendinizi yeni sahip olarak atayamazsınız.'), findsOneWidget);
      expect(env.cloud.emergencyArgs, isEmpty);
    });

    testWidgets('cihaz UID\'si YAZARAK teyit edilir (confirmUid); yanlış UID ile onaylanamaz', (tester) async {
      final env = await openEmergency(tester);
      await typeInto(tester, 'field_reset_uid', uid.toLowerCase());
      await typeInto(tester, 'field_reset_reason', reason);

      await tapKey(tester, 'btn_reset_submit');
      expect(find.textContaining('AHBU-S3-A1B2C3 kimlikli cihaz sıfırlanacak'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('field_confirm_phrase')), 'AHBU-S3-FFFFFF');
      await tester.pump();
      expect(tester.widget<ElevatedButton>(find.byKey(const Key('btn_confirm_destructive'))).onPressed, isNull);
      expect(env.cloud.emergencyArgs, isEmpty);

      await confirmTyped(tester, 'ahbu-s3-a1b2c3');

      final args = env.cloud.emergencyArgs.single;
      expect(args['uid'], uid, reason: 'normalleştirilmiş (büyük harf)');
      expect(args['confirm'], uid);
      expect(args['reasonLength'], reason.length);
      expect(args['newOwner'], isNull);
    });

    testWidgets('UNCLAIMED: tek seferlik yeni kurulum PIN\'i gösterilir (kopyalanabilir)', (tester) async {
      final env = await openEmergency(tester);
      env.cloud.emergencyResetToReturn = const EmergencyResetResult(
        action: 'UNCLAIMED',
        deviceUuid: uid,
        affectedUsersCount: 3,
        setupPin: '482916',
      );
      await typeInto(tester, 'field_reset_uid', uid);
      await typeInto(tester, 'field_reset_reason', reason);

      await tapKey(tester, 'btn_reset_submit');
      await confirmTyped(tester, uid);

      expect(find.byKey(const Key('emergency_result')), findsOneWidget);
      expect(textOf(tester, 'reset_headline'), 'Cihaz sıfırlandı ve stoğa alındı.');
      expect(textOf(tester, 'reset_affected'), '3 kullanıcının erişimi kaldırıldı.');
      expect(textOf(tester, 'reset_setup_pin'), '482916');
      expect(find.byKey(const Key('btn_copy_setup_pin')), findsOneWidget);
    });

    testWidgets('kısmi başarı (HTTP 200 + partial + warnings): uyarılar ve eksik yerel anahtar GÖSTERİLİR', (tester) async {
      final env = await openEmergency(tester);
      env.cloud.emergencyResetToReturn = EmergencyResetResult(
        action: 'REASSIGNED',
        deviceUuid: uid,
        newOwner: const ResetNewOwner(id: 'u2', fullName: 'Yeni Malik'),
        partial: true,
        warnings: const <String>['Pano çevrimdışı: yerel anahtar iletilemedi.', 'Eski MQTT bağlantıları kesilemedi.'],
        localKey: 'yerel-anahtar-ornek',
        deviceCredential: const DeviceMqttCredential(host: 'broker.ornek.test', port: 8884, username: 'd_x', password: 'gizli-sifre-ornek', topicId: 'h_x'),
      );
      await typeInto(tester, 'field_reset_uid', uid);
      await typeInto(tester, 'field_reset_reason', reason);
      await typeInto(tester, 'field_reset_new_owner', 'Yeni.Malik@Ornek.test');

      await tapKey(tester, 'btn_reset_submit');
      await confirmTyped(tester, uid);

      expect(env.cloud.emergencyArgs.single['newOwner'], 'yeni.malik@ornek.test');
      expect(textOf(tester, 'reset_headline'), contains('Cihaz Yeni Malik hesabına devredildi.'));
      expect(textOf(tester, 'reset_headline'), contains('Bazı adımlar eksik kaldı'));
      expect(textOf(tester, 'reset_warning_0'), 'Pano çevrimdışı: yerel anahtar iletilemedi.');
      expect(textOf(tester, 'reset_warning_1'), 'Eski MQTT bağlantıları kesilemedi.');
      expect(textOf(tester, 'reset_local_key'), 'yerel-anahtar-ornek');
      // Süper yöneticiye sunucu yerel anahtar vermez (M4-02): sihirbaz notu yerine servis PIN yolu yazılır.
      expect(find.byKey(const Key('reset_credential_note')), findsNothing);
      expect(find.byKey(const Key('reset_super_note')), findsOneWidget);
      // Bulut kimliği parolası ekranda GÖSTERİLMEZ.
      expect(find.textContaining('gizli-sifre-ornek'), findsNothing);
    });

    testWidgets('uyarı listesi boş ama partial=true ise yine de açıklayıcı uyarı gösterilir', (tester) async {
      final env = await openEmergency(tester);
      env.cloud.emergencyResetToReturn = const EmergencyResetResult(action: 'UNCLAIMED', deviceUuid: uid, partial: true);
      await typeInto(tester, 'field_reset_uid', uid);
      await typeInto(tester, 'field_reset_reason', reason);

      await tapKey(tester, 'btn_reset_submit');
      await confirmTyped(tester, uid);

      expect(textOf(tester, 'reset_warning_0'), contains('kısmen tamamlandı'));
    });

    testWidgets('sunucu hatası dostu mesajla gösterilir; form açık kalır, sonuç ekranı gelmez', (tester) async {
      final env = await openEmergency(tester);
      env.cloud.emergencyError = apiError(403, 'Bu cihazı yalnızca süper kullanıcı sıfırlayabilir.', code: 'FORBIDDEN');
      await typeInto(tester, 'field_reset_uid', uid);
      await typeInto(tester, 'field_reset_reason', reason);

      await tapKey(tester, 'btn_reset_submit');
      await confirmTyped(tester, uid);

      expect(textOf(tester, 'reset_error'), 'Bu cihazı yalnızca süper kullanıcı sıfırlayabilir.');
      expect(find.byKey(const Key('emergency_result')), findsNothing);
      expect(find.byKey(const Key('emergency_form')), findsOneWidget);
    });

    testWidgets('onay vazgeçilirse sunucuya istek gitmez', (tester) async {
      final env = await openEmergency(tester);
      await typeInto(tester, 'field_reset_uid', uid);
      await typeInto(tester, 'field_reset_reason', reason);

      await tapKey(tester, 'btn_reset_submit');
      await tapKey(tester, 'btn_cancel_destructive');

      expect(env.cloud.emergencyArgs, isEmpty);
    });
  });
}
