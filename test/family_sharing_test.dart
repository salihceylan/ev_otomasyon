import 'dart:async';

import 'package:ev_otomasyon/models/api_models.dart';
import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/services/ev_cloud_api_service.dart';
import 'package:ev_otomasyon/ui/common/date_format.dart';
import 'package:ev_otomasyon/ui/pages/family/invite_family_dialog.dart';
import 'package:ev_otomasyon/ui/pages/family/join_home_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'support/support.dart';
import 'ui/e2_support.dart';

/// Aile daveti (üretim kuralları, yarış, yerel saat) ve eve katılma / devir kabulü (normalleştirme,
/// önizleme + onay adımı, yıkıcı onay).
void main() {
  group('InviteFamilyDialog', () {
    Future<Opened<void>> open(WidgetTester tester, E2Env env) {
      return openFromHost<void>(tester, env.state, (context) => InviteFamilyDialog.show(context));
    }

    testWidgets('açılışta OTOMATİK kod üretilmez; yalnızca "Üret" düğmesiyle üretilir', (tester) async {
      final env = e2Env();
      await open(tester, env);

      expect(env.cloud.calls.contains('createInvitation'), isFalse, reason: 'sunucuda gereksiz davet bırakılmaz');
      expect(find.byKey(const Key('invite_member_code')), findsNothing);
      expect(find.byKey(const Key('btn_generate_member_invite')), findsOneWidget);

      await tapKey(tester, 'btn_generate_member_invite');

      expect(env.cloud.inviteArgs, hasLength(1));
      expect(find.byKey(const Key('invite_member_code')), findsOneWidget);
      expect(textOf(tester, 'invite_member_code'), 'AHBU-FAMILY1234');
    });

    testWidgets('aile daveti rolü `resident` olarak gider (eski `member` DEĞİL) ve QR içeriği AHBU-INVITE: önekli', (tester) async {
      final env = e2Env();
      await open(tester, env);

      await tapKey(tester, 'btn_generate_member_invite');

      expect(env.cloud.inviteArgs.single['role'], 'resident');
      expect(env.cloud.inviteArgs.single['hours'], isNull);
      expect(find.byKey(const ValueKey<String>('qr_payload:AHBU-INVITE:AHBU-FAMILY1234')), findsOneWidget);
      expect(find.byType(QrImageView), findsOneWidget);
    });

    testWidgets('sunucunun UTC bitiş zamanı YEREL saatle gösterilir', (tester) async {
      final env = e2Env();
      env.cloud.invitationToReturn = InvitationModel(
        code: 'AHBU-UTCTEST123',
        role: 'resident',
        expiresAt: DateTime.utc(2026, 10, 2, 23, 30),
      );
      await open(tester, env);

      await tapKey(tester, 'btn_generate_member_invite');

      final local = DateTime.utc(2026, 10, 2, 23, 30).toLocal();
      expect(textOf(tester, 'invite_member_expiry'), 'Son geçerlilik: ${formatLocalDateTime(local)}');
      expect(
        textOf(tester, 'invite_member_expiry'),
        contains('${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}'),
        reason: 'saat yerel saat diliminde (UTC alanları değil)',
      );
      // Saat dilimi UTC olmayan makinede (geliştirici/QA telefonu) ham UTC saati ASLA yazılmaz. (UTC
      // makinede yerel = UTC olduğundan bu denetim anlamsızdır: yalnızca üstteki biçimleme denetimi kalır.)
      if (local.timeZoneOffset != Duration.zero) {
        expect(textOf(tester, 'invite_member_expiry'), isNot(contains('23:30')), reason: 'UTC saati gösterilmemeli');
      }
    });

    test('formatLocalDateTime: UTC değeri yerel saate çevirir; UTC alanlarını (yerel dilim UTC değilse) yazmaz', () {
      final utc = DateTime.utc(2026, 10, 2, 23, 30);
      // Beklenen değer biçimleyiciden BAĞIMSIZ hesaplanır: aynı anın yerel alanları.
      final local = DateTime.fromMillisecondsSinceEpoch(utc.millisecondsSinceEpoch);
      String two(int v) => v.toString().padLeft(2, '0');
      final expected = '${two(local.day)}.${two(local.month)}.${local.year} ${two(local.hour)}:${two(local.minute)}';

      expect(formatLocalDateTime(utc), expected);
      expect(formatLocalDateTime(local), expected, reason: 'yerel değer de aynı anı aynı yazar');
      if (local.timeZoneOffset != Duration.zero) {
        expect(formatLocalDateTime(utc), isNot('02.10.2026 23:30'));
      }
    });

    testWidgets('misafir süre çipleri YALNIZCA seçimdir: seçmek kod üretmez; üst sınır 72 saat', (tester) async {
      final env = e2Env();
      await open(tester, env);
      await tapText(tester, 'Süreli Misafir');

      for (final hours in <int>[2, 4, 24, 48, 72]) {
        await tapKey(tester, 'chip_guest_$hours');
      }
      expect(env.cloud.calls.contains('createInvitation'), isFalse, reason: 'çip seçimi kod üretmez');
      expect(find.byKey(const Key('invite_guest_code')), findsNothing);
      expect(find.byKey(const Key('chip_guest_96')), findsNothing, reason: '72 saatten uzun seçenek yok');
      expect(find.textContaining('En fazla 72 saat'), findsOneWidget);

      await typeInto(tester, 'field_guest_name', '  Temizlikçi Fatma  ');
      await tapKey(tester, 'btn_generate_guest_invite');

      final args = env.cloud.inviteArgs.single;
      expect(args['role'], 'guest');
      expect(args['hours'], 72, reason: 'son seçilen süre');
      expect(args['guestName'], 'Temizlikçi Fatma');
      expect(textOf(tester, 'invite_guest_code'), 'AHBU-GUEST12345');
      final until = DateTime.utc(2026, 10, 1, 20, 30);
      expect(textOf(tester, 'invite_guest_until'), 'Son erişim: ${formatLocalDateTime(until)}');
    });

    testWidgets('bayat yanıt yeni üretimi ezmez: "Vazgeç"ten sonra gelen eski sonuç yok sayılır', (tester) async {
      final env = e2Env();
      final first = Completer<InvitationModel>();
      final second = Completer<InvitationModel>();
      env.cloud.inviteHandler = (index, role) => index == 0 ? first.future : second.future;
      await open(tester, env);

      await tapKey(tester, 'btn_generate_member_invite'); // 1. istek (yavaş)
      expect(find.byKey(const Key('btn_invite_cancel_pending')), findsOneWidget);
      await tapKey(tester, 'btn_invite_cancel_pending'); // vazgeç
      await tapKey(tester, 'btn_generate_member_invite'); // 2. istek

      second.complete(InvitationModel(code: 'AHBU-YENIKOD0001', role: 'resident', expiresAt: kTestNow.add(const Duration(hours: 24))));
      await settle(tester);
      expect(textOf(tester, 'invite_member_code'), 'AHBU-YENIKOD0001');

      first.complete(InvitationModel(code: 'AHBU-ESKIKOD0001', role: 'resident', expiresAt: kTestNow.add(const Duration(hours: 24))));
      await settle(tester);
      expect(textOf(tester, 'invite_member_code'), 'AHBU-YENIKOD0001', reason: 'gecikmiş eski yanıt ekranı değiştirmez');
    });

    testWidgets('vazgeçilen istek, yanıtı gelse bile ekranda kod göstermez', (tester) async {
      final env = e2Env();
      final gate = Completer<InvitationModel>();
      env.cloud.inviteHandler = (index, role) => gate.future;
      await open(tester, env);
      await tapKey(tester, 'btn_generate_member_invite');
      await tapKey(tester, 'btn_invite_cancel_pending');

      gate.complete(InvitationModel(code: 'AHBU-HAYALET0001', role: 'resident', expiresAt: kTestNow));
      await settle(tester);

      expect(find.byKey(const Key('invite_member_code')), findsNothing);
      expect(find.byKey(const Key('btn_generate_member_invite')), findsOneWidget);
    });

    testWidgets('diyalog kapanırken bekleyen yanıt gelirse hata oluşmaz', (tester) async {
      final env = e2Env();
      final gate = Completer<InvitationModel>();
      env.cloud.inviteHandler = (index, role) => gate.future;
      await open(tester, env);
      await tapKey(tester, 'btn_generate_member_invite');
      await tapKey(tester, 'btn_close');
      expect(find.byType(InviteFamilyDialog), findsNothing);

      gate.complete(InvitationModel(code: 'AHBU-GEC00000001', role: 'resident', expiresAt: kTestNow));
      await settle(tester);

      expect(tester.takeException(), isNull);
    });

    testWidgets('sunucu hatası Türkçe gösterilir ve yeniden denenebilir', (tester) async {
      final env = e2Env();
      env.cloud.inviteError = apiError(409, 'Bu ev için çok fazla aktif davet var.', code: 'CONFLICT');
      await open(tester, env);

      await tapKey(tester, 'btn_generate_member_invite');
      expect(textOf(tester, 'invite_member_error'), 'Bu ev için çok fazla aktif davet var.');
      expect(find.textContaining('Exception'), findsNothing);

      env.cloud.inviteError = null;
      await tapKey(tester, 'btn_generate_member_invite');
      expect(find.byKey(const Key('invite_member_code')), findsOneWidget);
      expect(find.byKey(const Key('invite_member_error')), findsNothing);
    });

    testWidgets('davet yetkisi olmayan rol (aile üyesi) üretim yapamaz', (tester) async {
      final env = e2Env(role: 'resident');
      await open(tester, env);

      expect(find.byKey(const Key('invite_forbidden')), findsOneWidget);
      expect(find.byKey(const Key('btn_generate_member_invite')), findsNothing);
      expect(env.cloud.calls.contains('createInvitation'), isFalse);
    });

    testWidgets('başlangıç kodu verilirse (QR gösterimi) üretim yapmadan kodu gösterir', (tester) async {
      final env = e2Env();
      await pumpApp(
        tester,
        state: env.state,
        child: const Scaffold(body: InviteFamilyDialog(initialInviteCode: 'AHBU-TEST99', initialHomeName: 'Kadıköy Daire 4')),
      );

      expect(find.text('AHBU-TEST99'), findsOneWidget);
      expect(find.textContaining('Kadıköy Daire 4'), findsWidgets);
      expect(env.cloud.calls.contains('createInvitation'), isFalse);
    });
  });

  group('parseJoinCode (kod normalleştirme)', () {
    test('davet kodları: kırpma, büyük harf, boşluk atma, önek tamamlama', () {
      for (final raw in <String>['ahbu-ab12cd34ef', '  AHBU-AB12CD34EF ', 'ab12cd34ef', 'AHBU-INVITE:AHBU-AB12CD34EF', 'ahbu-invite:ab12cd34ef', 'ahbu - ab12 cd34 ef']) {
        final parsed = parseJoinCode(raw);
        expect(parsed, isNotNull, reason: raw);
        expect(parsed!.code, 'AHBU-AB12CD34EF', reason: raw);
        expect(parsed.isTransfer, isFalse, reason: raw);
      }
    });

    test('devir kodları: AHBU-TR- ve AHBU-TRANSFER: biçimleri devir olarak tanınır', () {
      for (final raw in <String>['AHBU-TR-ABCDEF123456', 'ahbu-tr-abcdef123456', 'AHBU-TRANSFER:AHBU-TR-ABCDEF123456', 'ahbu-transfer:abcdef123456']) {
        final parsed = parseJoinCode(raw);
        expect(parsed, isNotNull, reason: raw);
        expect(parsed!.code, 'AHBU-TR-ABCDEF123456', reason: raw);
        expect(parsed.isTransfer, isTrue, reason: raw);
      }
    });

    test('geçersiz girişler null döner', () {
      for (final bad in <String>['', '   ', 'AHBU-', 'x', 'AHBU-!!!!!!', 'AHBU-TR-12', 'A' * 90, 'AHBU-INVITE:']) {
        expect(parseJoinCode(bad), isNull, reason: bad);
      }
      expect(parseJoinCode(null), isNull);
    });
  });

  group('JoinHomeDialog (önizleme + onay)', () {
    Future<Opened<bool>> open(WidgetTester tester, E2Env env, {String? initialCode}) {
      return openFromHost<bool>(tester, env.state, (context) => JoinHomeDialog.show(context, initialCode: initialCode));
    }

    testWidgets('boş/geçersiz kod adımı geçmez; sunucuya hiçbir şey gitmez', (tester) async {
      final env = e2Env(role: null);
      await open(tester, env);

      await tapKey(tester, 'btn_join_continue');
      expect(find.text('Lütfen davet kodunu girin'), findsOneWidget);

      await typeInto(tester, 'field_join_code', 'x');
      await tapKey(tester, 'btn_join_continue');
      expect(find.text('Geçerli bir davet veya devir kodu girin'), findsOneWidget);
      expect(env.cloud.calls, isEmpty);
    });

    testWidgets('davet: kod normalleştirilir, ÖNİZLEME (ev adı + sakin sayısı) gösterilir, onay sonrası katılınır', (tester) async {
      final env = e2Env(role: null);
      env.cloud.previewToReturn = const JoinCodePreview(isTransfer: false, homeName: 'Kadıköy Daire 4', residentCount: 3, role: 'resident');
      final opened = await open(tester, env);

      await typeInto(tester, 'field_join_code', ' ahbu-ab12cd34ef ');
      await tapKey(tester, 'btn_join_continue');

      expect(env.cloud.previewCodes, <String>['AHBU-AB12CD34EF'], reason: 'önizleme normalleştirilmiş kodla istenir');
      expect(textOf(tester, 'join_preview_home'), 'Kadıköy Daire 4');
      expect(textOf(tester, 'join_preview_residents'), '3 kişi');
      expect(env.cloud.joinCodes, isEmpty, reason: 'onaydan ÖNCE katılım yapılmaz');
      expect(find.byKey(const Key('field_join_confirm_phrase')), findsNothing, reason: 'davet yıkıcı değildir');

      await tapKey(tester, 'btn_join_confirm');

      expect(env.cloud.joinCodes, <String>['AHBU-AB12CD34EF']);
      expect(opened.result, isTrue);
    });

    testWidgets('misafir daveti önizlemesi: erişim penceresi YEREL saatle gösterilir', (tester) async {
      final env = e2Env(role: null);
      env.cloud.previewToReturn = JoinCodePreview(
        isTransfer: false,
        homeName: 'Kadıköy Daire 4',
        residentCount: 2,
        role: 'guest',
        guestValidFrom: DateTime.utc(2026, 10, 1, 12),
        guestValidUntil: DateTime.utc(2026, 10, 2, 8, 30),
      );
      await open(tester, env);

      await typeInto(tester, 'field_join_code', 'AHBU-AB12CD34EF');
      await tapKey(tester, 'btn_join_continue');

      expect(textOf(tester, 'join_preview_guest_from'), formatLocalDateTime(DateTime.utc(2026, 10, 1, 12)));
      expect(textOf(tester, 'join_preview_guest_until'), formatLocalDateTime(DateTime.utc(2026, 10, 2, 8, 30)));
      expect(find.text('Süreli misafir'), findsOneWidget);
    });

    testWidgets('kullanıcı dairenin zaten üyesiyse önizleme bunu bildirir (davet tüketilmez)', (tester) async {
      final env = e2Env(role: null);
      env.cloud.previewToReturn = const JoinCodePreview(isTransfer: false, homeName: 'Kadıköy Daire 4', role: 'resident', alreadyMember: true);
      await open(tester, env);

      await typeInto(tester, 'field_join_code', 'AHBU-AB12CD34EF');
      await tapKey(tester, 'btn_join_continue');

      expect(find.byKey(const Key('join_already_member')), findsOneWidget);
    });

    test('sunucunun gerçek önizleme gövdesi (home_name, resident_count, already_member, guest_valid_*) doğru okunur', () {
      final preview = JoinCodePreview.fromJson(<String, dynamic>{
        'kind': 'invitation',
        'is_transfer': false,
        'home_name': 'Kadıköy Daire 4',
        'resident_count': 3,
        'role': 'guest',
        'expires_at': '2026-10-02T12:00:00.000Z',
        'already_member': true,
        'guest_valid_from': '2026-10-01T12:00:00.000Z',
        'guest_valid_until': '2026-10-02T08:30:00.000Z',
      });

      expect(preview.isTransfer, isFalse);
      expect(preview.homeName, 'Kadıköy Daire 4');
      expect(preview.residentCount, 3);
      expect(preview.role, 'guest');
      expect(preview.alreadyMember, isTrue);
      expect(preview.guestValidUntil, DateTime.utc(2026, 10, 2, 8, 30));
      expect(JoinCodePreview.fromJson(<String, dynamic>{'kind': 'transfer', 'home_name': 'Villa'}).isTransfer, isTrue);
    });

    testWidgets('önizleme ucu yoksa (sunucu desteklemiyor) bilgi notu gösterilir; yine de onay adımı vardır', (tester) async {
      final env = e2Env(role: null);
      env.cloud.previewToReturn = null;
      await open(tester, env);

      await typeInto(tester, 'field_join_code', 'AHBU-AB12CD34EF');
      await tapKey(tester, 'btn_join_continue');

      expect(find.byKey(const Key('join_preview_unavailable')), findsOneWidget);
      expect(textOf(tester, 'join_preview_home'), 'Onaydan sonra görünür');
      expect(env.cloud.joinCodes, isEmpty);
    });

    testWidgets('devir kodu YIKICI sayılır: uyarı + "DEVRAL" yazarak onay olmadan kabul edilmez', (tester) async {
      final env = e2Env(role: null);
      env.cloud.previewToReturn = const JoinCodePreview(isTransfer: true, homeName: 'Villa Merkez', residentCount: 4, role: 'owner');
      final opened = await open(tester, env);

      await typeInto(tester, 'field_join_code', 'AHBU-TRANSFER:ABCDEF123456');
      await tapKey(tester, 'btn_join_continue');

      expect(find.byKey(const Key('join_transfer_warning')), findsOneWidget);
      expect(textOf(tester, 'join_preview_home'), 'Villa Merkez');
      expect(textOf(tester, 'join_preview_residents'), '4 kişi');
      ElevatedButton confirm() => tester.widget<ElevatedButton>(find.byKey(const Key('btn_join_confirm')));
      expect(confirm().onPressed, isNull, reason: 'ifade yazılmadan onay yok');

      await typeInto(tester, 'field_join_confirm_phrase', 'devral');
      expect(confirm().onPressed, isNotNull);
      expect(env.cloud.acceptCodes, isEmpty);

      await tapKey(tester, 'btn_join_confirm');

      expect(env.cloud.acceptCodes, <String>['AHBU-TR-ABCDEF123456'], reason: 'devir ucu ve normalleştirilmiş kod');
      expect(env.cloud.joinCodes, isEmpty);
      expect(opened.result, isTrue);
    });

    testWidgets('"Geri" ilk adıma döner; kod korunur, ifade temizlenir', (tester) async {
      final env = e2Env(role: null);
      env.cloud.previewToReturn = const JoinCodePreview(isTransfer: true, homeName: 'Villa Merkez');
      await open(tester, env);
      await typeInto(tester, 'field_join_code', 'AHBU-TR-ABCDEF123456');
      await tapKey(tester, 'btn_join_continue');
      await typeInto(tester, 'field_join_confirm_phrase', 'DEVRAL');

      await tapKey(tester, 'btn_join_back');

      expect(find.byKey(const Key('field_join_code')), findsOneWidget);
      expect(tester.widget<TextFormField>(find.byKey(const Key('field_join_code'))).controller!.text, contains('AHBU-TR-ABCDEF123456'));
    });

    testWidgets('süresi dolmuş kod (önizlemede 410) ilk adımda açık mesajla gösterilir', (tester) async {
      final env = e2Env(role: null);
      env.cloud.previewError = apiError(410, 'Bu kodun süresi dolmuş.', code: 'GONE');
      await open(tester, env);

      await typeInto(tester, 'field_join_code', 'AHBU-AB12CD34EF');
      await tapKey(tester, 'btn_join_continue');

      expect(textOf(tester, 'join_error'), 'Bu kodun süresi dolmuş.');
      expect(find.byKey(const Key('btn_join_continue')), findsOneWidget, reason: 'ilk adımda kalır');
    });

    testWidgets('katılma hatası (kod kullanılmış) onay adımında açık mesaj verir ve tekrar denenebilir', (tester) async {
      final env = e2Env(role: null);
      env.cloud.joinError = apiError(410, 'Bu davet kodu daha önce kullanılmış.', code: 'GONE');
      await open(tester, env);
      await typeInto(tester, 'field_join_code', 'AHBU-AB12CD34EF');
      await tapKey(tester, 'btn_join_continue');

      await tapKey(tester, 'btn_join_confirm');

      expect(textOf(tester, 'join_error'), 'Bu kodun süresi dolmuş veya daha önce kullanılmış. Yeni bir kod isteyin.');
      expect(find.byKey(const Key('btn_join_confirm')), findsOneWidget);
    });

    testWidgets('onay sırasında çift dokunuş ikinci katılım isteği göndermez', (tester) async {
      final env = e2Env(role: null);
      await open(tester, env);
      await typeInto(tester, 'field_join_code', 'AHBU-AB12CD34EF');
      await tapKey(tester, 'btn_join_continue');

      await tester.tap(find.byKey(const Key('btn_join_confirm')));
      await tester.tap(find.byKey(const Key('btn_join_confirm')), warnIfMissed: false);
      await settle(tester);

      expect(env.cloud.joinCodes, hasLength(1));
    });

    testWidgets('QR\'dan gelen başlangıç kodu girişe yazılır (kullanıcı önce önizlemeyi görür)', (tester) async {
      final env = e2Env(role: null);
      await open(tester, env, initialCode: 'AHBU-AB12CD34EF');

      expect(tester.widget<TextFormField>(find.byKey(const Key('field_join_code'))).controller!.text, 'AHBU-AB12CD34EF');
      expect(env.cloud.joinCodes, isEmpty, reason: 'taranan kod otomatik katılmaz');
    });

    testWidgets('servis PIN oturumuyla bir eve katılınamaz', (tester) async {
      final env = e2Env(role: 'service_session', globalRole: 'service_session');
      env.cloud.restoreServiceSession(accessToken: 'servis', info: _sessionInfo());
      await open(tester, env);

      expect(find.byKey(const Key('join_forbidden')), findsOneWidget);
      expect(find.byKey(const Key('btn_join_continue')), findsNothing);
    });
  });
}

ServiceSessionInfo _sessionInfo() => ServiceSessionInfo(
      homeId: kHomeA,
      homeName: 'Servis Evi',
      expiresAt: kTestNow.add(const Duration(hours: 2)),
    );
